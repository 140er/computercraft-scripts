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
At 85% the server shows `DISK pressure`, keeps heartbeat updates in memory and
checkpoints every 10000 events instead of 2000. Retention checkpoints still run.

Event saves remain synchronous. New log segments target 8 KB to reduce rewrite
work. The schema, 64 KB single-event limit, retention budget and generation
recovery stay compatible with `install rollback`. Completed appends survive a
crash during the next write. The event whose write was interrupted may be absent.

To omit routine heartbeat events, add `state = { coalesceHeartbeats = true }`
to the existing `so-server.cfg` table and restart the server. The setting defaults
to false. Role, journal, fingerprint and significant fuel changes still create
events. Views receive current contact times and fuel without routine log writes.
Snapshots save those values on the existing event-count and retention cadence.
There is no time-based snapshot, so idle freshness can remain volatile until
another checkpoint. After restart, restored machines receive a fresh boot-time
contact timestamp before normal stale thresholds apply.
Tap DISK on status for bytes in log, snapshots, cells, jobs, keys and other files.
The ledger counts all file generations and refreshes every 30 seconds. Other
includes code, filesystem allocation and files outside those stores.

If an event cannot save, the server folds it into memory and queues it for retry.
The queue holds at most 256 events and 262144 serialized bytes. Status and AR show
`DISK N events pending`. New movement leases stop until the queue drains; stationary
parks and recovery remain available. Retries run every five seconds, at most 16
events per tick. A full queue or an event above the log segment budget refuses the event and
prints `DISK event refused`.
Queued events are volatile. A power loss before retry loses those events.
Free disk space before restarting. Snapshot failures retry at most once per minute.
Dug marks remain on disk across jobs. Only consent removes them.
Workers and displays download less than 800 KB each.

Servers and displays use all attached modems and detect modem changes without a
reboot. A wired monitor or AR cable can coexist with a wireless or ender modem.

Each network should have one `so/server` host. If another host already uses that
name, the server shows its ID and keeps running for paired clients. Reboot after
the name becomes available to register it. A paired display reconnects directly
to its saved server ID, even if another server answers discovery. Fresh clients
still use hostname discovery, so isolate competing networks while pairing.

## Turtle tools

Workers report equipped tool names without moving or digging. Mining readiness
checks for a pickaxe and lumber checks for an axe. Missing tools appear in NEEDS YOU.
With automatic swaps off, these warnings never block START or interrupt planning.
Older workers without equipment queries show `tools unknown` and keep working.
The turtle terminal shows its label, assigned job, current step, fuel and reason.

Automatic swaps default to off. To enable them on a worker, add
`autoToolSwap=true` to its plain `so-worker.cfg` table and reboot. Keep any existing
`dim` field. Put one replacement tool in an inventory slot. The worker swaps only
into an empty side or a side holding a tool, keeping its modem equipped. The old
tool goes into inventory. A failed swap keeps the old tool and appears in NEEDS YOU;
retries wait 30 game seconds. Tools stay in inventory during cleanup and unloading.
Swaps check equipment first, so a replay after reboot does not swap the old tool back.
Tool durability is not checked.

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
`x y z` block coordinates. X and Z must be within 30000000 blocks of zero;
Y must be between -2048 and 2048. Select `minecraft:overworld`,
`minecraft:the_nether` or `minecraft:the_end`, also accepted as `0`, `-1` or `1`.
Enter defaults to the overworld. The installer shows the coordinates and dimension
before saving. Enter confirms; `n` starts over. The position is saved in `so-server.cfg`.

