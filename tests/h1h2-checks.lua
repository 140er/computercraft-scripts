-- H1H2 attacker suite. Behavior goes through h1h2.lua, ssot.handle and the client.
if not os.epoch then os.epoch = function() return 0 end end
if not os.day then os.day = function() return 0 end end

local mocks = dofile("tests/mocks.lua")
local host = mocks.new(false)
host.env.dofile = function(path) return assert(loadfile(path, "t", host.env))() end
host.env.os.day = host.env.os.day or function() return 0 end
local S = host.env.dofile("ssot.lua")
local A = host.env.dofile("atomic.lua")
local H = host.env.dofile("h1h2.lua")
local Client = host.env.dofile("ssot-client.lua")
local secret = "test-secret-123456"
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  local line = (ok and "PASS " or "FAIL ") .. name .. (ok and "" or " | " .. tostring(err))
  print(line)
  if fs and fs.open then
    local h = fs.open("h1h2-checks.log", "a")
    if h then h.writeLine(line) h.close() end
  end
  if not ok then failed = failed + 1 end
end

local function pose(x)
  return { dim = "minecraft:overworld", x = x or 0, y = 64, z = 0 }
end

local function slurp(path)
  if fs and fs.open then
    local h = fs.open(path, "r")
    if h then
      local text = h.readAll()
      h.close()
      return text
    end
  end
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local function spit(path, text)
  if fs and fs.open then
    local h = assert(fs.open(path, "w"))
    h.write(text)
    h.close()
    return
  end
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function unspit(path)
  if fs and fs.exists and fs.exists(path) then fs.delete(path) return end
  os.remove(path)
end

local function packet(id, op, counter, fields, epoch)
  epoch = epoch or 1
  local m = A.copy(fields or {})
  m.v, m.type, m.expect, m.op = 2, "ssot", "ssot_reply", op
  m.id, m.boot, m.counter, m.counterEpoch = id, "turtle-" .. id, counter, epoch
  m.rid = m.rid or ("r" .. epoch .. ":" .. counter)
  m.secret = nil
  m.mac = H.mac(secret, m)
  return m
end

local function open(cfg)
  return S.new({}, cfg, function() return 10000 end, "boot-1", function() return true end)
end

