if fs and fs.exists("wh2-program.lua") and not rawget(_ENV,"__wh2Running") then
  if dofile("wh2-program.lua").run("lava.lua",...) then return end
end
-- lava.lua - lava fuel runner (CC: Tweaked)
--
-- A turtle that collects lava in buckets and keeps the other bots' chests stocked with
-- it: the lumberjack's chest, the miners' chests, or any chest you name.
-- Where the lava comes from:
--  * A dripstone + cauldron farm at its home (the easy way: it never leaves home).
--    Cauldrons on the left and right of its home spot and of a straight corridor in
--    front of it, plus one at the end of the corridor, each under a pointed dripstone
--    with lava above it. It walks the corridor and fills buckets at the full cauldrons.
--  * A lava pool or lake: it flies there, scoops the lava column by column from the
--    middle out, a few blocks deep, and flies back. It remembers where it got to.
-- Full buckets go in its home chest (behind it). On a delivery round it takes them out
-- again, flies to each drop-off chest, drops lava in from above until that chest has
-- enough, and takes the empty buckets there home to fill them again.
-- It burns its own lava when it runs low. It never digs: only grass, flowers, leaves
-- and snow in its way, and only if it has a tool. It flies over things, so give it room.
--
-- Needs: a turtle with a wireless or ender modem (for the pocket panel and GPS), a chest
-- behind it with a few empty buckets in it, and a little fuel to start (one lava bucket).
--
-- One-time setup:
--   lava setup <x> <y> <z> <facing>  its own position (F3) and the way it faces, with
--                                    the chest behind it
--   lava setup                       the same from GPS (it turns to find the chest and
--                                    needs a free block in front of or behind it)
--   Setup also looks for cauldrons next to it and along the corridor in front of it.
-- Then:
--   lava                        run (starts by itself on boot after setup).
--                               Keys: P pause / go on, R run now, H come home, Q quit.
--   lava add <name> <x> <y> <z> [buckets]   a drop-off chest at x y z, kept at that many
--                               lava buckets (default 6). The block above it must be
--                               free: the turtle hovers there and drops the lava in.
--   lava add <name> here [buckets]   the same, with the turtle put ON the chest (GPS)
--   lava remove <name>          forget a drop-off chest
--   lava list                   the drop-offs, the pool and the farm
--   lava pool <x> <y> <z>       a lava pool: x y z of a lava block on its surface
--   lava pool off               stop going to the pool
--   lava exit <x> <y> <z>       a free spot outside your base it flies to first when it
--   lava exit off               leaves for a pool or drop-off (when home is indoors)
--   lava scan                   look for cauldrons again (after building more)
--   lava home                   after putting it back on its home spot by hand
--   lava update                 fetch the latest version from GitHub

local CFG_FILE, STATE_FILE, LOG_FILE = "lava.cfg", "lava.state", "lava.log"
local PROTOCOL = "lava"

local WANT = 6             -- lava buckets to keep in a drop-off chest (lava add can change it)
local KEEP_EMPTY = 1       -- empty buckets it leaves in a drop-off (a miner likes a spare)
local ROUND_EVERY = 15     -- minutes between delivery rounds
local FARM_EVERY = 5       -- minutes between walks along the cauldrons
local POOL_BELOW = 8       -- go to the pool when the home chest has fewer lava buckets than this...
local POOL_EVERY = 10      -- ...but at most once every this many minutes
local POOL_RADIUS = 12     -- how far from the pool point it looks for lava
local POOL_DEPTH = 6       -- how far below the surface it scoops
local HOP = 3              -- fly this many blocks above the higher end of a flight
local MAX_CLIMB = 40       -- never climb more than this above the higher end of a flight
local CORRIDOR_MAX = 32    -- longest cauldron corridor setup looks along
local BLIND = 2            -- lava buckets it drops in a chest it can't look into
local REFUEL_BELOW = 1000  -- burns its own lava below this...
local REFUEL_TO = 2000     -- ...up to about this (a lava bucket is 1000)
local MIN_FUEL = 100       -- below this it stays home
local WAIT = 60            -- seconds between looks when there is nothing to do
local RETRY = 20
local FUEL_MARGIN, MIN_FREE, FULLNESS_HIGH, KEEP_ITEMS = 50, 0, math.huge, {}
if wh2 then
  wh2.bind(function(values)
    REFUEL_BELOW, REFUEL_TO, FUEL_MARGIN = values.fuelLow, values.fuelTarget, values.fuelMargin
    MIN_FUEL, MIN_FREE = values.minTripFuel, values.minFreeSlots
    FULLNESS_HIGH, KEEP_ITEMS = values.fullnessHigh, values.keep
  end)
end

local LAVA, BUCKET = "minecraft:lava_bucket", "minecraft:bucket"

-- Directions: 0=north(-z) 1=east(+x) 2=south(+z) 3=west(-x) 4=up 5=down
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
  local raw = dofile("atomic.lua").read(path)
  if type(raw) ~= "table" then return nil end
  if (raw.v == 1 or raw.schema == 1) and type(raw.generation) == "number" and type(raw.value) == "table" then
    return raw.value
  end
  return raw
end

local A = dofile("atomic.lua")
local disk = A.mount("/")
local saved = {}
local function saveTable(path, t)
  local rec = saved[path]
  if not rec then
    rec = disk:open(path, function(v) return type(v) == "table" end, { class = "bulk", limit = 900000 })
    saved[path] = rec
  end
  return rec:save(t)
end

local function hasTag(info, t) return info and info.tags and info.tags[t] end

local function isChest(info)
  if not info then return false end
  if info.name:find("chest") or info.name:find("barrel") then return true end
  return hasTag(info, "c:chests") or hasTag(info, "forge:chests") or hasTag(info, "c:barrels")
