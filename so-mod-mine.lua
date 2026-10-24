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
  length = 64, branches = 8, continuous = false, mode = "thorough", ores = {}, turtles = {}, progress = { nextBranch = 0, done = 0 }, running = false }
local function branchLine(branch)
  local d = ({[0]={0,-1},{1,0},{0,1},{-1,0}})[job.home.facing]
  local distance = 1 + (branch+1)*(job.mode=="fast" and 2 or 4)
  local start = {dim=job.dim,x=job.home.x+d[1]*distance,y=job.bottom,z=job.home.z+d[2]*distance}
  return {start,{dim=job.dim,x=start.x-d[2]*job.length,y=start.y,z=start.z+d[1]*job.length}}
end
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
local function dropFailure(id, row, kind, point, reason)
  reason = reason or (kind == "ore" and "full" or "empty")
  local text = P.chestError(kind, reason, point)
  local key = (point and point.id or ("hold:" .. kind)) .. ":" .. reason
  local retry = row.dropRetry
  if not retry or retry.key ~= key then retry = { key = key, tries = 0 } row.dropRetry = retry end
  retry.tries = retry.tries + 1
  if retry.tries >= 3 or reason ~= "full" and reason ~= "empty" then
    if not retry.alerted then
      emit("mine.alert", { id = id, text = text, reason = reason, point = point })
      retry.alerted = true
    end
    row.laneWait = nil
    row.state, row.error = "hold", text
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
    dropFailure(id, row, kind, picked and picked.failedPoint, picked and picked.reason or "none")
    row.state = "hold" row.laneWait = nil
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
  dropFailure(id, row, kind, point, "unreachable")
  save() return false
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
local function confirmFuel(row, orderRid)
  for _, item in ipairs(row.inv or {}) do
    if item.count > 0 and P.fuelValue(item.name) > 0 then
      call("shop", "fuelAvailable", row.trip.point, orderRid or false)
      return
    end
  end
