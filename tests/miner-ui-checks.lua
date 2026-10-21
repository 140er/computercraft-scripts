return function(test, equal, read, mocks)
  local source = read("miner.lua")

  local function loadUi(m)
    local code = assert(source:match("^(.*)\nopenModem%(%)"))
    m.env.box = {}
    return assert(load(code .. [[
function box.status(s) status = s end
function box.recall() return recall end
function box.pos(x, y, z) pos.x, pos.y, pos.z = x, y, z end
function box.phase(p) st.phase = p end
function box.views(on) cfg.viewsControl = on and true or false end
function box.estop(on) C.estop = on and true or nil end
function box.estopped() return C.estop end
function box.error(msg) st.lastError = msg and { msg = msg } or nil end
function box.fuelOk() return fuelOk(8) end
function box.layer(y, branch, step, branchLen)
  st.job = { y = y, branchLen = branchLen }
  st.levels[y] = { branch = branch, step = step }
end
function box.job(job) st.job = job end
function box.bores(t) st.bores = t end
function box.boreAt(v) st.boreAt = v end
function box.dug(n) st.dug = n end
function box.mining(state)
  if state == nil then C.mining = nil return end
  C.mining = { state = function() return state end }
end
function box.setStatus(s) setStatus(s) end
function box.screen(flag) cfg.screen = flag end
return ui
]], "=miner.lua", "t", m.env))()
  end

  local function boot(fuel)
    local m = mocks.miner({ home = { x = 0, y = 64, z = 0 }, facing = 0, spine = 1 })
    m.fuel = fuel or 180
    m.env.keys = { q = 16, p = 25, h = 35 }
    return m, loadUi(m), m.env.box
  end

  local function makeTerm(w, h, color)
    local grid, fg, bg = {}, {}, {}
    local curx, cury, ink, paper = 1, 1, 1, 32768
    local term = { bad = {}, setters = { text = 0, back = 0 }, fg = fg, bg = bg }
    local function blank()
      for y = 1, h do
        grid[y], fg[y], bg[y] = {}, {}, {}
        for x = 1, w do
          grid[y][x], fg[y][x], bg[y][x] = " ", ink, paper
        end
      end
    end
    blank()
    function term.getSize() return w, h end
    function term.isColor() return color and true or false end
    function term.isColour() return color and true or false end
    function term.setTextColor(c)
      term.setters.text = term.setters.text + 1
      if not color then error("setTextColor", 0) end
      ink = c
    end
    function term.setBackgroundColor(c)
      term.setters.back = term.setters.back + 1
      if not color then error("setBackgroundColor", 0) end
      paper = c
    end
    function term.setCursorPos(x, y)
      if type(x) ~= "number" or type(y) ~= "number" or x < 1 or y < 1 or x > w or y > h then
        term.bad[#term.bad + 1] = { op = "cursor", x = x, y = y }
      end
      curx, cury = x, y
    end
    function term.write(text)
      text = tostring(text)
      if cury < 1 or cury > h or curx < 1 or curx > w or curx + #text - 1 > w then
        term.bad[#term.bad + 1] = { op = "write", x = curx, y = cury, n = #text }
      end
      if cury >= 1 and cury <= h then
        for i = 1, #text do
          local x = curx + i - 1
          if x >= 1 and x <= w then
            grid[cury][x], fg[cury][x], bg[cury][x] = text:sub(i, i), ink, paper
          end
        end
      end
      curx = curx + #text
    end
    function term.clear() blank() end
    function term.row(y) return table.concat(grid[y]) end
    function term.rows()
      local out = {}
      for y = 1, h do out[y] = table.concat(grid[y]) end
      return out
    end
    return term
  end

  local function dump(term)
    local lines = { mocks.encode(term.bad) }
    for y, row in ipairs(term.rows()) do lines[#lines + 1] = string.format("%02d|%s|", y, row) end
    return table.concat(lines, "\n")
  end

  local function find(term, text)
    for y, row in ipairs(term.rows()) do
      local x = row:find(text, 1, true)
      if x then return x, y, row end
    end
  end

  local function painted(m, text)
    for _, line in ipairs(m.output) do
      if line:find(text, 1, true) then return true end
    end
  end

  local function wake(co, ...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then error(err, 0) end
    return coroutine.status(co)
  end

  local function layer(m, ui, box)
    box.status("Following vein")
    box.layer(12, 4, 9, 64)
    box.pos(0, 64 - 400, 0)
    box.error("bedrock blocks the shaft")
    ui.said = "bucket of gravel"
    assert(box.fuelOk() == false, "fuel 180 far from home still counted as enough")
    local frame = ui.snap()
    equal(frame.task, "Following vein")
    equal(frame.state, "RUNNING")
    equal(frame.fuel.text, "180")
    equal(frame.fuel.tone, "low")
    equal(frame.problem, "bedrock blocks the shaft")
    equal(frame.rows, {
      { leftLabel = "Layer", leftValue = "Y 12", rightLabel = "Branch", rightValue = "4" },
      { leftLabel = "Step", leftValue = "9/64", rightLabel = "Dug", rightValue = "0" },
    })
    return frame
  end

  test("miner screen shows the vein, the layer, and the problem", function()
    local m, ui, box = boot(180)
    local frame = layer(m, ui, box)
    local term = makeTerm(39, 13, true)
    ui.paint(term, frame)
    assert(#term.bad == 0, dump(term))
    assert(term.row(11):find("bedrock blocks the shaft", 1, true), dump(term))
    assert(not term.row(11):find("bucket of gravel", 1, true), dump(term))
    assert(term.row(13):find("[Q] quit", 1, true), dump(term))
    local mx, my = find(term, "MINER")
    assert(mx, dump(term))
    assert(term.bg[my][mx] == m.env.colors.green, "title bar is not green")
    local sx, sy = find(term, "RUNNING")
    assert(sx, dump(term))
    assert(term.fg[sy][sx] == m.env.colors.lime, "running is not lime")
    assert(term.bg[sy][sx] == m.env.colors.green, "state left the title bar")
    local tx, ty = find(term, "Following vein")
    assert(tx, dump(term))
    assert(term.fg[ty][tx] == m.env.colors.yellow, "task is not yellow")
    local fuel = select(3, find(term, "Fuel"))
    assert(fuel and fuel:sub(31, 39) == "180      ", dump(term))
    local fx, fy = find(term, "Fuel")
    local low = false
    for x = 1, 39 do if term.bg[fy][x] == m.env.colors.red then low = true end end
    assert(low, "low fuel bar has no red")
    assert(find(term, "Free 16/16"), dump(term))
    local nx, ny = find(term, "bucket of gravel")
    assert(nx and ny ~= 11, dump(term))
    local bang = term.row(11):find("!", 1, true)
    assert(bang and term.fg[11][bang] == m.env.colors.red, "problem is not red")
    local qx = term.row(13):find("[Q]", 1, true)
    assert(qx and term.bg[13][qx] == m.env.colors.gray, "keys are not on gray")
    assert(term.fg[13][qx] == m.env.colors.white, "keys are not white")
    assert(not find(term, "MINING"), dump(term))
  end)

  test("miner screen shows unlimited fuel across the row", function()
    local m, ui, box = boot("unlimited")
    local frame = ui.snap()
    equal(frame.fuel.text, "unlimited")
    equal(frame.fuel.ratio, 1)
    equal(frame.fuel.tone, "ok")
    local term = makeTerm(39, 13, false)
    ui.paint(term, frame)
    assert(#term.bad == 0 and term.setters.text == 0 and term.setters.back == 0, dump(term))
    local row = select(3, find(term, "unlimited"))
    equal(row, "Fuel " .. string.rep("#", 24) .. " unlimited")
    local narrow = makeTerm(15, 13, false)
    ui.paint(narrow, frame)
    equal(select(3, find(narrow, "unlimited")), "Fuel  unlimited")
    local tiny = makeTerm(10, 13, false)
    ui.paint(tiny, frame)
    local clipped = select(3, find(tiny, "Fuel"))
    equal(clipped, "Fuel unlim")
    assert(not clipped:find("#", 1, true), clipped)
    m.fuel = 10000
    equal(ui.snap().fuel.text, "10.0k")
    m.fuel = 9999
    equal(ui.snap().fuel.text, "9999")
    m.fuel = 100
    assert(box.fuelOk() == true)
    local home = ui.snap()
    equal(home.fuel.text, "100")
    equal(home.fuel.tone, "short")
  end)

  test("miner screen paints a basic term without color setters", function()
    local m, ui, box = boot(180)
    local frame = layer(m, ui, box)
    local term = makeTerm(39, 13, false)
    ui.paint(term, frame)
    assert(find(term, "Following vein"), dump(term))
    assert(term.setters.text == 0 and term.setters.back == 0, "basic term was asked for a color")
    assert(#term.bad == 0, dump(term))
    local fuel = select(3, find(term, "Fuel"))
    assert(fuel:find("#", 1, true), dump(term))
    assert(fuel:sub(30, 33) == " 180", dump(term))
  end)

  test("miner screen paints a one by one term inside the cell", function()
    local _, ui, box = boot(180)
    box.phase("mining")
    ui.home = true
    local frame = ui.snap()
    equal(frame.state, "COMING HOME")
    local term = makeTerm(1, 1, true)
    ui.paint(term, frame)
    assert(#term.bad == 0, dump(term))
  end)

  test("miner screen keys pause, come home, and quit", function()
    local m, ui, box = boot(180)
    box.phase("mining")
    local narrow = makeTerm(26, 13, true)
    ui.paint(narrow, ui.snap())
    local keys = narrow.row(13)
    assert(keys:find("[Q]", 1, true) and not keys:find("come home", 1, true), dump(narrow))
    local tall = makeTerm(39, 20, true)
    ui.paint(tall, ui.snap())
    assert(tall.row(20):find("[Q]", 1, true), dump(tall))
    for y = 1, 19 do assert(not tall.row(y):find("[Q]", 1, true), dump(tall)) end
    equal(ui.key(m.env.keys.q), "redraw")
    local wide = makeTerm(39, 13, true)
    ui.paint(wide, ui.snap())
    assert(wide.row(13):find("Press Q again to quit", 1, true), dump(wide))
    equal(ui.key(m.env.keys.q), "quit")
    equal(ui.key(m.env.keys.h), "redraw")
    assert(ui.home == true)
    equal(ui.snap().state, "COMING HOME")
    assert(box.recall() == true)
    ui.home = false
    ui.sync()
    assert(box.recall() == false)
    equal(ui.key(m.env.keys.p), "redraw")
    assert(ui.pause == true and box.recall() == true)
    assert(not box.estopped(), "pause set the estop")
    equal(ui.key(m.env.keys.h), "redraw")
    assert(ui.home == false, "come home while paused")
    ui.hub = false
    ui.sync()
    assert(ui.pause == true and ui.home == false and box.recall() == true)
    ui.paint(wide, ui.snap())
    assert(wide.row(13):find("[P] go on", 1, true), dump(wide))
    equal(ui.key(9), "redraw")
  end)

  test("miner screen prefers the zone strip over a stale layer", function()
    local _, ui, box = boot(7000)
    box.layer(12, 4, 9, 64)
    box.status("Following vein")
    box.mining({
      task = { min = { z = 0 }, max = { z = 7 } },
      progress = 3,
      stack = { {}, {} },
      phase = "work",
      service = "drop",
    })
    local frame = ui.snap()
    equal(frame.state, "RUNNING")
    equal(frame.rows, {
      { leftLabel = "Strip", leftValue = "3/8", rightLabel = "Vein", rightValue = "2" },
      { leftLabel = "Phase", leftValue = "work", rightLabel = "Service", rightValue = "drop" },
    })
    local term = makeTerm(39, 13, true)
    ui.paint(term, frame)
    assert(find(term, "3/8"), dump(term))
    assert(not find(term, "Y 12"), dump(term))
  end)

  test("miner screen names lost, paused, home, and stopped", function()
    local _, ui, box = boot(7000)
    box.phase("mining")
    ui.pause = true
    ui.sync()
    equal(ui.snap().state, "PAUSING")
    box.mining({ phase = "home" })
    assert(ui.atHome() == true)
    equal(ui.snap().state, "PAUSED")
    box.mining({ phase = "work" })
    assert(ui.atHome() == false)
    equal(ui.snap().state, "PAUSING")
    ui.pause = false
    ui.home = true
    ui.sync()
    equal(ui.snap().state, "COMING HOME")
    box.mining({ phase = "done" })
    assert(ui.atHome() == true)
    equal(ui.snap().state, "RUNNING")
    box.mining(nil)
    box.views(true)
    box.phase("home")
    box.pos(3, 64, 0)
    ui.home = true
    ui.pause = false
    ui.hub = false
    ui.sync()
    assert(ui.atHome() == false)
    equal(ui.snap().state, "COMING HOME")
    box.pos(0, 64, 0)
    assert(ui.atHome() == true)
    equal(ui.snap().state, "RUNNING")
    box.views(false)
    box.phase("home")
    box.pos(3, 64, 0)
    ui.home = true
    ui.sync()
    assert(ui.atHome() == true)
    equal(ui.snap().state, "RUNNING")
    box.phase("lost")
    ui.pause = true
    ui.sync()
    equal(ui.snap().state, "LOST")
    box.phase("mining")
    ui.pause = false
    ui.home = false
    ui.hub = false
    ui.sync()
    box.estop(true)
    equal(ui.snap().state, "STOPPED")
    ui.hub = true
    ui.sync()
    equal(ui.snap().state, "RECALLED")
  end)

  test("miner screen shows a tunnel at block zero", function()
    local _, ui, box = boot(7000)
    box.mining(nil)
    box.job({ bore = { x = 0, z = -3 } })
    box.bores({ ["0,-3"] = 2 })
    box.dug(7)
    equal(ui.snap().rows[1].rightValue, "-")
    box.boreAt(0)
    local frame = ui.snap()
    equal(frame.rows[1].leftValue, "2/3")
    equal(frame.rows[1].rightValue, "0")
    equal(frame.rows[2].leftValue, "7")
  end)

  test("miner screen keeps running after a bad frame", function()
    local m, ui, box = boot(180)
    box.setStatus("Digging")
    assert(painted(m, "Digging"), "status was quiet before the screen owned print")
    m.env.term = makeTerm(39, 13, false)
    ui.snap = function() error("bad frame", 0) end
    local co = coroutine.create(ui.screen)
    assert(wake(co) == "suspended")
    equal(ui.said, "bad frame")
    local n = #m.output
    box.setStatus("Quiet")
    assert(#m.output == n, "the screen still printed status")
    assert(wake(co, "timer", m.timer) == "suspended")
    equal(ui.said, "bad frame")
    assert(m.env.term.setters.text == 0 and m.env.term.setters.back == 0)
    assert(wake(co, "mouse_click", 1, 1) == "suspended")
  end)

  test("miner screen quits on a basic term", function()
    local m, ui = boot(180)
    m.env.term = makeTerm(39, 13, false)
    local co = coroutine.create(ui.screen)
    assert(wake(co) == "suspended")
    assert(ui.said == nil)
    assert(m.env.term.setters.text == 0 and m.env.term.setters.back == 0)
    assert(find(m.env.term, "MINER"), dump(m.env.term))
    ui.quitAsk = true
    assert(wake(co, "key", m.env.keys.q) == "dead")
    assert(painted(m, "Miner stopped. Type miner to start it again."))
    assert(m.env.term.setters.text == 0 and m.env.term.setters.back == 0)
  end)

  test("miner screen clears come home once it is home", function()
    local m, ui, box = boot(180)
    box.phase("home")
    ui.home = true
    ui.sync()
    assert(box.recall() == true)
    m.env.term = makeTerm(39, 13, true)
    local co = coroutine.create(ui.screen)
    assert(wake(co) == "suspended")
    assert(ui.home == true, "the first paint cleared come home")
    assert(wake(co, "timer", m.timer) == "suspended")
    assert(ui.home == false and box.recall() == false)
    box.phase("mining")
    ui.home = true
    ui.sync()
    assert(wake(co, "timer", 0) == "suspended")
    assert(ui.home == true and box.recall() == true, "a stray timer cleared come home")
    ui.said = "kept line"
    assert(wake(co, "timer", m.timer) == "suspended")
    equal(ui.said, "kept line")
    assert(ui.home == true and box.recall() == true)
    assert(wake(co, "mouse_click", 1, 1) == "suspended")
    assert(ui.home == true)
  end)

  test("miner screen is on unless screen is false", function()
    local m, ui, box = boot(180)
    local main = function() end
    assert(ui.withScreen(main) ~= main)
    local saw
    m.env.parallel.waitForAny = function(screen, work) saw = { screen, work } end
    ui.withScreen(main)()
    assert(saw[1] == ui.screen and saw[2] == main, "the screen does not start before the worker")
    box.screen(false)
    assert(ui.withScreen(main) == main)
    box.screen(nil)
    assert(ui.withScreen(main) ~= main)
  end)
end
