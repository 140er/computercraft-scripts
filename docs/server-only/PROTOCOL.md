# so protocol

Rednet protocol name is `so`. The server hosts that protocol as `server`. One server runs `so-server.lua` on a computer whose disk is at least 16000000 bytes. Turtles, pocket computers, and monitors keep no state that matters after a reboot. After a reboot the server tells them what to do.

Time is `os.epoch("utc")` in milliseconds. Do not use `os.time` or in-game days.

Every rednet payload is the table returned by `so-proto.encode`. `encode` checks the table and returns a copy. `decode` accepts a table and returns nil for anything else. A string payload is dropped. `so-proto.ser` is only the canonical bytes for the MAC.

`rid` is at most 64 characters. `body` is at most 8 tables deep, counting the body table itself. The canonical form of the accepted envelope is at most 16384 bytes. A 1 MB string field or a deeper body is dropped. The server keeps answering later messages.

```lua
{ v = 1, t = "<type>", rid = "<request id>", from = <computer id>, at = <utc ms>, mac = "<hex>", body = {} }
```

`v` is 1. `t` is the message type. `rid` is a non-empty string. `from` is the sender computer id and it matches the rednet sender id. `at` is utc milliseconds. `body` is a table. `mac` is 64 lowercase hex characters.

## MAC and replay

The shared secret is the per-machine key from pairing. On disk the key is 64 hex characters. The MAC key is those 32 raw bytes.

The signed bytes are the canonical encoding of `{ v, t, rid, from, at, body }` with `mac` left out. `mac` is HMAC-SHA256 of those bytes, written as lowercase hex.

Canonical encoding is a Lua literal. String values use `%q`. Whole numbers use `%d`. Other numbers use `%.17g`. Booleans are `true` and `false`. Table keys are sorted by `type(key) .. ":" .. tostring(key)`. A cycle is an error. Two tables that differ only in key order encode to the same string.

The server drops a bad MAC and prints `so-server: bad mac from <id>`. It does not answer. A pair message is checked with `pair.derive` of the code on screen and the sender id. A retry of a pair `rid` that still has a saved reply is checked with the handshake key stored beside that reply. Any other message is checked with the key saved for `from`. No key is a bad MAC. A pair with no live code and no saved handshake key for that `rid` is a bad MAC.

`at` must be within 60000 ms of the receiver's `os.epoch("utc")`. A larger gap is dropped as `so-server: bad message from <id>`.

After a good MAC, the server remembers each `rid` for that `from` for 120000 ms. The window is the age of the rid, not a fixed count of entries. A repeated `rid` with no saved reply is dropped and logged as `so-server: replay from <id>`. The server does not answer. A bad MAC does not enter this window.

The server keeps the encoded reply for each `(from, rid)` for 120000 ms. A later message with that same `from` and `rid` is sent the saved reply again. The handler does not run a second time.

`so-proto.request(target, t, body, timeout, tries)` builds one message and sends that same table, with the same `rid`, on every try. `timeout` is seconds per try. `tries` is how many sends to make. Omitted values are 3 seconds and 1 try. The call yields on `os.pullEvent`. Events that are not the matching reply stay consumed, so the caller runs `request` in its own coroutine with `parallel.waitForAny`. A handler on the server must not call `request`, because the server loop is already waiting on `os.pullEvent`. A module sends with `SO.proto.build` and `rednet.send`. A matching reply must verify under the key for `target`. The return is the reply envelope, or `nil` and `timeout` or `no key`.

A reply reuses the request `rid`. `from` on the reply is the computer that answered. The first `reply(t, body)` wins. Later calls do nothing.

A payload that is not a table, or an envelope that fails `decode`, is dropped and logged as `so-server: bad message from <id>`. The same line is used when `from` does not match the rednet sender.

## Message types

Send every message below through `so-proto`. Do not add a field here without editing this file.

### pair

The joining computer sends `pair` to the server. `body.pub` is its X25519 public key, 64 lowercase hex characters. The code is not a field.

