# Configure fleet views

Copy `views.cfg.example` to `views.cfg` on the hub. Set `server` to the fleet server's computer ID. Set `secret` to this hub's entry in the server's `ssot.cfg` controller table. Set `enabled=true` to enable the views.

Set `dim` and `center` to the area to show. Coordinates use world blocks, including negative Y. The viewport radius is at most seven blocks. The viewer requests bounded SSOT pages and labels old data as stale when a request fails. Missing cells remain unknown.

Set `gpu` to the DirectGPU peripheral name. Set `monitor` to an adjacent monitor side or its wired peripheral name. The backend uses the monitor's actual pixel resolution. It owns its display and releases that display when it closes. A normal monitor can show the warehouse without a GPU.

Run `hub pro`, `hub map`, or `hub warehouse`. These commands select the starting view only when `views.cfg` enables views. Existing installations without that file keep the original dashboard.

For a new computer, run `install view-pro`, `install view-warehouse`, or `install view-map`. The installer asks for pairing and peripheral names, installs the dependencies, and writes the selected startup command. Existing role IDs stay unchanged.

The view keys are:

| Key | Action |
| --- | --- |
| `p` | Toggle Pro and the original dashboard. |
| `m` | Show the world map. |
| `n` | Show the warehouse map. |
| `t`, `y`, `i` | Select top, side, or isometric projection. |
| `,`, `.` | Rotate the isometric camera. |
| `+`, `-` | Change zoom. |
| `[`, `]` | Change the Pro fleet page. |
| `h`, `r`, `e` | Resume, recall, or emergency stop. |

Select a turtle in the Pro list before clicking a known air cell on the map. Stale maps cannot issue movement. Unknown cells and solid cells cannot be movement targets.

## Enable manual view control on a turtle

Enable and pair SSOT and navigation first. Configure `nav.bounds` through the existing `miner nav bounds` command. Keep mining disabled and set `viewsControl=true` in `miner.cfg`. This selects a dedicated manual worker. It does not run mining and manual movement at the same time.

Each move must stay within the configured navigation bounds and within seven blocks on each axis of the current turtle pose. The server requires observed air at the destination. The turtle imports a bounded map and walks only through known air. It checks the physical route and never digs for a view command.

The hub persists a command counter before sending. The server rejects old counters and sends each turtle its own paired credential. Navigation persists command order across restarts. A restarted turtle reconciles its physical pose and waits for another manual move. A command acknowledgment means receipt, while the turtle's status reports arrival or refusal.

## PR 4 warehouse boundary

`view-source.lua` is the only module that calls PR 4's warehouse API. It calls `wh-sites` without a name to obtain at most 32 site names, then calls it with each name. A site contains `kind`, `pose`, and `side`. Kinds are `source`, `drop`, or `charge`. Poses contain dimension, coordinates, and heading.

The current PR 4 API removes stock and exposes no order snapshot. The map therefore shows configured sites only. A server without PR 4 reports warehouse data as unavailable. Tests stub this exact read interface.

## Reproduce verification

Run `C:\Tools\lua52\lua52.exe tests\run.lua` for the mock checks. Run `tests\sandbox\run.ps1 -Scenario views` with a PR 5 output directory for the emulator scenario.

Run `tests\review-capture.ps1 -Scenario hub-pro` and `-Scenario warehouse-normal` for the CraftOS images. The warehouse image mirrors actual monitor drawing calls to the emulator framebuffer. It does not replace the real Minecraft monitor screenshot.

Run `tests\ingame\run.ps1 -Scenario views -Client` for the isolated Minecraft scenario. The runner takes the shared client lock, waits for other test servers, and uses a fresh test root. Consult `docs/evidence/pr5` and `SUMMARY-pr5.md` for the actual results and remaining gaps.
