# Server-only docs

Open `docs/` as an Obsidian vault. Start with [[SERVER-ONLY-MAP]]
([architecture map](SERVER-ONLY-MAP.md)) for files, public APIs, the event loop,
persistence and checks. Read [[server-only/PROTOCOL]]
([protocol](server-only/PROTOCOL.md)) for wire formats and module contracts.

## Wave plan

This is the planned sequence, not a completion report.

1. Wave 1 is SO0, the server core, protocol, pairing, store and test harness.
2. Wave 2 is SO1 state and logs, SO2 workers, SO5 displays and SO8 drop points.
3. Wave 3 adds cells, leases and the shop adapter.
4. Wave 4 adds W4-0 report facts and plan helpers, SO3 mining and SO7 lumber.
5. Wave 5 adds the SO9 installer and SO10 AR.
6. Wave 6 is the SO11 integration run.

See [[server-only/PROTOCOL#Tasks]]
([task ownership](server-only/PROTOCOL.md#tasks)) for the module assignments.

## Open gaps

- `install.lua` lists no `so-*` files yet. SO9 must include the core files,
  thin clients, `lib/ccryptolib/`, `so-log.lua`, `so-plan.lua`, planner files
  and every `so-mod-*.lua`.
- Lease records are memory-only. Planners must recover durable reservations
  with park leases after a server restart.
- Mining SO3 and lumber SO7 are in progress in wave 4. Their modules are absent
  from the mapped base, as is SO10 AR.
- Offline checks do not replace CraftOS-PC sandbox runs or integration with
  a local Minecraft server and real mods. Those environments are unavailable
  for this docs change, so in-game checks remain untested.

See [[SERVER-ONLY-MAP#Open gaps]]
([map gaps](SERVER-ONLY-MAP.md#open-gaps)) and [[SERVER-ONLY-MAP#Tests and checks]]
([checks](SERVER-ONLY-MAP.md#tests-and-checks)) before starting the next task.
