# Tick clock evidence

The native clock contract comes from CC:Tweaked tag `v1.21.1-1.120.2`.
`OSAPI.clock()` counts computer updates in 0.05-second units and resets on boot.
The in-game epoch follows world daylight time and uses 72 times nominal game
milliseconds. Daylight freezes and time commands make it unsuitable for elapsed
waits. Native timers count computer ticks. The exact pack ROM does not replace
CraftOS-PC's older native APIs, so emulator results do not prove Minecraft's
accelerated scheduling.

Source files checked during the investigation:

- [OSAPI.java](https://github.com/cc-tweaked/CC-Tweaked/blob/v1.21.1-1.120.2/projects/core/src/main/java/dan200/computercraft/core/apis/OSAPI.java).
- [ServerComputer.java](https://github.com/cc-tweaked/CC-Tweaked/blob/v1.21.1-1.120.2/projects/common/src/main/java/dan200/computercraft/shared/computer/core/ServerComputer.java).
- [Environment.java](https://github.com/cc-tweaked/CC-Tweaked/blob/v1.21.1-1.120.2/projects/core/src/main/java/dan200/computercraft/core/computer/Environment.java).

`SO.now()` uses a durable reservation seeded from UTC on the first boot.
This preserves old absolute timer values without rewriting recovery state.
The reservation prevents backward observations across crashes, at the cost of
up to one extra game second per server start. Server-off time pauses. This contract
also avoids treating daylight jumps as elapsed time.

`so11-1x.log` and `so11-4x.log` contain the focused scenario runs before the
final lease-ID and queued-retry fixes. Both have 18 passing checks. Their A
scenarios deliver four ore, fell four trees and deliver 16 logs. Their B
scenarios deliver four ore, fell three trees and deliver 15 logs. The earlier 645/645 full run is in `full-suite.log`; it predates the rebase
and final legacy-server fix. It is historical evidence, not verification of
the rebased head. The PR records the new exact-head full-suite result.

A review reproduced a delayed retry extending a queued lease. The worker now
keeps the earliest queued deadline. The clock regression executes that queued
batch after its original deadline and checks that it refuses the move.
Lease IDs include durable time so a reboot cannot make this clamp mistake a
new lease for the previous one.

`syntax-locals.log` checks every changed Lua file with Lua 5.2 and Cobalt's
active-local accounting. `client-size.log` counts installed source files from
the installer role lists. `utc.log` checks every root `so-*.lua` and both clients
against the reviewed UTC allow-list.

Gate B was not run by this implementation task. The orchestrator owns the
real-game recheck and merge. The server-only map lists accelerated checks and
those that must retain real 20 TPS timing. No live server or RCON was used.

`clock-part.log` has ten passing clock regressions on the final source, including
legacy server lease-ID reuse at both speeds. A repeated legacy lease matches
both its ID and original UTC expiry; a new expiry can start a new lease.
`ui0-linux.log` has all ten UI0 checks passing, including the POSIX-only fixture
generator, with no skips. `lease-orderings.log` and
`formal/evidence/lease-orderings.json` record 483,841 traces, 17,418,260
comparisons and five caught scratch mutations. The model retains the documented
fixed-clock module-reload collision; whole-server reboot continuity has its
own clock regression.
