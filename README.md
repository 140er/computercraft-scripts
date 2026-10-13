# computercraft-scripts

ComputerCraft (CC: Tweaked) turtle scripts.

- `hub.lua` + `miner.lua`: **Mine Army**. A hub with a dashboard in your base, and a fleet of mining turtles that each go down their own shaft to the ore level, dig branch tunnels there and come back.
- `smartmine.lua`: the old standalone tunnel miner (no hub). Still works.

## Mine Army

### What it does
- Each turtle moves 1 block forward (into the hole you made there) and goes down. It finishes that 1x1 shaft to the ore level **once** and reuses it every trip after. Iron is above diamond, so the same shaft works for every level.
- At the ore level it digs a main tunnel with a branch every 4 blocks (3 blocks of rock between), 64 long by default.
- Tunnels are 1x1. It still inspects the block above and below, so it finds as much ore as in a 3-high tunnel, just faster. Mobs can't spawn in 1-high tunnels either.
- Caves: if a wall, ceiling or floor opens into a cave (air or water), it plugs the opening with cobble. If a branch runs into a cave, it closes the branch off and starts the next one. The main tunnel goes straight through and walls itself in on the way. This keeps the tunnels free of mobs, water and lava.
- At every step it looks left and right into the walls. Ores are followed as a vein. For the target ore (e.g. diamond) it checks 18 of the 26 neighbours.
- Lava gets sealed with the first placeable non-ore block. It never steps into lava and never uses coal to seal.
- Junk (cobble, deepslate, tuff, gravel, dirt, string, bones, ...) is dropped underground every ~10 blocks. It keeps one stack of blocks for sealing. All ores, including modded ones, are kept.
- It goes home when the inventory is full, when it needs the remaining fuel to get back, when its trip time is up, or when the hub recalls it. There it unloads into the chest, refuels from the same chest and goes again.
- **Clean chest:** every time it unloads, it also cleans its chest. Only ores (raw ores, gems, dusts, modded ores), fuel and buckets may stay. Anything else is taken out and dropped underground on the next trip, never in your base.
- It saves its position and progress in a file. After a reboot or chunk unload it first goes home safely and then continues where it was.
- Once it is inside the hole it covers it at floor level with a block, so nobody falls in. On the way back it digs it open, comes up and moves 1 block back to its home spot (chest behind it).

| Button | Level (Y) |
|---|---|
| Diamond / Redstone | -58 |
| Gold | -16 |
| Lapis | 0 |
| Iron | 16 |
| Copper / Coal | 48 |

### Regions (no collisions)
Each turtle has a "role" = the direction of its main tunnel. Its branches always go a quarter turn clockwise:

| Role | Main tunnel | Branches |
|---|---|---|
| east  | east  | south |
| south | south | west  |
| west  | west  | north |
| north | north | east  |

This gives every turtle its own quadrant, and no tunnel crosses another turtle's shaft.

### What you need
- Per turtle: a mining turtle (pickaxe) + a wireless modem (normal or ender).
- Per turtle: a chest directly **behind** the turtle. Fuel: coal or lava buckets (in the chest or in the turtle itself).
- Base computer (advanced for colour/clicking) + wireless modem. Monitor optional (advanced monitor = touch buttons).

### Fuel: lava buckets
- A full lava bucket = 1000 fuel. The turtle burns full buckets from its own inventory and from the chest.
- It keeps empty buckets. When it finds a lava source on the way, it scoops it with an empty bucket, burns it right away (+1000 fuel) and then seals the spot with a block. There is a lot of lava at Y -58, so a turtle with a bucket fuels itself.
- 2 full buckets per turtle is enough to start. If you only use coal, still give it 1 empty bucket.
- Flowing lava can't be picked up with a bucket; it just gets sealed.

