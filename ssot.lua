local M = { version = 1 }
local A = dofile("atomic.lua")
local Mining = dofile("mine-tasks.lua")
local Warehouse = dofile("warehouse-tasks.lua")
local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end
local function word(s, n) return type(s) == "string" and #s > 0 and #s <= n end
function M.pose(p)
  return type(p) == "table" and word(p.dim, 80) and p.dim:match("^[%w_]+:[%w_/.-]+$")
    and integer(p.x, -30000000, 30000000) and integer(p.y, -2048, 2048)
    and integer(p.z, -30000000, 30000000)
end
local function equal(a, b)
  return a and b and a.dim==b.dim and a.x==b.x and a.y==b.y and a.z==b.z
end
local function clone(p) return { dim = p.dim, x = p.x, y = p.y, z = p.z } end
local function chunk(p)
  return p.dim .. "|" .. math.floor(p.x / 16) .. "|" .. math.floor(p.y / 16) .. "|" .. math.floor(p.z / 16),
    p.x % 16 + 16 * (p.z % 16) + 256 * (p.y % 16) + 1
end
function M.config(raw)
  assert(type(raw) == "table" and type(raw.controllers) == "table", "invalid SSOT controllers")
  local count = 0
  for id,key in pairs(raw.controllers) do
    assert(type(id) == "string" and integer(tonumber(id),0,2147483647)
      and word(key,128) and #key >= 16, "invalid paired controller")
    count=count+1
  end
  assert(count <= 32,"controller limit")
  for name,bounds in pairs({maxChunks={1,64},pageBytes={1024,8192},leaseMs={1000,30000}}) do
    assert(raw[name] == nil or integer(raw[name],bounds[1],bounds[2]),"invalid " .. name)
  end
  raw.chatNames = raw.chatNames or {"Jeffreyy2","njov10","yolobeerman"}
  raw.chatUUIDs = raw.chatUUIDs or {}
  assert(type(raw.chatNames) == "table" and type(raw.chatUUIDs) == "table", "invalid chat allowlist")
  return raw
end
function M.chatAllowed(cfg,name,uuid)
  if type(name) ~= "string" or type(uuid) ~= "string" or #uuid ~= 36
    or not uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then return false end
  for _,allowed in ipairs(cfg.chatNames) do
    if name == allowed and cfg.chatUUIDs[allowed] == uuid then return true end
  end
  return false
end
function M.bounded(value, limit, legacy)
  local seen, size, nodes = {}, 0, 0
  local function visit(v, depth)
    nodes = nodes + 1
    if depth > (legacy and 16 or 10) or nodes > (legacy and 32768 or 2048) then return false end
    local t = type(v)
    if t == "table" then
      if seen[v] or getmetatable(v) then return false end
      seen[v] = true
      for k, x in pairs(v) do
        if type(k)~="string" and type(k)~="number" then return false end
        if not visit(k, depth + 1) or not visit(x, depth + 1) then return false end
      end
      if legacy then seen[v]=nil end
    elseif t == "string" then size = size + #v + 8
    elseif t == "number" then if v ~= v or math.abs(v) == math.huge then return false end size = size + 24
    elseif t == "boolean" then size = size + 5
    else return false end
    return size <= limit
  end
  return visit(value, 0)
end
local function canonical(v)
  if type(v)=="string" then return string.format("%q",v) end
  if type(v)~="table" then return tostring(v) end
  local keys,parts={},{}
  for k in pairs(v) do keys[#keys+1]=k end
  table.sort(keys,function(a,b)
    if type(a)==type(b) then return a<b end
    return type(a)<type(b)
  end)
  for _,k in ipairs(keys) do parts[#parts+1]="[" .. canonical(k) .. "]=" .. canonical(v[k]) end
  return "{" .. table.concat(parts,",") .. "}"
end
function M.new(s, cfg, clock, epoch, save)
  s.schema = 1
  s.chunks, s.names, s.poses = s.chunks or {}, s.names or {}, s.poses or {}
  s.moves, s.clients = s.moves or {}, s.clients or {}
  s.rev, s.seq = s.rev or 0, s.seq or 0
  cfg = cfg or {}
  local maxChunks = math.min(64, tonumber(cfg.maxChunks) or 64)
  local pageBytes = math.max(1024, math.min(8192, tonumber(cfg.pageBytes) or 8192))
  local lease = math.max(1000, math.min(30000, tonumber(cfg.leaseMs) or 5000))
  local function kindOf(op)
    if op == "traffic" or op == "snapshot" then return "read" end
    if op == "calibrate" or op == "sync" or op == "reserve" or op == "start"
      or op == "commit" or op == "release" or op == "renew" then return "control" end
    return "bulk"
  end
  local function slim(result)
    return { ok = result.ok, error = result.error, token = result.token, epoch = result.epoch,
      untilAt = result.untilAt, revision = result.revision, pose = result.pose,
      v = result.v, type = result.type, rid = result.rid, server = result.server, auth = result.auth }
  end
  local function occupied(p, owner)
    for id, pos in pairs(s.poses) do if id ~= owner and equal(p, pos) then return id end end
    for id, r in pairs(s.moves) do
      if id ~= owner and (r.phase == "started" or (r.epoch == epoch and r.untilAt > clock()))
        and (equal(p, r.to) or equal(p, r.from)) then return id end
    end
    return false
  end
  local function run(id, m)
    local op, p, r = m.op, m.pose, s.moves[id]
    if op:sub(1,5)=="mine-" then return Mining.run(s,id,m,clock,epoch,M.pose) end
    if op:sub(1,3)=="wh-" then return Warehouse.run(s,id,m,epoch,M.pose) end
    if op=="traffic" then
      if not s.poses[id] or s.poses[id].boot~=m.boot then return {ok=false,error="sync before traffic"} end
      if m.peer~=nil then
        if not integer(m.peer,0,2147483647) then return {ok=false,error="invalid traffic peer"} end
        return {ok=true,pose=s.poses[m.peer] and clone(s.poses[m.peer])}
      end
      if not M.pose(m.to) or m.to.dim~=s.poses[id].dim
        or math.abs(m.to.x-s.poses[id].x)+math.abs(m.to.y-s.poses[id].y)+math.abs(m.to.z-s.poses[id].z)~=1 then return {ok=false,error="invalid traffic destination"} end
      local peer=occupied(m.to,id)
      return {ok=true,peer=peer or false,yield=peer and id>peer or false,pose=peer and clone(s.poses[peer])}
    end
    if op=="calibrate" then
      local previous=s.poses[id]
      if not M.pose(p) or not M.pose(m.previous) or p.dim~=m.previous.dim or occupied(p,id) then
        return {ok=false,error="invalid calibration destination"}
      end
      if previous and not equal(previous,m.previous) and not equal(previous,p) then
        return {ok=false,error="stale calibration source"}
      end
      if r and (m.token~=r.token or m.epoch~=r.epoch or not equal(m.previous,r.from)) then
        return {ok=false,error="calibration needs pending token"}
      end
      s.poses[id],s.moves[id]=clone(p),nil
      s.poses[id].boot=m.boot
      return {ok=true,pose=clone(p),epoch=epoch}
    elseif op == "sync" then
      if not M.pose(p) or occupied(p, id) then return { ok = false, error = "pose conflict" } end
      if r and not equal(p, r.from) and not equal(p, r.to) then return { ok = false, error = "reconcile source or destination" } end
      if r and r.phase == "granted" and not equal(p, r.from) then return { ok = false, error = "move never started" } end
      if s.poses[id] and not r and not equal(p, s.poses[id]) then return { ok = false, error = "manual reconciliation required" } end
      s.poses[id], s.moves[id] = clone(p), nil
      s.poses[id].boot = m.boot
      return { ok = true, pose = clone(p), epoch = epoch }
    elseif op == "reserve" then
      if not M.pose(p) or not M.pose(m.to) or not equal(p, s.poses[id]) or s.poses[id].boot ~= m.boot or p.dim ~= m.to.dim
        or math.abs(p.x - m.to.x) + math.abs(p.y - m.to.y) + math.abs(p.z - m.to.z) ~= 1 then
        return { ok = false, error = "invalid adjacent source" }
      end
      if r and (r.phase == "started" or (r.epoch == epoch and r.untilAt > clock())) then return { ok = false, error = "already reserved" } end
      if occupied(m.to, id) then return { ok = false, error = "occupied" } end
      s.seq = s.seq + 1
      r = { from = clone(p), to = clone(m.to), token = epoch .. ":" .. s.seq,
        epoch = epoch, boot = m.boot, phase = "granted", untilAt = clock() + lease }
      s.moves[id] = r
      return { ok = true, token = r.token, epoch = epoch, untilAt = r.untilAt }
    elseif op == "start" or op == "commit" or op == "release" or op == "renew" then
      if not r or m.token ~= r.token or m.epoch ~= r.epoch or m.boot ~= r.boot
        or r.epoch ~= epoch or not M.pose(p) or not equal(p, r.from) then return { ok = false, error = "invalid token/source" } end
      if op == "release" then
        if r.phase == "started" then return { ok = false, error = "reconcile required" } end
        s.moves[id] = nil
      elseif r.untilAt <= clock() then return { ok = false, error = "expired; reconcile" }
      elseif op == "renew" then r.untilAt = clock() + lease
      elseif op == "start" then r.phase = "started"
      elseif op == "commit" then
        if r.phase ~= "started" or not M.pose(m.to) or not equal(m.to, r.to) then return { ok = false, error = "not started/destination" } end
        s.poses[id], s.moves[id] = clone(r.to), nil
        s.poses[id].boot = m.boot
      end
      return { ok = true, untilAt = r.untilAt }
    elseif op == "scan" then
      if not M.pose(p) or not equal(p, s.poses[id]) or not integer(m.revision, 0, s.rev)
        or type(m.cells) ~= "table" or #m.cells > 64 or #m.cells == 0 then return { ok = false, error = "invalid scan" } end
      local count, additions, names = 0, {}, {}
      for _, name in ipairs(s.names) do names[name] = true end
      for _ in pairs(s.chunks) do count = count + 1 end
      for k, c in pairs(m.cells) do
        if not integer(k, 1, #m.cells) or type(c) ~= "table" or not M.pose(c) or c.dim ~= p.dim
          or math.abs(c.x - p.x) > 32 or math.abs(c.y - p.y) > 32 or math.abs(c.z - p.z) > 32
          or not (c.name == false or (word(c.name, 128) and c.name:match("^[%w_]+:[%w_/.-]+$"))) then
          return { ok = false, error = "invalid observation" }
        end
        local key = chunk(c)
        if c.name then names[c.name] = true end
        if not s.chunks[key] and not additions[key] then additions[key], count = true, count + 1 end
        if s.chunks[key] and m.revision < s.chunks[key].rev then return { ok = false, error = "stale revision" } end
      end
      if count > maxChunks then return { ok = false, error = "resident chunk limit" } end
      local nameCount = 0
      for _ in pairs(names) do nameCount = nameCount + 1 end
      if nameCount > 256 then return { ok = false, error = "name limit" } end
      for _, c in ipairs(m.cells) do
        local key, index = chunk(c)
        local ch = s.chunks[key] or { cells = {}, rev = 0 }
        local name = 0
        if c.name then
          for i, n in ipairs(s.names) do if n == c.name then name = i break end end
          if name == 0 then
            s.names[#s.names + 1], name = c.name, #s.names + 1
          end
        end
        ch.cells[index], ch.rev, s.chunks[key] = name, s.rev + 1, ch
      end
      s.rev = s.rev + 1
      return { ok = true, revision = s.rev }
    elseif op == "snapshot" then
      if not word(m.chunk, 120) or not integer(m.cursor or 0, 0, 4096)
        or (m.revision ~= nil and not integer(m.revision, 0, 2147483647)) then return { ok = false, error = "invalid query" } end
      local ch = s.chunks[m.chunk]
      if m.revision and (not ch or m.revision ~= ch.rev) then return { ok = false, error = "stale cursor" } end
      local out = { ok = true, revision = ch and ch.rev or 0, cells = {}, cursor = 0,
        v=1,type="ssot_reply",rid=m.rid,server=os.getComputerID(),auth=cfg.controllers[tostring(id)] }
      for i = (m.cursor or 0) + 1, 4096 do
        if ch and ch.cells[i] ~= nil then
          local n = ch.cells[i]
          local entry = { i, false }
          if n ~= 0 then entry[2] = s.names[n] end
          out.cells[#out.cells + 1] = entry
          if #textutils.serialize(out, { compact = true }) > pageBytes - 16 or #out.cells > 64 then
            out.cells[#out.cells] = nil
            if #out.cells==0 then return {ok=false,error="page budget too small"} end
            out.cursor = i - 1 break
          end
        end
      end
      if #out.cells==0 and out.cursor~=0 then return {ok=false,error="page budget too small"} end
      return out
    end
    return { ok = false, error = "unknown operation" }
  end
  return { epoch=epoch,state = function() return A.copy(s) end, handle = function(id, m)
    if not integer(id, 0, 2147483647) or not M.bounded(m, 32768)
      or #textutils.serialize(m, { compact = true }) > 8192 or m.v ~= 1 or m.type ~= "ssot" or not word(m.rid, 80)
      or not word(m.boot, 80) or not word(m.op, 16) or m.expect ~= "ssot_reply"
      or not integer(m.counter, 1, 2147483647) then return nil end
    local key = cfg.controllers and cfg.controllers[tostring(id)]
    if not word(key, 128) or #key < 16 or m.secret ~= key then return nil end
    local client = s.clients[id] or { counter = 0, cache = {} }
    client.cache, client.order = client.cache or {}, client.order or {}
    local request = canonical(m)
    local requestHash = A.hash(request)
    local cached = client.cache[m.rid]
    if cached then
      if cached.request == request and (m.op~="snapshot" or
        #textutils.serialize(cached.result,{compact=true})<=pageBytes) then return A.copy(cached.result) end
      return nil
    end
    if not next(client.cache) then
      if s.applied and s.applied.rid == m.rid and s.applied.hash == requestHash and type(s.applied.result) == "table" then
        return A.copy(s.applied.result)
      end
      if client.last and client.last.rid == m.rid and client.last.hash == requestHash and type(client.last.result) == "table" then
        return A.copy(client.last.result)
      end
    end
    if m.counter <= client.counter then return nil end
    local clients = 0
    for _ in pairs(s.clients) do clients = clients + 1 end
    if clients >= 32 and not s.clients[id] then return nil end
    local previous = s
    s = A.copy(s)
    client = s.clients[id] or { counter = 0, cache = {}, order = {} }
    local result = run(id, m)
    result.v, result.type, result.rid, result.server = 1, "ssot_reply", m.rid, os.getComputerID()
    result.auth = key
    if m.op=="snapshot" and #textutils.serialize(result,{compact=true})>pageBytes then s=previous return nil end
    client.counter = m.counter
    client.order = client.order or {}
    client.order[#client.order + 1] = m.rid
    client.cache[m.rid] = { request = request, result = A.copy(result) }
    while #client.order > 8 do client.cache[table.remove(client.order, 1)] = nil end
    local kind = kindOf(m.op)
    if kind == "bulk" then
      s.applied = { rid = m.rid, hash = requestHash, rev = s.rev, result = slim(result) }
    end
    if kind ~= "read" then
      client.last = { rid = m.rid, hash = requestHash, op = m.op, result = slim(result) }
    end
    s.clients[id] = client
    local ok, err = true
    if kind ~= "read" then ok, err = (save or function() return true end)(s, kind) end
    if not ok then
      s = previous
      return { v = 1, type = "ssot_reply", rid = m.rid, server = os.getComputerID(),
        auth = key, ok = false, error = tostring(err) }
    end
    return A.copy(result)
  end }
end
local function validControl(s)
  if not (type(s) == "table" and integer(s.rev, 0, 2147483647) and integer(s.seq, 0, 2147483647)
    and integer(s.epoch, 0, 2147483647) and integer(s.mapGen or 0, 0, 2147483647)
    and type(s.poses) == "table" and type(s.moves) == "table" and type(s.clients) == "table") then return false end
  local count = 0
  for id, p in pairs(s.poses) do
    count = count + 1
    if count > 32 or not integer(id, 0, 2147483647) or not M.pose(p) or not word(p.boot, 80) then return false end
  end
  for id, r in pairs(s.moves) do
    if not s.poses[id] or type(r) ~= "table" or not M.pose(r.from) or not M.pose(r.to)
      or not equal(r.from, s.poses[id]) or r.from.dim ~= r.to.dim
      or math.abs(r.from.x - r.to.x) + math.abs(r.from.y - r.to.y) + math.abs(r.from.z - r.to.z) ~= 1
      or not word(r.token, 80) or not word(r.epoch, 80) or not word(r.boot, 80)
      or (r.phase ~= "granted" and r.phase ~= "started") or not integer(r.untilAt, 0, 9007199254740991) then return false end
  end
  count = 0
  for id, c in pairs(s.clients) do
    count = count + 1
    if count > 32 or not integer(id, 0, 2147483647) or type(c) ~= "table"
      or not integer(c.counter, 0, 2147483647) then return false end
    if c.last ~= nil and (type(c.last) ~= "table" or not word(c.last.rid, 80) or not word(c.last.hash, 16)
      or type(c.last.result) ~= "table") then return false end
  end
  return true
end
local function validMap(s, cfg)
  if not (type(s) == "table" and type(s.chunks) == "table" and type(s.names) == "table"
    and integer(s.rev, 0, 2147483647)) then return false end
  local names = 0
  for i, name in pairs(s.names) do
    names = names + 1
    if not integer(i, 1, 256) or not word(name, 128) or not name:match("^[%w_]+:[%w_/.-]+$") then return false end
  end
  if names ~= #s.names then return false end
  local count = 0
  for key, ch in pairs(s.chunks) do
    count = count + 1
    if count > (cfg.maxChunks or 64) or not word(key, 120) or not key:match("^[%w_]+:[%w_/.-]+|%-?%d+|%-?%d+|%-?%d+$")
      or type(ch) ~= "table" or not integer(ch.rev, 0, s.rev) or type(ch.cells) ~= "table" then return false end
    for i, name in pairs(ch.cells) do
      if not integer(i, 1, 4096) or not integer(name, 0, #s.names) then return false end
    end
  end
  if s.applied ~= nil and (type(s.applied) ~= "table" or not word(s.applied.rid, 80)
    or type(s.applied.result) ~= "table") then return false end
  return Mining.valid(s.mining, M.pose) and Warehouse.valid(s.warehouse, M.pose)
end
local function projectControl(s)
  local clients = {}
  for id, c in pairs(s.clients) do
    clients[id] = { counter = c.counter, last = c.last }
  end
  return { rev = s.rev or 0, seq = s.seq or 0, epoch = s.epoch or 0, mapGen = s.mapGen or 0,
    poses = s.poses, moves = s.moves, clients = clients }
end
local function projectMap(s)
  return { rev = s.rev or 0, names = s.names, chunks = s.chunks, mining = s.mining,
    warehouse = s.warehouse, applied = s.applied }
end
local function readLegacy(path)
  for _, file in ipairs({ path, path .. ".tmp", path .. ".bak" }) do
    if fs.exists(file) then
      local value = A.read(file)
      if type(value) == "table" then
        if value.schema == 1 and type(value.value) == "table" then return value.value end
        if value.v == 1 and type(value.value) == "table" then return value.value end
        return value
      end
    end
  end
end
function M.open(cfg)
  cfg = M.config(cfg)
  local disk = A.mount("/")
  local control = disk:open("ssot.control", validControl, { class = "control", limit = 32768 })
  local map = disk:open("ssot.map", function(v) return validMap(v, cfg) end, { class = "bulk", limit = 900000, anchor = "ssot.control" })
  local s
  local legacy = (control.value == nil and map.value == nil) and readLegacy("ssot.state") or nil
  if legacy then
    s = legacy
  else
    local c, m = control.value or {}, map.value or {}
    s = { schema = 1, rev = c.rev or m.rev or 0, seq = c.seq or 0, epoch = c.epoch or 0, mapGen = c.mapGen or 0,
      poses = c.poses or {}, moves = c.moves or {}, clients = c.clients or {},
      chunks = m.chunks or {}, names = m.names or {}, mining = m.mining, warehouse = m.warehouse, applied = m.applied }
  end
  s.schema = 1
  s.chunks, s.names, s.poses = s.chunks or {}, s.names or {}, s.poses or {}
  s.moves, s.clients = s.moves or {}, s.clients or {}
  s.rev, s.seq, s.epoch, s.mapGen = s.rev or 0, s.seq or 0, s.epoch or 0, s.mapGen or 0
  s.epoch = s.epoch + 1
  local function persist(state, kind)
    if kind == "read" then return true end
    if kind == "bulk" then
      local ok, err = map:save(projectMap(state))
      if not ok then return false, err end
      state.mapGen = map.generation
      return control:save(projectControl(state))
    end
    return control:save(projectControl(state))
  end
  assert(persist(s, "control"))
  if legacy then
    for _, file in ipairs({ "ssot.state", "ssot.state.tmp", "ssot.state.bak" }) do
      if fs.exists(file) then fs.delete(file) end
    end
  end
  return M.new(s, cfg, function() return os.epoch("utc") end, tostring(s.epoch), persist)
end
return M
