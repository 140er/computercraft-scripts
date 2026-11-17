---
name: verify
description: Run computercraft-scripts for real (mock CC runtime, plus the CraftOS-PC sandbox where available) and check a change end-to-end before committing or opening a PR
---

# Verify computercraft-scripts

"Verified" means the changed script loads and the changed behaviour was seen working in a CC runtime that is not the live game: the mock harness (`tests/run.lua`) for `hub.lua`, `server.lua` and `miner.lua`, and the CraftOS-PC sandbox (`tests/sandbox/run.ps1`, Windows only) for boot, rednet and disk limits. Scripts with no harness (lumber, farmer, lava, builder, buddy, factory, roomsorter, sorter, panel, ...) only get a compile check here; say so.

## Never

- Never connect to, deploy to, or test against the live Minecraft server, its RCON, or live in-game computers. Merging to `main` is what makes live computers pull code, so never push to `main`.
- Never put server addresses, RCON details or API keys (e.g. the Buddy `api.key` file) in the repo, logs or PR text.
- Never run `install.lua reset` or `update.lua` against anything but a throwaway sandbox disk: both delete or overwrite files and `update.lua` downloads from `main`.
- No paid APIs (Buddy's model server calls are not part of verify).

## 1. Cheap checks

From the repo root (Lua 5.2 and Git installed; about 12 s total):

```bash
for f in *.lua tests/*.lua tests/sandbox/*.lua; do luac5.2 -p "$f" || echo "SYNTAX FAIL $f"; done
lua5.2 tests/run.lua 2>&1 | grep -E '^(FAIL|[0-9]+ tests passed)'
```

- `tests/run.lua` is the repo's only suite and is quick; it runs everything (hub, server, miner mocks). Exit code 1 and `FAIL` lines mean a failure.
- It compares no-controller hub output against `git show main:hub.lua`, so a local `main` ref must exist (`git branch main origin/main` if it does not; never move another worktree's branch).
- CC counts top-level locals of all enclosing functions together and fails a script over 200 (this broke `miner.lua` and `roomsorter.lua` before); `luac` does not catch it. Check any file you added locals to: `grep -c '^local ' <file>`. Today `roomsorter.lua` is 177 and `miner.lua` 168. Keep below ~190 or move values into a table.

## 2. Start it for real

Local stand-in A (always available): the mock harness boots the real script text in a mocked CC environment (`tests/mocks.lua`: `mocks.new(...).start(code)`, then `m.push(event, ...)`, `m.tick()`, `m.status(id, packet)`). `lua5.2 tests/run.lua` above is that start. Ready when it prints `NN tests passed` with no `FAIL`.

Stand-in B (Windows with PowerShell only): the CraftOS-PC v2.8.3 sandbox boots server, hub and an idle miner on three emulated computers with modems and a 1 MB disk each:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\sandbox\run.ps1 -Seconds 30
```

Ready when it ends with `Sandbox PASS` (per computer `PASS booted=True errors=0`, `rx` above 0). It downloads CraftOS-PC on first use, or reads `CRAFTOS_PC`. Run it with a timeout; it stops its own emulator. It does not run on a Linux host without a CraftOS-PC v2.8.3 build.

## 3. Check the change

Drive the changed behaviour, do not only run the suite:

1. Changed `hub.lua`/`server.lua`/`miner.lua`: add or extend a test in `tests/run.lua`, `tests/server.lua`, `tests/miner_lost.lua` or `tests/miner_dirs.lua` that fails on `main` and passes on your change (`test("name", function() ... end)`; feed packets with `m.status(...)` / `m.request(...)`, assert on `m.output`, `m.messages`, `m.files`, `m.arCalls`). Run `lua5.2 tests/run.lua` on both revisions (`git stash` for the base) and show the failure and the pass.
2. Changed a message, saved state file or rednet protocol (`minearmy`, `fleetserver`, `roomsorter`, `turtlefactory`, `builder`): assert an old-format message or old `hub.state` / `server.state` still loads (see how `tests/server.lua` restarts from saved state).
3. Changed any other script: `luac5.2 -p <file>` plus the local-count check above, then state that behaviour needs an in-game check by the owner on a local test server. Do not claim it works.

## 4. Evidence

Put in the PR body, from the exact commit being pushed (`git rev-parse HEAD`):

- the `luac` loop output (empty means OK) and `lua5.2 tests/run.lua | tail -5` including the `NN tests passed` line;
- for a behaviour change, the failing-then-passing output of your new test on base vs head;
- the sandbox `Sandbox PASS` block with its per-computer lines, or the reason it was not run;
- which behaviour was not exercised (mining physics, radio range, chunk loading, real goggles).

## 5. Clean up

The mock suite starts no processes, ports or files outside memory. If you started a sandbox or any other process, stop only the PID you captured at spawn (`pid=$!`), never by name or pattern. Remove the sandbox artifacts directory it printed and drop any `git stash` entry you created (stashes are shared with other worktrees; leave others alone). `git status` must show only your intended changes.

## If verify cannot run

If `lua5.2`, `luac5.2` or Git is missing, or the sandbox is not available, run every part that can run and write in the PR which part did not run and why. Never write "verified" for a part that did not run; the sandbox and any behaviour in Minecraft itself stay with the owner.
