# Fleet verification record

Gate A mock suite and the CraftOS fleet scenario passed on Linux. Gate B was not run. Mock checks do not replace a Minecraft run.

Raw evidence belongs under `C:\Work\gemini-input\p3\evidence\fleet\`. Failed runs stay there. The required hardening merge needs a passing summary for at least H12. The branch has no replacement authentication implementation while that dependency is pending.

| Check | State | Evidence |
| --- | --- | --- |
| Contract3 base merge and normal push | Ran | cd3f958 |
| Program standalone startup and live native-call controls | Mock passed | tests/wh2-fleet-program.lua |
| Four nav headings and top and bottom access | Mock passed | tests/wh2-fleet-adapters.lua |
| Relative frames excluded from world AR markers | Mock passed | tests/wh2-fleet-adapters.lua |
| Full mock suite | PASS | lua5.2 tests/run.lua, 144 tests, 0 failures |
| CraftOS fleet scenario with three turtles, one operator, and 1 MB disks | PASS | tests/sandbox/run.ps1 -Scenario fleet |
| Headless UI captures | NOT RUN | gateA |
| Miner server-known drop-off with exact counts | NOT RUN | gateB |
| Live global, role, and computer settings, override removal, and thresholds | NOT RUN | gateB |
| Restart preserves settings | NOT RUN | gateB |
| Shared positions on real AR glasses | NOT RUN | gateB |
| Full drop-off box and no turtle fuel | NOT RUN | gateB |
| Turtle and chunk unload | NOT RUN | gateB |
| Charger power loss | NOT RUN | gateB |
| Two turtles approach one service spot | NOT RUN | gateB |
| Replay, spoofing, huge counters, and downgrade attempts | NOT RUN | gateB |
| Crash after outbox save, transmit, and commit | NOT RUN | gateB |
| Disk limits, allocation, save failure, and control reserve | NOT RUN | gateB |
| Event bursts during save and HTTP, with surviving timers | NOT RUN | gateB |
| Lost commit, GPS loss, modem removal, and full disk mid-move | NOT RUN | gateB |
| Validator fuzzing | NOT RUN | gateA |
| Version skew and interrupted update rollback | NOT RUN | gateB |
| Two-hour soak with four turtles | NOT RUN | gateB |
| Real room and board screenshots and a video under 10 MB | NOT RUN | gateB |

Sorting, smelting, crafting, wizard answers, and layout upload cases belong to their feature owners. Their applicability must be recorded against every item in `docs/testing/gateB-depth.md` before the final verdict. A pending or skipped applicable item prevents a passing verdict.
