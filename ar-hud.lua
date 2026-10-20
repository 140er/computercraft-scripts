local H = {}
local PREFIX = "ssot-ar:"
local C = { bg=0xDD11161D, border=0xFF30363D, cyan=0xFF58A6FF, green=0xFF2EA043,
  gold=0xFFD29922, red=0xFFF85149, purple=0xFFA371F7, white=0xFFE6EDF3, muted=0xFF8B949E }
local layers = { p="proHud", t="xrayTurtles", o="xrayOres", a="xrayTunnels" }
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
local function context(turtles,cfg)
  if not cfg.followTarget then return cfg end
  local out={}
  for k,v in pairs(cfg) do out[k]=v end
  out.origin=nil
  for _,t in ipairs(turtles or {}) do
    if tostring(t.id)==tostring(cfg.followTarget) and not t.stale and position(t) then
      out.origin={x=t.x,y=t.y,z=t.z,dim=t.dim}
      out.dimension=t.dim
      break
    end
  end
  return out
end
local function cellID(cell) return cell.dim..":"..cell.x..":"..cell.y..":"..cell.z end
local function isOre(cell)
  return type(cell.name)=="string" and (cell.name:find("_ore",1,true) or cell.name:find("ancient_debris",1,true))
end
function H.defaults()
  return {enabled=false,proHud=true,xrayTurtles=true,xrayOres=true,xrayTunnels=false,
    dimension="minecraft:overworld",radius=64,maxTurtles=32,maxCells=128,anchors={}}
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
function H.command(cfg,args,save)
  local old={}
  for k,v in pairs(cfg) do old[k]=v end
  if args[1]=="enable" and (args[2]=="on" or args[2]=="off") then cfg.enabled=args[2]=="on"
  elseif args[1]=="origin" and #args==5 and tostring(args[2]):match("^[%w_]+:[%w_/.-]+$") then
    local x,y,z=tonumber(args[3]),tonumber(args[4]),tonumber(args[5])
    if not finite(x) or not finite(y) or not finite(z) then return false,"Invalid coordinates" end
    cfg.dimension=args[2] cfg.origin={dim=args[2],x=x,y=y,z=z}
  elseif args[1]=="follow" and #args==2 then
    local id=tonumber(args[2])
    if args[2]=="off" then cfg.followTarget=nil
    elseif finite(id) and id>=0 and id%1==0 and id<=2147483647 then cfg.followTarget=id
    else return false,"follow requires a computer ID or off" end
  else return false,"ar enable on|off; ar origin dimension x y z; ar follow ID|off" end
  local ok,err=save()
  if not ok then
    for k in pairs(cfg) do cfg[k]=nil end
    for k,v in pairs(old) do cfg[k]=v end
    return false,err
  end
  return true,"Saved AR configuration"
