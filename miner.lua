-- miner.lua - Mine Army turtle (CC: Tweaked)
--
-- Eenmalig instellen (zie README):
--   miner setup <x> <y> <z> <facing> <rol>
--     x y z   = wereldcoordinaten van de turtle (F3), bv. -216 65 -743
--     facing  = kant waar de turtle naar kijkt: north/east/south/west
--     rol     = richting van zijn hoofdgang: east/south/west/north
--               (oostelijkste turtle = east, westelijkste = west,
--                de twee in het midden = south en north)
-- Daarna:
--   miner            luistert naar de hub (dashboard) voor opdrachten
--   miner diamond    werkt zonder hub, mijnt diamonds (ook: iron, gold, ...)
--   miner home       na handmatig terugzetten op de startplek: positie resetten
--
-- Kist met kolen direct ACHTER de turtle. Turtle heeft pickaxe + wireless/ender modem.
-- De turtle graaft een schacht recht onder zich naar het erts-niveau en hergebruikt
-- die schacht elke trip. Daar graaft hij een hoofdgang met om de 4 blokken een zijgang
-- (3 blokken steen ertussen), 1x1. Grot-openingen worden dichtgezet.

local VERSION = 2

-- Versie = hash van de inhoud van dit bestand (zelfde berekening als in hub.lua)
local function hashOf(text)
  local h = 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end
local PROGRAM = (shell and shell.getRunningProgram()) or "miner.lua"
local MY_HASH = "?"
if fs.exists(PROGRAM) then
  local fh = fs.open(PROGRAM, "r")
  MY_HASH = hashOf(fh.readAll())
  fh.close()
end
local PROTOCOL = "minearmy"
local CFG_FILE, STATE_FILE = "miner.cfg", "miner.state"

local BRANCH_LEN = 64      -- standaard lengte zijgang (hub kan dit overschrijven)
local BRANCH_GAP = 4       -- om de 4 blokken een zijgang = 3 blokken ertussen
local FUEL_MARGIN = 64     -- extra fuel bovenop de weg naar huis
local MIN_TRIP_FUEL = 2000 -- probeer minstens zoveel te tanken
local JUNK_EVERY = 10      -- troep weggooien per ~10 gegraven blokken
local MAX_VEIN = 64        -- max blokken per ader
local RETRY = 20

local ORES = {
  diamond  = { y = -58, targets = { "minecraft:diamond_ore", "minecraft:deepslate_diamond_ore" } },
  redstone = { y = -58, targets = { "minecraft:redstone_ore", "minecraft:deepslate_redstone_ore" } },
  gold     = { y = -16, targets = { "minecraft:gold_ore", "minecraft:deepslate_gold_ore" } },
  lapis    = { y = 0,   targets = { "minecraft:lapis_ore", "minecraft:deepslate_lapis_ore" } },
  iron     = { y = 16,  targets = { "minecraft:iron_ore", "minecraft:deepslate_iron_ore" } },
  copper   = { y = 48,  targets = { "minecraft:copper_ore", "minecraft:deepslate_copper_ore" } },
  coal     = { y = 48,  targets = { "minecraft:coal_ore", "minecraft:deepslate_coal_ore" } },
}

-- Richtingen: 0=north(-z) 1=east(+x) 2=south(+z) 3=west(-x) 4=up 5=down
local UP, DOWN = 4, 5
local DIRS = { north = 0, east = 1, south = 2, west = 3, n = 0, e = 1, s = 2, w = 3 }
local DIRNAME = { [0] = "north", "east", "south", "west", "up", "down" }
local DX = { [0] = 0, 1, 0, -1, 0, 0 }
local DY = { [0] = 0, 0, 0, 0, 1, -1 }
local DZ = { [0] = -1, 0, 1, 0, 0, 0 }
local OPP = { [0] = 2, 3, 0, 1, 5, 4 }

local args = { ... }

---------------------------------------------------------------------------
-- Bestanden
---------------------------------------------------------------------------
local function loadTable(path)
  for _, p in ipairs({ path, path .. ".tmp" }) do
    if fs.exists(p) then
      local h = fs.open(p, "r")
      local t = textutils.unserialize(h.readAll())
      h.close()
      if type(t) == "table" then return t end
    end
  end
  return nil
end

local function saveTable(path, t)
  local tmp = path .. ".tmp"
  local h = fs.open(tmp, "w")
  h.write(textutils.serialize(t, { compact = true }))
  h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
if args[1] == "setup" then
  local hx, hy, hz = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
  local facing = DIRS[(args[5] or ""):lower()]
  local role = DIRS[(args[6] or ""):lower()]
  if not hx and gps then
    local gx, gy, gz = gps.locate(2)
    if gx then hx, hy, hz = math.floor(gx + 0.5), math.floor(gy + 0.5), math.floor(gz + 0.5) end
  end
  if not (hx and hy and hz and facing and role) then
    print("Usage: miner setup <x> <y> <z> <facing> <role>")
    print("  facing/role: north, east, south or west")
    print("  e.g. miner setup -216 65 -743 south east")
    return
  end
  local found, info = false, nil
  turtle.turnLeft() turtle.turnLeft()
  found, info = turtle.inspect()
  turtle.turnLeft() turtle.turnLeft()
  if not (found and info.name:find("chest") or found and info.name:find("barrel")) then
    print("WARNING: no chest found behind the turtle!")
  end
  saveTable(CFG_FILE, { home = { x = hx, y = hy, z = hz }, facing = facing, spine = role })
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("miner")\n')
  h.close()
  os.setComputerLabel("Miner-" .. DIRNAME[role])
  print("Saved. Home " .. hx .. "," .. hy .. "," .. hz .. " facing " .. DIRNAME[facing])
  print("Main tunnel " .. DIRNAME[role] .. ", branches " .. DIRNAME[(role + 1) % 4])
  print("Start with: miner   (or reboot the turtle)")
  return
