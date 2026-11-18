"""One RCON session. The caller passes host, port and password."""

from . import faults, inventory, machines, rooms
from .rcon import Client


class Session:
    def __init__(self, host, port, password, log_path, timeout=30):
        self.host = host
        self.port = int(port)
        self.log_path = log_path
        self._client = Client(host, port, password, log_path, timeout=timeout)

    def close(self):
        self._client.close()

    def marker(self, text):
        self._client.marker(text)

    def command(self, text, timeout=None):
        return self._client.command(text, timeout=timeout)

    def build_room(self, spec):
        return rooms.build(self, spec)

    def fill_container(self, pos, stacks, dimension="minecraft:overworld"):
        return inventory.fill_container(self, pos, stacks, dimension)

    def read_container(self, pos, dimension="minecraft:overworld"):
        return inventory.read_container(self, pos, dimension)

    def read_region(self, corner_a, corner_b, dimension="minecraft:overworld", limit=8000):
        return inventory.read_region(self, corner_a, corner_b, dimension, limit)

    def write_counts(self, before, after, json_path, markdown_path):
        return inventory.write_counts(before, after, json_path, markdown_path)

    def place_computer(self, pos, computer_id, advanced=True, facing="north", modem=None,
                       modem_facing="down", dimension="minecraft:overworld"):
        return machines.place_computer(
            self, pos, computer_id, advanced, facing, modem, modem_facing, dimension)

    def place_turtle(self, pos, computer_id, advanced=True, facing="north", fuel=0,
                     left=None, right=None, dimension="minecraft:overworld"):
        return machines.place_turtle(
            self, pos, computer_id, advanced, facing, fuel, left, right, dimension)

    def place_modem(self, pos, kind="wireless_advanced", facing="down", dimension="minecraft:overworld"):
        return machines.place_modem(self, pos, kind, facing, dimension)

    def place_furnace(self, pos, kind="furnace", facing="north", dimension="minecraft:overworld"):
        return machines.place_furnace(self, pos, kind, facing, dimension)

    def fill_chest(self, pos, item="minecraft:cobblestone", stack_count=64, slots=27,
                   dimension="minecraft:overworld"):
        return faults.fill_chest(self, pos, item, stack_count, slots, dimension)

    def empty_turtle_fuel(self, pos, dimension="minecraft:overworld"):
        return faults.empty_turtle_fuel(self, pos, dimension)

    def remove_furnace(self, pos, dimension="minecraft:overworld"):
        return faults.remove_furnace(self, pos, dimension)

    def unload_chunk(self, pos, dimension="minecraft:overworld", timeout=90):
        return faults.unload_chunk(self, pos, dimension, timeout)

    def request_restart(self, callback, reason=""):
        return faults.request_restart(self, callback, reason)
