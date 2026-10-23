local P = dofile("so-plan.lua")
local M = {}
local junk, keep = {}, {}
for name in ("cobblestone cobbled_deepslate stone deepslate granite diorite andesite tuff calcite dirt coarse_dirt rooted_dirt grass_block mud gravel sand red_sand sandstone netherrack basalt smooth_basalt blackstone dripstone_block pointed_dripstone flint clay_ball moss_block mossy_cobblestone soul_sand soul_soil end_stone amethyst_shard infested_stone infested_deepslate"):gmatch("%S+") do junk["minecraft:" .. name] = true end
for name in ("diamond emerald lapis_lazuli redstone coal charcoal coal_block quartz ancient_debris netherite_scrap gold_nugget bucket lava_bucket water_bucket torch"):gmatch("%S+") do keep["minecraft:" .. name] = true end
M.ores = { diamond = true, redstone = true, gold = true, lapis = true, iron = true, copper = true, coal = true }
function M.key(p) return p.x .. "," .. p.y .. "," .. p.z end
function M.same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
function M.ore(d, ores)
  if not d or type(d.name) ~= "string" then return false end
  if ores and #ores > 0 then
    local matched = false
    for _, name in ipairs(ores) do
      if d.name:match("[:_]" .. name .. "_") or d.name:match("[:_]" .. name .. "$")
          or (d.tags and (d.tags["c:ores/" .. name] or d.tags["forge:ores/" .. name])) then matched = true break end
    end
    if not matched then return false end
  end
  if d.name:match("_ore$") or d.name:find(":raw_", 1, true) or d.name:find(":ore_", 1, true) then return true end
  for tag, yes in pairs(d.tags or {}) do
    if yes and (tag == "c:ores" or tag == "forge:ores" or tag:match("^c:ores/") or tag:match("^forge:ores/")) then return true end
  end
  return false
end
function M.junk(d)
  if junk[d.name] then return true end
  for _, part in ipairs({ "sandstone", "terracotta", "cobble" }) do if d.name:find(part, 1, true) then return true end end
  if keep[d.name] or M.ore(d) or P.fuelValue(d.name) > 0 then return false end
  for tag in pairs(d.tags or {}) do
    if tag:match("^[cf]:") or tag:match("^forge:") then
      for _, part in ipairs({ "ores", "raw_materials", "gems", "dusts" }) do if tag:find(part, 1, true) then return false end end
    end
    if tag == "minecraft:coals" then return false end
  end
  return true
end
function M.distance(a, b) return math.abs(a.x-b.x) + math.abs(a.y-b.y) + math.abs(a.z-b.z) end
function M.cell(p, dir)
  local x, y, z = P.ahead(p, dir)
  return { dim = p.dim, x = x, y = y, z = z }
end
function M.turn(p, want)
  local delta = (want - p.facing) % 4
  if delta == 0 then return nil end
  return { op = delta == 3 and "turnLeft" or "turnRight" }
