# Configure the AR hub

Install the named **AR hub** role on a computer with a modem and a cc_ar `ar_controller`. Link cc_ar goggles to that controller. Use an AP `chat_box` for chat commands.

The AR role runs the existing hub. AR and chat start disabled. Shared-controller ownership requires a paired hub and an enrolled player.

The server renderer reads ore cells from its SSOT map. The hub fallback has fleet telemetry only. Ore rendering on a separate AR hub needs the PR 5 snapshot adapter.

The installed cc_ar 0.2.1 build depth-tests its 3D lines and text. The `xray` commands select world geometry; the installed renderer cannot show it through walls. The HUD says `Outlines stop at blocks`. Its Lua API also exposes no wearer identity, equipped status, removal event, or unlink operation. Controller detach is detectable, but taking off goggles is not. These requirements remain unmet.

Run these commands on the computer that owns the controller, then restart its program.

```text
server ar origin minecraft:overworld 100 64 -200
server ar enable on
server ar follow 12
server ar follow off
```

Replace `server` with `hub` on an AR hub. An origin has a dimension and world coordinates. A followed turtle must have a fresh, dimensioned position. If that position becomes unavailable, the HUD suppresses world geometry.

Shift+P, Shift+T, Shift+O, and Shift+A toggle the fleet cards, turtle boxes, ore boxes, and known-air boxes. The hub's existing lowercase `h` and `r` keep their resume and recall behavior. Recharge uses the confirmed chat command below.

## Authorize chat

Obtain each player's UUID from a trusted server-side player record. Add the verified UUIDs for Jeffreyy2, njov10, and yolobeerman locally.

```text
server chat allow VERIFIED-UUID Jeffreyy2
server chat allow VERIFIED-UUID njov10
server chat allow VERIFIED-UUID yolobeerman
server chat enable on
```

`VERIFIED-UUID` is a placeholder. Names without enrolled UUIDs grant no permission. The exact name and UUID must both match `chatNames` and `chatUUIDs` in `ssot.cfg`. Chat and AR use this same policy. Remove access with `server chat deny UUID`.

Set the AR owner after enrollment.

```text
server ar owner Jeffreyy2 VERIFIED-UUID
```

For a separate hub, pair its computer ID in `ssot.cfg` on both computers. Enroll that ID on the server, copy the same player policy to the hub, and set the hub's owner locally.

```text
server ar enroll HUB-ID Jeffreyy2 VERIFIED-UUID
hub ar owner Jeffreyy2 VERIFIED-UUID
```

Run the `server` command on the server and the `hub` command on the hub. Replace `HUB-ID` with its numeric computer ID. Restart both programs after configuration changes. Missing configuration, unmatched identities, and legacy modem ownership claims grant no AR access.

Authorized players can send `!hub`, `!recharge`, `!pro`, or `!xray`. Pro and x-ray also accept `on` or `off`. Each request returns a confirmation token that expires after 30 seconds. Confirm with `!confirm TOKEN`. A token works once. New commands from the same player are limited to one every two seconds.

AP leaves `!` commands visible in public chat. AP hides a message prefixed with `$` and passes its hidden status to the program. Use `$pro` and `$confirm TOKEN` for that path. Replies go to the requesting player.

Recall reports dispatch, which does not prove that a turtle reached home. Recharge queues a durable request for online paired miners with charging service enabled. The miner uses the warehouse charging route, reports its outcome, and returns home. Set up that route and its fuel target as described in [warehouse configuration](warehouse.md). Missing service or a failed charger produces an error.

## Set locations

```text
server chat bounds minecraft:overworld 0 -60 0 100 80 100
server chat spot warehouse supplies minecraft:overworld 10 64 12
server chat spot charging north minecraft:overworld 14 64 12
```

These commands persist AR configuration in `ar.cfg`. Spots become dimensioned anchor beams. Configure warehouse routes separately.

The bounds entry records the requested mine bounds for integration. Existing PR 3 miner configuration still controls mining and navigation limits. Do not treat the AR bounds entry as enforcement.

Configure enforced bounds on each miner with the existing commands.

```text
miner mine bounds minecraft:overworld 0 -60 0 100 80 100
miner nav bounds minecraft:overworld 0 -60 0 100 80 100
```

## Install and repair a bundle

Each role has a file list, shared dependencies, and a startup command in `bundle-manifest.lua`. Miner, store, server, hub, panel, AR, and the existing utility roles install their own file sets. The PR 5 view roles remain unavailable until its corrected branch is merged. Selecting an unavailable role changes no files.

Install and update remove files outside the selected role, including stale scripts and cached code. The manifest's explicit allowlist preserves configuration, state, journals, cold storage, keys, and user data. Configured miner counter and warehouse state paths are preserved too. A role change replaces the script set and startup command. An ordinary update preserves existing configured startup arguments.

The updater fetches one release manifest and rejects mixed file versions. It stages dependencies before replacing scripts. The next update recovers an interrupted transaction before fetching files. For offline repair, run:

```text
update --repair
```

If the interruption left `update.lua` absent, run the staged copy.

```text
update.lua.fleet-stage --repair
```

Restart after repair. Booting an interrupted installation alone does not run repair.

The whole manifest includes the role table and dependencies. Its Ed25519 signature is pending the H1H2 integration. The current checksum detects mismatched files but does not authenticate a release.

After changing a distributed Lua file, regenerate the manifest before testing or committing.

```powershell
C:\Tools\lua52\lua52.exe tests\make-bundle-manifest.lua --pending-pr5
```

Drop `--pending-pr5` after merging all PR 5 view modules.
