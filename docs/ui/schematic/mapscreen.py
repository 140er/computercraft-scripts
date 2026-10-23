"""The map screen at every size: controls, the compass, the map, the callout and the wall roster.

The twin of M.layout and M.render in so-mod-map.lua. Sizes: wall (80x30 and up) adds a roster strip
under the map; room (52 wide and up) keeps every control in the top row; pocket (25 to 51 wide) moves
pan and zoom to the bottom row; tiny puts them on the last two rows. The compass sits at the right
end of the top row on every size, outside the map, so markers and labels never reach it.
"""
from cc import Canvas
from kit import arrow, chip, section
import mapdraw as MD
from scene import S


def layout(w, h, n):
    kind = "wall" if w >= 80 and h >= 30 else "room" if w >= 52 else "pocket" if w >= 25 else "tiny"
    L = dict(kind=kind, mx=1, my=2, mw=w)
    if kind == "room":
        L["mh"] = h - 1
    elif kind == "pocket":
        L["mh"] = h - 2
    elif kind == "tiny":
        L["mh"] = h - 3
    else:
        cols = (w - 32) // 33 + 1
        lines = min(4, (n + cols - 1) // cols)
        rows = 2 * lines
        L["my"] = 3
        L["mh"] = h - 2 - (rows + 1 if rows else 0)
        L["roster"] = dict(y=h - rows + 1, cols=cols, lines=lines) if rows else None
    L["mh"] = max(1, L["mh"])
    return L


def level_label(level):
    return "ALL" if level == "all" else "Y%d" % level


def controls(cv, L, w, h, level, fit):
    kind = L["kind"]
    if kind in ("room", "wall", "pocket"):
        cv.put(2, 1, "MAP", "0")
        x = chip(cv, 6, 1, "FIT", "map-fit", "on" if fit else "plain") + 1
        if kind != "pocket":
            x = chip(cv, x, 1, "-", "map-out") + 1
            x = chip(cv, x, 1, "+", "map-in") + 2
            for a, i in (("◄", "w"), ("▲", "n"), ("▼", "s"), ("►", "e")):
                x = chip(cv, x, 1, a, "map-" + i) + 1
        else:
            x0 = 1 + (w - 24) // 2
            for i, (a, d) in enumerate((("◄", "w"), ("▲", "n"), ("▼", "s"), ("►", "e"))):
                chip(cv, x0 + 4 * i, h, a, "map-" + d)
            chip(cv, x0 + 17, h, "-", "map-out")
            chip(cv, x0 + 21, h, "+", "map-in")
    else:
        x0 = 1 + (w - 15) // 2
        for i, (a, d) in enumerate((("◄", "w"), ("▲", "n"), ("▼", "s"), ("►", "e"))):
            chip(cv, x0 + 4 * i, h - 1, a, "map-" + d)
        x0 = 1 + (w - 13) // 2
        chip(cv, x0, h, "-", "map-out")
        chip(cv, x0 + 4, h, "FIT", "map-fit", "on" if fit else "plain")
        chip(cv, x0 + 10, h, "+", "map-in")
    x = w - 14
    chip(cv, x, 1, "▼", "map-down")
    text = level_label(level)
    cv.put(x + 3 + (5 - len(text)) // 2, 1, text, "0")
    cv.hit("map-level", x + 3, 1, 5, 1, text)
    chip(cv, x + 8, 1, "▲", "map-up")
    MD.compass(cv, w - 2, 1)


def roster(cv, L, w):
    R, ts = L["roster"], S["turtles"]
    section(cv, 2, R["y"], w - 2, "TURTLES", len(ts))
    room = R["cols"] * R["lines"]
    shown = len(ts) if len(ts) <= room else room - 1
    for i in range(min(len(ts), room)):
        x, y = 2 + (i % R["cols"]) * 33, R["y"] + 1 + (i // R["cols"]) * 2
        if i >= shown:
            cv.put(x, y, "+%d more" % (len(ts) - shown), "8")
            break
        t = ts[i]
        cv.put(x, y, arrow(t["f"]), t["col"])
        cv.put(x + 2, y, t["id"], "0")
        cv.put(x + 5, y, t["state"][:10], t["col"] if t["col"] in ("1", "e", "8") else "0")
        cv.put(x + 16, y, "%d,%d,%d" % (t["x"], t["y"], t["z"]), "8")


def screen(w, h, title, level="all", scale=None, centre=None, pick=None):
    """scale (sx, sz) and centre (cx, cz) give a panned or zoomed view; without them the view fits."""
    cv = Canvas(w, h, title)
    L = layout(w, h, len(S["turtles"]))
    if scale:
        v = MD.view(L["mw"], L["mh"], level, scale[0], scale[1], centre[0], centre[1])
    else:
        v = MD.fit(L["mw"], L["mh"], level)
    taken, _ = MD.draw(cv, v, L["mx"], L["my"], pick=pick)
    if pick:
        MD.callout(cv, v, L["mx"], L["my"], pick, taken)
    controls(cv, L, w, h, level, not scale)
    if L.get("roster"):
        roster(cv, L, w)
    cv.hit("map-pick", L["mx"], L["my"], L["mw"], L["mh"])
    return cv


TITLES = {
    "map-57x24": "Map, room monitor 57x24",
    "map-100x38": "Map, wall 100x38",
    "map-26x20": "Map, pocket 26x20",
    "map-sel-57x24": "Map, room monitor, Y-58 at 1x1, lost #6 tapped",
    "map-39x19": "Map, 39x19, broken drop 3 tapped",
    "map-29x12": "Map, 29x12 at Y-58 and 2x2, a vein tapped",
    "map-15x10": "Map, smallest monitor 15x10",
    "schematic-map-XL": "Map, largest wall 164x81",
}


def make(v):
    return lambda: screen(v["w"], v["h"], TITLES[v["name"]], v["level"], v["scale"], v["centre"], v["pick"])


# One fixture per view line in tests/ui/map-scene.txt; tests/so/map.lua renders the same views.
FIXTURES = [(v["name"], make(v)) for v in S["views"]]
