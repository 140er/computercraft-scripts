from .model import Blocked, Criteria, values, world_pose, lumber_workers

TITLE = "Lumber harvest and replant"


def evaluate(d):
    c = Criteria()
    c.require(d.get("logs_delivered", 0) > 0, "Real logs delivered")
    c.require(d.get("replanted", 0) >= 4, "Four trees felled and replanted")
    c.require(d.get("dug_count", 0) > 0, "Successful digs observed")
    c.require(d.get("unsafe_digs") == [] if "unsafe_digs" in d else None, "Only known stem and canopy cells dug; ground and stone untouched")
    return c.finish(d)


def run(ctx):
    try:
        proof = ctx.runtime.farm_allowlist()
    except (OSError, ValueError, KeyError) as error:
        raise Blocked(f"Cannot read cold farm tree blocks: {error}") from None
    ctx.record("C6-cold-allowed-cells.json", proof)
    allowed = {tuple(b["pos"]) for b in proof["blocks"]}
    if not allowed:
        raise Blocked("Cold farm template has no native stem/canopy cells")
    before = ctx.count_items("wood", "_log")
    ctx.lumber()
    rows = ctx.sample("C6-samples.jsonl", ctx.game_seconds(600),
                      lambda rs: sum(bool(s.get("plantedAt")) for s in rs[-1]["lumber"].get("spots", {}).values()) >= 4 and ctx.count_items("wood", "_log") > before)
    dug = set()
    for r in rows:
        frame = lumber_workers(r["lumber"], ctx.computer("lumber")).get(str(ctx.computer("lumber")), {}).get("frame")
        if frame:
            for p in values(r["workers"].get(str(ctx.computer("lumber")), {}).get("dug")):
                dug.add(world_pose(p, frame))
    d = {"logs_delivered": ctx.count_items("wood", "_log") - before,
         "replanted": sum(bool(s.get("plantedAt")) for s in rows[-1]["lumber"].get("spots", {}).values()),
         "dug_count": len(dug), "unsafe_digs": sorted(dug - allowed)}
    return evaluate(ctx.record("C6-observations.json", d))
