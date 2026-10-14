-- botlib.lua - shared code for the newer turtles: farmer, fuel, builder, factory (CC: Tweaked)
-- Not a program by itself: those scripts load it with dofile("botlib.lua").
-- install.lua and update.lua fetch it along with them.
--
-- What it gives a bot:
--  * world position + heading that survive reboots (x y z as F3 shows them)
--  * setup with "x y z facing", or found by GPS when there are GPS hosts (gpshost.lua)
--  * moving: step, fly to a spot over obstacles, go home
--  * fuel: lava buckets / coal from the home chest, never anything else
--  * the turtle screen (status, fuel bar, numbers, P / H / Q keys)
--  * the pocket panel: status, pause / resume / come home / update, developer
--    console, and the bot's own commands, all on rednet protocol "bots"

local lib = {}
lib.BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/"
lib.PROTOCOL = "bots"

-- Directions: 0 = north (-z), 1 = east (+x), 2 = south (+z), 3 = west (-x), 4 = up, 5 = down
local UP, DOWN = 4, 5
lib.UP, lib.DOWN = UP, DOWN
lib.DX = { [0] = 0, 1, 0, -1, 0, 0 }
lib.DY = { [0] = 0, 0, 0, 0, 1, -1 }
lib.DZ = { [0] = -1, 0, 1, 0, 0, 0 }
lib.OPP = { [0] = 2, 3, 0, 1, 5, 4 }
lib.DIRS = { north = 0, east = 1, south = 2, west = 3, n = 0, e = 1, s = 2, w = 3 }
lib.DIRNAME = { [0] = "north", "east", "south", "west", "up", "down" }
local DX, DY, DZ = lib.DX, lib.DY, lib.DZ

-- What it may burn: lava buckets and coal. Never logs, planks or crops.
lib.FUEL_VALUE = {
  ["minecraft:lava_bucket"] = 1000, ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80,
  ["minecraft:coal_block"] = 800, ["minecraft:blaze_rod"] = 120,
}

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------
function lib.loadTable(path)
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

function lib.saveTable(path, t)
  local tmp = path .. ".tmp"
  local h = fs.open(tmp, "w")
  h.write(textutils.serialize(t, { compact = true }))
  h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
end

-- "<bot> update": latest version from GitHub (update.lua does the work, fetched here if missing)
function lib.update()
  if not fs.exists("update.lua") then
    shell.run("wget", lib.BASE .. "update.lua", "update.lua")
  end
  shell.run("update")
end

function lib.startup(program)
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("' .. program .. '")\n')
  h.close()
end

---------------------------------------------------------------------------
-- Blocks
---------------------------------------------------------------------------
local function hasTag(info, t) return info and info.tags and info.tags[t] end
lib.hasTag = hasTag

function lib.isChest(info)
  if not info then return false end
  if info.name:find("chest") or info.name:find("barrel") then return true end
  return hasTag(info, "c:chests") or hasTag(info, "forge:chests") or hasTag(info, "c:barrels")
end

-- Blocks a bot never digs, whatever it's doing
local PROTECT = { "chest", "barrel", "shulker", "computercraft:", "furnace", "smoker", "crafting_table", "_bed",
  "spawner", "beacon", "anvil", "enchanting", "hopper", "dropper", "dispenser", "brewing", "_door", "bedrock",
  "end_portal", "nether_portal", "reinforced_deepslate" }
function lib.isProtected(info)
  if not info then return false end
  for _, p in ipairs(PROTECT) do
    if info.name:find(p, 1, true) then return true end
  end
  return false
end

local SOFT = { "leaves", "vine", "short_grass", "tall_grass", "fern", "flower", "dead_bush", "snow", "lichen",
  "moss_carpet", "sweet_berry", "dandelion", "poppy", "tulip", "orchid", "allium", "bluet", "daisy",
  "cornflower", "lily_of_the_valley", "rose_bush", "lilac", "peony", "sunflower", "cobweb", "torch" }