end
function H.controls(cfg,save,dispatch,notify)
  local function execute(action,args)
    if action=="pro" or action=="xray" then
      if cfg.enabled~=true then return false,"Enable AR locally first." end
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
    end})
  end
  local pending,untilAt
  return {
    chat=chat,
    key=function(key)
      if cfg.enabled~=true then return false end
      if layers[key] then
        local old=cfg[layers[key]]
        H.toggle(cfg,key)
        local ok,err=save()
        if not ok then cfg[layers[key]]=old end
        notify(ok and ("AR "..layers[key].." "..tostring(cfg[layers[key]])) or tostring(err))
        return true
      end
      local action=key=="h" and "hub" or (key=="r" and "recharge")
      if not action then return false end
      local now=os.epoch("utc")
      if pending==action and now<untilAt then
        pending=nil
        local ok,message=execute(action,{})
        notify(message or (ok and "Queued" or "Unavailable"))
      else
        pending,untilAt=action,now+30000
        notify("Press "..key:upper().." again within 30s to confirm "..action)
      end
      return true
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
function H.toggle(cfg,key)
  local layer=layers[key]
  if cfg.enabled~=true or not layer then return false end
  cfg[layer]=cfg[layer]==false
  return true
end
function H.snapshot(fleet,state,cfg)
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
    if pose then t.x,t.y,t.z,t.dim=pose.x,pose.y,pose.z,pose.dim end
    snap.turtles[#snap.turtles+1]=t
  end
  cfg=context(snap.turtles,cfg)
  if not position(cfg.origin) then return snap end
  local keys={}
  for key in pairs(state.chunks or {}) do
    local dim,cx,cy,cz=key:match("^(.-)|(-?%d+)|(-?%d+)|(-?%d+)$")
    if dim==cfg.dimension then
      cx,cy,cz=tonumber(cx),tonumber(cy),tonumber(cz)
      local o,r=cfg.origin,limit(cfg.radius,64,256)
      if cx*16<=o.x+r and cx*16+15>=o.x-r and cy*16<=o.y+r and cy*16+15>=o.y-r
        and cz*16<=o.z+r and cz*16+15>=o.z-r then
        keys[#keys+1]={key=key,dim=dim,x=cx,y=cy,z=cz,d=(cx*16+8-o.x)^2+(cy*16+8-o.y)^2+(cz*16+8-o.z)^2}
      end
    end
  end
  table.sort(keys,function(a,b) return a.d==b.d and a.key<b.key or a.d<b.d end)
  local scanned=0
  for _,ch in ipairs(keys) do
      for i=1,4096 do
        scanned=scanned+1
        if scanned>8192 then snap.truncated=true return snap end
        if scanned%512==0 and type(sleep)=="function" then sleep(0) end
        local n=state.chunks[ch.key].cells[i]
        if n~=nil then
          local at=i-1
          local cell={x=ch.x*16+at%16,y=ch.y*16+math.floor(at/256),
            z=ch.z*16+math.floor(at/16)%16,dim=ch.dim,name=(state.names or {})[n],state=n==0 and "AIR" or nil}
          if nearby(cell,cfg) and ((isOre(cell) and cfg.xrayOres~=false)
            or (cell.state=="AIR" and cfg.xrayTunnels==true)) then
            snap.world_map[#snap.world_map+1]=cell
            if #snap.world_map>=limit(cfg.maxCells,128,256) then return snap end
          end
        end
      end
  end
  return snap
end
local function same(a,b)
  if not a or #a~=#b then return false end
  for i=1,#b do if a[i]~=b[i] then return false end end
  return true
end
function H.clear(ar,mem)
  local changed=false
  for id in pairs(mem.elements or {}) do ar.delete(id) changed=true end
  if changed then ar.update() end
  mem.elements={}
  if mem.persist then mem.persist(mem.elements) end
end
function H.render(ar,snap,mem,cfg)
  if cfg.enabled~=true then
    if next(mem.elements or {}) then H.clear(ar,mem) end
    return
  end
  cfg=context(snap.turtles,cfg)
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
  for _,t in ipairs(snap.turtles or {}) do
    if #turtles>=limit(cfg.maxTurtles,32,32) then break end
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
  text("footer",8,250,"P HUD | T turtles | O ore | A air | H hub | R recharge",C.muted)
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
      text(id..":state",12,y+15,t.stale and "No signal" or t.status or t.phase or t.state or "Unknown",C.muted)
      rect(id..":fuelbg",164,y+18,48,5,C.border)
      local pct=t.fuel=="unlimited" and 1 or (finite(t.fuel) and math.max(0,math.min(1,t.fuel/(finite(t.maxFuel) and math.max(1,t.maxFuel) or 20000))) or 0)
      if pct>0 then rect(id..":fuel",164,y+18,math.max(1,math.floor(pct*48)),5,finite(t.fuel) and t.fuel<250 and C.red or C.green) end
    end
    rect("radar:bg",376,42,92,92,C.bg)
    text("radar:title",380,46,"RADAR",C.purple)
    if position(cfg.origin) and cfg.origin.dim==cfg.dimension then
      rect("radar:origin",420,86,3,3,C.gold)
      for i,cell in ipairs(snap.world_map or {}) do
        if i>limit(cfg.maxCells,128,256) then break end
        if nearby(cell,cfg) then
          local ore=isOre(cell)
          if (ore and cfg.xrayOres~=false) or (cell.state=="AIR" and cfg.xrayTunnels==true) then
            local scale=36/limit(cfg.radius,64,256)
            rect("radar:cell:"..cellID(cell),421+math.floor((cell.x-cfg.origin.x)*scale),
              87+math.floor((cell.z-cfg.origin.z)*scale),2,2,ore and C.cyan or C.muted)
          end
        end
      end
      for _,t in ipairs(turtles) do
        if nearby(t,cfg) and not t.stale then
          local scale=36/limit(cfg.radius,64,256)
          local x,y=421+math.floor((t.x-cfg.origin.x)*scale),87+math.floor((t.z-cfg.origin.z)*scale)
          rect("radar:turtle:"..tostring(t.id),x,y,3,3,C.green)
        end
      end
    else text("radar:unknown",380,78,cfg.followTarget and "Target lost" or "Set origin",C.gold) end
  end
  if cfg.xrayTurtles~=false then
    for _,t in ipairs(turtles) do
      if nearby(t,cfg) and not t.stale then
        local id="turtle:"..tostring(t.id)
        box(id,t,C.green)
        put("drawText3D",id..":label",color(C.green),t.x+0.5,t.y+1.4,t.z+0.5,0,0,2,"#"..tostring(t.id),true)
      end
    end
  end
  for i,cell in ipairs(snap.world_map or {}) do
    if i>limit(cfg.maxCells,128,256) then break end
    if nearby(cell,cfg) then
      local ore=isOre(cell)
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
    if nearby(p,cfg) then
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
