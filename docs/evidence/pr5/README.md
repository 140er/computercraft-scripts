# PR 5 verification

Gate A passes. Gate B is pending while the shared client lock is held by another PR.

The mock suite passed 102 tests. `mocks.txt` contains the complete transcript. `focused.txt` records the rendering, UI and manual-control checks after the final production edits.

`gateA.json` combines the seven original CraftOS result files and physical world state. Three production miners completed nine moves with zero collisions. Each arrived at x=1, y=65, with z=-3, 0 or 3. The disk limit was 4,000,000 bytes. The least remaining space was 2,754,638 bytes. `gateA-source-sha256.json` records the copied production files.

`hub-pro.png` is a CraftOS framebuffer capture with three fleet rows. `warehouse-normal.png` mirrors the actual monitor drawing calls onto the CraftOS framebuffer. It is a monitor-output mirror, not a native monitor-window or Minecraft capture. The two capture JSON files retain the calls and fixture metadata.

The sandbox uses its own data directory and modem network. It disables fleet mesh forwarding for the emulator fixture, whose physical-world operations otherwise add radio RPC traffic absent from a real turtle. `transport-diagnostic.json` preserves failed attempts, the limits of the tracing instrumentation and the final successful run. Those failures are not counted as passes.

The native harness uses a fresh test root, checked ports, the shared lock, a 3 GB server heap and owned process IDs. It requires actual DirectGPU creation, wired and adjacent selection, two displays, camera modes, frame caching and throttling, a normal warehouse monitor, Tom's GPU, a real client click followed by physical movement, and restart/rebuild evidence. Its four F2 screenshots and performance results are still pending. No native rendering claim is made from mocks or CraftOS images.

The warehouse fixture replaces only PR 4's `wh-sites` read boundary. Mine snapshots, command authentication and navigation use production code. See `../../ssot-pr5.md` for the interface and configuration.

Full logs and failed attempts remain at `C:\Work\gemini-input\p2\evidence\pr5`. The two CraftOS PNGs are also in `C:\Work\gemini-input\shots`.