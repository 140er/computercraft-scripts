# Fix plan for the normal line (alpha, then main)

Repo 140er/computercraft-scripts. Written by the plan agent on 2026-10-21 at 01:45 CEST (Amsterdam). Co-signer Poteto Judgment.

**Co-signed by Poteto Judgment, 21 Oct 2026, conditional edits 1 to 3 applied.**

Heads checked. main is `5140e2c`. alpha is `3f780ac` ("Merge branch 'pr85' into alpha"). The reviews used older alpha heads (`23a9585` for Judgment, `21619e9` for Poteto Code). Alpha line numbers in this plan are for `3f780ac` unless a line says otherwise.

Sources. `/workspace/reviews/ccs-arch-review.md` and `ccs-warehouse-boot.md` (+ `.patch`) by Poteto Judgment. `/workspace/ccreview/REPORT.md`, `WAREHOUSE.md` and `PLAN-FACTS.md` by Poteto Code. PRs 30, 31, 77 and 82 on GitHub. `/workspace/plans/cc-h4-offline-plan.md` for context only.

This is the canonical fix list for the normal line. Other plans point to its F-steps.

Labels. **measured** means someone ran it, or the code was read at the pinned sha with the file and line given. **inferred** means it follows from measured facts but nobody ran it. **guess** means it is not checked.

## 1. Rules

1. Stock CC:Tweaked only. Computers and turtles have 1,000,000 bytes, the default `computer_space_limit` (measured, CC:T `Config.java` line 15, cited in cc-h4-offline-plan.md:176). Raising the limit is not a fix on this line.
2. Default CC:Tweaked config. Plain turtles. No mods are required for core play.
3. No new features until C1, C2 and C3 are done. That freeze covers alpha. It lasts until F6 passes its gate, because C2 is fixed in F6.
4. Cloud agents use Grok 4.7 at normal speed. Never Fast.
5. Nothing is tested on live servers. Gate A is the CraftOS-PC sandbox. Gate B is a disposable test server with 1,000,000-byte computer and turtle disks, not 8 MB.
6. Evidence per step is the Gate B `SUMMARY.md` with `GATES: PASS` at 1 MB, the commit sha, and a screenshot for anything a player sees. "Tests pass" alone does not close F2, F3 or F6.
7. Work lands on alpha first. Main only gets it through the promotion steps in section 4. Main feeds the live updater (`update.lua:12` on main points at `refs/heads/main`, measured), so every main merge reaches live computers on their next update.
8. Mod Forge Admin updates the `Status:` line of each step. Values are `todo`, `in progress` and `done`, plus the PR link.

## 2. One disagreement, and where I stand

Poteto Code rates nothing Critical, because `luac -p` passes, luacheck has 0 errors, and the suites pass (98 on main, 387 on alpha, measured in `/workspace/ccreview/tests-*.txt`). Poteto Judgment keeps C1, C2 and C3 Critical, because the suites run on 4 MB and 8 MB disks and cannot see the 1 MB failures.

I side with Judgment. A gate that cannot fail is not evidence. The facts back that. Gate A runs most scenarios at 4,000,000 bytes (measured, alpha `tests/sandbox/run.ps1:135`). Gate B forces 8,000,000 bytes (measured, alpha `tests/ingame/run.ps1:46`). That is why F0 comes first. F0 makes the gates able to fail, and it must show red on alpha before any fix lands.

## 3. Findings and steps

Each item gives the problem, evidence, fix, PR, dependencies and a done-check. Steps F0 to F7 come from Judgment's proposed order. I verified each claim against the code and note where I disagree.

### F0. 1 MB truth gate

Port. Also ported to server-only.

