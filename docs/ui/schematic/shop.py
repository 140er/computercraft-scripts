"""The shop in route A at every size; the twin of the layout in so-mod-shop.lua.

The stock comes from tests/ui/shop-stock.tsv, which tests/ui/ui2c.lua feeds to the real module. Each
fixture is a page reached by the taps in PAGES; the Lua test makes the same taps and compares cells.
"""
import math
import os
import re

from cc import Canvas
from kit import bar, chip, leader, rule, section

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
CATS = [("ores", "ore raw ingot nugget block gem dust"), ("wood", "log planks sapling crafted"),
        ("stone", "stone earth build"), ("plants", "leaves seeds flowers plants"), ("food", "crops meat meals"),
        ("tools", "tools weapons armour"), ("redstone", "dust logic motion"), ("mobs", "hostile passive"),
        ("mods", ""), ("other", "")]
TABS = ["items", "low", "find"]
KEYS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
MARK = {"sent": "d", "delivered": "8", "failed": "e"}
NOW = "21:14"
# Items a page holds at most, so the biggest walls stay under the frame budget. The Lua screen
# also redraws with 8 fewer at a time while a frame passes 15000 bytes; no fixture needs that.
MOST = 32


# ---------------------------------------------------------------- stock

def stock():
    """Items, recent orders and recipes from the scene, the way the Lua test loads them."""
    data = {"items": [], "orders": [], "recipes": {}}
    with open(os.path.join(ROOT, "tests", "ui", "shop-stock.tsv")) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if line.startswith("#") or not p[0]:
                continue
            if p[0] == "order":
                data["orders"].append(dict(hm=p[2], n=int(p[3]), status=p[4]))
            elif p[0] == "recipe":
                data["recipes"][p[1]] = int(p[2])
            else:
                samples = [int(v) for v in p[2].split(",")]
                if len(samples) == 1:
                    samples = samples * 59 + [int(p[1])]
                cat, sub = p[4].split("/")
                data["items"].append(dict(name=p[0], count=int(p[1]), samples=samples, stack=int(p[3]),
                                          cat=cat, sub=sub))
    return data


def label(name):
    path = name.split(":", 1)[1] if ":" in name else name
    return " ".join(w[:1].upper() + w[1:] for w in path.split("_"))


