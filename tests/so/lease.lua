local H = dofile("tests/so/harness.lua")
-- Generated with formal/evidence/lease-orderings.json by formal/verify_lease.py.
-- Part tests carry this hash because their input set excludes formal evidence.
local evidenceSourceHash = "61a1f22d22ea60e2af1ee64816f46bc83e2a239f10124e8f6576fd38123738c6"
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
  test("lease history wire pages use UTC cursors and text without changing sequence pages", function()
    local s = setup(origin)
    local epoch = s.server.env.os.epoch
    local utc = 1700000000000
    s.server.env.os.epoch = function(kind) return kind == "utc" and utc or epoch(kind) end
    for i = 1, 105 do
      utc = utc + 1000
      assert(s.state.emit("sample", { text = "event " .. i }))
    end
    s.server.env.os.epoch = epoch
    local internal = s.state.history.page({ from = 100, count = 2 })
    equal(internal.entries[1].seq, 101)
    equal(internal.entries[2].seq, 102)
    equal(internal.next, 102)
    local function page(query)
      local n = #s.worker.env.replies
      s.send("history.page", query)
      local reply = s.worker.env.replies[n + 1]
      equal(reply.t, "history.page")
      return reply.body
    end
    local first = page({ limit = 2, from = 1, count = 1, reverse = false })
    equal(first.entries, {
      { at = utc, text = "sample event 105" },
      { at = utc - 1000, text = "sample event 104" },
    })
    equal(first.next, {at=utc-1000, seq=104})
    local second = page({ limit = 2, before = first.next })
    equal(second.entries[1], {at=utc-2000, text="sample event 103"})
    equal(second.entries[2], {at=utc-3000, text="sample event 102"})
    local last = page({ limit = 50, before = utc - 103000 })
    equal(last.entries, {{at=utc-104000, text="sample event 1"}})
    equal(last.next, nil)
    equal(#page({}).entries, 20)
    equal(#page({limit=99}).entries, 50)
    equal(#page({limit=0}).entries, 1)
    equal(s.state.history.page({from=100,count=2}), internal)
  end)
  test("lease history wire sorts UTC times and excludes equal cursor times", function()
    local s = setup(origin)
    local epoch = s.server.env.os.epoch
    local utc = 1700000000000
    s.server.env.os.epoch = function(kind) return kind == "utc" and utc or epoch(kind) end
    assert(s.state.emit("sample", "first"))
    utc = utc - 1000
    assert(s.state.emit("sample", {reason="older"}))
    utc = utc + 1000
    assert(s.state.emit("sample", false))
    s.server.env.os.epoch = epoch
    s.send("history.page", {limit=2})
    equal(s.worker.env.replies[1].body, {entries={
      {at=utc,text="sample cleared"}, {at=utc,text="sample first"}}, next={at=utc,seq=1}})
    s.send("history.page", {before=utc,limit=2})
    equal(s.worker.env.replies[2].body, {entries={{at=utc-1000,text="sample older"}}})
  end)
  test("lease history wire cursor retains equal-time overflow across pages", function()
    for _, count in ipairs({3,55}) do
      local s = setup(origin)
      local epoch, utc = s.server.env.os.epoch, 1700000000000
      s.server.env.os.epoch = function(kind) return kind == "utc" and utc or epoch(kind) end
      for i = 1, count do assert(s.state.emit("sample", {text="event " .. i})) end
      s.server.env.os.epoch = epoch
      local cursor
      for newest = count, 1, -2 do
        s.send("history.page", {limit=2, before=cursor})
        local reply = s.worker.env.replies[#s.worker.env.replies]
        equal(reply.t, "history.page")
        local expected = {{at=utc,text="sample event " .. newest}}
        if newest > 1 then expected[2] = {at=utc,text="sample event " .. (newest-1)} end
        equal(reply.body.entries, expected)
        cursor = reply.body.next
        equal(cursor, newest > 2 and {at=utc,seq=newest-1} or nil)
      end
      s.send("history.page", {limit=2, before=utc})
      equal(s.worker.env.replies[#s.worker.env.replies].body, {entries={}})
      s.send("history.page", {limit=2, before={at=utc}})
      equal(s.worker.env.replies[#s.worker.env.replies].body, {entries={}})
    end
  end)
  test("lease setup handoff commits only with the complete route", function()
    local s = setup(origin)
    local pose = {dim="minecraft:overworld",x=0,y=0,z=0}
    local route = {pose, {dim=pose.dim,x=1,y=0,z=0}}
    assert(s.cells.reserve("gps:2", 0, 0, 0))
    assert(s.cells.reserve("mine:3", 1, 0, 0))
    assert(s.lease.claimProbe(2, "setup:2", pose))
    equal(s.cells.owner(0, 0, 0), "gps:2")
    local ok, err = s.cells.reserveMany("setup:2", route)
    equal(ok, false)
    equal(err, "held")
    equal(#s.cells.list("setup:2", 10), 0)
    equal(s.cells.owner(0, 0, 0), "gps:2")
    assert(s.cells.releaseOwner("mine:3"))
    assert(s.lease.claimProbe(2, "setup:2", pose))
    local open = s.server.env.fs.open
    s.server.env.fs.open = function(path, mode)
      if path == "so-data/cells/res.tmp" and mode == "w" then return nil end
      return open(path, mode)
    end
    equal(s.cells.reserveMany("setup:2", route), false)
    equal(#s.cells.list("setup:2", 10), 0)
    equal(s.cells.owner(0, 0, 0), "gps:2")
    s.server.env.fs.open = open
    -- A failed reservation consumes the pending handoff.
    equal(s.cells.reserveMany("setup:2", route), false)
    assert(s.lease.claimProbe(2, "setup:2", pose))
    assert(s.cells.reserveMany("setup:2", route))
    equal(s.cells.owner(0, 0, 0), "setup:2")
    equal(s.cells.owner(1, 0, 0), "setup:2")
    assert(s.lease.clearProbe(2))
    equal(s.cells.owner(0, 0, 0), "setup:2")
  end)
  test("lease setup failure does not claim a free pose or change other planner handoffs", function()
    local s = setup(origin)
    local pose = {dim="minecraft:overworld",x=0,y=0,z=0}
    assert(s.cells.reserve("gps:2", 2, 0, 0))
    assert(s.cells.reserve("mine:3", 1, 0, 0))
    assert(s.lease.claimProbe(2, "setup:2", pose))
    equal(s.cells.reserveMany("setup:2", {pose,{dim=pose.dim,x=1,y=0,z=0}}), false)
    equal(s.cells.owner(0, 0, 0), nil)
    equal(#s.cells.list("setup:2", 10), 0)
    assert(s.lease.claimProbe(2, "mine:2", {dim=pose.dim,x=2,y=0,z=0}))
    equal(s.cells.owner(2, 0, 0), "mine:2")
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
  local function settingsServer()
    local s=setup(origin)
    s.server.files["so-server.cfg"]=H.encode({workerSettings=true})
    s.send("hello",{role="turtle",capabilities={workerSettings=true},settingsControl=true,
      settings={seq=1,dim="minecraft:overworld",autoToolSwap=false,remoteN=4}})
    return s
  end
  local function replySettings(s,t,body,rid,from)
    local worker=from or s.worker
    local p=worker.env.P or s.worker.env.P
    local msg=p.build(key,t,body,rid)
    if from then msg.from=from.id msg.mac=p.sign(key,msg) end
    worker.env.rednet.send(1,msg,"so")
    s.net.flush()
  end
  test("lease settings defaults off and old workers receive no command", function()
    local s=setup(origin)
    local before=#s.server.sent
    equal(s.lease.settings(2,{autoToolSwap=false}),nil)
    equal(#s.server.sent,before)
    s.server.files["so-server.cfg"]=H.encode({workerSettings=true})
    local rid,err=s.lease.settings(2,{autoToolSwap=false})
    equal(rid,nil); equal(err,"update required")
    equal(#s.server.sent,before)
  end)
  test("lease settings replies match authenticated sender rid command and counter without reply loops", function()
    local s=settingsServer()
    local rid=assert(s.lease.settings(2,{autoToolSwap=true}))
    local pending=s.lease.status(2).settingsPending
    equal(pending,{rid=rid,n=5})
    local confirmed={seq=2,dim="minecraft:overworld",autoToolSwap=true,remoteN=5}
    local before=#s.server.sent
    for _,body in ipairs({{command="worker.update",n=5,settings=confirmed},
      {command="worker.settings",n=4,settings=confirmed}}) do
      s.lease.handlers.ack({from=2,t="ack",rid=rid,body=body})
      equal(s.lease.status(2).settingsPending,pending)
    end
    replySettings(s,"ack",{command="worker.settings",n=5,settings=confirmed},rid.."-wrong")
    equal(s.lease.status(2).settingsPending,pending)
    local other=s.net.machine({id=3,modem=true})
    replySettings(s,"ack",{command="worker.settings",n=5,settings=confirmed},rid,other)
    equal(s.lease.status(2).settingsPending,pending)
    equal(#s.server.sent,before,"unmatched replies caused a reply loop")
    replySettings(s,"ack",{command="worker.settings",n=5,settings=confirmed},rid)
    equal(s.lease.status(2).settings,confirmed)
    equal(s.lease.status(2).settingsPending,nil)
    replySettings(s,"ack",{command="worker.settings",n=5,settings={seq=99,autoToolSwap=false}},rid)
    equal(s.lease.status(2).settings,confirmed)
  end)
  test("lease delayed ack and hello cannot replace newer confirmed settings or reuse an old intent", function()
    local s=settingsServer()
    local rid=assert(s.lease.settings(2,{autoToolSwap=true}))
    local newer={seq=3,dim="minecraft:the_nether",autoToolSwap=false,remoteN=5}
    s.send("hello",{role="turtle",capabilities={workerSettings=true},settingsControl=true,settings=newer})
    replySettings(s,"ack",{command="worker.settings",n=5,
      settings={seq=2,dim="minecraft:overworld",autoToolSwap=true,remoteN=5}},rid)
    s.send("hello",{role="turtle",capabilities={workerSettings=true},settingsControl=true,
      settings={seq=1,autoToolSwap=true,remoteN=4}})
    equal(s.lease.status(2).settings,newer)
    rid=assert(s.lease.settings(2,{autoToolSwap=true}))
    equal(s.lease.status(2).settingsPending.n,6)
    replySettings(s,"err",{command="worker.settings",code="settings",n=6,text="worker busy"},rid)
    equal(s.lease.status(2).settings,newer)
    equal(s.lease.status(2).settingsError,"worker busy")
    rid=assert(s.lease.settings(2,{autoToolSwap=true}))
    equal(s.lease.status(2).settingsPending.n,7)
    s.net.advance(16)
    equal(s.lease.status(2).settings,newer)
    equal(s.lease.status(2).settingsPending,nil)
    equal(s.lease.status(2).settingsError,"settings timed out")
  end)
  test("lease unassigned status requires assignments and open lease to clear", function()
    local s=settingsServer()
    local assigned=true
    s.server.env.SO.mods.build={assigned=function() return assigned end}
    s.net.advance(2)
    local function idleCount()
      local count=0
      for _,sent in ipairs(s.server.sent) do
        if sent.payload.t=="worker.status" and sent.payload.body.job=="" then count=count+1 end
      end
      return count
    end
    equal(idleCount(),0)
    equal(s.lease.settings(2,{autoToolSwap=true}),nil)
    assigned=false
    local lid=assert(s.lease.send(2,{{op="inspectDown"}},{ms=2000}))
    s.net.advance(1)
    equal(idleCount(),0)
    s.send("step.report",{lease=lid,results={{ok=true}}})
    s.net.advance(1)
    assert(idleCount()>0)
  end)
  test("lease tick isolates assigned and idle status send failures", function()
    for _,assigned in ipairs({false,true}) do
      local s=settingsServer()
      s.server.env.SO.mods.build={assigned=function() return assigned end}
      local attempted=false
      s.server.env.rednet.send=function(_,payload)
        local msg=s.server.env.SO.proto.decode(payload)
        if msg and msg.t=="worker.status" then attempted=true; error("status transport failed") end
      end
      local ok,err=pcall(s.lease.tick)
      assert(attempted,"lease tick did not attempt the status")
      assert(ok,tostring(err))
    end
  end)
  test("lease new pairing refreshes settings baseline and counter without pushing cached values", function()
    local s=settingsServer()
    assert(s.lease.settings(2,{autoToolSwap=true}))
    s.net.flush()
    local nextKey=string.rep("b",64)
    assert(s.server.env.SO.pair.remember(2,nextKey))
    s.worker.env.KEY=nextKey
    s.send("hello",{role="turtle",capabilities={workerSettings=true},settingsControl=true,
      settings={seq=0,autoToolSwap=false}})
    equal(s.lease.status(2).settings,{seq=0,autoToolSwap=false})
    equal(s.lease.status(2).settingsPending,nil)
    local count=0
    for _,sent in ipairs(s.server.sent) do if sent.payload.t=="worker.settings" then count=count+1 end end
    equal(count,1,"reconnect pushed cached settings")
    assert(s.lease.settings(2,{autoToolSwap=true}))
    equal(s.lease.status(2).settingsPending.n,1)
  end)

  test("lease legacy hellos keep dimension and tool facts when settings control is off", function()
    local s=setup(origin)
    s.server.install({"so-plan.lua"})
    s.server.files["so-server.cfg"]=H.encode({remoteDimensions=true})
    s.send("hello",{role="turtle",capabilities={workerSettings=true,dimensionSafety=true},
      settings={seq=0,autoToolSwap=false}})
    s.send("hello",{role="turtle",dim="minecraft:the_nether",
      capabilities={workerSettings=true,dimensionSafety=true,autoToolSwap=true},
      settings={seq=0,dim="minecraft:the_nether",autoToolSwap=true}})
    equal(s.lease.status(2).autoToolSwap,true)
    assert(s.lease.remoteReady(2,"minecraft:the_nether"))
    equal(s.lease.settings(2,{autoToolSwap=false}),nil)
  end)


  test("B2-B selected worker dimension and SWAP remain confirmed while pending until the matched ack",function()
    local s=settingsServer()
    local before=s.lease.status(2).settings
    local rid=assert(s.lease.settings(2,{dim="minecraft:the_nether",autoToolSwap=true}))
    equal(s.lease.status(2).settings,before)
    equal(s.lease.status(2).settingsPending,{rid=rid,n=5})
    equal(s.lease.settings(3,{autoToolSwap=true}),nil)
    equal(s.lease.status(2).settings,before)
    local confirmed={seq=2,dim="minecraft:the_nether",autoToolSwap=true,remoteN=5}
    replySettings(s,"ack",{command="worker.settings",n=5,settings=confirmed},rid)
    equal(s.lease.status(2).settings,confirmed) equal(s.lease.status(2).settingsPending,nil)
    rid=assert(s.lease.settings(2,{dim="minecraft:the_end",autoToolSwap=false}))
    equal(s.lease.status(2).settings,confirmed)
    local newer={seq=3,dim="minecraft:the_end",autoToolSwap=false,remoteN=6}
    s.send("hello",{role="turtle",capabilities={workerSettings=true},settingsControl=true,settings=newer})
    equal(s.lease.status(2).settings,newer) equal(s.lease.status(2).settingsPending,nil)
  end)
  test("B2-B server settings respect the worker flag capability and idle assignment eligibility",function()
    for _,case in ipairs({"worker flag","capability","build assignment","open lease","uncertain"}) do
      local s=settingsServer()
      if case=="worker flag" then
        s.send("hello",{role="turtle",capabilities={workerSettings=true},settingsControl=false,
          settings={seq=1,dim="minecraft:overworld",autoToolSwap=false}})
      elseif case=="capability" then
        s.send("hello",{role="turtle",capabilities={},settingsControl=true})
      elseif case=="build assignment" then
        s.server.env.SO.mods.build={assigned=function(id) return id==2 end}
      elseif case=="open lease" then assert(s.lease.send(2,{{op="inspectDown"}}))
      else s.send("hello",{role="turtle",journal={id="changed",pose={x=0,y=0,z=0,f=0},uncertain=true},
        capabilities={workerSettings=true},settingsControl=true,
        settings={seq=1,dim="minecraft:overworld",autoToolSwap=false}}) end
      local before=s.lease.status(2).settings
      local rid,err=s.lease.settings(2,{dim="minecraft:the_nether",autoToolSwap=true})
      equal(rid,nil,case)
      equal(err,case=="worker flag" and "settings disabled" or case=="capability" and "update required" or "worker busy",case)
      equal(s.lease.status(2).settings,before)
      equal(s.lease.status(2).settingsPending,nil)
    end
  end)

end
