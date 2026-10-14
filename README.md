# computercraft-scripts

ComputerCraft (CC: Tweaked) turtle scripts.

- **Mine Army** (`hub.lua`, `miner.lua`, optional `relay.lua`): a hub with a dashboard in your base and a fleet of mining turtles. Each turtle goes down its own shaft to the ore level you pick, mines branch tunnels there and comes back to unload and refuel.
- **Sorter & Smelter** (`sorter.lua`): a turtle (or computer) on a wired network of chests and furnaces. It empties the miners' chests, smelts the raw ores in all your furnaces and blast furnaces, keeps them fuelled and sorts everything into storage. See [Sorter & Smelter](#sorter--smelter).
- **Storage Room** (`roomsorter.lua`): no modems or cables. A turtle in a closed room maps the room, builds its own chests and furnaces, sorts and smelts what you put in the input chest, remembers where everything is and brings you items in the output chest. See [Storage Room](#storage-room).
- `smartmine.lua`: the old standalone tunnel miner (no hub). Still works.

---

## Quick start

1. **Turtles:** a mining turtle (pickaxe) + wireless modem (normal or ender), a chest directly **behind** it, and a 1x1 hole **in front** of it going down. Put 2 lava buckets in the turtle or chest and a spare empty bucket in the chest.
2. **Hub:** an (advanced) computer within ~64 blocks of the turtles with a wireless modem. A monitor next to it is optional (advanced monitor = touch buttons), and a second monitor becomes an info screen.
3. **Copy the files:** drag `miner.lua` onto each turtle's screen and `hub.lua` onto the hub's screen. (Or, if the repo is public and `http` is enabled: `wget https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/install.lua install`, then `install`.)
4. **Set up each turtle once** (see below), then on the hub: `hub install`, `hub`.
5. On the dashboard: pick a time, pick an ore. Done.

### Setup: your 4 turtles
They stand at y=65, z=-743, chest on the north side (z=-744), so they face **south**. `setup` warns you if it doesn't see a chest behind the turtle.
```
miner setup -216 65 -743 south east    -- x=-216 (easternmost)
miner setup -218 65 -743 south south   -- x=-218
miner setup -220 65 -743 south north   -- x=-220
miner setup -222 65 -743 south west    -- x=-222 (westernmost)
```
General form: `miner setup <x> <y> <z> <facing> <role>`. Setup writes a `startup.lua` and gives the turtle a label (`Miner-east`, ...), so it restarts by itself and keeps its files when you pick it up.

---

## How a trip works

1. At home it unloads into the chest, cleans the chest, refuels and gets its job from the hub.
2. It moves 1 block forward into its hole and goes down. The shaft is finished to the ore level **once** and reused every trip after (iron is above diamond, so one shaft serves every level). The hole is covered with a block at floor level while the turtle is down there, and again after it comes home.
3. At the ore level it digs a **main tunnel** with **branch tunnels** off one side, all 1x1. It inspects the blocks above and below every tunnel block (no extra digging, and mobs can't spawn in 1-high tunnels).
4. Ore it sees is followed as a vein. For the target ore (e.g. diamond) it also checks the edge neighbours (18 of 26).
5. It comes home when: the inventory is full, it needs its remaining fuel to get back, the session time is up (it leaves early enough to be home when the clock hits 0), or the hub recalls it.

| Ore button | Level (Y) |
|---|---|
| Diamond / Redstone | -58 |
| Gold | -16 |
| Lapis | 0 |
| Iron | 16 |
| Copper / Coal | 48 |

### Regions (no collisions)
Each turtle's "role" is the direction of its main tunnel; its branches go a quarter turn clockwise. Every turtle gets its own quadrant and no tunnel crosses another turtle's shaft.

| Role | Main tunnel | Branches |
|---|---|---|
| east  | east  | south |
| south | south | west  |
| west  | west  | north |
| north | north | east  |

### Reach and layers
A turtle never goes more than **96 blocks** (6 chunks) from its shaft, ore veins included, so it stays in the chunks that are loaded while you are at your base.
- When a level is mined out within that reach, it starts a new layer 3 blocks higher with its branches shifted so they fall between the old ones (diamond: Y -58, -55, -52, -49).
- After 4 layers the dashboard shows "Area full": pick another ore or raise `reach` in `hub.state` (don't go above your server's simulation distance × 16 minus a margin).
- If it still runs into an unloaded chunk (you walked away), it keeps its progress, goes home and waits a minute.
- If the main tunnel hits something it can't get through (e.g. the reinforced deepslate of an ancient city, or lava that still won't seal after backing off 3 times) at the same spot on 2 trips, that layer counts as full and it moves on to the next layer. The reason shows on the dashboard's detail line and in `miner.log`.

### Mining modes: Thorough and Fast
Toggle with the button at the top right of the dashboard. A switch applies from the next branch on.

| | Thorough (default) | Fast |
|---|---|---|
| Branch spacing | every 4 blocks (3 blocks of rock between) | every 2 blocks (1 block between) |
| Looks at | above, below, ahead **and the left/right walls** | above, below and ahead only |
| Turning while digging | 4 turns per block | none |
| Cave openings in the walls | sealed | not seen, so not sealed |

Measured in a simulator over one full layer: Fast looks at about **18% more rock per minute** and covers more of the area, Thorough catches more of the odd single-block ores in the walls. Both take about the same time per layer.

### Caves, water and lava
- An opening into a cave (air or water) next to, above or below a tunnel is plugged with cobble. A branch that runs into a cave is closed off and the next one starts; the main tunnel goes straight through and walls itself in. Water in front of a tunnel is plugged and dug through.
- It never steps into lava. Lava sources are scooped with its empty bucket and burned as fuel (+1000), then the spot is sealed. Flowing lava is just sealed. Water is never scooped.
- Out of blocks to seal with? It digs one out of the rock next to it (the floor first). While walking its old tunnels it tops up to 8 blocks from the floor, because lava can flow into a tunnel between trips.
- Lava it can't seal (it keeps flowing in): it backs off 2 blocks through its own tunnel, waits a few seconds, comes back and tries again, up to 3 times, before giving up.

### Junk, loot and the chest
- **Kept:** all ores and what they drop (raw ores, diamond, emerald, lapis, redstone, quartz, gems, dusts, modded ores), fuel and buckets.
- **Junk:** everything else (cobble, deepslate, tuff, gravel, dirt, sandstone, terracotta, string, bones, ...). It is dropped underground every ~10 blocks, never in your base. One stack is kept for sealing, preferably cobbled deepslate or cobblestone.
- **Clean chest:** at every unload it removes anything from its chest that isn't ore, fuel or a bucket and drops it underground on the next trip.

### Fuel
- Fuel is an internal number in the turtle (type `refuel` on the turtle to see it, or look at the dashboard). 1 fuel = 1 block moved; turning and digging are free. Coal = 80, lava bucket = 1000, max 100,000 for an advanced turtle.
- It burns full lava buckets from its inventory and chest, and keeps the empty bucket to scoop lava underground. A turtle without a bucket takes one from its chest at home. Keep a spare empty bucket in each chest.
- It always keeps enough fuel to get home (distance + 72). At home it only tops up from the chest when it has less than ~2,000.

---

## Dashboard

```
 Mining Diamond (Y -58)         ALL ORES   THOROUGH

  Dia   Rstone   Gold   Lapis   Iron   Copper  Coal

  STOP   RECALL   UPDATE (2)

 Time  10m   20m   30m   45m   1h  0:42:10

 Turtle       Job      Status            Y   Fuel Free
 ...
 IN TURTLES NOW
 Diamond 7  Raw iron 14  Redstone 8 ...
```
- **Top line:** the current job. It shows "Orders for: <turtle>" while a turtle is selected, and a red `LOST:` alert or a short notice when there is one.
- **Ore buttons:** the whole fleet mines that ore. Tap a turtle in the list first to give only that turtle an order; `ALL` goes back to the whole fleet.
- **THOROUGH / FAST:** mining mode (see above).
- **ALL ORES / ONLY DIA:** with ALL ORES the turtles keep every ore they find. Switch it to ONLY and they mine just the chosen ore: other ores are not followed, and any they dig through are dropped underground like stone (coal is burned as fuel instead). Applies from the next trip; what's already in the chests stays.
- **Time:** session length, 10 minutes up to 1 hour (default 30 minutes). Picking an ore starts the countdown; pressing a time while mining restarts it. When it runs out the hub stops everything, like STOP. Each turtle gets the remaining time when it leaves home and keeps its own clock (saved as real time, survives reboots), so it comes home on time even when it can't hear the hub. It sets off early enough to be home when the clock runs out. While a session runs there is no per-trip time limit, so the turtles only come home early when they're full or need fuel. With less than 3 minutes left no new trip starts.
- **STOP:** stay home after the current trip. **RECALL:** come home now (if in range); **RESUME** lets them go again.
- **UPDATE:** see "Updating" below. The number is how many turtles run a different version than the `miner.lua` on the hub; those have a `*` after their name.
- **IN TURTLES NOW:** the loot currently in all turtles together (last reported for turtles out of range).
- Keyboard: `1`-`7` ore, `s` stop, `r` recall, `h` resume, `u` update, `a` all, `q` quit.
- Status colours: orange "Underground" = out on a trip and out of radio range (normal); red "NO SIGNAL" = should be home but isn't answering; red LOST/STUCK/ERROR = needs you.
- **Detail line** (under the turtle table): the full status and last error of the turtle you tapped, or otherwise the most recent error of any turtle in the last 30 minutes. "Going home: after error" means a trip hit an error; the detail line says which. Each turtle also keeps its last 40 errors in `miner.log` (read it on the turtle with `edit miner.log`).

### Info screen (second monitor)
Put a normal (grey) monitor next to the hub and reboot the hub. Normal monitors can't be tapped, so they always get the info screen; the biggest advanced monitor gets the dashboard. A 1x1 monitor gets a compact version:
```
MINE ARMY                         14:30
---------------------------------------
Mining Diamond (Y -58)
Time left                       0:18:00
4 turtles: 2 out, 2 home

THIS SESSION            12m, 425 ores/h
 Redstone                            40
 Diamond                             14

TURTLES                       Y    fuel
 east   going home          -40   24120
 south  home                 65    2200

ALL TIME
 Raw iron                           540
 Diamond                            212
```
- "This session" counts what the turtles delivered to their chests since you started the session, and the ores per hour. After the session ends it shows the last session.
- It uses a smaller text size on small monitors and leaves out the sections that don't fit.

### Radio range
A normal wireless modem reaches about 64 blocks, more the higher it is (up to ~384 near the build limit). A message gets through when it is within range of *either* modem.
- Without a relay, the hub only hears turtles near the base. That's fine: orders, updates and the session time are picked up at home.
- **Relay:** put a computer with a wireless modem high above your base (y 250+), copy `relay.lua` onto it, run `relay install`, then `relay`. It forwards all messages, so the hub sees the turtles everywhere.
- Ender modems work everywhere without a relay.

### Updating
1. Drag the new `miner.lua` onto the **hub's** screen (nothing happens yet).
2. Press **UPDATE**. Turtles at home update right away; turtles that can hear the hub go home first; the rest update when they get home.
- Updates only happen at home after unloading. Position, heading and progress are kept (`miner.state`, `miner.cfg`).
- A broken file is rejected. A turtle running a version older than hub updates needs one manual copy.
- To update the hub itself: drag `hub.lua` onto it and reboot it.
- Anyone on the server with a computer and modem could pretend to be the hub; on a server with strangers that is a risk.

---

## Sorter & Smelter

`sorter.lua` runs on a turtle or a computer. It doesn't move: everything goes through **wired modems**, so one sorter handles any number of chests and furnaces.

```
 [input chests] --> furnaces / blast furnaces --> [storage chests]
        \________________ everything else ______________/
             [fuel chest] --> furnaces        [pickup chest] <-- get
```

### Building it
1. Place the turtle/computer and put a **wired modem** (the full block, or the small one on a block) against it.
2. Put a wired modem on every chest and furnace you want to use and connect them all with **networking cable**.
3. **Right-click every modem** so it turns red (connected). The chat says e.g. `Peripheral "minecraft:chest_3" connected`.
4. Optional: a monitor on the network (or next to it) shows the status screen.

Smokers are ignored. Furnaces and blast furnaces are found by themselves; only the chests need a role.

### Chest roles (`sorter setup`)
Setup walks past every chest on the network and shows what's in it (put a marker item in a chest to recognise it), then asks for its role:

| Role | What it does |
|---|---|
| **input** | Emptied all the time. Put the miners' home chests here (wired modem on each) and the loot sorts itself. Anything you throw in gets sorted too. |
| **fuel** | Fuel for the furnaces: coal, charcoal, coal blocks, dried kelp blocks, lava buckets. Coal from the inputs ends up here first. |
| **storage** | Where everything goes. Give it a category to keep things apart: `any`, `ores`, `ingots`, `gems`, `fuel` or `misc`. |
| **overflow** | Used when the storage chests are full. |
| **pickup** | Where `get` puts the items you ask for. |
| **ignore** | Not touched. |

An item goes to: a chest of its category that already holds it → another chest of its category → an `any` chest that holds it → another `any` chest → overflow. If nothing has room, the screen shows **FULL** and the items stay in the input chests.

### Smelting
- **Smelted:** raw ores (`raw_iron`, `raw_gold`, `raw_copper`, modded `raw_*`), ore blocks (`*_ore`, from silk touch) and ancient debris. Raw ore *blocks* are stored as they are (they can't be smelted).
- Ores go to the furnace with the shortest queue, 8 at a time, at most 32 waiting per furnace. Blast furnaces (twice as fast) are filled first.
- If all furnaces are busy, the ores go to storage and are taken out again when a furnace has room. So raw ore never stays in storage.
- **Fuel:** each furnace gets just enough for what is waiting in it (coal = 8 items, 4 in a blast furnace). It doesn't put a coal block in for 5 ores unless there is nothing else. Empty buckets from lava come back out and get stored. With `useStorageFuel` it also burns coal from storage when the fuel chest is empty.
- XP: furnaces that are emptied by the sorter keep their XP. Break a furnace (or take out a result by hand) to get it.

### Mine Army chests as input
- The miners need their **buckets and lava buckets**, so those are always left in the input chests. Everything else is taken, also coal (the miners also refuel with lava they scoop up).
- Want a stack of coal to stay for the miners? Add `["minecraft:coal"] = 64` to `leave` in `sorter.cfg`.

### Status screen
```
SORTER & SMELTER                   12:00
---------------------------------------
Furnaces 3, busy 3           to smelt 30
Fuel chest: 40 items
Storage 7/54 slots                   12%
Smelted 8 Iron ingot

SMELTED                         77 in 3m
 Iron ingot                           72
 Gold ingot                            3

FURNACES
 blast_0 32 Raw copper        8 charcoal
 furnace_0 32 Raw iron            2 coal
```
- Red **NO FUEL!**: a furnace has ores but no fuel and the fuel chest is empty.
- Orange **new chest(s)**: a chest was added to the network: run `sorter setup` to give it a role (until then it's left alone).

### Commands
Type at the `>` line at the bottom of the turtle's screen:

| Command | What |
|---|---|
| `get iron ingot 32` | put 32 iron ingots in the pickup chest (default 64) |
| `find diamond` | how many are in storage |
| `pause` / `resume` | stop / start moving items |
| `quit` | stop the program |

| Where | Command | What |
|---|---|---|
| sorter | `sorter setup` | give the chests a role (run again after adding chests) |
| sorter | `sorter list` | show all chests and furnaces with their role |
| sorter | `sorter install`, `sorter` | autostart, run |

### Settings (`sorter.cfg`)
- `interval` (3): seconds between rounds when there is nothing to do.
- `queue` (32): max items waiting in one furnace.
- `extraSmelt`: more things to smelt in normal furnaces, e.g. `{ "minecraft:oak_log", "minecraft:sand", "minecraft:cobblestone" }` for charcoal, glass and stone.
- `noSmelt`: ores to store raw, e.g. `{ "minecraft:raw_copper" }`.
- `leave`: what stays in the input chests and how many.
- `fuels`: fuel order, most preferred first.
- `useStorageFuel` (true): also burn coal from storage.
- Smelted totals are in `sorter.stats`, errors in `sorter.log`.

---

## Storage Room

`roomsorter.lua`: the no-cables version. One turtle in a closed room does it all: it maps the room, places the chests and furnaces you give it, sorts and smelts, and **remembers which chest holds what**. It also checks each chest's contents every time it visits it, so its memory stays right.

### What you need
- A **closed room** with a flat floor and ceiling (any size and floor shape) with an **input chest** and an **output chest** built into the walls, so you can reach them from outside. At least 3 blocks high if you want furnaces.
- A plain turtle (no tool needed). A wireless modem on it is optional (for asking from outside, see below).
- Some coal in the turtle for the first scan.

### Setup
1. Put the turtle **on the floor, facing the input chest**, with some coal in it.
2. `roomsorter scan 4` (4 = how many blocks high the inside of the room is). The turtle drives over the floor once and looks at the walls; the walls are taken to go straight up to the ceiling (a 16x16 room takes ~5 minutes). If the room has a hole at floor height, it says so and comes back.
   - Leave the number out (`roomsorter scan`) and it flies up once from its start spot to measure the height.
   - Best: both chests at floor height. If the output chest is higher up the wall, it also checks the walls above the floor (takes a bit longer).
   - More than one other chest in the walls? Put 1 item in the output chest (only there) and scan again.
3. `roomsorter install`, then `roomsorter`.
4. Put **chests or barrels**, **furnaces / blast furnaces** and **coal** in the input chest. The turtle builds with them.

### How it builds
Seen from above (input chest `I` at the top, turtle `T` on its start spot):
```
 ####I####       floor                upper layer (above the road)
 #...T...#   <- row 0: stays free     #.......#
 #.BFFFB.#   <- row 1: furnaces       #.CCCCC.#  <- their helper chests
 #CCCCCCC#   <- row 2: storage        #CCCCCCC#
 #CCCCCCC#   <- row 3                 #CCCCCCC#
 #CCCC...#   <- fills left to right   #CCC....#
```
- The layer 1 block above the floor stays free as the turtle's road. Chests go on the floor and in the layer above the road (in tall rooms this repeats every 3 blocks up).
- **Furnace row:** the row right in front of the start spot, centred on the turtle, a helper chest straight above each furnace. The turtle drops ores in from above and moves fuel and results through the helper chest. Up to 16 furnaces (`maxFurnaces`), or as many as fit in the row.
- **Storage:** the rows behind it, one row at a time, left to right. Spots outside this pattern (the upper layer over the way in, the ends of the furnace row) are only used when the rest is full.
- **Everything you give it is built right away:** every furnace (with a chest for its helper) and every chest or barrel. Spares are stored and built as soon as there is a spot.
- Chests in one row all face the same way and the next row the other way, so they never join into double chests. Barrels work too.
- It never blocks a spot it needs to get somewhere, and it keeps the blocks next to its start spot and the wall chests free.

### Sorting and smelting
- Each kind of item gets its own chest: first a chest that already has it, then an empty chest, then a new chest it places, and only when all of that is full, any free slot.
- Raw ores, ore blocks and ancient debris are smelted (blast furnaces first), the valuable ones first: ancient debris, gold, iron, other (modded) ores, copper last.
- **Food is cooked** too: raw beef, porkchop, chicken, mutton, rabbit, cod, salmon, potatoes and kelp. Give it **smokers** (like furnaces) and food goes there first (twice as fast); normal furnaces cook it too, blast furnaces never get food and smokers never get ore. `cook = false` in `room.cfg` turns it off. Fuel: charcoal, coal, coal blocks, dried kelp blocks, from storage. The turtle also refuels itself from them.
- Out of room and out of chests: the screen shows **FULL**, and new items stay in the input chest.

### Getting items out
Type on the turtle (walk into the room and right-click it), or ask from outside with a computer (below):

| Command | What |
|---|---|
| `get iron ingot 32` | brings 32 iron ingots to the output chest (default: 1 stack) |
| `find diamond` | how many there are |
| `list` | everything in storage |
| `build` | shows how many chests/furnaces are built and how much room is left, and builds any that aren't yet (it normally does that by itself) |
| `pause` / `resume` / `quit` | on the turtle only |

**Order screen (buttons):** on an advanced (gold) computer `roomsorter client` shows tiles with little icons instead of a prompt. Ordering and crafting are one screen:
- the home screen has **Frequent** (what you order most), a tile per category (Fuel, Ores, Ingots, Gems, Wood, Blocks, Food, Mob drops, Tools, Other) and **All items**,
- a category shows what's in storage (yellow count) **and what the turtle can craft** (purple `+N`, even when there's none in storage). The craftable count includes parts it can make first (logs -> planks -> sticks -> torches),
- click an item and pick an amount: green buttons come from storage, purple ones need crafting. **Not enough in storage? It takes what's there and crafts the rest**, all to the pickup chest. "All stored", "Max" and "Other amount..." too,
- "Type it myself" / "Not listed? Type it" works the same way (`iron ingot 32`),
- the blue bar shows **Status:** what the turtle is busy with, updated every 5 seconds,
- Backspace = back. `roomsorter client text` gives the old typing prompt (`order torch 32` there does the same).

**Order screen on a monitor:** put an **advanced monitor** (e.g. 2x2) next to the request computer. `roomsorter client` then shows the order screen on the monitor (tap it) and the computer's own screen becomes a command prompt (right-click the computer and type `get iron ingot 32`, `order torch 16`, `craft chest 2`, `find coal`, `list`, `recipes`, `status`, `build`, `pause`, `learn`, `resume`, `blocked`, `unblock`). On the monitor any amount is picked with -16 / -1 / +1 / +16 and Order.

**Orders first:** an order is handled before anything else. The turtle checks for orders between every step of what it's doing (taking from the drop-off chest, building each chest, each furnace, storing), so it doesn't finish a long job first.

**From outside:** give the turtle a wireless modem (craft them together), and on any computer or pocket computer with a wireless modem run `roomsorter client`. Same commands. (`roomsorter install client` starts it on boot.)

**No wireless modem for the request computer?** Connect it to the board computer with a cable: a wired modem on each of the two computers, networking cable between them, right-click both modems so they turn red. The board computer (which has a wireless modem) then passes your requests on to the turtle and the answers back; it does that by itself when it sees the wired modem (its own screen says "Passing requests from the cable on to the turtle"). Run `roomsorter client` on the request computer as usual; it says "Connected through the board computer".

### Stock board (monitor outside the room)
A stock-exchange style screen of what's in storage, on a computer with a **wireless modem** and a **monitor** next to it. The turtle needs a wireless modem too.

1. Copy `roomsorter.lua` onto the computer.
2. `roomsorter install board`, then reboot (or run `roomsorter board`).

```
 ROOM EXCHANGE                                                     LIVE  14:32
 3,790 items  51 kinds  7 chests 19% full  3 furnaces  Smelting
ITEM                                             QTY   CHG 1H       %   LAST IN
 ♦ TOP: valuable & most ordered
Netherite scrap                                    2      ▲+2      new    1m ago
Cobblestone                                      128        =     0.0%        -
Diamond                                           33     ▲+20  +153.8%    1m ago
 RECENTLY ADDED
Iron ingot                                       668    ▲+480  +255.3%       now
 IRON INGOT 668 ▲+480  • DIAMOND 33 ▲+20  • COBBLESTONE 128 =  • ...
```
- **TOP** (always on top): the valuable items (netherite, diamonds, emeralds, gold, iron, ...) and the items you order most, taking turns.
- Below that, every 10 seconds it switches between **RECENTLY ADDED** (what came in last) and **MOST IN STOCK**.
- **QTY** how many are in storage, **CHG 1H** and **%** how much that changed in the last hour, **LAST IN** when that item last came in ("now", "5m ago").
- A number that just changed lights up for a few seconds. The bottom line is a scrolling ticker tape of everything.
- Any size of monitor works; wide monitors get two columns. A **normal (grey) monitor** shows it in greyscale with ▲/▼; an **advanced (gold) monitor** shows rises in green and drops in red.
- The turtle sends its stock every 10 seconds and right after something changes. `LIVE` turns into a blinking `NO SIGNAL` after a minute without news. History is kept in `board.hist`, so a reboot keeps the trends.

### Crafting
Give the turtle a **crafting table**: put one in the drop-off chest and it equips it on its free side (next to the wireless modem). Then it can craft:
- On the **order screen** craftable items simply show up in their category with a purple `+N`; ordering more than there is in storage crafts the rest.
- Or type `craft torch 32` (turtle prompt or `roomsorter client text`), `recipes` lists them.
- **Parts first:** missing sticks, planks (from any log) etc. are crafted first, e.g. torches straight from logs + coal.
- **Built in:** sticks, torches, planks, crafting tables, chests, furnaces, ladders, buckets, shears, hoppers, rails, compass, flint and steel, arrows, bread, paper, books, stone bricks, glass panes, iron/diamond tools, storage blocks (9 ingots -> block) and back, nuggets -> ingots.
- **Teach it anything else** (also modded recipes): on the turtle (or the request computer) type `pause`, wait until it says Paused (its inventory is empty then), put **one** set of the recipe in its 3x3 grid (the left 3 columns of the top 3 rows), type `learn`, then `resume`. Learned recipes are in `room.recipes`.
- How it crafts: it empties itself, takes the ingredients straight into the grid slots, crafts as much as fits in its inventory at once and repeats.

### Things in the way (cables, ...)
- Something in the turtle's way (a cable through the room, a block, or it simply can't move there 5 times in a row) is saved in its map **for good**, and it goes around it.
- Chests it can't reach anymore are left out (their items don't show in `list` either); the screen says how many and where it's blocked. It never places a chest that would cut it off from a spot it can reach now.
- `blocked` lists the blocked spots (and what is there) and the chests that are cut off with what's in them. Spots are counted from the turtle's start: x = blocks to the right, y = up (0 = floor), z = rows back from the drop-off wall.
- `unblock` forgets all blocked spots (`unblock x,y,z` just one), e.g. when it marked a spot because you stood in its way. If something is really there, it notices again.
- Best: run cables outside the room or under the floor. A cable through the road layer can cut off part of the room once the rows next to it are full.

