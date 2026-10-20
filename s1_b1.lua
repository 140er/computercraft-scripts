-- Stub for B1 lease records. B1 replaces this file.
-- S1 stores the lease and stops issuing one while authority is frozen. It does not move or dig.
local M = { version = 1, item = "B1", replacedBy = "B1 lease v2" }

function M.lease(x)
  return type(x) == "table" and x.v == 2 and type(x.id) == "string" and #x.id > 0 and #x.id <= 80
    and type(x.turtle) == "number" and x.turtle == x.turtle and x.turtle % 1 == 0
    and x.turtle >= 0 and x.turtle <= 2147483647
end

return M
