local U = dofile("so-ui.lua")
local M = { scene = {}, dirs = {[0]={0,-1},{1,0},{0,1},{-1,0}},
  dimensions = {[0]="minecraft:overworld",[-1]="minecraft:the_nether",[1]="minecraft:the_end"} }

M.call = function(name, method, ...)
  local mod = SO.mods[name]
  if mod and type(mod[method]) == "function" then return mod[method](...) end
end
M.dim = function(dim) return M.dimensions[dim] or dim or "minecraft:overworld" end
M.gather = function(now)
  if not M.config or now >= (M.configAt or 0)+5000 then
    M.config, M.configAt = SO.store.read("so-server.cfg") or {}, now
  end
  local config = M.config
  local mine = M.call("mine", "mapView") or {}
  local lumber = M.call("lumber", "mapView") or {}
  local dim = M.dim(config.pos and config.pos.dim or mine.dim or lumber.dim)
  local scene = {dim=dim, server=config.pos, mine=mine, lumber=lumber, turtles={}, drops={}}
  local workers = {}
  for id, row in pairs(M.call("state", "get", "machines") or {}) do
    if row.role == nil or row.role == "worker" or row.role == "turtle" then workers[tostring(id)] = row end
  end
  for id, row in pairs(mine.turtles or {}) do
    local previous = workers[tostring(id)]
    row.seen = previous and previous.seen
    workers[tostring(id)] = row
  end
  if lumber.turtle then
    local previous = workers[tostring(lumber.turtle.id)]
    lumber.turtle.seen = previous and previous.seen
    workers[tostring(lumber.turtle.id)] = lumber.turtle
  end
  for id, row in pairs(workers) do
    local p = row.pose
    if p and M.dim(p.dim or row.dim or mine.dim) == dim then
      local status = M.call("lease", "status", tonumber(id) or id) or {}
      local range = M.call("lease", "inRange", tonumber(id) or id, p)
      local state, color = tostring(row.state or "idle"), "1"
      if status.lost or status.uncertain or range == false or state == "lost" or state == "range" or state == "out of range"
          or row.seen and now-row.seen >= 120000 then color = "e"
      elseif state == "done" then color = "b"
      elseif state == "mining" or state == "working" or state == "lumber" or status.open and state ~= "stopped" and state ~= "idle" then color = "d" end
      scene.turtles[#scene.turtles+1] = {id=id, pose=p, color=color}
    end
  end
  table.sort(scene.turtles, function(a,b) return a.id < b.id end)
  for _, p in ipairs(M.call("drops", "list") or {}) do
    if M.dim(p.dim) == dim then scene.drops[#scene.drops+1] = p end
  end
  if lumber.saplings and M.dim(lumber.dim) == dim then
    local p = SO.store.copy(lumber.saplings) p.kind = "saplings" scene.drops[#scene.drops+1] = p
  end
  M.scene = scene
end
M.view = function(session)
  session.map = session.map or {level="all", fit=true}
  return session.map
end
M.geometry = function(scene)
  local j = scene.mine
  if not j.home or j.homeSet == false or M.dim(j.dim) ~= scene.dim then return end
  local d = M.dirs[j.home.facing or 0]
  local count = math.max(1, j.branches or 0)
  return {x=j.home.x+d[1], z=j.home.z+d[2], dx=d[1], dz=d[2],
    rx=-d[2], rz=d[1], gap=j.mode=="fast" and 2 or 4, count=count, length=j.length or 64,
    bottom=j.bottom, top=j.home.y}
end
M.render = function(w, h, session)
  session = type(session)=="table" and session or {}
  local v, s = M.view(session), M.scene
  local c, vw, vh = U.canvas(w,h), w, math.max(1,h-4)
  local g = M.geometry(s)
  local surface = s.server and s.server.y or s.lumber.ground or g and g.top or 64
  local y = v.level=="surface" and surface or g and g.bottom or surface
  local minx, maxx, minz, maxz
  local function bound(x,z)
    minx, maxx = math.min(minx or x,x), math.max(maxx or x,x)
    minz, maxz = math.min(minz or z,z), math.max(maxz or z,z)
  end
  if g then
    bound(g.x,g.z)
    bound(g.x+g.dx*g.count*g.gap,g.z+g.dz*g.count*g.gap)
    bound(g.x+g.dx*g.count*g.gap+g.rx*g.length,g.z+g.dz*g.count*g.gap+g.rz*g.length)
    bound(g.x+g.rx*g.length,g.z+g.rz*g.length)
  end
  local area = M.dim(s.lumber.dim)==s.dim and s.lumber.area
  if area then bound(area.x1,area.z1) bound(area.x2,area.z2) end
  if s.server then bound(s.server.x,s.server.z) end
  for _, p in ipairs(s.drops) do bound(p.x,p.z) end
  for _, t in ipairs(s.turtles) do bound(t.pose.x,t.pose.z) end
  minx,maxx,minz,maxz = minx or 0,maxx or 0,minz or 0,maxz or 0
  if v.fit then
    v.scale = math.max(1,math.ceil((maxx-minx+3)/vw),math.ceil((maxz-minz+3)/vh))
    v.x, v.z = math.floor((minx+maxx)/2), math.floor((minz+maxz)/2)
  end
  local scale = v.scale or 1
  local left, top = v.x-math.floor(vw/2)*scale, v.z-math.floor(vh/2)*scale
  local function project(x,z) return math.floor((x-left)/scale)+1, math.floor((z-top)/scale)+2 end
  local function visible(p) return v.level=="all" or p.y==y end
  local function mark(p,ch,color)
    local x,z = project(p.x,p.z)
    if x>=1 and x<=vw and z>=2 and z<=vh+1 then c.put(x,z,ch,"f",color) return x,z end
  end
  local key = table.concat({left,top,scale,w,h,v.level,y,s.dim},":")
  if v.scanKey ~= key then v.scanKey, v.cursor, v.dug, v.nextDug = key, 0, {}, {} end
  local low, high = y,y
  if v.level=="all" then low,high = math.min(y,surface),math.max(y,surface) end
  local width, depth = vw*scale,vh*scale
  local total = width*depth*(high-low+1)
  for _=1,math.min(256,total) do
    local n = v.cursor
    local x,z = left+n%width, top+math.floor(n/width)%depth
    local level = low+math.floor(n/(width*depth))
    if M.call("cells","isDug",x,level,z,s.dim) then
      local px,pz = project(x,z)
      v.dug[(pz-2)*vw+px],v.nextDug[(pz-2)*vw+px] = true,true
    end
    v.cursor = (n+1)%total
    if v.cursor==0 then v.dug,v.nextDug=v.nextDug,{} end
  end
  for z=2,vh+1 do
    for x=1,vw do
      if v.dug[(z-2)*vw+x] then c.put(x,z," ","0","8") end
      local x1,z1 = left+(x-1)*scale,top+(z-2)*scale
      local x2,z2 = x1+scale-1,z1+scale-1
      if area and (v.level=="all" or y==s.lumber.ground) and
          ((x1<=area.x1 and x2>=area.x1 or x1<=area.x2 and x2>=area.x2) and z2>=area.z1 and z1<=area.z2
          or (z1<=area.z1 and z2>=area.z1 or z1<=area.z2 and z2>=area.z2) and x2>=area.x1 and x1<=area.x2) then
        c.put(x,z," ","f","d")
      end
      if g then
        local ax,az = x1-g.x,z1-g.z
        local bx,bz = x2-g.x,z2-g.z
        local a1,a2 = math.min(ax*g.dx+az*g.dz,bx*g.dx+bz*g.dz), math.max(ax*g.dx+az*g.dz,bx*g.dx+bz*g.dz)
        local r1,r2 = math.min(ax*g.rx+az*g.rz,bx*g.rx+bz*g.rz), math.max(ax*g.rx+az*g.rz,bx*g.rx+bz*g.rz)
        local branch = math.max(1,math.ceil(a1/g.gap))
        if (v.level=="all" or y==g.bottom) and
            (r1<=0 and r2>=0 and a2>=0 and a1<=g.count*g.gap
            or branch<=g.count and branch*g.gap<=a2 and r2>=0 and r1<=g.length) then
          if not v.dug[(z-2)*vw+x] then c.put(x,z," ","f","7") end
        end
      end
    end
  end
  if g and (v.level=="all" or y>=math.min(g.bottom,g.top) and y<=math.max(g.bottom,g.top)) then
    mark({x=g.x,z=g.z},"H","9")
  end
  for _, p in ipairs(s.drops) do
    if visible(p) then mark(p,(p.kind or "chest"):sub(1,1):upper(),p.broken and "e" or "a") end
  end
  if s.server and visible(s.server) then mark(s.server,"@","9") end
  local occupied = {}
  for _, t in ipairs(s.turtles) do if visible(t.pose) then
    local x,z = project(t.pose.x,t.pose.z)
    if x>=1 and x<=vw and z>=2 and z<=vh+1 then occupied[z*vw+x] = true end
  end end
  for _, t in ipairs(s.turtles) do if visible(t.pose) then
    local arrow = ({[0]="^",">","v","<",north="^",east=">",south="v",west="<"})[t.pose.facing or t.pose.f or 0] or "^"
    local x,z = mark(t.pose,arrow,t.color)
    if x and scale==1 and x+#t.id<=vw then
      local free = true
      for dx=1,#t.id do
        local cell = c.cells[z][x+dx]
        if occupied[z*vw+x+dx] or cell[1]~=" " then free=false end
      end
      if free then c.put(x+1,z,t.id,"f",t.color) end
    end
  end end
  c.header("MAP", "N ^ 1:"..scale)
  local controls = {{"BACK","map-back"},{"FIT","map-fit"},{"+","map-in"},{"-","map-out"}}
  local cols = U.grid(w,h,4)
  for i,b in ipairs(controls) do c.button(cols[i].x,h-2,cols[i].w,b[1],b[2],i==2 and "9" or "7",1) end
  cols = U.grid(w,h,4)
  for i,b in ipairs({{"^","map-n"},{"<","map-w"},{"v","map-s"},{">","map-e"}}) do
    c.button(cols[i].x,h-1,cols[i].w,b[1],b[2],"7",1)
  end
  c.button(1,h,w,v.level=="all" and "ALL" or (v.level=="surface" and "SURFACE " or "MINE ")..y,"map-level","7",1)
  return c.frame()
end
M.input = function(event)
  if not event.session then return end
  local v,id = M.view(event.session), event.id
  if id=="map-fit" then v.fit=true
  elseif id=="map-level" then v.level=({mine="surface",surface="all",all="mine"})[v.level]
  elseif id=="map-in" or id=="map-out" then
    v.fit=false v.scale=math.max(1,math.min(4096,(v.scale or 1)*(id=="map-in" and 0.5 or 2)))
    v.scale=math.ceil(v.scale)
  else
    local d = ({["map-n"]={0,-1},["map-e"]={1,0},["map-s"]={0,1},["map-w"]={-1,0}})[id]
    if d then v.fit=false v.x=(v.x or 0)+d[1]*3*(v.scale or 1) v.z=(v.z or 0)+d[2]*3*(v.scale or 1) end
  end
end
return {name="map",handlers={},tick=function(now)
  M.gather(now)
  if not M.wired and SO.mods.display then SO.mods.display.screen("map",M.render,M.input) M.wired=true end
end}
