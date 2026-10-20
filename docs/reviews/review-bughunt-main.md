# Bug hunt on main ece242a

Branch `review/bughunt-main`. The hunt is main only. `feat/wh2-base` and the open `feat/ssot-*` branches were read and not pushed.

Checked areas are concurrency, restarts, protocol and auth, the 1000000 byte disk, and chunk loading. The mock suite is `lua5.2 tests/run.lua`. On this branch that command is the pre-fix suite. The fixes live on other branches and were run there.

## Ranked findings

1. High. `buddy.lua:757` calls `peripheral.find("chatBox")`. Advanced Peripherals 1.21.1 `ChatBoxPeripheral` sets `PERIPHERAL_TYPE` to `chat_box`. A buddy turtle with a chat box never enters the chat loop at `buddy.lua:788`. Every other `peripheral.find`, `hasType`, and `getType ==` string on main matches a registered name. `modem`, `monitor`, `drive`, and `workbench` are CC:Tweaked mc-1.21.x `getType` results. `inventory` is `PeripheralType.ofAdditional("inventory")` and is only passed to `hasType`. `ar_controller` matches `docs/gemini-review.md:90`. `tm_gpu` matches `docs/gemini-review.md:98`. `player_detector` and `geo_scanner` are not used. Fix and test are in PR 30.

2. High. `server.lua:874` drops `minearmy` status when `ssot.cfg` exists and the sender is not a paired controller. An old miner has no controller secret, so the dashboard loses it. Commands stay gated at `server.lua:385`. The failing test is on the fix branch. It is `an old miner still reports after SSOT pairing is turned on` in `tests/server.lua`. Before the fix, `m.state().bots[5]` was nil. After the fix, `lua5.2 tests/run.lua` reports 99 tests passed. PR 31.

3. High. `miner.lua:303` deletes `miner.state` before `miner.lua:309` moves the temp file into place. The next save opens `miner.state.tmp` with mode `w` and truncates the only remaining copy. A Lua 5.2 copy of `miner.lua:291` through `miner.lua:309`, with a crash injected at each point, printed `load after crash 2` and then `load after second crash` with both files nil. The same delete-then-move shape is in `factory.lua:59`, `farmer.lua:79`, `builder.lua:98`, `lava.lua:101`, and `lumber.lua:90`. `hub.lua:156`, `roomsorter.lua:65`, `sorter.lua:50`, `buddy.lua:51`, and `store.lua:4` truncate the live file on open. Issue 32.

4. High. `atomic.lua:65` poisons SSOT after one failed save. `ssot.lua:256` then returns nil for every later request until restart. `wc -c *.lua` on this commit reports 977086 bytes. A 1000000 byte disk cannot hold those scripts plus `ssot.state`, `ssot.state.bak`, and `ssot.state.tmp`. The free-space check at `atomic.lua:53` only reserves one new copy. Issue 33.

5. Medium. `ssot.lua:93` keeps both cells of a `started` move with no expiry and no epoch check. `ssot.lua:311` increments the epoch on boot and still loads the move. A late commit fails at `ssot.lua:154`. `ssot-client.lua:115` then stops movement until reboot. `nav.lua:79` can reconcile after that reboot when GPS shows one of the two cells. A turtle that never returns leaves both cells taken. The existing test `offline occupancy and restart preserve both cells of uncertain moves` expects the block to remain. Issue 36.

6. Medium. `ssot.lua:229` compares `m.secret` with the controller key. `ssot.lua:247` copies that key into `result.auth`. A lower counter is rejected at `ssot.lua:238`. A different computer id cannot use a captured secret, because stock rednet sets the sender id from the sending computer. The secret still crosses the modem in requests, replies, and mesh copies, and it sits in plaintext in `ssot.cfg` (`server.lua:125`). Issue 35.

7. Medium. No file on main requests a chunk ticket. `gpshost.lua:16` and `hub.lua:507` tell the operator to keep the chunk loaded. `miner.lua:51` allows a turtle 96 blocks from the shaft. An unloaded chunk freezes the turtle. An ender modem does not load chunks. No force ticket is left behind, because none is taken. Issue 34.

## Checked and not confirmed as new bugs

Two turtles cannot reserve one cell. `ssot.lua:142` calls `occupied` at `ssot.lua:91`, which sees the other pose and any live move. `tests/ssot-checks.lua` already covers contention, expiry, and renewal. A duplicate request id returns the stored result for the last eight ids. A reordered lower counter is rejected at `ssot.lua:238`.

`ssot.lua:281` calls `sleep(0)` inside the save validator. That yields the server coroutine. The network loop is that same coroutine, so a second `handle` does not run until the save returns. `refresh`, `meshLoop`, and `gpuLoop` can run during the yield. This hunt did not show a lost SSOT update from that window.

`atomic.lua` promotes `ssot.state.tmp` and `ssot.state.bak` by generation. A crash during the temp write leaves the previous generation. That path is already tested in `tests/server.lua` for `server.state`. The poison flag above is the part that still stops the process.

Malformed SSOT tables are rejected by `ssot.lua:224` and `M.bounded`. The existing test `missing fields, bad types, cyclic, oversized and unauthorized packets do not mutate` passed on main.

## Not verified

Gate B was not run. This environment has no disposable Minecraft server. The live server was not touched.

Headless CraftOS-PC was not run for these cases. The mock suite was the executed check.
