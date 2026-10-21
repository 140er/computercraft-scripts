local function mark(text)
  local h = fs.open("/turtle-up.txt", "w")
  h.writeLine(text)
  h.close()
end
mark("booted")
dofile("/verify/turtle-pre.lua")
if not peripheral.isPresent("back") then periphemu.create("back", "modem") end
local call0, wrap0 = peripheral.call, peripheral.wrap
peripheral.call = function(n, m, ...)
  if m == "isWireless" and peripheral.getType(n) == "modem" then return true end
  return call0(n, m, ...)
end
peripheral.wrap = function(n)
  local p = wrap0(n)
  if p and peripheral.getType(n) == "modem" then
    p.isWireless = function() return true end
  end
  return p
end
if not fs.exists("room.cfg.a") then
  local h = fs.open("room.cfg.a", "w")
  h.write(textutils.serialize({ v = 1, generation = 1, value = { keepLogs = 32 } }))
  h.close()
end
for _, path in ipairs({ "room.map", "room.map.a", "room.map.b" }) do
  if fs.exists(path) then fs.delete(path) end
end
mark("starting roomsorter")
local ok, err = pcall(shell.run, "roomsorter")
mark("returned " .. tostring(ok) .. " " .. tostring(err))
