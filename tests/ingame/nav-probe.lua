peripheral.find("modem",rednet.open)
local client=dofile("ssot-client.lua").new({server=0,secret="test-secret-123456",timeout=5})
local id=os.getComputerID()
local A=dofile("atomic.lua")
assert(id==3)
local function json(path,value)
  local h=assert(fs.open(path,"w")) h.write(textutils.serializeJSON(value)) h.close()
end
local function signal(name)
  json(name .. ".json",{ok=true})
  while not fs.exists(name .. ".continue") do sleep(.1) end
end
local function receive()
  while true do
    local _,sender,m,protocol=os.pullEvent("rednet_message")
    client.dispatch(sender,m,protocol)
  end
end
local function worker()
  local dim="minecraft:overworld"
  local h=assert(fs.open("sandbox-result.json","r"))
  local result=textutils.unserializeJSON(h.readAll()) h.close()
  local mode=assert(fs.open("nav-probe","r")) local phase=mode.readAll() mode.close()
  local progress=A.store("nav-probe-progress",function(v) return type(v)=="table" and type(v.result)=="table" end,200000)
  if phase=="resume" then result=assert(progress.value,"missing probe checkpoint").result end
  local nav,last
  local function observed()
    local x,y,z=gps.locate(2)
    if x then return {dim=dim,x=math.floor(x+.5),y=math.floor(y+.5),z=math.floor(z+.5)} end
  end
  nav=dofile("nav.lua").open({pose={dim=dim,x=2,y=66,z=0,h=1},path="nav.state",client=client,
    canExcavate=function(info) return info.name=="minecraft:gravel" end,
    bounds={min={dim=dim,x=-64,y=64,z=-64},max={dim=dim,x=64,y=69,z=64}},observe=observed,
    checkpoint=function(point)
      if point=="move-observed" then
        local p=nav.pose()
        if not last or p.x~=last.x or p.y~=last.y or p.z~=last.z then
          result.timeline[#result.timeline+1]={x=p.x,y=p.y,z=p.z,at=os.epoch("utc"),method="environment"}
          last=p
        end
      end
    end})
  if phase=="gps" then
    assert(not nav.recover(),"GPS loss must stop recovery")
    signal("nav-gps-failed")
    assert(nav.recover(),"real GPS did not recover")
    json("nav-gps-restored.json",{ok=true})
  elseif phase=="relocate" then
    assert(not nav.recover(),"relocated turtle silently accepted its old pose")
    assert(nav.calibrate(1))
    last=nav.pose()
    result.timeline[#result.timeline+1]={x=last.x,y=last.y,z=last.z,at=os.epoch("utc"),method="physical relocation"}
    assert(nav.go({dim=dim,x=2,y=66,z=0},"explore"))
    assert(nav.go({dim=dim,x=4,y=66,z=1},"explore"))
    signal("nav-gravel")
    local moved,reason=nav.step(4,"excavate")
    assert(moved or reason=="falling block" or reason=="Movement obstructed",tostring(reason))
    if moved then assert(nav.step(5,"walk")) end
    local actual=assert(observed())
    assert(actual.x==4 and actual.y==66 and actual.z==1)
    json("nav-gravel-result.json",{ok=true,moved=moved,reason=reason or "moved"})
    signal("nav-gravel-clear")
    assert(nav.go({dim=dim,x=4,y=66,z=4},"explore"))
    for x=5,31 do assert(nav.go({dim=dim,x=x,y=66,z=4},"explore")) end
    last=nav.pose()
    assert(progress.save({result=result}))
    turtle.select(1) assert(turtle.equipRight())
    peripheral.find("modem",rednet.open)
    signal("nav-loader-disabled")
    local ok,why=nav.step(1,"explore")
    assert(not ok and tostring(why):lower():find("loaded",1,true),tostring(why))
    assert(nav.pose().x==31)
    json("nav-disabled-refusal.json",{ok=true,reason=why})
    while true do os.pullEvent() end
  elseif phase=="resume" then
    assert(nav.recover())
    last=nav.pose() assert(last.x==31 and last.y==66 and last.z==4)
    turtle.select(1)
    local item=assert(turtle.getItemDetail(1))
    assert(item.name=="computercraft:wireless_modem_advanced")
    assert(turtle.equipRight()) peripheral.find("modem",rednet.open)
    signal("nav-loader-enabled")
    local ok,why=nav.step(1,"explore")
    json("nav-loader-result.json",{ok=true,enabledMoved=ok,reason=why or "moved",pose=nav.pose()})
    signal("nav-boundary-load")
    if not ok then assert(nav.step(1,"explore")) end
    assert(nav.go({dim=dim,x=2,y=66,z=0},"walk"))
    local p=assert(observed()) local q=nav.pose()
    assert(p.x==q.x and p.y==q.y and p.z==q.z)
    result.pose=q json("sandbox-result.json",result)
    json("nav-environment-result.json",{ok=true,gpsFailure=true,relocation=true,chunkBoundary=true,pose=q})
  else error("unknown probe") end
  while true do os.pullEvent() end
end
local ok,err=pcall(parallel.waitForAny,receive,worker)
if not ok then json("nav-environment-failure.json",{ok=false,error=tostring(err)}) error(err,0) end
