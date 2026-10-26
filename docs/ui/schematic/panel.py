"""The panel role in route A: the main page, ALERTS, PAIR, PAIRED and ENROLL at every size, and the
pocket's PAIRED and ENROLL pages; the twin of the panel pages in so-mod-panel.lua. The data comes from
the status model (status.py), tests/ui/system-scene.txt and tests/ui/panel-scene.txt.
"""
import hashlib

from cc import Canvas
from kit import actions, chip, flag, leader, progress, rule, section, tone
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


def shop_block(cv, x, y, cw, search, loaded=True, sent=None, reply=None, found=True, again=None, stock=None, saved=None):
    """The search, its best match with the stock, 1, 16 and 64 (one ORDER n for a typed trailing count),
    then the last order (sent: line, colour) and the shop's reply. Without a storage room (found False)
    the chips are muted. again is the last order's (count, id), which a tap on its line sends again."""
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
    exact = [i for i in PK.matches(search, 99, stock) if i["name"] == search]
    best = exact or ([i for i in PK.matches(search, 1, stock) if i["count"] > 0] if search else [])
    if not search and saved and saved.get("pins"):
        best = [i for i in PK.matches("", 4096, stock) if i["name"] == saved["pins"][0]][:1]
    best = [PK.tag(i, PK.shared(stock)) for i in best]
    if loaded and not live:
        cv.put(x, y + 2, "storage room not found"[:cw], "e")
    elif loaded and best:
        leader(cv, x, y + 2, cw, best[0]["label"], str(best[0]["count"]), "1" if best[0]["count"] < (PK.saved_minimum(saved, best[0]) if saved is not None else 10) else "0")
    elif loaded and search:
        cv.put(x, y + 2, "no match", "8")
    target = ":" + best[0]["name"] if not search and saved and saved.get("pins") and best else ""
    third = (cw - 2) // 3
    if qty is not None:
        if live:
            chip(cv, x, y + 3, "ORDER %d" % qty, "order:%d%s" % (qty, target), "plain", cw)
        else:
            PK.dead(cv, x, y + 3, "ORDER %d" % qty, cw)
    for i, n in enumerate(() if qty is not None else (1, 16, 64)):
        cx = x + i * (third + 1)
        if live:
            chip(cv, cx, y + 3, str(n), "order:%d%s" % (n, target), "plain", third)
        else:
            PK.dead(cv, cx, y + 3, str(n), third)
    if loaded and best and saved is not None:
        PK.saved_controls(cv, saved, best[0], x, y + 4, cw, True)
    elif loaded and saved is not None:
        PK.saved_nav(cv, saved, None, x, y + 4, cw)
    offset = 2 if saved is not None else 0
    if loaded and sent:
        cv.put(x, y + 4 + offset, sent[0][:cw], sent[1])
        if live and again:
            cv.hit("order:%d:%s" % again, x, y + 4 + offset, cw, 1)
    if loaded and reply:
        cv.put(x, y + 5 + offset, reply[:cw], "8")


def build_rows(mode, reason):
    """P.buildRows: the section, placements and the builder turtle, then its hold as a flag."""
    return (1 if mode == "compact" else 3) + (1 if reason else 0)


def build_block(cv, x, y, cw, f, mode, reason):
    """P.buildBlock: build.facts() as the BUILD block, without chips."""
    word = PK.state_word(str(f.get("state", "-")), cw - 8)
    section(cv, x, y, cw, "BUILD", word, tone(word))
    if mode != "compact":
        frac = "%d/%d" % (f.get("done", 0), f.get("total", 0))
        progress(cv, x, y + 1, min(10, cw - len(frac) - 1), f.get("done", 0), f.get("total", 0))
        tid = f.get("turtleId")
        leader(cv, x, y + 2, cw, "turtle", "#%d" % tid if tid is not None else "-", "0" if tid is not None else "8")
    if reason:
        flag(cv, x, y + build_rows(mode, reason) - 1, cw, (PK.wrap(reason, cw - 2) or [""])[0])


def fleet(m):
    lost = sum(1 for t in m["turtles"] if t["lost"])
    return "%d ok · %d lost" % (len(m["turtles"]) - lost, lost), lost