end

local function isCauldron(info)
  return info ~= nil and (info.name == "minecraft:cauldron" or info.name == "minecraft:lava_cauldron")
end

---------------------------------------------------------------------------
-- GPS (optional)
---------------------------------------------------------------------------
local function gpsHere()
  if not gps or not peripheral.find("modem", function(_, m) return m.isWireless() end) then return nil end
  local x, y, z = gps.locate(2)
  if not x then return nil end
  return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
end

-- Which way it faces, by GPS: one block forward (or back) and back again
local function gpsFacing(here)
  local sign
  if turtle.forward() then sign = 1 elseif turtle.back() then sign = -1 else return nil end
  local p = gpsHere()
  for _ = 1, 20 do
    if (sign == 1 and turtle.back()) or (sign == -1 and turtle.forward()) then break end
    sleep(0.5)
  end
  if not p then return nil end
  local dx, dz = (p.x - here.x) * sign, (p.z - here.z) * sign
  for d = 0, 3 do
    if DX[d] == dx and DZ[d] == dz then return d end
  end
  return nil
end

local function coords(a, b, c)
  local x, y, z = tonumber(a), tonumber(b), tonumber(c)
  if not (x and y and z) then return nil end
  return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
end

---------------------------------------------------------------------------
-- Setup and commands
---------------------------------------------------------------------------
if args[1] == "setup" then
  if not turtle then error("lava.lua runs on a turtle", 0) end
  local home, facing
  if args[2] then
    home = coords(args[2], args[3], args[4])
    facing = DIRS[(args[5] or ""):lower()]
    if not (home and facing) then
      print("Usage: lava setup <x> <y> <z> <facing>   (facing: north/east/south/west)")
      print("   or: lava setup   (with GPS)")
      return
    end
    turtle.turnLeft() turtle.turnLeft()
    local ok, info = turtle.inspect()
    turtle.turnLeft() turtle.turnLeft()
    if not (ok and isChest(info)) then print("WARNING: no chest behind the turtle!") end
  else
    -- turn until the chest is behind it, then ask GPS where that is
    local found = false
    for _ = 1, 4 do
      turtle.turnLeft() turtle.turnLeft()
      local ok, info = turtle.inspect()
      turtle.turnLeft() turtle.turnLeft()
      if ok and isChest(info) then found = true break end
      turtle.turnRight()
    end
    if not found then print("WARNING: no chest found next to the turtle!") end
    home = gpsHere()
    if not home then
      print("No GPS here. Use: lava setup <x> <y> <z> <facing>")
      return
    end
    facing = gpsFacing(home)
    if not facing then
      print("GPS works, but I need a free block in front of or behind me (and a little fuel)")
      print("to find my facing. Or: lava setup <x> <y> <z> <facing>")
      return
    end
  end
  local old = loadTable(CFG_FILE) or {}
  saveTable(CFG_FILE, { home = home, facing = facing, drops = old.drops or {}, pool = old.pool, exit = old.exit })
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
  A.replaceBytes("startup.lua", 'shell.run("lava")\n', function(s) return load(s) ~= nil end)
  os.setComputerLabel(os.getComputerLabel() or "Lava Runner")
  print("Home " .. home.x .. " " .. home.y .. " " .. home.z .. ", facing " .. DIRNAME[facing] .. ".")
  args = { "scan", "setup" } -- go on below: look for cauldrons
end

if not turtle then error("lava.lua runs on a turtle", 0) end
local cfg = loadTable(CFG_FILE)
if not cfg then
  print("Not set up yet. First: lava setup <x> <y> <z> <facing>")
  print("(or just lava setup, with GPS)")
  return
end
cfg.drops = cfg.drops or {}
cfg.cauldrons = cfg.cauldrons or {}
local HOME, FACING = cfg.home, cfg.facing
local BACK = OPP[FACING]
local function saveCfg() saveTable(CFG_FILE, cfg) end
local function where(p) return p.x .. " " .. p.y .. " " .. p.z end

