"""Route A map prototype: line glyphs per text cell, markers and greedy inline labels.

so-mod-map.lua will get the Lua version of this cell pass and label placer; until then the status
wall draws its thumbnail from here in the generator and through map.thumb in the server."""
from scene import S

ARROW = {0: "▲", 1: "►", 2: "▼", 3: "◄"}
SX = [1, 2, 3, 4, 6, 8, 12, 16]

def geometry():
    g, geo = S["g"], set()
    geo.add((g["x"], g["z"]))
    for k in range(1, g["spine"] + 1): geo.add((g["x"] + g["dx"] * k, g["z"] + g["dz"] * k))
    for b in range(1, g["branches"] + 1):
        bx, bz = g["x"] + g["dx"] * b * g["gap"], g["z"] + g["dz"] * b * g["gap"]
        for k in range(1, g["length"] + 1): geo.add((bx + g["rx"] * k, bz + g["rz"] * k))
    return geo

def small(cls, geo, limit=7):
    """Dug blocks off the mine geometry in pieces under `limit` blocks: ore digs, not passages."""
    off = {p for p, c in cls.items() if p not in geo}
    seen, out = set(), set()
    for p in off:
        if p in seen: continue
        comp, stack = [], [p]; seen.add(p)
        while stack:
            q = stack.pop(); comp.append(q)
            for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                r = (q[0] + dx, q[1] + dz)
                if r in off and r not in seen: seen.add(r); stack.append(r)
        if len(comp) < limit: out.update(comp)
    return out

def blocks(level):
    """World (x,z) -> class set, at one level or every level ('all')."""
    g, cls = S["g"], {}
    def add(x, z, c): cls.setdefault((x, z), set()).add(c)
    a = S["area"]
    infarm = lambda x, z: a["x1"] <= x <= a["x2"] and a["z1"] <= z <= a["z2"]
    for x1, y1, z1, x2, y2, z2 in S["dug"]:
        if level != "all" and not (min(y1, y2) <= level <= max(y1, y2)): continue
        for x in range(min(x1, x2), max(x1, x2) + 1):
            for z in range(min(z1, z2), max(z1, z2) + 1):
                if not infarm(x, z): add(x, z, "dug")
    if level == "all" or level == g["bottom"]:
        for k in range(1, g["spine"] + 1): add(g["x"] + g["dx"] * k, g["z"] + g["dz"] * k, "plan")
        for b in range(1, g["branches"] + 1):
            bx, bz = g["x"] + g["dx"] * b * g["gap"], g["z"] + g["dz"] * b * g["gap"]
            for k in range(1, g["length"] + 1): add(bx + g["rx"] * k, bz + g["rz"] * k, "plan")
    for who, x1, y1, z1, x2, y2, z2 in S["reserve"]:
        if level != "all" and not (min(y1, y2) <= level <= max(y1, y2)): continue
        for x in range(min(x1, x2), max(x1, x2) + 1):
            for z in range(min(z1, z2), max(z1, z2) + 1): add(x, z, "held")
    return cls

def bounds(level):
    g, a = S["g"], S["area"]
    xs = [g["x"], g["x"] + g["rx"] * g["length"]]
    zs = [g["z"], g["z"] + g["dz"] * g["spine"]]
    if level == "all" or abs(level - a["ground"]) <= 8:
        xs += [a["x1"], a["x2"]]; zs += [a["z1"], a["z2"]]
    for p in S["drops"] + [dict(x=S["server"][0], y=S["server"][1], z=S["server"][2])] + S["turtles"]:
        if near(p, level): xs.append(p["x"]); zs.append(p["z"])
    return min(xs), min(zs), max(xs), max(zs)

def near(p, level): return level == "all" or abs(p.get("y", level) - level) <= 1

