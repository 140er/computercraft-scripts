---
name: gate-b
description: Run gate B, the in-game test on a disposable NeoForge 1.21.1 server with the real client, on the Windows worker async-repro-win10. Use when a PR needs gate B, F2 screenshots or a video clip, or when asked to verify a branch in Minecraft.
---

# Gate B

Gate B boots throwaway Minecraft servers on the VM, runs the `tests/ingame` scenarios against a branch, captures client F2 screenshots and a video, and writes `SUMMARY.md`.
It never touches the live server. Never connect to 100.91.208.60 or its RCON.

## Where it runs

Only on the My Machines worker `async-repro-win10` (Windows 10, Windows PowerShell 5.1, user LabAdmin).
Cursor-hosted Linux agents cannot run it. They run gate A (`tests/sandbox/run.ps1`) instead.

## Run it

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\ingame\gateb.ps1 -Ref <branch or refs/pull/N/head>
```

- `-Scenario ssot,nav,mining,warehouse` is the default and the only set that can pass.
- `-Output <dir>` defaults to `C:\Work\gateb-evidence\<stamp>`.
- Exit code 0 is `GATES: PASS`, 1 is `GATES: FAIL`, 2 is `GATES: PARTIAL`.
- `GATES: PARTIAL` means a subset of scenarios ran. It is not a pass. Use it only to debug one scenario.
- A full run takes about 40 minutes, plus any wait for holds and locks. Start it in the background and poll `SUMMARY.md`.

## Reading SUMMARY.md while it runs

The first line is `GATES: RUNNING` until the run ends. The heartbeat line names the time and the current step and is rewritten at every step.
If the heartbeat is older than 60 minutes, or the PID it names is gone, the run is dead. Report it as a FAIL.

## What the script does

1. Fetches `-Ref` into a fresh folder. The Lua code and the scenario drivers both come from that ref.
2. Reads the live jar sha256 list from gatebd (`Get-GatebHealth`) and stages exactly those jars from the hash-keyed cache. A missing jar or a different hash stops the run.
3. Waits while a hold is active, meaning `C:\Work\gemini-input\p2\gateB.hold` exists or gatebd health reports `hold`. It checks again before each scenario. Create that file to pause gate B runs, for example during VM maintenance.
4. Waits for `gateB.lock` and 5 GB free RAM, then holds the lock for the whole run. `owner.txt` names the host, stamp, PID and process start time.
5. Per scenario, takes `gateB-client.lock` through gatebd's `Enter-GatebClientLock` and runs `tests\ingame\run.ps1 -Client`.
6. Fails a scenario on a non-PASS verdict, no F2 screenshot, a jar whose hash differs from live, or a live jar the test server did not load. Fails a full run with no video clip.
7. In `finally`, in this order, it stops this run's java, deletes the test folders and the staged base, releases the client lock, then releases the server lock. Junctions are unlinked with `cmd /c rmdir` first, so the shared `libraries` folder is never deleted.

## Dead runs and stale locks

A run killed hard skips its `finally`. The next gateb.ps1 run cleans it up.
It reclaims a lock only when `owner.txt` was written by gateb.ps1 on this host and that PID is gone or now belongs to a process with another start time.
It then stops that run's java, deletes that run's folders the junction-safe way, and removes the lock.
Locks written by anything else, such as `PR 6`, are never reclaimed. Wait for them.

## gateB-depth.md

If the ref has `docs/testing/gateB-depth.md`, each `- ` item needs a line in `tests/ingame/depth-map.txt`:

```
warehouse | Build the warehouse room in the world.
```

The text is the start of the depth item. An item counts as covered only when its mapped scenario passed in this run. An item mapped to a scenario that a subset skipped leaves the run at PARTIAL. Uncovered items go to `depth-not-run.txt` and fail the run.

## Rules

- Never delete or take over a lock someone else holds, except the dead gateb.ps1 runs above.
- Never stop java or Codex processes you did not start. Codex works in `C:\Work`.
- Never restart the VM or change its CPU pinning.
- Never commit `token.txt`, the gatebd token or the box address.
- A skipped scenario, a missing screenshot or a missing video is not a pass. Never round it up.

## Report

Quote the `GATES:` line, the ref and sha, the scenario table and the problems from `SUMMARY.md`.
Name the host as "VM-local disposable server, not live".
Attach `SUMMARY.md`, the screenshots, the `.mp4`, `rcon.txt`, `latest.log` and `jar-sha256.txt` from each scenario folder.
