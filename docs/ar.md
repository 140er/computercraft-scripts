# Configure the AR hub

Install the named **AR hub** role on a computer with a modem and a cc_ar `ar_controller`. Link cc_ar goggles to that controller. Use an AP `chat_box` for chat commands.

The AR role runs the existing hub. The server and hub keep their existing drawing ownership protocol. AR and chat start disabled.

The server renderer reads ore cells from its SSOT map. The hub fallback has fleet telemetry only. Ore rendering on a separate AR hub needs the PR 5 snapshot adapter.

Run these commands on the computer that owns the controller, then restart its program.

```text
server ar origin minecraft:overworld 100 64 -200
server ar enable on
server ar follow 12
server ar follow off
```

Replace `server` with `hub` on an AR hub. An origin has a dimension and world coordinates. A followed turtle must have a fresh, dimensioned position. If that position becomes unavailable, the HUD suppresses world geometry.

The local keys P, T, O, and A toggle the fleet cards, turtle boxes, ore boxes, and known-air boxes. H requests recall. R requests recharge. Press H or R twice within 30 seconds to confirm.

## Authorize chat

Obtain each player's UUID from a trusted server-side player record. Add the verified UUIDs for Jeffreyy2, njov10, and yolobeerman locally.

```text
server chat allow VERIFIED-UUID Jeffreyy2
server chat allow VERIFIED-UUID njov10
server chat allow VERIFIED-UUID yolobeerman
server chat enable on
```

`VERIFIED-UUID` is a placeholder. The allowlist starts empty. A display name never grants permission. Remove access with `server chat deny UUID`.

Authorized players can send `!hub`, `!recharge`, `!pro`, or `!xray`. Pro and x-ray also accept `on` or `off`. Each request returns a confirmation token that expires after 30 seconds. Confirm with `!confirm TOKEN`. A token works once.

AP leaves `!` commands visible in public chat. AP hides a message prefixed with `$` and passes its hidden status to the program. Use `$pro` and `$confirm TOKEN` for that path. Replies go to the requesting player.

Recall reports dispatch, which does not prove that a turtle reached home. Recharge reports unavailable until the PR 4 charging dispatcher is integrated.

## Set locations

```text
server chat bounds minecraft:overworld 0 -60 0 100 80 100
server chat spot warehouse supplies minecraft:overworld 10 64 12
server chat spot charging north minecraft:overworld 14 64 12
```

These commands persist AR configuration in `ar.cfg`. Spots become dimensioned anchor beams. They do not create warehouse routes or charging behavior in this independent branch.

The bounds entry records the requested mine bounds for integration. Existing PR 3 miner configuration still controls mining and navigation limits. Do not treat the AR bounds entry as enforcement.

Configure enforced bounds on each miner with the existing commands.

```text
miner mine bounds minecraft:overworld 0 -60 0 100 80 100
miner nav bounds minecraft:overworld 0 -60 0 100 80 100
```

## Install and repair a bundle

The installer appends named AR, warehouse, world-view, and Pro roles. It preserves the existing role order. Warehouse and view entrypoints report their missing PR 4 or PR 5 integration.

The updater fetches one release manifest and rejects mixed file versions. It stages dependencies before replacing scripts. An interrupted commit needs offline repair before normal use.

```text
update --repair
```

If the interruption left `update.lua` absent, run the staged copy.

```text
update.lua.fleet-stage --repair
```

Restart after repair. This is a manual recovery path, not automatic reboot recovery.

After changing a distributed Lua file, regenerate the manifest before testing or committing.

```powershell
C:\Tools\lua52\lua52.exe tests\make-bundle-manifest.lua
```
