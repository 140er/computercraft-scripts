"""The route A prototype screens that are not ported yet, kept as the reference for their port.

Each worker moves a screen from here into its own module and FIXTURES in screens.py, then deletes it
here. Render them with: python3 -I docs/ui/schematic/screens.py --prototype DIR
"""
from cc import Canvas
import kit
from kit import rule, section, leader, ticks
from scene import S
import mapdraw as MD
import status as ST

ARROW = MD.ARROW
TIME = "21:14"


def header(cv, name, tabs=(), active=None, right="", rfg="8", y=1):
    kit.bar(cv, name, tabs, active, right, rfg, y)


def alert(cv, y, text, x=2):
    kit.flag(cv, x, y, cv.w - x, text)


def bignum(cv, x, y, text, fg="0", w=4, h=5, gap=2):
    return kit.digits(cv, x, y, text, fg, w, h, gap)


def chip(cv, x, y, label, bid, fg="0", bg="7", pad=1):
    lab = " " * pad + label + " " * pad
    cv.put(x, y, lab, fg, bg)
    cv.hit(bid, x, y, len(lab), 1, label)
    return x + len(lab)


def button(cv, x, y, w, label, bid, fg="0", h=1, bg="7"):
    cv.fill(x, y, w, h, bg)
    cv.put(x + max(0, (w - len(label)) // 2), y + (h - 1) // 2, label[:w], fg, bg)
    cv.hit(bid, x, y, w, h, label)


Canvas.button = button


def _turtles():
    out = {}
    for t in ST.model()["turtles"]:
        w = t["where"]
        out[str(t["id"])] = dict(id=str(t["id"]), f=t["facing"], col=t["tone"], state=t["state"], x=t["x"],
                                 y=t["y"], z=t["z"], fuel=t["fuel"], ore=t["ore"], seen=t["ago"] // 60000,
                                 branch=int(w[1:]) if w.startswith("b") else None)
    return out


T = _turtles()


def where(t):
    if t["id"] == "5": return "farm"
    if t["id"] == "4": return "lane"
    return "b%d" % t["branch"]

def trow(cv, x, y, t, wide=False):
    cv.put(x, y, ARROW[t["f"]], t["col"]); cv.put(x + 2, y, t["id"], "0")
    st = t["state"]
    cv.put(x + 5, y, st, "0" if t["col"] == "d" else t["col"])
    cv.put(x + 16, y, where(t), "8")
    if wide:
        cv.put(x + 22, y, "%d,%d,%d" % (t["x"], t["y"], t["z"]), "0")
        cv.put(x + 37, y, "%5d" % t["fuel"], "0" if t["fuel"] > 500 else "1")
        cv.put(x + 44, y, "%4d" % t["ore"], "0")
        cv.put(x + 50, y, "3m" if t["seen"] else "now", "e" if t["seen"] else "8")

ORDER = ["2", "3", "4", "6", "5"]

# ------------------------------------------------------------------ mining
def mine_diagram(cv, x0, y0, cols, labels=True):
    """Job diagram: one row per branch, north up. Columns: number, lane id, spine, branch."""
    g = S["g"]; n = g["branches"]; per = g["length"] / cols
    sp = x0 + 4
    for b in range(n, 0, -1):
        y = y0 + (n - b)
        cv.put(x0, y, "%2d" % b, "8")
        cv.put(sp, y, "+", "b")
        done = {8: 160 - 120, 9: 142 - 120, 10: 0}.get(b, 64)
        for i in range(cols):
            cv.put(sp + 1 + i, y, "-" if (i + 1) * per <= done + 0.01 else "·", "3" if (i + 1) * per <= done + 0.01 else "8")
    for t in (T["2"], T["3"]):
        y = y0 + (n - t["branch"]); i = int((t["x"] - 120) / per)
        cv.put(sp + i, y, "►", t["col"]); cv.put(sp + 1 + i, y, "-", "b")
        if labels: cv.put(sp + 3 + i, y, t["id"] + ("" if t["col"] == "d" else " wait"), t["col"])
    y = y0 + (n - 7)
    cv.put(sp + cols, y, "►", "e")
    if labels: cv.put(sp + cols + 2, y, "6 lost", "e")
    cv.put(sp, y0 + n, "|", "b"); cv.put(sp, y0 + n + 1, "º", "9")
    if labels: cv.put(sp + 2, y0 + n + 1, "shaft", "8")
    yb = y0 + n - 3
    cv.put(sp, yb, "▼", "d")
    if labels: cv.put(sp - 1, yb, "4", "d")

def mining():
    cv = Canvas(57, 24, "Mining, room monitor 57x24")
    header(cv, "MINING", ["overview", "setup"], "overview", "running", "d")
    mine_diagram(cv, 1, 3, 30)
    for i, (a, b, c) in enumerate([("busy", "2/4", "0"), ("lane", "#4", "b"), ("depth", "-58", "0"),
                                   ("done", "7/10", "0"), ("ore", "214", "0"), ("fuel", "412", "1")]):
        leader(cv, 46, 3 + i, 11, a, b, c)
    section(cv, 2, 16, 55, "TURTLES", "fuel  ore")
    for i, k in enumerate(["2", "3", "4", "6"]):
        t = T[k]; trow(cv, 2, 17 + i, t)
        cv.put(24, 17 + i, "%d,%d,%d" % (t["x"], t["y"], t["z"]), "e" if t["col"] == "e" else "8")
        cv.put(46, 17 + i, "%4d" % t["fuel"], "1" if t["fuel"] < 500 else "0"); cv.put(52, 17 + i, "%4d" % t["ore"], "0")
    cv.button(2, 23, 26, "START", "start", "8")
    cv.button(31, 23, 26, "STOP", "stop", "e")
    return cv

def mining_setup():
    cv = Canvas(57, 24, "Mining setup, room monitor 57x24")
    header(cv, "MINING", ["overview", "setup"], "setup", "stopped", "8")
    def stepper(y, key, value):
        chip(cv, 13, y, "-", "set-" + key + "-"); cv.put(18, y, value.center(8), "0"); chip(cv, 27, y, "+", "set-" + key + "+")
    y = 3
    cv.put(2, y, "home", "8"); cv.put(13, y, "120,64,-340 n", "0"); chip(cv, 28, y, "set", "home-set"); y += 2
    cv.put(2, y, "bottom", "8"); stepper(y, "bottom", "Y -58"); y += 2
    cv.put(2, y, "branches", "8"); stepper(y, "branches", "10"); y += 2
    cv.put(2, y, "length", "8"); stepper(y, "length", "64"); y += 2
    cv.put(2, y, "mode", "8"); chip(cv, 13, y, "fast", "mode-fast", "8", "f"); chip(cv, 20, y, "thorough", "mode-thorough"); y += 2
    cv.put(2, y, "ores", "8"); cv.put(13, y, "all", "0"); chip(cv, 28, y, "edit", "ores-edit"); y += 2
    cv.put(2, y, "turtles", "8"); cv.put(13, y, "#2 #3 #4 #6", "0"); chip(cv, 28, y, "+", "t-add"); chip(cv, 32, y, "-", "t-rm")
    for yy in range(3, 22): cv.put(38, yy, "|", "c")
    for b in range(10, 0, -1):
        yy = 3 + (10 - b)
        cv.put(41, yy, "%2d" % b, "8"); cv.put(44, yy, "+", "3")
        for i in range(12): cv.put(45 + i, yy, "·", "8")
    cv.put(44, 13, "|", "3"); cv.put(44, 14, "º", "9")
    cv.put(41, 16, "40 × 64", "8")
    cv.button(2, 23, 26, "START", "start", "9")
    cv.button(31, 23, 26, "STOP", "stop", "8")
    return cv

# ------------------------------------------------------------------ lumber
def lumber():
    cv = Canvas(57, 24, "Lumber, room monitor 57x24")
    header(cv, "LUMBER", ["overview", "setup"], "overview", "running", "d")
    a = S["area"]
    ox, oy = 2, 4
    W, H = (a["x2"] - a["x1"]) * 2, a["z2"] - a["z1"]
    px = lambda x: ox + (x - a["x1"]) * 2
    py = lambda z: oy + (z - a["z1"])
    for x in range(W + 1): cv.put(ox + x, oy, "-", "c"); cv.put(ox + x, oy + H, "-", "c")
    for y in range(H + 1): cv.put(ox, oy + y, "|", "c"); cv.put(ox + W, oy + y, "|", "c")
    for x, y in ((0, 0), (W, 0), (0, H), (W, H)): cv.put(ox + x, oy + y, "+", "c")
    for sp in S["spots"]:
        cv.put(px(sp["x"]), py(sp["z"]), "♠" if sp["ready"] else "♣", "d" if sp["ready"] else "8")
    t = T["5"]; cv.put(px(t["x"]), py(t["z"]), "►", "d"); cv.put(px(t["x"]) + 1, py(t["z"]) - 1, "5", "d")
    for d in S["drops"]:
        if d["kind"] in ("wood", "saplings"):
            cv.put(px(d["x"]) - 1, py(d["z"]), "•", "0"); cv.put(px(d["x"]) + 1, py(d["z"]), d["kind"], "8")
    for y in range(3, 22): cv.put(40, y, "|", "c")
    x = 42
    for i, (k, v, c) in enumerate([("ready", "9/12", "d"), ("growing", "3", "0"), ("next grow", "6:20", "0"),
                                   ("logs today", "96", "0"), ("saplings", "14", "0"), ("fuel", "1210", "0")]):
        leader(cv, x, 4 + i * 2, 15, k, v, c)
    cv.put(2, 18, "►", "d"); cv.put(4, 18, "5", "0"); cv.put(7, 18, "felling", "0"); cv.put(18, 18, "101,65,-347", "8")
    cv.button(2, 23, 26, "START", "start", "8")
    cv.button(31, 23, 26, "STOP", "stop", "e")
    return cv

# ------------------------------------------------------------------ shop
ITEMS = [("COAL", 961, "+44"), ("RAW COPPER", 640, "+31"), ("REDSTONE", 412, "+18"), ("IRON INGOT", 1240, "+60"),
         ("RAW IRON", 48, "-20"), ("LAPIS LAZULI", 230, "+9"), ("GOLD INGOT", 88, ""), ("DIAMOND", 14, "+2"),
         ("EMERALD", 3, ""), ("RAW GOLD", 0, ""), ("QUARTZ", 0, ""), ("AMETHYST", 26, "")]
ITEMS.sort(key=lambda r: -r[1])

def shop_row(cv, x, y, w, name, n, tr, sel=False, trend=True):
    bg = "7" if sel else None
    if sel: cv.fill(x - 1, y, w + 2, 1, "7")
    cv.put(x, y, name, "0", bg)
    num = str(n)
    tx = x + w - (8 if trend else 0)
    cv.put(tx - len(num), y, num, "8" if n == 0 else ("1" if n < 10 else "0"), bg)
    for i in range(x + len(name) + 1, tx - len(num) - 1): cv.put(i, y, "·", "c", bg)
    if trend and tr:
        up = tr.startswith("+")
        cv.put(tx + 2, y, ("↑" if up else "↓") + tr[1:], "8" if up else "1", bg)

# ------------------------------------------------------------------ drops
def drops():
    cv = Canvas(57, 24, "Drop points, room monitor 57x24")
    header(cv, "DROP POINTS", right="5")
    cv.put(2, 3, "id", "8"); cv.put(5, 3, "kind", "8"); cv.put(15, 3, "where", "8"); cv.put(29, 3, "side", "8")
    for i, d in enumerate(S["drops"]):
        y = 4 + i; sel = d["broken"]; bg = "7" if sel else None
        if sel: cv.fill(1, y, 34, 1, "7")
        c = "e" if d["broken"] else "0"
        cv.put(2, y, str(d["id"]), c, bg); cv.put(5, y, d["kind"], c, bg)
        cv.put(15, y, "%d,%d,%d" % (d["x"], d["y"], d["z"]), "8", bg); cv.put(29, y, "front", "8", bg)
    alert(cv, 10, "3 chest missing")
    for y in range(3, 22): cv.put(36, y, "|", "c")
    v = MD.view(20, 18, 64, 1, 1, 118, -342)
    MD.draw(cv, v, 37, 4, drop_label="id", select_drop=3)
    cv.button(2, 23, 17, "FIX 3", "fix", "9")
    cv.button(21, 23, 17, "REMOVE 3", "remove", "8")
    cv.button(40, 23, 17, "ADD", "add", "0")
    return cv

# ------------------------------------------------------------------ map
def map_controls(cv, y, w, level="ALL", fit=True):
    x = 2; cv.put(x, y, "MAP", "0"); x = 7
    x = chip(cv, x, y, "FIT", "map-fit", "f" if fit else "0", "9" if fit else "7") + 2
    x = chip(cv, x, y, "-", "map-out") + 1; x = chip(cv, x, y, "+", "map-in") + 2
    for a, i in (("◄", "w"), ("▲", "n"), ("▼", "s"), ("►", "e")): x = chip(cv, x, y, a, "map-" + i) + 1
    x = w - 15
    x = chip(cv, x, y, "▼", "map-down") + 1; x = chip(cv, x, y, level, "map-level", "0", "f", 1) + 1; chip(cv, x, y, "▲", "map-up")

def map_room():
    cv = Canvas(57, 24, "Map, room monitor 57x24")
    map_controls(cv, 1, 57)
    v = MD.fit(57, 23, "all"); MD.draw(cv, v, 1, 2)
    return cv

def map_wall():
    cv = Canvas(100, 38, "Map, wall 100x38")
    map_controls(cv, 1, 100)
    v = MD.fit(100, 26, "all"); MD.draw(cv, v, 1, 3)
    section(cv, 2, 30, 98, "TURTLES")
    for i, k in enumerate(ORDER):
        t = T[k]; x = 2 + (i % 3) * 33; y = 31 + i // 3 * 2
        cv.put(x, y, ARROW[t["f"]], t["col"]); cv.put(x + 2, y, t["id"], "0")
        cv.put(x + 5, y, t["state"], "0" if t["col"] == "d" else t["col"])
        cv.put(x + 16, y, "%d,%d,%d" % (t["x"], t["y"], t["z"]), "8")
    return cv

def map_pocket():
    cv = Canvas(26, 20, "Map, pocket 26x20")
    cv.put(2, 1, "MAP", "0"); chip(cv, 7, 1, "FIT", "map-fit", "f", "9")
    chip(cv, 13, 1, "▼", "map-down"); cv.put(17, 1, "ALL", "0"); chip(cv, 21, 1, "▲", "map-up")
    v = MD.fit(26, 18, "all"); MD.draw(cv, v, 1, 2)
    x = 1
    for a, i in (("◄", "w"), ("▲", "n"), ("▼", "s"), ("►", "e"), ("-", "out"), ("+", "in")):
        cv.button(x, 20, 3, a, "map-" + i); x += 4 + (1 if i == "e" else 0)
    return cv

def map_selected():
    cv = Canvas(57, 24, "Map, room monitor, Y -58 zoomed in, #6 selected")
    map_controls(cv, 1, 57, "Y-58", fit=False)
    v = MD.view(57, 23, -58, 1, 1, 158, -367)
    MD.draw(cv, v, 1, 2, select="6")
    t = T["6"]; p = MD.cell(v, t["x"], t["z"]); tx, ty = 1 + p[0], 2 + p[1]
    bw, bh = 22, 7; bx, by = tx - bw + 1, ty + 2
    cv.fill(bx, by, bw, bh, "f")
    frame_box(cv, bx, by, bw, bh, "e")
    cv.put(tx, ty + 1, "|", "e"); cv.put(tx, by, "+", "e")
    cv.put(bx + 2, by + 1, "#6", "0"); cv.put(bx + 5, by + 1, "lost", "e"); cv.put(bx + bw - 8, by + 1, "3 min", "8")
    cv.put(bx + 2, by + 2, "184,-58,-369", "8")
    leader(cv, bx + 2, by + 3, bw - 4, "fuel", "412", "1")
    leader(cv, bx + 2, by + 4, bw - 4, "ore", "22")
    leader(cv, bx + 2, by + 5, bw - 4, "lease", "expired", "e")
    return cv

# ------------------------------------------------------------------ pocket
PTABS = ["FLEET", "JOBS", "SHOP", "PAIR"]
def ptabs(cv, active):
    x = 1
    for t in PTABS:
        lab = " %s " % t
        cv.put(x, 1, lab, "0" if t == active else "8", "7" if t == active else "f")
        cv.buttons.append({"id": "tab-" + t, "x": x, "y": 1, "w": len(lab), "h": 1, "label": t})
        x += len(lab)
    cv.put(7, 1, "•", "e", "7" if active == "FLEET" else "f")

def pocket_fleet():
    cv = Canvas(26, 20, "Pocket FLEET")
    ptabs(cv, "FLEET")
    alert(cv, 3, "#6 lost  3m"); alert(cv, 4, "drop 3 broken")
    section(cv, 2, 6, 24, "TURTLES", "5")
    for i, k in enumerate(ORDER):
        t = T[k]; y = 7 + i
        cv.put(2, y, ARROW[t["f"]], t["col"]); cv.put(4, y, t["id"], "0")
        cv.put(7, y, t["state"], "0" if t["col"] == "d" else t["col"]); cv.put(22, y, where(t), "8")
    section(cv, 2, 13, 24, "TODAY")
    leader(cv, 2, 14, 24, "ore", "214"); leader(cv, 2, 15, 24, "logs", "96")
    section(cv, 2, 17, 24, "SERVER")
    cv.put(2, 18, "disk", "8"); ticks(cv, 7, 18, 14, 2); cv.put(22, 18, "13%", "0")
    cv.put(2, 19, "4 displays · 3 leases", "8")
    return cv

def pocket_jobs():
    cv = Canvas(26, 20, "Pocket JOBS")
    ptabs(cv, "JOBS")
    section(cv, 2, 3, 24, "MINING", "running", "d")
    ticks(cv, 2, 4, 10, 7); cv.put(13, 4, "7/10", "0")
    leader(cv, 2, 5, 24, "busy", "2/4"); leader(cv, 2, 6, 24, "lane", "▼4", "b")
    leader(cv, 2, 7, 24, "min fuel", "412 #6", "1")
    cv.button(2, 9, 11, "START", "mine-start", "8"); cv.button(15, 9, 11, "STOP", "mine-stop", "e")
    section(cv, 2, 12, 24, "LUMBER", "running", "d")
    cv.put(2, 13, "♠♠♠♠♠♠♠♠♠", "d"); cv.put(11, 13, "♣♣♣", "8"); cv.put(15, 13, "9/12", "0")
    leader(cv, 2, 14, 24, "next grow", "6:20"); leader(cv, 2, 15, 24, "saplings", "14"); leader(cv, 2, 16, 24, "fuel", "1210")
    cv.button(2, 18, 11, "START", "lum-start", "8"); cv.button(15, 18, 11, "STOP", "lum-stop", "e")
    return cv

def pocket_shop():
    cv = Canvas(26, 20, "Pocket SHOP quick order")
    ptabs(cv, "SHOP")
    cv.put(2, 3, ">", "8"); cv.put(4, 3, "iron", "0"); cv.put(8, 3, "_", "9"); chip(cv, 23, 3, "×", "clear", "8", "f")
    rule(cv, 2, 4, 25)
    rows = [("IRON INGOT", 1240), ("IRON ORE", 312), ("RAW IRON", 48), ("IRON BLOCK", 27), ("IRON NUGGET", 5),
            ("IRON DOOR", 3), ("IRON PICKAXE", 1), ("IRON BARS", 0)]
    shop_row(cv, 2, 5, 24, rows[0][0], rows[0][1], "", sel=True, trend=False)
    cv.button(2, 6, 7, "1", "o1"); cv.button(10, 6, 7, "16", "o16"); cv.button(18, 6, 7, "64", "o64")
    for i, (nm, n) in enumerate(rows[1:]): shop_row(cv, 2, 8 + i, 24, nm, n, "", trend=False)
    cv.put(2, 19, "16 IRON INGOT sent", "d")
    return cv

def pocket_pair():
    cv = Canvas(26, 20, "Pocket PAIR")
    ptabs(cv, "PAIR")
    bignum(cv, 2, 5, "4821", "0", w=5, h=7, gap=1)
    ticks(cv, 2, 14, 18, 12, "9"); cv.put(21, 14, "0:48", "0")
    cv.button(2, 18, 24, "NEW CODE", "pair-new")
    return cv

# ------------------------------------------------------------------ takeovers
def frame_box(cv, x, y, w, h, fg):
    rule(cv, x, y, x + w - 1, fg); rule(cv, x, y + h - 1, x + w - 1, fg)
    for j in range(y, y + h): cv.put(x, j, "|", fg); cv.put(x + w - 1, j, "|", fg)
    for a, b in ((x, y), (x + w - 1, y), (x, y + h - 1), (x + w - 1, y + h - 1)): cv.put(a, b, "+", fg)

def alert_takeover():
    cv = Canvas(57, 24, "Alert takeover, room monitor")
    frame_box(cv, 1, 1, 57, 24, "e")
    cv.put(5, 3, " #6 LOST ", "f", "e")
    cv.put(15, 3, "184,-58,-369", "0"); cv.put(28, 3, "3 min", "8")
    cv.put(5, 5, "lease expired, lane released", "8")
    v = MD.view(49, 13, -58, 1, 1, 162, -371)
    MD.draw(cv, v, 5, 7, select="6")
    ticks(cv, 5, 22, 49, 30, "e")
    return cv

def unassigned():
    cv = Canvas(57, 24, "Unassigned display")
    header(cv, "UNASSIGNED")
    bignum(cv, 24, 7, "7", "0", w=9, h=11)
    return cv

def no_server():
    cv = ST.status(ST.model(), 57, 24)
    cv.title = "No server: last picture in the stale palette, one coral row"
    cv.fill(1, 1, 57, 1, "2")
    cv.put(2, 1, "NO SERVER", "f", "2"); cv.put(13, 1, "0:42", "f", "2"); cv.put(45, 1, "retry in 8 s", "f", "2")
    return cv


def server_term():
    cv = Canvas(51, 19, "Server terminal 51x19")
    header(cv, "SO SERVER #1", right="up 3h12")
    alert(cv, 3, "#6 lost"); alert(cv, 4, "drop 3 junk broken")
    section(cv, 2, 6, 23, "FLEET")
    leader(cv, 2, 7, 23, "turtles", "4 ok · 1 lost")
    leader(cv, 2, 8, 23, "displays", "4")
    leader(cv, 2, 9, 23, "leases", "3")
    section(cv, 28, 6, 23, "DISK", "13%")
    ticks(cv, 28, 7, 23, 3)
    leader(cv, 28, 8, 23, "used", "2.1 MB")
    leader(cv, 28, 9, 23, "pair", "4821")
    section(cv, 2, 11, 49, "LOG")
    for i, (t, m, c) in enumerate([("21:13:40", "lease 6-311 expired: #6 lost", "e"), ("21:14:02", "lease 2-961 reported ok", "8"),
                                   ("21:14:05", "drops: 3 junk chest missing", "e"), ("21:14:09", "pair: display 10 joined", "8"),
                                   ("21:14:11", "mine: #3 waits for lane", "1")]):
        cv.put(2, 12 + i, t, "8"); cv.put(11, 12 + i, "•", c); cv.put(13, 12 + i, m, "0")
    for i, (k, lab) in enumerate([("P", "pair"), ("R", "roles"), ("L", "log")]):
        x = 2 + i * 12; cv.put(x, 19, "[" + k + "]", "9"); cv.put(x + 4, 19, lab, "0")
    return cv

SCREENS = [("03-mining-57x24", mining),
           ("04-mining-setup-57x24", mining_setup), ("05-lumber-57x24", lumber),
           ("08-drops-57x24", drops), ("09-map-57x24", map_room),
           ("10-map-wall-100x38", map_wall), ("11-map-pocket-26x20", map_pocket), ("12-map-selected-57x24", map_selected),
           ("13-pocket-fleet-26x20", pocket_fleet), ("14-pocket-jobs-26x20", pocket_jobs), ("15-pocket-shop-26x20", pocket_shop),
           ("16-pocket-pair-26x20", pocket_pair), ("17-alert-57x24", alert_takeover), ("18-unassigned-57x24", unassigned),
           ("19-no-server-57x24", no_server), ("20-server-terminal-51x19", server_term)]

