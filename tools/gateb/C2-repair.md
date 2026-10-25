# C2 display repair

Select the B1-U repair scenario on the pinned merged tip:

```sh
GATEB_C2_REPAIR=1 python3 tools/gateb/run.py --checks C2 --sha FULL_COMMIT_SHA --worlds 1 --output /tmp/c2-repair
```

Without `GATEB_C2_REPAIR=1`, C2 keeps its existing invitation and rejection scenario.
The opt-in selects repair instead. Run ordinary C2 separately when both results
are needed. Repair requires 20 TPS and the standard private Gate B fixture with
its wall, pocket and spare `probe` computer. The native client must be available.

The driver verifies both clients are paired to the original server, shuts that
server down, and boots the spare computer with the pinned server programs and
fresh state. It enables `repairServer` in each client's `so-display.cfg` while
preserving the other settings. No credentials or job state are copied to the
replacement server.

The wall receives native `monitor_touch` events at every cell of each attached
monitor. These are injected through the test bridge into the real display event
loop. The driver checks the read-only view, CHANGE SERVER, change confirmation,
candidate entry, empty code entry and partial code entry. It compares the target,
repair step, digit count, peer fingerprints and hashes of all `so-keys` generations.
Local terminal and pocket inputs then confirm the candidate and enter the six
digits. Both clients must retain only the new peer after reboot, match the server's
key fingerprint, and receive a fresh authenticated frame.

The test-only bridge loader exposes an observer before the display's final loop
call. It does not write the installed `display.lua` or replace its repair handlers.
The observer returns ids, digit counts and 16-character SHA-256 fingerprints.
It never returns keys or entered digits. The runtime loader is restored and the
native client is stopped on exit. The normal driver owns world shutdown.

Evidence includes `C2R-observations.json`, before/after attack snapshots, terminal
and monitor snapshots with empty credential fields, a fresh received frame for
each reboot, and four native photos showing repair and reboot. Candidate entry
and partial code snapshots contain state only. Photos document the run and do
not claim reviewed visual approval. The C2 result records the exact commit and TPS.

This tooling PR runs mocked tests only. The UI-B orchestrator runs native Gate B
on the pinned merged tip and reviews its evidence.
