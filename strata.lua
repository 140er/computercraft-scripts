-- Strata map (H4b2). Baseline plus exceptions. The flag defaults on.
--
-- Flag: pass { strata = false } to stay off. A missing key stays on.
-- Off: no new baseline, no predicted confidence, observed air and named cells remain.
-- On: overworld abs frames and yAbs frames can publish a frozen baseline.
-- Predicted cells never authorize a walk.
--
-- Disk bytes follow the plan's region array: 64 by 64 columns, one byte each,
-- 0 = unknown height, plus packed segments, boxes, and exception cells.
-- Per-section files, dirty saves, and schema migration stay in H4b1.
-- SHA-256 stays in H1. Journal storage stays in B1.

local Hash = dofile("lib/stubs/h4b2_h1.lua")
local Slots = dofile("lib/stubs/h4b2_h4b1.lua")
local Journal = dofile("lib/stubs/h4b2_b1.lua")

local M = { v = 2, FLAG = "strata", DEFAULT_ON = true }
local H = {}

M.PROTOTYPE_BYTES = 9460
M.MIN_COLUMNS = 32
M.MIN_CELLS = 256
M.MISPREDICT_MAX = 0.05
M.HOLDOUT_MIN = 4096
M.HOLDOUT_SECTIONS = 16

local FILLER = {
  ["minecraft:stone"] = true, ["minecraft:deepslate"] = true, ["minecraft:tuff"] = true,
  ["minecraft:andesite"] = true, ["minecraft:granite"] = true, ["minecraft:diorite"] = true,
  ["minecraft:dirt"] = true, ["minecraft:netherrack"] = true,
}
local DELTA = {
  [0] = { 0, 0, -1 }, { 1, 0, 0 }, { 0, 0, 1 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 },
}
local AIR = "minecraft:air"

local function int(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function nameOk(s)
  return type(s) == "string" and #s > 0 and #s <= 128 and s:match("^[%w_]+:[%w_/.-]+$") ~= nil
end

function M.filler(name)
  return FILLER[name] == true
end

function M.pos(p)
  return type(p) == "table" and type(p.frame) == "string" and #p.frame > 0 and #p.frame <= 80
    and not p.frame:find("|", 1, true) and (p.frame == "abs" or p.frame:sub(1, 2) == "f:")
    and type(p.yAbs) == "boolean"
    and type(p.dim) == "string" and p.dim:match("^[%w_]+:[%w_/.-]+$") ~= nil
    and int(p.x, -30000000, 30000000) and int(p.y, -2048, 2048) and int(p.z, -30000000, 30000000)
end

function M.canCalibrate(p)
  if not M.pos(p) or p.dim ~= "minecraft:overworld" or p.yAbs ~= true then return false end
  return p.frame == "abs" or p.frame:sub(1, 2) == "f:"
end

function M.sectionKey(p)
  return string.format("%s|%s|%d|%d|%d", p.frame, p.dim,
    math.floor(p.x / 16), math.floor(p.y / 16), math.floor(p.z / 16))
end

function M.regionKey(p)
  return string.format("%s|%s|%d|%d", p.frame, p.dim, math.floor(p.x / 64), math.floor(p.z / 64))
end

function M.cellIndex(p)
  return 1 + (p.x % 16) + 16 * (p.z % 16) + 256 * (p.y % 16)
end

function M.columnIndex(p)
  return 1 + (p.x % 64) + 64 * (p.z % 64)
end

function M.flagOn(value)
  if value == nil then return M.DEFAULT_ON end
  return value == true
end

function M.enabled(cfg)
  if type(cfg) ~= "table" then return M.DEFAULT_ON end
  return M.flagOn(cfg.strata)
end

function M.new(cfg)
  if type(cfg) ~= "table" then cfg = {} end
  return {
    v = 2,
    enabled = M.enabled(cfg),
    regions = {},
    sections = {},
    baselines = {},
    nextVer = {},
  }
end

function M.slot(key)
  return Slots.sectionSlot(key)
end

local function be16(n)
  n = math.floor(n) % 65536
  return string.char(math.floor(n / 256) % 256, n % 256)
end

local function be32(n)
  if n < 0 then n = n + 4294967296 end
  n = math.floor(n) % 4294967296
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256)
end

local function i16(n)
  if n < 0 then n = n + 65536 end
  return be16(n)
end

local function i32(n)
  if n < 0 then n = n + 4294967296 end
  return be32(n)
end

local function u64(n)
  if n < 0 then return nil end
  local hi = math.floor(n / 4294967296)
  local lo = n % 4294967296
  return be32(hi) .. be32(lo)
end

local function rd16(s, i)
  local a, b = s:byte(i, i + 1)
  if not a or not b then return nil end
  return a * 256 + b, i + 2
end

local function rd32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  if not d then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d, i + 4
end

local function rds16(s, i)
  local n, j = rd16(s, i)
  if not n then return nil end
  if n >= 32768 then n = n - 65536 end
  return n, j
end

local function rds32(s, i)
  local n, j = rd32(s, i)
  if not n then return nil end
  if n >= 2147483648 then n = n - 4294967296 end
  return n, j
end

local function rdu64(s, i)
  local hi, j = rd32(s, i)
  local lo, k = rd32(s, j or 1)
  if not hi or not lo then return nil end
  return hi * 4294967296 + lo, k
end

