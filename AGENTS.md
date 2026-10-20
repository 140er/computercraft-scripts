# Instructions for coding agents

These rules apply to every Codex (or other agent) session in this repo.

## Working mode

- Work in poteto-mode. The skill files are on the Windows VM at
  `C:\Tools\pstack\skills\`. Read `poteto-mode\SKILL.md` and its
  `playbooks\` and `references\` before you start, and follow the playbook
  that fits the task.
- Run unslop (`C:\Tools\pstack\skills\unslop\SKILL.md`) on every piece of
  prose you write: PR titles and descriptions, docs, READMEs, commit
  messages and code comments.
- Use only models included in the subscription (Codex: `gpt-6.1-sol`).
  No paid APIs or services.

## Safety

- Merging to `main` makes the live in-game computers pull the new code.
  Put new behaviour behind a config flag that defaults to off, unless it is
  a pure server-side addition that is safe by itself.
- Never touch, deploy to or test against the live Minecraft server
  (zurvur, 100.91.208.60) or its RCON.
- Do not merge your own PR. The orchestrator merges after it has checked
  the evidence.

## Testing

A change is done only when both gates pass with saved evidence:

- Gate A: CraftOS-PC sandbox, `tests\sandbox\run.ps1`, with several
  computers and turtles, under the disk limit. Mock suite:
  `C:\Tools\lua52\lua52.exe tests\run.lua`. Headless screenshots:
  `tests\review-capture.ps1`.
- Gate B: a real run on a local test Minecraft server with the real mods
  (never the live server). Keep the logs, screenshots or video.

If a gate cannot be met for real (for example DirectGPU or AR shots that
need a real client), say so in the PR. Do not fake evidence.
