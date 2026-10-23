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

ORES = ["coal", "copper", "iron", "gold", "redstone", "lapis", "diamond"]
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

def mining_model():
    """What so-mod-mine's gather builds: job facts, one row per turtle, the dug extent per branch."""
    g = S["g"]
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
    job = dict(home=dict(x=g["home"][0], y=g["home"][1], z=g["home"][2], facing=hf), homeSet=True,
               bottom=g["bottom"], length=g["length"], mode=g["mode"], ores=[],
               running=ST["mining"]["running"], done=ST["mining"]["done"], total=ST["mining"]["total"])
    return mining_gather(job, rows, ST["today"]["ore"], None)


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
             ores=job["ores"])
    for row in sorted(rows, key=lambda x: x["id"]):
        p = row["pose"]
        word = "lost" if row["lost"] else row["state"]
        t = dict(id=row["id"], facing=(p["facing"] - h["facing"]) % 4, state=word, tone=tone(word),
                 where="lane" if row["lane"] else "b%d" % (row["branch"] + 1) if row["branch"] is not None else "-",
                 at=where(p), fuel=row["fuel"], ore=row["ores"], lost=row["lost"], spine=False, row=None, along=0)
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
        cv.put(18, y, t["where"][:5], "8")
        cv.put(24, y, t["at"][:max(0, right - 36)], "e" if t["lost"] else "8")
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
    for i, (a, b, c) in enumerate(mining_facts(m)):
        leader(cv, lx, 3 + i, 11, a, b, c)
    run_chips(cv, ya, m, 3)
    if m["alert"]:
        flag(cv, 2, ya - 2, w - 2, m["alert"])
    # Caps keep the biggest walls inside the 16 KB frame: 12 turtle rows, 24 branch rows.
    nt = min(len(m["turtles"]), max(0, ya - 12), 12)
    shown = min(m["total"], ya - 3 - nt - (1 if nt else 0) - 6 + 1, 24)
    diagram(cv, m, 3, shown, lx - 2)
    turtle_rows(cv, m, 3 + shown + 3, nt, lx + 10)


def mine_column(cv, m):
    w, h = cv.w, cv.h
    shown = role_bar(cv, "MINING", TABS, SHORT, 0, m["state"], tone(m["state"]))
    ya = last_row(h, False)
    run_chips(cv, ya, m, 1)
    if m["alert"]:
        flag(cv, 2, ya - 1, w - 2, m["alert"])
    facts = mining_facts(m)
    end = ya - 2 - (1 if m["alert"] else 0)
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
    diagram(cv, m, 3, top - 6, w - 1)


def tiny_rows(cv, m, rows, shown):
    """Leaders from row 3 (2 on very short screens) to h-2, the alert on h-1, the actions on h."""
    w, h = cv.w, cv.h
    if not shown:
        rows = [("state", m["state"], state_fg(tone(m["state"])))] + rows
    y = 3 if h >= 6 else 2
    for a, b, c in rows:
        if y > h - 2:
            break
        leader(cv, 2, y, w - 2, a, b, c)
        y += 1
    if m["alert"] and h >= 4:
        flag(cv, 2, h - 1, w - 2, m["alert"])
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
    tiny_rows(cv, m, [f[0], f[3], f[1], f[5], f[4]], shown)


# ---------------------------------------------------------------- mining setup

def home_text(m):
    h = m["home"]
    return "%d,%d,%d %s" % (h["x"], h["y"], h["z"], "nesw"[h["facing"]]) if m["homeSet"] else "-"


def ore_text(m):
    return ",".join(m["ores"]) if m["ores"] and len(m["ores"]) < len(ORES) else "all"


def ore_on(m, name):
    return not m["ores"] or name in m["ores"]


