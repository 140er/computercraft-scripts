local H = {}
local SSOT = dofile("ssot.lua")
local PREFIX = "ssot-ar:"
local C = { bg=0xDD11161D, border=0xFF30363D, cyan=0xFF58A6FF, green=0xFF2EA043,
  gold=0xFFD29922, red=0xFFF85149, purple=0xFFA371F7, white=0xFFE6EDF3, muted=0xFF8B949E }
local layers = { P="proHud", T="xrayTurtles", O="xrayOres", A="xrayTunnels" }
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function position(p)
  return type(p)=="table" and finite(p.x) and finite(p.y) and finite(p.z) and type(p.dim)=="string"
end
local function limit(n,default,max)
  return finite(n) and math.max(1,math.min(max,math.floor(n))) or default
end
local function nearby(p,cfg)
  local o=cfg.origin
  return position(p) and position(o) and p.dim==cfg.dimension and o.dim==cfg.dimension
    and (p.x-o.x)^2+(p.y-o.y)^2+(p.z-o.z)^2<=limit(cfg.radius,64,256)^2
end
local function coords(p)
  return type(p)=="table" and finite(p.x) and finite(p.y) and finite(p.z) and p.conf~="lost" and p or nil
end
local function configuredDim(explicit, cfg)
  if type(explicit)=="string" and explicit~="" then return explicit end
  if type(cfg)=="table" and type(cfg.dimension)=="string" and cfg.dimension~="" then return cfg.dimension end
end
local function point(p)
  return type(p)=="table" and finite(p.x) and finite(p.y) and finite(p.z) and p.conf~="lost" and p or nil
end
function H.hubPoint(cfg)
  if type(cfg)~="table" then return nil end
  local hub=point(cfg.hub) or point(cfg.origin)
  if not hub then return nil end
  local dim=configuredDim(type(hub.dim)=="string" and hub.dim or nil, cfg)
  if not dim then return nil end
  return { x=hub.x, y=hub.y, z=hub.z, dim=dim }
end
local function addRel(home, rel)
  local x,y,z=home.x,home.y,home.z
  if type(rel)=="table" then
    if finite(rel.x) then x=x+rel.x end
    if finite(rel.y) then y=y+rel.y end
    if finite(rel.z) then z=z+rel.z end
  end
  return { x=x, y=y, z=z }
end
local function hubSpread(id, hub)
  local n=math.abs(math.floor(tonumber(id) or 0))%16
  local col,row=n%4,math.floor(n/4)
  return {
    x=hub.x+(col-1.5)*0.75, y=hub.y, z=hub.z+(row-1.5)*0.75,
    dim=hub.dim, style="unknown", src="hub",
  }
end
-- A fix is a known x y z, or a dead-reckoned pose that is not lost.
-- A missing dimension uses the configured one. With no fix, the marker uses
-- the last world point, then a home or shaft plus its offset, then the hub.
function H.place(t, cfg, extra)
  if type(t)~="table" then return nil end
  extra=type(extra)=="table" and extra or {}
  local at, dim, src = coords(t), type(t.dim)=="string" and t.dim or nil, "fix"
  if not at and type(t.pose)=="table" then at, dim, src = coords(t.pose), t.pose.dim, "pose" end
  if not at and type(t.gps)=="table" then at, dim, src = coords(t.gps), t.gps.dim or t.dim, "gps" end
  if not at and type(t.pos)=="table" and (t.pos.dim or t.pos.conf or t.pos.src or t.pos.v) then
    at, dim, src = coords(t.pos), t.pos.dim or t.dim, "pos"
  end
  if at then
    dim=configuredDim(dim, cfg)
    if not dim then return nil end
    return { x=at.x, y=at.y, z=at.z, dim=dim, conf=at.conf, src=at.src or src, style="fix" }
  end
  local remembered=type(extra.last)=="table" and extra.last[tostring(t.id)] or nil
  local last=point(remembered) or point(t.last) or point(t.lastKnown)
  if last then
    dim=configuredDim(type(last.dim)=="string" and last.dim or nil, cfg)
    if dim then return { x=last.x, y=last.y, z=last.z, dim=dim, conf=last.conf, src="last", style="approx" } end
  end
  local home=point(t.home) or point(t.shaft)
  if home then
    at=addRel(home, t.rel or t.offset)
    dim=configuredDim(type(home.dim)=="string" and home.dim or (type(t.dim)=="string" and t.dim or nil), cfg)
    if dim then return { x=at.x, y=at.y, z=at.z, dim=dim, src="home", style="approx" } end
  end
  local hub=point(extra.hub) and extra.hub or H.hubPoint(cfg)
  if hub and type(hub.dim)=="string" then return hubSpread(t.id, hub) end
