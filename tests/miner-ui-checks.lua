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
  st.job = st.job or {}
  st.job.y, st.job.branchLen = y, branchLen
  st.levels[y] = { branch = branch, step = step }
end
function box.job(job) st.job = job end
function box.found(n) st.found = n end
function box.reason(r) st.homeReason = r end
function box.haul(t) ui.haul = t end
function box.need(n) ui.tripNeed = n end
function box.bores(t) st.bores = t end
function box.boreAt(v) st.boreAt = v end
function box.dug(n) st.dug = n end
function box.mining(state)
  if state == nil then C.mining = nil return end
  C.mining = { state = function() return state end }
end
function box.navStopped(on)
  C.nav = on and { stopped = function() return true end } or nil
end
function box.setStatus(s) setStatus(s) end
function box.screen(flag) cfg.screen = flag end
return ui
]], "=miner.lua", "t", m.env))()
  end

  local function boot(fuel)
    local m = mocks.miner({ home = { x = 0, y = 64, z = 0 }, facing = 0, spine = 1 })
    m.fuel = fuel or 6840
    m.env.keys = { q = 16, p = 25, h = 35, r = 19 }
    m.env.os.getComputerLabel = function() return "Miner 3" end
    return m, loadUi(m), m.env.box
  end

  local function makeTerm(w, h, color)
    local grid, fg, bg = {}, {}, {}
    local curx, cury, ink, paper = 1, 1, 1, 32768
    local term = { bad = {}, setters = { text = 0, back = 0 }, fg = fg, bg = bg }
    local grey = { [1] = true, [128] = true, [256] = true, [32768] = true }
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
      if not color and not grey[c] then error("setTextColor " .. tostring(c), 0) end
      ink = c
    end
    function term.setBackgroundColor(c)
      term.setters.back = term.setters.back + 1
      if not color and not grey[c] then error("setBackgroundColor " .. tostring(c), 0) end
      paper = c
    end
    function term.setCursorPos(x, y)
      if type(x) ~= "number" or type(y) ~= "number" or x < 1 or y < 1 or x > w or y > h then
        term.bad[#term.bad + 1] = { op = "cursor", x = x, y = y }
      end
      curx, cury = x, y
    end
    function term.clearLine()
      if cury < 1 or cury > h then return end
      for x = 1, w do
        grid[cury][x], fg[cury][x], bg[cury][x] = " ", ink, paper
      end
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

  local function wake(co, ...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then error(err, 0) end
    return coroutine.status(co)
  end

  local function fill(m, n, name)
    for s = 1, 16 do m.inventory[s] = nil end
    for s = 1, n do m.inventory[s] = { name = name or "minecraft:cobblestone", count = 1 } end
  end

  local gem, band, half = string.char(4), string.char(140), string.char(132)

  test("miner screen formats fuel and bar halves", function()
    local m, ui, box = boot(6840)
    equal(ui.fuelText(6840), "6840")
    equal(ui.fuelText(9999), "9999")
    equal(ui.fuelText(10000), "10.0k")
    equal(ui.fuelText(12300), "12.3k")
    equal(ui.fuelText("unlimited"), nil)
    equal(ui.barHalves(0, 22), 0)
    equal(ui.barHalves(1 / 20000, 22), 1)
    equal(ui.barHalves(6840 / 20000, 22), 15)
    equal(ui.barHalves(10 / 16, 22), 28)
    equal(ui.barHalves(1, 22), 44)
    box.pos(0, 64 - 400, 0)
    m.fuel = 180
    assert(box.fuelOk() == false, "fuel 180 far from home still counted as enough")
  end)

  test("miner screen picks a headline and a tone from phase or homeReason", function()
    local m, ui, box = boot(6840)
    local c = m.env.colors
    local function show()
      local note = ui.note()
      return { note.id, note.tone, note.headline, note.detail[1], note.detail[2], note.keys,
        note.fuel and note.fuel.color or "hidden", note.bag.color, note.head }
    end
    box.phase("mining")
    box.job({ ore = "diamond", y = -58, branchLen = 32 })
    box.layer(-58, 7, 19, 32)
    box.job({ ore = "diamond", y = -58, branchLen = 32 })
    box.found(9)
    equal(show(), { "mining", "work", "Digging for diamonds.",
      "Branch 7 at Y -58, 19 of 32 blocks.", nil, "run", "green", "lightGray", "white" })
    box.phase("descending")
    box.pos(0, -31, 0)
    box.found(0)
    equal(show(), { "descending", "move", "Going down the shaft.",
      "At Y -31, heading for Y -58.", nil, "run", "green", "lightGray", "white" })
    box.phase("returning")
    box.reason("inventory full")
    equal(show(), { "returning", "move", "Coming home to unload.",
      "The bag is full.", nil, "run", "green", "lightGray", "white" })
    box.reason("recalled")
    equal(show(), { "recalled", "move", "Coming home.",
      "The hub called me back.", nil, "run", "green", "lightGray", "white" })
    box.reason("fuel low")
    local low = show()
    equal(low, { "lowfuel", "soon", "Coming home to refuel.",
      "Fuel is low. If the chest behind", "home is empty, add coal or lava.", "run", "orange", "lightGray", "orange" })
    box.phase("home")
    box.reason(nil)
    box.setStatus("Unloading")
    box.haul({ ["minecraft:diamond"] = 9, ["minecraft:redstone"] = 37, ["minecraft:coal"] = 22,
      ["minecraft:raw_iron"] = 14 })
    equal(show()[1], "unloading")
    equal(ui.note().headline, "Unloading into the chest.")
    equal(ui.note().detail[1], "9 diamond, 37 redstone, 22 coal.")
    box.setStatus("Refueling")
    box.need(2000)
    equal(show(), { "refueling", "move", "Refueling from the chest.",
      "Filling to 2000 for the next trip.", nil, "run", "green", "lightGray", "white" })
    box.setStatus("Not enough fuel in the chest (310/2000)")
    equal(show()[1], "outfuel")
    equal(ui.note().headline, "Out of fuel at home.")
    equal(ui.note().fuel.color, "orange")
    equal(ui.note().tone, "now")
    box.setStatus("Chest full!")
    equal(show()[1], "chestfull")
    equal(ui.note().bag.color, "orange")
    equal(ui.note().head, "orange")
    box.setStatus("STUCK: bedrock")
    box.error("Bedrock below me at -112 -58 304. Clear it, then press R to retry.")
    local stuck = ui.note()
    equal(stuck.id, "stuck")
    equal(stuck.tone, "now")
    equal(stuck.headline, "Stuck. I need a hand.")
    equal(stuck.detail[1], "Bedrock below me at -112 -58 304.")
    equal(stuck.detail[2], "Clear it, then press R to retry.")
    equal(stuck.keys, "stuck")
    equal(stuck.head, "red")
    box.setStatus("Starting")
    box.error(nil)
    box.phase("lost")
    box.pos(-112, -58, 304)
    equal(show(), { "lost", "now", "Lost. Going up to find home.",
      "At -112 -58 304.", nil, "run", "green", "lightGray", "red" })
    box.phase("home")
    box.setStatus("ERROR: no chest next to me. Put me on my home spot, Ctrl+T, type: miner home")
    local chest = ui.note()
    equal(chest.id, "nochest")
    equal(chest.keys, "none")
    equal(chest.keysText, "")
    equal(chest.detail[2], "Ctrl+T and type: miner home")
    box.setStatus("Starting")
    box.phase("mining")
    ui.pause = true
    ui.sync()
    equal(ui.note().id, "paused")
    equal(ui.note().headline, "Paused.")
    equal(ui.note().keysText, "P go on   H come home")
    ui.pause = false
    ui.sync()
    box.estop(true)
    equal(ui.note().id, "stopped")
    equal(ui.note().keys, "none")
    box.estop(false)
    box.navStopped(true)
    equal(ui.note().headline, "Stopped by the hub.")
    box.navStopped(false)
    box.phase("home")
    box.mining({ phase = "done" })
    equal(ui.note().id, "done")
    equal(ui.note().tone, "done")
    equal(ui.note().marker, "lightBlue")
    equal(ui.note().headline, "This level is done.")
    equal(ui.note().detail[1], "Waiting at home for the hub.")
    box.mining(nil)
    box.setStatus("Waiting for orders")
    equal(ui.note().id, "done")
    equal(ui.note().detail[1], "Waiting for orders.")
    box.setStatus("No hub found (staying home)")
    equal(ui.note().detail[1], "No hub found (staying home).")
    assert(c.lime and c.orange and c.red)
  end)

  test("miner screen draws the note, the gauges, and the gems", function()
    local m, ui, box = boot(6840)
    local c = m.env.colors
    fill(m, 10)
    box.phase("mining")
    box.job({ ore = "diamond", y = -58, branchLen = 32 })
    box.layer(-58, 7, 19, 32)
    box.job({ ore = "diamond", y = -58, branchLen = 32 })
    box.found(9)
    local term = makeTerm(39, 13, true)
    ui.paint(term, ui.snap())
    assert(#term.bad == 0, dump(term))
    equal(term.row(1):sub(2, 8), "Miner 3")
    assert(term.fg[1][2] == c.lightGray)
    for y = 1, 13 do assert(term.row(y):sub(39, 39) == " ", dump(term)) end
    for _, y in ipairs({ 2, 6, 8, 10, 12 }) do
      equal(term.row(y), string.rep(" ", 39))
    end
    assert(term.row(3):sub(2, 2) == string.char(16) and term.fg[3][2] == c.lime)
    equal(term.row(3):sub(4, 24), "Digging for diamonds.")
    assert(term.fg[3][4] == c.white)
    equal(term.row(4):sub(4, 38), "Branch 7 at Y -58, 19 of 32 blocks.")
    equal(term.row(7):sub(4, 7), "Fuel")
    equal(term.row(7):sub(10, 16), string.rep(band, 7))
    equal(term.row(7):sub(17, 17), half)
    assert(term.fg[7][10] == c.green and term.fg[7][17] == c.green and term.fg[7][18] == c.gray)
    equal(term.row(7):sub(35, 39), "6840 ")
    equal(term.row(9):sub(4, 6), "Bag")
    equal(term.row(9):sub(10, 23), string.rep(band, 14))
    assert(term.fg[9][10] == c.lightGray and term.fg[9][24] == c.gray)
    equal(term.row(9):sub(34, 39), "10/16 ")
    equal(term.row(11):sub(4, 14), string.rep(gem, 9) .. " 9")
    assert(term.fg[11][4] == c.lightBlue and term.fg[11][14] == c.lightBlue)
    equal(term.row(13):sub(2, 22), "P pause   H come home")
    assert(term.fg[13][2] == c.gray)
    box.found(0)
    ui.paint(term, ui.snap())
    equal(term.row(11):sub(4, 29), "No diamonds yet this trip.")
    assert(term.fg[11][4] == c.gray)
    assert(not term.row(11):find(gem, 1, true), dump(term))
    box.found(5)
    ui.paint(term, ui.snap())
    equal(term.row(11):sub(4, 10), string.rep(gem, 5) .. " 5")
    box.found(30)
    ui.paint(term, ui.snap())
    equal(term.row(11):sub(4, 30), string.rep(gem, 24) .. " 30")
    local plain = makeTerm(39, 13, false)
    box.found(9)
    box.phase("mining")
    ui.paint(plain, ui.snap())
    assert(#plain.bad == 0, dump(plain))
    local allow = { [c.white] = true, [c.lightGray] = true, [c.gray] = true, [c.black] = true }
    for y = 1, 13 do
      for x = 1, 39 do
        assert(allow[plain.fg[y][x]], "fg " .. tostring(plain.fg[y][x]))
        assert(plain.bg[y][x] == c.black, "bg")
      end
    end
    assert(plain.fg[3][2] == c.white and plain.fg[7][10] == c.white and plain.fg[7][18] == c.gray)
    assert(plain.fg[1][2] == c.lightGray and plain.fg[13][2] == c.gray)
    m.fuel = "unlimited"
    ui.paint(term, ui.snap())
    equal(term.row(7), string.rep(" ", 39))
    local narrow = makeTerm(26, 13, true)
    m.fuel = 6840
    ui.paint(narrow, ui.snap())
    assert(#narrow.bad == 0, dump(narrow))
    equal(narrow.row(7):sub(22, 26), "6840 ")
    local tiny = makeTerm(1, 1, true)
    ui.paint(tiny, ui.snap())
    assert(#tiny.bad == 0, dump(tiny))
  end)

  test("miner screen keys pause, come home, and retry", function()
    local m, ui, box = boot(6840)
    box.phase("mining")
    box.job({ ore = "diamond", y = -58, branchLen = 32 })
    equal(ui.key(m.env.keys.p), "redraw")
    assert(ui.pause == true and box.recall() == true)
    assert(not box.estopped())
    equal(ui.key(m.env.keys.h), "redraw")
    assert(ui.home == true and box.recall() == true)
    equal(ui.key(m.env.keys.r), "redraw")
    assert(ui.retry ~= true)
    equal(ui.key(m.env.keys.q), "redraw")
    ui.pause = false
    ui.home = false
    ui.sync()
    box.setStatus("STUCK: bedrock")
    box.error("bedrock")
    equal(ui.key(m.env.keys.p), "redraw")
    assert(ui.pause ~= true)
    equal(ui.key(m.env.keys.r), "redraw")
    assert(ui.retry == true)
    box.setStatus("ERROR: no chest next to me")
    ui.retry = false
    equal(ui.key(m.env.keys.r), "redraw")
    equal(ui.key(m.env.keys.h), "redraw")
    assert(ui.retry ~= true and ui.home ~= true)
    assert(box.fuelOk() == true)
  end)

  test("miner screen stays quiet once it is up and still logs a bad frame", function()
    local m, ui, box = boot(180)
    box.setStatus("Digging")
    local printed = false
    for _, line in ipairs(m.output) do
      if line:find("Digging", 1, true) then printed = true end
    end
    assert(printed, "status was quiet before the screen owned print")
    m.env.term = makeTerm(39, 13, false)
    local co = coroutine.create(ui.screen)
    assert(wake(co) == "suspended")
    local n = #m.output
    box.setStatus("Quiet")
    assert(#m.output == n, "the screen still printed status")
    assert(m.queued[#m.queued][1] == "miner_draw")
    assert(wake(co, "miner_draw") == "suspended")
    local text, back = m.env.term.setters.text, m.env.term.setters.back
    ui.snap = function() error("bad frame", 0) end
    assert(wake(co, "timer", m.timer) == "suspended")
    equal(ui.said, "bad frame")
    assert(wake(co, "key", m.env.keys.q) == "suspended")
    assert(m.env.term.setters.text == text and m.env.term.setters.back == back)
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
    assert(ui.home == true)
    assert(wake(co, "timer", m.timer) == "suspended")
    assert(ui.home == false and box.recall() == false)
    box.phase("mining")
    ui.home = true
    ui.sync()
    assert(wake(co, "timer", 0) == "suspended")
    assert(ui.home == true and box.recall() == true)
  end)

  test("miner screen is on unless screen is false", function()
    local m, ui, box = boot(180)
    local main = function() end
    assert(ui.withScreen(main) ~= main)
    local saw
    m.env.parallel.waitForAny = function(screen, work) saw = { screen, work } end
    ui.withScreen(main)()
    assert(saw[1] == ui.screen and saw[2] == main)
    box.screen(false)
    assert(ui.withScreen(main) == main)
    box.screen(nil)
    assert(ui.withScreen(main) ~= main)
  end)
end
