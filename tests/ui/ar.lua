-- U2-AR: AR draw errors are logged, the goggles keep the alert while it is active and ALERTS steps
-- through alerts, drop labels carry the DROP POINTS row number, disabled room points draw grey with
-- no beam, and BROKEN gets its own HUD row under DISK.
local H = dofile('tests/so/harness.lua')
local R = dofile('tests/ui/render.lua')
local WHITE, GREY, RED, HAIR = 0xFFE6EAF2 - 2^32, 0xFF7886A3 - 2^32, 0xFFFF6B5E - 2^32, 0xFF28344D - 2^32

-- The real drops and AR modules on one server, with a fake controller that records each element.
local function boot()
  local m = H.new().machine({ id = 1, capacity = 16000000 })
  m.install({ 'so-store.lua', 'so-ui.lua', 'so-mod-drops.lua', 'so-mod-ar.lua' })
  m.files['so-server.cfg']=H.encode({arFollowups=false,remoteDimensions=false})
  local e, b = m.env, { values = {}, errors = {}, free = 13920000 }
  e.SO = { now = function() return 0 end, mods = {}, store = e.dofile('so-store.lua'), proto = { ser = H.encode },
    error = function(line) b.errors[#b.errors + 1] = line end }
  e.SO.mods.state = { get = function() return {} end, view = function() return { values = b.values } end }
  local screens = {}
  e.SO.mods.display = { screen = function(role, render, input) screens[role] = { render = render, input = input } end }
  e.fs.getCapacity = function() return 16000000 end
  e.fs.getFreeSpace = function() return b.free end
  local ar = { elements = {}, frames = 0 }
  for _, method in ipairs({ 'drawLine3D', 'drawText3D', 'drawRect2D', 'drawText2D' }) do
    ar[method] = function(id, ...)
      if b.fail then error(b.fail, 0) end
      ar.elements[id] = { ... }
    end
  end
  ar.delete = function(id) ar.elements[id] = nil end
  ar.update = function() ar.frames = ar.frames + 1 end
  e.peripheral.find = function() return ar end
  e.peripheral.getName = function() return 'ar_controller_0' end
  b.drops = e.dofile('so-mod-drops.lua')
  assert(b.drops.roomSink(false))
  e.SO.mods.drops = b.drops
  b.ar, b.screens, b.tick = ar, screens, e.dofile('so-mod-ar.lua').tick
  return b
end

local function screen(b, w, h, session)
  local frame = b.screens.ar.render(w, h, session)
  local out = R.capture(w, h)
  for y, row in ipairs(frame.rows) do
    local fg, bg = {}, {}
    for _, run in ipairs(row.runs) do fg[#fg + 1], bg[#bg + 1] = string.rep(run[2], run[1]), string.rep(run[3], run[1]) end
    out.setCursorPos(1, y)
    out.blit(row.text .. string.rep(' ', w - #row.text), table.concat(fg), table.concat(bg))
  end
  return out.picture().text, frame
end

-- B13-U: an AR server with configurable flags, workers, reservations and drops. b.A is the module
-- table; b.files the server's files.
local NETHER, END, OVER = 'minecraft:the_nether', 'minecraft:the_end', 'minecraft:overworld'
local function follow(config, saved, opts)
  for _,name in ipairs({"arFollowups","remoteDimensions"}) do
    if config[name]==nil then config[name]=false end
  end
  opts = opts or {}
  local m = H.new().machine({ id = 1, capacity = 16000000 })
  m.install({ 'so-store.lua', 'so-ui.lua', 'so-mod-ar.lua' })
  local e, b = m.env, { values = {}, machines = {}, cells = {}, points = {}, mine = {}, saves = 0, free = 13920000 }
  m.files['so-server.cfg'] = H.encode(config)
  e.SO = { now = function() return 0 end, mods = {}, store = e.dofile('so-store.lua'), proto = { ser = H.encode } }
  -- The seed write skips the validator, so legacy files with extra keys can be planted.
  if saved then assert(e.SO.store.store('so-data/ar', function() return true end).save(saved)) end
  local store = e.SO.store.store
  e.SO.store.store = function(...)
    local box = store(...)
    local save = box.save
    box.save = function(v) b.saves = b.saves + 1 return save(v) end
    return box
  end
  e.SO.mods.state = { get = function() return b.machines end, view = function() return { values = b.values } end }
  e.SO.mods.cells = { list = function(owner) return b.cells[owner] or {} end,
    retirement = function() return b.retirement end }
  e.SO.mods.drops = { list = function() return b.points end }
  e.SO.mods.mine = { mapView = function() return b.mine end }
  local screens = {}
  e.SO.mods.display = { screen = function(role, render, input) screens[role] = { render = render, input = input } end }
  e.fs.getCapacity = function() return 16000000 end
  e.fs.getFreeSpace = function() return b.free end
  local ar = { elements = {} }
  for _, method in ipairs({ 'drawLine3D', 'drawText3D', 'drawRect2D', 'drawText2D' }) do
    ar[method] = function(id, ...) ar.elements[id] = { ... } end
  end
  ar.delete = function(id) ar.elements[id] = nil end
  ar.update = function() end
  e.peripheral.find = function() return ar end
  b.ar, b.screens, b.files, b.env = ar, screens, m.files, e
  b.load = function()
    b.tick = e.dofile('so-mod-ar.lua').tick
    b.tick(opts.at or 0)
    for i = 1, 10 do
      local k, v = debug.getupvalue(screens.ar.render, i)
      if k == 'A' then b.A = v end
    end
  end
  b.saved = function() return e.SO.store.read('so-data/ar').value end
  -- Display sessions as so-mod-display passes them; taps and renders use display 1 by default.
  b.display = { id = 1 }
  b.tap = function(id, session) screens.ar.input({ id = id, session = session or b.display }) end
  b.text = function(w, h, session) return table.concat(screen(b, w or 57, h or 24, session or b.display), '\n') end
  b.load()
  return b
end
local ON = { arFollowups = true, remoteDimensions = true, pos = { dim = OVER, x = 0, y = 64, z = 0 } }
local function turtle(dim, x) return { role = 'turtle', state = 'idle', seen = 0, pose = { dim = dim, x = x or 1, y = 64, z = 1, facing = 0 } } end
local function cell(dim, x) return { dim = dim, x = x, y = 64, z = 5 } end
local function drawn(b, prefix)
  local out = {}
  for id in pairs(b.ar.elements) do if id:sub(1, #prefix) == prefix then out[#out + 1] = id end end
  return #out
end

return function(test, equal)
  test('U2-AR a failed AR draw logs its error once and the controller recovers', function()
    local b = boot()
    b.fail = 'drawText2D: bad colour'
    b.tick(1000)
    equal(#b.errors, 1)
    assert(b.errors[1]:find('ar_controller_0', 1, true) and b.errors[1]:find('drawText2D: bad colour', 1, true), b.errors[1])
    -- Discovery re-adds the controller every 5 s; the same error is not logged again.
    b.tick(6000)
    equal(#b.errors, 1)
    b.fail = nil
    b.tick(11000)
    assert(b.ar.elements['hud:disk:value'], 'redrawn after the error clears')
    b.fail = 'later'
    b.values['mine.alert'] = { text = 'X' }
    b.tick(12000)
    equal(#b.errors, 2)
  end)

  test('U2-AR the newest alert stays on the goggles while active and ALERTS steps to the next', function()
    local b = boot()
    b.values['mine.alert'] = { text = 'CHEST FULL' }
    b.tick(1000)
    equal(b.ar.elements['alert:rule'][1], RED)
    b.tick(61000)
    equal(b.ar.elements['alert:mine.alert'][4], 'CHEST FULL')
    equal(b.ar.elements['alert:rule'][1], HAIR)
    equal(b.ar.elements['alert:count'], nil)
    b.values['lumber.alert'] = { text = 'NO SAPLINGS' }
    b.tick(62000)
    equal(b.ar.elements['alert:lumber.alert'][4], 'NO SAPLINGS')
    equal(b.ar.elements['alert:mine.alert'], nil)
    equal(b.ar.elements['alert:count'][4], '1/2')
    local text, frame = screen(b, 57, 24)
    assert(text[13]:find('ALERTS', 1, true) and text[13]:find('1/2', 1, true), text[13])
    assert(text[14]:find('! NO SAPLINGS', 1, true), text[14])
    local hit
    for _, button in ipairs(frame.buttons) do if button.id == 'alert:next' then hit = button end end
    equal({ hit.x, hit.y, hit.w, hit.h }, { 1, 13, 57, 2 })
    -- A tap steps to the next alert and redraws on the next tick, with no save.
    b.screens.ar.input({ id = 'alert:next' })
    b.tick(62100)
    equal(b.ar.elements['alert:mine.alert'][4], 'CHEST FULL')
    equal(b.ar.elements['alert:count'][4], '2/2')
    assert(screen(b, 57, 24)[14]:find('! CHEST FULL', 1, true))
    b.screens.ar.input({ id = 'alert:next' })
    b.tick(63100)
    equal(b.ar.elements['alert:lumber.alert'][4], 'NO SAPLINGS')
    -- A new alert takes the flag back.
    b.screens.ar.input({ id = 'alert:next' })
    b.tick(64100)
    equal(b.ar.elements['alert:mine.alert'][4], 'CHEST FULL')
    b.values['shop.alert'] = { text = 'OUT OF SAND' }
    b.tick(65100)
    equal(b.ar.elements['alert:shop.alert'][4], 'OUT OF SAND')
    -- The alert ends: its flag goes and the row leaves the screen.
    b.values = {}
    b.tick(66100)
    equal(b.ar.elements['alert:backing'], nil)
    assert(not table.concat(screen(b, 57, 24), '\n'):find('ALERTS', 1, true))
  end)

  test('U2-AR a disk alert stays when the player stepped to another alert and turns alerts off', function()
    local b = boot()
    b.values['disk.alert'] = { text = 'DISK 90%' }
    b.values['mine.alert'] = { text = 'CHEST FULL' }
    b.tick(1000)
    equal(b.ar.elements['alert:disk.alert'][4], 'DISK 90%')
    b.screens.ar.input({ id = 'alert:next' })
    b.tick(1100)
    equal(b.ar.elements['alert:mine.alert'][4], 'CHEST FULL')
    b.screens.ar.input({ id = 'alerts' })
    b.tick(2100)
    equal(b.ar.elements['alert:mine.alert'], nil)
    equal(b.ar.elements['alert:disk.alert'][4], 'DISK 90%')
  end)

  test('U2-AR drop labels read #n like the DROP POINTS rows', function()
    local b = boot()
    for i, kind in ipairs({ 'ore', 'fuel', 'ore' }) do
      assert(b.drops.add({ id = 'p' .. i, kind = kind, dim = 0, x = i * 4, y = 64, z = 0, side = 'front' }))
    end
    local list = b.drops.list()
    for i = 1, 3 do equal(list[i].n, i) end
    b.tick(1000)
    equal(b.ar.elements['drop:p1'][8], '#1')
    equal(b.ar.elements['drop:p2'][8], '#2')
    equal(b.ar.elements['drop:p3'][8], '#3')
  end)

  test('U2-AR a disabled room point is grey with no beam and does not count as BROKEN', function()
    local b = boot()
    assert(b.drops.add({ id = 'room', kind = 'ore', dim = 0, x = 0, y = 64, z = 0, side = 'front', room = true }))
    for _ = 1, 3 do b.drops.note('room') end
    local p = b.drops.list()[1]
    assert(p.disabled and p.broken)
    b.tick(1000)
    equal(b.ar.elements['drop:room'][1], GREY)
    for i = 1, 12 do equal(b.ar.elements['drop:room:box:' .. i][1], GREY) end
    equal(b.ar.elements['drop:room:beam'], nil)
    equal(b.ar.elements['hud:broken:value'], nil)
    -- With room sinks on, the same point is live again: coral, beamed and counted.
    assert(b.drops.roomSink(true))
    b.tick(2000)
    equal(b.ar.elements['drop:room'][1], RED)
    assert(b.ar.elements['drop:room:beam'])
    equal(b.ar.elements['hud:broken:value'][4], '1')
  end)

  test('U2-AR a broken chest with the disk at 85% shows both BROKEN and DISK', function()
    local b = boot()
    b.free = 2400000
    assert(b.drops.add({ id = 'p1', kind = 'ore', dim = 0, x = 0, y = 64, z = 0, side = 'front' }))
    for _ = 1, 3 do b.drops.note('p1') end
    b.tick(1000)
    equal(b.ar.elements['hud:disk:value'][4], '85%')
    equal(b.ar.elements['hud:disk:value'][1], RED)
    equal(b.ar.elements['hud:broken:value'][4], '1')
    -- BROKEN sits on its own row under TURTLES, ALERTS and DISK.
    equal(b.ar.elements['hud:broken:backing'], { 0xE00B111C - 2^32, 4, 101, 68, 129 })
    equal(b.ar.elements['hud:broken:divider'], nil)
    equal(b.ar.elements['hud:disk:backing'][3], 72)
    equal(b.ar.elements['hud:turtles:value'][1], WHITE)
  end)

  test('B13-U an old four-boolean file loads unchanged and migrates only on an enabled edit', function()
    local b = follow(ON, { turtles = true, leases = false, drops = true, alerts = false })
    equal(b.A.dim, OVER)
    equal(b.A.focus, { kind = 'all' })
    equal(b.A.layers, { turtles = true, leases = false, drops = true, alerts = false })
    equal(b.saves, 0)
    equal(b.saved(), { turtles = true, leases = false, drops = true, alerts = false })
    b.tap('drops')
    equal(b.saved(), { v = 2, turtles = true, leases = false, drops = false, alerts = false, focus = { kind = 'all' } })
    -- With the flag off an old file stays four booleans.
    local off = follow({}, { turtles = true, leases = true, drops = true, alerts = true })
    off.tap('leases')
    equal(off.saved(), { turtles = true, leases = false, drops = true, alerts = true })
  end)

  test('B13-U v, dim, focus and stray keys are never layer toggles', function()
    local b = follow({}, { turtles = true, leases = true, drops = true, alerts = true, extra = true })
    for _, id in ipairs({ 'v', 'dim', 'focus', 'extra', 'ar-focus', 'ar-dim:nether', 'ar-all' }) do b.tap(id) end
    equal(b.saves, 0)
    equal(b.saved().extra, true)
    local v2 = follow(ON, { v = 2, turtles = true, leases = true, drops = true, alerts = true, focus = { kind = 'all' } })
    for _, id in ipairs({ 'v', 'dim', 'focus', 'kind' }) do v2.tap(id) end
    equal(v2.saves, 0)
    equal(v2.saved().v, 2)
  end)

  test('B13-U the validator takes v2 records only in the exact shape', function()
    local b = follow({})
    local base = function(extra)
      local v = { v = 2, turtles = true, leases = true, drops = true, alerts = true, focus = { kind = 'all' } }
      for k, x in pairs(extra or {}) do v[k] = x end
      return v
    end
    assert(b.A.valid(base()))
    assert(b.A.valid(base({ dim = NETHER, focus = { kind = 'turtle', id = 2147483647 } })))
    assert(b.A.valid(base({ focus = { kind = 'drop', id = string.rep('a', 128) } })))
    assert(b.A.valid({ turtles = true, leases = true, drops = true, alerts = true, old = 1 }))
    for _, bad in ipairs({
      base({ junk = 1 }), base({ v = 3 }), base({ v = 1 }), base({ focus = false }), base({ dim = 'minecraft:moon' }),
      base({ dim = -1 }), base({ focus = { kind = 'turtle' } }), base({ focus = { kind = 'drop' } }),
      base({ focus = { kind = 'all', id = 3 } }), base({ focus = { kind = 'turtle', id = 3, x = 1 } }),
      base({ focus = { kind = 'turtle', id = 0 } }), base({ focus = { kind = 'turtle', id = 2147483648 } }),
      base({ focus = { kind = 'turtle', id = 1.5 } }), base({ focus = { kind = 'turtle', id = 0 / 0 } }),
      base({ focus = { kind = 'turtle', id = math.huge } }), base({ focus = { kind = 'turtle', id = '3' } }),
      base({ focus = { kind = 'drop', id = string.rep('a', 129) } }), base({ focus = { kind = 'drop', id = 'a b' } }),
      base({ focus = { kind = 'chest', id = 'p1' } }), base({ turtles = 'yes' }),
      { v = 2, turtles = true, leases = true, drops = true, focus = { kind = 'all' } },
    }) do assert(not b.A.valid(bad), H.encode(bad)) end
  end)

  test('B13-U the saved dimension needs both flags; with them off it stays in the file unused', function()
    local saved = { v = 2, turtles = true, leases = true, drops = true, alerts = true, dim = NETHER,
      focus = { kind = 'turtle', id = 3 } }
    for _, case in ipairs({
      { {}, OVER, 'all', false }, { { arFollowups = true }, OVER, 'turtle', false },
      { { remoteDimensions = true }, OVER, 'all', false }, { { arFollowups = true, remoteDimensions = true }, NETHER, 'turtle', true },
      { { arFollowups = true, remoteDimensions = true, arDim = -1, pos = { dim = END } }, NETHER, 'turtle', true },
      { { remoteDimensions = true, arDim = 1, pos = { dim = OVER } }, END, 'all', false },
    }) do
      local b = follow(case[1], saved)
      equal(b.A.dim, case[2])
      equal(b.A.focus.kind, case[3])
      local text = b.text(57, 24)
      equal(text:find('focus ', 1, true) ~= nil, case[1].arFollowups == true)
      equal(text:find('NETHER', 1, true) ~= nil, case[4])
      -- Layer toggles keep the dormant fields.
      b.tap('drops')
      local after = b.saved()
      equal({ after.v, after.dim, after.focus, after.drops }, { 2, NETHER, { kind = 'turtle', id = 3 }, false })
    end
    -- remoteDimensions off: no dimension control.
    local b = follow({ arFollowups = true }, saved)
    b.tap('ar-dim:end')
    equal(b.saves, 0)
  end)

  test('B13-U switching dimension redraws without a restart and resets focus in the same save', function()
    local b = follow(ON, nil, { at = 0 })
    b.machines = { [2] = turtle(OVER), [3] = turtle(NETHER) }
    b.points = { { id = 'o', n = 1, kind = 'ore', dim = OVER, x = 4, y = 64, z = 4 },
      { id = 'n', n = 2, kind = 'ore', dim = NETHER, x = 4, y = 64, z = 4 } }
    b.cells = { ['mine:2'] = { cell(OVER, 1), cell(OVER, 2) }, ['mine:3'] = { cell(NETHER, 1), cell(NETHER, 2) } }
    b.tap('ar-focus')
    b.tap('ar-turtle:2')
    equal(b.saved().focus, { kind = 'turtle', id = 2 })
    b.tick(1000)
    assert(b.ar.elements['turtle:2'] and not b.ar.elements['turtle:3'])
    assert(b.text():find('WORLD', 1, true))
    b.tap('ar-dim:nether')
    local saved = b.saved()
    equal({ saved.dim, saved.focus }, { NETHER, { kind = 'all' } })
    -- The next tick draws the Nether at the same coordinates and deletes the overworld elements.
    b.tick(1001)
    assert(b.ar.elements['turtle:3'] and b.ar.elements['drop:n'] and b.ar.elements['lease:mine:3:1'])
    equal(drawn(b, 'turtle:2'), 0)
    equal(drawn(b, 'drop:o'), 0)
    equal(drawn(b, 'lease:mine:2'), 0)
    -- Restart keeps it.
    b.load()
    equal(b.A.dim, NETHER)
    assert(b.ar.elements['turtle:3'])
    b.tap('ar-dim:world')
    b.tick(1002)
    assert(b.ar.elements['turtle:2'] and not b.ar.elements['turtle:3'])
    b.tap('ar-dim:moon')
    b.tap('ar-dim:')
    equal(b.saves, 3)
  end)

  test('B13-U turtle focus keeps its box, trail and own reservations and every warning', function()
    local b = follow(ON)
    b.machines = { [12] = turtle(OVER, 1), [7] = turtle(OVER, 9), [8] = { role = 'turtle', pose = { dim = NETHER, x = 0, y = 64, z = 0 } } }
    b.cells = { ['mine:12'] = { cell(OVER, 1), cell(OVER, 3) }, ['gps:12'] = { cell(OVER, 20) },
      ['build:12'] = { cell(OVER, 30) }, ['mine:7'] = { cell(OVER, 9), cell(OVER, 11) }, ['gps:7'] = { cell(OVER, 40) },
      ['mine:120'] = { cell(OVER, 50) } }
    b.mine = { dim = OVER, trails = { { id = 12, state = 'done', points = { { x = 1, y = 64, z = 1 }, { x = 1, y = 64, z = 9 } } },
      { id = 7, state = 'done', points = { { x = 9, y = 64, z = 1 }, { x = 9, y = 64, z = 9 } } } },
      preview = { { x = 0, y = 60, z = 0 }, { x = 0, y = 60, z = 9 } } }
    b.points = { { id = 'p1', n = 1, kind = 'ore', dim = OVER, x = 1, y = 64, z = 1 },
      { id = 'p2', n = 2, kind = 'fuel', dim = OVER, x = 6, y = 64, z = 6, broken = true } }
    b.values['mine.alert'] = { text = 'CHEST FULL' }
    b.retirement = { text = 'DUG STORAGE: CONFIRM' }
    b.tick(1000)
    assert(b.ar.elements['turtle:7'] and b.ar.elements['preview:branch'] and b.ar.elements['drop:p1'])
    equal(drawn(b, 'lease:gps:'), 0)
    b.tap('ar-turtle:7777')
    b.tap('ar-turtle:8')
    equal(b.saves, 0)
    b.tap('ar-turtle:12')
    b.tick(1001)
    assert(b.ar.elements['turtle:12'] and b.ar.elements['turtle:12:box:1'] and b.ar.elements['trail:12'])
    assert(b.ar.elements['lease:mine:12:1'] and b.ar.elements['lease:gps:12:1'] and b.ar.elements['lease:build:12:1'])
    for _, gone in ipairs({ 'turtle:7', 'trail:7', 'lease:mine:7', 'lease:gps:7', 'lease:mine:120', 'preview:', 'drop:p1' }) do
      equal(drawn(b, gone), 0)
    end
    -- The broken chest, the HUD totals, the alert and retirement consent stay.
    assert(b.ar.elements['drop:p2'] and b.ar.elements['drop:p2:beam'])
    equal(b.ar.elements['hud:turtles:value'][4], '3')
    equal(b.ar.elements['hud:broken:value'][4], '1')
    equal(b.ar.elements['alert:mine.alert'][4], 'CHEST FULL')
    equal(b.ar.elements['alert:dug-storage'][4], 'DUG STORAGE: CONFIRM')
    assert(b.text():find('[#12]', 1, true))
    -- Layer switches still apply.
    b.tap('leases')
    b.tick(1002)
    equal(drawn(b, 'lease:'), 0)
    assert(b.ar.elements['turtle:12'])
  end)

  test('B13-U drop focus keeps that point; a removed target shows missing and never widens', function()
    local b = follow(ON)
    b.machines = { [12] = turtle(OVER, 1) }
    b.cells = { ['mine:12'] = { cell(OVER, 1), cell(OVER, 3) } }
    b.points = { { id = 'p1', n = 1, kind = 'ore', dim = OVER, x = 1, y = 64, z = 1 },
      { id = 'p3', n = 3, kind = 'fuel', dim = OVER, x = 6, y = 64, z = 6 },
      { id = 'q', n = 4, kind = 'ore', dim = NETHER, x = 6, y = 64, z = 6 } }
    b.tap('ar-drop:q')
    b.tap('ar-drop:nope')
    b.tap('ar-drop:a b')
    equal(b.saves, 0)
    b.tap('ar-drop:p3')
    b.tick(1000)
    assert(b.ar.elements['drop:p3'] and b.ar.elements['drop:p3:box:1'])
    equal(drawn(b, 'drop:p1'), 0)
    equal(drawn(b, 'turtle:'), 0)
    equal(drawn(b, 'lease:'), 0)
    assert(b.text():find('[drop #3]', 1, true))
    -- The point is removed: no target geometry, nothing else returns, the row reads missing.
    b.points = { b.points[1] }
    b.tick(3000)
    equal(drawn(b, 'drop:'), 0)
    equal(drawn(b, 'turtle:'), 0)
    local text, frame = screen(b, 57, 24, b.display)
    local row
    for _, button in ipairs(frame.buttons) do if button.id == 'ar-focus' then row = button.y end end
    assert(text[row]:find('[missing]', 1, true), text[row])
    -- A removed turtle the same way, then ALL widens again.
    b.tap('ar-all')
    b.tap('ar-turtle:12')
    b.machines = {}
    b.tick(5000)
    equal(drawn(b, 'lease:'), 0)
    assert(b.text():find('[missing]', 1, true))
    b.tap('ar-all')
    b.tick(5001)
    assert(b.ar.elements['drop:p1'])
  end)

  test('B13-U a failed save keeps the previous settings and scene', function()
    local b = follow(ON)
    b.machines = { [12] = turtle(OVER, 1), [7] = turtle(OVER, 9) }
    b.tick(1000)
    b.free = 100
    local before = b.files['so-data/ar']
    for _, id in ipairs({ 'ar-turtle:12', 'ar-dim:nether', 'drops' }) do b.tap(id) end
    equal(b.files['so-data/ar'], before)
    equal({ b.A.focus, b.A.dim, b.A.layers.drops }, { { kind = 'all' }, OVER, true })
    b.tick(3000)
    assert(b.ar.elements['turtle:7'] and b.ar.elements['turtle:12'])
    b.free = 13920000
    b.tap('ar-turtle:12')
    equal(b.A.focus, { kind = 'turtle', id = 12 })
  end)

  test('B13-U FOCUS lists targets in pages, marks the current one and BACK leaves it', function()
    local b = follow(ON)
    b.machines = { [40] = turtle(OVER), [3] = turtle(OVER), [12] = turtle(OVER), [7] = turtle(OVER), [9] = turtle(END) }
    for n = 1, 8 do b.points[n] = { id = 'p' .. n, n = n, kind = 'ore', dim = OVER, x = n, y = 64, z = 0 } end
    b.tap('ar-turtle:12')
    b.tap('ar-focus')
    equal(b.saves, 1)
    local text = b.text(15, 10)
    assert(text:find('FOCUS', 1, true) and text:find('1/3', 1, true) and text:find('MORE', 1, true), text)
    assert(not text:find('#9', 1, true))
    b.tap('ar-more')
    assert(b.text(15, 10):find('2/3', 1, true))
    b.tap('ar-back')
    assert(b.text(15, 10):find('LAYERS', 1, true))
    b.tap('ar-focus')
    b.tap('ar-drop:p5')
    equal(b.A.focus, { kind = 'drop', id = 'p5' })
    assert(b.text():find('LAYERS', 1, true))
  end)

  test('B13-U the follow-up screens match their schematic fixtures', function()
    local b = follow(ON)
    -- Literal paths, so part runs declare every fixture they read.
    local paths = { ['ar-FM'] = 'tests/ui/fixtures/ar-FM.txt', ['ar-FS'] = 'tests/ui/fixtures/ar-FS.txt',
      ['ar-FXS'] = 'tests/ui/fixtures/ar-FXS.txt', ['ar-PM'] = 'tests/ui/fixtures/ar-PM.txt',
      ['ar-PXS'] = 'tests/ui/fixtures/ar-PXS.txt', ['ar-PS'] = 'tests/ui/fixtures/ar-PS.txt' }
    local function check(name, w, h, frame)
      local fixture = R.load(paths[name])
      local out = R.capture(w, h)
      for y, row in ipairs(frame.rows) do
        local fg, bg = {}, {}
        for _, run in ipairs(row.runs) do fg[#fg + 1], bg[#bg + 1] = string.rep(run[2], run[1]), string.rep(run[3], run[1]) end
        out.setCursorPos(1, y)
        out.blit(row.text .. string.rep(' ', w - #row.text), table.concat(fg), table.concat(bg))
      end
      local diff = R.diff(fixture, out)
      assert(#diff == 0, name .. '\n' .. table.concat(diff, '\n'))
      for i, x in ipairs(frame.buttons) do
        assert(x.x >= 1 and x.y >= 1 and x.x + x.w - 1 <= w and x.y + x.h - 1 <= h, name .. ' ' .. x.id)
        for j, o in ipairs(frame.buttons) do
          assert(i == j or x.x + x.w <= o.x or o.x + o.w <= x.x or x.y + x.h <= o.y or o.y + o.h <= x.y, name .. ' overlap ' .. x.id)
        end
      end
      assert(#H.encode(frame) < 16384, name .. ' frame size')
    end
    local layers = { turtles = true, leases = true, drops = true, alerts = true }
    check('ar-FM', 57, 24, b.A.layout({ count = 1, layers = layers, follow = { focus = '#12', dims = 'nether' },
      alert = { text = 'ore chest full at -120,64,35', i = 1, n = 2 } }, 57, 24))
    check('ar-FS', 29, 12, b.A.layout({ count = 1, layers = layers, follow = { focus = 'missing', missing = true } }, 29, 12))
    check('ar-FXS', 15, 10, b.A.layout({ count = 1, layers = layers, follow = { focus = 'drop #3', dims = 'world' } }, 15, 10))
    -- The lists come from the real targets.
    b.machines = { [40] = turtle(OVER), [3] = turtle(OVER), [12] = turtle(OVER), [7] = turtle(OVER) }
    for n = 1, 8 do b.points[n] = { id = 'p' .. n, n = n, kind = 'ore', dim = OVER, x = n, y = 64, z = 0 } end
    b.tap('ar-turtle:12')
    b.tap('ar-focus')
    check('ar-PM', 57, 24, b.screens.ar.render(57, 24, b.display))
    b.tap('ar-more')
    check('ar-PXS', 15, 10, b.screens.ar.render(15, 10, b.display))
    b.machines, b.points = {}, {}
    b.tap('ar-back')
    b.tap('ar-all')
    b.tap('ar-focus')
    check('ar-PS', 29, 12, b.screens.ar.render(29, 12, b.display))
    -- The generator reproduces them.
    local started, pipe = pcall(io.popen, 'pwd')
    local root = started and pipe and pipe:read('*l')
    if started and pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= '/' or not os.execute('python3 -V > /dev/null 2>&1') then
      return dofile('tests/skips.lua').record('B13-U schematic generator', 'needs host processes, a POSIX shell and python3')
    end
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "'"))
    local names = { 'ar-FM', 'ar-FS', 'ar-FXS', 'ar-PM', 'ar-PXS', 'ar-PS' }
    assert(os.execute("python3 -I '" .. root .. "/docs/ui/schematic/screens.py' --fixtures '" .. dir .. "' " .. table.concat(names, ' ') .. ' > /dev/null'))
    for _, name in ipairs(names) do
      local a, c = io.open(dir .. '/' .. name .. '.txt', 'rb'), io.open(paths[name], 'rb')
      equal(a:read('*a'), c:read('*a'))
      a:close() c:close()
    end
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)

  test('B13-U FOCUS on one display leaves the other display and the saved settings alone', function()
    local b = follow(ON)
    b.machines = { [12] = turtle(OVER), [7] = turtle(OVER) }
    local a, other = { id = 1 }, { id = 2 }
    local before = b.text(57, 24, other)
    b.tap('ar-focus', a)
    assert(b.text(57, 24, a):find('FOCUS', 1, true))
    equal(b.text(57, 24, other), before)
    b.tap('ar-more', a)
    b.tap('ar-back', other)
    assert(b.text(57, 24, a):find('FOCUS', 1, true))
    equal(b.text(57, 24, other), before)
    equal(b.saves, 0)
    -- A choice on A saves for every display and closes only A's list.
    b.tap('ar-focus', other)
    b.tap('ar-turtle:12', a)
    equal(b.saved().focus, { kind = 'turtle', id = 12 })
    assert(b.text(57, 24, a):find('[#12]', 1, true))
    assert(b.text(57, 24, other):find('FOCUS', 1, true))
    b.tap('ar-back', other)
    assert(b.text(57, 24, other):find('[#12]', 1, true))
  end)
end
