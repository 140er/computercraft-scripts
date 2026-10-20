# Gate B depth

Gate B is a real run on a disposable Minecraft test server with the real mod
jars and the real client. It never touches the live server or its RCON. This
file sets the minimum depth. A PR whose gate B falls short of it is not a pass.

## Setup

- Disposable server under a fresh root (`C:\Work\mc-<pr>-<random>`), real
  jars from the pack, its own free game and RCON ports, `-Xmx3G`.
- Hold `C:\Work\gemini-input\p2\gateB.lock` while the server or the shared
  client (`C:\mc-client`) runs. Stop only the java processes you started.
- Use the real client for screenshots (F2) and video.

## Scale

- Build the warehouse room in the world. Test several sizes, including one
  odd or irregular room (non-rectangular floor, a pillar or a step).
- Run several turtles at once, not one.
- Use real quantities: full stacks, partial stacks and mixed modded items.
  No single-item toy cases.

## End-to-end flows

Run each flow the way a player would, from the board or in-world, and read
the result from real inventories.

- Sorting and smelting: dump a mixed mining load (ores, raw metals, food,
  sand, dye, modded items) into the input. Check that it lands in chests, the
  furnace, the blast furnace and the smoker (if present), and collect the
  outputs.
- Crafting: request stained glass panes from sand and dye on the board.
  Check the exact pane count in the output chest. Run at least three more
  multi-step crafts that cross mods (Create, Create addons, Mekanism-style or
  whatever is in the pack). One of them must miss an ingredient and report
  clearly what is missing.
- Wizard: add a modded ore the system does not know. Answer the prompt on
  the board. Check that the ore is smelted or routed as answered, and that
  the answer survives a reboot.
- Miner drop-off: a miner fills its inventory and delivers to the drop-off
  box the server knows, with no local drop-off config. Exact counts before
  and after.
- Dev mode: toggle auto-charge and auto drop-off live, per turtle and
  globally, and change thresholds. Behavior changes at once, without a
  reflash. The settings survive a server restart.
- AR: the glasses show the shared positions and state from the server.

## Failure and edge cases

- Full chests.
- No fuel (turtle and furnace).
- Furnace removed mid-job.
- Turtle unloaded and chunk unload.
- Server restart mid-craft and mid-smelt.
- Two requests at once.
- Power loss at the charger.

## Hardening cases

These come from [the 2026-10-20 review](../review/judgment-2026-10-20.md).
Each one runs in gate A (CraftOS-PC sandbox, added to `tests\sandbox`) and,
where it involves the world, in gate B.

- Attacker: replayed request, captured secret, faked sender id, a fake server
  answering `rednet.lookup`/`rednet.host`, a huge counter.
- Disk: the real limits. Run once with a 1,000,000-byte server disk and
  realistic content (map chunks, journals, fleet records), and once with the
  limit read from `fs.getCapacity` on a larger disk. A failed save recovers.
- Event loss: a rednet burst during a save and during an HTTP call. No request
  is dropped and the timer still fires.
- Faults: a commit lost after a real move, the GPS host down, an ender modem
  removed, the disk full mid-move.
- Validator fuzzing: random and malformed messages against every validator.
- Updates: version skew between server and clients, and an update
  interrupted halfway, which must roll back to the last good version.
- Soak: at least 2 hours with 4 turtles, logging save time and state size over
  time. A box-side test server is fine for this.

## Evidence

- Before and after item counts, read through RCON or inventory APIs, in a
  table with exact numbers.
- Server log and CC logs.
- Real F2 screenshots of the room, the board and the wizard.
- At least one real video clip per PR of its main flow.
- Failed attempts stay in the evidence with what went wrong.

## Verdict

`GATES: PASS` only when every item above that applies to the PR ran. List
anything skipped with the reason. A skipped item means `GATES: FAIL`.
