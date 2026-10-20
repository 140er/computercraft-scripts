Mining leases and extraction

Mining requires paired SSOT and calibrated navigation from PR 2. It defaults off. Configure each turtle's navigation bounds to include its home, the approach corridor, and the mine. Mining uses known air for travel to a lease and for return. Unknown approach corridors need prior navigation observations.

Run these commands on a paired turtle. Replace the example coordinates with the test mine coordinates.

```text
miner mine bounds minecraft:overworld 0 64 1 11 66 6 4
miner mine home 1 65 0 south
miner mine enable
miner
```

`miner mine bounds` saves the shared mine through the authenticated server. The server rejects a replacement while any task is assigned. Width must be divisible by spacing, which can be 2, 3, or 4. Height must be divisible by 3. Tunnel length is at most 64. A mine has at most 128 zones. Each zone has at most 768 cells. Mining bounds are separate from navigation bounds.

Each zone has one southbound tunnel. Its entry is one block above the zone floor, one block east of the west edge, and one block north of the zone. The allocator selects the nearest available entry in the turtle's dimension. It keeps one unfinished task per turtle. Use separate, reachable home poses for the miners.

The miner inspects all six faces before extracting adjacent ore. It follows a visited DFS stack, stays within its zone, and returns along known air. Vanilla ore names, ancient debris, `c:ores`, `forge:ores`, and their category tags are accepted. `miner.cfg` can also supply `mining.targets`, a table of block names mapped to true. Navigation still rejects fluids, waterlogged blocks, containers, and blocks outside the excavation allowlist.

Spacing is a coverage choice. At spacing 4, an isolated block two cells from a tunnel can remain unseen. Flood-fill reaches connected veins, but does not reveal isolated ore through stone. Zone boundaries also limit extraction. The gate fixture measures 46 extracted ore blocks and three intentionally untouched gap blocks.

The server saves task ownership and acknowledged progress in `ssot.state`. The turtle saves its DFS stack, visited cells, pending action, and return reason in `mining.state`. `nav.state` remains the authority for physical movement. Keep these files together. A missing traversal file with nonzero server progress stops mining instead of discarding queued ore. Resolve an ambiguous turn with the existing navigation calibration command.

An unstarted offer can expire after 30 seconds and change owners. Once a miner activates a task, expiry quarantines it to that owner. The owner renews it after recovery. Active expiry does not prove that a turtle stopped digging. Automatic reassignment of active work would risk two miners in the same zone.

Low fuel, fewer than two empty slots, recall, or a hazard interrupts work. The miner retains its stack and returns to its configured home pose and heading. It reports a blocked home or resume route and stops work. ESTOP stops movement immediately. A later go command resumes it. `miner mine disable` saves the disabled flag for the next boot.

PR 4 owns unloading and proximity charging. This version never drops items to an unavailable chest. Clear inventory or provide fuel at home, then let the miner resume. It retains the unfinished task while service is unavailable. Warehouse and charging poses will have their own commands in PR 4. No far_beacons dependency or chat command was added.

An update request returns this opt-in miner home. Apply updates from the turtle shell. Automatic completion of a hub update is not wired into the new mining loop.
