if fs and fs.exists("wh2-program.lua") and not rawget(_ENV,"__wh2Running") then
  if dofile("wh2-program.lua").run("builder.lua",...) then return end
end
-- builder.lua - building / terraforming turtle (CC: Tweaked)
--
-- Clears and flattens land, lays floors and platforms, builds walls and lights up an
-- area with torches so nothing spawns there. Blocks come from a supply chest behind its
-- home spot; when it runs short it orders more from the Storage Room (roomsorter.lua)
-- over the radio, and it gives the blocks it digs out to a dump chest.
--
-- Needs: a turtle with a pickaxe (digs everything), fuel (coal, charcoal, lava buckets).
-- Wireless or ender modem for ordering from storage and for the pocket panel (optional).
--
-- One-time setup (turtle on its home spot, supply chest next to it):
--   builder setup                     finds the chest and turns its back to it. With GPS
--                                     it learns its real position by itself.
--   builder setup <x> <y> <z> <facing>  same, but you give its F3 position and the way it
--                                     faces (north/east/south/west); chest must be behind it
-- Without GPS or coordinates it counts from its home spot: home = 0 0 0, x = to its
-- right, y = up, z = negative in front of it.
--
-- Jobs (type them after "builder", press J on its screen, or use the pocket panel).
-- Coordinates are where you STAND (F3, your feet) at two opposite corners:
--   floor   x1 y1 z1 x2 y2 z2 [block]           floor under your feet (level y1 - 1),
--                                                default cobblestone; also sky platforms
--   walls   x1 y1 z1 x2 y2 z2 [height] [block]  walls around the rectangle, starting at
--                                                your feet, default 3 high, cobblestone
--   flatten x1 y1 z1 x2 y2 z2 [filler]          land flat: everything from your feet up
--                                                goes, dips below get filled (with what it
--                                                dug, or the filler block you name)
--   clear   x1 y1 z1 x2 y2 z2                    dig out the whole box (both corners in)
--   light   x1 y1 z1 x2 y2 z2 [spacing]         torches on the ground every 'spacing'
--                                                blocks (default 10): no mobs spawn there
-- e.g.  builder floor 100 64 -20 115 64 -5 stone_bricks
-- More jobs wait in a queue. Other commands:
--   builder            run (starts by itself on boot after setup)
--   builder home       after putting it back on its home spot by hand: reset position
--   builder stop       forget the current job and the queue
--   builder update     fetch the latest version from GitHub
-- Keys on its screen: J new job, P pause / go on, H come home, S stop job, Q quit.
--
-- Chests at home:
--   behind it          SUPPLY: blocks, torches and fuel. Best: make this the Storage
--                      Room's pickup chest (its outside), so orders land right there.
--   left/right/under   DUMP (optional): what it digs out goes here, e.g. a chest that
--                      feeds the Storage Room's input. Without one it goes in the supply.
-- From the supply chest it only takes what the job needs; other things stay there.

local CFG_FILE, STATE_FILE, LOG_FILE = "builder.cfg", "builder.state", "builder.log"
local PROTOCOL, STORE_PROTOCOL = "builder", "roomsorter"

local REACH = 128          -- job corners at most this far from home
local MAX_CELLS = 16384    -- biggest job (cells of floor/flatten, blocks of clear)
local CAP = 32             -- flatten clears at most this high above the ground
local FILL_DEPTH = 4       -- flatten fills dips this deep; deeper holes get a lid
local SPACING = 10         -- default torch spacing (light 14 still leaves >0 in the gaps)
local KEEP_FREE = 2        -- slots kept free for what it digs
local FUEL_MARGIN = 100
local REFUEL_BELOW = 3000  -- at home, top up from the supply chest when below this...
local REFUEL_TO = 5000     -- ...to about this
local MIN_FUEL = 500       -- below this it won't start out
local ORDER_WAIT = 300     -- seconds it waits for an order from storage
local REORDER = 300        -- don't order the same thing again within this many seconds
local WAIT = 30            -- seconds between checks while it waits for something
local RETRY = 20
local SERVICE_FREE, FULLNESS_HIGH, KEEP_ITEMS = 1, math.huge, {}
if wh2 then
  wh2.bind(function(values)
    REFUEL_BELOW, REFUEL_TO, FUEL_MARGIN = values.fuelLow, values.fuelTarget, values.fuelMargin
    MIN_FUEL, KEEP_FREE, SERVICE_FREE = values.minTripFuel, values.minFreeSlots, values.minFreeSlots
    FULLNESS_HIGH, KEEP_ITEMS = values.fullnessHigh, values.keep
  end)
end

-- Directions: 0=north(-z) 1=east(+x) 2=south(+z) 3=west(-x) 4=up 5=down (same as miner.lua)
local UP, DOWN = 4, 5
local DIRS = { north = 0, east = 1, south = 2, west = 3, n = 0, e = 1, s = 2, w = 3 }
local DIRNAME = { [0] = "north", "east", "south", "west", "up", "down" }
local DX = { [0] = 0, 1, 0, -1, 0, 0 }
local DY = { [0] = 0, 0, 0, 0, 1, -1 }
local DZ = { [0] = -1, 0, 1, 0, 0, 0 }
local OPP = { [0] = 2, 3, 0, 1, 5, 4 }

local args = { ... }
if args[1] == "update" then
  -- latest version from GitHub (update.lua does the work, fetched here if missing)
  if not fs.exists("update.lua") then
    shell.run("wget", "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/alpha/update.lua", "update.lua")
  end
  shell.run("update")
  return
end

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

local function isChest(info)
  if not info then return false end
  local n = info.name
  if n:find("chest") or n:find("barrel") or n:find("shulker_box") then return true end
  local t = info.tags or {}
  return t["c:chests"] or t["forge:chests"] or t["c:barrels"] or false
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
if args[1] == "setup" then
  if not turtle then error("builder.lua only runs on a turtle", 0) end
  local hx, hy, hz = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
  local facing = DIRS[(args[5] or ""):lower()]
  if args[2] and not (hx and hy and hz and facing) then
    print("Usage: builder setup [<x> <y> <z> <facing>]")
    print("  e.g. builder setup 120 64 -350 south")
    return
  end
  local function chestBehind()
    turtle.turnLeft() turtle.turnLeft()
    local ok, info = turtle.inspect()
    turtle.turnLeft() turtle.turnLeft()
    return ok and isChest(info)
  end
  if not facing then
    -- turn until the chest is behind it (it may be on any side)
    local found = false
    for _ = 1, 4 do
      if chestBehind() then found = true break end
      turtle.turnRight()
    end
    if not found then print("WARNING: no supply chest found next to the turtle!") end
  elseif not chestBehind() then
    print("WARNING: no supply chest behind the turtle!")
  end
  local world = hx ~= nil
  if not world and gps then
    -- GPS: where am I, and which way do I face (one step forward and back)
    local gx, gy, gz = gps.locate(2)
    if gx then
      hx, hy, hz = math.floor(gx + 0.5), math.floor(gy + 0.5), math.floor(gz + 0.5)
      local up = false
      if not turtle.forward() then up = turtle.up() and turtle.forward() end
      local fx, _, fz = gps.locate(2)
      turtle.back()
      if up then turtle.down() end
      if fx then
        local dx, dz = math.floor(fx + 0.5) - hx, math.floor(fz + 0.5) - hz
        for d = 0, 3 do if DX[d] == dx and DZ[d] == dz then facing = d end end
      end
      if facing then world = true else hx, hy, hz = nil, nil, nil end
    end
  end
  if not world then
    hx, hy, hz, facing = 0, 0, 0, 0
    print("No GPS: coordinates count from here (home = 0 0 0, x = right, z = minus in front).")
  end
  -- An optional dump chest left, right or under it
  local dump
  for _, d in ipairs({ (facing + 3) % 4, (facing + 1) % 4 }) do
    local turn = (d == (facing + 3) % 4) and turtle.turnLeft or turtle.turnRight
    local back = (d == (facing + 3) % 4) and turtle.turnRight or turtle.turnLeft
    turn()
    local ok, info = turtle.inspect()
    back()
    if not dump and ok and isChest(info) then dump = d end
  end
  if not dump then
    local ok, info = turtle.inspectDown()
    if ok and isChest(info) then dump = DOWN end
  end
  saveTable(CFG_FILE, { home = { x = hx, y = hy, z = hz }, facing = facing, world = world, dump = dump })
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("builder")\n')
  h.close()
  os.setComputerLabel(os.getComputerLabel() or "Builder")
  print("Saved. Home " .. hx .. "," .. hy .. "," .. hz .. " facing " .. DIRNAME[facing]
    .. (world and "" or " (counted from here)"))
  print(dump and ("Dump chest: " .. (dump == DOWN and "under it" or DIRNAME[dump]))
    or "No dump chest: dug blocks go in the supply chest.")
  print("Start with: builder   (or reboot the turtle)")
  return
