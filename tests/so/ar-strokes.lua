local H = dofile("tests/so/harness.lua")
local function boot()
  local n = H.new()
  local m = n.machine({ id = 1, capacity = 16000000 })
  m.install({ "so-store.lua", "so-mod-ar.lua" })
  m.files["so-server.cfg"] = H.encode({ pos = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 } })
  local e = m.env
  local b = { machines = {}, points = {}, deleted = {}, frames = 0 }
  e.SO = { now = function() return 0 end, store = e.dofile("so-store.lua"), proto = { ser = H.encode }, mods = {} }
  e.SO.mods.state = { get = function() return b.machines end, view = function() return { values = {} } end }
  e.SO.mods.lease = { status = function() return { open = "batch" } end, inRange = function() return true end }
  e.SO.mods.drops = { list = function() return b.points end }
  local ar = { elements = {} }
  for _, method in ipairs({ "drawLine3D", "drawText3D", "drawText2D", "drawRect2D" }) do
    ar[method] = function(id, ...) ar.elements[id] = { method = method, ... } end
  end
  ar.delete = function(id) b.deleted[#b.deleted + 1] = id ar.elements[id] = nil end
  ar.clear = function() ar.elements = {} end
  ar.update = function() b.frames = b.frames + 1 end
  e.peripheral.find = function(kind) if kind == "ar_controller" then return ar end end
  b.ar, b.tick = ar, e.dofile("so-mod-ar.lua").tick
  return b
end
local function turtle(x, z, facing) return { pose = { dim = "minecraft:overworld", x = x, y = 64, z = z, facing = facing }, seen = 0, fuel = 500 } end
local function owned(b, key)
  local ids = {}
  for id in pairs(b.ar.elements) do
    if id == key or id:sub(1, #key + 1) == key .. ":" then ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end
local function lines(b)
  local count = 0
  for _, element in pairs(b.ar.elements) do if element.method == "drawLine3D" then count = count + 1 end end
  return count
end
local function near(a, b) return math.abs(a - b) < 1e-9 end
return function(test, equal)
  test("AR draws every outline as one stroke per edge and the heading as a small chevron on the top face", function()
    local b = boot()
    b.machines[2] = turtle(1, 3, 1)
    b.points = { { id = "ore", kind = "ore", dim = 0, x = 5, y = 64, z = 3 } }
    b.tick(1000)
    equal(#owned(b, "turtle:2"), 15, "label, 12 box edges and 2 chevron lines")
    equal(#owned(b, "drop:ore"), 13, "label and 12 box edges")
    for _, id in ipairs(owned(b, "turtle:2")) do assert(not id:find(":s%d$"), "no strand " .. id) end
    for edge = 1, 12 do equal(b.ar.elements["turtle:2:box:" .. edge].method, "drawLine3D") end
    local top = b.ar.elements["turtle:2:box:5"]
    equal(near(top[3], 65.05) and near(top[6], 65.05), true, "edges 5 to 8 are the top face")
    -- Facing east: the tip sits 0.3 east of the top centre, the wings 0.1 behind it and 0.25 aside.
    local left, right = b.ar.elements["turtle:2:heading"], b.ar.elements["turtle:2:heading:1"]
    for _, wing in ipairs({ left, right }) do
      equal(near(wing[5], 1.8) and near(wing[6], 65.05) and near(wing[7], 3.5), true, "both wings meet at the tip")
      equal(near(wing[2], 1.4) and near(wing[3], 65.05), true, "wings start behind the centre on the top face")
      assert(wing[2] > 0.95 and wing[5] < 2.05, "the chevron stays inside the box")
    end
    equal(near(left[4], 3.75) and near(right[4], 3.25), true, "wings sit 0.25 either side")
    equal(b.ar.elements["turtle:2:heading:2"], nil, "no arrow head or hatches")
    assert(b.ar.elements["turtle:2"][3] > 65.05, "the label sits above the chevron")
    for i, case in ipairs({ { 0, 1.5, 3.2 }, { 2, 1.5, 3.8 }, { 3, 1.2, 3.5 } }) do
      local facing, tip = case[1], { case[2], case[3] }
      b.machines[2] = turtle(1, 3, facing)
      b.tick(1000 + 1000 * i)
      local wing = b.ar.elements["turtle:2:heading"]
      equal(near(wing[5], tip[1]) and near(wing[7], tip[2]), true, "tip for facing " .. facing)
    end
  end)
  test("AR stroke ids are stable across frames and a removed turtle deletes exactly its ids", function()
    local b = boot()
    b.machines[2], b.machines[3] = turtle(1, 3, 1), turtle(6, 3, 2)
    b.tick(1000)
    local before = {}
    for id in pairs(b.ar.elements) do before[#before + 1] = id end
    table.sort(before)
    b.machines[2].fuel = 499
    b.tick(2000)
    local after = {}
    for id in pairs(b.ar.elements) do after[#after + 1] = id end
    table.sort(after)
    equal(after, before)
    equal(#b.deleted, 0)
    local gone = owned(b, "turtle:3")
    equal(#gone, 15)
    b.machines[3] = nil
    b.tick(3000)
    table.sort(b.deleted)
    equal(b.deleted, gone)
    equal(b.frames, 3, "one update per frame")
  end)
  test("AR keeps 14 lines per turtle, far under the old 1932-line frame budget", function()
    local b = boot()
    for id = 1, 20 do b.machines[id] = turtle(id * 3, 0, 0) end
    b.tick(1000)
    for id = 1, 16 do equal(#owned(b, "turtle:" .. id), 15, "labelled turtle " .. id) end
    for id = 17, 20 do equal(#owned(b, "turtle:" .. id), 14, "turtle " .. id .. " past the label limit keeps its strokes") end
    equal(lines(b), 20 * 14)
    assert(lines(b) <= 16 * 117 + 4 * 15)
    b.machines[1] = nil
    b.tick(2000)
    equal(#owned(b, "turtle:17"), 15, "the next nearest turtle gains a label")
    equal(lines(b), 19 * 14)
  end)
end
