"""Route A map: the cell pass, markers, labels, branch numbers and callouts.

This is the twin of the drawing half of so-mod-map.lua; tests/so/map.lua compares the two cell by
cell through the fixtures. North is up at every size: x grows to the right and z downwards, and the
two axes only scale. The axis the branches step along snaps to the branch gap.
"""
from kit import age, box, leader
from scene import S

ARROW = {0: "▲", 1: "►", 2: "▼", 3: "◄"}
SX = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]  # cells along a free axis
SN = [1, 2, 4, 8, 16, 32, 64]  # cells along the branch axis: divisors and multiples of the gap
MARGIN = 7  # blocks read past the view, so a cut dig still counts its full size (up to 6)
PLAN, DUG, HELD = 1, 2, 4


def snapped(g):
    """'z' when the spine runs north-south (branches are rows), 'x' when east-west, else None."""
    if not g:
        return None
    return "z" if g["dz"] != 0 else "x"


def phase(g):
    return g["z"] + g["dz"] * g["gap"] if snapped(g) == "z" else g["x"] + g["dx"] * g["gap"]


def on_geo(g, x, z):
    ax, az = x - g["x"], z - g["z"]
    along, side = ax * g["dx"] + az * g["dz"], ax * g["rx"] + az * g["rz"]
    if side == 0 and 0 <= along <= g["spine"]:
        return True
    return g["gap"] <= along <= g["spine"] and along % g["gap"] == 0 and 1 <= side <= g["length"]


def farm_on(level):
    a = S.get("area")
    return a is not None and (level == "all" or a["ground"] <= level <= a["ground"] + 8)


def near(p, level):
    return level == "all" or abs(p.get("y", level) - level) <= 1


def area():
    a = S["area"]
    return min(a["x1"], a["x2"]), min(a["z1"], a["z2"]), max(a["x1"], a["x2"]), max(a["z1"], a["z2"])


def server():
    sv = S["server"]
    return dict(x=sv[0], y=sv[1], z=sv[2])


def bounds(level):
    g, pts = S["g"], []
    pts.append((g["x"], g["z"]))
    if g["branches"] > 0:
        for along, side in ((g["spine"], 0), (g["gap"], g["length"]), (g["spine"], g["length"])):
            pts.append((g["x"] + g["dx"] * along + g["rx"] * side, g["z"] + g["dz"] * along + g["rz"] * side))
    if farm_on(level):
        x1, z1, x2, z2 = area()
        pts += [(x1, z1), (x2, z2)]
    for p in S["drops"] + [server()] + S["turtles"]:
        if near(p, level):
            pts.append((p["x"], p["z"]))
    xs, zs = [p[0] for p in pts], [p[1] for p in pts]
    return min(xs), min(zs), max(xs), max(zs)


def span(lo, hi, room, ladder, ph=None):
    """The first scale on the ladder that fits hi-lo in room cells; the start snaps to ph."""
    for s in ladder:
        start = lo if ph is None else lo - (lo - ph) % s
        if (hi - start) // s + 1 <= room:
            return s, start, (hi - start) // s + 1
    return s, start, (hi - start) // s + 1