The server answers `ack` when the MAC matches the live code. `body.ok` is `true`. `body.pub` is the server public key, 64 lowercase hex characters. `body.proof` is HMAC-SHA256, keyed by the 6-digit code, over the bytes `so-pair-v2\0`, then the client public key, then the server public key. Those public keys are the raw 32-byte values, not the hex text. `proof` is 64 lowercase hex characters. The server then clears the code.

The envelope MAC on that `pair` and its `ack` uses the handshake key from `pair.derive`, not the stored machine key. A retry of the same `rid` gets the saved `ack` again. The server keeps that handshake key for 120000 ms next to the saved reply, so the retry still verifies after the code is cleared. A new `rid` for an id that already has a key needs a new code. A different computer needs a new code.

### hello

A paired computer sends `hello` to the server.

`body.role` is an optional string. `body.label` is an optional string.

`body.w` and `body.h` are optional positive integers. They are the display size in character cells, from `getSize`. The display module reads them. It does not treat `body.role` as the screen assignment.

A turtle also sends these fields.

`body.fuel` is a number, or the string `unlimited`.

`body.free` is how many of the 16 slots are empty.

`body.inv` lists the occupied slots. Each entry is `{ slot = number, name = string, count = number }`.

`body.gps` is optional. When a GPS answers, it is `{ x = number, y = number, z = number }`.

`body.journal` is the turtle's journal. `journal.id` is a string. `journal.seq` is a number. `journal.pose` is `{ x = number, y = number, z = number, f = number }` in the turtle's own frame since boot. `f` is 0 north, 1 east, 2 south, 3 west. `journal.moves` is the last 32 completed moves, oldest first. Each move is `{ n = number, op = string, ok = true }`. `op` is `forward`, `back`, `up`, `down`, `turnLeft`, or `turnRight`. `journal.dug` is the last 32 cells this turtle dug. Each entry is `{ x = number, y = number, z = number }`. `journal.pending` is optional. It is `{ n = number, op = string, lease = string }` when a step was started and not finished.

The server answers `ack`.

### ack

`body.ok` is `true`. A reply to `drops.edit` also sets `body.id` to the point id.

### err

The server sends `err` when no built-in handler and no module handler matches `t`.

`body.code` is `unknown`. `body.text` is `unknown type`.

`body.code` is `store` when the server could not save a new pair key. `body.text` is the store error.

`body.code` is `pair` when `body.pub` is not a 32-byte key. `body.text` is `pub`.

### lease.batch

The server sends `lease.batch` to a turtle.

`body.lease` is a string. `body.expires` is utc milliseconds. `body.steps` is an array of 1 to 16 steps. SO3 checks the length.

A step is a table.

`op` is one of `forward`, `back`, `up`, `down`, `turnLeft`, `turnRight`, `dig`, `digUp`, `digDown`, `place`, `placeUp`, `placeDown`, `suck`, `suckDown`, `drop`, `dropDown`, `refuel`, `select`, `inspect`, `inspectUp`, `inspectDown`.

`slot` is optional. It is an integer from 1 to 16. `select` uses it. Other ops use the already selected slot.

`n` is an optional integer. `refuel`, `drop`, `dropDown`, `suck`, and `suckDown` use it as a count.

### step.report

The turtle sends `step.report` to the server.

`body.lease` is the lease string from `lease.batch`. `body.results` is one table per step, in the same order.

`results[i].ok` is a boolean. `results[i].err` is an optional string. `results[i].data` is an optional table. For a successful inspect, `data.name` is the block name when a block is present.

`results[i].counts` is an optional array of 16 numbers, the item count in slots 1 to 16 after the step.

`results[i].err` is `expired` when the step was not run because `lease.batch` `expires` had passed. Later steps in that batch use the same error.

### beacon

The turtle broadcasts `beacon`.

`body.id` is its computer id. `body.fuel` is a number. Unlimited fuel is sent as `-1`. `body.journal` is a string, the last journal id it knows.

