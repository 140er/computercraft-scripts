local H=dofile("tests/so/harness.lua")
local F=dofile("tests/so/worker-fixture.lua")
local modules={"so-plan.lua","so-ui.lua","so-log.lua","so-mod-state.lua","so-mod-lease.lua",
  "so-mod-cells.lua","so-mod-display.lua","so-mod-drops.lua","so-mod-mine.lua","so-mine-plan.lua",
  "so-mod-lumber.lua","so-lumber-plan.lua","so-mod-panel.lua"}
local function setup(enabled, protected)
  local a=F.setup({id=2,modem=true,turtle=true,capacity=1000000,facing=1},modules)
  a.t.files["so-worker.cfg"]=H.encode({dim="minecraft:overworld"})
  a.s.files["so-server.cfg"]=H.encode({setupMovement=enabled,protectedAreas=protected,pos={dim="minecraft:overworld",x=40,y=64,z=10}})
  if protected then a.n.kill(a.s) a.s=a.n.boot(a.s) a.n.flush() end
  a.n.advance(3)
  a.t.env.gps={locate=function() return a.t.pos.x+40,a.t.pos.y+64,a.t.pos.z+10 end}
  local function hello(fuel)
    local seen=F.sent(a.t,"hello")[#F.sent(a.t,"hello")].body
    local body={role="turtle",label="setup-turtle\n123456789",journal=a.t.files["so-journal"] and F.journal(a.t) or seen.journal,capabilities=seen.capabilities,
      fuel=fuel==nil and a.t.env.turtle.getFuelLevel() or fuel,gps={dim="minecraft:overworld",x=a.t.pos.x+40,y=a.t.pos.y+64,z=a.t.pos.z+10}}
    local proto=a.t.env.dofile("so-proto.lua")
    a.helloSeq=(a.helloSeq or 0)+1
    a.t.env.rednet.send(1,proto.encode(proto.build(string.rep("a",64),"hello",body,"setup-hello-"..a.helloSeq)),"so")
    a.n.flush()
  end
  hello()
  a.hello=hello
  a.ui=a.s.env.SO.mods.display.screen("generic")
  return a
end
local function press(ui,w,h,id,session)
  local frame=ui.render(w,h,session)
  for _,b in ipairs(frame.buttons) do
    if b.id==id then
      assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h,"button outside frame")
      assert(frame.rows[b.y].text:find(b.label,1,true),"button not drawn: "..id)
      ui.input({id=id,session=session})
      return
    end
  end
  error("missing button "..id)
