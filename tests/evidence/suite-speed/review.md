Reviewed the full runner, slot adapter, CI gate and lint configuration.

The canonical test file retains its original prefix. The companion runner fails
if its callback marker disappears or becomes ambiguous. New suite files are
discovered from the canonical runner and assigned even without saved costs.
Every shard discovers the same groups; tie breaking uses the path. SO11 A and B
cache their scenario state independently and run only when selected. The final
gate rejects a failed process or a missing or mismatched shard summary.

The lint runner checks unknown reads, accidental global assignments and syntax
errors. The scratch test confirms these failures and unused-local warnings.
CC extensions are declared by name. The only write exemptions apply to the
existing boot wrappers. Product code is unchanged.

Sequential and sharded logs must have identical CHECK-TIME identities before
handoff. Syntax and local limits include the vendored Lua modules. The vendor
contains only the pure Lua API closure because its unused upstream SHA helper
uses Lua 5.3 syntax. Remaining files match the pinned upstream source.

Gate A rendering/turtle behavior and Gate B gameplay are not certified by this
tooling change. The orchestrator owns the frozen server-only Gate B run.

One compatibility issue was fixed during review. The installed adapter now
uses the full runner only in checkouts containing the new tooling. A mocked
scheduler probe confirms older checkouts retain their original full-suite path.

Final coverage comparison passed. All three runs have the same multiset of 617
check identities. The sharded run passed using local-2 and Windows. Contention
serialized its first three shards and delayed Windows acquisition; the saved
361.46-second wall time is not evidence of a parallel speedup. A benchmark with
several free slots is still needed. No slot infrastructure errors occurred.
The non-POSIX probe executes the real UI0 generator branch and confirms its
named skip appears in a zero-pass, one-skip final summary.
