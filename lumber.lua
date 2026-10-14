-- lumber.lua - tree farm turtle (CC: Tweaked)
--
-- Needs a felling turtle (a turtle with an axe), a chest directly BEHIND it and a
-- straight lane IN FRONT of it, with the trees on one or both sides of the lane:
--
--   top view, T = turtle (facing up), C = chest, S = sapling spot, . = lane
--
--        S . S     <- 3rd pair
--          .
--          .
--        S . S     <- 2nd pair
--          .
--          .
--        S . S     <- 1st pair: 1 block in front of the turtle, left and right
--          T
--          C
--
-- The sapling spots need dirt or grass under them. The lane is at the same height
-- as the saplings and must be free (air); leaves, logs and plants in it are cut away.
--
-- One-time setup:
--   lumber setup [trees] [spacing] [sides]
--     trees    = trees per side (default 4)
--     spacing  = blocks from one tree to the next along the lane (default 3)
--     sides    = left, right or both (default both)
-- Then:
--   lumber          run (started automatically on boot after setup)
--   lumber home     after putting it back on its home spot by hand: reset position
--
-- Each round it walks the lane, fells every grown tree (the whole trunk, plus logs
-- and leaves right next to it), replants a sapling, picks up drops in the lane,
-- comes home, refuels from wood and puts the logs in the chest. Then it waits a bit.
-- Bone meal in the turtle is used on saplings. Works for 1x1 trees (oak, birch,
-- spruce, jungle, acacia, cherry), not for 2x2 trees (dark oak, big spruce/jungle).

local CFG_FILE, STATE_FILE, LOG_FILE = "lumber.cfg", "lumber.state", "lumber.log"

local WAIT = 120           -- seconds between rounds (a sapling takes ~15 min to grow)
local MAX_HEIGHT = 32      -- never climb higher than this
local KEEP_SAPLINGS = 32   -- saplings of each kind it keeps; the rest goes in the chest
local BONEMEAL_TRIES = 3   -- bone meal per sapling per round (if it has any)
local DIG_LEAVES = true    -- also cut the leaves next to the trunk (more saplings)
local FUEL_MARGIN = 50
local RETRY = 20

-- Directions relative to the home spot:
-- 0 = forward (along the lane), 1 = right, 2 = back (chest), 3 = left, 4 = up, 5 = down
local UP, DOWN = 4, 5
local DF = { [0] = 1, 0, -1, 0, 0, 0 }
local DS = { [0] = 0, 1, 0, -1, 0, 0 }
local DY = { [0] = 0, 0, 0, 0, 1, -1 }
local OPP = { [0] = 2, 3, 0, 1, 5, 4 }
local DIRNAME = { [0] = "forward", "right", "back", "left", "up", "down" }
local SIDES = { left = { 3 }, right = { 1 }, both = { 3, 1 } }

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
-- Setup
---------------------------------------------------------------------------
if args[1] == "setup" then
  local trees = tonumber(args[2] or 4)
  local spacing = tonumber(args[3] or 3)
  local sides = (args[4] or "both"):lower()
  if not (trees and trees >= 1 and spacing and spacing >= 1 and SIDES[sides]) then
    print("Usage: lumber setup [trees] [spacing] [sides]")
    print("  trees   = trees per side (default 4)")
    print("  spacing = blocks between tree spots along the lane (default 3)")
    print("  sides   = left, right or both (default both)")
    return
  end
  if turtle then
    turtle.turnLeft() turtle.turnLeft()
    local ok, info = turtle.inspect()
    turtle.turnLeft() turtle.turnLeft()
    if not (ok and isChest(info)) then print("WARNING: no chest found behind the turtle!") end
  end
  saveTable(CFG_FILE, { trees = math.floor(trees), spacing = math.floor(spacing), sides = sides })
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("lumber")\n')
  h.close()
  os.setComputerLabel(os.getComputerLabel() or "Lumberjack")
  local lane = 1 + (math.floor(trees) - 1) * math.floor(spacing)
  print("Saved: " .. math.floor(trees) .. " trees on " .. sides .. " side(s), every "
    .. math.floor(spacing) .. " blocks. Lane is " .. lane .. " blocks long.")
  print("Start with: lumber   (or reboot the turtle)")
  return
