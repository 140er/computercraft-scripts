# Gate B runtime API v1

The runtime is a local Python 3 CLI and importable module. All large files live
under `GATEB_HOME`, default `~/work/gateb-runtime2`. It never connects to a remote
Minecraft server. Run commands from the repository root.

```sh
python3 tools/gateb/world.py build-template --snapshot /path/to/stopped/world
python3 tools/gateb/world.py clone smoke-1
python3 tools/gateb/world.py serve smoke-1
python3 tools/gateb/world.py install smoke-1 FULL_COMMIT_SHA --mode copy
python3 tools/gateb/world.py api smoke-1 '{"op":"terminal","computer":1}'
python3 tools/gateb/world.py stop smoke-1
```

Every successful CLI call prints one JSON object. Errors print
`{"ok":false,"error":"..."}` and exit nonzero. Python callers can add this
directory to `sys.path`, then use `from world import Runtime` and
`Runtime(home=None).request(run, request, timeout=15)`. Responses are JSON values
as below; failures raise `RuntimeError`. The CLI wraps responses in
`{"ok":true,"result":...,"elapsed_s":...}`. Timeouts are seconds.

`manifest.json` contains `version:1`, `dimension`, `computers` keyed by decimal
ID with `role`, `kind`, `pos:[x,y,z]`, and `facing`; `fixtures` keyed by name with
`pos` and `kind`; `forceload:[x1,z1,x2,z2]`. Roles are server, display, worker.
Named computers are `server`, `wall`, `pocket`, `miner1`, `miner2`, `lumber`,
`storage`. Resolve these names through each entry's `name`. Runs have private
worlds, console FIFOs, logs, bridge directories, loopback ports and process IDs.

| Request | Result |
| --- | --- |
| `{"op":"manifest"}` | The run manifest |
| `{"op":"terminal","computer":1}` | `{width,height,lines:[{text,fg,bg}],at}`. Blit colours use `0123456789abcdef`; rows and columns are 1 based. |
| `{"op":"monitors","computer":2}` | Object keyed by peripheral name, each value a terminal snapshot |
| `{"op":"files","computer":4,"path":"so-journal"}` | `{path,content}` with raw Lua serialized text. `so-data` returns a path-to-content object recursively. Pairing keys are never readable. |
| `{"op":"turtle","computer":4}` | `{pos:[x,y,z],block,nbt}` from saved native chunk NBT; call `save` first for a fresh disk snapshot. |
| `{"op":"block","pos":[0,64,0]}` | `{pos,block,nbt}` from saved native chunk NBT |
| `{"op":"chest","pos":[-4,64,4]}` | `{pos,block,nbt,items}` from saved native chunk NBT |
| `{"op":"input","computer":1,"event":"key","args":[25,false]}` | `{queued:true}`. Events include `key`, `key_up`, `char`, `paste`, `monitor_touch`. For touch use `args:["monitor_name",x,y]`. |
| `{"op":"lua","computer":1,"code":"return turtle.getFuelLevel()"}` | `{values:[...]}`. Runs in the real computer environment. No secrets in returned values. |
| `{"op":"command","command":"tick rate 20"}` | `{output:"..."}` after a correlated console completion marker. Leading slash optional. |
| `{"op":"save"}` | Console result after `save-all flush`. |
| `{"op":"power","computer":1,"action":"reboot"}` | `{action,computer}`. Actions on, off, reboot. |

The bridge runs alongside the installed role, captures its real terminal calls,
and polls requests every 100 ms. It is test instrumentation outside the role
manifest. A successful input response proves queuing, not application success.
The driver must wait for visible state or durable application evidence. A stopped
computer cannot answer bridge calls. Power-on uses native server control.
Native disk readers report saved state, never inferred journal coordinates.

`reset RUN` stops and restores the template world, then starts it if it was
running. Minecraft holds chunk and entity state in memory, so whole-world reset
always restarts. `serve` is idempotent and waits for the native Done message.
`pool up N` clones and starts `pool-1` through `pool-N`; `pool status` reports
ports, PIDs and RSS. `pool down` stops only those runs. Each server has a 2 GiB
heap, two active processors and a 256 MiB direct-memory cap. Admission requires
at least 3 GiB available memory per new server.

All servers and clients cooperate with `~/work/test-suite.lock`. A pool keeper
holds that exclusive flock while any runtime process is alive. If another Gate B
or cc-test owns the lock, starting a runtime fails without touching its files.
Port allocation and per-run mutations use separate locks. World clones use
reflinks where supported, otherwise independent copies. Mutable world files are
never hardlinked. `client RUN start|shot|stop` owns a private Xvfb display and
client directory. A later start repairs a dead client or Xvfb. Screenshots are
real client PNGs; headless snapshots are terminal text only.

Configuration is `GATEB_HOME/config.json`. Supported paths are `server_source`
for a stopped test server distribution, `snapshot` for a stopped world,
`java`, and `client_source` for an installed test client. Defaults refer to the
existing local Gate B test distribution. The live reference config is never a
write destination. Snapshot import refuses a world with an active session lock.

The API commit was pushed before implementation. Additional driver operations:

- `{"op":"frame","computer":2}` returns the latest passively observed,
  authenticated `view.frame` body, including the original button rectangles.
  Lua snippets on that display can read `GATEB_FRAME`. Snippets run in the role
  environment; server snippets can access `SO`.
- `{"op":"helpers","enabled":false}` removes all queued bridge requests and
  suspends polling. Re-enable with `enabled:true`, then reboot the computers.
  This does not change force loads; use `forceload remove all` separately.
- Turtle results include `facing` from native blockstate. File reads use the
  host filesystem and work while a computer is off or unloaded.

Fixtures include ore, fuel, wood, saplings, storage_output, storage_stock, ar and
wall. Chest entries include `side`. `mine.home` is `[x,y,z,"s"]`;
`mine.bottom`, `length` and `starts` describe the prepared snapshot.
`farm.area` is `[x1,z1,x2,z2]`, `ground` is the soil Y coordinate and
`dig_cells` names the tree roots. The snapshot retains existing durable job
state; drivers must explicitly configure and stop jobs before checks.

Pocket computer 3 is in GateBTester's saved inventory. CC:Tweaked only ticks it
when that player connects. Headless pocket terminal/input/Lua calls are
unavailable until client login. The fixture manifest sets `requires_client:true`.
Client screenshots alone do not prove C3 or C13 positioning or goggles behavior.
There is no unpaired probe in an imported snapshot unless prepared explicitly.
