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

Disk warnings start at 70% usage and name the largest measured store in MB.
Starts and job writes remain allowed below 80% if no event write is pending or
failed. At 72% the server warns and allows them; at 82% it warns and refuses.
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
With automatic swaps off, these warnings do not block START. Mining refuses dig
batches without a reported equipped pickaxe and shows `needs pickaxe`. Lumber
keeps its existing tool behavior.
Older workers without equipment queries show `tools unknown` and keep working.
The turtle terminal shows its label, assigned job, current step, fuel and reason.

Automatic swaps default to off. To enable them on a worker, add
`autoToolSwap=true` to its plain `so-worker.cfg` table and reboot. Keep any existing
`dim` field. Put one replacement tool in an inventory slot. The worker fills an empty
equipment side before replacing a tool on the other side. It protects non-tool
equipment, including its modem. The old tool goes into inventory. A failed swap keeps the old tool and appears in NEEDS YOU;
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
a mouse click, or monitor touch. SERVER and DISPLAY are separate buttons.
Only touches inside a drawn button select it. With a monitor attached, display
is the default.

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
A wrong code stays on the display, so Backspace can fix one digit. Typing a
seventh digit starts a new code.
The server terminal shows the ids of computers whose pairing attempts it
rejected. A computer gets two wrong codes a minute and three per code. Ten
wrong codes burn the code; press P for a new one. Wrong codes from a machine
that proves its saved key do not count toward the ten.
Pairing uses the CPace protocol, so a recorded pairing does not reveal the code.
Update the server first. Updated clients cannot pair with an older server.
Legacy pairing stays enabled unless `so-server.cfg.retireLegacyPair=true`.
Set it only after updating turtles, pockets and wall displays, then restart the
server. Only boolean `true` retires legacy `pair`; saved pairings keep working.
Updated clients use `pair2`. The release notice is
[issue #308](https://github.com/140er/computercraft-scripts/issues/308).
Startup prints `legacy pair: retired` or `legacy pair: kept`. The next-release
removal notice appears only while legacy pairing is kept.
Displays show the pairing prompt and digits on the monitor and computer terminal.
Backspace removes a digit. The sixth digit starts pairing. If it fails, the
display shows the reason and accepts a new code. Displays keep looking when
the server is absent and reconnect after it restarts.
Each machine starts its installed program immediately and on reboot.
Paired turtles never ask for another code at boot. They show `waiting for server`
and retry discovery and authenticated hello with backoff capped at 30 seconds.
If discovery fails, they use their saved server id. Unpaired turtles keep
retrying discovery while waiting for six digits and Enter at `Code:`.
Before pairing, the boot code row shows the discovered `server N`.
An unpaired worker honors the server selected by `install --server <id>` even
if discovery finds another server. Saved pairing keys govern paired boots.

Display text commands appear on the bottom row while you type. Backspace
edits the line and Enter sends it and clears it. Wall displays also echo the
line on the computer terminal. Screens at least three rows tall reserve one
row for input, leaving the remaining rows for server frames and buttons.
Full-screen kit frames use every row; while you type, the line covers the bottom row.

`install <token>` refuses enrollment if `so-keys`, `so-keys.bak` or `so-keys.tmp`
exists. It asks you to run `install reset` first and writes no `so-enroll`. Reset
confirmation shows the number of paired keys from `so-keys`, or from `so-keys.bak` when
the primary file is missing or unreadable. It never prints key text. Each downloaded
file is named before its HTTP request. Successful `install update` and `install rollback` commands print `Updated <role> from <old7> to <new7>` and immediately start
the installed role program. Missing or invalid revision metadata appears as `unknown`. A
failed update or rollback starts no role program.

Run `install <full-sha>` for a fresh install or `install update <full-sha>` for
an update to a full lowercase 40-character commit. All files come from that
commit even if the branch moves. The installer verifies that the commit belongs
to `server-only` history. It checks space before
bootstrap downloads and again for the complete role plan. Ordinary downloads
retry a failed file up to three times. Explicit-SHA installs and updates use one attempt for bootstrap downloads.
With the current pinned installer, remaining files allow up to three attempts.
Guarded worker updates use one attempt per file.
Run `install check` to compare the installed revision with the branch without
changing files. Failed branch lookup reports an error. Rerunning the server
installer updates its position and keeps other settings, including `enroll`.

Run `install update` to download the saved role again. `update` calls the same
installer. Updates preserve pairing keys, the worker journal, drop points,
display settings, server position and `so-data/`. All downloads must return
non-empty HTTP 200 responses, and Lua files must compile before any installed
file changes. Startup recovers interrupted swaps before launching the program.
A failed download leaves the installed files in place. A private repository may
answer "not found".

Run `install rollback` to restore the release saved by the last successful update,
including its installer, startup, file list and pinned commit. Rollback works offline
and preserves pairing, configuration, saved data and journals. It deletes a
waiting enroll token, so enroll again after a rollback. Only one previous
release is kept. A successful rollback consumes it; another update replaces it.
Interrupted swaps recover on startup. A rollback across different recorded protocol
versions is refused. Releases without protocol metadata use protocol 1.

Run `install reset` and type `yes` to delete everything except `install.lua`
and `/rom`. This removes pairing keys and saved data. Run `install` again and
pair the machine again after a reset.

### Space admission and offline kits

Online installs resolve one commit and read its Git-tree sizes and blob IDs
before downloading code. The first space check covers the bootstrap installer
and its role and digest helpers. The second uses that verified installer's role
list and refuses before role-code downloads if space or metadata is missing.
Both checks print required and free bytes. Refusal preserves installed files
and the retained rollback release. Missing destination paths use their nearest
existing parent's drive; paths on another mount still refuse.

Failed downloads remain in `/.so-download/`. Run `install update [sha] --resume`
or `install --resume` to reuse verified files at that same commit. The console
prints `Resuming pinned commit <full SHA>`. A normal retry starts a new cache.
A successful online install removes the cache. Rollback checks space too.

On a machine with HTTP access, run `install kit <mount> <role> <full-commit-sha>`.
Use a separate disk with space for the complete kit. Export downloads the pinned
release and publishes `so-kit/manifest` last. The kit has code and dependency
licences, with file sizes, Git blob IDs and SHA-256 digests. It has no keys,
config, runtime data, journals or enrollment tokens.

Use a trusted installed or manually supplied installer to run
`install offline <mount>`. A kit runs its own installer. Only use disks from a
trusted source. Digests detect changes relative to the manifest; they do not
prove who supplied it. Offline installation verifies the role file list, sizes,
both digests and Lua syntax before changing installed files. The offline installation path uses kit files without download requests or online
fallback. The kit installer runs with normal environment access, so only use kits
from a trusted source. Older pinned installers without staged-update or offline-kit
support are refused. Fresh machines pair afterward; updates preserve runtime
files.

### Pinned worker updates

Set `panelUpdates=true` in `so-server.cfg` and `remoteUpdates=true` in
`so-worker.cfg` to allow `SO.updateWorker(id)`. Both default off. The server
proposes its running full revision to one idle, unassigned worker. Requests
are refused rather than queued. Busy, offline or older workers refuse, as do
workers with recovery holds, uncertain journals or a saved API cooldown.
A cooldown refusal shows `api cooldown` and starts no installer or reboot.

The installed updater proves that the target belongs to `server-only` history
and strictly descends from the running worker revision. Unknown, equal, older,
diverged or malformed revisions refuse. It checks GitHub response budget headers
and uses at most four sequential API calls per uncached remote update, including
the pinned tree. Missing budget headers, insufficient budget or a failed request
stop the attempt. There is no automatic API retry or rate-limit polling.
Ten simultaneous workers need at most 40 calls from the shared unauthenticated
60-per-hour budget. `updateApiRetryAt` saves the UTC-second cooldown across reboot.

Code comes only from the fixed repository at the full target SHA, with redirects
disabled. A pinned failure never falls back to branch code. Trust rests in the
paired operator, repository history and GitHub/TLS, without a separate content
signature. A locally typed `install update <sha>` can select an older commit
that still belongs to branch history. Unpinned manual updates remain available
for old clients.

After acceptance, the worker stops accepting leases, leaves its event loop,
runs the installed updater and reboots after success or handled failure.
Only a later hello with the target revision confirms completion. Pending state
expires after 120000 game milliseconds and does not survive server restart.

### Local worker settings

Set `settingsControl=true` in `so-worker.cfg` to show WORLD, NETHER, END and SWAP
on the turtle. Set `workerSettings=true` in `so-server.cfg` to permit backend
settings requests too. Both flags default off. `remoteDimensions` separately
controls remote movement.

Stop and unassign the turtle before editing. Queued work, recovery, journal
uncertainty, an unexpired park or stale server/unassignment contact blocks edits.
Local and remote edits share the same durable record; the last saved edit wins.
Turning SWAP on equips no tool. Changing dimension with retained history saves
uncertainty and requires an explicit re-anchor. Config recovery also holds
movement until an explicit re-anchor in a configured dimension.

### Copy job setup from a turtle

Set `jobPoseSetup=true` in `so-server.cfg` to enable paired-pose setup chips.
It defaults off. Mining HOME copies the selected assigned turtle's occupied
cell and facing. Mining and lumber let each display select a turtle. Lumber
and build capture FROM, then TO; each display keeps its own first corner.
Lumber ground is one block below FROM. Build corners are one block below each
captured pose. Build HOME copies its assigned turtle's occupied cell and facing.
Open leases, lost or uncertain poses and recovery refuse capture. Job validation
still applies. These controls configure the job without moving the turtle.

Mining shows COMPLETE after all workers, branches and supply/return work finish.
To add branches, increase the budget and press START. Raising the budget alone
does not resume work after restart. Build shows COMPLETE with placed/total cells.
Each job saves one completion notice; ticks and restart do not repeat it.
Mining and lumber show no worker-fuel warning with zero assigned turtles.

## Display roles

Each display shows one role. Only the server changes it. Press `R` on the
server terminal, type `<id> <role>` and press Enter, for example `7 mining`.
`7 -` clears the role. The list above the prompt shows every display's id,
size, role and computer label. Esc closes the prompt.
`<id> far on|off` changes text scale. `<id> identify` shows that display's id
for five seconds. Status ALERTS opens the complete newest-first alert list.
Server monitor taps redraw at once.

Roles are `status`, `pocket`, `mining`, `lumber`, `shop`, `drops`, `ar`,
`panel` and `map`. A new pocket gets `pocket`: its glance page and panel page
switch with `PANEL` and `GLANCE`. Any other new display shows `UNASSIGNED`
with its id in big digits. The server's own monitor shows status; assign it
another role with the server's own id. Roles survive restarts.

The panel PAIR page has an ENROLL ON/OFF switch. With `panelUpdates=true`, stale
paired turtles offer UPDATE where space allows; worker opt-in is still required.
FORGET confirmation shows its job impact. With `workerSettings=true`, tap a
turtle row for confirmed dimension and tool-swap settings. Confirmed values stay
unchanged while changes are pending. A matched acknowledgement or a newer hello
confirms the settings; a rejection or a 15-game-second timeout clears the pending
state. The panel also shows a read-only BUILD block when the build module is
available.

## Map

Assign the `map` role to a display. The map fits the configured mine, farm, drops and turtles on
entry with all levels projected. `FIT` restores that view after using `+`, `-` or the four pan buttons.
Each display keeps its own view until the server restarts.

North is up, x increases to the right and z increases downward. Grey cells are
planned shaft, spine and branches. Light grey cells are known dug blocks. `H`
marks the shaft and `@` marks the server. Turtles use `^ > v <` for heading,
with their id beside them when it fits. Busy turtles are green, idle turtles
amber, lost or out-of-range turtles coral, and finished turtles blue.
Chest letters include `O` for ore, `F` for fuel, `W` for wood and `S` for
saplings. The farm outline is green. Broken drop points are coral.
A builder appears only at its confirmed pose in this dimension. Unknown poses
hide its marker. Its blueprint outline remains and contributes to FIT bounds.
Held builders show their hold and placement progress.

The bottom button cycles `MINE`, `SURFACE` and `ALL`. Mine selects the job's
bottom y level. Surface selects the server's y level, or the farm ground when
there is no server position. All projects the scene and scans dug blocks at the mine bottom, tunnel roof,
surface, farm ground, and known chest and turtle levels. Dug blocks appear progressively, with at
most 256 cell reads per frame. At coarse zoom, several blocks share one cell.
Turtles draw above landmarks and cells. The map starts in the server's dimension.
With remote jobs enabled, the bottom-right button cycles WORLD, NETHER and END.
Each display keeps its dimension choice. Workers, chests, routes and dug marks
always use the selected dimension.

## Nether and End jobs

Remote jobs default to off. Set `remoteDimensions = true` in `so-server.cfg`
to enable them. Keep its existing position and other settings. Use ender modems
on the server and remote turtles. They work across dimensions with unlimited
range. This flag leaves overworld radio-range checks unchanged.

Update the workers, then set each remote turtle's `so-worker.cfg` to its actual
dimension, for example `{ dim = "minecraft:the_nether" }`. Restart the worker.
The server requires a matching dimension and the updated worker's safety
capability before it sends remote work. A dimension change in a worker with
journal history marks its pose uncertain. Explicit add re-anchors it and clears
that old move and dug history before work resumes.

Set a mining home with `home <x> <y> <z> <n|e|s|w> [dimension]`, or a lumber
farm with `area <x1> <z1> <x2> <z2> <ground> [dimension]`. Dimensions accept
`minecraft:overworld`, `minecraft:the_nether`, `minecraft:the_end`, or the short
names `overworld`, `nether`, `end`. Omit the dimension to keep the current one.
Stop the job and remove its workers before changing dimensions. The new home
or area replaces the old one. Mining starts with bottom 15 in the Nether or
48 in the End. Set the intended depth before starting.

Use `add <id> <x> <y> <z> <n|e|s|w>` with the turtle's actual coordinates and
heading. Remote ADD HERE refuses GPS, even if it returns coordinates. GPS
replies do not identify the hosts' dimension, and ender modems can hear a
constellation in another dimension. An explicit pose anchors the journal
without GPS. Interrupted moves with finite fuel use the saved fuel count.
Unlimited-fuel moves without reliable evidence require an explicit re-add.

Overworld journals keep their existing format. An absent journal dimension
means overworld in memory, and saves omit the overworld dimension field.

Remote turtle movement stays within Y 1..126 in the Nether and 1..255 in the
End. The End's void below Y 0 is outside every route. Turtles fly, so a route
can cross open air above that limit. Lumber also requires room for its ground
plus four travel level. A worker inspects immediately before every remote move
and refuses lava, water or an unknown cell. It stops the remaining batch on a
failed move. After each Nether move it also inspects all six adjacent cells.
The horizontal scan turns in place and journals each turn, then restores its
heading. Source or flowing lava stops the batch, parks the turtle and raises
`lava at x,y,z` with the observed lava's world coordinates. A completed move
still counts as movement, so recovery retains the turtle's new pose.

Inspection and movement are separate commands. Lava can flow into the destination
between them, and these checks cannot prevent every entry into liquid. Lava can
also change during or after the surrounding scan. The post-move check reduces
silent work beside lava; it does not make movement atomic or inspect the block
occupied by the turtle. Turtles take no lava damage. Clear the reported hazard
and check the turtle before restarting. Mining can seal fluids or scoop source
lava before retrying.
The ore filter accepts `quartz`, `nether_gold` and `ancient_debris`.

Set ore, wood, fuel and sapling chests in the job's dimension. Drop-point
numbers are 0 for overworld, -1 for Nether and 1 for End. Jobs never travel
through portals or use a chest in another dimension. Reservations and dug
marks remain separate even when coordinates overlap.

These jobs do not load chunks. Keep the turtle, route and service chests loaded
while it works. Leaving the dimension can unload them and stall the job.
The screen shows `remote silent; unloaded?` after a missing lease report.
That is a possible cause, not a measurement of chunk state. Reservations stay
held, and remote workers beacon in place after expiry. They never reverse an
old route without inspection. Restore chunk loading, wait for recovery and
resolve any displayed cause before restarting work.

AR draws only the configured server dimension by default, or overworld when
there is no position. Set `arDim = "minecraft:the_nether"` or
`arDim = "minecraft:the_end"` in `so-server.cfg` and restart the server to select
a remote overlay. Match that setting to the dimension where the goggles are
used. The controller cannot infer the wearer's dimension.

## Drop points

Assign the `drops` role to a display for the drop-point list. Tap `ADD NEW` to open the editor. Use the kind and side buttons
to cycle values, the dimension and coordinate buttons to adjust the draft,
and `ADD` to save it. `FROM #N` copies a paired turtle's fresh, proven world
position into the draft. `front` selects the cell the turtle faces. `down`
selects the chest below it. Unknown facing, stale GPS and uncertain journals
refuse the action. Review the coordinates before `ADD`. Select a point in the list for `FIX` or `REMOVE`. Use
`PREV` and `NEXT` to page through the list. The editor's `BACK` returns to the
list. All controls fit a 26x20 pocket or 29x12
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

Mining and lumber each have `START`, `STOP` and `SETUP`. Setup's `BACK`
returns to its main page. Shop item tiles open the order page, whose `BACK`
returns to the list. No screen links to another role. Every page fits 26x20
and 29x12. Compact mining rows show the full x,y,z position before state.
Mining SETUP has SINGLE and CONTINUOUS controls. Continuous mode has a branch
stepper from 1 to 4096 and a route-based fuel estimate. The estimate excludes
ore detours and chest trips. Ore taps preserve other filters, including Nether
ores. An empty filter means all ten supported ores. Narrow screens open a
separate ore editor. Empty auto-fuel pickups retry after one game minute.

The server stores dug marks in compact 16x16x16 sections. At 1 MB of section
files, every display shows a request to forget old areas, with `allow` and
`keep` buttons. AR goggles show the same request. Each area is one section.
Nothing in the world changes. Turtles inspect forgotten blocks if they return.

`allow` forgets the oldest eligible marks, aiming for 650 KB. Running job areas,
reservations, open leases and worker recovery paths stay protected. If an area
becomes protected after the request appears, the server keeps it. Recovery
history stays protected even after a worker is removed from a job.
The banner asks "Dug marks X. Forget N areas (Y)?" with ALLOW and KEEP in at
most three rows at 26x20 and 29x12. KEEP shows "Kept." and saves a ten-minute
snooze across reboot and storage growth. Later threshold requests need another
50 percent growth. Under disk pressure, the snooze shows "Disk full. Add disk
space." and an "Add disk space" row in NEEDS. After the gap, pressure may ask
again for any previous choice. ALLOW has a one-minute gap. A pressure offer can
retire all offered sections that remain safe, even below 650 KB.
The 80 percent disk guard still applies.

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
Assignments, return routes and counts survive restarts. `stop` waits for sent
batches to settle and clears route geometry. `start` rebuilds routes using the
existing branch claims. Increasing `branches` and
starting again lets finished miners continue.
Mining refuses `home`, `bottom`, `length`, `branches`, `continuous` and `mode` edits
while the job runs or a turtle row still holds a route. Changes to home, bottom, length
or mode reset geometry and progress. Branch-budget and continuous-mode changes retain
progress.
A cell that fails three mining digs is skipped, with its failure count saved across
server restarts. Mining bypasses skipped cells and continues the branch. Detours avoid
known containers and protected cells. If inspection discovers an obstacle on a saved
detour, mining discards that path and replans. If no path is found within the bounded
search, the unreachable goal is saved as skipped and the job continues without waiting
for the player. Recovery counts an interrupted dig attempt unless the worker's dug
history confirms success. Skipped cells are never recorded as dug. Mining refreshes its
standing-cell reservation even when it already owns the cell, so a pending release
cannot free the occupied pose.
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
`remove` refuses a turtle whose last reported pose is in the shared shaft or
bottom spine. Wait for an off-lane pose. It can then cancel a stationary recovery
or park inspection and release reservations. Other open leases must finish first.
Unfinished branch claims, including a return-trip claim, are reassigned before
a new branch is allocated, without increasing `nextBranch` again. `stop` allows
an already sent batch to finish. The screen shows worker state, pose, fuel, ore
count and errors.

Tap a worker row or a turtle arrow on the map to open its detail page. It shows
pose, fuel, inventory, lease, pending step, ore, last seen, branch progress and
errors. BACK returns to the same page. Mining rows show branch progress bars;
lumber shows planted spots against known spots. The pocket header has MAP and
MORE, with paging and PANEL in one footer row.

PARK ALL stops mining after its current batches. Lumber PARK pauses the selected
worker. Mining REMOVE needs two taps within five seconds. Lumber removal uses
text commands.

Set `workerPark=true` in `so-server.cfg` and restart to enable per-worker
`park <id>`, `resume <id>` and `remove <id>` on mining, lumber and build screens.
The flag defaults off. PARK finishes the current batch, shows `parking`, then
shows `parked` after a stationary report. Other workers continue. RESUME cancels
that pause or pending removal. START keeps these pauses while the flag is on.

REMOVE waits for a confirmed park and reservation cleanup before deleting the
job row. Lost or uncertain workers keep their rows and reservations until
recovery and a fresh park report. There is no force path. Mining waits outside
its shared shaft and spine; lumber waits outside its held chest-access lane.
Resume to clear the lane, then remove again. Cleanup keeps the occupied cell
reserved as `gps:<id>`. Adding the worker to a job reclaims it. Unfinished mining
branches return to the queue. Removing the builder stops its job.
Turning the flag off and restarting clears and logs these pauses and pending
removals. Assignments remain and resume after recovery. With the flag off,
lumber START resumes legacy PARK pauses.

An uncertain pose appears as POSE ?. RE-ADD opens a coordinate and facing editor; confirm the
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
changing assignments. With `workerPark=true`, `remove` queues the confirmed
park and cleanup described above. Failed cleanup retains the row for retry.
A turtle at a chest returns before
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
Dark oak is excluded. In REPEAT, empty sapling chests disable replanting
while felling continues. ONCE holds until replanting can finish. Configure a wood drop and a fuel drop.
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
same list page.
The whole flow works by touch on monitors and pockets, without a search field.
Small screens use short quantity labels and a category picker.

Each display keeps its own category, letter, sort, page, selection and order
status. An order sends once. Quantity buttons stay inactive until you return
to the list and select an item again. `Order: sent` means the request went out
or the room accepted it. `Order: delivered` requires an explicit delivery reply.
Getting or Crafting keeps the order pending. Without acknowledgment, orders
fail after two game minutes. Acknowledged orders wait ten game minutes from
dispatch, then fail with "no delivery". Refusals show failed. The server never
retries orders automatically.
Keyboard panels show the best shop match, stock, last order and room reply.
Pocket SHOP adds STACK and ALL. ALL orders stock up to one stack and is disabled
at zero stock.

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
stays the same, turtles show `No key on server` above `Code:`. Displays retain
their `Old key kept` prompt. Press P on the server and type the new code on each client. Turtles also require Enter. The
client keeps its old key until pairing succeeds. A normal authenticated reply
restores the client screen, so a false prompt does not require a reset.

A fresh turtle shows `UNPAIRED` on row 4 until it saves a pairing key. After
pairing, that row shows the server contact age or current job status. A failed
first-boot pairing shows `Pair failed: <reason>` below `Code:`.

With default-off `shopSaved=true`, shop, panel and pocket displays share saved
lists and up to four pinned exact item IDs. LISTS opens without ordering.
Each list holds up to 32 items; there are at most 16 lists. Counts must fit the
known stack size. ORDER rechecks the saved revision and fresh stock, and each
drawn control sends once. Stale edits refuse with `changed`. An empty panel or
pocket search shows the first pin. Turning the flag off retains the saved files.

### Replacing the server computer

Set `repairServer=true` in each display's `so-display.cfg`. It defaults off.
While the keyed display is not live, press `r` at its own keyboard or click the
top row on its own screen. Choose CHANGE SERVER, confirm the candidate id and
type the new server's six-digit code from P. Wall taps only show the saved id.
Wrong codes, exchange timeouts and failed saves keep the old key and leave
REPAIR open for another attempt. Cancel, or two minutes without input, resumes
the old server on its existing timer. During `Pairing...`, wait for the
exchange to finish; CANCEL is unavailable. Success saves only the proven server.

### Managed room output recovery

Set `managedOutput=true` in the room turtle's `room.cfg` to enable managed
outputs. It defaults off. A claim binds one server and the room's output and
admits one tagged request. This does not enable managed requests in the server's
legacy shop adapter. A settlement receipt, rather than an empty chest, proves
that queued work, crafts and carried cargo cannot emit for that request.

Saved output state starts quarantined after reboot. On the room turtle, run
`output reconcile` to cancel pending work, return cargo to storage, return home
and save a settlement barrier. Full storage, unresolved cargo or failed saves
keep quarantine. The network cannot run this command. Turning the flag off
retains the interlock and recovery state and refuses new claims and orders.

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
changes and restarts never replace a waiting order. With auto enabled, after
120000 game milliseconds a successful save clears waiting and leaves
`fuel order timed out` in attention, including after restart. A later empty report
can order again after the physical chest's 600000 ms cooldown, with fresh stock
and only one outstanding order. Late replies for the timed-out request are ignored.
If saving the timeout fails, waiting remains and tick retries without an alert event.
`shop.fuelClear()` saves a manual release of waiting and its alert while retaining
chest cooldowns.

Missing storage, stale stock, low stock, refused orders, failed sends and policy
save failures appear in NEEDS attention. An acknowledgement is not delivery.
Getting or Crafting replies do not extend the timeout. The timeout alert survives
restart and cooldown until a new order, usable pickup, manual clear, policy
change or later fuel failure replaces or clears it. Mining retries
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
server error log. NEEDS includes pending enrollments and recent server errors.
HEALTH also shows module counts and load/tick status, `rev`, `cfg`, saved
position and GPS gap. The revision row shows eight characters or `unknown`.
The cfg rows list recognized enabled startup flags, `defaults` or `unreadable`.
Storage rows use KB and MB. NEEDS warns if boot GPS differs from the saved
position by more than two blocks. The warning does not move the saved origin.
An unreadable existing `so-server.cfg` warns in the terminal, error log and
NEEDS that defaults are active. Repair the file before relying on its flags.

HEALTH also pages refused-message totals by reason, retained sender counts,
capacity evictions and the slowest module's peak tick cost and age. Sender
counts use ten-minute game-time buckets and retain at most 128 senders.
Reason totals survive expiry and eviction until restart. Refused traffic writes
zero ERRORS lines per sender per ten minutes.

Set `alarm=true` in `so-server.cfg` for severity 1 notes on the first speaker
by sorted name. It defaults off. Startup and enabling establish a silent
baseline. New issues sound once; standing issues repeat every five game minutes.
Display snoozes do not mute the server alarm. Missing, busy or failing speakers
skip the attempt. The server attempts at most one note per tick.

`soundQuiet` defaults to false. For 23:00 through 07:00 Amsterdam time, use
`{startMinute=1380,endMinute=420}`. Quiet hours include the start and exclude
the end. Equal endpoints mute all day; invalid values mute sound and report an
error. Existing reminders wait five game minutes after quiet ends. A new issue
first seen when quiet ends can sound immediately. Sound settings refresh each
tick. Set `pocketTone=true` for one note on a speaker pocket when a new stop-level
takeover opens. It defaults off and follows `soundQuiet`. The tone waits up to
ten game seconds for its matching health key. Standing alerts after restart
stay silent. A missing, busy or failing speaker skips the note. A tone lost in
transit is not resent.

A lost turtle's NEEDS row shows silence age and its last known world position.
Tap it for BACK, SNOOZE and OPEN. SNOOZE hides that turtle's lost row on all
displays for one game hour. Contact or server restart clears the snooze.
OPEN goes to its job page. Other warnings remain visible.
ERRORS rows open the complete message with wrapping, paging and BACK.
`PREV`, `NEXT` and `BACK` work on pockets and compact monitors.
Recent errors save at most once per 30 game seconds; a power loss can lose
records still waiting to save.

CLEAR opens a ten-game-second CONFIRM or CANCEL choice on that display. A new
error requires a fresh confirmation. Leaving ERRORS or restarting cancels it.
A successful clear saves an empty log and resets all ERRORS detail selections.
Standing alerts, event history and reservations remain. A failed save keeps the
visible rows and shows its cause. After a reported save failure, restart can
recover the old ring or a newer verified empty temporary generation.

AR shows up to four broken-chest beams above the normal label budget. Its third
HUD tile shows BROKEN while a chest in the server dimension needs attention.
On the map, FOCUS centres the first broken chest; BROKEN opens its drop-list
page. Tapping a broken chest opens that point. Status also has a BROKEN tile.
The next unassigned mining branch appears in blue in AR and amber on the map.
AR trails show active progress and up to 64 recent completed branches.
Map dots show the newest 20 recorded poses per assigned mining or lumber worker.
They follow the dimension and level filter and disappear when parked or removed.
They do not fade with time or affect FIT; older dots are dropped to fit the frame.

With `arFollowups=true` in `so-server.cfg`, AR offers ALL, turtle and drop focus.
It defaults off. Focus hides unrelated geometry but keeps broken-chest warnings,
HUD totals, alerts and retirement consent. A missing target shows `missing` until
ALL is selected. With `remoteDimensions=true` too, WORLD/NETHER/END saves the AR
dimension and resets focus to ALL. Changes redraw without restarting.
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

With `dropsSavedSetup=true` in `so-server.cfg`, SETUP saves FOUND candidates
and offers SUSPEND/RESUME for a selected point. The flag defaults off. ADD keeps
the candidate; CLEAR FOUND requires two taps. Suspended points remain listed
but new selections skip them. Existing committed trips finish. Suspension sends
no movement or cancellation. Saved suspensions still exclude points with the
flag off; re-enable it to resume them. Archive all `so-drops` generations before
rollout, because older binaries reject the v2 file.

### Test several chest points

Set `dropsTestQueue=true` and `setupMovement=true` in `so-server.cfg`.
Both default off. In SETUP, TEST ALL visits unverified usable points in the
current dimension. CHECK SELECTED visits that display's selected points,
including verified ones. Narrow screens shorten it to CHECK. One idle turtle
visits at most 64 points in list order. Each visit rechecks admission and counts
only after inspection, saved verification, return and occupied-cell handoff.

STOP QUEUE drops pending visits and lets the active return finish. Failures and
FACING also drop pending visits. Leaving SETUP keeps the queue running. Restart
clears the queue and selections but keeps fenced recovery reservations.

Mining retries and lumber fuel/sapling services recheck current drop usability.
Suspended, missing, broken or unreadable points hold with that reason. START
and restart cannot bypass it. Committed commands and safe returns finish.
Saved suspensions still apply after `dropsSavedSetup` is disabled.

### Forget a paired device

Open PANEL, PAIR, PAIRED. Find the id and tap FORGET, then CONFIRM within
15 seconds. The panel lists the role or kind, time since last seen and a
four-character key fingerprint. A display cannot forget itself.

The server removes the key and parks mine, lumber and build assignments. It
keeps possibly occupied cell reservations because the turtle may still be
moving, and sends a best-effort stationary park. Other lumber workers continue.
Setup scans and chest visits are cancelled. Their route moves from setup
ownership to GPS recovery holds until the turtle is explicitly re-added. Re-pair and
explicitly re-add the turtle at its actual pose before resuming it. The next
hello shows `No key on server` above `Code:` on the turtle. NEEDS includes
the most recent forget event.

### Revoke from the server terminal

Set `terminalRevoke=true` in `so-server.cfg`. It defaults off. Press R, type
`<id> revoke`, then repeat that numeric ID within 15 game seconds. The prompt
shows `parks N jobs` and adds `holds 1 scan` for busy setup work. A mismatched
ID, Escape, timeout, changed key or disabled flag cancels. A normal role command
also cancels the pending confirmation and runs normally. Confirming revokes
the key and runs durable cleanup while retaining possibly occupied reservations.

### Enroll many turtles

Enrollment is off by default. Add `enroll = true` to the existing
`so-server.cfg` table and restart to enable it at setup. The server API
`SO.enroll.setEnabled(true)` also saves the runtime switch without a restart.
`SO.enroll.setEnabled(false)` closes the window and drops
undecided rows. Approved devices can still collect their results for ten minutes
after the decision. Restart keeps the switch but closes the window.

Open PANEL, PAIR and tap ENROLL. The page shows a token such as
`12-K7QP-3MXA-9WTD-HR2E`, the time left and how many turtles joined. The window
lasts ten minutes and takes at most 20 turtles. Paste the same command on each
turtle:

```text
wget run https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/server-only/install.lua 12-K7QP-3MXA-9WTD-HR2E
```

On an unkeyed turtle that already has the installer, run `install <token>`
with the token from the server's PAIR page, then approve it on the panel.

If the turtle still shows `Code:` after the install, paste or type the token
there and press Enter. Each turtle then appears on the panel as a row with its
id, `TURTLE` and a four-character fingerprint. While approval is pending, the
turtle shows `approve on panel <fp>` with the same fingerprint. Tap OK or NO per
row, or APPROVE ALL for the rows on the screen. Rows that did not fit wait for the next tap. CLOSE ends the window. Approved turtles keep their own keys;
the token is never a key and the server does not save it.

Only the display that opened the window sees the token and its controls.
Anyone who has the token can ask to join, so approve only turtles you expect;
compare fingerprints if in doubt. When two requests use the same id, that id
cannot join in this window. A turtle stops and keeps no key when two different
servers answer its token.
Joining or a tagged refusal deletes the token file. Window closure and timeout
keep the token and secret for retry. An off reply pauses the attempt across
reboot. Re-enter the token locally or rerun the installer to resume it. The same
token keeps its secret. The window owner can reset the deadline to ten minutes from now
without changing its token or approval cap. A server restart closes the window.

The installer can stage tokens for workers, pockets and wall displays with
`install <token> [sha] [--server <id>]`. Selection must match the token's server
and requires an unpaired client. Any `so-keys`, `.tmp` or `.bak` generation
refuses token installation and server selection. The installer preserves unrelated
client config fields. A token replaces an existing saved server selection with
its server id. A pinned installer that lacks option support refuses the install.
An unpaired pocket or wall display attempts enrollment once at boot and shows
`Enroll <fingerprint> <state>` while waiting for approval. A paused `off`
attempt resumes after local token entry or an installer rerun. Pasting at the
computer terminal or pocket screen starts another attempt; monitor taps never
enroll, resume or repair. Failed enrollment leaves code pairing available.
`so-display.cfg.server` selects an unpaired join. Saved keys govern paired boots;
use REPAIR to change a keyed server.


## Lease recovery after restart

The server saves open leases before sending and restores them before dispatch.
It reconciles the acknowledged prefix with saved job receipts. It never retries
movement after restart. A failed radio send keeps the lease open; without an
accepted report, recovery waits until after its deadline plus ten game seconds.
Restored and expired work then needs a stationary journal fence. Reservations
stay held. This recovery runs even with feature flags off. Workers without both
`setupFence` and `parkBatch` need an update before they can resume.

Corrupt main or backup lease files block dispatch. An invalid uncommitted
`leases.tmp` is discarded. Forget deletes the lease record but retains possibly
occupied reservations; re-pair and explicitly re-add the turtle to recover it.
Interrupted setup visits keep their route and need new approval. Lease
persistence has no opt-out and does not promise exactly-once callback effects.

## Builder holds and idle workers

Invalid BUILD commands and configuration refusals show feedback for five game
seconds and keep any saved hold.
NEEDS uses one stable `build:<cause>` row per current builder cause. Fix the
reported cause before retrying START. Fuel and material rows stay during
supply retries until a report confirms enough fuel or material. A partial
refill may leave the fuel row active.

Legacy generic holds keep their original diagnostic through recovery and
restart. Review BUILD, then use START after readiness passes. A failed
completion save remains a safety hold until a save succeeds. Unknown builder
poses stay off the map data while blueprint bounds remain. Drawing builder
markers remains a follow-up.

An idle worker stays paired after its completed lease report is acknowledged.
Recovery then requires a full lease duration without authenticated server
contact. Work leases backtrack after silence; park leases stay put and beacon.
Remote workers keep their stationary recovery rule. Reusing the worker's last acknowledged lease ID returns `expired` for every
requested step and runs nothing.

Set `displayAck=true` in `so-server.cfg` to measure display freshness from
successful frame drawing. It defaults off. Updated displays become stale after
ten game seconds without a frame ack. Older displays show `unverified`.
Without the flag, freshness still uses the last send.


## Protected paths and reservation release

Set `protectedAreas=true` in `so-server.cfg` and restart to enable protected
boxes. It defaults off. The server API `SO.mods.cells.protect(boxes)` saves up
to 64 boxes with unique IDs, dimensions and inclusive integer bounds.
`SO.mods.cells.protected()` returns the saved set and any load error.
Saved boxes remain when disabled. Invalid protection data holds movement.
Activation and edits wait for reconciled leases and reservation holders.
One offline holder blocks activation until it reconciles, without a timeout bypass.

Protection checks movement, dig, place and drop targets. Ordinary movement and
these writes from inside boxes are refused too. Mining, lumber, builder and
setup stop each prefix at its first move or turn. A matching report must prove
the expected pose and facing with an advanced journal before the next prefix.
Failed or missing movement reports retain reservations until stationary recovery.
Route assessment uses memory-only clear facts. Unknown cells are not proven clear.

An idle unassigned turtle inside protection needs an approved exit through
known-clear cells. `SO.mods.lease.exitRequest(id,steps,actor,token?)` previews
then confirms the same path within 30 game seconds. The complete route reserves
before movement. It allows at most 16 moves and 64 move/turn operations, ends
outside all boxes, and cannot enter a new box or re-enter a departed one.
A failed boundary or restart discards approval and retains reservations.

Set `worldEdits=true` in `so-server.cfg` to enable reservation RELEASE,
authenticated `cells.forget`, mark clearing and keep-box edits. It defaults off.
With it off, `cells.forget` errors without arming confirmation. Saved holds and
keep boxes remain. Select a map holder and tap RELEASE, then RELEASE? within
30 game seconds. The worker must be unassigned, have no unresolved lease and
have been silent for at least five game minutes. `releaseSilence` can raise
that minimum. Restart starts a fresh silence grace.

WAIT GPS means pending. The worker must acknowledge a stationary fenced GPS
lease with an advanced journal and unchanged certain pose. The server saves
its occupied `gps:<id>` cell before freeing the route. New contact, timeout,
changed reservations or failed saves keeps the route held. Recovery can prove
the occupied cell while retaining the original route. There is no offline force release.

`SO.mods.cells.clearMarks(box,actor,token?)` previews then confirms a mark-only
clear of at most 64 sections. It changes no world blocks, reservations or recovery
records. Work, recovery and any reserved section prevent clearing.
It skips unexplored areas, rechecks before each save and reports partial failures.
Restart cancels approval. `SO.mods.cells.keep(boxes)` saves keep boxes;
`keep()` reads them. Any intersection keeps the whole section during retirement,
including the final ALLOW check. Keep boxes grant no movement permission and do
not bypass the disk guard. See [the protocol](docs/server-only/PROTOCOL.md#fenced-release-and-mark-retention).

## Mining KEEP, recall and ore markers

On MINING, `keep <exact namespaced IDs>` replaces the saved list; commas or
spaces separate up to 64 IDs. `keep none` clears it. Wait for batches and recovery
to settle before changing it. KEEP prevents cleanup from discarding selected
items. Selected surplus is unloaded, while the first eligible sealing stack,
fuel, tools and utility items are retained. KEEP still requires free inventory
slots and sealing stock to dig.

Recall defaults off. While stopped, use `recall on` and
`staging <id> <x> <y> <z> <n|e|s|w>` for each assigned turtle. Destinations must
be distinct, at home height in the job dimension and outside shared lanes,
home and chest access. `recall` saves the request, stops new claims, drains
accepted work and returns without digging or sealing. Every move or turn waits
for a fenced report. Shared-lane passes reserve before entry. Unknown or blocked
routes, lost workers and insufficient fuel hold recall.

All turtles must reach their saved destinations and facings before staging
finishes. STOP pauses recall. START after staging retraces checked routes to
saved work poses and resumes unfinished mining. Restart preserves cursors and
recovers journals before travel. `recall off` cannot erase unfinished recall.
Assignments and route settings stay fixed until it finishes. Settle recall
before downgrading.

`orecoordinates on` enables proven positions on confirmed mining ore events.
It defaults off. On MAP, `ore finds on` enables yellow asterisks for that display
session; `ore finds off` hides them. Finds expire after ten game minutes.
They show only in their dimension and exact selected level, or ALL. They stay
below workers, reservations and labels and never expand FIT or change travel.
The bounded memory cache rebuilds from retained history after restart.

## Builder home and material selection

BUILD's setup material chip opens a paged list of reported inventory items and
summed counts. Selecting an item changes material without resetting completed
progress. `no report` differs from an empty inventory. The job tab shows `need`
and `carried`; carried is `unknown` before the first inventory report.
Below 24 columns only the job tab draws.

Builder return defaults off. While safely stopped, set
`home <x> <y> <z> n|e|s|w` and `return on`. The first added worker supplies home
if none exists; re-adding preserves it. Return requires a certain pose and
updated workers with `parkBatch` and `setupFence`.
The final confirmed placement starts RETURNING. Travel never digs and waits
for journal and pose confirmation after each move or turn. Obstructions, range,
reservations and insufficient fuel hold the return. Refuel manually and use START
after fixing the cause. STOP pauses it. Restart preserves placement progress
and unfinished return, then recovers the pose before replanning. Configuration
and REMOVE cannot erase it. COMPLETE waits for confirmed home position and
facing. With `return off`, completion stays at the final target.

## Lumber cycles, species and emergency fuel

Lumber defaults to REPEAT. While stopped without unfinished work, `mode once`
selects one harvest cycle; `mode repeat` restores repeating surveys.
ONCE saves the survey, claims and members. It finishes accepted trees, replants,
unloads with confirmed receipts and parks every member at a distinct clear
position outside shared access before COMPLETE. It does not wait for regrowth.
Missing saplings, blocked chests, lost workers or unavailable clear parking hold
completion. STOP and restart preserve the cycle. START resumes unfinished work;
START after COMPLETE begins a new cycle. Added workers wait for the next cycle.
Mode, species, area and existing membership cannot change mid-cycle.

`species <exact log IDs>` selects oak, spruce, birch, jungle, acacia, cherry or
mangrove logs, such as `species minecraft:oak_log minecraft:birch_log`.
`species none` selects no trees. `species false` restores legacy classification
and is the default. Explicit selections admit only those supported logs and
their mapped leaves. Other wood and leaves block felling and travel, including
chest trips. Dark oak remains excluded.

`burnLogs true` enables emergency log fuel while stopped without pending
commands. It defaults false; `burnLogs false` disables it. Only a valid fuel
chest inspection and confirmed empty pickup into an empty inventory slot at
the existing access can authorize burning carried overworld logs or wood.
Wrong items, broken chests, carried ordinary fuel, timeouts and missing facts
cannot substitute for empty-chest proof. Only the next lease can use the proof;
START, stop, pause, park, recovery, reload or a lane wait discards unused proof.

The saved refuel intent requests the minimum items needed for the existing
return reserve, within a conservative 20000-fuel bound and the worker's limit.
Reports or recovery must reconcile consumption and fuel gain before another
burn. Another stack needs a fresh empty pickup. After returning, the turtle
holds for ordinary fuel and keeps the empty-chest alert. START can recheck the
chest but cannot repeat burns for that empty service. Confirmed ordinary
refueling clears the hold. Burning changes no routes or production credits.

## Gate B tooling

From the checkout under test, run
`tools/gateb/gateb-retry.sh --slot A|B --full FULL_SHA --worlds 2`.
UI-B owns A; fix-round owns B. `GATEB_SLOT` also selects the slot; default is A.
Each slot owns at most two private worlds in the shared runtime home.
C3 and C13 wait for running checks and block new checks in both slots during
visual checks. Exit 75 means busy admission or ownership. The wrapper retries
every 60 seconds for up to 30 minutes and preserves real check results.
Use separate output or candidate-photo directories for each invocation.
Let an older keeper become idle before starting the two-slot driver.
See [the map](docs/SERVER-ONLY-MAP.md#gate-b-slots-and-photos) for photo ordering.
