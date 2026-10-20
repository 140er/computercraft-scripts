# PR 6 evidence

Gate A passed for bundle `8152c067`. Gate B is incomplete.

The final mock run passed 116 registered tests and the standalone SSOT, navigation, mining, and AR checks. See [mocks-final.log](mocks-final.log). The updater transport regressions include a failing run before the fixture correction in [regression-checks.txt](regression-checks.txt).

The final CraftOS run used six computers, three turtle emulators, virtual modems, and a 4,000,000-byte disk limit. It exercised the production server and hub, detach and reattach, server ownership recovery, and a complete CraftOS process restart. See [coverage.json](gateA/coverage.json) and [sandbox.log](gateA/sandbox.log). The run directory is `C:\Work\sbx-pr6\b6898016b8e54c0daa799219bc172ded`.

```powershell
C:\Tools\lua52\lua52.exe tests\run.lua
powershell -NoProfile -ExecutionPolicy Bypass -File tests\sandbox\run.ps1 -Scenario ar -Seconds 900 -DataRoot C:\Work\sbx-pr6 -Output C:\Work\gemini-input\p2\evidence\pr6\gateA\final-shared
```

The sandbox uses strict cc_ar mocks and module-level chat and installation fault injection. Its owners have separate controller stores. `tests/ar-shared-owner.lua` separately proves stale element removal against one shared store. That regression failed before the ownership fix. A native shared-controller run is still needed.

![CraftOS HUD](gateA/ar-hud-emulated.png)

This is a CraftOS screenshot of the emulated HUD, not a Minecraft goggles screenshot. It was captured before the final ownership cleanup change, which does not change the layout.

The first native attempt used `C:\Work\mc-ssot-pr6-8a9ce730`, ports 50882 and 50883, and the pinned installed mods. The server timed out during world startup before RCON became ready. No Lua probes or client screenshots ran. Its logs are in `C:\Work\gemini-input\p2\evidence\pr6\gateB\native-final`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\ingame\run.ps1 -Scenario ar -Client -Timeout 1800 -Output C:\Work\gemini-input\p2\evidence\pr6\gateB\final-shared
```

The native runner keeps renderer, client, and production ownership results separate. Rendering alone cannot pass the complete gate. Production recall and charging, all-role installation, and storage integration still need real-game verification.

PR 4 supplies the charging and warehouse boundary. PR 5 supplies view roles and the separate hub's ore snapshot. Those adapters report unavailable in this independent branch. Configured AR bounds record intent; the miner's existing mine and navigation bounds enforce movement limits.

The allowlist starts empty. Verified UUIDs must be enrolled locally. The updater has manual offline repair after interrupted file promotion; automatic reboot recovery is not claimed.
