"""Route A twin of the AR goggles screen (A.layout in so-mod-ar.lua).

tests/ui/ra3-ar.lua draws the same models with the real module and compares every fixture cell by
cell. The model is the controller count and the four layer switches.
"""
from cc import Canvas
from kit import bar, leader, section

ORDER = ("turtles", "leases", "drops", "alerts")


def layout(count, layers, w, h, title=""):
    """The header with the controller count, LAYERS, then one leader row per layer with [on] in green
    or [off] muted. The whole row is the layer's toggle."""
    cv = Canvas(w, h, title)
    right = "%d controller%s" % (count, "" if count == 1 else "s")
    if len(right) + 14 > w:
        right = str(count)
    bar(cv, "AR GOGGLES", right=right)
    on = sum(1 for layer in ORDER if layers[layer])
    lw, step, y = min(w - 2, 55), 2 if h >= 16 else 1, 2
    if h >= 7:
        section(cv, 2, 3, lw, "LAYERS", "%d on" % on)
        y = 3 + step
    for i, layer in enumerate(ORDER):
        ry, state = y + i * step, layers[layer]
        word = "on" if state else "off"
        leader(cv, 2, ry, lw, layer, "[%s]" % word, "8")
        cv.put(lw - len(word) + 1, ry, word, "d" if state else "8")
        cv.hit(layer, 1, ry, w, 1, layer)
    return cv


def _ar(w, h, title, count, off=()):
    return lambda: layout(count, {layer: layer not in off for layer in ORDER}, w, h, title)


# Every size the ar role draws; tests/ui/ra3-ar.lua keeps the same models.
FIXTURES = [
    ("ar-M", _ar(57, 24, "AR layers, room monitor 57x24, drops off", 1, ("drops",))),
    ("ar-W", _ar(100, 38, "AR layers, wall 100x38, two controllers", 2)),
    ("ar-L", _ar(39, 19, "AR layers, wall monitor 39x19, drops off", 1, ("drops",))),
    ("ar-P", _ar(26, 20, "AR layers on a pocket 26x20", 1)),
    ("ar-S", _ar(29, 12, "AR layers at 29x12, no controller, leases and alerts off", 0, ("leases", "alerts"))),
    ("ar-XS", _ar(15, 10, "AR layers, smallest monitor 15x10, turtles off", 1, ("turtles",))),
]