### Moving the pickup chest
Moved the pickup chest a bit (up to 2 blocks up/down, 1 sideways)? Just order something: when the chest isn't where it was, the turtle looks around the old spot, finds it and uses the new spot from then on. Or type `pickup` (turtle or request computer) to make it look right away. Fill the old spot in the wall, the room must stay closed.

### Restarts
- Position and heading are saved before every move and turn. After a restart it looks around, compares that with its map and carries on.
- Picked it up? Put it back on its start spot facing the input chest and type `roomsorter home`, then `roomsorter`.
- Changed the room (moved a wall)? `roomsorter scan force` maps it again, but it forgets what is where, so empty the chests it built first.

### Settings (`room.cfg`)
`maxFurnaces` (16), `queue` (32 items per furnace), `interval` (5 s between looks in the input chest), `minFuel` (1000), `extraSmelt` (e.g. `{ "minecraft:oak_log" }` for charcoal), `noSmelt`, `fuels`, `maxSize` / `maxHeight` / `maxCells` (how big a room may be). The map is in `room.map`, what is where in `room.idx`, errors in `room.log`.

---

## Safety and recovery

- **Reboots / chunk unloads:** position, heading and progress are saved on every move and turn. After a restart away from home the turtle goes home along its own tunnels first, then carries on.
- **Heading checks:** at boot it looks for its chest; at the bottom of its shaft it checks which side the main tunnel opening is on and corrects its heading if needed.
- **No blind digging:** on its own routes it never digs through natural rock. Rock where its tunnel should be means it is lost.
- **Lost:** it goes straight up to the surface, digging only natural ground (stone, dirt, sand, gravel, ores, leaves; never cobble, planks, logs or other possible builds, it steps around those). In the open air it builds an 8-block pillar of its blocks and waits on top, also after reboots. The dashboard shows a red `LOST: <name> at x,y,z` (x/z can be a few blocks off if it had to step around something).
- **No chest at home:** it never unloads without a chest behind it. It first turns around looking for it; if it still can't find it, the dashboard shows "ERROR: no chest behind me".
- **Putting a turtle back:** pick it up (it keeps its files), put it on its home spot next to its chest in any direction, and type `miner`. It finds its chest and resets its position and heading; progress is kept. If needed: Ctrl+T, `miner home`, `miner`.

---

## Commands

| Where | Command | What |
|---|---|---|
| turtle | `miner setup <x> <y> <z> <facing> <role>` | one-time setup |
| turtle | `miner` | run with the hub (started automatically on boot) |
| turtle | `miner diamond` / `miner diamond fast` / `miner diamond only` | run without a hub |
| turtle | `miner home` | reset position to the home spot after putting it back by hand |
| hub | `hub install`, `hub` | autostart, run |
| relay | `relay install`, `relay` | autostart, run |

## Settings
- `hub.state` (on the hub): `reach` (96), `branchLen` (64), `mineMinutes` (15), `sessionLen`, `mode`.
- Top of `miner.lua`: `BRANCH_LEN`, `BRANCH_GAP`, `FAST_GAP`, `REACH`, `LAYER_STEP`, `MAX_LAYERS`, `JUNK_EVERY`, `MAX_VEIN`, `FUEL_MARGIN`.

## Good to know
- Turtles only work in loaded chunks. When a chunk unloads the turtle pauses; when it loads again it restarts, goes home and carries on.
- `smartmine.lua` is the older standalone miner: `smartmine <length> [tunnels] [gap] [block1,block2,...]`.
