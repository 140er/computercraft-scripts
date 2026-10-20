local Core = dofile("install-core.lua")
local Touch = dofile("install-touch.lua")
local Roles = dofile("install-roles.lua")

-- Computer 51x19, turtle 39x13, pocket 26x20.
-- Scale 1 on an 8 by 6 advanced monitor is 164 by 81.
local PROFILES = {
  { name = "turtle", width = 39, height = 13 },
  { name = "computer", width = 51, height = 19 },
  { name = "pocket", width = 26, height = 20 },
  { name = "monitor", width = 164, height = 81 },
}

local FILES = {
  "fresh-miner", "home-frame", "code-expired", "code-replayed", "code-burned",
  "neighbour-missing", "neighbour-unknown", "disk-full", "hash-mismatch",
}

local function readFile(path)
  local file = io.open(path, "rb")
  if file then
    local text = file:read("*a")
    file:close()
    return text
  end
  if fs and fs.exists and fs.exists(path) then
    local handle = fs.open(path, "r")
    local text = handle.readAll()
    handle.close()
    return text
  end
end

local function loadEvent(name)
  local paths = { "tests/i2-events/" .. name .. ".lua", "i2-events/" .. name .. ".lua" }
  local last
  for _, path in ipairs(paths) do
    local fn, err = loadfile(path)
    if fn then return fn() end
    last = err
  end
  error("missing event file " .. name .. ": " .. tostring(last))
end

