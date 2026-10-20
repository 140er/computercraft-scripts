local id = os.getComputerID()
assert(config.get("standardsMode") == true, "standardsMode disabled")
assert(fs.getCapacity("/") == 1000000, "wrong disk limit")
if not peripheral.isPresent("left") then assert(periphemu.create("left", "modem", 1)) end
local call = peripheral.call
peripheral.call = function(name, method, ...)
  if name == "left" and method == "isWireless" then return true end
  return call(name, method, ...)
end
rednet.open("left")
local function report(ok, err)
  local result = { ok = ok, booted = true, errors = ok and {} or { tostring(err) },
    lines = { ok and "fleet scenario passed" or tostring(err) }, free = fs.getFreeSpace("/"), rx = 0 }
  if #result.errors == 0 then result.errors = textutils.empty_json_array end
  local h = assert(fs.open("sandbox-result.json", "w"))
  h.write(textutils.serializeJSON(result))
  h.close()
end
if id == 0 then
  for peer = 1, 4 do
    if not peripheral.isPresent("computer_" .. peer) then
      assert(periphemu.create(tostring(peer), "computer"))
      local from = rednet.receive("fleet_boot", 30)
      assert(from == peer, "computer did not finish BIOS startup: " .. tostring(from))
      sleep(0.2)
    end
  end
else
  rednet.send(0, true, "fleet_boot")
end
local ok, err = pcall(dofile, "fleet-runtime.lua")
if not ok then report(false, err) end
while true do os.pullEvent() end
