# Gate B driver

Run from the repository root with Python 3. The runtime from `codex/gateb-runtime`
provides `tools/gateb/world.py` and its API v1. Until it lands, pass
`--runtime-dir /path/to/runtime-checkout/tools/gateb`. No third-party Python
package is required. Pixel comparisons use ImageMagick.

```sh
python3 tools/gateb/run.py --full FULL_SHA --worlds 2
python3 tools/gateb/run.py --changed BASE..SHA
python3 tools/gateb/run.py --checks C3,C5 --sha FULL_SHA --worlds 1
python3 tools/gateb/run.py --changed BASE..SHA --checks C13 --plan
python3 tools/gateb/run.py --checks C5,C7 --sha CLOCK_BUILD_SHA --tick-rate 80
python3 -m unittest discover -s tools/gateb/tests -v
```

Results go to `~/work/gateb-driver/<timestamp>-<sha>/`. Each check saves its own
samples, observations and `C<number>-result.json`. The merged `report.md` and
`report.json` credit only the selected checks on that exact commit. Missing
results become blocked. Evidence from different commits cannot be merged.
Exit status is 0 for a passing run or no affected checks, 1 for failed or blocked
checks, and 2 for invalid arguments or unavailable runtime setup. A report with
no selected checks has status `not_run`.

The runner creates private named worlds and stops them in `finally`. It resets
each world to the native template before each check and verifies the installed
commit before acting. Groups share a worker queue across the requested worlds.
Mining runs C5, C7, C8 and C10. Screens run C1 through C4 and C14. Services run
C6, C12 and C13. Lifecycle runs C9 and C11. Client work is serialized; only C3 and
C13 start a client. Runtime admission and the shared test lock remain authoritative.
No command connects to a remote Minecraft server.

Changed-file selection follows the task's module mapping. Unknown Lua production
files select all checks because shared storage, protocol and geometry can affect
any role. Documentation, tests and tooling alone select none. Renames include
both their removed and added paths. Explicit checks add to the changed selection.

Only C5, C6, C7 and C8 use the requested tick rate. C9, C10, C11 and C14 stay at
20 TPS, as do the remaining checks. Speed changes require the requested commit
to wire `SO.now` to `store.clock`, plus a running server exposing that function.
C7 measures elapsed tick-clock time, never Minecraft calendar time or nominal
wall time multiplied by requested TPS. The runner restores 20 TPS after a check.
The 7.5-minute C7 duration at 80 TPS is a target, not a measured result.

## Fixtures and evidence

Computer names and native poses come from the runtime manifest. Mining and farm
geometry may be top-level `mine` and `farm` entries. Physical chests are named
`ore`, `fuel`, `wood`, `saplings`, `storage_output` and `storage_stock` under
`fixtures`. The farm's `dig_cells` must list every native stem and canopy cell.
Any successful dig outside those cells fails C6. The driver configures real drop
points through the public module API and checks native poses before every add.
C7 uses a native low-fuel fixture to exercise a real fuel trip. C8 fills the real
ore chest, then resets its private world for the separate native low-fuel case.
No conditional planner branch is forced.

C1 requires ordinary HTTP installation evidence on all six roles. Minecraft
pockets require a connected player. When C1 and C3 are selected together, C3 runs
C1 while its photo client is connected, saving a separate C1 result. C1 alone
reports blocked if the runtime cannot provide six-role installation evidence
without starting another client.
File-copy preparation never counts as a normal HTTP installation.

C3 reads actual received button rectangles and injects native mouse or monitor
input. Successful queuing alone never establishes navigation success. Optional
`client_views.wall` and `client_views.pocket` console commands place the client
for native photos. `visual_baselines` maps screenshot names to reviewed external
references with `path`, `sha256`, and `regions` of `[width,height,x,y]`. Regions
must exclude changing clocks or world animation. Exact pixels must match.
Missing references block visual claims. Large images stay outside git.

C13 additionally needs `fixtures.goggles` with `linked_player_in_template`,
`verify_command`, and `expected_turtles`. The native verification command must
emit `GATEB_GOGGLES_LINKED` only when the player wears goggles linked to the test
controller. References must cover label alignment, overlap, HUD, layer removal
and stable frames. The driver never equates taking a screenshot with passing a
visual check.

C11 disables the runtime bridge helpers, clears queued inputs through that API,
removes force loads, and checks native chunk-load state before its full 120-second
window. Observation then reads disk state only. Return restores chunk loading
without enabling helpers, rebooting computers or sending job input. Only changed
x/y/z counts as resumed movement. Turns do not count.

C14 starts a real HTTP update asynchronously, observes staging, and uses the
runtime's native terminate delivery to interrupt that updater. It verifies old
files and pairing integrity, reboots, completes a normal update and compares the
installed hashes against the requested commit. If the updater finishes before
staging can be interrupted, the check is blocked. Pairing values never enter
saved evidence; integrity evidence contains only comparison outcomes.

## Test fixtures

Small extracts under `tests/fixtures` come from the saved 0f73a4e Gate B run.
Each extract names its source and original commit. These are regression inputs,
not Gate B evidence for the driver or a newer build. Synthetic samples test
specific failures, including late lane grants, input replay, turns without
movement, incomplete recovery and missing visual proof.