end

if not turtle then error("miner.lua only runs on a turtle", 0) end
local cfg = loadTable(CFG_FILE)
if not cfg then
  print("Not set up yet. First: miner setup <x> <y> <z> <facing> <role>")
  return
end
local HOME = cfg.home
-- De schacht zit 1 blok VOOR de startplek (daar zitten de gaten)
local SHAFT = { x = HOME.x + DX[cfg.facing], z = HOME.z + DZ[cfg.facing] }
local SPINE = cfg.spine
local BRANCH = (SPINE + 1) % 4
local ROLE = DIRNAME[SPINE]

if args[1] == "home" then
  -- Handmatig herstel: de turtle staat (weer) op zijn startplek, kist erachter.
  -- Voortgang (gangen, schacht) blijft bewaard.
  local s0 = loadTable(STATE_FILE) or {}
  s0.pos = { x = HOME.x, y = HOME.y, z = HOME.z }
  s0.h = cfg.facing
  s0.phase = "home"
  s0.vein = {}
  s0.pending = nil
  saveTable(STATE_FILE, s0)
  print("Position reset to home " .. HOME.x .. "," .. HOME.y .. "," .. HOME.z .. " (facing " .. DIRNAME[cfg.facing] .. ").")
  print("Make sure it really stands there, chest behind it. Start with: miner")
  return
end

local standaloneOre = args[1] and args[1]:lower()
if standaloneOre and not ORES[standaloneOre] then
  print("Unknown ore: " .. standaloneOre)
  return
end

---------------------------------------------------------------------------
-- Toestand (overleeft reboot / chunk unload)
---------------------------------------------------------------------------
local st = loadTable(STATE_FILE) or {}
st.pos = st.pos or { x = HOME.x, y = HOME.y, z = HOME.z }
st.h = st.h or cfg.facing
st.levels = st.levels or {}   -- [y] = { spine=, branch=, step= }
st.shaft = st.shaft or HOME.y -- laagste gegraven y in de schacht
st.vein = st.vein or {}       -- pad van de huidige ader-uitstap
st.phase = st.phase or "home"
st.dug = st.dug or 0
st.found = st.found or 0      -- doel-ertsen deze trip
st.total = st.total or {}
local pos = st.pos

local function save() saveTable(STATE_FILE, st) end

local status = "Starting"
local recall = false
local updateWanted = false -- hub heeft een nieuwe versie vrijgegeven: naar huis om te updaten
local hubId = nil
local radio = false

local function job() return st.job end

---------------------------------------------------------------------------
-- Telemetrie
---------------------------------------------------------------------------
local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end

local function packet()
  local j = st.job or {}
  local items = {}
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d then items[d.name] = (items[d.name] or 0) + d.count end
  end
  local L = j.y and st.levels[j.y] or {}
  return {
    type = "status", v = VERSION, hash = MY_HASH, id = os.getComputerID(),
    label = os.getComputerLabel() or ("Turtle " .. os.getComputerID()),
    role = ROLE, status = status, phase = st.phase,
    x = pos.x, y = pos.y, z = pos.z,
    fuel = turtle.getFuelLevel(), free = freeSlots(),
    ore = j.ore, level = j.y, branch = L.branch, step = L.step, branchLen = j.branchLen,
    found = st.found, dug = st.dug, recall = recall, scooped = st.scooped,
    items = items,
  }
end

local lastSent = -10
local function publish(force)
  if not radio then return end
  if not force and os.clock() - lastSent < 2 then return end
  lastSent = os.clock()
  local p = packet()
  if hubId then pcall(rednet.send, hubId, p, PROTOCOL) else pcall(rednet.broadcast, p, PROTOCOL) end
end

local function setStatus(s)
  status = s
  print(s)
  publish(true)
end

---------------------------------------------------------------------------
-- Blok-herkenning
---------------------------------------------------------------------------
local TARGET = {}
local function setTargets(list)
  TARGET = {}
  for _, n in ipairs(list or {}) do
    if not n:find(":") then n = "minecraft:" .. n end
    TARGET[n] = true
  end
end

local function hasTag(info, t) return info and info.tags and info.tags[t] end

local function isOre(info)
  if not info then return false end
  local n = info.name
  if TARGET[n] or n:find("_ore$") or n:find(":ore_") or n == "minecraft:ancient_debris" then return true end
  for tag in pairs(info.tags or {}) do
    if tag == "c:ores" or tag == "forge:ores" or tag:find("^c:ores/") or tag:find("^forge:ores/") then
      return true
    end
  end
  return false
end
local function isTarget(info) return info and TARGET[info.name] end
local function isLava(info)
  if not info then return false end
  return info.name:find(":lava$") or info.name:find(":flowing_lava$") or hasTag(info, "minecraft:lava")
end
local function isLiquid(info)
  return info and (info.name:find(":water$") or info.name:find(":flowing_water$") or isLava(info))
