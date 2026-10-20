PR 3 work record

Feature checklist

- [x] 1. `how` over the affected subsystem.
- [x] 2. `architect` for parallel design exploration.
  Single-agent exploration follows the PR 1 instruction. No delegates or other models.
- [x] 3. Write the throughput checkpoint as four todo items.
  Blocking first steps. Check the branch base and baseline mocks before edits.
  Independent workstreams. Allocation, extraction and gate fixtures share contracts, so edits stay sequential.
  Shared mutable state. The SSOT server owns leases. Each miner owns its traversal file.
  Smallest safe decomposition. One owner extends the existing RPC, atomic store and navigation.
- [x] 4. Delegate code-writing to a subagent using your configured feature model.
  Skip delegation because the PR 1 rules require one agent. Keep a separate review pass.
- [x] 5. Verify on the matching surface.
- [x] 6. Rebase into small, ordered commits. Stack follow-ups.
- [x] 7. If the design is contested, `interrogate` before shipping.
  Skip other models and agents under the PR 1 rules.
- [x] 8. Run **Opening a PR**.

The existing SSOT request handler validates and authenticates messages, copies state, applies one operation, and saves before replying. Navigation journals physical actions and reserves every destination. Miner boot recovers navigation before starting work. Both gate runners copy repository Lua into isolated computer disks.

Two designs were considered. A global ore-cell claim table would permit veins across strip boundaries but add a second allocator and per-cell renewal. Disjoint rectangular zones keep lease ownership and extraction bounds together. This PR uses zones. Boundary ore remains untouched. Coverage is measured against seeded blocks, including an ore hidden in a spacing-four gap.

Data shapes

- The server stores a mine configuration and a bounded array of zone tasks. A task has an owner, token, deadline, status and acknowledged tunnel progress.
- A miner stores its task, tunnel progress, a bounded DFS stack with a six-face cursor per frame, visited cells, and a return reason. Navigation owns physical pose and movement recovery.
- Expired active tasks remain quarantined to their owner. Renewal resumes them. Unstarted offers can expire and change owners. A stale token cannot acknowledge or finish a task.

Mining stays disabled unless `miner.cfg` explicitly enables it. Configuration uses a paired computer command. Warehouse delivery and charging remain PR 4 work. This PR returns to a configured home pose and reports unavailable service without dropping items into the world.

Model the Domain put ownership in zone tasks and traversal in DFS frames. Make Operations Idempotent preserved tokens across renewals and made completion safe to retry. Laziness Protocol kept movement and atomic storage in the existing modules. Test Behavior, Not Implementation required ore counts, real positions, and failed-before recovery tests. Sequence Work into Verifiable Units separated allocation, extraction, and the queued-air fix into commits. Prove It Works required both actual runtimes and matching source hashes.

The PR 1 rules require one agent and one model. Parallel design delegates and cross-model review were skipped under that instruction. The deslop skill is absent from the installed pstack skills. The code and prose received a manual review. The added code contains no explanatory comments.

The six-face visited traversal and service/resume behavior follow `smartmine.lua`. The new engine persists the stack and delegates physical movement to navigation. Speculative diagonal excavation and lava detours would cross the chosen zone and return policies, so they were excluded.

No session transcript directory was supplied. The final trail audit used this conversation's tool outputs and the saved artifacts. Correction rows withdraw the early RCON unload claim and qualify the inferred client-config race. The authoritative final runs are named in README.md.
