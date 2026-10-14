-- factory.lua - Turtle factory: the mining fleet builds its own new turtles (CC: Tweaked)
--
-- The factory is a crafty turtle (crafting table + wireless modem) outside the Storage
-- Room, facing the room's pickup chest. It orders the parts from the room sorter, crafts
-- a wireless mining turtle, places it on the build spot above itself, gives it coal and
-- its program. The new turtle flies to a free home spot and joins the hub's fleet.
--
--   factory setup [x y z]       once, on the factory turtle (its own coordinates; GPS works too)
--   factory slot <x> <y> <z> <facing> <role> [site]
--                               a home spot for a new miner (same as 'miner setup' takes)
--   factory slots               list the home spots
--   factory free <n>            home spot n is free again (its turtle got lost)
--   factory unslot <n>          forget home spot n
--   factory cruise <y>          height the new turtles fly at
--   factory disk                write the installer onto a floppy in a drive next to it
--   factory build [n]           build n miners (also while it runs: type build 2)
--   factory                     run (listens to 'build' from here and over the radio)
--   factory update              fetch the latest version from GitHub
--
-- Around the factory turtle:
--   front  the Storage Room's pickup chest (from outside the room)
--   below  a chest of its own for parts and coal
--   above  the build spot, open to the sky (up to the cruise height)
--   a disk drive with the factory floppy right next to the build spot (not under it)

local PROTOCOL = "turtlefactory"
local CFG_FILE, JOB_FILE = "factory.cfg", "deliver.job"
local PROGRAM = (shell and shell.getRunningProgram()) or "factory.lua"

local FUEL_PER_COAL = 80
local FUEL_MARGIN = 40
local ORDER_RETRY = 300   -- seconds without new parts before ordering the missing ones again
local ORDER_GIVEUP = 1800 -- seconds before a build gives up waiting for parts

local DIRS = { north = 0, east = 1, south = 2, west = 3, n = 0, e = 1, s = 2, w = 3 }
local DIRNAME = { [0] = "north", "east", "south", "west" }
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = -1, 0, 1, 0 }
local UP, DOWN = 4, 5

-- One wireless mining turtle
local IRON, COMPUTER, CHEST = "minecraft:iron_ingot", "computercraft:computer_normal", "minecraft:chest"
local PICKAXE, MODEM = "minecraft:diamond_pickaxe", "computercraft:wireless_modem_normal"
local TURTLE = "computercraft:turtle_normal"
local FUELS = { "minecraft:coal", "minecraft:charcoal" }

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

