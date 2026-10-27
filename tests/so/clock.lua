local H = dofile("tests/so/harness.lua")
local F = dofile("tests/so/worker-fixture.lua")
local function clock(rate)
  local n = H.new({tickRate=rate})
  local m = n.machine({id=1})
  m.install({"so-store.lua"})
  m.files["clock-test.lua"] = [[
    store = dofile("so-store.lua")
    now = store.clock()
    initial = now()
    while true do os.pullEvent() end
  ]]
  m.boot("clock-test.lua")
  assert(m.alive(), tostring(m.error))
  return n, m
end
local function trace(rate, park)
  local a = F.setup(nil, {"so-mod-lease.lua"}, rate)
  local send = a.s.env.rednet.send
  a.s.env.rednet.send = function(id, wire, protocol)
    local msg = a.s.env.SO.proto.decode(wire)
    if msg and msg.t == "ack" and msg.body.command == "step.report" then return true end
    return send(id, wire, protocol)
  end
  local began = a.n.time
  local events = {}
  local broadcast = a.t.env.rednet.broadcast
  a.t.env.rednet.broadcast = function(wire, protocol)
    if wire.t == "beacon" then events[#events+1] = (a.n.time-began)/1000 end
    return broadcast(wire, protocol)
  end
  local first = {x=a.t.pos.x,y=a.t.pos.y,z=a.t.pos.z}
  local steps = {{op=park and "inspectDown" or "forward"}}
  assert(a.s.env.SO.mods.lease.send(2,steps,{ms=2000}))
  a.n.flush()
  a.n.advance(1)
  local body
  for _, wire in ipairs(a.s.sent) do if wire.payload.t=="lease.batch" then body=wire.payload.body end end
  assert(body and body.ttl==2000)
  a.n.advance(64)
  F.check(a)
  assert(#events>0,"no expiry beacon")
  assert(H.encode(a.t.pos)==H.encode(first),"park moved or work did not backtrack")
  return events
end
return function(test, equal)
  test("clock harness separates game ticks, UTC and each computer boot",function()
    local n = H.new({tickRate=4})
    local a = n.machine({id=1})
    local wall = a.env.os.epoch("utc")
    equal(a.env.os.clock(),0)
    n.advanceReal(0.25)
    equal(a.env.os.clock(),1)
    equal(a.env.os.epoch("utc")-wall,250)
    local b=n.machine({id=2})
    equal(b.env.os.clock(),0)
    equal(a.env.os.clock(),1)
  end)
  test("clock preserves legacy UTC timers and reserves monotonic reboot time",function()
    for _, rate in ipairs({1,4}) do
      local n,m=clock(rate)
      local first=m.env.now()
      equal(first,n.utc())
      local retry=first+60000
      n.advance(12.25)
      equal(m.env.now()-first,12250)
      local saved=m.env.store.store("timers",function() return true end)
      assert(saved.save({retry=retry,seen=first}))
      local before=m.env.now()
      n.kill(m);n.advance(120)
      m=n.boot(m)
      assert(m.alive(),tostring(m.error))
      local after=m.env.now()
      assert(after>before and after-before<=1000,"clock went backwards or skipped more than its reservation")
      local timers=m.env.store.store("timers",function() return true end).value
      equal(timers.retry,retry);equal(timers.seen,first)
      n.advance((retry-after)/1000)
      equal(m.env.now(),retry)
    end
  end)
  test("clock refuses to issue unreserved time after a checkpoint failure",function()
    local n,m=clock(4)
    n.advance(2)
    local open=m.env.fs.open
    m.env.fs.open=function(path,mode)
      if path=="so-data/clock.tmp" and mode=="w" then error("disk failure") end
      return open(path,mode)
    end
    equal(m.env.now(),m.env.initial)
    equal(m.env.now(),m.env.initial)
    m.env.fs.open=open
    equal(m.env.now(),m.env.initial)
    n.advance(1)
    equal(m.env.now(),m.env.initial+1000)
  end)
  test("clock lease expiry, fast beacons, backtracking and parks match at 1x and 4x",function()
    equal(trace(4,false),trace(1,false))
    equal(trace(4,true),trace(1,true))
  end)
  test("clock legacy lease fallback and repeated leases retain the original deadline",function()
    for _, rate in ipairs({1,4}) do
      local a=F.setup(nil,nil,rate)
      local function send(body)
        local proto=a.s.env.SO.proto
        local msg=proto.build(a.s.env.SO.pair.key(2),"lease.batch",body)
        a.s.env.rednet.send(2,assert(proto.encode(msg)),"so");a.n.flush()
      end
      local body={lease="legacy",expires=a.n.utc()+2000,steps={{op="inspectDown"}}}
      send(body);a.n.advance(1)
      send(body);a.n.advance(1.1)
      assert(#F.sent(a.t,"beacon")>0,"retry extended the original expiry")
      F.check(a)
    end
  end)
  test("clock legacy servers can reuse a lease ID after reboot with a new UTC expiry",function()
    for _, rate in ipairs({1,4}) do
      local a=F.setup(nil,nil,rate)
      local function send(expires, op)
        local proto=a.s.env.SO.proto
        local msg=proto.build(a.s.env.SO.pair.key(2),"lease.batch",{
          lease="2-1",expires=expires,steps={{op=op}},
        })
        a.s.env.rednet.send(2,assert(proto.encode(msg)),"so");a.n.flush()
      end
      send(a.n.utc()+1000,"inspectDown");a.n.advance(1.1)
      send(a.n.utc()+2000,"forward");a.n.advance(0.2)
      equal(a.t.pos,{x=0,y=0,z=-1})
      local reports=F.sent(a.t,"step.report")
      assert(reports[#reports].body.results[1].ok,"old lease deadline blocked a new legacy lease")
      F.check(a)
    end
  end)
  test("clock a delayed retry cannot extend a batch queued behind other work",function()
    local n=H.new({tickRate=4})
    local m=n.machine({id=2,turtle=true})
    m.install({"worker.lua","so-proto.lua","so-pair.lua","so-store.lua"})
    local f=assert(io.open("worker.lua","rb"));local source=f:read("*a");f:close()
    local code,count=source:gsub("W.boot%(%)%s*$","return W")
    equal(count,1)
    local w=assert(load(code,"@worker.lua","t",m.env))()
    local key=string.rep("ab",32)
    w.server=1;w.lease="busy";w.expires=10000
    w.pair={repairHint=function() return false end,key=function() return key end}
    local sender=n.machine({id=1});sender.install({"so-proto.lua"})
    local proto=sender.env.dofile("so-proto.lua")
    local function accept(ttl)
      w.accept(1,assert(proto.encode(proto.build(key,"lease.batch",{
        lease="queued",ttl=ttl,expires=n.utc()+ttl,steps={{op="forward"}},
      }))))
    end
    accept(1000);n.advance(0.2);accept(900);n.advance(0.85)
    local results
    w.store=m.env.dofile("so-store.lua")
    w.journal={dim="minecraft:overworld"};w.pose={x=0,y=0,z=0,f=0}
    w.paint=function() end;w.save=function() return true end;w.counts=function() return {} end
    w.report=function(value) results=value end;w.enterFast=function() end
    w.startBatch(w.queued)
    equal(results[1].err,"expired")
    equal(m.pos,{x=0,y=0,z=0})
  end)
  test("clock a worker reboot clears local deadlines and a server reboot changes lease IDs",function()
    local a=F.setup(nil,{"so-mod-lease.lua"},4)
    local old=assert(a.s.env.SO.mods.lease.send(2,{{op="inspectDown"}},{ms=1000}))
    a.n.advance(2)
    a.n.kill(a.s);a.s=a.n.boot(a.s);a.n.flush()
    assert(a.s.alive(),tostring(a.s.error))
    local fresh=assert(a.s.env.SO.mods.lease.send(2,{{op="inspectDown"}},{ms=1000}))
    assert(fresh~=old,"lease ID repeated across server boots")
    a.n.advance(0.5)
    a.n.kill(a.t);a.t=a.n.boot(a.t);a.n.flush()
    a.n.advance(2)
    equal(#F.sent(a.t,"beacon"),0)
    equal(a.t.env.os.clock(),2)
    F.check(a)
  end)
  test("clock daily dates stay UTC while the recent-ore window uses game time",function()
    for _, rate in ipairs({1,4}) do
      local n,m=clock(rate)
      m.install({"so-mod-state.lua","so-mod-daily.lua","so-ui.lua"})
      local e=m.env
      e.SO={now=e.now,mods={},store=e.store}
      local state=e.dofile("so-mod-state.lua");e.SO.mods.state=state
      local daily=e.dofile("so-mod-daily.lua")
      local at=e.os.epoch("utc")
      assert(state.emit("mine.ore",{name="minecraft:diamond",count=3}))
      daily.tick(e.now())
      local date=daily.today().date
      n.advance(599.9);daily.tick(e.now());equal(daily.today().oreRecent,3)
      n.advance(0.1);daily.tick(e.now());equal(daily.today().oreRecent,0)
      equal(daily.today().ore,3);equal(daily.today().date,date)
      local event=state.history.page({count=1}).entries[1]
      equal(event.at,at);equal(event.gameAt,e.initial)
      equal(e.os.epoch("utc")-at,600000/rate)
    end
  end)
  test("clock recovery retry sends only the remaining game duration and a legacy UTC expiry",function()
    for _, rate in ipairs({1,4}) do
      local n,m=clock(rate)
      m.install({"so-mod-lease.lua","so-proto.lua"})
      m.files["so-server.cfg"]=H.encode({protectedAreas=false,alternateAxisOrders=false,storageDeliveries=false})
      m.env.SO={now=m.env.now,mods={},store=m.env.store,
        pair={key=function() return string.rep("ab",32) end},proto=m.env.dofile("so-proto.lua")}
      local lease=m.env.dofile("so-mod-lease.lua")
      assert(lease.send(2,{{op="inspectDown"}},{ms=5000,recover=true}))
      local first=m.sent[#m.sent].payload.body
      n.advance(1);lease.tick(m.env.now())
      local retry=m.sent[#m.sent].payload.body
      equal(first.ttl,5000);equal(retry.ttl,4000)
      equal(retry.expires-m.env.os.epoch("utc"),4000)
      equal(first.lease,retry.lease)
    end
  end)
end
