local F = dofile("tests/so/worker-fixture.lua")
local modules = { "so-mod-state.lua", "so-log.lua", "so-mod-lease.lua", "so-mod-cells.lua",
  "so-mod-display.lua", "so-mod-mine.lua", "so-mine-plan.lua", "so-plan.lua",
  "so-mod-lumber.lua", "so-lumber-plan.lua" }

local function parked(rate, role, dropReport)
  local a = F.setup(nil, modules, rate)
  a.n.advance(1)
  a.s.env.SO.mods.display.screen(role).input({ text = "add 2 0 0 0 n" })
  a.n.advance(3)
  local lease = a.s.env.SO.mods.lease
  assert(not lease.status(2).open and not lease.status(2).lost, "initial park failed")
  local began, wall = a.n.time, a.n.utc()
  local dropped, renewed, attempts, beaconCount = nil, {}, {}, 0
  local send = a.s.env.rednet.send
  a.s.env.rednet.send = function(id, wire, protocol)
    if wire.t == "lease.batch" then
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
  assert(#attempts == 4, "expected three renewals and one retry")
  assert(attempts[1].lease == dropped and attempts[2].lease == dropped, "retry changed the lease")
  assert(attempts[2].rid ~= attempts[1].rid, "retry reused its envelope")
  assert(attempts[2].ttl == attempts[1].ttl - 1000, "retry extended the deadline")
  assert(attempts[2].at - attempts[1].at == 1000, "retry did not use game seconds")
  assert(a.n.time - began == 1800000 and a.n.utc() - wall == 1800000 / rate)
  assert(a.t.pos.x == 0 and a.t.pos.y == 0 and a.t.pos.z == 0, "parked worker moved")
  local count = 0
  for _ in pairs(renewed) do count = count + 1 end
  assert(count == 3, "park renewal cadence changed")
end

local function gpsWindow(rate, op)
  local a = F.setup(nil, { "so-mod-lease.lua" }, rate)
  local locating = false
  a.t.env.gps = { locate = function(seconds)
    locating = true
    local timer = a.t.env.os.startTimer(seconds)
    while true do
      local event, id = a.t.env.os.pullEvent()
      if event == "timer" and id == timer then locating = false return nil end
    end
  end }
  for _ = 1, 700 do
    if locating then break end
    a.n.advance(0.05)
  end
  assert(locating, "idle hello did not enter GPS lookup")
  local lease = a.s.env.SO.mods.lease
  local id = assert(lease.send(2, {{op=op}}, {ms=600000}))
  a.n.advance(3)
  F.check(a)
  assert(not lease.status(2).open, "GPS lookup swallowed the lease")
  local reports = F.sent(a.t, "step.report")
  assert(#reports == 1 and reports[1].body.lease == id, "lease did not report exactly once")
  assert(a.t.pos.z == (op == "forward" and -1 or 0), "unexpected worker position")
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
    for _, op in ipairs({"inspectDown", "forward"}) do
      test("GPS lookup preserves " .. op .. " leases at " .. rate .. "x", function() gpsWindow(rate, op) end)
    end
  end
end
