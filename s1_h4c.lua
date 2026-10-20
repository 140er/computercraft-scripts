-- Stub for the H4c storage ledger. H4c's ledger replaces this file.
-- The hub uses the same policy shape with a smaller budget and no peers.
local M = { version = 1, item = "H4c", replacedBy = "H4c storage ledger" }

function M.policy(profile)
  local hub = profile == "hub"
  return {
    v = 1, mode = "ask", warnAt = 0.8, forgetOlderThanMs = false, controlReserve = 65536,
    budget = hub and 300000 or 900000,
    peers = false,
    expand = hub and "server" or "storage-turtles",
  }
end

function M.ledger(used, policy)
  local total = policy.budget
  local ratio = total > 0 and used / total or 1
  local state = "ok"
  if ratio >= 1 then state = "paused"
  elseif ratio >= policy.warnAt then state = "warn" end
  return {
    v = 1, localTotal = total, localUsed = used, peerTotal = 0, peerUsed = 0,
    growthPerHour = 0, state = state,
  }
end

return M
