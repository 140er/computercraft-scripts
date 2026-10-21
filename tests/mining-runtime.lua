local runtime, _, diskText = ...
local id=os.getComputerID()
dofile("gate-disk.lua")(diskText)
local A=dofile("atomic.lua")
local client=dofile("ssot-client.lua").new({server=0,secret="test-secret-123456",timeout=5})
local messages,pending,serial={}, {},0
local send=rednet.send
local requests,dropped,duplicated={},false,false
rednet.send=function(to,m,proto)
  if runtime=="sandbox" and proto=="fleetserver" and type(m)=="table" and m.type=="ssot" then
    requests[m.rid]=m.op
    if m.op=="mine-lease" then send(to,m,proto) duplicated=true end
  end
  return send(to,m,proto)
end
local boot=tostring(os.epoch("utc"))
local function json(path,v)
  local h=assert(fs.open(path,"w")) h.write(textutils.serializeJSON(v)) h.close()
end
local function wait(kind,peer,timeout)
  local deadline=os.clock()+(timeout or 600)
  repeat
    for i,v in ipairs(messages) do
      if v.m.kind==kind and v.id==peer then table.remove(messages,i) return v.m end
    end
    sleep(.05)
  until os.clock()>deadline
  error("timeout "..kind.." from "..peer)
end
local function world(op,args)
  serial=serial+1 local rid=boot..":"..id..":"..serial
  local deadline=os.clock()+30
  repeat
    send(5,{op=op,args=args or {},rid=rid},"ssot_world")
    sleep(.01)
    if pending[rid] then local v=pending[rid] pending[rid]=nil return v end
  until os.clock()>deadline
  error("world timeout "..op)
