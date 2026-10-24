"""The pocket role in route A: FLEET, ALERTS, JOBS, SHOP and PAIR at 26x20; the twin of the pocket pages
in so-mod-panel.lua. The data comes from the status model (status.py) and tests/ui/system-scene.txt.
"""
from cc import Canvas
from kit import actions, chip, digits, filled, leader, progress, rule, section, ticks, tone
import status as ST
from scene import lines

TABS = ["FLEET", "JOBS", "SHOP", "PAIR"]


def system():
    """tests/ui/system-scene.txt: the alert, shop stock, pair code, outage and server log of the scene."""
    s = {"stock": [], "log": []}
    for p in lines("system-scene.txt"):
        k = p[0]
        if k == "alert":
            s["alert"] = dict(key=p[1], id=int(p[2]), text=" ".join(p[3:]))
        elif k == "saplings":
            s["saplings"] = int(p[1])
        elif k == "stock":
            s["stock"].append((p[1], int(p[2])))
        elif k == "search":
            s["search"] = p[1]
        elif k == "order":
            s["order"] = (int(p[1]), p[2])
        elif k == "pair":
            s["code"], s["left"] = p[1], int(p[2])
        elif k == "outage":
            s["since"], s["retry"] = int(p[1]), int(p[2])
        elif k == "log":
            s["log"].append(" ".join(p[1:]))
    return s


SYS = system()


def tabs(cv, active, dot):
    """The pocket header: four tabs from column 1, the active one on the panel colour, and a coral dot
    inside FLEET while anything needs a look."""
    x = 1
    for t in TABS:
        lab = " %s " % t
        on = t.lower() == active
        cv.put(x, 1, lab, "0" if on else "8", "7" if on else "f")
        cv.hit("tab:" + t.lower(), x, 1, len(lab), 1, t)
        x += len(lab)
    if dot:
        cv.put(7, 1, "•", "e")


def fleet(m, w=26, h=20):
    """Status's one-column layout under the tab bar; the alert rows open the ALERTS page."""
    cv = Canvas(w, h, "Pocket FLEET")
    q = dict(m)
    q["alerts"] = []
    ST.column(cv, q)
    cv.fill(1, 1, w, 1, "f")
    tabs(cv, "fleet", len(m["flags"]) > 0)
    for y in range(3, 3 + min(len(m["flags"]), 2 if h >= 17 else 1)):
        cv.hit("alerts", 2, y, w - 2, 1)
    return cv


def wrap(text, width):
    """Word wrap; a word longer than the width is cut. The twin of P.wrap."""
    out, line, width = [], "", max(1, width)
    for word in text.split():
        while len(word) > width:
            if line:
                out.append(line)
                line = ""
            out.append(word[:width])
            word = word[width:]
        if not line:
            line = word
        elif len(line) + 1 + len(word) <= width:
            line += " " + word
        else:
            out.append(line)
            line = word
    if line:
        out.append(line)
    return out


def alert_pages(flags, w, h):
    """Each flag is its wrapped text, then its wrapped detail, then a blank row."""
    pages, page, used, room = [], None, 0, h - 5
    for f in flags:
        rows = [(t, "0") for t in wrap(f["text"], w - 4)[:2]]
        rows += [(t, "8") for t in wrap(f.get("detail") or "", w - 4)[:2]]
        if page is None or used + len(rows) > room:
            page, used = [], 0
            pages.append(page)
        page.append(rows)
        used += len(rows) + 1
    return pages


