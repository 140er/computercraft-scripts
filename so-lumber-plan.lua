local L = {}

function L.isLog(block)
  return type(block) == "table" and type(block.name) == "string"
    and not block.name:find("dark_oak", 1, true)
    and block.tags ~= nil and block.tags["minecraft:logs"] == true
end

function L.isLeaves(block)
  return type(block) == "table" and type(block.name) == "string"
    and ((block.tags and block.tags["minecraft:leaves"] == true) or block.name:match("_leaves$") ~= nil)
end

function L.isSapling(name)
  return type(name) == "string" and (name:match("_sapling$") ~= nil or name == "minecraft:mangrove_propagule")
end

function L.saplingFor(name)
  if name == "minecraft:mangrove_log" then return "minecraft:mangrove_propagule" end
  return type(name) == "string" and (name:gsub("_log$", "_sapling")) or nil
end

function L.canDig(block)
  if L.isLog(block) or L.isLeaves(block) then return true end
  local plants = {
    ["minecraft:short_grass"] = true, ["minecraft:grass"] = true,
    ["minecraft:tall_grass"] = true, ["minecraft:fern"] = true,
    ["minecraft:large_fern"] = true, ["minecraft:dead_bush"] = true,
    ["minecraft:vine"] = true,
  }
  return type(block) == "table" and plants[block.name] == true
end

function L.scan(area, ground, dim)
  local out = {}
  local reverse = false
  for row = area.z1, area.z2, 3 do
    local z = math.min(row + 1, area.z2)
    for x = reverse and area.x2 or area.x1, reverse and area.x1 or area.x2, reverse and -1 or 1 do
      out[#out + 1] = { dim = dim, x = x, y = ground + 2, z = z, facing = reverse and 3 or 1 }
    end
    reverse = not reverse
  end
  return out
end

function L.access(point, near, blocked)
  local candidates = {}
  if point.side == "down" then
    candidates[1] = { dim = point.dim, x = point.x, y = point.y + 1, z = point.z }
  else
    for f, offset in ipairs({ {0, -1}, {1, 0}, {0, 1}, {-1, 0} }) do
      candidates[#candidates + 1] = {
        dim = point.dim, x = point.x + offset[1], y = point.y, z = point.z + offset[2],
        facing = (f + 1) % 4,
      }
    end
  end
  local best
  for _, cell in ipairs(candidates) do
    if not blocked or not blocked(cell) then
      if not best or (near and L.distance(cell, near) < L.distance(best, near)) then best = cell end
    end
  end
  return best
end

function L.travel(from, target, ground)
  if from.x ~= target.x or from.z ~= target.z then
    if from.y ~= ground + 2 then
      return { dim = from.dim, x = from.x, y = ground + 2, z = from.z }
    end
    return { dim = target.dim, x = target.x, y = ground + 2, z = target.z }
  end
  return target
end

function L.distance(a, b)
  return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

return L
