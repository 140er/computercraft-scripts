local M = {}
local roles={roomsorter="store",sorter="store",factory="factory",hub="hub",panel="panel",server="server",smartmine="miner"}
local behavior={roomsorter="sorting",sorter="sorting",factory="crafting",smartmine="mining"}
local actions={forward=true,back=true,up=true,down=true,turnLeft=true,turnRight=true,dig=true,digUp=true,digDown=true,
  place=true,placeUp=true,placeDown=true,drop=true,dropUp=true,dropDown=true,suck=true,suckUp=true,suckDown=true,refuel=true,craft=true}
local function pack(...) return {n=select("#",...),...} end
local unpack=table.unpack or unpack
function M.run(path,...)
  if rawget(_ENV,"__wh2Running") then return false end
  local command=...
  if (path=="roomsorter.lua" or path=="sorter.lua") and command=="ssot" then return false end
  local Atomic=dofile("atomic.lua")
  local bootstrap=Atomic.read("wh2.cfg") or {}
  if bootstrap.enabled~=true then return false end
  if type(bootstrap.server)~="number" or type(bootstrap.dimension)~="string" then
    print("Fleet unavailable. Configure wh2.cfg. Standalone mode.") return false
  end
  local ok,rpc=pcall(function() return dofile("ssot-client.lua").new(bootstrap) end)
  if not ok then print("Fleet unavailable. Standalone mode. "..tostring(rpc)) return false end
  peripheral.find("modem",rednet.open)
  local program=path:gsub("%.lua$","")
  local boot=tostring(os.epoch("utc"))..":"..os.getComputerID()
  local pose,state,detail=false,"idle",""
  local client,bindings
  bindings={}
  local configKeys={roomsorter={maxSize="roomMaxSize",maxHeight="roomMaxHeight",maxCells="roomMaxCells",maxFurnaces="roomMaxFurnaces",
    queue="smeltQueue",minFuel="roomFuelLow",extraSmelt="extraSmelt",noSmelt="noSmelt",charcoal="charcoal",keepLogs="keepLogs",fuels="roomFuels",cook="smelting"},
    sorter={queue="smeltQueue",extraSmelt="extraSmelt",noSmelt="noSmelt",leave="leave",fuels="wiredFuels",useStorageFuel="useStorageFuel",cook="smelting"}}
  local function apply(settings)
    for _,binding in ipairs(bindings) do
      for target,source in pairs(configKeys[program] or {}) do binding[target]=settings[source] end
      if program=="roomsorter" then binding.interval=settings.roomIntervalMs/1000
      elseif program=="sorter" then binding.interval=settings.wiredIntervalMs/1000 end
    end
  end
  local function snapshot()
    local fuel,inventory=false,false
    if turtle then
      local used=0 for slot=1,16 do if turtle.getItemCount(slot)>0 then used=used+1 end end
      fuel={level=turtle.getFuelLevel(),limit=turtle.getFuelLimit()}
      inventory={slots=16,usedSlots=used,fullness=used/16}
    end
    return {id="cc:"..os.getComputerID(),computerId=os.getComputerID(),turtleId=turtle and os.getComputerID() or false,
      kind=turtle and "turtle" or "computer",label=os.getComputerLabel() or program,role=roles[program] or "other",
      boot=rpc.boot or boot,ownerGeneration=0,state=state,detail=detail,pose=pose,heading=false,poseConfirmed=false,
      fuel=fuel,inventory=inventory,currentJob=false,lastSeen=0,appliedSettingsRevision=0,
      capabilities={navigation=false,inventory=turtle~=nil,crafting=turtle and type(turtle.craft)=="function" or false},error=false}
  end
  client=dofile("wh2-client.lua").new({rpc=rpc,enabled=true,role=roles[program] or "other",dimension=bootstrap.dimension,snapshot=snapshot,apply=apply})
  function client.bindConfig(value)
    bindings[#bindings+1]=value
    if client.ready() then apply(client.settings()) end
  end
  function client.allowed(key)
    local settings=client.settings()
    return client.ready() and settings.enabled==true and settings[key]==true
  end
  local function waitAllowed()
    local settings=client.settings()
    while not client.ready() or settings.enabled~=true or behavior[program] and settings[behavior[program]]~=true do
      local status=client.status()
      local reason=status.detail or "Fleet behavior is disabled"
      if detail~=reason then print(reason) end
      state,detail="stopped",reason
      os.pullEvent("wh2_settings") settings=client.settings()
    end
    return settings
  end
  local environment=setmetatable({__wh2Running=true,wh2=client},{__index=_ENV})
  environment.peripheral=setmetatable({},{__index=peripheral})
  local transfers={pushItems=true,pullItems=true}
  environment.peripheral.wrap=function(name)
    local device=peripheral.wrap(name)
    if type(device)~="table" then return device end
    local proxy={} for method,fn in pairs(device) do
      if transfers[method] then
        proxy[method]=function(...) waitAllowed() state="sorting" return fn(...) end
      else proxy[method]=fn end
    end
    return proxy
  end
  environment.peripheral.call=function(name,method,...)
    if transfers[method] then waitAllowed() state="sorting" end
    return peripheral.call(name,method,...)
  end
  if turtle then
    environment.turtle=setmetatable({},{__index=turtle})
    for name in pairs(actions) do
      if type(turtle[name])=="function" then
        environment.turtle[name]=function(...)
          local policy=waitAllowed()
          if name=="refuel" and policy.autoCharge~=true then return false,"auto-charge disabled" end
          if name:match("^drop") and program~="roomsorter" and program~="sorter" and policy.autoDropoff~=true then
            return false,"auto-drop-off disabled"
          end
          state=name:match("^dig") and "mining" or name:match("^drop") and "dropping" or name=="craft" and "crafting" or "returning"
          return turtle[name](...)
        end
      end
    end
  end
  local arguments=pack(...)
  local function execute()
    local chunk=assert(loadfile(path,"t",environment))
    return chunk(unpack(arguments,1,arguments.n))
  end
  local function work()
    while true do
      if gps then
        local x,y,z=gps.locate(.2)
        if x then pose={dim=bootstrap.dimension,x=math.floor(x+.5),y=math.floor(y+.5),z=math.floor(z+.5)} else pose=false end
      end
      client.tick()
      os.queueEvent("wh2_settings")
      sleep(1)
    end
  end
  local threads={{co=coroutine.create(execute)},{co=coroutine.create(work)}}
  local function resume(thread,event)
    local result=pack(coroutine.resume(thread.co,unpack(event,1,event.n)))
    if not result[1] then error(result[2],0) end
    thread.filter=result[2]
  end
  for _,thread in ipairs(threads) do resume(thread,{n=0}) end
  while coroutine.status(threads[1].co)~="dead" do
    local event=pack(os.pullEventRaw())
    if event[1]=="rednet_message" then client.dispatch(event[2],event[3],event[4]) end
    for _,thread in ipairs(threads) do
      if coroutine.status(thread.co)~="dead" and (thread.filter==nil or thread.filter==event[1] or event[1]=="terminate") then resume(thread,event) end
    end
  end
  return true
end
return M
