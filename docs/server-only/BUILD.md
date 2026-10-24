# Builder jobs

The server runs one builder job on one paired turtle. Installation adds
`so-mod-build.lua` to the server role. Update workers before building. Builder
refuses work until a worker advertises the `parkBatch` capability. Jobs stay stopped
until START or `start`. MORE opens the drop-point list, which has a BUILD button.
BUILD has START, STOP, SETUP and BACK buttons at 26x20 and 29x12. SETUP shows both
corners, material and turtle. Its shape button cycles FLOOR, WALLS and BOX.
Setup pages belong to each display session.

Configure the job with typed commands. Coordinates describe the blocks to place.
Both corners are inclusive. Shapes accept at most 16384 cells in their bounding
volume. The default shape is floor.

```text
area 0 64 0 4 64 4
shape floor
material minecraft:stone
add 12 0 66 -2 s
start
stop
```

`shape platform` also makes a floor. Floors use only the lower Y layer.
`shape wall` and `shape walls` fill the rectangle perimeter on every Y layer.
`shape box` adds the bottom and roof to those walls, leaving the interior empty.
A 5x5 floor has 25 blocks. A 3x3x3 box has 26 blocks.

`add <id>` uses the paired turtle's registered world pose when it includes a
facing. Otherwise supply `add <id> x y z n|e|s|w`. A turtle assigned to mining or
lumber cannot also join the builder. Configuration waits for an open lease to
finish. An uncertain pose accepts an explicit re-add and requires START afterward.

Main's builder uses text jobs rather than a separate blueprint file. Import its
floor/platform and wall/walls commands with `import`, optionally including the
`builder` prefix.

```text
import floor 0 65 0 4 65 4 stone
import builder walls 0 64 0 2 64 2 3 stone
```

Imports preserve main's conventions. A floor uses the first corner's Y minus
one. Walls start at the first corner's Y. Their optional height defaults to
three. Imports accept material names without the `minecraft:` prefix. Clear,
flatten and light jobs are outside this module's scope.

## Supply and safety

Add a `storage` drop point through MORE. Coordinates identify the chest itself.
`down` uses the cell above it; `front` chooses a neighbouring cell and faces the
chest. Keep that access column and the route above the build clear. Supply uses
the existing storage/any drop-point selection. Stock that chest with the exact
material name. The builder selects empty inventory slots when it sucks stock.
Wrong items remain in the inventory and can cause an inventory-full alert.
It does not order stock from the Storage Room.

When the turtle runs out, it visits storage and returns to the current target.
An empty chest shows `out of material` and retries every ten seconds on `SO.now`.
A missing chest, blocked route, foreign reservation, mining lane, or range
boundary holds the job. Fix the cause and press START. The turtle needs fuel;
out-of-fuel jobs hold for operator refuelling.

The turtle builds from the bottom up and places downward. Horizontal travel
uses a clearance height above the blueprint and the original turtle position.
Every dispatch reserves the departure, movement and affected block cells under
`build:<id>`. Travel batches stop at the proven radio range and contain at most
16 steps. Builder refuses mining shaft and spine cells using `so-mine-plan`.
Every builder batch opts into worker parking after expiry. Its persisted park flag
also prevents a restarted worker from backtracking or digging through inherited
journal history. It never digs, including inside the blueprint. An unexpected existing block
holds the job. An existing matching material counts as complete.

The server saves progress and an intent before dispatch. On restart it keeps
reservations until the worker confirms its journal pose. It then inspects the
current target. A matching block advances the cursor without another placement.
A physical placement followed by a lost report therefore does not place twice.
Save failures stop new work. Dug-retirement protection includes the worker,
blueprint and any supply trip.

## Proposed Gate B C15, builder

C15 is proposed for `tools/gateb`; it is not registered in the current runner.
The orchestrator should add it to the services group and map changes to
`so-mod-build.lua` to C15. Installation changes also affect C1, navigation affects
C3, and restart behaviour affects C9 and C11. Until that mapping exists,
`tools/gateb/run.py --changed` treats the new Lua module as shared code and selects
all registered checks. That selection cannot give builder-specific pass credit.

Run C15 only in a private test world with the real pack and paired workers.
Save the exact SHA, world coordinates, cold and final block snapshots, worker
journals, leases, reservation samples and actual display frames. Its criteria are:

1. Install the server and worker normally. Use drawn MORE, BUILD, SETUP, START,
   STOP and BACK buttons on 26x20 and 29x12 displays. Confirm the resulting role
   or job state after each click.
2. Build a 5x5 stone floor and compare all 25 blocks against the blueprint.
   Build a 3x3x3 hollow box and compare all 26 shell blocks plus the empty centre.
   Reject any placement outside those expected cells or any dig anywhere.
3. Supply fewer blocks than the floor needs. Observe the storage trip, empty
   material alert and a stationary worker. Refill the physical chest and observe
   automatic completion after the retry without a second START.
4. Restart the server after a physical placement and before its report commits.
   Resume from the saved cursor. Require the remaining structure to complete
   with one successful placement per target and no reservation loss while the
   pose is unknown. Repeat with a worker restart between target inspection and
   placement.
5. Hold one target with a competing job. Require no placement there until that
   reservation releases. Block the travel path outside the volume and require
   an alert with every outside block unchanged. Repeat near a mining shaft and
   at the proven radio range boundary. Reject a lease crossing either boundary.
6. Stop the server during a movement batch and after a placement. Keep it off
   beyond lease expiry and the fast-beacon window. Require the worker to finish
   only its reserved batch and then stay parked. Seed an earlier dug journal
   entry outside the volume, place an obstacle there, and require zero fallback
   movement or digs. Reassign the worker to mining and require builder to stop.
7. Keep the worker below 1 MB throughout and record server save failures as holds.
   Record visible alerts for missing chests, wrong stock and unusable fuel.

Gate B is reserved for the orchestrator. The implementation PR includes Lua
world-simulation evidence, not a real Minecraft pass.
