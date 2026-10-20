-- Behaviour checks for the AR planner adapter. PUC Lua and the CraftOS
-- sandbox both call this with (test, equal).
return function(test, equal)
  local A = dofile("ar-planner.lua")
  local core = dofile("lib/stubs/a1_planner_core.lua")
  local DIM = "minecraft:overworld"
  local ADA = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  local BOB = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"

  local function cfg()
    return {
      arPlanner = true, chatEnabled = true,
      chatAllowlist = { [ADA] = "Ada", [BOB] = "Bob" },
    }
  end

  local function air(x, y, z)
    return { conf = "observed", name = "minecraft:air" }
  end

  local function world(solids)
    return function(x, y, z)
      local name = solids[x .. "," .. y .. "," .. z]
      if name then return { conf = "observed", name = name } end
      return air(x, y, z)
    end
  end

  local function host(extra)
    local h = {
      cfg = cfg(), detector = {}, dimension = DIM, originId = 4, core = core,
      cell = world({ ["10,65,20"] = "minecraft:stone" }),
    }
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
  end

  local function open(extra)
    local session, why = A.open(host(extra))
    assert(session, why or "open failed")
    return session
  end

  local function player(x, y, z, yaw, pitch)
    return {
      x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0,
      eyeHeight = 1.62, dimension = DIM, name = "Ada",
    }
  end

  local function recorder()
    local calls = {}
    local function rec(name)
      return function(...) calls[#calls + 1] = { name = name, n = select("#", ...), args = { ... } } end
    end
    return {
      clear = rec("clear"), update = rec("update"), delete = rec("delete"),
      drawLine3D = rec("drawLine3D"), drawText2D = rec("drawText2D"),
      drawText3D = rec("drawText3D"), drawRect2D = rec("drawRect2D"),
      drawItemIcon3D = rec("drawItemIcon3D"),
    }, calls
  end

  local function updates(calls)
    local n = 0
    for _, call in ipairs(calls) do if call.name == "update" then n = n + 1 end end
    return n
  end

  test("flag defaults on, explicit false stays off, and a missing detector refuses", function()
    local session, why = A.open({ cfg = {}, detector = {}, dimension = DIM })
    assert(session, why)
    session, why = A.open({ detector = {}, dimension = DIM })
    assert(session, why)
    session, why = A.open({ cfg = { arPlanner = false }, detector = {}, dimension = DIM })
    equal(session, nil)
    equal(why, "off")
    session, why = A.open({ cfg = { arPlanner = 1 }, detector = {}, dimension = DIM })
    equal(session, nil)
    equal(why, "off")
    session, why = A.open({ cfg = { arPlanner = true }, dimension = DIM })
    equal(session, nil)
    equal(why, "no-detector")
  end)

  test("look vector and ray stop only on observed solid", function()
    local south = A.look(0, 0)
    assert(math.abs(south.x) < 1e-9 and math.abs(south.y) < 1e-9 and south.z > 0.9, "yaw 0 looks south")
    local north = A.look(180, 0)
    assert(north.z < -0.9, "yaw 180 looks north")
    local down = A.look(0, 90)
    assert(down.y < -0.9, "positive pitch looks down")
    local solids = { ["2,64,5"] = "minecraft:stone", ["2,64,3"] = "minecraft:air" }
    solids["2,64,4"] = nil
    local function query(x, y, z)
      local key = x .. "," .. y .. "," .. z
      if solids[key] then
        return { conf = "observed", name = solids[key], solid = A.solid("observed", solids[key]) }
      end
      return { conf = "unknown", solid = false }
    end
    local hit, uncertain = A.ray({ x = 2.5, y = 64.5, z = 0.5 }, { x = 0, y = 0, z = 1 }, query, 32)
    equal(hit, { x = 2, y = 64, z = 5, certain = true })
    equal(uncertain, { x = 2, y = 64, z = 1, certain = false, conf = "unknown" })
    local airHit = A.ray({ x = 2.5, y = 64.5, z = 0.5 }, { x = 0, y = 0, z = 1 }, function(x, y, z)
      if x == 2 and y == 64 and z == 3 then
        return { conf = "observed", name = "minecraft:air", solid = false }
      end
      if x == 2 and y == 64 and z == 4 then
        return { conf = "observed", name = "minecraft:stone", solid = true }
      end
      return { conf = "observed", name = "minecraft:air", solid = false }
    end, 32)
    equal(airHit, { x = 2, y = 64, z = 4, certain = true })
  end)

  test("chat samples match the keyboard events and the plan", function()
    local session = open()
    assert(session:sample(player(10.5, 64, 17.3, 0, 0), 0))
    equal(session.hit, { x = 10, y = 65, z = 20, certain = true })
    assert(session:chat("Ada", "$level 64", ADA, true, 0))
    assert(session:chat("Ada", "$plan chest", ADA, true, 1000))
    assert(session:sample(player(12.2, 64, 22.8, 0, 0), 1000))
    assert(session:chat("Ada", "$plan here miner north", ADA, true, 1000))
    assert(session:chat("Ada", "$plan ok", ADA, true, 2000))
    local keyboard = {
      { t = "level", y = 64 },
      { t = "place", kind = "chest", at = A.anchor(10, 65, 20, DIM) },
      { t = "place", kind = "bot", role = "miner", h = 0, at = A.anchor(12, 64, 22, DIM) },
      { t = "confirm" },
    }
    equal(session.log, keyboard)
    local state = core.blank(DIM, 4)
    for _, event in ipairs(keyboard) do state = core.transition(state, event) end
    equal(core.view(session.state), core.view(state))
    local view = core.view(state)
    equal(view.plan.y, 64)
    equal(view.plan.id, "p:4:1")
    equal(view.bots[view.plan.bots[1]].role, "miner")
    equal(view.bots[view.plan.bots[1]].pos.h, 0)
    equal(view.bots[view.plan.bots[1]].state, "code-issued")
    equal(view.fixtures[view.plan.fixtures[1]].kind, "chest")
    equal(view.fixtures[view.plan.fixtures[1]].pos, A.anchor(10, 65, 20, DIM))
  end)

  test("here mode ignores the ray and headings follow north 0", function()
    local session = open({ cell = function() return nil end })
    assert(session:sample(player(4.2, 70, -3.8, 0, 0), 0))
    equal(session.hit, nil)
    assert(session:chat("Ada", "$plan here miner east", ADA, true, 0))
    equal(session.log[1].h, 1)
    equal(session.log[1].at, A.anchor(4, 70, -4, DIM))
    assert(session:chat("Ada", "$plan chest", ADA, true, 0) == true)
    equal(#session.log, 1)
    equal(session.replies[#session.replies].text, "Cursor is uncertain.")
  end)

  test("relative level, undo, and a second planner", function()
    local session = open()
    assert(session:sample(player(10.5, 64, 17.3), 0))
    assert(session:chat("Ada", "$level 63", ADA, true, 0))
    assert(session:chat("Ada", "$level +1", ADA, true, 0))
    equal(session.log, { { t = "level", y = 63 }, { t = "level", y = 64 } })
    assert(session:chat("Ada", "$undo", ADA, true, 0))
    equal(core.view(session.state).plan.y, 63)
    assert(session:chat("Ada", "$level -59", ADA, true, 0))
    equal(session.log[#session.log].y, -59)
    assert(session:chat("Ada", "$undo", ADA, true, 0))
    assert(session:chat("Bob", "$level 70", BOB, true, 0))
    equal(core.view(session.state).plan.y, 63)
    equal(session.replies[#session.replies].text, "Planner is Ada.")
    assert(session:chat("Ada", "$plan ok", ADA, true, 0))
    equal(session.replies[#session.replies].text, "Need a chest and a miner before confirm.")
  end)

  test("allowlist, hidden prefix, and other dimensions", function()
    local session = open()
    equal(session:chat("Ada", "$plan chest", "not-a-uuid", true, 0), false)
    equal(#session.replies, 0)
    equal(session:chat("Ada", "$plan chest", ADA, false, 0), false)
    equal(session:chat("Eve", "$level 64", "cccccccc-dddd-eeee-ffff-000000000000", true, 0), false)
    assert(session:chat("Ada", "level 64", ADA, true, 0))
    equal(session.log[1], { t = "level", y = 64 })
    assert(session:chat("Ada", "$plan miner north", ADA, true, 0))
    equal(session.replies[#session.replies].text, "Use the panel for that.")
    assert(session:sample({ x = 1, y = 64, z = 1, yaw = 0, pitch = 0, dimension = "minecraft:the_nether" }, 1000))
    assert(session:chat("Ada", "$plan chest", ADA, true, 1000))
    equal(session.replies[#session.replies].text, "Other dimensions use the panel.")
    equal(session.hit, nil)
  end)

  test("samples are 4 Hz and frames are 2 Hz, redrawn on boot", function()
    local session = open()
    local first = player(10.5, 64, 17.3)
    local other = player(0.5, 64, 0.5, 180, 0)
    assert(session:sample(first, 0))
    equal(session.hit.z, 20)
    assert(session:sample(other, 100) == false)
    equal(session.hit.z, 20)
    assert(session:sample(other, 250))
    equal(session.hit, nil)
    local ar, calls = recorder()
    session:boot()
    assert(session:draw(0, ar))
    equal(updates(calls), 1)
    assert(calls[1].name == "clear")
    assert(session:draw(100, ar) == false)
    equal(updates(calls), 1)
    session.owner = "Ada"
    session.dirty = true
    assert(session:draw(200, ar) == false)
    equal(updates(calls), 1)
    session.dirty = true
    assert(session:draw(500, ar))
    equal(updates(calls), 2)
    local clears = 0
    for _, call in ipairs(calls) do if call.name == "clear" then clears = clears + 1 end end
    equal(clears, 1)
  end)

  test("drawing keeps the level band, the name, and the element cap", function()
    local session = open()
    session.owner = "Ada"
    session.state.y = 64
    local picture = {
      plan = { y = 64, fixtures = { "near", "far" }, bots = {} },
      fixtures = {
        near = { kind = "chest", pos = A.anchor(1, 64, 2, DIM) },
        far = { kind = "chest", pos = A.anchor(1, 70, 2, DIM) },
      },
      bots = {},
    }
    session.core = {
      view = function() return picture end,
      blank = core.blank, transition = core.transition,
    }
    local ar, calls = recorder()
    session:boot()
    session:draw(0, ar)
    local sawNear, sawFar, sawName, sawIcon = false, false, false, false
    for _, call in ipairs(calls) do
      if call.name == "drawText2D" and call.args[5] == "Planner: Ada" then sawName = true end
      if call.name == "drawItemIcon3D" and call.args[8] == "minecraft:chest" then sawIcon = true end
      if call.name == "drawLine3D" then
        for i = 2, 7 do
          if call.args[i] == 70 or call.args[i] == 71 then sawFar = true end
          if call.args[i] == 64 or call.args[i] == 65 then sawNear = true end
        end
      end
    end
    assert(sawName and sawNear and sawIcon and not sawFar, "level band or hud missing")
    local many = { plan = { y = 64, fixtures = {}, bots = {} }, fixtures = {}, bots = {} }
    for i = 1, 20 do
      local id = "f" .. i
      many.plan.fixtures[i] = id
      many.fixtures[id] = { kind = "chest", pos = A.anchor(i, 64, 0, DIM) }
    end
    session.core.view = function() return many end
    session:boot()
    session:draw(1000, ar)
    equal(session.truncated, true)
    local drawn = 0
    for _, call in ipairs(calls) do
      if call.name ~= "clear" and call.name ~= "update" and call.name ~= "delete" then drawn = drawn + 1 end
    end
    -- The second frame is the one under test. Count only its draws by rebuilding.
    local list = session:elements()
    assert(#list <= 128, "cap " .. #list)
    equal(list[2].id, "a1:hud:name")
  end)

  test("geo scan confirms a solid hit and demotes air", function()
    local scans = 0
    local blocks = { { x = 2, y = 0, z = 0, name = "minecraft:stone" } }
    local sent = {}
    local session = open({
      scannerAt = { x = 8, y = 65, z = 20 },
      scanner = { scan = function(radius)
        scans = scans + 1
        equal(radius, 8)
        return blocks
      end },
      chatBox = {
        sendMessageToPlayer = function(message, username)
          sent[#sent + 1] = { "whisper", message, username }
        end,
        sendToastToPlayer = function(message, title, username)
          sent[#sent + 1] = { "toast", message, title, username }
        end,
      },
    })
    assert(session:sample(player(10.5, 64, 17.3), 0))
    blocks[1].name = "minecraft:air"
    assert(session:chat("Ada", "$plan chest", ADA, true, 0))
    equal(#session.log, 0)
    equal(session.replies[#session.replies].text, "Cursor is uncertain.")
    equal(scans, 1)
    blocks[1].name = "minecraft:stone"
    assert(session:sample(player(10.5, 64, 17.3), 2500))
    assert(session:chat("Ada", "$plan chest", ADA, true, 2500))
    equal(scans, 2)
    equal(session.log[1].kind, "chest")
    equal(session.log[1].at, A.anchor(10, 65, 20, DIM))
  end)

  test("confirm delivers the copy code by whisper, toast, and HUD", function()
    local sent = {}
    local session = open({
      chatBox = {
        sendMessageToPlayer = function(message, username) sent[#sent + 1] = { "whisper", message, username } end,
        sendToastToPlayer = function(message, title, username) sent[#sent + 1] = { "toast", message, title, username } end,
      },
      core = {
        blank = core.blank, view = core.view,
        transition = function(state, event)
          local nextState, effects = core.transition(state, event)
          if effects[1] and effects[1].op == "plan-code" then effects[1].code = "K7Q2M9XDPT" end
          return nextState, effects
        end,
      },
    })
    assert(session:sample(player(10.5, 64, 17.3), 0))
    assert(session:chat("Ada", "$plan chest", ADA, true, 0))
    assert(session:chat("Ada", "$plan here miner north", ADA, true, 0))
    assert(session:chat("Ada", "$plan ok", ADA, true, 0))
    equal(sent, {
      { "whisper", "K7Q2M9XDPT", "Ada" },
      { "toast", "K7Q2M9XDPT", "Copy code", "Ada" },
    })
    local ar, calls = recorder()
    session:boot()
    session:draw(0, ar)
    local saw = false
    for _, call in ipairs(calls) do
      if call.name == "drawText2D" and call.args[5] == "Code: K7Q2M9XDPT" then saw = true end
    end
    assert(saw, "code missing from the HUD")
    local polls = 0
    session.follow = "Ada"
    session.detector = { getPlayerPos = function(name)
      polls = polls + 1
      equal(name, "Ada")
      return player(10.5, 64, 17.3)
    end }
    assert(session:poll(5000))
    assert(session:poll(5100) == false)
    equal(polls, 1)
    assert(session:poll(5250))
    equal(polls, 2)
  end)
end
