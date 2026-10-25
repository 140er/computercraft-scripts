"""The panel role in route A: the main page, ALERTS, PAIR, PAIRED and ENROLL at every size, and the
pocket's PAIRED and ENROLL pages; the twin of the panel pages in so-mod-panel.lua. The data comes from
the status model (status.py), tests/ui/system-scene.txt and tests/ui/panel-scene.txt.
"""
import hashlib

from cc import Canvas
from kit import actions, chip, leader, rule, section
import pocket as PK
import status as ST
from scene import lines

MODES = ("full", "tight", "compact")


def scene():
    """tests/ui/panel-scene.txt: the health count, the paired keys, and the enroll window."""
    s = {"paired": [], "pending": []}
    for p in lines("panel-scene.txt"):
        k = p[0]
        if k == "needs":
            s["needs"] = int(p[1])
        elif k == "paired":
            s["paired"].append(dict(id=int(p[1]), kind=None if p[2] == "-" else p[2],
                                    seen=None if p[3] == "-" else int(p[3])))
        elif k == "self":
            s["self"] = int(p[1])
        elif k == "confirm":
            s["confirm"] = int(p[1])
        elif k == "enroll":
            s["enroll"] = dict(token=p[1], left=int(p[2]), joined=int(p[3]), cap=int(p[4]))
        elif k == "pending":
            s["pending"].append(dict(id=int(p[1]), kind=p[2], fp=p[3], n=int(p[4])))
    return s


SC = scene()


def fingerprint(ident):
    """so-pair's fingerprint of a key; the scene's keys are the id as two hex digits, 32 times."""
    return hashlib.sha256(("%02x" % ident * 32).encode()).hexdigest()[:4].upper()


def header(cv, w, h, right="", needs=None):
    """PANEL, the HEALTH and NEEDS chips on the main page with the health module, a hairline, the time."""
    cv.put(2, 1, "PANEL", "0")
    x = 9
    if needs is not None and w >= 26 and h >= 12:
        x = chip(cv, x, 1, "HEALTH", "health") + 1
        n = str(needs)
        chip(cv, x, 1, "NEEDS " + n, "attention")
        if n != "0":
            cv.put(x + 7, 1, n, "1", "7")
        x += len(n) + 9
    if x + len(right) + 2 > w:
        right = ""
    if right:
        cv.put(w - len(right), 1, right, "8")
    rule(cv, x, 1, w - len(right) - 2)


def nav(cv, y, items):
    """Chips from column 2 at their own width, or shared equally when they do not fit."""
    need = sum(len(i[0]) + 3 for i in items) - 1
    if need > cv.w - 2:
        actions(cv, y, items)
        return
    x = 2
    for label, bid, kind in items:
        x = chip(cv, x, y, label, bid, kind) + 1


def back(cv, y, bid):
    chip(cv, cv.w - 6, y, "BACK", bid)


def act(cv, y, label, bid, fg, right=None):
    """A list row's own action as bracketed text ending at column right (w-1), so stacked rows never
    form a slab."""
    x = (right or cv.w - 1) - len(label) - 1
    cv.put(x, y, "[", "8")
    cv.put(x + 1, y, label, fg)
    cv.put(x + len(label) + 1, y, "]", "8")
    cv.hit(bid, x, y, len(label) + 2, 1, label)


def pager(cv, y, page, pages, prev, nxt):
    """Paging chips stay drawn on a single page (muted), as the old PREV and NEXT were."""
    n, kind = "%d/%d" % (page + 1, pages), "plain" if pages > 1 else "muted"
    if 9 + len(n) > cv.w - 8:
        chip(cv, 2, y, "◄", prev, kind, 1)
        chip(cv, 4, y, "►", nxt, kind, 1)
        return
    x = chip(cv, 2, y, "◄", prev, kind) + 1
    cv.put(x, y, n, "8")
    chip(cv, x + len(n) + 1, y, "►", nxt, kind)


