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
  opts.cfg = opts.cfg or {displayAck=false,turtleInventory=false,workerPark=false}
  local net = H.new()
  local m = net.machine({id=1})
  m.install({"so-store.lua", "so-ui.lua", "so-mod-display.lua"})
  local s = { clock = 0, values = opts.values or {}, machines = opts.machines or {}, lost = opts.lost or {}, m = m }
  m.env.SO = { now = function() return s.clock end,
    mods = { state = { view = function() return { values = s.values } end,
      get = function(key) if key == "machines" then return s.machines end end },
      lease = { status = function(id) return { lost = s.lost[id] } end } },
    store = m.env.dofile("so-store.lua"), pair = { key = function() return "key" end },
    proto = opts.proto or { ser = H.encode, build = function(_, _, body) return body end, encode = function(body) return body end },
    error = function() end }
  if opts.cfg then m.files["so-server.cfg"] = H.encode(opts.cfg) end
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
    s.tap("dismiss")
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
    -- The alert stood through the restart, so it takes over once first.
    s.d.monitorTouch("top", 2, 2)
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
    s.tap("dismiss")
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
    s.tap("dismiss")
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

  test("P-U3-13: the schematic generator reproduces the ALERTS list fixtures", function()
    local started, pipe = pcall(io.popen, "pwd")
    local root = started and pipe and pipe:read("*l")
    if started and pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= "/" or not os.execute("python3 -V > /dev/null 2>&1") then
      return dofile("tests/skips.lua").record("display-server generator", "needs host processes, a POSIX shell and python3")
    end
    local function read(path)
      local f = assert(io.open(path, "rb"))
      local data = f:read("*a")
      f:close()
      return data
    end
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "'"))
    assert(os.execute("python3 -I '" .. root .. "/docs/ui/schematic/screens.py' --fixtures '" .. dir .. "' > /dev/null"))
    local count = 0
    for name in read(root .. "/docs/ui/schematic/system.py"):gmatch('\n    %("(alertlist[%w%-]*)", ') do
      equal(read(dir .. "/" .. name .. ".txt"), read("tests/ui/fixtures/" .. name .. ".txt"))
      count = count + 1
    end
    equal(count, 3)
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)

  -- B7-U (D7): frame acknowledgements behind so-server.cfg displayAck.
  local function capable(s, id, w, h)
    s.d.handlers.hello({ from = id, body = { w = w or 39, h = h or 13, capabilities = { frameAck = 1 } } })
    assert(s.d.assign(id, "status"))
    s.d.handlers["view.sub"]({ from = id })
  end
  local function ack(s, id, token, extra)
    local body = { v = 1, token = token }
    for k, v in pairs(extra or {}) do body[k] = v end
    s.d.handlers["view.ack"]({ from = id, body = body })
  end
  -- The R list rows by id, as the terminal's role mode draws them.
  local function roles(s)
    s.m.env.SO.terminal = { mode = "role", log = {} }
    s.m.env.term = screen(51, 19).target
    s.m.env.term.isColor = function() return true end
    s.d.drawTerminal(s.clock)
    local rows = {}
    for _, row in ipairs(s.m.env.SO.terminal.displays) do rows[row.id] = row end
    return rows
  end
  local function private(s) return dofile("tests/ui/scene.lua").private(s.d.handlers.hello, "D") end

  test("B7-U: displayAck off: a frameAck display gets no challenge and freshness stays send-based", function()
    local s = boot()
    capable(s, 2)
    s.at(1000)
    equal(s.frame(2).ack, nil, "no challenge with the flag off")
    ack(s, 2, "x")
    for ms = 2000, 30000, 1000 do s.at(ms) end
    equal(s.frame(2).ack, nil)
    equal(s.d.statusModel().tiles[7].sub, "all fresh", "frames still sent keep it fresh")
    equal(roles(s)[2].state, nil, "no ACK column")
    equal(s.d.statusModel().terminal.stale, nil)
  end)

  test("B7-U: displayAck on: an old client gets no challenge and reads unverified", function()
    local s = boot({ cfg = { displayAck = true } })
    s.open("status", 39, 13, 2)
    s.at(1000)
    equal(s.frame(2).ack, nil, "no capability, no challenge")
    for ms = 2000, 30000, 1000 do s.at(ms) end
    equal(s.d.statusModel().tiles[7].sub, "1 unverified")
    equal(roles(s)[2].state, "unverified")
    equal(roles(s)[2].stale, nil)
  end)

  test("B7-U: waiting until the first ACK, fresh after it, stale 10 s after the last ACK", function()
    local s = boot({ cfg = { displayAck = true } })
    capable(s, 2)
    local first = s.frame(2).ack
    equal(first.v, 1)
    assert(type(first.token) == "string" and #first.token >= 1 and #first.token <= 64, tostring(first.token))
    s.at(1000)
    equal(roles(s)[2].state, "waiting")
    ack(s, 2, first.token)
    s.at(2500)
    equal(roles(s)[2].state, "1s")
    equal(roles(s)[2].stale, false)
    -- Heartbeats repeat the unchanged picture with a new token each time; none is acknowledged.
    local seen = { [first.token] = true }
    for ms = 2000, 10000, 1000 do
      s.at(ms)
      local token = s.frame(2).ack.token
      if not seen[token] then seen[token] = ms end
    end
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    assert(count >= 3, "each heartbeat carries a fresh token")
    s.at(10999)
    equal(s.d.statusModel().tiles[7].sub, "all fresh")
    -- Hello and input never refresh heard.
    capable(s, 2)
    s.d.handlers.input({ from = 2, body = { id = "x", x = 1, y = 1 } })
    s.at(11000)
    equal(s.d.statusModel().tiles[7].sub, "#2 stale")
    equal(s.d.statusModel().terminal.stale, 1)
    equal(roles(s)[2].state, "stale 10s")
    equal(roles(s)[2].stale, true)
    equal(s.d.statusModel().displays[1].ago, 10000)
    ack(s, 2, s.frame(2).ack.token)
    s.at(11100)
    equal(s.d.statusModel().tiles[7].sub, "all fresh", "a later ACK makes it fresh again")
  end)

  test("B7-U: a display that never acknowledges goes stale 10 s after its hello", function()
    local s = boot({ cfg = { displayAck = true } })
    s.clock = 500
    capable(s, 2)
    s.at(10499)
    equal(roles(s)[2].state, "waiting")
    s.at(10500)
    equal(roles(s)[2].state, "stale 10s")
    equal(s.d.statusModel().tiles[7].sub, "#2 stale")
  end)

  test("B7-U: forged, foreign, malformed, expired and repeated ACKs are ignored", function()
    local s = boot({ cfg = { displayAck = true } })
    capable(s, 2)
    capable(s, 3)
    local token = s.frame(2).ack.token
    s.clock = 1000
    ack(s, 3, token)
    ack(s, 2, "deadbeef")
    ack(s, 2, token, { v = 2 })
    ack(s, 2, token, { extra = 1 })
    ack(s, 2, "")
    ack(s, 2, string.rep("a", 65))
    ack(s, 2, nil)
    s.d.handlers["view.ack"]({ from = 2, body = { token = token } })
    s.d.handlers["view.ack"]({ from = 4, body = { v = 1, token = token } })
    s.at(2000)
    equal(roles(s)[2].state, "waiting", "no bad ACK sets heard")
    equal(roles(s)[3].state, "waiting", "a foreign token does not count for its sender")
    ack(s, 2, token)
    s.at(2000)
    equal(roles(s)[2].state, "0s")
    s.clock = 9000
    ack(s, 2, token)
    s.at(12000)
    equal(roles(s)[2].state, "stale 10s", "a repeated token is spent")
    -- A token is good for less than 10 s.
    s.clock = 20000
    s.d.handlers["view.sub"]({ from = 2 })
    local late = s.frame(2).ack.token
    s.clock = 30000
    ack(s, 2, late)
    s.at(30000)
    equal(roles(s)[2].state, "stale 28s", "an expired token is ignored")
    s.d.handlers["view.sub"]({ from = 2 })
    local good = s.frame(2).ack.token
    s.clock = 39999
    ack(s, 2, good)
    s.at(39999)
    equal(roles(s)[2].state, "0s")
  end)

  test("B7-U: at most four tokens wait, and a failed send keeps none", function()
    local s = boot({ cfg = { displayAck = true } })
    capable(s, 2)
    local D = private(s)
    local tokens = { s.frame(2).ack.token }
    for i = 2, 5 do
      s.d.handlers["view.sub"]({ from = 2 })
      tokens[i] = s.frame(2).ack.token
      assert(tokens[i] ~= tokens[i - 1], "each frame has its own token")
    end
    equal(#D.sessions[2].ack.pending, 4)
    ack(s, 2, tokens[1])
    equal(D.sessions[2].ack.heard, nil, "the oldest gave way to the fifth")
    local send = s.m.env.rednet.send
    s.m.env.rednet.send = function() return false end
    s.d.handlers["view.sub"]({ from = 2 })
    s.m.env.rednet.send = send
    equal(#D.sessions[2].ack.pending, 4, "an unsent token is not kept")
    equal(D.sessions[2].ack.pending[4].token, tokens[5])
    s.clock = 100
    ack(s, 2, tokens[2])
    equal(D.sessions[2].ack.heard, 100)
    equal(#D.sessions[2].ack.pending, 3)
  end)

  test("B7-U: a restart or forget drops the ACK state", function()
    local s = boot({ cfg = { displayAck = true } })
    capable(s, 2)
    ack(s, 2, s.frame(2).ack.token)
    s.d.forget(2)
    s.at(1000)
    equal(roles(s)[2].state, nil, "only the saved role is left")
    local again = boot({ cfg = { displayAck = true } })
    again.open("status", 39, 13, 2)
    equal(roles(again)[2].state, "unverified")
  end)

  -- A proto whose envelope fails over a byte limit, with the frame's rid and body kept.
  local function sized(limit)
    return { ser = H.encode, build = function(_, t, body, rid)
      return { v = 1, t = t, rid = rid or string.rep("1", 20), from = 1, at = 1700000000000, mac = string.rep("0", 64), body = body }
    end, encode = function(msg) if #H.encode(msg) <= limit then return msg end end }
  end
  local function big(s)
    local rows = {}
    for n = 1, 13 do rows[n] = { text = string.rep(string.char(64 + n), 39) } end
    s.d.screen("generic", function() return { rows = rows, buttons = {} } end, function() end)
  end

  test("B7-U: the challenge has room kept in the envelope, so it sheds nothing, on view.sub and view.get", function()
    local limit = 1100
    local plain = boot({ proto = sized(limit) })
    big(plain)
    plain.open("generic", 39, 13, 2)
    local s = boot({ cfg = { displayAck = true }, proto = sized(limit) })
    big(s)
    s.open("generic", 39, 13, 5)
    s.d.handlers.hello({ from = 2, body = { w = 39, h = 13, capabilities = { frameAck = 1 } } })
    assert(s.d.assign(2, "generic"))
    s.d.handlers["view.sub"]({ from = 2 })
    local old, new = s.frame(5).body, s.frame(2).body
    equal(old.ack, nil)
    assert(new.ack and new.ack.token, "the frame carries its challenge")
    equal(#new.rows, #old.rows, "a challenge sheds no row beyond an old client's frame")
    assert(#new.rows < 13, "the picture really was over the limit")
    assert(#plain.frame(2).body.rows >= #new.rows, "displayAck off fits as before")
    local room = { v = 1, t = "view.frame", rid = string.rep("0", 64), from = 1, at = 1700000000000,
      mac = string.rep("0", 64), body = new }
    new.ack = { v = 1, token = string.rep("0", 64) }
    assert(#H.encode(room) <= limit, "the largest challenge fits too")
    -- view.get: the challenge goes in before reply signs under the request's rid.
    local replied
    s.d.handlers["view.get"]({ from = 2, rid = "2-1-1" }, function(t, body)
      replied = sized(limit).encode(sized(limit).build("key", t, body, "2-1-1"))
    end)
    assert(replied, "the view.get frame fits")
    assert(replied.body.ack.token ~= "2-1-1", "the token is not the request rid")
    equal(#replied.body.rows, #old.rows)
    local D = private(s)
    equal(D.sessions[2].ack.pending[#D.sessions[2].ack.pending].token, replied.body.ack.token)
    s.clock = 10
    ack(s, 2, replied.body.ack.token)
    equal(D.sessions[2].ack.heard, 10, "the view.get token is accepted once")
  end)

  test("B7-U: the server monitor's last good draw is its freshness", function()
    local mon = screen(39, 13)
    local s = boot({ cfg = { displayAck = true }, monitor = mon })
    s.at(1000)
    s.at(3500)
    equal(roles(s)[1].state, "0s")
  end)

  test("B7-U: the R list and the stale leader match their twins", function()
    local frame = boot().d.terminal({ tiles = {} }, { id = 1, uptime = "up 3h12", mode = "role", input = "", notice = "",
      displays = { { id = 1, size = "57x24", role = "status", label = "server", state = "0s", stale = false },
        { id = 2, size = "26x20", role = "pocket", state = "waiting", stale = false },
        { id = 5, size = "57x24", role = "mining", label = "mine entrance west", state = "4s", stale = false },
        { id = 6, size = "57x24", role = "unassigned", state = "unverified" },
        { id = 7, size = "15x10", role = "status", label = "hall", state = "stale 12s", stale = true },
        { id = 9, size = "-", role = "drops" } } }, 51, 19)
    match("tests/ui/fixtures/rolesack-T.txt", frame)
    local S = dofile("tests/ui/scene.lua")
    local sc = S.new()
    local log = sc.env.SO.terminal.log
    for i = #log, 1, -1 do log[i] = nil end
    for i, line in ipairs(sc.sys.log) do log[i] = line end
    local term = R.capture(51, 19)
    sc.env.term = term
    sc.D.model = sc.D.gather()
    sc.D.model.terminal.stale = 1
    sc.d.drawTerminal(sc.now)
    equal(R.diff(R.load("tests/ui/fixtures/serverstale-T.txt"), term), {})
  end)

  test("B7-U: a view.get reply that may not have gone out never pushes out a sent token", function()
    local s = boot({ cfg = { displayAck = true } })
    capable(s, 2)
    local D = private(s)
    local sent = { s.frame(2).ack.token }
    for i = 2, 4 do s.d.handlers["view.sub"]({ from = 2 }); sent[i] = s.frame(2).ack.token end
    -- The production reply returns nothing whether or not the frame went out.
    local lost
    s.d.handlers["view.get"]({ from = 2, rid = "2-9-1" }, function(_, body) lost = body.ack.token end)
    assert(lost, "view.get still carries a challenge")
    equal(#D.sessions[2].ack.pending, 4)
    for i = 1, 4 do equal(D.sessions[2].ack.pending[i].token, sent[i]) end
    ack(s, 2, sent[1])
    equal(D.sessions[2].ack.heard, 0, "the oldest sent token still counts")
    -- Below the limit a view.get token waits provisionally; the next sent frame pushes it out first.
    s.d.handlers["view.get"]({ from = 2, rid = "2-9-2" }, function(_, body) lost = body.ack.token end)
    s.d.handlers["view.sub"]({ from = 2 })
    local tokens = {}
    for _, p in ipairs(D.sessions[2].ack.pending) do tokens[p.token] = true end
    assert(not tokens[lost], "the provisional token went first")
    for i = 2, 4 do assert(tokens[sent[i]], "sent token " .. i .. " kept") end
  end)

  test("B7-U: a near-limit view.get with an escaped 64-byte rid still fits once signed", function()
    local rid = string.rep('"', 32) .. string.rep("\\", 32)
    for limit = 900, 1400, 7 do
      local s = boot({ cfg = { displayAck = true }, proto = sized(limit) })
      big(s)
      s.d.handlers.hello({ from = 2, body = { w = 39, h = 13, capabilities = { frameAck = 1 } } })
      assert(s.d.assign(2, "generic"))
      local replied, called
      s.d.handlers["view.get"]({ from = 2, rid = rid }, function(t, body)
        called = true
        replied = sized(limit).encode(sized(limit).build("key", t, body, rid))
      end)
      assert(not called or replied, "limit " .. limit .. ": the reply fit the probe but not the envelope")
      assert(called, "limit " .. limit .. ": no reply")
    end
  end)

  test("B7-U: route A rows carry stale, waiting and unverified, and fresh rows their ACK age", function()
    local s = boot({ cfg = { displayAck = true } })
    capable(s, 2)
    capable(s, 3)
    s.open("status", 39, 13, 4)
    s.clock = 1000
    ack(s, 3, s.frame(3).ack.token)
    s.at(3000)
    local rows = {}
    for _, row in ipairs(s.d.statusModel().displays) do rows[row.id] = row end
    equal({ rows[2].state, rows[3].state, rows[4].state }, { "waiting", nil, "unverified" })
    equal(rows[3].ago, 0)
    equal({ s.d.statusModel().staleDisplays, s.d.statusModel().unverifiedDisplays }, { 0, 1 })
    s.at(11000)
    rows = {}
    for _, row in ipairs(s.d.statusModel().displays) do rows[row.id] = row end
    equal({ rows[2].state, rows[3].state }, { "stale", "stale" })
    equal(rows[3].ago, 10000)
    equal(s.d.statusModel().staleDisplays, 2)
    local off = boot()
    off.open("status", 39, 13, 4)
    off.at(1000)
    equal(off.d.statusModel().displays[1].state, nil, "flag off: no state")
    equal(off.d.statusModel().staleDisplays, nil)
  end)

  test("B7-U: the status leaders and the wall list match their twins", function()
    local U = dofile("so-ui.lua")
    local sc = dofile("tests/ui/scene.lua").new()
    local model = sc.D.gather()
    local copy = {}
    for k, v in pairs(model) do copy[k] = v end
    copy.staleDisplays, copy.unverifiedDisplays, copy.thumb = 1, 1, nil
    local states = { { "stale", 70000 }, { "waiting", 0 }, { "unverified", 0 } }
    copy.displays = {}
    for i, d in ipairs(model.displays) do
      local row = {}
      for k, v in pairs(d) do row[k] = v end
      if states[i] then row.state, row.ago = states[i][1], states[i][2] end
      copy.displays[i] = row
    end
    match("tests/ui/fixtures/statusack-M.txt", U.status(copy, 57, 24))
    match("tests/ui/fixtures/statusack-W.txt", U.status(copy, 100, 38))
  end)
end
