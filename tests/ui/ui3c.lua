local H = dofile("tests/so/harness.lua")
local C = { green = 0xFF3DDC84 - 2^32, amber = 0xFFFFC24B - 2^32, coral = 0xFFFF6B5E - 2^32,
  blue = 0xFF5AB0FF - 2^32, teal = 0xFF2DD4BF - 2^32, stale = 0xFF4A5468 - 2^32,
  white = 0xFFF2F4F8 - 2^32, backing = 0xC00E1626 - 2^32 }
local function boot()
  local m = H.new().machine({ id = 1, capacity = 16000000 })
  m.install({ "so-store.lua", "so-mod-ar.lua", "so-mod-cells.lua" })
  local e, b = m.env, { machines = {}, values = {}, entries = {}, points = {}, cells = {}, status = {}, outside = {} }
  e.SO = { store = e.dofile("so-store.lua"), proto = { ser = H.encode }, mods = {} }
  local mods = e.SO.mods
  mods.state = { get = function() return b.machines end, view = function() return { values = b.values } end }
  mods.lease = { status = function(id) return b.status[id] end, inRange = function(id) return not b.outside[id] end }
  mods.drops = { list = function() return b.points end }
  mods.cells = { list = function(owner) return b.cells[owner] end, counts = function()
    local reserved = {}; for owner in pairs(b.cells) do reserved[owner] = 1 end
    return { reserved = reserved }
  end }
  mods.display = { screen = function(_, _, input) b.input = input end }
  e.fs.getCapacity = function() return 16000000 end
  e.fs.getFreeSpace = function() return b.free or 13920000 end
  local ar = { elements = {}, methods = {}, deleted = {}, frames = 0 }
  for _, method in ipairs({ "drawLine3D", "drawText3D", "drawRect2D", "drawText2D" }) do
    ar[method] = function(id, ...) ar.elements[id], ar.methods[id] = { ... }, method end
  end
  ar.delete = function(id) ar.deleted[#ar.deleted + 1] = id; ar.elements[id] = nil end
  ar.update = function() ar.frames = ar.frames + 1 end
  e.peripheral.find = function() return ar end
  b.ar, b.env, b.tick = ar, e, e.dofile("so-mod-ar.lua").tick
  b.machine = function(id, state)
    b.machines[id] = { state = state, seen = 1000, fuel = 400,
      pose = { dim = "minecraft:overworld", x = id, y = 64, z = 3 } }
  end
  return b
end
return function(test, equal)
  test("UI3c turtle labels and twelve box edges use known state colours", function()
    local b = boot()
    local cases = { { "mining", C.green, "MINING" }, { "waiting", C.amber, "WAITING" },
      { "hold", C.amber, "HOLD" }, { "idle", C.coral, "LOST" }, { "idle", C.stale, "STALE" },
      { "idle", C.teal, "LEASED" }, { "idle", C.coral, "OUT OF RANGE" },
      { "idle", C.amber, "LOW FUEL" }, { "idle", C.white, "IDLE" },
      { "wait lane", C.amber, "WAIT LANE" }, { "working", C.green, "WORKING" } }
    for id, row in ipairs(cases) do b.machine(id, row[1]); b.status[id] = { open = "lease" } end
    b.status[4].lost = true; b.machines[5].seen = -119000; b.outside[7] = true
    b.machines[8].fuel = 12; b.status[9] = {}
    b.tick(1000)
    equal(b.ar.frames, 1)
    for id, row in ipairs(cases) do
      local key = "turtle:" .. id
      equal(b.ar.elements[key][1], row[2]); equal(b.ar.elements[key][7], 3)
      equal(b.ar.elements[key][8], "#" .. id .. " " .. row[3])
      for edge = 1, 12 do
        equal(b.ar.methods[key .. ":box:" .. edge], "drawLine3D")
        equal(b.ar.elements[key .. ":box:" .. edge][1], row[2])
      end
    end
  end)
  test("UI3c lease owners have one blue outline and drops have uppercase labels", function()
    local b = boot(); b.machine(2, "working")
    b.cells["mine:2"] = { { x = 0, y = 1, z = 2 }, { x = 8, y = 3, z = 4 } }
    b.cells["lumber:2"] = { { x = 10, y = 1, z = 2 } }
    b.points = { { id = 3, kind = "ore", x = 2, y = 3, z = 4 },
      { id = 4, kind = "fuel", x = 5, y = 3, z = 4, broken = true } }
    b.tick(1000)
    local n = 0
    for id, args in pairs(b.ar.elements) do if id:match("^lease:") then n = n + 1; equal(args[1], C.blue) end end
    equal(n, 24)
    equal(b.ar.elements["lease:mine:2:2"][2], 9)
    for _, row in ipairs({ { 3, C.white, "ORE 3" }, { 4, C.coral, "FUEL 4" } }) do
      equal(b.ar.elements["drop:" .. row[1]][8], row[3])
      for i = 1, 12 do equal(b.ar.elements["drop:" .. row[1] .. ":box:" .. i][1], row[2]) end
    end
  end)
  test("UI3c AR frame with 200 reservations does not sleep or yield", function()
    local b = boot(); b.machine(2, "mining")
    local sleeps = 0
    b.env.sleep = function() error("server module called sleep") end
    b.env.SO.breathe = function() sleeps = sleeps + 1 end
    local cells = b.env.dofile("so-mod-cells.lua")
    local route = {}
    for x = 1, 200 do route[x] = { x = x, y = 64, z = 3 } end
    assert(cells.reserveMany("mine:2", route))
    b.env.SO.mods.cells = cells
    sleeps = 0; cells.counts(); assert(sleeps > 0, "counts must exercise the pause threshold")
    sleeps = 0
    local frame = coroutine.create(function() b.tick(1000) end)
    local ok, err = coroutine.resume(frame); assert(ok, err)
    equal(coroutine.status(frame), "dead")
    equal(sleeps, 0)
    equal(b.ar.frames, 1)
    for edge = 1, 12 do equal(b.ar.elements["lease:mine:2:" .. edge][1], C.blue) end
    equal(b.ar.elements["lease:mine:2:2"][2], 201)
  end)
  test("UI3c HUD has three forty pixel tiles with backing and four pixel bars", function()
    local b = boot(); b.machine(2, "working"); b.machine(3, "lost")
    b.values["mine.alert"] = { text = "CHEST FULL" }; b.tick(1000)
    for i, id in ipairs({ "turtles", "alerts", "disk" }) do
      local key = "hud:" .. id
      equal(b.ar.methods[key .. ":backing"], "drawRect2D")
      equal(b.ar.elements[key .. ":backing"], { C.backing, (i - 1) * 40, 18, 40, 28 })
      equal(b.ar.elements[key .. ":bar"], { i == 3 and C.green or C.coral, (i - 1) * 40, 18, 40, 4 })
      equal(b.ar.elements[key .. ":label"][4], id:upper())
    end
    equal(b.ar.elements["hud:turtles:value"][4], "1 ok")
    equal(b.ar.elements["hud:alerts:value"][4], "1")
    equal(b.ar.elements["hud:disk:value"][4], "13%")
    b.free = 1600000; b.tick(2000); equal(b.ar.elements["hud:disk:bar"][1], C.coral)
  end)
  test("UI3c alert banner expires after five seconds and retains the HUD count", function()
    local b = boot(); b.tick(1000); b.values["mine.alert"] = { text = "CHEST FULL" }; b.tick(2000)
    equal(b.ar.elements["alert:backing"], { C.coral, 0, 0, 120, 14 })
    equal(b.ar.elements["alert:mine.alert"][4], "CHEST FULL")
    b.tick(6000); assert(b.ar.elements["alert:backing"])
    b.tick(7000); equal(b.ar.elements["alert:backing"], nil); equal(b.ar.elements["alert:mine.alert"], nil)
    equal(b.ar.elements["hud:alerts:value"][4], "1")
    b.tick(8000); equal(b.ar.elements["alert:backing"], nil)
    b.values["mine.alert"] = { text = "FUEL EMPTY" }; b.tick(9000)
    equal(b.ar.elements["alert:mine.alert"][4], "FUEL EMPTY")
    b.input({ id = "alerts" }); b.tick(10000)
    equal(b.ar.elements["alert:backing"], nil); equal(b.ar.elements["hud:alerts:value"][4], "1")
    b.input({ id = "alerts" }); b.tick(14000); equal(b.ar.elements["alert:backing"], nil)
  end)
  test("UI3c repeated history alerts renew the banner without changing the count", function()
    local b = boot(); b.values["mine.alert"] = { text = "FULL" }
    b.env.SO.mods.state.history = { page = function(q)
      local rows = {}; for _, row in ipairs(b.entries) do if row.seq > q.from then rows[#rows + 1] = row end end
      return { entries = rows }
    end }
    b.entries[1] = { seq = 1, kind = "mine.alert" }; b.tick(1000); b.tick(6000)
    equal(b.ar.elements["alert:mine.alert"], nil)
    b.entries[2] = { seq = 2, kind = "mine.alert" }; b.tick(7000)
    assert(b.ar.elements["alert:mine.alert"]); equal(b.ar.elements["hud:alerts:value"][4], "1")
  end)
  test("UI3c stable frames retain ids and removing a turtle deletes exactly its ids", function()
    local b = boot(); b.machine(2, "working"); b.machine(3, "working"); b.tick(1000)
    local ids = {}; for id in pairs(b.ar.elements) do ids[id] = true end
    assert(ids["hud:turtles:bar"], "stable scene includes the new HUD")
    b.tick(1500); equal(b.ar.frames, 1); b.tick(2000); equal(b.ar.frames, 1)
    for id in pairs(b.ar.elements) do assert(ids[id]); ids[id] = nil end
    equal(ids, {}); equal(b.ar.deleted, {})
    b.machines[2] = nil; b.tick(3000); equal(b.ar.frames, 2); equal(#b.ar.deleted, 16)
    for _, id in ipairs(b.ar.deleted) do assert(id == "turtle:2" or id:match("^turtle:2:")) end
    b.input({ id = "turtles" }); b.tick(4000); equal(b.ar.elements["turtle:3"], nil)
  end)
end
