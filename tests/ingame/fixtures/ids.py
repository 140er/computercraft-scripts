"""Resource-location checks shared by room, item and machine commands."""

import re

from .errors import FixtureError

RESOURCE = re.compile(r"^[a-z0-9_.-]+:[a-z0-9_./-]+$")
FACING = ("north", "south", "east", "west")
HEADING_OF = {"north": 0, "east": 1, "south": 2, "west": 3}
# nav.lua:3 and miner.lua:70. Index 0 is north, toward negative Z.
HEADING_VECTOR = ((0, -1), (1, 0), (0, 1), (-1, 0))


def resource(value, label):
    if not isinstance(value, str) or not RESOURCE.match(value):
        raise FixtureError("%s must be a namespaced id" % label)
    return value


def dimension(value):
    return resource(value or "minecraft:overworld", "dimension")


def facing(value, allowed=FACING):
    if value not in allowed:
        raise FixtureError("facing must be one of %s" % ", ".join(allowed))
    return value


def xyz(pos):
    if not isinstance(pos, (tuple, list)) or len(pos) != 3:
        raise FixtureError("position needs x, y and z")
    out = []
    for number in pos:
        if isinstance(number, bool) or not isinstance(number, int):
            raise FixtureError("coordinates must be integers")
        if number < -30000000 or number > 30000000:
            raise FixtureError("coordinate out of range")
        out.append(number)
    return tuple(out)


def count(value, upper=99):
    if isinstance(value, bool) or not isinstance(value, int) or value < 1 or value > upper:
        raise FixtureError("count must be an integer from 1 to %s" % upper)
    return value


def slot(value, upper=53):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > upper:
        raise FixtureError("slot must be an integer from 0 to %s" % upper)
    return value


def computer_id(value):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > 65535:
        raise FixtureError("computer id must be an integer from 0 to 65535")
    return value


def run(dimension_id, body):
    return "execute in %s run %s" % (dimension(dimension_id), body)


def block_pos(pos):
    x, y, z = xyz(pos)
    return "%s %s %s" % (x, y, z)