local function readFile(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  local s = h.readAll()
  h.close()
  return s
end

local function writeFile(path, s)
  local h = fs.open(path, "w")
  h.write(s)
  h.close()
end

local function pretty(name)
  local s = (name:match(":(.+)$") or name):gsub("_", " ")
  return s:sub(1, 1):upper() .. s:sub(2)
end

local function openModem()
  local m = peripheral.find("modem", function(_, x) return x.isWireless() end)
  if not m then return false end
  rednet.open(peripheral.getName(m))
  return true
end

local args = { ... }

if args[1] == "update" then
  if not fs.exists("update.lua") then
    shell.run("wget", "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/update.lua", "update.lua")
  end
  shell.run("update")
  return
end

---------------------------------------------------------------------------
-- The new turtle's side: fly to the home spot, then become a miner
---------------------------------------------------------------------------
if args[1] == "deliver" then
  local job = loadTable(JOB_FILE)
  if not job then print("Nothing to deliver.") return end
  openModem()
  local function tell(kind, text)
    print(text or kind)
    pcall(rednet.send, job.factory, { type = kind, text = text, slot = job.slot }, PROTOCOL)
  end
  local pos, home = job.pos, job.home
  if gps then
    local x, y, z = gps.locate(2)
    if x then pos.x, pos.y, pos.z = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5) end
  end
  for s = 1, 16 do
    turtle.select(s)
    turtle.refuel()
  end
  turtle.select(1)
  local function save() saveTable(JOB_FILE, job) end

  -- Leaves, grass and snow are dug away. Anything else is left alone: it goes around or waits.
  local SOFT = { ["minecraft:vine"] = true, ["minecraft:short_grass"] = true, ["minecraft:grass"] = true,
    ["minecraft:tall_grass"] = true, ["minecraft:fern"] = true, ["minecraft:large_fern"] = true,
    ["minecraft:snow"] = true }
  local function soft(name) return SOFT[name] or name:find("leaves$") ~= nil end

  local function face(d)
    while job.h ~= d do
      if (d - job.h) % 4 == 3 then turtle.turnLeft() job.h = (job.h + 3) % 4
      else turtle.turnRight() job.h = (job.h + 1) % 4 end
      save()
    end
  end

  local function step(dir)
    local go, inspect, dig, attack
    if dir == UP then go, inspect, dig, attack = turtle.up, turtle.inspectUp, turtle.digUp, turtle.attackUp
    elseif dir == DOWN then go, inspect, dig, attack = turtle.down, turtle.inspectDown, turtle.digDown, turtle.attackDown
    else
      face(dir)
      go, inspect, dig, attack = turtle.forward, turtle.inspect, turtle.dig, turtle.attack
    end
    for _ = 1, 10 do
      if go() then
        if dir == UP then pos.y = pos.y + 1
        elseif dir == DOWN then pos.y = pos.y - 1
        else pos.x, pos.z = pos.x + DX[dir], pos.z + DZ[dir] end
        save()
        return true
      end
      if turtle.getFuelLevel() == 0 then return false, "out of fuel" end
      local found, info = inspect()
      if found and soft(info.name) then dig()
      elseif found then return false, pretty(info.name)
      else attack() sleep(0.5) end -- a mob in the way
    end
    return false, "something in the way"
  end

  local function stuck(what)
    tell("stuck", ("Stuck at %d,%d,%d: %s. Trying again in 30 s."):format(pos.x, pos.y, pos.z, what))
    sleep(30)
  end

  -- Placed facing an unknown way (no block info)? Find out with GPS at cruise height.
  local function findFacing()
    if not gps then return false end
    local x1, _, z1 = gps.locate(2)
    if not x1 then return false end
    for _ = 1, 4 do
      if turtle.forward() then
        local x2, _, z2 = gps.locate(2)
        turtle.back()
        if not x2 then return false end
        for d = 0, 3 do
          if math.floor(x2 - x1 + 0.5) == DX[d] and math.floor(z2 - z1 + 0.5) == DZ[d] then job.h = d save() return true end
        end
        return false
      end
      turtle.turnRight()
    end
    return false
  end

  print(("Flying to my home spot %d,%d,%d"):format(home.x, home.y, home.z))
  while true do
    if job.stage == "up" then
      if pos.y >= job.cruise then job.stage = "x" save()
      else
        local ok, what = step(UP)
        if not ok then stuck(what) end
      end
    elseif job.stage == "x" or job.stage == "z" then
      local axis = job.stage
      if job.h == nil and not findFacing() then
        stuck("don't know which way I face (no GPS)")
      elseif pos[axis] == home[axis] then
        job.stage = axis == "x" and "z" or "down"
        save()
      else
        local dir
        if axis == "x" then dir = home.x > pos.x and 1 or 3 else dir = home.z > pos.z and 2 or 0 end
        local ok, what = step(dir)
        -- something tall in the way: hop over it
        if not ok and not (pos.y < job.cruise + 16 and step(UP)) then stuck(what) end
      end
    elseif job.stage == "down" then
      if pos.y <= home.y then job.stage = "turn" save()
      else
        local ok, what = step(DOWN)
        if not ok then stuck(what) end
      end
    else
      face(job.facing)
      for s = 1, 16 do
        turtle.select(s)
        turtle.refuel()
      end
      turtle.select(1)
      writeFile("startup.lua", 'shell.run("miner")\n')
      fs.delete(JOB_FILE)
      if fs.exists(PROGRAM) then fs.delete(PROGRAM) end
      tell("arrived", "Home. Starting as a miner.")
      sleep(1)
      os.reboot()
    end
  end