For a worker or display, press P on the running server, then enter its six-digit
code on the client. The code works once and expires after five minutes.
An already-paired display can also open PANEL, PAIR and press NEW CODE.
Its panel and the server terminal show the code and time left. Other displays
cannot see that invitation. Pressing NEW CODE again keeps the pending code.
After use or expiry, press NEW CODE for the next client.
Keep any leading zeros in the code.
The server terminal shows the ids of computers whose pairing attempts it
rejected. A computer gets two wrong codes a minute and three per code. Ten
wrong codes burn the code; press P for a new one. Wrong codes from a machine
that proves its saved key do not count toward the ten.
Pairing uses the CPace protocol, so a recorded pairing does not reveal the code.
Update the server first. Updated clients cannot pair with an older server.
Clients from the previous release still pair this release; update them before
the next one, which drops the old method.
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

Run `install rollback` to restore the release saved by the last successful update,
including its installer, startup, file list and pinned commit. Rollback works offline
and preserves pairing, configuration, saved data and journals. Only one previous
release is kept. A successful rollback consumes it; another update replaces it.
Interrupted swaps recover on startup. A rollback across different recorded protocol
versions is refused. Releases without protocol metadata use protocol 1.

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
and `ADD` to save it. `FROM #N` copies a paired turtle's fresh, proven world
position into the draft. `front` selects the cell the turtle faces. `down`
selects the chest below it. Unknown facing, stale GPS and uncertain journals
refuse the action. Review the coordinates before `ADD`. Select a point in the list for `FIX` or `REMOVE`. Use
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
asks again after section files grow by another 50 percent. At 85% disk use,
`keep` asks again after one minute even without that growth. Sharding onto
more server storage is a future option. The 80 percent disk guard still applies.

Open the `mining` display screen. Submit these text commands:

```text
home <x> <y> <z> <n|e|s|w>
bottom <y>
length <n>
mode thorough|fast
branches <n>
continuous on|off
ores diamond,iron,...
add <id>
add <id> <x> <y> <z> <n|e|s|w>
remove <id>
start
stop
```

`home` sets the chest-side position and is required before the first `start`.
`start` requires an ore drop, a fuel drop, an added paired turtle with a
reported pose and fuel, and the existing disk guard. Broken drops do not pass.
SETUP shows each missing item in red. A home stays unset until `home` is sent.
`bottom` sets the shaft bottom.
Branch length defaults to 64 blocks. `thorough` inspects walls, while `fast`
uses faster branches. `branches <n>` enables continuous mining and sets the
whole job's branch budget from 1 to 4096. The default budget is eight.
`continuous off` keeps the existing one-branch-per-worker behavior and is the
default for new and saved jobs. `continuous on` uses the saved budget.
Completed miners unload, count their branch once, return through its junction
and take the next unassigned branch. They park when the budget is assigned.
Assignments, return routes and counts survive restarts. `stop` pauses after the
current batch and preserves the remaining work. Increasing `branches` and
starting again lets finished miners continue.
`ores` selects the supported ore names and accepts spaces
around commas, such as `ores diamond, iron`.
`add` anchors a paired worker at its world position and facing. `add <id>` and
`ADD HERE #N` on SETUP use a GPS fix at most 60 seconds old in the server's
configured dimension. On each turtle, save its current dimension in
`so-worker.cfg`, for example `{ dim = "minecraft:overworld" }`. Use
`minecraft:the_nether` or `minecraft:the_end` there as needed. GPS itself supplies
no dimension. Missing or mismatched worker dimensions refuse automatic add and
FROM. Update this setting if you move the turtle to another dimension.
Facing comes from proven GPS movement or an anchored
journal. The initial local journal north is never world north by assumption.
When facing is unknown, the server reserves the turtle's cell and all four
horizontal neighbours, then requests `forward` and `gps`. The turtle moves one
block without digging and stays there. The successful GPS result establishes its
new position and facing before assignment. The standing reservation transfers
atomically to the job owner. Other probe cells stay reserved until the assignment
saves. A blocked probe refuses the add.
Missing GPS or uncertain pose requires the explicit coordinate command. A lost
probe report keeps its reservations until an explicit add clears them.
`remove` can cancel a stationary recovery or park inspection and releases the
worker's lane and reservations. Other open leases must finish first. `stop` allows
an already sent batch to finish. The screen shows worker state, pose, fuel, ore
count and errors.

