from .model import Criteria, values, world_pose

TITLE = "Lumber harvest and replant"


def evaluate(d):
    c = Criteria()
    c.require(d.get("logs_delivered", 0) > 0, "Real logs delivered")
    c.require(d.get("replanted", 0) >= 4, "Four trees felled and replanted")
    c.require(d.get("dug_count", 0) > 0, "Successful digs observed")
    c.require(d.get("unsafe_digs") == [] if "unsafe_digs" in d else None, "Only known stem and canopy cells dug; ground and stone untouched")
    return c.finish(d)


def run(ctx):
    config = ctx.fixture("farm")
    allowed = {tuple(p) for p in config.get("dig_cells", [])}
    if not allowed:
        from .model import Blocked
        raise Blocked("Farm manifest must list native stem/canopy dig_cells to prove soil/stone safety")
    before = ctx.count_items("wood", "_log")
    ctx.lumber()
    rows = ctx.sample("C6-samples.jsonl", ctx.game_seconds(600),
                      lambda rs: sum(bool(s.get("plantedAt")) for s in rs[-1]["lumber"].get("spots", {}).values()) >= 4 and ctx.count_items("wood", "_log") > before)
    dug = set()
    for r in rows:
        frame = r["lumber"].get("turtle", {}).get("frame")
        if frame:
            for p in values(r["workers"].get(str(ctx.computer("lumber")), {}).get("dug")):
                dug.add(world_pose(p, frame))
    d = {"logs_delivered": ctx.count_items("wood", "_log") - before,
         "replanted": sum(bool(s.get("plantedAt")) for s in rows[-1]["lumber"].get("spots", {}).values()),
         "dug_count": len(dug), "unsafe_digs": sorted(dug - allowed)}
    return evaluate(ctx.record("C6-observations.json", d))
