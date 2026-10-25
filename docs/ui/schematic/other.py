"""Route A twins for the Build screen (so-mod-build.lua), the health pages (so-mod-health.lua) and
turtle details with the pose editor (U.turtle in so-ui.lua).

The data comes from tests/ui/other-scene.txt; tests/ui/ra2-other.lua feeds the same file to the real
modules and compares every fixture cell by cell. The helpers below are the twins of the "Group other"
block at the end of so-ui.lua.
"""
import math
import re

from cc import Canvas
from kit import actions, bar, chip, leader, mark, progress, role_bar, rule, section, tone
from pocket import wrap
from scene import lines

DOT = "·"
FACING = "NESW"


def scene():
    s = {"build": {}, "detail": {}, "health": {"machines": [], "leases": {}, "points": [], "holds": [],
                                               "entries": [], "events": []}}
    for p in lines("other-scene.txt"):
        if p[0].startswith("#"):
            continue
        k, rest = p[0], p[1:]
        if k == "build":
            b, key = s["build"], rest[0]
            if key == "area":
                n = list(map(int, rest[1:7]))
                b["area"] = dict(x1=min(n[0], n[3]), y1=min(n[1], n[4]), z1=min(n[2], n[5]),
                                 x2=max(n[0], n[3]), y2=max(n[1], n[4]), z2=max(n[2], n[5]))
            elif key in ("turtle", "home"):
                n = list(map(int, rest[1:]))
                pose = dict(x=n[-4], y=n[-3], z=n[-2], facing=n[-1])
                b[key] = dict(id=n[0], pose=pose) if key == "turtle" else pose
            elif key in ("cursor", "fuel"):
                b[key] = int(rest[1])
            elif key == "running":
                b["running"] = True
            else:
                b[key] = " ".join(rest[1:])
        elif k == "detail":
            d, key = s["detail"], rest[0]
            if key == "pose":
                n = list(map(int, rest[1:5]))
                d["pose"] = dict(x=n[0], y=n[1], z=n[2], facing=n[3])
            elif key == "inv":
                d["inv"] = [int(rest[1])]
            elif key in ("now", "fuel", "ore", "seen", "branch", "done", "total"):
                d[key] = int(rest[1])
            else:
                d[key] = rest[1]
        elif k == "draft":
            n = list(map(int, rest))
            s["draft"] = dict(x=n[0], y=n[1], z=n[2], facing=n[3])
        elif k == "health":
            h, key = s["health"], rest[0]
            if key == "machine":
                h["machines"].append(dict(id=int(rest[1]), role=rest[2], seen=int(rest[3])))
            elif key == "lease":
                h["leases"][int(rest[1])] = rest[2]
            elif key == "point":
                h["points"].append(dict(id=rest[1], broken=rest[2] == "broken"))
            elif key == "hold":
                h["holds"].append(dict(role=rest[1], id=int(rest[2]), text=" ".join(rest[3:])))
            elif key == "error":
                h["entries"].append(dict(at=int(rest[1]), text=" ".join(rest[2:])))
            elif key == "event":
                text = " ".join(rest[3:])
                h["events"].append(dict(at=int(rest[1]), kind=rest[2], text="cleared" if text == "-" else text))
            elif key == "disk":
                h["disk"] = (float(rest[1]), int(rest[2]))
            else:
                h[key] = [int(x) for x in rest[1:]]
    return s


SCENE = scene()


# ---------------------------------------------------------------- the so-ui.lua "Group other" block

def flag_lines(cv, x, y, width, text, detail, n, first=False):
    """! and the text wrapped over at most n rows, ... marking a cut. The detail is muted after the text
    when it fits, else on the next row; with first it takes row 1 alone. Returns the rows drawn."""
    rows, room, dy, dx = wrap(text or "", width - 2), width - 2, None, None
    lead = bool(first and detail)
    if lead:
        rows.insert(0, "")
        dy, dx = 1, 0
    if len(rows) > n:
        rows = rows[:n]
        last = rows[-1]
        if last:
            rows[-1] = (last if len(last) + 3 <= room else fit(last, room - 3)) + "..."
    if detail and not lead:
        if rows and len(rows[-1]) + 1 + len(detail) <= room:
            dy, dx = len(rows), len(rows[-1]) + 1
        elif len(rows) < n:
            rows.append("")
            dy, dx = len(rows), 0
    if not rows:
        return 0
    cv.put(x, y, "!", "e")
    for i, line in enumerate(rows):
        cv.put(x + 2, y + i, line, "0")
    if dy:
        cv.put(x + 2 + dx, y + dy - 1, detail, "8")
    return len(rows)


