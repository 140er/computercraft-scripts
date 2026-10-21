local S = { turtles = {}, callbacks = {}, seq = 0 }

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
    if not row.posed or distance > row.range then row.range = distance end
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

S.send = function(id, steps, opts)
  if not S.number(id) or id < 0 or id % 1 ~= 0 then return nil, "id" end
  local row = S.row(id)
  if row.lost then return nil, "lost" end
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
    id = tostring(id) .. "-" .. S.seq, turtleId = id, steps = SO.store.copy(steps),
    owner = opts.owner, pose = S.copyPose(opts.pose), expires = os.epoch("utc") + ms, status = "open",
  }
  local wire, err = SO.proto.encode(SO.proto.build(key, "lease.batch", {
    lease = lease.id, expires = lease.expires, steps = lease.steps,
  }))
  if not wire then return nil, err end
  row.open = lease
  local ok, sent = pcall(rednet.send, id, wire, "so")
  if not ok or sent == false then row.open = nil return nil, "send" end
  return lease.id
end

S.status = function(id)
  local row = S.row(id)
  return { open = row.open and row.open.id or nil, lost = row.lost, range = row.range, seen = row.seen }
end

S.inRange = function(id, pos)
  if not S.pos then return true end
  local distance = S.distance(pos)
  return distance ~= nil and distance <= S.row(id).range + 8
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
  row.seen = os.epoch("utc")
  lease.status = "reported"
  local cells = S.module("cells")
  if type(cells) == "table" and type(cells.releaseOwner) == "function" then cells.releaseOwner(lease.id) end
  if allOk and lease.pose then
    local pose = S.copyPose(lease.pose)
    pose.id = msg.from
    S.emit("pose", pose)
    S.observe(row, pose)
  end
  S.notify(lease, results)
end

S.beacon = function(msg)
  local row = S.row(msg.from)
  row.lost = true
  row.seen = os.epoch("utc")
  row.journal = msg.body.journal
  S.emit("machine", { id = msg.from, fuel = msg.body.fuel, seen = row.seen, journal = row.journal })
end

S.hello = function(msg)
  local row = S.row(msg.from)
  row.lost = false
  row.seen = os.epoch("utc")
  S.observe(row, msg.body.pose or msg.body.gps)
end

S.tick = function(now)
  now = now or os.epoch("utc")
  local count = 0
  for _, row in pairs(S.turtles) do
    local lease = row.open
    if lease and now > lease.expires + 10000 then
      row.open = nil
      lease.status = "expired"
      S.notify(lease, nil)
    end
    count = count + 1
    if count % 64 == 0 then sleep(0) end
  end
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
  onReport = function(owner, fn)
    if type(owner) ~= "string" or type(fn) ~= "function" then return false end
    S.callbacks[owner] = fn
    return true
  end,
  status = S.status,
  inRange = S.inRange,
}
