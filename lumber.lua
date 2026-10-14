-- lumber.lua - tree farming turtle (CC: Tweaked)
--
-- Put a felling turtle (a turtle with an axe) somewhere in the open with a chest
-- directly BEHIND it. It searches the area around that spot for trees by itself,
-- fells them, replants a sapling in the same place and keeps coming back to every
-- tree it planted. Logs go in the chest; it refuels itself from the wood.
--
-- One-time setup:
--   lumber setup [radius]   radius = how far from the chest it may go (default 48)
-- Then:
--   lumber          run (started automatically on boot after setup)
--   lumber home     after putting it back on its home spot by hand: reset position
--   lumber reset    forget the trees it knows and search the whole area again
--
-- How it works:
--  * Searching: it walks over the ground in a square spiral around the chest, lines
--    3 blocks apart, and looks left and right for tree trunks. It climbs over hills,
--    steps down into dips and floats over water. Where it can't walk, it flies.
--  * Felling: it cuts the whole trunk and, while it is short of saplings, the whole
--    crown of leaves (that's where saplings come from). Then it plants a sapling of
--    the same kind on the spot.
--  * Spare saplings are planted in a grid near the chest; those become spots too.
--  * Farming: every tree it planted is a "spot". Spots are visited again once a
--    sapling has had time to grow (bone meal in the turtle helps). It flies to them
--    over the trees and comes down through the leaves.
--  * When the area is fully searched, or it has MAX_SPOTS spots, it only farms.
-- Works for 1x1 trees (oak, birch, spruce, jungle, acacia, cherry). Dark oak is left
-- alone; 2x2 giant spruce/jungle trees get only one of their 4 columns cut.
-- It never digs ground or stone: only logs, leaves and small plants.

local CFG_FILE, STATE_FILE, LOG_FILE = "lumber.cfg", "lumber.state", "lumber.log"

local RADIUS = 48          -- default search radius (setup can change it)
local SPACING = 3          -- search lines this far apart (it looks 1 block to each side)
local MAX_SPOTS = 64       -- trees it farms at most (found ones + ones it planted itself)
local NURSERY_RADIUS = 15  -- spare saplings are planted in a grid 3 apart within this distance of the chest
local SAPLING_RESERVE = 6  -- saplings kept for replanting before it plants spare ones
local REGROW_MIN = 20      -- minutes before a planted sapling is checked again (it takes ~16 on average)
local EXPLORE_CELLS = 50   -- search cells per trip (one cell = SPACING blocks of walking)
local HOP = 3              -- fly this many blocks above the highest point of a flight
local WAIT = 120           -- seconds to wait at home when there is nothing to do
local MAX_HEIGHT = 40      -- never climb higher than this inside one tree
local TREE_FUEL = 40       -- fuel kept aside for felling one tree (up and down, around the crown)
local LEAF_RINGS = true    -- cut the whole crown for saplings (about 20 fuel per tree)...
local SAPLING_WANT = 24    -- ...but only while it has fewer saplings than this
local KEEP_SAPLINGS = 64   -- saplings of each kind it keeps; the rest goes in the chest
local BONEMEAL_TRIES = 3   -- bone meal per sapling per visit (if it has any)
local FUEL_MARGIN = 30
local RETRY = 20

-- Directions relative to the home spot:
-- 0 = forward, 1 = right, 2 = back (chest), 3 = left, 4 = up, 5 = down
local UP, DOWN = 4, 5
local DF = { [0] = 1, 0, -1, 0, 0, 0 }
local DS = { [0] = 0, 1, 0, -1, 0, 0 }
local DY = { [0] = 0, 0, 0, 0, 1, -1 }
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

local function hasTag(info, t) return info and info.tags and info.tags[t] end

local function isChest(info)
  if not info then return false end
  if info.name:find("chest") or info.name:find("barrel") then return true end
  return hasTag(info, "c:chests") or hasTag(info, "forge:chests") or hasTag(info, "c:barrels")
end

---------------------------------------------------------------------------
-- Setup and commands
---------------------------------------------------------------------------
if args[1] == "setup" then
  local radius = tonumber(args[2] or RADIUS)
  if not radius or radius < 4 then
    print("Usage: lumber setup [radius]   (default " .. RADIUS .. ")")
    return
  end
  if turtle then
    turtle.turnLeft() turtle.turnLeft()
    local ok, info = turtle.inspect()
    turtle.turnLeft() turtle.turnLeft()
    if not (ok and isChest(info)) then print("WARNING: no chest found behind the turtle!") end
  end
  saveTable(CFG_FILE, { radius = math.floor(radius) })
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("lumber")\n')
  h.close()
  os.setComputerLabel(os.getComputerLabel() or "Lumberjack")
  print("Saved. It searches up to " .. math.floor(radius) .. " blocks from its chest.")
  print("Start with: lumber   (or reboot the turtle)")
  return
end

if not turtle then error("lumber.lua only runs on a turtle", 0) end
local cfg = loadTable(CFG_FILE)
if not cfg then
  print("Not set up yet. First: lumber setup [radius]")
  return
end
local R = cfg.radius or RADIUS

if args[1] == "home" or args[1] == "reset" then
  local s0 = loadTable(STATE_FILE) or {}
  if args[1] == "home" then
    s0.pos = { f = 0, s = 0, y = 0 }
    s0.h = 0
    s0.pending, s0.tree, s0.top = nil, nil, nil
    print("Position reset to the home spot (chest behind the turtle).")
  else
    s0.spots, s0.cursor, s0.bad = {}, nil, nil
    print("Forgot all trees. It searches the area again.")
  end
  saveTable(STATE_FILE, s0)
  print("Start with: lumber")
  return
end

---------------------------------------------------------------------------
-- State (survives reboot / chunk unload)
---------------------------------------------------------------------------
local st = loadTable(STATE_FILE) or {}
st.pos = st.pos or { f = 0, s = 0, y = 0 }
st.h = st.h or 0
st.spots = st.spots or {}  -- ["f,s"] = { f=, s=, y= (ground level), t= (planted / last checked) }
st.cursor = st.cursor or 2 -- next cell of the search spiral (cell 1 is home)
st.felled = st.felled or 0 -- trees felled, all time
st.logs = st.logs or 0     -- logs harvested, all time: counted as items (into the chest or burned)
local pos = st.pos

local function save() saveTable(STATE_FILE, st) end
local function now() return os.epoch("utc") end

local function applyMove(d)
  pos.f, pos.s, pos.y = pos.f + DF[d], pos.s + DS[d], pos.y + DY[d]
end

-- A reboot during a move: the fuel tells whether the move happened
if st.pending then
  local f = turtle.getFuelLevel()
  if f ~= "unlimited" and f < st.pending.fuel then applyMove(st.pending.d) end
  st.pending = nil
  save()
end

local status = ""
local function setStatus(s)
  if s == status then return end
  status = s
  print(os.date("%H:%M") .. " " .. s)
end

local function at() return pos.f .. "," .. pos.s .. "," .. pos.y end

-- Remember an error in lumber.log (last 40 lines)
local function logError(msg)
  msg = tostring(msg)
  pcall(function()
    local lines = {}
    if fs.exists(LOG_FILE) then
      local h = fs.open(LOG_FILE, "r")
      for line in h.readAll():gmatch("[^\n]+") do lines[#lines + 1] = line end
      h.close()
    end
    lines[#lines + 1] = os.date("%Y-%m-%d %H:%M") .. " " .. at() .. " " .. msg
    while #lines > 40 do table.remove(lines, 1) end
    local h = fs.open(LOG_FILE, "w")
    h.write(table.concat(lines, "\n") .. "\n")
    h.close()
  end)
end

---------------------------------------------------------------------------
-- Blocks and items
---------------------------------------------------------------------------
local function isLog(info)
  if not info or info.name:find("leaves") then return false end
  return hasTag(info, "minecraft:logs") or info.name:find("_log$") ~= nil
end
-- A log it may cut: not dark oak (always 2x2)
local function isTreeLog(info) return isLog(info) and not info.name:find("dark_oak") end
local function isLeaves(info)
  if not info then return false end
  return hasTag(info, "minecraft:leaves") or info.name:find("leaves") ~= nil
end
local function isSapling(info)
  if not info then return false end
  return hasTag(info, "minecraft:saplings") or info.name:find("sapling") ~= nil or info.name:find("propagule") ~= nil
end
local PLANTS = { "vine", "short_grass", "tall_grass", "fern", "flower", "dead_bush", "snow", "lichen",
  "moss_carpet", "sweet_berry", "dandelion", "poppy", "tulip", "orchid", "allium", "bluet", "daisy",
  "cornflower", "lily_of_the_valley", "rose_bush", "lilac", "peony", "sunflower" }
local function isPlant(info)
  if info.name:find("pot") then return false end -- flower pots
  if hasTag(info, "minecraft:replaceable") or hasTag(info, "minecraft:flowers") then return true end
  if info.name == "minecraft:grass" then return true end -- short grass before 1.20.3
  for _, p in ipairs(PLANTS) do
    if info.name:find(p, 1, true) then return true end
  end
  return false
end

-- air, soft (leaves/plants: cut away), log, sapling, water, lava, solid
local function classify(info)
  if not info then return "air" end
  local n = info.name
  if n:find("lava") then return "lava" end
  if n == "minecraft:water" or n == "minecraft:bubble_column" then return "water" end
  if isLog(info) then return "log" end
  if isSapling(info) then return "sapling" end
  if isLeaves(info) or isPlant(info) then return "soft" end
  return "solid"
end

local function canPlantOn(info)
  if not info then return false end
  if hasTag(info, "minecraft:dirt") then return true end
  local n = info.name
  return n == "minecraft:dirt" or n:find("grass_block") ~= nil or n:find("podzol") ~= nil
    or n:find("coarse_dirt") ~= nil or n:find("rooted_dirt") ~= nil or n:find("mycelium") ~= nil
    or n:find("moss_block") ~= nil or n == "minecraft:mud"
end

local function isSaplingItem(d) return d.name:find("sapling") ~= nil or d.name:find("propagule") ~= nil end
-- Saplings it plants: not dark oak (one alone never grows)
local function isPlantable(d) return isSaplingItem(d) and not d.name:find("dark_oak") end
local function isLogItem(d) return d.name:find("_log$") ~= nil and not d.name:find("leaves") end
local function isBoneMeal(d) return d.name == "minecraft:bone_meal" end

local function saplingFor(logName)
  if not logName then return nil end
  if logName == "minecraft:mangrove_log" then return "minecraft:mangrove_propagule" end
  return (logName:gsub("_log$", "_sapling"))
end

local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end

local function findSlot(test)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and test(d) then return s end
  end
  return nil
end

local function countLogs()
  local n = 0
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and isLogItem(d) then n = n + d.count end
  end
  return n
end

local function saplingCount()
  local n = 0
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and isPlantable(d) then n = n + d.count end
  end
  return n
end

local function haveSapling() return findSlot(isPlantable) ~= nil end

---------------------------------------------------------------------------
-- Fuel
---------------------------------------------------------------------------
local function fuel()
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return math.huge end
  return f
end

-- Burn fuel from the inventory up to 'target': coal, sticks etc. first, logs last.
-- Saplings are never burned.
local function burn(target)
  if fuel() >= target then return true end
  local limit = turtle.getFuelLimit()
  if target > limit then target = limit end
  for pass = 1, 2 do
    for s = 1, 16 do
      local d = turtle.getItemDetail(s)
      if d and not isSaplingItem(d) and (pass == 2) == isLogItem(d) then
        turtle.select(s)
        while fuel() < target and turtle.getItemCount(s) > 0 do
          if not turtle.refuel(1) then break end
          if pass == 2 then st.logs = st.logs + 1 end
        end
      end
      if fuel() >= target then turtle.select(1) return true end
    end
  end
  turtle.select(1)
  return fuel() >= target
end

-- Fuel to get home from here (up over the trees, across, down)
local function homeCost()
  return math.abs(pos.f) + math.abs(pos.s) + math.abs(pos.y) + 2 * HOP + 20
end

local TARGET_FUEL = 2 * R + 2 * HOP + 200 -- topped up to this at home

-- Fuel to spare for extras (leaf crowns, planting spares) instead of just felling?
local function fuelToSpare()
  return fuel() >= homeCost() + TARGET_FUEL / 2
end

-- Enough fuel to do 'extra' more and still get home? Burns wood if needed.
local function fuelFor(extra)
  local need = homeCost() + extra + FUEL_MARGIN
  return fuel() >= need or burn(need)
end

---------------------------------------------------------------------------
-- Movement
---------------------------------------------------------------------------
-- The new heading is saved BEFORE each turn (same as miner.lua)
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

local function dig(d, info)
  local ok, why
  if d == UP then ok, why = turtle.digUp()
  elseif d == DOWN then ok, why = turtle.digDown()
  else face(d) ok, why = turtle.dig() end
  if not ok and type(why) == "string" and why:lower():find("tool") then error("No axe: " .. why, 0) end
  return ok, why
end

local function rawMove(d)
  local mv = turtle.forward
  if d == UP then mv = turtle.up elseif d == DOWN then mv = turtle.down else face(d) end
  st.pending = { d = d, fuel = turtle.getFuelLevel() }
  save()
  local ok = mv()
  if ok then applyMove(d) end
  st.pending = nil
  save()
  return ok
end

-- One step. Cuts leaves and plants (and logs when cutLogs is set) in the way.
-- Returns false when something else is in the way: ground, a build, a trunk, lava.
local function step(d, cutLogs)
  for attempt = 1, RETRY do
    local info = inspect(d)
    local c = classify(info)
    if c == "soft" or (c == "log" and cutLogs) then
      dig(d, info)
    elseif c ~= "air" and c ~= "water" then
      return false
    end
    if fuel() == 0 and not burn(homeCost()) then error("Out of fuel", 0) end
    if rawMove(d) then return true end
    -- A mob or player in the way: wait first, hit it only if it doesn't go away
    if attempt > 5 and inspect(d) == nil then
      if d == UP then turtle.attackUp() elseif d == DOWN then turtle.attackDown() else turtle.attack() end
    end
    sleep(0.5)
  end
  return false
end

-- Up to height y. Something above it (a branch, an overhang): slide sideways and retry.
local function rise(y)
  local slides = 0
  while pos.y < y do
    if not step(UP) then
      local moved = false
      for d = 0, 3 do
        if step(d) then moved = true break end
      end
      slides = slides + 1
      if not moved or slides > 8 then error("Can't get up at " .. at(), 0) end
    end
  end
end

-- Fly to column f,s at least 'alt' high; goes higher when something is in the way.
local function flyTo(tf, ts, alt)
  rise(alt)
  local top = alt + 48
  while pos.f ~= tf or pos.s ~= ts do
    local d
    if pos.f ~= tf then d = pos.f < tf and 0 or 2 else d = pos.s < ts and 1 or 3 end
    if not step(d) then
      if pos.y >= top then error("Can't fly past " .. at(), 0) end
      rise(pos.y + 1)
    end
  end
end

local function flightAlt(y) return math.max(pos.y, y or pos.y) + HOP end

local function goHome()
  if pos.f == 0 and pos.s == 0 and pos.y == 0 then return end
  setStatus("Going home")
  if pos.f ~= 0 or pos.s ~= 0 then flyTo(0, 0, flightAlt(0)) end
  while pos.y > 0 do
    if not step(DOWN) then error("Something blocks the way down to my chest at " .. at(), 0) end
  end
  if pos.y < 0 then rise(0) end
end

---------------------------------------------------------------------------
-- Trees
---------------------------------------------------------------------------
local function cutLeaves(d)
  local info = inspect(d)
  if isLeaves(info) then
    dig(d, info)
    return true
  end
  return false
end

-- Leaves on the 4 sides; returns how many it cut
local function clearLeaves()
  local start, n = st.h, 0
  for i = 0, 3 do
    if cutLeaves((start + i) % 4) then n = n + 1 end
  end
  return n
end

-- Fly once around the trunk at this height (the 8 blocks around it), cutting all
-- leaves there and the leaves just outside, above and below them. That's most of
-- a crown, and every leaf block cut can drop a sapling.
local RING = { { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }
local function unitDir(df, ds)
  if df > 0 then return 0 elseif df < 0 then return 2 elseif ds > 0 then return 1 else return 3 end
end
local function leafRing()
  local cf, cs = pos.f, pos.s
  local path = {}
  for _, r in ipairs(RING) do
    local d = unitDir(cf + r[1] - pos.f, cs + r[2] - pos.s)
    if not step(d) then break end
    path[#path + 1] = d
    if r[1] ~= 0 then cutLeaves(r[1] > 0 and 0 or 2) end
    if r[2] ~= 0 then cutLeaves(r[2] > 0 and 1 or 3) end
    cutLeaves(UP)
    cutLeaves(DOWN)
  end
  -- back to the trunk: the short way after a full round, else the way it came
  if #path == #RING and step(1) and step(2) then return end
  while pos.f ~= cf or pos.s ~= cs do
    local d = table.remove(path)
    if not d then break end
    if not step(OPP[d]) then error("Can't get back to the trunk at " .. at(), 0) end
  end
end

-- Plant a sapling in the block below the turtle
local function plantBelow(want)
  local s = (want and findSlot(function(d) return d.name == want and isPlantable(d) end)) or findSlot(isPlantable)
  if not s then return false end
  turtle.select(s)
  local ok = turtle.placeDown()
  turtle.select(1)
  return ok
end

local function boneMealBelow()
  for _ = 1, BONEMEAL_TRIES do
    local s = findSlot(isBoneMeal)
    if not s then return end
    turtle.select(s)
    turtle.placeDown()
    turtle.select(1)
    if not isSapling(inspect(DOWN)) then return end
  end
end

local function countSpots()
  local n = 0
  for _ in pairs(st.spots) do n = n + 1 end
  return n
end

-- A sapling was planted here: come back when it has grown
local function remember(f, s, y)
  local k = f .. "," .. s
  local spot = st.spots[k]
  if not spot then
    if countSpots() >= MAX_SPOTS then return end
    spot = { f = f, s = s }
    st.spots[k] = spot
  end
  spot.y, spot.t, spot.fails = y, now(), nil
  save()
end

local function forget(f, s)
  st.spots[f .. "," .. s] = nil
  save()
end

-- The turtle is inside or right above a trunk. Cuts everything above (st.top: after a
-- reboot it climbs back through the part it already cut), then everything below,
-- then plants a sapling on the ground where the trunk stood.
local function fellColumn(logName)
  st.tree = { f = pos.f, s = pos.s, log = logName or (st.tree and st.tree.log) }
  save()
  setStatus("Felling a tree at " .. at())
  local start = pos.y
  local lastRing = -math.huge
  -- Leaves next to the trunk here? Then go around it, every other level.
  local function harvest()
    if clearLeaves() > 0 and LEAF_RINGS and math.abs(pos.y - lastRing) >= 2
      and saplingCount() < SAPLING_WANT and fuelToSpare() then
      lastRing = pos.y
      leafRing()
    end
  end
  while pos.y < start + MAX_HEIGHT do
    local info = inspect(UP)
    if not isLog(info) and not (info == nil and pos.y < (st.top or -math.huge)) then break end
    st.tree.log = st.tree.log or (info and info.name)
    st.top = math.max(st.top or pos.y + 1, pos.y + 1)
    save()
    if not step(UP, true) then break end
    harvest()
  end
  -- The top of the crown, right above the trunk
  if LEAF_RINGS and saplingCount() < SAPLING_WANT and fuelToSpare() and isLeaves(inspect(UP)) and step(UP) then
    clearLeaves()
    cutLeaves(UP)
    step(DOWN)
  end
  st.top = nil
  save()
  -- Back down through the trunk to the ground
  while true do
    local info = inspect(DOWN)
    if isLog(info) then
      st.tree.log = st.tree.log or info.name
      dig(DOWN, info)
      if not step(DOWN) then break end
      harvest()
    elseif info == nil and pos.y > start then
      if not step(DOWN) then break end
    else
      break
    end
  end
  -- This is where the bottom log was: plant from one block up
  local ground = inspect(DOWN)
  local baseY = pos.y
  if canPlantOn(ground) and step(UP) then
    if plantBelow(saplingFor(st.tree.log)) then
      remember(pos.f, pos.s, baseY)
    else
      forget(pos.f, pos.s)
      setStatus("No sapling to replant: put some in the turtle or the chest")
    end
  end
  st.felled = st.felled + 1
  st.tree = nil
  save()
end

-- Step into a trunk next to the turtle and fell it
local function fellBeside(d, info)
  -- remembered before the first cut, so a reboot right after it still finishes the tree
  st.tree = { f = pos.f + DF[d], s = pos.s + DS[d], log = info.name }
  save()
  dig(d, info)
  if not step(d) then
    st.tree = nil
    save()
    return false
  end
  fellColumn(info.name)
  return true
end

---------------------------------------------------------------------------
-- Visiting planted spots
---------------------------------------------------------------------------
local function dueSpots()
  local list, t = {}, now()
  for _, spot in pairs(st.spots) do
    if t - (spot.t or 0) >= REGROW_MIN * 60000 then
      list[#list + 1] = spot
    end
  end
  return list
end

local function nearest(list)
  local bi, bd = nil, math.huge
  for i, spot in ipairs(list) do
    local d = math.abs(spot.f - pos.f) + math.abs(spot.s - pos.s) + math.abs(spot.y - pos.y)
    if d < bd then bi, bd = i, d end
  end
  if not bi then return nil, 0 end
  return table.remove(list, bi), bd
end

local function failSpot(spot, why)
  spot.fails = (spot.fails or 0) + 1
  spot.t = now()
  if spot.fails >= 3 then
    st.spots[spot.f .. "," .. spot.s] = nil
    logError("Gave up on the tree spot at " .. spot.f .. "," .. spot.s .. ": " .. why)
  end
  save()
end

-- Fly to a spot, come down through the leaves; fell, bone meal or plant
local function visit(spot)
  setStatus("Checking the tree at " .. spot.f .. "," .. spot.s)
  flyTo(spot.f, spot.s, flightAlt(spot.y))
  while pos.y > spot.y + 1 do
    local info = inspect(DOWN)
    if isTreeLog(info) then
      fellColumn(info.name)
      return true
    end
    if not step(DOWN) then
      failSpot(spot, "something above it (" .. (info and info.name or "?") .. ")")
      return false
    end
  end
  local info = inspect(DOWN)
  if isTreeLog(info) then
    fellColumn(info.name)
    return true
  elseif isSapling(info) then
    boneMealBelow()
    info = inspect(DOWN)
    if isTreeLog(info) then fellColumn(info.name) return true end
    -- not grown yet: look again in half the usual time
    spot.t, spot.fails = now() - REGROW_MIN * 30000, nil
  elseif info == nil or classify(info) == "soft" then
    -- the sapling is gone (eaten, trampled, cut by someone)
    if info then dig(DOWN, info) end
    if plantBelow() then
      spot.t, spot.fails = now(), nil
    else
      failSpot(spot, "no sapling to plant")
    end
  else
    failSpot(spot, "the spot is taken by " .. info.name)
  end
  save()
  return false
end

---------------------------------------------------------------------------
-- Searching for trees
---------------------------------------------------------------------------
-- Square spiral around home, cells SPACING apart, cell 1 = home
local CELLS = { { 0, 0 } }
do
  local f, s, d, len = 0, 0, 0, 1
  local done = false
  while not done do
    for _ = 1, 2 do
      for _ = 1, len do
        f, s = f + DF[d] * SPACING, s + DS[d] * SPACING
        if math.abs(f) > R or math.abs(s) > R then done = true break end
        CELLS[#CELLS + 1] = { f, s }
      end
      if done then break end
      d = (d + 1) % 4
    end
    len = len + 1
  end
end

-- Down to the ground (through air, leaves and plants). Fells a trunk it lands on.
local function land()
  for _ = 1, 128 do
    local info = inspect(DOWN)
    local c = classify(info)
    if c == "log" and isTreeLog(info) then fellColumn(info.name) return end
    if c ~= "air" and c ~= "soft" then return end
    if not step(DOWN) then return end
  end
end

-- A trunk on side d? Fell it and come back. True if it felled one.
local function lookAt(d)
  local info = inspect(d)
  if not isTreeLog(info) then return false end
  if not fellBeside(d, info) then return false end
  -- back out of the tree column (it is right above the new sapling now)
  local tries = 0
  while not step(OPP[d]) do
    tries = tries + 1
    if tries > 6 or not step(UP) then break end
  end
  land()
  return true
end

-- One step over the ground: climb over hills and obstacles, then down to the ground
local function walk(d)
  for _ = 1, 24 do
    if step(d) then land() return true end
    if isTreeLog(inspect(d)) then return "tree" end
    if not step(UP) then return false end
  end
  return false
end

-- Search the next cells of the spiral. Returns the number of trees felled.
local function explore(budget)
  local felled = 0
  local from = CELLS[st.cursor - 1]
  setStatus("Searching for trees (" .. (st.cursor - 1) .. "/" .. #CELLS .. ")")
  if pos.f ~= from[1] or pos.s ~= from[2] then flyTo(from[1], from[2], flightAlt()) end
  land()
  for _ = 1, budget do
    if st.cursor > #CELLS or countSpots() >= MAX_SPOTS then break end
    if freeSlots() < 4 or not fuelFor(TREE_FUEL + 2 * SPACING) then break end
    local cell = CELLS[st.cursor]
    while pos.f ~= cell[1] or pos.s ~= cell[2] do
      local d
      if pos.f ~= cell[1] then d = pos.f < cell[1] and 0 or 2 else d = pos.s < cell[2] and 1 or 3 end
      if lookAt((d + 3) % 4) then felled = felled + 1 end
      if lookAt((d + 1) % 4) then felled = felled + 1 end
      local w = walk(d)
      if w == "tree" then
        if fellBeside(d, inspect(d)) then felled = felled + 1 end
        land()
      elseif not w then
        -- can't get over it on foot: fly to the cell
        flyTo(cell[1], cell[2], flightAlt())
        land()
      end
      if freeSlots() < 4 then break end
    end
    if pos.f == cell[1] and pos.s == cell[2] then
      st.cursor = st.cursor + 1
      save()
    end
  end
  return felled
end

---------------------------------------------------------------------------
-- Planting spare saplings
---------------------------------------------------------------------------
-- A grid 3 blocks apart around the chest (not right next to it), nearest first
local NURSERY = {}
for f = -NURSERY_RADIUS, NURSERY_RADIUS do
  for s = -NURSERY_RADIUS, NURSERY_RADIUS do
    if f % 3 == 0 and s % 3 == 0 and math.max(math.abs(f), math.abs(s)) >= 3 then
      NURSERY[#NURSERY + 1] = { f, s }
    end
  end
end
table.sort(NURSERY, function(a, b) return math.abs(a[1]) + math.abs(a[2]) < math.abs(b[1]) + math.abs(b[2]) end)

local function nearSpot(f, s)
  for _, spot in pairs(st.spots) do
    if math.abs(spot.f - f) <= 1 and math.abs(spot.s - s) <= 1 then return true end
  end
  return false
end

-- Plant the saplings it has to spare on free grid places. Each one becomes a spot.
-- Places where nothing can grow (stone, sand, water, a build) are remembered as bad.
local function plantSpares()
  st.bad = st.bad or {}
  local planted = 0
  for _, c in ipairs(NURSERY) do
    if countSpots() >= MAX_SPOTS or saplingCount() <= SAPLING_RESERVE or not fuelToSpare() then break end
    local k = c[1] .. "," .. c[2]
    if not st.spots[k] and not st.bad[k] and not nearSpot(c[1], c[2]) then
      local dist = math.abs(c[1] - pos.f) + math.abs(c[2] - pos.s) + 2 * HOP
      if not fuelFor(dist + TREE_FUEL) then break end
      setStatus("Planting a sapling at " .. k)
      flyTo(c[1], c[2], flightAlt())
      land() -- a tree standing there gets felled and replanted
      if not st.spots[k] then
        local y = pos.y
        if canPlantOn(inspect(DOWN)) and step(UP) and plantBelow() then
          remember(c[1], c[2], y)
          planted = planted + 1
        else
          st.bad[k] = true
          save()
        end
      end
    end
  end
  return planted
end

---------------------------------------------------------------------------
-- A trip: planted spots first, then search
---------------------------------------------------------------------------
-- Returns trees felled and why it stopped: "full", "fuel", "searched" or nil (nothing left)
local function trip()
  local felled = 0
  local list = dueSpots()
  while #list > 0 do
    if freeSlots() < 4 then return felled, "full" end
    local spot, dist = nearest(list)
    if not fuelFor(dist + 2 * HOP + TREE_FUEL) then return felled, "fuel" end
    if visit(spot) then felled = felled + 1 end
  end
  if saplingCount() > SAPLING_RESERVE and countSpots() < MAX_SPOTS and fuelToSpare() then plantSpares() end
  if st.cursor <= #CELLS and countSpots() < MAX_SPOTS and freeSlots() >= 4 then
    -- only worth the flight if there is fuel left for a good part of the search
    local from = CELLS[st.cursor - 1]
    local dist = math.abs(from[1] - pos.f) + math.abs(from[2] - pos.s) + 2 * HOP
    if not fuelFor(dist + TREE_FUEL + 10 * SPACING) then return felled, "fuel" end
    felled = felled + explore(EXPLORE_CELLS)
    return felled, "searched"
  end
  return felled, nil
end

---------------------------------------------------------------------------
-- Home: chest, fuel, saplings
---------------------------------------------------------------------------
-- Face the chest; turns around to find it if the saved heading is off
local function findChest()
  face(2)
  for _ = 1, 4 do
    local ok, info = turtle.inspect()
    if ok and isChest(info) then
      st.h = 2
      save()
      return true
    end
    turtle.turnRight()
  end
  return false
end

-- Low on fuel or out of saplings: take stacks out of the chest one by one, burn
-- what burns. Everything else goes back with the next deposit.
local function restock()
  local tries = 0
  while (fuel() < TARGET_FUEL or not haveSapling()) and tries < 27 do
    tries = tries + 1
    local s
    for e = 1, 16 do if turtle.getItemCount(e) == 0 then s = e break end end
    if not s then break end
    local before = countLogs()
    turtle.select(s)
    if not turtle.suck() then break end
    local d = turtle.getItemDetail(s)
    if d and not isSaplingItem(d) then
      while fuel() < TARGET_FUEL and turtle.getItemCount(s) > 0 do
        if not turtle.refuel(1) then break end
      end
    end
    -- logs from the chest were counted when they went in; what's left goes back with the deposit
    st.logs = st.logs - (countLogs() - before)
  end
  turtle.select(1)
end

-- Everything into the chest except saplings (up to KEEP_SAPLINGS each) and bone meal
local function deposit()
  local kept = {}
  local ok = true
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d then
      local keep = 0
      if isBoneMeal(d) then keep = d.count
      elseif isPlantable(d) then
        keep = math.min(d.count, math.max(0, KEEP_SAPLINGS - (kept[d.name] or 0)))
        kept[d.name] = (kept[d.name] or 0) + keep
      end
      if d.count > keep then
        turtle.select(s)
        if turtle.drop(d.count - keep) then
          if isLogItem(d) then st.logs = st.logs + d.count - turtle.getItemCount(s) - keep end
        else
          ok = false
        end
      end
    end
  end
  turtle.select(1)
  return ok
end

local function service()
  setStatus("Unloading")
  while not findChest() do
    setStatus("ERROR: no chest behind me. Put me on my home spot, Ctrl+T, type: lumber home")
    sleep(30)
  end
  -- Sticks are burned, they're not worth a chest slot
  local function stick(d) return d.name == "minecraft:stick" end
  local sticks = findSlot(stick)
  while sticks and fuel() ~= math.huge and fuel() < turtle.getFuelLimit() - 5 do
    turtle.select(sticks)
    if not turtle.refuel() then break end
    sticks = findSlot(stick)
  end
  burn(TARGET_FUEL)
  restock()
  face(2)
  while not deposit() do
    setStatus("Chest full! Empty it and I'll carry on")
    sleep(30)
  end
  save()
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
-- After a reboot or an error: finish the tree it was in, then go home
local function recover()
  local t = st.tree
  if t and math.abs(t.f - pos.f) <= 1 and math.abs(t.s - pos.s) <= 1 then
    -- stopped right next to the tree it was cutting (or going around its crown): step in
    if pos.f ~= t.f then step(pos.f < t.f and 0 or 2, pos.s == t.s) end
    if pos.f == t.f and pos.s ~= t.s then step(pos.s < t.s and 1 or 3, true) end
  end
  if t and t.f == pos.f and t.s == pos.s then
    fellColumn()
  end
  st.tree, st.top = nil, nil
  goHome()
end

local function main()
  print("Lumberjack: searching up to " .. R .. " blocks around the chest")
  while true do
    local ok, err = pcall(recover)
    if ok then break end
    if err == "Terminated" then error(err, 0) end
    logError(err)
    setStatus("STUCK: " .. tostring(err))
    sleep(30)
  end
  while true do
    service()
    local minFuel = 2 * HOP + TREE_FUEL + 4 * SPACING + FUEL_MARGIN + 20
    if fuel() < minFuel then
      setStatus("Not enough fuel (" .. fuel() .. "/" .. minFuel .. "): put logs or coal in the chest")
      sleep(30)
    else
      local ok, n, why = pcall(trip)
      if not ok then
        if n == "Terminated" then error(n, 0) end
        logError(n)
        setStatus("Error: " .. tostring(n))
        why = nil
      end
      local ok2, err2 = pcall(recover)
      while not ok2 do
        if err2 == "Terminated" then error(err2, 0) end
        logError(err2)
        setStatus("STUCK: " .. tostring(err2))
        sleep(30)
        ok2, err2 = pcall(recover)
      end
      if why == "fuel" then
        setStatus("Low on fuel (" .. turtle.getFuelLevel() .. "): waiting. Logs or coal in the chest help")
        sleep(WAIT)
      elseif not why then
        setStatus("Waiting. Felled " .. st.felled .. " trees, " .. st.logs .. " logs, "
          .. countSpots() .. " trees planted, fuel " .. turtle.getFuelLevel())
        sleep(WAIT)
      end
    end
  end
end

turtle.select(1)
main()
