# Miner offline autonomy (PENDING APPROVAL)

> PENDING APPROVAL. Jeffrey decides on this plan. Nothing here gets built
> until he accepts it. These are notes.

Part of the fleet PR. Miners on a normal wireless modem sometimes leave the
range of the hub and the server. The server stays the source of truth whenever
it is reachable. Out of range, the miner runs on its own under these rules.
This is a full feature for normal-modem miners, not a fallback. An ender modem
stays an option, not the default answer.

## Chunk loading

A normal-modem turtle only keeps working out of range while its area stays
loaded, by a player nearby or a chunk loader. When the area unloads, the
turtle freezes. When it loads again, the turtle reboots without GPS, and the
no-dig-while-lost rule applies: it does not dig until it has re-anchored its
position.

## Lease

Before it leaves range, the miner caches a lease signed by the server (HMAC,
per the hardening track). The lease covers:

- the job area (the cells it may mine);
- the drop-off box, charger and home locations;
- the return route;
- the dev-mode toggles and thresholds in force;
- a deadline.

The miner never claims a cell outside the lease.

## Safety invariants

These hold in every mode. No dev-mode toggle can disable them.

- No digging while lost. The miner re-anchors its position first.
- A reserved corridor: the return route stays reserved and clear.
- For block state, the newest observation wins.
- An expired lease means wait: no new digging until the server renews it.
- A full journal means go home.

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

## Store and forward

The miner keeps a local, append-only, bounded event journal: mined cells, map
deltas, items, problems. On reconnect it replays the journal idempotently. The
server reconciles it with fixed merge rules and wins every conflict.

## Check-in and expiry

The miner returns toward range to check in on a period, and at the lease
deadline at the latest. If it does not come back, the server marks it overdue,
expires the lease and frees its cells (the H5 dead-turtle recovery).

## Gate B

- A miner on a normal modem goes out of range mid-job, hits a full inventory,
  low fuel, lava and a blocked path, comes back, syncs, and the server's counts
  reconcile exactly with the items delivered.
- A miner dies out of range. The lease expires and its cells are freed.
- A normal-modem miner's area unloads while it is out of range. It freezes,
  reboots without GPS when the area loads again, and digs nothing until it has
  re-anchored.
