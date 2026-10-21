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

`results[i].ok` is a boolean. `results[i].err` is an optional string. `results[i].data` is an optional table. For a successful inspect, `data.name` is the block name. `data.tags` contains at most eight matching tags as `[tag] = true`. The allowed tags are `c:ores`, `forge:ores`, `minecraft:logs`, `minecraft:leaves`, `minecraft:saplings`, `minecraft:dirt`, `c:chests`, `forge:chests`, and any tag beginning with `c:ores/` or `forge:ores/`. The worker retains the fixed tags before subtype tags. If the full report would exceed the envelope limit, it removes the longest subtype tags until it fits. `data.level` is the numeric `state.level` when present. A water or lava source has level 0.

`results[i].counts` is an optional array of 16 numbers, the item count in slots 1 to 16 after the step.

`results[i].err` is `expired` when the step was not run because `lease.batch` `expires` had passed. Later steps in that batch use the same error.

`body.pose` is `{ x, y, z, f }` in the journal frame after the last step. `body.journal` is the journal id. `body.fuel` is the numeric fuel level, or `-1` for unlimited. `body.inv` is the occupied-slot list `{ { slot, name, count }, ... }`. `body.dug` is the last 32 dug cells `{ { x, y, z }, ... }` in the journal frame. The worker reads these facts once after the batch, including when a step failed or expired.

### beacon

The turtle broadcasts `beacon`.

