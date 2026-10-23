"""Status in route A at every size; the twin of U.status in so-ui.lua.

model() builds, from the scene, the same table so-mod-display's gather builds from the modules.
"""
from cc import Canvas
from kit import age, arrow, bar, filled, flag, leader, mark, progress, section, ticks, tone
from scene import PHASE, S, ST


def hm(t):
    return t[:5]


def model():
    st = ST
    pos = S["poses"]
    turtles, mine, wood = [], [], []
    busy, lane = 0, None
    for t in st["turtles"]:
        p = pos[str(t["id"])]
        lost = st["leases"].get(t["id"]) == "lost"
        word = "lost" if lost else PHASE.get(t["state"], t["state"]) if t["job"] == "lumber" else t["state"]
        where = "farm" if t["job"] == "lumber" else "lane" if t["at"] == "lane" else "b%d" % (int(t["at"]) + 1)
        row = dict(id=t["id"], facing=p["f"], state=word, tone=tone(word), where=where, x=p["x"], y=p["y"],
                   z=p["z"], fuel=t["fuel"], ore=t["ore"], ago=t["ago"], lost=lost)
        (wood if t["job"] == "lumber" else mine).append(row)
        if t["job"] == "mine":
            if row["tone"] == "d":
                busy += 1
            if t["at"] == "lane":
                lane = row
    mine.sort(key=lambda r: r["id"])
    turtles = mine + wood
    flags = [dict(text="#%d lost" % t["id"], detail="%d,%d,%d · %s" % (t["x"], t["y"], t["z"], age(t["ago"], True)),
                  short=age(t["ago"])) for t in turtles if t["lost"]]
    flags += [dict(text="drop %d %s broken" % (d["id"], d["kind"]), brief="drop %d broken" % d["id"])
              for d in S["drops"] if d["broken"]]
    ready = sum(1 for sp in S["spots"] if sp["ready"])
    m = st["mining"]
    lu = st["lumber"]
    grow = lu["grow"] // 1000
    used = st["cap"] - st["free"]
    return dict(
        time="21:14", server=dict(id=st["id"], up="%dh%02d" % (st["uptime"] // 3600000, st["uptime"] // 60000 % 60)),
        flags=flags, turtles=turtles,
        mining=dict(state="running" if m["running"] else "stopped", done=m["done"], total=m["total"],
                    busy=busy, workers=len(mine), lane=lane),
        lumber=dict(state="running" if lu["running"] else "stopped", ready=ready, spots=len(S["spots"]),
                    grow="%d:%02d" % (grow // 60, grow % 60)),
        today=dict(ore=st["today"]["ore"], logs=st["today"]["logs"], recent=st["today"]["recent"],
                   names=st["today"]["names"]),
        disk=dict(used=used, cap=st["cap"]),
        leases=sum(1 for v in st["leases"].values() if v == "open"),
        displays=[dict(id=d["id"], role=d["role"], size=d["size"], ago=0) for d in st["displays"]],
        drops=S["drops"],
        events=[dict(time=e["time"], text=e["text"], tone=mark(e["text"])) for e in reversed(st["events"])],
    )


# ---------------------------------------------------------------- shared rows

def state_fg(t):
    return t if t in ("1", "e", "8") else "0"


def turtle(cv, x, y, t, w):
    """Arrow, id, state, where. w is the row width; narrow rows put where at the right edge."""
    cv.put(x, y, arrow(t["facing"]), t["tone"])
    cv.put(x + 2, y, str(t["id"]), "0")
    if w >= 30:
        cv.put(x + 5, y, t["state"][:10], state_fg(t["tone"]))
        cv.put(x + 16, y, t["where"][:5], "8")
    else:
        cv.put(x + 5, y, t["state"][:w - 11], state_fg(t["tone"]))
        cv.put(x + w - 4, y, t["where"][:4], "8")


def at(t, full=False):
    """"x,z" or "x,y,z", or "-" before the first known position."""
    if t.get("x") is None:
        return "-"
    return "%d,%d,%d" % (t["x"], t["y"], t["z"]) if full else "%d,%d" % (t["x"], t["z"])


def more(cv, x, y, n):
    cv.put(x, y, "+%d more" % n, "8")


def disk_value(d):
    if not d:
        return "-", "8"
    pct = "%d%%" % (d["used"] * 100 // d["cap"])
    return pct, "e" if d["used"] * 5 >= d["cap"] * 4 else "0"


def disk(cv, x, y, w, d, value=None):
    """disk |········ 13% across w cells; value replaces the percentage."""
    pct, fg = disk_value(d)
    value = value or pct
    cv.put(x, y, "disk", "8")
    n = w - 6 - max(4, len(value))
    ticks(cv, x + 5, y, n, filled(n, d["used"], d["cap"]) if d else 0, "e" if fg == "e" else "3")
    cv.put(x + w - len(value), y, value, fg)


def jobs(cv, x, y, m, wide=False):
    mi, lu = m.get("mining"), m.get("lumber")
    cv.put(x, y, "mining", "0")
    if mi:
        cv.put(x + 8, y, mi["state"], tone(mi["state"]))
        progress(cv, x + 17, y, 10, mi["done"], mi["total"])
        if wide:
            cv.put(x + 34, y, "busy %d/%d" % (mi["busy"], mi["workers"]), "8")
            if mi["lane"]:
                cv.put(x + 44, y, "lane", "8")
                cv.put(x + 49, y, arrow(mi["lane"]["facing"]) + str(mi["lane"]["id"]), "b")
    else:
        cv.put(x + 8, y, "-", "8")
    cv.put(x, y + 1, "lumber", "0")
    if lu:
        cv.put(x + 8, y + 1, lu["state"], tone(lu["state"]))
        progress(cv, x + 17, y + 1, 10, lu["ready"], lu["spots"], "d", "♠", "8", "♣")
        if wide and lu.get("grow"):
            cv.put(x + 34, y + 1, "grow " + lu["grow"], "8")
    else:
        cv.put(x + 8, y + 1, "-", "8")


def today_rows(m, n):
    t = m.get("today")
    if not t:
        return [("ore", "-", "8"), ("logs", "-", "8"), ("ore 10 min", "-", "8")][:n]
    rows = [("ore", str(t["ore"]), "0")]
    for name, count in t["names"][:max(0, n - 3)]:
        rows.append((name, str(count), "0"))
    rows += [("logs", str(t["logs"]), "0"), ("ore 10 min", "+%d" % t["recent"], "0")]
    return rows[:n]


def flags(cv, y, w, m, n, short=False, x=2):
    """Up to n alert rows from y; the last says how many more. Returns the rows drawn."""
    fl = m["flags"]
    shown = fl[:n]
    room = w - 2 * (x - 1)
    for i, f in enumerate(shown):
        detail = f.get("short") if short else f.get("detail")
        text = f.get("brief") if len(f["text"]) > room - 2 and f.get("brief") else f["text"]
        flag(cv, x, y + i, room, text, detail or "")
    if len(fl) > n and n > 0:
        extra = "+%d" % (len(fl) - n)
        cv.put(w - len(extra), y + n - 1, extra, "8")
    if shown and m.get("alerts"):
        cv.hit("alerts", x, y, room, len(shown))
    return len(shown)


def event_rows(cv, x, y, w, m, n, clock=5):
    for i, e in enumerate(m["events"][:n]):
        if clock:
            cv.put(x, y + i, e["time"][:clock], "8")
        tx = x + (clock + 1 if clock else 0)
        cv.put(tx, y + i, "•", e["tone"])
        cv.put(tx + 2, y + i, e["text"][:max(0, w - (tx + 2 - x))], "0")


# ---------------------------------------------------------------- layouts

def room(cv, m):
    w, h = cv.w, cv.h
    bar(cv, m.get("name", "STATUS"), right=m["time"])
    na = flags(cv, 3, w, m, 2)
    top = 4 + na if na else 3
    lw, rx = w - 24, w - 19
    ts = m["turtles"]
    room_rows = max(0, h - top - 11)
    nt = min(len(ts), room_rows)
    section(cv, 2, top, lw, "TURTLES", len(ts))
    for i in range(nt):
        y = top + 1 + i
        if i == nt - 1 and len(ts) > nt:
            more(cv, 4, y, len(ts) - i)
            break
        t = ts[i]
        turtle(cv, 2, y, t, lw)
        cv.put(24, y, at(t)[:lw - 22], "e" if t["lost"] else "8")
    jy = top + nt + 2
    section(cv, 2, jy, lw, "JOBS")
    jobs(cv, 2, jy + 1, m)
    section(cv, rx, top, 19, "TODAY")
    for i, (a, b, c) in enumerate(today_rows(m, 3)):
        leader(cv, rx, top + 1 + i, 19, a, b, c)
    section(cv, rx, top + 5, 19, "SERVER")
    disk(cv, rx, top + 6, 19, m.get("disk"))
    leader(cv, rx, top + 7, 19, "leases", str(m["leases"]))
    leader(cv, rx, top + 8, 19, "displays", str(len(m["displays"])))
    leader(cv, rx, top + 9, 19, "up", m["server"]["up"])
    dy = max(jy + 2, top + 9) + 2
    section(cv, 2, dy, w - 2, "DROPS", len(m["drops"]))
    x = 2
    for d in m["drops"]:
        text = "%d %s" % (d["id"], d["kind"])
        if x + 1 + len(text) > w - 1:
            break
        c = "e" if d["broken"] else "0"
        cv.put(x, dy + 1, "×" if d["broken"] else "•", c)
        cv.put(x + 2, dy + 1, text, c)
        x += len(text) + 5
    ey = dy + 3
    if ey < h:
        section(cv, 2, ey, w - 2, "EVENTS")
        event_rows(cv, 2, ey + 1, w - 2, m, h - ey)


def wall(cv, m):
    w, h = cv.w, cv.h
    bar(cv, m.get("name", "STATUS"), right="server #%d · %s" % (m["server"]["id"], m["time"]))
    na = flags(cv, 3, 56, m, 2)
    top = 4 + na if na else 3
    lw = 54
    ts = m["turtles"]
    # Caps keep the biggest walls inside the 16 KB frame; tight is the fallback when they do not.
    tight = m.get("tight")
    nt = min(len(ts), max(3, min(h - top - 27, 5 if tight else 8)))
    section(cv, 2, top, lw, "TURTLES", len(ts))
    for x, label in ((24, "position"), (40, "fuel"), (47, "ore"), (52, "seen")):
        cv.put(x, top + 1, label, "8")
    for i in range(nt):
        y = top + 2 + i
        if i == nt - 1 and len(ts) > nt:
            more(cv, 4, y, len(ts) - i)
            break
        t = ts[i]
        turtle(cv, 2, y, t, lw)
        cv.put(24, y, at(t, True), "0")
        fuel = t.get("fuel")
        cv.put(39, y, "%5s" % ("-" if fuel is None else fuel), "1" if fuel is not None and fuel < 500 else "0")
        cv.put(46, y, "%4s" % t.get("ore", "-"), "0")
        cv.put(52, y, age(t["ago"]), "e" if t["lost"] else "1" if t["ago"] >= 120000 else "8")
    jy = top + nt + 3
    section(cv, 2, jy, lw, "JOBS")
    jobs(cv, 2, jy + 1, m, True)
    fy = jy + 4
    section(cv, 2, fy, 26, "TODAY")
    for i, (a, b, c) in enumerate(today_rows(m, 5)):
        leader(cv, 2, fy + 1 + i, 26, a, b, c)
    section(cv, 31, fy, 25, "SERVER")
    d = m.get("disk")
    disk(cv, 31, fy + 1, 25, d, d and "%.1f/%d MB" % (d["used"] / 1e6, d["cap"] // 1000000))
    leader(cv, 31, fy + 2, 25, "leases", str(m["leases"]))
    leader(cv, 31, fy + 3, 25, "displays", str(len(m["displays"])))
    leader(cv, 31, fy + 4, 25, "up", m["server"]["up"])
    dy = fy + 7
    ds = m["drops"]
    nd = min(len(ds), 5)
    section(cv, 2, dy, lw, "DROPS", len(ds))
    for i in range(nd):
        y = dy + 1 + i
        if i == nd - 1 and len(ds) > nd:
            more(cv, 4, y, len(ds) - i)
            break
        p = ds[i]
        c = "e" if p["broken"] else "0"
        cv.put(2, y, "×" if p["broken"] else "•", c)
        cv.put(4, y, str(p["id"]), c)
        cv.put(7, y, p["kind"][:9], c)
        cv.put(17, y, at(p, True), "8")
        cv.put(31, y, "broken" if p["broken"] else "ok", "e" if p["broken"] else "8")
    ey = dy + nd + 2
    bottom = ey - 2
    if ey < h and m["events"]:
        ne = min(len(m["events"]), h - ey, 5 if tight else 8)
        section(cv, 2, ey, lw, "EVENTS")
        event_rows(cv, 2, ey + 1, lw, m, ne, 8)
        bottom = ey + ne
    rx, rw = 60, w - 60
    dy = 3
    if m.get("thumb"):
        th = min(h - 12, 26 if tight else 30)
        m["thumb"](cv, rx, 3, min(rw, 40 if tight else 48), th)
        dy = 3 + th + 1
    ls = m["displays"]
    section(cv, rx, dy, rw, "DISPLAYS", len(ls))
    shown = ls[:max(0, h - dy)]
    for i, s in enumerate(shown):
        y = dy + 1 + i
        cv.put(rx, y, "%2d" % s["id"], "0")
        cv.put(rx + 4, y, s["role"][:7], "0")
        cv.put(rx + 12, y, s["size"], "8")
        cv.put(rx + 21, y, age(s["ago"]), "8" if s["ago"] < 10000 else "1")
    # The rule stops with the content: every ruled row costs about 140 frame bytes.
    for y in range(3, max(bottom, dy + len(shown)) + 1):
        cv.put(58, y, "|", "c")


def column(cv, m):
    """One column for 24 to 95 columns and 14 or more rows: pocket, 39x19 and the 51x19 terminal."""
    w, h = cv.w, cv.h
    wide = w >= 36
    bar(cv, m.get("name", "STATUS"), right=m["time"])
    na = flags(cv, 3, w, m, 2 if h >= 17 else 1, not wide)
    top = 4 + na if na else 3
    blocks = ["jobs", "facts"] if wide else ["today", "server"]
    size = {"jobs": 4, "facts": 4, "today": 4, "server": 4}
    while blocks and h - top - sum(size[b] for b in blocks) < 1:
        blocks.pop()
    ts = m["turtles"]
    room_rows = h - top - sum(size[b] for b in blocks)
    nt = min(len(ts), room_rows)
    section(cv, 2, top, w - 2, "TURTLES", len(ts))
    for i in range(nt):
        y = top + 1 + i
        if i == nt - 1 and len(ts) > nt:
            more(cv, 4, y, len(ts) - i)
            break
        t = ts[i]
        turtle(cv, 2, y, t, w - 2)
        if wide:
            cv.put(24, y, at(t)[:w - 25], "e" if t["lost"] else "8")
    y = top + nt + 2
    for b in blocks:
        if b == "jobs":
            section(cv, 2, y, w - 2, "JOBS")
            jobs(cv, 2, y + 1, m)
        elif b == "facts":
            lw = (w - 5) // 2
            rx = 2 + lw + 3
            rw = w - rx
            section(cv, 2, y, lw, "TODAY")
            for i, (a, v, c) in enumerate(today_rows(m, 2)):
                leader(cv, 2, y + 1 + i, lw, a, v, c)
            section(cv, rx, y, rw, "SERVER")
            disk(cv, rx, y + 1, rw, m.get("disk"))
            leader(cv, rx, y + 2, rw, "leases", str(m["leases"]))
        elif b == "today":
            section(cv, 2, y, w - 2, "TODAY")
            for i, (a, v, c) in enumerate(today_rows(m, 2)):
                leader(cv, 2, y + 1 + i, w - 2, a, v, c)
        elif b == "server":
            section(cv, 2, y, w - 2, "SERVER")
            disk(cv, 2, y + 1, w - 2, m.get("disk"))
            cv.put(2, y + 2, ("%d displays · %d leases" % (len(m["displays"]), m["leases"]))[:w - 2], "8")
        y += size[b]
    if h - (y - 1) >= 2 and m["events"]:
        section(cv, 2, y, w - 2, "EVENTS")
        event_rows(cv, 2, y + 1, w - 2, m, h - y, 5 if w >= 30 else 0)


def tiny(cv, m):
    """Under 24 columns or 14 rows: the role name and the leaders that fit."""
    w, h = cv.w, cv.h
    name = m.get("name", "STATUS")
    bar(cv, name, right=m["time"] if w >= len(name) + 9 else "")
    y = 3 if h >= 6 else 2
    na = flags(cv, y, w, m, 2 if h >= 9 else 1 if h >= 6 else 0, True, 1)
    if na:
        y += na + 1
    ts = m["turtles"]
    lost = sum(1 for t in ts if t["lost"])
    mi, t, d = m.get("mining"), m.get("today"), m.get("disk")
    rows = [("turtles", str(len(ts)), "e" if lost else "0")]
    if mi:
        running = mi["state"] == "running"
        rows.append(("mining", "%d/%d" % (mi["done"], mi["total"]) if running else mi["state"], "0" if running else "8"))
    rows += [("ore", str(t["ore"]) if t else "-", "0" if t else "8"),
             ("logs", str(t["logs"]) if t else "-", "0" if t else "8")]
    rows.append(("disk",) + disk_value(d))
    lu = m.get("lumber")
    if lu:
        rows.append(("trees", "%d/%d" % (lu["ready"], lu["spots"]), "0"))
    for a, v, c in rows:
        if y > h:
            break
        leader(cv, 2, y, w - 2, a, v, c)
        y += 1


def status(m, w, h, title=""):
    cv = Canvas(w, h, title)
    if w >= 96 and h >= 32:
        wall(cv, m)
    elif w >= 52 and h >= 22:
        room(cv, m)
    elif w >= 24 and h >= 14:
        column(cv, m)
    else:
        tiny(cv, m)
    return cv
