# Backlog

Later work, after the hardening track and warehouse v2 land. From
[the 2026-10-20 review](review/judgment-2026-10-20.md). Not started.

The review lists three projects as references: Actually Useful Turtles
(helpmyRF24isntworking/computercraft), SWARM (ninnghazad/SWARM) and
smart-turtle (luochen1990/smart-turtle). Read them for ideas only. Do not copy
their code.

| Item | Size | What it means |
| --- | --- | --- |
| Shared reservations for every program | M-L | lumber, farmer, builder, lava and sorter use server reservations and nav, like the miners. |
| Monitoring and alerts | S | Stuck, out of fuel, disk nearly full, offline: sent to chat and the AR HUD. |
| Fuel economy | M | Plan trips around fuel and charger distance, and charge before a long job. |
| Quarry modes | M | Full quarry, branch mining, vein-only, and layer by layer, chosen per job. |
| Self-replication pairing | M | A new turtle built by the fleet pairs itself with the server safely. |
| Restock forecasting | M | Track use over time and restock or craft ahead, including after a craft. |
| Blueprint building | L | Build from .nbt, .schem or litematic files with material lists. |

Out of scope: multi-dimension fleets.

## Approved: H4 storage, offline miners, positions without GPS, installer, planner

Jeffrey accepted this program on 2026-10-20 at 17:09 (Europe/Amsterdam). The
plan is [docs/plans/cc-h4-offline-plan.md](plans/cc-h4-offline-plan.md). Every
PR needs Gate A and an in-depth Gate B run with saved evidence. A skipped item
is a failed gate.

Build order (each starts after its dependencies):

| Step | PR | Depends on |
| --- | --- | --- |
| 1 | P0 platform measurements and frozen contract | none |
| 2 | H3 server request queue (hardening track) | P0 |
| 3 | H1H2 keyed BLAKE3 MAC and Ed25519 manifest (hardening track) | H3 |
| 4 | N1 positions without GPS, frames, dead-reckoning confidence | H1H2 (built early; H1H2 gets merged in later, never rebased) |
| 5 | I1 install core, keyboard installer, enrolment, per-role files | N1, PR 5, PR 6 |
| 5 | H4a code cache off the server, 2-copy save, control reserve | N1 |
| 6 | I2 touch installer | I1 |
| 6 | H4b1 compact sections, per-section files, migration | H4a |
| 7 | H5 dead turtles (hardening track) | H4b1 |
| 8 | H4c storage ledger, player choice, forget preview | H5 |
| 9 | W1 wh2 fleet core | H4c |
| 10 | B1 lease v2, offline movement, journal | W1 |
| 10 | T1 planner core and server MVP | W1, I1, H4b1 |
| 11 | B2 local problem handling | B1 |
| 11 | A1 AR planner MVP | T1, PR 6 |
| 12 | T2 planner on panel, hub and server | T1 |
| 13 | S1 hub profile and authority handover | H4c (runs after T2 in order) |
| 14 | H4b2 baseline plus exceptions, flagged | H4b1 |
| 15 | H4d peer cold storage | H4c, H5, B1 lease state (runs after H4b2 in order) |
