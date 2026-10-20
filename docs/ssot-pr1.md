# Configure SSOT coordination

SSOT is off until the server has `ssot.cfg` and a miner has `ssot.enabled = true` in `miner.cfg`. Install or update the server, hub, and miner roles to copy `atomic.lua`, `ssot.lua`, and `ssot-client.lua`. A hub can import the client without enabling miner movement.

Copy `ssot.cfg.example` to `ssot.cfg` on the server. Add each paired computer ID as a string key in `controllers`. Give each computer a separate random secret of 16 to 128 characters. Configure that computer's client with the server ID and its matching secret. Keep the configuration private.

For a miner, add this table to the existing `miner.cfg`. Replace the example values with the paired values.

```lua
ssot = {
	enabled = true,
	server = 0,
	secret = "replace-with-a-private-secret",
	dimension = "minecraft:overworld",
}
```

The miner requires a GPS world frame and an unambiguous movement journal at boot. It refuses SSOT startup if an old move or turn remains pending. Resolve that journal through the existing recovery flow before enabling the flag. Automatic navigation recovery belongs to PR 2.

The opted-in miner refuses manual drive commands. Its worker owns movement and turns. PR 2 adds a shared movement queue before manual driving can join that owner. The flag does not change manual driving on existing miners.

## Use the client

Create one client per program. Feed `client.dispatch(sender, packet, protocol)` from the program's sole application rednet receiver. Run that receiver concurrently with callers. Do not call a blocking RPC inside the receiver.

`client.resync(observedPose)` establishes the current world pose. A pose contains `dim`, `x`, `y`, and `z`. Supply GPS or another independently observed pose after a reboot. Never substitute the server's last pose for an observation.

`client.move(from, to, execute)` reserves an adjacent destination, records its token, confirms movement start, calls `execute`, and commits the result. The callback returns the native movement success and error. The library copies both endpoints before the callback runs. A timeout before confirmation never calls the callback. An uncertain result stops movement until reboot and reconciliation.

Low-level callers can use `reserve`, `start`, `commit`, `release`, and `renew`. Each accepts one fields table. Reserve needs `pose` and `to`. Later operations need the original `pose`, `token`, and `epoch`. Commit also needs `to`. A granted reservation expires. A started reservation keeps both cells blocked after expiry. Only an observed source or destination pose can reconcile it. An offline turtle's confirmed occupied cell never expires.

`scan` accepts the current `pose`, a `revision`, and up to 64 observed `cells`. Each cell has dimensioned coordinates and `name`. Use `false` for AIR and a namespaced block name for SOLID. Omit unknown cells. A delta older than a changed chunk fails. Retry from a fresh snapshot. The server interns up to 256 names.

`snapshot` accepts `chunk`, optional `cursor`, and optional `revision`. The chunk key is `dimension|cx|cy|cz`. A page returns at most 64 index-and-name pairs, its revision, and its next cursor. Cursor zero means completion. Pin the returned revision on later pages to reject a changed chunk. Pages have a configurable encoded limit between 1,024 and 8,192 bytes.

## Pair chat identities

The configuration defaults to the player names `Jeffreyy2`, `njov10`, and `yolobeerman`. Names alone grant no permission. Add their exact UUIDs to `chatUUIDs`, keyed by player name. Obtain the UUIDs once from the local server's player records or an observed AP `chat` event. Use full UUID strings with hyphens. `ssot.chatAllowed` requires both the configured name and UUID. Empty or unresolved entries deny access.

PR 1 adds this authorization check. It adds no chat commands. PR 6 owns the chat adapter and commands.

## Understand the trust boundary

Every SSOT request carries version 1, a request ID, an expected response type, a monotonically increasing durable counter, a turtle boot identity, and the paired secret. Replies include the server ID and the matching secret. Clients check the sender, server ID, secret, version, response type, and pending request ID. Retries reuse the original request. The server retains eight results per paired computer and rejects older counters after eviction. At most 32 paired computers may hold durable request state.

This is a shared-secret protocol on a trusted modem network. It does not encrypt packets or implement HMAC. A listener that captures a valid packet can recover its secret. Rednet IDs are spoofable. Do not expose this network to hostile computers. Counters reject old mutations, and secrets reject unauthenticated guesses. They do not protect a compromised paired computer or a stolen secret.

With `ssot.cfg` present, legacy hub mutations, registrations, and telemetry also require a paired sender ID. Legacy packets retain their existing format and have no secret or replay protection. Without this file, legacy behavior stays unchanged. The shared validator bounds legacy requests at 256 KiB and SSOT requests at 8 KiB. SSOT occupancy coordinates only opted-in turtles. An uncoordinated turtle can still physically obstruct them.

## Recover state and control disk use

`ssot.state` stores schema 1 map chunks, occupied poses, reservations, the boot epoch, and replay results. `atomic.lua` writes a temporary generation, reads and parses it, then rotates the current generation to `.bak`. The loader picks the newest valid current, temporary, or backup generation. It refuses to initialize an empty database over corrupt existing generations.

The server acknowledges mutations only after persistence. A storage failure stops further SSOT requests until restart. Free space first, then restart and reconcile turtles. Preserve the current, `.tmp`, and `.bak` files when investigating a failure.

SSOT limits each encoded generation to 900,000 bytes. Three generations can consume 2,700,000 bytes during rotation. The remainder of the four-million-byte disk holds scripts, legacy state, and staging space. The server rejects new chunks at the configured resident limit. It does not silently evict observations. Export or deliberately replace the test map before increasing retention requirements. This stores a bounded set of fleet observations.

Each request checkpoints the bounded resident map and replay cache. PR 1 uses no append journal. The acceptance runs measure 10,004 cells in eight chunks; they do not establish throughput for a full 64-chunk map. Large scans may need smaller retention or a later storage design.

The existing `server.state` loader accepts the previous unversioned table. Its next save adds schema 1, copies shared tables, verifies the temporary file, and retains a previous good generation. Code mirror behavior keeps its existing space reserve.

## Rerun the gates

Run `C:\Tools\lua52\lua52.exe tests\run.lua` for mocks. Run `powershell -NoProfile -ExecutionPolicy Bypass -File tests\sandbox\run.ps1 -Scenario ssot -Seconds 600 -Output <evidence-directory>` for native CraftOS transport and emulated physical turtles. Run the same script with `-Scenario smoke -Seconds 120` for legacy server, hub, and miner behavior.

Run `powershell -NoProfile -ExecutionPolicy Bypass -File tests\ingame\run.ps1 -Scenario ssot` for a disposable NeoForge world. The runner binds Minecraft and RCON to loopback, stages scripts while stopped, creates a corridor, and restarts the complete server at a durable reservation checkpoint. RCON credentials stay in the test directory. The runner never targets the live server.

Add `-Client` to attempt an offline Minecraft client screenshot. If the VM has no primary monitor, the runner retains the GLFW error and generates a diagram from the recorded turtle positions. That diagram is not a client screenshot.

See [the design choices](ssot-pr1-design.md), [the decision trail](ssot-pr1-decisions.tsv), and [the retained evidence](evidence/pr1/README.md).