end

if not turtle then error("builder.lua only runs on a turtle", 0) end
local cfg = loadTable(CFG_FILE)
if not cfg then
  print("Not set up yet. First: builder setup")
  return
end
local HOME, FACING = cfg.home, cfg.facing
local SUPPLY = OPP[FACING]
-- Columns it never builds in or digs: its home spot and the chests next to it
local KEEP_OUT = { [HOME.x .. "," .. HOME.z] = true }
for _, d in ipairs({ SUPPLY, cfg.dump }) do
  if d and d < 4 then KEEP_OUT[(HOME.x + DX[d]) .. "," .. (HOME.z + DZ[d])] = true end
end

---------------------------------------------------------------------------
-- State (survives reboot / chunk unload)
---------------------------------------------------------------------------
local st = loadTable(STATE_FILE) or {}
st.pos = st.pos or { x = HOME.x, y = HOME.y, z = HOME.z }
st.h = st.h or FACING
st.queue = st.queue or {}
st.stats = st.stats or { jobs = 0, placed = 0, dug = 0 }
st.ordered = st.ordered or {}
local pos = st.pos

local function save() saveTable(STATE_FILE, st) end

if args[1] == "home" then
  st.pos = { x = HOME.x, y = HOME.y, z = HOME.z }
  st.h, st.pending = FACING, nil
  save()
  print("Position reset to home " .. HOME.x .. "," .. HOME.y .. "," .. HOME.z .. ". Start with: builder")
  return
elseif args[1] == "stop" then
  st.job, st.queue = nil, {}
  save()
  print("Job and queue forgotten. Start with: builder")
  return
end

-- A reboot during a move: the fuel tells whether the move happened
if st.pending then
  local f = turtle.getFuelLevel()
  if f ~= "unlimited" and f < st.pending.fuel then
    local d = st.pending.d
    pos.x, pos.y, pos.z = pos.x + DX[d], pos.y + DY[d], pos.z + DZ[d]
  end
  st.pending = nil
  save()
end

local ui = { status = "Starting", lastError = nil, draw = function() end }
local function setStatus(s)
  if s == ui.status then return end
  ui.status = s
  ui.draw()
end

local function at() return pos.x .. "," .. pos.y .. "," .. pos.z end
local function atHome() return pos.x == HOME.x and pos.y == HOME.y and pos.z == HOME.z end

