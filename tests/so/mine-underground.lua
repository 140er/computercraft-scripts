-- Gate B C7 follow-up: miner 4 was removed and re-added where it stood on the
-- spine, after a server restart. Its new route started at the shaft top, so it
-- climbed a new column, then found no remembered route home. Fuel then always
-- looked low and every supply trip failed with "no known mine route".
local H = dofile("tests/so/harness.lua")
local FILES = { "so-server.lua", "so-store.lua", "so-mod-state.lua", "so-pair.lua", "so-proto.lua", "so-mod-lease.lua",
  "so-mod-cells.lua", "so-mod-display.lua", "so-mod-drops.lua", "so-mod-mine.lua", "so-mine-plan.lua", "so-plan.lua" }

local function tree(m)
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path)); m.files[path] = f:read("*a"); f:close()
  end
end

local function wire(server)
  local input, render
  local display = server.env.SO.mods.display
  local original = display.screen
  display.screen = function(role, r, i) if role == "mining" then input, render = i, r end return original(role, r, i) end
  server.env.SO.mods.mine.tick()
  return function(text) input({ text = text }) end, function() return render() end
end

local function row(server)
  return server.env.SO.store.read("so-data/mine/job").value.turtles["2"]
end

-- Records every cell the turtle stands in, including the ones inside a batch.
local function watch(turtle, seen)
  for _, op in ipairs({ "up", "down", "forward", "back" }) do
    local move = turtle.env.turtle[op]
    turtle.env.turtle[op] = function()
      local ok, err = move()
      if ok then seen[#seen + 1] = { x = turtle.pos.x, y = turtle.pos.y, z = turtle.pos.z } end
      return ok, err
    end
  end
end

-- The shaft column is 0,*,-1 and the surface is y = 0. Anything else between
-- the mine level and the surface is a new column cut towards the surface.
local function climbed(seen, bottom)
  for _, p in ipairs(seen) do
    if p.y > bottom and p.y < 0 and not (p.x == 0 and p.z == -1) then return p end
  end
end

local function setup()
  local net = H.new()
  local server = net.machine({ id = 1, modem = true })
  server.install(FILES) tree(server)
  server.files["so-server.cfg"] = H.encode({protectedAreas=false,alternateAxisOrders=false,storageDeliveries=false,workerPark=false,pos={dim="minecraft:overworld",x=0,y=0,z=0}})
  server.boot("so-server.lua") net.flush()
  assert(server.env.SO.mods.drops.add({id="ore",dim=0,x=100000,y=0,z=0,side="front",kind="ore"}))
  local input = wire(server)
  local key = string.rep("a", 64)
  assert(server.env.SO.pair.remember(2, key))
  local turtle = net.machine({ id = 2, modem = true, turtle = true, fuel = 4000, capacity = 1000000 })
  turtle.install({ "worker.lua", "so-store.lua", "so-pair.lua", "so-proto.lua" }) tree(turtle)
  turtle.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["1"] = key } } })
  turtle.boot("worker.lua") net.flush()
  input("add 2 0 0 0 n") net.advance(1)
  local chest = { name = "minecraft:chest", inv = { { name = "minecraft:coal", count = 64 } } }
  net.world["1,0,0"] = chest
  assert(server.env.SO.mods.drops.add({ id = "fuel", dim = 0, x = 1, y = 0, z = 0, side = "front", kind = "fuel" }))
  input("home 0 0 0 n") input("bottom -4") input("length 3")
  return net, server, turtle, input, chest
end

-- Restart the server with the turtle moved to pose (world frame = journal frame).
local function restart(net, server, turtle, pose, fuel)
  net.kill(server)
  local store = turtle.env.dofile("so-store.lua")
  local box = store.store("so-journal", function(v) return type(v) == "table" end, 16000)
  local saved = box.value
  saved.pose, saved.moves, saved.park, saved.pending = { x = pose.x, y = pose.y, z = pose.z, f = pose.f }, {}, nil, nil
  assert(box.save(saved))
  net.onBoot = function(m)
    if m.id == 2 then m.pos.x, m.pos.y, m.pos.z, m.heading, m.fuel = pose.x, pose.y, pose.z, pose.f, fuel end
  end
  turtle = net.boot(turtle) net.flush()
  net.onBoot = nil
  net.advance(5)
  assert(turtle.alive(), tostring(turtle.error))
  server = net.boot(server) net.flush()
  local input, render = wire(server)
  return server, turtle, input, render
end