def main(m, w, h, title, keyboard=False, search="", needs=None, f=None, reasons=None, show_fleet=True, found=True,
         fuel=None, stock=None, sent=None, again=None, saved=None, build=None, page=0, shop=False):
    """Job blocks in as many columns of 16 cells or more as fit (at most 36 wide), split by a dim rule;
    the lowest row of blocks gives up its spare row, then its facts, when rows run out. fuel is the fuel
    auto row (PK.fuel_value) under the turtles; "N lost" (`lost`) opens the panel's own ALERTS. build is
    build.facts() with the hold text as alert, drawn as a BUILD block after LUMBER. Rows of blocks share
    pages when even their compact forms do not fit; page picks one and the pager takes row h-1. shop adds the SHOP chip of
    storageDeliveries."""
    cv = Canvas(w, h, title)
    header(cv, w, h, m["time"], needs)
    f = PK.facts(m) if f is None else f
    reasons = dict(reasons or {})
    blocks = ["mining", "lumber"] + (["build"] if build is not None else []) + (["shop"] if keyboard else [])
    if build is not None:
        f = dict(f, build=build)
        reasons["build"] = build.get("alert")
    top, lw = 3, min(w - 2, 36)
    if show_fleet and m["turtles"] and h >= 12:
        text, lost = fleet(m)
        leader(cv, 2, 3, lw, "turtles", text)
        if lost:
            cv.put(2 + lw - len("%d lost" % lost), 3, "%d lost" % lost, "e")
            cv.hit("lost", 2 + lw - len("%d lost" % lost), 3, len("%d lost" % lost), 1)
        top = 4
    if fuel and h >= 12:
        leader(cv, 2, top, lw, "fuel auto", fuel[0], fuel[1])
        top += 1
    if top > 3:
        top += 1
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
        return max((8 if saved is not None else 6) if r == "shop" else build_rows(mode(row, r), reasons.get(r)) if r == "build"
                   else PK.job_rows(mode(row, r), reasons.get(r)) for r in row["roles"])

    def total():
        return sum(rows(row) + 1 for row in grid) - 1

    pages, used = [[]], -1
    for row in grid:
        row["mode"] = 2
        rh = rows(row)
        row["mode"] = 0
        if pages[-1] and used + rh + 1 > h - 1 - top:
            pages.append([])
            used = -1
        pages[-1].append(row)
        used += rh + 1
    page %= len(pages)
    grid = pages[page]
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
                shop_block(cv, x, y, cw, search, found=found, stock=stock, sent=sent, again=again, saved=saved)
            elif role == "build":
                build_block(cv, x, y, cw, build, mode(row, role), reasons.get(role))
            else:
                PK.job(cv, x, y, cw, role, f.get(role), mode(row, role), reasons.get(role))
        y += rh + 1
    if len(pages) > 1:
        pager(cv, h - 1, page, len(pages), "jobs-prev", "jobs-next")
    nav(cv, h, [("ALERTS", "alerts", "plain"), ("PAIR", "pair", "plain")] + ([("SHOP", "shop", "plain")] if shop else []))
    return cv


# The delivery chest of the SHOP fixtures (a storage drop point) and its "to" row.
CHEST = dict(id="workshop", dim=0, x=12, y=64, z=-3, side="front", kind="storage")
CHEST_ROW = ("workshop 12 64 -3", "0", True, "workshop")
# Delivery status rows: (head, label, colour, detail, RETRY id).
DELIVERY = {
    "ordered": ("ORDERED 16 ", "IRON INGOT", "1", "pickup", None),
    "held": ("HELD 16 ", "IRON INGOT", "e", "delivery chest full or transfer failed", "delivery-1"),
    "delivered": ("DELIVERED 16 ", "IRON INGOT", "d", "workshop", None),
    "refused": ("REFUSED 16 ", "IRON INGOT", "e", "room support missing", None),
    "busy": ("BUSY ordinary quarantined", "", "1", "order timed out", None),
}


