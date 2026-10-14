-- farmer.lua - crop farming turtle (CC: Tweaked)
--
-- A farming turtle (a turtle with a hoe; a pickaxe works too but can't till new land)
-- flies one block above a field and harvests whatever is ripe: wheat, carrots,
-- potatoes, beetroot, nether wart, melons, pumpkins, sugar cane and bamboo. It replants
-- the same crop straight away and tills bare dirt in the field. The harvest goes in its
-- chest (put that chest by the storage room's input chest and it all gets sorted).
--
-- Put it on the corner of the field, ONE BLOCK ABOVE the crops, with a chest next to it
-- (behind, beside or under it, not on the field side). The field starts at the block in
-- front of the turtle and goes <length> blocks forward and <width> blocks to the right
-- (or left), counting the column the turtle is in.
--
-- One-time setup:
--   farmer setup <x> <y> <z> <facing> <length> <width> [left]
--     x y z facing = where the turtle is and the way it faces (F3); with GPS hosts
--                    (gpshost.lua) "farmer setup <length> <width>" is enough
-- Then:
--   farmer          run (starts by itself on boot after setup). Keys: P pause, H home, Q quit
--                   The pocket panel's Bots tab has a Harvest now button.
--   farmer home     after putting it back on its home spot by hand: reset position
--
-- Fuel: lava buckets or coal in its chest. It never eats the crops. Bone meal in the
-- turtle gets used on young crops. It keeps up to a stack of every kind of seed to replant.

local lib = dofile("botlib.lua")
local CFG_FILE = "farmer.cfg"
local WAIT_MIN = 15       -- minutes between rounds
local KEEP_SEEDS = 64     -- seeds of each kind it keeps for replanting; the rest goes in the chest

local args = { ... }
if args[1] == "update" then lib.update() return end

-- crop block -> the item that plants it, and the age when it's ripe
local CROPS = {
  ["minecraft:wheat"] = { seed = "minecraft:wheat_seeds", ripe = 7 },
  ["minecraft:carrots"] = { seed = "minecraft:carrot", ripe = 7 },
  ["minecraft:potatoes"] = { seed = "minecraft:potato", ripe = 7 },
  ["minecraft:beetroots"] = { seed = "minecraft:beetroot_seeds", ripe = 3 },
  ["minecraft:nether_wart"] = { seed = "minecraft:nether_wart", ripe = 3 },
}
local SEEDS = {}
for block, c in pairs(CROPS) do SEEDS[c.seed] = block end
local FRUIT = { ["minecraft:melon"] = true, ["minecraft:pumpkin"] = true }
local TALL = { ["minecraft:sugar_cane"] = true, ["minecraft:bamboo"] = true }

if args[1] == "setup" then
  if not turtle then error("farmer.lua only runs on a turtle", 0) end
  local home, nextArg = lib.parsePlace(args, 2)
  if not home then
    print(nextArg)
    print("Usage: farmer setup <x> <y> <z> <facing> <length> <width> [left]")
    return
  end
  local length, width = tonumber(args[nextArg]), tonumber(args[nextArg + 1])
  local left = (args[nextArg + 2] or ""):lower() == "left"
  if not length or not width or length < 1 or width < 1 then
    print("Usage: farmer setup <x> <y> <z> <facing> <length> <width> [left]")
    return
  end
  -- the chest: under the turtle, or behind / beside it
  local chest
  local ok, info = turtle.inspectDown()
  if ok and lib.isChest(info) then chest = lib.DOWN end
  if not chest then
    local turns = { { 2, "turnRight", "turnRight" }, { 1, "turnRight" }, { 3, "turnLeft" } }
    for _, t in ipairs(turns) do
      for k = 2, #t do turtle[t[k]]() end
      local ok2, info2 = turtle.inspect()
      for k = #t, 2, -1 do if t[k] == "turnRight" then turtle.turnLeft() else turtle.turnRight() end end
      if ok2 and lib.isChest(info2) then chest = (home.f + t[1]) % 4 break end
    end
  end
  if not chest then print("WARNING: no chest found under, behind or beside the turtle!") chest = (home.f + 2) % 4 end
  lib.saveTable(CFG_FILE, { home = home, chest = chest, length = math.floor(length), width = math.floor(width), left = left })
  if fs.exists("farmer.state") then fs.delete("farmer.state") end
  lib.startup("farmer")
  os.setComputerLabel(os.getComputerLabel() or "Farmer")
  print("Saved. Field " .. math.floor(length) .. " long, " .. math.floor(width) .. " wide to the " .. (left and "left" or "right") .. ".")
  print("Start with: farmer   (or reboot the turtle)")
  return
end

if not turtle then error("farmer.lua only runs on a turtle", 0) end
local cfg = lib.loadTable(CFG_FILE)
if not cfg then
  print("Not set up yet. First: farmer setup <x> <y> <z> <facing> <length> <width> [left]")
  return
end

if args[1] == "home" then
  local s0 = lib.loadTable("farmer.state") or {}
  s0.pos = { x = cfg.home.x, y = cfg.home.y, z = cfg.home.z }
  s0.h, s0.pending = cfg.home.f, nil
  lib.saveTable("farmer.state", s0)
  print("Position reset to the home spot. Start with: farmer")
  return
end

local B = lib.bot("farmer", cfg, { title = "FARMER", color = colors.lime })
local st, pos = B.st, B.pos
st.harvest = st.harvest or {} -- item name -> how many it brought home, all time
st.crop = st.crop or {}       -- "i,j" -> crop block that grew there (to replant the same)
st.bad = st.bad or {}         -- "i,j" -> nothing grows there (stone, water, a path)
st.rounds = st.rounds or 0

-- Field cell i (1..length, forward) j (0..width-1, sideways): the spot the turtle flies over
local F = cfg.home.f
local SIDE = cfg.left and (F + 3) % 4 or (F + 1) % 4
local function cell(i, j)
  return cfg.home.x + lib.DX[F] * i + lib.DX[SIDE] * j, cfg.home.z + lib.DZ[F] * i + lib.DZ[SIDE] * j
end

local function isSeed(d) return SEEDS[d.name] ~= nil end
local function isBoneMeal(d) return d.name == "minecraft:bone_meal" end

-- Only a hoe tills; a pickaxe would dig the dirt away. Turtles that can't tell what
-- they hold (older CC: Tweaked) don't till.
local function hasHoe()
  for _, f in ipairs({ "getEquippedLeft", "getEquippedRight" }) do
    if turtle[f] then
      local ok, d = pcall(turtle[f])
      if ok and type(d) == "table" and d.name and d.name:find("_hoe") then return true end
    end
  end
  return false
end

-- Seed to plant on this cell: the crop that was there, else the seed it has most of
local function seedSlot(key)
  local want = st.crop[key] and CROPS[st.crop[key]] and CROPS[st.crop[key]].seed
  local best, bestN
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and isSeed(d) then
      if want and d.name == want then return s end
      if not want and (not bestN or d.count > bestN) then best, bestN = s, d.count end
    end
  end
  if want then return nil end
  return best
end

-- Count what came into the inventory since 'before' (a snapshot of counts by name)
local function snapshot()
  local t = {}
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d then t[d.name] = (t[d.name] or 0) + d.count end
  end
  return t
end
local function countNew(before)
  for name, n in pairs(snapshot()) do
    local extra = n - (before[name] or 0)
    if extra > 0 then st.harvest[name] = (st.harvest[name] or 0) + extra end
  end
end

-- Sugar cane or bamboo in the turtle's own layer, in the way on side d: cut it and pick
-- up the top part that falls down
local function cutTall(d)
  local info = B.inspect(d)
  if not info or not TALL[info.name] then return end
  local before = snapshot()
  B.dig(d)
  sleep(0.3)
  B.suck(d)
  countNew(before)
end

-- Plant on the empty spot below the turtle; tills dirt first if it has to (hoe)
local function plant(key)
  local s = seedSlot(key)
  if not s then return false end
  if B.place(lib.DOWN, s) then return true end
  -- no farmland: go down into the crop layer, till the dirt under it, come back up
  local below = B.inspect(lib.DOWN)
  if below then return false end
  if not B.step(lib.DOWN) then return false end
  local soil = B.inspect(lib.DOWN)
  local tilled = false
  if soil and hasHoe() and (lib.hasTag(soil, "minecraft:dirt") or soil.name:find("grass_block") or soil.name:find("dirt")) then
    tilled = turtle.digDown() -- a hoe turns it into farmland
  end
  if not B.step(lib.UP) then error("Can't get back up at " .. B.at(), 0) end
  if tilled and B.place(lib.DOWN, seedSlot(key) or s) then return true end
  if not tilled and hasHoe() then st.bad[key] = true end
  return false
end

-- The turtle is over cell i,j: harvest, replant, bone meal
local function tend(i, j)
  local key = i .. "," .. j
  local info = B.inspect(lib.DOWN)
  if not info then
    if not st.bad[key] then plant(key) end
    return
  end
  local name = info.name
  local crop = CROPS[name]
  local age = info.state and info.state.age
  if crop then
    st.crop[key] = name
    if age and age >= crop.ripe then
      local before = snapshot()
      turtle.digDown()
      countNew(before)
      plant(key)
    elseif B.findSlot(isBoneMeal) then
      B.place(lib.DOWN, B.findSlot(isBoneMeal))
    end
  elseif FRUIT[name] then
    local before = snapshot()
    turtle.digDown()
    countNew(before)
  elseif lib.hasTag(info, "minecraft:crops") and not TALL[name] and age and age >= 7 then
    -- a crop from another mod: harvest when age 7, replant if it gave seeds back
    local before = snapshot()
    turtle.digDown()
    countNew(before)
    plant(key)
  end
end

local function cellCount() return cfg.length * cfg.width end

-- One round over the whole field, in rows that go back and forth
local function trip()
  if not B.fuelFor(cellCount() + cfg.length + cfg.width + 20) then return "fuel" end
  B.setStatus("Harvesting")
  for j = 0, cfg.width - 1 do
    local from, to, stepI = 1, cfg.length, 1
    if j % 2 == 1 then from, to, stepI = cfg.length, 1, -1 end
    for i = from, to, stepI do
      if B.stopAsked() then return end
      if B.freeSlots() == 0 then
        B.setStatus("Full: unloading")
        return "again"
      end
      if not B.fuelFor(10) then return "fuel" end
      local x, z = cell(i, j)
      local d
      if pos.x ~= x then d = pos.x < x and 1 or 3 elseif pos.z ~= z then d = pos.z < z and 2 or 0 end
      if d and pos.y == cfg.home.y then cutTall(d) end
      local ok, err = pcall(B.goTo, x, cfg.home.y, z)
      if ok then
        tend(i, j)
      else
        if err == "Terminated" then error(err, 0) end
        B.logError("Cell " .. i .. "," .. j .. ": " .. tostring(err))
      end
    end
  end
  st.rounds = st.rounds + 1
  B.save()
end

local function service()
  B.setStatus("Unloading")
  B.refuelFrom(cfg.chest)
  while not B.unload(cfg.chest, function(d)
    if isSeed(d) then return KEEP_SEEDS end
    if isBoneMeal(d) then return 64 end
    return 0
  end) do
    B.setStatus("Chest full! Empty it and I'll carry on")
    sleep(30)
  end
  -- out of seeds: take some out of the chest
  if not B.findSlot(isSeed) then B.take(cfg.chest, isSeed, 64) end
  B.face(cfg.home.f)
  B.save()
end

B.lines = function()
  local total, top = 0, {}
  for name, n in pairs(st.harvest) do
    total = total + n
    top[#top + 1] = { name = name, n = n }
  end
  table.sort(top, function(a, b) return a.n > b.n end)
  local l = {
    { "Rounds", st.rounds }, { "Harvested", B.fmt(total) },
    { "Field", cfg.length .. "x" .. cfg.width }, { "Seeds", B.count(isSeed) },
  }
  for k = 1, math.min(4, #top) do
    local short = top[k].name:match(":(.+)$") or top[k].name
    l[#l + 1] = { short:gsub("_", " "):sub(1, 10), B.fmt(top[k].n) }
  end
  return l
end
B.actions = { { label = "Harvest now", cmd = "now" } }
B.onCommand = function(m)
  if m.cmd == "now" then B.wakeUp() return "Going round now" end
  return "Unknown command " .. tostring(m.cmd)
end

B.run({ service = service, trip = trip, wait = WAIT_MIN * 60, idleText = "Waiting for the crops to grow" })