def short(n):
    return "%dk" % (n // 1000) if n >= 10000 else str(n)


def items(data):
    out = []
    for it in data["items"]:
        s = it["samples"]
        delta = it["count"] - s[0]
        rate = math.floor(abs(delta) * 60 / max(1, len(s) - 1) + 0.5)
        state = "empty" if it["count"] == 0 else "low" if it["count"] < min(16, it["stack"]) else "ok"
        out.append(dict(it, label=label(it["name"]), rate=-rate if delta < 0 else rate, state=state))
    return out


SORTS = {
    "count": lambda i: (-i["count"], i["name"]),
    "name": lambda i: (i["label"].lower(), i["name"]),
    "trend": lambda i: (-abs(i["rate"]), i["name"]),
}


def view(**kw):
    v = dict(tab="items", cat="all", sub="all", low="all", sort="count", page=1, search="", keys=False,
             pick=None, selected=None)
    v.update(kw)
    return v


def gather(data, v, recent=()):
    m = dict(found=True, stale=False, time=NOW, all=items(data), items=[], recipes=data["recipes"],
             recent=list(recent))
    for it in m["all"]:
        if v["tab"] == "items":
            keep = (v["cat"] == "all" or it["cat"] == v["cat"]) and (v["sub"] == "all" or it["sub"] == v["sub"])
        elif v["tab"] == "low":
            keep = it["state"] != "ok" and (v["low"] == "all" or it["state"] == v["low"])
        else:
            q = re.sub(r"\s+", "_", v["search"].lower())
            keep = q in it["name"].lower() or q in re.sub(r"\s+", "_", it["label"].lower())
        if keep:
            m["items"].append(it)
        if it["name"] == v["selected"]:
            m["selected"] = it
    m["items"].sort(key=SORTS[v["sort"]])
    return m


def subs(v, m):
    """Sub chips of the open category: its table, or one per mod namespace by item count."""
    out = [("sub:all", "all")]
    for cat, names in CATS:
        if cat == v["cat"]:
            out += [("sub:" + s, s) for s in names.split()]
    if v["cat"] == "mods":
        counts = {}
        for it in m["all"]:
            if it["cat"] == "mods":
                counts[it["sub"]] = counts.get(it["sub"], 0) + 1
        out += [("sub:" + s, s[:10]) for s in sorted(counts, key=lambda s: (-counts[s], s))]
    return out if len(out) > 1 else None


# ---------------------------------------------------------------- pieces

def head(cv, m, v, w):
    """Header row: the kit bar when SHOP, the tabs and the right word fit, else the tabs alone.
    The time gives way first; a stale word that still does not fit moves to the footer (m["note"])."""
    word = "missing" if not m["found"] else "stale" if m["stale"] else "stock"
    rfg = "e" if not m["found"] else "1" if m["stale"] else "8"
    right = word if word == "missing" else word + " " + m["time"] if w >= 52 else m["time"] if word == "stock" else word
    if w < 31 + len(right):
        right = "" if word == "stock" else word
    if w >= 31 + len(right) or (w >= 29 and right == ""):
        bar(cv, "SHOP", TABS, v["tab"], right, rfg)
        return
    if w < 23 + len(right):
        m["note"], right = word == "stale", ""
    x = 1
    for t in TABS:
        lab = " %s " % t
        cv.put(x, 1, lab, "0", "7") if t == v["tab"] else cv.put(x, 1, lab, "8")
        cv.hit("tab:" + t, x, 1, len(lab), 1, t)
        x += len(lab) + 1
    end = w - len(right) - 1
    if right:
        cv.put(end + 1, 1, right, rfg)
    rule(cv, x, 1, end - 1)


def note(cv, m, x, y):
    if m.get("note"):
        cv.put(x, y, "stale", "1")


def flow(cv, x1, x2, y, entries, active, dry=False):
    """Chips left to right with one cell between, wrapping at x2. Returns the rows used; dry only counts."""
    x, rows = x1, 1
    for bid, lab in entries:
        if x > x1 and x + len(lab) + 1 > x2:
            x, rows = x1, rows + 1
        if dry:
            x += len(lab) + 3
        else:
            x = chip(cv, x, y + rows - 1, lab, bid, "plain" if bid == active else "off") + 1
    return rows


def sorter(cv, x, y, lw, v, trend):
    """The column head is the sort control: item, stock and /h; the active one is a chip with ▼."""
    for lab, key, left in (("item", "name", x - 1), ("stock", "count", x + lw - 8), ("/h", "trend", x + lw + 1)):
        if key == "trend" and not trend:
            continue
        if v["sort"] == key:
            chip(cv, left, y, lab + " ▼", "sort:" + key)
        else:
            lx = x if key == "name" else x + lw - 5 if key == "count" else x + lw + 2
            cv.put(lx, y, lab, "8")
            cv.hit("sort:" + key, lx, y, len(lab), 1, lab)


def row(cv, x, y, cw, it, trend, sel):
    if sel:
        cv.fill(x - 1, y, cw + 2, 1, "7")
    lw = cw - 7 if trend else cw
    fg = "8" if it["state"] == "empty" else "1" if it["state"] == "low" else "0"
    leader(cv, x, y, lw, it["label"].upper(), it["count"], fg, "0")
    if trend and it["rate"] != 0:
        up = it["rate"] > 0
        cv.put(x + lw + 2, y, ("↑" if up else "↓") + short(abs(it["rate"])), "8" if up else "1")
    cv.hit("item:" + it["name"], x, y, cw, 1, it["label"].upper())


def pages(cv, m, w, h, page, count):
    text = "%d of %d" % (page, count)
    cv.put(2, h, text, "8")
    note(cv, m, 3 + len(text), h)
    chip(cv, w - 11, h, "◄", "prev", "plain" if page > 1 else "muted", 5)
    chip(cv, w - 5, h, "►", "next", "plain" if page < count else "muted", 5)


def pane(cv, m, v, it, x, y, pw, bottom, close):
    """The item: name, facts as leaders, ORDER chips, then the recent orders."""
    tall = bottom - y + 1 >= 13
    cv.put(x, y, it["label"].upper()[:pw - (3 if close else 0)], "0")
    if close:
        cv.put(x + pw - 1, y, "×", "8")
        cv.hit("items", x + pw - 3, y, 3, 1, "×")
    y += 2 if tall else 1
    fg = "8" if it["state"] == "empty" else "1" if it["state"] == "low" else "0"
    facts = [("stock", str(it["count"]), fg)]
    if tall and it["stack"] > 1:
        full, rest = divmod(it["count"], it["stack"])
        facts.append(("stacks", str(full) + ("+%d" % rest if rest else ""), "0"))
    rate = it["rate"]
    facts.append(("last hour", ("↑" if rate > 0 else "↓") + short(abs(rate)) if rate else "0",
                  "1" if rate < 0 else "0" if rate else "8"))
    if tall and it["sub"] != it["cat"]:
        facts.append((it["cat"], it["sub"], "0"))
    if tall and m["recipes"].get(it["name"], 0) > 0:
        facts.append(("craftable", str(m["recipes"][it["name"]]), "0"))
    for lab, value, vfg in facts:
        leader(cv, x, y, pw, lab, value, vfg)
        y += 1
    y += 1 if tall else 0
    section(cv, x, y, pw, "ORDER")
    on = m["found"]
    cw, cw2 = (pw - 2) // 3, (pw - 1) // 2
    for i, n in enumerate(("1", "16", "64")):
        chip(cv, x + i * (cw + 1), y + 1, n, "order:%s:%s" % (n, it["name"]), "plain" if on else "muted", cw)
    for i, n in enumerate(("stack", "all")):
        ok = on and (n != "all" or it["count"] > 0)
        chip(cv, x + i * (cw2 + 1), y + 2, n, "order:%s:%s" % (n, it["name"]), "plain" if ok else "muted", cw2)
    y += 4 if tall else 3
    for e in m["recent"]:
        if y > bottom:
            break
        cv.put(x, y, "•", MARK.get(e["status"], "e"))
        cv.put(x + 2, y, ("%d %s" % (e["n"], e["status"]))[:pw - 8], "0")
        cv.put(x + pw - len(e["hm"]), y, e["hm"], "8")
        y += 1
    return y - 1


def picker(cv, m, v, y, w, bottom):
    """Narrow screens pick a category or sub from leader rows with item counts."""
    counts = {}
    for it in m["all"]:
        for key in ("cat:all", "cat:" + it["cat"], "sub:all" if it["cat"] == v["cat"] else None,
                    "sub:" + it["sub"] if it["cat"] == v["cat"] else None):
            counts[key] = counts.get(key, 0) + 1
    if v["pick"] == "cats":
        entries, active = [("cat:all", "all")] + [("cat:" + c, c) for c, _ in CATS], "cat:" + v["cat"]
    else:
        entries, active = subs(v, m) or [], "sub:" + v["sub"]
    n = max(1, bottom - y + 1)
    cols = max(1, min(-(-len(entries) // n), w // 14))
    cw = (w - 2 - 2 * (cols - 1)) // cols
    entries = entries[:n * cols]
    for i, (bid, lab) in enumerate(entries):
        x, ry = 2 + (i // n) * (cw + 2), y + i % n
        if bid == active:
            cv.fill(x - 1, ry, cw + 2, 1, "7")
        leader(cv, x, ry, cw, lab, counts.get(bid, 0), "0", "0")
        cv.hit(bid, x, ry, cw, 1, lab)


# ---------------------------------------------------------------- page

def layout(m, v, w, h, title="", most=MOST):
    cv = Canvas(w, h, title)
    head(cv, m, v, w)
    gap = 1 if h >= 16 else 0
    y, bottom, wide = 2 + gap, h - 1 - gap, w >= 52
    it = m.get("selected")
    if it and not wide:
        pane(cv, m, v, it, 2, y, w - 2, bottom, False)
        note(cv, m, chip(cv, 2, h, "back", "items") + 1, h)
        return cv
    if v["tab"] == "items" and wide:
        y += flow(cv, 2, w - 1, y, [("cat:all", "all")] + [("cat:" + c, c) for c, _ in CATS], "cat:" + v["cat"])
        sub = v["cat"] != "all" and subs(v, m)
        if sub and flow(cv, 2, w - 1, y, sub, None, True) > 2:
            chip(cv, 2, y + gap, v["sub"] + " ▼", "pick:subs", "on" if v["pick"] == "subs" else "plain")
            y += gap + 1
        elif sub:
            y += gap + flow(cv, 2, w - 1, y + gap, sub, "sub:" + v["sub"])
    elif v["tab"] == "items":
        x = chip(cv, 2, y, v["cat"] + " ▼", "pick:cats", "on" if v["pick"] == "cats" else "plain")
        if v["cat"] != "all" and subs(v, m):
            chip(cv, x + 1, y, v["sub"] + " ▼", "pick:subs", "on" if v["pick"] == "subs" else "plain")
        y += 1
    elif v["tab"] == "low":
        y += flow(cv, 2, w - 1, y, [("low:all", "all"), ("low:low", "low"), ("low:empty", "empty")],
                  "low:" + v["low"])
    else:
        dx = chip(cv, w - 12, y, "del", "key:DEL")
        chip(cv, dx + 1, y, "clr", "key:CLR")
        cv.put(2, y, ">", "8")
        cv.put(4, y, v["search"].upper()[-max(1, w - 19):], "0")
        if v["keys"]:
            cv.put(4 + min(len(v["search"]), max(1, w - 19)), y, "_", "8")
        if w > 15:
            cv.hit("keys", 2, y, w - 15, 1, ">")
        y += 1
        if v["keys"]:
            per = max(1, min(13, (w - 1) // 4))
            for i, k in enumerate(KEYS):
                if y + gap + i // per <= bottom:
                    chip(cv, 2 + (i % per) * 4, y + gap + i // per, k, "key:" + k)
            y += gap + -(-len(KEYS) // per)
    y += gap
    if v["pick"] and v["tab"] == "items" and (not wide or v["pick"] == "subs"):
        picker(cv, m, v, y, w, bottom)
        note(cv, m, chip(cv, 2, h, "back", "back") + 1, h)
        return cv
    if it:
        rx = w - min(40, max(24, int(w * 0.42))) - 2
        last = pane(cv, m, v, it, rx + 2, y, w - rx - 2, bottom, True)
        cols, cw, trend, top = 1, rx - 3, False, y
    else:
        cols = 2 if w >= 90 else 1
        cw = (w - 2 - 3 * (cols - 1)) // cols
        trend, top = cw >= 36, y + 1
        for c in range(cols if cw >= 14 else 0):
            sorter(cv, 2 + c * (cw + 3), y, cw - 7 if trend else cw, v, trend)
    n = min(max(0, bottom - top + 1), most // cols)
    per = max(1, n * cols)
    count = max(1, -(-len(m["items"]) // per))
    page = max(1, min(v["page"], count))
    if not m["found"]:
        cv.put(2, top, "!", "e")
        cv.put(4, top, "storage room not found"[:max(0, w - 4)], "0")
    elif not m["items"]:
        cv.put(2, top, "no items", "8")
    shown = m["items"][(page - 1) * per:page * per] if n else []
    rows = min(n, -(-len(shown) // cols)) or 1
    for i, item in enumerate(shown):
        x = 2 + (i // rows) * (cw + 3)
        if i // rows > 0 and i % rows == 0:
            for ry in range(y, top + rows):
                cv.put(x - 2, ry, "|", "c")
        row(cv, x, top + i % rows, cw, item, trend, it is not None and item["name"] == it["name"])
    if it:
        for ry in range(y, max(last, top + rows - 1 if shown else y) + 1):
            cv.put(rx, ry, "|", "c")
    pages(cv, m, w, h, page, count)
    return cv


# ---------------------------------------------------------------- fixtures

SIZES = [(57, 24, "room monitor"), (39, 19, "wall monitor 4x3 at scale 1"), (100, 38, "large wall"),
         (29, 12, "compact monitor"), (26, 20, "pocket")]
PAGES = [
    ("browse", "category browse", dict(cat="ores")),
    ("item", "item with an order sent", dict(cat="ores", selected="minecraft:iron_ingot")),
    ("low", "low and empty stock", dict(tab="low")),
    ("find", "search keypad", dict(tab="find", search="iron", keys=True)),
    ("pick", "category picker", dict(cat="ores", pick="cats")),
]


def page(name, kw, w, h, title):
    def make():
        data = stock()
        recent = []
        if kw.get("selected"):
            recent = [dict(hm=NOW, n=16, status="sent")] + data["orders"]
        v = view(**kw)
        return layout(gather(data, v, recent), v, w, h, title)
    return make


FIXTURES = [("shop-%s-%dx%d" % (name, w, h), page(name, kw, w, h, "Shop %s, %s %dx%d" % (what, where, w, h)))
            for name, what, kw in PAGES for w, h, where in SIZES if name != "pick" or w < 52]
# The Big Tiles shop fixture names stay (test files are never deleted) and hold route A pages.
KW = {name: (what, kw) for name, what, kw in PAGES}
FIXTURES += [(old, page(name, KW[name][1], w, h, "Shop %s, %s %dx%d" % (KW[name][0], where, w, h)))
             for old, name, w, h, where in (("shop-M", "browse", 57, 24, "room monitor"),
                                            ("shoporder-M", "item", 57, 24, "room monitor"),
                                            ("shop-compact", "browse", 29, 12, "compact monitor"),
                                            ("shop-pocket", "browse", 26, 20, "pocket"),
                                            ("shop-large", "browse", 100, 38, "large wall"))]
