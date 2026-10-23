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
S.alert = function(text)
  if S.job.alert ~= text then
    S.job.alert = text
    S.emit("lumber.alert", { text = text })
    S.save()
  end
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
  local name = result and result.ok and type(result.data) == "table" and result.data.name or nil
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
        S.alert("hold saplings chest; fix drop point and start")
        return false
      end
      point = { id = saved.id, dim = j.dim, x = point.x, y = point.y, z = point.z, side = point.side }
    end
  else
    local drops = S.module("drops")
    local near = { dim = ({ ["minecraft:overworld"] = 0, ["minecraft:the_nether"] = -1,
      ["minecraft:the_end"] = 1 })[j.dim], x = j.turtle.pose.x, y = j.turtle.pose.y, z = j.turtle.pose.z }
    local picked = near.dim ~= nil and type(drops.pick) == "function" and drops.pick(kind, near)
    point = picked and picked.point
    if point then
      point = { id = point.id, dim = j.dim, x = point.x, y = point.y, z = point.z, side = point.side, kind = point.kind }
    end
  end
  if not point then
    if kind == "saplings" then
      j.noSaplings = true
      S.alert("out of saplings")
    else
      j.blocked = "hold"
      S.alert("hold " .. kind .. "; fix chest, then start")
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
        S.alert("hold " .. j.service.kind .. " chest; fix chest and start")
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
        S.alert("out of saplings")
        service.stage = "return"
      end
    elseif service then
      service.stage = "refuel"
    end
  elseif action == "refuel" then
    if j.service then
      if not ok then j.blocked = "fuel" S.alert("no usable fuel") else j.service.stage = "return" end
    end
  elseif action == "junk" then
    if not ok then j.blocked = "hold" S.alert("junk drop failed; fix chest, then start") end
  elseif type(action) == "table" and action.kind == "drop" then
    local after = S.count(function(name) return name:match("_log$") ~= nil end)
    local count = math.max(0, action.before - after)
    if ok and inspected and result.ok and count > 0 then
      j.logs = (j.logs or 0) + count
      S.emit("lumber.logs", { id = turtleId, count = count })
    elseif not ok or not inspected then
      j.blocked = "hold"
      S.alert("hold wood; fix chest and start")
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
      S.alert("hold saplings chest; fix drop point and start")
      return
    end
    service.point.id = saved.id
  end
  if service.stage == "travel" then
    if not service.access or S.occupied(service.access) then
      service.access = L.access(service.point, j.turtle.pose, S.occupied)
      if not service.access then
        j.blocked = "hold"
        S.alert("no access to " .. service.kind .. " chest")
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
        S.alert("out of saplings")
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
    if not item then j.blocked = "fuel" S.alert("no usable fuel") return end
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
    local id = ev.id
    if id == "setup" or id == "tab:setup" then S.screen.view(ev.session).page = "setup" return end
    if id == "lumber-back" or id == "tab:overview" or id == "tab:main" then S.screen.view(ev.session).page = "main" return end
    if id ~= "start" and id ~= "stop" then return end
    text = id
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
    if not ok then S.admission = err return end
    S.admission = nil
    if not j.area or not j.turtle or not j.ground then S.alert("configure area and turtle") return end
    j.running, j.blocked, j.noSaplings, j.alert, j.failures = true, nil, false, nil, nil
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
  return { rows = rows, buttons = {} }
end

-- Route A screen (docs/ui/SCHEMATIC-SPEC.md); docs/ui/schematic/jobs.py is the twin of A.gather
-- and the layouts and writes their fixtures. Pages belong to the display session.
local A = { tabs = { "overview", "setup" }, short = { "main", "setup" }, page = "main",
  phases = { scan = "scanning", base = "felling", climb = "felling", descend = "felling", plant = "planting", plantPlace = "planting" } }
S.screen = A
A.view = function(session)
  if type(session) ~= "table" then return A end
  session.lumber = session.lumber or { page = "main" }
  return session.lumber
end
A.near = function(area, p)
  return p.x >= area.x1 - 32 and p.x <= area.x2 + 32 and p.z >= area.z1 - 32 and p.z <= area.z2 + 32
