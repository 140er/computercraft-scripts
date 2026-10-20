# Install alpha

One command on a fresh computer, turtle, or pocket computer.

```
wget run https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/alpha/install.lua
```

`install.lua`, `update.lua`, and `server.lua` on this branch download from `refs/heads/alpha`. A machine that already installed main keeps downloading main until you run the command above.

`install-shell.lua` takes a `base` argument. On this branch the default is the alpha URL.

The branch is https://github.com/140er/computercraft-scripts/tree/alpha. It is not merged into main.

# Turn a feature on

Every flag below defaults off. Set it to `true`, then reboot.

In `ssot.cfg`:

- `wh2 = { enabled = true }` turns on warehouse v2 dispatch and layout.
- `deadTurtles = true` with `deadAfterMs = 120000` marks a silent turtle missing.
- `compactSections = true` stores the map as schema 2 sections.
- `leaseV2 = true` turns on lease v2 on the server.
- `hubProfile = true` turns on the S1 hub profile.
- `planner = true` turns on the server planner screen.

On a miner, in `miner.cfg`:

- `wh2 = { enabled = true }` turns on fleet control.
- `nav.gpsFree = true` stops that turtle calling GPS for moves.
- `leaseV2 = true` and `offlineAutonomy = true` together wrap mining in the lease. The server flag has to be on as well.

On a store turtle, `gpsFree = true` in its config does the same for warehouse navigation.

Other files:

- Hub and panel wizard. `settings set wh2.enabled true`
- Factory craft. In `factory.cfg`, `wh2 = { enabled = true }`
- Planner tools on the panel, hub, and server. In `planner.cfg`, `enabled = true`
- AR planner. `arPlanner = true` on the host config. It also needs a player detector.
- AR goggles. `enabled = true` in `ar.cfg`. Chat stays off until `chatEnabled = true` in that same file. Names and UUIDs stay in `ssot.cfg` under `chatNames` and `chatUUIDs`.
- Views. `enabled = true` in `views.cfg`.
- Strata. Call `strata.new` with `strata = true`. Nothing in the boot path turns this on.
- Storage ledger. `storage-host.lua` stays off until `enabled = true` is passed to `create`.
- Peer cold storage. `storage-peer.lua` stays off until `peerStorage` is true and a mac and floppy key are present.

The server event queue from H3 is always on. It is how the server keeps fleet messages while a download runs.

# Files the installer does not copy

The updater only accepts a flat `name.lua` role file. Anything under `lib/stubs/` has to be copied by hand before you turn on the feature that loads it.

```
mkdir lib/stubs
wget https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/alpha/lib/stubs/b1_n1.lua lib/stubs/b1_n1.lua
wget https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/alpha/lib/stubs/b1_h1.lua lib/stubs/b1_h1.lua
wget https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/alpha/lib/stubs/b1_h4c.lua lib/stubs/b1_h4c.lua
wget https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/alpha/lib/stubs/b1_h5.lua lib/stubs/b1_h5.lua
wget https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/alpha/lib/stubs/b1_w1.lua lib/stubs/b1_w1.lua
wget https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/alpha/lib/stubs/h4d_dep.lua lib/stubs/h4d_dep.lua
```

Lease v2 needs the five `b1_` files. Peer storage needs `h4d_dep.lua`.

# What still runs on a stub

These stubs stay because the real module does not have the same functions.

