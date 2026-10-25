local F = dofile("tests/so/worker-fixture.lua")
local modules = {"so-mod-lease.lua", "so-mod-cells.lua"}

local function holdAcks(a)
  local held, send = {}, a.s.env.rednet.send
  a.s.env.rednet.send = function(id, wire, protocol)
    local msg = a.s.env.SO.proto.decode(wire)
    if msg and msg.t == "ack" and msg.body.command == "step.report" then
      held[#held + 1] = {wire=wire, msg=msg}
      return true
    end
    return send(id, wire, protocol)
  end
  return held, send
end

return function(test, equal)
  for _, op in ipairs({"inspectDown", "forward"}) do
    test("completed " .. op .. " lease stays paired and idle past its deadline", function()
      local a = F.setup(nil, modules)
      local lease = a.s.env.SO.mods.lease
      local reports = 0
      lease.onReport("idle-test", function(_, _, results, record)
        assert(results and record.status == "reported")
        reports = reports + 1
      end)
      local id = assert(lease.send(2, {{op=op}}, {ms=15000, owner="idle-test"}))
      a.n.advance(1)
      F.check(a)
      equal(F.sent(a.t, "step.report")[1].body.lease, id)
      equal(reports, 1)
      equal(lease.status(2).open, nil)
      local report = F.sent(a.t, "step.report")[1]
      local acknowledged = false
      for _, ack in ipairs(F.sent(a.s, "ack")) do
        if ack.rid == report.rid and ack.body.command == "step.report" and ack.body.lease == id then
          acknowledged = true
        end
      end
      assert(acknowledged, "report acknowledgement missing")
      a.n.advance(15)
      F.check(a)
      equal(lease.status(2).lost, false, "completed worker became LOST")
      equal(#F.sent(a.t, "beacon"), 0)
      a.n.advance(90)
      F.check(a)
      equal(#F.sent(a.t, "beacon"), 0)
      equal(a.t.pos.z, op == "forward" and -1 or 0)
      equal(lease.status(2).lost, false)
      equal(lease.status(2).last.status, "reported")
      equal(a.t.env.textutils.unserialize(a.t.files["so-keys"]).value.keys["1"],
        a.s.env.SO.pair.key(2))
    end)
  end

  test("a retried acknowledged lease cannot move again or restart its deadline", function()
    local a = F.setup(nil, modules)
    local lease, proto = a.s.env.SO.mods.lease, a.s.env.SO.proto
    assert(lease.send(2, {{op="forward"}}, {ms=15000}))
    a.n.advance(1)
    local batch = F.sent(a.s, "lease.batch")[1].body
    batch.ttl = 14000
    local msg = proto.build(a.s.env.SO.pair.key(2), "lease.batch", batch)
    a.s.env.rednet.send(2, proto.encode(msg), "so")
    a.n.advance(16)
    F.check(a)
    local reports = F.sent(a.t, "step.report")
    equal(#reports, 2)
    equal(reports[2].body.results[1].ok, false)
    equal(reports[2].body.results[1].err, "expired")
    equal(a.t.pos.z, -1)
    equal(#F.sent(a.t, "beacon"), 0)
    equal(lease.status(2).lost, false)
  end)

  for _, op in ipairs({"inspectDown", "forward"}) do
    test("acknowledged " .. op .. " lease recovers after fresh server contact stops", function()
      local a = F.setup(nil, modules)
      local lease, proto = a.s.env.SO.mods.lease, a.s.env.SO.proto
      if op == "inspectDown" then
        assert(lease.send(2, {{op="forward"}}, {ms=15000}))
        a.n.advance(1)
      end
      local id = assert(lease.send(2, {{op=op}}, {ms=15000}))
      a.n.advance(13)
      F.check(a)
      equal(lease.status(2).open, nil)
      equal(lease.status(2).last.status, "reported")
      local acknowledged = false
      for _, ack in ipairs(F.sent(a.s, "ack")) do
        if ack.body.command == "step.report" and ack.body.lease == id then acknowledged = true end
      end
      assert(acknowledged, "completed lease was not acknowledged")
      local contact = proto.build(a.s.env.SO.pair.key(2), "worker.status", {job="", reason=""})
      a.s.env.rednet.send(2, proto.encode(contact), "so")
      a.n.flush()
      a.n.kill(a.s)
      a.n.advance(14)
      assert(a.t.alive(), tostring(a.t.error))
      equal(#F.sent(a.t, "beacon"), 0, "recovery ignored fresh authenticated contact")
      equal(a.t.pos.z, -1)
      a.n.advance(2)
      equal(#F.sent(a.t, "beacon"), 1, "ack disabled silence recovery")
      a.n.advance(65)
      assert(a.t.alive(), tostring(a.t.error))
      if op == "forward" then
        equal(a.t.pos.z, 0)
        equal(#F.journal(a.t).moves, 0)
      else
        equal(a.t.pos.z, -1)
        equal(#F.journal(a.t).moves, 1)
        local beacons = F.sent(a.t, "beacon")
        equal(#beacons, 3)
        equal(beacons[2].at - beacons[1].at, 30000)
        equal(beacons[3].at - beacons[2].at, 30000)
      end
    end)
    test("healthy idle " .. op .. " lease with a two-second ttl never becomes LOST", function()
      local a = F.setup(nil, modules)
      local lease = a.s.env.SO.mods.lease
      assert(lease.send(2, {{op=op}}, {ms=2000}))
      a.n.advance(60)
      F.check(a)
      equal(#F.sent(a.t, "beacon"), 0)
      equal(lease.status(2).lost, false)
      equal(a.t.pos.z, op == "forward" and -1 or 0)
    end)
  end

  test("a server that reuses an acknowledged lease id receives a refusal and closes it", function()
    local a = F.setup(nil, modules)
    local lease, so = a.s.env.SO.mods.lease, a.s.env.SO
    local began = so.now()
    local id = assert(lease.send(2, {{op="forward"}}, {ms=15000}))
    a.n.advance(1)
    a.n.kill(a.s)
    a.s = a.n.boot(a.s)
    a.n.flush()
    so = a.s.env.SO
    so.now = function() return began end
    lease = so.mods.lease
    local state
    for i=1,10 do
      local name,value=debug.getupvalue(lease.send,i)
      if name=="S" then state=value break end
    end
    -- Force a broken server counter; normal restarts retain it.
    assert(state).seq=0
    local reports = 0
    lease.onReport("reused", function(_, _, results, record)
      equal(record.status, "reported")
      equal(#results, 2)
      for _, result in ipairs(results) do
        equal(result.ok, false)
        equal(result.err, "expired")
      end
      reports = reports + 1
    end)
    equal(lease.send(2, {{op="forward"}, {op="forward"}}, {ms=15000, owner="reused"}), id)
    a.n.advance(1)
    F.check(a)
    equal(reports, 1)
    equal(lease.status(2).open, nil)
    equal(lease.status(2).last.ok, false)
    equal(a.t.pos.z, -1)
  end)

  for _, op in ipairs({"inspectDown", "forward"}) do
    test("unacknowledged " .. op .. " report still enters silence recovery", function()
      local a = F.setup(nil, modules)
      local held = holdAcks(a)
      local lease = a.s.env.SO.mods.lease
      assert(lease.send(2, {{op=op}}, {ms=15000}))
      a.n.advance(1)
      equal(#held, 1)
      equal(lease.status(2).open, nil)
      a.n.advance(15)
      F.check(a)
      equal(#F.sent(a.t, "beacon"), 1)
      equal(lease.status(2).lost, true)
      if op == "forward" then
        a.n.advance(65)
        F.check(a)
        equal(a.t.pos.z, 0)
        equal(#F.journal(a.t).moves, 0)
      else
        equal(a.t.pos.z, 0)
        equal(F.journal(a.t).park, true)
      end
    end)
  end

  for _, mismatch in ipairs({"rid", "lease", "command"}) do
    test("a report ack with the wrong " .. mismatch .. " cannot close the deadline", function()
      local a = F.setup(nil, modules)
      local held, send = holdAcks(a)
      local lease, proto = a.s.env.SO.mods.lease, a.s.env.SO.proto
      local id = assert(lease.send(2, {{op="inspectDown"}}, {ms=15000}))
      a.n.advance(1)
      local body = {command="step.report", lease=id}
      local rid = held[1].msg.rid
      if mismatch == "rid" then rid = rid .. "-wrong" else body[mismatch] = "wrong" end
      local msg = proto.build(a.s.env.SO.pair.key(2), "ack", body, rid)
      send(2, proto.encode(msg), "so")
      a.n.advance(15)
      F.check(a)
      equal(#F.sent(a.t, "beacon"), 1)
      equal(lease.status(2).lost, true)
    end)
  end

  test("a delayed completed report ack cannot close a newer executing lease", function()
    local a = F.setup(nil, modules)
    local held, send = holdAcks(a)
    local lease = a.s.env.SO.mods.lease
    assert(lease.send(2, {{op="inspectDown"}}, {ms=15000}))
    a.n.advance(1)
    assert(lease.send(2, {{op="forward"}, {op="forward"}}, {ms=15000}))
    a.n.flush()
    equal(F.journal(a.t).pending.op, "forward")
    send(2, held[1].wire, "so")
    a.n.advance(16)
    F.check(a)
    equal(#held, 2)
    equal(#F.sent(a.t, "beacon"), 1)
    equal(lease.status(2).lost, true)
  end)

  test("a worker that stops mid-lease still expires without releasing its cells", function()
    local a = F.setup(nil, modules)
    local lease, cells = a.s.env.SO.mods.lease, a.s.env.SO.mods.cells
    local expired = 0
    lease.onReport("idle-test", function(_, _, results, record)
      equal(results, nil)
      equal(record.status, "expired")
      expired = expired + 1
    end)
    assert(cells.reserve("idle-test:2", 0, 0, -1))
    local id = assert(lease.send(2, {{op="forward"}, {op="forward"}}, {ms=15000, owner="idle-test"}))
    a.n.flush()
    equal(lease.status(2).open, id)
    equal(F.journal(a.t).pending.op, "forward")
    a.n.kill(a.t)
    a.n.advance(26)
    assert(a.s.alive(), tostring(a.s.error))
    equal(expired, 1)
    equal(lease.status(2).open, nil)
    equal(lease.status(2).last.status, "expired")
    equal(cells.owner(0, 0, -1), "idle-test:2")
    equal(#F.sent(a.t, "step.report"), 0)
  end)
end
