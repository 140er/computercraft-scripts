local mocks = dofile("tests/mocks.lua")
local env = mocks.new(false).env
env.dofile = function(path) return assert(loadfile(path, "t", env))() end
local Core = env.dofile("planner-core.lua")
local Ops = env.dofile("planner-ops.lua")
local View = env.dofile("planner-view.lua")
local Host = env.dofile("planner-host.lua")
local Settings = env.dofile("planner-settings.lua")
local Map = env.dofile("planner-map.lua")
local S = env.dofile("ssot.lua")
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or "\n  " .. tostring(err)))
  if not ok then failed = failed + 1 end
end

local function eq(actual, expected, message)
  assert(mocks.encode(actual) == mocks.encode(expected), (message or "values differ")
    .. "\nexpected: " .. mocks.encode(expected) .. "\nactual: " .. mocks.encode(actual))
end

local function step(state, event, now)
  local nextState, effects, err = Core.transition(state, event, now or 5000)
  assert(nextState, err or "missing state")
  assert(not err, err)
  return nextState, effects
end

local function reload(state)
  local text = env.textutils.serialize(state)
  local loaded = env.textutils.unserialize(text)
  assert(Ops.valid(loaded), "reloaded plan is invalid")
  eq(loaded.rev, state.rev, "rev survived reload")
  eq(loaded.active, state.active, "active plan survived reload")
  return loaded
end

local function build()
  local state = Core.empty(4, 1700000000000)
  state = step(state, { t = "anchor", x = 100, y = 64, z = 200, h = 0, dim = "minecraft:overworld" })
  state = step(state, { t = "create", name = "Base" })
  state = step(state, { t = "draw", x1 = 100, z1 = 200, x2 = 106, z2 = 206 })
  state = step(state, { t = "place", kind = "chest", x = 102, z = 202 })
  state = step(state, { t = "place", kind = "bot", x = 102, z = 201, role = "miner" })
  return state
end

test("create, edit, save and reload a plan", function()
  local state = build()
  local created = state.rev
  state = step(state, { t = "edit", what = "name", name = "Yard" })
  assert(state.rev == created + 1, "edit bumps rev")
  state = step(state, { t = "edit", what = "chest", x = 103, z = 202 })
  local plan = state.plans[state.active]
  eq(plan.name, "Yard")
  local chest = state.fixtures[plan.fixtures[1]]
  eq(chest.pos.x, 103)
  eq(chest.pos.frame, "abs")
  state = step(state, { t = "edit", what = "chest", x = 102, z = 202 })
  local loaded = reload(state)
  eq(loaded.plans[loaded.active].name, "Yard")
  eq(loaded.fixtures[loaded.plans[loaded.active].fixtures[1]].pos, state.fixtures[plan.fixtures[1]].pos)
  eq(loaded.bots[loaded.plans[loaded.active].bots[1]].role, "miner")
  eq(loaded.bots[loaded.plans[loaded.active].bots[1]].settings, { revision = 4, overrides = {} })
end)

test("level slider changes the viewed level and keeps the other slice", function()
  local state = build()
  local plan = state.plans[state.active]
  local chestY = state.fixtures[plan.fixtures[1]].pos.y
  state = step(state, { t = "level", y = 65 })
  eq(state.y, 65)
  eq(state.plans[state.active].y, 64, "the base level stays put")
  eq(state.fixtures[plan.fixtures[1]].pos.y, chestY)
  local blocked = Core.transition(state, { t = "place", kind = "chest", x = 102, z = 202 })
  assert(not blocked, "a second level cannot take a second chest")
  state = step(state, { t = "level", dy = -1 })
  eq(state.y, 64)
  local loaded = reload(state)
  eq(loaded.y, 64)
  eq(loaded.fixtures[loaded.plans[loaded.active].fixtures[1]].pos.y, 64)
end)