def tab_rows(cv, groups, active, reserve):
    """Tab groups from column 1; a group that does not fit beside the one before starts the next row,
    and reserve keeps the right end of row 1 free. Tabs are (label, id, accent). Returns the last row."""
    x, y = 1, 1
    for i, group in enumerate(groups):
        width = sum(len(t[0]) + 2 for t in group)
        if i > 0 and x + 2 + width - 1 > cv.w - (reserve if y == 1 else 0):
            rule(cv, x + 1, y, cv.w - 1)
            x, y = 1, y + 1
        elif i > 0:
            x += 2
        for t in group:
            on = t[1] == active
            cv.put(x, y, " %s " % t[0], "0" if on else "8", "7" if on else "f")
            if len(t) > 2 and t[2]:
                word = t[0].split()[-1]
                cv.put(x + 1 + len(t[0]) - len(word), y, word, t[2])
            cv.hit(t[1], x, y, len(t[0]) + 2, 1, t[0])
            x += len(t[0]) + 2
    rule(cv, x + 1, y, cv.w - 1)
    return y


def fit(text, width):
    """The text cut to width at the last space that fits, or mid-word when one word is longer."""
    if len(text) <= width:
        return text
    m = re.match(r"^(.*\S)\s", text[:width + 1])
    return m.group(1) if m else text[:max(0, width)]


def pager(cv, y, note, back, forward):
    chip(cv, cv.w - 7, y, "◄", "prev", "plain" if back else "muted")
    chip(cv, cv.w - 3, y, "►", "next", "plain" if forward else "muted")
    if note:
        cv.put(cv.w - 8 - len(note), y, note, "8")


def control_rows(cv, items, back):
    """Chips flowed over the last rows, then back right-aligned on the last row. Returns the first row."""
    rows, x = [[]], 2
    for item in items:
        if x + len(item[0]) + 2 > cv.w and rows[-1]:
            rows.append([])
            x = 2
        rows[-1].append(item)
        x += len(item[0]) + 3
    bx = cv.w - len(back[0]) - 2
    if rows[-1] and x > bx:
        rows.append([])
    top = cv.h - len(rows) + 1
    for i, row in enumerate(rows):
        cx = 2
        for label, bid, kind in row:
            cx = chip(cv, cx, top + i, label, bid, kind) + 1
    chip(cv, bx, cv.h, *back)
    return top


# ---------------------------------------------------------------- turtle details

def pose_text(p):
    if not p or any(p.get(a) is None for a in "xyz"):
        return "-"
    return "%d,%d,%d %s" % (p["x"], p["y"], p["z"], FACING[p.get("facing", 0)])


def detail_row():
    d = SCENE["detail"]
    return dict(role=d["role"], state=d["state"], pose=d["pose"], fuel=d["fuel"],
                inv=[dict(slot=1, count=c) for c in d["inv"]], lease=d["lease"], step=d["step"], ore=d["ore"],
                seen=d["seen"], branch=d["branch"], done=d["done"], total=d["total"])


def confirm_chip(sel, key, label, bid, kind):
    """U.confirmChip: CONFIRM in coral while key is armed, else label as kind."""
    return ("CONFIRM", bid, "stop") if sel.get("confirm") == key else (label, bid, kind)


