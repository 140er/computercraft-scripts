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
S.owner = function() return "lumber:" .. tostring(S.job.turtle.id) end
S.release = function()
  local cells = S.module("cells")
  if type(cells.releaseOwner) == "function" then cells.releaseOwner(S.owner()) end
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
  if not P.inRange(lease, j.turtle.id, cells) then
    j.blocked = "out of range"
    S.alert("out of range")
    return false
  end
  local reservations = S.module("cells")
  if type(reservations.reserveMany) ~= "function" then S.alert("cells unavailable") return false end
  local ok = reservations.reserveMany(S.owner(), cells)
  if not ok then S.alert("cells held") return false end
  local pose = j.turtle.pose
  for _, step in ipairs(steps) do pose = P.apply(pose, step.op) end
  local id, err = lease.send(j.turtle.id, steps, {
    owner = "lumber", recover = recover == true, ms = ms, pose = pose,
  })
  if not id then
    if err == "lost" then S.recover = true end
    S.alert("lease " .. tostring(err))
    return false
  end
  S.pending = { id = id, action = action, steps = steps, pose = j.turtle.pose }
  S.idlePark = action == "park" or action == "recover"
  if S.idlePark then S.parkAt = os.epoch("utc") end
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
  local detour = S.job.detour
  if detour then
    if not S.moveDirect(detour) then return false end
    S.job.detour = nil
    S.save()
  end
  return S.moveDirect(target)
end

