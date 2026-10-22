-- so-mod-state.lua - event log, machine registry, and views.

local H = {}

H.copy = function(v)
  if type(v) ~= "table" then return v end
  local seen = {}
  local function walk(x)
    if type(x) ~= "table" then return x end
    if seen[x] then error("cycle", 0) end
    seen[x] = true
    local out = {}
    for key, item in pairs(x) do out[walk(key)] = walk(item) end
    seen[x] = nil
    return out
  end
  local ok, out = pcall(walk, v)
  if not ok then return nil, "cycle" end
  return out
end

H.shallow = function(values)
  local out = {}
  for key, value in pairs(values) do out[key] = value end
  return out
end

H.disk = function()
  local cap = fs.getCapacity("/")
  local free = fs.getFreeSpace("/")
  local info = { capacity = 0, used = 0, free = 0, ratio = 0, alerts = {}, accepting = true }
  if type(cap) ~= "number" or cap <= 0 then return info end
  if type(free) ~= "number" or free < 0 then free = 0 end
  local used = cap - free
  if used < 0 then used = 0 end
  info.capacity = cap
  info.used = used
  info.free = free
  info.ratio = used / cap
  if info.ratio >= 0.8 then
    info.alerts = { "disk" }
    info.accepting = false
  end
  return info
end

H.fp = function(id)
  if type(id) ~= "number" or type(SO) ~= "table" or type(SO.pair) ~= "table" or type(SO.proto) ~= "table" then
    return nil
  end
  if type(SO.pair.key) ~= "function" or type(SO.proto.sha256) ~= "function" or type(SO.proto.hex) ~= "function" then
    return nil
  end
  local key = SO.pair.key(id)
  if type(key) ~= "string" then return nil end
  return SO.proto.hex(SO.proto.sha256(key))
end

H.machine = function(row)
  if type(row) ~= "table" then return nil end
  local pose
  if type(row.pose) == "table" then
    pose = { dim = row.pose.dim, x = row.pose.x, y = row.pose.y, z = row.pose.z, facing = row.pose.facing }
  end
  return { id = row.id, role = row.role, fp = row.fp, seen = row.seen, fuel = row.fuel, pose = pose }
end

H.builtin = function(name)
  if name == "fleet" or name == "log" or name == "status" then return true end
  return type(name) == "string" and name:match("^turtle/%d+$") ~= nil
end

H.descend = function(root, rest)
  if rest == nil or rest == "" then return H.copy(root) end
  local cur = root
  for part in string.gmatch(rest, "[^/]+") do
    if type(cur) ~= "table" then return nil end
    local nxt = cur[part]
    if nxt == nil then
      local num = tonumber(part)
      if num ~= nil then nxt = cur[num] end
    end
    cur = nxt
  end
  if type(cur) == "table" then return H.copy(cur) end
  return cur
end

H.tail = function(evs)
  local out, start = {}, #evs - 49
  if start < 1 then start = 1 end
  local i = start
  while i <= #evs do
    local ev = evs[i]
    out[#out + 1] = { seq = ev.seq, at = ev.at, kind = ev.kind, data = ev.data }
    i = i + 1
  end
  return out
end

H.fleet = function(S)
  local ids = {}
  for id in pairs(S.machines) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na < nb end
    return tostring(a) < tostring(b)
  end)
  local out, i = {}, 1
  while i <= #ids do
    out[i] = H.machine(S.machines[ids[i]])
    i = i + 1
  end
  return out
end

H.ensure = function(S, id)
  local key = tostring(id)
  local row = S.machines[key]
  if not row then
    row = { id = id }
    S.machines[key] = row
  end
  return row
end

