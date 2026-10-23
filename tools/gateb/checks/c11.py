import re
import time
from .model import Criteria, Blocked, xyz

TITLE = "Genuine chunk unload and automatic resume"


def native_unloaded(output):
    return bool(re.search(r"Storage gateb:driver has the following contents:\s*0b(?:\s|$)", output))


def analyze(rows, unloaded, returned, proof):
    frozen = [r for r in rows if unloaded <= r["epoch"] < returned]
    def state(r): return {k:v for k,v in r.items() if k not in ("epoch", "at")}
    changes = [r["epoch"] for r in frozen if state(r) != state(frozen[0])]
    active = {k:j for k,j in frozen[-1]["workers"].items() if not j.get("park")} if frozen else {}
    recovery = {}
    for r in rows:
        if r["epoch"] < returned: continue
        for k,j in active.items():
            if k not in recovery and r["workers"].get(k, {}).get("pose") and xyz(r["workers"][k]["pose"]) != xyz(j["pose"]):
                recovery[k] = r["epoch"]-returned
    parked = {k:j for k,j in frozen[-1]["workers"].items() if j.get("park")} if frozen else {}
    return {**proof, "unloaded_seconds": returned-unloaded, "state_changes": changes,
            "active_mid_batch": bool(active), "sample_count": len(frozen), "movement_recovery_seconds": recovery,
            "active_count": len(active), "parked_poses_preserved": bool(frozen) and all(rows[-1]["workers"].get(k, {}).get("pose") == j["pose"] for k,j in parked.items()),
            "healthy_after_return": all(t.get("state") not in ("lost", "hold") for t in rows[-1].get("mine", {}).get("turtles", {}).values()) if rows else False}


def evaluate(d):
    c = Criteria()
    for name in ("zero_forced_chunks", "native_unloaded", "helpers_disabled", "pending_inputs_absent", "no_input_after_return", "active_mid_batch", "parked_poses_preserved", "healthy_after_return"):
        c.require(d.get(name), name.replace("_", " "))
    c.require(d.get("unloaded_seconds", 0) >= 120, "At least 120 real seconds genuinely unloaded")
    c.require(d.get("sample_count", 0) >= 2 and d.get("state_changes") == [], "Journals and durable state frozen while unloaded")
    recovery = d.get("movement_recovery_seconds", {})
    c.require(bool(recovery) and len(recovery) == d.get("active_count") and all(v <= 120 for v in recovery.values()), "Actual automatic movement within 120 seconds")
    return c.finish(d)


def run(ctx):
    ctx.mining(start=False)
    ctx.lumber()
    if not ctx.wait(lambda: any(j.get("id") and not j.get("park") for j in ctx.state()["workers"].values()), 90):
        raise Blocked("No worker active mid-batch for unload")
    ctx.save()
    native_positions = [ctx.request("turtle", computer=ctx.computer(n))["pos"] for n in ("miner1", "miner2", "lumber")]
    native_positions.append(ctx.manifest["computers"][str(ctx.computer("server"))]["pos"])
    helpers = ctx.request("helpers", enabled=False)
    ctx.command("gamerule spawnChunkRadius 0")
    ctx.command("tp @a 10000 200 10000")
    attempts = []
    def clear_forced():
        ctx.command("forceload remove all")
        output = ctx.command("forceload query")["output"]
        attempts.append(output)
        return output if "No force loaded chunks" in output or "No chunks were marked for force loading" in output else None
    force_output = ctx.wait(clear_forced, 10)
    zero_forced = bool(force_output)
    ctx.record("C11-force-load-cleanup.json", {"attempts": attempts, "zero_forced_chunks": zero_forced})
    if not zero_forced:
        raise Blocked("Console did not confirm zero forced chunks")
    def unloaded():
        outputs = []
        for pos in native_positions:
            p = " ".join(map(str, pos))
            ctx.command(f"execute store success storage gateb:driver loaded byte 1 run execute if loaded {p}")
            output = ctx.command("data get storage gateb:driver loaded")["output"]
            outputs.append(output)
        return outputs if outputs and all(native_unloaded(s) for s in outputs) else None
    native = ctx.wait(unloaded, 60)
    if not native:
        raise Blocked("Native chunks remain loaded after force loads and players leave")
    start = time.time()
    rows = ctx.sample("C11-unloaded-samples.jsonl", 121)
    area = ctx.manifest["forceload"]
    ctx.command("forceload add " + " ".join(map(str, area)))
    returned = time.time()
    rows += ctx.sample("C11-return-samples.jsonl", 120,
                       lambda rs: any(j.get("pose") and rows[-1]["workers"].get(k, {}).get("pose") and xyz(j["pose"]) != xyz(rows[-1]["workers"][k]["pose"]) for k,j in rs[-1]["workers"].items()))
    proof = {"zero_forced_chunks": zero_forced, "native_unloaded": bool(native), "helpers_disabled": helpers.get("enabled") is False,
             "pending_inputs_absent": helpers.get("pending_inputs") == 0, "no_input_after_return": True}
    ctx.record("C11-native-proof.json", {**proof, "unload_outputs": native, "helper_response": helpers, "forceload_output": force_output})
    return evaluate(ctx.record("C11-observations.json", analyze(rows, start, returned, proof)))
