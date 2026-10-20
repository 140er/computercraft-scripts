# PR 5 verification

Gate A passes with the Tom monitor and opt-in hub hostname fixes. Gate B remains incomplete. Native failures and partial results are preserved separately from passing evidence.

The mock suite passed 104 tests and the standalone core rendering, Tom monitor and UI checks. `mocks.txt` contains the complete UTF-8 transcript. `focused.txt` retains the earlier rendering, UI and manual-control checks.

`gateA.json` combines the seven CraftOS result files and physical world state from the final `multi-view` run. Three production miners completed nine moves with zero collisions. Each arrived at x=1, y=65, with z=-3, 0 or 3. The disk limit was 4,000,000 bytes. The least remaining space was 2,753,309 bytes. No recovery reboot was needed in this run. `gateA-source-sha256.json` records the copied production files.

`hub-pro.png` is a CraftOS framebuffer capture with three fleet rows. `warehouse-normal.png` mirrors the actual monitor drawing calls onto the CraftOS framebuffer. It is a monitor-output mirror, not a native monitor-window or Minecraft capture. The two capture JSON files retain the calls and fixture metadata.

The sandbox uses its own data directory and modem network. It disables fleet mesh forwarding for the emulator fixture, whose physical-world operations otherwise add radio RPC traffic absent from a real turtle. `transport-diagnostic.json` preserves failed attempts, the limits of the tracing instrumentation and the first successful run. Those failures are not counted as passes. The earlier `tom-fixed` run also recovered from one turtle timeout through a bounded reboot.

The native harness uses a fresh test root, checked ports, the shared lock, a 3 GB server heap and owned process IDs. It requires actual DirectGPU creation, wired and adjacent selection, two displays, camera modes, frame caching and throttling, a normal warehouse monitor, Tom's GPU, a real client click followed by physical movement, and restart/rebuild evidence. The four F2 screenshots and performance results are still pending. No native rendering claim is made from mocks or CraftOS images.

The normal monitor passed in the first native attempt. Tom controls overflowed its 64-pixel screen, which now has a regression test and a responsive layout fix. A second attempt passed Tom but stopped when another view computer claimed the same legacy hub hostname. Enabled views now fall back to a unique hostname. A third attempt recorded watchdog terminations and empty reports during a VM slowdown. Its owned server was stopped and cleanup released the lock.

The fourth attempt found that the fixture's hardcoded GPU side wrapped a wired modem. The fixture now finds the actual DirectGPU peripheral and records its methods. The fifth created a real display, then checked for scene data before the controller had saved its scan seed. The fixture now waits up to 180 seconds for a populated rendered scene and records refresh diagnostics. `gateB-fifth-attempt.json` and `native-directgpu-peripherals.json` preserve that partial result. Production code did not change for either fixture repair.

The sixth attempt stopped when a production miner could not obtain a GPS observation. Other computers left empty reports, and the server log records watchdog terminations. Host coordinates and modem placement were correct. About 25 seconds elapsed between turning on the GPS hosts and turtles; that does not establish host readiness or the cause of the failure. A native-only preflight now requires two consistent, in-bounds observations from real GPS within 180 seconds before launching each miner. Production GPS calls and watchdog limits remain unchanged. `gateB-sixth-attempt.json`, `native-sixth-server.log` and `native-sixth-gc.log` retain the failed run. The curated server log trims trailing whitespace.

Client polling now waits for complete JSON and preserves the exact parsed bytes. A valid failure verdict still fails immediately. `client-json-checks.txt` records the focused checks.

The warehouse fixture replaces only PR 4's `wh-sites` read boundary. Mine snapshots, command authentication and navigation use production code. See `../../ssot-pr5.md` for the interface and configuration.

Full logs and failed attempts remain at `C:\Work\gemini-input\p2\evidence\pr5`. The two CraftOS PNGs are also in `C:\Work\gemini-input\shots`.

The third attempt's log is native-watchdog.log. It records whole-server lag and watchdog stacks in scheduling and error cleanup. It does not establish a Lua loop, GC failure or memory exhaustion. Later probes keep watchdog limits unchanged, add GC/safepoint logs, stagger startup and reject partial JSON verdicts.
The curated watchdog log trims trailing whitespace. The original remains in the full evidence directory.
