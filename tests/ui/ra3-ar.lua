-- RA3 the AR goggles screen in route A. Fixtures come from docs/ui/schematic/ar.py; the real
-- so-mod-ar.lua draws the same models here and must match them cell by cell.
local H = dofile('tests/so/harness.lua')
local R = dofile('tests/ui/render.lua')

local function read(path)
  local f = assert(io.open(path, 'rb'))
  local text = f:read('*a')
  f:close()
  return text
end

-- A server with the real AR and display modules; screens.ar is what the display role calls.
local function boot()
  local m = H.new().machine({ id = 1, capacity = 16000000 })
  m.install({ 'so-store.lua', 'so-ui.lua', 'so-mod-ar.lua' })
  local e = m.env
  local screens, saves = {}, 0
  e.SO = { now = function() return 0 end, mods = {}, store = e.dofile('so-store.lua'), proto = { ser = H.encode } }
  local store = e.SO.store.store
  e.SO.store.store = function(...)
    local box = store(...)
    local save = box.save
    box.save = function(v) saves = saves + 1; return save(v) end
    return box
  end
  e.SO.mods.display = { screen = function(role, render, input) screens[role] = { render = render, input = input } end }
  e.peripheral.find = function() end
  local b = { env = e, screens = screens, saves = function() return saves end }
  b.load = function()
    local mod = e.dofile('so-mod-ar.lua')
    mod.tick(0)
    for i = 1, 10 do
      local k, v = debug.getupvalue(screens.ar.render, i)
      if k == 'A' then b.A = v end
    end
    return mod
  end
  b.load()
  return b
end

