-- Stub for W1 settings registry. W1 (wh2-fleet.lua) replaces this file.
local M = {}

M.keys = {
  offlineAutonomy = "boolean",
  checkInEveryMs = "ms",
  leaseMs = "lease",
  returnMarginMs = "margin",
  journalMaxEvents = "events",
  journalMaxBytes = "bytes",
}

local defaults = {
  offlineAutonomy = false,
  checkInEveryMs = 60000,
  leaseMs = 900000,
  returnMarginMs = 120000,
  journalMaxEvents = 1024,
  journalMaxBytes = false,
}

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function check(key, value, values)
  local kind = M.keys[key]
  if not kind then return false, "unknown setting" end
  if kind == "boolean" then
    if type(value) ~= "boolean" then return false, "invalid " .. key end
  elseif kind == "bytes" then
    if value ~= false and not integer(value, 4096, 262144) then return false, "invalid " .. key end
  elseif kind == "events" then
    if not integer(value, 1, 4096) then return false, "invalid " .. key end
  elseif kind == "ms" then
    if not integer(value, 1000, 3600000) then return false, "invalid " .. key end
  elseif kind == "lease" then
    if not integer(value, 60000, 3600000) then return false, "invalid " .. key end
  elseif kind == "margin" then
    if not integer(value, 1000, 3600000) then return false, "invalid " .. key end
  end
  return true
end

function M.defaults()
  local out = {}
  for k, v in pairs(defaults) do out[k] = v end
  return out
end

function M.snapshot(revision, overrides)
  if revision ~= nil and not integer(revision, 0, 2147483647) then return nil, "invalid settings revision" end
  local values = M.defaults()
  if overrides ~= nil then
    if type(overrides) ~= "table" then return nil, "invalid settings" end
    for key, value in pairs(overrides) do
      local ok, why = check(key, value, values)
      if not ok then return nil, why end
      values[key] = value
    end
  end
  if values.checkInEveryMs >= values.leaseMs - values.returnMarginMs then
    return nil, "check-in does not fit the lease"
  end
  return { revision = revision or 0, values = values }
end

return M