end
local function text(frame)
  local rows={} for _,row in ipairs(frame.rows) do rows[#rows+1]=row.text end
  return table.concat(rows,"\n")
end
return function(test,equal)
  test("protected setup acknowledges a complete visit and can reuse its occupied GPS cell",function()
    local a=setup(true,true)
    assert(a.s.env.SO.mods.drops.add({id="ore",dim=0,x=43,y=63,z=10,side="down",kind="ore"}))
    a.n.world["3,-1,0"]="minecraft:chest"
    a.ui.input({text="test ore"})
    press(a.ui,29,12,"facing:1",{})
    a.n.advance(5) F.check(a)
    assert(a.s.env.SO.mods.drops.list()[1].verified)
    local before=#F.sent(a.s,"lease.batch")
    a.hello()
    a.ui.input({text="test ore"})
    a.n.advance(5) F.check(a)
    assert(#F.sent(a.s,"lease.batch")>before,"occupied GPS cell blocked a new visit")
    equal(a.s.env.SO.mods.cells.list("setup:2",100),{})
    equal({a.t.pos.x,a.t.pos.y,a.t.pos.z},{0,0,0})
  end)
  for _,failure in ipairs({"move","turn"}) do
    test("protected setup "..failure.." failure sends no remainder and keeps the route",function()
      local a=setup(true,true)
      local session={}
      local failed=false
      local op=failure=="move" and "forward" or "turnRight"
      a.t.env.turtle[op]=function() failed=true return false,"blocked" end
      if failure=="move" then
        assert(a.s.env.SO.mods.drops.add({id="ore",dim=0,x=43,y=63,z=10,side="down",kind="ore"}))
        a.ui.input({text="test ore"})
      else
        press(a.ui,29,12,"testing",session)
        press(a.ui,29,12,"scan:2",session)
      end
      press(a.ui,29,12,"facing:1",session)
      a.n.advance(5) F.check(a)
      assert(failed,"setup did not reach the injected boundary")
      local sent=F.sent(a.s,"lease.batch")
      local count=#sent
      a.n.advance(5) F.check(a)
      equal(#F.sent(a.s,"lease.batch"),count)
      for _,q in ipairs(sent) do
        equal(#q.body.steps,1)
        assert(q.body.journal and q.body.steps[1].park)
      end
      assert(#a.s.env.SO.mods.cells.list("setup:2",100)>0,"failed setup released its route")
      equal({a.t.pos.x,a.t.pos.y,a.t.pos.z},{0,0,0})
    end)
  end
  test("protected setup assesses its entire test route before reserving or sending",function()
    local a=setup(true,true)
    local cells=a.s.env.SO.mods.cells
    assert(cells.protect({{id="build",dim="minecraft:overworld",x1=41,x2=42,y1=64,y2=64,z1=10,z2=10}}))
    assert(a.s.env.SO.mods.drops.add({id="ore",dim=0,x=43,y=63,z=10,side="down",kind="ore"}))
    a.ui.input({text="test ore"})
    press(a.ui,29,12,"facing:1",{})
    a.n.advance(3) F.check(a)
    equal(#F.sent(a.s,"lease.batch"),0)
    equal(cells.list("setup:2",100),{})
    assert(text(a.ui.render(29,12)):find("protected",1,true))
  end)
  for _,size in ipairs({{26,20},{29,12}}) do
    local w,h=size[1],size[2]
    test("setup scans adjacent chests through drawn controls at "..w.."x"..h,function()
      local a=setup(true)
      a.n.world["1,0,0"]="minecraft:chest"
      a.n.world["0,-1,0"]="minecraft:barrel"
      a.n.world["0,0,1"]="minecraft:stone"
      local session={}
      press(a.ui,w,h,"testing",session)
      press(a.ui,w,h,"scan:2",session)
      press(a.ui,w,h,"facing:1",session)
      a.n.advance(4)
      F.check(a)
      equal({a.t.pos.x,a.t.pos.y,a.t.pos.z,a.t.heading},{0,0,0,1})
      local f=a.ui.render(w,h,session)
      assert(text(f):find("40,63,10",1,true),text(f))
      assert(text(f):find("41,64,10",1,true),text(f))
      press(a.ui,w,h,"candidate:1",session)
      press(a.ui,w,h,"add",session)
      local point=a.s.env.SO.mods.drops.list()[1]
      equal({point.x,point.y,point.z,point.kind,point.side},{40,63,10,"ore","down"})
      for _,packet in ipairs(F.sent(a.s,"lease.batch")) do assert(packet.body.steps[1].park) end
      local cells=a.s.env.SO.mods.cells
      equal(cells.list("setup:2",100),{})
      equal(cells.owner(40,64,10,"minecraft:overworld"),"gps:2")
      assert(not cells.reserve("other",40,64,10,"minecraft:overworld"))
    end)
  end
  for _,fuel in ipairs({3,6,"unlimited"}) do
    test("setup visit budgets the complete return trip with fuel "..fuel,function()
      local a=setup(true)
      a.t.fuel=fuel a.hello()
      local cells=a.s.env.SO.mods.cells
      assert(a.s.env.SO.mods.drops.add({id="ore",dim=0,x=43,y=63,z=10,side="down",kind="ore"}))
      a.n.world["3,-1,0"]="minecraft:chest"
      a.ui.input({text="test ore"})
      press(a.ui,29,12,"facing:1",{})
      a.n.advance(5) F.check(a)
      equal({a.t.pos.x,a.t.pos.y,a.t.pos.z},{0,0,0})
      equal(cells.list("setup:2",100),{})
      if fuel==3 then
        equal(#F.sent(a.s,"lease.batch"),0)
        assert(text(a.ui.render(29,12)):find("fuel #2: need 6, have 3",1,true))
        equal(a.s.env.SO.mods.drops.list()[1].verified,nil)
      else
        assert(a.s.env.SO.mods.drops.list()[1].verified)
        equal(cells.owner(40,64,10,"minecraft:overworld"),"gps:2")
        assert(not cells.reserve("other",40,64,10,"minecraft:overworld"))
        a.n.kill(a.s) a.s=a.n.boot(a.s) a.n.flush()
        equal(a.s.env.SO.mods.cells.owner(40,64,10,"minecraft:overworld"),"gps:2")
      end
    end)
  end
  test("setup refuses a visit with an unknown fuel report",function()
    local a=setup(true) a.hello(false)
    assert(a.s.env.SO.mods.drops.add({id="ore",dim=0,x=43,y=63,z=10,side="down",kind="ore"}))
    a.ui.input({text="test ore"}) press(a.ui,29,12,"facing:1",{})
    equal(#F.sent(a.s,"lease.batch"),0)
    assert(text(a.ui.render(29,12)):find("fuel #2 unknown",1,true))
  end)
  test("setup keeps its route when the occupied-cell handoff cannot save",function()
    local a=setup(true)
    local cells=a.s.env.SO.mods.cells
    local handoff=cells.handoff
    cells.handoff=function() return false,"disk full" end
    a.ui.input({text="scan 2"}) press(a.ui,29,12,"facing:1",{})
    a.n.advance(4) F.check(a)
    equal(cells.owner(40,64,10,"minecraft:overworld"),"setup:2")
    assert(not cells.reserve("other",40,64,10,"minecraft:overworld"))
    cells.handoff=handoff
    a.hello() a.ui.input({text="release 2"}) a.n.advance(1)
    equal(cells.owner(40,64,10,"minecraft:overworld"),"gps:2")
  end)
  test("setup movement defaults off and never sends a lease",function()
    local a=setup()
    a.ui.input({text="scan 2"})
    equal(#F.sent(a.s,"lease.batch"),0)
    equal({a.t.pos.x,a.t.pos.z,a.t.heading},{0,0,1})
    assert(text(a.ui.render(29,12)):find("setupMovement off",1,true))
  end)
  test("FACING prompt: BACK shows the list, CANCEL the turtles, other refusals clear it",function()
    local a=setup(true)
    local session={}
    press(a.ui,29,12,"testing",session)
    press(a.ui,29,12,"scan:2",session)
    assert(text(a.ui.render(29,12,session)):find("FACING #2",1,true))
    press(a.ui,29,12,"list",session)
    local f=text(a.ui.render(29,12,session))
    assert(f:find("DROP",1,true) and not f:find("FACING",1,true),f)
    press(a.ui,29,12,"testing",session)
    press(a.ui,29,12,"scan:2",session)
    press(a.ui,29,12,"facing-cancel",session)
    f=text(a.ui.render(29,12,session))
    assert(f:find("TURTLES",1,true) and not f:find("FACING",1,true),f)
    press(a.ui,29,12,"scan:2",session)
    local lease=a.s.env.SO.mods.lease
    local old=lease.status
    lease.status=function(id) local status=old(id) status.parkBatch=false return status end
    press(a.ui,29,12,"facing:1",session)
    lease.status=old
    f=text(a.ui.render(29,12,session))
    assert(f:find("update worker",1,true) and f:find("TURTLES",1,true) and not f:find("FACING",1,true),f)
    equal(#F.sent(a.s,"lease.batch"),0)
  end)
  test("drop visit verifies persists and returns; a miss clears verification",function()
    local a=setup(true)
    local drops=a.s.env.SO.mods.drops
    assert(drops.add({id="ore",dim=0,x=43,y=63,z=10,side="down",kind="ore"}))
    a.n.world["3,-1,0"]="minecraft:chest"
    a.ui.input({text="test ore"})
    press(a.ui,29,12,"facing:1",{})
    a.n.advance(5)
    F.check(a)
    equal({a.t.pos.x,a.t.pos.y,a.t.pos.z,a.t.heading},{0,0,0,1})
    local p=drops.list()[1]
    assert(p.verified and p.verified.block=="minecraft:chest")
    local saved=a.s.env.SO.store.store("so-drops",function() return true end).value
    equal(saved.points[1].verified,p.verified)
    a.n.world["3,-1,0"]=nil
    a.n.world["4,-1,0"]="minecraft:chest"
    a.hello()
    a.ui.input({text="test ore"})
    a.n.advance(5)
    equal(drops.list()[1].verified,nil)
    equal(saved.points[1].verified.block,"minecraft:chest")
    local plan=a.s.env.dofile("so-plan.lua")
    assert(plan.chestCheck(drops.list(),"ore",{dim=0,x=40,y=64,z=10}).ok)
  end)
  test("setup refuses reserved cells, mining lane, and old workers",function()
    local a=setup(true)
    local lease=a.s.env.SO.mods.lease
    local old=lease.status
    lease.status=function(id) local status=old(id) status.parkBatch=false return status end
    a.ui.input({text="scan 2"})
    equal(#F.sent(a.s,"lease.batch"),0)
    lease.status=old
    local mine=a.s.env.SO.mods.mine
    local original=mine.mapView
    mine.mapView=function() return {dim="minecraft:overworld",homeSet=true,home={x=39,y=64,z=10,facing=1},bottom=60,branches=1} end
    a.ui.input({text="scan 2"})
    press(a.ui,29,12,"facing:1",{})
    equal(#F.sent(a.s,"lease.batch"),0)
    mine.mapView=original
    assert(a.s.env.SO.mods.cells.reserve("other",40,64,10,"minecraft:overworld"))
    a.ui.input({text="scan 2"})
    press(a.ui,29,12,"facing:1",{})
    equal(#F.sent(a.s,"lease.batch"),0)
  end)
  test("setup blocked move stops and holds cells until a fresh pose releases them",function()
    local a=setup(true)
    assert(a.s.env.SO.mods.drops.add({id="ore",dim=0,x=43,y=63,z=10,side="down",kind="ore"}))
    a.n.world["1,0,0"]="minecraft:stone"
    a.ui.input({text="test ore"})
    press(a.ui,29,12,"facing:1",{})
    a.n.advance(3)
    equal({a.t.pos.x,a.t.pos.z},{0,0})
    assert(#a.s.env.SO.mods.cells.list("setup:2",100)>0)
    equal(#F.sent(a.s,"lease.batch"),1)
    a.hello()
    a.ui.input({text="release 2"})
    a.n.advance(1)
    equal(a.s.env.SO.mods.cells.list("setup:2",100),{})
  end)
  for _,restart in ipairs({false,true}) do
    test("failed setup stays busy after an unconfirmed release"..(restart and " across restart" or " live"),function()
      local a=setup(true)
      assert(a.s.env.SO.mods.drops.add({id="ore",dim=0,x=43,y=63,z=10,side="down",kind="ore"}))
      a.n.world["1,0,0"]="minecraft:stone"
      a.ui.input({text="test ore"}) press(a.ui,29,12,"facing:1",{})
      a.n.advance(3) F.check(a)
      local cells=a.s.env.SO.mods.cells
      local function ordered(list)
        table.sort(list,function(a,b)
          if a.dim~=b.dim then return a.dim<b.dim end
          if a.x~=b.x then return a.x<b.x end
          if a.y~=b.y then return a.y<b.y end
          return a.z<b.z
        end)
        return list
      end
      local held=ordered(cells.list("setup:2",100))
      assert(#held>0 and a.s.env.SO.mods.drops.busy(2))
      a.t.env.gps.locate=function() return nil end
      a.hello()
      local send=a.t.env.rednet.send
      local pending
      if restart then a.t.env.rednet.send=function(id,payload,protocol)
        if payload.t=="step.report" then pending=payload return true end
        return send(id,payload,protocol)
      end end
      a.ui.input({text="release 2"}) a.n.advance(1) F.check(a)
      if restart then
        assert(pending,"missing release report")
        a.n.kill(a.s) a.s=a.n.boot(a.s) a.n.flush() a.n.advance(1)
        a.ui=a.s.env.SO.mods.display.screen("generic")
        send(1,pending,"so") a.n.flush() a.n.advance(1) F.check(a)
      end
      assert(a.s.env.SO.mods.drops.busy(2),"release report forgot the failed task")
      equal(ordered(a.s.env.SO.mods.cells.list("setup:2",100)),held)
      local task=a.s.env.SO.store.read("so-data/cells/setup").value.task
      assert(task and task.failed and task.id==2,"failed task was not persisted")
      local session={}
      a.ui.input({id="testing",session=session})
      local release=false
      for _,b in ipairs(a.ui.render(29,12,session).buttons) do if b.id=="release" then release=true end end
      assert(release,"held setup lost its release control")
    end)
  end
  test("setup refuses stale fixes and retains its route after a lost report",function()
    local a=setup(true)
    a.n.advance(61)
    a.ui.input({text="scan 2"})
    equal(#F.sent(a.s,"lease.batch"),0)
    a.hello()
    local send=a.t.env.rednet.send
    a.t.env.rednet.send=function(id,payload,protocol)
      if payload.t=="step.report" then return true end
      return send(id,payload,protocol)
    end
    a.ui.input({text="scan 2"})
    press(a.ui,29,12,"facing:1",{})
    a.n.advance(27)
    F.check(a)
    assert(#a.s.env.SO.mods.cells.list("setup:2",100)>0)
    equal(a.s.env.SO.mods.drops.list(),{})
    equal({a.t.pos.x,a.t.pos.z},{0,0})
  end)
  test("setup elevated drop retraces its outward route",function()
    local a=setup(true)
    assert(a.s.env.SO.mods.drops.add({id="high",dim=0,x=43,y=65,z=10,side="down",kind="ore"}))
    a.n.world["3,1,0"]="minecraft:chest"
    a.ui.input({text="test high"})
    press(a.ui,29,12,"facing:1",{})
    a.n.advance(6)
    F.check(a)
    assert(a.s.env.SO.mods.drops.list()[1].verified)
    equal({a.t.pos.x,a.t.pos.y,a.t.pos.z,a.t.heading},{0,0,0,1})
    equal(a.s.env.SO.mods.cells.list("setup:2",100),{})
  end)
  test("setup release fences delayed movement after restart and permits another scan",function()
    local a=setup(true)
    assert(a.s.env.SO.mods.drops.add({id="ore",dim=0,x=43,y=63,z=10,side="down",kind="ore"}))
    local send=a.s.env.rednet.send
    local delayed
    a.s.env.rednet.send=function(id,payload,protocol)
      if payload.t=="lease.batch" then delayed=payload return true end
      return send(id,payload,protocol)
    end
    a.ui.input({text="test ore"})
    press(a.ui,29,12,"facing:1",{})
    assert(delayed)
    a.n.kill(a.s)
    a.s=a.n.boot(a.s)
    a.n.flush() a.n.advance(3)
    a.ui=a.s.env.SO.mods.display.screen("generic")
    a.hello()
    equal(a.s.env.SO.mods.lease.status(2).open,delayed.body.lease)
    a.ui.input({text="release 2"})
    assert(#a.s.env.SO.mods.cells.list("setup:2",100)>0,"open lease released its route")
    a.n.advance(26)
    a.hello() a.n.advance(1) a.hello()
    a.ui.input({text="release 2"})
    a.n.advance(1)
    equal(a.s.env.SO.mods.cells.list("setup:2",100),{})
    a.s.env.rednet.send(2,delayed,"so")
    a.n.flush() a.n.advance(1)
    equal({a.t.pos.x,a.t.pos.y,a.t.pos.z},{0,0,0})
    a.hello()
    a.ui.input({text="scan 2"})
    local frame=a.ui.render(29,12,{})
    for _,b in ipairs(frame.buttons) do if b.id=="facing:1" then press(a.ui,29,12,"facing:1",{}) break end end
    a.n.advance(4)
    F.check(a)
    equal(a.s.env.SO.mods.cells.list("setup:2",100),{})
    assert(not text(a.ui.render(29,12,{})):find("held",1,true))
  end)
  test("setup restart reconciles a saved inspection once when its caller receipt save failed",function()
    local a=setup(true)
    assert(a.s.env.SO.mods.drops.add({id="missing",dim=0,x=43,y=63,z=10,side="down",kind="ore"}))
    local open=a.s.env.fs.open
    a.s.env.fs.open=function(path,mode)
      if path=="so-data/cells/setup.tmp" and mode=="w" then
        local value=a.s.env.SO.store.read("so-drops")
        if value and value.value.points[1].fails==1 then return nil end
      end
      return open(path,mode)
    end
    a.ui.input({text="test missing"}) press(a.ui,29,12,"facing:1",{})
    a.n.advance(4) F.check(a)
    equal(a.s.env.SO.store.read("so-drops").value.points[1].fails,1)
    assert(a.s.env.SO.mods.lease.outcome(2),"failed caller save acknowledged the inspection")
    local before=#F.sent(a.s,"lease.batch")
    a.n.kill(a.s) a.s=a.n.boot(a.s) a.n.flush() a.n.advance(1) F.check(a)
    equal(a.s.env.SO.store.read("so-drops").value.points[1].fails,1)
    equal(a.s.env.SO.mods.lease.outcome(2),nil)
    for _,batch in ipairs(F.sent(a.s,"lease.batch")) do
      for _,step in ipairs(batch.body.steps) do equal(step.op,"gps") end
    end
    assert(before>0)
    assert(#a.s.env.SO.mods.cells.list("setup:2",100)>0)
  end)
  test("setup fenced work refuses a failed pending-journal save without moving",function()
    local a=setup(true)
    a.t.capacity=1
    a.ui.input({text="scan 2"})
    press(a.ui,29,12,"facing:1",{})
    a.n.advance(3)
    F.check(a)
    equal({a.t.pos.x,a.t.pos.y,a.t.pos.z,a.t.heading},{0,0,0,1})
    assert(#a.s.env.SO.mods.cells.list("setup:2",100)>0)
  end)
  test("setup labels persist and update with heartbeat coalescing enabled",function()
    local a=setup(false)
    a.s.files["so-server.cfg"]=H.encode({state={coalesceHeartbeats=true},pos={dim="minecraft:overworld",x=40,y=64,z=10}})
    a.n.kill(a.s) a.s=a.n.boot(a.s) a.n.flush() a.n.advance(2)
    a.hello()
    local state=a.s.env.SO.mods.state
    equal(state.get("machines/2").label,"setup-turtle1234")
    state.handlers.hello({from=2,body={role="turtle",label="renamed"}})
    equal(state.get("machines/2").label,"renamed")
  end)
  for _,size in ipairs({{26,20},{29,12}}) do
    test("display rejects hidden setup and job controls at "..size[1].."x"..size[2],function()
      local a=setup(true)
      local display=a.s.env.SO.mods.display
      display.handlers.hello({from=3,body={w=size[1],h=size[2],keyboard=true}})
      local function frame()
        local f
        display.handlers["view.get"]({from=3},function(_,body) f=body end)
        return f
      end
      local function send(id)
        display.handlers.input({from=3,body={id=id,x=1,y=1}})
      end
      local function pressVisible(id)
        local f=frame()
        for _,b in ipairs(f.buttons) do if b.id==id then
          display.handlers.input({from=3,body={id=id,x=b.x,y=b.y}}) return
        end end
        error("missing displayed control "..id)
      end
      local f=frame()
      local packetCount=#F.sent(a.s,"lease.batch")
      for _,id in ipairs({"test","scan:2","facing:1","mining:start","turtle-park"}) do send(id) end
      equal(#F.sent(a.s,"lease.batch"),packetCount)
      equal(frame().role,f.role)
      -- Roles change only by assignment.
      assert(display.assign(3,"generic"))
      equal(frame().role,"generic")
      for _,id in ipairs({"test","scan:2","facing:1","mining:start","turtle-park"}) do send(id) end
      equal(#F.sent(a.s,"lease.batch"),packetCount)
      assert(not a.s.env.SO.mods.state.get("mine.alert"))
      assert(display.assign(3,"panel")) frame()
      local before=a.s.env.SO.mods.state.get("mine.alert")
      send("start") send("scan:2") send("test")
      equal(a.s.env.SO.mods.state.get("mine.alert"),before)
      pressVisible("mining:start")
      assert(a.s.env.SO.mods.state.get("mine.alert"))
      assert(display.assign(3,"generic")) pressVisible("testing")
      pressVisible("scan:2") pressVisible("facing:1")
      a.n.advance(4) F.check(a)
      assert(#F.sent(a.s,"lease.batch")>packetCount)
      frame()
      packetCount=#F.sent(a.s,"lease.batch")
      send("facing:1")
      equal(#F.sent(a.s,"lease.batch"),packetCount)
    end)
  end
  test("panel shows refused start and clears reason on stop; picker uses clipped labels",function()
    local a=setup(false)
    local mods=a.s.env.SO.mods
    local panel=mods.display.screen("panel")
    local session={id=3}
    press(panel,29,12,"mining:start",session)
    assert(text(panel.render(29,12,session)):find("home not set",1,true))
    press(panel,29,12,"mining:stop",session)
    assert(not text(panel.render(29,12,session)):find("home not set",1,true))
    equal(mods.state.get("machines/2").label,"setup-turtle1234")
    mods.state.emit("pair.done",{id=2,at=a.s.env.SO.now()})
    a.n.advance(1)
    assert(text(panel.render(29,12,session)):find("Paired turtle #2",1,true))
    a.n.advance(31)
    assert(not text(panel.render(29,12,session)):find("Paired",1,true))
  end)
end
