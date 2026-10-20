# WH2 contract review

Reviewed `docs/design/wh2-contract.md` at `8de2440` on `feat/wh2-base` at 2026-10-20 17:45:56 +0200. That commit is the heading and slot edit. A fetch at 2026-10-20 16:01:39 UTC still showed that commit as the branch tip and as the latest commit of this file. `docs/design/h4-offline-contract.md` is not on the branch. `git cat-file -e` on that path failed. The accepted plan is `docs/plans/cc-h4-offline-plan.md` at the same commit. Jeffrey accepted it on 2026-10-20 at 17:09. The contract says the plan wins where shapes differ at `wh2-contract.md` line 5.

This review did not edit the contract.

## Verdict

Do not build fleet, wizard, layout, or craft from this text. The heading numbers for the four compass points now match the code. The sample location still faces the wrong block. Stored headings, room coordinates, no-GPS coordinates, and duration units still disagree with the programs. The header names keyed BLAKE3 and Ed25519. The protocol body is HMAC-SHA256. The ownership section still says H4 is on hold.

## Conventions

### Heading

`wh2-contract.md` line 29 now says north 0, east 1, south 2, west 3, up 4, down 5. It cites `nav.lua` lines 3 to 7 and `miner.lua` lines 69 to 72.

`nav.lua` line 3 is the only vector table in that range. Heading 0 is `{0,0,-1}`, which is north. Heading 1 is `{1,0,0}`, east. Heading 2 is `{0,0,1}`, south. Heading 3 is `{-1,0,0}`, west. Indexes 4 and 5 are up and down. `nav.lua` line 12 accepts a stored heading only when it is an integer from 0 through 3. `miner.lua` lines 67 to 72 use the same four compass values, and indexes 4 and 5 are move deltas. `miner.lua` line 68 maps only north, east, south, and west onto 0 through 3. `factory.lua` lines 35 to 36 match. `docs/warehouse.md` line 7 states north 0, east 1, south 2, west 3. `warehouse-tasks.lua` line 16 requires site heading `h` from 0 through 3.

The plan comment at `cc-h4-offline-plan.md` line 39 now says the same four compass values. That part of `8de2440` matches the code.

The location example was not updated. `wh2-contract.md` lines 115 to 118 put the inventory block at x 11, z 20, and the standing cell at x 10, z 20, with `h = 0` and `side = "front"`. Heading 0 faces -z. The block in front of that cell is x 10, z 19. The block in the example is one step east, which is heading 1. A turtle that copies the example interacts with air. The same `h = 0` at line 22 has no neighbor block, so that sample is only a value, not a facing toward a chest.

Line 29 also calls up and down headings. `nav.lua` line 12 rejects them. A fleet or site record with heading 4 fails the movement owner and the warehouse site check.

### Slots

`wh2-contract.md` line 185 now says contract slot numbers are 1-based CC Lua slots, and NBT and RCON number the same slots from 0. Furnace input, fuel, and output are CC slots 1, 2, and 3, which are NBT slots 0, 1, and 2. `sorter.lua` lines 303 to 325 use `l[1]`, `l[2]`, and `l[3]` for input, fuel, and output. `roomsorter.lua` lines 2294 to 2301 pull the result from slot 3 and a bucket from slot 2. Turtle pattern keys at `wh2-contract.md` line 239 are the CC crafting grid, slots 1, 2, 3, 5, 6, 7, 9, 10, and 11. Those match `turtle.getItemDetail`.

Line 155 still calls the keys native numbered slots. Line 185 defines that phrase for CC. Chest contents use the same rule. A chest NBT `Slot` of 0 is contract key 1. The sentence tells RCON fixtures to subtract one. That conversion is specified.

Upload offsets stay a different zero. `wh2-contract.md` line 377 says offsets are zero-based counts of accepted records. `wh2-contract.md` line 341 starts `wh2-get` at cursor 0. Those are not inventory slots.

The cold-chunk expansion at `wh2-contract.md` line 446 is `x + 16*z + 256*y` with index 0 meaning unknown. `ssot.lua` lines 18 to 21 use the same axis order and then add 1. `ssot.lua` lines 208 to 209 store 0 as air. A migration that treats the two indexes as the same number shifts every cell and turns air into unknown, or the reverse.

### Coordinate frames