S.service = function(kind, resume)
  local j = S.job
  local point
  if kind == "saplings" then
    point = j.saplings
    if point then point = { dim = j.dim, x = point.x, y = point.y, z = point.z, side = point.side } end
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
      S.alert("hold " .. kind)
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
  S.noteBlocks(pending, results)
  if report.inv then j.inv = report.inv end
  if report.fuel ~= nil then j.fuel = report.fuel end
  local action, result = pending.action, results[#results]
  local ok = true
  for _, row in ipairs(results) do if not row.ok then ok = false end end
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
    elseif action.cell.y > (j.ground or -math.huge) and L.canDig(block) then
      local dig = ({ up = "digUp", down = "digDown", forward = "dig" })[action.move]
      S.op(dig, "motion", { j.turtle.pose, action.cell })
    else
      local scan = S.route and S.route[j.cursor or 1]
      if j.phase == "scan" and not j.service and scan
        and action.cell.x == scan.x and action.cell.y == scan.y and action.cell.z == scan.z then
        j.cursor = j.cursor + 1
      elseif action.move == "forward" then
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
            if not duplicate and (not spot or os.epoch("utc") - (spot.plantedAt or 0) >= 600000) then
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
      j.spots[j.tree.x .. "," .. j.tree.z].plantedAt = os.epoch("utc")
      S.finishTree()
    elseif block then
      S.finishTree()
    else
      j.phase = "plantPlace"
    end
  elseif action == "plant" then
    if ok then j.spots[j.tree.x .. "," .. j.tree.z].plantedAt = os.epoch("utc") end
    S.finishTree()
  elseif action == "suck" then
    local service = j.service
    if service and service.kind == "saplings" then
      local desired = j.tree and L.saplingFor(j.tree.kind)
      if S.slot(function(name) return name == desired end) then
        service.stage = "return"
      elseif ok and S.empty() then
        service.stage = "suck"
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
  elseif type(action) == "table" and action.kind == "drop" then
    local after = S.count(function(name) return name:match("_log$") ~= nil end)
    local count = math.max(0, action.before - after)
    if count > 0 then
      j.logs = (j.logs or 0) + count
      S.emit("lumber.logs", { id = turtleId, count = count })
    elseif not ok then
      j.blocked = "hold"
      S.alert("hold wood")
    end
  end
  if not S.pending then S.release() end
  S.save()
end

S.workService = function()
  local j, service = S.job, S.job.service
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
    service.stage = service.kind == "wood" and "drop" or "suck"
    S.save()
  end
  if service.stage == "suck" then
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
    if not item then service.stage = "return" S.save() return end
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
  if j.phase == "roundEnd" then
    local logs = S.slot(function(name) return name:match("_log$") ~= nil end)
    if logs then S.service("wood", "waiting") else j.phase = "waiting" j.nextRound = now + 600000 S.save() end
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
  local words = {}
  for word in tostring(ev.text or ev.id or ""):gmatch("%S+") do words[#words + 1] = word end
  local j = S.job
  local function integer(i)
    local n = tonumber(words[i])
    if n and n == n and n % 1 == 0 and math.abs(n) < 30000000 then return n end
  end
  if words[1] == "stop" and #words == 1 then j.running = false
  elseif words[1] == "start" and #words == 1 then
    if not j.area or not j.turtle or not j.ground then S.alert("configure area and turtle") return end
    j.running, j.blocked, j.noSaplings, j.alert = true, nil, false, nil
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
    if j.running or S.pending then S.alert("stop before configuring") return end
    local id, x, y, z = integer(2), integer(3), integer(4), integer(5)
    local f = ({ n = 0, e = 1, s = 2, w = 3 })[words[6]]
    if not id or id < 0 or not x or not y or not z or f == nil then S.alert("invalid turtle") return end
    if j.turtle then S.release() end
    local pose = { dim = j.dim, x = x, y = y, z = z, facing = f }
    j.turtle = { id = id, anchor = pose, pose = pose }
    j.inv, j.fuel = {}, 0
    S.recover = true
  else S.alert("invalid command") return end
  S.save()
end

S.render = function()
  local j = S.job
  local known, planted = 0, 0
  for _, spot in pairs(j.spots) do known = known + 1 if (spot.plantedAt or 0) > 0 then planted = planted + 1 end end
  local state = j.blocked or (S.recover and j.turtle and "recovering") or (j.running and j.phase or "stopped")
  local rows = {}
  local function row(text, red) rows[#rows + 1] = { text = text, fg = red and "e" or "0", bg = "f" } end
  row("Lumber " .. tostring(state), j.blocked == "lost" or j.blocked == "out of range")
  row("Logs delivered " .. tostring(j.logs or 0))
  row("Saplings " .. tostring(S.count(L.isSapling)))
  row("Spots " .. known .. " planted " .. planted)
  row("Fuel " .. tostring(j.fuel or "?"))
  row("Alert " .. tostring(j.alert or "-"), j.blocked == "lost" or j.blocked == "out of range")
  return { rows = rows, buttons = { { id = "generic", x = 1, y = 8, w = 7, label = "generic" } } }
end

S.tick = function(now)
  local lease = S.module("lease")
  local display = S.module("display")
  if not S.wired and type(display.screen) == "function" then display.screen("lumber", S.render, S.input) S.wired = true end
  if not S.callback and type(lease.onReport) == "function" then lease.onReport("lumber", S.report) S.callback = true end
  local j = S.job
  if not j.turtle or not S.callback or type(lease.status) ~= "function" then return end
  local status = lease.status(j.turtle.id)
  if status.lost then S.recover = true j.blocked = "lost" end
  if S.pending or status.open then return end
  if S.recover then
    if not j.turtle.anchor and not status.pose then S.alert("waiting for reported pose") return end
    if not j.turtle.anchor and status.pose and j.turtle.frame then j.turtle.pose = P.toWorld(j.turtle.frame, status.pose) end
    S.park(true)
    return
  end
  if j.blocked or not j.running or not j.area or not j.turtle.frame then
    if not S.idlePark or not S.parkAt or now - S.parkAt >= 540000 then S.park() end
    return
  end
  if type(j.fuel) == "number" and j.fuel >= 0 and j.fuel < 80 and not j.service then
    if not S.service("fuel") then return end
  end
  S.work(now)
end

return { name = "lumber", handlers = {}, tick = S.tick }