if args[1] == "add" then
  local name = args[2]
  local p, want
  if name and args[3] == "here" then
    p = gpsHere()
    if not p then print("No GPS: give the chest's x y z instead") return end
    p.y = p.y - 1 -- the chest is under the turtle
    want = tonumber(args[4])
  elseif name then
    p = coords(args[3], args[4], args[5])
    want = tonumber(args[6])
  end
  if not p then
    print("Usage: lava add <name> <x> <y> <z> [buckets]")
    print("   or: lava add <name> here [buckets]   (turtle on the chest, GPS)")
    return
  end
  for i = #cfg.drops, 1, -1 do
    if cfg.drops[i].name:lower() == name:lower() then table.remove(cfg.drops, i) end
  end
  p.name, p.want = name, math.max(1, math.floor(want or WANT))
  cfg.drops[#cfg.drops + 1] = p
  saveCfg()
  print("Drop-off " .. name .. ": chest at " .. where(p) .. ", kept at " .. p.want .. " lava buckets.")
  print("Keep the block above that chest free.")
  if args[3] == "here" then print("Now put me back on my home spot (with GPS I fly home by myself).") end
  return
elseif args[1] == "remove" then
  local n = #cfg.drops
  for i = #cfg.drops, 1, -1 do
    if cfg.drops[i].name:lower() == tostring(args[2]):lower() then table.remove(cfg.drops, i) end
  end
  saveCfg()
  print(n > #cfg.drops and ("Forgot " .. args[2] .. ".") or ("No drop-off called " .. tostring(args[2])))
  return
elseif args[1] == "pool" or args[1] == "exit" then
  local key = args[1]
  if args[2] == "off" then
    cfg[key] = nil
  else
    local p = coords(args[2], args[3], args[4])
    if not p then print("Usage: lava " .. key .. " <x> <y> <z>   or   lava " .. key .. " off") return end
    cfg[key] = p
  end
  saveCfg()
  if key == "pool" then
    -- a new pool: start from its middle again
    local s0 = loadTable(STATE_FILE)
    if s0 then s0.poolCursor, s0.poolDry, s0.poolT = nil, nil, nil saveTable(STATE_FILE, s0) end
  end
  print(cfg[key] and (key .. " set to " .. where(cfg[key]) .. ".") or (key .. " off."))
  return
elseif args[1] == "list" then
  print("Home " .. where(HOME) .. ", facing " .. DIRNAME[FACING])
  print("Cauldrons: " .. #cfg.cauldrons .. (#cfg.cauldrons == 0 and " (lava scan looks again)" or ""))
  print("Pool: " .. (cfg.pool and where(cfg.pool) or "none"))
  if cfg.exit then print("Exit: " .. where(cfg.exit)) end
  print("Drop-offs:" .. (#cfg.drops == 0 and " none (lava add)" or ""))
  for _, d in ipairs(cfg.drops) do print("  " .. d.name .. ": " .. where(d) .. ", keep " .. d.want) end
  return
end

---------------------------------------------------------------------------
-- State (survives reboot / chunk unload)
---------------------------------------------------------------------------
local st = loadTable(STATE_FILE) or {}
st.pos = st.pos or { x = HOME.x, y = HOME.y, z = HOME.z }
st.h = st.h or FACING
st.path = st.path or ""  -- the moves from home to here, without detours: the way back
st.drop = st.drop or {}  -- [name] = { lava =, t =, gave =, err = } from the last visit
st.collected = st.collected or 0
st.delivered = st.delivered or 0
local pos = st.pos

local function save() saveTable(STATE_FILE, st) end
local function now() return os.epoch("utc") end
local function at() return pos.x .. "," .. pos.y .. "," .. pos.z end
local function atHome() return pos.x == HOME.x and pos.y == HOME.y and pos.z == HOME.z end

if args[1] == "home" then
  st.pos = { x = HOME.x, y = HOME.y, z = HOME.z }
  st.h, st.path, st.lost, st.pending = FACING, "", nil, nil
  save()
  print("Position reset to the home spot (chest behind the turtle).")
  print("Start with: lava")
  return
end

-- The way home: every position on st.path and how far along the path it is. Coming
-- back to a position cuts the loop out, so the path is never longer than it needs to be.
local trail, trailAt = {}, {}
local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function rebuildTrail()
  trail, trailAt = {}, {}
  local x, y, z = HOME.x, HOME.y, HOME.z
  trail[key(x, y, z)], trailAt[0] = 0, key(x, y, z)
  for i = 1, #st.path do
    local d = tonumber(st.path:sub(i, i))
    x, y, z = x + DX[d], y + DY[d], z + DZ[d]
    trail[key(x, y, z)], trailAt[i] = i, key(x, y, z)
  end
  if x ~= pos.x or y ~= pos.y or z ~= pos.z then
    -- doesn't add up: forget it and fly home the direct way
    st.path, st.lost = "", not atHome() or nil
    trail, trailAt = { [key(HOME.x, HOME.y, HOME.z)] = 0 }, { [0] = key(HOME.x, HOME.y, HOME.z) }
  end
end

local function applyMove(d)
  pos.x, pos.y, pos.z = pos.x + DX[d], pos.y + DY[d], pos.z + DZ[d]
  if st.lost then
    if atHome() then st.lost, st.path = nil, "" rebuildTrail() end
    return
  end
  local k = key(pos.x, pos.y, pos.z)
  local back = trail[k]
  if back then
    for i = back + 1, #st.path do
      trail[trailAt[i]], trailAt[i] = nil, nil
    end
    st.path = st.path:sub(1, back)
  else
    st.path = st.path .. d
    trail[k], trailAt[#st.path] = #st.path, k
  end
end

if st.lost then st.path = "" else rebuildTrail() end

-- A reboot during a move: the fuel tells whether the move happened
if st.pending then
  local f = turtle.getFuelLevel()
  if f ~= "unlimited" and f < st.pending.fuel then applyMove(st.pending.d) end
  st.pending = nil
  save()
end

-- Carried somewhere by hand (or it lost count)? GPS knows better.
do
  local g = gpsHere()
  if g and (g.x ~= pos.x or g.y ~= pos.y or g.z ~= pos.z) then
    pos.x, pos.y, pos.z = g.x, g.y, g.z
    st.path, st.lost = "", not atHome() or nil
    rebuildTrail()
    st.h = gpsFacing(g) or st.h
    save()
  end
end

-- What the screen shows (drawn by the UI further down)
local ui = { status = "Starting", lastError = nil, draw = function() end }
local function setStatus(s)
  if s == ui.status then return end
  ui.status = s
  ui.draw()
end

-- Remember an error in lava.log (last 40 lines)
local function logError(msg)
  msg = tostring(msg)
  pcall(function()
    local lines = {}
    if fs.exists(LOG_FILE) then
      local h = fs.open(LOG_FILE, "r")
      for line in h.readAll():gmatch("[^\n]+") do lines[#lines + 1] = line end
      h.close()
    end
    ui.lastError = os.date("%H:%M") .. " " .. msg
    lines[#lines + 1] = os.date("%Y-%m-%d %H:%M") .. " " .. at() .. " " .. msg
    while #lines > 40 do table.remove(lines, 1) end
    local h = fs.open(LOG_FILE, "w")
    h.write(table.concat(lines, "\n") .. "\n")
    h.close()
  end)
end

---------------------------------------------------------------------------
-- Inventory
---------------------------------------------------------------------------
local function countItem(name)
  local n = 0
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == name then n = n + d.count end
  end
  return n
end

local function findItem(name)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == name then return s end
  end
  return nil
end

local function emptySlot()
  for s = 1, 16 do
    if turtle.getItemCount(s) == 0 then return s end
  end
  return nil
end

local function freeSlots()
  local n = 0
  for s = 1, 16 do
    if turtle.getItemCount(s) == 0 then n = n + 1 end
  end
  return n
end

local function inventoryNeedsService()
  local free = freeSlots()
  return free < MIN_FREE or (16 - free) / 16 >= FULLNESS_HIGH
end

-- A chest next to the turtle ("front" or "bottom") as a peripheral: its contents
local function chestList(side)
  local c = peripheral.wrap(side)
  if not (c and c.list) then return nil end
  local ok, l = pcall(c.list)
  if ok and type(l) == "table" then return l, c end
  return nil
end

local function count(list, name)
  local n = 0
  for _, it in pairs(list) do
    if it.name == name then n = n + it.count end
  end
  return n
end

-- Move chest slot 'slot' to slot 1, so suck() takes exactly that stack (as miner.lua does)
local function toFront(chest, side, list, slot)
  if slot == 1 then return true end
  if list[1] then
    local free
    for e = chest.size(), 2, -1 do
      if not list[e] then free = e break end
    end
    if not free then return false end
    if not pcall(chest.pushItems, side, 1, 64, free) then return false end
  end
  return (pcall(chest.pushItems, side, slot, 64, 1))
end

-- Where a taken item goes: empty buckets on the stack it has, else an empty slot
local function slotFor(name)
  if name == BUCKET then
    for s = 1, 16 do
      local d = turtle.getItemDetail(s)
      if d and d.name == BUCKET and d.count < 16 then return s end
    end
  end
  return emptySlot()
end

-- Take up to n items called 'name' from the chest in front ("front") or below ("bottom")
local function take(side, name, n)
  local suck, drop = turtle.suck, turtle.drop
  if side == "bottom" then suck, drop = turtle.suckDown, turtle.dropDown end
  local got = 0
  local list, chest = chestList(side)
  if list then
    for _ = 1, 32 do
      if got >= n or not list then break end
      local slot
      for sl, it in pairs(list) do
        if it.name == name and (not slot or sl < slot) then slot = sl end
      end
      local s = slotFor(name)
      if not slot or not s or not toFront(chest, side, list, slot) then break end
      turtle.select(s)
      local before = countItem(name)
      if not suck(n - got) then break end
      got = got + countItem(name) - before
      list = chestList(side)
    end
  else
    -- can't look inside: take stacks one by one and put back what isn't wanted
    local held = {}
    for _ = 1, 27 do
      if got >= n then break end
      local s = emptySlot()
      if not s then break end
      turtle.select(s)
      if not suck() then break end
      local d = turtle.getItemDetail(s)
      if d and d.name == name then got = got + d.count else held[#held + 1] = s end
    end
    for _, s in ipairs(held) do
      turtle.select(s)
      drop()
    end
  end
  turtle.select(1)
  return got
end

---------------------------------------------------------------------------
-- Fuel
---------------------------------------------------------------------------
local function fuel()
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return math.huge end
  return f
end

-- Burn carried lava buckets up to 'target', never past the fuel limit
local function burnLava(target)
  local limit = turtle.getFuelLimit()
  while fuel() < target and fuel() + 1000 <= limit do
    local s = findItem(LAVA)
    if not s then break end
    turtle.select(s)
    if not turtle.refuel(1) then break end
  end
  turtle.select(1)
  return fuel() >= target
end

local function dist(p) return math.abs(p.x - pos.x) + math.abs(p.y - pos.y) + math.abs(p.z - pos.z) end

-- Enough fuel to go 'extra' blocks more and still get home? Burns carried lava if needed.
local function fuelFor(extra)
  local need = math.max(wh2 and wh2.managed() and REFUEL_BELOW or 0,
    extra + math.max(#st.path, dist(HOME)) + 2 * HOP + FUEL_MARGIN)
  return fuel() >= need or burnLava(need)
end

---------------------------------------------------------------------------
-- Movement (it never digs, apart from plants in the way)
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

-- Blocks a turtle moves through: air, lava and water (never into a cauldron)
local function passable(info)
  if not info then return true end
  local n = info.name
  if n:find("cauldron") then return false end
  return n:find("lava") ~= nil or n == "minecraft:water" or n == "minecraft:bubble_column"
end

local SOFT = { "short_grass", "tall_grass", "fern", "flower", "dead_bush", "vine", "snow", "leaves", "sapling",
  "dandelion", "poppy", "tulip", "orchid", "allium", "bluet", "daisy", "cornflower", "lily_of_the_valley", "bush" }
local function isSoft(info)
  if info.name:find("pot") or info.name:find("block") then return false end -- flower pots, snow blocks
  if info.name == "minecraft:grass" then return true end -- short grass before 1.20.3
  for _, p in ipairs(SOFT) do
    if info.name:find(p, 1, true) then return true end
  end
  return false
end

local function dig(d)
  if d == UP then return turtle.digUp() elseif d == DOWN then return turtle.digDown() end
  face(d)
  return turtle.dig()
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

-- One step. False when something solid is in the way (or another turtle).
local function step(d)
  if ui.homeNow and not ui.homing then error("Called home", 0) end
  for _ = 1, RETRY do
    local info = inspect(d)
    if info and not passable(info) then
      if not (isSoft(info) and dig(d)) then return false end
    end
    if fuel() == 0 and not burnLava(1) then error("Out of fuel", 0) end
    if rawMove(d) then return true end
    sleep(0.5) -- a mob or a player in the way: wait for it to go
  end
  return false
end

-- Fly to x,y,z: up to 'hop' above the higher end first, then across (climbing over and
-- going around what is in the way), then straight down or up to y.
local function flyTo(tx, ty, tz, hop)
  local top = math.max(pos.y, ty)
  local cruise = top + (hop or HOP)
  local budget = 3 * (math.abs(tx - pos.x) + math.abs(tz - pos.z) + math.abs(ty - pos.y)) + 200
  local goal = tx .. "," .. ty .. "," .. tz
  while pos.x ~= tx or pos.z ~= tz do
    budget = budget - 1
    if budget < 0 then error("Can't find a way to " .. goal, 0) end
    local dx, dz = tx - pos.x, tz - pos.z
    local a = dx ~= 0 and (dx > 0 and 1 or 3) or nil
    local b = dz ~= 0 and (dz > 0 and 2 or 0) or nil
    if math.abs(dz) > math.abs(dx) then a, b = b, a end
    if (pos.y < cruise and step(UP)) or step(a) or (b and step(b)) then
      -- moved
    elseif pos.y < top + MAX_CLIMB and step(UP) then
      cruise = math.max(cruise, pos.y)
    elseif not (step((a + 1) % 4) or step((a + 3) % 4)) then
      error("Stuck on the way to " .. goal .. " at " .. at(), 0)
    end
  end
  while pos.y > ty do
    if not step(DOWN) then error("Something is in the way down to " .. goal .. " at " .. at(), 0) end
  end
  while pos.y < ty do
    if not step(UP) then error("Something is in the way up to " .. goal .. " at " .. at(), 0) end
  end
end

-- Home the way it came (that way is free), or straight there if it doesn't know it
local function goHome()
  if not atHome() then
    setStatus("Going home")
    ui.homing = true
    local ok, err = pcall(function()
      while not st.lost and #st.path > 0 do
        local d = OPP[tonumber(st.path:sub(-1))]
        local moved = false
        for _ = 1, 15 do
          if step(d) then moved = true break end
          sleep(2) -- another turtle in the way
        end
        if not moved then break end
      end
      if not atHome() then flyTo(HOME.x, HOME.y, HOME.z) end
    end)
    ui.homing = false
    if not ok then error(err, 0) end
  end
  face(FACING)
end

-- Leaving the base: through the exit spot, if there is one
local function leave()
  if cfg.exit and atHome() then
    setStatus("Leaving the base")
    flyTo(cfg.exit.x, cfg.exit.y, cfg.exit.z, 0)
  end
end

---------------------------------------------------------------------------
-- Lava
---------------------------------------------------------------------------
-- An empty bucket to use, with room for the full one it becomes
local function canScoop()
  if inventoryNeedsService() then return false end
  local s = findItem(BUCKET)
  return s ~= nil and (turtle.getItemCount(s) == 1 or emptySlot() ~= nil)
end

-- Use an empty bucket on the cauldron or lava in direction d
local function scoop(d)
  local s = findItem(BUCKET)
  if not s then return false end
  local before = countItem(LAVA)
  turtle.select(s)
  if d == UP then turtle.placeUp() elseif d == DOWN then turtle.placeDown() else face(d) turtle.place() end
  turtle.select(1)
  return countItem(LAVA) > before
end

local function isLavaSource(info)
  return info ~= nil and info.name == "minecraft:lava" and info.state ~= nil and info.state.level == 0
end

local function sideDir(side)
  if side == "l" then return (FACING + 3) % 4 elseif side == "r" then return (FACING + 1) % 4 end
  return FACING
end

-- Setup: cauldrons left and right of home and of the corridor in front of it, and in
-- front of its last block. The corridor ends at the first block without cauldrons.
local function scanFarm()
  local found = {}
  local function look(i, side)
    if isCauldron(inspect(sideDir(side))) then
      found[#found + 1] = { i = i, side = side }
      return true
    end
    return false
  end
  look(0, "l")
  look(0, "r")
  local i = 0
  while i < CORRIDOR_MAX do
    local info = inspect(FACING)
    if info and not passable(info) then
      look(i, "f")
      break
    end
    if not step(FACING) then break end
    i = i + 1
    local l, r = look(i, "l"), look(i, "r")
    if not (l or r) then break end
  end
  goHome()
  cfg.cauldrons = found
  saveCfg()
  return found
end

-- Walk along the cauldrons and fill buckets at the full ones
local function farmRound()
  local last = -1
  for _, c in ipairs(cfg.cauldrons) do last = math.max(last, c.i) end
  st.farmT = now()
  if last < 0 then return 0 end
  setStatus("Filling buckets at the cauldrons")
  local got, full = 0, 0
  for i = 0, last do
    if i > 0 and not step(FACING) then error("Something blocks the cauldron corridor at " .. at(), 0) end
    for _, c in ipairs(cfg.cauldrons) do
      if c.i == i then
        local d = sideDir(c.side)
        if (inspect(d) or {}).name == "minecraft:lava_cauldron" then
          full = full + 1
          if canScoop() and scoop(d) then got = got + 1 end
        end
      end
    end
    if not canScoop() then break end
  end
  st.farmFull, st.farmGot = full, got
  st.collected = st.collected + got
  save()
  goHome()
  return got
end

-- Square spiral around the pool point: { dx, dz } per column, the middle first
local SPIRAL = {}
do
  local x, z, dx, dz = 0, 0, 0, -1
  for _ = 1, (2 * POOL_RADIUS + 1) * (2 * POOL_RADIUS + 1) do
    SPIRAL[#SPIRAL + 1] = { x, z }
    if x == z or (x < 0 and x == -z) or (x > 0 and x == 1 - z) then dx, dz = -dz, dx end
    x, z = x + dx, z + dz
  end
end

-- Fly to the pool and scoop lava, column by column, until the buckets are full
local function poolTrip()
  local P = cfg.pool
  st.poolT = now()
  save()
  local y0 = P.y + 1 -- flies just above the surface
  if not fuelFor(2 * dist(P) + 200) then
    setStatus("Not enough fuel to get to the pool")
    return 0
  end
  leave()
  setStatus("Flying to the lava pool")
  flyTo(P.x, y0, P.z)
  local got = 0
  st.poolCursor = st.poolCursor or 1
  while canScoop() and fuelFor(50) do
    local cell = SPIRAL[st.poolCursor]
    if not cell then
      st.poolDry = true
      logError("The pool at " .. where(P) .. " is empty: give me a new one (lava pool x y z)")
      break
    end
    setStatus("Scooping lava at the pool (" .. got .. " so far)")
    local ok, err = pcall(flyTo, P.x + cell[1], y0, P.z + cell[2], 0)
    if not ok and (err == "Terminated" or err == "Called home" or err == "Out of fuel") then error(err, 0) end
    local done = true
    if ok then
      -- down the column, scooping every lava source on the way
      local depth = 0
      while true do
        local info = inspect(DOWN)
        if isLavaSource(info) then
          if not canScoop() then done = false break end
          if scoop(DOWN) then got = got + 1 end
        elseif info and not passable(info) then
          break
        end
        if depth >= POOL_DEPTH or not step(DOWN) then break end
        depth = depth + 1
      end
      while pos.y < y0 do
        if not step(UP) then error("Can't get back up out of the pool at " .. at(), 0) end
      end
    end
    if done then st.poolCursor = st.poolCursor + 1 end
    save()
  end
  st.collected = st.collected + got
  save()
  goHome()
  return got
end

-- Hovering over a drop-off chest: top it up with lava and take its empty buckets
local function serve(dp)
  if not isChest(inspect(DOWN)) then error("No chest under me at " .. at(), 0) end
  local list = chestList("bottom")
  local give = list and math.max(0, dp.want - count(list, LAVA)) or BLIND
  local gave = 0
  while gave < give do
    local s = findItem(LAVA)
    if not s then break end
    turtle.select(s)
    if not turtle.dropDown() then break end -- chest full
    gave = gave + 1
  end
  turtle.select(1)
  if list then
    local spare = count(list, BUCKET) - KEEP_EMPTY
    if spare > 0 then take("bottom", BUCKET, spare) end
    list = chestList("bottom")
  end
  st.drop[dp.name] = { lava = list and count(list, LAVA) or nil, t = now(), gave = gave }
  st.delivered = st.delivered + gave
  save()
  return gave
end

-- Delivery round: take lava from the home chest and visit every drop-off, nearest first
local function deliverRound()
  st.lastRound = now()
  save()
  face(BACK)
  local room = freeSlots() - (findItem(BUCKET) and 0 or 1) -- keep a slot for empty buckets
  if room > 0 then take("front", LAVA, room) end
  face(FACING)
  if countItem(LAVA) == 0 then return 0 end
  leave()
  local todo = {}
  for _, dp in ipairs(cfg.drops) do todo[#todo + 1] = dp end
  local gave = 0
  while #todo > 0 and countItem(LAVA) > 0 do
    local k = 1
    for i = 2, #todo do
      if dist(todo[i]) < dist(todo[k]) then k = i end
    end
    local dp = table.remove(todo, k)
    if not fuelFor(2 * dist(dp)) then
      logError("Not enough fuel for the drop-off " .. dp.name)
      break
    end
    setStatus("Bringing lava to " .. dp.name)
    local ok, res = pcall(function()
      flyTo(dp.x, dp.y + 1, dp.z)
      return serve(dp)
    end)
    if ok then
      gave = gave + res
    else
      if res == "Terminated" or res == "Called home" or res == "Out of fuel" then error(res, 0) end
      logError(dp.name .. ": " .. tostring(res))
      st.drop[dp.name] = { t = now(), err = tostring(res) }
      save()
    end
  end
  goHome()
  return gave
end

-- At home: own fuel, full buckets into the chest, a stack of empty buckets to carry
local function service()
  if wh2 and wh2.managed() then error("Fleet services blocked: lava journal has no shared service adapter", 0) end
  face(BACK)
  local ok, info = turtle.inspect()
  if not (ok and isChest(info)) then
    error("No chest behind me. Put me on my home spot, Ctrl+T, type: lava home", 0)
  end
  if fuel() < REFUEL_BELOW then
    setStatus("Refuelling with my own lava")
    burnLava(REFUEL_TO)
    while fuel() < REFUEL_TO and take("front", LAVA, 1) > 0 do burnLava(REFUEL_TO) end
  end
  -- everything but one stack of empty buckets goes in the chest
  local kept = false
  local full = false
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and not KEEP_ITEMS[d.name] and (d.name ~= BUCKET or kept) then
      turtle.select(s)
      if not turtle.drop() then full = true end
    elseif d then
      kept = true
    end
  end
  turtle.select(1)
  if full then logError("My home chest is full") end
  local have = countItem(BUCKET)
  if have < 16 then take("front", BUCKET, 16 - have) end
  local list = chestList("front")
  st.stock = list and count(list, LAVA) or nil
  st.spare = list and count(list, BUCKET) or nil
  face(FACING)
  save()
end

---------------------------------------------------------------------------
-- What to do next
---------------------------------------------------------------------------
local function due(t, minutes) return not t or now() - t >= minutes * 60000 end

local function nextJob()
  local force = ui.force or {}
  local empties = findItem(BUCKET) ~= nil
  if empties and #cfg.cauldrons > 0 and (force.farm or due(st.farmT, FARM_EVERY)) then return "farm" end
  if empties and cfg.pool and not st.poolDry
    and (force.pool or ((st.stock or 0) < POOL_BELOW and due(st.poolT, POOL_EVERY))) then return "pool" end
  if #cfg.drops > 0 and ((st.stock or 0) > 0 or countItem(LAVA) > 0)
    and (force.deliver or due(st.lastRound, ROUND_EVERY)) then return "deliver" end
  ui.force = nil
  return nil
end

local function minutesLeft(t, minutes)
  if not t then return 0 end
  return math.max(0, math.ceil((t + minutes * 60000 - now()) / 60000))
end

local function idleText()
  if findItem(BUCKET) == nil and (#cfg.cauldrons > 0 or cfg.pool) then return "No empty buckets: put some in my chest" end
  if #cfg.cauldrons == 0 and not cfg.pool and #cfg.drops == 0 then return "Nothing to do: see lava list" end
  local parts = {}
  if #cfg.cauldrons > 0 then parts[#parts + 1] = "cauldrons in " .. minutesLeft(st.farmT, FARM_EVERY) .. "m" end
  if #cfg.drops > 0 then
    if (st.stock or 0) == 0 then parts[#parts + 1] = "no lava to deliver"
    else parts[#parts + 1] = "round in " .. minutesLeft(st.lastRound, ROUND_EVERY) .. "m" end
  end
  return "Waiting: " .. table.concat(parts, ", ")
end

---------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------
local W, H = term.getSize()
local COLOR = term.isColour and term.isColour()
local function col(c, plain) if COLOR then return c end return plain or colors.white end

local function fmt(n)
  if n == nil then return "?" end
  if n == math.huge then return "unlimited" end
  if n >= 10000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end

local function row(y, text, fg, bg)
  term.setCursorPos(1, y)
  term.setBackgroundColor(bg or colors.black)
  term.setTextColor(fg or colors.white)
  term.clearLine()
  term.write(text:sub(1, W))
end

local function pair(y, l1, v1, l2, v2)
  term.setCursorPos(2, y)
  term.setBackgroundColor(colors.black)
  term.setTextColor(col(colors.lightGray))
  term.write(l1)
  term.setTextColor(colors.white)
  term.write(v1)
  if l2 then
    term.setCursorPos(math.floor(W / 2) + 2, y)
    term.setTextColor(col(colors.lightGray))
    term.write(l2)
    term.setTextColor(colors.white)
    term.write(v2)
  end
end

local function state()
  if st.paused then return atHome() and "PAUSED" or "PAUSING", col(colors.yellow) end
  if ui.homeNow and not atHome() then return "COMING HOME", col(colors.orange) end
  return "RUNNING", col(colors.lime)
end

local function poolText()
  if not cfg.pool then return "none" end
  if st.poolDry then return "empty, set a new one" end
  return math.floor(((st.poolCursor or 1) - 1) * 100 / #SPIRAL) .. "% searched"
end

local function drawScreen()
  local name, stateColor = state()
  row(1, " LAVA RUNNER", colors.white, col(colors.red, colors.gray))
  term.setCursorPos(W - #name, 1)
  term.setTextColor(stateColor)
  term.write(name)
  row(2, "")
  -- status, over two lines if needed
  local text, w = ui.status, W - 2
  local cut = #text
  if #text > w then
    cut = w
    for i = w, math.floor(w / 2), -1 do
      if text:sub(i, i) == " " then cut = i break end
    end
  end
  row(3, " " .. text:sub(1, cut), col(colors.yellow))
  row(4, " " .. (text:sub(cut + 1):gsub("^ ", "")), col(colors.yellow))
  -- fuel bar
  local f = fuel()
  row(5, "")
  term.setCursorPos(2, 5)
  term.setTextColor(col(colors.lightGray))
  term.write("Fuel ")
  local barW = W - 15
  local frac = f == math.huge and 1 or math.min(1, f / REFUEL_TO)
  local fill = math.floor(barW * frac + 0.5)
  term.setBackgroundColor(f < 500 and col(colors.red) or f < REFUEL_BELOW and col(colors.orange) or col(colors.lime))
  term.write(string.rep(" ", fill))
  term.setBackgroundColor(col(colors.gray, colors.gray))
  term.write(string.rep(" ", barW - fill))
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.write(" " .. fmt(f))
  row(6, "")
  row(7, "") pair(7, "Stock   ", fmt(st.stock) .. " lava", "Empty    ", fmt(st.spare) .. " + " .. countItem(BUCKET))
  row(8, "") pair(8, "Farm    ", #cfg.cauldrons .. " cauldrons", "Pool     ", poolText())
  row(9, "") pair(9, "Got     ", fmt(st.collected), "Delivered ", fmt(st.delivered))
  local drops = {}
  for _, dp in ipairs(cfg.drops) do
    local i = st.drop[dp.name] or {}
    drops[#drops + 1] = dp.name .. " " .. (i.err and "!" or ((i.lava and tostring(i.lava) or "?") .. "/" .. dp.want))
  end
  row(10, "") pair(10, "Drops   ", #drops > 0 and table.concat(drops, ", ") or "none (lava add)")
  if ui.lastError then row(11, " ! " .. ui.lastError, col(colors.red)) else row(11, "") end
  for y = 12, H - 1 do row(y, "") end
  local keys = st.paused and " [P] go on  [Q] quit" or " [P] pause [R] run now [H] home [Q] quit"
  if ui.quitAsk then keys = " Press Q again to quit, any key: no" end
  row(H, keys, colors.white, col(colors.gray, colors.gray))
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
          print("Lava runner stopped. Type lava to start it again.")
          return
        end
      elseif a == keys.p then
        st.paused = not st.paused
        save()
      elseif a == keys.r then
        ui.force = { farm = true, pool = true, deliver = true }
      elseif a == keys.h then
        ui.homeNow = true
      elseif a == keys.q then
        ui.quitAsk = true
      end
      ui.draw()
    elseif ev == "term_resize" then
      W, H = term.getSize()
      ui.draw()
    end
  end
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------
local function job(name)
  if ui.force then ui.force[name] = nil end
  if name == "farm" then farmRound() elseif name == "pool" then poolTrip() else deliverRound() end
end

-- Back home after a reboot or an error; keeps trying
local function recover()
  while true do
    local ok, err = pcall(goHome)
    if ok then break end
    if err == "Terminated" then error(err, 0) end
    logError(err)
    setStatus("STUCK: " .. tostring(err))
    sleep(30)
  end
  ui.homeNow = false
end

local function worker()
  recover()
  while true do
    local ok, err = pcall(service)
    if ok then ui.homeNow = false end
    if not ok then
      if err == "Terminated" then error(err, 0) end
      logError(err)
      setStatus(tostring(err))
      sleep(30)
    elseif ui.updateNow then
      -- panel's Update all: fetch the latest lava.lua now that it's home (reboots if new)
      ui.updateNow = false
      setStatus("Updating from GitHub")
      shell.run(shell.getRunningProgram(), "update") -- fetches update.lua too if it is missing
    elseif st.paused then
      setStatus("Paused at home. Press P to go on")
      while st.paused do sleep(1) end
    elseif fuel() < MIN_FUEL then
      setStatus("Out of fuel: put lava buckets in my chest")
      sleep(30)
    else
      local j = nextJob()
      if j then
        local ok2, err2 = pcall(job, j)
        if not ok2 then
          if err2 == "Terminated" then error(err2, 0) end
          if err2 ~= "Called home" then
            logError(err2)
            setStatus("Error: " .. tostring(err2))
          end
        end
        recover()
      else
        setStatus(idleText())
        for _ = 1, WAIT do
          if st.paused or ui.force or ui.updateNow then break end
          sleep(1)
        end
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

local function stateMsg(rid)
  local drops = {}
  for _, dp in ipairs(cfg.drops) do
    local i = st.drop[dp.name] or {}
    drops[#drops + 1] = { name = dp.name, want = dp.want, lava = i.lava, err = i.err,
      age = i.t and math.floor((now() - i.t) / 1000) or nil }
  end
  local name = state()
  return { type = "lava_state", rid = rid, label = os.getComputerLabel(), state = name, status = ui.status,
    fuel = fuel(), fuelMax = REFUEL_TO, stock = st.stock, spare = st.spare, carry = countItem(LAVA),
    empties = countItem(BUCKET), cauldrons = #cfg.cauldrons, farmFull = st.farmFull, pool = cfg.pool and poolText() or nil,
    drops = drops, collected = st.collected, delivered = st.delivered, paused = st.paused, err = ui.lastError,
    gps = { x = pos.x, y = pos.y, z = pos.z }, -- world coordinates since setup
    home = atHome(), nextRound = #cfg.drops > 0 and minutesLeft(st.lastRound, ROUND_EVERY) or nil }
end

-- Pocket control panel (panel.lua): status, pause / run now / come home, Update all.
-- Without a modem this just waits forever.
local function radio()
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then while true do os.pullEvent("lava_never") end end
  rednet.open(peripheral.getName(modem))
  rednet.host(PROTOCOL, os.getComputerLabel() or ("lava" .. os.getComputerID()))
  while true do
    local id, m = rednet.receive(PROTOCOL)
    if type(m) == "table" and m.type == "dev" then
      devCommand(m, LOG_FILE, "lava", function(r) rednet.send(id, r, PROTOCOL) end, NO_DRIVE)
    elseif type(m) == "table" then
      if m.cmd == "pause" then st.paused = true save()
      elseif m.cmd == "resume" then st.paused = false save()
      elseif m.cmd == "home" then ui.homeNow = true
      elseif m.cmd == "run" then ui.force = { farm = true, pool = true, deliver = true }
      elseif m.cmd == "deliver" then ui.force = { deliver = true }
      elseif m.cmd == "update" then ui.updateNow, ui.homeNow = true, true end
      if m.cmd then ui.draw() end
      rednet.send(id, stateMsg(m.rid), PROTOCOL)
    end
  end
end

if args[1] == "scan" then
  if not atHome() then print("I'm not on my home spot. Put me there and type: lava home") return end
  local ok, found = pcall(scanFarm)
  if not ok then
    print("Couldn't look along the corridor: " .. tostring(found))
    print("Give me a little fuel (a lava bucket) and type: lava scan")
    return
  end
  local corridor = 0
  for _, c in ipairs(found) do corridor = math.max(corridor, c.i) end
  print("Found " .. #found .. " cauldron" .. (#found == 1 and "" or "s")
    .. (#found > 0 and (" (corridor " .. corridor .. " blocks long)") or "") .. ".")
  if args[2] == "setup" then
    print("Next: lava add <name> <x> <y> <z> for each chest to keep stocked,")
    print("lava pool <x> <y> <z> for a lava pool (optional), then: lava")
  end
  return
end

turtle.select(1)
term.clear()
parallel.waitForAny(worker, screen, radio, devPairLoop)
