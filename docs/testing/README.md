# Server-only test kit

This kit targets frozen server-only commit `0f73a4e`. Product code is unchanged.

```sh
python3 tools/install-test-parts.py
cc-test --part server
cc-test --part miner
cc-test --part so-mine-plan.lua --lua-only
cc-test --part tests/so/lease.lua --lua-only
cc-test
```

The focused mining fixture loads the real mining module, its planner libraries
and UI library with store/lease/cell mocks. Its seven checks cover start guards,
uncertain workers, range refusal, exactly-once branch counting, disk failure,
retirement protection and report expiry. The broader mining regressions remain
explicit parts and run in the full suite.

The first two commands default to Lua regressions plus the version-checked
emulator layer. `--lua-only` is an explicit unit-test shortcut. Plain `cc-test`
remains the full regression suite and must pass once before a PR. The
orchestrator decides when to run real-server/gameplay tests.

`server`/`server.lua` and `miner`/`miner.lua` are server-only aliases for
`so-server.lua` and `so-mod-mine.lua`. Normal-build work comes later.
A root module first selects its dedicated `tests/parts/<module>.lua` suite
when present. Next it prefers suites whose product-file dependency closure
is contained in the module closure. Otherwise it selects matching filename words
and a source dependency on the module or its libraries. If there are none, it selects related
non-scenario regressions. The command prints exactly which suites it chose.
Run `scripts/test-part --list` to see module-to-suite selection, or
`python3 tools/test_parts.py --dependencies miner` to inspect generated inputs.
Choose an explicit test file to narrow a large module part further.
Numbered SO/UI scenarios remain explicit parts and run in the full suite;
focused module parts do not replace them. A module with no regression fails
rather than claiming coverage. A targeted module part must execute its source
chunk through the guarded loaders; merely reading its text does not count.
This check confirms execution, not complete behavioral or line coverage.

## Dependency enforcement and parallel runs

`tools/test_parts.py` builds a graph from Lua source strings: literal
`require`, `dofile`, `loadfile`, source reads and fake-computer installation
lists. It resolves crypto library paths assembled from a literal prefix,
finite name list and `.lua` suffix. Embedded Lua program strings contribute
edges too. No handwritten per-module dependency manifests are maintained.
`require` resolves both `?.lua` and `lib/?.lua`, matching the runner.
Static strings can conservatively include a file not reached by a particular
test branch; the kit never executes such a file just to discover dependencies.
Arbitrary computed paths are not inferred. They fail at runtime if missing
from the generated closure.

Each run copies only its closure into a unique temporary directory. The
generated `tests/part-manifest.lua` lists every permitted input. Guarded
`io.open`, `loadfile`, `dofile` and `require` reject undeclared inputs; even a
swallowed loader error fails the final result. Host writes, deletes and child
processes are forbidden. Fake machine disks, clocks, networks and turtle worlds
remain in memory, with no shared ports or state. This is dependency checking
for trusted repository tests, not a security sandbox against hostile Lua.

The installed `cc-test` still chooses the first free local, Windows or PC slot.
The repository installer backs up the scheduler to `cc-test.bak-parts` and
refuses unfamiliar patch locations. Both remote transports receive the same
minimal staged archive. Tests execute `tests/run.lua` inside that archive,
which contains the part runner rather than the full suite.
Part Lua CPU time is limited to 60 seconds by default; local wall time has the
same limit. Remote workers also retain their 20-minute outer wall deadline.
Use `--part-timeout 180` only for an intentionally longer scenario.
The slot lock covers the emulator and Lua work together. The full runner in
the checkout is unchanged. The remote infrastructure's baseline repository
contains only a placeholder; part tests cannot access it.

Run `python3 tools/test-parts-selftest.py` to check graph closure, omitted
inputs, simultaneous private runs and a swallowed undeclared-load failure.

## Emulator versions and peripherals

See [CraftOS-PC evaluation](craftos-pc.md) for extracted modpack versions,
source references, installed binaries, mismatch handling and peripheral APIs.
The pack pins Minecraft **1.21.1** and CC:Tweaked **1.120.2**.
The default emulator layer loads the pack jar's own ROM, checks its 1.120.2
version text, validates the jar hash and verifies every extracted file.
CraftOS-PC **2.8.3** retains a **1.112.0 native core**. The ROM swap covers
Lua-side code; it does not replace native filesystem, peripheral or turtle
implementations. The evaluation records those differences and the mocks/shims
used by server-only tests. A mismatched jar, ROM version or emulator fails;
there is no automatic Lua-only fallback. No successful Lua-only
result proves CC:Tweaked or add-on integration compatibility.

