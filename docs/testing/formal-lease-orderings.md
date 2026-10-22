# Lease ordering verification

Run from the repository root:

```sh
python3 formal/verify_lease.py --evidence formal/evidence/lease-orderings.json
```

Python 3 and Lua 5.2 are the only dependencies. The runner limits all Lua subprocesses together to 55 seconds. It saves bounds, tool version, source hash, baseline results and the five scratch counterexamples in the evidence file. It removes scratch implementations before reporting success.

## Tool choice and scope

`tests/so/lease.lua` checks individual protocol cases. It does not enumerate combinations of reports, expiry, uncertain journals and a server restart. These combinations matter because leases are memory-only while reservations survive restart.

The checker uses exact finite schedule enumeration rather than TLA+. The executable reference transition model and real Lua module share a small event alphabet, so direct execution avoids a second language and a JVM dependency. There is no sampling or state pruning. This is bounded model conformance checking, not an unbounded proof of the complete distributed protocol.

`formal/lease_orderings.lua` wraps the actual contents of `so-mod-lease.lua` in a factory. Each trace starts with fresh module locals. Restart calls the factory again while preserving the reservation stub. The reference model separately tracks open lease, sequence, uncertainty, expected callback history, and reservation owners. Every event compares implementation state and effects with the reference state.

The environment assumes one paired worker, successful synchronous nonblocking rednet sends, a working copy operation, and a cells module whose release removes the named owner. The harness records a synthetic reservation on every accepted send. This tests the lease module's release policy; it does not execute the real cells persistence code or prove planner recovery. The callback records completions and does not dispatch more work.

## Bounds

Every permutation of these eight event occurrences runs, including prefixes with reports before dispatch:

- Two distinct dispatch attempts, `send_a` and `send_b`.
- A report for `send_a` and a duplicate of that report.
- A foreign or malformed report.
- One expiry tick.
- One module restart.
- One hello with an uncertain journal.

There are 40,320 permutations. Each runs with 1-step and 16-step batches, three foreign report modes, and ticks at 11,000 and 11,001 ms. That is 483,840 full traces plus the explicit restart finding trace. Worker 2 receives work; sender 3 supplies the wrong-sender case. Each dispatch lasts 1,000 ms. The two tick values check the exact grace boundary for a lease dispatched at time zero. A dispatch after the tick receives a later deadline. No other time values, event repetition counts, operation shapes or workers are covered.

The checker compares the observable projection after every event. It does not enumerate arbitrary-length executions, concurrent Lua instructions, crashes inside handlers, real radio queues, send failures, reanchor acknowledgments, worker journals, movement, dug sections, planner lane deadlocks, callback reentrancy, or disk failures. Gate A and Gate B remain separate integration requirements.

## Code mapping and falsification

The covered implementation is `so-mod-lease.lua` at sync commit `0f73a4ea74815bc21158585a498da446f5072034`. The evidence records its current SHA-256. Changes to these functions require review of the corresponding transition and mutation anchor.

| Property | Implementation and reference transition | Broken scratch implementation |
| --- | --- | --- |
| `dispatch` | `S.send` busy check, allocation and `row.open`; model refuses a second open batch | Remove the busy guard |
| `report_integrity` | `S.report` sender row, lease ID and result count; model accepts only a matching full report | Remove lease ID comparison |
| `reservation_retention` | `S.tick` expires without release; module reload leaves cells outside module state | Release cells on expiry |
| `uncertainty` | `S.hello` uncertain journal, `S.send` refusal, `S.status` uncertainty | Remove uncertain-pose dispatch guard |
| `callback_once` | `S.report` clears the open lease and calls `S.notify`; `S.tick` notifies expiry | Notify twice for an accepted report |

Each mutation edits the actual Lua source into a temporary file and executes it with the same model. Each must fail its named property with a concrete trace. The model stays unchanged. These checks prevent a passing command whose oracle cannot detect any broken implementation. They do not establish completeness of the oracle.

The malformed case supplies an empty result array; arbitrary invalid result fields are outside this bound. Reservation retention on restart is conditional on the external durable-cells assumption, not a persistence proof. Callback uniqueness is per currently open record; it does not claim globally unique lease IDs across restarts.

## Finding: lease IDs repeat after restart

The explicit trace calls the real module in this order:

```text
send_a -> returns 2-1
restart -> S.seq returns to zero
send_b -> returns 2-1
report_a -> closes send_b and invokes its callback
```

`S.seq` starts at zero on module load. `S.send` builds `<worker>-<sequence>`, and `S.report` correlates only the sender and that string before validating the result shape. A delayed old report with the same shape can therefore match a new open lease at this boundary. The model records this implemented behavior rather than claiming cross-restart report identity safety.

This is a module-level finding. Authentication, freshness, replay-cache restart behavior and planner recovery may constrain whether the trace reaches the handler in a complete deployment. This checker neither proves nor dismisses that end-to-end case. No product change accompanies the finding.

## Evidence maintenance

Keep the two skill copies identical. Rerun the command after changing the model, runner, mutation anchors or covered implementation. Preserve a failing trace before changing expectations. Review a new source hash against the sync commit instead of treating a new hash as evidence that the model is current. Evidence comes from local Lua execution and is not Minecraft or CraftOS-PC evidence.
