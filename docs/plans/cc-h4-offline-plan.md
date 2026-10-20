# H4 storage, offline miners, GPS-free positions, installer and Turtle Planner plan

This plan covers 1 MB storage (H4), peer cold storage, offline miner autonomy (Design B), the strata baseline map format, GPS-free positioning, the installer makeover and the Turtle Planner for `140er/computercraft-scripts`. It is read against `main` at `ece242a`, PR #29 (PR 5) at `6a94dc2`, PR #28 (PR 6) at `ab26bde`, and the design docs on `feat/wh2-base` at `a73de6f`. Jeffrey's decisions 6 and 7 stay. Pushback appears only where something is unsafe, and each pushback keeps the decision intact.

Labels. (measured) means I read it in source, ran it, or measured it this session. (inferred) means it follows from measured facts. (guess) means it is unverified. Imperative steps are plan, not claims.

The rule this program enforces is simple. Unknown is never free, nothing is forgotten without the player's choice, and no turtle digs unless it can prove where it is.

The PR order is P0, H3, H1H2, N1, then I1 and I2 alongside H4a and H4b1, then H5, H4c, W1, then B1 and B2 alongside T1, A1 and T2, then S1, H4b2, H4d.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. Check a box only when its evidence exists as a file, a log line, a screenshot, a test run or a SHA.

The program runs `pstack/skills/poteto-mode/playbooks/autopilot-stack.md` adapted to the repo's rules. Codex on the Windows VM builds each PR with `gpt-6.1-sol` (measured, `AGENTS.md`). Mod Forge Admin merges. Jeffrey approves the plan. No author merges its own PR (measured, `AGENTS.md`). Every new behavior ships behind a config flag that defaults off, because merging to `main` makes live computers pull code (measured, `AGENTS.md`).

Deviation from the playbook skeleton. The operator fixed this file's structure, and the repo's gates are Gate A and Gate B, not ten swarm lanes. One agent builds each PR (measured, `docs/evidence/pr4/plan.md`). So each PR names one Gate A check and one Gate B check instead of ten lanes.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Here live means Gate B and perf means the Gate A and soak numbers. Concretely, a PR is verified only when its unit, Gate A and Gate B boxes are all checked with saved evidence under `docs/evidence/<pr>/` and `docs/testing/gateB-depth.md` depth (measured, that file says a skipped item is `GATES: FAIL`).

## 1. The real goal

A player on a server with 1,000,000 byte computer disks and no GPS hosts can run a turtle fleet that keeps its map, never loses data silently, keeps mining when the server is unreachable, and installs new machines in a few touches or keystrokes. The player can also plan a base on a map, on the server, the hub or the panel, and hand each new bot a code that sets it up completely. The central server stays the single source of truth whenever it is reachable.

Who notices. The player sees a storage choice instead of silent loss, miners that keep working through a server restart, and a one-screen installer. The next maintainer inherits one position shape with a frame tag, one map format, one lease shape and one install state machine instead of per-script variants.

## 2. Core data shapes

Every shape is a Lua table with a version field `v`. A reader rejects an unknown `v`. All times are server UTC milliseconds from `os.epoch("utc")`, never `os.epoch("ingame")` (see section 3 for why). Section keys keep the 16 by 16 by 16 section that `ssot.lua` `chunk()` already uses (measured, `ssot.lua` lines 18 to 21).

### 2.1 Position and frame (new, used everywhere)

```lua
pos = {
  v = 1,
  frame = "abs",          -- "abs" or "f:<frameId>"; relative frames never enter the absolute map
  yAbs = true,            -- true when y is world y even in a relative frame ("miner setup <y>" mode)
  dim = "minecraft:overworld",
  x = 10, y = 65, z = 20, h = 0,   -- h uses nav.lua headings, east 0 to north 3
  conf = "certain",       -- "certain", "suspect" or "lost"
  src = "neighbour",      -- "gps", "neighbour", "radio", "typed", "reckoned", "inherited"
  anchoredAt = 1792500000000,
}
frame = { v = 1, id = "f:17:1792500000000", owner = 17, yAbs = true,
  toAbs = false }         -- false until anchored, then { dx, dy, dz, rot } with rot in 0..3
```

Today a pose has only `dim`, `x`, `y`, `z` and an optional `h` (measured, `ssot.lua` `M.pose` lines 9 to 13). The frame tag is new. The server stores relative frame data under its own key prefix. Anchoring a frame re-keys its data into `abs` exactly once, keyed by frame id, so a repeat is a no-op.

### 2.2 Map region and section, format v2 (baseline plus exceptions)

H4b1 ships the section shape with palette plus RLE cells and `observed` or `unknown` confidence only. The region baseline, `predicted` confidence and segments arrive with H4b2 behind a flag.

```lua
region = { v = 2, key = "abs|minecraft:overworld|rx|rz",   -- 64 by 64 columns
  baseline = { ver = 3, frozen = true,
    surface = "<1 byte per observed column, 0 = unknown>",
    fillerTo = { dirt = 3 }, blendLo = 0, blendHi = 8,       -- calibrated deepslate band
    samples = 4120, calibratedAt = 1792500000000 },
  segments = { { x = 1, y = -54, z = 0, d = 2, n = 64, inspected = true,
                 by = 17, lease = "7:mine:12", rev = 812, base = 3 } },
  boxes = { { min = {...}, max = {...}, kind = "air", inspected = true, rev = 900, base = 3 } } }
section = { v = 2, key = "abs|minecraft:overworld|3|4|-2", rev = 812, hash = "<sha256 hex>",
  palette = { "=", "minecraft:air", "minecraft:diamond_ore" },  -- "=" means observed, equals baseline
  cells = "<2 byte index + 1 byte palette index, sorted>",
  observedAt = 1792500000000, lastRead = 1792500000000, tier = "hot" }
```

Cell confidence is derived, not stored per cell. A cell is observed when it is in `cells`, inside a segment or box, or a face neighbour of an `inspected` segment or box. It is predicted when only the baseline covers it. It is unknown otherwise. Predicted is usable for cost estimates only. It is never free and never counts as observed. A filler class (`stone`, `deepslate`, `tuff`, `andesite`, `granite`, `diorite`, `dirt`, `netherrack`) matches the baseline as one class, because navigation treats them alike (measured, `mining.lua` line 11 `ground` set). Gravel is not filler because it falls.

### 2.3 Replica placement (H4d)

```lua
placement = { v = 1, key = "abs|minecraft:overworld|3|4|-2", rev = 812, hash = "...", bytes = 1843,
  holders = { [21] = { ackAt = 0, verifiedAt = 0, role = "store" } },
  localCopy = true,       -- may turn false only with 2 eligible non-miner holders acked at this rev and hash
  state = "hot" }         -- "hot", "replicating", "cold", "degraded" or "unknown"
```

### 2.4 Peer reachability record (H4d)

```lua
peer = { v = 1, id = 21, role = "store", enrolledAt = 0, enrolledBy = 4,
  quota = 420000, used = 120000, freeReported = 610000, reportedAt = 0,
  window = { sent = 240, ok = 236 }, lastReplyAt = 0, boot = "1792...:21", bootChanges = 1,
  power = { fuel = 18000, limit = 20000 }, holdsOfflineLease = false,
  score = 0.98, eligible = true, why = false }
```

### 2.5 Lease v2 (B1)

```lua
lease = { v = 2, id = "7:mine:1234", turtle = 17, boot = "...", epoch = "7",
  issuedAt = 0, untilAt = 0, issuedRev = 812, frame = "abs",
  area = { min = pos, max = pos },            -- cells the turtle owns exclusively
  corridor = { pos, pos },                    -- reserved return path, at most 256 cells
  dropoff = access, charger = access, home = pos,
  settings = { revision = 4, values = {} },   -- dev thresholds in force
  fuelReserve = 120, mac = "<keyed BLAKE3 hex with the turtle's pairing key>" }
```

