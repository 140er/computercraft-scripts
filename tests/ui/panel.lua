-- RA2 panel: the panel role and the pocket's PAIRED and ENROLL pages in route A, cell by cell against
-- the fixtures docs/ui/schematic/panel.py writes from the same scene files (tests/ui/scene.lua,
-- tests/ui/panel-scene.txt).
local R = dofile('tests/ui/render.lua')
local S = dofile('tests/ui/scene.lua')

-- Literal paths, so part runs declare every fixture they read.
local FIXTURE = {
  ['panel-M'] = 'tests/ui/fixtures/panel-M.txt', ['panel-W'] = 'tests/ui/fixtures/panel-W.txt',
  ['panel-L'] = 'tests/ui/fixtures/panel-L.txt', ['panel-S'] = 'tests/ui/fixtures/panel-S.txt',
  ['panel-XS'] = 'tests/ui/fixtures/panel-XS.txt', ['panel-P'] = 'tests/ui/fixtures/panel-P.txt',
  ['panelalerts-M'] = 'tests/ui/fixtures/panelalerts-M.txt',
  ['panelpair-P'] = 'tests/ui/fixtures/panelpair-P.txt', ['panelcode-P'] = 'tests/ui/fixtures/panelcode-P.txt',
  ['panelpair-S'] = 'tests/ui/fixtures/panelpair-S.txt', ['panelcode-S'] = 'tests/ui/fixtures/panelcode-S.txt',
  ['panelcode-M'] = 'tests/ui/fixtures/panelcode-M.txt',
  ['paired-P'] = 'tests/ui/fixtures/paired-P.txt', ['paired-S'] = 'tests/ui/fixtures/paired-S.txt',
  ['paired-M'] = 'tests/ui/fixtures/paired-M.txt',
  ['enroll-P'] = 'tests/ui/fixtures/enroll-P.txt', ['enroll-S'] = 'tests/ui/fixtures/enroll-S.txt',
  ['enroll-M'] = 'tests/ui/fixtures/enroll-M.txt' }

local function read(path)
  local f = assert(io.open(path, 'rb'))
  local text = f:read('*a')
  f:close()
  return text
end

