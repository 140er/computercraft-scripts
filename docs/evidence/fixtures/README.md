# Fixture run evidence

This folder is the 2026-10-20 run of `python3 -m tests.ingame.fixtures.validate --port 25575 --server-dir /tmp/gateb-server --restart` on this VM. The host was `127.0.0.1`. The password stayed in `/tmp/gateb-server/rcon.password`. A search of this folder found no copy of it.

The server was NeoForge 21.1.259 with one public mod jar, `cc-tweaked-1.21.1-forge-1.120.2.jar`. `jars.json` records sha256 `e8651fe24b384e925e563c9ad077644744474e2e7c0adb8e6d5b4757598dce9f` and `computer_space_limit = 1000000`.

`rcon.txt` line 5 forceloaded the small room. Line 8 filled air from `7 64 6` to `13 67 13` and the reply was `Successfully filled 105 block(s)`. That box includes the north door pad at z 6. Line 3960 ran `tick freeze` and the reply was `The game is frozen`. Item replaces ran after that freeze.

`counts-after.md` lines 7 to 13 are the mixed drop-off chest. Slot 0 cobblestone went from 64 to 50. Slot 4 `computercraft:disk` stayed 1. Slot 5 `computercraft:cable` stayed 16. Lines 14 and 15 are the furnace, which was removed, so raw iron 8 and coal 3 became 0. Line 17 blast-furnace coal stayed 2. Line 19 smoker coal stayed 1. The empty-container section lists the turtle and the four unused drop-off chests.

`counts-restart.md` compares a scan taken after the blast furnace and smoker fuel slots were cleared with the scan after the restart callback. Every listed delta is 0. `faults.json` records turtle fuel 250 to 0, a cobblestone chest total of 1728, and `Unmarked chunk [25, 0] in Overworld for force loading` with `unloaded` true after 1 poll.

`latest.log` is the process the restart callback started. Line 18 names CC: Tweaked 1.120.2. Line 46 is `Done (0.414s)`. Line 49 is `RCON running on 127.0.0.1:25575`.

`custom-mods.json` lists `turtlebattery`, `recipe_index` and `turtlematicfix` with `present` false and `public` false. There is no download URL.

No player joined. `summary.json` records `There are 0 of a max of 1 players online:`. There are no client screenshots.
