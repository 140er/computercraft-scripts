PR 3 evidence

Both gates passed against the same production Lua. The authoritative directories are `C:\Work\gemini-input\p2\evidence\pr3\gateA\renewal-final` and `C:\Work\gemini-input\p2\evidence\pr3\gateB\native-final`. Earlier directories retain failures and superseded runs.

Gate A used seven computers, three turtle emulators, and four-megabyte disks. It exercised the production server and hub, duplicate lease packets, a dropped acknowledgement, process restart during a vein and during resume, ownership expiry, inventory and fuel interrupts, hazards, blocked return paths, and traversal crash checkpoints. The world recorded 134 moves and zero collisions. The miners collected 46 ore blocks. Three isolated gap ores remained. The regression suite also passed 97 tests plus the mining checks.

Run the checks from the repository root.

```powershell
C:\Tools\lua52\lua52.exe tests\run.lua
powershell -NoProfile -ExecutionPolicy Bypass -File tests\sandbox\run.ps1 -Scenario mining -Seconds 1800 -Output C:\Work\gemini-input\p2\evidence\pr3\gateA\renewal-final
powershell -NoProfile -ExecutionPolicy Bypass -File tests\ingame\run.ps1 -Scenario mining -Client -Timeout 1200 -Output C:\Work\gemini-input\p2\evidence\pr3\gateB\native-final
```

The legacy smoke scenario passed with a 180-second run. `tests\review-capture.ps1` captured the unchanged hub. These artifacts are under the full Gate A directory's `smoke-final` and `capture` siblings.

Gate B used real turtles with the pinned mods. One miner returned on low fuel and refueled from a real coal item. Another returned with a full inventory. The fixture removed only injected stone and preserved its diamonds. All three paused with durable traversal state. The fixture removed their ender upgrades, observed the chunk unload through a numeric RCON query, restarted Minecraft, restored the upgrades, and resumed work. All three finished at their configured home poses and headings.

The native block queries passed positive and negative controls. They verified 46 removed ores, three untouched gap ores, and preserved bedrock. The inventories contained 12, 22, and 12 diamonds. [gateB-mining.json](gateB-mining.json), [blocks.json](blocks.json), [rcon.txt](rcon.txt), and [durable-state.txt](durable-state.txt) retain those checks. [matching-sources.txt](matching-sources.txt) confirms both gates used the committed production hashes.

The test coordinator needed a reboot to collect completion ACKs after unloading. [coordinator-reboot.txt](coordinator-reboot.txt) records the manual commands. The runner now performs those same commands after all three miners report completion. No mining result was supplied by hand.

[mining-before.png](mining-before.png) and [mining-after.png](mining-after.png) are real Minecraft F2 captures. No motion clip was recorded.

The decision trail is [decisions.tsv](decisions.tsv). [work.md](work.md) records the design alternatives and review constraints. The failed-before tests are [dig-move-red.txt](dig-move-red.txt) and [expired-owner-red.txt](expired-owner-red.txt). [source-sha256.json](source-sha256.json) lists the production hashes after LF normalization.

Mining defaults off. Active expired tasks remain with their owner. Bounds and home poses have in-game commands. Spacing 4 and zone boundaries can leave ore untouched. Unloading, proximity charging, and warehouse poses belong to PR 4. Automatic hub-update completion is not connected to the opt-in mining loop. The turtle shell can apply updates at home.

The PR 1 rules require one agent and one model. The review was local. The deslop skill was unavailable. No live server was used. No merge was performed.
