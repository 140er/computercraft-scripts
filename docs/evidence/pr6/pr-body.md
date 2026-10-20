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
- Gate B is failing. Native element creation, three real turtles, Minecraft restart recovery, and production shared-controller ownership passed. This includes server death/reclaim, key forwarding, controller replacement, and scoped cleanup. Real linked goggles show the HUD.
- Through-wall geometry is blocked by cc_ar 0.2.1's depth-tested renderer. Its Lua API exposes no see-through option. The captured wall image shows no outlines; it is retained as failure evidence. See [the bytecode findings](docs/evidence/pr6/cc-ar-depth.md).
- Real AP chat passed after fixing the test token parser: an unenrolled UUID caused no action, hidden/public commands each executed once, and replay was rejected. A later ownership comparison was inconclusive because a status read could be empty; the hub journal shows no drawing after the key. Fresh-snapshot checks, complete-PNG capture, and native cached-role installation are queued for another run.
- Production chat recall with physical turtle return remains unverified. PR 4 charging/storage and PR 5 views are deferred integration boundaries. Saved results and screenshots are in [docs/evidence/pr6](docs/evidence/pr6). Full VM evidence is under `C:\Work\gemini-input\p2\evidence\pr6\gateA` and `gateB`.

The decision trail and full-doc6 AR findings are in [docs/evidence/pr6/decisions.tsv](docs/evidence/pr6/decisions.tsv) and [docs/gemini-review.md](docs/gemini-review.md).
