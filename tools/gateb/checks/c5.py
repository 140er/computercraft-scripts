from .mining import analyze, criteria, cold_cells, audit_dug

TITLE = "Two-miner lane and branch completion"


def evaluate(data):
    c = criteria(data)
    c.require(data.get("observed_game_seconds", 0) >= 600, "Observe at least 600 game seconds")
    return c.finish(data)


def run(ctx):
    ctx.measure_game_clock = True
    cold = cold_cells(ctx, "C5")
    ctx.mining()
    miners = [ctx.computer(n) for n in ("miner1", "miner2")]
    def done(rows):
        data = analyze(rows, miners, ctx.tick_rate)
        return bool(data["range_samples"] or data["collisions"] or data["stalled_miners"] or data["observed_game_seconds"] >= 600)
    rows = ctx.sample("C5-samples.jsonl", ctx.game_seconds(600) + 30, done)
    data = analyze(rows, miners, ctx.tick_rate)
    data["previously_dug_cells"] = audit_dug(rows, miners, cold)
    data["prior_dug_coverage"] = "cold marks audited" if cold else "not triggered; covered by unit tests"
    data["conditional_yield"] = ("naturally triggered; observed in samples" if any(t.get("yield") for r in rows for t in r["mine"].get("turtles", {}).values())
                                 else "not triggered; covered by unit tests")
    return evaluate(ctx.record("C5-observations.json", data))
