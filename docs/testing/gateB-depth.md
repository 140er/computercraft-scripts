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

## End-to-end flows (#50, #51, #52, #53)

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
  Repeat with two recipes for one output and multiple stocked tag members.
  Record the selected IDs and fingerprints. A chance-only output must block
  with `chance_only`, and a cycle must report its path. Repeat a saved progress
  event after reboot with a new transport counter. Produced and delivered
  totals must stay unchanged. Use a plan and warehouse load beyond the old
  32-site, 32-order, and 8-line caps and record the admitted bytes.
- Wizard: add a modded ore the system does not know. Answer the prompt on
  the board. Check that the ore is smelted or routed as answered, and that
  the answer survives a reboot. Also reboot midway through a route or recipe
  answer. The board must redisplay the question at the saved step with its
  partial answer and text. Repeated unknown reports must preserve that draft.
- Miner drop-off: a miner fills its inventory and delivers to the drop-off
  box the server knows, with no local drop-off config. Exact counts before
  and after.
- Dev mode: toggle auto-charge and auto drop-off live, per turtle and
  globally, and change thresholds. Behavior changes at once, without a
  reflash. The settings survive a server restart.
  Exercise `global`, `role`, and numeric computer scopes. Check global < role
  < computer precedence and removal of an override. Confirm that computer 17
  uses its persisted string key `"17"`.
- AR: the glasses show the shared positions and state from the server.

## Failure and edge cases (#53)

- Full chests.
- No fuel (turtle and furnace).
- Furnace removed mid-job.
- Turtle unloaded and chunk unload.
- Server restart mid-craft and mid-smelt.
- Two requests at once.
- Two layout uploads by one operator to different fields. Reboot and resume
  each by its upload ID. Let one expire and confirm that its retry reports
  `upload_expired` and leaves the published record intact.
- Crash after outbox save, after transmit, and after server commit. The client
  must restore the same envelope and counter, including the old boot identity.
  Neither the physical action nor its progress may count twice.
- Power loss at the charger.

## Hardening cases (#49, #54, #55)

These come from [the 2026-10-20 review](../review/judgment-2026-10-20.md).
Each one runs in gate A (CraftOS-PC sandbox, added to `tests\sandbox`) and,
where it involves the world, in gate B.

- Attacker: replayed request, captured secret, faked sender id, a fake server
  answering `rednet.lookup`/`rednet.host`, a huge counter.
  Check `requireMac=false` preserves legacy operations. Upgrade locally to true,
  then prove that v1 requests fail and config removal or rollback cannot
  downgrade the saved upgrade marker.
- Disk (H4, approved 2026-10-20): the real limits. Run once with a 1,000,000-byte server disk and
  realistic content (map chunks, journals, fleet records), and once with the
  limit read from `fs.getCapacity` on a larger disk. A failed save recovers.
  At the real 1 MB limit, lose cold-storage peers mid-run: data re-replicates,
  and unreachable cells stay unknown, never free. Hit the storage warning at
  1 MB, decline forgetting, enroll a turtle on the panel and check the data
  moves to it. Then pick `forget-old` and check that exactly the previewed data
  goes, and nothing else. A section changed after preview must survive and
  appear in the skipped list. Run the hub profile at 1000000 bytes too. Record
  the code bytes, both state copies, file allocation overhead, scratch, and
  the 65536-byte control reserve against the contract's budget table.
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
