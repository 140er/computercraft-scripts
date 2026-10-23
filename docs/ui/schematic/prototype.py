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

# ------------------------------------------------------------------ map
SCREENS = []

