local mocks = dofile("tests/mocks.lua")
local function read(path)
  local f = assert(io.open(path, "rb"))
  local code = f:read("*a")
  f:close()
  return code
end
local source = read("hub.lua")
local baseline = assert(io.popen("git show main:hub.lua", "r"))
local original = baseline:read("*a")
assert(baseline:close(), "git show main:hub.lua failed")
assert(#original > 0, "empty baseline")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n  " .. tostring(err):sub(1, 1500))
  end
end
local function equal(actual, expected, message)
  assert(mocks.encode(actual) == mocks.encode(expected), (message or "values differ")
    .. "\nexpected: " .. mocks.encode(expected) .. "\nactual: " .. mocks.encode(actual))
end
local state = { target = "diamond", branchLen64 = true, sessionLen = 1800, reach = 96,
  totals = { ["minecraft:diamond"] = 24 }, progress = {} }
local function turtle(role, x, z)
  return { type = "status", label = "Miner-" .. role, role = role, phase = "mining", status = "Mining",
    x = x + 8, y = -58, z = z + 4, fuel = 7000, free = 12, branch = 2, step = 4, level = -58,
    branchLen = 64, reach = 96, shaft = { x = x, y = 64, z = z, bottom = -58 },
    items = { ["minecraft:diamond"] = 3 } }
end
local fleet = { turtle("east", 101, -20), turtle("south", 105, -20),
  turtle("west", 109, -20), turtle("north@2", 113, -20) }
local function start(attached, code)
  local m = mocks.new(attached, state)
  m.start(code or source)
  for id, packet in ipairs(fleet) do m.status(id, packet) end
  m.tick()
  return m
end
local function frame(m) return assert(m.frames[#m.frames], "3D mode did not publish a frame") end
local function count(elements, method)
  local n = 0
  for _, element in pairs(elements) do if element.method == method then n = n + 1 end end
  return n
end
local function hud(m, enabled)
  equal(frame(m).view.args,
    { "view", (enabled and 0x55FF55 or 0x999999) - 0x1000000, 4, 4, enabled and "3D: AAN" or "3D: UIT", false })
  if not enabled then
    equal(count(frame(m), "drawText3D"), 0, "disabled view kept world labels")
    equal(count(frame(m), "drawLine3D"), 0, "disabled view kept world lines")
  end
end
local function touch3D(m, label)
  local x, y, found
  for _, line in ipairs(m.output) do
    local call = assert(load("return " .. line, "=output", "t", {}))()
    if call[1] == "dashboard" then
      if call[2] == "setCursorPos" then x, y = call[3], call[4]
      elseif call[2] == "write" and call[3] == label then found = { x, y } end
    end
  end
  assert(found, "3D touch button missing: " .. label)
  m.push("monitor_touch", "dashboard", found[1], found[2])
end

test("no controller: the dashboard and its keys work and never touch AR", function()
  local m = start(false)
  m.push("char", "1")
  m.push("monitor_touch", "dashboard", 2, 5)
  m.push("mouse_click", 1, 2, 3)
  m.push("char", "s")
  m.push("char", "r")
  m.push("char", "h")
  m.push("char", "v")
  m.push("monitor_resize", "dashboard")
  m.push("term_resize")
  m.push("peripheral", "unrelated")
  m.push("peripheral_detach", "unrelated")
  m.tick()
  equal(m.arCalls, {}, "3D mode must stay off")
  local out = table.concat(m.output, "\n")
  assert(out:find(mocks.encode({ "dashboard", "write", " 3D VIEW " }), 1, true), "3D VIEW button missing")
  equal(m.env.textutils.unserialize(m.files["hub.state"]).recallAll, false, "resume after recall")
  m.push("char", "q")
end)

test("3D VIEW draws the fleet with teletext pixels, turns, and BACK returns", function()
  local m = start(false)
  touch3D(m, " 3D VIEW ")
  local blits = 0
  for i = 1, #m.output do
    local call = assert(load("return " .. m.output[i], "=output", "t", {}))()
    if call[1] == "dashboard" and call[2] == "blit" then
      blits = blits + 1
      equal(#call[3], 80, "row width")
      equal(#call[4], 80)
      equal(#call[5], 80)
    end
  end
  equal(blits, 38, "one row per line between the title and the controls")
  local out = table.concat(m.output, "\n")
  assert(out:find("Miner-east", 1, true), "turtle names in the 3D view")
  local frames = #m.output
  m.tick()
  assert(#m.output > frames, "the view redraws every second")
  touch3D(m, " < BACK ")
  assert(table.concat(m.output, "\n", frames):find(mocks.encode({ "dashboard", "write", " STOP " }), 1, true),
    "BACK did not return to the dashboard")
  m.push("char", "q")
end)

test("goggles: HUD lines, ore icons, and frames that delete instead of clearing", function()
  local m = start(true)
  local p = turtle("east", 101, -20)
  p.ore = "diamond"
  m.status(1, p)
  m.tick()
  local elements = frame(m)
  equal(elements["hud:bg"].method, "drawRect2D")
  equal(elements["hud:title"].args[5], "Fleet")
  equal(elements["hud:1"].args[5], "Miner-east: Mining")
  equal(elements["turtle:1:ore"].args, { "turtle:1:ore", p.shaft.x + 0.5, 69, p.shaft.z + 0.5, 0, 0, 1.5,
    "minecraft:diamond" })
  local clears = 0
  for _, c in ipairs(m.arCalls) do if c.method == "clear" then clears = clears + 1 end end
  m.tick()
  m.tick()
  local after = 0
  for _, c in ipairs(m.arCalls) do if c.method == "clear" then after = after + 1 end end
  equal(after, clears, "frames after the first must not clear (that flickers)")
  -- A forgotten turtle's elements are deleted
  m.status(2, { type = "reset" })
  m.tick()
  equal(frame(m)["turtle:2"], nil)
  equal(frame(m)["turtle:2:box:1"], nil)
  equal(frame(m)["hud:4"], nil, "HUD line of the removed turtle")
end)

test("fleetview draws teletext pixels with the right colours", function()
  local V = assert(loadfile("fleetview.lua", "t", mocks.new(false).env))()
  local rows = {}
  local t = { setCursorPos = function(_, y) rows.y = y end,
    blit = function(text, fg, bg) rows[rows.y] = { text, fg, bg } end }
  -- One horizontal red line through the middle of a 4x2 cell area, seen from the side
  local scene = { lines = { { -10, 0, 0, 10, 0, 0, 2 ^ 14 } }, marks = {}, box = { -10, 10, 0, 0 }, ground = 0 }
  V.render(t, 1, 1, 4, 2, scene, { yaw = 0, pitch = 0, zoom = 1, panX = 0, panZ = 0 })
  local all = rows[1][1] .. rows[2][1]
  local lit = 0
  for i = 1, #all do if all:byte(i) >= 128 and all:byte(i) <= 159 then lit = lit + 1 end end
  assert(lit >= 4, "line pixels missing: " .. all)
  assert((rows[1][2] .. rows[1][3] .. rows[2][2] .. rows[2][3]):find("e", 1, true), "red (e) not used")
end)

test("shaft labels are raised, centered and readable with smaller turtle markers", function()
  local m = start(true)
  local elements = frame(m)
  equal(count(elements, "drawText3D"), 8, "shaft and position markers per turtle")
  equal(count(elements, "drawLine3D"), 72, "shaft, path, four region edges and a 12-edge box per turtle")
  -- Expected corners from the miner's clockwise branches, including a site-qualified role.
  local corners = {
    { 197, 44, 101, 44 }, { 41, 76, 41, -20 },
    { 13, -84, 109, -84 }, { 177, -116, 177, -20 },
  }
  for id, p in ipairs(fleet) do
    local key, c = "turtle:" .. id, corners[id]
    equal(elements[key].args,
      { key, 0x55FFFF - 0x1000000, p.shaft.x + 0.5, 67, p.shaft.z + 0.5, 0, 0, 6, p.label, true })
    equal(elements[key .. ":position"].args,
      { key .. ":position", 0x55FFFF - 0x1000000, p.x + 0.5, -56.6, p.z + 0.5, 0, 0, 2, "#" .. id, true })
    equal(elements[key .. ":box:1"].args,
      { key .. ":box:1", 0x55FFFF - 0x1000000, p.x - 0.05, -58.05, p.z - 0.05, p.x + 1.05, -58.05, p.z - 0.05 })
    equal(elements[key .. ":path"].args,
      { key .. ":path", 0x55FFFF - 0x1000000, p.shaft.x + 0.5, -57.5, p.shaft.z + 0.5, p.x + 0.5, -57.5, p.z + 0.5 })
    equal(elements[key .. ":shaft"].args,
      { key .. ":shaft", -1, p.shaft.x + 0.5, 66.5, p.shaft.z + 0.5, p.shaft.x + 0.5, -58, p.shaft.z + 0.5 })
    equal(elements[key .. ":region:3"].args,
      { key .. ":region:3", 0x55FFFF - 0x1000000, c[1] + 0.5, -58, c[2] + 0.5, c[3] + 0.5, -58, c[4] + 0.5 })
  end
  equal(m.rejected, 0)
  hud(m, true)
end)

test("attach, detach and reattach use peripheral events", function()
  local m = start(false)
  m.attached = true
  m.push("peripheral", "arbitrary_controller_name")
  equal(count(frame(m), "drawText3D"), 8)
  hud(m, true)
  touch3D(m, " 3D: AAN ")
  hud(m, false)
  m.push("char", "v")
  m.attached = false
  m.push("peripheral_detach", "arbitrary_controller_name")
  equal(frame(m), {}, "detach should clear the previous controller")
  local calls = #m.arCalls
  m.tick()
  equal(#m.arCalls, calls, "detached controller was called")
  equal(m.detachedCalls, 2, "clear and update on the detached controller")
  m.attached = true
  m.push("peripheral", "arbitrary_controller_name")
  equal(count(frame(m), "drawText3D"), 8)
  hud(m, true)
  m.push("char", "q")
  equal(frame(m), {}, "quit should clear the view")
end)

test("new frames replace old positions and clamp branch width to reach", function()
  local m = start(true)
  local p = turtle("east", 101, -20)
  p.x, p.reach = 150, 16
  m.status(1, p)
  m.tick()
  local elements = frame(m)
  equal(count(elements, "drawText3D"), 8)
  equal(elements["turtle:1"].args[3], 101.5, "shaft label should stay at the opening")
  equal(elements["turtle:1:position"].args[3], 150.5)
  equal(elements["turtle:1:region:3"].args,
    { "turtle:1:region:3", 0x55FFFF - 0x1000000, 117.5, -58, -3.5, 101.5, -58, -3.5 })
end)

test("local coordinates, old miners and incomplete geometry are handled", function()
  local m = start(true)
  local localPos, legacy, partial = turtle("east", 1, 2), turtle("east", 3, 4), turtle("east", 5, 6)
  localPos.x, localPos.z, localPos.shaft = nil, nil, nil
  legacy.shaft = nil
  partial.shaft.bottom = "unknown"
  m.status(1, localPos)
  m.status(2, legacy)
  m.status(3, partial)
  m.tick()
  local elements = frame(m)
  equal(count(elements, "drawText3D"), 5)
  equal(count(elements, "drawLine3D"), 43)
  equal(elements["turtle:1"], nil, "local positions must not become world markers")
  equal(elements["turtle:2"].args[3], legacy.x + 0.5)
  equal(elements["turtle:3"].args[4], 67, "incomplete shaft depth must not hide the opening")
end)

test("key and dashboard touch toggles persist both states across restart", function()
  for _, input in ipairs({ "key", "touch" }) do
    local function toggle(m, enabled)
      if input == "key" then m.push("char", "v")
      else touch3D(m, enabled and " 3D: AAN " or " 3D: UIT ") end
    end
    local function restart(m)
      m.push("char", "q")
      local nextHub = mocks.new(true, state)
      nextHub.files = m.files
      nextHub.start(source)
      for id, packet in ipairs(fleet) do nextHub.status(id, packet) end
      nextHub.tick()
      return nextHub
    end
    local m = start(true)
    hud(m, true)
    toggle(m, true)
    hud(m, false)
    equal(m.env.textutils.unserialize(m.files["hub.3d"]), { enabled = false })
    m.tick()
    hud(m, false)
    m.attached = false
    m.push("peripheral_detach", "arbitrary_controller_name")
    m.attached = true
    m.push("peripheral", "arbitrary_controller_name")
    hud(m, false)
    m = restart(m)
    hud(m, false)
    toggle(m, false)
    hud(m, true)
    equal(count(frame(m), "drawText3D"), 8)
    equal(m.env.textutils.unserialize(m.files["hub.3d"]), { enabled = true })
    m = restart(m)
    hud(m, true)
    equal(count(frame(m), "drawText3D"), 8)
  end
end)

test("turtles at the shaft top need no extra position marker or path", function()
  local m = start(true)
  local p = turtle("east", 101, -20)
  p.x, p.y, p.z = p.shaft.x, p.shaft.y, p.shaft.z
  m.status(1, p)
  m.tick()
  equal(frame(m)["turtle:1:position"], nil)
  equal(frame(m)["turtle:1:path"], nil)
end)

test("LOST, STUCK and ERROR show red errors below the label; stale reports stay grey", function()
  local m = start(true)
  for id, status in ipairs({ "LOST", "STUCK: blocked", "ERROR: no fuel" }) do
    local p = turtle("east", 101, -20)
    p.phase, p.status = id == 1 and "lost" or "mining", status
    p.lastError = id == 1 and string.rep("Blocked ", 8) or nil
    m.status(id, p)
    m.tick()
    local elements, key = frame(m), "turtle:" .. id
    equal(elements[key].args[2], 0xFF5555 - 0x1000000)
    equal(elements[key .. ":position"].args[2], 0xFF5555 - 0x1000000)
    equal(elements[key .. ":error"].args,
      { key .. ":error", 0xFF5555 - 0x1000000, 101.5, 65.8, -19.5, 0, 0, 2,
        (p.lastError or status):sub(1, 40), true })
  end
  m.time = m.time + 16
  m.tick()
  for key, element in pairs(frame(m)) do
    if element.method ~= "drawText2D" and element.method ~= "drawRect2D" then
      equal(element.args[2], 0x999999 - 0x1000000, "stale element " .. key)
    end
  end
  m.status(1, turtle("east", 101, -20))
  m.tick()
  equal(frame(m)["turtle:1:error"], nil, "recovered turtle kept its error")
end)

test("controller failure stops 3D calls and leaves the dashboard running", function()
  local m = start(true)
  m.fail = "update"
  m.tick()
  local calls, output = #m.arCalls, #m.output
  m.tick()
  equal(#m.arCalls, calls)
  assert(#m.output > output, "2D stopped after controller failure")
  equal(m.rejected, 0)
end)

test("real miner telemetry supplies world shafts and omits local positions", function()
  local miner = read("miner.lua")
  local shafts = { { 100, -21 }, { 101, -20 }, { 100, -19 }, { 99, -20 } }
  local hub = start(true)
  for facing = 0, 3 do
    for _, localOnly in ipairs({ false, true }) do
      local m = mocks.new(false)
      m.files["miner.cfg"] = mocks.encode({ home = { x = 100, y = 64, z = -20 },
        facing = facing, spine = 1, loc = localOnly })
      m.files["miner.state"] = mocks.encode({ pos = { x = 110, y = -58, z = -20 }, h = (facing + 1) % 4, shaft = -58,
        phase = "mining", job = { y = -58, branchLen = 64 }, levels = { [-58] = { branch = 2, step = 4 } } })
      m.env.turtle = { select = function() end, getItemDetail = function() end,
        getItemCount = function() return 0 end, getFuelLevel = function() return 7000 end }
      -- Run the real listener and packet publisher without moving a turtle in the worker.
      local scheduler = m.env.parallel.waitForAny
      m.env.parallel.waitForAny = function(_, listener) scheduler(listener) end
      m.start(miner)
      m.push("rednet_message", 99, { type = "go" }, "minearmy")
      local packet = assert(m.messages[#m.messages], "miner did not publish status")
      equal(packet.type, "status")
      equal(packet.facing, ({ "north", "east", "south", "west" })[(facing + 1) % 4 + 1])
      if localOnly then
        equal({ packet.x, packet.z, packet.shaft }, {}, "local coordinates leaked into world telemetry")
      else
        equal({ packet.x, packet.y, packet.z }, { 110, -58, -20 })
        equal(packet.shaft, { x = shafts[facing + 1][1], y = 64, z = shafts[facing + 1][2], bottom = -58 })
        equal(packet.reach, 96)
        hub.status(facing + 10, packet)
      end
    end
  end
  hub.tick()
  equal(count(frame(hub), "drawText3D"), 16)
  equal(count(frame(hub), "drawLine3D"), 156)
  local dx, dz = { 1, 0, -1, 0 }, { 0, 1, 0, -1 }
  for facing = 0, 3 do
    local key = "turtle:" .. (facing + 10)
    local tx, tz = 110.5 + dx[facing + 1] * 1.5, -19.5 + dz[facing + 1] * 1.5
    equal(frame(hub)[key .. ":heading"].args,
      { key .. ":heading", 0x55FFFF - 0x1000000, 110.5, -57.5, -19.5, tx, -57.5, tz })
    equal(frame(hub)[key .. ":heading:1"].args,
      { key .. ":heading:1", 0x55FFFF - 0x1000000, tx, -57.5, tz,
        tx - dx[facing + 1] * 0.5 - dz[facing + 1] * 0.5, -57.5,
        tz - dz[facing + 1] * 0.5 + dx[facing + 1] * 0.5 })
    assert(frame(hub)[key .. ":heading:2"], "missing arrow wing")
  end
end)

test("Tom's GPU: 3D window, triangles per cube, list, buttons and FLIP", function()
  local env = mocks.new(false).env
  local saved = {}
  env.settings = { get = function(k) return saved[k] end, set = function(k, v) saved[k] = v end, save = function() end }
  local V = assert(loadfile("fleetview.lua", "t", env))()
  local calls, verts, colors3, size = {}, 0, 0, 16
  local gl = setmetatable({
    glVertex = function() verts = verts + 1 end,
    glColor = function(r, g, b)
      assert(r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and b <= 255, "colour out of range")
      colors3 = colors3 + 1
    end,
  }, { __index = function(_, k) return function(...) calls[#calls + 1] = k end end })
  local texts = {}
  local gpu = {
    refreshSize = function() end,
    setSize = function(res) size = res end,
    getSize = function() return 8 * size * 2, 4 * size * 2 end, -- 2x1 monitors of 8x4 blocks... any size
    createWindow3D = function(x, y, w, h) assert(w > 0 and h > 0) return gl end,
    filledRectangle = function() end,
    drawText = function(x, y, text) texts[#texts + 1] = text end,
    sync = function() calls[#calls + 1] = "gpu.sync" end,
  }
  local g = assert(V.gpuOpen(gpu))
  equal(size, 64, "highest resolution first")
  assert(g.listW > 0, "a big screen gets the list")
  local list = { V.entry(1, "miner", { label = "Miner-east", x = 10, y = 40, z = 5, facing = "east",
    shaft = { x = 0, y = 64, z = 0, bottom = 40 }, level = 40, role = "east", reach = 32, branchLen = 16 }, 0) }
  V.gpuDraw(g, list, { title = "Fleet", places = { { x = 0, y = 64, z = 0, name = "Hub" } } })
  assert(verts > 0 and verts % 3 == 0, "whole triangles: " .. verts)
  assert(colors3 > 0, "colours set")
  local order = table.concat(calls, " ")
  assert(order:find("clear.-glBegin.-glEnd.-render.-sync.-gpu.sync"), "frame order: " .. order)
  assert(table.concat(texts, "|"):find("Miner-east", 1, true), "bot in the list")
  local flip
  for _, b in ipairs(g.buttons) do if b[3] == "flip" then flip = b end end
  equal(V.gpuTouch(g, flip[1] + 1, g.h - 5), "flip")
  equal(saved["fleet.gpuflip"], true, "FLIP is saved")
  equal(V.gpuTouch(g, 5, 5), nil, "taps in the 3D area do nothing")
  local yaw = g.cam.yaw
  equal(V.gpuTouch(g, g.buttons[1][1] + 1, g.h - 5), "left")
  assert(g.cam.yaw ~= yaw, "< turns the view")
end)

test("3D mock rejects unverified methods", function()
  local m = mocks.new(true)
  assert(not pcall(function() m.ar.drawBox3D() end))
  equal(m.rejected, 1)
  assert(not pcall(function() m.ar.drawText2D("hud", 0xFF55FF55, 4, 4, "3D: AAN", false) end))
  assert(not pcall(function() m.ar.drawText2D("hud", -1, 4.5, 4, "3D: AAN", false) end))
  assert(not pcall(function() m.ar.drawText2D("hud", -1, 4, 4, "3D: AAN", 0) end))
end)

dofile("tests/miner_lost.lua")(test, equal, read, mocks)
dofile("tests/miner_dirs.lua")(test, equal, read, mocks)
dofile("tests/server.lua")(test, equal, read, mocks)
dofile("tests/so/so0.lua")(test, equal, read, mocks)

print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/so1.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/so2.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/so8.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/so5.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/so4.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/lease.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/so6.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/w40.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/so3.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/so7.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/so10.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/so9.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/so11.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

test("server modules share the shell program environment", function()
  local H = dofile("tests/so/harness.lua")
  local net = H.new()
  local server = net.machine({ id = 70, modem = true, directories = true })
  server.install({ "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-log.lua",
    "so-plan.lua", "so-mine-plan.lua", "so-lumber-plan.lua", "so-mod-ar.lua", "so-mod-cells.lua",
    "so-mod-display.lua", "so-mod-drops.lua", "so-mod-lease.lua", "so-mod-lumber.lua",
    "so-mod-mine.lua", "so-mod-shop.lua", "so-mod-state.lua" })
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    server.files[path] = read(path)
  end
  local global = server.env
  global._G = global
  global.loadfile = function(path, mode, env)
    local source = server.files[path]
    if not source then return nil, "missing " .. tostring(path) end
    return load(source, "@" .. path, mode or "bt", env or global)
  end
  local program = setmetatable({}, { __index = global })
  global.runServer = assert(global.loadfile("so-server.lua", nil, program))
  server.spawn("runServer()")
  net.advance(3)
  local output = table.concat(server.log, "\n")
  assert(server.alive(), tostring(server.error) .. "\n" .. output)
  assert(not output:find("so-server: skip", 1, true), output)
  assert(not output:find("failed:", 1, true), output)
  local count = 0
  for _, name in ipairs({ "ar", "cells", "display", "drops", "lease", "lumber", "mine", "shop", "state" }) do
    assert(program.SO.mods[name], "module missing after boot: " .. name)
    count = count + 1
  end
  equal(count, 9, "all server modules loaded and ticked")
end)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/screen-nav.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/display-client.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/drop-editor.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/worker-boot.lua")(test, equal)
dofile("tests/so/server-net.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/snapshot-prune.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/mine-travel.lua").run(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/store-recover.lua")(test)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/worker-drop.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/worker-park.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/worker-pending.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/worker-reanchor.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/lumber-loops.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/disk-guard.lua")(test)

dofile("tests/so/lumber-deliver.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/tick-stall.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/mine-done-return.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/lumber-path.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/minor-ui.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/mine-dead.lua")(test, equal)
dofile("tests/so/worker-discard.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/mine-underground.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/dug-bitset.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/dug-retirement.lua")(test, equal)
dofile("tests/so/dug-display.lua")(test, equal)
dofile("tests/so/dug-mine.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/ui/ui0.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/ui/ui1.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/ui/ui2a.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/ui/ui2c.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/ui/ui2b.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/ui/ui2d.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/ui/ui3a.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/ui/ui3c.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/ui/ui3b.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/ui/ui5b.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/ui/ui5a.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/parts/so-mod-mine.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/hello-visible.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end


dofile("tests/so/range-batch.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/map.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/panel-pair.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/ui/shop-touch.lua").run(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
dofile("tests/so/ar-labels.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

if not __suite_test then dofile("tests/skips.lua").summary(passed, failed) end

dofile("tests/so/clock-utc.lua")(test)
dofile("tests/so/clock.lua")(test, equal)
dofile("tests/so/clock-so11.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/park-renewal.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/visibility.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/job-readiness.lua")(test, equal)
dofile("tests/so/mining-continuous.lua")(test, equal)
dofile("tests/parts/so-mod-mine.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/w1-addhere-disk.lua")(test, equal, read, mocks)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end

dofile("tests/so/log-perf.lua")(test, equal)
print(passed .. " tests passed" .. (failed > 0 and (", " .. failed .. " FAILED") or ""))
if failed > 0 then os.exit(1) end
