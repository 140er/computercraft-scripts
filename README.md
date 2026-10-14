# computercraft-scripts

Turtle and computer scripts for [CC: Tweaked](https://tweaked.cc/) (ComputerCraft) in Minecraft: a mining fleet, two storage systems, a tree farm, a crop farm, a lava fuel runner, a builder that also bores tunnels, a factory that builds more turtles, a turtle you can chat with, and a pocket computer with a map that controls them all.

| Bot | File | Runs on | What it does |
|---|---|---|---|
| [Mine Army](#mine-army) | `hub.lua`, `miner.lua`, optional `relay.lua` | computer + mining turtles | A hub with a dashboard in your base and a fleet of mining turtles. Each goes down its own shaft to the ore level you pick, mines branch tunnels and comes back to unload and refuel. |
| [Storage Room](#storage-room) | `roomsorter.lua` | turtle | No modems or cables. A turtle in a closed room maps it, builds its own chests and furnaces, sorts and smelts what you put in, remembers where everything is and brings you items. |
| [Sorter & Smelter](#sorter--smelter) | `sorter.lua` | turtle or computer | On a wired network of chests and furnaces: empties the miners' chests, smelts the raw ores, keeps the furnaces fuelled and sorts everything into storage. |
| [Lumberjack](#tree-farm-lumberlua) | `lumber.lua` | felling turtle | Finds trees around its chest by itself, fells and replants them, and puts the logs in the chest. |
| [Buddy](#buddy-companion-turtle) | `buddy.lua` | turtle | A companion you chat with, powered by your own model server (or xAI's Grok). Does small jobs around your base. |
| [Farmer](#farmer-farmerlua) | `farmer.lua` | farming turtle (hoe) | Flies over a field, harvests what's ripe (wheat, carrots, potatoes, beetroot, nether wart, melons, pumpkins, sugar cane, bamboo), replants and tills. |
| [Fuel runner](#fuel-runner-fuellua) | `fuel.lua` | turtle | Fills buckets at a dripstone lava farm or a lava lake and keeps the other bots' fuel chests stocked with lava. |
| [Builder](#builder-builderlua) | `builder.lua` | mining turtle | Clears and flattens land, lays floors, builds walls, and bores lit tunnels that bridge gaps and seal lava. |
| [Turtle factory](#turtle-factory-factorylua) | `factory.lua` | crafty turtle | Crafts new turtles from parts the storage room makes, and sends each one off to its spot already set up as a miner, farmer, builder, ... |
| [GPS hosts](#gps-and-the-map) | `gpshost.lua` | 4 computers | GPS for the map on the pocket panel and for setup without typing coordinates. |
| [Pocket panel](#pocket-panel) | `panel.lua` | advanced pocket computer | One app to control everything above from anywhere, with a live **map** and an **Update all** button. |
| | `smartmine.lua` | mining turtle | The old standalone tunnel miner (no hub). Still works. |

---

## Installing

You need **http enabled** in the ComputerCraft config (it is by default). On the computer or turtle, run:
```
wget https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/install.lua install
install <bot>
```
where `<bot>` is one of `miner`, `hub`, `relay`, `roomsorter`, `sorter`, `lumber`, `buddy`, `farmer`, `fuel`, `builder`, `factory`, `gpshost`, `panel`, `smartmine`. It downloads that script plus `update.lua` and tells you the next step. Each bot's section below has its setup.

No http? Drag the `.lua` file from this repo onto the computer's screen instead.

## Updating

- **One bot:** type `<bot> update` (for example `lumber update`), or just `update`. It fetches the latest version of every script from this repo that is on that computer, checks that it loads, and reboots if anything changed.
- **Everything at once:** press **Update all** on the [pocket panel](#pocket-panel). Every bot it can reach updates itself at a safe moment: the lumberjack when it's home, Buddy after its current job, the storage room after putting everything away. The hub fetches the new `hub.lua` and `miner.lua` and hands it to the mining turtles, which update when they get home. Then the panel updates itself.
- Bots without a modem (`sorter`, `relay`, `smartmine`) only update with their own `update` command.
- A bot that can't reach GitHub keeps running its current version.

---

## Mine Army

### Quick start

1. **Turtles:** a mining turtle (pickaxe) + wireless modem (normal or ender), a chest directly **behind** it, and a 1x1 hole **in front** of it going down. Put 2 lava buckets in the turtle or chest and a spare empty bucket in the chest.
2. **Hub:** an (advanced) computer within ~64 blocks of the turtles with a wireless modem. A monitor next to it is optional (advanced monitor = touch buttons), and a second monitor becomes an info screen.
3. **Install:** `install miner` on each turtle and `install hub` on the hub (see [Installing](#installing)).
4. **Set up each turtle once** (see below), then on the hub: `hub install`, `hub`.
5. On the dashboard: pick a time, pick an ore. Done.

### Setup: the turtles
Example: 4 turtles in a row at y=64, z=-350, each with its chest on the north side, so they face **south**. Give each a different role (the direction of its main tunnel). `setup` warns you if it doesn't see a chest behind the turtle.
```
miner setup 120 64 -350 south east    -- easternmost
miner setup 118 64 -350 south south
miner setup 116 64 -350 south north
miner setup 114 64 -350 south west    -- westernmost
```
General form: `miner setup <x> <y> <z> <facing> <role>`, with the turtle's own coordinates (F3). Setup writes a `startup.lua` and gives the turtle a label (`Miner-east`, ...), so it restarts by itself and keeps its files when you pick it up.

---

### How a trip works

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

### Dashboard

```
 Mining Diamond (Y -58)         ALL ORES   THOROUGH

  Dia   Rstone   Gold   Lapis   Iron   Copper  Coal

  STOP   RECALL   UPDATE (2)              CUSTOM

 Time  10m   20m   30m   45m   1h  0:42:10

 Turtle       Job      Status            Y   Fuel Free
 ...
 IN TURTLES NOW
 Diamond 7  Raw iron 14  Redstone 8 ...
```
- **Top line:** the current job. It shows "Orders for: <turtle>" while a turtle is selected, and a red `LOST:` alert or a short notice when there is one.
- **Ore buttons:** the whole fleet mines that ore. Tap a turtle in the list first to give only that turtle an order; `ALL` goes back to the whole fleet.
- **THOROUGH / FAST:** mining mode (see above).
- **CUSTOM** (or the `c` key on the hub computer): type any item on the **hub computer** (monitors have no keyboard), then the height (Enter = a sensible default).
  - Rock (`cobbled deepslate`, `cobblestone`, `tuff`, `granite`, `diorite`, `andesite`, `calcite`, `gravel`, `dirt`): the turtles keep that item instead of dropping it, plus the ores they find. Their inventories fill fast (about 900 blocks per trip), so give them big chests.
  - Anything else is taken as an ore name, also modded: `emerald`, `zinc`, `raw tin`, `osmium`. They mine every ore block with that word in its name and keep every item with it (raw zinc, ...). Check the name with F3 if nothing turns up.
  - Custom items are never cleaned out of the chest later. Tap an ore button to go back to normal ores.
- **ALL ORES / ONLY DIA:** with ALL ORES the turtles keep every ore they find. Switch it to ONLY and they mine just the chosen ore: other ores are not followed, and any they dig through are dropped underground like stone (coal is burned as fuel instead). Applies from the next trip; what's already in the chests stays.
- **Time:** session length, 10 minutes up to 1 hour (default 30 minutes). Picking an ore starts the countdown; pressing a time while mining restarts it. When it runs out the hub stops everything, like STOP. Each turtle gets the remaining time when it leaves home and keeps its own clock (saved as real time, survives reboots), so it comes home on time even when it can't hear the hub. It sets off early enough to be home when the clock runs out. While a session runs there is no per-trip time limit, so the turtles only come home early when they're full or need fuel. With less than 3 minutes left no new trip starts.
- **STOP:** stay home after the current trip. **RECALL:** come home now (if in range); **RESUME** lets them go again.
- **UPDATE:** see "Updating" below. The number is how many turtles run a different version than the `miner.lua` on the hub; those have a `*` after their name.
- **IN TURTLES NOW:** the loot currently in all turtles together (last reported for turtles out of range).
- Keyboard: `1`-`7` ore, `c` custom item, `s` stop, `r` recall, `h` resume, `u` update, `a` all, `q` quit.
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

### Updating the fleet
1. On the hub: `hub update` (or **Update all** on the pocket panel). It fetches the latest `hub.lua` and `miner.lua` from GitHub, reboots and releases the new `miner.lua`. Or, for a version of your own: drag `miner.lua` onto the **hub's** screen and press **UPDATE**.
2. Turtles at home update right away; turtles that can hear the hub go home first; the rest update when they get home. (`miner update` on a turtle just points you to the hub, so all turtles run the same version.)
- Updates only happen at home after unloading. Position, heading and progress are kept (`miner.state`, `miner.cfg`).
- A broken file is rejected. A turtle running a version older than hub updates needs one manual copy.
- Anyone on the server with a computer and modem could pretend to be the hub; on a server with strangers that is a risk.

### Safety and recovery

- **Reboots / chunk unloads:** position, heading and progress are saved on every move and turn. After a restart away from home the turtle goes home along its own tunnels first, then carries on.
- **Heading checks:** at boot it looks for its chest; at the bottom of its shaft it checks which side the main tunnel opening is on and corrects its heading if needed. After a reboot in the middle of a turn, and before it gives up as lost, it looks at the tunnel around it (open behind, rock on the walls) and fixes a heading that is a quarter turn off.
- **Recall:** a recalled turtle drops whatever it is doing, also in the middle of an ore vein (it leaves the rest of the vein), and comes straight home.
- **No blind digging:** on its own routes it never digs through natural rock. Rock where its tunnel should be means it is lost.
- **Lost:** it goes straight up to the surface, digging only natural ground (stone, dirt, sand, gravel, ores, leaves; never cobble, planks, logs or other possible builds, it steps around those). In the open air it builds an 8-block pillar of its blocks and waits on top, also after reboots. The dashboard shows a red `LOST: <name> at x,y,z` (x/z can be a few blocks off if it had to step around something). Why it got lost is in `miner.log` on the turtle and on the hub.
- **No chest at home:** it never unloads without a chest behind it. It first turns around looking for it; if it still can't find it, the dashboard shows "ERROR: no chest behind me".
- **Putting a turtle back:** pick it up (it keeps its files), put it on its home spot next to its chest in any direction, and type `miner`. It finds its chest and resets its position and heading; progress is kept. If needed: Ctrl+T, `miner home`, `miner`.


### Commands

| Where | Command | What |
|---|---|---|
| turtle | `miner setup <x> <y> <z> <facing> <role>` | one-time setup |
| turtle | `miner` | run with the hub (started automatically on boot) |
| turtle | `miner diamond` / `miner diamond fast` / `miner diamond only` | run without a hub |
| turtle | `miner home` | reset position to the home spot after putting it back by hand |
| hub | `hub install`, `hub` | autostart, run |
| relay | `relay install`, `relay` | autostart, run |
| tree turtle | `lumber setup [radius]`, `lumber` | one-time setup, run |
| tree turtle | `lumber home` / `lumber reset` | reset position after putting it back by hand / forget all trees |
| hub | `hub update` | fetch the latest hub.lua and miner.lua and release it to the turtles |
| anywhere | `update` or `<bot> update` | fetch the latest version of this computer's scripts, see [Updating](#updating) |

### Settings
- `hub.state` (on the hub): `reach` (96), `branchLen` (64), `mineMinutes` (15), `sessionLen`, `mode`.
- Top of `miner.lua`: `BRANCH_LEN`, `BRANCH_GAP`, `FAST_GAP`, `REACH`, `LAYER_STEP`, `MAX_LAYERS`, `JUNK_EVERY`, `MAX_VEIN`, `FUEL_MARGIN`.

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
- **Built in:** sticks, torches, planks, crafting tables, chests, furnaces, ladders, buckets, shears, hoppers, rails, compass, flint and steel, arrows, bread, paper, books, stone bricks, glass panes, iron/diamond tools (hoes too), storage blocks (9 ingots -> block) and back, nuggets -> ingots, and the ComputerCraft parts for the [turtle factory](#turtle-factory-factorylua): computers, turtles and wireless modems (an ender pearl each).
- **Teach it anything else** (also modded recipes): on the turtle (or the request computer) type `pause`, wait until it says Paused (its inventory is empty then), put **one** set of the recipe in its 3x3 grid (the left 3 columns of the top 3 rows), type `learn`, then `resume`. Learned recipes are in `room.recipes`.
- How it crafts: it empties itself, takes the ingredients straight into the grid slots, crafts as much as fits in its inventory at once and repeats.

### Things in the way (cables, ...)
- Something in the turtle's way (a cable through the room, a block, or it simply can't move there 5 times in a row) is saved in its map **for good**, and it goes around it.
- Chests it can't reach anymore are left out (their items don't show in `list` either); the screen says how many and where it's blocked. It never places a chest that would cut it off from a spot it can reach now.
- `blocked` lists the blocked spots (and what is there) and the chests that are cut off with what's in them. Spots are counted from the turtle's start: x = blocks to the right, y = up (0 = floor), z = rows back from the drop-off wall.
- `unblock` forgets all blocked spots (`unblock x,y,z` just one), e.g. when it marked a spot because you stood in its way. If something is really there, it notices again.
- `resync` counts everything again: it looks at every blocked spot once more (free again? then it's cleared), opens cut-off chests from another side where it can, reads every chest it can reach and forgets chests that were broken by hand. Use it when the numbers look wrong. The order screen says when chests are cut off (their items are missing from the lists).
- Best: run cables outside the room or under the floor. A cable through the road layer can cut off part of the room once the rows next to it are full.

### Moving the pickup chest
Moved the pickup chest a bit (up to 3 blocks down, 2 up, 2 sideways, also down into a hole)? Just order something: when the chest isn't where it was, the turtle feels around the old spot (open spots like a hole or the old chest spot become part of its map, so it can go in there), finds the chest and uses the new spot from then on. Or type `pickup` (turtle or request computer) to make it look right away. You may leave the old spot open (e.g. chest moved 1 down, turtle reaches it from the old spot); just make sure the room stays closed to the outside.

### Restarts
- Position and heading are saved before every move and turn. After a restart it looks around, compares that with its map and carries on.
- Picked it up? Put it back on its start spot facing the input chest and type `roomsorter home`, then `roomsorter`.
- Changed the room (moved a wall)? `roomsorter scan force` maps it again, but it forgets what is where, so empty the chests it built first.

### Settings (`room.cfg`)
`maxFurnaces` (16), `queue` (32 items per furnace), `interval` (5 s between looks in the input chest), `minFuel` (1000), `extraSmelt` (e.g. `{ "minecraft:oak_log" }` for charcoal), `noSmelt`, `fuels`, `maxSize` / `maxHeight` / `maxCells` (how big a room may be). The map is in `room.map`, what is where in `room.idx`, errors in `room.log`.

---

## Tree farm (lumber.lua)

A felling turtle (turtle + axe, no modem needed) that finds trees around its home by itself, fells them, replants them and keeps farming them.

1. Put the turtle somewhere in the open next to a chest (behind it is best; it turns to find the chest if it is on another side). Logs go in there, and you put its fuel, **lava buckets**, in the same chest. A second chest directly **under** the turtle also works for lava, but is optional. Keep the space above the turtle open: it flies out and back through there.
2. `install lumber` on the turtle (see [Installing](#installing)), or drag `lumber.lua` onto its screen.
3. `lumber setup [radius]`: how far from the chest it may go (default 48 blocks, so it stays in the chunks around you).
4. A few saplings in the turtle or the chest help it get going (optional).
5. `lumber` (starts by itself on boot after setup).

```
 LUMBERJACK                    RUNNING
 Felling a tree at 12,-3,4
 Fuel ██████████████████░░░░░   4180
 Lava 12 buckets in my chest
 Felled  68         Logs     309
 Farm    64/64      Saplings 29
 Search  11%        Area     48 blocks
 ! 14:02 Gave up on the tree spot at 4,-14
 [P] pause  [H] come home  [Q] quit
```
- **P**: pause. Out on a trip it finishes the tree it is on, flies home, unloads and waits. P again: carry on.
- **H**: come home now (unload, refuel), then carry on.
- **Q**: quit (press Q twice). `lumber` starts it again; it remembers everything.
- The fuel bar turns orange below 2000 and red when it's nearly out. The red `!` line is the last problem it ran into (all of them are in `lumber.log`).

**What it does:**
- **Search:** it walks over the ground in a square spiral around the chest, in lines 3 blocks apart, and looks left and right for tree trunks. It climbs over hills, steps down into dips and floats over water. Where it can't walk, it flies. Each trip searches a part of the spiral and remembers where it stopped.
- **Fell:** the whole trunk. While it has fewer than 24 saplings it also flies once around the trunk every other level and cuts the whole crown of leaves: that gives a few saplings per tree. Then it plants a sapling of the same kind on the spot.
- **Plant spares:** saplings it doesn't need for replanting (it keeps 6) are planted in a grid, 3 blocks apart, within 15 blocks of the chest, nearest first. Each one is remembered like any other tree, so the farm grows close to home where it is cheap to visit. Grid places where nothing can grow (stone, sand, water, a build) are remembered and skipped.
- **Farm:** every sapling it planted is remembered. About 20 minutes later it flies back over the trees, comes down through the leaves and fells it if it has grown (or uses bone meal on it if it has some, and looks again later).
- **Home:** it puts the logs, sticks, apples, extra saplings and empty buckets in the chest behind it. Below 4000 fuel it takes lava buckets from its chest (and from a chest under it, if there is one) until it has about 5000 (one bucket = 1000). Out of saplings, it takes them from the chest behind it.
- Once the whole area is searched or it farms 64 trees, it only farms.

**Good to know:**
- 1x1 trees: oak, birch, spruce, jungle, acacia, cherry. Dark oak is left standing. Of a 2x2 giant spruce/jungle it only cuts one column.
- It never digs ground or stone, only logs, leaves and small plants (grass, flowers, vines). It can't tell a log house from a tree, so keep wooden builds out of its radius.
- Saplings: cutting the crown gives a few saplings per tree, more than it needs. The rest go in the chest (it keeps up to 64 of each kind).
- Fuel: it **never burns its own wood**. Only lava buckets (or coal, charcoal, coal blocks) from its chest. Walking, climbing and flying cost 1 per block, going around a crown about 20; a busy hour in a forest uses about 3 to 4 lava buckets. Empty buckets go back in the chest, so you can refill them. With no fuel left it waits at home ("Out of fuel") until you add some.
- Reboots / chunk unloads: position and heading are saved on every move and turn. After a restart it finishes the tree it was cutting and flies home. Errors are kept in `lumber.log`.
- `lumber home`: you put it back on its spot by hand. `lumber reset`: forget all trees and search the area again.
- Settings at the top of `lumber.lua`: `RADIUS`, `MAX_SPOTS`, `NURSERY_RADIUS`, `SAPLING_RESERVE`, `SAPLING_WANT`, `LEAF_RINGS`, `REGROW_MIN`, `EXPLORE_CELLS`, `HOP`, `WAIT`, `KEEP_SAPLINGS`, `BONEMEAL_TRIES`.

## Good to know
- Turtles only work in loaded chunks. When a chunk unloads the turtle pauses; when it loads again it restarts, goes home and carries on.
- `smartmine.lua` is the older standalone miner: `smartmine <length> [tunnels] [gap] [block1,block2,...]`.

---

## Buddy (companion turtle)

A turtle you talk to. A language model reads what you say and decides what to do with the turtle's tools: move, turn, look around, pick up or drop items, place or break a block, refuel, craft (crafty turtle), and walk back home. It is a companion, not a worker: it turns down big jobs like mining and leaves those to the Mine Army.

**The brain** is any OpenAI-style chat API with tool calling: your own server (vLLM, SGLang, Ollama, LM Studio, ...) or xAI's Grok. The requests come from the Minecraft server, so the model server must be reachable from there (Tailscale is fine).

1. `install buddy` on the turtle (see [Installing](#installing)), or drag `buddy.lua` onto its screen.
2. Point it at your model server(s): `buddy server http://my-gpu-box:8000 http://192.168.1.20:8000`. Give one or more; when the first can't be reached it uses the next. A bare `host:port` works too. It picks the first model the server offers (`buddy models` lists them, `buddy model <id>` picks one).
   - Grok instead: `buddy server grok`, then `buddy key <xAI key>` (from [console.x.ai](https://console.x.ai), paid per use).
   - Server needs a key? `buddy key <key>` saves it in `api.key` on the turtle. It never goes into this repo.
3. Put the turtle on its home spot, facing the way you like, then `buddy setup [name]` (default name Buddy). It writes a `startup.lua`, so it starts by itself.
4. `buddy` and type away: "look around", "go 5 forward and drop the cobble in the chest", "what have you got on you?", "come home".

**Places and memory:** walk it to a spot and say "remember this as the sorter drop chest" (stand it so the chest is in front of, above or below it). From then on "go to the sorter drop" works, and so does "move everything from the miner chest to the sorter drop": it walks back and forth until the chest is empty. It walks between places along routes it has driven before, so it never needs to dig. Tell it facts too ("remember that the miner chests are north of home"). Places and notes live in `buddy.memory` and survive restarts. `set_home` and `buddy setup` forget the places, because they are stored as routes from home.

**Your own server, two things to check:**
- **Answers are streamed**, so a slow model doesn't hit ComputerCraft's 60 second limit as long as it keeps producing text. Thinking is switched off by default (`buddy think on` to allow it).
- **Tool calling must be on.** vLLM: start it with `--enable-auto-tool-choice --tool-call-parser <parser for your model>` (the GLM parser for GLM). If Buddy only talks and never moves, this is why.
- **ComputerCraft blocks private and local addresses** by default. If Buddy says "Domain not permitted", allow your servers in `config/computercraft-server.toml` (world `serverconfig` folder on some setups) by adding this **above** the existing `$private` deny rule, then restart the server. `100.64.0.0/10` covers all Tailscale addresses.
  ```toml
  [[http.rules]]
      host = "100.64.0.0/10"
      action = "allow"
  ```

**Talking in game chat:** equip a **Chat Box** from Advanced Peripherals on the turtle and start your message with its name: `buddy, put a torch above you`. It answers in chat.

| Command | |
|---|---|
| `buddy server <url> [url2 ...]` | use your own model server(s); `buddy server grok` for xAI |
| `buddy model <id>` | pick the model (`auto` = the first one the server offers) |
| `buddy models` | list the models the server offers |
| `buddy think on\|off` | own server: let a reasoning model (GLM, Qwen, ...) think before it answers. Off by default: much faster |
| `buddy key <key>` | save an API key on the turtle |
| `buddy name <name>` | rename it (also its chat name) |
| `buddy home` | after putting it back on its home spot by hand: reset its position |
| `/reset`, `/quit` | while chatting: forget the conversation / stop |

**Safety:**
- It counts its own steps from home and never goes more than 32 blocks from home on any axis (`range` in `buddy.cfg`). `go_home` walks back the way it came.
- It never digs to get somewhere and only breaks or places blocks when you ask. It refuses to break chests, barrels, computers, turtles, furnaces, hoppers, doors, beds and similar base blocks.
- It can't see you, so "come here" makes it ask where you are compared to it.

---

## Farmer (farmer.lua)
A **farming turtle** (a turtle with a diamond hoe) that looks after a field of crops. It flies one block above the field and harvests what's ripe: wheat, carrots, potatoes, beetroot, nether wart, melons and pumpkins (it leaves the stems), sugar cane and bamboo (it leaves the bottom block). It plants the same crop again straight away, tills bare dirt in the field into farmland and plants it, and uses bone meal on young crops if you give it some. Crops from other mods that use the normal crop ages work too.

**Setup.** Put the turtle on the corner of the field, **one block above the crops** (above the farmland + 1), facing along the field, with a chest next to it (behind, beside or under it, not on the field). Then:
```
farmer setup <x> <y> <z> <facing> <length> <width> [left]
```
`x y z facing` = where the turtle is (F3) and the way it faces; the field is `length` blocks forward (starting at the block in front of it) and `width` blocks to the right (or `left`), counting the column it stands in. With [GPS](#gps-and-the-map) `farmer setup <length> <width>` is enough. It starts on boot; `farmer` starts it by hand.

- Water in the field is fine (it flies over it), so is a torch or a path: what can't grow is remembered and skipped.
- Every 15 minutes it goes round. **Harvest now** on the panel sends it straight away.
- The harvest and spare seeds go in its chest; it keeps up to a stack of every kind of seed. Put that chest next to the storage room's input chest (or empty it there) and the storage room makes bread, sugar, paper, etc. from it.
- Fuel: lava buckets or coal in its chest. It never eats its crops.
- Without a hoe (a pickaxe) it still harvests and replants, but never tills (it would dig the dirt away instead).

## Fuel runner (fuel.lua)
A turtle (no tool needed) that keeps everyone's fuel chests full of **lava buckets**, so you don't have to. It fills empty buckets at a **dripstone lava farm** (cauldrons under pointed dripstone that hangs from a block with lava on top) or a **lava lake**, brings full buckets to the chests you give it, and takes the empty buckets that the bots left there back. Spare lava goes in its own chest, the depot. It runs on that lava itself.

**Setup.** Put it next to its depot chest with some empty buckets in it, then:
```
fuel setup <x> <y> <z> <facing>                     where the turtle is (with GPS: fuel setup)
fuel cauldrons <x> <y> <z> <count> <line> <walkway> a straight line of lava cauldrons
fuel lake <x> <y> <z> [radius]                      a lava lake: x y z = a lava block on its surface
fuel add <name> <x> <y> <z> [keep]                  a chest to keep stocked (default 4 buckets)
fuel list / fuel remove <name> / fuel clear
fuel
```
- **Cauldrons:** `x y z` is the first cauldron, `count` how many in a straight line, `line` the way the line runs and `walkway` the side with a free row of air next to the cauldrons for the turtle, e.g. `fuel cauldrons 100 64 200 8 east south`. A cauldron under dripstone fills in a few minutes; it goes round every 10 minutes.
- **Lake:** it flies over the lake one block above the lava and scoops up source blocks in a spiral, then goes deeper (turtles don't mind lava).
- **Chests:** it drops the buckets in **from above**, so keep the block on top of each chest free. Good ones: the [lumber turtle's](#tree-farm-lumberlua) chest (it puts the empty buckets back in it, the runner takes those), each miner's fuel chest, the builder's and the farmer's chest, the factory's supply chest.
- The panel's Bots tab has **Add chest**, **Add lake**, **Add cauldrons** and **List** buttons, so you can add a chest while standing next to it.

## Builder (builder.lua)
A **mining turtle** that does the boring building work. Give it jobs with world coordinates; it does them one after the other and comes home in between to unload, refuel and get blocks.

```
builder setup <x> <y> <z> <facing>          where the turtle is (with GPS: builder setup)
builder tunnel <x> <y> <z> <dir> <length> [width] [height]
builder flatten <x1> <z1> <x2> <z2> <y> [height]
builder floor <x1> <z1> <x2> <z2> <y> [block]
builder walls <x1> <z1> <x2> <z2> <y> <height> [block]
builder clear <x1> <y1> <z1> <x2> <y2> <z2>
builder list / builder cancel / builder clearall
builder
```
- **Tunnel** (default 3 wide, 3 high): `x y z` is the floor-level middle of the tunnel's mouth (the block you would stand in; keep it open from above, the turtle flies in there), `dir` the way it goes. It fills gaps in the floor (so it bridges ravines and caves), seals lava, water and cave openings in the walls and ceiling with blocks, dries up lava and water inside the tunnel, and puts a torch on the floor every 8 blocks. A safe, lit highway to your mine or to a second base.
- **Flatten**: everything above height `y` goes (16 blocks up, or `height`), holes at `y` get filled. Good for a building site.
- **Floor** / **Walls**: lays blocks at height `y` / builds walls round the rectangle. Blocks that are already there stay.
- **Clear**: digs out a whole box.
- **Blocks**: cobblestone, cobbled deepslate, dirt, netherrack and the like, or the block a job names (`builder floor 0 0 9 9 63 stone_bricks`). What it digs up is used too; spare gravel and cobble get thrown away when it's full. Put blocks, torches and lava/coal in its chest; order them from the storage room.
- It never digs chests, barrels, furnaces, computers and turtles, beds, doors or spawners: those spots get skipped (see `builder.log`).
- Jobs can also be given from the panel's Bots tab (**Tunnel**, **Flatten**, **Floor**, **Walls**, **Clear box**). Paused or rebooted mid-job, it carries on where it was.

## Turtle factory (factory.lua)
A **crafty turtle** (crafting table) with a wireless or ender modem that turns parts into working turtles and sends them off. Order "a miner at 130 64 -350 facing south with role east": the factory crafts a plain turtle + diamond pickaxe + wireless modem into a mining turtle, puts it on its launch pad and switches it on. The new turtle boots from the factory's floppy disk, downloads `miner.lua` from GitHub, flies to its spot, runs `miner setup` there and starts working for the hub like the others.

**Layout:** a disk drive with a floppy disk **on top of** the factory; the block in front of the factory and the one above that free (the launch pad), with open sky above the pad; the supply chest behind, beside or under the factory.
```
factory setup <x> <y> <z> <facing>          (with GPS: factory setup)
factory build <kind> <x> <y> <z> <facing> [setup arguments]
factory list / factory cancel / factory order on|off
factory
```
- `kind`: `miner` (pickaxe), `builder` (pickaxe), `farmer` (hoe), `lumber` (axe), `fuel` (no tool) or `turtle` (just a turtle with a pickaxe that flies there). `x y z facing` is the new turtle's home spot: **build its chest there first**. The setup arguments are whatever comes after `x y z facing` in that bot's setup: `factory build miner 130 64 -350 south east` (role), `factory build farmer 90 64 10 north 9 9` (field), `factory build lumber 60 70 40 north 48` (lumber has no coordinates in its setup: just the radius).
- **Parts** in the supply chest, per turtle: a plain turtle (`computercraft:turtle_normal`), the tool, a wireless modem, and lava or coal (it gives each new turtle about 2000 fuel). The [storage room](#storage-room) can craft all of them: turtles (7 iron + computer + chest), computers (stone, redstone, glass pane), wireless modems (stone + an ender pearl) and diamond tools. Put the factory against the storage room's **pickup chest** (that becomes its supply chest) and type `factory order on`: it orders whatever is missing by itself.
- The new turtle flies straight there 6 blocks above the higher of the two spots and goes higher when something is in the way. If it gets stuck, it says where on its screen; pick it up and run the setup by hand.
- A new miner works like the others; give it its own home spot at least 10 blocks from the other miners' shafts.

## GPS and the map
GPS lets a computer or turtle ask where it is. It needs **4 computers with wireless or ender modems**, high up and not all in one flat layer or line (e.g. three at the same height in an L, the fourth a few blocks above one of them). On each one:
```
install gpshost
gpshost <x> <y> <z>        that computer's own coordinates
```
They start by themselves after that. With GPS:
- the farmer, fuel runner, builder and factory can do `<bot> setup` without coordinates (they find their facing by stepping forward and back),
- the pocket panel's **Map** tab shows where you are, plus the lumber turtle and Buddy. Miners (through the hub) and the newer bots are on the map even without GPS, because they keep track of their own coordinates.

## Good to know about the newer bots
The farmer, fuel runner, builder and factory share `botlib.lua` (`install` and `update` fetch it along). They all:
- keep their position and heading in a `.state` file, so a reboot or chunk unload doesn't lose them; `<bot> home` resets the position after you carry one back to its home spot,
- have the same screen: status, fuel bar and numbers, keys **P** pause / go on, **H** come home, **Q** quit,
- burn only lava buckets, coal, charcoal, coal blocks and blaze rods, from their chest,
- answer the pocket panel (Bots tab, Map, console, Update all) when they have a wireless or ender modem, and write problems to `<bot>.log`.

## Pocket panel
`panel.lua` runs on an **advanced pocket computer with an ender modem** (a normal wireless modem works too, within range). `install panel` on it (see [Installing](#installing)), then `panel install` (opens on start-up) and `panel`.

Tabs along the top (tap them, or keys 1-7, Q quits):
- **Home**: every machine at a glance. Green dot = it answers. Tap a card to open it.
- **Mine**: same as the hub dashboard: tap an ore (Other = type any rock or ore), STOP, RECALL, RESUME, session time. Tap a turtle to give orders to that turtle only, ALL to go back.
- **Store**: what's in the storage room. Search, tap an item and pick an amount to have it brought to the pickup chest (missing items get crafted). Pause/Resume, Resync.
- **Bots**: the lumber turtle, farmers, fuel runners, builders and the factory in one list. Tap one for its status, fuel and numbers, Pause / Go on, Come home, and its own buttons: *Harvest now*, *Add chest* / *Add lake*, *Tunnel* / *Flatten* / *Floor* / *Walls*, *Build turtle*. Buttons that need more ask for it on the bottom line (e.g. the tunnel's x y z, direction and length).
- **Buddy**: chat with Buddy, or send it home or to a place it remembers with one tap.
- **Map**: every bot seen from above, north up: `M` miners, `W` lumber, `B` Buddy, `F` farmer, `L` fuel runner, `U` builder, `T` factory, `@` you. `-`/`+` (or scroll) zoom, tap the map to move it there, tap a letter to see who it is and where, **Me** centres on you again. See [GPS and the map](#gps-and-the-map).
- **Update all** (on the Home tab, or `update all` in the console): every bot it can reach fetches its latest version from GitHub at a safe moment, then the panel updates itself. See [Updating](#updating).
- **>_ (console)**: type commands, with Tab completion and Up/Down history. `help` lists them all. Examples:
  - `bots` (who's online), `hub diamond`, `hub recall`, `Miner1 stop`, `hub item zinc 20`
  - `store find coal`, `store get iron ingot 32`, `store blocked`, `wood pause`, `buddy go fetch the logs`
  - on any bot except the storage turtle: `info`, `log`, `ls`, `cat <file>`, `get <file>` (copies it to the pocket), `reboot`; `miners reboot` does every miner
  - `listen minearmy` shows every message on that protocol, `send <id> <protocol> <msg>` sends one by hand

With a password you can also change things on a bot: `put <file> [as]` sends a file from the pocket, `update <file> [as]` sends it and reboots the bot, `rm <file>` deletes one, and `lua <code>` runs Lua on the bot (e.g. `Miner1 lua turtle.getFuelLevel()`). `miners update miner.lua` updates the whole fleet.
To turn this on, put a password in a file `dev.key` on each bot and type `key <password>` on the pocket. Without `dev.key`, a bot refuses put, rm and lua. With it, every dev command needs the password, so other players with a modem can't use them.
Careful: Lua run with `lua` runs next to the bot's program, so moving a turtle that way makes it lose track of where it is.

Every machine needs its own wireless or ender modem and the version of its script that answers the panel: `hub.lua` (this repo), `roomsorter.lua` (already does), `lumber.lua` and `buddy.lua` (new versions), and the bots that use `botlib.lua` (farmer, fuel, builder, factory) all answer on the protocol `bots`. In the console, call those by name or kind: `builder tunnel 100 64 200 east 50`, `fuel add lumber 60 70 41`, `factory build miner 130 64 -350 south east`, `farmer now`, `builder list`. A turtle has two upgrade slots, so the modem takes the one its tool doesn't use. An ender modem on the pocket computer reaches normal wireless modems anywhere in the same dimension, as long as their chunks are loaded.

---

## License

GPL-3.0, see [LICENSE](LICENSE). You may use, change and share these scripts; copies you share, changed or not, must stay under the GPL too.
