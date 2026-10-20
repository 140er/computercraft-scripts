# Configure safe navigation

Navigation requires a paired SSOT server, working GPS, and a known heading. It defaults off. Keep both `ssot.enabled` and `nav.enabled` off until you have configured and tested the turtle.

Run this command on the turtle to save its navigation bounds. Coordinates are inclusive and belong to the supplied dimension.

```text
miner nav bounds minecraft:overworld -32 -64 -32 32 128 32
```

Set `ssot.enabled=true` and `nav.enabled=true` in `miner.cfg`. The SSOT configuration needs `server`, `secret`, and `dimension`. The configured dimension must match the turtle's world. GPS cannot identify dimensions.

Start the turtle with a known heading. After a physical relocation or an interrupted turn, stop the miner, face the turtle in a known direction, and run this command.

```text
miner nav calibrate east
```

Calibration observes GPS and reconciles server occupancy. Relocation clears the local route map. The turtle then needs to explore a safe route before it can return through known air. Calibration preserves mining progress.

The calibration request requires the paired turtle's secret and its previous server pose. An outstanding movement also requires its token. A destination held by another turtle stays blocked. Ordinary boot sync continues to reject relocation. The server trusts the paired owner to attest that the operator physically moved and oriented the turtle.

Recall uses known air and never digs. A changed block can cause a replan or a safe refusal. Unknown exploration inspects each destination and refuses blocks. Excavation uses the miner's existing ground and ore checks. Fluids, unbreakable blocks, chests, and chargers remain obstacles. Navigation does not use far_beacons.

The default map and search limits are 2,048 cells each. Search yields every 32 expansions and allows five planning attempts per route. A full local map stops movement rather than deleting a return route. Journal saves use the existing atomic store and retain a previous generation.

The paired server can send `estop` to latch a stop and cancel search or movement before its next physical action. A newer `go` command clears the latch after the movement owner becomes idle. Navigation saves the server epoch and command sequence with the latch. Older deliveries and duplicate commands cannot resume a stopped turtle. Commands cannot interrupt a turtle API call already in progress. Manual driving remains disabled while SSOT is enabled.

Mine task allocation, warehouse access poses, charging, and UUID chat commands belong to later PRs. This PR adds the configurable navigation volume only.
