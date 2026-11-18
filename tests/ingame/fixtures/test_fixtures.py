"""Unit tests for room geometry, SNBT, count tables and RCON framing."""

import json
import socket
import struct
import threading
import unittest
from pathlib import Path

from tests.ingame.fixtures.errors import FixtureError
from tests.ingame.fixtures.inventory import diff_counts, write_counts
from tests.ingame.fixtures.mods import CUSTOM_MODS, custom_mod_status
from tests.ingame.fixtures.rcon import Client
from tests.ingame.fixtures.machines import place_turtle
from tests.ingame.fixtures.rooms import RoomSpec, plan_room
from tests.ingame.fixtures.snbt import item_rows, parse, parse_data_reply


ROOT = Path(__file__).resolve().parents[3]


class SnbtTests(unittest.TestCase):
    def test_mixed_items(self):
        text = '{Items:[{Slot:0b,count:64,id:"minecraft:cobblestone"},{Slot:1b,count:1,id:"minecraft:diamond_pickaxe",components:{"minecraft:damage":0}}],id:"minecraft:chest"}'
        block_id, rows = item_rows(parse(text))
        self.assertEqual(block_id, "minecraft:chest")
        self.assertEqual(rows[0]["count"], 64)
        self.assertEqual(rows[1]["components"], {"minecraft:damage": 0})

    def test_live_turtle_shape(self):
        text = '{Fuel: 0, RightUpgrade: {components: {"computercraft:on": 0b}, id: "computercraft:wireless_modem_advanced"}, x: 2, LeftUpgrade: {id: "minecraft:diamond_pickaxe"}, Slot: 0, y: 65, Items: [], z: 0, id: "computercraft:turtle_advanced", ComputerId: 7, On: 0b}'
        block_id, rows = item_rows(parse_data_reply("2, 65, 0 has the following block data: " + text))
        self.assertEqual(block_id, "computercraft:turtle_advanced")
        self.assertEqual(rows, [])

    def test_reply_prefix_and_typed_array(self):
        parsed = parse_data_reply('Chest has the following block entity data: {Items:[],id:"minecraft:chest"}')
        self.assertEqual(parsed["id"], "minecraft:chest")
        self.assertEqual(parse("[B;1b,2b]"), [1, 2])
        self.assertEqual(parse('{a:"quoted \\"x\\""}'), {"a": 'quoted "x"'})
        self.assertTrue(parse("true"))
        self.assertEqual(parse("-4s"), -4)

    def test_component_stacks_stay_separate(self):
        before = {"containers": [{"pos": [1, 65, 2], "block": "minecraft:chest", "items": [
            {"slot": 0, "id": "minecraft:diamond_pickaxe", "count": 1, "components": {"minecraft:damage": 0}},
            {"slot": 1, "id": "minecraft:diamond_pickaxe", "count": 1, "components": {"minecraft:damage": 4}},
        ]}]}
        after = {"containers": [{"pos": [1, 65, 2], "block": "minecraft:chest", "items": [
            {"slot": 0, "id": "minecraft:diamond_pickaxe", "count": 1, "components": {"minecraft:damage": 0}},
        ]}]}
        table = diff_counts(before, after)
        self.assertEqual(len(table["rows"]), 2)
        damaged = [row for row in table["rows"] if row["components"] == {"minecraft:damage": 4}]
        self.assertEqual(damaged[0]["delta"], -1)
        self.assertEqual(table["totals"][0]["delta"], -1)


class RoomTests(unittest.TestCase):
    def test_heading_matches_nav(self):
        text = (ROOT / "nav.lua").read_text(encoding="utf-8")
        self.assertIn("[0]={0,0,-1}, {1,0,0}, {0,0,1}, {-1,0,0}", text)

    def test_sizes_and_odd_shapes(self):
        rect = plan_room(RoomSpec("small", (8, 65, 8), 5, 5, 3))["result"]
        self.assertEqual(len(rect["interior"]), 25)
        ell = plan_room(RoomSpec("ell", (0, 65, 0), 8, 8, 3, shape="l"))["result"]
        interior = {tuple(cell) for cell in ell["interior"]}
        self.assertNotIn((4, 65, 4), interior)
        self.assertIn((0, 65, 0), interior)
        self.assertLess(len(interior), 64)
        door = ell["door"]["lower"]
        self.assertEqual(door[2], -1)
        self.assertNotIn((door[0], 65, door[2]), interior)
        drop = ell["dropoff"]
        access = drop["access"]["pos"]
        self.assertEqual(drop["access"]["heading"], 1)
        self.assertEqual([access[0] + 1, access[1], access[2]], drop["pos"])
        self.assertIn(tuple(access), interior)
        self.assertNotIn(tuple(drop["pos"]), interior)
        notched = plan_room(RoomSpec("bite", (10, 65, 10), 9, 6, 3, shape="notched"))["result"]
        notch_cells = {tuple(cell) for cell in notched["interior"]}
        self.assertIn((10, 65, 15), notch_cells)
        self.assertIn((18, 65, 15), notch_cells)
        self.assertNotIn((13, 65, 15), notch_cells)

    def test_rect_rejects_a_notch(self):
        with self.assertRaises(FixtureError):
            RoomSpec("bad", (0, 65, 0), 5, 5, 3, notch=(1, 1, 1, 1))

    def test_air_fill_covers_the_door_pad_and_stays_under_the_fill_limit(self):
        plan = plan_room(RoomSpec("small", (8, 65, 8), 5, 5, 3))
        outside = plan["result"]["door"]["outside"]
        fills = [command for command in plan["commands"] if " run fill " in command]
        self.assertTrue(any(_fill_covers(command, outside) for command in fills))
        ell = plan_room(RoomSpec("ell", (0, 65, 0), 8, 8, 3, shape="l"))
        ell_fills = [command for command in ell["commands"] if " run fill " in command]
        self.assertTrue(any(_fill_covers(command, (4, 64, 4)) for command in ell_fills))
        huge = plan_room(RoomSpec("max", (0, 65, 0), 48, 48, 24))
        huge_fills = [command for command in huge["commands"] if " run fill " in command]
        self.assertGreater(len(huge_fills), 1)
        for command in huge_fills:
            self.assertLessEqual(_fill_volume(command), 32768)

    def test_commands_name_the_dimension(self):
        plan = plan_room(RoomSpec("nether", (0, 65, 0), 4, 4, 2, dimension="minecraft:the_nether"))
        self.assertTrue(all(command.startswith("execute in minecraft:the_nether run ") for command in plan["commands"]))
        self.assertTrue(any("oak_door[facing=north,half=lower" in command for command in plan["commands"]))
        self.assertTrue(any("chest[facing=west,type=single]" in command for command in plan["commands"]))


