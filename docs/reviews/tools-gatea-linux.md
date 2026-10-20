# Review notes for tools/gatea-linux

Reviewed `main` at `ece242a` and `origin/feat/wh2-base` at `9d14824`. Runtime Lua on `main` was not changed. Open issues 32 through 40 already record the secret-on-the-wire path, the poisoned save, the delete-then-move savers, and the missing chunk ticket. Those are not repeated here.

## 1. High. An expired turtle is both still in the world and free to assign

`docs/plans/cc-h4-offline-plan.md:7` on `feat/wh2-base` says unknown is never free. `docs/plans/cc-h4-offline-plan.md:311` tells Gate A to pass when a turtle killed mid-move has its cells free after expiry. `docs/plans/cc-h4-offline-plan.md:312` says the same for Gate B.

`docs/design/wh2-contract.md:430` says an expired pose becomes unknown occupancy and route planning cannot treat it as observed air. `docs/design/wh2-contract.md:568` says lease expiry frees scheduling claims and physical occupancy stays unknown until an observation clears it. `docs/design/miner-autonomy.md:71` and `docs/design/miner-autonomy.md:78` say the server frees the cells. `docs/design/miner-autonomy.md:15` says an unloaded turtle freezes in place and comes back without GPS.

A second turtle sent into those cells meets the frozen turtle. The written Gate A cannot pass if the cells stay unknown, and the safety rule cannot hold if the cells become free. Filed as https://github.com/140er/computercraft-scripts/issues/45.

`docs/design/wh2-contract.md:5` says the plan wins where it differs from the notes. `docs/design/wh2-contract.md:521` says `docs/design/miner-autonomy.md` is the specification. `docs/design/h4-offline-contract.md` is the file named as the frozen shape, and it is absent on `origin/feat/wh2-base`.

The same pair disagrees about digging while lost. `docs/design/miner-autonomy.md:54` allows dead reckoning when GPS is gone. `docs/design/wh2-contract.md:523` forbids digging until the pose and heading are re-anchored. `docs/plans/cc-h4-offline-plan.md:7` forbids digging without a proved position.

## 2. Medium. A standards-mode yield abort poisons the map during the volume scan

CraftOS-PC 2.8.3 with `standardsMode` true aborts a computer that does not yield. Setting `abortTimeout` to 120000 does not extend that budget. The same busy loop with `standardsMode` false and `abortTimeout` 120000 ran 25 seconds without the abort. `config.get("abortTimeout")` still prints 17000 when the key is omitted and 120000 when it is set, so the key is stored and then ignored under standards mode.

Three `-Scenario nav` runs failed in the 10000-cell scan with `SSOT timeout (stopped)`. One server terminal ended at `/rom/apis/rednet.lua:470: Too long without yielding`. A temporary log around `server.lua` `ssot.handle`, not kept in this branch, recorded one scan at 7062 ms that returned `ok=nil` and `/atomic.lua:52: Too long without yielding`. The next scans returned in 0 ms with `ok=nil`. `atomic.lua:65` sets `poisoned` when `save` throws, and `ssot.lua:256` then refuses later mutations. That is the same silence as issue 33, triggered here by the yield abort rather than a full disk.

A one-computer bench copied a 3432-cell `ssot.state` from an earlier run in 2 ms and serialized it in 5 ms. The 7 second abort happens with the fleet loaded, not on that copy alone. GitHub Actions run 39459767437 on `ubuntu-latest` failed the same scan. The controller error was `SSOT timeout (stopped)` at `tests/ssot-runtime.lua:388`. Smoke and the mock suite passed on that run. Filed as https://github.com/140er/computercraft-scripts/issues/58.

## 3. Low. Gate A still boots the fleet at 4000000 bytes

`tests/sandbox/run.ps1` writes `computerSpaceLimit = 4000000`. `tests/sandbox/driver.lua:28` requires that capacity. The small-disk case that does run is the mock in `tests/ssot-storage.lua:54`, loaded by the ssot and nav scenarios. A 1000000-byte computer with the current root mirror is the case in issue 33. This branch does not add a second CraftOS scenario for it.
