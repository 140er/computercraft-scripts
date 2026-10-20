# Run the wizard gates

Run from `C:\Work\cc-wh2-wizard` on `feat/wh2-wizard`.
The requirements are in `docs/testing/gateB-depth.md` and `tests/wh2-wizard-gate-plan.json`.

## Check the code and prepare the scene

```powershell
powershell -NoProfile -File tests/wh2-wizard-gate-verify.ps1 -MockSuite
powershell -NoProfile -File tests/ingame/wh2-wizard.ps1 -Mode Prepare
powershell -NoProfile -File tests/sandbox/wh2-wizard.ps1 -PrepareOnly
```

Preparation starts no Minecraft process. It saves scene commands, item provenance,
per-computer source hashes, allocation estimates, and missing production prerequisites.
Both runners stage the role files in `tests/wh2-wizard-gate-prerequisites.json`
and the gate modules. They omit unrelated root programs.

The default binding reports missing production modules and unavailable runtime
APIs, then fails. It never creates an authenticated test server.
The branch's legacy SSOT transport sends its pairing secret and cannot serve new wh2 operations.
File presence alone cannot replace production authentication or a running dispatcher.

The CraftOS wizard scenario does not use that binding. Computer 0 commits
`wh2-wizard.lua` over rednet. Turtles report real chest contents. Boards drive
`wh2-board.lua`. A passing run is that scenario, not a keyed BLAKE3 session.

The dependencies include the H3 request worker, H1+H2 keyed BLAKE3 transport,
N1 frames, H4 storage, H5 recovery, and the W1 shared client and dispatcher.
The native inventory test adapter also needs the layout job lifecycle for a full gate.
Merge only the dependency branches authorized by the main task. Never rebase or force-push.

## Run Gate A

```powershell
powershell -NoProfile -File tests/sandbox/wh2-wizard.ps1
powershell -NoProfile -File tests/sandbox/run.ps1 -Scenario smoke -DiskLimit 1000000 -Output <raw-output> -DataRoot <unique-data-root>
powershell -NoProfile -File tests/review-capture.ps1 -Scenario wizard -View queue -DiskLimit 1000000 -Output <capture-output> -DataRoot <unique-data-root>
```

The wizard runner creates seven native CraftOS computers, four chest-backed turtle
adapters, and real emulator monitors. Every disk has a native capacity of 1,000,000 bytes.
Linux uses the CraftOS-PC 2.8.3 AppImage in headless mode with SDL dummy drivers.
Each computer saves its boot, capacity, and scenario result.
The production binding still fails closed when a caller asks it for keyed BLAKE3.

The in-process self-check exercises real board controls and the server state module.
It covers drafts, ownership, revisions, malformed bodies, and inventory conservation.
It does not prove authenticated transport or replace either runtime gate.
Headless screenshots are fixtures and cannot replace Minecraft F2 evidence.

## Run Gate B

Read `C:\Work\gemini-input\gateb\README.md`, then dot-source its `gateb.ps1`.
Create a fresh box run with `-SpaceLimit 1000000` and the default 3 GB heap.
The box uses its own admission control. Do not wait for another session's VM server lock.

```powershell
. C:\Work\gemini-input\gateb\gateb.ps1
$run = New-GatebRun -Name 'wizard' -SpaceLimit 1000000
try {
    Start-GatebRun $run.id | Out-Null
    & tests/ingame/wh2-wizard.ps1 -Mode Run -HostKind Box -RunId $run.id
} finally {
    Remove-GatebRun $run.id | Out-Null
}
```

`-Mode Run` rejects missing prerequisites before it starts the scenario.
`-Mode Probe` builds the same physical scene and boots all seven computers despite
missing production modules. It collects native startup failures and counts all eight
item IDs in the real barrels, turtle inventories, and destination chests.
The probe is partial evidence and never returns a passing gate verdict.
Keep its failed attempts.

For a VM-local server, use the same driver with `-HostKind Local`, a fresh
`C:\Work\mc-wh2-wizard-*` root, and the owning runner's loopback RCON and restart scriptblocks.
Hold `gateB.lock` while that server runs. The driver never starts or stops another local Java process.

The scene has three room sizes, a pillar, and an irregular wall.
Every turtle input has full stacks, partial stacks, and eight item IDs.
The unknown IDs are `superbwarfare:galena_ore`, 64 per turtle, and
`superbwarfare:silver_ore`, 19 per turtle. Preparation verifies both models in the real jar.
Headings follow `nav.lua`, with north 0, east 1, south 2, and west 3.
Inventory APIs use slots 1 through 16. RCON and NBT slots start at 0.
Cooking slots are API input 1, fuel 2, output 3, and NBT input 0, fuel 1, output 2.

## Supply the production binding

A production binding must expose the following checked values.

| Field | Required behavior |
| --- | --- |
| `authenticated` | True only after the production handshake verifies the pinned server. |
| `authentication` | Version 2, `mac="blake3-keyed"`, `requireMac=true`, `handshakeVerified=true`, and `serverPinned=true`. |
| `client` | The shared `wh2-client.new` instance with queued `call`, non-yielding `dispatch`, and one outbound worker. Its RPC comes from the authenticated SSOT client. |
| `receiver` | Real receive and outbound loops that keep queued calls alive. |
| `server` | The serialized production SSOT dispatcher on computer 0. It alone commits wizard state. |
| `boardTerm` | A real monitor in Minecraft or an emulator monitor in CraftOS. |
| `authorityBoot` | The actual server boot identity, changed by a server restart. |
| `metrics` | Measured production storage results with `source="production-storage"`, `saveSequence`, `lastSaveMs`, `lastSavedAt`, and `stateBytes`. |
| `boundary` | Real production observations for named failure, auth, event, storage, unload, outbox, and update checks. Missing support fails the check. |

Do not supply direct `wh2-wizard.run` calls, secret-bearing v1 packets, a second state
file, constant save timings, or an authenticated flag inferred from module existence.
The native transfer helper checks physical inventory conservation. It does not implement
production site locks, route jobs, or machine recovery.

## Review the evidence

The driver tests duplicate reports, retained unknown stacks, skip, persisted drafts,
two editor takeovers, board answers, stale writes, and real reboot and restart barriers.
It compares full retained answers and questions, not merely the presence of a class.
Physical cases include full chests, missing fuel, removed machines, and modem loss.
The approved H4 checks and durable outbox crash cases remain required.

The soak lasts at least 7,200 seconds with four active turtles. Each sample adds and
routes another physical unknown load. Output chests move intact into archives, and
count files include those archives. The known mixed items stay constant.
Samples record native capacity, allocated bytes, free space, state size, measured saves,
and exact totals. Evidence stops with an explicit failure before it consumes the control reserve.

Raw evidence belongs under `C:\Work\gemini-input\p3\evidence\wizard\gateA` or `gateB`.
Each attempt has a fresh directory. Box evidence names its run and game port at
100.78.96.94 as disposable. Save `jar-sha256.txt`, both RCON transcripts,
`logs/latest.log`, and all computer disks before removing the run.
Never copy the daemon URL, token, or `token.txt` into the public repository.

Build the scene before taking `gateB-client.lock`. Use `Enter-GatebClientLock`,
`Connect-GatebLocal`, and `tests/ingame/client.ps1` for real F2 room, board, and wizard
shots and a real video. Disconnect and release the client lock afterward.
Another session's Minecraft process must exit before capture can start.

Only final evidence review can mark the gates passed. A skipped applicable item,
an unavailable production binding, a missing F2 shot or clip, or a short soak means `GATES: FAIL`.
