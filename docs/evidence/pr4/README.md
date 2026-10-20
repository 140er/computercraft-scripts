# Warehouse acceptance evidence

Both gates passed with the final production files. Post-rebase checks matched the saved computer disks in both gates to the repository files. The native runner exited zero after checked probe resumes. The disposable server and client are stopped.

## Commands

Run from the repository root in PowerShell. Prefix each `.ps1` command with `powershell -NoProfile -ExecutionPolicy Bypass -File`.

```powershell
C:\Tools\lua52\lua52.exe tests\run.lua
tests\sandbox\run.ps1 -Scenario warehouse -Seconds 1800 -Output C:\Work\gemini-input\p2\evidence\pr4\gateA\accepted-final
tests\sandbox\run.ps1 -Scenario smoke -Seconds 120 -Output C:\Work\gemini-input\p2\evidence\pr4\gateA\legacy-final
tests\review-capture.ps1 -Output C:\Work\gemini-input\p2\evidence\pr4\gateA\capture
tests\ingame\run.ps1 -Scenario warehouse -Client -Timeout 1500 -Output C:\Work\gemini-input\p2\evidence\pr4\gateB\accepted-final
tests\ingame\run.ps1 -Scenario warehouse -Client -ResumeProbes -TestRoot C:\Work\mc-ssot-pr1-10370dfa -Timeout 1500 -Output C:\Work\gemini-input\p2\evidence\pr4\gateB\accepted-final
```

## Gate A

Six computers include three physical turtle emulators. Their shared world recorded 224 moves and zero collisions with 4,000,000-byte disks. Three orders delivered 33 iron ingots and three nonstackable pickaxes to one shared drop. Each source retained its seven dirt blocks. The miner unloaded two ore blocks and completed its saved traversal. The fixture rebooted the entire CraftOS process after physical pickup, delivery, and wrong-item restoration checkpoints. It injected dropped, duplicated, and reordered acknowledgements. The low-fuel worker charged during its order and continued with its cargo.

The focused mock suites cover empty sources, full drops, wrong items, competing bays, unavailable and slow charging, timeout, unlimited fuel, dead ends, blocked passing cells, and invalid requests. The full suite passed 98 counted regressions plus its focused suites. Legacy smoke passed. [The headless capture](hub-current.png) shows the existing idle hub. It does not show a warehouse monitor or Pro Mode.

[Run transcript](gateA-run.txt), [coverage](gateA-coverage.json), [results](gateA-warehouse-results.json), [source hashes](gateA-source-sha256.json), [durable state](gateA-durable-state.txt), [mock transcript](gateA-mocks.txt), and [smoke transcript](gateA-smoke.txt).

## Gate B

The disposable world is `C:\Work\mc-ssot-pr1-10370dfa`, with game traffic on localhost:65382 and RCON on localhost:65383. It uses the supplied turtlebattery 0.3.0 jar, SBW 0.8.9.2, Classic Peripherals with `enderModemNerf=false`, and 4 MB computer disks. The full mod hashes accompany the results.

The first run with the final production files passed the warehouse, traffic, physical-transfer restart, mining, inventory, range, power, and moving-loader checks. It failed because the isolated normal turtle's chunk retained an explicit force ticket after restart. The checked resume reruns the hardware section in that completed world after checking the production hashes, saved orders, mining completion, and unchanged mod hashes. It preserves earlier transcripts, probe results, and failed capture frames in `before-resume-*`. It does not replay or replace the warehouse results.

Subsequent resumes repeat the probes after fixing a capture race and retrying a failed client launch. The first clip attempt copied partial PNGs before Minecraft completed them, and FFmpeg rejected them. The helper now waits for the PNG end marker. One later client launch failed inside NeoForge early-window configuration before opening a window. Its crash report remains under the external `gateB/client-window-failure/` directory. The unchanged client launcher was retried.

The powered station charged at offsets eight on each axis, including the diagonal and corner. An offset nine on one axis did not charge. This jar uses an inclusive box, not a sphere. A station without energy and a missing station did not increase fuel.

A moving ender turtle crossed a chunk boundary and continued charging with zero players online. A separate running ender turtle kept the server's chunk ticking. The standalone server computer did not load that chunk itself. The loader sample covers a 15-second wait without players and one boundary crossing. It does not prove indefinite station loading after the turtle leaves. Provide persistent loading for the server, GPS hosts, and station before deployment. No code depends on `far_beacons`.

Gate B passed physical counts of 33 iron ingots and three pickaxes in the shared drop, seven protected dirt blocks per source, and two mined diamonds in the mining drop. The saved dispatcher has three partial orders, no bay locks or pending moves, and one completed mining task. Charging resumed after both isolated chunks unloaded and reloaded. Fuel stayed fixed after the powered station broke.

[Successful resume transcript](gateB-run.txt), [initial failure transcript](gateB-initial-run.txt), [results](gateB-warehouse-results.json), [durable state](gateB-durable-state.txt), [source hashes](gateB-source-sha256.json), [mod hashes](gateB-jar-sha256.txt), [RCON transcript](gateB-rcon.txt), [raw probe records](gateB-probes.json), [unloaded chunks](gateB-station-unload.json), [server loader heartbeat](gateB-server-loader.json), and [final server log excerpt](gateB-latest-excerpt.log). The external evidence directory retains full logs and the failed diagnostic runs.

[Warehouse F2 screenshot](warehouse.png), [recharge clip](recharge.mp4), [first frame](recharge-before.png), [last frame](recharge-after.png), and [video validation](video.txt). The 14.52-second clip uses real F2 frames with their observed timing. Its probe measured fuel rising from 113 to 157. The screenshots retain Minecraft's capture chat messages.

## Review and decision trail

[Setup commands](../../warehouse.md), [design and throughput checkpoint](plan.md), and [append-only decisions](decisions.tsv) record the choices and failed diagnostics. All behavior that moves a live turtle requires explicit enablement. No live server was contacted and no merge was performed.

The PR 1 rules require one agent and only gpt-6.1-sol. Design, implementation, and review ran in this session. The requested cursor-team-kit deslop skill was unavailable. The final diff received manual prose and no-comments checks.
