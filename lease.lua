-- Lease v2, exclusive cells, and order-independent observation replay.
-- Enabled only when ssot cfg.leaseV2 is true. The MAC provider is H1H2.
local M = {}
local N1 = dofile("lib/stubs/b1_n1.lua")
local H5 = dofile("lib/stubs/b1_h5.lua")
local W1 = dofile("lib/stubs/b1_w1.lua")
local Journal = dofile("journal.lua")

local MAX_AREA = 65536
local MAX_SPAN = 512
local MAX_CORRIDOR = 256
local CLOCK_MAX = 9007199254740991

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[copy(k)] = copy(x) end
  return out
end

local function canonical(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local keys, parts = {}, {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) < type(b)
  end)
  for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. canonical(k) .. "]=" .. canonical(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.message(lease)
  local body = copy(lease)
  body.mac = nil
  return "b1-lease-v2\0" .. canonical(body)
end

local function sign(lease, key, macfn)
  lease.mac = nil
  local mac, err = macfn(key, M.message(lease))
  if type(mac) ~= "string" or not mac:match("^[%x]+$") or #mac < 8 or #mac > 128 or #mac % 2 ~= 0 then
    return nil, err or "mac provider unavailable"
  end
  lease.mac = mac
  return lease
end

function M.verify(lease, key, macfn)
  if type(lease) ~= "table" or type(lease.mac) ~= "string" or type(macfn) ~= "function" then return false end
  local expect = macfn(key, M.message(lease))
  return type(expect) == "string" and expect == lease.mac
end

local function frameOk(frame)
  return frame == "abs" or (type(frame) == "string" and #frame <= 64 and frame:match("^f:[%w:_-]+$") ~= nil)
end

local function accessOk(a, frame)
  return type(a) == "table" and (a.side == "front" or a.side == "top" or a.side == "bottom")
    and N1.pos(a.pose) and a.pose.frame == frame
end

local function adjacent(a, b)
  return a.dim == b.dim and a.frame == b.frame
    and math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z) == 1
end

function M.shape(lease)
  if type(lease) ~= "table" or lease.v ~= 2 or type(lease.id) ~= "string" or #lease.id == 0 or #lease.id > 80 then
    return false
  end
  if not integer(lease.turtle, 0, 2147483647) or type(lease.boot) ~= "string" or #lease.boot == 0 or #lease.boot > 80 then
    return false
  end
  if type(lease.epoch) ~= "string" or not lease.epoch:match("^%d+$") or #lease.epoch > 20 then return false end
  if not integer(lease.issuedAt, 0, CLOCK_MAX) or not integer(lease.untilAt, 0, CLOCK_MAX) then return false end
  if not integer(lease.workUntil, lease.issuedAt, CLOCK_MAX) or not integer(lease.issuedRev, 0, 2147483647) then
    return false
  end
  if not frameOk(lease.frame) or (lease.grant ~= "work" and lease.grant ~= "return") then return false end
  if not integer(lease.fuelReserve, 0, 1000000) then return false end
  if lease.mac ~= nil and (type(lease.mac) ~= "string" or not lease.mac:match("^[%x]+$")) then return false end
  if lease.grant == "work" and lease.workUntil > lease.untilAt then return false end
  local area = lease.area
  if type(area) ~= "table" or not N1.pos(area.min) or not N1.pos(area.max) then return false end
  if area.min.frame ~= lease.frame or area.max.frame ~= lease.frame or area.min.dim ~= area.max.dim then return false end
  if area.min.x > area.max.x or area.min.y > area.max.y or area.min.z > area.max.z then return false end
  local spanX, spanY, spanZ = area.max.x - area.min.x + 1, area.max.y - area.min.y + 1, area.max.z - area.min.z + 1
  if spanX > MAX_SPAN or spanY > MAX_SPAN or spanZ > MAX_SPAN or spanX * spanY * spanZ > MAX_AREA then return false end
  if type(lease.corridor) ~= "table" or #lease.corridor < 1 or #lease.corridor > MAX_CORRIDOR then return false end
  for i, cell in ipairs(lease.corridor) do
    if not N1.pos(cell) or cell.frame ~= lease.frame or cell.dim ~= area.min.dim then return false end
    if i > 1 and not adjacent(lease.corridor[i - 1], cell) then return false end
  end
  if not N1.pos(lease.home) or lease.home.frame ~= lease.frame or lease.home.dim ~= area.min.dim then return false end
  if not N1.same(lease.corridor[1], lease.home) and not N1.same(lease.corridor[#lease.corridor], lease.home) then
    return false
  end
  if not accessOk(lease.dropoff, lease.frame) or not accessOk(lease.charger, lease.frame) then return false end
  local settings = lease.settings
  if type(settings) ~= "table" or not integer(settings.revision, 0, 2147483647) or type(settings.values) ~= "table" then
    return false
  end
  return true
end

function M.onPath(lease, p)
  if N1.same(p, lease.home) then return true end
  for _, cell in ipairs(lease.corridor) do if N1.same(cell, p) then return true end end
  return false
end

function M.inArea(lease, p)
  local area = lease.area
  local frame = p.frame or "abs"
  return frame == area.min.frame and p.dim == area.min.dim and p.x >= area.min.x and p.x <= area.max.x
    and p.y >= area.min.y and p.y <= area.max.y and p.z >= area.min.z and p.z <= area.max.z
end

function M.covers(lease, p)
  return M.inArea(lease, p) or M.onPath(lease, p)
end

function M.cellOwned(lease, p)
  if (p.frame or "abs") ~= lease.frame then return false end
  if lease.grant == "return" then return M.onPath(lease, p) end
  return M.covers(lease, p)
end

function M.inside(lease, p, at)
  if lease.turtle == nil or at < lease.issuedAt then return false end
  if lease.grant == "return" then
    return at < lease.untilAt and M.onPath(lease, p)
  end
  return at < lease.workUntil and M.covers(lease, p)
end

local function live(lease, now)
  return type(lease) == "table" and type(now) == "number" and lease.grant ~= nil
    and type(lease.untilAt) == "number" and now < lease.untilAt and not lease.fenced
end

local function fence(lease, now)
  if type(lease) ~= "table" or type(now) ~= "number" or type(lease.untilAt) ~= "number" then return end
  if lease.fenced or now < lease.untilAt then return end
  lease.fenced = true
  lease.recovery = H5.fence(lease, now)
end

function M.occupies(s, p, owner, now)
  if type(s.leases) ~= "table" or type(p) ~= "table" then return false end
  for _, lease in pairs(s.leases) do
    fence(lease, now)
    if lease.turtle ~= owner and live(lease, now) and M.cellOwned(lease, p) then return lease.turtle end
  end
  return false
end

local function overlaps(s, candidate, now)
  for id, other in pairs(s.leases or {}) do
    if id ~= candidate.id and other.turtle ~= candidate.turtle then
      fence(other, now)
      if live(other, now) then
        local a, b = candidate.area, other.area
        if candidate.grant ~= "return" and other.grant ~= "return" and a.min.dim == b.min.dim and a.min.frame == b.min.frame
          and a.min.x <= b.max.x and b.min.x <= a.max.x and a.min.y <= b.max.y and b.min.y <= a.max.y
          and a.min.z <= b.max.z and b.min.z <= a.max.z then
          return other.turtle
        end
        local function hits(lease, point)
          if lease.grant == "return" then return M.onPath(lease, point) end
          return M.covers(lease, point)
        end
        if candidate.grant ~= "return" then
          for _, cell in ipairs(other.grant == "return" and other.corridor or {}) do
            if M.inArea(candidate, cell) or M.onPath(candidate, cell) then return other.turtle end
          end
          if other.grant == "return" and (M.inArea(candidate, other.home) or M.onPath(candidate, other.home)) then
            return other.turtle
          end
        end
        for _, cell in ipairs(candidate.corridor) do if hits(other, cell) then return other.turtle end end
        if hits(other, candidate.home) then return other.turtle end
        if other.grant ~= "return" and candidate.grant ~= "return" then
          for _, cell in ipairs(other.corridor) do if hits(candidate, cell) then return other.turtle end end
        end
      end
    end
  end
  return false
end

local function closer(from, to, home)
  local function dist(p)
    return math.abs(p.x - home.x) + math.abs(p.y - home.y) + math.abs(p.z - home.z)
  end
  return dist(to) < dist(from)
end

function M.authorize(spec)
  local lease, settings = spec.lease, spec.settings or (spec.lease and spec.lease.settings)
  if not settings or not settings.values or settings.values.offlineAutonomy ~= true then return "rpc", "offline autonomy disabled" end
  if not lease then return "rpc", "no lease" end
  local from, to, now = spec.from, spec.to, spec.now
  if not N1.pos(from) or not N1.pos(to) then return "denied", "invalid pose" end
  if from.conf == "lost" or to.conf == "lost" then return "denied", "lost" end
  if spec.dig and from.conf ~= "certain" then return "denied", "lost" end
  if from.dim ~= to.dim or (from.frame or "abs") ~= (to.frame or "abs")
    or math.abs(from.x - to.x) + math.abs(from.y - to.y) + math.abs(from.z - to.z) ~= 1 then
    return "denied", "not adjacent"
  end
  local home = spec.home or lease.home
  local headingHome = (not spec.dig) and closer(from, to, home) and M.cellOwned(lease, from) and M.cellOwned(lease, to)
  if not live(lease, now) or lease.grant == "return" then
    if lease.grant == "return" and live(lease, now) and headingHome then return "return" end
    return "denied", "expired"
  end
  if Journal.shouldReturn(spec.journal) then
    if headingHome then return "return", "journal budget" end
    return "denied", "journal budget"
  end
  local every = settings.values.checkInEveryMs or 60000
  if now >= lease.issuedAt + every then
    if headingHome then return "return", "check in" end
    return "denied", "check in"
  end
  if not M.covers(lease, from) or not M.covers(lease, to) then return "denied", "outside lease" end
  return "local"
end

local function chunkOf(p)
  return p.dim .. "|" .. math.floor(p.x / 16) .. "|" .. math.floor(p.y / 16) .. "|" .. math.floor(p.z / 16),
    p.x % 16 + 16 * (p.z % 16) + 256 * (p.y % 16) + 1
end

local function mapKey(p)
  return (p.frame or "abs") .. "|" .. p.dim .. "|" .. p.x .. "|" .. p.y .. "|" .. p.z
end

local function beats(a, b)
  if a.at ~= b.at then return a.at > b.at end
  if a.turtle ~= b.turtle then return a.turtle > b.turtle end
  return a.seq > b.seq
end

local function keep(best, claim)
  if not best or beats(claim, best) then return claim end
  return best
end

function M.baseCell(s, pos)
  local key = mapKey(pos)
  if s.leaseMap and s.leaseMap[key] then return s.leaseMap[key], key end
  local unknown, name, ruleRev = true, false, 0
  if (pos.frame or "abs") == "abs" then
    local chunkKey, index = chunkOf(pos)
    local chunk = s.chunks and s.chunks[chunkKey]
    if chunk then
      ruleRev = chunk.rev or 0
      if chunk.cells and chunk.cells[index] ~= nil then
        unknown = false
        local stored = chunk.cells[index]
        if stored == 0 then name = false else name = s.names[stored] end
      end
    end
  end
  return {
    v = 1, ruleRev = ruleRev, baseUnknown = unknown, baseName = name,
    holder = false, fresh = false, sawStale = false,
  }, key
end

function M.outcome(cell)
  if cell.holder then return cell.holder.name, false end
  if cell.fresh then return cell.fresh.name, false end
  if cell.sawStale or cell.baseUnknown then return nil, true end
  return cell.baseName, false
end

local function classify(cell, lease, pos, at)
  if M.inside(lease, pos, at) then return "holder" end
  if cell.baseUnknown or cell.ruleRev <= lease.issuedRev then return "fresh" end
  return "stale"
end

function M.claim(cell, lease, obs)
  local kind = classify(cell, lease, obs.pos, obs.at)
  local claim = { name = obs.name, at = obs.at, turtle = obs.turtle, seq = obs.seq }
  if kind == "holder" then cell.holder = keep(cell.holder, claim)
  elseif kind == "fresh" then cell.fresh = keep(cell.fresh, claim)
  else cell.sawStale = true end
  return cell
end

local function roomFor(s, writes, maxChunks)
  local seen, names, chunks, nameCount = {}, {}, {}, #s.names
  for _, known in ipairs(s.names) do names[known] = true end
  for key in pairs(s.chunks) do chunks[key] = true seen[key] = true end
  local chunkCount = 0
  for _ in pairs(seen) do chunkCount = chunkCount + 1 end
  for _, write in ipairs(writes) do
    if (write.pos.frame or "abs") == "abs" and not write.unknown then
      local key = chunkOf(write.pos)
      if not chunks[key] then
        chunks[key] = true
        chunkCount = chunkCount + 1
        if chunkCount > maxChunks then return false, "resident chunk limit" end
      end
      if write.name and not names[write.name] then
        names[write.name] = true
        nameCount = nameCount + 1
        if nameCount > 256 then return false, "name limit" end
      end
    end
  end
  return true
end

local function project(s, pos, name, unknown, maxChunks)
  if (pos.frame or "abs") ~= "abs" then return true end
  local key, index = chunkOf(pos)
  local chunk = s.chunks[key]
  if unknown then
    if chunk and chunk.cells then chunk.cells[index] = nil end
    return true
  end
  if not chunk then
    local count = 0
    for _ in pairs(s.chunks) do count = count + 1 end
    if count >= maxChunks then return false, "resident chunk limit" end
    chunk = { cells = {}, rev = 0 }
    s.chunks[key] = chunk
  end
  local stored = 0
  if name then
    if type(name) ~= "string" or not name:match("^[%w_]+:[%w_/.-]+$") then return false, "invalid observation" end
    for i, known in ipairs(s.names) do if known == name then stored = i break end end
    if stored == 0 then
      if #s.names >= 256 then return false, "name limit" end
      s.names[#s.names + 1] = name
      stored = #s.names
    end
  end
  chunk.cells[index] = stored
  s.rev = s.rev + 1
  chunk.rev = s.rev
  return true
end

function M.view(s)
  local cells = {}
  for key, cell in pairs(s.leaseMap or {}) do
    local name, unknown = M.outcome(cell)
    cells[#cells + 1] = { key = key, name = name, unknown = unknown }
  end
  table.sort(cells, function(a, b) return a.key < b.key end)
  return cells
end

local function fail(why)
  return { ok = false, error = why }
end

local function macfnOf(cfg)
  if type(cfg.leaseMac) == "function" then return cfg.leaseMac end
  return dofile("lib/stubs/b1_h1.lua").keyed
end

local function build(spec, id, turtle, boot, epoch, now, rev, macfn, key)
  local settings, why = W1.snapshot(spec.settingsRevision, spec.settings)
  if not settings then return nil, why end
  local duration = settings.values.leaseMs
  local lease = {
    v = 2, id = id, turtle = turtle, boot = boot, epoch = tostring(epoch),
    issuedAt = now, untilAt = now + duration, workUntil = now + duration, issuedRev = rev,
    frame = spec.frame or (spec.area and spec.area.min and spec.area.min.frame) or "abs",
    grant = "work", area = spec.area, corridor = spec.corridor,
    dropoff = spec.dropoff, charger = spec.charger, home = spec.home,
    settings = settings, fuelReserve = spec.fuelReserve,
  }
    if not M.shape(lease) then return nil, "invalid lease" end
    local signed, why = sign(lease, key, macfn)
    if not signed then return nil, why end
    if not M.shape(signed) then return nil, "invalid lease" end
    return signed
end

local function noteItem(s, turtle, entry)
  if entry.kind ~= "item" or entry.phase ~= "done" then return end
  s.leaseItems = s.leaseItems or {}
  s.leaseItems[turtle] = s.leaseItems[turtle] or {}
  s.leaseItems[turtle][entry.name] = entry.count
end

local function mapTouch(entry)
  if entry.kind == "observe" and entry.phase == "done" then
    return entry.cell, entry.name == false and false or entry.name
  end
  if entry.kind == "dig" and entry.phase == "done" then return entry.cell, false end
  return nil
end

function M.run(s, id, m, clock, epoch, cfg)
  local now = clock()
  local key = cfg.controllers and cfg.controllers[tostring(id)]
  local macfn = macfnOf(cfg)
  s.leases = s.leases or {}
  if m.op == "lease-issue" or m.op == "lease-renew" or m.op == "lease-return" then
    if not s.poses[id] or s.poses[id].boot ~= m.boot then return fail("sync before lease") end
  end
  if m.op == "lease-issue" then
    for _, lease in pairs(s.leases) do
      fence(lease, now)
      if lease.turtle == id and live(lease, now) then return fail("lease already held") end
    end
    s.seq = s.seq + 1
    local issued, why = build({
      area = m.area, corridor = m.corridor, dropoff = m.dropoff, charger = m.charger, home = m.home,
      fuelReserve = m.fuelReserve, settings = m.settings, settingsRevision = m.settingsRevision, frame = m.frame,
    }, epoch .. ":mine:" .. s.seq, id, m.boot, epoch, now, s.rev, macfn, key)
    if not issued then s.seq = s.seq - 1 return fail(why) end
    local pose = s.poses[id]
    if not M.covers(issued, pose) then s.seq = s.seq - 1 return fail("pose outside lease") end
    local held = overlaps(s, issued, now)
    if held then s.seq = s.seq - 1 return fail("occupied") end
    s.leases[issued.id] = issued
    return { ok = true, lease = copy(issued) }
  elseif m.op == "lease-renew" then
    local lease = s.leases[m.id]
    if type(m.id) ~= "string" or not lease or lease.turtle ~= id or lease.boot ~= m.boot then return fail("unknown lease") end
    fence(lease, now)
    if not live(lease, now) or lease.grant ~= "work" then return fail("expired") end
    local acked = s.leaseAck and s.leaseAck[id] and s.leaseAck[id][lease.id] or 0
    if m.seq ~= nil and (not integer(m.seq, 0, 2147483647) or acked < m.seq) then return fail("replay required") end
    local nextLease = copy(lease)
    local duration = nextLease.settings.values.leaseMs
    nextLease.untilAt = now + duration
    nextLease.workUntil = nextLease.untilAt
    local signed, why = sign(nextLease, key, macfn)
    if not signed then return fail(why) end
    s.leases[lease.id] = signed
    return { ok = true, lease = copy(signed) }
  elseif m.op == "lease-return" then
    local lease = s.leases[m.id]
    if type(m.id) ~= "string" or not lease or lease.turtle ~= id then return fail("unknown lease") end
    local nextLease = copy(lease)
    nextLease.grant = "return"
    nextLease.fenced = nil
    nextLease.recovery = nil
    nextLease.untilAt = now + nextLease.settings.values.returnMarginMs
    local held = overlaps(s, nextLease, now)
    if held then return fail("occupied") end
    local signed, why = sign(nextLease, key, macfn)
    if not signed then return fail(why) end
    s.leases[lease.id] = signed
    return { ok = true, lease = copy(signed) }
  elseif m.op == "lease-replay" then
    local lease = type(m.id) == "string" and s.leases[m.id] or nil
    if not lease or lease.turtle ~= id then return fail("unknown lease") end
    if type(m.entries) ~= "table" or #m.entries == 0 or #m.entries > 32 then return fail("invalid replay") end
    local ack = s.leaseAck and s.leaseAck[id] and s.leaseAck[id][lease.id] or 0
    local first = m.entries[1] and m.entries[1].seq
    for i, entry in ipairs(m.entries) do
      if not Journal.validEntry(entry, id) or entry.lease ~= lease.id or entry.frame ~= lease.frame
        or entry.seq ~= first + i - 1 then
        return fail("invalid journal entry")
      end
    end
    if first > ack + 1 then return fail("journal gap") end
    local applyFrom = 1
    if first <= ack then
      if m.entries[#m.entries].seq <= ack then
        return { ok = true, acked = ack, map = M.view(s), items = copy(s.leaseItems and s.leaseItems[id] or {}) }
      end
      applyFrom = ack - first + 2
    end
    local applying = #m.entries - applyFrom + 1
    local maxEvents = lease.settings.values.journalMaxEvents or 1024
    if ack + applying > maxEvents then return fail("journal event limit") end
    local pending = {}
    for i = applyFrom, #m.entries do
      local entry = m.entries[i]
      local pos, name = mapTouch(entry)
      if pos then
        if entry.name ~= nil and entry.kind == "observe" and entry.name ~= false
          and (type(entry.name) ~= "string" or not entry.name:match("^[%w_]+:[%w_/.-]+$")) then
          return fail("invalid observation")
        end
        local key = mapKey(pos)
        pending[key] = pending[key] or M.baseCell(s, pos)
        pending[key] = copy(pending[key])
        M.claim(pending[key], lease, { pos = pos, name = name, at = entry.at, turtle = id, seq = entry.seq })
      end
    end
    local maxChunks = math.min(64, tonumber(cfg.maxChunks) or 64)
    local writes = {}
    for key, cell in pairs(pending) do
      local frame, rest = key:match("^([^|]+)|(.+)$")
      local dim, xs, ys, zs = rest:match("^(.+)|([^|]+)|([^|]+)|([^|]+)$")
      local pos = { frame = frame, dim = dim, x = tonumber(xs), y = tonumber(ys), z = tonumber(zs) }
      local resolved, unknown = M.outcome(cell)
      writes[#writes + 1] = { key = key, cell = cell, pos = pos, name = resolved, unknown = unknown }
    end
    local ok, why = roomFor(s, writes, maxChunks)
    if not ok then return fail(why) end
    s.leaseAck = s.leaseAck or {}
    s.leaseAck[id] = s.leaseAck[id] or {}
    s.leaseMap = s.leaseMap or {}
    for _, write in ipairs(writes) do
      local projected, err = project(s, write.pos, write.name, write.unknown, maxChunks)
      if not projected then return fail(err) end
      s.leaseMap[write.key] = write.cell
    end
    for i = applyFrom, #m.entries do noteItem(s, id, m.entries[i]) end
    s.leaseAck[id][lease.id] = ack + applying
    return { ok = true, acked = s.leaseAck[id][lease.id], map = M.view(s), items = copy(s.leaseItems and s.leaseItems[id] or {}) }
  end
  return fail("unknown lease operation")
end

local function storedLease(lease)
  return M.shape(lease) and type(lease.mac) == "string" and (lease.fenced == nil or type(lease.fenced) == "boolean")
    and (lease.recovery == nil or type(lease.recovery) == "table")
end

function M.validStored(s)
  if s.leases ~= nil then
    if type(s.leases) ~= "table" then return false end
    local n = 0
    for id, lease in pairs(s.leases) do
      n = n + 1
      if n > 32 or id ~= lease.id or not storedLease(lease) then return false end
    end
  end
  if s.leaseMap ~= nil then
    if type(s.leaseMap) ~= "table" then return false end
    local n = 0
    for key, cell in pairs(s.leaseMap) do
      n = n + 1
      if n > 8192 or type(key) ~= "string" or #key > 160 or type(cell) ~= "table" or cell.v ~= 1
        or not integer(cell.ruleRev, 0, 2147483647) or type(cell.baseUnknown) ~= "boolean"
        or (cell.baseName ~= false and (type(cell.baseName) ~= "string" or #cell.baseName > 128))
        or type(cell.sawStale) ~= "boolean" then return false end
    end
  end
  if s.leaseAck ~= nil then
    if type(s.leaseAck) ~= "table" then return false end
    for id, leases in pairs(s.leaseAck) do
      if not integer(id, 0, 2147483647) or type(leases) ~= "table" then return false end
      for lid, seq in pairs(leases) do
        if type(lid) ~= "string" or not integer(seq, 0, 2147483647) then return false end
      end
    end
  end
  if s.leaseItems ~= nil then
    if type(s.leaseItems) ~= "table" then return false end
    for id, items in pairs(s.leaseItems) do
      if not integer(id, 0, 2147483647) or type(items) ~= "table" then return false end
      for name, count in pairs(items) do
        if type(name) ~= "string" or not integer(count, 0, 1000000) then return false end
      end
    end
  end
  return true
end

return M
