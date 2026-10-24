"""Route A kit, call for call the same as the schematic part of so-ui.lua (docs/ui/SCHEMATIC-SPEC.md).

Every function takes the canvas first; the Lua kit has the same names as canvas methods
(C.bar, C.section, ...). Change both together: the fixtures compare them cell by cell.
"""
import re

ARROW = {0: "▲", 1: "►", 2: "▼", 3: "◄"}
CHIP = {"plain": ("0", "7"), "primary": ("9", "7"), "stop": ("e", "7"), "muted": ("8", "7"),
        "on": ("f", "9"), "off": ("8", "f")}
TONES = [("e", ["lost", "broken", "block", "error", "fail", "missing", "expire", "refuse"]),
         ("1", ["wait", "hold", "range", "recover", "stale", "low", "full"]),
         ("8", ["idle", "stop", "done", "off"])]


def tone(word):
    """State colour of a state word: d working, 1 waiting, e lost or broken, 8 idle."""
    word = (word or "").lower()
    if word in ("", "-"):
        return "8"
    for colour, stems in TONES:
        for stem in stems:
            if re.search(r"(?<![a-z])" + stem, word):
                return colour
    return "d"


def mark(line):
    """Colour of a log line's mark: only problems and waits get a colour."""
    t = tone(line)
    return t if t in ("e", "1") else "8"


