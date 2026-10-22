# Server-only ComputerCraft

The `server-only` branch runs one server computer with at least 16 MB of disk.
It owns jobs, reservations, paired keys and saved state. Turtles execute batches
from the server. Displays show frames from the server and send input back.
The `main` branch has separate bots such as miner, hub and roomsorter.
This installer offers only server, worker and display roles.

Each turtle starts with a proven radio range of 16 blocks from the server.
Nearby reports never reduce it. Known world poses and successful batch reports
can extend it. Work stays within that range plus eight blocks. Mining and supply
travel shorten long batches at that boundary, then use the next report to extend
the range and continue. Shaft and spine reservations stay held across those
batches. Lumber travel advances one cell per lease.

A range-blocked or held miner retreats through known free cells to leave the
shared lane, then releases its lane reservation and queue entry. It keeps its
occupied cell reserved and returns to its previous pose before resuming work.
Retreat requires fuel for both directions. Failed escape moves try another known
exit, and a worker without return fuel stays out of the queue.
If it cannot retreat safely, it releases the pass but still protects its physical
cell. Another turtle cannot pass through a physically immobile turtle.

## Requirements

Install CC:Tweaked 1.120.2. Advanced Peripherals and cc_ar are optional.
Use modems for rednet communication between the machines. HTTP must be enabled
so the installer can fetch the public GitHub files.

Before installing the server, set this in the world's `computercraft-server.toml`
and restart the world:

```toml
computer_space_limit = 16000000
```

A larger value also works. A 1 MB or 8 MB disk cannot run the server.

Mining and lumber refuse `start` when the server disk is 80% full or more.
The screen shows `disk >=80%; free space`. Free space and submit `start` again.
Existing jobs and recovery continue, so disk use can still grow. Dug marks remain
on disk across jobs and have no automatic pruning or total byte limit.
Workers and displays download less than 800 KB each.

Servers and displays use all attached modems and detect modem changes without a
reboot. A wired monitor or AR cable can coexist with a wireless or ender modem.

Each network should have one `so/server` host. If another host already uses that
name, the server shows its ID and keeps running for paired clients. Reboot after
the name becomes available to register it. A paired display reconnects directly
to its saved server ID, even if another server answers discovery. Fresh clients
still use hostname discovery, so isolate competing networks while pairing.

## Install and pair

Run this on each machine:

```text
wget run https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/server-only/install.lua
```

A turtle installs as a worker. A pocket computer installs as a display.
A regular computer offers server or display. Use the arrow keys and Enter,
a mouse click, or monitor touch. With a monitor attached, display is the default.

For the server, the installer checks disk capacity before any download.
It tries GPS for two seconds. If GPS does not answer, enter the server's
`x y z` coordinates. Enter the dimension, or press Enter for
`minecraft:overworld`. The position is saved in `so-server.cfg`.

For a worker or display, press P on the running server, then enter its six-digit
code on the client. The code works once and expires after five minutes.
An already-paired display can also open PANEL, PAIR and press NEW CODE.
Its panel and the server terminal show the code and time left. Other displays
cannot see that invitation. Pressing NEW CODE again keeps the pending code.
After use or expiry, press NEW CODE for the next client.
Keep any leading zeros in the code.
Displays show the pairing prompt and digits on the monitor and computer terminal.
Backspace removes a digit. The sixth digit starts pairing. If it fails, the
display shows the reason and accepts a new code. Displays keep looking when
the server is absent and reconnect after it restarts.
Each machine starts its installed program immediately and on reboot.
Paired turtles never ask for another code at boot. They show `waiting for server`
and retry discovery and authenticated hello with backoff capped at 30 seconds.
If discovery fails, they use their saved server id. Unpaired turtles keep
retrying discovery while waiting for six digits and Enter at `Code:`.

Display text commands appear on the bottom row while you type. Backspace
edits the line and Enter sends it and clears it. Wall displays also echo the
line on the computer terminal. Screens at least three rows tall reserve one
row for input, leaving the remaining rows for server frames and buttons.

Run `install update` to download the saved role again. `update` calls the same
installer. Updates preserve pairing keys, the worker journal, drop points,
display settings, server position and `so-data/`. All downloads must return
non-empty HTTP 200 responses, and Lua files must compile before any installed
file changes. Startup recovers interrupted swaps before launching the program.
A failed download leaves the installed files in place. A private repository may
answer "not found".

Run `install reset` and type `yes` to delete everything except `install.lua`
and `/rom`. This removes pairing keys and saved data. Run `install` again and
pair the machine again after a reset.

## Map

Tap `MAP` in the header of any display or panel. `BACK` returns to the screen
that opened it. The map fits the configured mine, farm, drops and turtles on
entry with all levels projected. `FIT` restores that view after using `+`, `-` or the four pan buttons.
Each display keeps its own view until the server restarts.

