-- H1H2: keyed BLAKE3 request MACs and one Ed25519 signature on the manifest.
-- requireMac defaults off. The Ed25519 secret stays in ssot.sign and never
-- goes on the wire. H3's queue is the stub in lib/stubs/h1h2_h3.lua.
local M = { COUNTER_CEILING = 2147483647 }

local blake, ed, random
local kdf

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function ensureOs(o)
  if type(o) ~= "table" then return end
  if type(o.epoch) ~= "function" then o.epoch = function() return 0 end end
  if type(o.day) ~= "function" then o.day = function() return 0 end end
  if type(o.time) ~= "function" then o.time = function() return 0 end end
end

local function fileThere(api, path)
  if not (api and api.exists and api.exists(path)) then return false end
  if api.isDir and api.isDir(path) then return false end
  return true
end

-- bios dofile loads into _G, and _G has no package. The shell injects require
-- only into program environments. A test env's fs is a mock, so the ROM copy
-- is read through the real computer fs.
local function ensurePackage()
  local env = _ENV
  if type(package) == "table" and type(require) == "function" then
    if env.package == nil then env.package = package end
    if env.require == nil then env.require = require end
    return
  end
  local disk, loader = fs, loadfile
  if not fileThere(disk, "/rom/modules/main/cc/expect.lua") then
    disk, loader = rawget(_G, "fs"), rawget(_G, "loadfile")
  end
  if not (fileThere(disk, "/rom/modules/main/cc/expect.lua") and type(loader) == "function") then
    error("package is unavailable", 2)
  end
  local pkg = {
    loaded = {},
    preload = {},
    path = "/?.lua;/?/init.lua;/rom/modules/main/?.lua;/rom/modules/main/?/init.lua",
  }
  local function req(name)
    if pkg.loaded[name] ~= nil then return pkg.loaded[name] end
    if pkg.preload[name] then
      local result = pkg.preload[name](name)
      if result == nil then result = true end
      pkg.loaded[name] = result
      return result
    end
    local fname = (name:gsub("%.", "/"))
    local path
    for pattern in pkg.path:gmatch("[^;]+") do
      local candidate = pattern:gsub("%?", fname)
      if fileThere(disk, candidate) then path = candidate break end
    end
    if not path then error("module '" .. name .. "' not found", 2) end
    local fn, err = loader(path, nil, env)
    if not fn then error(err, 2) end
    local sentinel = {}
    pkg.loaded[name] = sentinel
    local ok, result = pcall(fn, name)
    if not ok then
      pkg.loaded[name] = nil
      error(result, 0)
    end
    if result == nil then result = true end
    pkg.loaded[name] = result
    return result
  end
  env.require, env.package = req, pkg
  if rawget(_G, "require") == nil then _G.require = req end
  if rawget(_G, "package") == nil then _G.package = pkg end
end

local function ensureExpect()
  ensurePackage()
  if package.loaded["cc.expect"] then return end
  local ok = pcall(require, "cc.expect")
  if ok then return end
  package.preload["cc.expect"] = function()
    local function expect(_, value, ...)
      local got = type(value)
      for i = 1, select("#", ...) do
        if got == select(i, ...) then return value end
      end
      error("bad argument (" .. table.concat({ ... }, " or ") .. " expected, got " .. got .. ")", 3)
    end
    return { expect = expect }
  end
end

local function loadCrypto()
  if blake then return end
  ensureOs(os)
  ensureOs(_G.os)
  ensureExpect()
  if not package.path:find("./?.lua", 1, true) then
    package.path = "./?.lua;./?/init.lua;" .. package.path
  end
  blake = require("ccryptolib.blake3")
  ed = require("ccryptolib.ed25519")
  random = require("ccryptolib.random")
  kdf = blake.deriveKey("computercraft-scripts ssot mac v2")
end

