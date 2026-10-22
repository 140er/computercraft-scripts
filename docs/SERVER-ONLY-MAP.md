Read this first; explore only what it doesn't cover. Update it in the same PR when you change a module's public API.

# Server-only map

This maps the code on `origin/server-only`. One server computer owns durable
state and needs at least 16000000 bytes of disk. Workers and displays are thin,
paired clients. Workers must fit a 1 MB disk. All times use `os.epoch("utc")`.
The [[server-only/PROTOCOL]] ([protocol](server-only/PROTOCOL.md)) owns wire formats
and API details. Return to [[index]] ([start page](index.md)) for the wave plan.

## Files and public calls

Signatures use each returned library or `SO.mods.<name>`. Programs export no API.
Handlers use `handler(msg, reply)`, ticks use `tick(now)`,
and listeners use `listener(sender, message)`.

### Core and shared libraries

- [so-server.lua](../so-server.lua) boots the server, loads modules, authenticates
  dispatch and runs the event loop. No exported API. Built-in handlers are
  `pair(msg, reply)` and `hello(msg, reply)`.
- [so-proto.lua](../so-proto.lua) builds and checks authenticated envelopes.
  Calls are `encode(value)`, `decode(value)`, `build(key, t, body, rid)`,
  `sign(key, msg)`, `macOk(key, msg)`, `fresh(msg)`, `bind(keyFor)`,
  `request(target, t, body, timeout, tries)`, `canonical(msg)`, `ser(value)`,
  `sha256(msg)`, `hmac(key, msg)`, `hex(raw)` and `unhex(hex)`.
  `request` waits, so never call it from the server's handlers or ticks.
- [so-pair.lua](../so-pair.lua) pairs machines with X25519 and saves their keys.
  Calls are `open(proto, store)`, `derive(code, serverId, clientId)`,
  `pending()`, `clear()`, `key(id)`, `peer()`, `remember(id, key)`,
  `session(clientPubHex)`, `invite(screen)`, `join(code, serverId)` and
  `repairHint(sender, payload, serverId)`. The hint check only authorizes a prompt;
  it never removes a saved key.
  `join` is a client boot call that waits. Omitting `serverId` uses discovery.
  `peer()` returns the lowest saved numeric peer id, or nil. Workers use it
  as their server id when discovery fails.
- [so-store.lua](../so-store.lua) owns generation-based persistence.
  Calls are `copy(value)`, `read(path)` and `store(path, valid, limit)`.
  `store` returns `{ value, save = function(value) }`; `save` returns success
  and an optional error. `read` reads a plain Lua table without generation recovery.
- [so-log.lua](../so-log.lua) stores bounded event segments and snapshots for state.
  `open(store)` returns `{ snap, events(), append(ev), due(),
  checkpoint(payload), rawBytes() }`.