Tap a worker row or a turtle arrow on the map to open its detail page. It shows
pose, fuel, inventory, lease, pending step, ore, last seen, branch progress and
errors. BACK returns to the same page. Mining rows show branch progress bars;
lumber shows planted spots against known spots. The pocket header has MAP and
MORE, with paging and PANEL in one footer row.

PARK ALL stops the mining job after its current batches. Lumber PARK parks the
selected turtle after its current batch; the other turtles continue. Lumber
`start` resumes parked turtles. Mining REMOVE needs two taps within five seconds
and follows the same lease checks as the command. Lumber `remove <id>` remains
available through text commands. An uncertain
pose appears as POSE ?. RE-ADD opens a coordinate and facing editor; confirm the
worker's actual position there, then press RE-ADD twice to submit it.

## Lumber

Open the `lumber` screen and submit these commands:

```text
area <x1> <z1> <x2> <z2> <ground y>
saplings <x> <y> <z> <front|down>
add <id>
add <id> <x> <y> <z> <n|e|s|w>
remove <id>
park <id>
start
stop
```

`start` requires farm bounds and soil height, wood and fuel drops, a configured
sapling chest, paired turtles with reported fuel, and the disk guard. Every
added worker must be paired, have a certain pose and report nonzero fuel.
SETUP lists missing items in red and configured items in green.
`area` sets farm bounds and soil height. `saplings` sets the sapling chest's own
coordinates. With `front`, the planner chooses the nearest eligible cell beside
the chest at the same height and faces the turtle towards it to take saplings.
With `down`, the turtle stands at `<x> <y+1> <z>` and takes saplings from below.
Leave these access cells clear. The planner excludes cells at or below soil
height, known obstacles, chest cells and planted spots at soil height plus one.
Distance is Manhattan distance from the turtle's current position. Ties use
north, east, south, west order. If no eligible cell remains, the turtle holds
with a named `saplings #<id> unreachable` alert.

`add` adds a paired worker with an axe and retains the others. `add <id>` uses
the same GPS fix and facing probe as mining. Stop before
changing assignments. `remove` removes the selected worker once its lease and
park report finish. Retry when requested. A turtle at a chest returns before
it can be removed. Each worker recovers its own journal pose after restart.
Workers claim separate scan positions and trees, so one lost turtle does not
stop the others. They queue for shared chests and keep access reserved until
clear. A turtle already occupying an access column finishes service before
queued arrivals enter. Keep the approaches clear. Multiple workers can detour above the normal
flight height of soil plus two. Travel protects saplings and tree bases.
With several workers, sapling trips return surplus supplies before leaving.
Work stays stopped until configured and started. `stop` parks after the current
lease reports. Log delivery counts require a successful drop and an inventory
decrease. A saved delivery receipt reconciles a lost report after restart and
prevents a second count. Failed wood, fuel and sapling chest inspections mark drop points broken
after three failures. Repair the chest, use `fix` in the generic drop editor if
marked broken, and send `start` on the lumber screen. Sapling service reuses a
matching drop point or adds a `storage` point to that editor. Remove unused old
sapling points there after changing the coordinates.
Dark oak is excluded. Empty sapling chests disable replanting
while felling continues. Configure a wood drop and a fuel drop.
Chest alerts distinguish unconfigured, broken, unreachable, full and empty
containers. Alerts name the point and coordinates. Full and empty require an
inspection of a chest, barrel or shulker box and a failed item transfer.
The screen shows each turtle, its work state and fuel, plus deliveries, saplings,
spots and alerts. Three turtles fit 26x20 and 29x12. NEXT pages longer lists.
Three failed moves or digs stop work and emit an alert for the screen and AR.
Fix the obstruction or tool, then type `start`. Refuelling starts with the
distance to the fuel chest
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
Until discovery the shop screen says `Storage room not found`.
Tap a category, use `A-Z` to jump to a letter, and sort by `STOCK` or `NAME`.
Categories come from item IDs. Unknown items appear under `OTHER`.
Tap an item, then `ORDER 1`, `ORDER 16` or `ORDER 64`. BACK returns to the
same list page. List BACK returns to status, where MORE opens navigation.
The whole flow works by touch on monitors and pockets, without a search field.
Small screens use short quantity labels and a category picker.