def fit(mw, mh, level, valign="middle"):
    """Snap scales: x from SX, z to a divisor or multiple of the branch gap so every branch is one row."""
    x1, z1, x2, z2 = bounds(level)
    sx = next(s for s in SX if (x2 - x1) // s + 1 <= mw - 8)  # room for one inline label
    g = S["g"]; phase = (g["z"] + g["dz"] * g["gap"])
    for sz in [1, 2, 4, 8, 16]:
        top = z1 - (z1 - phase) % sz
        if (z2 - top) // sz + 1 <= mh: break
    rows = (z2 - top) // sz + 1
    v = view(mw, mh, level, sx, sz, (x1 + x2) // 2, 0)
    v["top"] = top - (0 if valign == "top" else (mh - rows) // 2) * sz
    cols = (x2 - x1) // sx + 1
    v["left"] = x1 - max(1, (mw - cols) // 2 - 3) * sx  # labels sit mostly east of things
    return v

def view(mw, mh, level, sx, sz, cx, cz, x1=None):
    g = S["g"]
    left = cx - (mw * sx) // 2
    top = cz - (mh * sz) // 2
    phase = (g["z"] + g["dz"] * g["gap"]) % sz  # a branch is the first block row of its cell
    top -= (top - phase) % sz
    return dict(mw=mw, mh=mh, level=level, sx=sx, sz=sz, left=left, top=top)

def cell(v, x, z):
    c, r = (x - v["left"]) // v["sx"], (z - v["top"]) // v["sz"]
    return (c, r) if 0 <= c < v["mw"] and 0 <= r < v["mh"] else None

def draw(cv, v, ox, oy, select=None, labels=True, drop_label="kind", select_drop=None):
    """Draw the map into canvas cv with its top-left cell at (ox, oy); select is a turtle id drawn inverted."""
    cls = blocks(v["level"])
    geo = geometry(); dots = small(cls, geo)
    cellset = {}
    for (x, z), c in cls.items():
        p = cell(v, x, z)
        if p: cellset.setdefault(p, []).append((x, z, c))
    line = lambda x, z: (x, z) in cls and (x, z) not in dots
    occ = {}
    for p, items in cellset.items():
        h = vv = 0; dug = held = False
        if all((x, z) in dots for x, z, c in items):
            cv.put(ox + p[0], oy + p[1], "·", "3"); occ[p] = "line"; continue
        for x, z, c in items:
            if (x, z) in dots: continue
            dug |= "dug" in c; held |= "held" in c
            for dx, dz in ((1, 0), (-1, 0)):
                if line(x + dx, z + dz): h += 1
            for dx, dz in ((0, 1), (0, -1)):
                if line(x + dx, z + dz): vv += 1
        if h and vv and h < 2 * vv and vv < 2 * h: ch = "+" if dug else "·"
        elif vv > h: ch = "|" if dug else "¦"
        elif h: ch = "-" if dug else "·"
        else: ch = "·"
        fg = "b" if held else "3" if dug else "8"
        cv.put(ox + p[0], oy + p[1], ch, fg)
        occ[p] = "line"
    # farm: hairline outline, trees inside
    a = S["area"]
    if v["level"] == "all" or abs(v["level"] - a["ground"]) <= 8:
        c1, c2 = cell(v, a["x1"], a["z1"]), cell(v, a["x2"], a["z2"])
        if c1 and c2:
            (x1, y1), (x2, y2) = c1, c2
            for x in range(x1, x2 + 1):
                for y in (y1, y2): cv.put(ox + x, oy + y, "-", "c"); occ[(x, y)] = "farm"
            for y in range(y1, y2 + 1):
                for x in (x1, x2): cv.put(ox + x, oy + y, "|", "c"); occ[(x, y)] = "farm"
            for x, y in ((x1, y1), (x2, y1), (x1, y2), (x2, y2)): cv.put(ox + x, oy + y, "+", "c")
            for x in range(x1 + 1, x2):
                for y in range(y1 + 1, y2): occ[(x, y)] = "farmin"
            ready = sum(1 for sp in S["spots"] if sp["ready"])
            for sp in S["spots"]:
                p = cell(v, sp["x"], sp["z"])
                if p: cv.put(ox + p[0], oy + p[1], "♠" if sp["ready"] else "♣", "d" if sp["ready"] else "8"); occ[p] = "tree"
            farm_label = ("farm %d/%d" % (ready, len(S["spots"])), (x1, y1))
        else: farm_label = None
    else: farm_label = None
    marks = []  # (cell, glyph, fg, label, lfg, prio, ref)
    g = S["g"]
    sp = cell(v, g["x"], g["z"])
    if sp: marks.append((sp, "º", "9", "shaft", "8", 1, "shaft"))
    for d in S["drops"]:
        if not near(d, v["level"]): continue
        p = cell(v, d["x"], d["z"])
        if p: marks.append((p, "×" if d["broken"] else "•", "e" if d["broken"] else "0",
                            str(d["id"]) if drop_label == "id" else d["kind"], "e" if d["broken"] else "8", 2, d))
    sv = S["server"]
    p = cell(v, sv[0], sv[2])
    if p and near(dict(y=sv[1]), v["level"]): marks.append((p, "@", "9", "server", "8", 2, "server"))
    for t in S["turtles"]:
        if not near(t, v["level"]): continue
        p = cell(v, t["x"], t["z"])
        lab = t["id"] + ("" if t["col"] == "d" or v["sx"] >= 3 else " " + t["state"].split()[0])
        if p: marks.append((p, ARROW[t["f"]], t["col"], lab, t["col"], 3, t))
    marks.sort(key=lambda m: -m[5])
    taken = {}
    for m in marks:
        if m[0] in taken: continue
        sel = isinstance(m[6], dict) and ((select and m[6].get("id") == select and "f" in m[6]) or
                                         (select_drop and m[6].get("id") == select_drop and "kind" in m[6]))
        cv.put(ox + m[0][0], oy + m[0][1], m[1], "f" if sel else m[2], m[2] if sel else None); taken[m[0]] = m
    placed = {}
    def place(text, at, fg, prefer):
        x, y = at
        n = len(text)
        cands = {"r": (x + 1, y), "l": (x - n, y), "ur": (x + 1, y - 1), "dr": (x + 1, y + 1),
                 "ul": (x - n, y - 1), "dl": (x - n, y + 1), "u": (x - n // 2, y - 1), "d": (x - n // 2, y + 1),
                 "in": (x + 1, y + 1)}
        best = None
        for i, k in enumerate(prefer):
            cx, cy = cands[k]
            if cx < 0 or cx + n > v["mw"] or cy < 0 or cy >= v["mh"]: continue
            cost, bad = i * 0.1, False
            for j in range(-1, n + 1):
                q = (cx + j, cy)
                if 0 <= j < n:
                    if q in taken or q in placed: bad = True; break
                    if q in occ: cost += 3 if occ[q] in ("line", "tree") else 1
                elif q in placed: bad = True; break
                elif q in taken and q != at: bad = True; break
            if not bad and (best is None or cost < best[0]): best = (cost, cx, cy)
        if best is None: return False
        _, cx, cy = best
        cv.put(ox + cx, oy + cy, text, fg)
        for j in range(n): placed[(cx + j, cy)] = text
        return True
    if labels:
        for m in marks:
            if taken.get(m[0]) is not m: continue
            ref = m[6]
            pref = ["r", "l", "ur", "dr", "ul", "dl", "u", "d"]
            if isinstance(ref, dict) and ref.get("f") == 1: pref = ["ur", "dr", "r", "ul", "dl", "l"]  # don't sit on the path ahead
            if isinstance(ref, dict) and ref.get("f") in (0, 2): pref = ["r", "l", "ur", "dr"]
            if v["sx"] >= 3 and isinstance(ref, dict) and "kind" in ref and not ref["broken"]: continue
            if v["sx"] >= 3 and ref == "shaft": continue
            if select and isinstance(ref, dict) and ref.get("id") == select: continue
            if isinstance(ref, dict) and "kind" in ref: pref = ["r", "l", "d", "dr", "dl", "u", "ur", "ul"]
            place(m[3], m[0], m[4], pref)
        if farm_label and v["sx"] < 3:
            place(farm_label[0], (farm_label[1][0] - 1, farm_label[1][1]), "8", ["u", "ur", "r"])
    # branch numbers west of the spine, or on the left edge when the spine is off screen
    if v["sz"] <= 2 and (v["level"] == "all" or v["level"] == g["bottom"]):
        for b in range(1, g["branches"] + 1):
            z = g["z"] + g["dz"] * b * g["gap"]
            r = (z - v["top"]) // v["sz"]
            c = (g["x"] - v["left"]) // v["sx"]
            if not 0 <= r < v["mh"]: continue
            text = "%d" % b
            if c < 0: cv.put(ox, oy + r, text, "8"); continue
            free = lambda q: q[0] < 0 or (q not in occ and q not in taken and q not in placed)
            x = c - len(text) - 1
            for _ in range(4):  # step past a label sitting against the spine
                if x < 0: break
                if all(free((x + j, r)) for j in range(-3, len(text) + 1)):
                    cv.put(ox + x, oy + r, text, "8"); break
                if not ((x + len(text), r) in placed or (x + len(text), r) in taken): break
                x -= 2
    return taken
