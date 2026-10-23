local P = dofile("so-plan.lua")
local L = dofile("so-lumber-plan.lua")
local S = { recover = true, pending = nil, wired = false, callback = false, route = nil }

S.valid = function(job)
  return type(job) == "table" and type(job.spots) == "table" and type(job.dim) == "string"
end
S.box = SO.store.store("so-data/lumber/job", S.valid)
S.job = S.box.value or {
  dim = "minecraft:overworld", spots = {}, running = false, phase = "scan", cursor = 1,
  logs = 0, inv = {}, fuel = 0,
}

S.module = function(name)
  local mod = SO.mods and SO.mods[name]
  return type(mod) == "table" and mod or {}
end
S.save = function()
  local ok, err = S.box.save(S.job)
  if not ok then S.job.running, S.job.alert = false, "save failed: " .. tostring(err) end
  return ok
end
S.emit = function(kind, value)
  local state = S.module("state")
  if type(state.emit) == "function" then state.emit(kind, value) end
end
S.alert = function(text, point, reason)
  if S.job.alert ~= text then
    S.job.alert = text
    S.emit("lumber.alert", { text = text, point = point, reason = reason })
    S.save()
  end
end
S.chestAlert = function(kind, reason, point)
  S.alert(P.chestError(kind, reason, point), point, reason)