- `lib/stubs/a1_planner_core.lua` and `lib/stubs/a1_chat.lua`. `planner-core.lua` is the mining planner. `chat-control.lua` accepts hub, recharge, pro, and xray.
- `lib/stubs/t2_dep.lua`. `planner-tools.lua` needs `mint`, `pos`, and `style`, which `planner-core.lua` does not export.
- `lib/stubs/b2_dep.lua`. The B1 lease record is not the problem journal this module calls.
- `lib/stubs/h4b2_h4b1.lua`, `lib/stubs/h4b2_h1.lua`, and `lib/stubs/h4b2_b1.lua`. `mapstore.lua` has no `sectionSlot`. H1 is not in alpha.
- `lib/stubs/layout_dep.lua`. Layout observation reads schema 1 chunks. The compact section store is a different shape.
- `lib/stubs/craft_dep.lua`. Craft uses `wh2-layout.lua` `reserveCraft` when that function exists, and `wh2-client.lua` for class lookup. `register` stays on the stub.
- `lib/stubs/h4c_dep.lua`. The H4a usage helper stays here. H4a is not in alpha.
- `lib/stubs/b1_h1.lua`, `b1_h4c.lua`, `b1_h5.lua`, `b1_n1.lua`, and `b1_w1.lua`. `position.lua` does not export the copy and compare helpers B1 calls. H1 stays out.
- `s1_t1.lua`, `s1_h4c.lua`, `s1_i1.lua`, and `s1_b1.lua`. These check stored hub records. The real planner, ledger, enrol, and lease modules do not export that shape.
- `lib/stubs/h4d_dep.lua`. H4a capacity, the H4b1 section codec, the B2 offline-lease bit, and the H1 mac stay here.

# Not in this branch

- H1H2, pull request 77. Signing stays `pending-h1h2`.
- H4a. There is no pull request.

# Checks

`lua5.2 tests/run.lua` printed `371 tests passed`. The same run also printed `13 h4d tests passed`, `21 wizard state tests passed`, `8 wizard contract3 tests passed`, `Wizard board 29 passed, 0 failed`, and `Wizard host 14 passed, 0 failed`. CraftOS-PC is not installed on the machine that built this branch, so the sandbox scenarios were not run here.

The ssot sandbox scenario has a known timeout on main. The scan is `ssot-runtime.lua` line 388, 10000 cells.

`tests/sandbox/run.ps1` does not list the wizard or h3 scenarios. `tests/sandbox/driver.lua` can start `h3` and `h3-burst` when the scenario name is passed in. The Lua unit files cover those programs.

Gate B is not required for this branch. `tests/ingame/run.ps1` on alpha includes the main fix that loads every live jar. That came in with pull request 60, merge `5140e2c`.

# Setup without editing a cfg

`plug.lua` fills a missing value. A value already in the cfg wins. A saved answer wins next. Discovery runs only when both are absent. The program writes the answer into that same cfg. Feature flags stay as they were.

A fleet secret comes from `install.cfg` `pairingKey`, or from the enrol copy code the server already prints. The client derives the key. The server copies a paired key into an empty `ssot.cfg` controller slot. A slot that already has a secret stays. Keys stay off the screen. A missing `ssot.cfg` stays missing.

- Miner. GPS supplies home. The turtle turns until a chest, barrel, or shulker is behind it, to its right, or to its left. When `ssot.enabled` is already true, `rednet.lookup` supplies the fleet server id, and the pairing key or an enrol code supplies the secret. Asked once when GPS is absent, for coordinates and facing. Asked once when SSOT is on and the dimension is missing. The tunnel direction stays unset. `ssot.enabled` stays as it was.
- Store and warehouse. Lookup supplies the server id. The pairing key or an enrol code supplies the secret. GPS supplies the pose with heading 0. Asked once when lookup finds several servers or none, when no pairing key is saved, when the dimension is missing, and when `store pose` has no GPS fix. Bounds stay on `store bounds`. A fleet bootstrap that already set the server skips this fill.
- Factory. GPS supplies the position. Front stays the pickup side and bottom stays the parts side when those sides are inventories. Asked once for coordinates when GPS fails, and for a side when that side is not an inventory.
- Farmer. The turtle turns until a chest is next to it. Asked once for the row count, the row width, and left or right. `farmer drop` with no numbers asks once for forward, right, and up.
- Lumber. The turtle turns until a chest is behind it, saves radius 48, and writes `startup.lua`. Nothing is asked. `lumber setup` still changes the radius.
- Lava. The turtle turns until a chest is behind it. GPS supplies home and facing. Asked once when GPS fails, for coordinates and facing. Drop chests stay on `lava add`. The lava pool stays on `lava pool`.
- Builder. GPS supplies home. Asked once for facing, and for coordinates when GPS fails. Cancelling the coordinate prompt keeps the local frame at 0, 0, 0.
- Buddy. Asked once for its own model address, or for an xAI key. The key is hidden while it is typed and is Buddy's own key. The program prints `Key saved in api.key.`
- Roomsorter. One colour monitor is used as found. Asked once when several monitors are attached. The name is saved as `room.cfg` `monitor`. A name already in that file wins. The room scan still finds the chests.
- Panel. One lookup hit is used and left unsaved. Asked once when several hosts answer. The pick is saved under `panel.cfg` `hosts`. Other keys in that file stay. An id already in `hosts` wins.
- Planner. When the panel or hub program is running, `enabled` is already true, and `server` is missing, lookup supplies the server id and only that field is written. Asked once when lookup finds several servers or none. `enabled` stays as it was. Loading the file as a library skips the prompt.
- Storage. `storage-peer.lua` already makes its own key. No server id, side, or chest name has to be typed into a cfg. `peerStorage` stays off.
- Server. The existing screen pick still chooses the largest colour monitor. Pairing keys already in `enrol.store` fill empty controller slots. Nothing new is asked.
- GPS host. Typed coordinates and a saved `gpshost.cfg` win. Asked once for the x, y, and z of this computer. The host is the GPS reference, so the fix is typed.

