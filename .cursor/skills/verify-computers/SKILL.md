---
name: verify-computers
description: "Self-test computercraft-scripts in CraftOS-PC 2.8.3 headless before review. Boots each role from a fresh 1000000-byte disk and runs the no-server, late-turtle, reboot, and server-cache scenarios. Use before asking for review, and when a change can miss the default disk."
---

# Verify computers

Self-test for computercraft-scripts. It installs CraftOS-PC 2.8.3 headless, boots each role from the real installer on a fresh 1000000-byte disk, and prints PASS or FAIL with the free bytes left on that disk.

Run this before review. Gate B is still the last gate. Follow `.cursor/skills/gate-b/SKILL.md` on the Windows worker for the in-game run. Never connect to the live server 100.91.208.60 or its RCON.

`main`, `alpha`, and every other branch must fit and run on the default 1000000-byte disk. A role that fails on that disk is FAIL. A future server-only build may use a larger disk. server, hub, miner, store, roomclient, roomsorter, lumber, and panel may not.

## Launch

Install once on a Linux cloud VM.

```bash
sudo apt-get install -y lua5.2 libfuse2
```

Ubuntu 24 ships that fuse library as `libfuse2t64`. The AppImage extract needs `libfuse.so.2`.

```bash
mkdir -p "$HOME/.cache/computercraft-sandbox/craftos-2.8.3-linux"
curl -fsSL -o "$HOME/.cache/computercraft-sandbox/craftos-2.8.3-linux/CraftOS-PC.x86_64.AppImage" \
  https://github.com/MCJack123/craftos2/releases/download/v2.8.3/CraftOS-PC.x86_64.AppImage
echo "f25536c7a05f67827fe44573ff65627cbe595e13c75815ef86a4e1f3bd33a88c  $HOME/.cache/computercraft-sandbox/craftos-2.8.3-linux/CraftOS-PC.x86_64.AppImage" | sha256sum -c
chmod +x "$HOME/.cache/computercraft-sandbox/craftos-2.8.3-linux/CraftOS-PC.x86_64.AppImage"
( cd "$HOME/.cache/computercraft-sandbox/craftos-2.8.3-linux" && ./CraftOS-PC.x86_64.AppImage --appimage-extract )
```

The binary is `squashfs-root/AppRun`. `AppRun --version` prints `CraftOS-PC v2.8.3`. The ROM file `squashfs-root/usr/share/craftos/rom/help/changelog.md` contains the line `Updated CC:T version to 1.112.0`.

`verify-computers doctor` and `verify-computers run` download and extract that pin when the cache is empty. They stop if the checksum differs.

Each drive gets a new temp directory. The config sets `standardsMode` true and `computerSpaceLimit` 1000000, so `fs.getCapacity` reports 1000000. It also sets `checkUpdates` false, `keepOpenOnShutdown` false, `logErrors` true, `clockSpeed` 20, and `abortTimeout` 17000. HTTP stays off except the server-cache scenario. The whitelist is `raw.githubusercontent.com` and `github.com`.

Ready means doctor prints `capacity 1000000` and `doctor PASS`.

Run one verification at a time. The runs share `docs/evidence/verify-computers/`.

## Doctor

```bash
.cursor/skills/verify-computers/bin/verify-computers doctor
```

Doctor checks the pinned checksum, the CraftOS-PC version line, the CC:Tweaked 1.112.0 changelog line, `lua5.2`, every role file named by `bundle-manifest.lua`, and a one-shot computer whose capacity is 1000000. It does not boot the roles.

## Drive

```bash
.cursor/skills/verify-computers/bin/verify-computers run
.cursor/skills/verify-computers/bin/verify-computers run role-boot
.cursor/skills/verify-computers/bin/verify-computers run role-boot miner
.cursor/skills/verify-computers/bin/verify-computers run no-server
.cursor/skills/verify-computers/bin/verify-computers run late-turtle
.cursor/skills/verify-computers/bin/verify-computers run reboot-mid-move
.cursor/skills/verify-computers/bin/verify-computers run ssot-cache
.cursor/skills/verify-computers/bin/verify-computers run mocks
```

`run` with no arguments runs `lua5.2 tests/run.lua` and every scenario below. Exit 0 means every line is PASS. Exit 1 means at least one FAIL. The closing lines of stdout are the same text as `docs/evidence/verify-computers/SUMMARY.txt`.

A role disk is built in three steps.