H.apply = function(S, ev)
  S.seq = ev.seq
  S.rev = ev.seq
  S.values[ev.kind] = ev.data
  if ev.kind == "machine" and type(ev.data) == "table" and type(ev.data.id) == "number" then
    local row = H.ensure(S, ev.data.id)
    if ev.data.role ~= nil then row.role = ev.data.role end
    if ev.data.fp ~= nil then row.fp = ev.data.fp end
    if ev.data.fuel ~= nil then row.fuel = ev.data.fuel end
    row.seen = ev.data.seen ~= nil and ev.data.seen or ev.at
    if type(ev.data.pose) == "table" then row.pose = H.machine({ pose = ev.data.pose }).pose end
  elseif ev.kind == "pose" and type(ev.data) == "table" and type(ev.data.id) == "number" then
    local row = H.ensure(S, ev.data.id)
    local pose = ev.data
    row.pose = { dim = pose.dim, x = pose.x, y = pose.y, z = pose.z, facing = pose.facing }
  elseif ev.kind == "job" then
    S.jobs[#S.jobs + 1] = ev.data
  end
end

H.render = function(S, evs, name)
  if type(name) ~= "string" then return nil end
  local custom = S.custom[name]
  if custom and not H.builtin(name) then
    local ok, data = pcall(custom, {
      rev = S.rev, values = H.shallow(S.values), machines = H.copy(S.machines), jobs = H.copy(S.jobs),
    })
    if ok then return data end
    return nil
  end
  if name == "fleet" then return H.fleet(S) end
  if name == "log" then return H.tail(evs) end
  if name == "status" then return H.disk() end
  local id = name:match("^turtle/(%d+)$")
  if id then return H.machine(S.machines[id]) end
  return nil
end

H.frame = function(S, evs, name)
  return { t = "view.frame", name = name, rev = S.rev, at = os.epoch("utc"), data = H.render(S, evs, name) }
end

local S = {
  seq = 0, rev = 0, values = {}, machines = {}, jobs = {}, custom = {}, subs = {}, mem = {},
}

local disklog
if type(SO) == "table" and type(SO.store) == "table" then
  if fs.exists("so-log.lua") then
    disklog = dofile("so-log.lua").open(SO.store)
  else
    print("so-mod-state: missing so-log.lua")
  end
end
if disklog then
  if disklog.snap then
    S.values = disklog.snap.values
    S.machines = disklog.snap.machines
    S.jobs = disklog.snap.jobs or {}
    S.seq = disklog.snap.seq
    S.rev = disklog.snap.seq
  end
end

H.events = function()
  if disklog then return disklog.events() end
  return S.mem
end

do
  local evs, i = H.events(), 1
  while i <= #evs do
    if evs[i].seq > S.seq then H.apply(S, evs[i]) end
    i = i + 1
  end
end

H.flush = function()
  local now, i = os.epoch("utc"), 1
  local evs = H.events()
  while i <= #S.subs do
    local sub = S.subs[i]
    if sub.dead then
      table.remove(S.subs, i)
    else
      if sub.dirty and now - sub.last >= 500 then
        local frame = H.frame(S, evs, sub.name)
        if frame.rev ~= sub.rev then
          sub.last = now
          sub.rev = frame.rev
          sub.dirty = false
          if type(sub.notify) == "function" then pcall(sub.notify, frame) end
        else
          sub.dirty = false
        end
      end
      i = i + 1
    end
  end
end

H.touch = function()
  local i = 1
  while i <= #S.subs do
    S.subs[i].dirty = true
    i = i + 1
  end
  H.flush()
end

local function canStart()
  if not H.disk().accepting then return false, "disk >=80%; free space" end
  return true
end

local function emit(kind, data)
  if type(kind) ~= "string" or kind == "" then return false, "kind" end
  if kind == "job" and not H.disk().accepting then return false, "disk" end
  local stored, copyErr = H.copy(data)
  if copyErr then return false, copyErr end
  if kind == "machine" and type(stored) == "table" and stored.fp == nil then
    stored.fp = H.fp(stored.id)
  end
  local ev = { at = os.epoch("utc"), kind = kind, data = stored }
  if disklog then
    local ok, err = disklog.append(ev)
    if not ok then return false, err end
  else
    S.seq = S.seq + 1
    ev.seq = S.seq
    S.mem[#S.mem + 1] = ev
  end
  -- Fold the event into memory before the snapshot, or the snapshot seq
  -- would skip this event on the next boot.
  H.apply(S, ev)
  if disklog and disklog.due() then
    local saved, saveErr = disklog.checkpoint({
      values = S.values, machines = S.machines, jobs = S.jobs,
    })
    if not saved then print("so-log: snapshot failed: " .. tostring(saveErr)) end
  end
  H.touch()
  return true
end

local function get(path)
  if type(path) ~= "string" then return nil end
  if path == "machines" then return H.descend(S.machines, "") end
  local rest = path:match("^machines/(.+)$")
  if rest then return H.descend(S.machines, rest) end
  rest = path:match("^machines%.(.+)$")
  if rest then return H.descend(S.machines, (rest:gsub("%.", "/"))) end
  return S.values[path]
end

local view = {}

view.get = function(q)
  local name = type(q) == "table" and q.name or nil
  return H.frame(S, H.events(), name)
end

view.sub = function(q)
  local name = type(q) == "table" and q.name or nil
  local notify = type(q) == "table" and q.notify or nil
  local sub = { name = name, notify = notify, last = 0, rev = -1, dirty = false, dead = false }
  sub.stop = function() sub.dead = true end
  S.subs[#S.subs + 1] = sub
  return sub
end

setmetatable(view, {
  __call = function(_, name, buildFn)
    if name == nil then return { rev = S.rev, values = H.shallow(S.values) } end
    if type(name) ~= "string" or type(buildFn) ~= "function" or H.builtin(name) then return false, "view" end
    S.custom[name] = buildFn
    return true
  end,
})

local history = {
  page = function(q)
    local query = type(q) == "table" and q or {}
    local count = query.count or query.limit or 20
    if type(count) ~= "number" then count = 20 end
    count = math.floor(count)
    if count < 1 then count = 1 end
    if count > 50 then count = 50 end
    local evs = H.events()
    local start = 1
    if type(query.from) == "number" then
      start = #evs + 1
      local i = 1
      while i <= #evs do
        if evs[i].seq > query.from then start = i break end
        i = i + 1
      end
    end
    local entries, i = {}, start
    while i <= #evs and #entries < count do
      local ev = evs[i]
      entries[#entries + 1] = { seq = ev.seq, at = ev.at, kind = ev.kind, data = ev.data }
      i = i + 1
    end
    local nxt
    if i <= #evs and #entries > 0 then nxt = entries[#entries].seq end
    return { entries = entries, next = nxt }
  end,
}

return {
  name = "state",
  handlers = {},
  tick = function() H.flush() end,
  emit = emit,
  get = get,
  view = view,
  canStart = canStart,
  job = function(data) return emit("job", data) end,
  history = history,
}
