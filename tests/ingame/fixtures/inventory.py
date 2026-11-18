"""Fill containers and read exact stack counts back through data get block."""

import json
from pathlib import Path

from .errors import FixtureError, ensure_ok
from .ids import block_pos, count, dimension, resource, run, slot, xyz
from .snbt import SnbtError, item_rows, parse_data_reply


def fill_container(session, pos, stacks, dimension_id="minecraft:overworld"):
    """Replace slots with the given stacks. Item ids are caller data, including modded ids."""
    pos = xyz(pos)
    dimension_id = dimension(dimension_id)
    normalized = [_stack(entry) for entry in stacks]
    seen = set()
    for entry in normalized:
        if entry["slot"] in seen:
            raise FixtureError("duplicate slot %s" % entry["slot"])
        seen.add(entry["slot"])
    replies = []
    for entry in normalized:
        command = run(dimension_id, "item replace block %s container.%s with %s %s" % (
            block_pos(pos), entry["slot"], entry["id"], entry["count"]))
        reply = ensure_ok(session.command(command), command)
        if "Replaced" not in reply and "Changed the block" not in reply:
            raise FixtureError("slot was not replaced: %s" % reply.strip(), command, reply)
        replies.append(reply)
    found = read_container(session, pos, dimension_id)
    _expect_stacks(found, normalized)
    return {"pos": list(pos), "dimension": dimension_id, "items": found["items"]}


def read_container(session, pos, dimension_id="minecraft:overworld"):
    pos = xyz(pos)
    dimension_id = dimension(dimension_id)
    command = run(dimension_id, "data get block %s" % block_pos(pos))
    reply = ensure_ok(session.command(command), command)
    if "not a block entity" in reply:
        return {"pos": list(pos), "dimension": dimension_id, "block": None, "items": [], "present": False}
    try:
        parsed = parse_data_reply(reply)
    except SnbtError as exc:
        raise FixtureError("could not parse container data: %s" % exc, command, reply) from exc
    block_id, rows = item_rows(parsed)
    if rows is None and block_id is None:
        raise FixtureError("container reply had no compound: %s" % reply.strip()[:500], command, reply)
    return {
        "pos": list(pos),
        "dimension": dimension_id,
        "block": block_id,
        "items": rows,
        "present": True,
    }


def read_region(session, corner_a, corner_b, dimension_id="minecraft:overworld", limit=8000):
    """Read every block entity with an Items tag inside the box, inclusive."""
    start = xyz(corner_a)
    end = xyz(corner_b)
    dimension_id = dimension(dimension_id)
    positions = list(_box(start, end))
    if len(positions) > limit:
        raise FixtureError("region has %s blocks, above the %s limit" % (len(positions), limit))
    containers = []
    for pos in positions:
        command = run(dimension_id, "data get block %s" % block_pos(pos))
        reply = session.command(command)
        if "not loaded" in reply or "currently loaded" in reply:
            raise FixtureError("chunk is not loaded at %s" % block_pos(pos), command, reply)
        if "not a block entity" in reply:
            continue
        ensure_ok(reply, command)
        if "has the following block entity data" not in reply and "{" not in reply:
            continue
        try:
            parsed = parse_data_reply(reply)
        except SnbtError as exc:
            raise FixtureError("could not parse block data at %s: %s" % (block_pos(pos), exc), command, reply) from exc
        if not isinstance(parsed, dict):
            continue
        block_id, rows = item_rows(parsed)
        if not _container(block_id) and "Items" not in parsed and "items" not in parsed:
            continue
        containers.append({
            "pos": list(pos),
            "block": block_id,
            "items": rows,
        })
    return {
        "dimension": dimension_id,
        "min": [min(start[i], end[i]) for i in range(3)],
        "max": [max(start[i], end[i]) for i in range(3)],
        "containers": containers,
    }


def diff_counts(before, after):
    """Pair stacks by position, slot, item id and component fingerprint."""
    before_rows = _indexed(before)
    after_rows = _indexed(after)
    keys = sorted(set(before_rows) | set(after_rows), key=_sort_key)
    rows = []
    for key in keys:
        left = before_rows.get(key)
        right = after_rows.get(key)
        before_count = 0 if left is None else left["count"]
        after_count = 0 if right is None else right["count"]
        pos, slot, item_id, fingerprint = key
        rows.append({
            "pos": list(pos),
            "block": (right or left)["block"],
            "slot": slot,
            "id": item_id,
            "components": None if fingerprint == "" else json.loads(fingerprint),
            "before": before_count,
            "after": after_count,
            "delta": after_count - before_count,
        })
    totals = {}
    for row in rows:
        bucket = totals.setdefault(row["id"], {"id": row["id"], "before": 0, "after": 0})
        bucket["before"] += row["before"]
        bucket["after"] += row["after"]
    for bucket in totals.values():
        bucket["delta"] = bucket["after"] - bucket["before"]
    return {
        "rows": rows,
        "totals": [totals[key] for key in sorted(totals)],
        "empty": _empty(after if after is not None else before),
        "containers_before": len(before.get("containers", [])),
        "containers_after": len(after.get("containers", [])),
    }