end

if not turtle then error("lumber.lua only runs on a turtle", 0) end
local cfg = loadTable(CFG_FILE)
if not cfg then
  print("Not set up yet. First: lumber setup [trees] [spacing] [sides]")
  return
end
local TREE_SIDES = SIDES[cfg.sides] or SIDES.both
local LANE = 1 + (cfg.trees - 1) * cfg.spacing
local TREES = cfg.trees * #TREE_SIDES
local TREE_FUEL = 2 * MAX_HEIGHT + 4                   -- worst case for one tree
local START_FUEL = 2 * LANE + TREE_FUEL + FUEL_MARGIN  -- needed to set out at all
local TARGET_FUEL = START_FUEL + TREES * 20            -- topped up to this at home

if args[1] == "home" then
  local s0 = loadTable(STATE_FILE) or {}
  s0.pos = { f = 0, s = 0, y = 0 }
  s0.h = 0
  s0.pending = nil
  saveTable(STATE_FILE, s0)
  print("Position reset to the home spot (chest behind the turtle).")
  print("Start with: lumber")
  return
end

---------------------------------------------------------------------------
-- State (survives reboot / chunk unload)
---------------------------------------------------------------------------
local st = loadTable(STATE_FILE) or {}
st.pos = st.pos or { f = 0, s = 0, y = 0 }
st.h = st.h or 0
st.felled = st.felled or 0 -- trees felled, all time
st.logs = st.logs or 0     -- logs cut, all time
local pos = st.pos

