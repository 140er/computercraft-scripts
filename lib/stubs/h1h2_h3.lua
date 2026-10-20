-- Stub for H3 (feat/hard-h3). H1H2 admits each MAC check through this
-- boundary. H3 replaces this file with the 32-slot worker coroutine.
-- This stub does not run a worker, move mirror or http work, or reply busy
-- on the wire. admit takes one slot. finish releases it.
local LIMIT = 32
local M = { limit = LIMIT }

function M.new()
  return { n = 0 }
end

function M.admit(q)
  if type(q) ~= "table" or (q.n or 0) >= LIMIT then return nil, "busy" end
  q.n = (q.n or 0) + 1
  return true
end

function M.finish(q)
  if type(q) == "table" and type(q.n) == "number" and q.n > 0 then q.n = q.n - 1 end
end

return M
