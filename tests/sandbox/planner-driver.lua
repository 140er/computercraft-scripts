local id = os.getComputerID()
local SECRET = "test-secret-123456"
local BOOT = "planner_boot"
local PROTOCOL = "planner"

local function fail(err) error(err, 0) end

local function report(ok, errors, lines)
  local result = { ok = ok, booted = true, errors = errors or {}, lines = lines or {},
    rx = 0, httpOK = 0, httpAttempts = 0, free = fs.getFreeSpace("/") }
  if #result.errors == 0 then result.errors = textutils.empty_json_array end
  if #result.lines == 0 then result.lines = textutils.empty_json_array end
  local handle = assert(fs.open("sandbox-result.json", "w"))
  handle.write(textutils.serializeJSON(result))
  handle.close()
end

local function modem()
  if not peripheral.isPresent("left") then assert(periphemu.create("left", "modem", 1)) end
  local call = peripheral.call
  peripheral.call = function(name, method, ...)
    if name == "left" and method == "isWireless" then return true end
    return call(name, method, ...)
  end
  rednet.open("left")
end

local function noGps()
  local x = gps.locate(1)
  if x ~= nil then fail("a GPS host answered") end
end

local function observe(correct)
  if correct then
    return {
      h = 2,
      blocks = {
        front = "minecraft:chest", back = "minecraft:air", left = "minecraft:air",
        right = "minecraft:air", up = "minecraft:air", down = "minecraft:stone",
      },
      peripherals = { front = "inventory" },
    }
  end
  return {
    h = 2,
    blocks = {
      front = "minecraft:stone", back = "minecraft:stone", left = "minecraft:stone",
      right = "minecraft:stone", up = "minecraft:stone", down = "minecraft:stone",
    },
    peripherals = {},
  }
end

