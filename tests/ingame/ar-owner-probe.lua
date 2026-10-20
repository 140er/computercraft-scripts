local id=os.getComputerID()
assert(id==0 or id==4,"Owner fixture requires computer 0 or 4")
local role=id==0 and "server" or "hub"
local started=os.epoch("utc")
local function write(path,value)
  local h=assert(fs.open(path,"w"))
  h.write(textutils.serializeJSON(value))
  h.close()
end
local function read(path)
  if not fs.exists(path) then return nil end
  local h=assert(fs.open(path,"r"))
  local value=textutils.unserializeJSON(h.readAll())
  h.close()
  return value
end
local previous=read("ar-owner.json")
local state={ok=true,id=id,role=role,boot=previous and previous.boot+1 or 1,
  started=started,calls={},mutations=0,updates=0,removals=0,errors={},
  journal={},lastMutation=0,lastUpdate=0,programRunning=false}
local function record(event)
  event.time=os.epoch("utc")
  state.journal[#state.journal+1]=event
  if #state.journal>256 then table.remove(state.journal,1) end
end
local nativeFind,nativeWrap=peripheral.find,peripheral.wrap
local wrapped=setmetatable({},{__mode="k"})
local function observe(device)
  if not device or wrapped[device] then return device end
  local name=peripheral.getName(device)
  if not peripheral.hasType(name,"ar_controller") then return device end
  wrapped[device]=true
  for method,fn in pairs(device) do
    if type(fn)=="function" then
      device[method]=function(...)
        local returns=table.pack(pcall(fn,...))
        state.calls[method]=(state.calls[method] or 0)+1
        local mutation=method=="update" or method=="delete" or method:match("^draw") or method:match("^remove")
          or method:match("^clear") or method:match("^set")
        if not returns[1] then
          state.errors[#state.errors+1]={time=os.epoch("utc"),method=method,error=tostring(returns[2])}
          record({kind="error",method=method,error=tostring(returns[2])})
          error(returns[2],0)
        end
        if mutation then
          state.mutations=state.mutations+1
          state.lastMutation=os.epoch("utc")
          if method=="update" then state.updates=state.updates+1 state.lastUpdate=state.lastMutation end
          if method=="delete" or method:match("^remove") or method:match("^clear") then state.removals=state.removals+1 end
          local first=select(1,...)
          record({kind="mutation",method=method,element=type(first)=="string" and first or nil})
        end
        return table.unpack(returns,2,returns.n)
      end
    end
  end
  return device
end
peripheral.wrap=function(name) return observe(nativeWrap(name)) end
peripheral.find=function(...)
  local devices=table.pack(nativeFind(...))
  for i=1,devices.n do devices[i]=observe(devices[i]) end
  return table.unpack(devices,1,devices.n)
end
local function lease(direction,peer,message,protocol)
  if protocol~="fleetserver" or type(message)~="table" then return end
  if message.type=="ack" or message.type=="ar_ready" or message.type=="hub_put" or message.type=="hub_get" then
    record({kind="lease",direction=direction,peer=peer,type=message.type,
      arOwner=message.arOwner,arUntil=message.arUntil,arClient=message.arClient})
  end
end
local nativeSend=rednet.send
rednet.send=function(peer,message,protocol)
  local result=nativeSend(peer,message,protocol)
  lease("sent",peer,message,protocol)
  return result
end
http=nil
_G.http=nil
if not fs.exists("ar.cfg") then
  local cfg=dofile("ar-hud.lua").defaults()
  cfg.enabled=true
  cfg.origin={x=1,y=66,z=0,dim="minecraft:overworld"}
  cfg.anchors={hub={x=1,y=66,z=0,dim="minecraft:overworld"}}
  local h=assert(fs.open("ar.cfg","w"))
  h.write(textutils.serialize(cfg))
  h.close()
end
local function save()
  state.time=os.epoch("utc")
  state.free=fs.getFreeSpace("/")
  local device=nativeFind("ar_controller")
  state.attached=device~=nil
  state.elementCount=0
  state.elementIds={}
  state.elements={}
  state.readError=nil
  if device then
    local ok,elements=pcall(device.getAllElements)
    if ok then
      state.elements=elements
      for name in pairs(elements) do
        state.elementCount=state.elementCount+1
        state.elementIds[#state.elementIds+1]=tostring(name)
      end
      table.sort(state.elementIds)
    else state.readError=tostring(elements) end
  end
  write("ar-owner.json",state)
  write("ar-owner-boot-"..state.boot..".json",state)
end
local function monitor()
  local timer=os.startTimer(1)
  while true do
    local ev,a,b,c=os.pullEvent()
    if ev=="rednet_message" then lease("received",a,b,c)
    elseif ev=="peripheral" or ev=="peripheral_detach" then record({kind=ev,name=a})
    elseif ev=="timer" and a==timer then
      local request=read("ar-owner-request.json")
      if request and request.id~=state.request then
        assert(type(request.id)=="string","Request ID must be a string")
        if request.key then
          assert(type(request.key)=="string" and #request.key==1 and ("ptoav"):find(request.key,1,true),
            "Only real AR layer keys are accepted")
          os.queueEvent("char",request.key)
        end
        state.request=request.id
        record({kind="request",id=request.id,key=request.key})
      end
      save()
      timer=os.startTimer(1)
    end
  end
end
local ok,err=pcall(function()
  assert(fs.getCapacity("/")==4000000,"Wrong computer disk capacity")
  save()
  parallel.waitForAny(function()
    state.programRunning=true
    assert(loadfile(role..".lua","t",_ENV))()
    error("Production program exited")
  end,monitor)
end)
if not ok then
  state.ok=false
  state.programRunning=false
  state.failure=tostring(err)
  pcall(save)
end
