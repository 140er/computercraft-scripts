# Top-down map mockups. Mirrors so-mod-map.lua on the scene in map-scene.txt;
# tests/so/map.lua renders the same scene through the real module and compares.
import math
from pathlib import Path

COLOUR = {1: "0", 2: "0", 3: "d", 4: "1", 5: "d", 6: "b", 7: "1"}
NAMES = {1: "PLANNED", 2: "DUG", 3: "FARM", 4: "SAPLING", 5: "TREE", 6: "LANE", 7: "HELD"}
LETTERS = {"ore": "O", "fuel": "F", "junk": "J", "wood": "W", "storage": "C", "any": "A", "saplings": "S"}
ARROWS = "^>v<"
LABELS = {"map-fit": "FIT", "map-in": "+", "map-out": "-", "map-n": "^", "map-s": "v", "map-w": "<",
          "map-e": ">", "map-up": "UP", "map-down": "DN"}
DIRS = [(0, -1), (1, 0), (0, 1), (-1, 0)]
HEADER_ROW = 2


def sextant(bits):
    if bits == 0: return " "
    if bits == 63: return "█"
    if bits == 21: return "▌"
    if bits == 42: return "▐"
    return chr(0x1FB00 + bits - 1 - (bits > 21) - (bits > 42))


def load_scene(path):
    s = {"dug": set(), "reserved": [], "turtles": [], "drops": [], "spots": [], "views": [], "server": None,
         "g": None, "area": None}
    for line in Path(path).read_text().splitlines():
        a = line.split()
        if not a: continue
        n = [int(x) for x in a[1:] if x.lstrip("-").isdigit()]
        if a[0] == "server": s["server"] = dict(x=n[0], y=n[1], z=n[2])
        elif a[0] == "mine":
            x, y, z, f, bottom, length, branches = n
            d, r = DIRS[f % 4], DIRS[(f + 1) % 4]
            gap = 2 if a[7] == "fast" else 4
            s["g"] = dict(x=x + d[0], z=z + d[1], top=y, bottom=bottom, dx=d[0], dz=d[1], rx=r[0], rz=r[1],
                          gap=gap, branches=branches, length=length, spine=branches * gap)
        elif a[0] in ("dug", "reserve"):
            box = [int(v) for v in a[-6:]]
            for x in range(box[0], box[3] + 1):
                for y in range(box[1], box[4] + 1):
                    for z in range(box[2], box[5] + 1):
                        if a[0] == "dug": s["dug"].add((x, y, z))
                        else: s["reserved"].append(dict(x=x, y=y, z=z, who=a[1]))
        elif a[0] == "turtle":
            ident, x, y, z, f = n
            state = a[6]
            colour = "e" if state in ("lost", "range") else "b" if state == "done" else \
                "d" if state in ("mining", "working", "lumber") or ("open" in a[7:] and state not in ("stopped", "idle")) else "1"
            s["turtles"].append(dict(id=ident, x=x, y=y, z=z, facing=f, color=colour, label=state.upper()))
        elif a[0] == "drop": s["drops"].append(dict(kind=a[1], x=n[0], y=n[1], z=n[2], broken="broken" in a))
        elif a[0] == "saplings": s["saplings"] = dict(kind="saplings", x=n[0], y=n[1], z=n[2], broken=False)
        elif a[0] == "farm": s["area"] = dict(x1=n[0], z1=n[1], x2=n[2], z2=n[3]); s["ground"] = n[4]
        elif a[0] == "spot": s["spots"].append(dict(x=n[0], z=n[1], ready=a[3] == "ready"))
        elif a[0] == "view":
            w, h = map(int, a[1].split("x"))
            v = dict(w=w, h=h, level="all" if a[2] == "all" else int(a[2]), fit=a[3] == "fit", focus=None)
            rest = a[4:]
            if a[3] == "zoom":
                v.update(zoom=int(a[4]), cx=int(a[5]), cz=int(a[6]))
                rest = a[7:]
            if rest and rest[0] == "focus": v["focus"] = (int(rest[1]), int(rest[2]))
            s["views"].append(v)
    s["turtles"].sort(key=lambda t: t["id"])
    if "saplings" in s: s["drops"].append(s["saplings"])
    return s


