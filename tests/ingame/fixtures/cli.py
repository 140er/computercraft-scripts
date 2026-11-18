"""JSON in, JSON out. The PowerShell wrapper uses this entry point.

Restart stays in Python or PowerShell. A callback cannot cross stdin.
prepare_restart flushes the world and logs the request. The caller then
restarts the process and opens a new session.
"""

import json
import sys

from .errors import FixtureError
from .mods import custom_mod_status
from .rooms import RoomSpec
from .session import Session


def main(argv=None):
    del argv
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        _emit({"ok": False, "error": "invalid JSON: %s" % exc})
        return 1
    if not isinstance(payload, dict):
        _emit({"ok": False, "error": "request must be an object"})
        return 1
    try:
        op = payload["op"]
        args = payload.get("args") or {}
        if op == "custom_mods":
            _emit({"ok": True, "result": custom_mod_status(args.get("paths"))})
            return 0
        session = Session(payload["host"], int(payload["port"]), payload["password"], payload.get("log") or "rcon.txt")
        try:
            _emit({"ok": True, "result": _dispatch(session, op, args)})
        finally:
            session.close()
        return 0
    except (FixtureError, KeyError, TypeError, ValueError) as exc:
        _emit({"ok": False, "error": str(exc)})
        return 1


def _dispatch(session, op, args):
    if op == "command":
        return {"reply": session.command(args["command"])}
    if op == "prepare_restart":
        session.marker("restart requested %s" % args.get("reason", ""))
        flush = session.command("save-all flush", timeout=120)
        session.close()
        return {"flush": flush}
    if op == "build_room":
        return session.build_room(_room(args))
    if op == "fill_container":
        return session.fill_container(args["pos"], args["stacks"], args.get("dimension", "minecraft:overworld"))
    if op == "read_container":
        return session.read_container(args["pos"], args.get("dimension", "minecraft:overworld"))
    if op == "read_region":
        return session.read_region(args["min"], args["max"], args.get("dimension", "minecraft:overworld"))
    if op == "write_counts":
        return session.write_counts(args["before"], args.get("after"), args["json"], args["markdown"])
    if op == "place_computer":
        return session.place_computer(
            args["pos"], args["computer_id"], args.get("advanced", True), args.get("facing", "north"),
            args.get("modem"), args.get("modem_facing", "down"), args.get("dimension", "minecraft:overworld"))
    if op == "place_turtle":
        return session.place_turtle(
            args["pos"], args["computer_id"], args.get("advanced", True), args.get("facing", "north"),
            args.get("fuel", 0), args.get("left"), args.get("right"), args.get("dimension", "minecraft:overworld"))
    if op == "place_modem":
        return session.place_modem(
            args["pos"], args.get("kind", "wireless_advanced"), args.get("facing", "down"),
            args.get("dimension", "minecraft:overworld"))
    if op == "place_furnace":
        return session.place_furnace(
            args["pos"], args.get("kind", "furnace"), args.get("facing", "north"),
            args.get("dimension", "minecraft:overworld"))
    if op == "fill_chest":
        return session.fill_chest(
            args["pos"], args.get("item", "minecraft:cobblestone"), args.get("count", 64),
            args.get("slots", 27), args.get("dimension", "minecraft:overworld"))
    if op == "empty_turtle_fuel":
        return session.empty_turtle_fuel(args["pos"], args.get("dimension", "minecraft:overworld"))
    if op == "remove_furnace":
        return session.remove_furnace(args["pos"], args.get("dimension", "minecraft:overworld"))
    if op == "unload_chunk":
        return session.unload_chunk(args["pos"], args.get("dimension", "minecraft:overworld"), args.get("timeout", 90))
    raise FixtureError("unknown operation %s" % op)


def _room(args):
    return RoomSpec(
        name=args["name"], origin=args["origin"], width=args["width"], depth=args["depth"],
        height=args["height"], shape=args.get("shape", "rect"), notch=args.get("notch"),
        wall=args.get("wall", "minecraft:stone_bricks"), floor=args.get("floor", "minecraft:smooth_stone"),
        door=args.get("door", "minecraft:oak_door"), dropoff=args.get("dropoff", "minecraft:chest"),
        dimension=args.get("dimension", "minecraft:overworld"))


def _emit(payload):
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    sys.exit(main())
