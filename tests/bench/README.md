# P0 platform probes

These scripts measure the installed runtimes. No production script loads them.
All keys, messages and seeds in the crypto benchmark are public fixtures.
Never use them for enrolment.

The vendored MIT ccryptolib files are unchanged at commit
`14489aa1ec408f8a07e1292be5ef91dfe8567c74`.
`vendor/source.json` records each file hash.
The files match upstream Git blobs byte for byte. The recorded runtime disks
retain the equivalent CRLF checkout used during measurement.

## Result format

Each timed operation records `ok`, `elapsedMs`, `yields`, `longestSliceMs`,
`belowTimeout`, `value` and `error`. The threshold is 7,000 ms between
coroutine suspensions. Total duration may exceed it when the operation yields.
The wrapper forwards event filters. Files and screenshots are written outside
the timed operation.

Crypto runs five rounds in alternating case order. Each round covers keyed
BLAKE3 at 1,024, 8,192 and 37,888 bytes, SHA-256 at 963, 12,288 and 37,888 bytes,
X25519 public-key generation and exchange, and Ed25519 signing, verification
and modified-message rejection. Ed25519 also signs and verifies an 8,192-byte
manifest fixture. X25519 uses fixed RFC 7748 keys. Entropy initialization is a
separate probe. Ed25519 signatures are randomized by ccryptolib, so the probe
verifies generated signatures rather than comparing their bytes with a
deterministic signature. RFC 8032 verification remains a separate case.

The first sample includes runtime warmup. Keep all five samples when comparing
the result. Millisecond wall-clock readings include scheduling delays. The
shared VM was saturated during P0, so the results establish watchdog headroom
for these inputs, not a portable speed ratio between runtimes.

SHA-256 uses fixed-size section payloads from the plan's sizing examples.
It does not claim to serialize a future H4 section implementation.

## Gate A

```powershell
C:\Tools\lua52\lua52.exe tests\run.lua
tests\sandbox\run.ps1 -Scenario bench -Disk 1000000 -Output <raw>\gateA
```

The runner starts three CraftOS-PC processes with private computer disks.
Two identify as mock turtles for storage classification. They perform no
physical movement. A* loads the real `nav.lua` and a 64 by 64 known-air fixture.
Five searches stop at the 2,048-node budget. Five searches at 4,096 nodes find
a 126-move path. No search calls GPS or moves a turtle.

CraftOS-PC's SDL dummy driver saves terminal screenshots without a desktop.
Its disk accounting differs from Cobalt. Report both measurements.

## Gate B

Read `C:\Work\gemini-input\gateb\README.md`. Allocate a disposable run with
`-SpaceLimit 1000000`, then start it through the daemon. Use the daemon's
copied pack configs. Do not connect to the live server.

```powershell
tests\bench\gateB.ps1 -RunId <id> -Output <raw>\gateB\setup
tests\bench\world.ps1 -RunId <id> -Output <raw>\gateB\world
tests\bench\capture.ps1 -RunId <id> -Output <raw>\gateB\capture -TestRoot <private-client-root>
```

`gateB.ps1` installs seven disks and builds the scene. It starts one computer
and six real turtles, with no GPS hosts. Initial crypto, A*, randomness and
storage probes run from `startup.lua`. `world.ps1` measures movement, charging,
five Turtlematic upgrades, analog redstone, game time, modem reach and a chunk
unload followed by reload.

`capture.ps1` takes the shared client lock after building the monitor scene.
The real client measures the detector at known positions and rotations, then
captures each result with F2. It compares AR lines and text with and without
a stone wall. Its video retains the capture times of F2 frames during ten
physical turtle moves.

Use a fresh disposable run for a full rerun. Named result files persist.
`Invoke-P0Probe` waits for a named result, so reusing a name could read an older
result. Archive the old result before a deliberate retry. Command upload
requires a matching readback before the ready marker is written.

Save the final computer disks, `jar-sha256.txt`, the daemon's `rcon.txt`, and
`logs/latest.log`. Keep failed attempts. Inspect the F2 images before writing
the visual verdict. Delete the disposable run after saving its evidence.
Never copy client argument files, `server.properties`, daemon credentials or
`token.txt` into the public evidence.

`summarize.py` collects the P0 evidence layout and checks exact counts. It
requires an explicit visual verdict and a video before it can mark Gate B
complete. The JSON files retain raw timings and probe errors.

```powershell
C:\Tools\python\cpython-3.12.15-windows-x86_64-none\python.exe tests\bench\summarize.py --raw <raw> --sandbox <sandbox-run> --server <saved-server> --world <world-probe-output> --run-id <id> --output docs\evidence\p0
```

The saved server directory must contain `computer`, `logs`, `config`,
`rcon.txt` and `jar-sha256.txt`. The world output supplies the before and after
chunk-reload records. `gateB/capture/visual-verdict.json` needs `complete=true`
only after a reviewer verifies the actual images. Missing required results,
incorrect counts or missing client evidence keep Gate B failed.
