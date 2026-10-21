local P = dofile("so-plan.lua")
local M = dofile("so-mine-plan.lua")
local S = { wired = false, pending = {}, known = {}, dugFacts = {}, burst = { n = 0 }, error = nil }
local unloadKeep = {
  ["minecraft:bucket"] = true, ["minecraft:lava_bucket"] = true,
  ["minecraft:water_bucket"] = true, ["minecraft:torch"] = true,
}
local box = SO.store.store("so-data/mine/job", function(v) return type(v) == "table" and type(v.turtles) == "table" end)
local job = box.value or { dim = "minecraft:overworld", home = { x = 0, y = 0, z = 0, facing = 0 }, bottom = -58,
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
local function reservePose(id, row)
  local p = row.pose
  if call("cells","owner",p.x,p.y,p.z,p.dim)==owner(id) then return true end
  local ok, err = call("cells", "reserve", owner(id), p.x, p.y, p.z, p.dim)
  if not ok then row.error = err or "standing cell unavailable" end
  return ok
end
local function park(id, row, recover)
  if not recover and row.parkUntil and os.epoch("utc") < row.parkUntil - 60000 then return end
  local lid, err = call("lease", "send", id, P.park.steps, { owner = "mine", recover = recover, ms = P.park.ms, pose = row.pose })
  if lid then S.pending[id] = { kind = recover and "recover" or "park" } row.parkUntil = os.epoch("utc") + P.park.ms
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
    row.state, row.error = "hold", kind == "ore" and "ore chest full" or "fuel chest empty"
    retry.after = os.epoch("utc") + 60000
  end
end
local function trip(id, row, kind)
  local near = SO.store.copy(row.pose)
  near.dim = ({ ["minecraft:overworld"] = 0, ["minecraft:the_nether"] = -1, ["minecraft:the_end"] = 1 })[job.dim]
  if near.dim == nil then row.error = "drop dimension unsupported" return false end
  local picked = call("drops", "pick", kind, near)
  if not picked or not picked.point then
    dropFailure(id, row, kind)
    row.error = picked and picked.alert or "drops: hold " .. kind
    row.state = "hold"
    if row.dropRetry.alerted then row.error = row.error .. " " .. (kind == "ore" and "ore chest full" or "fuel chest empty") end
    save()
    return false
  end
  local point = SO.store.copy(picked.point)
  point.dim = job.dim
  local candidates = {}
  if point.side == "down" then candidates[1] = { dim = job.dim, x = point.x, y = point.y+1, z = point.z }
  else
    for f = 0, 3 do
      local p = { dim = job.dim, x = point.x, y = point.y, z = point.z, facing = f }
      local c = M.cell(p, "back") c.facing = f candidates[#candidates+1] = c
    end
    table.sort(candidates, function(a,b) return M.distance(row.pose,a) < M.distance(row.pose,b) end)
  end
  for _, stand in ipairs(candidates) do
    local held = call("cells", "owner", stand.x, stand.y, stand.z, stand.dim)
    local known = S.known[M.key(stand)]
    if (not held or held == owner(id)) and (known == nil or known == false) then
      row.trip = { kind = kind, point = point, stand = stand, back = SO.store.copy(row.pose), stage = "out" }
      row.state = kind return true
    end
  end
  row.error = "drop neighbours held" return false
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
    elseif row.lane.entered then
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
  local cells,seen={},{}
  local function add(cell)
    local key=M.key(cell)
    if not seen[key] then cells[#cells+1]=cell seen[key]=true end
  end
  for _,cell in ipairs(action.cells or {}) do add(cell) end
  local pass=needs and M.lanePass(job,row) or {}
  if needs and not row.lane then
    row.laneWait=row.laneWait or {at=os.epoch("utc"),passes=0}
    local first=id
    for other,peer in pairs(job.turtles) do
      if tonumber(other)~=id and (peer.lane or M.inLane(job,peer.pose)) then return false,"held" end
      if peer.laneWait and laneOrder(tonumber(other),first) then first=tonumber(other) end
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
local plan
local function report(_, id, results, lease)
  local row = job.turtles[tostring(id)]
  if not row then return end
  local action, interrupted = S.pending[id], row.inflight
  S.pending[id] = nil
  if not results or not lease.report or not lease.report.pose then
    row.state, row.error, row.recover = "lost", "lease expired or missing pose", true save() return
  end
  row.inflight = nil
  local facts = lease.report
  if not row.frame then row.frame = P.frame(row.anchor, facts.pose) end
  local old = row.pose
  row.pose = P.toWorld(row.frame, facts.pose)
  row.inv, row.fuel = facts.inv or row.inv or {}, facts.fuel or row.fuel
  local priorDug,nextDug=S.dugFacts[id] or {},{}
  for _, c in ipairs(facts.dug or {}) do
    local world = P.toWorld(row.frame, { x = c.x, y = c.y, z = c.z, f = 0 })
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
  if facts.dug then S.dugFacts[id]=nextDug end
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
      elseif action.kind == "cleanup" then
        row.cleanup = #M.cleanup(row.inv,false) > 0
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
        if failed then dropFailure(id, row, row.trip.kind, row.trip.point)
        else row.dropRetry, row.error = nil, nil end
        if action.kind == "unload" then row.trip.stage = "out"
        elseif type(row.fuel) == "number" and row.fuel >= 2000 then row.trip.stage = "back" end
      end
    end
  end
  releaseBatch(id,row)
  if not M.same(old, row.pose) then row.lastMove = os.epoch("utc") end
  save()
  local now=os.epoch("utc")
  if not S.burst.at or now-S.burst.at>50 then S.burst.n=0 end
  S.burst.at,S.burst.n=now,S.burst.n+1
  local limit,workers,lane=4,0,false
  for _,peer in pairs(job.turtles) do workers=workers+1 lane=lane or peer.lane~=nil end
  if lane and workers>1 then limit=2 end
  if action and action.kind~="park" and action.kind~="recover" and job.running and S.burst.n<limit
      and (not S.handoffAt or now-S.handoffAt>50) then plan(id,row) end
end
local function send(id, row, action)
  if #action.steps == 0 then return false end
  if not P.inRange(mod("lease"), id, action.cells or {}) then row.state, row.error = "range", "outside proven radio range" return false end
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
  if status.lost then row.state, row.error, row.recover = "lost", "worker beacon", true end
  if status.open then return end
  if status.lost or row.recover then
    row.state = "lost" row.recover = true park(id,row,true) return
  end
  if not row.frame then row.recover = true park(id,row,true) return end
  if row.lane and row.lane.release then return end
  if not reservePose(id,row) then row.state = "waiting" park(id,row,false) return end
  if not P.inRange(mod("lease"),id,{row.pose}) then row.state,row.error="range","outside proven radio range" park(id,row,false) return end
  if not job.running or row.state == "done" then row.state = row.state == "done" and "done" or "stopped" park(id,row,false) return end
  if row.dropRetry and row.dropRetry.after and os.epoch("utc") < row.dropRetry.after then
    park(id,row,false) return
  end
  row.inv = row.inv or {}
  local clean = M.cleanup(row.inv,false)
  if not row.trip and #clean > 0 and (row.cleanup or (row.dug or 0)-(row.cleaned or 0)>=10 or P.free(row.inv)<2) then
    send(id,row,{kind="cleanup",steps=clean,cells={}}) return
  end
  if not row.trip then
    local low = type(row.fuel)=="number" and row.fuel >= 0 and row.fuel < M.distance(row.pose,job.home)+64
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
          if value>0 then steps={{op="select",slot=item.slot},{op="refuel",n=math.min(item.count,math.max(1,math.ceil((2000-(row.fuel or 0))/value)))}} break end
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
    while row.route[row.index] and M.same(row.pose,row.route[row.index]) do row.index=row.index+1 end
    row.goal=row.route[row.index]
    if not row.goal then
      for _, item in ipairs(row.inv) do
        if not M.junk(item) and not unloadKeep[item.name] and P.fuelValue(item.name) == 0 then
          if trip(id,row,"ore") then save() plan(id,row)
          else park(id,row,false) end
          return
        end
      end
      row.state="done" job.progress.done=(job.progress.done or 0)+1
      emit("mine.progress",{level=job.bottom,branch=row.branch,done=job.progress.done}) save() park(id,row,false) return
    end
  end
  row.state="mining"
  local action=M.next(job,row,lookup,row.inv,row.fuel)
  if action.kind=="hold" then row.error=action.error row.state="hold" park(id,row,false)
  elseif not send(id,row,action) then park(id,row,false) end
end
local function input(event)
  if type(event.text)~="string" then return end
  local a={} for word in event.text:gmatch("%S+") do a[#a+1]=word end
  local cmd=a[1]
  local dirs={n=0,e=1,s=2,w=3}
  local function num(i) local n=tonumber(a[i]) if n and n%1==0 and math.abs(n)<30000000 then return n end end
  if cmd=="home" and num(2) and num(3) and num(4) and dirs[a[5]] then job.home={x=num(2),y=num(3),z=num(4),facing=dirs[a[5]]}
  elseif cmd=="bottom" and num(2) then job.bottom=num(2)
  elseif cmd=="length" and num(2) and num(2)>0 and num(2)<=4096 then job.length=num(2)
  elseif cmd=="mode" and (a[2]=="thorough" or a[2]=="fast") then job.mode=a[2]
  elseif cmd=="ores" and a[2] then
    local names={} for name in a[2]:gmatch("[^,]+") do if not M.ores[name] then S.error="unknown ore" return end names[#names+1]=name end job.ores=names
  elseif cmd=="add" and num(2) and num(2)>=0 and num(3) and num(4) and num(5) and dirs[a[6]] then
    local id=num(2) if job.turtles[tostring(id)] then S.error="already added" return end
    local pose={dim=job.dim,x=num(3),y=num(4),z=num(5),facing=dirs[a[6]]}
    job.turtles[tostring(id)]={anchor=pose,pose=pose,state="recovering",recover=true,inv={}}
    reservePose(id,job.turtles[tostring(id)]) save() park(id,job.turtles[tostring(id)],true)
  elseif cmd=="remove" and num(2) then
    local status=call("lease","status",num(2))
    if status and status.open then S.error="turtle has open lease" return end
    call("cells","releaseOwner",owner(num(2))) job.turtles[tostring(num(2))]=nil
  elseif cmd=="start" then job.running=true
  elseif cmd=="stop" then job.running=false
  else S.error="invalid mining command" return end
  save()
end
local function render()
  local rows={{text="Mining " .. (job.running and "running" or "stopped")},{text="bottom "..job.bottom.." length "..job.length.." "..job.mode}}
  if S.error then rows[#rows+1]={text=S.error,fg="e"} end
  for id,row in pairs(job.turtles) do
    local p=row.pose
    rows[#rows+1]={text=id.." "..row.state.." "..p.x..","..p.y..","..p.z.." fuel "..tostring(row.fuel or "?").." ores "..(row.ores or 0).." "..tostring(row.error or ""),fg=(row.state=="lost" or row.state=="range") and "e" or "0"}
  end
  return {rows=rows,buttons={}}
end
return {name="mine",handlers={},tick=function()
  if not S.wired then
    local lease,display=mod("lease"),mod("display")
    if not lease or type(lease.onReport)~="function" or not display or type(display.screen)~="function" then return end
    lease.onReport("mine",report) display.screen("mining",render,input) S.wired=true
    for _,row in pairs(job.turtles) do row.recover=true row.state="recovering" end
  end
  for id,row in pairs(job.turtles) do
    if row.lane and row.lane.release and not row.recover then
      local status=call("lease","status",tonumber(id))
      if status and not status.open then
        call("cells","releaseOwner",owner(tonumber(id)))
        row.lane=nil
        S.handoffAt=os.epoch("utc")
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
