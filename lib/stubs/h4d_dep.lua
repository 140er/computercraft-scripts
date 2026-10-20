-- H4d dependency shims. Each table is the interface that item owns.
-- H4a replaces h4a with ssot-storage.lua (capacity, control reserve, durable save).
-- H4b1 replaces h4b1 with chunk-store.lua (real section bytes and sha256). The codec
-- here is an opaque stand-in, not palette plus RLE.
-- B2 replaces b2. B1 owns the lease record; this only answers the offline-lease bit.
-- H1 replaces h1 with ssot-auth.lua (keyed BLAKE3, pairing, randomness).

local M = { item = "h4d" }

local function mix(text)
  local h = 5381
  for i = 1, #text do
    h = (h * 33 + text:byte(i)) % 4294967296
  end
  return string.format("%08x", h)
end

M.h4a = {
  controlReserve = function() return 65536 end,
  capacity = function(fsapi, path)
    path = path or "/"
    local cap = fsapi.getCapacity(path)
    local free = fsapi.getFreeSpace(path)
    local unlimited = cap == "unlimited" or free == "unlimited"
    return {
      total = type(cap) == "number" and cap or 0,
      free = type(free) == "number" and free or 0,
      unlimited = unlimited and true or false,
    }
  end,
  save = function(fsapi, path, text)
    local handle = fsapi.open(path, "w")
    if not handle then return false, "open failed" end
    handle.write(text)
    handle.close()
    return true
  end,
}

M.h4b1 = {
  codec = "h4b1-stub",
  hash = function(body)
    if type(body) ~= "string" then return nil end
    return "stub-" .. mix(body)
  end,
  encode = function(section)
    if type(section) ~= "table" or type(section.key) ~= "string" or type(section.rev) ~= "number" then
      return nil, "invalid section"
    end
    local payload = section.payload
    if payload == nil then payload = "" end
    if type(payload) ~= "string" then return nil, "invalid section" end
    local body = "h4b1-stub\0" .. section.key .. "\0" .. tostring(section.rev) .. "\0" .. payload
    return {
      key = section.key,
      rev = section.rev,
      codec = "h4b1-stub",
      body = body,
      hash = "stub-" .. mix(body),
    }
  end,
  unknown = function(key)
    return { conf = "unknown", key = key }
  end,
}

M.b2 = {
  holdsOfflineLease = function(id, leases)
    return type(leases) == "table" and leases[id] == true
  end,
}

M.h1 = {
  macKind = "missing",
  mac = function()
    return nil, "h1 keyed BLAKE3 is not loaded"
  end,
  paired = function(id, paired)
    return type(paired) == "table" and paired[id] == true
  end,
  random = function()
    return nil, "h1 randomness is not loaded"
  end,
}

return M