- [so-plan.lua](../so-plan.lua) provides pure geometry and batch helpers.
  Calls are `frame(worldPose, journalPose)`, `toWorld(frame, pose)`,
  `toJournal(frame, pose)`, `ahead(pose, dir)`, `apply(pose, op)`,
  `replay(startPose, steps, results)`, `path(from, to, opts)`, `chunk(steps, n)`,
  `inRange(lease, id, cells)`, `fuelValue(name)` and `free(inv)`.
  `park` is a ten-minute `inspectDown` lease template. Renew it with less than
  one minute remaining. Paths assume success; callers reserve cells and split
  work into batches of at most 16. See [plan helpers](server-only/PROTOCOL.md#plan-helpers).

- [so-mine-plan.lua](../so-mine-plan.lua) builds mining routes and next-step actions.
  Calls are `key(p)`, `same(a, b)`, `ore(d, ores)`, `junk(d)`, `distance(a, b)`,
  `cell(p, dir)`, `turn(p, want)`, `route(job, branch)`, `sealable(item)`,
  `cleanup(inv, all)`, `travel(from, goal, point, job?, row?)`,
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
  `travel(from, target, ground)` and `distance(a, b)`. `travel` returns the next
  service waypoint, with horizontal travel at ground plus two. `access` takes the chest's own coordinates. For `front`,
  it chooses the nearest unblocked horizontal neighbour by Manhattan distance
  and faces the chest. Ties use north, east, south, west order. For `down`,
  it uses the cell directly above the chest. It returns nil if all candidates
  are blocked. The lumber caller supplies the known-obstacle checks.

### Server modules

All modules return `{ name, handlers, tick, ... }`. Call another module only
from a handler or tick through `SO.mods.<name>`, after checking that the function
exists. Do not call other modules while files load or from listeners.
See [module APIs](server-only/PROTOCOL.md#module-apis).

- [so-mod-state.lua](../so-mod-state.lua), `state`, folds events into registry,
  jobs and views. Calls are `emit(kind, data)`, `get(path)`, `job(data)`,
  `view()`, `view(name, buildFn)`, `view.get(q)`, `view.sub(q)`, `canStart()`,
  `history.page(q)` and `tick(now)`. `view` is a callable table.
  `view.sub` returns a subscription with `stop()`. Query fields are `name`
  and `notify` for views, and `from`, `count` or `limit` for history.
  `canStart()` reads current disk use. Mining and lumber `start` refuse at 80%
  or more and show `disk >=80%; free space`. Existing work, recovery and stop
  remain available. No wire handlers. Built-in views are `fleet`, `turtle/<id>`,
  `log` and `status`.
  See [state](server-only/PROTOCOL.md#state).
- [so-mod-lease.lua](../so-mod-lease.lua), `lease`, dispatches worker batches
  without waiting. Calls are `send(id, steps, opts)`, `onReport(owner, fn)`,
  `status(id)`, `inRange(id, pos)` and `tick(now)`.
  `opts` accepts `ms`, `owner`, `recover` and expected world `pose`.
  Reports call `fn(leaseId, turtleId, results, lease)`; expiry passes nil results.
  Handlers are `step.report`, `beacon`, `hello` and `history.page`.
  Reports release lease-owned cells; silence leaves reservations in place.
  `status(id).uncertain` marks an unresolved worker pose; `send` then refuses
  all leases with `pose uncertain`, including recovery parks.
  `reanchor(id, worldPose)` sends an authenticated `worker.anchor` for an uncertain
  journal and retries until a matching hello confirms it. Mining/lumber `add`
  use it to replace an uncertain worker assignment with the operator-supplied pose.
  See [lease](server-only/PROTOCOL.md#lease).
- [so-mod-cells.lua](../so-mod-cells.lua), `cells`, owns reservations and dug marks.
  Calls are `reserve(who, x, y, z, dim)`, `reserveMany(who, cells)`,
  `release(who, x, y, z, dim)`, `releaseOwner(who)`, `forgetOwner(who)`,
  `owner(x, y, z, dim)`, `isFree(x, y, z, dim)`, `markDug(x, y, z, dim)`,
  `isDug(x, y, z, dim)`, `forget(x, y, z, dim)`, `counts()`,
  `list(who, max)` and `tick(now)`. `list` returns up to `max` copied
  `{ dim, x, y, z }` reservations, default 256.
  The optional dimension defaults to `minecraft:overworld`.
  Handler `cells.forget` requires a second, confirmed request.
  See [cells](server-only/PROTOCOL.md#cells).
- [so-mod-drops.lua](../so-mod-drops.lua), `drops`, owns drop points and inspect
  failure counts. Calls are `pick(kind, nearPos)`, `steps(point)`, `add(point)`,
  `remove(id)`, `fix(id)`, `note(id, blockName)`, `list()` and `tick(now)`.
  `list` copies every `{ id, dim, x, y, z, side, kind, broken }` point.
  Points use the chest's own coordinates. `front` accesses it from beside it
  at the same height; `down` accesses it from directly above.
  Handler `drops.edit` edits points. Tick registers the generic screen.
  The editor pages points to fit below navigation, reserves the bottom input row,
  and accepts typed coordinates or `add kind x y z [side] [dim]`.
  Drop-point dimensions are integers; cell and world-frame dimensions use strings.
  See [drops](server-only/PROTOCOL.md#drops).
- [so-mod-display.lua](../so-mod-display.lua), `display`, assigns roles and sends
  clipped frames. Calls are `screen(role, render, input)` and `tick(now)`.
  `render(w, h, clientId)` returns `{ rows, buttons }`; `input(event)` receives the drawn role,
  sender ID `from`, coordinates and button id or text. Handlers are `hello`, `view.sub`, `view.get`
  and `input`. Built-in screens are `generic` and `status`.
  The generic screen reserves two top rows for `mining`, `lumber`, `shop`,
  `status` and `ar`, with the drop editor below. Every destination has a visible
  `generic` button on 26x20 pockets and 29x12 monitors.
  See [display](server-only/PROTOCOL.md#display).
- [so-mod-shop.lua](../so-mod-shop.lua), `shop`, adapts the legacy Storage Room
  turtle to the shop screen. Only `tick(now)` is exported beyond module metadata.
  No `so` handlers. Listeners are `roomsorter`, `roomsorter_stock` and `dns`.
  Tick registers the shop screen, discovers storage and polls stock.
  See the [shop exception](server-only/PROTOCOL.md#shop).

- [so-mod-mine.lua](../so-mod-mine.lua), `mine`, runs branch mining and ore recovery.
  Only `tick(now)` is exported beyond module metadata; no wire handlers.
  Tick registers `display.screen("mining", render, input)` and
  `lease.onReport("mine", report)`. Cell owner tags are `mine:<id>`.
  Screen callbacks are `render()` and `input(event)`; reports use
  `report(leaseId, turtleId, results, lease)`. Jobs save to `so-data/mine/job`.
  New jobs default to `ores = {}`, which accepts all ores. A refused junk cleanup
  sets `cleanupBlocked` on that worker and sends excess junk through the next ore
  unload, retaining one suitable sealing stack. Completed routes
  unload remaining ore through the configured drop before parking.
  A lane pass reserves its full route through the shaft and spine plus its exit in one
  call. Intermediate batches retain the reservation until the worker leaves.
  Saved rows include `lane = { cells, entered, target?, release? }` while holding the lane
  and `laneWait = { at, passes }` while queued. Exit cleanup runs from tick;
  rapid report bursts defer further planning to tick. Oldest waiters go first, then
  lowest id; a waiter with three intervening grants has priority. Waiting rows
  show `wait lane`. Side veins wait until the worker leaves the shared lane.
  Saved turtle rows may contain `dropRetry = { key, tries, alerted, after }`.
  Fuel trips aim for 2000. If the chest empties sooner, the worker returns once
  its fuel covers the saved return route, the paused position's route home, and 64 more moves.
  Supply trips save `path` and `reserve` in the trip record. They use the lane queue
  and reserve the shared corridor, surface approach and branch exit through the
  chest turnaround and return. Private branch cells use normal movement batches.
  Route searches read only the in-memory block lookup. Home routes and vein access
  cache by pose, route waypoint and mine geometry; stationary ticks and chest
  candidates reuse them. Fuel reports use the saved trip path and reserve.
  Trips using the shared corridor defer report planning to tick. Moves outside the lane release one private
  cell per report for trips using the shared corridor, keeping reservation cleanup
  below the cells burst threshold. Trips wholly on the surface retain normal batching.
  Three failures at one drop emit `mine.alert { id, text }`, show the error,
  and park with one retry per minute. Missing drops use the same delay.
  See [[server-only/PROTOCOL#mine]] ([mining](server-only/PROTOCOL.md#mine)).
- [so-mod-lumber.lua](../so-mod-lumber.lua), `lumber`, scans, harvests and replants trees.
  Only `tick(now)` is exported beyond module metadata; no wire handlers.
  Tick registers `display.screen("lumber", render, input)` and
  `lease.onReport("lumber", report)`. Cell owner tags are `lumber:<id>`.
  Screen callbacks are `render()` and `input(event)`; reports use
  `report(leaseId, turtleId, results, lease)`. Jobs save to `so-data/lumber/job`.
  Restart recovery sends a stationary park using the saved frame without a
  volatile lease pose or range proof. Its report rebuilds the world pose before
  work resumes. Work leases still require the range and reservation checks.
  Three failed moves or digs hold and emit `lumber.alert`. Holds show that
  `start` is required after fixing the cause. Fuel trips reserve the route
  distance plus 32 fuel. Wood service removes junk and excess saplings while
  preserving one per known spot of each species and the current tree.
  Log delivery counts require a successful drop report and an inventory decrease.
  Wood and supply inspections call `drops.note`. Sapling service reuses a matching
  drop point or registers a stable `storage` point for the drop editor.
  See [[server-only/PROTOCOL#lumber]] ([lumber](server-only/PROTOCOL.md#lumber)).

- [so-mod-ar.lua](../so-mod-ar.lua), `ar`, draws server data on attached cc_ar
  controllers. Only `tick(now)` is exported beyond module metadata. No wire handlers.
  Tick registers `display.screen("ar", render, input)` with `turtles`, `leases`,
  `drops` and `alerts` toggles. Switches save through `so-store` to `so-data/ar`.
  Discovery runs at most every five seconds; changed scenes redraw at most once
  per second. Failed controllers are dropped until discovery. Known server
  dimensions filter world elements. See [AR](server-only/PROTOCOL.md#ar).

### Thin clients

- [worker.lua](../worker.lua) executes `lease.batch`, sends `hello`, `step.report`
  and `beacon`, journals steps, and backs up after work lease expiry. No exported API.
  A single `inspectDown` marks a stationary park. When it expires, the worker
  stays put and beacons every 30 seconds, retaining its move history.
  Paired boots retry discovery and hello with backoff capped at 30 seconds,
  using the saved server id if discovery fails. They show `waiting for server`
  until an authenticated reply arrives. A `pair.required` hint also offers a code
  prompt while retaining the saved key until a new pairing succeeds. Otherwise
  only unpaired boots prompt for a code. That prompt keeps retrying discovery
  while accepting digits and Enter. Idle workers send hello every 30 seconds
  without authenticated replies to detect a later server key reset.
  Drop and suck operations on every side require an adjacent inventory. Missing
  inventories return `no inventory` and leave items in the turtle.
  At boot, pending moves use saved fuel or GPS to resolve their outcome. Turns
  or missing evidence stay uncertain. The worker reports that fact, keeps the
  pending entry, and refuses further steps without moving or backtracking.
  An operator re-adds it with its actual pose to clear uncertainty. The worker
  saves that anchor and clears old move/dug history before confirming it.
  It accepts authenticated server batches, not planner decisions. Keep it small
  and add no new turtle files.
- [display.lua](../display.lua) pairs, sends `hello` and `view.sub`, draws
  `view.frame` and sends `input`. No exported API. It handles touch, clicks,
  text and resize events. Pairing prompts and digits appear on the display and
  its computer terminal. Failed pairing accepts a new code. A `pair.required`
  hint shows the same prompt without deleting the old key. Authenticated frames
  dismiss the hint and restore the normal screen. Discovery and
  stale-frame hello/subscribe retries use backoff capped at 30 seconds. At boot,
  it prefers the lowest saved paired server ID and retries that ID without DNS.
  It opens every modem and rescans on attach and detach events. Screens
  at least three rows tall reserve the bottom row for typed input and report
  the remaining height in `hello`. Wall displays also echo input on the terminal.

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
  `so-lumber-plan.lua` and every root `so-mod-*.lua`, including `so-mod-ar.lua`.
  Current modules are ar, cells, display, drops, lease, lumber, mine, shop and
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
The installer uses GPS or manual coordinates and a dimension prompt.
Updates do not replace this config or any runtime state.

All downloads stage in `/.so-new/<path>`. A failed fetch or compile removes
staging without changing installed files. `/.so-old/manifest` records target
paths and whether they existed before the swap. Old copies move under
`/.so-old/` before staged copies move into place. Recovery restores backups and
removes newly introduced targets unless `/.so-new/committed` exists. That marker
means every target was moved and recovery only finishes cleanup. The next
installer invocation and installed startup both recover before continuing.
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
4. The P key opens pairing. The one-second timer expires reply-cache entries,
   refreshes the pairing prompt and calls every `tick(now)` in filename order.
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
SO11 scenario B uses length-48 mining branches and grown trees, cuts inside a server call at the first observed instant after 240 seconds with three open work leases, then checks four minutes of recovery after two minutes down, including lane exclusion and exactly-once interrupted dug reports.

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
sh tools/check-scope.sh origin/server-only HEAD
```

Keep each Lua file under 185 locals, including enclosing functions, for Cobalt's
200-local ceiling. Commit before the scope check so `HEAD` includes the change.
Offline tests do not prove in-game behavior. State which AGENTS.md gates could
not run and which Minecraft or client checks remain unavailable in the PR.

## Open gaps

- Lease state is memory-only. Planner recovery must use park leases and account
  for reservations that survived the restart.
- SO3 mining, SO7 lumber, SO9 installer and SO10 AR are implemented.
