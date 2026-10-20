## Why

The Gemini AR draft uses incompatible controller calls and accepts chat commands without authorization. This change adds a disabled-by-default HUD to the existing server/hub owner and confirms commands from configured UUIDs.

## What changed

- Add fleet cards, fuel alerts, a 2D radar, depth-tested world boxes, configurable anchors, and namespaced element cleanup.
- Add UUID authorization, expiring single-use confirmation, local configuration, and public/hidden AP chat handling.
- Append named installer roles and verify staged release bundles with rollback and manual offline repair.

## Scope

- This PR targets main independently of PR 4 and PR 5. Charging/warehouse and view adapters report unavailable until those branches are integrated later.
- A separate hub has fleet telemetry only; its ore snapshot needs PR 5. AR bounds record requested configuration. Existing miner bounds enforce movement.
- The UUID allowlist starts empty. Enroll trusted UUIDs for Jeffreyy2, njov10, and yolobeerman locally. No far_beacons dependency is added.

## Blast radius

AR and chat default to off. The existing owner protocol remains in use. Installer and updater behavior changes for all roles; interrupted file promotion requires manual offline repair.

## Verification

- Linux Gate A passed for bundle `4538c7db`. `lua5.2 tests/run.lua` printed `168 tests passed`. CraftOS-PC 2.8.3 ran the `ar` scenario with six computers, three turtle emulators, 4,000,000-byte disks, and a full process restart. `pwsh -NoProfile -File tests/chat-token-parser.ps1` printed `PASS confirmation token parser`.
- Gate B was not run on this pass. Earlier native runs created elements, moved three real turtles, recovered from a Minecraft restart, and passed production shared-controller ownership. Those runs are not this commit's Gate B.
- cc_ar 0.2.1 depth-tests 3D lines and text. The HUD says outlines stop at blocks. A wall image with no outlines matches that renderer. See [the bytecode findings](docs/evidence/pr6/cc-ar-depth.md).
- The confirmation parser keeps the token after `!confirm` or `$confirm`. It does not take `pro` from `Confirm pro`.
- A recalled miner that is already outside the mining loop walks home. The mock and the CraftOS scenario cover that path. A physical return on a real turtle, and a native install of every role, still need Gate B.

The decision trail and full-doc6 AR findings are in [docs/evidence/pr6/decisions.tsv](docs/evidence/pr6/decisions.tsv) and [docs/gemini-review.md](docs/gemini-review.md).
