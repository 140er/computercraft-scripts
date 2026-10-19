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

local passed = 0
local function test(name, fn)
  fn()
  passed = passed + 1
  print("PASS " .. name)
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

test("no controller: full 2D output and event effects match main", function()
  local old, new = start(false, original), start(false)
  local function events(m)
    m.push("char", "1")
    m.push("monitor_touch", "dashboard", 2, 5)
    m.push("mouse_click", 1, 2, 3)
    m.push("char", "s")
    m.push("char", "r")
    m.push("char", "h")
    m.push("monitor_resize", "dashboard")
    m.push("term_resize")
    m.push("peripheral", "unrelated")
    m.push("peripheral_detach", "unrelated")
    m.tick()
    m.push("char", "q")
  end
  events(old)
  events(new)
  equal(new.output, old.output, "2D draws, terminal output or event effects changed")
  equal(new.files, old.files, "saved hub state changed")
  equal(new.arCalls, {}, "3D mode must stay off")
end)

test("startup detection: one world marker, shaft and region per turtle", function()
  local m = start(true)
  local elements = frame(m)
  equal(count(elements, "drawText3D"), 4, "one marker per turtle")
  equal(count(elements, "drawLine3D"), 20, "one shaft and four region edges per turtle")
  -- Expected corners from the miner's clockwise branches, including a site-qualified role.
  local corners = {
    { 197, 44, 101, 44 }, { 41, 76, 41, -20 },
    { 13, -84, 109, -84 }, { 177, -116, 177, -20 },
  }
  for id, p in ipairs(fleet) do
    local key, c = "turtle:" .. id, corners[id]
    equal(elements[key].args, { key, 0x55FFFF - 0x1000000, p.x, p.y, p.z, 0, 0, 1, "#" .. id, true })
    equal(elements[key .. ":shaft"].args,
      { key .. ":shaft", -1, p.shaft.x, 64, p.shaft.z, p.shaft.x, -58, p.shaft.z })
    equal(elements[key .. ":region:3"].args,
      { key .. ":region:3", 0x55FFFF - 0x1000000, c[1], -58, c[2], c[3], -58, c[4] })
  end
  equal(m.rejected, 0)
  local old = start(false, original)
  equal(m.output, old.output, "3D changed the 2D dashboard")
end)

test("attach, detach and reattach use peripheral events", function()
  local m = start(false)
  m.attached = true
  local before = #m.output
  m.push("peripheral", "arbitrary_controller_name")
  equal(#m.output, before, "attach must not add 2D draws")
  equal(count(frame(m), "drawText3D"), 4)
  m.attached = false
  m.push("peripheral_detach", "arbitrary_controller_name")
  equal(frame(m), {}, "detach should clear the previous controller")
  local calls = #m.arCalls
  m.tick()
  equal(#m.arCalls, calls, "detached controller was called")
  equal(m.detachedCalls, 2, "clear and update on the detached controller")
  m.attached = true
  m.push("peripheral", "arbitrary_controller_name")
  equal(count(frame(m), "drawText3D"), 4)
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
  equal(count(elements, "drawText3D"), 4)
  equal(elements["turtle:1"].args[3], 150)
  equal(elements["turtle:1:region:3"].args,
    { "turtle:1:region:3", 0x55FFFF - 0x1000000, 117, -58, -4, 101, -58, -4 })
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
  equal(count(elements, "drawText3D"), 3)
  equal(count(elements, "drawLine3D"), 5)
  equal(elements["turtle:1"], nil, "local positions must not become world markers")
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
      m.files["miner.state"] = mocks.encode({ pos = { x = 110, y = -58, z = -20 }, shaft = -58,
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
  equal(count(frame(hub), "drawText3D"), 8)
  equal(count(frame(hub), "drawLine3D"), 40)
end)

test("3D mock rejects unverified methods", function()
  local m = mocks.new(true)
  assert(not pcall(function() m.ar.drawBox3D() end))
  equal(m.rejected, 1)
end)

print(passed .. " tests passed")
