# Configure warehouse turtles

Warehouse movement, mining service, and traffic yielding default to off. Pair each turtle in the server's `ssot.cfg` before setup. Use the same secret on that turtle. Keep the existing UUID chat allowlist. These commands run on computer terminals and do not add chat commands.

Install the `store` role with `install store quick`. `roomsorter ssot` and `sorter ssot` accept the same arguments as `store`.

Configure the connection and calibrated parking pose on the turtle. Keep parking cells separate from shared source and drop access cells. Headings are north `0`, east `1`, south `2`, and west `3`. Use actual coordinates for your world. Completed orders return to this parking pose so another turtle can use the drop.

```lua
store server <serverId> <pairedSecret> minecraft:overworld
store pose <x> <y> <z> <heading>
store bounds <minX> <minY> <minZ> <maxX> <maxY> <maxZ>
```

After an interrupted turn, use `store calibrate <heading>` with the turtle's observed heading. Calibration keeps the configured parking pose and reconciles its current GPS pose with the server.

Survey each route before enabling orders. Survey permits movement through air and never digs. Normal warehouse work uses only surveyed cells. GPS must cover the warehouse.

```lua
store survey <x> <y> <z>
```

Define each interaction site by the cell the turtle occupies, its heading, and the side of the adjacent inventory. Valid sides are `front`, `top`, and `bottom`. A charging site is the parking cell within the powered station's measured range.

```lua
store site iron source <x> <y> <z> <heading> front
store site output drop <x> <y> <z> <heading> front
store site charger charge <x> <y> <z> <heading> front
store stock iron
store charger charger 2000
store traffic on
store enable
store install
```

Place source and drop inventories beside their access cells. Keep interaction cells clear. Stock reports read the actual source inventory. Refresh reports after a player or another system changes a source.

Submit an order with a unique key. Repeat item, quantity, and source for additional lines. Retrying the same key and contents returns the same order. Reusing that key for different contents fails.

```lua
store order order-17 output minecraft:iron_ingot 32 iron
store
store charge charger 2000 60000
```

Orders reserve reported stock before pickup. If stock cannot fill a line, the order records a partial delivery. Submit a new key for the remaining quantity after replenishing and reporting stock. The dispatcher retains at most 32 orders, 32 sites, eight lines per order, and 64 item names per stock report. Reaching a limit stops new work. It does not discard old orders.

Each physical transfer records the selected slot and its count before the operation. On reboot, the turtle measures that slot before acknowledging progress. Keep the turtle's inventory and pose unchanged during recovery. Mixed sources use empty turtle slots to hold unwanted stacks, then return those stacks before leaving. A source with more unwanted stacks than the available slots produces a partial order. A full drop retains cargo and retries. Missing inventories never cause a drop into the world.

Active orders and bay locks keep their owner across a crash. Restart that owner with its disk and inventory intact. The dispatcher does not assign its cargo to another turtle. A completed interaction releases its bay. Movement reservations still protect the occupied cell.

## Enable mining service

Configure mining and navigation first. Define the drop and charger sites with their actual world poses. The miner keeps its own route journal. Run `miner nav survey <x> <y> <z>` to visit each access cell and return home before enabling service. A walk failure stops service and keeps the mining traversal.

```lua
miner service drop output
miner service charger charger
miner service fuel 2000
miner service enable
miner nav traffic on
```

Set `warehouse.keep` in `miner.cfg` to a map of item names that must stay in the turtle, such as `{["minecraft:bucket"]=true}`. Equipped upgrades stay equipped. `warehouse.chargeTimeout` sets the charging timeout in milliseconds and defaults to 60000.

After a mining interruption, the miner returns home, unloads into the configured inventory, waits for measured station charging when fuel is low, and returns to its saved task. It preserves the vein traversal. `miner service disable` disables automatic service.

`store charger <site> <targetFuel>` enables automatic low-fuel charging during orders. The turtle preserves its cargo and line quantities, charges, returns to its saved pose, and continues the same order. It checks the known outward and return costs before departing. A target that cannot cover the return route fails before movement. Mining reserves the drop and charging round trips before leaving home.

Charging reads `turtle.getFuelLevel()`. It never sucks a fuel item or calls `refuel`. A charger that cannot be reached releases its bay. A busy bay and a station with no fuel rise have bounded waits. A failed charging attempt returns to its saved pose. Unlimited fuel completes without a wait. A target already met needs no additional rise.

Traffic first tries a known alternate route. In a head-on aisle, the higher computer ID retreats through known air to a passing cell and waits for the other turtle to clear it. It never digs a sidestep. A dead end, blocked passing cell, missing peer, or wait limit returns an error and preserves physical occupancy. Provide passing cells in one-wide aisles.

No code in this PR depends on `far_beacons`. Ender-modem and chunk-loading support are acceptance-test results for the pinned local jars. They are not assumptions about another pack.

The supplied turtlebattery 0.3.0 jar and SBW 0.8.9.2 charged advanced turtles throughout an inclusive box of eight blocks on each axis. An offset of nine on one axis did not charge. The service still waits for actual fuel rise, so a configured parking pose cannot substitute for power.

A standalone server computer with an ender modem did not keep its own chunk loaded in the local test. Keep a running ender turtle near the server or provide a persistent chunk ticket. The acceptance fixture uses that turtle and checks its heartbeat with zero players online. Moving ender turtles must also keep the station and GPS hosts loaded. Verify those chunks before enabling work in another installation.