local function wstr(s)
  if type(s) ~= "string" or #s > 65535 then return nil end
  return be16(#s) .. s
end

local function rstr(s, i)
  local n, j = rd16(s, i)
  if not n or j + n - 1 > #s then return nil end
  return s:sub(j, j + n - 1), j + n
end

local function regionParts(key)
  local frame, dim, rx, rz = key:match("^([^|]+)|([^|]+)|(%-?%d+)|(%-?%d+)$")
  if not frame then return nil end
  return frame, dim, tonumber(rx), tonumber(rz)
end

local function atRegion(key, xl, y, zl)
  local frame, dim, rx, rz = regionParts(key)
  if not frame then return nil end
  return { frame = frame, yAbs = true, dim = dim, x = rx * 64 + xl, y = y, z = rz * 64 + zl }
end

local function ensureRegion(store, key, frame, dim)
  local r = store.regions[key]
  if r then return r end
  r = { v = 2, key = key, frame = frame, dim = dim, baseline = false, segments = {}, boxes = {}, strings = {} }
  store.regions[key] = r
  store.nextVer[key] = store.nextVer[key] or 0
  return r
end

local function ensureSection(store, p)
  local key = M.sectionKey(p)
  local s = store.sections[key]
  if s then return s end
  s = {
    v = 2, key = key, rev = 0, cells = {}, conflicts = {},
    observedAt = 0, base = false,
  }
  store.sections[key] = s
  return s
end

local function strId(region, text)
  for i, s in ipairs(region.strings) do if s == text then return i end end
  region.strings[#region.strings + 1] = text
  return #region.strings
end

local function sameEvidence(a, b)
  return a and b and a.by == b.by and a.lease == b.lease and a.seq == b.seq and a.rev == b.rev
end

local function stepDelta(d)
  local t = DELTA[d]
  if not t then return nil end
  return t[1], t[2], t[3]
end

function H.insideSegment(seg, x, y, z)
  local dx, dy, dz = stepDelta(seg.d)
  if not dx then return false end
  local kx, ky, kz = x - seg.x, y - seg.y, z - seg.z
  local k
  if dx ~= 0 then
    if ky ~= 0 or kz ~= 0 or kx % dx ~= 0 then return false end
    k = kx / dx
  elseif dy ~= 0 then
    if kx ~= 0 or kz ~= 0 or ky % dy ~= 0 then return false end
    k = ky / dy
  else
    if kx ~= 0 or ky ~= 0 or kz % dz ~= 0 then return false end
    k = kz / dz
  end
  return k % 1 == 0 and k >= 0 and k < seg.n
end

function H.insideBox(box, x, y, z)
  return x >= box.min.x and x <= box.max.x and y >= box.min.y and y <= box.max.y
    and z >= box.min.z and z <= box.max.z
end

local function splitSegment(seg)
  local dx, dy, dz = stepDelta(seg.d)
  local pieces, start, prev = {}, 0, nil
  for k = 0, seg.n - 1 do
    local p = { frame = seg.frame, dim = seg.dim, x = seg.x + dx * k, z = seg.z + dz * k }
    local rk = string.format("%s|%s|%d|%d", seg.frame, seg.dim, math.floor(p.x / 64), math.floor(p.z / 64))
    if prev and rk ~= prev then
      local s = seg.x + dx * start
      local y = seg.y + dy * start
      local z = seg.z + dz * start
      pieces[#pieces + 1] = { x = s, y = y, z = z, d = seg.d, n = k - start, region = prev }
      start = k
    end
    prev = rk
  end
  pieces[#pieces + 1] = {
    x = seg.x + dx * start, y = seg.y + dy * start, z = seg.z + dz * start,
    d = seg.d, n = seg.n - start, region = prev,
  }
  return pieces
end

local function shapeMeta(seg)
  return {
    by = seg.by or 0, lease = seg.lease or "", seq = seg.seq or 0, rev = seg.rev or 0,
    at = seg.at or 0, inspected = seg.inspected == true, base = seg.base or false,
    evidence = seg.evidence or { turtle = seg.by or 0, lease = seg.lease or "", seq = seg.seq or 0 },
  }
end

local function sameLine(a, b)
  if a.d ~= b.d or a.inspected ~= b.inspected or a.base ~= b.base then return false end
  if (a.by or 0) ~= (b.by or 0) or (a.lease or "") ~= (b.lease or "") then return false end
  local dx, dy, dz = stepDelta(a.d)
  if dx ~= 0 then return a.y == b.y and a.z == b.z end
  if dy ~= 0 then return a.x == b.x and a.z == b.z end
  return a.x == b.x and a.y == b.y
end

local function placeSegment(region, piece, meta)
  local seg = {
    x = piece.x, y = piece.y, z = piece.z, d = piece.d, n = piece.n,
    inspected = meta.inspected, by = meta.by, lease = meta.lease, seq = meta.seq,
    rev = meta.rev, at = meta.at, base = meta.base, evidence = meta.evidence,
  }
  local dx, dy, dz = stepDelta(seg.d)
  for _, old in ipairs(region.segments) do
    if old.x == seg.x and old.y == seg.y and old.z == seg.z and old.d == seg.d and old.n == seg.n
      and sameEvidence(old, seg) then
      return old
    end
    if sameLine(old, seg) then
      local function kOf(s)
        if dx ~= 0 then return (s.x - old.x) / dx end
        if dy ~= 0 then return (s.y - old.y) / dy end
        return (s.z - old.z) / dz
      end
      local a0, a1 = 0, old.n - 1
      local b0, b1 = kOf(seg), kOf(seg) + seg.n - 1
      if math.max(a0, b0) <= math.min(a1, b1) + 1 then
        local lo, hi = math.min(a0, b0), math.max(a1, b1)
        old.x = old.x + dx * lo
        old.y = old.y + dy * lo
        old.z = old.z + dz * lo
        old.n = hi - lo + 1
        if (seg.seq or 0) > (old.seq or 0) then
          old.seq = seg.seq
          old.evidence = seg.evidence
        end
        return old
      end
    end
  end
  region.segments[#region.segments + 1] = seg
  return seg
end

local function checkSeg(seg)
  if type(seg) ~= "table" or not int(seg.d, 0, 5) or not int(seg.n, 1, 4096) then return false end
  if not int(seg.x, -30000000, 30000000) or not int(seg.y, -2048, 2048) or not int(seg.z, -30000000, 30000000) then
    return false
  end
  if type(seg.frame) ~= "string" or type(seg.dim) ~= "string" then return false end
  return true
end

function M.addSegment(store, seg)
  if type(store) ~= "table" or not checkSeg(seg) then return nil, "segment" end
  local meta = shapeMeta(seg)
  local placed = {}
  for _, piece in ipairs(splitSegment(seg)) do
    local probe = { frame = seg.frame, dim = seg.dim, x = piece.x, y = piece.y, z = piece.z, yAbs = seg.yAbs ~= false }
    local region = ensureRegion(store, piece.region, seg.frame, seg.dim)
    placed[#placed + 1] = placeSegment(region, piece, meta)
    ensureSection(store, probe)
  end
  return placed
end

function M.addBox(store, box)
  if type(store) ~= "table" or type(box) ~= "table" or box.kind ~= "air" then return nil, "box" end
  if type(box.frame) ~= "string" or type(box.dim) ~= "string" then return nil, "box" end
  local a, b = box.min, box.max
  if not a or not b or not int(a.x, -30000000, 30000000) or not int(b.x, a.x, 30000000) then return nil, "box" end
  if not int(a.y, -2048, 2048) or not int(b.y, a.y, 2048) or not int(a.z, -30000000, 30000000) or not int(b.z, a.z, 30000000) then
    return nil, "box"
  end
  local meta = shapeMeta(box)
  local made = {}
  local x0 = math.floor(a.x / 64)
  local x1 = math.floor(b.x / 64)
  local z0 = math.floor(a.z / 64)
  local z1 = math.floor(b.z / 64)
  for rx = x0, x1 do
    for rz = z0, z1 do
      local minx = math.max(a.x, rx * 64)
      local maxx = math.min(b.x, rx * 64 + 63)
      local minz = math.max(a.z, rz * 64)
      local maxz = math.min(b.z, rz * 64 + 63)
      local key = string.format("%s|%s|%d|%d", box.frame, box.dim, rx, rz)
      local region = ensureRegion(store, key, box.frame, box.dim)
      local item = {
        min = { x = minx, y = a.y, z = minz }, max = { x = maxx, y = b.y, z = maxz },
        kind = "air", inspected = meta.inspected, by = meta.by, lease = meta.lease,
        seq = meta.seq, rev = meta.rev, at = meta.at, base = meta.base, evidence = meta.evidence,
      }
      local dup = false
      for _, old in ipairs(region.boxes) do
        if old.min.x == item.min.x and old.min.y == item.min.y and old.min.z == item.min.z
          and old.max.x == item.max.x and old.max.y == item.max.y and old.max.z == item.max.z
          and sameEvidence(old, item) then dup = true break end
      end
      if not dup then region.boxes[#region.boxes + 1] = item end
      made[#made + 1] = item
    end
  end
  return made
end

function M.observe(store, pos, block, meta)
  if not M.pos(pos) or not nameOk(block) then return nil, "observation" end
  meta = meta or {}
  local section = ensureSection(store, pos)
  local region = ensureRegion(store, M.regionKey(pos), pos.frame, pos.dim)
  local index = M.cellIndex(pos)
  if section.conflicts[index] then return nil, "conflict" end
  section.cells[index] = { x = pos.x, y = pos.y, z = pos.z, name = block }
  if int(meta.at, 0, 9007199254740991) and meta.at > section.observedAt then section.observedAt = meta.at end
  if int(meta.rev, 0, 2147483647) then section.rev = math.max(section.rev, meta.rev) end
  section.region = region.key
  return true
end

function M.noteConflict(store, pos, rev)
  if not M.pos(pos) or not int(rev, 0, 2147483647) then return nil, "conflict" end
  local section = ensureSection(store, pos)
  section.conflicts[M.cellIndex(pos)] = rev
  section.cells[M.cellIndex(pos)] = nil
  return true
end

local function columnSurface(samples)
  local cols = {}
  for _, s in ipairs(samples) do
    local k = s.x .. ":" .. s.z
    local col = cols[k]
    if not col then
      col = { x = s.x, z = s.z, cells = {} }
      cols[k] = col
    end
    col.cells[s.y] = s.name
  end
  local surfaces = {}
  for _, col in pairs(cols) do
    local best
    for y, name in pairs(col.cells) do
      if name ~= AIR and col.cells[y + 1] == AIR and (not best or y > best) then best = y end
    end
    if best then surfaces[#surfaces + 1] = { x = col.x, z = col.z, y = best, cells = col.cells } end
  end
  return surfaces
end

local function lowerMedian(values)
  if #values == 0 then return nil end
  table.sort(values)
  return values[math.floor((#values + 1) / 2)]
end

local function predictColumn(base, y, surfaceY)
  if not surfaceY then return nil end
  if y > surfaceY then return AIR end
  local dirt = base.fillerTo.dirt
  if y >= surfaceY - dirt and y <= surfaceY then return "minecraft:dirt" end
  if y < base.blendLo then return "minecraft:deepslate" end
  if y > base.blendHi then return "minecraft:stone" end
  local mid = math.ceil((base.blendLo + base.blendHi) / 2)
  if y < mid then return "minecraft:deepslate" end
  return "minecraft:stone"
end

function M.predictName(base, x, y, z)
  if type(base) ~= "table" or base.frozen ~= true then return nil end
  local col = 1 + (x % 64) + 64 * (z % 64)
  return predictColumn(base, y, base.surface[col])
end

local function buildBaseline(samples, now, ver)
  local frame, dim, yAbs
  local seen = {}
  local list = {}
  for _, s in ipairs(samples) do
    if not M.canCalibrate(s) or not nameOk(s.name) then return nil, "sample" end
    if not frame then frame, dim, yAbs = s.frame, s.dim, s.yAbs end
    if s.frame ~= frame or s.dim ~= dim or s.yAbs ~= yAbs then return nil, "frame" end
    local id = s.x .. ":" .. s.y .. ":" .. s.z
    if not seen[id] then
      seen[id] = s
      list[#list + 1] = s
    end
  end
  if not frame then return nil, "sample" end
  local surfaces = columnSurface(list)
  if #surfaces < M.MIN_COLUMNS then return nil, "columns" end
  local below = {}
  local dirtCounts, stoneMin, deepMax = {}, nil, nil
  local sawStone, sawDeep = false, false
  for _, col in ipairs(surfaces) do
    local n, y = 0, col.y - 1
    while n < 64 and col.cells[y] == "minecraft:dirt" do n, y = n + 1, y - 1 end
    dirtCounts[#dirtCounts + 1] = n
  end
  for _, s in ipairs(list) do
    local surfaceY
    for _, col in ipairs(surfaces) do
      if col.x == s.x and col.z == s.z then surfaceY = col.y break end
    end
    if surfaceY and s.y <= surfaceY then below[s.x .. ":" .. s.y .. ":" .. s.z] = true end
    if s.name == "minecraft:stone" then
      sawStone = true
      if not stoneMin or s.y < stoneMin then stoneMin = s.y end
    elseif s.name == "minecraft:deepslate" then
      sawDeep = true
      if not deepMax or s.y > deepMax then deepMax = s.y end
    end
  end
  local sampleCount = 0
  for _ in pairs(below) do sampleCount = sampleCount + 1 end
  if sampleCount < M.MIN_CELLS or not sawStone or not sawDeep then return nil, "samples" end
  local blendLo, blendHi = stoneMin, deepMax
  if blendLo > blendHi then
    local mid = math.floor((blendLo + blendHi) / 2)
    blendLo, blendHi = mid, mid
  end
  local origin = surfaces[1].y
  for i = 2, #surfaces do if surfaces[i].y < origin then origin = surfaces[i].y end end
  local surface = {}
  for _, col in ipairs(surfaces) do
    local idx = 1 + (col.x % 64) + 64 * (col.z % 64)
    local delta = col.y - origin
    if delta < 0 or delta > 254 then return nil, "height" end
    surface[idx] = col.y
  end
  local base = {
    ver = ver, frozen = true, surface = surface, originY = origin,
    fillerTo = { dirt = lowerMedian(dirtCounts) }, blendLo = blendLo, blendHi = blendHi,
    samples = sampleCount, calibratedAt = now or 0, frame = frame, dim = dim,
  }
  return base
end

local function pinHash(base)
  local raw = Hash.digest(string.format("baseline|%d|%d|%d|%d|%d|%d",
    base.ver, base.originY, base.fillerTo.dirt, base.blendLo, base.blendHi, base.samples))
  base.hash = Hash.hex(raw)
  base.rawHash = raw
  return base
end

function M.calibrate(store, regionKey, samples, now)
  if type(store) ~= "table" or not store.enabled then return nil, "disabled" end
  if type(regionKey) ~= "string" or type(samples) ~= "table" then return nil, "region" end
  local ver = (store.nextVer[regionKey] or 0) + 1
  local base, err = buildBaseline(samples, now or 0, ver)
  if not base then return nil, err end
  local frame, dim = regionParts(regionKey)
  if not frame or frame ~= base.frame or dim ~= base.dim then return nil, "region" end
  -- Samples must sit in this region.
  local rx = tonumber(regionKey:match("|(%-?%d+)|%-?%d+$"))
  local rz = tonumber(regionKey:match("|(%-?%d+)$"))
  for _, s in ipairs(samples) do
    if math.floor(s.x / 64) ~= rx or math.floor(s.z / 64) ~= rz then return nil, "region" end
  end
  pinHash(base)
  local region = ensureRegion(store, regionKey, frame, dim)
  local previous = region.baseline
  region.baseline = base
  store.baselines[base.hash] = base
  store.nextVer[regionKey] = ver
  for _, seg in ipairs(region.segments) do if seg.base == false then seg.base = ver end end
  for _, box in ipairs(region.boxes) do if box.base == false then box.base = ver end end
  return base, previous
end

function M.recalibrate(store, regionKey, samples, now)
  if type(store) ~= "table" or not store.enabled then return nil, "disabled" end
  local before = M.observedList(store)
  local region = store.regions[regionKey]
  local old = region and region.baseline
  local base, err = M.calibrate(store, regionKey, samples, now)
  if not base then return nil, err end
  if old then store.baselines[old.hash] = old end
  local after = M.observedList(store)
  if #before ~= #after then
    region.baseline = old
    store.nextVer[regionKey] = old and old.ver or 0
    return nil, "roundtrip"
  end
  for i = 1, #before do
    if before[i] ~= after[i] then
      region.baseline = old
      store.nextVer[regionKey] = old and old.ver or 0
      return nil, "roundtrip"
    end
  end
  return base, old
end

local function baselineFor(store, region, ver)
  if not region or not region.baseline then return nil end
  if ver == nil or ver == false or region.baseline.ver == ver then return region.baseline end
  for _, base in pairs(store.baselines) do
    if base.ver == ver and base.frame == region.frame and base.dim == region.dim then return base end
  end
  return nil
end

local function explicitAt(store, p)
  local section = store.sections[M.sectionKey(p)]
  if not section then return nil end
  local index = M.cellIndex(p)
  if section.conflicts[index] then return "conflict", section.conflicts[index] end
  local cell = section.cells[index]
  if cell then return "cell", cell.name end
  return nil
end

local function covered(store, p)
  local key = M.regionKey(p)
  local region = store.regions[key]
  if not region then return nil end
  for _, seg in ipairs(region.segments) do
    if H.insideSegment(seg, p.x, p.y, p.z) then return "segment", seg end
  end
  for _, box in ipairs(region.boxes) do
    if H.insideBox(box, p.x, p.y, p.z) then return "box", box end
  end
  for _, seg in ipairs(region.segments) do
    if seg.inspected then
      for d = 0, 5 do
        local dx, dy, dz = stepDelta(d)
        if H.insideSegment(seg, p.x - dx, p.y - dy, p.z - dz) then return "face", seg end
      end
    end
  end
  for _, box in ipairs(region.boxes) do
    if box.inspected then
      for d = 0, 5 do
        local dx, dy, dz = stepDelta(d)
        local x, y, z = p.x - dx, p.y - dy, p.z - dz
        if H.insideBox(box, x, y, z) and not H.insideBox(box, p.x, p.y, p.z) then return "face", box end
      end
    end
  end
  return nil
end

function M.lookup(store, pos)
  if not M.pos(pos) then return nil, nil, "pos" end
  local kind, extra = explicitAt(store, pos)
  if kind == "conflict" then return "unknown", nil end
  if kind == "cell" then return "observed", extra end
  local cover, shape = covered(store, pos)
  if cover == "segment" or cover == "box" then return "observed", AIR end
  if cover == "face" then
    local region = store.regions[M.regionKey(pos)]
    local base = baselineFor(store, region, shape.base)
    local predicted = base and M.predictName(base, pos.x, pos.y, pos.z)
    if predicted then return "observed", predicted end
    return "unknown", nil
  end
  if not store.enabled then return "unknown", nil end
  local region = store.regions[M.regionKey(pos)]
  local base = region and region.baseline
  if base then
    local name = M.predictName(base, pos.x, pos.y, pos.z)
    if name then return "predicted", name end
  end
  return "unknown", nil
end

function M.allowsWalk(store, pos)
  local conf, name = M.lookup(store, pos)
  return conf == "observed" and name == AIR
end

function M.estimateCost(store, pos)
  local conf, name = M.lookup(store, pos)
  if conf == "unknown" then return nil end
  if conf == "predicted" then return name == AIR and 4 or 8 end
  return name == AIR and 1 or 2
end

function M.wireMark(store, pos)
  local conf, name = M.lookup(store, pos)
  if conf ~= "observed" then return nil end
  local region = store.regions[M.regionKey(pos)]
  local base = region and region.baseline
  if store.enabled and base and M.predictName(base, pos.x, pos.y, pos.z) == name then return "=" end
  return name
end

local function visitShapeCells(shape, kind, fn)
  if kind == "segment" then
    local dx, dy, dz = stepDelta(shape.d)
    for k = 0, shape.n - 1 do fn(shape.x + dx * k, shape.y + dy * k, shape.z + dz * k, AIR) end
  else
    for x = shape.min.x, shape.max.x do
      for y = shape.min.y, shape.max.y do
        for z = shape.min.z, shape.max.z do fn(x, y, z, AIR) end
      end
    end
  end
end

function M.observedList(store)
  local seen = {}
  local function put(frame, dim, x, y, z, name)
    seen[frame .. "|" .. dim .. "|" .. x .. "|" .. y .. "|" .. z] = name
  end
  for _, region in pairs(store.regions) do
    for _, seg in ipairs(region.segments) do
      visitShapeCells(seg, "segment", function(x, y, z, name)
        put(region.frame, region.dim, x, y, z, name)
      end)
    end
    for _, box in ipairs(region.boxes) do
      visitShapeCells(box, "box", function(x, y, z, name)
        put(region.frame, region.dim, x, y, z, name)
      end)
    end
  end
  for _, section in pairs(store.sections) do
    local frame, dim = section.key:match("^([^|]+)|([^|]+)|")
    if frame then
      for _, cell in pairs(section.cells) do
        put(frame, dim, cell.x, cell.y, cell.z, cell.name)
      end
    end
  end
  for _, region in pairs(store.regions) do
    local function face(x, y, z)
      local p = { frame = region.frame, yAbs = true, dim = region.dim, x = x, y = y, z = z }
      local key = region.frame .. "|" .. region.dim .. "|" .. x .. "|" .. y .. "|" .. z
      if seen[key] then return end
      local conf, name = M.lookup(store, p)
      if conf == "observed" and name then seen[key] = name end
    end
    for _, seg in ipairs(region.segments) do
      if seg.inspected then
        local dx, dy, dz = stepDelta(seg.d)
        for k = 0, seg.n - 1 do
          local x, y, z = seg.x + dx * k, seg.y + dy * k, seg.z + dz * k
          for d = 0, 5 do
            local fx, fy, fz = stepDelta(d)
            if not H.insideSegment(seg, x + fx, y + fy, z + fz) then face(x + fx, y + fy, z + fz) end
          end
        end
      end
    end
    for _, box in ipairs(region.boxes) do
      if box.inspected then
        for x = box.min.x, box.max.x do
          for y = box.min.y, box.max.y do
            face(x, y, box.min.z - 1)
            face(x, y, box.max.z + 1)
          end
        end
        for z = box.min.z, box.max.z do
          for y = box.min.y, box.max.y do
            face(box.min.x - 1, y, z)
            face(box.max.x + 1, y, z)
          end
        end
        for x = box.min.x, box.max.x do
          for z = box.min.z, box.max.z do
            face(x, box.min.y - 1, z)
            face(x, box.max.y + 1, z)
          end
        end
      end
    end
  end
  local list = {}
  for key, name in pairs(seen) do
    list[#list + 1] = key .. "|" .. name
  end
  table.sort(list)
  return list
end

function M.ingestMining(store, task, observations)
  if type(task) ~= "table" or type(task.min) ~= "table" or type(task.max) ~= "table" then return nil, "task" end
  if not int(task.progress, 0, 4096) or task.progress < 1 then return nil, "progress" end
  local min, max = task.min, task.max
  if min.dim ~= max.dim or min.x > max.x or min.y > max.y or min.z > max.z then return nil, "task" end
  local z1 = min.z + task.progress - 1
  if z1 > max.z then return nil, "progress" end
  local proposal = {
    installed = false, d = 2, x = min.x, y = min.y, z = min.z,
    n = task.progress, frame = task.frame, dim = min.dim,
  }
  if observations == nil then return proposal end
  if type(observations) ~= "table" then return nil, "observations" end
  local have = {}
  for _, c in ipairs(observations) do
    if type(c) == "table" and c.name == AIR then have[c.x .. ":" .. c.y .. ":" .. c.z] = true end
  end
  for x = min.x, max.x do
    for y = min.y, max.y do
      for z = min.z, z1 do
        if not have[x .. ":" .. y .. ":" .. z] then return nil, "unobserved" end
      end
    end
  end
  local frame = task.frame or "abs"
  if max.x == min.x and max.y == min.y then
    local placed = M.addSegment(store, {
      frame = frame, dim = min.dim, yAbs = task.yAbs ~= false,
      x = min.x, y = min.y, z = min.z, d = 2, n = task.progress,
      inspected = false, by = task.by, lease = task.lease, seq = task.seq, rev = task.rev, at = task.at,
    })
    if not placed then return nil, "segment" end
  else
    local placed = M.addBox(store, {
      frame = frame, dim = min.dim, kind = "air",
      min = { x = min.x, y = min.y, z = min.z }, max = { x = max.x, y = max.y, z = z1 },
      inspected = false, by = task.by, lease = task.lease, seq = task.seq, rev = task.rev, at = task.at,
    })
    if not placed then return nil, "box" end
  end
  proposal.installed = true
  return proposal
end

local function lineOf(a, b)
  local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
  local n = math.abs(dx) + math.abs(dy) + math.abs(dz)
  if n < 1 or (dx ~= 0 and dy ~= 0) or (dx ~= 0 and dz ~= 0) or (dy ~= 0 and dz ~= 0) then return nil end
  local d
  if dx > 0 then d = 1 elseif dx < 0 then d = 3
  elseif dy > 0 then d = 4 elseif dy < 0 then d = 5
  elseif dz > 0 then d = 2 else d = 0 end
  return d, n
end

function M.ingestMove(store, move)
  if type(move) ~= "table" or move.phase ~= "commit" and move.phase ~= "done" then return nil, "phase" end
  if not M.pos(move.from) or not M.pos(move.to) then return nil, "pose" end
  if move.from.frame ~= move.to.frame or move.from.dim ~= move.to.dim then return nil, "frame" end
  local d, n = lineOf(move.from, move.to)
  if not d then return nil, "straight" end
  return M.addSegment(store, {
    frame = move.from.frame, dim = move.from.dim, yAbs = move.from.yAbs,
    x = move.from.x, y = move.from.y, z = move.from.z, d = d, n = n + 1,
    inspected = false, by = move.by, lease = move.lease, seq = move.seq, rev = move.rev, at = move.at,
  })
end

function M.ingestJournal(store, entry)
  if not Journal.isEntry(entry) then return nil, "journal" end
  if not Journal.isDone(entry) then return true, "pending" end
  if entry.kind == "move" or entry.kind == "dig" then
    return M.ingestMove(store, {
      phase = "done", from = entry.from, to = entry.to, by = entry.by or (entry.evidence and entry.evidence.turtle),
      lease = entry.lease, seq = entry.seq, rev = entry.rev, at = entry.at,
    })
  elseif entry.kind == "observe" then
    local pos = entry.cell or entry.to
    return M.observe(store, pos, entry.name, entry)
  end
  return true, "ignored"
end

function M.misprediction(predicted, actual)
  if predicted == nil or actual == nil then return true end
  if predicted == actual then return false end
  if actual == AIR or predicted == AIR then return true end
  if actual == "minecraft:water" or actual == "minecraft:lava" then return true end
  if actual == "minecraft:gravel" or actual == "minecraft:sand" then return true end
  if actual:match("_ore$") or actual == "minecraft:ancient_debris" then return true end
  if FILLER[predicted] and FILLER[actual] then return false end
  return true
end

function M.score(base, held)
  if type(held) ~= "table" or #held == 0 then return nil, "holdout" end
  local bad, sections = 0, {}
  for _, s in ipairs(held) do
    local pred = M.predictName(base, s.x, s.y, s.z)
    if M.misprediction(pred, s.name) then bad = bad + 1 end
    sections[math.floor(s.x / 16) .. ":" .. math.floor(s.y / 16) .. ":" .. math.floor(s.z / 16)] = true
  end
  local nsec = 0
  for _ in pairs(sections) do nsec = nsec + 1 end
  return bad / #held, nsec, #held
end

function M.evaluateDefault(report)
  local out = { enable = false, eligible = false, why = "flag stays off" }
  if type(report) ~= "table" then out.why = "no gate B report" return out end
  if report.predictedWalks ~= 0 then out.why = "predicted walk" return out end
  if type(report.h4b1Bytes) ~= "number" or type(report.h4b2Bytes) ~= "number" then
    out.why = "missing bytes" return out
  end
  if report.h4b2Bytes >= report.h4b1Bytes then out.why = "not smaller than h4b1" return out end
  if type(report.heldOut) ~= "number" or report.heldOut < M.HOLDOUT_MIN then out.why = "holdout" return out end
  if type(report.sections) ~= "number" or report.sections < M.HOLDOUT_SECTIONS then out.why = "sections" return out end
  if type(report.misprediction) ~= "number" or report.misprediction >= M.MISPREDICT_MAX then
    out.why = "misprediction" return out
  end
  out.eligible = true
  out.why = "gate B would allow a later default; this build stays off"
  return out
end

local function encodeBaseline(base)
  local origin = base.originY
  local bytes = {}
  for i = 1, 4096 do
    local y = base.surface[i]
    if y == nil then bytes[i] = string.char(0)
    else
      local d = y - origin
      bytes[i] = string.char(d + 1)
    end
  end
  return table.concat(bytes)
end

local function encodeRegion(store, region)
  local base = region.baseline
  local function evid(item)
    local text = string.format("%d|%s|%d|%d|%d", item.by or 0, item.lease or "", item.seq or 0, item.rev or 0, item.at or 0)
    return strId(region, text)
  end
  local exc = {}
  local rx = tonumber(region.key:match("|(%-?%d+)|%-?%d+$"))
  local rz = tonumber(region.key:match("|(%-?%d+)$"))
  for _, section in pairs(store.sections) do
    for _, cell in pairs(section.cells) do
      if math.floor(cell.x / 64) == rx and math.floor(cell.z / 64) == rz then
        exc[#exc + 1] = cell
      end
    end
  end
  table.sort(exc, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    if a.y ~= b.y then return a.y < b.y end
    return a.z < b.z
  end)
  for _, seg in ipairs(region.segments) do evid(seg) end
  for _, box in ipairs(region.boxes) do evid(box) end
  for _, cell in ipairs(exc) do strId(region, cell.name) end
  local parts = { wstr(region.key) }
  if not base then parts[#parts + 1] = string.char(0)
  else
    parts[#parts + 1] = string.char(1)
    parts[#parts + 1] = be16(base.ver) .. string.char(base.frozen and 1 or 0) .. i16(base.originY)
    parts[#parts + 1] = string.char(base.fillerTo.dirt) .. i16(base.blendLo) .. i16(base.blendHi)
    parts[#parts + 1] = be32(base.samples) .. u64(base.calibratedAt) .. base.rawHash .. encodeBaseline(base)
  end
  parts[#parts + 1] = be16(#region.strings)
  for _, s in ipairs(region.strings) do parts[#parts + 1] = wstr(s) end
  parts[#parts + 1] = be16(#region.segments)
  for _, seg in ipairs(region.segments) do
    local xl, zl = seg.x % 64, seg.z % 64
    local flags = seg.inspected and 1 or 0
    local bver = seg.base == false and 65535 or seg.base
    parts[#parts + 1] = string.char(xl, zl) .. i16(seg.y) .. string.char(seg.d) .. be16(seg.n)
      .. string.char(flags) .. be16(evid(seg)) .. be16(bver)
  end
  parts[#parts + 1] = be16(#region.boxes)
  for _, box in ipairs(region.boxes) do
    local flags = box.inspected and 1 or 0
    local bver = box.base == false and 65535 or box.base
    parts[#parts + 1] = string.char(box.min.x % 64, box.min.z % 64, box.max.x % 64, box.max.z % 64)
      .. i16(box.min.y) .. i16(box.max.y) .. string.char(flags) .. be16(evid(box)) .. be16(bver)
  end
  parts[#parts + 1] = be16(#exc)
  for _, cell in ipairs(exc) do
    parts[#parts + 1] = string.char(cell.x % 64, cell.z % 64) .. i16(cell.y) .. be16(strId(region, cell.name))
  end
  local body = table.concat(parts)
  local digest = Hash.digest("cc-h4/region/2" .. body)
  return "H4R" .. string.char(2) .. be32(#body) .. body .. digest
end

function M.encode(store)
  local keys = {}
  for key in pairs(store.regions) do keys[#keys + 1] = key end
  table.sort(keys)
  local parts = { "H4D" .. string.char(2) .. string.char(store.enabled and 1 or 0) .. be16(#keys) }
  for _, key in ipairs(keys) do parts[#parts + 1] = encodeRegion(store, store.regions[key]) end
  local extra = {}
  for hash, base in pairs(store.baselines) do
    local live = false
    for _, region in pairs(store.regions) do
      if region.baseline and region.baseline.hash == hash then live = true break end
    end
    if not live then extra[#extra + 1] = base end
  end
  table.sort(extra, function(a, b) return a.hash < b.hash end)
  parts[#parts + 1] = be16(#extra)
  for _, base in ipairs(extra) do
    local body = be16(base.ver) .. i16(base.originY) .. string.char(base.fillerTo.dirt)
      .. i16(base.blendLo) .. i16(base.blendHi) .. be32(base.samples) .. u64(base.calibratedAt)
      .. base.rawHash .. encodeBaseline(base) .. wstr(base.frame) .. wstr(base.dim)
    parts[#parts + 1] = be32(#body) .. body
  end
  return table.concat(parts)
end

function M.bytes(store)
  return #M.encode(store)
end

local function decodeBaselineBody(s, i, verForced)
  local ver, j = rd16(s, i)
  if verForced then ver, j = verForced, i end
  local origin, j2 = rds16(s, j)
  local dirt = s:byte(j2 or 1)
  if not origin or not dirt then return nil end
  j = j2 + 1
  local lo, j3 = rds16(s, j)
  local hi, j4 = rds16(s, j3 or 1)
  local samples, j5 = rd32(s, j4 or 1)
  local at, j6 = rdu64(s, j5 or 1)
  if not hi or not samples or not at or j6 + 31 > #s then return nil end
  local raw = s:sub(j6, j6 + 31)
  j = j6 + 32
  if j + 4095 > #s then return nil end
  local surface, packed = {}, s:sub(j, j + 4095)
  for c = 1, 4096 do
    local b = packed:byte(c)
    if b ~= 0 then surface[c] = origin + b - 1 end
  end
  local base = {
    ver = ver, frozen = true, surface = surface, originY = origin,
    fillerTo = { dirt = dirt }, blendLo = lo, blendHi = hi,
    samples = samples, calibratedAt = at, rawHash = raw, hash = Hash.hex(raw),
  }
  return base, j + 4096
end

local function parseEvidence(text)
  local by, lease, seq, rev, at = text:match("^(%d+)|(.*)|(%d+)|(%d+)|(%d+)$")
  if not by then return { by = 0, lease = "", seq = 0, rev = 0, at = 0 } end
  return { by = tonumber(by), lease = lease, seq = tonumber(seq), rev = tonumber(rev), at = tonumber(at) }
end

local function decodeRegion(store, file)
  if file:sub(1, 3) ~= "H4R" or file:byte(4) ~= 2 then return nil, "region" end
  local len, i = rd32(file, 5)
  if not len or 9 + len + 31 > #file then return nil, "region" end
  local body = file:sub(9, 8 + len)
  local key, j = rstr(body, 1)
  if not key then return nil, "region" end
  local frame, dim, rx, rz = regionParts(key)
  if not frame then return nil, "region" end
  local region = ensureRegion(store, key, frame, dim)
  local flag = body:byte(j)
  j = j + 1
  if flag == 1 then
    local ver, j1 = rd16(body, j)
    local frozen = body:byte(j1 or 1)
    if not ver or not frozen then return nil, "baseline" end
    local base, j2 = decodeBaselineBody(body, j1 + 1, ver)
    if not base or frozen ~= 1 then return nil, "baseline" end
    base.frame, base.dim = frame, dim
    region.baseline = base
    store.baselines[base.hash] = base
    store.nextVer[key] = math.max(store.nextVer[key] or 0, ver)
    j = j2
  elseif flag ~= 0 then return nil, "baseline" end
  local nstr, j3 = rd16(body, j)
  if not nstr then return nil, "strings" end
  j = j3
  region.strings = {}
  for _ = 1, nstr do
    local text, jn = rstr(body, j)
    if not text then return nil, "strings" end
    region.strings[#region.strings + 1] = text
    j = jn
  end
  local function evid(id)
    local text = region.strings[id] or ""
    return parseEvidence(text)
  end
  local nseg, j4 = rd16(body, j)
  if not nseg then return nil, "segments" end
  j = j4
  for _ = 1, nseg do
    local xl, zl = body:byte(j, j + 1)
    local y, jy = rds16(body, j + 2)
    local d = body:byte((jy or 1))
    local n, jn = rd16(body, (jy or 1) + 1)
    local flags = body:byte((jn or 1))
    local eid, je = rd16(body, (jn or 1) + 1)
    local bver, jb = rd16(body, je or 1)
    if not xl or not y or not d or not n or not flags or not eid or not bver then return nil, "segment" end
    local ev = evid(eid)
    region.segments[#region.segments + 1] = {
      x = rx * 64 + xl, y = y, z = rz * 64 + zl, d = d, n = n,
      inspected = flags % 2 == 1, by = ev.by, lease = ev.lease, seq = ev.seq, rev = ev.rev, at = ev.at,
      base = bver == 65535 and false or bver, evidence = { turtle = ev.by, lease = ev.lease, seq = ev.seq },
    }
    j = jb
  end
  local nbox, j5 = rd16(body, j)
  if not nbox then return nil, "boxes" end
  j = j5
  for _ = 1, nbox do
    local x0, z0, x1, z1 = body:byte(j, j + 3)
    local y0, jy = rds16(body, j + 4)
    local y1, jy2 = rds16(body, jy or 1)
    local flags = body:byte(jy2 or 1)
    local eid, je = rd16(body, (jy2 or 1) + 1)
    local bver, jb = rd16(body, je or 1)
    if not x0 or not y0 or not y1 or not flags or not eid or not bver then return nil, "box" end
    local ev = evid(eid)
    region.boxes[#region.boxes + 1] = {
      min = { x = rx * 64 + x0, y = y0, z = rz * 64 + z0 },
      max = { x = rx * 64 + x1, y = y1, z = rz * 64 + z1 },
      kind = "air", inspected = flags % 2 == 1, by = ev.by, lease = ev.lease, seq = ev.seq,
      rev = ev.rev, at = ev.at, base = bver == 65535 and false or bver,
      evidence = { turtle = ev.by, lease = ev.lease, seq = ev.seq },
    }
    j = jb
  end
  local nexc, j6 = rd16(body, j)
  if not nexc then return nil, "cells" end
  j = j6
  for _ = 1, nexc do
    local xl, zl = body:byte(j, j + 1)
    local y, jy = rds16(body, j + 2)
    local nid, jn = rd16(body, jy or 1)
    if not xl or not y or not nid or not region.strings[nid] then return nil, "cell" end
    local pos = atRegion(key, xl, y, zl)
    M.observe(store, pos, region.strings[nid], {})
    j = jn
  end
  if j ~= #body + 1 then return nil, "tail" end
  return true
end

function M.decode(blob)
  if type(blob) ~= "string" or blob:sub(1, 3) ~= "H4D" or blob:byte(4) ~= 2 then return nil, "version" end
  local store = M.new({ strata = blob:byte(5) == 1 })
  local n, i = rd16(blob, 6)
  if not n then return nil, "regions" end
  for _ = 1, n do
    if blob:sub(i, i + 2) ~= "H4R" then return nil, "region" end
    local len = rd32(blob, i + 4)
    if not len then return nil, "region" end
    local fileLen = 8 + len + 32
    local ok, err = decodeRegion(store, blob:sub(i, i + fileLen - 1))
    if not ok then return nil, err end
    i = i + fileLen
  end
  local extra, j = rd16(blob, i)
  if not extra then return nil, "baselines" end
  i = j
  for _ = 1, extra do
    local len, j1 = rd32(blob, i)
    if not len or i + 3 + len > #blob then return nil, "baselines" end
    local body = blob:sub(j1, j1 + len - 1)
    local ver, jb = rd16(body, 1)
    local base, j2 = decodeBaselineBody(body, jb, ver)
    if not base then return nil, "baselines" end
    local frame, j3 = rstr(body, j2)
    local dim, j4 = rstr(body, j3 or 1)
    if not frame or not dim or j4 ~= #body + 1 then return nil, "baselines" end
    base.frame, base.dim = frame, dim
    store.baselines[base.hash] = base
    i = j1 + len
  end
  if i ~= #blob + 1 then return nil, "tail" end
  return store
end

-- RLE (rle/1) and sparse (sparse/1) cell codecs. H4b2 reads both.
-- H4b1's writer is the stubbed chunk store; this is the reader and the flagged writer.

local function paletteIndex(palette, name)
  for i, entry in ipairs(palette) do if entry == name then return i end end
  return nil
end

function M.encodeCells(codec, palette, cells)
  if codec == "sparse/1" then
    local idxs = {}
    for index in pairs(cells) do idxs[#idxs + 1] = index end
    table.sort(idxs)
    local width = #palette > 255 and 2 or 1
    local parts = {}
    local prev = 0
    for _, index in ipairs(idxs) do
      if index <= prev or index < 1 or index > 4096 then return nil, "index" end
      local ref = paletteIndex(palette, cells[index])
      if not ref or ref == 0 then return nil, "palette" end
      prev = index
      if width == 1 then
        if ref > 255 then return nil, "palette" end
        parts[#parts + 1] = be16(index) .. string.char(ref)
      else
        parts[#parts + 1] = be16(index) .. be16(ref)
      end
    end
    return table.concat(parts), width
  elseif codec == "rle/1" then
    local width = #palette > 255 and 2 or 1
    local function refAt(index)
      local name = cells[index]
      if name == nil then return 0 end
      local ref = paletteIndex(palette, name)
      if not ref then return nil end
      return ref
    end
    local parts, run, prev = {}, 0, refAt(1)
    if prev == nil then return nil, "palette" end
    for index = 1, 4096 do
      local ref = refAt(index)
      if ref == nil then return nil, "palette" end
      if ref ~= prev then
        if width == 1 then parts[#parts + 1] = be16(run) .. string.char(prev)
        else parts[#parts + 1] = be16(run) .. be16(prev) end
        prev, run = ref, 1
      else run = run + 1 end
    end
    if width == 1 then parts[#parts + 1] = be16(run) .. string.char(prev)
    else parts[#parts + 1] = be16(run) .. be16(prev) end
    return table.concat(parts), width
  end
  return nil, "codec"
end

function M.decodeCells(codec, palette, raw, width)
  width = width or (#palette > 255 and 2 or 1)
  local cells = {}
  if codec == "sparse/1" then
    local i, prev = 1, 0
    while i <= #raw do
      local index, j = rd16(raw, i)
      local ref
      if width == 1 then
        ref = raw:byte(j or 1)
        j = (j or 1) + 1
      else
        ref, j = rd16(raw, j or 1)
      end
      if not index or not ref or index <= prev or index > 4096 or ref == 0 or not palette[ref] then return nil, "sparse" end
      cells[index] = palette[ref]
      prev, i = index, j
    end
    if i ~= #raw + 1 then return nil, "tail" end
    return cells
  elseif codec == "rle/1" then
    local i, covered = 1, 0
    local prev
    while i <= #raw do
      local run, j = rd16(raw, i)
      local ref
      if width == 1 then
        ref = raw:byte(j or 1)
        j = (j or 1) + 1
      else
        ref, j = rd16(raw, j or 1)
      end
      if not run or not ref or run < 1 or covered + run > 4096 then return nil, "rle" end
      if ref ~= 0 and not palette[ref] then return nil, "palette" end
      if prev == ref then return nil, "rle" end
      for k = 1, run do
        if ref ~= 0 then cells[covered + k] = palette[ref] end
      end
      covered, prev, i = covered + run, ref, j
    end
    if covered ~= 4096 or i ~= #raw + 1 then return nil, "rle" end
    return cells
  end
  return nil, "codec"
end

function M.sectionCodec(store)
  return store.enabled and "sparse/1" or "rle/1"
end

return M
