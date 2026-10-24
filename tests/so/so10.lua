local H = dofile("tests/so/harness.lua")
local function boot(present)
  local net = H.new()
  local machine = net.machine({ id = 1, capacity = 16000000 })
  machine.install({ "so-store.lua", "so-mod-ar.lua", "so-mod-cells.lua", "so-mod-drops.lua", "so-mod-display.lua" })
  local env = machine.env
  env.SO = { now = function() return env.os.epoch("utc") end, mods = {}, store = env.dofile("so-store.lua"), proto = { ser = H.encode } }
  local mods = env.SO.mods
  mods.cells, mods.drops = env.dofile("so-mod-cells.lua"), env.dofile("so-mod-drops.lua")
  local machines = {
    [2] = { pose = { dim = "minecraft:overworld", x = 1, y = 64, z = 3, facing = 1 }, seen = 1000, fuel = 400 },
    [3] = { pose = { dim = "minecraft:overworld", x = 8, y = 64, z = 3 }, seen = 1000, fuel = 200 },
  }
  local values = { ["drops.alert"] = { text = "hold" } }
  mods.state = { get = function() return machines end, view = setmetatable({}, { __call = function() return { values = values } end }) }
  mods.lease = { peek = function(id) return id == 2 and { open = "batch" } or { lost = true } end }
  mods.lease.status = mods.lease.peek
  mods.display = { screen = function(role, render, input) env.render, env.input = render, input end }
  assert(mods.cells.reserve("mine:2", -17, 64, 3))
  assert(mods.cells.reserve("lumber:3", 8, 64, 3))
  assert(mods.drops.add({ id = "ore", kind = "ore", dim = 0, x = 5, y = 64, z = 3, side = "front" }))
  local ar = { elements = {}, deleted = {}, frames = 0, calls = 0, clears = 0 }
  for _, method in ipairs({ "drawLine3D", "drawText3D", "drawText2D" }) do
    ar[method] = function(id, ...)
      ar.calls = ar.calls + 1
      if method == "drawLine3D" and ar.fail then error("draw failure") end
      ar.elements[id] = { ... }
    end
  end
  ar.delete = function(id) ar.deleted[id] = true ar.elements[id] = nil end
  ar.clear = function() ar.clears = ar.clears + 1 ar.elements = {} end
  ar.update = function() ar.frames = ar.frames + 1 end
  local finds = 0
  env.peripheral.find = function(kind)
    assert(kind == "ar_controller")
    finds = finds + 1
    if present then return ar end
  end
  local module = env.dofile("so-mod-ar.lua")
  return { tick = module.tick, ar = ar, mods = mods, env = env, machines = machines,
    finds = function() return finds end }
