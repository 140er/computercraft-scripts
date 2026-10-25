-- S4: the pocket pages and the system screens in route A, cell by cell against the fixtures
-- docs/ui/schematic/pocket.py and system.py write from the same scene (tests/ui/scene.lua).
local R = dofile('tests/ui/render.lua')
local S = dofile('tests/ui/scene.lua')
local U = dofile('so-ui.lua')

-- Literal paths, so part runs declare every fixture they read.
local FIXTURE = {
  ['pocket-fleet-P'] = 'tests/ui/fixtures/pocket-fleet-P.txt', ['pocket-alerts-P'] = 'tests/ui/fixtures/pocket-alerts-P.txt',
  ['pocket-jobs-P'] = 'tests/ui/fixtures/pocket-jobs-P.txt', ['pocket-shop-P'] = 'tests/ui/fixtures/pocket-shop-P.txt',
  ['pocket-pair-P'] = 'tests/ui/fixtures/pocket-pair-P.txt', ['pocket-code-P'] = 'tests/ui/fixtures/pocket-code-P.txt',
  ['alert-M'] = 'tests/ui/fixtures/alert-M.txt', ['alert-W'] = 'tests/ui/fixtures/alert-W.txt',
  ['alert-T'] = 'tests/ui/fixtures/alert-T.txt', ['alert-P'] = 'tests/ui/fixtures/alert-P.txt',
  ['alert-XS'] = 'tests/ui/fixtures/alert-XS.txt', ['alert-nomap-M'] = 'tests/ui/fixtures/alert-nomap-M.txt',
  ['unassigned-M'] = 'tests/ui/fixtures/unassigned-M.txt', ['unassigned-XS'] = 'tests/ui/fixtures/unassigned-XS.txt',
  ['unloaded-M'] = 'tests/ui/fixtures/unloaded-M.txt', ['outage-M'] = 'tests/ui/fixtures/outage-M.txt',
  ['outage-P'] = 'tests/ui/fixtures/outage-P.txt', ['server-T'] = 'tests/ui/fixtures/server-T.txt',
  ['pairing-T'] = 'tests/ui/fixtures/pairing-T.txt', ['log-T'] = 'tests/ui/fixtures/log-T.txt',
  ['roles-T'] = 'tests/ui/fixtures/roles-T.txt', ['status-M'] = 'tests/ui/fixtures/status-M.txt' }

local function read(path)
  local f = assert(io.open(path, 'rb'))
  local text = f:read('*a')
  f:close()
  return text
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

