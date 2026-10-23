local M = {}
local S = {
  keys = {},
  pending = nil,
  proto = nil,
  box = nil,
  x = nil,
  rnd = nil,
  fp = nil,
  life = 300000,
  proof = "so-pair-v2\0",
  hs = "so-pair-hs-v2\0",
  -- Pairing budget: tries per sender per window, failed guesses per code.
  window = 60000,
  tries = 3,
  flood = 20,
  burn = 10,
  recent = {},
  sessions = {},
}

-- CPACE-X25519-SHA512 from draft-irtf-cfrg-cpace-21, sections 7 and 8.2,
-- with the key confirmation of section 10.4. SHA-512 is FIPS 180-4.
local C = { K = {}, H = {}, two32 = 4294967296 }

C.words = function(hex, out)
  for i = 1, #hex / 8 do out[i] = tonumber(hex:sub(i * 8 - 7, i * 8), 16) end
end
C.words(
    "428a2f98d728ae227137449123ef65cdb5c0fbcfec4d3b2fe9b5dba58189dbbc" ..
    "3956c25bf348b53859f111f1b605d019923f82a4af194f9bab1c5ed5da6d8118" ..
    "d807aa98a303024212835b0145706fbe243185be4ee4b28c550c7dc3d5ffb4e2" ..
    "72be5d74f27b896f80deb1fe3b1696b19bdc06a725c71235c19bf174cf692694" ..
    "e49b69c19ef14ad2efbe4786384f25e30fc19dc68b8cd5b5240ca1cc77ac9c65" ..
    "2de92c6f592b02754a7484aa6ea6e4835cb0a9dcbd41fbd476f988da831153b5" ..
    "983e5152ee66dfaba831c66d2db43210b00327c898fb213fbf597fc7beef0ee4" ..
    "c6e00bf33da88fc2d5a79147930aa72506ca6351e003826f142929670a0e6e70" ..
    "27b70a8546d22ffc2e1b21385c26c9264d2c6dfc5ac42aed53380d139d95b3df" ..
    "650a73548baf63de766a0abb3c77b2a881c2c92e47edaee692722c851482353b" ..
    "a2bfe8a14cf10364a81a664bbc423001c24b8b70d0f89791c76c51a30654be30" ..
    "d192e819d6ef5218d69906245565a910f40e35855771202a106aa07032bbd1b8" ..
    "19a4c116b8d2d0c81e376c085141ab532748774cdf8eeb9934b0bcb5e19b48a8" ..
    "391c0cb3c5c95a634ed8aa4ae3418acb5b9cca4f7763e373682e6ff3d6b2b8a3" ..
    "748f82ee5defb2fc78a5636f43172f6084c87814a1f0ab728cc702081a6439ec" ..
    "90befffa23631e28a4506cebde82bde9bef9a3f7b2c67915c67178f2e372532b" ..
    "ca273eceea26619cd186b8c721c0c207eada7dd6cde0eb1ef57d4f7fee6ed178" ..
    "06f067aa72176fba0a637dc5a2c898a6113f9804bef90dae1b710b35131c471b" ..
    "28db77f523047d8432caab7b40c724933c9ebe0a15c9bebc431d67c49c100d4c" ..
    "4cc5d4becb3e42b6597f299cfc657e2a5fcb6fab3ad6faec6c44198c4a475817", C.K)
C.words("6a09e667f3bcc908bb67ae8584caa73b3c6ef372fe94f82ba54ff53a5f1d36f1510e527fade682d19b05688c2b3e6c1f1f83d9abfb41bd6b5be0cd19137e2179", C.H)

C.rot = function(h, l, n)
  if n >= 32 then h, l, n = l, h, n - 32 end
  if n == 0 then return h, l end
  return bit32.bor(bit32.rshift(h, n), bit32.lshift(l, 32 - n)),
    bit32.bor(bit32.rshift(l, n), bit32.lshift(h, 32 - n))
end

