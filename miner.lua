-- miner.lua - Mine Army turtle (CC: Tweaked)
--
-- One-time setup (see README):
--   miner setup <y> [role]    without GPS: only its height (F3); home is its own x 0 z 0
--   miner setup [role]        with GPS: it finds its position and facing by itself
--   miner setup hub <facing> <role> [left|right]   no GPS: measures where the hub is
--                             (needs 'hub pos <x> <y> <z>' once on the hub)
--   miner setup <x> <y> <z> <facing> <role>
--     x y z   = world coordinates of the turtle (F3), e.g. 120 64 -350
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

local C = {} -- tuning values and fixed messages (a table: CC only allows 200 locals in total)
C.BRANCH_LEN = 64      -- default branch length (the hub can override this)
C.BRANCH_GAP = 4       -- thorough mode: a branch every 4 blocks = 3 blocks between
C.FAST_GAP = 2         -- fast mode: a branch every 2 blocks = 1 block between, no wall checks
C.FUEL_MARGIN = 64     -- extra fuel on top of the way home
C.MIN_TRIP_FUEL = 2000 -- try to refuel at least this much
C.JUNK_EVERY = 10      -- drop junk every ~10 dug blocks
C.MAX_VEIN = 64        -- max blocks per vein
C.REACH = 96           -- never go further than this from the shaft (stay in loaded chunks)
C.LAYER_STEP = 3       -- when a level is full: next layer this many blocks higher
C.MAX_LAYERS = 4       -- layers per ore before the area counts as full
C.RETRY = 20

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
if args[1] == "update" then
  -- turtles get new versions from the hub, so they all run the same one
  print("Mining turtles update through the hub: type 'hub update' on the hub")
  print("(or press Update all on the pocket panel). They update when they get home.")
  return
end

