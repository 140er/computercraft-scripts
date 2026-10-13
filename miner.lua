-- miner.lua - Mine Army turtle (CC: Tweaked)
--
-- One-time setup (see README):
--   miner setup <x> <y> <z> <facing> <role>
--     x y z   = world coordinates of the turtle (F3), e.g. -216 65 -743
--     facing  = direction the turtle faces: north/east/south/west
--     role    = direction of its main tunnel: east/south/west/north
--               (easternmost turtle = east, westernmost = west,
--                the two in the middle = south and north)
-- Then:
--   miner            listens to the hub (dashboard) for orders
--   miner diamond    works without a hub, mines diamonds (also: iron, gold, ...)
--   miner diamond fast   same, in fast mode
--   miner home       after putting it back on its home spot by hand: reset position
--
-- Chest with fuel directly BEHIND the turtle. Turtle needs a pickaxe + wireless/ender modem.
-- The turtle moves 1 block forward into its hole and digs a shaft down to the ore level,
-- reusing that shaft every trip. There it digs a main tunnel with a branch every 4 blocks
-- (3 blocks of rock between), 1x1. Openings into caves get sealed.

local VERSION = 2

-- Version = hash of this file's contents (same calculation as in hub.lua)
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

local BRANCH_LEN = 64      -- default branch length (the hub can override this)
local BRANCH_GAP = 4       -- thorough mode: a branch every 4 blocks = 3 blocks between
local FAST_GAP = 2         -- fast mode: a branch every 2 blocks = 1 block between, no wall checks
local FUEL_MARGIN = 64     -- extra fuel on top of the way home
local MIN_TRIP_FUEL = 2000 -- try to refuel at least this much
local JUNK_EVERY = 10      -- drop junk every ~10 dug blocks
local MAX_VEIN = 64        -- max blocks per vein
local REACH = 96           -- never go further than this from the shaft (stay in loaded chunks)
local LAYER_STEP = 3       -- when a level is full: next layer this many blocks higher
local MAX_LAYERS = 4       -- layers per ore before the area counts as full
local RETRY = 20

local ORES = {
  diamond  = { y = -58, targets = { "minecraft:diamond_ore", "minecraft:deepslate_diamond_ore" }, drops = { "minecraft:diamond" } },
  redstone = { y = -58, targets = { "minecraft:redstone_ore", "minecraft:deepslate_redstone_ore" }, drops = { "minecraft:redstone" } },
  gold     = { y = -16, targets = { "minecraft:gold_ore", "minecraft:deepslate_gold_ore" }, drops = { "minecraft:raw_gold" } },
  lapis    = { y = 0,   targets = { "minecraft:lapis_ore", "minecraft:deepslate_lapis_ore" }, drops = { "minecraft:lapis_lazuli" } },
  iron     = { y = 16,  targets = { "minecraft:iron_ore", "minecraft:deepslate_iron_ore" }, drops = { "minecraft:raw_iron" } },
  copper   = { y = 48,  targets = { "minecraft:copper_ore", "minecraft:deepslate_copper_ore" }, drops = { "minecraft:raw_copper" } },
  coal     = { y = 48,  targets = { "minecraft:coal_ore", "minecraft:deepslate_coal_ore" }, drops = { "minecraft:coal" } },
}

-- Directions: 0=north(-z) 1=east(+x) 2=south(+z) 3=west(-x) 4=up 5=down
local UP, DOWN = 4, 5
local DIRS = { north = 0, east = 1, south = 2, west = 3, n = 0, e = 1, s = 2, w = 3 }
local DIRNAME = { [0] = "north", "east", "south", "west", "up", "down" }
local DX = { [0] = 0, 1, 0, -1, 0, 0 }
local DY = { [0] = 0, 0, 0, 0, 1, -1 }
local DZ = { [0] = -1, 0, 1, 0, 0, 0 }
local OPP = { [0] = 2, 3, 0, 1, 5, 4 }

local args = { ... }

---------------------------------------------------------------------------
-- Files
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
-- The shaft is 1 block IN FRONT of the home spot (that is where the holes are)
local SHAFT = { x = HOME.x + DX[cfg.facing], z = HOME.z + DZ[cfg.facing] }
local reach = REACH -- set per trip from the hub's job
local function inReach(x, z)
  return math.abs(x - SHAFT.x) <= reach and math.abs(z - SHAFT.z) <= reach
end
local SPINE = cfg.spine
local BRANCH = (SPINE + 1) % 4
local ROLE = DIRNAME[SPINE]

if args[1] == "home" then
  -- Manual recovery: the turtle is (back) on its home spot, chest behind it.
  -- Progress (tunnels, shaft) is kept.
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
-- State (survives reboot / chunk unload)
---------------------------------------------------------------------------
local st = loadTable(STATE_FILE) or {}
st.pos = st.pos or { x = HOME.x, y = HOME.y, z = HOME.z }
st.h = st.h or cfg.facing
st.levels = st.levels or {}   -- [y] = { spine=, branch=, step= }
st.shaft = st.shaft or HOME.y -- lowest dug y in the shaft
st.vein = st.vein or {}       -- path of the current vein excursion
st.phase = st.phase or "home"
st.dug = st.dug or 0
st.found = st.found or 0      -- target ores this trip
st.total = st.total or {}
local pos = st.pos

local function save() saveTable(STATE_FILE, st) end

local status = "Starting"
local recall = false
local updateWanted = false -- hub released a new version: go home to update
local hubId = nil
local radio = false

local function job() return st.job end

