local scenario=...
local function write(path,value)
  local f=assert(fs.open(path,"w")) f.write(textutils.serialize(value)) f.close()
end
local function json(path,value)
  local f=assert(fs.open(path,"w")) f.write(textutils.serializeJSON(value)) f.close()
end
assert(periphemu.create("left","modem",1))
local call=peripheral.call
peripheral.call=function(name,method,...)
  if name=="left" and method=="isWireless" then return true end
  return call(name,method,...)
end
gps.locate=function() return 0,65,0 end
http=nil _G.http=nil
local scene={dim="minecraft:overworld",revision=7,stale=false,cells={},sites={
  {name="Iron",kind="source",pose={dim="minecraft:overworld",x=-5,y=65,z=0,h=1},side="front"},
  {name="Drop",kind="drop",pose={dim="minecraft:overworld",x=4,y=65,z=0,h=3},side="front"},
  {name="Charger",kind="charge",pose={dim="minecraft:overworld",x=0,y=65,z=3,h=0},side="front"}
}}
for x=-5,5 do for z=-4,4 do
  scene.cells[#scene.cells+1]={x=x,y=65,z=z,name=false}
end end
scene.cells[#scene.cells+1]={x=-4,y=65,z=-2,name="minecraft:iron_ore"}
local source={scene=function() return scene end,refresh=function() return true end,
  poll=function() return true end,dispatch=function() return false end}
local originalDofile=dofile
dofile=function(path)
  if path=="view-source.lua" then return {new=function() return source end} end
  return originalDofile(path)
end
_G.dofile=dofile
write("views.cfg",{enabled=true,mode=scenario=="hub-pro" and "pro" or "warehouse",
  server=99,secret="test-secret-123456",dim=scene.dim,center={x=0,y=65,z=0},monitor="right"})
local calls={}
local finishMirror
if scenario=="warehouse-normal" then
  assert(periphemu.create("right","monitor"))
  local wrap=peripheral.wrap
  local normal=wrap("right")
  local canvas=term.native()
  local live=true
  normal.setTextScale(0.5)
  local mirrored={}
  for key,value in pairs(normal) do mirrored[key]=value end
  for _,method in ipairs({"clear","clearLine","setCursorPos","write","blit","setTextColor","setBackgroundColor"}) do
    mirrored[method]=function(...)
      local args=table.pack(...)
      if not live then return end
      calls[#calls+1]={method=method,args={...}}
      local ok,err=pcall(normal[method],table.unpack(args,1,args.n)) assert(ok,err)
      return canvas[method](table.unpack(args,1,args.n))
    end
  end
  mirrored.getSize=canvas.getSize
  mirrored.isColor=function() return false end
  mirrored.isColour=mirrored.isColor
  peripheral.wrap=function(name) if name=="right" then return mirrored end return wrap(name) end
  local find,getName=peripheral.find,peripheral.getName
  peripheral.find=function(kind,filter)
    if kind=="monitor" then return mirrored end
    return find(kind,filter)
  end
  peripheral.getName=function(p) if p==mirrored then return "right" end return getName(p) end
  finishMirror=function()
    live=false
    periphemu.remove("right")
    local start=1
    for i,entry in ipairs(calls) do if entry.method=="clear" then start=i end end
    canvas.setBackgroundColor(colors.black)
    canvas.setTextColor(colors.white)
    for i=start,#calls do
      local entry=calls[i]
      canvas[entry.method](table.unpack(entry.args))
    end
    term.redirect(canvas)
  end
end
parallel.waitForAny(function()
  assert(shell.run("hub.lua",scenario=="hub-pro" and "pro" or "warehouse"),"hub exited")
end,function()
  for tick=1,12 do
  sleep(1)
  for id=1,3 do
    os.queueEvent("rednet_message",id,{type="status",label="Miner "..id,dim=scene.dim,x=id-2,y=65,z=id-2,
      phase="home",status=id==2 and "Charging" or "Ready",fuel=id==3 and "unlimited" or 1800,free=16-id*2,
      facing="north",role="north",ore="iron"},"minearmy")
  end
  end
  sleep(2)
  json("capture-"..scenario..".json",{scenario=scenario,renderer="production hub",
    monitorOutputMirror=scenario=="warehouse-normal",warehouseAdapter="PR4 wh-sites fixture",calls=calls})
  if finishMirror then finishMirror() end
  term.screenshot()
  sleep(1)
  os.shutdown()
end)
