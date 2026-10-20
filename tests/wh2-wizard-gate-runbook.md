# Run the wizard scenarios

Run these commands from `C:\Work\cc-wh2-wizard` on `feat/wh2-wizard`.
The preparation command copies test disks and writes scene commands. It starts no Java process or client.

```powershell
powershell -NoProfile -File tests/wh2-wizard-gate-verify.ps1 -MockSuite
powershell -NoProfile -File tests/ingame/wh2-wizard.ps1 -Mode Prepare
powershell -NoProfile -File tests/sandbox/wh2-wizard.ps1 -PrepareOnly
```

The data shapes are a JSON plan, one config per computer, a command with a unique
`nonce`, a matching result, and append-only observations in `wizard-events.jsonl`.
The shared Lua runtime owns board checks and the native turtle transfer adapter.
PowerShell owns scene changes, process restart barriers, exact physical counts,
and the soak clock. File and RCON adapters use the same driver on both hosts.

Each turtle input contains eight item IDs. Separate fixture barrels hold 37
stone in each room. Their counts are saved independently of the routing loads.
The two unknown IDs are
`superbwarfare:galena_ore`, 64 per turtle, and `superbwarfare:silver_ore`, 19 per turtle.
The recipe dump at `C:\Work\recipe-data\recipes\recipes_lua\superbwarfare.lua`
lists both IDs. Preparation verifies both item model entries in the local
Superb Warfare jar and saves its SHA-256. Runtime still needs that jar on the disposable server.

The runtime requires `wh2-wizard-gate-bindings.lua`. Supply its path through
`-Bindings`. Its `open(config)` returns these fields:

| Field | Requirement |
| --- | --- |
| `authenticated` | `true` only when the real HMAC transport and pairing are active. |
| `client` | The real shared `wh2-client` with queued `call(op, body)`. Each reply has `ok`, and failures have `code`. |
| `receiver` | The real authenticated receiver and outbound worker loop. It must keep client calls alive. |
| `server` | The real SSOT dispatcher loop on computer 0. Only SSOT saves wizard state. |
| `boardTerm` | A real monitor in Gate B, or an emulator monitor in Gate A, at least 26 columns and 20 rows. |
| `metrics` | Server measurements with actual save duration in milliseconds and save timestamp. Do not substitute a constant. |
| `boundary(case, evidence)` | Fleet or layout checks that the wizard cannot perform by itself. Missing support raises an error. |

Do not implement this binding with a raw `rednet.send`, secret-bearing v1
packets, direct calls to `wh2-wizard.run`, or another shared-state file.
The in-process self-check calls the module directly and proves only the test
assertions and real board controls. It is not Gate A or Gate B evidence.

The lead must integrate `wh2-wizard` in `tests/sandbox/run.ps1`. Keep its real
`computerSpaceLimit=1000000`. Stage computers 0 through 6, the root Lua files,
the two gate Lua modules, configs from preparation, and the binding supplied by
`WH2_WIZARD_GATE_BINDINGS`. Use `tests/sandbox/wh2-wizard-driver.lua` as startup.
Use the staged module inventory instead of copying every root Lua file. It leaves
space for persistent state under the 1 MB limit. Create four emulator turtles
with actual persistent test inventories and a monitor.
Dispatch the scenario's command and result files through the same host driver.
The default driver never emits a successful `sandbox-result.json`. The lead's
runner must review required observations and write its verdict after the reboot
and process-restart barriers. Do not treat the service's continued execution as a pass.

For Gate B, create a fresh disposable run with `-SpaceLimit 1000000`. Start it
only when the lead is ready. Then run:

```powershell
powershell -NoProfile -File tests/ingame/wh2-wizard.ps1 -Mode Run -HostKind Box -RunId <disposable-id> -Bindings <binding-path>
```

