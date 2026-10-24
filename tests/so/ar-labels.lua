local H = dofile("tests/so/harness.lua")
local function boot()
  local n = H.new()
  n.time=0
  local m = n.machine({id=1,capacity=16000000})
  m.install({"so-store.lua","so-mod-state.lua","so-mod-display.lua","so-mod-ar.lua","so-ui.lua"})
  m.files["so-server.cfg"] = H.encode({pos={dim="minecraft:overworld",x=0,y=64,z=0}})
  local e, b = m.env, {points={},status={}}
  e.SO = { now = function() return e.os.epoch("utc") end,store=e.dofile("so-store.lua"),proto={ser=H.encode},mods={}}
  local mods = e.SO.mods
  mods.state = e.dofile("so-mod-state.lua")
  mods.lease = {peek=function(id) return b.status[id] or {} end,status=function(id) return b.status[id] or {} end,inRange=function() return true end}
  mods.drops = {list=function() return b.points end}
  mods.display = e.dofile("so-mod-display.lua")
  local ar = {elements={}}
  for _, method in ipairs({"drawText3D","drawLine3D","drawRect2D","drawText2D"}) do
    ar[method] = function(id,...) ar.elements[id]={...} end
  end
  ar.delete = function(id) ar.elements[id]=nil end
  ar.update = function() end
  e.peripheral.find = function(kind) if kind=="ar_controller" then return ar end end
  b.ar, b.mods, b.n = ar, mods, n
  b.tick = e.dofile("so-mod-ar.lua").tick
  return b
end
local function model(display)
  for i=1,20 do
    local name, value = debug.getupvalue(display.tick,i)
    if name=="D" then return value.model end
  end
  error("missing display model")
