-- Stub for I1 copy-code records. enrol.lua replaces this file.
-- S1 stores codes and migrates them. The MAC over the enrolment transcript stays with I1.
local M = { version = 1, item = "I1", replacedBy = "enrol.lua" }

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

function M.code(c)
  if type(c) ~= "table" or c.v ~= 1 then return false end
  if type(c.code) ~= "string" or not c.code:match("^[A-Z2-7]+$") or #c.code < 10 or #c.code > 16 then return false end
  if not integer(c.issuer, 0, 2147483647) then return false end
  if not integer(c.issuedAt, 0, 9007199254740991) or not integer(c.untilAt, 0, 9007199254740991) then return false end
  if type(c.role) ~= "string" or #c.role == 0 or #c.role > 32 then return false end
  if type(c.used) ~= "boolean" or not integer(c.attempts, 0, 5) then return false end
  if not (c.planBot == false or (type(c.planBot) == "string" and c.planBot:match("^p:%d+:%d+$"))) then return false end
  if c.claiming ~= nil and type(c.claiming) ~= "boolean" then return false end
  if c.invalidated ~= nil and type(c.invalidated) ~= "boolean" then return false end
  return true
end

-- Present and bounded. I1 verifies the keyed MAC. This stub only checks the slot is filled.
function M.proof(proof)
  return type(proof) == "string" and #proof > 0 and #proof <= 128
end

return M