def row(buttons, y, w, ids, weights):
    total, acc, free = sum(weights), 0, w - (len(ids) - 1)
    for i, ident in enumerate(ids):
        a = math.floor(acc * free / total + 0.5)
        acc += weights[i]
        buttons.append(dict(id=ident, x=1 + a + i, y=y, w=math.floor(acc * free / total + 0.5) - a, h=1))


def layout(w, h):
    top = HEADER_ROW + 1
    rows = h - top + 1
    L = dict(mx=1, my=top, buttons=[])
    add = lambda ident, x, y, width, height: L["buttons"].append(dict(id=ident, x=x, y=y, w=width, h=height))
    if w >= 29 and rows >= 8 and w * 6 >= h * 9:
        rw = 15 if w >= 90 else 9
        rx, bh = w - rw, 3 if rows >= 29 else 1
        every = rows >= 8 * bh + 5
        some, third, half = every or rows >= 8 * bh + 2, rw // 3, (rw - 1) // 2
        y = top
        L.update(mw=rx - 2, mh=rows)
        add("map-fit", rx, y, rw, bh); y += bh + every
        add("map-out", rx, y, half, bh); add("map-in", rx + rw - half, y, half, bh); y += bh + some
        add("map-n", rx + third, y, third, bh); add("map-w", rx, y + bh, third, bh)
        add("map-e", rx + 2 * third, y + bh, third, bh); add("map-s", rx + third, y + 2 * bh, third, bh)
        y += 3 * bh + some
        add("map-up", rx, y, rw, bh); y += bh + every
        add("map-level", rx, y, rw, bh); y += bh + every
        add("map-down", rx, y, rw, bh)
    else:
        L.update(mw=w, mh=max(1, h - top - 1))
        if w >= 23:
            row(L["buttons"], h - 1, w, ["map-w", "map-n", "map-s", "map-e", "map-out", "map-in"], [3] * 6)
            row(L["buttons"], h, w, ["map-fit", "map-down", "map-level", "map-up"], [5, 4, 7, 4])
        else:
            row(L["buttons"], h - 1, w, ["map-w", "map-n", "map-s", "map-e"], [3] * 4)
            row(L["buttons"], h, w, ["map-out", "map-fit", "map-in", "map-level"], [3, 5, 3, 7])
    return L


def bounds(s):
    pts = []
    g = s["g"]
    if g:
        pts.append((g["x"], g["z"]))
        if g["branches"] > 0:
            pts.append((g["x"] + g["dx"] * g["spine"], g["z"] + g["dz"] * g["spine"]))
            pts.append((g["x"] + g["dx"] * g["gap"] + g["rx"] * g["length"], g["z"] + g["dz"] * g["gap"] + g["rz"] * g["length"]))
            pts.append((g["x"] + g["dx"] * g["spine"] + g["rx"] * g["length"], g["z"] + g["dz"] * g["spine"] + g["rz"] * g["length"]))
    if s["area"]: pts += [(s["area"]["x1"], s["area"]["z1"]), (s["area"]["x2"], s["area"]["z2"])]
    if s["server"]: pts.append((s["server"]["x"], s["server"]["z"]))
    pts += [(p["x"], p["z"]) for p in s["drops"]] + [(t["x"], t["z"]) for t in s["turtles"]]
    xs, zs = [p[0] for p in pts], [p[1] for p in pts]
    return min(xs), min(zs), max(xs), max(zs)


def lane(g, c):
    if c["x"] == g["x"] and c["z"] == g["z"]:
        return min(g["top"], g["bottom"]) <= c["y"] <= max(g["top"], g["bottom"])
    ax, az = c["x"] - g["x"], c["z"] - g["z"]
    along = ax * g["dx"] + az * g["dz"]
    return c["y"] == g["bottom"] and ax * g["dz"] - az * g["dx"] == 0 and 0 <= along <= g["spine"]