Each display keeps its own category, letter, sort, page, selection and order
status. An order sends once. Quantity buttons stay inactive until you return
to the list and select an item again. `Order: sent` means the request went out
or the room accepted it. `Order: delivered` requires an explicit delivery reply.
The current legacy room replies when it queues an order, so it stays `sent`.
Refusals and unanswered orders show `failed`. Orders time out after two minutes
and are never retried automatically.

Stock older than 30 seconds shows `STALE STOCK`. After five minutes without
stock, the server clears the list and discovers storage again. Rooms use the
legacy unpaired protocol; isolate competing storage networks.
Keyboard-equipped panels retain typed quick search. Monitor panels show a SHOP
button that opens the touch shop. Clients report keyboard availability in hello.
Older clients that omit it get the touch panel.
The shop also fits the padded kit from #177, whose header occupies row 2. It
measures the header and tile extent and adjusts paging to the available space.
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

### Fuel auto-order

Fuel auto-order defaults to off. Register the room's OUTPUT chest as a `fuel`
drop point. In MINING > SETUP, tap OUTPUT to select that point, then tap FUEL AUTO
to turn it on. The equivalent commands are `fuel output <point-id>` and `fuel auto on`.
`fuel auto off` stops orders. Mining and lumber share this policy.

Only an empty report from that output chest triggers an order. The server orders
64 `minecraft:charcoal`, or 64 `minecraft:coal` when charcoal stock is below 64.
It requires stock less than 30 seconds old. A saved ten-minute cooldown covers
the physical chest across workers, point aliases and server restarts. The server
saves the cooldown and outstanding order before sending. Only one fuel order
can be outstanding. A matching delivery or refusal, or a worker observing usable
fuel at that output, ends the wait. The cooldown, acknowledgements, configuration
changes and restarts never replace a waiting order. A power cut before send can
leave it waiting; `delivery unconfirmed` stays in attention until it is resolved.

Missing storage, stale stock, low stock, refused orders, failed sends and policy
save failures appear in NEEDS attention. An acknowledgement is not delivery.
After two minutes without an explicit delivery reply or a successful worker
pickup of usable fuel, attention shows `delivery unconfirmed`. Mining retries
its fuel trip on its normal schedule. Lumber retries once a minute while this
policy is on. It temporarily retains non-fuel pickups in tracked slots while
searching for fuel, then returns them to the output before refueling. Job cargo
stays in its original slots. These pickup records survive restart. A full
inventory or failed return stays in attention and keeps its retry. Turning auto
off leaves the normal manual fuel hold in place.

### Room input sinks

Room sinks default to off. Use the existing drop-point editor to register the
room's INPUT chest twice, once as `ore` and once as `wood`. On each draft, tap
ROOM ON before ADD. Tap SINKS ON to enable all marked room points. These are
ordinary drop points; the room sorts and smelts their contents through its
existing input flow. Mining keeps its junk cleanup separate.

For an existing point, `room <point-id> on` marks it and
`room <point-id> off` removes the mark. `room sink on` enables marked points;
`room sink off` excludes them from selection and job readiness. These commands
belong to the drop-point screen. The server API is also available for setup:

```lua
SO.mods.drops.add({id="room_ore",dim=0,x=X,y=Y,z=Z,side="down",kind="ore",room=true})
SO.mods.drops.add({id="room_wood",dim=0,x=X,y=Y,z=Z,side="down",kind="wood",room=true})
SO.mods.drops.roomSink(true)
```

