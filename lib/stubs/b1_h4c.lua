-- Stub for H4c storage ledger. H4c replaces this file.
-- The journal budget is free space after the reserves H4c measures. This stub only subtracts what the caller passes.
local M = {}

function M.policy()
  return { v = 1, mode = "ask", warnAt = 0.8, forgetOlderThanMs = false, controlReserve = 65536 }
end

function M.journalBudget(spec)
  spec = spec or {}
  if type(spec.budget) == "number" then return spec.budget end
  local free = spec.freeBytes
  if free == "unlimited" then free = 90000 end
  if type(free) ~= "number" or free ~= free or free < 0 then return 0 end
  local policy = spec.policy or M.policy()
  local reserve = (policy.controlReserve or 0) + (spec.navBytes or 0) + (spec.codeBytes or 0)
    + (spec.stagingBytes or 0) + (spec.pendingBytes or 0) + (spec.returnReserve or 0)
  local budget = free - reserve
  if budget < 0 then budget = 0 end
  if type(spec.ceiling) == "number" and spec.ceiling >= 0 and spec.ceiling < budget then budget = spec.ceiling end
  return budget
end

return M
