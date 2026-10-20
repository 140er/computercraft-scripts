if fs and fs.exists("wh2-program.lua") and not rawget(_ENV,"__wh2Running") then
  if dofile("wh2-program.lua").run("gpshost.lua",...) then return end
end
-- gpshost.lua - one GPS host computer (CC: Tweaked). Four of these give every
-- turtle and pocket computer its real position, and the pocket panel a live map.
--
--   gpshost <x> <y> <z>   set this computer's own position (press F3, look at
--                         the computer block) and start hosting; it also starts
--                         again by itself after a reboot or chunk reload
--   gpshost               start hosting with the saved position
--   gpshost check         ask the other GPS hosts where this computer is
--
-- Setting up the tower (4 computers, each with a wireless or ender modem):
--   * Ender modems on the hosts are easiest: they reach every bot at any
--     distance. Normal wireless modems reach further the higher they are.
--   * Put them high up, a few blocks apart, and NOT all at the same height and
--     NOT all in one line: e.g. three in an L at one height, the fourth 3 blocks
--     higher or lower. That is what lets GPS also tell the height.
--   * The chunk must stay loaded, so build it near your base (or chunk-load it).

local CFG = "gpshost.cfg"

local function modem()
  return peripheral.find("modem", function(_, m) return m.isWireless() end)
end

local A = dofile("atomic.lua")
local cfgRec
local function save(x, y, z)
  cfgRec = cfgRec or A.mount("/"):open(CFG, function(v) return type(v) == "table" end, { class = "control", limit = 8192 })
  cfgRec:save({ x = x, y = y, z = z })
  A.replaceBytes("startup.lua", 'shell.run("gpshost")\n', function(s) return load(s) ~= nil end)
end

local function load()
  local raw = A.read(CFG)
  if type(raw) ~= "table" then return nil end
  if (raw.v == 1 or raw.schema == 1) and type(raw.generation) == "number" and type(raw.value) == "table" then
    return raw.value
  end
  return raw
end

local args = { ... }
if args[1] == "update" then
  -- latest version from GitHub (update.lua does the work, fetched here if missing)
  if not fs.exists("update.lua") then
    shell.run("wget", "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/alpha/update.lua", "update.lua")
  end
  shell.run("update")
  return
end
if not modem() then
  print("Put a wireless or ender modem on this computer first.")
  return
end

if args[1] == "check" then
  print("Asking the other GPS hosts...")
  local x, y, z = gps.locate(3)
  if x then
    print(("They say I'm at %d %d %d"):format(math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)))
    local c = load()
    if c and (c.x ~= math.floor(x + 0.5) or c.y ~= math.floor(y + 0.5) or c.z ~= math.floor(z + 0.5)) then
      print(("My saved position is %d %d %d: one of them is wrong!"):format(c.x, c.y, c.z))
    end
  else
    print("No fix. Fewer than 4 hosts are reachable, or they")
    print("are all at the same height or in one line.")
  end
  return
end

local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
if x and y and z then
  save(x, y, z)
  print(("Saved: this computer is at %d %d %d."):format(x, y, z))
  if not os.getComputerLabel() then os.setComputerLabel("GPS " .. x .. "," .. y .. "," .. z) end
else
  local c = load()
  if not c then
    print("Usage: gpshost <x> <y> <z>")
    print("  the coordinates of THIS computer block")
    print("  (press F3 and look at it: 'Targeted Block')")
    return
  end
  x, y, z = c.x, c.y, c.z
end

term.clear()
term.setCursorPos(1, 1)
print("GPS host at " .. x .. " " .. y .. " " .. z)
print("Keep this chunk loaded. Ctrl+T stops it.")
print("")
shell.run("gps", "host", x, y, z)