Coordinates identify the chest block. Verify access in the test world before
enabling either feature. For `down`, the cell at X,Y+1,Z must be outside the
room, free and reachable. For `front`, a reachable outside cell must be beside
the chest at its height, and the worker must select that outside approach.
The room's internal map uses relative coordinates and does not prove this
outside access. If the input or output can only be reached from inside the
room, leave the feature off until the chest or route is changed.

After a test delivery, compare the room's ore and log stock, confirm the output
pickup and check its furnace fuel. Room geometry and actual sorting need Gate B
in a disposable world. Mock unload tests do not prove them.

## Health and attention

Open `HEALTH` or `ATTENTION` from `MORE` or the panel. HEALTH pages server,
clock, storage and network diagnostics. ATTENTION lists issues that need a
person and opens the screen for each repair. The list refreshes every five
game seconds. `ALERTS` keeps retained alert events after they clear. `EVENTS`
browses state history with a kind filter. `ERRORS` shows the bounded persistent
server error log. `PREV`, `NEXT` and `BACK` work on pockets and compact monitors.
Recent errors save at most once per 30 game seconds; a power loss can lose
records still waiting to save.

AR shows up to four broken-chest beams above the normal label budget. Its third
HUD tile shows BROKEN while a chest in the server dimension needs attention.
On the map, FOCUS centres the first broken chest; BROKEN opens its drop-list
page. Tapping a broken chest opens that point. Status also has a BROKEN tile.
The next unassigned mining branch appears in blue in AR and amber on the map.
AR trails show active progress and up to 64 recent completed branches.
For C13 label trials, set `arLabelScale = 0.6` in `so-server.cfg` and restart.
Allowed scales are 0.5 to 0.7; the default stays 0.5 until measured in-game.

### Chest setup

The drop editor's TEST button opens chest setup. SCAN lists adjacent chests,
barrels and shulker boxes around an unassigned, idle turtle. Choose its facing
with N, E, S or W when GPS has not established it. Select a found coordinate,
choose the kind, then ADD. The scan restores the original facing and transfers
no items. A chest above the turtle uses DOWN access from above the chest.

New setup movement requires `setupMovement = true` in `so-server.cfg`. It is off
by default. Workers must advertise `capabilities.parkBatch` and `capabilities.setupFence`. GPS must identify
the turtle's dimension and position, and the server must know its journal pose.
Assigned mining, lumber and builder turtles are excluded.

Select a drop point, open TEST, then press TEST #id. A free turtle visits the
access cell, inspects the block and returns to its starting pose. Visits never
dig, use at most a 64-block outward distance and refuse mining lanes, reserved
cells and routes beyond radio range. A blocked move stops the visit. Its route
stays reserved until a fresh GPS fix and a worker acknowledgment permit RELEASE. After a server restart,
`release <turtle-id>` on the drop editor releases the saved setup route using
that fresh fix. Uncertain workers need their normal explicit reanchor first.

The editor also accepts `scan <turtle-id>` and `test <point-id>`. Successful
visits save `{at, block}` on the point. Missing inventories clear verification
and count toward the existing broken-point limit. FIX remains required for a
broken point. Readiness rows show "verified by visit" or "unverified";
unverified points remain usable. Verification records an observation, so a
later removed chest can still fail during normal work.

Pairing shows a panel notice for 30 game seconds. Mining and lumber setup list
unassigned turtles with labels, ids on ADD HERE, and fuel. Labels use at most
16 characters. Refused mining commands appear in the panel's mining block;
an accepted command clears the reason.

Chest visits refuse unknown fuel or a fuel level below the complete round trip.
The refusal shows the needed and available fuel. After setup, the turtle's
standing cell remains reserved until its next setup or assignment takes it.
Display button presses must belong to the last delivered screen; stale controls
need a fresh frame before they can be used.