local function paintSizes(model)
  local View = dofile("planner-view.lua")
  local lines = {}
  for _, size in ipairs({ { 328, 162 }, { 164, 81 }, { 51, 19 }, { 39, 13 }, { 26, 20 } }) do
    local win = window.create(term.current(), 1, 1, size[1], size[2], false)
    local w, h = win.getSize()
    if w ~= size[1] or h ~= size[2] then fail("window " .. w .. "x" .. h) end
    local blits = 0
    local native = win.blit
    win.blit = function(text, fg, bg)
      blits = blits + 1
      if #text ~= size[1] or #fg ~= size[1] or #bg ~= size[1] then
        fail("blit " .. #text .. " at " .. size[1] .. "x" .. size[2])
      end
      native(text, fg, bg)
    end
    local layout = View.paint(win, model)
    if blits ~= size[2] then fail("rows " .. blits .. " at " .. size[2]) end
    if size[1] == 26 and size[2] == 20 and size[2] - layout.mapTop + 1 ~= 18 then
      fail("pocket map is not 18 rows")
    end
    lines[#lines + 1] = "render " .. size[1] .. "x" .. size[2]
  end
  return lines
end

local function server()
  modem()
  noGps()
  for peer = 1, 2 do
    if not peripheral.isPresent("computer_" .. peer) then
      assert(periphemu.create(tostring(peer), "computer"))
      local from = rednet.receive(BOOT, 30)
      if from ~= peer then fail("computer " .. peer .. " did not boot") end
    else
      peripheral.call("computer_" .. peer, "turnOn")
    end
  end
  local handle = assert(fs.open("ssot.cfg", "w"))
  handle.write('{controllers={["1"]="test-secret-123456",["2"]="test-secret-123456"},planner=true}')
  handle.close()
  local SSOT = dofile("ssot.lua")
  local api = SSOT.open({
    controllers = { ["1"] = SECRET, ["2"] = SECRET },
    planner = true,
  })
  local function put(event)
    local result = api.plan(event)
    if not result or not result.ok then fail((result and result.error) or "plan event failed") end
    return result
  end
  put({ t = "anchor", x = 100, y = 64, z = 200, h = 0, dim = "minecraft:overworld" })
  put({ t = "create", name = "Base" })
  put({ t = "draw", x1 = 100, z1 = 200, x2 = 106, z2 = 206 })
  put({ t = "place", kind = "chest", x = 102, z = 202 })
  put({ t = "place", kind = "bot", x = 102, z = 201, role = "miner" })
  put({ t = "level", y = 65 })
  local raised = api.state().planner
  if raised.y ~= 65 or raised.fixtures[raised.plans[raised.active].fixtures[1]].pos.y ~= 64 then
    fail("level switch moved the chest")
  end
  put({ t = "level", y = 64 })
  put({ t = "edit", what = "name", name = "Yard" })
  local issued = put({ t = "issue" })
  local code
  for _, effect in ipairs(issued.effects) do if effect.op == "code" then code = effect.code end end
  if not code then fail("no code") end
  local Host = dofile("planner-host.lua")
  local screen = term.current()
  local host = Host.attach({ ssot = api, screen = screen, clock = function() return os.epoch("utc") end })
  host.focusX, host.focusZ = 98, 198
  host.code = code
  host.draw()
  local lines = paintSizes(host.model())
  lines[#lines + 1] = "code " .. code
  local text = textutils.serialize(api.state().planner)
  local loaded = textutils.unserialize(text)
  if loaded.rev ~= api.state().planner.rev or loaded.plans[loaded.active].name ~= "Yard" then
    fail("reload mismatch")
  end
  rednet.broadcast({ type = "code", code = code }, PROTOCOL)
  rednet.send(2, { type = "go" }, PROTOCOL)
  local wrong, right
  local deadline = os.clock() + 25
  while not (wrong and right) do
    local timer = os.startTimer(math.max(0.1, deadline - os.clock()))
    local event, sender, message, proto = os.pullEvent()
    if event == "timer" and sender == timer then fail("turtle claim timed out") end
    if event == "rednet_message" and proto == PROTOCOL and type(message) == "table" and message.op == "plan-claim" then
      local reply = api.handle(sender, message)
      rednet.send(sender, reply or { ok = false, error = "rejected" }, PROTOCOL)
      if sender == 2 then
        if not reply or reply.ok or reply.error ~= "wrong cell" then
          fail("wrong placement reply " .. textutils.serialize(reply))
        end
        if not reply.screen or not reply.screen:find("Wrong cell", 1, true) then
          fail("wrong-cell screen missing")
        end
        wrong = true
        rednet.send(1, { type = "go" }, PROTOCOL)
      elseif sender == 1 then
        if not reply or not reply.ok then fail("good placement failed") end
        if reply.role ~= "miner" or reply.settings.revision ~= 4 or reply.pose.conf ~= "certain" then
          fail("claim fields mismatch")
        end
        if reply.pose.x ~= 102 or reply.pose.y ~= 64 or reply.pose.z ~= 201 or reply.pose.h ~= 2 then
          fail("claim pose mismatch")
        end
        right = true
      end
    end
  end
  lines[#lines + 1] = "claims verified"
  report(true, {}, lines)
end

local function turtle()
  modem()
  noGps()
  rednet.send(0, true, BOOT)
  local _, codeMsg = rednet.receive(PROTOCOL, 30)
  if type(codeMsg) ~= "table" or type(codeMsg.code) ~= "string" then fail("no copy code") end
  local _, go = rednet.receive(PROTOCOL, 30)
  if type(go) ~= "table" or go.type ~= "go" then fail("no go") end
  local message = {
    v = 1, type = "ssot", expect = "ssot_reply", op = "plan-claim",
    boot = "turtle-" .. id, rid = "claim-" .. id, counter = 1,
    code = codeMsg.code, observe = observe(id == 1),
  }
  rednet.send(0, message, PROTOCOL)
  local _, reply = rednet.receive(PROTOCOL, 20)
  if type(reply) ~= "table" then fail("no claim reply") end
  local handle = assert(fs.open("planner-enrol.state", "w"))
  handle.write(textutils.serialize({
    role = reply.role, settings = reply.settings, pose = reply.pose,
    error = reply.error, screen = reply.screen,
  }))
  handle.close()
  if id == 2 then
    if reply.ok or reply.error ~= "wrong cell" then fail("expected wrong cell, got " .. tostring(reply.error)) end
    if not reply.screen or not reply.screen:find("Wrong cell", 1, true) then fail("installer screen") end
    report(true, {}, { reply.screen })
    return
  end
  if not reply.ok then fail(reply.error or "claim failed") end
  if reply.role ~= "miner" or reply.settings.revision ~= 4 or not reply.settings.overrides then
    fail("settings mismatch")
  end
  if reply.pose.x ~= 102 or reply.pose.y ~= 64 or reply.pose.z ~= 201 or reply.pose.h ~= 2 or reply.pose.conf ~= "certain" then
    fail("pose mismatch")
  end
  report(true, {}, { "pose " .. reply.pose.x .. "," .. reply.pose.y .. "," .. reply.pose.z, "role miner" })
end

assert(config.get("standardsMode") == true, "standardsMode disabled")
assert(fs.getCapacity("/") == 4000000, "wrong disk limit")
local ok, err = pcall(id == 0 and server or turtle)
if not ok then report(false, { tostring(err) }, {}) end
