# Warehouse v2 contract

This is the shared reference for fleet, layout, wizard, and craft. It defines new interfaces. The four PRs branch from this base and merge in that order. Existing `mine-*`, `wh-*`, navigation, and legacy rednet interfaces retain their meanings.

## Ownership and coordinates

The server's sole SSOT dispatcher owns durable shared state. New modules participate in its existing copy, validate, replay, save, and reply transaction. They do not write separate shared state files or send replies themselves.

```lua
wh2 = {
	schema = 1,
	fleet = { revision = 0, records = {}, settings = {} },
	layout = { revision = 0, locations = {}, rooms = {}, slots = {}, classDefaults = {} },
	wizard = { revision = 0, classes = {}, questions = {} },
	craft = { revision = 0, jobs = {}, queries = {} },
}
wh2Config = { enabled = false, operators = { ["4"] = true }, recipeHubId = 5 }
pose = { dim = "minecraft:overworld", x = 10, y = 65, z = 20 }
access = {
	pose = { dim = "minecraft:overworld", x = 10, y = 65, z = 20, h = 0 },
	side = "front",
}
```

`s.wh2` is additive to schema 1 `ssot.state`. A missing subtree means that its feature has never written state. Existing state never disappears because its module is absent. Each module validates its own subtree through `valid(value, poseValidator)` and handles its operations through `run(s, senderId, message, context)`. Context contains UTC milliseconds in `now`, the server's string `epoch`, `pose`, and validated configuration. A module writes only its own subtree. Only SSOT saves the resulting state and replay record. `wh2Config` is the private `ssot.cfg.wh2` shape; all listed IDs also require existing controller pairing.

Coordinates are integer world blocks with a dimension. Headings use `nav.lua`, with east 0, south 1, west 2, and north 3. `access.pose` is the turtle's standing cell; it is not the inventory block. `side` is `front`, `top`, or `bottom`. Room-relative coordinates and the legacy room heading 0 need an explicit layout conversion before publication. GPS plus a calibrated heading establishes that conversion.

Record, location, and job IDs are stable strings of at most 64 bytes. Item, block, recipe, and tag IDs retain their namespaced provider strings. Existing map and warehouse validators still apply at those boundaries. An unsupported long resource ID fails explicitly rather than being truncated. Unknown scalar values use `false`. Absent optional keys retain the source API's meaning. Arrays are dense. Tables contain no functions, metatables, cycles, or shared table references on the wire.

## Fleet and jobs

```lua
fleetRecord = {
	id = "cc:17", computerId = 17, turtleId = 17,
	kind = "turtle", label = "Miner east", role = "miner",
	boot = "1792500000000:17", state = "mining", detail = "Zone 3",
	pose = { dim = "minecraft:overworld", x = 10, y = 65, z = 20 },
	heading = 0, poseConfirmed = true,
	fuel = { level = 1800, limit = 20000 },
	inventory = { slots = 16, usedSlots = 14, fullness = 0.875 },
	currentJob = { kind = "mine", id = "zone:3", step = "extract" },
	lastSeen = 1792500000000, appliedSettingsRevision = 4,
	capabilities = { navigation = true, inventory = true, crafting = false },
	error = false,
}
```

The rednet sender is the computer identity. A turtle's `turtleId` equals its CC computer ID; CC supplies no separate turtle UUID. Other computers use `turtleId=false`, `fuel=false`, and `inventory=false`. Labels can change without changing identity. Roles are `miner`, `store`, `crafter`, `factory`, `hub`, `server`, `panel`, or `other`.

States are `idle`, `mining`, `returning`, `dropping`, `charging`, `sorting`, `crafting`, `blocked`, or `stopped`. Readers derive `offline` after 15000 ms without a report. `lastSeen` is server UTC milliseconds, never a sender timestamp. Offline status does not release occupancy, site locks, or active work. Fuel uses `"unlimited"` for unlimited level and limit, never infinity.

Fullness is occupied slots divided by total slots. It is not an item count divided by 1024. Complete inventory scans belong to the storage or worker inventory model, not the heartbeat's legacy loot summary. `currentJob=false` means idle. Otherwise `kind` is `mine`, `warehouse`, or `craft`; `id` references the owning allocator. Fleet does not duplicate allocator tokens or progress journals.

