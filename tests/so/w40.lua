local H = dofile("tests/so/harness.lua")
local P = dofile("so-plan.lua")
local key = string.rep("a", 64)
local function libs(m)
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path, "rb"))
    m.files[path] = f:read("*a")
    f:close()
  end
end
local function setup()
  local net = H.new()
  local server = net.machine({ id = 1, modem = true })
  server.install({ "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-mod-lease.lua" })
  libs(server)
  server.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["2"] = key } } })
  server.boot("so-server.lua")
  assert(server.alive(), tostring(server.error))
  local worker = net.machine({ id = 2, modem = true, turtle = true, capacity = 1000000 })
  worker.install({ "worker.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" })
  libs(worker)
  worker.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["1"] = key } } })
  worker.boot("worker.lua")
  net.flush()
  assert(worker.alive(), tostring(worker.error))
  return net, server, worker, server.env.SO.mods.lease
end
local function sent(m, kind)
  local out = {}
  for _, wire in ipairs(m.sent) do
    if type(wire.payload) == "table" and wire.payload.t == kind then out[#out + 1] = wire.payload end
  end
  return out
end
local function batch(net, server, worker, lease, steps, opts)
  local n = #sent(worker, "step.report")
  local id = assert(lease.send(2, steps, opts))
  net.advance(1)
  assert(not worker.error, tostring(worker.error))
  assert(not server.error, tostring(server.error))
  local reports = sent(worker, "step.report")
  assert(#reports == n + 1, "report missing")
  return reports[#reports].body, id
end
return function(test, equal)
  test("W40 blocked batch reports actual pose, inventory, fuel and dug cells", function()
    local net, server, worker, lease = setup()
    worker.inv[1] = { name = "minecraft:coal", count = 3 }
    net.world["0,0,-1"] = "minecraft:stone"
    net.world["0,0,-2"] = "minecraft:bedrock"
    local steps = { { op = "dig" }, { op = "forward" }, { op = "forward" }, { op = "turnRight" }, { op = "forward" } }
    local record
    lease.onReport("facts", function(_, _, _, r) record = r end)
    local body = batch(net, server, worker, lease, steps, { owner = "facts" })
    equal(body.pose, { x = 1, y = 0, z = -1, f = 1 })
    equal(P.replay({ x = 0, y = 0, z = 0, f = 0 }, steps, body.results), body.pose)
    equal(body.results[3].ok, false)
    equal(body.fuel, 998)
    equal(body.inv, { { slot = 1, name = "minecraft:coal", count = 3 } })
    equal(body.dug, { { x = 0, y = 0, z = -1 } })
    equal(record.report, { pose = body.pose, fuel = body.fuel, inv = body.inv, dug = body.dug, journal = body.journal })
    equal(lease.status(2).pose, body.pose)
    equal(lease.status(2).journal, body.journal)
    equal(lease.status(2).poseAt, record.expires - 60000 + 250)
  end)
  test("W40 recovery sends to a beaconing worker and its report clears lost", function()
    local net, server, worker, lease = setup()
    batch(net, server, worker, lease, { { op = "forward" } }, { ms = 1200 })
    net.advance(1)
    equal(lease.status(2).lost, true)
    local beacon = sent(worker, "beacon")[1].body
    equal(beacon.pose, { x = 0, y = 0, z = -1, f = 0 })
    equal(lease.status(2).pose, beacon.pose)
    local id, reason = lease.send(2, { { op = "inspectDown" } })
    assert(id == nil)
    equal(reason, "lost")
    local recover = assert(lease.send(2, { { op = "turnRight" } }, { recover = true }))
    id, reason = lease.send(2, { { op = "forward" } }, { recover = true })
    equal(reason, "busy")
    net.advance(1)
    equal(lease.status(2).lost, false)
    equal(sent(worker, "step.report")[2].body.lease, recover)
  end)
  test("W40 sixteen ore inspects retain eight selected tags in one envelope", function()
    local net, server, worker, lease = setup()
    local tags = { ["c:ores"] = true, ["forge:ores"] = true, ["c:ores/copper"] = true,
      ["forge:ores/copper"] = true, ["minecraft:logs"] = true, ["minecraft:leaves"] = true,
      ["c:chests"] = true, ["forge:chests"] = true, ["unrelated:tag"] = true }
    net.world["0,0,-1"] = { name = "example:modded_ore", tags = tags, state = { level = 0 } }
    for slot = 1, 16 do worker.inv[slot] = { name = "example:inventory_item", count = 64 } end
    local journal = { id = "2-32", seq = 32, pose = { x = 0, y = 0, z = 0, f = 0 }, moves = {}, dug = {} }
    for i = 1, 32 do journal.dug[i] = { x = i, y = -64, z = -i } end
    worker.files["so-journal"] = H.encode({ schema = 1, generation = 1, value = journal })
    worker.co = nil
    worker.boot("worker.lua")
    net.flush()
    local steps = {}
    for i = 1, 16 do steps[i] = { op = "inspect" } end
    local body = batch(net, server, worker, lease, steps)
    for _, result in ipairs(body.results) do
      local expected = {}
      for tag in pairs(tags) do if tag ~= "unrelated:tag" then expected[tag] = true end end
      equal(result.data, { name = "example:modded_ore", tags = expected, level = 0 })
    end
    local report = sent(worker, "step.report")[1]
    assert(server.env.SO.proto.encode(report), "report exceeds protocol limit")
    assert(#H.encode(report) <= 16384, "serialized envelope exceeds limit")
  end)
  test("W40 long ore tags fit a full inventory and dug journal", function()
    local net, server, worker, lease = setup()
    local journal = { id = "2-32", seq = 32, pose = { x = 0, y = 0, z = 0, f = 0 }, moves = {}, dug = {} }
    for i = 1, 32 do journal.dug[i] = { x = i, y = -64, z = -i } end
    worker.files["so-journal"] = H.encode({ schema = 1, generation = 1, value = journal })
    for slot = 1, 16 do worker.inv[slot] = { name = "example:item", count = 64 } end
    worker.co = nil
    worker.boot("worker.lua")
    net.flush()
    local tags, steps = { ["c:ores"] = true }, {}
    for i = 1, 7 do tags["c:ores/" .. string.rep("x", 100) .. i] = true end
    net.world["0,0,-1"] = { name = "example:ore", tags = tags }
    for i = 1, 16 do steps[i] = { op = "inspect" } end
    local body = batch(net, server, worker, lease, steps)
    equal(#body.inv, 16)
    equal(#body.dug, 32)
    for _, result in ipairs(body.results) do equal(result.data.tags["c:ores"], true) end
    local report = sent(worker, "step.report")[1]
    assert(server.env.SO.proto.encode(report), "long tags exceeded envelope")
    assert(server.env.SO.proto.macOk(key, report), "trimmed report MAC")
  end)
  test("W40 inspect caps selected tags and keeps broad ore membership", function()
    local net, server, worker, lease = setup()
    local tags = { ["c:ores"] = true, ["unrelated:ore"] = true }
    for i = 1, 12 do tags["forge:ores/variant" .. i] = true end
    net.world["0,0,-1"] = { name = "example:ore", tags = tags, state = { level = "bad" } }
    local body = batch(net, server, worker, lease, { { op = "inspect" } })
    local data, n = body.results[1].data, 0
    for tag in pairs(data.tags) do
      assert(tag == "c:ores" or tag:match("^forge:ores/"), tag)
      n = n + 1
    end
    equal(n, 8)
    equal(data.tags["c:ores"], true)
    assert(data.level == nil)
  end)
  test("W40 lease drops bad fact fields and keeps valid siblings", function()
    local net, server, worker, lease = setup()
    worker.co = nil
    local record
    lease.onReport("facts", function(_, _, _, r) record = r end)
    local id = assert(lease.send(2, { { op = "forward" } }, { owner = "facts" }))
    lease.handlers["step.report"]({ from = 2, body = { lease = id, results = { { ok = false } },
      pose = { x = 1, y = 2, z = 3, f = "bad" }, journal = "journal", fuel = "bad",
      inv = { { slot = 1, name = "coal", count = 2 } }, dug = { false } } })
    equal(record.report, { journal = "journal", inv = { { slot = 1, name = "coal", count = 2 } } })
    net.advance(1)
    lease.handlers.hello({ from = 2, body = { journal = { id = "hello", pose = { x = 9, y = 8, z = 7, f = 2 } } } })
    equal(lease.status(2).pose, { x = 9, y = 8, z = 7, f = 2 })
    equal(lease.status(2).journal, "hello")
    equal(lease.status(2).poseAt, net.time)
  end)
  test("W40 changed journal never reuses a pose from another journal", function()
    local net, _, worker, lease = setup()
    worker.co = nil
    local pose = { x = 3, y = 4, z = 5, f = 1 }
    lease.handlers.hello({ from = 2, body = { journal = { id = "A", pose = pose } } })
    local at = lease.status(2).poseAt
    net.advance(1)
    lease.handlers.beacon({ from = 2, body = { journal = "A", pose = false } })
    equal(lease.status(2).pose, pose)
    equal(lease.status(2).poseAt, at)
    lease.handlers.beacon({ from = 2, body = { journal = "B", pose = false } })
    equal(lease.status(2).journal, "B")
    assert(lease.status(2).pose == nil)
    assert(lease.status(2).poseAt == nil)
    lease.handlers.hello({ from = 2, body = { journal = { id = "C", pose = pose } } })
    equal(lease.status(2).pose, pose)
    equal(lease.status(2).poseAt, net.time)
  end)
  test("W40 pair retry during a new code returns cached ack without a miss", function()
    local net, server, worker = setup()
    worker.co = nil
    server.env.os.queueEvent("key", 25, false)
    net.flush()
    local code = assert(table.concat(server.log, "\n"):match("Pair code: (%d%d%d%d%d%d)"))
    local client = net.machine({ id = 3, modem = true })
    client.install({ "so-proto.lua", "so-pair.lua", "so-store.lua" })
    libs(client)
    client.spawn(string.format([[proto = dofile("so-proto.lua")
      pair = dofile("so-pair.lua")
      pair.open(proto, dofile("so-store.lua"))
      assert(pair.join(%q, 1))]], code))
    net.flush()
    assert(not client.error, tostring(client.error))
    local request = sent(client, "pair")[1]
    local ack = sent(server, "ack")
    ack = ack[#ack]
    server.env.os.queueEvent("key", 25, false)
    net.flush()
    local before = #sent(server, "ack")
    client.env.rednet.send(1, client.env.proto.encode(request), "so")
    net.flush()
    equal(#sent(server, "ack"), before + 1)
    equal(sent(server, "ack")[before + 1], ack)
    for _, line in ipairs(server.log) do assert(not line:find("bad mac", 1, true), line) end
    -- Four invalid messages leave the pending code alive only if the retry did not count.
    for _ = 1, 4 do
      local bad = client.env.proto.build(string.rep("b", 64), "pair", {})
      client.env.rednet.send(1, client.env.proto.encode(bad), "so")
      net.flush()
    end
    assert(server.env.SO.pair.pending(), "retry consumed a bad-MAC allowance")
  end)
  test("W40 fake chests transfer items and fuel uses item values", function()
    local net, server, worker, lease = setup()
    local chest = { name = "minecraft:chest", inv = { { name = "minecraft:coal_block", count = 3 } } }
    net.world["0,-1,0"] = chest
    local body = batch(net, server, worker, lease, {
      { op = "suckDown", n = 2 }, { op = "refuel", n = 1 }, { op = "dropDown", n = 1 }, { op = "forward" },
    })
    equal(body.fuel, 1799)
    equal(body.inv, {})
    equal(chest.inv[1].count, 1)
    equal(chest.inv[2], { name = "minecraft:coal_block", count = 1 })
  end)
  test("W40 frames round trip in all rotations", function()
    for rot = 0, 3 do
      local journal = { x = 5, y = -4, z = 8, f = 1 }
      local world = { dim = "minecraft:nether", x = 32, y = 70, z = -21, facing = (1 + rot) % 4 }
      local frame = P.frame(world, journal)
      equal(frame.rot, rot)
      equal(P.toWorld(frame, journal), world)
      local other = { x = -9, y = 7, z = 3, f = 3 }
      equal(P.toJournal(frame, P.toWorld(frame, other)), other)
    end
  end)
  test("W40 planner paths, chunks, range, parking and inventory helpers", function()
    local from = { dim = "minecraft:overworld", x = 0, y = 0, z = 0, facing = 0 }
    local path = P.path(from, { x = 2, y = 1, z = -1 }, { dig = true })
    equal(path.pose.x, 2)
    equal(path.pose.y, 1)
    equal(path.pose.z, -1)
    equal(#path.cells, 4)
    equal(path.steps[1].op, "digUp")
    equal(path.steps[2].op, "up")
    local results = {}
    for i = 1, #path.steps do results[i] = { ok = true } end
    equal(P.replay(from, path.steps, results), path.pose)
    local first, rest = P.chunk(path.steps, 3)
    equal(#first, 3)
    equal(#rest, #path.steps - 3)
    equal(P.inRange(nil, 2, path.cells), true)
    equal(P.inRange({}, 2, path.cells), true)
    equal(P.inRange({ inRange = function(id, cell) return id == 2 and cell.x < 2 end }, 2, path.cells), false)
    equal(P.park, { steps = { { op = "inspectDown" } }, ms = 600000 })
    equal(P.fuelValue("minecraft:coal"), 80)
    equal(P.fuelValue("minecraft:charcoal"), 80)
    equal(P.fuelValue("minecraft:coal_block"), 800)
    equal(P.fuelValue("minecraft:lava_bucket"), 1000)
    equal(P.fuelValue("minecraft:blaze_rod"), 120)
    equal(P.fuelValue("minecraft:dirt"), 0)
    equal(P.free({ { slot = 3, name = "coal", count = 1 } }), 15)
    for facing = 0, 3 do
      local p = { x = 1, y = 2, z = 3, f = facing }
      for _, op in ipairs({ "forward", "back", "up", "down" }) do
        local x, y, z = P.ahead(p, op)
        local moved = P.apply(p, op)
        equal({ moved.x, moved.y, moved.z }, { x, y, z })
      end
      equal(P.apply(P.apply(p, "turnLeft"), "turnRight"), p)
    end
    local custom = P.path(from, { x = 0, y = -1, z = 1 }, { order = "zxy" })
    equal(custom.steps[1].op, "turnRight")
    equal(custom.steps[#custom.steps].op, "down")
  end)
end