function M.canonical(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local keys, parts = {}, {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) < type(b)
  end)
  for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. M.canonical(k) .. "]=" .. M.canonical(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.toHex(s)
  local parts = {}
  for i = 1, #s do parts[i] = string.format("%02x", s:byte(i)) end
  return table.concat(parts)
end

function M.fromHex(hex)
  if type(hex) ~= "string" or #hex % 2 ~= 0 or not hex:match("^[0-9a-f]+$") then return nil end
  local out = {}
  for i = 1, #hex, 2 do out[#out + 1] = string.char(tonumber(hex:sub(i, i + 1), 16)) end
  return table.concat(out)
end

local function same(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  for i = 1, #a do
    if a:byte(i) ~= b:byte(i) then return false end
  end
  return true
end

-- MAC text is rid|counter|op|canonical body. counterEpoch is a body field.
function M.macText(msg)
  local body = {}
  for k, v in pairs(msg) do if k ~= "mac" then body[k] = v end end
  return tostring(msg.rid) .. "|" .. tostring(msg.counter) .. "|" .. tostring(msg.op) .. "|" .. M.canonical(body)
end

local function keyBytes(secret)
  loadCrypto()
  return kdf(secret)
end

function M.mac(secret, msg)
  loadCrypto()
  return M.toHex(blake.digestKeyed(keyBytes(secret), M.macText(msg), 32))
end

function M.verifyMac(secret, msg)
  if type(secret) ~= "string" or type(msg) ~= "table" or type(msg.mac) ~= "string" then return false end
  if not msg.mac:match("^[0-9a-f]+$") or #msg.mac ~= 64 then return false end
  return same(M.mac(secret, msg), msg.mac)
end

function M.counterOk(epoch, counter)
  return integer(epoch, 1, 2147483646) and integer(counter, 1, 2147483646)
end

function M.nextCounter(epoch, counter)
  epoch = epoch or 1
  counter = counter or 0
  if not integer(epoch, 1, 2147483646) or not integer(counter, 0, M.COUNTER_CEILING) then
    return nil, "counter epoch exhausted"
  end
  if counter >= 2147483646 then
    if epoch >= 2147483646 then return nil, "counter epoch exhausted" end
    return epoch + 1, 1
  end
  return epoch, counter + 1
end

function M.fresh(client, m)
  client = client or {}
  if m.v == 2 and not M.counterOk(m.counterEpoch or 1, m.counter) then return false end
  if m.v == 2 then
    local storedEpoch = client.counterEpoch or 1
    local epoch = m.counterEpoch or 1
    if epoch > storedEpoch then return true end
    if epoch < storedEpoch then return false end
  end
  return type(m.counter) == "number" and m.counter > (client.counter or 0)
end

local function queue()
  if M._Q then return M._Q end
  local ok, mod = pcall(dofile, "lib/stubs/h1h2_h3.lua")
  if not ok or type(mod) ~= "table" or type(mod.new) ~= "function" then return nil end
  M._Q = mod
  return mod
end

function M.authorize(cfg, id, m, key)
  if cfg and cfg.requireMac == true and m.v ~= 2 then return nil end
  if m.v == 1 then
    if m.secret ~= key then return nil end
    return "v1"
  end
  if m.v ~= 2 or m.secret ~= nil or m.id ~= id then return nil end
  if type(m.mac) ~= "string" or not m.mac:match("^[0-9a-f]+$") or #m.mac ~= 64 then return nil end
  if not M.counterOk(m.counterEpoch or 1, m.counter) then return nil end
  local Q = queue()
  if not Q then return nil end
  M._jobs = M._jobs or Q.new()
  local admitted = Q.admit(M._jobs)
  if not admitted then return nil end
  local ok, good = pcall(M.verifyMac, key, m)
  Q.finish(M._jobs)
  if not ok or not good then return nil end
  return "v2"
end

function M.sealReply(secret, req, result)
  result.auth = nil
  result.secret = nil
  result.v = 2
  result.op = req.op
  result.counter = req.counter
  result.counterEpoch = req.counterEpoch or 1
  result.mac = M.mac(secret, result)
  return result
end

function M.initRandom(seed)
  loadCrypto()
  random.init(seed)
end

function M.publicKey(skHex)
  loadCrypto()
  local sk = M.fromHex(skHex)
  if not sk or #sk ~= 32 then return nil end
  return M.toHex(ed.publicKey(sk))
end

function M.signManifest(skHex, manifest)
  loadCrypto()
  local sk = M.fromHex(skHex)
  if not sk or #sk ~= 32 or type(manifest) ~= "table" then return nil, "invalid manifest key" end
  if not random.isInit() then return nil, "random" end
  local pk = ed.publicKey(sk)
  local signed = {}
  for k, v in pairs(manifest) do if k ~= "sig" and k ~= "sk" then signed[k] = v end end
  signed.sig = M.toHex(ed.sign(sk, pk, M.canonical(signed)))
  return signed, M.toHex(pk)
end

function M.manifestText(manifest)
  local body = {}
  for k, v in pairs(manifest) do if k ~= "sig" then body[k] = v end end
  return M.canonical(body)
end

function M.verifyManifest(pkHex, manifest)
  if type(manifest) ~= "table" or manifest.schema ~= 1 then return false end
  if type(manifest.version) ~= "string" or type(manifest.files) ~= "table" then return false end
  if not integer(manifest.server, 0, M.COUNTER_CEILING) or type(manifest.sig) ~= "string" then return false end
  local pk, sig = M.fromHex(pkHex), M.fromHex(manifest.sig)
  if not pk or #pk ~= 32 or not sig or #sig ~= 64 then return false end
  loadCrypto()
  return ed.verify(pk, M.manifestText(manifest), sig) == true
end

function M.parseManifest(code)
  if type(code) ~= "string" then return nil end
  local fn = load(code, "=bundle-manifest", "t", {})
  if not fn then return nil end
  local ok, value = pcall(fn)
  if ok and type(value) == "table" then return value end
end

local function readHandle(api, path)
  if not (api and api.exists and api.exists(path) and api.open) then return nil end
  local h = api.open(path, "r")
  if not h then return nil end
  local text = h.readAll()
  h.close()
  return text
end

local function readText(path)
  local text = readHandle(fs, path)
  if text ~= nil then return text end
  local gfs = rawget(_G, "fs")
  if gfs ~= fs then
    text = readHandle(gfs, path)
    if text ~= nil then return text end
  end
  if not (io and io.open) then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  text = f:read("*a")
  f:close()
  return text
end

local function parsePin(text)
  if type(text) ~= "string" then return nil end
  local value
  if textutils and textutils.unserialize then
    local ok, parsed = pcall(textutils.unserialize, text)
    if ok then value = parsed end
  end
  if type(value) ~= "table" then
    local fn = load("return " .. text, "=fleet.pin", "t", {})
    if not fn then return nil end
    local ok, parsed = pcall(fn)
    if not ok then return nil end
    value = parsed
  end
  if type(value) ~= "table" or value.v ~= 1 or not integer(value.server, 0, M.COUNTER_CEILING) then return nil end
  if value.pub ~= nil and (type(value.pub) ~= "string" or not value.pub:match("^[0-9a-f]+$") or #value.pub ~= 64) then
    return nil
  end
  if value.sk ~= nil then return nil end
  return value
end

function M.readPin(path)
  if path == nil and M._pin ~= nil then
    if M._pin == false then return nil end
    return M._pin
  end
  return parsePin(readText(path or "fleet.pin"))
end

-- Pinned computer id. Never calls rednet.lookup.
function M.resolveUpdateServer()
  local pin = M.readPin()
  if not pin then return nil end
  return pin.server
end

function M.manifestAllows(name, code, hashOf)
  local pin = M.readPin()
  if not pin or type(pin.pub) ~= "string" then return true end
  if name == "bundle-manifest.lua" then
    local man = M.parseManifest(code)
    if not man or man.server ~= pin.server or not M.verifyManifest(pin.pub, man) then
      M._manifest = nil
      return false
    end
    M._manifest = man
    return true
  end
  local man = M._manifest
  if not man then
    man = M.parseManifest(readText("bundle-manifest.lua"))
    if not man or man.server ~= pin.server or not M.verifyManifest(pin.pub, man) then return false end
    M._manifest = man
  end
  if type(code) ~= "string" or type(hashOf) ~= "function" then return false end
  return man.files[name] == hashOf(code)
end

return M
