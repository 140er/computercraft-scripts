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
local function miners(test, equal, bottom)
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
  local workers, reached, clipped = {}, {}, 0
  local transmit = lease.send
  lease.send = function(id, steps, opts)
    local at = workers[id] and workers[id].pos
    if at and #steps > 1 and steps[1].op == "down" and #steps < 16 then clipped = clipped + 1 end
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
        local ok, err = move()
        if ok then
          local p = worker.pos
          equal(cells.owner(p.x, p.y, p.z, DIM), "mine:" .. worker.id)
          for id, other in pairs(workers) do
            if id ~= worker.id then
              assert(p.x ~= other.pos.x or p.y ~= other.pos.y or p.z ~= other.pos.z, "workers collided")
            end
          end
          if p.y == bottom and p.x ~= -5 then reached[worker.id] = true end
        end
        return ok, err
      end
    end
  end
  command("home -5 64 4 s") command("bottom " .. bottom) command("length 16")
  for y = bottom, 63 do net.world["-5," .. y .. ",5"] = "minecraft:stone" end
  command("start")
  local stalled, worst = {}, 0
  for _ = 1, 1200 do
    net.advance(0.25)
    assert(not server.error, tostring(server.error))
    local job = server.env.SO.store.read("so-data/mine/job").value
    for id, worker in pairs(workers) do
      assert(not worker.error, tostring(worker.error))
      local row = job.turtles[tostring(id)]
      stalled[id] = row.state == "range" and (stalled[id] or 0) + 1 or 0
      worst = math.max(worst, stalled[id])
      assert(stalled[id] <= 3, "miner " .. id .. " stuck in range at " .. row.pose.y)
    end
    if reached[4] and reached[5] then break end
  end
  assert(reached[4] and reached[5], "both miners must reach their branches")
  if bottom < 48 then assert(clipped > 0, "known shaft descent did not exercise a cut batch") end
  print("range-batch bottom " .. bottom .. ": both branches reached; max range ticks " .. worst .. "; cut descents " .. clipped)
end

return function(test, equal)
  test("range-batch Gate B C5 two miners reach their branches", function() miners(test, equal, 48) end)
  test("range-batch two miners extend range down a deep known shaft", function() miners(test, equal, 16) end)

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
