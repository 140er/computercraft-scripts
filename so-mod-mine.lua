local P = dofile("so-plan.lua")
local M = dofile("so-mine-plan.lua")
local S = { wired = false, pending = {}, known = {}, dugFacts = {}, burst = { n = 0 }, error = nil }
S.homeRoutes = setmetatable({}, {__mode="k"})
local unloadKeep = {
  ["minecraft:bucket"] = true, ["minecraft:lava_bucket"] = true,
  ["minecraft:water_bucket"] = true, ["minecraft:torch"] = true,
}
local box = SO.store.store("so-data/mine/job", function(v) return type(v) == "table" and type(v.turtles) == "table" end)
local job = box.value or { homeSet = false, dim = "minecraft:overworld", home = { x = 0, y = 0, z = 0, facing = 0 }, bottom = -58,
  length = 64, mode = "thorough", ores = {}, turtles = {}, progress = { nextBranch = 0, done = 0 }, running = false }
local function mod(name) return SO.mods and SO.mods[name] end
local function call(name, fn, ...)
  local m = mod(name)
  if m and type(m[fn]) == "function" then return m[fn](...) end
end
local function save()
  local ok, err = box.save(job)
  if not ok then S.error = tostring(err) job.running = false end
  return ok
end
local function emit(kind, data) call("state", "emit", kind, data) end
local function owner(id) return "mine:" .. id end
local function lookup(cell)
  return S.known[M.key(cell)]
end
local function mark(cell)
  if not call("cells","isDug",cell.x,cell.y,cell.z,cell.dim) then
    call("cells", "markDug", cell.x, cell.y, cell.z, cell.dim)
  end
  S.known[M.key(cell)] = false
