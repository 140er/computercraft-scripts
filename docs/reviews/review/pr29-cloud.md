# Review of PR 29

Head is `feat/ssot-pr5` at `f93f7c8`. Base is `main`. This review did not push to that branch.

The scope is `docs/gemini-review.md` lines 169 to 175, plus the Gate A and Gate B lists under that section, `AGENTS.md`, and `docs/testing/gateB-depth.md` on `feat/wh2-base`.

## Acceptance

1. DirectGPU voxel scene on one advanced monitor. Partly met. `directview.lua:70-138` creates a display, loads two cube models and three 2x2 textures, and draws them. No in-game display was completed. `docs/evidence/pr5/gateB-third-attempt.json` has `clientStarted` false. The first two attempt files stop before DirectGPU.

2. The same scene on a multiblock wall. Partly met. `directview.lua:90-92` reads `getDisplayInfo` after creation. Creation still passes 320 and 240 at `directview.lua:71` and `views.cfg.example:12-13`. There is no 3x2 wall result in the branch.

3. Camera, textures, and culling. Partly met. `directview.lua:74-81` calls `setupCamera`, `setBackfaceCulling`, `addAmbientLight`, and `addDirectionalLight`. `directview.lua:99-107` calls `lookAt` and `draw3DModelTextured`. `tests/view-core-checks.lua:32-44` checks argument counts only. Gate B did not draw a frame.

4. Top and side slices. Met for one cell. `view-scene.lua:67-68` filters those modes. `tests/view-core-checks.lua:18-21` round-trips one cell. A full default neighborhood fails in iso. See finding 1.

5. Shared SSOT map. Met for paging, air, and unknown cells. `view-source.lua:16-43` reads snapshot pages. `ssot.lua:194-196` encodes air as false and omits unknown cells. Gate A computer 4 passed `real authenticated scan and snapshot` in `docs/evidence/pr5/gateA.json`.

6. Click movement and manual commands. Partly met. `server.lua:459-479` requires a paired secret, a fresh sequence, and observed air. `miner.lua:2659-2702` requires `viewsControl`, bounds, and a 7-block limit, then walks. Gate A moved three turtles to x=1 with zero collisions in `docs/evidence/pr5/gateA.json`. An iso click on a dense radius-6 map does not select the center cell. See finding 1.

7. Responsive Pro controls. Partly met. The PR changes Tom's button row in `fleetview.lua`. The text UI overlaps below 7 rows. See finding 5. The same overflow already exists on `main` and is proposed separately in PR 38.

8. Warehouse top view on a normal monitor without DirectGPU. Partly met. `views.lua:45` forces top. `hub.lua:1637-1641` closes DirectGPU in warehouse mode. `docs/evidence/pr5/warehouse-normal.png` is a color framebuffer mirror. `docs/evidence/pr5/README.md` says so. Monochrome is missing. See finding 3.

9. Monochrome support. Missing. `views.lua:7` always calls `setTextColor`. `tests/view-ui-checks.lua:6` stubs that call so it cannot throw. `tests/review-capture-views.lua:56` reports `isColor` false and still invokes the real monitor method at line 51.

10. Tom's GPU as a secondary backend. Partly met on this PR. `docs/evidence/pr5/gateB-second-attempt.json` records `tomMonitor` pass after the compact-button change. `hub.lua:1748` still runs that loop unless the startup mode is warehouse.

11. Plain terminal when the GPU peripheral is absent. Met in code. `hub.lua:1642` checks `peripheral.isPresent` before `peripheral.wrap`. The text UI still draws. This run had no DirectGPU peripheral. Headless CraftOS-PC refused monitors with `Monitors are not available in this mode`.

12. Installer roles launch the selected backend. Met for file set and startup text. `install.lua:551-570` appends `view-pro`, `view-warehouse`, and `view-map` after `smartmine`. `tests/view-install-checks.lua` checks that order and the startup line. `update.lua` lists the new modules in `KNOWN`. A later classic `hub install` writes `shell.run("hub")` at `hub.lua:36-39` and does not clear `views.cfg`. An enabled file therefore stays enabled.

13. New runtime behavior defaults off. Met for the views themselves. `views.cfg.example` sets `enabled = false`. `hub.lua:255` builds the view UI only when `enabled == true`. `estop` routing is the exception. See finding 4.

14. Gate A `views` scenario with a server, a hub, and three turtles. Met in the committed evidence. `docs/evidence/pr5/gateA.json` records seven computers, nine moves, and zero collisions at a 4,000,000-byte disk. This Linux run did not repeat `tests/sandbox/run.ps1`. That script starts `CraftOS-PC_console.exe`.

