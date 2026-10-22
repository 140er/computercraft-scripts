import re
from .mining import analyze, criteria

TITLE = "Thirty-minute mining soak"


def evaluate(data):
    c = criteria(data)
    c.require(data.get("game_seconds", 0) >= 1800, "Observe at least 1800 game seconds")
    for name in ("ore_delivered", "fuel_trip", "ore_trip"):
        c.require(data.get(name), name.replace("_", " "))
    c.require(data.get("server_errors") == 0 if "server_errors" in data else None, "No server handler, tick or listener failures")
    return c.finish(data)


def run(ctx):
    ctx.set_fuel("miner1", 120)
    ctx.mining()
    before = ctx.count_items("ore", "raw_iron")
    start = ctx.game_clock()
    miners = [ctx.computer(n) for n in ("miner1", "miner2")]
    rows = ctx.sample("C7-samples.jsonl", ctx.game_seconds(1800) + 60,
                      lambda rs: analyze(rs, miners, ctx.tick_rate)["range_samples"] > 0 or
                      (ctx.game_clock() - start) >= 1800000,
                      observe=lambda: {"server_log": ctx.lua("server", "return SO.terminal.log")})
    data = analyze(rows, miners, ctx.tick_rate)
    data["game_seconds"] = (ctx.game_clock() - start) / 1000
    data["ore_delivered"] = ctx.count_items("ore", "raw_iron") - before > 0
    for kind in ("ore", "fuel"):
        data[f"{kind}_trip"] = any(t.get("trip", {}).get("kind") == kind for r in rows for t in r["mine"].get("turtles", {}).values())
    data["server_errors"] = len({line for r in rows for line in r.get("server_log", [])
                                 if re.search(r"so-server: (handler|tick|listen).*failed", line)})
    return evaluate(ctx.record("C7-observations.json", data))