end

---------------------------------------------------------------------------
-- The floppy: every new turtle boots from it once and asks the factory for its program
---------------------------------------------------------------------------
local BOOT = [[
-- Turtle factory installer (written by 'factory disk').
-- A new turtle next to this drive asks the factory for its program. Any other
-- computer just starts as usual.
if not turtle or fs.exists("/startup.lua") or fs.exists("/miner.cfg") then
  if fs.exists("/startup.lua") then shell.run("/startup.lua") end
  return
end
local m = peripheral.find("modem", function(_, x) return x.isWireless() end)
if not m then print("No wireless modem on this turtle.") return end
rednet.open(peripheral.getName(m))
print("New turtle " .. os.getComputerID() .. ": asking the factory for my program...")
for _ = 1, 20 do
  rednet.broadcast({ type = "hello" }, "turtlefactory")
  local deadline = os.clock() + 5
  while os.clock() < deadline do
    local _, msg = rednet.receive("turtlefactory", deadline - os.clock())
    if type(msg) == "table" and msg.type == "package" and msg.to == os.getComputerID() then
      for name, code in pairs(msg.files) do
        local h = fs.open("/" .. name, "w") h.write(code) h.close()
      end
      local h = fs.open("/deliver.job", "w") h.write(textutils.serialize(msg.job)) h.close()
      h = fs.open("/startup.lua", "w") h.write('shell.run("factory", "deliver")\n') h.close()
      os.setComputerLabel(msg.label)
      shell.run("/startup.lua")
      return
    end
  end
end
print("No answer from the factory.")
]]

if args[1] == "disk" then
  local drive = peripheral.find("drive", function(_, d) return d.isDiskPresent() and d.hasData() end)
  if not drive then print("Put a disk drive with a floppy in it next to this computer first.") return end
  local path = drive.getMountPath()
  writeFile(fs.combine(path, "startup.lua"), BOOT)
  drive.setDiskLabel("Turtle factory")
  print("Installer written to the floppy.")
  print("Now put the floppy in a disk drive right next to the build spot (above the factory).")
  return
end

---------------------------------------------------------------------------
-- Factory settings
---------------------------------------------------------------------------
local cfg = loadTable(CFG_FILE) or {}
cfg.slots = cfg.slots or {}
cfg.built = cfg.built or 0
local function saveCfg() saveTable(CFG_FILE, cfg) end

if args[1] == "setup" then
  if not turtle then print("The factory runs on a crafty turtle.") return end
  local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
  if not x and gps then
    local gx, gy, gz = gps.locate(2)
    if gx then x, y, z = math.floor(gx + 0.5), math.floor(gy + 0.5), math.floor(gz + 0.5) end
  end
  if not (x and y and z) then
    print("Usage: factory setup <x> <y> <z>   (this turtle's own coordinates, F3)")
    return
  end
  cfg.pos = { x = x, y = y, z = z }
  cfg.cruise = cfg.cruise or y + 10
  saveCfg()
  local okFront = peripheral.hasType and peripheral.hasType("front", "inventory") or peripheral.getType("front")
  local okDown = peripheral.hasType and peripheral.hasType("bottom", "inventory") or peripheral.getType("bottom")
  if not okFront then print("WARNING: no pickup chest in front of the turtle!") end
  if not okDown then print("WARNING: no parts chest under the turtle!") end
  if turtle.detectUp() then print("WARNING: the build spot above the turtle isn't empty!") end
  writeFile("startup.lua", 'shell.run("factory")\n')
  os.setComputerLabel(os.getComputerLabel() or "Factory")
  print(("Saved. Factory at %d,%d,%d, new turtles fly at y=%d."):format(x, y, z, cfg.cruise))
  print("Next: factory slot ... for each home spot, factory disk, then factory")
  return
end

---------------------------------------------------------------------------
-- Commands (from the arguments, the prompt and the radio)
---------------------------------------------------------------------------
local queue = 0          -- miners still to build
local busy = nil         -- what the factory is doing right now
local stateText = "Idle"
local log = {}
local pendingUpdate = false
local cancelled = false

