-- RA2 group other: Build, the health pages and turtle details in route A. Fixtures come from
-- docs/ui/schematic/other.py; the real so-mod-build, so-mod-health and U.turtle draw the same
-- tests/ui/other-scene.txt here and must match them cell by cell.
local R = dofile('tests/ui/render.lua')
local U = dofile('so-ui.lua')

local function read(path)
  local f = assert(io.open(path, 'rb'))
  local text = f:read('*a')
  f:close()
  return text
end

local function scene()
  local s = { build = {}, detail = {}, health = { machines = {}, leases = {}, points = {}, holds = {}, entries = {}, events = {} } }
  for line in read('tests/ui/other-scene.txt'):gmatch('[^\n]+') do
    local p = {}
    for w in line:gmatch('%S+') do p[#p + 1] = w end
    local k, key, n = p[1], p[2], function(i) return tonumber(p[i]) end
    local rest = function(i) return table.concat(p, ' ', i) end
    if k == 'build' then
      local b = s.build
      if key == 'area' then b.area = { x1 = n(3), y1 = n(4), z1 = n(5), x2 = n(6), y2 = n(7), z2 = n(8) }
      elseif key == 'turtle' then b.turtle = { id = n(3), pose = { x = n(4), y = n(5), z = n(6), facing = n(7) } }
      elseif key == 'home' then b.home = { x = n(3), y = n(4), z = n(5), facing = n(6) }
      elseif key == 'cursor' or key == 'fuel' then b[key] = n(3)
      elseif key == 'running' then b.running = true
      else b[key] = rest(3) end
    elseif k == 'detail' then
      local d = s.detail
      if key == 'pose' then d.pose = { x = n(3), y = n(4), z = n(5), facing = n(6) }
      elseif key == 'inv' then d.inv = { { slot = 1, name = 'minecraft:diamond', count = n(3) } }
      else d[key] = n(3) or p[3] end
    elseif k == 'draft' then s.draft = { x = n(2), y = n(3), z = n(4), facing = n(5) }
    elseif k == 'health' then
      local h = s.health
      if key == 'machine' then h.machines[#h.machines + 1] = { id = n(3), role = p[4], seen = n(5) }
      elseif key == 'lease' then h.leases[n(3)] = p[4]
      elseif key == 'point' then h.points[#h.points + 1] = { id = p[3], broken = p[4] == 'broken' }
      elseif key == 'hold' then h.holds[#h.holds + 1] = { role = p[3], id = n(4), text = rest(5) }
      elseif key == 'error' then h.entries[#h.entries + 1] = { at = n(3), text = rest(4) }
      elseif key == 'event' then h.events[#h.events + 1] = { at = n(3), kind = p[4], text = rest(5) }
      else
        h[key] = {}
        for i = 3, #p do h[key][#h[key] + 1] = tonumber(p[i]) end
      end
    end
  end
  return s
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

-- Literal paths, so part runs declare every fixture they read.
local FIXTURE = {
  ['build-26x20'] = 'tests/ui/fixtures/build-26x20.txt', ['build-29x12'] = 'tests/ui/fixtures/build-29x12.txt',
  ['build-57x24'] = 'tests/ui/fixtures/build-57x24.txt', ['buildsetup-26x20'] = 'tests/ui/fixtures/buildsetup-26x20.txt',
  ['buildsetup-29x12'] = 'tests/ui/fixtures/buildsetup-29x12.txt', ['buildsetup-57x24'] = 'tests/ui/fixtures/buildsetup-57x24.txt',
  ['health-26x20'] = 'tests/ui/fixtures/health-26x20.txt', ['health-29x12'] = 'tests/ui/fixtures/health-29x12.txt',
  ['health-57x24'] = 'tests/ui/fixtures/health-57x24.txt', ['attention-26x20'] = 'tests/ui/fixtures/attention-26x20.txt',
  ['attention-29x12'] = 'tests/ui/fixtures/attention-29x12.txt', ['alerts-26x20'] = 'tests/ui/fixtures/alerts-26x20.txt',
  ['alerts-29x12'] = 'tests/ui/fixtures/alerts-29x12.txt', ['events-26x20'] = 'tests/ui/fixtures/events-26x20.txt',
  ['events-29x12'] = 'tests/ui/fixtures/events-29x12.txt', ['events-57x24'] = 'tests/ui/fixtures/events-57x24.txt',
  ['errors-26x20'] = 'tests/ui/fixtures/errors-26x20.txt', ['errors-29x12'] = 'tests/ui/fixtures/errors-29x12.txt',
  ['turtle-P'] = 'tests/ui/fixtures/turtle-P.txt', ['turtle-S'] = 'tests/ui/fixtures/turtle-S.txt',
  ['turtle-M'] = 'tests/ui/fixtures/turtle-M.txt', ['turtlepose-P'] = 'tests/ui/fixtures/turtlepose-P.txt',
  ['turtlepose-S'] = 'tests/ui/fixtures/turtlepose-S.txt' }

local function match(name, frame)
  local fixture = R.load(FIXTURE[name])
  local out = capture(frame, fixture.w, fixture.h)
  local diff = R.diff(fixture, out)
  assert(#diff == 0, name .. '\n' .. table.concat(diff, '\n'))
  contrast(out, name)
  return out
end

local function ids(frame)
  local out = {}
  for _, b in ipairs(frame.buttons) do out[b.id] = b end
  return out
end

local function copy(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

-- The real build module with the scene's saved job.
local function build()
  local b, dim = scene().build, 'minecraft:overworld'
  local pose = copy(b.turtle.pose)
  pose.dim = dim
  local area = copy(b.area)
  area.shape, area.dim = b.shape, dim
  local saved = { dim = dim, cursor = b.cursor, running = b.running == true, phase = 'check', inv = {}, shape = b.shape,
    material = b.material, blueprint = area, turtle = { id = b.turtle.id, pose = pose }, home = b.home, fuel = b.fuel,
    blocked = b.blocked, alert = b.alert }
  local t = { saved = saved, open = 'lease-8' }
  local env = setmetatable({}, { __index = _G })
  env.SO = { now = function() return 0 end, breathe = function() end, mods = {},
    store = { copy = copy, store = function() return { value = copy(saved), save = function(j) t.saved = copy(j) return true end } end } }
  env.SO.mods.state = { emit = function() return true end }
  env.SO.mods.display = { screen = function(_, render, input) t.render, t.input = render, input end }
  env.SO.mods.lease = { status = function() return { open = t.open } end, onReport = function() end }
  t.mod = assert(loadfile('so-mod-build.lua', 't', env))()
  t.mod.tick()
  return t
end

-- The real health module over the scene's facts: machines, leases, the disk, the log, errors and history.
local function health()
  local hs = scene().health
  local t, now = { screens = {} }, hs.now[1]
  local machines, jobs, points = {}, {}, {}
  for _, m in ipairs(hs.machines) do machines[tostring(m.id)] = { role = m.role, seen = m.seen } end
  for _, hold in ipairs(hs.holds) do
    jobs[hold.role] = jobs[hold.role] or { turtles = {} }
    jobs[hold.role].turtles[tostring(hold.id)] = { alert = hold.text }
  end
  for _, p in ipairs(hs.points) do points[#points + 1] = { id = p.id, broken = p.broken } end
  local env = setmetatable({}, { __index = _G })
  env.peripheral = { find = function()
    local out = {}
    for i = 1, hs.modems[1] do out[i] = {} end
    return unpack(out)
  end }
  local function page(q)
    local list = {}
    for i = #hs.events, 1, -1 do
      local e = hs.events[i]
      if (not q.kind or e.kind == q.kind) and (not q.alerts or e.kind:match('%.alert$')) then
        list[#list + 1] = { kind = e.kind, gameAt = e.at, data = e.text ~= '-' and { text = e.text } }
      end
    end
    local first, out = q.before or 1, {}
    for i = first, math.min(#list, first + q.count - 1) do out[#out + 1] = list[i] end
    return { entries = out, next = first + q.count <= #list and first + q.count or nil }
  end
  env.SO = {
    store = { read = function(path)
      local value = path == 'so-data/clock' and { ceiling = hs.clock[1] } or path == 'so-data/mine/job' and jobs.mining
        or path == 'so-data/lumber/job' and jobs.lumber
      return value and { schema = 1, generation = 1, value = value } or nil
    end },
    health = { started = hs.runtime[1], cadence = hs.runtime[2], wallCadence = hs.runtime[3], tickMs = hs.runtime[4] },
    errors = { status = function() return { count = hs.errors[1], bytes = hs.errors[2] } end,
      entries = function() return copy(hs.entries) end },
    mods = {
      state = { get = function(key) if key == 'machines' then return copy(machines) end end,
        view = { get = function() return { data = { ratio = hs.disk[1], free = hs.disk[2] } } end },
        diagnostics = function()
          local l = hs.log
          return { available = true, seq = l[1], segments = l[2], bytes = l[3], snapshot = l[4], snapshotAt = l[5] }
        end,
        history = { page = page, kinds = function()
          local seen, out = {}, {}
          for _, e in ipairs(hs.events) do
            if not seen[e.kind] then seen[e.kind] = true; out[#out + 1] = e.kind end
          end
          table.sort(out)
          return out
        end } },
      lease = { status = function(id) return { open = hs.leases[id] == 'open' or nil } end },
      drops = { list = function() return copy(points) end },
      display = { screen = function(role, render, input) t.screens[role] = { render = render, input = input } end },
    },
  }
  t.mod = assert(loadfile('so-mod-health.lua', 't', env))()
  t.mod.tick(now)
  t.render = function(role, w, h, session) return t.screens[role].render(w, h, session or {}) end
  return t
end

local function detailRow()
  local d = scene().detail
  return { role = d.role, state = d.state, pose = copy(d.pose), fuel = d.fuel, inv = copy(d.inv), lease = d.lease,
    step = d.step, ore = d.ore, seen = d.seen, branch = d.branch, done = d.done, total = d.total }
end

return function(test, equal)
  test('RA2 build job and setup match the schematic fixtures', function()
    local t = build()
    for _, size in ipairs({ { 26, 20 }, { 29, 12 }, { 57, 24 } }) do
      local name = size[1] .. 'x' .. size[2]
      local frame = t.render(size[1], size[2], { buildSetup = false })
      match('build-' .. name, frame)
      local b = ids(frame)
      assert(b['tab:job'] and b['tab:setup'] and b.start and b.stop, name)
      frame = t.render(size[1], size[2], { buildSetup = true })
      match('buildsetup-' .. name, frame)
      b = ids(frame)
      if size[1] >= 36 then assert(b['shape floor'] and b['shape walls'] and b['shape box'], name)
      else assert(b['shape-next'], name) end
    end
  end)

  test('RA2 build tabs and shape chips keep the old ids working', function()
    local t = build()
    local session = {}
    for _, pair in ipairs({ { 'tab:setup', true }, { 'tab:job', false }, { 'setup', true }, { 'build-back', false } }) do
      t.input({ id = pair[1], session = session })
      equal(session.buildSetup, pair[2])
    end
    -- A running job refuses configuration; stopped, the chips set the shape.
    t.open = nil
    t.input({ id = 'shape box', session = session })
    equal(t.saved.shape, 'walls')
    t.input({ id = 'stop', session = session })
    t.input({ id = 'shape box', session = session })
    equal(t.saved.shape, 'box')
    t.input({ id = 'shape-next', session = session })
    equal(t.saved.shape, 'floor')
  end)

  test('RA2 health pages match the schematic fixtures', function()
    local t = health()
    for _, case in ipairs({ { 'health', 26, 20 }, { 'health', 29, 12 }, { 'health', 57, 24 }, { 'attention', 26, 20 },
        { 'attention', 29, 12 }, { 'alerts', 26, 20 }, { 'alerts', 29, 12 }, { 'events', 26, 20 }, { 'events', 29, 12 },
        { 'events', 57, 24 }, { 'errors', 26, 20 }, { 'errors', 29, 12 } }) do
      local frame = t.render(case[1], case[2], case[3])
      local out = match(case[1] .. '-' .. case[2] .. 'x' .. case[3], frame)
      local b = ids(frame)
      for _, id in ipairs({ 'health', 'attention', 'events', 'alerts', 'errors' }) do assert(b[id], id) end
      -- The pager shows only beside a second page.
      local paged = out.picture().text[case[3]]:find(R.char(17), 1, true) ~= nil
      assert((b.prev ~= nil) == paged and (b.next ~= nil) == paged, 'pager ' .. case[1])
    end
  end)

  test('RA2 health rows open their fix, the kind picker sets the kind and pages turn', function()
    local t = health()
    local session, opened = {}, {}
    local frame = t.render('attention', 26, 20, session)
    local row = ids(frame)['item:drop/ore']
    assert(row and row.x == 1 and row.w == 26, 'whole row target')
    t.screens.attention.input({ id = 'item:drop/ore', session = session, open = function(...) opened = { ... } end })
    equal(opened, { 'generic', { 'list', 'select:ore' } })
    t.screens.attention.input({ id = 'events', session = session, open = function(...) opened = { ... } end })
    equal(opened, { 'events' })
    t.render('events', 26, 20, session)
    t.screens.events.input({ id = 'kind', session = session })
    frame = t.render('events', 26, 20, session)
    assert(ids(frame)['pick:2'], 'picker row')
    t.screens.events.input({ id = 'pick:2', session = session })
    frame = t.render('events', 26, 20, session)
    equal(ids(frame).kind.label, 'drops.broken')
    -- Two pages of health at 29x12: the right chip turns to the second, which has the fleet counts.
    local h = {}
    frame = t.render('health', 29, 12, h)
    equal(ids(frame).prev.label, '\17')
    t.screens.health.input({ id = 'next', session = h })
    local out = capture(t.render('health', 29, 12, h), 29, 12)
    local text = table.concat(out.picture().text, '\n')
    assert(text:find('modems', 1, true) and text:find('paired', 1, true) and text:find('2/2', 1, true), text)
  end)

  test('RA2 turtle details and the pose editor match the schematic fixtures', function()
    local s, row = scene(), detailRow()
    for _, case in ipairs({ { 'P', 26, 20 }, { 'S', 29, 12 }, { 'M', 57, 24 } }) do
      local frame = U.turtle.render(case[2], case[3], { id = tostring(s.detail.id) }, detailRow(), s.detail.now)
      match('turtle-' .. case[1], frame)
      local b = ids(frame)
      assert(b['turtle-park'] and b['turtle-remove'] and b['turtle-back'], case[1])
      equal(b['turtle-back'].y, case[3])
    end
    row.uncertain = true
    for _, case in ipairs({ { 'P', 26, 20 }, { 'S', 29, 12 } }) do
      local frame = U.turtle.render(case[2], case[3], { id = tostring(s.detail.id), draft = copy(s.draft) }, row, s.detail.now)
      match('turtlepose-' .. case[1], frame)
      local b = ids(frame)
      for _, axis in ipairs({ 'x', 'y', 'z', 'facing' }) do assert(b['pose:' .. axis .. ':-1'] and b['pose:' .. axis .. ':1'], axis) end
      equal(b['turtle-cancel'].y, case[3])
      assert(b['turtle-save'])
    end
    -- Armed, the destructive chips read CONFIRM in coral.
    local frame = U.turtle.render(26, 20, { id = '2', confirm = 'remove' }, detailRow(), s.detail.now)
    local remove = ids(frame)['turtle-remove']
    equal(remove.label, 'CONFIRM')
    local out = capture(frame, 26, 20)
    equal(out.cells[remove.y][remove.x + 1][2], 'e')
    equal(out.cells[remove.y][remove.x + 1][3], '7')
  end)

  test('RA2 turtle details keep long errors whole and all chips on screen', function()
    local s = scene()
    for _, size in ipairs({ { 26, 20 }, { 29, 12 }, { 57, 24 } }) do
      local row = detailRow()
      row.uncertain, row.error, row.retry = true, 'storage chest missing for ore drop near the shaft', s.detail.now + 4000
      local frame = U.turtle.render(size[1], size[2], { id = '2' }, row, s.detail.now)
      local out = capture(frame, size[1], size[2])
      contrast(out, 'error ' .. size[1])
      local text = table.concat(out.picture().text, '\n')
      assert(text:find('storage chest', 1, true) and text:find('pose ?', 1, true), text)
      local b = ids(frame)
      assert(b['turtle-park'] and b['turtle-remove'] and b['turtle-add'] and b['turtle-back'], 'chips at ' .. size[1])
    end
  end)

  test('RA2 schematic generator reproduces every fixture of the group', function()
    local started, pipe = pcall(io.popen, 'pwd')
    local root = started and pipe and pipe:read('*l')
    if started and pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= '/' or not os.execute('python3 -V > /dev/null 2>&1') then
      return dofile('tests/skips.lua').record('RA2 schematic generator', 'needs host processes, a POSIX shell and python3')
    end
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "'"))
    assert(os.execute("python3 -I '" .. root .. "/docs/ui/schematic/screens.py' --fixtures '" .. dir .. "' > /dev/null"))
    local count = 0
    for name in read(root .. '/docs/ui/schematic/other.py'):gmatch('\n    %("([%w%-]+)", _') do
      equal(read(dir .. '/' .. name .. '.txt'), read(assert(FIXTURE[name], name)))
      count = count + 1
    end
    equal(count, 23)
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)
end
