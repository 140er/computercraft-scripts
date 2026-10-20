# P0 runtime measurements

Gate A passed. The CraftOS-PC column and [gateA.json](gateA.json) are a Linux
rerun of the bench probes on CraftOS-PC 2.8.3. The Cobalt column is the
disposable-server run and did not change. Gate B failed because the required
real client was occupied by another session. The detector position checks,
AR occlusion, F2 screenshots and video did not run. The saved server
measurements below are real runs, not substitutes for those missing checks.

The host was box run `h4-p0-b7ab5018`, disposable, not live. It ran Minecraft
1.21.1 with CC:Tweaked 1.120.2 and the pack jars in [jar-sha256.txt](jar-sha256.txt).
The daemon copied the pack configs. Only the disposable run's CC disk limit
changed to 1,000,000 bytes. There were no GPS hosts.

## Crypto

Each row contains five measurements in milliseconds, including the first
sample. Zero means less than the millisecond clock resolution.

| Operation and input bytes | CraftOS-PC | Cobalt |
| --- | --- | --- |
| blake3-keyed-1024 | 1, 0, 1, 1, 0 | 7, 1, 1, 1, 1 |
| blake3-keyed-8192 | 3, 3, 2, 2, 3 | 53, 6, 7, 6, 6 |
| blake3-keyed-37888 | 14, 13, 13, 13, 12 | 122, 26, 27, 28, 24 |
| sha256-section-963 | 1, 1, 1, 1, 1 | 16, 2, 2, 2, 2 |
| sha256-section-12288 | 13, 12, 13, 12, 12 | 83, 24, 31, 26, 21 |
| sha256-section-37888 | 38, 43, 37, 38, 36 | 99, 80, 77, 77, 69 |
| x25519-keygen | 2, 1, 2, 1, 1 | 8, 6, 5, 5, 5 |
| x25519-exchange | 5, 6, 6, 5, 6 | 27, 22, 19, 34, 24 |
| ed25519-sign | 3, 2, 1, 2, 2 | 9, 10, 10, 6, 9 |
| ed25519-verify | 7, 7, 8, 6, 6 | 39, 25, 42, 40, 34 |
| ed25519-reject | 6, 6, 6, 6, 7 | 42, 34, 27, 24, 24 |
| ed25519-sign-8192 | 17, 17, 17, 16, 16 | 43, 39, 52, 39, 39 |
| ed25519-verify-8192 | 23, 21, 21, 21, 21 | 62, 58, 67, 64, 56 |

Each runtime completed 65 samples with no failed checks and five deliberate
modified-message rejections. Every crypto sample made zero explicit yields.
The largest uninterrupted sample was 43 ms in CraftOS-PC and 122 ms in Cobalt,
below the 7,000 ms watchdog. These inputs do not need an internal yield on the
measured systems. Future queues still need bounded work between requests.

The X25519 key-generation row measures public-key derivation from a fixed
RFC 7748 private key. It excludes entropy initialization. Signature generation
uses a public seeded generator. Ed25519's generated signatures passed
verification outside the timed region. Independent RFC verification and
modified-message rejection run as their own timed operations.

The SHA payload sizes represent the plan's section sizing examples. They
measure hashing, not an implemented H4 serializer. The CPU-saturated shared
VM and the disposable server differ, so these numbers are not a controlled
runtime speed comparison. [host-load.json](host-load.json) records VM load.

## Randomness

| Source | CraftOS-PC | Cobalt | Interpretation |
| --- | --- | --- | --- |
| Uninitialized generator | Rejected in 2 ms | Rejected in 4 ms | Initialization is required. |
| Supplied public fixture seed | 1 ms, 32 bytes | 2 ms, 32 bytes | Works, but the fixture has no secret entropy. |
| VM instruction timing | 534 ms, 32 bytes | 573 ms, 32 bytes | Works. Upstream warns that this source is riskier. |
| Krist HTTPS websocket token | Failed in 150 ms, no token URL | Failed in 57 ms, domain not permitted | Unavailable under these settings. No token was saved. |
| Classic crypto peripheral | Absent in the emulator | 15 ms, 32 bytes | `cryptographic_accelerator` and `randomBytes` work in this pack. |