**Problem.** The gates cannot fail on 1 MB problems, and the role bundles do not match what the code loads.
- Gate B sets `$diskLimit = 8000000` (measured, alpha `tests/ingame/run.ps1:46`). Gate A uses 4,000,000 for every scenario except `install` and `h4a` (measured, alpha `tests/sandbox/run.ps1:135`).
- `bundle-manifest.lua` leaves out 27 root modules (measured by Poteto Code at `21619e9`). I re-checked at `3f780ac`. `mapstore`, `mapsection`, `shelf`, `roles`, `mirror` and `wh2-locations` are still absent (measured, `rg` over `bundle-manifest.lua`). So compact maps (#70) are silently off behind the `21619e9` guard (`ssot.lua:127`), `hub shelf` crashes on `dofile` (`hub.lua:77-80`), and #82's shelf, roles and mirror never install.
- The miner bundle in `install-roles.lua:14-15` totals 312,351 bytes. But `miner.lua` also `dofile`s `b1-nav.lua` (:2413), `lib/stubs/b1_h1.lua` (:2414), `view-source.lua` (:3041) and `wh2-client.lua` (:880), and none of them are in that bundle (measured).
- No fixture holds a full state, so real state sizes are unknown (measured, PLAN-FACTS.md section 3).

**Fix.**
1. Gate A and Gate B run every scenario at 1,000,000 bytes for computers and turtles. This undoes PR 85's 8 MB. Keep the PR 85 runner, change only the number.
2. Add `tests/f0-role-load.lua`. For each role, build a sandbox fs with only that role's bundle, load the entry file, and follow every `dofile` and `require` in the static graph, including lazy ones. Fail on any module that is loaded but not shipped.
3. Add `tests/f0-role-size.lua`. For each role, assert `code bytes + sum over stores of (copies x limit) + reserve <= 0.8 x 1,000,000`. Copies is 3 for legacy `A.store` and 2 for `mount:open`. Count each file and each directory as at least 500 bytes, because CC:Tweaked charges `MINIMUM_FILE_SIZE = 500` per file and per directory (measured, CC:T `mc-1.21.x` at `794f78ae437a`, `MountConstants.java:30` and `WritableFileMount.java:90,124,177`). So a file's cost is `max(500, size)`, and each directory adds 500.
4. Add `tests/fixtures/full-state/` with a full `ssot.state`, `nav.state`, `mining.state`, `server.state` and `hub.state` at their current caps. Measure their real serialized sizes and print them.
5. Add a manifest check that fails when a root module is loaded but not listed. Then regenerate `bundle-manifest.lua` with `tests/make-bundle-manifest.lua` from the real graph.
6. Add an H3 check. With alpha's queue (`server.lua:276-284`, measured), send 32 requests during one full-state save and assert none are lost at 1 MB.

**PR.** New PR to alpha, `test: F0 1 MB truth gate`. The manifest fix is a second commit in the same PR, after the red run is recorded.
**Depends on.** Nothing.
**Done-check.**
- Before the manifest fix, a recorded red run on alpha `3f780ac`. `f0-role-load` fails for `roomclient` (missing `atomic.lua`), `miner` (the four modules above) and `server` (`wh2-locations.lua`, `mapstore.lua`). `f0-role-size` fails for `miner` and `server`. Gate B at 1 MB shows at least one FAIL.
- After the manifest fix, `f0-role-load` passes for every role except the ones F1 and F2 fix, and those are listed as expected failures.
- The full-state fixture prints real byte counts into the PR body.

Status: todo | PR: -

### F1. Warehouse order computer, server crash on bad queries, PRs 30 and 31

Port. Also ported to server-only.

This is one PR with five parts. Parts a and b are the warehouse fix.

**F1a. Alpha role install leaves the order computer dead.**
- **Problem.** The `roomclient` entry has no `boot` and no `atomic.lua`, so no startup is written and `roomsorter client` dies with `File not found` (measured in CraftOS-PC by Judgment, `ccs-warehouse-boot-harness/alpha-live-flow.log`; still true at `3f780ac`, `install-roles.lua:22-23`). `roles.lua:29` lacks `atomic.lua` too (measured).
- **Fix.** Apply `/workspace/reviews/ccs-warehouse-boot.patch`. It sets `boot = "roomsorter client"`, adds `atomic.lua` and `update.lua` to `install-roles.lua` and `roles.lua`, and quotes each boot word in `writeBoot` (`install-shell.lua:139-145`).

**F1b. The order client gives up after one search.**
- **Problem.** `roomsorter client` looks for the turtle once for about 17 s, then exits (measured, main `roomsorter.lua:85-116`, alpha `:164-195` at `21619e9`). A turtle that boots 25 s late leaves the monitor black (measured in CraftOS-PC, `/workspace/ccreview/repro/data-main-late`). This is the bug Jeffrey sees on main, because main's role install is fine (measured, `main-control.log`).
- **Fix.** Apply `/workspace/ccreview/fix/roomsorter-client-retry.diff`. The client keeps looking and writes its status on the monitor.

**F1c. One bad query kills the alpha server.**
- **Problem.** A `wh2-get` for `locations` runs `dofile("wh2-locations.lua")` (measured, `wh2-dispatch.lua:63`). That file is not in the manifest. `request()` is called without `pcall` (measured, `server.lua:1229` and `:1246` at `3f780ac`; Poteto Code cited `:1180` at `21619e9`). One such query ends the server loop (inferred from the code, not run).
- **Fix.** Wrap each `request()` call in `pcall`, log the error and reply with an error. Ship `wh2-locations.lua` through the F0 manifest fix.

**F1d. PR 30, chat box name.**
- **Problem.** `buddy.lua:757` on main calls `peripheral.find("chatBox")` (measured). PR 30 changes it to `chat_box` (measured from the diff). PR 30 is a draft against main, not in alpha (measured).
- **Fix.** Cherry-pick PR 30 into this PR. First check `chat_box` and the `sendMessage` and `chat` event arguments against Advanced Peripherals 0.7.62b, the server's version, not 0.8. Poteto Code notes 0.8 changed `sendMessage` and the `chat` event order (measured from AP docs by Poteto Code). Whether 0.7.62b already uses `chat_box` is a guess until checked in the jar. Safest form is `peripheral.find("chat_box") or peripheral.find("chatBox")`.

**F1e. PR 31, status from unpaired miners.**
- **Problem.** With `ssot.cfg` present, `minearmy` status from a miner not in `controllers` is dropped (measured, main `server.lua:874`). Unpaired miners show stale on the dashboard. PR 31 is a draft against main, not in alpha (measured).
- **Fix.** Cherry-pick PR 31. Its test pairs computer 7, sends status from 5 and expects the record, and expects no reply to a command from 5 (measured from the PR body).

**PR 82 relation.** PR 82 (H4a, base main, not a draft, mergeable) is already in alpha's history (measured, PLAN-FACTS.md section 4). Its `roles.lua:29` repeats the missing `atomic.lua` (measured by Judgment). Block PR 82 on main until F1a and the F0 manifest fix are in it. Do not merge PR 82 to main on its own.
**Depends on.** F0.
**Done-check.**
- CraftOS-PC `install role roomclient quick` plus reboot shows the ORDER screen (Judgment's `flow2.lua`).
- CraftOS-PC late-turtle repro (`/workspace/ccreview/repro/run-scenario.sh`, turtle starts 25 s late) shows the ORDER screen once the turtle comes up.
- `f0-role-load` passes for `roomclient`.
- New test `tests/f1-server-bad-query.lua` sends an unknown op, a malformed table and a `locations` query, then a valid `get`. The server answers the valid `get`.
- PR 30 test plus a note in the PR body naming the AP 0.7.62b source used.
- PR 31 test passes on alpha.
- `lua5.2 tests/run.lua` passes with at least 388 tests.
- Screenshot of the ORDER screen on an advanced monitor from Gate B at 1 MB.

Status: todo | PR: -

**F1w. Conditional. Only if wh2 fleet mode is turned on anywhere.**
- **Problem.** `wh2-program.lua:84-93` runs programs with `shell` and `require` nil, which breaks self-update and the wizard (measured in CraftOS-PC by Poteto Code). Its peripheral proxies have no metatable, so `peripheral.getName` may throw. That second part is unconfirmed on a real wh2 setup (guess, Poteto Code saw the error in a standalone check). Nothing writes `wh2.cfg` today (measured).
- **Fix.** `setmetatable(proxy, getmetatable(device))` and pass `shell` and `require` into the program environment.
- **Done-check.** CraftOS-PC test with `wh2.cfg` `enabled=true` runs `roomsorter update` and `peripheral.getName` on a found modem without error.

Status: todo | PR: -

### F2. Disk budget at 1 MB (C1)

Port. Also ported to server-only.

**Problem.**
- Legacy `A.store` keeps the file, `.tmp` and `.bak`, so three copies exist during a save (measured, main `atomic.lua:27,59-61`, alpha `atomic.lua:365-400`). Its default limit is 900,000 bytes (main `ssot.lua:308`, alpha `ssot.lua:812`). Nav allows 400,000 (main `nav.lua:45`, alpha `:75`) and mining 250,000 (`mining.lua:33`).
- A failed save poisons the store (main `atomic.lua:65`), then `nav.lua:49` (alpha `:91`) asserts and the miner dies. After a restart, `assert(store.save(s))` at main `ssot.lua:312` crashes the server at boot (measured, Judgment's harness `lua5.2 bench.lua 64`).
- The server code cache is 977,085 bytes on main and 1,345,300 bytes on alpha, next to a 900,000-byte state budget (measured by Poteto Code, PLAN-FACTS.md section 3). That cannot fit 1 MB.
- Several saves are not atomic at all. Main `hub.lua:156-158` writes `hub.state` in place (measured). Poteto Code lists 54 unguarded `fs.open(...,"w")` sites on main and 43 on alpha (`/workspace/ccreview/fsopen-unguarded-*.txt`).

**Where I disagree with Judgment's F2 text.** Judgment says "cut atomic.lua to temp plus fs.move". Alpha already has that. PR 82's `mount:open` two-slot store is on alpha (measured, `atomic.lua:95-298`, and `mining.lua:33` uses it). The gap is that `ssot.lua:731` and `nav.lua:75` on alpha still call the legacy three-copy `A.store` (measured). So the fix is to move those callers, then remove the legacy path. Two slots still mean two full copies, so budgets must count 2x.

**Fix.**
1. Move `ssot.lua`, `nav.lua` and every other `A.store` caller to `mount:open`. Delete the legacy writer after a one-time migration read.
2. Derive budgets from `fs.getCapacity` and the role's code size at boot, with 20% headroom. Rough numbers for a 1 MB miner (inferred). Code is up to 467,104 bytes (measured static `dofile` closure of alpha `miner.lua`, 33 files). That leaves about 333,000 bytes for state across two slots, so nav about 100,000 and mining about 50,000 per copy. Judgment measured about 556 KB for the miner closure at `23a9585` with `git cat-file`. My lower figure comes from a static `dofile` scan at `3f780ac`, so the true number needs F0's size test.
3. The server stops caching all code. Turn on PR 82's code shelf, so the server serves only role bundles, or move the cache to a separate mirror computer. The `ssot.state` budget then follows the same formula. Rough figure is about 200,000 bytes per copy (inferred, 1,000,000 minus a 392,205-byte static server closure minus 20%, halved).
4. A failed write degrades instead of dying. The store reports "disk full", keeps the last good value, stays writable for control data (PR 82's control reserve), and the program keeps running read-only for bulk data. Never `assert` on a save at boot.
5. Convert `hub.state`, `server.state` and the other in-place writes to the atomic store.
6. Lower `maxChunks` and map caps to what the budget allows.

**PR.** New PR to alpha, `fix: F2 fit 1 MB disks`.
**Depends on.** F0 (size test and fixture). F1 is not required.
**Done-check.**
- `f0-role-size` passes for every role with the full-state fixture.
- New fault-injection test `tests/f2-fs-full.lua` uses `/workspace/reviews/harness` mocks. It fills the disk during a save on the server and on a miner. Both keep running, both show a "disk full" warning, and a server reboot with an over-budget state boots read-only instead of crashing at `ssot.lua:312`.
- `lua5.2 bench.lua 64` in the harness no longer ends in `state budget exceeded` at boot.
- Gate B at 1 MB `SUMMARY.md` with `GATES: PASS`, plus a screenshot of the disk-full warning on the server monitor.

Status: todo | PR: -

### F3. Recovery without asserts (C3)

Port. Also ported to server-only.

**Problem.** CC turtles reboot when their chunk reloads, often mid-move. The legacy journal `st.pending` is set before `turtle.forward` (main `miner.lua:1169-1171`). Boot then hits `assert(not st.pending ...)` and the program ends (measured, main `miner.lua:2787`, `:2820`; alpha `:3202`, `:3259`). Other exits are a GPS miss after a good move (main `nav.lua:210`, alpha `:563`), `mining.lua:60` and `:135` on main, SSOT boot without GPS or server (main `miner.lua:2822-2824`, alpha `:3261-3263`), `ssot-client.lua:99`, `nav.lua:49` (alpha `:91`) and `store.lua:221` on alpha (all measured). `startup.lua` runs the program once.

**Fix.**
1. One supervisor loop per program. It wraps the main loop in `pcall`, shows status, backs off (for example 5 s, 15 s, 60 s, then 60 s), retries, and never exits on its own.
2. Replace the listed asserts with a `recover` state. Resolve `st.pending` and `st.turnFrom` from the GPS pose plus the journal, the way `nav.recover` already does. Without GPS, stay in `recover` and retry.
3. Keep asserts only for programmer errors such as bad config types.
4. Make `nav.recover` reachable outside fleet mode (alpha `C.bootNavigation` prints "keeps running" and never calls it again, measured by Judgment).

**PR.** New PR to alpha, `fix: F3 supervisor and recover state`.
**Depends on.** F2, because a failed save must already degrade.
**Done-check.**
- New Gate A tests. `f3-reboot-mid-move` kills the turtle between `st.pending` and the commit. `f3-gps-miss` drops one GPS fix after a good move. `f3-no-server-boot` boots with no server. Each ends with the turtle program still running and in `recover` or back at work.
- Gate B at 1 MB, one run that kills a mining turtle during a move (chunk unload or `/reload`). `SUMMARY.md` shows `GATES: PASS` and the turtle resumes without a hand reboot. Screenshot of its status.

Status: todo | PR: -

### F6. Offline-capable movement (C2, H6). Runs in parallel with F4

Port. Normal line only.

**Problem.**
- Every block costs reserve, start and commit (main `ssot-client.lua:84-96`), each a durable full-state server save, plus a GPS fix before and after (main `nav.lua:170,209`). A normal-modem miner out of range cannot move one block (measured by reading).
- `dead.lua` is on by default with `deadAfterMs` 120,000 (measured, alpha `ssot.lua:122,131`). After 120 s of silence it deletes the turtle's started move and releases its bay locks (measured, alpha `dead.lua:115-116`). On return the commit fails and `ssot-client.lua:99` stops the program (measured).
- H6. When the warehouse service is off, mining interrupts on "inventory full" or "low fuel" (main `mining.lua:147-156`) and the miner restarts the job at once, looping until fuel hits the margin (measured by Judgment, main `miner.lua:2138-2149`).

**Fix.**
1. Finish B1 lease v2. The turtle moves locally under a valid lease, keeps a journal and reconciles in batches. Use the shapes in cc-h4-offline-plan.md sections 2.5 and 2.6 and the B1 section there. Do not import its server-only ideas.
2. `dead.lua` never deletes a move or a bay whose lease is still valid. Only an explicit `turtle-forget` does that. Until this holds, default `deadTurtles` to off for normal-modem miners.
3. H6. When service is off, fall back to the legacy chest unload and refuel at home.
4. A minimal piece of F5. For SSOT miners, the hub treats pose, lease and progress as read-only and never writes them back. Today the hub merges by wall-clock `rev` (measured, main `hub.lua:154`, `hub.rev = os.epoch("utc")`), so a stale hub copy with a newer clock can overwrite a reconciled pose (inferred). Full F5 stays in Phase 5.
5. M4. `ssot-client` calls are single-flight. A second concurrent call gets "SSOT busy" instead of waiting (measured by Judgment, main `ssot-client.lua:26`). Lease batching adds renew and batch-commit calls next to request retries (3 sends of 1 s, main `ssot-client.lua:40-51`). So F6 queues or serialises client calls, and a retried batch must replay through the request-id cache, not apply twice (inferred).

**Order.** F6 runs in parallel with F4 in Phase 4, each with its own gate. C2 is Critical and its fix ends the feature freeze. The lease and `dead.lua` already live in `ssot.lua`, so F6 does not need full F5 first (inferred). When both are ready, F4 merges first, because its MAC wrapper sits in the `ssot-client` request path. F6 then rebases on F4.
**PR.** New PR to alpha, `fix: F6 lease-based offline movement`.
**Depends on.** F3.
**Done-check.**
- Gate A test `f6-dead-keeps-lease` holds a turtle silent for 200 s with a valid lease, then commits. The commit succeeds and the move was not deleted.
- Gate A test `f6-service-off` fills the inventory with service off. The miner unloads into its home chest and refuels instead of looping.
- Gate A test `f6-hub-stale-copy`. The hub holds a stale pose, lease and progress with a newer wall-clock `rev` while a turtle reconciles. The SSOT pose wins, and the hub never writes those fields back.
- Gate A test `f6-retry-batch`. Two concurrent client calls during a lease batch both complete, and a retried batch commit is applied once.
- Gate B at 1 MB. Pause the server for 10 minutes. A miner finishes its lease, then reconciles when the server returns. `SUMMARY.md` `GATES: PASS`, commit sha and a screenshot of the reconciled pose.

Status: todo | PR: -

### F4. Signed updates and an atomic updater (H4, H5, PR 77)

Port. Also ported to server-only.

**Problem.**
- H4. `update.lua:62-99` on main accepts code from whatever `rednet.lookup` returns and checks a hash the sender supplies (measured). The SSOT secret travels in clear text in every request (measured, main `ssot-client.lua:35`).
- H5. `update.lua:130-131` deletes a file, then moves the new one in (measured). A crash between them leaves no file. The hub hands turtles only `miner.lua` (measured by Judgment, main `miner.lua:2043-2048`).
- PR 77 (draft, base main, +3897/-17, 31 files, mergeable) adds keyed BLAKE3 request MACs, an Ed25519 signed manifest and a `fleet.pin` (measured from the PR body). `requireMac` defaults to false. It is not in alpha (measured, Judgment).

**Fix.** Rebase PR 77 onto alpha. Turn `requireMac` on for paired machines. Add a staged update folder plus a manifest swap with a version marker. The hub serves the full role bundle, not just `miner.lua`. Check the vendored ccryptolib size against the F0 budget (cc-h4-offline-plan.md:296 estimates 107,532 bytes, inferred).
**PR.** PR 77, retargeted to alpha, plus one follow-up PR for the staged swap.
**Depends on.** F2 (budget) and F3 only. Runs in parallel with F6 in Phase 4. Merges before F6 when both are ready.
**Done-check.**
- Gate A test. A tampered manifest and an unsigned manifest are both refused.
- Gate A test. An update killed mid-swap reboots into the old version.
- Gate A test. A v1 request with the secret is refused when `requireMac` is true.
- `f0-role-size` still passes with ccryptolib.
- Gate B at 1 MB `SUMMARY.md` `GATES: PASS` for one signed update across a miner, the hub and the server.

Status: todo | PR: -

### F5s. Subtract unused alpha services. Runs before F5

Port. Normal line only.

**Problem.** PR 86's `alpha-boot.lua` builds strata, the storage host and peers, but nothing reads `alphaBoot` (measured, alpha `server.lua:1409,1420` and `hub.lua:2094,2105`; luacheck W231 in `/workspace/ccreview/luacheck-prs.txt`). #76 strata and #80 peer storage have no callers outside tests (measured by Poteto Code, PLAN-FACTS.md section 4). They cost disk and boot time at 1 MB.
**Fix.** Remove the `alpha-boot.lua` calls, or gate them off by default with a test that proves they stay off. Keep the modules in the repo until F5 to F7 decide whether they are needed.
**PR.** New PR to alpha, `chore: F5s gate off unused alpha services`.
**Depends on.** F2.
**Done-check.** Test `f5s-services-off` boots the server and the hub and asserts no strata, storage host or peer object is created. `f0-role-size` shows the saved bytes.

Status: todo | PR: -

### F5. One owner of state (H1)

Port. Normal line only.

**Problem.** One miner's state lives in `hub.state`, `server.state`, the miner's own file and `ssot.state` (measured by Judgment). The hub adopts the server copy when `rev` is newer, and `rev` is wall-clock `os.epoch("utc")` (measured, main `hub.lua:154`). The server keeps a second position per bot from telemetry (main `server.lua:315`). AR and the GPU view draw from telemetry on main (`server.lua:504,934`).
**Fix.** `ssot.state` owns pose, lease and task. The hub becomes a client and UI. Telemetry is display only. AR and the GPU view read SSOT poses. No wall-clock comparison decides which copy wins.
**PR.** New PR to alpha, `fix: F5 ssot owns pose and jobs`.
**Depends on.** F4, F6, F5s.
**Done-check.**
- A grep test fails if any job or position write happens outside `ssot.lua` and its client.
- Gate A two-writer race test. The hub and a turtle update the same job at once. The result is the same after any interleaving.
- Gate B at 1 MB `SUMMARY.md` `GATES: PASS`, with a screenshot of the hub and the AR view showing the same pose.

Status: todo | PR: -

### F7. Map producer, then views (H2)

Port. Normal line only.

**Problem.** Only op `scan` writes the server map (`ssot.lua:163-197` on main), and nothing outside tests sends it (measured, `rg '"scan"'` on main finds only the op table in `ssot-client.lua:54` and unrelated hub, farmer and builder commands). DirectGPU, AR x-ray, H4b1, H4b2 and strata all read an empty map (measured by Judgment). The DirectGPU textured-draw argument order is unverified (guess, conflicting docs, Judgment M1).
**Fix.** Decide first whether the shared map earns its 1 MB space. If yes, nav sends batched `scan` deltas from `remember`, and turn on compact sections now that F0 ships `mapstore.lua` and `mapsection.lua`. Run one in-game probe that draws one textured cube and times 100 calls. If no, delete the map consumers.
**PR.** New PR to alpha, `feat-fix: F7 map producer`. Allowed after F6, because the freeze is over.
**Depends on.** F5.
**Done-check.**
- Gate A test. After a mining run the server map is non-empty and matches the cells the turtle saw.
- Gate B at 1 MB. Screenshot of the monitor map next to the mined area, matching. Probe log with the argument order that worked.
- `f0-role-size` still passes with a full map fixture.

Status: todo | PR: -

## 4. Phases in run order

Each phase ends in a gate. A gate is Gate A green plus a Gate B `SUMMARY.md` with `GATES: PASS` at 1 MB, unless the phase says otherwise.

**Phase 0. Make the gates honest.** F0. Gate. A recorded red run on alpha `3f780ac`, then green for everything except the expected F1 and F2 failures.

**Phase 1. Stop the visible breakage.** F1 (with F1w only if wh2 is in use). Gate. ORDER screen in both CraftOS-PC flows and in Gate B, bad-query test green.
- **Main hotfix M1.** F1b (client retry), PR 30 and PR 31 are small and fix bugs on live main. Land them on main as one small PR after the alpha PR passes. Main's role install is not broken, so F1a is not needed there (measured). Jeffrey approves this merge, because it reaches live computers.

**Phase 2. Fit 1 MB.** F2, then F5s. Gate. `f0-role-size` green for all roles, `f2-fs-full` green, Gate B at 1 MB.

**Phase 3. Never die.** F3. Gate. The three F3 Gate A tests and the Gate B kill-during-move run.

**Phase 4. Work offline and trust updates.** F6 and F4 in parallel, each with its own gate.
- F4 gate. Tampered, unsigned and killed-mid-swap tests green, plus the signed update Gate B run.
- F6 gate. Gate B 10-minute server pause run, plus `f6-hub-stale-copy` and `f6-retry-batch`.
- Merge order. F4 first, then F6 rebases on it.
- The feature freeze ends when F6's gate passes, because that fixes C2.
- **Main promotion P1 (recommended default, Jeffrey to confirm).** A curated fix branch, not all of alpha. It carries F0 to F3, F6 and F4, plus F5s with the unused services gated off. PR 82's two-slot store and role lists come with F1 and F2. After the freeze, alpha's feature PRs reach main one at a time, each through Gate B at 1 MB.

**Phase 5. One owner.** F5 only. Gate. Two-writer race test and the Gate B screenshot of hub and AR showing the same pose.

**Phase 6. Map.** F7. Gate. Map screenshot and DirectGPU probe.
- **Main promotion P2.** F5 and F7 reach main through the same one-PR-at-a-time path, each through Gate B at 1 MB.

**server-only cut.** The server-only branch is cut when F4's gate passes, whether or not F6 is done. F0 to F4 are ported to server-only. F5s, F5, F6 and F7 stay on the normal line only. F6 is not ported even if it is done by then (inferred, server-only has its own turtle protocol).

## 5. Cross-reference

| Finding | Step | Covered in Judgment's list? |
|---|---|---|
| C1 disk budgets | F0, F2 | Yes |
| C2 online-only movement | F6 | Yes |
| C3 recovery asserts | F3 | Yes |
| H1 no single owner | F5 | Yes |
| H2 map has no producer | F7 | Yes |
| H3 main server drops messages | F0 step 6 (check alpha queue), P1 (main gets it) | **No. Added.** Fixed on alpha already (`server.lua:276-284`, measured). F1c adds the per-request `pcall`. |
| H4 unauthenticated code and commands | F4 | Yes |
| H5 non-atomic updates | F4 | Yes |
| H6 no refuel or unload without service | F6 | **No. Added.** |
| PR 30 chat box | F1d, M1 | Yes |
| PR 31 unpaired status | F1e, M1 | Yes |
| PR 77 H1H2 MACs | F4 | Yes |
| PR 82 H4a 1 MB groundwork | F1 (block on main), F2 (two-slot store), P1 | Yes |
| Warehouse role install (Judgment) | F1a | Yes |
| Warehouse client retry (Poteto Code) | F1b, M1 | Added by Chief of Staff |
| Server crash on bad query | F1c | Added by Chief of Staff |
| Manifest missing 27 modules | F0 | Added by Chief of Staff |
| Server code cache 977 KB / 1.35 MB | F2 step 3 | Added by Chief of Staff |
| wh2 proxy and environment | F1w | Added, conditional |
| PR 86 unused alpha services | F5s | Added |
| M2 leases never expire on main | F6 | Partly. Not a separate step. |
| M4 single-flight client | F6 fix step 5 | Added |
| M6 non-atomic saves | F2 step 5 | Added |

Not covered on purpose. M1 is part of F7. M3 (heavy work per tick) stays in the cleanup PR. Low items from both reviews (for example `panel.lua:1556`, alpha `miner.lua:774`, dead code) are left for a cleanup PR after Phase 4.

## 6. Rulings on the order

These were disagreements with Judgment's first order. Judgment ruled on each when co-signing.
1. F2 moves `ssot.lua:731` and `nav.lua:75` on alpha off the legacy `A.store` writer and deletes that writer. Alpha already has temp file plus move through `mount:open` (measured).
2. Miner size stays open until F0 measures it. Judgment measured about 556 KB at `23a9585`. My static `dofile` closure at `3f780ac` is 467,104 bytes (measured). Both are over budget once state is counted (inferred, 467,104 plus 2 x 400,000 for nav alone is over 1,000,000). F0's size test is the number of record.
3. The freeze ends when C2 is fixed, which is F6's gate.
4. F6 no longer waits for F4 and F5. It runs in parallel with F4 in Phase 4, F4 merges first, and Phase 5 is F5 only.
5. H3 and H6 were missing from the first list. They are now mapped (section 5).

## 7. Risks

- Promoting all of alpha would ship 23 feature PRs to live computers at once (measured, alpha merges PRs 28, 29, 61-76, 78-82, 83, 84, 86). The curated P1 avoids that. The risk returns if someone merges alpha wholesale (inferred).
- Cutting a curated P1 branch from a busy alpha may hit conflicts, because the fixes touch files the feature PRs also changed (inferred).
- The budgets in F2 are rough until F0's fixture gives real sizes (inferred).
- Gate B needs a disposable server. If one is not available, F2, F3 and F6 cannot close (rule 6).
- PR 77 with ccryptolib may push the server or hub over the 1 MB budget (guess until F0 measures it).
- Crypto speed against the 7 s yield timeout is not measured on this line (guess).
- Line numbers drift fast on alpha. Steps cite `3f780ac`. Re-check before editing.

## 8. Open questions for Jeffrey

1. At promotion P1, should main take all of alpha, or a curated fix branch? **Recommended default.** A curated branch with F0 to F3, F6 and F4, plus F5s with the unused services gated off. Not all of alpha. Feature PRs reach main one at a time after the freeze, each through Gate B at 1 MB. Jeffrey confirms.
2. May the main hotfix M1 (client retry plus PRs 30 and 31) go to main early, before alpha's phases finish? **Recommended. Yes.** It fixes the black order screen Jeffrey sees on live main. The merge still needs Jeffrey's approval, because it reaches live computers.
3. Is wh2 fleet mode turned on anywhere? If not, F1w stays parked.
4. Does the shared server map earn its space at 1 MB (F7)?

## 9. Left out on purpose

- Everything from the server-only line. No thin turtles, no hub removal, no drop points, no sharding.
- Raising `computer_space_limit`. Not allowed on stock 1 MB.
- H4c, H4d cold storage and strata as features. F5s gates them off. A later plan decides.
- New UI work, including the miner UI, until the freeze ends.

## 10. What I could not verify

- PR 30, 31, 77 and 82 have no review comments or reviews on GitHub (measured, API returned none).
- Whether AP 0.7.62b uses `chat_box` or `chatBox`. Left as a check inside F1d.
- The `locations` crash was read in the code, not run.
- Poteto Code's 27-module count was at `21619e9`. I re-checked six of the named modules at `3f780ac`, not all 27.
- I did not run any test, Gate A or Gate B. All done-checks are proposals.

## 11. Review log

- 21 Oct 2026. Poteto Judgment co-signed on the condition that edits 1 to 3 go in. All six edits below are applied.
- Edit 1. Phase 4 runs F6 and F4 in parallel, each with its own gate. F4 depends only on F2 and F3. F4 merges first and F6 rebases on it. server-only is cut when F4's gate passes. Phase 5 is F5 only.
- Edit 2. F6 gets a minimal piece of F5. The hub treats SSOT pose, lease and progress as read-only. New Gate A test `f6-hub-stale-copy`.
- Edit 3. Open question 1 has a recommended default, a curated P1 fix branch instead of all of alpha.
- Edit 4. F0's size formula counts at least 500 bytes per file and per directory, from CC:T `WritableFileMount`.
- Edit 5. Open question 2 recommends yes to the M1 hotfix, still with Jeffrey's merge approval.
- Edit 6. F6 covers M4, the single-flight client, with test `f6-retry-batch`. M3 stays in cleanup.
- Section 6 rulings applied. F2 deletes the legacy writer. The freeze ends at F6. Miner size waits for F0. F6 runs parallel to F4.
