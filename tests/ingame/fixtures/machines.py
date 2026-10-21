"""Place computers, turtles, modems and cooking blocks with setblock NBT."""

from .errors import FixtureError, ensure_ok
from .ids import block_pos, computer_id, dimension, facing, resource, run, xyz

COMPUTER_BLOCKS = {
    False: "computercraft:computer_normal",
    True: "computercraft:computer_advanced",
}
TURTLE_BLOCKS = {
    False: "computercraft:turtle_normal",
    True: "computercraft:turtle_advanced",
}
MODEM_BLOCKS = {
    "wireless_normal": "computercraft:wireless_modem_normal",
    "wireless_advanced": "computercraft:wireless_modem_advanced",
    "wired": "computercraft:wired_modem_full",
}
FURNACE_BLOCKS = {
    "furnace": "minecraft:furnace",
    "blast_furnace": "minecraft:blast_furnace",
    "smoker": "minecraft:smoker",
}
# Minecraft container slots are 0-based. The wh2 contract's slots 1, 2 and 3 are these plus one.
FURNACE_SLOTS = {"input": 0, "fuel": 1, "output": 2}


def place_computer(session, pos, computer, advanced=True, face="north", modem=None, modem_facing="down",
                   dimension_id="minecraft:overworld"):
    pos = xyz(pos)
    computer = computer_id(computer)
    face = facing(face)
    block = COMPUTER_BLOCKS[bool(advanced)]
    command = run(dimension_id, "setblock %s %s[facing=%s]{ComputerId:%s}" % (block_pos(pos), block, face, computer))
    _replace(session, dimension_id, pos, command)
    placed = {"pos": list(pos), "block": block, "computer_id": computer, "facing": face}
    if modem:
        above = (pos[0], pos[1] + 1, pos[2])
        placed["modem"] = place_modem(session, above, kind=modem, face=modem_facing, dimension_id=dimension_id)
    return placed


def place_turtle(session, pos, computer, advanced=True, face="north", fuel=0, left=None, right=None,
                 dimension_id="minecraft:overworld"):
    pos = xyz(pos)
    computer = computer_id(computer)
    face = facing(face)
    if isinstance(fuel, bool) or not isinstance(fuel, int) or fuel < 0 or fuel > 1000000:
        raise FixtureError("fuel must be an integer from 0 to 1000000")
    left = resource(left, "left upgrade") if left else None
    right = resource(right, "right upgrade") if right else None
    block = TURTLE_BLOCKS[bool(advanced)]
    parts = ["ComputerId:%s" % computer, "Fuel:%s" % fuel]
    if left:
        parts.append('LeftUpgrade:"%s"' % left)
    if right:
        parts.append('RightUpgrade:"%s"' % right)
    command = run(dimension_id, "setblock %s %s[facing=%s]{%s}" % (block_pos(pos), block, face, ",".join(parts)))
    _replace(session, dimension_id, pos, command)
    return {
        "pos": list(pos),
        "block": block,
        "computer_id": computer,
        "facing": face,
        "heading": {"north": 0, "east": 1, "south": 2, "west": 3}[face],
        "fuel": fuel,
        "left": left,
        "right": right,
    }


def place_modem(session, pos, kind="wireless_advanced", face="down", dimension_id="minecraft:overworld"):
    pos = xyz(pos)
    if kind not in MODEM_BLOCKS:
        raise FixtureError("modem kind must be wireless_normal, wireless_advanced or wired")
    block = MODEM_BLOCKS[kind]
    if kind == "wired":
        state = "%s[modem=true]" % block
    else:
        face = facing(face, ("north", "south", "east", "west", "up", "down"))
        state = "%s[facing=%s]" % (block, face)
    command = run(dimension_id, "setblock %s %s" % (block_pos(pos), state))
    _replace(session, dimension_id, pos, command)
    return {"pos": list(pos), "block": block, "kind": kind, "facing": face}


def place_furnace(session, pos, kind="furnace", face="north", dimension_id="minecraft:overworld"):
    pos = xyz(pos)
    if kind not in FURNACE_BLOCKS:
        raise FixtureError("furnace kind must be furnace, blast_furnace or smoker")
    face = facing(face)
    block = FURNACE_BLOCKS[kind]
    command = run(dimension_id, "setblock %s %s[facing=%s,lit=false]" % (block_pos(pos), block, face))
    _replace(session, dimension_id, pos, command)
    return {"pos": list(pos), "block": block, "kind": kind, "facing": face, "slots": dict(FURNACE_SLOTS)}


def _replace(session, dimension_id, pos, command):
    # setblock refuses a block that is already the same. Fill air first so a second run still changes the cell.
    clear = run(dimension_id, "fill %s %s minecraft:air" % (block_pos(pos), block_pos(pos)))
    reply = ensure_ok(session.command(clear), clear)
    if "filled" not in reply:
        raise FixtureError("cell was not cleared: %s" % reply.strip(), clear, reply)
    _changed(session, command)


def _changed(session, command):
    reply = ensure_ok(session.command(command), command)
    if "Changed the block" not in reply:
        raise FixtureError("block did not change: %s" % reply.strip(), command, reply)
    return reply
