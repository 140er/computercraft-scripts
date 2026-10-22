# CraftOS-PC for server-only tests

The default runner passes on Ubuntu 24.04 and Windows with **the exact CC:Tweaked
1.120.2 ROM from the pack jar**, running on **CraftOS-PC 2.8.3's older 1.112.0
native core**. This combination follows the user's explicit compatibility
exception. It is not an exact emulator of Minecraft or the 1.120.2 Java core.
`_HOST` remains `ComputerCraft 1.112.0 (CraftOS-PC v2.8.3)`.

## Run it

From the checkout, with no environment setup on this machine:

```sh
scripts/test-emulator
```

The runner detects the existing extracted AppImage at
`~/work/craftos-so-evaluation/squashfs-root/AppRun` and the pack jar at
`~/work/gateb-modpack/server/mods/cc-tweaked-1.21.1-forge-1.120.2.jar`.
`~/work/mc-serverfiles/mods/` is the next jar candidate. There is no download on
normal execution. Explicit `--craftos` / `CRAFTOS_PC` and `--cc-jar` /
`CRAFTOS_CC_JAR` take precedence. A missing executable, wrong executable version,
wrong jar hash, incorrect ROM version text, or failed assertion exits nonzero.
There is no fallback to another ROM or a Lua-only result.

The slot adapter runs this integration before focused Lua regressions:

```sh
cc-test --part server
cc-test --part miner
cc-test --part so-mine-plan.lua --lua-only
```

The last command deliberately skips the emulator. Run plain `cc-test` once
before a PR to cover scenarios omitted by focused parts.

Standalone runs acquire one existing local cc-test slot lock, either
`~/work/test-suite.lock` or `~/work/test-suite-local-2.lock`. A parent holding a
local slot passes `CC_TEST_EMULATOR_SLOT=local-1` or `local-2`. Remote slot
reservations do not reserve local compute: the adapter leaves this variable
unset and the runner obtains its own free local slot. Busy slots return **75**
promptly. Windows uses the existing exclusive `C:\Tools\cc-test\slot.lock` file.

Each run uses a fresh evidence directory and separate computer disks, capped at
16 MB. The native renderer uses `SDL_VIDEODRIVER=dummy` and
`SDL_AUDIODRIVER=dummy`: native monitors work without a desktop window. The
headless renderer itself cannot create monitors. Native modems use an in-process
network-ID map, not TCP ports. The fixture's network ID `1` is local to its own
process and cannot connect concurrent runs. HTTP is disabled.

The integration has a 25-second process deadline by default, configurable with
`--timeout` (1..300 seconds), plus bounded version/unit checks. It kills only the
emulator process it starts and releases its slot. `--evidence DIR` chooses a new
or empty output directory; otherwise it prints a temporary evidence path.

## Pins and ROM verification

[versions.json](../../tests/craftos/versions.json) records the pack, jar hashes,
add-on versions, ROM tree hash and inspected CraftOS source revision.
The Modrinth pack index pins **Minecraft 1.21.1 / NeoForge 21.1.259**. Embedded
`META-INF/neoforge.mods.toml` pins **CC:Tweaked 1.120.2**. The Gate B server,
Gate B client and serverfiles copies of its jar have identical SHA-256:

```text
e8651fe24b384e925e563c9ad077644744474e2e7c0adb8e6d5b4757598dce9f
```

Every run verifies that whole jar hash, checks its embedded version metadata,
extracts all **220 files** under `data/computercraft/lua/`, and compares every
extracted file's bytes with its jar entry. It checks the ROM's own
`rom/help/whatsnew.md` first line: `New features in CC: Tweaked 1.120.2`.
The sorted `relative-path + NUL + SHA-256 + LF` file list hashes to:

```text
87743e59ef2001af8fa15db152783abfc25b3faada77dda279389ee2db021855
```

The full per-file list is saved in `rom-hashes.json`. The ROM is unmodified;
`--rom` selects it directly. Normal disk `startup.lua` launches the fixture,
because `--script` and `--exec` depend on CraftOS-specific ROM startup code.
ROM provenance and `_HOST` are reported separately. Add-on-injected ROM programs,
such as DirectGPU's terminal API, are outside this extracted CC jar and are not
exercised by the current server-only sources.

