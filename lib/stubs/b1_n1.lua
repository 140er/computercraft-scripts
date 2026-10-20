-- Stub for N1 framed positions. N1 replaces this file.
local M = {}
local vectors = {
  [0] = { 0, 0, -1 }, { 1, 0, 0 }, { 0, 0, 1 }, { -1, 0, 0 },
  [4] = { 0, 1, 0 }, [5] = { 0, -1, 0 },
}

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

function M.pos(p)
  if type(p) ~= "table" or p.v ~= 1 then return false end
  if p.frame ~= "abs" and (type(p.frame) ~= "string" or #p.frame > 64 or not p.frame:match("^f:[%w:_-]+$")) then
    return false
  end
  if type(p.yAbs) ~= "boolean" then return false end
  if type(p.dim) ~= "string" or #p.dim > 80 or not p.dim:match("^[%w_]+:[%w_/.-]+$") then return false end
  if not integer(p.x, -30000000, 30000000) or not integer(p.y, -2048, 2048)
    or not integer(p.z, -30000000, 30000000) or not integer(p.h, 0, 3) then return false end
  if p.conf ~= "certain" and p.conf ~= "suspect" and p.conf ~= "lost" then return false end
  if p.src ~= "gps" and p.src ~= "neighbour" and p.src ~= "radio" and p.src ~= "typed"
    and p.src ~= "reckoned" and p.src ~= "inherited" then return false end
  if not integer(p.anchoredAt, 0, 9007199254740991) then return false end
  return true
end

function M.copy(p)
  return {
    v = 1, frame = p.frame, yAbs = p.yAbs, dim = p.dim,
    x = p.x, y = p.y, z = p.z, h = p.h, conf = p.conf, src = p.src, anchoredAt = p.anchoredAt,
  }
end

function M.same(a, b)
  return type(a) == "table" and type(b) == "table" and a.dim == b.dim and a.x == b.x
    and a.y == b.y and a.z == b.z and (a.frame or "abs") == (b.frame or "abs")
end

function M.certain(p)
  return type(p) == "table" and p.conf == "certain"
end

function M.offset(p, d)
  local v = vectors[d]
  if not v or not M.pos(p) then return nil end
  local out = M.copy(p)
  out.x, out.y, out.z = p.x + v[1], p.y + v[2], p.z + v[3]
  out.src = "reckoned"
  return out
end

return M
