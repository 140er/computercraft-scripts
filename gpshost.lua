-- gpshost.lua - a GPS host: tells turtles and pocket computers where they are (CC: Tweaked)
--
-- GPS needs 4 computers, each with a wireless or ender modem, high up and NOT all in one
-- flat layer or one line, e.g. three at the same height in an L shape plus one a few
-- blocks above one of them. Ender modems reach everywhere (and other dimensions).
-- With GPS the new bots (farmer, fuel, builder, factory) can do "<bot> setup" without
-- coordinates, and the pocket panel's map shows the pocket, the lumber turtle and Buddy.
--
-- On each of the 4 computers:
--   gpshost <x> <y> <z>   the coordinates of THAT computer (F3, the block it is in)
-- It starts by itself on boot after that.
--   gpshost               start again (after Ctrl+T)

local args = { ... }
if args[1] == "update" then
  if not fs.exists("update.lua") then
    shell.run("wget", "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/update.lua", "update.lua")
  end
  shell.run("update")
  return
end

local CFG = "gpshost.cfg"
local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
if x and y and z then
  local h = fs.open(CFG, "w")
  h.write(textutils.serialize({ x = x, y = y, z = z }))
  h.close()
  h = fs.open("startup.lua", "w")
  h.write('shell.run("gpshost")\n')
  h.close()
  os.setComputerLabel(os.getComputerLabel() or ("GPS " .. x .. " " .. y .. " " .. z))
  print("Saved. This computer is a GPS host from now on, also after a reboot.")
elseif args[1] then
  print("Usage: gpshost <x> <y> <z>   (this computer's own coordinates)")
  return
end

if not fs.exists(CFG) then
  print("Usage: gpshost <x> <y> <z>   (this computer's own coordinates, F3)")
  return
end
local h = fs.open(CFG, "r")
local c = textutils.unserialize(h.readAll())
h.close()
if not peripheral.find("modem", function(_, m) return m.isWireless() end) then
  print("Put a wireless or ender modem on this computer first.")
  return
end
print("GPS host at " .. c.x .. " " .. c.y .. " " .. c.z)
shell.run("gps", "host", tostring(c.x), tostring(c.y), tostring(c.z))
