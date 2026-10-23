# Multi-turtle lumber verification

The change was reviewed for shared claims, chest queue release, per-worker
recovery and delivery accounting. The review found four issues. The fix round
releases unused approaches after expiry while retaining possible occupied cells,
returns saplings after unsuccessful searches, migrates the park-renewal reader,
and reconciles delivery intents with saved event receipts.

`cc-test --part tests/so/lumber-multi.lua --lua-only --part-timeout 120` passed
all eight cases on the Windows slot. They cover two and three workers with
front and down chests, all 16 logs delivered once, all spots replanted, a worker
lost mid-tree, a restart with three active workers, a worker lost in the chest
queue, and a lost delivery report followed by two server restarts. Movement
wrappers reject any attempted entry into another turtle's occupied cell.

The focused lumber unit checks passed, including unsuccessful sapling searches
and delivery receipt replay. UI0 ran on Linux without skips. UI2b checked the
updated fixture, all three turtle rows at 26x20 and 29x12, and drawn navigation
buttons. Park renewal passed at both 1x and 4x. The range regression confirmed
that a supply trip extends its proven range before reserving a distant approach.

The first full run exposed an SO11 diagnostic that read the worker table before
setup, and a single-worker outage timing regression. The diagnostic now guards
that initial sample. A lone worker retains immediate movement follow-ups and
its sapling supply. `cc-test --part tests/so/clock-so11.lua --lua-only
--part-timeout 180` then passed all 18 accelerated integration cases.

The changed production Lua files passed luacheck with zero errors and warnings,
Lua 5.2 parsing, the clock allow-list and cobaltlocals below 185. Gate B tooling
passed 62 driver tests and six cold-farm tests. Those Python tests use saved
fixtures and do not provide in-game evidence.

After the visibility merge, its attention reader also accepts per-worker lumber
holds and alerts. Its focused tests passed, including independent clearing of
two workers' notices.

The final plain `cc-test` result and tested head belong in the PR. Logs are
saved locally under `tests/evidence/w2-lumber-multi/` and in the suite runner's
reported output directory.

No Minecraft server was started. Gate B C6 remains for the orchestrator, with a
two-worker proposal in `tools/gateb/C6-multi.md`. The C4 and C10 frame readers
accept both the new worker rows and existing recordings. W1 readiness and GPS
behavior is retained after rebasing onto bbe6240. Readiness checks all added
workers, GPS add hands its reservation to the selected worker, and chest alerts
retain their cause, point and coordinates.
