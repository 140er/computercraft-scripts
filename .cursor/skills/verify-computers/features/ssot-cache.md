# Server cache

The fleet server boots on the default 1000000-byte disk, stays running, and mirrors its code cache onto that same disk without filling it.

## Sub-features

- `server-stays` boots `server install` with a small `ssot.cfg` and leaves the server running.
- `cache-fits` fetches the mirror into `server-code/` while `fs.getFreeSpace` stays at or above 0 and the screen never says `disk full`.

## How to get to it (user POV)

- Place the fleet server computer and run `server install`.
- Write `ssot.cfg` with the controller secret and reboot.
- Let the server pull its code mirror. The computer keeps running and still has free space.

## Driving it with verify-computers

Preconditions:

- Doctor printed `doctor PASS` and `capacity 1000000`.
- HTTP is on for this scenario only. The whitelist is `raw.githubusercontent.com` and `github.com`.

- **Cache boot.** Run `.cursor/skills/verify-computers/bin/verify-computers run ssot-cache`. The summary line is `server PASS`, `returned=false`, `capacity=1000000`, and `free` is at least 0.
- **Mirror.** `docs/evidence/verify-computers/ssot-cache-server.txt` lists at least one `server-code/` file, and the screen has no `disk full`.
- **State.** `docs/evidence/verify-computers/ssot-cache-server.state.txt` is present when the server wrote `server.state`. It must not contain `disk full` either. The judge reads it with the screen.

## Gotchas

- Current alpha logs `disk full: insufficient space` while the server process stays up. `disk full` is FAIL even though `returned=false`. Report it and do not change `server.lua` here.
- The server keeps about 65536 bytes spare before it will write a cached file. A mirror that stops early still fails when the state file records `disk full`.
- `textutils.serialize` of a large SSOT state can hit `Too long without yielding` in CraftOS-PC and finish quickly under `lua5.2`. That string is FAIL, and it is an emulator limit. Gate B confirms large maps.
- This scenario is the one place HTTP is enabled. A config or argument that mentions 100.91.208.60 stops the run.
