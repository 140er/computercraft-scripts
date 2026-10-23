# so protocol

Rednet protocol name is `so`. The server attempts to host that protocol as `server`. One server runs `so-server.lua` on a computer whose disk is at least 16000000 bytes. Turtles, pocket computers, and monitors keep no state that matters after a reboot. After a reboot the server tells them what to do.

Servers and displays open every attached modem and rescan on `peripheral` and
`peripheral_detach` events. A wired modem does not exclude a wireless or ender
modem. The server attempts hostname registration once at boot. If it fails, the
server stays running and shows the conflicting host ID when lookup returns one.
Paired clients can still send directly to its computer ID.

A display boots with the lowest numeric server ID in its saved pairing keys,
including a recovered key generation. It keeps sending to that ID through
outages, regardless of `so/server` lookup results. It uses hostname discovery
only when it has no paired server. The wire format is unchanged.

Fresh pairing still uses the shared `so/server` hostname. Two installations in
ender range, including across dimensions, can collide or answer discovery in a
different order. This change does not select the intended server for an unpaired
client. Isolate the networks while pairing. Selecting a server explicitly needs
a separate setup or discovery change. A server that failed registration needs a
reboot after the hostname becomes available. A server registered offline may
also collide when a modem is attached later.

Durations use `SO.now()` in integer game milliseconds on the server. Workers
and displays each use their local `now()` helper over `os.clock()`. One game
second is 20 computer ticks. It takes 0.25 real seconds at `/tick rate 80` when
the server sustains that rate. Timers and turtle actions use the same ticks.

CC:Tweaked 1.120.2 resets `os.clock()` at computer startup. The server uses
`so-store.clock()` to add a durable offset. Its first boot starts at UTC to
preserve existing UTC-based saved timers and ages. It writes a `ticks-v1`
upper reservation to `so-data/clock` before returning time within it. A server start
resumes at that reservation, consuming at most one extra game second. Offline
server time pauses. The clock and all job/state generations form one backup;
restore them together. A checkpoint failure refuses further clock reads.
Clients persist recovery facts rather than lease deadlines, so their clocks
can reset on reboot. Server recovery sends a new stationary lease.