Use the crypto peripheral when attached, or a separately supplied secret seed.
Do not treat a successful timing-noise call as proof of entropy quality.
Do not assume Krist is reachable. Peripheral absence on a new turtle remains
a real provisioning concern.

## Storage

All seven Cobalt disks reported capacity 1,000,000 bytes. Before the fixture,
each reported 802,070 bytes free. After it, each reported 798,069 bytes free.
A directory cost 500 bytes. Files of 0, 1, 499, 500, 501 and 1,000 bytes cost
500, 500, 500, 500, 501 and 1,000 bytes. That is 4,001 allocated bytes for
2,501 content bytes plus the directory.

All three CraftOS-PC disks reported the same capacity. Their free space fell
from 807,679 to 805,178 bytes. Directories cost zero and files cost their
content size. CraftOS-PC cannot prove the 500-byte accounting rule.
The two emulator turtle identities are mocks. Gate B used six real turtles.
The different initial free space reflects the probe revision and filesystem
accounting, not a controlled software-size comparison.

## A* and world measurements

| Probe | Exact observed result |
| --- | --- |
| A*, each runtime | Ten trials. Five 2,048-node searches refused with `search budget`. Five 4,096-node searches found 126 moves. No physical moves or GPS calls. |
| A* yields | 62 yields for each 2,048-node search, 127 for each 4,096-node search. Longest uninterrupted slice was 11 ms in CraftOS-PC and 11 ms in Cobalt. |
| A* total time | CraftOS-PC 3,669 to 3,700 ms and 7,519 to 7,599 ms. Cobalt 3,099 to 3,101 ms and 6,350 to 6,400 ms. Yielding kept each trial within the watchdog between suspensions. |
| Fuel config | Fuel required. Normal limit 20,000. Advanced limit 100,000. All six test turtles were advanced. |
| Normal turtle | Ten moves consumed ten fuel. Two idle seconds changed fuel by zero. |
| Turtlematic automata, netherite, creative and chunk vial | Ten moves per upgrade. Every move consumed one fuel. Two idle seconds changed fuel by zero. |
| Turtlematic starbound | Ten moves. Observed per-move decreases were 1, 1, -1, 1, 0, 0, -1, 1, -3, -1. Idle fuel rose from 1,029 to 1,033. |
| Charging enabled | Ten moves. Nine immediate decreases were one and one was zero. Idle fuel rose from 4,652 to 4,661. |
| Charging removed | Ten moves consumed ten fuel. Idle fuel stayed at 4,696. |
| Analog redstone | Four outputs 0, 1, 7, 15 read back as 0, 1, 7, 15 on the adjacent turtle. |
| Ender to normal, 512 blocks | 10 of 10 packets arrived. Reported distance was 512. |
| Normal to normal, 512 blocks | 0 of 10 new packets arrived. The receiver retained the ten earlier ender packets. |
| Ender to normal, Nether | 10 of 10 packets arrived. Distance was absent. |
| Normal-modem turtle chunk reload | Boot count rose from 4 to 5. Three unloaded-chunk queries and an unchanged heartbeat preceded reload. |
| Frozen game time | Five readings stayed at 111,600,000. UTC advanced between readings. |
| `/time set 6000` | Five readings stayed at 129,600,000, a jump of 18,000,000. |
| Daylight cycle enabled | Five readings increased by 7,200 per approximately 100 ms. |

There were 80 successful physical moves in the eight completed fuel scenarios.
Fuel differences cannot count moves when charging or starbound regeneration
is active. The copied Turtlematic config sets starbound regeneration chance
to 0.15 and amount to one. Its normal tier rate ceilings are 2, 3, 4 and 6,
with a creative ceiling of 32. Those are operation rate settings, not measured
per-move charges.

The charger started with 64 coal blocks. The saved inventory query found 63,
with one burning. The three queried turtle inventories were empty.
RCON confirmed 341 floor blocks and 15 monitor blocks. The test used seven
computer disks and seven forceloaded Overworld chunks plus one Nether chunk.
It made zero dig calls.

## Detector and AR

The copied AP config sets detector range to -1 and random position error to
false. That is config evidence only. Rounding, yaw, pitch, eye height,
dimension reporting, measured range, repeatability and the `$anchor`
calculation still require the real client.

