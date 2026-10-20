# Unknown material wizard work

The wizard queues unknown item IDs and stores operator answers on the server. The board reads the same item classes as warehouse workers.

## Work checklist

1. `how` over the affected subsystem.
2. `architect` for parallel design exploration.
3. Write the throughput checkpoint as four todo items.
4. Delegate code-writing to a subagent using your configured feature model.
5. Verify on the matching surface.
6. Rebase into small, ordered commits. Stack follow-ups.
7. If the design is contested, `interrogate` before shipping.
8. Run **Opening a PR**.

The supplied contract fixes the state shape. A server-owned queue avoids diverging answers on different boards. A local board-owned answer file was rejected because other machines would not see it.

- Blocking first steps. Read the contract and board entry points, capture baseline checks, and identify passing hardening branches before Gate B.
- Independent workstreams. Server module, board module, and test scenario have disjoint owners. The lead integrates shared files.
- Shared mutable state. Only the SSOT dispatcher commits `s.wh2.wizard`. Agents never commit or change branches.
- Smallest safe decomposition. Three workers implement the state module, board interaction, and test scenarios. The lead reviews and runs the gates.

## Data shapes

`s.wh2.wizard` contains `revision`, `classes[itemId]`, and `questions[itemId]`. Class answers use the contract's `itemClass`. Questions use `unknownQuestion`; skipping leaves the durable question open. The board keeps only its current selection and skipped IDs for that visit.

`wh2-get` reads `classes` and `questions`. `wh2-unknown` coalesces reports. `wh2-class` checks the operator and base revision, then commits the answer and resolution together. Recipe suggestions come from Recipe Index `getUsesOf` and never from item name suffixes.

## Verification

Gate A requires the mock suite, several sandbox computers and turtles, saved captures, and the 1,000,000-byte disk limit. Gate B requires the disposable real server, real inventories, reboot and restart checks, simultaneous questions, failure cases, F2 captures, a video, and the required soak. A missing check remains a failure.
