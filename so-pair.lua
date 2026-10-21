local M = {}
local S = {
  keys = {},
  pending = nil,
  proto = nil,
  box = nil,
  x = nil,
  rnd = nil,
  life = 300000,
  proof = "so-pair-v2\0",
  hs = "so-pair-hs-v2\0",
}

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
  S.rnd = require("ccryptolib.random")
  require("ccryptolib.config").usePeripherals(false)
  if not S.rnd.isInit() then
    local mix = {
      tostring(os.epoch("utc")),
      tostring(os.clock()),
      tostring({}),
      tostring(math.random(0, 16777215)),
      tostring(os.getComputerID()),
    }
    S.rnd.init(table.concat(mix, "|"))
  end
end

M.open = function(proto, store)
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
end

M.derive = function(code, serverId, clientId)
  local material = S.hs .. tostring(serverId) .. "\0" .. tostring(clientId) .. "\0" .. tostring(code)
  return S.proto.hex(S.proto.sha256(material))
end

M.pending = function()
  local slot = S.pending
  if type(slot) ~= "table" then return nil end
  if os.epoch("utc") >= slot.exp then
    S.pending = nil
    return nil
  end
  return slot.code
end

M.clear = function() S.pending = nil end
M.key = function(id) return S.keys[tostring(id)] end

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

M.invite = function(screen)
  loadCrypto()
  local code = string.format("%06d", math.random(0, 999999))
  local sk = S.rnd.random(32)
  S.pending = {
    code = code,
    exp = os.epoch("utc") + S.life,
    sk = sk,
    pk = S.x.publicKey(sk),
  }
  local line = "Pair code: " .. code
  print(line)
  if screen and screen.clear then
    screen.clear()
    screen.setCursorPos(1, 1)
    screen.write(line)
  end
  return code
end

M.join = function(code)
  if not S.proto then return nil, "not open" end
  if type(code) ~= "string" or not code:match("^%d%d%d%d%d%d$") then return nil, "code" end
  local server = rednet.lookup("so", "server")
  if type(server) ~= "number" then return nil, "no server" end
  loadCrypto()
  local name = tostring(server)
  local previous = S.keys[name]
  local sk = S.rnd.random(32)
  local pk = S.x.publicKey(sk)
  S.keys[name] = M.derive(code, server, os.getComputerID())
  local reply, err = S.proto.request(server, "pair", { pub = S.proto.hex(pk) }, 3, 2)
  if not reply or reply.t ~= "ack" or type(reply.body) ~= "table" or reply.body.ok ~= true then
    S.keys[name] = previous
    return nil, err or "pair failed"
  end
  local remote = raw32(reply.body.pub)
  if not remote or reply.body.proof ~= proofFor(code, pk, remote) then
    S.keys[name] = previous
    return nil, "proof"
  end
  local machine = S.proto.hex(S.proto.sha256(S.x.exchange(sk, remote)))
  local ok, saveErr = M.remember(server, machine)
  if not ok then
    S.keys[name] = previous
    return nil, saveErr
  end
  return true
end

return M
