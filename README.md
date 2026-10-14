# computercraft-scripts

ComputerCraft (CC: Tweaked) turtle scripts.

- **Mine Army** (`hub.lua`, `miner.lua`, optional `relay.lua`): a hub with a dashboard in your base and a fleet of mining turtles. Each turtle goes down its own shaft to the ore level you pick, mines branch tunnels there and comes back to unload and refuel.
- `smartmine.lua`: the old standalone tunnel miner (no hub). Still works.
- **Lumberjack** (`lumber.lua`): a tree farm turtle. Finds trees around its chest by itself, fells and replants them, refuels from the wood and puts the logs in the chest. See [Tree farm](#tree-farm-lumberlua) below.

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

### Updating
1. Drag the new `miner.lua` onto the **hub's** screen (nothing happens yet).
2. Press **UPDATE**. Turtles at home update right away; turtles that can hear the hub go home first; the rest update when they get home.
- Updates only happen at home after unloading. Position, heading and progress are kept (`miner.state`, `miner.cfg`).
- A broken file is rejected. A turtle running a version older than hub updates needs one manual copy.
- To update the hub itself: drag `hub.lua` onto it and reboot it.
- Anyone on the server with a computer and modem could pretend to be the hub; on a server with strangers that is a risk.

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
| tree turtle | `lumber setup [radius]`, `lumber` | one-time setup, run |
| tree turtle | `lumber home` / `lumber reset` | reset position after putting it back by hand / forget all trees |

## Settings
- `hub.state` (on the hub): `reach` (96), `branchLen` (64), `mineMinutes` (15), `sessionLen`, `mode`.
- Top of `miner.lua`: `BRANCH_LEN`, `BRANCH_GAP`, `FAST_GAP`, `REACH`, `LAYER_STEP`, `MAX_LAYERS`, `JUNK_EVERY`, `MAX_VEIN`, `FUEL_MARGIN`.

## Tree farm (lumber.lua)

A felling turtle (turtle + axe, no modem needed) that finds trees around its home by itself, fells them, replants them and keeps farming them.

1. Put the turtle somewhere in the open with a chest directly **behind** it (logs go in there) and a chest directly **under** it with **lava buckets** (its fuel). Keep the space above the turtle open: it flies out and back through there.
2. Drag `lumber.lua` onto the turtle (or `install lumber`).
3. `lumber setup [radius]`: how far from the chest it may go (default 48 blocks, so it stays in the chunks around you).
4. A few saplings in the turtle or the chest help it get going (optional).
5. `lumber` (starts by itself on boot after setup).

```
 LUMBERJACK                    RUNNING
 Felling a tree at 12,-3,4
 Fuel ██████████████████░░░░░   4180
 Lava 12 buckets in the chest
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
- **Home:** it puts the logs, sticks, apples, extra saplings and empty buckets in the chest behind it. Below 4000 fuel it takes lava buckets from the chest under it until it has about 5000 (one bucket = 1000). Out of saplings, it takes them from the chest behind it.
- Once the whole area is searched or it farms 64 trees, it only farms.

**Good to know:**
- 1x1 trees: oak, birch, spruce, jungle, acacia, cherry. Dark oak is left standing. Of a 2x2 giant spruce/jungle it only cuts one column.
- It never digs ground or stone, only logs, leaves and small plants (grass, flowers, vines). It can't tell a log house from a tree, so keep wooden builds out of its radius.
- Saplings: cutting the crown gives a few saplings per tree, more than it needs. The rest go in the chest (it keeps up to 64 of each kind).
- Fuel: it **never burns its own wood**. Only lava buckets (or coal, charcoal, coal blocks) from the chest under it. Walking, climbing and flying cost 1 per block, going around a crown about 20; a busy hour in a forest uses about 3 to 4 lava buckets. Empty buckets come back in the chest behind it, so you can refill them. With no fuel left it waits at home ("Out of fuel") until you add some.
- Reboots / chunk unloads: position and heading are saved on every move and turn. After a restart it finishes the tree it was cutting and flies home. Errors are kept in `lumber.log`.
- `lumber home`: you put it back on its spot by hand. `lumber reset`: forget all trees and search the area again.
- Settings at the top of `lumber.lua`: `RADIUS`, `MAX_SPOTS`, `NURSERY_RADIUS`, `SAPLING_RESERVE`, `SAPLING_WANT`, `LEAF_RINGS`, `REGROW_MIN`, `EXPLORE_CELLS`, `HOP`, `WAIT`, `KEEP_SAPLINGS`, `BONEMEAL_TRIES`.

## Good to know
- Turtles only work in loaded chunks. When a chunk unloads the turtle pauses; when it loads again it restarts, goes home and carries on.
- `smartmine.lua` is the older standalone miner: `smartmine <length> [tunnels] [gap] [block1,block2,...]`.