end
return function(test,equal)
  test("AR labels are compact and nearby drops and turtles have separate heights",function()
    local b=boot()
    b.points={{id="ore_left",kind="ore",dim=0,x=0,y=64,z=1},{id="fuel_right",kind="fuel",dim=0,x=1,y=64,z=1}}
    b.mods.state.emit("pose",{id=2,dim="minecraft:overworld",x=0,y=64,z=2})
    b.tick(1000)
    local labels={b.ar.elements["drop:ore_left"],b.ar.elements["drop:fuel_right"],b.ar.elements["turtle:2"]}
    equal(labels[1][8],"O");equal(labels[2][8],"F");equal(labels[3][8],"#2")
    for i,a in ipairs(labels) do
      assert(a[7]>0 and a[7]<=0.5,"world label scale exceeds 0.5")
      assert(a[3]>65,"label must sit above its block")
      for j=1,i-1 do
        assert(math.abs(a[3]-labels[j][3])>=0.25,"nearby labels overlap vertically")
      end
    end
    for edge=1,12 do assert(b.ar.elements["drop:ore_left:box:"..edge]) end
    assert(b.ar.elements["turtle:2:heading"])
  end)
  test("AR keeps the nearest drop labels per kind and bounds turtle labels while keeping boxes",function()
    local b=boot()
    for i=20,1,-1 do
      b.points[#b.points+1]={id="ore"..i,kind="ore",dim=0,x=i,y=64,z=1}
      b.mods.state.emit("pose",{id=i,dim="minecraft:overworld",x=i,y=64,z=2})
    end
    b.points[#b.points+1]={id="fuel",kind="fuel",dim=0,x=30,y=64,z=1}
    b.tick(1000)
    local drops,turtles=0,0
    for id,a in pairs(b.ar.elements) do
      if id:match("^drop:[^:]+$") then drops=drops+1;assert(a[7]<=0.5) end
      if id:match("^turtle:%d+$") then turtles=turtles+1;assert(a[7]<=0.5) end
    end
    equal(drops,9);equal(turtles,16)
    assert(b.ar.elements["drop:ore1"]);equal(b.ar.elements["drop:ore9"],nil)
    assert(b.ar.elements["drop:fuel"]);assert(b.ar.elements["turtle:16"])
    equal(b.ar.elements["turtle:17"],nil)
    assert(b.ar.elements["drop:ore20:box:1"]);assert(b.ar.elements["turtle:20:box:1"])
    local first=H.encode(b.ar.elements)
    local reverse={};for i=#b.points,1,-1 do reverse[#reverse+1]=b.points[i] end
    b.points=reverse;b.tick(2000)
    equal(H.encode(b.ar.elements),first)
    b.points={};b.tick(3000);equal(b.ar.elements["drop:ore1"],nil)
  end)
  test("AR turtle total agrees with fleet and status for working and paired idle turtles",function()
    local b=boot()
    for id=2,4 do
      b.mods.state.handlers.hello({from=id,body={role="turtle",fuel=1000}})
      b.mods.state.emit("pose",{id=id,dim="minecraft:overworld",x=id,y=64,z=0})
      b.status[id]={open=(id==4 and "lumber" or "mine")..id,seen=130000}
    end
    b.mods.state.handlers.hello({from=8,body={role="display"}})
    b.n.time=130000;b.mods.display.tick(130000);b.tick(130000)
    equal(model(b.mods.display).tiles[1].value,"3")
    equal(model(b.mods.display).okShort,"3 ok")
    equal(b.ar.elements["hud:turtles:value"][4],model(b.mods.display).tiles[1].value)
    equal(b.ar.elements["hud:turtles:value"][1],0xFFE6EAF2-2^32)
    for id=2,4 do assert(b.ar.elements["turtle:"..id][1]~=0xFF7886A3-2^32,"working turtle marked stale") end
    b.mods.state.handlers.hello({from=5,body={role="worker",fuel=1000}})
    b.mods.display.tick(131000);b.tick(131000)
    equal(model(b.mods.display).tiles[1].value,"4")
    equal(b.ar.elements["hud:turtles:value"][4],"4")
    local count=0
    for _,row in ipairs(b.mods.state.view.get({name="fleet"}).data) do
      if row.role=="turtle" then count=count+1 end
    end
    equal(count,4)
    b.status[2].lost=true
    b.mods.display.tick(132000);b.tick(132000)
    equal(b.ar.elements["hud:turtles:value"][4],model(b.mods.display).tiles[1].value)
    equal(b.ar.elements["hud:turtles:value"][1],0xFFFF6B5E-2^32)
  end)
  test("AR counts two mining leases, one lumber lease and a paired idle worker after real reports",function()
    local F=dofile("tests/so/worker-fixture.lua")
    local a=F.setup(nil,{"so-mod-state.lua","so-log.lua","so-mod-lease.lua","so-ui.lua",
      "so-mod-display.lua","so-mod-ar.lua"})
    local mods=a.s.env.SO.mods
    local workers={[2]=a.t}
    for id=3,5 do
      assert(a.s.env.SO.pair.remember(id,string.rep("a",64)))
      local w=a.n.machine({id=id,modem=true,turtle=true,capacity=1000000})
      for path,data in pairs(a.t.files) do
        if path~="so-journal" and not path:match("^so%-journal%.") then w.files[path]=data end
      end
      w.boot("worker.lua");a.n.flush();workers[id]=w
    end
    local elements={}
    local ar={update=function() end,delete=function(id) elements[id]=nil end}
    for _,method in ipairs({"drawText3D","drawLine3D","drawRect2D","drawText2D"}) do
      ar[method]=function(id,...) elements[id]={...} end
    end
    a.s.env.peripheral.find=function(kind) if kind=="ar_controller" then return ar end end
    a.n.advance(131)
    for id=2,4 do
      local owner=id==4 and "lumber" or "mine"
      local pose={dim="minecraft:overworld",x=id,y=64,z=0,facing=1}
      assert(mods.lease.send(id,{{op="turnRight"}},{owner=owner,pose=pose}))
      a.n.flush();a.n.advance(1)
      assert(mods.lease.status(id).seen>=a.n.time-1000)
    end
    for id=2,4 do
      local owner=id==4 and "lumber" or "mine"
      local pose={dim="minecraft:overworld",x=id,y=64,z=0,facing=1}
      assert(mods.lease.send(id,{{op="inspectDown"}},{owner=owner,pose=pose}))
    end
    mods.display.tick(a.n.time);mods.ar.tick(a.n.time)
    equal(model(mods.display).tiles[1].value,"4")
    equal(elements["hud:turtles:value"][4],"4")
    equal(elements["hud:turtles:value"][1],0xFFE6EAF2-2^32)
    equal(mods.lease.status(5).open,nil)
    for id=2,4 do assert(mods.lease.status(id).open) end
    for _,w in pairs(workers) do assert(w.alive(),tostring(w.error)) end
    F.check(a)
  end)
end
