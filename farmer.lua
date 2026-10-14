-- farmer.lua - crop farming turtle (CC: Tweaked)
--
-- Put a turtle on the ground at one corner of your field, at the height of the crops,
-- with a chest behind it (it turns to find it and calls that side "behind"). The field
-- lies in front of it: the first row is right in front, the rows go away from the chest.
-- It flies one block above the crops, harvests what is ripe and replants it, and puts
-- the harvest in that chest, or brings it to another chest (the storage room's input).
--
-- Crops: wheat, carrots, potatoes, beetroot, nether wart (and most modded crops: it
-- learns their seed from what they drop), melons and pumpkins (it picks the fruit and
-- leaves the stems), sugar cane and bamboo (it cuts all but the bottom block).
-- Any turtle tool can harvest; with a hoe it also tills dirt that dried out.
--
-- One-time setup:
--   farmer setup <length> <width> [left]  field size in blocks; it lies to the right of
--                                         the turtle's column, or to the left with "left"
-- Then:
--   farmer          run (started automatically on boot after setup). The screen shows what
--                   it does; keys: P pause / go on, H come home, N harvest now, Q quit.
--   farmer drop <forward> <right> <up>    bring the harvest to a chest somewhere else (the
--                   storage room's input chest), counted from the turtle's home spot facing
--                   the field. It flies over to it and comes down onto it from above, so
--                   that chest needs open sky (or at least a free shaft) above it.
--   farmer drop off  harvest into the chest behind it again
--   farmer seed <crop>  what to plant on empty farmland it knows nothing about (a new
--                   field): wheat, carrot, potato, beetroot, netherwart or an item name
--   farmer home     after putting it back on its home spot by hand: reset position
--   farmer reset    forget what grows where
--
-- Fuel: lava buckets or coal in a chest UNDER the turtle (best when the chest behind it
-- is the storage room's input, which would eat them), or in the chest behind it.

local CFG_FILE, STATE_FILE, LOG_FILE = "farmer.cfg", "farmer.state", "farmer.log"

local FLY = 1              -- flies this high above its home spot (one block above the crops)
local HOP = 4              -- on the way to the drop chest: this many blocks above the highest point
local WAIT = 600           -- seconds between two rounds over the field...
local WAIT_IDLE = 1500     -- ...or this long when the last round found nothing ripe
local KEEP_SEEDS = 64      -- seeds (and potatoes, carrots...) of each kind it keeps for replanting
local MIN_FREE = 2         -- go and unload when fewer slots than this are free
local FUEL_MARGIN = 30
local REFUEL_BELOW = 2000  -- at home, top up from the fuel chest when below this...
local REFUEL_TO = 3000     -- ...to about this (a lava bucket is 1000)
local MIN_FUEL = 200       -- below this it waits at home for fuel
local RETRY = 20

-- Directions relative to the home spot:
-- 0 = forward (the field), 1 = right, 2 = back (chest), 3 = left, 4 = up, 5 = down
local UP, DOWN = 4, 5
local DF = { [0] = 1, 0, -1, 0, 0, 0 }
local DS = { [0] = 0, 1, 0, -1, 0, 0 }
local DY = { [0] = 0, 0, 0, 0, 1, -1 }

local args = { ... }
if args[1] == "update" then
  -- latest version from GitHub (update.lua does the work, fetched here if missing)
  if not fs.exists("update.lua") then
    shell.run("wget", "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/update.lua", "update.lua")
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

local function hasTag(info, t) return info and info.tags and info.tags[t] end

local function isChest(info)
  if not info then return false end
  if info.name:find("chest") or info.name:find("barrel") then return true end
  return hasTag(info, "c:chests") or hasTag(info, "forge:chests") or hasTag(info, "c:barrels")
end

-- What it plants for each crop block
local SEED = {
  ["minecraft:wheat"] = "minecraft:wheat_seeds", ["minecraft:carrots"] = "minecraft:carrot",
  ["minecraft:potatoes"] = "minecraft:potato", ["minecraft:beetroots"] = "minecraft:beetroot_seeds",
  ["minecraft:nether_wart"] = "minecraft:nether_wart",
}
-- Fully grown at this age (other crops: 7)
local MAX_AGE = { ["minecraft:beetroots"] = 3, ["minecraft:nether_wart"] = 3 }
local SEED_NAMES = {
  wheat = "minecraft:wheat_seeds", seeds = "minecraft:wheat_seeds", carrot = "minecraft:carrot",
  carrots = "minecraft:carrot", potato = "minecraft:potato", potatoes = "minecraft:potato",
  beetroot = "minecraft:beetroot_seeds", beetroots = "minecraft:beetroot_seeds",
  netherwart = "minecraft:nether_wart", wart = "minecraft:nether_wart",
}

---------------------------------------------------------------------------
-- Setup and commands
---------------------------------------------------------------------------
if args[1] == "setup" then
  local len, wid = tonumber(args[2] or ""), tonumber(args[3] or "")
  if not len or not wid or len < 1 or wid < 1 or len * wid > 4096 then
    print("Usage: farmer setup <length> <width> [left]")
    print("  length: rows in front of the turtle")
    print("  width:  blocks per row, from the turtle's column to the right (or left)")
    return
  end
  if turtle then
    -- turn until the chest is behind it (the chest may be on any side)
    local found = false
    for _ = 1, 4 do
      turtle.turnLeft() turtle.turnLeft()
      local ok, info = turtle.inspect()
      turtle.turnLeft() turtle.turnLeft()
      if ok and isChest(info) then found = true break end
      turtle.turnRight()
    end
    if not found then print("WARNING: no chest found next to the turtle!") end
  end
  local old = loadTable(CFG_FILE) or {}
  saveTable(CFG_FILE, { length = math.floor(len), width = math.floor(wid), left = args[4] == "left",
    drop = old.drop, seed = old.seed })
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("farmer")\n')
  h.close()
  os.setComputerLabel(os.getComputerLabel() or "Farmer")
  print("Saved: a field of " .. math.floor(len) .. " x " .. math.floor(wid) .. " to the "
    .. (args[4] == "left" and "left" or "right") .. ", in front of the turtle.")
  print("Start with: farmer   (or reboot the turtle)")
  return
end

local cfg = loadTable(CFG_FILE)
if not cfg then
  print("Not set up yet. First: farmer setup <length> <width> [left]")
  return
end

if args[1] == "drop" then
  if args[2] == "off" then
    cfg.drop = nil
    print("The harvest goes in the chest behind the turtle again.")
  else
    local f, s, y = tonumber(args[2] or ""), tonumber(args[3] or ""), tonumber(args[4] or "")
    if not f or not s or not y then
      print("Usage: farmer drop <forward> <right> <up>   (or: farmer drop off)")
      print("Where the chest is, from the turtle's home spot looking at the field.")
      print("Left, back and down are negative numbers.")
      return
    end
    cfg.drop = { f = math.floor(f), s = math.floor(s), y = math.floor(y) }
    print("The harvest goes to the chest at " .. f .. " forward, " .. s .. " right, " .. y .. " up.")
    print("It lands on top of it, so keep the space above that chest free.")
  end
  saveTable(CFG_FILE, cfg)
  return
end

if args[1] == "seed" then
  local w = (args[2] or ""):lower()
  if w == "" or w == "off" then
    cfg.seed = nil
    print("Empty farmland it knows nothing about stays empty.")
  else
    cfg.seed = SEED_NAMES[w] or (w:find(":") and w) or ("minecraft:" .. w)
    print("Empty farmland gets " .. cfg.seed .. " (put some in the turtle).")
  end
  saveTable(CFG_FILE, cfg)
  return
end

if args[1] == "home" or args[1] == "reset" then
  local s0 = loadTable(STATE_FILE) or {}
  if args[1] == "home" then
    s0.pos = { f = 0, s = 0, y = 0 }
    s0.h = 0
    s0.pending, s0.away = nil, nil
    print("Position reset to the home spot (chest behind the turtle).")
  else
    s0.cells, s0.bad, s0.cursor = {}, {}, 1
    print("Forgot what grows where. It learns it again on the next round.")
  end
  saveTable(STATE_FILE, s0)
  print("Start with: farmer")
  return
end

if not turtle then error("farmer.lua only runs on a turtle", 0) end

-- The field, row by row, back and forth (snake order)
local SIDE = cfg.left and -1 or 1
local CELLS = {}
for f = 1, cfg.length do
  for i = 0, cfg.width - 1 do
    local j = (f % 2 == 1) and i or (cfg.width - 1 - i)
    CELLS[#CELLS + 1] = { f, j * SIDE }
  end
end
local function inField(f, s)
  return f >= 1 and f <= cfg.length and s * SIDE >= 0 and s * SIDE < cfg.width
end

---------------------------------------------------------------------------
-- State (survives reboot / chunk unload)
---------------------------------------------------------------------------
local st = loadTable(STATE_FILE) or {}
st.pos = st.pos or { f = 0, s = 0, y = 0 }
st.h = st.h or 0
st.cursor = st.cursor or 1   -- next cell of this round
st.cells = st.cells or {}    -- ["f,s"] = seed it plants there ("fruit": melon/pumpkin spot, plant nothing)
st.bad = st.bad or {}        -- ["f,s"] = true: nothing can be planted there
st.learned = st.learned or {} -- crop block = its seed, for crops not in SEED
st.crops = st.crops or {}    -- crop = how many it harvested, all time
st.items = st.items or 0     -- items delivered, all time
st.rounds = st.rounds or 0   -- rounds over the whole field, all time
st.got = st.got or 0         -- crops harvested in this round
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

-- What the screen shows (drawn by the UI further down)
local ui = { status = "Starting", homeNow = false, lastError = nil, draw = function() end }
local function setStatus(s)
  if s == ui.status then return end
  ui.status = s
  ui.draw()
end

local function at() return pos.f .. "," .. pos.s .. "," .. pos.y end

-- Remember an error in farmer.log (last 40 lines)
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
-- Blocks and items
---------------------------------------------------------------------------
local function isTall(info)
  return info ~= nil and (info.name == "minecraft:sugar_cane" or info.name == "minecraft:bamboo")
end
local function isFruit(info)
  if not info or info.name:find("stem") or info.name:find("carved") then return false end
  return info.name:find("melon$") ~= nil or info.name:find("pumpkin$") ~= nil
end
local function isCrop(info)
  if not info or info.name:find("stem") or not info.state or type(info.state.age) ~= "number" then return false end
  return SEED[info.name] ~= nil or hasTag(info, "minecraft:crops") or st.learned[info.name] ~= nil
end
local function isRipe(info) return info.state.age >= (MAX_AGE[info.name] or 7) end

-- air, ripe, growing, fruit, tall (bottom of sugar cane / bamboo: stays), other
local function kind(info)
  if not info then return "air" end
  if isCrop(info) then return isRipe(info) and "ripe" or "growing" end
  if isFruit(info) then return "fruit" end
  if isTall(info) then return "tall" end
  return "other"
end

local function seedFor(blockName) return SEED[blockName] or st.learned[blockName] end

local function pretty(name)
  local s = (tostring(name):match(":(.+)$") or tostring(name)):gsub("_", " ")
  return s:sub(1, 1):upper() .. s:sub(2)
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

local function counts()
  local t = {}
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d then t[d.name] = (t[d.name] or 0) + d.count end
  end
  return t
end

-- Seeds it knows (planted somewhere on the field, or the setup seed)
local function seedKinds()
  local t = {}
  for _, v in pairs(st.cells) do if v ~= "fruit" then t[v] = true end end
  for _, v in pairs(SEED) do t[v] = true end
  for _, v in pairs(st.learned) do t[v] = true end
  if cfg.seed then t[cfg.seed] = true end
  return t
end

---------------------------------------------------------------------------
-- Fuel
---------------------------------------------------------------------------
local function fuel()
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return math.huge end
  return f
end

-- Fuel it may burn: lava buckets and coal. Never its harvest.
local FUEL_VALUE = {
  ["minecraft:lava_bucket"] = 1000, ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80,
  ["minecraft:coal_block"] = 800,
}
local function isFuelItem(d) return FUEL_VALUE[d.name] ~= nil end

-- Burn fuel items from the inventory up to 'target', without wasting any over the limit
local function burn(target)
  if fuel() >= target then return true end
  local limit = turtle.getFuelLimit()
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and isFuelItem(d) then
      turtle.select(s)
      while fuel() < target and turtle.getItemCount(s) > 0
        and fuel() + FUEL_VALUE[d.name] <= limit do
        if not turtle.refuel(1) then break end
      end
    end
    if fuel() >= target then break end
  end
  turtle.select(1)
  return fuel() >= target
end

-- Fuel to get home from here
local function homeCost()
  return math.abs(pos.f) + math.abs(pos.s) + math.abs(pos.y) + 2 * HOP + 10
end

-- Enough fuel to do 'extra' more and still get home? Burns carried fuel if needed.
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

local function dig(d)
  if d == UP then return turtle.digUp()
  elseif d == DOWN then return turtle.digDown() end
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

-- Sugar cane / bamboo in the way: cut it. The part above falls as items: pick them up.
local function cutTall(d)
  dig(d)
  for _ = 1, 3 do
    sleep(0.2)
    if d == UP then turtle.suckUp() elseif d == DOWN then turtle.suckDown() else turtle.suck() end
  end
end

-- One step. Cuts sugar cane and bamboo in the way (never the bottom block of it on the
-- field: it flies above that). False when something else is in the way.
local function step(d)
  for attempt = 1, RETRY do
    local info = inspect(d)
    if isTall(info) then
      cutTall(d)
      local k = pretty(info.name)
      st.crops[k] = (st.crops[k] or 0) + 1
      st.got = st.got + 1
    elseif info and info.name ~= "minecraft:water" then
      return false
    end
    if fuel() == 0 and not burn(1) then error("Out of fuel", 0) end
    if rawMove(d) then return true end
    -- A mob or player in the way: wait first, hit it only if it doesn't go away
    if attempt > 5 and inspect(d) == nil then
      if d == UP then turtle.attackUp() elseif d == DOWN then turtle.attackDown() else turtle.attack() end
    end
    sleep(0.5)
  end
  return false
end

-- Up to height y. Something above it: slide sideways and retry.
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

-- Over the field, one block above the crops. Goes over a lamp or a scarecrow in
-- the way and comes back down after it.
local function fieldStep(d)
  local tries = 0
  while not step(d) do
    tries = tries + 1
    if tries > 6 then error("Something big blocks the field at " .. at(), 0) end
    rise(pos.y + 1)
  end
  while pos.y > FLY do
    local below = inspect(DOWN)
    if below and not isTall(below) then break end
    if not step(DOWN) then break end
  end
end

-- To a cell of the field (or its home column 0,0), staying over the field
local function travel(tf, ts)
  if pos.y < FLY then rise(FLY) end
  if pos.f == 0 and pos.s == 0 and tf > 0 then fieldStep(0) end
  while pos.f ~= tf do fieldStep(pos.f < tf and 0 or 2) end
  while pos.s ~= ts do fieldStep(pos.s < ts and 1 or 3) end
end

local function goHome()
  if pos.f == 0 and pos.s == 0 and pos.y == 0 then return end
  setStatus("Going home")
  if st.away or not inField(pos.f, pos.s) and not (pos.f == 0 and pos.s == 0) then
    -- out on a delivery (or somewhere odd): fly back over everything
    flyTo(0, 0, math.max(pos.y, FLY + HOP))
  else
    if pos.f ~= 0 or pos.s ~= 0 then
      travel(1, 0)
      fieldStep(2)
    end
  end
  while pos.y > 0 do
    if not step(DOWN) then error("Something blocks the way down to my chest at " .. at(), 0) end
  end
  if pos.y < 0 then rise(0) end
  st.away = nil
  save()
end

---------------------------------------------------------------------------
-- Harvesting and planting
---------------------------------------------------------------------------
local hoe = nil -- true: it has a hoe and may till dirt
local function hasHoe()
  if hoe ~= nil then return hoe end
  hoe = false
  -- (older CC: Tweaked versions can't tell; then it never tills)
  for _, side in ipairs({ "getEquippedLeft", "getEquippedRight" }) do
    local ok, d = pcall(turtle[side] or error)
    if ok and type(d) == "table" and d.name and d.name:find("hoe") then hoe = true end
  end
  return hoe
end

local function plantBelow(seed)
  local s = findSlot(function(d) return d.name == seed end)
  if not s then return false, "no seed" end
  turtle.select(s)
  local ok = turtle.placeDown()
  turtle.select(1)
  return ok
end

-- Dirt that lost its farmland: go down and till it (needs a hoe), back up, plant
local function tillAndPlant(seed)
  if not hasHoe() or st.noTill then return false end
  if not step(DOWN) then return false end
  local below = inspect(DOWN)
  local tilled = false
  if below and (below.name == "minecraft:dirt" or below.name:find("grass_block")) then
    turtle.digDown()
    local after = inspect(DOWN)
    if after and after.name:find("farmland") then
      tilled = true
    elseif not after then
      -- that tool dug the dirt out instead of tilling it: put it back, don't try again
      local s = findSlot(function(d) return d.name == below.name or d.name == "minecraft:dirt" end)
      if s then turtle.select(s) turtle.placeDown() turtle.select(1) end
      st.noTill = true
      save()
    end
  end
  step(UP)
  return tilled and plantBelow(seed)
end

-- Seed of a cell next to this one (rows usually hold one crop)
local function neighbourSeed(f, s)
  for _, o in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
    local v = st.cells[(f + o[1]) .. "," .. (s + o[2])]
    if v and v ~= "fruit" then return v end
  end
  return nil
end

-- Pick a ripe crop below and plant the same again
local function harvest(info, k)
  local before = counts()
  turtle.digDown()
  local seed = seedFor(info.name)
  if not seed then
    -- a crop it doesn't know: its seed is what it dropped (preferably something called seed)
    local best
    for name, n in pairs(counts()) do
      if n > (before[name] or 0) and (not best or name:find("seed")) then best = name end
    end
    if best then st.learned[info.name], seed = best, best end
  end
  local key = pretty(info.name)
  st.crops[key] = (st.crops[key] or 0) + 1
  st.got = st.got + 1
  if seed then
    st.cells[k] = seed
    if not plantBelow(seed) then setStatus("No " .. pretty(seed) .. " left to replant") end
  end
end

-- Everything the turtle does above one cell
local function tend(f, s)
  local k = f .. "," .. s
  local info = inspect(DOWN)
  local c = kind(info)
  if c == "ripe" then
    harvest(info, k)
  elseif c == "growing" then
    local seed = seedFor(info.name)
    if seed and st.cells[k] ~= seed then st.cells[k] = seed save() end
  elseif c == "fruit" then
    turtle.digDown()
    local key = pretty(info.name)
    st.crops[key] = (st.crops[key] or 0) + 1
    st.got = st.got + 1
    st.cells[k] = "fruit"
  elseif c == "air" and not st.bad[k] and st.cells[k] ~= "fruit" then
    local seed = st.cells[k] or neighbourSeed(f, s) or cfg.seed
    if seed then
      local ok, why = plantBelow(seed)
      if not ok and why ~= "no seed" then ok = tillAndPlant(seed) end
      if ok then
        st.cells[k] = seed
      elseif why ~= "no seed" and not st.cells[k] then
        st.bad[k] = true -- a path, a torch spot: nothing grows here
      end
    end
  end
end

---------------------------------------------------------------------------
-- A round over the field
---------------------------------------------------------------------------
-- Returns why it stopped: "full", "fuel", "stop" or nil (the round is done)
local function round()
  setStatus("Looking after the field (" .. (st.cursor - 1) .. "/" .. #CELLS .. ")")
  while st.cursor <= #CELLS do
    if st.paused or ui.homeNow then return "stop" end
    if freeSlots() < MIN_FREE then return "full" end
    local cell = CELLS[st.cursor]
    if not fuelFor(math.abs(cell[1] - pos.f) + math.abs(cell[2] - pos.s) + 4) then return "fuel" end
    travel(cell[1], cell[2])
    tend(cell[1], cell[2])
    st.cursor = st.cursor + 1
    save()
    if st.cursor % 8 == 0 then setStatus("Looking after the field (" .. (st.cursor - 1) .. "/" .. #CELLS .. ")") end
  end
  st.cursor = 1
  st.rounds = st.rounds + 1
  -- next round once the crops had time to grow (kept over a reboot or chunk unload)
  st.nextAt = now() + ((st.got > 0) and WAIT or WAIT_IDLE) * 1000
  st.got = 0
  save()
  return nil
end

---------------------------------------------------------------------------
-- Home: chest, fuel, delivering the harvest
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

local function emptySlot()
  for e = 1, 16 do if turtle.getItemCount(e) == 0 then return e end end
  return nil
end

-- Lava buckets in the chests at home (nil: no chest it can look into)
local lavaLeft = nil
local function countLava()
  local total, seen = 0, false
  for _, side in ipairs({ "bottom", "front" }) do
    pcall(function()
      local c = peripheral.wrap(side)
      if not c or not c.list then return end
      seen = true
      for _, it in pairs(c.list()) do
        if it.name == "minecraft:lava_bucket" then total = total + it.count end
      end
    end)
  end
  lavaLeft = seen and total or nil
end

local function wantFuel()
  return fuel() < REFUEL_BELOW or fuel() + 1000 <= REFUEL_TO
end

-- Chest in front: move a fuel item into its first slot, so the next suck takes
-- exactly that. False if there is none (or no peripheral access).
local function fuelToFirstSlot()
  local ok, res = pcall(function()
    local c = peripheral.wrap("front")
    if not c or not c.list then return false end
    local list = c.list()
    if list[1] and FUEL_VALUE[list[1].name] then return true end
    local from
    for slot, it in pairs(list) do
      if FUEL_VALUE[it.name] and (not from or slot < from) then from = slot end
    end
    if not from then return false end
    if list[1] then
      local free
      for e = c.size(), 2, -1 do if not list[e] then free = e break end end
      if not free then return false end
      c.pushItems(peripheral.getName(c), 1, 64, free)
    end
    return c.pushItems(peripheral.getName(c), from, 1, 1) > 0
  end)
  return ok and res
end

-- At home: top up with lava buckets (or coal). First from a chest under the turtle,
-- then from the chest behind it (only when it can see which slot holds fuel, so it
-- never pulls the harvest back out). Empty buckets go in the chest behind it.
local function refuelHome()
  burn(REFUEL_TO)
  if fuel() >= REFUEL_BELOW then return end
  local ok, info = turtle.inspectDown()
  if ok and isChest(info) then
    for _ = 1, 32 do
      if not wantFuel() then break end
      local s = emptySlot()
      if not s then break end
      turtle.select(s)
      if not turtle.suckDown(1) then break end
      burn(REFUEL_TO)
    end
  end
  face(2)
  for _ = 1, 32 do
    if not wantFuel() then break end
    local s = emptySlot()
    if not s or not fuelToFirstSlot() then break end
    turtle.select(s)
    if not turtle.suck(1) then break end
    burn(REFUEL_TO)
  end
  turtle.select(1)
end

-- Drop everything except seeds for replanting (KEEP_SEEDS of each kind) and fuel.
-- harvestOnly: also keep empty buckets (they go home, not to the storage room).
local function unload(dropFn, harvestOnly)
  local kept, seeds = {}, seedKinds()
  local ok = true
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d then
      local keep = 0
      if isFuelItem(d) or (harvestOnly and d.name == "minecraft:bucket") then keep = d.count
      elseif seeds[d.name] then
        keep = math.min(d.count, math.max(0, KEEP_SEEDS - (kept[d.name] or 0)))
        kept[d.name] = (kept[d.name] or 0) + keep
      end
      if d.count > keep then
        turtle.select(s)
        if dropFn(d.count - keep) then
          if d.name ~= "minecraft:bucket" then st.items = st.items + d.count - turtle.getItemCount(s) - keep end
        else
          ok = false
        end
      end
    end
  end
  turtle.select(1)
  save()
  return ok
end

-- Anything worth bringing to the drop chest?
local function haveHarvest()
  local seeds, kept = seedKinds(), {}
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and not isFuelItem(d) and d.name ~= "minecraft:bucket" then
      if not seeds[d.name] then return true end
      kept[d.name] = (kept[d.name] or 0) + d.count
      if kept[d.name] > KEEP_SEEDS then return true end
    end
  end
  return false
end

-- Bring the harvest to the drop chest (cfg.drop). False if it couldn't get there.
local function deliver()
  local t = cfg.drop
  local cost = 2 * (math.abs(t.f) + math.abs(t.s) + math.abs(t.y) + 2 * HOP) + 20
  if not fuelFor(cost) then return false end
  setStatus("Bringing the harvest to the storage room")
  goHome()
  st.away = true
  save()
  flyTo(t.f, t.s, math.max(pos.y, t.y + 1) + HOP)
  while pos.y > t.y + 1 do
    if not step(DOWN) then error("Can't get down to the drop chest at " .. at(), 0) end
  end
  local info = inspect(DOWN)
  if not isChest(info) then error("No chest at the drop spot " .. t.f .. "," .. t.s .. "," .. t.y, 0) end
  local full = not unload(turtle.dropDown, true)
  if full then logError("The drop chest is full") end
  goHome()
  return not full
end

local function service()
  setStatus("Unloading")
  while not findChest() do
    setStatus("ERROR: no chest behind me. Put me on my home spot, Ctrl+T, type: farmer home")
    sleep(30)
  end
  refuelHome()
  countLava()
  face(2)
  while not unload(turtle.drop) do
    setStatus("Chest full! Empty it and I'll carry on")
    sleep(30)
  end
end

---------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------
local W, H = term.getSize()
local COLOR = term.isColour and term.isColour()
local function col(c, plain) if COLOR then return c end return plain or colors.white end

local function fmt(n)
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
  local home = pos.f == 0 and pos.s == 0 and pos.y == 0
  if st.paused then return home and "PAUSED" or "PAUSING", col(colors.yellow) end
  if ui.homeNow and not home then return "COMING HOME", col(colors.orange) end
  return "RUNNING", col(colors.lime)
end

-- The crops it harvested most, all time: { { name, n }, ... }
local function topCrops(n)
  local l = {}
  for k, v in pairs(st.crops) do if v > 0 then l[#l + 1] = { k, v } end end
  table.sort(l, function(a, b) return a[2] > b[2] end)
  while #l > n do table.remove(l) end
  return l
end

local function totalCrops()
  local t = 0
  for _, v in pairs(st.crops) do t = t + v end
  return t
end

local function drawScreen()
  local name, stateColor = state()
  row(1, " FARMER", colors.white, col(colors.lime, colors.gray))
  term.setCursorPos(W - #name, 1)
  term.setTextColor(stateColor)
  term.write(name)
  row(2, "")
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
  local barColor = (f < MIN_FUEL * 2) and col(colors.red) or (f < REFUEL_BELOW / 2) and col(colors.orange) or col(colors.lime)
  term.setBackgroundColor(barColor)
  term.write(string.rep(" ", fill))
  term.setBackgroundColor(col(colors.gray, colors.gray))
  term.write(string.rep(" ", barW - fill))
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.write(" " .. fmt(f))
  row(6, "")
  if lavaLeft == nil then
    pair(6, "Lava ", "put lava buckets in a chest under me")
  elseif lavaLeft == 0 then
    term.setCursorPos(2, 6)
    term.setTextColor(col(colors.red))
    term.write("Lava none left: put buckets in my chest!")
  else
    pair(6, "Lava ", lavaLeft .. " bucket" .. (lavaLeft == 1 and "" or "s") .. " in my chests")
  end
  row(7, "")
  row(8, "") pair(8, "Harvest ", fmt(totalCrops()), "Rounds   ", tostring(st.rounds))
  row(9, "") pair(9, "Field   ", cfg.length .. "x" .. cfg.width, "Round    ",
    math.floor((st.cursor - 1) * 100 / #CELLS) .. "%")
  local top = topCrops(3)
  local parts = {}
  for _, t in ipairs(top) do parts[#parts + 1] = fmt(t[2]) .. " " .. t[1]:lower() end
  row(10, " " .. (#parts > 0 and table.concat(parts, ", ") or "Nothing harvested yet"), col(colors.lightGray))
  if ui.lastError then row(11, " ! " .. ui.lastError, col(colors.red)) else row(11, "") end
  for y = 12, H - 1 do row(y, "") end
  local keys = st.paused and " [P] go on  [Q] quit" or " [P] pause [H] home [N] now [Q] quit"
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
          print("Farmer stopped. Type farmer to start it again.")
          return
        end
      elseif a == keys.p then
        st.paused = not st.paused
        save()
      elseif a == keys.h then
        ui.homeNow = true
      elseif a == keys.n then
        ui.now = true
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
local function recover() goHome() end

local function stuck(fn)
  local ok, err = pcall(fn)
  while not ok do
    if err == "Terminated" then error(err, 0) end
    logError(err)
    setStatus("STUCK: " .. tostring(err))
    sleep(30)
    ok, err = pcall(fn)
  end
end

local function worker()
  stuck(recover)
  local rest = nil -- "fuel": it came home short of fuel, wait at home after unloading
  while true do
    if cfg.drop and haveHarvest() and fuel() >= MIN_FUEL then
      local ok, err = pcall(deliver)
      if not ok then
        if err == "Terminated" then error(err, 0) end
        logError(err)
        setStatus("Error: " .. tostring(err))
      end
      stuck(recover)
    end
    service()
    if ui.updateNow then
      -- panel's Update all: fetch the latest farmer.lua now that it's home (reboots if new)
      ui.updateNow = false
      setStatus("Updating from GitHub")
      shell.run(shell.getRunningProgram(), "update") -- fetches update.lua too if it is missing
    end
    ui.homeNow = false
    if rest == "fuel" and not st.paused then
      setStatus("Low on fuel: waiting for lava buckets")
      sleep(120)
    elseif rest == "error" then
      sleep(30)
    elseif st.nextAt and not st.paused then
      setStatus("Waiting for the crops to grow")
      -- wake up straight away for pause, harvest now or Update all
      while now() < st.nextAt and not (st.paused or ui.now or ui.updateNow) do sleep(1) end
      if ui.now or now() >= st.nextAt then st.nextAt = nil save() end
    end
    ui.now = false
    rest = nil
    if st.paused then
      setStatus("Paused at home. Press P to go on")
      while st.paused do sleep(1) end
    elseif st.nextAt or ui.updateNow then
      -- not time yet: woken up for Update all, which runs at the top of the loop
    elseif fuel() < MIN_FUEL then
      setStatus("Out of fuel: put lava buckets in a chest under me")
      sleep(30)
    else
      local ok, why = pcall(round)
      if not ok then
        if why == "Terminated" then error(why, 0) end
        logError(why)
        setStatus("Error: " .. tostring(why))
        why = "error"
      end
      stuck(recover)
      if why == "fuel" or why == "error" then rest = why end
    end
  end
end

-- Developer commands from the pocket panel's console (panel.lua): info, log, ls, cat,
-- get (copy a file to the pocket), reboot, and put / rm / lua (write or delete a file,
-- run Lua). If this computer has a file "dev.key", every command needs that same
-- password (on the pocket: key <password>). put, rm and lua only work once dev.key exists.
local function devCommand(m, logFile, program, reply)
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
    out("Locked: put a password in a file dev.key on this computer to allow " .. op)
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
  elseif op == "reboot" then
    out("Rebooting...")
    reply(r)
    sleep(0.5)
    os.reboot()
    return
  else r.ok = false out("Unknown dev command: " .. tostring(op)) end
  reply(r)
end

-- Pocket control panel (panel.lua): status, pause / come home / harvest now and
-- Update all over a wireless or ender modem. Without a modem this just waits forever.
local function radio()
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then while true do os.pullEvent("farmer_never") end end
  rednet.open(peripheral.getName(modem))
  rednet.host("farmer", os.getComputerLabel() or ("farmer" .. os.getComputerID()))
  while true do
    local id, m = rednet.receive("farmer")
    if type(m) == "table" and m.type == "dev" then
      devCommand(m, LOG_FILE, "farmer", function(r) rednet.send(id, r, "farmer") end)
    elseif type(m) == "table" then
      if m.cmd == "pause" then st.paused = true save()
      elseif m.cmd == "resume" then st.paused = false save()
      elseif m.cmd == "home" then ui.homeNow = true
      elseif m.cmd == "now" then ui.now = true
      elseif m.cmd == "update" then ui.updateNow, ui.homeNow = true, true end
      if m.cmd then ui.draw() end
      local top = {}
      for _, t in ipairs(topCrops(3)) do top[#top + 1] = { name = t[1], n = t[2] } end
      local name = state()
      rednet.send(id, { type = "farmer_state", rid = m.rid, label = os.getComputerLabel(), state = name,
        status = ui.status, fuel = fuel(), fuelMax = REFUEL_TO, lava = lavaLeft, harvested = totalCrops(),
        top = top, items = st.items, rounds = st.rounds, field = cfg.length .. "x" .. cfg.width,
        progress = math.floor((st.cursor - 1) * 100 / #CELLS), next = st.nextAt and math.max(0, math.floor((st.nextAt - now()) / 1000)),
        drop = cfg.drop ~= nil, paused = st.paused, err = ui.lastError, pos = { f = pos.f, s = pos.s, y = pos.y } }, "farmer")
    end
  end
end

local function main()
  term.clear()
  parallel.waitForAny(worker, screen, radio)
end

turtle.select(1)
main()