end
local function cleanupAction(row)
  local key = M.key(row.pose)
  local blocked = row.cleanupBlocked
  if type(blocked) ~= "table" or blocked.pose ~= key then blocked = {pose=key} row.cleanupBlocked=blocked end
  local candidates = {
    {side="down",cell=M.cell(row.pose,"down")},
    {side="up",cell=M.cell(row.pose,"up")},
  }
  for f=0,3 do
    local pose=SO.store.copy(row.pose) pose.facing=f
    candidates[#candidates+1]={side="front",cell=M.cell(pose,"forward"),facing=f}
  end
  local target
  for _, candidate in ipairs(candidates) do
    if not blocked[M.key(candidate.cell)] then
      target=target or candidate
      if lookup(candidate.cell)==false then target=candidate break end
    end
  end
  if not target then return nil end
  local turn=target.facing and M.turn(row.pose,target.facing)
  if turn then return {kind="turn",steps={turn},cells={},pose=P.apply(row.pose,turn.op)} end
  return {kind="cleanup",steps=M.cleanup(row.inv,false,target.side),cells={},cell=target.cell}
end
local function reservePose(id, row)
  local p = row.pose
  if call("cells","owner",p.x,p.y,p.z,p.dim)==owner(id) then return true end
  local ok, err = call("cells", "reserve", owner(id), p.x, p.y, p.z, p.dim)
  if not ok then row.error = err or "standing cell unavailable" end
  return ok
end
local function park(id, row, recover)
  if recover or row.state ~= "wait lane" then row.laneWait = nil end
  if not recover and row.parkUntil and SO.now() < row.parkUntil - 60000 then return end
  local lid, err = call("lease", "send", id, P.park.steps, { owner = "mine", recover = recover, ms = P.park.ms, pose = row.pose })
  if lid then S.pending[id] = { kind = recover and "recover" or "park" } row.parkUntil = SO.now() + P.park.ms
  else row.error = err end
end
local function scan(row, vein)
  row.scan = { index = job.mode == "fast" and not vein and 5 or 1, facing = row.pose.facing }
end
local function dropFailure(id, row, kind, point)
  local key = point and point.id or ("hold:" .. kind)
  local retry = row.dropRetry
  if not retry or retry.key ~= key then retry = { key = key, tries = 0 } row.dropRetry = retry end
  retry.tries = retry.tries + 1
  if retry.tries >= 3 then
    if not retry.alerted then
      emit("mine.alert", { id = id, text = kind == "ore" and "ore chest full" or "fuel chest empty" })
      retry.alerted = true
    end
    row.laneWait = nil
    row.state, row.error = "hold", kind == "ore" and "ore chest full" or "fuel chest empty"
    retry.after = SO.now() + 60000
  end
end
local function homeRoute(row)
  local key = M.key(row.pose)
  local cached = S.homeRoutes[row]
  if cached and cached.key == key and cached.index == row.index and cached.route == row.route
      and cached.home == job.home and cached.bottom == job.bottom and cached.dim == job.dim then return cached end
  local path, access = M.supplyRoute(job,row,job.home,nil,lookup)
  -- No remembered route: a re-add underground, or the lookup is empty after a
  -- restart. Below the surface, plan the direct way down to the mine level and
  -- along the spine; trips without access dig the same path.
  if not path and row.pose.y < job.home.y then path = M.supplyRoute(job,{pose=row.pose},job.home) end
  cached = {key=key,index=row.index,route=row.route,home=job.home,bottom=job.bottom,dim=job.dim,
    reserve=path and #path-1+64 or math.huge,
    row={pose=row.pose,route=row.route,index=row.index,access=access}}
  S.homeRoutes[row] = cached
  return cached
end
local function fuelReserve(row)
  return homeRoute(row).reserve
end
local function tripReserve(t)
  local back = {pose=t.back}
  return (t.path and #t.path-1 or M.supplyDistance(job,back,t.stand))
    + (t.reserve or fuelReserve(back))
end
local function trip(id, row, kind)
  local near = SO.store.copy(row.pose)
  near.dim = ({ ["minecraft:overworld"] = 0, ["minecraft:the_nether"] = -1, ["minecraft:the_end"] = 1 })[job.dim]
  if near.dim == nil then row.error = "drop dimension unsupported" return false end
  local picked = call("drops", "pick", kind, near)
  if not picked or not picked.point then
    dropFailure(id, row, kind)
    row.error = picked and picked.alert or "drops: hold " .. kind
    row.state = "hold" row.laneWait = nil
    if row.dropRetry.alerted then row.error = row.error .. " " .. (kind == "ore" and "ore chest full" or "fuel chest empty") end
    save()
    return false
  end
  local point = SO.store.copy(picked.point)
  point.dim = job.dim
  local route = homeRoute(row)
  if route.reserve == math.huge then row.error = "no known mine route" return false end
  local candidates = {}
  if point.side == "down" then candidates[1] = { dim = job.dim, x = point.x, y = point.y+1, z = point.z }
  else
    for f = 0, 3 do
      local p = { dim = job.dim, x = point.x, y = point.y, z = point.z, facing = f }
      local c = M.cell(p, "back") c.facing = f candidates[#candidates+1] = c
    end
    table.sort(candidates, function(a,b) return M.supplyDistance(job,route.row,a) < M.supplyDistance(job,route.row,b) end)
  end
  for _, stand in ipairs(candidates) do
    local held = call("cells", "owner", stand.x, stand.y, stand.z, stand.dim)
    local known = S.known[M.key(stand)]
    if (not held or held == owner(id)) and (known == nil or known == false) then
      local path = M.supplyRoute(job,route.row,stand,point)
      if path then
        local shared=false
        for _,cell in ipairs(path) do if M.inLane(job,cell) then shared=true break end end
        row.trip = { kind = kind, point = point, stand = stand, back = SO.store.copy(row.pose), stage = "out", path = path, reserve = route.reserve, shared = shared }
        row.state = kind row.laneWait = nil return true
      end
    end
  end
  row.error = "drop neighbours held or no mine route" return false
end
local function laneOrder(a,b)
  local x,y=job.turtles[tostring(a)].laneWait,job.turtles[tostring(b)].laneWait
  local xp,yp=x and x.passes or 0,y and y.passes or 0
  if (xp>=3)~=(yp>=3) then return xp>=3 end
  local xt,yt=x and x.at or math.huge,y and y.at or math.huge
  if xt~=yt then return xt<yt end
  return a<b
end
local function releaseBatch(id,row)
  if row.lane then
    if M.inLane(job,row.pose) then row.lane.entered=true
    elseif row.lane.entered and not row.trip then
      row.lane.release=true
      reservePose(id,row)
      return
    end
  end
  local keep={[M.key(row.pose)]=true}
  for _,cell in ipairs(row.lane and row.lane.cells or {}) do keep[M.key(cell)]=true end
  for _,cell in ipairs(call("cells","list",owner(id),100000) or {}) do
    if not keep[M.key(cell)] then call("cells","release",owner(id),cell.x,cell.y,cell.z,cell.dim) end
  end
  reservePose(id,row)
end
local function reserveBatch(id,row,action)
  local needs=M.inLane(job,row.pose)
  if action.kind~="scan" then
    for _,cell in ipairs(action.cells or {}) do needs=needs or M.inLane(job,cell) end
  end
  if not needs then row.laneWait=nil end
  local cells,seen={},{}
  local function add(cell)
    local key=M.key(cell)
    if not seen[key] then cells[#cells+1]=cell seen[key]=true end
  end
  for _,cell in ipairs(action.cells or {}) do add(cell) end
  local leaving=row.yield and row.yield.stage=="out"
  local pass=needs and (row.yield and (leaving and row.yield.path or row.yield.pass) or M.lanePass(job,row)) or {}
  if needs and not row.lane then
    row.laneWait=row.laneWait or {at=SO.now(),passes=0}
    local first=id
    for other,peer in pairs(job.turtles) do
      local parked=peer.yield and peer.yield.stage=="wait"
      if tonumber(other)~=id and (peer.lane or M.inLane(job,peer.pose) and not parked) then return false,"held" end
      if not leaving and peer.laneWait and laneOrder(tonumber(other),first) then first=tonumber(other) end
    end
    if first~=id then return false,"held" end
    for _,cell in ipairs(pass) do add(cell) end
  elseif row.lane then
    for _,cell in ipairs(pass) do
      if call("cells","owner",cell.x,cell.y,cell.z,cell.dim)~=owner(id) then add(cell) end
    end
  end
  local held=true
  for _,cell in ipairs(cells) do
    if call("cells","owner",cell.x,cell.y,cell.z,cell.dim)~=owner(id) then held=false break end
  end
  if not held then
    local ok,err=call("cells","reserveMany",owner(id),cells)
    if not ok then return false,err end
  end
  if needs and not row.lane then
    local vein=row.veins and row.veins[#row.veins]
    row.lane={cells=pass,entered=M.inLane(job,row.pose),
      target=vein and row.goal and M.same(vein,row.goal) and SO.store.copy(vein) or nil}
    row.laneWait=nil
    for other,peer in pairs(job.turtles) do
      if tonumber(other)~=id and peer.laneWait then peer.laneWait.passes=peer.laneWait.passes+1 end
    end
  elseif row.lane then
    local retained={}
    for _,cell in ipairs(row.lane.cells) do retained[M.key(cell)]=true end
    for _,cell in ipairs(pass) do
      if not retained[M.key(cell)] then row.lane.cells[#row.lane.cells+1]=cell retained[M.key(cell)]=true end
    end
  end
  return true
end
local function releaseLane(id,row)
  call("cells","releaseOwner",owner(id))
  row.lane,row.laneWait=nil,nil
  reservePose(id,row)
  S.handoffAt=SO.now()
end
local function yieldPath(id,row,returnMoves)
  local queue,head,seen,parents={row.pose},1,{[M.key(row.pose)]=true},{}
  while queue[head] and head<=512 do
    local p=queue[head] head=head+1
    if not M.inLane(job,p) then
      local path={p}
      while parents[M.key(p)] do p=parents[M.key(p)] table.insert(path,1,p) end
      if type(row.fuel)~="number" or row.fuel<0 or row.fuel>=2*(#path-1)+(returnMoves or 0) then return path end
      return nil
    end
    for _,dir in ipairs({"forward","back","up","down","right","left"}) do
      local pose=p
      if dir=="right" or dir=="left" then
        pose=P.apply(p,dir=="right" and "turnRight" or "turnLeft") dir="forward"
      end
      local cell=M.cell(pose,dir)
      local key,held=M.key(cell),call("cells","owner",cell.x,cell.y,cell.z,cell.dim)
      if not seen[key] and lookup(cell)==false and (not held or held==owner(id))
          and P.inRange(mod("lease"),id,{cell}) then
        seen[key],parents[key]=true,p queue[#queue+1]=cell
      end
    end
  end
end
local function beginYield(id,row)
  row.laneWait=nil
  local path=yieldPath(id,row) or {row.pose}
  row.yield={path=path,cursor=2,stage="out",state=row.state,error=row.error,
    action=row.blockedAction,pass=SO.store.copy(row.lane and row.lane.cells or M.lanePass(job,row)),
    after=row.dropRetry and (row.dropRetry.after or 0) or SO.now()+60000}
  for _,cell in ipairs(path) do row.yield.pass[#row.yield.pass+1]=cell end
end
local function rerouteYield(id,row,action)
  local y=row.yield
  for _,cell in ipairs(action.cells or {}) do S.known[M.key(cell)]=nil end
  local prefix={}
  for _,cell in ipairs(y.path) do
    prefix[#prefix+1]=cell
    if M.same(cell,row.pose) then break end
  end
  local path=#(action.cells or {})>0 and yieldPath(id,row,#prefix-1)
  y.path,y.cursor=prefix,#prefix+1
  if y.stage=="back" then y.retryAfter=SO.now()+60000 end
  y.stage="out"
  for i=2,#(path or {}) do
    y.path[#y.path+1]=path[i] y.pass[#y.pass+1]=path[i]
  end
end
local plan
local function report(_, id, results, lease)
  local row = job.turtles[tostring(id)]
  if not row then return end
  local action, interrupted = S.pending[id], row.inflight
  S.pending[id] = nil
  if not results or not lease.report or not lease.report.pose then
    row.state, row.error, row.recover = "lost", "lease expired or missing pose", true row.laneWait=nil save() return
  end
  row.inflight = nil
  local facts = lease.report
  if not row.frame then row.frame = P.frame(row.anchor, facts.pose) end
  local old = row.pose
  row.pose = P.toWorld(row.frame, facts.pose)
  row.inv, row.fuel = facts.inv or row.inv or {}, facts.fuel or row.fuel
  local priorDug,nextDug=S.dugFacts[id] or {},{}
  local history = {}
  for _, c in ipairs(facts.dug or {}) do
    local world = P.toWorld(row.frame, { x = c.x, y = c.y, z = c.z, f = 0 })
    history[#history + 1] = world
    if action and action.kind == "recover" and interrupted and interrupted.kind == "dig"
        and M.same(world, interrupted.cell)
        and not call("cells", "isDug", world.x, world.y, world.z, world.dim) then
      row.dug = (row.dug or 0) + 1
      if interrupted.ore then
        row.ores, row.veinCount = (row.ores or 0) + 1, (row.veinCount or 0) + 1
        emit("mine.ore", { id = id, name = interrupted.ore, count = 1 })
        row.scanAfter = true
        if row.veinCount >= 64 then row.veins = { world } end
      end
      interrupted = nil
    end
    local key=M.key(world)
    if not priorDug[key] then mark(world) end
    nextDug[key]=true
  end
  if facts.dug then
    S.dugFacts[id]=nextDug
    call("cells", "rememberWorker", id, row.pose, history)
  end
  if action then
    local batchResults, cursor, batched = results, old, action.actions ~= nil
    for _, part in ipairs(action.actions or { action }) do
      action = part
      results = {}
      for i = 1, #(action.steps or batchResults) do results[i] = batchResults[(action.first or 1) + i - 1] end
      if batched and action.cell then
        local op = action.steps[1].op
        local dir = op:find("Up",1,true) and "up" or op:find("Down",1,true) and "down" or op == "up" and "up" or op == "down" and "down" or "forward"
        action.cell = M.cell(cursor, dir)
      end
      cursor = P.replay(cursor, action.steps or {}, results)
      if row.lane and M.inLane(job,cursor) then row.lane.entered=true end
      if action.kind == "recover" then row.recover, row.error = false, nil row.state = job.running and "mining" or "stopped"
      elseif action.kind == "inspect" or action.kind == "scan" then
        local result = results[#results]
        S.known[M.key(action.cell)] = result.ok and result.data or false
        if action.kind == "scan" then
          row.scan.index = row.scan.index + 1
          if result.ok and result.data and (result.data.name == "minecraft:lava" or result.data.name == "minecraft:water") then row.fluid = action.cell end
          if result.ok and M.ore(result.data, job.ores) and not call("cells", "isDug", action.cell.x, action.cell.y, action.cell.z, job.dim)
            and (row.veinCount or 0) < 64 then
            row.veins = row.veins or {}
            local duplicate = false
            for _, v in ipairs(row.veins) do if M.same(v, action.cell) then duplicate = true end end
            if not duplicate then row.veins[#row.veins+1] = action.cell end
          end
        end
      elseif action.kind == "dig" then
        if results[1].ok then
          mark(action.cell) row.dug = (row.dug or 0) + 1
          if action.ore then row.ores = (row.ores or 0)+1 row.veinCount = (row.veinCount or 0)+1 emit("mine.ore", { id = id, name = action.ore, count = 1 }) row.scanAfter = true
            if row.veinCount >= 64 then row.veins = { action.cell } end
          end
        else S.known[M.key(action.cell)] = nil row.error = results[1].err end
      elseif action.kind == "seal" then S.known[M.key(action.cell)] = nil
      elseif action.kind == "move" then
        if results[1].ok then
          S.known[M.key(action.cell)] = false
          S.known[M.key(old)] = false
          scan(row, row.scanAfter)
          row.scanAfter = nil
        else S.known[M.key(action.cell)] = nil row.error = results[1].err end
      elseif action.kind == "yield" and row.yield then
        for _,result in ipairs(results) do
          if not result.ok then rerouteYield(id,row,action) break end
        end
      elseif action.kind == "cleanup" then
        row.cleanup = #M.cleanup(row.inv,false) > 0
        for i, step in ipairs(action.steps) do
          if step.op == "discard" and not results[i].ok then
            row.cleanupBlocked[M.key(action.cell)] = true
          end
        end
        if not row.cleanup then row.cleaned = row.dug or 0 end
      elseif action.kind == "unload" or action.kind == "refuel" then
        local failed = false
        for i, step in ipairs(action.steps) do
          local result = results[i]
          if step.op == "inspect" or step.op == "inspectDown" then
            if not result.ok then call("drops", "note", row.trip.point.id, nil) end
          elseif step.op == "drop" or step.op == "dropDown" or step.op == "suck" or step.op == "suckDown" then
            if not result.ok then failed = true end
          end
        end
        local enough = action.kind == "refuel" and type(row.fuel) == "number"
          and (row.fuel < 0 or row.fuel >= tripReserve(row.trip))
        if failed and enough then
          row.trip.stage = "back"
          row.state, row.dropRetry, row.error = "fuel", nil, nil
        elseif failed then dropFailure(id, row, row.trip.kind, row.trip.point)
        else row.dropRetry, row.error = nil, nil end
        if action.kind == "unload" then row.trip.stage = "out"
        elseif type(row.fuel) == "number" and row.fuel >= math.max(2000,tripReserve(row.trip)) then row.trip.stage = "back" end
      end
    end
  end
  releaseBatch(id,row)
  if not M.same(old, row.pose) then row.lastMove = SO.now() end
  save()
  local now=SO.now()
  if not S.burst.at or now-S.burst.at>50 then S.burst.n=0 end
  S.burst.at,S.burst.n=now,S.burst.n+1
  local limit,workers,lane=4,0,false
  for _,peer in pairs(job.turtles) do workers=workers+1 lane=lane or peer.lane~=nil end
  if lane and workers>1 then limit=2 end
  if action and action.kind~="park" and action.kind~="recover" and (not row.trip or row.trip.shared==false) and job.running and S.burst.n<limit
      and (not S.handoffAt or now-S.handoffAt>50) then plan(id,row) end
end
local function send(id, row, action)
  if #action.steps == 0 then return false end
  local proposed=action
  action = P.rangeBatch(mod("lease"), id, action)
  if not action then
    row.state,row.error,row.blockedAction="range","outside proven radio range",proposed
    row.laneWait=nil
    return false
  end
  if not row.yield then row.blockedAction=nil end
  local ok, err = reserveBatch(id,row,action)
  if not ok then
    row.state, row.error = row.laneWait and "wait lane" or "waiting", err or "cells unavailable"
    return false
  end
  row.inflight = action
  if not save() then row.inflight = nil return false end
  local lid, why = call("lease", "send", id, action.steps, { owner = "mine", pose = action.pose or row.pose, ms = 60000 })
  if not lid then row.inflight = nil row.error = why return false end
  row.parkUntil = nil
  S.pending[id] = action return true
end
local function yieldLane(id,row)
  local y=row.yield
  row.state,row.error=y.state,y.error
  local target=y.path[y.cursor]
  if target and M.same(row.pose,target) then
    y.cursor=y.cursor+(y.stage=="back" and -1 or 1)
    target=y.path[y.cursor]
  end
  if y.stage=="out" and not target then
    y.stage,y.cursor="wait",#y.path-1
    releaseLane(id,row) save()
  end
  if y.stage=="wait" then
    row.laneWait=nil
    local ready=y.action and P.rangeBatch(mod("lease"),id,y.action)
      or not y.action and SO.now()>=y.after
    local fuel=type(row.fuel)~="number" or row.fuel<0 or row.fuel>=#y.path-1
    if not ready or not fuel or not job.running or SO.now()<(y.retryAfter or 0) then
      park(id,row,false) return true
    end
    y.stage="back" target=y.path[y.cursor]
  end
  if y.stage=="back" and not target then
    local turn=M.turn(row.pose,y.path[1].facing)
    if turn then send(id,row,{kind="yield",steps={turn},cells={},pose=P.apply(row.pose,turn.op)}) return true end
    row.yield,row.blockedAction=nil,nil
    save()
    return false
  end
  if target then
    local action=P.path(row.pose,target)
    action.kind="yield"
    if not send(id,row,action) then park(id,row,false) end
  end
  return true
end
local function scanAction(row)
  local n = row.scan.index
  if n > 6 then row.scan = nil return nil end
  local want = (row.scan.facing + math.min(n-1,3)) % 4
  if n <= 4 then
    local turn = M.turn(row.pose,want)
    if turn then return { kind = "turn", steps = {turn}, cells = {}, pose = P.apply(row.pose,turn.op) } end
  end
  local dir = n == 5 and "up" or n == 6 and "down" or "forward"
  local c = M.cell(row.pose,dir)
  return { kind = "scan", cell = c, cells = {c}, steps = { {op = n == 5 and "inspectUp" or n == 6 and "inspectDown" or "inspect"} } }
end
plan = function(id,row)
  local status = call("lease", "status", id)
  if not status then return end
  if status.uncertain then
    row.state, row.error = "hold", "pose uncertain: re-add turtle " .. id
    row.laneWait=nil
    return
  end
  if status.lost then row.state, row.error, row.recover = "lost", "worker beacon", true row.laneWait=nil end
  if status.open then return end
  if status.lost or row.recover then
    row.state = "lost" row.recover = true park(id,row,true) return
  end
  if not row.frame then row.recover = true park(id,row,true) return end
  if row.lane and row.lane.release then return end
  if not row.yield and (row.state=="range" or row.state=="hold")
      and (row.lane or M.inLane(job,row.pose)) then beginYield(id,row) save() end
  if row.yield and yieldLane(id,row) then return end
  if not reservePose(id,row) then row.state = "waiting" park(id,row,false) return end
  if not P.inRange(mod("lease"),id,{row.pose}) then row.state,row.error="range","outside proven radio range" park(id,row,false) return end
  if not job.running or row.state == "done" then row.state = row.state == "done" and "done" or "stopped" park(id,row,false) return end
  if row.dropRetry and row.dropRetry.after and SO.now() < row.dropRetry.after then
    park(id,row,false) return
  end
  row.inv = row.inv or {}
  local clean = M.cleanup(row.inv,false)
  if not row.trip and #clean > 0 and (row.cleanup or (row.dug or 0)-(row.cleaned or 0)>=10 or P.free(row.inv)<2) then
    local action=cleanupAction(row)
    if action then send(id,row,action) return end
  end
  if not row.trip then
    local low = type(row.fuel)=="number" and row.fuel >= 0 and row.fuel < fuelReserve(row)
    if low or P.free(row.inv)<2 then if not trip(id,row,P.free(row.inv)<2 and "ore" or "fuel") then park(id,row,false) return end end
  end
  if row.trip then
    local t = row.trip
    row.goal = t.stage == "back" and t.back or t.stand
    if M.same(row.pose,row.goal) then
      if t.stage == "back" then
        local turn = M.turn(row.pose,t.back.facing)
        if turn then send(id,row,{kind="turn",steps={turn},cells={},pose=P.apply(row.pose,turn.op)}) return end
        row.trip, row.goal = nil,nil row.state="mining"
        if row.resumeTrip then
          row.trip, row.resumeTrip = row.resumeTrip, nil
          save()
          return
        end
        releaseBatch(id,row)
        if row.lane and row.lane.release then save() return end
      elseif t.point.side == "front" and row.pose.facing ~= t.stand.facing then
        local turn = M.turn(row.pose,t.stand.facing)
        send(id,row,{kind="turn",steps={turn},cells={},pose=P.apply(row.pose,turn.op)}) return
      elseif t.kind == "ore" then
        local steps = {}
        for _, item in ipairs(row.inv) do
          if not M.junk(item) and not unloadKeep[item.name] then
            steps[#steps+1]={op="select",slot=item.slot}
            local drop = call("drops","steps",t.point) or {}
            for _, step in ipairs(drop) do steps[#steps+1]=step end
            break
          end
        end
        if #steps==0 then t.stage="back" else send(id,row,{kind="unload",steps=steps,cells={}}) return end
      else
        local steps = {}
        for _, item in ipairs(row.inv) do
          local value = P.fuelValue(item.name)
          if value>0 then steps={{op="select",slot=item.slot},{op="refuel",n=math.min(item.count,math.max(1,math.ceil((math.max(2000,tripReserve(t))-(row.fuel or 0))/value)))}} break end
        end
        if #steps==0 then
          local occupied={} for _, item in ipairs(row.inv) do occupied[item.slot]=true end
          local slot for i=1,16 do if not occupied[i] then slot=i break end end
          if not slot then
            row.trip = nil
            if trip(id,row,"ore") then row.resumeTrip = t
            else row.trip = t park(id,row,false) end
            save()
            return
          end
          steps={{op=t.point.side=="down" and "inspectDown" or "inspect"},{op="select",slot=slot},{op=t.point.side=="down" and "suckDown" or "suck",n=64}}
        end
        send(id,row,{kind="refuel",steps=steps,cells={}}) return
      end
    end
    if row.trip then
      local action = M.next(job,row,lookup,row.inv,row.fuel)
      if action.kind == "hold" then row.state, row.error = "hold", action.error end
      if not send(id,row,action) then park(id,row,false) end
      return
    end
  end
  if row.fluid and not M.inLane(job,row.pose) then
    local target = row.fluid
    local known = S.known[M.key(target)]
    if known ~= nil and (known == false or (known.name ~= "minecraft:lava" and known.name ~= "minecraft:water")) then row.fluid=nil
    else
      local prior = row.goal row.goal=target
      local action=M.next(job,row,function(c) return S.known[M.key(c)] end,row.inv,row.fuel)
      row.goal=prior
      if action.kind=="hold" then row.error=action.error row.state="hold" park(id,row,false)
      elseif not send(id,row,action) then park(id,row,false) end
      return
    end
  end
  if row.scan then
    local action=scanAction(row)
    if action then
      if action.cell and M.inLane(job,action.cell) and not row.lane then
        row.scan.index=row.scan.index+1 save() return
      end
      if not send(id,row,action) then
        local held=action.cell and call("cells","owner",action.cell.x,action.cell.y,action.cell.z,job.dim)
        if held and held~=owner(id) then row.scan.index=row.scan.index+1 save()
        else park(id,row,false) end
      end
      return
    end
  end
  while row.veins and row.veins[#row.veins] do
    local cell=row.veins[#row.veins]
    if row.goal and M.same(cell,row.goal) or not call("cells","isDug",cell.x,cell.y,cell.z,job.dim) then break end
    table.remove(row.veins)
  end
  if row.veins and #row.veins>0 and (not M.inLane(job,row.pose) or row.lane and row.lane.target) then
    row.goal=row.veins[#row.veins]
    if M.same(row.pose,row.goal) then table.remove(row.veins) row.goal=nil scan(row,true) save() return end
  else
    row.veinCount = 0
    if not row.route then
      local branch=job.progress.nextBranch or 0 job.progress.nextBranch=branch+1
      row.branch, row.route, row.index=branch,M.route(job,branch),1
      row.veinCount = 0
    end
    -- A worker added below the surface joins its route at the nearest tunnel
    -- cell rather than climbing a new column to the shaft top.
    if row.index==1 and row.pose.y<row.route[1].y then
      row.index=2
      for i=3,#row.route do
        if M.distance(row.pose,row.route[i])<M.distance(row.pose,row.route[row.index]) then row.index=i end
      end
    end
    while row.route[row.index] and M.same(row.pose,row.route[row.index]) do row.index=row.index+1 end
    row.goal=row.route[row.index]
    -- A finished worker recovered elsewhere (moved by hand, or backed along
    -- its path by a worker from before #146) returns to its branch end, so it
    -- does not park in a column or lane that other workers travel through.
    local last=row.route[#row.route]
    if not row.goal and last and not M.same(row.pose,last) then row.goal=last end
    if not row.goal then
      for _, item in ipairs(row.inv) do
        if not M.junk(item) and not unloadKeep[item.name] and P.fuelValue(item.name) == 0 then
          if trip(id,row,"ore") then save() plan(id,row)
          else park(id,row,false) end
          return
        end
      end
      row.state="done"
      -- Recovery sets a finished row back to mining; count each branch once.
      if row.counted~=row.branch then
        row.counted=row.branch job.progress.done=(job.progress.done or 0)+1
        emit("mine.progress",{level=job.bottom,branch=row.branch,done=job.progress.done})
      end
      save() park(id,row,false) return
    end
  end
  row.state="mining"
  local action=M.next(job,row,lookup,row.inv,row.fuel)
  if action.kind=="hold" then row.error=action.error row.state="hold" park(id,row,false)
  elseif not send(id,row,action) then park(id,row,false) end
end
local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local defaultView = { page = "main" }
local function view(session)
  if not U or type(session) ~= "table" then return defaultView end
  session.mining = session.mining or { page = "main" }
  return session.mining
end
-- Route A screen (docs/ui/SCHEMATIC-SPEC.md); docs/ui/schematic/jobs.py is the twin of V.gather
-- and the layouts and writes their fixtures.
local V = { ores = { "coal", "copper", "iron", "gold", "redstone", "lapis", "diamond" },
  tabs = { "overview", "setup" }, short = { "main", "setup" }, dirs = { [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } } }
V.oreOn = function(m, name)
  if #m.ores == 0 then return true end
  for _, ore in ipairs(m.ores) do if ore == name then return true end end
  return false
end
-- A tapped control as the text command that makes the same change, or nil.
V.command = function(id)
  if id == "set-bottom-" or id == "set-bottom+" then return "bottom " .. (job.bottom + (id == "set-bottom+" and 1 or -1)) end
  if id == "set-length-" or id == "set-length+" then
    return "length " .. math.max(1, math.min(4096, job.length + (id == "set-length+" and 8 or -8)))
  end
  local mode = id:match("^mode%-(%a+)$")
  if mode then return "mode " .. mode end
  local ore = id:match("^ore%-(%a+)$")
  if not ore or not M.ores[ore] then return end
  local on = {}
  for _, name in ipairs(V.ores) do
    if V.oreOn({ ores = job.ores }, name) ~= (name == ore) then on[#on + 1] = name end
  end
  if #on > 0 then return "ores " .. table.concat(on, ",") end
end
-- Job facts, one row per turtle placed on the job diagram, and the dug extent of every branch.
V.gather = function()
  local h = job.home
  local d, r = V.dirs[h.facing], V.dirs[(h.facing + 1) % 4]
  local tx, tz = h.x + d[1], h.z + d[2]
  local gap, length, bottom = job.mode == "fast" and 2 or 4, job.length, job.bottom
  local total, ids = job.progress.nextBranch or 0, {}
  for id, row in pairs(job.turtles) do
    ids[#ids + 1] = tonumber(id)
    total = math.max(total, (row.branch or -1) + 1)
  end
  table.sort(ids)
  local today = call("daily", "today")
  local m = { state = job.running and "running" or "stopped", alert = S.error, length = length, gap = gap,
    bottom = bottom, done = job.progress.done or 0, total = total, extents = {}, turtles = {}, busy = 0,
    workers = 0, ore = today and today.ore, home = h, homeSet = job.homeSet ~= false, mode = job.mode, ores = job.ores }
  for b = 1, total do m.extents[b] = length end
  for _, n in ipairs(ids) do
    local row = job.turtles[tostring(n)]
    local p = row.pose or row.anchor or h
    local status = call("lease", "status", n) or {}
    local word = status.lost and "lost" or row.laneWait and "wait lane" or tostring(row.state)
    local t = { id = n, facing = ((p.facing or h.facing) - h.facing) % 4, world = p.facing, state = word, tone = U.tone(word),
      where = row.lane and "lane" or row.branch and "b" .. (row.branch + 1) or "-", at = p.x .. "," .. p.y .. "," .. p.z,
      fuel = type(row.fuel) == "number" and row.fuel or nil, ore = row.ores or 0, lost = status.lost and true or false,
      spine = false, along = 0 }
    local k = (p.x - tx) * d[1] + (p.z - tz) * d[2]
    local along = (p.x - tx) * r[1] + (p.z - tz) * r[2]
    local near = math.floor((2 * k + gap) / (2 * gap))
    if row.lane then
      t.spine, t.row = true, p.y == bottom and math.max(0, math.min(total, near)) or 0
    elseif math.abs(p.y - bottom) <= 1 and k > 0 and along > 0 and near >= 1 and near <= total then
      t.row, t.along = near, math.min(along, length)
    end
    local b = row.branch
    if b and b >= 0 and b < total and row.state ~= "done" then
      if t.row == b + 1 and not t.spine then m.extents[b + 1] = t.along
      elseif row.route and row.index then m.extents[b + 1] = math.max(0, math.min(length, row.index - 3 - (b + 1) * gap))
      else m.extents[b + 1] = 0 end
    end
    m.turtles[#m.turtles + 1] = t
    m.workers = m.workers + 1
    if t.tone == "d" then m.busy = m.busy + 1 end
    if row.lane and not m.lane then m.lane = t end
    if t.fuel and (not m.fuel or t.fuel < m.fuel.value) then m.fuel = { value = t.fuel, id = n } end
    if not m.alert and row.error then m.alert = row.error end
  end
  return m
end
V.facts = function(m)
  local lane, fuel = m.lane, m.fuel
  return { { "busy", m.busy .. "/" .. m.workers, "0" }, { "lane", lane and "#" .. lane.id or "-", lane and "b" or "8" },
    { "depth", tostring(m.bottom), "0" }, { "done", m.done .. "/" .. m.total, "0" },
    { "ore", m.ore and tostring(m.ore) or "-", m.ore and "0" or "8" },
    { "fuel", fuel and tostring(fuel.value) or "-", fuel and (fuel.value < 500 and "1" or "0") or "8" } }
end
V.fg = function(tone) return (tone == "1" or tone == "e" or tone == "8") and tone or "0" end
V.run = function(C, y, m, gap)
  local run = m.state == "running"
  U.actions(C, y, { { "START", "start", run and "muted" or "primary" }, { "STOP", "stop", run and "stop" or "muted" } }, gap)
end
-- One row per branch, newest at the top: number, spine, dug '-' and planned dots, the turtles.
V.diagram = function(C, m, top, avail, right)
  local sp, total, length = 5, m.total, m.length
  local cols = math.max(1, math.min(right - sp - 9, length))
  local shown = math.max(0, math.min(total, avail))
  local first, fg, marks = total - shown + 1, m.lane and "b" or "3", {}
  for i = 0, shown - 1 do
    local b, y = total - i, top + i
    C.put(math.max(1, sp - 2 - #tostring(b)), y, tostring(b), "8")
    C.put(sp, y, "+", fg)
    for k = 1, cols do
      local dug = k * length <= m.extents[b] * cols
      C.put(sp + k, y, dug and "-" or U.g.dot, dug and "3" or "8")
    end
  end
  local base = top + shown
  C.put(sp, base, "|", fg)
  C.put(sp, base + 1, U.g.shaft, "9")
  C.put(sp + 2, base + 1, "shaft", "8")
  for _, t in ipairs(m.turtles) do
    if t.row then
      local y = t.row >= first and top + total - t.row or base
      if t.spine then
        C.put(sp - #tostring(t.id), y, tostring(t.id), t.tone)
        marks[#marks + 1] = { sp, y, t, false }
      elseif t.row >= first then
        local i = math.max(1, math.min(cols, math.floor(t.along * cols / length)))
        local held = i < cols and t.tone ~= "e"
        local label = t.tone == "d" and tostring(t.id) or t.id .. " " .. t.state:match("^%S*")
        local x = sp + i + 2 + (held and 1 or 0)
        C.put(x, y, label:sub(1, math.max(0, right - x + 1)), t.tone)
        marks[#marks + 1] = { sp + i, y, t, held }
      end
    end
  end
  for _, mk in ipairs(marks) do
    if mk[4] then C.put(mk[1] + 1, mk[2], "-", "b") end
    C.put(mk[1], mk[2], U.arrow(mk[3].facing), mk[3].tone)
  end
end
-- TURTLES with fuel and ore from column 2 to right: the section on row top, then nt rows.
V.turtles = function(C, m, top, nt, right)
  local ts = m.turtles
  if #ts == 0 then return end
  C.section(2, top, right - 1, "TURTLES", "fuel  ore")
  for i = 1, nt do
    local y, t = top + i, ts[i]
    if i == nt and #ts > nt then C.put(4, y, "+" .. (#ts - i + 1) .. " more", "8") break end
    C.put(2, y, U.arrow(t.facing), t.tone)
    C.put(4, y, tostring(t.id), "0")
    C.put(7, y, t.state:sub(1, 10), V.fg(t.tone))
    C.put(18, y, t.where:sub(1, 5), "8")
    C.put(24, y, t.at:sub(1, math.max(0, right - 36)), t.lost and "e" or "8")
    local fuel = t.fuel and tostring(t.fuel) or "-"
    C.put(right - 5 - #fuel, y, fuel, not t.fuel and "8" or t.fuel < 500 and "1" or "0")
    C.put(right - #tostring(t.ore), y, tostring(t.ore), "0")
  end
end
V.room = function(C, m)
  local w, ya = C.w, C.h - 1
  U.roleBar(C, "MINING", V.tabs, V.short, 1, m.state, U.tone(m.state))
  -- The diagram draws at most one cell per block; the facts and the table follow it on wide walls.
  local lx = math.min(w - 11, math.max(1, math.min(w - 27, m.length)) + 18)
  for i, f in ipairs(V.facts(m)) do C.leader(lx, 2 + i, 11, f[1], f[2], f[3]) end
  V.run(C, ya, m, 3)
  if m.alert then C.flag(2, ya - 2, w - 2, m.alert) end
  -- Caps keep the biggest walls inside the 16 KB frame: 12 turtle rows, 24 branch rows.
  local nt = math.min(#m.turtles, math.max(0, ya - 12), 12)
  local shown = math.min(m.total, ya - 3 - nt - (nt > 0 and 1 or 0) - 5, 24)
  V.diagram(C, m, 3, shown, lx - 2)
  V.turtles(C, m, 3 + shown + 3, nt, lx + 10)
end
V.column = function(C, m)
  local w, ya = C.w, C.h
  local shown = U.roleBar(C, "MINING", V.tabs, V.short, 1, m.state, U.tone(m.state))
  V.run(C, ya, m, 1)
  if m.alert then C.flag(2, ya - 1, w - 2, m.alert) end
  local f, last, top = V.facts(m), ya - 2 - (m.alert and 1 or 0)
  if w < 30 then
    local rows = { f[1], f[2], f[4], f[6] }
    if not shown then table.insert(rows, 1, { "state", m.state, V.fg(U.tone(m.state)) }) end
    top = last - #rows + 1
    for i, row in ipairs(rows) do C.leader(2, top + i - 1, w - 2, row[1], row[2], row[3]) end
  else
    local lw = math.floor((w - 5) / 2)
    top = last - 2
    for i = 1, 3 do
      C.leader(2, top + i - 1, lw, f[i][1], f[i][2], f[i][3])
      C.leader(lw + 5, top + i - 1, w - lw - 5, f[i + 3][1], f[i + 3][2], f[i + 3][3])
    end
  end
  V.diagram(C, m, 3, top - 6, w - 1)
end
-- Tabs from 24 columns; below that the role name and the state word when it fits.
V.tinyBar = function(C, name, m)
  if C.w >= 24 then return U.roleBar(C, name, V.tabs, V.short, 1, m.state, U.tone(m.state)) end
  local right = C.w >= 12 + #m.state and m.state or ""
  C.bar(name, {}, nil, right, U.tone(m.state))
  return right ~= ""
end
-- Leaders from row 3 (2 on very short screens) to h-2, the alert on h-1, the actions on h.
V.tiny = function(C, m)
  local w, h = C.w, C.h
  local f, shown = V.facts(m), V.tinyBar(C, "MINING", m)
  local rows = { f[1], f[4], f[2], f[6], f[5] }
  if not shown then table.insert(rows, 1, { "state", m.state, V.fg(U.tone(m.state)) }) end
  local y = h >= 6 and 3 or 2
  for _, row in ipairs(rows) do
    if y > h - 2 then break end
    C.leader(2, y, w - 2, row[1], row[2], row[3])
    y = y + 1
  end
  if m.alert and h >= 4 then C.flag(2, h - 1, w - 2, m.alert) end
  V.run(C, h, m, 1)
end
-- The setup controls from row y, step rows apart, none below row stop. Returns the last row.
V.setupRows = function(C, m, x, y, step, vx, vw, right, editing, stop)
  local h = m.home
  if y <= stop then
    local home = m.homeSet and (h.x .. "," .. h.y .. "," .. h.z .. " " .. ("nesw"):sub(h.facing + 1, h.facing + 1)) or "-"
    C.put(x, y, "home", "8")
    C.put(vx, y, home:sub(1, right - vx + 1), m.homeSet and "0" or "8")
  end
  y = y + step
  if y <= stop then
    C.put(x, y, "bottom", "8")
    U.stepper(C, vx, y, "Y " .. m.bottom, "set-bottom", vw)
  end
  y = y + step
  if y <= stop then
    C.put(x, y, "length", "8")
    U.stepper(C, vx, y, m.length, "set-length", vw)
  end
  y = y + step
  if y <= stop then
    C.put(x, y, "mode", "8")
    local nx = C.chip(vx, y, "fast", "mode-fast", m.mode == "fast" and "plain" or "off") + 1
    C.chip(nx, y, "thorough", "mode-thorough", m.mode == "thorough" and "plain" or "off")
  end
  y = y + step
  if y <= stop then
    local ex = right - 5
    local ores = #m.ores > 0 and #m.ores < #V.ores and table.concat(m.ores, ",") or "all"
    C.put(x, y, "ores", "8")
    C.put(vx, y, ores:sub(1, math.max(0, ex - vx - 1)), "0")
    C.chip(ex, y, "edit", "ores-edit", editing and "on" or "plain")
  end
  local last = y
  if editing and C.w < 52 then
    local cx = x
    y = y + 1
    for _, name in ipairs(V.ores) do
      if cx + #name + 2 > right + 1 then cx, y = x, y + 1 end
      if y <= stop then C.chip(cx, y, name, "ore-" .. name, V.oreOn(m, name) and "plain" or "off") end
      cx = cx + #name + 3
    end
    return y
  end
  y = y + step
  if y <= stop then
    local ids = {}
    for _, t in ipairs(m.turtles) do ids[#ids + 1] = "#" .. t.id end
    local list = table.concat(ids, " ")
    C.put(x, y, "turtles", "8")
    C.put(vx, y, list ~= "" and list:sub(1, right - vx + 1) or "-", "0")
  end
  return math.max(last, y)
end
V.setupRoom = function(C, m, editing)
  local w, ya = C.w, C.h - 1
  U.roleBar(C, "MINING", V.tabs, V.short, 2, m.state, U.tone(m.state))
  local rx = w - 19
  local px, right = rx + 3, nil
  local left = V.setupRows(C, m, 2, 3, 2, 13, 8, rx - 3, editing, ya - 3)
  if editing then
    for i, name in ipairs(V.ores) do C.chip(px, 2 + i, name, "ore-" .. name, V.oreOn(m, name) and "plain" or "off") end
    right = 2 + #V.ores
  else
    local n = math.min(10, ya - 9)
    for i = 0, n - 1 do
      local b, y = n - i, 3 + i
      C.put(px + 2 - #tostring(b), y, tostring(b), "8")
      C.put(px + 3, y, "+", "3")
      C.put(px + 4, y, string.rep(U.g.dot, w - px - 4), "8")
    end
    C.put(px + 3, 3 + n, "|", "3")
    C.put(px + 3, 4 + n, U.g.shaft, "9")
    C.put(px, 6 + n, n * m.gap .. " " .. U.g.cross .. " " .. m.length, "8")
    right = 6 + n
  end
  for y = 3, math.max(left, right) do C.put(rx, y, "|", "c") end
  if m.alert then C.flag(2, ya - 2, w - 2, m.alert) end
  V.run(C, ya, m, 3)
end
V.setupColumn = function(C, m, editing)
  local w, h = C.w, C.h
  U.roleBar(C, "MINING", V.tabs, V.short, 2, m.state, U.tone(m.state))
  local wide = w >= 36
  V.setupRows(C, m, 2, 3, h >= 19 and 2 or 1, wide and 13 or 10, wide and 8 or 6, w - 1, editing,
    m.alert and h - 2 or h - 1)
  if m.alert then C.flag(2, h - 1, w - 2, m.alert) end
  V.run(C, h, m, 1)
end
V.layout = function(m, w, h, setup, editing)
  local C = U.canvas(w, h)
  local room = w >= 52 and h >= 22
  if setup and w >= 24 then
    if room then V.setupRoom(C, m, editing) else V.setupColumn(C, m, editing) end
  elseif room then V.room(C, m)
  elseif w >= 24 and h >= 14 then V.column(C, m)
  else V.tiny(C, m) end
  return C.frame()
end
-- so-mod-panel's pocket probe reads a 120x18 frame from an id-less session: the state on row 2
-- and LABEL VALUE rows from 3 with their colour. Kept until the panel reads facts().
V.probe = function(m)
  local rows = { { text = "" }, { text = "MINING " .. m.state } }
  for _, f in ipairs({ { "BUSY", m.busy .. "/" .. m.workers, "d" }, { "DEPTH", tostring(m.bottom), "d" },
      { "BRANCHES", m.done .. "/" .. m.total, "b" }, { "MIN FUEL", m.fuel and tostring(m.fuel.value) or "-", m.fuel and "d" or "c" } }) do
    rows[#rows + 1] = { text = f[1] .. " " .. f[2], runs = { { #f[1] + #f[2] + 1, "0", f[3] } } }
  end
  return { rows = rows, buttons = {} }
end
local function input(event)
  if type(event.text) ~= "string" then
    local v, id = view(event.session), tostring(event.id)
    if id == "setup" or id == "tab:setup" then v.page = "setup" return
    elseif id == "mine-back" or id == "tab:overview" or id == "tab:main" then v.page = "main" return
    elseif id == "ores-edit" then v.ores = not v.ores return
    elseif id == "start" or id == "stop" then event = { text = id }
    else event = { text = V.command(id) } end
  end
  if type(event.text)~="string" then return end
  local a={} for word in event.text:gmatch("%S+") do a[#a+1]=word end
  local cmd=a[1]
  local dirs={n=0,e=1,s=2,w=3}
  local function num(i) local n=tonumber(a[i]) if n and n%1==0 and math.abs(n)<30000000 then return n end end
  if cmd=="home" and num(2) and num(3) and num(4) and dirs[a[5]] then job.home={x=num(2),y=num(3),z=num(4),facing=dirs[a[5]]} job.homeSet=true
  elseif cmd=="bottom" and num(2) then job.bottom=num(2)
  elseif cmd=="length" and num(2) and num(2)>0 and num(2)<=4096 then job.length=num(2)
  elseif cmd=="mode" and (a[2]=="thorough" or a[2]=="fast") then job.mode=a[2]
  elseif cmd=="ores" and a[2] then
    local names={}
    for name in table.concat(a," ",2):gmatch("[^,]+") do
      name=name:match("^%s*(.-)%s*$")
      if not M.ores[name] then S.error="unknown ore" return end
      names[#names+1]=name
    end
    if #names==0 then S.error="unknown ore" return end
    job.ores=names
  elseif cmd=="add" and num(2) and num(2)>=0 and num(3) and num(4) and num(5) and dirs[a[6]] then
    local id=num(2)
    local status=call("lease","status",id)
    local uncertain=status and status.uncertain
    if job.turtles[tostring(id)] and not uncertain then S.error="already added" return end
    local pose={dim=job.dim,x=num(3),y=num(4),z=num(5),facing=dirs[a[6]]}
    if uncertain then
      local ok,err=call("lease","reanchor",id,pose)
      if not ok then S.error=err return end
      call("cells","releaseOwner",owner(id))
      S.pending[id],S.dugFacts[id]=nil,nil
    end
    S.error=nil
    job.turtles[tostring(id)]={anchor=pose,pose=pose,state="recovering",recover=true,inv={}}
    reservePose(id,job.turtles[tostring(id)]) save() park(id,job.turtles[tostring(id)],true)
  elseif cmd=="remove" and num(2) then
    local status=call("lease","status",num(2))
    if status and status.open then
      local ok = call("lease","cancelPark",num(2),"mine")
      if not ok then S.error="turtle has open lease" return end
    end
    local released, err = call("cells","releaseOwner",owner(num(2)))
    if released == false then S.error=tostring(err) return end
    job.turtles[tostring(num(2))]=nil
    S.pending[num(2)],S.dugFacts[num(2)] = nil,nil
  elseif cmd=="start" then
    local ok, err = call("state", "canStart")
    if not ok then S.error = err or "disk guard unavailable" return end
    if job.homeSet == false or not job.home then S.error="set home before start" return end
    S.error = nil
    job.running=true
  elseif cmd=="stop" then job.running=false
  else S.error="invalid mining command" return end
  S.error=nil
  save()
end
local function legacyRender(w)
  local rows={{text="        Mining " .. (job.running and "running" or "stopped")},{text="bottom "..job.bottom.." length "..job.length.." "..job.mode}}
  if S.error then rows[#rows+1]={text=S.error,fg="e"} end
  for id,row in pairs(job.turtles) do
    local p=row.pose
    if row.error == "pose uncertain: re-add turtle " .. id then
      if (w or 51) < #row.error then
        rows[#rows+1]={text="pose uncertain:",fg="e"}
        rows[#rows+1]={text="re-add turtle "..id,fg="e"}
      else rows[#rows+1]={text=row.error,fg="e"} end
    else
    rows[#rows+1]={text=id.." "..row.state.." "..p.x..","..p.y..","..p.z.." fuel "..tostring(row.fuel or "?").." ores "..(row.ores or 0).." "..tostring(row.error or ""),fg=(row.state=="lost" or row.state=="range") and "e" or "0"}
    end
  end
  return {rows=rows,buttons={}}
end
local function render(w,h,session)
  if not U then return legacyRender(w) end
  w, h = w or 57, h or 24
  if type(session) == "table" and session.id == nil and w == 120 and h == 18 then return V.probe(V.gather()) end
  local v = view(session)
  return V.layout(V.gather(), w, h, v.page == "setup", v.ores)
end
-- Job facts for other screens (the pocket's JOBS page); pure reads.
local function facts()
  local m = V.gather()
  return { state = m.state, done = m.done, total = m.total, busy = m.busy, workers = m.workers, depth = m.bottom,
    lane = m.lane and { id = m.lane.id, facing = m.lane.world } or nil,
    fuel = m.fuel and { value = m.fuel.value, id = m.fuel.id } or nil, alert = m.alert }
end
local function dugProtection(protect)
  for _, row in pairs(job.turtles) do
    if not S.wired or row.recover or not row.frame then return false end
    protect(job.dim, row, 48)
  end
  if job.running then
    local route = M.route(job, math.max(0, (job.progress.nextBranch or 0) - 1))
    protect(job.dim, { job.home, route }, 64)
  end
  return true
end
local function forgetDug(paths)
  local dim = job.dim:gsub("[^%w_%-]", function(c) return string.format("%%%02x", string.byte(c)) end)
  local prefix, visited = "so-data/cells/" .. dim .. "/", 0
  for key in pairs(S.known) do
    local x, y, z = key:match("^([^,]+),([^,]+),([^,]+)$")
    if x then
      local section = prefix .. string.format("%.0f_%.0f_%.0f", math.floor(tonumber(x)/16)+0,
        math.floor(tonumber(y)/16)+0, math.floor(tonumber(z)/16)+0)
      if paths[section] then S.known[key] = nil end
    end
    visited = visited + 1
    if visited % 128 == 0 then SO.breathe() end
  end
end
local function mapView()
  local view = {dim=job.dim,home=SO.store.copy(job.home),homeSet=job.homeSet,bottom=job.bottom,
    length=job.length,mode=job.mode,branches=job.progress.nextBranch or 0,turtles={},
    running=job.running,done=job.progress.done or 0}
  for id,row in pairs(job.turtles) do
    view.branches=math.max(view.branches,(row.branch or 0)+1)
    view.turtles[id]={pose=SO.store.copy(row.pose or row.anchor),state=row.state,dim=job.dim,
      branch=row.branch,lane=row.lane~=nil,ores=row.ores or 0}
  end
  return view
end
return {name="mine",handlers={},mapView=mapView,facts=facts,dugProtection=dugProtection,forgetDug=forgetDug,tick=function()
  if not S.wired then
    local lease,display=mod("lease"),mod("display")
    if not lease or type(lease.onReport)~="function" or not display or type(display.screen)~="function" then return end
    lease.onReport("mine",report) display.screen("mining",render,input) S.wired=true
    for _,row in pairs(job.turtles) do
      -- Rows saved before counted existed were counted when they finished.
      if row.state=="done" and row.counted==nil then row.counted=row.branch end
      row.recover=true row.state="recovering"
    end
  end
  for id,row in pairs(job.turtles) do
    if row.state ~= "wait lane" or row.recover or not job.running
      or (row.dropRetry and row.dropRetry.after and SO.now() < row.dropRetry.after) then row.laneWait=nil end
    if row.lane and row.lane.release and not row.recover then
      local status=call("lease","status",tonumber(id))
      if status and not status.open then
        call("cells","releaseOwner",owner(tonumber(id)))
        row.lane=nil
        S.handoffAt=SO.now()
        reservePose(tonumber(id),row)
        save()
        break
      end
    end
  end
  local ids={}
  for id in pairs(job.turtles) do ids[#ids+1]=tonumber(id) end
  table.sort(ids,laneOrder)
  for _,id in ipairs(ids) do plan(id,job.turtles[tostring(id)]) end
end}