def age(ms, long=False):
    if ms < 60000:
        return "now"
    if ms < 3600000:
        return "%d%s" % (ms // 60000, " min" if long else "m")
    return "%d%s" % (ms // 3600000, " h" if long else "h")


def arrow(facing):
    return ARROW.get(facing, "•")


def bar(cv, name, tabs=(), active=None, right="", rfg="8", y=1):
    """Header row: role name, tabs, a dim hairline, then the state word or time at the right."""
    cv.put(2, y, name, "0")
    x = 2 + len(name) + 2
    for t in tabs:
        lab = " %s " % t
        if t == active:
            cv.put(x, y, lab, "0", "7")
        else:
            cv.put(x, y, lab, "8")
        cv.hit("tab:" + t.lower(), x, y, len(lab), 1, t)
        x += len(lab) + 1
    end = cv.w - len(right) - 1
    if right:
        cv.put(end + 1, y, right, rfg)
    rule(cv, x, y, end - 1)


def rule(cv, x1, y, x2, fg="c"):
    for x in range(x1, x2 + 1):
        cv.put(x, y, "-", fg)


def section(cv, x, y, w, title, right="", rfg="8"):
    cv.put(x, y, title, "8")
    right = str(right)
    end = x + w - 1 - (len(right) + 1 if right else 0)
    if right:
        cv.put(end + 1, y, right, rfg)
    rule(cv, x + len(title) + 1, y, end - 1)


def leader(cv, x, y, w, label, value, vfg="0", lfg="8"):
    value = str(value)
    cv.put(x, y, label[:max(0, w - len(value) - 1)], lfg)
    vx = x + w - len(value)
    for i in range(x + len(label) + 1, vx - 1):
        cv.put(i, y, "·", "c")
    cv.put(vx, y, value, vfg)


def ticks(cv, x, y, n, done, fg="3", rest="8", ch="|", restch="·"):
    for i in range(n):
        cv.put(x + i, y, ch if i < done else restch, fg if i < done else rest)


def filled(n, part, whole):
    """Cells of an n-cell tick row for part of whole; any part > 0 shows at least one."""
    if whole <= 0 or part <= 0:
        return 0
    return max(1, min(n, (part * n * 2 + whole) // (whole * 2)))


def progress(cv, x, y, n, done, total, fg="3", ch="|", rest="8", restch="·"):
    """A tick row with its explicit fraction after it. Returns the column after the fraction."""
    ticks(cv, x, y, n, filled(n, done, total), fg, rest, ch, restch)
    frac = "%d/%d" % (done, total)
    cv.put(x + n + 1, y, frac, "0")
    return x + n + 1 + len(frac)


def chip(cv, x, y, label, bid, kind="plain", w=None):
    """One-row control; w fixes the width and centres the label. Returns the column after it."""
    fg, bg = CHIP[kind]
    w = w or len(label) + 2
    cv.put(x, y, " " * w, fg, bg)
    cv.put(x + max(0, (w - len(label)) // 2), y, label[:w], fg, bg)
    cv.hit(bid, x, y, w, 1, label)
    return x + w


def flag(cv, x, y, w, text, detail=""):
    """! text detail; the detail is drawn only when it fits."""
    cv.put(x, y, "!", "e")
    text = text[:max(0, w - 2)]
    cv.put(x + 2, y, text, "0")
    if detail and x + 3 + len(text) + len(detail) <= x + w:
        cv.put(x + 3 + len(text), y, detail, "8")


def box(cv, x, y, w, h, fg):
    rule(cv, x, y, x + w - 1, fg)
    rule(cv, x, y + h - 1, x + w - 1, fg)
    for j in range(y, y + h):
        cv.put(x, j, "|", fg)
        cv.put(x + w - 1, j, "|", fg)
    for a, b in ((x, y), (x + w - 1, y), (x, y + h - 1), (x + w - 1, y + h - 1)):
        cv.put(a, b, "+", fg)


# Thin seven-segment digits drawn with - | +.
SEG = {"0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd", "4": "fgbc", "5": "afgcd", "6": "afgedc",
       "7": "abc", "8": "abcdefg", "9": "abcdfg", "-": "g"}


def digit(cv, x, y, d, fg="0", w=4, h=5):
    segs, m = SEG[d], h // 2
    if d == "1":
        for r in range(h):
            cv.put(x + w // 2, y + r, "|", fg)
        return
    hz = {"a": 0, "g": m, "d": h - 1}
    vt = {"f": (0, 1, m - 1), "b": (w - 1, 1, m - 1), "e": (0, m + 1, h - 2), "c": (w - 1, m + 1, h - 2)}
    for s, row in hz.items():
        if s in segs:
            for i in range(1, w - 1):
                cv.put(x + i, y + row, "-", fg)
    for s, (col, r1, r2) in vt.items():
        if s in segs:
            for r in range(r1, r2 + 1):
                cv.put(x + col, y + r, "|", fg)
    for col in (0, w - 1):
        for row in (0, m, h - 1):
            hor = any(s in segs for s, r in hz.items() if r == row)
            ver = any(s in segs and c == col and (r1 - 1 == row or r2 + 1 == row)
                      for s, (c, r1, r2) in vt.items())
            if hor and ver:
                cv.put(x + col, y + row, "+", fg)
            elif hor:
                cv.put(x + col, y + row, "-", fg)
            elif ver:
                cv.put(x + col, y + row, "|", fg)


def digits(cv, x, y, text, fg="0", w=4, h=5, gap=2):
    """Large line digits for numbers read across a room. Returns the drawn width."""
    for i, d in enumerate(text):
        digit(cv, x + i * (w + gap), y, d, fg, w, h)
    return len(text) * (w + gap) - gap


# ---------------------------------------------------------------- job screens (S3)

def role_bar(cv, name, tabs, short, active, right="", rfg="8"):
    """Header with tabs: the full labels when they fit beside the right word, then the short
    labels, then without the right word. active is the tab's index. Returns whether right shows."""
    def end(ts):
        return 2 + len(name) + 2 + sum(len(t) + 3 for t in ts)
    if end(tabs) + len(right) + 2 > cv.w:
        tabs = short
    if end(tabs) + len(right) + 2 > cv.w:
        right = ""
    bar(cv, name, tabs, tabs[active], right, rfg)
    return right != ""


def stepper(cv, x, y, value, bid, vw=8):
    """- value +: chips with ids bid- and bid+ around a value centred in vw cells. Returns the next column."""
    chip(cv, x, y, "-", bid + "-")
    value = str(value)[:vw]
    cv.put(x + 5 + (vw - len(value)) // 2, y, value, "0")
    return chip(cv, x + 6 + vw, y, "+", bid + "+")


def actions(cv, y, items, gap=1):
    """Screen-wide chips of equal width over columns 2 to w-1; items are (label, id, kind)."""
    n = len(items)
    bw = (cv.w - 2 - gap * (n - 1)) // n
    for i, (label, bid, kind) in enumerate(items):
        chip(cv, 2 + i * (bw + gap), y, label, bid, kind, bw)
