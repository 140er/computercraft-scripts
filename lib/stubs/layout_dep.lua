-- Schema-1 chunk reader for layout path checks.
-- H4b1 replaces this with palette and RLE sections. Relative frames stay unknown.

local M = {}

local function integer(n)
  return type(n) == "number" and n == n and n % 1 == 0
end

function M.observe(s, pos)
  if type(s) ~= "table" or type(s.chunks) ~= "table" or type(pos) ~= "table" then return nil end
  if pos.frame ~= "abs" then return nil end
  if not integer(pos.x) or not integer(pos.y) or not integer(pos.z) or type(pos.dim) ~= "string" then return nil end
  local key = pos.dim .. "|" .. math.floor(pos.x / 16) .. "|" .. math.floor(pos.y / 16) .. "|" .. math.floor(pos.z / 16)
  local ch = s.chunks[key]
  if type(ch) ~= "table" or type(ch.cells) ~= "table" then return nil end
  local index = pos.x % 16 + 16 * (pos.z % 16) + 256 * (pos.y % 16) + 1
  local stored = ch.cells[index]
  if stored == nil then return nil end
  if stored == 0 then return "minecraft:air" end
  if type(s.names) ~= "table" or type(s.names[stored]) ~= "string" then return nil end
  return s.names[stored]
end

return M