For coordinated turtles, `pose` comes from confirmed `s.poses`; heading comes from the calibrated movement owner. A report cannot move SSOT occupancy. Legacy observations have `poseConfirmed=false` and cannot authorize a route. A changed boot or uncertain position requires existing navigation reconciliation.

## Settings and live changes

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

Pairing keys, server identity, dimension, calibrated pose, and physical journals remain local setup. Both the server's `ssot.cfg.wh2.enabled` and the turtle's local `wh2.enabled` default off. A remote behavior setting cannot bypass those prerequisites or clear ESTOP. After bootstrap opt-in, reads and authorized management requests remain available while behavior flags are off. Existing configurations seed settings only through an explicit opt-in import. The adapter converts old seconds to milliseconds and preserves the different room and wired sorter defaults. `cook` maps to `smelting`. Normal startup does not overwrite shared settings with old `miner.cfg`, `room.cfg`, or `sorter.cfg` values.

## Locations and rooms

```lua
location = {
	id = "mine-drop", kind = "dropoff", roomId = "room:main", enabled = true,
	block = { dim = "minecraft:overworld", x = 11, y = 65, z = 20 },
	access = {
		pose = { dim = "minecraft:overworld", x = 10, y = 65, z = 20, h = 0 },
		side = "front",
	},
	siteNames = { source = false, drop = "mine-drop", charge = false },
	lockId = "inventory:mine-drop", revision = 3,
}
room = {
	id = "room:main", revision = 3, scanComplete = false,
	bounds = {
		min = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 },
		max = { dim = "minecraft:overworld", x = 15, y = 70, z = 31 },
	},
	observedChunks = { ["minecraft:overworld|0|4|0"] = 8 },
	blocked = { ["minecraft:overworld|5|65|5"] = "minecraft:stone" },
	accessPaths = {
		["mine-drop"] = {
			{ dim = "minecraft:overworld", x = 9, y = 65, z = 20 },
			{ dim = "minecraft:overworld", x = 10, y = 65, z = 20 },
		},
	},
	reserved = {
		["minecraft:overworld|10|65|20"] = { kind = "access", locationId = "mine-drop" },
	},
}
```

Location kinds are `dropoff`, `charge`, `parking`, `warehouse_input`, `warehouse_output`, `storage`, `furnace`, `blast`, `smoker`, and `room`. A room location references `roomId` and can omit `block` and `access`. Other locations have an access pose. Inventory locations also have a block pose. A parking spot has no inventory or site lock. Missing optional devices are absent locations, never guessed coordinates.

`dropoffId`, `chargerId`, and `parkingId` select shared locations. When false, resolution selects an enabled, reachable location of that kind in the turtle's dimension, ordered by route cost then ID. No candidate means a visible blocked reason. Miners therefore need no local drop-off coordinate.

Layout adapts locations to existing `wh-site` records through `siteNames`. Drop-off, warehouse output, and machine input access use `kind="drop"`. Pickup storage and warehouse input use `kind="source"`. Chargers use `kind="charge"` and a lock ID for their bay. A bidirectional inventory has separate source and drop names sharing one `lockId`. Layout assigns the same lock identity to every view of the same dimensioned block. Parking and room locations use false for unused site names and lock IDs.

Room bounds are inclusive. SSOT chunk observations remain the source for observed air, solids, and unknown cells. `observedChunks` pins their revisions; a missing cell is unknown, not air. `blocked` is the sparse room obstacle index, including pillars and irregular walls. Layout does not infer an entire column from one floor observation. `scanComplete` requires an observation of every cell in the scanned volume.

Access paths contain adjacent, observed air cells and end at the location's standing cell. Layout validates paths against current observations before allocation or placement. `reserved` prevents building on access paths, entrances, parking cells, charger cells, and machine access cells. Reservation kinds are `access`, `entrance`, `parking`, `charge`, or `machine`. These are layout reservations. Transient movement reservations remain exclusively in `s.moves`, with their existing tokens and restart behavior.

## Storage and item classes

One storage slot describes one physical inventory and its placement intent. `contents` uses the inventory's native numbered slots.

