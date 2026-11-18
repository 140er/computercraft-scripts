# Gate B fixtures

Python helpers for a disposable Minecraft test server. Callers pass the RCON host, the port and the password. The same calls work against a server on this machine or against another machine.

```python
from tests.ingame.fixtures import RoomSpec, Session

session = Session("127.0.0.1", 25575, password, "rcon.txt")
room = session.build_room(RoomSpec("small", (8, 65, 8), 5, 5, 3))
session.fill_container(room["dropoff"]["pos"], [
    {"slot": 0, "id": "minecraft:cobblestone", "count": 64},
    {"slot": 1, "id": "computercraft:cable", "count": 16},
])
before = session.read_region(room["bounds"]["min"], room["bounds"]["max"])
```

`RoomSpec` shapes are `rect`, `l` and `notched`. Each room gets a floor, walls, a north door and a drop-off chest. The air fill covers the door pad and the rectangular footprint, then the floor and walls are placed back. A room at the 48 by 48 by 24 limit is filled in slices of at most 32768 blocks. The drop-off `access.heading` uses the same numbers as `nav.lua` line 3. 0 is north. 1 is east. 2 is south. 3 is west.

`fill_container` puts the caller's item ids in the given slots. Modded ids are data. The server rejects an id that is not installed, and it rejects a count above that item's stack limit.

`read_region` runs `data get block` on every block in the box and keeps containers. `write_counts` writes a JSON file and a Markdown table of before and after counts. Stacks with different components stay on separate rows.

`place_computer`, `place_turtle`, `place_modem` and `place_furnace` fill the cell with air and then `setblock`, so a second run still changes the block. Furnace kinds are `furnace`, `blast_furnace` and `smoker`. Minecraft container slots are 0, 1 and 2 for input, fuel and output.

Faults are `fill_chest`, `empty_turtle_fuel`, `remove_furnace` and `unload_chunk`. `request_restart` flushes the world and calls the caller's callback. The callback restarts the process. The next command opens a new RCON connection.

Every command and reply is appended to the log path.

`custom_mod_status` reports `turtlebattery`, `recipe_index` and `turtlematicfix`. Those jars are not public. Pass a local path if you have one. The function does not download them.

PowerShell callers dot-source `fixtures.ps1` and call `Invoke-GateBFixture`. `Request-FixtureRestart` takes a script block for the reboot.

`python3 -m unittest tests.ingame.fixtures.test_fixtures` checks geometry, SNBT and RCON framing without Minecraft. `python3 -m tests.ingame.fixtures.validate` runs the helpers against a live RCON port.
