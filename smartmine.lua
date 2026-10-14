-- smartmine.lua v9 for CC: Tweaked turtles
-- Usage: smartmine <length> [tunnels] [gap] [block1,block2,...]
-- Start: turtle faces into the tunnel, chest with coal directly BEHIND the turtle.

local args = { ... }
if args[1] == "update" then
  -- latest version from GitHub (update.lua does the work, fetched here if missing)
  if not fs.exists("update.lua") then
    shell.run("wget", "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/update.lua", "update.lua")
  end
  shell.run("update")
  return
end
local function usage()
  print("Usage: smartmine <length> [tunnels] [gap] [block1,block2,...]")
  print("  length  = length of each tunnel")
  print("  tunnels = number of tunnels side by side (to the right), default 1")
  print("  gap     = blocks between tunnels, default 3")
  print("  blocks  = target blocks, default diamond_ore")
  print("Put a chest with coal behind the turtle.")
end

local LEN = tonumber(args[1])
if not LEN or LEN < 1 then usage() return end
local TUNNELS = tonumber(args[2]) or 1
local GAP = tonumber(args[3]) or 3

-- Target blocks
local TARGET = {}
if args[4] then
  for n in string.gmatch(args[4], "[^,]+") do
    if not n:find(":") then n = "minecraft:" .. n end
    TARGET[n] = true
  end
else
  TARGET["minecraft:diamond_ore"] = true
  TARGET["minecraft:deepslate_diamond_ore"] = true
end

-- Junk: gets dropped
local JUNK = {}
for _, n in ipairs({ "cobblestone", "cobbled_deepslate", "deepslate", "stone", "dirt",
  "gravel", "sand", "netherrack", "andesite", "diorite", "granite", "tuff", "calcite",
  "basalt", "smooth_basalt", "blackstone", "flint", "dripstone_block", "pointed_dripstone",
  "cobbled_deepslate", "mossy_cobblestone", "clay_ball", "grass_block", "soul_sand",
  "soul_soil", "end_stone", "amethyst_shard" }) do
  JUNK["minecraft:" .. n] = true
end

-- Items that cannot be placed (name parts)
local NOPLACE = { "diamond", "raw_", "coal", "redstone", "lapis", "emerald", "quartz",
  "flint", "ingot", "gem", "nugget", "dust", "shard", "ball", "bone", "string",
  "stick", "torch", "bucket", "_ore", "ore_" }

local FUEL_MARGIN = 30
local JUNK_EVERY = 10
local MAX_VEIN = 48
local RETRY = 30

-- Position: dir 0=forward(+z) 1=right(+x) 2=back 3=left ; 4=up 5=down
local x, y, z, dir = 0, 0, 0, 0
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }
local path = {}        -- stored path (stack of directions)
local seen = {}        -- already inspected coordinates
local dug = 0
local OPP = { [0] = 2, 3, 0, 1, 5, 4 }

local function key(a, b, c) return a .. "," .. b .. "," .. c end
local function neighbour(d)
  if d == 4 then return x, y + 1, z elseif d == 5 then return x, y - 1, z end
  return x + DX[d], y, z + DZ[d]
end

-- Turning with minimal turns
local function face(d)
  if d >= 4 or d == dir then return end
  local diff = (d - dir) % 4
  if diff == 1 then turtle.turnRight()
  elseif diff == 3 then turtle.turnLeft()
  else turtle.turnRight() turtle.turnRight() end
  dir = d
end

local function inspect(d)
  local ok, info
  if d == 4 then ok, info = turtle.inspectUp()
  elseif d == 5 then ok, info = turtle.inspectDown()
  else face(d) ok, info = turtle.inspect() end
  seen[key(neighbour(d))] = true
  if ok then return info end
  return nil
end

local function hasTag(info, t) return info and info.tags and info.tags[t] end
local function isOre(info)
  if not info then return false end
  local n = info.name
  return TARGET[n] or hasTag(info, "c:ores") or hasTag(info, "forge:ores")
    or n:find("_ore") ~= nil or n:find("ore_") ~= nil
end
local function isTarget(info) return info and TARGET[info.name] end
local function isLava(info) return info and (info.name == "minecraft:lava" or info.name == "minecraft:flowing_lava") end

-- Find a placeable seal block
local function isFuel(slot)
  turtle.select(slot)
  return turtle.refuel(0)
