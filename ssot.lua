local M = { version = 1 }
local A = dofile("atomic.lua")
local Mining = dofile("mine-tasks.lua")
local Warehouse = dofile("warehouse-tasks.lua")
local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end
local function word(s, n) return type(s) == "string" and #s > 0 and #s <= n end
local function frameId(id)
  if type(id) ~= "string" or #id > 64 then return nil end
  local owner, stamp = id:match("^f:(%d+):(%d+)$")
  if not owner or not stamp then return nil end
  if #owner > 1 and owner:sub(1, 1) == "0" then return nil end
  if #stamp > 1 and stamp:sub(1, 1) == "0" then return nil end
  owner, stamp = tonumber(owner), tonumber(stamp)
  if not integer(owner, 0, 2147483647) or not integer(stamp, 0, 9007199254740991) then return nil end
  if id ~= "f:" .. owner .. ":" .. stamp then return nil end
  return owner, stamp
end
function M.pose(p)
  if not (type(p) == "table" and word(p.dim, 80) and p.dim:match("^[%w_]+:[%w_/.-]+$")
    and integer(p.x, -30000000, 30000000) and integer(p.y, -2048, 2048)
    and integer(p.z, -30000000, 30000000)) then return false end
  if p.frame ~= nil and p.frame ~= "abs" and not frameId(p.frame) then return false end
  if p.h ~= nil and not integer(p.h, 0, 3) then return false end
  return true
