local F = dofile("tests/so/worker-fixture.lua")
local modules = { "so-mod-state.lua", "so-log.lua", "so-mod-lease.lua", "so-mod-cells.lua",
  "so-mod-display.lua", "so-mod-mine.lua", "so-mine-plan.lua", "so-plan.lua",
  "so-mod-lumber.lua", "so-lumber-plan.lua" }

local function parked(rate, role, dropReport, waiting)
  local a = F.setup(nil, modules, rate)
  a.n.advance(1)
  local input = a.s.env.SO.mods.display.screen(role).input
  if waiting then input({ text = "area 0 0 0 0 -2" }) end
  input({ text = "add 2 0 0 0 n" })
  a.n.advance(3)
  if waiting then
    input({ text = "start" })
    a.n.advance(10)
    assert(a.s.env.SO.store.read("so-data/lumber/job").value.phase == "waiting", "lumber did not enter its planting wait")
  end
  local lease = a.s.env.SO.mods.lease
  assert(not lease.status(2).open and not lease.status(2).lost, "initial park failed")
  local began, wall = a.n.time, a.n.utc()
  local dropped, renewed, attempts, beaconCount = nil, {}, {}, 0
  local send = a.s.env.rednet.send
  a.s.env.rednet.send = function(id, wire, protocol)
    if wire.t == "lease.batch" and wire.body.ttl > 60000 then
      local body = wire.body
      renewed[body.lease] = true
      attempts[#attempts + 1] = { lease = body.lease, ttl = body.ttl, rid = wire.rid, at = a.n.time }
      if not dropReport and not dropped then dropped = body.lease return true end
    end
    return send(id, wire, protocol)
  end
  local report = a.t.env.rednet.send
  a.t.env.rednet.send = function(id, wire, protocol)
    if dropReport and wire.t == "step.report" and not dropped then dropped = wire.body.lease return true end
    return report(id, wire, protocol)
  end
  local beacon = lease.handlers.beacon
  lease.handlers.beacon = function(msg) beaconCount = beaconCount + 1 return beacon(msg) end
  for _ = 1, 1800 do
    a.n.advance(1)
    F.check(a)
    assert(not lease.status(2).lost, "parked worker went lost")
    assert(beaconCount == 0, "parked worker emitted an expiry beacon")
  end
  assert(dropped, "renewal loss was not exercised")
  if not waiting then assert(#attempts == 4, "expected three renewals and one retry") end
  assert(attempts[1].lease == dropped and attempts[2].lease == dropped, "retry changed the lease")
  assert(attempts[2].rid ~= attempts[1].rid, "retry reused its envelope")
  assert(attempts[2].ttl == attempts[1].ttl - 1000, "retry extended the deadline")
  assert(attempts[2].at - attempts[1].at == 1000, "retry did not use game seconds")
  assert(a.n.time - began == 1800000 and a.n.utc() - wall == 1800000 / rate)
  assert(a.t.pos.x == 0 and a.t.pos.y == 0 and a.t.pos.z == 0, "parked worker moved")
  local count = 0
  for _ in pairs(renewed) do count = count + 1 end
  assert(waiting and count >= 3 or count == 3, "park renewal cadence changed")
end

local function gpsWait(worker)
  local locating = false
  local gps = { locate = function(seconds)
    locating = true
    local timer = worker.env.os.startTimer(seconds)
    while true do
      local event, id = worker.env.os.pullEvent()
      if event == "timer" and id == timer then locating = false return nil end
    end
  end }
  return gps, function() return locating end
end

local function gpsWindow(rate, op)
  local a = F.setup(nil, { "so-mod-lease.lua" }, rate)
  local gps, locating = gpsWait(a.t)
  a.t.env.gps = gps
  for _ = 1, 700 do
    if locating() then break end
    a.n.advance(0.05)
  end
  assert(locating(), "idle hello did not enter GPS lookup")
  local lease = a.s.env.SO.mods.lease
  local id = assert(lease.send(2, {{op=op}}, {ms=600000}))
  a.n.advance(3)
  F.check(a)
  assert(not lease.status(2).open, "GPS lookup swallowed the lease")
  local reports = F.sent(a.t, "step.report")
  assert(#reports > 0 and reports[1].body.lease == id, "lease did not report")
  if op == "forward" then assert(#reports == 1, "work executed more than once") end
  assert(a.t.pos.z == (op == "forward" and -1 or 0), "unexpected worker position")
end

local function anchorDuringGps(rate)
  local a = F.setup(nil, { "so-mod-lease.lua" }, rate)
  assert(a.s.env.SO.mods.lease.send(2, {{op="inspectDown"}}, {ms=600000}))
  a.n.advance(1)
  local box = a.t.env.dofile("so-store.lua").store("so-journal", function() return true end, 16000)
  local journal = box.value
  journal.uncertain = true
  assert(box.save(journal))
  a.n.kill(a.t)
  local locating
  a.n.onBoot = function(m)
    if m.id == 2 then m.env.gps, locating = gpsWait(m) end
  end
  a.t = a.n.boot(a.t)
  a.n.onBoot = nil
  assert(locating(), "worker boot did not enter GPS lookup")
  local proto = a.s.env.SO.proto
  local anchor = proto.build(a.s.env.SO.pair.key(2), "worker.anchor", {
    journal = journal.id, pose = {x=0,y=0,z=0,f=0},
  })
  a.s.env.rednet.send(2, assert(proto.encode(anchor)), "so")
  a.n.advance(3)
  assert(not F.journal(a.t).uncertain, "anchor was not accepted during GPS lookup")
  local lease = a.s.env.SO.mods.lease
  assert(lease.send(2, {{op="forward"}}, {ms=600000}))
  a.n.advance(3)
  F.check(a)
  assert(not lease.status(2).open and a.t.pos.z == -1, "anchor stranded the outer GPS lookup")
end

return function(test)
  for _, rate in ipairs({1, 4}) do
    for _, role in ipairs({"mining", "lumber"}) do
      for _, dropReport in ipairs({false, true}) do
        test(role .. " park survives a lost renewal " .. (dropReport and "report" or "batch") .. " for 1800 game seconds at " .. rate .. "x", function()
          parked(rate, role, dropReport)
        end)
      end
    end
    test("lumber planting waits survive a lost renewal for 1800 game seconds at " .. rate .. "x", function()
      parked(rate, "lumber", false, true)
    end)
    for _, op in ipairs({"inspectDown", "forward"}) do
      test("GPS lookup preserves " .. op .. " leases at " .. rate .. "x", function() gpsWindow(rate, op) end)
    end
    test("anchor during GPS lookup leaves the worker responsive at " .. rate .. "x", function() anchorDuringGps(rate) end)
  end
end
