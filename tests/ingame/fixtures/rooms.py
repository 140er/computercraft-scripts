"""Warehouse rooms with a floor, walls, a door and a drop-off chest."""

from .errors import FixtureError, ensure_ok
from .ids import HEADING_OF, HEADING_VECTOR, block_pos, resource, run, xyz

SHAPES = ("rect", "l", "notched")
FILL_LIMIT = 32768


class RoomSpec:
    def __init__(self, name, origin, width, depth, height, shape="rect", notch=None,
                 wall="minecraft:stone_bricks", floor="minecraft:smooth_stone",
                 door="minecraft:oak_door", dropoff="minecraft:chest",
                 dimension="minecraft:overworld"):
        if not isinstance(name, str) or name.strip() == "" or any(char in name for char in "\r\n"):
            raise FixtureError("room name is required")
        self.name = name.strip()
        self.origin = xyz(origin)
        self.width = _span(width, "width")
        self.depth = _span(depth, "depth")
        self.height = _span(height, "height", lower=2, upper=24)
        self.shape = shape.lower() if isinstance(shape, str) else shape
        if self.shape not in SHAPES:
            raise FixtureError("room shape must be rect, l or notched")
        self.notch = _notch(self.shape, self.width, self.depth, notch)
        self.wall = resource(wall, "wall")
        self.floor = resource(floor, "floor")
        self.door = resource(door, "door")
        self.dropoff = resource(dropoff, "drop-off")
        self.dimension = resource(dimension, "dimension")


def plan_room(spec):
    """Return interior cells, the door, the drop-off and the commands that build them."""
    if not isinstance(spec, RoomSpec):
        raise FixtureError("plan_room expects a RoomSpec")
    x0, y, z0 = spec.origin
    interior = _interior(x0, z0, spec.width, spec.depth, spec.notch)
    walls = set()
    for x, z in interior:
        for dx, dz in ((0, -1), (0, 1), (-1, 0), (1, 0)):
            neighbor = (x + dx, z + dz)
            if neighbor not in interior:
                walls.add(neighbor)
    door_column = _door_column(interior)
    door = (door_column[0], y, door_column[1])
    door_upper = (door[0], y + 1, door[2])
    drop_column, access_column = _dropoff_column(interior, door_column)
    drop = (drop_column[0], y, drop_column[1])
    access = (access_column[0], y, access_column[1])
    heading = HEADING_OF["east"] if drop[0] > access[0] else (
        HEADING_OF["west"] if drop[0] < access[0] else (
            HEADING_OF["south"] if drop[2] > access[2] else HEADING_OF["north"]))
    vx, vz = HEADING_VECTOR[heading]
    if (access[0] + vx, access[2] + vz) != (drop[0], drop[2]):
        raise FixtureError("drop-off access heading does not face the chest")
    floor_cells = {(x, y - 1, z) for x, z in interior}
    floor_cells.update((x, y - 1, z) for x, z in walls)
    floor_cells.add((door[0], y - 1, door[2] - 1))
    wall_blocks = []
    for x, z in sorted(walls):
        for dy in range(spec.height):
            block = (x, y + dy, z)
            if block == door or block == door_upper or block == drop:
                continue
            wall_blocks.append(block)
    solids = list(floor_cells) + wall_blocks + [door, door_upper, drop]
    mins = [min(block[i] for block in solids) for i in range(3)]
    maxs = [max(block[i] for block in solids) for i in range(3)]
    commands = _clear_commands(spec, floor_cells, wall_blocks, door, door_upper, drop)
    for block in sorted(floor_cells):
        commands.append(_set(spec.dimension, block, spec.floor))
    for block in wall_blocks:
        commands.append(_set(spec.dimension, block, spec.wall))
    commands.append(_set(spec.dimension, door, "%s[facing=north,half=lower,hinge=left,open=false]" % spec.door))
    commands.append(_set(spec.dimension, door_upper, "%s[facing=north,half=upper,hinge=left,open=false]" % spec.door))
    commands.append(_set(spec.dimension, drop, _dropoff_state(spec.dropoff)))
    result = {
        "name": spec.name,
        "shape": spec.shape,
        "dimension": spec.dimension,
        "origin": [x0, y, z0],
        "width": spec.width,
        "depth": spec.depth,
        "height": spec.height,
        "notch": list(spec.notch) if spec.notch else None,
        "interior": [[x, y, z] for x, z in sorted(interior)],
        "door": {
            "lower": list(door),
            "upper": list(door_upper),
            "facing": "north",
            "outside": [door[0], y, door[2] - 1],
        },
        "dropoff": {
            "pos": list(drop),
            "block": spec.dropoff,
            "facing": "west",
            "access": {"pos": list(access), "heading": heading, "side": "front"},
        },
        "bounds": {"min": mins, "max": maxs},
        "commands": len(commands),
    }
    return {"commands": commands, "result": result}


