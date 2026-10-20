# Miner offline autonomy, approved (#48, #49)

> APPROVED. Jeffrey accepted it on 2026-10-20 at 17:09 (Europe/Amsterdam).
> The build plan is [the H4 offline plan](../plans/cc-h4-offline-plan.md) (N1, B1 and B2). Where the plan and
> these notes differ, the plan wins.

B1 implements leases, offline movement, and journals after W1's settings
registry. B2 then adds local problem handling. N1 supplies framed positions
and confidence before either. Miners on a normal wireless modem sometimes leave the
range of the hub and the server. The server stays the source of truth whenever
it is reachable. Out of range, the miner runs on its own under these rules.
This is a full feature for normal-modem miners, not a fallback. An ender modem
stays an option, not the default answer.

## Chunk loading (#49)

A normal-modem turtle only keeps working out of range while its area stays
loaded, by a player nearby or a chunk loader. When the area unloads, the
turtle freezes. On reload it reboots. N1 restores certain position through
journal and fingerprint reconciliation or an anchor. An unresolved move uses
fuel only when the measured move cost is known and no charging occurred.
Suspect or lost position forbids digging. GPS is optional.

## Lease (#49)

Before it leaves range, the miner caches the plan's v2 lease with a keyed
BLAKE3 MAC using its pairing key. P0 freezes it in
`docs/design/h4-offline-contract.md`. The lease covers:

- the job area (the cells it may mine);
- inline framed access poses for drop-off and charger, and the home pose;
- a reserved return corridor of at most 256 cells;
- the dev-mode toggles and thresholds in force;
- UTC millisecond issue and expiry times, numeric epoch, and fuel reserve.

The miner never claims a cell outside the lease. A miner holding an offline
lease holds no peer replicas. Miners never count toward the two required copies.

## Safety invariants (#49)

These hold in every mode. No dev-mode toggle can disable them.

- Digging requires certain position from N1 recovery or an anchor.
- A reserved corridor: the return route stays reserved and clear.
- Block state follows B1's lease authority and section-revision rule, then
  UTC milliseconds, turtle ID, and sequence as tie-breaks.
- An expired lease forbids moving or digging until renewal or a return-only grant.
- At 80% of the journal budget, stop new work and head home. Preserve room for
  the return. If another action cannot be journaled, wait.

## Local problem handling

| Problem | Behavior |
| --- | --- |
| Full inventory | Compact, or trash items on its filter list. Otherwise return to drop off. |
| Low fuel or battery | Return, with a margin computed from the distance home. |
| Bedrock or unbreakable block | Mark the cell and route around it. |
| Lava or water | Handle safely (place a block, avoid the source), never path through. |
| Gravel or sand | Dig until the falling blocks stop. |
| Mob or blocked path | Retry, then reroute. |
| Lost position | Re-anchor with GPS if available, otherwise dead reckoning plus the journal. |
| Stuck | Back off, then mark the cell and skip it. |

Defaults are conservative. Every behavior here is a dev-mode setting, on/off
plus its thresholds, per turtle and global. Settings tune behavior; they never
switch off the safety invariants above.

## Store and forward (#49)

The miner keeps the plan's versioned entry and journal head. Kinds are move,
turn, dig, observe, item, problem, boot, and anchor. Physical intent precedes
action, then done records the resolved outcome. Replay keys on turtle, lease,
and sequence. The byte budget comes from actual free space after navigation,
code, pending requests, update staging, and return reserves.

The server applies the holder's valid observations inside its unexpired lease.
Outside it, observations apply only to unknown cells or sections no newer than
the lease's issuedRev. Otherwise the cell becomes unknown. Ties use UTC
milliseconds, turtle ID, and sequence. The miner accepts that result.

## Check-in and expiry (#49)

The miner returns toward range to check in on a period, and at the lease
deadline at the latest. If it does not come back, the server marks it overdue,
expires the lease and releases scheduling claims under H5 recovery. Possible
physical occupancy stays unknown until observation or reconciliation clears it.

## Gate B (#49)

- A miner on a normal modem goes out of range mid-job, hits a full inventory,
  low fuel, lava and a blocked path, comes back, syncs, and the server's counts
  reconcile exactly with the items delivered.
- A miner dies out of range. The lease expires, scheduling claims are released,
  and possible physical occupancy stays unknown.
- A normal-modem miner's area unloads while it is out of range. It freezes,
  reboots when the area loads again, and digs nothing until N1 restores certain
  position through journal and fingerprint reconciliation or an anchor.
