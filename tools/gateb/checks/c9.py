import time
from .model import Criteria

TITLE = "Idle server outage"


def evaluate(d):
    c = Criteria()
    c.require(d.get("off_seconds", 0) >= 180, "Server computer off for at least 180 real seconds")
    c.require(d.get("no_motion"), "All three idle worker journals remain still")
    stale, recovery = d.get("stale_seconds"), d.get("recovery_seconds")
    c.require(stale <= 15 if stale is not None else None, "Display becomes stale")
    c.require(recovery <= 30 if recovery is not None else None, "Display recovers within 30 seconds")
    c.require(d.get("new_recovery_parks"), "All workers receive new recovery parks")
    return c.finish(d)


def run(ctx):
    ctx.mining(start=False); ctx.lumber(start=False)
    ctx.screen_input("mining", "stop"); ctx.screen_input("lumber", "stop")
    ready = ctx.wait(lambda: all(j.get("park") for j in ctx.state()["workers"].values()) and len(ctx.state()["workers"]) == 3, 60)
    if not ready:
        return evaluate({"no_motion": False})
    before = ctx.record("C9-before.json", ctx.state())
    ctx.power("server", "off")
    started, stale = time.monotonic(), None
    rows = []
    try:
        while time.monotonic() - started < 181:
            rows.append(ctx.state())
            text = " ".join(l["text"] for l in ctx.terminal("wall")["lines"])
            if stale is None and ("stale" in text.lower() or "NO SERVER" in text): stale = time.monotonic()-started
            time.sleep(ctx.interval)
    finally:
        ctx.power("server", "on")
    off_seconds, boot = time.monotonic()-started, time.monotonic()
    recovered = ctx.wait(lambda: "stale" not in " ".join(l["text"] for l in ctx.terminal("wall")["lines"]).lower()
                         and "NO SERVER" not in " ".join(l["text"] for l in ctx.terminal("wall")["lines"]), 30)
    recovery = time.monotonic()-boot if recovered else None
    ctx.wait(lambda: all(j.get("park") and j.get("id") != before["workers"].get(k, {}).get("id")
                        for k,j in ctx.state()["workers"].items()), 30)
    after = ctx.state()
    ctx.record("C9-outage-samples.json", rows)
    return evaluate(ctx.record("C9-observations.json", {"off_seconds": off_seconds,
        "no_motion": bool(rows) and all(len(r["workers"]) == 3 and all(j.get("pose") == before["workers"][k].get("pose") for k,j in r["workers"].items()) for r in rows),
        "stale_seconds": stale, "recovery_seconds": recovery,
        "new_recovery_parks": len(after["workers"]) == 3 and all(j.get("park") and j.get("id") != before["workers"][k].get("id") for k,j in after["workers"].items())}))