def setup_rows(cv, m, x, y, step, vx, vw, right, editing):
    """The setup controls from row y, step rows apart. Returns the last row drawn."""
    def label(text):
        cv.put(x, y, text, "8")
    label("home")
    cv.put(vx, y, home_text(m)[:right - vx + 1], "0" if m["homeSet"] else "8")
    y += step
    label("bottom")
    stepper(cv, vx, y, "Y %d" % m["bottom"], "set-bottom", vw)
    y += step
    label("length")
    stepper(cv, vx, y, m["length"], "set-length", vw)
    y += step
    label("mode")
    nx = chip(cv, vx, y, "fast", "mode-fast", "plain" if m["mode"] == "fast" else "off") + 1
    chip(cv, nx, y, "thorough", "mode-thorough", "plain" if m["mode"] == "thorough" else "off")
    y += step
    label("ores")
    ex = right - 5
    cv.put(vx, y, ore_text(m)[:max(0, ex - vx - 1)], "0")
    chip(cv, ex, y, "edit", "ores-edit", "on" if editing else "plain")
    last = y
    if editing and cv.w < 52:
        cx, y = x, y + 1
        for name in ORES:
            if cx + len(name) + 2 > right + 1:
                cx, y = x, y + 1
            cx = chip(cv, cx, y, name, "ore-" + name, "plain" if ore_on(m, name) else "off") + 1
        return y
    y += step
    label("turtles")
    cv.put(vx, y, " ".join("#%d" % t["id"] for t in m["turtles"])[:right - vx + 1] or "-", "0")
    return max(last, y)


def setup_room(cv, m, editing):
    w, h = cv.w, cv.h
    role_bar(cv, "MINING", TABS, SHORT, 1, m["state"], tone(m["state"]))
    ya = last_row(h, True)
    rx = w - 19
    left = setup_rows(cv, m, 2, 3, 2, 13, 8, rx - 3, editing)
    px = rx + 3
    if editing:
        for i, name in enumerate(ORES):
            chip(cv, px, 3 + i, name, "ore-" + name, "plain" if ore_on(m, name) else "off")
        right = 3 + len(ORES) - 1
    else:
        n = min(10, ya - 2 - 3 - 4)
        for i in range(n):
            b, y = n - i, 3 + i
            cv.put(px + 2 - len(str(b)), y, str(b), "8")
            cv.put(px + 3, y, "+", "3")
            for x in range(px + 4, w):
                cv.put(x, y, "·", "8")
        cv.put(px + 3, 3 + n, "|", "3")
        cv.put(px + 3, 4 + n, "º", "9")
        cv.put(px, 6 + n, "%d × %d" % (n * m["gap"], m["length"]), "8")
        right = 6 + n
    for y in range(3, max(left, right) + 1):
        cv.put(rx, y, "|", "c")
    if m["alert"]:
        flag(cv, 2, ya - 2, w - 2, m["alert"])
    run_chips(cv, ya, m, 3)


def setup_column(cv, m, editing):
    w, h = cv.w, cv.h
    role_bar(cv, "MINING", TABS, SHORT, 1, m["state"], tone(m["state"]))
    ya = last_row(h, False)
    wide = w >= 36
    setup_rows(cv, m, 2, 3, 2 if h >= 19 else 1, 13 if wide else 10, 8 if wide else 6, w - 1, editing)
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
    """What so-mod-lumber's gather builds: the farm, its chests, the turtle and the facts."""
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
                turtle=dict(id=t["id"], facing=p["f"], x=p["x"], y=p["y"], z=p["z"], state=word, tone=tone(word)),
                ready=ready, total=len(S["spots"]), grow="%d:%02d" % (grow // 60, grow % 60),
                logs=ST["today"]["logs"], saplings=int(EXTRA["saplings"][0][0]), fuel=t["fuel"],
                chest=next(dict(x=d["x"], y=d["y"], z=d["z"], side="front") for d in S["drops"] if d["kind"] == "saplings"))


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
    t = m["turtle"]
    if t and bx1 <= t["x"] <= bx2 and bz1 <= t["z"] <= bz2:
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


def lumber_turtle(cv, m, y):
    t = m["turtle"]
    if not t:
        return
    cv.put(2, y, arrow(t["facing"]), t["tone"])
    cv.put(4, y, str(t["id"]), "0")
    cv.put(7, y, t["state"][:10], state_fg(t["tone"]))
    cv.put(18, y, where(t)[:max(0, cv.w - 19)], "8")