Line 29 says coordinates are integer world blocks. Three existing frames are not that.

Room scans are relative to the turtle's start cell. `roomsorter.lua` lines 1043 to 1046 set heading 0 to the direction it faced toward the input chest, and heading 1 to its right. The numeric deltas match world north only when that start facing was world north. Line 29 says those values need an explicit conversion before publication, and that GPS plus a calibrated heading establishes it. The rotation and the world origin are not written. A layout publish that copies room x and z into `minecraft:overworld|x|y|z` writes the room grid onto the world origin.

No-GPS miners use a third frame. `miner.lua` line 400 sets home to x 0, z 0, facing 0, and `loc` true when setup is given only a height. `README.md` lines 112 to 117 describe the same mode. `miner.lua` line 656 omits x and z from status when `loc` is set, and the comment says they are not world coordinates. `miner.lua` line 614 refuses SSOT in that mode. The fleet pose at `wh2-contract.md` line 20 is `dim`, `x`, `y`, `z` with no frame and no confidence. The plan position at `cc-h4-offline-plan.md` lines 34 to 42 has `frame`, `yAbs`, `conf`, and `src`, and the `yAbs` comment names this setup mode. The contract record cannot store it. Line 5 says the plan wins, and the fleet table still publishes the old pose.

### Units

The settings table mixes units. `wh2-contract.md` lines 72 to 78 set `chargeTimeoutMs` to 60000, `tripSeconds` to 900, `sessionSeconds` to 1800, `retrySeconds` to 20, `roomIntervalMs` to 5000, and `wiredIntervalMs` to 3000. Line 102 says other durations are positive integers. It does not name one unit for a field whose name has no suffix.

`hub.lua` line 130 defaults `mineMinutes` to 15. `miner.lua` line 1693 adds `mineMinutes * 60` to `os.clock`. `tripSeconds = 900` matches 15 minutes only after that multiply. Line 108 says the import converts old seconds to milliseconds. It does not mention minutes. An import that treats 15 as seconds stores a 15 second trip.

`hub.lua` lines 134 to 139 store `sessionLen` in seconds, default 1800. `hub.lua` line 315 returns remaining session time in seconds. `miner.lua` line 2576 multiplies `stopIn` by 1000. `sessionSeconds = 1800` matches the hub field. `chargeTimeoutMs` is already milliseconds. One registry holds both.

`sorter.lua` line 58 defaults the wired interval to 3 seconds. `roomsorter.lua` line 952 defaults the room interval to 5 seconds. The contract's 3000 and 5000 match those defaults if the line 108 conversion is applied. `roomsorter.lua` line 953 uses `minFuel` 1000 as a fuel count. `roomFuelLow = 1000` sits beside the millisecond fields. The contract does not say it is fuel.

Recipe `time` is ticks and fluid amounts are millibuckets at `wh2-contract.md` line 241. CC `sleep` takes seconds. The contract does not say to divide ticks by 20 before a wait.

Fuel matches the code. Line 53 uses the string `unlimited` and forbids infinity. `miner.lua` line 971 already branches on that string.

`lastSeen` is server UTC milliseconds at line 53. Legacy status has no such field. `server.lua` lines 145 to 152 keep the packet's own numbers. The contract does not say those numbers are not timestamps.

## Blocking gaps

Each gap below is one that a PR would implement wrong if it followed the contract text. Each one is a GitHub issue labelled `wh2-contract`.

### 1. Compass sample, stored heading, frames, and units

https://github.com/140er/computercraft-scripts/issues/46

Severity is high. Layout copies the sample and faces the wrong block. Fleet can store heading 4, which `nav.lua` line 12 rejects. Layout can publish room coordinates as world blocks. Settings can turn a 15 minute trip into 15 seconds.

The evidence is the conventions section. `8de2440` changed the compass sentence and the slot sentence only. The location example, the heading range, the pose fields, and the duration names were left as they were.

### 2. The MAC body contradicts the accepted plan

https://github.com/140er/computercraft-scripts/issues/47

Severity is high. H1+H2 will vendor the wrong primitive. A later enrolment PR cannot verify those signatures.

