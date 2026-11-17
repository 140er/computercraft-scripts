# Review guide

Lua scripts for CC: Tweaked turtles and computers (mining fleet, storage room, farms, pocket panel). Merging to `main` makes every live in-game computer and turtle download the new code, so a script that does not load, loops forever, or loses a turtle's state breaks the running fleet.

Severity tags: **Important** = blocks merge. **Nit** = mention, never blocks. **Pre-existing** = problem already on the base branch; note it, never block this PR for it.

## Important

- Rollout safety: new behaviour must sit behind a config flag that defaults to off, unless it is a pure server-side addition that is safe by itself. Check that the default path behaves exactly as before for already-running computers.
- Script must still load in CC: top-level `local` count (CC counts locals of all enclosing functions together and fails over 200; `roomsorter.lua` and `miner.lua` are close), compile errors, Lua 5.1-based runtime limits. A file that does not compile bricks every machine that updates to it.
- Update and install paths (`update.lua`, `install.lua`, `server.lua` file serving, `hub.lua` hand-out to turtles): downloads must be checked with `load` before replacing a working file; hash/offset/size checks stay intact; `install reset` and any `fs.delete` stay limited to what they list and keep `rom` and `install.lua`.
- Wire protocols (rednet `minearmy`, `fleetserver`, `roomsorter`, `turtlefactory`, `builder`): changing a message shape must keep old turtles and computers working, since fleets update at different times (turtles update only when home). Look for new required fields, renamed `type` values, and unvalidated `msg` fields.
- Saved state (`hub.state`, `server.state`, `miner.cfg`, per-bot state files): old files must still load; saves must stay atomic (temp file + move + backup) and must not serialize shared or cyclic tables (`Cannot serialize table with repeated entries` happened). Watch the 1 MB-class disk limit when logs or caches grow.
- Turtle movement and mining: position/heading tracking after failed moves, reboots mid-turn, chunk unloads and `LOST` recovery; digging into lava or water; refuel and return-home thresholds; a loop with no `sleep`/yield or no exit that can hang a turtle in a shaft.
- Hub/server orders (go, recall, update, rename, reset, forget): a recall or pause must always win; orders are retried until acked, so check duplicates and ordering do not restart a recalled miner.
- Dev console (`devCommand` in `hub.lua` and `builder.lua`, `panel.lua`): `put`, `rm`, `lua` need `dev.key`; `api.key` and `dev.key` are never sent or logged; pairing stays limited to a pocket within 3 blocks.
- Secrets and addresses: no API keys, server addresses, RCON details or personal names in code, docs, tests or evidence files.
- Bug fixes need a test that fails on the base and passes on the head (mock tests in `tests/`), unless the behaviour only exists in Minecraft; then the PR must say what the owner has to check in game.

## Nit

- Redraw cost on monitors and AR goggles (full clears every second, many draw calls); prefer deleting changed elements over clearing.
- README sections left stale by a behaviour change; prose that is long or restates the code.
- Style drift from the surrounding file (naming, long functions); extra top-level locals that a table would hold.

## Pre-existing

- Gate A (CraftOS-PC sandbox) is Windows-only and Gate B needs a local Minecraft test server; neither runs in a Linux review. Do not block a PR for missing evidence of something only those gates cover, if the PR says so.
- `tests/run.lua` compares against the local `main` ref and has coverage only for `hub.lua`, `server.lua` and `miner.lua`; the other scripts have no automated tests.
- Many very long files (`roomsorter.lua`, `miner.lua`, `panel.lua`) and the local-count pressure in them.
- Report other pre-existing problems as Pre-existing, not Important.

## Rules the reviewer enforces

- The PR ran the verify skill (`.claude/skills/verify/SKILL.md`) or says why it could not; claims of "verified" need evidence in the PR body.
- A PR never changes the checks or rules that judge it (REVIEW.md, merge-gate or check config, CI recipes, test thresholds) to make itself pass. The gate reads REVIEW.md from the base branch, never from the PR head.
- No secrets, tokens or credentials in code, logs, fixtures, commits or PR text.
