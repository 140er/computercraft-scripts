# PR 4 work plan

1. `how` over the affected subsystem.
2. `architect` for parallel design exploration.
3. Write the throughput checkpoint as four todo items.
4. Delegate code-writing to a subagent.
5. Verify on the matching surface.
6. Rebase into small, ordered commits. Stack follow-ups.
7. If the design is contested, `interrogate` before shipping.
8. Run **Opening a PR**.

Steps 2 and 4 run in this session because the PR 1 rules require one agent. No cross-model review runs because the user permits only gpt-6.1-sol.

## Throughput checkpoint

- Blocking first steps. Read the plan and prior results, check the branch stack, run the baseline mocks, and add failing warehouse checks.
- Independent workstreams. Dispatcher, turtle service, traffic, and fixtures have separate responsibilities. Their contracts require serial implementation under the one-agent rule.
- Shared mutable state. The SSOT dispatcher owns orders, stock reservations, and bay locks. Each turtle owns its transfer journal. Existing navigation owns movement.
- Smallest safe decomposition. One worker implements and reviews each unit before moving to the next.

## Ground

`ssot.lua` authenticates paired computers, deduplicates requests, and saves every mutation before replying. `mine-tasks.lua` owns mining leases. `nav.lua` owns GPS recovery and reserved moves. `mining.lua` preserves traversal while returning home. `roomsorter.lua` currently runs its own room and order loop. Installer and mirror registries deploy dependencies explicitly.

## Sketch and choice

One candidate uses wired inventory transfers from the dispatcher. It requires network names for moving turtles and makes the dispatcher responsible for physical transfer recovery. The chosen candidate keeps physical transfers on the turtle. A saved slot count before each transfer lets recovery measure the result after a crash. The dispatcher owns durable order quantities and exclusive interaction sites. Mixed source contents remain in escrow until the turtle returns them to the source.

The service job records its order, line, phase, carried slots, cumulative quantities, and pending transfer. A charge job records its bay, initial fuel, deadline, and target. Navigation records a bounded trail for deterministic retreat. Higher computer IDs yield to lower IDs. A route with no safe passing space returns a bounded failure.

Model the Domain led to separate dispatcher orders and physical turtle journals. Make Operations Idempotent led to cumulative acknowledgements and slot-count reconciliation. Build the Lever led to shared warehouse fixtures and result verifiers. Prove It Works requires both native and emulator evidence. Sequence Work into Verifiable Units separates the implementation commit from gate tooling and evidence.

## Agree

Proceed under the user's implementation request. Warehouse and traffic behavior require explicit enablement.

## Implement

Add behavioral checks before production code, then extend both gate runners with the same warehouse scenario. Verify SBW range with the actual supplied jar. The README's adjacency text predates its radius note, so it cannot establish the range.

## Scrap

Replace the sketch if real inventory or charging behavior contradicts it. Record the evidence and the replacement in decisions.tsv.
