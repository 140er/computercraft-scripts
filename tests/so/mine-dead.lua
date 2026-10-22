local H = dofile("tests/so/harness.lua")
local function setup(saved)
  local net=H.new()
  local server=net.machine({id=1,modem=true})
  server.install({"so-server.lua","so-store.lua","so-mod-state.lua","so-pair.lua","so-proto.lua","so-mod-lease.lua",
    "so-mod-cells.lua","so-mod-display.lua","so-mod-drops.lua","so-mod-mine.lua","so-mine-plan.lua","so-plan.lua"})
  for _,name in ipairs({"x25519","random","blake3","chacha20","config","internal/util","internal/hw",
    "internal/curve25519","internal/fp","internal/edwards25519","internal/packing"}) do
    local path="lib/ccryptolib/"..name..".lua"
    local f=assert(io.open(path)) server.files[path]=f:read("*a") f:close()
  end
  server.files["so-server.cfg"]=H.encode({pos={dim="minecraft:overworld",x=0,y=0,z=0}})
  if saved then server.files["so-data/mine/job"]=H.encode({schema=1,generation=1,value=saved}) end
  server.boot("so-server.lua") net.flush()
  assert(not server.error,tostring(server.error))
  local render,input
  local display=server.env.SO.mods.display
  local original=display.screen
  display.screen=function(role,r,i)
    if role=="mining" then render,input=r,i end
    return original(role,r,i)
  end
  server.env.SO.mods.mine.tick()
  return {net=net,server=server,mods=server.env.SO.mods,
    input=function(text) input({text=text}) end,
    render=function() return render() end,
    job=function() return server.env.SO.store.read("so-data/mine/job").value end}
end
local function addLive(s,id)
  local key=string.rep("b",64)
  assert(s.server.env.SO.pair.remember(id,key))
  local turtle=s.net.machine({id=id,modem=true,turtle=true,fuel=4000,capacity=1000000})
  turtle.install({"worker.lua","so-store.lua","so-pair.lua","so-proto.lua"})
  for path,data in pairs(s.server.files) do
    if path:find("lib/ccryptolib/",1,true)==1 then turtle.files[path]=data end
  end
  turtle.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
  turtle.boot("worker.lua") s.net.flush()
  s.input("add "..id.." 0 0 0 n")
  return turtle
end
local function contains(s,text)
  for _,row in ipairs(s.render().rows) do if row.text:find(text,1,true) then return true end end
  return false
end
return function(test,equal)
  test("mine requires home and clears command errors",function()
    local s=setup()
    local canStart=s.mods.state.canStart
    s.mods.state.canStart=function() return false,"disk >=80%; free space" end
    s.input("start") assert(contains(s,"disk >=80%; free space"))
    s.mods.state.canStart=canStart
    s.input("start") assert(contains(s,"set home before start"))
    s.input("length 4") assert(not contains(s,"set home before start"))
    assert(not s.job().running)
    s.input("home 0 0 0 n") s.input("start") assert(s.job().running)
    s.input("ores diamond, iron") equal(s.job().ores,{"diamond","iron"})
    s.input("ores diamond, unknown") assert(contains(s,"unknown ore"))
    s.input("stop") assert(not contains(s,"unknown ore"))
  end)
  test("mine start fails closed without its disk guard",function()
    local s=setup()
    s.input("home 0 0 0 n")
    for _,state in ipairs({false,{}}) do
      s.mods.state=state or nil
      s.input("start")
      assert(contains(s,"disk guard unavailable"))
      assert(not s.job().running)
    end
  end)
  test("mine removes an unloaded recovery holder and releases reservations",function()
    local pose={dim="minecraft:overworld",x=0,y=-1,z=-1,facing=0}
    local lane={{dim=pose.dim,x=0,y=0,z=-1},{dim=pose.dim,x=0,y=-1,z=-1},
      {dim=pose.dim,x=0,y=-2,z=-1}}
    local s=setup({home={x=0,y=0,z=0,facing=0},dim=pose.dim,bottom=-2,length=3,mode="thorough",ores={},
      progress={nextBranch=0,done=0},running=true,turtles={["2"]={pose=pose,anchor=pose,
      state="lost",lane={cells=lane,entered=true},inv={}}}})
    assert(s.server.env.SO.pair.remember(2,string.rep("a",64)))
    s.mods.mine.tick()
    local lease=s.mods.lease.status(2).open assert(lease)
    assert(s.mods.cells.reserve(lease,2,0,0))
    assert(s.mods.cells.reserveMany("mine:2",lane))
    local turtle=addLive(s,3)
    s.net.advance(5)
    assert(s.job().turtles["3"].state~="done")
    s.input("remove 2")
    equal(s.mods.lease.status(2).open,nil)
    equal(s.job().turtles["2"],nil)
    for _,cell in ipairs(lane) do equal(s.mods.cells.owner(cell.x,cell.y,cell.z),nil) end
    equal(s.mods.cells.owner(2,0,0),nil)
    s.mods.lease.handlers["step.report"]({from=2,body={lease=lease,results={{ok=true}}}})
    equal(s.job().turtles["2"],nil)
    equal(s.mods.lease.status(2).open,nil)
    s.net.advance(80)
    assert(not s.server.error,tostring(s.server.error))
    assert(not turtle.error,tostring(turtle.error))
    equal(s.job().turtles["3"].state,"done")
  end)
  test("mine refuses removal with actual movement or another owner's lease",function()
    local s=setup()
    assert(s.server.env.SO.pair.remember(2,string.rep("a",64)))
    s.input("add 2 0 0 0 n")
    assert(s.mods.lease.cancelPark(2,"mine"))
    local moving=assert(s.mods.lease.send(2,{{op="forward"}},{owner="mine"}))
    s.input("remove 2")
    equal(s.mods.lease.status(2).open,moving) assert(s.job().turtles["2"])
    assert(contains(s,"turtle has open lease"))
    assert(not s.mods.lease.cancelPark(2,"mine"))
    s.mods.lease.handlers["step.report"]({from=2,body={lease=moving,results={{ok=true}}}})
    local other=assert(s.mods.lease.send(2,{{op="inspectDown"}},{owner="other"}))
    s.input("remove 2") equal(s.mods.lease.status(2).open,other)
  end)
  test("mine clears a stale lane waiter during recovery and supports saved home",function()
    local pose={dim="minecraft:overworld",x=99,y=-2,z=-5,facing=0}
    local s=setup({home={x=0,y=0,z=0,facing=0},dim=pose.dim,bottom=-2,length=3,mode="thorough",ores={},
      progress={nextBranch=0,done=0},running=true,turtles={["2"]={pose=pose,anchor=pose,
      state="wait lane",laneWait={at=0,passes=10},inv={}}}})
    s.input("start") assert(s.job().running)
    equal(s.job().turtles["2"].laneWait,nil)
    local turtle=addLive(s,3)
    s.net.advance(80)
    assert(not s.server.error,tostring(s.server.error))
    assert(not turtle.error,tostring(turtle.error))
    equal(s.job().turtles["3"].state,"done")
  end)
end
