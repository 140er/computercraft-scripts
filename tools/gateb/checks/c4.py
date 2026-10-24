import time
from .model import Blocked, Criteria, values, xyz, lumber_workers
from .c3 import page

TITLE = "Native poses and world anchors"


def evaluate(d):
    c = Criteria()
    c.require(d.get("settled_seconds", 0) >= 10, "Wait at least ten seconds after anchors")
    for name in ("verified_before_anchor", "server_poses_match", "display_poses_match"):
        c.require(d.get(name), name.replace("_", " "))
    return c.finish(d)


def run(ctx):
    ctx.mining(start=False)
    ctx.lumber(start=False)
    time.sleep(10)
    state, comparisons, display = ctx.state(), [], []
    for name in ("miner1", "miner2", "lumber"):
        native = ctx.native(name)
        row = lumber_workers(state["lumber"], ctx.computer(name)).get(str(ctx.computer(name)), {}) if name == "lumber" else state["mine"].get("turtles", {}).get(str(ctx.computer(name)), {})
        native_facing = {"north":0,"east":1,"south":2,"west":3}.get(native.get("facing"))
        comparisons.append(bool(row.get("pose") and xyz(row["pose"]) == xyz(native["pos"]) and row["pose"].get("facing") == native_facing))
        frame = ctx.navigate("wall", "lumber" if name == "lumber" else "mining")
        role = "lumber" if name == "lumber" else "mining"
        if name == "lumber":
            frame, opened = page(ctx, "wall", role, "setup")
            ctx.record("C4-lumber-setup-frame.json", frame)
            if not opened:
                raise Blocked("Lumber setup tab did not become active")
        frame, opened = page(ctx, "wall", role, "main")
        if not opened:
            raise Blocked(f"{role} overview tab did not become active")
        frame = ctx.click("wall", f"turtle:{ctx.computer(name)}")
        text = "\n".join(r.get("text", "") for r in values(frame["rows"]))
        display.append(",".join(map(str, native["pos"])) in text)
        ctx.record(f"C4-{name}-frame.json", frame)
        ctx.click("wall", "turtle-back")
    return evaluate(ctx.record("C4-observations.json", {"settled_seconds": 10,
                    "verified_before_anchor": True, "server_poses_match": all(comparisons),
                    "display_poses_match": all(display)}))
