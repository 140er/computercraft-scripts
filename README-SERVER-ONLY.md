# Server-only ComputerCraft

The `server-only` branch runs one server computer with at least 16 MB of disk.
It owns jobs, reservations, paired keys and saved state. Turtles execute batches
from the server. Displays show frames from the server and send input back.
The `main` branch has separate bots such as miner, hub and roomsorter.
This installer offers only server, worker and display roles.

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
Press P again for each additional client. Keep any leading zeros in the code.
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

## Drop points

The generic display has a drop-point editor. Use `kind` and `side` to cycle
values, the dimension and coordinate buttons to adjust the draft, and `add`
to save it. Existing points have `fix` and `remove` buttons. Use `prev` and
`next` to page through the list. All controls fit a 26x20 pocket or 29x12 monitor,
with the bottom row left for typed input.
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

The generic screen has `mining`, `lumber`, `shop`, `status` and `ar` buttons
above the drop editor. These links and each screen's `generic` return button
fit a 26x20 pocket or 29x12 monitor.

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

`home` sets the chest-side position. `bottom` sets the shaft bottom.
Branch length defaults to 64 blocks. `thorough` inspects walls, while `fast`
uses faster branches. `ores` selects the supported ore names.
`add` anchors a paired worker at its world position and facing.
Remove a worker only after its lease has closed. `stop` allows an already sent
batch to finish. The screen shows worker state, pose, fuel, ore count and errors.

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

`add` anchors one paired worker with an axe.
Work stays stopped until configured and started. `stop` parks after the current
lease reports. Dark oak is excluded. Empty sapling chests disable replanting
while felling continues. Configure a wood drop and a fuel drop.
The screen shows work state, deliveries, saplings, spots, fuel and alerts.

## Shop and the Storage Room turtle

The shop screen uses the Storage Room turtle from `main`. Install that turtle
with main's installer and select `roomsorter.lua`. Do not install the worker
role on that turtle. It uses the legacy plain-rednet storage protocols and
does not pair with this server.

The server discovers the Storage Room turtle and polls stock automatically.
Until discovery the shop screen says `Storage room not found, still looking`.
Type text to filter item names. Matching ignores case and treats spaces as
underscores. Item buttons order 1, 16 or 64 items. Replies appear as `Order:`
lines. Orders are not retried automatically and time out after two minutes.
The storage protocol commands are `stock` and `order`; they are not shop text
commands. See the [shop protocol](docs/server-only/PROTOCOL.md#shop).

Workers refuse drop and suck steps unless the target is an inventory. A missing
chest returns `no inventory` and keeps the items in the turtle. This also refuses
mining junk drops into open space; they need an inventory below the turtle.