def shop_block(cv, x, y, cw, search, loaded=True, sent=None, reply=None, found=True):
    """The search, its best match with the stock, 1, 16 and 64 (one ORDER n for a typed trailing count),
    then the last order (sent: line, colour) and the shop's reply. Without a storage room (found False)
    the chips are muted."""
    section(cv, x, y, cw, "SHOP", "" if loaded else "not loaded")
    if loaded:
        typed = search[-(cw - 3):] if cw > 3 else ""
        cv.put(x, y + 1, ">", "8")
        cv.put(x + 2, y + 1, typed, "0")
        cv.put(x + 2 + len(typed), y + 1, "_", "9")
        cv.hit("search", x, y + 1, cw, 1)
    search, qty = PK.split(search)
    live = loaded and found
    # S.best: an exact id keeps its count, even zero; another search takes the first match in stock.
    exact = [i for i in PK.matches(search, 99) if i["name"] == search]
    best = exact or ([i for i in PK.matches(search, 1) if i["count"] > 0] if search else [])
    if loaded and not live:
        cv.put(x, y + 2, "storage room not found"[:cw], "e")
    elif loaded and best:
        leader(cv, x, y + 2, cw, best[0]["label"], str(best[0]["count"]), "1" if best[0]["count"] < 10 else "0")
    elif loaded and search:
        cv.put(x, y + 2, "no match", "8")
    third = (cw - 2) // 3
    if qty is not None:
        if live:
            chip(cv, x, y + 3, "ORDER %d" % qty, "order:%d" % qty, "plain", cw)
        else:
            PK.dead(cv, x, y + 3, "ORDER %d" % qty, cw)
    for i, n in enumerate(() if qty is not None else (1, 16, 64)):
        cx = x + i * (third + 1)
        if live:
            chip(cv, cx, y + 3, str(n), "order:%d" % n, "plain", third)
        else:
            PK.dead(cv, cx, y + 3, str(n), third)
    if loaded and sent:
        cv.put(x, y + 4, sent[0][:cw], sent[1])
    if loaded and reply:
        cv.put(x, y + 5, reply[:cw], "8")


def fleet(m):
    lost = sum(1 for t in m["turtles"] if t["lost"])
    return "%d ok · %d lost" % (len(m["turtles"]) - lost, lost), lost


def main(m, w, h, title, keyboard=False, search="", needs=None, f=None, reasons=None, show_fleet=True, found=True):
    """Job blocks in as many columns of 16 cells or more as fit (at most 36 wide), split by a dim rule;
    the lowest row of blocks gives up its spare row, then its facts, when rows run out."""
    cv = Canvas(w, h, title)
    header(cv, w, h, m["time"], needs)
    f = PK.facts(m) if f is None else f
    reasons = reasons or {}
    blocks = ["mining", "lumber"] + (["shop"] if keyboard else [])
    top = 3
    if show_fleet and m["turtles"] and h >= 12:
        text, lost = fleet(m)
        lw = min(w - 2, 36)
        leader(cv, 2, 3, lw, "turtles", text)
        if lost:
            cv.put(2 + lw - len("%d lost" % lost), 3, "%d lost" % lost, "e")
        top = 5
    n = len(blocks)
    cw = (w - 2 - (n - 1) * 3) // n
    while n > 1 and cw < 16:
        n -= 1
        cw = (w - 2 - (n - 1) * 3) // n
    cw = min(cw, 36)
    grid = [dict(mode=0, roles=blocks[i:i + n]) for i in range(0, len(blocks), n)]

    def mode(row, role):
        return MODES[row["mode"]] if f.get(role) is not None else "compact"

    def rows(row):
        return max(6 if r == "shop" else PK.job_rows(mode(row, r), reasons.get(r)) for r in row["roles"])

    def total():
        return sum(rows(row) + 1 for row in grid) - 1

    r = len(grid) - 1
    while r >= 0 and total() > h - 1 - top:
        if grid[r]["mode"] < 2:
            grid[r]["mode"] += 1
        else:
            r -= 1
    y = top
    for row in grid:
        rh = rows(row)
        if y + rh - 1 > h - 2:
            break
        for i, role in enumerate(row["roles"]):
            x = 2 + i * (cw + 3)
            if i > 0:
                for j in range(y, y + rh):
                    cv.put(x - 2, j, "|", "c")
            if role == "shop":
                shop_block(cv, x, y, cw, search, found=found)
            else:
                PK.job(cv, x, y, cw, role, f.get(role), mode(row, role), reasons.get(role))
        y += rh + 1
    nav(cv, h, [("ALERTS", "alerts", "plain"), ("PAIR", "pair", "plain")])
    return cv


def alerts(texts, w, h, title, page=0):
    """The pocket's alert pages: each alert wraps to two rows, then a blank row."""
    cv = Canvas(w, h, title)
    header(cv, w, h)
    section(cv, 2, 3, w - 2, "ALERTS", len(texts), "e" if texts else "8")
    pages = PK.alert_pages([dict(text=t) for t in texts], w, h)
    page %= max(1, len(pages))
    if not texts:
        cv.put(2, 4, "no alerts", "8")
    y = 4
    for rows in (pages[page] if pages else []):
        cv.put(2, y, "!", "e")
        for text, fg in rows:
            cv.put(4, y, text, fg)
            y += 1
        y += 1
    pager(cv, h, page, max(1, len(pages)), "alert-prev", "alert-next")
    back(cv, h, "panel-back")
    return cv