end
S.readiness = function()
  local j = S.job
  local checks = {{ok=j.area ~= nil,text=j.area and "area ready" or "area not set"},{ok=j.ground ~= nil,text=j.ground and ("ground "..j.ground) or "ground not set"}}
  local drops, lease = S.module("drops"), S.module("lease")
  local points = type(drops.list)=="function" and drops.list() or {}
  local dim = ({["minecraft:overworld"]=0,["minecraft:the_nether"]=-1,["minecraft:the_end"]=1})[j.dim]
  local p = j.turtle and j.turtle.pose or {x=0,y=j.ground or 0,z=0}
  local near = {dim=dim,x=p.x,y=p.y,z=p.z}
  for _,kind in ipairs({"wood","fuel"}) do checks[#checks+1]=P.chestCheck(points,kind,near) end
  local saplings
  for _,point in ipairs(points) do
    if j.saplings and point.dim==dim and point.x==j.saplings.x and point.y==j.saplings.y
        and point.z==j.saplings.z and point.side==j.saplings.side then saplings=point break end
  end
  checks[#checks+1]={ok=j.saplings ~= nil and not (saplings and saplings.broken),
    text=not j.saplings and "no saplings chest set" or saplings and saplings.broken
      and P.chestError("saplings","broken",saplings) or "saplings chest ready"}
  local id=j.turtle and j.turtle.id
  local status=id and type(lease.status)=="function" and lease.status(id)
  local paired=id ~= nil and SO.pair and SO.pair.key(id) ~= nil and status and not status.uncertain and not status.lost
  checks[#checks+1]={ok=paired, text=paired and "paired turtle ready" or "paired turtle missing"}
  local fueled=id ~= nil and type(j.fuel)=="number" and j.fuel~=0
  checks[#checks+1]={ok=fueled,text=fueled and ("fuel "..j.fuel) or "fuel missing"}
  return checks
end
S.count = function(predicate)
  local n = 0
  for _, item in ipairs(S.job.inv or {}) do if predicate(item.name) then n = n + item.count end end
  return n
end
S.slot = function(predicate)
  for _, item in ipairs(S.job.inv or {}) do if predicate(item.name) and item.count > 0 then return item end end
end
S.empty = function()
  local occupied = {}
  for _, item in ipairs(S.job.inv or {}) do occupied[item.slot] = true end
  for slot = 1, 16 do if not occupied[slot] then return slot end end
end
S.junk = function()
  local needed = {}
  for _, spot in pairs(S.job.spots) do
    local name = L.saplingFor(spot.kind)
    if name then needed[name] = (needed[name] or 0) + 1 end
  end
  local tree = S.job.tree
  if tree then
    local name = L.saplingFor(tree.kind)
    if name then needed[name] = math.max(needed[name] or 0, 1) end
  end
  for _, item in ipairs(S.job.inv or {}) do
    if L.isSapling(item.name) then
      local keep = math.min(item.count, needed[item.name] or 0)
      needed[item.name] = math.max(0, (needed[item.name] or 0) - keep)
      if item.count > keep then return item, item.count - keep end
    elseif item.name == "minecraft:stick" or item.name == "minecraft:apple" or item.name:match("_leaves$") then
      return item, item.count
    end
  end
end
S.fuelNeed = function()
  local j, drops = S.job, S.module("drops")
  local dim = ({ ["minecraft:overworld"] = 0, ["minecraft:the_nether"] = -1, ["minecraft:the_end"] = 1 })[j.dim]
  local p = j.turtle.pose
  local picked = dim ~= nil and type(drops.pick) == "function" and drops.pick("fuel", { dim = dim, x = p.x, y = p.y, z = p.z })
  local point = picked and picked.point
  if not point then return 32 end
  local access = L.access(point, p)
  if not access then return 32 end
  local flight = j.ground + 2
  return math.abs(p.y - flight) + math.abs(p.x - access.x) + math.abs(p.z - access.z)
    + math.abs(access.y - flight) + 32
end
S.owner = function() return "lumber:" .. tostring(S.job.turtle.id) end
S.release = function()
  local cells = S.module("cells")
  if type(cells.releaseOwner) == "function" then return cells.releaseOwner(S.owner()) end
  return true
end

S.cellKey = function(p) return p.x .. "," .. p.y .. "," .. p.z end
S.occupied = function(p)
  local j = S.job
  if p.y <= j.ground or (j.obstacles or {})[S.cellKey(p)] then return true end
  for _, chest in pairs({ j.saplings, j.service and j.service.point }) do
    if p.x == chest.x and p.y == chest.y and p.z == chest.z then return true end
  end
  return p.y == j.ground + 1 and j.spots[p.x .. "," .. p.z] ~= nil
end
S.noteBlocks = function(pending, results)
  local at = pending.pose
  local directions = { inspect = "forward", inspectUp = "up", inspectDown = "down",
    dig = "forward", digUp = "up", digDown = "down" }
  local known = S.job.obstacles or {}
  S.job.obstacles = known
  for i, step in ipairs(pending.steps) do
    local result, dir = results[i], directions[step.op]
    if dir then
      local x, y, z = P.ahead(at, dir)
      local key = S.cellKey({ x = x, y = y, z = z })
      if step.op:match("^inspect") then known[key] = result.ok and result.data ~= nil or nil
      elseif result.ok then known[key] = nil end
    end
    if result.ok then at = P.apply(at, step.op) end
  end
end

S.send = function(steps, action, cells, recover, ms)
  local j, lease = S.job, S.module("lease")
  if not j.turtle or type(lease.send) ~= "function" or type(lease.status) ~= "function" then return false end
  if S.pending or lease.status(j.turtle.id).open then return false end
  cells = cells or { j.turtle.pose }
  local at = j.turtle.pose
  local directions = { inspect = "forward", dig = "forward", place = "forward", drop = "forward", suck = "forward",
    inspectUp = "up", digUp = "up", placeUp = "up", inspectDown = "down", digDown = "down",
    placeDown = "down", dropDown = "down", suckDown = "down" }
  for _, step in ipairs(steps) do
    local direction = directions[step.op]
    if direction then
      local x, y, z = P.ahead(at, direction)
      cells[#cells + 1] = { dim = j.dim, x = x, y = y, z = z }
    end
    at = P.apply(at, step.op)
    if step.op == "forward" or step.op == "up" or step.op == "down" or step.op == "back" then
      cells[#cells + 1] = { dim = j.dim, x = at.x, y = at.y, z = at.z }
    end
  end
  if not recover and not P.rangeBatch(lease, j.turtle.id, { steps = steps, cells = cells }) then
    j.blocked = "out of range"
    S.idlePark, S.parkAt = nil, nil
    S.alert("out of range")
    return false
  end
  local reservations = S.module("cells")
  if type(reservations.reserveMany) ~= "function" then
    j.blocked = "hold"
    S.idlePark, S.parkAt = nil, nil
    S.alert("cells unavailable")
    return false
  end
  local ok = reservations.reserveMany(S.owner(), cells)
  if not ok then
    j.blocked = "hold"
    S.idlePark, S.parkAt = nil, nil
    S.alert("cells held")
    return false
  end
  local pose = j.turtle.pose
  for _, step in ipairs(steps) do pose = P.apply(pose, step.op) end
  local id, err = lease.send(j.turtle.id, steps, {
    owner = "lumber", recover = recover == true, ms = ms, pose = pose,
  })
  if not id then
    S.release()
    S.idlePark, S.parkAt = nil, nil
    j.blocked = "hold"
    if err == "lost" then S.recover = true end
    S.alert("lease " .. tostring(err))
    return false
  end
  S.pending = { id = id, action = action, steps = steps, pose = j.turtle.pose }
  S.idlePark = action == "park" or action == "recover"
  if S.idlePark then S.parkAt = SO.now() end
  return true
end
S.op = function(op, action, cells)
  return S.send({ { op = op } }, action, cells)
end
S.park = function(recover)
  return S.send(P.park.steps, recover and "recover" or "park", nil, recover, P.park.ms)
end

S.moveDirect = function(target)
  local p = S.job.turtle.pose
  if p.x == target.x and p.y == target.y and p.z == target.z then
    if target.facing ~= nil and p.facing ~= target.facing then
      local d = (target.facing - p.facing) % 4
      S.op(d == 3 and "turnLeft" or "turnRight", "motion")
      return false
    end
    return true
  end
  local path = P.path(p, target)
  local step = path.steps[1]
  if step.op == "turnLeft" or step.op == "turnRight" then S.op(step.op, "motion") return false end
  local x, y, z = P.ahead(p, step.op)
  local cell = { dim = p.dim, x = x, y = y, z = z }
  local inspect = ({ up = "inspectUp", down = "inspectDown", forward = "inspect" })[step.op]
  S.send({ { op = inspect } }, { kind = "path", move = step.op, cell = cell }, { p, cell })
  return false
end

S.move = function(target)
  if S.job.service then
    if S.job.detour then S.job.detour = nil S.save() end
    local waypoint = L.travel(S.job.turtle.pose, target, S.job.ground)
    if not S.moveDirect(waypoint) then return false end
    return S.moveDirect(target)
  end
  local detour = S.job.detour
  if detour then
    if not S.moveDirect(detour) then return false end
    S.job.detour = nil
    S.save()
  end
  return S.moveDirect(target)
end

S.saplingPoint = function(point)
  local drops = S.module("drops")
  local dim = ({ ["minecraft:overworld"] = 0, ["minecraft:the_nether"] = -1,
    ["minecraft:the_end"] = 1 })[S.job.dim]
  if dim == nil or type(drops.list) ~= "function" or type(drops.add) ~= "function" then return nil end
  for _, saved in ipairs(drops.list()) do
    if saved.dim == dim and saved.x == point.x and saved.y == point.y and saved.z == point.z
      and saved.side == point.side then return saved end
  end
  local saved = { id = table.concat({ "lumber_saplings", dim, point.x, point.y, point.z, point.side }, "_"),
    dim = dim, x = point.x, y = point.y, z = point.z, side = point.side, kind = "storage" }
  if drops.add(saved) then return saved end
end
S.noteChest = function(point, result)
  local name = P.chestPresent(result) and result.data.name or nil
  local drops = S.module("drops")
  if point and point.id and type(drops.note) == "function" then drops.note(point.id, name) end
  return type(name) == "string" and name ~= ""
end

S.service = function(kind, resume)
  local j = S.job
  local point
  if kind == "saplings" then
    point = j.saplings
    if point then
      local saved = S.saplingPoint(point)
      if not saved or saved.broken then
        j.blocked = "hold"
        S.chestAlert("saplings", saved and "broken" or "unavailable", saved or point)
        return false
      end
      point = { id = saved.id, dim = j.dim, x = point.x, y = point.y, z = point.z, side = point.side }
    end
  else
    local drops = S.module("drops")
    local near = { dim = ({ ["minecraft:overworld"] = 0, ["minecraft:the_nether"] = -1,
      ["minecraft:the_end"] = 1 })[j.dim], x = j.turtle.pose.x, y = j.turtle.pose.y, z = j.turtle.pose.z }
    local picked = near.dim ~= nil and type(drops.pick) == "function" and drops.pick(kind, near)
    if not picked or not picked.point then
      j.blocked = "hold"
      S.chestAlert(kind, picked and picked.reason or "none", picked and picked.failedPoint)
      return false
    end
    point = picked.point
    if point then
      point = { id = point.id, dim = j.dim, x = point.x, y = point.y, z = point.z, side = point.side, kind = point.kind }
    end
  end
  if not point then
    if kind == "saplings" then
      j.noSaplings = true
      S.chestAlert("saplings", "none")
    else
      j.blocked = "hold"
      S.chestAlert(kind, "none")
    end
    return false
  end
  local p = j.turtle.pose
  j.service = {
    kind = kind, point = point, resume = resume or j.phase, stage = "travel",
    back = { dim = p.dim, x = p.x, y = p.y, z = p.z, facing = p.facing },
  }
  S.save()
  return true
end

S.finishTree = function()
  local j = S.job
  j.tree = nil
  if not j.probing then j.cursor = (j.cursor or 1) + 1 end
  j.probing = nil
  j.phase = "scan"
  S.save()
end

S.report = function(id, turtleId, results, lease)
  local j, pending = S.job, S.pending
  if not j.turtle or turtleId ~= j.turtle.id then return end
  if not pending or pending.id ~= id then return end
  S.pending = nil
  if not results then
    S.recover = true
    j.blocked = "lost"
    S.alert("lost lease")
    return
  end
  local report = lease.report or {}
  if report.pose then
    if j.turtle.anchor then
      j.turtle.frame = P.frame(j.turtle.anchor, report.pose)
      j.turtle.anchor = nil
    end
    if j.turtle.frame then j.turtle.pose = P.toWorld(j.turtle.frame, report.pose) end
  else
    S.recover = true
    S.alert("missing pose")
    return
  end
  local cells = S.module("cells")
  if j.turtle.frame and type(cells.markDug) == "function" and type(cells.isDug) == "function" then
    local history = {}
    for _, cell in ipairs(report.dug or {}) do
      local world = P.toWorld(j.turtle.frame, { x = cell.x, y = cell.y, z = cell.z, f = 0 })
      history[#history + 1] = world
      if not cells.isDug(world.x, world.y, world.z, world.dim) then
        cells.markDug(world.x, world.y, world.z, world.dim)
      end
    end
    if report.dug and type(cells.rememberWorker) == "function" then cells.rememberWorker(turtleId, j.turtle.pose, history) end
  end
  local inspected
  if pending.action == "junk" or type(pending.action) == "table" and pending.action.kind == "drop" then
    inspected = S.noteChest(j.service and j.service.point, results[2])
  end
  S.noteBlocks(pending, results)
  if report.inv then j.inv = report.inv end
  if report.fuel ~= nil then j.fuel = report.fuel end
  local action, result = pending.action, results[#results]
  local ok = true
  for _, row in ipairs(results) do if not row.ok then ok = false end end
  local attempted, failed
  for i, step in ipairs(pending.steps) do
    if step.op == "forward" or step.op == "back" or step.op == "up" or step.op == "down"
      or step.op == "turnLeft" or step.op == "turnRight" or step.op:match("^dig") then
      attempted = true
      if not results[i] or not results[i].ok then failed = step.op end
    end
  end
  if attempted then
    if failed then
      j.failures = (j.failures or 0) + 1
      if j.failures >= 3 then
        j.blocked = "hold"
        S.alert(failed .. " failed; fix cause, then start")
      end
    else j.failures = nil end
  end
  if failed then
    if not S.pending then S.release() end
    S.save()
    return
  end
  if action == "recover" then
    S.recover = false
    j.blocked = nil
    S.release()
  elseif type(action) == "table" and action.kind == "path" then
    local block = result.ok and result.data or nil
    if not block then
      S.op(action.move, "motion", { j.turtle.pose, action.cell })
    elseif j.service and j.service.stage == "travel" and j.service.access
      and S.cellKey(action.cell) == S.cellKey(j.service.access) then
      j.service.access, j.detour = nil, nil
    elseif action.cell.y > (j.ground or -math.huge)
      and (not j.service or action.cell.y > j.ground + 1) and L.canDig(block) then
      local dig = ({ up = "digUp", down = "digDown", forward = "dig" })[action.move]
      S.op(dig, "motion", { j.turtle.pose, action.cell })
    else
      local scan = S.route and S.route[j.cursor or 1]
      if j.phase == "scan" and not j.service and scan
        and action.cell.x == scan.x and action.cell.y == scan.y and action.cell.z == scan.z then
        j.cursor = j.cursor + 1
      elseif action.move == "forward" and not j.service then
        local target = j.service and (j.service.stage == "return" and j.service.back or j.service.access) or scan
        if target then
          j.detour = { dim = j.dim, x = target.x, y = j.turtle.pose.y + 1, z = target.z }
        else
          j.blocked = "blocked"
          S.alert("blocked by " .. tostring(block.name))
        end
      else
        j.blocked = "blocked"
        S.alert("blocked by " .. tostring(block.name))
      end
    end
  elseif action == "scan" or action == "scanCandidate" then
    if action == "scan" then
      j.candidates = j.candidates or {}
      local p = j.turtle.pose
      for _, side in ipairs({ { i = 2, op = "turnLeft" }, { i = 5, op = "turnRight" } }) do
        local seen = results[side.i]
        if seen and seen.ok and L.isLog(seen.data) then
          local x, _, z = P.ahead(P.apply(p, side.op), "forward")
          if x >= j.area.x1 and x <= j.area.x2 and z >= j.area.z1 and z <= j.area.z2 then
            local duplicate = false
            for _, candidate in ipairs(j.candidates) do if candidate.x == x and candidate.z == z then duplicate = true end end
            local spot = j.spots[x .. "," .. z]
            if not duplicate and (not spot or SO.now() - (spot.plantedAt or 0) >= 600000) then
              j.candidates[#j.candidates + 1] = { dim = j.dim, x = x, y = j.ground + 2, z = z }
            end
          end
        end
      end
    end
    local block = result.ok and result.data or nil
    local p = j.turtle.pose
    local key = p.x .. "," .. p.z
    local spot = j.spots[key]
    if L.isLog(block) then
      j.spots[key] = { kind = block.name, plantedAt = spot and spot.plantedAt or 0 }
      j.tree = { x = p.x, z = p.z, kind = block.name }
      j.phase = "base"
    elseif spot and not block and not j.noSaplings then
      j.tree = { x = p.x, z = p.z, kind = spot.kind }
      j.phase = "plant"
    else
      if not j.probing then j.cursor = j.cursor + 1 end
      j.probing = nil
    end
  elseif action == "baseCheck" then
    if result.ok and L.isLog(result.data) then
      S.op("digDown", "base")
    else
      j.phase = "climb"
    end
  elseif action == "base" then
    if ok then j.phase = "climb" else j.phase = "base" end
  elseif action == "climb" then
    if result.ok and L.isLog(result.data) then
      local p = j.turtle.pose
      local cell = { dim = j.dim, x = p.x, y = p.y + 1, z = p.z }
      S.send({ { op = "digUp" }, { op = "up" } }, "ascend", { p, cell })
    else
      j.phase = "descend"
    end
  elseif action == "plantCheck" then
    local block = result.ok and result.data or nil
    if block and L.isSapling(block.name) then
      j.spots[j.tree.x .. "," .. j.tree.z].plantedAt = SO.now()
      S.finishTree()
    elseif block then
      S.finishTree()
    else
      j.phase = "plantPlace"
    end
  elseif action == "plant" then
    if ok then j.spots[j.tree.x .. "," .. j.tree.z].plantedAt = SO.now() end
    S.finishTree()
  elseif action == "supplyCheck" then
    if j.service then
      if S.noteChest(j.service.point, result) then
        j.service.stage = "take"
      else
        j.blocked = "hold"
        S.chestAlert(j.service.kind, "broken", j.service.point)
      end
    end
  elseif action == "suck" then
    local service = j.service
    if service and service.kind == "saplings" then
      local desired = j.tree and L.saplingFor(j.tree.kind)
      if S.slot(function(name) return name == desired end) then
        service.stage = "return"
      elseif ok and S.empty() then
        service.stage = "check"
      else
        j.noSaplings = true
        S.chestAlert("saplings", ok and "wrong saplings; inventory full" or P.transferFailure("saplings",result), service.point)
        service.stage = "return"
      end
    elseif service then
      if not ok then j.blocked="fuel" S.chestAlert("fuel",P.transferFailure("fuel",result),service.point)
      else service.stage = "refuel" end
    end
  elseif action == "refuel" then
    if j.service then
      if not ok then j.blocked = "fuel" S.chestAlert("fuel", "no usable fuel", j.service.point) else j.service.stage = "return" end
    end
  elseif action == "junk" then
    if not ok then j.blocked = "hold" S.chestAlert("wood", inspected and P.transferFailure("wood",result) or "broken", j.service.point) end
  elseif type(action) == "table" and action.kind == "drop" then
    local after = S.count(function(name) return name:match("_log$") ~= nil end)
    local count = math.max(0, action.before - after)
    if ok and inspected and result.ok and count > 0 then
      j.logs = (j.logs or 0) + count
      S.emit("lumber.logs", { id = turtleId, count = count })
    elseif not ok or not inspected then
      j.blocked = "hold"
      S.chestAlert("wood", inspected and P.transferFailure("wood",result) or "broken", j.service.point)
    end
  end
  if not S.pending then S.release() end
  S.save()
end

S.workService = function()
  local j, service = S.job, S.job.service
  if service.kind == "saplings" and not service.point.id then
    local saved = S.saplingPoint(service.point)
    if not saved or saved.broken then
      j.blocked = "hold"
      S.chestAlert("saplings", saved and "broken" or "unavailable", saved or service.point)
      return
    end
    service.point.id = saved.id
  end
  if service.stage == "travel" then
    if not service.access or S.occupied(service.access) then
      service.access = L.access(service.point, j.turtle.pose, S.occupied)
      if not service.access then
        j.blocked = "hold"
        S.chestAlert(service.kind, "unreachable", service.point)
        return
      end
      S.save()
    end
    if not S.move(service.access) then return end
    service.stage = service.kind == "wood" and "drop" or "check"
    S.save()
  end
  if service.stage == "check" or service.stage == "suck" then
    service.stage = "check"
    S.op(service.point.side == "down" and "inspectDown" or "inspect", "supplyCheck")
  elseif service.stage == "take" then
    local slot = S.empty()
    if not slot then
      if service.kind == "saplings" then
        j.noSaplings, service.stage = true, "return"
        S.alert("inventory full")
      else
        j.blocked = "full"
        S.alert("inventory full")
      end
      return
    end
    S.send({ { op = "select", slot = slot }, { op = service.point.side == "down" and "suckDown" or "suck" } }, "suck")
  elseif service.stage == "drop" then
    local item = S.slot(function(name) return name:match("_log$") ~= nil end)
    if not item then
      local junk, count = S.junk()
      if junk then
        S.send({ { op = "select", slot = junk.slot },
          { op = service.point.side == "down" and "inspectDown" or "inspect" },
          { op = service.point.side == "down" and "dropDown" or "drop", n = count } }, "junk")
        return
      end
      service.stage = "return" S.save() return
    end
    local drops = S.module("drops")
    if type(drops.steps) ~= "function" then S.alert("drops unavailable") return end
    local steps = drops.steps(service.point)
    if #steps < 2 then S.alert("invalid wood drop") return end
    S.send({ { op = "select", slot = item.slot }, steps[1], steps[2] }, {
      kind = "drop", before = S.count(function(name) return name:match("_log$") ~= nil end),
    })
  elseif service.stage == "refuel" then
    local item = S.slot(function(name) return P.fuelValue(name) > 0 end)
    if not item then j.blocked = "fuel" S.chestAlert("fuel", "no usable fuel", service.point) return end
    S.send({ { op = "select", slot = item.slot }, { op = "refuel", n = item.count } }, "refuel")
  elseif service.stage == "return" then
    if service.back and not S.move(service.back) then return end
    j.phase = service.resume
    j.service = nil
    S.save()
  end
end

S.work = function(now)
  local j = S.job
  if j.service then S.workService() return end
  if P.free(j.inv or {}) < 3 and (S.junk() or S.slot(function(name) return name:match("_log$") ~= nil end)) then S.service("wood") return end
  if j.phase == "roundEnd" then
    local logs = S.slot(function(name) return name:match("_log$") ~= nil end)
    if logs or S.junk() then S.service("wood", "waiting") else j.phase = "waiting" j.nextRound = now + 600000 S.save() end
    return
  end
  if j.phase == "waiting" then
    if not j.nextRound then j.nextRound = now + 600000 S.save() end
    if now < j.nextRound then
      if not S.idlePark or not S.parkAt or now - S.parkAt >= 540000 then S.park() end
      return
    end
    j.phase, j.cursor, j.nextRound = "scan", 1, nil
    S.route = nil
    S.save()
  end
  if j.phase == "scan" then
    if P.free(j.inv or {}) < 3 and S.slot(function(name) return name:match("_log$") ~= nil end) then S.service("wood") return end
    S.route = S.route or L.scan(j.area, j.ground, j.dim)
    local target = j.probing or S.route[j.cursor or 1]
    if not j.probing and j.candidates and #j.candidates > 0 then
      j.probing = table.remove(j.candidates, 1)
      target = j.probing
      S.save()
    end
    if not target then j.phase = "roundEnd" S.save() return end
    if not S.move(target) then return end
    if j.probing then S.op("inspectDown", "scanCandidate") return end
    S.send({
      { op = "turnLeft" }, { op = "inspect" }, { op = "turnRight" },
      { op = "turnRight" }, { op = "inspect" }, { op = "turnLeft" }, { op = "inspectDown" },
    }, "scan")
  elseif j.phase == "base" then
    if not S.move({ dim = j.dim, x = j.tree.x, y = j.ground + 2, z = j.tree.z }) then return end
    S.op("inspectDown", "baseCheck")
  elseif j.phase == "climb" then
    if not S.move({ dim = j.dim, x = j.tree.x, y = math.max(j.ground + 2, j.turtle.pose.y), z = j.tree.z }) then return end
    if j.turtle.pose.y > j.ground + 64 then j.phase = "descend" S.alert("tree too tall") S.save() return end
    S.op("inspectUp", "climb")
  elseif j.phase == "descend" then
    if S.move({ dim = j.dim, x = j.tree.x, y = j.ground + 2, z = j.tree.z }) then j.phase = "plant" S.save() end
  elseif j.phase == "plant" or j.phase == "plantPlace" then
    if j.noSaplings then S.finishTree() return end
    local desired = L.saplingFor(j.tree.kind)
    local item = S.slot(function(name) return name == desired end)
    if not item then
      if not S.service("saplings") then S.finishTree() end
      return
    end
    local target = { dim = j.dim, x = j.tree.x, y = j.ground + 2, z = j.tree.z }
    if not S.move(target) then return end
    if j.phase == "plant" then S.op("inspectDown", "plantCheck")
    else S.send({ { op = "select", slot = item.slot }, { op = "placeDown" } }, "plant") end
  end
end

S.input = function(ev)
  if type(ev) ~= "table" then return end
  local text = ev.text
  if text == nil then
    if ev.id == "setup" then S.setup, S.setupPage = true, 0 return end
    if ev.id == "setup-next" then S.setupPage = (S.setupPage or 0) + 1 return end
    if ev.id == "lumber-back" then S.setup = false return end
    if ev.id ~= "start" and ev.id ~= "stop" then return end
    text = ev.id
  end
  local words = {}
  for word in tostring(text):gmatch("%S+") do words[#words + 1] = word end
  local j = S.job
  local function integer(i)
    local n = tonumber(words[i])
    if n and n == n and n % 1 == 0 and math.abs(n) < 30000000 then return n end
  end
  if words[1] == "stop" and #words == 1 then j.running = false
  elseif words[1] == "start" and #words == 1 then
    local state = S.module("state")
    local ok, err = false, "disk guard unavailable"
    if type(state.canStart) == "function" then ok, err = state.canStart() end
    if not ok then S.admission = err S.emit("lumber.alert",{text=err}) return end
    S.admission = nil
    local missing=P.missing(S.readiness())
    if #missing>0 then S.alert(table.concat(missing,"; ")) return end
    j.running, j.blocked, j.noSaplings, j.alert, j.failures = true, nil, false, nil, nil
    if type(state.get)=="function" and state.get("lumber.alert") then S.emit("lumber.alert",false) end
    S.recover = true
  elseif words[1] == "area" and #words == 6 then
    if j.running or S.pending then S.alert("stop before configuring") return end
    local x1, z1, x2, z2, ground = integer(2), integer(3), integer(4), integer(5), integer(6)
    if not x1 or not z1 or not x2 or not z2 or not ground or math.abs(x2 - x1) > 127 or math.abs(z2 - z1) > 127 then S.alert("invalid area") return end
    j.area = { x1 = math.min(x1, x2), z1 = math.min(z1, z2), x2 = math.max(x1, x2), z2 = math.max(z1, z2) }
    j.ground, j.cursor, j.phase, j.tree, j.service = ground, 1, "scan", nil, nil
    j.candidates, j.probing, j.detour, j.spots, j.nextRound = {}, nil, nil, {}, nil
    S.route = nil
  elseif words[1] == "saplings" and #words == 5 then
    local x, y, z = integer(2), integer(3), integer(4)
    if not x or not y or not z or (words[5] ~= "front" and words[5] ~= "down") then S.alert("invalid sapling chest") return end
    j.saplings = { x = x, y = y, z = z, side = words[5] }
    j.noSaplings = false
  elseif words[1] == "add" and #words == 6 then
    local id, x, y, z = integer(2), integer(3), integer(4), integer(5)
    local f = ({ n = 0, e = 1, s = 2, w = 3 })[words[6]]
    if not id or id < 0 or not x or not y or not z or f == nil then S.alert("invalid turtle") return end
    local lease = S.module("lease")
    local status = type(lease.status) == "function" and lease.status(id) or {}
    local reanchor = status.uncertain and j.turtle and j.turtle.id == id
    if (j.running or S.pending) and not reanchor then S.alert("stop before configuring") return end
    if j.turtle and not reanchor then
      local lease = S.module("lease")
      if type(lease.status) ~= "function" or lease.status(j.turtle.id).open then
        S.alert("old turtle has open lease; retry add after report")
        return
      end
      if j.turtle.id ~= id and (S.recover or not S.idlePark) then
        S.park(S.recover)
        S.alert("parking old turtle; retry add after report")
        return
      end
    end
    S.idlePark, S.parkAt = nil, nil
    local pose = { dim = j.dim, x = x, y = y, z = z, facing = f }
    if status.uncertain then
      local ok, err = lease.reanchor(id, pose)
      if not ok then S.alert(err) return end
      S.pending, S.idlePark, S.parkAt = nil, nil, nil
      j.blocked, j.alert, j.tree, j.service = nil, nil, nil, nil
      j.phase = "scan"
    end
    if j.turtle then
      local released, err = S.release()
      if released == false then S.alert("save failed: " .. tostring(err)) return end
    end
    j.turtle = { id = id, anchor = pose, pose = pose }
    j.inv, j.fuel = {}, 0
    S.recover = true
  else S.alert("invalid command") return end
  S.save()
end

S.legacyRender = function(w)
  local j = S.job
  local known, planted = 0, 0
  for _, spot in pairs(j.spots) do known = known + 1 if (spot.plantedAt or 0) > 0 then planted = planted + 1 end end
  local state = j.blocked or (S.recover and j.turtle and "recovering") or (j.running and j.phase or "stopped")
  local rows = {}
  local function row(text, red) rows[#rows + 1] = { text = text, fg = red and "e" or "0", bg = "f" } end
  if j.blocked == "pose uncertain" then
    local text = "pose uncertain: re-add turtle " .. j.turtle.id
    if (w or 51) < #text then row("pose uncertain:",true) row("re-add turtle "..j.turtle.id,true)
    else row(text,true) end
  else row("Lumber " .. tostring(state), j.blocked == "lost" or j.blocked == "out of range") end
  row("Logs delivered " .. tostring(j.logs or 0))
  row("Saplings " .. tostring(S.count(L.isSapling)))
  row("Spots " .. known .. " planted " .. planted)
  row("Fuel " .. tostring(j.fuel or "?"))
  row(S.admission or ("Alert " .. tostring(j.alert or "-")), S.admission ~= nil or j.blocked ~= nil)
  if j.blocked then row("Fix cause, then type start", true) end
  return { rows = rows, buttons = { { id = "generic", x = 1, y = 8, w = 7, label = "generic" } } }
end

S.gather = function()
  local j, known, ready = S.job, 0, 0
  local daily = S.module("daily")
  local today = type(daily.today) == "function" and daily.today()
  local now = SO.now()
  for _, spot in pairs(j.spots) do
    known = known + 1
    if (spot.plantedAt or 0) == 0 or now - spot.plantedAt >= 600000 then ready = ready + 1 end
  end
  local saplings = S.count(L.isSapling)
  local seconds = j.nextRound and math.max(0, math.ceil((j.nextRound - now) / 1000))
  local grow = seconds and string.format("%d:%02d", math.floor(seconds / 60), seconds % 60) or "-"
  local function point(p)
    return p and (p.x .. "," .. p.y .. "," .. p.z .. " " .. (p.side or "")) or "-"
  end
  return {
    state = j.blocked or (S.recover and j.turtle and "recovering") or (j.running and "running" or "stopped"),
    alert = S.admission or j.alert, setup = S.setup, setupPage = S.setupPage,
    readiness = S.readiness(),
    details = {
      "AREA " .. (j.area and (j.area.x1 .. "," .. j.area.z1 .. " to " .. j.area.x2 .. "," .. j.area.z2) or "-"),
      "GROUND " .. tostring(j.ground or "-"), "SAPLINGS " .. point(j.saplings),
      "TURTLE " .. (j.turtle and (j.turtle.id .. " at " .. point(j.turtle.pose)) or "-"),
    },
    tiles = {
      {"TREES READY", tostring(ready), "of " .. known .. " spots", "d"},
      {"LOGS TODAY", today and tostring(today.logs) or "-", today and "" or "no daily source", today and "d" or "c"},
      {"SAPLINGS", tostring(saplings), "", saplings == 0 and "e" or "d"},
      {"TURTLE", j.turtle and tostring(j.turtle.id) or "-", j.phase or "-", j.turtle and "d" or "c"},
      {"FUEL", tostring(j.fuel or "-"), type(j.fuel) == "number" and (j.fuel < 80 and "low" or "ok") or "no source", j.fuel and (type(j.fuel) == "number" and j.fuel < 80 and "1" or "d") or "c"},
      {"NEXT GROW", grow, seconds and "" or "no timer", seconds and "b" or "c"},
    },
  }
end

S.layout = function(model, w, h)
  local U = S.ui
  local C = U.canvas(w, h)
  C.header("LUMBER", model.state)
  local compact = w < 39 or h < 20
  local navRows = w < 26 and 2 or 1
  local bottom = compact and math.max(1, h - navRows + 1) or h - 3
  if model.setup then
    local lines = {}
    for _, check in ipairs(model.readiness) do lines[#lines+1]={text=check.text,bg=check.ok and "d" or "e"} end
    for _, line in ipairs(model.details) do
      for first = 1, #line, math.max(1, w - 2) do
        lines[#lines + 1] = {text=line:sub(first, first + math.max(1, w - 2) - 1),bg="f"}
      end
    end
    local count = math.max(1, bottom - 3)
    local pages = math.ceil(#lines / count)
    local offset = ((model.setupPage or 0) % math.max(1, pages)) * count
    for i = 1, count do
      if lines[offset + i] and i + 2 < bottom then
        local line=lines[offset+i]
        C.fill(1,i+2,w,1,line.bg)
        C.put(2,i+2,line.text:sub(1,math.max(0,w-2)),U.ink(line.bg),line.bg)
      end
    end
    local left = 1
    if pages > 1 then
      local width = math.max(1, math.floor(w / 2))
      C.button(1, bottom, width, "NEXT", "setup-next", "7", compact and 1 or 3)
      left = width + 1
    end
    C.button(left, bottom, w - left + 1, "BACK", "lumber-back", "7", compact and 1 or 3)
  else
    local cols, rows = U.grid(w, h)
    if compact then
      for i, t in ipairs(model.tiles) do
        if i + 2 < bottom then
          C.fill(1, i + 2, w, 1, t[4])
          C.put(2, i + 2, (t[1] .. " " .. t[2]):sub(1, w-2), U.ink(t[4]), t[4])
        end
      end
    else
      for i, t in ipairs(model.tiles) do
        local row = math.floor((i - 1) / #cols)
        if row < rows then
          local col = cols[(i - 1) % #cols + 1]
          C.tile(col.x, 4 + row * 8, col.w, unpack(t))
        end
      end
    end
    local buttons = U.grid(w, h, w < 26 and 2 or 4)
    if w == 57 and h == 24 then buttons = {{x=1,w=13},{x=15,w=13},{x=29,w=14},{x=44,w=14}} end
    for i, b in ipairs({{"START", "start", "9"}, {"STOP", "stop", "e"}, {"SETUP", "setup", "7"}, {"BACK", "status", "7"}}) do
      local col = buttons[(i - 1) % #buttons + 1]
      local y = bottom + (w < 26 and math.floor((i - 1) / 2) or 0)
      C.button(col.x, y, col.w, b[1], b[2], b[3], compact and 1 or 3)
    end
  end
  if not model.setup then
    local count=#C.buttons
    C.alert(model.alert and ("! " .. model.alert))
    if #C.buttons>count then table.insert(C.buttons,1,table.remove(C.buttons)) end
  end
  return C.frame()
end

S.render = function(w, h)
  if not w or not h then return S.legacyRender(w) end
  if not S.ui and (not fs or not fs.exists or fs.exists("so-ui.lua")) then S.ui = dofile("so-ui.lua") end
  if not S.ui then return S.legacyRender(w) end
  return S.layout(S.gather(), w, h)
end

S.tick = function(now)
  local lease = S.module("lease")
  local display = S.module("display")
  if not S.wired and type(display.screen) == "function" then display.screen("lumber", S.render, S.input) S.wired = true end
  if not S.callback and type(lease.onReport) == "function" then lease.onReport("lumber", S.report) S.callback = true end
  local j = S.job
  if not j.turtle or not S.callback or type(lease.status) ~= "function" then return end
  local status = lease.status(j.turtle.id)
  if status.uncertain then
    j.blocked = "pose uncertain"
    S.alert("pose uncertain: re-add turtle " .. j.turtle.id)
    return
  end
  if status.lost then S.recover = true j.blocked = "lost" end
  if S.pending or status.open then return end
  if S.recover then
    if not j.turtle.frame and not j.turtle.anchor then S.alert("waiting for reported pose") return end
    S.park(true)
    return
  end
  if j.blocked or not j.running or not j.area or not j.turtle.frame then
    if not S.idlePark or not S.parkAt or now - S.parkAt >= 540000 then S.park() end
    return
  end
  if type(j.fuel) == "number" and j.fuel >= 0 and j.fuel < S.fuelNeed() and not j.service then
    if not S.service("fuel") then return end
  end
  S.work(now)
end

S.dugProtection = function(protect)
  local j = S.job
  if j.turtle then
    if S.recover or not j.turtle.frame then return false end
    protect(j.dim, j, 48)
    if S.pending then protect(j.dim, S.pending, 48) end
  end
  if j.running and j.area then
    protect(j.dim, { { x=j.area.x1, y=-math.huge, z=j.area.z1 },
      { x=j.area.x2, y=math.huge, z=j.area.z2 } }, 1)
  end
  return true
end

S.mapView = function()
  local j = S.job
  return {dim=j.dim,area=SO.store.copy(j.area),ground=j.ground,saplings=SO.store.copy(j.saplings),
    turtle=j.turtle and {id=j.turtle.id,pose=SO.store.copy(j.turtle.pose),
      state=j.blocked or (j.running and "lumber" or "idle")}}
end
return { name = "lumber", handlers = {}, tick = S.tick, dugProtection = S.dugProtection, mapView = S.mapView }