end
local function sealable(slot)
  local it = turtle.getItemDetail(slot, true)
  if not it then return false end
  if hasTag(it, "c:ores") or hasTag(it, "forge:ores") then return false end
  if hasTag(it, "minecraft:coals") then return false end
  for _, p in ipairs(NOPLACE) do if it.name:find(p, 1, true) then return false end end
  if isFuel(slot) then return false end
  return true
end

local function placeDir(d)
  if d == 4 then return turtle.placeUp() elseif d == 5 then return turtle.placeDown() end
  face(d) return turtle.place()
end

local function seal(d)
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 and sealable(s) then
      turtle.select(s)
      if placeDir(d) then turtle.select(1) return true end
    end
  end
  turtle.select(1)
  return false
end

-- Digging with retries (gravel, mobs)
local function digDir(d)
  local dig, det, atk
  if d == 4 then dig, det, atk = turtle.digUp, turtle.detectUp, turtle.attackUp
  elseif d == 5 then dig, det, atk = turtle.digDown, turtle.detectDown, turtle.attackDown
  else face(d) dig, det, atk = turtle.dig, turtle.detect, turtle.attack end
  for _ = 1, RETRY do
    if not det() then return true end
    local ok, why = dig()
    if not ok and why and why:find("nbreakable") then return false end
    if not ok then atk() sleep(0.2) end
  end
  return not det()
end

-- Lava check + seal; false = lava remains
local function clearLava(d)
  local info = inspect(d)
  if isLava(info) then
    if not seal(d) then return false end
  end
  return true
end

local function rawMove(d)
  local mv, atk
  if d == 4 then mv, atk = turtle.up, turtle.attackUp
  elseif d == 5 then mv, atk = turtle.down, turtle.attackDown
  else face(d) mv, atk = turtle.forward, turtle.attack end
  for _ = 1, RETRY do
    if mv() then
      if d == 4 then y = y + 1 elseif d == 5 then y = y - 1
      else x = x + DX[d] z = z + DZ[d] end
      return true
    end
    if not digDir(d) then return false end
    atk()
    if turtle.getFuelLevel() == 0 then return false end
  end
  return false
end