```lua
storageSlot = {
	id = "slot:main:12", roomId = "room:main", locationId = "chest-12",
	kind = "chest", category = "ingots", revision = 6,
	size = 27, observedAt = 1792500000000,
	contents = {
		[1] = { item = "minecraft:iron_ingot", count = 32, maxCount = 64, nbt = false },
	},
}
machineSlot = {
	id = "slot:main:blast1", roomId = "room:main", locationId = "blast-1",
	kind = "blast", category = false, revision = 6,
	size = 3, roles = { [1] = "input", [2] = "fuel", [3] = "output" },
	contents = { [2] = { item = "minecraft:coal", count = 8, maxCount = 64, nbt = false } },
}
itemClass = {
	item = "minecraft:raw_iron", class = "ores", route = "blast",
	storeCategory = "ingots", recipeId = "minecraft:iron_ingot_from_blasting_raw_iron",
	source = "layout", revision = 2, updatedBy = 17,
}
unknownQuestion = {
	id = "item:example:raw_tin", item = "example:raw_tin", state = "open",
	firstSeen = 1792500000000, sampleLocationId = "warehouse-in",
}
```

Storage kinds are `chest`, `furnace`, `blast`, or `smoker`. Barrels and other general inventories use `chest` after capability checks. Empty native slots are absent from `contents`. Unknown observations use `contents=false`; they never count as available stock. Actual `size`, stack limits, item counts, and NBT fingerprints come from inventory APIs. Component-sensitive stacks cannot merge merely because their item IDs match.

All three cooking machines use native slots 1 for input, 2 for fuel, and 3 for output. Fuel slots accept validated fuels. Outputs are extraction-only. Machine slots are never spare chest capacity. A removed machine invalidates its observation and blocks its job. Layout intent does not promise an inventory exists.

Categories are `any`, `ores`, `ingots`, `gems`, `fuel`, and `misc`. The effective item-class table maps item IDs to rows. `route` is `store`, `furnace`, `blast`, `smoker`, `fuel`, or `unknown`. `storeCategory` is the destination category for stored items or collected results. `recipeId=false` means no selected processing recipe. `fuel` routes to fuel storage. Workers consume it only under the fuel policy and stock reservations.

Layout owns exact-ID defaults in `s.wh2.layout.classDefaults`, with `source="layout"`. Wizard owns answers in `s.wh2.wizard.classes`, with `source="wizard"`. Readers overlay answers on defaults. Defaults work before wizard is installed and cannot overwrite answers. The `classes` query returns this effective view with revision `"<layoutRevision>:<wizardRevision>"`, using 0 for an absent subtree. Repeated unknown reports coalesce into one question per item ID. An answer commits its class row and question resolution together. Unknown or unsupported routes retain the stack in the input or designated quarantine storage and report the question. They never discard it or infer a recipe from a name suffix.

`wh2-client.lookupClass(itemId)` returns the effective row and class revision through `wh2-get`, or a row with `route="unknown"` when no definition exists. `reportUnknown(itemId, locationId)` queues `wh2-unknown`. A class change hint or a changed revision invalidates cached rows. Before wizard is installed, defaults remain readable and unknown reporting returns `unavailable`; the worker retains the item for a later report. Layout callers use these methods and do not import the wizard module.

Every transfer takes the existing physical site lock. Existing warehouse stock reservations remain the authority for pickup quantities. Craft reserves ingredients through those orders; it does not subtract stock in a second ledger. Layout refuses to move or remove locations used by an active lock or job.

## Recipe graph and production

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
	id = "craft:17:9", key = "board:17:request9", requestedBy = 17, revision = 2,
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
	action = "progress", jobId = "craft:17:9", token = "claim:17:9", epoch = "3",
	stepId = 1, state = "done",
	observed = { locationId = "furnace-1", item = "minecraft:glass", count = 6, stockRevision = 8 },
}
```

An ingredient has `count` and exactly one of `item`, `tag`, or `items`. Tags have no leading `#`. `more=true` means an API alternatives list is incomplete. `resolveTag` returns complete item-tag membership. A capped alternatives list cannot prove an unlisted substitute is invalid or available. The planner records each concrete choice and checks actual stock before reservation.

