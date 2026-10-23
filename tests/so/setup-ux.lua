local H=dofile("tests/so/harness.lua")
local F=dofile("tests/so/worker-fixture.lua")
local modules={"so-plan.lua","so-ui.lua","so-log.lua","so-mod-state.lua","so-mod-lease.lua",
  "so-mod-cells.lua","so-mod-display.lua","so-mod-drops.lua","so-mod-mine.lua","so-mine-plan.lua",
  "so-mod-lumber.lua","so-lumber-plan.lua","so-mod-panel.lua"}
local function setup(enabled)
  local a=F.setup({id=2,modem=true,turtle=true,capacity=1000000,facing=1},modules)
  a.t.files["so-worker.cfg"]=H.encode({dim="minecraft:overworld"})
  a.s.files["so-server.cfg"]=H.encode({setupMovement=enabled,pos={dim="minecraft:overworld",x=40,y=64,z=10}})
  a.n.advance(3)
  a.t.env.gps={locate=function() return a.t.pos.x+40,a.t.pos.y+64,a.t.pos.z+10 end}
  local function hello()
    local seen=F.sent(a.t,"hello")[#F.sent(a.t,"hello")].body
    local body={role="turtle",label="setup-turtle\n123456789",journal=a.t.files["so-journal"] and F.journal(a.t) or seen.journal,capabilities=seen.capabilities,
      fuel=1000,gps={dim="minecraft:overworld",x=a.t.pos.x+40,y=a.t.pos.y+64,z=a.t.pos.z+10}}
    local proto=a.t.env.dofile("so-proto.lua")
    a.t.env.rednet.send(1,proto.encode(proto.build(string.rep("a",64),"hello",body)),"so")
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
      equal(a.s.env.SO.mods.cells.list("setup:2",100),{})
    end)
  end
  test("setup movement defaults off and never sends a lease",function()
    local a=setup()
    a.ui.input({text="scan 2"})
    equal(#F.sent(a.s,"lease.batch"),0)
    equal({a.t.pos.x,a.t.pos.z,a.t.heading},{0,0,1})
    assert(text(a.ui.render(29,12)):find("setup movement disabled",1,true))
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
