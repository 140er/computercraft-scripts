# Shop mockups: a port of the so-mod-shop.lua layout, fed with tests/ui/shop-stock.tsv.
# Coordinates are 1-based like the Lua kit. tests/ui/ui2c.lua drives the real module
# with the same stock and compares every fixture cell. The port covers the fixture
# scenes: fresh stock on screens at least 26 wide. Stale and missing stock and the
# split navigation of narrower screens exist only in the Lua.
import math
import re
from pathlib import Path

GLYPHS = "0123456789%-:/ "
BITS = [1, 2, 4, 8, 16, 32]


class Kit:
    """The so-ui.lua canvas calls the shop uses, on a generator Canvas."""

    def __init__(s, canvas, big, sextant):
        s.c, s.w, s.h, s.bigrows, s.sextant = canvas, canvas.w, canvas.h, big, sextant

    def put(s, x, y, text, bg=None):
        for i, ch in enumerate(text):
            cx = x + i
            if 1 <= cx <= s.w and 1 <= y <= s.h:
                s.c.t[y - 1][cx - 1] = ch
                if bg:
                    s.c.b[y - 1][cx - 1] = bg

    def fill(s, x, y, width, height, bg):
        for j in range(y, y + height):
            s.put(x, j, " " * max(0, width), bg)

    def center(s, x, width, y, text, bg=None):
        text = str(text)[:max(0, width)]
        s.put(x + max(0, (width - len(text)) // 2), y, text, bg)

    def big(s, x, y, width, text, bg):
        text = str(text)
        if len(text) * 3 > width or any(ch not in GLYPHS for ch in text):
            s.center(x, width, y + 1, text, bg)
            return
        start = x + max(0, (width - len(text) * 3) // 2)
        for r, row in enumerate(s.bigrows(text)):
            s.put(start, y + r, row, bg)

    def tile(s, x, y, width, label, value, sub, bg, height):
        right = min(s.w - 1, x + width - 1)
        x = max(2, x)
        width = max(0, right - x + 1)
        s.fill(x, y, width, height, bg)
        s.put(x + 1, y + 1, label[:max(0, width - 2)])
        s.big(x + 1, y + 2, max(0, width - 2), value, bg)
        if height >= 7:
            s.put(x + 1, y + 5, sub[:max(0, width - 2)])

    def button(s, x, y, width, label, bg="7", height=3):
        s.fill(x, y, width, height, bg)
        inset = 1 if len(label) <= width - 2 else 0
        s.center(x + inset, max(0, width - 2 * inset), y + height // 2, label)

    def header(s, name, right, bg):
        s.fill(2, 2, max(0, s.w - 2), 1, bg)
        s.put(2, 2, name[:max(0, s.w - 2)])
        s.put(s.w - len(right), 2, right)

    def right(s, x, y, text):
        s.put(x - len(text) + 1, y, text)

    def sparkline(s, x, y, width, height, samples, ink):
        n, pw, ph = len(samples), width * 2, height * 3
        if n == 0 or width < 1 or height < 1:
            return
        lo, hi = min(samples), max(samples)
        cells = {}
        for px in range(pw):
            v = samples[math.floor(px * n / pw)]
            tall = math.ceil(ph / 2) if hi == lo else math.floor((v - lo) * (ph - 1) / (hi - lo) + 0.5) + 1
            for py in range(ph - tall, ph):
                key = (py // 3) * width + px // 2
                cells[key] = cells.get(key, 0) + BITS[px % 2 + 2 * (py % 3)]
        for r in range(height):
            for c in range(width):
                bits = cells.get(r * width + c, 0)
                # The test capture shows a partial cell as its navy pixels on the ink colour.
                if bits == 0:
                    s.put(x + c, y + r, " ", "f")
                elif bits == 63:
                    s.put(x + c, y + r, " ", ink)
                else:
                    s.put(x + c, y + r, s.sextant(63 - bits), ink)


def grid(w, n):
    available = w - n + 1
    cols = []
    for i in range(1, n + 1):
        left = math.floor((i - 1) * available / n + 0.5)
        right = math.floor(i * available / n + 0.5)
        cols.append((left + i, right - left))
    return cols


CATS = [("ores", "ORES", "ore raw ingot nugget block gem dust"), ("wood", "WOOD", "log planks sapling crafted"),
        ("stone", "STONE", "stone earth build"), ("plants", "PLANTS", "leaves seeds flowers plants"),
        ("food", "FOOD", "crops meat meals"), ("tools", "TOOLS", "tools weapons armour"),
        ("redstone", "REDSTONE", "dust logic motion"), ("mobs", "MOBS", "hostile passive"),
        ("mods", "MODS", ""), ("other", "OTHER", "")]


def label(name):
    path = name.split(":", 1)[1] if ":" in name else name
    return " ".join(word[:1].upper() + word[1:] for word in path.split("_"))


def short(n):
    return str(n // 1000) + "k" if n >= 10000 else str(n)


def load():
    items, orders, recipes = [], {}, {}
    for line in Path(__file__).resolve().parents[2].joinpath("tests/ui/shop-stock.tsv").read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        f = line.split("\t")
        if f[0] == "order":
            orders.setdefault(f[1], []).append((f[2], int(f[3]), f[4]))
            continue
        if f[0] == "recipe":
            recipes[f[1]] = int(f[2])
            continue
        name, count, stack = f[0], int(f[1]), int(f[3])
        cat, sub = f[4].split("/")
        samples = [int(v) for v in f[2].split(",")] if "," in f[2] else [int(f[2])] * 59 + [count]
        delta = count - samples[0]
        rate = math.floor(abs(delta) * 60 / max(1, len(samples) - 1) + 0.5)
        item = dict(name=name, label=label(name), count=count, stack=stack, cat=cat, sub=sub,
                    rate=-rate if delta < 0 else rate, samples=samples)
        item["trend"] = "-" if delta == 0 else ("^ +" if delta > 0 else "v -") + short(rate) + "/h"
        item["arrow"] = "-" if delta == 0 else "^" if delta > 0 else "v"
        item["state"] = "empty" if count == 0 else "low" if count < min(16, stack) else "ok"
        items.append(item)
    return items, orders, recipes


def norm(text):
    return re.sub(r"\s+", "_", text.lower())


def match(item, query):
    return query == "" or query in item["name"].lower() or query in norm(item["label"])


def ordered(items, sort):
    if sort == "name":
        return sorted(items, key=lambda i: (i["label"].lower(), i["name"]))
    if sort == "trend":
        return sorted(items, key=lambda i: (-abs(i["rate"]), i["name"]))
    return sorted(items, key=lambda i: (-i["count"], i["name"]))


def summary(items):
    rows = [dict(id="cat:" + c[0], label=c[1], cat=c[0], items=0, total=0, low=0) for c in CATS]
    low = dict(id="low", label="LOW", items=0)
    empty = dict(id="empty", label="EMPTY", items=0)
    for item in items:
        row = next(r for r in rows if r["cat"] == item["cat"])
        row["items"] += 1
        row["total"] += item["count"]
        if item["state"] != "ok":
            row["low"] += 1
        if item["state"] == "low":
            low["items"] += 1
        if item["state"] == "empty":
            empty["items"] += 1
    for row in rows:
        row["state"] = "b" if row["items"] > 0 else "c"
    low["state"] = "1" if low["items"] > 0 else "d"
    empty["state"] = "e" if empty["items"] > 0 else "d"
    return rows + [low, empty]


def nav(k, entries):
    for (x, width), entry in zip(grid(k.w, len(entries)), entries):
        if entry[1]:
            k.button(x, k.h, width, entry[0], entry[2] if len(entry) > 2 else "7", 1)
        else:
            k.fill(x, k.h, width, 1, "7")
            inset = 1 if len(entry[0]) <= width - 2 else 0
            k.center(x + inset, max(0, width - 2 * inset), k.h, entry[0])


def paged(entries, page, pages):
    if pages <= 1:
        return entries
    return [entries[0], ("<", "prev"), (f"{page}/{pages}", None), (">", "next")] + entries[1:]


def flow(k, y, entries, selected, most):
    rows, row, used, width = [], [], 0, k.w - 2
    for entry in entries:
        need = len(entry[1]) + 1
        if row and used + 1 + need > width:
            rows.append((row, used))
            row, used = [], 0
        used += (1 if row else 0) + need
        row.append(entry)
    if row:
        rows.append((row, used))
    rows = rows[:most]
    for r, (pack, used) in enumerate(rows):
        x, extra, n = 2, width - used, len(pack)
        for i, entry in enumerate(pack, 1):
            size = len(entry[1]) + 1 + math.floor(extra * i / n) - math.floor(extra * (i - 1) / n)
            k.button(x, y + r, size, entry[1], "a" if entry[0] == selected else "7", 1)
            x += size + 1
    return len(rows)


def header(k, title, status):
    right = status if k.w >= 26 else ""
    k.header(title[:max(0, k.w - 3 - len(right))], right, "a")


def home(k, items, page=1):
    top = 4 if k.h >= 16 else 3
    rows = summary(items)
    space = max(1, k.h - 2 - top)
    tall = max(1, min(3, space // len(rows)))
    per = max(1, space // tall)
    pages = max(1, math.ceil(len(rows) / per))
    nav(k, paged([("ALL", "all"), ("FIND", "search")], page, pages))
    x0, x1 = 2, k.w - 1
    count = x0 + 16
    total = count + (7 if x1 - x0 + 1 < 26 else 8)
    low = total + 5 if x1 - total >= 5 else None
    bar = (low or total) + 2
    most = max([1] + [r.get("total", 0) for r in rows])
    k.fill(x0, top, x1 - x0 + 1, 1, "7")
    k.put(x0 + 2, top, "CATEGORY")
    k.right(count, top, "ITEMS")
    k.right(total, top, "TOTAL")
    if low:
        k.right(low - 1, top, "LOW")
    for i, row in enumerate(rows[(page - 1) * per:page * per], 1):
        y = top + 1 + (i - 1) * tall
        mid = y + (tall - 1) // 2
        k.fill(x0, y, x1 - x0 + 1, tall, "7" if i % 2 == 0 else "f")
        k.fill(x0, y, 1, tall, row["state"])
        k.put(x0 + 2, mid, row["label"][:9])
        k.right(count, mid, str(row["items"]))
        if "total" in row:
            k.right(total, mid, str(row["total"]))
        if low and row.get("low", 0) > 0:
            k.fill(low - 3, y, 4, tall, "1")
            k.right(low - 1, mid, str(row["low"]))
        if "total" in row and x1 - bar + 1 >= 6 and row["total"] > 0:
            k.fill(bar, y, max(1, math.floor(row["total"] * (x1 - bar + 1) / most + 0.5)), tall, "b")
    y = top + 2 + len(rows) * tall
    if pages > 1 or k.h - 2 - y < 3:
        return
    movers = ordered([i for i in items if i["rate"] != 0], "trend")[:k.h - 2 - y]
    if movers:
        table(k, x0, x1, y, movers, None, "MOVING")


def columns(width):
    if width >= 44:
        return [("count", "COUNT", 7), ("stacks", "STACKS", 7), ("trend", "TREND", 10)]
    if width >= 34:
        return [("count", "COUNT", 7), ("trend", "TREND", 10)]
    if width >= 20:
        return [("count", "COUNT", 6), ("trend", "^v", 2)]
    return [("count", "COUNT", 6)]


def cell(item, key, width):
    if key == "count":
        return str(item["count"])
    if key == "trend":
        return item["arrow"] if width < 10 else item["trend"]
    if item["stack"] <= 1:
        return "-"
    stacks = item["count"] / item["stack"]
    return str(math.floor(stacks)) if stacks >= 100 else "%.1f" % stacks


def table(k, x0, x1, y, items, sort, title=None):
    cols, right = columns(x1 - x0 + 1), x1
    spans = [None] * len(cols)
    for i in range(len(cols) - 1, -1, -1):
        spans[i] = (right - cols[i][2] + 1, right, right - 1 if cols[i][0] == "count" else right)
        right -= cols[i][2]
    k.fill(x0, y, x1 - x0 + 1, 1, "7")
    if sort == "name":
        k.fill(x0, y, right - x0 + 1, 1, "a")
    k.put(x0 + 2, y, title or "NAME")
    for col, span in zip(cols, spans):
        if col[0] == sort:
            k.fill(span[0], y, span[1] - span[0] + 1, 1, "a")
        k.right(span[2], y, col[1])
    for i, item in enumerate(items, 1):
        row = y + i
        state = {"ok": "d", "low": "1", "empty": "e"}[item["state"]]
        k.fill(x0, row, x1 - x0 + 1, 1, "7" if i % 2 == 0 else "f")
        k.fill(x0, row, 1, 1, state)
        for col, span in zip(cols, spans):
            if col[0] == "count" and item["state"] != "ok":
                k.fill(span[0] + 1, row, span[1] - span[0], 1, state)
            k.right(span[2], row, cell(item, col[0], col[2]))
        k.put(x0 + 2, row, item["label"][:max(0, right - x0 - 2)])


def subs(cat, items):
    entry = next(c for c in CATS if c[0] == cat)
    out = [("sub:all", "ALL")] + [("sub:" + s, s.upper()) for s in entry[2].split()]
    if cat == "mods":
        counts = {}
        for item in items:
            if item["cat"] == "mods":
                counts[item["sub"]] = counts.get(item["sub"], 0) + 1
        for space in sorted(counts, key=lambda s: (-counts[s], s)):
            out.append(("sub:" + space, space.upper()[:10]))
    return out if len(out) > 1 else None


def listing(k, items, chosen, chips=None, sub="all", sort="count", page=1):
    y = 4 if k.h >= 16 else 3
    if chips:
        y += flow(k, y, chips, "sub:" + sub, max(0, k.h - 3 - y))
    split = 2 if k.w - 2 >= 90 else 1
    width = (k.w - 2 - (split - 1)) // split
    per = max(1, k.h - 2 - y)
    capacity = per * split
    pages = max(1, math.ceil(len(chosen) / capacity))
    nav(k, paged([("BACK", "back")], page, pages))
    chosen = ordered(chosen, sort)
    first = (page - 1) * capacity
    rows = math.ceil(min(capacity, len(chosen) - first) / split)
    for c in range(split):
        start = first + c * rows
        piece = chosen[start:start + rows]
        if c == 0 or piece:
            x0 = 2 + c * (width + 1)
            table(k, x0, x0 + width - 1, y, piece, sort)


def trend_ink(item):
    return "d" if item["rate"] > 0 else "1" if item["rate"] < 0 else "b"


def chart(k, x, y, width, height, item):
    if width < 4 or height < 2:
        return
    k.fill(x, y, width, 1, "7")
    if len(item["trend"]) + 9 <= width:
        k.put(x + 1, y, "TREND")
    k.right(x + width - 2, y, item["trend"] if len(item["trend"]) <= width - 2 else item["arrow"])
    k.fill(x, y + 1, width, height - 1, "f")
    k.sparkline(x + 1, y + 1, width - 2, height - 1, item["samples"], trend_ink(item))


def stock_tile(k, item, x, y, width, height):
    word = {"empty": "EMPTY", "low": "LOW"}.get(item["state"], "IN STOCK")
    bg = {"ok": "b", "low": "1", "empty": "e"}[item["state"]]
    full, rest = divmod(item["count"], item["stack"])
    sub = ""
    if item["stack"] > 1 and full > 0:
        sub = f"{full} stacks" + (f" + {rest}" if rest > 0 else "")
    k.tile(x, y, width, word, str(item["count"]), sub, bg, height)


AMOUNTS = ["1", "16", "64", "STACK", "ALL"]


def order_button(k, x, y, width, height, label, item):
    if label == "ALL" and item["count"] <= 0:
        k.fill(x, y, width, height, "c")
        k.center(x + 1, max(0, width - 2), y + height // 2, label)
    else:
        k.button(x, y, width, label, "a", height)


def facts(item, recipes):
    cat = next(c[1] for c in CATS if c[0] == item["cat"])
    if item["cat"] != "other":
        cat += " > " + item["sub"].upper()
    out = ["STACK " + str(item["stack"]), cat]
    if item["name"] in recipes:
        out.append("CRAFT " + str(recipes[item["name"]]))
    return out


def detail(k, item, orders, recipes, status):
    w, h = k.w, k.h
    nav(k, [("BACK", "items")])
    top = 4 if h >= 16 else 3
    if h < 16:
        bottom = h - 2
        tile = max(13, len(str(item["count"])) * 3 + 3) if w >= 26 else w - 2
        stock_tile(k, item, 2, top, tile, max(1, bottom - 1 - top))
        if w >= 26:
            chart(k, tile + 3, top, w - tile - 4, bottom - 1 - top, item)
        for (x, width), label in zip(grid(w, 5), AMOUNTS):
            order_button(k, x, bottom, width, 1, label, item)
        k.put(2, h - 1, status[:max(0, w - 2)])
        return
    if w < 39:
        th = 7 if h >= 20 else 6
        stock_tile(k, item, 1, top, w, th)
        buttons = h - 3
        chart(k, 2, top + th + 1, w - 2, buttons - 1 - (top + th + 1), item)
        for (x, width), label in zip(grid(w, 3), AMOUNTS[:3]):
            order_button(k, x, buttons, width, 1, label, item)
        for (x, width), label in zip(grid(w, 2), AMOUNTS[3:]):
            order_button(k, x, buttons + 1, width, 1, label, item)
        k.put(2, h - 1, status[:max(0, w - 2)])
        return
    cols = grid(w, max(1, (w + 1) // 19))
    th = 7 if h >= 24 else 6
    stock_tile(k, item, cols[0][0], top, cols[0][1], th)
    chart(k, cols[1][0], top, w - cols[1][0], th, item)
    height = 3
    buttons = h - 2 - height
    for (x, width), label in zip(grid(w, 5), AMOUNTS):
        order_button(k, x, buttons, width, height, label, item)
    k.put(2, h - 2, status[:max(0, w - 2)])
    lines = buttons - 1 - (top + th + 1)
    at = cols[-1][0] + 1 if w >= 50 else w
    for i, (hm, n, state) in enumerate(orders[:lines], 1):
        k.put(3, top + th + i, (hm + "%6d" % n + "  " + state)[:max(0, at - 5)])
    for i, fact in enumerate(facts(item, recipes)[:lines] if at < w else [], 1):
        k.put(at, top + th + i, fact[:max(0, w - at)])


def keypad(k, items, query):
    w, h = k.w, k.h
    found = sum(1 for item in items if match(item, norm(query)))
    nav(k, [("BACK", "back"), (f"{found} FOUND", "found", "a")])
    y = 4 if h >= 16 else 3
    k.fill(2, y, w - 2, 1, "0")
    k.put(3, y, (query.upper() + "_")[-max(1, w - 4):])
    top = y + (2 if h >= 16 else 1)
    rows = h - 2 - top + 1
    tall = max(1, min(5, (rows + 1) // 4 - 1))
    gap = 1 if 4 * tall + 3 <= rows else 0
    cols = grid(w, 7)
    for i in range(28):
        key = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"[i] if i < 26 else ("DEL" if i == 26 else "CLR")
        x, width = cols[i % 7]
        y = top + (i // 7) * (tall + gap)
        if y + tall - 1 <= h - 2:
            k.button(x, y, width, key, "7", tall)


SIZES = [(57, 24, "room monitor"), (39, 19, "wall monitor"), (26, 20, "pocket"),
         (29, 12, "compact monitor"), (100, 38, "large monitor")]
STATUS = "stock 21:14"


def generate(Canvas, big, sextant):
    items, orders, recipes = load()
    iron = next(i for i in items if i["name"] == "minecraft:iron_ingot")
    recent = [("21:14", 16, "sent")] + orders.get(iron["name"], [])
    sent = "Order: sent  Getting 16 Iron ingot..."
    ores = [i for i in items if i["cat"] == "ores"]
    scenes = []
    for w, h, where in SIZES:
        size = f"{w}x{h}"
        c = Canvas(w, h)
        k = Kit(c, big, sextant)
        header(k, "SHOP", STATUS)
        home(k, items)
        scenes.append((f"shop-home-{size}", c, f"Shop home, {where}"))
        c = Canvas(w, h)
        k = Kit(c, big, sextant)
        header(k, "ORES", STATUS)
        listing(k, items, ores, subs("ores", items))
        scenes.append((f"shop-list-{size}", c, f"Shop category list, ores, {where}"))
        c = Canvas(w, h)
        k = Kit(c, big, sextant)
        header(k, iron["label"].upper(), STATUS)
        detail(k, iron, recent, recipes, sent)
        scenes.append((f"shop-item-{size}", c, f"Shop item page, {where}"))
        c = Canvas(w, h)
        k = Kit(c, big, sextant)
        header(k, "FIND", STATUS)
        keypad(k, items, "iron")
        scenes.append((f"shop-find-{size}", c, f"Shop search keypad, {where}"))
    for w, h, where in SIZES[:3]:
        c = Canvas(w, h)
        k = Kit(c, big, sextant)
        header(k, "FIND IRON", STATUS)
        listing(k, items, [i for i in items if match(i, "iron")])
        scenes.append((f"shop-results-{w}x{h}", c, f"Shop search results, {where}"))
    c = Canvas(57, 24)
    k = Kit(c, big, sextant)
    header(k, "LOW STOCK", STATUS)
    listing(k, items, [i for i in items if i["state"] == "low"], sort="trend")
    scenes.append(("shop-low-57x24", c, "Shop low stock by trend, room monitor"))
    c = Canvas(57, 24)
    k = Kit(c, big, sextant)
    header(k, "MODS", STATUS)
    listing(k, items, [i for i in items if i["cat"] == "mods"], subs("mods", items), sort="name")
    scenes.append(("shop-mods-57x24", c, "Shop mod items by namespace, room monitor"))
    return scenes


# Fixture names from before the browser, kept as copies of the page that replaced them.
ALIASES = {"shop-M": "shop-home-57x24", "shoporder-M": "shop-item-57x24", "shop-compact": "shop-home-29x12",
           "shop-pocket": "shop-home-26x20", "shop-large": "shop-home-100x38"}


def write(Canvas, big, sextant, destination, fixtures=False):
    destination = Path(destination)
    scenes = generate(Canvas, big, sextant)
    if fixtures:
        named = {stem: (canvas, title) for stem, canvas, title in scenes}
        scenes = scenes + [(old, *named[new]) for old, new in ALIASES.items()]
        for stem, canvas, title in scenes:
            layers = [f"{canvas.w}x{canvas.h} {title}"]
            layers += ["".join(row) for row in canvas.t]
            layers += ["".join(row) for row in canvas.b]
            (destination / (stem + ".txt")).write_text("\n".join(layers) + "\n", encoding="utf-8")
    else:
        (destination / "shop-mockups.md").write_text(
            "\n\n".join(canvas.dump(title + "  [" + stem + "]", True) for stem, canvas, title in scenes) + "\n",
            encoding="utf-8")