### 2.6 Journal entry (B1)

```lua
entry = { v = 1, seq = 41, lease = "7:mine:1234", at = 0, frame = "abs",
  kind = "move",          -- "move", "turn", "dig", "observe", "item", "problem", "boot", "anchor"
  phase = "intent",       -- "intent" then "done"; replay keys on (turtle, lease, seq)
  from = pos, to = pos, fuelBefore = 1800, cell = pos, name = "minecraft:stone", count = 0 }
journalHead = { v = 1, lease = "7:mine:1234", committed = 41, acked = 30, bytes = 18000, budget = 90000 }
```

### 2.7 Storage policy, ledger and forget preview (H4c)

```lua
storagePolicy = { v = 1, mode = "ask", warnAt = 0.8, forgetOlderThanMs = false, controlReserve = 65536 }
ledger = { v = 1, localTotal = 0, localUsed = 0, peerTotal = 0, peerUsed = 0, growthPerHour = 0,
  state = "ok" }          -- "ok", "warn", "paused"
forgetPreview = { v = 1, id = "p:812:3", createdAt = 0, untilAt = 0, olderThanMs = 0, rev = 812,
  items = { { key = "...", rev = 640, hash = "...", bytes = 1200 } }, bytes = 0 }
```

### 2.8 Install state machine (I1)

```lua
install = { v = 1, step = "detect",
  machine = { kind = "turtle", advanced = false, id = 31, label = false, sides = {} },
  source = false,         -- "code", "neighbour", "fresh"
  role = false, enrol = false, pos = false, files = false,
  error = false,          -- { code = "code_expired", retry = "enter_code", detail = "" }
  history = {} }
-- steps: detect, source, enter_code, neighbour, role, position, facing, review, fetch, pair, done, error
-- events: { t = "choose", n = 2 }, { t = "text", s = "" }, { t = "back" }, { t = "retry" },
--         { t = "io", op = "gps", ok = true, value = {} }, { t = "timer" }
-- effects returned to the shell: { op = "scan" }, { op = "gps" }, { op = "rpc", call = "enrol-hello" },
--         { op = "apply_bundle", files = {} }, { op = "write_cfg" }, { op = "reboot" }
-- core: transition(state, event) -> state, effects. No term, peripheral, rednet or fs calls inside.
```

The keyboard front end is a full redesign, not a fallback. Both front ends render the same steps with the same features, copy code, neighbour copy, server-sent settings, position, role and per-role files. Error steps name the cause and offer retry, back and help.

### 2.9 Copy code and enrolment (I1)

```lua
copyCode = { v = 1, code = "K7Q2M9XDPT", issuer = 17,   -- 10 base32 chars; 16 if X25519 fails P0 issuedAt = 0, untilAt = 0,  -- ttl 120000 ms
  role = "miner", settingsRef = { revision = 4 }, devToggles = {},
  filesRef = { manifest = "8152c067", role = "miner" },
  frame = "abs", home = pos, used = false, attempts = 0,    -- burned after 5 failed attempts
  planBot = false }       -- PlannedBot id when the planner issued it; the same record serves both flows
enrolClaim = { v = 1, id = 31, server = 4, newPub = "<x25519 32 bytes>", serverPub = "<x25519 32 bytes>",
  nNew = "<16 bytes>", nServer = "<16 bytes>",
  proof = "<keyed MAC with the code over every field above>" }
-- pairing key = KDF(x25519 shared secret, transcript). The code only authenticates the transcript.
```

## 3. What the repo and CC:Tweaked actually support

### Repo facts

