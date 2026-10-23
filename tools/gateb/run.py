#!/usr/bin/env python3
"""Run Gate B checks in isolated local Minecraft worlds."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import ExitStack
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import uuid

from checks import ACCELERATED, GROUPS, IDS, load
from checks.context import Context, sanitize
from checks.admission import admit, reserve_local_slot
from checks.model import Blocked, Result, Verdict

ROOT = Path(__file__).resolve().parents[2]
MAPPING = (
    (r"(?:so-mod-mine|so-mine-plan|so-mod-lease)", ("C5", "C7", "C8", "C10")),
    (r"(?:^|/)(?:display|so-mod-display|so-ui|screens)(?:[./-]|$)", ("C3", "C4")),
    (r"so-mod-ar", ("C13",)),
    (r"(?:^|/)(?:install|update)(?:[./-]|$)", ("C1", "C14")),
    (r"(?:^|/)worker(?:[./-]|$)", ("C1", "C9", "C11")),
    (r"lumber", ("C6",)),
    (r"shop|roomsorter", ("C12",)),
    (r"(?:pair|pairing)", ("C2",)),
)


def git(*args, binary=False):
    done = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True)
    if done.returncode:
        raise ValueError("Git cannot resolve the requested revision or diff")
    return done.stdout if binary else done.stdout.decode().strip()


def resolve(ref):
    return git("rev-parse", "--verify", f"{ref}^{{commit}}")


def select_checks(files):
    selected = set()
    for path in files:
        if path.startswith(("docs/", "tests/", "tools/")) or path.lower().endswith(".md"):
            continue
        matches = [checks for pattern, checks in MAPPING if re.search(pattern, path)]
        if matches:
            for checks in matches: selected.update(checks)
        elif path.endswith(".lua"):
            selected.update(IDS)
    return [check for check in IDS if check in selected]


def tick_scaled(commit):
    server, store = git("show", f"{commit}:so-server.lua"), git("show", f"{commit}:so-store.lua")
    return bool(re.search(r"now\s*=\s*store\.clock\(", server) and "function M.clock()" in store and "os.clock()" in store)


def merge_results(results, expected, commit, wall_seconds):
    indexed = {}
    for result in results:
        item = result.to_dict() if isinstance(result, Result) else result
        if item["check"] not in expected: raise ValueError("Unexpected check in results")
        if item["check"] in indexed: raise ValueError("Duplicate check result")
        if item["commit"] != commit: raise ValueError("Cannot merge evidence from different commits")
        if item["status"] not in ("pass", "fail", "blocked"): raise ValueError("Invalid result status")
        indexed[item["check"]] = item
    for check in expected:
        if check not in indexed:
            indexed[check] = Result(check, commit, "blocked", "", 0, 20, ["No check result produced"], {}, [], "").to_dict()
    ordered = [indexed[c] for c in IDS if c in indexed]
    counts = {status: sum(r["status"] == status for r in ordered) for status in ("pass", "fail", "blocked")}
    status = "fail" if counts["fail"] else "blocked" if counts["blocked"] else "pass" if ordered else "not_run"
    return {"version": 1, "commit": commit, "status": status, "wall_seconds": round(wall_seconds, 3),
            "counts": counts, "checks": ordered, "unselected": [c for c in IDS if c not in expected]}


def write_report(report, output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    (output / "report.json").write_text(json.dumps(sanitize(report), indent=2) + "\n")
    for result in report["checks"]:
        target = output / result["check"] / f"{result['check']}-result.json"
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(sanitize(result), indent=2) + "\n")
    lines = [f"# Gate B, server-only {report['commit'][:12]}", "", f"Exact build `{report['commit']}`.", "",
             f"Result {report['status']}. {report['counts']['pass']} Pass, {report['counts']['fail']} Fail, {report['counts']['blocked']} Blocked.",
             f"Wall time {report['wall_seconds']:.2f} seconds.", "", "| Check | Result | Timing, observation and evidence |", "| --- | --- | --- |"]
    for r in report["checks"]:
        findings = "; ".join(r["findings"]) or load(r["check"]).TITLE
        findings = findings.replace("|", "\\|").replace("\n", " ")
        if "observed_game_seconds" in r["metrics"]:
            findings += f"; sampled {r['metrics']['observed_wall_seconds']:.2f} real seconds / {r['metrics']['observed_game_seconds']:.2f} game seconds"
        target = f"{r['check']}/{r['check']}-result.json"
        lines.append(f"| {r['check']} | {r['status'].title()} | {r['wall_seconds']:.2f}s at {r['tick_rate']:g} TPS. {findings}. [Evidence]({target}) |")
    if report["unselected"]:
        lines += ["", "Unselected checks have no result for this build: " + ", ".join(report["unselected"]) + "."]
    (output / "report.md").write_text("\n".join(lines) + "\n")


def runtime_class(directory):
    path = directory / "world.py"
    if not path.is_file(): raise Blocked("Runtime is not installed. Land codex/gateb-runtime or pass --runtime-dir to its tools/gateb directory")
    spec = importlib.util.spec_from_file_location("gateb_world", path)
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(directory))
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.Runtime


def execute(ctx, check, runtime_dir, prepare=True, reset=True):
    started_at, start = datetime.now(timezone.utc).isoformat(), time.monotonic()
    try:
        ctx.runtime_dir = runtime_dir
        if prepare:
            admit()
            if reset:
                ctx.cli("reset", ctx.run, timeout=180)
                ctx.cli("serve", ctx.run, timeout=180)
            install = ctx.cli("install", ctx.run, ctx.commit, "--mode", "copy", timeout=180)
            ctx.record("installed-build.json", install)
            if install.get("sha") != ctx.commit or install.get("errors"):
                raise Blocked("Runtime did not verify a clean exact-commit installation")
            ctx.manifest = ctx.request("manifest")
            if not ctx.wait(lambda: ctx.lua("server", 'return SO and SO.mods and SO.mods.display and SO.mods.display.screen("mining") ~= nil'), 60):
                raise Blocked("Installed server did not finish booting")
        ctx.command(f"tick rate {ctx.tick_rate:g}")
        if ctx.tick_rate != 20 and ctx.lua("server", 'return SO and type(SO.now) == "function"') is not True:
            raise Blocked("Installed server has no SO.now tick-scaled clock; refusing speed-up")
        verdict = load(check).run(ctx)
    except Blocked as error:
        verdict = Verdict("blocked", [str(error)])
    except (RuntimeError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        ctx.record("runtime-error.json", {"type": type(error).__name__, "message": str(error)})
        verdict = Verdict("blocked", [f"Runtime or evidence unavailable ({type(error).__name__}); see runtime-error.json"])
    finally:
        try: ctx.command("tick rate 20")
        except (RuntimeError, OSError, ValueError): pass
    result = Result(check, ctx.commit, verdict.status, started_at, round(time.monotonic()-start, 3),
                    ctx.tick_rate, verdict.findings, verdict.metrics, ctx.evidence, ctx.run)
    ctx.record(f"{check}-result.json", result.to_dict())
    print(f"{check} {result.status} {result.wall_seconds:.2f}s", flush=True)
    return result


def stop_owned(ctx, world):
    try:
        return ctx.cli("stop", world)
    except (Blocked, OSError, subprocess.TimeoutExpired) as error:
        proof = {"world": world, "graceful_stop_error": str(error)}
        ctx.record(f"{world}-shutdown.json", proof)
        keeper = importlib.import_module("keeper")
        for force in (False, True):
            if world not in ctx.runtime.status():
                return {**proof, "stopped": True}
            keeper.call(ctx.runtime.home, {"op": "signal", "key": world, "force": force})
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if world not in ctx.runtime.status():
                    result = {**proof, "stopped": True, "forced": force}
                    ctx.record(f"{world}-shutdown.json", result)
                    return result
                time.sleep(.2)
        raise Blocked(f"Owned runtime process {world} survived cleanup")


def execute_repeated(ctx, check, runtime_dir, reset=True):
    if check not in ("C8", "C10"):
        return execute(ctx, check, runtime_dir, reset=reset)
    attempts = []
    for index in range(1, 4):
        attempt = Context(ctx.runtime, ctx.run, {}, ctx.output / f"attempt-{index}",
                          ctx.commit, ctx.tick_rate, ctx.interval)
        attempts.append(execute(attempt, check, runtime_dir, reset=reset or index > 1))
    statuses = [result.status for result in attempts]
    durations = [result.wall_seconds for result in attempts]
    status = "fail" if "fail" in statuses else "blocked" if "blocked" in statuses else "pass"
    metrics = {"attempts": [result.to_dict() for result in attempts], "repeat_count": 3,
               "flaky": len(set(statuses)) > 1,
               "wall_seconds_min": min(durations), "wall_seconds_max": max(durations),
               "wall_seconds_spread": max(durations) - min(durations)}
    findings = [f"Three independent runs: {', '.join(statuses)}; wall spread {max(durations)-min(durations):.2f}s"]
    result = Result(check, ctx.commit, status, attempts[0].started_at, sum(durations),
                    ctx.tick_rate, findings, metrics,
                    [f"attempt-{i}/{check}-result.json" for i in range(1, 4)], ctx.run)
    ctx.record(f"{check}-result.json", result.to_dict())
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--full", metavar="SHA")
    mode.add_argument("--changed", metavar="BASE..SHA")
    parser.add_argument("--checks", help="Comma-separated checks; unioned with changed-file selection")
    parser.add_argument("--sha", default="origin/server-only", help="Build for explicit --checks")
    parser.add_argument("--worlds", type=int, default=2)
    parser.add_argument("--tick-rate", type=float, default=20)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--runtime-dir", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--plan", action="store_true", help="Print selection and effective rates without starting a runtime")
    args = parser.parse_args(argv)
    if not args.full and not args.changed and not args.checks: parser.error("Specify --full, --changed, or --checks")
    if args.worlds < 1 or args.worlds > 4: parser.error("--worlds must be between 1 and 4")
    if not 1 <= args.tick_rate <= 200: parser.error("--tick-rate must be between 1 and 200")
    try:
        selected = set(IDS if args.full else ())
        revision = args.full or args.sha
        if args.changed:
            if "..." in args.changed or args.changed.count("..") != 1: parser.error("--changed requires BASE..SHA")
            base, revision = args.changed.split("..")
            base, revision = resolve(base), resolve(revision)
            paths = git("diff", "--name-only", "-z", "--no-renames", base, revision).split("\0")
            selected.update(select_checks(paths))
        commit = resolve(revision)
        if args.checks:
            explicit = set(args.checks.upper().split(","))
            if not explicit <= set(IDS): parser.error("Unknown check in --checks")
            selected.update(explicit)
        selected = [c for c in IDS if c in selected]
        rates = {c: args.tick_rate if c in ACCELERATED else 20 for c in selected}
        if any(rate != 20 for rate in rates.values()) and not tick_scaled(commit):
            parser.error("This build has no SO.now tick-scaled clock from codex/so-clock. Speed-up would shorten lease/retry coverage; use --tick-rate 20")
        if args.plan:
            print(json.dumps({"commit": commit, "checks": selected, "tick_rates": rates, "worlds": args.worlds,
                              "repeats": {c: 3 if c in ("C8", "C10") else 1 for c in selected}}, indent=2))
            return 0
        output = args.output or Path.home() / "work/gateb-driver" / (datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + commit[:12])
        start = time.monotonic()
        if not selected:
            write_report(merge_results([], [], commit, 0), output)
            print(f"No affected gameplay checks. Report {output / 'report.md'}")
            return 0
        Runtime = runtime_class(args.runtime_dir.resolve())
        runtime = Runtime()
        cli = Context(runtime, "", {}, output, commit)
        cli.runtime_dir = args.runtime_dir.resolve()
        token = datetime.now().strftime("%Y%m%d%H%M%S") + "-" + uuid.uuid4().hex[:8]
        groups = [[c for c in checks if c in selected] for checks in GROUPS.values()]
        groups = [checks for checks in groups if checks]
        prefix = f"driver-{token}"
        worlds = [f"{prefix}-{i+1}" for i in range(min(args.worlds, len(groups))) ]
        client_lock, group_lock = threading.Lock(), threading.Lock()
        results, created, finished = [], [], set()
        reservation = ExitStack()
        try:
            admit()
            reservation.enter_context(reserve_local_slot())
            created.extend(worlds)
            resources = cli.cli("pool", "up", len(worlds), "--prefix", prefix, timeout=180 * len(worlds))
            cli.record("pool-start.json", resources)
            def worker(world):
                output_results = []
                first = True
                while True:
                    with group_lock:
                        if not groups: break
                        checks = groups.pop(0)
                    for check in checks:
                        with group_lock:
                            if check in finished: continue
                        ctx = Context(runtime, world, {}, output/check, commit, rates[check])
                        if check == "C3" and "C1" in selected:
                            def linked_install():
                                linked = Context(runtime, world, ctx.manifest, output/"C1", commit, 20)
                                result = execute(linked, "C1", args.runtime_dir.resolve(), prepare=False)
                                with group_lock:
                                    results.append(result)
                                    finished.add("C1")
                            ctx.linked_install = linked_install
                        if check in ("C3", "C13"):
                            with client_lock: result = execute(ctx, check, args.runtime_dir.resolve(), reset=not first)
                        else: result = execute_repeated(ctx, check, args.runtime_dir.resolve(), reset=not first)
                        first = False
                        with group_lock:
                            results.append(result)
                            finished.add(check)
                return output_results
            with ThreadPoolExecutor(max_workers=len(worlds)) as pool:
                for future in as_completed([pool.submit(worker, world) for world in worlds]):
                    future.result()
        except (Blocked, OSError, subprocess.TimeoutExpired) as error:
            for check in selected:
                if check not in finished:
                    results.append(Result(check, commit, "blocked", datetime.now(timezone.utc).isoformat(),
                                          0, rates[check], [str(error)], {}, [], ""))
            raise
        finally:
            cleanup = []
            for world in created:
                cleanup.append(stop_owned(cli, world))
            reservation.close()
            report = merge_results(results, selected, commit, time.monotonic()-start)
            report["cleanup"] = cleanup
            write_report(report, output)
        print(f"Report {output / 'report.md'}", flush=True)
        return 0 if report["status"] == "pass" else 1
    except (Blocked, ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
