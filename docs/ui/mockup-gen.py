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
def add(c, name, legend=False, stem=None):
    M.append(c.dump(name, legend))
    FIXTURES.append((c, name, stem))

def grid(w,n):
    available=w-n+1
    return [(int(i*available/n+0.5)+i,int((i+1)*available/n+0.5)-int(i*available/n+0.5)) for i in range(n)]
status_data = [("TURTLES","3","3 ok, 0 lost","d"),("LEASES","2","","b"),("ALERTS","1","ore chest full","e"),
    ("ORE TODAY","214","+12","b"),("LOGS TODAY","96","","d"),("DISK","13%","2.1 of 16 MB","d"),
    ("DISPLAYS","4","all fresh","d"),("DROPS","5","1 broken","1"),("PAIR","","","9")]
def status(w,h,indices,n,title):
    c=Canvas(w,h);c.header("STATUS","21:14");c.alert("! ore chest full (drop 3)" if w!=39 else "! ore chest full")
    cols=grid(w,n);wanted=(len(indices)+n-1)//n
    height=7 if h-4>=wanted*8-1 else 6
    for i,index in enumerate(indices):
        x,width=cols[i%n]; y=3+(i//n)*(height+1)
        lab,val,sub,bg=status_data[index]
        if index==8:
            left=max(1,x);right=min(w-2,x+width-1)
            c.button(left,y+1,right-left+1,"PAIR","9",3)
        else:c.tile(x,y,width,lab,val,sub,bg,height)
    if w==51:
        c.fill(1,11,w-2,1,"7");c.text(1,11,"LOG")
    add(c,title,True)
status(57,24,list(range(9)),3,"Status, room monitor 3x2 at scale 0.5")
status(39,19,[0,2,3,5],2,"Status, wall monitor 4x3 at scale 1")

# --- Pocket role (26x20), so-mod-panel.lua. One-row tab bar, chip rows, one-row controls.
# K mirrors the kit's one-based coordinates so these blocks read like the Lua.
class K:
    def __init__(s, w=26, h=20): s.c, s.w, s.h = Canvas(w, h), w, h
    def put(s, x, y, text, bg=None): s.c.text(x - 1, y - 1, text, bg)
    def fill(s, x, y, w, h, bg): s.c.fill(x - 1, y - 1, w, h, bg)
    def center(s, x, w, y, text, bg=None): s.c.center(x - 1, w, y - 1, text, bg)
    def big(s, x, y, w, text):
        for r, row in enumerate(big(text)): s.center(x, w, y + r, row)
    def button(s, x, y, w, label, bg):
        s.fill(x, y, w, 1, bg)
        inset = 1 if len(label) <= w - 2 else 0
        s.center(x + inset, w - 2 * inset, y, label)
    def chips(s, y, label, chips, x=2, right=None):
        right = right or s.w - 1
        room = right - x - sum(len(t) + 2 for t, _ in chips)
        s.put(x, y, label[:max(0, room)])
        for text, bg in reversed(chips):
            right -= len(text) + 2
            s.put(right + 1, y, " " + text + " ", bg)

POCKET_FLEET = [("TURTLES", [("3 ok", "d"), ("1 lost", "e")]), ("LEASES", [("2 open", "b")]),
    ("ALERTS", [("3", "e")]), ("ORE TODAY", [("214", "b")]), ("LOGS TODAY", [("96", "d")]),
    ("DISK", [("13%", "d")]), ("DISPLAYS", [("4", "d")]), ("DROPS", [("5", "d"), ("1 broken", "1")])]
POCKET_ALERTS = ["ore chest full", "hold saplings chest; fix drop point and start", "drops: hold fuel"]

def fleet_rows(k, top, step):
    for i, (label, chips) in enumerate(POCKET_FLEET): k.chips(top + i * step, label, chips)

def tabs(k, page, alerts=3):
    k.fill(1, 1, k.w, 1, "7")
    x = 1
    for tab in ["FLEET", "JOBS", "SHOP", "PAIR"]:
        active = tab == page or (page == "ALERTS" and tab == "FLEET")
        k.put(x, 1, " " + tab + " ", "9" if active else "e" if tab == "FLEET" and alerts else "7")
        x += len(tab) + 2

def wrap(text, width):
    lines, line = [], ""
    for word in text.split():
        if not line: line = word
        elif len(line) + 1 + len(word) <= width: line += " " + word
        else: lines.append(line); line = word
    return lines + ([line] if line else [])

k = K(); k.c.header("FLEET", "21:14"); fleet_rows(k, 4, 2)
add(k.c, "Status at 26x20 (a pocket assigned status)", True)

k = K(); tabs(k, "FLEET"); fleet_rows(k, 3, 2)
add(k.c, "Pocket FLEET: chip rows; ALERTS opens the list, FLEET turns coral while alerts exist", True, "pocket-fleet-P")

k = K(); tabs(k, "ALERTS"); k.chips(3, "ALERTS", [("3", "e")])
y = 5
for text in POCKET_ALERTS:
    for line in wrap(text, 22)[:3]: k.fill(2, y, 1, 1, "e"); k.put(4, y, line); y += 1
    y += 1
add(k.c, "Pocket ALERTS (a FLEET page), newest first", True, "pocket-alerts-P")

k = K(); tabs(k, "JOBS")
for y, role, state, sbg, facts in [
        (3, "MINING", "running", "d", [("BUSY", "2/3", "d"), ("DEPTH", "-58", "d"), ("BRANCHES", "3/8", "b"), ("MIN FUEL", "640", "d")]),
        (12, "LUMBER", "stopped", "c", [("TREES READY", "2", "d"), ("SAPLINGS", "0", "e"), ("NEXT GROW", "6:20", "b"), ("FUEL", "1210", "d")])]:
    k.fill(2, y, 24, 1, "7"); k.chips(y, role, [(state, sbg)], 3)
    for i, (label, value, bg) in enumerate(facts): k.chips(y + 1 + i, label, [(value, bg)], 3)
    k.button(2, y + 6, 11, "START", "9"); k.button(15, y + 6, 11, "STOP", "e")
add(k.c, "Pocket JOBS: state chip, facts, one-row START and STOP", True, "pocket-jobs-P")

k = K(); tabs(k, "SHOP")
k.fill(2, 3, 21, 1, "0"); k.put(2, 3, " iron_"); k.button(23, 3, 3, "x", "7")
items = [("IRON INGOT", 1240), ("IRON ORE", 312), ("RAW IRON", 48), ("IRON BLOCK", 27),
    ("IRON NUGGET", 5), ("IRON DOOR", 3), ("IRON PICKAXE", 1), ("IRON BARS", 0)]
y = 5
for i, (label, count) in enumerate(items):
    if i == 0: k.fill(2, y, 24, 1, "7")
    k.chips(y, label, [(str(count), "e" if count == 0 else "1" if count <= 16 else "b")])
    y += 1
    if i == 0:
        for (x, w), n in zip(grid(24, 3), [1, 16, 64]): k.button(x + 2, y, w, str(n), "a")
        y += 2
k.put(2, 19, "sent 16 IRON INGOT")
add(k.c, "Pocket SHOP: search, matches, one tap orders the shown item", True, "pocket-shop-P")

for code in [None, "482915"]:
    k = K(); tabs(k, "PAIR")
    k.fill(2, 3, 24, 5, "9" if code else "c"); k.big(2, 4, 24, code or "------")
    if code: k.center(2, 24, 7, "4:52 left")
    k.button(2, 9, 24, "NEW CODE", "9")
    add(k.c, "Pocket PAIR " + ("with a code" if code else "ready"), True, "pocket-code-P" if code else "pocket-pair-P")

# --- Panel role on a 26x20 screen (monitor panels use the same blocks)
c = Canvas(26, 20); c.header("PANEL", "22:14")
c.text(1, 2, "MINING   stopped"); c.button(0, 3, 12, "START", "9"); c.button(13, 3, 13, "STOP", "e")
c.text(1, 7, "LUMBER   running"); c.button(0, 8, 12, "START", "9"); c.button(13, 8, 13, "STOP", "e")
c.text(1, 12, "SHOP     search:"); c.fill(1, 13, 24, 1, "0"); c.text(1, 13, " iron_                  ", "0")
c.button(0, 15, 8, "1", "a"); c.button(9, 15, 8, "16", "a"); c.button(18, 15, 8, "64", "a")
c.fill(0, 19, 26, 1, "7"); c.text(0, 19, " ALERTS  PAIR            ")
add(c, "Panel role at 26x20", True)

# --- Mining, M
c = Canvas(57, 24); c.header("MINING", "running")
cols = [(0,18),(19,19),(39,18)]
for (x, w), (lab, val, sub, bg) in zip(cols, [("BUSY","2/2","both digging","d"),("ORE TODAY","214","iron 120 dia 3","b"),("DEPTH","-12","","d")]):
    c.tile(x, 3, w, lab, val, sub, bg,6)
for (x, w), (lab, val, sub, bg) in zip(cols, [("LANE","1","#3 waiting","1"),("MIN FUEL","640","#3","d"),("BRANCHES","3/8","48 long","b")]):
    c.tile(x, 9, w, lab, val, sub, bg,6)
c.fill(0, 15, 57, 1, "7"); c.text(1, 15, "TURTLE  STATE      POS          FUEL  ORE")
for i, line in enumerate(["#2      mining     12,60,-9      812   14","#3      wait lane   0,61,-1      640    9"]):
    c.text(1, 18 + i, line)
c.fill(0, 18, 1, 1, "d"); c.fill(0, 19, 1, 1, "1")
for (x, w), (label, bg) in zip(cols, [("START", "9"), ("STOP", "e"), ("SETUP", "7")]): c.button(x, 20, w, label, bg)
add(c, "Mining, room monitor")

# --- Lumber, M
c = Canvas(57, 24); c.header("LUMBER", "running")
for (x, w), (lab, val, sub, bg) in zip(cols, [("TREES READY","2","","d"),("LOGS TODAY","96","","d"),("SAPLINGS","0","","e")]):
    c.tile(x, 3, w, lab, val, sub, bg)
c.fill(1,11,12,1,"c"); c.fill(1,11,6,1,"b"); c.text(14,11,"SPOTS 2/4")
c.text(1,12,"NEXT GROW 6:20")
for i, text in enumerate(["#4 felling F1210", "#5 wait chest F640", "#6 scan F640"]):
    c.fill(0,14+i,1,1,"d"); c.text(1,14+i,text)
c.alert("! out of saplings: replanting paused")
for (x, w), (label, bg) in zip(cols, [("START", "9"), ("STOP", "e"), ("SETUP", "7")]): c.button(x, 20, w, label, bg)
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
    for (x, width), label in zip(grid(w, 3), ["<", "1/" + str(max(1, math.ceil(18 / capacity))), ">"]):
        c.button(x, bottom, width, label, h=nav)
    return c

add(shop(57, 24), "Shop, room monitor")
add(shop(57, 24, True), "Shop order page")

# --- Generic / drops page
c = Canvas(57, 24); c.header("DROP POINTS", "5 points")
c.fill(0, 2, 57, 1, "7"); c.text(1, 2, "ID  KIND     WHERE          SIDE   STATE")
rows = [("1  ore      10,64,-2       front  ok","d"),("2  fuel     12,64,-2       front  ok","d"),("3  wood     -4,64,10       front  ok","d"),("4  saplings -6,64,10       front  ok","d"),("5  any       0,64,4        down   broken","e")]
for i, (t, bg) in enumerate(rows): c.fill(0, 3+i, 1, 1, bg); c.text(1, 3+i, t)
for (x, w), (label, bg) in zip(cols, [("FIX #5", "9"), ("REMOVE", "7"), ("ADD NEW", "7")]): c.button(x, 21, w, label, bg)
add(c, "Drop points (drops role)")

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
c.fill(0, 18, 51, 1, "7"); c.text(1, 18, "[P] pair a client   [R] roles   [L] full log")
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
for i, (lab, val, sub, bg) in enumerate([("TURTLES","ON","","d"),("LEASES","ON","","d"),("DROPS","OFF","","c"),("ALERTS","ON","","d")]):
    c.tile([0, 29][i % 2], 3 + (i // 2) * 8, 28, lab, val, sub, bg)
add(c, "AR layer switches")

c = Canvas(15, 10); c.header("FLEET", "ok"); c.tile(0, 2, 15, "TURTLES", "3", "3 ok, 0 lost", "d", 7); c.button(0, 9, 15, "NEXT", h=1)
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
        c.button(0, h-5, w, "PAIRED", h=1)
        c.button(0, h-4, w, "NEW CODE", "9")
        c.button(0, h-1, w, "BACK", h=1)
        add(c, "Panel pairing " + ("code" if pending else "ready") + " " + size, True)

add(shop(29, 12), "Shop, compact touch monitor", True)
add(shop(26, 20), "Shop, pocket touch flow", True)
add(shop(100, 38), "Shop, large touch monitor")
status(51,19,[0,6,5,2],4,"Status, terminal")

# --- Displays without a role show their id; the operator assigns one on the server
def unassigned(w, h, ident):
    c = Canvas(w, h); c.header("UNASSIGNED", "")
    top = 3 if h >= 10 else 2
    height = h - top - 1
    c.fill(1, top, w - 2, height, "9")
    if height >= 7: c.text(2, top + 1, "DISPLAY")
    rows = big(ident)
    for r in range(3): c.center(1, w - 2, top + max(0, (height - 3) // 2) + r, rows[r])
    return c
add(unassigned(57, 24, "6"), "Unassigned display, room monitor", True)
add(unassigned(15, 10, "6"), "Unassigned display, smallest monitor", True)

c = Canvas(51, 19); c.header("SO SERVER #1", "roles")
c.fill(0, 3, 51, 1, "7"); c.text(1, 3, "ID    SIZE    ROLE")
for i, (ident, size, role) in enumerate([("1", "57x24", "status"), ("2", "26x20", "pocket"), ("5", "57x24", "mining"),
        ("6", "57x24", "unassigned"), ("7", "15x10", "status"), ("9", "-", "drops")]):
    c.text(1, 4 + i, f"{ident:<6}{size:<8}{role}")
c.text(1, 17, "display 7: status")
c.fill(0, 18, 51, 1, "7"); c.text(1, 18, "> 6 shop_"); c.text(26, 18, "[Enter] set  [Esc] back")
add(c, "Server terminal, role command (R)", True)

for w, h in [(26, 20), (29, 12)]:
    for setup in [False, True]:
        c = Canvas(w, h); c.header("BUILD", "stopped")
        if setup:
            c.text(1, 3, "AREA -"); c.text(1, 6, "MATERIAL -"); c.text(1, 7, "TURTLE -")
            for (x, width), label in zip(grid(w, 2), ["FLOOR", "BACK"]):
                c.button(x, h-3, width, label)
        else:
            c.fill(0, 3, w, 5, "d"); c.center(0, w, 3, "FLOOR", "d")
            for r, row in enumerate(big("0")): c.center(0, w, 4+r, row, "d")
            c.text(1, 8, "OF 0")
            if h >= 16:
                c.text(1, 10, "MATERIAL -"); c.text(1, 12, "TURTLE -")
            height = 3 if h >= 16 else 1
            for (x, width), label, bg in zip(grid(w, 4), ["START", "STOP", "SETUP", "BACK"], ["9", "e", "7", "7"]):
                c.button(x, h-height, width, label, bg, height)
        add(c, "Builder " + ("setup" if setup else "job") + f" {w}x{h}", True)

import hashlib
for w, h, size in [(26, 20, "P"), (29, 12, "S")]:
    c = Canvas(w, h); c.header("PAIRED", "")
    for i in range((h-4)//3):
        device = i+2
        y = 2+i*3
        c.text(1, y, f"#{device} ?")
        fingerprint = hashlib.sha256((f"{device:02x}"*32).encode()).hexdigest()[:4].upper()
        c.text(w-5, y, fingerprint)
        c.text(1, y+1, "-")
        if device != 2:
            c.button(w-13, y+1, 12, "FORGET", "e", h=1)
    for (x, width), label in zip(grid(w, 3), ["PREV", "BACK", "NEXT"]):
        c.button(x, h-1, width, label, h=1)
    add(c, "Paired devices " + size, True)

import argparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--fixtures", type=Path, nargs="?", const=Path(__file__).resolve().parents[2] / "tests/ui/fixtures")
args = parser.parse_args()

if args.fixtures:
    args.fixtures.mkdir(parents=True, exist_ok=True)
    names = "status-M status-L status-P panel-P mining-M lumber-M shop-M shoporder-M drops-M alert-M outage-M server-T pairing-T ar-M status-XS panelpair-P panelcode-P panelpair-S panelcode-S shop-compact shop-pocket shop-large status-T unassigned-M unassigned-XS roles-T build-26x20 buildsetup-26x20 build-29x12 buildsetup-29x12 paired-P paired-S".split()
    named = [(stem, canvas, title) for canvas, title, stem in FIXTURES if stem]
    named += [(stem, canvas, title) for stem, (canvas, title, _) in zip(names, [f for f in FIXTURES if not f[2]])]
    # Screens ported to route A get their fixtures from docs/ui/schematic/screens.py instead,
    # including the five shop names, which now hold route A pages.
    ported = {"status-M", "status-L", "status-P", "status-T", "status-XS",
              "shop-M", "shoporder-M", "shop-compact", "shop-pocket", "shop-large",
              "pocket-fleet-P", "pocket-alerts-P", "pocket-jobs-P", "pocket-shop-P", "pocket-pair-P", "pocket-code-P",
              "alert-M", "outage-M", "server-T", "pairing-T", "roles-T", "unassigned-M", "unassigned-XS",
              "mining-M", "lumber-M", "drops-M",
              "panel-P", "panelpair-P", "panelcode-P", "panelpair-S", "panelcode-S", "paired-P", "paired-S",
              "build-26x20", "buildsetup-26x20", "build-29x12", "buildsetup-29x12", "ar-M"}
    for stem, canvas, title in named:
        if stem in ported:
            continue
        layers = [f"{canvas.w}x{canvas.h} {title}"]
        layers += ["".join(row) for row in canvas.t]
        layers += ["".join(row) for row in canvas.b]
        (args.fixtures / (stem + ".txt")).write_text("\n".join(layers) + "\n", encoding="utf-8")
    raise SystemExit(0)

open("./mockups.md", "w").write("\n\n".join(M) + "\n")
# font table
ft = []
for ch in "0123456789%-:/":
    ft.append(ch + ":  " + "  ".join(FONT[ch]))
open("./font.txt", "w").write("\n".join(ft) + "\n")
print("\n".join(big("0123456789")))
print("\n".join(big("482 915")))