Recipe kinds use `type`, not the human `machine` text. `minecraft:crafting` plus a numeric `pattern` is shaped; the same type without it is shapeless. Pattern keys are turtle slots 1, 2, 3, 5, 6, 7, 9, 10, and 11. Other turtle slots must be empty for crafting. Cooking kinds are `minecraft:smelting`, `minecraft:blasting`, and `minecraft:smoking`. Other types retain their source IDs and require a matching installed machine adapter. An unsupported adapter produces a blocked step with its type, never a successful craft.

Optional `fluids`, `heat`, `time`, `steps`, `loops`, and `transitional` retain the API shapes and omissions. Fluid amounts are millibuckets and time is ticks. Sequenced assembly keeps ordered steps and repeats them `loops` times. Step addition counts multiply by loops; the transitional item is not an addition. An API step has `type`, `machine`, and `inputs`, with optional `outputs` and `fluids`. It has no invented `heat`, `time`, `pattern`, or `id` fields. Unknown heat, tools, energy costs, component requirements, or container returns need an adapter or a blocked reason.

Production steps use `ceil(required / guaranteedOutputCount)` batches, share surplus within the plan, and consume each dependency once. Outputs with chance below 1 cannot satisfy a guaranteed count. Cycles terminate with an explicit unresolved requirement. A step's `needs` references earlier step IDs. `ingredients` records chosen item fingerprints and per-batch counts. `orderKey` and `line` reference existing warehouse reservation lines, or are false before allocation. A component-sensitive ingredient needs verified matching stock; existing item-only totals cannot prove that match. States are `pending`, `running`, `done`, `blocked`, or `uncertain`. Job states are `planning`, `planned`, `running`, `blocked`, `done`, `cancelled`, or `uncertain`. A missing ingredient blocks execution and reports its exact count.

Create returns a `planning` job. Only the configured hub planner publishes its plan with `wh2-craft` action `plan`, carrying `jobId`, `baseRevision`, `generation`, `offset`, `steps`, `missing`, and `final`. Step offsets start at 0 and count accepted steps. The server stages one plan per job and commits only a complete validated graph. Plans have at most 128 steps and use the same byte limits as other uploads. A changed job revision or provider generation rejects the staged plan. Physical workers claim only a complete plan. Fuel and machine operating inputs are explicit requirements when an adapter knows them.

Creating a craft uses a caller key that remains stable across retries. Jobs retain ownership across restarts. Workers journal physical actions through the existing navigation and warehouse boundaries. An uncertain transfer, smelt, or craft requires inventory reconciliation before retry. `produced` and `delivered` count observed output, not requested output or acknowledged commands. Completion requires the requested count in the output inventory. Batch surplus stays recorded stock.

### Hub limits and recipe service

The supplied dump's `recipes_min.lua` contains 3878 recipes and is 1131311 bytes. `recipes.json` contains 3880 shaped and shapeless crafting recipes. `stats.txt` reports 3878 and records 2441 excluded non-crafting recipes. The dump cannot supply smelting or the complete runtime graph. The live Recipe Index is authoritative for the installed recipes and tags. An offline import is an explicit fallback pinned to its file hash. It converts dump `s`, `l`, `o`, `n`, and `#tag` fields to this schema and preserves result components as unresolved requirements when necessary.

The hub queries `getRecipesFor`, `getUsesOf`, `getRecipe`, `list`, and `resolveTag` on demand. It never installs the complete dump, all namespace shards, or a serialized full graph. Its recipe cache occupies at most 131072 encoded bytes in RAM and is disposable. Persisted hub files, temporary generations, backups, scripts, and any optional offline shard together stay below 1000000 bytes with 8192 bytes free for writes. Insufficient space rejects the import or save; raising the disk limit does not satisfy this requirement.

Remote graph requests use a bounded queue in `s.wh2.craft.queries`. The server returns a ticket immediately. A hub worker claims the query, calls the peripheral outside the rednet receiver, and publishes one result fragment. Clients read that fragment by ticket. There are at most four active tickets, one unconsumed fragment per ticket, and a 30000 ms idle expiry. The query owner releases or advances its ticket after reading. Expiry discards recipe lookup state only, never production work.