# The size-coverage states of the panel's SHOP page and the pocket's delivery mode.
SHOP_STATES = {
    "scene": {}, "none": dict(to=("no chest", "8", True), chest=None),
    "ordered": dict(live=False, status=DELIVERY["ordered"]), "held": dict(live=False, status=DELIVERY["held"]),
    "busy": dict(live=False, status=DELIVERY["busy"]),
}
POCKET_STATES = {
    "deliver": dict(to=CHEST_ROW, deliver=dict(chest="workshop", token="1", live=True), status=DELIVERY["delivered"]),
    "refused": dict(to=CHEST_ROW, deliver=dict(chest="workshop", token="1", live=True), status=DELIVERY["refused"]),
    "room": dict(to=("room output", "8", True)),
}


def shop_page(w, h, title="", to=CHEST_ROW, chest="workshop", live=True, status=None, keyboard=False, search="",
              stock=None):
    """The panel's SHOP page (storageDeliveries on): the pocket's SHOP list under the PANEL header,
    deliveries only. chest is the chest a delivery may go to now (None: none picked, moved or removed);
    live is False while the room output is busy."""
    cv = Canvas(w, h, title)
    header(cv, w, h)
    return PK.shop({"flags": []}, w, h, search=search, stock=stock, to=to, cv=cv, keyboard=keyboard,
                   deliver=dict(chest=chest, token="1", live=live), status=status)


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


def pair(m, w, h, title, code=None, left=0, enroll=None, refused=None, switch=None):
    """refused is a refused EXTEND's reason, drawn after ENROLL once the ENROLL page has closed. switch is
    the saved enroll switch (SO.enroll.enabled()) as its ON or OFF chip, None without setEnabled."""
    cv = Canvas(w, h, title)
    header(cv, w, h)
    fit = code_fit(w, h)
    g = dict(y=3, ty=4, list=h - 2, new=h, back=h)
    if fit:
        g.update(fit)
        g["ty"] = 3 + fit["dh"] + (1 if 4 + fit["dh"] < h - 2 else 0)
    if w < 19:
        g["list"], g["new"] = h - 4, h - 2
    cv = PK.pair(m, w, h, code, left, enroll=enroll, g=g, cv=cv)
    x = 20
    if switch is not None:
        x = chip(cv, x, g["list"], "ON" if switch else "OFF", "enroll-off" if switch else "enroll-on",
                 "primary" if switch else "plain") + 1
    if refused:
        cv.put(x, g["list"], refused[:max(0, w - x)], "e")
    return cv


