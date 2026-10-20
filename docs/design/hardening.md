# Hardening track

Jeffrey wants the fleet as bug free as possible before the warehouse v2
features land. This track fixes the findings in
[the 2026-10-20 review](../review/judgment-2026-10-20.md). The shared shapes
for it live in [the wh2 contract](wh2-contract.md).

## Merge order (#48)

H4 and miner autonomy are approved. Jeffrey accepted the plan on 2026-10-20
at 17:09 Europe/Amsterdam. The program order follows
[the accepted plan](../plans/cc-h4-offline-plan.md). It is P0, H3, H1H2, N1, then I1
and I2 alongside H4a and H4b1, then H5, H4c, W1, then B1 and B2 alongside T1,
A1 and T2, then S1, H4b2, H4d.

PR 5 and PR 6 feed installer and UI work. W1 is the fleet PR and follows H4c.
Wizard follows W1, layout follows wizard, and craft follows layout. They need
H3 and H4a through H4c, without waiting for H4d. The full file ownership and
shared-file integration order are in [the wh2 contract](wh2-contract.md).

## H3: server event loop

- Incoming requests go into a queue. One worker coroutine handles them.
- Nothing yields inside `handle` or a save: no `sleep`, no `http.get`, no
  `os.pullEvent` in those paths.
- The periodic timer survives lost events and is re-armed.

## H1+H2 auth and updates (#47, #53, #55)

- A MAC over request id, counter, op and body. The approved plan uses
  ccryptolib's keyed BLAKE3 for it, and an Ed25519-signed manifest. The key never goes on
  the wire, in requests or in replies. Mesh relays forward the MAC, not a key.
- The v2 envelope carries a keyed BLAKE3 MAC over rid, counter, op, and the
  canonical body, including its auth context. The client saves the counter
  and complete envelope before sending, then restores that envelope on boot.
- Replays return the saved result. Before the counter ceiling, an authenticated
  exchange advances the integer authentication epoch and starts a new session.
- Updates use a signed manifest that names one version for every file. The
  client pins the server ID, signing key ID, and Ed25519 public key. It installs
  all files or none and keeps the last
  good version for rollback. No unauthenticated `rednet.lookup` fallback.
- Extras: version and capability handshake between client and server.
- `ssot.cfg.requireMac` defaults to false. Once true, it rejects v1 requests.
  A durable upgrade marker prevents config changes or rollback from downgrading
  the authority. New wh2 operations always require v2 authentication.

## H4 disk budget, approved (#48, #49, #54)

> APPROVED. Jeffrey accepted it on 2026-10-20 at 17:09 (Europe/Amsterdam).
> The build plan is [the H4 offline plan](../plans/cc-h4-offline-plan.md). It splits H4 into H4a, H4b1, H4b2,
> H4c and H4d. Where the plan and these notes differ, the plan wins.

The server never hardcodes its disk size. Live is 4,000,000 bytes today, with
16,000,000 staged for the next restart.

Foundation, from the review:

- a. No fleet code cache on the state server's disk.
- c. A runtime cap read from `fs.getCapacity` and `fs.getFreeSpace`. Per-chunk
  dirty saves with batched writes, and no full-state copy and validation per
  request.
- e. An atomic save that keeps 2 copies, not 3. A failed save is recovered and
  reported; it never silences the server until a restart.
- b. Compact chunk format (binary or RLE) with a version header.

Cold storage on peers follows the accepted plan's replica rules (#49).

- The server offloads cold state, such as map chunks nobody touched recently
  and old journals, to peers it rates as reliable.
- The score measures how consistently a peer stays reachable: ping and reply
  success over time, never leaving modem range or sitting in an unloaded chunk,
  uptime, and power headroom (fuel or battery). Movement and stationarity do
  not count.
- Store and warehouse robots rank first, then stationary computers. At least
  two eligible non-miner peers verify each cold section before local eviction.
  Miners hold extra replicas only and hold none while holding an offline lease.
  A changed boot removes a peer from the count until hash re-verification.
- Content hashes and a server-only keyed BLAKE3 MAC protect integrity.
  The storage key needs a floppy export before peer storage is enabled.
- Fetch on demand into a local LRU cache.
- Re-replicate early when a peer's reachability starts to drop or its power
  runs low. Rebalance by free space.
- Unreachable cold data counts as unknown, never as free. Turtles route
  conservatively around it.

### No silent forgetting

The server never forgets data on its own. The local LRU cache only drops
copies that still live on peers.

Storage policy, one setting per server, on the panel and in dev mode:

| Policy | Behavior |
| --- | --- |
| `ask` (default) | Ask the player when space runs low. |
| `expand` | Use cold-storage peers only. Never forget. |
| `forget-old` | Evict the oldest data to unknown, with an optional age threshold. |
| `hybrid` | Peers first. Forget only when the peers are full too. |

Capacity flow:

- The server tracks total and used space across its own disk and every peer.
- At a warning threshold (default 80%), the panel and the AR glasses ask:
  "Storage almost full: add N turtles as storage, or allow forgetting data
  older than X?" N is estimated from the current growth rate.
- Enrolling a turtle as storage is one click on the panel, after a
  reachability check.
- Until the player answers, new map data is held compressed and writes pause
  before the control reserve is consumed. Miners retain observations in a
  runtime-sized local journal and stop new work at its return threshold.
  Nothing is dropped or acknowledged from RAM alone.

The hub uses the same two-copy backend. The plan reports 142143 bytes of hub
code after H4a, or about 260000 with crypto and planner code. The contract's
1 MB table admits two 300000-byte state copies, a 65536-byte control reserve,
32768 bytes for allocation overhead and small local files, 8192 scratch bytes,
and 33504 bytes of headroom. The ledger checks actual allocated bytes before
admission. The table is a design allowance, not runtime evidence.

The panel has a storage view: each peer's capacity, use and reachability, what
each one holds, where `forget` would apply, and a preview of exactly what would
be forgotten.

## H5: dead turtles

- Live recovery from the move journal, without a reboot.
- Expiry for moves in phase `started`, for poses, and for warehouse jobs.
- An admin `forget turtle` command.
- A commit timeout after a real move, or a GPS failure, recovers instead of
  halting the turtle.
- Extras include a binary-heap A* open list. P0 checks its yielding batches.
  N1 provides confidence and framed dead reckoning, with GPS as an optional
  check (#49).