The MAC still uses that turtle's paired key. The server can verify it. SO0 has no beacon handler, so the server answers `err` until SO2 registers one.

### view.get

A display sends `view.get` to the server.

`body.role` is ignored. The server answers one `view.frame` for the role stored for that computer. That answer does not subscribe the display.

### view.sub

A display sends `view.sub` to the server.

`body` is `{}`. `body.role` is ignored. The server uses the role stored for that computer. A computer with no stored role is `generic`.

SO5 sends the current `view.frame` when the display subscribes, and again every 4 seconds while the subscription lasts. It also sends a frame when the picture changes. A repeat may keep the same `rev`.

### view.frame

The server sends `view.frame` to a display.

`body.rev` is a number. It grows when the picture changes. A repeat of the same picture keeps the same `rev`.

`body.role` is `shop`, `mining`, `status`, or `generic`. It is the screen that was drawn.

`body.rows` is the draw list. Each row is `{ text = string, fg = string, bg = string }`.

`body.buttons` is a list of `{ id = string, x = number, y = number, w = number, label = string }`. The list may be empty.

`x` and `y` are 1-based character coordinates. `w` is the width in characters. A button is one row tall.

`fg` and `bg` are CC blit strings. One character paints the whole row. A string the same length as `text` paints each character.

### input

A display sends `input` to the server. It does not wait.

`body.id` is the button id, or absent when the player submitted text. `body.text` is that text, or absent for a button. `body.x` and `body.y` are 1-based character coordinates.

`body.role` is ignored. The server uses the role stored for that computer.

### drops.edit

A paired computer sends `drops.edit` to the server. The payload is the table from `so-proto.encode`. A string payload is dropped. The server answers `ack` or `err`.

`body.op` is `add`, `remove`, or `fix`.

For `add`, `body.id` is a string of letters, digits, underscore, and hyphen. `body.dim`, `body.x`, `body.y`, and `body.z` are integers. `body.side` is `front` or `down`. `body.kind` is `fuel`, `ore`, `junk`, `wood`, `storage`, or `any`.

For `remove` and `fix`, `body.id` is that point id.

`ack` has `body.ok` true and `body.id` set to the point id. A second `add` of the same id and the same fields is `ack` and does not create a second point. `remove` of an unknown id is `ack`.

`err` uses `body.code` `full` and `body.text` `64 points` when the point would be the 65th. `body.code` `bad` and `body.text` `bad field` when a field is missing or not in the set. `body.code` `kind` and `body.text` `bad kind` for a kind outside the set. `body.code` `side` and `body.text` `bad side` for a side outside `front` and `down`, including `up`. `body.code` `exists` and `body.text` `id exists` when that id is already stored with different fields. `body.code` `missing` and `body.text` `missing point` when `fix` names no point. `body.code` `store` when the registry could not be saved. `body.text` is then the store error.

### history.page

The caller sends `history.page` to the server.

`body.before` is an optional utc millisecond. Omit it to start at the newest entry. `body.limit` is an optional integer from 1 to 50. The default is 20.

The reply type is `history.page`. `body.entries` is `{ at = number, text = string }`, newest first. `body.next` is a number, or absent on the last page. Pass `next` as `before` to read the following page.

## Module APIs

`so-server` sets the global `SO` before it loads modules.

`SO.proto`, `SO.pair`, and `SO.store` are the three libraries. `SO.mods[name]` is the table that module returned. A module calls another module from a handler or from `tick`. It does not call another module from the top of its file. Files load in sorted name order, and `SO.mods[name]` is set after that file returns.

A module returns one table.

```lua
{
  name = "state",
  handlers = { ["type.name"] = function(msg, reply) end },
  tick = function(now) end,
}
```

`msg` is the decoded envelope. `reply(t, body)` sends one reply. `now` is utc milliseconds. `tick` runs once each second from `os.startTimer(1)`. A late timer does not run the missed seconds. `tick` returns quickly.

