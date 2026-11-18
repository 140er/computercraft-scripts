# Review of test/gateb-fixtures

The fixture library is Python test tooling. It does not change fleet Lua. Runtime behaviour on the live computers stays as it is on main `ece242a`.

Findings below are ranked. Each one names a file and a line on main unless the path is called out as `feat/wh2-base`. That branch was read and not modified.

## 1. High. Contract headings disagree with nav.lua

`docs/design/wh2-contract.md` line 27 on `feat/wh2-base` says headings use `nav.lua`, with east 0, south 1, west 2, and north 3. `nav.lua` line 3 is `[0]={0,0,-1}, {1,0,0}, {0,0,1}, {-1,0,0}`. Index 0 moves on -Z, which is north. `miner.lua` lines 69 to 72 use the same order. A layout that follows the contract sentence faces the opposite horizontal block. Likelihood is high once that layout is published. This branch builds drop-off access from `nav.lua` line 3.

## 2. High. Pairing secret is copied into replies and mesh relays

`ssot.lua` line 247 sets `result.auth = key` on every accepted reply. Line 229 accepts a request when `m.secret` equals that key. `server.lua` lines 260 to 276 retransmit the whole modem message on the repeat channel and again toward the recipient. A computer with an ender modem in range can read the pairing secret from the relay. Likelihood is high on any fleet that uses the mesh. Unfixed on main.

## 3. High. A failed save silences the state server until restart

`atomic.lua` line 65 sets `poisoned = true` when the save pcall fails. Line 40 then returns `storage requires restart` for later saves. `ssot.lua` line 256 sets `failed = true` and restores the previous state. Line 224 returns nil while `failed` is set. The server stops answering SSOT requests until the computer reboots. Likelihood is high when the state disk is near the 1,000,000 byte limit. `docs/evidence/fixtures/jars.json` recorded `computer_space_limit = 1000000` on the public-jar test server.

## 4. Medium. The network timer is re-armed only in the timer branch

`server.lua` line 896 assigns a new timer only when `network()` sees its own timer event. `ssot.lua` line 281 calls `sleep(0)` while validating chunk tables. That validation runs inside `handle`, which `server.lua` lines 868 to 870 call from the rednet branch of the same coroutine. `sleep` pulls the next event. A timer event pulled there never reaches line 896, so the one-second loop stops. `server.lua` line 220 `http.get` is inside `mirror`, and `refresh` at line 924 calls it from another coroutine, so that yield does not by itself eat the network timer.

## 5. Medium. Counter 2147483647 locks the client out

`ssot.lua` line 227 rejects a counter outside 1 to 2147483647. Line 238 rejects a counter that is not greater than the stored counter. A client that has used 2147483647 cannot send another accepted request. Likelihood grows with long-lived turtles. It is not a one-boot failure.

## 6. Medium. The old RCON helper reads one packet and ignores the host

`tests/ingame/rcon.py` line 29 connects to `127.0.0.1` only. `receive()` at lines 21 to 37 returns one response packet. The 1.21.1 server splits a reply at 4096 UTF-8 bytes. A longer reply is truncated. `tests/ingame/fixtures/rcon.py` reassembles those chunks and takes host, port and password from the caller. The old helper is unchanged. The PowerShell Gate B scripts call it, and `pwsh` is not installed here, so this change does not rewrite that helper.

## 7. Medium. Updates trust djb2 and an unauthenticated lookup

`update.lua` lines 53 to 57 hash file text with djb2. Line 68 uses `rednet.lookup("fleetserver", "server")` when GitHub cannot be reached. Any modem host can answer that lookup and supply files. `server.lua` lines 17 to 19 list the fleet scripts, and lines 200 to 214 keep a copy on the state computer. At a 1,000,000 byte disk that copy competes with state. `docs/design/hardening.md` section H4 on `feat/wh2-base` is marked PENDING APPROVAL. Nothing from that section is built here.

## 8. Medium. Active warehouse jobs and a failed commit do not recover

`warehouse-tasks.lua` lines 100 to 109 return the owner's active job on `wh-claim` and never expire it. A turtle that stops mid-order holds the job. `ssot-client.lua` lines 96 to 99 error after a physical move whose commit fails, and lines 109 to 115 keep `stopped` set so later moves fail until reboot. `nav.lua` lines 234 to 236 scan the whole open list to find the best node. That cost grows with the path. These are not a small default-off patch.

## 9. Guess. Cooking slot numbers

`docs/design/wh2-contract.md` line 183 on `feat/wh2-base` says cooking machines use native slots 1, 2 and 3. The live block data in `docs/evidence/fixtures/counts-after.md` lines 14 to 19 uses container slots 0, 1 and 2 for input and fuel. CC Lua inventories are 1-based. The contract may mean those Lua slots. This is a mapping risk, not a confirmed bug.

## 10. Design gap. Miner autonomy is not approved

`docs/design/miner-autonomy.md` on `feat/wh2-base` says PENDING APPROVAL and that nothing there gets built until it is accepted. This branch does not implement it.

## What this branch checked

`python3 -m unittest tests.ingame.fixtures.test_fixtures` passed 13 tests. The live command was `python3 -m tests.ingame.fixtures.validate` against `127.0.0.1:25575`. Evidence is `docs/evidence/fixtures/`. `lua5.2` is not installed, so `tests/run.lua` was not run. This change adds no Lua. CraftOS-PC was not run. The live host `100.91.208.60` was not contacted.
