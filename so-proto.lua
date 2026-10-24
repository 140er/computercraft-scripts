local M = {}
local S = {
  name = "so",
  limit = 16384,
  skew = 60000,
  -- Every computer reads the same host clock, so no stamp is ahead of
  -- its receiver. Allowing none keeps old stamps before a restart.
  ahead = 0,
  memory = 120000,
  ridMax = 64,
  depthMax = 8,
  seq = 0,
  seen = {},
  keyFor = nil,
  K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  },
  H = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  },
}

local function whole(n)
  return type(n) == "number" and n == n and n % 1 == 0 and n > -2 ^ 53 and n < 2 ^ 53
end

M.sha256 = function(msg)
  local h = { S.H[1], S.H[2], S.H[3], S.H[4], S.H[5], S.H[6], S.H[7], S.H[8] }
  local bytes = { msg:byte(1, #msg) }
  bytes[#bytes + 1] = 0x80
  while (#bytes % 64) ~= 56 do bytes[#bytes + 1] = 0 end
  local bits = #msg * 8
  bytes[#bytes + 1] = 0
  bytes[#bytes + 1] = 0
  bytes[#bytes + 1] = 0
  bytes[#bytes + 1] = 0
  bytes[#bytes + 1] = bit32.band(bit32.rshift(bits, 24), 255)
  bytes[#bytes + 1] = bit32.band(bit32.rshift(bits, 16), 255)
  bytes[#bytes + 1] = bit32.band(bit32.rshift(bits, 8), 255)
  bytes[#bytes + 1] = bit32.band(bits, 255)
  local w = {}
  local block = 1
  while block <= #bytes do
    for t = 0, 15 do
      local i = block + t * 4
      w[t] = bit32.bor(bit32.lshift(bytes[i], 24), bit32.lshift(bytes[i + 1], 16),
        bit32.lshift(bytes[i + 2], 8), bytes[i + 3])
    end
    for t = 16, 63 do
      local x = w[t - 15]
      local y = w[t - 2]
      local s0 = bit32.bxor(bit32.rrotate(x, 7), bit32.rrotate(x, 18), bit32.rshift(x, 3))
      local s1 = bit32.bxor(bit32.rrotate(y, 17), bit32.rrotate(y, 19), bit32.rshift(y, 10))
      w[t] = bit32.band(w[t - 16] + s0 + w[t - 7] + s1, 0xFFFFFFFF)
    end
    local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for t = 0, 63 do
      local s1 = bit32.bxor(bit32.rrotate(e, 6), bit32.rrotate(e, 11), bit32.rrotate(e, 25))
      local ch = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
      local t1 = bit32.band(hh + s1 + ch + S.K[t + 1] + w[t], 0xFFFFFFFF)
      local s0 = bit32.bxor(bit32.rrotate(a, 2), bit32.rrotate(a, 13), bit32.rrotate(a, 22))
      local maj = bit32.bxor(bit32.band(a, b), bit32.band(a, c), bit32.band(b, c))
      local t2 = bit32.band(s0 + maj, 0xFFFFFFFF)
      hh = g
      g = f
      f = e
      e = bit32.band(d + t1, 0xFFFFFFFF)
      d = c
      c = b
      b = a
      a = bit32.band(t1 + t2, 0xFFFFFFFF)
    end
    h[1] = bit32.band(h[1] + a, 0xFFFFFFFF)
    h[2] = bit32.band(h[2] + b, 0xFFFFFFFF)
    h[3] = bit32.band(h[3] + c, 0xFFFFFFFF)
    h[4] = bit32.band(h[4] + d, 0xFFFFFFFF)
    h[5] = bit32.band(h[5] + e, 0xFFFFFFFF)
    h[6] = bit32.band(h[6] + f, 0xFFFFFFFF)
    h[7] = bit32.band(h[7] + g, 0xFFFFFFFF)
    h[8] = bit32.band(h[8] + hh, 0xFFFFFFFF)
    block = block + 64
  end
  local out = {}
  for i = 1, 8 do
    local x = h[i]
    out[i] = string.char(bit32.rshift(x, 24), bit32.band(bit32.rshift(x, 16), 255),
      bit32.band(bit32.rshift(x, 8), 255), bit32.band(x, 255))
  end
  return table.concat(out)
end

M.hex = function(raw)
  local parts = {}
  for i = 1, #raw do parts[i] = string.format("%02x", raw:byte(i)) end
  return table.concat(parts)
end

M.unhex = function(hex)
  if type(hex) ~= "string" or #hex % 2 ~= 0 or not hex:match("^%x+$") then
    error("bad key", 0)
  end
  local out = {}
  for i = 1, #hex, 2 do
    out[#out + 1] = string.char(tonumber(hex:sub(i, i + 1), 16))
  end
  return table.concat(out)
end

M.hmac = function(key, msg)
  if #key > 64 then key = M.sha256(key) end
  if #key < 64 then key = key .. string.rep("\0", 64 - #key) end
  local ipad, opad = {}, {}
  for i = 1, 64 do
    local b = key:byte(i)
    ipad[i] = string.char(bit32.bxor(b, 0x36))
    opad[i] = string.char(bit32.bxor(b, 0x5c))
  end
  return M.sha256(table.concat(opad) .. M.sha256(table.concat(ipad) .. msg))
end

M.ser = function(v)
  local seen = {}
  local function write(value)
    local kind = type(value)
    if kind == "string" then return string.format("%q", value) end
    if kind == "number" then
      if whole(value) then return string.format("%d", value) end
      return string.format("%.17g", value)
    end
    if kind == "boolean" then return value and "true" or "false" end
    if kind ~= "table" then error("bad type", 0) end
    if seen[value] then error("cycle", 0) end
    seen[value] = true
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    for i = 2, #keys do
      local key = keys[i]
      local rank = type(key) .. ":" .. tostring(key)
      local j = i - 1
      while j >= 1 do
        local other = keys[j]
        local otherRank = type(other) .. ":" .. tostring(other)
        if otherRank <= rank then break end
        keys[j + 1] = other
        j = j - 1
      end
      keys[j + 1] = key
    end
    local parts = {}
    for i = 1, #keys do
      parts[i] = "[" .. write(keys[i]) .. "]=" .. write(value[keys[i]])
    end
    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return write(v)
end

local function checkedCopy(value, depthMax)
  local state = { n = 0, bad = false, seen = {} }
  local function walk(v, depth)
    if state.bad then return nil end
    local kind = type(v)
    if kind == "string" then
      if #v > S.limit then state.bad = true return nil end
      state.n = state.n + #v + 2
    elseif kind == "number" then
      if v ~= v or v == math.huge or v == -math.huge then state.bad = true return nil end
      state.n = state.n + 1
    elseif kind == "boolean" then
      state.n = state.n + 4
    elseif kind == "table" then
      if depth > depthMax or state.seen[v] then state.bad = true return nil end
      state.seen[v] = true
      state.n = state.n + 2
      local out = {}
      for key, item in pairs(v) do
        local copiedKey = walk(key, depth + 1)
        local copied = walk(item, depth + 1)
        if state.bad then return nil end
        out[copiedKey] = copied
      end
      state.seen[v] = nil
      if state.n > S.limit then state.bad = true return nil end
      return out
    else
      state.bad = true
      return nil
    end
    if state.n > S.limit then state.bad = true return nil end
    return v
  end
  local copy = walk(value, 1)
  if state.bad or type(copy) ~= "table" then return nil end
  local ok, text = pcall(M.ser, copy)
  if not ok or type(text) ~= "string" or #text > S.limit then return nil end
  return copy
end

M.encode = function(value)
  if type(value) ~= "table" then return nil end
  return checkedCopy(value, S.depthMax + 1)
end

M.canonical = function(msg)
  return M.ser({
    v = msg.v, t = msg.t, rid = msg.rid, from = msg.from, at = msg.at, body = msg.body,
  })
end

M.sign = function(key, msg)
  return M.hex(M.hmac(M.unhex(key), M.canonical(msg)))
end

M.macOk = function(key, msg)
  if type(key) ~= "string" or #key ~= 64 or not key:match("^%x+$") then return false end
  if type(msg) ~= "table" or type(msg.mac) ~= "string" or #msg.mac ~= 64 then return false end
  local expect = M.sign(key, msg)
  local diff = 0
  for i = 1, 64 do
    if expect:byte(i) ~= msg.mac:byte(i) then diff = diff + 1 end
  end
  return diff == 0
end

M.decode = function(value)
  if type(value) ~= "table" then return nil, "type" end
  if value.v ~= 1 or type(value.t) ~= "string" or #value.t < 1 or #value.t > S.limit
    or type(value.rid) ~= "string" or #value.rid < 1 or #value.rid > S.ridMax
    or not whole(value.from) or not whole(value.at) or type(value.mac) ~= "string"
    or #value.mac ~= 64 or type(value.body) ~= "table" then
    return nil, "shape"
  end
  local age = os.epoch("utc") - value.at
  if age > S.skew or age < -S.ahead then return nil, "time" end
  local body = checkedCopy(value.body, S.depthMax)
  if not body then return nil, "body" end
  local copy = {
    v = 1,
    t = value.t,
    rid = value.rid,
    from = value.from,
    at = value.at,
    mac = value.mac,
    body = body,
  }
  local ok, text = pcall(M.ser, copy)
  if not ok or type(text) ~= "string" or #text > S.limit then return nil, "size" end
  return copy
end

M.bind = function(keyFor)
  S.keyFor = keyFor
end

M.build = function(key, t, body, rid)
  S.seq = S.seq + 1
  local msg = {
    v = 1,
    t = t,
    rid = rid or string.format("%d-%d-%d", os.getComputerID(), os.epoch("utc"), S.seq),
    from = os.getComputerID(),
    at = os.epoch("utc"),
    body = body or {},
  }
  msg.mac = M.sign(key, msg)
  return msg
end

-- Refuse envelopes stamped before utc. An earlier run accepted nothing
-- stamped after its own last tick, so a restart cannot reopen the replay
-- window.
M.since = function(utc) S.since = utc end

M.fresh = function(msg)
  local now = os.epoch("utc")
  if S.since and msg.at < S.since then return false end
  local slot = S.seen[msg.from]
  if not slot then
    slot = {}
    S.seen[msg.from] = slot
  end
  for rid, at in pairs(slot) do
    if now - at > S.memory then slot[rid] = nil end
  end
  if slot[msg.rid] then return false end
  slot[msg.rid] = now
  return true
end

-- Drops expired rids and empty senders from the replay memory.
M.prune = function()
  local cutoff = os.epoch("utc") - S.memory
  for from, slot in pairs(S.seen) do
    for rid, at in pairs(slot) do
      if at < cutoff then slot[rid] = nil end
    end
    if next(slot) == nil then S.seen[from] = nil end
  end
end

-- key, when given, replaces the bound key for this one exchange.
M.request = function(target, t, body, timeout, tries, key)
  key = key or (S.keyFor and S.keyFor(target))
  if not key then return nil, "no key" end
  local wait = timeout or 3
  if type(wait) ~= "number" or wait <= 0 then wait = 3 end
  local msg = M.build(key, t, body)
  local wire = M.encode(msg)
  if not wire then return nil, "encode" end
  local left = tries or 1
  while left > 0 do
    left = left - 1
    rednet.send(target, wire, S.name)
    local timer = os.startTimer(wait)
    local got
    while not got do
      local ev, a, b, c = os.pullEvent()
      if ev == "timer" and a == timer then break end
      if ev == "rednet_message" and c == S.name and a == target and type(b) == "table" then
        local reply = M.decode(b)
        if reply and reply.rid == msg.rid and reply.from == target and M.macOk(key, reply) and M.fresh(reply) then
          got = reply
        end
      end
    end
    if got then
      os.cancelTimer(timer)
      return got
    end
  end
  return nil, "timeout"
end

return M