AR line and text occlusion also remain unmeasured. The capture script draws
two lines and two texts, then compares a stone wall with open air.
The server accepted two lines and two texts in a 7 ms API preflight.
An offline detector call returned no online players. Neither that call nor
a successful AR peripheral call establishes the required player measurements.
Neither the source comments nor a successful peripheral call establishes
visibility through terrain.

## Section 3 guesses

| Guess in the accepted plan | Disposition |
| --- | --- |
| Classic Peripherals may nerf ender reach. | Measured. `enderModemNerf=false`; 10/10 packets arrived at 512 blocks and across dimensions. |
| The pack may lack a crypto peripheral. | Measured. Its accelerator provided 32 random bytes after 15 ms initialization. |
| Cobalt crypto may exceed the watchdog. | Measured. All 65 samples passed; maximum uninterrupted duration was 122 ms. |
| The throwaway HMAC prototype's Cobalt speed is unknown. | Unreachable in this PR. The plan replaces that unshipped implementation with vendored keyed BLAKE3. No handwritten HMAC is introduced. |

The additional detector and AR assumptions remain unverified and keep
Gate B failed.

## Evidence and failures

[gateA.json](gateA.json) and [gateB.json](gateB.json) retain the raw operation
results and exact counts. [computer-disks.zip](computer-disks.zip) contains
the real disks. [craftos-run.zip](craftos-run.zip) contains the three emulator
disks and 35 native terminal screenshots from the Linux rerun. [rcon.txt](rcon.txt) and
[logs/latest.log](logs/latest.log) come from the disposable run.
[unit.log](unit.log) has 150 named passing checks, including the main suite's
99-test summary. `lua5.2 tests/run.lua` on Linux printed the same 150 lines
and `99 tests passed`, exit code 0. [sandbox-smoke.txt](sandbox-smoke.txt)
is the separate CraftOS-PC smoke scenario from the Linux Gate A runner:
server, hub, and miner each passed, and the runner printed `Sandbox PASS`.

Failed and superseded attempts remain under `failed-attempts`.

- The first emulator attempt hit startup watchdogs under CPU saturation.
  Setup now yields between imports and filesystem work.
- The next attempt exposed a missing module loader in `dofile` scripts.
  Each probe now uses CC's own require environment.
- A later crypto attempt compared randomized Ed25519 signatures with a
  deterministic RFC signature. The corrected check verifies generated
  signatures. The RFC verification case remains independent.
- One emulator attempt could not boot its two child computers and reported
  BIOS parser errors. The runner now uses three separate CraftOS processes.
- An emulator run passed its numerical checks but some asynchronous captures
  showed the next progress screen. The result now stays visible before and
  after capture. The final images show the measured operation and its result.
- A server command was read while its host upload was incomplete.
  Commands now require readback equality and a separate ready marker.
- An upgrade name contained underscores rejected by the probe ID validator.
  The validator now accepts underscores. All five upgrades completed.
- Some final downloads and stop requests failed in transit. The final retry
  saved the stopped computer disks and shutdown logs, then deleted the run.
  `transport-retries.json` records the attempts. Their cause is not established.

## Scope of the gates

P0 changes test instruments and the contract, with no production behavior.
The warehouse, crafting, wizard, installer, attack, replication and storage
eviction flows belong to later PRs. They are outside this measurement PR.
No two-hour behavioral soak is claimed.

The required detector, AR, F2 and video checks were skipped because
the shared client lock was blocked by Minecraft PID 9804 from an earlier
session. P0 did not start that process and must not stop it. This is a Gate B
failure, not an exemption. The contract's shapes can be reviewed, but P0
must not be treated as passed until those checks run.

The disposable run was saved, stopped and deleted. See [closed.json](closed.json).
The client waiter was stopped without stopping the existing Minecraft client.
A follow-up capture needs a new disposable run using the committed scripts.

## Decisions from the probes

The Model the Domain principle led to a registry of named probes with one
result shape. The Explain the Number principle led to output checks, raw
timings, explicit yield counts and separate entropy initialization. It also
kept emulator disk accounting distinct from the Cobalt result.