15. Projection and click edges, negative Y, clipping, stale markers, resize, detach, the Pro toggle, loss, reconnect, and bounded pages. Mixed. Negative chunks pass in `tests/view-core-checks.lua:13-16`. The Gate A scan check includes an injected disconnect and a later refresh. `tests/views-runtime.lua:331-335` queues `monitor_resize` and removes the monitor, then records success without an assertion. The sandbox config sets `radius` to 1 at `tests/views-runtime.lua:274`, so the 1024-cell cap is not exercised.

16. The DirectGPU mock checks signatures only. Met. `tests/view-core-checks.lua:32-68`. `docs/ssot-pr5.md` says the mock cannot certify rendering.

17. `hub-pro.png` and `warehouse-normal.png` from CraftOS. Met as committed images. The Pro image shows three fleet rows. The warehouse image shows a top view. Site and turtle labels overlap in that image. See finding 8.

18. Gate B client PNGs, a 3x2 wall, throttle, detach, a real click, and bandwidth. Missing. The three attempt files under `docs/evidence/pr5/` are failures. The branch has no `directgpu-single.png`, `directgpu-wall.png`, `hub-pro-ingame.png`, or `warehouse-normal-ingame.png`.

19. `AGENTS.md` requires Gate A and Gate B before a change is done. Gate B is not a pass. The PR is still draft. That matches the PR text.

20. `docs/testing/gateB-depth.md` on `feat/wh2-base`. Sorting, smelting, crafting, and the wizard do not belong to this view PR. The items that do belong are not met. There is no F2 screenshot. Gate A used a 4,000,000-byte disk (`docs/evidence/pr5/gateA.json` field `diskLimitBytes`). The `recovery` array in that file is empty. View-command rejection tests exist in `tests/server.lua`. No soak run is in the evidence.

## Ranked findings

1. High. The default iso map drops the nearest blocks and a center click selects the wrong cell. `view-scene.lua:70-78` sorts far cells first and then deletes from the end until 1024 remain. `view-source.lua:10` defaults `radius` to 6. `views.cfg.example` uses the same radius. A radius of 6 is 2197 cells. `directview.lua:102` and `view-scene.lua:84` both use that list, so the GPU scene and the GPU pick lose the center. A lua 5.2 probe of a radius-6 iso cloud on a 492x328 frame kept 1024 cells, dropped the center ore, and returned air at 9,63,-4 for the center pixel. The ore was at 10,64,-3. The same probe kept the ore in top and side mode, where the slice is 169 cells. CraftOS-PC v2.8.3 headless printed `cells=2197 visible=1024 oreKept=false`. Gate A uses radius 1, so its passing turtles do not cover this path. This hits any enabled iso or map view once the snapshot is dense.

2. High. A throttled frame clears the click target. `directview.lua:94-95` sets `framePick` to nil when the interval has not elapsed. `hub.lua:1653` redraws every 0.1 seconds. The default interval is 0.2 seconds in `views.cfg.example`. A lua 5.2 replica of that condition reported `pick=false` on the in-between steps. `directview.lua:148` then ignores `directgpu_mouse`. `directview.lua:40-43` includes turtle position in the frame key, so movement keeps the key changing. Clicks are dropped while the fleet moves.

3. High. A non-color monitor is not handled. `views.lua:7` calls `setTextColor` on every draw. `docs/gemini-review.md` line 82 says a normal monitor is monochrome. The UI test never lets that call fail. This headless CraftOS run reported `color=true` and could not attach a monitor, so the throw was not executed here. Likelihood is high on a non-advanced monitor. The warehouse acceptance asks for that monitor.

4. Medium. `estop` is added to `ROUTED` for every hub. `hub.lua:250`. The previous table did not include it. The change is not behind `views.cfg`. When the fleet server was seen in the last 15 seconds, estop takes the server path and the existing two-second direct fallback. This run did not time that path on a live computer.

5. Medium. The server copies the turtle's controller secret into the command it delivers. `server.lua:356`. `tests/server.lua` expects `commandAuth` to equal that secret. `miner.lua:2662` accepts the command when the field matches `cfg.ssot.secret`. Rednet is carried by a modem transmit. A computer in range can read the payload. One captured command reveals a reusable credential.

