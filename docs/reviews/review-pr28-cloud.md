# Review of PR 28

Head `feat/ssot-pr6` at `271aac8`. Base `main` at `ece242a`. This review did not push to that branch.

PR 28 adds a disabled AR HUD and a UUID chat gate. The mock suite on that head passes. Several acceptance items from `docs/gemini-review.md` section 7, PR 6, are still open once an operator turns AR on.

## What passed

`lua5.2 tests/run.lua` on `main` printed `98 tests passed` and exited 0.

The same command on `271aac8` printed `116 tests passed` and exited 0. That run includes `tests/chat-checks.lua` and `tests/install-checks.lua`.

Those checks show an empty allowlist denies chat, a username without the matching UUID does not authorize, a confirmation token works once, a restart rejects the old token, and a token expires after 30 seconds. `tests/install-checks.lua` keeps role 5 as `roomclient` and rolls back a failed bundle.

`ar-hud.lua` line 37 defaults `enabled` to false. Chat stays off until `chatEnabled` is saved. `tests/ar-hud-unit.lua` expects no controller calls while disabled.

CraftOS-PC `v2.8.3` matches sha256 `f25536c7a05f67827fe44573ff65627cbe595e13c75815ef86a4e1f3bd33a88c`. One headless computer, id 7, loaded `ar-hud.lua` and `chat-control.lua` from that commit.

`docs/evidence/pr6/gateB/native-priority/ar-hud.png` shows the fleet card, the low-fuel banner, and the radar on a real client. `ar-xray.png` shows the same 2D HUD while a stone wall fills the view. No turtle or ore outline is visible through that wall. That matches `docs/evidence/pr6/cc-ar-depth.md`.

## Ranked findings

### P1. Ore and turtle geometry is shown to every linked goggle

`ar-hud.lua` lines 37 to 38 default `xrayOres` and `xrayTurtles` to true. `ar-hud.lua` lines 348 to 358 plot ore and turtle cells on the 2D radar. `ar-hud.lua` lines 370 to 385 draw world boxes from the same snapshot. Nothing in `H.render` reads the chat allowlist.

`docs/gemini-review/evidence/ccar-signatures.txt` lists no wearer or player method on `ar_controller`. `tests/ingame/ar-probe.lua` lines 42 to 63 render a diamond ore cell with `chatAllowlist` still empty.

The headless probe printed `XRAY true` and `ENABLED false`. Turning AR on therefore turns ore radar on. The 3D lines stay depth-tested, so the wall shot does not show them. The 2D radar does not need that path.

Anyone who wears goggles linked to that controller sees the HUD. The allowlist only gates chat commands.

### P1. The radius stops after two chunks

`ar-hud.lua` lines 249 to 252 count every cell slot. At 8192 slots the function returns with `truncated` set. Two chunks are 8192 slots, so the third chunk is never read.

The headless probe placed `minecraft:diamond_ore` in chunk `minecraft:overworld|2|0|0` with origin `0,0,0` and radius 64. The ore block is at x=32, inside that radius. The probe printed `TRUNC true`, `MAP 0`, and `DIAMOND 0`.

`tests/chat-checks.lua` only puts the ore in the first chunk, at cell 201. That test does not catch this miss.

### P1. `ar_layer` persists x-ray toggles without a chat UUID

`server.lua` lines 400 to 402 apply the controller list only when `ssot.cfg` exists. `server.lua` lines 403 to 408 set `arHub` from any `hub_get` or `hub_put` that sets `arClient`. `server.lua` lines 435 to 444 toggle a layer and call `saveAR` when the sender is `arHub`.

Without `ssot.cfg`, any modem computer can claim `arHub` and then persist `xrayOres` or `xrayTurtles`. With `ssot.cfg`, any paired controller can. The chat allowlist is not consulted. Rednet sender ids are the computer id, so this is not a forged name. It is a missing bind between the layer command and the UUID list.

`hub.lua` lines 1600 to 1602 forward keys `p`, `t`, `o`, and `a` as `ar_layer` whenever the server owns AR.

### P1. This branch conflicts with current main and with PR 5

