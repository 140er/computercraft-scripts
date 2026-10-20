## Why

The Gemini AR draft uses incompatible controller calls and accepts chat commands without authorization. This change adds a disabled-by-default HUD to the existing server/hub owner and confirms commands from configured UUIDs.

## What changed

- Add fleet cards, fuel alerts, radar, dimensioned x-ray geometry, configurable anchors, and namespaced element cleanup.
- Add UUID authorization, expiring single-use confirmation, local configuration, and public/hidden AP chat handling.
- Append named installer roles and verify staged release bundles with rollback and manual offline repair.

## Scope

- This PR targets main independently of PR 4 and PR 5. Charging/warehouse and view adapters report unavailable until those branches are integrated later.
- A separate hub has fleet telemetry only; its ore snapshot needs PR 5. AR bounds record requested configuration. Existing miner bounds enforce movement.
- The UUID allowlist starts empty. Enroll trusted UUIDs for Jeffreyy2, njov10, and yolobeerman locally. No far_beacons dependency is added.

## Blast radius

AR and chat default to off. The existing owner protocol remains in use. Installer and updater behavior changes for all roles; interrupted file promotion requires manual offline repair.

## Verification

- Gate A passed for bundle `8152c067`: 116 mock tests plus standalone checks; six CraftOS computers, three turtle emulators, 4 MB disks, ownership faults, and full process restart.
- Gate B is incomplete. The native renderer fixture and Minecraft restart recovery passed with actual cc_ar, AP, and three real turtles. The client timed out creating its loading window. Ownership polling hit an empty-file race. Fixes to the isolated runner are queued for another run; real goggles and production ownership remain unverified.
- Production recall/charging and all-role storage/view integration remain unverified. Saved results and the emulated screenshot are in [docs/evidence/pr6](docs/evidence/pr6). Full VM evidence is under `C:\Work\gemini-input\p2\evidence\pr6\gateA` and `gateB`.

The decision trail and full-doc6 AR findings are in [docs/evidence/pr6/decisions.tsv](docs/evidence/pr6/decisions.tsv) and [docs/gemini-review.md](docs/gemini-review.md).
