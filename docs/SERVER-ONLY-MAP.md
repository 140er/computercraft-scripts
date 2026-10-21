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
  Calls are `key(p)`, `same(a, b)`, `ore(d)`, `junk(d)`, `distance(a, b)`,
  `cell(p, dir)`, `turn(p, want)`, `route(job, branch)`, `sealable(item)`,
  `cleanup(inv, all)`, `travel(from, goal, point)` and `next(job, row, lookup, inv, fuel)`.
  `ores` is the supported ore-name set.
- [so-lumber-plan.lua](../so-lumber-plan.lua) classifies trees and plans scans and chest access.
  Calls are `isLog(block)`, `isLeaves(block)`, `isSapling(name)`, `saplingFor(name)`,
  `canDig(block)`, `scan(area, ground, dim)`, `access(point, near, blocked)`
  and `distance(a, b)`.

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
  `isDug(x, y, z, dim)`, `forget(x, y, z, dim)`, `counts()` and `tick(now)`.
  The optional dimension defaults to `minecraft:overworld`.
  Handler `cells.forget` requires a second, confirmed request.
  See [cells](server-only/PROTOCOL.md#cells).
- [so-mod-drops.lua](../so-mod-drops.lua), `drops`, owns drop points and inspect
  failure counts. Calls are `pick(kind, nearPos)`, `steps(point)`, `add(point)`,
  `remove(id)`, `fix(id)`, `note(id, blockName)` and `tick(now)`.
  Handler `drops.edit` edits points. Tick registers the generic screen.
  Drop-point dimensions are integers; cell and world-frame dimensions use strings.
  See [drops](server-only/PROTOCOL.md#drops).
- [so-mod-display.lua](../so-mod-display.lua), `display`, assigns roles and sends
  clipped frames. Calls are `screen(role, render, input)` and `tick(now)`.
  `render()` returns `{ rows, buttons }`; `input(event)` receives the drawn role,
  coordinates and button id or text. Handlers are `hello`, `view.sub`, `view.get`
  and `input`. Built-in screens are `generic` and `status`.
  The generic screen includes a `lumber` button, including with the drops screen.
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
  See [[server-only/PROTOCOL#mine]] ([mining](server-only/PROTOCOL.md#mine)).
- [so-mod-lumber.lua](../so-mod-lumber.lua), `lumber`, scans, harvests and replants trees.
  Only `tick(now)` is exported beyond module metadata; no wire handlers.
  Tick registers `display.screen("lumber", render, input)` and
  `lease.onReport("lumber", report)`. Cell owner tags are `lumber:<id>`.
  Screen callbacks are `render()` and `input(event)`; reports use
  `report(leaseId, turtleId, results, lease)`. Jobs save to `so-data/lumber/job`.
  See [[server-only/PROTOCOL#lumber]] ([lumber](server-only/PROTOCOL.md#lumber)).

### Thin clients

- [worker.lua](../worker.lua) executes `lease.batch`, sends `hello`, `step.report`
  and `beacon`, journals steps, and backs up after lease expiry. No exported API.
  It accepts authenticated server batches, not planner decisions. Keep it small
  and add no new turtle files.
- [display.lua](../display.lua) pairs, sends `hello` and `view.sub`, draws
  `view.frame` and sends `input`. No exported API. It handles touch, clicks,
  text and resize events, and retries when its frame becomes stale.

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
  `so-lumber-plan.lua` and every root `so-mod-*.lua`. Current modules are cells,
  display, drops, lease, lumber, mine, shop and state. Only a regular computer
  with at least 16000000 bytes of capacity can install this role.

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
`install reset` requires `yes` and deletes everything except `install.lua`
and `/rom`, including pairing keys. SO9 tests check role coverage, dependency
closure, client size, download validation, crash recovery and state preservation.

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
4. The P key opens pairing. The one-second timer expires reply-cache entries,
   refreshes the pairing prompt and calls every `tick(now)` in filename order.
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
- `so-drops` holds drop points and failure counts. `so-display` holds screen roles.
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
The full suite takes roughly three minutes.

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
- SO3 mining, SO7 lumber and SO9 installer are implemented. SO10 AR remains.
  `so-mod-ar.lua` is still absent.