def write_counts(before, after, json_path, markdown_path):
    table = diff_counts(before, after) if after is not None else _single(before)
    payload = {"before": before, "after": after, "table": table}
    destination = Path(json_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    Path(markdown_path).write_text(_markdown(table), encoding="utf-8")
    return table


def _container(block_id):
    if not block_id:
        return False
    if block_id in {
        "minecraft:chest", "minecraft:trapped_chest", "minecraft:barrel",
        "minecraft:hopper", "minecraft:dropper", "minecraft:dispenser",
        "minecraft:furnace", "minecraft:blast_furnace", "minecraft:smoker",
        "computercraft:turtle_normal", "computercraft:turtle_advanced",
    }:
        return True
    return block_id.endswith("shulker_box")


def _stack(entry):
    if not isinstance(entry, dict):
        raise FixtureError("a stack is an object with slot, id and count")
    return {
        "slot": slot(entry.get("slot")),
        "id": resource(entry.get("id"), "item"),
        "count": count(entry.get("count")),
    }


def _expect_stacks(found, expected):
    actual = {(row["slot"], row["id"]): row["count"] for row in found["items"]}
    for entry in expected:
        key = (entry["slot"], entry["id"])
        if actual.get(key) != entry["count"]:
            raise FixtureError(
                "slot %s %s read back %s, expected %s" % (entry["slot"], entry["id"], actual.get(key), entry["count"]))


def _box(start, end):
    for x in range(min(start[0], end[0]), max(start[0], end[0]) + 1):
        for y in range(min(start[1], end[1]), max(start[1], end[1]) + 1):
            for z in range(min(start[2], end[2]), max(start[2], end[2]) + 1):
                yield (x, y, z)


def _fingerprint(components):
    if not components:
        return ""
    return json.dumps(components, sort_keys=True, separators=(",", ":"))


def _indexed(snapshot):
    rows = {}
    for container in snapshot.get("containers", []):
        pos = tuple(container["pos"])
        for item in container.get("items", []):
            key = (pos, item["slot"], item["id"], _fingerprint(item.get("components")))
            rows[key] = {
                "count": item["count"],
                "block": container.get("block"),
            }
    return rows


def _sort_key(key):
    pos, slot, item_id, fingerprint = key
    return (pos[0], pos[1], pos[2], -1 if slot is None else slot, item_id, fingerprint)


def _empty(snapshot):
    found = []
    for container in snapshot.get("containers", []):
        if container.get("items"):
            continue
        found.append({"pos": list(container["pos"]), "block": container.get("block")})
    found.sort(key=lambda row: (row["pos"][0], row["pos"][1], row["pos"][2], row["block"] or ""))
    return found


def _single(snapshot):
    diff = diff_counts(snapshot, snapshot)
    for row in diff["rows"]:
        row["after"] = None
        row["delta"] = None
    for bucket in diff["totals"]:
        bucket["after"] = None
        bucket["delta"] = None
    return diff


def _markdown(table):
    lines = [
        "# Container counts",
        "",
        "| x | y | z | block | slot | item | before | after | delta |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    if not table["rows"]:
        lines.append("|  |  |  |  |  |  |  |  |  |")
    for row in table["rows"]:
        x, y, z = row["pos"]
        after = "" if row["after"] is None else str(row["after"])
        delta = "" if row["delta"] is None else str(row["delta"])
        lines.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            x, y, z, row["block"] or "", "" if row["slot"] is None else row["slot"],
            row["id"], row["before"], after, delta))
    lines.extend(["", "# Item totals", "", "| item | before | after | delta |", "| --- | --- | --- | --- |"])
    for bucket in table["totals"]:
        after = "" if bucket["after"] is None else str(bucket["after"])
        delta = "" if bucket["delta"] is None else str(bucket["delta"])
        lines.append("| %s | %s | %s | %s |" % (bucket["id"], bucket["before"], after, delta))
    lines.extend(["", "# Empty containers", "", "| x | y | z | block |", "| --- | --- | --- | --- |"])
    if not table.get("empty"):
        lines.append("|  |  |  |  |")
    for container in table.get("empty", []):
        x, y, z = container["pos"]
        lines.append("| %s | %s | %s | %s |" % (x, y, z, container["block"] or ""))
    lines.append("")
    return "\n".join(lines)
