-- Copy codes and neighbour confirmation. Records live in enrol.store, not in
-- ssot.state. X25519 waits on P0, so a code is 16 Crockford characters and the
-- pairing key is HMAC-SHA256 of the transcript keyed by that code.

local M = { tries = 5, ttl = 120000, planTtl = 900000 }
local ALPH = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
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

local function add(...)
  local n = 0
  for i = 1, select("#", ...) do n = n + select(i, ...) end
  return n % 4294967296
end

local function hex32(x)
  local out = {}
  for shift = 24, 0, -8 do
    out[#out + 1] = string.format("%02x", bit32.band(bit32.rshift(x, shift), 255))
  end
  return table.concat(out)
end

local function sha256(msg)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local len = #msg
  local pad = msg .. "\128" .. string.rep("\0", (56 - (len + 1) % 64) % 64)
  local bits = len * 8
  pad = pad .. string.char(0, 0, 0, 0,
    bit32.band(bit32.rshift(bits, 24), 255), bit32.band(bit32.rshift(bits, 16), 255),
    bit32.band(bit32.rshift(bits, 8), 255), bit32.band(bits, 255))
  local w = {}
  for i = 1, #pad, 64 do
    for t = 0, 15 do
      local j = i + t * 4
      w[t] = bit32.bor(bit32.lshift(pad:byte(j), 24), bit32.lshift(pad:byte(j + 1), 16),
        bit32.lshift(pad:byte(j + 2), 8), pad:byte(j + 3))
    end
    for t = 16, 63 do
      local s0 = bit32.bxor(bit32.rrotate(w[t - 15], 7), bit32.rrotate(w[t - 15], 18), bit32.rshift(w[t - 15], 3))
      local s1 = bit32.bxor(bit32.rrotate(w[t - 2], 17), bit32.rrotate(w[t - 2], 19), bit32.rshift(w[t - 2], 10))
      w[t] = add(w[t - 16], s0, w[t - 7], s1)
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for t = 0, 63 do
      local s1 = bit32.bxor(bit32.rrotate(e, 6), bit32.rrotate(e, 11), bit32.rrotate(e, 25))
      local ch = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
      local t1 = add(h, s1, ch, K[t + 1], w[t])
      local s0 = bit32.bxor(bit32.rrotate(a, 2), bit32.rrotate(a, 13), bit32.rrotate(a, 22))
      local maj = bit32.bxor(bit32.band(a, b), bit32.band(a, c), bit32.band(b, c))
      local t2 = add(s0, maj)
      h, g, f, e, d, c, b, a = g, f, e, add(d, t1), c, b, a, add(t1, t2)
    end
    h0, h1, h2, h3 = add(h0, a), add(h1, b), add(h2, c), add(h3, d)
    h4, h5, h6, h7 = add(h4, e), add(h5, f), add(h6, g), add(h7, h)
  end
  return hex32(h0) .. hex32(h1) .. hex32(h2) .. hex32(h3) .. hex32(h4) .. hex32(h5) .. hex32(h6) .. hex32(h7)
end

local function rawSha(msg)
  local hex = sha256(msg)
  local out = {}
  for i = 1, #hex, 2 do out[#out + 1] = string.char(tonumber(hex:sub(i, i + 1), 16)) end
  return table.concat(out)
end

function M.sha256(msg)
  return sha256(msg)
end

function M.hmac(key, msg)
  if #key > 64 then key = rawSha(key) end
  key = key .. string.rep("\0", 64 - #key)
  local ip, op = {}, {}
  for i = 1, 64 do
    local b = key:byte(i)
    ip[i] = string.char(bit32.bxor(b, 0x36))
    op[i] = string.char(bit32.bxor(b, 0x5c))
  end
  return sha256(table.concat(op) .. rawSha(table.concat(ip) .. msg))
end

local VEC = { [0] = { 0, 0, -1 }, { 1, 0, 0 }, { 0, 0, 1 }, { -1, 0, 0 } }
local TURN = { front = 0, right = 1, back = 2, left = 3 }

local function copyPos(p)
  return {
    v = 1, frame = p.frame or "abs", yAbs = p.yAbs ~= false, dim = p.dim,
    x = p.x, y = p.y, z = p.z, h = p.h, conf = "certain", src = "neighbour",
    anchoredAt = p.anchoredAt or false,
  }
end

function M.beside(pose, side)
  if type(pose) ~= "table" or type(pose.x) ~= "number" or type(pose.y) ~= "number"
    or type(pose.z) ~= "number" or type(pose.dim) ~= "string" then return nil end
  local out = copyPos(pose)
  if side == "up" or side == "down" then
    out.y = pose.y + (side == "up" and 1 or -1)
    out.h = false
    return out
  end
  local turn = TURN[side]
  if turn == nil or type(pose.h) ~= "number" then return nil end
  local h = (pose.h + turn) % 4
  local v = VEC[h]
  out.x, out.z, out.h = pose.x + v[1], pose.z + v[3], (h + 2) % 4
  return out
end

function M.empty()
  return { v = 1, seq = 0, codes = {}, confirms = {}, paired = {} }
end

function M.encode(bytes)
  if type(bytes) ~= "string" or #bytes ~= 10 then return nil end
  local bits = {}
  for i = 1, 10 do
    local b = bytes:byte(i)
    for shift = 7, 0, -1 do bits[#bits + 1] = bit32.band(bit32.rshift(b, shift), 1) end
  end
  local out = {}
  for i = 0, 15 do
    local n = 0
    for b = 1, 5 do n = n * 2 + bits[i * 5 + b] end
    out[i + 1] = ALPH:sub(n + 1, n + 1)
  end
  return table.concat(out)
end

function M.parse(text)
  text = tostring(text or "")
  local id, code = text:match("^(c:%d+:%d+)%s+([%w]+)$")
  if not code then code = text:match("^([%w]+)$") end
  if not code then return nil, nil end
  code = code:upper()
  if not code:match("^[0-9A-HJKMNP-TVWXYZ]+$") or #code ~= 16 then return id, nil end
  return id, code
end

function M.transcript(claim)
  return table.concat({
    "v1", tostring(claim.id), tostring(claim.server), claim.codeId or "",
    claim.nNew or "", claim.nServer or "", claim.newPub or "", claim.serverPub or "",
  }, "|")
end

function M.proof(code, claim)
  return M.hmac(code, M.transcript(claim))
end

function M.pairingKey(code, claim)
  return M.hmac(code, "pair|" .. M.transcript(claim))
end

local function bytes(rng, n)
  local out = {}
  for i = 1, n do out[i] = string.char((rng or math.random)(0, 255)) end
  return table.concat(out)
end

local function nonce(rng)
  local raw = bytes(rng, 16)
  local hex = {}
  for i = 1, #raw do hex[i] = string.format("%02x", raw:byte(i)) end
  return table.concat(hex)
end

function M.issue(store, now, issuer, req, rng)
  if type(req) ~= "table" or type(req.role) ~= "string" or #req.role < 1 or #req.role > 32 then
    return nil, "role"
  end
  store.seq = (store.seq or 0) + 1
  local id = "c:" .. tostring(issuer) .. ":" .. tostring(store.seq)
  local code = M.encode(bytes(rng, 10))
  local ttl = req.planBot and M.planTtl or M.ttl
  local rec = {
    v = 1, id = id, code = code, issuer = issuer, role = req.role,
    issuedAt = now, untilAt = now + ttl, frame = req.frame or "abs",
    home = req.home or false, settingsRef = req.settingsRef or { revision = 0 },
    filesRef = req.filesRef or { role = req.role }, planBot = req.planBot or false,
    used = false, burned = false, attempts = 0,
  }
  store.codes[id] = rec
  return {
    v = 1, id = id, code = code, issuer = issuer, role = rec.role,
    issuedAt = now, untilAt = rec.untilAt, frame = rec.frame, home = rec.home,
    settingsRef = rec.settingsRef, filesRef = rec.filesRef, planBot = rec.planBot,
    used = false, attempts = 0,
  }
end

local function reject(rec)
  rec.attempts = (rec.attempts or 0) + 1
  if rec.attempts >= M.tries then
    rec.burned, rec.used, rec.code = true, true, nil
    return { ok = false, error = "code_burned" }
  end
  return { ok = false, error = "code_rejected", attempts = rec.attempts }
end

local function gate(rec, now)
  if not rec then return { ok = false, error = "code_unknown" } end
  if rec.burned then return { ok = false, error = "code_burned" } end
  if rec.used then return { ok = false, error = "code_replayed" } end
  if type(now) ~= "number" or now > rec.untilAt then return { ok = false, error = "code_expired" } end
end

function M.hello(store, now, id, msg, serverId, rng)
  local rec = store.codes[msg.codeId]
  local blocked = gate(rec, now)
  if blocked then return blocked end
  if type(msg.nNew) ~= "string" or #msg.nNew < 8 or #msg.nNew > 64 then
    return { ok = false, error = "code_rejected" }
  end
  rec.nNew = msg.nNew
  rec.nServer = nonce(rng)
  rec.claimer = id
  return {
    ok = true, codeId = rec.id, nServer = rec.nServer, untilAt = rec.untilAt,
    server = serverId, role = rec.role,
  }
end

function M.claim(store, now, id, msg, serverId)
  local rec = store.codes[msg.codeId]
  local blocked = gate(rec, now)
  if blocked then return blocked end
  local claim = {
    id = id, server = serverId, codeId = rec.id,
    nNew = rec.nNew or "", nServer = rec.nServer or "",
    newPub = msg.newPub or "", serverPub = msg.serverPub or "",
  }
  if msg.nNew ~= claim.nNew or msg.nServer ~= claim.nServer or msg.proof ~= M.proof(rec.code, claim) then
    return reject(rec)
  end
  local key = M.pairingKey(rec.code, claim)
  rec.used, rec.code = true, nil
  store.paired[tostring(id)] = { role = rec.role, at = now, key = key }
  return {
    ok = true, role = rec.role, frame = rec.frame, home = rec.home,
    filesRef = rec.filesRef, settingsRef = rec.settingsRef,
    codeId = rec.id, nNew = claim.nNew, nServer = claim.nServer, server = serverId,
  }
end

function M.confirm(store, now, id, msg)
  if type(msg.newId) ~= "number" or type(msg.side) ~= "string" or type(msg.pose) ~= "table" then
    return { ok = false, error = "neighbour_missing" }
  end
  if not M.beside(msg.pose, msg.side) and msg.side ~= "up" and msg.side ~= "down" then
    return { ok = false, error = "neighbour_missing" }
  end
  store.confirms[tostring(id)] = {
    newId = msg.newId, side = msg.side, pose = msg.pose, at = now,
  }
  return { ok = true }
end

function M.neighbour(store, now, id, msg, controllers)
  local who = tostring(msg.neighbour or "")
  if not (controllers and controllers[who]) then
    return { ok = false, error = "neighbour_unknown" }
  end
  local confirm = store.confirms[who]
  if not confirm or confirm.newId ~= id or confirm.side ~= msg.side
    or type(confirm.at) ~= "number" or now - confirm.at > M.ttl then
    return { ok = false, error = "neighbour_missing" }
  end
  local pos = M.beside(confirm.pose, confirm.side)
  if not pos then return { ok = false, error = "neighbour_missing" } end
  return { ok = true, pos = pos, frame = pos.frame }
end

local function readAll(filesystem, name)
  if not filesystem.exists(name) then return nil end
  local h = filesystem.open(name, "r")
  if not h then return nil end
  local text = h.readAll()
  h.close()
  return text
end

local function literal(v, seen)
  local kind = type(v)
  if kind == "string" then return string.format("%q", v) end
  if kind == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    if v % 1 == 0 and math.abs(v) < 2 ^ 53 then return string.format("%.0f", v) end
    return string.format("%.17g", v)
  end
  if kind == "boolean" then return v and "true" or "false" end
  if v == nil then return nil end
  if kind ~= "table" then return nil end
  if seen[v] then return nil end
  seen[v] = true
  local keys = {}
  for key in pairs(v) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return tostring(a) < tostring(b) end
    return type(a) < type(b)
  end)
  local parts = {}
  for _, key in ipairs(keys) do
    local inner = literal(v[key], seen)
    if inner then
      local shown
      if type(key) == "string" and key:match("^[%a_][%w_]*$") then shown = key
      else shown = "[" .. (literal(key, seen) or "nil") .. "]" end
      parts[#parts + 1] = shown .. "=" .. inner
    end
  end
  seen[v] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.load(filesystem)
  local text = readAll(filesystem, "enrol.store")
  if not text or text == "" then return M.empty() end
  local fn, err = load("return " .. text, "=enrol.store", "t", {})
  if not fn then return nil, err end
  local ok, store = pcall(fn)
  if not ok or type(store) ~= "table" or store.v ~= 1 or type(store.codes) ~= "table" then
    return nil, "enrol.store unreadable"
  end
  store.confirms = store.confirms or {}
  store.paired = store.paired or {}
  return store
end

function M.save(filesystem, store)
  local text = literal(store, {})
  local tmp = "enrol.store.tmp"
  local h = filesystem.open(tmp, "w")
  if not h then return false, "open" end
  h.write(text)
  h.close()
  local back = readAll(filesystem, tmp)
  if back ~= text then
    filesystem.delete(tmp)
    return false, "verify"
  end
  if filesystem.exists("enrol.store") then filesystem.delete("enrol.store") end
  filesystem.move(tmp, "enrol.store")
  return true
end

function M.operate(id, msg, clock, cfg, filesystem)
  filesystem = filesystem or fs
  local store, err = M.load(filesystem)
  if not store then return { ok = false, error = "enrol_store", detail = tostring(err) } end
  local now = clock()
  local serverId = os.getComputerID()
  local result
  if msg.op == "enrol-issue" then
    local rec, why = M.issue(store, now, id, msg, math.random)
    if not rec then return { ok = false, error = "code_rejected", detail = why } end
    result = rec
    result.ok = true
  elseif msg.op == "enrol-hello" then
    result = M.hello(store, now, id, msg, serverId, math.random)
  elseif msg.op == "enrol-claim" then
    result = M.claim(store, now, id, msg, serverId)
  elseif msg.op == "enrol-confirm" then
    result = M.confirm(store, now, id, msg)
  elseif msg.op == "enrol-neighbour" then
    result = M.neighbour(store, now, id, msg, cfg and cfg.controllers)
  else
    return { ok = false, error = "unknown operation" }
  end
  if not result then return { ok = false, error = "code_rejected" } end
  local saved, saveErr = M.save(filesystem, store)
  if not saved then return { ok = false, error = "disk_full", detail = tostring(saveErr) } end
  return result
end

return M
