local H = dofile("tests/so/harness.lua")
local function setup(config)
  local n=H.new()
  local m=n.machine({id=1,capacity=16000000})
  m.install({"so-store.lua","so-ui.lua","so-mod-ar.lua","so-mod-map.lua","so-mod-drops.lua"})
  m.files["so-server.cfg"]=H.encode(config or {pos={dim="minecraft:overworld",x=0,y=64,z=0}})
  local s={points={},mine={},screens={},elements={}}
  local mods={state={get=function() return {} end,view=function() return {} end},
    drops={list=function() return s.points end},mine={mapView=function() return s.mine end},
    display={screen=function(role,render,input) s.screens[role]={render=render,input=input} end}}
  m.env.SO={store=m.env.dofile("so-store.lua"),proto={ser=H.encode},mods=mods}
  local ar={update=function() end,delete=function(id) s.elements[id]=nil end}
  for _,method in ipairs({"drawLine3D","drawText3D","drawText2D","drawRect2D"}) do
    ar[method]=function(id,...) s.elements[id]={method=method,args={...}} end
  end
  m.env.peripheral.find=function(kind) if kind=="ar_controller" then return ar end end
  s.ar=m.env.dofile("so-mod-ar.lua")
  s.map=m.env.dofile("so-mod-map.lua")
  s.m,s.mods=m,mods
  return s
