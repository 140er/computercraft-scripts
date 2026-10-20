# PR 6 fix coverage

This file records the fix round. Earlier evidence remains in place.
The final verdict also requires the corrected PR 5 merge and final-source
Gate A and Gate B runs.

| Review item | Change or constraint | Regression evidence |
| --- | --- | --- |
| P1a, AR layer authorization | World layers require the shared enrolled name and UUID. | AR authorization and owner-revocation tests. |
| P1b, radius 64 | Bounded selection traverses the full radius, keeps ores before air, and keeps nearest cells within each class. | Radius-64 regression includes ore beyond the former 8192-cell cutoff. |
| P1c, unauthenticated AR hub | AR controls require SSOT authorization and enrolled controller ownership. Legacy ownership packets cannot grant access. | Absent configuration, raw claims, wrong identities, replay, and revoked ownership tests. |
| P1d, PR 5 integration | The cloud-review fix round has not arrived. Commit ecc6cad only changes native test startup timing. | Merge remains pending. |
| P2, chat rate and names | Chat uses the shared name and UUID policy and limits repeated commands. | Chat and authorization regressions. |
| P2, recharge | Recharge uses the real mining service. Authorization, durable delivery, cancellation, and native checks are under final verification. | Recharge regressions and native scenario. |
| P2, goggles removal | cc_ar 0.2.1 exposes no wearer-removal status or event. | Saved API signatures and `cc-ar-depth.md`. This requirement is unmet. |
| P2, status redraw cost | AR reads the store through a projection, yields during traversal, and caches unchanged geometry. | Traversal, cache, and revision tests. |
| P2, role startup | The manifest defines startup commands and dependencies per role. Legacy startup arguments survive the first update. | Exact file-list, startup, and migration tests. |
| Issue #39 | Chat and AR call the same `SSOT.chatAllowed` policy. | Shared identity and revocation tests. |
| Signed manifest | The role table belongs to the whole signing payload. H1H2 has not supplied a passed signing implementation. Existing checksums do not authenticate releases. | Manifest metadata tests. Signing remains pending. |

The native scenario uses four production miners, four lanes of 64 diamond
ore blocks, a real shared map, real GPS hosts, and real chat confirmation.
It records concurrent requests, a server restart during mining, modem loss,
chunk unload, physical recall, recharge failures, and a two-hour soak.
Before and after counts come from native block and inventory queries.
These are planned checks until the saved native result proves they ran.

The installer scenario runs a miner and a store turtle, records their exact
file lists, and starts their installed programs. It also tests an old updater,
preserved user data, role changes, and recovery after a real computer reboot
during an update.

Sorting rooms, furnace recipes, crafting chains, and the warehouse wizard are
outside this PR's changed behavior. PR 6 installs the existing store role;
that does not establish new evidence for every warehouse workflow.

The required native through-wall view is unavailable in the pinned cc_ar
renderer. Successful Lua drawing calls cannot establish that view.
The current wearer cannot be checked through its Lua API either.
Both limitations keep the overall verdict at `GATES: FAIL`.
