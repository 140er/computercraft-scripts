local runtime=...
local id=os.getComputerID()
if fs.exists("sandbox-result.json") then
  local h=assert(fs.open("sandbox-result.json","r")) local r=textutils.unserializeJSON(h.readAll()) h.close()
  if r and r.ok then while true do sleep(1) end end
end
local A,F=dofile("atomic.lua"),dofile("warehouse-fixture.lua")
assert(fs.getCapacity("/")==1000000,"warehouse requires a one-megabyte disk")
local client=dofile("ssot-client.lua").new({server=0,secret="test-secret-123456",timeout=3})
local messages,pending,serial,published={}, {},0,{}
local send=rednet.send
local requests,dropped,delayed,duplicate={},false,nil,false
local function fault(name)
  if not fs.exists("fault-"..name) then local h=assert(fs.open("fault-"..name,"w")) h.write("injected") h.close() end
end
rednet.send=function(to,m,proto)
  if runtime=="sandbox" and proto=="fleetserver" and type(m)=="table" and m.type=="ssot" then
    requests[m.rid]=m.op
    if m.op=="wh-progress" then send(to,m,proto) duplicate=true fault("duplicate") end
  end
  return send(to,m,proto)
end
local function json(path,v) local h=assert(fs.open(path,"w")) h.write(textutils.serializeJSON(v)) h.close() end
local function publish(peer,kind,fields)
  local m=fields or {} m.kind=kind published[peer..":"..kind]=m
  send(peer,m,"warehouse_test")
end
local function wait(kind,peer,timeout)
  local untilAt=os.clock()+(timeout or 600)
  local queryAt=0
  repeat
    for i,v in ipairs(messages) do if v.id==peer and v.m.kind==kind then table.remove(messages,i) return v.m end end
    if os.clock()>=queryAt then send(peer,{kind="status",want=kind},"warehouse_test") queryAt=os.clock()+1 end
    sleep(.05)
  until os.clock()>untilAt
  error("warehouse timeout "..kind.." from "..peer)
end
local function world(op,args)
  serial=serial+1 local rid=tostring(os.epoch("utc"))..":"..id..":"..serial
  local untilAt=os.clock()+30
  repeat
    send(5,{op=op,args=args or {},rid=rid},"ssot_world") sleep(.01)
    if pending[rid] then local v=pending[rid] pending[rid]=nil return v end
  until os.clock()>untilAt
  error("world timeout "..op)