```lua
recipeQuery = {
	action = "query", key = "board:17:lookup9",
	method = "getRecipesFor", id = "minecraft:glass", page = 1, pageSize = 20,
}
recipeFragment = {
	action = "publish", ticket = "recipe:17:9", token = "recipe-claim:9", epoch = "3",
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

Graph pages are disposable. Only selected production steps and bounded query fragments enter shared state. They remain subject to SSOT's 900000-byte generation limit and its replay-cache cost. This hub disk limit does not claim that the existing coordinator's three SSOT generations fit on a 1 MB disk.

## Rednet protocol

All requests use protocol `fleetserver`, the existing SSOT envelope version 1, and payload `wh2=1`. Warehouse v2 does not change the transport version. Clients use one `ssot-client` instance and feed `dispatch` from the program's existing sole application receiver. Blocking calls run outside that receiver.

```lua
request = {
	v = 1, type = "ssot", expect = "ssot_reply", op = "wh2-get", wh2 = 1,
	rid = "1792500000000:17:42", boot = "1792500000000:17", counter = 42,
	secret = "private-paired-key", topic = "locations", cursor = 0,
}
reply = {
	v = 1, type = "ssot_reply", rid = "1792500000000:17:42",
	server = 0, auth = "private-paired-key", wh2 = 1, ok = true,
	revision = 3, records = {}, cursor = 0,
}
changeHint = {
	v = 1, type = "wh2_changed", wh2 = 1, server = 0,
	auth = "private-paired-key", topic = "settings", revision = 5,
}
```

The paired sender owns its own telemetry and settings acknowledgement. Configured operator computer IDs may edit settings, layouts, classes, and craft requests. A configured recipe hub ID may claim and publish recipe queries. These roles come from private `ssot.cfg.wh2` configuration, not a self-reported fleet role. Legacy hub packets cannot write v2 state. Secrets never appear in fleet records or view responses.

The client validates the sender, server ID, auth, version, response type, and pending request ID. Retries reuse the original request, counter, and ID. New requests advance the existing durable counter. The existing eight-result replay rule and save-before-reply ordering remain. Operation names stay within 16 bytes. Requests and replies stay within 8192 compact serialized bytes and `ssot.bounded` limits. Ordinary pages target 4096 bytes with at most 64 records. Larger records use explicit subresource pages, never truncated facts.

`wh2-get` starts with cursor 0. Later pages pin `revision`; cursor 0 in a reply means complete. Records sort by stable ID. A changed revision returns `stale_revision` and restarts the read. Mutation errors use `ok=false`, `code`, and a readable `error`; codes are `invalid`, `forbidden`, `disabled`, `unavailable`, `stale_revision`, `busy`, `capacity`, `blocked`, `too_large`, or `recipe_unavailable`. Invalid authentication retains the existing silent rejection.

The change hint only schedules an authenticated read. It never applies settings or causes movement. Clients validate its sender and auth and coalesce hints. Lost hints recover through heartbeat polling.

The operation payloads are fixed by this table. Common envelope fields are omitted.

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

Layout subresource messages have these operation fields, inside the same SSOT envelope.

```lua
layoutUpload = {
	op = "wh2-layout", kind = "room", id = "room:main", field = "accessPaths",
	pathId = "mine-drop", baseRevision = 3, offset = 0, final = true,
	records = {
		{ dim = "minecraft:overworld", x = 9, y = 65, z = 20 },
		{ dim = "minecraft:overworld", x = 10, y = 65, z = 20 },
	},
}
layoutRead = {
	op = "wh2-get", topic = "rooms", id = "room:main", field = "accessPaths",
	pathId = "mine-drop", revision = 4, cursor = 0,
}
```

Room fields are `accessPaths`, `blocked`, and `reserved`. The slot field is `contents`. A path upload identifies one `pathId` and streams poses. Blocked and reserved records have named `key` and `value` fields. Contents records have named `slot` and `stack` fields. Offsets are zero-based counts of accepted records. Replies contain `nextOffset` and the unchanged base revision until `final` commits a new revision. Read cursors follow the ordinary `wh2-get` rule. The server stages one edit of at most 65536 encoded bytes per operator, rejects gaps or changed revisions, and publishes only a validated final record. Staging expires after 30000 ms idle without replacing the current record. These fragments count toward the shared state limit. No partially uploaded room becomes executable.

## File boundaries and merge order

The base owns only this contract. No LuaLS file duplicates these tables. Each PR owns its named tests and evidence directory; shared runner hooks belong to fleet and accept optional scenario modules from later PRs.

| Merge | PR | Owned existing files | Owned new files and data |
| --- | --- | --- | --- |
| 1 | Fleet | `server.lua`, `ssot.lua`, `ssot-client.lua`, `miner.lua`, `mining.lua`, `nav.lua`, `fleetview.lua`, `install.lua`, `update.lua`, shared test runner dispatch | `wh2-fleet.lua`, `wh2-client.lua`, `tests/wh2-fleet-*`, `docs/evidence/wh2-fleet/`. Owns fleet, settings, protocol registration, optional module loading, and deployment lists. |
| 2 | Layout | `roomsorter.lua`, `sorter.lua`, `store.lua`, `warehouse.lua`, `warehouse-tasks.lua` | `wh2-layout.lua`, `tests/wh2-layout-*`, `docs/evidence/wh2-layout/`. Owns locations, room conversion, scans, placement, slots, and site-lock aliasing. |
| 3 | Wizard | `hub.lua`, `panel.lua` | `wh2-wizard.lua`, `tests/wh2-wizard-*`, `docs/evidence/wh2-wizard/`. Owns class answers, unknown questions, board answers, settings controls, and hub extension bindings. |
| 4 | Craft | `factory.lua` | `wh2-craft.lua`, `wh2-recipes.lua`, `craft.lua`, `tests/wh2-craft-*`, `docs/evidence/wh2-craft/`. Owns recipe provider, production graph, workers, and factory compatibility adapter. |

Fleet reserves fixed optional modules `wh2-layout.lua`, `wh2-wizard.lua`, and `wh2-craft.lua` at the SSOT boundary. It also reserves later worker and hub dependencies in installer, updater, and server mirror lists. Missing optional files do not fail a legacy install or erase saved state. Requests for an absent module return `unavailable`. Only enabled, installed modules receive v2 operations. Unvalidated saved data from an absent module remains opaque and cannot be replaced by another module.

Wizard binds optional `wh2-recipes.lua.open(context)` on the hub. Context contains the shared RPC worker, Recipe Index peripheral, and board drawing helpers. The returned service exposes `tick`, `draw`, and `handle`; absent service means an unavailable craft panel. Craft implements this binding without editing `hub.lua` or `panel.lua`. `wh2-client.lua` supplies queued `call`, receiver `dispatch`, and settings refresh to all callers. These are fixed extension points, not arbitrary downloaded plugins.

All four PRs can develop against this document before earlier PRs merge. Later PRs rebase after their predecessors land. A required shared-file change goes to its named owner before that owner's merge; after merge it is a narrow integration follow-up in merge order. No PR copies another owner's module or invents a second registry. The orchestrator merges; authors do not merge their own PRs.

## Source checks and implementation gates

The existing boundaries are in [SSOT](../../ssot.lua), [its client](../../ssot-client.lua), [navigation](../../nav.lua), [mining](../../mining.lua), [warehouse tasks](../../warehouse-tasks.lua), [warehouse worker](../../warehouse.lua), and [room sorter](../../roomsorter.lua). Setup and recovery are described in [SSOT configuration](../ssot-pr1.md), [navigation](../navigation.md), [mining](../mining.md), and [warehouse](../warehouse.md).

Recipe sources are `C:\Work\mudded-mods\mods\recipe_index\API.md` and `C:\Work\recipe-data\recipes\`, including `README.md`, `stats.txt`, `recipes.json`, and `recipes_lua/minecraft.lua`. The dump and API are different formats; an import always converts explicitly.

This contract adds no executable behavior and claims no runtime gate result. Each implementation PR needs saved Gate A and Gate B evidence under [Gate B depth](../testing/gateB-depth.md). Relevant flows include multiple turtles, irregular rooms, exact mixed-stack counts, live global and per-turtle settings, persistent wizard answers, real machine steps, missing ingredients, concurrent requests, and restart reconciliation. Existing runners use a 4 MB coordinator disk; craft must also prove its hub runs within the separate 1 MB budget above. A skipped required runtime check is a failed gate, never a fabricated pass.