end
local function button(frame,id)
  for _,b in ipairs(frame.buttons) do if b.id==id then
    local row=frame.rows[b.y+math.floor((b.h or 1)/2)].text
    assert(row:sub(b.x,b.x+b.w-1):find("%S"),"target must be drawn")
    return b
  end end
  local ids={} for _,b in ipairs(frame.buttons) do ids[#ids+1]=b.id end
  error("missing button "..id.." in "..table.concat(ids,","))
end
local function mineFixture()
  local job={homeSet=true,home={x=0,y=64,z=0,facing=0},bottom=60,length=100,mode="fast",
    dim="minecraft:overworld",running=true,continuous=true,branches=8,progress={nextBranch=1},turtles={}}
  local s={job=job,routes=0}
  local env=setmetatable({SO={store={copy=function(v)
    local function copy(t)
      if type(t)~="table" then return t end
      local out={} for k,x in pairs(t) do out[k]=copy(x) end return out
    end
    return copy(v)
  end,store=function() return {value=job,save=function() return true end} end},mods={}}},{__index=_G})
  env.dofile=function(path)
    local lib=dofile(path)
    if path=="so-mine-plan.lua" then
      local route=lib.route
      lib.route=function(...) s.routes=s.routes+1 return route(...) end
    end
    return lib
  end
  s.mine=assert(loadfile("so-mod-mine.lua","t",env))()
  return s
end
return function(test,equal)
  test("broken chest labels and beams have a separate four-point budget",function()
    local s=setup()
    for i=1,10 do s.points[#s.points+1]={id="near"..i,kind="ore",dim=0,x=i,y=64,z=0} end
    for i=1,6 do s.points[#s.points+1]={id="broken"..i,kind="ore",dim=0,x=100+i,y=64,z=0,broken=true} end
    s.points[#s.points+1]={id="nether",kind="ore",dim=-1,x=0,y=64,z=0,broken=true}
    s.ar.tick(1000)
    local beams,labels=0,0
    for id in pairs(s.elements) do
      if id:match(":beam$") then beams=beams+1 end
      if id:match("^drop:broken%d+$") then labels=labels+1 end
    end
    equal(beams,4) equal(labels,4)
    equal(s.elements["drop:broken1:beam"].args,{0xFFFF6B5E-2^32,101.5,65,0.5,101.5,71,0.5})
    assert(s.elements["drop:near8"]) equal(s.elements["drop:near9"],nil)
    equal(s.elements["hud:broken:value"].args[4],"6") equal(s.elements["hud:disk:value"],nil)
    equal(s.elements["hud:broken:backing"].args[3],72)
    s.points={} s.ar.tick(2000)
    equal(s.elements["drop:broken1:beam"],nil) assert(s.elements["hud:disk:value"])
  end)
  test("AR label scale trials preserve the default and expand stack spacing",function()
    local s=setup({arLabelScale=0.6})
    for i=1,2 do s.points[i]={id=tostring(i),kind="ore",dim=0,x=0,y=64,z=0} end
    s.ar.tick(1000)
    local a,b=s.elements["drop:1"].args,s.elements["drop:2"].args
    equal(a[7],0.6) assert(math.abs(a[3]-b[3])>=0.3-0.000001)
    equal(s.elements["hud:turtles:backing"].args[3],72)
  end)
  test("branch preview caches route geometry, excludes shaft and suppresses assigned branches",function()
    local s=mineFixture()
    local v=s.mine.mapView()
    equal(s.routes,1) equal(#v.preview,2)
    equal(v.preview[1],{dim=s.job.dim,x=0,y=60,z=-5,facing=0})
    equal(v.preview[2].x,100) equal(v.preview[2].z,-5)
    v.preview[1].x=999
    equal(s.mine.mapView().preview[1].x,0) equal(s.routes,1)
    s.job.progress.nextBranch=2 s.mine.mapView() equal(s.routes,2)
    s.job.home.facing=1
    v=s.mine.mapView() equal(s.routes,3) equal(v.preview[2].z,100)
    s.job.turtles["2"]={branch=2,pose={x=7,y=60,z=50},state="wait lane"}
    v=s.mine.mapView() equal(v.preview,nil) equal(#v.trails,1)
    equal(v.trails[1].points[2].z,50)
    s.job.turtles["2"].pose.z=999
    equal(s.mine.mapView().trails[1].points[2].z,100)
    s.job.turtles["2"].pose.z=-999
    equal(#s.mine.mapView().trails,0)
    s.job.turtles={} s.job.running=false equal(s.mine.mapView().preview,nil)
    s.job.running=true s.job.progress.nextBranch=8 equal(s.mine.mapView().preview,nil)
    s.job.progress.nextBranch=0 s.job.homeSet=false equal(s.mine.mapView().preview,nil)
    s.job.homeSet=true assert(s.mine.mapView().preview)
  end)
  test("completed trails and unknown map markers never grow real lease rows",function()
    local s=setup()
    s.m.install({"so-mod-lease.lua"})
    s.m.env.SO.now=function() return 1000 end
    local lease=s.m.env.dofile("so-mod-lease.lua")
    s.mods.lease=lease
    lease.status(7)
    local rows
    for i=1,10 do
      local name,value=debug.getupvalue(lease.status,i)
      if name=="S" then rows=value.turtles break end
    end
    assert(rows,"real lease rows must be observable")
    local function count()
      local n=0 for _ in pairs(rows) do n=n+1 end return n
    end
    local before=count()
    equal(lease.peek("unknown"),nil)
    local snapshot=lease.peek(7)
    snapshot.lost=true
    equal(lease.peek(7).lost,false)
    local pose={dim="minecraft:overworld",x=1,y=64,z=0}
    assert(lease.inRange("unknown",pose))
    local machines={screen={role="display",pose=pose},[8]={role="worker",pose=pose,seen=1000}}
    s.mods.state.get=function() return machines end
    local points={{x=0,y=60,z=-5},{x=100,y=60,z=-5}}
    s.mine={dim="minecraft:overworld",preview=points,turtles={ghost={pose=pose,state="mining"}}}
    local peek=lease.peek
    local completedLookups=0
    lease.peek=function(id)
      if tostring(id):match("^done:") then completedLookups=completedLookups+1 end
      return peek(id)
    end
    for i=1,100 do
      s.mine.trails={{id="done:"..i,state="done",points=points},
        {id="ghost",state="mining",points=points}}
      s.ar.tick(i*1000)
      s.map.tick(i*1000)
      equal(count(),before,"display reads created a lease row")
      assert(s.elements["trail:done:"..i])
    end
    s.mine.trails={}
    s.ar.tick(101000)
    equal(s.elements["trail:done:100"],nil)
    equal(completedLookups,0,"completed trails must skip lease reads")
    equal(count(),before)
  end)
  test("AR preview and state trails use bounded lines and follow layer switches",function()
    local s=setup()
    local points={{x=0,y=60,z=-5},{x=100,y=60,z=-5}}
    s.mine={dim="minecraft:overworld",preview=points,trails={
      {id="1",state="mining",points=points},{id="2",state="wait lane",points=points},
      {id="done:0",state="done",points=points}}}
    s.ar.tick(1000)
    equal(s.elements["preview:branch"].args,{0xFF5AB0FF-2^32,0.5,60.5,-4.5,100.5,60.5,-4.5})
    equal(s.elements["trail:1"].args[1],0xFF3DDC84-2^32)
    equal(s.elements["trail:2"].args[1],0xFFFFC24B-2^32)
    equal(s.elements["trail:done:0"].args[1],0x504A5468)
    s.mine.trails[1].state="lost" s.ar.tick(2000)
    equal(s.elements["trail:1"].args[1],0xFFFF6B5E-2^32)
    s.mine.trails[1].state="mining"
    s.mods.lease={peek=function() return {uncertain=true} end}
    s.ar.tick(3000) equal(s.elements["trail:1"].args[1],0xFFFF6B5E-2^32)
    s.mods.lease=nil s.ar.tick(130000)
    equal(s.elements["trail:1"].args[1],0xFF4A5468-2^32)
    s.screens.ar.input({id="turtles"}) s.screens.ar.input({id="leases"}) s.ar.tick(131000)
    equal(s.elements["trail:1"],nil) equal(s.elements["preview:branch"],nil)
  end)
  for _,size in ipairs({{26,20},{29,12}}) do
    test("map focuses broken chests and draws next branch at "..size[1].."x"..size[2],function()
      local s=setup()
      s.points={{id="far",kind="ore",dim=0,x=100,y=64,z=0,broken=true}}
      s.mine={dim="minecraft:overworld",preview={{x=95,y=60,z=2},{x=105,y=60,z=2}}}
      s.map.tick(0)
      local screen,session=s.screens.map,{}
      local frame=screen.render(size[1],size[2],session)
      local b=button(frame,"map-focus")
      screen.input({id=b.id,x=b.x,y=b.y,session=session})
      equal(session.map.x,100) equal(session.map.z,0) equal(session.map.scale,1) equal(session.map.fit,false)
      frame=screen.render(size[1],size[2],session)
      b=button(frame,"map-drop:far")
      local opened
      local count=button(frame,"map-broken")
      screen.input({id=count.id,x=count.x,y=count.y,session=session,open=function(role,actions) opened={role,actions} end})
      equal(opened,{"generic",{"list","focus:far"}})
      opened=nil
      screen.input({id=b.id,x=b.x,y=b.y,session=session,open=function(role,actions) opened={role,actions} end})
      equal(opened,{"generic",{"list","focus:far"}})
      s.points[#s.points+1]={id="healthy",kind="fuel",dim=0,x=101,y=64,z=0}
      s.points[#s.points+1]={id="other",kind="wood",dim=0,x=100,y=64,z=0,broken=true}
      s.map.tick(1000)
      session.map.scale=2
      frame=screen.render(size[1],size[2],session)
      b=button(frame,"map-drop:far")
      equal(frame.rows[b.y].text:sub(b.x,b.x),"O")
      for _,target in ipairs(frame.buttons) do assert(target.id~="map-drop:other","one target per visible cell") end
      local found=false
      for _,row in ipairs(frame.rows) do for _,run in ipairs(row.runs) do if run[3]=="1" then found=true end end end
      assert(found,"preview must be visible in amber")
    end)
  end
  for _,size in ipairs({{26,20},{29,12},{39,19},{51,19},{57,24}}) do
    test("status broken tile opens the selected chest through display input at "..size[1].."x"..size[2],function()
      local s=setup()
      s.m.install({"so-mod-display.lua","so-proto.lua"})
      s.m.env.SO.now=function() return 1000 end
      s.m.env.SO.pair={key=function() return "key" end}
      s.m.env.SO.proto=s.m.env.dofile("so-proto.lua")
      local drops=s.m.env.dofile("so-mod-drops.lua")
      s.mods.drops=drops
      assert(drops.add({id="broken",kind="ore",side="front",dim=0,x=100,y=64,z=0}))
      for _=1,3 do drops.note("broken",nil) end
      local display=s.m.env.dofile("so-mod-display.lua")
      s.mods.display=display
      drops.tick() display.tick(1000)
      display.handlers.hello({from=22,body={w=size[1],h=size[2],fullH=size[2]}})
      local function frame()
        local value
        display.handlers["view.get"]({from=22,body={}},function(_,got) value=got end)
        return value
      end
      if frame().role~="status" then
        local b=button(frame(),"status")
        display.handlers.input({from=22,body={id=b.id,x=b.x,y=b.y}})
      end
      local b=button(frame(),"broken")
      display.handlers.input({from=22,body={id=b.id,x=b.x,y=b.y}})
      equal(frame().role,"generic")
      button(frame(),"select:broken")
    end)
  end
  test("drop focus opens the page containing a distant selected chest",function()
    local s=setup()
    local drops=s.m.env.dofile("so-mod-drops.lua")
    for i=1,20 do assert(drops.add({id="p"..i,kind="ore",side="front",dim=0,x=i,y=64,z=0})) end
    drops.tick()
    local screen,session=s.screens.generic,{id=22}
    screen.input({id="focus:p20",session=session,from=22})
    local frame=screen.render(29,12,session)
    local found=false
    for _,b in ipairs(frame.buttons) do if b.id=="select:p20" then found=true end end
    assert(found,"selected chest must be on the visible page")
    button(frame,"fix")
  end)
end