test("issue and claim save the planned pose, role and settings", function()
  local state = build()
  local effects
  state, effects = step(state, { t = "issue" }, 8000)
  local code, untilAt
  for _, effect in ipairs(effects) do
    if effect.op == "code" then code, untilAt = effect.code, effect.untilAt end
  end
  assert(code and #code == 10, "copy code")
  eq(untilAt, 8000 + 900000, "planner codes last 15 minutes")
  local bot = state.bots[state.plans[state.active].bots[1]]
  eq(bot.state, "code-issued")
  eq(bot.pos.h, 2, "miner faces the chest, south")
  eq(bot.expect.neighbours[2], "minecraft:chest")
  local observe = {
    h = 2,
    blocks = {
      front = "minecraft:chest", back = "minecraft:air", left = "minecraft:air",
      right = "minecraft:air", up = "minecraft:air", down = "minecraft:stone",
    },
    peripherals = { front = "inventory" },
  }
  local claimed, claimEffects = step(state, { t = "claim", code = code, observe = observe, computerId = 31 }, 9000)
  local sync
  for _, effect in ipairs(claimEffects) do if effect.op == "sync" then sync = effect end end
  eq(sync.role, "miner")
  eq(sync.settings, bot.settings)
  eq({ sync.pose.x, sync.pose.y, sync.pose.z, sync.pose.h, sync.pose.conf, sync.pose.frame },
    { 102, 64, 201, 2, "certain", "abs" })
  eq(claimed.bots[bot.id].state, "claimed")
  eq(claimed.codes[code].used, true)
  local again, _, err = Core.transition(claimed, { t = "claim", code = code, observe = observe, computerId = 32 }, 9000)
  assert(not again and err == "code used", err)
end)

test("a neighbourhood that misses the chest is a wrong cell", function()
  local state = step(build(), { t = "issue" }, 8000)
  local code = state.bots[state.plans[state.active].bots[1]].code
  local observe = {
    h = 2,
    blocks = {
      front = "minecraft:stone", back = "minecraft:stone", left = "minecraft:stone",
      right = "minecraft:stone", up = "minecraft:stone", down = "minecraft:stone",
    },
    peripherals = {},
  }
  local nextState, effects, err = Core.transition(state, { t = "claim", code = code, observe = observe, computerId = 32 }, 9000)
  eq(err, "wrong cell")
  eq(effects[1].text, "Wrong cell. The blocks around this turtle do not match the plan.")
  eq(nextState.codes[code].attempts, 1)
  eq(nextState.codes[code].used, false)
  eq(nextState.bots[state.plans[state.active].bots[1]].state, "code-issued")
end)

test("map confidence stub and settings stub", function()
  local sample = { ["minecraft:overworld|1|64|2"] = { conf = "observed", name = "minecraft:chest" } }
  eq(Map.confidence(sample, "minecraft:overworld", 1, 64, 2), "observed")
  eq(Map.name(sample, "minecraft:overworld", 1, 64, 2), "minecraft:chest")
  eq(Map.confidence(sample, "minecraft:overworld", 0, 64, 0), "unknown")
  eq(Map.confidence({ ["minecraft:overworld|0|64|0"] = "predicted" }, "minecraft:overworld", 0, 64, 0), "predicted")
  local stored = Settings.forBot("miner")
  eq(stored, { revision = 4, overrides = {} })
  eq(Settings.effective("miner", stored).values.branchLength, 64)
  assert(not Settings.forBot("farmer"), "mvp settings know the miner role only")
end)

test("monitor render at the section 5b sizes", function()
  local sizes = { { 328, 162 }, { 164, 81 }, { 51, 19 }, { 39, 13 }, { 26, 20 } }
  local function classAt(x, z)
    local row = { "unknown", "predicted", "known", "intent", "occupied", "base", "chest", "bot" }
    return row[x + 1] or "unknown"
  end
  for _, size in ipairs(sizes) do
    local rows = {}
    local screen = {
      getSize = function() return size[1], size[2] end,
      clear = function() end,
      setCursorPos = function() end,
      blit = function(text, fg, bg)
        assert(#text == size[1] and #fg == size[1] and #bg == size[1], "blit width " .. size[1])
        rows[#rows + 1] = { text = text, fg = fg, bg = bg }
      end,
    }
    local layout = View.paint(screen, {
      name = "Base", y = 64, rev = 3, originX = 0, originZ = 0,
      classAt = classAt, headingAt = function(x) if x == 7 then return 2 end end,
    })
    eq(#rows, size[2], "one blit per row at " .. size[1] .. "x" .. size[2])
    assert(rows[1].text:find("y64", 1, true), "level label")
    assert(rows[2].text:find("[-]", 1, true) and rows[2].text:find("[+]", 1, true), "level slider")
    local map = rows[3].text
    eq(map:sub(1, 8), "?+#!@.Cv")
    eq(rows[3].bg:sub(1, 8), "f874e31d")
    if size[1] == 26 and size[2] == 20 then
      eq(layout.mapTop, 3)
      eq(size[2] - layout.mapTop + 1, 18, "pocket map is 18 rows")
      eq(size[1], 26, "pocket map is 26 columns")
    end
  end
end)

test("host touch switches level and issues a code", function()
  local stored = { planner = Core.empty(4, 1000), poses = {}, moves = {} }
  local api = {
    plan = function(event)
      local effects, err = Ops.commit(stored, event, function() return 5000 end, 4, "server")
      return { ok = err == nil, error = err or false, effects = effects, rev = stored.planner.rev, state = stored.planner }
    end,
    state = function() return stored end,
  }
  local rows = {}
  local screen = {
    getSize = function() return 51, 19 end,
    clear = function() end,
    setCursorPos = function() end,
    blit = function(text) rows[#rows + 1] = text end,
  }
  local host = Host.attach({ ssot = api, screen = screen, clock = function() return 5000 end })
  host.draw()
  local plus
  for _, hit in ipairs(host.layout.hits) do
    if hit.kind == "level" and hit.dy == 1 then plus = hit end
  end
  assert(plus, "slider plus")
  host.touch(plus.x1, plus.row)
  rows = {}
  host.draw()
  assert(rows[1]:find("y65", 1, true), "touch raised the level")
  host.apply({ t = "anchor", x = 10, y = 65, z = 10, h = 0, dim = "minecraft:overworld" })
  host.apply({ t = "create", name = "Base" })
  host.apply({ t = "level", y = 65 })
  host.apply({ t = "draw", x1 = 8, z1 = 8, x2 = 14, z2 = 14 })
  host.apply({ t = "place", kind = "chest", x = 10, z = 12 })
  host.apply({ t = "place", kind = "bot", x = 10, z = 11 })
  local issued = host.apply({ t = "issue" })
  local code
  for _, effect in ipairs(issued.effects) do if effect.op == "code" then code = effect.code end end
  assert(code, "host issued a code")
  rows = {}
  host.draw()
  assert(table.concat(rows, "\n"):find(code, 1, true), "monitor shows the code")
  local loaded = reload(api.state().planner)
  eq(loaded.rev, stored.planner.rev)
end)

test("dispatcher stores intents, blocks the cell, and claims through sync", function()
  local time, counter, saved = 10000, {}, nil
  local cfg = { controllers = { ["1"] = "test-secret-123456", ["2"] = "test-secret-123456" } }
  local api = S.new({}, cfg, function() return time end, "boot-1", function(s) saved = s return true end)
  local function request(id, op, fields)
    counter[id] = (counter[id] or 0) + 1
    local message = fields or {}
    message.v, message.type, message.expect, message.op = 1, "ssot", "ssot_reply", op
    message.boot, message.rid, message.counter = "turtle-" .. id, "r" .. counter[id], counter[id]
    message.secret = cfg.controllers[tostring(id)]
    return api.handle(id, message)
  end
  assert(request(1, "plan-put", { rev = api.state().planner.rev, event = { t = "anchor", x = 0, y = 64, z = 0, h = 0, dim = "minecraft:overworld" } }).ok)
  local rev = api.state().planner.rev
  assert(request(1, "plan-put", { rev = rev, event = { t = "create", name = "Base" } }).ok)
  rev = api.state().planner.rev
  assert(request(1, "plan-put", { rev = rev, event = { t = "draw", x1 = 0, z1 = 0, x2 = 4, z2 = 4 } }).ok)
  rev = api.state().planner.rev
  assert(not request(1, "plan-put", { rev = rev - 1, event = { t = "place", kind = "chest", x = 2, z = 2 } }).ok, "stale rev")
  assert(request(1, "plan-put", { rev = rev, event = { t = "place", kind = "chest", x = 2, z = 2 } }).ok)
  rev = api.state().planner.rev
  assert(request(1, "plan-put", { rev = rev, event = { t = "place", kind = "bot", x = 2, z = 1 } }).ok)
  local holds = request(1, "plan-intent", {})
  assert(holds.ok and #holds.holds == 2, "chest and miner intents")
  assert(request(1, "sync", { pose = { dim = "minecraft:overworld", x = 1, y = 64, z = 1 } }).ok)
  local blocked = request(1, "reserve", { pose = { dim = "minecraft:overworld", x = 1, y = 64, z = 1 }, to = { dim = "minecraft:overworld", x = 2, y = 64, z = 1 } })
  eq(blocked.ok, false)
  eq(blocked.error, "occupied")
  local traffic = request(1, "traffic", { to = { dim = "minecraft:overworld", x = 2, y = 64, z = 1 } })
  eq(traffic.ok, false)
  eq(traffic.error, "occupied")
  local issued = request(1, "plan-code", {})
  assert(issued.ok and issued.code, issued.error)
  local good = {
    h = 2,
    blocks = { front = "minecraft:chest", back = "minecraft:air", left = "minecraft:air", right = "minecraft:air", up = "minecraft:air", down = "minecraft:stone" },
    peripherals = { front = "inventory" },
  }
  local wrong = request(2, "plan-claim", { code = issued.code, observe = {
    h = 2,
    blocks = { front = "minecraft:stone", back = "minecraft:stone", left = "minecraft:stone", right = "minecraft:stone", up = "minecraft:air", down = "minecraft:stone" },
    peripherals = {},
  } })
  eq(wrong.ok, false)
  eq(wrong.error, "wrong cell")
  assert(wrong.screen:find("Wrong cell", 1, true), wrong.screen)
  local claimed = request(2, "plan-claim", { code = issued.code, observe = good })
  assert(claimed.ok, claimed.error)
  eq(claimed.role, "miner")
  eq(claimed.settings, { revision = 4, overrides = {} })
  eq({ claimed.pose.x, claimed.pose.y, claimed.pose.z, claimed.pose.h, claimed.pose.conf }, { 2, 64, 1, 2, "certain" })
  eq(api.state().poses[2].x, 2)
  local reloaded = reload(saved.planner)
  eq(reloaded.bots[claimed.pose and api.state().planner.plans[api.state().planner.active].bots[1]].state, "claimed")
  assert(not api.state().planner.codes[issued.code] or api.state().planner.codes[issued.code].used)
end)

test("plan-claim accepts a turtle that has no pairing secret", function()
  local time, counter = 10000, {}
  local cfg = { controllers = { ["1"] = "test-secret-123456" } }
  local api = S.new({}, cfg, function() return time end, "boot-1", function() return true end)
  local function send(id, op, fields, secret)
    counter[id] = (counter[id] or 0) + 1
    local message = fields or {}
    message.v, message.type, message.expect, message.op = 1, "ssot", "ssot_reply", op
    message.boot, message.rid, message.counter = "turtle-" .. id, "r" .. id .. "-" .. counter[id], counter[id]
    if secret ~= nil then message.secret = secret end
    return api.handle(id, message)
  end
  assert(send(1, "plan-put", { event = { t = "anchor", x = 0, y = 64, z = 0, h = 0, dim = "minecraft:overworld" } }, cfg.controllers["1"]).ok)
  local rev = api.state().planner.rev
  assert(send(1, "plan-put", { rev = rev, event = { t = "create", name = "Base" } }, cfg.controllers["1"]).ok)
  rev = api.state().planner.rev
  assert(send(1, "plan-put", { rev = rev, event = { t = "draw", x1 = 0, z1 = 0, x2 = 4, z2 = 4 } }, cfg.controllers["1"]).ok)
  rev = api.state().planner.rev
  assert(send(1, "plan-put", { rev = rev, event = { t = "place", kind = "chest", x = 2, z = 2 } }, cfg.controllers["1"]).ok)
  rev = api.state().planner.rev
  assert(send(1, "plan-put", { rev = rev, event = { t = "place", kind = "bot", x = 2, z = 1 } }, cfg.controllers["1"]).ok)
  local issued = send(1, "plan-code", {}, cfg.controllers["1"])
  assert(issued.ok and issued.auth == cfg.controllers["1"], "paired reply still carries the secret")
  local good = {
    h = 2,
    blocks = { front = "minecraft:chest", back = "minecraft:air", left = "minecraft:air", right = "minecraft:air", up = "minecraft:air", down = "minecraft:stone" },
    peripherals = { front = "inventory" },
  }
  assert(send(9, "plan-claim", { code = issued.code, observe = good }, "not-the-secret") == nil, "a wrong secret is rejected")
  assert(not api.state().planner.codes[issued.code].used, "a rejected secret does not burn the code")
  local claimed = send(9, "plan-claim", { code = issued.code, observe = good })
  assert(claimed and claimed.ok, claimed and claimed.error)
  eq(claimed.auth, false)
  eq({ claimed.pose.x, claimed.pose.y, claimed.pose.z, claimed.pose.h, claimed.pose.conf }, { 2, 64, 1, 2, "certain" })
  eq(api.state().poses[9].x, 2)
end)

test("an unanchored plan keeps a relative frame until F3 entry", function()
  local state = step(Core.empty(4, 10), { t = "create", name = "Base" })
  state = step(state, { t = "draw", x1 = 0, z1 = 0, x2 = 2, z2 = 2 })
  local plan = state.plans[state.active]
  eq(plan.frame, "f:4:10")
  eq(plan.areas[1].min.frame, "f:4:10")
  eq(plan.areas[1].min.yAbs, true)
  state = step(state, { t = "anchor", x = 5, y = 64, z = 7, h = 1, dim = "minecraft:overworld" })
  plan = state.plans[state.active]
  eq(plan.frame, "abs")
  eq({ plan.areas[1].min.x, plan.areas[1].min.z, plan.areas[1].max.x, plan.areas[1].max.z }, { 5, 7, 7, 9 })
  local again = step(state, { t = "anchor", x = 9, y = 64, z = 9, h = 0, dim = "minecraft:overworld" })
  eq(again.rev, state.rev, "a second anchor is a no-op")
  eq(again.plans[again.active].areas[1].min.x, 5)
end)

test("retiring a plan releases its intents in one revision", function()
  local state = build()
  local before = state.rev
  assert(Core.blocks(state, { dim = "minecraft:overworld", x = 102, y = 64, z = 202 }))
  state = step(state, { t = "retire" })
  eq(state.rev, before + 1)
  eq(state.active, false)
  assert(not Core.blocks(state, { dim = "minecraft:overworld", x = 102, y = 64, z = 202 }))
  assert(not Core.blocks(state, { dim = "minecraft:overworld", x = 102, y = 64, z = 201 }))
end)

test("planner sources do not call satellite locating", function()
  for _, name in ipairs({ "planner-core.lua", "planner-host.lua", "planner-view.lua", "planner-ops.lua",
    "planner-enrol.lua", "planner-settings.lua", "planner-map.lua", "planner-claim.lua" }) do
    local file = assert(io.open(name, "rb"))
    local source = file:read("*a")
    file:close()
    assert(not source:find("gps", 1, true), name)
    assert(not source:find("locate", 1, true), name)
  end
end)

assert(failed == 0, failed .. " planner failures")
