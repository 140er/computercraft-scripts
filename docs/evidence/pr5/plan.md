# PR 5 work plan

1. `how` over the affected subsystem.
2. `architect` for parallel design exploration.
3. Write the throughput checkpoint as four todo items.
4. Delegate code-writing to a subagent using your configured feature model.
5. Verify on the matching surface. "Inconclusive" or wrong-surface is not a pass. Flag it.
6. Rebase into small, ordered commits. Stack follow-ups.
   Skip rebase. The user supplied this branch and forbids rebasing other branches.
7. If the design is contested, `interrogate` before shipping.
8. Run **Opening a PR**.

The data shape is a scene with a dimension, revision, observed cells, fleet entries, warehouse sites, and freshness. Unknown cells are absent. Observed air uses `name=false`.

The source adapter reads bounded SSOT pages and PR 4's `wh-sites` operation. The scene owns projection and picking. DirectGPU owns only its displays and textures. The hub owns selection and commands.

Two designs were compared. Extending `fleetview.lua` would reuse its scene conversion, but would couple map rendering to the AR work in PR 6. Separate scene and source modules keep that change isolated. Existing Tom's GPU and AR rendering remain their own backends.

## Throughput checkpoint

- Blocking first steps. Read the shipped interfaces and test tooling before implementation. Check DirectGPU's variable argument methods before defining their mock.
- Independent workstreams. Core source and rendering modules, hub and installer integration, and gate tooling have separate file owners.
- Shared mutable state. All edits use this worktree. Gate A gets unique PR 5 data directories. Gate B holds the shared client lock and owns its Java PIDs.
- Smallest safe decomposition. Three implementation owners cover disjoint files. The lead owns movement validation, integration, evidence review, and publication.

Model the Domain shaped the explicit scene and camera records. Boundary Discipline put PR 4 decoding in one adapter. Separate Before Serializing Shared State shaped the isolated gate directories. Prove It Works requires actual rendered Minecraft screenshots before a visual pass.