def age(seen):
    if seen is None:
        return "-"
    s = seen // 1000
    return "%ds" % s if s < 60 else "%dm" % (s // 60)


def paired(w, h, title, machines=True, me=None, confirm=None, page=0, tabs=None, failed=False, impact=None,
           stale=(), updates=False, updating=(), settings=False, note=None):
    """The paired keys: one row each from 40 columns, else the age and the chip on a second row.
    machines False draws them as a server that has seen none of them (tests/so/forget.lua). impact is
    SO.forgetImpact's text for the armed row; stale ids run another revision (amber id, and UPDATE with
    updates, or "updating" for ids in updating); settings makes turtle rows open WORKER."""
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
    text = "save failed" if failed else note if note else str(len(rows))
    section(cv, 2, 3, w - 2, "PAIRED", text[:max(0, w - 11)], "e" if failed or note else "8")
    for i, row in enumerate(rows[page * capacity:(page + 1) * capacity]):
        y, ident = 4 + i * step, "#%d" % row["id"]
        kind = (row["kind"] or "") if machines else ""
        when = age(row["seen"]) if machines else "-"
        fp = fingerprint(row["id"])
        old = row["id"] in stale and row["kind"] == "turtle"
        armed = row["id"] != me and row["id"] == confirm
        said = impact if armed else None
        ay, ax = y + step - 1, 24 if step == 1 else 2
        if said and step == 1 and ax + len(said) > w - 10:
            ax = 18
        cv.put(2, y, ident, "1" if old else "0")
        if step == 1:
            if len(kind) <= 9:
                cv.put(8, y, kind, "8")
            if ax > 18:
                cv.put(18, y, fp, "0")
        else:
            if 2 + len(ident) + len(kind) <= w - 6:
                cv.put(3 + len(ident), y, kind, "8")
            cv.put(w - 4, y, fp, "0")
        if said:
            cv.put(ax, ay, said[:max(0, w - 10 - ax)], "e")
        else:
            cv.put(ax, ay, when, "8")
        if settings and row["kind"] == "turtle" and row["id"] != me:
            cv.hit("worker:%d" % row["id"], 2, y, 15 if step == 1 else w - 7, 1)
        if row["id"] != me:
            act(cv, ay, "CONFIRM" if armed else "FORGET",
                "forget-confirm:%d:1" % row["id"] if armed else "forget:%d" % row["id"], "e" if armed else "0")
        if updates and old and not armed and row["id"] != me and w - 18 > ax + len(when):
            if row["id"] in updating:
                cv.put(w - 18, ay, "updating", "1")
            else:
                act(cv, ay, "UPDATE", "update:%d" % row["id"], "9", w - 11)
    pager(cv, h, page, pages, "paired-prev", "paired-next")
    back(cv, h, "paired-back")
    return cv


DIMS = (("WORLD", "minecraft:overworld"), ("NETHER", "minecraft:the_nether"), ("END", "minecraft:the_end"))


def worker(w, h, title, ident, settings=None, block=None, note=None, tabs=None):
    """P.workerFrame: one turtle's confirmed dimension and tool swap, then its controls. settings is
    lease.status().settings (dim, autoToolSwap) or None; block is why the controls are missing, "pending"
    while a request waits for its ack or a newer hello; note is a refusal or the worker's error."""
    cv = Canvas(w, h, title)
    if tabs is None:
        header(cv, w, h)
    else:
        PK.tabs(cv, "pair", tabs)
    fg = "e"
    if not note and block == "pending":
        note, fg = "pending", "1"
    section(cv, 2, 3, w - 2, "WORKER #%d" % ident, (note or "")[:max(0, w - 14)], fg)
    s = settings or {}
    dim = next((label for label, name in DIMS if s.get("dim") == name), "-")
    swap = ("on" if s.get("autoToolSwap") else "off") if settings is not None else "-"
    top = 7 if block or h >= 9 else 4
    if top == 7:
        leader(cv, 2, 4, w - 2, "dimension", dim, "8" if dim == "-" else "0")
        leader(cv, 2, 5, w - 2, "tool swap", swap, "8" if swap == "-" else "0")
    if block and block != "pending":
        cv.put(2, min(7, h - 1), block[:w - 2], "8")
    elif not block:
        nav(cv, top, [(label, "worker-dim:" + label.lower(), "primary" if s.get("dim") == name else "plain")
                    for label, name in DIMS])
        on = bool(s.get("autoToolSwap"))
        nav(cv, top + 1, [("SWAP ON", "worker-swap:on", "primary" if on else "plain"),
                    ("SWAP OFF", "worker-swap:off", "plain" if on else "primary")])
    back(cv, h, "worker-back")
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
    section(cv, 2, 3, w - 11, "ENROLL", "%d:%02d" % (secs // 60, secs % 60), "0")
    chip(cv, w - 8, 3, "EXTEND", "enroll-extend")
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


def alert_texts(m):
    """The panel's ALERTS list for the scene: one row per lost turtle, then the state alert."""
    return [f["text"] for f in m["flags"] if f["text"].endswith(" lost")] + [PK.SYS["alert"]["text"]]


def code():
    return dict(code=PK.SYS["code"], left=PK.SYS["left"])


# build.facts() for a builder held for fuel at 37 of 120 placements, on turtle #6.
BUILD = dict(state="held", done=37, total=120, turtleId=6, alert="out of fuel")
# A long item name on the 26-column pocket: the count and status keep their room.
LONG = [("minecraft:polished_deepslate_stairs", 120), ("minecraft:oak_stairs", 40)]
# shop.fuelConfig() after a fuel order timed out, and with one order sent 45 seconds ago.
TIMED_OUT = dict(auto=True, alert=dict(reason="fuel order timed out"))
WAITING = dict(auto=True, waiting=dict(at=0))
# Two stocked ids that share the label COPPER INGOT.
COPPER = [("minecraft:copper_ingot", 200), ("create:copper_ingot", 30)]

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
    ("pocket-shopsaved-P", lambda: PK.shop({"flags": []}, search="iron",
         stock=[("minecraft:iron_ingot", 24)], saved={})),
    ("pocket-shopsaved-low-P", lambda: PK.shop({"flags": []}, search="iron",
         stock=[("minecraft:iron_ingot", 24)], show="low",
         saved={"minimums": {"minecraft:iron_ingot": 32}, "revision": 1})),
    ("pocket-shopminimum-P", lambda: PK.saved_editor()),
    ("pocket-shoppin-P", lambda: PK.shop({"flags": []}, search="", stock=[("minecraft:iron_ingot", 24)],
         saved={"pins": ["minecraft:iron_ingot"], "pinRevision": 1})),
    ("panelnoroom-P", lambda: main(ST.model(), 26, 20, "Panel role on a pocket 26x20 without a storage room",
                                   keyboard=True, search=PK.SYS["search"], found=False)),
    ("pocket-shoplong-P", lambda: PK.shop(ST.model(), search="stairs", stock=LONG,
                                          sent=(PK.order_line(1, "POLISHED DEEPSLATE STAIRS", "delivered", 24), "d"),
                                          reply="Delivered 1 Polished Deepslate Stairs",
                                          again=(1, "minecraft:polished_deepslate_stairs"))),
    ("panelfuel-M", lambda: main(ST.model(), 57, 24, "Panel 57x24, a fuel order timed out",
                                 fuel=PK.fuel_value(TIMED_OUT, 0, 25))),
    ("pocket-jobsfuel-P", lambda: PK.jobs(ST.model(), title="Pocket JOBS, a fuel order waiting 45s",
                                          fuel=PK.fuel_value(WAITING, 45000, 13))),
    ("paneldupe-P", lambda: main(ST.model(), 26, 20, "Panel role on a pocket 26x20, two copper ingots",
                                 keyboard=True, search="create:copper", stock=COPPER,
                                 sent=(PK.order_line(16, "CREATE:COPPER INGOT", "sent", 24), "d"),
                                 again=(16, "create:copper_ingot"))),
    ("panelalerts-M", lambda: alerts(alert_texts(ST.model()), 57, 24, "Panel ALERTS without the health module")),
    ("panelpair-P", lambda: pair(ST.model(), 26, 20, "Panel PAIR 26x20, no code")),
    ("panelcode-P", lambda: pair(ST.model(), 26, 20, "Panel PAIR 26x20 with a code", **code())),
    ("panelpair-S", lambda: pair(ST.model(), 29, 12, "Panel PAIR 29x12, no code")),
    ("panelcode-S", lambda: pair(ST.model(), 29, 12, "Panel PAIR 29x12 with a code", **code())),
    ("panelcode-M", lambda: pair(ST.model(), 57, 24, "Panel PAIR 57x24 with a code, enroll open",
                                 enroll=True, **code())),
    ("panelrefused-S", lambda: pair(ST.model(), 29, 12, "Panel PAIR 29x12, EXTEND refused as the window closed",
                                    enroll=True, refused="closed")),
    ("paired-P", lambda: paired(26, 20, "Pocket PAIRED, keys only", machines=False, tabs=False)),
    ("paired-S", lambda: paired(29, 12, "Panel PAIRED 29x12, keys only", machines=False)),
    ("paired-M", lambda: paired(57, 24, "Panel PAIRED 57x24, FORGET armed on #4", confirm=SC["confirm"])),
    ("enroll-P", lambda: enroll(26, 20, "Pocket ENROLL", tabs=False)),
    ("enroll-S", lambda: enroll(29, 12, "Panel ENROLL 29x12")),
    ("enroll-M", lambda: enroll(57, 24, "Panel ENROLL 57x24")),
    ("panelbuild-M", lambda: main(ST.model(), 57, 24, "Panel 57x24 with the builder held for fuel", needs=SC["needs"],
                                  build=BUILD)),
    ("panelbuild-S", lambda: main(ST.model(), 29, 12, "Panel 29x12 with the builder, page 1", build=BUILD)),
    ("panelbuild2-S", lambda: main(ST.model(), 29, 12, "Panel 29x12 with the builder, page 2", build=BUILD, page=1)),
    ("panelbuild-P", lambda: main(ST.model(), 26, 20, "Panel role on a pocket 26x20 with the builder and fuel, page 1",
                                  keyboard=True, search=PK.SYS["search"], build=BUILD, fuel=PK.fuel_value(WAITING, 45000, 13))),
    ("panelbuild2-P", lambda: main(ST.model(), 26, 20, "Panel role on a pocket 26x20 with the builder and fuel, page 2",
                                   keyboard=True, search=PK.SYS["search"], build=BUILD, fuel=PK.fuel_value(WAITING, 45000, 13),
                                   page=1)),
    ("panelenroll-S", lambda: pair(ST.model(), 29, 12, "Panel PAIR 29x12, enrollment on", enroll=True, switch=True)),
    ("panelenrolloff-S", lambda: pair(ST.model(), 29, 12, "Panel PAIR 29x12, enrollment off", enroll=False,
                                      switch=False)),
    ("pairedupdate-M", lambda: paired(57, 24, "Panel PAIRED 57x24, #4 and #6 stale, #6 updating", stale=(4, 6),
                                      updates=True, updating=(6,), settings=True)),
    ("pairedimpact-P", lambda: paired(26, 20, "Pocket PAIRED, FORGET armed on #4 names its job", tabs=False,
                                      confirm=SC["confirm"], impact="parks 1 job")),
    ("pairedimpact-M", lambda: paired(57, 24, "Panel PAIRED 57x24, a long impact takes the fingerprint",
                                      confirm=SC["confirm"], impact="parks 1 job; holds 1 scan")),
    ("worker-P", lambda: worker(26, 20, "Pocket WORKER #4 in the Nether", 4, tabs=False,
                                settings={"dim": "minecraft:the_nether", "autoToolSwap": False})),
    ("worker-S", lambda: worker(29, 12, "Panel WORKER #4, a change waiting for its ack", 4,
                                settings={"dim": "minecraft:the_nether", "autoToolSwap": False}, block="pending")),
    ("workerbusy-S", lambda: worker(29, 12, "Panel WORKER #5 on a job", 5,
                                    settings={"dim": "minecraft:overworld", "autoToolSwap": True}, block="worker busy")),
    ("panelshopnav-M", lambda: main(ST.model(), 57, 24, "Panel 57x24 with deliveries on: SHOP", needs=SC["needs"],
                                    shop=True)),
    ("panelshop-M", lambda: shop_page(57, 24, "Panel SHOP 57x24, a chest picked")),
    ("panelshop-S", lambda: shop_page(29, 12, "Panel SHOP 29x12, a chest picked")),
    ("panelshopnone-M", lambda: shop_page(57, 24, "Panel SHOP 57x24, no chest picked", to=("no chest", "8", True),
                                          chest=None)),
    ("panelshopordered-M", lambda: shop_page(57, 24, "Panel SHOP 57x24, ORDERED", live=False,
                                             status=DELIVERY["ordered"])),
    ("panelshopheld-M", lambda: shop_page(57, 24, "Panel SHOP 57x24, a held delivery", live=False,
                                          status=DELIVERY["held"])),
    ("panelshopbusy-L", lambda: shop_page(39, 19, "Panel SHOP 39x19, the room output busy", live=False,
                                          status=DELIVERY["busy"])),
    ("pocket-shopdeliver-P", lambda: PK.shop(ST.model(), title="Pocket SHOP, DELIVERED to a chest", to=CHEST_ROW,
                                             deliver=dict(chest="workshop", token="1", live=True),
                                             status=DELIVERY["delivered"])),
    ("pocket-shoprefused-P", lambda: PK.shop(ST.model(), title="Pocket SHOP, a refused delivery", to=CHEST_ROW,
                                             deliver=dict(chest="workshop", token="1", live=True),
                                             status=DELIVERY["refused"])),
    ("pocket-shoproom-P", lambda: PK.shop(ST.model(), title="Pocket SHOP with deliveries on, to the room output",
                                          to=("room output", "8", True))),
]