end
function M.route(job, branch)
  local home = job.home
  local p = P.apply({ dim = job.dim, x = home.x, y = home.y, z = home.z, facing = home.facing }, "forward")
  local out = { p }
  p = { dim = job.dim, x = p.x, y = job.bottom, z = p.z, facing = p.facing }
  out[#out+1] = p
  local gap = job.mode == "fast" and 2 or 4
  for _ = 1, (branch + 1) * gap do p = P.apply(p, "forward") out[#out+1] = p end
  p = P.apply(p, "turnRight")
  for _ = 1, job.length do p = P.apply(p, "forward") out[#out+1] = p end
  return out
end
local function laneShape(job)
  local top=P.apply({dim=job.dim,x=job.home.x,y=job.home.y,z=job.home.z,facing=job.home.facing},"forward")
  local last=0
  for _,row in pairs(job.turtles or {}) do last=math.max(last,row.branch or 0,row.returning and row.returning.branch or 0) end
  return top,(last+1)*(job.mode=="fast" and 2 or 4)
end
function M.lane(job, exit)
  local top,length=laneShape(job)
  local cells={}
  for y=math.min(top.y,job.bottom),math.max(top.y,job.bottom) do
    cells[#cells+1]={dim=job.dim,x=top.x,y=y,z=top.z}
  end
  local p={dim=job.dim,x=top.x,y=job.bottom,z=top.z,facing=top.facing}
  for _=1,length do p=P.apply(p,"forward") cells[#cells+1]=p end
  if exit and not M.inLane(job,exit) then cells[#cells+1]={dim=job.dim,x=exit.x,y=exit.y,z=exit.z} end
  return cells
end
function M.inLane(job, p)
  if not p or p.dim and p.dim~=job.dim then return false end
  local top,length=laneShape(job)
  if p.x==top.x and p.z==top.z and p.y>=math.min(top.y,job.bottom) and p.y<=math.max(top.y,job.bottom) then return true end
  if p.y~=job.bottom then return false end
  local dx,dz=({[0]=0,1,0,-1})[top.facing],({[0]=-1,0,1,0})[top.facing]
  local x,z=p.x-top.x,p.z-top.z
  local along=x*dx+z*dz
  return x*dz-z*dx==0 and along>=0 and along<=length
end
function M.lanePass(job,row)
  local cells,seen={},{}
  local cursor=row.pose
  local entered=M.inLane(job,cursor)
  local function add(p)
    local key=M.key(p)
    if not seen[key] then cells[#cells+1]={dim=job.dim,x=p.x,y=p.y,z=p.z} seen[key]=true end
  end
  if row.trip and row.trip.path then
    -- Reserve the turnaround too, so a second turtle cannot block the return at the chest.
    local first
    for i, p in ipairs(row.trip.path) do
      if M.inLane(job,p) then first=math.max(1,i-1) break end
    end
    if first then for i=first,#row.trip.path do add(row.trip.path[i]) end end
    return cells
  end
  if entered then add(cursor) end
  local function walk(goal,trip,vein)
    local order=not vein and job.home.facing%2==0 and not M.inLane(job,goal) and "yzx" or "yxz"
    local path=trip and M.travel(cursor,goal,trip.point,job,row) or P.path(cursor,goal,{order=order}).cells
    for _,p in ipairs(path or {}) do
      if M.inLane(job,p) then entered=true add(p)
      elseif entered then add(p) return true end
    end
    cursor={dim=job.dim,x=goal.x,y=goal.y,z=goal.z,facing=goal.facing or cursor.facing or 0}
  end
  local vein=row.veins and row.veins[#row.veins]
  if row.trip then
    if walk(row.goal,row.trip) then return cells end
  elseif vein and row.goal and M.same(vein,row.goal) then
    if walk(row.goal,nil,true) then return cells end
  end
  if row.returning then
    if walk(row.returning.junction) then return cells end
    local route=M.route(job,row.returning.branch)
    local reached=false
    for _,cell in ipairs(route) do
      if reached and walk(cell) then break end
      if M.same(cell,row.returning.junction) then reached=true end
    end
    return cells
  end
  local route=row.route or M.route(job,row.branch or 0)
  for i=row.index or 1,#route do if walk(route[i]) then break end end
  return cells
end
function M.sealable(item)
  if not M.junk(item) then return false end
  if item.name == "minecraft:sand" or item.name == "minecraft:red_sand" or item.name == "minecraft:gravel" then return false end
  for part in ("diamond emerald raw_ coal redstone lapis quartz flint ingot gem nugget dust shard ball bone string stick torch bucket _ore ore_ gravel concrete_powder seeds pickaxe modem pointed_dripstone"):gmatch("%S+") do
    if item.name:find(part,1,true) then return false end
  end
  return true
end
function M.cleanup(inv, all, side)
  local steps, kept = {}, false
  for _, item in ipairs(inv) do
    if M.junk(item) then
      if kept or all or not M.sealable(item) then
        steps[#steps+1] = { op = "select", slot = item.slot }
        steps[#steps+1] = { op = "discard", side = side or "down" }
      else kept = true end
    end
    if #steps >= 16 then break end
  end
  return steps
end
function M.supplyRoute(job, row, stand, point, lookup)
  local top = P.apply({dim=job.dim,x=job.home.x,y=job.home.y,z=job.home.z,facing=job.home.facing}, "forward")
  local bottom = {dim=job.dim,x=top.x,y=job.bottom,z=top.z,facing=top.facing}
  local access = row.access or {row.pose}
  local back = access[#access]
  if not row.access and lookup and row.route and back.y ~= top.y and not M.inLane(job, back) then
    local anchor = row.route[math.max(1, (row.index or 1)-1)]
    if anchor and not M.same(back, anchor) then
      local queue, parents, visited, head = {back}, {[M.key(back)]=false}, {[M.key(back)]=true}, 1
      local found
      while queue[head] and head <= 512 do
        local cell = queue[head] head = head + 1
        if M.same(cell, anchor) then found = cell break end
        for _, delta in ipairs({{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}) do
          local nextCell = {dim=job.dim,x=cell.x+delta[1],y=cell.y+delta[2],z=cell.z+delta[3]}
          local key = M.key(nextCell)
          if not visited[key] then
            visited[key] = true
            if (not point or not M.same(nextCell, point)) and lookup(nextCell) == false then
              parents[key] = cell queue[#queue+1] = nextCell
            end
          end
        end
      end
      if not found then return nil end
      access = {}
      while found do table.insert(access, 1, found) found = parents[M.key(found)] end
      back = anchor
    end
  end
  local junction = {dim=job.dim,x=back.x,y=job.bottom,z=back.z}
  if top.facing % 2 == 0 then junction.x = top.x else junction.z = top.z end
  local waypoints
  if M.inLane(job, back) then
    waypoints = back.x == top.x and back.z == top.z and {top, stand} or {bottom, top, stand}
  elseif back.y == top.y then waypoints = {stand}
  else waypoints = {junction, bottom, top, stand} end
  local cells, pose = {}, back
  for _, cell in ipairs(access) do
    if point and M.same(cell,point) then return nil end
    cells[#cells+1] = cell
  end
  for i, waypoint in ipairs(waypoints) do
    local part = i == #waypoints and M.travel(pose, waypoint, point) or P.path(pose, waypoint, {order="yxz"}).cells
    if not part then return nil end
    for _, cell in ipairs(part) do
      if point and M.same(cell, point) then return nil end
      local repeated
      for n, old in ipairs(cells) do if M.same(old,cell) then repeated=n break end end
      if repeated then while #cells>repeated do table.remove(cells) end
      else cells[#cells+1] = cell end
    end
    pose = waypoint
  end
  return cells, access
end
function M.supplyDistance(job, row, stand, lookup)
  local cells = M.supplyRoute(job, row, stand or job.home, nil, lookup)
  return cells and #cells-1 or math.huge
end
function M.travel(from, goal, point, job, row)
  if job and job.home and row and row.trip then
    local trip = row.trip
    local cells = trip.path or M.supplyRoute(job, {pose=trip.back}, trip.stand, point)
    if not cells then return nil end
    local first, last, step = 1, #cells, 1
    if trip.stage == "back" then first, last, step = #cells, 1, -1 end
    local found, out = false, {}
    for i = first, last, step do
      if found then out[#out+1] = cells[i]
      elseif M.same(cells[i], from) then found = true end
    end
    return found and out or nil
  end
  local function join(waypoints, order)
    local cells, pose = {}, from
    for _, waypoint in ipairs(waypoints) do
      local path = P.path(pose, waypoint, { order = order })
      for _, cell in ipairs(path.cells) do
        if point and M.same(cell, point) then return nil end
        cells[#cells + 1] = cell
      end
      pose = path.pose
    end
    return cells
  end
  for _, order in ipairs({ "yxz", "yzx", "xyz", "xzy", "zxy", "zyx" }) do
    local cells = join({ goal }, order)
    if cells then return cells end
  end
  for _, axis in ipairs({ "x", "z", "y" }) do
    for _, offset in ipairs({ 1, -1 }) do
      local a, b = {}, {}
      for key, value in pairs(from) do a[key] = value end
      for key, value in pairs(goal) do b[key] = value end
      a[axis], b[axis] = from[axis] + offset, from[axis] + offset
      local cells = join({ a, b, goal }, "yxz")
      if cells then return cells end
    end
  end
end
local function nextOne(job, row, lookup, inv, _fuel)
  local p, goal = row.pose, row.goal
  local out = { steps = {}, cells = {}, pose = p }
  if not goal or M.same(p, goal) then out.kind = "arrived" return out end
  if row.trip then
    local route = M.travel(p, goal, row.trip.point, job, row)
    if not route or not route[1] then out.kind, out.error = "hold", "no route around drop" return out end
    goal = route[1]
  end
  local dir, want
  if p.y ~= goal.y then dir = goal.y > p.y and "up" or "down"
  elseif not row.trip and not (row.veins and #row.veins>0) and job.home
      and job.home.facing%2==0 and p.z~=goal.z and not M.inLane(job,goal) then
    dir,want="forward",goal.z>p.z and 2 or 0
  elseif p.x ~= goal.x then dir, want = "forward", goal.x > p.x and 1 or 3
  else dir, want = "forward", goal.z > p.z and 2 or 0 end
  local turn = want and M.turn(p, want)
  if turn then out.steps = { turn } out.pose = P.apply(p, turn.op) out.kind = "turn" return out end
  local cell = M.cell(p, dir)
  local known = lookup(cell)
  local suffix = dir == "up" and "Up" or dir == "down" and "Down" or ""
  out.cells, out.cell = { cell }, cell
  if known == nil then out.steps, out.kind = { { op = "inspect" .. suffix } }, "inspect"
  elseif known ~= false then
    if known.name == "minecraft:lava" or known.name == "minecraft:water" then
      local selected, scoop
      if known.name == "minecraft:lava" and known.level == 0 then
        for _, item in ipairs(inv) do if item.name == "minecraft:bucket" then selected, scoop = item, true break end end
      end
      if not selected then for _, item in ipairs(inv) do if M.sealable(item) then selected = item break end end end
      if selected then
        out.steps = { { op = "select", slot = selected.slot }, { op = "place" .. suffix } }
        if scoop then out.steps[#out.steps+1] = { op = "refuel", n = 1 } end
        out.kind = "seal" return out
      end
      out.kind, out.error = "hold", "fluid needs bucket or sealing block"
    elseif known.name:find("chest", 1, true) or known.name:find("barrel", 1, true)
        or (known.tags and (known.tags["c:chests"] or known.tags["forge:chests"])) then
      out.kind, out.error = "hold", "container blocks route"
    else out.steps, out.kind = { { op = "dig" .. suffix } }, "dig" out.ore = M.ore(known) and known.name or nil end
  else out.steps, out.kind, out.pose = { { op = dir } }, "move", P.apply(p, dir) end
  return out
end
function M.next(job, row, lookup, inv, fuel)
  local out = { kind = "batch", steps = {}, cells = {}, actions = {}, pose = row.pose }
  local cursor = { pose = row.pose, goal = row.goal, trip = row.trip, veins = row.veins, branch = row.branch, route = row.route, index = row.index }
  while #out.steps < 16 do
    local action = nextOne(job, cursor, lookup, inv, fuel)
    if #action.steps == 0 or #out.steps + #action.steps > 16 then
      if #out.steps == 0 then return action end
      break
    end
    local first = out.actions[1]
    if first then
      if first.kind == "turn" and action.kind ~= "turn" then break end
      if first.kind == "move" and action.kind ~= "inspect"
          and (action.kind ~= "move" or action.steps[1].op ~= first.steps[1].op) then break end
    end
    action.first = #out.steps + 1
    out.actions[#out.actions+1] = action
    for _, step in ipairs(action.steps) do out.steps[#out.steps+1] = step end
    for _, cell in ipairs(action.cells) do out.cells[#out.cells+1] = cell end
    out.pose = action.pose
    if action.kind ~= "move" and action.kind ~= "turn" then break end
    cursor.pose = action.pose
    if action.kind == "move" and (not row.trip and row.pose.y == row.goal.y
        or row.trip and row.trip.shared~=false and not M.inLane(job,action.pose)) then break end
  end
  if #out.actions == 1 then return out.actions[1] end
  return out
end
return M