local function note(text)
  table.insert(log, 1, textutils.formatTime(os.time(), true) .. " " .. text)
  while #log > 6 do table.remove(log) end
  os.queueEvent("factory_draw")
end
local function setState(text) stateText = text os.queueEvent("factory_draw") end

local function slotName(i, sl)
  return ("%d: %d,%d,%d %s, role %s%s"):format(i, sl.x, sl.y, sl.z, DIRNAME[sl.facing], DIRNAME[sl.role],
    sl.site and (" @" .. sl.site) or "")
end
local function slotState(sl)
  if not sl.state then return "free" end
  return sl.state .. (sl.id and (" #" .. sl.id) or "")
end
local function freeSlots()
  local n = 0
  for _, sl in ipairs(cfg.slots) do if not sl.state then n = n + 1 end end
  return n
end

local function command(cmd, a)
  cmd = (cmd or ""):lower()
  a = a or {}
  if cmd == "slot" then
    local x, y, z = tonumber(a[1]), tonumber(a[2]), tonumber(a[3])
    local facing, role = DIRS[(a[4] or ""):lower()], DIRS[(a[5] or ""):lower()]
    if not (x and y and z and facing and role) then
      return { "slot <x> <y> <z> <facing> <role> [site]", "like 'miner setup': the spot, the way it faces (chest",
        "behind it), the direction of its main tunnel. Same role", "at a new place? Give a site name, e.g. b." }
    end
    cfg.slots[#cfg.slots + 1] = { x = x, y = y, z = z, facing = facing, role = role, site = a[6] }
    saveCfg()
    return { "Home spot " .. slotName(#cfg.slots, cfg.slots[#cfg.slots]) }
  elseif cmd == "slots" then
    local out = {}
    for i, sl in ipairs(cfg.slots) do out[#out + 1] = slotName(i, sl) .. ": " .. slotState(sl) end
    if #out == 0 then out[1] = "No home spots yet: slot <x> <y> <z> <facing> <role>" end
    return out
  elseif cmd == "free" or cmd == "unslot" then
    local i = tonumber(a[1])
    local sl = i and cfg.slots[i]
    if not sl then return { cmd .. " <n>   (see slots)" } end
    if busy == i then return { "It is building for that spot right now." } end
    if cmd == "free" then sl.state, sl.id = nil, nil else table.remove(cfg.slots, i) end
    saveCfg()
    return { cmd == "free" and ("Spot " .. i .. " is free again.") or ("Forgot spot " .. i .. ".") }
  elseif cmd == "cruise" then
    local y = tonumber(a[1])
    if not y then return { "cruise <y>: new turtles fly at y=" .. tostring(cfg.cruise) } end
    cfg.cruise = math.floor(y)
    saveCfg()
    return { "New turtles fly at y=" .. cfg.cruise .. "." }
  elseif cmd == "build" then
    local n = math.max(1, math.floor(tonumber(a[1]) or 1))
    local free = freeSlots() - queue - (busy and 1 or 0)
    if free <= 0 then return { "No free home spot left. Add one with slot ..." } end
    if n > free then n = free end
    queue = queue + n
    cancelled = false
    os.queueEvent("factory_wake")
    return { "Building " .. n .. " miner" .. (n > 1 and "s" or "") .. "." }
  elseif cmd == "cancel" then
    queue = 0
    cancelled = busy ~= nil
    return { busy and "Stopping after this step (parts stay in its chest)." or "Nothing to cancel." }
  elseif cmd == "update" then
    pendingUpdate = true
    os.queueEvent("factory_wake")
    return { busy and "Updating after this turtle." or "Updating..." }
  elseif cmd == "status" then
    return { stateText, ("%d to build, %d free spots, %d built so far"):format(queue, freeSlots(), cfg.built) }
  end
  return { "Commands: build [n], cancel, slot ..., slots, free <n>, unslot <n>, cruise <y>, status, update" }
end

if args[1] and args[1] ~= "build" then
  for _, l in ipairs(command(args[1], { table.unpack(args, 2) })) do print(l) end
  return
end

if not turtle then error("factory.lua runs on a crafty turtle", 0) end
if not cfg.pos then print("Not set up yet. First: factory setup [x y z]") return end
if not openModem() then print("The factory needs a wireless modem.") return end
if not turtle.craft then print("The factory needs a crafting table (craft it onto the turtle).") return end
rednet.host(PROTOCOL, os.getComputerLabel() or ("factory" .. os.getComputerID()))
if args[1] == "build" then command("build", { args[2] }) end

---------------------------------------------------------------------------
-- Parts: ordered from the Storage Room, moved from its pickup chest to our own chest
---------------------------------------------------------------------------
local pickup = function() return peripheral.wrap("front") end
local parts = function() return peripheral.wrap("bottom") end

local function countIn(inv, names)
  local n = 0
  if not inv then return 0 end
  for _, it in pairs(inv.list()) do
    for _, name in ipairs(names) do if it.name == name then n = n + it.count end end
  end
  return n
end

local sorterId
local function askSorter(cmd, text, n)
  if not sorterId then sorterId = rednet.lookup("roomsorter") end
  if not sorterId then return nil end
  local rid = math.random(1, 1073741823)
  rednet.send(sorterId, { cmd = cmd, text = text, n = n, rid = rid }, "roomsorter")
  local deadline = os.clock() + 10
  while os.clock() < deadline do
    local from, msg = rednet.receive("roomsorter", deadline - os.clock())
    if from == sorterId and type(msg) == "table" and msg.rid == rid then return msg end
  end
  sorterId = nil
  return nil
end

-- What one turtle needs, by item (fuel: any of FUELS)
local function partsFor(sl)
  local p = cfg.pos
  local dist = (cfg.cruise - p.y - 1) + math.abs(sl.x - p.x) + math.abs(sl.z - p.z) + math.max(0, cfg.cruise - sl.y)
  local coal = math.ceil((dist + FUEL_MARGIN) / FUEL_PER_COAL)
  return {
    { names = { IRON }, n = 7 }, { names = { COMPUTER }, n = 1 }, { names = { CHEST }, n = 1 },
    { names = { PICKAXE }, n = 1 }, { names = { MODEM }, n = 1 }, { names = FUELS, n = coal },
  }, coal
end

-- Move what's still missing from the pickup chest into the parts chest
local function collect(need)
  local from, to = pickup(), parts()
  if not (from and to) then return end
  local missing = {}
  for _, it in ipairs(need) do missing[it] = it.n - countIn(to, it.names) end
  for slot, item in pairs(from.list()) do
    for _, it in ipairs(need) do
      for _, name in ipairs(it.names) do
        if item.name == name and missing[it] > 0 then
          local moved = from.pushItems("bottom", slot, math.min(item.count, missing[it]))
          missing[it] = missing[it] - (moved or 0)
        end
      end
    end
  end
end

local function shortOf(need)
  local to = parts()
  local out = {}
  for _, it in ipairs(need) do
    local have = countIn(to, it.names)
    if have < it.n then out[#out + 1] = { it = it, n = it.n - have } end
  end
  return out
end

local function order(list)
  for _, m in ipairs(list) do
    local name = m.it.names[1]
    local reply = askSorter("order", name, m.n)
    if not reply then return false, "The Storage Room doesn't answer (does its turtle have a wireless modem?)" end
    local first = type(reply[1]) == "string" and reply[1] or ""
    -- coal: charcoal will do too
    if not (first:find("^Getting") or first:find("^Crafting") or first:find("^Only")) and m.it.names[2] then
      local r2 = askSorter("order", m.it.names[2], m.n)
      local f2 = r2 and type(r2[1]) == "string" and r2[1] or ""
      if f2:find("^Getting") or f2:find("^Crafting") or f2:find("^Only") then first = f2 end
    end
    if not (first:find("^Getting") or first:find("^Crafting") or first:find("^Only")) then
      return false, pretty(name) .. ": " .. first
    end
    note("Ordered " .. m.n .. " " .. pretty(name))
  end
  return true
end

local function gatherParts(need)
  collect(need)
  local short = shortOf(need)
  if #short == 0 then return true end
  local ok, err = order(short)
  if not ok then return false, err end
  local start, lastProgress, lastShort = os.clock(), os.clock(), #short
  while true do
    if cancelled then return false, "Cancelled." end
    local names = {}
    for _, m in ipairs(short) do names[#names + 1] = m.n .. " " .. pretty(m.it.names[1]) end
    setState("Waiting for parts: " .. table.concat(names, ", "))
    sleep(5)
    collect(need)
    short = shortOf(need)
    if #short == 0 then return true end
    local left = 0
    for _, m in ipairs(short) do left = left + m.n end
    if left < lastShort then lastShort, lastProgress = left, os.clock() end
    if os.clock() - start > ORDER_GIVEUP then return false, "Parts didn't come: " .. table.concat(names, ", ") end
    if os.clock() - lastProgress > ORDER_RETRY then
      -- extra parts are no loss: they wait in the chest for the next turtle
      ok, err = order(short)
      if not ok then return false, err end
      lastProgress = os.clock()
    end
  end
end

---------------------------------------------------------------------------
-- Crafting (the parts chest under the turtle holds everything in between)
---------------------------------------------------------------------------
local function emptyAll()
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then turtle.select(s) turtle.dropDown() end
  end
  turtle.select(1)
  for s = 1, 16 do if turtle.getItemCount(s) > 0 then return false end end
  return true
end

-- n of one of names from the parts chest into turtle slot `slot`.
-- suckDown takes from the chest's first slot, so the item is moved there first.
local function take(names, n, slot)
  local chest = parts()
  turtle.select(slot)
  for _ = 1, 8 do
    local have = turtle.getItemCount(slot)
    if have >= n then break end
    local list = chest.list()
    local from
    for s, it in pairs(list) do
      for _, name in ipairs(names) do if it.name == name and (not from or s < from) then from = s end end
    end
    if not from then break end
    if from ~= 1 then
      if list[1] then
        local free
        for s = 2, chest.size() do if not list[s] then free = s break end end
        if not free then break end
        chest.pushItems("bottom", 1, 64, free)
      end
      chest.pushItems("bottom", from, n - have, 1)
    end
    turtle.suckDown(n - have)
  end
  turtle.select(1)
  return turtle.getItemCount(slot) >= n
end

local function findTurtle()
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == TURTLE then return s end
  end
end

-- craft with what's in the grid; the result goes to slot 16, then to `to`
local function craftInto(to)
  turtle.select(16)
  local ok = turtle.craft(1)
  turtle.select(1)
  if not ok then return false end
  local s = findTurtle()
  if s and s ~= to then turtle.select(s) turtle.transferTo(to) turtle.select(1) end
  return turtle.getItemCount(to) > 0
end

local function craftMiner()
  if not emptyAll() then return false, "The parts chest under the factory is full." end
  -- turtle: iron all around, computer in the middle, chest at the bottom
  for _, s in ipairs({ 1, 2, 3, 5, 7, 9, 11 }) do
    if not take({ IRON }, 1, s) then emptyAll() return false, "No iron ingots in the parts chest." end
  end
  if not take({ COMPUTER }, 1, 6) or not take({ CHEST }, 1, 10) then emptyAll() return false, "Computer or chest missing." end
  if not craftInto(2) then emptyAll() return false, "Couldn't craft the turtle." end
  -- pickaxe on its left, then the wireless modem on its right
  if not take({ PICKAXE }, 1, 1) then emptyAll() return false, "No diamond pickaxe." end
  if not craftInto(1) then
    emptyAll()
    return false, "Couldn't put the pickaxe on (it must be a new, undamaged one)."
  end
  if not take({ MODEM }, 1, 2) then emptyAll() return false, "No wireless modem." end
  if not craftInto(1) then emptyAll() return false, "Couldn't put the modem on." end
  return true
end

---------------------------------------------------------------------------
-- Deploying: place it on the build spot, give it coal and its program
---------------------------------------------------------------------------
local function minerCode()
  -- the hub's released version, so it matches the rest of the fleet
  local hubId = rednet.lookup("minearmy", "hub")
  if hubId then
    rednet.send(hubId, { type = "get_miner" }, "minearmy")
    local deadline = os.clock() + 5
    while os.clock() < deadline do
      local from, msg = rednet.receive("minearmy", deadline - os.clock())
      if from == hubId and type(msg) == "table" and msg.type == "miner_file" and msg.code then return msg.code end
    end
  end
  local code = readFile("miner.lua")
  if code then return code end
  if http then
    local res = http.get("https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/miner.lua")
    if res then code = res.readAll() res.close() return code end
  end
end

local function deploy(i, sl, coal)
  while turtle.detectUp() do
    if cancelled then return false, "Cancelled." end
    setState("Waiting: the build spot above is taken")
    sleep(5)
  end
  turtle.select(1)
  if not turtle.placeUp() then return false, "Couldn't place the new turtle above the factory." end
  take(FUELS, coal, 2)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and (d.name == FUELS[1] or d.name == FUELS[2]) then turtle.select(s) turtle.dropUp() end
  end
  emptyAll()
  local found, info = turtle.inspectUp()
  local facing = found and info.state and DIRS[info.state.facing or ""]
  local newTurtle = peripheral.wrap("top")
  if not (newTurtle and newTurtle.getID) then return false, "The new turtle didn't show up as a peripheral." end
  local id = newTurtle.getID()
  local code = minerCode()
  if not code then return false, "No miner.lua: not on the hub, here, or on GitHub." end
  local files = { ["miner.lua"] = code, ["factory.lua"] = readFile(PROGRAM) }
  files["update.lua"] = readFile("update.lua")
  local p = cfg.pos
  local job = {
    factory = os.getComputerID(), slot = i, stage = "up", cruise = cfg.cruise,
    pos = { x = p.x, y = p.y + 1, z = p.z }, h = facing,
    home = { x = sl.x, y = sl.y, z = sl.z }, facing = sl.facing,
  }
  files["miner.cfg"] = textutils.serialize({ home = job.home, facing = sl.facing, spine = sl.role, site = sl.site },
    { compact = true })
  local label = "Miner-" .. DIRNAME[sl.role] .. (sl.site and ("-" .. sl.site) or "")

  setState("Starting turtle #" .. id)
  newTurtle.turnOn()
  local deadline, nextKick = os.clock() + 120, os.clock() + 30
  while true do
    local timer = os.startTimer(1)
    local ev, from, msg, proto = os.pullEvent()
    if ev == "rednet_message" and from == id and proto == PROTOCOL and type(msg) == "table" and msg.type == "hello" then
      rednet.send(id, { type = "package", to = id, files = files, job = job, label = label }, PROTOCOL)
      break
    end
    if ev ~= "timer" or from ~= timer then os.cancelTimer(timer) end
    if os.clock() > deadline then
      return false, "Turtle #" .. id .. " didn't ask for its program: is the floppy in a drive next to it?"
    elseif os.clock() > nextKick then
      pcall(newTurtle.reboot)
      nextKick = os.clock() + 30
    end
  end
  sl.state, sl.id = "flying", id
  cfg.built = cfg.built + 1
  saveCfg()
  note("Turtle #" .. id .. " is on its way to spot " .. i)
  -- wait until it has left the build spot
  deadline = os.clock() + 60
  while turtle.detectUp() and os.clock() < deadline do sleep(1) end
  return true
end

local function buildOne()
  local i, sl
  for k, s in ipairs(cfg.slots) do if not s.state then i, sl = k, s break end end
  if not sl then return false, "No free home spot left." end
  busy = i
  local need, coal = partsFor(sl)
  local ok, err = gatherParts(need)
  if ok then
    setState("Crafting a miner for spot " .. i)
    ok, err = craftMiner()
  end
  if ok then ok, err = deploy(i, sl, coal) end
  if not ok then emptyAll() end
  busy = nil
  return ok, err
end

---------------------------------------------------------------------------
-- Screen, prompt, radio
---------------------------------------------------------------------------
local W, H = term.getSize()
local native = term.current()
local statusWin = window.create(native, 1, 1, W, H - 1)
local promptWin = window.create(native, 1, H, W, 1)

local function draw()
  local t = statusWin
  local color = t.isColor()
  local function c(x) return color and x or colors.white end
  t.setBackgroundColor(colors.black)
  t.clear()
  local y = 1
  local function line(text, col)
    if y > H - 1 then return end
    t.setCursorPos(1, y)
    t.setTextColor(col or colors.white)
    t.write(text:sub(1, W))
    y = y + 1
  end
  line("TURTLE FACTORY", c(colors.yellow))
  line(stateText, c(colors.lightBlue))
  line(("%d to build, %d free spots, %d built"):format(queue, freeSlots(), cfg.built), c(colors.lightGray))
  y = y + 1
  for k, sl in ipairs(cfg.slots) do
    local st = slotState(sl)
    line(("%d %d,%d,%d %s%s: %s"):format(k, sl.x, sl.y, sl.z, DIRNAME[sl.role], sl.site and ("@" .. sl.site) or "", st),
      c(st == "free" and colors.green or st:find("^stuck") and colors.red or colors.white))
  end
  y = y + 1
  for _, l in ipairs(log) do line(l, c(colors.gray)) end
end

local function worker()
  while true do
    if pendingUpdate and not busy then
      pendingUpdate = false
      setState("Updating")
      term.redirect(native)
      term.clear()
      term.setCursorPos(1, 1)
      shell.run("update")
      term.redirect(promptWin)
      statusWin.redraw()
    end
    if queue > 0 then
      local ok, err = buildOne()
      if ok then
        queue = queue - 1
        setState(queue > 0 and "Next one..." or "Idle")
      else
        queue = 0
        note("Stopped: " .. tostring(err))
        setState("Stopped: " .. tostring(err))
      end
      cancelled = false
    else
      os.pullEvent("factory_wake")
    end
  end
end

local function screen()
  draw()
  while true do
    local ev = os.pullEvent()
    if ev == "factory_draw" or ev == "term_resize" then draw() end
  end
end

local function prompt()
  term.redirect(promptWin)
  local history = {}
  while true do
    promptWin.setBackgroundColor(colors.black)
    promptWin.clear()
    promptWin.setCursorPos(1, 1)
    promptWin.setTextColor(colors.yellow)
    promptWin.write("> ")
    promptWin.setTextColor(colors.white)
    local text = read(nil, history)
    if text ~= "" then
      history[#history + 1] = text
      local words = {}
      for w in text:gmatch("%S+") do words[#words + 1] = w end
      if words[1] == "quit" or words[1] == "exit" then return end
      for _, l in ipairs(command(words[1], { table.unpack(words, 2) })) do note(l) end
    end
  end
end

-- 'build' from the pocket panel or any computer, and news from the new turtles
local function radio()
  while true do
    local from, msg = rednet.receive(PROTOCOL)
    if type(msg) == "table" then
      if msg.cmd then
        local reply = command(msg.cmd, msg.args or { msg.n and tostring(msg.n) })
        reply.rid = msg.rid
        reply.state, reply.queue, reply.free, reply.built = stateText, queue, freeSlots(), cfg.built
        rednet.send(from, reply, PROTOCOL)
      elseif (msg.type == "arrived" or msg.type == "stuck") and cfg.slots[msg.slot or 0] then
        local sl = cfg.slots[msg.slot]
        if sl.id == from then
          sl.state = msg.type == "arrived" and "mining" or "stuck"
          saveCfg()
          note("#" .. from .. ": " .. tostring(msg.text))
        end
      end
    end
  end
end

parallel.waitForAny(worker, screen, prompt, radio)
term.redirect(native)
native.setBackgroundColor(colors.black)
native.clear()
native.setCursorPos(1, 1)
print("factory stopped.")