-- Leaves, plants, snow layers, torches: things in the way that any bot may cut
function lib.isSoft(info)
  if not info then return false end
  if info.name:find("pot") then return false end -- flower pots
  if hasTag(info, "minecraft:replaceable") or hasTag(info, "minecraft:leaves") or hasTag(info, "minecraft:flowers") then
    return true
  end
  if info.name == "minecraft:grass" then return true end -- short grass before 1.20.3
  for _, p in ipairs(SOFT) do
    if info.name:find(p, 1, true) then return true end
  end
  return false
end

-- air, water, lava, soft, solid
function lib.classify(info)
  if not info then return "air" end
  local n = info.name
  if n:find("lava") and not n:find("cauldron") then return "lava" end
  if n == "minecraft:water" or n == "minecraft:bubble_column" then return "water" end
  if lib.isSoft(info) then return "soft" end
  return "solid"
end

function lib.isLiquid(info)
  local c = lib.classify(info)
  return c == "water" or c == "lava"
end

---------------------------------------------------------------------------
-- Setup: where the turtle is and which way it faces
---------------------------------------------------------------------------
-- GPS position, rounded; nil without GPS hosts
function lib.locate(timeout)
  if not gps then return nil end
  local x, y, z = gps.locate(timeout or 2)
  if not x then return nil end
  return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
end

-- Facing by GPS: step forward (or back), see which way it went, step back
local function gpsFacing(x, y, z)
  local moved, back = turtle.forward(), false
  if not moved then moved, back = turtle.back(), true end
  if not moved then return nil end
  local x2, _, z2 = lib.locate()
  if back then turtle.forward() else turtle.back() end
  if not x2 then return nil end
  local dx, dz = x2 - x, z2 - z
  if back then dx, dz = -dx, -dz end
  if dz < 0 then return 0 elseif dx > 0 then return 1 elseif dz > 0 then return 2 elseif dx < 0 then return 3 end
  return nil
end

-- Reads "x y z facing" from args starting at index i (or finds them by GPS).
-- Returns { x =, y =, z =, f = } and the index of the next argument, or nil and a message.
function lib.parsePlace(args, i)
  local x, y, z = tonumber(args[i]), tonumber(args[i + 1]), tonumber(args[i + 2])
  local f = lib.DIRS[(args[i + 3] or ""):lower()]
  if x and y and z and f then return { x = x, y = y, z = z, f = f }, i + 4 end
  if x and y and z then return nil, "Facing missing: north, east, south or west" end
  -- no coordinates: GPS, with an optional facing ("<bot> setup north ...")
  f = lib.DIRS[(args[i] or ""):lower()]
  local gx, gy, gz = lib.locate()
  if not gx then return nil, "No GPS here: give the turtle's x y z (F3) and the way it faces" end
  local gf = f or (turtle and gpsFacing(gx, gy, gz))
  if not gf then return nil, "GPS found " .. gx .. " " .. gy .. " " .. gz .. ", but not the facing: add north/east/south/west" end
  return { x = gx, y = gy, z = gz, f = gf }, f and (i + 1) or i
end

---------------------------------------------------------------------------
-- Developer commands from the pocket panel's console (same as lumber.lua): info, log,
-- ls, cat, get, reboot, and put / rm / lua once the computer has a dev.key file.
---------------------------------------------------------------------------
function lib.devCommand(m, logFile, program, reply)
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