Built-in `pair` and `hello` run first. Module handlers for that same type run next, in file name order. All of them run. Unknown `t` gets `err`.

### state

SO1 owns this API on `SO.mods.state`. It also owns `so-log.lua`.

`state.emit(kind, data)` appends one event and folds it into the current state. `kind` is a string. `data` is a value `so-store` can save. The call returns true, or false and an error string. A false return changes nothing. The revision is the event sequence number. `emit(key, value)` is this same call.

`state.get(key)` returns the last value stored under that key, or nil.

`state.get(path)` also walks the machine registry. `machines`, `machines/<id>`, and `machines/<id>/<field>` read the registry. Dots work the same way as slashes.

`state.view()` with no arguments returns `{ rev = number, values = table }`. `values` is a shallow copy of the top key table.

`state.view(name, buildFn)` declares a named view. `buildFn` receives `{ rev, values, machines, jobs }` and returns the view data. The names `fleet`, `log`, `status`, and `turtle/<id>` stay built in.

`state.view.get({ name = string })` returns one frame `{ t = "view.frame", name, rev, at, data }`. `rev` is the event sequence. `at` is utc milliseconds. This frame is in-process. It is not a rednet `view.frame`.

`state.view.sub({ name = string, notify = function })` subscribes to that view. On a change, SO1 calls `notify(frame)`. The frame `rev` is greater than the previous frame for that subscriber. Two frames for one subscriber are at least 500 ms apart, so a subscriber gets at most 2 frames per second. `tick` sends a frame that was held back once the gap has passed.

`state.history.page({ from = number, count = number })` returns `{ entries, next }`. `entries` is `{ seq, at, kind, data }` in ascending `seq`, starting after `from`. Omit `from` to start at the oldest retained event. `count` defaults to 20 and is clamped to 1..50. `next` is the last `seq` in this page when another page exists, and nil on the last page. Pass `next` as `from` to read the following page. `limit` is accepted as an alias of `count`.

`state.job(data)` is `emit("job", data)`, except when the disk is 80% full or more. Then it returns false and `"disk"` and does not write the job. `emit("job", data)` follows the same rule.

`state.tick(now)` flushes held view frames. `now` is utc milliseconds. The server passes it once a second.

#### Events

Every accepted `emit` is one event `{ seq, at, kind, data }` in the log. `seq` starts at 1. `at` is utc milliseconds.

`kind` `machine` merges a registry row. `data` is `{ id, role, fp, seen, fuel, pose }`. `id` is the computer id. Fields left out stay as they were. Missing `seen` becomes the event time. Missing `fp` becomes the sha256 hex of that computer's paired key when the key is known.

`kind` `pose` sets the turtle pose. `data` is `{ id, dim, x, y, z, facing }`.

`kind` `job` appends a job. Any other `kind` stores `data` under that key for `get`.

#### Views

`fleet` is every machine row, sorted by id. Each row is `{ id, role, fp, seen, fuel, pose }`.

`turtle/<id>` is one machine row, or nil when that id is unknown.

`log` is the last 50 retained events, oldest first. Each entry is `{ seq, at, kind, data }`.

`status` is `{ capacity, used, free, ratio, alerts, accepting }`. `ratio` is `used / capacity`. `alerts` contains `"disk"` when `ratio` is 0.8 or more. `accepting` is false in that case.

#### Log files

Events live in segment files of at most 64 KB under `so-data/log/`. SO1 writes a snapshot of the folded state every 2000 events under `so-data/snap/`. On boot it loads the newest valid snapshot and applies later segment events. Live segment bytes stay at or under 1 MB. Older segments are deleted only after the snapshot that covers them is on disk. A crash during a segment write loses at most that one event. A failed write returns false and the error. SO1 does not drop it silently.

When the disk is 80% full or more, `status` raises the disk alert and new jobs are refused. Other events are still written while the disk accepts them.

