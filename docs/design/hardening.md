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

The server reads its disk size at runtime through `fs.getCapacity` and
`fs.getFreeSpace` and never hardcodes it. Live is 4,000,000 bytes today, with
16,000,000 staged for the next restart.

Large-disk profile (default):

- No fleet code cache on the state server's disk.
- Compact chunk format (binary or RLE), saved per chunk when dirty, with
  batched writes.
- No full-state copy and validation per request.
- Alert when the disk is nearly full. A failed save is recovered and reported;
  it never silences the server until a restart.

1 MB profile (small servers), on top of the above:

- The server offloads cold state, such as map chunks nobody touched recently
  and old journals, to cold-storage peers.
- Peers are turtles and computers the server rates as reliable. The score
  measures how consistently a peer stays reachable: ping and reply success over
  time, never leaving modem range or sitting in an unloaded chunk, uptime, and
  power headroom (fuel or battery). Movement does not count against a peer.
- Preference: store and warehouse robots first (they move a lot but stay in
  range), then stationary computers, then miners. Long-range miners qualify
  only while their measured reachability stays high.
- Each cold chunk lives on at least 2 peers. Content hashes plus HMAC protect
  integrity.
- Fetch on demand into a local LRU cache.
- Re-replicate when a peer's reachability starts to drop, when it is about to
  run out of power, or when it goes offline. Rebalance by free space.
- When cold data is unreachable, turtles route conservatively and treat its
  cells as unknown, never as free.

## H5: dead turtles

- Live recovery from the move journal, without a reboot.
- Expiry for moves in phase `started`, for poses, and for warehouse jobs.
- An admin `forget turtle` command.
- A commit timeout after a real move, or a GPS failure, recovers instead of
  halting the turtle.
- Extras: binary-heap A* open list, one GPS read per block.