local function match(name, frame)
  local fixture = R.load(FIXTURE[name])
  local out = S.capture(frame, fixture.w, fixture.h)
  local diff = R.diff(fixture, out)
  assert(#diff == 0, name .. '\n' .. table.concat(diff, '\n'))
  contrast(out, name)
  assert(#frame.rows == fixture.h, name .. ' rows')
  for _, b in ipairs(frame.buttons or {}) do
    assert(b.x >= 1 and b.y >= 1 and b.x + b.w - 1 <= fixture.w and b.y + (b.h or 1) - 1 <= fixture.h, name .. ' button ' .. b.id)
  end
  return out
end

local function find(frame, id)
  for _, b in ipairs(frame.buttons) do if b.id == id then return b end end
end

local function text(frame, w, h) return S.capture(frame, w, h).picture().text end

local POCKET = 10

-- The pocket's frame after one input; a takeover is dismissed first.
local function pocket(opts)
  local s = S.new(opts)
  s.page = function() return s.view(POCKET) end
  return s
end

-- display.lua as a client on a captured monitor, fed one frame.
local function client(w, h)
  local out = R.capture(w, h)
  local state = { now = 0, timers = {}, n = 0 }
  local env = setmetatable({}, { __index = _G })
  env.os = setmetatable({ epoch = function() return state.now end, clock = function() return state.now / 1000 end,
    getComputerID = function() return 2 end, getComputerLabel = function() return 'screen' end,
    startTimer = function(seconds) state.n = state.n + 1; state.timers[state.n] = seconds; return state.n end,
    cancelTimer = function(id) state.timers[id] = nil end, pullEvent = coroutine.yield }, { __index = os })
  out.setTextScale = function() end
  env.term = out
  env.peripheral = { find = function(kind) if kind == 'monitor' then return out end end, getName = function() return 'right' end }
  env.rednet = { lookup = function() return 1 end, send = function() end }
  env.dofile = function(path)
    if path == 'so-pair.lua' then return { open = function() end, key = function() return 'key' end } end
    if path == 'so-store.lua' then return { store = function() return {} end } end
    if path == 'so-proto.lua' then return { build = function() return {} end, encode = function(m) return m end,
      decode = function(m) return m end, macOk = function() return true end,
      since = function() end, fresh = function() return true end } end
    error(path)
  end
  local code = read('display.lua'):gsub('C.loop%(%)%s*$', 'return C')
  return assert(load(code, '@display.lua', 't', env))(), out, state
end

return function(test, equal)
  test('S4 pocket FLEET, JOBS, SHOP and PAIR match their fixtures through the real server path', function()
    local s = pocket({ panel = true, shop = true, facts = true })
    local f = s.page()
    equal(f.role, 'pocket')
    match('pocket-fleet-P', f)
    -- FLEET is status's one column under the tab row.
    local status = R.load('tests/ui/fixtures/status-P.txt')
    local fleet = S.capture(f, 26, 20).picture()
    for y = 2, 20 do equal(fleet.text[y], status.text[y]) end
    for _, tab in ipairs({ { 'tab:fleet', 1, 7 }, { 'tab:jobs', 8, 6 }, { 'tab:shop', 14, 6 }, { 'tab:pair', 20, 6 } }) do
      local b = assert(find(f, tab[1]), tab[1])
      equal({ b.x, b.y, b.w, b.h }, { tab[2], 1, tab[3], 1 })
    end
    local rows = {}
    for _, b in ipairs(f.buttons) do if b.id == 'alerts' then rows[#rows + 1] = b.y .. 'x' .. b.h end end
    equal(rows, { '3x1', '4x1' })
    s.tap(POCKET, 'tab:jobs')
    match('pocket-jobs-P', s.page())
    s.tap(POCKET, 'tab:shop')
    s.type(POCKET, s.sys.search)
    local order = s.sys.order
    s.tap(POCKET, 'order:' .. order[1] .. ':' .. order[2])
    match('pocket-shop-P', s.page())
    s.tap(POCKET, 'tab:pair')
    match('pocket-pair-P', s.page())
    s.tap(POCKET, 'pair-code')
    match('pocket-code-P', s.page())
    equal(s.calls[#s.calls], { 'pair', POCKET })
  end)

  test('S4 pocket ALERTS lists every flag and pages; a takeover still comes first', function()
    local s = pocket({ panel = true, alert = true })
    local first = s.page()
    assert(find(first, 'dismiss'), 'the new alert takes over the pocket first')
    s.tap(POCKET, 'dismiss')
    assert(find(s.page(), 'tab:fleet'), 'a tap dismisses the takeover')
    s.tap(POCKET, 'alerts')
    match('pocket-alerts-P', s.page())
    for i = 1, 9 do s.values['drops' .. i .. '.alert'] = { text = 'fault number ' .. i .. ' needs a look at drop point ' .. i } end
    s.now = s.now + 31000
    s.page()
    s.tap(POCKET, 'dismiss')
    local f = s.page()
    local rows = text(f, 26, 20)
    assert(find(f, 'alert-next') and find(f, 'alert-prev'), 'more flags than fit page')
    local pages = tonumber(rows[20]:match('1/(%d+)'))
    assert(pages and pages > 1, rows[20])
    s.tap(POCKET, 'alert-next')
    assert(text(s.page(), 26, 20)[20]:find('2/' .. pages, 1, true))
    s.tap(POCKET, 'alert-prev'); s.tap(POCKET, 'alert-prev')
    assert(text(s.page(), 26, 20)[20]:find(pages .. '/' .. pages, 1, true), 'paging wraps')
    s.tap(POCKET, 'tab:fleet')
    assert(find(s.page(), 'alerts'))
  end)

  test('S4 pocket JOBS falls back to the status model, then to grey chips without targets', function()
    local s = pocket({ panel = true })
    s.tap(POCKET, 'tab:jobs')
    local got, want = text(s.page(), 26, 20), R.load(FIXTURE['pocket-jobs-P']).text
    for y = 1, 20 do
      if y == 15 then assert(got[y]:find('saplings', 1, true) and got[y]:find('-%s*$'), got[y])
      else equal(got[y], want[y]) end
    end
    s.D.screens.mining, s.D.screens.lumber = nil, nil
    s.panel.tick(0)
    local f = s.page()
    local all = table.concat(text(f, 26, 20), '\n')
    local _, n = all:gsub('not loaded', '')
    equal(n, 2)
    for _, b in ipairs(f.buttons) do assert(not b.id:match(':st'), b.id) end
    s.tap(POCKET, 'mining:start')
    equal(#s.calls, 0)
  end)

  test('S4 pocket: one tap is one action and a long hold reads as its first word', function()
    local s = pocket({ panel = true, shop = true, facts = true })
    s.tap(POCKET, 'mining:start'); equal(#s.calls, 0)
    s.tap(POCKET, 'tab:jobs')
    for _, role in ipairs({ 'mining', 'lumber' }) do
      for _, cmd in ipairs({ 'start', 'stop' }) do
        local n = #s.calls
        s.tap(POCKET, role .. ':' .. cmd)
        equal(#s.calls, n + 1); equal(s.calls[#s.calls], { role, cmd })
      end
    end
    s.env.SO.mods.lumber.facts = function() return { state = 'hold saplings chest; fix drop point and start' } end
    local rows = S.capture(s.page(), 26, 20).picture()
    assert(rows.text[12]:find('LUMBER', 1, true) and rows.text[12]:find(' hold%s*$'), rows.text[12])
    assert(rows.fg[12]:find('1111', 1, true), 'hold is amber')
    s.tap(POCKET, 'order:16:minecraft:iron_ingot'); equal(#s.sends, 0)
    s.tap(POCKET, 'tab:shop'); s.type(POCKET, 'iron')
    for _, amount in ipairs({ 1, 16, 64 }) do
      assert(find(s.page(), 'order:' .. amount .. ':minecraft:iron_ingot'), 'chip names its item')
      local n = #s.sends
      s.tap(POCKET, 'order:' .. amount .. ':minecraft:iron_ingot')
      equal(#s.sends, n + 1)
      local sent = s.sends[#s.sends]
      equal({ sent.id, sent.protocol, sent.body.cmd, sent.body.text, sent.body.n }, { 9, 'roomsorter', 'order', 'minecraft:iron_ingot', amount })
    end
    s.tap(POCKET, 'pick:minecraft:raw_iron')
    local f = s.page()
    equal(find(f, 'order:64:minecraft:raw_iron').y, find(f, 'pick:minecraft:raw_iron').y + 1)
    s.tap(POCKET, 'order:64:minecraft:raw_iron')
    equal(s.sends[#s.sends].body.text, 'minecraft:raw_iron')
    assert(text(s.page(), 26, 20)[19]:find('64 RAW IRON sent', 1, true))
    local n = #s.sends
    s.page(); s.panel.tick(0); s.page()
    equal(#s.sends, n, 'drawing never orders')
    s.tap(POCKET, 'clear')
    assert(find(s.page(), 'pick:minecraft:gold_ingot'), 'clear shows every item')
    s.type(POCKET, 'missing')
    for _, b in ipairs(s.page().buttons) do assert(not b.id:match('^order:')) end
    s.tap(POCKET, 'order:1:minecraft:iron_ingot'); equal(#s.sends, n)
    s.type(POCKET, 'raw'); s.tap(POCKET, 'order:16:minecraft:iron_ingot')
    equal(#s.sends, n, 'a chip for an item outside the search')
    s.shop.order = function() end
    s.type(POCKET, 'iron'); s.tap(POCKET, 'order:1:minecraft:iron_ingot')
    local row = S.capture(s.page(), 26, 20).picture()
    assert(row.text[19]:find('not sent', 1, true) and row.fg[19]:sub(2, 2) == 'e', row.text[19])
    s.tap(POCKET, 'tab:pair'); n = #s.calls
    s.tap(POCKET, 'pair-code'); equal(#s.calls, n + 1)
    s.tap(POCKET, 'tab:jobs'); n = #s.calls
    s.tap(POCKET, 'pair-code'); equal(#s.calls, n)
    equal(s.view(POCKET).role, 'pocket')
    equal(s.saved.roles[tostring(POCKET)], 'pocket')
  end)

  test('S4 every pocket page keeps one-row controls inside 26x20 and 26x19', function()
    for _, h in ipairs({ 20, 19 }) do
      local s = pocket({ panel = true, shop = true, facts = true, alert = true })
      s.d.handlers.hello({ from = POCKET, body = { w = 26, h = h - 1, fullH = h, keyboard = true } })
      s.page(); s.tap(POCKET, 'dismiss')
      for _, page in ipairs({ 'fleet', 'alerts', 'jobs', 'shop', 'pair' }) do
        if page == 'alerts' then s.tap(POCKET, 'tab:fleet'); s.tap(POCKET, 'alerts') else s.tap(POCKET, 'tab:' .. page) end
        if page == 'shop' then s.type(POCKET, 'iron') end
        if page == 'pair' then s.tap(POCKET, 'pair-code') end
        local f = s.page()
        equal(#f.rows, h)
        contrast(S.capture(f, 26, h), page .. ' ' .. h)
        local seen = {}
        for _, b in ipairs(f.buttons) do
          equal(b.h, 1, page .. ' ' .. b.id)
          assert(b.x >= 1 and b.x + b.w - 1 <= 26 and b.y <= h, page .. ' bounds ' .. b.id)
          for x = b.x, b.x + b.w - 1 do
            assert(not seen[b.y .. ',' .. x], page .. ' overlapping ' .. b.id); seen[b.y .. ',' .. x] = true
          end
        end
      end
    end
  end)

  test('S4 the alert takeover matches every size, with the map crop around its subject', function()
    local calls = {}
    local s = S.new({ alert = true, crop = S.cellsFrom(FIXTURE['alert-M'], calls) })
    s.view(7)
    s.now = s.now + 2000
    local room = s.view(7)
    match('alert-M', room)
    equal(calls[#calls], { 5, 5, 49, 15, { x = 184, y = -58, z = -369, id = 6 } })
    equal(find(room, 'dismiss').w, 57)
    for _, size in ipairs({ { 'alert-W', 100, 38 }, { 'alert-T', 51, 19 }, { 'alert-P', 26, 20 }, { 'alert-XS', 15, 10 } }) do
      local crop = S.cellsFrom(FIXTURE[size[1]], calls)
      local t = S.new({ alert = true, crop = crop })
      local session = { alertSeen = {} }
      t.frame(session, size[2], size[3])
      t.now = t.now + 2000
      match(size[1], t.frame(session, size[2], size[3]))
    end
    local bare = S.new({ alert = true })
    bare.view(7); bare.now = bare.now + 2000
    match('alert-nomap-M', bare.view(7))
    -- A crop that fails leaves the area blank; a drop alert crops around its chest.
    local broken = S.new({ alert = true, crop = function() error('map busy') end })
    broken.view(7); broken.now = broken.now + 2000
    match('alert-nomap-M', broken.view(7))
    local drop = S.new({ crop = function(...) calls[#calls + 1] = { ... } end })
    drop.values['drops.alert'] = { kind = 'junk', text = 'drops: hold junk' }
    local f = drop.view(7)
    assert(text(f, 57, 24)[3]:find(' DROPS: HOLD JUNK  123,64,-337', 1, true), text(f, 57, 24)[3])
    equal(calls[#calls][6], { x = 123, y = 64, z = -337, drop = 3 })
  end)

  test('S4 takeover timing is unchanged: 5 s or a tap, once per alert, at most one per 30 s', function()
    local s = S.new({ alert = true })
    assert(find(s.view(7), 'dismiss'))
    s.now = s.now + 4999
    assert(find(s.view(7), 'dismiss'), 'still up at 4.999 s')
    s.now = s.now + 1
    assert(not find(s.view(7), 'dismiss'), 'gone at 5 s')
    s.values['lumber.alert'] = { text = 'saplings chest empty' }
    s.now = s.now + 1000
    assert(not find(s.view(7), 'dismiss'), 'a second alert within 30 s waits')
    s.now = s.now + 30000
    s.values['lumber.alert'] = { text = 'saplings chest still empty' }
    assert(find(s.view(7), 'dismiss'), 'after 30 s a new alert takes over')
    s.tap(7, 'dismiss')
    assert(not find(s.view(7), 'dismiss'), 'a tap dismisses it')
    s.tap(7, 'alerts')
    local opened = s.view(7)
    assert(find(opened, 'alerts-back'), 'tapping the alert rows opens the ALERTS list')
    for _, line in ipairs(text(opened, 57, 24)) do assert(not line:find('|||', 1, true), 'no countdown once opened') end
  end)

  test('S4 unassigned and unloaded displays show the role name and the id in line digits', function()
    local s = S.new()
    for _, size in ipairs({ { 'unassigned-M', 57, 24 }, { 'unassigned-XS', 15, 10 } }) do
      s.d.handlers.hello({ from = 6, body = { w = size[2], h = size[3] - 1, fullH = size[3] } })
      local f = s.view(6)
      equal(f.role, 'unassigned')
      match(size[1], f)
    end
    local f = s.view(9)
    equal(f.role, 'map')
    match('unloaded-M', f)
    for _, size in ipairs({ { 1, 1 }, { 7, 5 }, { 29, 12 }, { 164, 81 } }) do
      s.d.handlers.hello({ from = 6, body = { w = size[1], h = size[2], fullH = size[2] } })
      equal(#s.view(6).rows, size[2])
    end
    s.d.handlers.hello({ from = 123, body = { w = 57, h = 23, fullH = 24 } })
    assert(text(s.view(123), 57, 24)[8]:find('|', 1, true), 'three digits fit')
  end)

  test('S4 no server keeps the picture, swaps to the grey ramp and redraws only its row', function()
    local s = S.new({ panel = true })
    for _, case in ipairs({ { 'outage-M', 7, 57, 24 }, { 'outage-P', POCKET, 26, 20 } }) do
      local c, out, state = client(case[3], case[4])
      local body = s.view(case[2])
      c.onFrame({ body = body })
      local before = out.picture()
      state.now = s.sys.since
      c.markStale()
      c.retryAt = state.now + s.sys.retry
      c.drawStale()
      local fixture = R.load(FIXTURE[case[1]])
      equal(R.diff(fixture, out), {})
      local after = out.picture()
      for y = 2, case[4] do equal(after.text[y], before.text[y]); equal(after.bg[y], before.bg[y]) end
      for i = 0, 15 do equal(out.palette[2 ^ i], { U.stale[i] }) end
      -- The once-a-second repaint touches row 1 alone.
      local rows = {}
      local blit = out.blit
      out.blit = function(...) rows[#rows + 1] = select(2, out.getCursorPos()); return blit(...) end
      state.now = state.now + 1000
      c.drawStale()
      equal(rows, { 1 })
      assert(out.picture().text[1]:find('0:43', 1, true), out.picture().text[1])
      out.blit = blit
      -- A new frame brings the live palette back.
      c.onFrame({ body = body })
      equal(out.palette[2 ^ 2], { U.palette[2] })
      equal(out.picture().text[1], before.text[1])
    end
    local c, out = client(15, 10)
    c.onFrame({ body = { rows = {}, palette = U.palette } })
    c.markStale()
    assert(out.picture().text[1]:find('NO SERVER', 1, true), 'narrow screens keep the words')
  end)

  test('S4 the display client draws every pocket page as its fixture, labels over blanks only', function()
    local s = pocket({ panel = true, shop = true, facts = true })
    local steps = { { 'pocket-fleet-P' }, { 'pocket-jobs-P', 'tab:jobs' }, { 'pocket-shop-P', 'tab:shop', s.sys.search,
      'order:' .. s.sys.order[1] .. ':' .. s.sys.order[2] }, { 'pocket-pair-P', 'tab:pair' }, { 'pocket-code-P', 'pair-code' } }
    for _, step in ipairs(steps) do
      for i = 2, #step do
        if step[i]:find(':') or step[i] == 'pair-code' then s.tap(POCKET, step[i]) else s.type(POCKET, step[i]) end
      end
      local c, out = client(26, 20)
      c.onFrame({ body = s.page() })
      equal(R.diff(R.load(FIXTURE[step[1]]), out), {})
    end
    -- A labelled button over blank cells (the dug-storage choices) still gets its label.
    local c, out = client(26, 20)
    c.onFrame({ body = { rows = { { text = 'retire?', fg = '0', bg = 'f' }, { text = '', fg = '0', bg = 'f' } },
      buttons = { { id = 'dug.allow/1', label = 'allow', x = 1, y = 2, w = 5 } }, palette = U.palette } })
    equal(out.picture().text[2]:sub(1, 5), 'allow')
  end)

  test('S4 a takeover on a display a few cells wide draws and returns', function()
    for _, w in ipairs({ 1, 2, 3, 4, 5, 7 }) do
      local s = S.new({ alert = true })
      local f = s.frame({ alertSeen = {} }, w, 5)
      equal(#f.rows, 5)
      s.D.screens.pocket = nil
    end
    local s = pocket({ panel = true, alert = true })
    s.d.handlers.hello({ from = POCKET, body = { w = 4, h = 20, fullH = 20, keyboard = true } })
    s.view(POCKET); s.tap(POCKET, 'dismiss'); s.tap(POCKET, 'alerts')
    equal(#s.view(POCKET).rows, 20)
  end)

  test('S4 the server terminal matches normal, code, log and role modes', function()
    local s = S.new()
    local log = s.env.SO.terminal.log
    for i = #log, 1, -1 do log[i] = nil end
    for i, line in ipairs(s.sys.log) do log[i] = line end
    local term = R.capture(51, 19)
    s.env.term = term
    local v = s.env.SO.terminal
    s.D.model = s.D.gather()
    s.d.drawTerminal(s.now)
    equal(R.diff(R.load(FIXTURE['server-T']), term), {})
    contrast(term, 'server-T')
    v.mode, v.code, v.expires = 'code', s.sys.code, s.now + 292000
    s.d.drawTerminal(s.now)
    equal(R.diff(R.load(FIXTURE['pairing-T']), term), {})
    v.mode = 'log'
    s.d.drawTerminal(s.now)
    equal(R.diff(R.load(FIXTURE['log-T']), term), {})
    local roles = { { id = 1, size = '57x24', role = 'status' }, { id = 2, size = '26x20', role = 'pocket' },
      { id = 5, size = '57x24', role = 'mining' }, { id = 6, size = '57x24', role = 'unassigned' },
      { id = 7, size = '15x10', role = 'status' }, { id = 9, size = '-', role = 'drops' } }
    local frame = s.d.terminal(s.D.model, { id = 1, uptime = 'up 3h12', mode = 'role', input = '6 shop',
      notice = 'display 7: status', displays = roles }, 51, 19)
    match('roles-T', frame)
    -- A pending code shows on the normal screen; the status displays never show it.
    v.mode, s.pending = 'normal', s.sys.code
    s.d.drawTerminal(s.now)
    assert(term.picture().text[9]:find('482915', 1, true), term.picture().text[9])
    for _, size in ipairs({ { 1, 1 }, { 15, 10 }, { 26, 20 }, { 39, 19 }, { 100, 38 } }) do
      for _, mode in ipairs({ 'normal', 'code', 'log', 'role' }) do
        v.mode = mode
        local f = s.d.terminal(s.D.model, v, size[1], size[2])
        equal(#f.rows, size[2])
      end
    end
  end)

  test('S4 the terminal role prompt still assigns a role', function()
    local s = S.new()
    s.d.handlers.hello({ from = 6, body = { w = 57, h = 23, fullH = 24 } })
    equal(s.view(6).role, 'unassigned')
    local ok, notice = s.d.command('6 status')
    assert(ok, notice)
    equal(notice, 'display 6: status')
    equal(s.view(6).role, 'status')
  end)

  test('S4 frames stay small and display.lua stays far under 1 MB', function()
    local s = pocket({ panel = true, shop = true, facts = true, alert = true })
    for _, id in ipairs({ 7, 8, POCKET }) do
      local bytes = #s.env.SO.proto.ser(s.view(id))
      assert(bytes <= 16384, id .. ' frame ' .. bytes)
    end
    local size = #read('display.lua')
    assert(size < 20000, 'display.lua ' .. size .. ' bytes')
  end)
end