1. Copy that role's file list from `bundle-manifest.lua`.
2. Run that role's install command on computer 0.
3. Boot the `startup.lua` the installer wrote.

Install commands:

- server runs `server install`
- hub runs `hub install`
- miner runs `miner setup 0 64 0 north`
- store runs `store install`
- roomclient runs `roomsorter install client`
- roomsorter runs `roomsorter install`
- lumber runs `lumber setup 48`
- panel runs `panel install`

Turtle roles load `.cursor/skills/verify-computers/bin/turtle-pre.lua` before the install command and again before boot. CraftOS-PC has no turtle API.

The read-only mount `/verify` is this skill's `bin` directory. Those files sit outside the 1000000-byte disk. `fs.getFreeSpace("/verify")` is 0.

The pass screen for each scenario is in `features/`.

## Evidence

Proof is written to `docs/evidence/verify-computers/`.

- `SUMMARY.txt` records the CraftOS pin, the ROM line, the git revision, and `exempt none`. It ends with `VERIFY: PASS` or `VERIFY: FAIL` and one line per check.
- A role line looks like `server PASS free=409389 capacity=1000000 returned=false bytes=588043`.
- `role-boot-<role>.txt`, `no-server-miner.txt`, `reboot-mid-move-miner.txt`, `late-turtle-roomclient.txt`, and `ssot-cache-server.txt` are the emulator dumps. Each dump has capacity, free space, the on-disk file list, and the screen.
- `late-turtle-turtle-up.txt` records whether computer 1 started.
- `ssot-cache-server.state.txt` is `server.state` when the server wrote one.
- `mock-suite.txt` is the transcript of `lua5.2 tests/run.lua`.

PASS requires capacity 1000000, manifest bytes at or under 1000000, free space at or above 0, a startup file that contains `shell.run`, and a screen with no `disk full`, no `Too long without yielding`, no `file.lua:line:` crash, and no `Type an answer and press enter.`

`fit` passes when that screen is clean, including when the program returns. `stay` passes when the program is still running. `order` passes when the screen contains `ORDER`. `cache` passes when the server is still running and the disk contains `server-code/`. A `disk full` line fails `cache` on its own.

`lua5.2 tests/run.lua` does not boot CraftOS-PC.

## Cleanup

```bash
.cursor/skills/verify-computers/bin/verify-computers cleanup
```

Cleanup kills the CraftOS-PC pid this skill started, and only when that pid's command line contains `AppRun`. It then deletes that run's temp directory under `/tmp`. It leaves every other CraftOS-PC process alone.

`run` and `doctor` already clean up on the way out. Run `cleanup` again after a run that was killed. The second run is safe.

`docs/evidence/verify-computers/` stays in place. Cleanup does not delete `SUMMARY.txt` or the scenario dumps.

## Helpers

`.cursor/skills/verify-computers/bin/verify-computers` is the command. The Lua files beside it are loaded by that command.

- `plan.lua` reads `bundle-manifest.lua` and prints the role file list, the install words, and the doctor file check.
- `judge.lua` reads one result dump and prints the PASS or FAIL line.
- `wrap.lua` is what computer 0 boots. It runs the installer's startup, then writes `result.txt`.
- `turtle-pre.lua` and `world.lua` provide `turtle` inside CraftOS-PC.
- `fake-turtle.lua` is computer 1 in the late-turtle scenario. It waits 25 seconds, then answers the roomsorter protocol.

## Emulator limits

`fs.getFreeSpace` is the number that matches the disk limit. CraftOS-PC still accepts a raw write past that limit. The host adds the manifest file sizes and fails a role whose sum is over 1000000.

`textutils.serialize` of a large state can abort with `Too long without yielding` in CraftOS-PC. The same serializer finishes under plain Lua 5.2. Report that abort as an emulator limit, and still let the judge mark it FAIL. Confirm a large map with gate B.

Headless CraftOS-PC does not boot `computer/1` by itself. The late-turtle wrapper calls `periphemu.create(1, "computer")`, and that computer's startup is `fake-turtle.lua` copied onto its disk.

CraftOS-PC modems report `isWireless()` false. The wrapper reports true so the client takes the wireless path used in-game.

CraftOS-PC 2.8.3 has no monitor peripheral and no pocket computer. A scenario that needs a monitor gets a 36 by 24 window. Panel boots as an advanced computer because `config/0.json` sets `isColor` true.

`shell` is absent from `_G`. The boot file is `shell.run("/verify/wrap.lua")`. Loading that wrapper with `dofile` fails.