def code_fit(w, h):
    """Line digits as large as fit between the header and the chips; None when they do not fit."""
    dh = min(11, h - 7)
    dh -= 1 - dh % 2
    gap = 2 if w >= 40 else 1
    dw = min(9, (w - 2 - 5 * gap) // 6)
    dh = min(dh, 2 * dw + 1)
    return dict(dw=dw, dh=dh, gap=gap) if dh >= 5 and dw >= 3 else None


def pair(m, w, h, title, code=None, left=0, enroll=None):
    cv = Canvas(w, h, title)
    header(cv, w, h)
    fit = code_fit(w, h)
    g = dict(y=3, ty=4, list=h - 2, new=h, back=h)
    if fit:
        g.update(fit)
        g["ty"] = 3 + fit["dh"] + (1 if 4 + fit["dh"] < h - 2 else 0)
    if w < 19:
        g["list"], g["new"] = h - 4, h - 2
    return PK.pair(m, w, h, code, left, enroll=enroll, g=g, cv=cv)


def age(seen):
    if seen is None:
        return "-"
    s = seen // 1000
    return "%ds" % s if s < 60 else "%dm" % (s // 60)


def paired(w, h, title, machines=True, me=None, confirm=None, page=0, tabs=None, failed=False):
    """The paired keys: one row each from 40 columns, else the age and the chip on a second row.
    machines False draws them as a server that has seen none of them (tests/so/forget.lua)."""
    cv = Canvas(w, h, title)
    if tabs is None:
        header(cv, w, h)
    else:
        PK.tabs(cv, "pair", tabs)
    rows = SC["paired"]
    me = SC["self"] if me is None else me
    step = 1 if w >= 40 else 2
    capacity = max(1, (h - 5) // step)
    pages = max(1, -(-len(rows) // capacity))
    page %= pages
    section(cv, 2, 3, w - 2, "PAIRED", "save failed" if failed else len(rows), "e" if failed else "8")
    for i, row in enumerate(rows[page * capacity:(page + 1) * capacity]):
        y, ident = 4 + i * step, "#%d" % row["id"]
        kind = (row["kind"] or "") if machines else ""
        when = age(row["seen"]) if machines else "-"
        fp = fingerprint(row["id"])
        cv.put(2, y, ident, "0")
        if step == 1:
            if len(kind) <= 9:
                cv.put(8, y, kind, "8")
            cv.put(18, y, fp, "0")
            cv.put(24, y, when, "8")
        else:
            if 2 + len(ident) + len(kind) <= w - 6:
                cv.put(3 + len(ident), y, kind, "8")
            cv.put(w - 4, y, fp, "0")
            cv.put(2, y + 1, when, "8")
        if row["id"] != me:
            armed = row["id"] == confirm
            act(cv, y + step - 1, "CONFIRM" if armed else "FORGET",
                "forget-confirm:%d:1" % row["id"] if armed else "forget:%d" % row["id"], "e" if armed else "0")
    pager(cv, h, page, pages, "paired-prev", "paired-next")
    back(cv, h, "paired-back")
    return cv


def enroll(w, h, title, tabs=None, failed=False):
    """The enroll window: token, joined count, then one row per request with OK and NO, or two rows
    when an id and kind do not fit beside the fingerprint and chips."""
    cv = Canvas(w, h, title)
    if tabs is None:
        header(cv, w, h)
    else:
        PK.tabs(cv, "pair", tabs)
    e = SC["enroll"]
    secs = -(-e["left"] // 1000)
    section(cv, 2, 3, w - 2, "ENROLL", "%d:%02d" % (secs // 60, secs % 60), "0")
    token, y = e["token"], 4
    if len(token) <= w - 2:
        cv.put(2, 4, token, "0")
    else:
        parts = token.split("-")
        cut = len("-".join(parts[:3]))
        cv.put(2, 4, token[:cut], "0")
        cv.put(2, 5, token[cut + 1:], "0")
        y = 5
    leader(cv, 2, y + 1, w - 2, "joined", "%d/%d" % (e["joined"], e["cap"]))
    rows = SC["pending"]
    section(cv, 2, y + 2, w - 2, "PENDING", "save failed" if failed else len(rows), "e" if failed else "8")
    two = any(len("#%d %s" % (r["id"], r["kind"])) > w - 17 for r in rows)
    foot = h - 1 if w < 23 else h
    shown, ry = [], y + 3
    for row in rows:
        cy, fx, ident = (ry + 1 if two else ry), (w - 4 if two else w - 14), "#%d" % row["id"]
        if cy <= foot - 2:
            shown.append("%d-%d" % (row["id"], row["n"]))
            cv.put(2, ry, ident, "0")
            if 2 + len(ident) + len(row["kind"]) <= fx - 2:
                cv.put(3 + len(ident), ry, row["kind"], "8")
            cv.put(fx, ry, row["fp"], "0")
            act(cv, cy, "OK", "enroll-ok:%d:%d" % (row["id"], row["n"]), "9", w - 6)
            act(cv, cy, "NO", "enroll-no:%d:%d" % (row["id"], row["n"]), "e")
        ry = cy + 1
    chip(cv, 2, foot, "APPROVE ALL", "enroll-all:" + ".".join(shown), "primary")
    chip(cv, w - 7, h, "CLOSE", "enroll-close")
    return cv


def alert_texts():
    """The panel's ALERTS list for the scene: the state alert."""
    return [PK.SYS["alert"]["text"]]


def code():
    return dict(code=PK.SYS["code"], left=PK.SYS["left"])


# A long item name on the 26-column pocket: the count and status keep their room.
LONG = [("minecraft:polished_deepslate_stairs", 120), ("minecraft:oak_stairs", 40)]

FIXTURES = [
    ("panel-M", lambda: main(ST.model(), 57, 24, "Panel, room monitor 57x24", needs=SC["needs"])),
    ("panel-W", lambda: main(ST.model(), 100, 38, "Panel, wall 100x38", needs=SC["needs"])),
    ("panel-L", lambda: main(ST.model(), 39, 19, "Panel, wall monitor 39x19", needs=SC["needs"])),
    ("panel-S", lambda: main(ST.model(), 29, 12, "Panel, small monitor 29x12", needs=SC["needs"])),
    ("panel-XS", lambda: main(ST.model(), 15, 10, "Panel, smallest monitor 15x10", needs=SC["needs"])),
    ("panel-P", lambda: main(ST.model(), 26, 20, "Panel role on a pocket 26x20, quick order",
                             keyboard=True, search=PK.SYS["search"])),
    ("panelqty-P", lambda: main(ST.model(), 26, 20, "Panel role on a pocket 26x20, a typed quantity of 37",
                                keyboard=True, search="iron 37")),
    ("panelnoroom-P", lambda: main(ST.model(), 26, 20, "Panel role on a pocket 26x20 without a storage room",
                                   keyboard=True, search=PK.SYS["search"], found=False)),
    ("pocket-shoplong-P", lambda: PK.shop(ST.model(), search="stairs", stock=LONG,
                                          sent=(PK.order_line(1, "POLISHED DEEPSLATE STAIRS", "delivered", 24), "d"),
                                          reply="Delivered 1 Polished Deepslate Stairs")),
    ("panelalerts-M", lambda: alerts(alert_texts(), 57, 24, "Panel ALERTS without the health module")),
    ("panelpair-P", lambda: pair(ST.model(), 26, 20, "Panel PAIR 26x20, no code")),
    ("panelcode-P", lambda: pair(ST.model(), 26, 20, "Panel PAIR 26x20 with a code", **code())),
    ("panelpair-S", lambda: pair(ST.model(), 29, 12, "Panel PAIR 29x12, no code")),
    ("panelcode-S", lambda: pair(ST.model(), 29, 12, "Panel PAIR 29x12 with a code", **code())),
    ("panelcode-M", lambda: pair(ST.model(), 57, 24, "Panel PAIR 57x24 with a code, enroll open",
                                 enroll=True, **code())),
    ("paired-P", lambda: paired(26, 20, "Pocket PAIRED, keys only", machines=False, tabs=False)),
    ("paired-S", lambda: paired(29, 12, "Panel PAIRED 29x12, keys only", machines=False)),
    ("paired-M", lambda: paired(57, 24, "Panel PAIRED 57x24, FORGET armed on #4", confirm=SC["confirm"])),
    ("enroll-P", lambda: enroll(26, 20, "Pocket ENROLL", tabs=False)),
    ("enroll-S", lambda: enroll(29, 12, "Panel ENROLL 29x12")),
    ("enroll-M", lambda: enroll(57, 24, "Panel ENROLL 57x24")),
]
