-- so-pair.lua - one 6-digit code, one key per machine, saved in so-keys.
-- The code stays on the server screen. It is not a message field.

local M = {}
local S = { keys = {}, pending = nil, proto = nil, box = nil }

M.open = function(proto, store)
  S.proto = proto
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
  local material = "so-pair-v1\0" .. tostring(serverId) .. "\0" .. tostring(clientId) .. "\0" .. code
  return S.proto.hex(S.proto.sha256(material))
end

M.pending = function() return S.pending end
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

M.invite = function(screen)
  local code = string.format("%06d", math.random(0, 999999))
  S.pending = code
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
  local key = M.derive(code, server, os.getComputerID())
  S.keys[tostring(server)] = key
  local reply, err = S.proto.request(server, "pair", {}, 3, 2)
  if not reply or reply.t ~= "ack" then
    S.keys[tostring(server)] = nil
    return nil, err or "pair failed"
  end
  local ok, saveErr = M.remember(server, key)
  if not ok then return nil, saveErr end
  return true
end

return M