local function fits(view, profile, where)
  assert(#view.lines == profile.height, where .. " height " .. #view.lines)
  local used = {}
  for _, line in ipairs(view.lines) do
    assert(#line == profile.width, where .. " width " .. #line)
  end
  for _, button in ipairs(view.buttons) do
    assert(button.x >= 1 and button.y >= 1 and button.w >= 1 and button.h == 1, where)
    assert(button.x + button.w - 1 <= profile.width, where .. " button x")
    assert(button.y <= profile.height, where .. " button y")
    for x = button.x, button.x + button.w - 1 do
      local key = button.y .. ":" .. x
      assert(not used[key], where .. " overlap at " .. key)
      used[key] = true
    end
  end
end

local function resolve(state, event)
  if event.t == "choose" then
    local n
    for i, opt in ipairs(Core.options(state)) do
      if opt.id == event.id then n = i break end
    end
    assert(n, "no option " .. tostring(event.id) .. " on " .. tostring(state.step))
    return { t = "choose", n = n }
  end
  if event.t == "text" then return { t = "text", s = event.s } end
  if event.t == "back" then return { t = "back" } end
  return event
end

local function find(ui, state, profile, kind, id)
  local view = Touch.render(state, ui)
  fits(view, profile, state.step .. " " .. kind)
  for _, button in ipairs(view.buttons) do
    if button.kind == kind and (id == nil or button.id == id) then return button end
  end
end

local function press(ui, state, profile, kind, id)
  for _ = 1, 12 do
    local button = find(ui, state, profile, kind, id)
    if button then return Touch.hit(ui, state, button.x, button.y) end
    local more = find(ui, state, profile, "more")
    if not more then return nil end
    assert(Touch.hit(ui, state, more.x, more.y) == nil, "More changed the install")
  end
end

local function enterText(ui, state, profile, text)
  ui.buffer = ""
  for i = 1, #text do
    local ev = Touch.key(ui, state, nil, text:sub(i, i))
    assert(ev == nil, "a typed character left the field")
  end
  local view = Touch.render(state, ui)
  fits(view, profile, "text")
  local shown = false
  for _, line in ipairs(view.lines) do
    if line:find("> " .. text, 1, true) then shown = true end
  end
  assert(shown, "buffer hid " .. text)
  return press(ui, state, profile, "done")
end

local function play(script, profile, touchPath)
  local state = Core.boot(script.machine, Roles.catalog())
  local ui = Touch.new(profile.width, profile.height)
  local seen = {}
  for step, event in ipairs(script.events) do
    local resolved = resolve(state, event)
    local produced = resolved
    if touchPath and event.t ~= "io" then
      if event.t == "text" then produced = enterText(ui, state, profile, event.s)
      elseif event.t == "back" then produced = press(ui, state, profile, "back")
      else produced = press(ui, state, profile, "choose", event.id) end
      assert(produced, script.name .. " step " .. step .. " had no button on " .. profile.name)
      assert(produced.t == resolved.t, script.name .. " event " .. step)
      assert(produced.n == resolved.n, script.name .. " choice " .. step)
      assert(produced.s == resolved.s, script.name .. " text " .. step)
    end
    local effects
    state, effects = Core.transition(state, produced)
    for _, effect in ipairs(effects) do
      assert(effect.op ~= "gps", script.name .. " asked for gps")
    end
    if touchPath then fits(Touch.render(state, ui), profile, script.name .. " after " .. step) end
    seen[#seen + 1] = Roles.literal({ state = state, effects = effects })
  end
  return seen, state
end

local EXPECT = {
  ["fresh-miner"] = function(state)
    assert(state.step == "done", state.step)
    assert(state.role == "miner" and state.source == "fresh")
    assert(state.pos.h == 0 and state.pos.x == 10 and state.pos.y == 64 and state.pos.z == 20)
  end,
  ["home-frame"] = function(state)
    assert(state.step == "review", state.step)
    assert(state.pos.frame == "f:31:1792500000000", state.pos.frame)
    assert(state.pos.h == 3 and state.pos.x == 0 and state.pos.y == 0 and state.pos.z == 0)
    assert(state.pos.yAbs == false and state.pos.conf == "suspect" and state.pos.src == "reckoned")
  end,
  ["code-expired"] = function(state)
    assert(state.step == "enter_code" and state.error == false, state.step)
  end,
  ["code-replayed"] = function(state)
    assert(state.step == "enter_code" and state.error == false, state.step)
  end,
  ["code-burned"] = function(state)
    assert(state.step == "enter_code" and state.error == false, state.step)
  end,
  ["neighbour-missing"] = function(state)
    assert(state.step == "neighbour" and state.error == false, state.step)
    assert(Core.options(state)[1].id == "front")
  end,
  ["neighbour-unknown"] = function(state)
    assert(state.step == "neighbour" and state.error == false, state.step)
  end,
  ["disk-full"] = function(state)
    assert(state.step == "fetch" and state.error == false, state.step)
  end,
  ["hash-mismatch"] = function(state)
    assert(state.step == "fetch" and state.error == false, state.step)
  end,
}

return function(test, equal)
  for _, name in ipairs(FILES) do
    test("touch replays " .. name .. " on every screen", function()
      local script = loadEvent(name)
      equal(script.name, name)
      local direct = play(script, PROFILES[1], false)
      for _, profile in ipairs(PROFILES) do
        local touched, final = play(script, profile, true)
        assert(#touched == #direct, name .. " " .. profile.name .. " length")
        for i = 1, #direct do
          equal(touched[i], direct[i], name .. " " .. profile.name .. " step " .. i)
        end
        EXPECT[name](final)
      end
    end)
  end

  test("a miss, a gap and a typed edit do not change the install", function()
    local script = loadEvent("fresh-miner")
    local state = Core.boot(script.machine, Roles.catalog())
    state = Core.transition(state, script.events[1])
    local ui = Touch.new(39, 13)
    local before = Roles.literal(state)
    assert(Touch.hit(ui, state, 1, 1) == nil, "title was a button")
    assert(Touch.hit(ui, state, 40, 2) == nil, "past the right edge")
    assert(Touch.hit(ui, state, 0, 2) == nil, "past the left edge")
    local view = Touch.render(state, ui)
    assert(Touch.hit(ui, state, 7, 13) == nil, "gap beside Back")
    equal(Roles.literal(state), before)
    local fresh
    for i, opt in ipairs(Core.options(state)) do
      if opt.id == "fresh" then fresh = i end
    end
    state = Core.transition(state, { t = "choose", n = fresh })
    ui = Touch.new(26, 8)
    view = Touch.render(state, ui)
    local more
    for _, button in ipairs(view.buttons) do
      if button.kind == "more" then more = button end
    end
    assert(more, "short screen hid More")
    before = Roles.literal(state)
    assert(Touch.hit(ui, state, more.x, more.y) == nil)
    equal(Roles.literal(state), before)
    local store = press(ui, state, { width = 26, height = 8 }, "choose", "store")
    local direct = resolve(state, { t = "choose", id = "store" })
    equal(store, direct)
    local touched = Core.transition(state, store)
    local plain = Core.transition(state, direct)
    equal(Roles.literal(touched), Roles.literal(plain))
    assert(touched.step == "position" and touched.role == "store")
    local back = Touch.scroll(Touch.new(26, 8), state, 1)
    assert(back == nil)
    ui = Touch.new(39, 13)
    state = Core.transition(state, { t = "choose", n = 1 })
    state = Core.transition(state, { t = "choose", n = 1 })
    Touch.key(ui, state, nil, "1")
    Touch.key(ui, state, nil, "0")
    Touch.key(ui, state, nil, "/")
    local bad = Touch.key(ui, state, "enter")
    equal(bad, { t = "text", s = "10" })
    ui = Touch.new(39, 13)
    Touch.key(ui, state, nil, "A")
    assert(Touch.key(ui, state, "backspace") == nil)
    assert(ui.buffer == "")
    equal(Touch.key(ui, state, "backspace"), { t = "back" })
    ui = Touch.new(39, 13)
    for _ = 1, 49 do Touch.key(ui, state, nil, "a") end
    assert(#ui.buffer == 48, #ui.buffer)
  end)

  test("clicks, the monitor and the keyboard pick the same button", function()
    local script = loadEvent("fresh-miner")
    local state = Core.boot(script.machine, Roles.catalog())
    state = Core.transition(state, script.events[1])
    local ui = Touch.new(51, 19)
    local view = Touch.render(state, ui)
    local code
    for _, button in ipairs(view.buttons) do
      if button.id == "code" then code = button end
    end
    local click = Touch.hit(ui, state, code.x, code.y)
    ui = Touch.new(51, 19)
    local typed = Touch.input(ui, state, "mouse_click", 1, code.x, code.y)
    equal(click, typed)
    ui.monitor = "top"
    assert(Touch.input(ui, state, "mouse_click", 1, code.x, code.y) == nil)
    assert(Touch.input(ui, state, "monitor_touch", "left", code.x, code.y) == nil)
    equal(Touch.input(ui, state, "monitor_touch", "top", code.x, code.y), click)
    ui = Touch.new(51, 19)
    Touch.render(state, ui)
    Touch.key(ui, state, "down")
    local entered = Touch.key(ui, state, "enter")
    equal(entered, { t = "choose", n = 2 })
    equal(Touch.key(Touch.new(51, 19), state, nil, "1"), { t = "choose", n = 1 })
  end)

  test("touch stays off unless install.touch is true on a pointer", function()
    assert(Touch.available() == false)
    local oldSettings, oldTerm, oldPeripheral, oldColors = settings, term, peripheral, colors
    local ok, err = pcall(function()
    settings = { get = function() return nil end }
    term = { isColour = function() return true end }
    assert(Touch.available() == true, "a colour screen left touch off")
    settings = { get = function(key) if key == "install.touch" then return false end end }
    assert(Touch.available() == false, "explicit false left touch on")
    settings = { get = function(key) if key == "install.touch" then return "true" end end }
    assert(Touch.available() == false, "a string setting turned touch on")
    settings = { get = function(key) return key == "install.touch" and true or nil end }
    assert(Touch.available() == true)
    term = { isColour = function() return false end }
    assert(Touch.available() == false, "a basic computer drew buttons")
    peripheral = {
      getNames = function() return { "top" } end,
      getType = function(name) return name == "top" and "monitor" or nil end,
      call = function(_, method) return method == "isColour" end,
      wrap = function() return { getSize = function() return 50, 20 end, write = function() end, setCursorPos = function() end, clear = function() end } end,
    }
    assert(Touch.available() == true, "advanced monitor")
    local target, name = Touch.surface()
    equal(name, "top")
    equal({ target.getSize() }, { 50, 20 })
    colors = { black = 1, white = 2, yellow = 4, gray = 8 }
    local painted = {}
    target.clearLine = function() end
    target.setBackgroundColor = function() end
    target.setTextColor = function() end
    target.write = function(text) painted[#painted + 1] = text end
    local script = loadEvent("fresh-miner")
    local state = Core.boot(script.machine, Roles.catalog())
    state = Core.transition(state, script.events[1])
    Touch.draw(target, Touch.render(state, Touch.new(39, 13)))
    assert(table.concat(painted, "\n"):find("Copy a code", 1, true))
    local shell = assert(readFile("install-shell.lua"))
    local installer = assert(readFile("install.lua"))
    local touch = assert(readFile("install-touch.lua"))
    assert(shell:find("loaded.available", 1, true), "shell skips the flag")
    assert(installer:find("install-touch.lua", 1, true), "installer never downloads the touch view")
    assert(touch:find('settings.get("install.touch")', 1, true), "flag check")
    assert(touch:find("value == false", 1, true), "explicit false ignored")
    assert(not touch:find("gps.locate", 1, true), "touch view calls gps")
    local kept = false
    for _, kitName in ipairs(Roles.kit) do
      if kitName == "install-touch.lua" then kept = true end
    end
    assert(kept, "role install would delete install-touch.lua")
    end)
    settings, term, peripheral, colors = oldSettings, oldTerm, oldPeripheral, oldColors
    assert(ok, err)
  end)
end