Line 5 says the MAC is ccryptolib keyed BLAKE3 and the manifest is Ed25519. Lines 306 to 329 specify `sha2.lua`, `sha.hmac(sha.sha256, ...)`, and a test vector. This session recomputed that vector with Python `hmac` and the canonical encoding in lines 310 to 327. `Kpair` was `d3112db576986600216a96bd18ee1d046ab501ff2e9862f632588820d1d223c1`. The request key was `8d81c035d1f9dfcff439d1ab170d07721a742ee31a5d7cee24f88aa440cedad7`. Both match the contract. The HMAC section is internally consistent. The plan requires keyed BLAKE3.

`cc-h4-offline-plan.md` line 257 requires keyed BLAKE3 and one Ed25519 manifest signature. Line 505 says ccryptolib has no HMAC, so the plan rejected a hand-written HMAC. `hardening.md` lines 28 to 29 say the same. Line 408 still says the manifest MAC is paired-server HMAC and is not a public-key claim.

The envelope also differs. The plan line 258 uses `v = 2` and `requireMac`, default off. The contract request at line 283 uses `wire.major` and has no `v` field. Line 280 says a bare `v = 1` is not a handshake. It does not say whether a `v = 1` domain request is rejected.

### 3. H4 is still on hold in the ownership section

https://github.com/140er/computercraft-scripts/issues/48

Severity is high. The four feature PRs and H5 will stack on the wrong parents. Two owners will edit `ssot.lua`, `install.lua`, `nav.lua`, and `server.lua` without a named order.

Line 582 says the order is PR 5, PR 6, H3, H1+H2, H4, H5, fleet, wizard, layout, craft. The same sentence says H4 is on hold, H5 stacks on H1+H2, and layout and craft have no H4 prerequisite. Line 440 and line 521 say the build order comes from the plan. `cc-h4-offline-plan.md` line 9 orders P0, H3, H1H2, N1, then I1 and I2 beside H4a and H4b1, then H5, H4c, W1, then B1 and B2 beside T1, A1, and T2, then S1, H4b2, H4d. Line 235 says layout, wizard, and craft need H3 and H4a through H4c, not H4d. `hardening.md` lines 10 to 14 and `backlog.md` lines 30 to 52 record that order. `hardening.md` line 17 still starts layout and craft after H3 and H4. `miner-autonomy.md` line 7 still says the feature is part of the fleet PR. The plan splits it into B1 and B2 after W1.

Among fleet, wizard, layout, and craft, the named files do not overlap. Fleet owns `server.lua`, `ssot.lua`, `ssot-client.lua`, `miner.lua`, `mining.lua`, `nav.lua`, `fleetview.lua`, `install.lua`, and `update.lua` at line 594. Wizard owns `hub.lua` and `panel.lua` at line 595. Layout owns `roomsorter.lua`, `sorter.lua`, `store.lua`, `warehouse.lua`, and `warehouse-tasks.lua` at line 596. Craft owns `factory.lua` at line 597. New modules are `wh2-fleet.lua`, `wh2-client.lua`, `wh2-wizard.lua`, `wh2-layout.lua`, `wh2-craft.lua`, `wh2-recipes.lua`, and `craft.lua`. Subtrees are `fleet`, `layout`, `wizard`, and `craft` at lines 14 to 17. Those four do not write one key.

The wider table shares files on purpose and calls that sequential rebase at line 584. It does not name P0, N1, I1, I2, H4a, H4b1, H4b2, H4c, H4d, B1, B2, T1, T2, S1, A1, or W1. Those PRs also write `ssot.lua`, `install.lua`, `update.lua`, `nav.lua`, `server.lua`, `panel.lua`, and `hub.lua`. `cc-h4-offline-plan.md` line 227 says the installer PRs and the H4a and H4b1 group each add one dispatch line to `ssot.lua`.

Line 503 still says the storage messages stay unregistered until approval. Line 570 says the miner messages stay out of the registry until approval. Line 613 still says H4 and autonomy scenarios wait for approval. The header at line 5 says they are approved.

### 4. Position, lease, journal, and storage records are the pre-plan shapes

https://github.com/140er/computercraft-scripts/issues/49

Severity is high. W1, B1, and H4c will persist records the plan already replaced.

The fleet pose has no `v`, `frame`, `conf`, or `src` at line 20. The plan requires them at lines 34 to 42 and says a reader rejects an unknown `v` at line 29 of the plan.

