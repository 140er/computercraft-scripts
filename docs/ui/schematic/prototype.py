"""The route A prototype screens that are not ported yet, kept as the reference for their port.

Each worker moves a screen from here into its own module and FIXTURES in screens.py, then deletes it
here. Render them with: python3 -I docs/ui/schematic/screens.py --prototype DIR
"""
from cc import Canvas
import kit
from kit import rule, section, leader
from scene import S
import mapdraw as MD
import status as ST

ARROW = MD.ARROW
TIME = "21:14"


def header(cv, name, tabs=(), active=None, right="", rfg="8", y=1):
    kit.bar(cv, name, tabs, active, right, rfg, y)


def alert(cv, y, text, x=2):
    kit.flag(cv, x, y, cv.w - x, text)


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
SCREENS = [("03-mining-57x24", mining),
           ("04-mining-setup-57x24", mining_setup), ("05-lumber-57x24", lumber),
           ("08-drops-57x24", drops)]

