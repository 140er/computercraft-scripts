-- Section codec for H4b1. One 16x16x16 section is a palette and run-length
-- cells. A missing index is unknown. Observed air is the name minecraft:air.
-- The "=" baseline token belongs to H4b2 and is rejected here.
--
-- On disk, "CCS2" then version 2. The SHA-256 covers the key, revision,
-- palette, and runs. observedAt, lastRead, and tier sit outside the hash
-- so a read does not change the content hash. Cell 0 is the first cell.
-- Schema 1 stored that cell at index 1, and stored 0 for observed air.
--
-- Run bytes are at:uint16, palette:uint8, n:uint16, in index order.
-- The palette byte is the index minus one, so a section holds 256 names.
-- H4a replaces nothing in this file. T1 can call confidence() and get().

local M = { v = 2 }
local bit32 = bit32

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function add(a, b) return bit32.band(a + b, 0xffffffff) end
local function u32(n)
  return string.char(
    bit32.band(bit32.rshift(n, 24), 255),
    bit32.band(bit32.rshift(n, 16), 255),
    bit32.band(bit32.rshift(n, 8), 255),
    bit32.band(n, 255))
end
local function hex(bytes)
  local out = {}
  for i = 1, #bytes do out[i] = string.format("%02x", bytes:byte(i)) end
  return table.concat(out)
end

