local F = dofile("tests/so/worker-fixture.lua")
local function reboot(a)
  a.t.killed=false
  a.t.co,a.t.inbox,a.t.timers=nil,{},{}
  a.t.boot("worker.lua"); a.n.flush(); a.n.advance(3); F.check(a)
  local h=F.sent(a.t,"hello")
  return h[#h].body.journal
end
local function interrupt(a,op,happened)
  local original=a.t.env.turtle[op]
  if happened then
    a.t.env.turtle[op]=function()
      original()
      a.n.kill(a.t)
      error("power loss")
    end
  end
  F.send(a,{{op=op}})
  if happened then a.n.advance(0.05) end
  assert(F.journal(a.t).pending,"interruption missed pending step")
  a.t.env.turtle[op]=original
end
local function failSave(a, first, persistent)
  local open, attempts = a.t.env.fs.open, 0
  a.t.env.fs.open = function(path, mode)
    if path == "so-journal.tmp" and mode == "w" then
      attempts = attempts + 1
      if attempts == first or persistent and attempts >= first then return nil end
    end
    return open(path, mode)
  end
  return function() a.t.env.fs.open = open end
end
return function(test,equal)
  test("expiry cannot backtrack after a refused batch and persistent journal failure", function()
    local a = F.setup()
    F.send(a, {{op="forward"}}); a.n.advance(0.2)
    equal(a.t.pos.z, -1)
    local restore = failSave(a, 1, true)
    local back, calls = a.t.env.turtle.back, 0
    a.t.env.turtle.back = function() calls = calls + 1 return back() end
    F.send(a, {{op="forward"}}, 1000)
    a.n.advance(70); F.check(a)
    local reports = F.sent(a.t, "step.report")
    equal(reports[#reports].body.results[1].err, "expired")
    equal(calls, 0); equal(a.t.pos.z, -1)
    restore()
    local j = reboot(a)
    equal(j.pose.z, a.t.pos.z); equal(#j.moves, 1)
  end)
  for _, op in ipairs({"forward", "up", "turnRight"}) do
    test("failed expiry outcome save keeps " .. op .. " reversal uncertain", function()
      local a = F.setup()
      F.send(a, {{op=op}}, 1000); a.n.advance(0.2)
      local restore = failSave(a, 2, false)
      a.n.advance(100); F.check(a)
      equal(a.t.pos, {x=0, y=0, z=0}); equal(a.t.heading, 0)
      local beacons = F.sent(a.t, "beacon")
      equal(beacons[#beacons].body.pose, nil)
      equal(beacons[#beacons].body.uncertain, true)
      restore()
      local j = reboot(a)
      equal(j.uncertain, true); equal(#j.moves, 0)
      equal(j.pose, {x=0, y=0, z=0, f=0})
    end)
  end
  for _, happened in ipairs({false, true}) do
    test("reboot resolves an expiry reverse that " .. (happened and "ran" or "did not run"), function()
      local a = F.setup()
      F.send(a, {{op="forward"}}, 1000); a.n.advance(0.2)
      local back = a.t.env.turtle.back
      a.t.env.turtle.back = function()
        if happened then back() end
        a.n.kill(a.t); error("power loss")
      end
      a.n.advance(70)
      equal(F.journal(a.t).pending.reverse, true)
      a.t.env.turtle.back = back
      local j = reboot(a)
      equal(j.pose.z, a.t.pos.z); equal(j.pose.z, happened and 0 or -1)
      equal(#j.moves, happened and 0 or 1)
      equal(j.pending, nil)
      j = reboot(a)
      equal(j.pose.z, a.t.pos.z); equal(#j.moves, happened and 0 or 1)
    end)
  end
  local function blockedReturn()
    local a = F.setup()
    a.n.world["0,0,-1"] = "minecraft:stone"
    F.send(a, {{op="dig"}, {op="forward"}, {op="forward"}}, 1000)
    a.n.advance(0.2)
    equal(a.t.pos.z, -2)
    a.n.world["0,0,-1"] = "minecraft:stone"
    return a
  end
  test("expiry clears a known dug cell behind and restores its facing and history", function()
    local a = blockedReturn()
    a.n.advance(70); F.check(a)
    equal(a.t.pos.z, 0); equal(a.t.heading, 0)
    local j = reboot(a)
    equal(j.pose.z, 0); equal(j.pose.f, 0)
    equal(#j.moves, 0); equal(j.uncertain, nil)
  end)
  for _, failure in ipairs({
    {at=11, persistent=false, z=-2, moves=2, uncertain=true, name="restored facing save"},
    {at=12, persistent=true, z=-2, moves=2, name="retry pending save"},
    {at=13, persistent=false, z=-1, moves=1, uncertain=true, name="retry outcome save"},
  }) do
    test("expiry clearing stops after a failed " .. failure.name, function()
      local a = blockedReturn()
      local restore = failSave(a, failure.at, failure.persistent)
      a.n.advance(70); F.check(a)
      equal(a.t.pos.z, failure.z); equal(a.t.heading, 0)
      restore()
      local j = reboot(a)
      equal(j.pose.z, failure.z); equal(j.pose.f, 0)
      equal(j.uncertain, failure.uncertain); equal(#j.moves, failure.moves)
    end)
  end
  for turn = 1, 4 do
    test("expiry clearing turn " .. turn .. " requires a pending save", function()
      local a = blockedReturn()
      local restore = failSave(a, 3 + (turn-1)*2, true)
      a.n.advance(70); F.check(a)
      equal(a.t.pos.z, -2); equal(a.t.heading, (4-(turn-1))%4)
      restore()
      local j = reboot(a)
      if turn > 1 then equal(j.uncertain, true) end
      equal(j.pose.z, -2); equal(j.pose.f, a.t.heading)
      equal(#j.moves, 2)
    end)
    test("failed expiry clearing turn " .. turn .. " outcome survives reboot as uncertain", function()
      local a = blockedReturn()
      local restore = failSave(a, 4 + (turn-1)*2, false)
      a.n.advance(70); F.check(a)
      equal(a.t.pos.z, -2); equal(a.t.heading, (4-turn)%4)
      restore()
      local j = reboot(a)
      equal(j.uncertain, true); equal(#j.moves, 2)
      equal(j.pose.z, -2); equal(j.pose.f, a.t.heading)
    end)
  end
  for _, supplied in ipairs({false, true}) do
    test("failed pending save refuses movement with journal " .. tostring(supplied), function()
      local a = F.setup()
      local restore = failSave(a, 1, false)
      local calls, forward = 0, a.t.env.turtle.forward
      a.t.env.turtle.forward = function() calls = calls + 1 return forward() end
      local hello = F.sent(a.t, "hello")
      local body = {lease="failed-pending", expires=a.n.time+60000,
        steps={{op="forward"}, {op="turnRight"}},
        journal=supplied and hello[#hello].body.journal.id or nil}
      local msg = a.s.env.SO.proto.build(a.s.env.SO.pair.key(2), "lease.batch", body)
      a.s.env.rednet.send(2, a.s.env.SO.proto.encode(msg), "so")
      a.n.flush(); a.n.advance(0.2); F.check(a)
      equal(calls, 0); equal(a.t.pos.z, 0); equal(a.t.heading, 0)
      local reports = F.sent(a.t, "step.report")
      local r = reports[#reports].body
      equal(#r.results, 2)
      equal(r.results[1].err, "expired"); equal(r.results[2].err, "expired")
      restore()
      local j = reboot(a)
      equal(j.pose.z, 0); equal(j.pending, nil)
    end)
  end
  for _, op in ipairs({"forward", "turnRight"}) do
    test("failed " .. op .. " outcome save persists uncertainty and stops the batch", function()
      local a = F.setup()
      local restore = failSave(a, 2, false)
      F.send(a, {{op=op}, {op="up"}})
      a.n.advance(0.2); F.check(a)
      equal(a.t.pos.y, 0)
      equal(a.t.pos.z, op == "forward" and -1 or 0)
      equal(a.t.heading, op == "turnRight" and 1 or 0)
      local reports = F.sent(a.t, "step.report")
      local r = reports[#reports].body
      equal(r.results[1].ok, true)
      equal(r.results[2].err, "journal save failed")
      equal(r.pose, nil); equal(r.uncertain, true)
      equal(F.journal(a.t).pending.op, op)
      restore()
      local j = reboot(a)
      equal(j.uncertain, true); equal(j.pending.op, op)
      equal(j.pose.z, a.t.pos.z); equal(j.pose.f, a.t.heading)
      F.send(a, {{op="forward"}}); a.n.advance(31); F.check(a)
      reports = F.sent(a.t, "step.report")
      equal(reports[#reports].body.results[1].err, "pose uncertain")
      local beacons = F.sent(a.t, "beacon")
      equal(beacons[#beacons].body.pose, nil)
      equal(beacons[#beacons].body.uncertain, true)
    end)
  end
  test("persistent outcome save failure leaves a durable pending turn for reboot", function()
    local a = F.setup()
    local restore = failSave(a, 2, true)
    F.send(a, {{op="turnRight"}, {op="forward"}})
    a.n.advance(0.2); F.check(a)
    equal(a.t.heading, 1); equal(a.t.pos.x, 0)
    equal(F.journal(a.t).pending.op, "turnRight")
    restore()
    local j = reboot(a)
    equal(j.uncertain, true); equal(j.recovery.outcome, "uncertain")
    equal(j.pending.op, "turnRight")
  end)
  test("failed recovery save reports uncertainty without applying the move twice", function()
    local a = F.setup()
    interrupt(a, "forward", true)
    local restore = failSave(a, 1, false)
    local j = reboot(a)
    equal(j.uncertain, true); equal(j.pose.z, -1)
    equal(#j.moves, 1)
    restore()
    j = reboot(a)
    equal(j.uncertain, true); equal(j.pose.z, -1)
    equal(#j.moves, 1)
  end)
  for _,happened in ipairs({false,true}) do
    test("reboot resolves a finite-fuel move that " .. (happened and "happened" or "did not happen"),function()
      local a=F.setup()
      interrupt(a,"forward",happened)
      local j=reboot(a)
      equal(j.pose.z,happened and -1 or 0)
      equal(j.pose.z,a.t.pos.z)
      equal(j.pending,nil)
      equal(j.recovery.outcome,happened and "applied" or "not applied")
      equal(#j.moves,happened and 1 or 0)
      local seq=j.seq
      j=reboot(a)
      equal(j.seq,seq); equal(#j.moves,happened and 1 or 0)
    end)
    test("reboot reports an interrupted turn without guessing when it " .. (happened and "happened" or "did not happen"),function()
      local a=F.setup(nil,{"so-mod-lease.lua"})
      interrupt(a,"turnRight",happened)
      local j=reboot(a)
      equal(j.uncertain,true); equal(j.pending.op,"turnRight")
      equal(j.recovery.outcome,"uncertain")
      local lease=a.s.env.SO.mods.lease
      equal(lease.status(2).pose,nil); equal(lease.status(2).uncertain,true)
      local id,err=lease.send(2,{{op="inspectDown"}},{recover=true})
      equal(id,nil); equal(err,"pose uncertain")
      F.send(a,{{op="forward"},{op="turnLeft"}})
      a.n.advance(90); F.check(a)
      equal(a.t.pos.z,0); equal(a.t.heading,happened and 1 or 0)
      local r=F.sent(a.t,"step.report"); r=r[#r].body
      equal(r.pose,nil); equal(r.uncertain,true)
      equal(r.results[1].err,"pose uncertain")
      equal(F.journal(a.t).pending.op,"turnRight")
      local b=F.sent(a.t,"beacon")
      assert(#b>0,"uncertain worker stopped beaconing")
      equal(b[#b].body.pose,nil); equal(b[#b].body.uncertain,true)
    end)
    test("GPS resolves an unlimited-fuel move that " .. (happened and "happened" or "did not happen"),function()
      local a=F.setup({id=2,modem=true,turtle=true,capacity=1000000,fuel="unlimited"})
      a.t.env.gps={locate=function() return a.t.pos.x+40,a.t.pos.y+64,a.t.pos.z+10 end}
      interrupt(a,"up",happened)
      local j=reboot(a)
      equal(j.pending,nil); equal(j.pose.y,happened and 1 or 0)
      equal(j.pose.y,a.t.pos.y)
    end)
  end
  test("legacy pending move without evidence reports uncertainty",function()
    local a=F.setup()
    interrupt(a,"forward",false)
    local j=F.journal(a.t)
    j.pending.fuel,j.pending.gps=nil,nil
    assert(a.t.env.dofile("so-store.lua").store("so-journal",function() return true end,16000).save(j))
    j=reboot(a)
    equal(j.uncertain,true); equal(j.recovery.outcome,"uncertain")
  end)
end
