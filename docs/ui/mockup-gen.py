# Mockup generator for the Big Tiles spec: text layer (with real sextant glyphs) + bg colour layer.
FONT = {
 "0": [".###.","#...#","#...#","#...#","#...#","#...#",".###."],
 "1": ["..#..",".##..","..#..","..#..","..#..","..#..",".###."],
 "2": [".###.","#...#","....#","...#.","..#..",".#...","#####"],
 "3": ["####.","....#","....#",".###.","....#","....#","####."],
 "4": ["...#.","..##.",".#.#.","#..#.","#####","...#.","...#."],
 "5": ["#####","#....","####.","....#","....#","#...#",".###."],
 "6": ["..##.",".#...","#....","####.","#...#","#...#",".###."],
 "7": ["#####","....#","...#.","..#..",".#...",".#...",".#..."],
 "8": [".###.","#...#","#...#",".###.","#...#","#...#",".###."],
 "9": [".###.","#...#","#...#",".####","....#","...#.",".##.."],
 "%": ["##...","##..#","...#.","..#..",".#...","#..##","...##"],
 "-": [".....",".....",".....","#####",".....",".....","....."],
 ":": [".....",".##..",".##..",".....",".##..",".##..","....."],
 "/": ["....#","....#","...#.","..#..",".#...","#....","#...."],
 " ": ["....."]*7,
}
def glyph_px(ch):
    rows = ["......"] + [r + "." for r in FONT[ch]] + ["......"]   # 6 wide x 9 tall
    return rows
def sextant(bits):
    v = bits
    if v == 0: return " "
    if v == 63: return "█"
    if v == 21: return "▌"
    if v == 42: return "▐"
    return chr(0x1FB00 + v - 1 - (v > 21) - (v > 42))
def big(text):
    """returns 3 strings, 3 cols per glyph"""
    out = ["", "", ""]
    for ch in text:
        px = glyph_px(ch)
        for cr in range(3):
            for cc in range(3):
                b = 0
                for i, (dx, dy) in enumerate([(0,0),(1,0),(0,1),(1,1),(0,2),(1,2)]):
                    if px[cr*3+dy][cc*2+dx] == "#": b |= 1 << i
                out[cr] += sextant(b)
    return out