def fit(mw, mh, level, valign="middle"):
    """The whole scene: x leaves room for one label, the branch axis snaps to the gap."""
    x1, z1, x2, z2 = bounds(level)
    axis, ph = snapped(S["g"]), phase(S["g"])
    sx, left, cols = span(x1, x2, mw - 8, SN if axis == "x" else SX, ph if axis == "x" else None)
    sz, top, rows = span(z1, z2, mh, SN if axis == "z" else SX, ph if axis == "z" else None)
    v = dict(mw=mw, mh=mh, level=level, sx=sx, sz=sz)
    v["left"] = left - max(1, (mw - cols) // 2 - 3) * sx  # labels sit mostly east of things
    v["top"] = top - (0 if valign == "top" else max(0, (mh - rows) // 2)) * sz
    v["cx"], v["cz"] = v["left"] + (mw * sx) // 2, v["top"] + (mh * sz) // 2
    return v


def view(mw, mh, level, sx, sz, cx, cz):
    left, top = cx - (mw * sx) // 2, cz - (mh * sz) // 2
    axis = snapped(S["g"])
    if axis == "z":
        top -= (top - phase(S["g"])) % sz  # a branch is the first block row of its cell
    elif axis == "x":
        left -= (left - phase(S["g"])) % sx
    return dict(mw=mw, mh=mh, level=level, sx=sx, sz=sz, left=left, top=top, cx=cx, cz=cz)


def cell(v, x, z):
    c, r = (x - v["left"]) // v["sx"], (z - v["top"]) // v["sz"]
    return (c, r) if 0 <= c < v["mw"] and 0 <= r < v["mh"] else None


def blocks(v):
    """(x, z) -> PLAN|DUG|HELD bits, for the view and MARGIN blocks around it."""
    g, level, cls = S["g"], v["level"], {}
    x1, z1 = v["left"] - MARGIN, v["top"] - MARGIN
    x2, z2 = v["left"] + v["mw"] * v["sx"] - 1 + MARGIN, v["top"] + v["mh"] * v["sz"] - 1 + MARGIN

    def add(x, z, bit):
        if x1 <= x <= x2 and z1 <= z <= z2:
            cls[(x, z)] = cls.get((x, z), 0) | bit
    farm = farm_on(level)
    if farm:
        fx1, fz1, fx2, fz2 = area()
    for bx1, by1, bz1, bx2, by2, bz2 in S["dug"]:
        for y in range(min(by1, by2), max(by1, by2) + 1):
            if level != "all" and y != level:
                continue
            for x in range(min(bx1, bx2), max(bx1, bx2) + 1):
                for z in range(min(bz1, bz2), max(bz1, bz2) + 1):
                    # Farm travel marks are not tunnels; the farm draws as a farm.
                    if not (farm and fx1 <= x <= fx2 and fz1 <= z <= fz2):
                        add(x, z, DUG)
    if level == "all" or level == g["bottom"]:
        def line(bx, bz, ux, uz, n):
            # Cells four or more blocks long along the line keep its first two blocks per cell.
            size, base, o = (v["sx"], bx, v["left"]) if ux else (v["sz"], bz, v["top"])
            for k in range(1, n + 1):
                if size < 4 or (base + (ux + uz) * k - o) % size < 2:
                    add(bx + ux * k, bz + uz * k, PLAN)
        line(g["x"], g["z"], g["dx"], g["dz"], g["spine"])
        axis = snapped(g)
        snap, origin = (v["sz"], v["top"]) if axis == "z" else (v["sx"], v["left"])
        for b in range(1, g["branches"] + 1):
            bx, bz = g["x"] + g["dx"] * b * g["gap"], g["z"] + g["dz"] * b * g["gap"]
            # A branch sharing a cell row (or column) with an earlier one adds nothing new.
            if ((bz if axis == "z" else bx) - origin) % snap == 0:
                line(bx + 0, bz + 0, g["rx"], g["rz"], g["length"])
    for _, rx1, ry1, rz1, rx2, ry2, rz2 in S["reserve"]:
        for y in range(min(ry1, ry2), max(ry1, ry2) + 1):
            if level != "all" and y != level:
                continue
            for x in range(min(rx1, rx2), max(rx1, rx2) + 1):
                for z in range(min(rz1, rz2), max(rz1, rz2) + 1):
                    add(x, z, HELD)
    return cls


def small(cls, g):
    """Blocks off the mine geometry in pieces of 6 or fewer: ore digs, drawn as one dot."""
    off = {p for p in cls if not on_geo(g, p[0], p[1])}
    seen, out = set(), set()
    for p in off:
        if p in seen:
            continue
        comp, stack = [], [p]
        seen.add(p)
        while stack:
            q = stack.pop()
            comp.append(q)
            for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                r = (q[0] + dx, q[1] + dz)
                if r in off and r not in seen:
                    seen.add(r)
                    stack.append(r)
        if len(comp) < 7:
            out.update(comp)
    return out


def cells(v):
    """The line glyph of every map cell: {(c, r): (glyph, fg)}."""
    cls = blocks(v)
    dots = small(cls, S["g"])
    agg = {}
    for (x, z), bits in cls.items():
        p = cell(v, x, z)
        if not p:
            continue
        a = agg.setdefault(p, [True, 0, 0, False, False])
        if (x, z) in dots:
            continue
        a[0] = False
        a[3] = a[3] or bits & DUG != 0
        a[4] = a[4] or bits & HELD != 0
        for dx in (1, -1):
            q = (x + dx, z)
            if q in cls and q not in dots:
                a[1] += 1
        for dz in (1, -1):
            q = (x, z + dz)
            if q in cls and q not in dots:
                a[2] += 1
    out = {}
    for p, (dot, h, vv, dug, held) in agg.items():
        if dot:
            out[p] = ("·", "3")
            continue
        if h and vv and h < 2 * vv and vv < 2 * h:
            ch = "+" if dug else "·"
        elif vv > h:
            ch = "|" if dug else "¦"
        elif h:
            ch = "-" if dug else "·"
        else:
            ch = "·"
        out[p] = (ch, "b" if held else "3" if dug else "8")
    return out


def label_of(t, sx):
    return t["id"] if t["col"] == "d" or sx >= 3 else t["id"] + " " + t["state"].split()[0]


def markers(v, drop_label="kind"):
    """Turtles, then drops and the server, then the shaft: (cell, glyph, fg, label, lfg, kind, ref)."""
    level, out = v["level"], []
    for t in S["turtles"]:
        p = cell(v, t["x"], t["z"])
        if p and near(t, level):
            out.append((p, ARROW.get(t["f"], "•"), t["col"], label_of(t, v["sx"]), t["col"], "turtle", t))
    for d in S["drops"]:
        p = cell(v, d["x"], d["z"])
        if p and near(d, level):
            out.append((p, "×" if d["broken"] else "•", "e" if d["broken"] else "0",
                        str(d["id"]) if drop_label == "id" else d["kind"], "e" if d["broken"] else "8", "drop", d))
    sv = server()
    p = cell(v, sv["x"], sv["z"])
    if p and near(sv, level):
        out.append((p, "@", "9", "server", "8", "server", sv))
    g = S["g"]
    p = cell(v, g["x"], g["z"])
    if p:
        out.append((p, "º", "9", "shaft", "8", "shaft", g))
    return out


def did(d):
    """A drop's map id: its drop-point id, or saplings for the lumber chest."""
    return "saplings" if d["kind"] == "saplings" else str(d["id"])


def is_pick(m, pick):
    if not pick or pick[0] != m[5]:
        return False
    if m[5] == "turtle":
        return m[6]["id"] == str(pick[1])
    return m[5] != "drop" or did(m[6]) == str(pick[1])


PREFER = ["r", "l", "ur", "dr", "ul", "dl", "u", "d"]


def draw(cv, v, ox, oy, select=None, labels=True, drop_label="kind", select_drop=None, pick=None):
    """Draw the map with its top-left cell at canvas (ox, oy). pick is ('turtle', id), ('drop', id),
    ('server',), ('shaft',) or ('cell', x, z); select and select_drop are the older short forms.
    Returns the marker cells and the occupied cells."""
    if pick is None and select is not None:
        pick = ("turtle", select)
    if pick is None and select_drop is not None:
        pick = ("drop", select_drop)
    occ = {}
    for p, (ch, fg) in cells(v).items():
        cv.put(ox + p[0], oy + p[1], ch, fg)
        occ[p] = "line"
    farm_label = None
    if farm_on(v["level"]):
        fx1, fz1, fx2, fz2 = area()
        c1 = ((fx1 - v["left"]) // v["sx"], (fz1 - v["top"]) // v["sz"])
        c2 = ((fx2 - v["left"]) // v["sx"], (fz2 - v["top"]) // v["sz"])

        def edge(x, y, ch):
            if 0 <= x < v["mw"] and 0 <= y < v["mh"]:
                cv.put(ox + x, oy + y, ch, "c")
                occ[(x, y)] = "farm"
        for x in range(c1[0], c2[0] + 1):
            for y in range(c1[1], c2[1] + 1):
                if x in (c1[0], c2[0]) or y in (c1[1], c2[1]):
                    edge(x, y, "+" if x in (c1[0], c2[0]) and y in (c1[1], c2[1]) else "-" if y in (c1[1], c2[1]) else "|")
                elif 0 <= x < v["mw"] and 0 <= y < v["mh"]:
                    occ[(x, y)] = "farmin"
        ready = 0
        for sp in S["spots"]:
            ready += 1 if sp["ready"] else 0
            p = cell(v, sp["x"], sp["z"])
            if p:
                cv.put(ox + p[0], oy + p[1], "♠" if sp["ready"] else "♣", "d" if sp["ready"] else "8")
                occ[p] = "tree"
        if cell(v, fx1, fz1):
            farm_label = ("farm %d/%d" % (ready, len(S["spots"])), (c1[0] - 1, c1[1]))
    marks = markers(v, drop_label)
    taken = {}
    for m in marks:
        if m[0] in taken:
            continue
        sel = is_pick(m, pick)
        cv.put(ox + m[0][0], oy + m[0][1], m[1], "f" if sel else m[2], m[2] if sel else None)
        taken[m[0]] = m
    placed = {}

    def place(text, at, fg, prefer):
        x, y = at
        n = len(text)
        cands = {"r": (x + 1, y), "l": (x - n, y), "ur": (x + 1, y - 1), "dr": (x + 1, y + 1),
                 "ul": (x - n, y - 1), "dl": (x - n, y + 1), "u": (x - n // 2, y - 1), "d": (x - n // 2, y + 1)}
        best = None
        for i, k in enumerate(prefer):
            cx, cy = cands[k]
            if cx < 0 or cx + n > v["mw"] or cy < 0 or cy >= v["mh"]:
                continue
            cost, bad = i, False
            for j in range(-1, n + 1):
                q = (cx + j, cy)
                if 0 <= j < n:
                    if q in taken or q in placed:
                        bad = True
                        break
                    if q in occ:
                        cost += 30 if occ[q] in ("line", "tree") else 10
                elif q in placed or (q in taken and q != at):
                    bad = True
                    break
            if not bad and (best is None or cost < best[0]):
                best = (cost, cx, cy)
        if best is None:
            return False
        _, cx, cy = best
        cv.put(ox + cx, oy + cy, text, fg)
        for j in range(n):
            placed[(cx + j, cy)] = text
        return True
    if labels:
        for m in marks:
            if taken.get(m[0]) is not m or is_pick(m, pick):
                continue
            kind, ref, pref = m[5], m[6], PREFER
            if kind == "turtle" and ref["f"] == 1:
                pref = ["ur", "dr", "r", "ul", "dl", "l"]  # not on the path ahead
            elif kind == "turtle" and ref["f"] in (0, 2):
                pref = ["r", "l", "ur", "dr"]
            elif kind == "drop":
                if v["sx"] >= 3 and not ref["broken"]:
                    continue
                pref = ["r", "l", "d", "dr", "dl", "u", "ur", "ul"]
            elif kind == "shaft" and v["sx"] >= 3:
                continue
            place(m[3], m[0], m[4], pref)
        if farm_label and v["sx"] < 3:
            place(farm_label[0], farm_label[1], "8", ["u", "ur", "r"])
    numbers(cv, v, ox, oy, occ, taken, placed)
    return taken, occ


def numbers(cv, v, ox, oy, occ, taken, placed):
    """Branch numbers on the side of the spine away from the branches, or on the screen edge."""
    g = S["g"]
    axis = snapped(g)
    if not axis or not (v["level"] == "all" or v["level"] == g["bottom"]):
        return
    if (v["sz"] if axis == "z" else v["sx"]) > 2:
        return

    def free(q):
        return q not in occ and q not in taken and q not in placed
    sc = ((g["x"] - v["left"]) // v["sx"], (g["z"] - v["top"]) // v["sz"])
    for b in range(1, g["branches"] + 1):
        text = str(b)
        n = len(text)
        if axis == "z":
            r = (g["z"] + g["dz"] * b * g["gap"] - v["top"]) // v["sz"]
            if not 0 <= r < v["mh"]:
                continue
            c, step = sc[0], -1 if g["rx"] > 0 else 1
            if (c < 0 and step < 0) or (c >= v["mw"] and step > 0):
                x = 0 if step < 0 else v["mw"] - n
                if all((x + j, r) not in taken and (x + j, r) not in placed for j in range(n)):
                    cv.put(ox + x, oy + r, text, "8")
                continue
            x = c - n - 1 if step < 0 else c + 2
            for _ in range(4):  # step past a label sitting against the spine
                if x < 0 or x + n > v["mw"]:
                    break
                lo, hi = (-3, n) if step < 0 else (-1, n + 2)
                if all(q[0] < 0 or q[0] >= v["mw"] or free(q) for q in ((x + j, r) for j in range(lo, hi + 1))):
                    cv.put(ox + x, oy + r, text, "8")
                    break
                gap = (x + n, r) if step < 0 else (x - 1, r)
                if not (gap in placed or gap in taken):
                    break
                x += 2 * step
        else:
            c = (g["x"] + g["dx"] * b * g["gap"] - v["left"]) // v["sx"]
            if not 0 <= c <= v["mw"] - n:
                continue
            r = sc[1] - 1 if g["rz"] > 0 else sc[1] + 1
            if r < 0 or r >= v["mh"]:
                r = 0 if g["rz"] > 0 else v["mh"] - 1
            if all(q[0] < 0 or q[0] >= v["mw"] or free(q) for q in ((c + j, r) for j in range(-1, n + 1))):
                cv.put(ox + c, oy + r, text, "8")
                for j in range(n):
                    placed[(c + j, r)] = text


# ---------------------------------------------------------------- callouts

def callout_lines(pick, v):
    """(box colour, rows) for the picked thing; a row is ('text', [(dx, text, fg)]) or ('leader', label, value, fg)."""
    k = pick[0]
    if k == "turtle":
        t = next((t for t in S["turtles"] if t["id"] == str(pick[1])), None)
        if not t:
            return None
        st = t["col"] if t["col"] != "d" else "0"
        when = age(t["ago"], True)
        return t["col"], (t["x"], t["z"]), [
            ("text", [(0, "#" + t["id"], "0"), (len(t["id"]) + 2, t["state"], st), (-len(when), when, "8")]),
            ("text", [(0, "%d,%d,%d" % (t["x"], t["y"], t["z"]), "8")]),
            ("leader", "fuel", str(t["fuel"]), "1" if isinstance(t["fuel"], int) and t["fuel"] < 500 else "0"),
            ("leader", "ore", str(t["ore"]), "0"),
            ("leader", "lease", t["lease"], "e" if t["lease"] == "expired" else "0" if t["lease"] == "open" else "8")]
    if k == "drop":
        d = next((d for d in S["drops"] if did(d) == str(pick[1])), None)
        if not d:
            return None
        title = "saplings" if did(d) == "saplings" else "drop %d %s" % (d["id"], d["kind"])
        return "e" if d["broken"] else "3", (d["x"], d["z"]), [
            ("text", [(0, title, "0")]),
            ("text", [(0, "%d,%d,%d" % (d["x"], d["y"], d["z"]), "8")]),
            ("leader", "state", "broken" if d["broken"] else "ok", "e" if d["broken"] else "0")]
    if k == "server":
        sv = server()
        return "9", (sv["x"], sv["z"]), [("text", [(0, "server", "0")]),
                                       ("text", [(0, "%d,%d,%d" % (sv["x"], sv["y"], sv["z"]), "8")])]
    if k == "shaft":
        g = S["g"]
        holder, low = "-", None  # the holder of the lowest held shaft cell
        for who, x1, y1, z1, x2, y2, z2 in S["reserve"]:
            if min(x1, x2) <= g["x"] <= max(x1, x2) and min(z1, z2) <= g["z"] <= max(z1, z2):
                if low is None or min(y1, y2) < low:
                    holder, low = "#" + who.split(":")[-1], min(y1, y2)
        return "9", (g["x"], g["z"]), [("text", [(0, "shaft", "0")]),
                                       ("text", [(0, "%d,%d" % (g["x"], g["z"]), "8")]),
                                       ("leader", "lane", holder, "b" if holder != "-" else "8")]
    x, z = pick[1], pick[2]
    p = cell(v, x, z)
    cls, word, who = blocks(v), "", None
    bits = 0
    for (bx, bz), b in cls.items():
        if cell(v, bx, bz) == p:
            bits |= b
    word = "held" if bits & HELD else "dug" if bits & DUG else "planned" if bits & PLAN else ""
    if bits & HELD:
        for name, x1, y1, z1, x2, y2, z2 in S["reserve"]:
            if v["level"] != "all" and not min(y1, y2) <= v["level"] <= max(y1, y2):
                continue
            for bx in range(min(x1, x2), max(x1, x2) + 1):
                for bz in range(min(z1, z2), max(z1, z2) + 1):
                    if who is None and cell(v, bx, bz) == p:
                        who = "#" + name.split(":")[-1]
    at = "%d,%d" % (x, z) if v["level"] == "all" else "%d,%d,%d" % (x, v["level"], z)
    rows = [("text", [(0, at, "0")])]
    if word:
        rows.append(("text", [(0, word, "b" if word == "held" else "0")] + ([(len(word) + 1, who, "0")] if who else [])))
    return "3", (x, z), rows


def callout(cv, v, ox, oy, pick, taken=None):
    """A hairline box beside the picked marker, joined to it. Returns the box (x, y, w, h) in map cells."""
    got = callout_lines(pick, v)
    if not got:
        return None
    colour, (x, z), rows = got
    p = cell(v, x, z)
    if not p:
        return None
    tx, ty = p
    if pick[0] == "cell":
        ch = cv.cells[oy + ty - 1][ox + tx - 1]
        cv.cells[oy + ty - 1][ox + tx - 1] = [ch[0], "f", "3"]
    widest = 0
    for row in rows:
        if row[0] == "leader":
            widest = max(widest, len(row[1]) + len(row[2]) + 4)
        else:
            left = max([dx + len(t) for dx, t, _ in row[1] if dx >= 0] or [0])
            right = sum(len(t) + 1 for dx, t, _ in row[1] if dx < 0)
            widest = max(widest, left + right)
    bw, bh = min(v["mw"], max(14, widest + 4)), len(rows) + 2
    near, far = (tx - bw + 1, tx) if tx * 2 >= v["mw"] else (tx, tx - bw + 1)
    # Below, then above, each toward the middle first; the one hiding the fewest markers wins.
    best = None
    for fits, by, link, joint in ((ty + 2 + bh <= v["mh"], ty + 2, ty + 1, ty + 2),
                                  (ty - 1 - bh >= 0, ty - 1 - bh, ty - 1, ty - 2)):
        if not fits:
            continue
        for x0 in (near, far):
            bx = max(0, min(x0, v["mw"] - bw))
            hidden = sum(1 for (mx, my) in (taken or {}) if bx <= mx < bx + bw and by <= my < by + bh)
            if best is None or hidden < best[0]:
                best = (hidden, bx, by, link, joint)
    if best:
        _, bx, by, link, joint = best
    else:
        bx = max(0, min(near, v["mw"] - bw))
        by, link, joint = max(0, min(ty + 2, v["mh"] - bh)), None, None
    cv.fill(ox + bx, oy + by, bw, bh, "f")
    box(cv, ox + bx, oy + by, bw, bh, colour)
    if link is not None:
        cv.put(ox + tx, oy + link, "|", colour)
        cv.put(ox + tx, oy + joint, "+", colour)
    iw = bw - 4
    for i, row in enumerate(rows):
        y = oy + by + 1 + i
        if row[0] == "leader":
            leader(cv, ox + bx + 2, y, iw, row[1], row[2], row[3])
        else:
            for dx, text, fg in row[1]:
                at = dx if dx >= 0 else iw + dx
                text = text[:max(0, iw - at)]
                cv.put(ox + bx + 2 + at, y, text, fg)
    return bx, by, bw, bh


def thumb(cv, x, y, w, h):
    """The status wall thumbnail: the compass on the first row, the whole scene north up under it."""
    compass(cv, x + w - 2, y)
    draw(cv, fit(w, h - 1, "all", "top"), x, y + 1)


def compass(cv, x, y):
    cv.put(x, y, "↑N", "8")


def crop(cv, x, y, w, h, focus):
    """The alert crop: one block per cell around focus, at the mine level when focus is at or under it."""
    g = S["g"]
    level = g["bottom"] if g and focus.get("y") is not None and focus["y"] <= g["bottom"] else "all"
    pick = ("turtle", focus["id"]) if focus.get("id") is not None else \
        ("drop", focus["drop"]) if focus.get("drop") is not None else None
    draw(cv, view(w, h, level, 1, 1, focus["x"], focus["z"]), x, y, pick=pick)
    return True
