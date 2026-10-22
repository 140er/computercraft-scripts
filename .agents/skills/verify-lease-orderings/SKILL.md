---
name: verify-lease-orderings
description: Verify server lease dispatch, reports, expiry and restart orderings against the real Lua module with bounded exhaustive checking. Use when changing or reviewing so-mod-lease.lua; does not verify worker movement or transport authentication.
---

From the repository root, run:

```sh
python3 formal/verify_lease.py --evidence formal/evidence/lease-orderings.json
```

Read `docs/testing/formal-lease-orderings.md` for the bounds, code mapping and restart finding. The checker requires Python 3 and Lua 5.2. Its subprocess budget is 55 seconds.

Require a passing baseline and five `CAUGHT scratch Lua mutation` lines. The command writes each broken implementation into a temporary directory, checks the corresponding counterexample, and deletes the directory. A syntax error does not count as a caught property violation. Never introduce the scratch defects into the checkout.

If checking a scratch implementation supplied by a caller, add `--source /absolute/path/to/so-mod-lease.lua`. A nonzero baseline means verification failed. Preserve its counterexample; do not weaken the model to accept the change.

The model covers `S.send`, `S.report`, `S.tick`, the uncertain-journal branch of `S.hello`, `S.status`, `S.notify`, and module reload. Sync commit is `0f73a4ea74815bc21158585a498da446f5072034`. Evidence records the actual source SHA-256. When those functions change, inspect the model and mutation anchors before updating the sync commit and evidence. Keep this file identical to `.claude/skills/verify-lease-orderings/SKILL.md`.

Report new counterexamples as findings. This workflow authorizes verification artifacts, not product fixes, deployment, commits, or live Minecraft access. A passing result proves only the documented finite schedules and stub assumptions. The recorded restart ID reuse remains a finding even when the command passes.