-- Draws a frame the way display.lua does and checks every row and button stays in bounds.
local function capture(frame, w, h)
  local out = R.capture(w, h)
  assert(#frame.rows == h, 'rows ' .. #frame.rows)
  for y, row in ipairs(frame.rows) do
    local fg, bg = {}, {}
    for _, run in ipairs(row.runs) do fg[#fg + 1], bg[#bg + 1] = string.rep(run[2], run[1]), string.rep(run[3], run[1]) end
    fg, bg = table.concat(fg), table.concat(bg)
    assert(#fg == w and #row.text <= w, 'row ' .. y .. ' width')
    out.setCursorPos(1, y)
    out.blit(row.text .. string.rep(' ', w - #row.text), fg, bg)
  end
  for i, b in ipairs(frame.buttons) do
    assert(b.x >= 1 and b.y >= 1 and b.w > 0 and b.x + b.w - 1 <= w and b.y + (b.h or 1) - 1 <= h, 'button ' .. b.id)
    for j, o in ipairs(frame.buttons) do
      assert(i == j or b.x + b.w <= o.x or o.x + o.w <= b.x or b.y + b.h <= o.y or o.y + o.h <= b.y,
        'buttons ' .. b.id .. ' and ' .. o.id .. ' overlap')
    end
  end
  return out
end

-- Coloured glyphs sit on f or 7; c only draws structure; coloured backgrounds take f.
local STRUCTURE = { ['-'] = true, ['|'] = true, ['+'] = true, ['\183'] = true, ['\166'] = true, [' '] = true }
local DARK = { ['0'] = true, ['3'] = true, ['8'] = true, ['9'] = true, d = true, ['1'] = true, e = true, b = true, a = true, ['2'] = true }
local function contrast(out, name)
  for y, row in ipairs(out.cells) do
    for x, cell in ipairs(row) do
      local ch, fg, bg = cell[1], cell[2], cell[3]
      local ok
      if ch == ' ' then ok = true
      elseif bg == 'f' or bg == '7' then ok = DARK[fg] or fg == 'c' and STRUCTURE[ch]
      elseif bg == 'c' then ok = fg == '0' or fg == '3'
      else ok = fg == 'f' end
      assert(ok, string.format('%s contrast %s on %s at %d,%d (%q)', name, fg, bg, x, y, ch))
    end
  end
end

-- Literal paths, so part runs declare every fixture they read. The models are those of ar.py.
local ORDER = { 'turtles', 'leases', 'drops', 'alerts' }
local FIXTURES = {
  { 'ar-M', 'tests/ui/fixtures/ar-M.txt', 57, 24, 1, { drops = true } },
  { 'ar-W', 'tests/ui/fixtures/ar-W.txt', 100, 38, 2, {} },
  { 'ar-L', 'tests/ui/fixtures/ar-L.txt', 39, 19, 1, { drops = true } },
  { 'ar-P', 'tests/ui/fixtures/ar-P.txt', 26, 20, 1, {} },
  { 'ar-S', 'tests/ui/fixtures/ar-S.txt', 29, 12, 0, { leases = true, alerts = true } },
  { 'ar-XS', 'tests/ui/fixtures/ar-XS.txt', 15, 10, 1, { turtles = true } },
}
local function model(count, off)
  local layers = {}
  for _, layer in ipairs(ORDER) do layers[layer] = not off[layer] end
  return { count = count, layers = layers }
end

local function ids(frame)
  local out = {}
  for _, b in ipairs(frame.buttons) do out[b.id] = b end
  return out
end

return function(test, equal)
  test('RA3 the AR screen matches every schematic fixture cell by cell', function()
    local b = boot()
    for _, f in ipairs(FIXTURES) do
      local name, path, w, h = f[1], f[2], f[3], f[4]
      local fixture = R.load(path)
      equal({ fixture.w, fixture.h }, { w, h })
      local frame = b.A.layout(model(f[5], f[6]), w, h)
      local out = capture(frame, w, h)
      local diff = R.diff(fixture, out)
      assert(#diff == 0, name .. '\n' .. table.concat(diff, '\n'))
      contrast(out, name)
      assert(#H.encode(frame) < 16384, name .. ' frame size')
    end
  end)

  test('RA3 each layer row keeps its id, spans the row and shows its state word in its tone', function()
    local b = boot()
    for _, size in ipairs({ { 57, 24 }, { 100, 38 }, { 39, 19 }, { 26, 20 }, { 26, 19 }, { 29, 12 }, { 36, 10 }, { 15, 10 } }) do
      local w, h = size[1], size[2]
      local frame = b.A.layout(model(1, { leases = true }), w, h)
      local out = capture(frame, w, h)
      contrast(out, w .. 'x' .. h)
      local found = ids(frame)
      equal(#frame.buttons, 4)
      for _, layer in ipairs(ORDER) do
        local row = assert(found[layer], layer .. ' at ' .. w .. 'x' .. h)
        equal({ row.x, row.w, row.h }, { 1, w, 1 })
        local text = out.picture().text[row.y]
        local word = layer == 'leases' and 'off' or 'on'
        assert(text:find(layer, 1, true) and text:find('[' .. word .. ']', 1, true), text)
        -- The word ends one cell before the leader's right end (column 2 + min(w - 2, 55) - 1).
        local x = math.min(w - 2, 55) - #word + 1
        equal(out.cells[row.y][x][1], word:sub(1, 1))
        equal(out.cells[row.y][x][2], word == 'on' and 'd' or '8')
        equal(out.cells[row.y][x - 1][2], '8')
      end
    end
  end)

  test('RA3 a tap toggles its layer once, saves once and survives a reload', function()
    local b = boot()
    local before = b.saves()
    b.screens.ar.input({ id = 'drops' })
    equal(b.saves(), before + 1)
    local out = capture(b.screens.ar.render(26, 20), 26, 20)
    local text = table.concat(out.picture().text, '\n')
    assert(text:find('drops ', 1, true) and text:find('[off]', 1, true), text)
    assert(text:find('3 on', 1, true), text)
    b.screens.ar.input({ id = 'nothing' })
    b.screens.ar.input(nil)
    equal(b.saves(), before + 1)
    b.load()
    local frame = b.screens.ar.render(57, 24)
    local again = capture(frame, 57, 24)
    local row = ids(frame).drops
    assert(again.picture().text[row.y]:find('[off]', 1, true))
    for _, layer in ipairs({ 'turtles', 'leases', 'alerts' }) do
      assert(again.picture().text[ids(frame)[layer].y]:find('[on]', 1, true), layer)
    end
    b.screens.ar.input({ id = 'drops' })
    assert(capture(b.screens.ar.render(57, 24), 57, 24).picture().text[row.y]:find('[on]', 1, true))
  end)

  test('RA3 the header keeps the controller count and draws no filled blocks', function()
    local b = boot()
    local function header(count, w)
      return capture(b.A.layout(model(count, {}), w, 20), w, 20).picture().text[1]
    end
    assert(header(1, 26):find('AR GOGGLES', 1, true) and header(1, 26):find('1 controller', 1, true))
    assert(header(2, 57):find('2 controllers', 1, true))
    assert(header(0, 29):find('0 controllers', 1, true))
    assert(header(3, 15):find('AR GOGGLES  3', 1, true), header(3, 15))
    -- Route A screens keep the page colour: no cell is a coloured or panel block.
    local out = capture(b.A.layout(model(1, {}), 57, 24), 57, 24)
    for _, row in ipairs(out.cells) do for _, cell in ipairs(row) do equal(cell[3], 'f') end end
  end)

  test('RA3 schematic generator reproduces every AR fixture', function()
    local started, pipe = pcall(io.popen, 'pwd')
    local root = started and pipe and pipe:read('*l')
    if started and pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= '/' or not os.execute('python3 -V > /dev/null 2>&1') then
      return dofile('tests/skips.lua').record('RA3 schematic generator', 'needs host processes, a POSIX shell and python3')
    end
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "'"))
    assert(os.execute("python3 -I '" .. root .. "/docs/ui/schematic/screens.py' --fixtures '" .. dir .. "' ar-M ar-W ar-L ar-P ar-S ar-XS > /dev/null"))
    local count = 0
    for name in read(root .. '/docs/ui/schematic/ar.py'):gmatch('\n    %("([%w%-]+)", _ar') do
      local path
      for _, f in ipairs(FIXTURES) do if f[1] == name then path = f[2] end end
      equal(read(dir .. '/' .. name .. '.txt'), read(assert(path, name)))
      count = count + 1
    end
    equal(count, #FIXTURES)
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)
end
