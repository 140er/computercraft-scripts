# Hardening track

Jeffrey wants the fleet as bug free as possible before the warehouse v2
features land. This track fixes the findings in
[the 2026-10-20 review](../review/judgment-2026-10-20.md). The shared shapes
for it live in [the wh2 contract](wh2-contract.md).

## Merge order

PR 5, PR 6, H3, H1+H2, H4, H5, fleet, wizard, layout, craft.

Fleet and wizard develop alongside this track, then rebase onto it and use its
auth and request queue. Layout and craft start after H3 and H4 are merged.

## H3: server event loop

- Incoming requests go into a queue. One worker coroutine handles them.
- Nothing yields inside `handle` or a save: no `sleep`, no `http.get`, no
  `os.pullEvent` in those paths.
- The periodic timer survives lost events and is re-armed.

## H1+H2: auth and updates

- HMAC-SHA256 over request id, counter, op and body. The key never goes on
  the wire, in requests or in replies. Mesh relays forward the MAC, not a key.
- Replays are rejected. A counter near or at its maximum cannot lock a turtle
  out.
- Updates use a signed manifest that names one version for every file. The
  client pins the server id, installs all files or none, and keeps the last
  good version for rollback. No unauthenticated `rednet.lookup` fallback.
- Extras: version and capability handshake between client and server.

## H4: disk budget

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

Cold storage on peers, built on top of that foundation:

- The server offloads cold state, such as map chunks nobody touched recently
  and old journals, to peers it rates as reliable.
- The score measures how consistently a peer stays reachable: ping and reply
  success over time, never leaving modem range or sitting in an unloaded chunk,
  uptime, and power headroom (fuel or battery). Movement and stationarity do
  not count.
- Priority: store and warehouse robots first (they move a lot but stay in
  range), then stationary computers, then miners. Miners qualify only while
  their measured reachability stays high.
- Each cold chunk lives on at least 2 peers. Content hashes plus HMAC protect
  integrity.
- Fetch on demand into a local LRU cache.
- Re-replicate early when a peer's reachability starts to drop or its power
  runs low. Rebalance by free space.
- Unreachable cold data counts as unknown, never as free. Turtles route
  conservatively around it.

## H5: dead turtles

- Live recovery from the move journal, without a reboot.
- Expiry for moves in phase `started`, for poses, and for warehouse jobs.
- An admin `forget turtle` command.
- A commit timeout after a real move, or a GPS failure, recovers instead of
  halting the turtle.
- Extras: binary-heap A* open list, one GPS read per block.