function M.sha256(msg)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local bits = #msg * 8
  msg = msg .. "\128"
  msg = msg .. string.rep("\0", (56 - (#msg % 64)) % 64)
  msg = msg .. u32(math.floor(bits / 4294967296)) .. u32(bits % 4294967296)
  for off = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      local a, b, c, d = msg:byte(off + i * 4, off + i * 4 + 3)
      w[i] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for i = 16, 63 do
      local x, y = w[i - 15], w[i - 2]
      local s0 = bit32.bxor(bit32.rrotate(x, 7), bit32.rrotate(x, 18), bit32.rshift(x, 3))
      local s1 = bit32.bxor(bit32.rrotate(y, 17), bit32.rrotate(y, 19), bit32.rshift(y, 10))
      w[i] = add(add(w[i - 16], s0), add(w[i - 7], s1))
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 0, 63 do
      local s1 = bit32.bxor(bit32.rrotate(e, 6), bit32.rrotate(e, 11), bit32.rrotate(e, 25))
      local ch = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
      local t1 = add(add(add(h, s1), ch), add(K[i + 1], w[i]))
      local s0 = bit32.bxor(bit32.rrotate(a, 2), bit32.rrotate(a, 13), bit32.rrotate(a, 22))
      local maj = bit32.bxor(bit32.bxor(bit32.band(a, b), bit32.band(a, c)), bit32.band(b, c))
      local t2 = add(s0, maj)
      h, g, f = g, f, e
      e = add(d, t1)
      d, c, b = c, b, a
      a = add(t1, t2)
    end
    h0, h1, h2, h3 = add(h0, a), add(h1, b), add(h2, c), add(h3, d)
    h4, h5, h6, h7 = add(h4, e), add(h5, f), add(h6, g), add(h7, h)
  end
  return u32(h0) .. u32(h1) .. u32(h2) .. u32(h3) .. u32(h4) .. u32(h5) .. u32(h6) .. u32(h7)
end

function M.sha256hex(msg) return hex(M.sha256(msg)) end

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end
local function blockName(s)
  return type(s) == "string" and s ~= "=" and #s >= 3 and #s <= 128
    and s:match("^[%w_]+:[%w_/.-]+$") ~= nil
end
local function validKey(key)
  if type(key) ~= "string" or #key == 0 or #key > 180 or key:find("[\r\n\t]", 1) then return false end
  local rest = key:match("^abs|(.+)$") or key:match("^f:[%w_.:%-]+|(.+)$")
  return rest ~= nil and rest:match("^[%w_]+:[%w_/.-]+|%-?%d+|%-?%d+|%-?%d+$") ~= nil
end

function M.cellIndex(x, y, z)
  return (x % 16) + 16 * (z % 16) + 256 * (y % 16)
end

function M.sectionKey(pose)
  if type(pose) ~= "table" then return nil end
  local frame = pose.frame or "abs"
  if frame ~= "abs" and not frame:match("^f:[%w_.:%-]+$") then return nil end
  if type(pose.dim) ~= "string" or not integer(pose.x, -30000000, 30000000)
    or not integer(pose.y, -2048, 2048) or not integer(pose.z, -30000000, 30000000) then return nil end
  local key = string.format("%s|%s|%d|%d|%d", frame, pose.dim,
    math.floor(pose.x / 16), math.floor(pose.y / 16), math.floor(pose.z / 16))
  if not validKey(key) then return nil end
  return key
end

function M.normalizeKey(chunk)
  if validKey(chunk) then return chunk end
  if type(chunk) == "string" and chunk:match("^[%w_]+:[%w_/.-]+|%-?%d+|%-?%d+|%-?%d+$") then
    local key = "abs|" .. chunk
    if validKey(key) then return key end
  end
end

local function finish(key, rev, palette, runs, observedAt, lastRead)
  if not validKey(key) or not integer(rev, 0, 2147483647) then return nil, "bad section" end
  if not integer(observedAt, 0, 9007199254740991) or not integer(lastRead, 0, 9007199254740991) then
    return nil, "bad section"
  end
  local section = {
    v = 2, key = key, rev = rev, palette = palette, runs = runs,
    observedAt = observedAt, lastRead = lastRead, tier = "hot",
  }
  return section
end

function M.fromCells(key, rev, cells, observedAt, lastRead)
  local palette, seen, runs = {}, {}, {}
  local i = 0
  while i < 4096 do
    local name = cells[i]
    if name == nil then
      i = i + 1
    else
      if not blockName(name) then return nil, "bad block" end
      local id = seen[name]
      if not id then
        if #palette >= 256 then return nil, "palette limit" end
        palette[#palette + 1] = name
        id = #palette
        seen[name] = id
      end
      local n = 1
      while i + n < 4096 and cells[i + n] == name do n = n + 1 end
      runs[#runs + 1] = { at = i, pal = id, n = n }
      i = i + n
    end
  end
  return finish(key, rev, palette, runs, observedAt or 0, lastRead or 0)
end

function M.schema1Cells(names, cells)
  local out = {}
  for i, value in pairs(cells) do
    if not integer(i, 1, 4096) or not integer(value, 0, #names) then return nil, "bad schema 1 cell" end
    if value == 0 then out[i - 1] = "minecraft:air"
    else
      local name = names[value]
      if not blockName(name) then return nil, "bad schema 1 name" end
      out[i - 1] = name
    end
  end
  return out
end

function M.get(section, index)
  if section == nil or not integer(index, 0, 4095) then return nil end
  local lo, hi = 1, #section.runs
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local run = section.runs[mid]
    if index < run.at then hi = mid - 1
    elseif index >= run.at + run.n then lo = mid + 1
    else return section.palette[run.pal] end
  end
end

function M.confidence(section, index)
  if M.get(section, index) == nil then return "unknown" end
  return "observed"
end

function M.wireName(name)
  if name == "minecraft:air" then return false end
  return name
end

function M.apply(section, key, edits, rev, now)
  local cells = {}
  if section then
    if section.key ~= key then return nil, "key changed" end
    for _, run in ipairs(section.runs) do
      local name = section.palette[run.pal]
      for n = 0, run.n - 1 do cells[run.at + n] = name end
    end
  end
  for _, edit in ipairs(edits) do
    if not integer(edit.index, 0, 4095) then return nil, "bad index" end
    local name = edit.name
    if name == false then name = "minecraft:air" end
    if not blockName(name) then return nil, "bad block" end
    cells[edit.index] = name
  end
  local kept = section and section.observedAt or now
  return M.fromCells(key, rev, cells, kept, now)
end

local function u16(n) return string.char(math.floor(n / 256), n % 256) end

-- Hash input. The file stores key and revision again in front of this tail.
local function payload(key, rev, palette, runs)
  local parts = { key, "\0", u32(rev), u16(#palette) }
  for _, name in ipairs(palette) do
    parts[#parts + 1] = string.char(#name)
    parts[#parts + 1] = name
  end
  parts[#parts + 1] = u16(#runs)
  for _, run in ipairs(runs) do
    parts[#parts + 1] = string.char(math.floor(run.at / 256), run.at % 256, run.pal - 1,
      math.floor(run.n / 256), run.n % 256)
  end
  return table.concat(parts)
end

local function u64(n)
  return u32(math.floor(n / 4294967296)) .. u32(n % 4294967296)
end

function M.encode(section)
  if type(section) ~= "table" or section.v ~= 2 or section.tier ~= "hot" then return nil, "bad section" end
  if not validKey(section.key) or not integer(section.rev, 0, 2147483647) then return nil, "bad section" end
  if type(section.palette) ~= "table" or type(section.runs) ~= "table" then return nil, "bad section" end
  if #section.palette > 256 then return nil, "palette limit" end
  if #section.runs > 4096 then return nil, "bad run" end
  local cursor = 0
  for i, run in ipairs(section.runs) do
    if type(run) ~= "table" or not integer(run.at, 0, 4095) or not integer(run.n, 1, 4096)
      or not integer(run.pal, 1, #section.palette) or run.at < cursor or run.at + run.n > 4096 then
      return nil, "bad run"
    end
    if not blockName(section.palette[run.pal]) then return nil, "bad block" end
    cursor = run.at + run.n
    if i > 1 then
      local prev = section.runs[i - 1]
      if prev.at + prev.n == run.at and prev.pal == run.pal then return nil, "bad run" end
    end
  end
  local body = payload(section.key, section.rev, section.palette, section.runs)
  local digest = M.sha256(body)
  section.hash = hex(digest)
  local tailAt = #section.key + 6
  local head = {
    "CCS2", string.char(2), u16(#section.key), section.key, u32(section.rev), digest,
    u64(section.observedAt), u64(section.lastRead), "\1",
  }
  return table.concat(head) .. body:sub(tailAt), section.hash
end

local function take(bytes, i, n)
  if i + n - 1 > #bytes then return nil end
  return bytes:sub(i, i + n - 1), i + n
end
local function take16(bytes, i)
  local a, b = bytes:byte(i, i + 1)
  if not b then return nil end
  return a * 256 + b, i + 2
end
local function take32(bytes, i)
  local raw, n = take(bytes, i, 4)
  if not raw then return nil end
  local a, b, c, d = raw:byte(1, 4)
  return ((a * 256 + b) * 256 + c) * 256 + d, n
end
local function take64(bytes, i)
  local hi, n = take32(bytes, i)
  if not hi then return nil end
  local lo
  lo, n = take32(bytes, n)
  if not lo then return nil end
  return hi * 4294967296 + lo, n
end

function M.decode(bytes)
  if type(bytes) ~= "string" or #bytes < 8 or bytes:sub(1, 4) ~= "CCS2" or bytes:byte(5) ~= 2 then
    return nil, "unknown"
  end
  if bytes:sub(1, 9) == "whc-rle/1" then return nil, "unknown" end
  local i = 6
  local keyLen
  keyLen, i = take16(bytes, i)
  if not keyLen or keyLen == 0 or keyLen > 180 then return nil, "unknown" end
  local key
  key, i = take(bytes, i, keyLen)
  if not key or not validKey(key) then return nil, "unknown" end
  local rev
  rev, i = take32(bytes, i)
  if not rev or rev > 2147483647 then return nil, "unknown" end
  local digest
  digest, i = take(bytes, i, 32)
  if not digest then return nil, "unknown" end
  local observedAt, lastRead
  observedAt, i = take64(bytes, i)
  lastRead, i = take64(bytes, i)
  if not observedAt or not lastRead or observedAt > 9007199254740991 or lastRead > 9007199254740991 then
    return nil, "unknown"
  end
  local tier
  tier, i = take(bytes, i, 1)
  if tier ~= "\1" then return nil, "unknown" end
  local paletteCount
  paletteCount, i = take16(bytes, i)
  if not paletteCount or paletteCount > 256 then return nil, "unknown" end
  if #bytes < i + paletteCount - 1 then return nil, "unknown" end
  local palette = {}
  for n = 1, paletteCount do
    local len = bytes:byte(i)
    if not len or len == 0 or len > 128 then return nil, "unknown" end
    local name
    name, i = take(bytes, i + 1, len)
    if not name or not blockName(name) then return nil, "unknown" end
    palette[n] = name
  end
  local runCount
  runCount, i = take16(bytes, i)
  if not runCount or runCount > 4096 or #bytes < i + runCount * 5 - 1 then return nil, "unknown" end
  local runs, cursor = {}, 0
  for n = 1, runCount do
    local at, palByte, len
    at, i = take16(bytes, i)
    palByte = bytes:byte(i)
    i = i + 1
    len, i = take16(bytes, i)
    local pal = palByte and palByte + 1
    if not at or not pal or not len or at > 4095 or pal > paletteCount
      or len < 1 or at < cursor or at + len > 4096 then return nil, "unknown" end
    if n > 1 then
      local prev = runs[n - 1]
      if prev.at + prev.n == at and prev.pal == pal then return nil, "unknown" end
    end
    runs[n] = { at = at, pal = pal, n = len }
    cursor = at + len
  end
  if i ~= #bytes + 1 then return nil, "unknown" end
  local body = payload(key, rev, palette, runs)
  if M.sha256(body) ~= digest then return nil, "unknown" end
  local section = finish(key, rev, palette, runs, observedAt, lastRead)
  if not section then return nil, "unknown" end
  section.hash = hex(digest)
  return section
end

return M
