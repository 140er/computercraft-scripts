-- smartmine.lua v9 voor CC: Tweaked turtles
-- Gebruik: smartmine <lengte> [tunnels] [tussenruimte] [blok1,blok2,...]
-- Start: turtle kijkt de tunnel in, kist met kolen direct ACHTER de turtle.

local args = { ... }
local function usage()
  print("Gebruik: smartmine <lengte> [tunnels] [tussenruimte] [blok1,blok2,...]")
  print("  lengte       = lengte van elke tunnel")
  print("  tunnels      = aantal tunnels naast elkaar (rechts), standaard 1")
  print("  tussenruimte = blokken tussen tunnels, standaard 3")
  print("  blokken      = doelblokken, standaard diamond_ore")
  print("Kist met kolen achter de turtle zetten.")
end

local LEN = tonumber(args[1])
if not LEN or LEN < 1 then usage() return end
local TUNNELS = tonumber(args[2]) or 1
local GAP = tonumber(args[3]) or 3

-- Doelblokken
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

-- Troep: wordt weggegooid
local JUNK = {}
for _, n in ipairs({ "cobblestone", "cobbled_deepslate", "deepslate", "stone", "dirt",
  "gravel", "sand", "netherrack", "andesite", "diorite", "granite", "tuff", "calcite",
  "basalt", "smooth_basalt", "blackstone", "flint", "dripstone_block", "pointed_dripstone",
  "cobbled_deepslate", "mossy_cobblestone", "clay_ball", "grass_block", "soul_sand",
  "soul_soil", "end_stone", "amethyst_shard" }) do
  JUNK["minecraft:" .. n] = true
end

-- Items die je niet kunt plaatsen (naamdelen)
local NOPLACE = { "diamond", "raw_", "coal", "redstone", "lapis", "emerald", "quartz",
  "flint", "ingot", "gem", "nugget", "dust", "shard", "ball", "bone", "string",
  "stick", "torch", "bucket", "_ore", "ore_" }

local FUEL_MARGIN = 30
local JUNK_EVERY = 10
local MAX_VEIN = 48
local RETRY = 30

-- Positie: dir 0=vooruit(+z) 1=rechts(+x) 2=achter 3=links ; 4=op 5=neer
local x, y, z, dir = 0, 0, 0, 0
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }
local path = {}        -- opgeslagen pad (stapel richtingen)
local seen = {}        -- al geinspecteerde coordinaten
local dug = 0
local OPP = { [0] = 2, 3, 0, 1, 5, 4 }

local function key(a, b, c) return a .. "," .. b .. "," .. c end
local function neighbour(d)
  if d == 4 then return x, y + 1, z elseif d == 5 then return x, y - 1, z end
  return x + DX[d], y, z + DZ[d]
end

-- Draaien met minimale draaiingen
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

-- Plaatsbaar seal-blok zoeken
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

-- Graven met herstel (grind, mobs)
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

-- Lava check + seal; false = lava blijft
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

