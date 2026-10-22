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
  `pending()`, `clear()`, `key(id)`, `remember(id, key)`,
  `session(clientPubHex)`, `invite(screen)` and `join(code, serverId)`.
  `join` is a client boot call that waits. Omitting `serverId` uses discovery.
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
  `cleanup(inv, all)`, `travel(from, goal, point)`, `next(job, row, lookup, inv, fuel)`,
  `lane(job, exit)`, `inLane(job, pos)` and `lanePass(job, row)`.
  `lane` lists the shared shaft column and bottom spine through the furthest
  assigned junction, plus an optional exit. `inLane` tests that geometry;
  `lanePass` lists the cells crossed in the planned pass through its exit.
  `ores` is the supported ore-name set. The optional `ore` filter uses those names.
  `next` batches known straight travel and turns, ending at inspect or dig report
  boundaries. Multi-action results include `actions` with one-based `first` step indices.
- [so-lumber-plan.lua](../so-lumber-plan.lua) classifies trees and plans scans and chest access.
  Calls are `isLog(block)`, `isLeaves(block)`, `isSapling(name)`, `saplingFor(name)`,
  `canDig(block)`, `scan(area, ground, dim)`, `access(point, near, blocked)`
  and `distance(a, b)`.

- [so-ui.lua](../so-ui.lua) is the server-only Big Tiles kit. Calls are
  `size(w, h)`, `grid(w, h, columns?)`, `ink(bg)`, `glyph(ch, ink, bg)`,
  `canvas(w, h, bg?)`, `status(model, w, h)` and `alert(model, w, h)`.
  `palette` and `font` expose the spec tables. Grid returns one-based `{ x, w }`
  columns and a tile-row count. Glyph returns three blit rows with inverted cells.
  Canvas methods are `put`, `fill`, `center`, `big`, `hit`, `header`, `alert`,
  `tile`, `button`, `listRow`, `search` and `frame`. Coordinates are one-based.
  `frame()` returns compact rows, rectangular buttons and the palette.
  See [display](server-only/PROTOCOL.md#display) for the status model.

### Server modules

All modules return `{ name, handlers, tick, ... }`. Call another module only
from a handler or tick through `SO.mods.<name>`, after checking that the function
exists. Do not call other modules while files load or from listeners.
See [module APIs](server-only/PROTOCOL.md#module-apis).

- [so-mod-state.lua](../so-mod-state.lua), `state`, folds events into registry,
  jobs and views. Calls are `emit(kind, data)`, `get(path)`, `job(data)`,
  `view()`, `view(name, buildFn)`, `view.get(q)`, `view.sub(q)`,
  `history.page(q)` and `tick(now)`. `view` is a callable table.
  `view.sub` returns a subscription with `stop()`. Query fields are `name`
  and `notify` for views, and `from`, `count` or `limit` for history.
  No wire handlers. Built-in views are `fleet`, `turtle/<id>`, `log` and `status`.
  See [state](server-only/PROTOCOL.md#state).
- [so-mod-lease.lua](../so-mod-lease.lua), `lease`, dispatches worker batches
  without waiting. Calls are `send(id, steps, opts)`, `onReport(owner, fn)`,
  `status(id)`, `inRange(id, pos)` and `tick(now)`.
  `opts` accepts `ms`, `owner`, `recover` and expected world `pose`.
  Reports call `fn(leaseId, turtleId, results, lease)`; expiry passes nil results.
  Handlers are `step.report`, `beacon`, `hello` and `history.page`.
  Reports release lease-owned cells; silence leaves reservations in place.
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
  Handler `drops.edit` edits points. Tick registers the generic screen.
  The Big Tiles list selects the first broken point by default, or the first
  point when none are broken. Row taps select FIX and REMOVE targets. ADD NEW
  opens the draft editor and navigation to mining, lumber, shop and AR. BACK
  returns the list to status and the editor to the list. Long lists have paging.
  Drop-point dimensions are integers; cell and world-frame dimensions use strings.
  See [drops](server-only/PROTOCOL.md#drops).
- [so-mod-display.lua](../so-mod-display.lua), `display`, assigns roles and sends
  clipped frames. Calls are `screen(role, render, input)`, `screen(role)`, `far(id, on)`, `tick(now)`,
  `terminal(model, view, w, h)` and `monitorTouch(side, x, y)`.
  `terminal` returns a pure frame. The view supplies `id`, `mode` as normal,
  code or log, `uptime`, `log`, `offset`, `code`, `expires` and `now`.
  `monitorTouch` queues local input for the next tick. Tick discovers a local
  monitor at most every five seconds and draws at scale 0.5 with local navigation,
  without rednet or saved role changes. Tick also draws `SO.terminal` once a second.
  `screen(role)` returns the registered `{ render, input }` callbacks or nil.
  `far` saves a per-computer flag and returns success plus an optional save error.
  `palette` exposes the Big Tiles RGB table at numeric indices 0 through 15.
  `render(w, h, session?)` returns `{ rows, buttons, palette? }`; `input(event)` receives the drawn role,
  coordinates, button id or text, and the same server-local `session`. Handlers are `hello`, `view.sub`, `view.get`
  and `input`. Built-in screens are `generic` and `status`.
  Button id `status` returns any screen to status. Generic screens with their
  own `lumber` and `ar` buttons keep them. The drops list reaches those roles
  through ADD NEW and suppresses header injection; older generic screens retain
  the fallback buttons. Generic screens at least 39 columns wide gain a PANEL
  header button when they do not already provide one.
  Render signatures and revisions are isolated by role and size. Status also
  isolates paging and alert takeover state per display session. Panel frames also
  isolate revisions per session. A roleless 26x20 display defaults to status. Its
  glance row pages three tiles at a time with `prev` and `next`; `panel` selects
  panel mode. Explicit saved roles take precedence. Gather runs in
  handlers or ticks and reads state, leases, drops, sessions and server disk use.
  Ore and log totals have no source and use stale tiles. A missing kit retains
  the legacy status renderer for older partial installations.
  See [display](server-only/PROTOCOL.md#display).
- [so-mod-panel.lua](../so-mod-panel.lua), `panel`, registers the panel screen from
  `tick(now)`. No wire handlers or other exported calls. The screen keeps search,
  main/alerts/pair pages and alert paging in each display session. Tick gathers
  registered screen callbacks and job header states, plus state `.alert` values.
  Main-page inputs forward START and STOP once to the mining or lumber screen.
  Orders apply the local search to the shop screen, render its first page, select
  the first item and send one `order:<count>:<name>` input. Shop's count/name sort
  defines the best match. Missing screens have grey blocks without action targets.
  GLANCE returns to status; ALERTS lists state alerts; PAIR explains server pairing.
  Larger screens arrange the same controls using the kit grid. No saved panel file.
  See [panel](server-only/PROTOCOL.md#panel).
- [so-mod-shop.lua](../so-mod-shop.lua), `shop`, adapts the legacy Storage Room
  turtle to the shop screen. Only `tick(now)` is exported beyond module metadata.
  No `so` handlers. Listeners are `roomsorter`, `roomsorter_stock` and `dns`.
  Tick registers the shop screen, discovers storage and polls stock.
  Render callbacks use `render(w, h)`. The Big Tiles list opens an item with
  `item:<name>`; its order page uses `order:<count>:<name>` and `items` to return.
  List controls are `prev`, `next`, `clear`, `search` and `status` for BACK.
  Submitted text resets paging. The kit-free renderer retains the legacy list.
  See the [shop exception](server-only/PROTOCOL.md#shop).

- [so-mod-mine.lua](../so-mod-mine.lua), `mine`, runs branch mining and ore recovery.
  Only `tick(now)` is exported beyond module metadata; no wire handlers.
  Tick registers `display.screen("mining", render, input)` and
  `lease.onReport("mine", report)`. Cell owner tags are `mine:<id>`.
  Mining uses Big Tiles with START, STOP, SETUP and BACK. SETUP has a local
  BACK button; typed commands work on both pages. Daily ore totals have no
  source and use a stale tile. Missing kits retain the legacy renderer.
  Screen callbacks are `render(w, h)` and `input(event)`; reports use
  `report(leaseId, turtleId, results, lease)`. Jobs save to `so-data/mine/job`.
  New jobs default to `ores = {}`, which accepts all ores. Completed routes
  unload remaining ore through the configured drop before parking.
  A lane pass reserves its full route through the shaft and spine plus its exit in one
  call. Intermediate batches retain the reservation until the worker leaves.
  Saved rows include `lane = { cells, entered, target?, release? }` while holding the lane
  and `laneWait = { at, passes }` while queued. Exit cleanup runs from tick;
  rapid report bursts defer further planning to tick. Oldest waiters go first, then
  lowest id; a waiter with three intervening grants has priority. Waiting rows
  show `wait lane`. Side veins wait until the worker leaves the shared lane.
  Saved turtle rows may contain `dropRetry = { key, tries, alerted, after }`.
  Three failures at one drop emit `mine.alert { id, text }`, show the error,
  and park with one retry per minute. Missing drops use the same delay.
  See [[server-only/PROTOCOL#mine]] ([mining](server-only/PROTOCOL.md#mine)).
- [so-mod-lumber.lua](../so-mod-lumber.lua), `lumber`, scans, harvests and replants trees.
  Only `tick(now)` is exported beyond module metadata; no wire handlers.
  Tick registers `display.screen("lumber", render, input)` and
  `lease.onReport("lumber", report)`. Cell owner tags are `lumber:<id>`.
  Screen callbacks are `render(w, h)` and `input(event)`; reports use
  `report(leaseId, turtleId, results, lease)`. Jobs save to `so-data/lumber/job`.
  The Big Tiles screen gathers job state into a pure layout. START and STOP use
  the text command path. SETUP pages configuration commands; its BACK returns
  to lumber. Main BACK uses `status`. Missing grow timers use a stale tile.
  Logs are delivered totals, not daily totals. Calls without a size retain
  the legacy rows for older callers.
  Restart recovery sends a stationary park using the saved frame without a
  volatile lease pose or range proof. Its report rebuilds the world pose before
  work resumes. Work leases still require the range and reservation checks.
  See [[server-only/PROTOCOL#lumber]] ([lumber](server-only/PROTOCOL.md#lumber)).

- [so-mod-ar.lua](../so-mod-ar.lua), `ar`, draws server data on attached cc_ar
  controllers. Only `tick(now)` is exported beyond module metadata. No wire handlers.
  Tick registers `display.screen("ar", render, input)` with `turtles`, `leases`,
  `drops` and `alerts` toggles. The screen shows controller count, on/off tiles
  and BACK to status. Small screens use compact tiles. Switches save through
  `so-store` to `so-data/ar`.
  Discovery runs at most every five seconds; changed scenes redraw at most once
  per second. Failed controllers are dropped until discovery. Known server
  dimensions filter world elements. See [AR](server-only/PROTOCOL.md#ar).

### Thin clients

- [worker.lua](../worker.lua) executes `lease.batch`, sends `hello`, `step.report`
  and `beacon`, journals steps, and backs up after lease expiry. No exported API.
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
  `so-lumber-plan.lua`, `so-ui.lua` and every root `so-mod-*.lua`, including `so-mod-ar.lua` and `so-mod-panel.lua`.
  Current modules are ar, cells, display, drops, lease, lumber, mine, panel, shop and
  state. Only a regular computer with at least 16000000 bytes of capacity can
  install this role.

`/.so-role` contains the plain role name. `startup.lua` runs installer recovery,
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
loads root `so-mod-*.lua` files in sorted filename order, then opens the modem
and hosts rednet protocol `so` as `server`. Missing or invalid modules are skipped.

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

Handlers, listeners and ticks run inside `pcall`; a failure logs and the loop
continues. Never wait inside them. `sleep(0)`, `sleep(n)`, `rednet.lookup`,
`rednet.receive` and filtered `os.pullEvent` calls consume unrelated events
while this single coroutine waits. That can discard reports, beacons or keys.
Yield only during a real burst of work, never on the first call. Copy
`so-mod-cells.lua`'s `S.pause` pattern, which resets after an idle gap and yields
only after accumulated work or elapsed burst time.

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
it into place. A budget rejection leaves the store usable; a disk-write failure
blocks later saves until restart. Do not save inside tight loops.

- `so-keys` holds paired keys on server and clients. Pairing loads
  `lib/ccryptolib/` for X25519 and randomness.
- `so-server.cfg` is the plain server-position table read through `so-store.read`.
- `so-data/log/<segment>` holds events. `so-data/snap/<snapshot>` and
  `so-data/snap/latest` hold folded state and its snapshot pointer.
  Segments are at most 64 KB, retained segment bytes at most 1 MB, and snapshots
  occur every 2000 events or when retention needs one. New jobs stop at 80% disk use.
- `so-data/cells/res` holds reservations. Dug marks live in
  `so-data/cells/<escaped-dim>/<sx>_<sy>_<sz>` for 16-cube sections.
  The cache holds at most 256 sections; tick saves at most eight dirty sections.
- `so-drops` holds drop points and failure counts.
- `so-display` holds `{ roles = { [stringId] = role }, far = { [stringId] = true } }`.
  Roles include `panel`. Old files without `far` remain valid.
  Far displays use scale 1; others use 0.5.
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
same. SO11 treats every handler, listener or tick wait as a check 7 failure,
including the cells module's accumulated `sleep(0)` burst yields.
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

## Open gaps

- Lease state is memory-only. Planner recovery must use park leases and account
  for reservations that survived the restart.
- SO3 mining, SO7 lumber, SO9 installer and SO10 AR are implemented.
