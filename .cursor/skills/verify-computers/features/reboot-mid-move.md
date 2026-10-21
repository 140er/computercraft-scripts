# Reboot mid-move

A miner reboots with an unfinished move still in its state. It stays running and does not abandon the journal by crashing back to the shell.

## Sub-features

- `pending-move` writes a miner state whose `pending` move is still open, then boots SSOT.

## How to get to it (user POV)

- The miner is in the middle of `turtle.forward` when the chunk unloads or the turtle reboots.
- On the next boot the miner still has that pending move.
- The player finds the miner running, not stopped on a crash line.

## Driving it with verify-computers

Preconditions:

- Doctor printed `doctor PASS` and `capacity 1000000`.
- No fleet server is booted. GPS answers from the fake turtle world.

- **Reboot.** Run `.cursor/skills/verify-computers/bin/verify-computers run reboot-mid-move`. The summary line is `miner PASS`, `returned=false`, `capacity=1000000`, and `free` is at least 0.
- **Screen.** `docs/evidence/verify-computers/reboot-mid-move-miner.txt` has no `file.lua:line:` crash.

## Gotchas

- The planted state is `{pending={d=0,fuel=10000},pos={x=0,y=64,z=0},h=0}` next to a config that sets `spine` and SSOT. Slot files from the installer are removed first.
- Current alpha stops with `Resolve the miner movement journal before SSOT boot` and the program returns. That line is FAIL. Report it and do not change `miner.lua` here.
- `loadTable` reads `path` and `path.tmp`. A pending move that exists only in an `.a` or `.b` slot is not this boot.
