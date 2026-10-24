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
local function skipped(cell)
  return cell and ((job.digFailures and job.digFailures[M.key(cell)] or 0) >= 3
    or job.skipped and job.skipped[M.key(cell)])
end
local function failedDig(id, row, cell, reason)
  local key = M.key(cell)
  job.digFailures = job.digFailures or {}
  job.digFailures[key] = math.min(3, (job.digFailures[key] or 0) + 1)
  S.known[key] = nil row.error = reason
  if skipped(cell) then
    row.detour = nil row.error = nil
    emit("mine.alert", {id=id,text="skipped undiggable cell "..key})
  end
end
local function claimBranch()
  if job.unfinished and #job.unfinished > 0 then return table.remove(job.unfinished, 1), true end
  local branch = job.progress.nextBranch or 0
  if job.continuous and branch >= (job.branches or 8) then return nil end
  job.progress.nextBranch = branch + 1
  return branch
end
local function keepBranch(branch)
  if branch == nil then return end
  job.unfinished = job.unfinished or {}
  for _, old in ipairs(job.unfinished) do if old == branch then return end end
  job.unfinished[#job.unfinished+1] = branch
end
local function returnJunction(row)
  local route = row.route or M.route(job,row.branch)
  for i=#route,1,-1 do
    if M.inLane(job,route[i]) and not skipped(route[i]) then return SO.store.copy(route[i]) end
  end
  local home = SO.store.copy(job.home) home.dim=job.dim
  return home
end
local function clearRoute(row)
  if row.route then row.rebuild = row.branch end
  row.route, row.goal, row.detour, row.stopRoute = nil, nil, nil, nil
end
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
  if point.dim ~= near.dim then row.error="drop dimension mismatch" return false end
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
  if not row or row.forgotten then return end
  local action, interrupted = S.pending[id], row.inflight
  S.pending[id] = nil
  if not results or not lease.report or not lease.report.pose then
    row.state, row.error, row.recover = "lost", job.dim ~= "minecraft:overworld" and "remote silent; unloaded?" or "lease expired or missing pose", true row.laneWait=nil save() return
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
      if job.digFailures then job.digFailures[M.key(world)] = nil end
      interrupted = nil
    end
    local key=M.key(world)
    if not priorDug[key] then mark(world) end
    nextDug[key]=true
  end
  -- An interrupted dig consumes a retry unless recovery confirms success.
  if action and action.kind == "recover" and interrupted and interrupted.kind == "dig" then
    failedDig(id,row,interrupted.cell,"dig outcome missing after recovery")
  end
  if facts.dug then
    S.dugFacts[id]=nextDug
    call("cells", "rememberWorker", id, row.pose, history)
  end
  for _, result in ipairs(results) do
    local hazard=result.hazard or result.err
    if type(hazard)=="string" and hazard:match("^remote safety:") then
      row.safety=hazard row.error=hazard:gsub("^remote safety: ","") row.state="hold"
      emit("mine.alert",{id=id,text=row.error})
      break
    end
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
        if row.detour and M.impassable(job,action.cell,lookup,row.trip and row.trip.point) then
          for _, cell in ipairs(row.detour) do
            if M.same(cell,action.cell) then row.detour, row.error = nil, nil break end
          end
        end
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
          if job.digFailures then job.digFailures[M.key(action.cell)] = nil end
          if action.ore then row.ores = (row.ores or 0)+1 row.veinCount = (row.veinCount or 0)+1 emit("mine.ore", { id = id, name = action.ore, count = 1 }) row.scanAfter = true
            if row.veinCount >= 64 then row.veins = { action.cell } end
          end
        else
          failedDig(id,row,action.cell,results[1].err)
        end
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
  if action.kind == "skip" then
    job.skipped = job.skipped or {}
    job.skipped[M.key(action.cell)] = true
    row.detour, row.error = nil, nil
    if row.returning then
      keepBranch(row.returning.branch)
      row.returning, row.state = nil, "done"
    end
    row.trip, row.resumeTrip = nil, nil
    emit("mine.alert",{id=id,text="skipped unreachable cell "..M.key(action.cell)})
    return save()
  end
  if #action.steps == 0 then return false end
  for _, step in ipairs(action.steps) do
    if step.op == "dig" or step.op == "digUp" or step.op == "digDown" then
      local status = call("lease", "status", id)
      if not P.toolCheck(status and status.tools, "pickaxe").ok then
        if row.error ~= "needs pickaxe" then emit("mine.alert", {id=id,text="needs pickaxe"}) end
        row.state, row.error = "hold", "needs pickaxe"
        call("lease", "describe", id, "mine", row.error)
        save()
        return false
      end
    end
  end
  for _, part in ipairs(action.actions or {action}) do
    if part.detour ~= nil then row.detour = part.detour or nil end
  end
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
  if row.forgotten then return end
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
  if row.stopRoute or not job.running and row.route then clearRoute(row) save() end
  if type(mod("lease").ensureTool) == "function" then
    local equipped, reason = call("lease", "ensureTool", id, "pickaxe")
    if not equipped then
      row.state, row.error = "hold", reason
      local current = call("lease", "status", id)
      if not current or not current.open then park(id,row,false) end
      return
    end
    if tool.ok and row.error and (row.error == "needs pickaxe" or row.error:match("^tool swap failed:")) then
      row.state, row.error = "stopped", nil
    end
  end
  if job.dim ~= "minecraft:overworld" then
    local err=P.dimensionError(job.dim,SO.store.read("so-server.cfg")) or P.heightError(job.dim,row.pose.y)
      or P.heightError(job.dim,job.home.y) or P.heightError(job.dim,job.bottom) or row.safety
    if err then row.error=err:gsub("^remote safety: ","") row.state="hold" park(id,row,false) return end
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
  if row.detour then
    for i, cell in ipairs(row.detour) do
      if M.same(row.pose, cell) then
        for _=1,i do table.remove(row.detour,1) end
        break
      end
    end
    if #row.detour == 0 then row.detour = nil end
  end
  while row.veins and row.veins[#row.veins] do
    local cell=row.veins[#row.veins]
    if not skipped(cell) and (row.goal and M.same(cell,row.goal) or not call("cells","isDug",cell.x,cell.y,cell.z,job.dim)) then break end
    table.remove(row.veins)
  end
  local vein=row.veins and #row.veins>0 and (not M.inLane(job,row.pose) or row.lane and row.lane.target)
  if vein then
    row.goal=row.veins[#row.veins]
    if M.same(row.pose,row.goal) then table.remove(row.veins) row.goal=nil scan(row,true) save() return end
  elseif not row.returning then
    row.veinCount = 0
    if not row.route then
      local branch, reclaimed = row.rebuild, row.reclaimed
      if branch == nil then branch, reclaimed = claimBranch() end
      if branch == nil then row.state="done" save() park(id,row,false) return end
      row.branch, row.route, row.index=branch,M.route(job,branch),row.rebuild ~= nil and row.index or 1
      row.rebuild, row.reclaimed = nil, reclaimed
      row.veinCount = 0
    end
    -- A worker added below the surface joins its route at the nearest tunnel
    -- cell rather than climbing a new column to the shaft top.
    if row.index==1 and row.pose.y<row.route[1].y then
      row.index=2
      if not row.reclaimed then
        for i=3,#row.route do
          if M.distance(row.pose,row.route[i])<M.distance(row.pose,row.route[row.index]) then row.index=i end
        end
      end
    end
    while row.route[row.index] and (M.same(row.pose,row.route[row.index]) or skipped(row.route[row.index])) do row.index=row.index+1 end
    row.goal=row.route[row.index]
    -- A finished worker recovered elsewhere (moved by hand, or backed along
    -- its path by a worker from before #146) returns to its branch end, so it
    -- does not park in a column or lane that other workers travel through.
    local last=row.route[#row.route]
    if not row.goal and last and not skipped(last) and not M.same(row.pose,last) then row.goal=last end
    if not row.goal and last and skipped(last) and M.inLane(job,row.pose) then
      local endPose=SO.store.copy(last) endPose.facing=(job.home.facing+1)%4
      local exit=M.cell(endPose,"forward")
      if not skipped(exit) then row.goal=exit end
    end
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
      if #(job.unfinished or {}) > 0 or job.continuous and (job.progress.nextBranch or 0) < (job.branches or 8) then
        local branch=claimBranch()
        row.returning = {branch=branch,junction=returnJunction(row)}
        row.state = "mining"
      else save() park(id,row,false) return end
      save()
    end
  end
  if row.returning and not vein then
    if skipped(row.returning.junction) then row.returning.junction=returnJunction(row) end
    local junction = row.returning.junction
    if M.same(row.pose,junction) then
      local branch=row.returning.branch
      row.branch,row.route=branch,M.route(job,branch)
      row.index=2
      for i=2,#row.route do if M.same(row.route[i],junction) then row.index=i+1 break end end
      row.returning,row.rebuild=nil,nil
      row.goal=row.route[row.index]
    else row.goal=junction end
    save()
  end
  row.state="mining"
  local action=M.next(job,row,lookup,row.inv,row.fuel)
  if action.kind=="hold" then row.error=action.error row.state="hold" park(id,row,false)
  elseif not send(id,row,action) then park(id,row,false) end
end
local function dimensionError(y)
  local config=job.dim ~= "minecraft:overworld" and SO.store.read and SO.store.read("so-server.cfg")
  return P.dimensionError(job.dim, config) or P.heightError(job.dim, y)
end
local function readiness()
  local homeSet=job.homeSet ~= false and job.home ~= nil
  local checks = {{ok=homeSet, text=homeSet and ("home "..job.home.x..","..job.home.y..","..job.home.z) or "home not set"}}
  local home=job.home or {x=0,y=0,z=0}
  local near = {dim=({["minecraft:overworld"]=0,["minecraft:the_nether"]=-1,["minecraft:the_end"]=1})[job.dim],
    x=home.x,y=home.y,z=home.z}
  if job.dim ~= "minecraft:overworld" then
    local err = dimensionError(home.y) or P.heightError(job.dim, job.bottom)
    checks[#checks+1] = {ok=not err, text=err or job.dim}
    for id in pairs(job.turtles) do
      local ok, why = call("lease", "remoteReady", tonumber(id), job.dim)
      checks[#checks+1] = {ok=ok == true, text=why or "remote worker ready"}
    end
  end
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
  local started = total
  if job.continuous then total = math.max(total, job.branches or 8) end
  local today = call("daily", "today")
  local m = { state = job.running and "running" or "stopped", alert = S.error, length = length, gap = gap,
    bottom = bottom, done = job.progress.done or 0, total = total, extents = {}, turtles = {}, busy = 0,
    workers = 0, ore = today and today.ore, home = h, homeSet = job.homeSet ~= false, mode = job.mode, ores = job.ores,
    dim = job.dim, branches = job.branches or 8, continuous = job.continuous == true }
  for b = 1, total do m.extents[b] = b <= started and length or 0 end
  for _, n in ipairs(ids) do
    local row = job.turtles[tostring(n)]
    local p = row.pose or row.anchor or h
    -- A partial pose (a report without all three coordinates) has no place on the diagram.
    local whole = type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
    local status = call("lease", "status", n) or {}
    local word = status.lost and "lost" or row.laneWait and "wait lane" or tostring(row.state)
    local t = { id = n, facing = ((p.facing or h.facing) - h.facing) % 4, world = p.facing, state = word, tone = U.tone(word),
      where = row.lane and "lane" or row.branch and "b" .. (row.branch + 1) or "-", at = whole and p.x .. "," .. p.y .. "," .. p.z or "-",
      fuel = type(row.fuel) == "number" and row.fuel or nil, ore = row.ores or 0, lost = status.lost and true or false,
      spine = false, along = 0 }
    -- Live branch progress: b1 12/48, or b1 -/48 while the pose cannot place it.
    if row.branch and not row.lane then
      local done = U.branchProgress and U.branchProgress(job, row)
      t.prog = t.where .. " " .. (done or "-") .. "/" .. length
    end
    local k = whole and (p.x - tx) * d[1] + (p.z - tz) * d[2] or 0
    local along = whole and (p.x - tx) * r[1] + (p.z - tz) * r[2] or 0
    local near = math.floor((2 * k + gap) / (2 * gap))
    if not whole then
    elseif row.lane then
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
V.fuelPoints = function()
  local points = {}
  for _, point in ipairs(call("drops","list") or {}) do
    if point.kind == "fuel" and not point.broken then points[#points+1] = point end
  end
  table.sort(points,function(a,b) return a.id < b.id end)
  return points
end
-- The setup tab's extra facts: start checks, unassigned turtles and the shop's fuel policy.
V.setup = function(m)
  m.checks, m.available = {}, {}
  for _, check in ipairs(readiness()) do m.checks[#m.checks + 1] = { text = check.text, ok = check.ok } end
  for _, id in ipairs(call("lease", "candidates") or {}) do
    local machine = call("state", "get", "machines/" .. id) or {}
    m.available[#m.available + 1] = { id = id, fuel = machine.fuel }
  end
  local policy = call("shop", "fuelConfig")
  if type(policy) == "table" then
    m.policy = { auto = policy.auto == true, out = "-" }
    for i, point in ipairs(call("drops", "list") or {}) do
      if policy.output and point.id == policy.output.id then m.policy.out = tostring(i) end
    end
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
  local per = #ts > nt and math.max(1, nt - 1) or nt
  local first = ((m.workerPage or 0) % math.ceil(#ts / math.max(1, per))) * per
  for i = 1, nt do
    local y, t = top + i, ts[first + i]
    -- The last page keeps the row, so the pages wrap.
    if (i == nt or not t) and #ts > nt then
      C.put(4, y, "+" .. (#ts - math.min(per, #ts - first)) .. " more", "8")
      C.hit("workers-next", 2, y, right - 1, 1)
      break
    end
    if not t then break end
    C.hit("turtle:" .. t.id, 2, y, right - 1, 1)
    C.put(2, y, U.arrow(t.facing), t.tone)
    C.put(4, y, tostring(t.id), "0")
    C.put(7, y, t.state:sub(1, 10), V.fg(t.tone))
    C.put(18, y, (t.prog or t.where):sub(1, 9), "8")
    C.put(28, y, t.at:sub(1, math.max(0, right - 40)), t.lost and "e" or "8")
    local fuel = t.fuel and tostring(t.fuel) or "-"
    C.put(right - 5 - #fuel, y, fuel, not t.fuel and "8" or t.fuel < 500 and "1" or "0")
    C.put(right - #tostring(t.ore), y, tostring(t.ore), "0")
  end
end
-- Compact turtle rows from top to stop: arrow, id, then the branch progress while working or the
-- state word. Each row opens the turtle's details; +N more pages. Returns the last row drawn.
V.list = function(C, m, top, stop, right)
  local ts, nt = m.turtles, stop - top + 1
  if #ts == 0 or nt < 1 then return top - 1 end
  local per = #ts > nt and math.max(1, nt - 1) or nt
  local first = ((m.workerPage or 0) % math.ceil(#ts / per)) * per
  for i = 1, nt do
    local y, t = top + i - 1, ts[first + i]
    -- The last page keeps the row, so the pages wrap.
    if (i == nt or not t) and #ts > nt then
      C.put(4, y, "+" .. (#ts - math.min(per, #ts - first)) .. " more", "8")
      C.hit("workers-next", 2, y, right - 1, 1)
      return y
    end
    if not t then return y - 1 end
    local text = t.tone == "d" and t.prog or t.state
    C.put(2, y, U.arrow(t.facing), t.tone)
    C.put(4, y, tostring(t.id), "0")
    C.put(7, y, text:sub(1, math.max(0, right - 6)), text == t.state and V.fg(t.tone) or "0")
    C.hit("turtle:" .. t.id, 2, y, right - 1, 1)
  end
  return stop
end
V.room = function(C, m)
  local w, ya = C.w, C.h - 1
  U.roleBar(C, "MINING", V.tabs, V.short, 1, m.state, U.tone(m.state))
  -- The diagram draws at most one cell per block; the facts and the table follow it on wide walls.
  local lx, f = math.min(w - 11, math.max(1, math.min(w - 27, m.length)) + 18), V.facts(m)
  for i, row in ipairs(f) do C.leader(lx, 2 + i, 11, row[1], row[2], row[3]) end
  V.run(C, ya, m, 3)
  if m.alert then C.flag(2, ya - 2, w - 2, m.alert) end
  -- Caps keep the biggest walls inside the 16 KB frame: 12 turtle rows, 24 branch rows.
  local nt = math.min(#m.turtles, math.max(0, ya - 7 - #f), 12)
  local shown = math.min(m.total, ya - 3 - nt - (nt > 0 and 1 or 0) - 5, 24)
  V.diagram(C, m, 3, shown, lx - 2)
  -- The table runs under the facts, so a short diagram leaves it below them.
  V.turtles(C, m, math.max(3 + shown + 3, 4 + #f), nt, lx + 10)
end
-- The alert ending on row y: one flag row, or two when it is longer than the row and splits at a
-- space. Returns the rows used.
V.alert = function(C, y, text)
  local width = C.w - 4
  local cut = #text > width and text:sub(1, width + 1):match("^.*() ")
  if not cut or cut < 2 then C.flag(2, y, C.w - 2, text) return 1 end
  C.flag(2, y - 1, C.w - 2, text:sub(1, cut - 1))
  C.put(4, y, text:sub(cut + 1, cut + width), "0")
  return 2
end
V.column = function(C, m)
  local w, ya = C.w, C.h
  local shown = U.roleBar(C, "MINING", V.tabs, V.short, 1, m.state, U.tone(m.state))
  V.run(C, ya, m, 1)
  local f, last, top = V.facts(m), ya - 2 - (m.alert and V.alert(C, ya - 1, m.alert) or 0)
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
  -- Up to four turtle rows between the diagram and the leaders.
  local nt = math.max(0, math.min(#m.turtles, 4, top - 5))
  if nt > 0 then
    top = top - 2 - nt
    C.section(2, top, w - 2, "TURTLES")
    V.list(C, m, top + 1, top + nt, w - 1)
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
  -- Busy and done, then the turtles; without turtles the other leaders.
  local rows = #m.turtles > 0 and { f[1], f[4] } or { f[1], f[4], f[2], f[6], f[5] }
  if not shown then table.insert(rows, 1, { "state", m.state, V.fg(U.tone(m.state)) }) end
  -- A long alert wraps onto a second row from 8 rows up.
  local used = 0
  if m.alert and h >= 4 then
    if h >= 8 then used = V.alert(C, h - 1, m.alert) else C.flag(2, h - 1, w - 2, m.alert) used = 1 end
  end
  local stop = h - 1 - math.max(1, used)
  local y = h >= 6 and 3 or 2
  for _, row in ipairs(rows) do
    if y > stop then break end
    C.leader(2, y, w - 2, row[1], row[2], row[3])
    y = y + 1
  end
  V.list(C, m, y, stop, w - 1)
  V.run(C, h, m, 1)
end
-- The setup controls from row y, step rows apart, none below row stop. Returns the last row.
V.setupRows = function(C, m, x, y, step, vx, vw, right, editing, stop)
  local h = m.home
  if m.dim ~= "minecraft:overworld" then
    if y <= stop then
      C.put(x, y, "dim", "8")
      C.put(vx, y, m.dim:gsub("^minecraft:", ""):sub(1, right - vx + 1), "0")
    end
    y = y + step
  end
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
    C.put(x, y, vx - x >= 9 and "branches" or "branch", "8")
    C.put(vx, y, (m.branches .. " " .. (m.continuous and "continuous" or "single")):sub(1, right - vx + 1), "0")
  end
  if m.policy then
    y = y + step
    if y <= stop then
      C.put(x, y, "fuel", "8")
      local nx = C.chip(vx, y, "auto", "fuel-auto", m.policy.auto and "on" or "off") + 1
      C.chip(nx, y, "out " .. m.policy.out, "fuel-output", "plain")
    end
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
-- READY from row y to row stop between x and right: the missing start checks, the unassigned
-- turtles with an add chip, then the checks that pass. lead pages come before the list (the
-- narrow setup's controls); returns the last row drawn, or nil on a lead page.
V.ready = function(C, m, x, y, right, stop, offset, lead)
  local items, ok = V.items(m)
  local cap = stop - y
  if cap < 1 or #items == 0 then return y - 1 end
  lead = lead or 0
  local pages = math.ceil(#items / cap) + lead
  local page = (offset or 0) % pages
  if page < lead then return nil, pages end
  if pages > 1 then
    C.section(x, y, right - x + 1, "READY", (page + 1) .. "/" .. pages)
    C.hit("setup-next", x, y, right - x + 1, 1)
  else C.section(x, y, right - x + 1, "READY", ok .. "/" .. #m.checks, ok == #m.checks and "d" or "1") end
  local last = y
  for i = (page - lead) * cap + 1, math.min(#items, (page - lead + 1) * cap) do
    local it = items[i]
    last = last + 1
    C.put(x, last, U.g.bullet, it[1])
    C.put(x + 2, last, it[2]:sub(1, math.max(0, right - x - 1 - (it[3] and 6 or 0))), "0")
    if it[3] then C.chip(right - 4, last, "add", "here:" .. it[3], "primary") end
  end
  return last
end
V.items = function(m)
  local items, ok = {}, 0
  for _, check in ipairs(m.checks) do if not check.ok then items[#items + 1] = { "e", check.text } end end
  for _, t in ipairs(m.available) do items[#items + 1] = { "1", "#" .. t.id .. " fuel " .. tostring(t.fuel or "?"), t.id } end
  for _, check in ipairs(m.checks) do
    if check.ok then items[#items + 1] = { "d", check.text } ok = ok + 1 end
  end
  return items, ok
end
V.setupRoom = function(C, m, editing)
  local w, ya = C.w, C.h - 1
  U.roleBar(C, "MINING", V.tabs, V.short, 2, m.state, U.tone(m.state))
  local rx = math.max(32, math.floor(w / 2))
  local left = V.setupRows(C, m, 2, 3, 2, 13, 8, rx - 3, editing, ya - 3)
  local right
  if editing then
    for i, name in ipairs(V.ores) do C.chip(rx + 3, 2 + i, name, "ore-" .. name, V.oreOn(m, name) and "plain" or "off") end
    right = 2 + #V.ores
  else right = V.ready(C, m, rx + 2, 3, w - 1, ya - 3, m.setupPage) end
  for y = 3, math.max(left, right) do C.put(rx, y, "|", "c") end
  if m.alert then C.flag(2, ya - 2, w - 2, m.alert) end
  V.run(C, ya, m, 3)
end
V.setupColumn = function(C, m, editing)
  local w, h = C.w, C.h
  U.roleBar(C, "MINING", V.tabs, V.short, 2, m.state, U.tone(m.state))
  local wide, stop = w >= 36, m.alert and h - 2 or h - 1
  local vx, vw = wide and 13 or 10, wide and 8 or 6
  -- READY follows the controls; when it does not fit under them it gets pages of its own after
  -- the controls' page, which ends with the READY row.
  local last = V.setupRows(U.canvas(w, h), m, 2, 3, 1, vx, vw, w - 1, editing, stop)
  if #V.items(m) <= math.max(0, stop - last - 2) then
    V.setupRows(C, m, 2, 3, 1, vx, vw, w - 1, editing, stop)
    V.ready(C, m, 2, last + 2, w - 1, stop, m.setupPage)
  elseif stop >= 4 then
    local shown, pages = V.ready(C, m, 2, 3, w - 1, stop, m.setupPage, 1)
    if not shown then
      V.setupRows(C, m, 2, 3, 1, vx, vw, w - 1, editing, stop - 1)
      C.section(2, stop, w - 2, "READY", "1/" .. pages)
      C.hit("setup-next", 2, stop, w - 2, 1)
    end
  else V.setupRows(C, m, 2, 3, 1, vx, vw, w - 1, editing, stop) end
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
local function command(event)
  if type(event.text) ~= "string" then
    local v, id = view(event.session), tostring(event.id)
    if id == "setup" or id == "tab:setup" then v.page, v.offset = "setup", 0 return
    elseif id == "mine-back" or id == "tab:overview" or id == "tab:main" then v.page = "main" return
    elseif id == "ores-edit" then v.ores = not v.ores return
    elseif id == "setup-next" then v.offset = (v.offset or 0) + 1 return
    elseif id == "workers-next" or id == "workers-prev" then v.workers = (v.workers or 0) + (id == "workers-next" and 1 or -1) return
    elseif id:match("^here:%d+$") then event = { text = "add " .. id:match("%d+$") }
    elseif id == "fuel-auto" then
      local policy = call("shop","fuelConfig") or {}
      local ok, err = call("shop","fuelConfig",not policy.auto)
      if not ok then S.error = err or "shop unavailable" end
      return
    elseif id == "fuel-output" then
      local policy = call("shop","fuelConfig") or {}
      local points = V.fuelPoints()
      local index = 1
      for i, point in ipairs(points) do if policy.output and point.id == policy.output.id then index = i % #points + 1 break end end
      if points[index] then
        local ok, err = call("shop","fuelConfig",nil,points[index].id)
        if not ok then S.error = err or "shop unavailable" end
      else S.error = "no fuel output point" end
      return
    elseif id == "start" or id == "stop" then event = { text = id }
    else event = { text = V.command(id) } end
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
  local geometry = cmd=="home" or cmd=="bottom" or cmd=="length" or cmd=="branches" or cmd=="continuous" or cmd=="mode"
  if geometry then
    if job.running then S.error="stop mining before geometry changes" return end
    for _, row in pairs(job.turtles) do
      if row.route or row.stopRoute then S.error="wait for mining routes to stop" return end
    end
  end
  if cmd=="fuel" then
    local ok, err
    if a[2]=="auto" and (a[3]=="on" or a[3]=="off") and #a==3 then ok,err=call("shop","fuelConfig",a[3]=="on")
    elseif a[2]=="output" and a[3] and #a==3 then ok,err=call("shop","fuelConfig",nil,a[3])
    else S.error="invalid fuel command" return end
    S.error=not ok and (err or "shop unavailable") or nil
    return
  elseif cmd=="home" and num(2) and num(3) and num(4) and dirs[a[5]] and #a<=6 then
    local dim = job.dim
    if a[6] then dim=P.dimension(a[6]) end
    local config=dim ~= "minecraft:overworld" and SO.store.read and SO.store.read("so-server.cfg")
    local err = P.dimensionError(dim, config) or P.heightError(dim, num(3))
    if err then S.error=err return end
    if dim~=job.dim and (job.running or next(job.turtles)) then S.error="stop and remove turtles before dimension change" return end
    if dim~=job.dim then
      job.bottom=P.dimensions[dim].bottom or -58
      job.progress, S.known, S.trailDone, S.trailOrder = {nextBranch=0,done=0}, {}, {}, {}
      S.preview, S.previewKey = nil, nil
    end
    job.dim=dim job.home={x=num(2),y=num(3),z=num(4),facing=dirs[a[5]]} job.homeSet=true
  elseif cmd=="bottom" and num(2) then
    local err=dimensionError(num(2))
    if err then S.error=err return end
    job.bottom=num(2)
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
    local forgotten=job.turtles[tostring(id)] and job.turtles[tostring(id)].forgotten
    if job.turtles[tostring(id)] and not uncertain and not forgotten then S.error="already added" return end
    if forgotten and not SO.pair.key(id) then S.error="turtle is not paired" return end
    local err=dimensionError(num(4))
    if err then S.error=err return end
    local pose={dim=job.dim,x=num(3),y=num(4),z=num(5),facing=dirs[a[6]]}
    if uncertain or forgotten then
      if uncertain then
        local ok,err=call("lease","reanchor",id,pose)
        if not ok then S.error=err return end
      end
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
    local row = job.turtles[tostring(num(2))]
    if row and M.inLane(job,row.pose) then S.error="turtle in shared lane; wait for off-lane pose" return end
    local status=call("lease","status",num(2))
    if job.turtles[tostring(num(2))] and job.turtles[tostring(num(2))].forgotten then
      S.error="device forgotten; re-pair and re-add turtle" return
    end
    if status and status.open then
      local ok = call("lease","cancelPark",num(2),"mine")
      if not ok then S.error="turtle has open lease" return end
    end
    local released, err = call("cells","releaseOwner",owner(num(2)))
    if released == false then S.error=tostring(err) return end
    if row then
      if row.counted ~= row.branch then keepBranch(row.branch or row.rebuild) end
      if row.returning then keepBranch(row.returning.branch) end
    end
    job.turtles[tostring(num(2))]=nil
    for _, peer in pairs(job.turtles) do
      if peer.state == "done" and job.running and #(job.unfinished or {}) > 0 then peer.state = "mining" end
    end
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
    for _,row in pairs(job.turtles) do row.safety=nil end
    if #(job.unfinished or {})>0 or job.continuous and (job.progress.nextBranch or 0)<(job.branches or 8) then
      for _,row in pairs(job.turtles) do if row.state=="done" then row.state="mining" end end
    end
  elseif cmd=="stop" then
    job.running=false
    for id, row in pairs(job.turtles) do
      local status=call("lease","status",tonumber(id))
      if row.route then
        if status and status.open and not call("lease","cancelPark",tonumber(id),"mine") then row.stopRoute=true
        else clearRoute(row) end
      end
    end
  else S.error="invalid mining command" return end
  if geometry and cmd ~= "branches" and cmd ~= "continuous" then
    job.progress, job.unfinished, job.digFailures, job.skipped = {nextBranch=0,done=0}, {}, {}, {}
    S.known, S.trailDone, S.trailOrder = {}, {}, {}
    for id, row in pairs(job.turtles) do
      row.branch, row.rebuild, row.index, row.counted, row.reclaimed = nil, nil, nil, nil, nil
      row.returning, row.trip, row.resumeTrip, row.veins, row.scan, row.fluid, row.yield = nil, nil, nil, nil, nil, nil, nil
      row.state = "stopped"
      releaseLane(tonumber(id),row)
    end
  end
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
  if job.dim ~= "minecraft:overworld" then rows[#rows+1]={text=job.dim} end
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
  local m = V.gather()
  m.workerPage, m.setupPage = v.workers, v.offset
  if v.page == "setup" then V.setup(m) end
  return V.layout(m, w, h, v.page == "setup", v.ores)
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
    if row.forgotten or not S.wired or row.recover or not row.frame then return false end
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
    local x, y, z = key:match("([%-0-9]+),([%-0-9]+),([%-0-9]+)$")
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
    length=job.length,mode=job.mode,branches=job.progress.nextBranch or 0,turtles={},trails={},
    running=job.running,done=job.progress.done or 0}
  local branch = job.progress.nextBranch or 0
  local occupied = false
  for id,row in pairs(job.turtles) do
    view.branches=math.max(view.branches,(row.branch or 0)+1)
    view.turtles[id]={pose=SO.store.copy(row.pose or row.anchor),state=row.state,dim=job.dim,
      branch=row.branch,lane=row.lane~=nil,ores=row.ores or 0}
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
    local done,total = U and U.branchProgress and U.branchProgress(job,row), job.length
    out[id] = {role="mining", pose=SO.store.copy(row.pose), state=row.state, fuel=row.fuel,
      inv=SO.store.copy(row.inv or {}), branch=row.branch, done=done, total=total,
      step=S.pending[tonumber(id)] and S.pending[tonumber(id)].kind, error=row.error or S.error, retry=row.dropRetry and row.dropRetry.after,
      ore=row.ores, anchor=SO.store.copy(row.anchor)}
  end
  return out
end
local function forget(id)
  local row = job.turtles[tostring(id)]
  if not row then return true end
  row.forgotten, row.state, row.error, row.recover = true, "hold", "device forgotten", true
  row.laneWait = nil
  S.pending[id], S.dugFacts[id] = nil, nil
  return save()
end
return {name="mine",forget=forget,assigned=function(id) return job.turtles[tostring(id)] ~= nil end,handlers={},turtleView=turtleView,mapView=mapView,facts=facts,dugProtection=dugProtection,forgetDug=forgetDug,tick=function()
  if not S.wired then
    local lease,display=mod("lease"),mod("display")
    if not lease or type(lease.onReport)~="function" or not display or type(display.screen)~="function" then return end
    lease.onReport("mine",report) display.screen("mining",render,input) S.wired=true
    for _,row in pairs(job.turtles) do
      -- Rows saved before counted existed were counted when they finished.
      if row.state=="done" and row.counted==nil then row.counted=row.branch end
      if not row.forgotten then row.recover=true row.state="recovering" end
    end
  end
  for id,row in pairs(job.turtles) do
    if row.state ~= "wait lane" or row.recover or not job.running
      or (row.dropRetry and row.dropRetry.after and SO.now() < row.dropRetry.after) then row.laneWait=nil end
    if not row.forgotten and row.lane and row.lane.release and not row.recover then
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