def build(session, spec):
    plan = plan_room(spec)
    for command in plan["commands"]:
        reply = session.command(command)
        ensure_ok(reply, command)
        if " setblock " in command and "Changed the block" not in reply:
            raise FixtureError("block did not change: %s" % reply.strip(), command, reply)
        if " run fill " in command and "filled" not in reply:
            raise FixtureError("fill did not run: %s" % reply.strip(), command, reply)
        if " forceload add " in command and "force load" not in reply:
            raise FixtureError("forceload did not run: %s" % reply.strip(), command, reply)
    return plan["result"]


def _clear_commands(spec, floor_cells, wall_blocks, door, door_upper, drop):
    """Air out every cell the build writes, plus the rectangular footprint.

    The door pad sits one block north of the wall, outside the old wall box.
    A second build used to setblock that pad while it was already floor, and
    the server answered "Could not set the block". The notch stays inside the
    rectangle so a rebuild clears it before the inner walls go back.
    """
    x0, y, z0 = spec.origin
    cells = set(floor_cells)
    cells.update(wall_blocks)
    cells.add(door)
    cells.add(door_upper)
    cells.add(drop)
    for dx in range(spec.width):
        for dz in range(spec.depth):
            cells.add((x0 + dx, y - 1, z0 + dz))
            for dy in range(spec.height):
                cells.add((x0 + dx, y + dy, z0 + dz))
    box_min = [min(cell[i] for cell in cells) for i in range(3)]
    box_max = [max(cell[i] for cell in cells) for i in range(3)]
    commands = [
        run(spec.dimension, "forceload add %s %s %s %s" % (box_min[0], box_min[2], box_max[0], box_max[2])),
    ]
    commands.extend(_fill_air(spec.dimension, box_min, box_max))
    return commands


def _fill_air(dimension, box_min, box_max):
    x0, y0, z0 = box_min
    x1, y1, z1 = box_max
    width = x1 - x0 + 1
    depth = z1 - z0 + 1
    commands = []
    y = y0
    while y <= y1:
        span = 1
        while y + span <= y1 and width * (span + 1) * depth <= FILL_LIMIT:
            span += 1
        if width * span * depth > FILL_LIMIT:
            raise FixtureError("air fill slice is above 32768 blocks")
        commands.append(run(dimension, "fill %s %s %s %s %s %s minecraft:air" % (
            x0, y, z0, x1, y + span - 1, z1)))
        y += span
    return commands


def _span(value, label, lower=3, upper=48):
    if isinstance(value, bool) or not isinstance(value, int) or value < lower or value > upper:
        raise FixtureError("%s must be an integer from %s to %s" % (label, lower, upper))
    return value


def _notch(shape, width, depth, notch):
    if shape == "rect":
        if notch is not None:
            raise FixtureError("a rectangular room has no notch")
        return None
    if notch is None:
        if shape == "l":
            notch = (width // 2, depth // 2, width - width // 2, depth - depth // 2)
        else:
            cut_w = max(1, width // 3)
            cut_d = max(1, depth // 3)
            notch = ((width - cut_w) // 2, depth - cut_d, cut_w, cut_d)
    if not isinstance(notch, (tuple, list)) or len(notch) != 4:
        raise FixtureError("notch is x, z, width, depth inside the room")
    nx, nz, nw, nd = notch
    for number in (nx, nz, nw, nd):
        if isinstance(number, bool) or not isinstance(number, int):
            raise FixtureError("notch values must be integers")
    if nw < 1 or nd < 1 or nx < 0 or nz < 0 or nx + nw > width or nz + nd > depth:
        raise FixtureError("notch must sit inside the room")
    if nw == width and nd == depth:
        raise FixtureError("notch removes the whole room")
    return (nx, nz, nw, nd)


def _interior(x0, z0, width, depth, notch):
    cells = set()
    for dx in range(width):
        for dz in range(depth):
            if notch and notch[0] <= dx < notch[0] + notch[2] and notch[1] <= dz < notch[1] + notch[3]:
                continue
            cells.add((x0 + dx, z0 + dz))
    if not cells:
        raise FixtureError("room has no interior")
    return cells


def _door_column(interior):
    candidates = sorted(z for _x, z in interior)
    north = min(candidates)
    edge = sorted(x for x, z in interior if z == north and (x, north - 1) not in interior)
    if not edge:
        raise FixtureError("room has no north wall for a door")
    return (edge[len(edge) // 2], north - 1)


def _dropoff_column(interior, door_column):
    candidates = []
    for x, z in interior:
        east = (x + 1, z)
        if east in interior or east == door_column:
            continue
        candidates.append((z, x, east))
    if not candidates:
        raise FixtureError("room has no wall cell for a drop-off")
    candidates.sort()
    _z, x, east = candidates[-1]
    return east, (x, _z)


def _dropoff_state(block):
    if block.endswith("chest"):
        return "%s[facing=west,type=single]" % block
    if block == "minecraft:barrel":
        return "%s[facing=west]" % block
    return block


def _set(dimension, pos, block):
    return run(dimension, "setblock %s %s" % (block_pos(pos), block))