def turtle(w, h, title, sel=None, row=None, now=None):
    """U.turtle.render: the state word in the header, the error flag, leaders, progress, then the job's
    chips with BACK on the last row. With a draft it is the pose editor, with a step chip from 36 cells.
    With row workerPark the chips park, resume and remove this worker; RESUME replaces PARK once parked."""
    cv = Canvas(w, h, title)
    sel = sel or dict(id=SCENE["detail"]["id"])
    row = detail_row() if row is None else row
    now = SCENE["detail"]["now"] if now is None else now
    gap, lw, name = (1 if h >= 16 else 0), min(w - 2, 36), "TURTLE #%s" % sel["id"]
    if sel.get("draft"):
        p = sel["draft"]
        bar(cv, name, (), None, "pose ?" if row.get("uncertain") else "", "e")
        y = 2 + gap
        section(cv, 2, y, w - 2, "POSE", pose_text(p), "0")
        for i, axis in enumerate(("x", "y", "z", "facing")):
            ry = y + gap + 1 + i * (2 if h >= 19 else 1)
            value = FACING[p["facing"]] if axis == "facing" else str(p[axis])
            cv.put(2, ry, axis, "8")
            chip(cv, w - 15, ry, "-", "pose:%s:-1" % axis)
            cv.put(w - 12 + (9 - len(value)) // 2, ry, value, "0")
            chip(cv, w - 3, ry, "+", "pose:%s:1" % axis)
        items = [confirm_chip(sel, "add", "RE-ADD", "turtle-save", "primary")]
        if w >= 36:
            ten = sel.get("step") == 10
            items.append(("step 10" if ten else "step 1", "pose-step", "on" if ten else "plain"))
        control_rows(cv, items, ("BACK", "turtle-cancel", "plain"))
        return cv
    uncertain = row.get("uncertain")
    state = "pose ?" if uncertain else row.get("state") or "unassigned"
    fg = "e" if uncertain else tone(state) if row.get("state") else "8"
    if len(state) > w - len(name) - 5:
        state = state.split()[0][:max(0, w - len(name) - 5)]
    bar(cv, name, (), None, state, fg)
    role, items = row.get("role"), []
    assigned = role in ("mining", "lumber")
    park = row.get("workerPark")
    if assigned and park and row.get("state") == "parked":
        items.append(("RESUME", "turtle-resume", "primary"))
    elif assigned:
        items.append(("PARK ALL" if role == "mining" and not park else "PARK", "turtle-park", "plain"))
    if role == "mining" or assigned and park:
        items.append(confirm_chip(sel, "remove", "REMOVE", "turtle-remove", "stop"))
    if assigned and uncertain:
        items.append(("RE-ADD", "turtle-add", "primary"))
    top = control_rows(cv, items, ("BACK", "turtle-back", "plain"))
    y, bottom = 2 + gap, top - 1 - gap
    retry = "retry %ds" % max(0, math.ceil((row["retry"] - now) / 1000)) if row.get("retry") is not None else ""
    if row.get("error") or retry:
        y += flag_lines(cv, 2, y, w - 2, row.get("error") or "", retry, 3 if retry else 2, True) + gap
    inv = row.get("inv") or []
    fuel = row.get("fuel")
    seen = row.get("seen")
    facts = [("pose", "?" if uncertain else pose_text(row.get("pose")), "e" if uncertain else None),
             ("fuel", "-" if fuel is None else str(fuel), "1" if fuel is not None and fuel < 64 else None),
             ("inventory", "%d/16 %s %d" % (len(inv), DOT, sum(i.get("count", 0) for i in inv)), None),
             ("lease", str(row.get("lease") or "-"), None),
             ("step", str(row.get("step") or "-"), None),
             ("ore", str(row.get("ore") or 0), None),
             ("seen", "%ds" % max(0, (now - seen) // 1000) if seen is not None else "-", None)]
    total = row.get("total")
    shown = max(0, min(len(facts), bottom - y + 1 - (1 + gap if total is not None else 0)))
    for i, (label, value, vfg) in enumerate(facts[:shown]):
        leader(cv, 2, y + i, lw, label, value, vfg or ("8" if value == "-" else "0"))
    if total is not None:
        py = y + shown + gap
        branch = row.get("branch")
        label = "spots" if role == "lumber" else "b%s" % (branch + 1 if branch is not None else "-")
        cv.put(2, py, label, "8")
        x = 2 + len(label) + 1
        if row.get("done") is None:
            cv.put(x, py, "-/%d" % total, "0")
        else:
            frac = "%d/%d" % (row["done"], total)
            progress(cv, x, py, max(1, min(12, w - 1 - x - len(frac))), row["done"], total)
    return cv


def _turtle(w, h, title):
    return lambda: turtle(w, h, title)


def _parked(w, h, title):
    def make():
        row = detail_row()
        row["workerPark"], row["state"] = True, "parked"
        return turtle(w, h, title, None, row)
    return make


def _pose(w, h, title):
    def make():
        row = detail_row()
        row["uncertain"] = True
        return turtle(w, h, title, dict(id=SCENE["detail"]["id"], draft=SCENE["draft"]), row)
    return make


# ---------------------------------------------------------------- build

def cells(b, shape):
    """How many cells so-mod-build's expand lists for the area and shape."""
    n = 0
    for y in range(b["y1"], b["y2"] + 1):
        if shape == "floor" and y != b["y1"]:
            continue
        for z in range(b["z1"], b["z2"] + 1):
            for x in range(b["x1"], b["x2"] + 1):
                edge = x in (b["x1"], b["x2"]) or z in (b["z1"], b["z2"])
                if shape == "floor" or edge or shape == "box" and y in (b["y1"], b["y2"]):
                    n += 1
    return n


def build(w, h, title, setup=False):
    """so-mod-build's render: tabs job and setup; START and STOP on the last row of both."""
    cv = Canvas(w, h, title)
    j = SCENE["build"]
    gap, lw = (1 if h >= 16 else 0), min(w - 2, 40)
    state = j.get("blocked") or ("running" if j.get("running") else "stopped")
    fg = tone(state)
    if j.get("blocked") and fg != "e":
        fg = "1"
    shape = {"platform": "floor", "wall": "walls"}.get(j.get("shape"), j.get("shape") or "floor")
    b, t = j.get("area"), j.get("turtle")
    frm = "%d,%d,%d" % (b["x1"], b["y1"], b["z1"]) if b else None
    to = "%d,%d,%d" % (b["x2"], b["y2"], b["z2"]) if b else None
    stuff = j["material"].replace("minecraft:", "", 1) if j.get("material", "").startswith("minecraft:") \
        else j.get("material")
    role_bar(cv, "BUILD", ["job", "setup"], ["job", "setup"], 1 if setup else 0)
    y = 2 + gap
    if j.get("alert"):
        y += flag_lines(cv, 2, y, w - 2, j["alert"], None, 2) + gap
    if setup:
        cx = 13 if w >= 36 else 11
        cv.put(2, y, "shape", "8")
        if cx + 20 <= w - 1:
            x = cx
            for name in ("floor", "walls", "box"):
                x = chip(cv, x, y, name, "shape " + name, "plain" if name == shape else "off") + 1
        else:
            chip(cv, cx, y, shape, "shape-next")
        rows = [("from", frm), ("to", to), ("material", stuff), ("turtle", t and "#%d" % t["id"]),
                ("home", j.get("home") and pose_text(j["home"]))]
        for i, (label, value) in enumerate(rows):
            ry = y + (i + 1) * (2 if h >= 16 else 1)
            if ry < h - gap:
                cv.put(2, ry, label, "8")
                cv.put(cx, ry, (value or "-")[:max(0, w - cx)], "0" if value else "8")
    else:
        total = cells(b, shape) if b else 0
        done = min(j.get("cursor", 1) - 1, total)
        frac = "%d/%d" % (done, total)
        section(cv, 2, y, lw, shape.upper(), state, fg)
        progress(cv, 2, y + 1, max(1, lw - 1 - len(frac)), done, total)
        facts = [("material", stuff), ("turtle", t and "#%d" % t["id"]), ("position", t and pose_text(t["pose"])),
                 ("fuel", str(j["fuel"]) if j.get("fuel") is not None else None), ("from", frm), ("to", to)]
        for i, (label, value) in enumerate(facts):
            ry = y + 2 + gap + i
            if ry < h - gap:
                leader(cv, 2, ry, lw, label, value or "-", "0" if value else "8")
    running = j.get("running")
    actions(cv, h, [("START", "start", "muted" if running else "primary"),
                    ("STOP", "stop", "stop" if running else "muted")])
    return cv


def _build(w, h, title, setup=False):
    return lambda: build(w, h, title, setup)


# ---------------------------------------------------------------- health

def duration(ms):
    s = max(0, ms // 1000)
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm" % (s // 60)
    return "%dh%02dm" % (s // 3600, (s // 60) % 60)


def attention(hs):
    """so-mod-health's attention rows for the facts in the scene: broken drops, lost turtles, job holds
    and a full disk, most severe first."""
    now, rows = hs["now"][0], []
    for p in hs["points"]:
        if p["broken"]:
            rows.append((1, "drop/" + p["id"], "Chest %s broken" % p["id"], "generic"))
    owners = {}
    for hold in hs["holds"]:
        owners[hold["id"]] = hold["role"]
        rows.append((2, "%s/%d" % (hold["role"], hold["id"]), "T%d %s" % (hold["id"], hold["text"]), hold["role"]))
    for m in hs["machines"]:
        if m["role"] in ("worker", "turtle") and now - m["seen"] > 180000:
            pose = m.get("pose")
            text = "T%d lost %s" % (m["id"], duration(now - m["seen"]))
            if pose:
                text += " x%d y%d z%d" % (pose["x"], pose["y"], pose["z"])
            rows.append((1, "lost/%d" % m["id"], text, owners.get(m["id"], "mining")))
    if hs.get("gps_gap", 0) > 2:
        rows.append((2, "gps", "Server GPS gap %.1f blocks" % hs["gps_gap"], "health"))
    if hs["disk"][0] >= 0.8:
        rows.append((1, "disk", "Disk %d%% full" % int(hs["disk"][0] * 100), "health"))
    if hs["errors"][0] and hs["entries"] and 0 <= now - hs["entries"][-1]["at"] < 600000:
        rows.append((2, "errors", "Server errors %d" % hs["errors"][0], "errors"))
    for request in hs.get("requests", []):
        rows.append((2, "pair/%d" % request["id"], "Pair %d" % request["id"], "panel"))
    rows.sort(key=lambda r: (r[0], r[1]))
    return [dict(severity=r[0], key=r[1], text=r[2], target=r[3]) for r in rows]


def byte_size(n):
    if n is None:
        return "-"
    if n >= 1048576:
        return "%.1f MB" % (n / 1048576)
    if n >= 1024:
        return "%.1f KB" % (n / 1024)
    return "%d B" % n


def metrics(hs):
    now = hs["now"][0]
    started, cadence, wall, cost = hs["runtime"]
    seq, segments, size, snap, snap_at = hs["log"]
    ratio, free = hs["disk"]
    online = sum(1 for m in hs["machines"] if now - m["seen"] <= 180000)
    lost = len(hs["machines"]) - online
    dot = " %s " % DOT
    count, nbytes = hs["errors"]
    rows = [("uptime", duration(now - started)),
            ("tick", "%s%swall %s" % ("%dms" % cadence if cadence is not None else "-", dot, "%dms" % wall if wall is not None else "-")),
            ("tick cost", "%dms" % cost if cost is not None else "-"),
            ("clock reserve", duration(hs["clock"][0] - now) if hs["clock"] else "unknown", None if hs["clock"] else "8"),
            ("events", "#%d%s%d seg" % (seq, dot, segments) if seq is not None else "unavailable", None if seq is not None else "8"),
            ("event bytes", byte_size(size)),
            ("snapshot", "#%d %s" % (snap, duration(now - snap_at)) if snap else "none", None if snap else "8"),
            ("disk", "%d%%" % int(ratio * 100), "e" if ratio >= 0.8 else None),
            ("disk free", byte_size(free)),
            ("errors", "%d%s%s" % (count, dot, byte_size(nbytes))),
            ("modems", str(hs["modems"][0])),
            ("paired", "%d online%s%d lost" % (online, dot, lost), None, "%d lost" % lost if lost else None),
            ("leases", "%d open" % len(hs["leases"]))]
    if hs.get("modules") is not None:
        modules = hs["modules"]
        loaded = sum(m["status"] == "loaded" and not m.get("tick_error") for m in modules.values())
        failed = sum(m["status"] == "failed" or bool(m.get("tick_error")) for m in modules.values())
        absent = sum(m["status"] == "absent" for m in modules.values())
        cfg = hs.get("config", {})
        flags = [name for name in ("enroll", "retireLegacyPair", "remoteDimensions", "setupMovement",
                 "dropsSavedSetup", "arFollowups", "panelUpdates", "workerSettings", "workerPark") if cfg.get(name) is True]
        if cfg.get("state", {}).get("coalesceHeartbeats") is True:
            flags.append("state.coalesceHeartbeats")
        pos = cfg.get("pos")
        prefix = [("modules", "%d loaded" % loaded if modules else "unavailable"),
                  ("skip", "%d fail %d absent" % (failed, absent)),
                  ("rev", hs.get("revision", "unknown")[:8]), ("cfg", flags[0] if flags else "defaults"),
                  ("pos", "x%d y%d z%d" % (pos["x"], pos["y"], pos["z"]) if pos else "missing"),
                  ("GPS gap", "%.1f blocks" % hs["gps_gap"] if "gps_gap" in hs else "unavailable",
                   "1" if hs.get("gps_gap", 0) > 2 else None)]
        prefix += [("cfg", flag) for flag in flags[1:]]
        rows = prefix + rows
        for file, status in sorted(modules.items()):
            name = file.removeprefix("so-mod-").removesuffix(".lua")
            value = status["status"]
            if value == "loaded":
                value = "tick failed" if status.get("tick_error") else "ok %s ago" % duration(now-status["last_good"]) if "last_good" in status else "loaded"
            rows.append((name, value, "e" if status["status"] == "failed" or status.get("tick_error") else "8" if value == "absent" else None))
            if status.get("error") or status.get("tick_error"):
                rows.append(("error", status.get("error") or status["tick_error"], "e"))
    if hs["entries"]:
        rows.append(dict(last=hs["entries"][-1]["text"]))
    return rows


def footer_rows(w, label, note):
    """The footer's left chip sits on the last row when it ends a blank column before the pager's
    note and arrows, else on the row above."""
    return 1 if len(label) + 5 <= (w - 8 - len(note) if note else w - 7) else 2


def fit_pages(count, capacity, page, w, label):
    """Rows per page, pages and footer rows for count lines under a left chip and an n/m note."""
    pages = max(1, -(-count // capacity))
    rows = footer_rows(w, label, "%d/%d" % (max(1, min(page, pages)), pages))
    if rows == 2:
        capacity = max(1, capacity - 1)
        pages = max(1, -(-count // capacity))
    return capacity, pages, rows


FACTS = [("id", "id"), ("label", "label"), ("role", "role"), ("pos", None), ("count", "count"), ("item", "name"),
         ("total", "total"), ("fuel", "fuel"), ("level", "level"), ("branch", "branch"), ("done", "done"),
         ("op", "op"), ("reason", "reason")]


def event_data(e):
    """The event's recorded data; scene events carry only a text, and "cleared" is false."""
    if "data" in e:
        return e["data"]
    return False if e["text"] == "cleared" else {"text": e["text"]}


def event_text(e):
    data = event_data(e)
    if isinstance(data, dict):
        return data.get("text") or data.get("reason")
    return "cleared" if data is False else data


def event_found(e, find):
    """history.page's text filter: a plain case-insensitive substring of the kind and the data's text,
    reason, name and label."""
    if not find:
        return True
    data, parts = event_data(e), [e["kind"]]
    if isinstance(data, str):
        parts.append(data)
    elif isinstance(data, dict):
        parts += [str(data[k]) for k in ("text", "reason", "name", "label") if k in data]
    return find[:32].lower() in " ".join(parts).lower()


def event_facts(e):
    """so-mod-health's facts(): allowlisted scalar fields as leaders, then the text."""
    data, rows = event_data(e), []
    if isinstance(data, dict):
        for label, key in FACTS:
            if key is None:
                p = data if isinstance(data.get("x"), int) else data.get("point") or {}
                if all(isinstance(p.get(a), int) for a in "xyz"):
                    rows.append((label, "%d %d %d" % (p["x"], p["y"], p["z"])))
            elif key in data:
                rows.append((label, str(data[key])))
    text = data.get("text") if isinstance(data, dict) else "cleared" if data is False else data
    return rows, text


def health(role, w, h, title, kind=None, facts=None, error=None, error_page=1, page=1, held=False, find=None,
           picker=False, fact=None, lost_detail=False):
    """so-mod-health's render for role: tabs, the page's rows from the top, paging on the last row."""
    cv = Canvas(w, h, title)
    hs = facts if facts is not None else SCENE["health"]
    now = hs["now"][0]
    items = attention(hs)
    accent = ("e" if items[0]["severity"] == 1 else "1") if items else None
    last = tab_rows(cv, [[("HEALTH", "health"), ("NEEDS %d" % len(items), "attention", accent)],
                         [("EVENTS", "events"), ("ALERTS", "alerts"), ("ERRORS", "errors")]], role, 4)
    gap, lw = (1 if h >= 16 else 0), min(w - 2, 40)
    top = last + 1 + gap
    if role == "attention" and lost_detail:
        machine = hs["machines"][0]
        cv.put(2, top, "T%d lost %s" % (machine["id"], duration(now-machine["seen"])), "e")
        pose = machine.get("pose")
        cv.put(2, top+1, fit("x%d y%d z%d" % (pose["x"], pose["y"], pose["z"]) if pose else "pose unknown", lw), "0")
        chip(cv, 2, h, "BACK", "lost-back")
        chip(cv, 9, h, "SNOOZE", "lost-snooze")
        chip(cv, w-5, h, "OPEN", "lost-open")
        return cv
    history = role in ("events", "alerts")
    if history and fact is not None:
        cv.put(2, top, fact["kind"][:w - 2], "0")
        ago = duration(now - fact["at"]) + " ago"
        if 3 + len(fact["kind"]) + len(ago) <= w:
            cv.put(3 + len(fact["kind"]), top, ago, "8")
        top += 1 + gap
        rows, text = event_facts(fact)
        lines = wrap(re.sub(r"[\x00-\x1f\x7f]", " ", text), lw - 5) if text else []
        rows += [dict(label="text" if i == 0 else "", text=line) for i, line in enumerate(lines)]
        for i, row in enumerate(rows):
            y = top + i
            if y >= h:
                break
            if isinstance(row, dict):
                cv.put(2, y, row["label"], "8")
                cv.put(7, y, row["text"], "0")
            else:
                leader(cv, 2, y, lw, row[0], row[1][:max(1, lw - len(row[0]) - 2)])
        chip(cv, 2, h, "BACK", "fact-back")
        return cv
    if role == "events" and picker:
        kinds = ["all"] + sorted({e["kind"] for e in hs["events"]})
        capacity, pages, foot = fit_pages(len(kinds), max(1, h - gap - top), 1, w, "BACK")
        for i, name in enumerate(kinds[:capacity]):
            y = top + i
            if name == (kind or "all"):
                cv.put(2, y, "•", "0")
            cv.put(4, y, name[:w - 4], "0" if name == (kind or "all") else "8")
            cv.hit("pick:%d" % (i + 1), 1, y, w, 1, name)
        chip(cv, 2, h - foot + 1, "BACK", "kind-back")
        pager(cv, h, "1/%d" % pages, False, pages > 1)
        return cv
    if role == "events":
        cv.put(2, top, "kind", "8")
        chip(cv, 7, top, kind or "all", "kind")
        top += 1 + gap
        if find:
            cv.put(2, top, "find", "8")
            chip(cv, 7, top, find[:w - 9], "find")
            top += 1 + gap
    capacity = max(0, h - gap - top)
    if history:
        left = ("LATEST", "latest", "plain") if page > 1 else ("LIVE", "live", "primary") if held else ("HOLD", "hold", "plain")
        note = str(page) if page > 1 else ""
        foot = footer_rows(w, left[0], note)
        capacity = max(0, capacity - foot + 1)
    if role == "errors" and error is not None:
        cv.put(2, top, duration(now - error["at"]) + " ago", "8")
        top += 1 + gap
        text = re.sub(r"[\x00-\x1f\x7f]", " ", error["text"])
        rows = wrap(text, lw)
        capacity, pages, foot = fit_pages(len(rows), max(1, h - gap - top), error_page, w, "BACK")
        error_page = max(1, min(error_page, pages))
        for i, line in enumerate(rows[(error_page - 1) * capacity:error_page * capacity]):
            cv.put(2, top + i, line, "0")
        chip(cv, 2, h - foot + 1, "BACK", "error-back")
        pager(cv, h, "%d/%d" % (error_page, pages), error_page > 1, error_page < pages)
        return cv
    if role == "health":
        rows = []
        for m in metrics(hs):
            if isinstance(m, dict):
                for i, line in enumerate(wrap(m["last"], lw - 5)[:2]):
                    rows.append(dict(label="last" if i == 0 else "", text=line))
            else:
                rows.append(m)
    elif role == "attention":
        rows = items
    elif role == "errors":
        rows = [dict(time=duration(now - e["at"]), text=re.split(r"[\r\n]", e["text"], maxsplit=1)[0], fg="e")
                for e in reversed(hs["entries"])]
    else:
        rows = []
        for e in reversed(hs["events"]):
            if kind and e["kind"] != kind or role == "alerts" and not e["kind"].endswith(".alert"):
                continue
            if role == "events" and not event_found(e, find):
                continue
            name = e["kind"][:-len(".alert")] if role == "alerts" and e["kind"].endswith(".alert") else e["kind"]
            text = event_text(e)
            rows.append(dict(time=duration(now - e["at"]), kind=name, text=text or "",
                             fg="e" if role == "alerts" else mark(e["kind"] + (" " + text if text else ""))))
        count = max(1, capacity)
        more = len(rows) > page * count
        rows = rows[(page - 1) * count:page * count]
    total_rows = len(rows)
    if not history:
        rows = rows[(page-1)*max(1, capacity):page*max(1, capacity)]
    if not rows:
        if role == "attention":
            cv.put(2, top, "all clear", "d")
        else:
            cv.put(2, top, "no entries", "8")
    for i in range(capacity):
        if i >= len(rows):
            break
        row, y = rows[i], top + i
        if role == "health":
            if isinstance(row, dict):
                cv.put(2, y, row["label"], "8")
                cv.put(7, y, row["text"], "0")
            else:
                leader(cv, 2, y, lw, row[0], fit(row[1], max(1, lw-len(row[0])-1)), (row[2] if len(row) > 2 and row[2] else None)
                       or ("8" if row[1] == "-" else "0"))
                if len(row) > 3 and row[3]:
                    cv.put(2 + lw - len(row[3]), y, row[3], "e")
        elif role == "attention":
            cv.put(2, y, "!", "e" if row["severity"] == 1 else "1")
            cv.put(4, y, fit(row["text"], w - 4), "0")
            cv.hit("item:" + row["key"], 1, y, w, 1)
        else:
            cv.put(2, y, "•", row["fg"])
            cv.put(4, y, row["time"], "8")
            x = 5 + len(row["time"])
            if row.get("kind"):
                cv.put(x, y, row["kind"][:max(0, w - x)], "8")
                x += len(row["kind"]) + 1
            cv.put(x, y, fit(row["text"], w - x), "0")
            if history:
                cv.hit("event:%d" % (i + 1), 1, y, w, 1)
    pages = max(1, -(-total_rows // max(1, capacity)))
    if history:
        chip(cv, 2, h - foot + 1, *left)
        pager(cv, h, note, page > 1, more)
    else:
        pager(cv, h, "%d/%d" % (page, pages), page > 1, page < pages)
    return cv


HEALTH_ERROR = (
    "tick\nfailed: so-mod-mine.lua:120 attempt to index a nil value while saving the mining job "
    "for turtle 7; checkpoint refused because the disk is full. Free space in so-data, "
    "then retry the job. The worker keeps its last saved pose and reservations while the "
    "server waits for the checkpoint. Final detail: no blocks were changed."
)


def health_case(role, w, h, pending=False, detail=False, page=1):
    hs = dict(SCENE["health"], machines=[], leases={}, points=[], holds=[], requests=[],
              errors=[0, 0], entries=[])
    if pending:
        hs["requests"] = [dict(id=17)]
    else:
        hs["errors"], hs["entries"] = [1, 340], [dict(at=3590000, text=HEALTH_ERROR)]
    return health(role, w, h, "Health %s at %dx%d" % (role, w, h), facts=hs,
                  error=hs["entries"][0] if detail else None, error_page=page)


def history_events(n):
    """The history test's log: 40 events 20 s apart, one lumber.logs among them, then later arrivals.
    tests/so/health.lua emits the same events into the real so-mod-state."""
    out = []
    for i in range(1, n + 1):
        at = 3600000 - (41 - i) * 20000 if i <= 40 else 3590000 + (i - 41) * 5000
        if i == 12:
            kind, data = "lumber.logs", {"id": 5, "count": 12, "total": 40}
        elif i % 5 == 0:
            kind, data = "mine.alert", {"id": 7, "text": "ore chest full", "reason": "full"}
        elif i % 7 == 0:
            kind, data = "drops.broken", {"text": "chest 3 broken"}
        else:
            kind, data = "mine.ore", {"id": 7, "name": "diamond", "count": 1, "x": 12, "y": i - 60, "z": 88}
        out.append(dict(at=at, kind=kind, data=data))
    return out


def history_case(w, h, n=40, **options):
    hs = dict(SCENE["health"], machines=[], leases={}, points=[], holds=[], requests=[], errors=[0, 0],
              entries=[], events=history_events(n))
    return health("events", w, h, "Health history at %dx%d" % (w, h), facts=hs, **options)


def diagnostic_case(name, w, h):
    hs = dict(SCENE["health"], now=[3600000], runtime=[3600000, None, None, None],
              clock=None, log=[None, None, 6100000, None, None], disk=[0, 6100000], modems=[1],
              machines=[], leases={}, points=[], holds=[], requests=[], errors=[0, 340], entries=[])
    hs.update(modules={"so-mod-mine.lua": dict(status="loaded", last_good=3595000),
                       "so-mod-shop.lua": dict(status="failed", error="loader failed"),
                       "so-mod-ar.lua": dict(status="absent")}, revision="a"*40,
              config=dict(retireLegacyPair=True), gps_gap=10)
    if name.startswith("lost"):
        hs.pop("gps_gap")
        hs["machines"] = [dict(id=12, role="worker", seen=3180000, pose=dict(x=120, y=64, z=-30))]
    return health("health" if name.startswith("facts") else "attention", w, h, "Health facts",
                  facts=hs, page=(2 if h >= 16 else 3) if name == "facts-modules" else 2 if name == "facts-next" else 1, lost_detail=name == "lost-detail")


HEALTH_FIXTURES = []
for _w, _h in ((26, 20), (29, 12)):
    for _name in ("facts", "facts-next", "facts-modules", "lost", "lost-detail", "gps-gap"):
        HEALTH_FIXTURES.append(("health/%s-%dx%d" % (_name, _w, _h),
                                lambda n=_name, w=_w, h=_h: diagnostic_case(n, w, h)))
    for _name, _role, _options in (
        ("needs-error", "attention", {}),
        ("needs-enroll", "attention", dict(pending=True)),
        ("errors-list", "errors", {}),
        ("error-detail", "errors", dict(detail=True)),
        ("error-detail-next", "errors", dict(detail=True, page=2)),
    ):
        HEALTH_FIXTURES.append(("health/%s-%dx%d" % (_name, _w, _h),
                                lambda r=_role, w=_w, h=_h, o=_options: health_case(r, w, h, **o)))
    # Page 2, held page 1 after two later events, the kind picker, a search and one event's facts.
    for _name, _options in (
        ("events-page2", dict(page=2)),
        ("events-held", dict(held=True)),
        ("events-picker", dict(picker=True)),
        ("events-find", dict(find="chest")),
        ("event-facts", dict(fact=history_events(40)[38])),
    ):
        HEALTH_FIXTURES.append(("health/%s-%dx%d" % (_name, _w, _h),
                                lambda w=_w, h=_h, o=_options: history_case(w, h, **o)))
# A 1x1 monitor at scale 0.5: the footer's left chip moves above the page number and arrows.
for _name, _options in (("events-15x10", {}), ("events-page2-15x10", dict(page=2)),
                        ("events-picker-15x10", dict(picker=True))):
    HEALTH_FIXTURES.append(("health/" + _name, lambda o=_options: history_case(15, 10, **o)))


def _health(role, w, h, title, kind=None):
    return lambda: health(role, w, h, title, kind)


FIXTURES = [
    ("build-26x20", _build(26, 20, "Build, job tab at 26x20")),
    ("build-29x12", _build(29, 12, "Build, job tab at 29x12")),
    ("build-57x24", _build(57, 24, "Build, job tab, room monitor 57x24")),
    ("buildsetup-26x20", _build(26, 20, "Build, setup tab at 26x20", True)),
    ("buildsetup-29x12", _build(29, 12, "Build, setup tab at 29x12", True)),
    ("buildsetup-57x24", _build(57, 24, "Build, setup tab, room monitor 57x24", True)),
    ("health-26x20", _health("health", 26, 20, "Health at 26x20")),
    ("health-29x12", _health("health", 29, 12, "Health at 29x12")),
    ("health-57x24", _health("health", 57, 24, "Health, room monitor 57x24")),
    ("attention-26x20", _health("attention", 26, 20, "Needs at 26x20")),
    ("attention-29x12", _health("attention", 29, 12, "Needs at 29x12")),
    ("alerts-26x20", _health("alerts", 26, 20, "Alerts at 26x20")),
    ("alerts-29x12", _health("alerts", 29, 12, "Alerts at 29x12")),
    ("events-26x20", _health("events", 26, 20, "Events at 26x20")),
    ("events-29x12", _health("events", 29, 12, "Events at 29x12")),
    ("events-57x24", _health("events", 57, 24, "Events, room monitor 57x24")),
    ("errors-26x20", _health("errors", 26, 20, "Errors at 26x20")),
    ("errors-29x12", _health("errors", 29, 12, "Errors at 29x12")),
    ("turtle-P", _turtle(26, 20, "Turtle detail at 26x20")),
    ("turtle-S", _turtle(29, 12, "Turtle detail at 29x12")),
    ("turtle-M", _turtle(57, 24, "Turtle detail, room monitor 57x24")),
    ("turtlepose-P", _pose(26, 20, "Pose editor for an uncertain turtle at 26x20")),
    ("turtlepose-S", _pose(29, 12, "Pose editor for an uncertain turtle at 29x12")),
]
# tests/ui/w2screens.lua checks these against the generator.
FIXTURES += [("turtlepose-M", _pose(57, 24, "Pose editor for an uncertain turtle, room monitor 57x24")),
             ("turtlepark-P", _parked(26, 20, "Parked turtle detail with worker park at 26x20"))]


if __name__ == "__main__":
    import argparse
    from pathlib import Path

    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures", required=True)
    args = parser.parse_args()
    for name, make in FIXTURES + HEALTH_FIXTURES:
        if name.startswith(("health", "attention-", "alerts-", "events-", "errors-")):
            path = Path(args.fixtures) / (name + ".txt")
            path.parent.mkdir(parents=True, exist_ok=True)
            make().fixture(str(path))
