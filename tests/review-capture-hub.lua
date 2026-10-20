-- sandbox-verified on CraftOS-PC 2.8.3, SDL dummy GUI renderer.
-- Captures existing hub.lua without changing its code; no physical peripherals.
assert(periphemu.create("left", "modem", 1))
local call = peripheral.call
peripheral.call = function(name, method, ...)
  if name == "left" and method == "isWireless" then return true end
  return call(name, method, ...)
end
gps.locate = function() return 0, 64, 0 end
parallel.waitForAny(function() assert(shell.run("hub.lua")) end, function()
  sleep(6)
  term.screenshot()
  sleep(1)
  os.shutdown()
end)