`git merge-tree` of `origin/main` and `origin/feat/ssot-pr6` reports conflicts in `install.lua`, `miner.lua`, `server.lua`, `update.lua`, `tests/run.lua`, `tests/sandbox/driver.lua`, `tests/sandbox/run.ps1`, `tests/ingame/client.ps1`, and `tests/ingame/run.ps1`. GitHub reported `mergeable_state` dirty for PR 28.

`git merge-tree` of `origin/feat/ssot-pr5` (`f93f7c8`) and `origin/feat/ssot-pr6` adds conflicts in `hub.lua`, `fleetview.lua`, `tests/review-capture.ps1`, and `tests/server.lua`.

PR 5 `views.lua` lines 102 to 104 use `h` for resume and `r` for recall. PR 5 `hub.lua` line 1689 sends those keys to the view. PR 6 `hub.lua` lines 1603 to 1607 handle `h` and `r` in `arControls.key` before the old recall and resume lines. `ar-hud.lua` lines 141 to 150 map `h` to recall and `r` to recharge once `enabled` is true.

PR 5 appends installer ids `view-pro`, `view-warehouse`, and `view-map`. PR 6 appends `ar`, `store`, `vworld`, and `pro`. `role-adapter.lua` lines 7 to 9 tell the operator that the view role is unavailable until PR 5. After PR 5 merges, that stub is the wrong entrypoint.

PR 5 `server.lua` line 20 mirrors `views.lua`, `view-source.lua`, `view-scene.lua`, and `directview.lua`. PR 5 `update.lua` lines 15 to 20 put those files in `KNOWN` and `ALSO`. PR 6 `update.lua` lines 17 to 24 and `server.lua` lines 17 to 20 replace those lists with the AR files and omit the view files. A rebase that keeps the PR 6 lists stops distributing the view modules.

PR 6 `bundle-manifest.lua` has no view files. `update.lua` lines 184 to 186 reject a file whose hash is absent from that manifest.

### P2. Chat has no command rate, and the username is not bound

`chat-control.lua` line 105 drops only the same message from the same UUID inside 2 seconds. The headless probe sent 10 alternating `!hub` and `!recharge` events, 50 ms apart, from one allowlisted UUID. It printed `BURST 10`. Each one asks for a new confirmation. Confirming `hub` on the server recalls every miner at `server.lua` lines 515 to 521. There is no pause between recalls.

`chat-control.lua` line 76 checks the UUID and not the event username. The probe sent `!hub` as username `NotJeff` with Jeffreyy2's UUID and printed `SPOOF 5`. `ssot.lua` lines 38 to 45 require both the name and the UUID. Nothing in this PR calls `chatAllowed`. On main the helper is also unused. That gap is issue 39.

A public `!confirm` prints the token in chat. Another player still cannot redeem it, because `pending` is keyed by UUID. `chat-control.lua` lines 88 to 95 delete the token after one use. The restart case is covered by `tests/chat-checks.lua`.

`H.controls` in `ar-hud.lua` lines 123 to 126 whispers with `sendMessageToPlayer` and ignores the hidden flag. The reply path is private when that method succeeds. A missing `chat_box` drops the whisper and still stores the token.

### P2. Enabling AR remaps hub keys H and R

`hub.lua` lines 1606 to 1607 still mean recall and resume when `arControls.key` returns false. `ar-hud.lua` line 132 returns false when AR is disabled. After `ar enable on`, `h` confirms a recall and `r` confirms recharge. The second press inside 30 seconds runs it. `role-adapter.lua` lines 4 to 6 report recharge unavailable. The old resume key is gone for that session.

### P2. A missing controller is idle. Unequipped goggles keep the last picture

`server.lua` line 534 returns when `ar` is nil. The mock named `no controller: the dashboard and its keys work and never touch AR` passed on both trees.

`peripheral_detach` clears the old wrapper at `server.lua` lines 956 to 961. Taking the goggles off does not detach the controller block. No method in `ccar-signatures.txt` reports a worn set. `cc-ar-depth.md` says the client renderer checks the goggles. The Lua program keeps the elements. The next person to wear the linked goggles sees the last radar, including ores if that layer is on.

A draw error sets `ar` to nil at `server.lua` lines 552 to 555 until the next peripheral event. That can disable the HUD after one bad call.

