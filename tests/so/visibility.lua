local H = dofile("tests/so/harness.lua")
local setup = dofile("tests/so/minor-ui-fixture.lua")
local function prepare(server)
  server.install({"so-ui.lua","so-errors.lua","so-mod-health.lua","so-mod-panel.lua"})
end
local function has(frame,text)
  for _,row in ipairs(frame.rows) do if row.text:find(text,1,true) then return true end end
  return false
end
return function(test,equal)
  test("visibility error ring survives restart, rate limits and caps all generations",function()
    local net=H.new()
    local m=net.machine({id=1})
    m.install({"so-store.lua","so-errors.lua"})
    local store=m.env.dofile("so-store.lua")
    local errors=m.env.dofile("so-errors.lua").open(store,function() return net.time end)
    assert(errors.record("first error"))
    local first=m.files["so-data/errors"]
    for i=1,200 do errors.record(i..string.rep("\n\0\255",1000)) end
    equal(m.files["so-data/errors"],first)
    net.time=net.time+30000
    assert(errors.flush())
    local status=errors.status()
    assert(status.bytes<=status.cap and status.count<=128)
    local restarted=m.env.dofile("so-errors.lua").open(store,function() return net.time end)
    local entries=restarted.entries()
    assert(entries[#entries].text:find("200",1,true))
    entries[#entries].text="mutated"
    assert(restarted.entries()[#entries].text~="mutated")
    net.time=net.time+30000
    assert(restarted.record("after restart"))
    assert(restarted.status().bytes<=65536)
    local save=store.store
    store.store=function(...)
      local box=save(...)
      box.save=function() return false,"disk full" end
      return box
    end
    local failing=m.env.dofile("so-errors.lua").open(store,function() return net.time end)
    assert(not failing.record("retry me"))
    equal(failing.status().error,"disk full")
    assert(failing.status().pending)
  end)

  test("visibility attention facts appear, link to fixes and clear",function()
    local s=setup(26,20,prepare)
    local mod=s.server.env.SO.mods.health
    local f={now=200000,disk={ratio=.85},points={{id="ore",broken=true}},
      jobs={lumber={blocked="hold",turtle={id=8}},mining={turtles={["7"]={state="hold",error="ore full"}}}},
      machines={["7"]={seen=1},["8"]={seen=200000}},leases={["7"]={lost=true},["8"]={uncertain=true}},
      retirement={status="pending"},pairing=true,requests={{id=9}}}
    local rows=mod.attention(f)
    equal(#rows,9)
    local keys={}
    for _,row in ipairs(rows) do keys[row.key]=row end
    equal(keys["pose/8"].target,"lumber")
    equal(keys["drop/ore"].actions,{"list","select:ore"})
    equal(keys.disk.target,"health")
    equal(#mod.attention({now=0,disk={},jobs={},machines={}}),0)
  end)

  test("visibility shows each lumber worker hold and clears it independently",function()
    local s=setup(26,20,prepare)
    local facts={now=0,disk={},jobs={lumber={turtles={
      ["7"]={turtle={id=7},blocked="hold",alert="fuel chest empty"},
      ["8"]={turtle={id=8},alert="out of saplings"},
    }}}}
    local rows=s.server.env.SO.mods.health.attention(facts)
    equal(#rows,2)
    local targets={}
    for _,row in ipairs(rows) do targets[row.key]=row.target end
    equal(targets["lumber/7"],"lumber")
    equal(targets["lumber/8"],"lumber")
    facts.jobs.lumber.turtles["7"].blocked=nil
    facts.jobs.lumber.turtles["7"].alert=nil
    rows=s.server.env.SO.mods.health.attention(facts)
    equal(#rows,1)
    equal(rows[1].key,"lumber/8")
  end)

  test("visibility records tick, handler and listener failures",function()
    local s=setup(26,20,prepare)
    local so=s.server.env.SO
    local mod=so.mods.health
    local tick=mod.tick
    mod.tick=function() error("fixture tick") end
    s.net.advance(1)
    mod.tick=tick
    mod.handlers["visibility.fail"]=function() error("fixture handler") end
    local proto=s.client.env.dofile("so-proto.lua")
    local msg=proto.build(so.pair.key(2),"visibility.fail",{})
    s.client.env.rednet.send(1,proto.encode(msg),"so")
    s.net.flush()
    mod.listen={visibility=function() error("fixture listener") end}
    s.client.env.rednet.send(1,"fixture","visibility")
    s.net.flush()
    local entries=so.errors.entries()
    local text=""
    for _,entry in ipairs(entries) do text=text..entry.text end
    assert(text:find("fixture tick",1,true) and text:find("fixture handler",1,true) and text:find("fixture listener",1,true))
  end)

  test("visibility forged bad-MAC flood preserves earlier handler errors",function()
    local s=setup(26,20,prepare)
    local so=s.server.env.SO
    so.mods.health.handlers["visibility.fail"]=function() error("earlier handler error") end
    local proto=s.client.env.dofile("so-proto.lua")
    local msg=proto.build(so.pair.key(2),"visibility.fail",{})
    s.client.env.rednet.send(1,proto.encode(msg),"so")
    s.net.flush()
    local before=so.errors.entries()
    assert(before[#before].text:find("earlier handler error",1,true))
    local records,record=0,so.errors.record
    so.errors.record=function(...)
      records=records+1
      return record(...)
    end
    local last=msg.mac:sub(-1)
    msg.mac=msg.mac:sub(1,-2)..(last=="a" and "b" or "a")
    local forged=proto.encode(msg)
    for _=1,500 do s.client.env.rednet.send(1,forged,"so") end
    s.net.flush()
    assert(not s.server.error,tostring(s.server.error))
    equal(records,0)
    equal(so.errors.entries(),before)
    local log=so.terminal.log
    assert(log[#log]:find("bad mac from 2",1,true))
  end)

  test("visibility snapshot diagnostics survive restart",function()
    local net=H.new()
    local m=net.machine({id=1,directories=true})
    m.install({"so-log.lua","so-store.lua"})
    local store=m.env.dofile("so-store.lua")
    local log=m.env.dofile("so-log.lua").open(store)
    assert(log.append({kind="test",at=net.time,data={}}))
    assert(log.checkpoint({values={},machines={},jobs={},gameAt=net.time}))
    local status=log.status()
    equal(status.snapshot,1);equal(status.snapshotAt,net.time)
    local restarted=m.env.dofile("so-log.lua").open(store).status()
    equal(restarted.seq,status.seq);equal(restarted.snapshotAt,status.snapshotAt)
    equal(restarted.bytes,status.bytes)
  end)

  for _,size in ipairs({{26,20},{29,12}}) do
    test("visibility drawn screen navigation and history at "..size[1].."x"..size[2],function()
      local s=setup(size[1],size[2],prepare)
      local so=s.server.env.SO
      if s.frame().role=="status" then s.press("MORE") end
      s.press("HEALTH");equal(s.frame().role,"health")
      assert(has(s.frame(),"Uptime") and has(s.frame(),"Tick") and has(s.frame(),"Events"))
      s.press("NEXT")
      assert(has(s.frame(),"Modems") and has(s.frame(),"Paired"))
      s.press("PREV")
      s.press("ERRORS");equal(s.frame().role,"errors")
      so.error("visibility test failure")
      s.net.advance(5)
      assert(has(s.frame(),"visibility test"))
      for i=1,60 do so.mods.state.emit(i%2==0 and "mine.alert" or "mine.ore",{text="message "..i}) end
      so.mods.state.emit("mine.alert",false)
      s.press("ALERTS");equal(s.frame().role,"alerts")
      assert(has(s.frame(),"message 60"))
      s.press("NEXT");assert(not has(s.frame(),"message 60"))
      s.press("PREV");assert(has(s.frame(),"message 60"))
      s.press("EVENTS");equal(s.frame().role,"events")
      s.press("KIND ALL")
      assert(has(s.frame(),"KIND mine.alert"))
      s.press("NEXT");assert(not has(s.frame(),"message 60"))
      s.press("PREV")
      local latest=so.mods.state.history.page({reverse=true,count=2,kind="mine.ore"})
      equal(latest.entries[1].data.text,"message 59")
      equal(so.mods.state.history.page({reverse=true,before=latest.next,count=2,kind="mine.ore"}).entries[1].data.text,"message 55")
      assert(so.mods.drops.add({id="broken",kind="ore",side="front",dim=0,x=1,y=64,z=0}))
      for _=1,3 do so.mods.drops.note("broken",nil) end
      s.net.advance(6)
      s.press("NEEDS 1");equal(s.frame().role,"attention")
      s.press("Chest broken broken");equal(s.frame().role,"generic")
      s.press("FIX #1")
      s.net.advance(6)
      s.press("ATTENTION");assert(has(s.frame(),"All clear"))
      s.press("BACK");s.press("PANEL")
      s.press("HEALTH");equal(s.frame().role,"health")
      s.press("BACK");s.press("PANEL");s.press("ALERTS");equal(s.frame().role,"alerts")
      -- Saved roles recover after the server restarts.
      local fresh=s.net.boot(s.server)
      s.net.advance(5)
      assert(not fresh.error,tostring(fresh.error))
      local frame
      fresh.env.SO.mods.display.handlers["view.get"]({from=2},function(_,body) frame=body end)
      equal(frame.role,"alerts")
    end)
  end
end
