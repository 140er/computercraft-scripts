# Fleet verification record

Both gates remain pending. Mock checks do not replace a CraftOS or Minecraft run.

Raw evidence belongs under `C:\Work\gemini-input\p3\evidence\fleet\`. Failed runs stay there. The required hardening merge needs a passing summary for at least H12. The branch has no replacement authentication implementation while that dependency is pending.

| Check | State | Evidence |
| --- | --- | --- |
| Contract3 base merge and normal push | Ran | cd3f958 |
| Program standalone startup and live native-call controls | Mock passed | tests/wh2-fleet-program.lua |
| Four nav headings and top and bottom access | Mock passed | tests/wh2-fleet-adapters.lua |
| Relative frames excluded from world AR markers | Mock passed | tests/wh2-fleet-adapters.lua |
| Full mock suite | Running | mock-pickup.txt |
| CraftOS with several turtles and 1 MB disks | Pending | gateA |
| Headless UI captures | Pending | gateA |
| Miner server-known drop-off with exact counts | Pending | gateB |
| Live global, role, and computer settings, override removal, and thresholds | Pending | gateB |
| Restart preserves settings | Pending | gateB |
| Shared positions on real AR glasses | Pending | gateB |
| Full drop-off box and no turtle fuel | Pending | gateB |
| Turtle and chunk unload | Pending | gateB |
| Charger power loss | Pending | gateB |
| Two turtles approach one service spot | Pending | gateB |
| Replay, spoofing, huge counters, and downgrade attempts | Pending | gateB |
| Crash after outbox save, transmit, and commit | Pending | gateB |
| Disk limits, allocation, save failure, and control reserve | Pending | gateB |
| Event bursts during save and HTTP, with surviving timers | Pending | gateB |
| Lost commit, GPS loss, modem removal, and full disk mid-move | Pending | gateB |
| Validator fuzzing | Pending | gateA |
| Version skew and interrupted update rollback | Pending | gateB |
| Two-hour soak with four turtles | Pending | gateB |
| Real room and board screenshots and a video under 10 MB | Pending | gateB |

Sorting, smelting, crafting, wizard answers, and layout upload cases belong to their feature owners. Their applicability must be recorded against every item in `docs/testing/gateB-depth.md` before the final verdict. A pending or skipped applicable item prevents a passing verdict.