- The state server caches fleet code on its own disk. The `FILES` list sums to 977,085 bytes at `ece242a` (measured, `server.lua` lines 16 to 19, sizes summed on the box).
- The server role itself needs 142,474 bytes of code. A miner needs 186,344 bytes. A store robot needs 76,727 bytes (measured, summed from each role's `dofile` set).
- Every SSOT request copies and saves the whole state (measured, `ssot.lua` lines 242 to 255). One failed save silences SSOT until restart (measured, line 256). The state file cap is 900,000 bytes (measured, line 308).
- `atomic.lua` keeps `path`, `.tmp` and `.bak` and poisons itself after one failure (measured, `atomic.lua` lines 27, 59 to 61 and 65).
- The map holds at most 64 sections and 256 block names (measured, `ssot.lua` lines 31, 87 and 183). Cells store a name index with 0 for air and nothing else, no confidence and no per-cell time (measured, lines 184 to 194).
- Every physical move costs three RPCs, `reserve`, `start` and `commit`, and a failed commit stops movement until reboot (measured, `ssot-client.lua` lines 84 to 115). So a turtle cannot move at all today without the server (inferred).
- SSOT navigation calls GPS before and after every step and refuses to move without it (measured, `nav.lua` lines 170 and 209 to 210). The docs say navigation requires working GPS (measured, `docs/navigation.md` line 3). Miner and store pass `gps.locate(2)` as `observe` (measured, `miner.lua` line 2791, `store.lua` line 51).
- So in Jeffrey's world without GPS hosts, the SSOT navigation, mining leases and warehouse from PR 2 to PR 4 cannot run (inferred from the two facts above). The legacy miner path runs without GPS and counts from its home at x 0 z 0, or uses the hub's radio distance (measured, `README.md` lines 101 to 112, `miner.lua` lines 346 to 360). `gpshost.lua` exists for players who build a tower (measured).
- Walk routes need known air, and excavation treats unknown as passable but inspects before digging (measured, `nav.lua` lines 174, 186 and 251 to 252).
- Mining strips already record progress as a count along one tunnel (measured, `mine-tasks.lua` lines 52 and 96). The AR view stores a shaft as `{x,y,z,bottom}`, a vertical segment (measured, `fleetview.lua` lines 50 to 52 and 441). The miner tracks its lowest dug y (measured, `miner.lua` line 603). These are segments already (inferred).
- Secrets travel in plaintext in every request and reply (measured, `ssot-client.lua` lines 18 and 35, `docs/ssot-pr1.md` line 46). Pairing is manual, a secret typed into `ssot.cfg` (measured, `docs/ssot-pr1.md` line 5). At most 32 paired computers fit (measured, `ssot.lua` lines 30 and 241).
- PR 6 adds `bundle-manifest.lua` with one djb2 hash per file and a staged install with journal and rollback (measured, `refs/pull/28/head` `update.lua`, `update.lua` lines 53 to 57 on `main`). The manifest is global. I found no per-role prune of unused scripts in PR #28 at `ab26bde` (measured, grep for `prune`, `unused` and `roles`). Per-role file lists exist in `install.lua` `BOTS` entries (measured, PR #28 lines 557 to 577).
- The installer already reads `term.isColour()` and handles `mouse_click` (measured, `install.lua` lines 22, 140 and 214). It uses `gps.locate(2)` when available (measured, line 32).
- Gate A runs CraftOS-PC 2.8.3 with `computerSpaceLimit = 4000000` and `maxChunks=8` (measured, `tests/sandbox/run.ps1` lines 41 and 66). No Gate A scenario runs at 1,000,000 bytes today (measured).

### CC:Tweaked facts (source at commit `c6d72ad`)

- `computer_space_limit` defaults to 1,000,000 bytes and applies to computers and turtles (measured, `Config.java` line 15, `ConfigSpec.java` lines 101 to 103). Floppies get 125,000 bytes (measured, line 16).
- Each file or directory costs at least 500 bytes (measured, `MountConstants.MINIMUM_FILE_SIZE`). `fs.getFreeSpace` returns a number or `"unlimited"` per drive (measured, `FSAPI.java` docs).
- Wireless range is 64 blocks, rising to 384 at height (measured, `Config.java` lines 21 to 24). If either end is an ender modem, the packet arrives at any distance in the same dimension and across dimensions (measured, `WirelessNetwork.tryTransmit` lines 43 to 55). The modem has no payload size check (measured, `ModemPeripheral.transmit`). The 8,192 byte SSOT limit is the repo's own choice (measured, `ssot.lua` line 225).
- Classic Peripherals can nerf ender modem range through `enderModemNerf` (measured, `docs/gemini-review.md` line 99). Whether the pack enables it is unverified (guess).
- `os.epoch("ingame")` is `day * 86400000 + time * 3600000` from `level.getDayTime()` (measured, `OSAPI.java` line 384, `ServerComputer.java` lines 255 to 262). So it moves in 3,600 ms steps per tick, follows `/time set`, and freezes when `doDaylightCycle` is false (inferred). It cannot order two observations in the same tick (inferred).
- `os.epoch("utc")` reads the server JVM clock (measured, `OSAPI.java` line 382). Every computer on one server reads the same clock (inferred).
- GPS uses channel 65534 and a 2 second default timeout (measured, `gps.lua` lines 21 and 86 to 128). Hosts are computers, so they answer only while their chunk is loaded (inferred).
- `modem_message` carries the sender distance, also for ender packets in the same dimension (measured, `WirelessNetwork` line 49). Any computer with a known position can act as a GPS reference (inferred, that is what `gpshost.lua` does).
- Mouse input exists exactly when the terminal is colour (measured, `UserComputerInput` constructor uses `terminal.isColour()`). `monitor_touch` fires only for advanced monitors (measured, `MonitorPeripheral.java` line 44). So `term.isColour()` detects mouse support on the machine's own screen, and `peripheral.call(side, "isColour")` detects a touchable monitor (inferred).
- The computer peripheral exposes `turnOn`, `shutdown`, `reboot`, `getID`, `isOn` and `getLabel`, and no file access (measured, `ComputerPeripheral.java` lines 38 to 104).
- A broken computer or turtle drops an item with its computer ID and gets it back when placed (measured, `AbstractComputerBlock.java` lines 116 to 149). So files survive a pickup (inferred).
- A computer runs 7 seconds before a soft abort (measured, `TimeoutState.java` line 24 doc). Long hashing must yield (inferred).

### ccryptolib (cloned at `14489aa`, 2026-08-24)

- It exists at github.com/migeyel/ccryptolib under the MIT license (measured, `LICENSE`).
- It exports SHA-256 `digest` and `pbkdf2`, X25519 `publicKey` and `exchange`, a hardened X25519 variant, Ed25519 `publicKey`, `sign` and `verify`, ChaCha20, Poly1305, an AEAD, BLAKE3 `digest`, `digestKeyed` and `deriveKey`, and a random generator (measured, module return tables). It has no HMAC export (measured, grep).
- Randomness must be initialized before any secret operation, or the call errors (measured, `random.lua` line 119). The sources are a seed you supply, a Krist websocket token over http, VM instruction timing noise that its own docs call riskier, or a Classic Peripherals crypto peripheral when one is attached (measured, `README.md`, `random.lua` lines 52 to 103, `internal/hw.lua`). Whether the pack's Classic Peripherals build offers that peripheral is unverified (guess).
- The modules this plan needs total 107,532 bytes (measured). That adds about 11% of a 1 MB disk to every role that loads all of them (inferred). Enrolment-only modules can be removed after pairing through the per-role manifest (inferred).
- I found no explicit yield inside its hashing or curve code (measured, grep). A box run of one X25519 key generation under PUC Lua with shimmed CC APIs did not finish within 30 seconds and was stopped (measured). The shims may be at fault, so Cobalt speed stays unmeasured (guess). P0 decides.

### AR input facts (from `/workspace/gemini-docs/ar-glasses-capabilities.md`)

The doc reports jar and live-config reads that I did not repeat, so its claims below are reported, not measured by me. Its repo claims I checked.

- Repo checks that hold (measured). `fleetview.lua` line 364 starts the AR renderer. `hub.lua` line 613 and `server.lua` line 281 find `ar_controller`. `tests/mocks.lua` lines 16 to 25 hold the cc_ar signatures. PR 6's `ar-hud.lua` caps cells at 128 to 256, calls `update()` only on change, and replies through `chat_box` (PR #28, lines 115 to 130, 262, 278 and 415). `chat-control.lua` holds a UUID allowlist and 30 second confirm tokens (PR #28, lines 83 to 110). `buddy.lua` line 757 looks for `chatBox`, which the doc says AP names `chat_box`, so Buddy's chat is probably never found.
- Reported. cc_ar gives no input events. `update()` sends the full element set to every wearer. All goggles on one controller see one picture. A block controller shows only in its own dimension. Frames are blank after a server restart. Lines and text are probably depth-tested (the doc says inferred). `fleetview.lua` line 422 claims boxes show through rock, which nobody has verified (measured comment, unverified behavior).
- Reported. AP `player_detector.getPlayerPos` returns x, y, z, yaw, pitch, eye height and dimension, and live config has unlimited range and no random error. AP `chat_box` hides messages starting with `$` and can whisper or toast a player. AP `geo_scanner` scans real blocks within a small radius.

### Prototypes run this session (in `/workspace/proto`, PUC Lua 5.2.4 and Python 3)

- A throwaway HMAC-SHA256 in pure Lua with `bit32` passes the RFC vectors. It only sized the cost and is not shipped, since ccryptolib replaces it. It costs 0.44 ms for 256 bytes, 6.5 ms for 8 KB and 27.6 ms for 37 KB on the box (measured). Cobalt in game is a different VM, and its speed is unmeasured (guess, likely slower).
- One 16 cubed section in today's textutils format takes 8,211 bytes when every cell is known and 35,770 bytes with one unknown cell (measured, synthetic data). That matches Judgment's 37 KB estimate (inferred). Per-section palette plus RLE takes 963 bytes for the same section (measured).
- Fleet workload. Four miners, each with a shaft and 32 branches of 64 blocks, plus a quarry of three chunks 61 blocks deep, give 121,660 observed cells in 203 sections (measured, synthetic world). Palette plus RLE needs 245,375 bytes. Baseline plus exceptions needs 9,460 bytes, a 26 times saving (measured, synthetic world whose strata match the model). With 10% of wall cells as odd stone the saving is 5 times (52,908 bytes). With 25% it is 2.5 times (107,648 bytes) (measured). The filler class removes most odd-stone exceptions, so the real result should sit near the top of that range (inferred).

## 4. Dependency graph

```
P0 -> H3 -> H1H2 -> N1 -+-> I1 -> I2
PR5, PR6 ---------------+
                        +-> H4a -> H4b1 -> H5 -> H4c -> W1 -+-> B1 -> B2 ----------------+-> H4d
                                                            +-> T1 -+-> A1 (also PR6)    |
                                                                    +-> T2               |
                                                                    +-> S1               |
                                                            H4b1 -> H4b2 (flagged) ------+
I1 and H4b1 also feed T1. Layout (wh2) follows T1 and consumes verified fixtures.
```

- H3 comes before H1H2 because MAC checks add work inside the request path, and the queue must exist first (inferred from Judgment's order in `docs/review/judgment-2026-10-20.md`).
- H1 comes before every lease, enrolment and replica, because all three are signed with it.
- N1 comes before H4b1, I1 and B1, because all three carry the frame-tagged position.
- I1 and I2 run in parallel with H4a and H4b1. They own different files (`install*.lua`, `enrol.lua`, `update.lua` versus `atomic.lua`, `server.lua`, map modules). Both add one dispatch line to `ssot.lua`, so the second to merge rebases.
- H5 comes before B1 and H4d, because a turtle that never returns and a peer that dies both need expiry.
- W1 is the wh2 fleet PR from `docs/design/wh2-contract.md`. It owns the settings registry, so dev thresholds and `storagePolicy` enter it before B1 reads them.
- T1 needs I1 (one enrolment mechanism), H4b1 (cell confidence for styling, known or unknown only until H4b2) and W1 (settings registry for bot settings). T1 and B1 own different files and may run in parallel.
- S1 needs H4c, because the hub runs under the same storage ledger with a smaller budget. S1 is sized L. T2 and A1 do not depend on S1.
- A1 needs T1 and PR 6, because it reuses `ar-hud.lua` and `chat-control.lua`.
- H4b2 needs only H4b1 and ships behind a flag. It becomes the default only after it beats H4b1 in Gate B.
- H4d comes last. It needs H1, H3, H4a to H4c, H5 and lease state for miner eligibility. H4b1 makes it rarer, and H4b2 would make it much rarer.
- Layout, wizard and craft keep their order from `docs/design/hardening.md`. They need H3 and H4a to H4c, not H4d.

## 5. Sequenced PRs

Riskiest first means the PRs that test a premise come first. P0 measures the premises. N1 is the largest behavioral risk and lands early.

### P0. Measure the platform and freeze the contract

- [ ] **Scope.** Add `tests/bench/` probes and `docs/design/h4-offline-contract.md` with every shape in section 2. No runtime behavior.
- [ ] **Measures.** ccryptolib in Cobalt, X25519 exchange, Ed25519 verify and keyed BLAKE3 or SHA-256 per section, each against the 7 second timeout. Whether each needs explicit yields, and whether A* yields often enough (it yields every `batch` nodes today, measured, `nav.lua` line 246). Which randomness source works in game. The fuel config (`turtleNeedsFuel`, fuel limits) and move cost with Turtlematic upgrades. `getPlayerPos` on the test server with the same AP config as live, its rounding, yaw and pitch signs and dimension field. Whether AR lines and text hide behind terrain. `os.epoch("ingame")` across `/time set` and `doDaylightCycle false`. Ender reach with the pack's Classic Peripherals config. Whether a normal-modem turtle reboots after its chunk reloads. Fuel delta per move with and without turtlebattery charging. Redstone analog read between two adjacent turtles. `fs.getFreeSpace` on a turtle at 1,000,000 bytes.
- [ ] **Gate A.** Bench probes run in CraftOS-PC and save `docs/evidence/p0/gateA.json`.
- [ ] **Gate B.** The same probes run on a disposable server with no GPS hosts. Save `gateB.json` and one screenshot per probe. Pass when every number in section 3 marked (guess) becomes measured or is listed as unreachable.

### H3. Server request queue

- [ ] **Scope.** One bounded queue (32 entries) and one worker coroutine. No yield inside `handle` or a save. Remove `sleep(0)` from the validator (`ssot.lua` line 281). Move `mirror` and `http.get` out of the request path (`server.lua` lines 220 and 403). Re-arm the timer robustly (line 896).
- [ ] **Contract.** A full queue replies `busy`. The client retries with the same `rid`, which the existing eight-result cache makes idempotent (measured, `ssot.lua` lines 232 to 236).
- [ ] **Gate A.** A rednet burst of 200 requests during a forced slow save. Pass when every request gets a reply or `busy`, and the timer fires every second.
- [ ] **Gate B.** The same burst against a real server with three turtles moving. Pass when no turtle stops on `SSOT timeout`.

### H1H2. MAC auth and signed manifest

- [ ] **Scope.** Vendor ccryptolib, no hand-written primitives. Requests carry a keyed MAC over `rid|counter|op|canonical body`, using ccryptolib's keyed BLAKE3. The manifest is signed once with the server's Ed25519 key and every client verifies it with the pinned public key. The key never travels. Replies carry a MAC. Counters near the maximum roll to a new epoch instead of locking out. The PR 6 manifest gains that signature and a pinned server id. Remove the unauthenticated `rednet.lookup` fallback (`update.lua` line 53 onward).
- [ ] **Contract.** Envelope `v = 2` with `mac`. A `v = 1` request is rejected once `ssot.cfg` sets `requireMac = true`. Flag defaults off.
- [ ] **Gate A.** Attacker suite. Replay, captured packet, spoofed sender id, fake `fleetserver` host, counter at 2,147,483,647. Pass when all are rejected and the honest turtle keeps working.
- [ ] **Gate B.** The same attacks from a second computer in the real world, plus an update interrupted halfway that rolls back. Pass when logs show rejection and the rolled-back files match the last good manifest.

### N1. GPS-free positions, frames and dead-reckoning confidence

- [ ] **Scope.** `nav.lua` gets a position source chain instead of GPS per step. Each move journals `intent` with `fuelBefore`, then `done`. GPS becomes an optional check. Add radio triangulation against fleet machines with known absolute positions, reusing the hub distance method. It needs at least four non-coplanar measurement points from references in loaded chunks and a small residual, or it falls back to `suspect`. Add a player anchor where a player detector exists. A player standing on top of a turtle types `$anchor 17`, and the turtle takes the floored player position minus one in y. Add the frame tag to poses in `ssot.lua`. Relative frames never merge into `abs`.
- [ ] **Confidence rules.** `certain` needs a clean journal since the last anchor. A boot with no unresolved entry is `suspect` until a six-face fingerprint matches the journal's last recorded neighbours. An unresolved move has two resolvers. The fuel resolver applies only when fuel is enabled, the move cost is known and no charging happened. The fingerprint resolver compares six faces on boot with the fingerprints journaled at intent for both `from` and `to`, using the faces known at intent. In a tunnel this separates the two cells, because air lies behind `to` and unmined stone lies ahead (inferred). Anything else is `lost`. These rules never read whether GPS exists.
- [ ] **Contract.** `pos v = 1` and `frame v = 1` from section 2.1. Server ops `anchor` and `frame-merge`, the second idempotent by frame id.
- [ ] **Gate A.** Scripted crash at every checkpoint of `step` (`move-prepared` to `move-saved`, `nav.lua` lines 193 to 221) with no GPS stub. Pass when every case ends `certain` with the right pose or `lost` with no dig call.
- [ ] **Gate B.** No GPS hosts in the world. A miner moves 200 blocks, the chunk unloads mid-move, and it reloads. A second run picks the turtle up and places it two blocks away in the same tunnel. Pass when the first resumes `certain` and the second becomes `lost` or `suspect` and digs nothing until re-anchored. Save video.

### I1. Install core, keyboard front end and enrolment

- [ ] **Scope.** `install-core.lua` holds the pure state machine from section 2.8. `install-keys.lua` renders it with arrow keys, Enter and number shortcuts on every machine. `install.lua` becomes the effect shell. `enrol.lua` adds server ops. The manifest gains a `roles` table, and install prunes scripts the role does not list. If PR 6's fix round lands that first, reuse it instead.
- [ ] **Coordinate order.** Neighbour first, then a copy code with inherited frame and a typed F3 position, then GPS if hosts answer, then guided `gpshost.lua` setup. A machine with only a relative position gets a relative frame.
- [ ] **Copy code flow.** The old paired machine asks the server for a code. The server issues it with a 120 second TTL and single use. The old machine only displays it. Both sides make ephemeral X25519 keys and exchange public keys and nonces. The new machine proves the code with a keyed MAC over both public keys, both nonces and both ids. The pairing key comes from the X25519 shared secret, so a sniffed claim no longer lets anyone brute-force the long-term key offline. The server marks the code used before replying. Five failed claims burn it. If X25519 fails P0, codes grow to 16 characters (80 bits) and the key comes from the code.
- [ ] **Neighbour flow.** The new machine reads `getID` of each adjacent `computer` or `turtle` peripheral. The server asks that paired neighbour to confirm the new id on a named side. Position comes from the neighbour's absolute pose and side. Facing comes from both sides' reports, or from turning until the neighbour is in front. The key comes from the same X25519 exchange, authenticated by a code the neighbour displays.
- [ ] **Keyboard redesign.** Arrow keys move, Enter confirms, digits pick an option, Backspace goes back. Every screen fits 39 by 13, the turtle terminal (measured, `Config.java` line 38). Lands first because it works on every machine.
- [ ] **H2 fit.** The enrolment reply names the signed manifest version and the role. The new machine installs only files whose hashes match that manifest, with the per-client MAC from H1H2.
- [ ] **Gate A.** Drive `install-core.lua` headlessly in CraftOS-PC with scripted events for every path. Expired code, replayed claim, burned code, missing neighbour, unknown neighbour, full disk and bundle hash mismatch. Pass when each ends on the right `error` step with a working `retry`.
- [ ] **Gate B.** A basic turtle installs as a miner by keyboard from a copy code, and another by neighbour, both without GPS. Capture an expired code screen and a replay rejection. Pass with screenshots of every screen and one video.

### I2. Touch front end

- [ ] **Scope.** `install-touch.lua` renders the same steps as buttons on an advanced computer, advanced turtle, pocket computer or attached advanced monitor. No logic beyond hit testing.
- [ ] **Gate A.** The same scripted event files from I1 replay through the touch renderer. Pass when the state sequence equals I1's for each file.
- [ ] **Gate B.** A real touch install on an advanced computer with an advanced monitor, including an error and retry screen. Screenshots and video.

### H4a. Subtract first

- [ ] **Scope.** Remove the code cache from the state server. Code moves to a mirror role on another computer. A full cache of 977,085 bytes does not fit one 1,000,000 byte mirror with its own code and staging (inferred), so the mirror serves role bundles only, or two mirrors split the list, or floppies hold it. `atomic.lua` keeps two copies. A failed save recovers and reports instead of poisoning. Capacity comes from `fs.getCapacity` and `fs.getFreeSpace`. A control reserve keeps poses, moves, leases and clients writable when the map is full. The same applies to the hub. It stops carrying miner code copies, which the mirror role serves instead. That drops the hub from 286,338 to 142,143 bytes of code (measured, summed). With ccryptolib and the planner core it needs about 260,000 bytes, leaving roughly 338,000 bytes for state with two copies (inferred).
- [ ] **Gate A.** New sandbox scenario at `computerSpaceLimit = 1000000`. Fill the disk mid-save. Pass when SSOT keeps answering control ops and the panel shows the failure.
- [ ] **Gate B.** A real server at 1,000,000 bytes with realistic state. Pass when a turtle still moves home with the map full.

### H4b1. Compact sections, per-section files and migration

- [ ] **Scope.** Palette plus RLE per section, which shrank a dense section from 35,770 to 963 bytes (measured, synthetic). Per-section files, dirty saves and batched writes. Lift the 64 section and 256 name caps. Migrate schema 1 idempotently and keep the old file until the new one verifies. Section keys carry the frame prefix from N1. Cell confidence is observed or unknown.
- [ ] **Storage effect.** With ccryptolib the server has roughly 343,000 bytes for map data (inferred, 1,000,000 minus 142,474 bytes of server code, 107,532 bytes of crypto and a 64 KB reserve, halved). The prototype workload needs 245,375 to 269,509 bytes in this format (measured), about 71% to 79%. So the storage prompt arrives after roughly one such workload (inferred). Today's format would need 1.6 to 7.3 MB for the same 203 sections and cannot hold it at all (inferred from 8,211 to 35,770 bytes per section).
- [ ] **Gate A.** Migrate a schema 1 state, crash mid-migration and rerun. Pass when the map is identical and the old file is gone only after verification.
- [ ] **Gate B.** A real 1,000,000 byte server holds the four-miner workload. Pass when stored bytes stay within 20% of the prototype and the ledger reads them correctly.

### H4b2. Baseline plus exceptions (size L, behind a flag)

- [ ] **Scope.** The region and section shapes in section 2.2. Segments from mining progress, committed straight moves and journals. Baselines versioned and frozen once referenced, with materialized diffs on recalibration. Only `abs` frames and `yAbs` frames calibrate.
- [ ] **Default rule.** It becomes the default only if it beats H4b1 on bytes in Gate B on a real world, with misprediction below the P0 threshold and no predicted cell ever used as a walk route. Otherwise the flag stays off.
- [ ] **Storage effect.** Against the 343,000 byte budget, this format needs 3% to 31% for the same workload (inferred from 9,460 to 107,648 measured bytes). The storage prompt and the need for peers would come about 2.5 to 26 times later than with H4b1 (inferred). Peers then hold mostly exceptions and segments, which are small and change rarely (inferred).
- [ ] **Gate A.** Replay the prototype workload. Pass when bytes stay within 20% of the prototype and a round trip returns the same observed cells.
- [ ] **Gate B.** Mine the four-miner workload in a real world under both formats. Pass when the comparison table is saved and the default rule above is applied to it.

### H5. Dead turtles

- [ ] **Scope.** Live recovery from the move journal. Expiry for `started` moves, poses and warehouse jobs. Admin `forget turtle`. A commit timeout recovers instead of halting. Active mining work stays quarantined to its owner, as today (measured, `docs/mining.md`).
- [ ] **Gate A.** Kill a turtle mid-move. Pass when its cells free after expiry and nothing else changes.
- [ ] **Gate B.** Break a turtle in the world mid-job. Pass when the server frees its cells and the panel offers `forget turtle`.

### H4c. Storage ledger, policy, pause and forget preview

- [ ] **Scope.** Ledger and policy from section 2.7. At `warnAt` the panel and glasses offer the choice. While undecided, map writes return `capacity`, control writes continue, and turtles keep observations in a bounded local buffer. The buffer budget comes from free space at runtime. When it is full the turtle stops new mining work, heads home and tells the player on the panel, glasses and chat. Nothing is dropped. `forget-old` builds a preview with exact keys, revs and hashes. Commit deletes an item only when its rev and hash still match, and reports the rest as skipped. Forgotten cells become unknown. The panel gets a storage view. Before H4d the expand option says it needs storage turtles.
- [ ] **Gate A.** Hit the threshold at 1,000,000 bytes, decline, then preview and commit. Pass when exactly the previewed set is gone and a section changed after the preview survives.
- [ ] **Gate B.** The same flow on a real server, with screenshots of the prompt, preview and storage view.

### W1. wh2 fleet core

- [ ] Built as `docs/design/wh2-contract.md` specifies. This plan adds registry keys for B1 dev thresholds and for `storagePolicy`. Gates per that contract.

### B1. Lease v2, offline movement and journal

- [ ] **Scope.** Signed leases from section 2.5. The server's `occupied` check counts leased cells, so the lease holder owns its area and corridor exclusively. Inside its lease a turtle moves by dead reckoning with no per-step RPC. The journal from section 2.6 is append-only and bounded. At 80% the miner stops new work and heads home. Replay is idempotent by `(turtle, lease, seq)`. An expired lease means no move or dig until renewal or a return-only grant.
- [ ] **Conflict rule.** This replaces game-time ordering (see pushback 1). Inside its own unexpired lease, the holder wins. Outside, an observation applies when the server cell is unknown, or when the section rev is not above the lease's `issuedRev`. Otherwise the cell becomes unknown. Ties order by UTC ms, then turtle id, then seq.
- [ ] **Gate A.** Server killed mid-lease. Two turtles replay overlapping corridor observations in both orders. Pass when the final map is the same in both orders.
- [ ] **Gate B.** The server on a normal wireless modem so range really ends. A miner leaves range, mines, returns and replays. Reconnect on an expired lease while another turtle holds the cells. A tunnel mined against a stale server map. The journal reaching 80%. Pass with exact item counts and video.

### B2. Local problem handling

- [ ] **Scope.** Full inventory, fuel reserve on every leg, bedrock, lava and water, gravel with bounded retries, mobs with bounded retries, dimension change (becomes `lost`), pickup (becomes `suspect` or `lost`), stuck. Each one is a registry setting with bounds. The invariants are not settings.
- [ ] **Gate A.** One fixture per problem. Pass when each ends in its documented state.
- [ ] **Gate B.** Lava, gravel, a mob and a full inventory out of range in one run, with video.

### H4d. Peer cold storage

- [ ] **Scope.** Records from sections 2.3 and 2.4. One-click enrol after a reachability check. A server-to-peer service runs as its own coroutine in store, warehouse and miner programs, because the client allows one call in flight (measured, `ssot-client.lua` line 26). Replicas carry a server-only storage key MAC, so peers hold opaque blobs. Lazy fetch into an LRU. Early re-replication on a falling score. Rebalance by free space. Peer quota leaves room for the turtle's own journal, navigation state and update staging.
- [ ] **Eligibility.** At least two non-miner holders. Miners may hold extra replicas only (see pushback 3). A miner's disk is tight, with about 186 KB of code, `nav.state` up to about 400 KB during a two-copy save, the journal and PR 6 staging (measured limits, `nav.lua` line 45), so miners rarely hold much (inferred). A peer whose boot id changed since its last ack is dropped from the count until it re-verifies its blobs by hash.
- [ ] **Storage key.** Exporting the server's storage key to a floppy is a mandatory setup step before peer storage can be enabled.
- [ ] **Gate A.** Two store peers and one computer peer at 1,000,000 bytes. Kill one peer. Pass when data re-replicates and unreachable sections read as unknown.
- [ ] **Gate B.** At the real 1 MB limit, enrol a turtle from the prompt, verify migration, lose a peer, verify re-replication. Screenshots and video.

## 5b. Turtle Planner track

The player draws a base on a top-down map, places a chest and a bot, gets a copy code, and types it into the new turtle. The server already knows the bot's role, settings, job area and exact cell.

### Shapes

```lua
plan = { v = 1, id = "p:4:17",          -- origin computer id, then a durable counter at that origin
  frame = "abs", dim = "minecraft:overworld", y = 64, name = "Base", rev = 3,
  areas = { { id = "p:4:18", kind = "base", min = pos, max = pos } },
  fixtures = { "p:4:19" }, bots = { "p:4:20" } }
plannedFixture = { v = 1, id = "p:4:19", plan = "p:4:17", kind = "chest",   -- chest, dropoff, charger, furnace
  pos = pos, side = "front", state = "planned",   -- planned, verified, active, retired
  layoutId = false }                              -- wh2 layout location id once verified
plannedBot = { v = 1, id = "p:4:20", plan = "p:4:17", role = "miner",
  pos = pos,                                       -- includes the planned facing h
  settings = { revision = 4, overrides = {} }, devToggles = {}, jobArea = { min = pos, max = pos },
  expect = { neighbours = { [2] = "minecraft:chest" }, peripherals = { back = "inventory" } },
  state = "planned",      -- planned, code-issued, claimed, verified, active, retired
  code = false,           -- copyCode reference while code-issued
  computerId = false }    -- set at claim
authority = { v = 1, holder = 4, epoch = 2, since = 0, kind = "hub" }   -- exactly one code issuer
```

Planned entries are intents, not occupancy. A planned bot's cell and a fixture's cell go into the existing reservation check as `intent` holds. Other turtles route around them like occupied cells, and nothing moves on their behalf. At `claimed` the intent becomes the real pose through the existing `sync` op, keyed by the bot's computer id. An intent never counts as observed or free in the map. Retiring a plan releases its intents in one revision.

The copy code record from section 2.9 and the install core from section 2.8 serve the planner unchanged. The only difference is that the planner issues the code and sets `planBot`. Planner codes get a longer TTL, 15 minutes by default, because the player walks to the spot. Single use and the 5-try burn stay.

### Facts that shape it

- Monitor size is capped at 8 by 6 blocks (measured, `Config.java` lines 44 to 45). At text scale 0.5 that is 328 by 162 character cells, and at scale 1 it is 164 by 81 (measured, computed from `ServerMonitor.java` lines 34 to 42). A computer screen is 51 by 19, a turtle 39 by 13, a pocket 26 by 20 (measured, `Config.java` lines 35 to 42). There are 16 palette colours per screen, and `blit` draws a row in one call (measured, `fleetview.lua` line 289 uses it).
- So one map cell is one character, and a pocket shows a 26 by 18 window at best (inferred). Known, predicted, unknown, intent and real occupancy each need a distinct colour and glyph pair, not colour alone (inferred).
- The server draws on the best monitor it finds and handles `monitor_touch` and `mouse_click` (measured, `server.lua` lines 534 to 537 and 897). The panel is an advanced pocket computer whose map tab needs GPS hosts today (measured, `panel.lua` lines 1 and 17). PR 5 adds a projected top view with click targets in `views.lua` and `view-scene.lua` (measured, PR #29). The planner reuses that projection rather than adding a third.
- The hub runs without a server and sends orders straight to turtles (measured, `hub.lua` lines 13 and 255). It looks for a server every 30 seconds (measured, line 1495). It keeps `hub.state` and syncs with the server where the newer `rev` wins (measured, lines 116 and 213). The hub does not load `ssot.lua` (measured, grep). So a hub-only mode exists for the legacy fleet, but it has no reservations, leases or authentication (inferred).
- The hub role needs 286,338 bytes of code because it carries miner copies (measured, summed from its `ALSO` list).

### Absolute coordinates without GPS

The server knows absolute coordinates only after its frame is anchored. Anchor it once by F3 entry on the server or hub, as `hub pos` already allows (measured, `README.md` line 343), or from a known machine. Where an AP player detector is attached, one stand-here anchor replaces the F3 entry, since `getPlayerPos` is reported exact on live with unlimited range and the dimension included (reported by the AR doc, checked in P0 on the test server). Until then every plan carries a relative frame tag. A relative plan works for placement relative to the anchor machine, but its cells never merge into the absolute map, and its bots get relative poses. Anchoring later re-keys the plan with the N1 `frame-merge` op.

### Placement verification without GPS

At claim the new turtle reports what it can observe. It inspects front, up and down, turns to inspect the other sides, and lists adjacent peripheral types with `peripheral.getType`. The server compares that with `expect`. A planned chest found on the planned side and matching known map cells around it confirms the cell and the facing. A mismatch reports the wrong cell or facing on the installer screen with a retry. This check is strong when the neighbourhood is distinctive, for example a chest on one side and air above (inferred). It is weak in uniform stone, where many cells look alike (inferred). So the turtle's position confidence becomes `certain` only when the fingerprint is distinctive, else `suspect` until a neighbour check or F3 entry confirms it.

### Hub-only mode

Pushback. A hub that becomes the source of truth must not reimplement server logic. The hub loads the same `ssot.lua` and planner core with a `hub` profile, a smaller budget from the same ledger, no peers and no code mirror. One module, two profiles.

- The hub stores plans, intents, poses, moves, leases, copy codes and pairing keys under the same shapes.
- Its budget is about 300,000 bytes for state with two copies (inferred, 1,000,000 minus 286,338 bytes of code and a control reserve, halved). The storage policy and the 80% prompt apply. Expand means adding a server, since the hub has no peers.
- Ids are minted at creation as origin computer id plus a durable counter, so hub ids never collide with server ids (inferred, CC computer ids are unique per world).
- Handover runs once. The hub sets `authority` to frozen, stops issuing codes and leases, and exports in pages. The server imports keyed by id, so a repeat import adds nothing. The server then takes `authority` with epoch plus one and the hub becomes a client. A crash at any step resumes from the authority record.
- Unclaimed codes migrate with their remaining TTL, because the claim MAC binds to whichever server answers the hello. A code mid-claim is invalidated and reissued.
- This replaces the hub's newer-rev-wins sync for SSOT data. Two writers with last-writer-wins is the race this design removes.

### Track PRs

#### T1. Planner core and MVP on the server

- [ ] **Scope.** `planner-core.lua` is pure, with typed events like the install core. A host adapter for the server computer and its advanced monitor, keyboard and touch. One Y level, one base area, one chest and one miner, then issue the code. Ops `plan-put`, `plan-intent`, `plan-code` and `plan-claim` in the SSOT dispatcher. Styling for known, predicted, unknown, intent and occupied cells.
- [ ] **Gate A.** Scripted events draw a base, place a chest, plan a miner and issue a code. A sandbox turtle runs the installer with that code. Pass when the turtle's saved pose, role and settings equal the plan, and a wrong placement is reported.
- [ ] **Gate B.** No GPS hosts. Anchor the server by F3 once. Plan a chest and miner on the monitor, place the turtle on the marked cell, type the code, and let it mine. Then place a second turtle one cell off. Pass when the first verifies with exact coordinates and the second gets a wrong-cell screen. Screenshots and video.

#### S1. SSOT hub profile and authority handover (size L)

- [ ] **Scope.** `ssot.lua` profiles `server` and `hub`. The authority record and handover ops. Idempotent import keyed by id.
- [ ] **Gate A.** Hub-only fleet with plans, intents and two unclaimed codes. Crash the handover at every step and rerun. Pass when the server ends with the same ids once each and the codes still claim.
- [ ] **Gate B.** A real hub-only base, then a server added. Pass when plans, reservations and codes survive, one code is claimed after migration, and the hub never issues a code after handover.

#### T2. Full planner on all hosts

- [ ] **Scope.** Y slider, area drawing, all fixture kinds, other bot roles, job areas, dev toggles. Host adapters for the panel pocket, the hub and the server. Depends on T1 only. Until S1 lands, the hub adapter runs with a server present. Hub-only planning arrives with S1. Optional AR ghost markers through the existing AR owner.
- [ ] **Gate A.** The same scripted plan replays on all three adapters at their screen sizes. Pass when the resulting plan records are identical.
- [ ] **Gate B.** Plan on the panel, the hub and the server in turn, including a relative-frame plan merged after anchoring. Screenshots per host and one video.

#### A1. AR planner MVP (glasses plus chat, panel optional)

The AR front end is one more thin adapter over `planner-core.lua`. It turns chat commands and look samples into the same typed events as touch and keyboard.

- [ ] **Event mapping.** `$plan chest` becomes `{ t = "place", kind = "chest", at = lookHit }`. `$plan here miner north` becomes `{ t = "place", kind = "bot", role = "miner", at = feet, h = 3 }`. `$level 64` and `$level +1` become `{ t = "level", y = 64 }`. `$plan ok` becomes `{ t = "confirm" }`. `$undo` becomes `{ t = "undo" }`. Commands come through PR 6's `chat-control.lua` UUID allowlist.
- [ ] **Look cursor.** Poll `getPlayerPos` at 4 Hz. Step a voxel ray from the eye. Only observed solid cells stop the ray. Predicted and unknown cells draw as an uncertain cursor. A geo scanner scan near the player confirms the hit when one is attached. `here` mode uses the feet cell and needs no ray.
- [ ] **Drawing.** Ghost item models for planned chests and turtles, line boxes and labels for the current level plus or minus one only. Cap at 128 elements and 2 updates per second, only on change. Redraw everything on boot, because frames are blank after a restart. One planner session at a time per controller, with the planner's name in the HUD, because every wearer sees the same picture.
- [ ] **Code delivery.** The copy code arrives as a private chat message and a toast, and shows in the HUD.
- [ ] **Anchoring.** Where a player detector exists, plans take absolute coordinates straight from player positions, so the base needs no F3 entry and no GPS (inferred from the reported detector behavior, checked in P0). Without a detector the AR adapter is unavailable and the panel remains.
- [ ] **Limits kept.** A block controller works only in its own dimension, so other dimensions use the panel. Forms, the whole-base view, big edits and players without goggles stay on the panel.
- [ ] **Gate A.** Feed recorded `getPlayerPos` samples and chat events into the adapter in CraftOS-PC with mocked AR and AP peripherals. Pass when the resulting plan equals the plan the same steps make through the keyboard adapter.
- [ ] **Gate B.** With only glasses and chat, plan a chest and a miner, receive the code by whisper, place the turtle and type the code. Pass when the turtle's coordinates equal the ghost's coordinates and it starts mining. Record a video from the goggles view, and one screenshot proving whether lines show through terrain.

Order. A1 comes right after T1 and before T2. T1 builds the core and the panel forms that AR still needs for roles and settings. A1 then proves the core is host independent with the most different host before T2 adds more panel features. A1 needs PR 6 merged.

#### Order against wh2 layout

Layout should consume planner intents. A verified fixture becomes a layout `location` through the existing `wh2-layout` op, so there is one registry of drop-offs, chargers and furnaces (inferred from `docs/design/wh2-contract.md` ownership). If layout lands first, T1 writes through it instead.

## 6. Test plan

- [ ] **Unit.** Each PR adds cases to `tests/run.lua` and runs `C:\Tools\lua52\lua52.exe tests\run.lua`. Behavior only, through public module APIs.
- [ ] **Fuzz.** Random and malformed messages against every validator, including enrolment and replica ops.
- [ ] **Gate A scenarios.** Add `-Disk 1000000` and `-NoGps` to `tests/sandbox/run.ps1`. Every PR from H4a onward runs at 1,000,000 bytes. Every PR from N1 onward runs with no GPS stub.
- [ ] **Gate B default world.** No GPS hosts, server at 1,000,000 bytes, real jars, real client, disposable root per `docs/testing/gateB-depth.md`. One extra run with GPS hosts and one with an ender server.
- [ ] **Gate B list from the request.** Threshold, decline, enrol, migrate, exact forget preview. Peer loss and re-replication. Chunk unload mid-move without GPS and no dig. Reconnect on an expired lease while another turtle holds the cells. A mined tunnel against a stale map. Journal at 80%.
- [ ] **Planner and hub.** Planner on all three hosts and through the glasses. Hub-to-server migration with codes and reservations intact.
- [ ] **Soak.** Two hours, four turtles, logging save time, state size and ledger growth.

## 7. Risks

- **ccryptolib speed and randomness in Cobalt.** Unmeasured (guess). An X25519 operation may need yields to stay under the 7 second timeout. Weak randomness on a fresh turtle would weaken enrolment. P0 measures both. The fallback is 16-character codes.
- **Crypto disk cost.** 107,532 bytes per role that loads everything (measured). Prune enrolment-only modules after pairing.
- **Player detector trust.** Its exactness is reported from live config, not measured on the test server. A server with random error enabled would break AR anchoring. P0 checks it.
- **Dead reckoning after pickup.** A turtle placed into an identical spot passes the fingerprint (inferred). The panel's "I moved this turtle" action and the fuel check reduce this. It remains a residual risk.
- **Fuel delta with turtlebattery.** Charging during a move breaks the fuel resolver (inferred). Then the entry stays unresolved and the turtle is `lost`.
- **Baseline drift and caves.** Aquifers, caves and modded worldgen are mispredicted (inferred). Predicted is never free, so the cost is bytes, not safety. Few samples are handled by the minimum sample count.
- **Copy code guessing.** With X25519 a sniffer gains nothing offline, and online guesses stop after 5 tries (inferred). Without X25519 the 16-character fallback leaves 80 bits against offline guessing (inferred).
- **32 paired computers.** Enrolment and peers hit the cap (measured, `ssot.lua` line 30). Raise it with H4a's capacity work.
- **Storage key loss.** If the server's storage key is lost, every replica is unverifiable (inferred). The floppy export is mandatory before peers.
- **Placement fingerprint in uniform stone.** A turtle placed one cell off along a stone wall can match the plan (inferred). It stays `suspect` and the installer asks for F3 entry or a neighbour check.
- **Planner screens.** A pocket shows about 26 by 18 cells (inferred). Large bases need panning, and the MVP limits itself to one Y level.
- **Handover crash.** A crash between export and authority change could leave two issuers (inferred). The authority epoch and the frozen state prevent issuing until the record resolves.
- **Two ssot.lua writers.** I1 and H4b1 both touch the dispatcher. Merge order decides who rebases.

## 8. Pushback (each keeps Jeffrey's decision)

1. **"Newest game-time observation wins" is unsafe.** In-game time moves in 3,600 ms ticks, follows `/time set` and freezes with `doDaylightCycle` off (measured and inferred, section 3). Keep "newest observation wins" where it can be proven. Use lease authority, the section-rev check and the UTC tie-break from B1.
2. **"No digging while lost" cannot depend on GPS.** GPS is absent in Jeffrey's world, and pickup and chunk reload both just reboot the turtle (inferred). Define lost by dead-reckoning confidence as in N1.
3. **Miners cannot count toward the two replicas.** A miner on a normal modem out of range is unreachable by definition, and an unloaded one cannot answer at all (inferred). The server cannot see an unloaded chunk, only silence and a later boot change (inferred from `ssot-client.lua` line 6). Keep miners in the rating, as decided, but let them hold only extra replicas, and never while they hold an offline lease.
4. **"Writes pause" must not pause control writes.** Every move saves state today (measured, `ssot.lua` line 255). A full disk would freeze every turtle in place. Pause only map growth and keep a control reserve.
5. **Hub as source of truth must not duplicate the server.** Run the same SSOT module in a hub profile, as in S1. The hub's current newer-rev-wins sync must go for SSOT data, because two writers race (measured, `hub.lua` lines 116 and 213).
6. **If the player never answers, mining stops growing the map.** Nothing is lost and nothing is forgotten, as decided. The panel and glasses remind on a period. This is the honest cost of decision 7 and Jeffrey should know it.

## 9. Overlooked items

- The SSOT features from PR 2 to PR 4 need GPS and so do not run in Jeffrey's world today (inferred, section 3). N1 fixes that for all of them.
- With an ender modem on the server, a normal-modem turtle is never out of range in the same dimension (measured, `WirelessNetwork`). Out of range happens only with a normal-modem server, another dimension, a server restart or the Classic Peripherals nerf (inferred). Gate B must force it.
- Each turtle also has 1,000,000 bytes. A miner's code takes 186,344 bytes, and `nav.state` may reach 400,000 bytes with two copies during a save (measured, `nav.lua` line 45). The journal budget must come from free space at runtime.
- PR 6's staged update briefly needs room for staged and backup copies (measured, `update.lua` in PR #28). Peer quotas must leave that room.
- Many small files waste space at 500 bytes minimum each (measured). Batch small replicas.
- Planner codes live 15 minutes instead of 120 seconds. The longer TTL only widens the window for online guesses, which the 5-try burn caps (inferred).
- Pairing keys live outside `ssot.state` and never go to peers.
- A turtle in another dimension cannot use a frame from the overworld. Dimension change means `lost`.

## 10. Left out on purpose

- A separate palette plus RLE format. Baseline plus exceptions replaces it.
- A per-section RLE fallback for dense scans. Add it only if Gate B shows sections above about 1,365 exceptions.
- Encryption of traffic. Keys stay off the air through X25519, and messages carry MACs, but contents are not encrypted.
- The redstone key channel. X25519 makes it unnecessary.
- Making ender modems the default. Jeffrey kept both ideas.
- Drawing tools, the Y slider and non-miner bots in the planner MVP. They come in T2.
- Re-planning PR 5, PR 6, layout, wizard and craft. They keep their own plans.

## 11. Judgment review

Verdict. Poteto Judgment said ship with fixes. It agreed with all pushbacks and with N1 placed early.

| Finding | Decision | Why |
| --- | --- | --- |
| 1. Fuel resolver breaks without fuel or with Turtlematic move costs | Accepted | Both cases change fuel per move. P0 measures the fuel config. A fingerprint resolver now journals `from` and `to` faces at intent. Partial note. The `to` fingerprint can only use faces known at intent, so it is weak in unexplored stone. |
| 2. Triangulation needs 4 non-coplanar references in loaded chunks | Accepted with a change | The real requirement is four non-coplanar measurement points. The existing hub method gets them from one reference plus the turtle's own reckoned moves (measured, `miner.lua` lines 346 to 360). So the rule names measurement points, not machines. |
| 3. Drop a peer whose boot id changed until it re-verifies | Accepted | A reboot can mean a lost or replaced disk. Re-verification is cheap with small sections. |
| 4. Bound the local buffer during the pause | Accepted | Full buffer stops new work and tells the player. Nothing is dropped. |
| 5. X25519 enrolment with ccryptolib, no hand-rolled crypto | Accepted with two changes | ccryptolib exists, is MIT and has X25519, Ed25519, SHA-256 and BLAKE3 (measured). It has no HMAC, so MACs use its keyed BLAKE3 instead of a hand-written HMAC wrapper. The manifest uses Ed25519 instead of per-client MACs. The redstone channel is dropped. |
| 6. Split H4b into H4b1 and H4b2 | Accepted | H4b1 alone fixes the 1 MB failure. H4b2 is L and must prove itself on a real world. |
| 7. S1 is L, T2 must not depend on S1 | Accepted | The hub adapter runs with a server until S1 lands. |
| 8. H4a applies to the hub | Accepted | Dropping miner copies takes the hub to 142,143 bytes of code (measured). |
| SHA-256 and A* against the 7 s timeout in P0 | Accepted | A* already yields per batch (measured). Hashing does not (measured), so P0 measures it. |
| H4d says miners rarely hold much | Accepted | Added with the measured limits. |
| Floppy export of the storage key mandatory | Accepted with a narrower scope | Mandatory before peer storage is enabled, not before the server runs, so a player without a disk drive still gets a working server. |

Remaining disagreement. Two small points. Judgment asked for HMAC by name, and this plan uses keyed BLAKE3 because ccryptolib provides it and HMAC would mean writing a wrapper. If Jeffrey prefers HMAC-SHA256, the wrapper is ten lines checked against the RFC 4231 vectors. The floppy step is scoped to peers rather than to the whole server.

## Appendix A. Prototype evidence

Box files `/workspace/proto/sha.lua` (throwaway, superseded by ccryptolib), `bench.lua`, `chunkfmt.lua`, `baseline.py`, `b_0.10.py` and `b_0.25.py`. They are not committed to the repo. ccryptolib was cloned to `/tmp/ccl` at `14489aa`. Unproven items are listed in P0.

## Appendix B. Links

`docs/design/hardening.md`, `docs/design/miner-autonomy.md`, `docs/design/wh2-contract.md`, `docs/review/judgment-2026-10-20.md` and `docs/testing/gateB-depth.md` on `feat/wh2-base`. PR bodies for https://github.com/140er/computercraft-scripts/pull/28 and https://github.com/140er/computercraft-scripts/pull/29.
