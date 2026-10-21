# No server reply

A miner with SSOT turned on boots while the fleet server never answers. The miner stays on its running screen. It does not stop the program.

## Sub-features

- `miner-ssot-silent` writes a miner config with a spine and an SSOT server, boots, and leaves the program running.

## How to get to it (user POV)

- Run `miner setup 0 64 0 north` on a turtle.
- Set the miner config so SSOT points at a server id that is not running.
- Reboot the turtle. Nobody answers rednet.

## Driving it with verify-computers

Preconditions:

- Doctor printed `doctor PASS` and `capacity 1000000`.
- HTTP is off for this scenario. No server computer is booted beside the miner.

- **Boot with no reply.** Run `.cursor/skills/verify-computers/bin/verify-computers run no-server`. The summary line is `miner PASS`, `returned=false`, `capacity=1000000`, and `free` is at least 0.
- **Screen.** `docs/evidence/verify-computers/no-server-miner.txt` keeps the miner on screen for the whole wait. The screen has no `file.lua:line:` crash.

## Gotchas

- The config must include `spine`. Without it the miner sits in `Asking the hub which way to mine...` and never reaches SSOT boot, which hides this failure.
- The runner deletes `miner.cfg` and `miner.state` slot files before writing the config, so an atomic slot from `miner setup` cannot put the old config back.
- Current alpha reaches `/miner.lua` `SSOT timeout (stopped)` and the program returns. That crash line is FAIL. Report it and do not change `miner.lua` here.
- A crash whose text is only `Fleet control needs paired SSOT` is not this check. The SSOT timeout line is.
