-- S3: mining, lumber and drop points in route A. Fixtures come from docs/ui/schematic/jobs.py; the
-- jobs here are built from tests/ui/map-scene.txt, status-scene.txt and jobs-scene.txt and drawn by
-- the real modules.
local R = dofile('tests/ui/render.lua')

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

-- Every line of the three scene files by its first word.
local function scene()
  local s = { turtles = {}, poses = {}, drops = {}, spots = {}, leases = {}, branch = {} }
  for _, file in ipairs({ 'tests/ui/map-scene.txt', 'tests/ui/status-scene.txt', 'tests/ui/jobs-scene.txt' }) do
    for _, p in ipairs(words(file)) do
      local k, n = p[1], function(i) return tonumber(p[i]) end
      if k == 'mine' then s.mine = { x = n(2), y = n(3), z = n(4), facing = n(5), bottom = n(6), length = n(7), mode = p[8] }
      elseif k == 'server' and #p == 4 then s.server = { x = n(2), y = n(3), z = n(4) }
      elseif k == 'turtle' and file:find('map') then s.poses[p[2]] = { x = n(3), y = n(4), z = n(5), facing = n(6) }
      elseif k == 'turtle' then
        s.turtles[#s.turtles + 1] = { id = n(2), job = p[3], state = (p[4]:gsub('_', ' ')), fuel = n(5), ore = n(6), at = p[8] }
      elseif k == 'drop' then s.drops[#s.drops + 1] = { kind = p[2], x = n(3), y = n(4), z = n(5), broken = p[6] == 'broken' }
      elseif k == 'saplings' and #p == 4 then s.chest = { x = n(2), y = n(3), z = n(4), side = 'front' }
      elseif k == 'saplings' then s.saplings = n(2)
      elseif k == 'farm' then s.area = { x1 = n(2), z1 = n(3), x2 = n(4), z2 = n(5) } s.ground = n(6)
      elseif k == 'spot' then s.spots[#s.spots + 1] = { x = n(2), z = n(3), ready = p[4] == 'ready' }
      elseif k == 'mining' then s.mining = { running = p[2] == 'running', done = n(3), total = n(4) }
      elseif k == 'lumber' then s.lumber = { running = p[2] == 'running', grow = n(3) }
      elseif k == 'today' then s.today = { ore = n(2), logs = n(3) }
      elseif k == 'lease' then s.leases[n(2)] = p[3]
      elseif k == 'branch' then s.branch[n(2)] = n(3)
      elseif k == 'emptymine' then s.emptymine = { running = p[2] == 'running', state = p[3] }
      elseif k == 'fuelpolicy' then s.policy = { auto = p[2] == 'on', output = { id = p[3] } }
      elseif k == 'verified' then s.verified = s.verified or {} s.verified[n(2)] = true
      elseif k == 'roompoint' then s.roompoint = s.roompoint or {} s.roompoint[n(2)] = true
      elseif k == 'found' then s.found = s.found or {} s.found[#s.found + 1] = { dim = 0, x = n(2), y = n(3), z = n(4), side = p[5] }
      elseif k == 'woodturtle' then
        s.wood = s.wood or {}
        s.wood[#s.wood + 1] = { id = n(2), wait = (p[3]:gsub('_', ' ')), fuel = n(4), x = n(5), y = n(6), z = n(7), facing = n(8) }
      elseif k == 'candidate' then s.candidates = s.candidates or {} s.candidates[#s.candidates + 1] = { id = n(2), fuel = n(3) } end
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
  for _, b in ipairs(frame.buttons) do
    assert(b.x >= 1 and b.y >= 1 and b.w > 0 and b.x + b.w - 1 <= w and b.y + (b.h or 1) - 1 <= h, 'button ' .. b.id)
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
  ['mining-M'] = 'tests/ui/fixtures/mining-M.txt', ['mining-W'] = 'tests/ui/fixtures/mining-W.txt',
  ['mining-L'] = 'tests/ui/fixtures/mining-L.txt', ['mining-P'] = 'tests/ui/fixtures/mining-P.txt',
  ['mining-XS'] = 'tests/ui/fixtures/mining-XS.txt', ['miningsetup-M'] = 'tests/ui/fixtures/miningsetup-M.txt',
  ['miningempty-M'] = 'tests/ui/fixtures/miningempty-M.txt', ['miningempty-W'] = 'tests/ui/fixtures/miningempty-W.txt',
  ['miningsetup-L'] = 'tests/ui/fixtures/miningsetup-L.txt', ['miningsetup-P'] = 'tests/ui/fixtures/miningsetup-P.txt',
  ['miningores-M'] = 'tests/ui/fixtures/miningores-M.txt', ['miningores-P'] = 'tests/ui/fixtures/miningores-P.txt',
  ['lumber-M'] = 'tests/ui/fixtures/lumber-M.txt', ['lumber-W'] = 'tests/ui/fixtures/lumber-W.txt',
  ['lumber-L'] = 'tests/ui/fixtures/lumber-L.txt', ['lumber-P'] = 'tests/ui/fixtures/lumber-P.txt',
  ['lumber-XS'] = 'tests/ui/fixtures/lumber-XS.txt', ['lumbersetup-M'] = 'tests/ui/fixtures/lumbersetup-M.txt',
  ['lumbersetup-P'] = 'tests/ui/fixtures/lumbersetup-P.txt', ['drops-M'] = 'tests/ui/fixtures/drops-M.txt',
  ['drops-L'] = 'tests/ui/fixtures/drops-L.txt', ['drops-P'] = 'tests/ui/fixtures/drops-P.txt',
  ['drops-XS'] = 'tests/ui/fixtures/drops-XS.txt', ['dropsadd-M'] = 'tests/ui/fixtures/dropsadd-M.txt',
  ['dropsadd-P'] = 'tests/ui/fixtures/dropsadd-P.txt', ['dropsadd-XS'] = 'tests/ui/fixtures/dropsadd-XS.txt',
  ['dropssetup-M'] = 'tests/ui/fixtures/dropssetup-M.txt', ['dropssetup-P'] = 'tests/ui/fixtures/dropssetup-P.txt' }

local function match(name, frame)
  local fixture = R.load(FIXTURE[name])
  local out = capture(frame, fixture.w, fixture.h)
  local diff = R.diff(fixture, out)
  assert(#diff == 0, name .. '\n' .. table.concat(diff, '\n'))
  contrast(out, name)
  return out
end

-- Frame bytes as so-mod-display sends them: each row compacted the way D.compact does it, a blank
-- cell joining the previous run whatever its fg, or as text, fg and bg when that is smaller.
local function wire(proto, frame)
  local rows = {}
  for y, row in ipairs(frame.rows) do
    local fg, bg, runs = {}, {}, {}
    for _, run in ipairs(row.runs) do fg[#fg + 1], bg[#bg + 1] = string.rep(run[2], run[1]), string.rep(run[3], run[1]) end
    fg, bg = table.concat(fg), table.concat(bg)
    local text = row.text .. string.rep(' ', #fg - #row.text)
    for x = 1, #text do
      local last = runs[#runs]
      if last and last[3] == bg:sub(x, x) and (last[2] == fg:sub(x, x) or text:byte(x) == 32) then last[1] = last[1] + 1
      else runs[#runs + 1] = { 1, fg:sub(x, x), bg:sub(x, x) } end
    end
    local compact, plain = { text = row.text, runs = runs }, { text = text, fg = fg, bg = bg }
    rows[y] = #proto.ser(compact) < #proto.ser(plain) and compact or plain
  end
  return #proto.ser({ rows = rows, buttons = frame.buttons, palette = frame.palette })
end

local function ids(frame)
  local out = {}
  for _, b in ipairs(frame.buttons) do out[b.id] = b end
  return out
end

-- The real mining module with the scene's job: four turtles, ten branches, seven done. opts.empty
-- is the job before its first branch (the scene's emptymine line); opts.canvas sees every canvas.
local function mining(opts)
  opts = opts or {}
  local s, t = scene(), { saves = 0, states = {} }
  local g, fresh = s.mine, opts.empty and s.emptymine
  local job = { home = { x = g.x, y = g.y, z = g.z, facing = g.facing }, homeSet = true, dim = 'minecraft:overworld',
    bottom = g.bottom, length = g.length, mode = g.mode, ores = {}, turtles = {},
    progress = { done = s.mining.done, nextBranch = s.mining.total }, running = s.mining.running }
  if fresh then job.progress, job.running = { done = 0, nextBranch = 0 }, fresh.running end
  local env = setmetatable({}, { __index = _G })
  env.dofile = function(path)
    local lib = dofile(path)
    if path == 'so-ui.lua' and opts.canvas then
      local canvas = lib.canvas
      lib.canvas = function(...) return opts.canvas(canvas(...)) end
    end
    return lib
  end
  env.os = setmetatable({ epoch = function() return 0 end }, { __index = os })
  env.SO = { now = function() return 0 end, mods = {}, store = { store = function()
    return { value = job, save = function() t.saves = t.saves + 1 return true end } end, copy = function(v) return v end } }
  local mods = env.SO.mods
  mods.state = { canStart = function() return true end, get = function(key)
    for _, c in ipairs(s.candidates) do if key == 'machines/' .. c.id then return { fuel = c.fuel } end end
  end }
  mods.lease = { onReport = function() end, send = function() return 'park' end,
    status = function(id) return { lost = s.leases[id] == 'lost' or nil, open = s.leases[id] == 'open' or nil } end,
    cancelPark = function() return true end, candidates = function()
      local out = {}
      for _, c in ipairs(s.candidates) do out[#out + 1] = c.id end
      return out
    end }
  -- The scene's drop lines are the drop list with ids 1, 2, ...; the shop holds the fuel policy.
  mods.drops = { list = function()
    local out = {}
    for i, d in ipairs(s.drops) do out[i] = { id = tostring(i), dim = 0, x = d.x, y = d.y, z = d.z, side = 'front', kind = d.kind, broken = d.broken } end
    return out
  end }
  mods.shop = { fuelConfig = function(auto, output)
    if auto ~= nil then s.policy.auto = auto end
    if output ~= nil then s.policy.output = { id = output } end
    t.policy = s.policy
    return s.policy
  end }
  mods.cells = { reserve = function() return true end, releaseOwner = function() return true end }
  mods.display = { screen = function(_, render, input) t.render, t.input = render, input end }
  if not opts.bare then mods.daily = { today = function() return { ore = s.today.ore, oreByName = {} } end } end
  t.mod = assert(loadfile('so-mod-mine.lua', 't', env))()
  t.mod.tick()
  for _, row in ipairs(s.turtles) do
    if row.job == 'mine' then
      local lane = row.at == 'lane'
      local r = { pose = s.poses[tostring(row.id)], state = row.state, fuel = row.fuel, ores = row.ore,
        branch = lane and s.branch[row.id] or tonumber(row.at) }
      if fresh then lane, r.state, r.branch = false, fresh.state, nil end
      if lane then r.lane = { cells = {}, entered = 0 } end
      if r.state == 'wait lane' then r.laneWait = { at = 0, passes = 0 } end
      if r.state == 'done' then r.counted = r.branch end
      job.turtles[tostring(row.id)] = r
    end
  end
  t.job, t.env = job, env
  t.tap = function(session, id) t.input({ id = id, session = session, x = 1, y = 1 }) end
  t.type = function(text, session) t.input({ text = text, session = session }) end
  return t
end

-- The real lumber module with the scene's farm: twelve spots, nine ready, #5 felling.
local function lumber(opts)
  opts = opts or {}
  local s, t = scene(), { saves = 0 }
  local now = 50000000
  local p = s.poses['5']
  local wood
  for _, row in ipairs(s.turtles) do if row.job == 'lumber' then wood = row end end
  local job = { dim = 'minecraft:overworld', spots = {}, running = s.lumber.running, phase = wood.state, cursor = 1,
    logs = 0, fuel = wood.fuel, inv = { { name = 'minecraft:oak_sapling', count = s.saplings, slot = 1 } },
    nextRound = now + s.lumber.grow, area = s.area, ground = s.ground, saplings = s.chest,
    turtle = { id = wood.id, pose = { dim = 'minecraft:overworld', x = p.x, y = p.y, z = p.z, facing = p.facing } } }
  for _, spot in ipairs(s.spots) do job.spots[spot.x .. ',' .. spot.z] = { plantedAt = spot.ready and 0 or now - 1000 } end
  -- A second turtle on the farm (#217), waiting for a chest.
  job.turtles = {}
  for _, row in ipairs(s.wood) do
    job.turtles[tostring(row.id)] = { phase = 'scan', cursor = 1, fuel = row.fuel, inv = {}, wait = row.wait,
      turtle = { id = row.id, pose = { dim = 'minecraft:overworld', x = row.x, y = row.y, z = row.z, facing = row.facing } } }
  end
  local env = setmetatable({}, { __index = _G })
  env.os = setmetatable({ epoch = function() return 0 end }, { __index = os })
  env.SO = { now = function() return now end, mods = {}, store = { store = function()
    return { value = job, save = function() t.saves = t.saves + 1 return true end } end, copy = function(v) return v end } }
  local mods = env.SO.mods
  mods.display = { screen = function(_, render, input) t.render, t.input = render, input end }
  mods.state = { canStart = function() return true end, emit = function() end, get = function(key)
    for _, c in ipairs(s.candidates) do if key == 'machines/' .. c.id then return { fuel = c.fuel } end end
  end }
  mods.cells = { releaseOwner = function() return true end }
  if not opts.bare then
    mods.daily = { today = function() return { logs = s.today.logs } end }
    mods.drops = { list = function()
      local out = {}
      for i, d in ipairs(s.drops) do out[i] = { id = tostring(i), dim = 0, x = d.x, y = d.y, z = d.z, side = 'front', kind = d.kind, broken = d.broken } end
      return out
    end }
  end
  t.mod = assert(loadfile('so-mod-lumber.lua', 't', env))()
  t.mod.tick(now)
  for i = 1, 30 do
    local name, value = debug.getupvalue(t.mod.tick, i)
    if name == 'S' then t.S = value break end
  end
  for _, row in pairs(job.turtles) do row.recover = false end
  mods.lease = { onReport = function() end, status = function() return {} end, candidates = function()
    local out = {}
    for _, c in ipairs(s.candidates) do out[#out + 1] = c.id end
    return out
  end }
  t.job, t.env = job, env
  t.tap = function(session, id) t.input({ id = id, session = session, x = 1, y = 1 }) end
  return t
end

-- The real drops module with the scene's five points; the server, the shaft and the farm come from
-- so-server.cfg and the two jobs' mapView.
local function drops(opts)
  opts = opts or {}
  local s, t = scene(), { saves = 0 }
  local points = {}
  for _, d in ipairs(s.drops) do
    points[#points + 1] = { id = string.format('0_%d_%d_%d_front_%s', d.x, d.y, d.z, d.kind), dim = 0, x = d.x, y = d.y, z = d.z,
      side = 'front', kind = d.kind, fails = (d.broken or opts.broken == #points + 1) and 3 or 0,
      verified = s.verified[#points + 1] and { at = 0, block = 'minecraft:chest' } or nil, room = s.roompoint[#points + 1] }
  end
  local c = s.chest
  points[#points + 1] = { id = string.format('0_%d_%d_%d_front_storage', c.x, c.y, c.z), dim = 0, x = c.x, y = c.y, z = c.z,
    side = 'front', kind = 'storage', fails = 0 }
  for i = 1, opts.extra or 0 do
    points[#points + 1] = { id = 'extra' .. i, dim = 0, x = 100 + i, y = 64, z = -330, side = 'front', kind = 'any', fails = 0 }
  end
  t.stored = { points = points }
  local env = setmetatable({}, { __index = _G })
  env.os = setmetatable({ epoch = function() return 0 end }, { __index = os })
  env.SO = { now = function() return 1000 end, mods = {}, store = {
    store = function() return { value = t.stored, save = function(v) t.saves = t.saves + 1 t.stored = v return true end } end,
    read = function(path) if path == 'so-server.cfg' then return { pos = { x = s.server.x, y = s.server.y, z = s.server.z } } end end,
    copy = function(v) local o = {} for k, x in pairs(v) do o[k] = x end return o end } }
  local g = s.mine
  env.SO.mods.mine = { mapView = function() return { home = { x = g.x, y = g.y, z = g.z, facing = g.facing }, homeSet = true } end }
  env.SO.mods.lumber = { mapView = function() return { area = s.area } end }
  env.SO.mods.display = { screen = function(_, render, input) t.render, t.input = render, input end }
  env.SO.mods.state = { emit = function() end }
  env.SO.mods.lease = { candidates = function()
    local out = {}
    for _, c in ipairs(s.candidates) do out[#out + 1] = c.id end
    return out
  end }
  t.mod = assert(loadfile('so-mod-drops.lua', 't', env))()
  t.mod.tick()
  for i = 1, 30 do
    local name, value = debug.getupvalue(t.mod.tick, i)
    if name == 'S' then t.S = value break end
  end
  -- The chests an earlier scan found.
  t.S.candidates = s.found
  t.tap = function(session, id) t.input({ id = id, session = session, from = session.id, x = 1, y = 1 }) end
  t.type = function(session, text) t.input({ text = text, session = session, from = session.id }) end
  return t
end

return function(test, equal)
  test('S3 mining overview, setup and ore list match every size fixture', function()
    local t = mining()
    for _, size in ipairs({ { 'mining-M', 57, 24 }, { 'mining-W', 100, 38 }, { 'mining-L', 39, 19 },
        { 'mining-P', 26, 20 }, { 'mining-XS', 15, 10 } }) do
      match(size[1], t.render(size[2], size[3], { id = 7 }))
    end
    for _, size in ipairs({ { 'miningsetup-M', 57, 24 }, { 'miningsetup-L', 39, 19 }, { 'miningsetup-P', 26, 20 } }) do
      local session = { id = 7 }
      t.tap(session, 'tab:setup')
      match(size[1], t.render(size[2], size[3], session))
      t.tap(session, 'ores-edit')
      if size[1] ~= 'miningsetup-L' then match(size[1]:gsub('setup', 'ores'), t.render(size[2], size[3], session)) end
      t.tap(session, 'ores-edit')
      match(size[1], t.render(size[2], size[3], session))
    end
    equal(t.saves, 0)
  end)

  test('S3 mining before the first branch matches the empty fixtures', function()
    local t = mining({ empty = true })
    for _, size in ipairs({ { 'miningempty-M', 57, 24 }, { 'miningempty-W', 100, 38 } }) do
      match(size[1], t.render(size[2], size[3], { id = 7 }))
    end
  end)

  -- The facts are the only leaders on the overview: no other drawing may touch a cell a leader drew.
  test('S3 mining facts never share a cell with the diagram or the turtles', function()
    local C
    local function canvas(c)
      C = c
      local put, leader, inLeader = c.put, c.leader, false
      c.owner = {}
      c.put = function(x, y, text, ...)
        for i = 1, #text do
          local col = x + i - 1
          if y >= 1 and y <= c.h and col >= 1 and col <= c.w then
            local k, who = y * 1000 + col, inLeader and 'facts' or 'other'
            local was = c.owner[k]
            if was and was ~= who then c.clash = c.clash or string.format('%d,%d %q', col, y, text) end
            c.owner[k] = who
          end
        end
        return put(x, y, text, ...)
      end
      c.leader = function(...)
        inLeader = true
        leader(...)
        inLeader = false
      end
      return c
    end
    local sizes = { { 52, 22 }, { 57, 24 }, { 64, 30 }, { 80, 26 }, { 100, 38 }, { 121, 50 }, { 24, 14 }, { 26, 20 },
      { 30, 19 }, { 39, 19 }, { 51, 21 }, { 15, 10 }, { 23, 13 }, { 20, 6 } }
    local checked = 0
    for _, total in ipairs({ 0, 1, 2, 3, 4, 6, 10, 40 }) do
      for _, length in ipairs({ 8, 16, 32, 64 }) do
        for _, crew in ipairs({ 'all', 'none' }) do
          local t = mining({ empty = total == 0, canvas = canvas })
          t.job.length, t.job.progress.nextBranch, t.job.progress.done = length, total, math.min(total, 7)
          for id, row in pairs(t.job.turtles) do
            if crew == 'none' then t.job.turtles[id] = nil
            elseif row.branch and row.branch >= total then row.branch, row.lane, row.laneWait, row.counted = nil, nil, nil, nil end
          end
          for _, size in ipairs(sizes) do
            t.render(size[1], size[2], { id = 7 })
            assert(not C.clash, string.format('%dx%d, %d branches, length %d, turtles %s: %s', size[1], size[2], total,
              length, crew, tostring(C.clash)))
            checked = checked + 1
          end
        end
      end
    end
    equal(checked, 8 * 4 * 2 * 14)
  end)

  test('S3 lumber overview and setup match every size fixture', function()
    local t = lumber()
    for _, size in ipairs({ { 'lumber-M', 57, 24 }, { 'lumber-W', 100, 38 }, { 'lumber-L', 39, 19 },
        { 'lumber-P', 26, 20 }, { 'lumber-XS', 15, 10 } }) do
      match(size[1], t.render(size[2], size[3], { id = 7 }))
    end
    for _, size in ipairs({ { 'lumbersetup-M', 57, 24 }, { 'lumbersetup-P', 26, 20 } }) do
      local session = { id = 7 }
      t.tap(session, 'tab:setup')
      match(size[1], t.render(size[2], size[3], session))
    end
    equal(t.saves, 0)
  end)

  test('S3 drop points and the add editor match every size fixture', function()
    local t = drops()
    for _, size in ipairs({ { 'drops-M', 57, 24 }, { 'drops-L', 39, 19 }, { 'drops-P', 26, 20 }, { 'drops-XS', 15, 10 } }) do
      match(size[1], t.render(size[2], size[3], { id = 7 }))
    end
    for _, size in ipairs({ { 'dropsadd-M', 57, 24 }, { 'dropsadd-P', 26, 20 }, { 'dropsadd-XS', 15, 10 } }) do
      local session = { id = 8 }
      t.type(session, '126 64 -337')
      match(size[1], t.render(size[2], size[3], session))
    end
    for _, size in ipairs({ { 'dropssetup-M', 57, 24 }, { 'dropssetup-P', 26, 20 } }) do
      local session = { id = 9 }
      t.tap(session, 'testing')
      match(size[1], t.render(size[2], size[3], session))
    end
    equal(t.saves, 0)
  end)

  test('S3 setup controls change the job exactly like the typed commands, one save per tap', function()
    for _, case in ipairs({ { 'set-bottom-', 'bottom -59' }, { 'set-bottom+', 'bottom -57' }, { 'set-length-', 'length 56' },
        { 'set-length+', 'length 72' }, { 'mode-fast', 'mode fast' }, { 'mode-thorough', 'mode thorough' },
        { 'ore-coal', 'ores copper,iron,gold,redstone,lapis,diamond' } }) do
      local a, b, session = mining(), mining(), { id = 7 }
      a.tap(session, 'tab:setup')
      if case[1]:find('^ore') then a.tap(session, 'ores-edit') end
      assert(ids(a.render(57, 24, session))[case[1]], 'no drawn ' .. case[1])
      a.tap(session, case[1])
      b.type(case[2])
      equal(a.job, b.job)
      equal({ a.saves, b.saves }, { 1, 1 })
    end
    local t, session = mining(), { id = 7 }
    t.tap(session, 'tab:setup')
    t.tap(session, 'ore-coal')
    equal(#t.job.ores, 6)
    t.tap(session, 'ore-coal')
    equal(#t.job.ores, 7)
    assert(capture(t.render(57, 24, session), 57, 24).picture().text[11]:find('ores       all', 1, true))
    t.type('ores iron')
    local saves = t.saves
    t.tap(session, 'ore-iron')
    equal({ t.job.ores, t.saves }, { { 'iron' }, saves })
    t.type('length 4')
    t.tap(session, 'set-length-')
    equal(t.job.length, 1)
    t.type('length 4093')
    t.tap(session, 'set-length+')
    equal(t.job.length, 4096)
    -- Typed commands keep working on the setup tab, and taps never move another display's tab.
    t.type('home 1 2 3 e', session)
    equal(t.job.home, { x = 1, y = 2, z = 3, facing = 1 })
    assert(ids(t.render(57, 24, { id = 8 }))['tab:setup'] and not ids(t.render(57, 24, { id = 8 }))['set-bottom-'])
  end)

  test('S3 FIX, REMOVE and ADD act on the selected point once per tap', function()
    local t = drops({ broken = 1 })
    local list = t.mod.list
    local a, b = { id = 7 }, { id = 8 }
    local first, second, third = list()[1].id, list()[2].id, list()[3].id
    assert(capture(t.render(57, 24, a), 57, 24).picture().text[23]:find('FIX 1', 1, true))
    t.tap(a, 'select:' .. third)
    assert(capture(t.render(57, 24, a), 57, 24).picture().text[23]:find('FIX 3', 1, true))
    assert(capture(t.render(57, 24, b), 57, 24).picture().text[23]:find('FIX 1', 1, true), 'selection is per display')
    t.tap(a, 'fix')
    equal({ list()[1].broken, list()[3].broken, t.saves }, { true, false, 1 })
    t.tap(a, 'fix')
    equal(t.saves, 1)
    t.tap(a, 'remove')
    equal({ #list(), t.saves, t.mod.list()[3].id }, { 4, 2, list()[3].id })
    for _, p in ipairs(list()) do assert(p.id ~= third, 'removed the selected point') end
    -- The plan marks every chest as a one-cell target for the same selection.
    local cells = 0
    for _, button in ipairs(t.render(57, 24, b).buttons) do
      if button.id == 'select:' .. second and button.w == 1 then cells = cells + 1 end
    end
    equal(cells, 1)
    t.tap(b, 'select:' .. second)
    t.tap(b, 'new')
    local editor = capture(t.render(57, 24, b), 57, 24).picture().text
    assert(editor[9]:find('120', 1, true) and editor[3]:find('fuel', 1, true), editor[9])
    t.tap(b, 'add')
    equal({ #list(), t.saves }, { 4, 2 })
    assert(capture(t.render(57, 24, b), 57, 24).picture().text[22]:find('! id exists', 1, true))
    t.tap(b, 'x+')
    t.tap(b, 'add')
    equal({ #list(), t.saves, list()[5].x, list()[5].kind }, { 5, 3, 121, 'fuel' })
    assert(capture(t.render(57, 24, b), 57, 24).picture().text[22]:find('point added', 1, true))
    t.tap(b, 'list')
    t.type(b, 'add ore 130 64 -337')
    equal({ #list(), t.saves, list()[6].x }, { 6, 4, 130 })
    equal(first, list()[1].id)
  end)

  test('S3 mine and lumber facts give other screens the job state without a frame', function()
    equal(mining().mod.facts(), { state = 'running', done = 7, total = 10, busy = 2, workers = 4, depth = -58,
      lane = { id = 4, facing = 2 }, fuel = { value = 412, id = 6 } })
    equal(lumber().mod.facts(), { state = 'running', ready = 9, spots = 12, grow = '6:20', saplings = 14, fuel = 640 })
    -- The pocket panel still probes a 120x18 frame from an id-less session until it reads facts().
    local probe = mining().render(120, 18, {})
    equal({ probe.rows[2].text, probe.rows[5].text, probe.rows[5].runs[1][3] }, { 'MINING running', 'BRANCHES 7/10', 'b' })
    probe = lumber().render(120, 18, {})
    equal({ probe.rows[2].text, probe.rows[3].text }, { 'LUMBER running', 'TREES READY 9' })
  end)

  test('S3 crowded jobs, missing modules and odd sizes stay in bounds and under the frame limit', function()
    local proto = dofile('so-proto.lua')
    local t = mining()
    t.job.progress.nextBranch = 40
    for id = 20, 33 do
      t.job.turtles[tostring(id)] = { pose = { x = 121 + id, y = -58, z = -341 - 4 * (id - 10), facing = 1 }, state = 'mining',
        branch = id - 10, fuel = 900, ores = id }
    end
    local room = capture(t.render(57, 24, { id = 7 }), 57, 24).picture().text
    assert(room[3]:find('^40 '), room[3])
    local more = false
    for _, line in ipairs(room) do more = more or line:find('+%d+ more') ~= nil end
    assert(more, 'hidden turtles are counted')
    local screens = { t, lumber(), drops({ extra = 40 }), mining({ bare = true }), lumber({ bare = true }) }
    for _, size in ipairs({ { 1, 1 }, { 15, 10 }, { 26, 20 }, { 29, 12 }, { 36, 10 }, { 39, 19 }, { 51, 19 }, { 57, 24 },
        { 82, 40 }, { 100, 38 }, { 164, 81 } }) do
      for which, screen in ipairs(screens) do
        for _, tab in ipairs({ 'tab:overview', 'tab:setup' }) do
          local session = { id = 9 }
          screen.tap(session, tab)
          local frame = screen.render(size[1], size[2], session)
          contrast(capture(frame, size[1], size[2]), size[1] .. 'x' .. size[2])
          local bytes = wire(proto, frame)
          assert(bytes <= 16000, 'screen ' .. which .. ' ' .. tab .. ' frame bytes at ' .. size[1] .. 'x' .. size[2] .. ': ' .. bytes)
        end
      end
    end
  end)

  test('S3 schematic generator reproduces every job fixture', function()
    local started, pipe = pcall(io.popen, 'pwd')
    local root = started and pipe and pipe:read('*l')
    if started and pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= '/' or not os.execute('python3 -V > /dev/null 2>&1') then
      return dofile('tests/skips.lua').record('S3 schematic generator', 'needs host processes, a POSIX shell and python3')
    end
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "'"))
    assert(os.execute("python3 -I '" .. root .. "/docs/ui/schematic/screens.py' --fixtures '" .. dir .. "' > /dev/null"))
    local count = 0
    for name in read(root .. '/docs/ui/schematic/jobs.py'):gmatch('\n    %("([%w%-]+)", _') do
      equal(read(dir .. '/' .. name .. '.txt'), read(assert(FIXTURE[name], name)))
      count = count + 1
    end
    equal(count, 28)
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)

  test('S3 short setup screens, double taps and other dimensions stay safe', function()
    -- No control hides under the alert or the action row, and no two controls overlap.
    local t = mining()
    t.job.turtles['2'].error = 'no fuel chest'
    for _, size in ipairs({ { 39, 10 }, { 57, 5 }, { 24, 5 }, { 82, 5 }, { 26, 12 } }) do
      for _, ores in ipairs({ false, true }) do
        local session = { id = 9 }
        t.tap(session, 'tab:setup')
        if ores then t.tap(session, 'ores-edit') end
        local frame = t.render(size[1], size[2], session)
        local taken = {}
        for _, b in ipairs(frame.buttons) do
          if b.id ~= 'start' and b.id ~= 'stop' then assert(b.y <= size[2] - 2, b.id .. ' under the alert at ' .. size[1] .. 'x' .. size[2]) end
          for x = b.x, b.x + b.w - 1 do
            assert(not taken[x .. ',' .. b.y], b.id .. ' overlaps at ' .. size[1] .. 'x' .. size[2])
            taken[x .. ',' .. b.y] = true
          end
        end
      end
    end
    -- A second REMOVE before the next frame does nothing; typed add keeps its old reply.
    local d, a = drops(), { id = 7 }
    t = d.render(57, 24, a)
    d.tap(a, 'remove')
    d.tap(a, 'remove')
    equal(#d.mod.list(), 4)
    d.render(57, 24, a)
    d.tap(a, 'remove')
    equal(#d.mod.list(), 3)
    d.type(a, 'add ore 1 2 3')
    d.type(a, 'add ore 1 2 3')
    equal(#d.mod.list(), 4)
    assert(capture(d.render(57, 24, a), 57, 24).picture().text[22]:find('point added', 1, true))
    -- A Nether wood point inside the farm's x and z is not drawn on the overworld farm.
    local l = lumber()
    local list = l.env.SO.mods.drops.list
    l.env.SO.mods.drops.list = function()
      local out = list()
      out[#out + 1] = { id = 'nether', dim = -1, x = 100, y = 64, z = -349, side = 'front', kind = 'wood', broken = true }
      return out
    end
    equal(R.diff(R.load(FIXTURE['lumber-M']), capture(l.render(57, 24, { id = 7 }), 57, 24)), {})
  end)

  test('S3 server-only controls in route A: add here, fuel policy, pages, turtle rows, room and from', function()
    -- Mining: here:<id> runs the typed add, fuel chips change the shop policy, setup-next pages READY.
    local t, session = mining(), { id = 7 }
    t.tap(session, 'tab:setup')
    local frame = t.render(29, 12, session)
    assert(ids(frame)['fuel-auto'] and ids(frame)['setup-next'] and ids(frame)['here:12'] == nil)
    t.tap(session, 'setup-next')
    assert(ids(t.render(29, 12, session))['here:12'], 'READY page')
    t.tap(session, 'here:12')
    assert(capture(t.render(57, 24, session), 57, 24).picture().text[21]:find('GPS unavailable', 1, true))
    t.tap(session, 'fuel-auto')
    equal(t.policy.auto, false)
    t.tap(session, 'fuel-output')
    equal(t.policy.output.id, '2')
    -- Continuous jobs plan their whole branch budget; turtle rows open the turtle's details.
    t.job.continuous, t.job.branches = true, 12
    local room = t.render(57, 24, { id = 8 })
    assert(capture(room, 57, 24).picture().text[3]:find('^ *12 '), 'branch budget')
    assert(ids(room)['turtle:2'] and ids(room)['turtle:6'])
    for id = 20, 33 do t.job.turtles[tostring(id)] = { pose = { x = 121, y = -58, z = -345, facing = 1 }, state = 'mining', fuel = 900, ores = 0 } end
    local first = ids(t.render(57, 24, { id = 8 }))
    assert(first['workers-next'] and first['turtle:2'])
    local paged = { id = 8 }
    t.tap(paged, 'workers-next')
    local second = ids(t.render(57, 24, paged))
    assert(not second['turtle:2'] and second['workers-next'], 'turtle page two')
    equal(t.saves, 0)
    -- Lumber: both turtles sit on the plan and in the list; READY adds the unassigned turtle.
    local l = lumber()
    local lf = l.render(57, 24, { id = 7 })
    assert(ids(lf)['turtle:5'] and ids(lf)['turtle:7'])
    local ls = { id = 7 }
    l.tap(ls, 'tab:setup')
    assert(ids(l.render(57, 24, ls))['here:12'])
    -- Drops: room toggles, a turtle's position and a found chest fill the draft.
    local d, a = drops(), { id = 7 }
    d.tap(a, 'new')
    d.tap(a, 'room-point')
    equal({ d.S.draft.kind, d.S.draft.room, d.S.message }, { 'junk', nil, 'room needs ore or wood' })
    d.tap(a, 'kind')
    d.tap(a, 'room-point')
    equal({ d.S.draft.kind, d.S.draft.room }, { 'wood', true })
    d.tap(a, 'kind')
    equal(d.S.draft.room, nil)
    d.tap(a, 'room-sink')
    equal({ d.S.roomSink, d.saves, d.stored.roomSink }, { true, 1, true })
    assert(ids(d.render(57, 24, a))['from:12'])
    d.tap(a, 'from:12')
    equal(d.S.message, 'turtle world pose unavailable')
    d.tap(a, 'list')
    d.tap(a, 'testing')
    local setup = ids(d.render(57, 24, a))
    assert(setup['scan:12'] and setup['candidate:1'] and setup.list)
    d.tap(a, 'candidate:1')
    equal({ d.S.draft.x, d.S.draft.y, d.S.draft.z, d.S.draft.side }, { 121, 64, -340, 'down' })
    assert(capture(d.render(57, 24, a), 57, 24).picture().text[1]:find('ADD DROP POINT', 1, true))
  end)
end