# Runtime validation, 22 October 2026

The stopped `archives/pre-4b6ba5b-world` snapshot supplied the paired fixtures.
Native preparation of its copy completed in 84.422 seconds. The first native
attempt failed on a fixture variable-shadowing bug; that bug has a regression
test, and its logs remain under the runtime evidence directory. An earlier smoke
attempt was refused because cc-test owned the shared lock; no server started.

The successful two-world run is recorded in `two-world-smoke.json`. Both
headless servers were alive at once and used 2 GiB heaps and two active
processors. Start admission observed load1 1.35 and about 20 GiB available memory.
Their recorded RSS was 2,506,544 and 2,645,152 KiB. Both exited with code 0;
`pool status` was empty after cleanup.

| Operation | World 1 | World 2 |
| --- | ---: | ---: |
| Clone | 0.796 s | 1.778 s |
| Cold serve to native ready | 30.663 s | 30.308 s |
| Already warm serve | 0.001 s | 0.001 s |
| Exact-commit file-copy install | 2.090 s | 1.882 s |

Both worlds installed server-only commit
`d6530a01a1f186475ba1bda938a283090d3e8806` on the six application disks plus
unpaired probe 10. The pocket disk was installed offline; no client ran.
Both real server terminals showed status, and saved native NBT placed miner 4
at `[-5,64,3]`, facing south. A later fast-path native pose read took 0.002 s.
These timings describe this smoke run, not a complete Gate B speedup.

18 focused tests pass, including manifest geometry, port contention, independent
clones, native saved NBT, offline file reads, secret-path exclusion, bridge role
globals, asynchronous cancellation, process ownership and admission boundaries.
Python compilation, Lua syntax, Cobalt locals and scope checks pass.

The first plain cc-test run lost its Windows connection with exit 125. The
retry's terminal result was lost when the agent turn was interrupted. The final
plain run selected local-2 and passed all 617 tests with exit 0. Its complete
log is saved at `~/work/gateb-runtime2/evidence/cc-test.log`; the final output
is also retained in `full-suite.txt`.

Native HTTP installation and interruption, three or four concurrent worlds,
CraftOS-PC sandbox screenshots, and Xvfb/client crash recovery were not exercised
in this smoke. C3/C13 need the driver's real client and reviewed pixel evidence.
The runtime imports a stopped paired snapshot; it does not manufacture pairing
keys or create a fully paired world without that snapshot.

Full native logs, terminal captures, fixture commands, failed attempts and large
assets stay under `~/work/gateb-runtime2`. No so-keys files enter the repository
evidence. The live server and `~/work/mc-serverfiles` were untouched.
