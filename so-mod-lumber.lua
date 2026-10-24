local P = dofile("so-plan.lua")
local L = dofile("so-lumber-plan.lua")
local S = { wired = false, callback = false }

S.possible = function(previous, flight)
  local out, seen = {}, {}
  local function add(p)
    local key = p.x .. "," .. p.y .. "," .. p.z
    if not seen[key] then out[#out + 1], seen[key] = p, true end
  end
  for _, p in ipairs(previous or {}) do add(p) end
  local at = flight.pose
  add(at)
  for _, step in ipairs(flight.steps) do
    at = P.apply(at, step.op)
    if step.op == "forward" or step.op == "back" or step.op == "up" or step.op == "down" then add(at) end
  end
  return out
end

S.valid = function(job)
  return type(job) == "table" and type(job.spots) == "table" and type(job.dim) == "string"
end
S.box = SO.store.store("so-data/lumber/job", S.valid)
S.job = S.box.value or { dim = "minecraft:overworld", spots = {}, running = false, logs = 0 }
S.job.turtles = S.job.turtles or {}
if S.job.turtle then
  local row = {}
  for _, key in ipairs({ "turtle", "phase", "cursor", "inv", "fuel", "tree", "service", "probing",
    "detour", "blocked", "alert", "failures", "noSaplings", "fuelRetry" }) do
    row[key], S.job[key] = S.job[key], nil
  end
  S.job.turtles[tostring(row.turtle.id)] = row
end
for _, row in pairs(S.job.turtles) do
  if row.inflight then row.uncertain = S.possible(row.uncertain, row.inflight) end
  row.recover, row.pending, row.motion = true, nil, nil
end
S.job.visited = S.job.visited or {}
S.job.candidates = S.job.candidates or {}
S.rows = function()
  local rows = {}
  for _, row in pairs(S.job.turtles) do rows[#rows + 1] = row end
  table.sort(rows, function(a, b) return a.turtle.id < b.turtle.id end)
  return rows
end
S.anyPending = function()
  for _, row in pairs(S.job.turtles) do if row.pending then return true end end
  return false
end

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
  if type(state.emit) == "function" then return state.emit(kind, value) end
end
S.alert = function(text, point, reason)
  local target = S.row or S.job
  if target.alert ~= text then
    target.alert = text
    S.emit("lumber.alert", { id = S.row and S.row.turtle.id, text = text, point = point, reason = reason })
    S.save()
  end
end
S.clearAlert = function()
  local state=S.module("state")
  local active=S.job.alert or S.admission or state.get and state.get("lumber.alert")
  S.job.alert,S.admission=nil,nil
  if active then S.emit("lumber.alert",false) end
end
S.chestAlert = function(kind, reason, point)
  if kind == "fuel" and reason == "empty" then
    local shop = S.module("shop")
    if shop.fuelEmpty and shop.fuelEmpty(point) then S.row.fuelRetry = SO.now() + 60000 end
  end
  S.alert(P.chestError(kind, reason, point), point, reason)
end
S.autoFuel = function()
  local shop = S.module("shop")
  local policy = shop.fuelConfig and shop.fuelConfig()
  return policy and policy.auto == true, policy
end
S.fuelWait = function(reason)
  local j = S.row
  j.blocked = "fuel"
  if S.autoFuel() then j.fuelRetry = SO.now() + 60000 end
  S.chestAlert("fuel",reason,j.service.point)
end
S.fuelItem = function()
  return S.slot(function(name) return P.fuelValue(name) > 0 end)
end
S.takenItem = function()
  local service = S.row.service
  for _, item in ipairs(S.row.inv or {}) do
    if service and item.slot == service.takeSlot and item.count > 0 then return item end
  end
end
S.rememberFuelPickup = function()
  local item = S.takenItem()
  if not item or P.fuelValue(item.name) > 0 then return false end
  local service = S.row.service
  service.rejected = service.rejected or {}
  service.rejected[tostring(item.slot)] = item.name
  service.takeSlot = nil
  return true
end
S.rejectedItem = function()
  local rejected = S.row.service and S.row.service.rejected or {}
  for _, item in ipairs(S.row.inv or {}) do
    if rejected and rejected[tostring(item.slot)] == item.name and item.count > 0 and P.fuelValue(item.name) == 0 then return item end
  end
end
S.acceptFuel = function()
  if not S.fuelItem() then return false end
  local j, shop = S.row, S.module("shop")
  local taken = S.takenItem()
  if taken and P.fuelValue(taken.name) > 0 and shop.fuelAvailable then
    shop.fuelAvailable(j.service.point,j.service.takeOrder or false)
  end
  j.fuelRetry, j.service.takeSlot, j.service.takeOrder = nil, nil, nil
  j.service.stage = S.rejectedItem() and "returnFuelItem" or "refuel"
  return true
end
S.readiness = function()
  local j = S.job
  local checks = {{ok=j.area ~= nil,text=j.area and "area ready" or "area not set"},{ok=j.ground ~= nil,text=j.ground and ("ground "..j.ground) or "ground not set"}}
  local drops, lease = S.module("drops"), S.module("lease")
  local points = type(drops.list)=="function" and drops.list() or {}
  local dim = ({["minecraft:overworld"]=0,["minecraft:the_nether"]=-1,["minecraft:the_end"]=1})[j.dim]
  local first = S.rows()[1]
  local p = first and first.turtle.pose or {x=0,y=j.ground or 0,z=0}
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
  local rows, paired, fueled = S.rows(), true, true
  for _, row in ipairs(rows) do
    local id = row.turtle.id
    local status = type(lease.status)=="function" and lease.status(id)
    paired = paired and SO.pair and SO.pair.key(id) ~= nil and status and not status.uncertain and not status.lost
    fueled = fueled and type(row.fuel)=="number" and row.fuel~=0
  end
  paired, fueled = #rows > 0 and paired, #rows > 0 and fueled
  checks[#checks+1]={ok=paired, text=paired and "paired turtle ready" or "paired turtle missing"}
  checks[#checks+1]={ok=fueled,text=fueled and (#rows == 1 and ("fuel "..rows[1].fuel) or "fuel ready") or "fuel missing"}
  return checks
end
S.count = function(predicate)
  local n = 0
  for _, item in ipairs(S.row.inv or {}) do if predicate(item.name) then n = n + item.count end end
  return n
end
S.slot = function(predicate)
  for _, item in ipairs(S.row.inv or {}) do if predicate(item.name) and item.count > 0 then return item end end
end
S.empty = function()
  local occupied = {}
  for _, item in ipairs(S.row.inv or {}) do occupied[item.slot] = true end
  for slot = 1, 16 do if not occupied[slot] then return slot end end
end
S.junk = function()
  local needed = {}
  for _, spot in pairs(S.job.spots) do
    local name = L.saplingFor(spot.kind)
    if name then needed[name] = (needed[name] or 0) + 1 end
  end
  local tree = S.row.tree
  if tree then
    local name = L.saplingFor(tree.kind)
    if name then needed[name] = math.max(needed[name] or 0, 1) end
  end
  for _, item in ipairs(S.row.inv or {}) do
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
  local j, drops = S.row, S.module("drops")
  local dim = S.dropDim()
  local p = j.turtle.pose
  local picked = dim ~= nil and type(drops.pick) == "function" and drops.pick("fuel", { dim = dim, x = p.x, y = p.y, z = p.z })
  local point = picked and picked.point
  if not point then return 32 end
  local access = L.access(point, p)
  if not access then return 32 end
  local flight = S.job.ground + 2
  return math.abs(p.y - flight) + math.abs(p.x - access.x) + math.abs(p.z - access.z)
    + math.abs(access.y - flight) + 32
end
S.owner = function() return "lumber:" .. tostring(S.row.turtle.id) end
S.release = function()
  local cells = S.module("cells")
  if type(cells.releaseOwner) == "function" then return cells.releaseOwner(S.owner()) end
  return true
end

S.cellKey = function(p) return p.x .. "," .. p.y .. "," .. p.z end
S.occupied = function(p)
  if p.y <= S.job.ground or (S.job.obstacles or {})[S.cellKey(p)] then return true end
  local chests = { S.job.saplings }
  for _, row in pairs(S.job.turtles) do
    if row.service then chests[#chests + 1] = row.service.point end
  end
  local drops = S.module("drops")
  for _, point in ipairs(type(drops.list) == "function" and drops.list() or {}) do
    if point.dim == S.dropDim() then chests[#chests + 1] = point end
  end
  for _, chest in pairs(chests) do
    if p.x == chest.x and p.y == chest.y and p.z == chest.z then return true end
  end
  return p.y == S.job.ground + 1 and S.job.spots[p.x .. "," .. p.z] ~= nil
end
S.dropDim = function()
  return ({ ["minecraft:overworld"] = 0, ["minecraft:the_nether"] = -1, ["minecraft:the_end"] = 1 })[S.job.dim]
end
S.claimed = function(p, except)
  for _, row in pairs(S.job.turtles) do
    local target = row.tree or row.target
    if row ~= except and target and target.x == p.x and target.z == p.z then return true end
  end
  return false
end
S.busy = function(p, allowedOwner)
  local cells = S.module("cells")
  local owner = type(cells.owner) == "function" and cells.owner(p.x, p.y, p.z, S.job.dim)
  if owner and owner ~= S.owner() and owner ~= allowedOwner then return true end
  for _, row in pairs(S.job.turtles) do
    local at = row.turtle.pose
    if row ~= S.row and at and at.x == p.x and at.y == p.y and at.z == p.z then return true end
    local target = row.tree or row.target
    if row ~= S.row and target and target.x == p.x and target.z == p.z
      and p.y >= S.job.ground + 1 and p.y <= S.job.ground + 65 then return true end
  end
  return false
end
S.positions = function(row)
  local possible = row.uncertain or { row.turtle.pose }
  if row.inflight then return S.possible(possible, row.inflight) end
  return possible
end
S.keep = function()
  local row, keep = S.row, {}
  local function add(p)
    if p then keep[#keep + 1] = { dim = S.job.dim, x = p.x, y = p.y, z = p.z } end
  end
  add(row.turtle.pose)
  if row.target then add(row.target) end
  if row.tree then
    add({ x = row.tree.x, y = S.job.ground + 1, z = row.tree.z })
    add({ x = row.tree.x, y = S.job.ground + 2, z = row.tree.z })
  end
  if row.service and row.service.lane then
    for _, cell in ipairs(row.service.lane) do add(cell) end
  end
  if row.motion and row.motion.cell then add(row.motion.cell) end
  for _, p in ipairs(S.positions(row)) do add(p) end
  return keep
end
S.prune = function()
  local cells, keep = S.module("cells"), S.keep()
  if type(cells.list) ~= "function" or type(cells.release) ~= "function" then return S.release() end
  local keys = {}
  for _, p in ipairs(keep) do keys[S.cellKey(p)] = true end
  for _, p in ipairs(cells.list(S.owner(), 4096)) do
    if not keys[S.cellKey(p)] then
      local ok, err = cells.release(S.owner(), p.x, p.y, p.z, p.dim)
      if ok == false then S.alert("save failed: " .. tostring(err)) return false end
    end
  end
  return cells.reserveMany(S.owner(), keep)
end
S.suspendService = function()
  local row, cells = S.row, S.module("cells")
  local service = row.service
  if not service or service.suspended then return end
  local possible = S.positions(row)
  for _, p in ipairs(possible) do
    for _, cell in ipairs(service.lane or {}) do
      if S.cellKey(p) == S.cellKey(cell) then return end
    end
  end
  service.ticket, service.lane, service.suspended = nil, nil, true
  if type(cells.list) == "function" then S.prune() end
  S.save()
end
S.creditDelivery = function(count)
  local row, job, state = S.row, S.job, S.module("state")
  local delivery = row.delivery
  job.receipts = job.receipts or {}
  local last = type(state.get) == "function" and state.get("lumber.logs")
  if type(last) == "table" and type(last.receipts) == "table" then
    for id, seq in pairs(last.receipts) do job.receipts[id] = math.max(job.receipts[id] or 0, seq) end
    job.logs = math.max(job.logs or 0, last.total or 0)
  end
  local id = tostring(row.turtle.id)
  if delivery and (job.receipts[id] or 0) >= delivery.seq then row.delivery = nil return true end
  if count > 0 then
    local receipts = {}
    for key, value in pairs(job.receipts) do receipts[key] = value end
    receipts[id] = delivery.seq
    local total = (job.logs or 0) + count
    if S.emit("lumber.logs", { id = row.turtle.id, count = count, receipts = receipts, total = total }) == false then
      row.blocked = "hold"
      S.alert("delivery count not saved; start to retry")
      return false
    end
    job.receipts, job.logs = receipts, total
  end
  row.delivery = nil
  return true
end
S.claimTarget = function()
  local row, job, cells = S.row, S.job, S.module("cells")
  if type(cells.reserveMany) ~= "function" then row.blocked = "hold" S.alert("cells unavailable") return false end
  S.route = S.route or L.scan(job.area, job.ground, job.dim)
  local best, distance, candidateIndex
  local function consider(p, index, candidate)
    if not S.claimed(p, row) and not S.busy(p) then
      local d = L.distance(row.turtle.pose, p)
      if not distance or d < distance then
        best = { dim = job.dim, x = p.x, y = p.y, z = p.z, facing = p.facing, index = index }
        distance, candidateIndex = d, candidate
      end
    end
  end
  for index, p in ipairs(job.candidates) do consider(p, nil, index) end
  for index, p in ipairs(S.route) do if not job.visited[index] then consider(p, index) end end
  if not best or not cells.reserveMany(S.owner(), {best}) then return false end
  row.target, row.probing = best, candidateIndex ~= nil or nil
  if candidateIndex then table.remove(job.candidates, candidateIndex) end
  S.save()
  return true
end
S.chestKey = function(point)
  return S.job.dim .. ":" .. S.cellKey(point)
end
S.queueService = function()
  local row, cells = S.row, S.module("cells")
  local service = row.service
  if service.stage == "return" then return true end
  if not service.ticket then
    S.job.ticket = (S.job.ticket or 0) + 1
    service.ticket = S.job.ticket
    S.save()
  end
  if not service.access or S.occupied(service.access) then
    service.access = L.access(service.point, row.turtle.pose, S.occupied)
    if not service.access then return true end
  end
  local p, at = service.access, row.turtle.pose
  local occupying = service.lane or at.x == p.x and at.z == p.z
    and at.y >= math.min(p.y, S.job.ground + 2) and at.y <= math.max(p.y, S.job.ground + 3)
  for _, other in pairs(S.job.turtles) do
    local trip = other.service
    if other ~= row and trip and not trip.suspended and S.chestKey(trip.point) == S.chestKey(service.point)
      and (trip.lane or not occupying and trip.stage ~= "return" and trip.ticket and trip.ticket < service.ticket) then
      row.wait = "wait chest"
      return false
    end
  end
  if not service.lane and type(cells.reserveMany) == "function" then
    local p = service.access
    local lane = { { dim = S.job.dim, x = service.point.x, y = service.point.y, z = service.point.z } }
    for y = math.min(p.y, S.job.ground + 2), math.max(p.y, S.job.ground + 3) do
      lane[#lane + 1] = { dim = S.job.dim, x = p.x, y = y, z = p.z }
    end
    if not P.inRange(S.module("lease"), row.turtle.id, lane) then return true end
    for _, cell in ipairs(lane) do if S.busy(cell) then row.wait = "wait chest" return false end end
    if not cells.reserveMany(S.owner(), lane) then row.wait = "wait chest" return false end
    service.lane = lane
    S.save()
  end
  row.wait = nil
  return true
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
  local j, lease = S.row, S.module("lease")
  if not j.turtle or type(lease.send) ~= "function" or type(lease.status) ~= "function" then return false end
  if S.row.pending or lease.status(j.turtle.id).open then return false end
  cells = cells or { j.turtle.pose }
  local at = j.turtle.pose
  local directions = { inspect = "forward", dig = "forward", place = "forward", drop = "forward", suck = "forward",
    inspectUp = "up", digUp = "up", placeUp = "up", inspectDown = "down", digDown = "down",
    placeDown = "down", dropDown = "down", suckDown = "down" }
  for _, step in ipairs(steps) do
    local direction = directions[step.op]
    if direction then
      local x, y, z = P.ahead(at, direction)
      cells[#cells + 1] = { dim = S.job.dim, x = x, y = y, z = z }
    end
    at = P.apply(at, step.op)
    if step.op == "forward" or step.op == "up" or step.op == "down" or step.op == "back" then
      cells[#cells + 1] = { dim = S.job.dim, x = at.x, y = at.y, z = at.z }
    end
  end
  if not recover and not P.rangeBatch(lease, j.turtle.id, { steps = steps, cells = cells }) then
    j.blocked = "out of range"
    S.row.idlePark, S.row.parkAt = nil, nil
    S.alert("out of range")
    return false
  end
  local reservations = S.module("cells")
  if type(reservations.reserveMany) ~= "function" then
    j.blocked = "hold"
    S.row.idlePark, S.row.parkAt = nil, nil
    S.alert("cells unavailable")
    return false
  end
  local ok, reason, held = reservations.reserveMany(S.owner(), cells)
  if not ok and reason == "held" and held then
    local who = type(reservations.owner) == "function" and reservations.owner(held.x, held.y, held.z, held.dim)
    if type(who) == "string" and who:match("^lumber:") then j.wait = "wait cells" return false end
  end
  if not ok then
    j.blocked = "hold"
    S.row.idlePark, S.row.parkAt = nil, nil
    S.alert("cells held")
    return false
  end
  j.wait = nil
  local pose = j.turtle.pose
  for _, step in ipairs(steps) do pose = P.apply(pose, step.op) end
  j.inflight = { pose = j.turtle.pose, steps = steps }
  if not S.save() then S.prune() return false end
  local id, err = lease.send(j.turtle.id, steps, {
    owner = "lumber", recover = recover == true, ms = ms, pose = pose,
  })
  if not id then
    j.inflight = nil
    S.prune()
    S.row.idlePark, S.row.parkAt = nil, nil
    j.blocked = "hold"
    if err == "lost" then S.row.recover = true end
    S.alert("lease " .. tostring(err))
    return false
  end
  S.row.pending = { id = id, action = action, steps = steps, pose = j.turtle.pose }
  S.row.idlePark = action == "park" or action == "recover"
  if S.row.idlePark then S.row.parkAt = SO.now() end
  return true
end
S.op = function(op, action, cells)
  return S.send({ { op = op } }, action, cells)
end
S.park = function(recover)
  return S.send(P.park.steps, recover and "recover" or "park", nil, recover, P.park.ms)
end

S.follow = function(motion)
  if S.row.paused then return end
  if #S.rows() > 1 then S.row.motion = motion return end
  return S.send(motion.steps or { { op = motion.op } }, motion.action or "motion",
    motion.cell and { S.row.turtle.pose, motion.cell })
end

S.moveDirect = function(target)
  local p = S.row.turtle.pose
  if p.x == target.x and p.y == target.y and p.z == target.z then
    if target.facing ~= nil and p.facing ~= target.facing then
      local d = (target.facing - p.facing) % 4
      S.op(d == 3 and "turnLeft" or "turnRight", "motion")
      return false
    end
    return true
  end
  if #S.rows() > 1 then
    local goal = target
    local nextCell = L.nextCell(p, goal, S.job.ground, function(cell)
      return S.busy(cell) or (S.cellKey(cell) ~= S.cellKey(goal) and S.occupied(cell))
    end)
    if not nextCell then S.row.wait = "wait cells" return false end
    S.row.wait = nil
    target = nextCell
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
  if S.row.service and #S.rows() > 1 then return S.moveDirect(target) end
  if S.row.service then
    if S.row.detour then S.row.detour = nil S.save() end
    local waypoint = L.travel(S.row.turtle.pose, target, S.job.ground)
    if not S.moveDirect(waypoint) then return false end
    return S.moveDirect(target)
  end
  local detour = S.row.detour
  if detour then
    if not S.moveDirect(detour) then return false end
    S.row.detour = nil
    S.save()
  end
  return S.moveDirect(target)
end

S.saplingPoint = function(point)
  local drops = S.module("drops")
  local dim = S.dropDim()
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
  local j = S.row
  local point
  if kind == "saplings" then
    point = S.job.saplings
    if point then
      local saved = S.saplingPoint(point)
      if not saved or saved.broken then
        j.blocked = "hold"
        S.chestAlert("saplings", saved and "broken" or "unavailable", saved or point)
        return false
      end
      point = { id = saved.id, dim = S.job.dim, x = point.x, y = point.y, z = point.z, side = point.side }
    end
  else
    local drops = S.module("drops")
    local near = { dim = S.dropDim(), x = j.turtle.pose.x, y = j.turtle.pose.y, z = j.turtle.pose.z }
    local picked = near.dim ~= nil and type(drops.pick) == "function" and drops.pick(kind, near)
    if not picked or not picked.point then
      j.blocked = "hold"
      S.chestAlert(kind, picked and picked.reason or "none", picked and picked.failedPoint)
      return false
    end
    point = picked.point
    if point then
      point = { id = point.id, dim = S.job.dim, x = point.x, y = point.y, z = point.z, side = point.side, kind = point.kind }
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

S.finishTarget = function()
  local row = S.row
  if row.target and row.target.index then S.job.visited[row.target.index] = true end
  row.target, row.tree, row.probing, row.detour = nil, nil, nil, nil
  row.phase = "scan"
  S.save()
end

S.report = function(id, turtleId, results, lease)
  S.row = S.job.turtles[tostring(turtleId)]
  if not S.row then return end
  local j, pending = S.row, S.row.pending
  if not pending or pending.id ~= id then return end
  S.row.pending = nil
  if not results then
    j.uncertain = S.possible(j.uncertain, pending)
    S.row.recover, j.motion = true, nil
    j.blocked = "lost"
    S.suspendService()
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
    S.row.recover = true
    j.uncertain = S.possible(j.uncertain, pending)
    S.suspendService()
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
  if pending.action == "junk" or pending.action == "returnFuelItem" or type(pending.action) == "table" and pending.action.kind == "dropCheck" then
    inspected = S.noteChest(j.service and j.service.point, results[2])
  end
  j.inflight = nil
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
    if not S.row.pending then S.prune() end
    S.save()
    return
  end
  if action == "recover" then
    if j.delivery then
      if not report.inv then S.alert("missing inventory") S.save() return end
      local after = S.count(function(name) return name:match("_log$") ~= nil end)
      if not S.creditDelivery(math.max(0, j.delivery.before - after)) then S.save() return end
      if j.service then j.service.stage = "drop" end
    end
    S.row.recover, j.uncertain = false, nil
    if j.service then j.service.suspended = nil end
    j.blocked = nil
    S.prune()
  elseif type(action) == "table" and action.kind == "path" then
    local block = result.ok and result.data or nil
    if not block then
      S.follow({ op = action.move, cell = action.cell })
    elseif j.service and j.service.stage == "travel" and j.service.access
      and S.cellKey(action.cell) == S.cellKey(j.service.access) then
      j.service.access, j.service.lane, j.detour = nil, nil, nil
    elseif action.cell.y > (S.job.ground or -math.huge)
      and (not j.service or action.cell.y > S.job.ground + 1) and L.canDig(block) then
      local dig = ({ up = "digUp", down = "digDown", forward = "dig" })[action.move]
      S.follow({ op = dig, cell = action.cell })
    else
      local scan = j.target
      if j.phase == "scan" and not j.service and scan
        and action.cell.x == scan.x and action.cell.y == scan.y and action.cell.z == scan.z then
        S.finishTarget()
      elseif action.move == "forward" and not j.service then
        local target = j.service and (j.service.stage == "return" and j.service.back or j.service.access) or scan
        if target then
          j.detour = { dim = S.job.dim, x = target.x, y = j.turtle.pose.y + 1, z = target.z }
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
      S.job.candidates = S.job.candidates or {}
      local p = j.turtle.pose
      for _, side in ipairs({ { i = 2, op = "turnLeft" }, { i = 5, op = "turnRight" } }) do
        local seen = results[side.i]
        if seen and seen.ok and L.isLog(seen.data) then
          local x, _, z = P.ahead(P.apply(p, side.op), "forward")
          if x >= S.job.area.x1 and x <= S.job.area.x2 and z >= S.job.area.z1 and z <= S.job.area.z2 then
            local duplicate = false
            for _, candidate in ipairs(S.job.candidates) do if candidate.x == x and candidate.z == z then duplicate = true end end
            local spot = S.job.spots[x .. "," .. z]
            if not duplicate and (not spot or SO.now() - (spot.plantedAt or 0) >= 600000) then
              S.job.candidates[#S.job.candidates + 1] = { dim = S.job.dim, x = x, y = S.job.ground + 2, z = z }
            end
          end
        end
      end
    end
    local block = result.ok and result.data or nil
    local p = j.turtle.pose
    local key = p.x .. "," .. p.z
    local spot = S.job.spots[key]
    if L.isLog(block) and not S.claimed(p, j) then
      S.job.spots[key] = { kind = block.name, plantedAt = spot and spot.plantedAt or 0 }
      j.tree = { x = p.x, z = p.z, kind = block.name }
      j.phase = "base"
    elseif spot and not block and not j.noSaplings and not S.claimed(p, j) then
      j.tree = { x = p.x, z = p.z, kind = spot.kind }
      j.phase = "plant"
    else
      S.finishTarget()
    end
  elseif action == "baseCheck" then
    if result.ok and L.isLog(result.data) then
      S.follow({ op = "digDown", action = "base" })
    else
      j.phase = "climb"
    end
  elseif action == "base" then
    if ok then j.phase = "climb" else j.phase = "base" end
  elseif action == "climb" then
    if result.ok and L.isLog(result.data) then
      local p = j.turtle.pose
      local cell = { dim = S.job.dim, x = p.x, y = p.y + 1, z = p.z }
      S.follow({ steps = { { op = "digUp" }, { op = "up" } }, action = "ascend", cell = cell })
    else
      j.phase = "descend"
    end
  elseif action == "plantCheck" then
    local block = result.ok and result.data or nil
    if block and L.isSapling(block.name) then
      S.job.spots[j.tree.x .. "," .. j.tree.z].plantedAt = SO.now()
      S.finishTarget()
    elseif block then
      S.finishTarget()
    else
      j.phase = "plantPlace"
    end
  elseif action == "plant" then
    if ok then S.job.spots[j.tree.x .. "," .. j.tree.z].plantedAt = SO.now() end
    S.finishTarget()
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
        service.stage = #S.rows() > 1 and "restock" or "return"
      elseif ok and S.empty() then
        service.stage = "check"
      else
        j.noSaplings = true
        S.chestAlert("saplings", ok and "wrong saplings; inventory full" or P.transferFailure("saplings",result), service.point)
        service.stage = "restock"
      end
    elseif service then
      if not ok then j.blocked="fuel" S.chestAlert("fuel",P.transferFailure("fuel",result),service.point)
      else
        local rejected = S.rememberFuelPickup()
        if not S.acceptFuel() then
          service.stage = "check"
          S.fuelWait(rejected and "non-fuel items" or "no usable fuel")
        end
      end
    end
  elseif action == "returnFuelItem" then
    if ok and inspected then
      local slot = pending.steps[1].slot
      local remaining
      for _, item in ipairs(j.inv or {}) do if item.slot == slot and item.count > 0 then remaining = true end end
      if not remaining then j.service.rejected[tostring(slot)] = nil end
    else S.fuelWait(not inspected and "broken" or "non-fuel return failed") end
  elseif action == "restock" then
    if not ok then j.blocked = "hold" S.alert("sapling return failed") end
  elseif action == "refuel" then
    if j.service then
      if not ok then S.fuelWait("no usable fuel") else j.service.stage = "return" end
    end
  elseif action == "junk" then
    if not ok then j.blocked = "hold" S.chestAlert("wood", inspected and P.transferFailure("wood",result) or "broken", j.service.point) end
  elseif type(action) == "table" and action.kind == "dropCheck" then
    if ok and inspected then
      S.job.deliverySeq = (S.job.deliverySeq or 0) + 1
      j.delivery = { seq = S.job.deliverySeq, before = action.before, slot = action.slot, step = action.step }
      j.service.stage = "deliver"
    else
      j.blocked = "hold"
      S.chestAlert("wood", inspected and P.transferFailure("wood",result) or "broken", j.service.point)
    end
  elseif type(action) == "table" and action.kind == "drop" then
    local after = S.count(function(name) return name:match("_log$") ~= nil end)
    local count = math.max(0, action.before - after)
    if ok and report.inv and result.ok then
      S.creditDelivery(count)
    else
      j.delivery = nil
      j.blocked = "hold"
      S.chestAlert("wood", P.transferFailure("wood",result), j.service.point)
    end
    if not j.delivery and j.service then j.service.stage = "drop" end

  end
  if j.paused then j.motion = nil end
  if not S.row.pending then S.prune() end
  S.save()
end

S.workService = function()
  local j, service = S.row, S.row.service
  if service.stage == "return" and service.lane and service.access
    and (j.turtle.pose.x ~= service.access.x or j.turtle.pose.z ~= service.access.z) then
    service.lane, service.ticket = nil, nil
    S.prune()
    S.save()
  end
  if not S.queueService() then return end
  if service.kind == "saplings" and not service.point.id then
    local saved = S.saplingPoint(service.point)
    if not saved or saved.broken then
      j.blocked = "hold"
      S.chestAlert("saplings", saved and "broken" or "unavailable", saved or service.point)
      return
    end
    service.point.id = saved.id
  end
  if service.kind == "fuel" and service.stage ~= "travel" and service.stage ~= "return" then
    local rejected = S.rememberFuelPickup()
    if not S.acceptFuel() and rejected then service.stage = "check" S.fuelWait("non-fuel items") return end
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
      elseif service.kind == "fuel" and S.autoFuel() then S.fuelWait("inventory full")
      else
        j.blocked = "full"
        S.alert("inventory full")
      end
      return
    end
    if service.kind == "fuel" then
      service.takeSlot, service.takeOrder = nil, nil
      local auto, policy = S.autoFuel()
      if auto then
        service.takeSlot = slot
        service.takeOrder = policy.waiting and policy.waiting.rid or false
        if not S.save() then return end
      end
    end
    S.send({ { op = "select", slot = slot }, { op = service.point.side == "down" and "suckDown" or "suck", n = service.kind == "saplings" and 64 or 8 } }, "suck")
  elseif service.stage == "restock" then
    local desired = j.tree and L.saplingFor(j.tree.kind)
    for _, item in ipairs(j.inv or {}) do
      if L.isSapling(item.name) then
        local count = item.count - (item.name == desired and 1 or 0)
        if count > 0 then
          S.send({ { op = "select", slot = item.slot },
            { op = service.point.side == "down" and "dropDown" or "drop", n = count } }, "restock")
          return
        end
      end
    end
    service.stage = "return"
    S.save()
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
    S.send({ { op = "select", slot = item.slot }, steps[1] }, {
      kind = "dropCheck", slot = item.slot, step = steps[2],
      before = S.count(function(name) return name:match("_log$") ~= nil end),
    })
  elseif service.stage == "deliver" then
    if not j.delivery then service.stage = "drop" S.save() return end
    S.send({ { op = "select", slot = j.delivery.slot }, j.delivery.step }, {
      kind = "drop", before = j.delivery.before,
    })
  elseif service.stage == "returnFuelItem" then
    if service.access and not S.move(service.access) then return end
    local item = S.rejectedItem()
    if not item then service.rejected, service.stage = nil, "refuel" return end
    S.send({{op="select",slot=item.slot},
      {op=service.point.side == "down" and "inspectDown" or "inspect"},
      {op=service.point.side == "down" and "dropDown" or "drop",n=item.count}},"returnFuelItem")
  elseif service.stage == "refuel" then
    local item = S.fuelItem()
    if not item then S.fuelWait("no usable fuel") return end
    S.send({ { op = "select", slot = item.slot }, { op = "refuel", n = item.count } }, "refuel")
  elseif service.stage == "return" then
    if service.back and not S.move(service.back) then return end
    j.phase = service.resume
    j.service = nil
    S.prune()
    S.save()
  end
end

S.work = function(now)
  local j = S.row
  if j.service then S.workService() return end
  if P.free(j.inv or {}) < 3 and (S.junk() or S.slot(function(name) return name:match("_log$") ~= nil end)) then S.service("wood") return end
  if j.phase == "roundEnd" then
    local logs = S.slot(function(name) return name:match("_log$") ~= nil end)
    if logs or S.junk() then S.service("wood", "waiting") else j.phase = "waiting" S.job.nextRound = now + 600000 S.save() end
    return
  end
  if j.phase == "waiting" then
    if not S.job.nextRound then S.job.nextRound = now + 600000 S.save() end
    if now < S.job.nextRound then
      if not j.idlePark or not j.parkAt or now - j.parkAt >= 540000 then S.park() end
      return
    end
    j.phase = "scan"
  end
  if j.phase == "scan" then
    if not j.target and not S.claimTarget() then
      j.phase = "roundEnd"
      S.save()
      return
    end
    local target = j.target
    if not S.move(target) then return end
    if j.probing then S.op("inspectDown", "scanCandidate") return end
    S.send({
      { op = "turnLeft" }, { op = "inspect" }, { op = "turnRight" },
      { op = "turnRight" }, { op = "inspect" }, { op = "turnLeft" }, { op = "inspectDown" },
    }, "scan")
  elseif j.phase == "base" then
    if not S.move({ dim = S.job.dim, x = j.tree.x, y = S.job.ground + 2, z = j.tree.z }) then return end
    S.op("inspectDown", "baseCheck")
  elseif j.phase == "climb" then
    if not S.move({ dim = S.job.dim, x = j.tree.x, y = math.max(S.job.ground + 2, j.turtle.pose.y), z = j.tree.z }) then return end
    if j.turtle.pose.y > S.job.ground + 64 then j.phase = "descend" S.alert("tree too tall") S.save() return end
    S.op("inspectUp", "climb")
  elseif j.phase == "descend" then
    if S.move({ dim = S.job.dim, x = j.tree.x, y = S.job.ground + 2, z = j.tree.z }) then j.phase = "plant" S.save() end
  elseif j.phase == "plant" or j.phase == "plantPlace" then
    if j.noSaplings then S.finishTarget() return end
    local desired = L.saplingFor(j.tree.kind)
    local item = S.slot(function(name) return name == desired end)
    if not item then
      if not S.service("saplings") then S.finishTarget() end
      return
    end
    local target = { dim = S.job.dim, x = j.tree.x, y = S.job.ground + 2, z = j.tree.z }
    if not S.move(target) then return end
    if j.phase == "plant" then S.op("inspectDown", "plantCheck")
    else S.send({ { op = "select", slot = item.slot }, { op = "placeDown" } }, "plant") end
  end
end

S.input = function(ev)
  if type(ev) ~= "table" then return end
  S.row = nil
  local text = ev.text
  if text == nil then
    if ev.id == "setup" then S.setup, S.setupPage = true, 0 return end
    if ev.id == "setup-next" then S.setupPage = (S.setupPage or 0) + 1 return end
    if ev.id == "turtles-next" then S.turtlePage = (S.turtlePage or 0) + 1 return end
    if ev.id == "lumber-back" then S.setup = false return end
    if type(ev.id) == "string" and ev.id:match("^here:%d+$") then
      S.input({text="add " .. ev.id:match("%d+$")}) return
    end
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
  if words[1] == "add" and #words == 2 and integer(2) and integer(2) >= 0 then
    if j.turtles[tostring(integer(2))] then S.alert("turtle already assigned") return end
    if j.running or S.anyPending() then S.alert("stop before configuring") return end
    local lease = S.module("lease")
    if not lease.locate then S.alert("GPS unavailable; use explicit add") return end
    S.admission = "GPS probe"
    lease.locate(integer(2), j.dim, function(pose, err)
      S.admission = nil
      if not pose then S.admission = err S.alert(err) return end
      S.input({text=string.format("add %d %d %d %d %s", integer(2), pose.x, pose.y, pose.z, ({[0]="n","e","s","w"})[pose.facing])})
    end)
    return
  end
  if words[1] == "stop" and #words == 1 then S.clearAlert() j.running=false
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
    for _, row in pairs(j.turtles) do
      row.blocked, row.noSaplings, row.alert, row.failures, row.recover, row.paused = nil, false, nil, nil, true, nil
    end
  elseif words[1] == "park" and #words == 2 then
    local id = integer(2)
    local row = id and j.turtles[tostring(id)]
    if not row then S.alert("unknown turtle") return end
    row.paused, row.motion, row.wait = true, nil, nil
  elseif words[1] == "area" and #words == 6 then
    if j.running or S.anyPending() then S.alert("stop before configuring") return end
    local x1, z1, x2, z2, ground = integer(2), integer(3), integer(4), integer(5), integer(6)
    if not x1 or not z1 or not x2 or not z2 or not ground or math.abs(x2 - x1) > 127 or math.abs(z2 - z1) > 127 then S.alert("invalid area") return end
    j.area = { x1 = math.min(x1, x2), z1 = math.min(z1, z2), x2 = math.max(x1, x2), z2 = math.max(z1, z2) }
    j.ground, j.visited, j.candidates, j.spots, j.nextRound = ground, {}, {}, {}, nil
    for _, row in pairs(j.turtles) do
      row.phase, row.target, row.tree, row.service, row.probing, row.detour, row.motion = "scan", nil, nil, nil, nil, nil, nil
    end
    S.route = nil
  elseif words[1] == "saplings" and #words == 5 then
    local x, y, z = integer(2), integer(3), integer(4)
    if not x or not y or not z or (words[5] ~= "front" and words[5] ~= "down") then S.alert("invalid sapling chest") return end
    j.saplings = { x = x, y = y, z = z, side = words[5] }
    for _, row in pairs(j.turtles) do row.noSaplings = false end
  elseif words[1] == "add" and #words == 6 then
    local id, x, y, z = integer(2), integer(3), integer(4), integer(5)
    local f = ({ n = 0, e = 1, s = 2, w = 3 })[words[6]]
    if not id or id < 0 or not x or not y or not z or f == nil then S.alert("invalid turtle") return end
    local lease = S.module("lease")
    local status = type(lease.status) == "function" and lease.status(id) or {}
    if status.probing then S.alert("GPS probe pending") return end
    local row = j.turtles[tostring(id)]
    local reanchor = status.uncertain and row
    if (j.running or row and row.pending) and not reanchor then S.alert("stop before configuring") return end
    if status.open and not reanchor then S.alert("turtle has open lease") return end
    local pose = { dim = j.dim, x = x, y = y, z = z, facing = f }
    if status.uncertain then
      local ok, err = lease.reanchor(id, pose)
      if not ok then S.alert(err) return end
    end
    S.row = row or { turtle = { id = id, pose = pose } }
    if S.busy(pose, "gps:" .. id) then S.row = nil S.alert("turtle cell occupied") return end
    local released, err = S.release()
    if released == false then S.alert("save failed: " .. tostring(err)) return end
    if lease.claimProbe then
      local ok, claimErr = lease.claimProbe(id, "lumber:" .. id, pose)
      if not ok then S.row = nil S.alert(claimErr) return end
    end
    local previous = j.turtles[tostring(id)]
    j.turtles[tostring(id)] = {
      turtle = { id = id, anchor = pose, pose = pose }, inv = {}, fuel = 0, phase = "scan", recover = true,
      paused = row and row.paused or nil,
    }
    S.row = nil
    S.clearAlert()
    if not S.save() then j.turtles[tostring(id)] = previous return end
    if lease.clearProbe then
      local ok, clearErr = lease.clearProbe(id)
      if not ok then S.alert(clearErr) return end
    end
    return
  elseif words[1] == "remove" and #words == 2 then
    local id = integer(2)
    local row = id and j.turtles[tostring(id)]
    if not row then S.alert("unknown turtle") return end
    S.row = row
    local lease = S.module("lease")
    local status = type(lease.status) == "function" and lease.status(id) or {}
    if status.open or row.pending then S.alert("turtle has open lease") return end
    if row.recover or not row.idlePark then
      S.park(row.recover)
      S.alert("parking turtle; retry remove after report")
      return
    end
    if row.service and row.service.lane then S.alert("turtle at chest; start to clear access") return end
    local ok, err = S.release()
    if ok == false then S.alert("save failed: " .. tostring(err)) return end
    j.obstacles = j.obstacles or {}
    j.obstacles[S.cellKey(row.turtle.pose)] = true
    j.turtles[tostring(id)] = nil
    S.row = nil
  else S.alert("invalid command") return end
  S.clearAlert()
  S.save()
end

S.gather = function()
  local job, known, ready, done = S.job, 0, 0, 0
  local daily = S.module("daily")
  local today = type(daily.today) == "function" and daily.today()
  local now, saplings, workers, fuel = SO.now(), 0, {}, nil
  local alert, state = S.admission or job.alert, job.running and "running" or "stopped"
  for _, spot in pairs(job.spots) do
    known = known + 1
    if (spot.plantedAt or 0) > 0 then done = done + 1 end
    if (spot.plantedAt or 0) == 0 or now - spot.plantedAt >= 600000 then ready = ready + 1 end
  end
  local details = {
    "AREA " .. (job.area and (job.area.x1 .. "," .. job.area.z1 .. " to " .. job.area.x2 .. "," .. job.area.z2) or "-"),
    "GROUND " .. tostring(job.ground or "-"),
    "SAPLINGS " .. (job.saplings and S.cellKey(job.saplings) .. " " .. job.saplings.side or "-"),
  }
  for _, row in ipairs(S.rows()) do
    local label = row.blocked or (row.paused and (row.idlePark and "parked" or "parking"))
      or row.wait or (row.recover and "recovering")
      or (job.running and (row.service and row.service.kind or row.phase) or "stopped")
    workers[#workers + 1] = { id = row.turtle.id, state = label, fuel = row.fuel, blocked = row.blocked }
    for _, item in ipairs(row.inv or {}) do if L.isSapling(item.name) then saplings = saplings + item.count end end
    if type(row.fuel) == "number" then fuel = math.min(fuel or row.fuel, row.fuel) end
    if not alert and row.alert then alert = "#" .. row.turtle.id .. " " .. row.alert end
    if row.blocked then state = row.blocked end
    details[#details + 1] = "TURTLE " .. row.turtle.id .. (row.turtle.pose and " " .. S.cellKey(row.turtle.pose) or "")
  end
  local seconds = job.nextRound and math.max(0, math.ceil((job.nextRound - now) / 1000))
  local grow = seconds and string.format("%d:%02d", math.floor(seconds / 60), seconds % 60) or "-"
  return {
    done = done, total = known,
    state = state, alert = alert, setup = S.setup, setupPage = S.setupPage, workers = workers,
    readiness = S.readiness(),
    available = type(S.module("lease").candidates) == "function" and S.module("lease").candidates() or {},
    details = details, grow = grow, ready = ready, known = known, saplings = saplings,
    logs = today and tostring(today.logs) or "-", delivered = job.logs or 0, fuel = fuel,
    tiles = {
      { "TREES READY", tostring(ready), "", "d" },
      { "LOGS TODAY", today and tostring(today.logs) or "-", "", today and "d" or "c" },
      { "SAPLINGS", tostring(saplings), "", saplings == 0 and "e" or "d" },
    },
  }
end
S.legacyRender = function(w)
  local model = S.gather()
  local rows = {}
  local function add(text, red) rows[#rows + 1] = { text = text, fg = red and "e" or "0", bg = "f" } end
  add("Lumber " .. model.state, model.state == "lost" or model.state == "out of range")
  add("Logs delivered " .. model.delivered)
  add("Saplings " .. model.saplings)
  add("Spots " .. model.known)
  add("Fuel " .. tostring(model.fuel or "?"))
  if model.alert and #model.alert > (w or 51) and model.alert:find(": ", 1, true) then
    local at = model.alert:find(": ", 1, true)
    add(model.alert:sub(1, at), true)
    add(model.alert:sub(at + 2), true)
  else add(model.alert or "", model.alert ~= nil) end
  for _, row in ipairs(model.workers) do add("#" .. row.id .. " " .. row.state .. " F" .. tostring(row.fuel or "?"), row.blocked ~= nil) end
  return { rows = rows, buttons = { { id = "generic", x = 1, y = #rows + 1, w = 7, label = "generic" } } }
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
    if #(model.available or {}) > 0 then lines[#lines+1]={text="UNASSIGNED",bg="7"} end
    for _, id in ipairs(model.available or {}) do
      local state=S.module("state")
      local machine=state.get and state.get("machines/"..id) or {}
      lines[#lines+1]={text=(machine.label or ("#"..id)).." FUEL "..tostring(machine.fuel or "?"),bg="f"}
      lines[#lines+1]={id=id}
    end
    for _, line in ipairs(model.details) do
      for first = 1, #line, math.max(1, w - 2) do
        lines[#lines + 1] = {text=line:sub(first, first + math.max(1, w - 2) - 1),bg="f"}
      end
    end
    local count = math.max(1, bottom - 4)
    local pages = math.ceil(#lines / count)
    local offset = ((model.setupPage or 0) % math.max(1, pages)) * count
    for i = 1, count do
      if lines[offset + i] and i + 3 < bottom then
        local line=lines[offset+i]
        if line.id then C.button(1,i+3,w,"ADD HERE #"..line.id,"here:"..line.id,"9",1)
        else
          C.fill(1,i+3,w,1,line.bg)
          C.put(2,i+3,line.text:sub(1,math.max(0,w-2)),U.ink(line.bg),line.bg)
        end
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
    local first
    if compact then
      C.put(2, 4, ("TREES " .. model.ready .. "/" .. model.known .. "  LOGS " .. model.logs):sub(1, w - 2), "0", "f")
      C.put(2, 5, ("SAPLINGS " .. model.saplings .. "  GROW " .. model.grow):sub(1, w - 2), "0", "f")
      first = 7
    else
      local cols = U.grid(w, h, 3)
      for i, t in ipairs(model.tiles) do C.tile(cols[i].x, 4, cols[i].w, unpack(t)) end
      C.put(2, 13, "NEXT GROW " .. model.grow, "0", "f")
      first = 15
    end
    local progressY = compact and 6 or 12
    if progressY < bottom then
      U.progress(C, 2, progressY, math.min(12, math.max(0, w - 2)), model.done, model.total, "b")
      C.put(15, progressY, "SPOTS " .. model.done .. "/" .. model.total)
    end
    local count = math.max(1, bottom - first - 1)
    local pages = math.max(1, math.ceil(#model.workers / count))
    local offset = ((S.turtlePage or 0) % pages) * count
    for i = 1, count do
      local row = model.workers[offset + i]
      if row and first + i - 1 < bottom - 1 then
        local text = "#" .. row.id .. " " .. row.state .. " F" .. tostring(row.fuel or "?")
        C.fill(1, first + i - 1, 1, 1, row.blocked and "e" or "d")
        C.hit("turtle:" .. row.id, 1, first + i - 1, w, 1)
        C.put(2, first + i - 1, text:sub(1, math.max(1, w - 2)), row.blocked and "f" or "0", row.blocked and "e" or "f")
      end
    end
    if pages > 1 and bottom > 1 then C.button(1, bottom - 1, w, "NEXT", "turtles-next", "7", 1) end
    local buttons = U.grid(w, h, w < 26 and 2 or 4)
    if w == 57 and h == 24 then buttons = {{x=1,w=13},{x=15,w=13},{x=29,w=14},{x=44,w=14}} end
    for i, b in ipairs({{"START", "start", "9"}, {"STOP", "stop", "e"}, {"SETUP", "setup", "7"}, {"BACK", "status", "7"}}) do
      local col = buttons[(i - 1) % #buttons + 1]
      local y = bottom + (w < 26 and math.floor((i - 1) / 2) or 0)
      C.button(col.x, y, col.w, b[1], b[2], b[3], compact and 1 or 3)
    end
  end
  if model.setup then
    if model.alert then C.fill(2,3,w-2,1,"e") C.put(2,3,model.alert:sub(1,math.max(0,w-2)),"f","e") end
  else
    local count=#C.buttons
    C.alert(model.alert and ((compact and "" or "! ") .. model.alert))
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

S.tickRow = function(row, now)
  S.row = row
  local j, lease = S.row, S.module("lease")
  local status = lease.status(j.turtle.id)
  if status.uncertain then
    if j.inflight or j.uncertain then S.suspendService() end
    j.blocked = "pose uncertain"
    S.alert("pose uncertain: re-add turtle " .. j.turtle.id)
    return
  end
  if status.lost then
    j.recover = true j.blocked = "lost"
    if not j.pending and not status.open then S.suspendService() end
  end
  if j.pending or status.open then return end
  if j.recover then
    S.suspendService()
    if not j.turtle.frame and not j.turtle.anchor then S.alert("waiting for reported pose") return end
    S.park(true)
    return
  end
  if S.job.running and not j.paused and j.blocked == "fuel" and j.fuelRetry and now >= j.fuelRetry then
    local shop = S.module("shop")
    local policy = shop.fuelConfig and shop.fuelConfig()
    if policy and policy.auto and j.service and j.service.kind == "fuel" then
      j.blocked, j.alert, j.fuelRetry = nil, nil, nil
      if j.service.stage ~= "returnFuelItem" then j.service.stage = "check" end
      S.emit("lumber.alert",false)
      S.save()
    end
  end
  if j.blocked or j.paused or not S.job.running or not S.job.area or not j.turtle.frame then
    if not j.idlePark or not j.parkAt or now - j.parkAt >= 540000 then S.park() end
    return
  end
  if j.motion then
    local motion = j.motion
    local sent = S.send(motion.steps or { { op = motion.op } }, motion.action or "motion",
      motion.cell and { j.turtle.pose, motion.cell })
    if sent then j.motion = nil end
    return
  end
  if type(j.fuel) == "number" and j.fuel >= 0 and j.fuel < S.fuelNeed() and not j.service then
    if not S.service("fuel") then return end
  end
  S.work(now)
end
S.tick = function(now)
  local lease, display = S.module("lease"), S.module("display")
  if not S.wired and type(display.screen) == "function" then display.screen("lumber", S.render, S.input) S.wired = true end
  if not S.callback and type(lease.onReport) == "function" then lease.onReport("lumber", S.report) S.callback = true end
  if not S.callback or type(lease.status) ~= "function" then return end
  local rows = S.rows()
  if S.job.nextRound and now >= S.job.nextRound then
    local active = false
    for _, row in ipairs(rows) do
      if not row.blocked and (row.target or row.tree or row.service or row.motion) then active = true end
    end
    if not active then
      S.job.nextRound, S.job.visited, S.job.candidates = nil, {}, {}
      for _, row in ipairs(rows) do if row.phase == "waiting" then row.phase = "scan" end end
      S.save()
    end
  end
  for _, row in ipairs(rows) do S.tickRow(row, now) end
  S.row = nil
end

S.dugProtection = function(protect)
  for _, row in pairs(S.job.turtles) do
    if row.recover or not row.turtle.frame then return false end
    protect(S.job.dim, row, 48)
  end
  if S.job.running and S.job.area then
    local area = S.job.area
    protect(S.job.dim, { { x=area.x1, y=-math.huge, z=area.z1 },
      { x=area.x2, y=math.huge, z=area.z2 } }, 1)
  end
  return true
end

S.mapView = function()
  local j, turtles = S.job, {}
  for id, row in pairs(j.turtles) do
    turtles[id] = { id=row.turtle.id, pose=SO.store.copy(row.turtle.pose),
      state=row.blocked or (row.paused and "parked") or row.wait or (j.running and "lumber" or "idle") }
  end
  return {dim=j.dim,area=SO.store.copy(j.area),ground=j.ground,saplings=SO.store.copy(j.saplings),turtles=turtles}
end
S.turtleView = function()
  local model, out = S.gather(), {}
  for _, worker in ipairs(model.workers) do
    local row = S.job.turtles[tostring(worker.id)]
    local action = row.pending and row.pending.action
    out[tostring(worker.id)] = { role="lumber", pose=SO.store.copy(row.turtle.pose),
      anchor=SO.store.copy(row.turtle.anchor), state=worker.state, fuel=row.fuel,
      inv=SO.store.copy(row.inv or {}), done=model.done, total=model.total,
      error=row.alert or S.admission or S.job.alert, step=type(action)=="table" and action.kind or action }
  end
  return out
end
return { name = "lumber", assigned = function(id) return S.job.turtles[tostring(id)] ~= nil end, handlers = {}, turtleView = S.turtleView, tick = S.tick, dugProtection = S.dugProtection, mapView = S.mapView }