class PlaceTests(unittest.TestCase):
    def test_place_clears_the_cell_before_setblock(self):
        class Fake:
            def __init__(self):
                self.commands = []

            def command(self, command):
                self.commands.append(command)
                if " run fill " in command:
                    return "Successfully filled 1 block(s)"
                return "Changed the block at 1, 2, 3"

        fake = Fake()
        place_turtle(fake, (1, 2, 3), 4, fuel=250, left="minecraft:diamond_pickaxe")
        self.assertIn("fill 1 2 3 1 2 3 minecraft:air", fake.commands[0])
        self.assertIn("computercraft:turtle_advanced[facing=north]{ComputerId:4,Fuel:250", fake.commands[1])
        self.assertIn('LeftUpgrade:"minecraft:diamond_pickaxe"', fake.commands[1])


class RconTests(unittest.TestCase):
    def test_reassembles_a_split_reply_and_hides_the_password(self):
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        port = server.getsockname()[1]
        payload = "A" * 5000
        holder = {}

        def serve():
            conn, _addr = server.accept()
            holder["conn"] = conn
            ident, kind, _body = _read(conn)
            self.assertEqual(kind, 3)
            _write(conn, ident, 2, "")
            ident, kind, body = _read(conn)
            self.assertEqual(kind, 2)
            self.assertEqual(body, "big")
            raw = payload.encode()
            _write(conn, ident, 0, raw[:4096].decode())
            _write(conn, ident, 0, raw[4096:].decode())
            conn.close()

        thread = threading.Thread(target=serve)
        thread.start()
        log = ROOT / "tests" / "ingame" / "fixtures" / "_rcon-test.txt"
        if log.exists():
            log.unlink()
        client = Client("127.0.0.1", port, "secret-password", log, timeout=5)
        try:
            self.assertEqual(client.command("big"), payload)
        finally:
            client.close()
            thread.join(2)
            server.close()
        text = log.read_text(encoding="utf-8")
        self.assertIn("big", text)
        self.assertNotIn("secret-password", text)
        log.unlink()


class ModHookTests(unittest.TestCase):
    def test_private_jars_are_absent_and_have_no_url(self):
        status = custom_mod_status()
        self.assertEqual(tuple(status), CUSTOM_MODS)
        encoded = json.dumps(status)
        self.assertNotIn("http", encoded)
        self.assertTrue(all(row["public"] is False and row["present"] is False for row in status.values()))
        with self.assertRaises(FixtureError):
            custom_mod_status({"other": "missing.jar"})


class TableTests(unittest.TestCase):
    def test_markdown_has_exact_numbers(self):
        before = {"containers": [{"pos": [3, 65, 4], "block": "minecraft:chest", "items": [
            {"slot": 0, "id": "minecraft:dirt", "count": 64, "components": None},
        ]}]}
        after = {"containers": [{"pos": [3, 65, 4], "block": "minecraft:chest", "items": [
            {"slot": 0, "id": "minecraft:dirt", "count": 10, "components": None},
        ]}]}
        folder = ROOT / "tests" / "ingame" / "fixtures"
        table = write_counts(before, after, folder / "_counts.json", folder / "_counts.md")
        self.assertEqual(table["rows"][0]["delta"], -54)
        text = (folder / "_counts.md").read_text(encoding="utf-8")
        self.assertIn("| 3 | 65 | 4 | minecraft:chest | 0 | minecraft:dirt | 64 | 10 | -54 |", text)
        (folder / "_counts.json").unlink()
        (folder / "_counts.md").unlink()


def _fill_covers(command, pos):
    numbers = [int(part) for part in command.split() if _is_int(part)]
    x0, y0, z0, x1, y1, z1 = numbers[-6:]
    x, y, z = pos
    return x0 <= x <= x1 and y0 <= y <= y1 and z0 <= z <= z1


def _fill_volume(command):
    numbers = [int(part) for part in command.split() if _is_int(part)]
    x0, y0, z0, x1, y1, z1 = numbers[-6:]
    return (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1)


def _is_int(part):
    if part.startswith("-"):
        part = part[1:]
    return part.isdigit()


def _read(conn):
    length = struct.unpack("<i", _exact(conn, 4))[0]
    data = _exact(conn, length)
    ident, kind = struct.unpack("<ii", data[:8])
    return ident, kind, data[8:-2].decode()


def _write(conn, ident, kind, text):
    payload = text.encode()
    body = struct.pack("<ii", ident, kind) + payload + b"\x00\x00"
    conn.sendall(struct.pack("<i", len(body)) + body)


def _exact(conn, size):
    chunks = []
    while size:
        part = conn.recv(size)
        if not part:
            raise RuntimeError("closed")
        chunks.append(part)
        size -= len(part)
    return b"".join(chunks)


if __name__ == "__main__":
    unittest.main()