end
local function isUnbreakable(info)
  return info and (info.name == "minecraft:bedrock" or info.name:find("turtle") ~= nil
    or info.name:find("computer") ~= nil)
end

-- Troep (wordt weggegooid). Alles wat hier niet onder valt wordt bewaard.
local JUNK = {}
for _, n in ipairs({ "cobblestone", "cobbled_deepslate", "stone", "deepslate", "granite", "diorite",
  "andesite", "tuff", "calcite", "dirt", "coarse_dirt", "rooted_dirt", "grass_block", "mud", "gravel",
  "sand", "red_sand", "sandstone", "netherrack", "basalt", "smooth_basalt", "blackstone",
  "dripstone_block", "pointed_dripstone", "flint", "clay_ball", "moss_block", "mossy_cobblestone",
  "soul_sand", "soul_soil", "end_stone", "amethyst_shard", "infested_stone", "infested_deepslate" }) do
  JUNK["minecraft:" .. n] = true
end
local JUNK_TAGS = { "c:cobblestones", "c:stones", "forge:cobblestone", "forge:stone", "c:gravels",
  "forge:gravel", "c:sands", "forge:sand", "minecraft:dirt", "minecraft:stone_tool_materials",
  "minecraft:stone_crafting_materials", "c:netherracks", "forge:netherrack" }
local junkCache = {}

local function isOreItem(d)
  if d.name:find("_ore$") or d.name:find(":raw_") or d.name:find(":ore_") then return true end
  for tag in pairs(d.tags or {}) do
    if tag == "c:ores" or tag == "forge:ores" or tag:find("^c:ores/") or tag:find("^forge:ores/")
      or tag:find("^c:raw_materials") or tag:find("^forge:raw_materials") then return true end
  end
  return false
end

local function isJunk(slot)
  local d = turtle.getItemDetail(slot)
  if not d then return false end
  if JUNK[d.name] then return true end
  if junkCache[d.name] == nil then
    local full = turtle.getItemDetail(slot, true) or d
    local j = false
    if not isOreItem(full) then
      for _, t in ipairs(JUNK_TAGS) do if hasTag(full, t) then j = true break end end
    end
    junkCache[d.name] = j
  end
  return junkCache[d.name]
end

-- Seal-blok: echt neerzetbaar, geen erts, geen fuel (kolen blijven liggen), niet vallend.
local NOPLACE = { "diamond", "emerald", "raw_", "coal", "redstone", "lapis", "quartz", "flint",
  "ingot", "gem", "nugget", "dust", "shard", "ball", "bone", "string", "stick", "torch", "bucket",
  "_ore", "ore_", "gravel", "concrete_powder", "seeds", "pickaxe", "modem" }
local FALLING = { ["minecraft:sand"] = true, ["minecraft:red_sand"] = true, ["minecraft:gravel"] = true }
local sealCache = {}

local function sealable(slot)
  local d = turtle.getItemDetail(slot)
  if not d then return false end
  if sealCache[d.name] ~= nil then return sealCache[d.name] end
  local ok = true
  if FALLING[d.name] then ok = false end
  for _, p in ipairs(NOPLACE) do if d.name:find(p, 1, true) then ok = false break end end
  if ok then
    local full = turtle.getItemDetail(slot, true) or d
    if isOreItem(full) or hasTag(full, "minecraft:coals") then ok = false end
  end
  if ok then
    local prev = turtle.getSelectedSlot()
    turtle.select(slot)
    if turtle.refuel(0) then ok = false end -- brandstof (kolen, hout) niet gebruiken
    turtle.select(prev)
  end
  sealCache[d.name] = ok
  return ok
end

local function isFuelSlot(slot)
  if turtle.getItemCount(slot) == 0 then return false end
  turtle.select(slot)
  local ok = turtle.refuel(0)
  turtle.select(1)
  return ok
end

---------------------------------------------------------------------------
-- Beweging
---------------------------------------------------------------------------
-- Draaien. De nieuwe richting wordt VOOR elke draai opgeslagen: een draai gebeurt
-- direct en de 8 ticks animatie daarna zijn het grootste risico bij een reboot.
local function face(d)
  if d >= 4 then return end
  while st.h ~= d do
    if (d - st.h) % 4 == 3 then
      st.h = (st.h + 3) % 4
      save()
      turtle.turnLeft()
    else
      st.h = (st.h + 1) % 4
      save()
      turtle.turnRight()
    end
  end
end

local function inspect(d)
  local ok, info
  if d == UP then ok, info = turtle.inspectUp()
  elseif d == DOWN then ok, info = turtle.inspectDown()
  else face(d) ok, info = turtle.inspect() end
  if ok then return info end
  return nil
end

local function placeDir(d)
  if d == UP then return turtle.placeUp() elseif d == DOWN then return turtle.placeDown() end
  face(d)
  return turtle.place()
end

local BUCKET, LAVA_BUCKET = "minecraft:bucket", "minecraft:lava_bucket"

local function findItem(name, skip)
  for s = 1, 16 do
    if s ~= skip then
      local d = turtle.getItemDetail(s)
      if d and d.name == name then return s end
    end
  end
  return nil
end