For a local server, pass `-HostKind Local`, its fresh `-TestRoot`, and the owning
runner's loopback RCON and process restart scriptblocks. Hold the existing server
lock. The script accepts only `C:\Work\mc-wh2-wizard-*` roots bound to loopback.
It starts no local Java process. The box adapter restarts only the named disposable run.

The full-chest scene archives existing output, fills all 27 destination slots,
and retries after moving that chest intact into the archive. The no-fuel scene
sets one real turtle to zero fuel and leaves a real furnace without fuel.
The removed-machine scene fuels that furnace and breaks it after the boundary
starts its job. The boundary must collect and count the real dropped stacks.
The modem scene removes the board modem and then restores it.
The boundary must observe each blocked condition and retain the authoritative question and inventory counts.

Computers 5 and 6 submit independent authenticated operator requests at the same
revision. The host requires one winner and one stale loser. The loser refetches
before retrying its answer.
The `stale` check alone sends sequential requests and does not claim concurrency.
The `authentication` boundary covers replay, fake discovery, sender forgery,
unpaired senders, and huge counters. `event-bursts` uses real saves and an HTTP wait.
`unload` removes the relevant forceload ticket and observes stopped progress
before reload. `updates` requires the hardening owner's skew and rollback checks.
Adapters may cover absent fleet, layout, and craft boundaries in Gate A.
Gate B still requires real inventory and world observations for applicable cases.

During the soak, each of four turtles routes another physical modded load every
sample interval. Filled output chests move intact to archive coordinates. Count
files include those archives. Keep at least 7,200 seconds of samples, with native
disk capacity, free space, state bytes, actual save durations, and inventory totals.
The component-free test load permits the RCON count parser. A component-bearing
stack fails parsing and needs the native inventory API instead.

Neither preparation nor the runtime script writes `GATES: PASS`. The runtime
finishes with `awaiting-evidence-review`. The lead supplies F2 room, board, and
wizard shots and a real video under `Enter-GatebClientLock` later.
An absent mandatory observation, binding, integrated runner, or capture blocks the gate.

The feature checkpoint follows the assigned scope:

- Blocking first steps are the contract, real board API, local item IDs, and authenticated transport prerequisites.
- Independent workstreams are server state, board UI, and these test files. This worker writes only the test files and initial evidence inventory.
- SSOT owns shared mutable state. Each computer writes its own observations. Each attempt has a separate output directory.
- One worker owns the shared driver and both host adapters because their command shapes must agree. The user forbids nested agents.

The selected design uses one driver with host file and RCON operations. Separate
Gate A and Gate B scripts with copied assertions would let acceptance rules drift.
Model the Domain selected the plan and command shapes. Build the Lever selected
repeatable scene preparation and exact-count scripts. Test Behavior, Not
Implementation selected real board events and physical inventory totals.
The user forbids delegation and Git writes for this work item. PR work is outside
this assigned test scope.

The owned files are:

- `tests/wh2-wizard-gate-plan.json` defines inputs and applicability.
- `tests/wh2-wizard-gate-checks.lua` drives board controls, stale answers, and fuzz assertions.
- `tests/wh2-wizard-gate-runtime.lua` runs authenticated computer services and records observations.
- `tests/wh2-wizard-gate-host.ps1` parses exact native inventory counts.
- `tests/wh2-wizard-gate-selfcheck.lua` checks the scenario against the real wizard and board modules in process.
- `tests/wh2-wizard-gate-verify.ps1` checks syntax, the manifest, the inventory parser, and the in-process scenario.
- `tests/wh2-wizard-gate-runbook.md` records commands and integration requirements.
- `tests/sandbox/wh2-wizard-driver.lua` starts each computer's service and records failures.
- `tests/sandbox/wh2-wizard.ps1` prepares Gate A and calls the lead's shared runner.
- `tests/ingame/wh2-wizard.ps1` prepares the physical scene and drives box or local scenarios.
- `docs/evidence/wizard/README.md` holds the initial requirements inventory without a gate verdict.
