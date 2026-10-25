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
their clock.
A failed clock save freezes the timeline at its last issued time. `SO.clock.refused` is
true and `SO.clock.error` holds the save error. The server logs one refusal line, keeps
its event loop and screens running, and shows the refusal in the health metric and
attention list. Later clock reads retry the save. A successful retry clears the refusal
and resumes from the frozen time without charging the storage outage.

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
  owns one, or entropy is unavailable. New invitations use `pair.invite` and also appear on the terminal.
  Dispatch isolates handler errors and preserves the first reply. If no handler
  replies after an error, it caches `err {code="handler"}` for 120000 UTC ms.
  Successful pair2, legacy pairing and enrollment approval emit `pair.done`
  after key persistence and clear the previous `pair.forgotten` row.
  R opens the role prompt; Enter passes its line to `display.command`.
  The built-in `enroll` handler and `SO.enroll` are always available.
  `SO.enroll` exposes `enabled()`, `setEnabled(boolean)`, `open`, `view`, `close`,
  `extend` and `decide`. Enrollment defaults off. OFF closes pending work but
  permits collection of retained approved results. Only the boolean survives restart.
  Config saves verify the write and retain unrelated settings. If the canonical
  config is missing at startup, restore a valid temporary table first, otherwise
  the valid backup, before modules load. This preserves a checked OFF value after
  interruption between the two rename operations.
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
  `pending()`, `clear()`, `key(id)`, `peer()`, `remember(id, key, options?)`,
  `list()`, `forget(id, modules?)`, `forgetPending()`, `forgetDone(id)`, `session(clientPubHex)`, `invite(screen)`, `join(code, serverId, options?)`,
  `repairHint(sender, payload, serverId)`, `envelopeKey()`, `start(from, body)`,
  `confirm(from, body)`, `blocked(id)`, `charge(id, kind, paired)`, `rejected()` and
  `machineKey(secret)`.
  `start` and `confirm` are the server's two `pair2` steps; `confirm` returns the
  machine key and reply body, or nil, a reason and, for `tag`, whether the sender
  proved its saved key. `charge` is the one budget entry for every pairing handler.
  Kind `start` returns false when the sender or all senders are over budget.
  Kinds `reject` and `guess` return true and then true when they burned the code.
  `machineKey` turns a pairing secret into the stored 64-hex key with HKDF-SHA512.
  `join` sends only `pair2`. Client repair can pass `{replace=oldServerId}` to
  `join`, `remember` or `enroll`. After key proof, it saves one verified generation
  containing only the proven server. Failed saves retain old keys in memory and
  after reboot. Server-side additions remain additive. Enrollment preserves the
  token and secret on timeout or `paused="off"`; explicit resume clears the pause.
  A full 16-reply round is noisy and cannot confirm a key or pause the attempt.
  Batch enrollment adds `enrollOpen(owner)`, `enrollView(owner)`, `enrollClose()`,
  `enrollExtend(owner)`, `enrollDecide(id, n, approve)` and `enrollAnswer(from, body, enabled?)` on the server,
  `enroll(kind, show, options?)` and `enrollSave(text)` on devices, `enrollToken(text)` and
  `enrollDrop(id)`, which `forget` calls. The window and its token stay in memory.
  See [enroll](server-only/PROTOCOL.md#enroll).
  `derive` and `session` serve legacy `pair` for one release. `cpace` holds the
  SHA-512, Elligator2 and CPace helpers that tests check against the draft vectors. The hint check only authorizes a prompt;
  it never removes a saved key.
  `open` loads only stored keys that are strings of exactly 64 hexadecimal characters.
  It ignores invalid entries and logs one line without key text. The next key save omits
  ignored entries. `proto.macOk` returns false for malformed keys, allowing dispatch to
  refuse the frame without stopping the server.
  Failed timing initialization waits 30000 game ms after three attempts before
  another secret-generation attempt. Saved keys remain usable.
  `open` accepts the role's millisecond clock; omission uses local tick uptime.
  `join` is a client boot call that waits. Omitting `serverId` uses discovery.
  `peer()` returns the lowest saved numeric peer id, or nil. Workers use it
  as their server id when discovery fails.
- [so-store.lua](../so-store.lua) owns generation-based persistence.
  Calls are `copy(value)`, `read(path)`, `clock()` and `store(path, valid, limit)`.
  `clock()` returns the server's durable game-millisecond function and a status table
  with `refused` and an optional `error`.
  `store` returns `{ value, bytes, save = function(value) }`; `bytes` is the size
  of the recovered generation and updates after a successful save. `save` returns success
  and an optional error. `read` reads a plain Lua table without generation recovery.
- [so-log.lua](../so-log.lua) stores bounded event segments and snapshots for state.
  `open(store)` returns `{ snap, events(), fits(ev), append(ev), due(pressure?),
  checkpoint(payload), rawBytes(), status() }`.
  `status()` returns event availability, sequence, segment count, bytes, snapshot
  number, its saved game time and whether a checkpoint is due.
- [so-errors.lua](../so-errors.lua) opens with `open(store, now)` and returns
  `record(text, force?)`, `flush(now?, force?)`, `entries()` and `status()`. It retains at most
  128 errors in `so-data/errors`, with 2048 bytes per message. Each generation
  is at most 21000 bytes, so current, backup and temporary files fit within
  65536 bytes together. `status().bytes` counts every generation and is
  included in the disk ledger under `other`. Saves run at most once per 30000
  game milliseconds unless forced. A failed save keeps pending records for retry,
  including forced saves. `SO.error(text, force?)` prints and records server errors.
  A true force argument bypasses the flush interval. The server forces its final stop line.
  `SO.errors` exposes this log. `SO.health` holds startup time and the last tick's game cadence, wall
  cadence and cost. Wall cadence is diagnostic only.
- [so-plan.lua](../so-plan.lua) provides pure geometry and batch helpers.
  Calls are `frame(worldPose, journalPose)`, `toWorld(frame, pose)`,
  `toJournal(frame, pose)`, `ahead(pose, dir)`, `apply(pose, op)`,
  `replay(startPose, steps, results)`, `path(from, to, opts)`, `chunk(steps, n)`,
  `inRange(lease, id, cells)`, `rangeBatch(lease, id, action)`, `fuelValue(name)`, `free(inv)`,
  `chestPresent(result)`, `transferFailure(kind, result)`, `chestError(kind, reason, point)`,
  `chestCheck(points, kind, near)`, `toolCheck(tools, kind, id?, autoSwap?)` and `missing(checks)`.
  `toolCheck` returns `{ok,text,blocking}`. Missing tools are informational unless
  `autoSwap` is true; `missing` excludes nonblocking checks. Absent equipment facts are unknown.
  Dimension helpers are `dimensions`, `dimension(name)`, `dimensionError(dim, config)`
  and `heightError(dim, y)`. They validate vanilla aliases, remote opt-in and
  movement bounds. See [remote dimensions](server-only/PROTOCOL.md#remote-dimensions).
  `chestCheck` returns `{ok,text}` without writes. A configured usable chest
  without visit verification reads `not scanned`; a verified one reads
  `verified by visit`. Both remain usable. `missing` returns unmet text in order.
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
  `next(job, row, lookup, inv, fuel)`, `fuelEstimate(job)`,
  `lane(job, exit)`, `inLane(job, pos)` and `lanePass(job, row)`.
  `fuelEstimate(job)` returns approximate fuel in constant time. It counts
  `branches * length + gap * branches * (branches + 1) / 2`
  plus `2 * (1 + abs(home.y - bottom))`. Gap is 2 in fast mode and 4 in thorough
  mode. It excludes ore detours and chest service trips.
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

- [so-ui.lua](../so-ui.lua) is the server-only UI kit. Route A ("schematic",
  [spec](ui/SCHEMATIC-SPEC.md)) is the visual system; its canvas methods are `bar`,
  `section`, `rule`, `leader`, `ticks`, `progress`, `chip`, `flag`, `box` and `digits`,
  with helpers `tone(word)`, `mark(line)`, `age(ms, long?)`, `arrow(facing)`,
  `filled(n, part, whole)`, glyph bytes `g`, chip colours `chips`, `palette` and the
  no-server ramp `stale`. `roleBar(C, name, tabs, short, active, right?, rfg?)`,
  `stepper(C, x, y, value, id, vw?)` and `actions(C, y, items, gap?)` draw job headers
  with tabs, `- value +` steppers and equal action chips.
  `docs/ui/schematic/kit.py` mirrors them call for call.
  `status(model, w, h)` is route A at every size. The Big Tiles calls below stay
  for screens not ported yet. Calls are
  `clock(epochMs)`, `size(w, h)`, `grid(w, h, columns?)`, `ink(bg)`, `glyph(ch, ink, bg)`,
  `canvas(w, h, bg?)`, `status(model, w, h)`, `alert(model, w, h)`,
  `chipRow(C, y, label, chips, x?, right?)` and `fleetRows(C, model, top, step)`.
  `chipRow` draws a label and `{ text, bg }` chips right-aligned to `right`
  (default `w - 1`). `fleetRows` draws status tiles 1-8 as chip rows, using a
  tile's `chips` when present, and makes the ALERTS row the `alerts` target.
  `branchProgress(job, row)` returns clamped branch distance and length in constant time.
  Incomplete poses return nil distance; screens show unknown progress as `-`.
  `progress(canvas, x, y, width, done, total, color?)` draws a one-row bar.
  `turtle.render(w, h, selection, row, now)` returns a pure route A detail or pose-editor frame;
  `turtle.pose(pose)` formats coordinates and facing, or `-` for an incomplete pose.
  `turtle.draft(pose)` fills missing editor coordinates and facing with zero.
  Detail BACK uses the bottom-row coordinates without rendering the editor first.
  `pocketHeader(canvas, title)` draws MORE and MAP beside the title; no screen uses it since
  build, health and turtle detail moved to route A. Those screens add `wrap(text, width)`,
  `fit(text, width)` (cut at a word), `flagLines` (a wrapped `!` flag), `tabRows` (tab groups that
  wrap to a second row), `pager` (the `prev` and `next` chips) and `controlRows` (chips flowed
  over the last rows with BACK at the right end of row h); `docs/ui/schematic/other.py` is their twin.
  `clock` returns Amsterdam `{ h, m, s, date, hm, hms }` from UTC milliseconds,
  with EU summer time between the last Sundays of March and October at 01:00 UTC.
  Status, stock samples, panel headers and new terminal log lines use this clock.
  Durations keep their elapsed-time formats.
  `palette` (route A values) and `font` expose the spec tables. Grid returns one-based `{ x, w }`
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
  `history.page(q)`, `history.kinds()`, `diagnostics()` and `tick(now)`. `view` is a callable table.
  `view.sub` returns a subscription with `stop()`. Query fields are `name`
  and `notify` for views, and `from`, `count` or `limit` for history.
  `reverse=true` reads newest first with an exclusive `before` cursor. `kind`
  filters exact kinds and `alerts=true` filters `.alert` events. Optional numeric
  `id` selects table data with a matching `data.id` and combines with the other
  filters. Optional `text` searches kind and selected data fields as a plain,
  case-insensitive substring, using its first 32 bytes. The wire adapter omits it.
  `history.kinds()` returns sorted distinct retained kinds, at most 64. Cursor lookup
  uses binary search. `diagnostics()` returns the event log status.
  `canStart()` reads current disk use. Mining and lumber `start` refuse at 80%
  or more, or while event writes are pending or failed. Reasons name the largest
  store after a ledger scan; unknown capacity reports `disk size unknown`.
  Oversized events raise a refusal alert without setting a write error.
  Disk reads throttle mismatch-triggered ledger rescans to 30 game seconds.
  Existing work, recovery and stop
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
  emit events, as do label changes. Snapshots include freshness; restored machines get boot-time grace.
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
  `status(id)`, `peek(id)`, `cancelPark(id, "mine")`, `inRange(id, pos)`, `describe(id, job, reason)`,
  `ensureTool(id, kind)` and `tick(now)`. `status` also returns read-only `tools`
  and `toolError`, plus the worker opt-in as `autoToolSwap`. `ensureTool` returns true
  for equipped or unknown tools, or when swaps are disabled, otherwise
  false and a reason. It may send one tool lease when the worker advertises opt-in;
  retries wait 30000 game milliseconds. `describe` sends authenticated worker status
  on change or after 30000 game milliseconds.
  `remoteReady` requires `remoteDimensions=true`, an updated worker and matching
  configured dimensions. Ender-modem jobs use it instead of geometric range.
  Remote movement steps carry destination height and dimension guards.
  `opts` accepts `ms`, `owner`, `recover` and expected world `pose`.
  Reports call `fn(leaseId, turtleId, results, lease)`; expiry passes nil results.
  Unreported single-step `inspectDown` parks retry every game second with the
  same lease ID, a fresh envelope and the remaining duration. Reports stop retries.
  Handlers are `step.report`, `beacon`, `hello` and `history.page`.
  Range starts at 16 and only grows with known world poses or successful reports.
  Work may extend eight blocks beyond that proof.
  Reports notify the owning planner. Planner callbacks manage reservations under
  `mine:<id>`, `lumber:<id>`, `build:<id>` and `setup:<id>`. Reports, park
  cancellation and silence do not release them in the lease module.
  `peek(id)` returns a copied status for an existing row or nil, without creating
  workers. AR and map use it. `inRange` also reads without creating rows and uses
  range 16 for an unknown worker. `status(id)` retains its row-creation behavior.
  Both status calls include copied optional `last={status,ok,at}`. Valid reports
  record `reported` and all-step success; expiry records `expired` and false.
  `at` is game time. Rejected reports leave it unchanged. It lasts until the next
  result or restart.
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
  For `setup:<id>` it stages the occupied-cell handoff. The next `reserveMany`
  must include that cell and saves its transfer with the complete route.
  A conflict or save failure consumes the claim and leaves prior owners intact.
  Other planners keep the immediate handoff. Drops keeps its claim-then-reserve
  call sequence.
  `clearProbe(id)` releases other probe cells only after assignment saves.
  GPS fixes must carry the worker's explicit `so-worker.cfg` dimension.
  See [lease](server-only/PROTOCOL.md#lease).
- [so-mod-cells.lua](../so-mod-cells.lua), `cells`, owns reservations and dug marks.
  Calls are `prepareHandoff(from, to, x, y, z, dim)`, `handoff(from, to, x, y, z, dim)`, `reserve(who, x, y, z, dim)`, `reserveMany(who, cells)`,
  `release(who, x, y, z, dim)`, `releaseOwner(who)`, `forgetOwner(who)`,
  `owner(x, y, z, dim)`, `isFree(x, y, z, dim)`, `markDug(x, y, z, dim)`,
  `isDug(x, y, z, dim)`, `forget(x, y, z, dim)`, `counts()`,
  `list(who, max)` and `tick(now)`. `list` returns up to `max` copied
  `{ dim, x, y, z }` reservations, default 256.
  If `releaseOwner(who)` cannot save the recovery policy or reservations, it records the
  exact cells requested for release. `tick(now)` retries only those cells still held by
  the same owner. `reserve` and `reserveMany` remove their requested cells from that
  owner's pending release, including renewals that need no save. Pending retries are
  memory-only; saved reservations still survive a server restart.
  The optional dimension defaults to `minecraft:overworld`.
  Handler `cells.forget` requires a second, confirmed request.
  Sections save a 1024-character hex bitset, with a 2048-byte generation limit.
  Legacy tables migrate through two compact generations without losing marks.
  `retirement()` returns a pending request, a brief decision notice or a
  disk warning during a snooze. Pending `areas` are copied 16-cube bounds
  `{dim,x1,y1,z1,x2,y2,z2}`. `decideRetirement(id, choice)` accepts `allow` or `keep`.
  ALLOW rechecks current protection and saves dirty eligible sections before
  retirement. The offer never expands. Reads since the offer do not exclude sections.
  At 1000000 bytes, threshold offers aim for 650000 bytes. Pressure offers retire
  all offered sections still safe, even below that target. Empty retirable sets
  produce no request. KEEP saves a ten-minute snooze across restart and growth.
  Under pressure it returns `status="snoozed"`, `untilAt` and
  `text="Disk full. Add disk space."`. NEEDS shows `Add disk space`.
  After the gap, pressure may prompt for any previous choice. ALLOW's gap is one minute.
  `rememberWorker(id, worldPose, dug)` retains the last reported world-frame
  journal cells, including after job removal. Its bounded per-worker record and
  consent policy save to `so-data/dug-policy`. Reservations, running job areas,
  leases and recovery paths protect whole sections. Unknown recovery blocks
  retirement. Bulk work uses `SO.breathe`.
  The map's read-only calls are `dugVersion()`, `dugColumns(dim, sx1, sz1, sx2,
  sz2, max)`, `dugBits(dim, sx, sy, sz, memoryOnly)` and `reserved(dim, max)`.
  They never load, touch or save a section. A section-column index built at
  boot answers `dugColumns`. `reserved(dim, max)` caches each dimension separately.
  Its list and version stay stable until reservations or the limit change.
  The default limit is 4096. `holder(dim, x1, z1, x2, z2, y1?, y2?)` searches
  all reservations in an inclusive box and returns a copied `{who,x,y,z}`.
  It selects the lowest y, then x, then z, without loading dug sections.
  See [cells](server-only/PROTOCOL.md#cells).
- [so-mod-drops.lua](../so-mod-drops.lua), `drops`, owns drop points and inspect
  failure counts. Calls are `pick(kind, nearPos)`, `steps(point)`, `add(point)`,
  `remove(id)`, `edit(id, point)`, `fix(id)`, `note(id, blockName)`, `list()`, `roomMark(id, on)`,
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
  Handler `drops.edit` edits points. Tick registers the generic screen, which
  operators assign as `drops`.
  The route A list selects the first broken point by default, or the first
  point when none are broken. Row taps and chest taps on the room monitor's plan
  select FIX and REMOVE targets. ADD opens the draft editor, starting at the
  selection until the draft is edited. Page, selection, editor and draft are per display.
  After five minutes without input, the draft is discarded unsaved and the display
  returns to the list. REMOVE takes two taps within five seconds; the first shows
  CONFIRM. EDIT changes a usable point in place and keeps its id. Strikes and visit
  verification survive only when dimension, coordinates and side stay unchanged.
  The editor's BACK returns to the list. Long lists page in
  the header.
  The editor also offers `FROM #N` to copy the chest cell from a fresh, proven
  turtle pose; DOWN selects the block below the turtle. A `setup` tab holds the
  per-display chest setup (scan, test and feedback from server-only #222).
  Both renderers accept typed coordinates or `add kind x y z [side] [dim]`.
  The kit-free editor fits above local input; its paging is per display.
  Drop-point dimensions are integers; cell and world-frame dimensions use strings.
  See [drops](server-only/PROTOCOL.md#drops).
- [so-mod-display.lua](../so-mod-display.lua), `display`, assigns roles and sends
  clipped frames. Calls are `screen(role, render, input)`, `screen(role)`, `far(id, on)`, `identify(id)`, `tick(now)`,
  `terminal(model, view, w, h)`, `monitorTouch(side, x, y)`, `assign(id, role)`,
  `command(text)`, `drawTerminal(now?)` and `statusModel()`.
  `statusModel()` returns the status model of the last gather, or nil. The gather
  builds route A fields (flags, turtles, jobs, today, disk, displays, drops, events
  from `SO.terminal.log`, and `thumb` from an optional `map.thumb`) beside the
  tiles the panel role still uses. Every gather also builds `terminal` (counts,
  disk and alert lines, no `mapView`) for the server terminal. State alerts keep
  their `id` and `kind` so the takeover can find its subject.
  Compact rows let a blank cell join the previous run whatever its fg.
  A display shows one role. `assign` is the only way to change it: role nil or
  `-` clears, `drops` saves as `generic`, and unknown ids, unknown roles and
  unregistered screens return `false, reason`. Success returns
  `true, "display <id>: <role>"`; the next tick sends the new frame, and button
  taps from the old frame are ignored until then. `command`
  parses `<id> <role>`, `<id> -`, `<id> far on|off` or `<id> identify`. The server terminal's R
  prompt, tests and the gateb driver use it. See
  [display roles](server-only/PROTOCOL.md#display-roles).
  `terminal` returns a pure route A frame: alerts, FLEET, DISK, the log with a
  coloured mark per line and `[P] pair [R] roles [L] log`. The view supplies
  `id`, `mode` as normal, code, log or role, `uptime`, `log`, `offset`, `code`,
  `expires`, `now` and `pending`; role mode adds `displays`, `input` and `notice`.
  `monitorTouch` handles the tap and redraws at once. The last drawn button wins.
  Local and remote taps
  use the same drawn-button validation for dug-storage consent. Tick discovers a local
  monitor at most every five seconds. It draws at scale 0.5, or 1 with far saved
  under the server's id, without rednet. It
  shows the role saved under the server's own id, or status.
  Tick also draws `SO.terminal` once a second.
  `screen(role)` returns the registered `{ render, input }` callbacks or nil.
  `far` saves a per-computer flag and returns success plus an optional save error.
  `palette` exposes the Big Tiles RGB table at numeric indices 0 through 15.
  `render(w, h, session?)` returns `{ rows, buttons, palette? }`; `input(event)` receives the drawn role,
  coordinates, button id or text, and the same server-local `session`. Handlers are `hello`, `view.sub`, `view.get`
  and `input`. The built-in screen is `status`. No tap
  or typed text changes a role, and no screen draws buttons to another role.
  Input includes sender ID `from`. Sessions retain the client ID as `id` and hello `keyboard == true` as `keyboard`.
  Monitor clients send false; older clients omit it and get touch controls.
  Kit-free callbacks receive that ID instead of the session and the full height.
  Status frames are composed only when the model or display state changes.
  The four-second heartbeat repeats the last frame. Takeover SNOOZE suppresses
  automatic takeovers on that display for five minutes, in memory only. Alerts
  raised meanwhile count as seen; alert counts stay unchanged. After restart,
  the newest standing alert takes over once on each display.
  `snoozer(span)` exports the shared in-memory `set`, `on` and `clear` helper.
  Every status drop row opens the drop list with that point selected.
  The broken-drop flag opens the first broken point.
  Render signatures and revisions are isolated by role, size and session. Status also
  isolates paging and alert takeover state per display session. Panel frames also
  isolate revisions per session. With the kit, a roleless 26x20 display gets
  the `pocket` role. Status and pocket share the alert takeover; after it the
  pocket draws the registered `pocket` screen (so-mod-panel). Without that
  screen it draws the 26-wide status layout under a FLEET header. The takeover
  is a coral frame with the alert's title chip, its subject's position, a crop
  from an optional `map.crop(C, x, y, w, h, focus)` and a coral countdown row.
  Any other roleless display draws UNASSIGNED with its id in line digits; a
  role whose screen is missing draws the same page under the role name. Saved
  roles survive restart.
  Status has no paging; big walls cap their rows and redraw tight over 15400
  frame bytes. `identify(id)` shows IDENTIFY and the id in line digits for five
  seconds and saves nothing. Sessions retain the hello label for the role list.
  The DISPLAYS tile names stale ids. Status turtle rows, lost flags and the takeover
  id chip carry `turtle:<id>`. Status ALERTS opens a newest-first list with
  `alert-prev`, `alert-next` and `alerts-back`. Gather runs in
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
  Mining REMOVE sends `remove <id>` after two taps within five seconds.
  Lumber removal uses typed commands. Uncertain workers show POSE ? and a
  coordinate editor; RE-ADD
  requires two taps after editing and forwards the existing `add` command.
- [so-mod-map.lua](../so-mod-map.lua), `map`, registers the top-down screen
  from `tick(now)`. No wire handlers. Tick gathers `mine.mapView()`,
  `lumber.mapView()`, registry workers, lease state, drop points and
  `cells.reserved`, only within ten seconds of a render.
  `render(w, h, session)` keeps `level`, `fit`, `sx`, `sz`, `cx`, `cz`, `pick` and
  its cell and frame caches in `session.map`. Route A text cells: each covers
  `sx` by `sz` blocks and takes `-` `|` `+` from block adjacency (dots when only
  planned, blue when held); the branch axis snaps to the gap. North is up at every
  size and facing; a fixed `↑N` compass ends row 1, outside the map. Markers,
  greedy labels, branch numbers, tap callouts and a wall roster strip follow
  `docs/ui/SCHEMATIC-SPEC.md` section 10. Dug planes per section column and level
  are shared by all displays and the `thumb` and `crop` exports, read at most 16
  sections per tick, and rechecked with at most 64 memory-only probes per tick after
  the dug serial changes. An unchanged view returns its cached frame. A frame over
  15000 bytes draws one zoom step out only after visible dug planes have loaded.
  FIT waits for loaded terrain before zooming out to meet the frame budget. Held-cell callouts
  name the owner role and show silence after a minute or when the holder is lost,
  if contact time is known. Turtle callouts show the last batch result and age.
  Geometrically range-blocked Overworld turtles show measured distance and limit.
  Level arrows clamp to -64..319, 1..126 and 1..255 for Overworld, Nether and End.
  Selected-cell and shaft ownership queries search beyond the display-list cap.
  Exports `thumb(C, x, y, w, h)` (status wall)
  and `crop(C, x, y, w, h, focus)` (alert). The map is its own role with no BACK.
  `docs/ui/schematic/mapdraw.py` and `mapscreen.py` are its Python twins; the
  `view` lines in `tests/ui/map-scene.txt` feed both them and `tests/so/map.lua`.
  See [map](server-only/PROTOCOL.md#map).
- [so-mod-health.lua](../so-mod-health.lua), `health`, registers `health`,
  `attention`, `alerts`, `events` and `errors`. `count()` returns the attention
  count. EVENTS and ALERTS show page numbers from page 2, with LATEST to return
  to page 1 and keep filters. Page 1 has per-display HOLD and LIVE. EVENTS offers
  a retained-kind picker and typed text search. A row opens event facts; BACK
  restores its list page.
  Fuel failures link to mining SETUP. Lumber shows its saved alert
  cause before its blocked state. `attention(facts)` returns severity-sorted rows
  with `key`, `text`, `target` and optional input `actions`. Gathered facts are
  `now`, `disk`, `points`, `jobs`, `machines`, `leases`, `retirement`, `pairing`
  and optional `requests`, `fuelAlerts`, `forgotten`, `clockRefused`, `errorCount`
  and `errorAt`. The module gathers once per five game seconds. Jobs and paired
  IDs come from read-only generation recovery. Pending rows come from
  `SO.enroll.view().rows`, without the owner's token. Open pairing invitations
  also appear. A nonempty error ring adds one `errors` attention row while its
  newest entry is less than ten game minutes old. Aging out the row keeps errors.
  ERRORS rows preview the first line and open the full message with wrapping,
  paging and BACK. Each display keeps a stable selected message and list page.
  Truncation and wrapping preserve UTF-8 codepoints. The pages draw in route A:
  tabs HEALTH and NEEDS n, then EVENTS ALERTS ERRORS, leaders or list rows, and the `prev` and
  `next` chips on the last row ([schematic spec](ui/SCHEMATIC-SPEC.md#23-health-pages)).
  Display inputs receive `event.open(role, actions?)`. Under the role lock it opens
  that screen as a page inside the display's own role (`session.visit`, closed by
  `visit-back`) and sends the listed input IDs to it with the same display session.
  These callbacks stay on the server and do not enter wire frames.
- [so-mod-panel.lua](../so-mod-panel.lua), `panel`, registers the `panel` and
  `pocket` screens from `tick(now)`. No wire handlers or other exported calls. The screen keeps search,
  main/alerts/pair pages and alert paging in each display session. Tick gathers
  registered screen callbacks and job header states, reading only the header row, plus state `.alert` values.
  The status PAIR button opens the panel pair page directly. Main-page inputs
  forward START and STOP once to the mining or lumber screen.
  Keyboard-equipped panels show the best match and stock, call
  `shop.order(search, count, view)` once and draw the last order and reply below
  the quantity chips. Shop's count/name sort defines
  the best match; ordering leaves shop display state unchanged. Missing screens
  have grey blocks without action targets.
  Monitor panels drop quick search and quantities and show only the job blocks.
  ALERTS wraps state alerts to two rows as on the pocket; PAIR offers NEW CODE. The panel pages are route A
  (twin `docs/ui/schematic/panel.py`, SCHEMATIC-SPEC section 22): job blocks with
  the pocket's facts in columns of 16 to 36 cells, HEALTH and `NEEDS n` chips in
  row 1, ALERTS and PAIR chips on the last row, and bracketed `[FORGET]`,
  `[CONFIRM]`, `[OK]` and `[NO]` actions in the PAIRED and ENROLL lists.
  The pocket screen (route A, twin of `docs/ui/schematic/pocket.py`) keeps
  `session.pocket = { page, search, selected, sent, alertPage, invitation,
  pairBusy }`; `display.assign` clears it. Tabs `tab:fleet`, `tab:jobs`,
  `tab:shop` and `tab:pair` sit on row 1, with a coral dot in FLEET while any
  flag exists. FLEET is status's column layout from `display.statusModel()`;
  each alert row is an `alerts` button that opens ALERTS (every flag with its
  detail, `alert-prev` and `alert-next`). JOBS reads `mine.facts()` and
  `lumber.facts()` when present, else the status model, else the state the
  panel's 120x18 probe reads; it forwards `mining:start|stop` and
  `lumber:start|stop` once. SHOP lists as many `shop.matches` items as fit;
  `pick:<item>` selects, `clear` empties the search, and `order:<1|16|64|stack|all>:<item>`
  under the shown item calls `shop.order(item, count, view)` once while that item
  still matches the search. ALL has no target at zero stock. Row h-1 shows sent,
  delivered or failed; row h shows the reply. PAIR draws the code in line digits with a teal
  countdown and uses the same `pair-code` path as the panel. Its PAIRED chip opens
  the paired devices page (per-device FORGET), and ENROLL the batch enroll window
  when `enroll` is on. Inputs act only on
  the page that drew them.
  Authenticated display input calls `SO.pairCode(from)` and keeps its result in
  that session. Big digits and remaining time clear on use, expiry or burn.
  Code frames use the display's own key; other displays never receive them.
  When a pocket opens PAIRED or ENROLL the panel draws them under the pocket's
  tabs (`P.render(w, h, session, dot)`). No saved panel file.
  See [panel](server-only/PROTOCOL.md#panel).
  Dug-storage requests appear above every role, including status, pocket,
  generic and unassigned.
  The server accepts consent only for a current, fully visible button at its
  drawn coordinates. Decision notices last 30 seconds.
- [so-mod-shop.lua](../so-mod-shop.lua), `shop`, adapts the legacy Storage Room
  turtle to the shop screen. Exports `tick(now)`, `order(search, count, view?)`,
  `best(search)` and `matches(search, limit?)`. `matches` is read-only: up to `limit`
  (default 10) `{ name, count, label }` stocked items whose id or display name contains
  the search, by stock then id. `best` returns an exact id present in totals and
  its count, including zero; otherwise it returns the first stocked match.
  `order` refuses zero stock. Count accepts 1, 16, 64, `"stack"` or `"all"`.
  STACK uses the stack size; ALL uses stock up to one stack. It returns item id
  and count, or nil and a reason. An optional view receives `order`, `orderDetail`
  and `orderRid`, without a recent-orders entry. A failed send fails immediately.
  Getting or Crafting keeps the order pending for up to 600000 game ms from
  dispatch. Without acknowledgment the limit is 120000 ms. Delivery needs an
  explicit Delivered or sent-to-output-chest reply. Silence after acknowledgment
  shows `no delivery`. Matching sender and request id are required.
  `fuelConfig(auto?, outputId?)`, `fuelEmpty(point)`, `fuelAvailable(point, orderRid?)`,
  `fuelClear()` and `fuelAlerts()` run the fuel policy. Fuel auto-order defaults off in `so-data/fuel-policy`.
  Bind the room output as a fuel point in mining SETUP. Empty reports share a
  saved ten-minute cooldown per physical chest across mining/lumber and restarts.
  Exact charcoal or coal orders require 64 fresh stock. Save precedes send.
  At most one fuel order is outstanding, across cooldowns, flag/output changes
  and restarts. A confirmed refusal, delivery or observed usable fuel ends the
  saved wait. Pickup actions save the expected order id, so old inventory reports
  cannot complete a later order. Unknown replies keep waiting until the deadline. With
  fuel auto enabled, after two minutes a successful policy save clears waiting and keeps
  `fuel order timed out` attention. A later empty report may order again after the ten-minute physical-chest cooldown, with one outstanding order. Late replies for the
  timed-out request id are ignored. A failed policy save emits no alert and keeps
  waiting for retry. `fuelClear()` saves a manual release of waiting and its alert
  without clearing cooldowns.
  Failure causes appear in `shop.alert` and `fuelAlerts`; usable pickup clears
  them. Lumber saves pickup slots, retains non-fuel items while searching, and
  returns only those items before refueling. Missing fuel and failed returns
  retain their minute retry and recover through the saved service record.
  No `so` handlers. Listeners are `roomsorter`, `roomsorter_stock` and `dns`.
  Tick registers the shop screen, discovers storage, polls stock and samples it once a
  minute. Stock replies may add `labels`, `stacks` and `tags` (roomsorter.lua sends them);
  an item's category and sub come from a rule table on its id, then its tags, then its
  namespace (`S.kind`). The screen is route A at every size, with tabs ITEMS, LOW and
  FIND, category and sub chips (a picker under 52 cells), a sortable dotted list with
  hourly changes, and the item as a right-hand pane (its own page under 52 cells) with
  order chips 1, 16, 64, stack and all and the item's recent orders.
  `docs/ui/schematic/shop.py` is the layout's twin. Browse state belongs to each display;
  each order tap sends one order. Sent does not imply delivery.
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
  target before another placement. MORE links to BUILD. The screen draws in route A with the
  tabs `tab:job` and `tab:setup` ([schematic spec](ui/SCHEMATIC-SPEC.md#22-build)).
  While a running builder is held for fuel, it sends a stationary `inspectDown` probe
  whenever no lease is pending. The probe reserves only the turtle's current cell. If
  that reservation conflicts, the fuel hold stays active and later ticks retry. Refuel
  the turtle to let the next probe refresh its fuel and resume the build. A zero-fuel
  report keeps the "out of fuel" hold and sends no movement. Failed movement reports
  "out of fuel" when the worker reports a fuel error or zero fuel.
  See [builder jobs](server-only/BUILD.md).

- [so-mod-mine.lua](../so-mod-mine.lua), `mine`, runs branch mining and ore recovery.
  `assigned(id)` reports whether its job owns that worker.
  Calls are `tick(now)`, `dugProtection(protect)`, `forgetDug(sectionPaths)`, `mapView()` and `facts()`;
  no wire handlers. Protection covers the running mine and saved worker routes.
  `forgetDug` clears block lookup entries for a set of retired section paths.
  Tick registers `display.screen("mining", render, input)` and
  `lease.onReport("mine", report)`. Cell owner tags are `mine:<id>`.
  Mining is route A: an overview tab with the job diagram and a setup tab with
  steppers and toggles (`set-*`, `mode-*`, `ore-*`) that send the text commands.
  The tab belongs to the display session. Kit-free callers share the default page.
  Typed commands work on both tabs. Daily ore totals come from `daily.today()`,
  with `-` when missing. `facts()` returns the job state for other screens.
  Missing kits retain the legacy renderer.
  Screen callbacks are `render(w, h, session)` and `input(event)`; reports use
  `report(leaseId, turtleId, results, lease)`. Jobs save to `so-data/mine/job`.
  `mapView()` returns copied geometry fields, `running`, `done`, worker
  poses, states, branches, lane flags and ore counts, a cached two-endpoint
  next-branch `preview` and `trails` for the map, status and AR.
  endpoints and state per worker, plus at most 64 recently completed branches.
  Completion trails clear when START resumes a stopped job or the server restarts.
  These are display additions and do not change worker routes.
  `start` requires home, usable ore and fuel points, an added paired worker and
  reported fuel. SETUP shows compact state-coloured readiness rows.
  Saved homes remain configured. `branches <n>` enables continuous mining with a
  job budget of 1..4096 branches, default eight. `continuous` defaults off.
  A returning worker saves its next claim as `{branch,junction}` before retreating
  through the shared lane. Branch claims and counted completions survive restart. Ore
  filters default to all ores. `ores` accepts spaces around commas. `remove` refuses
  a reported pose in the shared shaft or bottom spine. Off-lane removal can retire a
  stationary recovery or park lease through `lease.cancelPark` when `workerPark`
  is off. The enabled contract below requires a fresh stationary report.
  Unfinished branch claims, including return-trip claims, are reassigned before
  allocating a new branch, without increasing `nextBranch` again. Stale
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
  SETUP has SINGLE and CONTINUOUS chips, a continuous branch stepper from 1 to
  4096 and `fuelEstimate(job)`. Ore taps preserve other selections across all
  ten supported ores. Empty or missing filters mean all ores. Narrow screens
  use a dedicated ore editor. Empty auto-fuel pickups retry after 60000 game ms
  and call the shared `shop.fuelEmpty` policy again.
  Mining refuses `home`, `bottom`, `length`, `branches`, `continuous` and `mode` edits
  while the job runs or a turtle row still holds a route. STOP waits for outstanding
  batches to settle and clears route geometry. START rebuilds the routes using existing
  branch claims. Changes to home, bottom, length or mode start fresh geometry and
  progress; branch-budget and continuous-mode changes retain progress.
  A cell that fails three mining digs is skipped, with its failure count saved across
  server restarts. Mining bypasses skipped cells and continues the branch. Detours avoid
  known containers and protected cells. If inspection discovers an obstacle on a saved
  detour, mining discards that path and replans. If no path is found within the bounded
  search, the unreachable goal is saved as skipped and the job continues without waiting
  for the player. Recovery counts an interrupted dig attempt unless the worker's dug
  history confirms success. Skipped cells are never recorded as dug. Mining refreshes
  its standing-cell reservation even when it already owns the cell, so a pending release
  cannot free the occupied pose.
  Mining refuses dig batches when reported equipment has no equipped pickaxe and shows
  `needs pickaxe`, even when automatic tool swaps are disabled. Automatic swaps remain
  opt-in. Workers without equipment reports retain the existing unknown-tool behavior.
  Lumber tool behavior is unchanged.
  See [[server-only/PROTOCOL#mine]] ([mining](server-only/PROTOCOL.md#mine)).
- [so-mod-lumber.lua](../so-mod-lumber.lua), `lumber`, scans, harvests and replants trees.
  `assigned(id)` reports whether its job owns that worker.
  `turtleView()` returns a copied detail row per worker, including its pose, fuel,
  inventory, state and step, plus shared farm progress.
  Calls are `tick(now)`, `dugProtection(protect)`, `mapView()` and `facts()`; no wire handlers.
  Protection covers the running farm at every height, saved service routes and
  worker recovery. Mining and lumber pass world-frame journal cells to cells.
  Tick registers `display.screen("lumber", render, input)` and
  `lease.onReport("lumber", report)`. Cell owner tags are `lumber:<id>`.
  Screen callbacks are `render(w, h, session)` and `input(event)`; reports use
  `report(leaseId, turtleId, results, lease)`. Jobs save to `so-data/lumber/job`.
  `mapView()` returns copied dimension, area, ground, sapling chest, up to 512
  sorted tree spots `{ x, z, ready }`, `running`, `grow` (ms to the next ready
  spot) and a `turtles` map of `{ id, pose, state, phase }` rows for the map and status.
  Old single-worker jobs migrate when loaded. Shared scan claims reserve target
  cells until felling and replanting finish. FIFO tickets serialize chest access.
  Workers retain the access column until their return leaves it. Lost workers
  keep their uncertain cells while the others continue.
  The Big Tiles screen gathers job state into a pure layout. START and STOP use
  the text command path. Every turtle appears with its phase and fuel. Three
  The route A screen draws the farm plan, its facts and every turtle with its
  phase and fuel; START and STOP use the text command path. `park <id>` saves a
  per-worker pause; `start` resumes legacy pauses when `workerPark` is off.
  With the flag on, START preserves per-worker pauses. The setup tab lists the
  configuration; tabs belong to the display session. Missing grow timers show `-`.
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
  `drops` and `alerts` toggles. The screen is route A (twin `docs/ui/schematic/ar.py`,
  SCHEMATIC-SPEC section 26): the controller count in the header, then one leader row
  per layer with `[on]` or `[off]`; the whole row is the toggle, with no BACK. Switches save through
  `so-store` to `so-data/ar`.
  Discovery runs at most every five seconds; changed scenes redraw at most once
  per second. Failed controllers are dropped until discovery. Known server
  dimensions filter world elements. Alerts expire after five minutes, renewed
  by new events. First controller attachment clears old elements when supported.
  World strokes are single lines in the route A palette: twelve-edge boxes and a
  two-line upright heading chevron outside a turtle's front face. A lease of just the
  turtle's cell merges into its box (blue), so a turtle never has two outlines. World labels use size 0.5 and
  short text, with nearby labels stacked. Only the nearest 16 turtle labels and
  eight drop labels per kind are drawn, using the server position. Boxes and
  chevrons remain. The HUD counts all registered workers like status, including
  paired idle workers; its value turns coral for lost leases.
  The HUD starts at GUI `(4,72)`: one hairline-ruled navy panel of three cells
  with muted caps labels and white values. A five-second alert flag is its first row,
  and retirement notices sit below the panel. Rectangles never overlap and use opposite corners.
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
  until an authenticated reply arrives. Fresh turtles show `UNPAIRED`; failed
  pairing shows `Pair failed: <reason>`. Pending enrollment shows
  `approve on panel <fp>`. A `pair.required` hint shows `No key on server` above
  `Code:` and offers a code
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
  Remote jobs always use explicit add. The worker advertises `dimensionSafety`,
  checks remote movement height and inspects immediately before moving. A failed
  remote move aborts its batch. Remote expiry stays stationary. Journal `dim`
  changes require re-anchor before retained dug history can be used again.
  Legacy overworld journals omit `dim` on save. Nether moves carry world poses,
  then inspect all six neighbours using journaled turns. A successful movement
  result can carry `hazard`; planners retain its moved pose, hold and report
  the lava coordinates. See the protocol for the remaining fluid race.
  `discard {side="front"|"up"|"down", n?}` checks for an empty cell and refuses
  adjacent inventories. The default side is down.
  An unpaired worker with `so-enroll` enrolls with the token's server before any
  lookup. The `Code:` prompt also accepts a pasted token, shown masked.
  It accepts authenticated server batches, not planner decisions. Keep it small
  and add no new turtle files.
- [display.lua](../display.lua) pairs, sends `hello` and `view.sub`, draws
  `view.frame` and sends `input`. No exported API. It handles touch, clicks,
  text and resize events, and retries when its frame becomes stale. Rows accept
  old blit strings or compact `{ text, runs = { { n, fg, bg }, ... } }` data.
  Compact text omits trailing spaces, which the client pads to the run width.
  Frames may carry a 0-based RGB palette and monitor scale 0.5 or 1. Missing
  palettes restore stock colours. A changed scale sends one resized hello.
  Buttons accept optional height `h`, default 1. Without a server the client
  keeps the last picture, swaps to the grey `stale` palette without redrawing it
  and draws one coral row, `NO SERVER m:ss ... retry in N s`, redrawn alone
  once a second on palette outputs and on every retry.
  Pairing prompts and digits appear on the display and
  its computer terminal. Failed pairing accepts a new code. A `pair.required`
  hint shows the same prompt without deleting the old key. Authenticated frames
  dismiss the hint and restore the normal screen. Discovery and
  stale-frame hello/subscribe retries use backoff capped at 30 seconds. At boot,
  it prefers the lowest saved paired server ID and retries that ID without DNS.
  It opens every modem and rescans on attach and detach events. A monitor attach
  or detach picks the output again, sends a hello if it changed, and redraws. Screens
  at least three rows tall reserve the bottom row for typed input and report
  the remaining height in `hello`. The optional `fullH` advertises physical height
  so Big Tiles can use every row, including the pocket's last row. Kit frames
  use that full height; while typing, the line covers their bottom row. Kit-free
  frames retain the input row. Wall displays
  also echo input on the terminal.
  `so-display.cfg.repairServer` enables terminal REPAIR after a server replacement.
  Like `retryInput`, it defaults off. Public wall taps cannot change the server.

## Managed room outputs

`roomsorter.lua` keeps legacy behavior until `room.cfg.managedOutput=true` or
an output-state generation exists. The flag defaults off. Managed outputs bind
one server and physical output, save claims and increasing request ids, and admit
one tagged get or order per claim. Settlement receipts prove that queues, crafts
and cargo can no longer emit for that request. An empty chest is insufficient.
Reboots quarantine saved output state. Run `output reconcile` locally on the room
turtle to return cargo and save a new settlement barrier. Disabling the flag
retains recovery and the interlock but refuses new claims and orders. This room
protocol does not enable managed-output requests in the legacy shop adapter.
See [managed room outputs](server-only/PROTOCOL.md#managed-room-outputs).

## Per-worker park and removal

`so-server.cfg.workerPark=true` enables `park <id>`, `resume <id>` and
`remove <id>` on mining, lumber and build screens. It defaults off and is read
at startup. A pause finishes the current batch, then needs a stationary report
before `parkConfirmed` permits removal. `removeRequested` survives restart;
confirmation does not. Recovery and a fresh report must complete first.
Resume clears the selected pause and pending removal. START keeps these pauses.

Removal waits for no open lease, lost status or uncertain pose. Cleanup transfers
the occupied cell from the job owner to `gps:<id>`, releases other job reservations
and saves row deletion. Failed cleanup or saves retain the row for retry. Recovery
reclaims a transferred GPS cell if deletion failed. Mining refuses removal in its
shared shaft or spine and returns unfinished branches to the queue. Lumber waits
until its chest-access lane is clear. Builder removal stops its single-worker job.
Adding a worker reclaims its standing reservation. No force removal exists.

With the flag off, startup clears and logs these saved pauses and removals.
Assignments remain and resume after recovery. Lumber's `parkRequested` separates
these pauses from legacy PARK and START behavior.

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

`install <token>` refuses enrollment if `so-keys`, `so-keys.bak` or `so-keys.tmp`
exists. It asks you to run `install reset` first and writes no `so-enroll`. Reset
confirmation shows the number of paired keys from `so-keys`, or from `so-keys.bak` when
the primary file is missing or unreadable. It never prints key text. Each downloaded
file is named before its HTTP request. Successful `install update` and `install rollback` commands print `Updated <role> from <old7> to <new7>` and immediately start
the installed role program. Missing or invalid revision metadata appears as `unknown`. A
failed update or rollback starts no role program.

Run `install <full-sha>` or `install update <full-sha>` to select a full lowercase
40-character commit in `server-only` history. Files stay pinned if the branch moves.
Current installs
check space for the bootstrap, then the pinned installer's complete role plan.
Ordinary downloads try a failed file up to three times. Explicit-SHA
installs and updates use one attempt per file. `install check` compares the installed revision
to the branch without writing files and reports an error if lookup fails.

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

`install <token> [sha] [--server <id>]` stages enrollment for workers,
pockets and wall displays. Their enrollment kinds are `turtle`, `pocket` and
`computer`. The pinned installer must support these options or installation
refuses without fallback. `--server` accepts one nonnegative integer and must
match the token's server when both are supplied. Any key-file generation refuses
a token or selected-server install. Selection merges `server` into
`so-worker.cfg` or `so-display.cfg` through the installer transaction and keeps
unrelated fields. A token updates an existing saved server selection to the token's
server. Without a token or selection, config stays unchanged. These options stage client
data; consumption depends on the installed client. The current display client
still uses code pairing. `/.so-role` contains the plain role name. Updates trim surrounding whitespace. `startup.lua` runs installer recovery,
then the role program. A fresh server install merges
`pos = { dim = string, x = number, y = number, z = number }` into `so-server.cfg`.
Rerunning it preserves unrelated settings, including `enroll`.
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
It deletes `so-enroll` before the swap, because an older worker never reads or
deletes it.
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
   and Up or Down scrolls it. R opens role mode: chars and paste type into a
   `<id> <role>` line, Enter applies it, Backspace edits and Esc leaves. Every
   key goes to the prompt while it is open. Server prints enter an in-memory log bounded to
   200 lines of at most 4096 bytes each. Long lines split without dropping text.
   Monitor touches queue local input. The one-second timer expires reply-cache
   entries, refreshes pairing state and calls every `tick(now)` in filename order.
   It rearms after the ticks; missed seconds do not produce catch-up ticks.
   If any event arrives more than 3 computer-tick seconds after the last tick, the loop
   logs, ticks and starts a fresh timer. This watchdog uses `os.clock()` so a frozen
   durable clock cannot stop timer recovery.

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

- [pair](server-only/PROTOCOL.md#pair), [enroll](server-only/PROTOCOL.md#enroll),
  [hello](server-only/PROTOCOL.md#hello),
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
The `history.page` wire handler returns `{at,text}` entries newest first.
`next` is an exclusive `{at,seq}` cursor, ordered by UTC milliseconds and then
sequence, both descending. Pass it unchanged as `before`. Legacy numbers and
`{at}` cursors select strictly older timestamps. `limit` defaults to 20 and is
bounded to 1..50. Internal `state.history.page` keeps sequence cursors, its
reverse option and full event entries.

Lease proof maintenance uses `formal/verify_lease.py` against the real lease
module. `--evidence formal/evidence/lease-orderings.json` writes the source
hash into the JSON evidence and `tests/so/lease.lua`. Focused tests and the full
suite check those hashes. `--check-evidence formal/evidence/lease-orderings.json`
rejects stale evidence without regeneration. The model uses planner owner
`mine:2`; reports and expiry retain it for planner callbacks to manage.

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
  Checkpoint n deletes segment generations only below snapshot n-1's `first`.
  Startup preserves those fallback files but reads events from the newest readable
  snapshot's `first`. It uses n-1's `first` only when n is unreadable. Missing
  segment numbers do not stop the scan. Sequence allocation resumes above the
  highest recovered event or published checkpoint sequence. Retention checkpoints
  begin above 960 KiB of retained segment bytes. They plan the new snapshot's
  `first` to leave at most 768 KiB of newer segments, then defer deletion to the
  previous snapshot's boundary.
- `so-data/cells/res` holds reservations. Dug marks live in
  `so-data/cells/<escaped-dim>/<sx>_<sy>_<sz>` for 16-cube sections.
  The cache holds at most 256 sections; tick saves at most eight dirty sections.
- `so-drops` holds drop points, failure counts and the default-off room-sink flag.
- `so-data/fuel-policy` holds the default-off fuel auto flag, bound output,
  up to 64 saved cooldowns, waiting delivery and its failure alert.
- `so-display` holds `{ roles = { [stringId] = role }, far = { [stringId] = true },
  locked = { [stringId] = true } }`. `locked` marks roles the command set; a
  pocket ignores an unlocked saved role from before R1.
  Roles are `status`, `pocket`, `mining`, `lumber`, `shop`, `generic`, `ar`,
  `panel` and `map`. Only `display.assign` writes them. The server's own id
  holds its local monitor role. `pocket` is new in R1; older servers reject a
  file containing it. Old files without `far` remain valid.
  Far displays use scale 1; others use 0.5.
- `so-data/daily` holds `{ date, cursor, ore, oreByName, logs, recent }`.
  Recent ore uses game-second buckets `{ total, counts = { [gameMs] = count } }`.
  Bucket keys and timestamp keys are decimal strings. Only the server installs it.
  If `so-data/daily`, `.tmp` and `.bak` have no valid generation, the daily module
  removes all three files and opens with zero totals and cursor zero. It logs
  `so-daily: unreadable totals reset` once. Its next tick reads retained history
  and saves rebuilt totals. A valid surviving generation preserves saved totals.
  Other store errors still stop the module from loading.
  Section files have no aggregate disk bound or automatic pruning. Owner release
  removes reservations only. Marks remain available for recovery across jobs.
- `so-drops` holds drop points and failure counts. `so-display` holds screen roles.
- `so-data/ar` holds the four AR layer switches, enabled by default.
- `so-journal` is the worker's bounded recovery journal. `so-code` supplies a
  boot-time pairing code and is deleted after successful worker pairing.
  `so-enroll` holds a client's enrollment token, optional X25519 secret and
  optional `paused="off"`. Window closure and timeout retain the attempt.
  Explicit local token entry or installer rerun resumes a pause.

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
`python3 -I docs/ui/mockup-gen.py --fixtures DIR` writes every Big Tiles fixture
that is not ported to route A, without changing the normal mockups.md and font.txt
output mode.

UI-1 adds `tests/ui/ui1.lua`. It checks glyph pixel round-trips, status drawing
from a tiles-only model, alert takeover timing and dismissal, takeover contrast,
clipping, locked roles, size-specific revisions, source gathering and server-only
kit installation. UI-3b covers the pocket's 20 rows.

R3 adds `tests/ui/r3pocket.lua`. It checks tab routing after a takeover,
missing modules, the fleet chips from a real gather, exact-item orders and the
JOBS page over the real mining and lumber modules. The route A pages moved to S4.


UI-2d adds `tests/ui/ui2d.lua`. It checks the ar-M fixture (route A since RA3), the route A drop list,
selected drop actions, draft editing, all 64 points through paging, AR switch
persistence, navigation, contrast and bounds at P, L, M, XS and odd sizes.
Screen gather and pure layout helpers are private; public module APIs, saved
files and client role lists are unchanged.

UI-3b adds `tests/ui/ui3b.lua`. It checks the typed search on the panel,
pocket defaults and tabs, per-pocket pages and search,
action forwarding, real shop orders, monitor layout, session revisions, role
persistence, alert paging, pairing help, missing modules, contrast, bounds and
server-only installation.

R1 adds `tests/so/role-lock.lua`. On a real server with every module it taps
every drawn button on every page of every role at 57x24, 39x19, 26x20 and
15x10 and checks the saved and drawn role never change. It also checks the
command's assign, change, clear and rejections, a restart, the terminal R
prompt through key events, the role list, and the roles-T, unassigned-M and
unassigned-XS fixtures. Tests that need a role use `display.command`.

S0 adds `tests/ui/s0.lua` and route A. `docs/ui/schematic/screens.py --fixtures`
writes the route A fixtures (`kit-M`, `status-M/W/XL/T/L/P/XS`, and since S2 the map's);
the test checks that output equals the committed files (Linux, python3) and renders
a PNG when a CC font is found. Fixtures gain an fg layer: `WxH title`, H text, H fg
and H bg rows; `tests/ui/render.lua` still loads two-layer fixtures and compares fg
only on non-blank cells, and its pictures map control bytes and Latin-1 to Unicode.
Status data comes from `tests/ui/status-scene.txt` and `tests/ui/map-scene.txt`
through the real gather. The test also checks every kit primitive, the coloured-glyph
contrast rule, missing modules, odd sizes, the tight wall fallback, blank-run
compaction on the 164x81 map fixture under 16 KB, and control glyphs through
`so-proto`, compact rows and the display client.

S4 adds `tests/ui/s4.lua` and `tests/ui/scene.lua`, a running server fed from
the status, map and `system-scene.txt` scenes. `docs/ui/schematic/pocket.py` and
`system.py` write the pocket (`pocket-fleet/alerts/jobs/shop/pair/code-P`),
takeover (`alert-M/W/T/P/XS`, `alert-nomap-M`), unassigned (`unassigned-M/XS`,
`unloaded-M`), no-server (`outage-M/P`) and terminal (`server-T`, `pairing-T`,
`log-T`, `roles-T`) fixtures. The test matches each through the real server
path (and display.lua for no-server) in text, fg and bg, with contrast and
bounds. It also checks the JOBS fallbacks, one action per tap, alert paging,
takeover timing, the crop call and its failure, the grey palette and row-only
repaint, the R prompt and frame sizes.

S3 adds `tests/ui/s3.lua` and `tests/ui/jobs-scene.txt`. `docs/ui/schematic/jobs.py`
writes the mining, lumber and drops fixtures (`mining-*`, `miningsetup-*`, `miningores-*`,
`lumber-*`, `lumbersetup-*`, `drops-*`, `dropsadd-*`). The test builds each job from the
scene files, draws it with the real module and compares every fixture cell by cell. It
also checks that each setup control equals its typed command with one save, that FIX,
REMOVE and ADD act on the selected point once per tap, `facts()`, the pocket probe,
crowded jobs, missing modules, odd sizes, contrast, frames under 16 KB at 164x81 and
generator parity.

RA2 adds `tests/ui/ra2-other.lua` and `tests/ui/other-scene.txt`. `docs/ui/schematic/other.py`
writes the build, health and turtle detail fixtures (`build-*`, `buildsetup-*`, `health-*`,
`attention-*`, `alerts-*`, `events-*`, `errors-*`, `turtle-*`, `turtlepose-*`). The test draws
the scene with the real build and health modules and `U.turtle`, compares every fixture cell by
cell with contrast and bounds, and checks the old ids, the row targets, the kind chip, paging,
CONFIRM and generator parity. The health scene fixes the disk numbers, so no fixture depends on
the host.

RA3 adds `tests/ui/ra3-ar.lua`. `docs/ui/schematic/ar.py` writes the AR screen fixtures
(`ar-M/W/L/P/S/XS`); ar-M was the last Big Tiles fixture, so `docs/ui/mockup-gen.py` writes none
now. The test draws each model with the real module, compares text, fg and bg cell by cell with
contrast and bounds, and checks the layer ids and full-row targets, one save per tap, reload and
generator parity. `tests/so/ar-strokes.lua` checks the single-stroke boxes, the front chevron,
stable ids and the line budget; `tests/ui/ui3c.lua` checks the HUD panel geometry, colours and
that no rectangles overlap.

R5 rewrote `tests/so/map.lua`; S2 moved it to route A. It renders every
`view` line in `tests/ui/map-scene.txt` (`map-*` and `schematic-map-XL`) through the
real cells module and compares text, fg and bg, then checks the compass and that north
stays up for all four mine facings, line glyphs, dots and held colours, pan, zoom, FIT,
picks and callouts, the level control, per-tick read and probe bounds, an idle map with
no reads, frames under 16 KB at 164x81, `thumb` against the status-W fixture, `crop`,
and that the cells map queries write nothing. On Linux it also checks that the
generator reproduces every map fixture.

S1 rewrites `tests/ui/ui2c.lua` for the route A shop. It loads `tests/ui/shop-stock.tsv`
(110 real item ids with history, stack and expected category) into the real module, taps
to every page and compares the `shop-browse`, `-item`, `-low`, `-find` and `-pick` fixtures
at 57x24, 39x19, 100x38, 29x12 and 26x20 cell by cell, with the contrast rule. The old
Big Tiles names (`shop-M`, `shoporder-M`, `shop-compact`, `shop-pocket`, `shop-large`)
hold route A pages too. It also
checks the category table on real ids and tags, filters and picker counts, every sort and
paging through every item once, keypad and keyboard search, one order per tap for each
amount, order replies and timeouts, `matches`, `best` and `order`, bounds at odd sizes,
stale and missing stock, the optional roomsorter fields, and (Linux, python3) that the
generator reproduces every shop fixture. `tests/parts/so-mod-shop.lua` runs it with
`tests/ui/shop-touch.lua`.

UI-5a adds `tests/ui/ui5a.lua`. It checks Amsterdam DST and midnight, screen
clocks, daily totals, exact ten-minute expiry, saved-cursor restart, bounded
history work, stale fallbacks and server-only installation.
RA2 adds `tests/ui/panel.lua` and `tests/ui/panel-scene.txt`. It compares the
panel main page (M, W, L, S, XS, P), ALERTS, PAIR with and without a code, PAIRED
and ENROLL on the panel and under the pocket tabs with the `panel.py` fixtures,
and checks route A colours, one-row controls without overlap and whole labels at
eight sizes. `tests/parts/so-mod-panel.lua` runs it with ui3b and r3pocket.


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

## Per-device forget

`pair.list()` returns sorted `{ id, fingerprint }` rows. The fingerprint is the
first four uppercase hex characters of SHA-256 of the stored hex key string.
`pair.forget(id)` saves the remaining keys before changing memory and cancels
that id's pending pair2 exchange. It returns success and an optional save error.

`pair.forget(id, modules)` atomically saves key removal and pending cleanup in
`so-keys`. `forgetPending()` returns copied `{id,modules,key}` records;
`forgetDone(id)` removes a completed record. The old key is only for revoking
leases. Normal key lookup returns nil, and `remember` refuses pending ids.

`SO.forgetDevice(id, actor)` revokes the key first, then parks assignments through `mine.forget(id)`,
`lumber.forget(id)`, `build.forget(id)` and `drops.forget(id)`, clears reply
caches, and calls `lease.forget(id)` and `display.forget(id)`. Planner forget
calls return success and save a `forgotten` flag. Lease forget accepts the previous key as an optional second argument, sends a
best-effort stationary park after revocation, detaches callbacks and marks the
pose uncertain. Display forget deletes the session. Possibly occupied reservations
remain intact. Each hook runs under `pcall`. Pending cleanup retries at boot
before planning and before every tick's module work. Missing required modules
or failed hooks and completion saves keep the record pending. Other ids can
pair; the same id waits for cleanup. Retries do not recreate the forget row.
An initial key-save failure leaves keys and cleanup targets unchanged. Lumber suspends unused service queues through its existing safe
path and pauses only the forgotten worker. These are local calls, with no new wire handler.

A forgotten builder frees its active assignment slot. Another paired turtle can take the
slot with `add` using its known pose or an explicit pose. Reservations owned by the old
`build:<id>` remain protected after replacement and restart. Re-adding the same
forgotten turtle still requires an explicit pose.

Panel PAIR has a PAIRED button. Each session pages its own list and confirms
through a drawn FORGET then CONFIRM button within 15000 ms. Each confirmation
button carries a unique attempt token so delayed inputs cannot confirm a later
forget flow. It requires a paired
display session, checks the button coordinates and the current target key, and
rejects self-forget. `pair.forgotten` records the id and actor in state history
and supplies an attention row linking back to PAIR.

`drops.forget(id)` cancels that device's setup scan, chest visit, release probe
and facing selection. It hands all `setup:<id>` reservations to `gps:<id>`
before releasing the setup owner, including orphaned routes after restart.
Delayed steps may still arrive, so the full route stays protected until the
existing explicit re-add and `lease.clearProbe(id)` path clears recovery cells.
A failed handoff keeps the remaining reservations and leaves cleanup pending. The call returns
success and an optional save error. Other devices' setup state stays intact.
## Remote job scope

`so-server.cfg` `remoteDimensions=true` enables Nether and End mining and
lumber. It defaults to off. `home` and `area` accept an optional final dimension.
Dimension changes require a stopped job without assigned workers. Supply chests,
leases, reservations and dug marks stay in that dimension. The map offers a
per-display WORLD/NETHER/END control when enabled. AR uses `arDim`, the server
dimension, or overworld, in that order. It never overlays different dimensions.

Remote movement stays within Nether Y 1..126 and End Y 1..255. End turtles can
fly through open air above the void. Workers refuse fluid detected before a
move. Nether post-move scans stop beside observed lava and report its coordinates.
Fluid can still change between commands; the scan cannot inspect the occupied
block. Neither ender modems nor this feature load chunks. Silent remote leases
show `remote silent; unloaded?`, retain reservations and recover in place.
See [the operator guide](../README-SERVER-ONLY.md#nether-and-end-jobs).
