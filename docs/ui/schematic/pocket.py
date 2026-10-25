"""The pocket role in route A: FLEET, ALERTS, JOBS, SHOP and PAIR at 26x20; the twin of the pocket pages
in so-mod-panel.lua. The data comes from the status model (status.py) and tests/ui/system-scene.txt.
"""
from cc import Canvas
from kit import chip, digits, filled, flag, leader, progress, rule, section, ticks, tone
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
    """A long hold reason reads as its first word; the alert list has the rest. A word that does not
    fit is left out."""
    if len(state) <= room:
        return state
    word = state
    for i, ch in enumerate(state):
        if ch in " :;,":
            word = state[:i]
            break
    return word if len(word) <= room else ""


def dead(cv, x, y, label, width):
    """A grey chip without a target, for a control whose module is missing."""
    cv.put(x, y, " " * width, "8", "7")
    cv.put(x + (width - len(label)) // 2, y, label, "8", "7")


def job_chips(cv, x, y, cw, role, running, loaded):
    half = (cw - 2) // 2
    for i, cmd in enumerate(("start", "stop")):
        cx = x if i == 0 else x + cw - half
        label = cmd.upper()
        if not loaded:
            dead(cv, cx, y, label, half)
            continue
        kind = ("muted" if running else "primary") if cmd == "start" else ("stop" if running else "muted")
        chip(cv, cx, y, label, role + ":" + cmd, kind, half)


def job_rows(mode, reason=None):
    """full 7 rows, tight 6 (7 with a flag), compact the section and the chips (3 with a flag)."""
    if mode == "compact":
        return 3 if reason else 2
    return 7 if mode == "full" or reason else 6


def job(cv, x, y, cw, role, f, mode="full", reason=None):
    title = role.upper()
    loaded = f is not None
    state = f["state"] if loaded else "not loaded"
    word = state_word(state, cw - len(title) - 3)
    last = y + job_rows(mode, reason) - 1
    section(cv, x, y, cw, title, word, tone(word) if loaded else "8")
    if reason:
        flag(cv, x, last - 1, cw, (wrap(reason, cw - 2) or [""])[0])
    if loaded and mode != "compact":
        if role == "mining":
            frac = "%d/%d" % (f.get("done", 0), f.get("total", 0))
            progress(cv, x, y + 1, min(10, cw - len(frac) - 1), f.get("done", 0), f.get("total", 0))
            busy = f.get("busy") is not None and f.get("workers") is not None
            leader(cv, x, y + 2, cw, "busy", "%d/%d" % (f["busy"], f["workers"]) if busy else "-", "0" if busy else "8")
            lane = f.get("lane")
            leader(cv, x, y + 3, cw, "lane", ("▲►▼◄"[lane["facing"]] if lane.get("facing") in (0, 1, 2, 3) else "•")
                   + str(lane["id"]) if lane else "-", "b" if lane else "8")
            fuel = f.get("fuel")
            leader(cv, x, y + 4, cw, "min fuel", "%d #%d" % (fuel["value"], fuel["id"]) if fuel else "-",
                   ("1" if fuel["value"] < 500 else "0") if fuel else "8")
        else:
            spots = f.get("spots", 0)
            frac = "%d/%d" % (f.get("ready", 0), spots)
            progress(cv, x, y + 1, min(spots if spots > 0 else 12, 12, cw - len(frac) - 1), f.get("ready", 0), spots,
                     "d", "♠", "8", "♣")
            for i, (label, key) in enumerate((("next grow", "grow"), ("saplings", "saplings"), ("fuel", "fuel"))):
                v = f.get(key)
                leader(cv, x, y + 2 + i, cw, label, "-" if v is None else str(v), "8" if v is None else "0")
    job_chips(cv, x, last, cw, role, loaded and state not in ("stopped", "not loaded"), loaded)


def jobs(m, w=26, h=20, f=None, title="Pocket JOBS"):
    cv = Canvas(w, h, title)
    tabs(cv, "jobs", len(m["flags"]) > 0)
    f = f or facts(m)
    job(cv, 2, 3, w - 2, "mining", f.get("mining"))
    job(cv, 2, 12, w - 2, "lumber", f.get("lumber"))
    return cv


# ---------------------------------------------------------------- shop

# so-mod-shop's stack sizes for the scene's items: tools stack to 1, the rest to 64.
STACKS = {"minecraft:iron_pickaxe": 1}


def matches(search, limit, stock=None):
    """so-mod-shop's matches: items whose id contains the search, most stock first, then by id."""
    q = search.lower().replace(" ", "_")
    items = [dict(name=n, count=c, label=n.split(":", 1)[-1].replace("_", " ").upper(), stack=STACKS.get(n, 64))
             for n, c in (SYS["stock"] if stock is None else stock) if q in n.lower()]
    items.sort(key=lambda i: (-i["count"], i["name"]))
    return items[:limit]


def lows(search, stock=None):
    """so-mod-shop's lows: low (under 16) and empty items whose id contains the search, emptiest first."""
    items = [dict(i, state="empty" if i["count"] == 0 else "low") for i in matches(search, 999, stock)
             if i["count"] < min(16, i["stack"])]
    items.sort(key=lambda i: (i["count"], i["name"]))
    return items


def split(text):
    """P.split: a typed search may end in a quantity ("sand 37")."""
    head, _, tail = text.rpartition(" ")
    if head.strip() and tail.isdigit():
        return head.rstrip(), int(tail)
    return text, None


def count_fg(n):
    return "8" if n == 0 else "1" if n < 10 else "0"


def order_line(n, label, status, width):
    """P.orderLine: the count and status always show; a long label is cut and ends in "..."."""
    head, tail = "%s " % n, " " + status
    room = width - len(head) - len(tail)
    if len(label) > room:
        label = label[:room - 3].rstrip() + "..." if room > 3 else ""
    return head + label + tail


def pager(cv, y, note, back, forward):
    """U.pager: a muted note, then the left and right chips at the right end."""
    chip(cv, cv.w - 7, y, "◄", "prev", "plain" if back else "muted")
    chip(cv, cv.w - 3, y, "►", "next", "plain" if forward else "muted")
    cv.put(cv.w - 8 - len(note), y, note, "8")


def shop(m, w=26, h=20, search=None, sent=None, selected=None, reply=None, stock=None, found=True, stale=False,
         show="all", page=1, title="Pocket SHOP quick order"):
    """sent is the last order's line and colour; reply is the shop's reply under it. show is the all, low
    or empty chip; page is the result page when the matches need a pager on row h-2."""
    cv = Canvas(w, h, title)
    tabs(cv, "shop", len(m["flags"]) > 0)
    raw = SYS["search"] if search is None else search
    search, qty = split(raw)
    width = w - 8
    cv.put(2, 3, ">", "8")
    cv.put(4, 3, raw[-width:], "0")
    cv.put(4 + len(raw[-width:]), 3, "_", "9")
    if raw:
        chip(cv, w - 3, 3, "×", "clear", "off")
    cw, y = (w - 4) // 3, 4
    for i, f in enumerate(("all", "low", "empty")):
        chip(cv, 2 + i * (cw + 1), y, f, "show:" + f, "on" if f == show else "plain", cw)
    y += 1
    if not found:
        flag(cv, 2, y, w - 2, "storage room not found")
    if found and stale:
        cv.put(2, y, "stock stale", "1")
        y += 1
    if not found:
        items = []
    elif show == "all":
        items = matches(search, 256, stock)
    else:
        items = [i for i in lows(search, stock) if i["state"] == show]
    if found and not items:
        cv.put(2, y, "no stock" if not search and show == "all" else "none " + show if show != "all" else "no match", "8")

    def grow(item):
        return 3 if item and item["count"] > 0 else 0

    def pick(lst):
        return next((i for i in lst if i["name"] == selected), lst[0] if lst else None)

    bottom, lst = h - 2, items
    if len(items) + grow(pick(items)) > bottom - y + 1:
        per = max(1, bottom - y - 3)
        pages = -(-len(items) // per)
        page = max(1, min(page, pages))
        lst = items[(page - 1) * per:page * per]
        pager(cv, bottom, "%d/%d" % (page, pages), page > 1, page < pages)
        bottom -= 1
    shown = pick(lst)
    for item in lst:
        if y > bottom - (2 if item is shown and grow(item) else 0):
            break
        if item is shown:
            cv.fill(1, y, w, 1, "7")
        leader(cv, 2, y, w - 2, item["label"], str(item["count"]), count_fg(item["count"]), "0")
        cv.hit("pick:" + item["name"], 2, y, w - 2, 1)
        y += 1
        if item is shown and item["count"] > 0:
            half = (w - 3) // 2
            if qty is None:
                for i, n in enumerate((1, 16, 64)):
                    chip(cv, 2 + i * (cw + 1), y, str(n), "order:%d:%s" % (n, item["name"]), "plain", cw)
            elif 1 <= qty <= item["stack"]:
                chip(cv, 2, y, "ORDER %d" % qty, "order:%d:%s" % (qty, item["name"]), "plain", w - 2)
            else:
                dead(cv, 2, y, "MAX %d" % item["stack"], w - 2)
            chip(cv, 2, y + 1, "STACK", "order:stack:" + item["name"], "plain", half)
            chip(cv, 3 + half, y + 1, "ALL", "order:all:" + item["name"], "plain", half)
            y += 3
    if sent:
        cv.put(2, h - 1, sent[0][:w - 2], sent[1])
    if reply:
        cv.put(2, h, reply[:w - 2], "8")
    return cv


# A 40-item search for paging: ITEM 01 to ITEM 40, 790 down to 10.
FORTY = [("mod:item_%02d" % i, 810 - i * 20) for i in range(1, 41)]


def shop_sent():
    n, name = SYS["order"]
    label = next(i["label"] for i in matches(name, 99) if i["name"] == name)
    return shop(ST.model(), sent=(order_line(n, label, "sent", 24), "d"))


# ---------------------------------------------------------------- pair

CODE_LIFE = 300000


def pair(m, w=26, h=20, code=None, left=0, busy=False, paired=True, enroll=None, title=None, g=None, cv=None):
    """enroll is None without the enroll window module, else whether ENROLL can open now. g places the
    code, ticks and chips: the pocket's PAIR tab by default, the panel's PAIR page from panel.py."""
    if cv is None:
        cv = Canvas(w, h, title or "Pocket PAIR " + ("with a code" if code else "ready"))
        tabs(cv, "pair", len(m["flags"]) > 0)
    g = g or dict(y=5, dw=3, dh=7, gap=1, ty=14, list=h - 4, new=h - 2)
    text = code or "------"
    width = len(text) * (g["dw"] + g["gap"]) - g["gap"] if g.get("dw") else w - 2
    x = (w - width) // 2 + 1
    if g.get("dw"):
        digits(cv, x, g["y"], text, "0" if code else "8", g["dw"], g["dh"], g["gap"])
    else:
        cv.put(x, g["y"], text, "0" if code else "8")
    if code:
        secs = -(-left // 1000)
        ticks(cv, x, g["ty"], width - 5, filled(width - 5, left, CODE_LIFE), "9")
        cv.put(x + width - 4, g["ty"], "%d:%02d" % (secs // 60, secs % 60), "0")
    elif busy:
        cv.put(x, g["ty"], "code in use", "1")
    if paired:
        if g.get("back") == g["new"]:
            chip(cv, 2, g["new"], "NEW CODE", "pair-code")
        else:
            chip(cv, 2, g["new"], "NEW CODE", "pair-code", "plain", w - 2)
    if g.get("back"):
        chip(cv, w - 6, g["back"], "BACK", "panel-back")
    # The paired devices and the enroll window open as pages of PAIR; the panel's chips keep their own width.
    if g.get("back"):
        x = chip(cv, 2, g["list"], "PAIRED", "paired") + 1
        if enroll:
            chip(cv, x, g["list"], "ENROLL", "enroll", "primary")
        elif enroll is not None:
            dead(cv, x, g["list"], "ENROLL", 8)
        return cv
    if enroll is None:
        chip(cv, 2, g["list"], "PAIRED", "paired", "plain", w - 2)
        return cv
    bw = (w - 3) // 2
    chip(cv, 2, g["list"], "PAIRED", "paired", "plain", bw)
    if enroll:
        chip(cv, 3 + bw, g["list"], "ENROLL", "enroll", "primary", bw)
    else:
        dead(cv, 3 + bw, g["list"], "ENROLL", bw)
    return cv