`body.id` is its computer id. `body.fuel` is a number. Unlimited fuel is sent as `-1`. `body.journal` is a string, the last journal id it knows. `body.pose` is `{ x, y, z, f }` in that journal frame.

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
  listen = { ["other-protocol"] = function(sender, message) end },
}
```

`msg` is the decoded envelope. `reply(t, body)` sends one reply. `now` is utc milliseconds. `tick` runs once each second from `os.startTimer(1)`. A late timer does not run the missed seconds. `tick` returns quickly.

Built-in `pair` and `hello` run first. Module handlers for that same type run next, in file name order. All of them run. Unknown `t` gets `err`.

`listen` is optional. For rednet protocols other than `so`, the server calls each matching listener in file name order inside `pcall`. A failed listener is logged and later listeners still run. The server sends `so` messages through authenticated dispatch only, even if a module declares `listen.so`. Listeners return without waiting. A listener records incoming data; cross-module calls still belong in handlers or `tick`.

### shop

`so-mod-shop.lua` registers the `shop` display role through `display.screen` from its first tick. It keeps stock, search text, order replies and trend samples in memory. Restarting the server clears them.

The module finds the existing, unpaired Storage Room turtle through DNS or the sender of a `roomsorter_stock` broadcast. Until found, its tick broadcasts `{ sType = "lookup", sProtocol = "roomsorter" }` on `dns` every 10 seconds without waiting. Its `dns` listener selects the sender of `{ sType = "lookup response", sProtocol = "roomsorter" }` only while no turtle is known. Before discovery the screen shows `Storage room not found, still looking`.

The legacy turtle uses plain rednet. This is an exception to the `so-proto` envelope. The shop sends `{ cmd = "stock", rid = number }` on `roomsorter` every 10 seconds after discovery. Replies carry that `rid` and `{ version, totals, state, crafty, cutoff, recipes, orders }`. Broadcasts on `roomsorter_stock` carry `{ totals, used, size, chests, furnaces, state, full }`. Only the selected turtle updates the stock.

The screen shows storage state and items sorted by descending count, with item name as the tie breaker. Submitted text filters names without case sensitivity; spaces match underscores. Each item has buttons for 1, 16 and 64. A button sends `{ cmd = "order", text = itemName, n = count, rid = number }` on `roomsorter` once. The module matches replies by sender and request id. It shows each reply line with `Order: ` until the next order. Orders are never retried automatically. An unanswered order shows a timeout after two minutes.

Each item keeps at most 60 samples, one per minute. Its `^`, `v` or `-` compares current stock with the oldest retained sample, about an hour ago once the history fills. Before an hour of history exists, it compares with the earliest available sample.

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

`lease.send(id, steps, opts)` sends 1..16 steps through `so-proto` without waiting. `opts` has optional `ms`, `owner`, `recover`, and `pose = { dim, x, y, z, facing }`. The default duration is 60000 ms. It returns a lease id `<id>-<n>`, or nil and a reason. An open lease returns `busy`. A beaconing turtle returns `lost` unless `opts.recover` is true. Recovery still refuses an open lease with `busy`. Invalid arguments, an absent pair key, or a failed send also return nil and a reason.

`lease.onReport(owner, fn)` registers one callback for an owner tag. It receives `(leaseId, turtleId, results, lease)`. The lease record has `id`, `turtleId`, `steps`, `owner`, `pose`, `expires`, and `status`. Status is `reported` after a report and `expired` after silence. An accepted report stores `lease.report = { pose, journal, fuel, inv, dug }`. Each field is type-checked independently. A bad field is omitted while valid fields remain. These facts are stored for successful batches and batches with failed or expired steps. A later registration replaces the callback.

An accepted `step.report` clears lost. A matching `step.report` closes the lease and calls `cells.releaseOwner(leaseId)` when present. Every result must have a boolean `ok`, and there must be one result per step. Only a full successful report emits `pose` with the turtle id and expected pose. It also updates the known range. The callback runs once. Unknown, closed, or wrong-sender reports have no effects. Ignored reports log once per turtle.

`lease.status(id)` returns `{ open, lost, range, seen, pose, journal, poseAt }`. `pose` is the newest valid journal pose `{ x, y, z, f }` observed in an accepted report, beacon, or hello. Hello supplies `body.journal.pose` and `body.journal.id`. `journal` is the latest valid journal id. `poseAt` is the local utc millisecond time when the pose was observed, or nil before any valid pose. A changed journal id without a valid pose clears `pose` and `poseAt` so planners cannot reuse coordinates from the old frame. `open` is the lease id or nil. `seen` is the last accepted report, beacon, or hello time in utc milliseconds, or 0 before contact. `lease.inRange(id, pos)` checks the distance from the server against that turtle's range plus 8 blocks. A known dimension mismatch returns false. The first known turtle pose sets its range. Later observations only increase it. The initial fallback is 16 blocks.

The server position comes from the plain `so-server.cfg` table `{ pos = { dim, x, y, z } }`, read through `so-store`. Without it, the module tries `gps.locate(2)`. Without either position, every range check returns true and the module logs that once at load.

A `beacon` marks the authenticated sender lost, retains its journal id, and emits `machine` with its id, fuel, seen time, and journal. The body id cannot select another turtle. `hello` clears lost and uses `body.gps` or `body.pose` as a known pose. An open lease remains open until a report or expiry.

`tick(now)` closes a silent lease after `expires + 10000` and calls its owner with nil results. It keeps the cells reserved. The planner decides how to recover them. The module also answers wire `history.page` with `state.history.page(body)`, including SO1's sequence-based entries and cursor.

Lease records, callbacks, beacon journals, and observed ranges live in memory. A server restart clears them. Planners must recover reservations before sending new work after a restart.

### cells

SO4 owns this API on `SO.mods.cells`. Coordinates are integer block positions. All one-cell calls accept an optional last `dim` string, defaulting to `minecraft:overworld`. The same coordinates in different dimensions are separate cells. `who` is a computer id or a lease string.

`cells.reserve(who, x, y, z, dim)` returns true, or false and `held` if another owner holds the cell. Reserving a cell already held by `who` succeeds.

`cells.reserveMany(who, cells)` takes `{ {dim, x, y, z}, ... }`. It reserves all cells or changes nothing. A conflict returns false, `held`, and the conflicting input cell.

`cells.release(who, x, y, z, dim)` returns true. It frees the cell only when `who` holds it. `cells.releaseOwner(who)` frees all cells held by that owner. Silence never expires a reservation.

`cells.owner(x, y, z, dim)` returns the owner or nil. `cells.isFree(x, y, z, dim)` returns a boolean.

`cells.markDug(x, y, z, dim)` records a dug block. Repeating it does not increase the dug count. `cells.isDug(x, y, z, dim)` returns a boolean.

`cells.forget(x, y, z, dim)` drops both the reservation and the dug mark. `cells.forgetOwner(who)` frees that owner's reservations and emits state event `cells.forget` with `{ who, count }`. Direct API calls queue the event until tick. Dug marks remain.

`cells.counts()` returns `{ reserved = { [who] = n }, dug = n }`. Tick registers a `cells` state view returning these counts when `state.view` is callable.

Reservations save through `so-store` to `so-data/cells/res` on each change and reload on boot. Dug marks save per 16x16x16 section to `so-data/cells/<dim>/<sx>_<sy>_<sz>`. Dimension names replace `:` for valid paths. The cache holds at most 256 sections. Eviction saves a changed section before removing it. Tick saves at most eight changed sections. Bulk loading yields.

Wire type `cells.forget` takes `{ who }` and replies with `{ confirm = token }` without freeing anything. The same sender must send `{ who, confirm = token }` within 30 seconds. A valid confirmation runs `forgetOwner`. Invalid, expired, reused, or mismatched confirmations reply with `err`.

### display

SO5 owns this API on `SO.mods.display`.

`display.screen(role, render, input)` registers one screen. `role` is a string. A second call for the same role replaces the first. `render` is called with no arguments and returns `{ rows, buttons }`. The module sets `rev` and `body.role`, and clips the picture to the `hello` size. `input` accepts `{ id, x, y, role }` and optional `text`. `role` in that table is the screen that was showing.

Button id `generic` returns that display to the generic screen. The generic screen's buttons are `shop`, `mining`, `status`, `generic`, and `lumber`.

The module stores each computer's role in `so-display`. The default is `generic`. The file survives a restart.

### lumber

`SO.mods.lumber` plans a tree farm for one paired worker with an axe. It is stopped until the operator configures it and sends `start`. It uses `so-plan.lua` and the pure helpers in `so-lumber-plan.lua`.

The `lumber` display accepts these text commands:

- `area <x1> <z1> <x2> <z2> <ground y>` sets the farm bounds and soil height.
- `saplings <x> <y> <z> <front|down>` sets the turtle access cell for the sapling chest.
- `add <id> <x> <y> <z> <n|e|s|w>` anchors one worker. A recovery park report supplies the journal pose for `P.frame`.
- `start` begins work. `stop` parks after the current lease reports.

The job saves through `so-store` at `so-data/lumber/job`. It contains `dim`, `area`, `ground`, `saplings`, `turtle = { id, frame, pose }`, and `spots`, keyed by `"x,z"` with `{ kind, plantedAt }`. It also stores the planner phase, progress, inventory facts, and delivery count for recovery. A restart recovers the worker with a park lease before continuing from its reported pose.

The planner sends at most one lease, tagged `lumber`. It reserves cells under `lumber:<id>` and checks every planned cell with `P.inRange`. Lost or expired leases require recovery. Idle workers receive `P.park`.

Search rows are three blocks apart at soil height plus two. Probes find logs at soil height plus one and remember their spots. Dark oak is excluded. The worker fells each column and replants the matching sapling from above. Movement inspects before digging and permits only logs, leaves, and small plants. Soil and stone remain intact. Planted spots become eligible again after ten minutes.

An empty sapling chest disables replanting while felling continues. It emits `lumber.alert` with `{ text = "out of saplings" }` once. Wood goes to `drops.pick("wood", pose)` using `drops.steps(point)` after each round or when fewer than three inventory slots remain. Saplings stay in the turtle. A `hold` result parks and raises an alert. Low fuel uses a fuel drop and `P.fuelValue`; logs are never burned.

The screen shows state, logs delivered, saplings carried, known and planted spots, fuel, and the last alert. Lost workers and range failures appear in red. Successful deliveries emit `lumber.logs` with `{ id, count }`. Alerts emit `lumber.alert` with `{ text }`.

### drops

SO8 owns this API on `SO.mods.drops`. It handles `drops.edit`.

`drops.pick(kind, nearPos)` takes a kind string and `nearPos = { dim, x, y, z }`, all integers. Kind is `fuel`, `ore`, `junk`, `wood`, `storage`, or `any`. It returns `{ point, chain, alert }`. `point` is `{ id, dim, x, y, z, side, kind }` for the nearest usable place, or nil. Usable means the same dimension and fewer than 3 inspect failures. The chain is the requested kind, then `any`, then the string `hold`. When the requested kind is `any`, that stage appears once. Each stage before `hold` is `{ kind, point, usable }`. `point` on the result is the first usable stage. When no stage is usable, `point` is nil and `alert` is `drops: hold <kind>`. That call also emits `drops.alert` with `{ kind, text }` when `SO.mods.state.emit` is a function. A call whose first argument is not a string returns nil. `tests/so/so0.lua` calls `pick({ name = "minecraft:cobble", n = 1 })` and gets nil.

`drops.steps(point)` takes a point. Side `front` returns `{ { op = "inspect" }, { op = "drop" } }`. Side `down` returns `{ { op = "inspectDown" }, { op = "dropDown" } }`. A call with no string `id` returns `{}`, including `steps({ name = "minecraft:cobble", n = 1, where = "front" })`.

`drops.add(point)` takes `{ id, dim, x, y, z, side, kind }`. It returns true, or false and a string. The 65th distinct id returns false and `full`. The same id with the same fields returns true and does not add a second point or change the failure count. Side `up` returns false and `side`.

`drops.remove(id)` returns true. A missing id returns true.

`drops.fix(id)` sets the failure count to 0 and returns true, or returns false and `missing`.

`drops.note(id, blockName)` records one inspect while the failure count is below 3. A non-empty string clears that count. Nil counts one failure. The third failure makes `pick` skip the point. Further notes leave it skipped. `fix` clears it. A successful inspect does not clear a point that is already at 3.

The list is saved through `so-store` in the file `so-drops`. A change emits `drops` with `{ op, id }` when `state.emit` exists.

## Plan helpers

Planners load `local P = dofile("so-plan.lua")`. This library is pure Lua. It does not use `SO`, rednet, waits, or storage. Facing is 0 north, 1 east, 2 south, and 3 west. North decreases z and east increases x.

`P.frame(worldPose, journalPose)` anchors a journal frame at a known world pose. World poses use `{ dim, x, y, z, facing }` and journal poses use `{ x, y, z, f }`. The frame is `{ dim, rot, ox, oy, oz }`. `rot` is the clockwise quarter-turn count. `P.toWorld(frame, journalPose)` converts to a world pose. `P.toJournal(frame, worldPose)` is its inverse.

`P.ahead(pose, dir)` returns the x, y, z of the cell `forward`, `back`, `up`, or `down`. `P.apply(pose, op)` returns a new pose after a move or turn. Other operations leave the pose unchanged. Both accept world or journal poses and preserve the facing field convention. `P.replay(startPose, steps, results)` applies only operations with a corresponding successful result.

`P.path(from, to, opts)` returns `{ steps, cells, pose }`. It turns and moves to the target cell in axis order `opts.order`, default `"yxz"`. An order must contain x, y, and z once each. With `opts.dig = true`, each move follows `dig`, `digUp`, or `digDown` as appropriate. `cells` lists every entered cell with its dimension. `pose` is the final pose. The path assumes success and does not avoid obstacles or reserve cells. Callers split steps into batches of at most 16. `P.chunk(steps, n)` returns the first n steps and the remainder as two arrays.

`P.inRange(lease, id, cells)` calls `lease.inRange(id, cell)` for every cell and returns false if any check fails. It returns true if the lease module or its range function is missing.

`P.park` is `{ steps = { { op = "inspectDown" } }, ms = 600000 }`. Planners send it to idle turtles and renew it when less than 60000 ms remains. An expired lease makes the worker beacon and back up its last moves.

`P.fuelValue(name)` returns fuel per item for Minecraft coal and charcoal as 80, coal blocks as 800, lava buckets as 1000, and blaze rods as 120. Other names return 0. `P.free(inv)` returns the number of empty slots among the turtle's 16 slots using the occupied-slot report list.

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

- SO0 owns `so-proto.lua`, `so-pair.lua`, `so-store.lua`, `so-server.lua`, and the harness.
- SO1 owns `so-mod-state.lua` and `so-log.lua`.
- SO2 owns `worker.lua`, the turtle program.
- SO3 owns `so-mod-mine.lua`, the mining planner.
- SO4 owns `so-mod-cells.lua`.
- SO5 owns `display.lua` and `so-mod-display.lua`.
- SO6 owns `so-mod-shop.lua`.
- SO7 owns `so-mod-lumber.lua`.
- SO8 owns `so-mod-drops.lua`.
- SO9 owns `install.lua`.
- SO10 owns `so-mod-ar.lua`.
- W3-B owns `so-mod-lease.lua`. It sends `lease.batch` and handles `step.report`, `beacon`, and `history.page`.
- W4-0 owns worker report facts, lease recovery facts, and the shared `so-plan.lua` helpers. It adds no planner.