end
-- The farm, its chests, the turtle and the facts.
A.gather = function()
  local j, now = S.job, SO.now()
  local daily, drops = S.module("daily"), S.module("drops")
  local today = type(daily.today) == "function" and daily.today()
  local m = { state = j.blocked or (S.recover and j.turtle and "recovering") or (j.running and "running" or "stopped"),
    alert = S.admission or j.alert, area = j.area, ground = j.ground, spots = {}, chests = {}, ready = 0, total = 0,
    logs = today and today.logs, saplings = S.count(L.isSapling), fuel = type(j.fuel) == "number" and j.fuel or nil,
    chest = j.saplings }
  for key, spot in pairs(j.spots) do
    local ready = (spot.plantedAt or 0) == 0 or now - spot.plantedAt >= 600000
    m.total = m.total + 1
    if ready then m.ready = m.ready + 1 end
    local x, z = tostring(key):match("^(%-?%d+),(%-?%d+)$")
    if x then m.spots[#m.spots + 1] = { x = tonumber(x), z = tonumber(z), ready = ready } end
  end
  local seconds = j.nextRound and math.max(0, math.ceil((j.nextRound - now) / 1000))
  m.grow = seconds and string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
  if j.saplings then m.chests[1] = { x = j.saplings.x, z = j.saplings.z, label = "saplings", broken = false } end
  if j.area and type(drops.list) == "function" then
    for _, p in ipairs(drops.list()) do
      if p.kind == "wood" and A.near(j.area, p) then m.chests[#m.chests + 1] = { x = p.x, z = p.z, label = "wood", broken = p.broken } end
    end
  end
  if j.turtle then
    local p, lease = j.turtle.pose or j.turtle.anchor or {}, S.module("lease")
    local status = type(lease.status) == "function" and lease.status(j.turtle.id) or {}
    local word = status.lost and "lost" or j.blocked or (j.running and (A.phases[j.phase] or "working") or "idle")
    m.turtle = { id = j.turtle.id, facing = p.facing, x = p.x, y = p.y, z = p.z, state = word, tone = S.ui.tone(word) }
  end
  return m
end
A.facts = function(m)
  local fuel = m.fuel
  return { { "ready", m.ready .. "/" .. m.total, m.ready > 0 and "d" or "8" }, { "growing", tostring(m.total - m.ready), "0" },
    { "next grow", m.grow or "-", m.grow and "0" or "8" }, { "logs", m.logs and tostring(m.logs) or "-", m.logs and "0" or "8" },
    { "saplings", tostring(m.saplings), m.saplings > 0 and "0" or "e" },
    { "fuel", fuel and tostring(fuel) or "-", not fuel and "8" or fuel < 80 and "1" or "0" } }
end
A.fg = function(tone) return (tone == "1" or tone == "e" or tone == "8") and tone or "0" end
A.run = function(C, y, m, gap)
  local run = m.state == "running"
  S.ui.actions(C, y, { { "START", "start", run and "muted" or "primary" }, { "STOP", "stop", run and "stop" or "muted" } }, gap)
end
A.at = function(p) return p.x .. "," .. p.y .. "," .. p.z end
-- The farm at up to four columns per block, squeezed when it does not fit; trees, chests and the
-- turtle. Returns the last row drawn.
A.plan = function(C, m, x0, y0, pw, ph)
  local a, U = m.area, S.ui
  if not a then return y0 - 1 end
  local bx1, bx2, bz1, bz2, room = a.x1, a.x2, a.z1, a.z2, 0
  for _, c in ipairs(m.chests) do
    bx1, bx2, bz1, bz2 = math.min(bx1, c.x), math.max(bx2, c.x), math.min(bz1, c.z), math.max(bz2, c.z)
    room = math.max(room, #c.label + 1)
  end
  local num = 1
  for _, n in ipairs({ 4, 3, 2 }) do if (bx2 - bx1) * n + 1 + room <= pw then num = n break end end
  local den = math.max(1, math.ceil((bx2 - bx1 + 1) / math.max(1, pw - room)))
  local rz = (bz2 - bz1) * 2 + 1 <= ph and num >= 3 and 2 or 1
  local zd = math.max(1, math.ceil((bz2 - bz1 + 1) / math.max(1, ph)))
  local function col(x) return x0 + math.floor((x - bx1) * num / den) end
  local function row(z) return y0 + math.floor((z - bz1) * rz / zd) end
  local c1, c2, r1, r2 = col(a.x1), col(a.x2), row(a.z1), row(a.z2)
  C.rule(c1, r1, c2, "c")
  C.rule(c1, r2, c2, "c")
  for y = r1, r2 do C.put(c1, y, "|", "c") C.put(c2, y, "|", "c") end
  for _, p in ipairs({ { c1, r1 }, { c2, r1 }, { c1, r2 }, { c2, r2 } }) do C.put(p[1], p[2], "+", "c") end
  local trees = {}
  for _, s in ipairs(m.spots) do
    local key = col(s.x) .. "," .. row(s.z)
    trees[key] = trees[key] or s.ready
  end
  for key, ready in pairs(trees) do
    local x, y = key:match("^(%-?%d+),(%-?%d+)$")
    C.put(tonumber(x), tonumber(y), ready and U.g.spade or U.g.club, ready and "d" or "8")
  end
  for _, c in ipairs(m.chests) do
    local x, y = col(c.x), row(c.z)
    C.put(x, y, c.broken and U.g.cross or U.g.bullet, c.broken and "e" or "0")
    local lx = (x > c2 or x >= c1 and x + 2 + #c.label <= x0 + pw) and x + 2 or x - 1 - #c.label
    C.put(lx, y, c.label, c.broken and "e" or "8")
  end
  local t = m.turtle
  if t and t.x and t.x >= bx1 and t.x <= bx2 and t.z >= bz1 and t.z <= bz2 then
    local x, y, label = col(t.x), row(t.z), tostring(t.id)
    local function blank(cx, cy, open)
      local cell = C.cells[cy] and C.cells[cy][cx]
      if not cell then return open end
      return cell[1] == " " or open and (cell[1] == "-" or cell[1] == "|" or cell[1] == "+")
    end
    for _, at in ipairs({ { x + 1, y - 1 }, { x + 1, y + 1 } }) do
      local ok = blank(at[1] - 1, at[2], true) and blank(at[1] + #label, at[2], true)
      for i = 0, #label - 1 do ok = ok and blank(at[1] + i, at[2], false) end
      if ok then C.put(at[1], at[2], label, t.tone) break end
    end
    C.put(x, y, U.arrow(t.facing), t.tone)
  end
  return row(bz2)
end
A.turtle = function(C, m, y)
  local t = m.turtle
  if not t then return end
  C.put(2, y, S.ui.arrow(t.facing), t.tone)
  C.put(4, y, tostring(t.id), "0")
  C.put(7, y, t.state:sub(1, 10), A.fg(t.tone))
  if t.x then C.put(18, y, A.at(t):sub(1, math.max(0, C.w - 19)), "8") end
end
A.room = function(C, m)
  local w, ya, U = C.w, C.h - 1, S.ui
  U.roleBar(C, "LUMBER", A.tabs, A.short, 1, m.state, U.tone(m.state))
  local fx, facts = w - 14, A.facts(m)
  for i, f in ipairs(facts) do C.leader(fx, 2 + 2 * i, 14, f[1], f[2], f[3]) end
  local bottom = A.plan(C, m, 2, 4, math.min(fx - 5, 64), math.min(ya - 9, 32))
  A.turtle(C, m, bottom + 3)
  for y = 3, math.max(bottom + 3, 2 + 2 * #facts) do C.put(fx - 2, y, "|", "c") end
  if m.alert then C.flag(2, ya - 2, w - 2, m.alert) end
  A.run(C, ya, m, 3)
end
A.column = function(C, m)
  local w, ya, U = C.w, C.h, S.ui
  local shown = U.roleBar(C, "LUMBER", A.tabs, A.short, 1, m.state, U.tone(m.state))
  A.run(C, ya, m, 1)
  if m.alert then C.flag(2, ya - 1, w - 2, m.alert) end
  local f, last, top = A.facts(m), ya - 2 - (m.alert and 1 or 0)
  if w < 30 then
    local rows = { f[1], f[3], f[6] }
    if not shown then table.insert(rows, 1, { "state", m.state, A.fg(U.tone(m.state)) }) end
    top = last - #rows + 1
    for i, row in ipairs(rows) do C.leader(2, top + i - 1, w - 2, row[1], row[2], row[3]) end
  else
    local lw = math.floor((w - 5) / 2)
    top = last - 1
    for i, pair in ipairs({ { 1, 5 }, { 3, 6 } }) do
      local a, b = f[pair[1]], f[pair[2]]
      C.leader(2, top + i - 1, lw, a[1], a[2], a[3])
      C.leader(lw + 5, top + i - 1, w - lw - 5, b[1], b[2], b[3])
    end
  end
  A.plan(C, m, 2, 3, math.min(w - 1, 64), math.min(top - 3, 32))
end
A.tiny = function(C, m)
  local w, h, U = C.w, C.h, S.ui
  local shown = w >= 24 and U.roleBar(C, "LUMBER", A.tabs, A.short, 1, m.state, U.tone(m.state))
  if w < 24 then
    shown = w >= 12 + #m.state
    C.bar("LUMBER", {}, nil, shown and m.state or "", U.tone(m.state))
  end
  local f = A.facts(m)
  local rows = { f[1], { "grow", f[3][2], f[3][3] }, f[5], f[6], f[4] }
  if not shown then table.insert(rows, 1, { "state", m.state, A.fg(U.tone(m.state)) }) end
  local y = h >= 6 and 3 or 2
  for _, row in ipairs(rows) do
    if y > h - 2 then break end
    C.leader(2, y, w - 2, row[1], row[2], row[3])
    y = y + 1
  end
  if m.alert and h >= 4 then C.flag(2, h - 1, w - 2, m.alert) end
  A.run(C, h, m, 1)
end
A.setup = function(C, m)
  local w, h, U = C.w, C.h, S.ui
  U.roleBar(C, "LUMBER", A.tabs, A.short, 2, m.state, U.tone(m.state))
  local room = w >= 52 and h >= 22
  local ya, step, vx = room and h - 1 or h, h >= 19 and 2 or 1, w >= 36 and 13 or 11
  local a, c, t = m.area, m.chest, m.turtle
  local rows = { { "area", a and (a.x1 .. "," .. a.z1 .. " " .. a.x2 .. "," .. a.z2) or "-" },
    { "ground", m.ground and tostring(m.ground) or "-" },
    { "saplings", c and (A.at(c) .. " " .. tostring(c.side)) or "-" },
    { "turtle", t and t.x and ("#" .. t.id .. " " .. A.at(t)) or "-" } }
  -- Narrow screens put each value on its own line under its label.
  local narrow = w < 36 and h >= 14
  for i, row in ipairs(rows) do
    local y = 3 + (i - 1) * (narrow and 3 or step)
    if y + (narrow and 1 or 0) > ya - 2 then break end
    C.put(2, y, row[1], "8")
    if narrow then C.put(4, y + 1, row[2]:sub(1, w - 4), row[2] ~= "-" and "0" or "8")
    else C.put(vx, y, row[2]:sub(1, w - vx), row[2] ~= "-" and "0" or "8") end
  end
  if m.alert then C.flag(2, ya - (room and 2 or 1), w - 2, m.alert) end
  A.run(C, ya, m, room and 3 or 1)
end
A.layout = function(m, w, h, setup)
  local C = S.ui.canvas(w, h)
  if setup and w >= 24 then A.setup(C, m)
  elseif w < 24 or h < 14 then A.tiny(C, m)
  elseif w >= 52 and h >= 22 then A.room(C, m)
  else A.column(C, m) end
  return C.frame()
end
-- so-mod-panel's pocket probe reads a 120x18 frame from an id-less session: the state on row 2
-- and LABEL VALUE rows from 3 with their colour. Kept until the panel reads facts().
A.probe = function(m)
  local rows = { { text = "" }, { text = "LUMBER " .. m.state } }
  for _, f in ipairs({ { "TREES READY", tostring(m.ready), "d" }, { "SAPLINGS", tostring(m.saplings), m.saplings == 0 and "e" or "d" },
      { "NEXT GROW", m.grow or "-", m.grow and "b" or "c" },
      { "FUEL", m.fuel and tostring(m.fuel) or "-", m.fuel and (m.fuel < 80 and "1" or "d") or "c" } }) do
    rows[#rows + 1] = { text = f[1] .. " " .. f[2], runs = { { #f[1] + #f[2] + 1, "0", f[3] } } }
  end
  return { rows = rows, buttons = {} }
end
S.render = function(w, h, session)
  if not w or not h then return S.legacyRender(w) end
  if not S.ui and (not fs or not fs.exists or fs.exists("so-ui.lua")) then S.ui = dofile("so-ui.lua") end
  if not S.ui then return S.legacyRender(w) end
  if type(session) == "table" and session.id == nil and w == 120 and h == 18 then return A.probe(A.gather()) end
  return A.layout(A.gather(), w, h, A.view(session).page == "setup")
end
-- Job facts for other screens (the pocket's JOBS page); pure reads.
S.facts = function()
  if not S.ui and (not fs or not fs.exists or fs.exists("so-ui.lua")) then S.ui = dofile("so-ui.lua") end
  local m = A.gather()
  return { state = m.state, ready = m.ready, spots = m.total, grow = m.grow, saplings = m.saplings, fuel = m.fuel, alert = m.alert }
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
  local spots, now, grow = {}, SO.now(), nil
  for key, spot in pairs(j.spots) do
    if #spots >= 512 then break end
    local x, z = key:match("^(%-?%d+),(%-?%d+)$")
    if x then
      local left = (spot.plantedAt or 0) == 0 and 0 or 600000 - (now - spot.plantedAt)
      spots[#spots + 1] = { x = tonumber(x), z = tonumber(z), ready = left <= 0 }
      if left > 0 and (not grow or left < grow) then grow = left end
    end
  end
  table.sort(spots, function(a, b) return a.x < b.x or a.x == b.x and a.z < b.z end)
  return {dim=j.dim,area=SO.store.copy(j.area),ground=j.ground,saplings=SO.store.copy(j.saplings),spots=spots,
    running=j.running,grow=grow,
    turtle=j.turtle and {id=j.turtle.id,pose=SO.store.copy(j.turtle.pose),phase=j.phase,
      state=j.blocked or (j.running and "lumber" or "idle")}}
end
return { name = "lumber", handlers = {}, tick = S.tick, dugProtection = S.dugProtection, mapView = S.mapView, facts = S.facts }
