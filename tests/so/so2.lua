local harness = dofile("tests/so/harness.lua")

local S = {
  sources = {
    "so-proto.lua", "so-pair.lua", "so-store.lua", "so-server.lua",
    "so-mod-state.lua", "so-mod-cells.lua", "so-mod-display.lua", "so-mod-drops.lua",
  },
  libs = {
    "lib/ccryptolib/x25519.lua",
    "lib/ccryptolib/random.lua",
    "lib/ccryptolib/blake3.lua",
    "lib/ccryptolib/chacha20.lua",
    "lib/ccryptolib/config.lua",
    "lib/ccryptolib/internal/util.lua",
    "lib/ccryptolib/internal/hw.lua",
    "lib/ccryptolib/internal/curve25519.lua",
    "lib/ccryptolib/internal/fp.lua",
    "lib/ccryptolib/internal/edwards25519.lua",
    "lib/ccryptolib/internal/packing.lua",
  },
}

S.installTree = function(machine)
  for i = 1, #S.libs do
    local path = S.libs[i]
    local handle = assert(io.open(path, "rb"))
    local data = handle:read("*a")
    handle:close()
    machine.files[path] = data
  end
end

S.sent = function(machine, kind)
  local out = {}
  for i = 1, #machine.sent do
    local payload = machine.sent[i].payload
    if type(payload) == "table" and payload.t == kind then out[#out + 1] = payload end
  end
  return out
end

S.boot = function(opts)
  opts = opts or {}
  local net = harness.new()
  local server = net.machine({ id = 1, capacity = 16000000, modem = true })
  server.install(S.sources)
  S.installTree(server)
  server.boot("so-server.lua")
  net.flush()
  assert(server.alive(), tostring(server.error))
  server.env.os.queueEvent("key", 25, false)
  net.flush()
  assert(not server.error, tostring(server.error))
  local code
  for i = 1, #server.log do
    code = server.log[i]:match("Pair code: (%d%d%d%d%d%d)")
    if code then break end
  end
  assert(code, "pair code missing")
  local turtle = net.machine({
    id = 2, capacity = 1000000, modem = true, turtle = true,
    x = opts.x or 0, y = opts.y or 0, z = opts.z or 0,
    facing = opts.facing or 0, fuel = opts.fuel or 1000,
  })
  turtle.install({ "worker.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" })
  S.installTree(turtle)
  turtle.files["so-code"] = code
  if opts.gps then
    local gps = opts.gps
    turtle.env.gps = { locate = function() return gps[1], gps[2], gps[3] end }
  end
  if opts.inv then
    for slot, item in pairs(opts.inv) do turtle.inv[slot] = { name = item.name, count = item.count } end
  end
  turtle.boot("worker.lua")
  net.flush()
  assert(not turtle.error, tostring(turtle.error))
  assert(not server.error, tostring(server.error))
  assert(turtle.alive(), "worker stopped")
  return net, server, turtle
end

S.lease = function(server, body)
  local key = assert(server.env.SO.pair.key(2), "no turtle key")
  local msg = server.env.SO.proto.build(key, "lease.batch", body)
  server.env.rednet.send(2, server.env.SO.proto.encode(msg), "so")
  return msg
end

S.wait = function(net, machine, kind, n, steps)
  for _ = 1, steps do
    if #S.sent(machine, kind) >= n then return end
    net.advance(0.05)
    assert(not machine.error, tostring(machine.error))
  end
  error("timed out waiting for " .. kind)
end

S.screen = function(turtle)
  local lines = {}
  for i = 1, 4 do lines[#lines + 1] = turtle.screen[i] or "" end
  return table.concat(lines, "\n")
end

S.journal = function(turtle)
  local raw = assert(turtle.files["so-journal"], "journal missing")
  return assert(turtle.env.textutils.unserialize(raw)).value
end

S.counts = function(a, b)
  return { a or 0, b or 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
end

S.reach = function(net, machine, at)
  if net.time < at then net.advance((at - net.time) / 1000) end
  assert(not machine.error, tostring(machine.error))
end

return function(test, equal)
  test("worker and its libraries fit in 100 KB", function()
    local names = { "worker.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" }
    local total = 0
    for i = 1, #names do
      local handle = assert(io.open(names[i], "rb"))
      total = total + #handle:read("*a")
      handle:close()
    end
    assert(total < 100000, "size " .. total)
  end)

  test("a batch of 16 steps reports the fake world", function()
    local net, server, turtle = S.boot({
      gps = { 3, 4, 5 },
      inv = {
        [1] = { name = "minecraft:cobblestone", count = 8 },
        [2] = { name = "minecraft:coal", count = 2 },
      },
    })
    local hello = S.sent(turtle, "hello")[1]
    equal(hello.body.role, "turtle")
    equal(hello.body.label, "m2")
    equal(hello.body.fuel, 1000)
    equal(hello.body.free, 14)
    equal(hello.body.gps, { x = 3, y = 4, z = 5 })
    equal(hello.body.inv, {
      { slot = 1, name = "minecraft:cobblestone", count = 8 },
      { slot = 2, name = "minecraft:coal", count = 2 },
    })
    equal(hello.body.journal.moves, {})
    assert(hello.body.journal.pending == nil)
    local screen = S.screen(turtle)
    assert(screen:find("lease -", 1, true), screen)
    assert(screen:find("step idle", 1, true), screen)
    assert(screen:find("fuel 1000", 1, true), screen)
    assert(screen:find("seen ", 1, true), screen)

    net.world["0,0,-1"] = "minecraft:stone"
    net.world["0,1,0"] = "minecraft:dirt"
    local full = S.counts(8, 2)
    local fueled = S.counts(8, 1)
    local placed = S.counts(7, 1)
    local dropped = S.counts(5, 1)
    S.lease(server, {
      lease = "wide",
      expires = net.time + 60000,
      steps = {
        { op = "inspect" },
        { op = "dig" },
        { op = "forward" },
        { op = "turnRight" },
        { op = "turnLeft" },
        { op = "inspectUp" },
        { op = "back" },
        { op = "digUp" },
        { op = "up" },
        { op = "down" },
        { op = "select", slot = 2 },
        { op = "refuel", n = 1 },
        { op = "select", slot = 1 },
        { op = "place" },
        { op = "drop", n = 2 },
        { op = "inspect" },
      },
    })
    S.wait(net, turtle, "step.report", 1, 80)
    local report = S.sent(turtle, "step.report")[1]
    equal(report.body.lease, "wide")
    local results = report.body.results
    equal(#results, 16)
    equal(results[1], { ok = true, data = { name = "minecraft:stone" }, counts = full })
    equal(results[2], { ok = true, counts = full })
    equal(results[3], { ok = true, counts = full })
    equal(results[4], { ok = true, counts = full })
    equal(results[5], { ok = true, counts = full })
    equal(results[6], { ok = false, err = "No block to inspect", counts = full })
    equal(results[7], { ok = true, counts = full })
    equal(results[8], { ok = true, counts = full })
    equal(results[9], { ok = true, counts = full })
    equal(results[10], { ok = true, counts = full })
    equal(results[11], { ok = true, counts = full })
    equal(results[12], { ok = true, counts = fueled })
    equal(results[13], { ok = true, counts = fueled })
    equal(results[14], { ok = true, counts = placed })
    equal(results[15], { ok = true, counts = dropped })
    equal(results[16], { ok = true, data = { name = "minecraft:cobblestone" }, counts = dropped })
    equal(turtle.pos.x, 0)
    equal(turtle.pos.y, 0)
    equal(turtle.pos.z, 0)
    equal(turtle.heading, 0)
    equal(turtle.fuel, 1076)
    equal(turtle.selected, 1)
    equal(net.world["0,0,-1"], "minecraft:cobblestone")
    assert(net.world["0,1,0"] == nil, "dirt remains")
    local journal = S.journal(turtle)
    equal(journal.pose, { x = 0, y = 0, z = 0, f = 0 })
    equal(#journal.moves, 6)
    equal(journal.moves[1].op, "forward")
    equal(journal.moves[6].op, "down")
    equal(#journal.dug, 2)
    assert(journal.pending == nil)
    screen = S.screen(turtle)
    assert(screen:find("lease wide", 1, true), screen)
    assert(screen:find("step idle", 1, true), screen)
    assert(screen:find("fuel 1076", 1, true), screen)
    assert(screen:find("seen %d+"), screen)
  end)

  test("lease expiry mid-batch stops at the next step", function()
    local net, server, turtle = S.boot()
    S.lease(server, {
      lease = "short",
      expires = net.time + 80,
      steps = {
        { op = "forward" }, { op = "forward" }, { op = "forward" }, { op = "forward" },
      },
    })
    net.advance(1)
    assert(not turtle.error, tostring(turtle.error))
    local report = S.sent(turtle, "step.report")
    equal(#report, 1)
    local results = report[1].body.results
    equal(results[1].ok, true)
    equal(results[2], { ok = false, err = "expired", counts = S.counts() })
    equal(results[3].err, "expired")
    equal(results[4].err, "expired")
    equal(turtle.pos.z, -1)
    equal(turtle.fuel, 999)
  end)

  test("a silent server gets 12 fast beacons, a 32-move return, then slow beacons", function()
    local net, server, turtle = S.boot()
    local function forwards(lease, expires)
      local steps = {}
      for i = 1, 16 do steps[i] = { op = "forward" } end
      S.lease(server, { lease = lease, expires = expires, steps = steps })
    end
    forwards("a", net.time + 100000)
    S.wait(net, turtle, "step.report", 1, 80)
    equal(turtle.pos.z, -16)
    forwards("b", net.time + 5000)
    S.wait(net, turtle, "step.report", 2, 80)
    equal(turtle.pos.z, -32)
    equal(turtle.fuel, 968)
    equal(#S.journal(turtle).moves, 32)
    S.wait(net, turtle, "beacon", 1, 200)
    local first = S.sent(turtle, "beacon")[1]
    equal(first.body.id, 2)
    equal(first.body.fuel, 968)
    assert(type(first.body.journal) == "string" and #first.body.journal > 0, "journal id")
    S.reach(net, turtle, first.at + 60000)
    local fast = S.sent(turtle, "beacon")
    equal(#fast, 12)
    equal(fast[12].at - fast[1].at, 55000)
    for i = 2, 12 do
      equal(fast[i].at - fast[i - 1].at, 5000, "beacon gap " .. i)
      equal(fast[i].body.journal, fast[1].body.journal)
    end
    equal(turtle.pos.z, -32)
    net.advance(2)
    assert(not turtle.error, tostring(turtle.error))
    equal(turtle.pos.z, 0)
    equal(turtle.heading, 0)
    equal(turtle.fuel, 936)
    equal(#S.journal(turtle).moves, 0)
    equal(#S.sent(turtle, "beacon"), 12)
    local screen = S.screen(turtle)
    assert(screen:find("step slow", 1, true), screen)
    assert(screen:find("lease b", 1, true), screen)
    net.advance(30)
    equal(#S.sent(turtle, "beacon"), 13)
    net.advance(30)
    equal(#S.sent(turtle, "beacon"), 14)
    local slow = S.sent(turtle, "beacon")
    equal(slow[14].at - slow[13].at, 30000)
  end)

  test("reboot mid-step puts the unfinished step on hello", function()
    local net, server, turtle = S.boot({ gps = { 8, 64, -2 } })
    S.lease(server, {
      lease = "mid",
      expires = net.time + 60000,
      steps = { { op = "forward" }, { op = "dig" } },
    })
    net.flush()
    assert(not turtle.error, tostring(turtle.error))
    local saved = S.journal(turtle)
    equal(saved.pending.op, "forward")
    equal(saved.pending.lease, "mid")
    equal(#saved.moves, 0)
    equal(turtle.pos.z, 0)
    turtle.co = nil
    turtle.boot("worker.lua")
    net.flush()
    assert(not turtle.error, tostring(turtle.error))
    local hello = S.sent(turtle, "hello")
    hello = hello[#hello]
    equal(hello.body.journal.pending.op, "forward")
    equal(hello.body.journal.pending.lease, "mid")
    equal(#hello.body.journal.moves, 0)
    equal(hello.body.gps, { x = 8, y = 64, z = -2 })
    equal(turtle.pos.z, 0)
    assert(turtle.alive(), "worker stopped after reboot")
  end)

  test("a batch with a bad MAC is ignored", function()
    local net, server, turtle = S.boot()
    local key = assert(server.env.SO.pair.key(2))
    local msg = server.env.SO.proto.build(key, "lease.batch", {
      lease = "nope",
      expires = net.time + 60000,
      steps = { { op = "forward" } },
    })
    local last = msg.mac:sub(64, 64)
    msg.mac = msg.mac:sub(1, 63) .. (last == "a" and "b" or "a")
    server.env.rednet.send(2, server.env.SO.proto.encode(msg), "so")
    local hello = S.sent(turtle, "hello")[1]
    assert(hello.body.gps == nil, "gps without a fix")
    net.flush()
    net.advance(1)
    assert(not turtle.error, tostring(turtle.error))
    equal(#S.sent(turtle, "step.report"), 0)
    equal(turtle.pos.z, 0)
    equal(turtle.fuel, 1000)
    local screen = S.screen(turtle)
    assert(not screen:find("nope", 1, true), screen)
  end)

  test("a new lease stops beaconing and runs", function()
    local net, server, turtle = S.boot()
    S.lease(server, {
      lease = "old",
      expires = net.time + 1000,
      steps = { { op = "forward" } },
    })
    S.wait(net, turtle, "beacon", 1, 80)
    equal(turtle.pos.z, -1)
    S.lease(server, {
      lease = "new",
      expires = net.time + 100000,
      steps = { { op = "forward" } },
    })
    net.advance(20)
    assert(not turtle.error, tostring(turtle.error))
    equal(turtle.pos.z, -2)
    equal(#S.sent(turtle, "beacon"), 1)
    local reports = S.sent(turtle, "step.report")
    equal(reports[#reports].body.lease, "new")
    equal(reports[#reports].body.results[1].ok, true)
  end)

  test("a new lease during the return stops walking back", function()
    local net, server, turtle = S.boot()
    S.lease(server, {
      lease = "gone",
      expires = net.time + 1000,
      steps = { { op = "forward" }, { op = "forward" } },
    })
    S.wait(net, turtle, "beacon", 1, 80)
    equal(turtle.pos.z, -2)
    S.reach(net, turtle, S.sent(turtle, "beacon")[1].at + 60000)
    equal(turtle.pos.z, -2)
    S.lease(server, {
      lease = "stay",
      expires = net.time + 100000,
      steps = { { op = "turnRight" } },
    })
    net.advance(2)
    assert(not turtle.error, tostring(turtle.error))
    equal(turtle.pos.z, -2)
    equal(turtle.heading, 1)
    equal(#S.journal(turtle).moves, 3)
  end)

  test("backtrack digs a block this turtle dug", function()
    local net, server, turtle = S.boot()
    net.world["0,-1,0"] = "minecraft:stone"
    net.world["0,-2,0"] = "minecraft:dirt"
    S.lease(server, {
      lease = "shaft",
      expires = net.time + 3000,
      steps = { { op = "digDown" }, { op = "down" }, { op = "digDown" }, { op = "down" } },
    })
    S.wait(net, turtle, "step.report", 1, 80)
    equal(turtle.pos.y, -2)
    net.world["0,-1,0"] = "minecraft:stone"
    S.wait(net, turtle, "beacon", 1, 200)
    S.reach(net, turtle, S.sent(turtle, "beacon")[1].at + 60000)
    net.advance(1)
    assert(not turtle.error, tostring(turtle.error))
    equal(turtle.pos.y, 0)
    assert(net.world["0,-1,0"] == nil, "stone this turtle dug is still there")
  end)

  test("backtrack stops on a block this turtle did not dig", function()
    local net, server, turtle = S.boot()
    S.lease(server, {
      lease = "out",
      expires = net.time + 3000,
      steps = { { op = "forward" }, { op = "forward" } },
    })
    S.wait(net, turtle, "step.report", 1, 40)
    equal(turtle.pos.z, -2)
    net.world["0,0,-1"] = "minecraft:obsidian"
    S.wait(net, turtle, "beacon", 1, 200)
    S.reach(net, turtle, S.sent(turtle, "beacon")[1].at + 60000)
    net.advance(1)
    assert(not turtle.error, tostring(turtle.error))
    equal(turtle.pos.z, -2)
    equal(net.world["0,0,-1"], "minecraft:obsidian")
    local screen = S.screen(turtle)
    assert(screen:find("step slow", 1, true), screen)
  end)
end
