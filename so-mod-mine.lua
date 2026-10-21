local P = dofile("so-plan.lua")
local M = dofile("so-mine-plan.lua")
local S = { wired = false, pending = {}, known = {}, error = nil }
local box = SO.store.store("so-data/mine/job", function(v) return type(v) == "table" and type(v.turtles) == "table" end)
local job = box.value or { dim = "minecraft:overworld", home = { x = 0, y = 0, z = 0, facing = 0 }, bottom = -58,
  length = 64, mode = "thorough", ores = { "diamond" }, turtles = {}, progress = { nextBranch = 0, done = 0 }, running = false }
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
  call("cells", "markDug", cell.x, cell.y, cell.z, cell.dim)
  S.known[M.key(cell)] = false
end
local function reservePose(id, row)
  local p = row.pose
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
local function trip(id, row, kind)
  local near = SO.store.copy(row.pose)
  near.dim = ({ ["minecraft:overworld"] = 0, ["minecraft:the_nether"] = -1, ["minecraft:the_end"] = 1 })[job.dim]
  if near.dim == nil then row.error = "drop dimension unsupported" return false end
  local picked = call("drops", "pick", kind, near)
  if not picked or not picked.point then row.error = picked and picked.alert or "drops: hold " .. kind row.state = "hold" return false end
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
    mark(world)
  end
  if action then
    if action.kind == "recover" then row.recover, row.error = false, nil row.state = job.running and "mining" or "stopped"
    elseif action.kind == "inspect" or action.kind == "scan" then
      local result = results[#results]
      S.known[M.key(action.cell)] = result.ok and result.data or false
      if action.kind == "scan" then
        row.scan.index = row.scan.index + 1
        if result.ok and result.data and (result.data.name == "minecraft:lava" or result.data.name == "minecraft:water") then row.fluid = action.cell end
        if result.ok and M.ore(result.data) and not call("cells", "isDug", action.cell.x, action.cell.y, action.cell.z, job.dim)
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
        S.known[M.key(action.cell)] = nil
        S.known[M.key(old)] = nil
        scan(row, row.scanAfter)
        row.scanAfter = nil
      else S.known[M.key(action.cell)] = nil row.error = results[1].err end
    elseif action.kind == "cleanup" then
      row.cleanup = #M.cleanup(row.inv,false) > 0
      if not row.cleanup then row.cleaned = row.dug or 0 end
    elseif action.kind == "unload" then row.trip.stage = "out"
    elseif action.kind == "refuel" then
      if type(row.fuel) == "number" and row.fuel >= 2000 then row.trip.stage = "back" end
    end
  end
  call("cells", "releaseOwner", owner(id)) reservePose(id, row)
  if not M.same(old, row.pose) then row.lastMove = os.epoch("utc") end
  save()
  if action and action.kind ~= "park" and action.kind ~= "recover" and job.running then plan(id,row) end
end
local function send(id, row, action)
  if #action.steps == 0 then return false end
  if not P.inRange(mod("lease"), id, action.cells or {}) then row.state, row.error = "range", "outside proven radio range" return false end
  local ok, err = call("cells", "reserveMany", owner(id), action.cells or {})
  if not ok then row.state, row.error = "waiting", err or "cells unavailable" return false end
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
  if not reservePose(id,row) then row.state = "waiting" park(id,row,false) return end
  if not P.inRange(mod("lease"),id,{row.pose}) then row.state,row.error="range","outside proven radio range" park(id,row,false) return end
  if not job.running or row.state == "done" then row.state = row.state == "done" and "done" or "stopped" park(id,row,false) return end
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
          if not M.junk(item) then
            steps[#steps+1]={op="select",slot=item.slot}
            local drop = call("drops","steps",t.point) or {}
            for _, step in ipairs(drop) do steps[#steps+1]=step end
            if #steps>=12 then break end
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
          steps={{op="select",slot=slot},{op=t.point.side=="down" and "suckDown" or "suck",n=64}}
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
  if row.fluid then
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
  if row.scan then local action=scanAction(row) if action then if not send(id,row,action) then park(id,row,false) end return end end
  if row.veins and #row.veins>0 then
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
  for id,row in pairs(job.turtles) do plan(tonumber(id),row) end
end}
