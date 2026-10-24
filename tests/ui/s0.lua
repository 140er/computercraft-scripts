-- S0: the route A kit, fg fixtures, compact runs, control glyphs and status at every size.
-- Fixtures come from docs/ui/schematic/screens.py; the status data from tests/ui/status-scene.txt
-- and tests/ui/map-scene.txt through the real so-mod-display gather.
local R = dofile('tests/ui/render.lua')
local U = dofile('so-ui.lua')

local function read(path)
  local f = assert(io.open(path, 'rb'))
  local text = f:read('*a')
  f:close()
  return text
end

local function words(path)
  local out = {}
  for line in read(path):gmatch('[^\n]+') do
    local p = {}
    for w in line:gmatch('%S+') do p[#p + 1] = w end
    if #p > 0 then out[#out + 1] = p end
  end
  return out
end

-- Draws a frame the way display.lua does: runs or blit strings, padded to the run width.
local function capture(frame, w, h)
  local out = R.capture(w, h)
  for y, row in ipairs(frame.rows) do
    local fg, bg = {}, {}
    for _, run in ipairs(row.runs or {}) do fg[#fg + 1], bg[#bg + 1] = string.rep(run[2], run[1]), string.rep(run[3], run[1]) end
    fg, bg = table.concat(fg), table.concat(bg)
    if not row.runs then
      fg = #row.fg == 1 and string.rep(row.fg, #row.text) or row.fg
      bg = #row.bg == 1 and string.rep(row.bg, #row.text) or row.bg
    end
    out.setCursorPos(1, y)
    out.blit(row.text .. string.rep(' ', #fg - #row.text), fg, bg)
  end
  return out
end

local function private(fn, key)
  for i = 1, 60 do local name, value = debug.getupvalue(fn, i); if name == key then return value end end
  error('missing upvalue ' .. key)
end

-- Fixture text back to CC bytes, for the map thumbnail stub.
local BYTE = {}
for b = 0, 255 do if b < 128 or b > 159 then BYTE[R.char(b)] = b end end
local function chars(text)
  local out = {}
  for ch in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do out[#out + 1] = ch end
  return out
end

-- A server with the real display module and fake modules fed from the two scene files.
local function scene(opts)
  opts = opts or {}
  local s = { now = 50000000, sends = {}, saved = { roles = {}, far = {}, locked = {} } }
  local status, map = {}, {}
  for _, p in ipairs(words('tests/ui/status-scene.txt')) do
    status[#status + 1] = p
  end
  for _, p in ipairs(words('tests/ui/map-scene.txt')) do map[#map + 1] = p end
  local env = setmetatable({}, { __index = _G })
  local epoch, started = 0, 0
  local machines, mineRows, wood, leases, displays, log = {}, {}, nil, {}, {}, {}
  local mineView, today, disk = {}, nil, nil
  local poses, drops, spots = {}, {}, {}
  for _, p in ipairs(map) do
    if p[1] == 'turtle' then poses[p[2]] = { dim = 'minecraft:overworld', x = tonumber(p[3]), y = tonumber(p[4]), z = tonumber(p[5]), facing = tonumber(p[6]) }
    elseif p[1] == 'drop' or p[1] == 'saplings' then
      local o = p[1] == 'saplings' and 0 or 1
      drops[#drops + 1] = { id = #drops + 1, dim = 0, kind = p[1] == 'saplings' and 'saplings' or p[2],
        x = tonumber(p[2 + o]), y = tonumber(p[3 + o]), z = tonumber(p[4 + o]), side = 'front', broken = p[6] == 'broken' }
    elseif p[1] == 'spot' then spots[#spots + 1] = { x = tonumber(p[2]), z = tonumber(p[3]), ready = p[4] == 'ready' } end
  end
  for _, p in ipairs(status) do
    local k = p[1]
    if k == 'epoch' then epoch = tonumber(p[2])
    elseif k == 'server' then s.id = tonumber(p[2]); started = s.now - tonumber(p[3])
    elseif k == 'disk' then disk = { tonumber(p[2]), tonumber(p[3]) }
    elseif k == 'today' then
      today = { ore = tonumber(p[2]), logs = tonumber(p[3]), oreRecent = tonumber(p[4]), oreByName = {} }
      for i = 5, #p do
        local name, count = p[i]:match('^(%a+):(%d+)$')
        today.oreByName['minecraft:' .. (name == 'redstone' and 'deepslate_redstone' or name) .. '_ore'] = tonumber(count)
      end
    elseif k == 'mining' then mineView = { running = p[2] == 'running', done = tonumber(p[3]), branches = tonumber(p[4]), turtles = mineRows }
    elseif k == 'lumber' then wood = { running = p[2] == 'running', grow = tonumber(p[3]), spots = spots }
    elseif k == 'turtle' then
      local id, job, state = p[2], p[3], p[4]:gsub('_', ' ')
      machines[id] = { id = tonumber(id), role = 'worker', fuel = tonumber(p[5]), seen = s.now - tonumber(p[7]), pose = poses[id] }
      if job == 'mine' then
        mineRows[id] = { pose = poses[id], state = state, dim = 'minecraft:overworld', lane = p[8] == 'lane',
          branch = tonumber(p[8]), ores = tonumber(p[6]) }
      else
        wood.turtle = { id = tonumber(id), pose = poses[id], state = 'lumber', phase = state }
      end
    elseif k == 'lease' then leases[tonumber(p[2])] = p[3]
    elseif k == 'display' then displays[#displays + 1] = { tonumber(p[2]), p[3], p[4] }
    elseif k == 'event' then log[#log + 1] = p[2] .. ' ' .. table.concat(p, ' ', 3) end
  end
  machines['7'] = { id = 7, role = 'display', seen = s.now }
  env.os = setmetatable({ epoch = function() return epoch end, getComputerID = function() return s.id end }, { __index = os })
  env.fs = { getCapacity = function() return disk[1] end, getFreeSpace = function() return disk[2] end }
  env.SO = { now = function() return s.now end, mods = {}, terminal = { log = log, started = started },
    pair = { key = function() return string.rep('01', 32) end },
    store = { store = function() return { value = s.saved, save = function(v) s.saved = v return true end } end,
      copy = function(v) return v end } }
  env.SO.proto = assert(loadfile('so-proto.lua', 't', env))()
  env.rednet = { send = function(id, wire) s.sends[#s.sends + 1] = { id = id, wire = wire } end }
  local mods = env.SO.mods
  mods.state = { view = function() return { values = {} } end, get = function() return machines end }
  mods.lease = { status = function(id) return { open = leases[id] == 'open' and 'l' or nil, lost = leases[id] == 'lost' or nil } end }
  mods.drops = { list = function() return drops end }
  if not opts.bare then
    mods.daily = { today = function() return today end }
    mods.mine = { mapView = function() return mineView end }
    mods.lumber = { mapView = function() return wood end }
  end
  if opts.thumb then mods.map = { thumb = opts.thumb } end
  for _, row in ipairs(displays) do s.saved.roles[tostring(row[1])], s.saved.locked[tostring(row[1])] = row[2], true end
  local d = assert(loadfile('so-mod-display.lua', 't', env))()
  mods.display = d
  local D = private(d.handlers.hello, 'D')
  for _, row in ipairs(displays) do
    local w, h = row[3]:match('(%d+)x(%d+)')
    d.handlers.hello({ from = row[1], body = { w = tonumber(w), h = tonumber(h) - 1, fullH = tonumber(h) } })
    D.sessions[row[1]].sent = s.now
  end
  s.d, s.D, s.env = d, D, env
  -- The full server path: gather, compose, fit and compact, as a display would receive it.
  s.view = function(id)
    local got
    d.handlers['view.get']({ from = id }, function(_, body) got = body end)
    return got
  end
  -- Status at any size for a private session, through the same fit and compact.
  s.status = function(w, h, pocket)
    D.model = D.gather()
    local frame = D.statusFrame({ alertSeen = {} }, w, h, s.now, pocket)
    local fitted = D.fit(frame, w, h)
    fitted.palette = frame.palette
    return fitted
  end
  return s
end

-- Draws the fixture's own cells in the given rectangle: the map module supplies the real thumbnail.
local function thumbFrom(path, calls)
  local fixture = R.load(path)
  return function(C, x, y, w, h)
    calls[#calls + 1] = { x, y, w, h }
    for j = 0, h - 1 do
      local text, fg, bg = chars(fixture.text[y + j]), fixture.fg[y + j], fixture.bg[y + j]
      for i = 0, w - 1 do
        local ch = text[x + i]
        if ch ~= ' ' then C.put(x + i, y + j, string.char(BYTE[ch]), fg:sub(x + i, x + i), bg:sub(x + i, x + i)) end
      end
    end
  end
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

-- Literal paths, so part runs declare every fixture they read.
local FIXTURE = { ['kit-M'] = 'tests/ui/fixtures/kit-M.txt', ['status-M'] = 'tests/ui/fixtures/status-M.txt',
  ['status-W'] = 'tests/ui/fixtures/status-W.txt', ['status-XL'] = 'tests/ui/fixtures/status-XL.txt',
  ['status-T'] = 'tests/ui/fixtures/status-T.txt', ['status-L'] = 'tests/ui/fixtures/status-L.txt',
  ['status-P'] = 'tests/ui/fixtures/status-P.txt', ['status-XS'] = 'tests/ui/fixtures/status-XS.txt',
  ['schematic-map-XL'] = 'tests/ui/fixtures/schematic-map-XL.txt',
  -- S4: the pocket and system screens (tests/ui/s4.lua compares them with the Lua screens).
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
  ['roles-T'] = 'tests/ui/fixtures/roles-T.txt' }

local function match(name, frame)
  local fixture = R.load(FIXTURE[name])
  local out = capture(frame, fixture.w, fixture.h)
  local diff = R.diff(fixture, out)
  assert(#diff == 0, name .. '\n' .. table.concat(diff, '\n'))
  return out
end

local SIZES = { { 'status-T', 51, 19 }, { 'status-L', 39, 19 }, { 'status-P', 26, 20 }, { 'status-XS', 15, 10 } }

return function(test, equal)
  test('S0 kit primitives match the generator cell by cell', function()
    local C = U.canvas(57, 24)
    C.bar('MINING', { 'overview', 'setup' }, 'overview', 'running', 'd')
    C.section(2, 3, 26, 'SECTION', '5')
    C.leader(2, 4, 26, 'ore', '214')
    C.leader(2, 5, 26, 'fuel', '412', '1')
    C.ticks(2, 6, 10, 3)
    equal(C.progress(2, 7, 10, 7, 10), 17)
    C.progress(2, 8, 10, 9, 12, 'd', U.g.spade, '8', U.g.club)
    local x = 2
    for _, kind in ipairs({ 'plain', 'primary', 'stop', 'muted', 'on', 'off' }) do x = C.chip(x, 10, kind, 'chip:' .. kind, kind) + 1 end
    C.chip(2, 12, 'START', 'start', 'primary', 12)
    C.chip(16, 12, 'STOP', 'stop', 'stop', 12)
    C.flag(2, 14, 26, '#6 lost', '184,-58,-369')
    C.box(30, 3, 26, 9, 'e')
    equal(C.digits(32, 5, '4821'), 22)
    C.digits(2, 16, '0123456789', '3', 4, 5, 1)
    C.rule(2, 22, 56)
    local glyphs, colours = { U.g.right, U.g.left, U.g.up, U.g.down, U.g.bullet, U.g.cross, U.g.spade, U.g.club,
      U.g.shaft, U.g.gap, U.g.dot, '@' }, 'd1eb0ed893b9'
    for i, ch in ipairs(glyphs) do C.put(2 + 2 * (i - 1), 23, ch, colours:sub(i, i)) end
    C.put(2, 24, U.arrow(0) .. ' ' .. U.arrow(1) .. ' ' .. U.arrow(5) .. ' ' .. U.age(185000, true), U.tone('wait lane'))
    local frame = C.frame()
    local out = match('kit-M', frame)
    contrast(out, 'kit-M')
    local ids = {}
    for _, b in ipairs(frame.buttons) do ids[#ids + 1] = b.id .. '@' .. b.x .. ',' .. b.y .. 'x' .. b.w end
    equal(ids, { 'tab:overview@10,1x10', 'tab:setup@21,1x7', 'chip:plain@2,10x7', 'chip:primary@10,10x9',
      'chip:stop@20,10x6', 'chip:muted@27,10x7', 'chip:on@35,10x4', 'chip:off@40,10x5', 'start@2,12x12', 'stop@16,12x12' })
  end)

  test('S0 state colours, ages and tick rounding', function()
    for word, tone in pairs({ mining = 'd', unload = 'd', felling = 'd', ['wait lane'] = '1', hold = '1', range = '1',
      ['out of range'] = '1', recovering = '1', lost = 'e', blocked = 'e', ['chest missing'] = 'e', idle = '8',
      stopped = '8', done = '8', ['-'] = '8', [''] = '8', running = 'd' }) do
      equal(U.tone(word), tone)
    end
    equal(U.mark('#2 reported 14 ore'), '8')
    equal(U.mark('#6 lease expired, lane released'), 'e')
    equal(U.mark('#3 waits for the lane'), '1')
    equal({ U.age(59999), U.age(60000), U.age(180000, true), U.age(7200000) }, { 'now', '1m', '3 min', '2h' })
    equal({ U.filled(10, 7, 10), U.filled(10, 9, 12), U.filled(10, 1, 100), U.filled(10, 0, 10), U.filled(10, 5, 0) },
      { 7, 8, 1, 0, 0 })
    equal(U.palette[3], 0x9DB0D2)
    equal(U.palette[15], 0x0B111C)
    equal(U.stale[2], 0xFF6B5E)
  end)

  test('S0 status from the real gather matches every size fixture in text, fg and bg', function()
    local calls = {}
    local s = scene({ thumb = thumbFrom('tests/ui/fixtures/status-W.txt', calls) })
    local room = s.view(7)
    equal(room.role, 'status')
    contrast(match('status-M', room), 'status-M')
    local wall = s.view(8)
    contrast(match('status-W', wall), 'status-W')
    equal(calls[#calls], { 60, 3, 40, 26 })
    for _, size in ipairs(SIZES) do
      contrast(match(size[1], s.status(size[2], size[3])), size[1])
    end
    local xl = scene({ thumb = thumbFrom('tests/ui/fixtures/status-XL.txt', calls) })
    local frame = xl.status(164, 81)
    contrast(match('status-XL', frame), 'status-XL')
    equal(calls[#calls], { 60, 3, 48, 30 })
    for _, f in ipairs({ room, wall, frame }) do
      local bytes = #s.env.SO.proto.ser(f)
      assert(bytes <= 16384, 'frame bytes ' .. bytes)
    end
    print('S0 status-XL frame ' .. #s.env.SO.proto.ser(frame) .. ' bytes')
  end)

  test('S0 status without map, jobs or daily keeps its layout and stays in bounds', function()
    local s = scene({ bare = true })
    local log = s.env.SO.terminal.log
    log[#log + 1] = '21:14:20 Pair code: 482915 server 1'
    for _, size in ipairs({ { 100, 38 }, { 57, 24 }, { 26, 20 } }) do
      for _, line in ipairs(capture(s.status(size[1], size[2]), size[1], size[2]).picture().text) do
        assert(not line:find('482915', 1, true), 'pairing code on status: ' .. line)
      end
    end
    local wall = capture(s.status(100, 38), 100, 38).picture()
    assert(wall.text[3]:find('DISPLAYS', 60, true), 'displays move up without a thumbnail')
    local room = capture(s.status(57, 24), 57, 24).picture()
    assert(room.text[14]:find('mining  -', 1, true), room.text[14])
    assert(room.text[7]:find('ore ', 38, true) and room.text[7]:find('-%s*$'), room.text[7])
    for _, size in ipairs({ { 1, 1 }, { 15, 10 }, { 29, 12 }, { 36, 10 }, { 26, 19 }, { 60, 30 }, { 96, 32 }, { 164, 81 } }) do
      local frame = s.status(size[1], size[2])
      equal(#frame.rows, size[2])
      local out = capture(frame, size[1], size[2])
      contrast(out, size[1] .. 'x' .. size[2])
      for _, b in ipairs(frame.buttons) do assert(b.x + b.w - 1 <= size[1] and b.y <= size[2]) end
    end
    local pocket = capture(scene().status(26, 20, true), 26, 20).picture()
    assert(pocket.text[1]:find('^ FLEET'), pocket.text[1])
  end)

  test('S0 the gather skips route A facts while no display shows status', function()
    local s = scene()
    for _, id in ipairs({ 7, 8, 10 }) do s.D.sessions[id] = nil end
    local views = 0
    s.env.SO.mods.mine.mapView = function() views = views + 1 return {} end
    equal(s.D.gather().turtles, nil)
    equal(views, 0)
    s.d.handlers.hello({ from = 7, body = { w = 57, h = 23, fullH = 24 } })
    assert(#s.D.gather().turtles > 0)
    equal(views, 1)
  end)

  test('S0 crowded walls redraw with fewer rows to stay under the frame limit', function()
    local calls = {}
    local s = scene({ thumb = thumbFrom('tests/ui/fixtures/status-XL.txt', calls) })
    local machines = s.env.SO.mods.state.get()
    for id = 20, 39 do
      machines[tostring(id)] = { id = id, role = 'worker', fuel = 300 + id, seen = s.now - id * 1000,
        pose = { x = 100 + id, y = -58, z = -300 - id, facing = id % 4 } }
    end
    local log = s.env.SO.terminal.log
    for i = 1, 30 do log[#log + 1] = string.format('21:15:%02d #%d waits for the lane after a long route home', i, i) end
    for _, size in ipairs({ { 164, 81 }, { 100, 38 }, { 120, 50 } }) do
      local frame = s.status(size[1], size[2])
      local bytes = #s.env.SO.proto.ser(frame)
      assert(bytes <= s.D.budget, size[1] .. 'x' .. size[2] .. ' frame bytes ' .. bytes)
      local text = capture(frame, size[1], size[2]).picture().text
      local more = false
      for _, line in ipairs(text) do if line:find('more', 1, true) then more = true end end
      assert(more, 'hidden turtles are counted')
    end
    -- This crowd passes the budget at 164x81, so the wall redrew tight: five turtle rows, not eight.
    local function count(budget)
      s.D.budget = budget
      for _, line in ipairs(capture(s.status(164, 81), 164, 81).picture().text) do
        local n = line:match('^%s+%+(%d+) more')
        if n then return tonumber(n) end
      end
    end
    equal({ count(30000), count(15000) }, { 18, 21 })
  end)

  test('S0 compact runs let blanks reuse the previous fg and draw the same cells', function()
    local s = scene()
    local blanks = string.rep(' ', 60)
    local row = { text = 'ab' .. blanks .. 'cd' .. blanks, bg = string.rep('f', 64) .. string.rep('7', 60),
      fg = '01' .. ('23456789'):rep(8):sub(1, 60) .. '45' .. ('6789'):rep(15) }
    local compact = s.D.compact(row)
    equal(compact.text, 'ab' .. blanks .. 'cd')
    equal(compact.runs, { { 1, '0', 'f' }, { 61, '1', 'f' }, { 1, '4', 'f' }, { 1, '5', 'f' }, { 60, '6', '7' } })
    local a, b = capture({ rows = { row } }, 124, 1), capture({ rows = { compact } }, 124, 1)
    equal(R.diff({ w = 124, h = 1, text = a.picture().text, fg = a.picture().fg, bg = a.picture().bg }, b), {})
    -- The route A map at 164x81 from the generator, sent as a generic screen.
    local fixture = R.load('tests/ui/fixtures/schematic-map-XL.txt')
    local rows = {}
    for y = 1, fixture.h do
      local text = {}
      for i, ch in ipairs(chars(fixture.text[y])) do text[i] = string.char(BYTE[ch]) end
      rows[y] = { text = table.concat(text), fg = fixture.fg[y], bg = fixture.bg[y] }
    end
    s.d.screen('generic', function() return { rows = rows, palette = U.palette } end)
    s.d.handlers.hello({ from = 2, body = { w = 164, h = 80, fullH = 81 } })
    assert(s.d.assign(2, 'drops'))
    local body = s.view(2)
    local bytes = #s.env.SO.proto.ser(body)
    assert(bytes <= 16384, 'map frame bytes ' .. bytes)
    equal(R.diff(fixture, capture(body, 164, 81)), {})
    -- The same rows when every fg change starts a run, as before route A.
    local old = 0
    for _, r in ipairs(rows) do
      local runs = {}
      for x = 1, #r.text do
        local last = runs[#runs]
        if last and last[2] == r.fg:sub(x, x) and last[3] == r.bg:sub(x, x) then last[1] = last[1] + 1
        else runs[#runs + 1] = { 1, r.fg:sub(x, x), r.bg:sub(x, x) } end
      end
      local compact = { text = r.text:gsub(' +$', ''), runs = runs }
      old = old + math.min(#s.env.SO.proto.ser(compact), #s.env.SO.proto.ser(r))
    end
    assert(bytes < old, 'blank reuse saves bytes')
    print('S0 164x81 route A map frame ' .. bytes .. ' bytes (rows ' .. old .. ' bytes without blank reuse)')
  end)

  test('S0 control glyphs 16-31 survive serialisation, compact rows and the client blit', function()
    local s = scene()
    local proto = s.env.SO.proto
    local text = ''
    for b = 1, 31 do if b ~= 10 and b ~= 13 then text = text .. string.char(b) end end
    text = text .. U.g.dot .. U.g.cross .. U.g.shaft .. U.g.gap .. '\127'
    local row = s.D.compact({ text = text, fg = string.rep('d', #text), bg = 'f' })
    equal(row.text, text)
    local body = { rows = { row }, buttons = {} }
    equal(assert(load('return ' .. proto.ser(body)))(), body)
    local key = string.rep('01', 32)
    local msg = proto.build(key, 'view.frame', body)
    assert(proto.macOk(key, msg), 'mac over control glyphs')
    local wire = assert(proto.encode(msg))
    local back = assert(proto.decode(wire))
    equal(back.body.rows[1].text, text)
    -- display.lua draws the row through blit unchanged.
    local out = R.capture(#text, 1)
    local env = setmetatable({ term = out, peripheral = { find = function() end } }, { __index = _G })
    env.os = setmetatable({ epoch = function() return 0 end, clock = function() return 0 end, getComputerID = function() return 2 end,
      getComputerLabel = function() return 'screen' end, startTimer = function() return 1 end, cancelTimer = function() end }, { __index = os })
    env.rednet = { lookup = function() return 1 end, send = function() end }
    env.dofile = function(path)
      if path == 'so-pair.lua' then return { open = function() end, key = function() return 'key' end } end
      if path == 'so-store.lua' then return { store = function() return {} end } end
      if path == 'so-proto.lua' then return { build = function() return {} end, encode = function(m) return m end,
        decode = function(m) return m end, macOk = function() return true end } end
      error(path)
    end
    local code = read('display.lua'):gsub('C.loop%(%)%s*$', 'return C')
    local client = assert(load(code, '@display.lua', 't', env))()
    client.onFrame({ body = back.body })
    for x = 1, #text do equal(out.cells[1][x][1], text:sub(x, x)) end
    for i, ch in ipairs(chars(out.picture().text[1])) do
      if text:byte(i) == 16 then equal(ch, '►') elseif text:byte(i) == 31 then equal(ch, '▼') end
    end
  end)

  test('S0 fixtures load with and without the fg layer', function()
    local old = R.load('tests/ui/fixtures/ar-M.txt')
    assert(old.fg == nil and #old.bg == old.h)
    local new = R.load('tests/ui/fixtures/status-M.txt')
    equal(#new.fg, new.h)
    local out = R.capture(3, 1)
    out.setCursorPos(1, 1); out.blit('a b', '0e1', 'fff')
    local diff = R.diff({ w = 3, h = 1, text = { 'a b' }, fg = { '0d0' }, bg = { 'fff' } }, out)
    equal(#diff, 1)
    assert(diff[1]:find('layer fg', 1, true), diff[1])
    equal(R.diff({ w = 3, h = 1, text = { 'a b' }, bg = { 'fff' } }, out), {})
  end)

  test('S0 schematic generator reproduces every fixture and renders with the CC font', function()
    local started, pipe = pcall(io.popen, 'pwd')
    local root = started and pipe and pipe:read('*l')
    if started and pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= '/' or not os.execute('python3 -V > /dev/null 2>&1') then
      return dofile('tests/skips.lua').record('S0 schematic generator', 'needs host processes, a POSIX shell and python3')
    end
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "'"))
    local gen = "python3 -I '" .. root .. "/docs/ui/schematic/screens.py'"
    assert(os.execute(gen .. " --fixtures '" .. dir .. "/fixtures' > /dev/null"))
    local count = 0
    for name in read(root .. '/docs/ui/schematic/screens.py'):gmatch('\n    %("([%w%-]+)", ') do
      equal(read(dir .. '/fixtures/' .. name .. '.txt'), read(assert(FIXTURE[name], name)))
      count = count + 1
    end
    assert(count >= 8, 'fixture names ' .. count)
    if os.execute(gen .. " --png '" .. dir .. "/png' kit-M > /dev/null 2>&1") then
      equal(read(dir .. '/png/kit-M.png'):sub(1, 8), '\137PNG\r\n\26\n')
    else
      dofile('tests/skips.lua').record('S0 schematic PNG render', 'font not found, PNG renders skipped (needs a local CC:Tweaked jar)')
    end
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)
end