def alerts(m, w=26, h=20, at=0):
    cv = Canvas(w, h, "Pocket ALERTS, a FLEET page")
    tabs(cv, "fleet", len(m["flags"]) > 0)
    section(cv, 2, 3, w - 2, "ALERTS", len(m["flags"]), "e" if m["flags"] else "8")
    pages = alert_pages(m["flags"], w, h)
    at = at % max(1, len(pages))
    y = 4
    for rows in (pages[at] if pages else []):
        cv.put(2, y, "!", "e")
        for text, fg in rows:
            cv.put(4, y, text, fg)
            y += 1
        y += 1
    if len(pages) > 1:
        chip(cv, 2, h, "◄", "alert-prev")
        n = "%d/%d" % (at + 1, len(pages))
        cv.put((w - len(n)) // 2 + 1, h, n, "8")
        chip(cv, w - 3, h, "►", "alert-next")
    return cv


# ---------------------------------------------------------------- jobs

def facts(m):
    """What mine.facts() and lumber.facts() report for the scene (the panel falls back to the model)."""
    mi, lu = m["mining"], m["lumber"]
    mine = [t for t in m["turtles"] if t["where"] not in ("farm", "-")]
    low = min(mine, key=lambda t: (t["fuel"], t["id"]))
    farm = [t for t in m["turtles"] if t["where"] == "farm"]
    return {"mining": dict(state=mi["state"], done=mi["done"], total=mi["total"], busy=mi["busy"],
                           workers=mi["workers"], lane=mi["lane"], fuel=dict(value=low["fuel"], id=low["id"])),
            "lumber": dict(state=lu["state"], ready=lu["ready"], spots=lu["spots"], grow=lu["grow"],
                           saplings=SYS["saplings"], fuel=farm[0]["fuel"])}


def state_word(state, room):
    """A long hold reason reads as its first word; the alert list has the rest."""
    if len(state) <= room:
        return state
    word = state
    for i, ch in enumerate(state):
        if ch in " :;,":
            word = state[:i]
            break
    return word[:room]


def job_chips(cv, y, w, role, running, loaded):
    half = (w - 4) // 2
    for i, cmd in enumerate(("start", "stop")):
        x = 2 if i == 0 else w - half
        label = cmd.upper()
        if not loaded:
            cv.put(x, y, " " * half, "8", "7")
            cv.put(x + (half - len(label)) // 2, y, label, "8", "7")
            continue
        kind = ("muted" if running else "primary") if cmd == "start" else ("stop" if running else "muted")
        chip(cv, x, y, label, role + ":" + cmd, kind, half)


def job(cv, y, w, role, f):
    title = role.upper()
    loaded = f is not None
    state = f["state"] if loaded else "not loaded"
    word = state_word(state, w - 2 - len(title) - 3)
    section(cv, 2, y, w - 2, title, word, tone(word) if loaded else "8")
    if loaded:
        lw = w - 2
        if role == "mining":
            progress(cv, 2, y + 1, 10, f.get("done", 0), f.get("total", 0))
            busy = f.get("busy") is not None and f.get("workers") is not None
            leader(cv, 2, y + 2, lw, "busy", "%d/%d" % (f["busy"], f["workers"]) if busy else "-", "0" if busy else "8")
            lane = f.get("lane")
            leader(cv, 2, y + 3, lw, "lane", ("▲►▼◄"[lane["facing"]] if lane.get("facing") in (0, 1, 2, 3) else "•")
                   + str(lane["id"]) if lane else "-", "b" if lane else "8")
            fuel = f.get("fuel")
            leader(cv, 2, y + 4, lw, "min fuel", "%d #%d" % (fuel["value"], fuel["id"]) if fuel else "-",
                   ("1" if fuel["value"] < 500 else "0") if fuel else "8")
        else:
            spots = f.get("spots", 0)
            progress(cv, 2, y + 1, min(12, spots) if spots > 0 else 12, f.get("ready", 0), spots, "d", "♠", "8", "♣")
            for i, (label, key) in enumerate((("next grow", "grow"), ("saplings", "saplings"), ("fuel", "fuel"))):
                v = f.get(key)
                leader(cv, 2, y + 2 + i, lw, label, "-" if v is None else str(v), "8" if v is None else "0")
    job_chips(cv, y + 6, w, role, loaded and state not in ("stopped", "not loaded"), loaded)


def jobs(m, w=26, h=20, f=None, title="Pocket JOBS"):
    cv = Canvas(w, h, title)
    tabs(cv, "jobs", len(m["flags"]) > 0)
    f = f or facts(m)
    job(cv, 3, w, "mining", f.get("mining"))
    job(cv, 12, w, "lumber", f.get("lumber"))
    return cv


# ---------------------------------------------------------------- shop

def matches(search, limit):
    """so-mod-shop's matches: items whose id contains the search, most stock first, then by id."""
    q = search.lower().replace(" ", "_")
    items = [dict(name=n, count=c, label=n.split(":", 1)[-1].replace("_", " ").upper())
             for n, c in SYS["stock"] if q in n.lower()]
    items.sort(key=lambda i: (-i["count"], i["name"]))
    return items[:limit]


def count_fg(n):
    return "8" if n == 0 else "1" if n < 10 else "0"


def shop(m, w=26, h=20, search=None, sent=None, selected=None):
    cv = Canvas(w, h, "Pocket SHOP quick order")
    tabs(cv, "shop", len(m["flags"]) > 0)
    search = SYS["search"] if search is None else search
    width = w - 8
    cv.put(2, 3, ">", "8")
    cv.put(4, 3, search[-width:], "0")
    cv.put(4 + len(search[-width:]), 3, "_", "9")
    if search:
        chip(cv, w - 3, 3, "×", "clear", "off")
    rule(cv, 2, 4, w - 1)
    items, y = matches(search, h), 5
    shown = next((i for i in items if i["name"] == selected), items[0] if items else None)
    if not items:
        cv.put(2, y, "no match" if search else "no stock", "8")
    for item in items:
        if y > h - 2 - (2 if item is shown else 0):
            break
        if item is shown:
            cv.fill(1, y, w, 1, "7")
        leader(cv, 2, y, w - 2, item["label"], str(item["count"]), count_fg(item["count"]), "0")
        cv.hit("pick:" + item["name"], 2, y, w - 2, 1)
        y += 1
        if item is shown:
            cw = (w - 4) // 3
            for i, n in enumerate((1, 16, 64)):
                chip(cv, 2 + i * (cw + 1), y, str(n), "order:%d:%s" % (n, item["name"]), "plain", cw)
            y += 2
    if sent:
        cv.put(2, h - 1, sent[0][:w - 2], sent[1])
    return cv


def shop_sent():
    n, name = SYS["order"]
    label = next(i["label"] for i in matches(name, 99) if i["name"] == name)
    return shop(ST.model(), sent=("%d %s sent" % (n, label), "d"))


# ---------------------------------------------------------------- pair

CODE_LIFE = 300000


def code_digits(cv, y, w, text, fg):
    """Six line digits, three cells wide, across a 26-cell pocket."""
    width = len(text) * 4 - 1
    digits(cv, (w - width) // 2 + 1, y, text, fg, 3, 7, 1)


def pair(m, w=26, h=20, code=None, left=0, busy=False, paired=True, enroll=None):
    """enroll is None without the enroll window module, else whether ENROLL can open now."""
    cv = Canvas(w, h, "Pocket PAIR " + ("with a code" if code else "ready"))
    tabs(cv, "pair", len(m["flags"]) > 0)
    code_digits(cv, 5, w, code or "------", "0" if code else "8")
    if code:
        secs = -(-left // 1000)
        ticks(cv, 2, 14, 18, filled(18, left, CODE_LIFE), "9")
        cv.put(21, 14, "%d:%02d" % (secs // 60, secs % 60), "0")
    elif busy:
        cv.put(2, 14, "code in use", "1")
    if paired:
        chip(cv, 2, h - 2, "NEW CODE", "pair-code", "plain", w - 2)
    # The paired devices and the enroll window open as pages of the PAIR tab.
    if enroll is None:
        chip(cv, 2, h - 4, "PAIRED", "paired", "plain", w - 2)
    else:
        actions(cv, h - 4, [("PAIRED", "paired", "plain"), ("ENROLL", "enroll", "primary" if enroll else "muted")])
    return cv