SO1 handles no wire types. SO5 owns wire `view.get`, `view.sub`, `view.frame`, and `input`. SO6 owns wire `history.page`.

### lease

`SO.mods.lease` dispatches worker batches. Planners call it from handlers or ticks.

`lease.send(id, steps, opts)` sends 1..16 steps through `so-proto` without waiting. `opts` has optional `ms`, `owner`, and `pose = { dim, x, y, z, facing }`. The default duration is 60000 ms. It returns a lease id `<id>-<n>`, or nil and a reason. An open lease returns `busy`. A beaconing turtle returns `lost`. Invalid arguments, an absent pair key, or a failed send also return nil and a reason.

`lease.onReport(owner, fn)` registers one callback for an owner tag. It receives `(leaseId, turtleId, results, lease)`. The lease record has `id`, `turtleId`, `steps`, `owner`, `pose`, `expires`, and `status`. Status is `reported` after a report and `expired` after silence. A later registration replaces the callback.

A matching `step.report` closes the lease and calls `cells.releaseOwner(leaseId)` when present. Every result must have a boolean `ok`, and there must be one result per step. Only a full successful report emits `pose` with the turtle id and expected pose. It also updates the known range. The callback runs once. Unknown, closed, or wrong-sender reports have no effects. Ignored reports log once per turtle.

`lease.status(id)` returns `{ open, lost, range, seen }`. `open` is the lease id or nil. `seen` is the last accepted report, beacon, or hello time in utc milliseconds, or 0 before contact. `lease.inRange(id, pos)` checks the distance from the server against that turtle's range plus 8 blocks. A known dimension mismatch returns false. The first known turtle pose sets its range. Later observations only increase it. The initial fallback is 16 blocks.

The server position comes from the plain `so-server.cfg` table `{ pos = { dim, x, y, z } }`, read through `so-store`. Without it, the module tries `gps.locate(2)`. Without either position, every range check returns true and the module logs that once at load.

A `beacon` marks the authenticated sender lost, retains its journal id, and emits `machine` with its id, fuel, seen time, and journal. The body id cannot select another turtle. `hello` clears lost and uses `body.gps` or `body.pose` as a known pose. An open lease remains open until a report or expiry.

`tick(now)` closes a silent lease after `expires + 10000` and calls its owner with nil results. It keeps the cells reserved. The planner decides how to recover them. The module also answers wire `history.page` with `state.history.page(body)`, including SO1's sequence-based entries and cursor.

Lease records, callbacks, beacon journals, and observed ranges live in memory. A server restart clears them. Planners must recover reservations before sending new work after a restart.

### cells

SO4 owns this API on `SO.mods.cells`. Coordinates are numbers.

`cells.reserve(who, x, y, z)` returns true, or false and an error string. `who` is a computer id or a lease string.

`cells.release(who, x, y, z)` returns true.

`cells.isFree(x, y, z)` returns a boolean.

`cells.markDug(x, y, z)` records a dug block.

`cells.isDug(x, y, z)` returns a boolean.

`cells.forget(x, y, z)` drops both the reservation and the dug mark.

The SO0 stub returns true from `reserve`, `release`, and `isFree`. `isDug` returns false. `markDug` and `forget` do nothing.

### display

SO5 owns this API on `SO.mods.display`.

`display.screen(role, render, input)` registers one screen. `role` is a string. A second call for the same role replaces the first. `render` is called with no arguments and returns `{ rows, buttons }`. The module sets `rev` and `body.role`, and clips the picture to the `hello` size. `input` accepts `{ id, x, y, role }` and optional `text`. `role` in that table is the screen that was showing.

Button id `generic` returns that display to the generic screen. The generic screen's buttons are `shop`, `mining`, `status`, and `generic`.

The module stores each computer's role in `so-display`. The default is `generic`. The file survives a restart.

### drops

SO8 owns this API on `SO.mods.drops`. It handles `drops.edit`.

