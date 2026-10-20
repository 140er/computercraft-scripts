-- Stub of the W1 settings registry. W1 owns the real registry.
-- Callers use forBot(role) and effective(stored). Revision 4 is the plan's sample.

local M = { v = 1, revision = 4 }

local DEFAULTS = {
  miner = { returnHome = true, branchLength = 64, reach = 96, tripSeconds = 900 },
}

function M.forBot(role)
  if type(role) ~= "string" or not DEFAULTS[role] then return nil, "unknown role" end
  return { revision = M.revision, overrides = {} }
end

function M.effective(role, stored)
  local base = DEFAULTS[role]
  if not base or type(stored) ~= "table" or stored.revision ~= M.revision then
    return nil, "unknown settings"
  end
  local values = {}
  for key, value in pairs(base) do values[key] = value end
  for key, value in pairs(stored.overrides or {}) do values[key] = value end
  return { revision = stored.revision, values = values }
end

return M
