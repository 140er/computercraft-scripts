# Add here and disk pressure evidence

The `w1-*.txt` captures beside this file are mock frames at 26x20 and 29x12.
They show mining setup, lumber setup, the drop draft and the disk ledger.
They are not Minecraft screenshots.

The behavioral suite is `tests/so/w1-addhere-disk.lua`. It uses the real worker,
server modules and display client on separate mock computers. It presses drawn
controls and covers GPS facing, explicit worker dimensions, lost probes,
reservation handoff and assignment save failures, drop coordinates, pressure
entry and exit, event retry, bounded refusal, AR persistence and KEEP consent.
`tests/so/store-recover.lua` also checks partial writes and ordered queue recovery.

Run the focused suite with:

```sh
cc-test --part tests/so/w1-addhere-disk.lua --lua-only --part-timeout 90
```

The local Linux UI and recovery pass completed with 104 tests passed and zero
failures. It includes UI0 and has no skipped checks. The mockup generator and UTC
allow-list checks passed. Luacheck reported zero errors. The final full-suite
result and head SHA are in the PR description.

Gate B requires the orchestrator's test Minecraft server. This task did not
start Minecraft or contact the live server. Affected checks are C4, C5, C6, C9
and C10. The standalone CraftOS-PC screenshot scripts were not run. Mock frames
and the scheduled full Lua plus pack-ROM emulator gate do not prove real-game
behavior.

GPS supplies no dimension. Automatic add and FROM require a matching dimension
from the turtle's explicit `so-worker.cfg`. The volatile event queue can lose
pending events if power fails before disk space is freed and retry succeeds.