C.sigma = function(h, l, a, b, c, shift)
  local ah, al = C.rot(h, l, a)
  local bh, bl = C.rot(h, l, b)
  local ch, cl
  if shift then
    ch, cl = bit32.rshift(h, c), bit32.bor(bit32.rshift(l, c), bit32.lshift(h, 32 - c))
  else
    ch, cl = C.rot(h, l, c)
  end
  return bit32.bxor(ah, bh, ch), bit32.bxor(al, bl, cl)
end

C.block = function(h, msg, at)
  local K, two32, sigma = C.K, C.two32, C.sigma
  local band, bxor, bnot = bit32.band, bit32.bxor, bit32.bnot
  local wh, wl = {}, {}
  for t = 0, 15 do
    local b1, b2, b3, b4, b5, b6, b7, b8 = msg:byte(at + t * 8, at + t * 8 + 7)
    wh[t] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    wl[t] = ((b5 * 256 + b6) * 256 + b7) * 256 + b8
  end
  for t = 16, 79 do
    local s0h, s0l = sigma(wh[t - 15], wl[t - 15], 1, 8, 7, true)
    local s1h, s1l = sigma(wh[t - 2], wl[t - 2], 19, 61, 6, true)
    local lo = wl[t - 16] + s0l + wl[t - 7] + s1l
    wl[t] = lo % two32
    wh[t] = (wh[t - 16] + s0h + wh[t - 7] + s1h + math.floor(lo / two32)) % two32
  end
  local ah, al, bh, bl, ch, cl, dh, dl = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
  local eh, el, fh, fl, gh, gl, hh, hl = h[9], h[10], h[11], h[12], h[13], h[14], h[15], h[16]
  for t = 0, 79 do
    local s1h, s1l = sigma(eh, el, 14, 18, 41)
    local lo = hl + s1l + bxor(band(el, fl), band(bnot(el), gl)) + K[t * 2 + 2] + wl[t]
    local t1h = hh + s1h + bxor(band(eh, fh), band(bnot(eh), gh)) + K[t * 2 + 1] + wh[t]
      + math.floor(lo / two32)
    local t1l = lo % two32
    local s0h, s0l = sigma(ah, al, 28, 34, 39)
    local t2l = s0l + bxor(band(al, bl), band(al, cl), band(bl, cl))
    local t2h = s0h + bxor(band(ah, bh), band(ah, ch), band(bh, ch))
    hh, hl, gh, gl, fh, fl = gh, gl, fh, fl, eh, el
    lo = dl + t1l
    eh, el = (dh + t1h + math.floor(lo / two32)) % two32, lo % two32
    dh, dl, ch, cl, bh, bl = ch, cl, bh, bl, ah, al
    lo = t1l + t2l
    ah, al = (t1h + t2h + math.floor(lo / two32)) % two32, lo % two32
  end
  local out = { ah, al, bh, bl, ch, cl, dh, dl, eh, el, fh, fl, gh, gl, hh, hl }
  for i = 15, 1, -2 do
    local lo = h[i + 1] + out[i + 1]
    h[i + 1] = lo % two32
    h[i] = (h[i] + out[i] + math.floor(lo / two32)) % two32
  end
end

C.sha512 = function(msg)
  local len, bits, tail = #msg, #msg * 8, {}
  for i = 16, 1, -1 do
    tail[i] = string.char(bits % 256)
    bits = math.floor(bits / 256)
  end
  msg = msg .. "\128" .. string.rep("\0", (111 - len) % 128) .. table.concat(tail)
  local h = {}
  for i = 1, 16 do h[i] = C.H[i] end
  for at = 1, #msg, 128 do C.block(h, msg, at) end
  local out = {}
  for i = 1, 16 do
    local x = h[i]
    out[i] = string.char(bit32.rshift(x, 24), bit32.band(bit32.rshift(x, 16), 255),
      bit32.band(bit32.rshift(x, 8), 255), bit32.band(x, 255))
  end
  return table.concat(out)
end