North is up, x increases to the right and z increases downward. Grey cells are
planned shaft, spine and branches. Light grey cells are known dug blocks. `H`
marks the shaft and `@` marks the server. Turtles use `^ > v <` for heading,
with their id beside them when it fits. Busy turtles are green, idle turtles
amber, lost or out-of-range turtles coral, and finished turtles blue.
Chest letters include `O` for ore, `F` for fuel, `W` for wood and `S` for
saplings. The farm outline is green. Broken drop points are coral.

The bottom button cycles `MINE`, `SURFACE` and `ALL`. Mine selects the job's
bottom y level. Surface selects the server's y level, or the farm ground when
there is no server position. All projects the scene and scans dug blocks at the mine bottom, tunnel roof,
surface, farm ground, and known chest and turtle levels. Dug blocks appear progressively, with at
most 256 cell reads per frame. At coarse zoom, several blocks share one cell.
Turtles draw above landmarks and cells. Only the server's dimension is shown.

## Drop points

Open `MORE` from status, pocket glance or the panel header for the generic
drop-point list. Tap `ADD NEW` to open the editor. Use the kind and side buttons
to cycle values, the dimension and coordinate buttons to adjust the draft,
and `ADD` to save it. Select a point in the list for `FIX` or `REMOVE`. Use
`PREV` and `NEXT` to page through the list. The editor's `BACK` returns to the
list, whose `BACK` returns to status. All controls fit a 26x20 pocket or 29x12
monitor. Big Tiles use the full display height; typing opens local input.
Kinds are `fuel`, `ore`, `junk`, `wood`, `storage` and `any`.
Sides are `front` and `down`. Drop-point dimensions are integers: 0 overworld,
-1 Nether, 1 End. Set each drop point to the chest's own coordinates. With
`front`, the turtle stands beside the chest at the same height and faces it.
With `down`, it stands directly above the chest. Leave the access cell clear.

On the generic screen, type `1250 64 -900` and press Enter to set the draft,
then tap `add`. Type `-1 1250 64 -900` to also set the dimension. To add
immediately, type `add ore 1250 64 -900 front 0`. The command is
`add <kind> <x> <y> <z> [front|down] [dim]`; omitted fields keep the draft's
side and dimension. Coordinates and dimension must be integers. Invalid input
shows an error and leaves the draft unchanged.

