-- Stub for H1's vendored ccryptolib sha256.digest.
-- Replace this file's digest with sha256.digest from the H1 vendor.
-- The bytes are stable and 32 long. They are not SHA-256.

local M = {}

local function mix(h, byte, salt)
  return (h * salt + byte) % 4294967296
end

function M.digest(bytes)
  if type(bytes) ~= "string" then return nil, "bytes" end
  local h = { 2166136261, 2166136261, 2166136261, 2166136261, 2166136261, 2166136261, 2166136261, 2166136261 }
  local salt = { 16777619, 2246822519, 3266489917, 668265263, 374761393, 668265263, 2246822519, 16777619 }
  for i = 1, #bytes do
    local b = bytes:byte(i)
    for k = 1, 8 do h[k] = mix(h[k], b + (i % 251), salt[k]) end
  end
  local n = #bytes
  local out = {}
  for k = 1, 8 do
    local v = (h[k] + n * k) % 4294967296
    out[#out + 1] = string.char(
      math.floor(v / 16777216) % 256,
      math.floor(v / 65536) % 256,
      math.floor(v / 256) % 256,
      v % 256)
  end
  return table.concat(out)
end

function M.hex(raw)
  if type(raw) ~= "string" then return nil end
  local parts = {}
  for i = 1, #raw do parts[i] = string.format("%02x", raw:byte(i)) end
  return table.concat(parts)
end

return M
