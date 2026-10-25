-- Server-side display commands and taps: far and identify from the R prompt, turtle rows,
-- lost flags and the takeover chip opening the turtle, labels in the role list, stale ids
-- on the DISPLAYS tile, immediate monitor taps and the status ALERTS list.
local H = dofile("tests/so/harness.lua")
local R = dofile("tests/ui/render.lua")

-- A sent frame against its twin fixture (docs/ui/schematic/system.py alert_list), in text, fg and bg.
local function match(path, frame)
  local fixture = R.load(path)
  local out = R.capture(fixture.w, fixture.h)
  for y, row in ipairs(frame.rows) do
    local fg, bg = {}, {}
    for _, run in ipairs(row.runs or {}) do fg[#fg + 1], bg[#bg + 1] = string.rep(run[2], run[1]), string.rep(run[3], run[1]) end
    fg, bg = table.concat(fg), table.concat(bg)
    if not row.runs then
      fg = #row.fg == 1 and string.rep(row.fg, #row.text) or row.fg
      bg = #row.bg == 1 and string.rep(row.bg, #row.text) or row.bg
    end
    out.setCursorPos(1, y)
    out.blit(row.text .. string.rep(" ", #fg - #row.text), fg, bg)
  end
  local diff = R.diff(fixture, out)
  assert(#diff == 0, path .. "\n" .. table.concat(diff, "\n"))
end

-- A screen that records blit rows by y.
local function screen(w, h)
  local s = { w = w, h = h, rows = {}, scales = {}, blits = 0 }
  s.target = {
    setTextScale = function(n) s.scales[#s.scales + 1] = n end,
    getSize = function() return s.w, s.h end,
    setCursorPos = function(_, y) s.y = y end,
    blit = function(text) s.rows[s.y] = text; s.blits = s.blits + 1 end,
    getCursorPos = function() return 1, s.y or 1 end,
  }
  s.text = function() return table.concat(s.rows, "\n", 1, s.h) end
  return s
end

local function boot(opts)
  opts = opts or {}
  local net = H.new()
  local m = net.machine({id=1})
  m.install({"so-store.lua", "so-ui.lua", "so-mod-display.lua"})
  local s = { clock = 0, values = opts.values or {}, machines = opts.machines or {}, lost = opts.lost or {}, m = m }
  m.env.SO = { now = function() return s.clock end,
    mods = { state = { view = function() return { values = s.values } end,
      get = function(key) if key == "machines" then return s.machines end end },
      lease = { status = function(id) return { lost = s.lost[id] } end } },
    store = m.env.dofile("so-store.lua"), pair = { key = function() return "key" end },
    proto = { ser = H.encode, build = function(_, _, body) return body end, encode = function(body) return body end },
    error = function() end }
  if opts.monitor then
    m.env.peripheral = { find = function(kind) if kind == "monitor" then return opts.monitor.target end end,
      getName = function() return "top" end }
  end
  if opts.term then m.env.term = opts.term.target end
  local d = m.env.dofile("so-mod-display.lua")
  s.d = d
  s.hello = function(id, w, h, label) d.handlers.hello({from=id, body={w=w or 39, h=h or 13, label=label}}) end
  s.open = function(role, w, h, id, label)
    id = id or 2
    s.hello(id, w, h, label)
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
  s.button = function(name, id)
    for _, b in ipairs(s.frame(id).buttons) do if b.id == name then return b end end
  end
  s.tap = function(name, id)
    local b = assert(s.button(name, id), "no button " .. name)
    d.handlers.input({from=id or 2, body={id=name, x=b.x, y=b.y}})
  end
  return s
end

local turtles = { [3] = { role = "worker", pose = { x = 10, y = 64, z = -4, facing = 0 }, fuel = 900, seen = 0 } }

return function(test, equal)
  test("UB-20: <id> far on sends scale 1 on the next frame, and off returns to 0.5", function()
    local s = boot()
    s.open("status", 39, 13, 7)
    s.at(1000)
    equal(s.frame(7).scale, 0.5)
    local ok, text = s.d.command("7 far on")
    assert(ok, tostring(text))
    equal(text, "display 7: far on")
    s.at(1100)
    equal(s.frame(7).scale, 1, "the next frame has scale 1")
    assert(s.d.command("7 far off"))
    s.at(1200)
    equal(s.frame(7).scale, 0.5)
    equal(select(1, s.d.command("7 far maybe")), false)
    equal(select(1, s.d.command("42 far on")), false, "unknown display")
  end)

  test("UB-20: the server monitor uses the far flag saved under the server's id", function()
    local mon = screen(39, 13)
    local s = boot({ monitor = mon })
    s.at(1000)
    equal(mon.scales[#mon.scales], 0.5)
    assert(s.d.command("1 far on"))
    s.at(2000)
    equal(mon.scales[#mon.scales], 1)
  end)

  test("P-U3-1: <id> identify shows the id large on that display only for 5 s and saves nothing", function()
    local s = boot()
    s.open("status", 39, 13, 6)
    s.open("status", 39, 13, 7)
    s.at(1000)
    local before = s.m.files["so-display"]
    local ok, text = s.d.command("6 identify")
    assert(ok, tostring(text))
    s.at(1500)
    local shown = s.text(6)
    assert(shown:find("IDENTIFY", 1, true), shown)
    assert(not shown:find("STATUS", 1, true), "the role page waits: " .. shown)
    equal(#s.frame(6).buttons, 0, "no controls while identifying")
    assert(not s.text(7):find("IDENTIFY", 1, true), "display 7 keeps its role")
    equal(s.m.files["so-display"], before, "identify saves nothing")
    s.at(6100)
    assert(s.text(6):find("STATUS", 1, true), "the role returns after 5 s: " .. s.text(6))
    equal(select(1, s.d.command("9 identify")), false, "an unknown display cannot identify")
  end)

  test("UB-24: status turtle rows hit turtle:<id> and open TURTLE #3", function()
    local s = boot({ machines = turtles })
    s.open("status", 57, 24)
    s.at(1000)
    assert(s.button("turtle:3"), "status at 57x24 returns turtle:3")
    s.tap("turtle:3")
    s.at(1100)
    assert(s.text():find("TURTLE #3", 1, true), s.text())
  end)

  test("UB-24: the #3 lost flag opens turtle 3, not the newest alert", function()
    local s = boot({ machines = turtles, lost = { [3] = true }, values = { ["mine.alert"] = { text = "fuel empty" } } })
    s.open("status", 57, 24)
    s.at(1000)
    local frame, flagY = s.frame(), nil
    for y, row in ipairs(frame.rows) do if row.text:find("#3 lost", 1, true) then flagY = y end end
    assert(flagY, "the lost flag is drawn")
    local hit
    for _, b in ipairs(frame.buttons) do if b.y == flagY then hit = b end end
    equal(hit and hit.id, "turtle:3")
    s.tap("turtle:3")
    s.at(1100)
    assert(s.text():find("TURTLE #3", 1, true), s.text())
  end)

  test("UB-25: the takeover #id chip opens the turtle; a tap elsewhere still dismisses", function()
    local s = boot({ machines = turtles })
    s.open("status", 57, 24)
    s.at(0)
    s.values["mine.alert"] = { text = "fuel empty", id = 3 }
    s.at(1000)
    local chip = assert(s.button("turtle:3"), "the chip carries turtle:3")
    local buttons = s.frame().buttons
    equal(buttons[#buttons].id, "turtle:3", "the chip is drawn after the dismiss hit")
    assert(s.text():sub(1, 400):find("#3", 1, true))
    s.tap("turtle:3")
    s.at(1100)
    assert(s.text():find("TURTLE #3", 1, true), s.text())

    local t = boot({ machines = turtles })
    t.open("status", 57, 24)
    t.at(0)
    t.values["mine.alert"] = { text = "fuel empty", id = 3 }
    t.at(1000)
    t.d.handlers.input({from=2, body={id="dismiss", x=2, y=20}})
    t.at(1100)
    assert(not t.button("dismiss"), "the takeover is dismissed")
    assert(not t.text():find("TURTLE #3", 1, true), t.text())
  end)

  test("P-U3-2: the role list shows each display's label from hello, cut to fit", function()
    local term = screen(51, 19)
    local s = boot({ term = term })
    s.open("status", 39, 13, 4, "kitchen")
    s.open("status", 39, 13, 5, "a very long computer label that cannot fit\1")
    s.m.env.SO.terminal = { mode = "role", log = {}, input = "" }
    s.d.drawTerminal(1000)
    local text = term.text()
    assert(text:find("status     kitchen", 1, true), text)
    for y = 1, 19 do equal(#(term.rows[y] or ""), 51) end
    assert(text:find("status     a very long computer l ", 1, true), text)
    assert(not text:find("computer la", 1, true), "the label is cut to the row")
  end)

  test("P-U3-11: the DISPLAYS tile names stale ids", function()
    local s = boot()
    s.open("status", 39, 13, 2)
    s.hello(7, 39, 13)
    for ms = 1000, 20000, 1000 do s.at(ms) end
    local tile = s.d.statusModel().tiles[7]
    equal(tile.label, "DISPLAYS")
    equal(tile.sub, "#7 stale")
    equal(tile.chips[2][1], "#7 stale")
  end)

  test("P-U3-12: a server monitor tap changes the picture without waiting for the tick", function()
    local mon = screen(39, 19)
    local s = boot({ monitor = mon, values = { ["a.alert"] = { text = "alpha" } } })
    s.at(1000)
    s.at(2000)
    local y
    for row, text in pairs(mon.rows) do if text:find("alpha", 1, true) then y = row end end
    assert(y, "the alert flag is drawn: " .. mon.text())
    local blits = mon.blits
    s.d.monitorTouch("top", 3, y)
    assert(mon.blits > blits, "the tap redraws at once")
    assert(mon.text():find("BACK", 1, true), mon.text())
  end)

  test("P-U3-13: ALERTS on status lists every alert newest first, with BACK", function()
    local s = boot({ values = { ["a.alert"] = { text = "alpha" } } })
    s.open("status", 39, 13)
    s.at(1000)
    s.values["b.alert"] = { text = "beta" }
    s.at(2000)
    s.d.handlers.input({from=2, body={id="dismiss", x=1, y=1}})
    s.values["c.alert"] = { text = "gamma" }
    s.at(40000)
    s.d.handlers.input({from=2, body={id="dismiss", x=1, y=1}})
    s.at(40100)
    s.tap("alerts")
    s.at(40200)
    local rows = s.frame().rows
    assert(rows[1].text:find("ALERTS", 1, true), s.text())
    equal({ rows[3].text:match("! (%a+)"), rows[4].text:match("! (%a+)"), rows[5].text:match("! (%a+)") },
      { "gamma", "beta", "alpha" })
    assert(s.button("alerts-back"), "BACK is drawn")
    s.tap("alerts-back")
    s.at(40300)
    assert(s.text():find("STATUS", 1, true), s.text())
  end)

  test("P-U3-13: the ALERTS list matches its twin at 57x24", function()
    local s = boot({ values = { ["a.alert"] = { text = "ore chest full", detail = "drop point #3" },
      ["b.alert"] = { text = "out of saplings" }, ["c.alert"] = { text = "#4 lease expired, lane released" } } })
    s.open("status", 57, 24)
    s.at(1000)
    s.tap("alerts")
    s.at(1100)
    match("tests/ui/fixtures/alertlist-M.txt", s.frame())
  end)

  test("P-U3-13: seven alerts at 15x10 page in the header and keep BACK whole", function()
    local values = {}
    for i = 1, 7 do values["a" .. i .. ".alert"] = { text = "alert " .. i } end
    local s = boot({ values = values })
    s.open("status", 15, 10)
    s.at(1000)
    s.tap("alerts")
    s.at(1100)
    match("tests/ui/fixtures/alertlist-XS.txt", s.frame())
    equal(s.frame().rows[10].text:sub(1, 8), "  BACK  ", "BACK and the gap after it are intact")
    local back, prev = s.button("alerts-back"), s.button("alert-prev")
    assert(back.x + back.w < prev.x, "the controls keep apart")
    s.tap("alert-next")
    s.at(1200)
    match("tests/ui/fixtures/alertlist-XS2.txt", s.frame())
    s.tap("alerts-back")
    s.at(1300)
    assert(s.text():find("STATUS", 1, true), s.text())
  end)
end