-- Stap met lava-check en pad-opslag
local function step(d, noRecord)
  if not clearLava(d) then return false, "lava" end
  if not digDir(d) then return false, "bedrock" end
  if not rawMove(d) then return false, "blocked" end
  if not noRecord then path[#path + 1] = d end
  return true
end

-- Een stap terug via het pad
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

-- Troep weggooien, een stapel plaatsbare troep houden voor lava
local function dropJunk()
  local kept = false
  for s = 1, 16 do
    local it = turtle.getItemDetail(s)
    if it and JUNK[it.name] then
      turtle.select(s)
      if not kept and sealable(s) then
        kept = true -- 1 stapel bewaren als seal-materiaal
      else turtle.dropDown() end
    end
  end
  turtle.select(1)
end

-- Naar huis, lossen, tanken, terug
local resumeFrom
local function goHome()
  local saved = {}
  for i, d in ipairs(path) do saved[i] = d end
  while #path > 0 do
    if not back() then error("Kan niet terug naar start", 0) end
  end
  face(2)
  return saved
end

local function unloadAndFuel()
  -- Lossen, brandstof houden
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 and not isFuel(s) then turtle.select(s) turtle.drop() end
  end
  -- Kolen uit de kist
  local need = function() return turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 2000 end
  local tries = 0
  while need() and tries < 20 do
    turtle.select(16)
    if turtle.suck(16) then
      if not turtle.refuel() then turtle.drop() end
    else
      tries = tries + 1
      for s = 1, 16 do turtle.select(s) turtle.refuel() end
      if turtle.getFuelLevel() < 500 then print("Geen kolen in kist, wacht...") sleep(5) else break end
    end
  end
  turtle.select(1)
end

local function resume(saved)
  for _, d in ipairs(saved) do
    local ok = false
    for _ = 1, 5 do if step(d) then ok = true break end sleep(0.5) end
    if not ok then error("Kan pad niet hervatten", 0) end
  end
end

local function service()
  local saved = goHome()
  unloadAndFuel()
  resume(saved)
end

-- Lichte fuel-check: afstand naar huis + marge
local function checkFuel()
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return end
  if f <= #path + FUEL_MARGIN then
    print("Fuel laag, naar huis")
    service()
  end
end

local function afterDig()
  dug = dug + 1
  if dug % JUNK_EVERY == 0 then dropJunk() end
  if freeSlots() == 0 then
    dropJunk()
    if freeSlots() == 0 then print("Inventory vol, lossen") service() end
  end
end

-- Vein finder: DFS met visited-set, zijstappen voor diagonalen
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
  -- Zijstappen: boven en onder alle 4 kanten, voor/achter de zijkanten (18 van 26)
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

-- Wandscan in de graafstap: links/rechts, kolom boven/onder ook voor ores
local function scanStep(fwd)
  for _, d in ipairs({ 4, 5 }) do
    local info = inspect(d)
    if isLava(info) then seal(d)
    elseif isOre(info) then vein(d, info) end
  end
  -- Links en rechts; volgorde zo dat er weinig gedraaid wordt
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

-- Omweg rond lava of bedrock
local function detour(fwd)
  for _, s in ipairs({ (fwd + 1) % 4, (fwd + 3) % 4, 4 }) do
    local base = #path
    local sb = (s == 4) and 5 or OPP[s]
    if step(s) and step(fwd) and step(fwd) and step(sb) then return true end
    while #path > base do back() end
  end
  return false
end

-- Een tunnelstap: 3 hoog, middelste rij
local function tunnelStep(fwd)
  checkFuel()
  local ok, why = step(fwd)
  if not ok then
    print("Probleem: " .. tostring(why) .. ", omweg")
    if not detour(fwd) then return false end
  end
  afterDig()
  if clearLava(4) then digDir(4) end
  if clearLava(5) then digDir(5) end
  scanStep(fwd)
  return true
end

-- Hoofdprogramma
local function main()
  if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < LEN + FUEL_MARGIN then
    face(2) unloadAndFuel() face(0)
  end
  for t = 1, TUNNELS do
    local fwd = (t % 2 == 1) and 0 or 2
    local i = 0
    while i < LEN do
      if not tunnelStep(fwd) then error("Geen veilige route", 0) end
      i = (fwd == 0) and z or (LEN - z)
      if fwd == 2 then i = LEN - z end
    end
    if t < TUNNELS then
      for _ = 1, GAP + 1 do
        if not tunnelStep(1) then error("Geen veilige route", 0) end
      end
    end
  end
  print("Klaar, terug naar start")
end

local ok, err = pcall(main)
if not ok then print("Fout: " .. tostring(err)) end
-- Altijd terug naar huis en lossen
local ok2, err2 = pcall(function() goHome() dropJunk() unloadAndFuel() end)
if not ok2 then print("Terugkeer mislukt: " .. tostring(err2)) end
face(0)
print("Gestopt op start. Gegraven: " .. dug)
