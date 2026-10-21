"""Run the fixture library against a caller-supplied RCON endpoint.

The default evidence directory is docs/evidence/fixtures. Pass the host,
port and password. This file can also start the local public-jar server
in server_dir. It never contacts 100.91.208.60.
"""

import argparse
import hashlib
import json
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

from tests.ingame.fixtures.errors import FixtureError
from tests.ingame.fixtures.mods import PUBLIC_MODS, custom_mod_status
from tests.ingame.fixtures.rcon import Client
from tests.ingame.fixtures.rooms import RoomSpec
from tests.ingame.fixtures.session import Session

ROOT = Path(__file__).resolve().parents[3]
LIVE = "100.91.208.60"
MIXED = [
    {"slot": 0, "id": "minecraft:cobblestone", "count": 64},
    {"slot": 1, "id": "minecraft:cobblestone", "count": 13},
    {"slot": 2, "id": "minecraft:iron_ingot", "count": 17},
    {"slot": 3, "id": "minecraft:diamond_pickaxe", "count": 1},
    {"slot": 4, "id": "computercraft:disk", "count": 1},
    {"slot": 5, "id": "computercraft:cable", "count": 16},
    {"slot": 6, "id": "minecraft:oak_log", "count": 32},
]


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--evidence", default=str(ROOT / "docs" / "evidence" / "fixtures"))
    parser.add_argument("--server-dir", default="")
    parser.add_argument("--restart", action="store_true")
    args = parser.parse_args(argv)
    if args.host == LIVE or LIVE in Path(args.password_file).read_text(encoding="utf-8"):
        raise SystemExit("refusing the live server")
    password = Path(args.password_file).read_text(encoding="utf-8").strip()
    evidence = Path(args.evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    log_path = evidence / "run.log"
    log_path.write_text("", encoding="utf-8")
    (evidence / "rcon.txt").write_text("", encoding="utf-8")

    def log(text):
        print(text, flush=True)
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write(text + "\n")

    owner = None
    if args.restart:
        if not args.server_dir:
            raise SystemExit("--restart needs --server-dir")
        owner = _Server(Path(args.server_dir), args.host, args.port, password, log, evidence / "rcon.txt")
    session = Session(args.host, args.port, password, evidence / "rcon.txt", timeout=30)
    summary = None
    try:
        summary = _scenario(session, evidence, log, owner)
    finally:
        session.close()
        if owner is not None:
            owner.stop()
        if args.server_dir:
            try:
                copy_server_evidence(args.server_dir, evidence)
            except OSError as exc:
                log("could not copy server evidence: %s" % exc)
    (evidence / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    log("validation finished")
    return 0


def _scenario(session, evidence, log, owner):
    session.marker("fixture validation start")
    listed = session.command("list")
    log(listed.strip())
    rooms = []
    specs = [
        RoomSpec("small", (8, 65, 8), 5, 5, 3),
        RoomSpec("medium", (32, 65, 8), 9, 7, 4),
        RoomSpec("large", (64, 65, 8), 13, 11, 4),
        RoomSpec("ell", (112, 65, 8), 11, 9, 4, shape="l"),
        RoomSpec("notched", (160, 65, 8), 11, 9, 4, shape="notched"),
    ]
    for spec in specs:
        log("building %s" % spec.name)
        rooms.append(session.build_room(spec))
    small = rooms[0]
    barrel_pos = _spare_cell(small)
    _place_fresh(session, barrel_pos, "execute in minecraft:overworld run setblock %s %s %s minecraft:barrel[facing=up]" % tuple(barrel_pos))
    machines = {
        "computer": session.place_computer((8, 65, 40), 50, modem="wireless_advanced"),
        "turtle": session.place_turtle(
            (10, 65, 40), 51, facing="north", fuel=250,
            left="minecraft:diamond_pickaxe", right="computercraft:wireless_modem_advanced"),
        "wired_modem": session.place_modem((12, 65, 40), kind="wired", facing="down"),
        "furnace": session.place_furnace((14, 65, 40), "furnace"),
        "blast_furnace": session.place_furnace((16, 65, 40), "blast_furnace"),
        "smoker": session.place_furnace((18, 65, 40), "smoker"),
    }
    session.command("computercraft turn-on 50")
    session.command("computercraft turn-on 51")
    frozen = session.command("tick freeze")
    if "frozen" not in frozen.lower():
        raise FixtureError("tick freeze failed: %s" % frozen.strip())
    drop = small["dropoff"]["pos"]
    session.fill_container(drop, MIXED)
    session.fill_container(barrel_pos, [
        {"slot": 0, "id": "minecraft:sand", "count": 16},
        {"slot": 1, "id": "minecraft:red_dye", "count": 2},
    ])
    session.fill_container(machines["furnace"]["pos"], [
        {"slot": 0, "id": "minecraft:raw_iron", "count": 8},
        {"slot": 1, "id": "minecraft:coal", "count": 3},
    ])
    session.fill_container(machines["blast_furnace"]["pos"], [
        {"slot": 0, "id": "minecraft:raw_gold", "count": 4},
        {"slot": 1, "id": "minecraft:coal", "count": 2},
    ])
    session.fill_container(machines["smoker"]["pos"], [
        {"slot": 0, "id": "minecraft:beef", "count": 6},
        {"slot": 1, "id": "minecraft:coal", "count": 1},
    ])
    rejected = _reject_missing_mod(session, (20, 65, 40))
    before = _scan(session, rooms, machines)
    session.write_counts(before, None, evidence / "counts-before.json", evidence / "counts-before.md")
    session.command("execute in minecraft:overworld run item replace block %s %s %s container.0 with minecraft:cobblestone 50" % tuple(drop))
    removed = session.remove_furnace(machines["furnace"]["pos"])
    fuel = session.empty_turtle_fuel(machines["turtle"]["pos"])
    _place_fresh(session, (22, 65, 40), "execute in minecraft:overworld run setblock 22 65 40 minecraft:chest")
    filled = session.fill_chest((22, 65, 40), item="minecraft:cobblestone", stack_count=64, slots=27)
    after = _scan(session, rooms, machines)
    table = session.write_counts(before, after, evidence / "counts-after.json", evidence / "counts-after.md")
    _require_row(table, drop, 0, "minecraft:cobblestone", 64, 50)
    _require_row(table, drop, 4, "computercraft:disk", 1, 1)
    _require_row(table, drop, 5, "computercraft:cable", 16, 16)
    _require_row(table, machines["furnace"]["pos"], 0, "minecraft:raw_iron", 8, 0)
    _require_row(table, machines["furnace"]["pos"], 1, "minecraft:coal", 3, 0)
    _require_row(table, machines["blast_furnace"]["pos"], 1, "minecraft:coal", 2, 2)
    _require_row(table, machines["smoker"]["pos"], 1, "minecraft:coal", 1, 1)
    restarted = None
    if owner is not None:
        # A restart boots with ticks running. A furnace that still holds fuel and an input
        # consumes one fuel item before RCON can freeze the new process.
        for name in ("blast_furnace", "smoker"):
            _clear_slot(session, machines[name]["pos"], 1)
        settled = _scan(session, [rooms[0]], machines)
        session.request_restart(owner.restart, reason="fixture validation")
        frozen_again = session.command("tick freeze")
        if "frozen" not in frozen_again.lower():
            raise FixtureError("tick freeze after restart failed: %s" % frozen_again.strip())
        restarted = _scan(session, [rooms[0]], machines)
        restart_table = session.write_counts(
            settled, restarted, evidence / "counts-restart.json", evidence / "counts-restart.md")
        changed = [row for row in restart_table["rows"] if row["delta"] != 0]
        if changed:
            raise FixtureError("counts changed across restart: %s" % changed[:5])
    session.command("tick unfreeze")
    session.command("execute in minecraft:overworld run forceload add 400 8 400 8")
    _place_fresh(session, (400, 64, 8), "execute in minecraft:overworld run setblock 400 64 8 minecraft:stone")
    _place_fresh(session, (400, 65, 8), "execute in minecraft:overworld run setblock 400 65 8 minecraft:chest")
    unloaded = session.unload_chunk((400, 65, 8), timeout=90)
    faults = {
        "rejected_mod_item": rejected,
        "removed_furnace": removed,
        "fuel": fuel,
        "filled_chest": filled,
        "unloaded_chunk": unloaded,
        "restarted": restarted is not None,
    }
    (evidence / "rooms.json").write_text(json.dumps(rooms, indent=2) + "\n", encoding="utf-8")
    (evidence / "machines.json").write_text(json.dumps(machines, indent=2) + "\n", encoding="utf-8")
    (evidence / "faults.json").write_text(json.dumps(faults, indent=2) + "\n", encoding="utf-8")
    (evidence / "custom-mods.json").write_text(json.dumps(custom_mod_status(), indent=2) + "\n", encoding="utf-8")
    if not unloaded["unloaded"]:
        raise FixtureError("chunk at 400 65 8 stayed loaded: %s" % unloaded.get("last"))
    if fuel["after"] != 0:
        raise FixtureError("fuel remained")
    if filled["total"] != 64 * 27:
        raise FixtureError("chest fill total mismatch")
    return {
        "rooms": [room["name"] for room in rooms],
        "shapes": [room["shape"] for room in rooms],
        "list": listed.strip(),
        "fuel": fuel,
        "filled_chest_total": filled["total"],
        "unloaded": unloaded["unloaded"],
        "rejected_mod_item": rejected["error"],
        "public_mods": PUBLIC_MODS,
    }


def _require_row(table, pos, slot, item_id, before, after):
    for row in table["rows"]:
        if row["pos"] == list(pos) and row["slot"] == slot and row["id"] == item_id:
            if row["before"] != before or row["after"] != after:
                raise FixtureError("count row %s was %s to %s" % (item_id, row["before"], row["after"]))
            return
    raise FixtureError("missing count row for %s slot %s" % (item_id, slot))


def _spare_cell(room):
    access = tuple(room["dropoff"]["access"]["pos"])
    drop = tuple(room["dropoff"]["pos"])
    for cell in room["interior"]:
        pos = tuple(cell)
        if pos != access and pos != drop:
            return list(pos)
    raise FixtureError("room has no spare cell")


def _reject_missing_mod(session, pos):
    _place_fresh(session, pos, "execute in minecraft:overworld run setblock %s %s %s minecraft:chest" % tuple(pos))
    try:
        session.fill_container(pos, [{"slot": 0, "id": "examplemod:not_installed", "count": 1}])
    except FixtureError as exc:
        return {"ok": False, "error": str(exc)}
    raise FixtureError("a missing mod item was accepted")


def _place_fresh(session, pos, command):
    clear = "execute in minecraft:overworld run fill %s %s %s %s %s %s minecraft:air" % (
        pos[0], pos[1], pos[2], pos[0], pos[1], pos[2])
    reply = session.command(clear)
    if "filled" not in reply:
        raise FixtureError("cell was not cleared: %s" % reply.strip(), clear, reply)
    return _changed(session, command)


def _clear_slot(session, pos, slot):
    command = "execute in minecraft:overworld run item replace block %s %s %s container.%s with minecraft:air" % (
        pos[0], pos[1], pos[2], slot)
    reply = session.command(command)
    if "Replaced" not in reply and "Changed" not in reply:
        raise FixtureError("slot was not cleared: %s" % reply.strip(), command, reply)
    return reply


def _changed(session, command):
    reply = session.command(command)
    if "Changed the block" not in reply:
        raise FixtureError("block did not change: %s" % reply.strip(), command, reply)
    return reply


def _scan(session, rooms, machines):
    containers = []
    parts = []
    for room in rooms:
        part = session.read_region(room["bounds"]["min"], room["bounds"]["max"])
        containers.extend(part["containers"])
        parts.append({"name": room["name"], "min": part["min"], "max": part["max"]})
    machine_points = [machines[name]["pos"] for name in machines]
    xs = [pos[0] for pos in machine_points]
    ys = [pos[1] for pos in machine_points]
    zs = [pos[2] for pos in machine_points]
    part = session.read_region((min(xs), min(ys), min(zs)), (max(xs), max(ys), max(zs)))
    containers.extend(part["containers"])
    parts.append({"name": "machines", "min": part["min"], "max": part["max"]})
    return {"dimension": "minecraft:overworld", "containers": containers, "parts": parts}


class _Server:
    def __init__(self, server_dir, host, port, password, log, rcon_log):
        self.server_dir = server_dir
        self.host = host
        self.port = port
        self.password = password
        self.log = log
        self.rcon_log = rcon_log
        self.process = None

    def restart(self):
        self.log("restart callback")
        client = Client(self.host, self.port, self.password, self.rcon_log, timeout=30)
        try:
            client.command("stop")
        except Exception as exc:
            self.log("stop returned %s" % exc)
        finally:
            client.close()
        self._wait_port(False)
        self.process = self._spawn()
        self._wait_port(True)

    def stop(self):
        if self.process is None or self.process.poll() is not None:
            return
        client = Client(self.host, self.port, self.password, self.rcon_log, timeout=30)
        try:
            client.command("stop")
        except Exception:
            pass
        finally:
            client.close()
        try:
            self.process.wait(timeout=90)
        except subprocess.TimeoutExpired:
            self.process.kill()

    def _spawn(self):
        stdout = open(self.server_dir / "stdout-restart.log", "w", encoding="utf-8")
        stderr = open(self.server_dir / "stderr-restart.log", "w", encoding="utf-8")
        return subprocess.Popen(
            ["java", "@user_jvm_args.txt", "@libraries/net/neoforged/neoforge/21.1.259/unix_args.txt", "nogui"],
            cwd=self.server_dir, stdout=stdout, stderr=stderr)

    def _wait_port(self, open_expected):
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            connected = _port_open(self.host, self.port)
            if connected == open_expected:
                if open_expected:
                    self._wait_rcon()
                return
            time.sleep(1)
        raise FixtureError("timed out waiting for RCON open=%s" % open_expected)

    def _wait_rcon(self):
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                client = Client(self.host, self.port, self.password, self.server_dir / "boot-rcon.txt", timeout=5)
                reply = client.command("list")
                client.close()
                if "players online" in reply:
                    frozen = client.command("tick freeze")
                    if "frozen" not in frozen.lower():
                        raise FixtureError("tick freeze after boot failed: %s" % frozen.strip())
                    return
            except Exception:
                time.sleep(1)
        raise FixtureError("RCON did not answer after restart")


def _port_open(host, port):
    try:
        with socket.create_connection((host, port), 1):
            return True
    except OSError:
        return False


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_server_evidence(server_dir, evidence):
    logs = Path(server_dir) / "logs" / "latest.log"
    if logs.exists():
        shutil.copyfile(logs, Path(evidence) / "latest.log")
    mods = []
    for path in sorted((Path(server_dir) / "mods").glob("*.jar")):
        mods.append({"file": path.name, "sha256": sha256_file(path)})
    config = list(Path(server_dir).glob("config/computercraft*.toml"))
    config += list((Path(server_dir) / "world").glob("serverconfig/computercraft*.toml"))
    limit = None
    for path in config:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("computer_space_limit"):
                limit = line.strip()
    (Path(evidence) / "jars.json").write_text(json.dumps({"mods": mods, "computer_space_limit": limit}, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