def lumber_room(cv, m):
    w, h = cv.w, cv.h
    role_bar(cv, "LUMBER", TABS, SHORT, 0, m["state"], tone(m["state"]))
    ya = last_row(h, True)
    fx = w - 14
    facts = lumber_facts(m)
    for i, (a, b, c) in enumerate(facts):
        leader(cv, fx, 4 + 2 * i, 14, a, b, c)
    bottom = farm_plan(cv, m, 2, 4, min(fx - 5, 64), min(ya - 9, 32))
    lumber_turtle(cv, m, bottom + 3)
    for y in range(3, max(bottom + 3, 4 + 2 * len(facts) - 2) + 1):
        cv.put(fx - 2, y, "|", "c")
    if m["alert"]:
        flag(cv, 2, ya - 2, w - 2, m["alert"])
    run_chips(cv, ya, m, 3)


def lumber_column(cv, m):
    w, h = cv.w, cv.h
    shown = role_bar(cv, "LUMBER", TABS, SHORT, 0, m["state"], tone(m["state"]))
    ya = last_row(h, False)
    run_chips(cv, ya, m, 1)
    if m["alert"]:
        flag(cv, 2, ya - 1, w - 2, m["alert"])
    facts = lumber_facts(m)
    end = ya - 2 - (1 if m["alert"] else 0)
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
    farm_plan(cv, m, 2, 3, min(w - 1, 64), min(top - 3, 32))


def lumber_tiny(cv, m):
    shown = tiny_bar(cv, "LUMBER", m)
    f = lumber_facts(m)
    tiny_rows(cv, m, [f[0], ("grow",) + f[2][1:], f[4], f[5], f[3]], shown)


def lumber_setup(cv, m):
    w, h = cv.w, cv.h
    role_bar(cv, "LUMBER", TABS, SHORT, 1, m["state"], tone(m["state"]))
    room = w >= 52 and h >= 22
    ya = last_row(h, room)
    step = 2 if h >= 19 else 1
    vx = 13 if w >= 36 else 11
    a, c, t = m["area"], m["chest"], m["turtle"]
    rows = [("area", "%d,%d %d,%d" % (a["x1"], a["z1"], a["x2"], a["z2"]) if a else "-"),
            ("ground", str(m["ground"]) if m["ground"] is not None else "-"),
            ("saplings", "%d,%d,%d %s" % (c["x"], c["y"], c["z"], c["side"]) if c else "-"),
            ("turtle", "#%d %s" % (t["id"], where(t)) if t else "-")]
    # Narrow screens put each value on its own line under its label.
    narrow = w < 36 and h >= 14
    for i, (label, value) in enumerate(rows):
        y = 3 + i * (3 if narrow else step)
        if y + (1 if narrow else 0) > ya - 2:
            break
        cv.put(2, y, label, "8")
        if narrow:
            cv.put(4, y + 1, value[:w - 4], "0" if value != "-" else "8")
        else:
            cv.put(vx, y, value[:w - vx], "0" if value != "-" else "8")
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

def drops_model(selected=None, editing=False):
    """What so-mod-drops' gather builds: the points in list order, the selection, the plan's context."""
    points = []
    for d in S["drops"]:
        kind = "storage" if d["kind"] == "saplings" else d["kind"]
        points.append(dict(n=d["id"], id="0_%d_%d_%d_front_%s" % (d["x"], d["y"], d["z"], kind), kind=kind,
                           x=d["x"], y=d["y"], z=d["z"], side="front", broken=d["broken"]))
    if selected is None:
        selected = next((p["id"] for p in points if p["broken"]), points[0]["id"] if points else None)
    g, a = S["g"], S["area"]
    return dict(points=points, selected=selected, page=1, editing=editing, message=None,
                server=dict(x=S["server"][0], z=S["server"][2]), shaft=dict(x=g["x"], z=g["z"]),
                area=dict(x1=a["x1"], z1=a["z1"], x2=a["x2"], z2=a["z2"]),
                draft=dict(dim=0, x=126, y=64, z=-337, side="front", kind="ore"))


SX = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]


