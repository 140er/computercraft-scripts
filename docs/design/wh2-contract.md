# Warehouse v2 contract

This is the shared reference for the hardening track, fleet, wizard, layout, and craft. It defines the interfaces those PRs use. Existing `mine-*`, `wh-*`, and navigation operations retain their domain meanings. The authentication upgrade is default-off through `ssot.cfg.requireMac`, as defined under Rednet protocol (#55). New wh2 operations always require v2 authentication.

H4 and miner offline autonomy are APPROVED. Jeffrey accepted it on 2026-10-20 at 17:09 (Europe/Amsterdam). The build plan is [the H4 offline plan](../plans/cc-h4-offline-plan.md), and its P0 PR freezes the implementable shapes in `docs/design/h4-offline-contract.md`. Where those shapes and the notes below differ, the plan wins. The H1+H2 MAC uses ccryptolib's keyed BLAKE3, and the update manifest is signed with Ed25519. This contract takes precedence over the earlier H4 prerequisite for layout and craft in [the hardening plan](hardening.md).

## Ownership and coordinates (#46, #49, #56)

The server's sole SSOT dispatcher owns durable shared state. New modules use its serialized validate, replay, mutate, save, and reply transaction. They do not write separate shared state files or send replies themselves. W1 requires H4a through H4c's storage backend before adding wh2 state.

```lua
wh2 = {
	schema = 1,
	fleet = { v = 1, revision = 0, records = {}, settings = {} },
	layout = { v = 1, revision = 0, locations = {}, rooms = {}, slots = {}, classDefaults = {} },
	wizard = { v = 1, revision = 0, classes = {}, questions = {} },
	craft = { v = 1, revision = 0, jobs = {}, queries = {} },
}
wh2Config = { enabled = false, operators = { ["4"] = true }, recipeHubId = 5 }
pos = {
	v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
	x = 10, y = 65, z = 20, h = 0, conf = "certain", src = "neighbour",
	anchoredAt = 1792500000000,
}
frame = { v = 1, id = "f:17:1792500000000", owner = 17, yAbs = true, toAbs = false }
access = {
	pose = {
		v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
		x = 10, y = 65, z = 20, h = 0, conf = "certain", src = "neighbour",
		anchoredAt = 1792500000000,
	},
	side = "front",
}
```

`s.wh2` is additive to schema 1 `ssot.state`. A missing subtree means that its feature has never written state. Existing state never disappears because its module is absent. Each module validates its own subtree through `valid(value, poseValidator)` and handles its operations through `run(s, senderId, message, context)`. The verified message contains `op` and `body`. Context contains UTC milliseconds in `now`, the server's integer `epoch`, the framed position validator, validated configuration, and negotiated capabilities. A module writes only its own subtree. Only SSOT saves the resulting state and replay record. `wh2Config` is the private `ssot.cfg.wh2` shape. All listed IDs also require controller pairing.

Positions use the plan's section 2.1 `pos v=1` and `frame v=1`. Coordinates and distances are integer blocks in one dimension and frame. `frame` is `"abs"` or `"f:<id>"`. `yAbs=true` means y is world height even when x and z are relative. An absolute position requires `yAbs=true`. `conf` is `certain`, `suspect`, or `lost`. `src` is `gps`, `neighbour`, `radio`, `typed`, `reckoned`, or `inherited`. `anchoredAt` is the last anchor's UTC millisecond timestamp, or 0 if never anchored. Samples of cell bounds use the same position fields. A bound's `h` has no facing effect.

Stored horizontal headings are integers 0 through 3, as in `nav.lua` lines 3 to 7 and `miner.lua` lines 69 to 72. North is 0 and -z, east is 1 and +x, south is 2 and +z, west is 3 and -x. Movement direction indexes 4 and 5 mean up and down. They are never stored in `pos.h` or a warehouse site heading. `access.pose` is the turtle's standing cell. `side` is `front`, `top`, or `bottom`. A front interaction targets the adjacent cell in `pos.h`'s direction. Top and bottom change y by +1 and -1.

A room scan starts at local x=0, z=0 with local heading 0 toward the input chest. It gets its own relative frame. Let `rot` be that initial facing in nav headings and let `toAbs={dx,dy,dz,rot}` contain the scan origin in world blocks. For local x,z, the rotated pair is x,z for rot 0, -z,x for rot 1, -x,-z for rot 2, and z,-x for rot 3. Absolute x,z add dx,dz to that pair. Absolute h is `(h+rot)%4`. Absolute y is the saved y when `yAbs=true`, otherwise `y+dy`. GPS plus a calibrated facing, a typed anchor, or a verified neighbour establishes the transform. N1 `frame-merge` re-keys it once by frame id. Unanchored data stays under its frame prefix and never enters the absolute map. Height-only miner setup uses x=0,z=0 in `f:<id>`, with `yAbs=true`, and does not claim world x or z.

Record, location, and job IDs are stable strings of at most 64 bytes. Item, block, recipe, and tag IDs retain their namespaced provider strings. Existing map and warehouse validators still apply at those boundaries. An unsupported long resource ID fails explicitly rather than being truncated. Arrays are dense. Tables contain no functions, metatables, cycles, or shared table references on the wire. New durable records below have `v=1` unless the plan specifies `v=2`. Readers reject unknown versions. The enclosing SSOT `schema` and wh2 payload version are separate from record versions.

All timestamps, including `lastSeen`, `observedAt`, deadlines, and `now`, are integer UTC milliseconds from `os.epoch("utc")`. Durations ending in `Ms` are milliseconds. Fields ending in `Seconds` are seconds. Byte budgets count encoded bytes and mount allocation overhead where stated. Counts and fuel units are not durations. Recipe time is ticks at 20 ticks per second, and fluid amounts are millibuckets. CC waits convert ticks to seconds by dividing by 20 and milliseconds by 1000. Legacy status numbers are not timestamps. The server stamps receipt time.

`epoch` is an integer authority counter from 0 through 2147483647, persisted in `s.epoch` and sent as a Lua number, including inside canonical MAC bodies. It is never a timestamp or a decimal string. `sessionGeneration` is a separate integer authentication epoch counter with the same encoding. A migration parses a legacy decimal epoch string once at the boundary, validates its range, and stores only the integer. H1+H2 removes `tostring(s.epoch)` from the context passed to new handlers. Tokens and IDs may embed decimal epoch text, but their `epoch` fields stay numeric. Exhausting an epoch counter requires local re-enrolment, never wraparound.

### Field absence and false values (#56)

There is no general false-means-unknown rule. An omitted key is legal only where this contract or the source recipe API makes it optional. Required fields never acquire defaults from omission. The following meanings apply to the named fields.

| Fields | Meaning of false |
| --- | --- |
| Behavior flags, capabilities, `scanComplete`, `localCopy`, `holdsOfflineLease`, `yAbs`, `pinned`, `renew` | Disabled, absent capability, incomplete scan, or the named negative boolean fact. `yAbs=false` means relative height. |
| Non-turtle `turtleId`, `fuel`, `inventory` | Not applicable. A turtle requires its numeric `turtleId` and fuel and inventory tables. A turtle's unmeasured `fuel.level`, `fuel.limit`, or inventory measurement is false and means unknown, never zero. |
| `pose`, `contents`, `frame.toAbs` | Unknown position, unobserved contents, or an unanchored frame. A known empty inventory uses `{}`. |
| `currentJob`, `error`, peer `why`, `category`, `recipeId`, `nbt`, unallocated `orderKey` and `line`, job `owner`, `token`, `epoch`, `overdueAt`, optional site names and lock IDs | No job, no error, no ineligibility reason, no assigned category or recipe, no fingerprint requirement, no reservation or claim, no overdue time, or no site or lock. Claim fields are all present together or all false. An absent fingerprint requirement never proves component equality. |
| `dropoffId`, `chargerId`, `parkingId` | Automatic location selection. It does not disable the behavior. |
| `storagePolicy.forgetOlderThanMs` | No age cutoff. It grants no consent to forget in `ask` or `expand` mode. |
| `leaseId` on issue, a renewed `lease` in a check-in reply | No previous lease, or no renewal granted. |

Only the fields above accept false in place of another type. Other optional API values retain the API's documented omission, not a new false sentinel. Validators reject illegal state combinations before any save.

## Fleet and jobs (#46, #49, #56)

```lua
fleetRecord = {
	v = 1, id = "cc:17", computerId = 17, turtleId = 17,
	kind = "turtle", label = "Miner east", role = "miner",
	boot = "1792500000000:17", ownerGeneration = 4, state = "mining", detail = "Zone 3",
	pose = {
		v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
		x = 10, y = 65, z = 20, h = 0, conf = "certain", src = "neighbour",
		anchoredAt = 1792500000000,
	},
	fuel = { level = 1800, limit = 20000 },
	inventory = { slots = 16, usedSlots = 14, fullness = 0.875 },
	currentJob = { kind = "mine", id = "zone:3", step = "extract" },
	lastSeen = 1792500000000, appliedSettingsRevision = 4,
	capabilities = { navigation = true, inventory = true, crafting = false },
	error = false,
}
```

The authenticated original sender is the computer identity, including through a relay. A turtle's `turtleId` equals its numeric CC computer ID. CC supplies no separate turtle UUID. `kind` is `turtle` or `computer`. Other computers use `turtleId=false`, `fuel=false`, and `inventory=false`. `kind="turtle"` with `turtleId=false` is invalid. Labels can change without changing identity. Roles are `miner`, `store`, `crafter`, `factory`, `hub`, `server`, `panel`, or `other`.

States are `idle`, `mining`, `returning`, `dropping`, `charging`, `sorting`, `crafting`, `blocked`, or `stopped`. Readers derive `offline` after 15000 ms without a report. `lastSeen` is server UTC milliseconds, never a sender timestamp. This display timeout does not release occupancy, site locks, or active work. H5 uses separate expiry and recovery rules below. Fuel uses `"unlimited"` for unlimited level and limit, never infinity.

Fullness is occupied slots divided by total slots. It is not an item count divided by 1024. Complete inventory scans belong to the storage or worker inventory model, not the heartbeat's legacy loot summary. `currentJob=false` means no assigned job. Otherwise its `kind` is `mine`, `warehouse`, or `craft`, and `id` references the owning allocator. `mining`, `sorting`, and `crafting` require a matching current job. Idle requires `currentJob=false`. Returning, dropping, charging, blocked, and stopped may retain unfinished work. Fleet does not duplicate allocator tokens or progress journals.

For coordinated turtles, `pose` comes from framed `s.poses`, including the movement owner's `h` and confidence. A report cannot move SSOT occupancy. Unanchored legacy observations use a relative frame and `conf="suspect"` or `"lost"`. They cannot authorize a route as absolute observations. A changed boot or uncertain position requires N1 journal and fingerprint reconciliation.

## Settings and live changes (#46, #50, #56)

Fleet owns one registry of behavior settings. Each registry entry supplies a type, bounds, and default. The board and turtles use that registry. New behavior toggles and thresholds enter the registry before callers use them.

```lua
settings = {
	revision = 4,
	defaults = {
		enabled = false, navigation = false, mining = false,
		warehouse = false, sorting = false, smelting = false, crafting = false,
		autoCharge = false, autoDropoff = false, traffic = false,
		mesh = true, returnHome = true,
		fuelLow = 200, fuelTarget = 2000, fuelMargin = 32,
		minFreeSlots = 2, fullnessHigh = 0.875, chargeTimeoutMs = 60000,
		dropoffId = false, chargerId = false, parkingId = false,
		keep = {}, miningTargets = {},
		miningMode = "thorough", branchLength = 64, reach = 96,
		tripSeconds = 900, sessionSeconds = 1800, minSessionSeconds = 180,
		thoroughGap = 4, fastGap = 2, layerStep = 3, layers = 4,
		veinLimit = 64, junkEvery = 10, retrySeconds = 20,
		minTripFuel = 2000, warehouseFuelMargin = 16,
		roomMaxSize = 48, roomMaxHeight = 24, roomMaxCells = 6000,
		roomMaxFurnaces = 16, roomIntervalMs = 5000, roomFuelLow = 1000,
		wiredIntervalMs = 3000, smeltQueue = 32,
		charcoal = true, keepLogs = 32, useStorageFuel = true,
		extraSmelt = {}, noSmelt = {},
		roomFuels = { "minecraft:charcoal", "minecraft:coal", "minecraft:coal_block", "minecraft:dried_kelp_block" },
		wiredFuels = { "minecraft:charcoal", "minecraft:coal", "minecraft:coal_block", "minecraft:dried_kelp_block", "minecraft:lava_bucket" },
		leave = { ["minecraft:bucket"] = 9999, ["minecraft:lava_bucket"] = 9999, ["minecraft:water_bucket"] = 9999 },
		navMaxCells = 2048, navMaxSearch = 2048, navBatch = 32,
		trafficWaits = 80, trafficWaitMs = 250, routeRetries = 5,
		trafficRouteRetries = 80, trailLength = 64, rpcTimeoutMs = 5000,
	},
	overrides = { ["17"] = { autoCharge = true, fuelTarget = 4000 } },
}
settingsPatch = {
	scope = "turtle", computerId = 17, baseRevision = 4,
	set = { autoDropoff = false }, unset = { "fuelTarget" },
}
```

Effective settings are registry defaults, then global `defaults`, then the string-keyed computer override. An override can contain every registry key. `false` is an explicit value; `unset` restores inheritance. Map and array values replace a whole value rather than merging their contents. Unknown keys and invalid combinations fail the entire patch. The server uses `baseRevision` to reject stale edits and increments the revision once per accepted patch.

Fuel counts and retained counts are nonnegative integers. `fuelTarget` is 1 through 100000 and exceeds `fuelLow`. `minFreeSlots` is 0 through 16. `fullnessHigh` is greater than 0 and at most 1. Other durations and counts are positive integers. `miningMode` is `thorough` or `fast`. Target and keep maps contain namespaced IDs mapped to true. `extraSmelt`, `noSmelt`, and fuel preferences are arrays of item IDs. `leave` maps item IDs to retained counts. Explicit class answers override imported smelting preferences. Disabling a behavior still prevents its route from executing. Existing module limits still apply, including mining geometry and navigation budgets.

Auto-charge starts at `fuelLow` or when the known service and return route plus the role's fuel margin requires more fuel. Auto drop-off starts when free slots fall below `minFreeSlots` or fullness reaches `fullnessHigh`. A lower `fuelLow` cannot authorize movement without enough fuel for the known return route. With a service toggle off, the turtle stops or returns safely when necessary. It does not silently run that service. `mining=false` interrupts extraction before its next physical action and retains unfinished work.

The server persists settings in `s.wh2.fleet.settings` before acknowledging them. It sends a change hint to online clients. The turtle's existing receiver queues a settings fetch through one outbound SSOT worker. A known newer revision pauses new autonomous actions until the fetch completes. Heartbeats also check the revision at least every 3000 ms. A turtle saves its effective settings and revision in `wh2-settings.cache` through `atomic.lua`, applies them before its next unstarted action, then reports `appliedSettingsRevision`. An in-progress native turtle call completes first. Offline turtles fetch before resuming work.

Pairing keys, server identity, dimension, calibrated pose, and physical journals remain local setup. Both the server's `ssot.cfg.wh2.enabled` and the turtle's local `wh2.enabled` default off. A remote behavior setting cannot bypass those prerequisites or clear ESTOP. After bootstrap opt-in, reads and authorized management requests remain available while behavior flags are off. Existing configurations seed settings only through an explicit opt-in import. The adapter maps `mineMinutes` to `tripSeconds` by multiplying by 60, so 15 becomes 900. `sessionLen` is already seconds and maps to `sessionSeconds` unchanged. Legacy room and wired intervals are seconds and multiply by 1000 for `roomIntervalMs` and `wiredIntervalMs`, preserving defaults 5000 and 3000. `chargeTimeoutMs` stays milliseconds. `roomFuelLow` is fuel units. `cook` maps to `smelting`. Normal startup does not overwrite shared settings with old `miner.cfg`, `room.cfg`, or `sorter.cfg` values.

## Locations and rooms (#46, #49, #56)

```lua
location = {
	v = 1, id = "mine-drop", kind = "dropoff", roomId = "room:main", enabled = true,
	block = { v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
		x = 11, y = 65, z = 20, h = 0, conf = "certain", src = "neighbour", anchoredAt = 1792500000000 },
	access = {
		pose = { v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
			x = 10, y = 65, z = 20, h = 1, conf = "certain", src = "neighbour", anchoredAt = 1792500000000 },
		side = "front",
	},
	siteNames = { source = false, drop = "mine-drop", charge = false },
	lockId = "inventory:mine-drop", revision = 3,
}
room = {
	v = 1, id = "room:main", revision = 3, scanComplete = false,
	bounds = {
		min = { v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
			x = 0, y = 64, z = 0, h = 0, conf = "certain", src = "typed", anchoredAt = 1792500000000 },
		max = { v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
			x = 15, y = 70, z = 31, h = 0, conf = "certain", src = "typed", anchoredAt = 1792500000000 },
	},
	observedChunks = { ["abs|minecraft:overworld|0|4|0"] = 8 },
	blocked = { ["abs|minecraft:overworld|5|65|5"] = "minecraft:stone" },
	accessPaths = {
		["mine-drop"] = {
			{ v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
				x = 9, y = 65, z = 20, h = 1, conf = "certain", src = "reckoned", anchoredAt = 1792500000000 },
			{ v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
				x = 10, y = 65, z = 20, h = 1, conf = "certain", src = "reckoned", anchoredAt = 1792500000000 },
		},
	},
	reserved = {
		["abs|minecraft:overworld|10|65|20"] = { kind = "access", locationId = "mine-drop" },
	},
}
```

Location kinds are `dropoff`, `charge`, `parking`, `warehouse_input`, `warehouse_output`, `storage`, `furnace`, `blast`, `smoker`, and `room`. A room location requires `roomId` and omits `block` and `access`. Parking requires `access` and omits `block`. Every other kind requires `block` and `access`, including a charger whose physical device occupies `block`. A drop-off without its block is invalid. Every position in a room, path, reservation, and location uses the same frame and dimension. A front, top, or bottom access must target its declared block exactly. The sample faces east with h=1 to reach x=11 from x=10. A parking spot has no inventory or site lock. Missing optional devices are absent locations, never guessed coordinates.

`dropoffId`, `chargerId`, and `parkingId` select shared locations. When false, resolution selects an enabled, reachable location of that kind in the turtle's dimension, ordered by route cost then ID. No candidate means a visible blocked reason. Miners therefore need no local drop-off coordinate.

Layout adapts locations to existing `wh-site` records through `siteNames`. Drop-off, warehouse output, and machine input access use `kind="drop"`. Pickup storage and warehouse input use `kind="source"`. Chargers use `kind="charge"` and a lock ID for their bay. A bidirectional inventory has separate source and drop names sharing one `lockId`. Layout assigns the same lock identity to every view of the same dimensioned block. Parking and room locations use false for unused site names and lock IDs.

Room bounds are inclusive. SSOT chunk observations remain the source for observed air, solids, and unknown cells. `observedChunks` pins their revisions; a missing cell is unknown, not air. `blocked` is the sparse room obstacle index, including pillars and irregular walls. Layout does not infer an entire column from one floor observation. `scanComplete` requires an observation of every cell in the scanned volume.

Access paths contain adjacent, observed air cells and end at the location's standing cell. Layout validates paths against current observations before allocation or placement. `reserved` prevents building on access paths, entrances, parking cells, charger cells, and machine access cells. Reservation kinds are `access`, `entrance`, `parking`, `charge`, or `machine`. These are layout reservations. Transient movement reservations remain exclusively in `s.moves`, with their existing tokens and restart behavior.

## Storage and item classes (#51, #56)

One storage slot describes one physical inventory and its placement intent. `contents` uses the inventory's native numbered slots.

```lua
storageSlot = {
	v = 1, id = "slot:main:12", roomId = "room:main", locationId = "chest-12",
	kind = "chest", category = "ingots", revision = 6,
	size = 27, observedAt = 1792500000000,
	contents = {
		[1] = { item = "minecraft:iron_ingot", count = 32, maxCount = 64, nbt = false },
	},
}
machineSlot = {
	v = 1, id = "slot:main:blast1", roomId = "room:main", locationId = "blast-1",
	kind = "blast", category = false, revision = 6,
	size = 3, roles = { [1] = "input", [2] = "fuel", [3] = "output" },
	contents = { [2] = { item = "minecraft:coal", count = 8, maxCount = 64, nbt = false } },
}
itemClass = {
	v = 1, item = "minecraft:raw_iron", class = "ores", route = "blast",
	storeCategory = "ingots", recipeId = "minecraft:iron_ingot_from_blasting_raw_iron",
	source = "layout", revision = 2, updatedBy = 17,
}
unknownQuestion = {
	v = 1, id = "item:example:raw_tin", item = "example:raw_tin", state = "open",
	firstSeen = 1792500000000, sampleLocationId = "warehouse-in",
}
```

Storage kinds are `chest`, `furnace`, `blast`, or `smoker`. Barrels and other general inventories use `chest` after capability checks. Empty native slots are absent from `contents`. Unknown observations use `contents=false`; they never count as available stock. Actual `size`, stack limits, item counts, and NBT fingerprints come from inventory APIs. Component-sensitive stacks cannot merge merely because their item IDs match.

All three cooking machines use native slots 1 for input, 2 for fuel, and 3 for output. Slot numbers in this contract are Lua and CC inventory API slots, which are 1-based. Minecraft NBT and RCON commands number the same slots from 0 (input 0, fuel 1, output 2), so test fixtures and RCON scripts subtract one. Fuel slots accept validated fuels. Outputs are extraction-only. Machine slots are never spare chest capacity. A removed machine invalidates its observation and blocks its job. Layout intent does not promise an inventory exists.

Categories are `any`, `ores`, `ingots`, `gems`, `fuel`, and `misc`. The effective item-class table maps item IDs to rows. `route` is `store`, `furnace`, `blast`, `smoker`, `fuel`, or `unknown`. `storeCategory` is the destination category for stored items or collected results. `recipeId=false` means no selected processing recipe. `fuel` routes to fuel storage. Workers consume it only under the fuel policy and stock reservations.

Layout owns exact-ID defaults in `s.wh2.layout.classDefaults`, with `source="layout"`. Wizard owns answers in `s.wh2.wizard.classes`, with `source="wizard"`. Readers overlay answers on defaults. Defaults work before wizard is installed and cannot overwrite answers. The `classes` query returns this effective view with revision `"<layoutRevision>:<wizardRevision>"`, using 0 for an absent subtree. Repeated unknown reports coalesce into one question per item ID. An answer commits its class row and question resolution together. Unknown or unsupported routes retain the stack in the input or designated quarantine storage and report the question. They never discard it or infer a recipe from a name suffix.

Question states are exactly `open`, `answering`, or `resolved`. Only a validated answer can move a question to resolved. A draft never enters the effective class table.

`wh2-client.lookupClass(itemId)` returns the effective row and class revision through `wh2-get`, or a row with `route="unknown"` when no definition exists. `reportUnknown(itemId, locationId)` queues `wh2-unknown`. A class change hint or a changed revision invalidates cached rows. Before wizard is installed, defaults remain readable and unknown reporting returns `unavailable`; the worker retains the item for a later report. Layout callers use these methods and do not import the wizard module.

Every transfer takes the existing physical site lock. Existing warehouse stock reservations remain the authority for pickup quantities. Craft reserves ingredients through those orders; it does not subtract stock in a second ledger. Layout refuses to move or remove locations used by an active lock or job.

## Recipe graph and production (#52, #53, #56)

The hub owns recipe lookup through `wh2-recipes.lua` and a wired `recipe_index`. Recipe nodes retain the Recipe Index 0.1.0 schema. Item nodes are keyed by item ID; recipe nodes are keyed by recipe ID. Inputs are quantity-bearing edges into recipes and outputs are edges back to items.

```lua
itemNode = { item = "minecraft:glass", recipes = { "minecraft:glass" } }
recipeNode = {
	id = "minecraft:glass", type = "minecraft:smelting", machine = "Furnace",
	inputs = { { count = 1, item = "minecraft:sand" } },
	outputs = { { item = "minecraft:glass", count = 1, chance = 1.0 } },
	time = 200,
}
tagIngredient = { count = 8, tag = "minecraft:planks" }
alternativeIngredient = { count = 1, items = { "minecraft:coal", "minecraft:charcoal" } }
craftJob = {
	v = 1, id = "craft:17:9", key = "board:17:request9", requestedBy = 17, revision = 2,
	output = { item = "minecraft:red_stained_glass_pane", count = 32 },
	outputLocationId = "warehouse-out", state = "blocked", owner = false,
	token = false, epoch = false, currentStep = 1,
	steps = {
		{ id = 1, recipeId = "minecraft:glass", type = "minecraft:smelting",
			batches = 6, machineLocationId = "furnace-1", needs = {}, state = "pending",
			ingredients = {
				{ item = "minecraft:sand", nbt = false, perBatch = 1,
					orderKey = "craft:17:9:step1", line = 1 },
			} },
	},
	missing = { { item = "minecraft:red_dye", count = 1 } },
	produced = 0, delivered = 0, error = false,
}
craftCreate = {
	action = "create", key = "board:17:request9",
	output = { item = "minecraft:red_stained_glass_pane", count = 32 },
	outputLocationId = "warehouse-out",
}
craftProgress = {
	action = "progress", jobId = "craft:17:9", token = "claim:17:9", epoch = 3,
	stepId = 1, state = "done",
	observed = { locationId = "furnace-1", item = "minecraft:glass", count = 6, stockRevision = 8 },
}
```

An ingredient has `count` and exactly one of `item`, `tag`, or `items`. Tags have no leading `#`. `more=true` means an API alternatives list is incomplete. `resolveTag` returns complete item-tag membership. A capped alternatives list cannot prove an unlisted substitute is invalid or available. The planner records each concrete choice and checks actual stock before reservation.

Recipe kinds use `type`, not the human `machine` text. `minecraft:crafting` plus a numeric `pattern` is shaped; the same type without it is shapeless. Pattern keys are turtle slots 1, 2, 3, 5, 6, 7, 9, 10, and 11. Other turtle slots must be empty for crafting. Cooking kinds are `minecraft:smelting`, `minecraft:blasting`, and `minecraft:smoking`. Other types retain their source IDs and require a matching installed machine adapter. An unsupported adapter produces a blocked step with its type, never a successful craft.

Optional `fluids`, `heat`, `time`, `steps`, `loops`, and `transitional` retain the API shapes and omissions. Fluid amounts are millibuckets and time is ticks. Sequenced assembly keeps ordered steps and repeats them `loops` times. Step addition counts multiply by loops; the transitional item is not an addition. An API step has `type`, `machine`, and `inputs`, with optional `outputs` and `fluids`. It has no invented `heat`, `time`, `pattern`, or `id` fields. Unknown heat, tools, energy costs, component requirements, or container returns need an adapter or a blocked reason.

Production steps use `ceil(required / guaranteedOutputCount)` batches, share surplus within the plan, and consume each dependency once. Outputs with chance below 1 cannot satisfy a guaranteed count. Cycles terminate with an explicit unresolved requirement. A step's `needs` references earlier step IDs. `ingredients` records chosen item fingerprints and per-batch counts. `orderKey` and `line` reference existing warehouse reservation lines, or are false before allocation. A component-sensitive ingredient needs verified matching stock; existing item-only totals cannot prove that match. States are `pending`, `running`, `done`, `blocked`, or `uncertain`. Job states are `planning`, `planned`, `running`, `blocked`, `done`, `cancelled`, or `uncertain`. A missing ingredient blocks execution and reports its exact count.

Validators enforce job and step states together. A `planning` job has no executable or running step and no worker claim. A `planned` job has a complete graph with no running step. A `running` step requires a `running` job and a current claim. Blocked or uncertain work starts no new physical action. A `done` job has no missing or unresolved requirements, all required steps done, and the requested count observed in the output inventory. It cannot retain a running step. Claim `owner`, `token`, and `epoch` are all false before allocation, or all valid together. Completed and cancelled jobs fence their claim and preserve observed quantities.

Create returns a `planning` job. Only the configured hub planner publishes its plan with `wh2-craft` action `plan`, carrying `jobId`, `baseRevision`, `generation`, `offset`, `steps`, `missing`, and `final`. Step offsets start at 0 and count accepted steps. The server stages one plan per job and commits only a complete validated graph. Plans have at most 128 steps and use the same byte limits as other uploads. A changed job revision or provider generation rejects the staged plan. Physical workers claim only a complete plan. Fuel and machine operating inputs are explicit requirements when an adapter knows them.

Creating a craft uses a caller key that remains stable across retries. Jobs retain ownership across restarts. Workers journal physical actions through the existing navigation and warehouse boundaries. An uncertain transfer, smelt, or craft requires inventory reconciliation before retry. `produced` and `delivered` count observed output, not requested output or acknowledged commands. Completion requires the requested count in the output inventory. Batch surplus stays recorded stock.

### Hub limits and recipe service (#54, #56)

The supplied dump's `recipes_min.lua` contains 3878 recipes and is 1131311 bytes. `recipes.json` contains 3880 shaped and shapeless crafting recipes. `stats.txt` reports 3878 and records 2441 excluded non-crafting recipes. The dump cannot supply smelting or the complete runtime graph. The live Recipe Index is authoritative for the installed recipes and tags. An offline import is an explicit fallback pinned to its file hash. It converts dump `s`, `l`, `o`, `n`, and `#tag` fields to this schema and preserves result components as unresolved requirements when necessary.

The hub queries `getRecipesFor`, `getUsesOf`, `getRecipe`, `list`, and `resolveTag` on demand. It never installs the complete dump, all namespace shards, or a serialized full graph. Its recipe cache occupies at most 131072 encoded bytes in RAM and is disposable. Persisted hub files, temporary generations, backups, scripts, and any optional offline shard together stay below 1000000 bytes with 8192 bytes free for writes. Insufficient space rejects the import or save; raising the disk limit does not satisfy this requirement.

Remote graph requests use a bounded queue in `s.wh2.craft.queries`. The server returns a ticket immediately. A hub worker claims the query, calls the peripheral outside the rednet receiver, and publishes one result fragment. Clients read that fragment by ticket. There are at most four active tickets, one unconsumed fragment per ticket, and a 30000 ms idle expiry. The query owner releases or advances its ticket after reading. Expiry discards recipe lookup state only, never production work.

```lua
recipeQuery = {
	action = "query", key = "board:17:lookup9",
	method = "getRecipesFor", id = "minecraft:glass", page = 1, pageSize = 20,
}
recipeFragment = {
	action = "publish", ticket = "recipe:17:9", token = "recipe-claim:9", epoch = 3,
	generation = "hub:5:boot7:catalog1",
	offset = 0, totalBytes = 12000, nextOffset = 4096,
	encoding = "lua", data = "serialized result fragment",
}
recipeAdvance = {
	action = "advance", ticket = "recipe:17:9",
	generation = "hub:5:boot7:catalog1", nextOffset = 4096,
}
```

API pages keep their 1-based page number and maximum page size 100. Network fragments are at most 4096 bytes and pin a hub catalog generation. The receiver reassembles at most 65536 bytes for one result using `textutils.unserialize`, never `load`. Larger API pages retry with smaller page sizes. A single oversized recipe or tag returns `too_large`. Missing providers return `recipe_unavailable`. A hub restart or source change invalidates outstanding generations and cached plans. Recipe Index exposes no reload revision. The provider refreshes selected recipes and tag choices before execution and advances its generation when their definitions change. The generation identifies the provider's observed definitions, not an atomic upstream snapshot.

Graph pages are disposable. Only selected production steps and bounded query fragments enter shared state. The current 900000-byte SSOT generation ceiling and replay-cache cost remain implementation limits, not disk-capacity measurements. A capacity refusal leaves the previous state intact. This hub budget does not claim that the coordinator's current save generations fit on a 1 MB disk.

## Rednet protocol (#47, #53, #55, #56)

All requests use rednet protocol `fleetserver`. H1+H2 owns envelope `v=2`, transport `wire={major=2,minor=0}`, and the authenticated version and capability handshake below. `wh2=1` is the payload schema, independent of transport and release versions. A bare `v=1` is not a handshake. Clients use one `ssot-client` instance and feed `dispatch` from the program's existing sole application receiver. Blocking calls run outside that receiver.

### Authentication rollout (#55)

`ssot.cfg.requireMac` defaults to false when absent. This flag is separate from `ssot.cfg.wh2.enabled` and local `wh2.enabled`, which also default off. With `requireMac=false`, existing v1 operations keep their legacy behavior. Installing new code alone does not remove their write authority. New wh2, lease, enrolment, and storage operations require authenticated v2 even during migration. A v2 client never falls back to v1 after a failed MAC or negotiation.

This sample shows the auth field in `ssot.cfg`. Existing controller and wh2 configuration fields remain alongside it.

```lua
ssotAuthConfig = { requireMac = false }
```

The operator first installs compatible code, provisions fresh keys and the pinned server ID and public key, and verifies v2 clients. It then sets `requireMac=true` locally on the authority. The server saves a durable `macRequired=true` upgrade marker before accepting that setting. Thereafter it rejects every v1 request, including domain reads and writes, and refuses unsigned updates. Setting the flag false or deleting it cannot clear that marker. Boot keeps v2 required when the config conflicts with the marker. Code rollback must preserve and understand it. Moving or replacing an authority requires a local migration that carries the marker and rotates credentials. Network requests cannot downgrade it. This is the one-way upgrade path.

```lua
request = {
	v = 2, wire = { major = 2, minor = 0 }, direction = "request", type = "ssot", expect = "ssot_reply",
	server = 0, sender = 17, keyId = "pair:17:2", session = "session:17:9",
	sessionGeneration = 9,
	rid = "1792500000000:17:42", boot = "1792500000000:17", counter = 42,
	op = "wh2-get", body = { wh2 = 1, topic = "locations", cursor = 0 },
	mac = "<64 lowercase hex digits>",
}
reply = {
	v = 2, wire = { major = 2, minor = 0 }, direction = "reply", type = "ssot_reply",
	server = 0, sender = 0, target = 17, keyId = "pair:17:2", session = "session:17:9",
	sessionGeneration = 9,
	rid = "1792500000000:17:42", boot = "1792500000000:17", counter = 42,
	op = "wh2-get", body = { wh2 = 1, ok = true, revision = 3, records = {}, cursor = 0 },
	mac = "<64 lowercase hex digits>",
}
changeHint = {
	v = 2, wire = { major = 2, minor = 0 }, direction = "hint", type = "wh2_changed",
	server = 0, sender = 0, target = 17, keyId = "pair:17:2", session = "session:17:9",
	sessionGeneration = 9,
	rid = "hint:17:6", counter = 6, op = "wh2-changed",
	body = { wh2 = 1, topic = "settings", revision = 5 },
	mac = "<64 lowercase hex digits>",
}
```

### MAC and key contract (#47)

H1+H2 vendors ccryptolib at a reviewed pin with its MIT license. The accepted plan inspected revision `14489aa`. `ssot-auth.lua` owns canonical encoding, ccryptolib's keyed BLAKE3 MAC, and domain-separated key derivation. It returns the full 32-byte MAC as 64 lowercase hex digits. HMAC-SHA256, `sha2.lua`, and the previous HMAC vectors are rejected. No hand-written cryptographic primitive or wrapper replaces ccryptolib. These modules are planned dependencies, not implementations already present in this branch.

The MAC input is the plan's `rid|counter|op|canonical body`. Precisely, it is `rid .. "|" .. decimal(counter) .. "|" .. op .. "|" .. canonical(B)`. `B` is the complete envelope with only `rid`, `counter`, `op`, and `mac` removed. It includes the domain `body`, direction, v, wire version, message type, expected reply, server and client IDs, key ID, session, authentication epoch, and boot wherever present. This definition preserves authentication of the complete context. The decimal counter has no leading zeros or plus sign. IDs and op names cannot contain `|`. Directions are `request`, `reply`, `hint`, `pair`, or `session` and must match the message type and derived key. Relays forward these bytes unchanged. MACs authenticate bodies without encrypting them.

Canonical encoding uses type tags and byte lengths. Strings are `s<decimal byte length>:<raw bytes>`, and booleans are `t` or `f`. Numbers are `n<16 lowercase hex digits>;`, the IEEE-754 binary64 bits in big-endian order. Negative zero encodes as positive zero. Tables are `m<count>{<key><value>...}` with integer keys first in numeric order and string keys next in byte order. Lengths and counts have no leading zero or plus sign. Empty tables encode as `m0{}`. Array positions are integer keys. Nil values, duplicate keys, other key types, non-finite numbers, and integers outside the exact binary64 range fail at this boundary. Domain validators still require integers for IDs, revisions, and counters. `textutils.serialize` is not the MAC encoding.

P0 checks keyed BLAKE3, SHA-256, X25519, and Ed25519 in Cobalt against the 7-second timeout and records any required yields outside SSOT transactions. H1+H2 keeps known-answer and canonical-encoding fixtures for the pinned library and records actual timings for small, page-sized, and maximum envelopes. The rejected primitive's analytic costs and vectors are not evidence for BLAKE3 performance or correctness.

Initial local pairing provisions a distinct high-entropy 32-byte bootstrap key on the server and controller through a trusted installer or direct console. Neither pairing messages nor discovery transmit it. A short PIN, `math.random`, a computer ID, and a timestamp do not supply key entropy. Public one-use challenges bind the transcript below. Challenges are unique within a durable pairing generation. Migration rotates the old plaintext keys before v2 use. I1 enrolment replaces manual entry with the plan's transcript-authenticated ephemeral X25519 exchange. Its copy code authenticates public keys, nonces, and IDs. The pairing key derives from the shared secret and transcript. Only if P0 rejects X25519 does I1 use the plan's 16-character code fallback. Randomness initialization must pass P0 before secret operations.

```lua
pairTranscript = {
	label = "cc-pair/2", server = 0, client = 17, pairingGeneration = 2,
	serverChallenge = "s:1", clientChallenge = "c:1",
}
keyDerivation = {
	label = "cc-ssot-key/2", direction = "request", server = 0, client = 17,
	pairingGeneration = 2, session = "session:17:9", sessionGeneration = 9,
}
```

For local bootstrap pairing, the proof is keyed BLAKE3 under `Kbootstrap` over the pairing transcript with domain `cc-ssot/2/pair`. ccryptolib's domain-separated KDF derives the 32-byte `Kpair` from the bootstrap secret and full transcript under `cc-ssot-pair/2`. I1 derives that key from the X25519 secret and its full enrolment transcript instead. Traffic keys derive from `Kpair` and the exact `keyDerivation` table under `cc-ssot-traffic/2`. The traffic direction is `request`, `reply`, or `hint`. The session-control derivation uses direction `session` and omits both `session` and `sessionGeneration`. It remains available when a session file is lost. KDF inputs and local keys are raw bytes. Wire MACs are lowercase hex. P0 freezes the library calls and their fixtures, including labels and field sets.

Ed25519 manifest signatures use the server's separate signing key and pinned public key. Pairing keys and the server-only storage key never sign a manifest. The old fixed MAC vector is removed rather than relabelled as a BLAKE3 result.

The replay window stores the last eight completed requests per client session, including their exact signed bytes and durable results. An exact retry returns that saved result without running the operation again. Reusing an ID or counter with different bytes fails. An evicted counter at or below the high-water mark fails. A new counter is an integer from 1 through 2147483647 and at most 64 above the high-water mark. The small gap allows a crash after reserving a local counter. Invalid MACs, huge counters, and rejected gaps never advance replay state. State, accepted counter, and result commit before reply.

Before the final 64 counter values, the client drains its worker and performs an authenticated `ssot-session` exchange. It rolls the client's authentication epoch, `sessionGeneration`, to the next integer and issues a new session ID before resetting the counter to zero. It does not overwrite the server's authority epoch or existing lease facts. The exchange also works when the counter is exhausted or its local file is lost. Pairing and session control use a fixed v2 control envelope before negotiation, with separate message types and MAC directions and `counter=0`. They bypass the domain-request counter check. Session control uses the session key, a fresh one-use server challenge, and a client attempt ID saved before sending. The server atomically saves the new session, authentication epoch, and counter zero. Its MAC-authenticated acknowledgement contains `{attemptId, serverChallenge, session, sessionGeneration}`. Retries return it only while that session remains current. A superseded attempt returns `superseded`. The client rejects older epochs and saves the acknowledgement before counter one. A crash resumes the same exchange. Hello must succeed before new domain work. Old sessions and hint sequences remain fenced. Numeric wrap, timestamp reset, unauthenticated reset, and a maximum counter cannot lock out a paired turtle.

The paired sender owns its own telemetry and settings acknowledgement. Configured operator computer IDs may edit settings, layouts, classes, and craft requests. A configured recipe hub ID may claim and publish recipe queries. These roles come from private `ssot.cfg.wh2` configuration, not a self-reported fleet role. Legacy hub packets cannot write v2 state. Keys never appear in v2 requests, replies, records, errors, hints, or relay wrappers. Legacy behavior while `requireMac=false` remains the migration exception, not a permitted v2 encoding.

The client validates the pinned server, target, session, authentication epoch, negotiated version, MAC, reply type, op, and pending request ID and counter. Direct messages also match the rednet sender. Relayed messages prove the original identity with the end-to-end MAC. The relay forwards the complete original envelope and MAC unchanged. Its bounded outer wrapper contains only routing IDs, deduplication ID, and hop limit. It holds no controller keys.

### Durable pending requests (#53)

Before any transmission, one atomic local outbox record saves the reserved counter and the complete immutable envelope, including its boot, session, authentication epoch, rid, body, and MAC. It saves the serialized envelope. Canonical input is reproduced deterministically from those saved fields. The record has a 20480-byte encoded ceiling per generation, covering an 8192-byte envelope, string escaping, and metadata. Both save copies count against the local ledger. A failed save sends nothing. One outbound worker permits one pending request. Saving only `ssot.counter`, as the current client does, does not meet this contract.

Boot restores that pending envelope before minting another counter, boot-dependent rid, or session. It retries the same authenticated bytes even if the current process has a different boot. It does not regenerate them from a new status snapshot. After a verified reply, it durably records the result and the caller's recovery cursor before clearing the pending record. A crash resumes that step. A fenced session or an evicted replay requires authenticated status and domain reconciliation using the stable operation key. It never authorizes blind repetition of a physical action. Only after the pending result is resolved may the client roll its session or send new domain work. Rednet may serialize a table again, but every authenticated field and canonical byte stays unchanged.

Operation names stay within 16 bytes. Requests and replies stay within 8192 compact serialized bytes, including envelope and MAC, and existing `ssot.bounded` limits. Canonical signed bytes also have an 8192-byte cap before hashing. Oversized records use smaller pages. Ordinary pages target 4096 bytes with at most 64 records. Larger records use explicit subresource pages, never truncated facts.

`wh2-get` starts with cursor 0. Later pages pin `revision`; cursor 0 in a reply means complete. Records sort by stable ID. A changed revision returns `stale_revision` and restarts the read. Mutation errors use `ok=false`, `code`, and a readable `error`. Codes are `invalid`, `forbidden`, `disabled`, `unavailable`, `stale_revision`, `busy`, `capacity`, `blocked`, `too_large`, `recipe_unavailable`, `incompatible`, `overdue`, or `reconcile_required`. Invalid authentication retains silent rejection.

The server signs one change hint per paired recipient with that recipient's hint key. A session-local increasing hint counter rejects old hints. The hint only schedules an authenticated read. It never applies settings or causes movement. Clients validate its identity, session, MAC, and sequence and coalesce hints. Lost hints recover through heartbeat polling.

The operation payloads are fixed by this table. Request fields live in `body`. Successful reply fields live in `body`, alongside `ok=true` and the payload schema. Common envelope fields are omitted.

| Operation | Request fields | Successful reply and owner |
| --- | --- | --- |
| `wh2-get` | `topic`, `cursor`, optional pinned `revision`, optional record `id`, optional subresource `field` and `pathId` | `revision`, `records`, `cursor`. Topics `fleet`, `settings`, `locations`, `rooms`, `slots`, `classes`, `questions`, and `crafts` route to their subtree owner. Classes use the composed view above. |
| `wh2-report` | `record`, `appliedSettingsRevision` | Server-stamped own record, `settingsRevision`. Fleet. |
| `wh2-settings` | The settings patch above | `revision`, effective settings for the target. Fleet. |
| `wh2-layout` | `baseRevision`, `kind`, `id`, and one of `value`, `remove=true`, or the upload fields below | `revision`, accepted record. Kinds `location`, `room`, `slot`, `classDefault`. Layout. Large scans use existing `scan`; paths and contents use bounded subresource pages. |
| `wh2-class` | `baseRevision`, `item`, `value` | `revision`, class row, resolved question. Wizard. |
| `wh2-unknown` | `item`, `sampleLocationId` | Existing or new question. A paired worker reports only an observed item. Wizard. |
| `wh2-recipe` | `action` plus query, ticket, or fragment fields | Actions `query`, `claim`, `publish`, `read`, `advance`, `release`. Replies contain a ticket and pending state, a query, or one fragment. Craft owns queue; hub supplies data. |
| `wh2-craft` | `action`, `key` for create, `jobId` otherwise, action fields | Actions `create`, `plan`, `claim`, `progress`, `reconcile`, `cancel`. Replies contain the job or a bounded job summary. Craft. |

Recipe ticket keys are scoped to the requesting computer. Only that owner can read, advance, or release a ticket. A `claim` reply gives the hub `ticket`, `query`, an opaque `token`, server `epoch`, and `untilAt`. Publish requires that claim's hub boot, token, current epoch, ticket, generation, and expected offset. Expired or replaced claims cannot publish. `read` supplies the ticket and optional pinned generation. `advance` acknowledges the current fragment's exact `nextOffset` and generation, then makes the next offset available to the hub. `release` supplies the ticket. Craft claim replies also include an opaque owner token and server epoch; progress and reconciliation require that token, epoch, and owner. Client assertions cannot mark a physical output as delivered without the worker's inventory observation.

Layout subresource messages have these operation fields. Each example's `op` goes in the envelope and its other fields go in `body`.

```lua
layoutUpload = {
	op = "wh2-layout", kind = "room", id = "room:main", field = "accessPaths",
	pathId = "mine-drop", baseRevision = 3, offset = 0, final = true,
	records = {
		{ v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
			x = 9, y = 65, z = 20, h = 1, conf = "certain", src = "reckoned", anchoredAt = 1792500000000 },
		{ v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
			x = 10, y = 65, z = 20, h = 1, conf = "certain", src = "reckoned", anchoredAt = 1792500000000 },
	},
}
layoutRead = {
	op = "wh2-get", topic = "rooms", id = "room:main", field = "accessPaths",
	pathId = "mine-drop", revision = 4, cursor = 0,
}
```

Room fields are `accessPaths`, `blocked`, and `reserved`. The slot field is `contents`. A path upload identifies one `pathId` and streams poses. Blocked and reserved records have named `key` and `value` fields. Contents records have named `slot` and `stack` fields. Offsets are zero-based counts of accepted records. Replies contain `nextOffset` and the unchanged base revision until `final` commits a new revision. Read cursors follow the ordinary `wh2-get` rule. The server stages one edit of at most 65536 encoded bytes per operator, rejects gaps or changed revisions, and publishes only a validated final record. Staging expires after 30000 ms idle without replacing the current record. These fragments count toward the shared state limit. No partially uploaded room becomes executable.

## Versions and updates (#47, #56)

The authenticated `ssot-hello` exchange negotiates a transport version before domain operations. Its body has the following shape.

```lua
hello = {
	challenge = "client:17:hello:8", release = "<immutable release id>", stateSchema = 1,
	wire = { minMajor = 2, maxMajor = 2, maxMinor = 0 },
	capabilities = { keyedBlake3 = 1, ed25519Manifest = 1, atomicBundle = 1, traffic = 1, wh2 = 1 },
	required = { "keyedBlake3", "ed25519Manifest", "atomicBundle", "traffic" },
}
helloReply = {
	challenge = "client:17:hello:8", serverChallenge = "server:0:hello:19",
	release = "<immutable release id>", stateSchema = 1, wire = { major = 2, minor = 0 },
	capabilities = { keyedBlake3 = 1, ed25519Manifest = 1, atomicBundle = 1, traffic = 1, wh2 = 1 },
	epoch = 3, compatible = true,
}
manifest = {
	v = 1, release = "<immutable release id>", server = 0, keyId = "ed25519:0:1",
	wire = { major = 2, minor = 0 }, stateSchema = 1,
	files = {
		{ path = "startup.lua", release = "<immutable release id>", bytes = 600, sha256 = "<64 hex digits>" },
		{ path = "ssot-client.lua", release = "<immutable release id>", bytes = 5200, sha256 = "<64 hex digits>" },
	},
	signature = "<128 lowercase hex digits>",
}
```

The hello tables are MAC-authenticated bodies. The manifest also has one server Ed25519 signature. Its example abbreviates the file list. The real manifest names every file and transitive dependency for the selected role, including optional modules that the release installs. Every entry names the same release. Paths are normalized relative paths from an allowlist. Duplicate paths, traversal, wrong sizes, missing dependencies, and mixed releases fail. Capability values are interface revisions, not self-granted roles. A missing required capability or major-version mismatch returns `incompatible` and pauses work. Unknown optional capabilities are ignored. The challenge, negotiated result, release, state schema, and capabilities are authenticated. A client never downgrades to plaintext after a failed negotiation.

The server signs `"cc-update-manifest/1|" .. canonical(manifestWithoutSignature)` once with its Ed25519 private key. The client pins the server computer ID, signing key ID, and 32-byte public key in local setup. It selects that pinned key by `keyId` and verifies the 64-byte signature encoded as 128 lowercase hex digits. A key supplied by discovery, a relay, or the manifest cannot replace the pin. The immutable signed bytes cover the release, file paths, byte counts, SHA-256 hashes, wire version, state schema, server ID, and signing key ID. The signature authenticates the paired server's release, without asserting upstream authorship.

Transport replies use `type="update_manifest"`, `op="update-manifest"`, and `body={challenge, manifest}` with those named keys. Their MAC direction is `reply`. The keyed BLAKE3 reply MAC binds the current request and challenge, while the same static Ed25519 signature verifies for every client. HTTP and relay downloads must match the signed hashes. Neither `rednet.lookup` nor `rednet.host` replaces the locally pinned server. First pairing, a server-ID change, or a signing-key change requires local setup.

The updater stages the complete generation under a new directory, checks the Ed25519 signature, transport MAC where applicable, byte counts, SHA-256 hashes, and Lua syntax, then records readiness. A recoverable activation journal selects the complete generation at boot. Recovery chooses either the old generation or the complete new generation, never per-file renames into a running tree. The launcher and module search path load only the selected generation. A successful boot and handshake promote it to last-good. An interrupted install or failed boot restores the previous last-good code generation. Code rollback preserves current durable shared state, counters, session fences, the MAC-required upgrade marker, movement journals, and cargo facts. It never restores an older authority checkpoint. Automatic rollback requires that last-good code can read the current state schema. An incompatible migration is refused before activation. The updater checks free space for staging and rollback before starting. Insufficient space leaves the current generation active.

H1+H2 also publishes the server's mirror as one verified generation. Its asynchronous refresh may fetch files individually, but no client can observe that generation until every manifest file passes. A serving node uses only a published manifest and matching chunks. This works with the current mirror location. It does not depend on the pending H4 cache relocation. Fleet adds its files to this manifest mechanism and does not restore mutable per-file updates.

## Server loop and module integration

H3 separates request reception from execution. The receiver bounds the envelope and queue, then admits a FIFO entry `{sender, envelope, receivedAt}`. One worker coroutine owns SSOT mutations and runs one complete transaction at a time. An exact duplicate still uses the replay result. Overflow never mutates state or acknowledges success. The client retries the same request, so queue pressure cannot skip an accepted operation.

No `handle`, validator, module `run`, or save path yields. They contain no `sleep`, synchronous `http.get`, or `os.pullEvent`, including in helpers and callbacks. Bounded CPU and filesystem work finishes within that transaction. HTTP and other yielding work run in separate coroutines and post bounded completion entries to the queue. Only the state worker applies those entries. A failed transaction cannot acknowledge success. The worker keeps serving available reads and status. H3 does not change the storage format or build the pending H4 save backend.

The event pump continues receiving modem, HTTP, and timer events while another coroutine waits. Maintenance uses an absolute next-due time. An independent ticker always arms its next timer before dispatching work. Every pump wake checks overdue maintenance and restores a missing or late timer. A periodic watchdog provides a wake if the primary timer event is lost. It coalesces missed ticks instead of replaying a burst. Losing one timer event cannot stop expiry, queue service, or refresh.

Fleet registers fixed optional wh2 handlers with this worker. `wh2-get` reads and all mutations pass through the same queue and authenticated dispatcher. Modules return a result and any change-hint intent. The worker commits before it signs replies or hints. Modules never create another receiver, call HTTP inside `run`, or write state independently. Recipe-provider and layout-scan work happen outside the transaction and submit bounded, validated results. The outbound client worker and sole receiver keep the same split.

## Expiry and live recovery

H5 adds server-owned deadlines to started moves, confirmed poses, and warehouse claims. Each record retains its owner, owner generation, boot, token, epoch, `lastSeen`, `untilAt`, `overdueAt=false`, and recovery status where applicable. The server uses its clock and persists overdue transitions. A verified heartbeat may renew a pose. Only the matching owner, token, and generation can renew work. Default deadlines are 30000 ms for a started move, 60000 ms for a pose, and 120000 ms for a warehouse claim. H5 exposes bounded private configuration for these durations. The 15000 ms fleet display timeout is separate.

Ordinary movement and warehouse mutation bodies carry `ownerGeneration` alongside their existing token and epoch fields. The server rejects a fenced generation before those mutations. A late heartbeat cannot renew an overdue or forgotten owner. A fresh session alone cannot clear a recovery requirement. Authenticated recovery `sync` may reconcile that owner's fenced move journal against its measured pose and heading. Its body carries the old owner generation, move token and epoch, and measured pose and heading. It cannot allocate new work. After durable reconciliation, its reply supplies the new `ownerGeneration`. An admin-forgotten turtle also requires local re-anchoring before that transition.

At a deadline, maintenance marks the record overdue, fences its token, and releases its scheduling ownership. Expiry does not prove a turtle, block, or cargo vanished. A started move's endpoints and an expired pose become unknown occupancy until observation or reconciliation clears them. They no longer reserve work forever, but route planning cannot treat them as observed air. A warehouse job preserves picked, delivered, and outstanding quantities. Only a reconciled unpicked remainder can return to the queue. Cargo or bay uncertainty blocks the affected transfer and cannot create replacement stock.

The operator-only `forget turtle` command maps to authenticated `turtle-forget` with body `{computerId, baseGeneration, reason}`. It atomically marks the owner forgotten, fences all tokens and sessions for that generation, clears its scheduling claims, and marks affected cells, bay contents, and unfinished jobs for reconciliation. It retains an audit tombstone and inventory facts. A stale generation cannot forget a newly recovered turtle. The command never marks physical cells free or deletes cargo evidence. A returning turtle requires a fresh authenticated session, a new owner generation, and local pose and journal reconciliation before work.

After an RPC timeout following a real move, the client freezes further physical actions but keeps its receiver and recovery worker alive. It retains the durable move journal, fetches current epoch and move status, and retries an exact pending request when possible. Otherwise it reconciles its measured source or destination through `sync`. GPS failure preserves the journal and retries re-anchoring without reboot. A non-endpoint pose or uncertain heading stays blocked for local calibration. The client clears its stopped state and journal only after an authenticated durable reconciliation reply. ESTOP remains an independent latch.

Craft adopts the same claim fencing and preserves observed progress on expiry. Miner offline leases are outside this approved H5 scope.

## H4 disk and cold storage, approved (#49, #56)

Jeffrey approved H4 on 2026-10-20 at 17:09 Europe/Amsterdam. The shapes below adopt sections 2.2 through 2.4 and 2.7 of [the accepted plan](../plans/cc-h4-offline-plan.md). P0 writes `docs/design/h4-offline-contract.md` as the single source for the codec and these versioned records. That file does not exist at `8de2440`. Implementation waits for P0 to freeze it. The integer epoch and field-specific false rules above resolve the review's type gaps for that freeze.

The foundation follows a, c, e, then b in the spec. The state server stores no fleet code cache. It reads `fs.getCapacity` and `fs.getFreeSpace` for the actual state mount at runtime. The reported live capacity is 4,000,000 bytes today, with 16,000,000 staged. Neither number is a constant in code. Unknown or unlimited API results are explicit capacity states. The server budgets metadata, rollback, and pending writes before admission.

Dirty chunks save in batches. Requests validate changed records without a full-state copy or full-state validation. Each chunk and the root generation use two alternating save slots, A and B, with generation, length, and checksum. The writer verifies inactive chunk slots before publishing the root that references them. It preserves the active generation throughout. Recovery selects the newest complete valid root and matching chunks. A partial inactive write leaves the old root usable. Failed writes report capacity or I/O failure and remain retryable. There is no third full temporary copy and no permanent silent-failure latch.

H4b1 stores versioned sections with a palette and RLE cells in per-section files. Confidence is observed or unknown. H4b2 adds the plan's region baseline, sorted exceptions, segments, and boxes behind a default-off flag. P0 freezes their byte encoding. The pre-plan `whc-rle/1` header is rejected. Section keys start with `abs|` or `f:<id>|`. Predicted cells may affect estimates but never authorize walking or count as observed. Baselines stay versioned and frozen once referenced.

The decoded plan index is `x + 16*z + 256*y`, from 0 through 4095 within a section. A missing observation is unknown. Index 0 denotes a cell, not unknown. Palette entries name air explicitly. In the schema 1 source, `ssot.lua` uses the same cell number plus 1, and a stored value of 0 means observed air. Migration subtracts 1 from the cell index, converts a stored 0 to `minecraft:air`, and keeps a missing source cell unknown. The decoder bounds lengths and palettes before allocation. Corrupt or unknown versions remain unreadable and unknown. Migration retains the source until the new generation verifies.

The plan records are below. Times are UTC milliseconds, quotas and sizes are bytes, and fuel is in fuel units. The zero times mean no sample yet. Peer copies contain encoded bytes without authority to change shared state.

```lua
section = {
	v = 2, key = "abs|minecraft:overworld|3|4|-2", rev = 812, hash = "<sha256 hex>",
	palette = { "=", "minecraft:air", "minecraft:diamond_ore" },
	cells = "<P0 encoding; H4b2 sorted 2-byte cell index plus 1-byte palette index>",
	observedAt = 1792500000000, lastRead = 1792500000000, tier = "hot",
}
placement = {
	v = 1, key = "abs|minecraft:overworld|3|4|-2", rev = 812, hash = "<sha256 hex>", bytes = 1843,
	holders = { [21] = { ackAt = 1792500000000, verifiedAt = 1792500000000, role = "store" } },
	localCopy = true, state = "replicating",
}
peer = {
	v = 1, id = 21, role = "store", enrolledAt = 1792500000000, enrolledBy = 4,
	quota = 420000, used = 120000, freeReported = 610000, reportedAt = 1792500000000,
	window = { sent = 240, ok = 236 }, lastReplyAt = 1792500000000,
	boot = "1792500000000:21", bootChanges = 1,
	power = { fuel = 18000, limit = 20000 }, holdsOfflineLease = false,
	score = 0.98, eligible = true, why = false,
}
storagePolicy = { v = 1, mode = "ask", warnAt = 0.8, forgetOlderThanMs = false, controlReserve = 65536 }
ledger = {
	v = 1, localTotal = 1000000, localUsed = 800000, peerTotal = 0, peerUsed = 0,
	growthPerHour = 300000, state = "warn",
}
forgetPreview = {
	v = 1, id = "p:812:3", createdAt = 1792500000000, untilAt = 1792500030000,
	olderThanMs = 604800000, rev = 812,
	items = { { key = "abs|minecraft:overworld|3|4|-2", rev = 640, hash = "<sha256 hex>", bytes = 1200 } },
	bytes = 1200,
}
```

All figures above are illustrative. Placement states are `hot`, `replicating`, `cold`, `degraded`, or `unknown`. Ledger states are `ok`, `warn`, or `paused`. The `=` palette entry means an observed cell equal to a referenced baseline and is unavailable before H4b2. Holder keys and peer IDs are numeric computer IDs. Reachability uses ping and real storage-reply success EWMAs with alpha 0.1. Missed deadlines count as failures. The score is `0.4*pingSuccess + 0.4*replySuccess + 0.1*uptimeRatio + 0.1*powerHeadroom`. Components are normalized from 0 to 1 over a ten-minute window. A peer also needs a fresh successful reply, no known out-of-range or unloaded interval in the qualifying window, and enough power for the repair horizon. Unknown power or reachability fails eligibility. A changed boot removes the holder from the verified count until it re-verifies the revision and hash. Stationarity adds no score and proves no reachability.

Eligible store and warehouse robots rank first, stationary computers second, and miners last. The minimum score is 0.95. A cold section requires verified durable copies at the same revision and hash on at least two distinct eligible non-miner peers before `localCopy` may become false. Miners hold extra replicas only, never count toward the two, and never hold replicas while holding an offline lease. Their quotas leave room for code, two navigation saves, the runtime journal budget, and update staging. A server-only storage key authenticates section identity, revision, codec, size, and hash with keyed BLAKE3. Per-peer keyed BLAKE3 envelopes protect transfer and acknowledgement. Peers never receive that storage key. Exporting it to a floppy is mandatory before enabling peer storage, not before running the server.

Reads fetch lazily by hash into an LRU cache and verify both hash and content MAC. The LRU only removes local copies whose required peer copies still exist. A reachability drop, failed reply, or low power triggers early re-replication from a verified copy. Rebalancing prefers eligible free space after reserves. Until repairs complete, local copies remain pinned. If all copies are unreachable, the directory retains the chunk record and its cells are unknown, never free. Loss of reachability never authorizes deletion.

The per-server policy appears on the panel and in dev mode. `ask` is the default. `expand` uses peers and never forgets. `forget-old` permits oldest eligible data in the displayed scope, with `forgetOlderThanMs` as its optional age cutoff. `hybrid` uses peers first and permits forgetting only when eligible peer capacity is exhausted. Selecting a forgetting policy is explicit player consent to its displayed scope and age rule. Every deletion batch records an exact preview. Active jobs, move journals, identities, replay records, and live reservations cannot enter that scope. Forgotten map cells become unknown and advance their revision. Before H4d, expansion says it needs storage turtles. Pausing map growth preserves `controlReserve` for control writes.

Capacity distinguishes raw physical bytes, bytes used by replicas, unique data, and usable space after replication and reserves. Unreachable peers remain visible with their last measured use and capacity, but contribute no usable free space. At 80% used by default, both the panel and AR glasses show `Storage almost full: add N turtles as storage, or allow forgetting data older than X?`. The estimate uses measured compressed growth over `projectionMs`, at least two replicas, reserves, current reachable free space, and each checked candidate's usable capacity. `N=ceil(max(0, projectedReplicaGrowth + reserveBytes - reachableFreeBytes) / candidateUsableBytes)`. The estimate states its horizon and refreshes when capacity changes. It never assumes a turtle disk size.

One click enrolls a selected turtle after the server checks pairing, reachability history, power, and free space. A failed check reports its reason and stores nothing. Until the player answers, new map data stays compressed in a bounded pending buffer and miners retain unacknowledged events in their local journals. The server pauses map writes before the reserve is exhausted. It sends no durable acknowledgement for RAM-only data. Miners continue only within current authorization and journal capacity, then return or wait safely. Backpressure prevents loss and crashes. It does not promise unbounded storage or enable offline autonomy.

The panel storage view pages the ledger and each peer's capacity, use, reachability history, and section and journal contents. It shows which server and peer copies a forgetting policy affects. A preview enumerates exact keys, revisions, hashes, age cutoff, replica locations, count, and bytes. A commit pins the immutable preview and policy revision. An expired preview or changed policy returns `stale_revision`. Under the accepted plan, a section changed since the preview is skipped by its revision and hash check. Other unchanged previewed sections may be removed. The result lists removed and skipped entries. No commit deletes an unlisted version.

These proposed messages use authenticated envelopes and bounded pages. They remain unregistered until approval.

| Operation | Intended body and result |
| --- | --- |
| `storage-ping` | Challenge and sample deadline. Reply supplies boot, power, capacity, and contents revision. Reply success also includes measured `cold-get` and `cold-has` results. |
| `cold-put` | Key, revision, hash, content MAC, codec, total bytes, offset, and bounded bytes. Durable acknowledgement follows full verification and names hash and revision. |
| `cold-get` | Hash, offset, and limit. Reply supplies matching metadata and bytes or `unavailable`. |
| `cold-has` | Bounded hashes. Reply supplies presence, verified size, and contents revision. |
| `cold-drop` | Exact hash and directory revision. Only the server authorizes removal after replacement replication or approved forgetting. |
| `storage-capacity` | Cursor and pinned revision. Reply supplies `ledger`, physical and replica byte totals, usable capacity after reserves, and per-peer contents pages. |
| `storage-policy` | `baseRevision` and `storagePolicy`. Operator-only update. Reply supplies the accepted revision and scope. |
| `storage-prompt` | Prompt ID and capacity revision. Reply supplies the displayed choices, growth horizon, candidate checks, and preview ID. AR actions use the same operator authorization. |
| `storage-enroll` | Prompt ID, computer ID, candidate-check ID, and expected capacity revision. Reply supplies enrollment or a failed eligibility check. Retries are idempotent. |
| `storage-preview` | Policy revision, scope, optional age threshold, cursor, and pinned directory revision. Reply supplies immutable preview ID, digest, exact records, and expiry. |
| `storage-forget` | Preview ID, digest, policy revision, and directory revision. Operator consent or an explicitly saved forgetting policy authorizes only that recorded scope. Reply supplies exact removals, skipped changed entries, and new revisions. |

## Miner offline autonomy, approved (#46, #49, #56)

Jeffrey approved miner offline autonomy on 2026-10-20 at 17:09 Europe/Amsterdam. These records adopt sections 2.5 and 2.6 of [the accepted plan](../plans/cc-h4-offline-plan.md). P0 freezes them in `docs/design/h4-offline-contract.md`. N1 supplies positions and confidence. B1 supplies leases and journals after W1. B2 adds local problem handling. [Miner offline autonomy](miner-autonomy.md) follows those rules. W1 settings and H5 recovery do not depend on B1 or B2.

This is a full feature for normal-modem miners. Ender modems remain optional. Out of range, a miner works only while a player or chunk loader keeps its area loaded. An unloaded turtle freezes and reboots on reload. N1 restores `certain` only after journal and fingerprint reconciliation, or an anchor. An unresolved move may use the measured fuel delta only when fuel and move cost are known and no charging occurred. Otherwise it needs a distinctive fingerprint. Suspect or lost position forbids digging. GPS is optional. A saved lease alone cannot prove position.

```lua
lease = {
	v = 2, id = "7:mine:1234", turtle = 17, boot = "1792500000000:17", epoch = 7,
	issuedAt = 1792500000000, untilAt = 1792500900000, issuedRev = 812, frame = "abs",
	area = {
		min = { v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
			x = 0, y = 60, z = 0, h = 0, conf = "certain", src = "typed", anchoredAt = 1792500000000 },
		max = { v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
			x = 15, y = 63, z = 31, h = 0, conf = "certain", src = "typed", anchoredAt = 1792500000000 },
	},
	corridor = {
		{ v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
			x = 10, y = 61, z = 20, h = 0, conf = "certain", src = "reckoned", anchoredAt = 1792500000000 },
		{ v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
			x = 10, y = 61, z = 19, h = 0, conf = "certain", src = "reckoned", anchoredAt = 1792500000000 },
	},
	dropoff = { pose = { v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
		x = 10, y = 61, z = 19, h = 1, conf = "certain", src = "neighbour", anchoredAt = 1792500000000 }, side = "front" },
	charger = { pose = { v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
		x = 10, y = 61, z = 19, h = 3, conf = "certain", src = "neighbour", anchoredAt = 1792500000000 }, side = "front" },
	home = { v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
		x = 10, y = 61, z = 19, h = 0, conf = "certain", src = "typed", anchoredAt = 1792500000000 },
	settings = { revision = 4, values = { checkInEveryMs = 60000, returnMarginMs = 120000 } },
	fuelReserve = 120, mac = "<keyed BLAKE3 hex with the turtle pairing key>",
}
entry = {
	v = 1, seq = 42, lease = "7:mine:1234", at = 1792500001000, frame = "abs",
	kind = "move", phase = "intent", fuelBefore = 1800,
	from = { v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
		x = 10, y = 61, z = 20, h = 0, conf = "certain", src = "reckoned", anchoredAt = 1792500000000 },
	to = { v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
		x = 10, y = 61, z = 19, h = 0, conf = "certain", src = "reckoned", anchoredAt = 1792500000000 },
}
journalHead = { v = 1, lease = "7:mine:1234", committed = 41, acked = 30, bytes = 18000, budget = 90000 }
```

The lease MAC uses ccryptolib keyed BLAKE3 with the turtle's pairing key over the canonical lease without `mac`, under a lease-specific domain label. It binds the complete `v=2` record, including numeric epoch, boot, frame, inline area, corridor, access poses, home, settings, and fuel reserve. Bounded transport fragments reassemble and verify the whole record before activation. The corridor has at most 256 adjacent observed-air positions in the same frame and dimension. The server reserves the area and corridor exclusively until `untilAt`. Renewal is server-only. Offline moves use dead reckoning within that authorization and need no per-step RPC. A lease holder cannot also hold peer replicas.

Five invariants survive every dev-mode choice. Digging requires certain position. The reserved return corridor stays clear. Block observations follow the lease-authority and revision merge rule below. An expired lease means no move or dig until renewal or an explicit return-only grant. The miner stops new work and heads home at 80% of its journal budget, with space reserved for the return. If it cannot journal another action, it waits. Disabling a local recovery behavior never bypasses an invariant.

The append-only local journal uses the plan's entry and head. The `budget=90000` sample is illustrative bytes, not a fixed allowance. B1 computes the budget from actual free space after code, navigation generations, pending envelopes, update staging, and return and reconciliation reserves. Entries also obey the registry's event cap. Every entry carries `v`, `seq`, `lease`, UTC `at`, `frame`, `kind`, and `phase`. Its other fields follow its kind. P0 freezes their validators.

| Entry kind | Required action or observation fields |
| --- | --- |
| `move`, `turn` | `from`, `to`, and `fuelBefore` when measured. Positions include h and frame. Intent saves known source and destination fingerprints for N1 recovery. Done records the resolved outcome. |
| `dig`, `observe` | `cell` and observed `name`. `dig` records intent before the native call and done after observation. `observe` is a done entry. Air is `minecraft:air`. An unknown observation omits `name` and explicitly carries `conf="unknown"`. |
| `item` | `cell`, `name`, and observed `count`, with source and destination inventory observations for transfers. A fingerprint requirement is explicit where needed. |
| `problem` | Bounded problem code, attempts, and decision `wait`, `retry`, `reroute`, `return`, or `skip`. |
| `boot`, `anchor` | Boot identity or anchored position and source, with the previous unresolved sequence when present. |

Entries record observations and actual item changes, not a second stock ledger. Each entry fits within 2048 canonical bytes. Intent and done append under the same action sequence. Only a resolved done entry is replayed for that sequence. An unresolved intent remains local and blocks further physical work until N1 resolves it. Observation-only entries start as done. Sequences increase and never reset within a lease. The head's `committed` is the contiguous done prefix, and `acked` never exceeds it. Bytes include unresolved intents and return entries. Reboot preserves both the journal and head and requires confidence recovery before new actions.

`miner-replay` sends `{leaseId, firstSeq, entries}` in bounded batches. Replay keys are `(turtle, lease, seq)`. The server persists contiguous accepted sequences and results before returning `{ackedThrough, conflicts, revision}`. Identical duplicates do nothing. Changed duplicates or gaps fail. The miner removes an acknowledged prefix only after saving the acknowledgement locally. Expired leases may replay observations made before `untilAt`, but cannot authorize later excavation. This deduplication outlives ordinary RPC's eight-result cache.

The server is the final merge authority. Ownership, reservations, leases, job progress, delivered counts, and settings always use its current records. Inside its own unexpired lease the holder's valid observation wins. Outside it, an observation applies only when the cell is unknown or the section revision is not above `issuedRev`. Otherwise the cell becomes unknown. Ties order by UTC milliseconds, then numeric turtle ID, then sequence. The server rejects impossible times and observations and returns the authoritative result. The miner replaces conflicting cached state with that result. Item counts require inventory observations and cannot come from a dig command alone.

The default check-in period is 60000 ms and lease duration is 900000 ms. The effective settings set the next check-in relative to `issuedAt`. The miner returns toward range early enough for the route estimate plus `returnMarginMs`, and always before `untilAt`. Failed check-ins do not extend permission. Reboot and clock uncertainty cannot extend a lease. At a missed check-in the server marks the miner overdue. At expiry it fences the lease and frees scheduling claims. Possible physical occupancy stays unknown until observation clears it.

The request and reply bodies below use the approved v2 keyed BLAKE3 envelope. B1 registers them after its named dependencies and gates. No further feature approval is pending.

| Operation | Intended request body | Intended successful reply body |
| --- | --- | --- |
| `miner-lease` | `action="issue"` or `"renew"`, `jobId`, `leaseId=false` for issue, `ownerGeneration`, framed `pose`, `settingsRevision`, `ackedThrough` | Complete signed v2 `lease`, fragmented if needed, or `wait` with reason. Renewal names the existing lease and supplies a newly signed deadline and settings snapshot. |
| `miner-checkin` | `leaseId`, `ownerGeneration`, framed `pose`, `lastSeq`, `ackedThrough`, `settingsRevision`, `renew=true` or false | UTC `serverNow`, `status`, `ackedThrough`, authoritative `revision`, accepted settings revision, and renewed `lease` or false. Missing journal entries require replay before renewal. |
| `miner-replay` | `leaseId`, `firstSeq`, `entries`, optional pinned server revision | `ackedThrough`, authoritative `revision`, and bounded `conflicts` containing sequence, code, and authoritative result. Larger conflict sets use a cursor. |

W1 adds the offline and problem-handling settings before B1 or B2 reads them. Defaults include `offlineAutonomy=false`, `checkInEveryMs=60000`, `leaseMs=900000`, `returnMarginMs=120000`, and `journalMaxEvents=1024`. The journal byte ceiling is an optional limit on the smaller runtime-derived budget, never a fixed disk allowance. Behavior settings cover inventory compaction and filtered trash, low-power return margin, unbreakable-block detours, fluid containment or avoidance, falling-block retries, blocked-path retry and reroute, re-anchor attempts, and stuck-cell backoff and skip. Each behavior has an enable flag and bounded thresholds. Defaults keep trash and fluid placement off. All settings appear in the registry and on the panel's dev-mode controls with the immutable invariants visible.

## File boundaries and merge order

The base owns only this contract. No LuaLS file duplicates these tables. The intended order is PR 5, PR 6, H3, H1+H2, H4, H5, fleet, wizard, layout, craft. H4 is ON HOLD. The active stack skips it, so H5 stacks directly on H1+H2. Layout and craft require the approved predecessors, including H3, but have no H4 prerequisite. H4 can re-enter only after Jeffrey approves its plan and the orchestrator sets its place against the then-current stack.

Ownership is sequential. An earlier owner controls shared files until its change lands. Later owners extend that result after rebase. Each PR owns its named tests and evidence directory. H3 establishes queue-related runner hooks. Fleet later adds optional wh2 scenario dispatch to those hooks.

| Merge | PR | Owned existing files | Owned new files and data |
| --- | --- | --- | --- |
| 1 | PR 5 | `hub.lua`, `fleetview.lua`, `server.lua`, `install.lua`, `update.lua` | View backends, snapshot adapter, Pro controls, view-role tests and evidence. See [the PR 5 scope](../gemini-review.md). |
| 2 | PR 6 | `fleetview.lua`, `server.lua`, `hub.lua`, `install.lua`, `update.lua` | AR entrypoint and chat adapter, final role registration, AR tests and evidence. See [the PR 6 scope](../gemini-review.md). |
| 3 | H3 | `server.lua`, `ssot.lua`, `atomic.lua`, `tests/run.lua`, `tests/sandbox/run.ps1`, `tests/review-capture.ps1` | Request queue, one worker, non-yielding transaction paths, timer recovery, `tests/h3-*`, `docs/evidence/h3/`. |
| 4 | H1+H2 | `ssot.lua`, `ssot-client.lua`, `server.lua`, `relay.lua`, `miner.lua`, `store.lua`, `hub.lua`, `panel.lua`, `fleetview.lua`, `install.lua`, `update.lua`, `atomic.lua` for the activation journal | `sha2.lua`, `ssot-auth.lua`, manifest and generation launcher, pairing migration, handshake, `tests/h1-h2-*`, `docs/evidence/h1-h2/`. Owns all transport and update changes. |
| 5, held | H4 | Planned only. `server.lua`, `ssot.lua`, `atomic.lua`, `panel.lua`, `hub.lua`, `fleetview.lua`, `install.lua`, `update.lua` | Proposed `ssot-storage.lua`, `chunk-store.lua`, `storage-peer.lua`, policy and capacity records, `tests/h4-*`, `docs/evidence/h4/`. No edits or implementation before approval. |
| 6 | H5 | `ssot.lua`, `ssot-client.lua`, `server.lua`, `nav.lua`, `miner.lua`, `mining.lua`, `warehouse-tasks.lua`, `warehouse.lua`, `store.lua`, `hub.lua`, `panel.lua` for admin recovery | Expiry and fencing fields, live journal recovery, admin forget command, `tests/h5-*`, `docs/evidence/h5/`. Parent is H1+H2 while H4 is held. |
| 7 | Fleet | `server.lua`, `ssot.lua`, `ssot-client.lua`, `miner.lua`, `mining.lua`, `nav.lua`, `fleetview.lua`, `install.lua`, `update.lua`, shared test runner dispatch | `wh2-fleet.lua`, `wh2-client.lua`, `tests/wh2-fleet-*`, `docs/evidence/wh2-fleet/`. Owns fleet, approved settings, wh2 handler registration, optional loading, and manifest entries. |
| 8 | Wizard | `hub.lua`, `panel.lua` | `wh2-wizard.lua`, `tests/wh2-wizard-*`, `docs/evidence/wh2-wizard/`. Owns class answers, unknown questions, board answers, approved settings controls, and hub extension bindings. |
| 9 | Layout | `roomsorter.lua`, `sorter.lua`, `store.lua`, `warehouse.lua`, `warehouse-tasks.lua` | `wh2-layout.lua`, `tests/wh2-layout-*`, `docs/evidence/wh2-layout/`. Owns locations, room conversion, scans, placement, slots, and site-lock aliasing. |
| 10 | Craft | `factory.lua` | `wh2-craft.lua`, `wh2-recipes.lua`, `craft.lua`, `tests/wh2-craft-*`, `docs/evidence/wh2-craft/`. Owns recipe provider, production graph, workers, and factory compatibility adapter. |

Fleet reserves fixed optional modules `wh2-layout.lua`, `wh2-wizard.lua`, and `wh2-craft.lua` at the SSOT boundary. It also reserves later worker and hub dependencies in the role manifests and installer registry. Missing optional files do not fail a legacy install or erase saved state. Requests for an absent module return `unavailable`. Only enabled, installed modules receive v2 operations. Unvalidated saved data from an absent module remains opaque and cannot be replaced by another module.

Wizard binds optional `wh2-recipes.lua.open(context)` on the hub. Context contains the shared RPC worker, Recipe Index peripheral, and board drawing helpers. The returned service exposes `tick`, `draw`, and `handle`; absent service means an unavailable craft panel. Craft implements this binding without editing `hub.lua` or `panel.lua`. `wh2-client.lua` supplies queued `call`, receiver `dispatch`, and settings refresh to all callers. These are fixed extension points, not arbitrary downloaded plugins.

Fleet and wizard may develop alongside hardening. Fleet rebases onto H5 and retains H3's queue, H1+H2's authentication and updater, and H5's recovery fields. It adds wh2 handlers and manifest entries at those extension points. Wizard then rebases onto fleet, including hardened hub and panel changes. It uses `wh2-client` over the authenticated outbound worker and cannot restore legacy packet handling. Layout rebases onto wizard and keeps H5's warehouse expiry and quantity reconciliation. Craft follows layout. No feature PR may cherry-pick an old shared file over these owners' changes.

A required shared-file change goes to its named owner before that owner's merge. After merge it is a narrow integration follow-up in merge order. No PR copies another owner's module or invents a second registry. The orchestrator merges. Authors do not merge their own PRs.

## Source checks and implementation gates

The existing boundaries are in [SSOT](../../ssot.lua), [its client](../../ssot-client.lua), [navigation](../../nav.lua), [mining](../../mining.lua), [warehouse tasks](../../warehouse-tasks.lua), [warehouse worker](../../warehouse.lua), and [room sorter](../../roomsorter.lua). Setup and recovery are described in [SSOT configuration](../ssot-pr1.md), [navigation](../navigation.md), [mining](../mining.md), and [warehouse](../warehouse.md). The [review](../review/judgment-2026-10-20.md) grounds the hardening scope. The [backlog](../backlog.md) remains later work.

Recipe sources are `C:\Work\mudded-mods\mods\recipe_index\API.md` and `C:\Work\recipe-data\recipes\`, including `README.md`, `stats.txt`, `recipes.json`, and `recipes_lua/minecraft.lua`. The dump and API are different formats; an import always converts explicitly.

This contract adds no executable behavior and claims no runtime gate result. Each implementation PR needs saved Gate A and Gate B evidence under [Gate B depth](../testing/gateB-depth.md). Relevant flows include attacker and replay cases, counter rollover, fake discovery, interrupted updates, event bursts during saves and HTTP, timer survival, lost movement commits, GPS loss, dead turtles, and the warehouse flows already defined here. Evidence records the actual disk capacity and free space. Craft also proves its hub runs within the separate 1 MB budget above. Pending H4 and autonomy scenarios become implementation gates only after their respective approvals. A skipped required runtime check is a failed gate, never a fabricated pass.
