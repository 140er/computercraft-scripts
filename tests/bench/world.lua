local P = dofile("probe.lua")
local probes = {}
local modem = peripheral.find("modem")
local messages = {}
if modem then modem.open(45890) end

function probes.peripherals()
  local devices = {}
  for _, name in ipairs(peripheral.getNames()) do
    devices[#devices + 1] = {name = name, types = {peripheral.getType(name)}, methods = peripheral.getMethods(name)}
  end
  return {devices = devices, fuel = turtle and turtle.getFuelLevel() or false,
    fuelLimit = turtle and turtle.getFuelLimit() or false}
end

function probes.clock()
  local rows = {}
  for i = 1, 5 do
    rows[i] = {utc = os.epoch("utc"), ingame = os.epoch("ingame"), day = os.day(), time = os.time()}
    sleep(.1)
  end
  return {samples = rows}
end

function probes.fuel(args)
  assert(turtle, "turtle required")
  local rows, moves = {}, 0
  for i = 1, 10 do
    local before = turtle.getFuelLevel()
    local ok, why = (i % 2 == 1 and turtle.forward or turtle.back)()
    local after = turtle.getFuelLevel()
    if ok then moves = moves + 1 end
    rows[i] = {before = before, after = after, ok = ok, error = why or false,
      delta = type(before) == "number" and before - after or false}
    sleep(args.pause or .1)
  end
  local beforeWait = turtle.getFuelLevel()
  sleep(2)
  return {samples = rows, moves = moves, beforeWait = beforeWait, afterWait = turtle.getFuelLevel(),
    fuelLimit = turtle.getFuelLimit()}
end

function probes.analog(args)
  if args.output ~= nil then
    redstone.setAnalogOutput(args.side, args.output)
    return {output = redstone.getAnalogOutput(args.side), side = args.side}
  end
  return {input = redstone.getAnalogInput(args.side), side = args.side}
end

function probes.detector(args)
  local detector = assert(peripheral.find("player_detector"), "no player_detector")
  local rows = {}
  for i = 1, 20 do
    local pos = detector.getPlayerPos(args.player or "SSOTProof")
    local row = {position = pos}
    if pos and pos.x then row.anchor = {x = math.floor(pos.x), y = math.floor(pos.y) - 1, z = math.floor(pos.z)} end
    rows[i] = row
    sleep(.05)
  end
  return {samples = rows, online = detector.getOnlinePlayers()}
end

function probes.send(args)
  assert(modem, "no modem")
  for i = 1, 10 do
    modem.transmit(45890, 45890, {probe = args.tag, seq = i, from = os.getComputerID()})
    sleep(.1)
  end
  return {packets = 10, tag = args.tag}
end

function probes.received() return {messages = messages} end
function probes.listen()
  modem = assert(peripheral.find("modem"), "no modem")
  modem.open(45890)
  return {open = modem.isOpen(45890)}
end
function probes.randomness() return dofile("randomness.lua") end
function probes.crypto() return dofile("crypto.lua") end
function probes.display(args) return args.value end

function probes.ar()
  local ar = assert(peripheral.find("ar_controller"), "no ar_controller")
  ar.clear()
  ar.drawLine3D("behind-line", -16711936, 2, -58, -4, 6, -58, -4)
  ar.drawText3D("behind-text", -1, 2, -57, -4, 0, 0, .03, "P0 BEHIND WALL", true)
  ar.drawLine3D("front-line", -65536, 2, -58, 0, 6, -58, 0)
  ar.drawText3D("front-text", -1, 2, -57, 0, 0, 0, .03, "P0 IN FRONT", true)
  ar.update()
  return {lines = 2, texts = 2, controller = peripheral.getName(ar)}
end

function probes.show(args)
  local f = assert(fs.open("results/" .. args.result .. ".json", "r"))
  local value = textutils.unserializeJSON(f.readAll())
  f.close()
  return value
end

parallel.waitForAll(function()
  while true do
    if fs.exists("command.ready") then
      local f = assert(fs.open("command.json", "r"))
      local command = textutils.unserializeJSON(f.readAll())
      f.close()
      fs.delete("command.ready")
      fs.delete("command.json")
      assert(type(command.id) == "string" and command.id:match("^[%w_%-]+$"), "invalid probe id")
      local result = P.measure(function() return assert(probes[command.probe], "unknown probe")(command.args or {}) end)
      result.id, result.computer, result.at = command.id, os.getComputerID(), os.epoch("utc")
      P.save(command.id, result)
    end
    local f = assert(fs.open("heartbeat.json", "w"))
    f.write(textutils.serializeJSON({at = os.epoch("utc"), ingame = os.epoch("ingame")}))
    f.close()
    sleep(.2)
  end
end, function()
  while true do
    local _, side, channel, reply, value, distance = os.pullEvent("modem_message")
    if channel == 45890 then
      messages[#messages + 1] = {side = side, reply = reply, message = value, distance = distance or false}
    end
  end
end)
