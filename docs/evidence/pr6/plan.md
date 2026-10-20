# PR 6 work plan

1. `how` over the affected subsystem.
2. `architect` for parallel design exploration.
3. Write the throughput checkpoint as four todo items.
4. Delegate code-writing to a subagent using your configured feature model.
5. Verify on the matching surface.
6. Rebase into small, ordered commits. Stack follow-ups.
   Skip rebase because the user requires the existing independent branch.
7. If the design is contested, `interrogate` before shipping.
8. Run **Opening a PR**.

## Throughput checkpoint

- Blocking first steps. Read the existing AR ownership, full Gemini source, installer registry, and gate tooling before changes. Save the baseline unit result.
- Independent workstreams. AR rendering owns fleetview, server, and hub. Chat and installation own their modules and registries. Gate A owns sandbox fixtures. The parent owns Gate B, docs, and review.
- Shared mutable state. Each workstream owns separate files. Minecraft needs one shared client, so Gate B uses the required directory lock. PR 6 has separate test roots and ports.
- Smallest safe decomposition. Keep the current drawing owner and add focused HUD and command state. Stub unavailable warehouse and view features at one boundary.

## Design phases

Ground, sketch, compare, implement, and discard any design that requires a second drawing owner.
