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

The probe expiry regressions start with three earlier journal moves, then probe
to local z=-4. They check stationary expiry after failed mining and lumber
assignment or handoff saves, missing GPS or reports, and successful probes.
A blocked probe remains at z=-3. The worker retains its full move journal through
the lease and beacon timeouts instead of backtracking beyond the reserved area.
Workers without advertised park-batch support refuse the probe without moving.
The focused suite now has 33 cases. Local Lua execution passed all 33. The
bounded lease checker passed 483841 traces and caught all five scratch defects;
its documented fixed-clock restart ID finding remains outside this fix.

Run the focused suite with:

```sh
cc-test --part tests/so/w1-addhere-disk.lua --lua-only --part-timeout 90
```

After rebasing onto `af2e111`, the targeted Linux pass completed with 111 tests
passed and zero failures. It includes UI0, visibility, readiness, continuous
mining, UI screens, storage recovery and GPS/disk checks, with no skipped checks.
The setup captures show the readiness checklist and ADD HERE together. The mockup generator and UTC
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
