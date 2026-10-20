# Fleet work plan

## Required playbook

- [x] Read the Principles section of poteto-mode.
- [x] Phase A. Frame.
- [x] Phase B. Design the workflow.
- [ ] Phase C. Run the loop.
- [ ] Phase D. Keep the audit trail.
- [ ] Phase E. Verify and hand back.

## Definition of done

The server owns fleet records, effective settings and shared service locations. Opted-in programs report through one small client. Miner service uses server locations without local drop coordinates. Settings apply before the next physical action. Legacy startup works with v2 disabled. Both runtime gates have saved evidence. The branch is pushed and its PR records exact results.

## Throughput checkpoint

- Blocking first steps. Read the contract and source. Establish module signatures before parallel edits. H12 must pass before the required rebase and Gate B.
- Independent workstreams. Fleet domain and its tests, the shared client and its tests, and miner integration use disjoint files. The parent owns dispatcher integration, other callers, manifests and runtime evidence.
- Shared mutable state. SSOT alone persists shared state. Agents share this worktree but own disjoint files. Only the parent runs git mutations and gates.
- Smallest safe decomposition. Three Codex workers use gpt-6.1-sol. No other model or paid service runs.

## Data shapes and design choice

Use the contract's fleetRecord, settingsPatch, settings and location tables. Registry rows own validation, defaults and display metadata. A single outbound queue owns v2 calls. Existing movement journals retain physical authority. Reports never change occupancy.

Two candidate integrations were considered. A separate telemetry receiver would duplicate authentication and race existing rednet loops. A shared client attached to each program's receiver preserves one transport owner. Use the shared client.

## Execution

- [ ] Implement fleet domain and behavioral tests.
- [ ] Implement queued client and cache tests.
- [ ] Integrate miner actions and server-known services.
- [ ] Integrate remaining program reporting, views and manifests.
- [ ] Run mock suite and CraftOS sandbox under 1,000,000 bytes.
- [ ] Rebase onto the furthest passing hardening branch, at least H12, and rerun Gate A.
- [ ] Run Gate B with the shared lock and retain failed attempts.
- [ ] Review, commit, push, open PR and write SUMMARY.

## Decisions

Model the Domain led to one settings registry instead of repeated validators. Prove It Works requires real inventory counts and screenshots before a gate can pass. Offline autonomy and H4 remain unimplemented.
