local H = dofile("tests/so/harness.lua")
local P = dofile("so-plan.lua")
local M = dofile("so-mine-plan.lua")
local DIM = "minecraft:overworld"
local FILES = { "so-server.lua", "so-store.lua", "so-mod-state.lua", "so-pair.lua", "so-proto.lua",
  "so-mod-lease.lua", "so-mod-cells.lua", "so-mod-display.lua", "so-mod-drops.lua", "so-mod-mine.lua",
  "so-mine-plan.lua", "so-plan.lua" }
local function tree(machine)
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local file = assert(io.open(path))
    machine.files[path] = file:read("*a") file:close()
  end
end
local function miners(equal, bottom, supplyBlock)
  local net = H.new()
  local server = net.machine({ id = 1, modem = true })
  server.install(FILES) tree(server)
  server.files["so-server.cfg"] = H.encode({ pos = { dim = DIM, x = 0, y = 64, z = 0 } })
  server.boot("so-server.lua") net.flush()
  local input
  local display, cells, lease = server.env.SO.mods.display, server.env.SO.mods.cells, server.env.SO.mods.lease
  local screen = display.screen
  display.screen = function(role, render, handler)
    if role == "mining" then input = handler end
    return screen(role, render, handler)
  end
  server.env.SO.mods.mine.tick()
  local function command(text) input({ text = text }) end
  local workers, reached, clipped, blocked, loaded, obstructed, drained = {}, {}, 0, false, false, false, false
  local realRange = lease.inRange
  if supplyBlock then
    lease.inRange = function(id, pose) return (id ~= 5 or pose.x ~= -5 or pose.z ~= 5 or pose.y >= 64) and realRange(id, pose) end
    net.world["-4,64,4"] = { name = "minecraft:chest", inv = {} }
    assert(server.env.SO.mods.drops.add({ id = "ore", dim = 0, x = -4, y = 64, z = 4, side = "front", kind = "ore" }))
  end
  local transmit = lease.send
  lease.send = function(id, steps, opts)
    if supplyBlock and id == 4 and reached[4] and not blocked then return nil, "waiting for shaft blocker" end
    local at = workers[id] and workers[id].pos
    local descending = at and #steps < math.min(16, at.y - bottom)
    for _, step in ipairs(steps) do descending = descending and step.op == "down" end
    if descending then
      clipped = clipped + 1
      local row = server.env.SO.store.read("so-data/mine/job").value.turtles[tostring(id)]
      assert(row.lane and #row.lane.cells > #steps, "cut descent lost its full lane pass")
      for _, cell in ipairs(row.lane.cells) do
        equal(cells.owner(cell.x, cell.y, cell.z, cell.dim), "mine:" .. id)
      end
    end
    if opts.owner == "mine" and at then
      local pose = { dim = DIM, x = at.x, y = at.y, z = at.z, facing = workers[id].heading }
      for _, step in ipairs(steps) do
        pose = P.apply(pose, step.op)
        assert(lease.inRange(id, pose), "dispatched a step outside proven range")
      end
    end
    return transmit(id, steps, opts)
  end
  for _, start in ipairs({ { id = 4, x = -5, f = 2 }, { id = 5, x = -7, f = 0 } }) do
    local key = string.rep("a", 64)
    assert(server.env.SO.pair.remember(start.id, key))
    local worker = net.machine({ id = start.id, modem = true, turtle = true, x = start.x, y = 64, z = 3,
      facing = start.f, fuel = 10000, capacity = 1000000, actionSeconds = 0.05 })
    workers[start.id] = worker
    worker.install({ "worker.lua", "so-store.lua", "so-pair.lua", "so-proto.lua" }) tree(worker)
    worker.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["1"] = key } } })
    worker.boot("worker.lua") net.flush()
    command("add " .. start.id .. " " .. start.x .. " 64 3 " .. (start.f == 2 and "s" or "n"))
    net.advance(1)
    for _, op in ipairs({ "up", "down", "forward", "back" }) do
      local move = worker.env.turtle[op]
      worker.env.turtle[op] = function()
        local before = worker.pos
        if supplyBlock == "obstructed" and worker.id == 5 and blocked and not obstructed
            and before.x == -5 and before.y == 64 and before.z == 5 then
          local target = P.apply({ dim = DIM, x = before.x, y = before.y, z = before.z, facing = worker.heading }, op)
          if target.y == 64 and (target.x ~= -5 or target.z ~= 5) then
            net.world[target.x .. "," .. target.y .. "," .. target.z] = "minecraft:stone"
            obstructed = true
            return false, "Movement obstructed"
          end
        end
        local ok, err = move()
        if ok then
          local p = worker.pos
          if supplyBlock == "fuel-short" and worker.id == 5 and p.x == -5 and p.y == 64 and p.z == 5 then
            worker.fuel = 1
          elseif supplyBlock == "fuel" and worker.id == 5 and blocked and not drained
              and (p.x ~= -5 or p.y ~= 64 or p.z ~= 5) then
            worker.fuel, drained = 0, true
          end
          equal(cells.owner(p.x, p.y, p.z, DIM), "mine:" .. worker.id)
          for id, other in pairs(workers) do
            if id ~= worker.id then
              assert(p.x ~= other.pos.x or p.y ~= other.pos.y or p.z ~= other.pos.z, "workers collided")
            end
          end
          if p.y == bottom and p.x ~= -5 then
            reached[worker.id] = true
          end
        end
        return ok, err
      end
    end
  end
  command("home -5 64 4 s") command("bottom " .. bottom) command("length 16")
  for y = bottom, 63 do net.world["-5," .. y .. ",5"] = "minecraft:stone" end
  command("start")
  local stalled, worst, tripAt, supplied, tripMs = {}, 0, nil, false, nil
  for _ = 1, 1200 do
    net.advance(0.25)
    assert(not server.error, tostring(server.error))
    local job = server.env.SO.store.read("so-data/mine/job").value
    for id, worker in pairs(workers) do
      assert(not worker.error, tostring(worker.error))
      local row = job.turtles[tostring(id)]
      stalled[id] = row.state == "range" and (stalled[id] or 0) + 1 or 0
      worst = math.max(worst, stalled[id])
      if not supplyBlock or id ~= 5 then
        assert(stalled[id] <= 3, "miner " .. id .. " stuck in range at " .. row.pose.y)
      elseif row.state == "range" or supplyBlock == "fuel-short" and row.state == "hold" then
        if not blocked then equal({ row.pose.x, row.pose.y, row.pose.z }, { -5, 64, 5 }) end
        blocked = true
        if not loaded and supplyBlock ~= "fuel-short" then
          for slot = 1, 15 do workers[4].inv[slot] = { name = "minecraft:raw_iron", count = 1 } end
          loaded = true
        end
      end
    end
    if supplyBlock == "fuel-short" then
      local peer = job.turtles["5"]
      if peer.yield and peer.yield.stage == "wait" then
        equal({ peer.pose.x, peer.pose.y, peer.pose.z }, { -5, 64, 5 })
        equal(workers[5].fuel, 1)
        assert(not peer.lane and not peer.laneWait, "fuel hold retained the full lane")
        equal(#cells.list("mine:5"), 1)
        print("range-batch: escape requires fuel for the return and keeps only the occupied cell")
        return
      end
    elseif supplyBlock then
      local row = job.turtles["4"]
      if row.trip then tripAt = tripAt or net.time end
      if tripAt then assert(net.time - tripAt < 120000, "ore trip stuck behind the range-blocked miner") end
      supplied = #net.world["-4,64,4"].inv >= 15 and not row.trip
      if supplied then
        tripMs = net.time - tripAt
        local peer = job.turtles["5"]
        assert(peer.yield and peer.yield.stage == "wait", "blocked miner did not wait outside the lane")
        assert(not M.inLane(job, peer.pose) and not peer.lane and not peer.laneWait, "blocked miner retained lane priority")
        break
      end
    elseif reached[4] and reached[5] then break end
  end
  if supplyBlock then
    assert(blocked and supplied, "range-blocked peer prevented the ore trip")
    lease.inRange = realRange
    if supplyBlock == "obstructed" then assert(obstructed, "escape obstruction was not exercised") end
    if supplyBlock == "fuel" then
      assert(drained, "escape did not drain fuel at the refuge")
      net.advance(5)
      local peer = server.env.SO.store.read("so-data/mine/job").value.turtles["5"]
      assert(peer.yield and peer.yield.stage == "wait" and not peer.lane and not peer.laneWait,
        "worker without return fuel reacquired the lane")
      equal(#cells.list("mine:5"), 1)
      workers[5].fuel = 10000
      assert(lease.cancelPark(5, "mine"))
      assert(lease.send(5, { { op = "inspectDown" } }, { owner = "mine", pose = peer.pose }))
      net.flush()
    end
    for _ = 1, 1200 do
      net.advance(0.25)
      assert(not server.error, tostring(server.error))
      for _, worker in pairs(workers) do assert(not worker.error, tostring(worker.error)) end
      if reached[5] then break end
    end
    print("range-batch C7: ore trip completed in " .. tripMs / 1000 .. "s past blocked miner; miner resumed after range restored")
  end
  assert(reached[4] and reached[5], "both miners must reach their branches")
  if bottom < 48 then assert(clipped > 0, "known shaft descent did not exercise a cut batch") end
  if not supplyBlock then
    print("range-batch bottom " .. bottom .. ": both branches reached; max range ticks " .. worst .. "; cut descents " .. clipped)
  end
end

return function(test, equal)
  test("range-batch Gate B C5 two miners reach their branches", function() miners(equal, 48) end)
  test("range-batch two miners extend range down a deep known shaft", function() miners(equal, 16) end)

  test("range-batch C7 blocked shaft worker yields for an ore trip and resumes", function() miners(equal, 48, true) end)

  test("range-batch C7 replans an obstructed escape for an ore trip", function() miners(equal, 48, "obstructed") end)
  test("range-batch C7 waits for return fuel before reacquiring the lane", function() miners(equal, 48, "fuel") end)
  test("range-batch retreat keeps fuel for its return", function() miners(equal, 48, "fuel-short") end)

  test("range-batch supply travel extends proof in both directions", function()
    local job = { dim = DIM, home = { x = 0, y = 64, z = 0, facing = 0 }, bottom = 16,
      mode = "thorough", length = 16, turtles = { { branch = 0 } } }
    local route = M.route(job, 0)
    local row = { pose = route[#route], route = route, index = #route + 1, branch = 0 }
    local stand = { dim = DIM, x = -2, y = 64, z = 0 }
    local path = assert(M.supplyRoute(job, row, stand))
    row.trip = { path = path, back = row.pose, stand = stand, stage = "out", shared = true }
    local origin, radius = row.pose, 16
    local lease = { inRange = function(_, p) return M.distance(origin, p) <= radius + 8 end }
    local cuts = 0
    for _, stage in ipairs({ "out", "back" }) do
      row.trip.stage = stage row.goal = stage == "out" and stand or row.trip.back
      for _ = 1, 300 do
        if M.same(row.pose, row.goal) then break end
        local proposed = M.next(job, row, function() return false end, {}, 4000)
        local action = assert(P.rangeBatch(lease, 4, proposed), "supply range deadlock")
        if #action.steps < #proposed.steps then cuts = cuts + 1 end
        assert(P.inRange(lease, 4, action.cells))
        row.pose = action.pose
        radius = math.max(radius, M.distance(origin, row.pose))
      end
      assert(M.same(row.pose, row.goal), "supply trip did not reach " .. stage)
    end
    assert(cuts > 0, "supply trip never cut a batch")
  end)

  test("range-batch lumber supply crosses the initial radius and returns", function()
    local fixture = dofile("tests/so/lumber-fixture.lua")()
    local job, radius = fixture.job, 16
    local function distance(p) return math.sqrt(p.x * p.x + (p.y - 2) ^ 2 + p.z * p.z) end
    fixture.mods.lease.inRange = function(_, p) return distance(p) <= radius + 8 end
    fixture.mods.cells.reserveMany = function(_, cells)
      assert(P.inRange(fixture.mods.lease, 2, cells), "lumber reserved an unsafe work cell")
      return true
    end
    job.service = { kind = "wood", stage = "travel", resume = "waiting",
      point = { x = 60, y = 1, z = 0, side = "down" },
      back = { dim = DIM, x = 0, y = 2, z = 0, facing = 1 } }
    local arrived = false
    for tick = 1, 800 do
      fixture.tick(tick)
      local queued = fixture.queued()
      if queued then
        local results = {}
        for i, step in ipairs(queued.steps) do
          results[i] = { ok = not step.op:match("^inspect") }
        end
        fixture.report(false, results)
        radius = math.max(radius, distance(job.turtle.pose))
      end
      assert(job.blocked == nil, tostring(job.alert))
      arrived = arrived or job.turtle.pose.x == 60
      if not job.service then break end
    end
    assert(arrived and not job.service, "lumber supply trip did not complete")
    equal(job.turtle.pose.x, 0)
    assert(radius >= 60, "lumber reports did not extend the range")
  end)

  test("range-batch a parked shaft cell does not block an unrelated spine pass", function()
    local top = { dim = DIM, x = -5, y = 64, z = 5, facing = 2 }
    local job = { dim = DIM, home = { x = -5, y = 64, z = 4, facing = 2 }, bottom = 48,
      mode = "thorough", length = 16, running = true, progress = { nextBranch = 2 }, turtles = {
        ["4"] = { pose = { dim = DIM, x = -6, y = 48, z = 9, facing = 1 }, fuel = 10000, inv = {}, branch = 1,
          route = { { dim = DIM, x = -5, y = 48, z = 9 }, { dim = DIM, x = -5, y = 48, z = 13 },
            { dim = DIM, x = -6, y = 48, z = 13 } }, index = 1 },
        ["5"] = { pose = top, fuel = 0, inv = {}, branch = 0,
          yield = { path = { top }, cursor = 0, stage = "wait", state = "hold", pass = {}, after = 60000 } },
      } }
    for _, row in pairs(job.turtles) do
      row.anchor = row.pose row.frame = { dim = DIM, rot = 0, ox = 0, oy = 0, oz = 0 }
    end
    local queued, callback = {}, nil
    local env = setmetatable({ os = { epoch = function() return 0 end },
      fs = { exists = function() return false end, makeDir = function() end, list = function() return {} end },
      SO = { store = { copy = dofile("so-store.lua").copy,
        store = function(path) return { value = path == "so-data/mine/job" and job or nil, save = function() return true end } end },
        mods = { state = { emit = function() end }, display = { screen = function() end }, lease = {
          inRange = function() return true end,
          status = function(id) return { open = queued[id] and id } end,
          onReport = function(_, fn) callback = fn end,
          send = function(id, steps, opts) queued[id] = { steps = steps, opts = opts } return id end,
        } } } }, { __index = _G })
    local cells = assert(loadfile("so-mod-cells.lua", "t", env))()
    env.SO.mods.cells = cells
    local mine = assert(loadfile("so-mod-mine.lua", "t", env))()
    mine.tick()
    for _, id in ipairs({ 4, 5 }) do
      local row, q = job.turtles[tostring(id)], assert(queued[id])
      queued[id] = nil
      callback(id, id, { { ok = false } }, { report = { pose = {
        x = row.pose.x, y = row.pose.y, z = row.pose.z, f = row.pose.facing }, fuel = row.fuel, inv = {} } })
      equal(q.steps[1].op, "inspectDown")
    end
    mine.tick()
    assert(queued[4], "stationary shaft worker prevented an unrelated spine lease")
    equal(queued[4].steps[1].op, "inspect")
    equal(cells.owner(-5, 48, 9, DIM), "mine:4")
    equal(cells.owner(top.x, top.y, top.z, DIM), "mine:5")
    assert(not job.turtles["5"].lane and not job.turtles["5"].laneWait)
  end)

  test("range-batch keeps atomic actions and stops at the first unsafe action", function()
    local lease = { inRange = function(_, p) return p.x <= 2 end }
    local move = { kind = "move", first = 1, steps = { { op = "forward" } }, cells = { { x = 2 } }, pose = { x = 2 } }
    local inspect = { kind = "inspect", first = 2, steps = { { op = "inspect" } }, cells = { { x = 3 } }, pose = { x = 2 } }
    local batch = { kind = "batch", actions = { move, inspect }, steps = { move.steps[1], inspect.steps[1] }, cells = { { x = 2 }, { x = 3 } } }
    local cut = assert(P.rangeBatch(lease, 4, batch))
    equal(cut.steps, move.steps) equal(cut.cells, move.cells) equal(cut.pose, move.pose)
    equal(#cut.actions, 1)
    equal(P.rangeBatch(lease, 4, inspect), nil)
    equal(P.rangeBatch({}, 4, batch), batch)
  end)
end