### P2. A dirty HUD frame copies the whole map and does not yield

`server.lua` line 326 sets `arDirty` on every status. `server.lua` lines 541 to 547 skip the 5 second quiet path when `arDirty` is set, then call `ssot.state()` and `H.render`. `ssot.lua` line 210 copies the whole store. `H.render` issues one peripheral call per edge with no `sleep`. A full ore box is 12 lines, and `maxCells` allows 128. The scan yields every 512 cells at `ar-hud.lua` line 253. The draw loop does not.

`docs/design/hardening.md` H3 says the server event loop must not do unbounded work in the request path. This draw runs inside `network` at `server.lua` line 939.

### P2. Installer stubs claim a boot service, and the manifest is an unsigned checksum

`install.lua` lines 569 to 577 add `store`, `vworld`, and `pro` with no startup step. `install.lua` lines 666 to 667 tell the operator the program starts on boot when `bot.done` is absent. `ar-role.lua` lines 2 to 6 do write `startup.lua`. The three stubs do not.

Role 5 stays `roomclient`. The install test on this head passed.

`update.lua` lines 65 to 68 hash with djb2 and print 8 hex digits. The manifest is downloaded from the same host as the files. `docs/design/hardening.md` H1 asks for an HMAC and for the key to stay off the wire. This bundle does not do that. It does reject a file whose bytes do not match the manifest. The install tests cover a mismatched hash and a crash during commit.

The first `update` from the updater already on a computer does not know `ar-hud.lua`. The new `update.lua` pulls it on the next run through `ALSO`. Until that second run, `server.lua` line 132 skips the HUD because the file is absent. That is safe. It is also a gap after the first reboot.

## Acceptance criteria

| Criterion from `docs/gemini-review.md` PR 6 | Result on `271aac8` |
|---|---|
| Fleet card, fuel alert, radar, boxes, anchors | Present in `ar-hud.lua`. Unit test passed. `ar-hud.png` shows the card, alert, and radar. |
| Keys P T O A H R with confirm on travel | Present. H and R replace the hub keys when AR is enabled. See P2. |
| `!hub` `!recharge` `!pro` `!xray` with UUID, one-use confirm | Present for the UUID. Username is not bound. No command rate. Recharge returns the PR 4 stub. |
| `$` hidden versus `!` public | `tests/chat-checks.lua` passed. Replies use `sendMessageToPlayer`. |
| One drawing owner and namespaced cleanup | Existing owner protocol kept. Shared-owner unit test passed. `ar.clear` is not used while the new HUD is enabled. |
| Dimension and follow target | Unit test passed. A stale follow target drops world geometry. |
| Bounded ore set | `maxCells` is 128. The scan returns after 8192 raw slots, so the radius is not the real bound. See P1. |
| Role 5 unchanged, new roles, hash, rollback | Role 5 test passed. Stub roles do not install a startup. Manifest is unsigned djb2. |
| Gate A mock suite | 116 passed here. `tests/sandbox/run.ps1` was not run. It is PowerShell. |
| Gate B goggles, chat recall, through-wall x-ray | Not re-run. Saved `ar-xray.png` shows no through-wall outline. Author marks Gate B failing in the PR body. |

## Oversights outside this PR

Issue 35 already records the controller secret in `ssot.lua` replies. Issue 39 records that `chatAllowed` has no production caller on main. This review did not open a patch for either. Both need the HMAC design in `docs/design/hardening.md`, not a one-line edit.

`docs/design/wh2-contract.md` lines 284 to 294 still put `secret` and `auth` in the example packets. `docs/design/hardening.md` H1 says the key never goes on the wire. Those two notes disagree. Issue 35 is the code side of that disagreement.

`docs/design/miner-autonomy.md` and `docs/testing/gateB-depth.md` describe chunk tickets and a multi-turtle warehouse run. Issue 34 already records that main never asks the world to load a chunk. This review did not repeat it.

## What this review did not run

No Minecraft server was started. The live host `100.91.208.60` was not contacted. `tests/sandbox/run.ps1` and `tests/ingame/ar.ps1` were not run. Gate B screenshots were only inspected as the files already in the PR. The PR 5 rebase was not performed.
