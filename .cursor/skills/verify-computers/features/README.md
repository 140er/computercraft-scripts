# Computer verification map

This directory is the source for the computercraft-scripts self-test. Read it before a run, then follow the feature file for the scenario you are proving.

## Baseline preconditions

- The checkout is the branch under test. `main`, `alpha`, and every other branch use the same 1000000-byte disk.
- `lua5.2` is on `PATH`. CraftOS-PC v2.8.3 is installed by `verify-computers doctor`, with sha256 `f25536c7a05f67827fe44573ff65627cbe595e13c75815ef86a4e1f3bd33a88c`.
- Doctor has printed `capacity 1000000` and `doctor PASS`.
- No other `verify-computers run` is using `docs/evidence/verify-computers/`.
- The live server 100.91.208.60 is never contacted. HTTP, when a scenario turns it on, is limited to `raw.githubusercontent.com` and `github.com`.

## Driving conventions

- Start from the baseline. Each scenario builds a fresh disk and deletes it on the way out.
- Run scenarios through `.cursor/skills/verify-computers/bin/verify-computers`.
- Treat the commands as literal.
- A FAIL on the 1000000-byte disk stays a FAIL. Do not raise the disk limit and do not skip server, hub, miner, store, roomclient, roomsorter, lumber, or panel.
- Leave the files in `docs/evidence/verify-computers/` after cleanup.

## Proof and skip reporting

- Capture the install, the boot, the screen, and the free-byte line.
- Quote the `VERIFY:` line and the role line from `SUMMARY.txt`.
- A skipped role is not covered by a different role.
- An alpha failure is a finding. Do not edit the role program to make the line pass.

## Feature entry contract

Each feature file has an H1, one paragraph, and these four H2 sections in order.

1. `Sub-features`
2. `How to get to it (user POV)`
3. `Driving it with verify-computers`
4. `Gotchas`

## Features

- [Role boot](./role-boot.md) boots all eight roles from the installer on an empty 1000000-byte disk.
- [No server reply](./no-server.md) boots a miner whose SSOT server never answers.
- [Late storage turtle](./late-turtle.md) boots the order computer, then starts the storage turtle 25 seconds later.
- [Reboot mid-move](./reboot-mid-move.md) boots a miner that still has an unfinished move.
- [Server cache](./ssot-cache.md) boots the fleet server and lets it mirror code onto the 1000000-byte disk.
