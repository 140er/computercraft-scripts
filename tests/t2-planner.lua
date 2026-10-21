-- T2: the same plan through the panel, hub, and server adapters.
local tools = dofile("planner-tools.lua")
local panel = dofile("planner-panel.lua")
local hub = dofile("planner-hub.lua")
local server = tools.host("server")
local stub = dofile("lib/stubs/t2_dep.lua")

local failed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n  " .. tostring(err))
  end
end

local function encode(value)
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) == "boolean" then return tostring(value) end
  if type(value) ~= "table" then return tostring(value) end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for i, key in ipairs(keys) do
    parts[i] = "[" .. encode(key) .. "]=" .. encode(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function equal(actual, expected, message)
  local got, want = encode(actual), encode(expected)
  if got ~= want then
    error((message or "values differ") .. "\nexpected: " .. want:sub(1, 1500) .. "\nactual: " .. got:sub(1, 1500), 2)
  end
end

local function assertTrue(value, message)
  if not value then error(message or "expected true", 2) end
end

local script = {
  { t = "level", y = 70 },
  { t = "draw", kind = "base", from = { x = 0, z = 0 }, to = { x = 5, z = 3 } },
  { t = "place", kind = "chest", at = { x = 1, z = 1 }, side = "front" },
  { t = "place", kind = "dropoff", at = { x = 2, z = 1 } },
  { t = "place", kind = "charger", at = { x = 3, z = 1 } },
  { t = "place", kind = "furnace", at = { x = 4, z = 1 } },
  { t = "place", kind = "bot", role = "miner", at = { x = 1, z = 2 }, h = 0 },
  { t = "place", kind = "bot", role = "farmer", at = { x = 3, z = 2 }, h = 1 },
  { t = "job", bot = { x = 1, z = 2 }, from = { x = 0, z = 16 }, to = { x = 4, z = 20 } },
  { t = "toggle", bot = { x = 1, z = 2 }, key = "offlineAutonomy" },
  { t = "confirm", bot = { x = 1, z = 2 } },
}

local function seed(extra)
  local opts = {
    enabled = true, origin = 4, counter = 17, server = 4, now = 1792500000000,
    frame = "abs", dim = "minecraft:overworld", settingsRevision = 4, name = "Base", y = 64,
  }
  for key, value in pairs(extra or {}) do opts[key] = value end
  return opts
end

local function replay(api, screen)
  local session = assert(api.open(seed({ screen = screen })))
  for _, step in ipairs(script) do
    local events = api.gesture(session, step)
    for _, ev in ipairs(events) do session = api.input(session, ev) end
  end
  return api.records(session), session
end

local function direct(api, screen)
  local session = assert(api.open(seed({ screen = screen })))
  for _, step in ipairs(script) do session = api.apply(session, step) end
  return api.records(session), session
end

local function botRole(records, role)
  for _, bot in ipairs(records.bots) do
    if bot.role == role then return bot end
  end
end

local function fixtureKind(records, kind)
  for _, fix in ipairs(records.fixtures) do
    if fix.kind == kind then return fix end
  end
end

test("T1 stub mints ids, builds poses, and defers every event", function()
  local id, n = stub.mint(4, 17)
  equal(id, "p:4:17")
  equal(n, 18)
  assertTrue(stub.mint(-1, 1) == nil)
  local pos = assert(stub.pos({
    frame = "abs", yAbs = true, dim = "minecraft:overworld", x = 1, y = 70, z = 2, h = 0,
    conf = "certain", src = "typed", anchoredAt = 0,
  }))
  equal(pos.v, 1)
  assertTrue(stub.pos({ frame = "abs", yAbs = true, dim = "overworld", x = 0, y = 0, z = 0 }) == nil)
  local seen = {}
  for kind, row in pairs(stub.styles) do
    assertTrue(not seen[row.glyph], "glyph " .. row.glyph)
    assertTrue(not seen[row.colour], "colour " .. row.colour)
    seen[row.glyph], seen[row.colour] = true, true
    local got = assert(stub.style(kind))
    equal(got.glyph, row.glyph)
    equal(got.blit, row.blit)
  end
  equal(select(2, stub.style("nope")), "bad_style")
  local session, effects = stub.transition({ v = 1 }, { t = "place" })
  equal(session.v, 1)
  equal(effects[1].op, "defer")
  equal(stub.ops.code, "plan-code")
end)

test("full planner is on unless planner.cfg sets enabled false", function()
  local cfg = tools.config({})
  equal(cfg.enabled, true)
  equal(cfg.server, false)
  equal(tools.config({ enabled = false }).enabled, false)
  equal(tools.config({ enabled = true, server = 4 }).enabled, true)
  local session = assert(panel.open({ enabled = false, screen = tools.screens.panel }))
  equal(session.enabled, false)
  equal(panel.records(session).plan, false)
  local _, effects = panel.input(session, { t = "char", ch = "+" })
  equal(effects[1].code, "disabled")
  local rows = panel.render(session)
  equal(#rows, 20)
  equal(#rows[1].text, 26)
  assertTrue(rows[1].text:find("Full planner is off", 1, true) == 1)
  local note
  local started = panel.start({ enabled = false, screen = tools.screens.panel }, {
    write = function(text) note = text end,
  })
  equal(started.enabled, false)
  equal(note, "Full planner is off.")
  assertTrue(panel.open({ enabled = true, screen = { w = 10, h = 5 } }) == nil)
end)

test("hub planning needs a server until the hub is the authority", function()
  local session, err = hub.open({ enabled = true, origin = 4, counter = 1 })
  equal(session, nil)
  equal(err, "needs_server")
  session = assert(hub.open({ enabled = true, hubOnly = true, origin = 4, counter = 17, screen = tools.screens.hub }))
  equal(session.hubOnly, true)
  equal(session.server, false)
end)

test("scripted plan matches on the pocket, the hub, and the server", function()
  local hosts = {
    { panel, tools.screens.panel },
    { hub, tools.screens.hub },
    { server, tools.screens.server },
  }
  local directRecords = direct(server, tools.screens.server)
  for _, host in ipairs(hosts) do
    local records = replay(host[1], host[2])
    equal(records, directRecords, host[1] == panel and "panel" or "host")
    local again = direct(host[1], host[2])
    equal(again, directRecords)
  end
  equal(directRecords.plan.id, "p:4:17")
  equal(directRecords.plan.y, 70)
  equal(directRecords.plan.rev, 11)
  equal(directRecords.plan.frame, "abs")
  equal(#directRecords.plan.areas, 1)
  equal(directRecords.plan.areas[1].id, "p:4:18")
  equal(directRecords.plan.areas[1].min.x, 0)
  equal(directRecords.plan.areas[1].max.z, 3)
  equal(directRecords.plan.areas[1].min.y, 70)
  equal(#directRecords.fixtures, 4)
  equal(#directRecords.bots, 2)
  local chest = fixtureKind(directRecords, "chest")
  equal(chest.id, "p:4:19")
  equal(chest.side, "front")
  equal(chest.state, "planned")
  equal(chest.layoutId, false)
  equal(fixtureKind(directRecords, "charger").kind, "charger")
  local miner = botRole(directRecords, "miner")
  local farmer = botRole(directRecords, "farmer")
  equal(miner.id, "p:4:23")
  equal(miner.pos.h, 0)
  equal(miner.pos.y, 70)
  equal(miner.state, "code-issued")
  equal(miner.code, false)
  equal(miner.computerId, false)
  equal(miner.settings.revision, 4)
  equal(miner.devToggles.offlineAutonomy, true)
  equal(miner.settings.overrides.offlineAutonomy, true)
  equal(miner.jobArea.min.z, 16)
  equal(miner.jobArea.max.x, 4)
  equal(miner.jobArea.max.z, 20)
  equal(miner.expect.neighbours[0], "minecraft:chest")
  equal(miner.expect.peripherals.front, "inventory")
  equal(farmer.role, "farmer")
  equal(farmer.pos.h, 1)
  equal(farmer.state, "planned")
  equal(farmer.jobArea, false)
end)

test("map touches differ by screen while the plan stays the same", function()
  local draw = script[2]
  local function firstTouch(api, screen)
    local session = assert(api.open(seed({ screen = screen })))
    for _, ev in ipairs(api.gesture(session, draw)) do
      if ev.t == "touch" then return ev end
    end
  end
  local pocket = firstTouch(panel, tools.screens.panel)
  local monitor = firstTouch(server, tools.screens.server)
  equal(pocket.x, 1)
  equal(pocket.y, 2)
  equal(monitor.x, 1)
  equal(monitor.y, 3)
  assertTrue(pocket.y ~= monitor.y)
end)

test("Y slider, undo, and the pocket tool row", function()
  local session = assert(panel.open(seed()))
  local layout = panel.layout(session)
  local yup
  for _, button in ipairs(layout.buttons) do
    if button.id == "yup" then yup = button end
    assertTrue(button.x2 <= 26, "tool past the pocket width")
  end
  assertTrue(yup ~= nil)
  local undo
  for _, button in ipairs(layout.buttons) do if button.id == "undo" then undo = button end end
  equal(undo, nil)
  session = panel.input(session, { t = "touch", x = yup.x, y = yup.y })
  equal(panel.records(session).plan.y, 65)
  session = panel.input(session, { t = "char", ch = "+" })
  equal(panel.records(session).plan.y, 66)
  session = panel.input(session, { t = "char", ch = "-" })
  equal(panel.records(session).plan.y, 65)
  session = panel.apply(session, { t = "draw", from = { x = 0, z = 0 }, to = { x = 2, z = 2 } })
  equal(panel.records(session).plan.areas[1].min.y, 65)
  session = panel.apply(session, { t = "level", y = 66 })
  equal(panel.records(session).plan.areas[1].min.y, 66)
  session = panel.apply(session, { t = "place", kind = "chest", at = { x = 1, z = 1 } })
  local rev = panel.records(session).plan.rev
  session = panel.apply(session, { t = "place", kind = "chest", at = { x = 1, z = 1 } })
  equal(panel.records(session).plan.rev, rev)
  session = panel.input(session, { t = "char", ch = "u" })
  equal(#panel.records(session).fixtures, 0)
  local _, effects = panel.input(session, { t = "key", key = "backspace" })
  while effects[1].op ~= "reject" do
    session, effects = panel.input(session, { t = "key", key = "backspace" })
  end
  equal(effects[1].code, "nothing")
end)

test("rejects bad tools, occupied cells, and huge areas", function()
  local session = assert(server.open(seed({
    world = function(x, _, z)
      if x == 9 and z == 9 then return "occupied" end
      if x == 0 and z == 0 then return "known" end
      return "unknown"
    end,
  })))
  local _, effects = server.apply(session, { t = "place", kind = "anvil", at = { x = 1, z = 1 } })
  equal(effects[1].code, "bad_fixture")
  _, effects = server.apply(session, { t = "place", kind = "bot", role = "pilot", at = { x = 1, z = 1 } })
  equal(effects[1].code, "bad_role")
  _, effects = server.apply(session, { t = "toggle", key = "fly", bot = { x = 1, z = 1 } })
  equal(effects[1].code, "bad_toggle")
  _, effects = server.apply(session, { t = "place", kind = "chest", at = { x = 9, z = 9 } })
  equal(effects[1].code, "occupied")
  _, effects = server.apply(session, { t = "draw", from = { x = 0, z = 0 }, to = { x = 64, z = 64 } })
  equal(effects[1].code, "area_limit")
  equal(server.records(session).plan.rev, 0)
  local rows = server.render(session)
  equal(rows[3].text:sub(1, 1), ".")
end)

test("server applies locally and the hub addresses the server", function()
  local hubSession = assert(hub.open(seed()))
  local _, hubEffects = hub.apply(hubSession, { t = "place", kind = "furnace", at = { x = 2, z = 2 } })
  equal(hubEffects[1].op, "plan-put")
  equal(hubEffects[1].to, 4)
  equal(hubEffects[1].localApply, false)
  equal(hubEffects[2].op, "plan-intent")
  equal(hubEffects[2].hold, "intent")
  local serverSession = assert(server.open(seed({ server = false })))
  local _, serverEffects = server.apply(serverSession, { t = "confirm" })
  equal(serverEffects[1].code, "no_bot")
  serverSession = server.apply(serverSession, { t = "place", kind = "chest", at = { x = 1, z = 1 } })
  _, serverEffects = server.apply(serverSession, { t = "place", kind = "bot", role = "builder", at = { x = 1, z = 2 }, h = 2 })
  equal(serverEffects[1].localApply, true)
  equal(serverEffects[1].to, false)
  local records = server.records(serverSession)
  equal(botRole(records, "builder").pos.h, 2)
  local panelSession = assert(panel.open(seed({ server = false })))
  local _, panelEffects = panel.apply(panelSession, { t = "place", kind = "chest", at = { x = 0, z = 0 } })
  equal(panelEffects[1].discover, "fleetserver")
  panelSession = panel.apply(panelSession, { t = "place", kind = "bot", role = "miner", at = { x = 0, z = 1 }, h = 0 })
  _, panelEffects = panel.apply(panelSession, { t = "confirm", bot = { x = 0, z = 1 } })
  equal(panelEffects[2].op, "plan-code")
  equal(panelEffects[2].ttl, 900000)
  equal(panelEffects[2].planBot, "p:4:19")
  _, panelEffects = panel.apply(panelSession, { t = "confirm", bot = { x = 0, z = 1 } })
  equal(panelEffects[1].code, "already_issued")
end)

test("a relative plan asks for frame merge and keeps its frame", function()
  local session = assert(server.open(seed({ frame = "f:4:1792500000000", yAbs = true })))
  session = server.apply(session, { t = "place", kind = "chest", at = { x = 3, z = 3 } })
  local before = server.records(session)
  equal(before.plan.frame, "f:4:1792500000000")
  equal(before.fixtures[1].pos.conf, "suspect")
  equal(before.fixtures[1].pos.frame, "f:4:1792500000000")
  local after, effects = server.apply(session, { t = "anchor" })
  equal(effects[1].op, "frame-merge")
  equal(effects[1].frame, "f:4:1792500000000")
  equal(server.records(after), before)
  local absolute = assert(server.open(seed()))
  local _, abs = server.apply(absolute, { t = "anchor" })
  equal(abs[1].code, "already_abs")
end)

test("ghost markers stay on this level and clip at the AR cap", function()
  local records, session = direct(server, tools.screens.server)
  local list = server.ghosts(session)
  assertTrue(#list <= 128)
  local chest, miner, box
  for _, marker in ipairs(list) do
    equal(marker.y, 70)
    if marker.label == "chest" then chest = marker end
    if marker.label == "miner" then miner = marker end
    if marker.kind == "box" then box = marker end
  end
  equal(chest.kind, "item")
  equal(chest.item, "minecraft:chest")
  equal(miner.kind, "label")
  equal(box.w, 6)
  equal(box.d, 4)
  equal(#tools.clip(list, 2), 2)
  equal(#tools.clip(list, 0), 0)
  equal(records.plan.y, list[1].y)
end)

test("keys and monitor touches reach the server adapter", function()
  local pulls = { { "char", "f" }, { "monitor_touch", "top", 2, 3 } }
  local index = 0
  local blits = 0
  local term = {
    clear = function() end,
    setCursorPos = function() end,
    blit = function(text) blits = blits + 1 assert(#text == 164) end,
    getSize = function() return 164, 81 end,
    isColour = function() return true end,
  }
  local session = server.start(seed(), {
    term = term,
    steps = 2,
    pull = function()
      index = index + 1
      local ev = pulls[index]
      return ev[1], ev[2], ev[3], ev[4]
    end,
  })
  equal(blits > 0, true)
  equal(#server.records(session).fixtures, 1)
  equal(server.records(session).fixtures[1].pos.x, 1)
  equal(server.records(session).fixtures[1].pos.z, 0)
end)

if failed > 0 then error(failed .. " T2 tests failed") end