6. Medium. Short text monitors overlap the fleet row with the footer. `views.lua:31-42` reserves `h-6` rows and still draws a row when the height is smaller. A lua 5.2 layout probe overlapped the header and the turtle row on a 7x5 screen, and overlapped the turtle row with the page line on a 12x6 screen. `tests/view-ui-checks.lua:18` draws 1x1 and 12x6 and only checks that the stub cursor stays in range. At width 15 the E-stop button is not registered because it starts at x=17.

7. Medium. DirectGPU creation asks for 320 by 240. `directview.lua:71`. The design note says a 3x2 wall is 492 by 328 at scale 1 and that `getDisplayInfo` is the size to trust. The draw uses `getDisplayInfo`, so the pixels follow whatever create actually built. Whether those two numbers force a 320x240 display is not proven against the running mod. Treat the wall-size claim as unmet until Gate B records `pixelWidth` and `pixelHeight`.

8. Low. The committed warehouse image overlaps a site label and a turtle label. `views.lua:55-72` draws sites and then turtles into the same cells. `docs/evidence/pr5/warehouse-normal.png` shows `S IroT2`.

9. Low. The view installer does not ask for a center or a radius. `install.lua:565`. `hub.lua:1624-1626` then uses the selected turtle, `viewsCfg.center`, `hub.pos`, or 0,64,0.

10. Process. PR 29 does not contain PR 4. `git merge-base origin/main origin/feat/ssot-pr5` is `b5c5bda`. GitHub reported `mergeable_state` dirty for PR 29. `view-source.lua` is written against `wh-sites` on the PR 4 commit named in `docs/ssot-pr5.md`. The owner of `feat/ssot-pr5` has to reconcile it. This review did not rebase that branch.

## What was run

`lua5.2 tests/run.lua` on `/tmp/pr29` at `f93f7c8` printed `104 tests passed` and exited 0.

`lua5.2 tests/run.lua` on `main` at `ece242a` printed `98 tests passed` and exited 0. That was before the separate Tom control change.

CraftOS-PC v2.8.3 was downloaded from the job URL. `sha256sum` printed `f25536c7a05f67827fe44573ff65627cbe595e13c75815ef86a4e1f3bd33a88c`. `squashfs-root/AppRun --headless --version` printed `CraftOS-PC v2.8.3`.

The headless probe used `--directory /tmp/craftos-probe --id 0` with `standardsMode` true and `computerSpaceLimit` 1000000. Startup loaded `view-scene.lua` from the PR head. It printed `capacity=1000000`, `color=true`, `cells=2197 visible=1024 oreKept=false`, and `Monitors are not available in this mode`. After padding the disk it printed `free=5819` and then wrote `views.counter` with `free=5800`. That did not reach the refusal path.

`tests/sandbox/run.ps1 -Scenario views` was not run. It is a Windows launcher for `CraftOS-PC_console.exe`.

No Minecraft server was started. The live server was not contacted.

## Main branch items

These are on `main` at `ece242a`. They are not introduced by PR 29.

The Tom button overflow at `fleetview.lua:650-659` is the same failure recorded in `docs/evidence/pr5/gateB-first-attempt.json`. PR 38 keeps the wide row and compacts a 64-pixel row. `lua5.2 tests/run.lua` on that branch passed the existing 98 tests and `tests/test_view_tom.lua`.

`ssot-client.lua:35` puts the controller secret on every SSOT request. `ssot.lua:229` compares it and later copies `auth` into the reply. `server.lua:260-269` relays modem repeat packets. A captured secret is reusable.

`update.lua:53-68` uses a djb2 hash and `rednet.lookup` for the hostname `server`. Any computer can host that name when GitHub is unreachable.

`ssot.lua:281` calls `sleep(0)` while checking saved chunks. `server.lua:881-896` rearms its one-second timer only when that loop sees the timer event. `sleep` pulls events. A timer that arrives during the sleep is not rearmed by this loop. That interaction was not executed here.

`ssot.lua:227` rejects a counter above 2147483647. `ssot.lua:238` rejects a counter that is not newer. A client that reaches the ceiling cannot send another accepted counter.

`ssot.lua:94` treats a move in phase `started` as occupancy for both the source and the destination. An offline turtle therefore holds those cells until something else clears the move.

`warehouse-tasks.lua` has no expiry, timeout, or lease check. `warehouse-tasks.lua:103-109` returns or assigns an active order with no age limit.

`server.lua:17-19` caches the fleet Lua on the same disk as `server.state`. Gate B depth still asks for a real 1,000,000-byte run with that cache. This review did not boot that server.
