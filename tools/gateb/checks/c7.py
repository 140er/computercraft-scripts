import re
from .mining import analyze, criteria, cold_cells, audit_dug

TITLE = "Thirty-minute mining soak"


def evaluate(data):
    c = criteria(data)
    c.require(data.get("game_seconds", 0) >= 1800, "Observe at least 1800 game seconds")
    for name in ("ore_delivered", "ore_trip"):
        c.require(data.get(name), name.replace("_", " "))
    c.require(data.get("server_errors") == 0 if "server_errors" in data else None, "No server handler, tick or listener failures")
    return c.finish(data)


def run(ctx):
    cold = cold_cells(ctx, "C7")
    ctx.mining()
    before = ctx.count_items("ore", "raw_iron")
    start = ctx.game_clock()
    miners = [ctx.computer(n) for n in ("miner1", "miner2")]
    def done(rows):
        observed = analyze(rows, miners, ctx.tick_rate, 180)
        return bool(observed["range_samples"] or observed["stalled_miners"] or observed["collisions"] or
                    (ctx.game_clock() - start) >= 1800000)
    rows = ctx.sample("C7-samples.jsonl", ctx.game_seconds(1800) + 60,
                      done,
                      observe=lambda: {"server_log": ctx.lua("server", "return SO.terminal.log")})
    data = analyze(rows, miners, ctx.tick_rate, 180)
    data["previously_dug_cells"] = audit_dug(rows, miners, cold)
    data["game_seconds"] = (ctx.game_clock() - start) / 1000
    data["ore_delivered"] = ctx.count_items("ore", "raw_iron") - before > 0
    for kind in ("ore", "fuel"):
        data[f"{kind}_trip"] = any(t.get("trip", {}).get("kind") == kind for r in rows for t in r["mine"].get("turtles", {}).values())
    if not data["fuel_trip"]:
        data["fuel_trip_coverage"] = "not triggered; covered by unit tests"
    data["conditional_yield"] = ("naturally triggered; observed in samples" if any(t.get("yield") for r in rows for t in r["mine"].get("turtles", {}).values())
                                 else "not triggered; covered by unit tests")
    data["server_errors"] = len({line for r in rows for line in r.get("server_log", [])
                                 if re.search(r"so-server: (handler|tick|listen).*failed", line)})
    return evaluate(ctx.record("C7-observations.json", data))