`os.epoch("ingame") / 72` has nominal game-millisecond units but follows
Minecraft daylight time, including `/time` changes and disabled daylight
cycling. `os.time()` is the hour within that day. Neither is a monotonic
interval clock. The checked native implementations are
[OSAPI](https://github.com/cc-tweaked/CC-Tweaked/blob/v1.21.1-1.120.2/projects/core/src/main/java/dan200/computercraft/core/apis/OSAPI.java)
and [ServerComputer](https://github.com/cc-tweaked/CC-Tweaked/blob/v1.21.1-1.120.2/projects/common/src/main/java/dan200/computercraft/shared/computer/core/ServerComputer.java).
The testkit's pack ROM does not replace CraftOS-PC's native clock APIs.

UTC remains the clock for envelope `at`, freshness and replay/cache retention,
history `at`, Amsterdam headers, stock sample dates and daily calendar dates.
History also carries `gameAt` for elapsed alert and recent-ore windows. Legacy
events use their original timestamp on the initially UTC-seeded timeline.
All other ages, leases, retries, park and planting waits, throttles and uptime
use the game clock. `tests/so/clock-utc.tsv` lists the permitted UTC expressions;
`tools/check-clock.py` rejects any other UTC read in every `so-*.lua` and both
clients.

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

The server drops a bad MAC and prints `so-server: bad mac from <id>`. It does not answer. A pair message is checked with `pair.derive` of the code on screen and the sender id. A retry of a pair `rid` that still has a saved reply is checked with the handshake key stored beside that reply. Any other message is checked with the key saved for `from`. No key is a bad MAC. A pair with no live code and no saved handshake key for that `rid` is a bad MAC. A `pair2` message and its reply are checked with the public key from `pair.envelopeKey()`, which is sha256 of `so-pair2 envelope\0` as 64 hex characters. That MAC only checks the envelope. CPace in the body protects the code.

`at` must be within 60000 ms of the receiver's `os.epoch("utc")`. A larger gap is dropped as `so-server: bad message from <id>`.

After a good MAC, the server remembers each `rid` for that `from` for 120000 ms. The window is the age of the rid, not a fixed count of entries. A repeated `rid` with no saved reply is dropped and logged as `so-server: replay from <id>`. The server does not answer. A bad MAC does not enter this window.

At start the server calls `so-proto.since(os.epoch("utc"))`. From then on `fresh` refuses any envelope whose `at` is older than that start, with the same `replay from` line. Every message an earlier run accepted was stamped before this run started, so a restart does not reopen the 60000 ms window. A client request that was in flight across the restart is dropped too; the client's next request carries a new `at`.

The server keeps the encoded reply for each `(from, rid)` for 120000 ms. A later message with that same `from` and `rid` is sent the saved reply again. The handler does not run a second time.

`so-proto.request(target, t, body, timeout, tries)` builds one message and sends that same table, with the same `rid`, on every try. `timeout` is seconds per try. `tries` is how many sends to make. Omitted values are 3 seconds and 1 try. The call yields on `os.pullEvent`. Events that are not the matching reply stay consumed, so the caller runs `request` in its own coroutine with `parallel.waitForAny`. A handler on the server must not call `request`, because the server loop is already waiting on `os.pullEvent`. A module sends with `SO.proto.build` and `rednet.send`. A matching reply must verify under the key for `target`. The return is the reply envelope, or `nil` and `timeout` or `no key`.

A reply reuses the request `rid`. `from` on the reply is the computer that answered. The first `reply(t, body)` wins. Later calls do nothing.

A payload that is not a table, or an envelope that fails `decode`, is dropped and logged as `so-server: bad message from <id>`. The same line is used when `from` does not match the rednet sender.

## Message types

Send every message below through `so-proto`. Do not add a field here without editing this file.

### pair2

`pair2` runs CPACE-X25519-SHA512 from draft-irtf-cfrg-cpace-21 in the initiator-responder setting, with the explicit key confirmation of its section 10.4. The joining computer is the initiator A and the server is B. PRS is the six code digits as ASCII. CI is `lv_cat("so-pair2", clientId, serverId)` with decimal ids. ADa and ADb are empty. Both envelopes and replies use the public `pair.envelopeKey()`.

Step 1. The client sends `pair2` with `body.sid`, 16 random bytes as 32 hex characters, and `body.y`, its share Ya as 64 hex characters. A client that already holds a key for this server adds `body.auth`, HMAC-SHA256 under that key of `so-pair2 auth\0`, the raw sid and the raw Ya, as 64 hex characters. The server answers `ack` with `body.y`, its share Yb. It keeps one session per sender with the expected tags and whether `auth` matched the key it saved for that sender. A session lasts 60000 ms.

Step 2. The client computes ISK and sends `pair2` with the same `body.sid` and `body.tag`, Ta as 128 hex characters. A step 2 whose sid does not match the open session gets `err` `session` and leaves that session open. Otherwise the server checks Ta once and drops the session either way. On a match it saves the machine key, answers `ack` with `body.ok = true` and `body.tag`, Tb as 128 hex characters, and clears the code. The client checks Tb before it saves the key.

```text
g    = Elligator2(decodeUCoordinate(SHA-512(lv_cat("CPace255", PRS, zero pad, CI, sid))[1..32]))
Ya   = X25519(ya, g)        Yb = X25519(yb, g)        K = X25519(ya, Yb) = X25519(yb, Ya)
ISK  = SHA-512(lv_cat("CPace255_ISK", sid, K) .. lv_cat(Ya, "") .. lv_cat(Yb, ""))
mac  = SHA-512("CPaceMac" .. sid .. ISK)
Ta   = HMAC-SHA512(mac, lv_cat(Ya, ""))                Tb = HMAC-SHA512(mac, lv_cat(Yb, ""))
key  = HKDF-SHA512(ISK, salt = empty, info = "so-pair2 machine key", 32 bytes), as 64 hex
```

A party aborts when K is all zero bytes. Nothing on the wire depends on the code without a secret scalar, so a recorded exchange gives a listener no way to test a guess. Each guess costs an online exchange with the server, and the budget in [pairing](#pairing-and-so-keys) limits those. `tests/so/pair2.lua` checks the draft's test vectors and its low-order point cases.

`err` replies carry `body.code = "pair"` and a `body.text` reason. `code` means no live code. `wait` means the sender is over its budget. `body` means a malformed sid or share, and `share` a share that gives K all zero. `session` means step 2 found no open session for that sender and sid. `tag` means Ta did not match. The client reports `no code`, `busy` and `wrong code` for `code`, `wait` and `tag`, and the other reasons as they are.

The envelope key is public, so any computer can send a joining client a forged `err`. The client then reports a failure even if the server saved its key; pairing again with a new code replaces that key.

### pair

Legacy pairing, kept for one release so clients from before `pair2` still pair. A recorded `pair` exchange lets a listener test all 10^6 codes offline, because `pair.derive` mixes only public values and the code. The next release removes it.

The joining computer sends `pair` to the server. `body.pub` is its X25519 public key, 64 lowercase hex characters. The code is not a field.

The server answers `ack` when the MAC matches the live code. `body.ok` is `true`. `body.pub` is the server public key, 64 lowercase hex characters. `body.proof` is HMAC-SHA256, keyed by the 6-digit code, over the bytes `so-pair-v2\0`, then the client public key, then the server public key. Those public keys are the raw 32-byte values, not the hex text. `proof` is 64 lowercase hex characters. The server then clears the code.

The envelope MAC on that `pair` and its `ack` uses the handshake key from `pair.derive`, not the stored machine key. A retry of the same `rid` gets the saved `ack` again. The server keeps that handshake key for 120000 ms next to the saved reply, so the retry still verifies after the code is cleared. A new `rid` for an id that already has a key needs a new code. A different computer needs a new code.

### hello

A paired computer sends `hello` to the server.

`body.role` is an optional string. `body.label` is an optional string.

`body.w` and `body.h` are optional positive integers. They are the available frame size in character cells. `display.lua` uses
`getSize` and reserves the bottom row for local input on screens at least
three rows tall, so `body.h` is one less than the physical height there.
Optional `body.fullH` advertises the physical height. The Big Tiles server uses
that height and kit frames fill every row, including pocket glance navigation.
Kit-free frames retain the local input row. `body.keyboard` is true only when the
client draws on its own terminal. Every monitor client reports false. Missing
flags use touch panel controls. The display module reads these sizes.
It does not treat `body.role` as the screen assignment.

A turtle also sends these fields.

`body.fuel` is a number, or the string `unlimited`.

`body.free` is how many of the 16 slots are empty.

`body.inv` lists the occupied slots. Each entry is `{ slot = number, name = string, count = number }`.

`body.gps` is optional. When a GPS answers, it is `{ x = number, y = number, z = number, dim? = string }`.
`dim` comes from the worker's explicit plain `so-worker.cfg` table `{dim=string}`.
GPS does not measure dimension. Missing `dim` permits range observation but
refuses automatic add and drop coordinates.

`body.journal` is the turtle's journal. `journal.id` is a string. `journal.seq` is a number. `journal.pose` is `{ x = number, y = number, z = number, f = number }` in the turtle's own frame since boot. `f` is 0 north, 1 east, 2 south, 3 west. `journal.moves` is the last 32 completed moves, oldest first. Each move is `{ n = number, op = string, ok = true }`. `op` is `forward`, `back`, `up`, `down`, `turnLeft`, or `turnRight`. `journal.dug` is the last 32 cells this turtle dug. Each entry is `{ x = number, y = number, z = number }`. `journal.pending` is optional. It is `{ n = number, op = string, lease = string }` when a step was started and not finished.

The server answers `ack`.

### ack

`body.ok` is `true`. A reply to `drops.edit` also sets `body.id` to the point id.

### err

The server sends `err` when no built-in handler and no module handler matches `t`.

`body.code` is `unknown`. `body.text` is `unknown type`.

`body.code` is `store` when the server could not save a new pair key. `body.text` is the store error.

`body.code` is `pair` when `body.pub` is not a 32-byte key. `body.text` is `pub`. `pair2` uses the same code with the reasons listed under [pair2](#pair2).

### lease.batch

The server sends `lease.batch` to a turtle.

`body.lease` is a string. `body.expires` is UTC milliseconds for legacy workers. `body.ttl` is the remaining game milliseconds for updated workers. `body.steps` is an array of 1 to 16 steps. SO3 checks the length.

A step is a table.

`op` is one of `discard`, `forward`, `back`, `up`, `down`, `turnLeft`, `turnRight`, `dig`, `digUp`, `digDown`, `place`, `placeUp`, `placeDown`, `suck`, `suckUp`, `suckDown`, `drop`, `dropUp`, `dropDown`, `refuel`, `select`, `inspect`, `inspectUp`, `inspectDown`.

`slot` is optional. It is an integer from 1 to 16. `select` uses it. Other ops use the already selected slot.

`n` is an optional integer. `refuel`, `drop`, `dropUp`, `dropDown`, `suck`, `suckUp`, and `suckDown` use it as a count.

`park=true` on the first step makes expiry hold position and send slow beacons
instead of reversing the movement journal. Workers advertise support through
`capabilities.parkBatch=true` in hello and reports. A single `inspectDown` also
parks without the flag.

Drop and suck operations require `peripheral.hasType(side, "inventory")` on the
target side. Otherwise the worker returns `ok = false, err = "no inventory"`
without calling the turtle transfer operation. Drops into open space are refused.

On reboot the worker resolves a pending movement from the saved fuel level. A
fuel difference of one means it ran; no difference means it did not. With
unlimited fuel, a GPS fix saved before the move and another at boot can resolve
the displacement. A turn, an old pending entry without evidence, or a conflicting
observation stays uncertain. The worker retains the pending entry and sends
`journal.recovery = { n, op, outcome }` on hello. `outcome` is `applied`,
`not applied`, or `uncertain`. `journal.uncertain = true` marks an unknown pose;
`journal.pose` then contains only the last committed pose. The worker stays still
and refuses subsequent steps with `pose uncertain` until an operator re-adds it.
The server discards its cached journal pose and refuses new leases while uncertain.

`discard` accepts `side = "front" | "up" | "down"`, defaulting to `down`,
and optional count `n`. It drops only after inspection establishes an empty cell.
An adjacent inventory always refuses discard, even if inspection reports air.
Occupied or uncertain cells return a failed result and keep the items.

### step.report

The turtle sends `step.report` to the server.

`body.lease` is the lease string from `lease.batch`. `body.results` is one table per step, in the same order.

`results[i].ok` is a boolean. `results[i].err` is an optional string. `results[i].data` is an optional table. For a successful inspect, `data.name` is the block name. `data.tags` contains at most eight matching tags as `[tag] = true`. The allowed tags are `c:ores`, `forge:ores`, `minecraft:logs`, `minecraft:leaves`, `minecraft:saplings`, `minecraft:dirt`, `c:chests`, `forge:chests`, and any tag beginning with `c:ores/` or `forge:ores/`. The worker retains the fixed tags before subtype tags. If the full report would exceed the envelope limit, it removes the longest subtype tags until it fits. `data.level` is the numeric `state.level` when present. A water or lava source has level 0.

`results[i].counts` is an optional array of 16 numbers, the item count in slots 1 to 16 after the step.

`results[i].err` is `expired` when the step was not run because `lease.batch` `expires` had passed. Later steps in that batch use the same error.

`body.uncertain = true` omits `body.pose` when an interrupted step could not be resolved.

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

Frame signatures and revisions are tracked per role and client. Unchanged
frames wait for the four-second keepalive even when other displays have different
sizes or pages.

`body.role` is `shop`, `mining`, `lumber`, `status`, `ar`, or `generic`. It is the screen that was drawn.

`body.rows` is the draw list. Each row is `{ text = string, fg = string, bg = string }`
or `{ text = string, runs = { { n, fg, bg }, ... } }`. Each run paints `n` cells
with one blit colour each for `fg` and `bg`. Runs cover the row width. Compact
rows may omit trailing spaces from `text`; the client pads them to the run width.
The server chooses compact rows only when their `so-proto.ser` output is smaller.

`body.palette` is optional. It maps numeric indices 0 through 15 to packed RGB
numbers, corresponding to blit slots `0` through `f`. A frame without a palette
restores the stock CC palette. `body.scale` is optional and accepts 0.5 or 1.
The server sends 0.5 by default, or 1 for a computer marked far. A monitor applies
the scale, then sends one `hello` if its character dimensions changed. The resize
event for the same dimensions does not send another `hello`.

`body.buttons` is a list of `{ id = string, x = number, y = number, w = number, h = number?, label = string }`. The list may be empty.

`x` and `y` are 1-based character coordinates. `w` is the width in characters. `h` is the height in rows and defaults to 1. Any cell inside the rectangle hits the button.

`fg` and `bg` are CC blit strings. One character paints the whole row. A string the same length as `text` paints each character.

### input

A display sends `input` to the server. It does not wait.

`body.id` is the button id, or absent when the player submitted text. `body.text` is that text, or absent for a button. `body.x` and `body.y` are 1-based character coordinates.

`body.role` is ignored. The server uses the role stored for that computer.

### drops.edit

A paired computer sends `drops.edit` to the server. The payload is the table from `so-proto.encode`. A string payload is dropped. The server answers `ack` or `err`.

`body.op` is `add`, `remove`, or `fix`.

For `add`, `body.id` is a string of letters, digits, underscore, and hyphen. `body.dim`, `body.x`, `body.y`, and `body.z` are integers. The x, y and z fields are the chest's own coordinates. `body.side` is `front` or `down`. `front` accesses the chest from a neighbouring cell at the same height while facing it; `down` accesses it from directly above. `body.kind` is `fuel`, `ore`, `junk`, `wood`, `storage`, or `any`.

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

`msg` is the decoded envelope. `reply(t, body)` sends one reply. `now` is `SO.now()` game milliseconds. `tick` runs once each second from `os.startTimer(1)`. A late timer does not run the missed seconds. `tick` returns quickly.

Built-in `pair` and `hello` run first. Module handlers for that same type run next, in file name order. All of them run. Unknown `t` gets `err`.

`listen` is optional. For rednet protocols other than `so`, the server calls each matching listener in file name order inside `pcall`. A failed listener is logged and later listeners still run. The server sends `so` messages through authenticated dispatch only, even if a module declares `listen.so`. Listeners return without waiting. A listener records incoming data; cross-module calls still belong in handlers or `tick`.

### shop

`so-mod-shop.lua` registers the `shop` display role through `display.screen` from its first tick. It keeps stock, per-display search text, order replies and trend samples in memory. Restarting the server clears them.

The module finds the existing, unpaired Storage Room turtle through DNS or the sender of a `roomsorter_stock` broadcast. Until found, its tick broadcasts `{ sType = "lookup", sProtocol = "roomsorter" }` on `dns` every 10 seconds without waiting. Its `dns` listener selects the sender of `{ sType = "lookup response", sProtocol = "roomsorter" }` only while no turtle is known. Before discovery the screen shows `Storage room not found, still looking`. After five minutes without a stock reply or stock broadcast from the selected turtle, it clears stale stock and resumes discovery. DNS replies and order replies do not extend that deadline. The legacy room has no server-only configuration or pairing record to select a preferred turtle; discovery uses the first DNS or stock responder.

The legacy turtle uses plain rednet. This is an exception to the `so-proto` envelope. The shop sends `{ cmd = "stock", rid = number }` on `roomsorter` every 10 seconds after discovery. Replies carry that `rid` and `{ version, totals, state, crafty, cutoff, recipes, orders }`. Broadcasts on `roomsorter_stock` carry `{ totals, used, size, chests, furnaces, state, full }`. Only the selected turtle updates the stock.

The Big Tiles screen uses `render(w, h, session)`. Stock is shared; category,
letter, sort, page, selection and order feedback belong to the display session.
It draws category tabs derived from item IDs, an A-Z letter picker, STOCK and
NAME sort buttons, item tiles and paging. Small screens open a category picker.
No shop search field is drawn. Submitted text remains a compatible name filter;
spaces match underscores, and a lone space or `*` clears it. Category taps clear
that filter. Count sort descends by stock and breaks ties by item ID. Name sort
uses the displayed name and then item ID. The stock time uses Amsterdam time.
Stock older than 30 seconds shows STALE STOCK.

Tapping `item:<itemName>` opens an IN STOCK tile and quantity buttons
`order:1:<itemName>`, `order:16:<itemName>` and `order:64:<itemName>`.
`items` returns to the same list page; `status` returns from the list to status.
Tiles keep the existing blue, amber, empty and trend states. Stale tiles use gray.
Without `so-ui.lua`, the legacy list and its direct order buttons remain available.

An order sends `{ cmd = "order", text = itemName, n = count, rid = number }`
on `roomsorter` once. Quantity buttons then become inactive until the user
returns to the list and selects an item again. Replies match sender and request
ID. Each reply updates only the initiating display's latest order. The status is
sent after dispatch and on a Getting or Crafting reply, delivered only after an
explicit Delivered or sent-to-output-chest reply, and failed on refusal or a
two-minute timeout. Legacy rooms currently acknowledge queued work, so sent is
the final observable state there. The screen never infers delivery from stock
changes and never retries orders. `shop.order(search, count)` remains a direct
one-order API for keyboard panel quick orders and leaves shop displays unchanged.

Each item keeps at most 60 samples, one per minute. Its `^`, `v` or `-` compares current stock with the oldest retained sample, about an hour ago once the history fills. Before an hour of history exists, it compares with the earliest available sample.

### state

SO1 owns this API on `SO.mods.state`. It also owns `so-log.lua`.

`state.emit(kind, data)` appends one event and folds it into the current state. `kind` is a string. `data` is a value `so-store` can save. The call returns true, or false and an error string. A false return does not fold
that event. A failed durable append sets the disk error and queues the event in
memory before folding it. The queue holds at most 256 events and 262144 serialized
bytes. Overflow or an event above the single-segment budget prints an explicit
refusal and returns false. Segment fit is checked before queue insertion. Queued events appear
in views and history, retry in sequence, and are lost if power fails before retry.
By default, the revision is the event sequence number. Heartbeat coalescing also
advances revisions for registry changes in memory. `emit(key, value)` is this same call.

`state.get(key)` returns the last value stored under that key, or nil.

`state.get(path)` also walks the machine registry. `machines`, `machines/<id>`, and `machines/<id>/<field>` read the registry. Dots work the same way as slashes.

`state.view()` with no arguments returns `{ rev = number, values = table }`. `values` is a shallow copy of the top key table.

`state.view(name, buildFn)` declares a named view. `buildFn` receives `{ rev, values, machines, jobs }` and returns the view data. The names `fleet`, `log`, `status`, and `turtle/<id>` stay built in.

`state.view.get({ name = string })` returns one frame `{ t = "view.frame", name, rev, at, data }`. `rev` is the view revision. `at` is utc milliseconds. This frame is in-process. It is not a rednet `view.frame`.

`state.view.sub({ name = string, notify = function })` subscribes to that view. On a change, SO1 calls `notify(frame)`. The frame `rev` is greater than the previous frame for that subscriber. Two frames for one subscriber are at least 500 ms apart, so a subscriber gets at most 2 frames per second. `tick` sends a frame that was held back once the gap has passed.

`state.history.page({ from = number, count = number })` returns `{ entries, next }`. `entries` is `{ seq, at, gameAt?, kind, data }` in ascending `seq`, starting after `from`. Omit `from` to start at the oldest retained event. `count` defaults to 20 and is clamped to 1..50. `next` is the last `seq` in this page when another page exists, and nil on the last page. Pass `next` as `from` to read the following page. `limit` is accepted as an alias of `count`.

`state.job(data)` is `emit("job", data)`, except when the disk is 80% full or more. Then it returns false and `"disk"` and does not write the job. `emit("job", data)` follows the same rule.

`state.canStart()` returns true below 80% disk use. At 80% or more it returns false and `"disk >=80%; free space"`. It reads current capacity and free space on every call and writes nothing. Mining and lumber call it before `start` changes their jobs. A missing guard refuses start too. Recovery, stop and ongoing work remain available.

`state.disk()` returns the same data as the status view. `state.canWork()` returns
false while event writes have failed or events await retry. The lease dispatcher
then refuses new movement batches. Recovery and stationary parks remain available.
At 85% disk use, unchanged heartbeat and fuel updates stay in memory. Event-count
checkpoints move to every 10000 events; retention checkpoints still run.

`state.tick(now)` retries at most 16 queued events every five seconds, refreshes
the disk ledger every 30 seconds, and flushes held view frames. `now` is `SO.now()` game milliseconds. The server passes it once a second.

#### Events

Every accepted `emit` is one event `{ seq, at, gameAt?, kind, data }` in the log. `seq` starts at 1. `at` is utc milliseconds.

`kind` `machine` merges a registry row. `data` is `{ id, role, fp, seen, fuel, pose }`. `id` is the computer id. Fields left out stay as they were. Missing `seen` becomes the event time. Missing `fp` becomes the sha256 hex of that computer's paired key when the key is known.

`kind` `pose` sets the turtle pose. `data` is `{ id, dim, x, y, z, facing }`.

`kind` `job` appends a job. Any other `kind` stores `data` under that key for `get`.

#### Views

`fleet` is every machine row, sorted by id. Each row is `{ id, role, fp, seen, fuel, pose }`.

`turtle/<id>` is one machine row, or nil when that id is unknown.

`log` is the last 50 retained events, oldest first. Each entry is `{ seq, at, gameAt?, kind, data }`.

`status` is `{ capacity, used, free, ratio, alerts, accepting, pressure,
pending, pendingBytes, error, stores, scanned }`. `pressure` is true at 85% use.
`pending` and `pendingBytes` describe the volatile event queue. `stores` has byte
counts for `log`, `snapshots`, `cells`, `jobs`, `keys`, and `other`, including all
file generations. `other` includes filesystem allocation and unclassified files.
The categories sum to `used`. `scanned` is the last ledger scan in game time. `ratio` is `used / capacity`. `alerts` contains `"disk"` when `ratio` is 0.8 or more. `accepting` is false in that case.

#### Log files

Events live in segment files of at most 64 KB under `so-data/log/`. SO1 writes a snapshot of the folded state every 2000 events under `so-data/snap/`. On boot it loads snapshot `n` from the recovered `latest` pointer, or `n-1` if `n` is invalid, and applies later segment events. After `latest` saves, cleanup deletes older numbered snapshots and their `.tmp` and `.bak` files. Startup repeats this cleanup. Live segment bytes stay at or under 1 MB. Older segments are deleted only after the snapshot that covers them is on disk. A crash during a segment write loses at most that one event. A failed write returns false and the error. SO1 does not drop it silently.

New segments target 8192 bytes of estimated serialized data. A larger valid
event occupies one segment up to the existing 65536-byte limit. Saves still
write and verify a full schema-1 generation before append returns success.
Current, `.tmp` and `.bak` recovery and protocol version 1 are unchanged.
`so-store.store` exposes `bytes`, the serialized size of its recovered or most
recently saved generation. Log accounting uses that size without rereading it.
Retention checkpoints leave at least 64 KB below the 1 MB window by removing
whole covered segments. This amortizes snapshot writes across small segments.

Optional `so-server.cfg` `state.coalesceHeartbeats=true` omits routine hello
events at every disk pressure. The default is false. First contact, role,
journal and fingerprint changes still emit `machine`. Fuel changes emit when
the type changes, zero is crossed, or the difference from the last machine
event reaches 100. Smaller changes update the registry in memory. Every changed
hello advances the view revision without consuming an event sequence number.
Subscriptions retain the 500 ms throttle. Revisions restart from durable event
state after reboot and must not be used as history cursors.

Snapshots include the current registry contact times and fuel. Their cadence
remains event-count and retention driven, so idle freshness has no bounded
checkpoint interval. With coalescing enabled, boot restores each machine's
`seen` as the newer of its saved contact time and `SO.now()`. This gives restored
machines the normal stale threshold to reconnect. Coalescing does not change
the existing volatile disk-failure backlog or make queued events durable.
The optional registry field `eventFuel` saves the last machine event's fuel
baseline, so cumulative changes still reach the threshold across restarts.
Older readers ignore that field.

When the disk is 80% full or more, `status` raises the disk alert and new jobs are refused. Other events are still written while the disk accepts them.

SO1 handles no wire types. SO5 owns wire `view.get`, `view.sub`, `view.frame`, and `input`. SO6 owns wire `history.page`.

### daily

`so-mod-daily.lua` is server-only. `daily.today()` returns a copied
`{ date, ore, oreByName, oreRecent, logs }`. `oreByName` maps full item names
to counts. `oreRecent` counts events in `(SO.now() - 600000, SO.now()]` from today's ore, using event `gameAt` or legacy `at`.
`tick(now)` consumes at most one 50-entry state history page without waiting.
It counts `mine.ore { id, name, count }` and `lumber.logs { id, count }` by
event timestamp, ignores other days, and resets totals at Amsterdam midnight.

The store `so-data/daily` holds `{ date, cursor, ore, oreByName, logs, recent }`.
`cursor` is the last consumed sequence, including ignored events. `recent`
maps decimal game seconds to `{ total, counts }`; `counts` maps decimal game
milliseconds to ore counts. At most 601 second buckets remain. Counts and
cursor save together at most once a minute, plus on a day change. A restart
replays retained history after the saved cursor. Events already removed by
state history retention cannot be reconstructed. There are no new wire types.


### lease

Lease IDs include the durable clock to distinguish batches across server boots.
`lease.batch` carries `ttl`, the remaining game milliseconds at send time.
The server's internal `expires` is a game-clock deadline. Wire `expires`
remains UTC plus that remaining duration for old workers. Retries recompute
the remaining duration. Updated workers anchor it on receipt, including time
spent queued behind another batch, and take the earlier deadline on a repeated
lease ID. A missing `ttl` converts the legacy UTC remainder once at receipt.
Legacy retries also match the original UTC expiry, so an old server can reuse
a lease ID after reboot without inheriting the previous deadline.
Transport delay before receipt is not charged by `ttl`. Mixed versions retain
20 TPS behavior; accelerated Gate B requires all roles updated.

Unreported single-step `inspectDown` parks retry every game second until a
report arrives or the lease expires. Retries retain the lease ID and use a
fresh envelope with the remaining duration. Both ordinary and recovery parks
use this rule. Workers accept authenticated server messages during GPS lookups,
so a lookup cannot discard a renewal or a work batch.


`SO.mods.lease` dispatches worker batches. Planners call it from handlers or ticks.

`lease.send(id, steps, opts)` sends 1..16 steps through `so-proto` without waiting. `opts` has optional `ms`, `owner`, `recover`, and `pose = { dim, x, y, z, facing }`. The default duration is 60000 ms. It returns a lease id `<id>-<n>`, or nil and a reason. An open lease returns `busy`. A beaconing turtle returns `lost` unless `opts.recover` is true. Recovery still refuses an open lease with `busy`. Invalid arguments, an absent pair key, or a failed send also return nil and a reason.

`lease.onReport(owner, fn)` registers one callback for an owner tag. It receives `(leaseId, turtleId, results, lease)`. The lease record has `id`, `turtleId`, `steps`, `owner`, `pose`, `expires`, and `status`. Status is `reported` after a report and `expired` after silence. An accepted report stores `lease.report = { pose, journal, fuel, inv, dug }`. Each field is type-checked independently. A bad field is omitted while valid fields remain. These facts are stored for successful batches and batches with failed or expired steps. A later registration replaces the callback.

An accepted `step.report` clears lost. A matching `step.report` closes the lease and calls `cells.releaseOwner(leaseId)` when present. Every result must have a boolean `ok`, and there must be one result per step. Only a full successful report emits `pose` with the turtle id and expected pose. It also updates the known range. The callback runs once. Unknown, closed, or wrong-sender reports have no effects. Ignored reports log once per turtle.

`lease.status(id)` returns `{ open, lost, range, seen, pose, journal, poseAt }`. `pose` is the newest valid journal pose `{ x, y, z, f }` observed in an accepted report, beacon, or hello. Hello supplies `body.journal.pose` and `body.journal.id`. `journal` is the latest valid journal id. `poseAt` is the local game-millisecond time when the pose was observed, or nil before any valid pose. A changed journal id without a valid pose clears `pose` and `poseAt` so planners cannot reuse coordinates from the old frame. `open` is the lease id or nil. `seen` is the last accepted report, beacon, or hello time in game milliseconds, or 0 before contact.

`lease.cancelPark(id, "mine")` retires an open mining lease only when its sole
step is `inspectDown`. It returns true when cancelled or already closed, otherwise
false and `"turtle has open lease"`. Cancellation releases reservations owned by
the lease and ignores later reports without calling the planner callback.

`lease.inRange(id, pos)` checks the distance from the server against that turtle's range plus 8 blocks. A known dimension mismatch returns false. Range starts at 16 blocks. Known poses and successful batch reports can only increase it, including the first observation.

The server position comes from the plain `so-server.cfg` table `{ pos = { dim, x, y, z } }`, read through `so-store`. Without it, the module tries `gps.locate(2)`. Without either position, every range check returns true and the module logs that once at load.

A `beacon` marks the authenticated sender lost, retains its journal id, and emits `machine` with its id, fuel, seen time, and journal. The body id cannot select another turtle. `hello` clears lost and uses `body.gps` or `body.pose` as a known pose. An open lease remains open until a report or expiry.

`tick(now)` closes a silent lease after `expires + 10000` and calls its owner with nil results. It keeps the cells reserved. The planner decides how to recover them. The module also answers wire `history.page` with `state.history.page(body)`, including SO1's sequence-based entries and cursor.

Lease records, callbacks, beacon journals, and observed ranges live in memory. A server restart clears them. Planners must recover reservations before sending new work after a restart.

`lease.world(id, dim)` returns `{ dim, x, y, z, facing? }`, or nil and a reason.
It requires pairing, a GPS fix at most 60 seconds old and at least as new as the
last journal pose, matching explicit worker and server dimensions, and a certain journal. An open
movement lease refuses it; a stationary park permits it. Facing is optional until
GPS displacement proves the journal rotation or a world-anchored journal agrees
with GPS. Initial journal `f=0` proves no world facing.

`lease.locate(id, dim, done)` calls `done(pose, error)` from the handler or a later
report. With unknown facing it reserves the start and four adjacent horizontal
cells under `gps:<id>`, then leases `forward`, `gps` for 15 seconds with
`park=true` on the first step. The worker must advertise
`capabilities.parkBatch=true` in hello; otherwise the probe refuses and requests
a worker update or explicit add. It never digs or turns. A successful forward
move and unit GPS delta establish facing. Before executing any probe step, the
worker saves the park state with its pending journal entry. Lease expiry enters
stationary slow beacons, including after GPS loss, a missing report or failed
assignment persistence. Earlier journal moves are not reversed.
`claimProbe(id, owner, pose)` atomically hands its
standing reservation from the probe to the job owner through `cells.handoff`.
The other probe cells remain until the job assignment saves. Only then does
`clearProbe(id)` release them. A blocked move with unchanged GPS releases the
probe cells and refuses. Missing GPS or reports retain those cells for recovery.
`clearProbe(id)` releases them after an explicit operator add has saved both
the standing reservation and the assignment, when no lease is open. `candidates()` returns sorted unassigned paired worker IDs. Mining and lumber
export `assigned(id)` for that list. Both accept `add <id>` and draw per-worker
ADD HERE controls on SETUP. Explicit `add <id> x y z f` retains its recovery role.

The worker accepts `gps` as a lease step. Its result is `{ ok=true,
data={x,y,z,dim?}, counts }`, or `{ok=false,err="no GPS",counts}`. GPS waiting keeps
processing authenticated server traffic. A probe uses normal per-step journal
writes and the existing uncertain-pose rules after interruption.

### mine

`so-mod-mine.lua` plans work for paired workers. It starts stopped. Its job lives in
`so-data/mine/job` through `so-store`. The job contains `dim`, `home`, `bottom`,
`length`, `branches`, `continuous`, `mode`, `ores`, `turtles`, and `progress`. `home` is the chest side of
the shaft. The shaft is one block forward from it. Each turtle gets a branch at the bottom level. Branch junctions are four blocks apart in `thorough` mode
and two blocks apart in `fast` mode. Branch length defaults to 64 blocks.
New jobs default to `ores = {}`, so they accept all ores. Saved ore filters stay unchanged.

The module registers `display.screen("mining", render, input)`. `render(w, h)`
returns a Big Tiles frame. Input ids `start` and `stop` use the text commands
below. `setup` opens the settings page and `mine-back` returns to mining.
`status` is the main BACK navigation id. Both pages accept text commands.
Daily ore totals have no source and show a stale `-` tile. A missing UI kit
retains the legacy renderer. Send these text
commands through that screen's `input.text`:

- `home <x> <y> <z> <n|e|s|w>` sets the chest-side position.
- `bottom <y>` and `length <n>` set the shaft bottom and branch length.
- `mode thorough|fast` selects wall inspection or faster branches.
- `ores diamond, iron,...` accepts spaces around commas and the supported names from `so-mine-plan.lua`.
  Only selected ores start wall veins. Empty or missing lists accept all ores.
  Ores blocking the route are still dug.
- `add <id> <x> <y> <z> <n|e|s|w>` anchors a paired worker's journal frame.
- `remove <id>` removes a worker after its lease closes or cancels its stationary
  recovery or park inspection. It releases the worker's lane and reservations.
  Movement and digging leases still prevent removal.
- `branches <n>` sets a job budget of 1..4096 branches and enables continuous mining.
  `continuous on|off` changes that flag. Its default is off; the budget defaults to eight.
- `start` checks the disk guard, home, usable ore and fuel drop points, at least one
  added paired worker without an uncertain or lost pose, and a nonzero reported fuel
  value for every added worker. Refusal emits `mine.alert {text, missing}` with an
  ordered list. Existing saved homes remain configured.
  `stop` lets an already sent batch finish. A valid command clears the prior command error.

Adding a worker sends a recovery park lease. Startup also sends each saved worker
one recovery park lease before planning. Reports supply the real journal pose,
inventory, fuel, and dug cells. The planner maps these facts through the worker's
frame. It keeps reservations under `mine:<id>`. Every entered, inspected, sealed,
or dug cell must pass the range check and reservation check before dispatch.
Lost and expired workers retain their reservations until a recovery report.
A completed route unloads remaining ore through the configured ore drop, returns
to its branch tip and parks. A missing or failed drop uses the existing retry delay.
A finished worker recovered away from its branch tip, for example one moved by
hand or saved after an older worker backed along its path, travels back to the
tip before it parks.
The screen shows each worker's state, pose, fuel, ore count, and last error.
A confirmed worker blocked by range or a hold retreats to a known free cell
outside the shaft and spine before parking. Retreat uses no digging and checks
range, fuel for both directions and reservations. Failed escape moves invalidate
their target and try another known exit. Return attempts require enough fuel;
failed returns retreat again and wait a minute before retrying. After leaving, it releases its lane pass and queue
entry while retaining its occupied cell. The saved yield path returns it to its
old pose and facing before work resumes. Range blocks retry when the original
action fits; other holds retry after a minute. No safe retreat releases the pass
but keeps the physically occupied cell protected. Other passes use normal cell
reservations instead of a global veto from that parked worker. Unknown or lost poses still
require recovery before movement or reservation release.

Lost workers and workers outside their proven radio range appear in red.

The shared lane contains the shaft column between `home.y` and `bottom`, and
its bottom spine through all assigned branch junctions. Before entering, a
worker reserves its whole route through the lane and its planned exit with the batch cells in one
`cells.reserveMany` call. A conflicting worker parks outside and retries each
tick. Only the lane holder may dig the first shaft. A logical pass may span
several batches of at most 16 steps; intermediate reports retain every lane
reservation. After the worker leaves the lane, its next tick releases the
reservation before another worker enters. Rapid report bursts defer additional
planning to tick instead of yielding inside a report callback.
Queued workers use oldest game-clock wait time, then lowest id. A worker skipped by
three grants has priority. The screen shows `wait lane` while blocked.
The saved turtle row includes `lane = { cells, entered, target?, release? }` and
`laneWait = { at, passes }`. `target` preserves an active vein crossing;
new side veins wait until the worker leaves the lane. Returning from a vein
reaches the branch depth before crossing wall cells, so filtered ores stay intact.
Scans skip cells held
by another owner. The bounded cache of already applied journal dug facts is
memory-only and clears on restart.

The pure helpers are `lane(job, exit)`, `inLane(job, pos)` and
`lanePass(job, row)`. They return the lane cells plus optional exit, membership,
and the entire planned pass through its first outside cell, respectively.

Work uses batches of at most 16 steps. Known straight travel and consecutive
turns share a lease. Travel can end with an inspect, whose result is read before
planning more work. Dig has a separate report boundary, so a failed dig cannot
authorize movement. Unknown shaft cells still require inspect and dig reports.
A fresh ten-block shaft therefore cannot be dug in two leases with this worker.
Thorough mode checks branch walls. Ore recognition also accepts `_ore` names, `:raw_` names, and
`c:ores` or `forge:ores` tags. The planner follows up to 64 ore blocks per vein.
It scoops lava sources with an empty bucket before trying sealing blocks.
It seals other lava and water before movement. About every ten digs, extra junk
uses guarded `discard` into an adjacent empty cell, preferring known open tunnel
cells. Failed targets are skipped until the turtle moves. Junk stays aboard when
no adjacent cell is safe, and ore unloads exclude junk. One suitable stack stays
for sealing.

Workers with fewer than two free slots visit an ore drop. Workers whose fuel is
below the mine route home plus 64 visit a fuel drop and refuel towards 2000,
or the return route plus reserve if that needs more fuel.
An empty fuel chest ends the pickup if the worker has enough fuel to return to
the paused position along the saved route and still meet that position's route home plus 64.
Otherwise the existing chest retry and hold rules apply.
Trips return to the position where work stopped. Underground trips return along
the branch to its spine junction, follow the spine to the shaft, and climb the shaft
before taking a shortest axis path around the chest to a free stand. Return trips
reverse the saved path. A side vein first connects through known dug cells to the
last reached mining waypoint. If that connection cannot be found within 512 cells,
for example after a restart empties the lookup or a re-add underground, a worker
below the surface plans the direct path: down or up its own column to the bottom
level, straight to the spine, then along the spine and up the shaft. That path
sets the fuel reserve and the trip digs it. Above the surface the trip still
waits with `no known mine route`. A worker added below the surface joins its
new route at the nearest cell after the shaft top instead of climbing to it. Searches use only the in-memory
block lookup, never the durable cells API. Home routes and vein access cache until
the pose, route waypoint or mine geometry changes. A stationary turtle does not
repeat the search on each tick; stand candidates reuse the cached access path.
Only the final approach can open new cells.
A trip reserves the shared corridor, surface approach and adjacent branch exit
before entering the lane, and retains them through the chest turnaround until
it returns to its paused position. Private branch cells use normal movement
batch reservations, keeping the lane grant independent of branch length. This uses
the same queue as other miners and prevents opposing surface approaches from
blocking each other. Supply trips sharing the lane run one at a time and defer
report planning to tick. Known shaft and spine travel still batches, while moves
outside the lane release one private cell per report when the trip uses the
shared corridor. Trips wholly on the surface keep normal batching. This limits reservation-map
copies during cleanup and keeps the server handler from yielding.
Saved trip records include `shared`, whether they cross the lane, `path`,
starting at the paused position, and `reserve`,
the fuel needed there for the route home plus 64. Older trip records use the mine
geometry when possible and hold if the recovered position is outside that route.
Full inventories unload before a fuel pickup.
Ore unloading includes mined fuel items. Front drops use a free neighbour
at the same height. Down drops use the cell above the chest. The drop module's
numeric dimensions map to `minecraft:overworld` as 0, `minecraft:the_nether` as
-1, and `minecraft:the_end` as 1. Other dimensions wait with an alert.
After three failed transfers at the same drop, the worker parks and retries
once per 60000 ms. Failed drop inspections call `drops.note(id, nil)` once each.
The first exhausted retry emits `mine.alert { id, text }`, where text is
`ore #<point> full at x,y,z` or `fuel #<point> empty at x,y,z` after an inspected
container reports a failed transfer. Unconfigured points report `no <kind> chest set`.
Broken points and unreachable access cells report their cause, id and coordinates
immediately. Alerts include `reason` and `point` alongside `id` and `text`.
Only item-transfer failures use the three-attempt threshold.
A successful transfer clears the retry state. Saved turtle rows use
`dropRetry = { key, tries, alerted, after }`, where `after` is a game-clock deadline in ms.
Each retry after the threshold sets a new one-minute deadline without repeating
the alert until a transfer succeeds or the drop changes.

The module emits `mine.ore` with `{ id, name, count }` and `mine.progress` with
`{ level, branch, done }` through `SO.mods.state.emit` when available.
`progress.done` and `mine.progress` count each branch once. Rows save the counted
branch as `counted`, so recovery after a restart or a finished row re-entering
`done` does not count it again. Rows saved before `counted` existed take their
branch as counted when they load in state `done`.
In continuous mode a finished worker claims the next branch before returning to its
old junction. `returning = {branch, junction}` saves that claim with the old route.
The planner reserves the shared pass through the old junction to the new branch,
then replaces the route at the junction. `progress.nextBranch` counts all claims,
including returns in flight, and cannot exceed the budget. At the budget workers
park at branch ends. A higher budget followed by `start` reopens finished workers.
`so-mine-plan.lua` owns the pure movement decisions, geometry, ore recognition,
and inventory rules. Its `next(job, row, lookup, inventory, fuel)` returns a batch
description without network, storage, or server calls. `row.pose` and `row.goal`
are world poses. `lookup(cell)` returns nil for unknown, false for air, or block
data. The caller reserves `cells` before sending `steps` and applies the actual
report rather than assuming the returned expected `pose`. Multi-action batches
also return `actions`, each with a one-based `first` index into `steps`.
`ore(data, ores)` accepts an optional list of supported ore names and matches
block names or ore subtype tags before applying the ore classifier.
`cleanup(inv, all, side)` returns select/discard steps for junk, retaining one
sealing stack unless `all` is true. `side` defaults to `down`.

### cells

`cells.handoff(from, to, x, y, z, dim)` atomically changes one reservation owner
through the generation store. Failed saves leave the old owner in place. Other
reservations keep their owners. Repeating a completed handoff succeeds.

At 85% disk use, dug-mark KEEP prompts again after one minute. Consent remains
required before any mark is removed.

SO4 owns this API on `SO.mods.cells`. Coordinates are integer block positions. All one-cell calls accept an optional last `dim` string, defaulting to `minecraft:overworld`. The same coordinates in different dimensions are separate cells. `who` is a computer id or a lease string.

`cells.reserve(who, x, y, z, dim)` returns true, or false and `held` if another owner holds the cell. Reserving a cell already held by `who` succeeds.

`cells.reserveMany(who, cells)` takes `{ {dim, x, y, z}, ... }`. It reserves all cells or changes nothing. A conflict returns false, `held`, and the conflicting input cell.

`cells.release(who, x, y, z, dim)` returns true. It frees the cell only when `who` holds it. `cells.releaseOwner(who)` frees all cells held by that owner. Silence never expires a reservation.

`cells.owner(x, y, z, dim)` returns the owner or nil. `cells.isFree(x, y, z, dim)` returns a boolean.

`cells.markDug(x, y, z, dim)` records a dug block. Repeating it does not increase the dug count. `cells.isDug(x, y, z, dim)` returns a boolean.

`cells.forget(x, y, z, dim)` drops both the reservation and the dug mark. `cells.forgetOwner(who)` frees that owner's reservations and emits state event `cells.forget` with `{ who, count }`. Direct API calls queue the event until tick. Dug marks remain.

`cells.list(who, max)` returns up to `max` copied reservations as `{ dim, x, y, z }`. The default limit is 256. Results have no defined order and edits to them do not change reservations.

`cells.counts()` returns `{ reserved = { [who] = n }, dug = n }`. Tick registers a `cells` state view returning these counts when `state.view` is callable.

Reservations save through `so-store` to `so-data/cells/res` on each change and reload on boot. Dug marks save per 16x16x16 section to `so-data/cells/<dim>/<sx>_<sy>_<sz>`. Dimension names replace `:` for valid paths. The cache holds at most 256 sections. Eviction saves a changed section before removing it. Tick saves at most eight changed sections. Bulk work calls `SO.breathe`, never `sleep`.

A section value is `{ format = "hex4096", bits = string, used = gameMs }`.
`bits` has exactly 1024 lowercase hex characters. Cell index
`x%16 + 16*(y%16) + 256*(z%16)` uses bit `index%4` of character
`floor(index/4)+1`, with the least significant bit first. Each generation has a
2048-byte write budget. The loader accepts old numeric-index boolean tables.
Their next save publishes two compact generations through `so-store`, so the
backup also shrinks. An interrupted migration recovers the newest valid
generation in either format. No consent is needed for this lossless conversion.
Reads refresh LRU time in memory. A section with marks persists that time at
most once per minute unless its bits change.

`cells.retirement()` returns nil, a pending request
`{ id, status = "pending", bytes, count, reclaim, text }`, or a decision notice
`{ status = "allowed"|"kept", text, untilAt }` for 30 seconds.
At 1000000 bytes of section files, tick proposes eligible sections in LRU order,
aiming for 650000 bytes. Accounting includes primary, backup and temporary
generations, with a 500-byte minimum per file. Requests wait for lossless
migration and for at least one eligible section. The server checks at most once
per ten seconds. The persisted request serial prevents old buttons from matching
a new request after a restart.

`cells.decideRetirement(id, choice)` accepts only the current request's `id` and
`choice = "allow"|"keep"`. It returns true on a decision, or false and an
optional storage error. A decision must save before any section is deleted.
`allow` rechecks protection and removes only the offered sections that remain
eligible and unused since the request. It removes backup and temporary files
before the primary and evicts the cached section. A crash can leave some
approved sections intact. Restart never resumes deletion. Forgotten cells become
unknown, and mining clears their cached block facts so later travel inspects
them. The request can reclaim less than offered if protections change.

`keep` deletes nothing. The generation store `so-data/dug-policy` records the
choice and a new request threshold at 150% of current use, including across
restarts. A completed `allow` also uses that growth step if protected areas keep
storage above the original threshold. The 80% disk guard remains in force.

`cells.rememberWorker(id, worldPose, dug)` records the worker's last reported
pose and up to 32 world-frame journal cells in that policy store. Tick and
reservation-owner release flush updated records. Records remain after job
removal until a later report replaces them. They protect the dug cells and a
48-block margin around the pose for the worker's 32-move backtrack and an
unreported batch of up to 16 moves.

Mining, lumber and lease modules expose `dugProtection(protect)`. Each must
return true before retirement can proceed. The callback
`protect(dim, coordinateTree, margin)` protects the bounding box of all nested
`{x,y,z}` points, expanded by `margin` blocks. Mining covers its running geometry,
including a 64-block vein margin, and saved worker routes. Lumber protects its
running farm at every height and its saved worker and service routes. Open
leases protect their world pose with a 48-block margin. Any reservation protects
its entire section. Uncertain poses, unresolved recovery and leases without a
world pose block retirement. Dirty sections are ineligible. These checks repeat
when `allow` is pressed. `mine.forgetDug(sectionPaths)` invalidates cached block
facts after retirement. Its argument is a `{ [sectionPath] = true }` set.

Wire type `cells.forget` takes `{ who }` and replies with `{ confirm = token }` without freeing anything. The same sender must send `{ who, confirm = token }` within 30 seconds. A valid confirmation runs `forgetOwner`. Invalid, expired, reused, or mismatched confirmations reply with `err`.

### display

The DISK status control opens byte counts for every store and a persistent
pressure or pending-event warning. AR keeps the disk warning visible until the
condition clears, including with event alerts off.

SO5 owns this API on `SO.mods.display`.

The server terminal uses `display.terminal(model, view, w, h)` to return a
Big Tiles frame. The model is the status model. The view supplies `id`,
`mode` as normal, code or log, `uptime`, `log`, `offset`, `code`,
`expires` and `now`. Times use game milliseconds and the log offset counts
back from the newest line. `SO.terminal` holds the runtime view. Display tick
draws it once per second. Prints enter a volatile 200-line log, with long lines
split into pieces of at most 4096 bytes. L opens the full log, L or Esc returns,
and Up or Down scrolls. P opens or renews the existing five-minute invite.
Esc clears it. Used or expired invites return to the normal page.

`display.monitorTouch(side, x, y)` queues a touch on the server's own monitor.
The next display tick routes it to the drawn screen and handles navigation.
Discovery runs at most every five seconds. The monitor uses its real size,
text scale 0.5 and the spec palette. Its status session and role are volatile,
separate from paired displays, and require no rednet traffic or saved files.
`display.screen(role, render, input)` registers one screen. `role` is a string.
A second call for the same role replaces the first. `screen(role)` with no
callbacks returns the registered `{ render, input }` or nil.
`render(w, h, session?)` receives the target size and server-local session and
returns `{ rows, buttons, palette? }`. The module sets `rev` and `body.role`,
and clips the picture to the `hello` size. `input` accepts
`{ from, id, x, y, role, session }` and optional `text`. The session is the same table
passed to render; it is never sent on the wire. `role` is the screen that was
showing. Local monitor input receives its own session through the same field.
The session includes client `id` and `keyboard`, true only when hello reports
`body.keyboard == true`. Monitor clients report false. A missing flag uses touch
controls. Monitor panels open the shop with a SHOP button; keyboard panels retain
typed quick search and quantities. Kit-free render callbacks receive the client
ID as their third argument. Their generic content height excludes two navigation
rows for mining, lumber, shop, status and AR. Every kit-free destination has a
visible generic return button on 26x20 pockets and 29x12 monitors.
Existing callbacks can ignore the added session argument and field.
Dug-storage requests occupy the top of every role, including `status` and
`generic`. The server wraps their text and shifts the role below it. Buttons
`dug.allow/<request-id>` and `dug.keep/<request-id>` carry labels `allow` and
`keep`. Consent requires a current button, its full visible label, and input
coordinates inside its drawn rectangle. Stale or clipped buttons do nothing.
Clients keep the existing `view.frame` and `input` wire formats. AR shows a
pending request until a player decides, even with event alerts disabled.

Frame signatures and revisions are kept per role, size and session. Status additionally
keeps revisions, tile paging and alert state per display session. Panel revisions
also stay per session. Every status frame carries the Big Tiles palette and that display's scale. Existing renderers
may ignore the size arguments. Older partial installs without `so-ui.lua` retain
the legacy status renderer.

The server-only `so-ui.lua` kit exports `palette`, `font`, `clock(epochMs)`, `size(w, h)`,
`grid(w, h, columns?)`, `ink(bg)`, `glyph(ch, ink, bg)`, `canvas(w, h, bg?)`,
`status(model, w, h)` and `alert(model, w, h)`. Sizes are P, T, M, L, XS or
`generic`. Grid returns one-based `{ x, w }` columns and the tile-row count.
Glyph returns three `{ text, fg, bg }` rows with inverted sextant cells.
Canvas coordinates are one-based. Its methods are `put(x,y,text,fg?,bg?)`,
`fill(x,y,w,h,bg)`, `center(x,w,y,text,bg?)`, `big(x,y,w,text,bg)`,
`hit(id,x,y,w,h)`, `header(name,right?,bg?)`, `alert(text)`,
`tile(x,y,w,label,value,sub,bg)`, `button(x,y,w,label,id,bg?,h?)`,
`listRow(y,text,state)`, `search(x,y,w,text,id?)` and `frame()`.
Frame returns compact runs, buttons with height and the palette.

`so-ui.clock(epochMs)` returns `{ h, m, s, date, hm, hms }` in Amsterdam time.
`date` is `YYYY-MM-DD`; `hm` and `hms` are zero-padded. UTC+1 becomes UTC+2
on the last Sunday in March at 01:00 UTC, and returns to UTC+1 on the last
Sunday in October at 01:00 UTC. Conversion uses Gregorian calendar arithmetic and
does not depend on the host time zone. Status and panel headers, shop stock
sample times, and new terminal log timestamps use this clock. Every new log
line starts with `hh:mm:ss ` before the message. Durations are unchanged.

The pure status layout takes `model.tiles`, ordered turtles, leases, alerts,
ore, logs, disk, displays, drops and pairing. Each tile is
`{ label, value, sub, bg }`. The model also has `time`, optional `alert`,
`alerts`, `log`, `terminalSubs`, `okShort`, `lostShort`, `oreShort` and `page`.
Takeover layout takes `takeover = { text, count?, detail?, sub? }` and defaults
the count to the length of `alerts`. Gathering stays in display handler and tick
paths. It reads state view `.alert` keys, registered worker machines, lease
status, drop points, display sessions and the server root disk. Ore and log
totals come from `daily.today()`, with `-` on stale tiles when unavailable.
Ore shows `+N last 10 min` in blue; logs show `logs delivered` in green.
Mining shows the daily ore total and its two largest item counts, ordered by
count descending then name ascending, with short names. Lumber shows daily logs.

Alert identity is the state key plus its serialized value. Each display sees
at most one takeover for each identity and at most one in 30 seconds. The
coral takeover ends after 5000 milliseconds or any tap. Suppressed identities
stay in the alert bar and do not trigger a delayed takeover. The alert bar
opens the latest alert until tapped. XS `next` cycles the tiles. Status buttons
select mining, lumber, shop or generic. At 26x20, glance row 20 shows
`<  glance n/m  >  PANEL`. Its `prev` and `next` inputs wrap three pages of
three tiles independently per pocket. The first page shows turtles, alerts and
ore; later pages show leases, logs, disk, displays, drops and pairing. The `panel`
input selects panel mode.
No saved data or wire type changes are required.

Button id `generic` returns that display to the generic screen. Button id
`status` returns to status from any screen. Generic buttons can select `shop`,
`mining`, `status`, `lumber`, `ar` and `panel`. Missing lumber and AR buttons are injected
for legacy generic screens. The drops list has `new` and `status` buttons, so
it suppresses that injection and reaches the other roles through ADD NEW.
Generic screens at least 39 columns wide also gain a PANEL header button
when the panel screen is loaded, unless they already have one.
This keeps panel mode reachable on monitors
when the drops module supplies the generic screen.

The module stores `{ roles = { [computerId] = role }, far = { [computerId] = true } }`
in `so-display`, with string computer ids. Old files without `far` remain valid.
The default role is `generic`, except a 26x20 display without a saved role
uses `status` when the kit is installed. Saved roles, including `panel` and `map`, take precedence. Both settings
survive a restart.
`display.far(id, on)` sets or clears the far flag through `so-store`. It returns
success and an optional save error. A successful change sends the new scale on
the next tick for a subscribed display. A failed save keeps the previous setting.
`display.palette` is the Big Tiles palette as RGB numbers at indices 0 through 15.
Renderers opt into it by returning `palette = SO.mods.display.palette`.

After ten seconds without a frame, the client keeps the last picture with stale
backgrounds and preserves inverted big digits. It draws a centred coral 21x7
NO SERVER tile, elapsed time in big digits and a retry countdown. Palette-capable
outputs repaint the timer once a second. Outputs without palette support retain
the legacy bottom-right stale marker and repaint on retries. The retry schedule
still uses jittered exponential backoff capped at 30 seconds.

### map

`so-mod-map.lua` is installed only on the server. It registers
`display.screen("map", render, input)` during tick. It adds no wire type.
The saved display role may be `map`; older role and far settings remain valid.
The display composer draws a teal `MAP` button at the right of every Big Tiles
header while the map screen is registered. Input `map` remembers the drawn role
in `session.mapReturn`. Input `map-back` restores that role, or status after a
restart. This also works on the server's local monitor.

`mine.mapView()` returns copied `{ dim, home, homeSet, bottom, length, mode,
branches, turtles }`. `branches` covers assigned branches and progress.
`turtles[id]` has `{ pose, state, dim }` in world coordinates.
`lumber.mapView()` returns copied `{ dim, area, ground, saplings, turtle }`.
The optional turtle has `{ id, pose, state }`. These getters do not save or
advance jobs. The map calls them from tick, together with registry, lease and
drop APIs. Registry workers without a job also appear when their pose is known.
Numeric drop dimensions are normalized to world dimension strings.

`render(w, h, session)` stores its state under `session.map`. `fit` starts true.
`x` and `z` hold the centre, and `scale` is integer blocks per colour cell.
`level` starts as `all` and cycles through `mine`, `surface`, `all`.
Mine selects the job bottom; surface selects server y, farm ground or mine home.
All projects every scene marker. Dug scans sample the mine bottom and its next
block, mine home, surface, farm ground, and known chest and turtle y levels.
The map is north-up with x horizontal and z vertical. It filters to the server
dimension, or the configured job dimension when the server position is absent.

Geometry tests intersections per screen cell. Route length and branch count do
not increase frame work. Dug scans call `cells.isDug` at most 256 times per
render and retain a viewport-sized raster. A completed scan replaces old marks.
View changes reset the scan. Changing tracked levels restarts the scan while
retaining its visible raster until a new pass completes. Empty shaft heights
are skipped. At coarse zoom, any found dug block marks its
projected cell. New dug blocks appear as the scan advances. Rendering never
calls sleep. Existing cell reads may use `SO.breathe` during bulk work.

Planned passages use panel grey `7`; dug cells use light grey `8`; the farm
outline uses green `d`. `H` marks the shaft in teal `9`. Chest letters use
purple `a` or coral `e` when broken. `@` marks the server in teal. Turtles draw
last as `^ > v <`, with an id to the right at one block per cell when it fits.
Busy uses green `d`, idle amber `1`, lost/range/stale coral `e`, and done blue `b`.
Markers at the same projected cell overlap; turtles take precedence.

Drawn inputs are `map-fit`, `map-in`, `map-out`, `map-n`, `map-w`, `map-s`,
`map-e` and `map-level`. Zoom ranges from 1 to 4096 blocks per cell. Panning
moves three displayed cells. Header placement follows the row drawn by the loaded kit, including row 2 in
the padded kit. Controls occupy the bottom three rows at every
size, including 26x20 and 29x12. The header shows north and blocks per cell.
The remaining rows expand with the display. All view and scan state clears on
server restart and remains independent per paired display or local monitor.

### panel

`so-mod-panel.lua` exports module metadata and `tick(now)`. It registers the
`panel` screen and has no wire handlers. It is installed only on the server.
Search and page selection live in the display session and clear on restart.
The saved display role can be `panel`; no new saved file or wire type is added.

Tick reads registered screens through `SO.mods.display.screen(role)` and reads
mining and lumber state from their rendered headers. It gathers the state view's
`.alert` values for the alert list. Render uses these cached facts and the local
session. Missing registered screens show grey controls marked `not loaded`.

Main-screen inputs are `mining:start`, `mining:stop`, `lumber:start`,
`lumber:stop`, `search`, `order:1`, `order:16` and `order:64`. Typed text changes
only this panel's search. START and STOP forward one input to the corresponding
registered screen. An order applies that search to the registered shop screen,
renders its first list page, selects its first `item:<name>` and sends exactly
one `order:<count>:<name>`. Shop sorts by descending stock count and then name,
which defines the best match. A search with no match sends no order. This uses
the existing shop search and selection state, shared with full shop screens.

`status` is GLANCE. `alerts` opens the paged alert list, with `alert-prev` and
`alert-next` wrapping pages. `pair` opens PAIR NEW CLIENT. Its `pair-code`
button is NEW CODE. Only a paired display with a matching session ID can
request it through authenticated `input`. The server-local `SO.pairCode(id)`
returns `{ code, expires }` for that requester, or nil if another display or
the terminal owns a pending invitation. It calls the same invitation path as P.
Repeated requests from the owner preserve the code, expiry and bad-attempt count.
The session holds the invitation. Its own signed `view.frame` shows six kit
big digits and remaining minutes and seconds. No invitation enters shared
screen data or broadcast frames. Other displays keep the normal pair page.
Use, expiry, five bad attempts or terminal cancellation restore that page.
`panel-back` returns to the main panel.
At 26x20 the controls match panel-P. Larger monitors use the kit grid; short
screens use compact controls. The pairing handshake and job planning are unchanged.

### lumber

`start` checks the disk guard, configured area and ground height, usable wood and
fuel drops, a configured unbroken sapling chest, an added paired worker without
an uncertain or lost pose, and reported nonzero fuel. Refusals name every missing
item in order. Empty sapling chests still permit felling after start.
SETUP uses compact red and green readiness rows. Chest alerts use the mining
cause format and include the drop point and reason in `lumber.alert`.


`SO.mods.lumber` plans a tree farm for one paired worker with an axe. It is stopped until the operator configures it and sends `start`. It uses `so-plan.lua` and the pure helpers in `so-lumber-plan.lua`.

The `lumber` display accepts these text commands:

- `area <x1> <z1> <x2> <z2> <ground y>` sets the farm bounds and soil height.
- `saplings <x> <y> <z> <front|down>` sets the sapling chest's own coordinates and access side.
- `add <id> <x> <y> <z> <n|e|s|w>` anchors one worker. A recovery park report supplies the journal pose for `P.frame`.
- `start` begins work. `stop` parks after the current lease reports.

For `front`, `L.access` chooses a horizontal neighbour at the chest's height
and faces the turtle towards the chest for `suck`. It chooses the eligible cell
with the shortest Manhattan distance from the turtle's current position.
Ties use north, east, south, west order. For `down`, the only candidate is
`{ x = x, y = y + 1, z = z }`, and the turtle uses `suckDown`.
The lumber caller excludes cells at or below soil height, known obstacles,
chest cells and planted spots at soil height plus one. Keep access cells clear;
these checks use the planner's known state. If no eligible cell remains,
the turtle holds with a named `saplings #<id> unreachable at x,y,z` alert.

The job saves through `so-store` at `so-data/lumber/job`. It contains `dim`, `area`, `ground`, `saplings`, `turtle = { id, frame, pose }`, and `spots`, keyed by `"x,z"` with `{ kind, plantedAt }`. It also stores the planner phase, progress, inventory facts, and delivery count for recovery. A restart sends a stationary recovery park on its first tick using the saved
frame. It does not require a memory-only lease pose or range observation.
The report sets the world pose to `P.toWorld(frame, lease.report.pose)` before
work resumes. Recovery parks bypass the work range check; movement leases keep
both range and reservation checks. A worker without a saved frame or an `add`
anchor shows `waiting for reported pose`.

The planner sends at most one lease, tagged `lumber`. It reserves cells under `lumber:<id>` and checks every planned cell with `P.inRange`. Lost or expired leases require recovery. Idle workers receive `P.park`.

Service trips use `L.travel(from, target, ground)` in both directions. Horizontal
travel stays at soil height plus two. Vertical travel uses the departure or
arrival column. Chest trips descend only at the access cell; return trips
restore the saved pose in its own column. Travel never digs saplings or
propagules, and service travel never digs at soil height plus one or lower.
Old saved detours are cleared for service trips. Blocked service routes hold
instead of bypassing the obstacle. A failed lease send releases the lumber
reservations and holds work while the next tick attempts a stationary park.

Replacing a turtle requires its lease to be closed. A different turtle also
requires a stationary park report for the old one. If needed, `add` parks the
old turtle and asks the operator to retry after its report. Until then, the
old turtle remains assigned. Replacement clears the cached park state.
Idle park expiry still needs the worker fix that prevents journal backup.

Search rows are three blocks apart at soil height plus two. Probes find logs at soil height plus one and remember their spots. Dark oak is excluded. The worker fells each column and replants the matching sapling from above. Movement inspects before digging and permits only logs, leaves, and small plants. Soil and stone remain intact. Planted spots become eligible again after ten minutes.

An empty sapling chest disables replanting while felling continues. It emits `lumber.alert` with `{ text = "saplings #<id> empty at x,y,z", reason = "empty", point }` once. Wood goes to `drops.pick("wood", pose)` using `drops.steps(point)` after each round or when fewer than three inventory slots remain. The wood chest also receives sticks, apples, leaves and excess saplings. The turtle keeps one sapling per known spot of that species, with at least one for the current tree. Inventory pressure also interrupts harvesting to unload. Round-end unloading includes junk even without logs. A failed junk drop holds and raises an alert.

Move and dig failures increment a saved `failures` count. Successful inspections do not reset it. Successful movement or digging resets it. Three failures hold and emit `lumber.alert`. Holds park and show `Fix cause, then type start`. The operator fixes the cause and sends `start` to clear the hold and retry through pose recovery. Low fuel uses a fuel drop and `P.fuelValue`; logs are never burned. Its threshold is the distance to the selected fuel chest access cell via soil height plus two, plus a margin of 32 fuel.

Wood deliveries count the reported inventory decrease only when every step in the
select, inspect and drop batch succeeds. Failed inspections call `drops.note` for
wood, fuel and sapling chests. Supply trips inspect before taking items. A failed
inspection holds the turtle. Repair the chest and send `start` to retry. Three
failed inspections mark the drop point broken in the generic editor. Use `fix`
there after repairing it. Successful inspections clear earlier failure counts.

Sapling service reuses a registered point at the same coordinates, dimension and
side. If none exists, it registers a `storage` point with the stable id
`lumber_saplings_<dim>_<x>_<y>_<z>_<side>`. These points share the 64-point limit.
A broken point or failed registration holds the turtle and asks for `start` after
the drop point is fixed. Changing the sapling coordinates leaves old points in
the editor, where the operator can remove them.

The screen callback accepts `render(w, h)` and draws Big Tiles from job state.
It shows eligible spots, delivered logs, carried saplings, turtle phase, fuel,
and the next scan countdown. A missing countdown uses a stale tile. The logs
tile uses the delivered total because no daily total exists. START and STOP
use the text commands above. SETUP lists the area, ground, sapling chest, turtle
and their text commands, with NEXT on small screens. Its BACK button returns
to lumber; the main BACK has
id `status`. Calls without dimensions retain the legacy rows. Successful deliveries emit `lumber.logs` with `{ id, count }`. Alerts emit `lumber.alert` with `{ text }`.

### drops

SO8 owns this API on `SO.mods.drops`. It handles `drops.edit`.

`drops.pick(kind, nearPos)` takes a kind string and `nearPos = { dim, x, y, z }`, all integers. Kind is `fuel`, `ore`, `junk`, `wood`, `storage`, or `any`. It returns `{ point, chain, alert, reason, failedPoint }`. `point` is `{ id, dim, x, y, z, side, kind }` for the nearest usable place, or nil. Usable means the same dimension and fewer than 3 inspect failures. The chain is the requested kind, then `any`, then the string `hold`. When the requested kind is `any`, that stage appears once. Each stage before `hold` is `{ kind, point, usable }`. `point` on the result is the first usable stage. When no stage is usable, `point` is nil and `reason` is `none` when no matching point is configured, or `broken` when all
matching points have three inspection strikes. `failedPoint` identifies the nearest
broken point. The alert names the kind, cause and point coordinates. That call also
emits `drops.alert` with `{ kind, text, reason, point }` when `SO.mods.state.emit` is a function. A call whose first argument is not a string returns nil. `tests/so/so0.lua` calls `pick({ name = "minecraft:cobble", n = 1 })` and gets nil.

`drops.list()` returns a copy of every drop point as `{ id, dim, x, y, z, side, kind, broken }`. `broken` is true after three inspect failures. Editing a returned point does not change stored points.

Drop points use the chest's own coordinates. The caller positions the turtle
beside the chest facing it for `front`, or directly above it for `down`.
`drops.steps(point)` takes a point. Side `front` returns `{ { op = "inspect" }, { op = "drop" } }`. Side `down` returns `{ { op = "inspectDown" }, { op = "dropDown" } }`. A call with no string `id` returns `{}`, including `steps({ name = "minecraft:cobble", n = 1, where = "front" })`.

`drops.add(point)` takes `{ id, dim, x, y, z, side, kind }`. It returns true, or false and a string. The 65th distinct id returns false and `full`. The same id with the same fields returns true and does not add a second point or change the failure count. Side `up` returns false and `side`.

`drops.remove(id)` returns true. A missing id returns true.

`drops.fix(id)` sets the failure count to 0 and returns true, or returns false and `missing`.

`drops.note(id, blockName)` records one inspect while the failure count is below 3. A non-empty string clears that count. Nil counts one failure. The third failure makes `pick` skip the point. Further notes leave it skipped. `fix` clears it. A successful inspect does not clear a point that is already at 3.

The generic Big Tiles screen shows short row numbers, kind, coordinates, side
and state, with green or coral state stripes. A row tap selects the point for
FIX and REMOVE. The default is the first broken point, or the first point if
none are broken. Long lists have PREV and NEXT controls. ADD NEW opens the
existing draft editor with kind, side, dimension and coordinate controls.
The list offers MINING, LUMBER, SHOP, AR and PANEL on its bottom row. SHOP uses purple;
the other buttons use slate. At 57x24 they occupy rows 22 through 24 with
widths 11, 11, 11, 10 and 10 and one-column gaps. Other sizes use the grid rule,
with one-row navigation in compact layouts. The editor keeps ADD and BACK.
The display module still injects its legacy LUMBER and AR header buttons
into the editor, plus PANEL on screens at least 39 columns wide when that
role is registered. The editor's BACK returns to the list. The list's BACK returns to status. Gather copies module state
before the private pure layout builds the requested display size.
The kit-free generic editor pages the point list with `prev` and `next`. Its draft and
buttons fit 26x20 pockets and 29x12 monitors below navigation and above the
bottom input row. Draft and feedback are shared between displays; paging is per display.
Existing `input.body.text` accepts `x y z` or `dim x y z` to set the draft,
and `add <kind> <x> <y> <z> [front|down] [dim]` to set and save it.
Omitted side and dimension keep the draft values. Dimension may be supplied
without side. All coordinates and dimensions must be finite integers. Dimension
0 is overworld, -1 Nether, 1 End. Invalid text leaves the draft unchanged and
shows an error. Button `add` and typed `add` show save failures in the editor.
No client or wire fields change.

The list is saved through `so-store` in the file `so-drops`. A change emits `drops` with `{ op, id }` when `state.emit` exists.


The drop editor's `FROM #N` copies a paired turtle's fresh world pose into the
unsaved draft. FRONT selects the horizontal cell it faces; DOWN selects `y-1`.
It maps the server dimension to drop dimensions 0, -1 or 1 and refuses unknown
maps, moving turtles, stale fixes and uncertain journals. Saving still needs ADD.

### ar

`so-mod-ar.lua` uses attached cc_ar `ar_controller` peripherals. It exports
`tick(now)` and has no wire handlers. Without a controller it does not draw.
It registers `display.screen("ar", render, input)`. The generic screen reaches
AR through its fallback button or the drops draft editor. The `ar` role
survives restart through `so-display`.

The screen shows the controller count and one tile per layer. Each tile shows
1 and "layer on" in green, or 0 and "layer off" in grey. Tapping a tile toggles
its layer once. Small screens use compact tiles. BACK returns to status.
Gather copies the layer state before the private pure layout renders it.
All layers are enabled initially. Switches save
through `so-store` to `so-data/ar` as `{ turtles, leases, drops, alerts }`, with
boolean values. A failed save leaves the current switches unchanged.

- `turtles` draws a twelve-edge box and heading arrow for each worker with a
  pose. Its short `#<id>` label uses size 0.5. State comes from the machine registry and
  `lease.status`, with `lease.inRange` checked when available. Two minutes
  unseen takes precedence and uses stale. Lost or out-of-range turtles use
  coral. Waiting, holding and numeric fuel below 64 use amber. Unlimited fuel
  is exempt. Working, mining, running and lumber states use green. Other open
  leases use teal; idle turtles use white. Last contact uses the newer registry
  or lease timestamp, including work reports.
- `leases` draws one blue bounding outline per `mine:<id>` or `lumber:<id>`
  owner derived from the machine registry using `cells.list(owner, math.huge)`.
  It includes all that owner's cells in the server dimension. Scene gathering
  does not call `cells.counts()`, whose reservation scan can breathe during a burst.
- `drops` draws a small box per point and a size-0.5 label with the first letter
  of its kind, such as O or F. Broken points use coral; other points use white.
- World labels sit above their blocks and stack 0.25 blocks apart when their
  horizontal positions are within two blocks. Labels use at most eight characters.
  The nearest 16 turtle labels and eight drop labels per kind remain visible,
  ordered by distance from the configured server position, then element id.
  Without server coordinates, element id determines the order. Boxes and arrows
  remain visible when their labels exceed these limits.
- The HUD starts at `(4,72)` in GUI units, below the Difficulty overlay.
  Its three 56-unit tiles have eight-unit gaps for TURTLES total, ALERTS count and DISK percent.
  Each has a translucent backing, white text and a four-pixel state bar.
  TURTLES uses the same machine registry and role filter as the status screen,
  including paired idle workers. Its bar uses the status screen's lost-lease
  check rather than treating an old registry timestamp as a missing turtle.
  Lost turtles, active alerts and disk use of at least 80 percent use coral;
  healthy tiles use green. Unknown disk use is stale.
- `alerts` shows the newest active `.alert` value in a coral banner for five
  seconds after observation, as the first row inside the HUD. The tile row moves
  down 14 GUI units while the strip is visible. Retained history detects repeated identical
  alerts; without history a changed serialized value renews the banner.
  Expiry deletes the banner while the HUD keeps the active alert-key count.
  The switch hides the banner without hiding the HUD count. Controllers without
  `drawRect2D` show the same five-second text row. Dug-storage notices sit below the tiles.
  `drawRect2D` receives opposite corners, including the tile bars.

World colours are signed ARGB with alpha FF. Green is `FF3DDC84`, amber
`FFFFC24B`, coral `FFFF6B5E`, blue `FF5AB0FF`, teal `FF2DD4BF`, stale
`FF4A5468` and white `FFF2F4F8`. HUD backing is `C00E1626`.
Alerts expire five minutes after the event timestamp, or first observation when
no timestamp is available. Repeated events renew the deadline and the short
banner. Expired snapshot values stay hidden until a new event arrives.
Text-only controllers use the same five-second alert deadline.

Known `so-server.cfg` `pos.dim` filters world elements. Numeric drop dimensions
map 0 to `minecraft:overworld`, -1 to `minecraft:the_nether`, and 1 to
`minecraft:the_end`. Without a known server dimension all elements are shown.

Tick discovers controllers at most once every five seconds without waiting.
It compares scenes and draws changes at most once per second. Stable element
ids let it delete removed elements with `ar.delete`. On first attachment it calls
`ar.clear()` when available to remove elements left before server boot. Later
frames clear only when delete is missing. Each frame ends with one `ar.update()`.
Colours are signed ARGB integers. Drawing errors drop that controller until later discovery.
The layers do not draw item icons.

## Plan helpers

Planners load `local P = dofile("so-plan.lua")`. This library is pure Lua. It does not use `SO`, rednet, waits, or storage. Facing is 0 north, 1 east, 2 south, and 3 west. North decreases z and east increases x.

`P.frame(worldPose, journalPose)` anchors a journal frame at a known world pose. World poses use `{ dim, x, y, z, facing }` and journal poses use `{ x, y, z, f }`. The frame is `{ dim, rot, ox, oy, oz }`. `rot` is the clockwise quarter-turn count. `P.toWorld(frame, journalPose)` converts to a world pose. `P.toJournal(frame, worldPose)` is its inverse.

`P.chestPresent(result)` recognizes inspected chests, barrels and shulker boxes.
`P.transferFailure(kind, result)` keeps explicit transfer errors such as `no inventory`.
`P.chestError(kind, reason, point)` formats a named chest cause with coordinates.
For ids longer than eight characters, cause and coordinates precede the full id.
`P.chestCheck(points, kind, near)` reads same-dimension points and returns `{ok,text}`.
`P.missing(checks)` returns every unmet text in order. These helpers write no state.

`P.ahead(pose, dir)` returns the x, y, z of the cell `forward`, `back`, `up`, or `down`. `P.apply(pose, op)` returns a new pose after a move or turn. Other operations leave the pose unchanged. Both accept world or journal poses and preserve the facing field convention. `P.replay(startPose, steps, results)` applies only operations with a corresponding successful result.

`P.path(from, to, opts)` returns `{ steps, cells, pose }`. It turns and moves to the target cell in axis order `opts.order`, default `"yxz"`. An order must contain x, y, and z once each. With `opts.dig = true`, each move follows `dig`, `digUp`, or `digDown` as appropriate. `cells` lists every entered cell with its dimension. `pose` is the final pose. The path assumes success and does not avoid obstacles or reserve cells. Callers split steps into batches of at most 16. `P.chunk(steps, n)` returns the first n steps and the remainder as two arrays.

`P.inRange(lease, id, cells)` calls `lease.inRange(id, cell)` for every cell and returns false if any check fails. It returns true if the lease module or its range function is missing.

`P.rangeBatch(lease, id, action)` returns the action unchanged when all its cells
pass `P.inRange`. Otherwise it returns the longest prefix of complete entries in
`action.actions` whose cells pass, or nil if no action fits. The returned batch
contains only that prefix's `steps`, `cells`, `actions` and final `pose`. Atomic
actions without `actions` are accepted whole or refused. Mining applies this
before reserving and saving a lease, including supply travel. A shortened batch
keeps the full shaft and spine lane pass reserved until the worker exits it.
Intermediate reports extend the range before planning the remaining travel.
Lumber uses the same check with atomic actions and moves one cell per travel lease.

`P.park` is `{ steps = { { op = "inspectDown" } }, ms = 600000 }`. Planners send it to idle turtles and renew it when less than 60000 ms remains. A single `inspectDown` step marks a stationary park lease in the worker journal.
If it expires, the worker stays put and beacons every 30 seconds. An expired
work lease without the park flag starts fast beacons and backtracking along the
last 32 moves.

`P.fuelValue(name)` returns fuel per item for Minecraft coal and charcoal as 80, coal blocks as 800, lava buckets as 1000, and blaze rods as 120. Other names return 0. `P.free(inv)` returns the number of empty slots among the turtle's 16 slots using the occupied-slot report list.

## Pairing and so-keys

The server screen shows `Press P to pair`. The P key calls `pair.invite(screen)`. That draws a 6-digit code and the server id, and prints `Pair code: <digits> server <id>`. The code includes leading zeros. It is 4 crypto random bytes, read as a big-endian integer modulo 1000000. It works once and expires after 300000 ms. When it is spent, expired, or burned, the screen shows `Press P to pair` again.

The server keeps a pairing budget per sender id. A `pair2` step 1 and every rejected pairing message count as one try for that sender. Rejected messages are a legacy `pair` with a bad MAC and a `pair2` with a malformed body, a bad share or a wrong Ta. A step 2 without an open session gets `err` `session` and counts nowhere. After three tries inside 60000 ms, step 1 from that sender gets `err` `wait` and its legacy `pair` messages are dropped with `so-server: pair blocked <id>`. A wrong `pair2` code costs two tries, the start and the rejection. All senders together may start 20 exchanges per 60000 ms.

A failed guess is a bad legacy MAC or a wrong Ta. Each sender may fail three guesses at one code and then waits for the next code, so one sender cannot burn a code. Ten failed guesses at one code burn it, except guesses from a sender that proved its saved key with `body.auth`. Rednet sender ids can be forged, so a paired id without that proof counts like any other sender. Legacy `pair` carries no proof, so its bad MACs always count. Each rejection prints `so-server: pair rejected <id>`.

Sender ids can be forged, so these limits also let a forging computer slow pairing down. It can use up a victim id's tries for 60000 ms, use up the 20 starts for everyone, or burn a code with ten forged ids. It cannot learn the code that way. Press P for a new code. The terminal pairing screen lists the last four rejected sender ids on one `Rejected` line. A paired display can also create an invitation through the panel NEW CODE button. Re-pairing an id that already has a key needs a fresh invitation.

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

`pair.join(code)` looks up `so` / `server`. `pair.join(code, serverId)` sends to `serverId` and does not call `rednet.lookup`. Both run `pair2`, check Tb, and save the machine key after the second `ack`. `join` never sends legacy `pair`. A fallback would let a computer that answers the `so` / `server` lookup, or plain lag, turn a pairing into one a listener can test offline. Against a server from before `pair2`, `join` fails with `timeout` after two tries of 3 s. Failure reasons are `no code`, `busy`, `wrong code`, `proof`, `timeout`, `session`, `share`, `body`, `pub` and the save error.

### Rollout

This release accepts both `pair2` and `pair` on the server. Clients send only `pair2`. Update the server first. Then an old client pairs with legacy `pair` and a new client with `pair2`. A new client cannot pair with an old server; it reports `timeout` until the server updates. Pairings from old clients use `pair` and stay open to offline code tests, so update clients before pairing them where you can. The next release drops `pair`, `pair.derive` and `pair.session`; clients that have not updated by then must update before they can pair again. Saved machine keys keep working across both releases.

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

Worker uncertainty is also exposed by `lease.status(id).uncertain`. While it is
true, `lease.send` returns `nil, "pose uncertain"`, including recovery parks.
Uncertain beacons carry `uncertain = true` and omit `pose`.

### worker.anchor

Mining or lumber `add <id> <x> <y> <z> <n|e|s|w>` can replace an existing uncertain
assignment. Both screens and the worker show `pose uncertain: re-add turtle <id>`.
The operator supplies the turtle's actual position and facing. Normal duplicate
mining adds still fail; lumber retains its normal configuration guards otherwise.

`lease.reanchor(id, worldPose)` requires an uncertain worker and sends an
authenticated `worker.anchor` with `{ journal, pose = { x, y, z, f } }`.
`journal` identifies the uncertain worker journal. The worker accepts only its
paired server, only while uncertain, and only when that journal id matches.
It saves the supplied pose as a fresh journal, clears pending steps, moves and dug
history, then sends hello with `journal.recovery = { outcome = "anchored", journal }`.
Duplicate anchor requests re-send hello without resetting the journal, so a lost
confirmation can recover. A failed save retains uncertainty. The server retries
the anchor once per second
and keeps refusing leases until that matching hello arrives. Old lease callbacks
are cancelled during re-anchoring. Work then starts from the new assignment.

### Re-pairing after a server key reset

When authentication fails for `hello`, `beacon` or `step.report`, the server
sends `{ t = "pair.required", from = serverId }` on `so`. This is an unsigned
hint outside the authenticated envelope. It is not proof that a key was lost.
Clients only show it for their saved server ID, and keep the saved key and
normal authenticated message handling. An authenticated display frame or worker
reply dismisses the prompt. A forged hint can show a prompt but cannot delete or replace keys,
change the server ID, authorize work or reset the turtle journal.

Press P on the server, then enter its new code on the client. Displays accept
six digits; turtles also require Enter. Failed pairing retains the old key.
Only a successful authenticated pairing saves the replacement key.

## Visibility

`MORE` and the panel have `HEALTH` and `ATTENTION` buttons. These pages also
link to `ALERTS`, `EVENTS` and `ERRORS`. Paging and event filters belong to each
display session. `EVENTS` cycles known kinds with `KIND`, or accepts an exact
kind as text. `ALL` clears the filter. History pages query retained state events
newest first. Clearing an alert leaves its event in history until normal log
retention removes it. The browser does not copy the event log into another file.

`state.history.page` also accepts `reverse=true`, an exclusive `before` sequence,
`kind` for an exact match, and `alerts=true` for `.alert` kinds. The forward
`from` cursor remains exclusive. Both directions return `next` only when more
matching entries remain. Counts remain capped at 50.

`ATTENTION` reads broken drop points, saved job holds, lost or uncertain workers,
dug-mark consent, disk pressure and pairing activity. Rows open the screen for
that issue. Broken chests select their point; uncertain workers open setup.
Gathering never starts jobs, moves workers or clears errors. Repairing a source
removes its item on the next gather, within five game seconds.

`HEALTH` pages uptime, game and wall tick cadence, tick cost, event sequence and
bytes, snapshot age, free disk, modem count, online and lost paired machines,
open leases, clock reservation and recent errors. Snapshot age is unknown for
snapshots saved before this change. Health diagnostics do not change the game
clock or scheduling. Tick cost uses `os.clock()` and has computer tick precision.

`SO.error(text)` prints and records failures. Bad messages, bad MACs, replays,
missing reply keys and pairing rejections (`pair rejected`, `pair blocked`)
stay in the volatile terminal log. These rejected
packets cannot evict persistent errors. `so-data/errors` uses generation
recovery and a bounded ring of at most 128 messages. Each message keeps 2048
bytes. All three generations together use at most 64 KB. Records save at most
once per 30 game seconds, so a power loss can discard recent unsaved records.
The first record can save immediately. Save failures retain pending records and
appear on HEALTH. `SO.errors.status()` returns `bytes`, `cap`, `count`, `pending`
and `error`. The byte count includes current, backup and temporary files, for
integration with the disk ledger. Files already count toward filesystem disk
pressure. No disk ledger exists on this base.

## Builder jobs

`so-mod-build.lua` registers the `build` display role and the `build` lease owner.
It adds no message types or turtle operations. Workers advertise
`capabilities.parkBatch=true` in `hello` and `step.report`. An optional
`park=true` on the first step of a batch persists a stationary expiry policy
before the worker executes that batch. Builder requires this capability and sets
the flag on every lease. Older workers receive only recovery inspection leases
and cannot start builder work. Other jobs keep their existing expiry behaviour.
Its public pure geometry calls are
`expand(blueprint)` and `import(text)`, both returning a value or `nil, error`.
The blueprint has inclusive `x1,y1,z1,x2,y2,z2`, `shape` and optional `dim`.
`expand` emits unique bottom-up placement cells for floor/platform, wall/walls
and hollow box shapes. `import` reads main builder floor and walls commands.
The module also exports `tick()` and `dugProtection(protect)`.

The screen accepts `area x1 y1 z1 x2 y2 z2`, `shape <kind>`, `material <name>`,
`add <id> [x y z n|e|s|w]`, `import <main builder command>`, `start` and `stop`.
Reservations use `build:<id>`. Supply uses existing storage drop points.
Saved intents and target inspection reconcile placement after restart.
See [builder jobs](BUILD.md) for command conventions and proposed Gate B C15.