---------------------------------------------------------------------------
-- Telemetry
---------------------------------------------------------------------------
local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end

local isLoot -- set further down, once the junk rules exist

local function packet()
  local j = st.job or {}
  local items = {}
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    -- only real loot: no junk, no seal blocks, no buckets
    if d and (not isLoot or isLoot(s, d)) then items[d.name] = (items[d.name] or 0) + d.count end
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
    lastError = st.lastError and st.lastError.msg, lastErrorAt = st.lastError and st.lastError.at,
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

-- Remember an error: shown on the dashboard and appended to miner.log (last 40 lines)
local function logError(msg)
  msg = tostring(msg)
  st.lastError = { msg = msg, at = os.epoch("utc") }
  pcall(function()
    local lines = {}
    if fs.exists("miner.log") then
      local h = fs.open("miner.log", "r")
      for line in h.readAll():gmatch("[^\n]+") do lines[#lines + 1] = line end
      h.close()
    end
    lines[#lines + 1] = os.date("%Y-%m-%d %H:%M") .. " " .. pos.x .. "," .. pos.y .. "," .. pos.z .. " " .. msg
    while #lines > 40 do table.remove(lines, 1) end
    local h = fs.open("miner.log", "w")
    h.write(table.concat(lines, "\n") .. "\n")
    h.close()
  end)
end

local function setStatus(s)
  status = s
  print(s)
  publish(true)
end

---------------------------------------------------------------------------
-- Block recognition
---------------------------------------------------------------------------
local TARGET = {}
-- "Only" mode (switch on the hub): mine only the target ore, everything else
-- (other ores too) counts as junk and gets dropped underground.
local ONLY = nil -- nil, or the set of item names to keep (what the target ore drops)
local function setTargets(list, job)
  TARGET = {}
  for _, n in ipairs(list or {}) do
    if not n:find(":") then n = "minecraft:" .. n end
    TARGET[n] = true
  end
  ONLY = nil
  local o = job and job.only and ORES[job.ore]
  if o and o.drops then
    ONLY = {}
    for _, n in ipairs(o.drops) do ONLY[n] = true end
    for n in pairs(TARGET) do ONLY[n] = true end -- the ore blocks themselves (silk touch)
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

-- Junk (gets dropped). Everything else is kept.
local JUNK = {}
for _, n in ipairs({ "cobblestone", "cobbled_deepslate", "stone", "deepslate", "granite", "diorite",
  "andesite", "tuff", "calcite", "dirt", "coarse_dirt", "rooted_dirt", "grass_block", "mud", "gravel",
  "sand", "red_sand", "sandstone", "netherrack", "basalt", "smooth_basalt", "blackstone",
  "dripstone_block", "pointed_dripstone", "flint", "clay_ball", "moss_block", "mossy_cobblestone",
  "soul_sand", "soul_soil", "end_stone", "amethyst_shard", "infested_stone", "infested_deepslate" }) do
  JUNK["minecraft:" .. n] = true
end
local junkCache = {}

local function isOreItem(d)
  if d.name:find("_ore$") or d.name:find(":raw_") or d.name:find(":ore_") then return true end
  for tag in pairs(d.tags or {}) do
    if tag == "c:ores" or tag == "forge:ores" or tag:find("^c:ores/") or tag:find("^forge:ores/")
      or tag:find("^c:raw_materials") or tag:find("^forge:raw_materials") then return true end
  end
  return false
end

-- What is worth keeping (in the turtle and in the chest): ores and what they drop
-- (raw ores, gems, dusts, also modded), fuel and buckets. Everything else is junk.
local KEEP_NAMES = {}
for _, n in ipairs({ "diamond", "emerald", "lapis_lazuli", "redstone", "coal", "charcoal", "coal_block",
  "quartz", "ancient_debris", "netherite_scrap", "gold_nugget", "bucket", "lava_bucket", "water_bucket" }) do
  KEEP_NAMES["minecraft:" .. n] = true
end
local KEEP_TAGS = { "c:ores", "forge:ores", "c:raw_materials", "forge:raw_materials", "c:gems",
  "forge:gems", "c:dusts", "forge:dusts", "minecraft:coals" }

local function keepDetail(d)
  if not d then return false end
  if JUNK[d.name] then return false end
  if KEEP_NAMES[d.name] or d.name:find("_ore$") or d.name:find(":raw_") or d.name:find(":ore_") then
    return true
  end
  for tag in pairs(d.tags or {}) do
    for _, k in ipairs(KEEP_TAGS) do
      if tag == k or tag:sub(1, #k + 1) == k .. "/" then return true end
    end
  end
  return false
end

-- Name parts that are always junk (all sandstone/terracotta/cobble variants)
local JUNK_PARTS = { "sandstone", "terracotta", "cobble" }

local function isJunk(slot)
  local d = turtle.getItemDetail(slot)
  if not d then return false end
  if ONLY then
    if d.name:find("bucket", 1, true) then return false end
    return not ONLY[d.name]
  end
  if JUNK[d.name] then return true end
  for _, part in ipairs(JUNK_PARTS) do
    if d.name:find(part, 1, true) then return true end
  end
  if KEEP_NAMES[d.name] then return false end
  if junkCache[d.name] == nil then
    junkCache[d.name] = not keepDetail(turtle.getItemDetail(slot, true) or d)
  end
  return junkCache[d.name]
end

-- Seal block: really placeable, not an ore, not fuel (coal is never used), not falling.
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
    if turtle.refuel(0) then ok = false end -- never use fuel (coal, wood)
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
-- Movement
---------------------------------------------------------------------------
-- Turning. The new heading is saved BEFORE each turn: a turn happens immediately
-- and the 8-tick animation after it is the biggest risk window for a reboot.
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

local BUCKET, LAVA_BUCKET, WATER_BUCKET = "minecraft:bucket", "minecraft:lava_bucket", "minecraft:water_bucket"

local function findItem(name, skip)
  for s = 1, 16 do
    if s ~= skip then
      local d = turtle.getItemDetail(s)
      if d and d.name == name then return s end
    end
  end
  return nil
end

-- Scoop lava with an empty bucket and burn it right away (+1000 fuel).
-- Only works on a lava source; flowing lava just gets sealed.
local function scoopLava(d)
  local f = turtle.getFuelLevel()
  if f == "unlimited" or f > turtle.getFuelLimit() - 1000 then return end
  if not isLava(inspect(d)) then return end -- only lava: never scoop water
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

-- Blocks that never lie on a route the turtle dug itself (gravel/sand can fall in,
-- seal blocks are cobble, so those are fine). Finding one means position/heading is off.
local NATURAL = {}
for _, n in ipairs({ "stone", "deepslate", "tuff", "granite", "diorite", "andesite", "calcite",
  "dirt", "grass_block", "smooth_basalt", "netherrack", "bedrock" }) do
  NATURAL["minecraft:" .. n] = true
end

-- Lava: scoop it as fuel first, then seal with the first placeable non-ore block
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

local function sealCount()
  local n = 0
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 and sealable(s) then n = n + turtle.getItemCount(s) end
  end
  return n
end

-- Get a seal block by digging natural rock next to the turtle, below first, then
-- above, then the walls (never in the direction it is going). Used when it ran out.
local function digSealBlock(notDir)
  for _, d in ipairs({ DOWN, UP, 0, 1, 2, 3 }) do
    if d ~= notDir then
      local info = inspect(d)
      if info and NATURAL[info.name] and info.name ~= "minecraft:bedrock" then
        local ok
        if d == DOWN then ok = turtle.digDown() elseif d == UP then ok = turtle.digUp()
        else face(d) ok = turtle.dig() end
        if ok and sealCount() > 0 then return true end
      end
    end
  end
  return false
end

-- Seal lava, digging a block for it first when the turtle has none left
local function sealLava(d)
  if seal(d) and not isLava(inspect(d)) then return true end
  if sealCount() == 0 and digSealBlock(d) then return seal(d) and not isLava(inspect(d)) end
  return false
end

-- The one junk stack kept for sealing lava: cobbled deepslate/cobblestone first,
-- then the biggest other placeable junk stack.
local SEAL_PREF = { ["minecraft:cobbled_deepslate"] = 1, ["minecraft:cobblestone"] = 2,
  ["minecraft:deepslate"] = 3, ["minecraft:stone"] = 4 }
local function sealStackSlot()
  local best, bestRank, bestCount
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 and isJunk(s) and sealable(s) then
      local d = turtle.getItemDetail(s)
      local rank = SEAL_PREF[d.name] or 9
      if not best or rank < bestRank or (rank == bestRank and d.count > bestCount) then
        best, bestRank, bestCount = s, rank, d.count
      end
    end
  end
  return best
end

local function keepOneSealStack(dropFn)
  local keep = sealStackSlot()
  for s = 1, 16 do
    if s ~= keep and turtle.getItemCount(s) > 0 and isJunk(s) then
      turtle.select(s)
      dropFn()
    end
  end
  turtle.select(1)
end

isLoot = function(slot, d)
  if d.name == "minecraft:bucket" or d.name == "minecraft:lava_bucket" or d.name == "minecraft:water_bucket" then
    return false
  end
  return not isJunk(slot)
end

local sinceDrop = 0
local function dropJunk()
  sinceDrop = 0
  if ONLY then -- "only" mode: burn mined coal instead of throwing it away
    for s = 1, 16 do
      if turtle.getItemCount(s) > 0 and isJunk(s) then
        turtle.select(s)
        local f = turtle.getFuelLevel()
        if f ~= "unlimited" and turtle.refuel(0) and f < turtle.getFuelLimit() - 1000 then turtle.refuel() end
      end
    end
    turtle.select(1)
  end
  keepOneSealStack(turtle.dropDown)
end

local function afterDig()
  st.dug = st.dug + 1
  sinceDrop = sinceDrop + 1
  if sinceDrop >= JUNK_EVERY or turtle.getItemCount(16) > 0 and freeSlots() == 0 then dropJunk() end
end

-- Digging with retries (gravel/sand, mobs). Returns false + reason on failure.
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
    local dug, why = digf()
    if dug then
      afterDig()
    elseif type(why) == "string" and why:lower():find("unbreakable") then
      return false, "unbreakable (" .. info.name .. ")" -- e.g. reinforced deepslate
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

-- One step, with the fuel trick so a reboot mid-move does not lose the position.
local function rawMove(d, inVein)
  local mv = turtle.forward
  if d == UP then mv = turtle.up elseif d == DOWN then mv = turtle.down else face(d) end
  -- inVein: true = step into a vein (push), "pop" = step back out (pop). Saved together
  -- with the move, so a reboot right after the move can't leave the vein list wrong.
  st.pending = { d = d, fuel = turtle.getFuelLevel(), vein = inVein }
  save()
  local ok, why = mv()
  if ok then
    applyMove(d)
    if inVein == "pop" then st.vein[#st.vein] = nil
    elseif inVein then st.vein[#st.vein + 1] = d end
  end
  st.pending = nil
  save()
  return ok, why
end

-- CC refuses to move a turtle into a chunk that is not loaded ("Cannot leave loaded world")
local UNLOADED = "outside loaded chunks"

-- Lava it can't seal: step back up to 2 blocks through its own (empty) tunnel, wait
-- for the flow to settle, then step forward again as far as it can. Callers work by
-- position, so it's fine if it ends up a block or two further back.
local function backOff(d)
  setStatus("Lava ahead, backing off")
  local back = OPP[d]
  local n = 0
  for _ = 1, 2 do
    if inspect(back) ~= nil or turtle.getFuelLevel() == 0 then break end
    if not rawMove(back) then break end
    n = n + 1
  end
  sleep(5)
  for _ = 1, n do
    local info = inspect(d)
    if isLava(info) and not sealLava(d) then return end
    info = inspect(d)
    if info and not isLiquid(info) and not dig(d) then return end
    if not rawMove(d) then return end
  end
end

-- Safe movement: never step into lava (seal it first), dig where needed.
local function move(d, inVein)
  local lavaTries = 0
  for attempt = 1, RETRY do
    local info = inspect(d)
    while isLava(info) do
      if sealLava(d) then
        info = inspect(d)
      else
        -- Can't seal it (e.g. lava keeps flowing in): back off a few blocks out of its
        -- way, give it time to settle or burn out, come back and try again.
        lavaTries = lavaTries + 1
        if lavaTries > 3 or d >= 4 or inVein then return false, "lava" end
        backOff(d)
        info = inspect(d)
      end
    end
    if info and not isLiquid(info) then
      local ok, why = dig(d)
      if not ok then
        if why:find("turtle") or why:find("computer") then sleep(1)
        else return false, why end
      end
    end
    if turtle.getFuelLevel() == 0 then return false, "out of fuel" end
    local moved, why = rawMove(d, inVein)
    if moved then
      publish(false)
      return true
    end
    if type(why) == "string" and why:lower():find("loaded") then return false, UNLOADED end
    if d == UP then turtle.attackUp() elseif d == DOWN then turtle.attackDown() else turtle.attack() end
    sleep(0.2 * math.min(attempt, 5))
  end
  return false, "blocked"
end

local LOST = "LOST"

-- Move along a route the turtle dug itself (shaft, main tunnel, branches, way home)
local function moveOrFail(d, what, inVein)
  local info = inspect(d)
  local hatch = d == DOWN and pos.x == SHAFT.x and pos.z == SHAFT.z and pos.y - 1 == HOME.y - 1
  if info and not hatch and (NATURAL[info.name] or isOre(info)) then
    error(LOST .. " at " .. pos.x .. "," .. pos.y .. "," .. pos.z .. ": rock where my tunnel should be", 0)
  end
  local ok, why = move(d, inVein)
  if not ok then error((what or "Stuck") .. ": " .. tostring(why), 0) end
end

---------------------------------------------------------------------------
-- Distance and the way home
---------------------------------------------------------------------------
local function along(d) -- distance from the shaft along direction d
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

-- Emergency refuel with fuel from the inventory
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
    moveOrFail(OPP[d], "Cannot get back out of vein", "pop")
  end
end

-- Move along an axis until the coordinate matches (through our own tunnels)
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

-- Back home via the known route: vein -> branch -> main tunnel -> shaft
local function goHome(reason)
  st.phase = "returning"
  save()
  setStatus("Going home: " .. (reason or ""))
  unwindVein()
  if pos.y < HOME.y - 2 then dropJunk() end
  -- Compare the height too. The "north" turtle's main tunnel runs right under
  -- the home spot; checking only x/z gave a false "home" there.
  if pos.x ~= HOME.x or pos.y ~= HOME.y or pos.z ~= HOME.z then
    if pos.x ~= SHAFT.x or pos.z ~= SHAFT.z then
      if st.job and st.job.y and pos.y ~= st.job.y then goAxis("y", st.job.y) end
      goAxis(axisOf(BRANCH), SHAFT[axisOf(BRANCH)])
      goAxis(axisOf(SPINE), SHAFT[axisOf(SPINE)])
      goAxis(axisOf(BRANCH), SHAFT[axisOf(BRANCH)])
    end
    goAxis("y", HOME.y)
    -- Close the hole again at floor level, so nobody falls in while the turtle is home
    if pos.x == SHAFT.x and pos.z == SHAFT.z and not turtle.detectDown() then seal(DOWN) end
    moveOrFail(OPP[cfg.facing], "Home spot blocked") -- 1 block back, chest behind it again
  end
  st.phase = "home"
  save()
end

---------------------------------------------------------------------------
-- Vein following
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
      if isLava(info) then sealLava(d)
      elseif isOre(info) and (isTarget(info) or not ONLY) then mineVein(d, isTarget(info)) end
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

-- Target ore: also the 12 edge neighbours (18 of 26), via side steps.
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
    if not allSeen(d, dirs) and fuelOk(4) and roomLeft() and inReach(pos.x + DX[d], pos.z + DZ[d]) then
      local info = inspect(d)
      if not isLava(info) and not isUnbreakable(info) then
        local depth = #st.vein
        if move(d, true) then
          veinSeen[key(pos.x, pos.y, pos.z)] = true
          scanFor(dirs)
          while #st.vein > depth do
            local back = st.vein[#st.vein]
            moveOrFail(OPP[back], "Cannot get back out of vein", "pop")
          end
        end
      end
    end
  end
end

mineVein = function(d, target)
  if not inReach(pos.x + DX[d], pos.z + DZ[d]) then
    if roomLeft() then dig(d) end -- mine the ore block, but don't step outside the reach
    return
  end
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
    moveOrFail(OPP[back], "Cannot get back out of vein", "pop")
  end
  status = prev
end

local function vein(d, info)
  veinSeen, veinCount = {}, 0
  veinSeen[key(pos.x, pos.y, pos.z)] = true
  mineVein(d, isTarget(info))
end

-- Look in direction d: seal lava, mine ore (with its vein)
local function check(d)
  local info = inspect(d)
  if isLava(info) then sealLava(d) return "lava" end
  if isOre(info) and (isTarget(info) or not ONLY) then vein(d, info) return "ore" end
  return info
end

---------------------------------------------------------------------------
-- Tunnel digging
---------------------------------------------------------------------------
local function isOpen(r) return r == nil or (type(r) == "table" and isLiquid(r)) end

-- Like check(), but an opening into a cave (air/water) gets sealed,
-- so no mobs, water or lava get into the tunnels.
-- A water bucket picked up by an older version: pour it into a cave opening
-- (sealed right after), so the turtle gets its empty bucket back for lava.
local function pourWaterBucket(d)
  local s = findItem(WATER_BUCKET)
  if not s then return end
  turtle.select(s)
  placeDir(d)
  turtle.select(1)
end

local function guard(d)
  local r = check(d)
  if isOpen(r) then
    if r == nil then pourWaterBucket(d) end
    seal(d)
    local i = inspect(d)
    if (not i or isLiquid(i)) and sealCount() == 0 and digSealBlock(d) then seal(d) end
  end
end

-- A new 1x1 tunnel cell in direction d (horizontal). Above, below and walls wa/wb
-- are only inspected (no extra digging, no room for mobs).
-- caveStop: if it runs into a cave, seal the tunnel end and stop (branches).
local function excavate(d, wa, wb, caveStop)
  local r = check(d)
  if caveStop and r == nil then
    seal(d)
    return false, "cave"
  end
  if type(r) == "table" and isLiquid(r) then seal(d) end -- water: plug it, then dig through
  local ok, why = move(d)
  if not ok then return false, why end
  guard(UP)
  guard(DOWN)
  if wa then guard(wa) end -- fast mode passes no walls: no turning
  if wb then guard(wb) end
  return true
end

-- Shaft: dig a new cell down and check the 4 walls once (3 turns)
local function excavateDown()
  check(DOWN)
  local ok, why = move(DOWN)
  if not ok then return false, why end
  local h = st.h
  for i = 0, 3 do guard((h + i) % 4) end
  return true
end

local mineUntil = nil -- os.clock() at which it must head back (max mining time per trip)
-- The hub's session timer, kept by the turtle itself (normal modems can't hear the hub
-- underground). Stored as real time in the state file, so it survives reboots.
local function nowMs() return os.epoch("utc") end

local function stopReason()
  if recall then return "recalled" end
  if updateWanted then return "update" end
  if mineUntil and os.clock() > mineUntil then return "trip time up" end
  -- Leave in time to be home when the session ends: ~0.5 s per block of the way back
  if st.sessionEnd and nowMs() + (distHome() * 0.5 + 20) * 1000 > st.sessionEnd then return "session time up" end
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

-- Down through the (existing) shaft
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
    -- Close the hatch at floor level so nobody falls into the shaft
    if pos.y == HOME.y - 2 and not turtle.detectUp() then seal(UP) end
  end
  return nil
end

-- Mine branches on this level until there is a reason to go home
local LEVEL_FULL = "level full"
local AREA_FULL = "area full"

-- Pick the layer to work on: the ore level, or a layer higher up when the lower
-- ones are full (every other layer has its branches shifted by 2 blocks).
local mode = "thorough" -- "thorough" or "fast", set per trip from the hub

-- Where branch L.branch starts along the main tunnel. Stored, so the spacing can
-- change between branches when you switch modes (older saves get it computed).
local function junctionOf(L)
  if L.junction == nil then L.junction = L.branch * BRANCH_GAP + (L.offset or 0) end
  return L.junction
end

local function pickLevel(base)
  for n = 0, MAX_LAYERS - 1 do
    local y = base + LAYER_STEP * n
    if y > HOME.y - 8 then break end
    local L = level(y)
    -- every other layer: branches shifted by half the spacing, so they fall in between
    if L.offset == nil then L.offset = (n % 2 == 1) and ((mode == "fast") and 1 or 2) or 0 end
    if not L.full then return y end
  end
  return nil
end

local function workLevel(j)
  local Y = j.y
  local BL = math.min(j.branchLen or BRANCH_LEN, reach)
  local L = level(Y)
  st.phase = "mining"
  -- Trip time limit only without a session timer; with one, the session decides
  -- (so all turtles come home together at the end instead of one by one).
  mineUntil = (j.mineMinutes and not st.sessionEnd) and (os.clock() + j.mineMinutes * 60) or nil
  while true do
    local k = L.branch
    local junction = junctionOf(L)
    local fast = (mode == "fast")
    if junction > reach then
      -- This layer is done within the reach; next trip takes the next layer
      L.full = true
      save()
      return LEVEL_FULL
    end
    -- Main tunnel up to junction k
    setStatus("Main tunnel to branch " .. k)
    while along(SPINE) < junction do
      local r = stopReason()
      if r then return r end
      if along(SPINE) < L.spine then
        -- Walking its old tunnel digs nothing: top up the seal blocks from the floor
        -- first, so lava that flowed in since the last trip can be sealed.
        if sealCount() < 8 then digSealBlock(UP) end
        moveOrFail(SPINE, "Main tunnel blocked")
      else
        local ok, why
        if fast then ok, why = excavate(SPINE) else ok, why = excavate(SPINE, BRANCH, OPP[BRANCH]) end
        if not ok and why == UNLOADED then return UNLOADED end
        if not ok then
          -- Something it can't get through (e.g. reinforced deepslate of an ancient city,
          -- lava it couldn't seal). Same spot on 2 trips: give up this layer, take the next.
          local here = along(SPINE)
          if L.blockedAt == here then L.blockedCount = (L.blockedCount or 1) + 1
          else L.blockedAt, L.blockedCount = here, 1 end
          L.blocked = why
          logError("Main tunnel blocked at " .. pos.x .. "," .. pos.y .. "," .. pos.z .. ": " .. tostring(why))
          if L.blockedCount >= 2 then
            L.full = true
            logError("Main tunnel blocked twice at the same spot: layer Y " .. Y .. " done, next trip takes the next layer")
          end
          save()
          return "main tunnel blocked: " .. tostring(why)
        end
        L.spine = along(SPINE)
        save()
      end
    end
    -- Branch
    setStatus("Branch " .. k .. " (" .. L.step .. "/" .. BL .. ")")
    while along(BRANCH) < BL do
      local r = stopReason()
      if r then return r end
      local i = along(BRANCH) + 1
      if i <= L.step then
        moveOrFail(BRANCH, "Branch blocked")
      else
        local ok, why
        if fast then ok, why = excavate(BRANCH, nil, nil, true)
        else ok, why = excavate(BRANCH, SPINE, OPP[SPINE], true) end
        if not ok and why == UNLOADED then return UNLOADED end -- not done: resume later
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
    L.junction = junction + (fast and FAST_GAP or BRANCH_GAP)
    L.step = 0
    save()
    goAxis(axisOf(BRANCH), SHAFT[axisOf(BRANCH)])
  end
end

---------------------------------------------------------------------------
-- Home: unload and refuel
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
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and (d.name == BUCKET or d.name == LAVA_BUCKET or d.name == WATER_BUCKET) then
      -- keep buckets: empty ones to scoop lava, full ones to burn
    elseif d then
      if isJunk(s) then
        -- junk never goes into the chest: the seal stack stays, the rest is dropped underground
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

-- Put fuel in slot 1 of the chest (via peripheral); otherwise search with suck.
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
  -- First full lava buckets from the turtle itself
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
      -- keep 1 empty bucket to scoop lava on the way, the rest back in the chest
      if left and not (left.name == BUCKET and not findItem(BUCKET, s)) then turtle.drop() end
    else
      held[#held + 1] = s -- not fuel: hold it for now, put it back later
    end
  end
  for _, s in ipairs(held) do turtle.select(s) turtle.drop() end
  turtle.select(1)
end

-- Move chest slot 'slot' to chest slot 1, so turtle.suck() takes exactly that stack
local function chestToFront(chest, list, slot)
  if slot == 1 then return true end
  if list[1] then
    local free
    for e = chest.size(), 2, -1 do if not list[e] then free = e break end end
    if not free then return false end
    if not pcall(chest.pushItems, "front", 1, 64, free) then return false end
  end
  return (pcall(chest.pushItems, "front", slot, 64, 1))
end

-- Make sure the turtle carries a bucket to scoop lava with. If it has none, take one
-- from the chest: a full lava bucket if there is one (burned when refueling), else an
-- empty one. Without the chest peripheral: look through the first stacks with suck.
local noBucketUntil = 0
local function ensureBucket()
  if findItem(BUCKET) or findItem(LAVA_BUCKET) or findItem(WATER_BUCKET) then return true end
  if os.clock() < noBucketUntil then return false end
  local chest = peripheral.wrap("front")
  if chest and chest.list and chest.pushItems then
    local ok, list = pcall(chest.list)
    if ok and type(list) == "table" then
      local pick
      for slot, it in pairs(list) do
        if it.name == LAVA_BUCKET then pick = slot break end
        if it.name == BUCKET and not pick then pick = slot end
      end
      if pick and chestToFront(chest, list, pick) then
        local s = emptySlot()
        if s then
          turtle.select(s)
          turtle.suck(1)
          local d = turtle.getItemDetail(s)
          turtle.select(1)
          if d and (d.name == BUCKET or d.name == LAVA_BUCKET) then return true end
          if d then turtle.select(s) turtle.drop() turtle.select(1) end
        end
      end
    end
  end
  -- Fallback: take stacks one by one, keep 1 bucket, put everything else back
  local held, got = {}, false
  for _ = 1, 8 do
    local s = emptySlot()
    if not s or freeSlots() <= 1 then break end
    turtle.select(s)
    if not turtle.suck(64) then break end
    local d = turtle.getItemDetail(s)
    held[#held + 1] = s
    if d and (d.name == BUCKET or d.name == LAVA_BUCKET) then got = s break end
  end
  for _, s in ipairs(held) do
    turtle.select(s)
    if s == got then
      if turtle.getItemCount(s) > 1 then turtle.drop(turtle.getItemCount(s) - 1) end
    else
      turtle.drop()
    end
  end
  turtle.select(1)
  if not got then noBucketUntil = os.clock() + 600 end -- don't shuffle the chest every minute
  return got and true or false
end

-- Clean the chest: only ores, fuel and buckets may stay. Anything else is moved
-- to chest slot 1 (via the chest peripheral), sucked into the turtle and dropped
-- underground on the next trip. Returns the number of stacks removed.
local function cleanChest()
  local chest = peripheral.wrap("front")
  if not chest or not chest.list or not chest.pushItems then return 0 end
  local removed = 0
  for _ = 1, 12 do
    if freeSlots() <= 2 then break end
    local ok, list = pcall(chest.list)
    if not ok or type(list) ~= "table" then break end
    local bad
    for slot = 1, chest.size() do
      local it = list[slot]
      if it then
        local d = it
        if chest.getItemDetail then
          local ok2, full = pcall(chest.getItemDetail, slot)
          if ok2 and full then d = full end
        end
        if not keepDetail(d) then bad = slot break end
      end
    end
    if not bad then break end
    if not chestToFront(chest, list, bad) then break end
    local s = emptySlot()
    turtle.select(s)
    if not turtle.suck(64) then break end
    local got = turtle.getItemDetail(s, true)
    if keepDetail(got) then
      -- moving inside the chest did not work: put it back and stop cleaning
      turtle.drop()
      break
    end
    removed = removed + 1
  end
  turtle.select(1)
  return removed
end

local function tripFuel(j)
  local L = st.levels[j.y] or { branch = 1 }
  local down = HOME.y - j.y
  local far = math.min(reach, (L.junction or L.branch * BRANCH_GAP) + 8) + (j.branchLen or BRANCH_LEN)
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
      if h.junction then L.junction = h.junction end
    elseif h.branch == L.branch and (h.step or 0) > L.step then
      L.step = h.step
    end
    if (h.spine or 0) > L.spine then L.spine = h.spine end
    if h.full then L.full = true end
    if L.offset == nil and h.offset ~= nil then L.offset = h.offset end
  end
end

-- Ask the hub something and wait for a reply of the given type
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

-- Fetch a new miner.lua from the hub, verify it, save it and reboot.
-- Only happens at home (after unloading), so no progress is lost.
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
    return { ore = standaloneOre, y = o.y, targets = o.targets, branchLen = BRANCH_LEN,
      mode = (args[2] == "fast" or args[3] == "fast") and "fast" or "thorough",
      only = (args[2] == "only" or args[3] == "only") or nil }
  end
  local reply = askHub()
  if reply then
    if type(reply.update) == "string" and reply.update ~= MY_HASH then selfUpdate(reply.update) end
    updateWanted = false
    mergeProgress(reply.progress)
    if reply.paused or not reply.ore then return nil, "waiting for orders" end
    recall = false
    return { ore = reply.ore, y = reply.y, targets = reply.targets, branchLen = reply.branchLen or BRANCH_LEN,
      mineMinutes = reply.mineMinutes, reach = reply.reach, stopIn = reply.stopIn, mode = reply.mode,
      only = reply.only and true or nil }
  end
  return nil, "no hub found (staying home)"
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Lost: go up to the surface, build a marker pillar and wait to be picked up
---------------------------------------------------------------------------
-- Blocks a lost turtle may dig on its way up: natural ground only. Never cobble,
-- planks, logs or anything else that could be part of a base.
local GROUND_TAGS = { "minecraft:base_stone_overworld", "minecraft:dirt", "minecraft:sand",
  "minecraft:leaves", "minecraft:snow", "c:ores", "forge:ores", "c:gravels", "c:sands" }
local function groundBlock(info)
  if not info or isLiquid(info) then return true end
  if NATURAL[info.name] or FALLING[info.name] or isOre(info) then return true end
  for _, t in ipairs(GROUND_TAGS) do if hasTag(info, t) then return true end end
  return false
end

local PILLAR = 8      -- marker pillar height
local SKY_AIR = 6     -- this many air blocks in a row above Y = home means open air
local approxPos = false

local function lostWait()
  while true do
    setStatus("LOST: on a pillar at " .. pos.x .. "," .. pos.y .. "," .. pos.z .. (approxPos and " (approx)" or ""))
    sleep(30)
  end
end

local function lostBeacon(why)
  print(tostring(why))
  st.phase = "lost"
  st.vein = {}
  save()
  setStatus("LOST: going up to the surface")
  local airRun, sidesteps = 0, 0
  while not (pos.y >= HOME.y and airRun >= SKY_AIR) and pos.y < 250 do
    if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 10 then
      burnMinedFuel()
      if turtle.getFuelLevel() < 10 then break end
    end
    local info = inspect(UP)
    if groundBlock(info) and move(UP) then
      if info == nil then airRun = airRun + 1 else airRun = 0 end
    else
      -- Not natural ground above (or stuck): step aside in any direction and try there
      sidesteps = sidesteps + 1
      if sidesteps > 16 then break end
      local moved = false
      for _ = 1, 4 do
        face((st.h + 1) % 4)
        local side = inspect(st.h)
        if groundBlock(side) and not isLava(side) and move(st.h) then moved = true break end
      end
      if not moved then break end
      approxPos = true -- heading is unknown, so x/z are a guess from here on
      airRun = 0
    end
  end
  setStatus("LOST: building a marker pillar")
  for _ = 1, PILLAR do
    if turtle.detectUp() or not move(UP) then break end
    seal(DOWN)
  end
  st.lostAt = { x = pos.x, y = pos.y, z = pos.z, approx = approxPos }
  save()
  lostWait()
end

-- On boot: a chest next to me means I am on my home spot (there are never
-- chests underground). Also works when the turtle was picked up and put back,
-- facing any direction. Position and heading get reset; progress
-- (tunnels, shaft) is kept.
local function calibrateAtHome()
  for i = 0, 3 do
    if chestInFront() then
      -- The chest is behind the home spot, so I now face opposite to my facing
      st.h = OPP[cfg.facing]
      pos.x, pos.y, pos.z = HOME.x, HOME.y, HOME.z
      st.phase = "home"
      st.vein = {}
      st.pending = nil
      save()
      if i > 0 then print("Chest found: I am on my home spot") end
      return true
    end
    -- face() saves the heading before every turn, so a reboot during this search
    -- can't leave the turtle with a wrong idea of where it faces
    face((st.h + 1) % 4)
  end
  return false
end

local function recover()
  if calibrateAtHome() then
    if st.job then setTargets(st.job.targets, st.job) end
    return
  end
  if st.pending then
    local f = turtle.getFuelLevel()
    if f ~= "unlimited" and f < st.pending.fuel then
      applyMove(st.pending.d)
      if st.pending.vein == "pop" then st.vein[#st.vein] = nil
      elseif st.pending.vein then st.vein[#st.vein + 1] = st.pending.d end
    end
    st.pending = nil
    save()
  end
  if st.job then setTargets(st.job.targets, st.job) end
  if st.phase == "lost" then
    -- Waiting to be picked up: never wander off. Put me back home to continue.
    approxPos = st.lostAt and st.lostAt.approx or false
    lostWait()
  end
  if st.phase ~= "home" or pos.x ~= HOME.x or pos.y ~= HOME.y or pos.z ~= HOME.z then
    print("Rebooted away from home, going back")
    goHome("reboot")
  end
end

-- Heading check at the bottom of the shaft: the only opening there is this level's
-- main tunnel. If it shows up on another side than expected, correct the heading.
local function shaftCompass(L)
  if not L or (L.spine or 0) < 1 or pos.x ~= SHAFT.x or pos.z ~= SHAFT.z then return end
  local open = {}
  for _ = 1, 4 do
    local ok, info = turtle.inspect()
    if not ok or isLiquid(info) then open[#open + 1] = st.h end
    face((st.h + 1) % 4)
  end
  if #open ~= 1 then return end -- unclear (cave, vein hole): keep what we have
  local err = (SPINE - open[1]) % 4
  if err ~= 0 then
    st.h = (st.h + err) % 4
    save()
    print("Heading corrected at the shaft (" .. err .. " quarter turns)")
  end
end

local function trip(j0)
  reach = j0.reach or REACH
  mode = (j0.mode == "fast") and "fast" or "thorough"
  st.sessionEnd = j0.stopIn and (nowMs() + j0.stopIn * 1000) or nil
  local base = j0.baseY or j0.y
  local Y = pickLevel(base)
  if not Y then return AREA_FULL end
  local j = {}
  for k, v in pairs(j0) do j[k] = v end
  j.baseY, j.y = base, Y
  st.job = j
  st.found = 0
  setTargets(j.targets, j)
  save()
  if j.y > HOME.y - 3 then error("Level " .. j.y .. " is too close to home", 0) end
  mineUntil = nil
  if pos.x == HOME.x and pos.y == HOME.y and pos.z == HOME.z then
    st.phase = "descending"
    moveOrFail(cfg.facing, "Hole in front of the turtle blocked")
  end
  local reason = descend(j.y)
  if not reason then
    shaftCompass(level(Y))
    dropJunk() -- junk from home (shaft, cleaned chest) goes here, not in the base
    reason = workLevel(j)
  end
  goHome(reason)
  return reason
end

local function worker()
  while true do
    local ok, err = pcall(recover)
    if ok then break end
    if err == "Terminated" then error(err, 0) end
    if tostring(err):find("^" .. LOST) then lostBeacon(err) end
    logError(err)
    setStatus("STUCK: " .. tostring(err))
    sleep(60)
  end
  while true do
    st.phase = "home"
    face(OPP[cfg.facing])
    if not chestInFront() then calibrateAtHome() end
    while not chestInFront() do
      -- No chest = it is not where it thinks. Drop nothing, mine nothing.
      setStatus("ERROR: no chest behind me. Put me on my home spot, Ctrl+T, type: miner home")
      sleep(30)
      face(OPP[cfg.facing])
    end
    setStatus("Unloading")
    local haul = unload()
    local cleaned = cleanChest()
    if not ensureBucket() then print("No bucket: put an empty bucket in the chest to scoop lava") end
    if cleaned > 0 then print("Removed " .. cleaned .. " junk stacks from the chest") end
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
        if ok and err == AREA_FULL then
          setStatus("Area full for " .. j.ore .. ": pick another ore or raise the reach")
          sleep(60)
        elseif ok and err == UNLOADED or not ok and tostring(err):find(UNLOADED, 1, true) then
          -- Next tunnel block is in a chunk that is not loaded: wait instead of retrying right away
          if not ok then pcall(goHome, UNLOADED) end
          setStatus("Waiting: work area not loaded (stay closer to it)")
          sleep(60)
        elseif not ok then
          if err == "Terminated" then error(err, 0) end
          if tostring(err):find("^" .. LOST) then lostBeacon(err) end
          logError(err)
          setStatus("Error: " .. tostring(err))
          local ok2, err2 = pcall(goHome, "after error")
          if not ok2 then
            if err2 == "Terminated" then error(err2, 0) end
            if tostring(err2):find("^" .. LOST) then lostBeacon(err2) end
            logError(err2)
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