-- Step with lava check and path recording
local function step(d, noRecord)
  if not clearLava(d) then return false, "lava" end
  if not digDir(d) then return false, "bedrock" end
  if not rawMove(d) then return false, "blocked" end
  if not noRecord then path[#path + 1] = d end
  return true
end

-- One step back along the path
local function back()
  local d = table.remove(path)
  if not d then return true end
  for _ = 1, RETRY do
    if rawMove(OPP[d]) then return true end
    sleep(0.5)
  end
  path[#path + 1] = d
  return false
end

-- Inventory
local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end

-- Drop junk, keep one stack of placeable junk for lava
local function dropJunk()
  local kept = false
  for s = 1, 16 do
    local it = turtle.getItemDetail(s)
    if it and JUNK[it.name] then
      turtle.select(s)
      if not kept and sealable(s) then
        kept = true -- keep 1 stack as seal material
      else turtle.dropDown() end
    end
  end
  turtle.select(1)
end

-- Go home, unload, refuel, go back
local resumeFrom
local function goHome()
  local saved = {}
  for i, d in ipairs(path) do saved[i] = d end
  while #path > 0 do
    if not back() then error("Cannot get back to start", 0) end
  end
  face(2)
  return saved
end

local function unloadAndFuel()
  -- Unload, keep fuel
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 and not isFuel(s) then turtle.select(s) turtle.drop() end
  end
  -- Coal from the chest
  local need = function() return turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 2000 end
  local tries = 0
  while need() and tries < 20 do
    turtle.select(16)
    if turtle.suck(16) then
      if not turtle.refuel() then turtle.drop() end
    else
      tries = tries + 1
      for s = 1, 16 do turtle.select(s) turtle.refuel() end
      if turtle.getFuelLevel() < 500 then print("No coal in chest, waiting...") sleep(5) else break end
    end
  end
  turtle.select(1)
end

local function resume(saved)
  for _, d in ipairs(saved) do
    local ok = false
    for _ = 1, 5 do if step(d) then ok = true break end sleep(0.5) end
    if not ok then error("Cannot resume path", 0) end
  end
end

local function service()
  local saved = goHome()
  unloadAndFuel()
  resume(saved)
end

-- Light fuel check: distance home + margin
local function checkFuel()
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return end
  if f <= #path + FUEL_MARGIN then
    print("Fuel low, going home")
    service()
  end
end

local function afterDig()
  dug = dug + 1
  if dug % JUNK_EVERY == 0 then dropJunk() end
  if freeSlots() == 0 then
    dropJunk()
    if freeSlots() == 0 then print("Inventory full, unloading") service() end
  end
end

-- Vein finder: DFS with visited set, side steps for diagonals
local veinSeen = {}
local veinCount = 0
local mineInto

local function scanFor(dirs)
  for _, d in ipairs(dirs) do
    local nx, ny, nz = neighbour(d)
    local k = key(nx, ny, nz)
    if not veinSeen[k] then
      veinSeen[k] = true
      local info = inspect(d)
      if isLava(info) then seal(d)
      elseif isOre(info) and veinCount < MAX_VEIN then mineInto(d, isTarget(info)) end
    end
  end
end

local ALL6 = { 0, 1, 2, 3, 4, 5 }
local function explore(isDia)
  scanFor(ALL6)
  if not isDia then return end
  -- Side steps: above and below all 4 sides, front/back the sides (18 of 26)
  local side = {
    { 4, { 0, 1, 2, 3 } }, { 5, { 0, 1, 2, 3 } },
    { 0, { 1, 3 } }, { 2, { 1, 3 } },
  }
  for _, sd in ipairs(side) do
    local d = sd[1]
    local info = inspect(d)
    if not isLava(info) and (not info or not info.name:find("bedrock")) then
      if step(d) then
        afterDig()
        scanFor(sd[2])
        back()
      end
    end
  end
end

mineInto = function(d, isDia)
  veinCount = veinCount + 1
  if step(d) then
    afterDig()
    veinSeen[key(x, y, z)] = true
    explore(isDia)
    back()
  end
end

local function vein(d, info)
  veinSeen = {}
  veinCount = 0
  veinSeen[key(x, y, z)] = true
  mineInto(d, isTarget(info))
end

-- Wall scan in the dig step: left/right, column above/below also for ores
local function scanStep(fwd)
  for _, d in ipairs({ 4, 5 }) do
    local info = inspect(d)
    if isLava(info) then seal(d)
    elseif isOre(info) then vein(d, info) end
  end
  -- Left and right; ordered to minimise turning
  local l, r = (fwd + 3) % 4, (fwd + 1) % 4
  for _, d in ipairs({ l, r }) do
    local nx, ny, nz = neighbour(d)
    if not seen[key(nx, ny, nz)] then
      local info = inspect(d)
      if isLava(info) then seal(d)
      elseif isOre(info) then vein(d, info) end
    end
  end
end

-- Detour around lava or bedrock
local function detour(fwd)
  for _, s in ipairs({ (fwd + 1) % 4, (fwd + 3) % 4, 4 }) do
    local base = #path
    local sb = (s == 4) and 5 or OPP[s]
    if step(s) and step(fwd) and step(fwd) and step(sb) then return true end
    while #path > base do back() end
  end
  return false
end

-- One tunnel step: 3 high, middle row
local function tunnelStep(fwd)
  checkFuel()
  local ok, why = step(fwd)
  if not ok then
    print("Problem: " .. tostring(why) .. ", detour")
    if not detour(fwd) then return false end
  end
  afterDig()
  if clearLava(4) then digDir(4) end
  if clearLava(5) then digDir(5) end
  scanStep(fwd)
  return true
end

-- Main program
local function main()
  if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < LEN + FUEL_MARGIN then
    face(2) unloadAndFuel() face(0)
  end
  for t = 1, TUNNELS do
    local fwd = (t % 2 == 1) and 0 or 2
    local i = 0
    while i < LEN do
      if not tunnelStep(fwd) then error("No safe route", 0) end
      i = (fwd == 0) and z or (LEN - z)
      if fwd == 2 then i = LEN - z end
    end
    if t < TUNNELS then
      for _ = 1, GAP + 1 do
        if not tunnelStep(1) then error("No safe route", 0) end
      end
    end
  end
  print("Done, going back to start")
end

local ok, err = pcall(main)
if not ok then print("Error: " .. tostring(err)) end
-- Always go home and unload
local ok2, err2 = pcall(function() goHome() dropJunk() unloadAndFuel() end)
if not ok2 then print("Return failed: " .. tostring(err2)) end
face(0)
print("Stopped at start. Dug: " .. dug)