## Formal verification

See [the formal verification report](formal-lease-orderings.md) and the project-local
`verify-*` skill for the bounded model, source links and rerun command.
Findings do not authorize product changes.

## Measured timings

Uncontended runs on t3code-home, with default parts including CraftOS-PC:

| Command | Checks | Wall time |
| --- | ---: | ---: |
| `cc-test` at the frozen base, Windows slot | 536 | 332.46 s |
| `cc-test` with the new mining unit checks, Windows slot | 543 | 373.07 s |
| `cc-test --part server` | emulator + 8 Lua checks | 10.30 s |
| `cc-test --part miner` | emulator + 7 Lua checks | 9.50 s |
| `cc-test --part server --lua-only` | 8 | 0.91 s |
| `cc-test --part miner --lua-only` | 7 | 0.21 s |
| `cc-test --part so-mine-plan.lua --lua-only` | 8 | 0.13 s |
| `cc-test --part so-mod-daily.lua --lua-only` | 7 | 0.18 s |
| `cc-test --part so-mod-panel.lua --lua-only` | 14 | 0.44 s |

The shared emulator integration takes about 9.3 seconds on Linux and 14.45
seconds on Windows. Daily/panel timings above are the initial uncontended
runs; final repetitions passed on Windows and under slot contention too. The focused mining
fixture stages six inputs; server stages 21. Before the focused fixture,
mining's broader regressions took 17.28 seconds for 19 checks and 40 inputs.
Those regressions remain in the full suite and available by test-file name.
The Windows part transport passed seven mining checks in 9.291 seconds,
including upload and worker startup. Concurrent server and mining CLI runs
passed on separate slots with separate staging directories.

These are wall times, including command startup. The full-suite Windows
measurements also include archive upload. Slot contention can add queue time;
other saved runs waited 180 seconds. Lua CPU and local execution times are
printed separately so queue delays are visible.

## Saved evidence

Timing and validation logs live under `tests/evidence/testkit/`. Queue time and
transport startup are distinct from Lua CPU time. The full suite covers the
normal-build regressions as well as server-only; focused aliases do not load
normal-build programs. Real-server Gate B is reserved for the orchestrator.

## Full gate and merge checks

Install the scheduler adapter after updating this checkout:

```sh
python3 tools/install-test-parts.py
cc-test
cc-test --shards 4
lua5.2 tools/luacheck.lua
```

Plain `cc-test` runs all checks sequentially. `--shards N` runs the same checks
through N independent scheduler clients, each taking the next free slot.
No slot is reserved while waiting for another shard. Each shard has the existing
20-minute execution deadline. The command fails if any shard fails, times out,
or lacks its completion summary. It saves each shard log and a combined JSON
result in the printed directory. Queue and transport time count toward the
reported wall time. Use fewer shards when fewer slots are free. Older checkouts without these
files keep their original sequential runner after adapter installation.

CI uses `scripts/test-suite --shards 4` on Linux, with the same Lua runner but
without the lab slot scheduler. The final summary includes passed, failed and
skipped counts and the names and reasons of skipped checks. CI also requires a separate Linux UI0 generator comparison with no skips.

`tests/run.lua` remains append-only. The full runner stages a copy as
`tests/full.lua` and substitutes its local test callback at one checked marker.
It preserves test registration order and discovers new suite files from the
canonical runner. A missing or ambiguous callback marker fails the gate.
Whole files form shard groups, except SO11's two recovery scenarios. Each SO11
scenario initializes lazily inside its first selected assertion, once per
scenario, so shards do not repeat it. `tests/suite-costs.lua` holds measured
Linux CPU costs; greedy allocation balances these groups for any shard count.
New groups default to one second and still run. `CHECK-TIME` and `FILE-TIME`
lines report Lua CPU seconds; the outer command reports wall seconds.

The merge gate requires the full suite, luacheck global checks, Lua 5.2 syntax,
Cobalt local limits and the append-only scope check. Luacheck v1.2.0 is pinned
under `tools/vendor/luacheck`, including its license. It needs only Lua 5.2,
with no root install, network access or native modules. The checked files are
`so-*.lua`, `worker.lua` and `display.lua`; legacy normal-build files and vendored
crypto code are outside this server-only gate. Extra file arguments check
scratch code with the same config.

