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
return function(test,equal)
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
