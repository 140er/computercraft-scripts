local H = dofile("tests/so/harness.lua")
-- Generated with formal/evidence/lease-orderings.json by formal/verify_lease.py.
-- Part tests carry this hash because their input set excludes formal evidence.
local evidenceSourceHash = "fc276d46ef2e9a23e92e6b1c7b5f4b02d5bd11742db8d72e0b1ec3143e30006b"
local key = string.rep("a", 64)
local function setup(position, gpsPos)
  local net = H.new()
  local server = net.machine({ id = 1, modem = true })
  server.install({ "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua",
    "so-mod-state.lua", "so-log.lua", "so-mod-lease.lua", "so-mod-cells.lua" })
  local libs = {
    "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing",
  }
  for _, name in ipairs(libs) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path, "rb"))
    server.files[path] = f:read("*a")
    f:close()
  end
  server.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["2"] = key, ["3"] = key } } })
  if position then server.files["so-server.cfg"] = H.encode({ pos = position }) end
  if gpsPos then server.env.gps = { locate = function(timeout)
    assert(timeout == 2)
    return gpsPos.x, gpsPos.y, gpsPos.z
  end } end
  server.boot("so-server.lua")
  assert(server.alive(), tostring(server.error))
  local lease = assert(server.env.SO.mods.lease, table.concat(server.log, "\n"))
  local calls, released = {}, {}
  local cells = server.env.SO.mods.cells
  local releaseOwner = cells.releaseOwner
  cells.releaseOwner = function(owner)
    released[#released + 1] = owner
    return releaseOwner(owner)
  end
  lease.onReport("mine", function(id, turtleId, results, record)
    calls[#calls + 1] = { id = id, turtleId = turtleId, results = results, lease = record }
  end)
  local worker = net.machine({ id = 2, modem = true, turtle = true })
  worker.install({ "so-proto.lua" })
  worker.env.KEY = key
  worker.spawn([[
    P = dofile("so-proto.lua")
    batches, replies = {}, {}
    function send(t, body)
      rednet.send(1, assert(P.encode(P.build(KEY, t, body))), "so")
    end
    while true do
      local ev, sender, wire, protocol = os.pullEvent()
      if ev == "rednet_message" and sender == 1 and protocol == "so" then
        local msg = assert(P.decode(wire))
        assert(P.macOk(KEY, msg) and P.fresh(msg))
        if msg.t == "lease.batch" then
          assert(#msg.body.steps >= 1 and #msg.body.steps <= 16)
          batches[#batches + 1] = msg.body
          if auto then
            local results = {}
            for i, step in ipairs(msg.body.steps) do
              results[i] = { ok = turtle[step.op](), counts = {} }
            end
            send("step.report", { lease = msg.body.lease, results = results })
          end
        else replies[#replies + 1] = msg end
      end
    end
  ]])
  local function send(t, body)
    worker.env.send(t, body)
    net.flush()
    assert(not server.error, tostring(server.error))
    assert(not worker.error, tostring(worker.error))
  end
  return { net = net, server = server, worker = worker, lease = lease,
    calls = calls, released = released, cells = cells, send = send, state = server.env.SO.mods.state }
end
local origin = { dim = 0, x = 0, y = 0, z = 0 }
local steps = { { op = "forward" }, { op = "up" } }
return function(test, equal, read)
  test("lease formal evidence matches the current source bytes", function()
    local s = setup(origin)
    local proto = s.server.env.SO.proto
    equal(proto.hex(proto.sha256(read("so-mod-lease.lua"))), evidenceSourceHash,
      "lease evidence is stale; rerun python3 formal/verify_lease.py --evidence formal/evidence/lease-orderings.json")
  end)
  test("lease refuses a second open batch without sending", function()
    local s = setup(origin)
    local id = assert(s.lease.send(2, steps, { owner = "mine" }))
    assert(id:match("^2%-%d+%-1$"), "lease ID must include its durable clock")
    local other, reason = s.lease.send(2, steps)
    equal(other, nil)
    equal(reason, "busy")
    s.net.flush()
    equal(#s.worker.env.batches, 1)
    equal(s.worker.env.batches[1].expires, s.net.time + 60000)
    equal(s.lease.status(2).open, id)
  end)
  test("lease full worker report keeps planner cells emits pose and calls once", function()
    local s = setup(origin)
    s.worker.env.auto = true
    for i, owner in ipairs({ "mine:2", "lumber:2", "build:2", "setup:2" }) do
      assert(s.cells.reserve(owner, i, 0, 0))
    end
    local pose = { dim = 0, x = 0, y = 1, z = -1, facing = 0 }
    local id = assert(s.lease.send(2, steps, { owner = "mine", pose = pose }))
    s.net.flush()
    equal(s.lease.status(2).open, nil)
    equal(s.released, {})
    for i, owner in ipairs({ "mine:2", "lumber:2", "build:2", "setup:2" }) do
      equal(s.cells.owner(i, 0, 0), owner)
    end
    equal(#s.calls, 1)
    equal(s.calls[1].id, id)
    equal(s.calls[1].turtleId, 2)
    equal(#s.calls[1].results, 2)
    equal(s.state.get("machines/2").pose, pose)
    equal(s.worker.pos.y, 1)
    equal(s.worker.pos.z, -1)
  end)
  test("lease duplicate unknown and wrong sender reports have no effects", function()
    local s = setup(origin)
    local id = assert(s.lease.send(2, steps, { owner = "mine", pose = origin }))
    s.net.flush()
    s.lease.handlers["step.report"]({ from = 3, body = { lease = id, results = { { ok = true }, { ok = true } } } })
    equal(s.lease.status(2).open, id)
    local results = { { ok = true }, { ok = true } }
    s.send("step.report", { lease = id, results = results })
    local before = s.state.view().rev
    for _ = 1, 2 do
      s.send("step.report", { lease = id, results = results })
      s.send("step.report", { lease = "unknown", results = results })
    end
    equal(#s.calls, 1)
    equal(#s.released, 0)
    equal(s.state.view().rev, before)
  end)
  test("lease park cancellation leaves real planner owners intact", function()
    local s = setup(origin)
    assert(s.cells.reserve("mine:2", 1, 0, 0))
    assert(s.lease.send(2, {{op="inspectDown"}}, {owner="mine"}))
    assert(s.lease.cancelPark(2, "mine"))
    equal(s.lease.status(2).open, nil)
    equal(s.cells.owner(1, 0, 0), "mine:2")
    equal(s.released, {})
    equal(#s.calls, 0)
  end)
  test("lease silence expires after grace and keeps reservations", function()
    local s = setup(origin)
    assert(s.cells.reserve("mine:2", 1, 0, 0))
    local id = assert(s.lease.send(2, steps, { owner = "mine", ms = 1000 }))
    s.net.advance(11)
    equal(#s.calls, 0)
    s.net.advance(1)
    equal(s.lease.status(2).open, nil)
    equal(#s.calls, 1)
    equal(s.calls[1].results, nil)
    equal(s.calls[1].lease.status, "expired")
    equal(s.cells.owner(1, 0, 0), "mine:2")
    equal(#s.released, 0)
    s.send("step.report", { lease = id, results = { { ok = true }, { ok = true } } })
    s.net.advance(1)
    equal(#s.calls, 1)
    equal(#s.released, 0)
  end)
  test("lease beacon blocks sends and hello restores contact", function()
    local s = setup(origin)
    s.send("beacon", { id = 999, fuel = 42, journal = "2-17" })
    equal(s.lease.status(2).lost, true)
    equal(s.lease.status(2).seen, s.net.time)
    local id, reason = s.lease.send(2, steps)
    equal(id, nil)
    equal(reason, "lost")
    local row = s.state.get("machines/2")
    equal(row.fuel, 42)
    equal(row.seen, s.net.time)
    local events = s.state.history.page({ count = 50 }).entries
    equal(events[#events].data.journal, "2-17")
    s.send("hello", { role = "turtle", journal = { id = "2-17" } })
    equal(s.lease.status(2).lost, false)
    assert(s.lease.send(2, steps))
  end)
  test("lease range never shrinks below 16 and grows only on full success", function()
    local s = setup(origin)
    s.send("hello", { gps = { x = 3, y = 4, z = 0 } })
    equal(s.lease.status(2).range, 16)
    local pose = { dim = 0, x = 30, y = 40, z = 0, facing = 1 }
    local id = assert(s.lease.send(2, steps, { pose = pose }))
    s.send("step.report", { lease = id, results = { { ok = true }, { ok = true } } })
    equal(s.lease.status(2).range, 50)
    equal(s.lease.inRange(2, { dim = 0, x = 58, y = 0, z = 0 }), true)
    equal(s.lease.inRange(2, { dim = 0, x = 59, y = 0, z = 0 }), false)
    id = assert(s.lease.send(2, steps, { pose = { dim = 0, x = 100, y = 0, z = 0 } }))
    s.send("step.report", { lease = id, results = { { ok = true }, { ok = false } } })
    equal(s.lease.status(2).range, 50)
    equal(s.state.get("machines/2").pose, pose)
  end)
  test("lease first park report preserves the initial range and nearer reports keep proof", function()
    local s = setup(origin)
    local near = { dim = 0, x = 3, y = 4, z = 0 }
    local park = { { op = "inspectDown" } }
    local function report(pose)
      local id = assert(s.lease.send(2, park, { pose = pose }))
      s.send("step.report", { lease = id, results = { { ok = true } } })
    end
    report(near)
    equal(s.lease.status(2).range, 16)
    equal(s.lease.inRange(2, { dim = 0, x = 24, y = 0, z = 0 }), true)
    report({ dim = 0, x = 30, y = 40, z = 0 })
    report(near)
    equal(s.lease.status(2).range, 50)
  end)
  test("lease malformed reports preserve open work and missing modules are optional", function()
    local s = setup(origin)
    local id = assert(s.lease.send(2, steps, { owner = "mine", pose = origin }))
    s.send("step.report", { lease = id, results = { { ok = true } } })
    equal(s.lease.status(2).open, id)
    equal(#s.calls, 0)
    equal(#s.released, 0)
    s.server.env.SO.mods.cells = {}
    s.server.env.SO.mods.state = {}
    s.send("step.report", { lease = id, results = { { ok = true }, { ok = true } } })
    equal(s.lease.status(2).open, nil)
    equal(#s.calls, 1)
  end)
  test("lease history page replies with state history entries over wire", function()
    local s = setup(origin)
    for i = 1, 4 do assert(s.state.emit("sample", { n = i })) end
    local query = { from = 1, count = 2 }
    local expected = s.state.history.page(query)
    s.send("history.page", query)
    equal(s.worker.env.replies[1].t, "history.page")
    equal(s.worker.env.replies[1].body, expected)
  end)
  test("lease lost GPS probe explains retry and a fresh hello permits another add", function()
    local dim = "minecraft:overworld"
    local s = setup({dim=dim,x=0,y=0,z=0})
    local function hello()
      s.send("hello", {role="turtle", gps={dim=dim,x=0,y=0,z=0},
        journal={id="probe",pose={x=0,y=0,z=0,f=0}},capabilities={parkBatch=true}})
    end
    hello()
    local reason
    s.lease.locate(2, dim, function(_, err) reason = err end)
    local first = assert(s.lease.status(2).open)
    s.net.advance(26)
    equal(reason, "GPS probe lost; retry add")
    equal(s.lease.status(2).open, nil)
    hello()
    s.lease.locate(2, dim, function() error("retry should start a probe") end)
    local retry = assert(s.lease.status(2).open)
    assert(retry ~= first)
    equal(s.lease.status(2).probing, true)
  end)
  test("lease range uses gps or allows positions without a server fix", function()
    local s = setup(nil, origin)
    equal(s.lease.status(2).range, 16)
    equal(s.lease.inRange(2, { x = 25, y = 0, z = 0 }), false)
    s = setup()
    equal(s.lease.inRange(2, { dim = 5, x = 99999, y = 0, z = 0 }), true)
    equal(s.lease.inRange(2, { dim = 5, x = 99999, y = 0, z = 0 }), true)
  end)
end
