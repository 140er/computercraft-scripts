Read this first; explore only what it doesn't cover. Update it in the same PR when you change a module's public API.

# Server-only map

This maps the code on `origin/server-only`. One server computer owns durable
state and needs at least 16000000 bytes of disk. Workers and displays are thin,
paired clients. Workers must fit a 1 MB disk. Durations use the server's `SO.now()` in game
milliseconds. Worker and display each have a tiny `now()` helper over
`os.clock()`. UTC remains the date and protocol freshness clock.

`SO.now()` comes from `so-store.clock()`. The first boot seeds its timeline
from UTC, so existing saved deadlines and ages keep their meaning. It then
advances by 50 ms per computer tick, independently of daylight changes.
`so-data/clock` stores a `ticks-v1` upper reservation before time within it is
returned. Each server start resumes at that reservation and can consume up to one game
second. Time while the server computer is off does not advance this clock.
Keep its generations with the rest of `so-data`; never restore jobs without
their clock. A failed clock save refuses to issue more time.

Lease deadlines, saved retries, planting waits, machine ages, LRU order,
beacons, discovery, frame throttles and uptime use this timeline. Event `at`,
Amsterdam dates, daily date boundaries, envelope timestamps and replay/cache
windows remain UTC. Events also carry `gameAt` for elapsed alert and recent-ore
windows. The initial UTC seed lets legacy event and saved timer values enter
the timeline without changing poses, reservations or recovery records.
Lease wire bodies carry remaining game milliseconds in `ttl`, plus a UTC
`expires` for old workers. Updated workers anchor `ttl` when it arrives and
never extend a deadline for the same lease. A missing `ttl` uses the legacy
UTC remainder. Mixed versions are supported at 20 TPS. Accelerated checks
require updated server, workers and displays.
The [[server-only/PROTOCOL]] ([protocol](server-only/PROTOCOL.md)) owns wire formats
and API details. Return to [[index]] ([start page](index.md)) for the wave plan.

## Files and public calls

Signatures use each returned library or `SO.mods.<name>`. Programs export no API.
Handlers use `handler(msg, reply)`, ticks use `tick(now)`,
and listeners use `listener(sender, message)`.

### Core and shared libraries

- [so-server.lua](../so-server.lua) boots the server, loads modules, authenticates
  dispatch and runs the event loop. Built-in handlers are
  `pair2(msg, reply)`, legacy `pair(msg, reply)` and `hello(msg, reply)`.
  At start it calls `proto.since` with the current UTC time. `SO.pairCode(id)` returns
  `{ code, expires }` only for a paired requester. It reuses that requester's
  pending invitation and returns nil while another requester or the terminal
  owns one. New invitations use `pair.invite` and also appear on the terminal.
- [so-proto.lua](../so-proto.lua) builds and checks authenticated envelopes.
  Calls are `encode(value)`, `decode(value)`, `build(key, t, body, rid)`,
  `sign(key, msg)`, `macOk(key, msg)`, `fresh(msg)`, `bind(keyFor)`,
  `request(target, t, body, timeout, tries, key?)`, `canonical(msg)`, `ser(value)`,
  `sha256(msg)`, `hmac(key, msg)`, `hex(raw)`, `unhex(hex)`, `since(utc)` and `prune()`.
  After `since`, `fresh` refuses envelopes stamped before that time. `prune` drops
  expired rids and empty senders; the server calls it every tick.
  `request` waits, so never call it from the server's handlers or ticks.
- [so-pair.lua](../so-pair.lua) pairs machines with CPace over X25519 and saves their keys.
  Calls are `open(proto, store, now?)`, `derive(code, serverId, clientId)`,
  `pending()`, `clear()`, `key(id)`, `peer()`, `remember(id, key)`,
  `session(clientPubHex)`, `invite(screen)`, `join(code, serverId)`,
  `repairHint(sender, payload, serverId)`, `envelopeKey()`, `start(from, body)`,
  `confirm(from, body)`, `blocked(id)`, `charge(id, kind, paired)`, `rejected()` and
  `machineKey(secret)`.
  `start` and `confirm` are the server's two `pair2` steps; `confirm` returns the
  machine key and reply body, or nil, a reason and, for `tag`, whether the sender
  proved its saved key. `charge` is the one budget entry for every pairing handler.
  Kind `start` returns false when the sender or all senders are over budget.
  Kinds `reject` and `guess` return true and then true when they burned the code.
  `machineKey` turns a pairing secret into the stored 64-hex key with HKDF-SHA512.
  `join` sends only `pair2`.
  `derive` and `session` serve legacy `pair` for one release. `cpace` holds the
  SHA-512, Elligator2 and CPace helpers that tests check against the draft vectors. The hint check only authorizes a prompt;
  it never removes a saved key.
  `open` accepts the role's millisecond clock; omission uses local tick uptime.
  `join` is a client boot call that waits. Omitting `serverId` uses discovery.
  `peer()` returns the lowest saved numeric peer id, or nil. Workers use it
  as their server id when discovery fails.
- [so-store.lua](../so-store.lua) owns generation-based persistence.
  Calls are `copy(value)`, `read(path)`, `clock()` and `store(path, valid, limit)`.
  `clock()` returns the server's durable game-millisecond function.
  `store` returns `{ value, bytes, save = function(value) }`; `bytes` is the size
  of the recovered generation and updates after a successful save. `save` returns success
  and an optional error. `read` reads a plain Lua table without generation recovery.
- [so-log.lua](../so-log.lua) stores bounded event segments and snapshots for state.
  `open(store)` returns `{ snap, events(), fits(ev), append(ev), due(pressure?),
  checkpoint(payload), rawBytes(), status() }`.
  `status()` returns event availability, sequence, segment count, bytes, snapshot
  number, its saved game time and whether a checkpoint is due.
- [so-errors.lua](../so-errors.lua) opens with `open(store, now)` and returns
  `record(text)`, `flush(now?)`, `entries()` and `status()`. It retains at most
  128 errors in `so-data/errors`, with 2048 bytes per message. Each generation
  is at most 21000 bytes, so current, backup and temporary files fit within
  65536 bytes together. `status().bytes` counts every generation and is
  included in the disk ledger under `other`. Saves run at most once per 30000
  game milliseconds. A failed save keeps the pending records for retry.
  `SO.error(text)` prints and records server errors. `SO.errors` exposes this
  log. `SO.health` holds startup time and the last tick's game cadence, wall
  cadence and cost. Wall cadence is diagnostic only.
