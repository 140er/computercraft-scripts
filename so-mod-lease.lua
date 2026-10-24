local S = { turtles = {}, callbacks = {}, seq = 0 }
S.rules = function()
  if not S.plan then S.plan=dofile("so-plan.lua") end
  return S.plan
end

S.number = function(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

S.position = function(p)
  return type(p) == "table" and S.number(p.x) and S.number(p.y) and S.number(p.z)
end

S.copyPose = function(p)
  if not S.position(p) then return nil end
  return { dim = p.dim, x = p.x, y = p.y, z = p.z, facing = p.facing }
end

S.journalPose = function(p)
  if not S.position(p) or not S.number(p.f) or p.f % 1 ~= 0 or p.f < 0 or p.f > 3 then return nil end
  return { x = p.x, y = p.y, z = p.z, f = p.f }
end

S.facts = function(body)
  local facts = { pose = not body.uncertain and S.journalPose(body.pose) or nil, uncertain = body.uncertain == true or nil }
  if type(body.journal) == "string" then facts.journal = body.journal end
  if S.number(body.fuel) then facts.fuel = body.fuel end
  if type(body.inv) == "table" then
    local good = true
    for _, item in pairs(body.inv) do
      if type(item) ~= "table" or not S.number(item.slot) or item.slot % 1 ~= 0
        or item.slot < 1 or item.slot > 16 or type(item.name) ~= "string"
        or not S.number(item.count) or item.count < 0 then good = false break end
    end
    if good then facts.inv = SO.store.copy(body.inv) end
  end
  if type(body.dug) == "table" then
    local good = true
    for _, cell in pairs(body.dug) do if not S.position(cell) then good = false break end end
    if good then facts.dug = SO.store.copy(body.dug) end
  end
  return facts
end

S.journalSeen = function(row, pose, journal)
  local p = S.journalPose(pose)
  if type(journal) == "string" and journal ~= row.journal and not p then
    row.pose, row.poseAt = nil, nil
  end
  if p then row.pose, row.poseAt = p, SO.now() end
  if type(journal) == "string" then row.journal = journal end
end

S.fix = function(row, fix, pose, journal)
  if not S.position(fix) or fix.x % 1 ~= 0 or fix.y % 1 ~= 0 or fix.z % 1 ~= 0 then
    row.fix = nil return
  end
  local previous = row.fix
  row.fix = { dim = fix.dim, x = fix.x, y = fix.y, z = fix.z, at = SO.now(), pose = S.journalPose(pose), journal = journal }
  if previous and previous.dim ~= fix.dim then row.rotation = nil previous = nil end
  if not previous or not previous.pose or not row.fix.pose then return end
  local dx, dz = pose.x - previous.pose.x, pose.z - previous.pose.z
  if dx == 0 and dz == 0 then
    if fix.x ~= previous.x or fix.z ~= previous.z or fix.y-previous.y ~= pose.y-previous.pose.y then row.rotation = nil end
    return
  end
  local wx, wz = fix.x - previous.x, fix.z - previous.z
  for rot = 0, 3 do
    if dx == wx and dz == wz and fix.y - previous.y == pose.y - previous.pose.y then
      row.rotation = { journal = journal, rot = rot }
      return
    end
    dx, dz = -dz, dx
  end
  row.rotation = nil
end

S.world = function(id, dim)
  local row = S.row(id)
  if not SO.pair.key(id) then return nil, "turtle not paired" end
  if row.uncertain or row.anchor then return nil, "pose uncertain; use explicit add" end
  if row.lost then return nil, "turtle lost; wait for hello" end
  if row.open and not (#row.open.steps == 1 and row.open.steps[1].op == "inspectDown") then return nil, "turtle has open lease" end
  local fix = row.fix
  if not fix or SO.now() - fix.at > 60000 or not row.poseAt or fix.at < row.poseAt then
    return nil, "no fresh GPS; use explicit add"
  end
  local config = SO.store.read("so-server.cfg")
  local serverDim = S.pos and S.pos.dim or config and config.pos and config.pos.dim
  if not serverDim then return nil, "GPS dimension unknown; use explicit add" end
  if not fix.dim then return nil, "GPS dimension unknown; set so-worker.cfg" end
  if dim ~= fix.dim or dim ~= serverDim and dim == "minecraft:overworld" then return nil, "GPS dimension mismatch" end
  if dim ~= "minecraft:overworld" then
    local err = S.rules().dimensionError(dim, config)
    return nil, err or "remote GPS untrusted; use explicit add"
  end
  local pose = { dim = dim, x = fix.x, y = fix.y, z = fix.z }
  if row.rotation and row.pose then
    pose.facing = (row.pose.f + row.rotation.rot) % 4
  end
  return pose
end

S.candidates = function()
  local out = {}
  for id, row in pairs(S.turtles) do
    local assigned = false
    for _, name in ipairs({"mine", "lumber", "build"}) do
      local mod = S.module(name)
      if mod and mod.assigned and mod.assigned(id) then assigned = true end
    end
    local drops=S.module("drops")
    if drops and drops.busy and drops.busy(id) then assigned=true end
    if row.worker and SO.pair.key(id) and not assigned and not row.open and not row.probeOwner then out[#out + 1] = id end
  end
  table.sort(out)
  return out
end

S.locate = function(id, dim, done)
  for _, name in ipairs({"mine", "lumber", "build"}) do
    local mod = S.module(name)
    if mod and mod.assigned and mod.assigned(id) then done(nil, "turtle already assigned") return end
  end
  local pose, err = S.world(id, dim)
  if not pose then done(nil, err) return end
  if pose.facing ~= nil then done(pose) return end
  local row, cells = S.row(id), S.module("cells")
  if row.open then done(nil, "turtle has open lease") return end
  if not row.parkBatch then done(nil, "probe needs worker update; use explicit add") return end
  if not row.pose or not cells then done(nil, "facing unknown; use explicit add") return end
  local owner, area = "gps:" .. id, { pose }
  for f = 0, 3 do
    local p = SO.store.copy(pose) p.facing = f
    local x, y, z = p.x+({[0]=0,1,0,-1})[f], p.y, p.z+({[0]=-1,0,1,0})[f]
    area[#area + 1] = { dim = dim, x = x, y = y, z = z }
  end
  local reserved, why = cells.reserveMany(owner, area)
  if not reserved then done(nil, why or "probe area reserved") return end
  local expected = SO.store.copy(row.pose)
  expected.x = expected.x+({[0]=0,1,0,-1})[expected.f]
  expected.z = expected.z+({[0]=-1,0,1,0})[expected.f]
  row.probeOwner = owner
  row.probe = { before = pose, done = done, owner = owner, pose = expected }
  local lid, reason = S.send(id, {{op="forward",park=true}, {op="gps"}}, {owner="gps", ms=15000})
  if not lid then row.probe = nil S.clearProbe(id) done(nil, reason) end
end

S.claimProbe = function(id, owner, pose)
  local cells = S.module("cells")
  local from = "gps:" .. id
  if not cells or not cells.list or #cells.list(from,1) == 0 then return true end
  if cells.owner(pose.x,pose.y,pose.z,pose.dim) == from then
    return cells.handoff(from,owner,pose.x,pose.y,pose.z,pose.dim)
  end
  return cells.reserve(owner,pose.x,pose.y,pose.z,pose.dim)
end

S.clearProbe = function(id)
  local row, cells = S.row(id), S.module("cells")
  local owner = "gps:" .. id
  local held = row.probeOwner or cells and cells.list and #cells.list(owner,1) > 0
  if not held then return true end
  if row.open then return false, "GPS probe has open lease" end
  local ok, err = cells.releaseOwner(owner)
  if ok == false then return false, err end
  row.probeOwner = nil
  return true
end

S.probed = function(row, results, lease)
  local probe = row.probe
  if not probe then return end
  row.probe = nil
  local fix = results and results[2] and results[2].data
  local valid = results and results[1].ok and results[2].ok and not row.uncertain
    and lease.report and row.pose and row.pose.x == probe.pose.x and row.pose.y == probe.pose.y
    and row.pose.z == probe.pose.z and row.pose.f == probe.pose.f and S.position(fix) and fix.dim == probe.before.dim
  local before = probe.before
  local dx, dy, dz = valid and fix.x-before.x, valid and fix.y-before.y, valid and fix.z-before.z
  local f = dy == 0 and (dx == 1 and dz == 0 and 1 or dx == -1 and dz == 0 and 3
    or dz == 1 and dx == 0 and 2 or dz == -1 and dx == 0 and 0)
  if f ~= false and f ~= nil then
    row.rotation = { journal = row.journal, rot = (f-row.pose.f)%4 }
    S.fix(row, fix, row.pose, row.journal)
    local p = {dim=before.dim,x=fix.x,y=fix.y,z=fix.z,facing=f}
    probe.done(p)
  elseif results and not results[1].ok and S.position(fix)
    and fix.x == before.x and fix.y == before.y and fix.z == before.z then
    local ok, err = S.clearProbe(lease.turtleId)
    probe.done(nil, not ok and err or "probe blocked; use explicit add")
  else
    row.fix = nil
    probe.done(nil, "probe pose unknown; use explicit add")
  end
end

S.distance = function(p)
  if not S.pos or not S.position(p) then return nil end
  if S.pos.dim ~= nil and p.dim ~= nil and S.pos.dim ~= p.dim then return nil end
  local dx, dy, dz = p.x - S.pos.x, p.y - S.pos.y, p.z - S.pos.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

S.row = function(id)
  local row = S.turtles[id]
  if not row then
    row = { lost = false, range = 16, seen = 0 }
    S.turtles[id] = row
  end
  return row
end

S.observe = function(row, pose)
  local distance = S.distance(pose)
  if distance then
    if distance > row.range then row.range = distance end
    row.posed = true
  end
end

S.module = function(name)
  return type(SO.mods) == "table" and SO.mods[name] or nil
end

S.emit = function(kind, body)
  local state = S.module("state")
  if type(state) == "table" and type(state.emit) == "function" then state.emit(kind, body) end
end

S.notify = function(lease, results)
  local callback = lease.owner and S.callbacks[lease.owner]
  if callback then
    local ok, err = pcall(callback, lease.id, lease.turtleId, results, lease)
    if not ok then print("so-lease: callback failed: " .. tostring(err)) end
  end
end

S.anchorSend = function(id, row)
  local key = SO.pair.key(id)
  if not key then return false, "no key" end
  local wire = SO.proto.encode(SO.proto.build(key, "worker.anchor", row.anchor.body))
  if not wire then return false, "anchor" end
  local ok, sent = pcall(rednet.send, id, wire, "so")
  row.anchor.after = SO.now() + 1000
  return ok and sent ~= false
end

S.reanchor = function(id, pose)
  local row = S.row(id)
  if not row.uncertain or type(row.journal) ~= "string" then return nil, "pose not uncertain" end
  if not S.position(pose) or type(pose.facing) ~= "number" or pose.facing % 1 ~= 0
    or pose.facing < 0 or pose.facing > 3 then return nil, "pose" end
  row.anchor = { body = { journal = row.journal,
    pose = { x = pose.x, y = pose.y, z = pose.z, f = pose.facing } } }
  local ok, err = S.anchorSend(id, row)
  if not ok then row.anchor = nil return nil, err or "send" end
  local lease = row.open
  row.open = nil
  if lease then lease.status = "reanchored" S.notify(lease, nil) end
  return true
end

S.encodeLease = function(key, lease)
  return SO.proto.encode(SO.proto.build(key, "lease.batch", {
    lease = lease.id, ttl = math.max(0, lease.expires - SO.now()),
    expires = os.epoch("utc") + math.max(0, lease.expires - SO.now()), steps = lease.steps,
    journal = lease.journal,
  }))
end

S.remoteReady = function(id, dim)
  local err = S.rules().dimensionError(dim, SO.store.read("so-server.cfg"))
  if err then return false, err end
  local row = S.turtles[id]
  if not row or not row.dimensionSafety then return false, "update remote worker" end
  if row.dim ~= dim then return false, "worker dimension mismatch; set so-worker.cfg" end
  return true
end

S.send = function(id, steps, opts)
  if not S.number(id) or id < 0 or id % 1 ~= 0 then return nil, "id" end
  local row = S.row(id)
  if row.uncertain or row.anchor then return nil, "pose uncertain" end
  if row.lost and not (type(opts) == "table" and opts.recover == true) then return nil, "lost" end
  if row.open then return nil, "busy" end
  if type(steps) ~= "table" or #steps < 1 or #steps > 16 then return nil, "steps" end
  local count = 0
  for key, step in pairs(steps) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #steps or type(step) ~= "table" then
      return nil, "steps"
    end
    count = count + 1
  end
  if count ~= #steps then return nil, "steps" end
  if opts ~= nil and type(opts) ~= "table" then return nil, "opts" end
  opts = opts or {}
  local ms = opts.ms or 60000
  if not S.number(ms) or ms <= 0 then return nil, "ms" end
  if opts.owner ~= nil and type(opts.owner) ~= "string" then return nil, "owner" end
  if opts.pose ~= nil and not S.position(opts.pose) then return nil, "pose" end
  local remote = opts.pose and (opts.pose.dim == "minecraft:the_nether" or opts.pose.dim == "minecraft:the_end")
  if remote and not (#steps == 1 and steps[1].op == "inspectDown") then
    local ready, why = S.remoteReady(id, opts.pose.dim)
    if not ready then return nil, why end
  end
  local state = S.module("state")
  if state and state.canWork and not state.canWork() and not opts.recover
    and not (#steps == 1 and steps[1].op == "inspectDown") then return nil, "DISK events pending" end
  local key = SO.pair.key(id)
  if not key then return nil, "no key" end
  if not row.posed then
    local state = S.module("state")
    if type(state) == "table" and type(state.get) == "function" then
      local machine = state.get("machines/" .. id)
      if type(machine) == "table" then S.observe(row, machine.pose) end
    end
  end
  S.seq = S.seq + 1
  local lease = {
    id = tostring(id) .. "-" .. string.format("%.0f", SO.now()) .. "-" .. S.seq, turtleId = id, steps = SO.store.copy(steps),
    owner = opts.owner, journal = opts.journal, pose = S.copyPose(opts.pose), expires = SO.now() + ms, status = "open",
  }
  if remote then
    local at = S.copyPose(opts.pose)
    local reverse={forward="back",back="forward",up="down",down="up",turnLeft="turnRight",turnRight="turnLeft"}
    for i=#lease.steps,1,-1 do
      local step = lease.steps[i]
      if step.op=="forward" or step.op=="back" or step.op=="up" or step.op=="down" then
        local err = S.rules().heightError(opts.pose.dim,at.y)
        if err then return nil, err end
        step.safety=S.copyPose(at)
      end
      if reverse[step.op] then at=S.rules().apply(at,reverse[step.op]) end
    end
  end
  if #steps == 1 and steps[1].op == "inspectDown" then
    lease.retryAt = SO.now() + 1000
  end
  local wire, err = S.encodeLease(key, lease)
  if not wire then return nil, err end
  row.open = lease
  local ok, sent = pcall(rednet.send, id, wire, "so")
  if not ok or sent == false then row.open = nil return nil, "send" end
  return lease.id
end

S.snapshot = function(row)
  if not row then return nil end
  return { open = row.open and row.open.id or nil, lost = row.lost, range = row.range, seen = row.seen,
    tools = SO.store.copy(row.tools), toolError = row.toolError, autoToolSwap = row.autoToolSwap == true,
    fuel = row.fuel, parkBatch = row.parkBatch, setupFence = row.setupFence, probing = row.probe ~= nil, fix = SO.store.copy(row.fix), rotation = SO.store.copy(row.rotation),
    pose = S.journalPose(row.pose), journal = row.journal, poseAt = row.poseAt, uncertain = row.uncertain or row.anchor and true or nil }
end

S.status = function(id) return S.snapshot(S.row(id)) end
S.peek = function(id) return S.snapshot(S.turtles[id]) end

S.cancelPark = function(id, owner)
  local row = S.turtles[id]
  local lease = row and row.open
  if not lease then return true end
  if owner ~= "mine" or lease.owner ~= owner or #lease.steps ~= 1
    or lease.steps[1].op ~= "inspectDown" then return false, "turtle has open lease" end
  row.open = nil
  lease.status = "cancelled"
  return true
end

S.forget = function(id, key)
  local row = S.turtles[id]
  if not row then return end
  if key then
    S.seq = S.seq + 1
    local wire = S.encodeLease(key, {
      id = "forget-" .. id .. "-" .. S.seq, expires = SO.now() + 600000, steps = {{op="inspectDown"}},
    })
    if wire then pcall(rednet.send, id, wire, "so") end
  end
  -- Without a final report, every reserved cell may still be occupied.
  row.open, row.probe, row.anchor = nil, nil, nil
  row.uncertain, row.lost = true, true
  row.pose, row.poseAt = nil, nil
end

S.inRange = function(id, pos)
  if pos and (pos.dim == "minecraft:the_nether" or pos.dim == "minecraft:the_end") then
    return S.remoteReady(id, pos.dim)
  end
  if not S.pos then return true end
  local distance = S.distance(pos)
  return distance ~= nil and distance <= (S.turtles[id] and S.turtles[id].range or 16) + 8
end

S.report = function(msg)
  local row = S.row(msg.from)
  local body = msg.body
  local lease = row.open
  if not lease or type(body) ~= "table" or body.lease ~= lease.id then
    if not row.warned then
      row.warned = true
      print("so-lease: ignored report from " .. tostring(msg.from))
    end
    return
  end
  local results = body.results
  if type(results) ~= "table" or #results ~= #lease.steps then return end
  local count, allOk = 0, true
  for i, result in pairs(results) do
    if type(i) ~= "number" or i % 1 ~= 0 or i < 1 or i > #lease.steps
      or type(result) ~= "table" or type(result.ok) ~= "boolean" then return end
    count = count + 1
    if not result.ok then allOk = false end
  end
  if count ~= #lease.steps then return end
  row.open = nil
  S.tools(row, body.tools)
  row.seen = SO.now()
  row.lost = false
  lease.report = S.facts(body)
  row.fuel = lease.report.fuel
  row.uncertain = lease.report.uncertain
  if row.uncertain then row.pose, row.poseAt = nil, nil end
  S.journalSeen(row, lease.report.pose, lease.report.journal)
  lease.status = "reported"
  if allOk and lease.pose and not row.uncertain then
    local pose = S.copyPose(lease.pose)
    pose.id = msg.from
    if row.pose and pose.facing ~= nil then row.rotation = { rot = (pose.facing-row.pose.f)%4 } end
    S.emit("pose", pose)
    S.observe(row, pose)
  end
  if lease.owner == "tools" then
    row.toolError = not allOk and ("tool swap failed: "..tostring(results[1].err or "failed")) or nil
  elseif lease.owner == "gps" then S.probed(row, results, lease) else S.notify(lease, results) end
end

S.beacon = function(msg)
  local row = S.row(msg.from)
  row.lost = true
  row.seen = SO.now()
  row.uncertain = msg.body.uncertain == true or nil
  if row.uncertain then row.pose, row.poseAt = nil, nil row.journal = msg.body.journal
  else S.journalSeen(row, msg.body.pose, msg.body.journal) end
  S.emit("machine", { id = msg.from, fuel = msg.body.fuel, seen = row.seen, journal = row.journal })
end

S.tools = function(row, tools)
  if type(tools) ~= "table" then row.tools = nil return end
  local clean = {}
  for _, side in ipairs({"left", "right"}) do
    local name = tools[side]
    if name ~= false and (type(name) ~= "string" or #name > 128) then row.tools = nil return end
    clean[side] = name
  end
  row.tools = clean
end

S.describe = function(id, job, reason)
  local row = S.row(id)
  local text = job.."/"..reason
  if row.description == text and SO.now()-(row.describedAt or 0)<30000 then return end
  local key = SO.pair.key(id)
  if not key then return end
  local wire = SO.proto.encode(SO.proto.build(key,"worker.status",{job=job,reason=reason}))
  if wire then rednet.send(id,wire,"so"); row.description, row.describedAt = text, SO.now() end
end

S.ensureTool = function(id, kind)
  local row = S.row(id)
  if not row.tools then return true end
  for _, name in pairs(row.tools) do
    if type(name) == "string" and name:match("_"..kind.."$") then row.toolError = nil return true end
  end
  if not row.autoToolSwap then return true, "needs "..kind end
  if not row.open and not row.uncertain and not row.lost
    and SO.now() >= (row.toolRetry or 0) then
    row.toolRetry = SO.now()+30000
    S.send(id, {{op="tool",kind=kind}}, {owner="tools"})
  end
  return false, row.toolError or ("needs "..kind)
end

S.hello = function(msg)
  local row = S.row(msg.from)
  row.lost = false
  row.seen = SO.now()
  row.fuel = (S.number(msg.body.fuel) or msg.body.fuel == "unlimited") and msg.body.fuel or nil
  S.tools(row, msg.body.tools)
  row.autoToolSwap = type(msg.body.capabilities) == "table" and msg.body.capabilities.autoToolSwap == true
  row.dimensionSafety = type(msg.body.capabilities) == "table" and msg.body.capabilities.dimensionSafety == true
  row.dim = msg.body.dim
  row.worker = msg.body.role == "turtle" or msg.body.role == "worker"
  row.setupFence = type(msg.body.capabilities) == "table" and msg.body.capabilities.setupFence == true
  row.parkBatch = type(msg.body.capabilities) == "table" and msg.body.capabilities.parkBatch == true
  local journal = msg.body.journal
  if type(journal) == "table" then
    if journal.seq and row.seq and journal.seq < row.seq then row.rotation, row.fix = nil, nil end
    row.seq = journal.seq
    row.uncertain = journal.uncertain == true or nil
    if row.uncertain then row.pose, row.poseAt = nil, nil row.journal = journal.id
    else
      if row.anchor and (type(journal.recovery) ~= "table" or journal.recovery.outcome ~= "anchored"
        or journal.recovery.journal ~= row.anchor.body.journal) then row.uncertain = true return end
      row.anchor = nil
      S.journalSeen(row, journal.pose, journal.id)
    end
  end
  S.fix(row, msg.body.gps, row.pose, row.journal)
  if type(journal) == "table" and journal.recovery and journal.recovery.outcome == "anchored"
    and row.fix and row.pose and row.fix.x == row.pose.x and row.fix.y == row.pose.y and row.fix.z == row.pose.z then
    row.rotation = { journal = row.journal, rot = 0 }
  end
  S.observe(row, msg.body.pose or msg.body.gps)
end

S.tick = function(now)
  now = now or SO.now()
  local count = 0
  for id, row in pairs(S.turtles) do
    if row.anchor and now >= row.anchor.after then S.anchorSend(id, row) end
    local lease = row.open
    if lease and now > lease.expires + 10000 then
      row.open = nil
      lease.status = "expired"
      if lease.owner == "gps" then S.probed(row, nil, lease) else S.notify(lease, nil) end
    elseif lease and lease.retryAt and now >= lease.retryAt and now < lease.expires then
      lease.retryAt = now + 1000
      local key = SO.pair.key(lease.turtleId)
      if key then
        local wire = SO.proto.encode(SO.proto.build(key, "lease.batch", {
          lease = lease.id, ttl = math.max(0, lease.expires - now),
          expires = os.epoch("utc") + math.max(0, lease.expires - now), steps = lease.steps,
          journal = lease.journal,
        }))
        if wire then pcall(rednet.send, lease.turtleId, wire, "so") end
      end
    end
    count = count + 1
    if count % 64 == 0 then SO.breathe() end
  end
end

S.dugProtection = function(protect)
  for _, row in pairs(S.turtles) do
    if row.uncertain or row.anchor then return false end
    if row.open then
      if not row.open.pose then return false end
      protect(row.open.pose.dim or "minecraft:overworld", row.open.pose, 48)
    end
  end
  return true
end

local config = SO.store.read("so-server.cfg")
if type(config) == "table" then S.pos = S.copyPose(config.pos) end
if not S.pos and type(gps) == "table" and type(gps.locate) == "function" then
  local ok, x, y, z = pcall(gps.locate, 2)
  if ok and S.number(x) and S.number(y) and S.number(z) then S.pos = { x = x, y = y, z = z } end
end
if not S.pos then print("so-lease: no server position; range checks disabled") end

return {
  name = "lease",
  handlers = {
    ["step.report"] = S.report,
    beacon = S.beacon,
    hello = S.hello,
    ["history.page"] = function(msg, reply)
      local state = S.module("state")
      if type(state) == "table" and type(state.history) == "table" and type(state.history.page) == "function" then
        reply("history.page", state.history.page(msg.body))
      end
    end,
  },
  tick = S.tick,
  send = S.send,
  reanchor = S.reanchor,
  clearProbe = S.clearProbe, claimProbe = S.claimProbe,
  locate = S.locate, world = S.world, candidates = S.candidates,
  onReport = function(owner, fn)
    if type(owner) ~= "string" or type(fn) ~= "function" then return false end
    S.callbacks[owner] = fn
    return true
  end,
  status = S.status,
  peek = S.peek,
  describe = S.describe,
  ensureTool = S.ensureTool,
  cancelPark = S.cancelPark,
  forget = S.forget,
  inRange = S.inRange,
  remoteReady = S.remoteReady,
  dugProtection = S.dugProtection,
}