`drops.pick(kind, nearPos)` takes a kind string and `nearPos = { dim, x, y, z }`, all integers. Kind is `fuel`, `ore`, `junk`, `wood`, `storage`, or `any`. It returns `{ point, chain, alert }`. `point` is `{ id, dim, x, y, z, side, kind }` for the nearest usable place, or nil. Usable means the same dimension and fewer than 3 inspect failures. The chain is the requested kind, then `any`, then the string `hold`. When the requested kind is `any`, that stage appears once. Each stage before `hold` is `{ kind, point, usable }`. `point` on the result is the first usable stage. When no stage is usable, `point` is nil and `alert` is `drops: hold <kind>`. That call also emits `drops.alert` with `{ kind, text }` when `SO.mods.state.emit` is a function. A call whose first argument is not a string returns nil. `tests/so/so0.lua` calls `pick({ name = "minecraft:cobble", n = 1 })` and gets nil.

`drops.steps(point)` takes a point. Side `front` returns `{ { op = "inspect" }, { op = "drop" } }`. Side `down` returns `{ { op = "inspectDown" }, { op = "dropDown" } }`. A call with no string `id` returns `{}`, including `steps({ name = "minecraft:cobble", n = 1, where = "front" })`.

`drops.add(point)` takes `{ id, dim, x, y, z, side, kind }`. It returns true, or false and a string. The 65th distinct id returns false and `full`. The same id with the same fields returns true and does not add a second point or change the failure count. Side `up` returns false and `side`.

`drops.remove(id)` returns true. A missing id returns true.

`drops.fix(id)` sets the failure count to 0 and returns true, or returns false and `missing`.

`drops.note(id, blockName)` records one inspect while the failure count is below 3. A non-empty string clears that count. Nil counts one failure. The third failure makes `pick` skip the point. Further notes leave it skipped. `fix` clears it. A successful inspect does not clear a point that is already at 3.

The list is saved through `so-store` in the file `so-drops`. A change emits `drops` with `{ op, id }` when `state.emit` exists.

## Pairing and so-keys

The server screen shows `Press P to pair`. The P key calls `pair.invite(screen)`. That draws a 6-digit code and the server id, and prints `Pair code: <digits> server <id>`. The code includes leading zeros. It is 4 crypto random bytes, read as a big-endian integer modulo 1000000. It works once and expires after 300000 ms. Five `pair` messages with a bad MAC burn the code. When it is spent, expired, or burned, the screen shows `Press P to pair` again. Re-pairing an id that already has a key needs a new press of P.

`pair.derive(code, serverId, clientId)` returns the handshake key used only to MAC the pair exchange.

```text
sha256("so-pair-hs-v2\0" .. serverId .. "\0" .. clientId .. "\0" .. code)
```

`serverId` and `clientId` are the decimal computer ids. The result is 64 lowercase hex characters. It is not the stored machine key.

Each side generates an X25519 key pair. The shared secret is `exchange(ourSecret, theirPublic)`. The stored machine key is sha256 of that 32-byte secret, written as 64 lowercase hex characters. A listener that records every pair message and knows the code cannot compute it.

X25519 comes from ccryptolib, MIT, Copyright (c) 2023 Miguel Oliveira. `lib/ccryptolib/random.lua` is the upstream file except its load-time seed mix, which calls `os.clock` instead of `os.day` and `os.time`. The vendored files are:

- `lib/ccryptolib/LICENSE`
- `lib/ccryptolib/x25519.lua`
- `lib/ccryptolib/random.lua`
- `lib/ccryptolib/blake3.lua`
- `lib/ccryptolib/chacha20.lua`
- `lib/ccryptolib/config.lua`
- `lib/ccryptolib/internal/util.lua`
- `lib/ccryptolib/internal/hw.lua`
- `lib/ccryptolib/internal/curve25519.lua`
- `lib/ccryptolib/internal/fp.lua`
- `lib/ccryptolib/internal/edwards25519.lua`
- `lib/ccryptolib/internal/packing.lua`

