-- Stub for H5 lease expiry. H5 replaces this file.
-- B1 stops using the cells. H5 frees scheduling claims and keeps physical occupancy unknown.
local M = {}

function M.fence(lease, now)
  return {
    v = 1,
    lease = lease.id,
    turtle = lease.turtle,
    at = now,
    overdue = true,
    fence = true,
    claims = "release",
    occupancy = "unknown",
  }
end

return M
