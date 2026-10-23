# Wave 1 mining validation

The focused logs cover exact readiness refusals, successful admission, named chest
causes, single-mode compatibility and compact setup frames. The frames come from
mocked display callbacks and are not Minecraft screenshots.

Linux UI0 passed all ten checks with no skips. The four disk-guard display checks
passed with paired workers and fuel reports. Disk-guard writes screenshots to the
host, so its focused part runner refused those writes. The direct Linux run in
`disk-guard.log` exercises those checks with evidence enabled.

The Pack-ROM emulator passed its server, protocol, display and peripheral checks.
The original emulator evidence is `/tmp/craftos-evidence-721khpqy`. Only its public
summary is copied here. Computer disks and pairing material are not copied.

Syntax checks passed for every changed Lua file. The Cobalt log covers every
changed Lua file and stays below 185 locals. Luacheck has zero errors for the
changed production code and focused test files. The append-only canonical runner
has its existing injected `__suite_test` global and is checked through the full
suite's runner. The UTC allow-list passed.

An independent code review found and reproduced a single-mode budget regression,
misclassified `no inventory` errors, and a wrong-species sapling alert. The fixes
have focused regression tests. All five continuation regressions passed, including two miners, restart, stop and
budget extension, ore and fuel trips during return, and a newly found return vein.
Continuation keeps the old route and saves the
next branch claim before returning through the shared lane.

Compact mining and lumber alerts now draw after the tiles, with the alert hit
target retained before navigation. The new checks verify that the missing item
and named chest cause are visible at both compact sizes.

The full-run fixture updates configure real paired workers, reported fuel and
required drops before admission. SO11 B now waits for a dig in flight alongside
three open work leases, so the power cut still proves interrupted dug replay
after readiness adds setup time. Its exactly-once assertions are unchanged.
The reboot comparison samples the same pre-cut cell set on both sides. Digs
completed during the outage are checked by interrupted-dig replay, rather than
being added to the baseline persistence sample. All 18 SO11 A/B checks passed
at 4x after this correction.

The final full-suite logs are saved outside the checkout under
`~/work/fix-round/evidence/w1-mining/`, in a folder named for the tested head.
The PR records the result and tested SHA.

Gate B was not run. The orchestrator owns real-game runs. Affected checks are
C5, C7 and C8 for mining and C6 for lumber start and chest failures.
