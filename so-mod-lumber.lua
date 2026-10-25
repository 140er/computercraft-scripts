local P = dofile("so-plan.lua")
local L = dofile("so-lumber-plan.lua")
local S = { wired = false, callback = false, lastLease = {} }
S.workerPark = SO.store.read and (SO.store.read("so-server.cfg") or {}).workerPark == true
S.scanNow = SO.store.read and (SO.store.read("so-server.cfg") or {}).lumberScan == true
S.poseSetup = SO.store.read and (SO.store.read("so-server.cfg") or {}).jobPoseSetup == true

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

S.invalidateProof = function(row)
  local service = row.service
  if not service or service.burnIntent then return end
  local changed = service.emptyProof ~= nil or service.checked ~= nil or service.stage == "burnLogs"
  service.emptyProof, service.checked = nil, nil
  if service.stage == "burnLogs" then service.stage = "check" end
  return changed
end

S.valid = function(job)
  return type(job) == "table" and type(job.spots) == "table" and type(job.dim) == "string"
end
S.box = SO.store.store("so-data/lumber/job", S.valid)
S.job = S.box.value or { dim = "minecraft:overworld", spots = {}, running = false, logs = 0 }
S.job.turtles = S.job.turtles or {}
S.job.cycleMode = S.job.cycleMode or "repeat"
if S.job.species == nil then S.job.species = false end
S.job.burnLogs = S.job.burnLogs == true
if S.job.cycle then
  S.job.candidates = S.job.cycle.candidates
  S.job.cycle.parked = {}
end
if S.job.turtle then
  local row = {}
  for _, key in ipairs({ "turtle", "phase", "cursor", "inv", "fuel", "tree", "service", "probing",
    "detour", "blocked", "alert", "failures", "noSaplings", "fuelRetry" }) do
    row[key], S.job[key] = S.job[key], nil
  end
  S.job.turtles[tostring(row.turtle.id)] = row
end
for id, row in pairs(S.job.turtles) do
  if not S.workerPark and (row.parkRequested or row.removeRequested or row.parkConfirmed) then
    row.paused,row.parkRequested,row.removeRequested,row.parkConfirmed,row.idlePark,row.parkAt=nil,nil,nil,nil,nil,nil
    print("so-lumber: workerPark off; cleared park state for "..id)
    S.pauseCleared=true
  end
  if row.inflight then row.uncertain = S.possible(row.uncertain, row.inflight) end
  S.invalidateProof(row)
  if S.job.burnLogs and row.service and not row.service.burnIntent
    and (row.service.stage == "take" or row.service.stage == "suck") then row.service.stage = "check" end
  row.recover, row.pending, row.motion, row.parkConfirmed = true, nil, nil, nil
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
  if S.reconciling then return true end
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
S.clearFuelAlert = function()
  local row, state = S.row, S.module("state")
  local text = row.alert
  if type(text) ~= "string" or not (text == "no fuel chest set" or text:match("^fuel ")) then return end
  row.alert = nil
  local active = state.get and state.get("lumber.alert")
  if type(active) == "table" and active.id == row.turtle.id and active.text == text then
    S.emit("lumber.alert", false)
  end
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
S.fuelChestKey = function(point)
  return table.concat({S.job.dim, tostring(point.id), point.x, point.y, point.z, point.side or "front"}, ":")
end
S.proofHere = function(proof)
  local j, service = S.row, S.row.service
  return proof and service and service.access and P.samePose(proof.pose, j.turtle.pose)
    and service.access.x == j.turtle.pose.x and service.access.y == j.turtle.pose.y
    and service.access.z == j.turtle.pose.z
    and (service.access.facing == nil or service.access.facing == j.turtle.pose.facing)
    and proof.chest == S.fuelChestKey(service.point)
end
S.reconcileBurn = function(report)
  local j, service = S.row, S.row.service
  local intent = service and service.burnIntent
  if not intent then return true end
  if type(report.inv) ~= "table" or type(report.fuel) ~= "number"
    or not (report.fuel >= 0 and report.fuel < math.huge) or report.uncertain
    or not P.samePose(intent.pose, j.turtle.pose) then
    j.recover = true
    S.alert("fuel refuel unconfirmed; recovery required")
    return false
  end
  local after = 0
  for _, item in ipairs(report.inv) do
    if item.slot == intent.slot then
      if item.name ~= intent.name then after = -1 else after = item.count end
    end
  end
  local consumed, gained = intent.before - after, report.fuel - intent.fuel
  if after < 0 or consumed < 0 or consumed > intent.n or gained < 0 or gained > consumed * intent.value
    or consumed == 0 and gained ~= 0 or consumed > 0 and gained == 0 then
    j.recover = true
    S.alert("fuel refuel unconfirmed; recovery required")
    return false
  end
  service.burnIntent, service.emptyProof = nil, nil
  if report.fuel >= intent.need then
    service.stage, service.logReturnHold = "return", true
  elseif consumed == intent.n and gained == consumed * intent.value then
    service.stage = "check"
  else
    service.stage, service.logReturnHold = "check", consumed > 0 or service.logReturnHold
    S.fuelWait("log refuel incomplete; fix cause, then start")
  end
  return true
end
S.burnLogs = function()
  local j, service = S.row, S.row.service
  if service.burnIntent then j.recover = true return end
  local usable, reason = S.usable(service.point)
  if not usable or not S.job.burnLogs or not S.proofHere(service.emptyProof) or service.emptyProof.empty ~= true
    or service.emptyProof.lease ~= S.lastLease[j.turtle.id] or service.logReturnHold
    or S.fuelItem() or S.rejectedItem() or type(j.fuel) ~= "number" or not (j.fuel >= 0 and j.fuel < math.huge) then
    service.emptyProof, service.stage = nil, "check"
    S.fuelWait(reason or "empty proof required")
    return
  end
  local need = S.fuelNeed(service.access, service.back)
  if j.fuel >= need then service.stage, service.logReturnHold = "return", true S.save() return end
  local item = S.slot(function(name) return (P.burnValue(name) or 0) > 0 end)
  if not item then S.fuelWait("no usable logs") return end
  local value = P.burnValue(item.name)
  -- Reports omit capacity. Bound requests to the basic turtle capacity; workers enforce lower configured limits.
  local capacity = 20000
  local n = math.min(item.count, math.ceil((need - j.fuel) / value), math.max(0, math.ceil((capacity - j.fuel) / value)))
  if n == 0 then S.fuelWait("fuel capacity reached") return end
  service.burnIntent = { slot = item.slot, name = item.name, before = item.count,
    fuel = j.fuel, n = n, value = value, need = need, pose = SO.store.copy(j.turtle.pose) }
  if not S.save() then return end
  S.send({ { op = "select", slot = item.slot }, { op = "refuel", n = n } }, "burnLogs")
end
S.dimensionError = function(dim, y)
  local config=dim ~= "minecraft:overworld" and SO.store.read and SO.store.read("so-server.cfg")
  return P.dimensionError(dim, config) or P.heightError(dim, y)