def render(Canvas, s, view):
    w, h = view["w"], view["h"]
    c = Canvas(w, h)
    L = layout(w, h)
    pw, ph = L["mw"] * 2, L["mh"] * 3
    v = dict(view)
    if v["fit"]:
        b = bounds(s)
        zoom = -1
        while zoom < 8 and ((b[2] - b[0] + 1) / 2 ** zoom > pw - 2 or (b[3] - b[1] + 1) / 2 ** zoom > ph - 2):
            zoom += 1
        v.update(zoom=zoom, cx=(b[0] + b[2]) // 2, cz=(b[1] + b[3]) // 2)
    scale = 2.0 ** v["zoom"]
    left, top = v["cx"] - math.floor(pw * scale / 2), v["cz"] - math.floor(ph * scale / 2)
    level, n, g, area = v["level"], round(1 / scale) if scale < 1 else 1, s["g"], s["area"]
    every = level == "all"
    r = {}

    def put(px, pz, cls):
        if 0 <= px < pw and 0 <= pz < ph and (cls != 1 or (px // n + pz // n) % 2 == 0):
            k = pz * pw + px
            if r.get(k, 0) < cls: r[k] = cls

    def block(x, z, cls):
        px, pz = math.floor((x - left) / scale), math.floor((z - top) / scale)
        for i in range(n):
            for j in range(n): put(px + i, pz + j, cls)

    def line(x1, z1, x2, z2, cls):
        for px in range(max(0, math.floor((min(x1, x2) - left) / scale)), min(pw - 1, math.floor((max(x1, x2) - left) / scale) + n - 1) + 1):
            for pz in range(max(0, math.floor((min(z1, z2) - top) / scale)), min(ph - 1, math.floor((max(z1, z2) - top) / scale) + n - 1) + 1):
                put(px, pz, cls)

    if g and (every or level == g["bottom"]):
        if g["spine"] > 0:
            line(g["x"] + g["dx"], g["z"] + g["dz"], g["x"] + g["dx"] * g["spine"], g["z"] + g["dz"] * g["spine"], 1)
        for k in range(1, g["branches"] + 1):
            x, z = g["x"] + g["dx"] * k * g["gap"], g["z"] + g["dz"] * k * g["gap"]
            line(x + g["rx"], z + g["rz"], x + g["rx"] * g["length"], z + g["rz"] * g["length"], 1)
    farm = area and (every or s["ground"] <= level <= s["ground"] + 8)
    if farm:
        ax1, ax2 = min(area["x1"], area["x2"]), max(area["x1"], area["x2"])
        az1, az2 = min(area["z1"], area["z2"]), max(area["z1"], area["z2"])
        line(ax1, az1, ax2, az1, 3); line(ax1, az2, ax2, az2, 3); line(ax1, az1, ax1, az2, 3); line(ax2, az1, ax2, az2, 3)
        for spot in s["spots"]: block(spot["x"], spot["z"], 5 if spot["ready"] else 4)
    for x, z in sorted({(x, z) for x, y, z in s["dug"] if every or y == level}):
        if not (farm and ax1 <= x <= ax2 and az1 <= z <= az2): block(x, z, 2)
    for cell in s["reserved"]:
        if every or cell["y"] == level: block(cell["x"], cell["z"], 6 if g and lane(g, cell) else 7)

    mx, my, mw, mh = L["mx"], L["my"], L["mw"], L["mh"]
    for cy in range(mh):
        for cx in range(mw):
            best, bits = 0, 0
            for j in range(3):
                k = (cy * 3 + j) * pw + cx * 2
                if k in r: bits += 1 << (2 * j); best = max(best, r[k])
                if k + 1 in r: bits += 1 << (2 * j + 1); best = max(best, r[k + 1])
            if best:
                colour = COLOUR[best]
                if colour == "0": c.text(mx + cx - 1, my + cy - 1, sextant(bits), "f")
                else: c.text(mx + cx - 1, my + cy - 1, sextant(63 - bits), colour)

    def cell_of(x, z):
        px, pz = math.floor((x - left) / scale), math.floor((z - top) / scale)
        if px < 0 or pz < 0 or px >= pw or pz >= ph: return None
        return px // 2, pz // 3

    occ = {}

    def mark(x, z, ch, bg, item):
        at = cell_of(x, z)
        if at:
            c.text(mx + at[0] - 1, my + at[1] - 1, ch, bg)
            occ[at] = item
        return at

    near = lambda p: every or abs(p["y"] - level) <= 1
    for p in s["drops"]:
        if near(p): mark(p["x"], p["z"], LETTERS.get(p["kind"], "?"), "e" if p["broken"] else "a", p)
    if s["server"] and near(s["server"]): mark(s["server"]["x"], s["server"]["z"], "@", "9", "server")
    if g: mark(g["x"], g["z"], "H", "9", "shaft")
    for t in reversed(s["turtles"]): t["at"] = mark(t["x"], t["z"], ARROWS[t["facing"]], t["color"], t)
    for t in s["turtles"] if scale <= 2 else []:
        at = t["at"]
        if at and occ.get(at) is t:
            text = str(t["id"])
            for offset in ([-len(text), 1] if t["facing"] == 1 else [1, -len(text)]):
                start = at[0] + offset
                if all(0 <= x < mw and (x, at[1]) not in occ for x in range(start, start + len(text))):
                    c.text(mx + start - 1, my + at[1] - 1, text, t["color"])
                    for x in range(start, start + len(text)): occ[(x, at[1])] = t
                    break

    label, coords = "", ""
    focus = v["focus"] and cell_of(*v["focus"])
    if focus:
        item = occ.get(focus)
        if not item: c.text(mx + focus[0] - 1, my + focus[1] - 1, "+", "0")
        if isinstance(item, dict) and "label" in item:
            label, coords = "#%d %s" % (item["id"], item["label"]), "%d,%d,%d" % (item["x"], item["y"], item["z"])
        elif item == "shaft": label, coords = "SHAFT", "%d,%d" % (g["x"], g["z"])
        elif item == "server": label, coords = "SERVER", "%d,%d,%d" % (s["server"]["x"], s["server"]["y"], s["server"]["z"])
        elif item:
            label = item["kind"].upper() + (" BROKEN" if item["broken"] else "")
            coords = "%d,%d,%d" % (item["x"], item["y"], item["z"])
        else:
            best = max(r.get((focus[1] * 3 + j) * pw + focus[0] * 2 + i, 0) for j in range(3) for i in range(2))
            label = NAMES.get(best, "")
            if best >= 6:
                owner = next(cell["who"] for cell in s["reserved"] if (every or cell["y"] == level)
                             and cell_of(cell["x"], cell["z"]) == focus)
                label += " #" + owner.split(":")[-1]
            fx, fz = v["focus"]
            coords = "%d,%d" % (fx, fz) if every else "%d,%d,%d" % (fx, level, fz)
    room = max(0, w - 7)
    text = ((label + " ") if label else "") + coords if len(label) + len(coords) + 1 <= room else label[:room]
    c.header("MAP", text)
    for b in L["buttons"]:
        value = b["id"] == "map-level" and ("ALL" if every else "Y%d" % level)
        bg = "9" if b["id"] == "map-fit" and v["fit"] else "b" if value else "7"
        c.button(b["x"] - 1, b["y"] - 1, b["w"], LABELS.get(b["id"]) or value, bg, b["h"])
    return c


def generate(Canvas):
    s = load_scene(Path(__file__).with_name("map-scene.txt"))
    scenes = []
    for view in s["views"]:
        w, h = view["w"], view["h"]
        what = "all levels" if view["level"] == "all" else "level %d" % view["level"]
        scenes.append((f"map-{w}x{h}", render(Canvas, s, view), f"Map, {what} {w}x{h}"))
    return scenes


def write(Canvas, destination, fixtures=False):
    destination = Path(destination)
    scenes = generate(Canvas)
    if fixtures:
        for stem, canvas, title in scenes:
            layers = [f"{canvas.w}x{canvas.h} {title}"]
            layers += ["".join(row) for row in canvas.t]
            layers += ["".join(row) for row in canvas.b]
            (destination / (stem + ".txt")).write_text("\n".join(layers) + "\n", encoding="utf-8")
    else:
        (destination / "map-mockups.md").write_text(
            "\n\n".join(canvas.dump(title, True) for _, canvas, title in scenes) + "\n", encoding="utf-8")