### Normal wireless modems
A normal wireless modem reaches about 64 blocks, so the hub can't hear turtles deep underground. That's fine:
- A turtle gets its orders and unloads its loot at home. That always works as long as the hub is within ~64 blocks of the turtles (right next to them is fine).
- On the dashboard a turtle that is out on a trip shows in orange as "Underground". Red "NO SIGNAL" means it should be home but isn't answering.
- A turtle mines at most `mineMinutes` (default 15) minutes per trip and then comes back, even if it isn't full. That way a new ore choice gets picked up within 15 minutes. Change it in `hub.state`.
- `RECALL` only reaches turtles in range. The hub keeps repeating the call, but a turtle deep down only comes back when its trip time is up. `STOP` always works: it stays home.
- With ender modems everything is live, without these limits.

### Installing
On every turtle and on the hub computer (`http` must be enabled on the server, and the repo must be public):
```
wget https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/install.lua install
install
```
Or copy `miner.lua` / `hub.lua` by hand: drag the file onto the computer's screen.

### Setup: your 4 turtles
They stand at y=65, z=-743, with the chest on the north side (z=-744), so they face **south**. `setup` warns you if the turtle doesn't see a chest behind it.
```
-- turtle at x=-216 (easternmost)
miner setup -216 65 -743 south east
-- turtle at x=-218
miner setup -218 65 -743 south south
-- turtle at x=-220
miner setup -220 65 -743 south north
-- turtle at x=-222 (westernmost)
miner setup -222 65 -743 south west
```
Setup also writes a `startup.lua` and gives the turtle a label (`Miner-east`, ...). That way it starts by itself after a reboot and keeps its files when you pick it up.

Hub computer:
```
hub install
hub
```
Then reboot the turtles (or type `miner`).

### Controls (dashboard)
- Tap an ore (Diamond, Iron, ...). All turtles go mining for it. A new choice applies from the next trip.
- Tap a turtle in the list first and then an ore: only that turtle gets that ore. `ALL` goes back to the whole fleet.
- `STOP`: stay home after the current trip.
- `RECALL`: come home right now (if in range). `RESUME` lets them go again.
- Keyboard: `1`-`7` ore, `s` stop, `r` recall, `h` resume, `u` update, `a` all, `q` quit.
- At the bottom, "IN TURTLES NOW" shows what is in the turtles right now, summed up. Turtles out of range count with what they last reported.

### Turtle is in the wrong place / thinks it is home
A turtle never unloads if there is no chest behind it. The dashboard then shows "ERROR: no chest behind me".
Fix: pick the turtle up (it keeps its files) and put it on its home spot next to the chest, facing any direction. On boot it looks around: if it sees its chest, it knows it is home and resets its position and heading itself. Progress is kept.
If that doesn't work, type (Ctrl+T first if it is running):
```
miner home
miner
```
`miner home` only resets the position; which tunnels are already dug is kept.

### Updating the turtles through the hub
1. Drag the new `miner.lua` onto the **hub computer's** screen. Nothing happens yet.
2. Press **UPDATE** (or key `u`). The number in brackets is how many turtles run a different version.
   - Turtles at home update right away.
   - Turtles out on a trip that can hear the hub go home first and update there.
   - Turtles too deep to hear the hub (normal modem) update when they get home.
- Updating only happens at home, after unloading. Position, heading and progress are stored in `miner.state` and `miner.cfg` and are kept. After the reboot it continues at the same branch.
- Turtles that don't have the released update yet show a `*` after their name on the dashboard.
- A turtle running a version from before hub updates existed can't update itself: copy `miner.lua` onto it by hand once. Its `*` never goes away until you do.
- A broken file is rejected. The turtle keeps its old version.
- To update the hub itself: drag `hub.lua` onto it as well and reboot the hub computer.
- Note: anyone on the server with a computer and a modem could pretend to be the "hub". On a server with strangers, that is a risk.

Without a hub: `miner diamond` (or `iron`, `gold`, ...) runs one turtle on its own.

### Good to know
- Turtles only work in loaded chunks. When the chunk unloads, the turtle stops. When it loads again, the turtle restarts, goes home and carries on.
- The more branches there are, the longer the main tunnel and the trip. The branch length is in `hub.state` (`branchLen`).
- Settings at the top of `miner.lua`: `BRANCH_LEN`, `JUNK_EVERY`, `MAX_VEIN`, `FUEL_MARGIN`.
