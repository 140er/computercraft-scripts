# SSOT PR 1 design

The server owns a sparse map and movement state. Callers use `ssot-client.lua` and feed its dispatcher from their existing rednet event loop. The library never receives rednet itself.

## Data shape

`chunks[dimension|cx|cy|cz]` contains a revision and sparse cells. Each local index is `1 + x%16 + 16*(z%16) + 256*(y%16)`. Missing cells mean UNKNOWN, zero means AIR, and positive integers reference interned block names.

`poses[computerID]` holds confirmed occupancy. `moves[computerID]` holds a source, adjacent destination, unique token, server epoch, turtle boot, lease deadline, and phase. A granted move can expire. A started move holds both cells until reconciliation, including while its turtle is offline.

`clients[computerID]` holds a durable replay counter and bounded request results. A retry uses the original request ID and counter. A changed payload with that ID fails. Evicted results cannot execute again because their counters remain stale.

## Alternatives

| Candidate | Consequence | Decision |
|---|---|---|
| Add the map to `server.state` | Every legacy status save rewrites the map and consumes staging space. | Rejected. |
| Keep a separate SSOT generation file, owned by the existing server dispatcher | Legacy saves stay small. Mutation replies follow durable saves. | Selected. |
| Append a journal and compact chunks independently | More recovery states and file operations need proof. | Deferred. Bounded snapshots suffice for PR 1. |

The client records movement before it asks to start. After a timeout it never starts a physical move. After an uncertain physical outcome it stops until pose reconciliation. A trusted caller supplies an observed world pose on boot. Server coordinates alone cannot establish physical position.

## Work checklist

1. `how` over the affected subsystem.
2. `architect` for parallel design exploration.
3. Write the throughput checkpoint as four todo items.
4. Delegate code-writing to a subagent using your configured feature model.
5. Verify on the matching surface.
6. Rebase into small, ordered commits. Stack follow-ups.
7. If the design is contested, `interrogate` before shipping.
8. Run **Opening a PR**.

Steps 2 and 4 use local design comparison and implementation. The user's one-agent rule overrides skill delegation. Cross-model review is unavailable under that rule. No merge is authorized.

- Blocking first steps. Read the review, reproduce the mock failure, and inspect the disposable server inputs.
- Independent workstreams. Run independent read-only inspections together. Implement and verify each unit sequentially.
- Shared mutable state. Only the server network dispatcher mutates SSOT. Its durable file is separate from legacy status.
- Smallest safe decomposition. One agent owns the coupled protocol, client, and test changes so their contracts stay aligned.

## Existing ownership

`server.lua` has one application receive loop, a separate raw modem relay, cache refresh, and rendering loops. It captures legacy telemetry and forwards existing hub commands. The SSOT request branch belongs in that receive loop. The raw relay does not interpret SSOT messages.

`miner.lua` owns its movement journal in `rawMove` and a separate backward movement branch. Its listener owns application rednet messages. Feature integration must cover both movement branches and feed SSOT replies through that listener. Setup behavior stays outside the opt-in runtime mode.

`install.lua`, `update.lua`, and the server code list enumerate deployable modules. The sandbox currently boots one server, hub, and idle turtle. It needs a separate movement scenario and a shared physical world.
