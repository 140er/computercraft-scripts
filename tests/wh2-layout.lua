-- Layout behaviour. Loaded from tests/run.lua.

local function install(test, equal)
  local L = dofile("wh2-layout.lua")
  local W = dofile("warehouse-tasks.lua")
  local cfg = L.config({ enabled = true, operators = { ["4"] = true } })

  local function ctx(now, extra)
    local context = { now = now or 1000, epoch = 1, config = cfg }
    if extra then for k, v in pairs(extra) do context[k] = v end end
    return context
  end

  local function pos(x, y, z, h, frame)
    return {
      v = 1, frame = frame or "abs", yAbs = true, dim = "minecraft:overworld",
      x = x, y = y, z = z, h = h or 0, conf = "certain", src = "typed", anchoredAt = 1000,
    }
  end

  local function location(id, x, kind)
    kind = kind or "dropoff"
    local block = pos(x + 1, 65, 0, 1)
    local access = { pose = pos(x, 65, 0, 1), side = "front" }
    local names = { source = false, drop = id, charge = false }
    if kind == "storage" then names = { source = id, drop = false, charge = false } end
    if kind == "charge" then names = { source = false, drop = false, charge = id } end
    return {
      v = 1, id = id, kind = kind, roomId = false, enabled = true,
      block = block, access = access, siteNames = names, lockId = "lock:" .. id, revision = 0,
    }
  end

  local function room(id)
    return {
      v = 1, id = id, revision = 0, scanComplete = false,
      bounds = { min = pos(0, 64, 0, 0), max = pos(3, 66, 3, 0) },
      observedChunks = {}, blocked = {}, accessPaths = {}, reserved = {},
    }
  end

  test("layout stays off until wh2.enabled", function()
    local s = {}
    local reply = L.run(s, 4, { op = "wh2-get", topic = "locations", cursor = 0 }, ctx(1000, { config = L.config({}) }))
    equal(reply.code, "disabled")
    equal(s.wh2, nil)
    equal(L.config({}).enabled, false)
  end)

  test("a non-operator cannot edit a location", function()
    local s = {}
    local reply = L.run(s, 5, {
      op = "wh2-layout", kind = "location", id = "mine-drop", baseRevision = 0, value = location("mine-drop", 10),
    }, ctx())
    equal(reply.code, "forbidden")
    equal(s.wh2.layout.locations["mine-drop"], nil)
  end)

  test("locations, bad facing, locks, and a busy remove", function()
    local s = { warehouse = { sites = {}, orders = {}, locks = {} } }
    local made = L.run(s, 4, {
      op = "wh2-layout", kind = "location", id = "mine-drop", baseRevision = 0, value = location("mine-drop", 10),
    }, ctx())
    equal(made.ok, true)
    equal(made.revision, 1)
    equal(made.record.access.pose.x, 10)
    equal(L.targets(made.record.access, made.record.block), true)
    local bad = location("mine-drop", 10)
    bad.access.pose.h = 0
    local rejected = L.run(s, 4, {
      op = "wh2-layout", kind = "location", id = "other", baseRevision = made.revision, value = bad,
    }, ctx())
    equal(rejected.code, "invalid")
    local again = L.run(s, 4, {
      op = "wh2-layout", kind = "location", id = "mine-drop", baseRevision = 0, value = location("mine-drop", 10),
    }, ctx())
    equal(again.code, "stale_revision")
    local twin = location("other", 10)
    twin.block = made.record.block
    twin.lockId = "lock:other"
    twin.siteNames.drop = "other"
    local clash = L.run(s, 4, {
      op = "wh2-layout", kind = "location", id = "other", baseRevision = made.revision, value = twin,
    }, ctx())
    equal(clash.code, "invalid")
    s.warehouse.locks["mine-drop"] = 17
    local removed = L.run(s, 4, {
      op = "wh2-layout", kind = "location", id = "mine-drop", baseRevision = made.revision, remove = true,
    }, ctx())
    equal(removed.code, "blocked")
    s.warehouse.locks["mine-drop"] = nil
    local gone = L.run(s, 4, {
      op = "wh2-layout", kind = "location", id = "mine-drop", baseRevision = made.revision, remove = true,
    }, ctx())
    equal(gone.ok, true)
    equal(s.wh2.layout.locations["mine-drop"], nil)
  end)

  test("a room path must be adjacent observed air and end on the standing cell", function()
    local s = { chunks = {}, names = {} }
    local made = L.run(s, 4, { op = "wh2-layout", kind = "room", id = "room:main", baseRevision = 0, value = room("room:main") }, ctx())
    equal(made.ok, true, made.error)
    local drop = location("mine-drop", 1)
    drop.roomId = "room:main"
    local early = L.run(s, 4, { op = "wh2-layout", kind = "location", id = "mine-drop", baseRevision = made.revision, value = drop }, ctx())
    equal(early.code, "blocked")
    local reserved = room("room:main")
    reserved.reserved = {
      ["abs|minecraft:overworld|0|65|0"] = { kind = "access", locationId = "mine-drop" },
      ["abs|minecraft:overworld|1|65|0"] = { kind = "entrance", locationId = "mine-drop" },
    }
    local updated = L.run(s, 4, {
      op = "wh2-layout", kind = "room", id = "room:main", baseRevision = made.revision, value = reserved,
    }, ctx())
    equal(updated.ok, true, updated.error)
    local placed = L.run(s, 4, {
      op = "wh2-layout", kind = "location", id = "mine-drop", baseRevision = updated.revision, value = drop,
    }, ctx())
    equal(placed.ok, true, placed.error)
    local function air(pos)
      if pos.x == 0 or pos.x == 1 then return "minecraft:air" end
    end
    local uploaded = L.run(s, 4, {
      op = "wh2-layout", kind = "room", id = "room:main", field = "accessPaths", pathId = "mine-drop",
      uploadId = "layout:4:1", baseRevision = placed.revision, offset = 0, final = false,
      records = { pos(0, 65, 0, 1) },
    }, ctx(1000, { observe = air }))
    equal(uploaded.ok, true, uploaded.error)
    equal(uploaded.nextOffset, 1)
    equal(uploaded.revision, placed.revision)
    local changed = L.run(s, 4, {
      op = "wh2-layout", kind = "room", id = "room:main", field = "accessPaths", pathId = "mine-drop",
      uploadId = "layout:4:1", baseRevision = placed.revision, offset = 0, final = false,
      records = { pos(2, 65, 0, 1) },
    }, ctx(1000, { observe = air }))
    equal(changed.code, "invalid")
    local gap = L.run(s, 4, {
      op = "wh2-layout", kind = "room", id = "room:main", field = "accessPaths", pathId = "mine-drop",
      uploadId = "layout:4:1", baseRevision = placed.revision, offset = 2, final = false,
      records = { pos(1, 65, 0, 1) },
    }, ctx(1000, { observe = air }))
    equal(gap.code, "invalid")
    local solid = L.run(s, 4, {
      op = "wh2-layout", kind = "room", id = "room:main", field = "accessPaths", pathId = "mine-drop",
      uploadId = "layout:4:1", baseRevision = placed.revision, offset = 1, final = true,
      records = { pos(1, 65, 0, 1) },
    }, ctx(1000, { observe = function() return "minecraft:stone" end }))
    equal(solid.code, "blocked")
    local done = L.run(s, 4, {
      op = "wh2-layout", kind = "room", id = "room:main", field = "accessPaths", pathId = "mine-drop",
      uploadId = "layout:4:1", baseRevision = placed.revision, offset = 1, final = true,
      records = { pos(1, 65, 0, 1) },
    }, ctx(1000, { observe = air }))
    equal(done.ok, true, done.error)
    equal(done.final, true)
    equal(#s.wh2.layout.rooms["room:main"].accessPaths["mine-drop"], 2)
    local replay = L.run(s, 4, {
      op = "wh2-layout", kind = "room", id = "room:main", field = "accessPaths", pathId = "mine-drop",
      uploadId = "layout:4:1", baseRevision = placed.revision, offset = 1, final = true,
      records = { pos(1, 65, 0, 1) },
    }, ctx(1000, { observe = air }))
    equal(replay.ok, true)
    equal(replay.revision, done.revision)
    local spent = L.run(s, 4, {
      op = "wh2-layout", kind = "room", id = "room:main", field = "blocked",
      uploadId = "layout:4:1", baseRevision = done.revision, offset = 0, final = true, records = {},
    }, ctx())
    equal(spent.code, "upload_expired")
  end)

  test("an idle upload expires and leaves the room in place", function()
    local s = {}
    local made = L.run(s, 4, { op = "wh2-layout", kind = "room", id = "room:main", baseRevision = 0, value = room("room:main") }, ctx())
    local started = L.run(s, 4, {
      op = "wh2-layout", kind = "room", id = "room:main", field = "blocked", uploadId = "layout:4:2",
      baseRevision = made.revision, offset = 0, final = false,
      records = { { key = "abs|minecraft:overworld|1|65|1", value = "minecraft:stone" } },
    }, ctx(5000))
    equal(started.ok, true, started.error)
    local status = L.run(s, 4, { op = "wh2-layout", action = "status", uploadId = "layout:4:2" }, ctx(5000 + 30000))
    equal(status.code, "upload_expired")
    equal(s.wh2.layout.rooms["room:main"].blocked["abs|minecraft:overworld|1|65|1"], nil)
    equal(s.wh2.layout.revision, made.revision)
  end)

  test("two uploads are the operator limit", function()
    local s = {}
    local made = L.run(s, 4, { op = "wh2-layout", kind = "room", id = "room:main", baseRevision = 0, value = room("room:main") }, ctx())
    local function open(n)
      return L.run(s, 4, {
        op = "wh2-layout", kind = "room", id = "room:main", field = "blocked", uploadId = "layout:4:" .. n,
        baseRevision = made.revision, offset = 0, final = false, records = {},
      }, ctx())
    end
    equal(open(3).ok, true, open(3).error)
    equal(open(4).ok, true, open(4).error)
    equal(open(5).code, "capacity")
  end)

  test("classes overlay wizard answers and keep layout defaults", function()
    local s = { wh2 = { wizard = { v = 1, revision = 4, classes = {
      ["minecraft:raw_iron"] = {
        v = 1, item = "minecraft:raw_iron", class = "ores", route = "blast", storeCategory = "ingots",
        recipeId = false, source = "wizard", revision = 4, updatedBy = 4,
      },
    } } } }
    local put = L.run(s, 4, {
      op = "wh2-layout", kind = "classDefault", id = "minecraft:raw_iron", baseRevision = 0,
      value = { item = "minecraft:raw_iron", class = "ores", route = "store", storeCategory = "misc", recipeId = false },
    }, ctx())
    equal(put.ok, true, put.error)
    equal(put.record.source, "layout")
    equal(put.record.route, "store")
    local view = L.run(s, 9, { op = "wh2-get", topic = "classes", cursor = 0 }, ctx())
    equal(view.ok, true)
    equal(view.revision, put.revision .. ":4")
    equal(view.records[1].route, "blast")
    equal(view.records[1].source, "wizard")
    s.wh2.wizard = nil
    local defaults = L.run(s, 9, { op = "wh2-get", topic = "classes", id = "minecraft:raw_iron", cursor = 0 }, ctx())
    equal(defaults.records[1].route, "store")
    equal(defaults.revision, put.revision .. ":0")
  end)

  test("a verified fixture becomes one location and a retired fixture leaves", function()
    local s = {}
    local fixture = {
      v = 1, id = "p:4:19", plan = "p:4:17", kind = "chest", side = "front", state = "verified",
      pos = pos(11, 65, 20, 1), layoutId = false,
    }
    local planned = L.run(s, 4, {
      op = "wh2-layout", kind = "fixture", id = "p:4:19", baseRevision = 0,
      value = { v = 1, id = "p:4:19", kind = "chest", state = "planned", pos = pos(11, 65, 20, 1) },
    }, ctx())
    equal(planned.code, "invalid")
    local accepted = L.run(s, 4, { op = "wh2-layout", kind = "fixture", id = "p:4:19", baseRevision = 0, value = fixture }, ctx())
    equal(accepted.ok, true, accepted.error)
    equal(accepted.record.kind, "storage")
    equal(accepted.record.block.x, 11)
    equal(accepted.record.access.pose.x, 10)
    equal(accepted.record.access.pose.h, 1)
    equal(L.orderKey(17, 9), "cw:17:9")
    fixture.state = "retired"
    local retired = L.run(s, 4, {
      op = "wh2-layout", kind = "fixture", id = "p:4:19", baseRevision = accepted.revision, value = fixture,
    }, ctx())
    equal(retired.removed, "p:4:19")
  end)

  test("frame conversion is idempotent and relative cells stay out of abs until anchored", function()
    local frame = { v = 1, id = "f:17:1", owner = 17, yAbs = true, toAbs = false }
    equal(L.toAbs(pos(1, 65, 2, 0, "f:17:1"), frame), nil)
    frame.toAbs = { dx = 16, dy = 5, dz = -2, rot = 1 }
    local turned = L.toAbs(pos(1, 65, 2, 0, "f:17:1"), frame)
    equal({ turned.frame, turned.x, turned.z, turned.h, turned.y }, { "abs", -2 + 16, 1 - 2, 1, 65 })
    frame.toAbs = { dx = 16, dy = 0, dz = 0, rot = 0 }
    local layout = L.empty()
    layout.locations["mine-drop"] = location("mine-drop", 1)
    layout.locations["mine-drop"].block.frame = "f:17:1"
    layout.locations["mine-drop"].access.pose.frame = "f:17:1"
    layout.rooms["room:main"] = room("room:main")
    layout.rooms["room:main"].bounds.min.frame = "f:17:1"
    layout.rooms["room:main"].bounds.max.frame = "f:17:1"
    layout.rooms["room:main"].observedChunks["f:17:1|minecraft:overworld|0|4|0"] = 8
    local once = L.applyFrameMerge(layout, frame)
    local twice = L.applyFrameMerge(once, frame)
    equal(once.locations["mine-drop"].block.frame, "abs")
    equal(once.locations["mine-drop"].block.x, layout.locations["mine-drop"].block.x + 16)
    equal(once.rooms["room:main"].observedChunks["abs|minecraft:overworld|1|4|0"], 8)
    equal(L.encoded(once), L.encoded(twice))
  end)

  test("schema-1 chunks report air and leave a missing cell unknown", function()
    local stub = dofile("lib/stubs/layout_dep.lua")
    local origin = pos(0, 64, 0, 0)
    local s = { names = { "minecraft:stone" }, chunks = { ["minecraft:overworld|0|4|0"] = { cells = { [1] = 0 }, rev = 3 } } }
    equal(stub.observe(s, origin), "minecraft:air")
    equal(stub.observe(s, pos(1, 64, 0, 0)), nil)
    origin.frame = "f:17:1"
    equal(stub.observe(s, origin), nil)
  end)

  test("an incomplete scan cannot be marked complete", function()
    local s = {}
    local body = room("room:main")
    body.scanComplete = true
    local reply = L.run(s, 4, { op = "wh2-layout", kind = "room", id = "room:main", baseRevision = 0, value = body }, ctx())
    equal(reply.code, "blocked")
  end)

  test("layout raises warehouse caps and refuses item totals for a fingerprint line", function()
    local function poseOf(p)
      return type(p) == "table" and type(p.dim) == "string" and p.x and p.y and p.z and p.h and p.h >= 0 and p.h <= 3
    end
    local function site(x, kind)
      return { kind = kind, pose = { dim = "minecraft:overworld", x = x, y = 65, z = 0, h = 2 }, side = "front" }
    end
    local function call(s, id, op, fields)
      local message = fields or {}
      message.op = op
      message.boot = "boot"
      return W.run(s, id, message, "1", poseOf)
    end
    local plain = { seq = 0, poses = { [1] = { boot = "boot" } }, warehouse = { sites = {}, orders = {}, locks = {} } }
    for i = 1, 32 do assert(call(plain, 4, "wh-site", { name = "s" .. i, site = site(i, i == 1 and "drop" or "source") }).ok) end
    equal(call(plain, 4, "wh-site", { name = "s33", site = site(33, "source") }).ok, false)
    local armed = { seq = 0, poses = { [1] = { boot = "boot" } }, warehouse = { sites = {}, orders = {}, locks = {} }, wh2 = { layout = L.empty() } }
    L.arm(armed, cfg)
    for i = 1, 33 do
      local reply = call(armed, 4, "wh-site", { name = "s" .. i, site = site(i, i == 1 and "drop" or "source") })
      equal(reply.ok, true, reply.error)
    end
    equal(armed.warehouse.raised, true)
    equal(call(armed, 4, "wh-stock", { name = "s2", stock = { ["minecraft:iron_ingot"] = 10 } }).ok, true)
    local plainLine = call(plain, 4, "wh-order", { key = "cw:4:1", drop = "s1", lines = { { item = "minecraft:iron_ingot", count = 1, source = "s2", nbt = "fp" } } })
    equal(plainLine.ok, false)
    local finger = call(armed, 4, "wh-order", {
      key = "cw:4:1", drop = "s1", job = "craft:4:1", step = 1,
      lines = { { item = "minecraft:iron_ingot", count = 4, source = "s2", nbt = "component-a" } },
    })
    equal(finger.ok, true, finger.error)
    local claimed = call(armed, 1, "wh-claim", {})
    equal(claimed.job.lines[1].count, 0)
    equal(claimed.job.lines[1].nbt, "component-a")
    local names = call(armed, 4, "wh-sites", {})
    equal(type(names.names), "table")
  end)

  test("projected sites share one lock id", function()
    local s = { warehouse = { sites = {}, orders = {}, locks = {} } }
    local chest = location("chest", 4, "storage")
    chest.siteNames.drop = "chest-out"
    local made = L.run(s, 4, { op = "wh2-layout", kind = "location", id = "chest", baseRevision = 0, value = chest }, ctx())
    equal(made.ok, true, made.error)
    local group = L.lockGroup(s.wh2.layout, "chest")
    table.sort(group)
    equal(group, { "chest", "chest-out" })
    local function poseOf(p) return type(p) == "table" and p.dim and p.h end
    L.arm(s, cfg)
    local locked = W.run(s, 8, { op = "wh-lock", name = "chest" }, "1", poseOf)
    equal(locked.ok, true, locked.error)
    equal(s.warehouse.locks["chest-out"], 8)
    equal(s.warehouse.locks.chest, 8)
  end)
end

if arg and arg[0] and arg[0]:find("wh2-layout", 1, true) then
  local passed, failed = 0, 0
  local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1 print("PASS " .. name)
    else failed = failed + 1 print("FAIL " .. name .. "\n  " .. tostring(err)) end
  end
  local function equal(actual, expected, message)
    local function enc(v)
      if type(v) ~= "table" then return tostring(v) end
      local keys, parts = {}, {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. enc(k) .. "]=" .. enc(v[k]) end
      return "{" .. table.concat(parts, ",") .. "}"
    end
    assert(enc(actual) == enc(expected), (message or "values differ") .. "\nexpected: " .. enc(expected) .. "\nactual: " .. enc(actual))
  end
  install(test, equal)
  print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
  if failed > 0 then os.exit(1) end
end

return install
