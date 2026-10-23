# Log performance evidence

Measured on Linux with Lua 5.2 and `tests/so/harness.lua`. The baseline is
`bbe624046430f526bb3084d9dadb7dbee4e62737`, including #211 and #214.

Each sample appends 1000 distinct ore events with a 160-character detail field.
Five samples alternate baseline and candidate. The timer uses host CPU time.
Only the append or emit loop is timed. Disk writes count actual handle write
bytes, including the generation wrapper. Setup and recovery are outside the timer.
Every sample checks the complete recovered sequence and payloads. The old reader
then appends one event, and the current reader checks that event after reopening.
The reported runs had 1000 successful writes each and no rejected or missing events.

Append CPU time per event fell from a median 3.565810 ms to 0.300763 ms.
The baseline range was 3.386343 to 3.598388 ms. The candidate range was
0.283017 to 0.356856 ms. Written bytes per event fell from 32216.179 to
3853.765, an 88.0 percent reduction. Total written bytes fell from 32216179
to 3853765 per 1000 events.

The state emit path includes event validation, copying, folding, disk checks and
view invalidation. Its median fell from 3.611602 to 0.333829 ms per event.
The baseline range was 3.491171 to 3.739153 ms. The candidate range was
0.322873 to 0.403836 ms. These samples do not reach the snapshot or retention
threshold, so these are mock event-path measurements, not a gameplay latency claim.
The separate retention regression exceeds the 1 MB window and verifies bounded
checkpoint frequency and recovery after grouped pruning.

A separate instrumented run identified serialization and verified generation
rewrites as the work removed. Serialized bytes fell from 64714853 to 4199352 for
1000 appends. Read bytes fell from 64432358 to 3853765. The candidate retains the
verification read. Peak mock data bytes, including temporary and backup files,
fell from 715301 to 657000. The mock counts string bytes rather than filesystem
allocation. The existing disk ledger and budgets are unchanged.

The host had eight cores and load averages around 2 to 3 during the alternating
runs. Other test workers were active. The mock serializer sorts keys and emits
explicit array indices. It differs from the pack ROM serializer. A separate run
with the real pack ROM `textutils` recovered every event with the old reader and
passed the rollback append round trip. No real disk latency was measured.

For an idle three-worker, two-display fleet sending hello every five seconds over
twelve minutes, the default retains 65 machine events. Opt-in coalescing retains
5. Both counts are asserted in the mock suite. The cumulative fuel baseline is
saved in snapshots. A 1000 to 950 to snapshot/restart to 900 regression emits the
second machine event. View revisions advance independently of history sequences.

Completed `log.append` calls retain synchronous verified generation durability.
The event interrupted during its own write may be absent. This change does not
make #214's existing volatile disk-failure backlog durable. Snapshot retry already
backs off for 60 seconds. Idle coalesced freshness has no time-based checkpoint.

To reproduce, export the three baseline modules and run the commands below five
times in alternating order. The optional fifth argument is the pack ROM root.

```sh
mkdir -p /tmp/g1-log-baseline
git show bbe6240:so-log.lua > /tmp/g1-log-baseline/so-log.lua
git show bbe6240:so-store.lua > /tmp/g1-log-baseline/so-store.lua
git show bbe6240:so-mod-state.lua > /tmp/g1-log-baseline/so-mod-state.lua
lua5.2 tools/log-bench.lua /tmp/g1-log-baseline 1000 timing /tmp/g1-log-baseline
lua5.2 tools/log-bench.lua . 1000 timing /tmp/g1-log-baseline
lua5.2 tools/log-bench.lua . 1000 profile /tmp/g1-log-baseline
```

Raw alternating samples follow. Columns contain source, path, event count, written
bytes, bytes per event, ms per event, write calls, read bytes, serialized bytes and
peak data bytes. Profile counters are zero in timing runs.

```text
source	mode	events	bytes_written	bytes_per_event	ms_per_event	writes	read_bytes	serialized_bytes	peak_data_bytes
/tmp/g1-log-baseline	append	1000	32216179	32216.179	3.580605	1000	0	0	0
/tmp/g1-log-baseline	emit	1000	32216179	32216.179	3.611602	1000	0	0	0
.	append	1000	3853765	3853.765	0.283017	1000	0	0	0
.	emit	1000	3853765	3853.765	0.322873	1000	0	0	0
/tmp/g1-log-baseline	append	1000	32216179	32216.179	3.565810	1000	0	0	0
/tmp/g1-log-baseline	emit	1000	32216179	32216.179	3.491171	1000	0	0	0
.	append	1000	3853765	3853.765	0.289140	1000	0	0	0
.	emit	1000	3853765	3853.765	0.333829	1000	0	0	0
/tmp/g1-log-baseline	append	1000	32216179	32216.179	3.465516	1000	0	0	0
/tmp/g1-log-baseline	emit	1000	32216179	32216.179	3.685264	1000	0	0	0
.	append	1000	3853765	3853.765	0.300763	1000	0	0	0
.	emit	1000	3853765	3853.765	0.333387	1000	0	0	0
/tmp/g1-log-baseline	append	1000	32216179	32216.179	3.386343	1000	0	0	0
/tmp/g1-log-baseline	emit	1000	32216179	32216.179	3.739153	1000	0	0	0
.	append	1000	3853765	3853.765	0.303878	1000	0	0	0
.	emit	1000	3853765	3853.765	0.362836	1000	0	0	0
/tmp/g1-log-baseline	append	1000	32216179	32216.179	3.598388	1000	0	0	0
/tmp/g1-log-baseline	emit	1000	32216179	32216.179	3.539512	1000	0	0	0
.	append	1000	3853765	3853.765	0.356856	1000	0	0	0
.	emit	1000	3853765	3853.765	0.403836	1000	0	0	0
```

The separate instrumented runs follow.

```text
/tmp/g1-log-baseline	append	1000	32216179	32216.179	3.551067	1000	64432358	64714853	715301
/tmp/g1-log-baseline	emit	1000	32216179	32216.179	3.501267	1000	64432358	65064639	715301
.	append	1000	3853765	3853.765	0.300995	1000	3853765	4199352	657000
.	emit	1000	3853765	3853.765	0.331082	1000	3853765	4549138	657000
```
