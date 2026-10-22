# Gate B runtime

Use Python 3 on Linux. The runtime needs an installed local NeoForge server,
Java 21 and a stopped Gate B world snapshot. The existing snapshot supplies the
paired computers, pocket, monitor wall, AR controller and storage program.
It does not download mods or write into the live reference configuration.

Large files stay in `~/work/gateb-runtime2`, which has private permissions.
Override that directory with `GATEB_HOME` or CLI `--home`. To use other test
assets, create `config.json` there:

```json
{
  "server_source": "/path/to/test-server",
  "snapshot": "/path/to/stopped-test-world",
  "java": "/path/to/java21/bin/java",
  "client_source": "/path/to/test-client",
  "port_start": 25600,
  "port_end": 25700
}
```

Run after the current Gate B session releases `~/work/test-suite.lock`:

```sh
python3 tools/gateb/world.py build-template
python3 tools/gateb/world.py clone smoke-1
python3 tools/gateb/world.py clone smoke-2
python3 tools/gateb/world.py serve smoke-1
python3 tools/gateb/world.py serve smoke-2
python3 tools/gateb/world.py install smoke-1 FULL_SHA --mode copy
python3 tools/gateb/world.py api smoke-1 '{"op":"terminal","computer":1}'
python3 tools/gateb/world.py api smoke-1 '{"op":"save"}'
python3 tools/gateb/world.py api smoke-1 '{"op":"turtle","computer":4}'
python3 tools/gateb/world.py stop smoke-1
python3 tools/gateb/world.py stop smoke-2
```

Build imports and cleans a private snapshot copy, starts a disposable headless
server to prepare the native fixtures, then saves and stops it. A completed
template has `prepared:true`. If preparation fails, keep the failed build logs
under `runs/template-build`, move the unfinished `template` directory aside and
retry. Source snapshots must have a `session.lock`; the importer refuses an
active Minecraft record lock. Keep snapshots from clean server shutdowns.

Each clone has independent mutable files. GNU `cp --reflink=auto` uses copy on
write where supported and independent copies elsewhere. There are no world
hardlinks. Reset restores the template and restarts a running server. Minecraft
cannot safely accept replacement region files while those chunks remain loaded.

`serve` waits for Minecraft's native ready marker. The shared pool keeper owns
the test-suite flock and the exact child processes it starts. Each server uses
a 2 GiB heap, two active processors and 256 MiB direct memory. Admission refuses
new servers or clients below 3 GiB available memory. An additional server
also requires load1 below 8 and more than 8 GiB available memory; refusal
reports both measurements. Pool up also applies those thresholds before
its first new world. `pool up 3`, `pool status`
and `pool down` manage named pool worlds and report RSS. Ordinary world servers
and clients share the same pool lock. Shut them down before running cc-test.
BlueMap's copied web listener is disabled, and voice chat binds to loopback on
the run's UDP port. The Minecraft port binds only to loopback; RCON is disabled.

`client RUN start` uses a private client directory and Xvfb display.
`client RUN shot` saves a real PNG, and `client RUN stop` stops both processes.
Restarting after either process dies recreates the pair. The pocket only runs
when GateBTester connects. Screenshots need Xvfb and ImageMagick's `import`.
C3 and C13 still need the driver to position the player and interact with the
native UI and goggles; launching a client does not prove those checks.

The file-copy installer reads the target commit's role manifest, removes retired
files and verifies SHA-256 hashes. It refuses pending installer transactions.
The HTTP mode executes the normal installer and retains failures in
`runs/RUN/install.json`; it needs a connected client for the pocket. The pinned
installer mode changes only commit resolution and retains native HTTP downloads.
Every mode keeps pairing state and adds a test-only startup bridge. The bridge
runs installer recovery before loading the role. Its Lua environment exposes
server `SO` and captured display `GATEB_FRAME`. The bridge is not application
source and never enters an installer role manifest.

See [API.md](API.md) for the request contract. Terminal rows contain actual CC
text and blit colours. Block, inventory and turtle position readers decode saved
Anvil/NBT files. Save first for current disk evidence. Host-side journal reads
work while computers are off or chunks unloaded. Input acknowledgement proves
queuing; the driver must verify the resulting application state. Do not return
pairing keys from Lua snippets or include private screenshots in evidence.

Run the fast tests separately from the Lua suite:

```sh
python3 -m unittest discover -s tools/gateb -v
luac5.2 -p tools/gateb/bridge.lua
python3 tools/cobaltlocals.py tools/gateb/bridge.lua
```

`python3 tools/gateb/smoke.py` builds a new template, starts two worlds together,
installs the current server-only tip, reads each real terminal and native turtle
pose, then stops both servers. It refuses to replace an existing template. Use
`--reuse-template` only when that template has already completed preparation.
Timing and sanitized terminal evidence go under the runtime home's `evidence`.
