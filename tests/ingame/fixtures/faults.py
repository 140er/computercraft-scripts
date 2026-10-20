"""Faults a Gate B scenario can inject while a job is running."""

import time

from .errors import FixtureError, ensure_ok
from .ids import block_pos, count, resource, run, xyz
from .inventory import fill_container


def fill_chest(session, pos, item="minecraft:cobblestone", stack_count=64, slots=27,
               dimension_id="minecraft:overworld"):
    """Fill every slot of a chest so a later drop has nowhere to land."""
    if isinstance(slots, bool) or not isinstance(slots, int) or slots < 1 or slots > 54:
        raise FixtureError("chest slots must be an integer from 1 to 54")
    stacks = [{"slot": index, "id": resource(item, "item"), "count": count(stack_count)} for index in range(slots)]
    filled = fill_container(session, pos, stacks, dimension_id)
    total = sum(row["count"] for row in filled["items"] if row["id"] == item)
    if total != stack_count * slots:
        raise FixtureError("filled chest total %s, expected %s" % (total, stack_count * slots))
    return {"pos": list(xyz(pos)), "item": item, "total": total, "slots": slots}


def empty_turtle_fuel(session, pos, dimension_id="minecraft:overworld"):
    """Set the turtle block Fuel tag to 0 and read it back."""
    pos = xyz(pos)
    before = _fuel(session, pos, dimension_id)
    command = run(dimension_id, "data merge block %s {Fuel:0}" % block_pos(pos))
    reply = ensure_ok(session.command(command), command)
    if "Modified" not in reply and "merged" not in reply.lower():
        raise FixtureError("fuel was not cleared: %s" % reply.strip(), command, reply)
    after = _fuel(session, pos, dimension_id)
    if after != 0:
        raise FixtureError("turtle fuel read back %s after the clear" % after)
    return {"pos": list(pos), "before": before, "after": after}


def remove_furnace(session, pos, dimension_id="minecraft:overworld"):
    """Replace a cooking block with air. Call this while a smelt job is in progress."""
    pos = xyz(pos)
    command = run(dimension_id, "setblock %s minecraft:air" % block_pos(pos))
    reply = ensure_ok(session.command(command), command)
    if "Changed the block" not in reply:
        raise FixtureError("furnace was not removed: %s" % reply.strip(), command, reply)
    check = run(dimension_id, "execute if block %s minecraft:air" % block_pos(pos))
    checked = session.command(check)
    if "Test passed" not in checked:
        raise FixtureError("furnace cell is not air: %s" % checked.strip(), check, checked)
    return {"pos": list(pos), "block": "minecraft:air"}


def unload_chunk(session, pos, dimension_id="minecraft:overworld", timeout=90, poll_seconds=2):
    """Remove the forceload ticket and wait until the chunk stops ticking."""
    pos = xyz(pos)
    command = run(dimension_id, "forceload remove %s %s" % (pos[0], pos[2]))
    reply = ensure_ok(session.command(command), command)
    deadline = time.monotonic() + timeout
    polls = []
    while True:
        probe = run(dimension_id, "execute if loaded %s run time query gametime" % block_pos(pos))
        probed = session.command(probe)
        loaded = probed.startswith("The time is ")
        polls.append({"loaded": loaded, "reply": probed.strip()})
        if not loaded:
            return {"pos": list(pos), "unloaded": True, "forceload": reply.strip(), "polls": len(polls)}
        if time.monotonic() >= deadline:
            return {"pos": list(pos), "unloaded": False, "forceload": reply.strip(), "polls": len(polls), "last": probed.strip()}
        time.sleep(poll_seconds)


def request_restart(session, callback, reason=""):
    """Flush the world, then let the caller restart the server.

    The callback owns the process. A remote host can reboot itself there.
    The next command on this session opens a new RCON connection.
    """
    if not callable(callback):
        raise FixtureError("restart callback is required")
    if not isinstance(reason, str):
        raise FixtureError("restart reason must be a string")
    session.marker("restart requested %s" % reason)
    flush = session.command("save-all flush", timeout=120)
    ensure_ok(flush, "save-all flush")
    session.close()
    callback()
    return {"reason": reason, "flush": flush.strip()}


def _fuel(session, pos, dimension_id):
    command = run(dimension_id, "data get block %s Fuel" % block_pos(pos))
    reply = ensure_ok(session.command(command), command)
    digits = []
    for token in reply.replace(",", " ").split():
        if token.lstrip("-").isdigit():
            digits.append(int(token))
    if not digits:
        raise FixtureError("fuel reply had no integer: %s" % reply.strip(), command, reply)
    return digits[-1]
