local S = { turtles = {}, callbacks = {}, seq = 0, owners = {mine=true,lumber=true,build=true,setup=true} }
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
  if S.persistenceError or row.record and not row.open then return nil, "lease recovery required" end
  if not SO.pair.key(id) then return nil, "turtle not paired" end
  if row.uncertain or row.anchor or row.boundaryHold then return nil, "pose uncertain; use explicit add" end
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
    if row.worker and SO.pair.key(id) and not assigned and not row.record and not S.persistenceError and not row.open and not row.probeOwner then out[#out + 1] = id end
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
  if S.safety then done(nil, "facing unknown; use explicit add") return end
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

S.probeBlocked = function(row)
  local record = row.record
  return S.persistenceError or record and (row.restored or record.status ~= "reported" or record.hold or not record.report
    or not record.report.pose or record.report.uncertain)
end

S.claimProbe = function(id, owner, pose)
  local cells = S.module("cells")
  local from = "gps:" .. id
  if not cells or not cells.list or #cells.list(from,1) == 0 then return true end
  if S.probeBlocked(S.row(id)) then return false, "lease recovery required" end
  if owner == "setup:" .. id then
    return cells.prepareHandoff(from, owner, pose.x, pose.y, pose.z, pose.dim)
  end
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
  if S.probeBlocked(row) then return false, "GPS probe recovery required" end
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
    probe.done(nil, results and "probe pose unknown; use explicit add" or "GPS probe lost; retry add")
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

S.assigned = function(id)
  for _, name in ipairs({"mine", "lumber", "build"}) do
    local mod = S.module(name)
    if mod and mod.assigned and mod.assigned(id) then return true, name end
  end
  local drops = S.module("drops")
  if drops and drops.busy and drops.busy(id) then return true, "drops" end
  return false
end

S.settingsValue = function(value)
  if type(value) ~= "table" or not S.number(value.seq) or value.seq < 0
    or value.seq % 1 ~= 0 or value.seq >= 2^53 or type(value.autoToolSwap) ~= "boolean" then return nil end
  if value.dim ~= nil and value.dim ~= "minecraft:overworld" and value.dim ~= "minecraft:the_nether"
    and value.dim ~= "minecraft:the_end" then return nil end
  if value.remoteN ~= nil and (not S.number(value.remoteN) or value.remoteN <= 0
    or value.remoteN % 1 ~= 0 or value.remoteN >= 2^53) then return nil end
  return {seq=value.seq, dim=value.dim, autoToolSwap=value.autoToolSwap, remoteN=value.remoteN}
end

S.settingsSeen = function(row, value)
  local confirmed = S.settingsValue(value)
  if not confirmed then return end
  if row.settings and confirmed.seq <= row.settings.seq then return end
  row.settings = confirmed
  if row.settingsControl then row.dim, row.autoToolSwap = confirmed.dim, confirmed.autoToolSwap end
  row.settingsN = math.max(row.settingsN or 0, confirmed.remoteN or 0)
  if row.settingsPending and confirmed.seq > row.settingsPending.seq then row.settingsPending = nil end
end

S.settings = function(id, changes)
  local config = SO.store.read("so-server.cfg")
  if type(config) ~= "table" or config.workerSettings ~= true then return nil, "settings disabled" end
  local row, key = S.turtles[id], SO.pair.key(id)
  if not row or not key or not row.workerSettings or not row.settings then return nil, "update required" end
  if row.settingsKey ~= key then return nil, "wait for hello" end
  if not row.settingsControl then return nil, "settings disabled" end
  if row.settingsPending then return nil, "settings pending" end
  if row.record or S.persistenceError or row.open or row.uncertain or row.anchor or row.lost or row.releaseLock or row.releaseHold or S.assigned(id) then return nil, "worker busy" end
  if type(changes) ~= "table" then return nil, "invalid settings" end
  for field in pairs(changes) do
    if field ~= "dim" and field ~= "autoToolSwap" then return nil, "invalid settings" end
  end
  local value = SO.store.copy(changes)
  value.seq = 0
  if value.autoToolSwap == nil then value.autoToolSwap = false end
  if not S.settingsValue(value) or changes.dim == nil and changes.autoToolSwap == nil then return nil, "invalid settings" end
  local body = SO.store.copy(changes)
  body.n = (row.settingsN or 0) + 1
  if body.n >= 2^53 then return nil, "settings counter exhausted" end
  row.settingsN = body.n
  local msg = SO.proto.build(key, "worker.settings", body)
  local wire = SO.proto.encode(msg)
  if not wire then return nil, "settings encode failed" end
  row.settingsPending = {rid=msg.rid, n=body.n, seq=row.settings.seq, key=key, untilAt=SO.now()+15000}
  local ok, sent = pcall(rednet.send, id, wire, "so")
  if not ok or sent == false then row.settingsPending=nil return nil, "send" end
  row.settingsError = nil
  return msg.rid
end

S.settingsReply = function(msg)
  local row = S.turtles[msg.from]
  local pending, body = row and row.settingsPending, msg.body
  if not pending or type(body) ~= "table" or body.command ~= "worker.settings"
    or pending.key ~= SO.pair.key(msg.from) or msg.rid ~= pending.rid or body.n ~= pending.n then return end
  row.settingsPending = nil
  if msg.t == "ack" then S.settingsSeen(row, body.settings)
  elseif body.code == "settings" then row.settingsError = body.text end
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
  if S.persistenceError then return nil, S.persistenceError end
  local row = S.row(id)
  if not row.uncertain or type(row.journal) ~= "string" then return nil, "pose not uncertain" end
  if not S.position(pose) or type(pose.facing) ~= "number" or pose.facing % 1 ~= 0
    or pose.facing < 0 or pose.facing > 3 then return nil, "pose" end
  row.anchor = { body = { journal = row.journal,
    pose = { x = pose.x, y = pose.y, z = pose.z, f = pose.facing } } }
  local ok, err = S.anchorSend(id, row)
  if not ok then row.anchor = nil return nil, err or "send" end
  row.worldFrame, row.reconciled = nil, false
  local lease = row.open
  if lease then
    lease = SO.store.copy(lease)
    lease.status = "expired"
    if not S.persist(lease) then return nil, "lease save failed" end
    row.open, row.record = nil, lease
    S.notify(lease, nil)
  end
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

S.boundaries = function() return S.safety == true end

S.assess = function(id, from, steps, opts)
  opts = opts or {}
  local cells, row = S.module("cells"), S.turtles[id]
  if not cells or not cells.assessment then return {ok=false,reason="cells unavailable"} end
  local valid = S.rules().assess(from,{})
  if not valid.ok then return valid end
  local targets, at = {}, from
  for _, step in ipairs(steps) do
    local target = S.rules().target(at,step.op)
    if target then targets[#targets+1] = target end
    at = S.rules().apply(at,step.op)
  end
  local checks = cells.assessment(opts.who or (opts.owner or "lease") .. ":" .. id, opts.exit, targets)
  if not opts.clear then checks.clear = nil end
  checks.limit = S.pos and (not from or from.dim == "minecraft:overworld") and ((row and row.range or 16) + 8) or nil
  checks.range = function(p) return S.inRange(id, p), S.distance(p), checks.limit end
  return S.rules().assess(from, steps, checks)
end

S.protectionReady = function()
  if S.persistenceError then return false end
  for _, row in pairs(S.turtles) do
    if row.record or row.open or row.uncertain or row.anchor or row.boundaryHold or row.releaseLock then return false end
  end
  return true
end

S.frameFor = function(row, frame)
  if frame then return SO.store.copy(frame) end
  if row.worldFrame then return SO.store.copy(row.worldFrame) end
  if row.fix and row.fix.pose and row.rotation and row.fix.dim and row.pose then
    return S.rules().frame({dim=row.fix.dim,x=row.fix.x,y=row.fix.y,z=row.fix.z,
      facing=(row.fix.pose.f+row.rotation.rot)%4}, row.fix.pose)
  end
end

S.exitPlan = function(id, from, steps)
  local cells, row, P = S.module("cells"), S.turtles[id], S.rules()
  local protection, err = cells.protected()
  if err then return nil, err end
  local route = {revision=protection.revision,start=P.membership(from,protection.boxes),departed={},steps={},cells={from},from=from}
  if not next(route.start) then return nil, "exit must start inside protection" end
  if type(steps) ~= "table" or #steps < 1 or #steps > 64 then return nil, "exit steps" end
  local at, moves = from, 0
  for _, step in ipairs(steps) do
    if type(step) ~= "table" or not (P.moves[step.op] or P.turns[step.op]) then return nil, "exit moves and turns only" end
    local check = S.assess(id, at, {step}, {who="gps:"..id,exit=route,clear=true})
    if not check.ok then return nil, check.reason end
    at = P.apply(at,step.op)
    if P.moves[step.op] then
      moves = moves + 1
      route.cells[#route.cells+1] = at
      local membership = P.membership(at,protection.boxes)
      for box in pairs(route.start) do if not membership[box] then route.departed[box] = true end end
    end
    route.steps[#route.steps+1] = {op=step.op}
  end
  if moves > 16 or next(P.membership(at,protection.boxes)) then return nil, "exit must end outside within 16 moves" end
  if row.fuel ~= "unlimited" and (not S.number(row.fuel) or row.fuel < 0 or row.fuel < moves) then
    return nil, "exit fuel unknown or insufficient"
  end
  route.departed, route.at, route.next = {}, from, 1
  return route
end

S.exitNext = function(id, row)
  local route, P = row.exitRoute, S.rules()
  local remaining = {}
  for i=route.next,#route.steps do remaining[#remaining+1] = route.steps[i] end
  local prefix = P.boundary({from=route.at,steps=remaining})
  local lid, err = S.send(id,prefix.steps,{owner="protectedExit",who="gps:"..id,pose=prefix.pose,exit=route,clear=true})
  if not lid then row.exitRoute = nil return nil, err end
  route.sent = #prefix.steps
  return lid
end

S.exitRequest = function(id, steps, actor, token)
  local row, cells = S.turtles[id], S.module("cells")
  if not S.safety or not cells or not (SO.store.read("so-server.cfg") or {}).protectedAreas then return nil, "protection disabled" end
  if not row or row.open or row.uncertain or row.boundaryHold or row.lost or S.assigned(id) then return nil, "exit needs idle certain worker" end
  if not row.parkBatch or not row.setupFence or not row.pose or not row.journal then return nil, "exit needs fenced worker" end
  if type(actor) ~= "number" and type(actor) ~= "string" then return nil, "exit actor" end
  local frame = S.frameFor(row)
  if not frame then return nil, "pose unknown" end
  local from = S.rules().toWorld(frame,row.pose)
  local route, err = S.exitPlan(id,from,steps)
  if not route then row.exitOffer = nil return nil, err end
  if not token then
    S.exitSerial = (S.exitSerial or 0) + 1
    row.exitOffer = {actor=actor,token=id.."-exit-"..SO.now().."-"..S.exitSerial,
      untilAt=SO.now()+30000,journal=row.journal,route=route}
    return SO.store.copy(row.exitOffer)
  end
  local offer = row.exitOffer
  row.exitOffer = nil
  if not offer or offer.actor ~= actor or offer.token ~= token or SO.now() > offer.untilAt
    or offer.journal ~= row.journal or offer.route.revision ~= route.revision or not S.rules().samePose(offer.route.from,from)
    or #offer.route.steps ~= #route.steps then return nil, "exit approval changed" end
  for i, step in ipairs(route.steps) do if step.op ~= offer.route.steps[i].op then return nil, "exit approval changed" end end
  local ok, why = cells.reserveMany("gps:"..id,route.cells)
  if not ok then return nil, why end
  row.exitRoute, row.worldFrame, row.probeOwner = route, frame, "gps:"..id
  return S.exitNext(id,row)
end

S.exitReported = function(lease, row, results)
  local route, P = row.exitRoute, S.rules()
  if not route then return end
  if not results then row.exitRoute, row.exitOffer = nil, nil return end
  route.at = P.toWorld(lease.frame,row.pose)
  route.next = route.next + route.sent
  local protection = S.module("cells").protected()
  local membership = P.membership(route.at,protection.boxes)
  for box in pairs(route.start) do if not membership[box] then route.departed[box] = true end end
  if route.next <= #route.steps then
    if not S.ackOutcome(lease.id) then row.exitRoute=nil return end
    S.exitNext(lease.turtleId,row)
  else
    row.exitRoute = nil
    local cells = S.module("cells")
    for _, p in ipairs(route.cells) do
      if p.x ~= route.at.x or p.y ~= route.at.y or p.z ~= route.at.z then
        cells.release("gps:"..lease.turtleId,p.x,p.y,p.z,p.dim)
      end
    end
  end
end

S.releaseReady = function(id, bootAt)
  local row = S.turtles[id]
  if not row or not row.worker or not SO.pair.key(id) then return nil, "unknown worker" end
  if row.record or S.persistenceError or row.open or row.uncertain or row.anchor or row.boundaryHold or row.releaseLock or row.releaseHold
    or row.probe or row.exitRoute or row.settingsPending or row.last and row.last.status == "expired"
    or S.assigned(id) then return nil, "worker has work or unresolved lease" end
  if not row.parkBatch or not row.setupFence or not row.pose or type(row.journal) ~= "string"
    or row.journal == "" then return nil, "release needs fenced worker" end
  local delay = (SO.store.read("so-server.cfg") or {}).releaseSilence
  delay = S.number(delay) and math.max(300000,delay) or 300000
  if SO.now()-math.max(row.seen or 0,row.contactAt or 0,bootAt or SO.now()) < delay then return nil, "wait for five minutes of silence" end
  return row.contact or 0
end

S.releaseFailed = function(row, lock)
  row.releaseLock = nil
  row.releaseHold = {worldPose=lock.worldPose}
  row.boundaryHold, row.reconciled = nil, false
  pcall(lock.done,nil)
end

S.releaseFence = function(id, contact, done)
  local row = S.turtles[id]
  local ready, err = S.releaseReady(id, 0)
  if ready == nil or ready ~= contact then return nil, err or "worker contacted server" end
  local frame = S.frameFor(row)
  local pose = frame and S.rules().toWorld(frame,row.pose) or S.copyPose(row.fix)
  local lock = {contact=contact,journal=row.journal,pose=SO.store.copy(row.pose),dim=row.dim,done=done,worldPose=pose}
  row.releaseLock = lock
  local ok, lid, reason = pcall(S.send,id,{{op="gps",park=true}},
    {owner="cellsRelease",journal=row.journal,release=lock,recover=true,ms=15000,pose=pose})
  if not ok or not lid then
    S.releaseFailed(row,lock)
    return nil, ok and reason or lid
  end
  return lid
end

S.releaseFix = function(row, lease, results, journal, pose, dim, contact, priorContact)
  local facts, fix = lease.report, results and results[1] and results[1].data
  local p = facts and facts.pose
  if not (results and results[1].ok and not facts.uncertain and p and pose
    and facts.journal and facts.journal ~= "" and facts.journal ~= journal and row.journal == facts.journal
    and p.x == pose.x and p.y == pose.y and p.z == pose.z and p.f == pose.f
    and priorContact == contact and S.position(fix) and fix.dim == dim
    and type(fix.dim) == "string" and S.rules().dimension(fix.dim) == fix.dim
    and fix.x%1 == 0 and fix.y%1 == 0 and fix.z%1 == 0) then return nil end
  return {dim=fix.dim,x=fix.x,y=fix.y,z=fix.z}
end

S.releaseReported = function(row, lease, results, priorContact)
  local lock = row.releaseLock
  if not lock then return end
  local fix = S.releaseFix(row,lease,results,lock.journal,lock.pose,lock.dim,lock.contact,priorContact)
  if fix and not S.assigned(lease.turtleId) then
    lock.worldPose = fix
    local ok, saved = pcall(lock.done,fix)
    if ok and saved then
      row.releaseLock = nil
      S.fix(row,fix,lease.report.pose,lease.report.journal)
      return
    end
  end
  S.releaseFailed(row,lock)
end

S.releaseRecovered = function(row, lease, results, priorContact)
  local fix = S.releaseFix(row,lease,results,lease.journal,lease.expected,lease.releaseDim,lease.releaseContact,priorContact)
  local cells = S.module("cells")
  row.boundaryHold, row.reconciled = nil, false
  if not fix or not cells then return false end
  row.releaseHold.worldPose = fix
  local ok, saved = pcall(cells.reserve,"gps:"..lease.turtleId,fix.x,fix.y,fix.z,fix.dim)
  if not ok or not saved then return false end
  S.fix(row,fix,lease.report.pose,lease.report.journal)
  row.releaseHold, row.worldFrame, row.reconciled = nil, nil, true
  lease.pose = fix
  return true
end

S.validLeases = function(value)
  if type(value) ~= "table" or value.v ~= 1 or type(value.records) ~= "table"
    or not S.number(value.seq) or value.seq < 0 or value.seq % 1 ~= 0 or value.seq >= 2^53 then return false end
  local count, workers = 0, {}
  for id, record in pairs(value.records) do
    if type(record) ~= "table" or type(id) ~= "string" or #id > 128 or record.id ~= id
      or not S.number(record.turtleId) or record.turtleId < 0 or record.turtleId % 1 ~= 0
      or workers[record.turtleId] or type(record.steps) ~= "table" or #record.steps < 1 or #record.steps > 16
      or not S.number(record.expires) or record.owner ~= nil and type(record.owner) ~= "string"
      or record.journal ~= nil and type(record.journal) ~= "string"
      or record.pose ~= nil and not S.position(record.pose)
      or not ({open=true,reported=true,expired=true,recovering=true,cancelled=true})[record.status] then return false end
    local n = 0
    for i, step in pairs(record.steps) do
      if type(i) ~= "number" or i%1 ~= 0 or i < 1 or i > #record.steps
        or type(step) ~= "table" or type(step.op) ~= "string" then return false end
      n = n+1
    end
    if n ~= #record.steps or record.status == "reported" and type(record.report) ~= "table" then return false end
    for _,field in ipairs({"boundary","reconcile","hold","releaseRecovery","sendUncertain","recovery"}) do
      if record[field] ~= nil and type(record[field]) ~= "boolean" then return false end
    end
    if record.retryAt ~= nil and not S.number(record.retryAt) then return false end
    if record.releaseHold ~= nil and (type(record.releaseHold) ~= "table"
      or record.releaseHold.worldPose ~= nil and not S.position(record.releaseHold.worldPose)) then return false end
    if record.frame and (type(record.frame) ~= "table" or not S.number(record.frame.ox)
      or not S.number(record.frame.oy) or not S.number(record.frame.oz) or not S.number(record.frame.rot)
      or record.frame.rot%1 ~= 0 or record.frame.rot < 0 or record.frame.rot > 3) then return false end
    if record.expected and not S.journalPose(record.expected) or record.from and not S.position(record.from)
      or record.intent ~= nil and type(record.intent) ~= "table" then return false end
    if record.report then
      local report = record.report
      if type(report) ~= "table" or report.pose ~= nil and not S.journalPose(report.pose)
        or report.journal ~= nil and type(report.journal) ~= "string"
        or report.uncertain ~= nil and type(report.uncertain) ~= "boolean" then return false end
    end
    if record.results then
      if type(record.results) ~= "table" or #record.results ~= #record.steps then return false end
      local results = 0
      for i, result in pairs(record.results) do
        if type(i) ~= "number" or i%1 ~= 0 or i < 1 or i > #record.steps
          or type(result) ~= "table" or type(result.ok) ~= "boolean" then return false end
        results = results+1
      end
      if results ~= #record.steps then return false end
    end
    workers[record.turtleId], count = true, count+1
    if count > 256 then return false end
  end
  return true
end

S.persist = function(record, remove)
  if S.persistenceError then return false, S.persistenceError end
  local value = SO.store.copy(S.saved)
  value.seq = S.seq
  value.records[record.id] = not remove and SO.store.copy(record) or nil
  local ok, err = S.box.save(value)
  if not ok then return false, err or "lease save failed" end
  S.saved = value
  return true
end

S.outcome = function(id)
  local row = S.turtles[id]
  local record = row and row.record
  if record and record.status ~= "open" and record.status ~= "recovering" then return SO.store.copy(record) end
end

S.ackOutcome = function(id)
  if S.persistenceError then return false, S.persistenceError end
  local record = S.saved.records[id]
  if not record then return true end
  if record.status == "open" or record.status == "recovering" then return false, "lease not terminal" end
  local row = S.row(record.turtleId)
  local hold = record.status == "expired" or record.hold or row.restored
  if not hold and row.bootRecovery and record.frame and record.report and record.report.pose
    and (record.owner == "mine" or record.owner == "lumber" or record.owner == "build") then
    local cells = S.module("cells")
    local pose = S.rules().toWorld(record.frame,record.report.pose)
    local ok, err = cells.reserve(record.owner .. ":" .. record.turtleId,pose.x,pose.y,pose.z,pose.dim)
    if not ok then return false, err or "restart standing cell unavailable" end
  end
  local nextRecord = SO.store.copy(record)
  if hold then nextRecord.status = "recovering" end
  local ok, err = S.persist(nextRecord, not hold)
  if not ok then return false, err end
  row.record = hold and nextRecord or nil
  if not hold then row.bootRecovery = nil end
  if hold and not row.releaseHold then row.boundaryHold = true end
  return true
end

S.restore = function()
  if type(fs) == "table" and type(fs.exists) == "function" then
    for _, path in ipairs({"so-data/cells/leases","so-data/cells/leases.tmp","so-data/cells/leases.bak"}) do
      if fs.exists(path) then
        local ok, generation = pcall(SO.store.read,path)
        if not ok or type(generation) ~= "table" or generation.schema ~= 1
          or not S.number(generation.generation) or generation.generation <= 0 or generation.generation%1 ~= 0
          or not S.validLeases(generation.value) then
          if path == "so-data/cells/leases.tmp" then fs.delete(path)
          else S.persistenceError = "lease state unreadable" return end
        end
      end
    end
  end
  local ok, box = pcall(SO.store.store, "so-data/cells/leases", S.validLeases, 900000)
  if not ok then S.persistenceError = "lease state unreadable" return end
  S.box, S.saved = box, box.value or {v=1,seq=0,records={}}
  S.seq = S.saved.seq
  for _, record in pairs(S.saved.records) do
    local row = S.row(record.turtleId)
    -- Peer movement waits until every restored worker has saved its current pose.
    row.record, row.lost, row.restored, row.bootRecovery = SO.store.copy(record), true, true, true
    row.worldFrame, row.releaseHold = record.frame, SO.store.copy(record.releaseHold)
    if record.status == "open" then row.open = row.record end
    if (record.status == "recovering" or record.hold) and not row.releaseHold then row.boundaryHold = true end
    if record.report then
      row.uncertain = record.report.uncertain
      S.journalSeen(row,record.report.pose,record.report.journal)
    end
  end
end

S.send = function(id, steps, opts)
  if not S.number(id) or id < 0 or id % 1 ~= 0 then return nil, "id" end
  if S.persistenceError then return nil, S.persistenceError end
  local row = S.row(id)
  if row.releaseLock and not (type(opts)=="table" and opts.release == row.releaseLock) then return nil, "release pending reconciliation" end
  if row.releaseHold and not (type(opts)=="table" and opts.recover == true and type(steps)=="table"
    and #steps == 1 and type(steps[1])=="table" and steps[1].op == "gps") then return nil, "release recovery GPS required" end
  if row.uncertain or row.anchor then return nil, "pose uncertain" end
  if row.lost and not (type(opts) == "table" and opts.recover == true) then return nil, "lost" end
  if row.open then return nil, "busy" end
  local recovery = row.record and row.record.status == "recovering"
  if row.record and not row.open and not recovery then return nil, "lease outcome pending" end
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
  if opts.exit and (opts.exit ~= row.exitRoute or opts.owner ~= "protectedExit") then return nil, "exit approval required" end
  local ms = opts.ms or 60000
  if not S.number(ms) or ms <= 0 then return nil, "ms" end
  if opts.owner ~= nil and type(opts.owner) ~= "string" then return nil, "owner" end
  if opts.pose ~= nil and not S.position(opts.pose) then return nil, "pose" end
  if row.releaseHold and (not row.setupFence or not row.parkBatch or not row.pose or not row.journal
    or row.journal == "" or opts.journal and opts.journal ~= row.journal) then return nil, "recovery needs fenced worker" end
  local fencedRecovery = recovery and row.setupFence and row.parkBatch
  if recovery then
    local observation = opts.recover == true
    for _, step in ipairs(steps) do
      if step.op ~= "inspect" and step.op ~= "inspectUp" and step.op ~= "inspectDown" and step.op ~= "gps" then observation = false end
    end
    if not observation or not row.pose or not row.journal
      or not fencedRecovery and (S.safety or #steps ~= 1 or steps[1].op ~= "inspectDown") then
      return nil, "restart needs fenced observation"
    end
  end
  local observation = true
  for _, step in ipairs(steps) do
    if step.op ~= "inspect" and step.op ~= "inspectUp" and step.op ~= "inspectDown" and step.op ~= "gps" then observation = false end
  end
  if not observation then
    for _, peer in pairs(S.turtles) do
      if peer.bootRecovery then return nil, "restart reconciliation pending" end
    end
  end
  local frame, from, expected, reconcile
  if S.safety or fencedRecovery then
    if not row.parkBatch or not row.setupFence or not row.journal or not row.pose then
      return nil, "boundary needs certain fenced worker"
    end
    local prefix = S.rules().boundary({steps=steps})
    if #prefix.steps ~= #steps then return nil, "acknowledged boundary required" end
    local motion, observation = false, true
    for _, step in ipairs(steps) do
      if S.rules().moves[step.op] or S.rules().turns[step.op] or S.rules().writes[step.op] then motion = true end
      if step.op ~= "inspect" and step.op ~= "inspectUp" and step.op ~= "inspectDown" and step.op ~= "gps" then observation = false end
    end
    reconcile = opts.recover == true and observation
    if row.boundaryHold and not reconcile then return nil, "boundary reconciliation required" end
    frame = S.frameFor(row, opts.frame)
    if frame then from = S.rules().toWorld(frame, row.pose) end
    if motion then
      local assessment = S.assess(id, from, steps, opts)
      if not assessment.ok then return nil, assessment.reason end
    end
    expected = SO.store.copy(row.pose)
    for _, step in ipairs(steps) do expected = S.rules().apply(expected, step.op) end
    if from and opts.pose and not reconcile then
      local at = from
      for _, step in ipairs(steps) do at = S.rules().apply(at, step.op) end
      if not S.rules().samePose(at, opts.pose) then return nil, "expected pose mismatch" end
    end
    if opts.journal and opts.journal ~= row.journal then return nil, "journal changed" end
  end
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
    owner = opts.owner, intent = SO.store.copy(opts.intent),
    journal = opts.journal or row.setupFence and row.journal or nil,
    frame = SO.store.copy(opts.frame), recovery = recovery or nil,
    pose = S.copyPose(opts.pose), expires = SO.now() + ms, status = "open",
  }
  if S.safety or fencedRecovery then
    lease.journal, lease.frame, lease.from, lease.expected, lease.reconcile = row.journal, frame, from, expected, reconcile
    if frame then lease.pose = S.rules().toWorld(frame,expected) end
    lease.steps[1].park, lease.boundary = true, true
    row.worldFrame = frame
  end
  if row.releaseLock or row.releaseHold then
    lease.hold, lease.releaseHold = true, {worldPose=S.copyPose(opts.pose) or S.copyPose(row.releaseHold and row.releaseHold.worldPose)}
  end
  if row.releaseHold then
    lease.releaseRecovery, lease.releaseContact, lease.releaseDim = true, row.contact or 0, row.dim
    lease.journal, lease.expected, lease.pose = row.journal, SO.store.copy(row.pose), S.copyPose(row.releaseHold.worldPose)
    lease.steps[1].park = true
  end
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
  if recovery then S.saved.records[row.record.id] = nil end
  local saved, why = S.persist(lease)
  if not saved then
    if recovery then S.saved.records[row.record.id] = SO.store.copy(row.record) end
    return nil, why
  end
  row.open, row.record, row.restored, row.restartProof = lease, lease, nil, nil
  if lease.frame then row.worldFrame = SO.store.copy(lease.frame) end
  local ok, sent = pcall(rednet.send, id, wire, "so")
  if not ok or sent == false then lease.sendUncertain = true end
  return lease.id
end

S.snapshot = function(row)
  if not row then return nil end
  return { persistenceError = S.persistenceError, recovering = row.record ~= nil, outcome = row.record and row.record.status ~= "open" and row.record.status ~= "recovering" and row.record.id or nil, open = row.open and row.open.id or nil, lost = row.lost or row.record and (row.record.status == "expired" or row.record.status == "recovering") or false, range = row.range, seen = row.seen,
    last = SO.store.copy(row.last), tools = SO.store.copy(row.tools), toolError = row.toolError, autoToolSwap = row.autoToolSwap == true,
    settings = SO.store.copy(row.settings), workerSettings = row.workerSettings, settingsControl = row.settingsControl,
    settingsPending = row.settingsPending and {rid=row.settingsPending.rid,n=row.settingsPending.n} or nil,
    releasing = row.releaseLock ~= nil, releaseHold = row.releaseHold ~= nil, contact = row.contact or 0,
    settingsError = row.settingsError, reconciled = row.reconciled, boundaryHold = row.boundaryHold,
    fuel = row.fuel, parkBatch = row.parkBatch, setupFence = row.setupFence, probing = row.probe ~= nil, fix = SO.store.copy(row.fix), rotation = SO.store.copy(row.rotation),
    pose = S.journalPose(row.pose), journal = row.journal, poseAt = row.poseAt,
    uncertain = row.uncertain or row.anchor and true or nil }
end

S.status = function(id) return S.snapshot(S.row(id)) end
S.peek = function(id) return S.snapshot(S.turtles[id]) end

S.cancelPark = function(id, owner)
  local row = S.turtles[id]
  local lease = row and row.open
  if not lease then return true end
  if owner ~= "mine" or lease.owner ~= owner or #lease.steps ~= 1
    or lease.steps[1].op ~= "inspectDown" then return false, "turtle has open lease" end
  lease = SO.store.copy(lease)
  lease.status = "cancelled"
  if not S.persist(lease) then return false, "lease save failed" end
  row.open, row.record = nil, lease
  return S.ackOutcome(lease.id)
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
  local record = row.record or row.open
  if record then
    local ok, err = S.persist(record, true)
    if not ok then return false, err end
    row.open, row.record, row.restored, row.bootRecovery = nil, nil, nil, nil
  end
  row.probe, row.anchor = nil, nil
  row.uncertain, row.lost = true, true
  row.worldFrame, row.reconciled = nil, false
  row.pose, row.poseAt = nil, nil
  row.settings, row.settingsPending, row.settingsKey, row.settingsN = nil, nil, nil, nil
end

S.inRange = function(id, pos)
  if pos and (pos.dim == "minecraft:the_nether" or pos.dim == "minecraft:the_end") then
    return S.remoteReady(id, pos.dim)
  end
  if not S.pos then return true end
  local distance = S.distance(pos)
  return distance ~= nil and distance <= (S.turtles[id] and S.turtles[id].range or 16) + 8
end

S.report = function(msg, reply)
  local row = S.row(msg.from)
  local body = msg.body
  local priorContact = row.contact or 0
  row.contact, row.contactAt = priorContact+1, SO.now()
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
  lease = SO.store.copy(lease)
  lease.report = S.facts(body)
  local accepted, boundaryOK = results, true
  if lease.boundary then
    local facts = lease.report
    local certain = not facts.uncertain and facts.pose and facts.journal and facts.journal ~= lease.journal
    local actual = certain and {dim="journal",x=facts.pose.x,y=facts.pose.y,z=facts.pose.z,facing=facts.pose.f}
    local before = lease.expected and {dim="journal",x=lease.expected.x,y=lease.expected.y,z=lease.expected.z,facing=lease.expected.f}
    local success = certain and (lease.reconcile or S.rules().samePose(before,actual))
    for i, step in ipairs(lease.steps) do
      if (S.rules().moves[step.op] or S.rules().turns[step.op]) and not results[i].ok or results[i].err == "journal changed" then success = false end
    end
    boundaryOK = success
    if not success then accepted, lease.hold = nil, true
    elseif lease.reconcile and lease.frame then lease.pose=S.rules().toWorld(lease.frame,facts.pose) end
  end
  if lease.journal then
    for _, result in ipairs(results) do
      if result.err == "journal changed" then accepted, lease.hold = nil, true end
    end
  end
  if lease.recovery and not lease.boundary and (not lease.report.pose or lease.report.uncertain) then
    accepted, lease.hold = nil, true
  end
  lease.status, lease.results = "reported", SO.store.copy(accepted)
  if not S.persist(lease) then return end
  row.open, row.record, row.restartProof = nil, lease, nil
  S.tools(row, body.tools)
  if type(body.capabilities) == "table" then
    row.parkBatch, row.setupFence = body.capabilities.parkBatch == true, body.capabilities.setupFence == true
  end
  row.seen = SO.now()
  row.lost = row.restored == true
  lease.report = S.facts(body)
  row.fuel = lease.report.fuel
  row.uncertain = lease.report.uncertain
  if row.uncertain then row.pose, row.poseAt = nil, nil end
  S.journalSeen(row, lease.report.pose, lease.report.journal)
  if not accepted then results, allOk = nil, false end
  if lease.boundary then
    if not boundaryOK then row.boundaryHold, row.reconciled, results, allOk = true, false, nil, false
    else row.boundaryHold, row.reconciled = nil, true end
  end
  if lease.recovery and not lease.boundary then
    if lease.hold then results, allOk = nil, false
    else row.boundaryHold, row.reconciled = nil, true end
  end
  if lease.releaseRecovery and not S.releaseRecovered(row,lease,results,priorContact) then
    results, allOk = nil, false
  end
  lease.status = "reported"
  row.last = {status="reported", ok=allOk, at=row.seen}
  if allOk and lease.pose and not row.uncertain then
    local pose = S.copyPose(lease.pose)
    pose.id = msg.from
    if row.pose and pose.facing ~= nil then row.rotation = { rot = (pose.facing-row.pose.f)%4 } end
    S.emit("pose", pose)
    S.observe(row, pose)
  end
  if lease.owner == "tools" then
    row.toolError = not allOk and ("tool swap failed: "..tostring(body.results[1].err or "failed")) or nil
  elseif lease.owner == "cellsRelease" then S.releaseReported(row,lease,results,priorContact)
  elseif lease.owner == "protectedExit" then S.exitReported(lease,row,results)
  elseif lease.owner == "gps" then S.probed(row, results, lease) else S.notify(lease, results) end
  if lease.releaseHold and not row.releaseLock and not row.releaseHold then
    lease.hold, lease.releaseHold = nil, nil
    if not S.persist(lease) then return end
  end
  if not S.owners[lease.owner] then
    if row.restored then lease.hold = true S.persist(lease) end
    S.ackOutcome(lease.id)
  end
  if reply then reply("ack", {command="step.report", lease=lease.id}) end
end

S.beacon = function(msg)
  local row = S.row(msg.from)
  row.contact, row.contactAt = (row.contact or 0)+1, SO.now()
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
  if job == "" and (row.open or S.assigned(id)) then return end
  local text = job.."/"..reason
  if row.description == text and SO.now()-(row.describedAt or 0)<30000 then return end
  local key = SO.pair.key(id)
  if not key then return end
  local wire = SO.proto.encode(SO.proto.build(key,"worker.status",{job=job,reason=reason,
    idleRid=job == "" and row.helloRid or nil}))
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
  row.contact, row.contactAt = (row.contact or 0)+1, SO.now()
  local key = SO.pair.key(msg.from)
  if row.settingsKey ~= key then
    row.settings, row.settingsPending, row.settingsN = nil, nil, nil
    row.settingsKey = key
  end
  row.workerSettings = type(msg.body.capabilities) == "table" and msg.body.capabilities.workerSettings == true
  row.settingsControl = msg.body.settingsControl == true
  if row.workerSettings then S.settingsSeen(row, msg.body.settings) end
  if row.helloRid ~= msg.rid then row.description = nil end
  row.helloRid = msg.rid
  row.lost = false
  row.seen = SO.now()
  row.fuel = (S.number(msg.body.fuel) or msg.body.fuel == "unlimited") and msg.body.fuel or nil
  S.tools(row, msg.body.tools)
  row.autoToolSwap = type(msg.body.capabilities) == "table" and msg.body.capabilities.autoToolSwap == true
  row.dimensionSafety = type(msg.body.capabilities) == "table" and msg.body.capabilities.dimensionSafety == true
  row.dim = msg.body.dim
  if row.settingsControl and row.settings then row.dim, row.autoToolSwap = row.settings.dim, row.settings.autoToolSwap end
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
      -- A changed journal makes every delayed copy of this fenced batch inert.
      if row.restored and row.open and row.open.journal and row.setupFence and row.parkBatch
        and type(journal.id) == "string" and journal.id ~= row.open.journal
        and not journal.pending and S.journalPose(journal.pose) then
        row.restartProof = true
      end
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
    if row.settingsPending and now >= row.settingsPending.untilAt then
      row.settingsPending, row.settingsError = nil, "settings timed out"
    end
    if row.anchor and now >= row.anchor.after then S.anchorSend(id, row) end
    local record = row.record
    if row.restored and record and not S.owners[record.owner] and record.status ~= "open" and record.status ~= "recovering" then
      S.ackOutcome(record.id)
      record = row.record
    end
    if record and record.status == "recovering" and not S.owners[record.owner]
      and row.worker and row.setupFence and row.parkBatch and not row.uncertain and not S.assigned(id) then
      S.send(id,{{op="gps",park=true}},{owner="leaseRecovery",recover=true,ms=15000,pose=record.pose,frame=record.frame})
    end
    local lease = row.open
    if lease and (now > lease.expires + 10000 or row.restartProof) then
      lease = SO.store.copy(lease)
      lease.status = "expired"
      if S.persist(lease) then
        row.open, row.record, row.restartProof = nil, lease, nil
        if lease.boundary then row.boundaryHold, row.reconciled = true, false end
        if lease.releaseRecovery then row.boundaryHold, row.reconciled = nil, false end
        row.last = {status="expired", ok=false, at=now}
        if lease.owner == "cellsRelease" then S.releaseReported(row,lease,nil)
        elseif lease.owner == "protectedExit" then S.exitReported(lease,row,nil)
        elseif lease.owner == "gps" then S.probed(row, nil, lease) else S.notify(lease, nil) end
        if not S.owners[lease.owner] then S.ackOutcome(lease.id) end
      end
    elseif lease and #lease.steps == 1 and lease.steps[1].op == "inspectDown"
      and lease.retryAt and now >= lease.retryAt and now < lease.expires then
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
    if row.worker and row.workerSettings and row.settingsControl and row.helloRid then
      local assigned, module = S.assigned(id)
      if assigned or row.open then
        pcall(S.describe, id, module or row.open.owner or "lease", "assigned")
      else pcall(S.describe, id, "", "") end
    end
    count = count + 1
    if count % 64 == 0 then SO.breathe() end
  end
end

S.historyPage = function(query, history)
  query = type(query) == "table" and query or {}
  local limit = S.number(query.limit) and math.floor(query.limit) or 20
  limit = math.max(1, math.min(50, limit))
  local before, beforeSeq = math.huge, nil
  if S.number(query.before) then before = query.before
  elseif type(query.before) == "table" and S.number(query.before.at) then
    before = query.before.at
    beforeSeq = S.number(query.before.seq) and query.before.seq or nil
  end
  local entries, cursor = {}, nil
  repeat
    local page = history.page({ reverse = true, before = cursor, count = 50 })
    for _, entry in ipairs(page.entries) do
      if entry.at < before or entry.at == before and beforeSeq and entry.seq < beforeSeq then
        entries[#entries + 1] = entry
      end
    end
    table.sort(entries, function(a, b)
      if a.at == b.at then return a.seq > b.seq end
      return a.at > b.at
    end)
    while #entries > limit + 1 do entries[#entries] = nil end
    cursor = page.next
  until not cursor
  local more = #entries > limit
  if more then entries[#entries] = nil end
  local out = {}
  for _, entry in ipairs(entries) do
    local data = entry.data
    local detail = type(data) == "table" and (data.text or data.reason)
      or type(data) == "string" and data or data == false and "cleared"
    out[#out + 1] = { at = entry.at, text = entry.kind .. (detail and " " .. tostring(detail) or "") }
  end
  local last = entries[#entries]
  return { entries = out, next = more and { at = last.at, seq = last.seq } or nil }
end

S.dugProtection = function(protect)
  for _, row in pairs(S.turtles) do
    local held = row.releaseHold or row.releaseLock
    if held then
      local pose = held.worldPose
      if pose then protect(pose.dim or "minecraft:overworld",pose,48) end
    else
      if row.uncertain or row.anchor or row.boundaryHold then return false end
      if row.open then
        if not row.open.pose then return false end
        protect(row.open.pose.dim or "minecraft:overworld", row.open.pose, 48)
      end
    end
  end
  return true
end

S.restore()
local config = SO.store.read("so-server.cfg")
S.safety = type(config) == "table" and (config.protectedAreas == true or config.alternateAxisOrders == true or config.storageDeliveries == true)
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
    ack = S.settingsReply,
    err = S.settingsReply,
    ["history.page"] = function(msg, reply)
      local state = S.module("state")
      if type(state) == "table" and type(state.history) == "table" and type(state.history.page) == "function" then
        reply("history.page", S.historyPage(msg.body, state.history))
      end
    end,
  },
  tick = S.tick,
  send = S.send, outcome = S.outcome, ackOutcome = S.ackOutcome,
  recoveryIds = function(owner)
    local ids = {}
    for id, row in pairs(S.turtles) do if row.record and row.record.owner == owner then ids[#ids+1] = id end end
    table.sort(ids)
    return ids
  end,
  boundaries = S.boundaries, assess = S.assess, protectionReady = S.protectionReady,
  releaseReady = S.releaseReady, releaseFence = S.releaseFence,
  exitRequest = S.exitRequest,
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
  settings = S.settings,
  ensureTool = S.ensureTool,
  cancelPark = S.cancelPark,
  forget = S.forget,
  inRange = S.inRange,
  remoteReady = S.remoteReady,
  dugProtection = S.dugProtection,
}