Undefined reads, accidental global writes, writes to read-only globals, syntax
errors, unused locals and unused arguments all fail lint. CC globals
and `SO` are declared explicitly; `SO.mods` module fields remain extensible.
Only the boot wrappers that replace `print`, `package` and `require` receive
file-specific write permissions. No blanket global suppression is used.
Run `python3 tools/suite-selftest.py` for shard coverage, skips, failure
propagation and scratch global defects. Gate B gameplay remains the
orchestrator's decision during the server-only freeze.

The Linux profile at `4b6ba5b` passed 617 checks in 348.57 wall seconds.
The final sequential run passed the same 617 checks in 351.87 seconds.
The largest measured groups were:

| Group | Lua CPU seconds |
| --- | ---: |
| Mining, `so3.lua` | 62.47 |
| SO11 B recovery | 56.81 |
| Range regressions | 47.86 |
| SO1 persistence | 42.64 |
| SO11 A recovery | 31.34 |

Complete per-file/check timings and gate logs are saved under
`tests/evidence/suite-speed/`. The profile includes test-body CPU time;
loading and scheduler overhead are included only in the wall measurement.

The measured `cc-test --shards 4` gate passed all 617 checks in 361.46 wall
seconds. Only local-2 was initially free. Shards 1, 4 and 2 used it in turn;
shard 3 eventually acquired Windows after waiting. This contended run did not
reduce wall time relative to the 348.57-second baseline. It proves scheduler
and Windows transport coverage, with identical check identities across all
runs. Repeat the benchmark with several free slots to measure the parallel
reduction. The measured CPU costs allocate about 86 seconds to each of four
shards before queue, platform and transport effects.

## Changed-file iteration

Reinstall the adapter with `python3 tools/install-test-parts.py` after pulling
these tools. Then run:

```sh
cc-test --changed
cc-test --changed origin/server-only --lua-only
cc-test --changed HEAD --part-timeout 30
```

`--changed [BASE]` compares the merge base of BASE and HEAD with the working
copy. It includes staged, unstaged and untracked files. BASE defaults to
`origin/server-only`. Root Lua modules use the same focused selection as
`--part`; individual suite changes run that suite. This is an iteration shortcut.
It does not replace the final full gate. Deleted modules, shared test helpers,
UI documentation, tooling and unmapped inputs fall back to the full gate.
Ordinary Markdown changes and saved evidence need no Lua parts. A bad base
revision fails the command. An empty selection is printed explicitly.

Each focused suite prints `PART-CPU` in Lua CPU seconds. Changed-file runs print
`PART-TIME` per scheduled part in wall seconds, including queue and transport.
Full shard runs print the ten slowest parts as `SLOW-PART`, and save all part
CPU totals in `result.json`. SO11 A and B remain separate cost groups.

CI requires UI0's generator comparison on Linux through
`python3 tools/check-ui0.py`. A missing or skipped comparison fails this step,
even when another suite shard runs on Windows. Lint now fails on every reported
warning as well as errors. The eight existing warnings were unused parameters
or overwritten initial values and have been removed without changing behavior.

## Evidence and cost refresh

CI uploads shard logs, `result.json`, generated `suite-costs.lua` and check
outputs as the `server-only-test-evidence` artifact, retained for 30 days.
New files under `tests/evidence/` are ignored except Markdown summaries.
Existing tracked evidence stays available. Keep concise review summaries in
git and link the CI run's artifact for raw logs and captures. Export evidence
that needs to outlive the artifact retention period to durable storage.

Once a week, download a successful Linux CI artifact and review its generated
`shards/suite-costs.lua`. Copy that file to `tests/suite-costs.lua` in a PR to
refresh shard allocation. Failed runs never generate replacement costs. Do not
use Windows or mixed-platform timings for the Linux cost table. Generation runs
on every CI pass, so the weekly refresh needs no profiling run.

## Gate B selection for PRs

List affected checks in the PR using the read-only planner:

```sh
python3 tools/gateb/run.py --changed origin/server-only..HEAD --plan
```

The orchestrator may run the same command without `--plan` to execute the
selected checks on isolated test worlds. PR authors must not start Minecraft
servers themselves. `--checks C3,C13` adds explicit checks to the selection.
C8 and C10 now run three times, with a world reset between attempts. The report
retains every attempt, its metrics and evidence, plus minimum, maximum and
spread of wall time. Mixed outcomes are marked flaky and cannot pass. A blocked
attempt also prevents a passing aggregate. Other checks still run once.