end
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
  if action and action.kind == "recover" and interrupted and interrupted.kind == "refuel"
      and interrupted.fuelOrder and row.trip and row.trip.kind == "fuel" then confirmFuel(row,interrupted.fuelOrder) end
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
        local failed, inspected, reason = false, row.trip.inspected == true, nil
        for i, step in ipairs(action.steps) do
          local result = results[i]
          if step.op == "inspect" or step.op == "inspectDown" then
            inspected = P.chestPresent(result)
            call("drops", "note", row.trip.point.id, inspected and result.data.name or nil)
            row.trip.inspected = inspected
            if not inspected then failed = true end
          elseif step.op == "drop" or step.op == "dropDown" or step.op == "suck" or step.op == "suckDown" then
            if not result.ok then failed = true reason=P.transferFailure(row.trip.kind,result)
            elseif row.trip.kind == "fuel" then
              confirmFuel(row,action.fuelOrder)
            end
          end
        end
        local enough = action.kind == "refuel" and type(row.fuel) == "number"
          and (row.fuel < 0 or row.fuel >= tripReserve(row.trip))
        if failed and inspected and row.trip.kind == "fuel" and reason == "empty" then
          call("shop", "fuelEmpty", row.trip.point)
        end
        if failed and enough and inspected and reason=="empty" then
          row.trip.stage = "back"
          row.state, row.dropRetry, row.error = "fuel", nil, nil
        elseif failed then dropFailure(id, row, row.trip.kind, row.trip.point, not inspected and "broken" or reason)
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
  if action.kind == "refuel" then
    local op = action.steps[#action.steps].op
    local policy = (op == "suck" or op == "suckDown") and call("shop","fuelConfig")
    action.fuelOrder = policy and policy.waiting and policy.waiting.rid or false
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
  local tool = P.toolCheck(status.tools,"pickaxe")
  call("lease", "describe", id, "mine", not tool.ok and tool.text or row.error or row.state or "idle")
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
  if type(mod("lease").ensureTool) == "function" then
    local equipped, reason = call("lease", "ensureTool", id, "pickaxe")
    if not equipped then
      row.state, row.error = "hold", reason
      local current = call("lease", "status", id)
      if not current or not current.open then park(id,row,false) end
      return
    end
    if row.error and (row.error == "needs pickaxe" or row.error:match("^tool swap failed:")) then
      row.state, row.error = "stopped", nil
    end
  end
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
          if not M.junk(item) and not unloadKeep[item.name] and not item.name:match("_pickaxe$") and not item.name:match("_axe$")
              and not item.name:match("_shovel$") and not item.name:match("_hoe$") and not item.name:match("_sword$") then
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
  local vein=row.veins and #row.veins>0 and (not M.inLane(job,row.pose) or row.lane and row.lane.target)
  if vein then
    row.goal=row.veins[#row.veins]
    if M.same(row.pose,row.goal) then table.remove(row.veins) row.goal=nil scan(row,true) save() return end
  elseif not row.returning then
    row.veinCount = 0
    if not row.route then
      local branch=job.progress.nextBranch or 0
      if job.continuous and branch >= (job.branches or 8) then row.state="done" save() park(id,row,false) return end
      job.progress.nextBranch=branch+1
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
        if not M.junk(item) and not unloadKeep[item.name] and not item.name:match("_pickaxe$") and not item.name:match("_axe$")
              and not item.name:match("_shovel$") and not item.name:match("_hoe$") and not item.name:match("_sword$") and P.fuelValue(item.name) == 0 then
          if trip(id,row,"ore") then save() plan(id,row)
          else park(id,row,false) end
          return
        end
      end
      row.state="done"
      -- Recovery sets a finished row back to mining; count each branch once.
      if row.counted~=row.branch then
        row.counted=row.branch job.progress.done=(job.progress.done or 0)+1
        S.trailDone = S.trailDone or {}
        S.trailDone[row.branch] = branchLine(row.branch)
        S.trailOrder = S.trailOrder or {}
        S.trailOrder[#S.trailOrder+1] = row.branch
        if #S.trailOrder>64 then S.trailDone[table.remove(S.trailOrder,1)]=nil end
        emit("mine.progress",{level=job.bottom,branch=row.branch,done=job.progress.done})
      end
      if job.continuous and (job.progress.nextBranch or 0) < (job.branches or 8) then
        local branch=job.progress.nextBranch or 0
        job.progress.nextBranch=branch+1
        local junction
        for i=#row.route,1,-1 do if M.inLane(job,row.route[i]) then junction=row.route[i] break end end
        row.returning = {branch=branch,junction=SO.store.copy(junction)}
        row.state = "mining"
      else save() park(id,row,false) return end
      save()
    end
  end
  if row.returning and not vein then
    local junction = row.returning.junction
    if M.same(row.pose,junction) then
      local branch=row.returning.branch
      row.branch,row.route=branch,M.route(job,branch)
      row.index=2
      for i=2,#row.route do if M.same(row.route[i],junction) then row.index=i+1 break end end
      row.returning=nil
      row.goal=row.route[row.index]
    else row.goal=junction end
    save()
  end
  row.state="mining"
  local action=M.next(job,row,lookup,row.inv,row.fuel)
  if action.kind=="hold" then row.error=action.error row.state="hold" park(id,row,false)
  elseif not send(id,row,action) then park(id,row,false) end
end
local function readiness()
  local homeSet=job.homeSet ~= false and job.home ~= nil
  local checks = {{ok=homeSet, text=homeSet and ("home "..job.home.x..","..job.home.y..","..job.home.z) or "home not set"}}
  local home=job.home or {x=0,y=0,z=0}
  local near = {dim=({["minecraft:overworld"]=0,["minecraft:the_nether"]=-1,["minecraft:the_end"]=1})[job.dim],
    x=home.x,y=home.y,z=home.z}
  local points = call("drops","list") or {}
  for _, kind in ipairs({"ore","fuel"}) do checks[#checks+1]=P.chestCheck(points,kind,near) end
  local added, ids = false, {}
  for id in pairs(job.turtles) do ids[#ids+1]=tonumber(id) end
  table.sort(ids)
  for _,id in ipairs(ids) do
    local status=call("lease","status",id)
    local paired=SO.pair and SO.pair.key(id) ~= nil
    if paired and status and not status.uncertain and not status.lost then added=true end
  end
  checks[#checks+1]={ok=added,text=added and "paired turtle ready" or "paired turtle missing"}
  if #ids==0 then checks[#checks+1]={ok=false,text="fuel missing"} end
  for _,id in ipairs(ids) do
    local row=job.turtles[tostring(id)]
    local status=call("lease","status",id)
    checks[#checks+1]=P.toolCheck(status and status.tools,"pickaxe",id,status and status.autoToolSwap)
    local fueled=type(row.fuel)=="number" and row.fuel~=0
    checks[#checks+1]={ok=fueled, text=fueled and ("fuel #"..id.." "..row.fuel) or ("fuel missing #"..id)}
  end
  return checks
end
local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local defaultView = { page = "main" }
local function view(session)
  if not U or type(session) ~= "table" then return defaultView end
  session.mining = session.mining or { page = "main" }
  return session.mining
end
local function command(event)
  if type(event.text) ~= "string" then
    if event.id == "workers-next" or event.id == "workers-prev" then
      local v = view(event.session) v.workers = (v.workers or 0)+(event.id == "workers-next" and 1 or -1) return
    elseif event.id == "setup" then view(event.session).page,view(event.session).offset = "setup",0 return
    elseif event.id == "setup-next" then local v=view(event.session) v.offset=(v.offset or 0)+1 return
    elseif type(event.id) == "string" and event.id:match("^here:%d+$") then event = { text = "add " .. event.id:match("%d+$") }
    elseif event.id == "fuel-auto" then
      local policy = call("shop","fuelConfig") or {}
      local ok, err = call("shop","fuelConfig",not policy.auto)
      if not ok then S.error = err or "shop unavailable" end
      return
    elseif event.id == "fuel-output" then
      local policy = call("shop","fuelConfig") or {}
      local points = {}
      for _, point in ipairs(call("drops","list") or {}) do
        if point.kind == "fuel" and not point.broken then points[#points+1] = point end
      end
      table.sort(points,function(a,b) return a.id < b.id end)
      local index = 1
      for i, point in ipairs(points) do if policy.output and point.id == policy.output.id then index = i % #points + 1 break end end
      if points[index] then
        local ok, err = call("shop","fuelConfig",nil,points[index].id)
        if not ok then S.error = err or "shop unavailable" end
      else S.error = "no fuel output point" end
      return
    elseif event.id == "mine-back" then view(event.session).page = "main" return
    elseif event.id == "start" or event.id == "stop" then event = { text = event.id } end
  end
  if type(event.text)~="string" then return end
  local a={} for word in event.text:gmatch("%S+") do a[#a+1]=word end
  local cmd=a[1]
  local dirs={n=0,e=1,s=2,w=3}
  local function num(i) local n=tonumber(a[i]) if n and n%1==0 and math.abs(n)<30000000 then return n end end
  if cmd == "add" and #a == 2 and num(2) and num(2) >= 0 then
    local id = num(2)
    if job.turtles[tostring(id)] then S.error = "already added" return end
    local lease = mod("lease")
    if not lease or not lease.locate then S.error = "GPS unavailable; use explicit add" return end
    S.error = "GPS probe"
    lease.locate(id, job.dim, function(pose, err)
      if not pose then S.error = err emit("mine.alert",{text=err}) return end
      command({text=string.format("add %d %d %d %d %s", id, pose.x, pose.y, pose.z, ({[0]="n","e","s","w"})[pose.facing])})
      emit("mine.alert",S.error and {text=S.error} or false)
    end)
    return
  end
  if cmd=="fuel" then
    local ok, err
    if a[2]=="auto" and (a[3]=="on" or a[3]=="off") and #a==3 then ok,err=call("shop","fuelConfig",a[3]=="on")
    elseif a[2]=="output" and a[3] and #a==3 then ok,err=call("shop","fuelConfig",nil,a[3])
    else S.error="invalid fuel command" return end
    S.error=not ok and (err or "shop unavailable") or nil
    return
  elseif cmd=="home" and num(2) and num(3) and num(4) and dirs[a[5]] then job.home={x=num(2),y=num(3),z=num(4),facing=dirs[a[5]]} job.homeSet=true
  elseif cmd=="bottom" and num(2) then job.bottom=num(2)
  elseif cmd=="length" and num(2) and num(2)>0 and num(2)<=4096 then job.length=num(2)
  elseif cmd=="branches" and num(2) and num(2)>0 and num(2)<=4096 then job.branches=num(2) job.continuous=true
  elseif cmd=="continuous" and (a[2]=="on" or a[2]=="off") then job.continuous=a[2]=="on"
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
    if status and status.probing then S.error="GPS probe pending" return end
    if job.turtles[tostring(id)] and not uncertain then S.error="already added" return end
    local pose={dim=job.dim,x=num(3),y=num(4),z=num(5),facing=dirs[a[6]]}
    if uncertain then
      local ok,err=call("lease","reanchor",id,pose)
      if not ok then S.error=err return end
      call("cells","releaseOwner",owner(id))
      S.pending[id],S.dugFacts[id]=nil,nil
    end
    local claimed, claimErr = call("lease", "claimProbe", id, owner(id), pose)
    if claimed == false then S.error = claimErr return end
    S.error=nil
    local previous = job.turtles[tostring(id)]
    job.turtles[tostring(id)]={anchor=pose,pose=pose,state="recovering",recover=true,inv={}}
    if not reservePose(id,job.turtles[tostring(id)]) or not save() then
      S.error = S.error or job.turtles[tostring(id)].error
      job.turtles[tostring(id)] = previous
      return
    end
    local cleared, clearErr = call("lease", "clearProbe", id)
    if cleared == false then S.error = clearErr return end
    park(id,job.turtles[tostring(id)],true)
    return
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
    if not ok then S.error = err or "disk guard unavailable" emit("mine.alert",{text=S.error}) return "published" end
    local missing=P.missing(readiness())
    if #missing>0 then
      S.error=table.concat(missing,"; ")
      emit("mine.alert",{text=S.error,missing=missing})
      return "published"
    end
    S.error = nil
    if call("state","get","mine.alert") then emit("mine.alert",false) end
    if not job.running then S.trailDone,S.trailOrder = {},{} end
    job.running=true
    if job.continuous and (job.progress.nextBranch or 0)<(job.branches or 8) then
      for _,row in pairs(job.turtles) do if row.state=="done" then row.state="mining" end end
    end
  elseif cmd=="stop" then job.running=false
  else S.error="invalid mining command" return end
  S.error=nil
  save()
end
local function input(event)
  if command(event)=="published" then return end
  if type(event.text) == "string" or event.id == "start" or event.id == "stop" or tostring(event.id):match("^here:") then
    local current=call("state","get","mine.alert")
    if S.error then
      if type(current) ~= "table" or current.text ~= S.error then emit("mine.alert",{text=S.error}) end
    elseif current then emit("mine.alert",false) end
  end
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
  return {rows=rows,buttons={{id="generic",x=1,y=1,w=7,label="generic"}}}
end
local function gather()
  local m = { available = call("lease", "candidates") or {}, running = job.running, alert = S.error, turtles = {}, tiles = {}, setup = {} }
  local busy, waiting, minimum, fuelId, waitIds = 0, 0, nil, nil, {}
  for id, row in pairs(job.turtles) do
    local state = row.laneWait and "wait lane" or row.state
    local stripe = (state == "lost" or state == "range") and "e" or
      (state == "wait lane" or state == "hold" or state == "waiting") and "1" or "d"
    if state == "mining" then busy = busy + 1 end
    if row.laneWait then waiting = waiting + 1 waitIds[#waitIds + 1] = "#" .. id end
    if type(row.fuel) == "number" and (not minimum or row.fuel < minimum) then minimum, fuelId = row.fuel, id end
    if not m.alert and row.error then m.alert = row.error end
    local p = row.pose or row.anchor or job.home
    local machine = call("state","get","machines/"..id) or {}
    m.turtles[#m.turtles + 1] = { label = machine.label, id = tonumber(id), state = state, stripe = stripe,
      pos = U and U.turtle.pose(p):match("^(%S+) ") or "-", fuel = tostring(row.fuel or "-"), ore = tostring(row.ores or 0),
      branch = row.branch, done = U and U.branchProgress(job,row), total = job.length }
  end
  table.sort(m.turtles, function(a,b) return a.id < b.id end)
  table.sort(waitIds)
  local today = call("daily", "today")
  local names, oreSub = {}, "no daily source"
  if today then
    for name, count in pairs(today.oreByName) do names[#names + 1] = { name = name, count = count } end
    table.sort(names, function(a,b) return a.count > b.count or (a.count == b.count and a.name < b.name) end)
    local parts = {}
    for i = 1, math.min(2, #names) do
      local short = names[i].name:gsub("^.-:", ""):gsub("^deepslate_", ""):gsub("_ore$", "")
      if short == "diamond" then short = "dia" end
      parts[#parts + 1] = short .. " " .. names[i].count
    end
    oreSub = table.concat(parts, " ")
  end
  m.tiles = {
    {"BUSY", busy .. "/" .. #m.turtles, busy .. " digging", "d"},
    {"ORE TODAY", today and tostring(today.ore) or "-", oreSub, today and "b" or "c"},
    {"DEPTH", tostring(job.bottom), "", "d"},
    {"LANE", tostring(waiting), waiting > 0 and (table.concat(waitIds,",") .. " waiting") or "clear", waiting > 0 and "1" or "d"},
    {"MIN FUEL", tostring(minimum or "-"), fuelId and ("#" .. fuelId) or "no fuel report", minimum and "d" or "c"},
    {"BRANCHES", (job.progress.done or 0) .. "/" .. (job.continuous and (job.branches or 8) or (job.progress.nextBranch or 0)), job.length .. " long", "b"},
  }
  m.setup = {
    "bottom " .. job.bottom, "length " .. job.length, "mode " .. job.mode,
    "ores " .. (#job.ores > 0 and table.concat(job.ores,",") or "all"),
    "branches " .. (job.branches or 8) .. (job.continuous and " continuous" or " single"),
  }
  m.fuelPolicy = call("shop","fuelConfig")
  m.readiness=readiness()
  return m
end
local function layout(m, w, h, setup, offset)
  local c = U.canvas(w,h)
  c.header(setup and "MINING SETUP" or "MINING", m.running and "running" or "stopped")
  if setup then
    local lines={}
    for _,check in ipairs(m.readiness) do
      lines[#lines+1]={text=check.text,bg=check.ok and "d" or "e"}
    end
    if #m.available > 0 then lines[#lines+1]={text="UNASSIGNED",bg="7"} end
    for _,id in ipairs(m.available or {}) do
      local machine=call("state","get","machines/"..id) or {}
      lines[#lines+1]={text=(machine.label or ("#"..id)).." FUEL "..tostring(machine.fuel or "?"),bg="f"}
      lines[#lines+1]={id=id}
    end
    for _,line in ipairs(m.setup) do
      for x=1,math.max(1,#line),math.max(1,w-2) do
        lines[#lines+1]={text=line:sub(x,x+math.max(1,w-2)-1),bg="f"}
      end
    end
    local count=math.max(1,h-(m.fuelPolicy and 6 or 4))
    local pages=math.max(1,math.ceil(#lines/count))
    local first=((offset or 0)%pages)*count
    for i=1,count do
      local line=lines[first+i]
      if line and i+3<h then
        if line.id then c.button(1,i+3,w,"ADD HERE #"..line.id,"here:"..line.id,"9",1)
        else
          c.fill(1,i+3,w,1,line.bg)
          c.put(2,i+3,line.text:sub(1,math.max(0,w-2)),U.ink(line.bg),line.bg)
        end
      end
    end
    if m.fuelPolicy then
      c.button(1,h-2,w,"FUEL AUTO "..(m.fuelPolicy.auto and "ON" or "OFF"),"fuel-auto","7",1)
      local output=m.fuelPolicy.output
      c.button(1,h-1,w,"OUTPUT "..(output and output.id or "NONE"),"fuel-output","7",1)
    end
    local left=1
    if pages>1 and w>1 then
      local width=math.max(1,math.floor(w/2))
      c.button(1,h,width,"NEXT","setup-next","7",1) left=width+1
    end
    c.button(left,h,w-left+1,"BACK","mine-back","7",1)
  else
    local cols = U.grid(w,h)
    local tall = h >= 19 and #cols >= 3
    local buttonHeight = tall and 3 or 1
    local buttonY = tall and h-3 or w < 26 and h-1 or h
    local tileRows = math.min(math.ceil(6/#cols), math.max(0,math.floor((buttonY-4)/7)))
    if tall then
      for i,t in ipairs(m.tiles) do
        local col = cols[(i-1)%#cols+1]
        local row = math.floor((i-1)/#cols)
        if row < tileRows then c.tile(col.x,4+row*6,col.w,t[1],t[2],t[3],t[4],6) end
      end
    else
      for i,t in ipairs(m.tiles) do
        if i+2 < math.min(buttonY, h < 19 and 6 or 9) then
          c.fill(1,i+2,w,1,t[4]); c.put(2,i+2,(t[1] .. " " .. t[2]):sub(1,math.max(0,w-2)))
        end
      end
    end
    local listY = tall and 4+tileRows*6 or h < 19 and 6 or 9
    local capacity = math.max(1, math.floor((buttonY-listY-1)/2))
    local pages = math.max(1, math.ceil(#m.turtles/capacity))
    local page = (m.page or 0) % pages
    if listY < buttonY then
      c.fill(1,listY,w,1,"7"); c.put(2,listY,w < 39 and "TURTLE  POS  STATE" or "TURTLE  STATE      POS          FUEL  ORE")
      for i=1,capacity do
        local row = m.turtles[page*capacity+i]
        local y = listY+1+(i-1)*2
        if row and y+1 < buttonY then
          local text = w < 39 and string.format("%s %s %s",row.label or ("#"..row.id),row.pos,row.state)
            or string.format("%-8s%-11s%-14s%-4s%4s",row.label or ("#"..row.id),row.state,row.pos,row.fuel,row.ore)
          c.listRow(y,text,row.stripe)
          c.hit("turtle:"..row.id,1,y,w,2)
          if row.branch ~= nil and row.done == nil then c.put(2,y+1,"-")
          else U.progress(c,2,y+1,math.min(12,w-2),row.done or 0,row.total or 0,row.stripe) end
          c.put(15,y+1,row.branch ~= nil and ("B"..row.branch.." "..(row.done or "-").."/"..(row.total or 0)) or "-")
        end
      end
    end
    if pages > 1 then
      c.button(w-9,listY,4,"<","workers-prev","7",1)
      c.button(w-4,listY,4,">","workers-next","7",1)
    end
    local buttons = {{"START","start","9"},{"STOP","stop","e"},{"SETUP","setup","7"},{"BACK","status","7"}}
    local available, x = math.max(0,w-3), 1
    for i,b in ipairs(buttons) do
      local width = math.floor(available/(5-i))
      local y = buttonY
      if w < 26 then
        local cols = U.grid(w,h,2)
        local col = cols[(i-1)%2+1]
        x, width, y = col.x, col.w, buttonY+math.floor((i-1)/2)
      end
      c.button(x,y,width,b[1],b[2],b[3],buttonHeight)
      x, available = x+width+1, available-width
    end
  end
  if setup then
    if m.alert then c.fill(2,3,w-2,1,"e") c.put(2,3,m.alert:sub(1,math.max(0,w-2)),"f","e") end
  else
    local count=#c.buttons
    c.alert(m.alert)
    if #c.buttons>count then table.insert(c.buttons,1,table.remove(c.buttons)) end
  end
  return c.frame()
end
local function render(w,h,session)
  if not U then return legacyRender(w) end
  local m = gather() m.page = view(session).workers
  return layout(m,w or 57,h or 24,view(session).page == "setup",view(session).offset)
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
    length=job.length,mode=job.mode,branches=job.progress.nextBranch or 0,turtles={},trails={}}
  local branch = job.progress.nextBranch or 0
  local occupied = false
  for id,row in pairs(job.turtles) do
    view.branches=math.max(view.branches,(row.branch or 0)+1)
    view.turtles[id]={pose=SO.store.copy(row.pose or row.anchor),state=row.state,dim=job.dim}
    if row.branch==branch or row.returning and row.returning.branch==branch then occupied=true end
    if row.state~="done" and row.branch and row.pose and row.pose.y==job.bottom and job.homeSet~=false then
      local points = branchLine(row.branch)
      local a,b = points[1],points[2]
      local dx,dz = (b.x-a.x)/job.length,(b.z-a.z)/job.length
      local length = math.max(0,math.min(job.length,(row.pose.x-a.x)*dx+(row.pose.z-a.z)*dz))
      b.x,b.z = a.x+dx*length,a.z+dz*length
      if length>0 then view.trails[#view.trails+1]={id=tostring(id),state=row.state,points=points} end
    end
  end
  local key = table.concat({job.dim,job.home.x,job.home.y,job.home.z,job.home.facing,
    job.bottom,job.length,job.mode,tostring(job.homeSet),branch},":")
  if S.previewKey~=key then
    S.previewKey=key
    S.preview=nil
    if job.homeSet~=false then
      local route=M.route(job,branch)
      S.preview={SO.store.copy(route[#route-job.length]),SO.store.copy(route[#route])}
    end
  end
  if job.running and job.homeSet~=false and not occupied and (not job.continuous or branch<(job.branches or 8)) then
    view.preview=SO.store.copy(S.preview)
    view.branches=math.max(view.branches,branch+1)
  end
  local done = {}
  for n in pairs(S.trailDone or {}) do done[#done+1]=n end
  table.sort(done,function(a,b) return a>b end)
  for i=1,math.min(64,#done) do
    view.trails[#view.trails+1]={id="done:"..done[i],state="done",points=SO.store.copy(S.trailDone[done[i]])}
  end
  return view
end
local function turtleView()
  local out = {}
  for id,row in pairs(job.turtles) do
    local done,total = U and U.branchProgress(job,row), job.length
    out[id] = {role="mining", pose=SO.store.copy(row.pose), state=row.state, fuel=row.fuel,
      inv=SO.store.copy(row.inv or {}), branch=row.branch, done=done, total=total,
      step=S.pending[tonumber(id)] and S.pending[tonumber(id)].kind, error=row.error or S.error, retry=row.dropRetry and row.dropRetry.after,
      ore=row.ores, anchor=SO.store.copy(row.anchor)}
  end
  return out
end
return {name="mine",assigned=function(id) return job.turtles[tostring(id)] ~= nil end,handlers={},turtleView=turtleView,mapView=mapView,dugProtection=dugProtection,forgetDug=forgetDug,tick=function()
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