- [so-plan.lua](../so-plan.lua) provides pure geometry and batch helpers.
  Calls are `frame(worldPose, journalPose)`, `toWorld(frame, pose)`,
  `toJournal(frame, pose)`, `ahead(pose, dir)`, `apply(pose, op)`,
  `replay(startPose, steps, results)`, `path(from, to, opts)`, `chunk(steps, n)`,
  `inRange(lease, id, cells)`, `rangeBatch(lease, id, action)`, `fuelValue(name)`, `free(inv)`,
  `chestPresent(result)`, `transferFailure(kind, result)`, `chestError(kind, reason, point)`,
  `chestCheck(points, kind, near)` and `missing(checks)`.
  `chestCheck` returns `{ok,text}` without writes. `missing` returns unmet text in order.
  `rangeBatch` returns the longest prefix within range of complete `action.actions`,
  rebuilding its steps, cells and final pose. It returns the original action when
  all cells fit, or nil when no complete action fits. Atomic actions stay whole.
  `park` is a ten-minute `inspectDown` lease template. Renew it with less than
  one minute remaining. Paths assume success; callers reserve cells and split
  work into batches of at most 16. See [plan helpers](server-only/PROTOCOL.md#plan-helpers).

- [so-mine-plan.lua](../so-mine-plan.lua) builds mining routes and next-step actions.
  Calls are `key(p)`, `same(a, b)`, `ore(d, ores)`, `junk(d)`, `distance(a, b)`,
  `cell(p, dir)`, `turn(p, want)`, `route(job, branch)`, `sealable(item)`,
  `cleanup(inv, all, side?)`, `travel(from, goal, point, job?, row?)`,
  `supplyRoute(job, row, stand, point?, lookup?)`, `supplyDistance(job, row, stand?, lookup?)`,
  `next(job, row, lookup, inv, fuel)`,
  `lane(job, exit)`, `inLane(job, pos)` and `lanePass(job, row)`.
  `lane` lists the shared shaft column and bottom spine through the furthest
  assigned junction, plus an optional exit. `inLane` tests that geometry;
  `lanePass` lists the cells crossed in the planned pass through its exit.
  `supplyRoute` returns the departure cell and every movement cell through the branch,
  spine and shaft to the stand. A supplied lookup returns false for known dug cells
  and connects a side vein to the last reached route waypoint, searching at most 512 cells.
  No connection returns nil. Its second result is that access path. A supplied
  `row.access` reuses the path without another search.
  `supplyDistance` counts those moves and returns infinity when no route exists.
  Contextual `travel` returns the remaining outbound or reverse trip cells.
  `ores` is the supported ore-name set. The optional `ore` filter uses those names.
  `next` batches known straight travel and turns, ending at inspect or dig report
  boundaries. Multi-action results include `actions` with one-based `first` step indices.
- [so-lumber-plan.lua](../so-lumber-plan.lua) classifies trees and plans scans and chest access.
  Calls are `isLog(block)`, `isLeaves(block)`, `isSapling(name)`, `saplingFor(name)`,
  `canDig(block)`, `scan(area, ground, dim)`, `access(point, near, blocked)`,
  `travel(from, target, ground)`, `nextCell(from, target, ground, blocked)` and `distance(a, b)`.
  `nextCell` searches at most 2048 cells and returns the first movement cell around
  other workers and their reservations, or nil when no route was found. `travel` returns the next
  service waypoint, with horizontal travel at ground plus two. `access` takes the chest's own coordinates. For `front`,
  it chooses the nearest unblocked horizontal neighbour by Manhattan distance
  and faces the chest. Ties use north, east, south, west order. For `down`,
  it uses the cell directly above the chest. It returns nil if all candidates
  are blocked. The lumber caller supplies the known-obstacle checks.

- [so-ui.lua](../so-ui.lua) is the server-only Big Tiles kit. Calls are
  `clock(epochMs)`, `size(w, h)`, `grid(w, h, columns?)`, `ink(bg)`, `glyph(ch, ink, bg)`,
  `canvas(w, h, bg?)`, `status(model, w, h)` and `alert(model, w, h)`.
  `branchProgress(job, row)` returns clamped branch distance and length in constant time.
  Incomplete poses return nil distance; screens show unknown progress as `-`.
  `progress(canvas, x, y, width, done, total, color?)` draws a one-row bar.
  `pocketHeader(canvas, title)` draws MORE and MAP beside the title.
  `turtle.render(w, h, selection, row, now)` returns a pure detail or pose-editor frame;
  `turtle.pose(pose)` formats coordinates and facing, or `-` for an incomplete pose.
  `turtle.draft(pose)` fills missing editor coordinates and facing with zero.
  Detail BACK uses the bottom-row coordinates without rendering the editor first.
  `clock` returns Amsterdam `{ h, m, s, date, hm, hms }` from UTC milliseconds,
  with EU summer time between the last Sundays of March and October at 01:00 UTC.
  Status, stock samples, panel headers and new terminal log lines use this clock.
  Durations keep their elapsed-time formats.
  `palette` and `font` expose the spec tables. Grid returns one-based `{ x, w }`
  columns and a tile-row count. Glyph returns three blit rows with inverted cells.
  Tiles accept an optional final height after the background. Six rows omit the sub-line; seven rows retain it. Titles and values have one cell of inner padding.
  Canvas methods are `put`, `fill`, `center`, `big`, `hit`, `header`, `alert`,
  `tile`, `button`, `listRow`, `search` and `frame`. Coordinates are one-based.
  `frame()` returns compact rows, rectangular buttons and the palette.
  See [display](server-only/PROTOCOL.md#display) for the status model.

### Server modules

Mining and lumber expose `turtleView()`, a read-only table keyed by worker ID.
Rows carry `role`, `pose`, `anchor`, `state`, `fuel`, `inv`, `done`, `total`,
`step` and `error`; mining also includes `branch`, `ore` and optional `retry`.
The step is the pending batch action; workers report only completed batches.
Mining progress projects the reported world pose onto the branch axis and clamps
it to the configured length. Lumber progress counts planted spots against known
spots. These adapters copy state without changing job scheduling.

All modules return `{ name, handlers, tick, ... }`. Call another module only
from a handler or tick through `SO.mods.<name>`, after checking that the function
exists. Do not call other modules while files load or from listeners.
See [module APIs](server-only/PROTOCOL.md#module-apis).

- [so-mod-state.lua](../so-mod-state.lua), `state`, folds events into registry,
  jobs and views. Calls are `emit(kind, data)`, `get(path)`, `job(data)`,
  `view()`, `view(name, buildFn)`, `view.get(q)`, `view.sub(q)`, `canStart()`, `disk()`, `canWork()`,
  `history.page(q)`, `diagnostics()` and `tick(now)`. `view` is a callable table.
  `view.sub` returns a subscription with `stop()`. Query fields are `name`
  and `notify` for views, and `from`, `count` or `limit` for history.
  `reverse=true` reads newest first with an exclusive `before` cursor. `kind`
  filters exact kinds and `alerts=true` filters `.alert` events. Cursor lookup
  uses binary search. `diagnostics()` returns the event log status.
  `canStart()` reads current disk use. Mining and lumber `start` refuse at 80%
  or more and show `disk >=80%; free space`. Existing work, recovery and stop
  remain available. Authenticated `hello` registers turtles and displays through
  `machine` events, on first contact, role or journal changes, fuel changes of
  at least 100 or crossing zero, and after 60 seconds. Built-in views are `fleet`, `turtle/<id>`,
  `log` and `status`. `disk()` adds byte counts by store, pressure at 85%,
  pending event count and write errors. Failed event writes queue at most 256
  events and 262144 bytes in memory. `canWork()` refuses new movement leases
  until retry drains that queue. Overflow prints an explicit refusal. Pressure
  keeps unchanged heartbeats in memory and reduces event-count checkpoints.
  Optional `so-server.cfg` `state.coalesceHeartbeats=true` keeps routine hello
  freshness and small fuel changes in memory at all disk pressures. It defaults
  to false. Real role, journal, fingerprint and significant fuel changes still
  emit events. Snapshots include freshness; restored machines get boot-time grace.
  View revisions can advance without an event sequence change in this mode.
  See [state](server-only/PROTOCOL.md#state).
- [so-mod-daily.lua](../so-mod-daily.lua), `daily`, counts retained `mine.ore`
  and `lumber.logs` events from one history page of at most 50 entries per tick.
  `today()` returns a copy of `{ date, ore, oreByName, oreRecent, logs }`.
  Days use Amsterdam midnight and `oreRecent` covers `(SO.now() - 600000, SO.now()]` using event `gameAt`.
  Counts and the last consumed sequence save together once a minute and on
  day changes. Restart replays events after that cursor. No wire handlers.
  See [daily](server-only/PROTOCOL.md#daily).
- [so-mod-lease.lua](../so-mod-lease.lua), `lease`, dispatches worker batches
  without waiting. Calls are `send(id, steps, opts)`, `onReport(owner, fn)`,
  `status(id)`, `peek(id)`, `cancelPark(id, "mine")`, `inRange(id, pos)` and `tick(now)`.
  `opts` accepts `ms`, `owner`, `recover` and expected world `pose`.
  Reports call `fn(leaseId, turtleId, results, lease)`; expiry passes nil results.
  Unreported single-step `inspectDown` parks retry every game second with the
  same lease ID, a fresh envelope and the remaining duration. Reports stop retries.
  Handlers are `step.report`, `beacon`, `hello` and `history.page`.
  Range starts at 16 and only grows with known world poses or successful reports.
  Work may extend eight blocks beyond that proof.
  Reports release lease-owned cells; silence leaves reservations in place.
  `peek(id)` returns a copied status for an existing row or nil, without creating
  workers. AR and map use it. `inRange` also reads without creating rows and uses
  range 16 for an unknown worker. `status(id)` retains its row-creation behavior.
  `status(id).uncertain` marks an unresolved worker pose; `send` then refuses
  all leases with `pose uncertain`, including recovery parks.
  `dugProtection(protect)` supplies bounds for open leases. It refuses retirement
  when a lease has no world pose or a worker has an uncertain pose.
  `reanchor(id, worldPose)` sends an authenticated `worker.anchor` for an uncertain
  journal and retries until a matching hello confirms it. Mining/lumber `add`
  use it to replace an uncertain worker assignment with the operator-supplied pose.
  `world(id, dim)` returns a fresh GPS pose and a proven facing when known.
  `locate(id, dim, done)` resolves add-here asynchronously, probing one forward
  step plus `gps` when needed. `candidates()` lists unassigned paired workers.
  `claimProbe(id, owner, pose)` saves the destination reservation before add.
  `clearProbe(id)` releases other probe cells only after assignment saves.
  GPS fixes must carry the worker's explicit `so-worker.cfg` dimension.
  See [lease](server-only/PROTOCOL.md#lease).
- [so-mod-cells.lua](../so-mod-cells.lua), `cells`, owns reservations and dug marks.
  Calls are `handoff(from, to, x, y, z, dim)`, `reserve(who, x, y, z, dim)`, `reserveMany(who, cells)`,
  `release(who, x, y, z, dim)`, `releaseOwner(who)`, `forgetOwner(who)`,
  `owner(x, y, z, dim)`, `isFree(x, y, z, dim)`, `markDug(x, y, z, dim)`,
  `isDug(x, y, z, dim)`, `forget(x, y, z, dim)`, `counts()`,
  `list(who, max)` and `tick(now)`. `list` returns up to `max` copied
  `{ dim, x, y, z }` reservations, default 256.
  The optional dimension defaults to `minecraft:overworld`.
  Handler `cells.forget` requires a second, confirmed request.
  Sections save a 1024-character hex bitset, with a 2048-byte generation limit.
  Legacy tables migrate through two compact generations without losing marks.
  `retirement()` returns a pending request or a brief decision notice.
  `decideRetirement(id, choice)` accepts `allow` or `keep` for that request.
  At 1000000 bytes of section generations, eligible sections prompt every
  display and AR. Only `allow` removes sections, oldest use first, aiming for
  650000 bytes. `keep` persists a new request threshold at 150% of current use.
  At 85% disk use, KEEP asks again after one minute without waiting for growth.
  `rememberWorker(id, worldPose, dug)` retains the last reported world-frame
  journal cells, including after job removal. Its bounded per-worker record and
  consent policy save to `so-data/dug-policy`. Reservations, running job areas,
  leases and recovery paths protect whole sections. Unknown recovery blocks
  retirement. Bulk work uses `SO.breathe`.
  See [cells](server-only/PROTOCOL.md#cells).
- [so-mod-drops.lua](../so-mod-drops.lua), `drops`, owns drop points and inspect
  failure counts. Calls are `pick(kind, nearPos)`, `steps(point)`, `add(point)`,
  `remove(id)`, `fix(id)`, `note(id, blockName)`, `list()`, `roomMark(id, on)`,
  `roomSink(on)` and `tick(now)`.
  `list` copies every `{ id, dim, x, y, z, side, kind, broken, room?, disabled? }` point.
  Optional `room=true` marks ore/wood input points. `roomSink` defaults off;
  pick and readiness exclude marked points until enabled. Both setters save
  before success and roll back on failure. The editor draws ROOM and SINKS
  buttons and accepts `room <id> on|off` and `room sink on|off`.
  `pick` also returns `reason = "none"|"broken"` and `failedPoint` when no point is usable.
  `drops.alert` includes the reason and named point with its coordinates.
  Points use the chest's own coordinates. `front` accesses it from beside it
  at the same height; `down` accesses it from directly above.
  Handler `drops.edit` edits points. Tick registers the generic screen.
  The Big Tiles list selects the first broken point by default, or the first
  point when none are broken. Row taps select FIX and REMOVE targets. ADD NEW
  opens the draft editor. The list links to mining, lumber, shop, AR, panel and build;
  links wrap into two rows below 41 columns and three below 26. BACK
  returns the list to status and the editor to the list. Long lists have paging.
  The kit editor also offers `FROM #N` to copy the chest cell from a fresh,
  proven turtle pose. DOWN selects the block below the turtle.
  Both renderers accept typed coordinates or `add kind x y z [side] [dim]`.
  The kit-free editor fits below two navigation rows and above local input;
  its paging is per display.
  Drop-point dimensions are integers; cell and world-frame dimensions use strings.
  See [drops](server-only/PROTOCOL.md#drops).
- [so-mod-display.lua](../so-mod-display.lua), `display`, assigns roles and sends
  clipped frames. Calls are `screen(role, render, input)`, `screen(role)`, `far(id, on)`, `tick(now)`,
  `terminal(model, view, w, h)` and `monitorTouch(side, x, y)`.
  `terminal` returns a pure frame. The view supplies `id`, `mode` as normal,
  code or log, `uptime`, `log`, `offset`, `code`, `expires` and `now`.
  `monitorTouch` queues local input for the next tick. Local and remote taps
  use the same drawn-button validation for dug-storage consent. Tick discovers a local
  monitor at most every five seconds and draws at scale 0.5 with local navigation,
  without rednet or saved role changes. Tick also draws `SO.terminal` once a second.
  `screen(role)` returns the registered `{ render, input }` callbacks or nil.
  `far` saves a per-computer flag and returns success plus an optional save error.
  `palette` exposes the Big Tiles RGB table at numeric indices 0 through 15.
  `render(w, h, session?)` returns `{ rows, buttons, palette? }`; `input(event)` receives the drawn role,
  coordinates, button id or text, and the same server-local `session`. Handlers are `hello`, `view.sub`, `view.get`
  and `input`. Built-in screens are `generic` and `status`. With the map module, every
  Big Tiles header has a drawn MAP target. `map` and `map-back` navigate on
  paired displays and the local monitor.
  Button id `status` returns any screen to status. Generic screens with their
  own `lumber` and `ar` buttons keep them. The drops list has its own navigation
  (MINING, LUMBER, SHOP, AR, PANEL) and suppresses header injection; older generic screens retain
  the fallback buttons. The draft editor keeps its header clear and returns
  to the list with BACK. Generic screens at least 39 columns wide gain a PANEL
  header button when the panel screen is loaded and they do not already provide one.
  Input includes sender ID `from`. Sessions retain the client ID as `id` and hello `keyboard == true` as `keyboard`.
  Monitor clients send false; older clients omit it and get touch controls.
  Kit-free callbacks receive that ID instead of the session. Their generic
  frames reserve two navigation rows and keep a visible return button.
  Render signatures and revisions are isolated by role, size and session. Status also
  isolates paging and alert takeover state per display session. Panel frames also
  isolate revisions per session. With the kit, a roleless 26x20 display defaults to status. Its
  glance row pages two tiles at a time with `prev` and `next`; `panel` selects
  panel mode. MORE opens generic from glance, status and panel. Explicit saved roles,
  including generic, take precedence and survive restart. The 15x10 status page
  has separate NEXT and MORE buttons. Gather runs in
  handlers or ticks and reads state, leases, drops, sessions and server disk use.
  Ore and log totals come from `daily.today()`; a missing module uses stale tiles.
  A missing kit retains
  the legacy status renderer for older partial installations.
  Mining/lumber rows and map arrows carry `turtle:<id>` targets. A selected turtle
  opens a session-local detail overlay; BACK restores the source page and map view.
  Tick gathers module `turtleView()` snapshots, registry last-seen and lease status;
  rendering reads that cache. Detail actions validate their drawn coordinates.
  PARK ALL sends mining's `stop`; lumber PARK sends `park <id>` for the selected
  worker, leaving the other workers running.
  Mining REMOVE sends `remove <id>` after two taps within five seconds. Lumber has
  no remove command. Uncertain workers show POSE ? and a coordinate editor; RE-ADD
  requires two taps after editing and forwards the existing `add` command.
- [so-mod-map.lua](../so-mod-map.lua), `map`, registers the top-down screen
  from `tick(now)`. No wire handlers. Tick gathers `mine.mapView()`,
  `lumber.mapView()`, registry workers, lease range/state and drop points.
  `render(w, h, session)` keeps fit, centre, blocks per cell, level and a bounded
  dug-cell scan in `session.map`. Rendering uses at most 256 `cells.isDug`
  calls, limited to known tunnel, surface, farm, chest and turtle levels.
  Scan caches replace on complete passes and reset on view changes.
  Mine geometry uses screen-cell intersections, independent of route length.
  MAP appears at the right of each Big Tiles header when this module is loaded.
  Map and navigation read the kit header row, including the padded row 2.
  BACK restores `session.mapReturn`, or status after restart. Local monitor
  navigation uses its own session. No client or saved-file format changes.
  See [map](server-only/PROTOCOL.md#map).
- [so-mod-health.lua](../so-mod-health.lua), `health`, registers `health`,
  `attention`, `alerts`, `events` and `errors`. `count()` returns the attention
  count. Fuel failures link to mining SETUP. Lumber shows its saved alert
  cause before its blocked state. `attention(facts)` returns severity-sorted rows
  with `key`, `text`, `target` and optional input `actions`. Gathered facts are
  `now`, `disk`, `points`, `jobs`, `machines`, `leases`, `retirement`, `pairing`
  and optional `requests` and `fuelAlerts`. The module gathers once per five game seconds.
  Jobs and paired IDs come from read-only generation recovery. An optional
  `SO.pair.requests()` supplies pairing requests; an open invitation also
  appears. Other job modules may add read-only status APIs later.
  Display inputs receive `event.open(role, actions?)` for navigation and a
  list of input IDs to send to that screen with the same display session.
  These callbacks stay on the server and do not enter wire frames.
- [so-mod-panel.lua](../so-mod-panel.lua), `panel`, registers the panel screen from
  `tick(now)`. No wire handlers or other exported calls. The screen keeps search,
  main/alerts/pair pages and alert paging in each display session. MORE in its
  header opens the generic drop-point list. Tick gathers
  registered screen callbacks and job header states, plus state `.alert` values.
  The status PAIR button opens the panel pair page directly. Unavailable NEW CODE
  controls are grey and have no action target. Main-page inputs forward START
  and STOP once to the mining or lumber screen.
  Keyboard-equipped panels call `shop.order(search, count)` once. Shop's count/name sort defines
  the best match; ordering leaves shop display state unchanged. Missing screens
  have grey blocks without action targets.
  Monitor panels replace quick search and quantities with a SHOP button.
  GLANCE returns to status; ALERTS lists state alerts; PAIR offers NEW CODE.
  Authenticated display input calls `SO.pairCode(from)` and keeps its result in
  that session. Big digits and remaining time clear on use, expiry or burn.
  Code frames use the display's own key; other displays never receive them.
  Larger screens arrange the same controls using the kit grid. No saved panel file.
  See [panel](server-only/PROTOCOL.md#panel).
  Dug-storage requests appear above every role, including status and generic.
  The server accepts consent only for a current, fully visible button at its
  drawn coordinates. Decision notices last 30 seconds.
- [so-mod-shop.lua](../so-mod-shop.lua), `shop`, adapts the legacy Storage Room
  turtle to the shop screen. Calls are `tick(now)`, `order(search, count)`,
  `fuelConfig(auto?, outputId?)`, `fuelEmpty(point)`, `fuelAvailable(point, orderRid?)` and
  `fuelAlerts()`. Fuel auto-order defaults off in `so-data/fuel-policy`.
  Bind the room output as a fuel point in mining SETUP. Empty reports share a
  saved ten-minute cooldown per physical chest across mining/lumber and restarts.
  Exact charcoal or coal orders require 64 fresh stock. Save precedes send.
  At most one fuel order is outstanding, across cooldowns, flag/output changes
  and restarts. A confirmed refusal, delivery or observed usable fuel ends the
  saved wait. Pickup actions save the expected order id, so old inventory reports
  cannot complete a later order. Unknown replies and timeouts cannot authorize a second order.
  Saved waiting orders raise delivery-unconfirmed attention after two minutes.
  Failure causes appear in `shop.alert` and `fuelAlerts`; usable pickup clears
  them. Lumber saves pickup slots, retains non-fuel items while searching, and
  returns only those items before refueling. Missing fuel and failed returns
  retain their minute retry and recover through the saved service record.
  `order` sends one order for the match with the highest stock, breaking ties
  by name. Counts are 1, 16 or 64. Missing matches or storage send nothing.
  No `so` handlers. Listeners are `roomsorter`, `roomsorter_stock` and `dns`.
  Tick registers the shop screen, discovers storage and polls stock.
  Render callbacks use `render(w, h, session)`. The Big Tiles list opens an item with
  `item:<name>`; its order page uses `order:<count>:<name>` and `items` to return.
  List controls are `category:<name>`, `letters`, `letter:<A-Z|ALL>`,
  `sort:count`, `sort:name`, `prev`, `next` and `status` for BACK.
  Small screens use `categories` to open a category picker. No shop search field
  is drawn. The kit-free renderer retains its item list and direct order buttons.
  Browse state and order feedback belong to each display. Orders send once and
  disable quantities until another item selection. Sent does not imply delivery.
  Stock goes stale after 30 seconds; five minutes without stock resumes discovery.
  The legacy room has no server-only pairing or selector setting.
  See the [shop exception](server-only/PROTOCOL.md#shop).

- [so-mod-build.lua](../so-mod-build.lua), `build`, builds opt-in blueprints on one
  paired turtle. Public calls are `expand(blueprint)`, `import(text)`, `tick()` and
  `dugProtection(protect)`. Blueprints have inclusive `x1,y1,z1,x2,y2,z2`, `shape`
  and optional `dim`. `expand` returns bottom-up cells or `nil, error`; `import`
  accepts main builder floor/platform and wall/walls text. Jobs save to
  `so-data/build/job`. Tick registers `display.screen("build", render, input)` and
  `lease.onReport("build", report)`. Owner tags are `build:<id>`. Travel and target
  cells use reservations, range prefixes and the mining lane geometry. Builder
  never digs. Material comes from a storage drop point. Empty stock retries every
  ten seconds on `SO.now`. Builder requires the worker `parkBatch` capability and
  marks every lease for stationary expiry, including after a worker reboot.
  Recovery reads worker pose and inspects the current
  target before another placement. MORE links to BUILD. See [builder jobs](server-only/BUILD.md).

- [so-mod-mine.lua](../so-mod-mine.lua), `mine`, runs branch mining and ore recovery.
  `assigned(id)` reports whether its job owns that worker.
  Calls are `tick(now)`, `dugProtection(protect)`, `forgetDug(sectionPaths)` and `mapView()`;
  no wire handlers. Protection covers the running mine and saved worker routes.
  `forgetDug` clears block lookup entries for a set of retired section paths.
  Tick registers `display.screen("mining", render, input)` and
  `lease.onReport("mine", report)`. Cell owner tags are `mine:<id>`.
  Mining uses Big Tiles with START, STOP, SETUP and BACK. SETUP has a local
  BACK button; the page belongs to the display session. Kit-free callers share
  the default page. Typed commands work on both pages. Daily ore totals and the top
  two ore names come from `daily.today()`, with a stale tile when missing.
  Missing kits retain the legacy renderer.
  Screen callbacks are `render(w, h, session)` and `input(event)`; reports use
  `report(leaseId, turtleId, results, lease)`. Jobs save to `so-data/mine/job`.
  `mapView()` returns copied geometry fields, worker poses/states, a cached
  two-endpoint next-branch `preview` and `trails` for AR. Trails contain two
  endpoints and state per worker, plus at most 64 recently completed branches.
  Completion trails clear when START resumes a stopped job or the server restarts.
  These are display additions and do not change worker routes.
  `start` requires home, usable ore and fuel points, an added paired worker and
  reported fuel. SETUP shows compact state-coloured readiness rows.
  Saved homes remain configured. `branches <n>` enables continuous mining with a
  job budget of 1..4096 branches, default eight. `continuous` defaults off.
  A returning worker saves its next claim as `{branch,junction}` before retreating
  through the shared lane. Branch claims and counted completions survive restart. Ore
  filters default to all ores. `ores` accepts spaces around commas. `remove` can retire a stationary recovery or park
  lease through `lease.cancelPark`, releasing the lane and reservations. Stale
  lane waiters lose their place when they leave the queue. Completed routes
  unload remaining ore through the configured drop before parking. Junk cleanup
  uses guarded `discard` into adjacent empty cells, preferring known open tunnel
  cells. Failed targets are skipped until movement. Ore unloads exclude junk.
  A lane pass reserves its full route through the shaft and spine plus its exit in one
  call. Intermediate batches retain the reservation until the worker leaves.
  Mining and supply batches stop at the furthest complete action within proven
  range plus eight blocks. Only the sent prefix enters `inflight`; the next
  report extends the proof before the remaining route is planned.
  Saved rows include `lane = { cells, entered, target?, release? }` while holding the lane
  and `laneWait = { at, passes }` while queued. Exit cleanup runs from tick;
  rapid report bursts defer further planning to tick. Oldest waiters go first, then
  lowest id; a waiter with three intervening grants has priority. Waiting rows
  show `wait lane`. Side veins wait until the worker leaves the shared lane.
  A range-blocked or held worker retreats through known free cells to leave the
  lane, then releases its pass and queue entry while retaining its occupied cell.
  Saved `yield = { path, cursor, stage, state, error, action?, pass, after, retryAfter? }`
  resumes the old pose and facing before normal work once the range check passes
  or the hold retry is due, with fuel for the return. Retreat reserves fuel for
  both directions and searches at most 512 known cells, without digging. Failed
  escape moves invalidate their target and try another known exit; failed returns
  retreat again and wait a minute before another return attempt.
  Without a safe retreat, the worker releases the pass and keeps its physical
  cell protected. Other passes can use the remaining lane when their cells do
  not intersect that occupied cell. A turtle that cannot physically move can
  still obstruct its cell.
  Saved turtle rows may contain `dropRetry = { key, tries, alerted, after }`.
  Fuel trips aim for 2000. If the chest empties sooner, the worker returns once
  its fuel covers the saved return route, the paused position's route home, and 64 more moves.
  Supply trips save `path` and `reserve` in the trip record. They use the lane queue
  and reserve the shared corridor, surface approach and branch exit through the
  chest turnaround and return. Private branch cells use normal movement batches.
  Route searches read only the in-memory block lookup. With no remembered route
  (restart, underground re-add), a worker below the surface uses the direct path
  down to the bottom level, to the spine and up the shaft for its reserve and trip.
  An underground re-add joins its route at the nearest cell past the shaft top.
  Rows save `counted`, the branch already added to `progress.done`. Home routes and vein access
  cache by pose, route waypoint and mine geometry; stationary ticks and chest
  candidates reuse them. Fuel reports use the saved trip path and reserve.
  Trips using the shared corridor defer report planning to tick. Moves outside the lane release one private
  cell per report for trips using the shared corridor, keeping reservation cleanup
  below the cells burst threshold. Trips wholly on the surface retain normal batching.
  Three failures at one drop emit `mine.alert { id, text }`, show the error,
  and park with one retry per minute. Missing drops use the same delay.
  See [[server-only/PROTOCOL#mine]] ([mining](server-only/PROTOCOL.md#mine)).
- [so-mod-lumber.lua](../so-mod-lumber.lua), `lumber`, scans, harvests and replants trees.
  `assigned(id)` reports whether its job owns that worker.
  `turtleView()` returns a copied detail row per worker, including its pose, fuel,
  inventory, state and step, plus shared farm progress.
  Calls are `tick(now)` and `dugProtection(protect)`; no wire handlers.
  Protection covers the running farm at every height, saved service routes and
  worker recovery. Mining and lumber pass world-frame journal cells to cells.
  Tick registers `display.screen("lumber", render, input)` and
  `lease.onReport("lumber", report)`. Cell owner tags are `lumber:<id>`.
  Screen callbacks are `render(w, h)` and `input(event)`; reports use
  `report(leaseId, turtleId, results, lease)`. Jobs save to `so-data/lumber/job`.
  `mapView()` returns copied dimension, area, ground, sapling chest and a
  `turtles` map of `{ id, pose, state }` rows for the map. Saved jobs use
  `turtles[id]` for each worker's journal frame, pose, phase, inventory and trip.
  Old single-worker jobs migrate when loaded. Shared scan claims reserve target
  cells until felling and replanting finish. FIFO tickets serialize chest access.
  Workers retain the access column until their return leaves it. Lost workers
  keep their uncertain cells while the others continue.
  The Big Tiles screen gathers job state into a pure layout. START and STOP use
  the text command path. Every turtle appears with its phase and fuel. Three
  fit 26x20 and 29x12; NEXT pages longer lists. Drawn worker rows open detail
  pages. `park <id>` saves a per-worker pause; `start` resumes paused workers.
  SETUP pages configuration; its BACK returns
  to lumber. Main BACK uses `status`. Missing grow timers use a stale tile.
  Logs are Amsterdam daily delivered totals from `daily.today()`, with a stale
  tile when missing. Calls without a size retain
  the legacy rows for older callers.
  Restart recovery sends a stationary park using the saved frame without a
  volatile lease pose or range proof. Its report rebuilds the world pose before
  work resumes. Work leases still require the range and reservation checks.
  Three failed moves or digs hold and emit `lumber.alert`. Holds show that
  `start` is required after fixing the cause. Fuel trips reserve the route
  distance plus 32 fuel. Wood service removes junk and excess saplings while
  preserving one per known spot of each species and the current tree.
  Wood inspections save a delivery intent before the transfer lease. Reports
  credit the inventory decrease. Recovery reconciles a lost report against that
  intent. `lumber.logs` carries total and per-worker receipt sequences to prevent
  duplicate events after a crash between the event and job saves.
  Wood and supply inspections call `drops.note`. Sapling service reuses a matching
  drop point or registers a stable `storage` point for the drop editor.
  See [[server-only/PROTOCOL#lumber]] ([lumber](server-only/PROTOCOL.md#lumber)).

- [so-mod-ar.lua](../so-mod-ar.lua), `ar`, draws server data on attached cc_ar
  controllers. Only `tick(now)` is exported beyond module metadata. No wire handlers.
  Tick registers `display.screen("ar", render, input)` with `turtles`, `leases`,
  `drops` and `alerts` toggles. The screen shows controller count, on/off tiles
  and BACK to status. Small screens use compact tiles. Switches save through
  `so-store` to `so-data/ar`.
  Discovery runs at most every five seconds; changed scenes redraw at most once
  per second. Failed controllers are dropped until discovery. Known server
  dimensions filter world elements. Alerts expire after five minutes, renewed
  by new events. First controller attachment clears old elements when supported.
  World labels use size 0.5 and short text, with nearby labels stacked. Only
  the nearest 16 turtle labels and eight drop labels per kind are drawn, using
  the server position. Boxes and arrows remain. The HUD counts all registered
  workers like status, including paired idle workers; its bar marks lost leases.
  The HUD starts at GUI `(4,72)`. A five-second alert strip is its first row,
  and retirement notices sit below the tiles. Rectangle arguments are opposite corners.
  Dug-storage requests remain visible until a player decides, including with
  the optional event-alert layer off. Decision notices last 30 seconds.
  See [AR](server-only/PROTOCOL.md#ar).

### Thin clients

- [worker.lua](../worker.lua) executes `lease.batch`, sends `hello`, `step.report`
  and `beacon`, journals steps, and backs up after work lease expiry. No exported API.
  A single `inspectDown`, or `park=true` on the first batch step, marks a
  stationary park. Workers advertise `capabilities.parkBatch=true` in hello and
  reports. Builder requires that capability. When the batch expires, the worker
  stays put and beacons every 30 seconds, retaining its move history.
  Paired boots retry discovery and hello with backoff capped at 30 seconds,
  using the saved server id if discovery fails. They show `waiting for server`
  until an authenticated reply arrives. A `pair.required` hint also offers a code
  prompt while retaining the saved key until a new pairing succeeds. Otherwise
  only unpaired boots prompt for a code. That prompt keeps retrying discovery
  while accepting digits and Enter. Idle workers send hello every 30 seconds
  without authenticated replies to detect a later server key reset.
  GPS lookups keep accepting authenticated server messages. An anchor received
  during a lookup confirms without starting a nested lookup.
  Drop and suck operations on every side require an adjacent inventory. Missing
  inventories return `no inventory` and leave items in the turtle.
  At boot, pending moves use saved fuel or GPS to resolve their outcome. Turns
  or missing evidence stay uncertain. The worker reports that fact, keeps the
  pending entry, and refuses further steps without moving or backtracking.
  An operator re-adds it with its actual pose to clear uncertainty. The worker
  saves that anchor and clears old move/dug history before confirming it.
  `so-worker.cfg` supplies the explicit GPS dimension as a plain `{ dim = string }`
  table. Missing dimensions disable automatic add and drop coordinates.
  `discard {side="front"|"up"|"down", n?}` checks for an empty cell and refuses
  adjacent inventories. The default side is down.
  It accepts authenticated server batches, not planner decisions. Keep it small
  and add no new turtle files.
- [display.lua](../display.lua) pairs, sends `hello` and `view.sub`, draws
  `view.frame` and sends `input`. No exported API. It handles touch, clicks,
  text and resize events, and retries when its frame becomes stale. Rows accept
  old blit strings or compact `{ text, runs = { { n, fg, bg }, ... } }` data.
  Compact text omits trailing spaces, which the client pads to the run width.
  Frames may carry a 0-based RGB palette and monitor scale 0.5 or 1. Missing
  palettes restore stock colours. A changed scale sends one resized hello.
  Buttons accept optional height `h`, default 1. The client draws the outage
  tile and timers without a server, preserving inverted digit cells.
  Pairing prompts and digits appear on the display and
  its computer terminal. Failed pairing accepts a new code. A `pair.required`
  hint shows the same prompt without deleting the old key. Authenticated frames
  dismiss the hint and restore the normal screen. Discovery and
  stale-frame hello/subscribe retries use backoff capped at 30 seconds. At boot,
  it prefers the lowest saved paired server ID and retries that ID without DNS.
  It opens every modem and rescans on attach and detach events. Screens
  at least three rows tall reserve the bottom row for typed input and report
  the remaining height in `hello`. The optional `fullH` advertises physical height
  so Big Tiles can use every row, including pocket glance navigation. Kit frames
  use that full height; kit-free frames retain the input row. Wall displays
  also echo input on the terminal.

## Installer roles and files

[install.lua](../install.lua) installs only server-only roles. Its top-level
`ROLES` table is the single source of truth for downloads. Programs export no
new module API. [update.lua](../update.lua) runs `install.lua update`.
See [the operator guide](../README-SERVER-ONLY.md) for setup and commands.

- Every role includes `install.lua`, `update.lua`, `so-proto.lua`, `so-pair.lua`
  and `so-store.lua`. It also includes all of `lib/ccryptolib/`, namely
  `random.lua`, `config.lua`, `chacha20.lua`, `blake3.lua`, `x25519.lua`,
  `internal/packing.lua`, `internal/util.lua`, `internal/hw.lua`,
  `internal/edwards25519.lua`, `internal/curve25519.lua`, `internal/fp.lua`
  and `LICENSE`. `cc.expect` is supplied by CC:Tweaked ROM.
- Worker adds `worker.lua`. Only turtles install this role.
- Display adds `display.lua`. Pockets install this role. Computers can choose it.
- Server adds `so-server.lua`, `so-log.lua`, `so-plan.lua`, `so-mine-plan.lua`,
  `so-lumber-plan.lua`, `so-ui.lua` and every root `so-mod-*.lua`, including `so-mod-ar.lua`, `so-mod-daily.lua` and `so-mod-panel.lua`.
  Current modules are ar, cells, daily, display, drops, lease, lumber, mine, panel, shop and
  state. Only a regular computer with at least 16000000 bytes of capacity can
  install this role.

Updates fetch and execute the new installer first, so its role list applies in
that update. The branch API resolves one commit SHA for every download. If it
fails, the installer tries GitHub's read-only Git refs endpoint, then the saved
`/.so-revision`. Without a valid SHA it stops without changing installed files.
There is no fallback to branch file URLs. Fresh installs use the same process.
An installer from before this bootstrap change still uses its old list and branch
file URLs for its first update. That update installs the bootstrap installer, and later updates
use the new list immediately. Fetching the new installer manually before running
`install update` also skips that transition. An old installer still rejects
whitespace in `/.so-role`; trim it or fetch the new installer first.
`/.so-files` records the installed role files. Updates remove files retired from
that list or the running installer's list, plus unlisted root `so-mod-*.lua` files.
Those deletions share the backup manifest and roll back with the replacements.
`/.so-revision` and `/.so-files` also participate in the swap.

`/.so-role` contains the plain role name. Updates trim surrounding whitespace. `startup.lua` runs installer recovery,
then the role program. A fresh server install writes `so-server.cfg` as the
plain table `{ pos = { dim = string, x = number, y = number, z = number } }`.
The installer uses GPS or integer manual coordinates. X and Z are bounded to
+/-30000000, Y to -2048..2048. The dimension menu accepts only the three vanilla
namespaced IDs or their numeric aliases 0, -1 and 1. Enter chooses the overworld.
The saved dimension is always namespaced. Coordinates and dimension appear before
an Enter confirmation; `n` restarts position entry.
Updates do not replace this config or any runtime state.

All downloads stage in `/.so-new/<path>`. A failed fetch or compile removes
staging without changing installed files. `/.so-old/manifest` records target
paths and whether they existed before the swap. Old copies move under
`/.so-old/` before staged copies move into place. Recovery restores backups and
removes newly introduced targets unless `/.so-new/committed` exists. That marker
means every target was moved and recovery only finishes cleanup. The next
installer invocation and installed startup both recover before continuing.
Before a swap, `/startup/so-install-recover.lua` provides a temporary CraftOS startup
fallback. It can run recovery from the root, backup or staged installer while
`install.lua` or `startup.lua` is between moves. Recovery removes this fallback.
Successful updates promote `/.so-old` to `/.so-prev`, replacing the previous release.
`/.so-new/keep` makes this promotion resumable after a crash. Fresh installs keep no
previous release. The retained manifest includes each replaced or retired file,
startup, role, file list, pinned revision and `/.so-protocol`, currently 1.
`install rollback` stages those exact bytes, removes files introduced by the update,
and uses the same manifest swap. `/.so-new/rollback` makes committed cleanup consume
the previous release instead of retaining the release being undone. An interrupted
rollback recovers to the current release before commit or the previous release after
commit. Rollback never downloads or changes pairing, config, data or journals.
Different protocol metadata refuses rollback; missing metadata means protocol 1.
Client tests measure the peak with one retained release and rollback staging under
1000000 bytes.
`install reset` requires `yes` and deletes writable files on the root drive,
including pairing keys, except `install.lua` and `/rom`. It skips mounts and
read-only paths, reports failed deletions and continues with the remaining files.
SO9 tests check role coverage, dependency closure, client size, download
validation, crash recovery and state preservation.

## One event loop

`so-server.lua` checks disk capacity before loading libraries. It creates `SO`,
loads root `so-mod-*.lua` files in sorted filename order with the server program
environment so they share `SO`, then opens every modem
and attempts to host rednet protocol `so` as `server`, even if no modem is attached
yet. Attach and detach events rescan modems without waiting for discovery.
A hostname collision shows the other host ID on the pairing screen and leaves
the event loop running. Registration is attempted once per boot. Missing or
invalid modules are skipped.

One coroutine waits on an unfiltered `os.pullEvent()`:

1. A `so` rednet event enters dispatch. Decode checks shape, sender and time;
   dispatch checks the MAC, resends cached replies and rejects replays.
2. Built-in `pair` or `hello` runs first, then every matching module handler in
   filename order. The first `reply(t, body)` wins. Unknown types receive `err`.
3. Other rednet protocols go to matching `listen[protocol]` hooks in filename
   order. `listen.so` cannot bypass authenticated dispatch.
4. The P key opens or renews pairing. Esc clears the invite. Used or expired
   invites return to the normal terminal. L opens the full log, L or Esc returns,
   and Up or Down scrolls it. Server prints enter an in-memory log bounded to
   200 lines of at most 4096 bytes each. Long lines split without dropping text.
   Monitor touches queue local input. The one-second timer expires reply-cache
   entries, refreshes pairing state and calls every `tick(now)` in filename order.
   It rearms after the ticks; missed seconds do not produce catch-up ticks.
   If any event arrives more than 3 s (`os.clock`) after the last tick, the
   loop logs, ticks and starts a fresh timer, so a lost timer cannot stop
   planning.

Handlers, listeners and ticks run inside `pcall`; a failure logs and the loop
continues. Never wait inside them. `sleep(0)`, `sleep(n)`, `rednet.lookup`,
`rednet.receive` and filtered `os.pullEvent` calls consume unrelated events
while this single coroutine waits. That can discard reports, beacons, keys or
the tick timer itself (Gate B C7). To yield during a long burst, call
`SO.breathe()`: it queues a marker and re-queues every event it pulls before
the marker, so nothing is lost. Yield only during a real burst of work, never
on the first call. Copy `so-mod-cells.lua`'s `S.pause` pattern, which resets
after an idle gap and breathes only after accumulated work or elapsed burst
time. `tests/so/tick-stall.lua` fails if any `so-mod-*.lua` calls `sleep`.

## Wire names

Every `so` payload goes through `so-proto`. See
[MAC and replay](server-only/PROTOCOL.md#mac-and-replay) for authentication.
The message definitions are linked here rather than repeated:

- [pair](server-only/PROTOCOL.md#pair), [hello](server-only/PROTOCOL.md#hello),
  [ack](server-only/PROTOCOL.md#ack), [err](server-only/PROTOCOL.md#err).
- [lease.batch](server-only/PROTOCOL.md#leasebatch),
  [step.report](server-only/PROTOCOL.md#stepreport), [beacon](server-only/PROTOCOL.md#beacon).
- [view.get](server-only/PROTOCOL.md#viewget), [view.sub](server-only/PROTOCOL.md#viewsub),
  [view.frame](server-only/PROTOCOL.md#viewframe), [input](server-only/PROTOCOL.md#input).
- [drops.edit](server-only/PROTOCOL.md#dropsedit),
  [history.page](server-only/PROTOCOL.md#historypage).
- [cells.forget](server-only/PROTOCOL.md#cells) is defined with the cells API.

The [shop](server-only/PROTOCOL.md#shop) uses plain-rednet protocols `roomsorter`,
`roomsorter_stock` and `dns` as a legacy exception. Its commands are `stock`
and `order`; discovery uses `lookup` and `lookup response` on `dns`.
State's in-process `view.frame` is separate from the wire frame.
The implemented `history.page` delegates to state and uses ascending sequence
cursors `from` and `next`, despite the older timestamp wording in Message types.

## State and disk layout

Save only through `so-store`. It recovers the newest valid generation among
`path`, `path.tmp` and `path.bak`. Saves verify the temporary file before moving
it into place. Budget and free-space rejections change no files. After a disk-write
failure, the next save recovers surviving generations and retries without a reboot.
Do not save inside tight loops.

- `so-keys` holds paired keys on server and clients. Pairing loads
  `lib/ccryptolib/` for X25519 and randomness.
- `so-server.cfg` is the plain server-position table read through `so-store.read`.
- `so-data/clock` holds the durable `ticks-v1` time reservation.
- `so-data/log/<segment>` holds events. `so-data/snap/<snapshot>` and
  `so-data/snap/latest` hold folded state and its snapshot pointer.
  Segments are at most 64 KB, retained segment bytes at most 1 MB, and snapshots
  occur every 2000 events or when retention needs one. After saving `latest`,
  cleanup removes snapshots older than `n-1`, including `.tmp` and `.bak` files.
  Startup repeats cleanup using the recovered pointer. Snapshots `n` and `n-1`
  remain available for loading. New jobs stop at 80% disk use.
- `so-data/cells/res` holds reservations. Dug marks live in
  `so-data/cells/<escaped-dim>/<sx>_<sy>_<sz>` for 16-cube sections.
  The cache holds at most 256 sections; tick saves at most eight dirty sections.
- `so-drops` holds drop points, failure counts and the default-off room-sink flag.
- `so-data/fuel-policy` holds the default-off fuel auto flag, bound output,
  up to 64 saved cooldowns, waiting delivery and its failure alert.
- `so-display` holds `{ roles = { [stringId] = role }, far = { [stringId] = true } }`.
  Roles include `panel` and `map`. Old files without `far` remain valid.
  Far displays use scale 1; others use 0.5.
- `so-data/daily` holds `{ date, cursor, ore, oreByName, logs, recent }`.
  Recent ore uses game-second buckets `{ total, counts = { [gameMs] = count } }`.
  Bucket keys and timestamp keys are decimal strings. Only the server installs it.
  Section files have no aggregate disk bound or automatic pruning. Owner release
  removes reservations only. Marks remain available for recovery across jobs.
- `so-drops` holds drop points and failure counts. `so-display` holds screen roles.
- `so-data/ar` holds the four AR layer switches, enabled by default.
- `so-journal` is the worker's bounded recovery journal. `so-code` supplies a
  boot-time pairing code and is deleted after successful worker pairing.

Lease records, owner callbacks, observed ranges, lost flags and journal facts
are memory-only. Reply/replay caches, display sessions and pictures, state
subscriptions and custom view functions, cell confirmation tokens, and shop
stock, search, order replies and trend samples also clear on restart.
Durable reservations survive. Planners must recover them with park leases
before issuing new work after a server restart.

## Tests and checks

`tests/run.lua` runs the mock suite, including `tests/so/*.lua`.
`tests/so/harness.lua` runs the real worker on fake computers with rednet,
clock events, separate disks, turtles and a shared block world.
Any fake disk that loads `so-pair.lua` must also copy `lib/ccryptolib/`.
The full suite takes roughly three minutes before SO11.

SO11 runs the real server with every module, three paired workers, two paired
screens and an unpaired Storage Room stub for twelve fake minutes. It cuts power
inside an active server call at minute six, preserves the disk, drops messages
for two minutes and boots a fresh server. It records all seven checks and prints
progress, lease and recovery totals before reporting failures. Run it alone with
`lua5.2 tests/so/so11.lua`; it also runs at the end of `lua5.2 tests/run.lua` and
prints its elapsed time. The harness adds `net.kill(machine)` and
`net.boot(machine)`, which returns a fresh machine with the same disk and id.
Optional machine settings enable inventory drops, fluid handling, action time, directory
listing, monitor size and server wait observations. Existing defaults stay the
same. SO11 treats every handler, listener or tick wait as a check 7 failure.
`SO.breathe()` does not count as a wait.
SO11 scenario B uses length-48 mining branches and grown trees, cuts inside a server call at the first observed instant after 240 seconds with three open work leases and a dig in flight, then checks four minutes of recovery after two minutes down, including lane exclusion and exactly-once interrupted dug reports.

Add a suite as `tests/so/<name>.lua` and append this block at the very end of
`tests/run.lua`. Change nothing above it:

```lua
dofile("tests/so/<name>.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
```

Run all four checks before a PR and record each command's last output line:

```sh
lua5.2 tests/run.lua
luac5.2 -p <every .lua file touched>
python3 tools/cobaltlocals.py <every .lua file touched>
sh tools/check-scope.sh origin/server-only-ui HEAD
```

Keep each Lua file under 185 locals, including enclosing functions, for Cobalt's
200-local ceiling. Commit before the scope check so `HEAD` includes the change.
Offline tests do not prove in-game behavior. State which AGENTS.md gates could
not run and which Minecraft or client checks remain unavailable in the PR.

UI-0 adds `tests/ui/ui0.lua` to the full suite. It checks frame compatibility,
serializer size, palette restoration, scale hello, button rectangles, outage
fixtures, retries, font encoding and generator output. `tests/ui/render.lua`
exports `load(path)`, `capture(w, h)` and `diff(fixture, picture)`. Capture returns
a fake terminal with CC drawing methods and `picture()` for text/background
layers. Diff returns up to eight cell differences with row, column, layer,
expected and actual values. Sextants use the spec ink/background rules to undo
inverted cells. `sextant(bits)` converts a six-bit pixel value to Unicode.
`python3 -I docs/ui/mockup-gen.py --fixtures DIR` writes all fifteen fixture
files without changing the normal mockups.md and font.txt output mode.

UI-1 adds `tests/ui/ui1.lua`. It checks glyph pixel round-trips, status fixtures,
alert takeover timing and dismissal, contrast, clipping, XS paging, role buttons,
size-specific revisions, source gathering and server-only kit installation.
`status-T.txt` uses four 12-column tiles and a log, with status navigation on the
bottom three rows. UI-1 pocket parity covers rows 1 through 19; UI-3b covers all 20 rows.


UI-2d adds `tests/ui/ui2d.lua`. It checks unchanged drops-M and ar-M fixtures,
selected drop actions, draft editing, all 64 points through paging, AR switch
persistence, navigation, contrast and bounds at P, L, M, XS and odd sizes.
Screen gather and pure layout helpers are private; public module APIs, saved
files and client role lists are unchanged.

UI-3b adds `tests/ui/ui3b.lua`. It checks unchanged status-P and panel-P fixtures
on all 20 rows, per-pocket paging and search, action forwarding, real shop orders,
monitor layout, session revisions, role persistence, alert paging, pairing help,
missing modules, contrast, bounds and server-only installation.

UI-5a adds `tests/ui/ui5a.lua`. It checks Amsterdam DST and midnight, screen
clocks, daily totals, exact ten-minute expiry, saved-cursor restart, bounded
history work, stale fallbacks and server-only installation. `lumber-M.txt` now
shows a stale daily tile because its fixture setup has no daily module.
`panel-P.txt` shows 22:14 for its existing 21:14 UTC test epoch.


## Open gaps

- Lease state is memory-only. Planner recovery must use park leases and account
  for reservations that survived the restart.
- SO3 mining, SO7 lumber, SO9 installer and SO10 AR are implemented.

## Accelerated Gate B checks

Run complete updated fleets at `/tick rate 80` for four times game speed.
Mining and lumber throughput, lane safety, range, leases, silence grace,
beacons, backtracking, park renewal, retry waits, discovery, stale frames,
alerts and saved-job recovery can use game-second limits. SO11 A and B run at
1x and 4x in the harness. Report game ticks and measured TPS with real elapsed
time; the harness does not prove native Minecraft scheduling. `/tick sprint`
can exercise these safety invariants, but client rendering and network service
may lag the sprint. Use `/tick rate 80` for timing acceptance and screenshots.

Keep tests of real outage durations, update interruptions and mixed-version
rollouts at 20 TPS. UTC skew, replay retention, clock dates, Amsterdam midnight
and daily date rollover also stay at 20 TPS. Changing tick rate cannot shorten
those wall-clock checks. Server-off recovery at higher rates uses a game-time
outage measured by the workers; the server's durable clock pauses while off.

G4 adds `tests/so/storage-room.lua`. It covers default-off flags, exact fresh
fuel IDs, shared physical-chest cooldowns, save/send failures, power cuts before
send, restart alerts, room readiness, worker unloads and drawn controls at
26x20 and 29x12. Gate B must still verify the room's outside input/output
access cells, actual fuel delivery, sorting stock and furnace fuel consumption.

### Setup UX additions

`drops.busy(id)` identifies the turtle held by an active or failed chest setup
operation. The drop editor owns scan candidates in memory, setup report routing
and scan/test/release commands. Setup requires `so-server.cfg.setupMovement=true`
and a worker with `parkBatch` and `setupFence`. It reserves the complete non-digging round trip
under `setup:<id>`, rejects the mining lane and retains cells after failures.
`drops.list()` includes optional `verified={at,block}` from a successful visit.
Readiness shows verification without refusing otherwise usable points.

`build.assigned(id)` joins the existing mining and lumber assignment queries.
`lease.candidates()` excludes all three jobs, open leases, GPS reservations and
active setup operations. `lease.status(id)` also exposes `parkBatch` and `setupFence`.
Machine registry rows and views include an optional sanitized 16-character
`label`. State retains `pair.done={id,at,role?,label?}` for panel notices.
Mining publishes command refusals through its existing `mine.alert` state key
and clears the key after accepted commands.

Setup completion retains the occupied cell as `gps:<id>` before freeing its
route. `lease.status(id).fuel` reports the latest hello or accepted step-report
fuel for round-trip admission. The display dispatcher keeps a per-session map
of the last delivered frame's button ids and rejects hidden or stale ids before
any screen action. Local monitor input uses its last painted frame.