The contract lease at lines 526 to 538 is `schema = 1`, HMAC-SHA256, location ids, and hashes. The plan lease at lines 93 to 99 is `v = 2`, keyed BLAKE3, inline access poses, a corridor of at most 256 cells, and `fuelReserve`. The contract journal kinds at lines 554 to 560 are `block`, `mine`, `items`, `problem`, and `move`, with phase `intent` or `observed`. The plan entry kinds at lines 104 to 109 are `move`, `turn`, `dig`, `observe`, `item`, `problem`, `boot`, and `anchor`, with phase `intent` then `done`. The contract journal cap is 262144 bytes at line 536. The plan sample head uses a budget of 90000 at line 109 and stops new work at 80 percent at line 326. Line 478 of the plan says the budget comes from free space at runtime.

The contract cold chunk at lines 451 to 456 is `whc-rle/1`. Expansion at line 446 is `x + 16*z + 256*y` with index 0 meaning unknown. `ssot.lua` lines 18 to 21 add 1 to that formula, and lines 208 to 209 store 0 as air. The same index cannot mean both. The plan section at lines 63 to 66 is a palette and a sorted cell list, and the key starts with the frame id. The contract policy at lines 466 to 469 has `forgetAfterMs` and `forgetScope`. The plan policy at line 115 has `warnAt`, `forgetOlderThanMs`, and `controlReserve`. The contract allows a miner to be one of the two required copies when its score is at least 0.98 at lines 489 to 491. Plan pushback 3 at line 469 says miners hold only extra replicas, and never while they hold an offline lease.

Line 521 says these notes predate the plan. The tables are still written as the records to implement.

### 5. Settings cannot express a global patch

https://github.com/140er/computercraft-scripts/issues/50

Severity is high. Gate B requires a live global toggle and a per-turtle toggle at `gateB-depth.md` lines 43 to 45. The patch example cannot name the global write.

Line 100 defines the read order as registry defaults, then global `defaults`, then the computer override. The only patch sample uses `scope = "turtle"` and `computerId = 17` at lines 94 to 97. No scope value for the global map is named. Overrides are keyed by the string `"17"` at line 92. The patch carries a numeric `computerId`. The contract does not say the server converts the number to that string. In Lua those keys are different. A numeric lookup misses the override.

Line 578 lists `offlineAutonomy`, check-in, lease, and the local problem-handling flags, then says they do not enter the approved settings example. Plan line 229 says W1 owns the registry and adds the B1 thresholds and `storagePolicy` before B1 reads them. Plan line 322 says W1 is built as the contract specifies and that the plan adds those keys. The contract example omits them.

Live apply for keys that are present is specified. The server saves before ack at line 106. A newer revision pauses new autonomous actions until the fetch. An in-progress native call finishes first. Heartbeats poll at least every 3000 ms. `mining = false` stops before the next physical action at line 104. Both `ssot.cfg.wh2.enabled` and the turtle `wh2.enabled` default off, at line 19 and line 108. A remote setting cannot clear ESTOP at line 108.

### 6. An open question has no mid-answer state

https://github.com/140er/computercraft-scripts/issues/51

Severity is high. A reboot while the player is answering drops the partial answer. The board has no rule that reloads the open question.

The question record is `id`, `item`, `state = "open"`, `firstSeen`, and `sampleLocationId` at lines 177 to 180. No other state is named. Line 189 says an answer commits the class row and the question resolution together. `wh2-class` carries `baseRevision`, `item`, and `value` at line 353. It has no draft, no step, and no question id. Nothing says the panel loads topic `questions` on boot and shows every `open` row again.

Repeated reports coalesce to one question per item id at line 189. That part survives a second report. The player's half-entered route and category do not. Gate B checks that a finished answer survives a reboot at `gateB-depth.md` lines 37 to 39. The contract does not cover a reboot before the answer is sent.

### 7. The planner does not choose among recipes or tags, and a zero guaranteed output divides by zero

https://github.com/140er/computercraft-scripts/issues/52

Severity is high. Two craft builds can reserve different ingredients for the same request. A chance-only recipe divides by zero.

`itemNode.recipes` is a list at line 200. `craftCreate` carries the output item and count and no recipe id at lines 225 to 228. No rule picks among recipes. Line 237 says the planner records a concrete tag choice and checks stock. It does not say which member wins when several are in stock. `more = true` means a capped list cannot prove an unlisted substitute at line 237. That limit is specified. The choice among listed members is not.

