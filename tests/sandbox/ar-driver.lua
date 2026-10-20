local id=os.getComputerID()
assert(config.get("standardsMode") and fs.getCapacity("/")==4000000)
if not peripheral.isPresent("left") then assert(periphemu.create("left","modem",1)) end
local call=peripheral.call
peripheral.call=function(name,method,...)
  if name=="left" and method=="isWireless" then return true end
  return call(name,method,...)
end
rednet.open("left")
http=nil
_G.http=nil
gps.locate=function() return id*2,64,0 end
local function json(path,value)
  local h=assert(fs.open(path,"w")) h.write(textutils.serializeJSON(value)) h.close()
end
local function report(lines)
  json("sandbox-result.json",{ok=true,booted=true,errors={},lines=lines,free=fs.getFreeSpace("/")})
end
if id==0 then
  for peer=1,5 do
    assert(periphemu.create(tostring(peer),"computer"))
    local from=rednet.receive("ar_boot",30)
    assert(from==peer,"computer failed to boot: "..peer)
  end
else rednet.send(0,true,"ar_boot") end
if id==0 or id==5 then
  local m=dofile("tests/ar-fixture.lua").install(false)
  local H=dofile("ar-hud.lua")
  local cfg=H.defaults()
  cfg.enabled=true cfg.origin={x=0,y=64,z=0,dim="minecraft:overworld"}
  cfg.ownerName,cfg.ownerUUID="GateBOperator","00000000-0000-4000-8000-000000000001"
  local auth={controllers={["5"]="pr6-sandbox-controller-5"},chatNames={cfg.ownerName},
    chatUUIDs={[cfg.ownerName]=cfg.ownerUUID},arControllers={["5"]={name=cfg.ownerName,uuid=cfg.ownerUUID}}}
  local authFile=assert(fs.open("ssot.cfg","w"))
  authFile.write(textutils.serialize(auth)) authFile.close()
  local h=assert(fs.open("ar.cfg","w")) h.write(textutils.serialize(cfg)) h.close()
  parallel.waitForAny(function()
    assert(loadfile(id==0 and "server.lua" or "hub.lua","t",_ENV))()
    error("production program exited")
  end,function()
    while true do
      local from,msg=rednet.receive("ar_test")
      if from==4 and type(msg)=="table" then
        if msg.op=="detach" then m.attached=false os.queueEvent("peripheral_detach","emulated_ar") end
        if msg.op=="attach" then m.attached=true os.queueEvent("peripheral","emulated_ar") end
        if msg.op=="done" then
          json("ar-calls.json",m.arCalls)
          report({"production "..(id==0 and "server" or "hub").." owner path","strict cc_ar signatures"})
        end
        local ids={}
        for key in pairs(m.elements) do ids[#ids+1]=key end
        rednet.send(4,{rid=msg.rid,frames=#m.frames,calls=#m.arCalls,ids=ids,rejected=m.rejected,attached=m.attached},"ar_reply")
      end
    end
  end)
elseif id<=3 then
  local T=dofile("turtle.lua")
  local world=T.world()
  turtle=T.new(function(op,args) return world.handle(id,op,args) end)
  assert(type(turtle.getFuelLevel())=="number")
  assert(turtle.up())
  local pose=world.handle(id,"pose",{})
  report({"turtle emulator moved and reported real native-modem telemetry"})
  while true do
    rednet.broadcast({type="status",label="AR miner "..id,x=pose[1],y=pose[2],z=pose[3],
      dim="minecraft:overworld",fuel=turtle.getFuelLevel(),fuelLimit=turtle.getFuelLimit(),
      status="Mining",facing="north"},"minearmy")
    sleep(1)
  end
else
  assert(loadfile("tests/ar-runtime.lua","t",_ENV))()
  while true do sleep(1) end
end
