# H4 offline contract

The shapes and byte rules below are complete for review. They become the frozen program contract after P0 passes. The fourteen open groups in the earlier candidate are resolved. [P0's evidence](../evidence/p0/README.md) records Gate A PASS and Gate B FAIL because the required real-client measurements could not run. P0 changes no runtime behavior. Every later runtime feature defaults off.

The [accepted H4 offline plan](../plans/cc-h4-offline-plan.md) is authoritative. This reference preserves every record and field in its sections 2 and 5b. The [wh2 contract](wh2-contract.md), [hardening notes](hardening.md), and [miner autonomy notes](miner-autonomy.md) apply only where they agree with that plan. Explicit P0 clarifications and deviations appear in the final decision table. Examples describe shapes. Placeholder strings and zero timestamps are not valid grants, measured results, or cryptographic vectors.

## Shared conventions

Named records retain the plan's `v`. Embedded types inherit that version. Unknown versions and unknown record fields fail at input and disk boundaries. Explicit dictionaries, such as settings and peripheral maps, use their declared key rules. A reader preserves an unsupported source instead of deleting or reinterpreting it. Payload versions, state schema, baseline `ver`, transport versions, and content `rev` are distinct.

Tables contain finite numbers, byte strings, booleans, and tables. Arrays are dense and start at 1. Dictionary keys are strings or declared integers. Metatables, functions, cycles, and shared table references are invalid serialized input. Repeated `pos` in examples means independent values. `false` means an explicitly unavailable value where allowed. It never means air or permission. Required fields cannot be omitted. In prose, braces that list bare field names describe named record fields, not positional arrays. Code blocks use Lua table syntax. This convention also applies to the field lists passed to C and B.

Computer IDs are integers from 0 through 2147483647. Revisions, counts, byte sizes, and sequence numbers are exact nonnegative integers at most 9007199254740991. Sequences start at 1 and never wrap. Record IDs are stable strings of at most 64 bytes. Boot and request IDs allow 80 bytes, dimension IDs 80, resource IDs 128, section keys 256, paths 128, and display text 256. Dimensions and resources retain the current namespaced syntax. Strings are never truncated. Ratios are finite values from 0 through 1.

Times are server UTC milliseconds from `os.epoch("utc")`. In-game time never orders observations or authorizes work. Durations use milliseconds. Expiry is exclusive, so `now >= untilAt` means expired. A durable `lastUtc` detects backwards clock movement. Time-dependent work stops on `now < lastUtc` until UTC catches up or an operator reconciles the clock and obtains fresh authority. Reboot cannot extend deadlines. Zero means never reported in peer metadata and unknown historical time in migrated observations. It cannot prove freshness.

Raw keys and public keys are byte strings, not hexadecimal text. SHA-256 hashes and full 32-byte keyed BLAKE3 MACs use 64 lowercase hexadecimal characters on disk and the wire. Ed25519 signatures use 128 lowercase hexadecimal characters. `bytes` counts encoded payload bytes, including file framing where present. Disk admission separately accounts for allocation overhead, directories, code, save copies, update staging, and control reserves. A 1 MB test disk has 1000000 bytes. The 65536-byte control reserve is 64 KiB.

The SSOT worker alone commits shared state. H3 keeps one FIFO of at most 32 requests. Parsing, cryptography, network work, and file preparation occur outside the non-yielding transaction. A prepared operation pins its input bytes, key generation, session, authority epoch, and state revisions. The transaction rechecks these pins, authorization, replay state, references, and deadlines before mutation and save. Changed pins require new preparation. Failed durability never acknowledges success.

Unknown cells are never free. Predicted cells cannot authorize walking. Intent, expiry, missing replicas, and plan retirement do not prove air. Settings cannot disable these rules, position confidence, lease boundaries, durable journals, or ESTOP.

### Canonical bytes

`C(value)` is the unique encoding below. It replaces the current request-cache serializer for v2 authentication.

| Value | Bytes |
| --- | --- |
| String | ASCII `s`, decimal byte length, ASCII `:`, then the raw bytes. |
| Boolean | ASCII `t` or `f`. |
| Number | ASCII `n`, 16 lowercase hexadecimal digits of its IEEE-754 binary64 bits in big-endian order, then ASCII `;`. Negative zero becomes positive zero. |
| Table | ASCII `m`, decimal entry count, ASCII `{`, each encoded key followed by its encoded value, then ASCII `}`. |

Counts have no leading zero or plus sign. Integer keys precede string keys. Integers sort numerically, strings by unsigned byte order. Keys are exact integers or strings only. Array positions are integer keys. Empty tables encode as `m0{}`. Nil, duplicate decoded keys, non-finite numbers, and integer magnitudes above 9007199254740991 fail. The decoder consumes exactly one value, rejects trailing bytes and noncanonical representations, and never uses Lua source loading. `textutils.serialize` is not `C`.

| Input | Canonical vector |
| --- | --- |
| `false` | `f` |
| `0` or negative zero | `n0000000000000000;` |
| `1` | `n3ff0000000000000;` |
| `{ a = "x", b = false }` | `m2{s1:as1:xs1:bf}` |
| `{ [1] = "a" }` | `m1{n3ff0000000000000;s1:a}` |
| A string containing NUL then `A` | ASCII `s2:` followed by bytes `00 41`. |

`B(domain,value)=C({domain=domain,value=value})`. Domain strings below are exact ASCII constants. `U16` and `U32` are unsigned big-endian integers of exactly two and four bytes. `hex` uses lowercase with no prefix. `unhex` rejects uppercase, odd lengths, and non-hex characters. These framing and encoding functions contain no cryptographic primitive.

### Wire bytes and bounded objects

Rednet protocol remains `fleetserver`. A v2 packet is the raw string `C(envelope)`. Both the complete packet and `C(envelopeWithoutMac)` are at most 8192 bytes. This explicitly replaces the older compact-Lua-table byte limit. The receiver bounds bytes before decoding, then limits nesting to 10 and keys plus values to 2048. Reassembled disk objects have depth at most 16 and at most 262144 keys plus values within their byte cap. These larger bounds never apply to a network envelope. A relay forwards the exact inner string. Its outer routing wrapper cannot influence authorization.

Oversized immutable objects use `blob-open`, `blob-part`, and `blob-close` through the same authenticated transport. Open operands are `{kind,id,bytes,sha256}`. Kinds are `lease`, `journal`, `section`, `region`, `manifest`, and `handover`. `id` and `sha256` both equal the SHA-256 hex of the complete transferred bytes. `bytes` is from 1 through 1048576. Parts are `{id,offset,data}`, with zero-based offset and at most 1024 data bytes. Parts are contiguous. An exact duplicate is a no-op. Changed duplicates and gaps fail. Open and part replies contain `{id,nextOffset}`. Close takes `{id}` and returns `{id,ready=true}` only after complete length, hash, and type validation.

One object per authenticated client may be staged. Admission reserves disk first. Staging expires after 120000 ms without progress and never represents acknowledged domain state. The sender retains its source. A domain operation uses `{blob=id}` in place of its oversized operand. Only that operation's durable success acknowledges application. A turtle cannot use a partial lease. Large journals use multiple objects containing whole entries. An oversized entry fails without truncation. Ordinary collection pages target 4096 bytes and contain at most 64 records.

## 2.1 Position and frame

```lua
pos = {
	v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
	x = 10, y = 65, z = 20, h = 0,
	conf = "certain", src = "neighbour", anchoredAt = 1792500000000,
}
frame = {
	v = 1, id = "f:17:1792500000000", owner = 17, yAbs = true,
	toAbs = false,
}
toAbs = { dx = 100, dy = 0, dz = 200, rot = 1 }
```

Coordinates are integer block cells. Positive x is east, positive y up, and positive z south. Bounds retain `ssot.lua` limits, x and z from -30000000 through 30000000 and y from -2048 through 2048. A transformed coordinate must also fit. `h` is mandatory and is east `0`, south `1`, west `2`, north `3`. Bounds ignore heading. This overrides current `nav.lua`'s north-0 convention.

`conf` is `certain`, `suspect`, or `lost`. `src` is `gps`, `neighbour`, `radio`, `typed`, `reckoned`, or `inherited`. Source alone never proves confidence. `anchoredAt` is the last trusted anchor time. Absolute positions require `yAbs=true`. Relative frames use the exact registered `f:` ID. Its owner is the creating computer. Registration binds that ID to one dimension, stored in the SSOT frame registry alongside the accepted frame record. Relative data has a separate key prefix.

A relative `yAbs=true` position has local x and z but world y. Otherwise all axes are local. `toAbs=false` means unanchored. A transform uses named integer fields. Rotation `rot` is from 0 through 3, with x-z mappings `{x,z}`, `{-z,x}`, `{-x,-z}`, `{z,-x}`. Translation follows rotation. Heading becomes `(h+rot)%4`, and y becomes `y+dy`. A `yAbs` frame requires `dy=0`. Repeating an identical merge is a no-op. A different transform for an already merged ID fails.

`frame-merge` freezes new work in that frame, reconciles or waits out its leases, transforms every map, plan, intent, pose, and access reference, then commits one generation selector. It keeps a durable `{id,dim,toAbs,sourceHash,targetHash,state}` receipt, where state is `prepared` or `committed`. A crash resumes that receipt. Destination observations merge by the replay rules. Disagreement without ordering evidence becomes unknown with retained provenance. Old lease MACs are never relabelled. New work receives new grants. Old-frame replay resolves through the saved transform and historical lease before merging once.

Certain position requires a clean journal since an anchor. A reboot with no unresolved action is suspect until its saved fingerprint matches. Unresolved movement needs an unambiguous fuel or endpoint fingerprint result. Fuel resolution requires enabled fuel, a measured move cost, and proof that neither charging nor upgrade regeneration occurred. Missing proof disables that resolver. A fingerprint is a sparse dictionary of direction numbers from section 2.2 to observed block names. Air is explicit. A match needs at least one recorded face and agreement on all recorded faces. Exactly one endpoint must match to resolve a move. Missing, identical, or conflicting evidence leaves it lost. During recovery, localFaces is rotated separately under each candidate heading before comparison with saved world-direction fingerprints. Front maps to h, back to h+2, left to h+3, and right to h+1 modulo four, then through the heading-to-direction table. Top and bottom map to directions 4 and 5. The probe never assumes the heading it is trying to prove.

Suspect or lost poses cannot dig. A dimension change makes the pose lost and cannot reuse the old frame. A relative pose can be certain locally. Radio anchoring needs four non-coplanar measurement points and a validated residual. Player anchoring uses the floored player's cell minus one in y when standing on the turtle. Platform accuracy and residual bounds require P0 measurements. The player-anchor formula remains unqualified until the blocked real-client check runs. No GPS host is assumed. GPS is an optional check only.

## 2.2 Map region and section

P0 preserves the plan's fields and adds explicit codec, baseline-reference, coverage, and provenance fields.

```lua
region = {
	v = 2, key = "abs|minecraft:overworld|0|0",
	baseline = {
		ver = 3, frozen = true, surface = "<4096 U16 heights>",
		fillerTo = { dirt = 3 }, blendLo = 0, blendHi = 8,
		samples = 4120, calibratedAt = 1792500000000,
	},
	segments = {
		{ x = 1, y = -54, z = 0, d = 2, n = 64, inspected = true,
			by = 17, lease = "7:mine:12", rev = 812, base = 3,
			at = 1792500000000, seq = 41, evidence = { turtle = 17, lease = "7:mine:12", seq = 41 } },
	},
	boxes = {
		{ min = { x = 0, y = -54, z = 0 }, max = { x = 1, y = -53, z = 1 },
			kind = "air", inspected = true, rev = 900, base = 3,
			by = 17, lease = "7:mine:12", at = 1792500000000, seq = 42,
			evidence = { turtle = 17, lease = "7:mine:12", seq = 42 } },
	},
}
section = {
	v = 2, key = "abs|minecraft:overworld|3|4|-2", rev = 812,
	hash = "<64 lowercase hex digits>", codec = "sparse/1",
	base = { region = "abs|minecraft:overworld|0|-1", ver = 3, hash = "<baseline SHA-256 hex>" },
	palette = { "=", "minecraft:air", "minecraft:diamond_ore" },
	cells = "<sorted cell records>", cover = { segments = {}, boxes = {} },
	provenance = { seed = false, facts = {}, conflicts = {} },
	observedAt = 1792500000000, lastRead = 1792500000000, tier = "hot",
}
```

### Keys, directions, and palettes

Sections contain 16 by 16 by 16 cells. Their keys are `frame|dim|sx|sy|sz`, using floor division by 16. Regions contain 64 by 64 columns. Keys are `frame|dim|rx|rz`, using floor division of x and z by 64. Numeric key components have no padding, plus signs, or negative zero. Frame and dimension components cannot contain `|`.

The logical cell index remains `1+xLocal+16*zLocal+256*yLocal`, from 1 through 4096. Local coordinates use nonnegative remainders, including for negative world coordinates. Region-local x and z are from 0 through 63. Region y uses frame y. Box corners are embedded `{x,y,z}` values with inclusive ordered bounds.

Segment `d` and fingerprint keys retain the existing vector numbering. They are separate from heading `h`.

| `d` | Delta x, y, z | Horizontal `h` |
| --- | --- | --- |
| 0 | 0, 0, -1 | 3 |
| 1 | 1, 0, 0 | 0 |
| 2 | 0, 0, 1 | 1 |
| 3 | -1, 0, 0 | 2 |
| 4 | 0, 1, 0 | None. |
| 5 | 0, -1, 0 | None. |

A palette contains distinct full block IDs and, in H4b2, the marker `=`. Entries sort by raw byte order, which places `=` first. Entries referenced by current cells, seeds, or facts remain. Unreferenced entries are removed. Palette width `w` is one byte for at most 255 entries and two bytes otherwise. Palette references are unsigned big-endian integers of width `w`. At most 65535 entries fit across retained evidence. Exhaustion returns `capacity` without loss. This wide form prevents a hidden replacement for the removed global name cap. Zero is unknown in RLE only. Air is the explicit name `minecraft:air`.

### Cell encoding and file identity

H4b1 uses `codec="rle/1"`, `base=false`, and empty coverage. `cells` consists of `U16(runLength)` followed by one palette reference. Positive run lengths cover indices 1 through 4096 exactly. Adjacent runs must differ. Unknown runs use reference zero. An all-unknown section with an empty palette has bytes `10 00 00`. An all-air section with palette `{ "minecraft:air" }` has bytes `10 00 01`.

H4b2 uses `codec="sparse/1"`. Each record is `U16(index)` followed by one nonzero palette reference. Indices strictly increase. An empty string means no explicit cells. With the example palette, air at index 1 and diamond ore at index 4096 encode as `00 01 02 10 00 03`. Invalid lengths, duplicate indices, missing palette entries, zero sparse references, and noncanonical RLE fail the decode.

The H4b2 reader accepts both codecs. Its default-off flag controls sparse writes and prediction exposure. Turning it off preserves access to existing observed data, resolves stored `=` against its pinned baseline, and materializes names and coverage before a later RLE write. It suppresses predicted results. An older reader that supports only RLE refuses sparse files instead of treating them as empty.

The `=` marker requires a resolvable pinned baseline. It means an actual observation whose exact material equals that prediction. It cannot mark an unobserved cell. Filler equivalence affects cost and prediction scoring, but observed names remain lossless. This clarifies the plan's filler-class shorthand.

The immutable section payload is exactly `{v,key,rev,codec,base,palette,cells,cover,provenance,observedAt}`. Let `P=C(payload)` and `D=sha256.digest(B("cc-h4/section/2",payload))`. File bytes are ASCII `H4S`, byte `02`, `U32(#P)`, `P`, then the 32 raw bytes `D`. `section.hash=hex(D)`. `placement.bytes` counts this whole file. `lastRead` and `tier` are directory metadata excluded from the hash. Immutable changes require a new revision and hash.

Region files use ASCII `H4R`, byte `02`, the same length and digest framing, and domain `cc-h4/region/2`. Their payload is exactly the region table. Baseline identity is `hex(sha256.digest(B("cc-h4/baseline/2",baseline)))`. The baseline registry is keyed by region key, `ver`, and that hash. References retain the exact baseline after recalibration. Missing baseline bytes make dependent `=` cells unknown. A reader cannot substitute the current baseline.

Section slots are map/sections/<keyHash>.a and map/sections/<keyHash>.b, where keyHash is SHA-256 hex of B("cc-h4/section-key/1",key). Region slots use map/regions and domain cc-h4/region-key/1. Baselines use map/baselines/<baselineHash>.bin. The directory stores the selected revision and content hash. A prepared slot does not change that selection. Superseded slots and baselines remain while a recovery generation references them.

A file is at most 1048576 bytes. Actual disk admission can be smaller. Capacity refusal preserves the previous file and all pending evidence. `tier` is `hot` or `cold`. H4b1 writes hot sections. `observedAt` is the greatest accepted observation time in the section, or zero for legacy-only data.

### Geometry and provenance

A segment contains `n` observed air cells including its start, along `d`, with `1 <= n <= 4096`. A box has `kind="air"` and represents observed air throughout its volume. Region boundaries split shapes. Section `cover` stores the same shapes clipped to that section in region coordinates. Clipping retains evidence identity. Region arrays are a derived index of these section records, never an independent winner during lookup. Shape arrays sort by C(evidence), then start or minimum x, y, z, then d and n for segments or maximum x, y, z for boxes. Duplicate identical shapes coalesce. Conflicting material evidence stays in provenance.

Each shape's `evidence` identifies the journal action that proves its air cells. Its `by`, `lease`, `seq`, `at`, and `rev` match that accepted evidence. `base` is false or a baseline version. Planned tunnels and job counters cannot generate coverage without observations.

`inspected=true` requires an explicit observation for every face-adjacent cell outside the volume. Those observations retain their actual names. Otherwise `inspected=false`, while known faces remain individual observations. Diagonals are excluded. Geometry never implies neighbouring air or filler. Sparse cells override coverage. Conflict markers override both. Baseline prediction has lowest precedence. H4b1 exposes observed and unknown. H4b2 also exposes predicted.

Provenance is persisted and hashed.

```lua
observationFact = {
	id = { turtle = 17, lease = "7:mine:12", seq = 41 },
	at = 1792500000000, issuedRev = 800, rev = 812, owned = true,
	cells = "<sparse records in the section palette>",
}
observationSeed = {
	rev = 800, cells = "<RLE records in the section palette>", conflicts = {},
}
```

`facts` sorts by the byte order of `C({id=id,owned=owned})`. Each fact records only actual observations in this section. SSOT computes `owned` from historical authorization. Online evidence uses `lease="online:<session>"` and the accepted request counter as `seq`. Server-validated fresh online observations have observation authority. Legacy observations form the initial compacted cells without an invented observer or time. They enter the seed when the first replay begins.

`seed=false` means no unsealed facts. Before the first such fact, SSOT expands the existing materialized cells and coverage into one seed at the prior section revision. `conflicts` maps cell index to its conflict revision. The seed preserves pre-existing conflict entries. All encoded cell strings use the shared palette and are remapped together. Facts are immutable. The materialized result must equal the replay rules below.

Compaction waits until every lease that can replay against the section has a durable `lease-close` acknowledgement. It then folds facts into the seed-free materialized result and retains unresolved conflict markers. There is no eviction of pending provenance to save space. Capacity pauses new work. A fresh authorized observation can resolve a conflict. A stale replay cannot treat that conflict as never-observed space.

### Baseline prediction and recalibration

`surface` is exactly 8192 bytes in column order `1+xLocal+64*zLocal`. Each U16 is zero for unknown, otherwise `surfaceY+2049`. Values 1 through 4097 cover every supported y. Larger values fail. This replaces the plan's insufficient one-byte height field. Heights never clamp or wrap.

This version calibrates only `minecraft:overworld` and frames with `yAbs=true`. Other dimensions have no baseline prediction. A surface sample needs an observed solid and observed air immediately above it. The greatest qualifying solid y is the column's surface. Unknown columns are not interpolated. Calibration needs at least 32 distinct sampled columns and 256 distinct observed cells at or below their surfaces. These are policy constants, not measurements.

Before these requirements hold, region.baseline is false and section.base is false. Observations and geometry still persist. Such a section cannot contain `=`. Each region has a durable baseline-version counter that increases at publication and survives deletion of unreferenced older baseline files.

For each sampled column, count consecutive observed dirt cells immediately below its surface. Stop at unknown or another material, with a maximum of 64. `fillerTo.dirt` is the lower median of those counts. No other fillerTo key is defined in this version. `blendLo` is the minimum observed stone y and `blendHi` the maximum observed deepslate y. Both materials are required. If `blendLo > blendHi`, both become `floor((blendLo+blendHi)/2)`. `samples` counts distinct calibration cells, never repeated reports.

For a column with surface `s`, prediction is air above `s`, dirt from `s-fillerTo.dirt` through `s`, deepslate below `blendLo`, and stone above `blendHi`. Inside the band, deepslate applies below `ceil((blendLo+blendHi)/2)` and stone at or above it. Dirt takes precedence. Unknown surface means no prediction. Filler scoring groups stone, deepslate, tuff, andesite, granite, diorite, dirt, and netherrack. Gravel is excluded. Exact observed names remain recoverable.

Published baselines require `frozen=true`. Recalibration creates a higher `ver`. Before replacing a reference, each old `=` whose prediction changes becomes its old explicit block name. Observed air and conflicts survive. The writer verifies the observed-cell round trip before selecting the replacement generation. Old baselines remain while any active or recovery generation references them.

The P0 policy threshold for making H4b2 the default is misprediction strictly below 0.05 over at least 4096 distinct held-out observations from at least 16 sections. Holdout cells did not train that baseline. A different filler member is a class match. Wrong air, fluid, ore, falling material, and absent prediction count as errors. Gate B must also show fewer charged bytes than H4b1 for the same observations and provenance, including directories and both save copies. No predicted cell may authorize walking. This specifies a future gate and asserts no result.

## 2.3 Replica placement

```lua
placement = {
	v = 1, key = "abs|minecraft:overworld|3|4|-2", rev = 812,
	hash = "<section hash>", bytes = 1843,
	holders = { [21] = { ackAt = 0, verifiedAt = 0, role = "store", boot = "<peer boot>" } },
	localCopy = true, state = "hot",
}
```

`key`, `rev`, `hash`, and `bytes` identify one exact section file. SSOT records each holder's enrolled role, current boot, durable acknowledgement, and verification time. The added boot field prevents a new boot from inheriting an old acknowledgement. Zero times do not qualify.

States are `hot`, `replicating`, `cold`, `degraded`, and `unknown`. Hot has a local working copy. Replicating is obtaining required copies. Cold has the required peer copies. Degraded lacks required coverage but has a readable copy. Unknown has none currently readable. These labels never substitute for verification.

`localCopy` can become false only after two distinct eligible non-miner holders acknowledge and verify this exact revision and hash on their current boots. Miners hold extras only and never while holding an offline lease. A boot change removes that holder from the count until re-verification. Repair retains any local copy. Unreachable sections keep their directory records and read as unknown.

A replica is `C({v=1,key=key,rev=rev,hash=hash,bytes=bytes,blob=sectionFile,mac=mac})`. The MAC is `hex(blake3.digestKeyed(Kstorage,B("cc-h4/replica/1",{v=1,key=key,rev=rev,hash=hash,bytes=bytes,blob=sectionFile}),32))`. Kstorage is a separate random 32-byte server-only key. Peers verify the file's public hash and hold the MAC opaquely. The server checks both hash and MAC after fetch. Peer transfer and acknowledgement also use that peer's pairing transport. Peers never receive Kstorage or another client's pairing key. Verified floppy export of Kstorage is required before enabling peer storage.

## 2.4 Peer reachability

```lua
peer = {
	v = 1, id = 21, role = "store", enrolledAt = 0, enrolledBy = 4,
	quota = 420000, used = 120000, freeReported = 610000, reportedAt = 0,
	window = { sent = 240, ok = 236 }, lastReplyAt = 0,
	boot = "1792...:21", bootChanges = 1,
	power = { fuel = 18000, limit = 20000 }, holdsOfflineLease = false,
	score = 0.98, eligible = true, why = false,
}
```

SSOT owns enrollment and eligibility. `quota` is a finite charged-byte allocation after code, navigation, journal, update, and control reserves. `0 <= used <= quota`. `freeReported` is finite whole-mount free space, `"unlimited"`, or false for unknown. `power` is false for a computer with no fuel API. A turtle reports numeric `fuel` and `limit` or `"unlimited"`. Missing turtle fuel evidence is unknown and ineligible.

Checks occur every 5000 ms with a 2000 ms response deadline. A durable ring stores the last 240 outcomes and boots. `window` and `bootChanges` are derived from that ring. A new boot resets the qualifying window and invalidates holder acknowledgements. `score=ok/sent`, or zero when sent is zero. These constants are policy, not measured reachability.

Eligibility requires 240 checks, score at least 0.95, the last three checks successful, a reply and capacity report no older than 15000 ms, and no boot change in the window. A fuelled turtle also needs fuel at least `max(1000,ceil(0.1*limit))`. Unlimited fuel passes. A computer without a fuel API is exempt from the fuel test. Enrollment and reserves must be valid. Unknown capacity fails. Unlimited capacity still needs a finite operator quota. A capacity failure also includes used above quota, no remaining allocation, or insufficient reported free bytes for one proposed replica after future reserves. An offline-lease miner is always excluded.

`why=false` means eligible. Otherwise it is the first failing reason in this order, `not_enrolled`, `lease`, `boot`, `warming`, `stale`, `reachability`, `power`, `capacity`. Candidate priority is store and warehouse, then stationary computer roles, then miner extras. Within a class, sort descending by `min(quota-used,freeReported-reserves)` and then ascending computer ID. Unlimited free space contributes the remaining finite quota. Reserves here count additional bytes needed for control, the admitted navigation and journal peaks, and update staging, after subtracting bytes already charged as used. Existing code is not subtracted from reported free space twice. No movement or stationarity bonus changes score.

## 2.5 Lease v2

```lua
access = { pose = pos, side = "front" }
lease = {
	v = 2, id = "7:mine:1234", turtle = 17, boot = "<turtle boot>", epoch = "7",
	issuedAt = 0, untilAt = 0, issuedRev = 812, frame = "abs",
	area = { min = pos, max = pos }, corridor = { pos, pos },
	dropoff = access, charger = access, home = pos,
	settings = { revision = 4, values = {} }, fuelReserve = 120,
	mac = "<keyed BLAKE3 hex>",
}
```

`access.pose` is the standing cell. Its side is `front`, `top`, or `bottom` relative to that heading. Dropoff or charger may be false only when the job has no need for it. All positions share one frame, yAbs convention, and dimension. Bounds are inclusive and ordered. Corridor cells are distinct, observed clear, face-adjacent, ordered toward home, and at most 256. Their repeated use of `pos` above is notation, not valid repeated coordinates.

SSOT issues a unique lease to its authenticated turtle, boot, and current epoch. `issuedAt < untilAt` and `issuedRev <= currentRev` are required. The epoch is an opaque generation string. Implementations mint it as `<authority.epoch>:<durable server boot counter>`. Old examples such as `7` are placeholders. Neither counter resets on code rollback.

The holder owns the area and corridor exclusively. SSOT's occupancy check includes them and planner intents. Offline actions need certain position, journal space, adequate return fuel, and a valid grant. Excavation is limited to the area. Corridor movement cannot dig. Settings are an effective W1 snapshot, not arbitrary caller options. `fuelReserve` uses measured move costs and return policy. P0 measured a cost of one fuel per successful move only when charging and upgrade regeneration were both absent. The recorded bounds name that case. Any other fuel change disables fuel-only recovery. At expiry no move or dig occurs until renewal or a return grant.

Lease MAC is `hex(blake3.digestKeyed(Kpair,B("cc-h4/lease/2",leaseWithoutMac),32))`. The complete record is authenticated, including settings and all positions. A valid MAC does not renew time or override fencing. A changed turtle boot requires reconciliation. A server restart cannot instantly stop an offline turtle. Old reservations stay unavailable to other owners until expiry or acknowledged surrender, even when the server has a newer epoch.

A return-only grant is a separate named record.

```lua
returnGrant = {
	v = 1, id = "return:4:9", turtle = 17, boot = "<current boot>", epoch = "<current epoch>",
	lease = "7:mine:1234", issuedAt = 0, untilAt = 0, issuedRev = 900,
	frame = "abs", corridor = { pos, pos }, home = pos, fuelReserve = 120,
	mac = "<keyed BLAKE3 hex>",
}
```

Its corridor starts at the reconciled current cell and ends at home. It has at most 256 distinct adjacent observed-clear cells. SSOT checks every reservation and current occupant. It authorizes walking and turns along that corridor only, never digging, new work, or journal deletion. Its MAC uses domain `cc-h4/return/1` and Kpair over the record without mac. An obstructed or conflicting route receives no grant. Renewal creates a new immutable ID and explicitly supersedes the old grant after the turtle acknowledges the replacement.

`lease-reconcile` takes `{lease,oldBoot,newBoot,head,pose,pending}`. `pending` is false or the complete unresolved intent with recovery evidence. It returns `{resolved,pose,acked,grant}`, with grant false or a complete new lease or return grant. SSOT validates the old signed lease and saved journal, resolves evidence, and commits old-boot fencing before issuing a grant. Unresolved evidence returns `resolved=false`, a lost pose, and no grant. Reconciliation itself permits no movement. Journal recovery may report old-boot facts through a new authenticated session without inheriting old movement authority.

## 2.6 Journal entry, recovery, and replay

```lua
entry = {
	v = 1, seq = 41, lease = "7:mine:1234", at = 0, frame = "abs",
	kind = "move", phase = "intent", from = pos, to = pos,
	fuelBefore = 1800, cell = false, name = false, count = 0,
	evidence = {
		boot = "<turtle boot>", from = {}, to = {}, after = {}, localFaces = {}, recovery = false,
		fuelAfter = false, moveCost = false, charging = "unknown", regeneration = "unknown",
		ok = false, reason = false, item = false, anchor = false,
	},
}
journalHead = {
	v = 1, lease = "7:mine:1234", committed = 41, acked = 30,
	bytes = 18000, budget = 90000, probe = false,
}
```

All original entry fields remain. `evidence` is the explicit P0 extension for information the accepted N1 and B1 rules require. Its from, to, and after fingerprint fields are sparse six-direction maps. localFaces maps front, back, left, right, top, and bottom to observed block names during recovery. Missing faces remain unknown. `boot` identifies the physical-action boot. `charging` and `regeneration` are each `none`, `possible`, or `unknown`. Fuel recovery requires both to be `none`. P0 measured starbound regeneration masking successful moves even without a charger. `moveCost` is false or a positive measured fuel cost. `fuelAfter` is false, numeric, or `"unlimited"`. `ok` is false in intent and a boolean result in done. `reason` is false or a stable error code of at most 64 bytes. `item` and `anchor` use the exact types below or false. Unused fingerprints are empty dictionaries. Recovery is false or {boot,method}, with method fuel, fingerprint, or typed. It identifies a later boot that resolved an old action. No arbitrary evidence fields are accepted.

`kind` is `move`, `turn`, `dig`, `observe`, `item`, `problem`, `boot`, or `anchor`. Every kind has an intent and done phase sharing one sequence. The writer saves intent before its physical action or observation. It saves done afterwards. A failed physical action still has a done result with `ok=false`. Original fields that do not apply are false, with `count=0`. Done repeats the action operands. `at` is phase UTC, not the time the server received the record.

| Kind | Required operands and result |
| --- | --- |
| `move` | `from` and adjacent `to` preserve heading. `fuelBefore`, intent endpoint fingerprints, and done `after`, `fuelAfter`, and `ok` are required. A successful move observes the vacated and entered cells as air. A failure leaves pose at from. |
| `turn` | Same coordinates in from and to, heading changes by one quarter turn. Endpoint fingerprints and done after fingerprint are required. Two quarter turns are two actions. No fuel inference resolves a turn. |
| `dig` | `from=to` is the standing pose. `cell` is a face neighbour and `name` the inspected pre-dig block. Done `after` contains the re-inspected target face. Success without a verified air result does not record air. `count=0`. |
| `observe` | `from=to` is the observing pose. `cell` is that cell or a face neighbour. `name` is the observed block, including explicit air. Done requires `ok=true`. Intent can have `name=false` before inspection. |
| `item` | `from=to` is the standing pose. `cell` is the accessed inventory block or false for an internal fuel action. `name` is the item ID. `count` is the actual nonnegative transferred quantity on done and zero on intent. Item evidence below is required. |
| `problem` | `from=to` is the current pose. `reason` is required. Done records the state transition and performs no implicit movement. |
| `boot` | `from` is the saved pose or false. `to` is the recovered pose or false. Done after fingerprint and reason state the recovery result. Missing position is lost. |
| `anchor` | `from` is the old pose or false and `to` the proposed pose. Anchor evidence is required. Done is successful only after the authority accepts that evidence. |

Item evidence is `{action,slot,nbt,before,after,receipt}`. `action` is `collect`, `dropoff`, `fuel`, or `trash`. Slot is 1 through 16, NBT is false or the API's bounded opaque identifier, before and after are observed counts, and receipt is false or a server inventory receipt ID. Collect requires `after-before=count`. Other actions require `before-after=count`. A dropoff without a destination receipt is an observation, not an increase in delivered stock. A retry never repeats an already completed transfer.

Anchor evidence is `{source,reference,faces}`. Source is `typed`, `neighbour`, `gps`, or `radio`. Reference is a server-issued anchor-evidence ID of at most 64 bytes. Faces is the observed fingerprint. SSOT records the typed operator confirmation or authenticated sensor evidence behind that ID. An untrusted position or a source label cannot substitute for it.

A physical action requires intent and done to fit before intent is saved. Each encoded phase is at most 8192 bytes. Journal disk framing is ASCII `H4J`, byte `01`, followed by records `U32(#C(entry))`, `C(entry)`, and `sha256.digest(B("cc-h4/journal-entry/1",entry))`. An incomplete final record is an uncommitted tail. Any earlier hash or decoding failure stops recovery without skipping records. An action whose done cannot be saved remains unresolved and cannot be repeated blindly.

Only one ordinary action may be unresolved. A recovery inspection can turn in place without moving to another cell. Before probing, it saves journalHead.probe={boot,phase="intent"}. It inspects local faces, completes all four quarter turns back to the starting orientation, and saves probe={boot,phase="done"} with localFaces before resolution. A reboot with probe still at intent cannot infer its heading and requires a trusted anchor. Probe is cleared only when the recovered pose is durable. This exception permits inspection turns only, never digging, translation, or inventory changes. `committed` is the highest contiguous done sequence. `acked` is the highest contiguous server-accepted prefix whose acknowledgement the turtle has saved. Thus `0 <= acked <= committed`. `bytes` counts retained encoded phases and the file header. `budget` comes from free space after code, navigation, update, and control reserves. The 90000 example is not a default. At 80% the miner starts no new work and returns while authorized. Before starting a lease it reserves enough journal bytes for the complete return corridor, turns, and one recovery record. If that reserve cannot fit, no offline lease starts. Full journals never discard unacknowledged entries.

Before a mining lease exists, N1 uses a locally unique journal ID `local:<computer>:<durable counter>`. This is not a lease. It permits only boot, anchor, problem, and authenticated observation records. It cannot authorize movement, digging, or inventory effects.

### Replay identity and time

Replay identity is `(turtle,lease,seq,phase)`. Turtle ID comes from the authenticated transport. Intent and done are successive phases, not conflicting duplicates. SSOT stores each accepted phase's SHA-256 digest and result outside the ordinary eight-request cache. Exact duplicates return that result. Changed duplicates fail. Gaps cannot advance the acknowledgement. Done without its durable intent fails.

A replay object is `{v=1,turtle,lease,entries}` with entries ordered by sequence and intent before done. Its reply is `{lease,acked,results}`, where each result is `{seq,status}` and status is `applied`, `conflict`, or `duplicate`. Results and observation provenance commit before reply. The turtle saves the returned prefix before truncation. Failed authentication, malformed evidence, or future timestamps do not advance it.

An observation's own-lease priority is judged at its done `at`, not at reconnect time. To receive owned priority, the full action must satisfy `issuedAt <= intent.at <= done.at < untilAt`, the historical boot and grant, and its spatial permissions. A recovered completion has its actual recovery UTC and recovery boot. It may finish an old intent after expiry but receives no historical owned priority unless the timing is independently proved by a previously durable done. It cannot invent a pre-expiry timestamp or authorize another action. The server requires phase times to be nondecreasing within a journal and no later than receipt UTC. There is no future-time grace interval because the computers share one JVM clock. Closed, revoked-with-acknowledgement, and superseded grants retain their historical intervals for replay. Expiry at replay does not erase valid earlier observations or authorize new movement.

A fact that contains both owned and outside cells splits into two records with the same ID and revision but different `owned` values. Facts sort by `C({id=id,owned=owned})`. Per-action bytes remain protected by the phase digest. Conflicting historical leases that claim simultaneous exclusive ownership indicate invalid authority state. Their overlap becomes unknown and quarantined instead of selecting an issuer by arrival order.

### Deterministic materialization

The accepted plan's own-lease rule and section-revision rule apply to retained evidence, not just the mutable cell produced by the last packet. This P0 clarification is needed for the required opposite-arrival-order result.

For each cell, materialization uses the pre-replay seed, all unsealed facts, and persistent conflict markers. The following order is normative.

1. Within one turtle and lease, keep the greatest sequence that observes this cell. Older facts remain available for replay validation but do not compete for the current material.
2. If valid owned observations remain, choose the greatest tuple `(at,turtle,seq)`. All three comparisons are ascending, so the greatest wins. If the full tuple ties across different leases, identical materials coalesce and differing materials become a retained conflict. Array order never breaks that tie. A fresh server-authorized online observation competes in this set. The selected owned observation can clear a conflict. Outside observations cannot override it.
3. With no owned observation, discard a contender that another contender causally supersedes. Causal supersession requires the newer contender's `issuedRev` to be at least the older fact's accepted `rev`. A fact can only cite a revision already committed before its lease was issued. Cycles fail validation.
4. A retained conflict marker prevents the unknown-cell exception. With no prior conflict, a never-observed seed cell and exactly one remaining contender accept that contender even when unrelated section revisions advanced.
5. Otherwise every remaining contender must pass the revision test. Compare its `issuedRev` with the seed section revision and the accepted revisions of other independent facts in that section. Same-turtle, same-lease predecessors do not count as independent changes. If any compared revision is greater, the cell becomes unknown and records the greatest conflicting revision. If all pass, the greatest `(at,turtle,seq)` wins.

Every newly accepted fact recomputes affected earlier contenders as well as its own cells. Thus two concurrent outside observations against a known stale section end unknown in either arrival order. A single observation of a genuinely never-observed cell can still apply. Conflict unknown and never-observed unknown are different durable states. A replay-induced conflict is recomputed from the seed and complete fact set. It is not fed back as a new seed until compaction. This prevents a transient conflict from changing the opposite-order result.

An accepted fact's `rev` is its durable SSOT revision. Replay permutations must preserve causal edges recorded in `issuedRev`; a lease cannot have been issued from a future result. With the same issuance history, independent post-issuance revisions all exceed those issuedRev values, so their relative arrival order does not change the predicate. Section revision numbers and file hashes can differ between runs. The required identical result is the cell material and confidence map, reservations, and delivered facts.

`lease-close` takes `{lease,lastSeq}` after the turtle has saved `acked=committed=lastSeq` and surrendered movement authority. SSOT seals that sequence prefix and saves the close result. Repeating close is a no-op. Later new entries for that lease fail. This is the explicit compaction boundary. An abandoned journal remains quarantined until operator reconciliation. Expiry alone cannot silently discard it.

## 2.7 Storage policy, ledger, and forgetting

```lua
storagePolicy = {
	v = 1, mode = "ask", warnAt = 0.8, forgetOlderThanMs = false,
	controlReserve = 65536,
}
ledger = {
	v = 1, localTotal = 0, localUsed = 0, peerTotal = 0, peerUsed = 0,
	growthPerHour = 0, state = "ok",
}
forgetPreview = {
	v = 1, id = "p:812:3", createdAt = 0, untilAt = 0,
	olderThanMs = 0, rev = 812,
	items = { { key = "<section key>", rev = 640, hash = "<section hash>", bytes = 1200 } },
	bytes = 1200,
}
```

W1 owns the setting registry. H4c owns policy application. Modes are `ask`, `expand`, `forget-old`, and `hybrid`. Ask is the default. Expand uses peers without forgetting. Forget-old needs the player's explicit saved consent to an age rule. Hybrid uses eligible peer space before that consented rule. A false age threshold grants no forgetting permission. `warnAt` is greater than zero and at most one. Control reserve cannot fund map growth.

`localTotal` is a finite mount capacity, `"unlimited"`, or false if unavailable. `localUsed` is charged bytes or false if unmeasurable. A finite used value comes from capacity minus reported free bytes on the same mount, including code, files, directories, and both save slots. If both APIs are unlimited, used comes from a complete allocation-aware inventory or remains false. Unknown values never become zero. Unlimited capacity suppresses a ratio warning but does not suppress failed-write handling or finite quotas.

Peer totals sum finite enrolled quotas and their charged usage, including unreachable enrolled peers. They do not imply availability or unique logical bytes. Admission checks current eligible free space separately. Runtime accounting samples every 60000 ms. Growth is `max(0,usedNow-usedThen)*3600000/elapsedMs` over the latest samples at least 60000 ms apart. Before two valid samples, or after a clock discontinuity, growth is false. The ledger keeps sample times in its enclosing control metadata.

State is `ok`, `warn`, or `paused`. Unknown capacity or a failed admission pauses new map growth. A finite used ratio at warnAt prompts the player and pauses map growth until policy resolves it. Control writes continue from their reserve. Turtles keep rejected observations durably in bounded local buffers. A full buffer stops new mining and returns only while authorized. RAM is never a durability acknowledgement.

Preview TTL is 120000 ms. The preview is immutable and keys sort by byte order. Its cutoff is `createdAt-olderThanMs`. A section qualifies only when its observedAt is nonzero and strictly before the cutoff and it has no active grant, unsealed evidence, or control dependency. An unknown historical timestamp cannot prove that data meets an age rule. Items name exact key, revision, hash, and complete section-file bytes. Top-level bytes is their sum. The plan's zero total beside a 1200-byte item is corrected notation.

Commit names the preview ID and requires unexpired operator consent or the saved matching policy. Each still-matching revision and hash is deleted independently. Changed items survive and are returned as skipped. This overrides the older whole-preview stale rejection. Before local deletion, the writer commits forgetTombstone={v=1,key=key,throughRev=commitRev,prior={rev=rev,hash=hash},at=now,peers={}}. Peers is the sorted array of holder IDs that must drop the exact prior blob. The directory retains this control record and each pending drop acknowledgement. Unreachable peers remove that exact old blob when they reconnect. They cannot resurrect it. Forgetting removes the section's observations and coverage projection. The tombstone also masks baseline prediction and old region geometry for that section, so forgotten cells are unknown. Fresh authorized observations with revisions above throughRev can supply individual cells again. Unobserved cells stay masked. Old replica bytes, sealed journals, and pre-forget evidence cannot clear the tombstone. Identity, lease, replay, pose, and unacknowledged journal state cannot be preview items.

## 2.8 Install reducer

All front ends call `transition(state,event) -> state,effects`. The core has no terminal, peripheral, rednet, filesystem, clock, or random calls. The shell supplies those results. Keyboard and touch differ only in rendering and hit testing.

This enrollment reducer starts after an authority exists. Creating the first authority uses trusted local setup and a locally trusted bootstrap release. Fresh selects an independently configured role under that authority. Installing a hub or server role never activates a second authority by itself.

```lua
install = {
	v = 1, step = "detect",
	machine = { kind = "turtle", advanced = false, id = 31, label = false, sides = {} },
	source = false, role = false, enrol = false, pos = false, files = false,
	error = false, history = {},
	nextEffect = 1, pending = false, candidate = false, roles = {}, inputMode = false,
}
installError = { code = "code_expired", retry = "enter_code", detail = "" }
installPeripheral = { types = { "computer", "turtle" }, id = 17 }
installFile = { path = "startup.lua", release = "<release id>", bytes = 600, sha256 = "<hash>" }
installEnrolment = {
	claim = false, role = "miner", manifest = "<manifest id>",
	handle = "<private shell handle>", server = 4, claimed = false,
	settings = { revision = 4, values = {} }, planBot = false, home = pos, candidate = false,
}
```

Steps remain `detect`, `source`, `enter_code`, `neighbour`, `role`, `position`, `facing`, `review`, `fetch`, `pair`, `done`, and `error`. Sources are false, `code`, `neighbour`, and `fresh`. Machine kinds are `computer`, `turtle`, and `pocket`. Advanced means colour-terminal support. Label is false or at most 64 display bytes. Sides map local side names to peripheral records. Type arrays contain distinct sorted names. Missing computer ID is false.

The added reducer fields provide effect correlation and a heading-free position candidate. `nextEffect` increases without reuse. Pending is false or `{id,op,call,args,successStep}`. Call is false except for RPC. Args are the typed operands below, except that pending state replaces codeInput with false. The first hello effect alone carries the entered code text. Its handle is install:<machine id>:<nextEffect>. The shell durably saves the next reducer state and that private attempt before sending. Retry uses the same handle and codeInput=false. nextEffect survives restart. The shell owns code text, private keys, and nonces outside public state. The handle is an opaque local reference to that private material. `claim` is false before proof construction and otherwise the public enrolClaim. No key appears in it.

A candidate is `{frame,yAbs,dim,x,y,z,h,src,anchoredAt,conf}`. It has the position field types except that h can be false. It is not a pos and cannot enter navigation or SSOT as one. GPS returns h=false and conf=suspect. The facing step supplies h. GPS alone never proves heading. A typed anchor needs explicit operator confirmation. A relative candidate gets a registered frame before pair completion. inputMode is false, absolute, or relative and selects the position text grammar. An authenticated hello can supply a planned candidate. A changed facing invalidates a neighbour fingerprint proof and requires a new proof or explicit typed-anchor confirmation before certainty.

Roles is a sorted array of at most 32 compatible role IDs from the trusted bootstrap catalogue or authenticated manifest. Files is false until the signed role manifest is verified, then at most 256 installFile entries in manifest path order. History has at most 12 editable-step snapshots with no nested history or pending effects. It never restores older claimed state, bundle activation, counters, or keys.

### Events and effects

The accepted event and effect tags remain. P0 supplies their operands and result types.

```lua
installEvents = {
	{ t = "choose", n = 2 },
	{ t = "text", s = "" },
	{ t = "back" }, { t = "retry" },
	{ t = "io", id = 1, op = "gps", ok = true, value = {} },
	{ t = "timer", id = 1, at = 1792500000000 },
}
installEffects = {
	{ id = 1, op = "scan", args = {} },
	{ id = 2, op = "gps", args = { timeoutMs = 2000 } },
	{ id = 3, op = "rpc", call = "enrol-hello", args = {} },
	{ id = 4, op = "apply_bundle", files = {}, args = {} },
	{ id = 5, op = "write_cfg", args = {} },
	{ id = 6, op = "reboot", args = {} },
}
```

Empty tables above are notation. The typed operands below are required before dispatch. The core emits at most one pending effect. Every completion matches both id and op. A stale completion is ignored. A pending RPC also pins call and its private attempt handle. A timer has the same pending ID and an externally supplied UTC. Timer ID zero initializes detect exactly once. A timer never guesses completion or success. Timed-out work enters error with the same durable attempt available for retry.

Text is at most 256 bytes. Invalid choices and malformed input return `invalid_input` with the current editable step as retry and emit no effect. Failures carry installError, with a stable code, a valid retry step, and secret-free detail. Help is a fixed lookup by code. Error choice 1 retries, 2 goes back, and 3 displays that help without an effect. A failure cannot advance to done.

| Effect | Exact operands | Successful `io.value` |
| --- | --- | --- |
| `scan` | Empty args. | `{machine,roles}`. Roles come from the trusted bootstrap catalogue. |
| `gps` | `{timeoutMs=2000}`. | Candidate with measured coordinates, configured dimension, h=false, src=gps, and conf=suspect. Failure to know dimension fails this effect. |
| `rpc`, `neighbour-check` | `{id,side,neighbour}` for this new machine and its selected adjacent ID. | `{candidate,neighbour,side,codeRequired=true}` after paired-neighbour confirmation. |
| `rpc`, `enrol-hello` | `{handle,source,role,codeInput,neighbour}`. Role or neighbour can be false. CodeInput is local shell input only, or false on a retry using its saved handle. | installEnrolment with a private handle and authenticated proposal metadata. The shell never sends codeInput on the wire. |
| `rpc`, `enrol-claim` | `{handle,pos,role,planBot}`. | installEnrolment with claimed=true, the final role, settings, home, and manifest. The shell durably saves Kpair before success. |
| `apply_bundle` | `files` plus args `{handle,manifest,role}`. | `{release,manifest,files,ready=true}` after signed-manifest verification, all hashes, staging, and recoverable activation preparation. |
| `write_cfg` | `{handle,server,role,pos,home,settings,manifest}`. | `{saved=true,release}` after configuration and generation selection are durable. |
| `reboot` | `{release}`. | No completion is required. The new boot verifies the selected generation. |

On first bundle fetch, apply_bundle.files is empty. The shell fetches the immutable manifest named by args.manifest, verifies it, resolves the complete signed role file set, and returns that set in value.files. A nonempty files operand on retry must equal that complete set exactly. The core stores value.files before write_cfg. The shell completes the authenticated hello negotiation for the new session before downloads.

The shell expands reducer RPC operands into the exact authenticated protocol below. It derives codeInput and ephemeral material outside the core, retains them in the private attempt journal, and passes only the handle back. Local shell operands are not permission to append arbitrary wire fields.

### Transition rules

The following choice order is fixed across keyboard and touch.

| Step | Input and next state |
| --- | --- |
| `detect` | Initial timer zero emits scan. Success stores machine and roles and enters source. |
| `source` | Choice 1 is code, 2 neighbour, 3 fresh. Code enters enter_code. Neighbour enters neighbour. Fresh enters role. |
| `neighbour` | Choices are discovered adjacent computers in side order front, back, left, right, top, bottom. Selection emits neighbour-check. Success retains the candidate and enters enter_code for the code displayed by that neighbour. |
| `role` | Choice selects the indexed compatible role. Fresh enters enter_code and needs a code issued for that role by a trusted authority console. Other flows enter position. Fresh never bypasses enrollment. |
| `enter_code` | Text emits enrol-hello. Success pins its metadata. A fixed inherited role proceeds to position. Otherwise it enters role. The shell redacts code text from logs and history. |
| `position` | Choice 1 confirms an authenticated planned candidate or a certain neighbour candidate when one exists. A planned candidate can remain suspect until claim verification. Choice 2 sets inputMode=absolute and waits for text. Choice 3 sets inputMode=relative and waits for text. Choice 4 requests optional GPS. All successful candidates proceed to facing. |
| `facing` | Choices 1 through 4 are east, south, west, north. A previously proved heading is offered preselected, never silently replaced. Selection builds pos and enters review. |
| `review` | Choice 1 confirms and emits enrol-claim, entering pair. Choice 2 goes back. No code use or physical work occurs merely on reaching review. |
| `pair` | Successful claim stores durable enrollment and emits apply_bundle, entering fetch. Lost replies retry the same attempt. Back is disabled while claim outcome is unresolved. |
| `fetch` | Successful apply_bundle emits write_cfg. Successful write_cfg enters done. Disk or hash failures retain the claimed enrollment for retry. |
| `done` | Choice 1 emits reboot. No automatic move or dig is an installer effect. |
| `error` | Retry reissues the failed operation with a new effect ID but the same durable protocol attempt where required. Back follows editable history only. |

Position choice 2 parses exactly `dimension x y z`, with whitespace-separated signed decimal integers. Choice 3 parses either `relative` or `relative y`. It sets local x=z=0, with y=0 and yAbs=false for the first form, or the typed world y and yAbs=true for the second. The shell reserves frame ID `f:<id>:<durable counter>` and registers it through the authenticated claim. In code flows an inherited frame is preserved unless the operator explicitly selects an absolute anchor and SSOT accepts its transform. GPS timeout returns to position and offers typed entry, neighbour setup, or instructions for optional gpshost setup. It never blocks installation in this no-GPS world.

Back invalidates read-only pending effects by ID and restores the preceding editable snapshot. It cannot cancel an uncertain claim, undo code consumption, or roll back installed state. After claim, only position correction through a new authenticated anchor and bundle/configuration retries remain. The shell's private install journal makes apply_bundle and write_cfg idempotent across crashes. Keyboard screens fit 39 by 13. Pocket renderers can scroll content but cannot omit a choice.

## 2.9 Copy code and enrolment

```lua
copyCode = {
	v = 1, code = "K7Q2M9XDPT", issuer = 17, issuedAt = 0, untilAt = 0,
	role = "miner", settingsRef = { revision = 4 }, devToggles = {},
	filesRef = { manifest = "<immutable manifest hash>", role = "miner" },
	frame = "abs", home = pos, used = false, attempts = 0, planBot = false,
}
enrolClaim = {
	v = 1, id = 31, server = 4,
	newPub = "<32 raw bytes>", serverPub = "<32 raw bytes>",
	nNew = "<16 raw bytes>", nServer = "<16 raw bytes>",
	proof = "<64 lowercase hex digits>",
}
```

This restores issuedAt and untilAt from the plan's swallowed inline comment. SSOT owns the code. Issuer is the paired machine that requested it. Ordinary TTL is 120000 ms. Planner TTL is 900000 ms. Codes have one successful use and burn after five distinct failed attempts under the rules below. Used, burned, and expired codes cannot start another claim. SettingsRef pins the W1 snapshot. DevToggles is a validated registry override map. FilesRef selects an immutable signed manifest and matching role. PlanBot is false or the planned bot ID. Home agrees with frame.

A paired machine can request a copy of its own enrolled role and allowed settings. Only configured operators can select another role, issue planner codes, or change operator membership. Enrollment never derives privileges from a self-reported role or dev toggle. A valid pairing MAC authenticates a sender and does not make that sender an operator.

The alphabet, in numeric order 0 through 31, is `0123456789ABCDEFGHJKMNPQRSTVWXYZ`. It includes the plan's `9`. Input normalization removes ASCII spaces and hyphens and converts ASCII lowercase to uppercase. Every other character, including O, I, L, U, non-ASCII letters, and punctuation, is rejected. No letter aliases or Unicode normalization apply. Normalized length is exactly 10 for the X25519 profile or 16 for the fallback profile. Generate each character from five unbiased bits from ccryptolib random output. Never use `math.random` for codes.

Profile `x25519-blake3/1` uses 10 characters and ephemeral X25519. Profile `code80-blake3/1` uses 16 characters and the accepted code-derived fallback. In that profile both public-key fields are false, while the 16-byte nonces remain mandatory. The code record's enclosing private issuance metadata stores its profile, source, and any confirmed neighbour challenge and does not infer it from a peer's request. The implementation selects an available profile from P0's measured bounds and qualified entropy sources. X25519 public-key generation and exchange finished on CraftOS-PC and on Cobalt with no explicit yield and under the 7,000 ms bound, so this measurement keeps the 10-character profile. It does not select the 16-character fallback. A network error, timeout, or peer suggestion cannot downgrade a code. If neither profile has qualified randomness and bounded library operations, issuance stays disabled.

### Cryptographic functions and framing

The pinned API source is [tests/bench/vendor/source.json](../../tests/bench/vendor/source.json), commit `14489aa1ec408f8a07e1292be5ef91dfe8567c74`. H1H2 vendors those modules with their license. The contract composes only these ccryptolib exports.

| Operation | Exact API |
| --- | --- |
| SHA-256 | `sha256.digest(bytes)` returns 32 raw bytes. |
| Keyed MAC | `blake3.digestKeyed(key32,bytes,32)` returns 32 raw bytes. |
| KDF | `blake3.deriveKey(context)(material,32)` returns 32 raw bytes. The first call returns a function. |
| X25519 | `x25519.publicKey(secret32)` and `x25519.exchange(secret32,public32)`. |
| Manifest signature | `ed25519.sign(secret32,public32,bytes)` and `ed25519.verify(public32,bytes,signature64)`. |
| Randomness | A qualified initialization of `random`, then `random.random(length)`. |
| MAC comparison | `util.compare(expectedRaw32,receivedRaw32)` after strict hex and length validation. This vendor helper also requires initialized randomness. |

There is no handwritten HMAC, SHA, curve, random generator, or KDF. Byte framing is application code. `KD(context,value)` means exactly `blake3.deriveKey(context)(C(value),32)`. `MAC(key,domain,value)` means exactly `hex(blake3.digestKeyed(key,B(domain,value),32))`. Key material inside C is raw bytes. No delimiter concatenation stands in for a structured value.

Initialization success alone is not an entropy proof. The benchmark's public deterministic seed is never a deployment seed. A trusted locally provisioned random seed or a qualified hardware source can initialize the vendor generator. Timing-source availability and quality remain explicitly qualified by P0's evidence. The fallback also needs real random codes and nonces. No seed or pairing key travels over unencrypted radio.

X25519 uses the vendored standard x25519 module. Both inputs have exact lengths. An exchange error or all-zero 32-byte shared secret fails the claim. The zero-result check and MAC comparisons use vendored util.compare on equal-length raw strings. The caller does not implement a timing-sensitive early-return comparison. This contract does not substitute the different x25519c API or hand-code point arithmetic. Secret bytes and ephemeral keys are kept in private attempt storage and erased only after the resulting pairing state is durable or the attempt is permanently abandoned.

### Hello lookup and authenticated transcript

The public lookup tag is `hex(sha256.digest(B("cc-h4/code-tag/1",{code=normalizedCode})))`. It selects exactly one live code. Duplicate live tags are rejected at issuance and regenerated. A tag is not authorization. `Kcode=KD("cc-h4/code-key/1",{suite=suite,code=normalizedCode})`.

The new machine saves its private attempt, nonce, ephemeral secret, and boot before hello. Hello body is exactly `{id,server,suite,codeTag,newPub,nNew}`. It travels in the enrollment envelope defined below, MACed with Kcode. The server bounds input and looks up the tag before verifying the MAC or doing curve work. A valid repeat of the same hello returns the same pending challenge.

The hello reply body is `{claim,offer}`. Claim is exactly enrolClaim without proof. Offer is exactly `{suite,codeTag,source,role,settingsRef,devToggles,filesRef,frame,home,planBot,untilAt,manifestKey,authorityEpoch,serverBoot,candidate,neighbourProof}`. Source comes from private issuance metadata and is code, neighbour, or fresh. Candidate is false or the typed planned or neighbour candidate from section 2.8. NeighbourProof is false or the server-recorded reciprocal-check challenge. A hello cannot change these values by claiming a different source. ManifestKey is the 32-byte Ed25519 public key. The response MAC under Kcode authenticates both public keys, both nonces, both IDs, the key pin, and the proposal. The client requires its requested suite and a matching pre-existing pin, when one exists. Initial local code entry establishes the first pin. Discovery cannot replace an existing pin.

The server indexes its private pending attempt by `(id,nNew,nServer)`. It stores codeTag, both boots, the exact offer, the server ephemeral secret, and a deadline no later than `min(code.untilAt,helloAt+30000)`. There are at most four pending attempts per code and 32 total. Excess work returns busy. These are admission limits, not permission to erase an uncertain successful claim.

The claim request body is `{claim,selection}`. Selection is exactly `{pos,role,planBot,observed,anchor}` and is checked against the code, registry, and planner intent. Observed is false for a computer or {faces,peripherals} for a turtle. Faces is a six-direction fingerprint projected under the proposed heading. Peripherals maps local sides to distinct sorted type arrays. Anchor is false or the literal typed after the user explicitly confirms the displayed coordinates and heading. The claim effect shell obtains these observations with the bounded in-place inspection probe before transmission. SSOT derives confidence from the evidence, the bound neighbourProof, or that authorized typed confirmation. It never trusts selection.pos.conf by itself. A mismatched planned cell or facing fails before code use. Uniform evidence can complete installation as suspect but cannot verify or activate the planned bot. The transcript is exactly:

```lua
transcript = {
	suite = "x25519-blake3/1", codeTag = "<lookup tag>",
	claim = "<enrolClaim table without proof>",
	offer = "<exact hello offer table>", boot = "<new machine boot>",
	selection = { pos = pos, role = "miner", planBot = false, observed = false, anchor = "typed" },
}
```

The quoted table placeholders are actual tables in the encoding. Proof is `MAC(Kcode,"cc-h4/enrol-proof/1",transcript)`. It covers every accepted enrolClaim field preceding proof and all added negotiation and selection data. Server lookup comes from the pending nonces, not from scanning all codes or trusting the claimed ID alone.

For X25519, both endpoints compute `shared=x25519.exchange(ownSecret,otherPublic)` and `Kpair=KD("cc-h4/pair-x25519/1",{shared=shared,transcript=transcript})`. For fallback, `Kpair=KD("cc-h4/pair-code80/1",{code=normalizedCode,transcript=transcript})`. These field names, contexts, and nesting are exact. `Kconfirm=KD("cc-h4/enrol-confirm/1",{pair=Kpair,transcript=transcript})` protects the successful reply.

A captured proof is an offline verifier for code guesses. X25519 prevents a passive observer who later learns the code from deriving that session's pairing key without its ephemeral shared secret. It is not a password-authenticated key exchange and does not make code guessing impossible. The fallback exposes its long-term key to a successful offline code guess. This corrects the plan's broader statement that a sniffer gains nothing offline while preserving its chosen algorithms and code lengths.

### Commit, retries, and results

A failed proof-bearing hello, or a completed claim rejected for proof, authorization, role, or placement, increments the selected code's attempts once for that exact authenticated submission digest. Repeating the same failed submission does not consume another attempt. A corrected claim has new transcript bytes and counts as a new attempt if it fails. Malformed input that cannot identify a pending code is rejected without mutating any code. Five failures burn it. This extends the plan's failed-claim limit to the authenticated hello, so it cannot become an unlimited online guess endpoint.

An ordinary code cannot replace an already paired computer ID. Re-pairing needs an explicit local authority reset after existing grants and state are reconciled. Successful claim atomically marks used, binds the new computer and optional planBot, records the exact attempt and result, and installs the private Kpair reference. It commits before replying. A changed claim cannot reuse the consumed code. An exact retry returns the saved result even if the ordinary code TTL has since elapsed, but only for that successful attempt. It does not create a second pairing. The durable result is outside the eight-request cache.

Success body is exactly `{id,server,keyId,pairingGeneration,session,sessionGeneration,role,settings,frame,home,pos,manifest,manifestKey,planBot,authorityEpoch}`. Settings is `{revision,values}`. Manifest is its immutable unsigned-manifest hash. The first sessionGeneration is 1. The reply MAC uses Kconfirm. The client saves the verified result and private key before an install effect reports claimed=true. Interrupted bundle download retries from this pairing and never consumes another code.

Before the new machine has a code, neighbour-check is the only unauthenticated enrollment discovery operation. It uses the enrollment envelope with keyId=false, mac=false, counter=0, session=false, and a fresh bounded rid. It can request a reciprocal check but cannot register a pose, select a role, consume a code, or authorize work. Its response is only an untrusted candidate hint. The server sends an authenticated request to the already paired neighbour. It binds `{newId,neighbourId,newSide,neighbourSide,challenge}`. The server requires reciprocal getID observations and the neighbour's certain pose. The two side vectors determine the adjacent cell and heading. If heading remains ambiguous, a locally requested turn-and-inspect setup can prove it, but the installer never substitutes a guessed heading. After local confirmation, the neighbour displays an ordinary code for the same protocol. The authenticated hello offer must bind the saved neighbourProof and candidate before that hint gains authority. Fresh setup also obtains a console-issued code. Neither flow transmits private files from an adjacent computer.

## Authentication, sessions, and manifests

### V2 envelope

All paired request envelopes have exactly these fields.

```lua
request = {
	v = 2, wire = { major = 2, minor = 0 }, type = "ssot", expect = "ssot_reply",
	server = 4, sender = 17, target = 4,
	keyId = "pair:17:2", session = "session:17:9",
	rid = "<request id>", boot = "<client boot>", counter = 42,
	op = "lease-replay", body = {}, mac = "<64 lowercase hex digits>",
}
```

A reply has the same fields, with type=ssot_reply, expect=false, sender=server, target=client, and the request's rid, boot, counter, op, keyId, and session. Its body is `{ok=true,...operationResult}` or `{ok=false,error=code,detail=text}`. Operation result tables elsewhere in this reference name the fields beside this common ok field. Those tables do not authorize extra fields. Enrollment replies follow the same rule. Error codes do not carry secrets. A hint uses type=wh2_changed, expect=false, op=wh2-changed, the current session and boot, and its own increasing counter. Hints schedule authenticated reads and never cause movement or settings application.

Both `v=2` and `wire={major=2,minor=0}` are required. Each body ID, server ID, boot, keyId, and nonce-derived rid must agree with its envelope and pending context. Cross-field disagreement fails before mutation. Disagreement fails. The capability names are `canonicalWire=1`, `keyedBlake3=1`, `ed25519Manifest=1`, and `atomicBundle=1`, plus supported domain capabilities such as `traffic=1` and `wh2=1`. `hmacSha256` is obsolete. `ssot-hello` retains the wh2 hello payload fields and challenge echo, with these capability replacements. Missing required capability or an unsupported state schema returns incompatible. A failed negotiation never causes plaintext fallback. `requireMac` defaults false for rollout. When enabled, all v1 domain requests fail.

For direction request, reply, or hint, `Kdirection=KD("cc-h4/traffic-key/1",{pair=Kpair,server=server,client=client,keyId=keyId,session=session,direction=direction})`. Envelope mac is `MAC(Kdirection,"cc-h4/wire/2/"..direction,envelopeWithoutMac)`. All envelope fields are covered. The direction suffix is one of those three fixed words, not arbitrary input. Direct delivery also checks rednet sender. Relayed delivery uses the authenticated original identities and byte-for-byte inner packet.

Enrollment uses the same exact envelope shape with type=ssot_enrol or ssot_enrol_reply, expect set to the counterpart or false, session=false, counter=0, and keyId=codeTag. Its operations are enrol-hello and enrol-claim. Initial hello rid is hex(nNew), and claim rid is hex(nServer). Request and hello-reply MACs use Kcode with domains `cc-h4/enrol-wire/1/request` and `cc-h4/enrol-wire/1/reply`. A successful claim reply uses Kconfirm and domain `cc-h4/enrol-result/1`. Failed replies use Kcode and the enrollment reply domain. These control messages never pass the ordinary counter check. Unknown tags receive no authenticated success and cannot affect ordinary sessions.

### Replay and session rollover

New ordinary counters are from 1 through 2147483647 and at most 64 above the saved high-water mark. The client reserves a counter durably before sending. Retries use identical bytes. The last eight completed requests retain exact canonical request bytes and durable results. Exact retries return the result. Reused rid or counter with changed bytes fails. Evicted counters at or below the high-water mark fail. Invalid MACs, gaps, and huge counters never advance replay state. Domain mutation, counter, and result commit together.

Queue overflow returns busy and does not consume a counter. An authenticated busy response is transient and is not stored as an operation result. An unauthenticated congestion hint can cause a bounded retry only. It cannot complete a request. Client retries preserve the same rid, counter, and bytes.

Session-control key is `KD("cc-h4/session-key/1",{pair=Kpair,server=server,client=client,keyId=keyId})`. Control envelopes use type=ssot_session or ssot_session_reply, session=false, counter=0, and op=ssot-session. Request and reply MAC domains are `cc-h4/session/1/request` and `cc-h4/session/1/reply`.

At counter 2147483583, the client drains work and starts rollover before the final 64 values. Control also works when the local counter is lost or exhausted. The client saves a random 16-byte attemptId. Body `{stage="hello",attemptId,boot}` obtains `{stage="challenge",attemptId,serverChallenge,generation}` with a one-use 16-byte server challenge and current session generation. Body `{stage="commit",attemptId,serverChallenge,boot}` commits the next session and generation. Reply is `{stage="accepted",attemptId,serverChallenge,session,sessionGeneration}`. Session IDs are `session:<client>:<durable generation>`.

The challenge is durable and expires after 30000 ms. Only one current challenge per client exists. An exact hello retry returns it. A different attempt supersedes the old uncommitted challenge. Commit atomically fences the old session and saves counter zero, hint counter zero, and the accepted result. An accepted retry returns success only while that session remains current. Otherwise it returns superseded. The client rejects older generations and saves acceptance before counter one and ssot-hello. Reboot and code rollback cannot reopen old sessions. The server retains committed attemptId-to-generation tombstones for the pairing generation, so an old accepted attempt remains superseded after its reply leaves a small cache.

### Signed manifest and bundle activation

The signed object preserves the wh2 manifest fields and adds roles and signature.

```lua
manifest = {
	schema = 1, release = "<immutable release id>", server = 4,
	wire = { major = 2, minor = 0 }, stateSchema = 2,
	files = {
		{ path = "startup.lua", release = "<same release>", bytes = 600, sha256 = "<hash>" },
	},
	roles = { miner = { "startup.lua" } },
	signature = { alg = "ed25519", keyId = "<SHA-256 of public key>", bytes = "<128 hex characters>" },
}
```

`unsigned` is this table with signature omitted. Manifest ID is `hex(sha256.digest(B("cc-h4/manifest/1",unsigned)))`. Signature bytes are `hex(ed25519.sign(serverSecret,serverPublic,B("cc-h4/manifest/1",unsigned)))`. KeyId is SHA-256 of the raw pinned public key. Clients call the vendored verifier on that exact preimage and decoded signature. The server signs once and persists that immutable signed object. The vendor signer may randomize signatures. Re-signing is not how manifest identity is calculated.

Files sort by path. Role arrays sort by path and contain the complete transitive file set for the role. Entries use one release. Paths are normalized relative allowlisted paths without empty components, dot components, traversal, drive prefixes, or backslashes. Duplicate paths, missing dependencies, incorrect sizes, mixed releases, and incompatible schemas fail. A file hash proves content integrity, not authorization. An authenticated download reply protects transport and does not replace the Ed25519 signature.

The updater stages the full role generation, verifies signature, byte counts, SHA-256 hashes, and Lua syntax, then records readiness. Activation selects a complete generation through a recoverable journal. Boot sees either the previous complete generation or the new complete generation. Unused role code is pruned only after the selected generation is durable and rollback requirements are met. No credentials, journals, or shared state are pruned as role code. Rollback requires code that can read the current state schema and never restores older authority, counters, sessions, movement facts, or inventory receipts.

### Bounded cryptography

No ccryptolib call is inserted inside H3 handle or save. The single worker prepares hashes, verifies MACs, and prepares immutable file bytes before entering its transaction. Crypto workers return only checked results with immutable pins. They cannot mutate SSOT. Publication and replay commit remain serialized and non-yielding.

The vendored API is one-shot. Yielding between calls does not make one oversized call safe. Each runtime profile has a P0-qualified maximum input size per operation. A request above that tested bound returns too_large before hashing. A profile without a demonstrated bounded call stays disabled. Large object support therefore does not imply that the current vendor can hash its maximum size within the watchdog. Changing the limit requires real evidence, not a handwritten incremental hash or yields inside SSOT. Ed25519 signing and verification, curve work, randomness, and baseline-file hashing follow the same rule. This resolves work placement while keeping runtime limits tied to recorded measurements.

## 5b. Planner records and placement

```lua
plan = {
	v = 1, id = "p:4:17", frame = "abs", dim = "minecraft:overworld",
	y = 64, name = "Base", rev = 3,
	areas = { { id = "p:4:18", kind = "base", min = pos, max = pos } },
	fixtures = { "p:4:19" }, bots = { "p:4:20" },
}
plannedFixture = {
	v = 1, id = "p:4:19", plan = "p:4:17", kind = "chest",
	pos = pos, side = "front", state = "planned", layoutId = false,
}
plannedBot = {
	v = 1, id = "p:4:20", plan = "p:4:17", role = "miner", pos = pos,
	settings = { revision = 4, overrides = {} }, devToggles = {},
	jobArea = { min = pos, max = pos },
	expect = { neighbours = { [2] = "minecraft:chest" }, peripherals = { back = "inventory" } },
	state = "planned", code = false, computerId = false,
}
authority = {
	v = 1, holder = 4, epoch = 2, since = 0, kind = "hub",
	state = "active", handover = false,
}
```

Plan, area, fixture, and bot IDs use `p:<origin computer>:<durable counter>`. Each origin shares one counter across these records. IDs survive handover. Fixtures and bots are distinct referenced IDs, not embedded copies. All positions share the parent plan's frame and dimension. Areas and job areas use inclusive ordered bounds. The only area kind in this version is base. Plan y is the display level and need not equal every fixture's y. Name is at most 64 display bytes. Every accepted edit advances rev.

Fixture kinds are chest, dropoff, charger, and furnace. States are planned, verified, active, and retired. Fixture pos is its block cell. Its h is the heading of the accessing turtle. For front access, standing cell is `fixture.pos - headingVector(h)`. For top access, it is the fixture cell minus one in y. For bottom access, it is the fixture cell plus one in y. The standing pose retains h. The side always describes the turtle API side. It does not describe the chest's model orientation. Verification requires a clear standing cell and an observed matching fixture at that side before publishing one wh2 layout location. LayoutId is false before publication and that location's ID afterwards.

Bot pos is its standing cell and heading. Role is in the signed manifest. Settings revision pins the registry. Overrides and devToggles contain only allowed registry keys. Expect.neighbours uses the six direction numbers above. An omitted face is unknown, never air. Expect.peripherals maps front, back, left, right, top, or bottom to a required peripheral type. Actual peripheral type lists may have additional types.

Bot states are planned, code-issued, claimed, verified, active, and retired. Code is false or the copyCode.code reference and is visible only to the authorized setup flow. ComputerId is false before claim. Claim commits code use, computer binding, and conversion of the bot intent to the existing sync pose in one transaction. Planned bot and fixture cells reserve intent holds. Intents block other turtles but prove neither occupancy nor observed air.

Placement checks inspect all six faces, restoring the starting heading after the inspection turns, and read adjacent peripheral types. An expected mismatch returns wrong_placement. Matching alone is insufficient in uniform surroundings. Fingerprint-only certainty requires at least one observed non-air landmark and a unique match among the 27 cells within one block of the planned cell and their four headings. An alternative with insufficient observations remains possible, so it prevents uniqueness. Otherwise the result stays suspect until a reciprocal neighbour check or a typed anchor confirms it. Identical distant surroundings remain a stated limitation of fingerprint-only evidence. No suspect bot digs.

Retiring a plan releases its intents in one revision. It cannot erase real occupancy, active physical work, or delivered inventory. Verified fixtures enter the existing wh2 registry. No second dropoff or charger registry is introduced.

### Planner events and AR cells

```lua
plannerEvents = {
	{ t = "place", kind = "chest", at = lookHit },
	{ t = "place", kind = "bot", role = "miner", at = feet, h = 3 },
	{ t = "level", y = 64 }, { t = "confirm" }, { t = "undo" },
}
```

The pure planner stages one draft placement. Place updates that draft. Confirm emits one plan-intent operation with the expected plan revision. Undo removes the draft or requests retirement of the most recent unclaimed intent. It never reverses a physical action or a claimed bot. A stale revision reloads the plan before retry. Level changes only the display level. Relative level text is resolved to an integer before the event. T1 has one base area, one chest, and one miner on one level. T2 can add roles and fixtures through the same records.

`feet` is the floored player cell. It does not subtract one in y. `lookHit` is the placement cell adjacent to the first observed solid voxel hit by the ray, on the face the ray entered. The solid hit itself is never the placement cell. Voxel traversal resolves equal boundary crossings in x, then y, then z order. The adapter sets placement h to the player's nearest cardinal heading using the P0-qualified yaw mapping. Scanner-confirmed blocks can provide observations. Unknown or predicted ray cells make the cursor uncertain. Confirmation requires observed clear placement space and cannot convert uncertainty into an observation.

AR samples at 4 Hz, draws the active level plus or minus one, uses at most 128 elements, and sends at most two changed updates per second. It redraws on boot. Each controller has one planner session with its owner named. Chat uses PR 6's UUID allowlist. Codes go to the authorized private message, toast, and setup HUD. Without a qualified player detector the AR adapter is unavailable, while keyboard and panel planning remain available. No runtime claim about terrain occlusion is made here.

### Single-authority handover

Authority keeps all accepted fields. Kind remains hub or server. The added state is active, frozen, or retired. Only active authority may issue codes, grants, or ordinary SSOT mutations. Handover is false or the following embedded record.

```lua
handover = {
	id = "handover:4:9", target = 8, targetKey = "<32-byte public key>",
	nextEpoch = 3, snapshotHash = "<SHA-256 hex>", pages = 12,
	ackedPages = 0, privateHash = "<SHA-256 hex>",
	preparedReceipt = false, release = false,
}
```

The hub runs the same SSOT and planner core with a smaller ledger budget, no peers, and no code mirror. Handover requires a locally trusted target ID and signing key. The target must have no active independent SSOT dataset. This protocol does not merge two active authorities. A target's imported state is staged and cannot issue work before activation.

The snapshot is a canonical sequence of `{kind,id,rev,hash,bytes}` records sorted by kind then C(id). It includes plans, intents, poses, moves, grants, journals accepted by SSOT, replay fences, codes, frame transforms, settings, map references, counters, and the authority record. Records use blob transfer when necessary. Page bodies are `{handover,page,records}` with at most 64 records and the normal packet bound. Page hashes are SHA-256 over B("cc-h4/handover-page/1",theCompletePageBody), in increasing one-based page order. A descriptor hash is SHA-256 of the exact exported object bytes, distinct from a section's content hash. Every imported object also passes its owning module's version and reference validator before prepared. SnapshotHash is SHA-256 over `B("cc-h4/handover-snapshot/1",{id,source,target,oldEpoch,nextEpoch,targetKey,pageHashes,privateHash})`.

Pairing keys, complete copyCode records, active-code secrets, and other private material never travel in those unencrypted pages. Public code references use codeTag, never the code string. The old signing secret stays at the source and is not exported. The other private records use an operator-carried local floppy export. PrivateHash covers `B("cc-h4/handover-private/1",privateBundle)`. The bundle is checked locally against the snapshot. The target retains its own signing key. The snapshot authority projection is exactly {v,holder,epoch,since,kind,state="frozen",handover=false}. Mutable transfer progress and the snapshot hash are excluded from that projection, so the snapshot cannot hash itself. If trusted private transfer is unavailable, handover stays frozen or does not start. Traffic encryption is outside the accepted plan, so a plaintext network export is not an alternative.

The durable sequence is fixed.

1. Source commits state=frozen with a unique handover ID and nextEpoch=epoch+1. It freezes all shared mutations to keep the export consistent, not just issuance. Read-only status continues. Turtles retain local ESTOP and their already granted offline limits. In-flight claims are invalidated. Claims already committed as used remain committed.
2. Source exports the immutable snapshot and private bundle. Target records each imported page and object by handover ID and stable object identity. Identical duplicates are no-ops. Changed duplicates fail. Import never increments domain revisions merely because a page is repeated.
3. After all page and private hashes verify, target durably records prepared and signs a preparedReceipt over `{id,source,target,targetKey,nextEpoch,snapshotHash}` with domain `cc-h4/handover-prepared/1`. Source verifies it with targetKey.
4. Source atomically commits state=retired and a release token over the same fields with domain `cc-h4/handover-release/1`, signed with the old pinned authority key. That durable retirement precedes sending release. Once release exists, source cannot unfreeze or mint authority again.
5. Target verifies the release, commits the imported generation and active authority with holder=target, epoch=nextEpoch, since=current UTC, and kind=server, then acknowledges. Source becomes a client. Repeated release or activation returns the recorded outcome.

PreparedReceipt and release are `{body,signature}`, with the exact bodies above and 128-character Ed25519 hex signatures. All signature preimages use B with their stated domain. Lost acknowledgements and crashes resume from durable state. A frozen source may abort only before a prepared receipt is accepted and before any release is created. The target then discards staging by that handover ID. After a prepared receipt, the safe recovery path is to finish the transfer. The absence of a reply never proves that another issuer is inactive.

Unclaimed codes retain their original absolute untilAt and profile. Time spent transferring consumes TTL. Pending hello challenges do not migrate. Their codes are invalidated, with a replacement code requiring a new ordinary issuance after activation. A successful but unanswered claim migrates its committed result and exact response bytes. The retired source can return that cached response under its old pinned identity without issuing work or changing state. The target can serve the same bytes as a relay, indexed by old server ID, client ID, both nonces, and the exact original claim digest. It never rewrites the inner envelope or executes the claim again. Unknown or changed requests fail. The client verifies the old Kconfirm MAC, then follows the signed handover and opens a new session. A different attempt needs a new operator-issued code under the normal re-pairing rules. The consumed code cannot pair twice.

Imported leases retain their old signed bytes, expiry, reservations, and replay history. The target keeps their cells reserved until expiry or acknowledged surrender. It cannot remotely revoke an offline turtle by changing an epoch. Clients verify the release with the old pinned authority key, pin the target ID and targetKey carried in that signed release, then establish a fresh session. A client never takes the replacement key from discovery. Existing Kpair can remain private key material, but traffic-key derivation binds the new server ID. No old-session packet becomes valid at the target. New grants require boot and position reconciliation.

## Migration and implementation ownership

The inspected current implementation has schema-1 map keys `dim|sx|sy|sz`, the same 1-based index, explicit air as name index zero, and absent cells as unknown. `nav.lua` uses north-0 vectors. `ssot-client.lua` sends plaintext v1 secrets and has one request in flight. `atomic.lua` currently keeps path, tmp, and bak and poisons the store after a failure. These are migration inputs, not permission to preserve behavior that contradicts the accepted plan.

H4b1 uses state schema 2 for the new map directory. H1H2 manifests report the actual active state schema, which can still be 1 before H4b1. New map files cannot be read as schema 1. H4a's two-slot save protocol writes the inactive slot, flushes and closes it, reads it back, validates it, and then publishes the highest complete generation. It never deletes the sole valid slot to make space. A failed write leaves the previous slot usable and reports the error. Code and mutable-state generation selectors are separate.

The migration receipt is `{v=1,sourceHash,targetSchema=2,frameBindings,headingBindings,cursor,outputHashes,state}`. State is copying, verified, or committed. SourceHash is SHA-256 of the exact old state bytes. FrameBindings maps each legacy namespace to its verified frame and dimension. HeadingBindings records the producing convention. Cursor is the last completed section key in byte order. OutputHashes maps completed target keys to verified hashes. The receipt and both source and target admission costs enter the ledger.

Migration freezes legacy map mutation, validates the old generation, then copies sections in key order. Name index zero becomes observed minecraft:air. Positive indices resolve through the old names table. Absent entries remain unknown. No time, observer, lease, or confidence is invented. Source observations become compacted RLE cells with their original section revision, seed=false, empty facts, and observedAt=0. Absolute SSOT namespaces are labelled abs only when their provenance establishes absolute meaning. Legacy relative miner namespaces receive registered relative frames. Ambiguous bindings stop that namespace's migration without discarding it.

For a producer using current nav vectors, horizontal heading converts once with `newH=(oldH+3)%4`. The migration receipt tags the converted generation. Already tagged data is never converted again. Position coordinates do not rotate merely because heading numbering changes. Producers with other conventions need an explicit verified binding. Missing heading remains an unresolved migration input, not east by default. A saved position becomes suspect until N1 recovery proves it.

Each section is verified for exact observed names, explicit air, unknown cells, and indices before its cursor advances. Final verification checks every source section against the new directory and hashes. Only then does one control-generation commit select schema 2 and mark committed. A crash repeats identical output or resumes at the saved cursor. A different sourceHash refuses resume. Source files remain until the committed target generation survives a validation restart and the configured rollback generation can read schema 2. The contract requires no destructive downgrade path.

The same generation discipline applies to H4b2 recalibration and frame merge. A staged transform or baseline does not become partially visible. Unsupported versions remain recoverable. Rollback never restores old session counters, journal acknowledgements, lease authority, code use, or inventory facts.

| Owner | Responsibility |
| --- | --- |
| P0 | This reference and platform probes. No runtime activation. |
| H3 | Queue, one state worker, non-yielding transactions, timer recovery. |
| H1H2 | Vendor crypto, canonical wire, replay sessions, private keys, signed manifests. |
| N1 | Positions, confidence, frame registry and merge, recovery evidence. |
| I1 and I2 | Enrollment, reducer and keyboard shell, then touch renderer. |
| H4a | Code-cache removal, two-copy saves, capacity admission, control reserves on server and hub. |
| H4b1 and H4b2 | RLE sections and migration, then flagged baselines, sparse cells, geometry, and recalibration. |
| H5 | Dead-turtle expiry, recovery, quarantine, explicit operator forgetting. |
| H4c and W1 | Ledger, policy, previews, backpressure, and the shared settings registry. |
| B1 and B2 | Grants, journals, replay, and bounded local problem handling. |
| T1, A1, and T2 | Planner and intent integration, AR adapter, then all host adapters. |
| S1 | Shared hub profile and single-authority handover. |
| H4d | Peer enrollment, eligibility, replica integrity, and repair. |
| wh2 layout | Verified fixture conversion to the existing location registry. |

The accepted plan's dependency graph controls merge order. Later owners extend earlier shared-file changes. Older prose that H4 is on hold, that layout bypasses its prerequisites, or that H5 follows H1H2 directly is superseded.

## P0 decisions and deviations

The rows resolve the previous candidate's F1 through F14. Constants in this table are normative choices, not measured claims.

| Group | Frozen rule and precise clarification |
| --- | --- |
| F1 | Accepted H4b1 and judgment item 6 override section 10's exclusion. One v2 file envelope has explicit rle/1 and sparse/1 codecs for the two phases. Palette width follows its count. Hash preimages, headers, and byte order are fixed above. No old whc-rle/1 format is imported. |
| F2 | Surface uses 4096 U16 values with y+2049 and zero unknown. This explicitly widens the plan's byte, which cannot encode the supported height range. |
| F3 | Calibration, deterministic predictor, sample minima, immutable references, lossless recalibration, and the below-5% held-out policy threshold are specified. H4b2 must measure actual prediction error and storage cost before enabling its default. |
| F4 | Entry gains typed evidence for both endpoint fingerprints, outcomes, item receipts, and anchors. Every event kind has a defined intent and done payload. |
| F5 | Section gains codec, base, cover, and persisted provenance. Boxes gain missing observer fields. Inspected neighbours require actual material evidence. Filler equivalence does not erase exact observed names. |
| F6 | Lease priority uses observation time. Ties choose greatest UTC, turtle ID, then seq. Set-based recomputation and persistent conflict markers clarify the revision rule and prevent arrival-order dependence. |
| F7 | A separately MACed returnGrant, explicit boot reconciliation, journal closure, and bounded authenticated blobs define recovery without implied renewal. |
| F8 | Vendor API signatures, exact canonical bytes, KDF framing, enrollment lookup and transcripts, capabilities, v2 envelopes, session rollover, and Ed25519 manifests are fixed. Both accepted enrollment profiles are defined. Evidence chooses availability, never peer negotiation. The code-guessing limitation is stated accurately. |
| F9 | The alphabet is 0123456789ABCDEFGHJKMNPQRSTVWXYZ. ASCII normalization is fixed. Ten and sixteen characters retain the plan's code lengths. |
| F10 | The peer window, freshness, score, power checks, ranking, finite quotas, capacity sentinels, sampling interval, and holder boot binding are explicit. |
| F11 | Reducer effects gain IDs and typed operands and results. Candidate heading can be false until facing. Claim precedes authenticated bundle fetch. Fresh install still requires a code. |
| F12 | Authority gains state and durable handover metadata. Freeze, complete import, source retirement, signed release, and target activation have a fixed order. Private keys use local transfer because traffic encryption is excluded. |
| F13 | Fixture side means turtle access side. Standing-cell conversion and AR adjacent-face placement are fixed. Ambiguous fingerprint placement stays suspect. |
| F14 | Crypto preparation stays outside H3 transactions and rechecks immutable pins before commit. A single library call must fit a measured runtime bound. Unsupported operations stay disabled. No handwritten crypto or yields inside SSOT are introduced. |

Other preserved clarifications are the repaired copy-code timestamp fields, inherited versions for embedded tables, named transform fields, separate heading and direction numbering, no automatic retreat after expiry, two required non-miner replicas, per-item forget-preview matching, distinct ordinary and planner TTLs, and exact preview byte totals.

## Coverage and qualification

| Accepted section | Named records and dependent types |
| --- | --- |
| 2.1 | pos, frame, transform, dimension registry, confidence, fingerprints. |
| 2.2 | region, section, baseline, palette, codecs, shapes, material provenance. |
| 2.3 | placement and boot-bound acknowledgements. |
| 2.4 | peer, reachability window, power, quotas, capacity sentinels. |
| 2.5 | lease, access, bounds, corridor, settings, returnGrant, reconciliation. |
| 2.6 | entry, journalHead, all kinds and phases, replay, closure. |
| 2.7 | storagePolicy, ledger, forgetPreview, exact item matching. |
| 2.8 | install, machine, error, history, all six event tags and all six effect operations. |
| 2.9 | copyCode, enrolClaim, both profiles, proof lookup and complete transcripts. |
| 5b | plan, plannedFixture, plannedBot, authority, planner events, handover. |

The specification review preserved 231 sampled direct and nested fields across all 19 accepted records, including the repaired copy-code timestamps. All 18 Lua reference blocks parsed. Canonical byte examples, RLE and sparse examples, all 4097 supported heights, the 32-character alphabet, and seven replay reference cases over ten arrival permutations passed their local checks. These checks used in-memory scripts and did not change runtime files.

Vendor API signatures were checked against the pinned source, including the curried `deriveKey` and the `util.compare` initialization dependency. An earlier host-Lua vendor-call smoke check did not finish inside its timeout and stays inconclusive. Effect correlation and handover crash points were reviewed against this text, not executed. Those checks do not qualify an implementation. The numbers in the next section are the saved probe results.

P0 is qualified only when Gate A and Gate B both pass. Gate A is the CraftOS-PC probe set, with three computers and two mock turtles at a 1,000,000 byte disk, plus `lua5.2 tests/run.lua`. Gate B is a disposable local Minecraft server with the real mods, no GPS hosts, and the client evidence required by `docs/testing/gateB-depth.md`. Evidence stays under `docs/evidence/p0/`, including `gateA.json` and `gateB.json`. No live server is a target.

The saved evidence records a Gate A pass for the emulator probes and a Gate B failure. The failure is the client work that did not run: detector position, rounding, yaw, pitch, eye height, dimension, range, AR line and text occlusion, F2 screenshots, and one video. Runtime enablement stays off. The shapes above are still the contract for later PRs.

## Recorded P0 bounds

CraftOS-PC 2.8.3 sample arrays are in `docs/evidence/p0/gateA.json`. Cobalt sample arrays, from CC:Tweaked 1.120.2 on Minecraft 1.21.1, are in `docs/evidence/p0/gateB.json`. The vendor revision is commit `14489aa1ec408f8a07e1292be5ef91dfe8567c74`. A larger one-shot input, or another runtime, is outside this qualification. Blob admission rejects a hash or signature preimage bigger than the measured input for that operation. Domain framing counts toward the bound.

Crypto. Both runtimes completed 65 samples, five per operation, with zero explicit yields and zero failed checks. Five samples are the deliberate modified-message rejections. The inputs are keyed BLAKE3 at 1,024, 8,192, and 37,888 bytes, SHA-256 at 963, 12,288, and 37,888 bytes, X25519 public-key generation and exchange on the RFC 7748 keys, and Ed25519 sign, verify, reject, plus an 8,192-byte manifest sign and verify. The longest uninterrupted Cobalt sample was 122 ms, on `blake3-keyed-37888`. The Linux CraftOS-PC rerun's longest uninterrupted crypto sample was 43 ms, on `sha256-section-37888`. Every saved sample was under 7,000 ms. These inputs do not need a yield inside the library call.

Randomness. An uninitialized generator was rejected on both runtimes. A caller-supplied seed and VM instruction timing each returned 32 bytes. The public benchmark seed is not deployment entropy, and a successful timing source is not a quality proof. Krist stored no token. The Linux CraftOS-PC rerun reported no token URL after 150 ms. Cobalt reported that the domain was not permitted (`gateB.json`, 57 ms). The disposable server's `cryptographic_accelerator` returned 32 bytes after 15 ms. Provisioning uses that peripheral when it is attached, or a secret seed supplied outside the radio. A turtle with neither source cannot issue either enrolment profile.

A*. `nav.lua` yields every `batch` nodes. The fixture uses batch 32, a 64 by 64 known-air plane, and no GPS. Each runtime ran five searches at 2,048 nodes, all refused with `search budget`, and five at 4,096 nodes, all returning 126 moves. Each 2,048-node search yielded 62 times and each 4,096-node search yielded 127 times. The longest uninterrupted slice was 11 ms on both the Linux CraftOS-PC rerun and Cobalt. CraftOS-PC search totals were 3,669 to 3,700 ms and 7,519 to 7,599 ms. Cobalt totals were 3,099 to 3,101 ms and 6,350 to 6,400 ms. No search moved a turtle. This fixture does not need a smaller batch to stay under the watchdog.

Storage. Every measured disk reported capacity 1,000,000. On Cobalt a directory cost 500 bytes, and files of 0, 1, 499, 500, 501, and 1,000 bytes allocated 500, 500, 500, 500, 501, and 1,000. Before the fixture each Cobalt disk reported 802,070 bytes free, and 798,069 after. On the Linux CraftOS-PC rerun each of the three disks fell from 807,679 bytes free to 805,178 bytes. The directory cost was 0 and each file cost its content size. Admission uses the real runtime's `fs.getCapacity` and `fs.getFreeSpace`.

Fuel. The copied CC config sets `need_fuel` true, `normal_fuel_limit` 20,000, and `advanced_fuel_limit` 100,000. The six turtles were advanced and reported limit 100,000. Ten moves with no charger and no starbound upgrade consumed one fuel each, and two idle seconds changed nothing. The automata, netherite, creative, and chunk-vial upgrades did the same. Starbound per-move deltas were 1, 1, -1, 1, 0, 0, -1, 1, -3, -1, and idle fuel rose from 1,029 to 1,033. With charging, nine immediate decreases were 1 and one was 0, and idle fuel rose from 4,652 to 4,661. After the charger was removed, ten moves consumed ten fuel and idle fuel stayed at 4,696. There were 80 successful moves across those eight scenarios and zero digs. Fuel recovery applies only when the journal records that charging and regeneration were both absent. The measured cost of one belongs to that case only.

Clocks, modems, and reload. With `doDaylightCycle` false, five `os.epoch("ingame")` readings stayed at 111,600,000 while UTC advanced. `/time set 6000` moved them to 129,600,000. With the cycle on, five readings increased by 7,200 about every 100 ms. `enderModemNerf` is false in `docs/evidence/p0/config/classicperipherals.toml`. An ender modem delivered 10 of 10 packets to a normal modem at 512 blocks, distance 512, and 10 of 10 into the Nether with no distance field. A normal modem delivered 0 of 10 new packets at 512 blocks. A normal-modem turtle's boot count rose from 4 to 5 after its chunk unloaded and loaded. Three queries during the unload saw no heartbeat change. Analog outputs 0, 1, 7, and 15 on one turtle read back as 0, 1, 7, and 15 on the neighbour.

Unqualified, and the reason Gate B is still a failure. Detector rounding, yaw and pitch signs, eye height, dimension, measured range, repeatability, the turtle-top anchor, and whether AR lines and text hide behind terrain were not measured. `docs/evidence/p0/config/Advancedperipherals/peripherals.toml` sets `playerDetMaxRange` to -1 and `enablePlayerPosRandomError` to false. That is the copied config, not a player position. `gateB.json` lists the missing result names `detector-anchor`, `detector-yaw-west-down`, `detector-yaw-east-up`, `detector-negative-fraction`, `detector-range-1024`, `detector-crossdim`, `ar-wall`, `ar-open`, and `fuel-video`. No peripheral call stands in for those checks.
