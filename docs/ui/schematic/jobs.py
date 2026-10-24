"""Mining, lumber and drop points in route A: the twins of the layouts in so-mod-mine.lua,
so-mod-lumber.lua and so-mod-drops.lua.

Each *_model() builds from the scene the table that module's gather builds from its job, and each
layout draws it the way the Lua does, cell for cell. tests/ui/s3.lua feeds the same scene files to
the real modules and compares the frames with the fixtures written from here.
"""
from cc import Canvas
from kit import actions, arrow, bar, chip, flag, leader, role_bar, rule, section, stepper, tone
from scene import DIRS, S, ST, lines

EXTRA = {}
for _p in lines("jobs-scene.txt"):
    EXTRA.setdefault(_p[0], []).append(_p[1:])

ORES = ["coal", "copper", "iron", "gold", "redstone", "lapis", "diamond", "quartz", "nether_gold", "ancient_debris"]
TABS, SHORT = ["overview", "setup"], ["main", "setup"]
PHASES = {"scan": "scanning", "base": "felling", "climb": "felling", "descend": "felling",
          "plant": "planting", "plantPlace": "planting"}


def state_fg(t):
    return t if t in ("1", "e", "8") else "0"


def where(p):
    return "%d,%d,%d" % (p["x"], p["y"], p["z"])


def facing_of(dx, dz):
    return next(f for f, d in DIRS.items() if d == (dx, dz))


def last_row(h, wide):
    """The row of the screen-wide actions: one spare row under them on room monitors."""
    return h - 1 if wide else h


# ================================================================ mining

def mining_model(empty=False):
    """What so-mod-mine's gather builds: job facts, one row per turtle, the dug extent per branch.
    empty: the job before its first branch (jobs-scene's emptymine line), no turtle on a branch."""
    g = S["g"]
    fresh = EXTRA["emptymine"][0] if empty else None
    hf = facing_of(g["dx"], g["dz"])
    lanes = {int(a): int(b) for a, b in EXTRA["branch"]}
    rows = []
    for t in ST["turtles"]:
        if t["job"] != "mine":
            continue
        p = S["poses"][str(t["id"])]
        lane = t["at"] == "lane"
        rows.append(dict(id=t["id"], pose=dict(x=p["x"], y=p["y"], z=p["z"], facing=p["f"]), state=t["state"],
                         lost=ST["leases"].get(t["id"]) == "lost", fuel=t["fuel"], ores=t["ore"], lane=lane,
                         branch=lanes.get(t["id"]) if lane else int(t["at"])))
        if fresh:
            rows[-1].update(state=fresh[1], lane=False, branch=None)
    job = dict(home=dict(x=g["home"][0], y=g["home"][1], z=g["home"][2], facing=hf), homeSet=True,
               bottom=g["bottom"], length=g["length"], mode=g["mode"], ores=[],
               running=ST["mining"]["running"], done=ST["mining"]["done"], total=ST["mining"]["total"])
    if fresh:
        job.update(running=fresh[0] == "running", done=0, total=0)
    m = mining_gather(job, rows, ST["today"]["ore"], None)
    mining_setup(m, rows)
    return m


def chest_check(points, kind, near):
    """so-plan's chestCheck for unverified points: the nearest working point of the kind or any."""
    best = None
    for p in points:
        if p["kind"] in (kind, "any") and not p["broken"]:
            d = abs(p["x"] - near["x"]) + abs(p["y"] - near["y"]) + abs(p["z"] - near["z"])
            if best is None or p["kind"] == kind and best[1]["kind"] != kind or \
                    p["kind"] == best[1]["kind"] and (d < best[0] or d == best[0] and p["id"] < best[1]["id"]):
                best = (d, p)
    if not best:
        return (False, "no %s chest set" % kind)
    p = best[1]
    return (True, "%s #%s unverified at %d,%d,%d" % (kind, p["id"], p["x"], p["y"], p["z"]))


def mining_setup(m, rows):
    """The setup tab's extra facts: start checks, unassigned turtles and the shop's fuel policy.
    The scene's drop lines are the drop list with ids 1, 2, ...; no turtle is paired."""
    h = m["home"]
    branches = m["branches"]
    m["fuelNeed"] = branches * m["length"] + m["gap"] * branches * (branches + 1) // 2 + 2 * (1 + abs(h["y"] - m["bottom"]))
    points = [dict(d, id=str(i + 1)) for i, d in enumerate(x for x in S["drops"] if x["kind"] != "saplings")]
    ready = [(True, "home %d,%d,%d" % (h["x"], h["y"], h["z"]))]
    ready += [chest_check(points, kind, h) for kind in ("ore", "fuel")]
    ready.append((False, "paired turtle missing"))
    for row in sorted(rows, key=lambda x: x["id"]):
        ready.append((True, "#%d tools unknown" % row["id"]))
        ready.append((True, "fuel #%d %d" % (row["id"], row["fuel"])))
    m["checks"] = ready
    m["available"] = [dict(id=int(a), fuel=int(b)) for a, b in EXTRA.get("candidate", [])]
    m["policy"] = None
    for auto, out in EXTRA.get("fuelpolicy", []):
        m["policy"] = dict(auto=auto == "on", out=next((p["id"] for p in points if p["id"] == out), "-"))


def mining_gather(job, rows, ore, alert):
    """The Lua gather from job and rows (sorted by id): turtles placed on the job diagram."""
    h = job["home"]
    d, r = DIRS[h["facing"]], DIRS[(h["facing"] + 1) % 4]
    tx, tz = h["x"] + d[0], h["z"] + d[1]
    gap = 2 if job["mode"] == "fast" else 4
    total, length, bottom = job["total"], job["length"], job["bottom"]
    m = dict(state="running" if job["running"] else "stopped", alert=alert, length=length, gap=gap,
             bottom=bottom, done=job["done"], total=total, extents=[length] * total, turtles=[], busy=0,
             workers=0, lane=None, fuel=None, ore=ore, home=h, homeSet=job["homeSet"], mode=job["mode"],
             ores=job["ores"], dim="minecraft:overworld", branches=8, continuous=False)
    for row in sorted(rows, key=lambda x: x["id"]):
        p = row["pose"]
        word = "lost" if row["lost"] else row["state"]
        t = dict(id=row["id"], facing=(p["facing"] - h["facing"]) % 4, state=word, tone=tone(word),
                 where="lane" if row["lane"] else "b%d" % (row["branch"] + 1) if row["branch"] is not None else "-",
                 at=where(p), fuel=row["fuel"], ore=row["ores"], lost=row["lost"], spine=False, row=None, along=0)
        # Live branch progress: b1 12/48 (so-ui's U.branchProgress).
        if row["branch"] is not None and not row["lane"]:
            dug = length if row["state"] == "done" else (p["x"] - h["x"]) * -d[1] + (p["z"] - h["z"]) * d[0]
            t["prog"] = "%s %d/%d" % (t["where"], max(0, min(length, dug)), length)
        k = (p["x"] - tx) * d[0] + (p["z"] - tz) * d[1]
        along = (p["x"] - tx) * r[0] + (p["z"] - tz) * r[1]
        near = (2 * k + gap) // (2 * gap)
        if row["lane"]:
            t["spine"], t["row"] = True, max(0, min(total, near)) if p["y"] == bottom else 0
        elif abs(p["y"] - bottom) <= 1 and k > 0 and along > 0 and 1 <= near <= total:
            t["row"], t["along"] = near, min(along, length)
        b = row["branch"]
        if b is not None and 0 <= b < total and row["state"] != "done":
            if t["row"] == b + 1 and not t["spine"]:
                m["extents"][b] = t["along"]
            elif row.get("route") and row.get("index"):
                m["extents"][b] = max(0, min(length, row["index"] - 3 - (b + 1) * gap))
            else:
                m["extents"][b] = 0
        m["turtles"].append(t)
        m["workers"] += 1
        if t["tone"] == "d":
            m["busy"] += 1
        if row["lane"] and not m["lane"]:
            m["lane"] = t
        if row["fuel"] is not None and (m["fuel"] is None or row["fuel"] < m["fuel"]["value"]):
            m["fuel"] = dict(value=row["fuel"], id=row["id"])
    return m


