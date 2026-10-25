local L = {}

L.species = {
  ["minecraft:oak_log"] = "minecraft:oak_leaves",
  ["minecraft:spruce_log"] = "minecraft:spruce_leaves",
  ["minecraft:birch_log"] = "minecraft:birch_leaves",
  ["minecraft:jungle_log"] = "minecraft:jungle_leaves",
  ["minecraft:acacia_log"] = "minecraft:acacia_leaves",
  ["minecraft:cherry_log"] = "minecraft:cherry_leaves",
  ["minecraft:mangrove_log"] = "minecraft:mangrove_leaves",
}

function L.selected(name, species)
  if species == false or species == nil then return true end
  if not L.species[name] then return false end
  for _, log in ipairs(species) do if log == name then return true end end
  return false
end

function L.isLog(block, species)
  return type(block) == "table" and type(block.name) == "string"
    and not block.name:find("dark_oak", 1, true)
    and block.tags ~= nil and block.tags["minecraft:logs"] == true
    and L.selected(block.name, species)
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

function L.canDig(block, species)
  if L.isLog(block, species) then return true end
  if L.isLeaves(block) then
    if species == false or species == nil then return true end
    for _, log in ipairs(species) do if L.species[log] == block.name then return true end end
    return false
  end
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

function L.nextCell(from, target, ground, blocked)
  local function key(p) return p.x .. "," .. p.y .. "," .. p.z end
  local open, seen = { { p = from, cost = 0 } }, { [key(from)] = true }
  for _ = 1, 2048 do
    if #open == 0 then return nil end
    local best = 1
    for i = 2, #open do
      local a, b = open[i], open[best]
      local da, db = L.distance(a.p, target), L.distance(b.p, target)
      if a.cost + da < b.cost + db or a.cost + da == b.cost + db and da < db then best = i end
    end
    local node = table.remove(open, best)
    if L.distance(node.p, target) == 0 then return node.first end
    for _, d in ipairs({ {1,0,0}, {-1,0,0}, {0,0,1}, {0,0,-1}, {0,1,0}, {0,-1,0} }) do
      local p = { dim = from.dim, x = node.p.x + d[1], y = node.p.y + d[2], z = node.p.z + d[3] }
      local atEnd = p.x == target.x and p.z == target.z or p.x == from.x and p.z == from.z
      if not seen[key(p)] and p.y >= math.min(ground + 2, from.y, target.y)
        and p.y <= math.max(ground + 4, from.y, target.y)
        and (p.y >= ground + 2 or atEnd) and not blocked(p) then
        seen[key(p)] = true
        open[#open + 1] = { p = p, cost = node.cost + 1, first = node.first or p }
      end
    end
  end
end

return L