end
return function(test, equal)
  test("AR fleet frame has turtle labels, reservation outlines and drop labels", function()
    local b = boot(true)
    b.tick(1000)
    equal(b.ar.frames, 1)
    equal(b.ar.elements["turtle:2"][8], "#2")
    equal(b.ar.elements["turtle:3"][8], "#3")
    equal(b.ar.elements["drop:ore"][8], "O")
    equal(b.ar.elements["turtle:2"][1], 0xFF2DD4BF - 2^32)
    equal(b.ar.elements["turtle:3"][1], 0xFFFF6B5E - 2^32)
    for _, owner in ipairs({ "mine:2", "lumber:3" }) do
      for i = 1, 12 do assert(b.ar.elements["lease:" .. owner .. ":" .. i]) end
    end
    assert(b.ar.elements["alert:drops.alert"])
    equal(b.ar.clears, 1)
  end)
  test("AR layer switches delete outlines on the next frame and persist", function()
    local b = boot(true)
    b.tick(1000)
    b.env.input({ id = "leases" })
    b.tick(2000)
    for i = 1, 12 do assert(b.ar.deleted["lease:mine:2:" .. i]) end
    assert(b.ar.elements["turtle:2"])
    equal(b.env.SO.store.store("so-data/ar", function() return true end).value.leases, false)
  end)
  test("AR throttles frames and discovery and skips unchanged scenes", function()
    local b = boot(true)
    b.tick(1000)
    b.machines[2].fuel = 399
    b.tick(1500)
    equal(b.ar.frames, 1)
    b.tick(2000)
    equal(b.ar.frames, 2)
    b.tick(3000)
    equal(b.ar.frames, 2)
    equal(b.finds(), 1)
    b.tick(6000)
    equal(b.finds(), 2)
    equal(b.ar.frames, 3)
    equal(b.ar.elements["alert:drops.alert"], nil)
    b.tick(7000)
    equal(b.ar.frames, 3)
  end)
  test("AR without a controller loads and ticks without drawing", function()
    local b = boot(false)
    b.tick(1000) b.tick(2000) b.tick(6000)
    equal(b.ar.calls, 0)
    equal(b.ar.frames, 0)
    equal(b.finds(), 2)
  end)
  test("AR drops a failing controller and rediscovers it later", function()
    local b = boot(true)
    b.ar.fail = true
    assert(pcall(b.tick, 1000))
    local calls = b.ar.calls
    b.tick(2000)
    equal(b.ar.calls, calls)
    b.ar.fail = false
    b.tick(6000)
    equal(b.ar.frames, 1)
  end)
  test("cells.list and drops.list return detached copies", function()
    local b = boot(false)
    local list = b.mods.cells.list("mine:2")
    equal(list[1].x, -17)
    equal(list[1].dim, "minecraft:overworld")
    list[1].x = 500
    equal(b.mods.cells.list("mine:2")[1].x, -17)
    equal(#b.mods.cells.list("mine:2", 0), 0)
    local drops = b.mods.drops.list()
    equal(drops[1].broken, false)
    drops[1].x = 500
    equal(b.mods.drops.list()[1].x, 5)
    for i = 1, 3 do b.mods.drops.note("ore") end
    equal(b.mods.drops.list()[1].broken, true)
  end)
  test("AR filters dimensions, ages turtles and limits alerts to the newest eight", function()
    local b = boot(true)
    b.env.SO.store.read = function() return { pos = { dim = "minecraft:overworld" } } end
    local values, entries = {}, {}
    for i = 1, 10 do
      local key = "test" .. i .. ".alert"
      values[key] = { text = "alert " .. i }
      entries[i] = { kind = key, seq = i }
    end
    b.mods.state.view = setmetatable({}, { __call = function() return { values = values } end })
    b.mods.state.history = { page = function(q)
      local out = {}
      for _, event in ipairs(entries) do if event.seq > q.from then out[#out + 1] = event end end
      return { entries = out }
    end }
    b.machines[3].pose.dim = "minecraft:the_nether"
    b.mods.ar = b.env.dofile("so-mod-ar.lua")
    b.mods.ar.tick(121001)
    equal(b.ar.elements["turtle:2"][1], 0xFF7886A3 - 2^32)
    equal(b.ar.elements["turtle:3"], nil)
    assert(b.ar.elements["drop:ore"])
    equal(b.ar.elements["lease:lumber:3:1"] ~= nil, true)
    equal(b.ar.elements["alert:test1.alert"], nil)
    equal(b.ar.elements["alert:test10.alert"][3], 75)
    entries[11] = { kind = "test1.alert", seq = 11 }
    b.mods.ar.tick(122001)
    equal(b.ar.elements["alert:test1.alert"][3], 75)
  end)
  test("display takes the AR role only from the server command and retains it", function()
    local b = boot(false)
    local display = b.env.dofile("so-mod-display.lua")
    display.screen("generic", function() return { rows = {}, buttons = {} } end, function() end)
    display.screen("ar", b.env.render or function() return { rows = {}, buttons = {} } end, function() end)
    display.handlers.hello({ from = 9, body = { w = 40, h = 20 } })
    local frame
    local function get() display.handlers["view.get"]({ from = 9 }, function(_, got) frame = got end) end
    assert(display.assign(9, "drops"))
    get()
    for _, button in ipairs(frame.buttons) do assert(button.id ~= "ar") end
    display.handlers.input({ from = 9, body = { id = "ar", x = 8, y = 1 } })
    get()
    equal(frame.role, "generic")
    assert(display.assign(9, "ar"))
    get()
    equal(frame.role, "ar")
    display = b.env.dofile("so-mod-display.lua")
    display.screen("ar", function() return { rows = {}, buttons = {} } end, function() end)
    get()
    equal(frame.role, "ar")
  end)
  test("AR removes departed turtles and clears on attach and falls back to clear without delete", function()
    local b = boot(true)
    b.tick(1000)
    b.machines[2] = nil
    b.tick(2000)
    assert(b.ar.deleted["turtle:2"])
    b.ar.delete = nil
    b.machines[3].fuel = 1
    b.tick(3000)
    equal(b.ar.clears, 2)
    equal(b.ar.frames, 3)
  end)
end