-- (defined this early on purpose: CC counts the locals of every enclosing function,
-- so these deep functions must sit before miner.lua's many top-level locals)
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
  elseif op == "known" then
    -- the blocks it remembers around it, for the pocket's map (no moving, any time)
    r.known = hooks and hooks.known and hooks.known(32) or {}
    out(#r.known .. " blocks")
  elseif op == "drive" then
    local hk = hooks or devDriveHooks()
    local why = not turtle and "This is not a turtle" or (hk.busy and hk.busy())
    local act = tostring(m.act or "scan")
    local seen = hk.known and hk.known() or {} -- blocks it remembers, then what it sees now
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
  -- Three ways (the hole in front, its chest behind it or to its left or right):
  --   miner setup <x> <y> <z> <facing> <role>   world coordinates (F3), as before
  --   miner setup [role]                        with GPS: position and facing found by itself
  --   miner setup <y> [role]                    no GPS: only its height; its own home is
  --                                             x 0 z 0, facing "north" = the way it faces
  -- role = direction of its main tunnel; without GPS also forward/right/back/left.
  -- Leave it out (or "auto") and the hub hands one out. name=<name> sets its label.
  local n, words, name = {}, {}, nil
  for i = 2, #args do
    if args[i]:lower():find("^name=") then name = args[i]:sub(6)
    elseif tonumber(args[i]) then n[#n + 1] = tonumber(args[i])
    else words[#words + 1] = args[i]:lower() end
  end
  local REL = { forward = 0, right = 1, back = 2, left = 3 }
  local hx, hy, hz, facing, role, loc
  local why -- what went wrong, shown under the usage
  -- Its hole goes in front of it. Placed facing the chest: turn around first. No hole
  -- there yet: dig the spot in front (the shaft below gets dug on the first trip).
  local function blocked(dig)
    local ok, info = (dig == "down" and turtle.inspectDown or turtle.inspect)()
    return ok and info.name:find("chest") or ok and info.name:find("barrel") or ok and info.name:find("shulker")
      or ok and info.name:find("computer") or ok and info.name:find("turtle")
  end
  local turned = blocked() and true or false
  if turned then turtle.turnRight() turtle.turnRight() print("Facing the chest: turned around, the hole goes this way.") end
  if turtle.detect() and not blocked() then
    for _ = 1, 8 do if not turtle.dig() then break end end -- gravel/sand can fall in
    if not turtle.detect() then print("Dug the start of its hole in front of it.") end
  end
  if words[1] == "hub" then
    -- No GPS, but the hub knows where it is: measure the radio distance to the hub
    -- from 3 spots (here, one step into the hole, one down the hole) to find where
    -- the hub is from here; with the facing that gives the world position.
    facing = DIRS[words[2] or ""]
    if facing and turned then facing = (facing + 2) % 4 end
    if words[3] == "left" or words[3] == "right" then table.insert(words, 3, "auto") end
    role = DIRS[words[3] or "auto"] or (not words[3] or words[3] == "auto") and "auto"
    local side = (words[4] == "left") and -1 or 1
    local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
    local function hubDist()
      modem.transmit(16524, 16524, { type = "where_hub" })
      local t = os.startTimer(3)
      while true do
        local ev, a, ch, _, msg, dist = os.pullEvent()
        if ev == "timer" and a == t then return nil end
        if ev == "modem_message" and ch == 16524 and type(msg) == "table" and msg.type == "hub_here"
          and type(dist) == "number" then return dist, msg end
      end
    end
    if not (facing and role) then
      print("Usage: miner setup hub <facing> [role] [left|right]")
      print("  facing: the way it faces (F3), role: its main tunnel")
      print("  left/right: which side of the turtle the hub is on")
      return
    elseif not modem then print("Needs a wireless or ender modem.") return
    elseif turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 4 then
      print("Put a little fuel in it first (refuel), it moves 2 blocks and back.") return
    end
    modem.open(16524)
    local d0, at = hubDist()
    if not d0 then print("No answer from the hub. Is it running (new version), and did you give it its position? (hub pos <x> <y> <z>)") return end
    if not turtle.forward() then print("Couldn't step forward into its hole.") return end
    local d1 = hubDist()
    local down = turtle.down()
    if not down and turtle.detectDown() and not blocked("down") then turtle.digDown() down = turtle.down() end
    local d2 = down and hubDist()
    if down then turtle.up() end
    turtle.back()
    if not (d1 and d2) then print("Couldn't measure from inside the hole (is it 2 deep?).") return end
    -- the hub as seen from here: x = right, y = up, z = backward (turtle faces -z)
    local lz = math.floor((d1 * d1 - d0 * d0 - 1) / 2 + 0.5)
    local ly = math.floor((d2 * d2 - d1 * d1 - 1) / 2 + 0.5)
    local lx = side * math.floor(math.sqrt(math.max(0, d0 * d0 - ly * ly - lz * lz)) + 0.5)
    local R, F = (facing + 1) % 4, facing
    hx = at.x - (lx * DX[R] - lz * DX[F])
    hy = at.y - ly
    hz = at.z - (lx * DZ[R] - lz * DZ[F])
    print("The hub is " .. math.abs(lx) .. (lx < 0 and " left, " or " right, ") .. math.abs(lz) .. (lz > 0 and " behind, " or " ahead, ")
      .. math.abs(ly) .. (ly < 0 and " down." or " up."))
  elseif #n >= 3 then
    hx, hy, hz = n[1], n[2], n[3]
    facing, role = DIRS[words[1] or ""], DIRS[words[2] or "auto"] or (not words[2] or words[2] == "auto") and "auto"
    if facing and turned then facing = (facing + 2) % 4 end
  elseif #n == 1 then
    hx, hy, hz, facing, loc = 0, n[1], 0, 0, true
    role = DIRS[words[1] or "auto"] or REL[words[1] or ""] or (not words[1] or words[1] == "auto") and "auto"
  elseif gps then
    -- GPS: where it is, and which way it faces (one step into its hole and back)
    local function fix()
      local x, y, z = gps.locate(2)
      if x then return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5) end
    end
    hx, hy, hz = fix()
    local stepped, stepWhy
    if hx then stepped, stepWhy = turtle.forward() end
    if stepped then
      local x, _, z = fix()
      turtle.back()
      for d = 0, 3 do if x and DX[d] == x - hx and DZ[d] == z - hz then facing = d end end
    end
    role = DIRS[words[1] or "auto"] or (facing and REL[words[1] or ""] and (facing + REL[words[1]]) % 4)
      or (not words[1] or words[1] == "auto") and "auto"
    if not hx then
      why = "No GPS signal here. Without GPS use: miner setup <y> (its height), or miner setup hub ..."
    elseif not stepped then
      why = "GPS works, but it can't step into the hole in front of it to find its facing ("
        .. tostring(stepWhy) .. (turtle.getFuelLevel() == 0 and ": give it some fuel first, refuel" or "")
        .. "). It needs fuel and an open 1x1 hole in front."
    elseif not facing then why = "GPS lost its signal while it stepped into the hole. Try again." end
  end
  if not role and not why then why = "Unknown role. Use north, east, south or west (or leave it out)." end
  if not (hx and hy and hz and facing and role) then
    print("Usage:")
    print("  miner setup <y> [role]     no GPS: just its height (F3)")
    print("  miner setup [role]         with GPS")
    print("  miner setup hub <facing> [role] [left|right]")
    print("  miner setup <x> <y> <z> <facing> [role]")
    print("role: the direction of its main tunnel, north/east/")
    print("south/west (no GPS: also forward/right/back/left).")
    print("Leave it out and the hub picks one.")
    print("Add name=<name> to give it a name.")
    if why then -- last, so it stays on the turtle's small screen
      if term.isColour and term.isColour() then term.setTextColour(colors.red) end
      print(why)
      if term.isColour and term.isColour() then term.setTextColour(colors.white) end
    end
    return
  end
  -- Its chest: behind it, or else to its right or left (the hole is in front)
  local chest, chests = nil, 0
  for _, turn in ipairs({ 2, 1, 3 }) do
    for _ = 1, turn do turtle.turnRight() end
    local found, info = turtle.inspect()
    for _ = turn, 3 do turtle.turnRight() end
    if found and (info.name:find("chest") or info.name:find("barrel") or info.name:find("shulker")) then
      chest, chests = chest or (facing + turn) % 4, chests + 1
    end
  end
  if not chest then print("WARNING: no chest next to the turtle (behind, left or right)!")
  elseif chests > 1 then print("WARNING: more than one chest next to it. Keep one, or it can get confused about its direction.") end
  if role == "auto" then role = nil end -- the hub hands out a direction on the first start
  saveTable(CFG_FILE, { home = { x = hx, y = hy, z = hz }, facing = facing, spine = role, loc = loc, chest = chest })
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("miner")\n')
  h.close()
  os.setComputerLabel(name and name ~= "" and name:sub(1, 32)
    or (role and ("Miner-" .. DIRNAME[role]) or ("Miner-" .. os.getComputerID())))
  if loc then
    print("Saved. Height " .. hy .. ", its own home is x 0 z 0, facing 'north'.")
    print(role and ("Main tunnel " .. ({ [0] = "forward", "to its right", "backward", "to its left" })[role]
      .. " (" .. DIRNAME[role] .. ")") or "Main tunnel: the hub picks it on the first start")
    print("No GPS: it won't show on the pocket's map.")
  else
    print("Saved. Home " .. hx .. "," .. hy .. "," .. hz .. " facing " .. DIRNAME[facing])
    print(role and ("Main tunnel " .. DIRNAME[role] .. ", branches " .. DIRNAME[(role + 1) % 4])
      or "Main tunnel: the hub picks it on the first start")
  end
  print("Name: " .. os.getComputerLabel())
  print("Start with: miner   (or reboot the turtle)")
  return
end

if not turtle then error("miner.lua only runs on a turtle", 0) end
local cfg = loadTable(CFG_FILE)
if not cfg then
  print("Not set up yet. First: miner setup (see: miner setup help)")
  return
end
if args[1]=="service" then
  cfg.warehouse=cfg.warehouse or {enabled=false}
  if args[2]=="enable" or args[2]=="disable" then
    assert(args[2]=="disable" or cfg.mining and cfg.mining.enabled==true and cfg.warehouse.drop and cfg.warehouse.charger,"configure mining, drop and charger first")
    cfg.warehouse.enabled=args[2]=="enable"
  elseif args[2]=="drop" or args[2]=="charger" then
    assert(type(args[3])=="string" and #args[3]>0 and #args[3]<=64,"site name required") cfg.warehouse[args[2]]=args[3]
  elseif args[2]=="fuel" then
    local n=tonumber(args[3]) assert(n and n%1==0 and n>=1 and n<=100000,"fuel target must be 1 through 100000") cfg.warehouse.targetFuel=n
  else error("Use miner service drop <site>, charger <site>, fuel <target>, enable or disable",0) end
  saveTable(CFG_FILE,cfg) print("Mining service saved") return
end
if args[1]=="nav" and args[2]=="traffic" then
  assert(args[3]=="on" or args[3]=="off","traffic on or off required")
  cfg.nav=cfg.nav or {} cfg.nav.traffic=args[3]=="on" saveTable(CFG_FILE,cfg) return
end
if args[1]=="mine" then
  cfg.mining=cfg.mining or {}
  if args[2]=="enable" or args[2]=="disable" then
    assert(args[2]=="disable" or cfg.ssot and cfg.ssot.enabled==true and cfg.nav and cfg.nav.enabled==true and cfg.mining.home,
      "configure SSOT, navigation and mining home first")
    cfg.mining.enabled=args[2]=="enable" saveTable(CFG_FILE,cfg) print("Mining "..args[2].."d") return
  elseif args[2]=="home" then
    local p={dim=assert(cfg.ssot and cfg.ssot.dimension),h=assert(DIRS[args[6]],"home heading required")}
    p.x,p.y,p.z=tonumber(args[3]),tonumber(args[4]),tonumber(args[5])
    assert(dofile("ssot.lua").pose(p),"integer home coordinates required")
    cfg.mining.home=p saveTable(CFG_FILE,cfg) print("Mining home saved") return
  elseif args[2]=="bounds" then
    local v={} for i=1,6 do v[i]=assert(tonumber(args[i+3]),"six coordinates required") end
    C.mineZone={min={dim=args[3],x=v[1],y=v[2],z=v[3]},max={dim=args[3],x=v[4],y=v[5],z=v[6]},spacing=tonumber(args[10]) or 3}
    assert(dofile("mine-tasks.lua").zone(C.mineZone,dofile("ssot.lua").pose),"invalid mine bounds")
  else error("Use miner mine bounds <dimension> <minX> <minY> <minZ> <maxX> <maxY> <maxZ> [spacing], home <x> <y> <z> <heading>, enable or disable",0) end
end
if args[1]=="nav" and args[2]=="bounds" then
  local dim=assert(args[3],"dimension required")
  local v={}
  for i=1,6 do v[i]=assert(tonumber(args[i+3]),"six integer coordinates required") assert(v[i]%1==0) end
  assert(v[1]<=v[4] and v[2]<=v[5] and v[3]<=v[6],"bounds are reversed")
  cfg.nav=cfg.nav or {}
  cfg.nav.bounds={min={dim=dim,x=v[1],y=v[2],z=v[3]},max={dim=dim,x=v[4],y=v[5],z=v[6]}}
  saveTable(CFG_FILE,cfg)
  print("Navigation bounds saved. Set nav.enabled=true in miner.cfg to enable.")
  return
end
if args[1]=="nav" and args[2]=="calibrate" then
  assert(cfg.ssot and cfg.ssot.enabled==true and cfg.nav and cfg.nav.enabled==true,"enable SSOT and navigation before calibration")
  C.navCalibration=assert(DIRS[args[3]],"heading required")
elseif args[1]=="nav" and args[2]=="survey" then
  assert(cfg.ssot and cfg.ssot.enabled==true and cfg.nav and cfg.nav.enabled==true,"enable SSOT and navigation before surveying")
  C.navSurvey={dim=cfg.ssot.dimension,x=tonumber(args[3]),y=tonumber(args[4]),z=tonumber(args[5])}
  assert(dofile("ssot.lua").pose(C.navSurvey),"integer survey coordinates required")
elseif args[1]=="nav" then error("Use miner nav bounds <dimension> <minX> <minY> <minZ> <maxX> <maxY> <maxZ> or miner nav calibrate <heading>",0) end
local HOME = cfg.home
-- The way its chest is (behind, left or right of the home spot; older setups: behind)
cfg.chest = cfg.chest or OPP[cfg.facing]
-- The shaft is 1 block IN FRONT of the home spot (that is where the holes are)
local SHAFT = { x = HOME.x + DX[cfg.facing], z = HOME.z + DZ[cfg.facing] }
if not cfg.spine then
  -- Set up without a direction: the hub hands one out (and keeps it for this turtle)
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then error("No direction set and no wireless modem to ask the hub. Run: miner setup <role>", 0) end
  rednet.open(peripheral.getName(modem))
  print("Asking the hub which way to mine...")
  while not cfg.spine do
    local hubAt = rednet.lookup(PROTOCOL, "hub")
    if hubAt then
      rednet.send(hubAt, { type = "dir?", id = os.getComputerID(), label = os.getComputerLabel(),
        shaft = not cfg.loc and { x = SHAFT.x, z = SHAFT.z } or nil }, PROTOCOL)
      local untilT = os.clock() + 3
      repeat
        local from, r = rednet.receive(PROTOCOL, math.max(0.1, untilT - os.clock()))
        if from == hubAt and type(r) == "table" and r.type == "dir" and (DIRS[r.dir or ""] or 9) < 4 then
          cfg.spine = DIRS[r.dir]
        end
      until cfg.spine or os.clock() >= untilT
    end
    if not cfg.spine then print("No answer from the hub (is it running?), trying again") sleep(5) end
  end
  saveTable(CFG_FILE, cfg)
  print("The hub says: main tunnel " .. DIRNAME[cfg.spine])
end
local reach = C.REACH -- set per trip from the hub's job
local function inReach(x, z)
  return math.abs(x - SHAFT.x) <= reach and math.abs(z - SHAFT.z) <= reach
end
local SPINE = cfg.spine
local BRANCH = (SPINE + 1) % 4
local ROLE = DIRNAME[SPINE] .. (cfg.site and ("@" .. cfg.site) or "")
local PROGRESS_KEY = not cfg.loc and ("shaft:" .. SHAFT.x .. "," .. SHAFT.z .. ":" .. ROLE) or ROLE

if args[1] == "home" then
  -- Manual recovery: the turtle is (back) on its home spot, facing its hole.
  -- Progress (tunnels, shaft) is kept.
  local s0 = loadTable(STATE_FILE) or {}
  s0.pos = { x = HOME.x, y = HOME.y, z = HOME.z }
  s0.h = cfg.facing
  s0.phase = "home"
  s0.vein = {}
  s0.pending = nil
  saveTable(STATE_FILE, s0)
  print("Position reset to home " .. HOME.x .. "," .. HOME.y .. "," .. HOME.z .. " (facing " .. DIRNAME[cfg.facing] .. ").")
  print("Make sure it really stands there, facing its hole. Start with: miner")
  return
end

local standaloneOre = args[1]~="nav" and args[1]~="mine" and args[1] and args[1]:lower()
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
st.seals = st.seals or {}
st.phase = st.phase or "home"
st.dug = st.dug or 0
st.found = st.found or 0      -- target ores this trip
st.total = st.total or {}
local pos = st.pos

local function save() saveTable(STATE_FILE, st) end
if type(cfg.ssot) == "table" and cfg.ssot.enabled == true then
  assert(not cfg.loc and type(cfg.ssot.dimension) == "string", "SSOT needs GPS and a dimension")
  C.ssot = dofile("ssot-client.lua").new(cfg.ssot)
  C.netEvent = "miner_network"
end
C.netEvent = C.netEvent or "rednet_message"
local function worldShaft()
  if not cfg.loc then return { x = SHAFT.x, y = HOME.y, z = SHAFT.z, bottom = st.shaft } end
end

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
    facing = DIRNAME[st.h],
    x = not cfg.loc and pos.x or nil, y = pos.y, z = not cfg.loc and pos.z or nil, -- no GPS: not world x/z
    shaft = worldShaft(),
    reach = reach,
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
  -- To everyone: the hub and the fleet server both keep track (through other bots when far)
  pcall(rednet.broadcast, p, PROTOCOL)
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
local ONLY = false
-- Items this job wants: what the target ore drops, plus a custom item typed on the hub
-- (e.g. cobbled deepslate: kept instead of dropped). MATCH: part of a (modded) ore name.
local WANT, MATCH = {}, nil
local function setTargets(list, job)
  TARGET = {}
  for _, n in ipairs(list or {}) do
    if not n:find(":") then n = "minecraft:" .. n end
    TARGET[n] = true
  end
  WANT, MATCH = {}, nil
  local o = job and ORES[job.ore]
  for _, n in ipairs(o and o.drops or {}) do WANT[n] = true end
  for n in pairs(TARGET) do WANT[n] = true end -- the ore blocks themselves (silk touch)
  for _, n in ipairs(job and type(job.keep) == "table" and job.keep or {}) do WANT[n] = true end
  if job and type(job.match) == "string" and #job.match >= 3 then MATCH = job.match end
  ONLY = (job and job.only and (next(WANT) ~= nil or MATCH ~= nil)) and true or false
  -- Remember custom items, so cleaning the chest never throws them out later
  if job and (job.keep or MATCH) then
    st.kept = st.kept or {}
    for _, n in ipairs(type(job.keep) == "table" and job.keep or {}) do st.kept[n] = true end
    if MATCH then st.kept["*" .. MATCH] = true end
  end
end
local function isWanted(name)
  return WANT[name] or (MATCH ~= nil and name:find(MATCH, 1, true) ~= nil)
end
local function everKept(name)
  if not st.kept then return false end
  if st.kept[name] then return true end
  for k in pairs(st.kept) do
    if k:sub(1, 1) == "*" and name:find(k:sub(2), 1, true) then return true end
  end
  return false
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
local function isTarget(info)
  if not info then return false end
  if TARGET[info.name] then return true end
  return MATCH ~= nil and info.name:find(MATCH, 1, true) ~= nil and isOre(info)
end
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
  "quartz", "ancient_debris", "netherite_scrap", "gold_nugget", "bucket", "lava_bucket", "water_bucket",
  "torch" }) do -- torches: for tunnel jobs
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
  if isWanted(d.name) then return false end -- also a custom item like cobbled deepslate
  if ONLY then return not d.name:find("bucket", 1, true) end
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
-- A reboot in the tick between the save and the turn itself still leaves the
-- heading a quarter turn off, so the old heading is kept in st.turnFrom until the
-- next move: after a reboot recover() checks which of the two is right.
local function face(d)
  if d >= 4 then return end
  if C.nav then
    local ok,why=C.nav.face(d)
    st.h=C.nav.pose().h save()
    if not ok and why=="cancelled" and C.estop then
      setStatus("ESTOP")
      while C.estop do sleep(.1) end
      return face(d)
    end
    if not ok then error("Turn refused: " .. tostring(why),0) end
    return
  end
  while st.h ~= d do
    st.turnFrom = st.h
    local ok, why
    if (d - st.h) % 4 == 3 then
      st.h = (st.h + 3) % 4
      save()
      ok, why = turtle.turnLeft()
    else
      st.h = (st.h + 1) % 4
      save()
      ok, why = turtle.turnRight()
    end
    if not ok then
      st.h, st.turnFrom = st.turnFrom, nil
      save()
      error("Turn failed: " .. tostring(why), 0)
    end
  end
end

-- Blocks it has seen lately, for the pocket panel's drive map. Two halves of up to
-- 3000 each, so the oldest ones drop out and it never grows too big.
local known = { cur = {}, old = {}, n = 0 }
function known.put(d, name) -- d = direction from the turtle, nil = where it stands
  local x, y, z = pos.x + (d and DX[d] or 0), pos.y + (d and DY[d] or 0), pos.z + (d and DZ[d] or 0)
  local k = x .. "," .. y .. "," .. z
  if not known.cur[k] then
    known.n = known.n + 1
    if known.n > 3000 then known.old, known.cur, known.n = known.cur, {}, 1 end
  end
  known.cur[k] = { x = x, y = y, z = z, name = name }
end
-- The ones within r blocks of it (sideways), one layer above and below included
function known.near(r)
  local all, out = {}, {}
  for _, half in ipairs({ known.old, known.cur }) do
    for k, b in pairs(half) do
      if math.abs(b.x - pos.x) <= r and math.abs(b.z - pos.z) <= r and math.abs(b.y - pos.y) <= 1 then all[k] = b end
    end
  end
  for _, b in pairs(all) do out[#out + 1] = b end
  return out
end

local function inspect(d)
  local ok, info
  if d == UP then ok, info = turtle.inspectUp()
  elseif d == DOWN then ok, info = turtle.inspectDown()
  else face(d) ok, info = turtle.inspect() end
  known.put(d, ok and info.name or "minecraft:air")
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

-- Natural rock on a known route needs proof that the turtle placed it there.
local NATURAL = {}
for _, n in ipairs({ "stone", "deepslate", "tuff", "granite", "diorite", "andesite", "calcite",
  "dirt", "grass_block", "smooth_basalt", "netherrack", "bedrock" }) do
  NATURAL["minecraft:" .. n] = true
end

local function sealKey(d)
  return (pos.x + DX[d]) .. "," .. (pos.y + DY[d]) .. "," .. (pos.z + DZ[d])
end

-- Lava: scoop it as fuel first, then seal with the first placeable non-ore block
local function seal(d)
  scoopLava(d)
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 and sealable(s) then
      local name = turtle.getItemDetail(s).name
      turtle.select(s)
      local ok = placeDir(d)
      turtle.select(1)
      if ok then
        if NATURAL[name] then st.seals[sealKey(d)] = name save() end
        return true
      end
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
  local keep = {}
  local best = sealStackSlot()
  if best then keep[best] = true end
  -- Tunnel jobs bridge gaps and patch walls: keep 5 more stacks of blocks for that
  local extra = (st.job and st.job.bore) and 5 or 0
  for s = 1, 16 do
    if extra > 0 and not keep[s] and turtle.getItemCount(s) > 0 and isJunk(s) and sealable(s) then
      keep[s] = true
      extra = extra - 1
    end
  end
  for s = 1, 16 do
    if not keep[s] and turtle.getItemCount(s) > 0 and isJunk(s) then
      turtle.select(s)
      dropFn()
    end
  end
  turtle.select(1)
end

isLoot = function(slot, d)
  if d.name == "minecraft:bucket" or d.name == "minecraft:lava_bucket" or d.name == "minecraft:water_bucket"
    or d.name == "minecraft:torch" then
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
  if sinceDrop >= C.JUNK_EVERY or turtle.getItemCount(16) > 0 and freeSlots() == 0 then dropJunk() end
end

-- Digging with retries (gravel/sand, mobs). Returns false + reason on failure.
local function dig(d, checkRoute)
  local digf, att
  if d == UP then digf, att = turtle.digUp, turtle.attackUp
  elseif d == DOWN then digf, att = turtle.digDown, turtle.attackDown
  else face(d) digf, att = turtle.dig, turtle.attack end
  for _ = 1, C.RETRY do
    local info = inspect(d)
    if checkRoute then checkRoute(info) end
    if not info or isLiquid(info) then return true end
    if isUnbreakable(info) then return false, "unbreakable (" .. info.name .. ")" end
    if isTarget(info) then st.found = st.found + 1 end
    local dug, why = digf()
    if dug then
      if st.seals[sealKey(d)] then st.seals[sealKey(d)] = nil save() end
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
  known.put(nil, "minecraft:air") -- where it stands now is open
end

function C.navMove(d,inVein,policy)
  st.navPending={d=d,vein=inVein} save()
  local ok,why=C.nav.step(d,policy)
  local p=C.nav.pose()
  if p.x~=pos.x or p.y~=pos.y or p.z~=pos.z then
    if inVein=="pop" then st.vein[#st.vein]=nil elseif inVein then st.vein[#st.vein+1]=d end
  end
  pos.x,pos.y,pos.z,st.h=p.x,p.y,p.z,p.h
  st.navPending=nil save()
  return ok,why
end
local function rawMove(d, inVein, backward)
  if C.nav then return C.navMove(d,inVein,"explore") end
  if C.ssotMoving then return false, "SSOT movement busy" end
  local mv = turtle.forward
  if backward then mv = turtle.back
  elseif d == UP then mv = turtle.up elseif d == DOWN then mv = turtle.down else face(d) end
  -- inVein: true = step into a vein (push), "pop" = step back out (pop). Saved together
  -- with the move, so a reboot right after the move can't leave the vein list wrong.
  local function execute()
  st.pending = { d = d, fuel = turtle.getFuelLevel(), vein = inVein }
  if not backward or C.ssot then st.turnFrom = nil end
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
  if not C.ssot then return execute() end
  C.ssotMoving = true
  local from = { dim = cfg.ssot.dimension, x = pos.x, y = pos.y, z = pos.z }
  local to = { dim = from.dim, x = pos.x + DX[d], y = pos.y + DY[d], z = pos.z + DZ[d] }
  local success, ok, why = pcall(C.ssot.move, from, to, execute)
  C.ssotMoving = false
  if not success then error(ok, 0) end
  return ok, why
end

-- CC refuses to move a turtle into a chunk that is not loaded ("Cannot leave loaded world")
C.UNLOADED = "outside loaded chunks"

-- Lava it can't seal: step back up to 2 blocks through its own (empty) tunnel, wait
-- for the flow to settle, then step forward again as far as it can. Callers work by
-- position, so it's fine if it ends up a block or two further back.
local function backOff(d, checkRoute)
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
    if info and not isLiquid(info) and not dig(d, checkRoute) then return end
    if not rawMove(d) then return end
  end
end

-- Safe movement: never step into lava (seal it first), dig where needed.
local function move(d, inVein, checkRoute)
  if C.nav then return C.navMove(d,inVein,st.phase=="returning" and "walk" or "excavate") end
  local lavaTries = 0
  for attempt = 1, C.RETRY do
    local info = inspect(d)
    if checkRoute then checkRoute(info) end
    while isLava(info) do
      if sealLava(d) then
        info = inspect(d)
      else
        -- Can't seal it (e.g. lava keeps flowing in): back off a few blocks out of its
        -- way, give it time to settle or burn out, come back and try again.
        lavaTries = lavaTries + 1
        if lavaTries > 3 or d >= 4 or inVein then return false, "lava" end
        backOff(d, checkRoute)
        info = inspect(d)
      end
    end
    if info and not isLiquid(info) then
      local ok, why = dig(d, checkRoute)
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
    if type(why) == "string" and why:lower():find("loaded") then return false, C.UNLOADED end
    if d == UP then turtle.attackUp() elseif d == DOWN then turtle.attackDown() else turtle.attack() end
    sleep(0.2 * math.min(attempt, 5))
  end
  return false, "blocked"
end

C.LOST = "LOST"
local reorient -- heading check against the tunnel around the turtle (further down)

-- Move along a route the turtle dug itself (shaft, main tunnel, branches, way home)
local function moveOrFail(d, what, inVein)
  local info = inspect(d)
  -- The hatch (Y home-1 in the shaft) is closed with a seal block, which can be
  -- andesite, tuff, deepslate etc.: from above on the way down, from below on the way up
  local function rock(i)
    local hatch = pos.x == SHAFT.x and pos.z == SHAFT.z and
      (d == DOWN and pos.y == HOME.y or d == UP and pos.y == HOME.y - 2)
    return i and not hatch and st.seals[sealKey(d)] ~= i.name and (NATURAL[i.name] or isOre(i))
  end
  -- Heading off by 90° or 180° looks like solid rock ahead of an open tunnel.
  local function tryHeading()
    if rock(info) and d < 4 and reorient({ 1, 3, 2 }) then info = inspect(d) end
  end
  tryHeading()
  -- GPS available: snap world coords once, then retry the heading check (never dig).
  if rock(info) and gps and not cfg.loc then
    local x, y, z = gps.locate(1)
    if x then
      x, y, z = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
      if x ~= pos.x or y ~= pos.y or z ~= pos.z then
        pos.x, pos.y, pos.z = x, y, z
        save()
        logError("GPS resync before LOST: now at " .. x .. "," .. y .. "," .. z)
        info = inspect(d)
        tryHeading()
      end
    end
  end
  local function checkRoute(i)
    if rock(i) then
      error(C.LOST .. " at " .. pos.x .. "," .. pos.y .. "," .. pos.z .. ": rock where my tunnel should be ("
        .. i.name:gsub("^minecraft:", "") .. " to the " .. DIRNAME[d] .. ")", 0)
    end
  end
  checkRoute(info)
  local ok, why = move(d, inVein, checkRoute)
  if not ok then error((what or "Stuck") .. ": " .. tostring(why), 0) end
end

---------------------------------------------------------------------------
-- Distance and the way home
---------------------------------------------------------------------------
local function along(d) -- distance from the shaft along direction d
  return (pos.x - SHAFT.x) * DX[d] + (pos.z - SHAFT.z) * DZ[d]
end

-- Which sides should be open (true) or rock (false) here, from what the turtle dug.
-- nil when it can't tell (shaft, other heights, vein going up/down).
local function expectedSides()
  local want = {}
  if #st.vein > 0 then
    local back = OPP[st.vein[#st.vein]] -- the way it came into this vein block
    if back >= 4 then return nil end
    want[back] = true
    return want
  end
  local j = st.job
  if not (j and j.y and pos.y == j.y and st.levels[j.y]) then return nil end
  local aS, aB = along(SPINE), along(BRANCH)
  if aS < 1 or aB < 0 then return nil end
  if aB == 0 then -- main tunnel: open back to the shaft, branches only go one way
    want[OPP[SPINE]] = true
    if aS < (st.levels[j.y].spine or 0) then want[SPINE] = true end
    want[OPP[BRANCH]] = false
  else -- branch: open back to the main tunnel, rock on both walls
    want[OPP[BRANCH]] = true
    want[SPINE] = false
    want[OPP[SPINE]] = false
  end
  return want
end

-- Look around (4 turns) and see if the tunnel fits better with the heading a
-- quarter turn off. tries = quarter turns to consider (1 = right, 3 = left).
-- Only corrects on clear evidence: at least 2 sides fit better than now.
reorient = function(tries)
  local want = expectedSides()
  if not want then return false end
  local open = {}
  for _ = 1, 4 do
    local ok, info = turtle.inspect()
    open[st.h] = not ok or isLiquid(info)
    face((st.h + 1) % 4)
  end
  local function score(k) -- k = how far the real heading is from what I think
    local s = 0
    for b = 0, 3 do
      local w = want[(b + k) % 4]
      if w ~= nil then s = s + ((open[b] == w) and 1 or -1) end
    end
    return s
  end
  local now = score(0)
  local best, bestScore = 0, now
  for _, k in ipairs(tries) do
    local s = score(k)
    if s > bestScore then best, bestScore = k, s end
  end
  st.turnFrom = nil
  if best ~= 0 and bestScore - now >= 2 then
    st.h = (st.h + best) % 4
    save()
    logError("Heading was off by " .. (best == 2 and "a half turn" or ("a quarter turn " .. (best == 1 and "right" or "left"))) .. ", corrected")
    return true
  end
  save()
  return false
end

local function distHome()
  return math.abs(pos.x - HOME.x) + math.abs(pos.z - HOME.z) + math.abs(pos.y - HOME.y) + #st.vein
end

local function fuelOk(extra)
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return true end
  return f >= distHome() + C.FUEL_MARGIN + (extra or 0)
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

local B = {} -- tunnel bore (filled in further down)

-- Back home via the known route: vein -> branch -> main tunnel -> shaft
local function goHome(reason)
  st.phase = "returning"
  save()
  setStatus("Going home: " .. (reason or ""))
  if C.nav then
    local ok,why=C.nav.go({dim=cfg.ssot.dimension,x=HOME.x,y=HOME.y,z=HOME.z},"walk")
    local p=C.nav.pose() pos.x,pos.y,pos.z,st.h=p.x,p.y,p.z,p.h save()
    if not ok then error("Safe return refused: " .. tostring(why),0) end
    st.vein={} st.phase="home" save()
    return
  end
  unwindVein()
  if st.job and st.job.bore then B.back() end -- tunnel: back to the shaft along the tunnel
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
    moveOrFail(OPP[cfg.facing], "Home spot blocked") -- 1 block back onto the home spot
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

-- Called home (recall or update): stop following veins, head back right away
local function calledHome() return recall or updateWanted end

local function scanFor(dirs)
  for _, d in ipairs(dirs) do
    if calledHome() then return end
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
    if calledHome() then return end
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
  if calledHome() then return end
  if not inReach(pos.x + DX[d], pos.z + DZ[d]) then
    if roomLeft() then dig(d) end -- mine the ore block, but don't step outside the reach
    return
  end
  if veinCount >= C.MAX_VEIN or not fuelOk(4) or not roomLeft() then
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
C.LEVEL_FULL = "level full"
C.AREA_FULL = "area full"

-- Pick the layer to work on: the ore level, or a layer higher up when the lower
-- ones are full (every other layer has its branches shifted by 2 blocks).
local mode = "thorough" -- "thorough" or "fast", set per trip from the hub

-- Where branch L.branch starts along the main tunnel. Stored, so the spacing can
-- change between branches when you switch modes (older saves get it computed).
local function junctionOf(L)
  if L.junction == nil then L.junction = L.branch * C.BRANCH_GAP + (L.offset or 0) end
  return L.junction
end

local function pickLevel(base)
  for n = 0, C.MAX_LAYERS - 1 do
    local y = base + C.LAYER_STEP * n
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
  local BL = math.min(j.branchLen or C.BRANCH_LEN, reach)
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
      return C.LEVEL_FULL
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
        if not ok and why == C.UNLOADED then return C.UNLOADED end
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
        if not ok and why == C.UNLOADED then return C.UNLOADED end -- not done: resume later
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
    L.junction = junction + (fast and C.FAST_GAP or C.BRANCH_GAP)
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
  face(cfg.chest)
  local haul = {}
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and (d.name == BUCKET or d.name == LAVA_BUCKET or d.name == WATER_BUCKET or d.name == "minecraft:torch") then
      -- keep buckets (empty ones to scoop lava, full ones to burn) and torches
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
        if not keepDetail(d) and not everKept(d.name) then bad = slot break end
      end
    end
    if not bad then break end
    if not chestToFront(chest, list, bad) then break end
    local s = emptySlot()
    turtle.select(s)
    if not turtle.suck(64) then break end
    local got = turtle.getItemDetail(s, true)
    if keepDetail(got) or (got and everKept(got.name)) then
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
  if j.bore then -- walk out through the finished tunnel and back, plus ~9 moves per new block
    local front = st.bores and st.bores[j.bore.x .. "," .. j.bore.z] or 0
    return math.max(C.MIN_TRIP_FUEL, 2 * front + 1000)
  end
  local L = st.levels[j.y] or { branch = 1 }
  local down = HOME.y - j.y
  local far = math.min(reach, (L.junction or L.branch * C.BRANCH_GAP) + 8) + (j.branchLen or C.BRANCH_LEN)
  return math.max(C.MIN_TRIP_FUEL, 2 * (down + far) + 600)
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
    if ev == C.netEvent and a == hubId and c == PROTOCOL and type(b) == "table" and b.type == replyType then
      return b
    elseif ev == "timer" and a == timer then
      hubId = nil
      return nil
    end
  end
end

local function askHub()
  return request({ type = "job?", id = os.getComputerID(), role = ROLE, shaft = worldShaft(), hash = MY_HASH }, "job")
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
    type = "report", id = os.getComputerID(), role = ROLE, shaft = worldShaft(), haul = haul,
    progress = { levels = st.levels, shaft = st.shaft }, bore = st.boreEnd,
  }, PROTOCOL)
end

local function getJob()
  if standaloneOre then
    local o = ORES[standaloneOre]
    return { ore = standaloneOre, y = o.y, targets = o.targets, branchLen = C.BRANCH_LEN,
      mode = (args[2] == "fast" or args[3] == "fast") and "fast" or "thorough",
      only = (args[2] == "only" or args[3] == "only") or nil }
  end
  local reply = askHub()
  if reply then
    if type(reply.update) == "string" and reply.update ~= MY_HASH then selfUpdate(reply.update) end
    updateWanted = false
    -- The hub gave it another direction: start over in the new quarter (the shaft stays)
    local nd = type(reply.dir) == "string" and DIRS[reply.dir]
    if nd and nd < 4 and nd ~= cfg.spine and st.phase == "home" then
      cfg.spine = nd
      saveTable(CFG_FILE, cfg)
      st.levels, st.job = {}, nil
      save()
      setStatus("New direction from the hub: " .. DIRNAME[nd] .. ", restarting")
      sleep(1)
      os.reboot()
    end
    if reply.progressKey == PROGRESS_KEY or (cfg.loc and reply.progressKey == nil) then mergeProgress(reply.progress) end
    if type(reply.bore) == "table" and not reply.paused then
      -- Tunnel job. One that already ended (done, or stopped by something) is not retried
      if st.boreEnd and st.boreEnd.n == reply.bore.n then return nil, st.boreEnd.why end
      recall = false
      return { ore = "tunnel", y = HOME.y, bore = reply.bore, mineMinutes = reply.mineMinutes, label = "Tunnel" }
    end
    if reply.paused or not reply.ore then return nil, (st.boreEnd and st.boreEnd.why) or "waiting for orders" end
    st.boreEnd = nil
    recall = false
    return { ore = reply.ore, y = reply.y, targets = reply.targets, branchLen = reply.branchLen or C.BRANCH_LEN,
      mineMinutes = reply.mineMinutes, reach = reply.reach, stopIn = reply.stopIn, mode = reply.mode,
      only = reply.only and true or nil, keep = reply.keep, match = reply.match, label = reply.label }
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
function C.navCanExcavate(info)
  if cfg.mining and cfg.mining.enabled then
    C.miningModule=C.miningModule or dofile("mining.lua")
    return C.miningModule.excavatable(info,cfg.mining.targets)
  end
  return not isLiquid(info) and not isUnbreakable(info) and groundBlock(info)
end

function C.runMining()
  local nav, b1 = C.nav, nil
  if cfg.leaseV2 == true and cfg.offlineAutonomy == true then
    b1 = dofile("b1-nav.lua").wrap(C.nav, {
      client = C.ssot, secret = cfg.ssot.secret, mac = dofile("lib/stubs/b1_h1.lua").keyed,
      now = function() return os.epoch("utc") end, free = function() return fs.getFreeSpace("/") end,
      spec = cfg.lease, confidence = cfg.lease and cfg.lease.confidence,
    })
    nav = b1
  end
  local mining=dofile("mining.lua").open({nav=nav,client=C.ssot,home=cfg.mining.home,targets=cfg.mining.targets,
    service=cfg.warehouse,cancelled=function() return recall or updateWanted end,b1=b1})
  while true do
    if b1 and not b1.ready() then
      local ok, why = b1.ensure()
      if not ok then setStatus("Lease " .. tostring(why)) sleep(5) end
    end
    if not b1 or b1.ready() then
    local state=mining.state()
    if state.phase=="home" and cfg.warehouse and cfg.warehouse.enabled==true and not recall and not C.estop then
      local ok,why=mining.service()
      if ok then
        if state.reason=="complete" then ok,why=mining.finish() else ok,why=mining.start() end
      end
      if not ok then setStatus(tostring(why)) sleep(5) end
    elseif state.phase=="home" and state.reason=="complete" then
      local ok,why=mining.finish() if not ok then setStatus(tostring(why)) sleep(5) end
    elseif not recall and not C.estop then
      local ok,why=mining.start()
      if ok then
        repeat
          ok,why=mining.tick()
          local p=nav.pose() pos.x,pos.y,pos.z,st.h=p.x,p.y,p.z,p.h
          st.phase=mining.state().phase=="return" and "returning" or "mining" save()
          setStatus("Mining "..tostring(why or mining.state().phase))
          sleep(0)
        until not ok
      end
      setStatus("Mining "..tostring(why)) sleep(5)
    else setStatus("Mining paused") sleep(1) end
    end
  end
end

C.PILLAR = 8      -- marker pillar height
C.SKY_AIR = 6     -- this many air blocks in a row above Y = home means open air
local approxPos = false

local function lostWait()
  -- the pocket panel can drive it home (see listener); then it starts over as a miner
  local n = 0
  while st.phase == "lost" do
    if n % 30 == 0 then
      local tip = st.lostWhy or (st.lastError and st.lastError.msg)
      if tip then
        tip = tip:gsub("^LOST at [^:]+: ", ""):gsub("%s+", " "):sub(1, 48)
      end
      setStatus("LOST: on a pillar at " .. pos.x .. "," .. pos.y .. "," .. pos.z
        .. (approxPos and " (approx)" or "")
        .. (tip and (" - " .. tip) or "")
        .. " (drive home / pick up)")
    end
    n = n + 1
    sleep(1)
  end
  setStatus("Driven home: restarting")
  sleep(1)
  os.reboot()
end

local function lostBeacon(why)
  print(tostring(why))
  logError(why) -- the reason, in miner.log and on the hub (this never returns)
  st.phase = "lost"
  st.vein = {}
  st.lostWhy = tostring(why)
  save()
  setStatus("LOST: going up to the surface")
  local airRun, sidesteps = 0, 0
  while not (pos.y >= HOME.y and airRun >= C.SKY_AIR) and pos.y < 250 do
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
  for _ = 1, C.PILLAR do
    if turtle.detectUp() or not move(UP) then break end
    seal(DOWN)
  end
  st.lostAt = { x = pos.x, y = pos.y, z = pos.z, approx = approxPos }
  save()
  lostWait()
end

local function verifyHome()
  if not gps or cfg.loc then return end
  local x, y, z = gps.locate(2)
  if x and (math.floor(x + 0.5) ~= HOME.x or math.floor(y + 0.5) ~= HOME.y or math.floor(z + 0.5) ~= HOME.z) then
    local msg = "ERROR: home differs from GPS; run miner setup"
    logError(msg)
    save()
    setStatus(msg)
    error(msg, 0)
  end
end

-- A chest identifies home only when GPS agrees, if available.
local function calibrateAtHome()
  for i = 0, 3 do
    if chestInFront() then
      verifyHome()
      -- I face the chest, so I know my heading
      st.h = cfg.chest
      pos.x, pos.y, pos.z = HOME.x, HOME.y, HOME.z
      st.phase = "home"
      st.vein = {}
      st.pending = nil
      st.turnFrom = nil
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
  if C.nav then
    if st.job then setTargets(st.job.targets,st.job) end
    if pos.x~=HOME.x or pos.y~=HOME.y or pos.z~=HOME.z then goHome("reboot") end
    return
  end
  if st.phase == "home" then verifyHome() end
  local turnFrom = st.turnFrom -- before calibrateAtHome turns around
  if calibrateAtHome() then
    if st.job then setTargets(st.job.targets, st.job) end
    return
  end
  if st.pending then
    local f = turtle.getFuelLevel()
    local moved
    if f ~= "unlimited" and st.pending.fuel ~= "unlimited" then
      moved = f < st.pending.fuel
    elseif gps and not cfg.loc then
      local x, y, z = gps.locate(2)
      if x then
        x, y, z = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
        local d = st.pending.d
        if x == pos.x and y == pos.y and z == pos.z then moved = false
        elseif x == pos.x + DX[d] and y == pos.y + DY[d] and z == pos.z + DZ[d] then moved = true end
      end
    end
    if moved == nil then error("Cannot resolve interrupted move; return home and run miner home", 0) end
    if moved then
      applyMove(st.pending.d)
      if st.pending.vein == "pop" then st.vein[#st.vein] = nil
      elseif st.pending.vein then st.vein[#st.vein + 1] = st.pending.d end
    end
    st.pending = nil
    save()
  end
  -- Rebooted right around a turn: the heading is either the saved one or the one before
  if turnFrom and st.phase ~= "lost" then
    print("Rebooted during a turn, checking my heading")
    reorient({ (turnFrom - st.h) % 4 })
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

---------------------------------------------------------------------------
-- Tunnel bore: a lit 3x3 highway from the shaft to an end point (hub job)
---------------------------------------------------------------------------
-- The tunnel starts at the shaft hole (1 block in front of home) at home height, runs
-- straight ahead (the way the turtle faces) and turns once to reach the end point.
-- 3 wide, 3 high, floor at home height. For every block of tunnel: holes in the floor
-- are filled (bridges over gaps), lava, water and cave openings in the walls and roof
-- are sealed, and every few blocks a torch goes on the wall.
-- Near both ends (the base, and wherever it ends) it only digs natural ground and leaves
-- open air alone, so it never tears into a building: a built block there ends the job.
B.TORCH = "minecraft:torch"
B.PROTECT = 12 -- blocks at each end where it only digs natural ground
B.NOBLOCKS = "out of blocks to bridge/patch with (put cobblestone in my chest)"
B.TAGS = { "minecraft:base_stone_nether", "minecraft:logs", "minecraft:leaves", "minecraft:replaceable",
  "minecraft:flowers", "minecraft:ice", "minecraft:terracotta", "minecraft:replaceable_by_trees",
  "minecraft:snow", "minecraft:nylium", "minecraft:wart_blocks", "minecraft:soul_fire_base_blocks",
  "minecraft:dripstone_replaceable_blocks", "minecraft:sculk_replaceable", "minecraft:moss_replaceable" }
B.NAMES = {}
for _, n in ipairs({ "clay", "dripstone_block", "pointed_dripstone", "moss_block", "moss_carpet", "mud",
  "magma_block", "amethyst_block", "budding_amethyst", "amethyst_cluster", "cobweb", "glow_lichen", "vine",
  "sculk", "sculk_vein", "obsidian", "sandstone", "red_sandstone", "mycelium", "podzol", "snow_block" }) do
  B.NAMES["minecraft:" .. n] = true
end
-- Visiting order of the 9 cells of one tunnel block {side, height}: side +1 = right of
-- the direction of travel. Odd blocks go through it backwards, so each one starts
-- where the one before ended.
B.SNAKE = { { 1, 2 }, { 1, 1 }, { 1, 0 }, { 0, 0 }, { 0, 1 }, { 0, 2 }, { -1, 2 }, { -1, 1 }, { -1, 0 } }

function B.natural(info)
  if groundBlock(info) or B.NAMES[info.name] then return true end
  for _, t in ipairs(B.TAGS) do if hasTag(info, t) then return true end end
  return false
end

-- The route: leg 1 straight ahead from the shaft, then leg 2 sideways to the end point
function B.route(b)
  if type(b) ~= "table" or type(b.x) ~= "number" or type(b.z) ~= "number" then return nil, "no end point" end
  local f = cfg.facing
  local a1 = axisOf(f)
  local a2 = (a1 == "x") and "z" or "x"
  local len1 = (b[a1] - SHAFT[a1]) * (DX[f] + DZ[f])
  local off = b[a2] - SHAFT[a2]
  local d2
  if a2 == "x" then d2 = (off >= 0) and 1 or 3 else d2 = (off >= 0) and 2 or 0 end
  if len1 < 0 then return nil, "the end point is behind me (tunnels start straight ahead)" end
  if off ~= 0 and len1 < 2 then return nil, "the end point is too far to the side right here (go 2+ blocks ahead first)" end
  return { f = f, len1 = len1, d2 = d2, len2 = math.abs(off), total = len1 + 1 + math.abs(off) }
end

-- Centre (x, z) of tunnel block i (0 = the shaft hole) and the direction there
function B.at(R, i)
  if i <= R.len1 then return SHAFT.x + DX[R.f] * i, SHAFT.z + DZ[R.f] * i, R.f end
  local k = i - R.len1
  return SHAFT.x + DX[R.f] * R.len1 + DX[R.d2] * k, SHAFT.z + DZ[R.f] * R.len1 + DZ[R.d2] * k, R.d2
end

-- Is block column (x, z) part of the tunnel? (so a wall patch never lands inside it)
function B.inside(R, x, z)
  local f, R1 = R.f, (R.f + 1) % 4
  local a = (x - SHAFT.x) * DX[f] + (z - SHAFT.z) * DZ[f]    -- along leg 1
  local s = (x - SHAFT.x) * DX[R1] + (z - SHAFT.z) * DZ[R1]  -- sideways from leg 1
  if a >= 0 and a <= R.len1 and math.abs(s) <= 1 then return true end
  local k = s * (DX[R1] * DX[R.d2] + DZ[R1] * DZ[R.d2])        -- along leg 2
  return R.len2 > 0 and k >= 1 and k <= R.len2 and math.abs(a - R.len1) <= 1
end

-- One step that digs. protect: only natural ground (third result true = give up the job)
function B.step(d, protect)
  local info = inspect(d)
  if protect and info and not isLiquid(info) and not info.name:find("turtle") and not B.natural(info) then
    return false, "built block in the way (" .. info.name:gsub("^minecraft:", "") .. ")", true
  end
  if info and isLiquid(info) and not isLava(info) then seal(d) end -- water: plug it, then dig through
  local ok, why = move(d)
  if not ok and type(why) == "string" and why:find("unbreakable") then return false, why, true end
  return ok, why
end

function B.go(x, y, z, protect)
  while pos.x ~= x or pos.y ~= y or pos.z ~= z do
    local d
    if pos.x ~= x then d = (x > pos.x) and 1 or 3
    elseif pos.z ~= z then d = (z > pos.z) and 2 or 0
    else d = (y > pos.y) and UP or DOWN end
    local ok, why, fatal = B.step(d, protect)
    if not ok then return false, why, fatal end
  end
  return true
end

-- Close an opening next to the tunnel. full = also open air (otherwise only liquids and,
-- below, holes in the floor). false = it needed a block and had none.
function B.patch(d, full)
  local info = inspect(d)
  if info and not isLiquid(info) then return true end
  if not info and not full and d ~= DOWN then return true end
  if sealCount() == 0 and not isLava(info) then return false end
  seal(d)
  return true
end

-- Same for a wall: skipped where the tunnel itself continues (the corner)
function B.wall(R, d, full)
  if B.inside(R, pos.x + DX[d], pos.z + DZ[d]) then return true end
  return B.patch(d, full)
end

function B.torch(d)
  local s = findItem(B.TORCH)
  if not s then st.noTorch = true return end
  turtle.select(s)
  face(d)
  turtle.place()
  turtle.select(1)
end

-- Dig tunnel block i: all 9 cells, patching the outside as it goes
function B.slice(R, i, every)
  local cx, cz, d = B.at(R, i)
  local X = (d + 1) % 4
  local protect = i < B.PROTECT or i >= R.total - B.PROTECT
  local odd = (i % 2 == 1)
  for n = 1, 9 do
    local cell = B.SNAKE[odd and (10 - n) or n]
    local c, h = cell[1], cell[2]
    local ok, why, fatal = B.go(cx + c * DX[X], HOME.y + h, cz + c * DZ[X], protect)
    if not ok then return false, why, fatal end
    local sealed = (c == 0 or B.wall(R, c == 1 and X or OPP[X], not protect))
      and (h ~= 0 or B.patch(DOWN, true))
      and (h ~= 2 or B.patch(UP, not protect))
      and (i < R.total - 1 or B.wall(R, d, not protect)) -- the far end: seal liquids there too
    if not sealed then return false, B.NOBLOCKS, true end
    -- Torch on the side that is already dug out (it never gets walked through again)
    if c == 0 and h == 1 and (every or 0) > 0 and i > 0 and i % every == 0 then
      B.torch(odd and OPP[X] or X)
    end
  end
  return true
end

-- The job is over (done or stopped by something): tell the hub, don't retry it
function B.finish(j, why)
  st.boreEnd = { n = j.bore.n, why = why }
  st.boreAt = nil
  save()
  return why
end

function B.trip(j0)
  local j = {}
  for k, v in pairs(j0) do j[k] = v end
  st.job = j
  st.found = 0
  st.noTorch = nil
  st.boreAt = nil
  setTargets({}, j)
  save()
  local R, bad = B.route(j.bore)
  if not R then return B.finish(j, "Tunnel refused: " .. bad) end
  local key = j.bore.x .. "," .. j.bore.z
  st.bores = st.bores or {} -- [end point] = tunnel blocks finished
  local done = st.bores[key] or 0
  if done >= R.total then return B.finish(j, "Tunnel done (" .. R.total .. " blocks)") end
  mineUntil = j.mineMinutes and (os.clock() + j.mineMinutes * 60) or nil
  st.phase = "mining"
  save()
  if pos.x == HOME.x and pos.y == HOME.y and pos.z == HOME.z then
    moveOrFail(cfg.facing, "Hole in front of the turtle blocked")
  end
  if done > 0 then -- walk through the finished part, along the middle of the floor
    setStatus("Tunnel: walking to block " .. done)
    local a1, a2 = axisOf(R.f), axisOf(R.d2)
    local x, z = B.at(R, math.min(done - 1, R.len1))
    goAxis(a1, (a1 == "x") and x or z)
    if done - 1 > R.len1 then
      x, z = B.at(R, done - 1)
      goAxis(a2, (a2 == "x") and x or z)
    end
  end
  for i = done, R.total - 1 do
    local r = stopReason()
    if r then return r end
    st.boreAt = i
    save()
    setStatus("Tunnel " .. i .. "/" .. R.total .. (st.noTorch and " (no torches)" or ""))
    local ok, why, fatal = B.slice(R, i, j.bore.every)
    if not ok then
      if why == C.UNLOADED then return C.UNLOADED end
      -- Stuck on the same block two trips in a row: give up instead of trying forever
      local bl = st.boreBlock
      if bl and bl.key == key and bl.i == i and bl.n == j.bore.n then fatal = true end
      st.boreBlock = { key = key, i = i, n = j.bore.n }
      local msg = "Tunnel stopped at " .. pos.x .. "," .. pos.y .. "," .. pos.z .. ": " .. tostring(why)
      logError(msg)
      if fatal then return B.finish(j, msg) end
      save()
      return msg
    end
    st.bores[key] = i + 1
    save()
  end
  return B.finish(j, "Tunnel done (" .. R.total .. " blocks)")
end

-- Way home: to the middle of the floor of the block it was on, then along the tunnel
function B.back()
  local R = B.route(st.job.bore)
  if not R then return end
  if st.boreAt then
    local cx, cz = B.at(R, st.boreAt)
    local ok, why = B.go(cx, pos.y, cz, false)
    if ok then ok, why = B.go(cx, HOME.y, cz, false) end
    if not ok then error("Way home blocked: " .. tostring(why), 0) end
    st.boreAt = nil
    save()
  end
  goAxis(axisOf(R.d2), SHAFT[axisOf(R.d2)])
  goAxis(axisOf(R.f), SHAFT[axisOf(R.f)])
end

-- At home: take a stack of torches from the chest (put them in the miner's chest)
function B.takeTorches()
  local have = findItem(B.TORCH)
  if have and turtle.getItemCount(have) >= 32 then return end
  local chest = peripheral.wrap("front")
  if not (chest and chest.list and chest.pushItems) then return end
  local ok, list = pcall(chest.list)
  if not ok or type(list) ~= "table" then return end
  local pick
  for slot, it in pairs(list) do if it.name == B.TORCH then pick = slot break end end
  if not pick or not chestToFront(chest, list, pick) then return end
  local s = have or emptySlot()
  if not s then return end
  turtle.select(s)
  turtle.suck(64 - turtle.getItemCount(s))
  local d = turtle.getItemDetail(s)
  if d and d.name ~= B.TORCH then turtle.drop() end
  turtle.select(1)
end

local function trip(j0)
  if j0.bore then
    local reason = B.trip(j0)
    goHome(reason)
    return reason
  end
  reach = j0.reach or C.REACH
  mode = (j0.mode == "fast") and "fast" or "thorough"
  st.sessionEnd = j0.stopIn and (nowMs() + j0.stopIn * 1000) or nil
  -- An ore level close to (or above) the home spot, e.g. coal at Y 48 with home at Y 52:
  -- mine at the highest level the shaft allows instead of giving up
  local base = math.min(j0.baseY or j0.y, HOME.y - 8)
  local Y = pickLevel(base)
  if not Y then return C.AREA_FULL end
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
    if tostring(err):find("^" .. C.LOST) then lostBeacon(err) end
    logError(err)
    setStatus("STUCK: " .. tostring(err))
    sleep(60)
  end
  while true do
    st.phase = "home"
    face(cfg.chest)
    if not chestInFront() then calibrateAtHome() end
    while not chestInFront() do
      -- No chest = it is not where it thinks. Drop nothing, mine nothing.
      setStatus("ERROR: no chest next to me. Put me on my home spot, Ctrl+T, type: miner home")
      sleep(30)
      face(cfg.chest)
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
      if j.bore then B.takeTorches() end
      local f = turtle.getFuelLevel()
      local minimum = 2 * (HOME.y - j.y) + 200
      if f ~= "unlimited" and f < minimum then
        setStatus("Not enough fuel in the chest (" .. f .. "/" .. minimum .. ")")
        sleep(30)
      else
        setStatus("Heading out: " .. (j.bore and ("tunnel to " .. j.bore.x .. "," .. j.bore.z) or (j.ore .. " at Y " .. j.y)))
        local ok, err = pcall(trip, j)
        if ok and err == C.AREA_FULL then
          setStatus("Area full for " .. j.ore .. ": all " .. C.MAX_LAYERS .. " layers dug within reach "
            .. (j.reach or C.REACH) .. ". Pick another ore or raise the reach")
          sleep(60)
        elseif ok and err == C.UNLOADED or not ok and tostring(err):find(C.UNLOADED, 1, true) then
          -- Next tunnel block is in a chunk that is not loaded: wait instead of retrying right away
          if not ok then pcall(goHome, C.UNLOADED) end
          setStatus("Waiting: work area not loaded (stay closer to it)")
          sleep(60)
        elseif not ok then
          if err == "Terminated" then error(err, 0) end
          if tostring(err):find("^" .. C.LOST) then lostBeacon(err) end
          logError(err)
          setStatus("Error: " .. tostring(err))
          local ok2, err2 = pcall(goHome, "after error")
          if not ok2 then
            if err2 == "Terminated" then error(err2, 0) end
            if tostring(err2):find("^" .. C.LOST) then lostBeacon(err2) end
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
  -- Driving from the pocket: only at home (not on a trip), through its own moves so the
  -- position stays right. Map = world x/z, north up.
  -- A LOST turtle can be driven too. With GPS its position is set right after every
  -- move (and its heading after a step forward or back); driven onto its home spot it
  -- finds its chest, and the worker restarts it as a normal miner.
  local lastFix
  local function lostFix(dir)
    if st.phase ~= "lost" or not gps or cfg.loc then return end -- no GPS setup: own coordinates
    local x, y, z = gps.locate(1)
    if not x then return end
    x, y, z = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
    if lastFix and (dir == "forward" or dir == "back") and y == lastFix.y then
      local s = dir == "back" and -1 or 1
      for d = 0, 3 do
        if DX[d] * s == x - lastFix.x and DZ[d] * s == z - lastFix.z then st.h = d approxPos = false end
      end
    end
    pos.x, pos.y, pos.z = x, y, z
    lastFix = { x = x, y = y, z = z }
    save()
    if x == HOME.x and y == HOME.y and z == HOME.z and calibrateAtHome() then
      st.lostAt = nil
      save()
    end
  end
  local hooks = {
    home = { HOME.x, HOME.z },
    pose = function() return pos.x, pos.y, pos.z, DX[st.h], DZ[st.h] end,
    turn = function(right) face((st.h + (right and 1 or 3)) % 4) end,
    move = function(dir)
      local ok, why
      if dir == "up" then ok, why = rawMove(UP) elseif dir == "down" then ok, why = rawMove(DOWN)
      elseif dir == "forward" then ok, why = rawMove(st.h)
      else
        ok, why = rawMove(OPP[st.h], nil, true)
      end
      if ok then lostFix(dir) end
      return ok, why
    end,
    busy = function()
      if C.ssot then return "Manual driving is disabled while SSOT is enabled" end
      if st.phase == "lost" then
        if not st.lostAt then return "Still climbing to the surface, try again in a moment" end
        lostFix()
        return nil
      end
      if st.phase ~= "home" then return "Out on a trip: RECALL it (and STOP) first" end
    end,
    known = function(r)
      if r and cfg.loc then return {} end -- for the world map, but set up without GPS
      return known.near(r or 12)
    end,
  }
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == C.netEvent and c == PROTOCOL and type(b) == "table" and (not C.nav or a==cfg.ssot.server) then
      local apply,valid=true,true
      if C.nav and (b.type=="go" or b.type=="recall" or b.type=="estop")
        and (b.target==nil or b.target==os.getComputerID()) then
        local why
        apply,why=C.nav.control(b.type,type(b.commandEpoch)=="string" and tonumber(b.commandEpoch) or nil,b.cid)
        valid=why~="invalid command"
        C.estop=C.nav.stopped()
      end
      if valid and b.cid and (b.target == nil or b.target == os.getComputerID()) then
        pcall(rednet.send, a, { type = "cmd_ack", cid = b.cid,commandEpoch=b.commandEpoch }, PROTOCOL)
      end
      if apply then
      if C.nav and b.type=="estop" and (b.target==nil or b.target==os.getComputerID()) then
        C.estop=true
      elseif (b.type == "recall" or b.type == "go") and (b.target == nil or b.target == os.getComputerID()) then
        if b.from then hubId = b.from end
        recall = (b.type == "recall")
        publish(true)
      elseif b.type == "rename" and b.target == os.getComputerID() and type(b.name) == "string" and b.name ~= "" then
        os.setComputerLabel(b.name:sub(1, 32))
        publish(true)
      elseif b.type == "update" and type(b.hash) == "string" and b.hash ~= MY_HASH then
        if b.from then hubId = b.from end
        updateWanted = true
      elseif b.type == "dev" then -- the pocket panel's console
        devCommand(b, "miner.log", "miner", function(r) rednet.send(a, r, PROTOCOL) end, hooks)
      end
      end
    end
  end
end

local function heartbeat()
  while true do
    sleep(3)
    if C.nav and C.nav.resumePending() then C.estop=false end
    publish(true)
  end
end

openModem()
if not radio then print("No wireless modem: hub/dashboard will not work.") end
turtle.select(1)
if C.ssot then
  C.ssotWorker = function()
    if cfg.nav and cfg.nav.enabled==true then
      assert(not st.pending and not st.turnFrom,"Resolve the legacy movement journal before navigation boot")
      C.nav=dofile("nav.lua").open({pose={dim=cfg.ssot.dimension,x=pos.x,y=pos.y,z=pos.z,h=st.h},
        bounds=cfg.nav.bounds,client=C.ssot,canExcavate=C.navCanExcavate,traffic=cfg.nav.traffic==true,
        observe=function()
          local x,y,z=gps.locate(2)
          if x then return {dim=cfg.ssot.dimension,x=math.floor(x+.5),y=math.floor(y+.5),z=math.floor(z+.5)} end
        end,
        cancelled=function() return C.estop or not (cfg.mining and cfg.mining.enabled) and st.phase~="returning" and st.phase~="home" and (recall or updateWanted) end})
      C.estop=C.nav.stopped()
      local ok,why
      if C.navCalibration~=nil then ok,why=C.nav.calibrate(C.navCalibration) else ok,why=C.nav.recover() end
      assert(ok,why)
      recall=C.nav.controlState().kind=="recall"
      local p=C.nav.pose()
      if st.navPending and (p.x~=pos.x or p.y~=pos.y or p.z~=pos.z) then
        if st.navPending.vein=="pop" then st.vein[#st.vein]=nil
        elseif st.navPending.vein then st.vein[#st.vein+1]=st.navPending.d end
      end
      pos.x,pos.y,pos.z,st.h=p.x,p.y,p.z,p.h st.navPending=nil save()
      if C.navCalibration~=nil then print("Navigation pose calibrated") return end
      if C.navSurvey then
        assert(C.nav.go(C.navSurvey,"explore"))
        local q=C.nav.pose() pos.x,pos.y,pos.z,st.h=q.x,q.y,q.z,q.h save()
        print("Navigation route surveyed") return
      end
      if C.mineZone then
        local r,why=C.ssot.call("mine-config",{zone=C.mineZone})
        assert(r and r.ok,why) print("Mine zones saved: "..r.count) return
      end
      if cfg.mining and cfg.mining.enabled then C.runMining() return end
      worker()
      return
    end
    assert(not st.pending and not st.turnFrom, "Resolve the miner movement journal before SSOT boot")
    local x, y, z = gps.locate(2)
    assert(x and x % 1 == 0 and y % 1 == 0 and z % 1 == 0, "SSOT boot needs an observed GPS pose")
    pos.x, pos.y, pos.z = x, y, z
    assert(C.ssot.resync({ dim = cfg.ssot.dimension, x = x, y = y, z = z }))
    save()
    worker()
  end
  C.ssotReceive = function()
    while true do
      local _, sender, packet, protocol = os.pullEvent("rednet_message")
      if not C.ssot.dispatch(sender, packet, protocol) then
        os.queueEvent(C.netEvent, sender, packet, protocol)
      end
    end
  end
  parallel.waitForAny(C.ssotReceive, C.ssotWorker, listener, heartbeat, devPairLoop)
else
  parallel.waitForAny(worker, listener, heartbeat, devPairLoop)
end