-- Remember an error in builder.log (last 40 lines). note = just log it, not an error
local function logError(msg, note)
  msg = tostring(msg)
  pcall(function()
    local lines = {}
    if fs.exists(LOG_FILE) then
      local h = fs.open(LOG_FILE, "r")
      for line in h.readAll():gmatch("[^\n]+") do lines[#lines + 1] = line end
      h.close()
    end
    if not note then ui.lastError = os.date("%H:%M") .. " " .. msg end
    lines[#lines + 1] = os.date("%Y-%m-%d %H:%M") .. " " .. at() .. " " .. msg
    while #lines > 40 do table.remove(lines, 1) end
    local h = fs.open(LOG_FILE, "w")
    h.write(table.concat(lines, "\n") .. "\n")
    h.close()
  end)
end

local function pretty(name)
  local s = (tostring(name):match(":(.+)$") or tostring(name)):gsub("_", " ")
  return s:sub(1, 1):upper() .. s:sub(2)
end

---------------------------------------------------------------------------
-- Blocks and items
---------------------------------------------------------------------------
local PLANTS = { "short_grass", "tall_grass", "fern", "flower", "dead_bush", "vine", "snow", "lichen",
  "moss_carpet", "sweet_berry", "dandelion", "poppy", "tulip", "orchid", "allium", "bluet", "daisy",
  "cornflower", "lily_of_the_valley", "rose_bush", "lilac", "peony", "sunflower", "seagrass", "kelp",
  "sugar_cane", "mushroom", "leaves" }
-- Things it may cut through even while travelling (plants, leaves, snow layers)
local function isSoft(info)
  if not info then return true end
  local n = info.name
  if n:find("pot") or n:find("block$") then return false end -- flower pots, snow/mushroom blocks
  if n == "minecraft:grass" then return true end -- short grass before 1.20.3
  if info.tags and info.tags["minecraft:replaceable"] then return true end
  for _, p in ipairs(PLANTS) do if n:find(p, 1, true) then return true end end
  return false
end
local function isLiquid(info)
  return info ~= nil and (info.name:find("water") ~= nil or info.name:find("lava") ~= nil
    or info.name == "minecraft:bubble_column")
end
-- Solid ground: something you can stand on (not air, liquid or a plant)
local function isSolid(info) return info ~= nil and not isLiquid(info) and not isSoft(info) end
local function isMachine(info) return info and (info.name:find("turtle") or info.name:find("computer")) end

-- Blocks flatten may fill dips with (no sand or gravel: those fall)
local FILLER = {
  ["minecraft:dirt"] = 1, ["minecraft:coarse_dirt"] = 1, ["minecraft:rooted_dirt"] = 1,
  ["minecraft:cobblestone"] = 2, ["minecraft:cobbled_deepslate"] = 2, ["minecraft:stone"] = 2,
  ["minecraft:deepslate"] = 2, ["minecraft:andesite"] = 2, ["minecraft:diorite"] = 2,
  ["minecraft:granite"] = 2, ["minecraft:tuff"] = 2, ["minecraft:netherrack"] = 2,
  ["minecraft:blackstone"] = 2, ["minecraft:mud"] = 1, ["minecraft:clay"] = 1,
}

local FUEL_VALUE = {
  ["minecraft:lava_bucket"] = 1000, ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80,
  ["minecraft:coal_block"] = 800,
}
local function isFuel(name) return FUEL_VALUE[name] ~= nil end

local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end

local function inventoryNeedsService()
  local free = freeSlots()
  return free < SERVICE_FREE or (16 - free) / 16 >= FULLNESS_HIGH
end

local function count(want)
  local n = 0
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and want(d.name) then n = n + d.count end
  end
  return n
end

local function selectItem(want, prefer)
  local best, bestScore
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and want(d.name) then
      local score = prefer and prefer(d.name) or 0
      if not best or score > bestScore then best, bestScore = s, score end
    end
  end
  if best then turtle.select(best) end
  return best
end

---------------------------------------------------------------------------
-- Fuel
---------------------------------------------------------------------------
local function fuel()
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return math.huge end
  return f
end

-- Burn fuel items it carries up to 'target', never over the turtle's limit
local function burn(target)
  local limit = turtle.getFuelLimit()
  for s = 1, 16 do
    if fuel() >= target then break end
    local d = turtle.getItemDetail(s)
    if d and isFuel(d.name) then
      turtle.select(s)
      while fuel() < target and turtle.getItemCount(s) > 0 and fuel() + FUEL_VALUE[d.name] <= limit do
        if not turtle.refuel(1) then break end
      end
    end
  end
  turtle.select(1)
  return fuel() >= target
end

local function cruiseY() return math.max(HOME.y, st.job and st.job.top or HOME.y) + 2 end

-- Fuel to get home from here (up to cruise height, across, down)
local function homeCost()
  local cy = math.max(cruiseY(), pos.y)
  return math.abs(pos.x - HOME.x) + math.abs(pos.z - HOME.z) + (cy - pos.y) + (cy - HOME.y) + 10
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

local function dig(d)
  local ok, why
  if d == UP then ok, why = turtle.digUp()
  elseif d == DOWN then ok, why = turtle.digDown()
  else face(d) ok, why = turtle.dig() end
  if ok then st.stats.dug = st.stats.dug + 1
  elseif type(why) == "string" and why:lower():find("tool") then error("No pickaxe: " .. why, 0) end
  return ok
end

local function attack(d)
  if d == UP then return turtle.attackUp() elseif d == DOWN then return turtle.attackDown() end
  face(d)
  return turtle.attack()
end

local function rawMove(d)
  local mv = turtle.forward
  if d == UP then mv = turtle.up elseif d == DOWN then mv = turtle.down else face(d) end
  st.pending = { d = d, fuel = turtle.getFuelLevel() }
  save()
  local ok = mv()
  if ok then pos.x, pos.y, pos.z = pos.x + DX[d], pos.y + DY[d], pos.z + DZ[d] end
  st.pending = nil
  save()
  return ok
end

-- One step. digAll: dig whatever is in the way (inside a job area); otherwise only
-- plants and leaves. Returns false when it can't get through.
local function move(d, digAll)
  if fuel() < 1 then error("Out of fuel", 0) end
  local fails = 0
  for _ = 1, RETRY do
    if rawMove(d) then return true end
    local info = inspect(d)
    if not info or isLiquid(info) then
      attack(d) -- a mob in the way
      sleep(0.3)
    elseif isMachine(info) then
      sleep(1) -- another turtle: let it pass
    elseif digAll or isSoft(info) then
      if not dig(d) then
        fails = fails + 1
        if fails >= 3 then return false end -- bedrock or protected
      end
    else
      return false
    end
  end
  return false
end

-- Go to x,y,z. Not digging (travel): it climbs over what's in the way. Digging (inside a
-- job): straight through. Up first, then across (x, then z), then down.
local function goTo(tx, ty, tz, digAll, cruise)
  local top = math.max(pos.y, ty, cruise or ty)
  while pos.y < top do
    if not move(UP, digAll) then
      if digAll then error("Can't get up at " .. at(), 0) end
      break -- under something: try going across from here
    end
  end
  local climbs = 0
  local function across(d, dist)
    while dist() > 0 do
      if not move(d, digAll) then
        climbs = climbs + 1
        if digAll or climbs > 40 or not move(UP, false) then error("Way blocked at " .. at(), 0) end
      end
    end
  end
  across(tx > pos.x and 1 or 3, function() return math.abs(tx - pos.x) end)
  across(tz > pos.z and 2 or 0, function() return math.abs(tz - pos.z) end)
  while pos.y > ty do
    if not move(DOWN, digAll) then error("Can't get down at " .. at(), 0) end
  end
  while pos.y < ty do
    if not move(UP, digAll) then error("Can't get up at " .. at(), 0) end
  end
end

local function inArea(j)
  return j and pos.x >= j.x1 and pos.x <= j.x2 and pos.z >= j.z1 and pos.z <= j.z2
end

local function goHome()
  if atHome() then face(FACING) return end
  setStatus("Going home")
  -- inside the job area it may dig its way up (it's all being dug there anyway)
  if inArea(st.job) and st.job.kind ~= "light" then goTo(pos.x, math.max(pos.y, cruiseY()), pos.z, true) end
  goTo(HOME.x, math.max(pos.y, cruiseY()), HOME.z, false)
  goTo(HOME.x, HOME.y, HOME.z, false)
  face(FACING)
end

---------------------------------------------------------------------------
-- Chests at home
---------------------------------------------------------------------------
local function chestSide(d)
  if d == DOWN then return "bottom" end
  face(d)
  return "front"
end
local function suck(d, n) if d == DOWN then return turtle.suckDown(n) end face(d) return turtle.suck(n) end
local function drop(d, n) if d == DOWN then return turtle.dropDown(n) end face(d) return turtle.drop(n) end

local function chestCount(d, want)
  local c = peripheral.wrap(chestSide(d))
  if not c or not c.list then return 0 end
  local n = 0
  for _, it in pairs(c.list()) do if want(it.name) then n = n + it.count end end
  return n
end

-- Take up to n of the items 'want' accepts. Other items stay in the chest.
local function take(d, want, n)
  local got = 0
  local side = chestSide(d)
  local c = peripheral.wrap(side)
  local held = {} -- slots holding things it took by mistake (old CC without self-moves)
  for _ = 1, 64 do
    if got >= n or freeSlots() <= #held then break end
    local first, wanted, empty
    if c and c.list then
      local list = c.list()
      for s = 1, c.size() do
        local it = list[s]
        if it and not first then first = s end
        if it and not wanted and want(it.name) then wanted = s end
        if not it and not empty then empty = s end
      end
      if not wanted then break end
      -- suck takes from the first stack: move the wanted stack to the front
      if wanted ~= first and empty then
        pcall(function()
          c.pushItems(side, first, 64, empty)
          c.pushItems(side, wanted, 64, first)
        end)
      end
    end
    local before = count(want)
    local slotsBefore = {}
    for s = 1, 16 do slotsBefore[s] = turtle.getItemCount(s) end
    if not suck(d, math.min(64, n - got)) then break end
    local now = count(want)
    if now == before then
      -- took something else: remember where it went, give it back at the end
      for s = 1, 16 do
        if turtle.getItemCount(s) > slotsBefore[s] then held[#held + 1] = s end
      end
    end
    got = got + (now - before)
  end
  for _, s in ipairs(held) do
    turtle.select(s)
    local dd = turtle.getItemDetail(s)
    if dd and not want(dd.name) then drop(d) end
  end
  turtle.select(1)
  return got
end

---------------------------------------------------------------------------
-- Ordering from the Storage Room (roomsorter.lua)
---------------------------------------------------------------------------
local radioOn = false
local storeId = nil

local function storeAsk(msg)
  if not radioOn then return nil, "no modem" end
  storeId = storeId or rednet.lookup(STORE_PROTOCOL)
  if not storeId then return nil, "no storage found" end
  msg.rid = math.random(1, 1073741824)
  rednet.send(storeId, msg, STORE_PROTOCOL)
  local deadline = os.clock() + 8
  while os.clock() < deadline do
    local from, m = rednet.receive(STORE_PROTOCOL, math.max(0.1, deadline - os.clock()))
    if from == storeId and type(m) == "table" and m.rid == msg.rid then return m end
  end
  storeId = nil
  return nil, "storage didn't answer"
end

-- Ask storage for n of one of 'names' (first that works). Returns true when it's coming.
local function order(names, n)
  for _, name in ipairs(names) do
    local last = st.ordered[name]
    if last and os.epoch("utc") - last < REORDER * 1000 then return true end
  end
  for _, name in ipairs(names) do
    local r = storeAsk({ cmd = "order", text = name, n = n })
    if not r then return false end
    local line = tostring(r[1] or "")
    if line:find("^Getting") or line:find("^Crafting") or line:find("^Only") then
      st.ordered[name] = os.epoch("utc")
      save()
      return true, line
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Jobs
---------------------------------------------------------------------------
local ALIAS = { floor = "floor", platform = "floor", walls = "walls", wall = "walls", flatten = "flatten",
  flat = "flatten", level = "flatten", clear = "clear", dig = "clear", light = "light", torches = "light",
  spawnproof = "light" }

local function itemName(s)
  s = tostring(s):lower():gsub("%s+", "_")
  if not s:find(":") then s = "minecraft:" .. s end
  return s
end

local function jobWords(text)
  local w = {}
  for x in tostring(text):gmatch("%S+") do w[#w + 1] = x end
  return w
end

-- "floor 1 64 2 10 64 12 stone" -> job table, or nil + why
local function parseJob(text)
  local w = jobWords(text)
  local kind = ALIAS[(w[1] or ""):lower()]
  if not kind then return nil, "Jobs: floor, walls, flatten, clear, light" end
  local n = {}
  for i = 2, 7 do
    n[i - 1] = tonumber(w[i])
    if not n[i - 1] then return nil, kind .. " x1 y1 z1 x2 y2 z2 ...: needs both corners" end
    n[i - 1] = math.floor(n[i - 1])
  end
  local j = { kind = kind, text = table.concat(w, " "), i = 1,
    x1 = math.min(n[1], n[4]), x2 = math.max(n[1], n[4]), z1 = math.min(n[3], n[6]), z2 = math.max(n[3], n[6]),
    y = n[2], ylo = math.min(n[2], n[5]), yhi = math.max(n[2], n[5]) }
  for _, x in ipairs({ j.x1, j.x2 }) do
    if math.abs(x - HOME.x) > REACH then return nil, "Too far from home (max " .. REACH .. " blocks)" end
  end
  for _, z in ipairs({ j.z1, j.z2 }) do
    if math.abs(z - HOME.z) > REACH then return nil, "Too far from home (max " .. REACH .. " blocks)" end
  end
  j.w, j.l = j.x2 - j.x1 + 1, j.z2 - j.z1 + 1
  local cells = j.w * j.l
  if kind == "floor" then
    j.block = itemName(w[8] or "cobblestone")
    j.n, j.top = cells, j.y
  elseif kind == "walls" then
    local h = tonumber(w[8])
    j.h = math.max(1, math.min(64, math.floor(h or 3)))
    j.block = itemName((h and w[9]) or (not h and w[8]) or "cobblestone")
    local perim = (j.w == 1 or j.l == 1) and cells or 2 * (j.w + j.l) - 4
    j.n, j.top = perim * j.h, j.y + j.h
  elseif kind == "flatten" then
    j.block = w[8] and itemName(w[8]) or nil
    j.n, j.top = cells, j.y
  elseif kind == "clear" then
    j.n, j.top = cells * (j.yhi - j.ylo + 1), j.yhi
  elseif kind == "light" then
    j.spacing = math.max(2, math.min(24, math.floor(tonumber(w[8]) or SPACING)))
    j.n, j.top = 0, math.max(j.y, HOME.y)
  end
  if j.n > MAX_CELLS then return nil, "Too big (" .. j.n .. " blocks, max " .. MAX_CELLS .. ")" end
  return j
end

local function describe(j)
  if not j then return "none" end
  local size = j.w .. "x" .. j.l
  if j.kind == "floor" then return "Floor " .. size .. " " .. pretty(j.block) end
  if j.kind == "walls" then return "Walls " .. size .. "x" .. j.h .. " " .. pretty(j.block) end
  if j.kind == "flatten" then return "Flatten " .. size .. " at y" .. (j.y - 1) end
  if j.kind == "clear" then return "Clear " .. size .. "x" .. (j.yhi - j.ylo + 1) end
  return "Light " .. size .. " every " .. j.spacing
end

-- Job geometry: the list of spots it works from, built once per job (not saved)
local G = { job = nil }
local function geometry(j)
  if G.job == j then return G end
  G = { job = j }
  local function serp(i, rev, total)
    if rev then i = total + 1 - i end
    local row, col = math.floor((i - 1) / j.w), (i - 1) % j.w
    if row % 2 == 1 then col = j.w - 1 - col end
    return j.x1 + col, j.z1 + row
  end
  if j.kind == "walls" then
    local p, seen = {}, {}
    local function add(x, z)
      local k = x .. "," .. z
      if not seen[k] then seen[k] = true p[#p + 1] = { x, z } end
    end
    for x = j.x1, j.x2 do add(x, j.z1) end
    for z = j.z1, j.z2 do add(j.x2, z) end
    for x = j.x2, j.x1, -1 do add(x, j.z2) end
    for z = j.z2, j.z1, -1 do add(j.x1, z) end
    G.perim = p
    j.n = #p * j.h
  elseif j.kind == "clear" then
    -- 3-high slices from the top: it digs up and down from the middle layer
    local slices, c = {}, j.yhi - 1
    while true do
      local cc = math.max(c, j.ylo)
      slices[#slices + 1] = cc
      if cc - 1 <= j.ylo then break end
      c = c - 3
    end
    G.slices = slices
    j.n = #slices * j.w * j.l
  elseif j.kind == "light" then
    local function line(a, b)
      local l = {}
      for v = a, b, j.spacing do l[#l + 1] = v end
      if b - l[#l] > j.spacing / 2 then l[#l + 1] = b end
      return l
    end
    local xs, zs = line(j.x1, j.x2), line(j.z1, j.z2)
    local pts = {}
    for r, z in ipairs(zs) do
      for c = 1, #xs do
        local x = xs[(r % 2 == 1) and c or (#xs + 1 - c)]
        pts[#pts + 1] = { x, z }
      end
    end
    G.points = pts
    j.n = #pts
  end
  G.serp = serp
  return G
end

-- Task i: where to stand and what to do there
local function task(j, i)
  local g = geometry(j)
  if j.kind == "floor" or j.kind == "flatten" then
    local x, z = g.serp(i)
    return { x = x, y = j.y, z = z }
  elseif j.kind == "walls" then
    local n = #g.perim
    local layer, k = math.floor((i - 1) / n), (i - 1) % n + 1
    return { x = g.perim[k][1], y = j.y + layer + 1, z = g.perim[k][2], layer = layer }
  elseif j.kind == "clear" then
    local per = j.w * j.l
    local s = math.floor((i - 1) / per) + 1
    local x, z = g.serp((i - 1) % per + 1, s % 2 == 0, per)
    return { x = x, y = g.slices[s], z = z }
  else
    return { x = g.points[i][1], z = g.points[i][2] }
  end
end

-- What the job needs to carry
local function wantFor(j)
  if not j then return nil end
  if j.kind == "floor" or j.kind == "walls" then return function(n) return n == j.block end end
  if j.kind == "light" then return function(n) return n == "minecraft:torch" end end
  if j.kind == "flatten" then
    if j.block then return function(n) return n == j.block end end
    return function(n) return FILLER[n] ~= nil end
  end
  return nil
end

local function orderNames(j)
  if j.kind == "light" then return { "minecraft:torch" } end
  if j.block then return { j.block } end
  return { "minecraft:cobblestone", "minecraft:dirt", "minecraft:cobbled_deepslate" }
end

-- How many it still needs (flatten: a few stacks, it mostly reuses what it digs)
local function stillNeeded(j)
  if j.kind == "flatten" then return j.nofill and 0 or 64 end
  if j.kind == "clear" then return 0 end
  return math.max(0, j.n - j.i + 1)
end

-- Place a block below from the slots 'want' accepts. false = has none.
local function placeDown(want, prefer)
  for _ = 1, 5 do
    if not selectItem(want, prefer) then return false end
    if turtle.placeDown() then
      st.stats.placed = st.stats.placed + 1
      turtle.select(1)
      return true
    end
    local info = inspect(DOWN)
    if info and not isLiquid(info) then
      if isSolid(info) then turtle.select(1) return true end -- something got there first
      dig(DOWN)
    else
      turtle.attackDown()
    end
    sleep(0.2)
  end
  turtle.select(1)
  return true -- can't place here (protected?): skip it
end

-- Make the block below 'name' (floors and walls)
local function setBelow(name)
  local info = inspect(DOWN)
  if info and info.name == name then return true end
  if info and not isLiquid(info) then dig(DOWN) end
  return placeDown(function(n) return n == name end)
end

local function doTask(j, t)
  local want = wantFor(j)
  if j.kind == "floor" then
    goTo(t.x, t.y, t.z, true)
    return setBelow(j.block)
  elseif j.kind == "walls" then
    goTo(t.x, t.y, t.z, true)
    return setBelow(j.block)
  elseif j.kind == "clear" then
    goTo(t.x, t.y, t.z, true)
    if t.y + 1 <= j.yhi then
      for _ = 1, 16 do -- gravel and sand keep falling
        local info = inspect(UP)
        if not info or isLiquid(info) then break end
        if not dig(UP) then break end
        sleep(0.1)
      end
    end
    if t.y - 1 >= j.ylo then
      local info = inspect(DOWN)
      if info and not isLiquid(info) then dig(DOWN) end
    end
    return true
  elseif j.kind == "flatten" then
    goTo(t.x, t.y, t.z, true)
    -- everything above the new ground goes (hills, trees)
    local up = 0
    while up < CAP do
      local info = inspect(UP)
      if not info or isLiquid(info) then break end
      if not move(UP, true) then break end
      up = up + 1
    end
    while pos.y > t.y do move(DOWN, true) end
    if j.nofill then return true end
    -- dips get filled: down to FILL_DEPTH, then blocks back up to the ground level
    local info = inspect(DOWN)
    if isSolid(info) then return true end
    if count(want) == 0 then return false end
    local ground = t.y - 1
    while pos.y > ground - FILL_DEPTH + 1 do
      local below = inspect(DOWN)
      if isSolid(below) then break end
      if below and not isLiquid(below) then dig(DOWN) end
      if not move(DOWN, true) then break end
    end
    while pos.y <= t.y - 1 do
      move(UP, true)
      -- dirt on top, stone underneath
      local top = pos.y - 1 == ground
      if not placeDown(want, function(n) return (FILLER[n] == 1) == top and 1 or 0 end) then
        return false
      end
    end
    return true
  elseif j.kind == "light" then
    goTo(t.x, math.max(pos.y, HOME.y), t.z, false)
    -- down to the ground, through plants
    for _ = 1, 64 do
      local info = inspect(DOWN)
      if info and not isSoft(info) or info and info.name:find("leaves") then break end
      if info then dig(DOWN) end
      if not move(DOWN, false) then break end
    end
    local below = inspect(DOWN)
    if not below or isLiquid(below) or below.name:find("torch") or below.name:find("lantern") then
      return true -- water, or there's a light already
    end
    if count(want) == 0 then return false end
    if not move(UP, false) then return true end -- no room for a torch here
    return placeDown(want)
  end
  return true
end

---------------------------------------------------------------------------
-- At home: unload, refuel, restock
---------------------------------------------------------------------------
-- Fuel: burn what it carries, then from the supply chest, then ask storage
local function refuel()
  if fuel() >= REFUEL_BELOW then return true end
  burn(REFUEL_TO)
  if fuel() < REFUEL_BELOW then
    if wh2 and wh2.managed() then error("Fleet charging blocked: builder journal has no shared service adapter", 0) end
    local per = 80
    take(SUPPLY, isFuel, math.min(64, math.ceil((REFUEL_TO - fuel()) / per)))
    burn(REFUEL_TO)
  end
  -- empty buckets back in the supply chest
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == "minecraft:bucket" then turtle.select(s) drop(SUPPLY) end
  end
  turtle.select(1)
  if fuel() < MIN_FUEL then
    setStatus("Low on fuel: ordering charcoal")
    order({ "minecraft:charcoal", "minecraft:coal" }, 32)
    return false
  end
  return true
end

-- Everything it doesn't need for the job goes in the dump chest
local function unload(want, keep)
  if wh2 and wh2.managed() then error("Fleet drop-off blocked: builder journal has no shared service adapter", 0) end
  local d = cfg.dump or SUPPLY
  local kept = 0
  for s = 1, 16 do
    local it = turtle.getItemDetail(s)
    if it then
      local useful = KEEP_ITEMS[it.name] or want and want(it.name) and kept < keep
      if useful then
        kept = kept + it.count
      elseif not isFuel(it.name) or fuel() >= REFUEL_TO then
        turtle.select(s)
        if not drop(d) and d ~= SUPPLY then drop(SUPPLY) end
      end
    end
  end
  turtle.select(1)
end

-- Get what the job needs. Returns how many it has.
local function restock(j)
  local want = wantFor(j)
  if not want then return 0 end
  local cap = math.max(0, 16 - KEEP_FREE - 1) * 64
  local need = math.min(stillNeeded(j), cap)
  local have = count(want)
  if have >= need then return have end
  have = have + take(SUPPLY, want, need - have)
  if have >= need then return have end
  -- ask the Storage Room for the rest, and wait for it in the supply chest
  local coming, line = order(orderNames(j), need - have)
  if not coming then return have end
  local start, lastGot = os.clock(), os.clock()
  while have < need and os.clock() - start < ORDER_WAIT do
    setStatus("Waiting for " .. (need - have) .. " " .. pretty(orderNames(j)[1]) .. " from storage")
    if line then logError("Ordered: " .. line, true) line = nil end
    sleep(5)
    local got = take(SUPPLY, want, need - have)
    if got > 0 then have, lastGot = have + got, os.clock() end
    if have > 0 and os.clock() - lastGot > 60 then break end -- it sent what it had
    if st.stopNow or st.paused then break end
  end
  return have
end

---------------------------------------------------------------------------
-- Running a job
---------------------------------------------------------------------------
-- Works from task j.i on. Returns why it stopped: done, fuel, material, full, pause, stop, home
local function runJob(j)
  local want = wantFor(j)
  geometry(j)
  while j.i <= j.n do
    if st.stopNow then return "stop" end
    if st.paused then return "pause" end
    if ui.homeNow or ui.updateNow then return "home" end
    if fuel() < math.max(REFUEL_BELOW, homeCost() + FUEL_MARGIN + 2 * CAP) then return "fuel" end
    if (j.kind == "clear" or j.kind == "flatten") and inventoryNeedsService() then return "full" end
    if want and j.kind ~= "flatten" and count(want) == 0 then return "material" end
    setStatus(describe(j) .. ": " .. math.floor((j.i - 1) * 100 / math.max(1, j.n)) .. "%")
    local t = task(j, j.i)
    if not KEEP_OUT[t.x .. "," .. t.z] then -- leave home and its chests alone
      if j.kind ~= "light" and math.abs(t.x - pos.x) + math.abs(t.z - pos.z) > 1 then
        -- coming from home or elsewhere: travel over things, only dig once above the spot
        goTo(t.x, math.max(pos.y, cruiseY()), t.z, false)
      end
      if not doTask(j, t) then return "material" end
    end
    j.i = j.i + 1
    save()
  end
  return "done"
end

---------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------
local W, H = term.getSize()
local function stateName()
  if st.paused then return "PAUSED" end
  if st.job then return atHome() and "AT HOME" or "BUILDING" end
  return "IDLE"
end

local function addJob(text)
  local j, why = parseJob(text)
  if not j then return false, why end
  geometry(j) -- counts the spots (walls, clear, light)
  if j.n > MAX_CELLS then return false, "Too big (" .. j.n .. " blocks, max " .. MAX_CELLS .. ")" end
  st.queue[#st.queue + 1] = j
  save()
  os.queueEvent("builder_wake")
  if st.job then return true, "Queued: " .. describe(j) .. " (" .. #st.queue .. " waiting)" end
  return true, "Starting: " .. describe(j)
end

local function drawScreen()
  if ui.typing then return end
  W, H = term.getSize()
  local color = term.isColor()
  local function col(c, plain) return color and c or (plain or colors.white) end
  local function row(y, s, fg, bg)
    term.setCursorPos(1, y)
    term.setBackgroundColor(bg or colors.black)
    term.setTextColor(fg or colors.white)
    s = tostring(s)
    term.write(s:sub(1, W) .. (" "):rep(math.max(0, W - #s)))
  end
  local name = stateName()
  local bc = st.paused and col(colors.yellow, colors.white) or col(colors.pink, colors.white)
  row(1, " " .. (os.getComputerLabel() or "Builder") .. (" "):rep(math.max(1, W - #name - 2
    - #(os.getComputerLabel() or "Builder"))) .. name .. " ", colors.black, bc)
  row(2, "")
  row(3, " " .. ui.status, col(colors.yellow))
  local j = st.job
  row(4, "")
  row(5, " Job     " .. describe(j), colors.white)
  if j then
    local frac = (j.i - 1) / math.max(1, j.n)
    local bw = math.max(4, W - 16)
    local f = math.floor(bw * frac + 0.5)
    term.setCursorPos(1, 6)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write(" Done    ")
    term.setBackgroundColor(col(colors.lime, colors.white))
    term.write((" "):rep(f))
    term.setBackgroundColor(col(colors.gray, colors.black))
    term.write((" "):rep(bw - f))
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.write(" " .. math.floor(frac * 100) .. "%   ")
  else
    row(6, " Done    -", colors.lightGray)
  end
  local want = wantFor(j)
  row(7, " Fuel    " .. (fuel() == math.huge and "unlimited" or tostring(fuel())), colors.white)
  row(8, " Blocks  " .. (want and (count(want) .. " " .. pretty(orderNames(j)[1]) .. " on board") or "-"), colors.white)
  row(9, " Where   " .. (atHome() and "at home" or at()), colors.white)
  row(10, " Queue   " .. #st.queue .. "   Jobs done " .. st.stats.jobs .. "   Placed " .. st.stats.placed,
    colors.lightGray)
  row(11, ui.lastError and (" ! " .. ui.lastError) or "", col(colors.red))
  for y = 12, H - 1 do row(y, "") end
  local keys = " [J]ob [P]ause [H]ome [S]top [Q]uit"
  if st.paused then keys = " [J]ob [P] go on [S]top [Q]uit" end
  if ui.quitAsk then keys = " Press Q again to quit, any key: no" end
  if ui.stopAsk then keys = " Press S again to stop the job" end
  row(H, keys, colors.white, col(colors.gray, colors.black))
  term.setBackgroundColor(colors.black)
end

local function screen()
  ui.draw = function() pcall(drawScreen) end
  ui.draw()
  local timer = os.startTimer(1)
  while true do
    local ev, a = os.pullEvent()
    if ev == "timer" and a == timer then
      ui.draw()
      timer = os.startTimer(1)
    elseif ev == "key" then
      if ui.quitAsk then
        ui.quitAsk = false
        if a == keys.q then
          term.setBackgroundColor(colors.black)
          term.clear()
          term.setCursorPos(1, 1)
          print("Builder stopped. Type builder to start it again.")
          return
        end
      elseif ui.stopAsk then
        ui.stopAsk = false
        if a == keys.s then st.stopNow = true os.queueEvent("builder_wake") end
      elseif a == keys.p then
        st.paused = not st.paused
        save()
        os.queueEvent("builder_wake")
      elseif a == keys.h then ui.homeNow = true
      elseif a == keys.s and st.job then ui.stopAsk = true
      elseif a == keys.q then ui.quitAsk = true
      elseif a == keys.j then
        ui.typing = true
        sleep(0) -- swallow the 'j' char event
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.white)
        print("New job (where you stand, F3):")
        print(" floor x1 y1 z1 x2 y2 z2 [block]")
        print(" walls x1 y1 z1 x2 y2 z2 [height] [block]")
        print(" flatten x1 y1 z1 x2 y2 z2 [filler]")
        print(" clear x1 y1 z1 x2 y2 z2")
        print(" light x1 y1 z1 x2 y2 z2 [spacing]")
        if not cfg.world then print("(no GPS: home = 0 0 0, x right, -z ahead)") end
        write("> ")
        local line = read()
        if line and line:find("%S") then
          local _, msg = addJob(line)
          print(msg)
          sleep(2)
        end
        ui.typing = false
      end
      ui.draw()
    elseif ev == "term_resize" then
      ui.draw()
    end
  end
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------
local function waitFor(secs)
  local timer = os.startTimer(secs)
  while true do
    local ev, a = os.pullEvent()
    if ev == "builder_wake" or (ev == "timer" and a == timer) then return end
  end
end

-- After a reboot or an error: safely back home (a job carries on from where it was)
local function recover()
  if not atHome() then goHome() end
  face(FACING)
end

local function worker()
  while true do
    local ok, err = pcall(recover)
    if ok then break end
    if err == "Terminated" then error(err, 0) end
    logError(err)
    setStatus("STUCK: " .. tostring(err))
    sleep(30)
  end
  while true do
    -- at home here
    if ui.updateNow then
      ui.updateNow = false
      setStatus("Updating from GitHub")
      shell.run(shell.getRunningProgram(), "update") -- reboots if there's a new version
    end
    ui.homeNow = false
    if st.stopNow then
      st.stopNow = false
      if st.job then logError("Stopped: " .. describe(st.job), true) end
      st.job = nil
      save()
    end
    if not st.job and #st.queue > 0 then
      st.job = table.remove(st.queue, 1)
      save()
    end
    local j = st.job
    local want = wantFor(j)
    unload(want, j and math.min(stillNeeded(j), 13 * 64) or 0)
    if st.paused then
      setStatus("Paused at home. Press P to go on")
      waitFor(WAIT)
    elseif not j then
      refuel()
      setStatus("Waiting for a job (press J)")
      waitFor(WAIT)
    elseif not refuel() and fuel() < MIN_FUEL then
      setStatus("Out of fuel: put coal or lava in my chest")
      waitFor(WAIT)
    else
      local have = restock(j)
      local go = true
      if want and have == 0 and stillNeeded(j) > 0 then
        if j.kind == "flatten" then
          -- no filler anywhere: cut the hills anyway, leave the dips
          j.nofill = true
          logError("No filler blocks: flattening without filling dips", true)
          save()
        else
          setStatus("Need " .. pretty(orderNames(j)[1]) .. ": put some in my chest")
          waitFor(WAIT)
          go = false
        end
      end
      if go then
        local ok, why = pcall(runJob, j)
        if not ok then
          if why == "Terminated" then error(why, 0) end
          logError(why)
          setStatus("Error: " .. tostring(why))
        elseif why == "done" then
          st.stats.jobs = st.stats.jobs + 1
          logError("Done: " .. describe(j), true)
          st.job = nil
          save()
        end
        local ok2, err2 = pcall(recover)
        while not ok2 do
          if err2 == "Terminated" then error(err2, 0) end
          logError(err2)
          setStatus("STUCK: " .. tostring(err2))
          sleep(30)
          ok2, err2 = pcall(recover)
        end
        if not ok then sleep(10) end
      end
    end
  end
end

-- Developer commands from the pocket panel's console (panel.lua): info, log, ls, cat,
-- get (copy a file to the pocket), reboot, and put / rm / lua (write or delete a file,
-- run Lua). If this computer has a file "dev.key", every command needs that same
-- password (on the pocket: key <password>). put, rm and lua only work once dev.key exists.
-- drive: move / turn / dig / place / look, answered with the position and the blocks
-- around it, for the pocket's map. hooks (optional) let the program keep its own idea of
-- where it is: pose() -> x, y, z, forward x, forward z (map: +x right, +z down),
-- turn(right), move("forward"|"back"|"up"|"down") -> ok, why; busy() -> reason or nil.
local devDrive = { x = 0, y = 0, z = 0, h = 0 } -- position used when there are no hooks
local function devDriveHooks()
  local HX, HZ = { [0] = 0, 1, 0, -1 }, { [0] = -1, 0, 1, 0 }
  local p = devDrive
  return {
    pose = function() return p.x, p.y, p.z, HX[p.h], HZ[p.h] end,
    turn = function(right)
      if right then turtle.turnRight() else turtle.turnLeft() end
      p.h = (p.h + (right and 1 or 3)) % 4
    end,
    move = function(dir)
      local ok, why = ({ forward = turtle.forward, back = turtle.back, up = turtle.up, down = turtle.down })[dir]()
      if ok then
        local s = dir == "back" and -1 or 1
        if dir == "up" then p.y = p.y + 1 elseif dir == "down" then p.y = p.y - 1
        else p.x, p.z = p.x + s * HX[p.h], p.z + s * HZ[p.h] end
      end
      return ok, why
    end,
  }
end

local function devCommand(m, logFile, program, reply, hooks)
  local r = { type = "dev_reply", rid = m.rid, ok = true }
  local function out(s) r.out = tostring(s) end
  local key
  if fs.exists("dev.key") then
    local h = fs.open("dev.key", "r")
    key = (h.readAll() or ""):gsub("%s+$", "")
    h.close()
  end
  local op, path = m.op, tostring(m.path or "")
  if key and key ~= "" and m.key ~= key then r.ok = false out("Wrong or missing dev key")
  elseif op == "info" then
    local fuel = turtle and turtle.getFuelLevel() or nil
    local free = 0
    if turtle then for s = 1, 16 do if turtle.getItemCount(s) == 0 then free = free + 1 end end end
    out((os.getComputerLabel() or "?") .. " #" .. os.getComputerID() .. " running " .. program
      .. (fuel and (" | fuel " .. tostring(fuel) .. " | " .. free .. " free slots") or "")
      .. " | up " .. math.floor(os.clock() / 60) .. " min | disk free " .. math.floor(fs.getFreeSpace("/") / 1024) .. " KB")
  elseif op == "log" then
    if not logFile or not fs.exists(logFile) then out("No log file")
    else
      local h = fs.open(logFile, "r")
      local lines = {}
      for l in (h.readAll() .. "\n"):gmatch("([^\n]*)\n") do if l ~= "" then lines[#lines + 1] = l end end
      h.close()
      local n = math.max(1, tonumber(m.n) or 10)
      out(table.concat(lines, "\n", math.max(1, #lines - n + 1)))
      if #lines == 0 then out("Log is empty") end
    end
  elseif op == "ls" then
    if path == "" then path = "/" end
    if not fs.isDir(path) then r.ok = false out("No such folder: " .. path)
    else
      local l = {}
      for _, f in ipairs(fs.list(path)) do
        local p = fs.combine(path, f)
        l[#l + 1] = fs.isDir(p) and (f .. "/") or (f .. " " .. fs.getSize(p))
      end
      out(#l > 0 and table.concat(l, "\n") or "(empty)")
    end
  elseif op == "cat" or op == "get" then
    local name = fs.getName(path)
    if name == "api.key" or name == "dev.key" then r.ok = false out("Secret file, not sent")
    elseif not fs.exists(path) or fs.isDir(path) then r.ok = false out("No such file: " .. path)
    else
      local h = fs.open(path, "r")
      r.data = h.readAll()
      h.close()
      out(op == "cat" and r.data or (path .. ": " .. #r.data .. " bytes"))
      if op == "cat" then r.data = nil end
    end
  elseif (op == "put" or op == "rm" or op == "lua") and not (key and key ~= "") then
    r.ok = false
    out("Locked: pair it first (stand next to it with the pocket, type pair) to allow " .. op)
  elseif op == "put" then
    if path == "" or type(m.data) ~= "string" then r.ok = false out("put needs a file name and its contents")
    else
      if fs.exists(path) then
        if fs.exists(path .. ".bak") then fs.delete(path .. ".bak") end
        fs.copy(path, path .. ".bak")
      end
      local h = fs.open(path, "w")
      h.write(m.data)
      h.close()
      out("Wrote " .. path .. " (" .. #m.data .. " bytes, the old one is " .. path .. ".bak)")
    end
  elseif op == "rm" then
    if path == "" or not fs.exists(path) then r.ok = false out("No such file: " .. path)
    else fs.delete(path) out("Deleted " .. path) end
  elseif op == "lua" then
    local env = setmetatable({}, { __index = _ENV or _G })
    local code = tostring(m.code or "")
    local fn, err = load("return " .. code, "=dev", "t", env)
    if not fn then fn, err = load(code, "=dev", "t", env) end
    if not fn then r.ok = false out(err)
    else
      local res = table.pack(pcall(fn))
      r.ok = res[1]
      local l = {}
      for i = 2, res.n do
        local ok, s = pcall(textutils.serialize, res[i])
        l[#l + 1] = ok and s or tostring(res[i])
      end
      out(#l > 0 and table.concat(l, ", ") or "(done, nothing returned)")
    end
  elseif op == "drive" then
    local hk = hooks or devDriveHooks()
    local why = not turtle and "This is not a turtle" or (hk.busy and hk.busy())
    local act = tostring(m.act or "scan")
    local seen = {}
    local function look(dx, dy, dz, fn)
      local x, y, z = hk.pose()
      local ok, info = fn()
      seen[#seen + 1] = { x = x + dx, y = y + dy, z = z + dz, name = ok and info.name or "air" }
    end
    local function lookFront() local _, _, _, fx, fz = hk.pose() look(fx, 0, fz, turtle.inspect) end
    if why then r.ok = false out(why)
    else
      local ok, err = true, nil
      if act == "left" or act == "right" then hk.turn(act == "right")
      elseif act == "forward" or act == "back" or act == "up" or act == "down" then
        if turtle.getFuelLevel() == 0 then ok, err = false, "Out of fuel" else ok, err = hk.move(act) end
      elseif act == "dig" then ok, err = turtle.dig()
      elseif act == "digUp" then ok, err = turtle.digUp()
      elseif act == "digDown" then ok, err = turtle.digDown()
      elseif act == "place" then ok, err = turtle.place()
      elseif act == "placeUp" then ok, err = turtle.placeUp()
      elseif act == "placeDown" then ok, err = turtle.placeDown()
      elseif act == "look" then for _ = 1, 4 do lookFront() hk.turn(true) end
      elseif act ~= "scan" then ok, err = false, "Unknown move: " .. act end
      lookFront()
      look(0, 1, 0, turtle.inspectUp)
      look(0, -1, 0, turtle.inspectDown)
      local x, y, z, fx, fz = hk.pose()
      r.drive = { x = x, y = y, z = z, fx = fx, fz = fz, seen = seen, fuel = turtle.getFuelLevel(), home = hk.home }
      r.ok = ok and true or false
      out(ok and (act == "scan" and "Ready" or "OK") or (act .. ": " .. tostring(err or "can't")))
    end
  elseif op == "reboot" then
    out("Rebooting...")
    reply(r)
    sleep(0.5)
    os.reboot()
    return
  else r.ok = false out("Unknown dev command: " .. tostring(op)) end
  reply(r)
end

-- Pairing with the pocket's "pair" command: the pocket sends its password on a modem
-- channel and this computer saves it as dev.key, but only if the pocket is within 3 blocks
-- (so only someone standing next to it can pair) and it has no dev.key yet.
local DEV_PAIR_CHANNEL = 16523
local function devPairLoop()
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then while true do os.pullEvent("dev_never") end end
  modem.open(DEV_PAIR_CHANNEL)
  -- Mesh: also pass on rednet messages meant for others, like CC's "repeat" program (each
  -- message once), so the server and the hub reach bots beyond their range through this
  -- one. Switch it off with: set fleet.mesh false
  local relayed = not (settings and settings.get("fleet.mesh") == false) and { n = 0 } or nil
  if relayed then modem.open(rednet.CHANNEL_REPEAT) end
  while true do
    local _, _, ch, replyCh, msg, dist = os.pullEvent("modem_message")
    if relayed and ch == rednet.CHANNEL_REPEAT and type(msg) == "table" and type(msg.nMessageID) == "number"
      and type(msg.nRecipient) == "number" and not relayed[msg.nMessageID] then
      if relayed.n > 500 then
        for k, t in pairs(relayed) do if k ~= "n" and t < os.clock() then relayed[k] = nil end end
        relayed.n = 0
      end
      relayed[msg.nMessageID], relayed.n = os.clock() + 60, relayed.n + 1
      modem.transmit(rednet.CHANNEL_REPEAT, replyCh, msg)
      modem.transmit(msg.nRecipient == rednet.CHANNEL_BROADCAST and msg.nRecipient or msg.nRecipient % 65500, replyCh, msg)
    elseif ch == DEV_PAIR_CHANNEL and type(msg) == "table" and msg.type == "dev_pair" then
      local res
      if fs.exists("dev.key") then res = "Already paired"
      elseif type(dist) ~= "number" or dist > 3 then res = "Too far away"
      elseif type(msg.newKey) ~= "string" or #msg.newKey < 8 then res = "Bad password"
      else
        local h = fs.open("dev.key", "w")
        h.write(msg.newKey)
        h.close()
        res = "Paired"
      end
      modem.transmit(replyCh, DEV_PAIR_CHANNEL, { type = "dev_pair_reply", id = os.getComputerID(),
        label = os.getComputerLabel(), text = res })
    end
  end
end

-- Driving from the pocket isn't wired into this program's own moves yet, so it's refused
-- (moving it behind its back would make it lose track of where it is)
local NO_DRIVE = { busy = function() return "Driving isn't supported on this bot yet" end }

-- Pocket control panel (panel.lua): status, jobs, pause / home / stop and Update all.
local function radio()
  if not radioOn then while true do os.pullEvent("builder_never") end end
  rednet.host(PROTOCOL, os.getComputerLabel() or ("builder" .. os.getComputerID()))
  while true do
    local id, m = rednet.receive(PROTOCOL)
    if type(m) == "table" and m.type == "dev" then
      devCommand(m, LOG_FILE, "builder", function(r) rednet.send(id, r, PROTOCOL) end, NO_DRIVE)
    elseif type(m) == "table" then
      local note
      if m.cmd == "pause" then st.paused = true save()
      elseif m.cmd == "resume" then st.paused = false save()
      elseif m.cmd == "home" then ui.homeNow = true
      elseif m.cmd == "stop" then
        if st.job then st.stopNow = true note = "Stopping the job, coming home." else note = "No job running." end
      elseif m.cmd == "clear" then st.queue = {} save() note = "Queue cleared."
      elseif m.cmd == "job" then
        local _, msg = addJob(m.text)
        note = msg
      elseif m.cmd == "update" then ui.updateNow, ui.homeNow = true, true end
      if m.cmd and m.cmd ~= "status" then os.queueEvent("builder_wake") ui.draw() end
      local j, want = st.job, wantFor(st.job)
      local queue = {}
      for k, q in ipairs(st.queue) do queue[k] = describe(q) end
      rednet.send(id, { type = "builder_state", rid = m.rid, label = os.getComputerLabel(), state = stateName(),
        status = ui.status, note = note, fuel = fuel(), fuelMax = REFUEL_TO,
        job = j and { text = j.text, desc = describe(j), kind = j.kind, i = j.i, n = j.n } or nil,
        material = want and { name = orderNames(j)[1], have = count(want), need = stillNeeded(j) } or nil,
        queue = queue, jobs = st.stats.jobs, placed = st.stats.placed, dug = st.stats.dug,
        paused = st.paused, err = ui.lastError, world = cfg.world,
        pos = { x = pos.x, y = pos.y, z = pos.z }, home = HOME,
        gps = cfg.world and { x = pos.x, y = pos.y, z = pos.z } or nil }, PROTOCOL)
    end
  end
end

-- "builder floor ..." typed in the shell: queue it and start
if args[1] then
  local ok, msg = addJob(table.concat(args, " "))
  print(msg)
  if not ok then return end
  sleep(1)
end

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if modem then
  rednet.open(peripheral.getName(modem))
  radioOn = true
end

term.clear()
turtle.select(1)
parallel.waitForAny(worker, screen, radio, devPairLoop)