The sources inspected read-only were
`~/work/mc-pack/muddedmincecraft-20261019-newmods.mrpack!modrinth.index.json`,
`~/work/gateb-modpack/{server,client}/mods/`, and `~/work/mc-serverfiles/mods/`.
No live Minecraft filesystem, server or RCON was used.

On 2026-10-22 the [published releases](https://github.com/MCJack123/craftos2/releases)
still selected [2.8.3](https://github.com/MCJack123/craftos2/releases/tag/v2.8.3),
which declares CC:Tweaked 1.112.0. The [nightly index](https://www.craftos-pc.cc/nightly)
listed archival executables and an Actions/artifact route, with no declared
1.120.x compatibility. No nightly binary was treated as a match or installed.
[Master at 2844cba](https://github.com/MCJack123/craftos2/blob/2844cba6184e7e2590910d6c2c33697b9b5ff9fd/src/util.hpp)
declares 1.116.1. Other advertised branches declared 1.109.2 (`lua-5.2`),
1.112.0 (`luajit`), 1.98.2 (`unicode-test`), or the experimental 2.0.0
(`lua-5.4`), rather than 1.120.2. The bounded source check found no suitable
1.120.x target. Saved branch declarations are in `tests/craftos/evidence/`.

## What executes

The [integration fixture](../../tests/craftos/integration.lua) creates three
native computers with independent disks and native modems. It executes the
unchanged `so-server.lua`, all 11 server modules, the real `display.lua`, protocol,
pairing, store and crypto libraries. A controller completes real X25519 pairing
with the server, then checks authenticated hello and frame responses, real input
switching from generic to status, unknown-method rejection, and the unsigned
repair hint after a forged MAC. A subsequent authenticated hello verifies that
the valid key survived. Preseeded keys let the separate display start normally;
the controller replaces its seed through the real pairing flow.

The server persists a machine event and reloads a generation saved through the
real store. Native monitors accept the server and display's real cursor, blit,
palette and scale calls. Instrumentation records calls and delegates them to the
native peripheral; no monitor methods are replaced with success stubs. The
controller saves the real status frame. The server's real AR module draws that
machine's scene into the contract fixture. Module skip/failure logs fail the run.
The short AR contract unit test also checks ID replacement, deletion, clear,
published-snapshot isolation and invalid argument types.

## Peripheral coverage

At the frozen product base, server-only discovery uses `peripheral.find` for
`modem`, `monitor`, and `ar_controller`, plus `getName`. Worker discard protection
uses `peripheral.hasType(side, "inventory")`. No server-only product
`peripheral.wrap` call was found; the exact pack ROM wraps discovered objects.

| Surface / exact pack version | Method and return contract | Coverage and limits |
| --- | --- | --- |
| CC:T 1.120.2 modem/rednet | `open`, `close`, `closeAll`, `transmit` return no values; `isOpen`, `isWireless` booleans; channels 0..65535. Rednet receives sender,payload,protocol; lookup returns ID or nil. | Native older modem and exact ROM rednet carry real product pairing and protocol traffic. Native `isWireless()` is false and default distance is zero. No dimensions, range, chunk loading or wired-world topology. |
| CC:T 1.120.2 monitor/terminal | `getSize()` returns width,height; scale getter returns number; scale setter, cursor, `blit(text,fg,bg)` and palette setters return no values. | Native monitors, with checked equal blit-layer lengths, scale 0.5, palette calls and real client/server drawing. Observed fixture size 78x40 after scale change. No Minecraft physical monitor geometry, human touch, font or client pixel parity claim. |
| CC:T 1.120.2 inventory type | `hasType(name,"inventory")`: true for inventory, false for another attached type, nil when absent. | Native chest, modem and detach checks cover all three return shapes. This tests the primitive used by worker discard protection, not worker world actions. |
| CC:AR 0.2.1 | Product-used draw, delete, clear and update signatures below; mutations return no values. | A stateful mock from the exact jar bytecode. Actual AR product drawing reaches it. No goggles, packets, Java numeric coercion/float narrowing or client rendering. |
| CC:T 1.120.2 turtle | Move/dig: success boolean plus optional failure string; inspect: success plus block table or failure string; item detail: table/nil; fuel: number or `"unlimited"`. | No native turtle. This integration reports that absence; existing focused Lua tests retain their shared block-world/turtle fixtures. No mining, collision, fuel, upgrade or inventory physics claim. |
| DirectGPU 1.0.25-neoforge-1.21.1 | No direct server-only discovery at this base. | Exact jar recorded; unused, no fake GPU installed. |
| Advanced Peripherals 0.7.62b | No direct server-only discovery at this base. | Exact jar recorded; player, ME, chunk and other APIs unused and unmocked. |
| Tom's Peripherals 1.3.1; Classic Peripherals 0.6.5 | No direct server-only discovery at this base. | Exact jars recorded; unused and unmocked. |
| Turtlematic 1.4.10; TurtlematicFix 1.0.0; TurtleBattery 0.3.0 | No direct server-only discovery at this base. | Exact jars recorded; turtle upgrade behavior not emulated. |

Exact CC:T contracts come from tag
[v1.21.1-1.120.2](https://github.com/cc-tweaked/CC-Tweaked/tree/v1.21.1-1.120.2),
including [peripheral.lua](https://github.com/cc-tweaked/CC-Tweaked/blob/v1.21.1-1.120.2/projects/core/src/main/resources/data/computercraft/lua/rom/apis/peripheral.lua),
[MonitorPeripheral.java](https://github.com/cc-tweaked/CC-Tweaked/blob/v1.21.1-1.120.2/projects/common/src/main/java/dan200/computercraft/shared/peripheral/monitor/MonitorPeripheral.java),
[ModemPeripheral.java](https://github.com/cc-tweaked/CC-Tweaked/blob/v1.21.1-1.120.2/projects/common/src/main/java/dan200/computercraft/shared/peripheral/modem/ModemPeripheral.java),
and [TurtleAPI.java](https://github.com/cc-tweaked/CC-Tweaked/blob/v1.21.1-1.120.2/projects/common/src/main/java/dan200/computercraft/shared/turtle/apis/TurtleAPI.java).
CraftOS [peripheral documentation](https://www.craftos-pc.cc/docs/periphemu),
[multi-computer documentation](https://www.craftos-pc.cc/docs/multicomp) and
[v2.8.3 modem source](https://github.com/MCJack123/craftos2/blob/v2.8.3/src/peripheral/modem.cpp)
explain the native facilities and in-process network implementation.

The exact local `cc_ar-0.2.1.jar` SHA-256 is
`479a5ebb06ee7be7c0c13279369e373bf628474daf1b7101fb5eb9f95aaa6ec2`.
Its `ARControllerPeripheral` bytecode was inspected with `javap -p -c`; output is
saved as `tests/craftos/evidence/cc-ar-0.2.1-javap.txt`. Product-used methods:

```text
drawLine3D(string id, int color, double x,y,z,u,v,w) -> no values
drawText2D(string id, int color, int x,y, string text, boolean shadow) -> no values
drawText3D(string id, int color, double x,y,z,rx,ry,scale, string text, boolean shadow) -> no values
drawRect2D(string id, int color, int x,y,w,h) -> no values
drawItemIcon3D(string id, double x,y,z,rx,ry,rz, string item) -> no values
delete(string id), clear(), update() -> no values
```

Draw calls replace by ID; delete removes one, clear removes all, update publishes
a copied container with a millisecond version. The mock implements this valid-call
subset and argument types. Unsupported methods remain absent. It does not
implement all of CC:AR or silently satisfy unknown peripheral calls.

## Native-core gaps

Loading the exact ROM does not replace CraftOS's C++ APIs or Lua VM with
CC:Tweaked's Java APIs and Cobalt. The exact pack's ROM changelog identifies
changes after 1.112.0 relevant to this code:

| Area used by server-only | Gap / treatment |
| --- | --- |
| Integer formatting in protocol request IDs and canonical serialization | Windows v2.8.3 rejects `%d` for epoch-millisecond integers. The test-only `native-shims.lua` detects this failure and substitutes `%.0f` solely for the exact patterns `%d` and `%d-%d-%d`, with integral finite inputs below 2^53. Reports identify the shim. Linux uses native formatting. Other formats are untouched; product files and `_HOST` are untouched. |
| Lua numbers, comparisons, pattern matching and bit operations | Cobalt later fixed large-double formatting/parsing, heterogeneous comparisons and pattern behavior; 1.119 adds Cobalt 0.9.9 and `table.create`. Successful crypto/serialization calls cover this fixture, not VM equivalence. No broad VM shim or unsupported version claim. |
| Rednet lookup/receive and parallel event handling | The 1.120.2 ROM supplies the newer lookup timeout and receive timer cleanup; its parallel API also includes later changes. This fixture uses that ROM directly. Native event scheduling, lag and execution limits still differ from Minecraft. |
| Disk capacity and paths | Native configuration enforces a 16 MB capacity. Later Minecraft storage-capacity components, Java path validation, disk accounting and crash persistence are not reproduced merely by this setting. Generation save/reload works in the exercised fixture. |
| Monitors, pockets and character input | Later Minecraft monitor-touch fixes, pocket/lectern behavior, block joins and rendering remain outside this virtual native monitor test. |
| Turtle operations and item details | Later collision, crafting, equipped-item, tags, map-color and NBT changes require real mods/world behavior. No success shim substitutes for them. |
| HTTP | Later HTTP filtering and websocket fixes are not verified; HTTP is disabled here. |

## Evidence, timings and installation

Final result files are under `tests/craftos/evidence/`; each run also retains its
full ROM, three disks, result JSON, version text, stdout/stderr and AR unit log.
Saved Windows text artifacts use LF line endings; the original run directories
retain the native output.
Linux final run: `~/work/craftos-so-evaluation/integration-linux-6/`.
Windows final run: `C:\Users\labadmin\work\so-craftos-evaluation\integration-windows-2\`.

| Run | Result / wall time |
| --- | --- |
| Ubuntu 24.04.5, default detection, native dummy renderer | PASS, 9.310 s, 61 integration assertions across three computers plus AR unit checks |
| Windows, same pack jar and integration, native dummy renderer | PASS, 14.453 s; integer-format shim active |
| Parent `cc-test --part server`, default emulator + focused Lua | PASS, 10.19 s, emulator 9.335 s |
| Parent `cc-test --part miner`, default emulator + focused Lua | PASS, 9.50 s uncontended; a queued run took 24.63 s |

The initial stopped checkpoint recorded failures: headless monitors unsupported,
a mistaken per-computer disk-limit override, missing generation envelope in seed
keys, DNS registration racing startup, and expecting silence instead of the real
repair hint for a forged MAC. These fixture mistakes were corrected. The first
Windows run then exposed the native integer-format gap; the final run passes with
the explicit shim. Archived early failures are evidence, not passing gates.

Linux had 15963 MiB available after restart. Installed only an official AppImage
and extracted files under `~/work/craftos-so-evaluation/`; no apt packages,
services or global configuration changed. Its SHA-256 was verified against the
published v2.8.3 hashes:
`f25536c7a05f67827fe44573ff65627cbe595e13c75815ef86a4e1f3bd33a88c`.
Windows already had `%LOCALAPPDATA%\computercraft-sandbox\craftos-2.8.3\CraftOS-PC_console.exe`.
The final Windows check reported 3416.328125 MiB free before running. Task files,
a copied CC jar and the existing `javap` tool were used under the task folder;
no installer or desktop session was used.

Portable Windows invocation after staging the checkout and exact jar:

```powershell
C:\Tools\python\cpython-3.12.15-windows-x86_64-none\python.exe scripts/test-emulator --evidence C:\Users\labadmin\work\so-craftos-evaluation\new-result
```

The runner detects the existing console executable, `C:\Tools\lua52\lua52.exe`,
and `~/work/so-craftos-evaluation/cc-tweaked-1.21.1-forge-1.120.2.jar` on Windows.
The normal `python` PATH entry there points at a WindowsApps alias; the explicit
Python path above was validated. Use `--cc-jar` for another staged location.

This is useful server/protocol/UI integration evidence, not a complete Gate A
claim: no native turtles or Minecraft/client screenshots were captured, and the
older native core is explicit. **Gate B was not run**, at the orchestrator's
discretion. No live server or desktop was accessed, and no deployment was made.