---------------------------------------------------------------------------
-- A bot
---------------------------------------------------------------------------
-- name: file names and protocol kind ("farmer"); opts: title, color, home (place
-- table, normally cfg.home), fuelTo (refuel up to), minFuel, hop
function lib.bot(name, cfg, opts)
  opts = opts or {}
  local B = { name = name, cfg = cfg, title = opts.title or name:upper(), color = opts.color or colors.blue }
  local STATE_FILE, LOG_FILE = name .. ".state", name .. ".log"
  B.LOG_FILE = LOG_FILE
  B.home = cfg.home
  B.fuelTo = opts.fuelTo or 5000
  B.minFuel = opts.minFuel or 300
  B.hop = opts.hop or 3
  local RETRY = 20

  local st = lib.loadTable(STATE_FILE) or {}
  B.st = st
  st.pos = st.pos or { x = B.home.x, y = B.home.y, z = B.home.z }
  st.h = st.h or B.home.f
  local pos = st.pos
  B.pos = pos

  function B.save() lib.saveTable(STATE_FILE, st) end
  function B.at() return pos.x .. "," .. pos.y .. "," .. pos.z end
  function B.atHome() return pos.x == B.home.x and pos.y == B.home.y and pos.z == B.home.z end

  local function applyMove(d) pos.x, pos.y, pos.z = pos.x + DX[d], pos.y + DY[d], pos.z + DZ[d] end

  -- A reboot during a move: the fuel tells whether the move happened
  if st.pending then
    local f = turtle.getFuelLevel()
    if f ~= "unlimited" and f < st.pending.fuel then applyMove(st.pending.d) end
    st.pending = nil
    B.save()
  end

  local ui = { status = "Starting", draw = function() end }
  B.ui = ui
  function B.setStatus(s)
    if s == ui.status then return end
    ui.status = s
    ui.draw()
  end

  -- Remember an error in <name>.log (last 40 lines)
  function B.logError(msg)
    msg = tostring(msg)
    pcall(function()
      local lines = {}
      if fs.exists(LOG_FILE) then
        local h = fs.open(LOG_FILE, "r")
        for line in h.readAll():gmatch("[^\n]+") do lines[#lines + 1] = line end
        h.close()
      end
      ui.lastError = os.date("%H:%M") .. " " .. msg
      lines[#lines + 1] = os.date("%Y-%m-%d %H:%M") .. " " .. B.at() .. " " .. msg
      while #lines > 40 do table.remove(lines, 1) end
      local h = fs.open(LOG_FILE, "w")
      h.write(table.concat(lines, "\n") .. "\n")
      h.close()
    end)
  end

  -- Pause or "come home" asked: jobs call this between steps and stop when it's true
  function B.stopAsked() return st.paused or ui.homeNow or ui.updateNow end

  ---------------------------------------------------------------------------
  -- Inventory and fuel
  ---------------------------------------------------------------------------
  function B.fuel()
    local f = turtle.getFuelLevel()
    if f == "unlimited" then return math.huge end
    return f
  end

  function B.findSlot(test)
    for s = 1, 16 do
      local d = turtle.getItemDetail(s)
      if d and test(d) then return s end
    end
    return nil
  end

  function B.count(test)
    local n = 0
    for s = 1, 16 do
      local d = turtle.getItemDetail(s)
      if d and test(d) then n = n + d.count end
    end
    return n
  end

  function B.freeSlots()
    local n = 0
    for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
    return n
  end

  function B.emptySlot()
    for s = 1, 16 do if turtle.getItemCount(s) == 0 then return s end end
    return nil
  end

  local FUEL = opts.fuelValue or lib.FUEL_VALUE
  B.FUEL = FUEL
  function B.isFuel(d) return FUEL[d.name] ~= nil end

  -- Burn fuel items from the inventory up to 'target', without wasting any over the limit
  function B.burn(target)
    if B.fuel() >= target then return true end
    local limit = turtle.getFuelLimit()
    for s = 1, 16 do
      local d = turtle.getItemDetail(s)
      if d and FUEL[d.name] then
        turtle.select(s)
        while B.fuel() < target and turtle.getItemCount(s) > 0 and B.fuel() + FUEL[d.name] <= limit do
          if not turtle.refuel(1) then break end
        end
      end
      if B.fuel() >= target then break end
    end
    turtle.select(1)
    return B.fuel() >= target
  end

  -- Fuel to get home from here (up, across, down)
  function B.homeCost()
    return math.abs(pos.x - B.home.x) + math.abs(pos.z - B.home.z) + math.abs(pos.y - B.home.y) + 2 * B.hop + 20
  end

  -- Enough fuel to do 'extra' more and still get home? Burns carried fuel if needed.
  function B.fuelFor(extra)
    local need = B.homeCost() + extra + 30
    return B.fuel() >= need or B.burn(need)
  end

  ---------------------------------------------------------------------------
  -- Moving
  ---------------------------------------------------------------------------
  -- The new heading is saved BEFORE each turn (same as miner.lua)
  function B.face(d)
    if d >= 4 then return end
    while st.h ~= d do
      if (d - st.h) % 4 == 3 then
        st.h = (st.h + 3) % 4
        B.save()
        turtle.turnLeft()
      else
        st.h = (st.h + 1) % 4
        B.save()
        turtle.turnRight()
      end
    end
  end

  function B.inspect(d)
    local ok, info
    if d == UP then ok, info = turtle.inspectUp()
    elseif d == DOWN then ok, info = turtle.inspectDown()
    else B.face(d) ok, info = turtle.inspect() end
    if ok then return info end
    return nil
  end

  function B.dig(d)
    if d == UP then return turtle.digUp()
    elseif d == DOWN then return turtle.digDown() end
    B.face(d)
    return turtle.dig()
  end

  -- Place the item in 'slot' on side d
  function B.place(d, slot)
    if slot then turtle.select(slot) end
    local ok
    if d == UP then ok = turtle.placeUp()
    elseif d == DOWN then ok = turtle.placeDown()
    else B.face(d) ok = turtle.place() end
    turtle.select(1)
    return ok
  end

  function B.drop(d, n)
    if d == UP then return turtle.dropUp(n) elseif d == DOWN then return turtle.dropDown(n) end
    B.face(d)
    return turtle.drop(n)
  end

  function B.suck(d, n)
    if d == UP then return turtle.suckUp(n) elseif d == DOWN then return turtle.suckDown(n) end
    B.face(d)
    return turtle.suck(n)
  end

  local function rawMove(d)
    local mv = turtle.forward
    if d == UP then mv = turtle.up elseif d == DOWN then mv = turtle.down else B.face(d) end
    st.pending = { d = d, fuel = turtle.getFuelLevel() }
    B.save()
    local ok = mv()
    if ok then applyMove(d) end
    st.pending = nil
    B.save()
    return ok
  end

  -- One step. mode "travel" cuts only soft things (leaves, plants); mode "dig" digs
  -- anything that isn't protected. Liquids are moved through. Returns false when blocked.
  function B.step(d, mode)
    for attempt = 1, RETRY do
      local info = B.inspect(d)
      local c = lib.classify(info)
      if c == "soft" or (c == "solid" and mode == "dig" and not lib.isProtected(info)) then
        B.dig(d)
      elseif c == "solid" then
        return false
      end
      if B.fuel() == 0 and not B.burn(1) then error("Out of fuel", 0) end
      if rawMove(d) then return true end
      -- a mob or player in the way: wait first, hit it only if it doesn't go away;
      -- sand or gravel that fell in: dig again
      if attempt > 5 and B.inspect(d) == nil then
        if d == UP then turtle.attackUp() elseif d == DOWN then turtle.attackDown() else turtle.attack() end
      end
      if B.inspect(d) == nil then sleep(0.5) end
    end
    return false
  end

  -- Up to height y. Something above (an overhang): slide sideways and try again.
  function B.rise(y, mode)
    local slides = 0
    while pos.y < y do
      if not B.step(UP, mode) then
        local moved = false
        for d = 0, 3 do
          if B.step(d, mode) then moved = true break end
        end
        slides = slides + 1
        if not moved or slides > 8 then error("Can't get up at " .. B.at(), 0) end
      end
    end
  end

  -- Fly to column x,z at least 'alt' high; goes higher when something is in the way
  function B.flyTo(tx, tz, alt, mode)
    B.rise(alt, mode)
    local top = alt + 48
    while pos.x ~= tx or pos.z ~= tz do
      local d
      if pos.x ~= tx then d = pos.x < tx and 1 or 3 else d = pos.z < tz and 2 or 0 end
      if not B.step(d, mode) then
        if pos.y >= top then error("Can't fly past " .. B.at(), 0) end
        B.rise(pos.y + 1, mode)
      end
    end
  end

  -- Straight down (or up) to height y in this column
  function B.toHeight(y, mode)
    while pos.y > y do
      if not B.step(DOWN, mode) then error("Something blocks the way down at " .. B.at(), 0) end
    end
    if pos.y < y then B.rise(y, mode) end
  end

  -- Go to x,y,z: up over everything, across, down. Neighbouring spots are walked straight.
  function B.goTo(x, y, z, mode)
    if pos.x == x and pos.y == y and pos.z == z then return end
    if math.abs(pos.x - x) + math.abs(pos.z - z) + math.abs(pos.y - y) == 1 then
      local d = x > pos.x and 1 or x < pos.x and 3 or z > pos.z and 2 or z < pos.z and 0 or y > pos.y and UP or DOWN
      if B.step(d, mode) then return end
    end
    if pos.x ~= x or pos.z ~= z then B.flyTo(x, z, math.max(pos.y, y) + B.hop, mode) end
    B.toHeight(y, mode)
  end

  function B.goHome()
    if B.atHome() then B.face(B.home.f) return end
    B.setStatus("Going home")
    B.goTo(B.home.x, B.home.y, B.home.z)
    B.face(B.home.f)
  end

  ---------------------------------------------------------------------------
  -- Chests
  ---------------------------------------------------------------------------
  local SIDE = { [UP] = "top", [DOWN] = "bottom" }
  -- Peripheral name of the chest on side d (front after turning that way)
  local function chestOn(d)
    if SIDE[d] then return SIDE[d] end
    B.face(d)
    return "front"
  end

  -- Count items matching 'test' in the chest on side d (nil: can't look inside)
  function B.chestCount(d, test)
    local side = chestOn(d)
    local ok, n = pcall(function()
      local c = peripheral.wrap(side)
      if not c or not c.list then return nil end
      local n = 0
      for _, it in pairs(c.list()) do
        if test(it) then n = n + it.count end
      end
      return n
    end)
    return ok and n or nil
  end

  -- Chest on side d: move a stack that matches 'test' into its first slot, so the next
  -- suck takes exactly that. False if there is none (or no peripheral access).
  local function toFirstSlot(side, test)
    local ok, res = pcall(function()
      local c = peripheral.wrap(side)
      if not c or not c.list then return false end
      local list = c.list()
      if list[1] and test(list[1]) then return true end
      local from
      for slot, it in pairs(list) do
        if test(it) and (not from or slot < from) then from = slot end
      end
      if not from then return false end
      local me = peripheral.getName(c)
      if list[1] then
        local free
        for e = c.size(), 2, -1 do if not list[e] then free = e break end end
        if not free then return false end
        c.pushItems(me, 1, 64, free)
      end
      return c.pushItems(me, from, 64, 1) > 0
    end)
    return ok and res
  end

  -- Take up to n items matching 'test' out of the chest on side d. Without peripheral
  -- access it takes stacks one by one and puts back what doesn't match.
  -- Returns how many it took.
  function B.take(d, test, n)
    local side = chestOn(d)
    local got = 0
    for _ = 1, 27 do
      if got >= n then break end
      local s = B.emptySlot()
      if not s then break end
      turtle.select(s)
      if toFirstSlot(side, test) then
        if not B.suck(d, math.min(64, n - got)) then break end
        got = got + turtle.getItemCount(s)
      else
        -- peripheral missing (or nothing matches): look through the stacks one by one
        if peripheral.wrap(side) and peripheral.wrap(side).list then break end
        if not B.suck(d) then break end
        local it = turtle.getItemDetail(s)
        if it and test(it) then
          got = got + it.count
        else
          B.drop(d) -- not wanted: back it goes (it lands in the first free slot)
          break
        end
      end
    end
    turtle.select(1)
    return got
  end

  -- Everything into the chest on side d except what keep(detail) says to keep (a number).
  -- False if the chest is full.
  function B.unload(d, keep)
    local kept = {}
    local ok = true
    for s = 1, 16 do
      local it = turtle.getItemDetail(s)
      if it then
        local k = 0
        if keep then
          local want = keep(it) or 0
          k = math.min(it.count, math.max(0, want - (kept[it.name] or 0)))
          kept[it.name] = (kept[it.name] or 0) + k
        end
        if it.count > k then
          turtle.select(s)
          if not B.drop(d, it.count - k) then ok = false end
        end
      end
    end
    turtle.select(1)
    return ok
  end

  -- At home: top up with lava buckets (or coal) from the chest on side d.
  -- Empty buckets go back with the unload that follows.
  function B.refuelFrom(d)
    B.burn(B.fuelTo)
    for _ = 1, 16 do
      if B.fuel() + 1000 > B.fuelTo and B.fuel() >= B.fuelTo / 2 then break end
      if B.take(d, B.isFuel, 1) == 0 then break end
      B.burn(B.fuelTo)
    end
  end

  ---------------------------------------------------------------------------
  -- Screen
  ---------------------------------------------------------------------------
  local W, H = term.getSize()
  local COLOR = term.isColour and term.isColour()
  local function col(c, plain) if COLOR then return c end return plain or colors.white end
  B.col = col

  local function fmt(n)
    if n == math.huge then return "unlimited" end
    if type(n) ~= "number" then return tostring(n) end
    if n >= 10000 then return string.format("%.1fk", n / 1000) end
    return tostring(math.floor(n))
  end
  B.fmt = fmt

  local function row(y, text, fg, bg)
    term.setCursorPos(1, y)
    term.setBackgroundColor(bg or colors.black)
    term.setTextColor(fg or colors.white)
    term.clearLine()
    term.write(text:sub(1, W))
  end

  local function pair(x, y, l, v)
    term.setCursorPos(x, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(col(colors.lightGray))
    term.write(l .. " ")
    term.setTextColor(colors.white)
    term.write(tostring(v))
  end

  function B.state()
    if st.paused then return B.atHome() and "PAUSED" or "PAUSING", col(colors.yellow) end
    if ui.homeNow and not B.atHome() then return "COMING HOME", col(colors.orange) end
    return "RUNNING", col(colors.lime)
  end

  local function drawScreen()
    local name, stateColor = B.state()
    row(1, " " .. B.title, colors.white, col(B.color, colors.gray))
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
    local f = B.fuel()
    row(5, "")
    term.setCursorPos(2, 5)
    term.setTextColor(col(colors.lightGray))
    term.write("Fuel ")
    local barW = W - 15
    local frac = f == math.huge and 1 or math.min(1, f / B.fuelTo)
    local fill = math.floor(barW * frac + 0.5)
    local barColor = (f < B.minFuel * 2) and col(colors.red) or (f < B.fuelTo / 4) and col(colors.orange) or col(colors.lime)
    term.setBackgroundColor(barColor)
    term.write(string.rep(" ", fill))
    term.setBackgroundColor(col(colors.gray, colors.gray))
    term.write(string.rep(" ", barW - fill))
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.write(" " .. fmt(f))
    -- the bot's own numbers, two per line
    local lines = B.lines and B.lines() or {}
    local y = 7
    row(6, "")
    for i = 1, #lines, 2 do
      if y > H - 2 then break end
      row(y, "")
      pair(2, y, lines[i][1], lines[i][2])
      if lines[i + 1] then pair(math.floor(W / 2) + 2, y, lines[i + 1][1], lines[i + 1][2]) end
      y = y + 1
    end
    for yy = y, H - 1 do row(yy, "") end
    if ui.lastError then row(H - 1, " ! " .. ui.lastError, col(colors.red)) end
    local keys = st.paused and " [P] go on  [Q] quit" or " [P] pause  [H] come home  [Q] quit"
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
            print(B.title .. " stopped. Type " .. name .. " to start it again.")
            return
          end
        elseif a == keys.p then
          st.paused = not st.paused
          B.save()
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
  -- Pocket panel (protocol "bots"): status, pause / resume / home / update, dev console,
  -- and the bot's own commands (B.onCommand)
  ---------------------------------------------------------------------------
  function B.stateMessage(rid, note)
    local name = B.state()
    return { type = "bot_state", rid = rid, kind = B.name, title = B.title, label = os.getComputerLabel(),
      state = name, status = ui.status, fuel = B.fuel(), fuelMax = B.fuelTo, paused = st.paused,
      err = ui.lastError, x = pos.x, y = pos.y, z = pos.z, home = { x = B.home.x, y = B.home.y, z = B.home.z },
      lines = B.lines and B.lines() or {}, actions = B.actions or {}, note = note }
  end

  local function radio()
    local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
    if not modem then while true do os.pullEvent("bots_never") end end
    rednet.open(peripheral.getName(modem))
    rednet.host(lib.PROTOCOL, name .. "-" .. os.getComputerID())
    while true do
      local id, m = rednet.receive(lib.PROTOCOL)
      if type(m) == "table" and m.type == "dev" then
        lib.devCommand(m, LOG_FILE, name, function(r) rednet.send(id, r, lib.PROTOCOL) end)
      elseif type(m) == "table" and m.cmd then
        local note
        if m.cmd == "pause" then st.paused = true B.save() note = "Pausing"
        elseif m.cmd == "resume" then st.paused = false B.save() note = "Running again"
        elseif m.cmd == "home" then ui.homeNow = true note = "Coming home"
        elseif m.cmd == "update" then ui.updateNow, ui.homeNow = true, true note = "Updating when home"
        elseif m.cmd ~= "status" and B.onCommand then
          local ok, res = pcall(B.onCommand, m)
          note = ok and res or ("Error: " .. tostring(res))
        end
        if m.cmd ~= "status" then ui.draw() end
        rednet.send(id, B.stateMessage(m.rid, note), lib.PROTOCOL)
      end
    end
  end

  ---------------------------------------------------------------------------
  -- Main loop. jobs: { service = at home (unload, refuel), trip = one round of work,
  -- returns nil (wait jobs.wait seconds), "again" (go straight on), "fuel" or "wait"
  -- (wait without changing the status),
  -- recover = after a reboot or error (default: go home) }
  ---------------------------------------------------------------------------
  local function guarded(fn, ...)
    local args = table.pack(...)
    while true do
      local ok, err = pcall(fn, table.unpack(args, 1, args.n))
      if ok then return end
      if err == "Terminated" then error(err, 0) end
      B.logError(err)
      B.setStatus("STUCK: " .. tostring(err))
      sleep(30)
    end
  end

  -- Sleep, but wake up for pause / come home / a new job
  function B.wait(secs, why)
    if why then B.setStatus(why) end
    local untilT = os.clock() + secs
    while os.clock() < untilT do
      if st.paused or ui.homeNow or ui.updateNow or ui.wake then break end
      sleep(1)
    end
    ui.wake = false
  end
  function B.wakeUp() ui.wake = true end

  local function worker(jobs)
    guarded(jobs.recover or B.goHome)
    while true do
      if B.atHome() then guarded(jobs.service) end -- (a builder rebooted mid-job carries on first)
      if ui.updateNow then
        ui.updateNow = false
        B.setStatus("Updating from GitHub")
        lib.update() -- reboots when there's a new version
      end
      ui.homeNow = false
      if st.paused then
        B.setStatus("Paused at home. Press P to go on")
        while st.paused do sleep(1) end
      elseif B.fuel() < B.minFuel then
        B.wait(30, "Out of fuel: put lava buckets or coal in my chest")
      else
        local ok, res = pcall(jobs.trip)
        if not ok then
          if res == "Terminated" then error(res, 0) end
          B.logError(res)
          B.setStatus("Error: " .. tostring(res))
          res = nil
        end
        guarded(jobs.recover or B.goHome)
        if res == "fuel" then
          if B.atHome() then guarded(jobs.service) end
          B.wait(jobs.wait or 120, "Low on fuel: waiting for lava buckets or coal")
        elseif res == "wait" then
          B.wait(jobs.wait or 120) -- the trip set the status: it waits for something
        elseif res ~= "again" then
          if B.atHome() then guarded(jobs.service) end
          B.wait(jobs.wait or 120, jobs.idleText or "Waiting")
        end
      end
    end
  end

  function B.run(jobs)
    term.clear()
    turtle.select(1)
    parallel.waitForAny(function() worker(jobs) end, screen, radio)
  end

  return B
end

return lib