-- Lava opscheppen met een lege emmer en meteen verbranden (+1000 fuel).
-- Werkt alleen op een lava-bron; stromende lava wordt gewoon afgedicht.
local function scoopLava(d)
  local f = turtle.getFuelLevel()
  if f == "unlimited" or f > turtle.getFuelLimit() - 1000 then return end
  local s = findItem(BUCKET)
  if not s then return end
  turtle.select(s)
  if placeDir(d) then
    local lb = findItem(LAVA_BUCKET)
    if lb then
      turtle.select(lb)
      turtle.refuel(1)
      st.scooped = (st.scooped or 0) + 1
    end
  end
  turtle.select(1)
end

-- Lava: eerst opscheppen als brandstof, dan afdichten met het eerste neerzetbare non-ore blok
local function seal(d)
  scoopLava(d)
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 and sealable(s) then
      turtle.select(s)
      local ok = placeDir(d)
      turtle.select(1)
      if ok then return true end
    end
  end
  turtle.select(1)
  return not isLava(inspect(d))
end

local function keepOneSealStack(dropFn)
  local kept = false
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 and isJunk(s) then
      if not kept and sealable(s) then kept = true
      else turtle.select(s) dropFn() end
    end
  end
  turtle.select(1)
end

local sinceDrop = 0
local function dropJunk()
  sinceDrop = 0
  keepOneSealStack(turtle.dropDown)
end

local function afterDig()
  st.dug = st.dug + 1
  sinceDrop = sinceDrop + 1
  if sinceDrop >= JUNK_EVERY or turtle.getItemCount(16) > 0 and freeSlots() == 0 then dropJunk() end
end

-- Graven met herstel (grind/zand, mobs). false + reden als het niet lukt.
local function dig(d)
  local digf, att
  if d == UP then digf, att = turtle.digUp, turtle.attackUp
  elseif d == DOWN then digf, att = turtle.digDown, turtle.attackDown
  else face(d) digf, att = turtle.dig, turtle.attack end
  for _ = 1, RETRY do
    local info = inspect(d)
    if not info or isLiquid(info) then return true end
    if isUnbreakable(info) then return false, "unbreakable (" .. info.name .. ")" end
    if isTarget(info) then st.found = st.found + 1 end
    if digf() then
      afterDig()
    else
      att()
      sleep(0.3)
    end
  end
  return false, "stays blocked"
end

local function applyMove(d)
  pos.x, pos.y, pos.z = pos.x + DX[d], pos.y + DY[d], pos.z + DZ[d]
end

