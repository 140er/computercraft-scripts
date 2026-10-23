from .model import Criteria, Blocked, xyz

TITLE = "Full ore and empty fuel recovery"

MAX_PASS_GAME_SECONDS = 300
RESUME_GAME_SECONDS = 30.5
REPAIR_GAME_SECONDS = 90


def evaluate(d):
    c = Criteria()
    for kind in ("ore", "fuel"):
        fault = d.get(kind, {})
        c.require(fault.get("alerts") == 1 if "alerts" in fault else None, f"One alert for {kind} fault")
        c.require(fault.get("parked"), f"Worker parks during {kind} fault")
        retries = fault.get("retry_game_seconds")
        c.require(bool(retries) and all(55 <= n <= 70 for n in retries) if retries is not None else None, f"{kind} retries every minute of game time")
        repaired = fault.get("repair_observed_game_seconds")
        c.require(repaired <= REPAIR_GAME_SECONDS if repaired is not None else None, f"{kind} repair observed within retry window")
        resume = fault.get("resume_after_lane_game_seconds")
        c.require(resume <= RESUME_GAME_SECONDS if resume is not None else False, f"{kind} moves within about 30 game seconds of lane availability")
        wait = fault.get("lane_wait_game_seconds")
        c.require(wait <= MAX_PASS_GAME_SECONDS if wait is not None else False, f"{kind} lane wait bounded by one competing pass")
        passes = fault.get("competing_passes")
        c.require(passes <= 1 if passes is not None else None, f"{kind} waiter is not bypassed by another lane pass")
    return c.finish(d)


def resume_stats(rows, affected, repair):
    previous_pose = rows[0]["workers"].get(affected, {}).get("pose")
    baseline = None
    ready, available, moved = None, None, None
    passes, previous_holders = 0, set()
    for row in rows:
        at = row["game_ms"]
        miners = row["mine"].get("turtles", {})
        worker = miners.get(affected, {})
        pose = row["workers"].get(affected, {}).get("pose")
        if ready is None and affected in miners and not worker.get("dropRetry"):
            ready = at
        if ready is None:
            previous_pose = pose
            continue
        holders = {ident for ident, peer in miners.items() if ident != affected and peer.get("lane")}
        passes += len(holders - previous_holders)
        previous_holders = holders
        if available is None and (worker.get("lane") or not holders):
            available = at
            baseline = previous_pose or pose
        if available is not None and pose and baseline and xyz(pose) != xyz(baseline):
            moved = at
            break
        previous_pose = pose
    return {"repair_observed_game_seconds": (ready - repair) / 1000 if ready is not None else None,
            "lane_available_game_ms": available,
            "lane_wait_game_seconds": (available - ready) / 1000 if available is not None else None,
            "competing_passes": passes,
            "resume_after_lane_game_seconds": (moved - available) / 1000 if moved is not None else None,
            "resume_game_seconds": (moved - repair) / 1000 if moved is not None else None}


def run(ctx):
    ore = " ".join(map(str, ctx.fixture("ore")["pos"]))
    fuel = " ".join(map(str, ctx.fixture("fuel")["pos"]))
    items = ",".join(f'{{Slot:{i}b,id:"minecraft:stone",count:64}}' for i in range(27))
    ctx.command(f"data modify block {ore} Items set value [{items}]")
    faults = {}
    for kind, message in (("ore", "ore chest full"), ("fuel", "fuel chest empty")):
        if kind == "fuel":
            ctx.cli("reset", ctx.run)
            installed = ctx.cli("install", ctx.run, ctx.commit, "--mode", "copy")
            ctx.record("C8-fuel-installed-build.json", installed)
            if installed.get("errors"):
                raise Blocked("Cannot restore the exact build for the fuel fault")
            ctx.wait(lambda: ctx.lua("server", "return SO ~= nil"), 60)
            ctx.command(f"tick rate {ctx.tick_rate:g}")
            ctx.set_fuel("miner1", 100)
            ctx.command(f"data modify block {fuel} Items set value []")
        ctx.mining()
        def has_fault(rows):
            return any(t.get("dropRetry", {}).get("tries", 0) >= 5 and message in t.get("error", "") for t in rows[-1]["mine"].get("turtles", {}).values())
        rows = ctx.sample(f"C8-{kind}-fault-samples.jsonl", ctx.game_seconds(600), has_fault)
        matching = [(r.get("game_ms", r["epoch"] * 1000 * ctx.tick_rate / 20) / 1000, ident, t) for r in rows for ident,t in r["mine"].get("turtles", {}).items() if message in t.get("error", "")]
        affected = matching[0][1] if matching else None
        retries = []
        last_tries, last_at = None, None
        for at,ident,t in matching:
            if ident != affected: continue
            tries = t.get("dropRetry", {}).get("tries")
            if tries is not None and tries != last_tries:
                if last_at is not None: retries.append(at-last_at)
                last_tries,last_at = tries,at
        events = ctx.lua("server", 'local out={};local seq=0;while true do local page=SO.mods.state.history.page({from=seq,count=50}); for _,e in ipairs(page.entries) do out[#out+1]=e;seq=e.seq end; if not page.next then break end end;return out')
        count = sum(e.get("kind") == "mine.alert" and message in str(e.get("data", {})) for e in (events.values() if isinstance(events, dict) else events or []))
        repair = ctx.game_clock()
        if kind == "ore": ctx.command(f"data modify block {ore} Items set value []")
        else: ctx.command(f'data modify block {fuel} Items set value [{{Slot:0b,id:"minecraft:coal",count:64}},{{Slot:1b,id:"minecraft:coal",count:64}}]')
        ctx.measure_game_clock = True
        resumed = ctx.sample(f"C8-{kind}-resume-samples.jsonl",
                             ctx.game_seconds(REPAIR_GAME_SECONDS + MAX_PASS_GAME_SECONDS + RESUME_GAME_SECONDS),
                             lambda rs: resume_stats(rs, affected, repair)["resume_game_seconds"] is not None)
        faults[kind] = {"alerts": count, "parked": bool(matching) and any(r["workers"].get(affected, {}).get("park") for r in rows),
                        "retry_game_seconds": retries, **resume_stats(resumed, affected, repair)}
    return evaluate(ctx.record("C8-observations.json", faults))
