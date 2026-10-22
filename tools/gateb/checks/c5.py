from .mining import analyze, criteria

TITLE = "Two-miner lane and branch completion"


def evaluate(data):
    return criteria(data).finish(data)


def run(ctx):
    ctx.mining()
    miners = [ctx.computer(n) for n in ("miner1", "miner2")]
    def done(rows):
        data = analyze(rows, miners, ctx.tick_rate)
        return bool(data["range_samples"] or data["collisions"] or len(data["completed_miners"]) == 2)
    rows = ctx.sample("C5-samples.jsonl", ctx.game_seconds(600), done)
    data = analyze(rows, miners, ctx.tick_rate)
    data["conditional_yield"] = "not triggered; covered by unit tests"
    return evaluate(ctx.record("C5-observations.json", data))