end
local function receive()
  while true do
    local from,m,proto=rednet.receive()
    if proto=="fleetserver" then
      if runtime=="sandbox" and requests[m.rid]=="wh-progress" and not dropped then dropped=true fault("drop")
      elseif runtime=="sandbox" and requests[m.rid]=="wh-claim" and delayed==nil then delayed={from,m,proto}
      else
        client.dispatch(from,m,proto)
        if delayed and delayed~=false then client.dispatch(table.unpack(delayed)) delayed=false fault("reorder") end
      end
    elseif proto=="ssot_world_reply" then pending[m.rid]=m.values
    elseif proto=="warehouse_test" then
      if m.kind=="status" then
        local found=published[from..":"..tostring(m.want)]
        if found then send(from,found,"warehouse_test") end
      else messages[#messages+1]={id=from,m=m} end
    end
  end
end
local function request(op,v) local r,why=client.call(op,v) assert(r and r.ok,why or r and r.error or op) return r end
local function controller()
  local disk=A.store("warehouse-controller.state",function(v) return type(v)=="table" end)
  if not disk.value then
    if runtime=="sandbox" then
      dofile("warehouse-unit.lua")
      dofile("mining-unit.lua")
      local mocks=dofile("mocks.lua")
      dofile("nav-checks.lua")(function(name,fn) assert(pcall(fn),name) end,nil,dofile("nav-fixture.lua")(nil,mocks))
      local function read(path) local f=assert(fs.open(path,"r")) local s=f.readAll() f.close() return s end
      dofile("miner-nav-checks.lua")(function(name,fn) local ok,err=pcall(fn) assert(ok,name..": "..tostring(err)) end,read,mocks)
    end
    for name,site in pairs(F.sites) do request("wh-site",{name=name,site=site}) end
    for peer=1,3 do
      local r=wait("ready",peer)
      request("wh-stock",{name="source"..peer,stock=r.stock})
      request("wh-order",{key="order"..peer,drop="drop1",lines={
        {item="minecraft:iron_ingot",count=12,source="source"..peer},
        {item="minecraft:diamond_pickaxe",count=1,source="source"..peer}}})
      publish(peer,"start")
      wait("claimed",peer)
    end
    for peer=1,3 do wait("paused",peer) end
    assert(disk.save({restart=true})) json("restart-ready.json",{ok=true})
    while true do sleep(1) end
  end
  for peer=1,3 do wait("resumed-ready",peer) publish(peer,"resume") end
  for peer=1,3 do wait("serviced",peer) end
  publish(3,"mine") wait("mined",3)
  for peer=1,2 do publish(peer,"traffic-stage") wait("staged",peer) end
  for peer=1,2 do publish(peer,"cross") end
  for peer=1,3 do
    while not fs.exists("peer-"..peer.."-done") do
      publish(peer,"poll")
      local done=false
      for i,v in ipairs(messages) do if v.id==peer and v.m.kind=="done" then table.remove(messages,i) done=true break end end
      if done then local h=fs.open("peer-"..peer.."-done","w") h.close() break end
      sleep(.25)
    end
  end
  send(0,{action="done"},"ssot_test")
  if runtime=="sandbox" then send(5,{op="done",args={},rid="done"},"ssot_world") end
  json("sandbox-result.json",{ok=true,booted=true,errors={},lines={"warehouse, mining continuation, charging and traffic passed"}})
  while true do sleep(1) end
end
local function worker()
  if runtime=="sandbox" then
    turtle=dofile("turtle.lua").new(world) _G.turtle=turtle
    local wrap=peripheral.wrap
    peripheral.wrap=function(side)
      if side=="front" or side=="top" or side=="bottom" then return {list=function() return world("inventory",{side})[1] or {} end} end
      return wrap(side)
    end
  end
  local home=F.pose(id*4-3,0,0)
  local trafficYields=0
  local nc={pose=home,bounds={min=F.pose(0,-4),max=F.pose(12,9)},client=client,traffic=true,
    checkpoint=function(point) if point=="traffic-yielded" then trafficYields=trafficYields+1 json("traffic-yield.json",{ok=true,count=trafficYields}) end end,
    canExcavate=dofile("mining.lua").excavatable,observe=function()
      if runtime=="sandbox" then local p=world("pose") return F.pose(p[1],p[3],p[4]) end
      local x,y,z=gps.locate(2) if x then return {dim=home.dim,x=math.floor(x+.5),y=math.floor(y+.5),z=math.floor(z+.5)} end
    end}
  local nav=dofile("nav.lua").open(nc)
  local ok,why
  for _=1,30 do ok,why=nav.recover() if ok then break end sleep(1) end
  assert(ok,why)
  for _,p in ipairs(F.air) do if not F.blocks[p.x..","..p.y..","..p.z] then nav.record(p,"minecraft:air") end end
  for k,name in pairs(F.blocks) do local x,y,z=k:match("([^,]+),([^,]+),([^,]+)") nav.record({dim=home.dim,x=tonumber(x),y=tonumber(y),z=tonumber(z)},name) end
  local disk=A.store("warehouse-gate.state",function(v) return type(v)=="table" end)
  local g=disk.value or {}
  local function checkpoint(point)
    if not g.paused and point==({[1]="pickup-physical",[2]="deliver-physical",[3]="restore-physical"})[id] then
      g.paused=true assert(disk.save(g))
      json("warehouse-paused.json",{pose=nav.pose(),point=point}) publish(4,"paused")
      while true do sleep(1) end
    end
  end
  local inv=function(side)
    if runtime=="sandbox" then return {list=function() return world("inventory",{side})[1] or {} end} end
    return peripheral.wrap(side)
  end
  local w=dofile("warehouse.lua").open({nav=nav,client=client,home=home,checkpoint=checkpoint,inventory=inv,charger="charge",targetFuel=160,chargeTimeout=60000})
  if not g.paused then
    local stock={}
    for _,v in pairs(assert(inv("front")).list()) do stock[v.name]=(stock[v.name] or 0)+v.count end
    publish(4,"ready",{stock=stock}) wait("start",4)
    request("wh-claim") publish(4,"claimed")
  else publish(4,"resumed-ready") wait("resume",4) end
  local ticks=0
  while w.state().phase~="done" do
    ticks=ticks+1 assert(ticks<200,"warehouse tick bound")
    local ok,why=w.tick()
    if not ok then assert(why=="charging" or why=="bay occupied",why) end
    sleep(.05)
  end
  local order=w.state().job
  local automaticCharges=w.state().serviceCharges or 0
  if id==2 then assert(automaticCharges>=1,"low-fuel order did not continue after charging") end
  assert(order.lines[1].delivered==11 and order.lines[2].delivered==1,"wrong order quantity")
  local before=turtle.getFuelLevel()
  assert(w.charge("charge",math.min(before+60,turtle.getFuelLimit()),runtime=="sandbox" and 30000 or 120000))
  for _=1,1000 do
    local moved,err=w.tick()
    if not moved then assert(err=="bay occupied" or err=="occupied",err) end
    if w.state().phase=="done" then break end
    sleep(.15)
  end
  assert(w.state().reason=="charged","charging did not finish")
  assert(nav.go(home,"walk")) assert(nav.face(home.h))
  publish(4,"serviced")
  local mining=false
  if id==3 then
    wait("mine",4)
    request("mine-config",{zone={min={dim=home.dim,x=8,y=64,z=1},max={dim=home.dim,x=11,y=66,z=2},spacing=4}})
    json("mine-ready.json",{ok=true})
    if runtime=="sandbox" then world("mine-fixture") else while not fs.exists("mine-installed") do sleep(.1) end end
    local mine=dofile("mining.lua").open({nav=nav,client=client,home=home,service={enabled=true,drop="drop3",charger="charge",targetFuel=500,chargeTimeout=30000}})
    assert(mine.start())
    for _=1,200 do assert(mine.tick()) if #mine.state().stack>=2 then break end end
    assert(#mine.state().stack>=2) mine.interrupt("inventory full")
    while mine.state().phase~="home" do mine.tick() sleep(0) end
    assert(mine.service()) assert(mine.start())
    for _=1,500 do local moved,err=mine.tick() if not moved then assert(err=="complete",err) break end sleep(0) end
    assert(mine.state().phase=="home" and mine.state().reason=="complete")
    assert(mine.service()) assert(mine.finish()) mining=true
    publish(4,"mined")
  else
    wait("traffic-stage",4)
    assert(nav.go(F.pose(id==1 and 3 or 7,8),"walk"))
    nc.path="traffic-nav.state" nc.pose=nav.pose() nc.bounds={min=F.pose(0,8),max=F.pose(10,9)}
    nav=dofile("nav.lua").open(nc) assert(nav.recover())
    for _,p in ipairs(F.air) do if p.z>=8 then nav.record(p,"minecraft:air") end end
    publish(4,"staged") wait("cross",4)
    assert(nav.go(F.pose(id==1 and 9 or 1,8),"walk"))
  end
  local inventory={} for slot=1,16 do inventory[slot]=turtle.getItemDetail(slot) or false end
  json("sandbox-result.json",{ok=true,booted=true,errors={},lines={"exact order and durable service passed"},order=order,pose=nav.pose(),
    inventory=inventory,charged=true,restart=g.paused,mining=mining,trafficYields=trafficYields,
    automaticCharges=automaticCharges,dropped=fs.exists("fault-drop"),duplicate=fs.exists("fault-duplicate"),reordered=fs.exists("fault-reorder")})
  while true do sleep(1) end
end
local function replies()
  while true do
    for i=#messages,1,-1 do
      local v=messages[i]
      if v.id==4 and v.m.kind=="poll" and fs.exists("sandbox-result.json") then table.remove(messages,i) publish(4,"done") end
    end
    sleep(.1)
  end
end
local ok,err=pcall(parallel.waitForAny,receive,id==4 and controller or worker,replies)
if not ok then json("sandbox-result.json",{ok=false,errors={tostring(err)}}) error(err,0) end
