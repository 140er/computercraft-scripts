# Craft Gate A

Recorded on Linux with Lua 5.2.4 and CraftOS-PC v2.8.3 (`standardsMode` true, `computerSpaceLimit` 1000000). The factory program stays on its existing path unless `factory.cfg` sets `wh2.enabled` to true.

## Gate A

`lua5.2 tests/run.lua` exited 0. The log is `gateA-mocks.txt`. The outer suite printed `98 tests passed`. The craft file adds eight checks, all PASS:

- the server flag stays off until `wh2.enabled` is true
- create is idempotent for operators and rejected for everyone else
- plan pages retry and stop at the step and byte caps
- claims, progress, reconcile, expiry, and cancel keep observed totals
- recipe tickets stay bounded and expire without touching jobs
- the planner is deterministic and reports shortages, cycles, and tags
- the worker journals one event id and refuses a move while layout is deferred
- `factory.lua` keeps the legacy program unless `wh2.enabled` is true

`tests/wh2-craft-sandbox.sh` ran one headless computer. Stderr was empty. `gateA-sandbox.json` reports `ok: true`, capacity 1000000, free 868422.

## Gate B

NOT RUN. No local Minecraft server was started. Checklist still open:

- [ ] NOT RUN: request stained glass panes from sand and dye and read the exact pane count from the output chest
- [ ] NOT RUN: three more multi-step crafts that cross the installed mods, including one missing ingredient with a clear shortage
- [ ] NOT RUN: two recipes for one output, and a tag with more than one stocked member, with the selected ids recorded
- [ ] NOT RUN: a chance-only output blocks with `chance_only`, and a cycle reports its path
- [ ] NOT RUN: replay a saved progress event after reboot; produced and delivered stay unchanged
- [ ] NOT RUN: a plan and warehouse load past the old 32-site, 32-order, and 8-line caps, with admitted bytes recorded
- [ ] NOT RUN: server restart mid-craft and mid-smelt