Line 243 uses `ceil(required / guaranteedOutputCount)`. Outputs with chance below 1 cannot satisfy a guaranteed count. If every output is below 1, the guaranteed count is 0. The formula does not say to block before the division. Missing ingredients block and report an exact count at line 243. Cycles end as an unresolved requirement at line 243. The `missing` list is items and counts at line 222. A cycle is not an item, and no field holds the cycle path. The 128 step cap at line 245 bounds the walk. It does not name the recorded failure.

`warehouse-tasks.lua` line 24 allows 32 sites. Line 31 allows 32 orders and 8 lines. Line 5 limits a site name and an order key to 64 characters of a restricted set. A craft plan may have 128 steps at contract line 245. Line 193 reserves ingredients through those warehouse orders. An `orderKey` built from a 64 byte job id plus a suffix exceeds the warehouse 64 character limit. Component fingerprints are on the craft ingredient at line 218 and not on the warehouse line at `warehouse-tasks.lua` lines 35 to 38. Line 243 says item-only totals cannot prove a component match. The only reservation record cannot store the fingerprint.

### 8. Progress, layout staging, and the pending envelope are not safe to repeat after a reboot

https://github.com/140er/computercraft-scripts/issues/53

Severity is high. A chunk unload reboots the turtle. A second progress message can count the same output twice. Two layout edits from one operator share one stage.

`ssot-client.lua` lines 28 to 30 save the counter and leave the envelope in the RAM table at line 7 and line 39. Line 6 builds `boot` from `os.epoch("utc")` at process start, so a reboot changes `boot`. Contract line 337 says a retry reuses the original envelope byte for byte, and that the counter is reserved before send. It does not put the envelope on disk. After reboot the client cannot resend those bytes. Craft progress carries `state` and `observed.count` and no event id at lines 230 to 234. The replay cache returns a result only for the same signed bytes at lines 331 to 332. A new counter with the same observation is a second request. Line 247 says `produced` counts observed output. It does not say the server sets that total instead of adding the count.

Line 377 stages one edit of at most 65536 bytes per operator. The stage is not keyed by room, slot, or field. A second upload from the same computer replaces or gaps the first. Expiry is 30000 ms of idle. A retry after expiry is not given a rule other than gap rejection.

Settings avoid this for their own revision. The turtle stores `appliedSettingsRevision` at line 106. A reboot fetches when the stored revision is older. Craft progress has no matching stored cursor.

Chunk unload does not let the native call finish. Line 523 says an unloaded turtle freezes and reboots without GPS. Line 106 says an in-progress native call completes first. Those two sentences describe different restarts.

### 9. The contract does not show that wh2 state fits a 1,000,000 byte disk

https://github.com/140er/computercraft-scripts/issues/54

Severity is high. Merging fleet onto the current save fills a 1 MB computer or poisons SSOT.

`ssot.lua` line 308 limits one generation to 900000 bytes. `atomic.lua` line 27 keeps `path`, `.tmp`, and `.bak`. `docs/ssot-pr1.md` line 56 says three generations can use 2,700,000 bytes. `atomic.lua` lines 40 and 65 poison the store after one failed save. `atomic.lua` line 54 also requires `text` plus 8192 bytes free. `gateB-depth.md` lines 66 to 67 require a real 1,000,000 byte run. The plan's goal is that disk at `cc-h4-offline-plan.md` line 21.

Line 276 says the 900000 byte ceiling is not a disk measurement, and that the hub budget does not claim the coordinator's generations fit on 1 MB. Line 253 caps hub files, scripts, and scratch at 1000000 bytes with 8192 free, and rejects a save that does not fit. That is a refusal, not a remaining-byte budget for fleet, rooms, slot contents, and craft jobs inside `ssot.state`. Slot contents and room cells have no byte cap. `roomMaxCells = 6000` is a count at line 80. H4a's two-copy save is the plan's answer, and line 582 still builds fleet before that save exists.

### 10. Legacy packets lose write authority with no default-off flag

https://github.com/140er/computercraft-scripts/issues/55

Severity is high. A merge to `main` makes live computers pull the code. `AGENTS.md` requires a new behavior to default off.

