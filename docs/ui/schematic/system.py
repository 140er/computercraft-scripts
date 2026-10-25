"""The system screens in route A: the alert takeover and the unassigned page (so-mod-display.lua), the
no-server bar (display.lua) and the server terminal (D.terminal in so-mod-display.lua)."""
import re

from cc import Canvas
from kit import age, bar, box, chip, digits, filled, flag, leader, mark, rule, section, ticks
import mapdraw as MD
import status as ST
from pocket import SYS, wrap

TAKEOVER = 5000


# ---------------------------------------------------------------- alert takeover

def subject(m, a):
    """The turtle or drop an alert is about: { label, x, y, z, id | drop } or None."""
    if a.get("id") is not None:
        for t in m["turtles"]:
            if t["id"] == a["id"] and t.get("x") is not None:
                return dict(label="#%d" % t["id"], x=t["x"], y=t["y"], z=t["z"], id=t["id"], row=t)
    if a.get("kind"):
        for d in m["drops"]:
            if d["kind"] == a["kind"]:
                return dict(label="drop %d" % d["id"], x=d["x"], y=d["y"], z=d["z"], drop=d["id"], row=d)
    return None


def subject_rows(s):
    """The subject's facts, drawn where the crop would be when there is no map."""
    r = s["row"]
    if s.get("drop") is not None:
        return [("kind", r["kind"], "0"), ("state", "broken" if r["broken"] else "ok", "e" if r["broken"] else "0")]
    fuel = r.get("fuel")
    return [("state", r["state"], ST.state_fg(r["tone"])), ("where", r["where"], "0"),
            ("fuel", "-" if fuel is None else str(fuel), "8" if fuel is None else "1" if fuel < 500 else "0"),
            ("ore", str(r.get("ore", "-")), "0"), ("seen", age(r.get("ago", 0), True), "8")]


