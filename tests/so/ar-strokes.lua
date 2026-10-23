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
  test("AR draws each near outline as a three-strand bundle and the heading as a hatched arrow", function()
    local b = boot()
    b.machines[2] = turtle(1, 3, 1)
    b.points = { { id = "ore", kind = "ore", dim = 0, x = 5, y = 64, z = 3 } }
    b.tick(1000)
    equal(#owned(b, "turtle:2"), 56, "label, 36 box strands and 19 arrow lines")
    equal(#owned(b, "drop:ore"), 37, "label and 36 box strands")
    for edge = 1, 12 do
      local base = b.ar.elements["turtle:2:box:" .. edge]
      for k = 2, 3 do
        local strand = b.ar.elements["turtle:2:box:" .. edge .. ":s" .. k]
        local ox, oy, oz = strand[2] - base[2], strand[3] - base[3], strand[4] - base[4]
        equal(near(strand[5] - base[5], ox) and near(strand[6] - base[6], oy) and near(strand[7] - base[7], oz), true, "strand is parallel")
        equal(near(math.sqrt(ox * ox + oy * oy + oz * oz), 0.025), true, "strand offset is the bundle radius")
        local dx, dy, dz = base[5] - base[2], base[6] - base[3], base[7] - base[4]
        equal(near(ox * dx + oy * dy + oz * dz, 0), true, "offset is perpendicular to the edge")
      end
    end
    local shaft = b.ar.elements["turtle:2:heading"]
    equal({ shaft[2], shaft[3], shaft[4], shaft[5], shaft[6], shaft[7] }, { 2.05, 64.5, 3.5, 2.7, 64.5, 3.5 })
    assert(b.ar.elements["turtle:2:heading:s2"] and b.ar.elements["turtle:2:heading:s3"])
    for k = 1, 4 do
      local edge = b.ar.elements["turtle:2:heading:" .. k]
      equal({ edge[2], edge[3], edge[4] }, { 3.25, 64.5, 3.5 }, "head edges meet at the tip")
      equal(edge[5], 2.7)
    end
    equal(b.ar.elements["turtle:2:heading:1"][7], 3.2)
    equal(b.ar.elements["turtle:2:heading:4"][6], 64.8)
    for i = 0, 5 do
      local h, v = b.ar.elements["turtle:2:heading:h" .. i], b.ar.elements["turtle:2:heading:v" .. i]
      equal(near(h[7] - h[4], 0.6 * (1 - i / 6)), true, "flat hatch narrows toward the tip")
      equal(near(v[6] - v[3], 0.6 * (1 - i / 6)), true, "upright hatch narrows toward the tip")
      equal(h[2], v[2])
    end
    equal(b.ar.elements["turtle:2:heading"][1], b.ar.elements["turtle:2:heading:v5"][1])
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
    equal(#gone, 56)
    b.machines[3] = nil
    b.tick(3000)
    table.sort(b.deleted)
    equal(b.deleted, gone)
    equal(b.frames, 3, "one update per frame")
  end)
  test("AR bundles only the nearest sixteen shapes and bounds lines per frame", function()
    local b = boot()
    for id = 1, 20 do b.machines[id] = turtle(id * 3, 0, 0) end
    b.tick(1000)
    for id = 1, 16 do equal(#owned(b, "turtle:" .. id), 56, "near turtle " .. id) end
    for id = 17, 20 do equal(#owned(b, "turtle:" .. id), 15, "far turtle " .. id .. " keeps a box and simple arrow") end
    equal(lines(b), 16 * 55 + 4 * 15)
    b.machines[1] = nil
    b.tick(2000)
    equal(#owned(b, "turtle:17"), 56, "the next nearest turtle gains a bundle and label")
    equal(lines(b), 16 * 55 + 3 * 15)
    assert(lines(b) <= 16 * 55 + 4 * 15)
  end)
end