end
function H.ensureOrigin(cfg, spot)
  if type(cfg)~="table" or cfg.enabled==false or position(cfg.origin) then return false end
  local at
  if type(spot)=="table" then
    at = coords(spot)
      or (type(spot.pos)=="table" and coords(spot.pos))
      or (type(spot.origin)=="table" and coords(spot.origin))
  end
  if not at then return false end
  local dim = configuredDim(type(at.dim)=="string" and at.dim or (type(spot.dim)=="string" and spot.dim or nil), cfg)
  if not dim then return false end
  cfg.dimension = dim
  cfg.origin = { dim=dim, x=at.x, y=at.y, z=at.z }
  return true
end
local authorized
local keyNames = { p="P", t="T", o="O", a="A" }
function H.layerKey(ev, key, shifted)
  if ev=="char" and layers[key] then return key end
  if ev=="key" and shifted==true and type(key)=="string" then return keyNames[key:lower()] end
end
local layerOrder={"P","T","O","A"}
function H.nextLayer(cfg, authCfg, previous)
  if type(cfg)~="table" or cfg.enabled~=true then return nil end
  local start=1
  if type(previous)=="string" then
    for i,letter in ipairs(layerOrder) do
      if letter==previous then start=i%#layerOrder+1 break end
    end
  end
  for step=0,#layerOrder-1 do
    local letter=layerOrder[(start-1+step)%#layerOrder+1]
    local layer=layers[letter]
    if layer=="proHud" or authorized(cfg, authCfg) then return letter end
  end
end
function H.gesture(ev, name, ownerName)
  if ev=="playerClick" and type(name)=="string" and type(ownerName)=="string"
    and name~="" and name==ownerName then return "cycle" end
end
local redstoneSides={"bottom","top","back","front","right","left"}
local function sideOn(read, side)
  if type(read)~="function" then return false end
  local ok,on=pcall(read, side)
  return ok and on==true
end
function H.redstoneSample(read)
  local now={}
  for _,side in ipairs(redstoneSides) do now[side]=sideOn(read, side) end
  return now
end
function H.redstoneRise(previous, read)
  local now,roseSide={},nil
  previous=type(previous)=="table" and previous or {}
  for _,side in ipairs(redstoneSides) do
    now[side]=sideOn(read, side)
    if now[side] and not previous[side] then roseSide=roseSide and "many" or side end
  end
  return roseSide~=nil and roseSide~="many", now
end
function H.side(side)
  if type(redstone)~="table" or type(redstone.getInput)~="function" then return false end
  local ok,on=pcall(redstone.getInput, side)
  return ok and on==true
end
function H.gestureState()
  return { level=H.redstoneSample(H.side), cursor=nil }
end
function H.feed(state, ev, arg, cfg, authCfg, apply)
  if type(state)~="table" or type(cfg)~="table" or type(apply)~="function" then return false end
  local hit=false
  if ev=="playerClick" then hit=H.gesture(ev, arg, cfg.ownerName)=="cycle"
  elseif ev=="redstone" then
    local rose,now=H.redstoneRise(state.level, H.side)
    state.level=now
    hit=rose and true or false
  else return false end
  if not hit then return false end
  local letter=H.nextLayer(cfg, authCfg, state.cursor)
  if letter and apply(letter) then state.cursor=letter return true end
  return false
end
function H.lights(cfg)
  if type(cfg)~="table" or cfg.enabled~=true then return nil end
  return { P=cfg.proHud~=false, T=cfg.xrayTurtles~=false, O=cfg.xrayOres~=false, A=cfg.xrayTunnels~=false }
end
function H.hubFrom(pos, dim)
  if not point(pos) then return nil end
  return { x=pos.x, y=pos.y, z=pos.z, dim=dim }
end
function H.inputMode(wizard, mode, serverOwned)
  local quiet=wizard and true or false
  return {
    keys=not quiet,
    touch=not quiet and (mode==nil or mode=="classic" or mode=="pro"),
    server=serverOwned and true or false,
  }
end
function H.hints(cfg, authCfg, input)
  if type(cfg)~="table" or cfg.enabled~=true then return nil end
  input = type(input)=="table" and input or {}
  if input.keys~=true and input.touch~=true then return nil end
  local function works(layer)
    if input.server==true then return authorized(cfg, authCfg) end
    if layer~="proHud" and not authorized(cfg, authCfg) then return false end
    return true
  end
  local names = {
    { key="P", layer="proHud", word="HUD" },
    { key="T", layer="xrayTurtles", word="turtles" },
    { key="O", layer="xrayOres", word="ore" },
    { key="A", layer="xrayTunnels", word="air" },
  }
  local parts = {}
  for _, item in ipairs(names) do
    if works(item.layer) then
      parts[#parts+1] = input.keys==true and ("Shift+"..item.key.." "..item.word) or ("Tap "..item.word)
    end
  end
  if #parts==0 then return nil end
  local line = table.concat(parts, " | ")
  if #line>64 then
    parts = {}
    for _, item in ipairs(names) do
      if works(item.layer) then parts[#parts+1] = input.keys==true and ("Shift+"..item.key) or item.word end
    end
    line = table.concat(parts, " ")
  end
  return #line<=64 and line or line:sub(1, 64)
end
local function context(turtles,cfg)
  if not cfg.followTarget then return cfg end
  local out={}
  for k,v in pairs(cfg) do out[k]=v end
  out.origin=nil
  for _,t in ipairs(turtles or {}) do
    local placed = H.place(t, cfg)
    if tostring(t.id)==tostring(cfg.followTarget) and not t.stale and placed and placed.style=="fix" then
      out.origin={x=placed.x,y=placed.y,z=placed.z,dim=placed.dim}
      out.dimension=placed.dim
      break
    end
  end
  return out
end
local function cellID(cell) return cell.dim..":"..cell.x..":"..cell.y..":"..cell.z end
local function isOre(name)
  return type(name)=="string" and (name:find("_ore",1,true) or name:find("ancient_debris",1,true))
end
authorized = function(cfg,authCfg)
  return SSOT.chatAllowed(authCfg or {},cfg.ownerName,cfg.ownerUUID)
end
local function yieldWork()
  local thread,main=coroutine.running()
  if thread and not main and os.queueEvent and os.pullEvent then
    os.queueEvent("ssot_ar_yield")
    os.pullEvent("ssot_ar_yield")
  elseif type(sleep)=="function" then sleep(0) end
end
function H.defaults()
  return {enabled=true,proHud=true,xrayTurtles=true,xrayOres=true,xrayTunnels=false,
    dimension="minecraft:overworld",radius=64,maxTurtles=32,maxCells=128,anchors={}}
end
local function uuidOk(value)
  return type(value)=="string" and value:lower():match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
end
function H.identity(name, uuid)
  if type(name)~="string" or #name<1 or #name>16 or not name:match("^[%w_]+$") then return nil end
  if not uuidOk(uuid) then return nil end
  return name, uuid:lower()
end
function H.adopt(cfg, auth, name, uuid)
  if type(cfg)~="table" or cfg.enabled==false or type(auth)~="table" then return false end
  name, uuid = H.identity(name, uuid)
  if not name then return false end
  if type(cfg.ownerName)=="string" and cfg.ownerName~="" and type(cfg.ownerUUID)=="string" and cfg.ownerUUID~="" then
    return false
  end
  auth.controllers = type(auth.controllers)=="table" and auth.controllers or {}
  auth.chatNames = type(auth.chatNames)=="table" and auth.chatNames or {}
  auth.chatUUIDs = type(auth.chatUUIDs)=="table" and auth.chatUUIDs or {}
  local existing = auth.chatUUIDs[name]
  if type(existing)=="string" and existing:lower()~=uuid then return false end
  local seen = false
  for _, allowed in ipairs(auth.chatNames) do if allowed==name then seen=true break end end
  if not seen and #auth.chatNames>=32 then return false end
  cfg.ownerName, cfg.ownerUUID = name, uuid
  if not seen then auth.chatNames[#auth.chatNames+1] = name end
  auth.chatUUIDs[name] = uuid
  return true
end
function H.player(detector)
  if type(detector)~="table" or type(detector.getPlayers)~="function" then return nil end
  local ok, list = pcall(detector.getPlayers, detector)
  if not ok or type(list)~="table" then return nil end
  local first = list[1]
  if type(first)~="string" and type(first)~="table" then
    for _, item in pairs(list) do
      if type(item)=="string" or type(item)=="table" then first=item break end
    end
  end
  local name, id
  if type(first)=="table" then name, id = first.name or first.username, first.uuid or first.UUID
  elseif type(first)=="string" then name = first end
  if type(name)=="string" and type(id)~="string" and type(detector.getPlayer)=="function" then
    local fine, info = pcall(detector.getPlayer, detector, name)
    if fine and type(info)=="table" then id = info.uuid or info.UUID end
  end
  return H.identity(name, id)
end
function H.claim(cfg, auth, computerId, detector)
  if type(cfg)~="table" or cfg.enabled==false then return false end
  if type(cfg.ownerName)=="string" and cfg.ownerName~="" and type(cfg.ownerUUID)=="string" and cfg.ownerUUID~="" then
    return false
  end
  local enrolled = type(auth)=="table" and type(auth.arControllers)=="table" and auth.arControllers[tostring(computerId or "")]
  if type(enrolled)=="table" and H.adopt(cfg, auth, enrolled.name, enrolled.uuid) then return true end
  local name, id = H.player(detector)
  if not name then return false end
  return H.adopt(cfg, auth, name, id)
end
function H.settings()
  local cfg=H.defaults()
  local source,exists
  for _,path in ipairs({"ar.cfg","ar.cfg.bak","ar.cfg.tmp"}) do
    if fs.exists(path) then
      exists=true
      local f=fs.open(path,"r")
      local ok,t=pcall(function() local s=f.readAll() f.close() return textutils.unserialize(s) end)
      if ok and type(t)=="table" then
        for k,v in pairs(t) do cfg[k]=v end
        source=path
        break
      end
    end
  end
  if exists and not source then error("Invalid AR config generations; preserve them for recovery") end
  local function save()
    local h
    local ok,err=pcall(function()
      local text=textutils.serialize(cfg)
      assert(#text<=32768,"AR config exceeds 32 KB")
      local free=fs.getFreeSpace("ar.cfg")
      assert(type(free)~="number" or free>=#text+1024,"disk full")
      if source and source~="ar.cfg" then
        if fs.exists("ar.cfg") then fs.delete("ar.cfg") end
        fs.move(source,"ar.cfg")
        source="ar.cfg"
      end
      h=assert(fs.open("ar.cfg.tmp","w"),"cannot write AR config")
      h.write(text) h.close() h=nil
      h=assert(fs.open("ar.cfg.tmp","r"))
      assert(h.readAll()==text,"AR config verification failed") h.close() h=nil
      if fs.exists("ar.cfg.bak") then fs.delete("ar.cfg.bak") end
      if fs.exists("ar.cfg") then
        fs.move("ar.cfg","ar.cfg.bak")
        source="ar.cfg.bak"
      end
      fs.move("ar.cfg.tmp","ar.cfg")
      source="ar.cfg"
    end)
    if h then pcall(h.close) end
    return ok,err
  end
  return cfg,save
end
function H.command(cfg,args,save,authCfg)
  local old={}
  for k,v in pairs(cfg) do old[k]=v end
  if args[1]=="enable" and (args[2]=="on" or args[2]=="off") then cfg.enabled=args[2]=="on"
  elseif args[1]=="owner" and #args==3 then
    if not SSOT.chatAllowed(authCfg or {},args[2],args[3]) then return false,"Owner is not on the shared chat allowlist" end
    cfg.ownerName,cfg.ownerUUID=args[2],args[3]:lower()
  elseif args[1]=="origin" and #args==5 and tostring(args[2]):match("^[%w_]+:[%w_/.-]+$") then
    local x,y,z=tonumber(args[3]),tonumber(args[4]),tonumber(args[5])
    if not finite(x) or not finite(y) or not finite(z) then return false,"Invalid coordinates" end
    cfg.dimension=args[2] cfg.origin={dim=args[2],x=x,y=y,z=z}
  elseif args[1]=="follow" and #args==2 then
    local id=tonumber(args[2])
    if args[2]=="off" then cfg.followTarget=nil
    elseif finite(id) and id>=0 and id%1==0 and id<=2147483647 then cfg.followTarget=id
    else return false,"follow requires a computer ID or off" end
  else return false,"ar enable on|off; ar owner name UUID; ar origin dimension x y z; ar follow ID|off" end
  local ok,err=save()
  if not ok then
    for k in pairs(cfg) do cfg[k]=nil end
    for k,v in pairs(old) do cfg[k]=v end
    return false,err
  end
  return true,"Saved AR configuration"
end
function H.controls(cfg,save,dispatch,notify,authCfg)
  local function execute(action,args)
    if action=="pro" or action=="xray" then
      if cfg.enabled~=true then return false,"Enable AR locally first." end
      if action=="xray" and not authorized(cfg,authCfg) then return false,"AR owner is not on the shared chat allowlist." end
      local key=action=="pro" and "proHud" or "xrayTurtles"
      local old,ore=cfg[key],cfg.xrayOres
      cfg[key]=args[1] and args[1]=="on" or (not args[1] and cfg[key]==false)
      if action=="xray" then cfg.xrayOres=cfg[key] end
      local ok,err=save()
      if not ok then cfg[key],cfg.xrayOres=old,ore return false,tostring(err) end
      return true,action.." "..(cfg[key] and "on" or "off")
    end
    return dispatch(action)
  end
  local chat
  if fs.exists("chat-control.lua") then
    chat=dofile("chat-control.lua").new(cfg,{save=save,execute=execute,reply=function(name,text)
      local box=peripheral.find("chat_box")
      if box then box.sendMessageToPlayer(text,name) end
    end},authCfg)
  end
  return {
    chat=chat,
    key=function(key)
      if cfg.enabled~=true then return false end
      if layers[key] then
        local old=cfg[layers[key]]
        local changed,message=H.toggle(cfg,key,authCfg)
        if not changed then notify(message) return true end
        local ok,err=save()
        if not ok then cfg[layers[key]]=old end
        notify(ok and ("AR "..layers[key].." "..tostring(cfg[layers[key]])) or tostring(err))
        return true
      end
      return false
    end,
  }
end
function H.memory(path)
  local mem={elements={}}
  local exists,loaded,source
  for _,file in ipairs({path,path..".bak",path..".tmp"}) do
    if fs.exists(file) then
      exists=true
      local f=fs.open(file,"r")
      local ok,ids=pcall(function()
        local text=f.readAll() f.close()
        assert(#text<=1048576,"AR ID journal exceeds 1 MB")
        local values=textutils.unserialize(text)
        assert(type(values)=="table" and #values<=16384,"Invalid AR ID journal")
        for _,id in ipairs(values) do
          assert(type(id)=="string" and #id<=192 and id:sub(1,#PREFIX)==PREFIX,"Invalid AR element ID")
        end
        return values
      end)
      if ok and type(ids)=="table" then
        for _,id in ipairs(ids) do mem.elements[id]={} end
        loaded=true
        source=file
        break
      end
    end
  end
  if exists and not loaded then error("Invalid AR ID journal; preserve it for recovery") end
  mem.persist=function(elements)
    local ids={}
    for id in pairs(elements) do ids[#ids+1]=id end
    assert(#ids<=16384,"AR ID journal exceeds 16384 elements")
    table.sort(ids)
    local text=textutils.serialize(ids)
    assert(#text<=1048576,"AR ID journal exceeds 1 MB")
    local free=fs.getFreeSpace(path)
    assert(type(free)~="number" or free>=#text+1024,"AR ID journal disk full")
    if source and source~=path then
      if fs.exists(path) then fs.delete(path) end
      fs.move(source,path)
      source=path
    end
    local f=assert(fs.open(path..".tmp","w"),"cannot journal AR IDs")
    f.write(text) f.close()
    f=assert(fs.open(path..".tmp","r"))
    local actual=f.readAll() f.close()
    assert(actual==text,"AR ID journal verification failed")
    if fs.exists(path..".bak") then fs.delete(path..".bak") end
    if fs.exists(path) then fs.move(path,path..".bak") source=path..".bak" end
    fs.move(path..".tmp",path)
    source=path
  end
  return mem
end
function H.toggle(cfg,key,authCfg)
  local layer=layers[key]
  if cfg.enabled~=true or not layer then return false end
  if layer~="proHud" and not authorized(cfg,authCfg) then
    return false,"AR owner is not on the shared chat allowlist."
  end
  cfg[layer]=cfg[layer]==false
  return true
end
function H.snapshot(fleet,state,cfg,authCfg,cache)
  state=state or {}
  local snap={turtles={},world_map={},anchors=cfg.anchors or {},revision=state.rev or 0,orders={}}
  if type(cfg.spots)=="table" then
    snap.anchors={}
    for k,v in pairs(cfg.anchors or {}) do snap.anchors[k]=v end
    for kind,spots in pairs(cfg.spots) do
      for name,p in pairs(spots) do
        snap.anchors[kind..":"..name]={x=p.x,y=p.y,z=p.z,dim=p.dimension}
      end
    end
  end
  for _,e in ipairs(fleet or {}) do
    local t={}
    for k,v in pairs(e) do t[k]=v end
    local pose=(state.poses or {})[e.id]
    if type(pose)=="table" and finite(pose.x) and finite(pose.y) and finite(pose.z) then
      t.x,t.y,t.z=pose.x,pose.y,pose.z
      if type(pose.dim)=="string" then t.dim=pose.dim end
      t.conf=pose.conf
    end
    local placed=H.place(t,cfg)
    if placed and placed.style=="fix" then
      t.x,t.y,t.z,t.dim,t.conf=placed.x,placed.y,placed.z,placed.dim,placed.conf
      t.unplaced=nil
    else t.unplaced=true end
    snap.turtles[#snap.turtles+1]=t
  end
  cfg=context(snap.turtles,cfg)
  if cfg.enabled~=true or not authorized(cfg,authCfg) or not position(cfg.origin) or cfg.origin.dim~=cfg.dimension
    or (cfg.xrayOres==false and cfg.xrayTunnels~=true) then return snap end
  local o,r,budget=cfg.origin,limit(cfg.radius,64,256),limit(cfg.maxCells,128,256)
  local mapKey=table.concat({state.rev or 0,cfg.dimension,o.dim,o.x,o.y,o.z,r,budget,
    tostring(cfg.xrayOres~=false),tostring(cfg.xrayTunnels==true)},"|")
  if cache and cache.mapKey==mapKey then
    snap.world_map,snap.truncated=cache.worldMap,cache.mapTruncated
    return snap
  end
  local nearest,eligible,scanned={},0,0
  local oreNames={}
  for n,name in pairs(state.names or {}) do oreNames[n]=isOre(name) and true or false end
  local function before(a,b)
    if a.ore~=b.ore then return a.ore end
    if a.distance~=b.distance then return a.distance<b.distance end
    return a.id<b.id
  end
  local function keep(x,y,z,dim,name,ore,air)
    local distance=(x-o.x)^2+(y-o.y)^2+(z-o.z)^2
    if distance>r*r then return end
    eligible=eligible+1
    local worst=nearest[1]
    if #nearest==budget and ((not ore and worst.ore) or (ore==worst.ore and distance>worst.distance)) then return end
    local cell={x=x,y=y,z=z,dim=dim,name=name,state=air and "AIR" or nil}
    local entry={cell=cell,ore=ore,distance=distance,id=cellID(cell)}
    if #nearest<budget then
      local at=#nearest+1
      nearest[at]=entry
      while at>1 do
        local parent=math.floor(at/2)
        if not before(nearest[parent],nearest[at]) then break end
        nearest[parent],nearest[at]=nearest[at],nearest[parent]
        at=parent
      end
    elseif before(entry,nearest[1]) then
      nearest[1]=entry
      local at=1
      while at*2<=#nearest do
        local child=at*2
        if child<#nearest and before(nearest[child],nearest[child+1]) then child=child+1 end
        if not before(nearest[at],nearest[child]) then break end
        nearest[at],nearest[child]=nearest[child],nearest[at]
        at=child
      end
    end
  end
  for key,ch in pairs(state.chunks or {}) do
    local dim,cx,cy,cz=key:match("^(.-)|(-?%d+)|(-?%d+)|(-?%d+)$")
    if dim==cfg.dimension then
      cx,cy,cz=tonumber(cx),tonumber(cy),tonumber(cz)
      if cx*16<=o.x+r and cx*16+15>=o.x-r and cy*16<=o.y+r and cy*16+15>=o.y-r
        and cz*16<=o.z+r and cz*16+15>=o.z-r then
        for i,n in pairs(ch.cells) do
          scanned=scanned+1
          if scanned%256==0 then yieldWork() end
          local ore=oreNames[n] or false
          if (ore and cfg.xrayOres~=false) or (n==0 and cfg.xrayTunnels==true) then
            local at=i-1
            keep(cx*16+at%16,cy*16+math.floor(at/256),cz*16+math.floor(at/16)%16,
              dim,(state.names or {})[n],ore,n==0)
          end
        end
      end
    end
  end
  table.sort(nearest,before)
  for _,entry in ipairs(nearest) do snap.world_map[#snap.world_map+1]=entry.cell end
  snap.truncated=eligible>budget or nil
  if cache then
    cache.mapKey,cache.worldMap,cache.mapTruncated=mapKey,snap.world_map,snap.truncated
  end
  return snap
end
local function same(a,b)
  if not a or #a~=#b then return false end
  for i=1,#b do if a[i]~=b[i] then return false end end
  return true
end
function H.clear(ar,mem)
  mem.reconciled=nil
  local changed=false
  for id in pairs(mem.elements or {}) do ar.delete(id) changed=true end
  if changed then ar.update() end
  mem.elements={}
  if mem.persist then mem.persist(mem.elements) end
end
function H.render(ar,snap,mem,cfg,authCfg)
  if not mem.reconciled then
    local inspect=rawget(ar,"getAllElements")
    if inspect then
      mem.elements=mem.elements or {}
      for id in pairs(inspect()) do
        if type(id)=="string" and id:sub(1,#PREFIX)==PREFIX then mem.elements[id]={} end
      end
    end
    mem.reconciled=true
  end
  if cfg.enabled~=true then
    if next(mem.elements or {}) then H.clear(ar,mem) end
    return
  end
  local hubAt=H.hubPoint(cfg)
  cfg=context(snap.turtles,cfg)
  local allowed=authorized(cfg,authCfg)
  local desired={}
  local function put(method,id,...)
    desired[PREFIX..id]={method,...}
  end
  local function color(c) return c>=0x80000000 and c-0x100000000 or c end
  local function text(id,x,y,str,c) put("drawText2D",id,color(c),x,y,tostring(str):sub(1,64),false) end
  local function rect(id,x,y,w,h,c) put("drawRect2D",id,color(c),x,y,x+w,y+h) end
  local function line(id,a,b,c) put("drawLine3D",id,color(c),a.x,a.y,a.z,b.x,b.y,b.z) end
  local function box(id,p,c)
    local vertices={}
    for _,dy in ipairs({0,1}) do
      for _,xz in ipairs({{0,0},{1,0},{1,1},{0,1}}) do
        vertices[#vertices+1]={x=p.x+xz[1],y=p.y+dy,z=p.z+xz[2]}
      end
    end
    for k,e in ipairs({{1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},{1,5},{2,6},{3,7},{4,8}}) do
      line(id..":edge:"..k,vertices[e[1]],vertices[e[2]],c)
    end
  end
  local turtles={}
  for _,raw in ipairs(snap.turtles or {}) do
    if #turtles>=limit(cfg.maxTurtles,32,32) then break end
    local t={}
    for k,v in pairs(raw) do t[k]=v end
    mem.last=mem.last or {}
    local placed=H.place(t,cfg,{last=mem.last,hub=hubAt})
    if placed and placed.style=="fix" then
      t.x,t.y,t.z,t.dim,t.conf=placed.x,placed.y,placed.z,placed.dim,placed.conf
      t.unplaced=nil
      t.mark=placed
      mem.last[tostring(t.id)]={x=placed.x,y=placed.y,z=placed.z,dim=placed.dim}
      if placed.conf=="suspect" and not tostring(t.status or ""):find("suspect",1,true) then
        t.status=tostring(t.status or t.phase or "Unknown").." [suspect]"
      end
    elseif placed then
      t.unplaced=true
      t.mark=placed
    else t.unplaced=true end
    turtles[#turtles+1]=t
  end
  local low,stopped=0,0
  for _,t in ipairs(turtles) do
    if finite(t.fuel) and t.fuel<250 then low=low+1 end
    if t.phase=="estop" or t.state=="ESTOP" or t.phase=="lost" or t.trouble then stopped=stopped+1 end
  end
  rect("header:bg",8,8,210,30,C.bg)
  text("header:title",12,12,"FLEET / AR",C.cyan)
  text("header:counts",12,24,#turtles.." units | revision "..tostring(snap.revision or 0),C.white)
  local hint=H.hints(cfg,authCfg,cfg.input)
  if hint then text("footer",8,250,hint,C.muted) end
  text("footer:depth",8,262,"Outlines stop at blocks",C.muted)
  if stopped>0 or low>0 then
    rect("alert:bg",228,8,240,24,stopped>0 and C.red or C.gold)
    text("alert:text",232,16,stopped>0 and ("ATTENTION: "..stopped.." units") or ("LOW FUEL: "..low.." units"),C.white)
  end
  if cfg.proHud~=false then
    for i=1,math.min(#turtles,6) do
      local t=turtles[i]
      local id,y="card:"..tostring(t.id),42+(i-1)*32
      rect(id..":bg",8,y,210,29,C.bg)
      text(id..":name",12,y+3,"#"..tostring(t.id).." "..tostring(t.name or t.role or "Turtle"),C.white)
      local stateText=t.stale and "No signal" or t.status or t.phase or t.state or "Unknown"
      if t.mark and t.mark.style=="unknown" then stateText=tostring(stateText).." | unknown"
      elseif t.mark and t.mark.style=="approx" then stateText=tostring(stateText).." | approx"
      elseif t.unplaced then stateText=tostring(stateText).." | no position" end
      text(id..":state",12,y+15,stateText,C.muted)
      rect(id..":fuelbg",164,y+18,48,5,C.border)
      local pct=t.fuel=="unlimited" and 1 or (finite(t.fuel) and math.max(0,math.min(1,t.fuel/(finite(t.maxFuel) and math.max(1,t.maxFuel) or 20000))) or 0)
      if pct>0 then rect(id..":fuel",164,y+18,math.max(1,math.floor(pct*48)),5,finite(t.fuel) and t.fuel<250 and C.red or C.green) end
    end
    rect("radar:bg",376,42,92,92,C.bg)
    text("radar:title",380,46,"RADAR",C.purple)
    if position(cfg.origin) and cfg.origin.dim==cfg.dimension then
      rect("radar:origin",420,86,3,3,C.gold)
      local missing=0
      for _,t in ipairs(turtles) do if not t.mark and not t.stale then missing=missing+1 end end
      if missing>0 then text("radar:missing",380,58,missing.." no position",C.gold) end
      for i,cell in ipairs(snap.world_map or {}) do
        if i>limit(cfg.maxCells,128,256) then break end
        if nearby(cell,cfg) then
          local ore=isOre(cell.name)
          if allowed and ((ore and cfg.xrayOres~=false) or (cell.state=="AIR" and cfg.xrayTunnels==true)) then
            local scale=36/limit(cfg.radius,64,256)
            rect("radar:cell:"..cellID(cell),421+math.floor((cell.x-cfg.origin.x)*scale),
              87+math.floor((cell.z-cfg.origin.z)*scale),2,2,ore and C.cyan or C.muted)
          end
        end
      end
      for _,t in ipairs(turtles) do
        local at=t.mark
        if allowed and cfg.xrayTurtles~=false and at and nearby(at,cfg) and not t.stale then
          local scale=36/limit(cfg.radius,64,256)
          local x,y=421+math.floor((at.x-cfg.origin.x)*scale),87+math.floor((at.z-cfg.origin.z)*scale)
          rect("radar:turtle:"..tostring(t.id),x,y,3,3,at.style=="fix" and C.green or C.gold)
        end
      end
    else text("radar:unknown",380,78,cfg.followTarget and "Target lost" or "Set origin",C.gold) end
  end
  if allowed and cfg.xrayTurtles~=false then
    for _,t in ipairs(turtles) do
      local at=t.mark
      local hubNear=at and at.style=="unknown" and position(hubAt) and at.dim==hubAt.dim
        and (at.x-hubAt.x)^2+(at.y-hubAt.y)^2+(at.z-hubAt.z)^2<=limit(cfg.radius,64,256)^2
      if at and not t.stale and (nearby(at,cfg) or hubNear) then
        local id="turtle:"..tostring(t.id)
        if at.style=="unknown" then
          line(id..":unknown",at,{x=at.x,y=at.y+2,z=at.z},C.gold)
          put("drawText3D",id..":unknown:label",color(C.gold),at.x,at.y+2.2,at.z,0,0,2,
            ("#"..tostring(t.id).." unknown"):sub(1,32),true)
        else
          local tint=at.style=="approx" and C.gold or C.green
          box(id,at,tint)
          put("drawText3D",id..":label",color(tint),at.x+0.5,at.y+1.4,at.z+0.5,0,0,2,
            "#"..tostring(t.id)..(at.style=="approx" and " ~" or ""),true)
        end
      end
    end
  end
  for i,cell in ipairs(snap.world_map or {}) do
    if i>limit(cfg.maxCells,128,256) then break end
    if allowed and nearby(cell,cfg) then
      local ore=isOre(cell.name)
      if ore and cfg.xrayOres~=false then box("ore:"..cellID(cell),cell,C.cyan)
      elseif cell.state=="AIR" and cfg.xrayTunnels==true then box("air:"..cellID(cell),cell,C.muted) end
    end
  end
  local anchors={}
  for name in pairs(snap.anchors or {}) do if type(name)=="string" then anchors[#anchors+1]=name end end
  table.sort(anchors)
  for i=1,math.min(#anchors,16) do
    local name=anchors[i]
    local p=snap.anchors[name]
    if allowed and nearby(p,cfg) then
      line("anchor:"..name..":beam",p,{x=p.x,y=p.y+16,z=p.z},C.gold)
      put("drawText3D","anchor:"..name..":label",color(C.gold),p.x,p.y+16.5,p.z,0,0,3,name:sub(1,32),true)
    end
  end
  local changed=false
  mem.elements=mem.elements or {}
  local membershipChanged=false
  local journal={}
  for id in pairs(mem.elements) do journal[id]=true if not desired[id] then membershipChanged=true end end
  for id in pairs(desired) do journal[id]=true if not mem.elements[id] then membershipChanged=true end end
  if membershipChanged and mem.persist then mem.persist(journal) end
  for id in pairs(mem.elements) do
    if not desired[id] then ar.delete(id) mem.elements[id]=nil changed=true end
  end
  for id,args in pairs(desired) do
    if not same(mem.elements[id],args) then
      ar[args[1]](id,table.unpack(args,2))
      mem.elements[id]=args
      changed=true
    end
  end
  if changed then ar.update() end
  if membershipChanged and mem.persist then mem.persist(desired) end
end
return H
