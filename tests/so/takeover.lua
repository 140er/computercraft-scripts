-- Status takeovers: the 30 s queue, standing alerts after a restart, the drop subject,
-- the server monitor's render errors and the oversize frame trim.
local H = dofile("tests/so/harness.lua")

local function boot(values, opts)
  opts = opts or {}
  local net = H.new()
  local m = net.machine({id=1})
  m.install({"so-store.lua", "so-ui.lua", "so-mod-display.lua"})
  local s = { clock = 0, errors = {}, values = values, m = m }
  m.env.SO = { now = function() return s.clock end,
    mods = { state = { view = function() return { values = s.values } end, get = function(key) return key == "machines" and opts.machines or {} end },
      drops = opts.drops, map = opts.map },
    store = m.env.dofile("so-store.lua"), pair = { key = function() return "key" end },
    proto = { ser = H.encode, build = function(_, _, body) return body end, encode = opts.encode or function(body) return body end },
    error = function(line) s.errors[#s.errors + 1] = line end }
  if opts.peripheral then m.env.peripheral = opts.peripheral end
  local d = m.env.dofile("so-mod-display.lua")
  s.d = d
  s.open = function(role, w, h, id)
    id = id or 2
    d.handlers.hello({from=id, body={w=w or 39, h=h or 13}})
    assert(d.assign(id, role or "status"))
    d.handlers["view.sub"]({from=id})
  end
  s.at = function(ms) s.clock = ms; d.tick(ms) end
  s.frame = function(id)
    for i = #m.sent, 1, -1 do
      if m.sent[i].id == (id or 2) then return m.sent[i].payload end
    end
  end
  s.text = function(id)
    local lines = {}
    for _, row in ipairs(s.frame(id).rows) do lines[#lines + 1] = row.text end
    return table.concat(lines, "\n")
  end
  s.takeover = function(id)
    local frame = s.frame(id)
    for _, b in ipairs(frame and frame.buttons or {}) do
      if b.id == "dismiss" then return s.text(id) end
    end
  end
  return s
end

return function(test, equal)
  test("a second alert within 30 s takes over once the gate opens", function()
    local s = boot({})
    s.open()
    s.at(0)
    equal(s.takeover(), nil)
    s.values["a.alert"] = { text = "alpha" }
    s.at(1000)
    assert((s.takeover() or ""):find("ALPHA", 1, true), "A takes over")
    s.values["b.alert"] = { text = "beta" }
    s.at(11000)
    equal(s.takeover(), nil, "B waits for the 30 s gate")
    s.at(21000)
    equal(s.takeover(), nil)
    s.at(31000)
    assert((s.takeover() or ""):find("BETA", 1, true), "B takes over at 30 s")
  end)

  test("a restart raises the newest standing alert once, and new ones after the gate", function()
    local s = boot({ ["mine.alert"] = { text = "standing hold" }, ["lumber.alert"] = { text = "standing saplings" } })
    s.open()
    s.at(1000)
    local first = s.takeover() or ""
    assert(first:find("STANDING", 1, true), "one standing alert takes over after the restart")
    s.at(6000)
    equal(s.takeover(), nil)
    s.at(32000)
    equal(s.takeover(), nil, "the other standing alert stays seen")
    s.values["shop.alert"] = { text = "out of sand" }
    s.at(33000)
    assert((s.takeover() or ""):find("OUT OF SAND", 1, true), "a new alert takes over")
  end)

  test("a display opened between gathers knows the alert raised since as standing", function()
    local s = boot({})
    s.open()
    s.at(1000)
    s.values["a.alert"] = { text = "alpha" }
    s.open("status", 39, 13, 3)
    s.at(2000)
    assert((s.takeover(2) or ""):find("ALPHA", 1, true), "the open display takes over")
    equal(s.takeover(3), nil, "the new display already found it standing")
  end)

  test("a cleared alert leaves alertSeen and takes over again when it returns", function()
    local s = boot({})
    s.open()
    s.at(0)
    s.values["a.alert"] = { text = "alpha" }
    s.at(1000)
    assert(s.takeover())
    s.values["a.alert"] = nil
    s.at(10000)
    equal(s.takeover(), nil)
    s.values["a.alert"] = { text = "alpha" }
    s.at(40000)
    assert((s.takeover() or ""):find("ALPHA", 1, true), "the returning alert is new again")
  end)

  test("a drop-break takeover names the broken drop by point id", function()
    local points = {
      { id = "1", kind = "ore", x = 10, y = 64, z = 10 },
      { id = "2", kind = "ore", x = 20, y = 65, z = 20, broken = true },
    }
    local s = boot({}, { drops = { list = function() return points end } })
    s.open()
    s.at(0)
    s.values["drops.alert"] = { kind = "ore", text = "ore #2 broken", reason = "broken",
      point = { id = "2", kind = "ore", x = 20, y = 65, z = 20 } }
    s.at(1000)
    local text = assert(s.takeover(), "the drop alert takes over")
    assert(text:find("20,65,20", 1, true), "takeover shows drop 2: " .. text)
    assert(not text:find("10,64,10", 1, true), "takeover must not show drop 1")
  end)

  test("a server monitor render error is logged once and the monitor rebuilt next tick", function()
    local finds = 0
    local monitor = { setTextScale = function() error("boom") end, getSize = function() return 39, 13 end }
    local s = boot({}, { peripheral = {
      find = function(kind) if kind == "monitor" then finds = finds + 1; return monitor end end,
      getName = function() return "top" end } })
    s.at(1000)
    equal(#s.errors, 1)
    assert(s.errors[1]:find("monitor top", 1, true) and s.errors[1]:find("boom", 1, true), s.errors[1])
    s.at(1050)
    equal(finds, 2, "the next tick rebuilds the monitor")
    equal(#s.errors, 1, "the same error is logged once")
  end)

  -- The frame only fits once a single row and the BACK and nav controls are left.
  local NAV = { "status", "turtle-back", "turtle-cancel", "panel-back", "paired-back", "items",
    "tab:fleet", "tab:jobs", "alert-prev", "alert-next" }
  local function trimmed(page)
    local nav = {}
    for _, id in ipairs(NAV) do nav[id] = true end
    local s = boot({}, { encode = function(body)
      if #body.rows > 1 then return nil end
      for _, b in ipairs(body.buttons) do if not nav[b.id] then return nil end end
      return body
    end })
    s.d.screen("generic", page, function() end)
    s.open("drops", 26, 20)
    s.at(1000)
    local ids = {}
    for _, b in ipairs(assert(s.frame(), "a trimmed frame is sent").buttons) do ids[#ids + 1] = b.id end
    return ids
  end

  test("an oversize frame keeps BACK while it sheds buttons", function()
    equal(table.concat(trimmed(function()
      return { rows = { { text = "a" }, { text = "b" }, { text = "c" } },
        buttons = { { id = "one", x = 1, y = 1, w = 3 }, { id = "two", x = 1, y = 2, w = 3 },
          { id = "status", label = "BACK", x = 1, y = 3, w = 4 } } }
    end), ","), "status")
  end)

  test("an oversize turtle page keeps turtle-back", function()
    local U = dofile("so-ui.lua")
    local ids = trimmed(function(w, h)
      return U.turtle.render(w, h, { id = 5 }, { role = "mining", state = "mining", pose = { x = 1, y = 2, z = 3, facing = 0 } }, 0)
    end)
    equal(ids[#ids], "turtle-back")
    for _, id in ipairs(ids) do assert(id == "turtle-back", "only BACK is left, got " .. id) end
    ids = trimmed(function(w, h)
      return U.turtle.render(w, h, { id = 5, draft = { x = 1, y = 2, z = 3, facing = 0 } }, {}, 0)
    end)
    equal(table.concat(ids, ","), "turtle-cancel")
  end)

  test("an oversize pocket tab page keeps its tabs, pager and BACK", function()
    local U = dofile("so-ui.lua")
    local ids = trimmed(function(w, h)
      local c = U.canvas(w, h)
      c.bar("FLEET", { "FLEET", "JOBS" }, "FLEET")
      for y = 2, 6 do c.hit("row:" .. y, 1, y, w, 1) end
      c.hit("alert-prev", 1, 7, 3, 1); c.hit("alert-next", 5, 7, 3, 1)
      c.hit("items", 1, 8, 5, 1); c.hit("paired-back", 1, 9, 4, 1); c.hit("panel-back", 1, 10, 4, 1)
      return c.frame()
    end)
    table.sort(ids)
    equal(table.concat(ids, ","), "alert-next,alert-prev,items,paired-back,panel-back,tab:fleet,tab:jobs")
  end)

  test("the status model has no undrawn PAIR tile", function()
    local s = boot({})
    s.open()
    s.at(1000)
    for _, tile in ipairs(s.d.statusModel().tiles) do assert(tile.label ~= "PAIR") end
  end)

  local function tap(s, id, button)
    s.d.handlers.input({ from = id or 2, body = { id = button, x = 1, y = 1 } })
  end
  local function has(s, id, button)
    for _, b in ipairs(s.frame(id).buttons or {}) do if b.id == button then return true end end
    return false
  end

  test("SNOOZE mutes takeovers on that display alone for five minutes", function()
    local s = boot({})
    s.open()
    s.open("status", 39, 13, 3)
    s.at(0)
    s.values["a.alert"] = { text = "alpha" }
    s.at(1000)
    assert(has(s, 2, "snooze"), "the takeover draws SNOOZE")
    tap(s, 2, "snooze")
    equal(s.takeover(2), nil, "SNOOZE ends the takeover")
    s.values["b.alert"] = { text = "beta" }
    s.at(40000)
    equal(s.takeover(2), nil, "the snoozed display stays on status")
    assert((s.takeover(3) or ""):find("BETA", 1, true), "the other display still takes over")
    local count
    for _, tile in ipairs(s.d.statusModel().tiles) do if tile.label == "ALERTS" then count = tile.value end end
    equal(count, "2", "the alert count stays")
    s.at(300000)
    equal(s.takeover(2), nil)
    s.values["c.alert"] = { text = "gamma" }
    s.at(302000)
    assert((s.takeover(2) or ""):find("GAMMA", 1, true), "a new alert takes over once the snooze ends")
    s.at(340000)
    equal(s.takeover(2), nil, "an alert raised during the snooze does not take over later")
  end)

  test("the snooze helper keeps one end time per key in memory", function()
    local s = boot({})
    local snooze = s.d.snoozer(300000)
    equal(snooze.on("t5", 0), false)
    snooze.set("t5", 1000)
    local on, left = snooze.on("t5", 2000)
    equal(on, true); equal(left, 299000)
    equal(snooze.on("t6", 2000), false, "one key at a time")
    equal(snooze.on("t5", 301000), false, "it ends after the span")
    snooze.set("t5", 400000)
    snooze.clear("t5")
    equal(snooze.on("t5", 400001), false, "clear ends it at once")
  end)

  -- SO.proto.ser calls in one tick: compose serialises each row and the signature.
  local function idleCost(role, displays, render)
    local s = boot({})
    if render then s.d.screen(role == "drops" and "generic" or role, render, function() end) end
    for i = 1, displays do s.open(role, 39, 13, 10 + i) end
    for t = 1, 6 do s.at(t * 1000) end
    local calls, ser = 0, s.m.env.SO.proto.ser
    s.m.env.SO.proto.ser = function(v) calls = calls + 1; return ser(v) end
    s.at(6500)
    s.m.env.SO.proto.ser = ser
    return calls, s
  end

  test("an unchanged status display is not composed again", function()
    equal(idleCost("status", 6), idleCost("status", 1), "the tick cost does not grow with idle displays")
  end)

  test("an unchanged page only signs its picture", function()
    local page = function()
      return { rows = { { text = "one" }, { text = "two" }, { text = "three" } }, buttons = {} }
    end
    equal(idleCost("drops", 6, page) - idleCost("drops", 1, page), 5, "one signature per display")
  end)

  test("an idle status display still beats every 4 s and a change sends on the next tick", function()
    local machines = {}
    local s = boot({}, { machines = machines })
    for i = 1, 3 do s.open("status", 39, 13, 10 + i) end
    s.at(1000)
    local before = #s.m.sent
    for t = 2, 9 do s.at(t * 1000) end
    equal(#s.m.sent - before, 6, "two heartbeats per display in 8 s")
    local rev = s.frame(11).rev
    machines[7] = { role = "worker" }
    before = #s.m.sent
    s.at(9500)
    equal(#s.m.sent - before, 3, "every display gets the change at once")
    assert(s.frame(11).rev > rev, "the new frame has a new rev")
  end)

  -- A map module whose thumbnail draws one letter, so a test can change what it shows.
  local function fakeMap()
    local map = { mark = "a" }
    map.thumb = function(C, x, y) C.put(x, y, map.mark, "0"); return true end
    return map
  end

  test("with the map loaded an unchanged status wall is not composed again", function()
    local function cost(displays)
      local s = boot({}, { map = fakeMap() })
      for i = 1, displays do s.open("status", 100, 38, 10 + i) end
      for t = 1, 6 do s.at(t * 1000) end
      local calls, ser = 0, s.m.env.SO.proto.ser
      s.m.env.SO.proto.ser = function(v) calls = calls + 1; return ser(v) end
      s.at(6500)
      s.m.env.SO.proto.ser = ser
      return calls
    end
    equal(cost(6), cost(1), "the tick cost does not grow with idle walls")
  end)

  test("a map thumbnail change sends to every status wall on the next tick", function()
    local map = fakeMap()
    local s = boot({}, { map = map })
    for i = 1, 3 do s.open("status", 100, 38, 10 + i) end
    for t = 1, 6 do s.at(t * 1000) end
    assert(s.text(11):find("a", 1, true))
    local rev = s.frame(11).rev
    map.mark = "Q"
    local before = #s.m.sent
    s.at(6500)
    equal(#s.m.sent - before, 3, "every wall gets the new thumbnail at once")
    assert(s.frame(11).rev > rev, "the new frame has a new rev")
    assert(s.text(11):find("Q", 1, true), "the frame shows the new thumbnail")
  end)
end