The server chooses the nearest usable point in the same dimension, then falls
back to `any`. Without a usable point the worker holds. Three failed inspections
mark a point broken. Correct the chest or point and press `fix` to enable it again.
The registry holds at most 64 points. See the
[drop protocol](docs/server-only/PROTOCOL.md#drops) for authenticated `drops.edit`
requests and field definitions.

## Mining

The drop-point list has `MINING`, `LUMBER`, `SHOP`, `AR` and `PANEL` buttons.
Links wrap across rows on small displays. Mining and lumber each have `SETUP`
and `BACK`. Setup's `BACK` returns to its main page; main-page `BACK` returns
to status. Shop item tiles open the order page, whose `BACK` returns to the
list. AR's `BACK` returns to status. Panel has `MORE` for the drop-point list
and `GLANCE` for status. Every screen is reachable by visible buttons at
26x20 and 29x12. Compact mining rows show the full x,y,z position before state.

The server stores dug marks in compact 16x16x16 sections. At 1 MB of section
files, every display shows a request to forget old areas, with `allow` and
`keep` buttons. AR goggles show the same request. Each area is one section.
Nothing in the world changes. Turtles inspect forgotten blocks if they return.

`allow` forgets the oldest eligible marks, aiming for 650 KB. Running job areas,
reservations, open leases and worker recovery paths stay protected. If an area
becomes protected after the request appears, the server keeps it. Recovery
history stays protected even after a worker is removed from a job.
`keep` saves everything and remembers the choice across restarts. The server
asks again only after section files grow by another 50 percent. Sharding onto
more server storage is a future option. The 80 percent disk guard still applies.

Open the `mining` display screen. Submit these text commands:

```text
home <x> <y> <z> <n|e|s|w>
bottom <y>
length <n>
mode thorough|fast
ores diamond,iron,...
add <id> <x> <y> <z> <n|e|s|w>
remove <id>
start
stop
```

`home` sets the chest-side position and is required before the first `start`.
`bottom` sets the shaft bottom.
Branch length defaults to 64 blocks. `thorough` inspects walls, while `fast`
uses faster branches. `ores` selects the supported ore names and accepts spaces
around commas, such as `ores diamond, iron`.
`add` anchors a paired worker at its world position and facing.
`remove` can cancel a stationary recovery or park inspection and releases the
worker's lane and reservations. Other open leases must finish first. `stop` allows
an already sent batch to finish. The screen shows worker state, pose, fuel, ore
count and errors.

## Lumber

Open the `lumber` screen and submit these commands:

```text
area <x1> <z1> <x2> <z2> <ground y>
saplings <x> <y> <z> <front|down>
add <id> <x> <y> <z> <n|e|s|w>
start
stop
```

`area` sets farm bounds and soil height. `saplings` sets the sapling chest's own
coordinates. With `front`, the planner chooses the nearest eligible cell beside
the chest at the same height and faces the turtle towards it to take saplings.
With `down`, the turtle stands at `<x> <y+1> <z>` and takes saplings from below.
Leave these access cells clear. The planner excludes cells at or below soil
height, known obstacles, chest cells and planted spots at soil height plus one.
Distance is Manhattan distance from the turtle's current position. Ties use
north, east, south, west order. If no eligible cell remains, the turtle holds
with `no access to saplings chest`.

`add` anchors one paired worker with an axe. To replace it, stop work and wait
for its lease to report. If `add` says it is parking the old turtle, wait for
the report and repeat `add`. Do not remove the old turtle before that report.
Service trips cross the farm at soil height plus two and descend at the chest
access cell. Keep that flight path clear. Travel protects saplings and tree
bases. A blocked service route holds until the operator fixes it and starts again.
Work stays stopped until configured and started. `stop` parks after the current
lease reports. Log delivery counts require a successful drop and an inventory
decrease. Failed wood, fuel and sapling chest inspections mark drop points broken
after three failures. Repair the chest, use `fix` in the generic drop editor if
marked broken, and send `start` on the lumber screen. Sapling service reuses a
matching drop point or adds a `storage` point to that editor. Remove unused old
sapling points there after changing the coordinates.
Dark oak is excluded. Empty sapling chests disable replanting
while felling continues. Configure a wood drop and a fuel drop.
The screen shows work state, deliveries, saplings, spots, fuel and alerts.
Three failed moves or digs stop work and emit an alert for the screen and AR.
Fix the obstruction or tool, then type `start`. Other holds also show this
recovery instruction. Refuelling starts with the distance to the fuel chest
along the flight-height route plus 32 fuel remaining.
At the wood chest, the turtle also drops sticks, apples, leaves and excess
saplings. It keeps one sapling per known spot of each species, including the
current tree. It unloads when fewer than three slots remain, even mid-tree,
and clears junk at the end of each round.

## Shop and the Storage Room turtle

The shop screen uses the Storage Room turtle from `main`. Install that turtle
with main's installer and select `roomsorter.lua`. Do not install the worker
role on that turtle. It uses the legacy plain-rednet storage protocols and
does not pair with this server.

The server discovers the Storage Room turtle and polls stock automatically.
Until discovery the shop screen says `Storage room not found, still looking`.
Type text to filter item names on that display. Matching ignores case and treats
spaces as underscores. Tap `clear`, or submit a lone space or `*`, to clear it.
After five minutes without stock, the server clears stale stock and looks for
a Storage Room turtle again. Rooms use the legacy unpaired protocol; there is
no saved room selector, so isolate competing storage networks.
Item buttons order 1, 16 or 64 items. Replies appear as `Order:` lines. Orders are not retried automatically and time out after two minutes.
The storage protocol commands are `stock` and `order`; they are not shop text
commands. See the [shop protocol](docs/server-only/PROTOCOL.md#shop).

Workers refuse drop and suck steps unless the target is an inventory. A missing
chest returns `no inventory` and keeps the items in the turtle.

Mining discards excess junk into adjacent empty cells, keeping one suitable stack
for sealing. Workers check the target before each discard and refuse inventories
or occupied cells. Ore chests receive ore, not excess cobble or deepslate.

Idle turtles stay put when their park lease expires during a server outage. They
beacon every 30 seconds. Only turtles whose last lease was work use fast beacons
and backtrack along their saved moves.

After a reboot, workers resolve an interrupted move from saved fuel or GPS
evidence before reporting their pose. If a move or turn cannot be resolved, the
worker shows `pose uncertain: re-add turtle <id>`, stays put and refuses new steps.
Its hello reports the pending operation and uncertainty. Inspect its position and
facing, then enter `add <id> <x> <y> <z> <n|e|s|w>` on its mining or lumber screen.
This re-anchors that turtle, clears its old movement history and uncertainty, and
starts a fresh assignment at the supplied pose. The worker must save and confirm
the anchor before work resumes. Rebooting alone does not guess a pose.

If the server is reset or its pairing keys are replaced while its computer ID
stays the same, clients show an "Old key kept" pairing prompt. Press P on the
server and type the new code on each client. Turtles also require Enter. The
client keeps its old key until pairing succeeds. A normal authenticated reply
restores the client screen, so a false prompt does not require a reset.
