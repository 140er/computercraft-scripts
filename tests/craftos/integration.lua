local id = os.getComputerID()
local result = { id = id, ok = false, checks = {}, monitorCalls = {}, errors = {} }
local function check(name, condition)
  assert(condition, name)
  result.checks[#result.checks + 1] = name
end
local function save()
  local handle = assert(fs.open("integration-result.json", "w"))
  handle.write(textutils.serializeJSON(result))
  handle.close()
end
local function run()
  result.nativeShims = dofile("native-shims.lua")
  result.host, result.lua = _HOST, _VERSION
  check("pack ROM version text", fs.open("rom/help/whatsnew.md", "r").readLine() ==
    "New features in CC: Tweaked 1.120.2")
  check("16 MB native disk", fs.getCapacity("/") == 16000000)
  check("standards mode", config.get("standardsMode") == true)
  check("native modem", periphemu.create("left", "modem", 1))
  rednet.open("left")
  check("native inventory peripheral", periphemu.create("front", "chest"))
  check("inventory hasType true", peripheral.hasType("front", "inventory") == true)
  check("non-inventory hasType false", peripheral.hasType("left", "inventory") == false)
  check("native inventory detach", periphemu.remove("front"))
  check("absent hasType nil", peripheral.hasType("front", "inventory") == nil)
  result.nativeTurtle = type(turtle) == "table"
  if id ~= 2 then
    check("native monitor", periphemu.create("right", "monitor", 39, 20))
    local nativeCall = peripheral.call
    peripheral.call = function(name, method, ...)
      if name == "right" then
        result.monitorCalls[method] = (result.monitorCalls[method] or 0) + 1
        if method == "blit" then
          local text, fg, bg = ...
          assert(#text == #fg and #fg == #bg, "invalid native monitor blit")
        end
      end
      return nativeCall(name, method, ...)
    end
  end
  if id == 0 then
    local ar, state = dofile("ar-mock.lua")()
    local nativeFind = peripheral.find
    peripheral.find = function(kind, filter)
      if kind == "ar_controller" then
        if not filter or filter("craftos_ar", ar) then return ar end
        return
      end
      return nativeFind(kind, filter)
    end
    check("native computer 1", periphemu.create("1", "computer"))
    check("native computer 2", periphemu.create("2", "computer"))
    parallel.waitForAny(function()
      assert(loadfile("so-server.lua", nil, _ENV))()
      error("product server returned")
    end, function()
      sleep(2)
      check("actual server modules loaded", SO and SO.mods and SO.mods.ar and SO.mods.display and SO.mods.lease)
      check("actual state event persisted", SO.mods.state.emit("machine", {
        id = 2, role = "worker", seen = os.epoch("utc"), fuel = 900,
        pose = { dim = "minecraft:overworld", x = 2, y = 64, z = 0, facing = 0 } }))
      local store = SO.store.store("integration-store", function(v) return type(v) == "table" end)
      check("native fs generation save", store.save({ value = 42 }))
      check("native fs generation reload", SO.store.read("integration-store").value.value == 42)
      local sender = rednet.receive("craftos-fixture", 5)
      check("pairing fixture requested", sender == 2)
      rednet.send(2, { code = SO.pair.invite() }, "craftos-fixture")
      sleep(6)
      check("server painted native monitor", (result.monitorCalls.blit or 0) > 0)
      check("AR published real product scene", state.updates > 0 and next(state.published) ~= nil)
      check("AR real product line calls", (state.calls.drawLine3D or 0) > 0)
      check("AR real product text calls", (state.calls.drawText3D or 0) > 0)
      result.arUpdates, result.arCalls = state.updates, state.calls
      result.moduleNames = {}
      for name in pairs(SO.mods) do result.moduleNames[#result.moduleNames + 1] = name end
      table.sort(result.moduleNames)
      local bad = {}
      for _, line in ipairs(SO.terminal.log) do
        if line:find("failed:", 1, true) or line:find("so-server: skip", 1, true) then bad[#bad + 1] = line end
      end
      result.serverErrors = bad
      check("no server module failures", #bad == 0)
    end)
  elseif id == 1 then
    parallel.waitForAny(function()
      assert(loadfile("display.lua", nil, _ENV))()
      error("product display returned")
    end, function()
      sleep(7)
      check("real display painted native monitor", (result.monitorCalls.blit or 0) > 0)
      check("real display applied palette", (result.monitorCalls.setPaletteColour or 0) >= 16)
      local monitor = assert(peripheral.find("monitor"))
      result.monitorSize = { monitor.getSize() }
      check("real display set scale", monitor.getTextScale() == 0.5)
    end)
  else
    sleep(1)
    local proto = dofile("so-proto.lua")
    local found
    for _ = 1, 3 do
      found = rednet.lookup("so", "server")
      if found ~= nil then break end
    end
    check("native rednet DNS", found == 0)
    rednet.send(0, { want = "pairing-code" }, "craftos-fixture")
    local sender, fixture = rednet.receive("craftos-fixture", 3)
    check("pairing code fixture", sender == 0 and type(fixture.code) == "string")
    local pair = dofile("so-pair.lua")
    pair.open(proto, dofile("so-store.lua"))
    local paired, pairErr = pair.join(fixture.code, 0)
    check("real X25519 pairing: " .. tostring(pairErr), paired == true)
    local key = pair.key(0)
    check("new pairing key persisted", type(key) == "string" and #key == 64 and key ~= string.rep("22", 32))
    local function request(kind, body)
      local response, err = proto.request(0, kind, body, 2, 2)
      assert(response, kind .. ": " .. tostring(err))
      check(kind .. " authenticated reply", proto.macOk(key, response))
      return response
    end
    check("real hello acknowledged", request("hello", { w = 39, h = 20 }).t == "ack")
    local frame = request("view.get", {})
    check("real generic frame", frame.t == "view.frame" and frame.body.role == "generic")
    local status
    for _, button in ipairs(frame.body.buttons) do if button.id == "status" then status = button end end
    check("real status button", status ~= nil)
    local input = proto.build(key, "input", { id = status.id, x = status.x, y = status.y })
    check("native input transport", rednet.send(0, assert(proto.encode(input)), "so"))
    sleep(0.3)
    frame = request("view.get", {})
    check("real input changed role", frame.body.role == "status" and #frame.body.rows > 0)
    check("unknown method rejected", request("integration.unknown", {}).t == "err")
    local forged = proto.build(key, "hello", { w = 39, h = 20 })
    forged.mac = string.rep("0", 64)
    rednet.send(0, forged, "so")
    local rejectedBy, rejection = rednet.receive("so", 0.5)
    check("forged MAC rejected with repair hint", rejectedBy == 0 and
      type(rejection) == "table" and rejection.t == "pair.required" and rejection.mac == nil)
    check("forged MAC preserved pairing key", request("hello", { w = 39, h = 20 }).t == "ack")
    result.frame = frame.body
  end
end
local ok, err = pcall(run)
result.ok = ok
if not ok then result.errors[#result.errors + 1] = tostring(err) end
save()
while true do os.pullEventRaw() end