def crop(cv, x, y, w, h, focus):
    """The scene's map around the focus at one block per cell, the subject inverted: what map.crop draws.
    mapdraw's own crop (the twin of so-mod-map's map.crop) wins once it is there."""
    if hasattr(MD, "crop"):
        return MD.crop(cv, x, y, w, h, focus) is not False
    x1, _, x2, _ = MD.bounds(focus["y"])
    left = min(focus["x"] - w // 2, x2 + 2 - w)
    left = max(left, x1 - 1)
    v = MD.view(w, h, focus["y"], 1, 1, left + w // 2, focus["z"])
    MD.draw(cv, v, x, y, select=str(focus["id"]) if focus.get("id") is not None else None,
            select_drop=focus.get("drop"))
    return True


def alert(m, a, w, h, left=None, mapped=True, title="Alert takeover"):
    """Coral frame and title chip, the subject's position, the detail, a map crop around the subject
    and a coral tick row counting the takeover down. The #id chip opens its turtle; a tap anywhere
    else dismisses it."""
    cv = Canvas(w, h, title)
    box(cv, 1, 1, w, h, "e")
    mx = 5 if w >= 40 else 3
    iw = w - 2 * (mx - 1)
    s = subject(m, a)
    name = ((s["label"] + " ") if s and s.get("id") is not None else "") + a["text"]
    rest = len(name) > iw - 2 and s and s.get("id") is not None
    label = " %s " % (s["label"] if rest else name).upper()[:iw - 2]
    y = 3 if h >= 10 else 2
    chip_y = y
    cv.put(mx, y, label, "f", "e")
    if rest:
        for line in wrap(a["text"], iw)[:2]:
            if y + 1 < h - 2:
                y += 1
                cv.put(mx, y, line, "0")
    pos = s and "%d,%d,%d" % (s["x"], s["y"], s["z"])
    if pos and len(pos) <= iw:
        if not rest and len(label) + 1 + len(pos) <= iw:
            cv.put(mx + len(label) + 1, y, pos, "0")
        elif y + 1 < h - 2:
            y += 1
            cv.put(mx, y, pos, "0")
    detail = a.get("detail") or a.get("sub")
    if detail and y + 2 < h - 2:
        y += 2
        cv.put(mx, y, detail[:iw], "8")
    top, bottom = y + 2, h - 5
    drawn = False
    if mapped and s and bottom - top + 1 >= 3 and iw >= 10:
        drawn = crop(cv, mx, top, iw, bottom - top + 1, s)
    if s and not drawn:
        for i, (label, value, fg) in enumerate(subject_rows(s)):
            if top + i <= bottom:
                leader(cv, mx, top + i, min(iw, 30), label, value, fg)
    if left is not None and h >= 8:
        ticks(cv, mx, h - 2, iw, filled(iw, left, TAKEOVER), "e")
    cv.hit("dismiss", 1, 1, w, h)
    # Clients take the last button drawn, so the chip goes after the dismiss hit.
    if s and s.get("id") is not None:
        cv.hit("turtle:%d" % s["id"], mx, chip_y, len(label), 1)
    return cv


# ---------------------------------------------------------------- status ALERTS

# Standing alerts, oldest first, as the gather lists them; tests/so/display-server.lua raises the same.
ALERTS = [dict(text="ore chest full", detail="drop point #3"), dict(text="out of saplings"),
          dict(text="#4 lease expired, lane released")]
ALERTS_XS = [dict(text="alert %d" % i) for i in range(1, 8)]


def alert_list(alerts, w, h, page=0, title="Status ALERTS"):
    """Every standing alert, newest first, one flag row each; BACK and a pager on the last row, the arrows
    moved up to the edge on narrow displays. The page count sits between BACK and the arrows when it
    fits, else in the header."""
    cv = Canvas(w, h, title)
    shown = list(reversed(alerts))
    top = 3 if h >= 6 else 2
    capacity = max(1, h - top - 1)
    pages = max(1, -(-len(shown) // capacity))
    page %= pages
    back = "BACK" if w >= 15 else "×"
    free = 2 + len(back) + 3
    px = max(w - 7, free)
    note = "%d/%d" % (page + 1, pages) if pages > 1 else None
    footer = note is not None and px - 1 - len(note) >= free
    bar(cv, "ALERTS", right=note if note and not footer else str(len(shown)), rfg="e" if shown else "8")
    if not shown:
        cv.put(2, top, "no alerts", "8")
    for i, a in enumerate(shown[page * capacity:(page + 1) * capacity]):
        flag(cv, 2, top + i, w - 2, a["text"], a.get("detail") or "")
    chip(cv, 2, h, back, "alerts-back")
    if pages > 1 and px + 6 <= w:
        chip(cv, px, h, "◄", "alert-prev")
        chip(cv, px + 4, h, "►", "alert-next")
        if footer:
            cv.put(px - 1 - len(note), h, note, "8")
    return cv


# ---------------------------------------------------------------- unassigned

def unassigned(w, h, ident, name="UNASSIGNED", title="Unassigned display"):
    """The role name in the header and the display id in line digits, as large as fits."""
    cv = Canvas(w, h, title)
    bar(cv, name)
    text = str(ident)
    n = len(text)
    dh = min(11, h - 3)
    dh -= 1 - dh % 2
    dw = min(9, dh - 2, (w - 4 - 2 * (n - 1)) // n)
    if dh < 5 or dw < 3:
        cv.put(2, 3 if h >= 3 else h, text, "0")
        return cv
    width = n * (dw + 2) - 2
    digits(cv, (w - width) // 2 + 1, 3 + (h - 2 - dh) // 2, text, "0", dw, dh, 2)
    return cv


# ---------------------------------------------------------------- no server

def stale_bar(cv, since, retry):
    """display.lua's no-server row over the kept picture: the time since the last frame and the retry."""
    w = cv.w
    secs = since // 1000
    clock = "%d:%02d" % (secs // 60, secs % 60)
    cv.fill(1, 1, w, 1, "2", " ", "f")
    cv.put(2, 1, "NO SERVER", "f", "2")
    cv.put(13, 1, clock, "f", "2")
    right = "retry in %d s" % retry
    if 13 + len(clock) + 1 + len(right) > w - 1:
        right = "%ds" % retry
    if 13 + len(clock) + 1 + len(right) <= w - 1:
        cv.put(w - len(right), 1, right, "f", "2")
    return cv


def outage(picture, title):
    picture.title = title
    return stale_bar(picture, SYS["since"], -(-SYS["retry"] // 1000))


# ---------------------------------------------------------------- server terminal

def hints(cv, x, y, keys, step=12):
    for k, label in keys:
        cv.put(x, y, "[%s]" % k, "9")
        cv.put(x + len(k) + 3, y, label, "0")
        x += max(step, len(k) + 3 + len(label) + 2)


def log_line(cv, x, y, w, line):
    hit = re.match(r"^(\d\d:\d\d:\d\d) (.*)$", line)
    t, text = (hit.group(1), hit.group(2)) if hit else ("", line)
    if t:
        cv.put(x, y, t, "8")
        x, w = x + 9, w - 9
    cv.put(x, y, "•", mark(text))
    cv.put(x + 2, y, text[:max(0, w - 2)], "0")


def term_model(m):
    lost = sum(1 for t in m["turtles"] if t["lost"])
    return dict(m, ok=len(m["turtles"]) - lost, lost=lost)


def terminal(m, view, w=51, h=19, title="Server terminal"):
    cv = Canvas(w, h, title)
    bar(cv, "SO SERVER #%s" % view["id"], right=view.get("uptime", ""))
    mode = view.get("mode", "normal")
    log = view.get("log", [])
    if mode == "code":
        section(cv, 2, 3, w - 2, "PAIR CODE")
        code = view["code"]
        left = max(0, view["expires"] - view["now"])
        secs = -(-left // 1000)
        width = len(code) * 7 - 2
        x = (w - width) // 2 + 1
        if width <= w - 2 and h >= 14:
            digits(cv, x, 5, code, "0", 5, 7, 2)
            n = width - 5
            ticks(cv, x, 13, n, filled(n, left, 300000), "9")
            cv.put(x + n + 1, 13, "%d:%02d" % (secs // 60, secs % 60), "0")
        else:
            cv.put(2, 5, code, "0")
            cv.put(2 + len(code) + 1, 5, "%d:%02d" % (secs // 60, secs % 60), "8")
        hints(cv, 2, h, [("P", "new code"), ("Esc", "cancel")], 14)
        return cv
    if mode == "role":
        rows, notice = view.get("displays", []), view.get("notice", "")
        width = max(1, w - 2)
        lines = 0 if not notice else 2 if len(notice) > width else 1
        last = h - 1 - max(1, lines)
        section(cv, 2, 3, w - 2, "DISPLAYS", len(rows))
        for i, r in enumerate(rows):
            y = 4 + i
            if y > last:
                break
            if y == last and i < len(rows) - 1:
                cv.put(4, y, "+%d more" % (len(rows) - i), "8")
                break
            cv.put(2, y, "%3s" % r["id"], "0")
            cv.put(7, y, r.get("size", "-"), "8")
            cv.put(17, y, r["role"][:w - 17], "8" if r["role"] == "unassigned" else "0")
            if r.get("label") and w > 29:
                cv.put(28, y, r["label"][:w - 29], "0")
        for r in range(lines):
            cv.put(2, h - lines + r, notice[r * width:(r + 1) * width], "8")
        typed = view.get("input", "")
        keys = [("Enter", "set"), ("Esc", "back")]
        kx = w - sum(len(k) + 3 + len(l) for k, l in keys) - 2
        room = max(1, kx - 7)
        cv.put(2, h, ">", "9")
        cv.put(4, h, typed[-room:], "0")
        cv.put(4 + len(typed[-room:]), h, "_", "9")
        hints(cv, kx, h, keys, 0)
        return cv
    if mode == "log":
        section(cv, 2, 3, w - 2, "LOG", len(log))
        top = 4
    else:
        tm = term_model(m)
        y = 3
        na = 0
        for i, f in enumerate(m["flags"][:2]):
            flag(cv, 2, y + i, w - 2, f["text"])
            na += 1
        y = 4 + na if na else 3
        two = w >= 48
        lw = (w - 5) // 2 if two else w - 2
        rx = 2 + lw + 3 if two else 2
        ry = y if two else y + 5
        section(cv, 2, y, lw, "FLEET")
        ok = "%d ok" % tm["ok"]
        lost = " · %d lost" % tm["lost"] if tm["lost"] else ""
        leader(cv, 2, y + 1, lw, "turtles", ok + lost)
        if lost:
            cv.put(2 + lw - len(lost) + 3, y + 1, lost[3:], "e")
        leader(cv, 2, y + 2, lw, "displays", str(len(m["displays"])))
        leader(cv, 2, y + 3, lw, "leases", str(m["leases"]))
        d = m.get("disk")
        pct, fg = ST.disk_value(d)
        section(cv, rx, ry, w - rx, "DISK", pct, fg)
        ticks(cv, rx, ry + 1, w - rx, filled(w - rx, d["used"], d["cap"]) if d else 0, "e" if fg == "e" else "3")
        leader(cv, rx, ry + 2, w - rx, "used", "%.1f MB" % (d["used"] / 1e6) if d else "-", "0" if d else "8")
        code = view.get("pending")
        leader(cv, rx, ry + 3, w - rx, "pair", code or "-", "0" if code else "8")
        top = ry + 5
        section(cv, 2, top, w - 2, "LOG")
        top += 1
    if view.get("hostError"):
        cv.put(2, 2, view["hostError"][:w - 2], "e")
    count = max(0, h - 1 - top)
    last = max(0, len(log) - view.get("offset", 0))
    for i, line in enumerate(log[max(0, last - count):last]):
        log_line(cv, 2, top + i, w - 2, line)
    if mode == "log":
        hints(cv, 2, h, [("Esc", "back"), ("↑↓", "scroll")], 14)
    else:
        hints(cv, 2, h, [("P", "pair"), ("R", "roles"), ("L", "log")])
    return cv