test("keyed BLAKE3 and Ed25519 match published vectors", function()
  H.initRandom("h1h2-vector-seed")
  local blake = require("ccryptolib.blake3")
  local ed = require("ccryptolib.ed25519")
  local key = "whats the Elvish word for friend"
  assert(#key == 32)
  assert(H.toHex(blake.digestKeyed(key, "", 32))
    == "92b2b75604ed3c761f9d6f62392c8a9227ad0ea3f09573e783f1498a4ed60d26")
  local sk = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
  local pk = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
  local sig = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
    .. "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
  assert(H.publicKey(sk) == pk)
  assert(ed.verify(H.fromHex(pk), "", H.fromHex(sig)) == true)
  assert(ed.verify(H.fromHex(pk), "x", H.fromHex(sig)) == false)
end)

test("requireMac defaults off and v1 requests still pass", function()
  local cfg = S.config({ controllers = { ["1"] = secret } })
  assert(cfg.requireMac == false)
  assert(not pcall(function() S.config({ controllers = { ["1"] = secret }, requireMac = "yes" }) end))
  local api = open({ controllers = { ["1"] = secret } })
  local m = { v = 1, type = "ssot", expect = "ssot_reply", op = "sync", rid = "v1", counter = 1,
    boot = "turtle-1", secret = secret, pose = pose(0) }
  local r = api.handle(1, m)
  assert(r and r.ok and r.v == 1 and r.auth == secret)
  local mac = packet(1, "sync", 2, { pose = pose(0), rid = "opt" })
  local v2 = api.handle(1, mac)
  assert(v2 and v2.ok and v2.v == 2 and v2.auth == nil and v2.mac)
  assert(not host.env.textutils.serialize(v2):find(secret, 1, true))
end)

test("attacker suite: replay, captured packet, spoofed id, ceiling counter", function()
  local api = open({ controllers = { ["1"] = secret, ["2"] = "other-secret-123456" }, requireMac = true })
  local v1 = { v = 1, type = "ssot", expect = "ssot_reply", op = "sync", rid = "old", counter = 1,
    boot = "turtle-1", secret = secret, pose = pose(4) }
  assert(api.handle(1, v1) == nil)
  assert(api.state().poses[1] == nil)
  local m = packet(1, "sync", 1, { pose = pose(0) })
  assert(m.secret == nil)
  assert(not host.env.textutils.serialize(m):find(secret, 1, true))
  local r = api.handle(1, m)
  assert(r and r.ok and r.v == 2 and r.auth == nil and H.verifyMac(secret, r))
  assert(not host.env.textutils.serialize(r):find(secret, 1, true))
  assert(api.state().poses[1].x == 0)
  local again = api.handle(1, m)
  assert(again and again.mac == r.mac and api.state().seq == 0)
  local flipped = A.copy(m)
  local n = tonumber(flipped.mac:sub(1, 2), 16)
  flipped.mac = string.format("%02x", (n + 1) % 256) .. flipped.mac:sub(3)
  assert(api.handle(1, flipped) == nil)
  local captured = A.copy(m)
  captured.pose = pose(3)
  assert(api.handle(1, captured) == nil)
  assert(api.state().poses[1].x == 0)
  assert(api.handle(2, m) == nil)
  local spoof = A.copy(m)
  spoof.id = 2
  assert(api.handle(2, spoof) == nil)
  local reused = A.copy(m)
  reused.rid = "stolen-rid"
  assert(api.handle(1, reused) == nil)
  for i = 2, 9 do
    assert(api.handle(1, packet(1, "snapshot", i, { chunk = "minecraft:overworld|0|4|0" })).ok)
  end
  assert(api.handle(1, m) == nil)
  assert(api.state().poses[1].x == 0)
  local ceiling = packet(1, "sync", 2147483647, { pose = pose(0) })
  assert(api.handle(1, ceiling) == nil)
  assert(api.handle(1, packet(1, "sync", 10, { pose = pose(0) })).ok)
  assert(api.handle(1, packet(1, "sync", 2147483646, { pose = pose(0) })).ok)
  assert(api.handle(1, ceiling) == nil)
  assert(api.state().clients[1].counter == 2147483646)
  local rolled = packet(1, "sync", 1, { pose = pose(0) }, 2)
  assert(api.handle(1, rolled).ok)
  assert(api.state().clients[1].counterEpoch == 2)
  assert(api.state().clients[1].counter == 1)
  assert(api.state().poses[1].x == 0)
end)

test("honest client rolls the counter and ignores a fake fleetserver", function()
  local api = open({ controllers = { ["99"] = secret }, requireMac = true })
  host.files["roll.counter"] = host.env.textutils.serialize({ schema = 1, generation = 1,
    value = { counter = 2147483645, counterEpoch = 1 } })
  local client = Client.new({ server = 99, secret = secret, requireMac = true,
    counterFile = "roll.counter", timeout = 1 })
  local seen = {}
  local send = host.env.rednet.send
  host.env.rednet.send = function(_, msg, proto)
    seen[#seen + 1] = msg
    assert(msg.v == 2 and msg.secret == nil and msg.id == 99)
    assert(not host.env.textutils.serialize(msg):find(secret, 1, true))
    local reply = assert(api.handle(99, msg))
    local flipped = A.copy(reply)
    local n = tonumber(flipped.mac:sub(1, 2), 16)
    flipped.mac = string.format("%02x", (n + 1) % 256) .. flipped.mac:sub(3)
    assert(client.dispatch(99, flipped, proto) == false)
    assert(client.dispatch(98, reply, proto) == false)
    assert(client.dispatch(99, reply, "minearmy") == false)
    assert(client.dispatch(99, reply, proto) == true)
  end
  local ok, err = pcall(function()
    local p = pose(0)
    assert(client.sync({ pose = p }).ok)
    assert(seen[1].counter == 2147483646 and seen[1].counterEpoch == 1)
    local ceiling = packet(99, "sync", 2147483647, { pose = p, rid = "ceil" })
    assert(api.handle(99, ceiling) == nil)
    assert(client.sync({ pose = p }).ok)
    assert(seen[2].counter == 1 and seen[2].counterEpoch == 2)
    assert(client.sync({ pose = p }).ok)
    assert(seen[3].counter == 2 and seen[3].counterEpoch == 2)
  end)
  host.env.rednet.send = send
  assert(ok, err)
end)

test("manifest signature pins the server id and the secret stays off the manifest", function()
  local sk = "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"
  H.initRandom("h1h2-manifest-seed")
  local manifest = { schema = 1, version = "8152c067", server = 4,
    files = { ["h1h2.lua"] = "deadbeef", ["update.lua"] = "cafebabe" } }
  local signed, pk = H.signManifest(sk, manifest)
  assert(signed and signed.sig and #signed.sig == 128 and signed.sk == nil)
  assert(pk == H.publicKey(sk) and not pk:find(sk, 1, true))
  assert(H.verifyManifest(pk, signed))
  local tampered = A.copy(signed)
  tampered.files = { ["h1h2.lua"] = "00000000", ["update.lua"] = "cafebabe" }
  assert(not H.verifyManifest(pk, tampered))
  tampered = A.copy(signed)
  tampered.server = 5
  assert(not H.verifyManifest(pk, tampered))
  local code = "return " .. H.canonical(signed)
  H._pin = { v = 1, server = 4, pub = pk }
  H._manifest = nil
  assert(H.manifestAllows("bundle-manifest.lua", code, function() return "" end))
  assert(H.manifestAllows("h1h2.lua", "bytes", function() return "deadbeef" end))
  assert(not H.manifestAllows("h1h2.lua", "bytes", function() return "ffffffff" end))
  H._pin = { v = 1, server = 9, pub = pk }
  H._manifest = nil
  assert(not H.manifestAllows("bundle-manifest.lua", code, function() return "" end))
  H._pin = false
  H._manifest = nil
  assert(H.resolveUpdateServer() == nil)
  H._pin = { v = 1, server = 4, pub = pk }
  assert(H.resolveUpdateServer() == 4)
  H._pin = nil
  local pinPath = "h1h2-test.pin"
  spit(pinPath, host.env.textutils.serialize({ v = 1, server = 4, pub = pk, sk = sk }))
  assert(H.readPin(pinPath) == nil)
  spit(pinPath, host.env.textutils.serialize({ v = 1, server = 4, pub = pk }))
  local pin = H.readPin(pinPath)
  unspit(pinPath)
  assert(pin and pin.server == 4 and pin.pub == pk and pin.sk == nil)
end)

test("update never trusts rednet.lookup and the H3 stub bounds the MAC queue", function()
  local src = slurp("update.lua")
  assert(not src:find("rednet.lookup", 1, true))
  assert(src:find("resolveUpdateServer", 1, true))
  local Q = dofile("lib/stubs/h1h2_h3.lua")
  assert(Q.limit == 32)
  local q = Q.new()
  for _ = 1, 32 do assert(Q.admit(q)) end
  local ok, why = Q.admit(q)
  assert(ok == nil and why == "busy")
  Q.finish(q)
  assert(Q.admit(q))
  H._Q = { new = function() return { n = 0 } end, admit = function() return nil, "busy" end, finish = function() end }
  H._jobs = nil
  local cfg = { requireMac = true, controllers = { ["1"] = secret } }
  local m = packet(1, "sync", 1, { pose = pose(0), rid = "queued" })
  assert(H.authorize(cfg, 1, m, secret) == nil)
  H._Q = nil
  H._jobs = nil
  assert(H.authorize(cfg, 1, m, secret) == "v2")
end)

print(failed == 0 and "h1h2 checks passed" or (failed .. " h1h2 checks failed"))
if failed > 0 then error(failed .. " h1h2 checks failed") end