`pair.join(code)` looks up `so` / `server`. `pair.join(code, serverId)` sends to `serverId` and does not call `rednet.lookup`. Both send `pair`, check `body.proof`, and save the machine key after `ack`.

Keys live in `so-keys` through `so-store`. The saved value is `{ keys = { ["<computer id>"] = "<64 hex>" } }`. On the server, the id is the paired machine. On the machine, the id is the server. The file budget is 200000 bytes.

`pair.key(id)` returns that hex string, or nil.

## Store

`so-store.store(path, valid, budget)` loads the newest valid generation from `path`, `path .. ".tmp"`, and `path .. ".bak"`. The file is `{ schema = 1, generation = number, value = ... }`. `valid(value)` must be true. A present file with no valid generation is an error.

`save(value)` writes a temp file, reads it back, and moves it into place. The previous file becomes `path .. ".bak"`.

`budget` is the maximum encoded file size in bytes. The default is 900000. A larger write returns false and `budget exceeded`. The current file is unchanged and later saves still work. A failed disk write returns false and blocks later saves until restart.

Callers save through `so-store` only. Do not save inside a tight loop.

## Disk and missing parts

`so-server` reads `fs.getCapacity("/")` before it loads anything else. Under 16000000 bytes it prints these two lines and returns.

```text
so-server: need 16000000 bytes, this disk has <cap>.
Set computer_space_limit in computercraft-server.toml to at least 16000000, then restart the world.
```

Set `computer_space_limit` in `computercraft-server.toml` on the NeoForge server, then restart the world. 16000000 boots. 1000000 and 8000000 do not.

A missing modem prints `so-server: no modem`. The process still ticks. A missing `so-mod-*.lua` file is normal. A module file that errors, or that does not return `{ name = string, handlers = table }`, prints `so-server: skip <file>` and the server continues. A missing `so-proto.lua`, `so-pair.lua`, or `so-store.lua` prints `so-server: missing <file>` and returns. A copy that fails to load prints `so-server: <file> failed: <error>` and returns.

The core does not call Advanced Peripherals, cc_ar, or Tom's Peripherals.

## Tasks

SO0 owns `so-proto.lua`, `so-pair.lua`, `so-store.lua`, `so-server.lua`, and `tests/so/harness.lua`. It handles `pair`, `hello`, `ack`, and `err`.

SO1 owns `so-mod-state.lua` and `so-log.lua`. It handles no wire types. It owns `state.emit`, `state.get`, `state.view`, `state.job`, and `state.history.page`.

SO2 owns `so-mod-beacon.lua`. It handles `beacon` on the server and writes fuel and journal through `state.emit`.

SO3 owns `so-mod-lease.lua`. It sends `lease.batch` and handles `step.report`.

SO4 owns `so-mod-cells.lua`. It handles no wire types. It owns `cells.reserve`, `cells.release`, `cells.isFree`, `cells.markDug`, `cells.isDug`, and `cells.forget`.

SO5 owns `so-mod-display.lua`. It handles `view.get`, `view.sub`, `view.frame`, and `input`. It owns `display.screen`.

SO6 owns `so-mod-history.lua`. It handles `history.page`.

SO7 owns `so-turtle.lua`, the turtle program, not a server module. It receives `lease.batch` and sends `step.report` and `beacon`. It stores nothing it cannot rebuild from the next lease.

SO8 owns `so-mod-drops.lua`. It handles `drops.edit`. It owns `drops.pick`, `drops.steps`, `drops.add`, `drops.remove`, `drops.fix`, and `drops.note`.

SO9 owns `so-mod-fuel.lua`. It handles no wire types. It reads beacon fuel from `state` and decides when a turtle should refuel.

SO10 owns `so-mod-jobs.lua`. It handles no wire types. It turns a job into lease steps and asks SO3 to send them.

SO1, SO4, SO5, and SO8 replace the stub file and keep the calls above. The other tasks add their files.
