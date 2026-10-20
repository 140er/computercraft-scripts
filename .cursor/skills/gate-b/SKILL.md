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

- `-Scenario ssot,nav,mining,warehouse` is the default. Keep `warehouse`, because it records the video clip.
- `-Output <dir>` defaults to `C:\Work\gateb-evidence\<stamp>`.
- Exit code 0 means `GATES: PASS`. Anything else is a fail.
- A full run takes one to two hours, plus any wait for the locks. Start it as a background command and poll `SUMMARY.md`.

## What the script does

1. Fetches `-Ref` into a fresh folder. The Lua code and the scenario drivers both come from that ref.
2. Reads the live jar sha256 list from gatebd (`Get-GatebHealth`) and stages exactly those jars from the hash-keyed cache. A jar that is missing or has another hash stops the run.
3. Waits for `C:\Work\gemini-input\p2\gateB.lock` and 5 GB free RAM, then holds the lock for the whole run.
4. Per scenario, takes `gateB-client.lock` through gatebd's `Enter-GatebClientLock`, runs `tests\ingame\run.ps1 -Client`, and releases the client lock.
5. Checks each scenario's verdict, its F2 screenshots and its `jar-sha256.txt` against the live hashes.
6. Releases both locks and deletes every test folder and the staged base, even on failure. Junctions are unlinked first, so the shared `libraries` folder is never deleted.

## Rules

- Never delete or take over a lock someone else holds. Wait for it.
- Never stop java or Codex processes you did not start. Codex works in `C:\Work`.
- Never restart the VM.
- Never commit `token.txt`, the gatebd token or the box address.
- A skipped scenario, a missing screenshot or a missing video is a `GATES: FAIL`. Report it as a fail with the reason. Never round it up to a pass.
- If the ref has `docs/testing/gateB-depth.md`, the script lists its items in `depth-not-run.txt` and fails. Cover them by adding scenarios to `tests/ingame/run.ps1` on the branch, then run again.

## Report

Quote the `GATES:` line, the ref and sha, the scenario table and the problems from `SUMMARY.md`.
Name the host as "VM-local disposable server, not live".
Attach `SUMMARY.md`, the screenshots, the `.mp4`, `rcon.txt`, `latest.log` and `jar-sha256.txt` from each scenario folder.
