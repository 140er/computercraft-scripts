local W = {}
local DX, DZ = { [0] = 0, 1, 0, -1 }, { [0] = -1, 0, 1, 0 }
local DROPS = {
  ["minecraft:stone"] = "minecraft:cobblestone", ["minecraft:deepslate"] = "minecraft:cobbled_deepslate",
  ["minecraft:diamond_ore"] = "minecraft:diamond", ["minecraft:deepslate_diamond_ore"] = "minecraft:diamond",
  ["minecraft:deepslate_redstone_ore"] = "minecraft:redstone", ["minecraft:iron_ore"] = "minecraft:raw_iron",
  ["minecraft:deepslate_iron_ore"] = "minecraft:raw_iron", ["minecraft:grass_block"] = "minecraft:dirt",
}
function W.new(opt)
  opt = opt or {}
  local blocks, chests = {}, {}
  local p = { x = 0, y = 64, z = 0, h = 0 }
  local fuel = opt.fuel or 20000
  local inv, sel = {}, 1
  local delay = opt.delay or 0.05
  local function key(x, y, z) return x .. "," .. y .. "," .. z end
  local function gen(x, y, z)
    if opt.gen then local b = opt.gen(x, y, z) if b ~= nil then return b end end
    if y >= 64 then return false end
    if y == 63 then return "minecraft:grass_block" end
    if y <= -64 then return "minecraft:bedrock" end
    local h = bit32.bxor(x * 374761393 % 4294967296, y * 668265263 % 4294967296, z * 2246822519 % 4294967296)
    h = bit32.bxor(h, bit32.rshift(h, 13)) * 1274126177 % 4294967296
    local hsh = bit32.bxor(h, bit32.rshift(h, 16)) % 400
    if y < 0 then
      if hsh == 3 then return "minecraft:deepslate_diamond_ore" end
      if hsh == 5 then return "minecraft:deepslate_redstone_ore" end
      if hsh == 7 then return "minecraft:deepslate_iron_ore" end
      return "minecraft:deepslate"
    end
    if hsh == 7 then return "minecraft:iron_ore" end
    return "minecraft:stone"
  end
  local function get(x, y, z)
    local k = key(x, y, z)
    if blocks[k] == nil then blocks[k] = gen(x, y, z) end
    return blocks[k]
  end
  local function set(x, y, z, v) blocks[key(x, y, z)] = v end
  for k, v in pairs(opt.blocks or {}) do blocks[k] = v end
  for k, v in pairs(opt.chests or {}) do chests[k] = v blocks[k] = blocks[k] or "minecraft:chest" end
  for i, it in pairs(opt.inventory or {}) do inv[i] = { name = it.name, count = it.count } end
  local function tick()
    if delay > 0 then sleep(delay) return end
    os.queueEvent("world_tick") os.pullEvent("world_tick")
  end
  local function at(dir)
    if dir == "up" then return p.x, p.y + 1, p.z end
    if dir == "down" then return p.x, p.y - 1, p.z end
    local s = dir == "back" and -1 or 1
    return p.x + DX[p.h] * s, p.y, p.z + DZ[p.h] * s
  end
  local function add(name, n)
    n = n or 1
    for i = 1, 16 do
      if inv[i] and inv[i].name == name and inv[i].count < 64 then
        local m = math.min(n, 64 - inv[i].count) inv[i].count = inv[i].count + m n = n - m
        if n == 0 then return true end
      end
    end
    for i = 1, 16 do
      if not inv[i] then inv[i] = { name = name, count = math.min(64, n) } n = n - inv[i].count if n == 0 then return true end end
    end
    return n == 0
  end
  local function move(dir)
    tick()
    if fuel ~= "unlimited" and fuel <= 0 then return false, "Out of fuel" end
    local x, y, z = at(dir)
    if get(x, y, z) then return false, "Movement obstructed" end
    p.x, p.y, p.z = x, y, z
    if fuel ~= "unlimited" then fuel = fuel - 1 end
    return true
  end
  local function dig(dir)
    tick()
    local x, y, z = at(dir)
    local b = get(x, y, z)
    if not b then return false, "Nothing to dig here" end
    if b == "minecraft:bedrock" then return false, "Cannot break unbreakable block" end
    if chests[key(x, y, z)] then return false, "Cannot break block" end
    set(x, y, z, false)
    add(DROPS[b] or b, 1)
    return true
  end
  local function inspect(dir)
    tick()
    local b = get(at(dir))
    if not b then return false, "No block to inspect" end
    return true, { name = b, state = {}, tags = {} }
  end
  local function detect(dir) tick() return get(at(dir)) and true or false end
  local function chestAt(dir) return chests[key(at(dir))] end
  local function drop(dir, n)
    tick()
    local it = inv[sel]
    if not it then return false, "No items to drop" end
    n = math.min(n or it.count, it.count)
    local c = chestAt(dir)
    if c then
      local left = n
      for i = 1, 27 do
        if c[i] and c[i].name == it.name and c[i].count < 64 then
          local m = math.min(left, 64 - c[i].count) c[i].count = c[i].count + m left = left - m
        end
        if left == 0 then break end
      end
      for i = 1, 27 do
        if left == 0 then break end
        if not c[i] then c[i] = { name = it.name, count = left } left = 0 end
      end
      n = n - left
      if n == 0 then return false, "No space for items" end
    end
    it.count = it.count - n
    if it.count == 0 then inv[sel] = nil end
    return true
  end
  local function suck(dir, n)
    tick()
    local c = chestAt(dir)
    if not c then return false, "No items to take" end
    for i = 1, 27 do
      local it = c[i]
      if it then
        local m = math.min(n or 64, it.count)
        local slotIt = inv[sel]
        if slotIt and slotIt.name ~= it.name then
          if not add(it.name, m) then return false, "No space for items" end
        elseif slotIt then
          m = math.min(m, 64 - slotIt.count) if m == 0 then return false, "No space for items" end
          slotIt.count = slotIt.count + m
        else inv[sel] = { name = it.name, count = m } end
        it.count = it.count - m
        if it.count == 0 then c[i] = nil end
        return true
      end
    end
    return false, "No items to take"
  end
  local function place(dir)
    tick()
    local it = inv[sel]
    if not it then return false, "No items to place" end
    local x, y, z = at(dir)
    if get(x, y, z) then return false, "Cannot place block here" end
    local name = it.name
    if name == "minecraft:lava_bucket" or name == "minecraft:water_bucket" then
      it.name = "minecraft:bucket" return true
    end
    if name == "minecraft:bucket" then return false, "Cannot place item here" end
    set(x, y, z, name)
    it.count = it.count - 1
    if it.count == 0 then inv[sel] = nil end
    return true
  end
  local FUEL = { ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:lava_bucket"] = 1000,
    ["minecraft:oak_log"] = 15, ["minecraft:oak_planks"] = 15 }
  local t = {
    forward = function() return move("forward") end, back = function() return move("back") end,
    up = function() return move("up") end, down = function() return move("down") end,
    turnLeft = function() tick() p.h = (p.h + 3) % 4 return true end,
    turnRight = function() tick() p.h = (p.h + 1) % 4 return true end,
    dig = function() return dig("forward") end, digUp = function() return dig("up") end, digDown = function() return dig("down") end,
    detect = function() return detect("forward") end, detectUp = function() return detect("up") end, detectDown = function() return detect("down") end,
    inspect = function() return inspect("forward") end, inspectUp = function() return inspect("up") end, inspectDown = function() return inspect("down") end,
    attack = function() return false, "Nothing to attack here" end, attackUp = function() return false, "Nothing to attack here" end,
    attackDown = function() return false, "Nothing to attack here" end,
    place = function() return place("forward") end, placeUp = function() return place("up") end, placeDown = function() return place("down") end,
    drop = function(n) return drop("forward", n) end, dropUp = function(n) return drop("up", n) end, dropDown = function(n) return drop("down", n) end,
    suck = function(n) return suck("forward", n) end, suckUp = function(n) return suck("up", n) end, suckDown = function(n) return suck("down", n) end,
    select = function(s) sel = s return true end, getSelectedSlot = function() return sel end,
    getItemCount = function(s) local it = inv[s or sel] return it and it.count or 0 end,
    getItemSpace = function(s) local it = inv[s or sel] return it and 64 - it.count or 64 end,
    getItemDetail = function(s) local it = inv[s or sel] return it and { name = it.name, count = it.count } or nil end,
    getFuelLevel = function() return fuel end, getFuelLimit = function() return 100000 end,
    refuel = function(n)
      local it = inv[sel]
      if not it or not FUEL[it.name] then return false, "Items not combustible" end
      if n == 0 then return true end
      local used = math.min(n or it.count, it.count)
      fuel = math.min(100000, fuel + FUEL[it.name] * used)
      if it.name == "minecraft:lava_bucket" then it.name = "minecraft:bucket" else
        it.count = it.count - used if it.count == 0 then inv[sel] = nil end end
      return true
    end,
    transferTo = function(slot, n)
      local it = inv[sel] if not it then return false end
      n = math.min(n or it.count, it.count)
      local d = inv[slot]
      if d and d.name ~= it.name then return false end
      if d then local m = math.min(n, 64 - d.count) d.count = d.count + m it.count = it.count - m
      else inv[slot] = { name = it.name, count = n } it.count = it.count - n end
      if it.count == 0 then inv[sel] = nil end
      return true
    end,
    compareTo = function(slot) local a, b = inv[sel], inv[slot] return (a and a.name) == (b and b.name) end,
    equipLeft = function() return false end, equipRight = function() return false end,
  }
  return t, { pos = p, blocks = blocks, set = set, get = get, inv = inv, chests = chests }
end
return W
