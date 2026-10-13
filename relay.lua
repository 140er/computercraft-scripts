-- relay.lua - range booster for normal wireless modems (CC: Tweaked)
--
-- A wireless modem's range grows with its height: about 64 blocks below y=96,
-- up to about 384 blocks near the build limit. A message gets through when it is
-- within range of EITHER modem, so one modem high up covers the hub and every
-- turtle in both directions.
--
-- Put a computer with a wireless modem high above your base (y 250 or more,
-- e.g. on a pillar), then:
--   relay install    start the relay automatically on boot
--   relay            run it now
-- It runs CC's built-in "repeat" program, which forwards all rednet messages.
-- Keep its chunk loaded (near your base is fine).

local args = { ... }
if args[1] == "install" then
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("relay")\n')
  h.close()
  print("Relay will now start automatically on boot.")
  return
end

local found = false
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then found = true end
end
if not found then error("Attach a wireless modem to this computer.", 0) end

local _, y = nil, nil
if gps then _, y = gps.locate(2) end
if y and y < 200 then
  print("Warning: this relay is at y=" .. math.floor(y) .. ". Higher = more range (y 250+ recommended).")
end
print("Relay running. Forwarding all rednet messages.")
shell.run("repeat")