end
function M.toAbs(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for k in pairs(t) do
    n = n + 1
    if k ~= "dx" and k ~= "dy" and k ~= "dz" and k ~= "rot" then return false end
  end
  return n == 4 and integer(t.dx, -60000000, 60000000) and integer(t.dy, -4096, 4096)
    and integer(t.dz, -60000000, 60000000) and integer(t.rot, 0, 3)
end
function M.pos(p)
  if type(p) ~= "table" or p.v ~= 1 then return false end
  local n = 0
  for k in pairs(p) do
    n = n + 1
    if k ~= "v" and k ~= "frame" and k ~= "yAbs" and k ~= "dim" and k ~= "x" and k ~= "y"
      and k ~= "z" and k ~= "h" and k ~= "conf" and k ~= "src" and k ~= "anchoredAt" then return false end
  end
  if n ~= 11 or not M.pose(p) then return false end
  if p.frame ~= "abs" and not frameId(p.frame) then return false end
  if p.yAbs ~= true and p.yAbs ~= false then return false end
  if p.frame == "abs" and p.yAbs ~= true then return false end
  if (p.conf ~= "certain" and p.conf ~= "suspect" and p.conf ~= "lost")
    or (p.src ~= "gps" and p.src ~= "neighbour" and p.src ~= "radio" and p.src ~= "typed"
      and p.src ~= "reckoned" and p.src ~= "inherited") then return false end
  return integer(p.anchoredAt, 0, 9007199254740991) and integer(p.h, 0, 3)
end
local function frameOf(p)
  if type(p) ~= "table" or p.frame == nil or p.frame == "abs" then return "abs" end
  return p.frame
end
local function equal(a, b)
  return a and b and frameOf(a)==frameOf(b) and a.dim==b.dim and a.x==b.x and a.y==b.y and a.z==b.z
end
local function clone(p)
  local o = { dim = p.dim, x = p.x, y = p.y, z = p.z }
  if p.h ~= nil then o.h = p.h end
  if p.v ~= nil then o.v = p.v end
  if p.frame ~= nil then o.frame = p.frame end
  if p.yAbs ~= nil then o.yAbs = p.yAbs end
  if p.conf ~= nil then o.conf = p.conf end
  if p.src ~= nil then o.src = p.src end
  if p.anchoredAt ~= nil then o.anchoredAt = p.anchoredAt end
  return o
end
local function sameToAbs(a, b)
  return type(a)=="table" and type(b)=="table" and a.dx==b.dx and a.dy==b.dy and a.dz==b.dz and a.rot==b.rot
end
local function rotateToAbs(x, y, z, h, yAbs, toAbs)
  if yAbs and toAbs.dy ~= 0 then return nil end
  local rot = toAbs.rot
  local rx, rz
  if rot == 0 then rx, rz = x, z
  elseif rot == 1 then rx, rz = -z, x
  elseif rot == 2 then rx, rz = -x, -z
  else rx, rz = z, -x end
  local x2, y2, z2 = rx + toAbs.dx, yAbs and y or y + toAbs.dy, rz + toAbs.dz
  if not integer(x2, -30000000, 30000000) or not integer(y2, -2048, 2048) or not integer(z2, -30000000, 30000000) then
    return nil
  end
  return x2, y2, z2, h ~= nil and (h + rot) % 4 or nil
end
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
  local failed = false
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
      if not M.pose(p) or not M.pose(m.to) or not equal(p, s.poses[id]) or frameOf(p) ~= frameOf(m.to)
        or s.poses[id].boot ~= m.boot or p.dim ~= m.to.dim
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
    elseif op == "anchor" then
      if not M.pos(p) or p.conf ~= "certain" then return { ok = false, error = "invalid anchor" } end
      local ev = m.evidence
      if type(ev) ~= "table" or (ev.source ~= "typed" and ev.source ~= "neighbour" and ev.source ~= "gps" and ev.source ~= "radio")
        or not word(ev.reference, 64) or type(ev.faces) ~= "table" then return { ok = false, error = "invalid anchor evidence" } end
      local faces = 0
      for dir, name in pairs(ev.faces) do
        faces = faces + 1
        if faces > 6 or not integer(dir, 0, 5) or not word(name, 128) or not name:match("^[%w_]+:[%w_/.-]+$") then
          return { ok = false, error = "invalid anchor evidence" }
        end
      end
      if faces < 1 then return { ok = false, error = "invalid anchor evidence" } end
      if p.frame ~= "abs" then
        local frames = s.frames or {}
        local owner = frameId(p.frame)
        local rec = frames[p.frame]
        if rec then
          if rec.dim ~= p.dim or rec.frame.yAbs ~= p.yAbs or rec.frame.owner ~= owner or rec.frame.toAbs ~= false then
            return { ok = false, error = "frame mismatch" }
          end
        else
          local n = 0
          for _ in pairs(frames) do n = n + 1 end
          if n >= 32 then return { ok = false, error = "frame limit" } end
        end
      end
      if occupied(p, id) then return { ok = false, error = "occupied" } end
      if p.frame ~= "abs" and not (s.frames and s.frames[p.frame]) then
        s.frames = s.frames or {}
        local owner = frameId(p.frame)
        s.frames[p.frame] = { frame = { v = 1, id = p.frame, owner = owner, yAbs = p.yAbs, toAbs = false }, dim = p.dim, receipt = false }
        s.rel = s.rel or {}
        s.rel[p.frame] = s.rel[p.frame] or { dim = p.dim, cells = {} }
      end
      s.poses[id] = clone(p)
      s.poses[id].boot = m.boot
      s.moves[id] = nil
      return { ok = true, pose = clone(p), epoch = epoch }
    elseif op == "frame-merge" then
      local idf = m.id
      local rec = type(idf) == "string" and s.frames and s.frames[idf] or nil
      if not rec or type(rec.frame) ~= "table" then return { ok = false, error = "unknown frame" } end
      if not M.toAbs(m.toAbs) then return { ok = false, error = "invalid transform" } end
      if rec.frame.yAbs and m.toAbs.dy ~= 0 then return { ok = false, error = "yAbs transform" } end
      if rec.frame.toAbs ~= false then
        if sameToAbs(rec.frame.toAbs, m.toAbs) then return { ok = true, id = idf, idempotent = true, state = "committed" } end
        return { ok = false, error = "frame already merged" }
      end
      for _, mv in pairs(s.moves) do
        if frameOf(mv.from) == idf or frameOf(mv.to) == idf then return { ok = false, error = "frame busy" } end
      end
      local bucket = (s.rel and s.rel[idf]) or { cells = {} }
      local painted, additions, count, names = {}, {}, 0, {}
      for _ in pairs(s.chunks) do count = count + 1 end
      for _, name in ipairs(s.names) do names[name] = true end
      for _, c in ipairs(bucket.cells or {}) do
        if type(c) ~= "table" or not integer(c.x, -30000000, 30000000) or not integer(c.y, -2048, 2048)
          or not integer(c.z, -30000000, 30000000) then return { ok = false, error = "invalid relative cell" } end
        local x, y, z = rotateToAbs(c.x, c.y, c.z, nil, rec.frame.yAbs, m.toAbs)
        if not x then return { ok = false, error = "transform out of bounds" } end
        local world = { dim = rec.dim, x = x, y = y, z = z, name = c.name }
        local key = chunk(world)
        if not s.chunks[key] and not additions[key] then additions[key], count = true, count + 1 end
        if world.name and world.name ~= false then names[world.name] = true end
        painted[#painted + 1] = world
      end
      local poseUpdates = {}
      for pid, pose in pairs(s.poses) do
        if frameOf(pose) == idf then
          local x, y, z, h = rotateToAbs(pose.x, pose.y, pose.z, pose.h, rec.frame.yAbs, m.toAbs)
          if not x then return { ok = false, error = "transform out of bounds" } end
          poseUpdates[pid] = { x = x, y = y, z = z, h = h }
        end
      end
      if count > maxChunks then return { ok = false, error = "resident chunk limit" } end
      local nameCount = 0
      for _ in pairs(names) do nameCount = nameCount + 1 end
      if nameCount > 256 then return { ok = false, error = "name limit" } end
      for _, world in ipairs(painted) do
        local key, index = chunk(world)
        local ch = s.chunks[key] or { cells = {}, rev = 0 }
        local name = 0
        if world.name and world.name ~= false then
          for i, n in ipairs(s.names) do if n == world.name then name = i break end end
          if name == 0 then s.names[#s.names + 1], name = world.name, #s.names + 1 end
        end
        ch.cells[index], ch.rev, s.chunks[key] = name, s.rev + 1, ch
      end
      for pid, upd in pairs(poseUpdates) do
        local pose = s.poses[pid]
        local boot = pose.boot
        local n = clone(pose)
        n.x, n.y, n.z, n.frame, n.yAbs, n.src = upd.x, upd.y, upd.z, "abs", true, "inherited"
        if upd.h ~= nil then n.h = upd.h end
        s.poses[pid] = n
        s.poses[pid].boot = boot
      end
      s.rev = s.rev + 1
      rec.frame.toAbs = { dx = m.toAbs.dx, dy = m.toAbs.dy, dz = m.toAbs.dz, rot = m.toAbs.rot }
      rec.receipt = { id = idf, dim = rec.dim, toAbs = rec.frame.toAbs, sourceHash = false, targetHash = false, state = "committed" }
      return { ok = true, id = idf, idempotent = false, state = "committed" }
    elseif op == "scan" then
      if not M.pose(p) or not equal(p, s.poses[id]) or not integer(m.revision, 0, s.rev)
        or type(m.cells) ~= "table" or #m.cells > 64 or #m.cells == 0 then return { ok = false, error = "invalid scan" } end
      if frameOf(p) ~= "abs" then
        local rec = s.frames and s.frames[p.frame]
        if not rec or rec.frame.toAbs ~= false or rec.dim ~= p.dim then return { ok = false, error = "unknown frame" } end
        for k, c in pairs(m.cells) do
          if not integer(k, 1, #m.cells) or type(c) ~= "table" or not M.pose(c) or c.dim ~= p.dim
            or math.abs(c.x - p.x) > 32 or math.abs(c.y - p.y) > 32 or math.abs(c.z - p.z) > 32
            or not (c.name == false or (word(c.name, 128) and c.name:match("^[%w_]+:[%w_/.-]+$"))) then
            return { ok = false, error = "invalid observation" }
          end
        end
        s.rel = s.rel or {}
        local bucket = s.rel[p.frame] or { dim = p.dim, cells = {} }
        local cells = {}
        for _, old in ipairs(bucket.cells) do cells[#cells + 1] = { x = old.x, y = old.y, z = old.z, name = old.name } end
        for _, c in ipairs(m.cells) do
          local replaced = false
          for i, old in ipairs(cells) do
            if old.x == c.x and old.y == c.y and old.z == c.z then
              cells[i] = { x = c.x, y = c.y, z = c.z, name = c.name }
              replaced = true
              break
            end
          end
          if not replaced then
            if #cells >= 1024 then return { ok = false, error = "relative map full" } end
            cells[#cells + 1] = { x = c.x, y = c.y, z = c.z, name = c.name }
          end
        end
        bucket.cells, bucket.dim, s.rel[p.frame] = cells, p.dim, bucket
        return { ok = true, revision = s.rev }
      end
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
    if failed or not integer(id, 0, 2147483647) or not M.bounded(m, 32768)
      or #textutils.serialize(m, { compact = true }) > 8192 or m.v ~= 1 or m.type ~= "ssot" or not word(m.rid, 80)
      or not word(m.boot, 80) or not word(m.op, 16) or m.expect ~= "ssot_reply"
      or not integer(m.counter, 1, 2147483647) then return nil end
    local key = cfg.controllers and cfg.controllers[tostring(id)]
    if not word(key, 128) or #key < 16 or m.secret ~= key then return nil end
    local client = s.clients[id] or { counter = 0, cache = {} }
    local request = canonical(m)
    local cached = client.cache[m.rid]
    if cached then
      if cached.request == request and (m.op~="snapshot" or
        #textutils.serialize(cached.result,{compact=true})<=pageBytes) then return A.copy(cached.result) end
      return nil
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
    s.clients[id] = client
    local ok, err = (save or function() return true end)(s)
    if not ok then s, failed = previous, true return nil, tostring(err) end
    return A.copy(result)
  end }
end
function M.open(cfg)
  cfg = M.config(cfg)
  local store = A.store("ssot.state", function(s)
    if not (type(s) == "table" and s.schema == 1 and type(s.chunks) == "table"
      and type(s.poses) == "table" and type(s.moves) == "table" and type(s.clients) == "table"
      and type(s.names) == "table" and integer(s.rev, 0, 2147483647)
      and integer(s.seq, 0, 2147483647) and integer(s.epoch, 0, 2147483647)) then return false end
    local names=0
    for i,name in pairs(s.names) do
      names=names+1
      if not integer(i,1,256) or not word(name,128) or not name:match("^[%w_]+:[%w_/.-]+$") then return false end
    end
    if names~=#s.names then return false end
    local count=0
    for key,ch in pairs(s.chunks) do
      count=count+1
      if count>(cfg.maxChunks or 64) or not word(key,120) or not key:match("^[%w_]+:[%w_/.-]+|%-?%d+|%-?%d+|%-?%d+$")
        or type(ch)~="table" or not integer(ch.rev,0,s.rev) or type(ch.cells)~="table" then return false end
      for i,name in pairs(ch.cells) do
        if not integer(i,1,4096) or not integer(name,0,#s.names) then return false end
      end
      if count%4==0 then sleep(0) end
    end
    count=0
    for id,p in pairs(s.poses) do
      count=count+1
      if count>32 or not integer(id,0,2147483647) or not M.pose(p) or not word(p.boot,80) then return false end
      if p.v ~= nil and p.v ~= 1 then return false end
      if p.conf ~= nil and p.conf ~= "certain" and p.conf ~= "suspect" and p.conf ~= "lost" then return false end
      if p.frame == "abs" and p.yAbs == false then return false end
    end
    if s.frames ~= nil then
      if type(s.frames) ~= "table" then return false end
      local n = 0
      for id, rec in pairs(s.frames) do
        n = n + 1
        if n > 32 or type(id) ~= "string" or type(rec) ~= "table" or type(rec.frame) ~= "table"
          or rec.frame.v ~= 1 or rec.frame.id ~= id or not word(rec.dim, 80) then return false end
        if rec.frame.toAbs ~= false and not M.toAbs(rec.frame.toAbs) then return false end
        if rec.receipt ~= false and (type(rec.receipt) ~= "table" or rec.receipt.state ~= "committed") then return false end
      end
    end
    if s.rel ~= nil then
      if type(s.rel) ~= "table" or s.frames == nil then return false end
      for id, bucket in pairs(s.rel) do
        if s.frames[id] == nil or type(bucket) ~= "table" or type(bucket.cells) ~= "table" then return false end
        local n = 0
        for _, c in ipairs(bucket.cells) do
          n = n + 1
          if n > 1024 or type(c) ~= "table" or not integer(c.x, -30000000, 30000000)
            or not integer(c.y, -2048, 2048) or not integer(c.z, -30000000, 30000000) then return false end
        end
        if n ~= #bucket.cells then return false end
      end
    end
    for id,r in pairs(s.moves) do
      if not s.poses[id] or type(r)~="table" or not M.pose(r.from) or not M.pose(r.to)
        or not equal(r.from,s.poses[id]) or r.from.dim~=r.to.dim
        or math.abs(r.from.x-r.to.x)+math.abs(r.from.y-r.to.y)+math.abs(r.from.z-r.to.z)~=1
        or not word(r.token,80) or not word(r.epoch,80) or not word(r.boot,80)
        or (r.phase~="granted" and r.phase~="started") or not integer(r.untilAt,0,9007199254740991) then return false end
    end
    count=0
    for id,c in pairs(s.clients) do
      count=count+1
      if count>32 or not integer(id,0,2147483647) or type(c)~="table"
        or not integer(c.counter,0,2147483647) or type(c.cache)~="table" or type(c.order)~="table" or #c.order>8 then return false end
      local cached=0
      for rid,entry in pairs(c.cache) do
        cached=cached+1
        if cached>8 or not word(rid,80) or type(entry)~="table" or not word(entry.request,32768)
          or type(entry.result)~="table" or entry.result.type~="ssot_reply" then return false end
      end
    end
    return Mining.valid(s.mining,M.pose) and Warehouse.valid(s.warehouse,M.pose)
  end, 900000)
  local s = store.value or { schema = 1, chunks = {}, names = {}, poses = {}, moves = {},
    clients = {}, rev = 0, seq = 0, epoch = 0 }
  s.epoch = s.epoch + 1
  assert(store.save(s))
  return M.new(s, cfg, function() return os.epoch("utc") end, tostring(s.epoch), store.save)
end
return M