-- Een stap, met fuel-truc zodat een reboot halverwege de positie niet kwijtraakt.
local function rawMove(d, inVein)
  local mv = turtle.forward
  if d == UP then mv = turtle.up elseif d == DOWN then mv = turtle.down else face(d) end
  st.pending = { d = d, fuel = turtle.getFuelLevel(), vein = inVein }
  save()
  local ok = mv()
  if ok then
    applyMove(d)
    if inVein then st.vein[#st.vein + 1] = d end
  end
  st.pending = nil
  save()
  return ok
end

-- Veilig bewegen: nooit in lava stappen (eerst afdichten), graven waar nodig.
local function move(d, inVein)
  for attempt = 1, RETRY do
    local info = inspect(d)
    if isLava(info) then
      if not seal(d) then return false, "lava" end
      info = inspect(d)
      if isLava(info) then return false, "lava" end
    end
    if info and not isLiquid(info) then
      local ok, why = dig(d)
      if not ok then
        if why:find("turtle") or why:find("computer") then sleep(1)
        else return false, why end
      end
    end
    if turtle.getFuelLevel() == 0 then return false, "out of fuel" end
    if rawMove(d, inVein) then
      publish(false)
      return true
    end
    if d == UP then turtle.attackUp() elseif d == DOWN then turtle.attackDown() else turtle.attack() end
    sleep(0.2 * math.min(attempt, 5))
  end
  return false, "blocked"
end

local function moveOrFail(d, what)
  local ok, why = move(d)
  if not ok then error((what or "Stuck") .. ": " .. tostring(why), 0) end
end

---------------------------------------------------------------------------
-- Afstand en terugweg
---------------------------------------------------------------------------
local function along(d) -- afstand vanaf de schacht langs richting d
  return (pos.x - SHAFT.x) * DX[d] + (pos.z - SHAFT.z) * DZ[d]
end

local function distHome()
  return math.abs(pos.x - HOME.x) + math.abs(pos.z - HOME.z) + math.abs(pos.y - HOME.y) + #st.vein
end

local function fuelOk(extra)
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return true end
  return f >= distHome() + FUEL_MARGIN + (extra or 0)
end

-- Noodtanken met kolen uit de inventory
local function burnMinedFuel()
  for s = 1, 16 do
    if isFuelSlot(s) then
      turtle.select(s)
      turtle.refuel()
    end
    if fuelOk(200) then break end
  end
  turtle.select(1)
end

local function unwindVein()
  while #st.vein > 0 do
    local d = st.vein[#st.vein]
    local ok = move(OPP[d])
    if not ok then error("Cannot get back out of vein", 0) end
    st.vein[#st.vein] = nil
    save()
  end
end

-- Rij langs een as tot de coordinaat klopt (door eigen gegraven gangen)
local function goAxis(axis, target)
  while true do
    local cur = pos[axis]
    if cur == target then return end
    local d
    if axis == "y" then d = (target > cur) and UP or DOWN
    elseif axis == "x" then d = (target > cur) and 1 or 3
    else d = (target > cur) and 2 or 0 end
    moveOrFail(d, "Way home blocked")
  end
end

local function axisOf(d) return (d == 1 or d == 3) and "x" or "z" end

-- Terug naar huis via de opgeslagen route: ader -> zijgang -> hoofdgang -> schacht
local function goHome(reason)
  st.phase = "returning"
  save()
  setStatus("Going home: " .. (reason or ""))
  unwindVein()
  if pos.y < HOME.y - 2 then dropJunk() end
  -- Let op: ook de hoogte vergelijken. De hoofdgang van de "north"-turtle loopt
  -- precies onder de startplek door; alleen x/z checken gaf daar een vals "thuis".
  if pos.x ~= HOME.x or pos.y ~= HOME.y or pos.z ~= HOME.z then
    if pos.x ~= SHAFT.x or pos.z ~= SHAFT.z then
      if st.job and st.job.y and pos.y ~= st.job.y then goAxis("y", st.job.y) end
      goAxis(axisOf(BRANCH), SHAFT[axisOf(BRANCH)])
      goAxis(axisOf(SPINE), SHAFT[axisOf(SPINE)])
      goAxis(axisOf(BRANCH), SHAFT[axisOf(BRANCH)])
    end
    goAxis("y", HOME.y)
    moveOrFail(OPP[cfg.facing], "Home spot blocked") -- 1 blok terug, kist weer achter hem
  end
  st.phase = "home"
  save()
end

---------------------------------------------------------------------------
-- Ader volgen
---------------------------------------------------------------------------
local veinSeen, veinCount = {}, 0
local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function nkey(d) return key(pos.x + DX[d], pos.y + DY[d], pos.z + DZ[d]) end

local function roomLeft()
  if freeSlots() <= 1 then dropJunk() end
  return freeSlots() > 1
end

local mineVein

local function scanFor(dirs)
  for _, d in ipairs(dirs) do
    local k = nkey(d)
    if not veinSeen[k] then
      veinSeen[k] = true
      local info = inspect(d)
      if isLava(info) then seal(d)
      elseif isOre(info) then mineVein(d, isTarget(info)) end
    end
  end
end

local function allSeen(fromDir, dirs)
  local bx, by, bz = pos.x + DX[fromDir], pos.y + DY[fromDir], pos.z + DZ[fromDir]
  for _, d in ipairs(dirs) do
    if not veinSeen[key(bx + DX[d], by + DY[d], bz + DZ[d])] then return false end
  end
  return true
end

-- Doelerts: ook de 12 randburen (18 van 26), via zijstapjes.
local function scanEdges()
  local h = st.h
  local side = {
    { UP, { h, (h + 1) % 4, (h + 2) % 4, (h + 3) % 4 } },
    { DOWN, { h, (h + 1) % 4, (h + 2) % 4, (h + 3) % 4 } },
    { h, { (h + 1) % 4, (h + 3) % 4 } },
    { (h + 2) % 4, { (h + 1) % 4, (h + 3) % 4 } },
  }
  for _, sd in ipairs(side) do
    local d, dirs = sd[1], sd[2]
    if not allSeen(d, dirs) and fuelOk(4) and roomLeft() then
      local info = inspect(d)
      if not isLava(info) and not isUnbreakable(info) then
        local depth = #st.vein
        if move(d, true) then
          veinSeen[key(pos.x, pos.y, pos.z)] = true
          scanFor(dirs)
          while #st.vein > depth do
            local back = st.vein[#st.vein]
            if not move(OPP[back]) then error("Cannot get back out of vein", 0) end
            st.vein[#st.vein] = nil
            save()
          end
        end
      end
    end
  end
end

mineVein = function(d, target)
  if veinCount >= MAX_VEIN or not fuelOk(4) or not roomLeft() then
    if roomLeft() then dig(d) end
    return
  end
  veinCount = veinCount + 1
  local depth = #st.vein
  local prev = status
  status = "Following vein"
  if not move(d, true) then status = prev return end
  veinSeen[key(pos.x, pos.y, pos.z)] = true
  scanFor({ UP, DOWN, st.h, (st.h + 1) % 4, (st.h + 3) % 4, (st.h + 2) % 4 })
  if target then scanEdges() end
  while #st.vein > depth do
    local back = st.vein[#st.vein]
    if not move(OPP[back]) then error("Cannot get back out of vein", 0) end
    st.vein[#st.vein] = nil
    save()
  end
  status = prev
end

local function vein(d, info)
  veinSeen, veinCount = {}, 0
  veinSeen[key(pos.x, pos.y, pos.z)] = true
  mineVein(d, isTarget(info))
end

-- Kijk in richting d: lava afdichten, erts uitgraven (met ader)
local function check(d)
  local info = inspect(d)
  if isLava(info) then seal(d) return "lava" end
  if isOre(info) then vein(d, info) return "ore" end
  return info
end

---------------------------------------------------------------------------
-- Tunnel graven
---------------------------------------------------------------------------
local function isOpen(r) return r == nil or (type(r) == "table" and isLiquid(r)) end

-- Als check(), maar een gat naar een grot (lucht/water) wordt dichtgezet,
-- zodat er geen mobs, water of lava de gangen in komen.
local function guard(d)
  local r = check(d)
  if isOpen(r) then seal(d) end
end

-- Een nieuwe tunnelcel in richting d (horizontaal), 1x1. Boven, onder en de wanden
-- wa/wb worden alleen bekeken (geen extra graafwerk, geen ruimte voor mobs).
-- caveStop: komt hij uit in een grot, dan gang dichtzetten en stoppen (zijgangen).
local function excavate(d, wa, wb, caveStop)
  local r = check(d)
  if r == "lava" and isLava(inspect(d)) then return false, "lava" end
  if caveStop and isOpen(r) then
    seal(d)
    return false, "cave"
  end
  local ok, why = move(d)
  if not ok then return false, why end
  guard(UP)
  guard(DOWN)
  guard(wa)
  guard(wb)
  return true
end

-- Schacht: een nieuwe cel omlaag graven en de 4 wanden 1x checken (3 draaiingen)
local function excavateDown()
  local r = check(DOWN)
  if r == "lava" and isLava(inspect(DOWN)) then return false, "lava" end
  local ok, why = move(DOWN)
  if not ok then return false, why end
  local h = st.h
  for i = 0, 3 do guard((h + i) % 4) end
  return true
end

local mineUntil = nil -- os.clock() waarop hij terug moet (max. graaftijd per trip)

local function stopReason()
  if recall then return "recalled" end
  if updateWanted then return "update" end
  if mineUntil and os.clock() > mineUntil then return "trip time up" end
  if not fuelOk(8) then
    burnMinedFuel()
    if not fuelOk(8) then return "fuel low" end
  end
  if not roomLeft() then return "inventory full" end
  return nil
end

local function level(y)
  local L = st.levels[y]
  if not L then
    L = { spine = 0, branch = 1, step = 0 }
    st.levels[y] = L
  end
  return L
end

-- Naar beneden door de (bestaande) schacht
local function descend(Y)
  st.phase = "descending"
  setStatus("Down the shaft to Y " .. Y)
  while pos.y > Y do
    local r = stopReason()
    if r then return r end
    if pos.y - 1 >= st.shaft then
      moveOrFail(DOWN, "Shaft blocked")
    else
      local ok, why = excavateDown()
      if not ok then error("Shaft: " .. tostring(why), 0) end
      st.shaft = pos.y
      save()
    end
    -- Luik dicht op vloerhoogte zodat niemand in de schacht valt
    if pos.y == HOME.y - 2 and not turtle.detectUp() then seal(UP) end
  end
  return nil
end

-- Mijn zijgangen op dit niveau tot er een reden is om naar huis te gaan
local function workLevel(j)
  local Y, BL = j.y, j.branchLen or BRANCH_LEN
  local L = level(Y)
  st.phase = "mining"
  mineUntil = j.mineMinutes and (os.clock() + j.mineMinutes * 60) or nil
  while true do
    local k = L.branch
    local junction = k * BRANCH_GAP
    -- Hoofdgang tot kruising k
    setStatus("Main tunnel to branch " .. k)
    while along(SPINE) < junction do
      local r = stopReason()
      if r then return r end
      if along(SPINE) < L.spine then
        moveOrFail(SPINE, "Main tunnel blocked")
      else
        local ok, why = excavate(SPINE, BRANCH, OPP[BRANCH])
        if not ok then
          L.blocked = why
          save()
          return "main tunnel blocked: " .. tostring(why)
        end
        L.spine = along(SPINE)
        save()
      end
    end
    -- Zijgang
    setStatus("Branch " .. k .. " (" .. L.step .. "/" .. BL .. ")")
    while along(BRANCH) < BL do
      local r = stopReason()
      if r then return r end
      local i = along(BRANCH) + 1
      if i <= L.step then
        moveOrFail(BRANCH, "Branch blocked")
      else
        local ok, why = excavate(BRANCH, SPINE, OPP[SPINE], true)
        if not ok then
          print("Branch " .. k .. " ended: " .. tostring(why))
          break
        end
        L.step = i
        save()
        if i % 8 == 0 then setStatus("Branch " .. k .. " (" .. i .. "/" .. BL .. ")") end
      end
    end
    L.branch = k + 1
    L.step = 0
    save()
    goAxis(axisOf(BRANCH), SHAFT[axisOf(BRANCH)])
  end
end

---------------------------------------------------------------------------
-- Thuis: lossen en tanken
---------------------------------------------------------------------------
local FUEL_NAMES = { ["minecraft:coal"] = true, ["minecraft:charcoal"] = true, ["minecraft:coal_block"] = true,
  ["minecraft:lava_bucket"] = true }

local function haulInto(h, s)
  local d = turtle.getItemDetail(s)
  if d then h[d.name] = (h[d.name] or 0) + d.count end
end

local function chestInFront()
  local ok, info = turtle.inspect()
  if not ok then return false end
  if info.name:find("chest") or info.name:find("barrel") or info.name:find("shulker") then return true end
  return hasTag(info, "c:chests") or hasTag(info, "forge:chests") or hasTag(info, "c:barrels")
end

local function unload()
  face(OPP[cfg.facing])
  local haul = {}
  local kept = false
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and (d.name == BUCKET or d.name == LAVA_BUCKET) then
      -- emmers houden: lege om lava te scheppen, volle om te verbranden
    elseif d then
      if not kept and isJunk(s) and sealable(s) then
        kept = true -- 1 stapel seal-blok houden
      elseif isJunk(s) then
        turtle.select(s)
        turtle.drop() -- restje troep van de schacht
      else
        haulInto(haul, s)
        turtle.select(s)
        if not turtle.drop() then print("Chest full!") end
      end
    end
  end
  turtle.select(1)
  return haul
end

local function emptySlot()
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then return s end end
  return nil
end

-- Zorg dat er brandstof op plek 1 van de kist ligt (via peripheral), anders zoeken met suck.
local function chestFuelFirst()
  local chest = peripheral.wrap("front")
  if not chest or not chest.list then return end
  local ok, list = pcall(chest.list)
  if not ok or not list then return end
  local fuelSlot
  for slot, it in pairs(list) do
    if FUEL_NAMES[it.name] and (not fuelSlot or slot < fuelSlot) then fuelSlot = slot end
  end
  if not fuelSlot or fuelSlot == 1 then return end
  local size = chest.size()
  if list[1] then
    local free
    for s = size, 2, -1 do if not list[s] then free = s break end end
    if not free then return end
    pcall(chest.pushItems, "front", 1, 64, free)
  end
  pcall(chest.pushItems, "front", fuelSlot, 64, 1)
end

local function refuelFromChest(target)
  if turtle.getFuelLevel() == "unlimited" then return end
  local limit = turtle.getFuelLimit()
  if target > limit - 100 then target = limit - 100 end
  -- Eerst volle lava-emmers uit de turtle zelf
  local lb = findItem(LAVA_BUCKET)
  while lb and turtle.getFuelLevel() < limit - 1000 do
    turtle.select(lb)
    turtle.refuel(1)
    lb = findItem(LAVA_BUCKET)
  end
  local tries = 0
  local held = {}
  while turtle.getFuelLevel() < target and tries < 32 do
    tries = tries + 1
    chestFuelFirst()
    local s = emptySlot()
    if not s then break end
    turtle.select(s)
    if not turtle.suck(64) then break end
    if turtle.refuel(0) then
      while turtle.getFuelLevel() < target and turtle.getItemCount(s) > 0 do
        if not turtle.refuel(1) then break end
      end
      local left = turtle.getItemDetail(s)
      -- 1 lege emmer houden om onderweg lava te scheppen, de rest terug in de kist
      if left and not (left.name == BUCKET and not findItem(BUCKET, s)) then turtle.drop() end
    else
      held[#held + 1] = s -- geen brandstof: even vasthouden, straks terug
    end
  end
  for _, s in ipairs(held) do turtle.select(s) turtle.drop() end
  turtle.select(1)
end

local function tripFuel(j)
  local L = st.levels[j.y] or { branch = 1 }
  local down = HOME.y - j.y
  local far = (L.branch + 2) * BRANCH_GAP + (j.branchLen or BRANCH_LEN)
  return math.max(MIN_TRIP_FUEL, 2 * (down + far) + 600)
end

---------------------------------------------------------------------------
-- Hub
---------------------------------------------------------------------------
local function openModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
      rednet.open(name)
      radio = true
    end
  end
end

local function mergeProgress(hp)
  if type(hp) ~= "table" then return end
  if type(hp.shaft) == "number" and hp.shaft < st.shaft then st.shaft = hp.shaft end
  for y, h in pairs(hp.levels or {}) do
    local L = level(y)
    if (h.branch or 0) > L.branch then
      L.branch, L.step = h.branch, h.step or 0
    elseif h.branch == L.branch and (h.step or 0) > L.step then
      L.step = h.step
    end
    if (h.spine or 0) > L.spine then L.spine = h.spine end
  end
end

-- Vraag iets aan de hub en wacht op een antwoord van het gegeven type
local function request(msg, replyType, timeout)
  if not radio then return nil end
  if not hubId then hubId = rednet.lookup(PROTOCOL, "hub") end
  if not hubId then return nil end
  rednet.send(hubId, msg, PROTOCOL)
  local timer = os.startTimer(timeout or 4)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and a == hubId and c == PROTOCOL and type(b) == "table" and b.type == replyType then
      return b
    elseif ev == "timer" and a == timer then
      hubId = nil
      return nil
    end
  end
end

local function askHub()
  return request({ type = "job?", id = os.getComputerID(), role = ROLE, hash = MY_HASH }, "job")
end

-- Nieuwe miner.lua van de hub halen, controleren, opslaan en herstarten.
-- Gebeurt alleen thuis (na het lossen), dus er gaat geen voortgang verloren.
local function selfUpdate(wanted)
  setStatus("Downloading update from hub")
  local r = request({ type = "get_miner", id = os.getComputerID() }, "miner_file", 10)
  if not r or type(r.code) ~= "string" then print("Update failed: no answer") return end
  if hashOf(r.code) ~= wanted then print("Update failed: corrupted") return end
  local fn, err = load(r.code, "miner", "t", _ENV)
  if not fn then print("Update failed: " .. tostring(err)) return end
  local tmp = PROGRAM .. ".new"
  local h = fs.open(tmp, "w")
  h.write(r.code)
  h.close()
  if fs.exists(PROGRAM) then fs.delete(PROGRAM) end
  fs.move(tmp, PROGRAM)
  setStatus("Updated, rebooting")
  sleep(1)
  os.reboot()
end

local function report(haul)
  if not (radio and hubId) then return end
  pcall(rednet.send, hubId, {
    type = "report", id = os.getComputerID(), role = ROLE, haul = haul,
    progress = { levels = st.levels, shaft = st.shaft },
  }, PROTOCOL)
end

local function getJob()
  if standaloneOre then
    local o = ORES[standaloneOre]
    return { ore = standaloneOre, y = o.y, targets = o.targets, branchLen = BRANCH_LEN }
  end
  local reply = askHub()
  if reply then
    if type(reply.update) == "string" and reply.update ~= MY_HASH then selfUpdate(reply.update) end
    updateWanted = false
    mergeProgress(reply.progress)
    if reply.paused or not reply.ore then return nil, "waiting for orders" end
    recall = false
    return { ore = reply.ore, y = reply.y, targets = reply.targets, branchLen = reply.branchLen or BRANCH_LEN,
      mineMinutes = reply.mineMinutes }
  end
  if st.job then return st.job, "hub unreachable, previous job" end
  return nil, "no hub found"
end

---------------------------------------------------------------------------
-- Hoofdlus
---------------------------------------------------------------------------
-- Bij opstarten: staat er een kist naast me, dan sta ik op mijn startplek
-- (onder de grond staan nooit kisten). Werkt ook als de turtle is opgepakt en
-- teruggezet, in welke richting dan ook. Positie en richting worden dan gereset;
-- de voortgang (gangen, schacht) blijft bewaard.
local function calibrateAtHome()
  for i = 0, 3 do
    if chestInFront() then
      -- De kist staat achter de startplek, dus ik kijk nu tegen de kijkrichting in
      st.h = OPP[cfg.facing]
      pos.x, pos.y, pos.z = HOME.x, HOME.y, HOME.z
      st.phase = "home"
      st.vein = {}
      st.pending = nil
      save()
      if i > 0 then print("Chest found: I am on my home spot") end
      return true
    end
    turtle.turnRight() -- 4x rechts = weer de oude richting als er geen kist is
  end
  return false
end

local function recover()
  if calibrateAtHome() then
    if st.job then setTargets(st.job.targets) end
    return
  end
  if st.pending then
    local f = turtle.getFuelLevel()
    if f ~= "unlimited" and f < st.pending.fuel then
      applyMove(st.pending.d)
      if st.pending.vein then st.vein[#st.vein + 1] = st.pending.d end
    end
    st.pending = nil
    save()
  end
  if st.job then setTargets(st.job.targets) end
  if st.phase ~= "home" or pos.x ~= HOME.x or pos.y ~= HOME.y or pos.z ~= HOME.z then
    print("Rebooted away from home, going back")
    goHome("reboot")
  end
end

local function trip(j)
  st.job = j
  st.found = 0
  setTargets(j.targets)
  save()
  if j.y > HOME.y - 3 then error("Level " .. j.y .. " is too close to home", 0) end
  mineUntil = nil
  if pos.x == HOME.x and pos.y == HOME.y and pos.z == HOME.z then
    st.phase = "descending"
    moveOrFail(cfg.facing, "Hole in front of the turtle blocked")
  end
  local reason = descend(j.y)
  if not reason then reason = workLevel(j) end
  goHome(reason)
end

local function worker()
  recover()
  while true do
    st.phase = "home"
    face(OPP[cfg.facing])
    while not chestInFront() do
      -- Geen kist = hij staat niet waar hij denkt. Niets weggooien, niet verder graven.
      setStatus("ERROR: no chest behind me. Put me on my home spot, Ctrl+T, type: miner home")
      sleep(30)
      face(OPP[cfg.facing])
    end
    setStatus("Unloading")
    local haul = unload()
    for n, c in pairs(haul) do st.total[n] = (st.total[n] or 0) + c end
    save()
    report(haul)
    local j, why = getJob()
    if not j then
      setStatus((tostring(why):gsub("^%l", string.upper)))
      sleep(10)
    elseif recall then
      setStatus("Recalled, waiting for hub")
      sleep(10)
    else
      setStatus("Refueling")
      local need = tripFuel(j)
      refuelFromChest(need)
      local f = turtle.getFuelLevel()
      local minimum = 2 * (HOME.y - j.y) + 200
      if f ~= "unlimited" and f < minimum then
        setStatus("Not enough fuel in the chest (" .. f .. "/" .. minimum .. ")")
        sleep(30)
      else
        setStatus("Heading out: " .. j.ore .. " at Y " .. j.y)
        local ok, err = pcall(trip, j)
        if not ok then
          if err == "Terminated" then error(err, 0) end
          setStatus("Error: " .. tostring(err))
          local ok2, err2 = pcall(goHome, "after error")
          if not ok2 then
            if err2 == "Terminated" then error(err2, 0) end
            setStatus("STUCK: " .. tostring(err2))
            sleep(30)
            pcall(recover)
          end
          sleep(5)
        end
      end
    end
  end
end

local function listener()
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and c == PROTOCOL and type(b) == "table" then
      if (b.type == "recall" or b.type == "go") and (b.target == nil or b.target == os.getComputerID()) then
        if b.from then hubId = b.from end
        recall = (b.type == "recall")
        publish(true)
      elseif b.type == "update" and type(b.hash) == "string" and b.hash ~= MY_HASH then
        if b.from then hubId = b.from end
        updateWanted = true
      end
    end
  end
end

local function heartbeat()
  while true do
    sleep(3)
    publish(true)
  end
end

openModem()
if not radio then print("No wireless modem: hub/dashboard will not work.") end
turtle.select(1)
parallel.waitForAny(worker, listener, heartbeat)