-- tests/ui/panel-scene.txt, as docs/ui/schematic/panel.py reads it.
local function scene()
  local sc = { paired = {}, pending = {} }
  for line in read('tests/ui/panel-scene.txt'):gmatch('[^\n]+') do
    local p = {}
    for w in line:gmatch('%S+') do p[#p + 1] = w end
    if p[1] == 'needs' then sc.needs = tonumber(p[2])
    elseif p[1] == 'paired' then sc.paired[#sc.paired + 1] = { id = tonumber(p[2]), kind = p[3] ~= '-' and p[3] or nil, seen = tonumber(p[4]) }
    elseif p[1] == 'self' then sc.self = tonumber(p[2])
    elseif p[1] == 'confirm' then sc.confirm = tonumber(p[2])
    elseif p[1] == 'enroll' then sc.enroll = { token = p[2], left = tonumber(p[3]), joined = tonumber(p[4]), cap = tonumber(p[5]) }
    elseif p[1] == 'pending' then sc.pending[#sc.pending + 1] = { id = tonumber(p[2]), kind = p[3], fp = p[4], n = tonumber(p[5]) } end
  end
  return sc
end

-- Route A: coloured glyphs on f or 7, c only for structure, and no filled colour anywhere.
local STRUCTURE = { ['-'] = true, ['|'] = true, ['+'] = true, ['\183'] = true, [' '] = true }
local DARK = { ['0'] = true, ['3'] = true, ['8'] = true, ['9'] = true, d = true, ['1'] = true, e = true, b = true, a = true }
local function routeA(out, name)
  for y, row in ipairs(out.cells) do
    for x, cell in ipairs(row) do
      local ch, fg, bg = cell[1], cell[2], cell[3]
      assert(bg == 'f' or bg == '7', string.format('%s fill %s at %d,%d', name, bg, x, y))
      assert(ch == ' ' or DARK[fg] or fg == 'c' and STRUCTURE[ch],
        string.format('%s contrast %s on %s at %d,%d (%q)', name, fg, bg, x, y, ch))
    end
  end
end

local function match(name, frame)
  local fixture = R.load(FIXTURE[name])
  local out = S.capture(frame, fixture.w, fixture.h)
  local diff = R.diff(fixture, out)
  assert(#diff == 0, name .. '\n' .. table.concat(diff, '\n'))
  routeA(out, name)
  assert(#frame.rows == fixture.h, name .. ' rows')
  for _, b in ipairs(frame.buttons or {}) do
    assert(b.h == 1, name .. ' one-row control ' .. b.id)
    assert(b.x >= 1 and b.y >= 1 and b.x + b.w - 1 <= fixture.w and b.y <= fixture.h, name .. ' button ' .. b.id)
  end
  return out
end

local function find(frame, id)
  for _, b in ipairs(frame.buttons) do if b.id == id or b.id:sub(1, #id + 1) == id .. ':' then return b end end
end

-- A monitor (or the scene's pocket) given the panel role through the real server path.
local function panel(s, id, w, h, keyboard)
  if w then s.d.handlers.hello({ from = id, body = { w = w, h = h, keyboard = keyboard } }) end
  assert(s.d.assign(id, 'panel'))
  return function() return s.view(id) end
end

-- The panel module alone, for the paired keys and the enroll window: P.render and P.pocket as
-- so-mod-display calls them, on a server that knows the scene's keys.
local function bare(sc, machines)
  local env = setmetatable({}, { __index = _G })
  local now = 50000000
  env.os = setmetatable({ epoch = function() return 0 end }, { __index = os })
  local known = {}
  for _, row in ipairs(sc.paired) do
    if machines then known[tostring(row.id)] = { role = row.kind, seen = row.seen and now - row.seen } end
  end
  local proto = assert(loadfile('so-proto.lua', 't', env))()
  local screens = {}
  env.SO = { now = function() return now end, proto = proto,
    mods = { state = { get = function(key) if key == 'machines' then return known end end },
      display = { screen = function(role, render, input) if render then screens[role] = { render = render, input = input } end end } },
    pair = { key = function() return 'key' end, pending = function() end,
      list = function()
        local out = {}
        for _, row in ipairs(sc.paired) do
          out[#out + 1] = { id = row.id, fingerprint = proto.hex(proto.sha256(string.rep(string.format('%02x', row.id), 32))):sub(1, 4):upper() }
        end
        return out
      end },
    pairCode = function() end,
    enroll = { view = function(owner)
      local e = sc.enroll
      return { owner = sc.self, left = e.left, joined = e.joined, cap = e.cap, rows = sc.pending, token = owner == sc.self and e.token or nil }
    end, open = function() return true end, close = function() end, decide = function() return true end } }
  local p = assert(loadfile('so-mod-panel.lua', 't', env))()
  p.tick(0)
  local function session(page, w)
    return { id = sc.self, isDisplay = true, w = w, pocket = { page = 'panel' }, panel = { page = page, search = '' } }
  end
  return screens, session, env
end

return function(test, equal)
  test('RA2 panel main page matches its fixtures at every size through the real server path', function()
    local sc = scene()
    local s = S.new({ panel = true, shop = true, facts = true })
    s.env.SO.mods.health = { count = function() return sc.needs end }
    for _, size in ipairs({ { 'panel-M', 21, 57, 24 }, { 'panel-W', 22, 100, 38 }, { 'panel-L', 23, 39, 19 },
        { 'panel-S', 24, 29, 12 }, { 'panel-XS', 25, 15, 10 } }) do
      local f = panel(s, size[2], size[3], size[4], false)()
      equal(f.role, 'panel')
      match(size[1], f)
      for _, id in ipairs({ 'mining:start', 'mining:stop', 'lumber:start', 'lumber:stop', 'alerts', 'pair' }) do
        assert(find(f, id), size[1] .. ' ' .. id)
      end
      assert(not find(f, 'order') and not find(f, 'search'), 'monitor panels have no quick order')
    end
    -- The panel role on the scene's pocket keeps its keyboard: the quick order joins the jobs.
    s.env.SO.mods.health = nil
    local view = panel(s, 10)
    s.type(10, s.sys.search)
    match('panel-P', view())
    for _, amount in ipairs({ 1, 16, 64 }) do assert(find(view(), 'order:' .. amount)) end
  end)

  test('RA2 panel START, STOP, HEALTH and NEEDS act once per tap from the drawn frame', function()
    local s = S.new({ panel = true, facts = true })
    local opened = {}
    s.env.SO.mods.health = { count = function() return 2 end }
    local view = panel(s, 21, 57, 24, false)
    local f = view()
    equal({ find(f, 'health').y, find(f, 'attention').y }, { 1, 1 })
    for _, role in ipairs({ 'mining', 'lumber' }) do
      for _, cmd in ipairs({ 'start', 'stop' }) do
        local n = #s.calls
        s.tap(21, role .. ':' .. cmd)
        equal(#s.calls, n + 1); equal(s.calls[#s.calls], { role, cmd })
      end
    end
    local D = s.D
    D.open = function(_, _, name) opened[#opened + 1] = name end
    s.tap(21, 'attention'); s.tap(21, 'health')
    equal(opened, { 'attention', 'health' })
  end)

  test('RA2 panel ALERTS and PAIR match their fixtures; BACK returns to the jobs', function()
    local s = S.new({ panel = true, alert = true })
    local view = panel(s, 21, 57, 24, false)
    s.tap(21, 'alerts')
    match('panelalerts-M', view())
    s.tap(21, 'panel-back')
    assert(find(view(), 'mining:start'))
    for _, size in ipairs({ { 'P', 26, 20, 31 }, { 'S', 29, 12, 32 } }) do
      local v = panel(s, size[4], size[2], size[3], false)
      s.tap(size[4], 'pair')
      match('panelpair-' .. size[1], v())
      s.tap(size[4], 'pair-code')
      match('panelcode-' .. size[1], v())
      equal(s.calls[#s.calls], { 'pair', size[4] })
    end
    s.env.SO.enroll = { view = function() end }
    local v = panel(s, 33, 57, 24, false)
    s.tap(33, 'pair'); s.tap(33, 'pair-code')
    match('panelcode-M', v())
    s.tap(33, 'panel-back')
    assert(find(v(), 'mining:start'))
  end)

  test('RA2 PAIRED and ENROLL match their fixtures on the panel and under the pocket tabs', function()
    local sc = scene()
    for _, case in ipairs({ { 'paired-P', 'paired', 26, 20, true }, { 'paired-S', 'paired', 29, 12 },
        { 'paired-M', 'paired', 57, 24, false, true }, { 'enroll-P', 'enroll', 26, 20, true },
        { 'enroll-S', 'enroll', 29, 12 }, { 'enroll-M', 'enroll', 57, 24 } }) do
      local name, page, w, h, pocket, machines = case[1], case[2], case[3], case[4], case[5], case[6]
      local screens, session, env = bare(sc, machines or page == 'enroll')
      local s = session(page, w)
      if name == 'paired-M' then s.panel.confirm = { id = sc.confirm, token = '1', expires = env.SO.now() + 15000, key = 'key' } end
      local f = pocket and screens.pocket.render(w, h, s) or screens.panel.render(w, h, s)
      match(name, f)
      if page == 'paired' then
        assert(not find(f, 'forget:' .. sc.self), 'no FORGET for the display itself')
        assert(find(f, 'paired-back'))
      else
        for _, row in ipairs(sc.pending) do
          if find(f, 'enroll-ok:' .. row.id) then assert(find(f, 'enroll-all').id:find(row.id .. '-' .. row.n, 1, true)) end
        end
        assert(find(f, 'enroll-close'))
      end
    end
  end)

  test('RA2 panel pages keep route A and one-row controls at every size', function()
    local s = S.new({ panel = true, shop = true, facts = true, alert = true })
    local health = { count = function() return 12 end }
    for i, size in ipairs({ { 15, 10 }, { 26, 20 }, { 29, 12 }, { 39, 19 }, { 51, 19 }, { 57, 24 }, { 100, 38 }, { 164, 81 } }) do
      local id = 40 + i
      local view = panel(s, id, size[1], size[2], false)
      -- The main page with HEALTH and NEEDS; without the health module ALERTS is the panel's own page.
      for _, page in ipairs({ 'main', 'alerts', 'pair' }) do
        s.env.SO.mods.health = page == 'main' and health or nil
        if page ~= 'main' then s.tap(id, page); assert(find(view(), 'panel-back'), page .. ' did not open') end
        local f = view()
        local out = S.capture(f, size[1], size[2])
        routeA(out, page .. ' ' .. size[1] .. 'x' .. size[2])
        local seen = {}
        for _, b in ipairs(f.buttons) do
          equal(b.h, 1, page .. ' ' .. b.id)
          assert(b.x >= 1 and b.x + b.w - 1 <= size[1] and b.y <= size[2], page .. ' bounds ' .. b.id)
          for x = b.x, b.x + b.w - 1 do
            assert(not seen[b.y .. ',' .. x], page .. ' overlapping ' .. b.id .. ' at ' .. size[1] .. 'x' .. size[2])
            seen[b.y .. ',' .. x] = true
          end
        end
        -- No label is cut inside a word.
        local text = table.concat(out.picture().text, '\n')
        for _, word in ipairs({ 'MINI', 'LUMB', 'STAR', 'ALER', 'PAIR', 'BACK', 'HEAL', 'NEED' }) do
          for hit in text:gmatch(word .. '%a*') do
            assert(({ MINING = 1, LUMBER = 1, START = 1, ALERTS = 1, PAIR = 1, PAIRED = 1, BACK = 1, HEALTH = 1, NEEDS = 1 })[hit],
              'cut label ' .. hit .. ' at ' .. size[1] .. 'x' .. size[2])
          end
        end
        if page ~= 'main' then s.tap(id, 'panel-back') end
      end
    end
  end)
end