end
local function receive()
  while true do
    local from,m,proto=rednet.receive()
    if proto=="fleetserver" then
      if runtime=="sandbox" and not dropped and requests[m.rid]=="mine-progress" then dropped=true
      else client.dispatch(from,m,proto) end
    elseif proto=="ssot_world_reply" then pending[m.rid]=m.values
    elseif proto=="mining_test" then messages[#messages+1]={id=from,m=m} end
  end
end
local function worker()
  if runtime=="sandbox" then turtle=dofile("turtle.lua").new(world) _G.turtle=turtle end
  local x=id*4-3
  local home={dim="minecraft:overworld",x=x,y=65,z=0,h=2}
  local Mine=dofile("mining.lua")
  local nav=dofile("nav.lua").open({pose=home,bounds={min={dim=home.dim,x=-1,y=63,z=-1},max={dim=home.dim,x=12,y=67,z=7}},
    client=client,canExcavate=Mine.excavatable,observe=function()
      if runtime=="sandbox" and not fs.exists("no-gps") then local p=world("pose") return {dim=home.dim,x=p[1],y=p[2],z=p[3]} end
      if gps and gps.locate then
        local a,b,c=gps.locate(2) if a then return {dim=home.dim,x=math.floor(a+.5),y=math.floor(b+.5),z=math.floor(c+.5)} end
      end
    end})
  local ok,why
  for _=1,30 do ok,why=nav.recover() if ok then break end sleep(1) end
  assert(ok,why)
  local gate=A.mount("/"):open("mining-gate.state",function(v) return type(v)=="table" end,{class="bulk",limit=900000})
  local g=gate.value or {}
  local mine=Mine.open({nav=nav,client=client,home=home})
  if not g.restart then
    send(4,{kind="ready"},"mining_test") wait("start",4)
    assert(mine.start())
    send(4,{kind="claimed",task=mine.state().task},"mining_test")
  else assert(mine.start()) end
  local ticks=0
  while mine.state().phase~="done" do
    ticks=ticks+1 assert(ticks<1500,"mining tick bound")
    local s=mine.state()
    if id==3 and not g.inventory and #s.stack>=2 then
      if runtime=="sandbox" then world("inventory-full")
      else
        local empty={}
        for slot=1,16 do if turtle.getItemCount(slot)==0 then empty[#empty+1]=slot end end
        json("inventory-ready.json",{pose=nav.pose(),empty=empty})
        while not fs.exists("inventory-filled") do sleep(.1) end
      end
      g.inventory=true assert(gate:save(g))
    end
    if not g.restart and #s.stack>=2 and (id~=2 or g.fuel) and (id~=3 or g.inventoryServiced) then
      g.restart=true assert(gate:save(g))
      json("mining-paused.json",{pose=nav.pose(),state=s})
      send(4,{kind="paused"},"mining_test")
      while true do sleep(1) end
    end
    if s.phase=="home" and s.reason=="complete" then assert(mine.finish()) break end
    local moved,err=mine.tick()
    if not moved then
      local state=mine.state()
      if state.phase=="home" and state.reason=="low fuel" and id==2 and not g.fuel then
        json("fuel-ready.json",{pose=nav.pose(),fuel=turtle.getFuelLevel()})
        if runtime=="sandbox" then world("fuel-refill")
        else
          while not fs.exists("fuel-filled") do sleep(.1) end
          turtle.select(16) assert(turtle.refuel(1)) turtle.select(1)
        end
        g.fuel=true assert(gate:save(g)) assert(mine.start())
      elseif state.phase=="home" and state.reason=="inventory full" and id==3 and not g.inventoryServiced then
        local slots=0 for i=1,16 do if turtle.getItemCount(i)>0 then slots=slots+1 end end
        assert(slots>=15,"inventory did not fill")
        json("inventory-returned.json",{pose=nav.pose(),slots=slots})
        if runtime=="sandbox" then world("inventory-clear")
        else while not fs.exists("inventory-cleared") do sleep(.1) end end
        g.inventoryServiced=true assert(gate:save(g)) assert(mine.start())
      elseif state.phase=="home" and state.reason=="complete" then assert(mine.finish()) break
      else error(err) end
    end
    sleep(0)
  end
  local p=nav.pose() assert(p.x==home.x and p.y==home.y and p.z==home.z and p.h==home.h)
  local inventory={}
  for slot=1,16 do inventory[slot]=turtle.getItemDetail(slot) or false end
  local result={ok=true,booted=true,errors={},lines={"mining and exact home recovery passed"},pose=p,
    ticks=ticks,fuelInterrupt=g.fuel or false,inventoryInterrupt=g.inventoryServiced or false,state=mine.state(),inventory=inventory}
  json("sandbox-result.json",result)
  while true do
    local from,m,proto=rednet.receive("unused")
  end
end
local function controller()
  local phase=A.mount("/"):open("mining-controller.state",function(v) return type(v)=="table" end,{class="bulk",limit=900000})
  if not phase.value then
    if runtime=="sandbox" then
      dofile("mining-unit.lua")
    end
    local dim="minecraft:overworld"
    local r,why=client.call("mine-config",{zone={min={dim=dim,x=0,y=64,z=1},max={dim=dim,x=11,y=66,z=6},spacing=4}})
    assert(r and r.ok,why)
    for peer=1,3 do
      wait("ready",peer)
      send(peer,{kind="start"},"mining_test")
      local claim=wait("claimed",peer)
      assert(claim.task.entry.x==peer*4-3)
    end
    for peer=1,3 do wait("paused",peer) end
    assert(phase:save({restart=true}))
    json("restart-ready.json",{ok=true})
    while true do sleep(1) end
  end
  for peer=1,3 do
    while not fs.exists("peer-"..peer.."-done") do
      send(peer,{kind="poll"},"mining_test")
      local found=false
      for i,v in ipairs(messages) do
        if v.id==peer and v.m.kind=="done" then table.remove(messages,i) found=true break end
      end
      if found then local f=fs.open("peer-"..peer.."-done","w") f.close() break end
      sleep(.25)
    end
  end
  send(0,{action="done"},"ssot_test")
  if runtime=="sandbox" then send(5,{op="done",args={},rid="done"},"ssot_world") end
  json("sandbox-result.json",{ok=true,booted=true,errors={},lines={"three leases and restart passed"}})
  while true do sleep(1) end
end
local function replies()
  while true do
    for i=#messages,1,-1 do
      local v=messages[i]
      if v.id==4 and v.m.kind=="poll" and fs.exists("sandbox-result.json") then
        table.remove(messages,i) send(4,{kind="done"},"mining_test")
      end
    end
    sleep(.1)
  end
end
local ok,err=pcall(parallel.waitForAny,receive,id==4 and controller or worker,replies)
if not ok then json("sandbox-result.json",{ok=false,errors={tostring(err)}}) error(err,0) end