C.hmac = function(key, msg)
  if #key > 128 then key = C.sha512(key) end
  key = key .. string.rep("\0", 128 - #key)
  local ipad, opad = {}, {}
  for i = 1, 128 do
    local b = key:byte(i)
    ipad[i] = string.char(bit32.bxor(b, 0x36))
    opad[i] = string.char(bit32.bxor(b, 0x5c))
  end
  return C.sha512(table.concat(opad) .. C.sha512(table.concat(ipad) .. msg))
end

-- lv_cat: each string with its LEB128 length in front.
C.lv = function(...)
  local out = {}
  for i = 1, select("#", ...) do
    local s = select(i, ...)
    local n, len = #s, {}
    repeat
      local b = n % 128
      n = (n - b) / 128
      len[#len + 1] = string.char(n > 0 and b + 128 or b)
    until n == 0
    out[i] = table.concat(len) .. s
  end
  return table.concat(out)
end

-- map_to_curve_elligator2 for curve25519 (RFC 9380 section 6.7.1, Z = 2).
C.ell2 = function(u)
  local fp = S.fp
  local A = fp.num(486662)
  local negA = fp.carry(fp.neg(A))
  local x1 = fp.mul(negA, fp.invert(fp.carry(fp.add(fp.num(1), fp.kmul(fp.square(u), 2)))))
  if fp.eqz(x1) then x1 = negA end
  local gx1 = fp.mul(x1, fp.carry(fp.add(fp.carry(fp.add(fp.square(x1), fp.kmul(x1, 486662))), fp.num(1))))
  if fp.sqrtDiv(gx1, fp.num(1)) then return x1 end
  return fp.carry(fp.sub(fp.carry(fp.neg(x1)), A))
end

C.generator = function(prs, ci, sid)
  local dsi = "CPace255"
  local pad = math.max(0, 128 - 1 - #C.lv(prs) - #C.lv(dsi))
  local hash = C.sha512(C.lv(dsi, prs, string.rep("\0", pad), ci, sid)):sub(1, 32)
  return S.fp.encode(C.ell2(S.fp.decode(hash)))
end

-- The client is the initiator. CI binds both computer ids to their roles.
C.ci = function(clientId, serverId)
  return C.lv("so-pair2", tostring(clientId), tostring(serverId))
end

C.share = function(prs, ci, sid, y)
  y = y or S.rnd.random(32)
  return y, S.x.exchange(y, C.generator(prs, ci, sid))
end

C.isk = function(y, other, sid, ya, yb)
  local k = S.x.exchange(y, other)
  if k == string.rep("\0", 32) then return nil end
  return C.sha512(C.lv("CPace255_ISK", sid, k) .. C.lv(ya, "") .. C.lv(yb, ""))
end

C.tags = function(isk, sid, ya, yb)
  local key = C.sha512("CPaceMac" .. sid .. isk)
  return C.hmac(key, C.lv(ya, "")), C.hmac(key, C.lv(yb, ""))
end

-- HKDF-SHA512 (RFC 5869) with an empty salt, 32 bytes of output.
C.machine = function(isk)
  local prk = C.hmac(string.rep("\0", 64), isk)
  return S.proto.hex(C.hmac(prk, "so-pair2 machine key\1"):sub(1, 32))
end

C.same = function(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do
    if a:byte(i) ~= b:byte(i) then diff = diff + 1 end
  end
  return diff == 0
end

M.cpace = C
-- The stored machine key format, 64 hex, for every pairing path.
M.machineKey = C.machine

local function raw32(hex)
  if type(hex) ~= "string" or #hex ~= 64 then return nil end
  local ok, raw = pcall(S.proto.unhex, hex)
  if not ok or type(raw) ~= "string" or #raw ~= 32 then return nil end
  return raw
end

local function proofFor(code, clientPk, serverPk)
  return S.proto.hex(S.proto.hmac(code, S.proof .. clientPk .. serverPk))
end

local function loadCrypto()
  if S.x then return end
  if type(package) ~= "table" then package = { loaded = {}, path = "", preload = {} } end
  package.loaded = package.loaded or {}
  package.preload = package.preload or {}
  if type(package.path) ~= "string" then package.path = "" end
  if not package.path:find("lib/?.lua", 1, true) then
    package.path = "lib/?.lua;" .. package.path
  end
  if not package.preload["cc.expect"] then
    package.preload["cc.expect"] = function()
      local function expect(index, value, ...)
        local got = type(value)
        for i = 1, select("#", ...) do
          if got == select(i, ...) then return value end
        end
        error("bad argument #" .. tostring(index), 3)
      end
      return { expect = expect }
    end
  end
  if type(require) ~= "function" then
    function require(name)
      local loaded = package.loaded[name]
      if loaded ~= nil then return loaded end
      local preload = package.preload[name]
      if preload then
        local result = preload(name)
        if result == nil then result = true end
        package.loaded[name] = result
        return result
      end
      local rel = (name:gsub("%.", "/"))
      for pattern in package.path:gmatch("[^;]+") do
        if pattern ~= "" then
          local path = pattern:gsub("%?", rel)
          if fs.exists(path) then
            package.loaded[name] = false
            local result = dofile(path)
            if result == nil then result = true end
            package.loaded[name] = result
            return result
          end
        end
      end
      error("module '" .. name .. "' not found", 2)
    end
  end
  S.x = require("ccryptolib.x25519")
  S.fp = require("ccryptolib.internal.fp")
  S.rnd = require("ccryptolib.random")
  require("ccryptolib.config").usePeripherals(false)
  if not S.rnd.isInit() then
    local material = table.concat({
      tostring(os.epoch("utc")),
      tostring(os.clock()),
      tostring({}),
      tostring(math.random(0, 16777215)),
      tostring(os.getComputerID()),
    }, "|")
    -- Timing noise can fail. The mix string still seeds the generator.
    pcall(S.rnd.initWithTiming)
    if S.rnd.isInit() then S.rnd.mix(material) else S.rnd.init(material) end
  end
end

M.open = function(proto, store, now)
  S.now = now or function() return math.floor(os.clock() * 1000 + 0.5) end
  S.proto = proto
  loadCrypto()
  S.box = store.store("so-keys", function(v)
    return type(v) == "table" and type(v.keys) == "table"
  end, 200000)
  S.keys = {}
  if S.box.value and type(S.box.value.keys) == "table" then
    for id, key in pairs(S.box.value.keys) do S.keys[tostring(id)] = key end
  end
  proto.bind(function(id) return S.keys[tostring(id)] end)
  S.envelope = proto.hex(proto.sha256("so-pair2 envelope\0"))
end

-- pair2 envelopes use this public MAC key; CPace carries the secret.
M.envelopeKey = function() return S.envelope end

M.derive = function(code, serverId, clientId)
  local material = S.hs .. tostring(serverId) .. "\0" .. tostring(clientId) .. "\0" .. tostring(code)
  return S.proto.hex(S.proto.sha256(material))
end

M.pending = function()
  local slot = S.pending
  if type(slot) ~= "table" then return nil end
  if S.now() >= slot.exp then
    S.pending = nil
    return nil
  end
  return slot.code
end

M.clear = function()
  S.pending = nil
  S.sessions = {}
end
M.key = function(id) return S.keys[tostring(id)] end
M.repairHint = function(sender, payload, server)
  return server ~= nil and sender == server and M.key(server) ~= nil
    and type(payload) == "table" and payload.from == server
    and payload.t == "pair.required"
end
M.peer = function()
  local first
  for id in pairs(S.keys) do
    local n = tonumber(id)
    if n and (not first or n < first) then first = n end
  end
  return first
end

M.remember = function(id, key)
  local name = tostring(id)
  local old = S.keys[name]
  S.keys[name] = key
  local copy = {}
  for k, v in pairs(S.keys) do copy[k] = v end
  local ok, err = S.box.save({ keys = copy })
  if not ok then
    if old == nil then S.keys[name] = nil else S.keys[name] = old end
    return false, err
  end
  return true
end

M.session = function(clientPubHex)
  local code = M.pending()
  if not code then return nil, "code" end
  local raw = raw32(clientPubHex)
  if not raw then return nil, "pub" end
  local slot = S.pending
  local shared = S.x.exchange(slot.sk, raw)
  return S.proto.hex(S.proto.sha256(shared)), {
    ok = true,
    pub = S.proto.hex(slot.pk),
    proof = proofFor(code, raw, slot.pk),
  }
end

local function recent(name, now)
  local list, kept = S.recent[name] or {}, {}
  for i = 1, #list do
    if now - list[i] < S.window then kept[#kept + 1] = list[i] end
  end
  S.recent[name] = kept[1] and kept or nil
  return kept
end

local function note(name)
  local list = recent(name, S.now())
  list[#list + 1] = S.now()
  S.recent[name] = list
end

-- A sender is blocked after S.tries starts or rejections inside S.window,
-- or after S.tries failed guesses at the live code.
M.blocked = function(id)
  local name, slot = tostring(id), S.pending
  if slot and (slot.fails[name] or 0) >= S.tries then return true end
  return #recent(name, S.now()) >= S.tries
end

-- The pairing budget, shared by every pairing handler.
-- kind "start" admits a new exchange: false when the sender or all senders
-- are over budget. kind "reject" records a rejected message and kind
-- "guess" a failed guess at the live code. A guess counts toward the code
-- unless its sender proved it is paired; the S.burn-th clears it. Both
-- return true, then true when they burned the code.
M.charge = function(id, kind, paired)
  local name, slot = tostring(id), S.pending
  if kind == "start" then
    if M.blocked(id) or #recent("*", S.now()) >= S.flood then return false end
    for other in pairs(S.recent) do recent(other, S.now()) end
    note(name)
    note("*")
    return true
  end
  note(name)
  if not slot then return true, false end
  local listed = false
  for i = 1, #slot.rejected do
    if slot.rejected[i] == id then listed = true end
  end
  if not listed then
    slot.rejected[#slot.rejected + 1] = id
    if #slot.rejected > 4 then table.remove(slot.rejected, 1) end
  end
  if kind ~= "guess" then return true, false end
  slot.fails[name] = (slot.fails[name] or 0) + 1
  if paired then return true, false end
  slot.misses = slot.misses + 1
  if slot.misses < S.burn then return true, false end
  M.clear()
  return true, true
end

M.rejected = function()
  local out, slot = {}, S.pending
  if slot then
    for i = 1, #slot.rejected do out[i] = slot.rejected[i] end
  end
  return out
end

-- A paired client proves it holds its saved key with body.auth.
-- Sender ids alone can be forged.
local function auth(key, sid, share)
  return S.proto.hex(S.proto.hmac(S.proto.unhex(key), "so-pair2 auth\0" .. sid .. share))
end

-- Server side of pair2 step 1: body { sid, y, auth? } from the client.
M.start = function(from, body)
  local code = M.pending()
  if not code then return nil, "code" end
  if not M.charge(from, "start") then return nil, "wait" end
  for name, slot in pairs(S.sessions) do
    if S.now() - slot.at > S.window then S.sessions[name] = nil end
  end
  local sid = type(body) == "table" and type(body.sid) == "string" and #body.sid == 32
    and body.sid:match("^%x+$") and S.proto.unhex(body.sid)
  local ya = type(body) == "table" and raw32(body.y)
  if not sid or not ya then return nil, "body" end
  local yb, own = C.share(code, C.ci(from, os.getComputerID()), sid)
  local isk = C.isk(yb, ya, sid, ya, own)
  if not isk then return nil, "share" end
  local ta, tb = C.tags(isk, sid, ya, own)
  local key = S.keys[tostring(from)]
  local paired = key ~= nil and C.same(body.auth, auth(key, sid, ya))
  S.sessions[tostring(from)] = { sid = sid, ta = ta, tb = tb, isk = isk, code = code,
    at = S.now(), paired = paired }
  return { y = S.proto.hex(own) }
end

-- Server side of pair2 step 2: body { sid, tag }. One check per session.
-- Returns the machine key and the reply body; on "tag" also whether the
-- sender proved it is paired.
M.confirm = function(from, body)
  local name = tostring(from)
  local slot = S.sessions[name]
  if not slot or type(body) ~= "table" or body.sid ~= S.proto.hex(slot.sid) then
    return nil, "session"
  end
  S.sessions[name] = nil
  if slot.code ~= M.pending() or S.now() - slot.at > S.window then return nil, "session" end
  local tag = type(body.tag) == "string" and #body.tag == 128 and body.tag:match("^%x+$")
    and S.proto.unhex(body.tag)
  if not C.same(tag, slot.ta) then return nil, "tag", slot.paired end
  return M.machineKey(slot.isk), { ok = true, tag = S.proto.hex(slot.tb) }
end

M.invite = function(screen)
  loadCrypto()
  local raw = S.rnd.random(4)
  local n = raw:byte(1) * 16777216 + raw:byte(2) * 65536 + raw:byte(3) * 256 + raw:byte(4)
  local code = string.format("%06d", n % 1000000)
  local sk = S.rnd.random(32)
  S.sessions = {}
  S.pending = {
    code = code,
    exp = S.now() + S.life,
    sk = sk,
    pk = S.x.publicKey(sk),
    misses = 0,
    fails = {},
    rejected = {},
  }
  local line = "Pair code: " .. code .. " server " .. tostring(os.getComputerID())
  print(line)
  if screen and screen.clear then
    screen.clear()
    screen.setCursorPos(1, 1)
    screen.write(line)
  end
  return code
end

local function failure(reply, err)
  local body = reply and type(reply.body) == "table" and reply.body or {}
  local why = reply and reply.t == "err" and body.text or err
  if why == "tag" then return "wrong code" end
  if why == "code" then return "no code" end
  if why == "wait" then return "busy" end
  return tostring(why or "pair failed")
end

-- Client side of pair2. Returns the machine key, or nil and a reason.
local function cpace(code, server, name, previous)
  local sid = S.rnd.random(16)
  local ya, own = C.share(code, C.ci(os.getComputerID(), server), sid)
  local body = { sid = S.proto.hex(sid), y = S.proto.hex(own) }
  if previous then body.auth = auth(previous, sid, own) end
  S.keys[name] = S.envelope
  local first, err = S.proto.request(server, "pair2", body, 3, 2)
  if not first then return nil, err end
  local yb = first.t == "ack" and type(first.body) == "table" and raw32(first.body.y)
  if not yb then return nil, failure(first, "pub") end
  local isk = C.isk(ya, yb, sid, own, yb)
  if not isk then return nil, "share" end
  local ta, tb = C.tags(isk, sid, own, yb)
  local second, err2 = S.proto.request(server, "pair2",
    { sid = S.proto.hex(sid), tag = S.proto.hex(ta) }, 3, 2)
  body = second and second.t == "ack" and type(second.body) == "table" and second.body
  if not body or body.ok ~= true then return nil, failure(second, err2) end
  local tag = type(body.tag) == "string" and #body.tag == 128 and body.tag:match("^%x+$")
    and S.proto.unhex(body.tag)
  if not C.same(tag, tb) then return nil, "proof" end
  return M.machineKey(isk)
end

M.join = function(code, serverId)
  if not S.proto then return nil, "not open" end
  if type(code) ~= "string" or not code:match("^%d%d%d%d%d%d$") then return nil, "code" end
  local server = serverId
  if server == nil then server = rednet.lookup("so", "server") end
  if type(server) ~= "number" then return nil, "no server" end
  loadCrypto()
  local name = tostring(server)
  local previous = S.keys[name]
  local machine, err = cpace(code, server, name, previous)
  if not machine then
    S.keys[name] = previous
    return nil, err
  end
  local ok, saveErr = M.remember(server, machine)
  if not ok then
    S.keys[name] = previous
    return nil, saveErr
  end
  return true
end

return M
