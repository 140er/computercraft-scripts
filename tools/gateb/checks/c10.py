import time
from .model import Criteria, own_path, values, world_pose, xyz

TITLE = "Active outage and own-path recovery"


def analyze(before, rows, off, boot):
    workers = before["workers"]
    frames = {k: (before["mine"]["turtles"][k]["frame"] if k in before["mine"].get("turtles", {}) else before["lumber"]["turtle"]["frame"]) for k in workers}
    allowed = {k: own_path(j, frames[k]) for k,j in workers.items()}
    outside, collisions, duplicates, recovered = [], [], [], {}
    retreat = {k:set() for k in workers}
    outage_samples = 0
    seen, previous = {}, {}
    last_off = {k:j["pose"] for k,j in workers.items()}
    for row in rows:
        if off+5 < row["epoch"] < boot: outage_samples += 1
        positions = {k: world_pose(j["pose"], frames[k]) for k,j in row["workers"].items() if k in frames and j.get("pose")}
        if len(set(positions.values())) < len(positions): collisions.append(row["epoch"])
        for k,p in positions.items():
            if row["epoch"] <= off + 5: allowed[k].add(p)
            elif row["epoch"] < boot and p not in allowed[k]: outside.append({"worker":k,"pos":p})
            if off+5 < row["epoch"] < boot: retreat[k].add(p)
            j = row["workers"][k]
            if row["epoch"] < boot: last_off[k] = j["pose"]
            elif k not in recovered and j.get("id") != workers[k].get("id") and not j.get("park") and xyz(j["pose"]) != xyz(last_off[k]):
                recovered[k] = row["epoch"]-boot
            if k not in before["mine"].get("turtles", {}): continue
            current = {world_pose(p, frames[k]) for p in values(j.get("dug"))}
            if k in previous:
                duplicates.extend({"worker":k,"pos":p} for p in current-previous[k] if p in seen[k])
                seen[k].update(current)
            else: seen[k] = set(current)
            previous[k] = current
    return {"off_seconds": boot-off, "active_workers": len(workers) == 3 and all(not j.get("park") for j in workers.values()),
            "outside_own_path": outside, "collisions": collisions, "duplicate_digs": duplicates,
            "movement_recovery_seconds": recovered, "worker_count": len(workers), "outage_samples": outage_samples,
            "retreat_observed": all(len(positions) > 1 for positions in retreat.values())}


def evaluate(d):
    c = Criteria()
    c.require(d.get("off_seconds", 0) >= 180, "Active server outage lasts at least 180 real seconds")
    c.require(d.get("active_workers"), "All three workers active before outage")
    c.require(d.get("outage_samples", 0) >= 2, "Multiple outage samples recorded")
    c.require(d.get("retreat_observed"), "Each active worker retreats along its path")
    for key in ("outside_own_path", "collisions", "duplicate_digs"):
        c.require(not d[key] if key in d else None, key.replace("_", " ") + " absent")
    recovery = d.get("movement_recovery_seconds", {})
    c.require(len(recovery) == d.get("worker_count", 3) and bool(recovery) and all(v <= 60 for v in recovery.values()), "Every worker actually moves within 60 seconds after reboot")
    return c.finish(d)


def run(ctx):
    ctx.mining(); ctx.lumber()
    if not ctx.wait(lambda: len(ctx.state()["workers"]) == 3 and all(j.get("id") and not j.get("park") for j in ctx.state()["workers"].values()), 90):
        return evaluate({"active_workers": False})
    before = ctx.record("C10-before.json", ctx.state())
    ctx.power("server", "off"); off = time.time()
    try:
        rows = ctx.sample("C10-off-samples.jsonl", 181)
    finally:
        ctx.power("server", "on")
    boot = time.time()
    rows += ctx.sample("C10-return-samples.jsonl", 60)
    return evaluate(ctx.record("C10-observations.json", analyze(before, rows, off, boot)))