def mining_facts(m):
    """The leader rows: (label, value, colour)."""
    lane, fuel = m["lane"], m["fuel"]
    return [("busy", "%d/%d" % (m["busy"], m["workers"]), "0"),
            ("lane", "#%d" % lane["id"] if lane else "-", "b" if lane else "8"),
            ("depth", str(m["bottom"]), "0"),
            ("done", "%d/%d" % (m["done"], m["total"]), "0"),
            ("ore", str(m["ore"]) if m["ore"] is not None else "-", "0" if m["ore"] is not None else "8"),
            ("fuel", str(fuel["value"]) if fuel else "-", ("1" if fuel["value"] < 500 else "0") if fuel else "8")]


def run_chips(cv, y, m, gap):
    run = m["state"] == "running"
    actions(cv, y, [("START", "start", "muted" if run else "primary"),
                    ("STOP", "stop", "stop" if run else "muted")], gap)


def diagram(cv, m, top, avail, right):
    """One row per branch, newest at the top: number, spine, dug '-' and planned '·', the turtles."""
    sp, total, length = 5, m["total"], m["length"]
    cols = max(1, min(right - sp - 9, length))
    shown = max(0, min(total, avail))
    first = total - shown + 1
    fg = "b" if m["lane"] else "3"
    for i in range(shown):
        b, y = total - i, top + i
        cv.put(max(1, sp - 2 - len(str(b))), y, str(b), "8")
        cv.put(sp, y, "+", fg)
        ext = m["extents"][b - 1]
        for k in range(1, cols + 1):
            dug = k * length <= ext * cols
            cv.put(sp + k, y, "-" if dug else "·", "3" if dug else "8")
    base = top + shown
    cv.put(sp, base, "|", fg)
    cv.put(sp, base + 1, "º", "9")
    cv.put(sp + 2, base + 1, "shaft", "8")
    marks = []
    for t in m["turtles"]:
        if t["row"] is None:
            continue
        y = top + total - t["row"] if t["row"] >= first else base
        if t["spine"]:
            label = str(t["id"])
            cv.put(sp - len(label), y, label, t["tone"])
            marks.append((sp, y, t, False))
            continue
        if t["row"] < first:
            continue
        i = max(1, min(cols, t["along"] * cols // length))
        held = i < cols and t["tone"] != "e"
        label = str(t["id"]) if t["tone"] == "d" else "%d %s" % (t["id"], t["state"].split()[0])
        x = sp + i + 2 + (1 if held else 0)
        cv.put(x, y, label[:max(0, right - x + 1)], t["tone"])
        marks.append((sp + i, y, t, held))
    for x, y, t, held in marks:
        if held:
            cv.put(x + 1, y, "-", "b")
        cv.put(x, y, arrow(t["facing"]), t["tone"])


def turtle_rows(cv, m, top, nt, right):
    """TURTLES with fuel and ore from column 2 to right: the section on row top, then nt rows."""
    ts = m["turtles"]
    if not ts:
        return
    section(cv, 2, top, right - 1, "TURTLES", "fuel  ore")
    for i in range(nt):
        y = top + 1 + i
        if i == nt - 1 and len(ts) > nt:
            cv.put(4, y, "+%d more" % (len(ts) - i), "8")
            break
        t = ts[i]
        cv.put(2, y, arrow(t["facing"]), t["tone"])
        cv.put(4, y, str(t["id"]), "0")
        cv.put(7, y, t["state"][:10], state_fg(t["tone"]))
        cv.put(18, y, (t.get("prog") or t["where"])[:9], "8")
        cv.put(28, y, t["at"][:max(0, right - 40)], "e" if t["lost"] else "8")
        fuel = "-" if t["fuel"] is None else str(t["fuel"])
        cv.put(right - 5 - len(fuel), y, fuel, "8" if t["fuel"] is None else "1" if t["fuel"] < 500 else "0")
        ore = str(t["ore"])
        cv.put(right - len(ore), y, ore, "0")


def mine_room(cv, m):
    w, h = cv.w, cv.h
    role_bar(cv, "MINING", TABS, SHORT, 0, m["state"], tone(m["state"]))
    ya = last_row(h, True)
    # The diagram draws at most one cell per block; the facts and the table follow it on wide walls.
    lx = min(w - 11, max(1, min(w - 27, m["length"])) + 18)
    facts = mining_facts(m)
    for i, (a, b, c) in enumerate(facts):
        leader(cv, lx, 3 + i, 11, a, b, c)
    run_chips(cv, ya, m, 3)
    if m["alert"]:
        flag(cv, 2, ya - 2, w - 2, m["alert"])
    # Caps keep the biggest walls inside the 16 KB frame: 12 turtle rows, 24 branch rows.
    nt = min(len(m["turtles"]), max(0, ya - 7 - len(facts)), 12)
    shown = min(m["total"], ya - 3 - nt - (1 if nt else 0) - 6 + 1, 24)
    diagram(cv, m, 3, shown, lx - 2)
    # The table runs under the facts, so a short diagram leaves it below them.
    turtle_rows(cv, m, max(3 + shown + 3, 4 + len(facts)), nt, lx + 10)


def alert_rows(cv, y, text):
    """The alert ending on row y: one flag row, or two when it is longer than the row and splits
    at a space. Returns the rows used."""
    width = cv.w - 4
    cut = text[:width + 1].rfind(" ") + 1 if len(text) > width else 0
    if cut < 2:
        flag(cv, 2, y, cv.w - 2, text)
        return 1
    flag(cv, 2, y - 1, cv.w - 2, text[:cut - 1])
    cv.put(4, y, text[cut:cut + width], "0")
    return 2


def mine_column(cv, m):
    w, h = cv.w, cv.h
    shown = role_bar(cv, "MINING", TABS, SHORT, 0, m["state"], tone(m["state"]))
    ya = last_row(h, False)
    run_chips(cv, ya, m, 1)
    facts = mining_facts(m)
    end = ya - 2 - (alert_rows(cv, ya - 1, m["alert"]) if m["alert"] else 0)
    if w < 30:
        rows = ([] if shown else [("state", m["state"], state_fg(tone(m["state"])))]) + \
               [facts[0], facts[1], facts[3], facts[5]]
        top = end - len(rows) + 1
        for i, (a, b, c) in enumerate(rows):
            leader(cv, 2, top + i, w - 2, a, b, c)
    else:
        lw = (w - 5) // 2
        rx = 2 + lw + 3
        top = end - 2
        for i in range(3):
            leader(cv, 2, top + i, lw, *facts[i])
            leader(cv, rx, top + i, w - rx, *facts[3 + i])
    # Up to four turtle rows between the diagram and the leaders.
    nt = max(0, min(len(m["turtles"]), 4, top - 5))
    if nt:
        top = top - 2 - nt
        section(cv, 2, top, w - 2, "TURTLES")
        mine_list(cv, m, top + 1, top + nt, w - 1)
    diagram(cv, m, 3, top - 6, w - 1)


def mine_list(cv, m, top, stop, right):
    """Compact turtle rows: arrow, id, then the branch progress while working or the state word;
    +N more. Returns the last row drawn."""
    ts, nt = m["turtles"], stop - top + 1
    if not ts or nt < 1:
        return top - 1
    per = max(1, nt - 1) if len(ts) > nt else nt
    for i in range(nt):
        y = top + i
        if (i == nt - 1 or i >= len(ts)) and len(ts) > nt:
            cv.put(4, y, "+%d more" % (len(ts) - min(per, len(ts))), "8")
            return y
        if i >= len(ts):
            return y - 1
        t = ts[i]
        working = t["tone"] == "d" and t.get("prog")
        text = t["prog"] if working else t["state"]
        cv.put(2, y, arrow(t["facing"]), t["tone"])
        cv.put(4, y, str(t["id"]), "0")
        cv.put(7, y, text[:max(0, right - 6)], "0" if working else state_fg(t["tone"]))
    return stop


def tiny_rows(cv, m, rows, shown, listing=None):
    """Leaders from row 3 (2 on very short screens) to h-2, the alert on h-1, the actions on h."""
    w, h = cv.w, cv.h
    if not shown:
        rows = [("state", m["state"], state_fg(tone(m["state"])))] + rows
    # A long alert wraps onto a second row from 8 rows up.
    used = 0
    if m["alert"] and h >= 4:
        if h >= 8:
            used = alert_rows(cv, h - 1, m["alert"])
        else:
            flag(cv, 2, h - 1, w - 2, m["alert"])
            used = 1
    stop = h - 1 - max(1, used)
    y = 3 if h >= 6 else 2
    for a, b, c in rows:
        if y > stop:
            break
        leader(cv, 2, y, w - 2, a, b, c)
        y += 1
    if listing:
        listing(y, stop)
    run_chips(cv, h, m, 1)


def tiny_bar(cv, name, m):
    """Tabs from 24 columns; below that the role name and the state word when it fits."""
    if cv.w >= 24:
        return role_bar(cv, name, TABS, SHORT, 0, m["state"], tone(m["state"]))
    right = m["state"] if cv.w >= 10 + len(m["state"]) + 2 else ""
    bar(cv, name, [], None, right, tone(m["state"]))
    return right != ""


def mine_tiny(cv, m):
    shown = tiny_bar(cv, "MINING", m)
    f = mining_facts(m)
    # Busy and done, then the turtles; without turtles the other leaders.
    if m["turtles"]:
        tiny_rows(cv, m, [f[0], f[3]], shown, lambda y, stop: mine_list(cv, m, y, stop, cv.w - 1))
    else:
        tiny_rows(cv, m, [f[0], f[3], f[1], f[5], f[4]], shown)


# ---------------------------------------------------------------- mining setup

def home_text(m):
    h = m["home"]
    return "%d,%d,%d %s" % (h["x"], h["y"], h["z"], "nesw"[h["facing"]]) if m["homeSet"] else "-"


def ore_text(m):
    return ",".join(m["ores"]) if m["ores"] and len(m["ores"]) < len(ORES) else "all"


def ore_on(m, name):
    return not m["ores"] or name in m["ores"]


def ore_rows(cv, m, x, y, right, stop):
    cx = x
    for name in ORES:
        if cx + len(name) + 2 > right + 1:
            cx, y = x, y + 1
        if y <= stop:
            chip(cv, cx, y, name, "ore-" + name, "plain" if ore_on(m, name) else "off")
        cx += len(name) + 3
    return y


def setup_rows(cv, m, x, y, step, vx, vw, right, editing, stop):
    """The setup controls from row y, step rows apart, none below row stop. Returns the last row."""
    if m["dim"] != "minecraft:overworld":
        if y <= stop:
            cv.put(x, y, "dim", "8")
            cv.put(vx, y, m["dim"].replace("minecraft:", "", 1)[:right - vx + 1], "0")
        y += step
    if y <= stop:
        cv.put(x, y, "home", "8")
        cv.put(vx, y, home_text(m)[:right - vx + 1], "0" if m["homeSet"] else "8")
    y += step
    if y <= stop:
        cv.put(x, y, "bottom", "8")
        stepper(cv, vx, y, "Y %d" % m["bottom"], "set-bottom", vw)
    y += step
    if y <= stop:
        cv.put(x, y, "length", "8")
        stepper(cv, vx, y, m["length"], "set-length", vw)
    y += step
    if y <= stop:
        cv.put(x, y, "mode", "8")
        nx = chip(cv, vx, y, "fast", "mode-fast", "plain" if m["mode"] == "fast" else "off") + 1
        chip(cv, nx, y, "thorough", "mode-thorough", "plain" if m["mode"] == "thorough" else "off")
    y += step
    if y <= stop:
        ex = right - 5
        cv.put(x, y, "ores", "8")
        cv.put(vx, y, ore_text(m)[:max(0, ex - vx - 1)], "0")
        chip(cv, ex, y, "edit", "ores-edit", "on" if editing else "plain")
    last = y
    if editing and cv.w < 52:
        return ore_rows(cv, m, x, y + 1, right, stop)
    y += step
    if y <= stop:
        nx = chip(cv, x, y, "SINGLE", "single", "off" if m["continuous"] else "plain") + 1
        chip(cv, nx, y, "CONTINUOUS", "continuous", "plain" if m["continuous"] else "off")
    if m["continuous"]:
        y += step
        if y <= stop:
            cv.put(x, y, "branches" if vx - x >= 9 else "branch", "8")
            stepper(cv, vx, y, m["branches"], "set-branches", vw)
    if m.get("policy"):
        y += step
        if y <= stop:
            cv.put(x, y, "fuel", "8")
            nx = chip(cv, vx, y, "auto", "fuel-auto", "on" if m["policy"]["auto"] else "off") + 1
            chip(cv, nx, y, "out " + m["policy"]["out"], "fuel-output", "plain")
    y += step
    if y <= stop:
        cv.put(x, y, "turtles", "8")
        cv.put(vx, y, " ".join("#%d" % t["id"] for t in m["turtles"])[:right - vx + 1] or "-", "0")
    return max(last, y)


def ready_items(m):
    """The missing start checks, the unassigned turtles with their id, then the checks that pass."""
    items = [("e", text, None) for good, text in m["checks"] if not good]
    items += [("1", "#%d fuel %d" % (t["id"], t["fuel"]), t["id"]) for t in m["available"]]
    items += [("d", text, None) for good, text in m["checks"] if good]
    return items, sum(1 for good, _ in m["checks"] if good)


def ready_rows(cv, m, x, y, right, stop, page=0, lead=0):
    """READY from row y to row stop between x and right; lead pages come before the list (the
    narrow setup's controls). Returns the last row drawn (None on a lead page) and the pages."""
    items, ok = ready_items(m)
    cap = stop - y
    if cap < 1 or not items:
        return y - 1, 1
    pages = -(-len(items) // cap) + lead
    page %= pages
    if page < lead:
        return None, pages
    if pages > 1:
        section(cv, x, y, right - x + 1, "READY", "%d/%d" % (page + 1, pages))
    else:
        section(cv, x, y, right - x + 1, "READY", "%d/%d" % (ok, len(m["checks"])), "d" if ok == len(m["checks"]) else "1")
    last = y
    for mk, text, here in items[(page - lead) * cap:(page - lead + 1) * cap]:
        last += 1
        cv.put(x, last, "•", mk)
        cv.put(x + 2, last, text[:max(0, right - x - 1 - (6 if here else 0))], "0")
        if here:
            chip(cv, right - 4, last, "add", "here:%d" % here, "primary")
    return last, pages


def setup_room(cv, m, editing):
    w, h = cv.w, cv.h
    role_bar(cv, "MINING", TABS, SHORT, 1, m["state"], tone(m["state"]))
    cv.put(2, 2, "fuel ~%d" % m["fuelNeed"], "8")
    ya = last_row(h, True)
    rx = max(32, w // 2)
    left = setup_rows(cv, m, 2, 3, 2, 13, 8, rx - 3, editing, ya - 3)
    if editing:
        for i, name in enumerate(ORES):
            chip(cv, rx + 3, 3 + i, name, "ore-" + name, "plain" if ore_on(m, name) else "off")
        right = 3 + len(ORES) - 1
    else:
        right = ready_rows(cv, m, rx + 2, 3, w - 1, ya - 3)[0]
    for y in range(3, max(left, right) + 1):
        cv.put(rx, y, "|", "c")
    if m["alert"]:
        flag(cv, 2, ya - 2, w - 2, m["alert"])
    run_chips(cv, ya, m, 3)


def setup_column(cv, m, editing):
    w, h = cv.w, cv.h
    role_bar(cv, "MINING", TABS, SHORT, 1, m["state"], tone(m["state"]))
    cv.put(2, 2, "fuel ~%d" % m["fuelNeed"], "8")
    ya = last_row(h, False)
    wide = w >= 36
    stop = ya - 2 if m["alert"] else ya - 1
    vx, vw = (13, 8) if wide else (10, 6)
    # READY follows the controls; when it does not fit under them it gets pages of its own after
    # the controls' page, which ends with the READY row.
    last = setup_rows(Canvas(w, h, ""), m, 2, 3, 1, vx, vw, w - 1, editing, stop)
    if editing and last > stop - 1:
        if stop >= 3:
            cv.put(2, 3, "ores", "8")
            chip(cv, w - 7, 3, "BACK", "ores-edit", "plain")
        ore_rows(cv, m, 2, 5, w - 1, stop)
    elif len(ready_items(m)[0]) <= max(0, stop - last - 2):
        setup_rows(cv, m, 2, 3, 1, vx, vw, w - 1, editing, stop)
        ready_rows(cv, m, 2, last + 2, w - 1, stop)
    elif stop >= 4:
        shown, pages = ready_rows(cv, m, 2, 3, w - 1, stop, 0, 1)
        if shown is None:
            setup_rows(cv, m, 2, 3, 1, vx, vw, w - 1, editing, stop - 1)
            section(cv, 2, stop, w - 2, "READY", "1/%d" % pages)
    else:
        setup_rows(cv, m, 2, 3, 1, vx, vw, w - 1, editing, stop)
    if m["alert"]:
        flag(cv, 2, ya - 1, w - 2, m["alert"])
    run_chips(cv, ya, m, 1)


def mining(m, w, h, setup=False, editing=False, title=""):
    cv = Canvas(w, h, title)
    room = w >= 52 and h >= 22
    if setup and w >= 24:
        (setup_room if room else setup_column)(cv, m, editing)
    elif room:
        mine_room(cv, m)
    elif w >= 24 and h >= 14:
        mine_column(cv, m)
    else:
        mine_tiny(cv, m)
    return cv


# ================================================================ lumber

def lumber_model():
    """What so-mod-lumber's gather builds: the farm, its chests, the turtles and the facts."""
    a = S["area"]
    t = next(x for x in ST["turtles"] if x["job"] == "lumber")
    p = S["poses"][str(t["id"])]
    word = "lost" if ST["leases"].get(t["id"]) == "lost" else PHASES.get(t["state"], "working")
    chests = []
    for d in S["drops"]:
        if d["kind"] == "saplings":
            chests.insert(0, dict(x=d["x"], z=d["z"], label="saplings", broken=False))
        elif d["kind"] == "wood" and a["x1"] - 32 <= d["x"] <= a["x2"] + 32 and a["z1"] - 32 <= d["z"] <= a["z2"] + 32:
            chests.append(dict(x=d["x"], z=d["z"], label="wood", broken=d["broken"]))
    grow = ST["lumber"]["grow"] // 1000
    ready = sum(1 for s in S["spots"] if s["ready"])
    return dict(state="running" if ST["lumber"]["running"] else "stopped", alert=None,
                area=dict(x1=a["x1"], z1=a["z1"], x2=a["x2"], z2=a["z2"]), ground=a["ground"],
                spots=S["spots"], chests=chests,
                turtles=[dict(id=t["id"], facing=p["f"], x=p["x"], y=p["y"], z=p["z"], state=word, tone=tone(word))] +
                [dict(id=int(i), facing=int(f), x=int(x), y=int(y), z=int(z), state=st.replace("_", " "), tone=tone(st.replace("_", " ")))
                 for i, st, _, x, y, z, f in EXTRA.get("woodturtle", [])],
                ready=ready, total=len(S["spots"]), grow="%d:%02d" % (grow // 60, grow % 60),
                logs=ST["today"]["logs"], saplings=int(EXTRA["saplings"][0][0]),
                fuel=min([t["fuel"]] + [int(x[2]) for x in EXTRA.get("woodturtle", [])]),
                chest=next(dict(x=d["x"], y=d["y"], z=d["z"], side="front") for d in S["drops"] if d["kind"] == "saplings"))


def lumber_setup_facts(m):
    """S.readiness for the scene: the drop lines are the drop list with ids 1, 2, ...; the first
    turtle is the reference for the nearest chests; no turtle is paired."""
    points = [dict(d, id=str(i + 1)) for i, d in enumerate(x for x in S["drops"] if x["kind"] != "saplings")]
    first = m["turtles"][0]
    ready = [(True, "area ready"), (True, "ground %d" % m["ground"])]
    ready += [chest_check(points, kind, first) for kind in ("wood", "fuel")]
    ready.append((True, "saplings chest ready"))
    ready += [(True, "#%d tools unknown" % t["id"]) for t in sorted(m["turtles"], key=lambda t: t["id"])]
    ready.append((False, "paired turtle missing"))
    ready.append((True, "fuel ready" if len(m["turtles"]) > 1 else "fuel %d" % m["fuel"]))
    m["checks"] = ready
    m["available"] = [dict(id=int(a), fuel=int(b)) for a, b in EXTRA.get("candidate", [])]
    return m


def lumber_facts(m):
    fuel = m["fuel"]
    return [("ready", "%d/%d" % (m["ready"], m["total"]), "d" if m["ready"] > 0 else "8"),
            ("growing", str(m["total"] - m["ready"]), "0"),
            ("next grow", m["grow"] or "-", "0" if m["grow"] else "8"),
            ("logs", str(m["logs"]) if m["logs"] is not None else "-", "0" if m["logs"] is not None else "8"),
            ("saplings", str(m["saplings"]), "0" if m["saplings"] > 0 else "e"),
            ("fuel", str(fuel) if fuel is not None else "-", "8" if fuel is None else "1" if fuel < 80 else "0")]


def farm_plan(cv, m, x0, y0, pw, ph):
    """The farm at two columns per block when it fits, else squeezed; trees, chests and the turtle.
    Returns the last row drawn."""
    a = m["area"]
    if not a:
        return y0 - 1
    xs = [a["x1"], a["x2"]] + [c["x"] for c in m["chests"]]
    zs = [a["z1"], a["z2"]] + [c["z"] for c in m["chests"]]
    bx1, bx2, bz1, bz2 = min(xs), max(xs), min(zs), max(zs)
    room = max([0] + [len(c["label"]) + 1 for c in m["chests"]])
    num = next((n for n in (4, 3, 2, 1) if (bx2 - bx1) * n + 1 + room <= pw), 1)
    den = max(1, -(-(bx2 - bx1 + 1) // max(1, pw - room)))
    rz = 2 if (bz2 - bz1) * 2 + 1 <= ph and num >= 3 else 1
    zd = max(1, -(-(bz2 - bz1 + 1) // max(1, ph)))

    def col(x):
        return x0 + (x - bx1) * num // den

    def row(z):
        return y0 + (z - bz1) * rz // zd
    c1, c2, r1, r2 = col(a["x1"]), col(a["x2"]), row(a["z1"]), row(a["z2"])
    rule(cv, c1, r1, c2, "c")
    rule(cv, c1, r2, c2, "c")
    for y in range(r1, r2 + 1):
        cv.put(c1, y, "|", "c")
        cv.put(c2, y, "|", "c")
    for x, y in ((c1, r1), (c2, r1), (c1, r2), (c2, r2)):
        cv.put(x, y, "+", "c")
    trees = {}
    for s in m["spots"]:
        k = (col(s["x"]), row(s["z"]))
        trees[k] = trees.get(k) or s["ready"]
    for (x, y), ready in sorted(trees.items()):
        cv.put(x, y, "♠" if ready else "♣", "d" if ready else "8")
    for c in m["chests"]:
        x, y = col(c["x"]), row(c["z"])
        cv.put(x, y, "×" if c["broken"] else "•", "e" if c["broken"] else "0")
        lx = x + 2 if x > c2 or x >= c1 and x + 2 + len(c["label"]) <= x0 + pw else x - 1 - len(c["label"])
        cv.put(lx, y, c["label"], "e" if c["broken"] else "8")
    for t in m["turtles"]:
        if not bx1 <= t["x"] <= bx2 or not bz1 <= t["z"] <= bz2:
            continue
        x, y = col(t["x"]), row(t["z"])
        label = str(t["id"])
        for lx, ly in ((x + 1, y - 1), (x + 1, y + 1)):
            if all(cv.ok(lx + i, ly) and cv.cells[ly - 1][lx + i - 1][0] == 32 for i in range(len(label))) and \
                    all(not cv.ok(i, ly) or cv.cells[ly - 1][i - 1][0] in (32, 45, 124, 43)
                        for i in (lx - 1, lx + len(label))):
                cv.put(lx, ly, label, t["tone"])
                break
        cv.put(x, y, arrow(t["facing"]), t["tone"])
    return row(bz2)


def lumber_turtles(cv, m, top, stop):
    """The turtles from row top to row stop; +N more. Returns the last row drawn."""
    ts, nt = m["turtles"], stop - top + 1
    if not ts or nt < 1:
        return top - 1
    per = max(1, nt - 1) if len(ts) > nt else nt
    for i in range(nt):
        y = top + i
        if i == nt - 1 and len(ts) > nt:
            cv.put(4, y, "+%d more" % (len(ts) - min(per, len(ts))), "8")
            return y
        if i >= len(ts):
            return y - 1
        t = ts[i]
        cv.put(2, y, arrow(t["facing"]), t["tone"])
        cv.put(4, y, str(t["id"]), "0")
        cv.put(7, y, t["state"][:min(10, cv.w - 7)], state_fg(t["tone"]))
        # The position only when it fits whole.
        if len(where(t)) <= cv.w - 19:
            cv.put(18, y, where(t), "8")
    return top + nt - 1


def lumber_room(cv, m):
    w, h = cv.w, cv.h
    role_bar(cv, "LUMBER", TABS, SHORT, 0, m["state"], tone(m["state"]))
    ya = last_row(h, True)
    fx = w - 14
    facts = lumber_facts(m)
    for i, (a, b, c) in enumerate(facts):
        leader(cv, fx, 4 + 2 * i, 14, a, b, c)
    bottom = farm_plan(cv, m, 2, 4, min(fx - 5, 64), min(ya - 9, 32))
    last = lumber_turtles(cv, m, bottom + 3, ya - 3)
    for y in range(3, max(last, 4 + 2 * len(facts) - 2) + 1):
        cv.put(fx - 2, y, "|", "c")
    if m["alert"]:
        flag(cv, 2, ya - 2, w - 2, m["alert"])
    run_chips(cv, ya, m, 3)


def lumber_column(cv, m):
    w, h = cv.w, cv.h
    shown = role_bar(cv, "LUMBER", TABS, SHORT, 0, m["state"], tone(m["state"]))
    ya = last_row(h, False)
    run_chips(cv, ya, m, 1)
    facts = lumber_facts(m)
    end = ya - 2 - (alert_rows(cv, ya - 1, m["alert"]) if m["alert"] else 0)
    if w < 30:
        rows = ([] if shown else [("state", m["state"], state_fg(tone(m["state"])))]) + \
               [facts[0], facts[2], facts[5]]
        top = end - len(rows) + 1
        for i, (a, b, c) in enumerate(rows):
            leader(cv, 2, top + i, w - 2, a, b, c)
    else:
        lw = (w - 5) // 2
        rx = 2 + lw + 3
        top = end - 1
        for i, (j, k) in enumerate(((0, 4), (2, 5))):
            leader(cv, 2, top + i, lw, *facts[j])
            leader(cv, rx, top + i, w - rx, *facts[k])
    # Up to three turtle rows between the plan and the leaders.
    nt = max(0, min(len(m["turtles"]), 3, top - 8))
    if nt:
        top = top - 1 - nt
        lumber_turtles(cv, m, top, top + nt - 1)
        top -= 1
    farm_plan(cv, m, 2, 3, min(w - 1, 64), min(top - 3, 32))


def lumber_tiny(cv, m):
    shown = tiny_bar(cv, "LUMBER", m)
    f = lumber_facts(m)
    # Ready and grow, then the turtles; without turtles the other leaders.
    if m["turtles"]:
        tiny_rows(cv, m, [f[0], ("grow",) + f[2][1:]], shown, lambda y, stop: lumber_turtles(cv, m, y, stop))
    else:
        tiny_rows(cv, m, [f[0], ("grow",) + f[2][1:], f[4], f[5], f[3]], shown)


def lumber_setup(cv, m):
    w, h = cv.w, cv.h
    role_bar(cv, "LUMBER", TABS, SHORT, 1, m["state"], tone(m["state"]))
    room = w >= 52 and h >= 22
    ya = last_row(h, room)
    step = 2 if h >= 19 else 1
    vx = 13 if w >= 36 else 11
    rx = max(32, w // 2) if room else w + 2
    a, c = m["area"], m["chest"]
    ts = ["#%d %s" % (t["id"], where(t)) for t in m["turtles"]]
    rows = [("area", ["%d,%d %d,%d" % (a["x1"], a["z1"], a["x2"], a["z2"]) if a else "-"]),
            ("ground", [str(m["ground"]) if m["ground"] is not None else "-"]),
            ("saplings", ["%d,%d,%d %s" % (c["x"], c["y"], c["z"], c["side"]) if c else "-"]),
            ("turtles" if len(ts) > 1 else "turtle", ts or ["-"])]
    # Narrow screens put each value on its own line under its label.
    narrow = w < 36 and h >= 14

    def values(cv, y, stop):
        last = y - 1
        for label, vals in rows:
            if y + (1 if narrow else 0) > stop:
                break
            cv.put(2, y, label, "8")
            last = y
            for i, value in enumerate(vals):
                vy = y + i + (1 if narrow else 0)
                if vy > stop:
                    break
                if narrow:
                    cv.put(4, vy, value[:w - 4], "0" if value != "-" else "8")
                else:
                    cv.put(vx, vy, value[:min(w - 1, rx - 3) - vx + 1], "0" if value != "-" else "8")
                last = vy
            y += len(vals) - 1 + (3 if narrow else step)
        return last
    stop = ya - 2 if m["alert"] else ya - 1
    if room:
        last = values(cv, 3, ya - 2)
        right = ready_rows(cv, m, rx + 2, 3, w - 1, ya - 3)[0]
        for yy in range(3, max(last, right) + 1):
            cv.put(rx, yy, "|", "c")
    else:
        # READY follows the values; when it does not fit under them it gets pages of its own after
        # the values' page, which ends with the READY row.
        last = values(Canvas(w, h, ""), 3, ya - 2)
        if len(ready_items(m)[0]) <= max(0, stop - last - 2):
            ready_rows(cv, m, 2, values(cv, 3, ya - 2) + 2, w - 1, stop)
        elif stop >= 4:
            shown, pages = ready_rows(cv, m, 2, 3, w - 1, stop, 0, 1)
            if shown is None:
                values(cv, 3, min(ya - 2, stop - 1))
                section(cv, 2, stop, w - 2, "READY", "1/%d" % pages)
        else:
            values(cv, 3, ya - 2)
    if m["alert"]:
        flag(cv, 2, ya - (2 if room else 1), w - 2, m["alert"])
    run_chips(cv, ya, m, 3 if room else 1)


def lumber(m, w, h, setup=False, title=""):
    cv = Canvas(w, h, title)
    if setup and w >= 24:
        lumber_setup(cv, m)
    elif w < 24 or h < 14:
        lumber_tiny(cv, m)
    elif w >= 52 and h >= 22:
        lumber_room(cv, m)
    else:
        lumber_column(cv, m)
    return cv


# ================================================================ drop points

def drops_model(selected=None, editing=False, testing=False):
    """What so-mod-drops' gather builds: the points in list order, the selection, the plan's context,
    the unassigned turtles and the chests their scans found."""
    points = []
    verified = {int(x[0]) for x in EXTRA.get("verified", [])}
    room = {int(x[0]) for x in EXTRA.get("roompoint", [])}
    for d in S["drops"]:
        kind = "storage" if d["kind"] == "saplings" else d["kind"]
        points.append(dict(n=d["id"], id="0_%d_%d_%d_front_%s" % (d["x"], d["y"], d["z"], kind), dim=0, kind=kind,
                           x=d["x"], y=d["y"], z=d["z"], side="front", broken=d["broken"],
                           verified=d["id"] in verified, room=d["id"] in room))
    if selected is None:
        selected = next((p["id"] for p in points if p["broken"]), points[0]["id"] if points else None)
    g, a = S["g"], S["area"]
    return dict(points=points, selected=selected, page=1, editing=editing, testing=testing, message=None,
                roomSink=False, turtles=[int(a) for a, _ in EXTRA.get("candidate", [])], start=0, compass=None, task=None, failed=None,
                found=[dict(x=int(x), y=int(y), z=int(z), side=sd) for x, y, z, sd in EXTRA.get("found", [])],
                server=dict(x=S["server"][0], z=S["server"][2]), shaft=dict(x=g["x"], z=g["z"]),
                area=dict(x1=a["x1"], z1=a["z1"], x2=a["x2"], z2=a["z2"]),
                draft=dict(dim=0, x=126, y=64, z=-337, side="front", kind="ore"))


SX = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]


def drop_plan(cv, m, x0, y0, pw, ph, draft=None):
    """A plan of the chests around home, one block per cell when it fits, labelled by number;
    the server, the shaft and the farm edge for context. Returns the last row drawn."""
    dim = next((p["dim"] for p in m["points"] if p["id"] == m["selected"]), 0)
    if draft:
        dim = draft["dim"]
    pts = [p for p in m["points"] if p["dim"] == dim]
    items = [(p["x"], p["z"]) for p in pts]
    if dim != 0:  # the server, the shaft and the farm are in the overworld
        m = dict(points=m["points"], selected=m["selected"], server=None, shaft=None, area=None)
    if draft and items and not (min(i[0] for i in items) - 32 <= draft["x"] <= max(i[0] for i in items) + 32 and
                                min(i[1] for i in items) - 32 <= draft["z"] <= max(i[1] for i in items) + 32):
        draft = None
    if draft:
        items.append((draft["x"], draft["z"]))
    if not items:
        return y0 - 1
    if y0 > 2:  # north is up, as on the map; the compass sits on the row above the plan
        cv.put(x0 + pw - 2, y0 - 1, "↑N", "8")
    if m["server"]:
        items.append((m["server"]["x"], m["server"]["z"]))
    if m["shaft"]:
        items.append((m["shaft"]["x"], m["shaft"]["z"]))
    if m["area"]:  # both farm corners are in the fit, so the farm edge is never cut
        items += [(m["area"]["x1"], m["area"]["z1"]), (m["area"]["x2"], m["area"]["z2"])]
    bx1, bx2 = min(i[0] for i in items), max(i[0] for i in items)
    bz1, bz2 = min(i[1] for i in items), max(i[1] for i in items)
    s = next((v for v in SX if (bx2 - bx1) // v + 1 <= pw - 4 and (bz2 - bz1) // v + 1 <= ph), SX[-1])
    cols, rows = (bx2 - bx1) // s + 1, (bz2 - bz1) // s + 1
    left = bx1 - (pw - cols) // 2 * s
    top = bz1 - (ph - rows) // 2 * s

    def cell(x, z):
        c, r = (x - left) // s, (z - top) // s
        return (x0 + c, y0 + r) if 0 <= c < pw and 0 <= r < ph else None
    taken, marks = {}, []
    a = m["area"]
    if a:
        c1, c2 = cell(a["x1"], a["z1"]), cell(a["x2"], a["z2"])
        if c1 and c2:
            for x in range(c1[0], c2[0] + 1):
                for y in (c1[1], c2[1]):
                    cv.put(x, y, "-", "c")
                    taken[(x, y)] = True
            for y in range(c1[1], c2[1] + 1):
                for x in (c1[0], c2[0]):
                    cv.put(x, y, "|", "c")
                    taken[(x, y)] = True
            for p in ((c1[0], c1[1]), (c2[0], c1[1]), (c1[0], c2[1]), (c2[0], c2[1])):
                cv.put(p[0], p[1], "+", "c")
    if m["shaft"]:
        marks.append((cell(m["shaft"]["x"], m["shaft"]["z"]), "º", "9", None, "shaft", "8", None))
    if m["server"]:
        marks.append((cell(m["server"]["x"], m["server"]["z"]), "@", "9", None, "server", "8", None))
    for p in pts:
        c = "e" if p["broken"] else "0"
        inv = c if p["id"] == m["selected"] and not draft else None
        marks.append((cell(p["x"], p["z"]), "×" if p["broken"] else "•", c, inv, str(p["n"]), "e" if p["broken"] else "8",
                      None if draft else "select:" + p["id"]))
    if draft:
        marks.append((cell(draft["x"], draft["z"]), "•", "9", "9", None, None, None))
    drawn = []
    for at, glyph, fg, inv, label, lfg, bid in marks:
        if not at:
            continue
        cv.put(at[0], at[1], glyph, "f" if inv else fg, inv)
        if bid:
            cv.hit(bid, at[0], at[1], 1, 1)
        taken[at] = True
        drawn.append((at, label, lfg))
    for at, label, lfg in drawn:
        if not label:
            continue
        for x in (at[0] + 1, at[0] - len(label)):
            span = [(x + j, at[1]) for j in range(-1, len(label) + 1)]
            if x >= x0 and x + len(label) <= x0 + pw and \
                    not any(q in taken and q != at for q in span):
                cv.put(x, at[1], label, lfg)
                for q in span[1:-1]:
                    taken[q] = True
                break
    return y0 + ph - 1


def drop_pages(n, cap):
    return max(1, -(-n // max(1, cap)))


OK_TEXT = {"chest found", "scan complete", "setup released", "scanning", "testing chest", "confirming release",
           "room saved", "point added"}


def drops_list(cv, m):
    w, h = cv.w, cv.h
    room = w >= 52 and h >= 22
    ya = last_row(h, room)
    pts = m["points"]
    broken = [p for p in pts if p["broken"]]
    nf = min(len(broken), 2 if h >= 19 else 1)
    lw = 34 if room else w - 1
    head = 4 if h >= 14 else 3
    cap = max(1, min(24, ya - 1 - (nf + 1 if nf else 0) - head - (1 if room else 0) + 1))
    pages = drop_pages(len(pts), cap)
    page = min(m["page"], pages)
    right, roomy = str(len(pts)), w >= 30
    if pages > 1:
        right = ("    %d/%d    " if roomy else " %d/%d ") % (page, pages)
    bar(cv, "DROP POINTS" if roomy else "DROPS", [], None, right, "8")
    if pages > 1:
        chip(cv, w - len(right), 1, "◄", "prev", "plain", 3 if roomy else 1)
        chip(cv, w - (3 if roomy else 1), 1, "►", "next", "plain", 3 if roomy else 1)
    wide = lw >= 34
    wx = 15 if wide else 13
    if head == 4:
        cv.put(2, 3, "id", "8")
        cv.put(5, 3, "kind", "8")
        cv.put(wx, 3, "where", "8")
        if wide:
            cv.put(28, 3, "side", "8")
    for i, p in enumerate(pts[(page - 1) * cap:page * cap]):
        y = head + i
        sel = p["id"] == m["selected"]
        bg = "7" if sel else None
        if sel:
            cv.fill(1, y, lw, 1, "7")
        c = "e" if p["broken"] else "0"
        # Room points read "ore room" where it fits, muted while room sinks are off.
        kind = p["kind"] + " room" if p["room"] and len(p["kind"]) + 5 <= wx - 6 else p["kind"]
        cv.put(2, y, str(p["n"]), c, bg)
        cv.put(5, y, kind[:wx - 6], "8" if p["room"] and not m["roomSink"] and not p["broken"] else c, bg)
        if wide:
            cv.put(15, y, where(p)[:12], "8", bg)
            cv.put(28, y, p["side"], "8", bg)
        else:
            cv.put(13, y, where(p)[:lw - 14], "8", bg)
        cv.put(lw, y, "×" if p["broken"] else "•" if p["verified"] else "·",
               "e" if p["broken"] else "d" if p["verified"] else "8", bg)
        cv.hit("select:" + p["id"], 1, y, lw, 1)
    first_flag = head + len(pts[(page - 1) * cap:page * cap]) + 1
    for i, p in enumerate(broken[:nf]):
        text = "%d %s broken" % (p["n"], p["kind"])
        if i == nf - 1 and len(broken) > nf:
            text = "%d broken" % len(broken)
        flag(cv, 2, first_flag + i, lw - 1, text)
    sel = next((p for p in pts if p["id"] == m["selected"]), None)
    tag = " %d" % sel["n"] if sel else ""
    # SCAN opens chest setup from 24 columns; narrow rows shorten REMOVE before they cut it.
    n, gap = (4 if w >= 24 else 3), (2 if room else 1)
    bw = (w - 2 - gap * (n - 1)) // n
    fix, rem = "FIX" + tag, "REMOVE" + tag
    if len(rem) > bw:
        fix, rem = "FIX", "REMOVE"
    if n == 4 and len(rem) > bw:
        rem = "DEL"
    items = [(fix, "fix", "primary" if sel and sel["broken"] else "muted"),
             (rem, "remove", "stop" if sel else "muted"), ("ADD", "new", "plain")]
    if n == 4:
        items.append(("SCAN", "testing", "plain"))
    actions(cv, ya, items, gap)
    if room:
        bottom = drop_plan(cv, m, 38, 3, min(w - 38, 48), min(ya - 4, 32))
        for y in range(3, bottom + 1):
            cv.put(36, y, "|", "c")


def drops_editor(cv, m):
    w, h = cv.w, cv.h
    room = w >= 52 and h >= 22
    ya = last_row(h, room)
    bar(cv, "ADD DROP POINT", [], None, "", "8")
    d = m["draft"]
    step = 2 if h >= 19 else 1
    vx, vw = (13, 8) if w >= 36 else (8, 6)
    y = 3 if h >= 12 else 2
    for label, kind in (("kind", "kind"), ("side", "side")):
        if w < 24:
            chip(cv, 2, y, d[kind], kind, "plain", w - 2)
        else:
            cv.put(2, y, label, "8")
            chip(cv, vx, y, d[kind], kind, "plain", vw + 9)
        y += step
    for field in ("dim", "x", "y", "z"):
        if y > ya - 2:
            break
        cv.put(2, y, field, "8")
        if w < 24:
            cv.put(3 + len(field), y, str(d[field])[:max(0, w - 10 - len(field))], "0")
            chip(cv, w - 7, y, "-", field + "-")
            chip(cv, w - 3, y, "+", field + "+")
        else:
            stepper(cv, vx, y, d[field], field, vw)
        y += step
    if w >= 24 and y <= ya - 2:
        cv.put(2, y, "room", "8")
        nx = chip(cv, vx, y, "point", "room-point", "on" if d.get("room") else "off") + 1
        chip(cv, nx, y, "sinks", "room-sink", "on" if m["roomSink"] else "off")
        y += step
    # The draft from a turtle's position: the cell ahead, or below for a down point.
    if w >= 24 and m["turtles"] and y <= ya - 2:
        cv.put(2, y, "from", "8")
        scroll(cv, ["#%d" % t for t in m["turtles"]], m["start"], vx, y, vx + vw + 11 if room else w - 1)
    msg = m["message"]
    if msg:
        if msg in OK_TEXT:
            cv.put(2, ya - 1, msg, "d")
        else:
            flag(cv, 2, ya - 1, w - 2, msg)
    actions(cv, ya, [("ADD", "add", "primary"), ("BACK", "list", "plain")], 3 if room else 1)
    if room:
        rx = vx + vw + 13
        bottom = drop_plan(cv, m, rx + 2, 3, min(w - rx - 2, 48), min(ya - 4, 32), d)
        for yy in range(3, bottom + 1):
            cv.put(rx, yy, "|", "c")


def scroll(cv, labels, first, x, y, right):
    """Chips in one row from x to right, starting at item first (wrapping); a + chip scrolls on."""
    first %= len(labels)
    shown = 0
    for k in range(first, len(labels)):
        if x + len(labels[k]) + 1 + (4 if k < len(labels) - 1 or first > 0 else 0) > right:
            break
        x = chip(cv, x, y, labels[k], "from:" + labels[k][1:], "plain") + 1
        shown += 1
    if shown < len(labels):
        chip(cv, x, y, "+", "from-next", "plain")


def drops_facing(cv, m, y, w):
    """A turtle without a facing asks for it first; CANCEL drops the prompt."""
    section(cv, 2, y, w - 2, "FACING #%d" % m["compass"]["id"])
    x = 2
    for i, label in enumerate(("N", "E", "S", "W")):
        x = chip(cv, x, y + 1, label, "facing:%d" % i, "primary", 5) + 1
    chip(cv, 2, y + 3, "cancel", "facing-cancel", "plain")


def drops_setup(cv, m):
    """Chest setup with an idle turtle: the selected point, the turtles to scan with (RELEASE on the
    one doing setup), the chests the scans found, and TEST, FIX and BACK."""
    w, h = cv.w, cv.h
    room = w >= 52 and h >= 22
    ya = last_row(h, room)
    stop = ya - 2
    bar(cv, "CHEST SETUP" if w >= 30 else "SETUP", [], None, "", "8")
    sel = next((p for p in m["points"] if p["id"] == m["selected"]), None)
    cv.put(2, 3, "point", "8")
    # Narrow screens drop the kind, then the side, before they cut the position.
    text = "-"
    if sel:
        for text in ("%d %s %s %s" % (sel["n"], sel["kind"], where(sel), sel["side"]),
                     "%d %s %s" % (sel["n"], where(sel), sel["side"]), "%d %s" % (sel["n"], where(sel))):
            if len(text) <= w - 9:
                break
    cv.put(8, 3, text[:max(0, w - 9)], ("e" if sel["broken"] else "0") if sel else "8")
    y = 5
    if m["compass"]:
        drops_facing(cv, m, y, w)
        items = []
    else:
        items = [("TURTLES", t, None) for t in m["turtles"]]
        if m["task"] is not None and m["task"] not in m["turtles"]:
            items.append(("TURTLES", m["task"], None))
        items = items or [("TURTLES", None, None)]
        items += [("FOUND", i + 1, p) for i, p in enumerate(m["found"])]
    k, section_ = m["start"] % max(1, len(items)), None
    while k < len(items) and y <= stop:
        name, n, p = items[k]
        if name != section_:
            if y + 1 > stop:
                break
            section_ = name
            section(cv, 2, y, w - 2, name)
            y += 1
        if y == stop and k < len(items) - 1:
            cv.put(4, y, "+%d more" % (len(items) - k), "8")
            break
        if p:
            cv.put(2, y, "•", "0")
            cv.put(4, y, ("%s %s" % (where(p), p["side"]))[:max(0, w - 10)], "0")
            chip(cv, w - 5, y, "add", "candidate:%d" % n, "plain")
        elif n is not None:
            busy = m["task"] == n
            cv.put(2, y, "•", ("e" if m["failed"] else "1") if busy else "d")
            cv.put(4, y, "#%d" % n, "0")
            if busy:
                chip(cv, w - 9, y, "release", "release", "stop")
            else:
                chip(cv, w - 6, y, "scan", "scan:%d" % n, "primary")
        else:
            cv.put(4, y, "-", "8")
        y, k = y + 1, k + 1
    msg = m["message"]
    if msg:
        if msg in OK_TEXT:
            cv.put(2, ya - 1, msg, "d")
        else:
            flag(cv, 2, ya - 1, w - 2, msg)
    actions(cv, ya, [("TEST", "test", "primary" if sel else "muted"),
                     ("FIX", "fix", "primary" if sel and sel["broken"] else "muted"),
                     ("BACK", "list", "plain")], 2 if room else 1)


def drops(m, w, h, title=""):
    cv = Canvas(w, h, title)
    (drops_editor if m["editing"] else drops_setup if m["testing"] else drops_list)(cv, m)
    return cv


# ================================================================ fixtures

def _mining(w, h, title, setup=False, editing=False, empty=False):
    return lambda: mining(mining_model(empty), w, h, setup, editing, title)


def _lumber(w, h, title, setup=False):
    return lambda: lumber(lumber_setup_facts(lumber_model()) if setup else lumber_model(), w, h, setup, title)


def _drops(w, h, title, editing=False, testing=False):
    return lambda: drops(drops_model(editing=editing, testing=testing), w, h, title)


FIXTURES = [
    ("mining-M", _mining(57, 24, "Mining, room monitor 57x24")),
    ("mining-W", _mining(100, 38, "Mining, wall 100x38")),
    ("mining-L", _mining(39, 19, "Mining, wall monitor 4x3 at scale 1")),
    ("mining-P", _mining(26, 20, "Mining at 26x20")),
    ("mining-XS", _mining(15, 10, "Mining, smallest monitor")),
    ("miningempty-M", _mining(57, 24, "Mining before the first branch, room monitor 57x24", empty=True)),
    ("miningempty-W", _mining(100, 38, "Mining before the first branch, wall 100x38", empty=True)),
    ("miningsetup-M", _mining(57, 24, "Mining setup, room monitor 57x24", True)),
    ("miningsetup-L", _mining(39, 19, "Mining setup, wall monitor 4x3", True)),
    ("miningsetup-P", _mining(26, 20, "Mining setup at 26x20", True)),
    ("miningsetup-29x12", _mining(29, 12, "Mining setup at 29x12", True)),
    ("miningores-29x12", _mining(29, 12, "Mining ore editor at 29x12", True, True)),
    ("miningores-M", _mining(57, 24, "Mining setup with the ore list open", True, True)),
    ("miningores-P", _mining(26, 20, "Mining setup at 26x20 with the ore list open", True, True)),
    ("lumber-M", _lumber(57, 24, "Lumber, room monitor 57x24")),
    ("lumber-W", _lumber(100, 38, "Lumber, wall 100x38")),
    ("lumber-L", _lumber(39, 19, "Lumber, wall monitor 4x3 at scale 1")),
    ("lumber-P", _lumber(26, 20, "Lumber at 26x20")),
    ("lumber-XS", _lumber(15, 10, "Lumber, smallest monitor")),
    ("lumbersetup-M", _lumber(57, 24, "Lumber setup, room monitor 57x24", True)),
    ("lumbersetup-P", _lumber(26, 20, "Lumber setup at 26x20", True)),
    ("drops-M", _drops(57, 24, "Drop points, room monitor 57x24")),
    ("drops-L", _drops(39, 19, "Drop points, wall monitor 4x3 at scale 1")),
    ("drops-P", _drops(26, 20, "Drop points at 26x20")),
    ("drops-XS", _drops(15, 10, "Drop points, smallest monitor")),
    ("dropsadd-M", _drops(57, 24, "Add a drop point, room monitor 57x24", True)),
    ("dropsadd-P", _drops(26, 20, "Add a drop point at 26x20", True)),
    ("dropsadd-XS", _drops(15, 10, "Add a drop point, smallest monitor", True)),
    ("dropssetup-M", _drops(57, 24, "Chest setup, room monitor 57x24", testing=True)),
    ("dropssetup-P", _drops(26, 20, "Chest setup at 26x20", testing=True)),
]
