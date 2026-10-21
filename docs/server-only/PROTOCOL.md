# so protocol

Rednet protocol name is `so`. The server hosts that protocol as `server`. One server runs `so-server.lua` on a computer whose disk is at least 16000000 bytes. Turtles, pocket computers, and monitors keep no state that matters after a reboot. After a reboot the server tells them what to do.

Time is `os.epoch("utc")` in milliseconds. Do not use `os.time` or in-game days.

Every rednet payload is a string from `so-proto.encode`. The string is at most 16384 bytes. A longer string is dropped. The decoded value is one table, the envelope.

```lua
{ v = 1, t = "<type>", rid = "<request id>", from = <computer id>, at = <utc ms>, mac = "<hex>", body = {} }
```

`v` is 1. `t` is the message type. `rid` is a non-empty string. `from` is the sender computer id and it matches the rednet sender id. `at` is utc milliseconds. `body` is a table. `mac` is 64 lowercase hex characters.

## MAC and replay

The shared secret is the per-machine key from pairing. On disk the key is 64 hex characters. The MAC key is those 32 raw bytes.

The signed bytes are the canonical encoding of `{ v, t, rid, from, at, body }` with `mac` left out. `mac` is HMAC-SHA256 of those bytes, written as lowercase hex.

Canonical encoding is a Lua literal. String values use `%q`. Whole numbers use `%d`. Other numbers use `%.17g`. Booleans are `true` and `false`. Table keys are sorted by `type(key) .. ":" .. tostring(key)`. A cycle is an error. Two tables that differ only in key order encode to the same string.

The server drops a bad MAC and prints `so-server: bad mac from <id>`. It does not answer. A pair message is checked with the key derived from the code on screen and the sender id. Any other message is checked with the key saved for `from`. No key is a bad MAC.

After a good MAC, the server remembers the last 256 `rid` values per `from`. A repeated `rid` is dropped and logged as `so-server: replay from <id>`. The server does not answer. A bad MAC does not enter this window.

`so-proto.request(target, t, body, timeout, tries)` sends to `target` and waits for a reply with the same `rid`. `timeout` is seconds per try. `tries` is how many sends to make. Omitted values are 3 seconds and 1 try. The call yields on `os.pullEvent`. Events that are not the matching reply stay consumed. A handler on the server must not call `request`, because the server loop is already waiting on `os.pullEvent`. A module sends with `SO.proto.build` and `rednet.send`. A matching reply must verify under the key for `target`. The return is the reply envelope, or `nil` and `timeout` or `no key`.

A reply reuses the request `rid`. `from` on the reply is the computer that answered. The first `reply(t, body)` wins. Later calls do nothing.

A payload that is not a string, or an envelope that fails `decode`, is dropped and logged as `so-server: bad message from <id>`. The same line is used when `from` does not match the rednet sender.

## Message types

Send every message below through `so-proto`. Do not add a field here without editing this file.

### pair

The joining computer sends `pair` to the server. `body` is `{}`. The code is not a field.

The server answers `ack` when the MAC matches the code on its screen. It then clears that code. The same computer may send `pair` again with a new `rid` if it missed the ack. The saved key still verifies. A different computer needs a new code.

### hello

A paired computer sends `hello` to the server.

`body.role` is an optional string. `body.label` is an optional string.

The server answers `ack`.

### ack

`body.ok` is `true`.

### err

The server sends `err` when no built-in handler and no module handler matches `t`.

`body.code` is `unknown`. `body.text` is `unknown type`.

`body.code` is `store` when the server could not save a new pair key. `body.text` is the store error.

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

### beacon

The turtle broadcasts `beacon`.

`body.id` is its computer id. `body.fuel` is a number. `body.journal` is a string, the last journal id it knows.

The MAC still uses that turtle's paired key. The server can verify it. SO0 has no beacon handler, so the server answers `err` until SO2 registers one.

### view.get

A display sends `view.get` to the server.

`body.role` is the screen role string.

The server answers `view.frame` when SO5 handles it.

### view.sub

A display sends `view.sub` to the server.

`body.role` is the screen role string.

SO5 then sends `view.frame` when that role's picture changes.

### view.frame

The server sends `view.frame` to a display.

`body.rev` is a number. It grows when the picture changes.

`body.rows` is the draw list. Each row is `{ text = string, fg = string, bg = string }`.

`body.buttons` is `{ id = string, x = number, y = number, w = number, label = string }`.

`x` and `y` are 1-based character coordinates. `w` is the width in characters. A button is one row tall.

`fg` and `bg` are CC blit strings. One character paints the whole row. A string the same length as `text` paints each character.

### input

A display sends `input` to the server. It does not wait.

`body.role` is the screen role. `body.id` is the button id, or absent for a bare click. `body.x` and `body.y` are 1-based character coordinates.

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

`display.screen(role, render, input)` registers one screen. `role` is a string. `render` returns the `view.frame` body `{ rev, rows, buttons }`. `input` accepts `{ id, x, y, role }`.

The SO0 stub accepts the three arguments and does nothing with them.

### drops

SO8 owns this API on `SO.mods.drops`.

`drops.pick(want)` takes `want = { name = string, n = number }` and returns `{ name = string, n = number, slot = number }`, or nil when nothing matches.

`drops.steps(action)` takes `action = { name = string, n = number, where = "front" or "up" or "down" }` and returns a step list. The list may be empty.

The SO0 stub returns nil from `pick` and `{}` from `steps`.

## Pairing and so-keys

`pair.invite(screen)` draws a 6-digit code on `screen` and prints `Pair code: <digits>`. The code includes leading zeros. One successful pair from a new computer clears it.

Both sides derive the same key.

```text
sha256("so-pair-v1\0" .. serverId .. "\0" .. clientId .. "\0" .. code)
```

`serverId` and `clientId` are the decimal computer ids. The result is stored as 64 lowercase hex characters.

`pair.join(code)` looks up `so` / `server`, sends `pair`, and saves the key after `ack`.

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

SO8 owns `so-mod-drops.lua`. It handles no wire types. It owns `drops.pick` and `drops.steps`.

SO9 owns `so-mod-fuel.lua`. It handles no wire types. It reads beacon fuel from `state` and decides when a turtle should refuel.

SO10 owns `so-mod-jobs.lua`. It handles no wire types. It turns a job into lease steps and asks SO3 to send them.

SO1, SO4, SO5, and SO8 replace the stub file and keep the calls above. The other tasks add their files.