local function save() saveTable(STATE_FILE, st) end

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
    lines[#lines + 1] = os.date("%Y-%m-%d %H:%M") .. " " .. pos.f .. "," .. pos.s .. "," .. pos.y .. " " .. msg
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
  if not info then return false end
  return hasTag(info, "minecraft:logs") or info.name:find("_log$") ~= nil
end
local function isLeaves(info)
  if not info then return false end
  return hasTag(info, "minecraft:leaves") or info.name:find("leaves") ~= nil
end
local function isSapling(info)
  if not info then return false end
  return hasTag(info, "minecraft:saplings") or info.name:find("sapling") ~= nil or info.name:find("propagule") ~= nil
end
-- What it may cut away to get through: wood, leaves and small plants. Never anything else.
local PLANTS = { "vine", "grass", "fern", "flower", "bush", "snow", "lichen", "moss_carpet" }
local function isClearable(info)
  if isLog(info) or isLeaves(info) then return true end
  if hasTag(info, "minecraft:replaceable") or hasTag(info, "minecraft:flowers") then return true end
  if info.name:find("grass_block") then return false end
  for _, p in ipairs(PLANTS) do
    if info.name:find(p, 1, true) then return true end
  end
  return false
end

local function isSaplingItem(d) return d.name:find("sapling") ~= nil or d.name:find("propagule") ~= nil end
local function isLogItem(d) return d.name:find("_log$") ~= nil end
local function isBoneMeal(d) return d.name == "minecraft:bone_meal" end

local function saplingFor(logName)
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
        end
      end
      if fuel() >= target then turtle.select(1) return true end
    end
  end
  turtle.select(1)
  return fuel() >= target
end

local function distHome() return math.abs(pos.f) + math.abs(pos.s) + math.abs(pos.y) end

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

-- info = what inspect() saw there, to count the logs cut
local function dig(d, info)
  local ok, why
  if d == UP then ok, why = turtle.digUp()
  elseif d == DOWN then ok, why = turtle.digDown()
  else face(d) ok, why = turtle.dig() end
  if ok and isLog(info) then st.logs = st.logs + 1 end
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

-- Move one block. Cuts wood, leaves and plants in the way; waits for anything else.
local function move(d)
  for attempt = 1, RETRY do
    local info = inspect(d)
    if info then
      if isClearable(info) then
        local ok, why = dig(d, info)
        if not ok and type(why) == "string" and why:lower():find("tool") then
          error("No axe: " .. why, 0)
        end
      else
        setStatus("Blocked " .. DIRNAME[d] .. " by " .. info.name)
        sleep(5)
      end
    end
    if fuel() == 0 and not burn(distHome() + FUEL_MARGIN) then error("Out of fuel", 0) end
    if rawMove(d) then return true end
    -- A mob or player in the way: wait first, hit it only if it doesn't go away
    if attempt > 5 and inspect(d) == nil then
      if d == UP then turtle.attackUp() elseif d == DOWN then turtle.attackDown() else turtle.attack() end
    end
    sleep(0.5)
  end
  error("Stuck: can't move " .. DIRNAME[d], 0)
end

local function goHome()
  while pos.y > 0 do move(DOWN) end
  while pos.s > 0 do move(3) end
  while pos.s < 0 do move(1) end
  while pos.f > 0 do
    face(2)
    turtle.suck()
    move(2)
  end
  while pos.f < 0 do move(0) end
end

---------------------------------------------------------------------------
-- Trees
---------------------------------------------------------------------------
-- Logs (branches) and leaves on the 4 sides of the trunk, 3 turns per level
local function clearAround()
  local start = st.h
  for i = 0, 3 do
    local d = (start + i) % 4
    local info = inspect(d)
    if isLog(info) or (DIG_LEAVES and isLeaves(info)) then dig(d, info) end
  end
end

-- Standing in the trunk at ground level: cut the trunk up to the top, come back down
-- st.top remembers how high it got, so after a reboot it climbs back through the part
-- it already cut instead of leaving the rest of the trunk floating.
local function chopUp()
  while pos.y < MAX_HEIGHT do
    local info = inspect(UP)
    if not isLog(info) and not (info == nil and pos.y < (st.top or 0)) then break end
    st.top = math.max(st.top or 0, pos.y + 1)
    save()
    move(UP)
    clearAround()
  end
  st.top = nil
  save()
  while pos.y > 0 do move(DOWN) end
end

-- Standing in the lane facing the tree spot: plant a sapling there
local function plant(side, want)
  face(side)
  turtle.suck() -- drops lying on the spot
  local s = (want and findSlot(function(d) return d.name == want end)) or findSlot(isSaplingItem)
  if not s then
    setStatus("No saplings left: put some in the turtle or the chest")
    return false
  end
  turtle.select(s)
  local ok = turtle.place()
  turtle.select(1)
  if not ok then setStatus("Can't plant at " .. pos.f .. " " .. DIRNAME[side] .. " (no dirt under it?)") end
  return ok
end

local function boneMeal(side)
  for _ = 1, BONEMEAL_TRIES do
    local s = findSlot(isBoneMeal)
    if not s then return end
    face(side)
    turtle.select(s)
    turtle.place()
    turtle.select(1)
    if not isSapling(inspect(side)) then return end
  end
end

local function fell(side, logName)
  setStatus("Felling tree at " .. pos.f .. " " .. DIRNAME[side])
  move(side)
  chopUp()
  move(OPP[side])
  plant(side, saplingFor(logName))
  st.felled = st.felled + 1
  save()
end

local function visit(side)
  local info = inspect(side)
  if isSapling(info) then
    boneMeal(side)
    info = inspect(side)
  end
  if isLog(info) then
    fell(side, info.name)
    return true
  elseif info == nil then
    plant(side)
  end
  -- anything else on the spot (a block, leaves): leave it alone
  return false
end

-- Walk the lane once. Returns the number of trees felled and why it came back early
-- ("full" or "fuel"), or nil when the whole lane is done.
local function pass()
  local n = 0
  for i = 0, cfg.trees - 1 do
    local f = 1 + i * cfg.spacing
    while pos.f < f do
      face(0)
      turtle.suck() -- saplings, sticks and apples in the lane
      move(0)
    end
    for _, side in ipairs(TREE_SIDES) do
      if freeSlots() < 4 then return n, "full" end
      if fuel() < distHome() + TREE_FUEL + FUEL_MARGIN
        and not burn(distHome() + TREE_FUEL + FUEL_MARGIN) then return n, "fuel" end
      if visit(side) then n = n + 1 end
    end
  end
  return n, nil
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
  while (fuel() < TARGET_FUEL or not findSlot(isSaplingItem)) and tries < 27 do
    tries = tries + 1
    local s
    for e = 1, 16 do if turtle.getItemCount(e) == 0 then s = e break end end
    if not s then break end
    turtle.select(s)
    if not turtle.suck() then break end
    local d = turtle.getItemDetail(s)
    if d and not isSaplingItem(d) then
      while fuel() < TARGET_FUEL and turtle.getItemCount(s) > 0 do
        if not turtle.refuel(1) then break end
      end
    end
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
      elseif isSaplingItem(d) then
        keep = math.min(d.count, math.max(0, KEEP_SAPLINGS - (kept[d.name] or 0)))
        kept[d.name] = (kept[d.name] or 0) + keep
      end
      if d.count > keep then
        turtle.select(s)
        if not turtle.drop(d.count - keep) then ok = false end
      end
    end
  end
  turtle.select(1)
  save()
  return ok
end

local function service()
  setStatus("Unloading")
  while not findChest() do
    setStatus("ERROR: no chest behind me. Put me on my home spot, Ctrl+T, type: lumber home")
    sleep(30)
  end
  -- Sticks are burned, they're not worth a chest slot
  local sticks = findSlot(function(d) return d.name == "minecraft:stick" end)
  while sticks and fuel() ~= math.huge and fuel() < turtle.getFuelLimit() - 5 do
    turtle.select(sticks)
    if not turtle.refuel() then break end
    sticks = findSlot(function(d) return d.name == "minecraft:stick" end)
  end
  burn(TARGET_FUEL)
  restock()
  face(2)
  while not deposit() do
    setStatus("Chest full! Empty it and I'll carry on")
    sleep(30)
  end
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
-- After a reboot away from home: finish the tree it was in, then go home
local function recover()
  if pos.s ~= 0 then
    setStatus("Finishing the tree I was in")
    while pos.y > 0 do move(DOWN) end
    local side = pos.s > 0 and 1 or 3
    chopUp()
    move(OPP[side])
    plant(side)
  end
  if pos.f ~= 0 or pos.y ~= 0 then
    setStatus("Going home")
    goHome()
  end
end

local function main()
  print("Lumberjack: " .. cfg.trees .. " trees " .. cfg.sides .. ", every " .. cfg.spacing .. " blocks")
  while true do
    local ok, err = pcall(recover)
    if ok then break end
    if err == "Terminated" then error(err, 0) end
    logError(err)
    setStatus("STUCK: " .. tostring(err))
    sleep(30)
  end
  local hurry = true -- no wait before the first round, or when it came back full
  while true do
    service()
    if fuel() < START_FUEL then
      setStatus("Not enough fuel (" .. fuel() .. "/" .. START_FUEL .. "): put logs or coal in the chest")
      sleep(30)
    else
      if not hurry then
        setStatus("Waiting " .. WAIT .. "s. Felled " .. st.felled .. " trees, " .. st.logs .. " logs cut so far, fuel " .. turtle.getFuelLevel())
        sleep(WAIT)
      end
      setStatus("Walking the lane")
      local ok, n, why = pcall(pass)
      if not ok then
        if n == "Terminated" then error(n, 0) end
        logError(n)
        setStatus("Error: " .. tostring(n))
        hurry = false
      else
        hurry = (why == "full")
        if n > 0 then print("Felled " .. n .. (why == "full" and ", inventory full" or "")) end
      end
      local ok2, err2 = pcall(recover) -- also finishes a tree it left half done
      while not ok2 do
        if err2 == "Terminated" then error(err2, 0) end
        logError(err2)
        setStatus("STUCK: " .. tostring(err2))
        sleep(30)
        ok2, err2 = pcall(recover)
      end
    end
  end
end

turtle.select(1)
main()