end
S.readiness = function()
  local j = S.job
  local rows = S.rows()
  if S.once() then
    local members = {}
    for _, row in ipairs(rows) do if S.member(row) then members[#members + 1] = row end end
    rows = members
  end
  local checks = {{ok=j.area ~= nil,text=j.area and "area ready" or "area not set"},{ok=j.ground ~= nil,text=j.ground and ("ground "..j.ground) or "ground not set"}}
  local drops, lease = S.module("drops"), S.module("lease")
  if j.dim ~= "minecraft:overworld" then
    local err=S.dimensionError(j.dim,(j.ground or 0)+2) or P.heightError(j.dim,(j.ground or 0)+4)
    checks[#checks+1]={ok=not err,text=err or j.dim}
    for _,row in ipairs(rows) do
      local ok, why
      if lease.remoteReady then ok,why=lease.remoteReady(row.turtle.id,j.dim) end
      checks[#checks+1]={ok=ok==true,text=why or "remote worker requires update"}
    end
  end
  local points = type(drops.list)=="function" and drops.list() or {}
  local dim = ({["minecraft:overworld"]=0,["minecraft:the_nether"]=-1,["minecraft:the_end"]=1})[j.dim]
  local first = rows[1]
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
  local paired, fueled = true, true
  for _, row in ipairs(rows) do
    local id = row.turtle.id
    local status = type(lease.status)=="function" and lease.status(id)
    paired = paired and SO.pair and SO.pair.key(id) ~= nil and status and not status.uncertain and not status.lost
    checks[#checks+1]=P.toolCheck(status and status.tools,"axe",id,status and status.autoToolSwap)
    fueled = fueled and type(row.fuel)=="number" and row.fuel~=0
  end
  paired, fueled = #rows > 0 and paired, #rows > 0 and fueled
  checks[#checks+1]={ok=paired, text=paired and "paired turtle ready" or "paired turtle missing"}
  if #rows > 0 then checks[#checks+1]={ok=fueled,text=fueled and (#rows == 1 and ("fuel "..rows[1].fuel) or "fuel ready") or "fuel missing"} end
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
S.reserve = function(p, access)
  local flight = S.job.ground + 2
  return math.abs(p.y - flight) + math.abs(p.x - access.x) + math.abs(p.z - access.z)
    + math.abs(access.y - flight) + 32
end
S.fuelNeed = function(access, from)
  local j, drops = S.row, S.module("drops")
  local dim = S.dropDim()
  local p = from or j.turtle.pose
  if not access then
    local picked = dim ~= nil and type(drops.choose) == "function" and drops.choose("fuel", { dim = dim, x = p.x, y = p.y, z = p.z })
    local point = picked and picked.point
    if point then access = L.access(point, p) end
  end
  if not access then return 32 end
  return S.reserve(p, access)
end
S.owner = function() return "lumber:" .. tostring(S.row.turtle.id) end
S.release = function()
  local cells = S.module("cells")
  if type(cells.releaseOwner) == "function" then return cells.releaseOwner(S.owner()) end
  return true
end

S.removeParked = function()
  local row, cells = S.row, S.module("cells")
  if row.service and row.service.lane then S.alert("turtle at chest; resume to clear access") return end
  if not cells.handoff or not cells.releaseOwner or not cells.list then S.alert("cells unavailable") return end
  local id, p = row.turtle.id, row.turtle.pose
  local ok, err = cells.handoff(S.owner(),"gps:"..id,p.x,p.y,p.z,p.dim)
  if ok then ok,err=S.release() end
  if not ok or #cells.list(S.owner(),1)>0 then S.alert(err or "reservation cleanup pending") return end
  S.job.turtles[tostring(id)]=nil
  if not S.save() then S.job.turtles[tostring(id)]=row return end
  S.row=nil
end
S.cellKey = function(p) return p.x .. "," .. p.y .. "," .. p.z end
S.cycleKey = function(p) return (p.dim or S.job.dim) .. ":" .. S.cellKey(p) end
S.once = function() return S.job.cycle ~= nil and S.job.cycle.phase ~= "complete" end
S.member = function(row)
  return S.job.cycle and S.job.cycle.members[tostring(row.turtle.id)] == true
end
S.hasClaims = function()
  for _, row in pairs(S.job.turtles) do
    if row.target or row.tree or row.service or row.delivery or row.motion or row.inflight then return true end
  end
  return false
end
S.newCycle = function()
  local job, seen = S.job, {}
  local cycle = { id = math.max(job.cycleSerial or 0, job.cycle and job.cycle.id or 0) + 1, targets = L.scan(job.area, job.ground, job.dim),
    cursor = 1, claims = {}, done = {}, members = {}, candidates = {}, phase = "survey", parks = {}, parked = {} }
  for _, p in ipairs(job.candidates) do
    local key = S.cycleKey(p)
    if not seen[key] then cycle.candidates[#cycle.candidates + 1], seen[key] = SO.store.copy(p), true end
  end
  for id, row in pairs(job.turtles) do
    cycle.members[id] = true
    row.phase, row.idlePark = "scan", nil
  end
  job.cycle, job.candidates, job.visited, job.nextRound = cycle, cycle.candidates, {}, nil
  job.cycleSerial = cycle.id
  job.scanRequested, job.scanRound = nil, nil
end
S.addCandidate = function(p)
  local cycle, key = S.job.cycle, S.cycleKey(p)
  if S.once() and (cycle.done[key] or cycle.claims[key]) then return end
  for _, candidate in ipairs(S.job.candidates) do if S.cycleKey(candidate) == key then return end end
  S.job.candidates[#S.job.candidates + 1] = p
end
S.clear = function(p)
  if S.occupied(p) then return false end
  local cells = S.module("cells")
  return (S.job.clear or {})[S.cellKey(p)] == true
    or type(cells.isDug) == "function" and cells.isDug(p.x, p.y, p.z, S.job.dim) == true
end
S.parkSafe = function(p)
  local job, drops = S.job, S.module("drops")
  local a = job.area
  if p.x >= a.x1 - 1 and p.x <= a.x2 + 1 and p.z >= a.z1 - 1 and p.z <= a.z2 + 1 then return false end
  local points = { job.saplings }
  for _, point in ipairs(type(drops.list) == "function" and drops.list() or {}) do
    if point.dim == S.dropDim() then points[#points + 1] = point end
  end
  for _, row in pairs(job.turtles) do
    if row.service then points[#points + 1] = row.service.point end
  end
  for _, point in pairs(points) do
    if math.abs(point.x - p.x) + math.abs(point.z - p.z) <= 2 then return false end
  end
  for id, park in pairs(job.cycle.parks) do
    if id ~= tostring(S.row.turtle.id) and S.cellKey(park) == S.cellKey(p) then return false end
  end
  return S.clear(p) and not S.busy(p)
end
S.parkDestination = function()
  local job, row = S.job, S.row
  local id, best, distance = tostring(row.turtle.id)
  local function consider(p)
    if not S.parkSafe(p) then return end
    local d = L.distance(row.turtle.pose, p)
    if distance and d >= distance then return end
    if d > 0 and not L.nextCell(row.turtle.pose, p, job.ground, function(cell)
      return S.busy(cell) or not S.clear(cell)
    end) then return end
    best, distance = p, d
  end
  for x = job.area.x1 - 8, job.area.x2 + 8 do
    for z = job.area.z1 - 8, job.area.z2 + 8 do
      if x < job.area.x1 - 1 or x > job.area.x2 + 1 or z < job.area.z1 - 1 or z > job.area.z2 + 1 then
        for y = job.ground + 2, job.ground + 4 do
          consider({ dim = job.dim, x = x, y = y, z = z, facing = row.turtle.pose.facing })
        end
      end
    end
  end
  if not best then S.alert("no clear parking route") return nil end
  local cells = S.module("cells")
  if not cells.reserveMany(S.owner(), { best }) then S.alert("parking cell held") return nil end
  job.cycle.parks[id] = best
  if not S.save() then return nil end
  return best
end
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
  if S.member(row) then add(S.job.cycle.parks[tostring(row.turtle.id)]) end
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
  local cycle = S.once() and job.cycle
  local route = cycle and cycle.targets or S.route
  local best, distance, candidateIndex
  local function consider(p, index, candidate)
    if cycle and (cycle.done[S.cycleKey(p)] or cycle.claims[S.cycleKey(p)]) then return end
    if not S.claimed(p, row) and not S.busy(p) then
      local d = L.distance(row.turtle.pose, p)
      if not distance or d < distance then
        best = { dim = job.dim, x = p.x, y = p.y, z = p.z, facing = p.facing, index = index }
        distance, candidateIndex = d, candidate
      end
    end
  end
  for index, p in ipairs(job.candidates) do consider(p, nil, index) end
  for index, p in ipairs(route) do if not job.visited[index] then consider(p, index) end end
  if not best or not cells.reserveMany(S.owner(), {best}) then return false end
  row.target, row.probing = best, candidateIndex ~= nil or nil
  if candidateIndex then table.remove(job.candidates, candidateIndex) end
  if cycle then cycle.claims[S.cycleKey(best)] = tostring(row.turtle.id) end
  return S.save()
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
  if S.once() then S.job.clear = S.job.clear or {} end
  for i, step in ipairs(pending.steps) do
    local result, dir = results[i], directions[step.op]
    if dir then
      local x, y, z = P.ahead(at, dir)
      local key = S.cellKey({ x = x, y = y, z = z })
      if step.op:match("^inspect") then known[key] = result.ok and result.data ~= nil or nil
      elseif result.ok then known[key] = nil end
      if S.once() then
        S.job.clear[key] = not known[key] and (result.ok or not result.err or result.err == "No block to inspect") or nil
      end
    end
    if result.ok then
      at = P.apply(at, step.op)
      if S.once() and P.moves[step.op] then S.job.clear[S.cellKey(at)] = true end
    end
  end
end

S.send = function(steps, action, cells, recover, ms, route)
  local j, lease = S.row, S.module("lease")
  if S.reconciling then
    j.nextDispatch = {steps=steps,action=action,cells=cells,recover=recover,ms=ms,route=route}
    return true
  end
  if not recover and lease.restartReady and not lease.restartReady() then
    j.nextDispatch = {steps=steps,action=action,cells=cells,recover=recover,ms=ms,route=route}
    return true
  end
  if action ~= "suck" and action ~= "burnLogs" then S.invalidateProof(j) end
  if not j.turtle or type(lease.send) ~= "function" or type(lease.status) ~= "function" then return false end
  if S.row.pending or lease.status(j.turtle.id).open then return false end
  local once = S.once() and S.member(j)
  local status = lease.status(j.turtle.id)
  if once and (not status.parkBatch or not status.setupFence or not status.journal or not status.pose) then
    S.alert("ONCE needs a certain fenced worker") return false
  end
  if once then steps = SO.store.copy(steps) end
  local boundary = once or lease.boundaries and lease.boundaries()
  if boundary then
    local prefix = P.boundary({from=j.turtle.pose,steps=steps})
    if #prefix.rest > 0 or route then
      route = route or {steps=steps,pose=j.turtle.pose,action=action,results={},recover=recover,ms=ms}
      route.rest = prefix.rest
    end
    steps = prefix.steps
    local check = lease.assess(j.turtle.id,j.turtle.pose,steps,{owner="lumber"})
    if not check.ok then j.blocked="hold" S.alert(check.reason) return false end
  end
  if once then
    steps[1].park = true
    if j.phase == "cyclePark" then
      local at = j.turtle.pose
      for _, step in ipairs(steps) do
        at = P.apply(at, step.op)
        if step.op:match("^dig") or P.moves[step.op] and not S.clear(at) then
          S.alert("parking needs a clear route") return false
        end
      end
    end
  end
  cells = cells or { j.turtle.pose }
  local at = j.turtle.pose
  if S.job.dim ~= "minecraft:overworld" and not (recover or #steps==1 and steps[1].op=="inspectDown") then
    local err = S.dimensionError(S.job.dim, at.y)
    if err then j.blocked="hold" S.alert(err) return false end
    for _,step in ipairs(steps) do
      at=P.apply(at,step.op)
      err=P.heightError(S.job.dim,at.y)
      if err then j.blocked="hold" S.alert(err) return false end
    end
    at=j.turtle.pose
  end
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
    owner = "lumber", recover = recover == true, ms = ms, pose = pose, frame = j.turtle.frame,
    journal = once and status.journal or nil,
    intent = {action=action,steps=steps,pose=j.turtle.pose,boundary=boundary and not recover,route=route,journal=once and status.journal or nil},
  })
  if not id then
    j.inflight = nil
    if not boundary then S.prune() end
    S.row.idlePark, S.row.parkAt = nil, nil
    j.blocked = "hold"
    if err == "lost" then S.row.recover = true end
    S.alert("lease " .. tostring(err))
    return false
  end
  S.lastLease[j.turtle.id] = id
  S.row.pending = { id = id, action = action, steps = steps, pose = j.turtle.pose,
    boundary = boundary and not recover, route = route, journal = once and status.journal or nil }
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
  if S.row.paused or S.once() and not S.job.running then return end
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
  if #S.rows() > 1 or S.row.phase == "cyclePark" then
    local goal = target
    local nextCell = L.nextCell(p, goal, S.job.ground, function(cell)
      return S.busy(cell) or (S.row.phase == "cyclePark" and not S.clear(cell))
        or (S.cellKey(cell) ~= S.cellKey(goal) and S.occupied(cell))
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
S.noteChest = function(point, result, receipt)
  local name = P.chestPresent(result) and result.data.name or nil
  local drops = S.module("drops")
  if point and point.id and type(drops.note) == "function" then drops.note(point.id, name, receipt) end
  return type(name) == "string" and name ~= ""
end
S.usable = function(point)
  local drops = S.module("drops")
  if type(drops.usable) == "function" then return drops.usable(point.id) end
  return not point.broken, "broken"
end

S.service = function(kind, resume)
  local j = S.row
  local point
  if kind == "saplings" then
    point = S.job.saplings
    if point then
      local saved = S.saplingPoint(point)
      local usable, reason
      if saved then usable, reason = S.usable(saved) end
      if not saved or not usable then
        j.blocked = "hold"
        S.chestAlert("saplings", reason or "unavailable", saved or point)
        return false
      end
      point = { id = saved.id, dim = S.job.dim, x = point.x, y = point.y, z = point.z, side = point.side }
    end
  else
    local drops = S.module("drops")
    local near = { dim = S.dropDim(), x = j.turtle.pose.x, y = j.turtle.pose.y, z = j.turtle.pose.z }
    local picked = near.dim ~= nil and type(drops.choose) == "function" and drops.choose(kind, near)
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
  if kind == "fuel" then S.clearFuelAlert() end
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
  if S.once() and row.target then
    local cycle, key = S.job.cycle, S.cycleKey(row.target)
    cycle.done[key], cycle.claims[key] = true, nil
    while cycle.targets[cycle.cursor] and cycle.done[S.cycleKey(cycle.targets[cycle.cursor])] do
      cycle.cursor = cycle.cursor + 1
    end
  end
  row.target, row.tree, row.probing, row.detour = nil, nil, nil, nil
  row.phase = "scan"
  S.save()
end

S.report = function(id, turtleId, results, lease)
  S.row = S.job.turtles[tostring(turtleId)]
  if not S.row or S.row.turtle.forgotten then return end
  local j, pending = S.row, S.row.pending
  if not pending or pending.id ~= id then return end
  S.row.pending = nil
  if not results then
    if j.service and pending.action == "suck" then
      j.service.emptyProof, j.service.checked = nil, nil
      if S.job.burnLogs then j.service.stage = "check" end
    end
    if S.member(j) then S.job.cycle.parked[tostring(turtleId)] = nil end
    j.parkConfirmed=nil
    j.uncertain = S.possible(j.uncertain, pending)
    S.row.recover, j.motion = true, nil
    j.blocked = "lost"
    S.suspendService()
    S.alert(S.job.dim ~= "minecraft:overworld" and "remote silent; unloaded?" or "lost lease")
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
    S.row.recover, j.parkConfirmed = true, nil
    j.uncertain = S.possible(j.uncertain, pending)
    S.suspendService()
    S.alert("missing pose")
    return
  end
  local fenced = true
  if pending.journal then
    fenced = type(report.journal) == "string" and report.journal ~= pending.journal
    for _, result in ipairs(results) do if result.err == "journal changed" then fenced = false end end
  end
  if S.once() and (not fenced or report.uncertain or type(report.inv) ~= "table") then
    j.uncertain = S.possible(j.uncertain, pending)
    j.recover, j.motion, j.blocked = true, nil, "lost"
    S.suspendService()
    S.alert("cycle report unconfirmed; reservations held")
    return
  end
  if pending.boundary and (report.uncertain or not P.confirm(pending.pose,pending.steps,results,j.turtle.pose)) then
    j.uncertain = S.possible(j.uncertain,pending)
    j.recover, j.motion, j.blocked = true, nil, "lost"
    S.suspendService()
    S.alert("boundary unconfirmed; reservations held")
    return
  end
  if pending.route then
    local route = pending.route
    if S.once() and not S.job.running and not route.recover then
      j.inflight, j.motion = nil, nil
      S.noteBlocks(pending, results)
      S.prune() S.save() return
    end
    for _, result in ipairs(results) do route.results[#route.results+1] = result end
    if #route.rest > 0 and S.reconciling then
      j.resumeRoute = route
      return
    end
    if #route.rest > 0 then
      if not S.send(route.rest,route.action,nil,route.recover,route.ms,route) then
        j.recover, j.blocked = true, "hold"
        S.suspendService()
        S.alert("route held; reservations retained")
      end
      return
    end
    pending = {action=route.action,pose=route.pose,steps=route.steps}
    results = route.results
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
    inspected = S.noteChest(j.service and j.service.point, results[2], id)
  end
  j.inflight = nil
  S.noteBlocks(pending, results)
  if report.inv then j.inv = report.inv end
  if report.fuel ~= nil then j.fuel = report.fuel end
  local action, result = pending.action, results[#results]
  local ok = true
  for _, row in ipairs(results) do if not row.ok then ok = false end end
  for _,r in ipairs(results) do
    local hazard=r.hazard or r.err
    if type(hazard)=="string" and hazard:match("^remote safety:") then
      j.blocked="hold" S.alert(hazard:gsub("^remote safety: ",""))
      S.prune() S.save() return
    end
  end
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
  if S.once() and action == "cyclePark" then
    local target = S.job.cycle.parks[tostring(turtleId)]
    if target and P.samePose(j.turtle.pose, target) and S.parkSafe(target) then
      S.job.cycle.parked[tostring(turtleId)] = true
      j.idlePark, j.parkAt = true, SO.now()
    end
  elseif S.workerPark and action == "park" and j.paused then
    j.parkConfirmed=true
  elseif action == "recover" then
    S.invalidateProof(j)
    local burning = j.service and j.service.burnIntent
    if not S.reconcileBurn(report) then S.save() return end
    if j.delivery then
      if not report.inv then S.alert("missing inventory") S.save() return end
      local after = S.count(function(name) return name:match("_log$") ~= nil end)
      if not S.creditDelivery(math.max(0, j.delivery.before - after)) then S.save() return end
      if j.service then j.service.stage = "drop" end
    end
    S.row.recover, j.uncertain = false, nil
    if S.once() then
      S.job.clear = S.job.clear or {}
      S.job.clear[S.cellKey(j.turtle.pose)] = true
      if j.tree and j.phase == "plantPlace" then j.phase = "plant" end
    end
    if j.service then j.service.suspended = nil end
    if not (burning and j.service.stage == "check")
      and not (j.service and j.service.logReturnHold and j.blocked == "fuel") then j.blocked = nil end
    S.prune()
  elseif type(action) == "table" and action.kind == "path" then
    local block = result.ok and result.data or nil
    if S.job.dim ~= "minecraft:overworld" and block and (block.name=="minecraft:lava" or block.name=="minecraft:water") then
      j.blocked="hold" S.alert("remote safety: "..block.name)
    elseif not block then
      S.follow({ op = action.move, cell = action.cell })
    elseif j.service and j.service.stage == "travel" and j.service.access
      and S.cellKey(action.cell) == S.cellKey(j.service.access) then
      j.service.access, j.service.lane, j.detour = nil, nil, nil
    elseif j.phase ~= "cyclePark" and action.cell.y > (S.job.ground or -math.huge)
      and (not j.service or action.cell.y > S.job.ground + 1) and L.canDig(block, S.job.species) then
      local dig = ({ up = "digUp", down = "digDown", forward = "dig" })[action.move]
      S.follow({ op = dig, cell = action.cell })
    else
      local scan = j.target
      if j.phase == "cyclePark" then
        S.job.cycle.parks[tostring(turtleId)], S.job.cycle.parked[tostring(turtleId)] = nil, nil
        S.alert("parking route blocked")
      elseif j.phase == "scan" and not j.service and scan
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
        if seen and seen.ok and L.isLog(seen.data, S.job.species) then
          local x, _, z = P.ahead(P.apply(p, side.op), "forward")
          if x >= S.job.area.x1 and x <= S.job.area.x2 and z >= S.job.area.z1 and z <= S.job.area.z2 then
            local duplicate = false
            for _, candidate in ipairs(S.job.candidates) do if candidate.x == x and candidate.z == z then duplicate = true end end
            local spot = S.job.spots[x .. "," .. z]
            if not duplicate and (S.once() or S.scanNow and S.job.scanRound or not spot or SO.now() - (spot.plantedAt or 0) >= 600000) then
              S.addCandidate({ dim = S.job.dim, x = x, y = S.job.ground + 2, z = z })
            end
          end
        end
      end
    end
    local block = result.ok and result.data or nil
    local p = j.turtle.pose
    local key = p.x .. "," .. p.z
    local spot = S.job.spots[key]
    if L.isLog(block, S.job.species) and not S.claimed(p, j) then
      S.job.spots[key] = { kind = block.name, plantedAt = spot and spot.plantedAt or 0 }
      j.tree = { x = p.x, z = p.z, kind = block.name }
      j.phase = "base"
    elseif spot and L.selected(spot.kind, S.job.species) and not block and not j.noSaplings and not S.claimed(p, j) then
      j.tree = { x = p.x, z = p.z, kind = spot.kind }
      j.phase = "plant"
    else
      S.finishTarget()
    end
  elseif action == "baseCheck" then
    if result.ok and L.isLog(result.data, S.job.species) then
      S.follow({ op = "digDown", action = "base" })
    else
      j.phase = "climb"
    end
  elseif action == "base" then
    if ok then j.phase = "climb" else j.phase = "base" end
  elseif action == "climb" then
    if result.ok and L.isLog(result.data, S.job.species) then
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
      if S.once() then j.blocked = "hold" S.alert("replant blocked") else S.finishTarget() end
    else
      j.phase = "plantPlace"
    end
  elseif action == "plant" then
    if ok then S.job.spots[j.tree.x .. "," .. j.tree.z].plantedAt = SO.now() end
    if ok or not S.once() then S.finishTarget() else j.blocked = "hold" S.alert("replant failed") end
  elseif action == "supplyCheck" then
    if j.service then
      j.service.checked, j.service.emptyProof = nil, nil
      if S.noteChest(j.service.point, result, id) then
        j.service.stage = "take"
        if S.job.burnLogs and j.service.kind == "fuel" and not report.uncertain then
          j.service.checked = { pose = SO.store.copy(j.turtle.pose), chest = S.fuelChestKey(j.service.point) }
        end
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
      local empty = S.job.burnLogs and S.job.running and not j.paused and not service.logReturnHold and #results == #pending.steps and results[1].ok
        and result.ok == false and result.err == "No items to take" and not report.uncertain
        and type(report.inv) == "table" and type(report.fuel) == "number"
        and S.proofHere(service.checked) and service.takeSlot and not S.takenItem()
        and not S.fuelItem() and not S.rejectedItem()
      if empty then
        service.emptyProof = { pose = SO.store.copy(j.turtle.pose), chest = S.fuelChestKey(service.point),
          slot = service.takeSlot, lease = id, empty = true }
        service.checked, service.stage = nil, "burnLogs"
        S.chestAlert("fuel", "empty", service.point)
      elseif not ok then
        service.emptyProof, service.checked = nil, nil
        j.blocked="fuel" S.chestAlert("fuel",P.transferFailure("fuel",result),service.point)
      else
        service.emptyProof, service.checked = nil, nil
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
  elseif action == "burnLogs" then
    if not S.reconcileBurn(report) then S.save() return end
  elseif action == "refuel" then
    if j.service then
      if not ok then S.fuelWait("no usable fuel") else S.clearFuelAlert() j.service.stage, j.service.logReturnHold = "return", nil end
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
  if not S.queueService() then
    if S.invalidateProof(j) then S.save() end
    return
  end
  if service.kind == "saplings" and not service.point.id then
    local saved = S.saplingPoint(service.point)
    if not saved then
      j.blocked = "hold"
      S.chestAlert("saplings", "unavailable", service.point)
      return
    end
    service.point.id = saved.id
  end
  if service.burnIntent then j.recover = true return end
  if service.kind == "fuel" and service.stage ~= "travel" and service.stage ~= "return" and service.stage ~= "burnLogs" then
    local rejected = S.rememberFuelPickup()
    if not S.acceptFuel() and rejected then service.stage = "check" S.fuelWait("non-fuel items") return end
  end
  local fuelAttempt = service.kind == "fuel" and (service.stage == "travel" or service.stage == "check"
    or service.stage == "suck" or service.stage == "take")
  if service.kind == "saplings" and service.stage ~= "return" or fuelAttempt then
    local usable, reason = S.usable(service.point)
    if not usable then
      if fuelAttempt then S.fuelWait(reason) return end
      j.blocked = "hold"
      S.chestAlert("saplings",reason,service.point)
      return
    end
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
    service.emptyProof, service.checked = nil, nil
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
      service.takeSlot, service.takeOrder, service.emptyProof = nil, nil, nil
      local auto, policy = S.autoFuel()
      if auto or S.job.burnLogs then
        service.takeSlot = slot
        if auto then service.takeOrder = policy.waiting and policy.waiting.rid or false end
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
  elseif service.stage == "burnLogs" then
    S.burnLogs()
  elseif service.stage == "refuel" then
    local item = S.fuelItem()
    if not item then S.fuelWait("no usable fuel") return end
    S.send({ { op = "select", slot = item.slot }, { op = "refuel", n = item.count } }, "refuel")
  elseif service.stage == "return" then
    if service.back and not S.move(service.back) then return end
    j.phase = service.resume
    if service.logReturnHold then
      service.stage, j.blocked = "travel", "fuel"
      S.invalidateProof(j)
      if S.autoFuel() then j.fuelRetry = j.fuelRetry or SO.now() + 60000 end
    else j.service = nil end
    S.prune()
    S.save()
  end
end

S.work = function(now)
  local j = S.row
  if j.service then S.workService() return end
  if S.once() and (j.phase == "cycleUnload" or j.phase == "cyclePark") then
    if j.phase == "cycleUnload" then
      if S.slot(function(name) return name:match("_log$") ~= nil end) or S.junk() then
        S.service("wood", "cycleUnload") return
      end
      j.phase = "cyclePark"
      if not S.save() then return end
    end
    local cycle, id = S.job.cycle, tostring(j.turtle.id)
    local target = cycle.parks[id]
    if target and not S.parkSafe(target) then
      cycle.parks[id], cycle.parked[id], target = nil, nil, nil
      if not S.save() then return end
    end
    target = target or S.parkDestination()
    if not target then return end
    if not S.moveDirect(target) then return end
    if not cycle.parked[id] or not j.parkAt or now - j.parkAt >= 540000 then
      S.send(P.park.steps, "cyclePark", nil, false, P.park.ms)
    end
    return
  end
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
    if S.scanNow and S.job.scanRequested and not j.target then
      if not j.idlePark or not j.parkAt or now - j.parkAt >= 540000 then S.park() end
      return
    end
    if not j.target and not S.claimTarget() then
      if S.once() then j.wait = "wait cycle" return end
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
    local target = { dim = S.job.dim, x = j.tree.x, y = S.job.ground + 2, z = j.tree.z }
    if S.once() and j.phase == "plant" then
      if S.move(target) then S.op("inspectDown", "plantCheck") end
      return
    end
    if j.noSaplings then
      if S.once() then S.alert("replant needs saplings") else S.finishTarget() end
      return
    end
    local desired = L.saplingFor(j.tree.kind)
    local item = S.slot(function(name) return name == desired end)
    if not item then
      if not S.service("saplings", S.once() and "plant" or nil) and not S.once() then S.finishTarget() end
      return
    end
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
    local id, v = ev.id, S.screen.view(ev.session)
    if id == "setup" or id == "tab:setup" then v.page, v.offset = "setup", 0 return end
    if id == "lumber-back" or id == "tab:overview" or id == "tab:main" then v.page = "main" return end
    if id == "setup-next" then v.offset = (v.offset or 0) + 1 return end
    if id == "turtles-next" then v.workers = (v.workers or 0) + 1 return end
    if S.poseSetup and id == "pose-next" then S.screen.pose(v,true) return end
    if S.poseSetup and (id == "from-here" or id == "to-here") then
      local row = S.screen.pose(v)
      local lease = S.module("lease")
      local status = row and lease.status and lease.status(row.turtle.id)
      local p = row and row.turtle.pose
      if not p or row.recover or not status or status.open or status.lost or status.uncertain
        or S.job.running or S.anyPending() then S.alert("paired pose unavailable") return end
      for _, key in ipairs({"x","y","z"}) do
        local n=p[key]
        if type(n) ~= "number" or n%1 ~= 0 or math.abs(n)>=30000000 then S.alert("paired pose unavailable") return end
      end
      if id == "from-here" then v.corner=SO.store.copy(p) return end
      local first = v.corner
      if not first or first.dim ~= p.dim or p.dim ~= S.job.dim then S.alert("set first corner") return end
      S.input({text=table.concat({"area",first.x,first.z,p.x,p.z,first.y-1}," ")})
      return
    end
    if type(id) == "string" and id:match("^here:%d+$") then S.input({ text = "add " .. id:match("%d+$") }) return end
    if id ~= "start" and id ~= "stop" and id ~= "scan" then return end
    text = id
  end
  local words = {}
  for word in tostring(text):gmatch("%S+") do words[#words + 1] = word end
  local j = S.job
  local function integer(i)
    local n = tonumber(words[i])
    if n and n == n and n % 1 == 0 and math.abs(n) < 30000000 then return n end
  end
  if S.once() and (words[1] == "area" or words[1] == "remove"
    or words[1] == "add" and j.turtles[tostring(integer(2))]) then
    S.alert("finish the current cycle before configuring members or area") return
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
  if words[1] == "mode" and #words == 2 and (words[2] == "once" or words[2] == "repeat") then
    if j.running or S.anyPending() or S.once() or S.hasClaims() then S.alert("finish work and stop before configuring") return end
    j.cycleMode, j.cycle = words[2], nil
    j.visited, j.nextRound = {}, nil
    for _, row in pairs(j.turtles) do row.phase, row.idlePark = "scan", nil end
  elseif words[1] == "species" and #words >= 2 then
    if j.running or S.anyPending() or S.once() or S.hasClaims() then S.alert("finish work and stop before configuring") return end
    local selection, seen = {}, {}
    if #words == 2 and words[2] == "false" then selection = false
    elseif not (#words == 2 and words[2] == "none") then
      for i = 2, #words do
        if not L.species[words[i]] then S.alert("unsupported log ID") return end
        if not seen[words[i]] then selection[#selection + 1], seen[words[i]] = words[i], true end
      end
      table.sort(selection)
    end
    j.species = selection
  elseif words[1] == "burnLogs" and #words == 2 and (words[2] == "true" or words[2] == "false") then
    if j.running or S.anyPending() then S.alert("stop before configuring") return end
    j.burnLogs = words[2] == "true"
  elseif words[1] == "stop" and #words == 1 then
    for _, row in pairs(j.turtles) do S.invalidateProof(row) end
    S.clearAlert() j.running=false
  elseif words[1] == "scan" and #words == 1 and S.scanNow then
    if S.once() or j.cycleMode == "once" then return end
    if not j.running or not j.area or j.ground == nil then return end
    if j.scanRequested then return end
    j.scanRequested = true
    S.save()
    return
  elseif words[1] == "start" and #words == 1 then
    local state = S.module("state")
    local ok, err = false, "disk guard unavailable"
    if type(state.canStart) == "function" then ok, err = state.canStart() end
    if not ok then S.admission = err S.emit("lumber.alert",{text=err}) return end
    S.admission = nil
    local missing=P.missing(S.readiness())
    if #missing>0 then S.alert(table.concat(missing,"; ")) return end
    if j.cycleMode == "once" then
      local lease = S.module("lease")
      for _, row in pairs(j.turtles) do
        if not S.once() or S.member(row) then
          local status = lease.status(row.turtle.id)
          if not status.parkBatch or not status.setupFence or not status.journal or not status.pose
            or status.uncertain or status.lost or row.turtle.forgotten or S.workerPark and row.paused or type(lease.assess) ~= "function" then
            S.alert("ONCE needs certain fenced workers") return
          end
          if not S.once() and (row.target or row.tree or row.service) then S.alert("finish existing claims before ONCE") return end
        end
      end
      if not S.once() then S.newCycle() end
    end
    j.running, j.blocked, j.noSaplings, j.alert, j.failures = true, nil, false, nil, nil
    if type(state.get)=="function" and state.get("lumber.alert") then S.emit("lumber.alert",false) end
    for _, row in pairs(j.turtles) do
      S.invalidateProof(row)
      row.blocked, row.noSaplings, row.alert, row.failures, row.recover, row.paused = nil, false, nil, nil, true, S.workerPark and row.paused or nil
      if S.member(row) then
        S.job.cycle.parked[tostring(row.turtle.id)] = nil
      end
      if S.once() or j.species ~= false then row.motion = nil end
    end
  elseif S.workerPark and (words[1]=="park" or words[1]=="resume" or words[1]=="remove") and #words==2 then
    local id=integer(2)
    local row=id and j.turtles[tostring(id)]
    if not row then S.alert("unknown turtle") return end
    if row.turtle.forgotten then S.alert("device forgotten; re-pair and re-add turtle") return end
    S.invalidateProof(row)
    if words[1]=="resume" then
      local cells,p=S.module("cells"),row.turtle.pose
      if cells.owner and cells.owner(p.x,p.y,p.z,p.dim)=="gps:"..id then
        local ok,err=cells.handoff("gps:"..id,"lumber:"..id,p.x,p.y,p.z,p.dim)
        if not ok then S.alert(err) return end
      end
      row.paused,row.parkRequested,row.removeRequested,row.parkConfirmed,row.idlePark=nil,nil,nil,nil,nil
    else
      if not row.paused then row.parkConfirmed,row.idlePark=nil,nil end
      row.paused,row.parkRequested=true,true
      if words[1]=="remove" then row.removeRequested=true end
    end
  elseif words[1] == "park" and #words == 2 then
    local id = integer(2)
    local row = id and j.turtles[tostring(id)]
    if not row then S.alert("unknown turtle") return end
    S.invalidateProof(row)
    row.paused, row.motion, row.wait = true, nil, nil
  elseif words[1] == "area" and (#words == 6 or #words == 7) then
    if j.running or S.anyPending() then S.alert("stop before configuring") return end
    local x1, z1, x2, z2, ground = integer(2), integer(3), integer(4), integer(5), integer(6)
    if not x1 or not z1 or not x2 or not z2 or not ground or math.abs(x2 - x1) > 127 or math.abs(z2 - z1) > 127 then S.alert("invalid area") return end
    local dim=j.dim
    if words[7] then dim=P.dimension(words[7]) end
    local err=S.dimensionError(dim,ground+2) or P.heightError(dim,ground+4)
    if err then S.alert(err) return end
    if dim~=j.dim and next(j.turtles) then S.alert("remove turtles before dimension change") return end
    if dim~=j.dim then j.saplings,j.obstacles=nil,{} end
    j.dim=dim
    j.area = { x1 = math.min(x1, x2), z1 = math.min(z1, z2), x2 = math.max(x1, x2), z2 = math.max(z1, z2) }
    j.ground, j.visited, j.candidates, j.spots, j.nextRound, j.scanRequested = ground, {}, {}, {}, nil, nil
    j.clear = nil
    j.scanRound = nil
    for _, row in pairs(j.turtles) do
      row.phase, row.target, row.tree, row.service, row.probing, row.detour, row.motion = "scan", nil, nil, nil, nil, nil, nil
    end
    S.route = nil
  elseif words[1] == "saplings" and #words == 5 then
    local x, y, z = integer(2), integer(3), integer(4)
    if not x or not y or not z or (words[5] ~= "front" and words[5] ~= "down") then S.alert("invalid sapling chest") return end
    local err=S.dimensionError(j.dim,y) or P.heightError(j.dim,words[5]=="down" and y+1 or y)
    if err then S.alert(err) return end
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
    if row and row.turtle.forgotten and not SO.pair.key(id) then S.alert("turtle is not paired") return end
    if (j.running or row and row.pending) and not reanchor then S.alert("stop before configuring") return end
    if status.open and not reanchor then S.alert("turtle has open lease") return end
    local err=S.dimensionError(j.dim,y)
    if err then S.alert(err) return end
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
    if row.turtle.forgotten then S.alert("device forgotten; re-pair and re-add turtle") return end
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

S.legacyRender = function(w)
  local j = S.job
  local known, planted, saplings, fuel = 0, 0, 0, nil
  local alert, state, rows, workers = S.admission or j.alert, j.running and "running" or "stopped", {}, {}
  for _, spot in pairs(j.spots) do known = known + 1 if (spot.plantedAt or 0) > 0 then planted = planted + 1 end end
  local function add(text, red) rows[#rows + 1] = { text = text, fg = red and "e" or "0", bg = "f" } end
  for _, row in ipairs(S.rows()) do
    for _, item in ipairs(row.inv or {}) do if L.isSapling(item.name) then saplings = saplings + item.count end end
    if type(row.fuel) == "number" then fuel = math.min(fuel or row.fuel, row.fuel) end
    if not alert and row.alert then alert = "#" .. row.turtle.id .. " " .. row.alert end
    if row.blocked then state = row.blocked end
    local label = row.blocked or (row.paused and ((S.workerPark and row.parkConfirmed or not S.workerPark and row.idlePark) and "parked" or "parking")) or row.wait
      or (row.recover and "recovering") or (j.running and (row.service and row.service.kind or row.phase) or "stopped")
    workers[#workers + 1] = { "#" .. row.turtle.id .. " " .. tostring(label) .. " F" .. tostring(row.fuel or "?"), row.blocked ~= nil }
  end
  add("Lumber " .. tostring(state), state == "lost" or state == "out of range")
  add("Logs delivered " .. tostring(j.logs or 0))
  add("Saplings " .. saplings)
  add("Spots " .. known .. " planted " .. planted)
  add("Fuel " .. tostring(fuel or "?"))
  if alert and #alert > (w or 51) and alert:find(": ", 1, true) then
    local at = alert:find(": ", 1, true)
    add(alert:sub(1, at), true)
    add(alert:sub(at + 2), true)
  else add(alert or "", alert ~= nil) end
  for _, row in ipairs(workers) do add(row[1], row[2]) end
  if state ~= "running" and state ~= "stopped" then add("Fix cause, then type start", true) end
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
A.pose = function(v, cycle)
  local rows = {}
  for _, row in ipairs(S.rows()) do
    if not row.turtle.forgotten and SO.pair and SO.pair.key(row.turtle.id) then rows[#rows+1]=row end
  end
  local index = cycle and #rows > 1 and 2 or 1
  for i, row in ipairs(rows) do if row.turtle.id == v.poseId then index=cycle and i % #rows + 1 or i break end end
  local row=rows[index]
  v.poseId=row and row.turtle.id
  return row
end
A.dims = { ["minecraft:overworld"] = 0, ["minecraft:the_nether"] = -1, ["minecraft:the_end"] = 1 }
A.near = function(area, p)
  return p.dim == (A.dims[S.job.dim] or 0) and p.x >= area.x1 - 32 and p.x <= area.x2 + 32 and p.z >= area.z1 - 32 and p.z <= area.z2 + 32
end
-- The farm, its chests, the turtles and the facts.
A.gather = function()
  local j, now = S.job, SO.now()
  local daily, drops, lease = S.module("daily"), S.module("drops"), S.module("lease")
  local today = type(daily.today) == "function" and daily.today()
  local m = { state = j.cycle and j.cycle.phase == "complete" and "complete" or j.running and "running" or "stopped", alert = S.admission or j.alert, area = j.area, ground = j.ground,
    spots = {}, chests = {}, turtles = {}, ready = 0, total = 0, planted = 0, logs = today and today.logs, saplings = 0, chest = j.saplings }
  local blocked, recovering
  for _, row in ipairs(S.rows()) do
    local id, p = row.turtle.id, row.turtle.pose or row.turtle.anchor or {}
    local status = type(lease.status) == "function" and lease.status(id) or {}
    local word = status.lost and "lost" or row.blocked or (row.paused and ((S.workerPark and row.parkConfirmed or not S.workerPark and row.idlePark) and "parked" or "parking")) or row.wait
      or (j.running and (row.service and row.service.kind or A.phases[row.phase] or "working") or "idle")
    m.turtles[#m.turtles + 1] = { id = id, facing = p.facing, x = p.x, y = p.y, z = p.z, state = word, tone = S.ui and S.ui.tone(word) }
    for _, item in ipairs(row.inv or {}) do if L.isSapling(item.name) then m.saplings = m.saplings + item.count end end
    if type(row.fuel) == "number" then m.fuel = math.min(m.fuel or row.fuel, row.fuel) end
    if not m.alert and row.alert then m.alert = "#" .. id .. " " .. row.alert end
    blocked, recovering = blocked or row.blocked, recovering or row.recover
  end
  m.state = blocked or recovering and "recovering" or m.state
  for key, spot in pairs(j.spots) do
    local ready = (spot.plantedAt or 0) == 0 or now - spot.plantedAt >= 600000
    m.total = m.total + 1
    if ready then m.ready = m.ready + 1 end
    if (spot.plantedAt or 0) > 0 then m.planted = m.planted + 1 end
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
  return m
end
-- The setup tab's extra facts: start checks and unassigned turtles.
A.setupFacts = function(m)
  local lease, state = S.module("lease"), S.module("state")
  m.checks, m.available = {}, {}
  for _, check in ipairs(S.readiness()) do m.checks[#m.checks + 1] = { text = check.text, ok = check.ok } end
  for _, id in ipairs(type(lease.candidates) == "function" and lease.candidates() or {}) do
    local machine = type(state.get) == "function" and state.get("machines/" .. id) or {}
    m.available[#m.available + 1] = { id = id, fuel = machine.fuel }
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
A.run = function(C, y, m, gap, setup)
  local run = m.state == "running"
  local items = { { "START", "start", run and "muted" or "primary" }, { "STOP", "stop", run and "stop" or "muted" } }
  if S.scanNow and not setup and C.w >= 26 then items[#items + 1] = { "SCAN", "scan", S.job.scanRequested and "muted" or "primary" } end
  S.ui.actions(C, y, items, gap)
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
  for _, t in ipairs(m.turtles) do
  if t.x and t.x >= bx1 and t.x <= bx2 and t.z >= bz1 and t.z <= bz2 then
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
  end
  return row(bz2)
end
-- The turtles from row top to row stop, each row opening its details; +N more pages.
-- Returns the last row drawn.
A.turtles = function(C, m, top, stop, page)
  local ts, nt = m.turtles, stop - top + 1
  if #ts == 0 or nt < 1 then return top - 1 end
  local per = #ts > nt and math.max(1, nt - 1) or nt
  local first = ((page or 0) % math.ceil(#ts / per)) * per
  for i = 1, nt do
    local y, t = top + i - 1, ts[first + i]
    -- The last page keeps the row, so the pages wrap.
    if (i == nt or not t) and #ts > nt then
      C.put(4, y, "+" .. (#ts - math.min(per, #ts - first)) .. " more", "8")
      C.hit("turtles-next", 2, y, C.w - 2, 1)
      return y
    end
    if not t then return y - 1 end
    C.put(2, y, S.ui.arrow(t.facing), t.tone)
    C.put(4, y, tostring(t.id), "0")
    C.put(7, y, t.state:sub(1, math.min(10, C.w - 7)), A.fg(t.tone))
    -- The position only when it fits whole.
    if t.x and #A.at(t) <= C.w - 19 then C.put(18, y, A.at(t), "8") end
    C.hit("turtle:" .. t.id, 2, y, C.w - 2, 1)
  end
  return top + nt - 1
end
-- READY from row y to row stop between x and right: the missing start checks, the unassigned
-- turtles with an add chip, then the checks that pass. lead pages come before the list (the
-- narrow setup's controls); returns the last row drawn, or nil on a lead page.
A.ready = function(C, m, x, y, right, stop, offset, lead)
  local items, ok = A.items(m)
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
    C.put(x, last, S.ui.g.bullet, it[1])
    C.put(x + 2, last, it[2]:sub(1, math.max(0, right - x - 1 - (it[3] and 6 or 0))), "0")
    if it[3] then C.chip(right - 4, last, "add", "here:" .. it[3], "primary") end
  end
  return last
end
A.items = function(m)
  local items, ok = {}, 0
  for _, check in ipairs(m.checks) do if not check.ok then items[#items + 1] = { "e", check.text } end end
  for _, t in ipairs(m.available) do items[#items + 1] = { "1", "#" .. t.id .. " fuel " .. tostring(t.fuel or "?"), t.id } end
  for _, check in ipairs(m.checks) do
    if check.ok then items[#items + 1] = { "d", check.text } ok = ok + 1 end
  end
  return items, ok
end
A.room = function(C, m)
  local w, ya, U = C.w, C.h - 1, S.ui
  U.roleBar(C, "LUMBER", A.tabs, A.short, 1, m.state, U.tone(m.state))
  local fx, facts = w - 14, A.facts(m)
  for i, f in ipairs(facts) do C.leader(fx, 2 + 2 * i, 14, f[1], f[2], f[3]) end
  local bottom = A.plan(C, m, 2, 4, math.min(fx - 5, 64), math.min(ya - 9, 32))
  local last = A.turtles(C, m, bottom + 3, ya - 3, m.workerPage)
  for y = 3, math.max(last, 2 + 2 * #facts) do C.put(fx - 2, y, "|", "c") end
  if m.alert then C.flag(2, ya - 2, w - 2, m.alert) end
  A.run(C, ya, m, 3)
end
-- The alert ending on row y: one flag row, or two when it is longer than the row and splits at a
-- space. Returns the rows used.
A.alert = function(C, y, text)
  local width = C.w - 4
  local cut = #text > width and text:sub(1, width + 1):match("^.*() ")
  if not cut or cut < 2 then C.flag(2, y, C.w - 2, text) return 1 end
  C.flag(2, y - 1, C.w - 2, text:sub(1, cut - 1))
  C.put(4, y, text:sub(cut + 1, cut + width), "0")
  return 2
end
A.column = function(C, m)
  local w, ya, U = C.w, C.h, S.ui
  local shown = U.roleBar(C, "LUMBER", A.tabs, A.short, 1, m.state, U.tone(m.state))
  A.run(C, ya, m, 1)
  local f, last, top = A.facts(m), ya - 2 - (m.alert and A.alert(C, ya - 1, m.alert) or 0)
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
  -- Up to three turtle rows between the plan and the leaders.
  local nt = math.max(0, math.min(#m.turtles, 3, top - 8))
  if nt > 0 then
    top = top - 1 - nt
    A.turtles(C, m, top, top + nt - 1, m.workerPage)
    top = top - 1
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
  -- Ready and grow, then the turtles; without turtles the other leaders.
  local rows = #m.turtles > 0 and { f[1], { "grow", f[3][2], f[3][3] } } or { f[1], { "grow", f[3][2], f[3][3] }, f[5], f[6], f[4] }
  if not shown then table.insert(rows, 1, { "state", m.state, A.fg(U.tone(m.state)) }) end
  -- A long alert wraps onto a second row from 8 rows up.
  local used = 0
  if m.alert and h >= 4 then
    if h >= 8 then used = A.alert(C, h - 1, m.alert) else C.flag(2, h - 1, w - 2, m.alert) used = 1 end
  end
  local stop = h - 1 - math.max(1, used)
  local y = h >= 6 and 3 or 2
  for _, row in ipairs(rows) do
    if y > stop then break end
    C.leader(2, y, w - 2, row[1], row[2], row[3])
    y = y + 1
  end
  A.turtles(C, m, y, stop, m.workerPage)
  A.run(C, h, m, 1)
end
A.setup = function(C, m)
  local w, h, U = C.w, C.h, S.ui
  U.roleBar(C, "LUMBER", A.tabs, A.short, 2, m.state, U.tone(m.state))
  local room = w >= 52 and h >= 22
  local ya, step, vx = room and h - 1 or h, h >= 19 and 2 or 1, w >= 36 and 13 or 11
  local rx, a, c, ts = room and math.max(32, math.floor(w / 2)) or w + 2, m.area, m.chest, {}
  for _, t in ipairs(m.turtles) do if t.x then ts[#ts + 1] = "#" .. t.id .. " " .. A.at(t) end end
  local rows = { { "area", { a and (a.x1 .. "," .. a.z1 .. " " .. a.x2 .. "," .. a.z2) or "-" } },
    { "ground", { m.ground and tostring(m.ground) or "-" } },
    { "saplings", { c and (A.at(c) .. " " .. tostring(c.side)) or "-" } },
    { #ts > 1 and "turtles" or "turtle", #ts > 0 and ts or { "-" } } }
  if S.poseSetup then
    rows[1][3]="corners"
    rows[4] = {"turtle",{m.poseId and ("#"..m.poseId) or "-"},"pose-next"}
  end
  -- Narrow screens put each value on its own line under its label.
  local narrow = w < 36 and h >= 14
  local function values(y, stop)
    local last = y - 1
    for _, row in ipairs(rows) do
      if y + (narrow and 1 or 0) > stop then break end
      C.put(2, y, row[1], "8")
      last = y
      for i, v in ipairs(row[2]) do
        local vy = y + i - (narrow and 0 or 1)
        if vy > stop then break end
        local x = narrow and 4 or vx
        if row[3] == "corners" then
          local right=math.min(w-1,rx-3)
          local width=math.max(1,math.floor((right-x-5)/2))
          local first=m.corner and (m.corner.x..","..m.corner.z) or a and (a.x1..","..a.z1) or "from"
          local last=a and (a.x2..","..a.z2) or "to"
          local nx=C.chip(x,vy,first:sub(1,width),"from-here",m.corner and "on" or "plain")+1
          C.chip(nx,vy,last:sub(1,width),"to-here")
        elseif row[3] then C.chip(x,vy,v,row[3])
        elseif narrow then C.put(4, vy, v:sub(1, w - 4), v ~= "-" and "0" or "8")
        else C.put(vx, vy, v:sub(1, math.min(w - 1, rx - 3) - vx + 1), v ~= "-" and "0" or "8") end
        last = vy
      end
      y = y + #row[2] - 1 + (narrow and 3 or step)
    end
    return last
  end
  local stop = m.alert and ya - 2 or ya - 1
  if room then
    local last, right = values(3, ya - 2), A.ready(C, m, rx + 2, 3, w - 1, ya - 3, m.setupPage)
    for yy = 3, math.max(last, right) do C.put(rx, yy, "|", "c") end
  else
    -- READY follows the values; when it does not fit under them it gets pages of its own after
    -- the values' page, which ends with the READY row.
    local real = C
    C = S.ui.canvas(w, h)
    local last = values(3, ya - 2)
    C = real
    if #A.items(m) <= math.max(0, stop - last - 2) then A.ready(C, m, 2, values(3, ya - 2) + 2, w - 1, stop, m.setupPage)
    elseif stop >= 4 then
      local shown, pages = A.ready(C, m, 2, 3, w - 1, stop, m.setupPage, 1)
      if not shown then
        values(3, math.min(ya - 2, stop - 1))
        C.section(2, stop, w - 2, "READY", "1/" .. pages)
        C.hit("setup-next", 2, stop, w - 2, 1)
      end
    else values(3, ya - 2) end
  end
  if m.alert then C.flag(2, ya - (room and 2 or 1), w - 2, m.alert) end
  A.run(C, ya, m, room and 3 or 1, true)
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
  local v, m = A.view(session), A.gather()
  m.workerPage, m.setupPage = v.workers, v.offset
  if v.page == "setup" then A.pose(v) m.poseId,m.corner=v.poseId,v.corner A.setupFacts(m) end
  return A.layout(m, w, h, v.page == "setup")
end
-- Job facts for other screens (the pocket's JOBS page); pure reads.
S.facts = function()
  if not S.ui and (not fs or not fs.exists or fs.exists("so-ui.lua")) then S.ui = dofile("so-ui.lua") end
  local m = A.gather()
  return { state = m.state, ready = m.ready, spots = m.total, grow = m.grow, saplings = m.saplings, fuel = m.fuel, alert = m.alert,
    cycleMode = S.job.cycleMode, species = S.job.species and SO.store.copy(S.job.species) or false,
    cycle = S.job.cycle and { id = S.job.cycle.id, phase = S.job.cycle.phase } }
end

S.reconcile = function(row,record)
  local lease = S.module("lease")
  record = record or lease.outcome and lease.outcome(row.turtle.id)
  if not record or record.owner ~= "lumber" then return false end
  S.row = row
  local receipt = record.id .. ":" .. record.status
  if row.leaseReceipt ~= receipt then
    row.pending = SO.store.copy(record.intent) or {action="recover",steps=record.steps,pose=row.turtle.pose}
    row.pending.id = record.id
    row.recover = false
    S.reconciling = true
    S.report(record.id,row.turtle.id,record.results,record)
    S.reconciling = nil
    row.leaseReceipt = receipt
  end
  if S.save() and lease.ackOutcome(record.id) and not lease.status(row.turtle.id).recovering
    and S.job.running and not row.paused and not row.blocked and not row.recover then
    if row.nextDispatch then
      local nextDispatch = row.nextDispatch
      row.nextDispatch = nil
      S.send(nextDispatch.steps,nextDispatch.action,nextDispatch.cells,nextDispatch.recover,nextDispatch.ms,nextDispatch.route)
    elseif row.resumeRoute then
      local route = row.resumeRoute
      row.resumeRoute = nil
      if not S.send(route.rest,route.action,nil,route.recover,route.ms,route) then row.resumeRoute,row.recover=route,true end
    end
  end
  return true
end
S.durableReport = function(id,turtleId,results,record)
  local row = S.job.turtles[tostring(turtleId)]
  if not row or row.turtle.forgotten then return end
  if S.module("lease").outcome then S.reconcile(row,record)
  else S.report(id,turtleId,results,record) end
end
S.tickRow = function(row, now)
  if row.turtle.forgotten then return end
  if S.reconcile(row) then return end
  S.row = row
  local j, lease = S.row, S.module("lease")
  local status = lease.status(j.turtle.id)
  local tool = P.toolCheck(status.tools,"axe")
  if type(lease.describe) == "function" then
    lease.describe(j.turtle.id,"lumber",not tool.ok and tool.text or j.alert or j.blocked or j.phase or "idle")
  end
  if status.uncertain then
    if j.inflight or j.uncertain then S.suspendService() end
    j.blocked = "pose uncertain"
    S.alert("pose uncertain: re-add turtle " .. j.turtle.id)
    return
  end
  if status.lost then
    if S.member(j) then S.job.cycle.parked[tostring(j.turtle.id)] = nil end
    j.recover, j.parkConfirmed = true, nil j.blocked = "lost"
    if not j.pending and not status.open then S.suspendService() end
  end
  if j.pending or status.open then return end
  if j.recover then
    j.nextDispatch, j.resumeRoute = nil, nil
    if S.member(j) then S.job.cycle.parked[tostring(j.turtle.id)] = nil end
    local cells,p=S.module("cells"),j.turtle.pose
    local gps="gps:"..j.turtle.id
    if cells.owner and cells.owner(p.x,p.y,p.z,p.dim)==gps then
      if not cells.handoff then S.alert("standing cell handoff unavailable") return end
      local ok,err=cells.handoff(gps,S.owner(),p.x,p.y,p.z,p.dim)
      if not ok then S.alert(err) return end
    end
    S.suspendService()
    if not j.turtle.frame and not j.turtle.anchor then S.alert("waiting for reported pose") return end
    S.park(true)
    return
  end
  if lease.restartReady and not lease.restartReady() then return end
  if S.workerPark and j.paused then
    if j.removeRequested and j.parkConfirmed then S.removeParked()
    elseif not j.parkConfirmed or not j.parkAt or now-j.parkAt>=540000 then S.park() end
    return
  end
  if S.job.cycle and not S.member(j) then
    if not j.idlePark or not j.parkAt or now - j.parkAt >= 540000 then S.park() end
    return
  end
  if S.job.running and not j.paused and j.blocked == "fuel" and j.fuelRetry and now >= j.fuelRetry then
    local shop = S.module("shop")
    local policy = shop.fuelConfig and shop.fuelConfig()
    if policy and policy.auto and j.service and j.service.kind == "fuel" then
      local usable, reason = S.usable(j.service.point)
      if not usable then
        j.fuelRetry=now+60000
        S.chestAlert("fuel",reason,j.service.point)
        S.save()
        return
      end
      j.blocked, j.fuelRetry = nil, nil
      if j.service.stage ~= "returnFuelItem" and not (j.service.logReturnHold and j.service.stage == "travel") then
        j.service.stage = "check"
      end
      if not j.service.logReturnHold then j.alert = nil S.emit("lumber.alert",false) end
      S.save()
    end
  end
  if type(lease.ensureTool) == "function" then
    local equipped, reason = lease.ensureTool(j.turtle.id,"axe")
    if not equipped then S.invalidateProof(j) S.alert(reason) S.park() return end
    if j.alert and (j.alert == "needs axe" or j.alert:match("^tool swap failed:")) then j.alert=nil S.save() end
  end
  if S.job.dim ~= "minecraft:overworld" then
    local err=S.dimensionError(S.job.dim,j.turtle.pose.y) or P.heightError(S.job.dim,(S.job.ground or 0)+2)
    if err then j.blocked="hold" S.alert(err) end
  end
  if j.blocked or j.paused or not S.job.running or not S.job.area or not j.turtle.frame then
    if not j.idlePark or not j.parkAt or now - j.parkAt >= 540000 then S.park() end
    return
  end
  if j.nextDispatch then
    local nextDispatch = j.nextDispatch
    j.nextDispatch = nil
    S.send(nextDispatch.steps,nextDispatch.action,nextDispatch.cells,nextDispatch.recover,nextDispatch.ms,nextDispatch.route)
    return
  end
  if j.resumeRoute then
    local route = j.resumeRoute
    j.resumeRoute = nil
    if not S.send(route.rest,route.action,nil,route.recover,route.ms,route) then
      j.resumeRoute, j.recover = route, true
    end
    return
  end
  if j.motion then
    local motion = j.motion
    local sent = S.send(motion.steps or { { op = motion.op } }, motion.action or "motion",
      motion.cell and { j.turtle.pose, motion.cell })
    if sent then j.motion = nil end
    return
  end
  if not j.service and type(j.fuel) == "number" and j.fuel >= 0 and j.fuel < S.fuelNeed() then
    if not S.service("fuel") then return end
  end
  S.work(now)
end
S.advanceCycle = function()
  local job, lease = S.job, S.module("lease")
  if not job.running or not S.once() then return end
  local cycle = job.cycle
  for id in pairs(cycle.members) do
    local row = job.turtles[id]
    if not row or row.turtle.forgotten or row.recover or row.blocked or row.paused or row.pending
      or row.target or row.tree or row.service or row.delivery or row.motion then return end
    local status = lease.status(row.turtle.id)
    if status.open or status.lost or status.uncertain then return end
  end
  if cycle.phase == "survey" then
    if #cycle.candidates > 0 or cycle.cursor <= #cycle.targets or next(cycle.claims) then return end
    cycle.phase = "finishing"
    for id in pairs(cycle.members) do job.turtles[id].phase, job.turtles[id].wait = "cycleUnload", nil end
    S.save()
  else
    for id in pairs(cycle.members) do
      local row = job.turtles[id]
      S.row = row
      if not cycle.parked[id] or not cycle.parks[id] or not P.samePose(row.turtle.pose, cycle.parks[id])
        or not S.parkSafe(cycle.parks[id]) then return end
    end
    cycle.phase, job.running = "complete", false
    if not S.save() then cycle.phase = "finishing" end
  end
end
S.tick = function(now)
  if S.pauseCleared then
    if not S.save() then return end
    S.pauseCleared=nil
  end
  local lease, display = S.module("lease"), S.module("display")
  if not S.wired and type(display.screen) == "function" then display.screen("lumber", S.render, S.input) S.wired = true end
  if not S.callback and type(lease.onReport) == "function" then lease.onReport("lumber", S.durableReport) S.callback = true end
  if not S.callback or type(lease.status) ~= "function" then return end
  local rows = S.rows()
  local requested = S.scanNow and S.job.scanRequested and S.job.running and S.job.area and S.job.ground ~= nil
  if not S.once() and S.job.cycleMode ~= "once" and (requested or S.job.nextRound and now >= S.job.nextRound) then
    local active = false
    for _, row in ipairs(rows) do
      if (requested or not row.blocked) and (row.target or row.tree or row.service or row.motion
        or requested and row.phase == "roundEnd") then active = true end
    end
    if not active then
      S.job.nextRound, S.job.visited, S.job.candidates = nil, {}, {}
      S.job.scanRound = requested == true or nil
      if requested then S.job.scanRequested = nil end
      for _, row in ipairs(rows) do if row.phase == "waiting" then row.phase = "scan" end end
      S.save()
    end
  end
  S.advanceCycle()
  for _, row in ipairs(rows) do S.tickRow(row, now) end
  S.advanceCycle()
  S.row = nil
end

S.dugProtection = function(protect)
  for _, row in pairs(S.job.turtles) do
    if row.turtle.forgotten or row.recover or not row.turtle.frame then return false end
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
  local turtles = {}
  for id, row in pairs(j.turtles) do
    turtles[id] = { id=row.turtle.id, pose=SO.store.copy(row.turtle.pose), phase=row.phase,
      state=row.blocked or (row.paused and (row.parkConfirmed and "parked" or "parking")) or row.wait or (j.running and "lumber" or "idle") }
  end
  return {dim=j.dim,area=SO.store.copy(j.area),ground=j.ground,saplings=SO.store.copy(j.saplings),spots=spots,
    running=j.running,grow=grow,turtles=turtles}
end
S.turtleView = function()
  local model, out = A.gather(), {}
  for _, worker in ipairs(model.turtles) do
    local row = S.job.turtles[tostring(worker.id)]
    local action = row.pending and row.pending.action
    out[tostring(worker.id)] = { role="lumber", pose=SO.store.copy(row.turtle.pose),
      anchor=SO.store.copy(row.turtle.anchor), state=row.paused and row.parkConfirmed and "parked" or worker.state, fuel=row.fuel,
      parkConfirmed=row.parkConfirmed, paused=row.paused,
      inv=SO.store.copy(row.inv or {}), done=model.planted, total=model.total,
      error=row.alert or S.admission or S.job.alert, step=type(action)=="table" and action.kind or action }
  end
  return out
end
S.forget = function(id)
  local row = S.job.turtles[tostring(id)]
  if not row then return true end
  if row.inflight then row.uncertain = S.possible(row.uncertain, row.inflight) end
  row.turtle.forgotten, row.paused, row.blocked = true, true, "device forgotten"
  row.pending, row.motion, row.idlePark, row.recover = nil, nil, nil, true
  local previous = S.row
  S.row = row
  S.suspendService()
  S.row = previous
  return S.save()
end
return { name = "lumber", forget = S.forget, assigned = function(id) return S.job.turtles[tostring(id)] ~= nil end, handlers = {},
  turtleView = S.turtleView, tick = S.tick, dugProtection = S.dugProtection, mapView = S.mapView, facts = S.facts }
