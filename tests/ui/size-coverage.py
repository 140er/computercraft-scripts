"""Validate the required size matrix and compare temporary Python renders with Lua."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "docs/ui/schematic"))
import size_adapters as A
import cc
sys.path.insert(0, str(ROOT / "tools"))
from test_parts import graph, closure


def need(condition, message):
    if not condition:
        raise ValueError(message)


def fields(value, names, context):
    need(type(value) is dict and set(value) == set(names.split()), context + " fields")


def array(value, context):
    need(type(value) is list, context + " must be a dense array")
    return value


def dimension(value, limit):
    return type(value) is int and 1 <= value <= limit


def case_name(ident, state, w, h):
    return "%s/%s/%dx%d" % (ident, state, w, h)


def manifest():
    screens = []
    for ident, spec in A.SCREENS.items():
        screen = copy.deepcopy(spec)
        screen["fixtures"] = [dict(name=case_name(ident, state, w, h), width=w, height=h, state=state)
                              for state in spec["states"] for w, h in A.BASELINE]
        screens.append(screen)
    return dict(version=1, screens=screens)


def validate(doc):
    fields(doc, "version screens", "manifest")
    need(type(doc["version"]) is int and doc["version"] == 1, "manifest version")
    seen, names = set(), set()
    for s in array(doc["screens"], "screens"):
        fields(s, "id scene luaEntry pythonEntry widths heights states fixtures", "screen")
        ident = s["id"]
        need(type(ident) is str and ident in A.SCREENS, "unknown screen " + repr(ident))
        need(ident not in seen, "duplicate screen " + ident)
        seen.add(ident)
        spec = A.SCREENS[ident]
        for key in ("scene", "luaEntry", "pythonEntry"):
            need(s[key] == spec[key], ident + " unknown " + key)
        for key, limit in (("widths", 164), ("heights", 81)):
            values = array(s[key], ident + " " + key)
            need(all(dimension(v, limit) for v in values), ident + " invalid " + key)
            need(values == sorted(set(values)), ident + " unsorted or duplicate " + key)
            need(set(spec[key]) <= set(values), ident + " missing " + key + " boundary")
        states = array(s["states"], ident + " states")
        need(all(type(v) is str for v in states), ident + " invalid state")
        need(len(states) == len(set(states)), ident + " duplicate state")
        need(set(states) == set(spec["states"]), ident + " missing or unknown state")
        cases = set()
        for f in array(s["fixtures"], ident + " fixtures"):
            fields(f, "name width height state", ident + " fixture")
            need(type(f["name"]) is str and f["name"], ident + " invalid fixture name")
            need(f["name"] not in names, "duplicate fixture " + f["name"])
            names.add(f["name"])
            need(dimension(f["width"], 164) and dimension(f["height"], 81), ident + " invalid fixture dimensions")
            need(f["state"] in states, ident + " unknown fixture state")
            cases.add((f["state"], f["width"], f["height"]))
        for state in states:
            for w, h in A.BASELINE:
                need((state, w, h) in cases, "missing required case " + case_name(ident, state, w, h))
    need(seen == set(A.SCREENS), "missing screens " + ", ".join(sorted(set(A.SCREENS) - seen)))


def cases(doc):
    for s in doc["screens"]:
        sizes = set(A.BASELINE)
        for b in s["widths"]:
            sizes.update((w, 20) for w in (b - 1, b, b + 1) if dimension(w, 164))
        for b in s["heights"]:
            sizes.update((51, h) for h in (b - 1, b, b + 1) if dimension(h, 81))
        for b in s["widths"]:
            for c in s["heights"]:
                sizes.update((w, h) for w in (b - 1, b, b + 1) for h in (c - 1, c, c + 1)
                             if dimension(w, 164) and dimension(h, 81))
        for state in s["states"]:
            wanted = sizes | {(f["width"], f["height"]) for f in s["fixtures"] if f["state"] == state}
            for w, h in sorted(wanted):
                yield s["id"], state, w, h


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, "duplicate JSON field " + key)
        result[key] = value
    return result


def self_test(doc):
    trials = []
    def bad(change):
        candidate = copy.deepcopy(doc)
        change(candidate)
        trials.append(candidate)
    bad(lambda d: d.update(extra=True))
    bad(lambda d: d.update(version=True))
    bad(lambda d: d["screens"].pop())
    bad(lambda d: d["screens"].append(copy.deepcopy(d["screens"][0])))
    for key, value in (("scene", "unknown"), ("luaEntry", "os.execute"), ("pythonEntry", "eval"),
                       ("widths", [24, 24]), ("heights", [82]), ("states", []), ("fixtures", {})):
        bad(lambda d, k=key, v=value: d["screens"][0].update({k: v}))
    for key, value in (("width", True), ("height", 0), ("width", 1.5), ("state", "unknown"), ("extra", 1)):
        bad(lambda d, k=key, v=value: d["screens"][0]["fixtures"][0].update({k: v}))
    bad(lambda d: d["screens"][0]["fixtures"].pop())
    bad(lambda d: d["screens"][0]["fixtures"].append(copy.deepcopy(d["screens"][0]["fixtures"][0])))
    for ident in ("status-alerts", "pocket-worker"):
        bad(lambda d, ident=ident: d.update(screens=[s for s in d["screens"] if s["id"] != ident]))
    bad(lambda d: next(s for s in d["screens"] if s["id"] == "terminal-code")["widths"].remove(42))
    for candidate in trials:
        try:
            validate(candidate)
        except ValueError:
            continue
        raise ValueError("validator accepted malformed coverage")
    print("size-coverage: %d validator rejection checks passed" % len(trials), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=ROOT / "tests/ui/size-coverage.json")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--screen")
    parser.add_argument("--case")
    parser.add_argument("--prepare", action="store_true")
    args = parser.parse_args()
    need(not args.prepare or not (args.screen or args.case), "--prepare requires the complete matrix")
    need(not args.prepare or args.manifest.resolve() == ROOT / "tests/ui/size-coverage.json",
         "--prepare requires the repository manifest")
    doc = json.loads(args.manifest.read_text(), object_pairs_hook=unique_object)
    validate(doc)
    self_test(doc)
    if args.validate_only:
        print("size-coverage: manifest complete, %d screens" % len(doc["screens"]))
        return
    lua = os.environ.get("SIZE_COVERAGE_LUA") or shutil.which("lua5.2") or shutil.which("lua") or (str(Path(r"C:\Tools\lua52\lua52.exe")) if Path(r"C:\Tools\lua52\lua52.exe").is_file() else None)
    need(lua or args.prepare, "Lua 5.2 not found")
    count, selected = 0, set()
    with tempfile.TemporaryDirectory(prefix="size-coverage-") as temporary:
        expected = ROOT / "tests/evidence/ui-size-coverage.txt" if args.prepare else Path(temporary) / "expected.txt"
        expected.parent.mkdir(parents=True, exist_ok=True)
        with expected.open("w", encoding="utf-8", newline="\n") as out:
            _, edges = graph(ROOT)
            inputs = sorted(path for path in closure(edges, ["tests/ui/size-coverage.lua"])
                            if path != "tests/evidence/ui-size-coverage.txt")
            out.write("inputs %d\n" % len(inputs))
            for path in inputs:
                out.write(path + " " + hashlib.sha256((ROOT / path).read_bytes()).hexdigest() + "\n")
            for ident, state, w, h in cases(doc):
                if args.screen and ident != args.screen:
                    continue
                if args.case and case_name(ident, state, w, h) != args.case:
                    continue
                selected.add(ident)
                cv = A.render(ident, state, w, h)
                need((cv.w, cv.h) == (w, h), case_name(ident, state, w, h) + " Python dimensions")
                out.write("%s %s %d %d\n" % (ident, state, w, h))
                out.writelines("".join(cc.BACK.get(c[0], chr(c[0])) for c in row) + "\n" for row in cv.cells)
                for layer in (1, 2):
                    out.writelines("".join(c[layer] for c in row) + "\n" for row in cv.cells)
                controls = [b for b in cv.buttons if b["x"] <= w and b["y"] <= h and b["x"] + b["w"] > 1 and b["y"] + b["h"] > 1]
                disabled = sorted(getattr(cv, "disabled", set()) - {b["id"] for b in controls})
                out.write("controls %d budget %d disabled %d\n" % (len(controls), A.options(ident, state, w, h), len(disabled)))
                out.writelines(b["id"] + "\n" for b in controls)
                out.writelines(bid + "\n" for bid in disabled)
                count += 1
        need(count > 0, "no size cases selected")
        if args.prepare:
            print("size-coverage: prepared %d cases at %s" % (count, expected))
            return
        result = subprocess.run([lua, "tests/ui/size-render.lua", str(expected)], cwd=ROOT, timeout=600)
        need(result.returncode == 0, "Lua size parity failed")
    print("size-coverage: %d fontless cases passed across %d screens" % (count, len(selected)))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print("size-coverage: FAIL " + str(error), file=sys.stderr)
        sys.exit(1)
