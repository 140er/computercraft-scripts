local R = dofile("tests/ui/render.lua")
local function read(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end
local function source(path)
  local root = os.getenv("UI0_BASELINE")
  return read(root and (root .. "/" .. path) or path)
end
local function client(w, h)
  local out = R.capture(w, h)
  local state = { now = 0, sends = {}, timers = {}, nextTimer = 0, scale = 1, sizes = { w, h } }
  local env = setmetatable({}, { __index = _G })
  env.os = setmetatable({
    epoch = function() return state.now end,
    clock = function() return state.now / 1000 end,
    getComputerID = function() return 2 end,
    getComputerLabel = function() return "screen" end,
    startTimer = function(seconds)
      state.nextTimer = state.nextTimer + 1
      state.timers[state.nextTimer] = seconds
      return state.nextTimer
    end,
    cancelTimer = function(id) state.timers[id] = nil end,
    pullEvent = coroutine.yield,
  }, { __index = os })
  out.setTextScale = function(scale)
    state.scale = scale
    state.scaleCalls = (state.scaleCalls or 0) + 1
  end
  out.getSize = function() return unpack(state.sizes) end
  out.getPaletteColour = function(n) return n / 65536, 0.25, 0.5 end
  env.term = out
  env.peripheral = { find = function(kind)
    if kind == "monitor" then
      return setmetatable({}, { __index = out })
    end
  end, getName = function() return "right" end }
  env.rednet = {
    lookup = function() return 1 end,
    send = function(_, msg) state.sends[#state.sends + 1] = msg end,
  }
  env.dofile = function(path)
    if path == "so-pair.lua" then return { open = function() end, key = function() return "key" end } end
    if path == "so-store.lua" then return {store=function() return {} end} end
    if path == "so-proto.lua" then
      return { build = function(_, t, body) return { t = t, body = body } end,
        encode = function(msg) return msg end, decode = function(msg) return msg end, macOk = function() return true end }
    end
    error(path)
  end
  local code, count = source("display.lua"):gsub("C.loop%(%)%s*$", "return C")
  assert(count == 1)
  local c = assert(load(code, "@display.lua", "t", env))()
  return c, out, state
end

local function server(saved)
  local proto = dofile("so-proto.lua")
  local state = { saved = saved or { roles = {} }, sends = {} }
  local env = setmetatable({ os={epoch=function() return 0 end}, SO = {now=function() return 0 end, mods = {}, proto = proto, pair = { key = function() return "key" end } } }, { __index = _G })
  env.SO.store = { store = function(_, valid)
    assert(valid(state.saved))
    return { value = state.saved, save = function(value)
      assert(valid(value))
      if state.fail then return false, "disk full" end
      state.saved = value
      return true
    end }
  end }
  env.rednet = { send = function(_, msg) state.sends[#state.sends + 1] = msg end }
  local display = assert(load(source("so-mod-display.lua"), "@so-mod-display.lua", "t", env))()
  local function frame(w, h)
    display.handlers.hello({ from = 2, body = { w = w, h = h } })
    local result
    display.handlers["view.get"]({ from = 2 }, function(_, body) result = body end)
    return result
  end
  return display, frame, state, proto
end

local function glyphRows(glyph, ink, background)
  local rows = {}
  for r = 0, 2 do
    local text, fg, bg = {}, {}, {}
    for c = 0, 2 do
      local bits = 0
      for p = 0, 5 do
        local x, y = c * 2 + p % 2, r * 3 + math.floor(p / 2)
        if x < 5 and y >= 1 and y <= 7 and glyph[y]:sub(x + 1, x + 1) == "#" then bits = bits + 2 ^ p end
      end
      local inverse = bits >= 32
      text[c + 1] = string.char(128 + (inverse and 63 - bits or bits))
      fg[c + 1], bg[c + 1] = inverse and background or ink, inverse and ink or background
    end
    rows[r + 1] = { text = table.concat(text), fg = table.concat(fg), bg = table.concat(bg) }
  end
  return rows
end

return function(test, equal)
  test("UI0 old and compact frames draw identical cells and tall buttons hit their rectangle", function()
    local c, out = client(8, 5)
    c.onFrame({ body = { rows = { { text = "abcdef", fg = "00ff00", bg = "ddeedd" } } } })
    local expected = out.picture()
    local cells = dofile("so-proto.lua").ser(out.cells)
    c.onFrame({ body = { rows = { { text = "abcdef", runs = { { 2, "0", "d" }, { 2, "f", "e" }, { 2, "0", "d" } } } },
      buttons = { { id = "buy", x = 2, y = 2, w = 3, h = 3 } } } })
    equal(R.diff(expected, out), {})
    equal(dofile("so-proto.lua").ser(out.cells), cells)
    for y = 2, 4 do assert(c.hit(2, y) and c.hit(4, y), "button row " .. y) end
    assert(not c.hit(1, 3) and not c.hit(5, 3) and not c.hit(2, 1) and not c.hit(2, 5))
    c.onFrame({ body = { rows = { { text = "a", runs = { { 8, "f", "e" } } } } } })
    equal(out.picture().text[1], "a       ")
    equal(out.picture().bg[1], "eeeeeeee")
  end)

  test("UI0 kit frames keep last-row navigation after a duplicate resize", function()
    local c = client(26, 20)
    c.onFrame({body={palette=dofile("so-ui.lua").palette,
      buttons={{id="panel",label="PANEL",x=19,y=20,w=7}}}})
    assert(c.hit(19,20), "kit navigation must use the full screen")
    local loop=coroutine.create(c.loop)
    assert(coroutine.resume(loop))
    assert(coroutine.resume(loop,"monitor_resize","right"))
    assert(c.hit(19,20), "duplicate resize must keep the last row clickable")
  end)

  test("UI0 three-row buttons include every row and exclude adjacent cells", function()
    local c = client(8, 5)
    c.onFrame({ body = { buttons = { { id = "buy", x = 2, y = 2, w = 3, h = 3 } } } })
    for y = 2, 4 do assert(c.hit(2, y) and c.hit(4, y), "button row " .. y) end
    assert(not c.hit(1, 3) and not c.hit(5, 3) and not c.hit(2, 1) and not c.hit(2, 5))
    c.onFrame({ body = { buttons = { { id = "buy", x = 2, y = 2, w = 3 } } } })
    assert(c.hit(2, 2) and not c.hit(2, 3), "default button height")
  end)

  test("UI0 palette and scale send exactly one resized hello and restore stock colours", function()
    local c, out, state = client(29, 12)
    local palette = {}
    for i = 0, 15 do palette[i] = 0x102030 + i end
    local original = out.setTextScale
    out.setTextScale = function(scale)
      original(scale)
      if scale == 0.5 then state.sizes = { 57, 24 } end
    end
    local before = #state.sends
    c.onFrame({ body = { rows = {}, palette = palette, scale = 0.5 } })
    equal(state.scale, 0.5)
    equal(#state.sends, before + 1)
    equal(state.sends[#state.sends], { t = "hello", body = { w = 57, h = 23, fullH = 24, keyboard = false, label = "screen" } })
    for i = 0, 15 do equal(out.palette[2 ^ i], { palette[i] }) end
    local loop = coroutine.create(c.loop)
    assert(coroutine.resume(loop))
    assert(coroutine.resume(loop, "monitor_resize", "right"))
    equal(#state.sends, before + 1)
    c.onFrame({ body = { rows = {}, scale = 0.5 } })
    equal(#state.sends, before + 1)
    for i = 0, 15 do equal(out.palette[2 ^ i], { 2 ^ i / 65536, 0.25, 0.5 }) end
  end)

  test("UI0 tiled 164x81 frame fits the real serializer without losing cells", function()
    local display, frame, _, proto = server({ roles = { ["2"] = "generic" } })
    local rows = {}
    for y = 1, 81 do
      local text, fg, bg = {}, {}, {}
      for x = 1, 164 do
        local tile = math.floor((x - 1) / 55)
        local colour = (y > 18 or y % 6 == 0 or x % 55 == 0) and "f" or ({ "d", "b", "e" })[tile % 3 + 1]
        text[x] = " "
        fg[x], bg[x] = colour == "f" and "0" or "f", colour
      end
      if y <= 18 and y % 6 >= 2 and y % 6 <= 4 then
        local glyph = glyphRows({ ".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####" }, "f", "d")[y % 6 - 1]
        for x = 1, 3 do text[x + 6], fg[x + 6], bg[x + 6] = glyph.text:sub(x, x), glyph.fg:sub(x, x), glyph.bg:sub(x, x) end
      end
      rows[y] = { text = table.concat(text), fg = table.concat(fg), bg = table.concat(bg) }
    end
    display.screen("generic", function() return { rows = rows } end)
    local body = frame(164, 81)
    local bytes = #proto.ser(body)
    assert(bytes <= 16384, "frame bytes " .. bytes)
    equal(#body.rows, 81)
    local c, out = client(164, 81)
    c.onFrame({ body = { rows = rows } })
    local expected = out.picture()
    local cells = proto.ser(out.cells)
    c.onFrame({ body = { rows = body.rows } })
    equal(R.diff(expected, out), {})
    equal(proto.ser(out.cells), cells)
    print("UI0 tiled frame body " .. bytes .. " bytes")
  end)

  test("UI0 far persists beside roles and a failed save leaves scale unchanged", function()
    local display, frame, state = server({ roles = { ["2"] = "status" } })
    equal(frame(57, 24).scale, 0.5)
    assert(display.far(2, true))
    equal(frame(57, 24).scale, 1)
    equal(state.saved.roles["2"], "status")
    local restarted, again = server(state.saved)
    equal(again(57, 24).scale, 1)
    state.fail = true
    assert(not display.far(2, false))
    equal(frame(57, 24).scale, 1)
    assert(restarted.far(2, false))
    equal(again(57, 24).scale, 0.5)
    assert(restarted.far(0, true))
    equal(display.palette[0], 0xE6EAF2)
    equal(display.palette[15], 0x0B111C)
    display.screen("status", function() return { rows = {}, palette = display.palette,
      buttons = { { id = "buy", x = 1, y = 2, w = 3, h = 3 } } } end)
    local body = frame(8, 3)
    equal(body.palette, display.palette)
    equal(body.buttons[1].h, 2)
  end)

  test("UI0 outage matches the fixture without a server and retries continue", function()
    local c, out, state = client(57, 24)
    c.onFrame({ body = { rows = { { text = " STATUS  (last picture, greyed)", fg = "0", bg = "f" } } } })
    local loop = coroutine.create(c.loop)
    assert(coroutine.resume(loop))
    state.now = 10000
    assert(coroutine.resume(loop, "timer", c.timer))
    assert(c.phase == "stale", "stale timeout did not fire")
    state.now = 42000
    c.retryAt = state.now + 8000
    assert(coroutine.resume(loop, "timer", c.repaint))
    local differences = R.diff("tests/ui/fixtures/outage-M.txt", out)
    assert(#differences == 0, table.concat(differences, "\n"))
    local before = #state.sends
    for i = 1, 7 do
      state.now = state.now + state.timers[c.timer] * 1000
      assert(coroutine.resume(loop, "timer", c.timer))
      equal(#state.sends, before + i * 2)
      assert(state.timers[c.timer] <= 30)
    end
    assert(c.phase == "stale")
  end)

  test("UI0 stale repaint preserves inverted digits and button labels", function()
    local c, out, state = client(57, 24)
    local rows = glyphRows({ ".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." }, "f", "d")
    c.onFrame({ body = { rows = rows, buttons = { { id = "x", x = 5, y = 1, w = 4, label = "KEEP" } } } })
    local before = out.picture()
    state.now = 42000
    c.markStale()
    local after = out.picture()
    for y = 1, 3 do
      equal(after.text[y], before.text[y])
      equal(after.bg[y], string.rep("c", 57))
    end
  end)

  test("UI0 capture round-trips every spec glyph including inverted sextants", function()
    local spec = read("docs/ui/BIG-TILES-SPEC.md"):match("## 4%. Big digit font(.-)## 5%.")
    local count = 0
    local c = client(57, 24)
    for ch, line in spec:gmatch("\n([0-9%%%-:/]):  ([.# ][^\n]+)") do
      local glyph = {}
      for row in line:gmatch("[.#]+") do glyph[#glyph + 1] = row end
      equal(#glyph, 7)
      if ch:match("[0-9:]") then equal(c.font[ch], table.concat(glyph)) end
      for _, background in ipairs({ "d", "e", "b", "c", "f", "7" }) do
        local ink = (background == "c" or background == "f" or background == "7") and "0" or "f"
        local rows = glyphRows(glyph, ink, background)
        local out = R.capture(3, 3)
        for y, row in ipairs(rows) do out.setCursorPos(1, y); out.blit(row.text, row.fg, row.bg) end
        local got = out.picture()
        local pixels = {}
        for row = 1, 9 do pixels[row] = "" end
        for r = 0, 2 do
          local column = 0
          for ch in got.text[r + 1]:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            local bits
            if ch == " " then bits = 0
            elseif ch == "█" then bits = 63
            elseif ch == "▌" then bits = 21
            elseif ch == "▐" then bits = 42
            else
              local a, b, c, d = ch:byte(1, 4)
              assert(d, "expected Unicode sextant")
              local codepoint = (a - 240) * 262144 + (b - 128) * 4096 + (c - 128) * 64 + d - 128
              bits = codepoint - 0x1FB00 + 1
              if bits >= 21 then bits = bits + 1 end
              if bits >= 42 then bits = bits + 1 end
              assert(bits > 0 and bits < 63, "sextant range")
            end
            for py = 0, 2 do
              local row = r * 3 + py + 1
              for px = 0, 1 do
                pixels[row] = pixels[row] .. (math.floor(bits / 2 ^ (py * 2 + px)) % 2 == 1 and "#" or ".")
              end
            end
            column = column + 1
          end
          equal(column, 3)
          equal(got.bg[r + 1], string.rep(background, 3))
        end
        equal(pixels[1], "......")
        equal(pixels[9], "......")
        for row = 1, 7 do equal(pixels[row + 1], glyph[row] .. ".") end
      end
      count = count + 1
    end
    equal(count, 14)
    local out = R.capture(2, 1)
    out.setBackgroundColour(2 ^ 13); out.setTextColour(2 ^ 15); out.clear()
    out.setCursorPos(2, 1); out.write("X")
    equal(out.picture().text[1], " X")
    equal(out.picture().bg[1], "dd")
    local differences = R.diff({ w = 2, h = 1, text = { " Y" }, bg = { "dd" } }, out)
    assert(differences[1]:find('row 1 column 2 layer text expected "Y" got "X"', 1, true))
  end)

  test("UI0 generator preserves section 7.1 and reproduces every fixture", function()
    assert(#source("display.lua") < 16384, "display.lua exceeds 16 KB")
    local pipe = io.popen("pwd")
    local root = pipe and pipe:read("*l")
    if pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= "/" or not os.execute("python3 -V > /dev/null 2>&1") then
      return dofile("tests/skips.lua").record(
        "UI0 generator preserves section 7.1 and reproduces every fixture",
        "needs a POSIX shell and python3")
    end
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "'"))
    local generatorRoot = os.getenv("UI0_BASELINE") or root
    local command = "cd '" .. dir .. "' && python3 -I '" .. generatorRoot .. "/docs/ui/mockup-gen.py'"
    assert(os.execute(command .. " > /dev/null"))
    local spec = read("docs/ui/BIG-TILES-SPEC.md")
    local section = spec:match("\n(Status, room monitor.-)\n\n\n### 7%.2")
    equal(read(dir .. "/mockups.md"), assert(section) .. "\n")
    assert(os.execute(command .. " --fixtures fixtures"))
    -- Status and the shop moved to docs/ui/schematic (tests/ui/s0.lua and tests/ui/ui2c.lua check them).
    local names = "panel-P mining-M lumber-M drops-M alert-M outage-M server-T pairing-T ar-M panelpair-P panelcode-P panelpair-S panelcode-S unassigned-M unassigned-XS roles-T map-26x20 map-29x12 map-57x24 pocket-fleet-P pocket-alerts-P pocket-jobs-P pocket-shop-P pocket-pair-P pocket-code-P"
    for name in names:gmatch("%S+") do
      equal(read(dir .. "/fixtures/" .. name .. ".txt"), read("tests/ui/fixtures/" .. name .. ".txt"))
      R.load(dir .. "/fixtures/" .. name .. ".txt")
    end
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)
end