class Canvas:
    def __init__(s, w, h, bg="f"):
        s.w, s.h = w, h
        s.t = [[" "]*w for _ in range(h)]
        s.b = [[bg]*w for _ in range(h)]
    def fill(s, x, y, w, h, bg):
        for j in range(y, y+h):
            for i in range(x, x+w):
                if 0 <= i < s.w and 0 <= j < s.h: s.b[j][i] = bg
    def text(s, x, y, txt, bg=None):
        for k, ch in enumerate(txt):
            i = x + k
            if 0 <= i < s.w and 0 <= y < s.h:
                s.t[y][i] = ch
                if bg: s.b[y][i] = bg
    def center(s, x, w, y, txt, bg=None):
        s.text(x + max(0, (w - len(txt)) // 2), y, txt[:w], bg)
    def header(s, name, right="21:14", bg="7"):
        s.fill(1, 1, s.w-2, 1, bg)
        s.text(1, 1, name)
        s.text(s.w - len(right) - 1, 1, right)
    def alert(s, msg):
        s.fill(1, 2, s.w-2, 1, "e")
        s.text(1, 2, msg[:s.w-2])
    def tile(s, x, y, w, label, value, sub="", bg="d", h=None):
        h = h or (7 if s.h >= 24 else 6)
        right = min(s.w-2,x+w-1)
        x = max(1,x); w = max(0,right-x+1)
        s.fill(x, y, w, h, bg)
        s.text(x + 1, y+1, label[:w-2])
        if len(value)*3 > w-2 or any(ch not in FONT for ch in value):
            s.center(x+1,w-2,y+3,value)
        else:
            rows = big(value)
            for r in range(3):
                s.center(x+1, w-2, y + 2 + r, rows[r])
        if sub and h >= 7: s.text(x + 1, y + 5, sub[:w-2])
    def button(s, x, y, w, label, bg="7", h=3):
        s.fill(x, y, w, h, bg)
        inset = 1 if len(label) <= w-2 else 0
        s.center(x+inset, w-2*inset, y + h // 2, label)
    def dump(s, name, legend=True):
        out = [f"{name}  ({s.w}x{s.h})", "```text"]
        out += ["".join(r) for r in s.t]
        out += ["```"]
        if legend:
            out += ["Background layer (blit letters, see palette):", "```text"]
            out += ["".join(r) for r in s.b]
            out += ["```"]
        return "\n".join(out)

M = []
FIXTURES = []
def add(c, name, legend=False):
    M.append(c.dump(name, legend))
    FIXTURES.append((c, name))

def grid(w,n):
    available=w-n+1
    return [(int(i*available/n+0.5)+i,int((i+1)*available/n+0.5)-int(i*available/n+0.5)) for i in range(n)]
status_data = [("TURTLES","3","3 ok, 0 lost","d"),("LEASES","2","","b"),("ALERTS","1","ore chest full","e"),
    ("ORE TODAY","214","+12","b"),("LOGS TODAY","96","","d"),("DISK","13%","2.1 of 16 MB","d"),
    ("DISPLAYS","4","all fresh","d"),("DROPS","5","1 broken","1"),("PAIR","","","9")]
def status(w,h,indices,n,title):
    c=Canvas(w,h);c.header("STATUS","21:14");c.alert("! ore chest full (drop 3)" if w!=39 else "! ore chest full")
    cols=grid(w,n);wanted=(len(indices)+n-1)//n
    navheight=3 if h>=19 and h-7>=wanted*8 else 1
    nav=h-navheight; height=7 if nav-3>=wanted*8-1 else 6
    for i,index in enumerate(indices):
        x,width=cols[i%n]; y=3+(i//n)*(height+1)
        lab,val,sub,bg=status_data[index]
        if index==8:
            left=max(1,x);right=min(w-2,x+width-1)
            c.button(left,y+1,right-left+1,"PAIR","9",3)
        else:c.tile(x,y,width,lab,val,sub,bg,height)
    if w==51:
        c.fill(1,11,w-2,1,"7");c.text(1,11,"LOG")
    labels=["MINING","SHOP","MORE"] if w==39 else ["MINING","LUMBER","SHOP","MORE"]
    for (x,width),label in zip(grid(w,len(labels)),labels):c.button(x,nav,width,label,"a" if label=="SHOP" else "7",navheight)
    add(c,title,True)
status(57,24,list(range(9)),3,"Status, room monitor 3x2 at scale 0.5")
status(39,19,[0,2,3,5],2,"Status, wall monitor 4x3 at scale 1")
c=Canvas(26,20);c.header("FLEET","21:14")
for i,index in enumerate([0,2]):c.tile(0,3+i*8,26,*status_data[index],h=7)
c.button(0,18,26,"MORE",h=1)
c.fill(0,19,26,1,"7");c.text(1,19,"<  glance 1/5  >  PANEL")
add(c,"Pocket, glance mode",True)

# --- Pocket panel mode (26x20)
c = Canvas(26, 20); c.header("PANEL", "22:14"); c.button(7, 1, 6, "MORE", h=1)
c.text(1, 2, "MINING   stopped"); c.button(0, 3, 12, "START", "9"); c.button(13, 3, 13, "STOP", "e")
c.text(1, 7, "LUMBER   running"); c.button(0, 8, 12, "START", "9"); c.button(13, 8, 13, "STOP", "e")
c.text(1, 12, "SHOP     search:"); c.fill(1, 13, 24, 1, "0"); c.text(1, 13, " iron_                  ", "0")
c.button(0, 15, 8, "1", "a"); c.button(9, 15, 8, "16", "a"); c.button(18, 15, 8, "64", "a")
c.fill(0, 19, 26, 1, "7"); c.text(0, 19, " GLANCE  ALERTS  PAIR    ")
add(c, "Pocket, panel mode", True)

# --- Mining, M
c = Canvas(57, 24); c.header("MINING", "running")
cols = [(0,18),(19,19),(39,18)]
for (x, w), (lab, val, sub, bg) in zip(cols, [("BUSY","2/2","both digging","d"),("ORE TODAY","214","iron 120 dia 3","b"),("DEPTH","-12","","d")]):
    c.tile(x, 3, w, lab, val, sub, bg,6)
for (x, w), (lab, val, sub, bg) in zip(cols, [("LANE","1","#3 waiting","1"),("MIN FUEL","640","#3","d"),("BRANCHES","3/8","48 long","b")]):
    c.tile(x, 10, w, lab, val, sub, bg,6)
c.fill(0, 17, 57, 1, "7"); c.text(1, 17, "TURTLE  STATE      POS          FUEL  ORE")
for i, line in enumerate(["#2      mining     12,60,-9      812   14","#3      wait lane   0,61,-1      640    9"]):
    c.text(1, 18 + i, line)
c.fill(0, 18, 1, 1, "d"); c.fill(0, 19, 1, 1, "1")
c.button(0, 20, 13, "START", "9"); c.button(14, 20, 13, "STOP", "e"); c.button(28, 20, 14, "SETUP"); c.button(43, 20, 14, "BACK")
add(c, "Mining, room monitor")

# --- Lumber, M
c = Canvas(57, 24); c.header("LUMBER", "running")
for (x, w), (lab, val, sub, bg) in zip(cols, [("TREES READY","2","of 4 spots","d"),("LOGS TODAY","96","","d"),("SAPLINGS","0","","e")]):
    c.tile(x, 3, w, lab, val, sub, bg)
for (x, w), (lab, val, sub, bg) in zip(cols, [("TURTLE","4","felling","d"),("FUEL","1210","ok","d"),("NEXT GROW","6:20","","b")]):
    c.tile(x, 11, w, lab, val, sub, bg)
c.alert("! out of saplings: replanting paused")
c.button(0, 20, 13, "START", "9"); c.button(14, 20, 13, "STOP", "e"); c.button(28, 20, 14, "SETUP"); c.button(43, 20, 14, "BACK")
add(c, "Lumber, room monitor")

def grid(w, n):
    import math
    available = w - n + 1
    return [(math.floor((i - 1) * available / n + .5) + i - 1,
             math.floor(i * available / n + .5) - math.floor((i - 1) * available / n + .5))
            for i in range(1, n + 1)]

SHOP_ITEMS = [("IRON INGOT", "1240", "^ +60/h", "b"),
              ("IRON ORE", "312", "- steady", "b"), ("RAW IRON", "48", "v -20/h", "1"),
              ("IRON BLOCK", "27", "- steady", "b"), ("IRON NUGGET", "5", "v low", "1"),
              ("IRON BARS", "0", "empty", "e")]
SHOP_ITEMS += [("IRON " + str(i), "0", "empty", "e") for i in range(7, 19)]

def shop(w, h, selected=False):
    import math
    c = Canvas(w, h)
    header, tile = 1, 5 if h < 16 else 7 if h >= 24 else 6
    nav = 1 if h < 16 else 3
    bottom = h - nav
    if selected:
        c.header("SHOP > IRON INGOT", "", "a")
        y = 2 if h < 16 else header + 2
        if y > header + 1: c.text(1, header + 1, "stock 21:14")
        c.tile(0, y, w, "IN STOCK", "1240", "^ +60 per hour", "b", tile)
        y = 7 if h < 16 else y + tile + 1
        height = 1 if h < 12 else 3 if h < 16 else min(5, bottom - 2 - y)
        for (x, width), amount in zip(grid(w, 3), [1, 16, 64]):
            c.button(x, y, width, ("" if w < 26 else "ORDER ") + str(amount), "a", height)
        c.text(1, bottom - 1, "Order: delivered")
        if h >= 16: c.text(1, bottom - 2, "stock 21:14")
        c.button(0, bottom, w, "BACK", h=nav)
        return c
    c.header("SHOP", "stock 21:14" if w >= 26 else "", "a")
    tabs = grid(w, max(1, min(7, (w + 1) // 7)))
    top = header + (3 if w < 26 or h < 12 else 2 + math.ceil(7 / len(tabs)))
    for i, label in enumerate(["ALL", "ORES", "WOOD", "FOOD", "BLOCKS", "TOOLS", "OTHER"]):
        x, width = tabs[i % len(tabs)]
        c.button(x, header + 1 + i // len(tabs), width, label, "a" if i == 0 else "7", 1)
    for (x, width), label in zip(grid(w, 3), ["A-Z", "STOCK", "NAME"]):
        c.button(x, top - 1, width, label, "a" if label == "STOCK" else "7", 1)
    cols = grid(w, max(1, (w + 1) // 19))
    capacity = len(cols) * max(1, (bottom - top) // (tile + 1))
    for i, (label, value, sub, bg) in enumerate(SHOP_ITEMS[:capacity]):
        x, width = cols[i % len(cols)]
        c.tile(x, top + (i // len(cols)) * (tile + 1), width, label, value, sub, bg, tile)
    c.text(1, bottom - 1, "Order: sent 16")
    for (x, width), label in zip(grid(w, 4), ["<", "1/" + str(max(1, math.ceil(18 / capacity))), ">", "BACK"]):
        c.button(x, bottom, width, label, h=nav)
    return c

add(shop(57, 24), "Shop, room monitor")
add(shop(57, 24, True), "Shop order page")

# --- Generic / drops page
c = Canvas(57, 24); c.header("DROP POINTS", "5 points")
c.fill(0, 2, 57, 1, "7"); c.text(1, 2, "ID  KIND     WHERE          SIDE   STATE")
rows = [("1  ore      10,64,-2       front  ok","d"),("2  fuel     12,64,-2       front  ok","d"),("3  wood     -4,64,10       front  ok","d"),("4  saplings -6,64,10       front  ok","d"),("5  any       0,64,4        down   broken","e")]
for i, (t, bg) in enumerate(rows): c.fill(0, 3+i, 1, 1, bg); c.text(1, 3+i, t)
c.button(0, 10, 13, "FIX #5", "9"); c.button(14, 10, 13, "REMOVE"); c.button(28, 10, 14, "ADD NEW"); c.button(43, 10, 14, "BACK")
c.button(0, 21, 11, "MINING"); c.button(12, 21, 11, "LUMBER"); c.button(24, 21, 11, "SHOP", "a"); c.button(36, 21, 10, "AR"); c.button(47, 21, 10, "PANEL")
add(c, "Drop points (generic)")
M[-1] += "\nThe navigation row was added on Jeffrey's request."

# --- Alert takeover and outage
c = Canvas(57, 24, "e"); c.center(0, 57, 3, "ALERT"); rows = big("3")
for r in range(3): c.center(0, 57, 6 + r, rows[r])
c.center(0, 57, 11, "ORE CHEST FULL"); c.center(0, 57, 13, "drop point #3 at 10,64,-2"); c.center(0, 57, 15, "turtle #3 parked until it is emptied")

add(c, "Alert takeover (5 s), coral background, ink text")

c = Canvas(57, 24, "c"); c.fill(18, 8, 21, 7, "e"); c.center(18, 21, 9, "NO SERVER"); rows = big("0:42")
for r in range(3): c.center(18, 21, 10 + r, rows[r])
c.center(18, 21, 13, "since last frame")
c.text(1, 0, "STATUS  (last picture, greyed)")
c.text(1, 22, "retrying in 8 s")
add(c, "Outage, last picture greyed (stale slot) with a coral NO SERVER tile")

# --- Server terminal 51x19
c = Canvas(51, 19); c.header("SO SERVER #1", "up 3h12")
for (x, w), (lab, val, sub, bg) in zip([(0,12),(13,12),(26,12),(39,12)], [("TURTLES","3","ok","d"),("DISPLAYS","4","fresh","d"),("DISK","13%","2.1 MB","d"),("ALERTS","1","see log","e")]):
    c.tile(x, 3, w, lab, val, sub, bg, 7)
c.fill(0, 11, 51, 1, "7"); c.text(1, 11, "LOG")
for i, l in enumerate(["21:14:02 lease 2-961 reported ok","21:14:05 drops: hold ore (3)","21:14:09 pair: display 7 joined","21:14:11 mine: #3 wait lane"]):
    c.text(1, 12 + i, l)
c.fill(0, 18, 51, 1, "7"); c.text(1, 18, "[P] pair a client     [L] full log")
add(c, "Server terminal, normal", True)

c = Canvas(51, 19); c.header("SO SERVER #1", "pairing")
c.fill(0, 2, 51, 13, "9"); c.center(0, 51, 3, "PAIR CODE")
rows = big("482 915")
for r in range(3): c.center(0, 51, 6 + r, rows[r])
c.center(0, 51, 11, "4:52 left")
c.fill(0, 18, 51, 1, "7"); c.text(1, 18, "[P] new code     [Esc] cancel")
add(c, "Server terminal, pairing", True)

# --- AR layers screen (M) and tiny 1x1
c = Canvas(57, 24); c.header("AR GOGGLES", "1 controller")
for (x, w), (lab, val, sub, bg) in zip(cols, [("TURTLES","ON","","d"),("LEASES","ON","","d"),("DROPS","OFF","","c")]):
    c.tile(x, 3, w, lab, val, sub, bg)
c.tile(0, 11, 18, "ALERTS", "ON", "", "d")
c.button(0, 20, 57, "BACK")
add(c, "AR layer switches")

c = Canvas(15, 10); c.header("FLEET", "ok"); c.tile(0, 2, 15, "TURTLES", "3", "0 lost", "d"); c.button(0, 8, 15, "NEXT", h=1); c.button(0, 9, 15, "MORE", h=1)
add(c, "Smallest monitor 1x1 at scale 0.5")

for w, h, size in [(26, 20, "P"), (29, 12, "S")]:
    for pending in [False, True]:
        c = Canvas(w, h); c.header("PANEL", "01:00")
        c.text(1, 2, "PAIR NEW CLIENT")
        if pending:
            c.fill(1, 3, w-2, 4, "9")
            for r, row in enumerate(big("123456")):
                c.center(1, w-2, 3+r, row)
            c.center(1, w-2, 6, "4:52 left", "9")
        c.button(0, h-4, w, "NEW CODE", "9")
        c.button(0, h-1, w, "BACK", h=1)
        add(c, "Panel pairing " + ("code" if pending else "ready") + " " + size, True)

add(shop(29, 12), "Shop, compact touch monitor", True)
add(shop(26, 20), "Shop, pocket touch flow", True)
add(shop(100, 38), "Shop, large touch monitor")
status(51,19,[0,6,5,2],4,"Status, terminal")

import argparse
from pathlib import Path
import runpy

map_mockup = runpy.run_path(str(Path(__file__).with_name("map-mockup.py")))

parser = argparse.ArgumentParser()
parser.add_argument("--fixtures", type=Path, nargs="?", const=Path(__file__).resolve().parents[2] / "tests/ui/fixtures")
args = parser.parse_args()

if args.fixtures:
    args.fixtures.mkdir(parents=True, exist_ok=True)
    names = "status-M status-L status-P panel-P mining-M lumber-M shop-M shoporder-M drops-M alert-M outage-M server-T pairing-T ar-M status-XS panelpair-P panelcode-P panelpair-S panelcode-S shop-compact shop-pocket shop-large status-T".split()
    for stem, (canvas, title) in zip(names, FIXTURES):
        layers = [f"{canvas.w}x{canvas.h} {title}"]
        layers += ["".join(row) for row in canvas.t]
        layers += ["".join(row) for row in canvas.b]
        (args.fixtures / (stem + ".txt")).write_text("\n".join(layers) + "\n", encoding="utf-8")
    map_mockup["write"](Canvas, args.fixtures, fixtures=True)
    import shutil
    import subprocess
    root = Path(__file__).resolve().parents[2]
    lua = shutil.which("lua5.2") or shutil.which("lua52") or "C:/Tools/lua52/lua52.exe"
    subprocess.run([lua, str(Path(__file__).with_name("visibility-fixtures.lua")),
                    str(args.fixtures.resolve())], cwd=root, check=True)
    raise SystemExit(0)

open("./mockups.md", "w").write("\n\n".join(M) + "\n")
map_mockup["write"](Canvas, Path("."))
# font table
ft = []
for ch in "0123456789%-:/":
    ft.append(ch + ":  " + "  ".join(FONT[ch]))
open("./font.txt", "w").write("\n".join(ft) + "\n")
print("\n".join(big("0123456789")))
print("\n".join(big("482 915")))