def drop_plan(cv, m, x0, y0, pw, ph, draft=None):
    """A plan of the chests around home, one block per cell when it fits, labelled by number;
    the server, the shaft and the farm edge for context. Returns the last row drawn."""
    pts = m["points"]
    items = [(p["x"], p["z"]) for p in pts]
    if draft and items and not (min(i[0] for i in items) - 32 <= draft["x"] <= max(i[0] for i in items) + 32 and
                                min(i[1] for i in items) - 32 <= draft["z"] <= max(i[1] for i in items) + 32):
        draft = None
    if draft:
        items.append((draft["x"], draft["z"]))
    if not items:
        return y0 - 1
    if m["server"]:
        items.append((m["server"]["x"], m["server"]["z"]))
    if m["shaft"]:
        items.append((m["shaft"]["x"], m["shaft"]["z"]))
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
    wide = lw >= 30
    if head == 4:
        cv.put(2, 3, "id", "8")
        cv.put(5, 3, "kind", "8")
        cv.put(15 if wide else 14, 3, "where", "8")
        if wide:
            cv.put(29, 3, "side", "8")
    for i, p in enumerate(pts[(page - 1) * cap:page * cap]):
        y = head + i
        sel = p["id"] == m["selected"]
        bg = "7" if sel else None
        if sel:
            cv.fill(1, y, lw, 1, "7")
        c = "e" if p["broken"] else "0"
        cv.put(2, y, str(p["n"]), c, bg)
        cv.put(5, y, p["kind"][:8], c, bg)
        if wide:
            cv.put(15, y, where(p)[:13], "8", bg)
            cv.put(29, y, p["side"], "8", bg)
        else:
            cv.put(14, y, where(p)[:lw - 14], "8", bg)
        cv.hit("select:" + p["id"], 1, y, lw, 1)
    first_flag = head + len(pts[(page - 1) * cap:page * cap]) + 1
    for i, p in enumerate(broken[:nf]):
        text = "%d %s broken" % (p["n"], p["kind"])
        if i == nf - 1 and len(broken) > nf:
            text = "%d broken" % len(broken)
        flag(cv, 2, first_flag + i, lw - 1, text)
    sel = next((p for p in pts if p["id"] == m["selected"]), None)
    tag = " %d" % sel["n"] if sel else ""
    fix, rem = "FIX" + tag, "REMOVE" + tag
    n3 = (w - 2 - 2 * (2 if room else 1)) // 3
    if len(rem) > n3:
        fix, rem = "FIX", "REMOVE"
    actions(cv, ya, [(fix, "fix", "primary" if sel and sel["broken"] else "muted"),
                     (rem, "remove", "stop" if sel else "muted"), ("ADD", "new", "plain")], 2 if room else 1)
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
    msg = m["message"]
    if msg:
        if msg == "point added":
            cv.put(2, ya - 1, msg, "d")
        else:
            flag(cv, 2, ya - 1, w - 2, msg)
    actions(cv, ya, [("ADD", "add", "primary"), ("BACK", "list", "plain")], 3 if room else 1)
    if room:
        rx = vx + vw + 13
        bottom = drop_plan(cv, m, rx + 2, 3, min(w - rx - 2, 48), min(ya - 4, 32), d)
        for yy in range(3, bottom + 1):
            cv.put(rx, yy, "|", "c")


def drops(m, w, h, title=""):
    cv = Canvas(w, h, title)
    (drops_editor if m["editing"] else drops_list)(cv, m)
    return cv


# ================================================================ fixtures

def _mining(w, h, title, setup=False, editing=False):
    return lambda: mining(mining_model(), w, h, setup, editing, title)


def _lumber(w, h, title, setup=False):
    return lambda: lumber(lumber_model(), w, h, setup, title)


def _drops(w, h, title, editing=False):
    return lambda: drops(drops_model(editing=editing), w, h, title)


FIXTURES = [
    ("mining-M", _mining(57, 24, "Mining, room monitor 57x24")),
    ("mining-W", _mining(100, 38, "Mining, wall 100x38")),
    ("mining-L", _mining(39, 19, "Mining, wall monitor 4x3 at scale 1")),
    ("mining-P", _mining(26, 20, "Mining at 26x20")),
    ("mining-XS", _mining(15, 10, "Mining, smallest monitor")),
    ("miningsetup-M", _mining(57, 24, "Mining setup, room monitor 57x24", True)),
    ("miningsetup-L", _mining(39, 19, "Mining setup, wall monitor 4x3", True)),
    ("miningsetup-P", _mining(26, 20, "Mining setup at 26x20", True)),
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
]
