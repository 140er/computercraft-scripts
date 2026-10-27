# Lease ordering verification

Run from the repository root:

```sh
python3 formal/verify_lease.py --evidence formal/evidence/lease-orderings.json
```

Python 3 and Lua 5.2 are the only dependencies. The runner limits Lua subprocesses to 55 seconds per flag mode. It saves bounds, tool version, source hash, baseline results and the seven scratch counterexamples per mode in the evidence file. It removes scratch implementations before reporting success.

The runner checks both shipped defaults (no config, safety on) and explicit
`protectedAreas=false`, `alternateAxisOrders=false`, `storageDeliveries=false`.
Evidence stores each baseline and all seven injected defects under `runs.defaults`
and `runs.off`, and hashes the flags and boundary planner as well as the lease source.
Each mode enumerates 493,941 traces, including two-restart, save-failure and
journal-recovery schedules: 987,882 traces and fourteen caught defects in total.

With defaults, the worker starts with fenced-batch capabilities, a journal and a
pose. Batches contain inspections followed by one move, respecting acknowledged
boundaries even at size 16. Reports advance the journal and confirm the expected
pose. The reference model checks boundary holds after expiry and restart as well
as dispatch refusal before a worker has supplied fresh capabilities. The off mode
retains the original batches of repeated moves. Cell admission remains a stub;
the real mine, lumber and builder worker tests cover those planners with no flags pinned.

## Tool choice and scope

`tests/so/lease.lua` checks individual protocol cases. It does not enumerate combinations of reports, expiry, uncertain journals and a server restart. These combinations matter because durable leases and reservations must agree after restart.

The checker uses exact finite schedule enumeration rather than TLA+. The executable reference transition model and real Lua module share a small event alphabet, so direct execution avoids a second language and a JVM dependency. There is no sampling or state pruning. This is bounded model conformance checking, not an unbounded proof of the complete distributed protocol.

`formal/lease_orderings.lua` wraps the actual contents of `so-mod-lease.lua` in a factory. Each trace starts with fresh module locals. Restart calls the factory again while preserving the lease store and reservation stub. The reference model separately tracks open lease, sequence, uncertainty, expected callback history, and reservation owners. Every event compares implementation state and effects with the reference state.

The model supplies `SO.now()` as game milliseconds. Module reload keeps that
clock fixed and resets module locals. A whole server boot also advances the
durable clock reservation; that separate boundary is covered by the clock
regressions, not this module-only model.

The environment assumes one paired worker, successful synchronous nonblocking rednet sends, a working copy operation, and a cells module whose release removes the named owner. The harness records a synthetic reservation on every accepted send. This tests the lease module's release policy; it does not execute the real cells persistence code or prove planner recovery. The callback records completions and does not dispatch more work.

## Bounds

Every permutation of these eight event occurrences runs, including prefixes with reports before dispatch:

- Two distinct dispatch attempts, `send_a` and `send_b`.
- A report for `send_a` and a duplicate of that report.
- A foreign or malformed report.
- One expiry tick.
- One module restart.
- One hello with an uncertain journal.

There are 40,320 permutations. Each runs with 1-step and 16-step batches, three foreign report modes, and ticks at 11,000 and 11,001 ms. That is 483,840 full traces per flag mode. Another 10,080 traces enumerate seven-event schedules with two restarts; 21 explicit traces cover save failures, forget and journal recovery. Worker 2 receives work; sender 3 supplies the wrong-sender case. Each dispatch lasts 1,000 ms. The two tick values check the exact grace boundary for a lease dispatched at time zero. A dispatch after the tick receives a later deadline. No other time values, event repetition counts, operation shapes or workers are covered.

The checker compares the observable projection after every event. It does not enumerate arbitrary-length executions, concurrent Lua instructions, crashes inside handlers, real radio queues, send failures, reanchor acknowledgments, worker execution, dug sections, planner lane deadlocks, callback reentrancy, or arbitrary disk failures. Journal and pose reports and whole-save failures use the stated finite stubs. Gate A and Gate B remain separate integration requirements.

## Code mapping and falsification

The verifier tracks `so-mod-lease.lua` from sync commit `d82f456583671350a655ee9c982c126ddd2795d4`. The evidence records its current SHA-256. Changes to these functions require review of the corresponding transition and mutation anchor.

| Property | Implementation and reference transition | Broken scratch implementation |
| --- | --- | --- |
| `dispatch` | `S.send` busy check, allocation and `row.open`; model refuses a second open batch | Remove the busy guard |
| `report_integrity` | `S.report` sender row, lease ID and result count; model accepts only a matching full report | Remove lease ID comparison |
| `reservation_retention` | `S.tick` expires without release; module reload leaves cells outside module state | Release cells on expiry |
| `restart_restore` | Restored durable open work blocks replacement dispatch | Discard restored open work |
| `recovery_forget` | Forget removes durable recovery before restart | Retain the forgotten record |
| `uncertainty` | `S.hello` uncertain journal, `S.send` refusal, `S.status` uncertainty | Remove uncertain-pose dispatch guard |
| `callback_once` | `S.report` clears the open lease and calls `S.notify`; `S.tick` notifies expiry | Notify twice for an accepted report |

Each mutation edits the actual Lua source into a temporary file and executes it with the same model. Each must fail its named property with a concrete trace. The model stays unchanged. These checks prevent a passing command whose oracle cannot detect any broken implementation. They do not establish completeness of the oracle.

The malformed case supplies an empty result array; arbitrary invalid result fields are outside this bound. Reservation retention on restart is conditional on the external durable-cells assumption, not a persistence proof. Callback uniqueness is per currently open record; it does not claim globally unique lease IDs across restarts.

## Historical finding: module reload can repeat IDs at a fixed clock

The original checker recorded this trace against the earlier implementation:

```text
send_a -> returns 2-0-1
restart -> S.seq returns to zero, clock remains zero
send_b -> returns 2-0-1
report_a -> closes send_b and invokes its callback
```

In that implementation, `S.seq` starts at zero on module load. `S.send` builds `<worker>-<gameMs>-<sequence>`, and `S.report` correlates only the sender and that string before validating the result shape. A delayed old report with the same shape can therefore match a new open lease at this boundary. The current module restores its durable sequence, and the model checks that sequence across restarts. This historical finding does not establish cross-restart report identity safety for every deployment.

This is a module-level finding. Authentication, freshness, replay-cache restart behavior and planner recovery may constrain whether the trace reaches the handler in a complete deployment. This checker neither proves nor dismisses that end-to-end case. A whole server boot resumes at the durable clock reservation and therefore
uses a later time component. The fixed-clock module-reload finding remains
within this model's stated assumptions.

## Evidence maintenance

Keep the two skill copies identical. Rerun the command after changing the model, runner, mutation anchors or covered implementation. Preserve a failing trace before changing expectations. Review a new source hash against the sync commit instead of treating a new hash as evidence that the model is current. Evidence comes from local Lua execution and is not Minecraft or CraftOS-PC evidence.
