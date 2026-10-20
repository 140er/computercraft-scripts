# Navigation evidence

The navigation gate runs a server, three turtles, a controller, and a shared world in CraftOS-PC. The smoke gate also boots the existing hub. Each computer has a 4,000,000-byte disk.

The Minecraft gate uses a disposable NeoForge world on loopback. Its real turtles cross a shared corridor, take a three-dimensional U route, reject a chest, water, and bedrock, and dig gravel. The GPS hosts are real computers. The fixture shuts them down, restores them, relocates a turtle, and calibrates it before further movement.

The disabled loader unloads the boundary computer. The gate checks the turtle block at x=31 and its retained server occupancy, then restarts Minecraft and reconciles the pose. It restores the ender upgrade, removes temporary forceloading, and crosses to x=32 before returning through known air.

Run the gates sequentially on this VM. Diagnostic runs with per-request tracing or overlapping stress tests hit the CraftOS watchdog. The final scenario has no tracing wrapper and yields between scan batches and snapshot pages. It still checks all 10,000 synthetic observations and every encoded page against the 8 KiB limit. The timing fields are diagnostic data, not a throughput comparison.

## Coverage

| Behavior | CraftOS and mocks | Real Minecraft |
| --- | --- | --- |
| Coordinates and heading | Four headings, negative coordinates, vertical moves, GPS loss, relocation, failed turns | GPS hosts, marker coordinates, relocation, calibration, final RCON positions |
| Journals and reservations | Every move and turn checkpoint, ambiguous turns, unlimited fuel, packet faults, full process restart | Computer and Minecraft restarts, uncertain movement recovery, three real turtles |
| Pathfinding and policies | U route, changed block, no route, search limit, fluids, entities, fuel, protected blocks | Three-dimensional U route, chest, water, bedrock, falling gravel |
| Cancellation | Search cancellation, busy movement owner, queued resume, stale epochs and command sequences | ESTOP replaces the server's queued go command over real modems |
| Storage and transport | 4 MB capacity, disk fill, save failures, bounded snapshots, malicious and replayed packets | Real disk fill, persisted map and reservations, ordinary and ender transport |

The runtime deliberately restarts before and after physical movement. Recorded trajectories include GPS observations after recovery. The one operator relocation is labeled separately from motor moves.

## Review the artifacts

The `gateA` and `gateB` directories contain the selected verdicts, checks, trajectories, and logs. `positions.csv` records the native trajectory. `ssot-crossing.png` is a real client F2 screenshot after the route and recovery tests. `position-timeline.png` is a diagram, not a Minecraft screenshot. No motion clip was recorded.

The full run directories are under `C:\Work\gemini-input\p2\evidence\pr2\`. Earlier failed diagnostic runs remain there. Test server passwords and game jars are not committed.

The selected runs are `gateA\verified` and `gateB\verified`. The mock transcript is `gateA\mocks-verified.txt`. Charger refusal is covered by mock observations; this PR does not claim a native charging test. Charging is part of PR 4.

The final CraftOS run passed all six computer roles and recorded 27 motor moves with zero collisions. Minecraft recorded 100 motor moves, one labeled relocation, and zero collisions. The mock suite passed 97 top-level tests. [Source hashes](source-sha256.txt) match all seven changed production Lua files in the repository and both staged gates after LF normalization.

The work used one agent as requested. The blocking steps were repository inspection and the movement contract tests. The navigation, miner, and protocol edits shared one journal contract, so they had one owner. The CraftOS and Minecraft fixtures were separate verification tasks, but their stress runs had to run sequentially on this VM.

The [decision trail](decisions.tsv) records the design and verification changes. Its initial timestamps were entered as approximate local times with an incorrect UTC suffix. The correction row identifies that mistake. Use the gate logs for event timing.

The requested single-agent mode also applied to review. No explanatory comments were added. Two existing comments that repeated or misstated the adjacent code were removed. The `deslop` skill was unavailable in the installed skill directories, so the diff and comments were reviewed directly.
