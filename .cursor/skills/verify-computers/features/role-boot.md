# Role boot

A player places a fresh computer or turtle, runs that role's install command, and reboots. The role program comes up on the default 1000000-byte disk and does not crash, fill the disk, or stop to ask a question.

## Sub-features

- `boot-server` installs with `server install` and stays up.
- `boot-hub` installs with `hub install` and stays up.
- `boot-miner` installs with `miner setup 0 64 0 north` and stays up while it asks the hub which way to mine.
- `boot-store` installs with `store install` and runs without waiting on the keyboard.
- `boot-roomclient` installs with `roomsorter install client` and either shows ORDER or returns a finished screen.
- `boot-roomsorter` installs with `roomsorter install` and shows the idle turtle screen.
- `boot-lumber` installs with `lumber setup 48` and stays on its running screen.
- `boot-panel` installs with `panel install` and draws the panel on the advanced computer.

## How to get to it (user POV)

- Place a computer, run `server install`, and reboot.
- Place a computer, run `hub install`, and reboot.
- Place a turtle, run `miner setup 0 64 0 north`, and reboot.
- Place a turtle, run `store install`, and reboot.
- Place a computer with a wireless modem, run `roomsorter install client`, and reboot.
- Place a turtle, run `roomsorter install`, and reboot.
- Place a turtle, run `lumber setup 48`, and reboot.
- Place an advanced computer, run `panel install`, and reboot.

## Driving it with verify-computers

Preconditions:

- Doctor printed `doctor PASS` and `capacity 1000000`.
- The temp disk for this run starts empty.

- **All eight roles.** Run `.cursor/skills/verify-computers/bin/verify-computers run role-boot`. Each role line in `docs/evidence/verify-computers/SUMMARY.txt` is PASS, `capacity=1000000`, and `free` is at least 0.
- **One role.** Run `.cursor/skills/verify-computers/bin/verify-computers run role-boot server`. The summary contains one `server PASS` line and `docs/evidence/verify-computers/role-boot-server.txt` shows the screen after boot.
- **Disk proof.** Open `role-boot-<role>.txt`. The capacity line is `capacity 1000000`, the file list has no `disk full`, and the screen section has no `file.lua:line:` crash.

## Gotchas

- The file list comes from `bundle-manifest.lua`. The disk also gets `bundle-manifest.lua` and `.fleet-role`, which `update.lua` apply writes on a real install. An install command that returns without writing `startup.lua` is FAIL, with the reason `install did not write startup`.
- Store on current alpha prints `Type an answer and press enter.` after `store install` and waits for a fleet server id. That line is FAIL. Leave `store.lua` unchanged and report it.
- Roomclient with no turtle returns after `No storage turtle found`. That clean return can PASS `fit`. It does not prove the late-turtle scenario.
- Hub's free space is the tight one. A few thousand bytes free is still PASS. Free space below 0 is FAIL.
- Copying files from the host can land more than 1000000 bytes, because CraftOS-PC does not refuse that write. The host byte sum is what fails the role.
- Panel is an advanced computer, `isColor` true. This emulator has no pocket computer.
- `Too long without yielding` on the screen is FAIL, and it is an emulator limit. Confirm large saves with gate B.