return function(test, equal)
  test("mine-underground: a worker re-added on the spine after a restart mines its new branch", function()
    local net, server, turtle, input = setup()
    input("start")
    net.advance(100)
    equal({ turtle.pos.x, turtle.pos.y, turtle.pos.z }, { 3, -4, -5 })
    equal(row(server).state, "done")

    -- Gate B: the worker stood on the spine with fuel 120 when the server came
    -- back, and was removed and re-added there.
    local render
    server, turtle, input, render = restart(net, server, turtle, { x = 0, y = -4, z = -4, f = 2 }, 120)
    local seen = {}
    watch(turtle, seen)
    input("remove 2") net.advance(5)
    equal({ turtle.pos.x, turtle.pos.y, turtle.pos.z }, { 0, -4, -4 })
    input("add 2 0 -4 -4 s")
    for _=1,20 do
      net.advance(0.25)
      local current=row(server)
      if current and not current.recover and current.fuel then break end
    end
    assert(row(server).fuel and not row(server).recover,"re-added worker did not reconcile before START")
    input("start")
    net.advance(300)
    assert(not server.error, tostring(server.error))
    assert(not turtle.error, tostring(turtle.error))
    local up = climbed(seen, -4)
    assert(not up, up and ("worker cut a column at " .. up.x .. "," .. up.y .. "," .. up.z))
    local r = row(server)
    for _, line in ipairs(render().rows) do assert(not line.text:find("no known mine route", 1, true), line.text) end
    equal(r.branch, 1)
    equal(r.state, "done")
    equal({ turtle.pos.x, turtle.pos.y, turtle.pos.z }, { 3, -4, -9 })
  end)

  test("mine-underground: a worker in a side cell after a restart still plans and refuels", function()
    local net, server, turtle, input, chest = setup()
    input("length 6")
    local reached
    local forward = turtle.env.turtle.forward
    turtle.env.turtle.forward = function()
      local ok, err = forward()
      if ok and turtle.pos.z == -5 and turtle.pos.x == 2 then reached = true end
      return ok, err
    end
    input("start")
    for _ = 1, 100 do
      net.advance(1)
      if reached then break end
    end
    assert(reached, "worker did not reach its branch")
    local x = turtle.pos.x
    -- The server restarts while the worker stands one cell above its branch,
    -- as after following a vein upward. The in-memory block lookup is empty,
    -- so no remembered route connects it to the branch.
    local render
    server, turtle, input, render = restart(net, server, turtle, { x = x, y = -3, z = -5, f = 1 }, 40)
    local seen = {}
    watch(turtle, seen)
    net.advance(300)
    assert(not server.error, tostring(server.error))
    assert(not turtle.error, tostring(turtle.error))
    for _, line in ipairs(render().rows) do assert(not line.text:find("no known mine route", 1, true), line.text) end
    assert(chest.inv[1].count < 64, "worker did not refuel")
    assert(turtle.fuel > 1900, "fuel " .. tostring(turtle.fuel))
    local up = climbed(seen, -3)
    assert(not up, up and ("worker cut a column at " .. up.x .. "," .. up.y .. "," .. up.z))
    local r = row(server)
    equal(r.state, "done")
    equal({ turtle.pos.x, turtle.pos.y, turtle.pos.z }, { 6, -4, -5 })
  end)

  -- Gate B: progress.done rose 6 to 7 after a server restart with no new
  -- branch. Recovery put the finished row back to mining and it was counted
  -- again when it finished in place.
  test("mine-underground: a finished branch is counted once across restarts", function()
    local net, server, turtle, input = setup()
    local progress = {}
    local function listen(s)
      local emit = s.env.SO.mods.state.emit
      s.env.SO.mods.state.emit = function(kind, data)
        if kind == "mine.progress" then progress[#progress + 1] = data.branch end
        return emit(kind, data)
      end
    end
    listen(server)
    input("start")
    net.advance(100)
    local function job() return server.env.SO.store.read("so-data/mine/job").value end
    equal(job().turtles["2"].state, "done")
    equal(job().progress, { done = 1, nextBranch = 1 })
    local here = { x = turtle.pos.x, y = turtle.pos.y, z = turtle.pos.z, f = turtle.heading }

    server, turtle = restart(net, server, turtle, here, turtle.fuel)
    listen(server)
    net.advance(60)
    equal(job().turtles["2"].state, "done")
    equal(job().progress, { done = 1, nextBranch = 1 })

    -- A job saved before rows recorded their counted branch. restart() kills
    -- the server before it can save again.
    local box = server.env.SO.store.store("so-data/mine/job", function(v) return type(v) == "table" end)
    local saved = box.value
    saved.turtles["2"].counted, saved.turtles["2"].state = nil, "done"
    assert(box.save(saved))
    server, turtle = restart(net, server, turtle, here, turtle.fuel)
    listen(server)
    net.advance(60)
    assert(not server.error, tostring(server.error))
    equal(job().turtles["2"].state, "done")
    equal(job().progress, { done = 1, nextBranch = 1 })
    equal(progress, { 0 })
  end)
end
