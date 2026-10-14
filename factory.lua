-- factory.lua - turtle factory: builds new turtles and sends them off to work (CC: Tweaked)
--
-- The factory is a crafty turtle (crafting table) with a wireless or ender modem. It takes
-- a plain turtle, a tool and a wireless modem out of its supply chest, crafts them into
-- a working turtle, puts it on the launch pad and switches it on. The new turtle boots
-- from the factory's floppy disk, downloads its program, flies to the spot you gave it
-- and sets itself up there. A new miner then takes orders from the hub like the others.
--
-- Layout (F = factory, looking forward):
--      [disk drive with a floppy]  [free]      <- the new turtle appears here
--      [F]                         [free]      <- the factory steps here to place it
--   supply chest behind, beside or under F. Keep the sky above the launch pad open.
--
-- The storage room can craft the parts: plain turtles (iron, a computer, a chest),
-- computers, wireless modems (ender pearl), diamond pickaxes, axes and hoes. Put the
-- factory against the storage room's pickup chest (that chest is then its supply chest)
-- and switch on "factory order on": it orders whatever it's missing by itself.
--
-- One-time setup:
--   factory setup <x> <y> <z> <facing>     (with GPS hosts: factory setup)
-- Orders (on the turtle after Q, or the pocket panel's Bots tab):
--   factory build <kind> <x> <y> <z> <facing> [setup arguments]
--     kind: miner, farmer, fuel, builder, lumber, or turtle (just a turtle with a pickaxe)
--     x y z facing: the new turtle's home spot (build its chest there first)
--     setup arguments: what comes after "x y z facing" in that bot's setup, e.g.
--       factory build miner 130 64 -350 south east      (role east)
--       factory build farmer 90 64 10 north 9 9         (field 9 long, 9 wide)
--       factory build lumber 60 70 40 north 48          (lumber has no x y z: radius 48)
--   factory list     factory cancel     factory order on|off
-- Then:
--   factory         run (starts by itself on boot after setup). Keys: P pause, Q quit

local lib = dofile("botlib.lua")
local CFG_FILE = "factory.cfg"
local GIVE_FUEL = 2000 -- fuel the new turtle gets for the trip (lava buckets or coal)
local TURTLE, MODEM, ENDER = "computercraft:turtle_normal", "computercraft:wireless_modem_normal",
  "computercraft:wireless_modem_advanced"
local TOOLS = {
  miner = "minecraft:diamond_pickaxe", builder = "minecraft:diamond_pickaxe", turtle = "minecraft:diamond_pickaxe",
  lumber = "minecraft:diamond_axe", farmer = "minecraft:diamond_hoe", fuel = false,
}
-- What the new turtle runs at its spot (after "x y z facing", the order's own arguments follow)
local SETUP = {
  miner = "miner setup %s", farmer = "farmer setup %s", fuel = "fuel setup %s", builder = "builder setup %s",
  lumber = "lumber setup", turtle = nil,
}

local args = { ... }
if args[1] == "update" then lib.update() return end

-- The program on the floppy: every new turtle on the launch pad runs it when it boots
local BOOT = [==[
-- written by factory.lua: a new turtle from the factory sets itself up
if fs.exists("/startup.lua") or fs.exists("/factory.cfg") then
  -- not a new turtle (the factory itself, or one that's set up already): normal start
  if fs.exists("/startup.lua") then shell.run("/startup.lua") end
  return
end
local mount, side
for _, s in ipairs(peripheral.getNames()) do
  if peripheral.getType(s) == "drive" and disk.hasData(s) then mount, side = disk.getMountPath(s), s end
end
local h = mount and fs.open(fs.combine(mount, "job"), "r")
if not h then print("No job on the factory disk.") return end
local job = textutils.unserialize(h.readAll())
h.close()
os.setComputerLabel(job.label)
print("Factory turtle: " .. job.label)
-- which way it faces: the disk drive is on the side away from the factory's front
local F = job.facing
local face = ({ front = (F + 2) % 4, back = F, left = (F + 3) % 4, right = (F + 1) % 4 })[side] or F
for s = 1, 16 do turtle.select(s) turtle.refuel() end
turtle.select(1)
-- its program
if job.kind ~= "turtle" then
  shell.run("wget", job.base .. "install.lua", "install.lua")
  shell.run("install", job.kind)
end
-- fly there: up, across, down
local DX, DZ = { [0] = 0, 1, 0, -1 }, { [0] = -1, 0, 1, 0 }
local x, y, z = job.pad.x, job.pad.y, job.pad.z
local function turnTo(d)
  while face ~= d do turtle.turnRight() face = (face + 1) % 4 end
end
local function fail(msg)
  print(msg)
  print("Fix it, then pick me up and put me at " .. job.x .. " " .. job.y .. " " .. job.z .. " and run:")
  print(job.setup or "(nothing)")
  error("stopped", 0)
end
local cruise = math.max(y, job.y) + 6
while y < cruise do
  if not turtle.up() then fail("Can't go up at " .. x .. " " .. y .. " " .. z) end
  y = y + 1
end
for _, axis in ipairs({ "x", "z" }) do
  while (axis == "x" and x ~= job.x) or (axis == "z" and z ~= job.z) do
    local d
    if axis == "x" then d = x < job.x and 1 or 3 else d = z < job.z and 2 or 0 end
    turnTo(d)
    if turtle.forward() then
      x, z = x + DX[d], z + DZ[d]
    elseif y < cruise + 40 and turtle.up() then
      y = y + 1
    else
      fail("Can't fly past " .. x .. " " .. y .. " " .. z)
    end
  end
end
while y > job.y do
  if not turtle.down() then fail("Can't get down at " .. x .. " " .. y .. " " .. z) end
  y = y - 1
end
turnTo(job.f)
if job.setup then shell.run(job.setup) end
if fs.exists("/startup.lua") then os.reboot() end
print("Here I am. Give me a program.")
]==]

local function writeBoot()
  if not disk.isPresent("top") or not disk.hasData("top") then
    return false, "Put a disk drive with a floppy disk ON TOP of the factory"
  end
  local mount = disk.getMountPath("top")
  local h = fs.open(fs.combine(mount, "startup.lua"), "w")
  h.write(BOOT)
  h.close()
  disk.setLabel("top", "Factory boot disk")
  return true
end

if args[1] == "setup" then
  if not turtle then error("factory.lua only runs on a turtle", 0) end
  local home, msg = lib.parsePlace(args, 2)
  if not home then
    print(msg)
    print("Usage: factory setup <x> <y> <z> <facing>")
    return
  end
  local chest
  local ok, info = turtle.inspectDown()
  if ok and lib.isChest(info) then chest = lib.DOWN end
  for k = 0, 3 do -- all the way round, so it ends up facing the way it started
    local ok2, info2 = turtle.inspect()
    if not chest and k > 0 and ok2 and lib.isChest(info2) then chest = (home.f + k) % 4 end
    turtle.turnRight()
  end
  local old = lib.loadTable(CFG_FILE) or {}
  lib.saveTable(CFG_FILE, { home = home, chest = chest or (home.f + 2) % 4, order = old.order })
  lib.startup("factory")
  os.setComputerLabel(os.getComputerLabel() or "Factory")
  if not chest then print("WARNING: no supply chest found behind, beside or under the turtle!") end
  local okBoot, why = writeBoot()
  if not okBoot then print("WARNING: " .. why) end
  if not peripheral.find("workbench") then print("WARNING: the factory needs a crafting table (a crafty turtle).") end
  print("Saved. Order a turtle, e.g. factory build miner 130 64 -350 south east")
  print("Then start with: factory   (or reboot the turtle)")
  return
end

if not turtle then error("factory.lua only runs on a turtle", 0) end
local cfg = lib.loadTable(CFG_FILE)
if not cfg then
  print("Not set up yet. First: factory setup <x> <y> <z> <facing>")
  return
end

-- words -> order, or nil and a usage line
local function parseOrder(w)
  local kind = (w[2] or ""):lower()
  if TOOLS[kind] == nil then return nil, "build <miner|farmer|fuel|builder|lumber|turtle> <x> <y> <z> <facing> [setup args]" end
  local x, y, z, f = tonumber(w[3]), tonumber(w[4]), tonumber(w[5]), lib.DIRS[(w[6] or ""):lower()]
  if not (x and y and z and f) then return nil, "build " .. kind .. " <x> <y> <z> <facing> [setup args]" end
  local rest = table.concat(w, " ", 7)
  if kind == "miner" and rest == "" then return nil, "A miner needs its role: north, east, south or west" end
  if kind == "farmer" and rest == "" then return nil, "A farmer needs its field: <length> <width> [left]" end
  return { kind = kind, x = x, y = y, z = z, f = f, rest = rest }
end

local function orderText(o)
  return ("%s at %d %d %d %s %s"):format(o.kind, o.x, o.y, o.z, lib.DIRNAME[o.f], o.rest or "")
end

local function command(st, w)
  local cmd = (w[1] or ""):lower()
  st.queue = st.queue or {}
  if cmd == "build" then
    local o, err = parseOrder(w)
    if not o then return err end
    st.queue[#st.queue + 1] = o
    return "Queued: " .. orderText(o)
  elseif cmd == "list" then
    local l = {}
    for k, o in ipairs(st.queue) do l[#l + 1] = k .. ". " .. orderText(o) end
    return #l > 0 and table.concat(l, "\n") or "Nothing ordered"
  elseif cmd == "cancel" then
    local o = table.remove(st.queue, 1)
    return o and ("Cancelled: " .. orderText(o)) or "Nothing ordered"
  elseif cmd == "order" then
    cfg.order = (w[2] or ""):lower() == "on"
    lib.saveTable(CFG_FILE, cfg)
    return cfg.order and "It orders missing parts from the storage room now" or "It won't order parts"
  end
  return "Commands: build, list, cancel, order on|off"
end

if args[1] == "home" then
  local s0 = lib.loadTable("factory.state") or {}
  s0.pos = { x = cfg.home.x, y = cfg.home.y, z = cfg.home.z }
  s0.h, s0.pending = cfg.home.f, nil
  lib.saveTable("factory.state", s0)
  print("Position reset to the home spot. Start with: factory")
  return
end
if args[1] then
  local s0 = lib.loadTable("factory.state") or {}
  print(command(s0, { table.unpack(args) }))
  lib.saveTable("factory.state", s0)
  return
end

local B = lib.bot("factory", cfg, { title = "TURTLE FACTORY", color = colors.cyan, fuelTo = 1000, minFuel = 20 })
local st, pos = B.st, B.pos
st.queue = st.queue or {}
st.built = st.built or 0
st.missing = st.missing or nil
local F = cfg.home.f
local pad = { x = cfg.home.x + lib.DX[F], y = cfg.home.y + 1, z = cfg.home.z + lib.DZ[F] }

---------------------------------------------------------------------------
-- Parts
---------------------------------------------------------------------------
local function named(name) return function(d) return d.name == name end end
local function isModem(d) return d.name == MODEM or d.name == ENDER end

-- The storage room, if there is one in range (for ordering parts)
local function sorter()
  local ok, id = pcall(rednet.lookup, "roomsorter")
  return ok and id or nil
end

local function inChest(test)
  return B.chestCount(cfg.chest, test) or 0
end

local function fuelInChest()
  return B.chestCount(cfg.chest, B.isFuel) or 0
end

-- What's missing for this order: a list of item names
local function missingParts(o)
  local miss = {}
  if inChest(named(TURTLE)) == 0 then miss[#miss + 1] = TURTLE end
  if TOOLS[o.kind] and inChest(named(TOOLS[o.kind])) == 0 then miss[#miss + 1] = TOOLS[o.kind] end
  if inChest(isModem) == 0 then miss[#miss + 1] = MODEM end
  return miss
end

local asked = {} -- item -> os.clock() when it was ordered
local function orderParts(miss)
  if not cfg.order then return end
  local id = sorter()
  if not id then return end
  for _, name in ipairs(miss) do
    if not asked[name] or os.clock() - asked[name] > 300 then
      asked[name] = os.clock()
      rednet.send(id, { cmd = "order", text = name, n = 1 }, "roomsorter")
    end
  end
end

---------------------------------------------------------------------------
-- Building one turtle
---------------------------------------------------------------------------
local function emptyAll()
  if not B.unload(cfg.chest) then error("Supply chest full", 0) end
end

local function slotOf(test)
  return B.findSlot(test)
end

-- Upgrades go on the side of the turtle they're crafted on: the tool left of the
-- turtle, then the modem right of it. Only those two items may be in the inventory.
local function craftParts(o)
  emptyAll()
  if TOOLS[o.kind] then
    B.setStatus("Crafting: turtle + " .. TOOLS[o.kind]:match(":(.+)$"))
    B.take(cfg.chest, named(TOOLS[o.kind]), 1) -- slot 1
    B.take(cfg.chest, named(TURTLE), 1)        -- slot 2
    turtle.select(1)
    if not turtle.craft() then error("Couldn't craft the tool onto the turtle", 0) end
    local t = slotOf(named(TURTLE))
    if not t then error("The crafted turtle went missing", 0) end
    if t ~= 1 then turtle.select(t) turtle.transferTo(1) end
  else
    B.take(cfg.chest, named(TURTLE), 1) -- slot 1
  end
  B.setStatus("Crafting: turtle + modem")
  if turtle.getItemCount(2) > 0 then turtle.select(2) B.drop(cfg.chest) end
  turtle.select(2)
  if B.take(cfg.chest, isModem, 1) == 0 then error("No wireless modem in the supply chest", 0) end
  turtle.select(1)
  if not turtle.craft() then error("Couldn't craft the modem onto the turtle", 0) end
  turtle.select(1)
end

local function build(o)
  local wb = peripheral.find("workbench")
  if not wb then error("No crafting table on the factory", 0) end
  -- 1. the turtle with its tool and modem
  craftParts(o)
  -- 2. the crafted turtle and fuel for its trip
  local t = slotOf(named(TURTLE))
  for s = 1, 16 do
    if s ~= t and turtle.getItemCount(s) > 0 then turtle.select(s) B.drop(cfg.chest) end
  end
  local fuelGot, fuelSlots = 0, {}
  for _ = 1, 4 do
    if fuelGot >= GIVE_FUEL then break end
    local before = {}
    for s = 1, 16 do before[s] = turtle.getItemCount(s) end
    if B.take(cfg.chest, B.isFuel, 1) == 0 then break end
    for s = 1, 16 do
      if turtle.getItemCount(s) > before[s] then
        local d = turtle.getItemDetail(s)
        local n = math.min(d.count, math.ceil((GIVE_FUEL - fuelGot) / B.FUEL[d.name]))
        fuelGot = fuelGot + n * B.FUEL[d.name]
        fuelSlots[#fuelSlots + 1] = { s = s, n = n }
      end
    end
  end
  if fuelGot < 200 then error("No fuel for the new turtle: put lava buckets or coal in the supply chest", 0) end
  -- 3. the job on the floppy
  local okBoot, why = writeBoot()
  if not okBoot then error(why, 0) end
  st.serial = (st.serial or 0) + 1
  local label = o.kind:sub(1, 1):upper() .. o.kind:sub(2) .. "-" .. st.serial
  local setup = SETUP[o.kind] and SETUP[o.kind]:format(o.x .. " " .. o.y .. " " .. o.z .. " " .. lib.DIRNAME[o.f] .. " " .. o.rest)
  if o.kind == "lumber" then setup = "lumber setup " .. o.rest end
  local h = fs.open(fs.combine(disk.getMountPath("top"), "job"), "w")
  h.write(textutils.serialize({ kind = o.kind, x = o.x, y = o.y, z = o.z, f = o.f, setup = setup, label = label,
    pad = pad, facing = F, base = lib.BASE }))
  h.close()
  -- 4. onto the pad, switch on, fuel
  B.setStatus("Launching " .. label)
  if not B.step(F) then error("Something is on the factory floor in front of me", 0) end
  if B.inspect(lib.UP) then
    B.step(lib.OPP[F])
    error("The launch pad is taken: is the last turtle still there?", 0)
  end
  turtle.select(t)
  if not turtle.placeUp() then
    B.step(lib.OPP[F])
    error("Couldn't put the turtle down on the launch pad", 0)
  end
  for _, f in ipairs(fuelSlots) do
    turtle.select(f.s)
    turtle.dropUp(f.n) -- into the new turtle's inventory
  end
  turtle.select(1)
  peripheral.call("top", "turnOn")
  sleep(2)
  B.step(lib.OPP[F])
  B.face(F)
  st.built = st.built + 1
  st.last = label .. " off to " .. o.x .. " " .. o.y .. " " .. o.z
  B.save()
end

local function trip()
  local o = st.queue[1]
  if not o then return end
  local miss = missingParts(o)
  if fuelInChest() == 0 and B.count(B.isFuel) == 0 then miss[#miss + 1] = "fuel (lava or coal)" end
  if #miss > 0 then
    st.missing = miss
    local short = {}
    for _, m in ipairs(miss) do short[#short + 1] = (m:match(":(.+)$") or m):gsub("_", " ") end
    B.setStatus("Missing: " .. table.concat(short, ", "))
    orderParts(miss)
    return "wait"
  end
  st.missing = nil
  build(o)
  table.remove(st.queue, 1)
  B.save()
  return #st.queue > 0 and "again" or nil
end

local function service()
  B.refuelFrom(cfg.chest)
  emptyAll()
  B.face(F)
end

B.lines = function()
  local miss = st.missing and #st.missing or 0
  return {
    { "Queued", #st.queue }, { "Built", st.built },
    { "Missing", miss }, { "Orders", cfg.order and "on" or "off" },
    { "Last", st.last or "-" },
  }
end
B.actions = {
  { label = "Build turtle", cmd = "cmd", ask = "<kind> <x> <y> <z> <facing> [setup args]", prefix = "build" },
  { label = "Queue", cmd = "cmd", arg = "list" },
  { label = "Cancel next", cmd = "cmd", arg = "cancel" },
  { label = "Order parts", cmd = "cmd", ask = "on or off", prefix = "order" },
}
B.onCommand = function(m)
  if m.cmd == "cmd" then
    local words = {}
    for wd in tostring(m.arg or ""):gmatch("%S+") do words[#words + 1] = wd end
    local msg = command(st, words)
    B.save()
    B.wakeUp()
    return msg
  end
  return "Unknown command " .. tostring(m.cmd)
end

-- the floppy may have been swapped: write the boot program again at every start
pcall(writeBoot)
B.run({ service = service, trip = trip, wait = 60, idleText = "Waiting for an order" })
