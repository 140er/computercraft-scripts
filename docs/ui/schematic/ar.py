"""Route A twin of the AR goggles screen (A.layout in so-mod-ar.lua).

tests/ui/ra3-ar.lua draws the same models with the real module and compares every fixture cell by
cell. The model is the controller count, the four layer switches and the goggles' alert.
tests/ui/ar.lua does the same for the arFollowups models: the focus row, the dimension words and
the FOCUS list.
"""
from cc import Canvas
from kit import bar, leader, section

ORDER = ("turtles", "leases", "drops", "alerts")


def _bar(cv, count, w):
    right = "%d controller%s" % (count, "" if count == 1 else "s")
    if len(right) + 14 > w:
        right = str(count)
    bar(cv, "AR GOGGLES", right=right)


def layout(count, layers, w, h, title="", alert=None, follow=None):
    """The header with the controller count, LAYERS, then one leader row per layer with [on] in green
    or [off] muted. The whole row is the layer's toggle. The goggles' alert follows where it fits,
    and a tap on it steps to the next alert."""
    cv = Canvas(w, h, title)
    _bar(cv, count, w)
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
    ay = y + len(ORDER) * step
    if follow and ay <= h:
        # follow is (focus word, missing, active dimension or None).
        focus, missing, dims = follow
        leader(cv, 2, ay, lw, "focus", "[%s]" % focus, "8")
        cv.put(lw - len(focus) + 1, ay, focus, "e" if missing else "0")
        cv.hit("ar-focus", 1, ay, w, 1, "focus")
        ay += step
        if dims and ay <= h:
            x = 2
            words = ("WORLD", "NETHER", "END") if w >= 20 else ("OVER", "NETH", "END")
            for key, word in zip(("world", "nether", "end"), words):
                cv.put(x, ay, word, "d" if key == dims else "8")
                cv.hit("ar-dim:" + key, x, ay, len(word), 1, word)
                x += len(word) + (2 if w >= 20 else 1)
            ay += step
    if alert and ay + 1 <= h:
        text, i, n = alert
        section(cv, 2, ay, lw, "ALERTS", "%d/%d" % (i, n))
        cv.put(2, ay + 1, "!", "e")
        cv.put(4, ay + 1, text[:max(0, lw - 2)], "0")
        cv.hit("alert:next", 1, ay, w, 2, "next alert")
    return cv


def picker(count, items, page, w, h, title=""):
    """FOCUS: ALL and the targets one per row, the current one green, then BACK, and MORE when
    there are more pages. items are (id, text, on)."""
    cv = Canvas(w, h, title)
    _bar(cv, count, w)
    lw, step, y = min(w - 2, 55), 2 if h >= 16 else 1, 2
    if h >= 7:
        y = 3 + step
    per = max(1, (h - step - y) // step + 1)
    pages = max(1, -(-len(items) // per))
    page = (page - 1) % pages + 1
    if h >= 7:
        section(cv, 2, 3, lw, "FOCUS", "%d/%d" % (page, pages) if pages > 1 else "")
    for i, (bid, text, on) in enumerate(items[(page - 1) * per:page * per]):
        ry = y + i * step
        cv.put(2, ry, text[:lw], "d" if on else "0")
        cv.hit(bid, 1, ry, w, 1, text)
    cv.put(2, h, "BACK", "0")
    cv.hit("ar-back", 1, h, 6, 1, "BACK")
    if pages > 1:
        cv.put(w - 4, h, "MORE", "0")
        cv.hit("ar-more", w - 5, h, 6, 1, "MORE")
    return cv


def _ar(w, h, title, count, off=(), alert=None):
    return lambda: layout(count, {layer: layer not in off for layer in ORDER}, w, h, title, alert)


# Every size the ar role draws; tests/ui/ra3-ar.lua keeps the same models.
FIXTURES = [
    ("ar-M", _ar(57, 24, "AR layers, room monitor 57x24, drops off", 1, ("drops",))),
    ("ar-W", _ar(100, 38, "AR layers, wall 100x38, two controllers", 2)),
    ("ar-L", _ar(39, 19, "AR layers, wall monitor 39x19, drops off", 1, ("drops",))),
    ("ar-P", _ar(26, 20, "AR layers on a pocket 26x20", 1)),
    ("ar-S", _ar(29, 12, "AR layers at 29x12, no controller, leases and alerts off", 0, ("leases", "alerts"))),
    ("ar-XS", _ar(15, 10, "AR layers, smallest monitor 15x10, turtles off", 1, ("turtles",))),
    ("ar-A", _ar(57, 24, "AR layers with the second of three alerts", 1, (), ("ore chest full at -120,64,35", 2, 3))),
    ("ar-AS", _ar(29, 12, "AR layers at 29x12 with one long alert", 1, (), ("no fuel chest set for turtle 12", 1, 1))),
]

ALL = lambda on: ("ar-all", "ALL", on)  # noqa: E731
TARGETS = [ALL(False)] + [("ar-turtle:%d" % n, "turtle #%d" % n, n == 12) for n in (3, 7, 12, 40)] + [
    ("ar-drop:p%d" % n, "drop #%d" % n, False) for n in range(1, 9)]


def _follow(w, h, title, follow, off=(), alert=None):
    return lambda: layout(1, {layer: layer not in off for layer in ORDER}, w, h, title, alert, follow)


def _pick(w, h, title, items, page=1):
    return lambda: picker(1, items, page, w, h, title)


# arFollowups models; tests/ui/ar.lua keeps the same ones.
FIXTURES += [
    ("ar-FM", _follow(57, 24, "AR with focus on turtle #12 in the Nether", ("#12", False, "nether"), (),
                      ("ore chest full at -120,64,35", 1, 2))),
    ("ar-FS", _follow(29, 12, "AR at 29x12 with a removed focus target, remote dimensions off",
                      ("missing", True, None))),
    ("ar-FXS", _follow(15, 10, "AR on the smallest monitor with focus on drop #3", ("drop #3", False, "world"))),
    ("ar-PM", _pick(57, 24, "FOCUS list with turtle #12 chosen", TARGETS)),
    ("ar-PXS", _pick(15, 10, "FOCUS list on the smallest monitor, second page", TARGETS, 2)),
    ("ar-PS", _pick(29, 12, "FOCUS list at 29x12 with only ALL", [ALL(True)])),
]
