from .model import Criteria, values, xyz


def analyze(rows, miners, tick_rate=20):
    ranges, collisions, errors, branches = [], [], [], set()
    first, second = map(str, miners)
    lane_cells, left, granted = set(), None, None
    was_in_lane = False
    left_clock, granted_clock = None, None
    for row in rows:
        turtles = row.get("mine", {}).get("turtles", {})
        positions = []
        for ident in (first, second):
            turtle = turtles.get(ident, {})
            if turtle.get("state") == "range": ranges.append(row["epoch"])
            if turtle.get("state") in ("lost", "hold") or turtle.get("error"):
                errors.append(f"{ident}: {turtle.get('error', turtle.get('state'))}")
            if turtle.get("pose"): positions.append(xyz(turtle["pose"]))
            if turtle.get("counted") is not None: branches.add(ident)
        if len(positions) == 2 and positions[0] == positions[1]: collisions.append(row["epoch"])
        a, b = turtles.get(first, {}), turtles.get(second, {})
        lane_cells.update(xyz(p) for p in values(a.get("lane", {}).get("cells")))
        if a.get("pose") and lane_cells:
            inside = xyz(a["pose"]) in lane_cells
            if inside: was_in_lane = True
            if was_in_lane and not inside and left is None:
                left = row["epoch"]
                left_clock = row.get("game_ms", row["epoch"] * 1000 * tick_rate / 20)
        if left is not None and granted is None and b.get("lane"):
            granted = row["epoch"]
            granted_clock = row.get("game_ms", row["epoch"] * 1000 * tick_rate / 20)
    elapsed = max(0, rows[-1]["epoch"] - rows[0]["epoch"]) if rows else 0
    game_elapsed = ((rows[-1]["game_ms"] - rows[0]["game_ms"]) / 1000
                    if rows and all("game_ms" in r for r in (rows[0], rows[-1])) else elapsed * tick_rate / 20)
    return {"observed_wall_seconds": round(elapsed, 3), "observed_game_seconds": round(game_elapsed, 3),
            "range_samples": len(ranges), "collisions": len(collisions), "errors": sorted(set(errors)),
            "completed_miners": sorted(branches), "lane_left_epoch": left, "lane_granted_epoch": granted,
            "handoff_game_seconds": None if granted is None else max(0, granted_clock-left_clock) / 1000}


def criteria(data):
    c = Criteria()
    c.require(data.get("range_samples") == 0 if "range_samples" in data else None, "No miner enters range")
    c.require(data.get("collisions") == 0 if "collisions" in data else None, "No turtle collision")
    c.require(not data["errors"] if "errors" in data else None, "No mining errors, holds or lost workers")
    c.require(len(data.get("completed_miners", [])) == 2, "Both miners complete a branch")
    handoff = data.get("handoff_game_seconds")
    c.require(handoff <= 30.5 if handoff is not None else None, "Second miner gets lane within about 30 game seconds after first exits lane cells")
    return c
