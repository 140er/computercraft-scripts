local runtime = ...
local id = os.getComputerID()
local function run()
if runtime == "sandbox" then
  assert(config.get("standardsMode"), "standardsMode disabled")
  if not peripheral.isPresent("left") then assert(periphemu.create("left", "modem", 1)) end
  local call = peripheral.call
  peripheral.call = function(name, method, ...)
    if name == "left" and method == "isWireless" then return true end
    return call(name, method, ...)
  end
  if id >= 1 and id <= 4 then turtle = dofile("turtle.lua").idle() _G.turtle = turtle end
end
while not peripheral.find("modem") do sleep(.1) end
peripheral.find("modem", rednet.open)
if runtime == "sandbox" then
  if id == 0 then
    for peer = 1, 5 do
      local name = "computer_" .. peer
      if not peripheral.isPresent(name) then assert(periphemu.create(tostring(peer), "computer"))
      else peripheral.call(name, "turnOn") end
      local from = rednet.receive("h3_boot", 40)
      assert(from == peer, "H3 peer did not boot " .. peer)
    end
  else rednet.send(0, true, "h3_boot") end
end
assert(loadfile("h3-runtime.lua", "t", _ENV))(runtime)
end
local ok,err=xpcall(run,function(value)
  return debug and debug.traceback and debug.traceback(tostring(value),2) or tostring(value)
end)
if not ok then
  if not fs.exists("sandbox-result.json") then
    local h=assert(fs.open("sandbox-result.json","w"))
    h.write(textutils.serializeJSON({ok=false,booted=false,errors={tostring(err)},
      lines={},capacity=fs.getCapacity("/"),free=fs.getFreeSpace("/")})) h.close()
  end
  error(err,0)
end
