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
rather than claiming coverage.

## Dependency enforcement and parallel runs

`tools/test_parts.py` builds a graph from Lua source strings: literal
`require`, `dofile`, `loadfile`, source reads and fake-computer installation
lists. It resolves crypto library paths assembled from a literal prefix,
finite name list and `.lua` suffix. Embedded Lua program strings contribute
edges too. No handwritten per-module dependency manifests are maintained.
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
CraftOS-PC **2.8.3** targets CC:Tweaked **1.112.0**, so the default
emulator layer currently refuses to run. An exact compatible release has not
been established. The emulator layer must refuse an unmatched runtime. No successful Lua-only
result proves CC:Tweaked or add-on integration compatibility.

## Formal verification

See [the formal verification report](formal-lease-orderings.md) and the project-local
`verify-*` skill for the bounded model, source links and rerun command.
Findings do not authorize product changes.

## Saved evidence

Timing and validation logs live under `tests/evidence/testkit/`. Queue time and
transport startup are distinct from Lua CPU time. The full suite covers the
normal-build regressions as well as server-only; focused aliases do not load
normal-build programs. Real-server Gate B is reserved for the orchestrator.
