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
    def header(s, name, right="21:14"):
        s.fill(0, 0, s.w, 1, "7")
        s.text(1, 0, name)
        s.text(s.w - len(right) - 1, 0, right)
    def alert(s, msg):
        s.fill(0, 1, s.w, 1, "e")
        s.text(1, 1, msg[:s.w-2])
    def tile(s, x, y, w, label, value, sub="", bg="d", h=5):
        s.fill(x, y, w, h, bg)
        s.text(x + 1, y, label[:w-2])
        rows = big(value)
        for r in range(3):
            s.center(x, w, y + 1 + r, rows[r])
        if sub: s.text(x + 1, y + 4, sub[:w-2])
    def button(s, x, y, w, label, bg="7", h=3):
        s.fill(x, y, w, h, bg)
        s.center(x, w, y + h // 2, label)
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
def add(c, name, legend=False): M.append(c.dump(name, legend))

# --- Status, M (3x2 @0.5 = 57x24): 3 tile columns 18/19/18, 3 tile rows
c = Canvas(57, 24); c.header("STATUS", "21:14  ok"); c.alert("! ore chest full (drop 3)          tap for alerts")
cols = [(0,18),(19,19),(39,18)]
data = [[("TURTLES","3","3 ok, 0 lost","d"),("LEASES","2","open now","b"),("ALERTS","1","ore chest full","e")],
        [("ORE TODAY","214","+12 last 10 min","b"),("LOGS TODAY","96","4 trees","d"),("DISK","13%","2.1 of 16 MB","d")],
        [("DISPLAYS","4","all fresh","d"),("DROPS","5","1 broken","1"),("PAIR","P","press P on server","9")]]
for r, row in enumerate(data):
    for (x, w), (lab, val, sub, bg) in zip(cols, row):
        if val == "P":
            c.fill(x, 2 + r*6 + 1, w, 5, bg); c.text(x+1, 2+r*6+1, lab); c.center(x, w, 2+r*6+3, "new client:"); c.text(x+1, 2+r*6+5, sub)
        else:
            c.tile(x, 2 + r*6 + 1, w, lab, val, sub, bg)
for (x, w), (lab, bg) in zip([(0,13),(14,14),(29,14),(44,13)], [("MINING","7"),("LUMBER","7"),("SHOP","a"),("MORE","7")]):
    c.button(x, 21, w, lab, bg)
add(c, "Status, room monitor 3x2 at scale 0.5", True)

# --- Status, L (4x3 @1 = 39x19): 2 columns 19/19, 2 rows
c = Canvas(39, 19); c.header("STATUS", "ok")
c.alert("! ore chest full")
cols = [(0,19),(20,19)]
data = [[("TURTLES","3","3 ok","d"),("ALERTS","1","ore chest full","e")],
        [("ORE TODAY","214","+12 / 10 min","b"),("DISK","13%","2.1 of 16 MB","d")]]
for r, row in enumerate(data):
    for (x, w), (lab, val, sub, bg) in zip(cols, row):
        c.tile(x, 3 + r*6, w, lab, val, sub, bg)
c.button(0, 16, 12, "MINING"); c.button(13, 16, 12, "SHOP", "a"); c.button(26, 16, 13, "MORE")
add(c, "Status, wall monitor 4x3 at scale 1", True)

# --- Pocket glance (26x20): 3 tiles of 5 rows + nav
c = Canvas(26, 20); c.header("FLEET", "21:14")
for i, (lab, val, sub, bg) in enumerate([("TURTLES","3","3 ok, 0 lost","d"),("ALERTS","1","ore chest full","e"),("ORE TODAY","214","+12 / 10 min","b")]):
    c.tile(0, 1 + i*6, 26, lab, val, sub, bg)
c.fill(0, 19, 26, 1, "7"); c.text(0, 19, " <  glance 1/3  >  PANEL ")
add(c, "Pocket, glance mode", True)

# --- Pocket panel mode (26x20)
c = Canvas(26, 20); c.header("PANEL", "21:14")
c.text(1, 2, "MINING   stopped"); c.button(0, 3, 12, "START", "9"); c.button(13, 3, 13, "STOP", "e")
c.text(1, 7, "LUMBER   running"); c.button(0, 8, 12, "START", "9"); c.button(13, 8, 13, "STOP", "e")
c.text(1, 12, "SHOP     search:"); c.fill(1, 13, 24, 1, "0"); c.text(1, 13, " iron_                  ", "0")
c.button(0, 15, 8, "1", "a"); c.button(9, 15, 8, "16", "a"); c.button(18, 15, 8, "64", "a")
c.fill(0, 19, 26, 1, "7"); c.text(0, 19, " GLANCE  ALERTS  PAIR    ")
add(c, "Pocket, panel mode", True)

# --- Mining, M
c = Canvas(57, 24); c.header("MINING", "running")
cols = [(0,18),(19,19),(39,18)]
for (x, w), (lab, val, sub, bg) in zip(cols, [("BUSY","2/2","both digging","d"),("ORE TODAY","214","iron 120 dia 3","b"),("DEPTH","-12","bottom -16","d")]):
    c.tile(x, 2, w, lab, val, sub, bg)
for (x, w), (lab, val, sub, bg) in zip(cols, [("LANE","1","#3 waiting","1"),("MIN FUEL","640","#3","d"),("BRANCHES","3/8","48 long","b")]):
    c.tile(x, 8, w, lab, val, sub, bg)
c.fill(0, 14, 57, 1, "7"); c.text(1, 14, "TURTLE  STATE      POS          FUEL  ORE")
for i, line in enumerate(["#2      mining     12,60,-9      812   14","#3      wait lane   0,61,-1      640    9"]):
    c.text(1, 15 + i, line)
c.fill(0, 15, 1, 1, "d"); c.fill(0, 16, 1, 1, "1")
c.button(0, 20, 13, "START", "9"); c.button(14, 20, 13, "STOP", "e"); c.button(28, 20, 14, "SETUP"); c.button(43, 20, 14, "BACK")
add(c, "Mining, room monitor")

# --- Lumber, M
c = Canvas(57, 24); c.header("LUMBER", "running")
for (x, w), (lab, val, sub, bg) in zip(cols, [("TREES READY","2","of 4 spots","d"),("LOGS TODAY","96","to wood chest","b"),("SAPLINGS","0","chest empty","e")]):
    c.tile(x, 2, w, lab, val, sub, bg)
for (x, w), (lab, val, sub, bg) in zip(cols, [("TURTLE","4","felling","d"),("FUEL","1210","ok","d"),("NEXT GROW","6:20","min:sec","b")]):
    c.tile(x, 8, w, lab, val, sub, bg)
c.alert("! out of saplings: replanting paused")
c.button(0, 20, 13, "START", "9"); c.button(14, 20, 13, "STOP", "e"); c.button(28, 20, 14, "SETUP"); c.button(43, 20, 14, "BACK")
add(c, "Lumber, room monitor")

# --- Shop, M: search + item tiles (purple header accent)
c = Canvas(57, 24); c.header("SHOP", "stock 21:14"); c.fill(0, 0, 57, 1, "a"); c.text(1, 0, "SHOP"); c.text(45, 0, "stock 21:14")
c.fill(1, 2, 55, 1, "0"); c.text(1, 2, " search: iron_                                         ", "0")
items = [("IRON INGOT","1240","^ +60/h","b"),("IRON ORE","312","- steady","b"),("RAW IRON","48","v -20/h","1")]
for (x, w), (lab, val, sub, bg) in zip(cols, items): c.tile(x, 4, w, lab, val, sub, bg)
items = [("IRON BLOCK","27","- steady","b"),("IRON NUGGET","5","v low","1"),("IRON BARS","0","empty","e")]
for (x, w), (lab, val, sub, bg) in zip(cols, items): c.tile(x, 10, w, lab, val, sub, bg)
c.text(1, 16, "Order: 16 iron_ingot sent to output chest")
c.button(0, 18, 18, "< PREV"); c.button(19, 18, 19, "page 1/3"); c.button(39, 18, 18, "NEXT >")
c.button(0, 21, 28, "CLEAR SEARCH"); c.button(29, 21, 28, "BACK")
add(c, "Shop, room monitor (tap an item tile for the order page)")

c = Canvas(57, 24); c.fill(0, 0, 57, 1, "a"); c.text(1, 0, "SHOP > IRON INGOT")
c.tile(0, 2, 57, "IN STOCK", "1240", "^ +60 per hour", "b")
c.button(0, 8, 18, "ORDER 1", "a", 5); c.button(19, 8, 19, "ORDER 16", "a", 5); c.button(39, 8, 18, "ORDER 64", "a", 5)
c.text(1, 14, "Order: 16 iron_ingot ok (2 s ago)")
c.button(0, 21, 57, "BACK")
add(c, "Shop order page")

# --- Generic / drops page
c = Canvas(57, 24); c.header("DROP POINTS", "5 points")
c.fill(0, 2, 57, 1, "7"); c.text(1, 2, "ID  KIND     WHERE          SIDE   STATE")
rows = [("1  ore      10,64,-2       front  ok","d"),("2  fuel     12,64,-2       front  ok","d"),("3  wood     -4,64,10       front  ok","d"),("4  saplings -6,64,10       front  ok","d"),("5  any       0,64,4        down   broken","e")]
for i, (t, bg) in enumerate(rows): c.fill(0, 3+i, 1, 1, bg); c.text(1, 3+i, t)
c.button(0, 10, 13, "FIX #5", "9"); c.button(14, 10, 13, "REMOVE"); c.button(28, 10, 14, "ADD NEW"); c.button(43, 10, 14, "BACK")
add(c, "Drop points (generic)")

# --- Alert takeover and outage
c = Canvas(57, 24, "e"); c.center(0, 57, 3, "ALERT"); rows = big("3")
for r in range(3): c.center(0, 57, 6 + r, rows[r])
c.center(0, 57, 11, "ORE CHEST FULL"); c.center(0, 57, 13, "drop point #3 at 10,64,-2"); c.center(0, 57, 15, "turtle #3 parked until it is emptied")
c.center(0, 57, 20, "(back to the screen in 5 s, or tap)")
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
    c.tile(x, 2, w, lab, val, sub, bg)
c.fill(0, 8, 51, 1, "7"); c.text(1, 8, "LOG")
for i, l in enumerate(["21:14:02 lease 2-961 reported ok","21:14:05 drops: hold ore (3)","21:14:09 pair: display 7 joined","21:14:11 mine: #3 wait lane"]):
    c.text(1, 9 + i, l)
c.fill(0, 18, 51, 1, "7"); c.text(1, 18, "[P] pair a client     [L] full log")
add(c, "Server terminal, normal", True)

c = Canvas(51, 19); c.header("SO SERVER #1", "pairing")
c.fill(0, 2, 51, 13, "9"); c.center(0, 51, 3, "PAIR CODE  (type it on the new client)")
rows = big("482 915")
for r in range(3): c.center(0, 51, 6 + r, rows[r])
c.center(0, 51, 11, "4:52 left, works once")
c.center(0, 51, 13, "5 wrong tries burn the code")
c.fill(0, 18, 51, 1, "7"); c.text(1, 18, "[P] new code     [Esc] cancel")
add(c, "Server terminal, pairing", True)

# --- AR layers screen (M) and tiny 1x1
c = Canvas(57, 24); c.header("AR GOGGLES", "1 controller")
for (x, w), (lab, val, sub, bg) in zip(cols, [("TURTLES","1","layer on","d"),("LEASES","1","layer on","d"),("DROPS","0","layer off","c")]):
    c.tile(x, 2, w, lab, val, sub, bg)
c.tile(0, 8, 18, "ALERTS", "1", "layer on", "d"); c.text(20, 9, "tap a tile to switch its layer")
c.button(0, 20, 57, "BACK")
add(c, "AR layer switches (1 = on, 0 = off)")

c = Canvas(15, 10); c.header("FLEET", "ok"); c.tile(0, 2, 15, "TURTLES", "3", "0 lost", "d"); c.fill(0, 8, 15, 2, "7"); c.center(0, 15, 8, "tap: next")
add(c, "Smallest monitor 1x1 at scale 0.5")

open("./mockups.md", "w").write("\n\n".join(M) + "\n")
# font table
ft = []
for ch in "0123456789%-:/":
    ft.append(ch + ":  " + "  ".join(FONT[ch]))
open("./font.txt", "w").write("\n".join(ft) + "\n")
print("\n".join(big("0123456789")))
print("\n".join(big("482 915")))
