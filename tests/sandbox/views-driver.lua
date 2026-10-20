local id=os.getComputerID()
assert(config.get("standardsMode") and fs.getCapacity("/")==4000000)
local networkFile=assert(fs.open("views-network","r"))
local network=assert(tonumber(networkFile.readAll())) networkFile.close()
if not peripheral.isPresent("left") then assert(periphemu.create("left","modem",network)) end
local call=peripheral.call
peripheral.call=function(name,method,...)
  if name=="left" and method=="isWireless" then return true end
  return call(name,method,...)
end
rednet.open("left")
settings.set("fleet.mesh",false)
http=nil _G.http=nil
if id==0 then
  for peer=1,6 do
    assert(periphemu.create(tostring(peer),"computer"))
    assert(rednet.receive("views_boot",30)==peer,"views computer failed to boot")
  end
  parallel.waitForAny(function() assert(loadfile("views-runtime.lua","t",_ENV))("sandbox") end,function()
    sleep(5)
    for peer=1,6 do rednet.send(peer,true,"views_start") end
    while true do sleep(1) end
  end)
elseif id==5 then
  rednet.send(0,true,"views_boot")
  local world=dofile("turtle.lua").world(nil,"views")
  local responses={}
  local done=false
  local function report()
    local s=world.state()
    local f=assert(fs.open("sandbox-result.json","w"))
    f.write(textutils.serializeJSON({ok=s.collisions==0,booted=true,errors={},lines={"three turtle shared physical world"},moves=#s.timeline})) f.close()
    f=assert(fs.open("world.json","w")) f.write(textutils.serializeJSON(s)) f.close()
  end
  while true do
    local from,m,proto=rednet.receive()
    if proto=="ssot_world" then
      if m.op=="done" then
        done=true report()
      else
        local key=from..":"..m.rid
        responses[key]=responses[key] or world.handle(from,m.op,m.args)
        rednet.send(from,{rid=m.rid,values=responses[key]},"ssot_world_reply")
        if done and m.op~="pose" then report() end
      end
    end
  end
else
  rednet.send(0,true,"views_boot")
  assert(rednet.receive("views_start",120)==0,"views server did not start")
end
assert(loadfile("views-runtime.lua","t",_ENV))("sandbox")
