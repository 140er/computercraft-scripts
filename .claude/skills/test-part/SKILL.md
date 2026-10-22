---
name: test-part
description: Run isolated server-only module regressions through cc-test while editing Lua, then run the full suite before a PR.
---

Work from the repository root. Install the slot adapter once with
`python3 tools/install-test-parts.py`.

Use `cc-test --part server` or `cc-test --part miner` while iterating.
These aliases mean `so-server.lua` and `so-mod-mine.lua`; the normal-build
`server.lua` and `miner.lua` are outside this kit's scope.
The default layer requires version-checked CraftOS-PC integration.
The pack pins Minecraft 1.21.1 / CC:Tweaked 1.120.2. CraftOS-PC 2.8.3
targets CC:Tweaked 1.112.0, so the default currently refuses the mismatch.
Do not turn a diagnostic probe into a passing exact-integration result.
For a faster plain-Lua unit run, explicitly use
`cc-test --part so-mine-plan.lua --lua-only`.
Use `cc-test --part tests/so/lease.lua --lua-only` to run one regression file.
`scripts/test-part <part>` forwards to the same scheduler.

Part selection derives focused regression names and dependency closures from
source. The command prints its selected suites. Numbered scenarios such as
SO3 and SO11 remain explicit parts, not implicit module iterations:
`cc-test --part tests/so/so11.lua`.
A module without a matching suite uses its related non-scenario regressions.
This can be slower; choose one printed regression file for the next iteration.

Each run has a private input directory and in-memory fake computers. The kit
copies only the generated dependency closure, guards reads and Lua loaders,
and fails any undeclared read even if a test catches its exception.
A dependency failure calls for fixing the source graph resolver or making the
loader expression statically resolvable, never disabling the guard.
Part runs use the existing free local, Windows and PC slots. Do not force a
slot unless the test needs it, and record the reason.

Run plain `cc-test` once before opening the PR. Preserve its log and the part
log, including slot, input count and timings. Full-suite tests cover scenarios
that focused parts omit. Computer disks use the server-only 16 MB budget;
smaller-budget rejection tests keep their intentional limits.
Real-server/gameplay testing is at the orchestrator's discretion. Never use
the live Minecraft server. Read [the kit README](../../../../docs/testing/README.md)
for version pins, emulator fidelity and the peripheral coverage table.
