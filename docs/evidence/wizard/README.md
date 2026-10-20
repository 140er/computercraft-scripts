# Wizard gate requirements

This is the initial requirements inventory. It contains no runtime verdict.
The scenario inventory is [wh2-wizard-gate-plan.json](../../../tests/wh2-wizard-gate-plan.json).
The acceptance rules come from [Gate B depth](../../testing/gateB-depth.md) and the [warehouse contract](../../design/wh2-contract.md).

Gate A requires the Lua mock suite, several CraftOS-PC computers and four turtles,
native capacity of 1,000,000 bytes on every disk, and saved headless captures.
The lead owns dispatch changes in `tests/sandbox/run.ps1`.

Gate B requires a fresh disposable real server, real mod jars, three room sizes
including an irregular room, and actual full and partial inventory stacks.
The same scenario driver must work through file and RCON adapters on the box and locally.
The live server and its RCON are forbidden.

The wizard flow requires two unknown modded item IDs, coalesced questions, skip,
real board answers through authenticated transport, exact routing counts, and
answers retained after computer reboot and server process restart.
Store routing is sufficient. A test must prove that unknown stacks stay intact before an answer.

Required failures include a full chest, turtle and furnace without fuel, a removed
machine, modem removal, concurrent requests, malformed requests, authentication
attacks, event bursts during saves and HTTP waits, and chunk unload and reload.
Each failed attempt stays in the evidence.

The soak requires four active turtles for at least two hours. Save durations,
state sizes, disk capacity, free space, question revisions, and exact inventory
totals need periodic records. Idle timers alone do not satisfy the soak.

The lead owns real-client F2 screenshots and video under the client lock.
Room, board, and wizard screenshots and a clip of the main flow remain mandatory.
Headless captures cannot replace them.

Craft production, miner drop-off, AR rendering, and movement recovery are outside
the wizard change. The JSON inventory gives the applicability reason for each.
H4 remains pending approval. Integrated hardening checks still need their own evidence.

Keep output below `C:\Work\gemini-input\p3\evidence\wizard`, with a fresh run
directory for each attempt. Preserve jar hashes, RCON transcripts, server and
computer logs, before and after counts, restart checkpoints, soak samples,
screenshots, and video. Missing applicable checks prevent a gate pass.