Views pairing, hub pairing, and the enrol protocol are unchanged.

# Merges

Each line is the merge commit on alpha.

- `f2b149fa35e5b942abf41fa30ff1455187fc905e` feat/wh2-base
- `34f9c8b53d71b62e19da9a61540d07af075c8dfa` feat/ssot-pr6, pull request 28
- `08923ccd715aa2544fb6733ca0b38fac2a7fcbfd` feat/ssot-pr5, pull request 29
- `e36c21bbb748f193a4be9db1336e900f30b27ed3` feat/i1-installer-cloud, pull request 61
- `673b9646078876f669c395195400ac88c267605d` feat/h4-p0, pull request 66
- `d1bf44803b691ebb9fd9d5410c787af370b33e66` feat/t1-planner-cloud, pull request 62
- `e70b36628fb1276a192a663c99bdf8d17a4eed9e` feat/h5-dead-turtles-cloud, pull request 63
- `a906f32c5a82c34dd2299c0ed91476a1353bae7c` feat/wh2-fleet, pull request 64
- `150bb8efae7860b70eb0e336c90230e641c70493` feat/craft-swarm, pull request 74
- `e33c8834b63c5c01b61b847eb00a710cc25cbc53` feat/wh2-wizard, pull request 65
- `70f795d1e4cced701b08ab22d4c835647663b60f` feat/i2-swarm, pull request 67
- `6cbf20bb0f66ff93ba03a903a7bc6930c557fab5` feat/h4-h4b1-cloud, pull request 70
- `5a40e1fc02cd1222acc7f809e8aabe8833c1a38b` feat/h4b2-swarm, pull request 76
- `1a2c4e79e7b3f5e0be45c4a23f58966086b6d009` feat/layout-swarm, pull request 75
- `548edf30d3bfa518e473ee7c1b8946fb08b03c02` feat/h4c-swarm, pull request 68
- `936ae6ecd11d528bca8e54ba94bb61cd9272e646` feat/hard-h3, pull request 73
- `fc6be9371eaeabc6d8010e4598e56ae2fc7347fd` feat/a1-swarm, pull request 69
- `f0903836d14b8c7ee7c620e265c7bef8216d1630` feat/t2-swarm, pull request 71
- `72edfb965e1a0a3836394cfef9a60fc7aa56e717` feat/b2-swarm, pull request 72
- `f68a9353e9e3a2b9f76bada2bdabbcfb1ae04c91` feat/n1-cloud, pull request 81
- `3d62b8d0de3b470f1aa6e8fdb8e9520ff057b51d` feat/b1-swarm, pull request 78
- `9f114ebc1a2bee0f93ffa1c1c3770594fe335b94` feat/s1-swarm, pull request 79
- `8835b369a789f9defbdb6e168b3a14f85b2a49bb` feat/h4d-swarm, pull request 80
- `04b5ec31cee4cfc6bac82fd09f8f10c434d65664` main, including pull request 60 at `5140e2c`