Line 3 says legacy packets cannot authorize shared-state changes or updates. Today, with no `ssot.cfg`, legacy behavior stays unchanged at `docs/ssot-pr1.md` line 48. The plan's `requireMac` defaults off at plan line 258. The contract does not name that flag. `wh2Config.enabled` defaults off at line 19. That flag is the wh2 feature, not the MAC on existing `sync` and `reserve`. Existing requests still send the secret in plaintext at `ssot-client.lua` line 35 and `ssot.lua` line 229. The reply copies it back at `ssot.lua` line 247. The contract forbids keys in replies at line 335. Shipping that ban without a default-off switch changes live auth on merge.

### 11. Several illegal combinations are still representable

https://github.com/140er/computercraft-scripts/issues/56

Severity is medium. Validators can reject them later. The tables do not make them unwritable, so two modules can disagree.

Line 31 says unknown scalars use `false`, and the next sentence says absent optional keys keep the source API's meaning. Absent and `false` are different, and `false` is also the real value for `currentJob`, `turtleId`, `fuel`, and `dropoffId` at lines 51, 55, and 73. A missing fuel level and a non-turtle's `fuel = false` share one token unless every reader checks the computer kind first.

A fleet row can combine `kind = "turtle"` with `turtleId = false`, or `state = "mining"` with `currentJob = false`. Those pairs are not forbidden. Location kinds that need a block are described in prose at line 143 and the table still allows a `dropoff` without `block`. A job can be `done` while `missing` is non-empty. A step can be `running` while the job is `planning` at line 243. Question `state` is an open string. Plan shapes carry `v` and tell the reader to reject an unknown `v`. These records mostly have no `v`.

Stored `s.epoch` is an integer at `ssot.lua` line 266. Message samples use the string `"3"` at contract line 394. `ssot.lua` line 313 passes `tostring` of the integer into the handler. A module that writes the string back into `s.epoch` fails the validator and the server does not boot.

## What holds

The four feature PRs do not share a file or a wh2 subtree. See gap 3.

Horizontal headings in the prose now match `nav.lua` line 3 and `miner.lua` lines 67 to 72. The slot base at line 185 matches `sorter.lua` and `roomsorter.lua`.

Create uses a caller key that stays stable across retries at line 247. Unknown reports coalesce per item id at line 189. An exact replay returns the saved result at lines 331 to 332. Session rollover is specified before the counter maximum at lines 333 to 334. Settings that are in the example have defaults, a read order, and a live-apply pause at lines 100 to 108. `mining = false` stops before the next dig at line 104. Fuel `unlimited` matches `miner.lua` line 971.

The operation names in the wh2 table are at most 16 bytes, which matches `ssot.lua` line 227. `storage-capacity` is 16 bytes. The contract's 8192 byte envelope matches `ssot.lua` line 225. The protocol name remains `fleetserver` at line 280.

## Oversights already filed

These are on `main` and already have issues. This review did not open duplicates.

- Pairing secret on the wire. `ssot.lua` line 247 and `ssot-client.lua` line 35. Issues 40 and 44.
- A failed save poisons SSOT until restart. `atomic.lua` lines 40 and 65, `ssot.lua` line 256. Issues 40 and 44.
- `sleep(0)` inside validation. `ssot.lua` line 281. Issues 40 and 44.
- Counter maximum locks a client out. `ssot.lua` lines 227 and 238. Issues 40 and 44.
- A started move keeps both cells. `ssot.lua` lines 93 to 94. Issue 36.
- Warehouse orders do not expire. `warehouse-tasks.lua` lines 100 to 109. Issue 40.

Issue 44 item 1 reports the old east-0 sentence and cites line 27. At `8de2440` that sentence is line 29 and it now says north 0. Issue 44 item 9 guesses that line 183 is the cooking slot list. At `8de2440` line 183 is the NBT sentence and line 185 states the 1-based rule. Issue 44 also still says H4 is pending approval. The header at line 5 says approved.

No small behavior fix was opened against `main`. The secret, the poison flag, and the timer yield are the hardening track. A one-line change there would change live computers.

## What this review did not run

No CraftOS-PC run and no Minecraft run. The contract says it adds no executable behavior at line 613. The HMAC vector was checked with Python `hmac` against the published hex, not on a ComputerCraft machine. ccryptolib timings in the plan were not remeasured. File-size sums in the plan were not remeasured. `docs/design/h4-offline-contract.md` was absent, so P0 has not frozen the shapes.
