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
  e.SO.mods.drops = b.drops
  b.ar, b.screens, b.tick = ar, screens, e.dofile('so-mod-ar.lua').tick
  return b
end

local function screen(b, w, h)
  local frame = b.screens.ar.render(w, h)
  local out = R.capture(w, h)
  for y, row in ipairs(frame.rows) do
    local fg, bg = {}, {}
    for _, run in ipairs(row.runs) do fg[#fg + 1], bg[#bg + 1] = string.rep(run[2], run[1]), string.rep(run[3], run[1]) end
    out.setCursorPos(1, y)
    out.blit(row.text .. string.rep(' ', w - #row.text), table.concat(fg), table.concat(bg))
  end
  return out.picture().text, frame
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
end
