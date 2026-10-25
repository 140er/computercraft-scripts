-- The route A scene as a running server: the real so-mod-display (and, on request, so-mod-panel and
-- so-mod-shop) fed from tests/ui/status-scene.txt, tests/ui/map-scene.txt and tests/ui/system-scene.txt,
-- the same files docs/ui/schematic reads to write the fixtures.
local R = dofile('tests/ui/render.lua')
local S = {}

local function read(path)
  local f = assert(io.open(path, 'rb'))
  local text = f:read('*a')
  f:close()
  return text
end

local function words(text)
  local out = {}
  for line in text:gmatch('[^\n]+') do
    local p = {}
    for w in line:gmatch('%S+') do p[#p + 1] = w end
    if #p > 0 then out[#out + 1] = p end
  end
  return out
end

-- Draws a frame the way display.lua does: runs or blit strings, padded to the run width.
S.capture = function(frame, w, h)
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

S.private = function(fn, key)
  for i = 1, 60 do local name, value = debug.getupvalue(fn, i); if name == key then return value end end
  error('missing upvalue ' .. key)
end

-- Fixture text back to CC bytes.
local BYTE = {}
for b = 0, 255 do if b < 128 or b > 159 then BYTE[R.char(b)] = b end end
S.chars = function(text)
  local out = {}
  for ch in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do out[#out + 1] = ch end
  return out
end
S.bytes = function(text)
  local out = {}
  for i, ch in ipairs(S.chars(text)) do out[i] = string.char(BYTE[ch]) end
  return table.concat(out)
end

-- Draws the fixture's own non-blank cells in a rectangle: a stand-in for a map module drawing there.
S.cellsFrom = function(path, calls)
  local fixture = R.load(path)
  return function(C, x, y, w, h, ...)
    calls[#calls + 1] = { x, y, w, h, ... }
    for j = 0, h - 1 do
      local text, fg, bg = S.chars(fixture.text[y + j]), fixture.fg[y + j], fixture.bg[y + j]
      for i = 0, w - 1 do
        local ch = text[x + i]
        if ch ~= ' ' then C.put(x + i, y + j, string.char(BYTE[ch]), fg:sub(x + i, x + i), bg:sub(x + i, x + i)) end
      end
    end
    return true
  end
end

-- tests/ui/system-scene.txt: the state alert, saplings, shop stock, search, order, pair code, outage and log.
S.system = function()
  local sys = { stock = {}, log = {} }
  for _, p in ipairs(words(read('tests/ui/system-scene.txt'))) do
    local k = p[1]
    if k == 'alert' then sys.alert = { key = p[2], id = tonumber(p[3]), text = table.concat(p, ' ', 4) }
    elseif k == 'saplings' then sys.saplings = tonumber(p[2])
    elseif k == 'stock' then sys.stock[p[2]] = tonumber(p[3])
    elseif k == 'search' then sys.search = p[2]
    elseif k == 'order' then sys.order = { tonumber(p[2]), p[3] }
    elseif k == 'pair' then sys.code, sys.left = p[2], tonumber(p[3])
    elseif k == 'outage' then sys.since, sys.retry = tonumber(p[2]), tonumber(p[3])
    elseif k == 'log' then sys.log[#sys.log + 1] = table.concat(p, ' ', 2) end
  end
  return sys
end

-- opts: bare (no daily, mine or lumber), thumb/crop (map module functions), alert (the state alert),
-- panel (so-mod-panel and stub job screens), shop (so-mod-shop with the stock), facts (job facts()).
S.new = function(opts)
  opts = opts or {}
  local s = { now = 50000000, sends = {}, calls = {}, saved = { roles = {}, far = {}, locked = {} }, sys = S.system() }
  local status, map = words(read('tests/ui/status-scene.txt')), words(read('tests/ui/map-scene.txt'))
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
  env.os = setmetatable({ epoch = function() return epoch end, getComputerID = function() return s.id end }, { __index = os })
  env.fs = { getCapacity = function() return disk[1] end, getFreeSpace = function() return disk[2] end }
  env.SO = { now = function() return s.now end, mods = {}, terminal = { log = log, started = started, id = s.id, mode = 'normal', offset = 0 },
    pair = { key = function() return string.rep('01', 32) end, pending = function() return s.pending end },
    store = { read = function() return nil end, store = function(path)
      s.storeValues=s.storeValues or {}
      if path=="so-display" then return {value=s.saved,save=function(v) s.saved=v return true end} end
      return {value=s.storeValues[path],save=function(v) s.storeValues[path]=env.SO.store.copy(v) return true end}
    end, copy = dofile("so-store.lua").copy } }
  env.SO.pairCode = function(id)
    s.calls[#s.calls + 1] = { 'pair', id }
    s.pending = s.sys.code
    return { code = s.sys.code, expires = s.now + s.sys.left }
  end
  env.SO.proto = assert(loadfile('so-proto.lua', 't', env))()
  env.rednet = { send = function(id, body, protocol) s.sends[#s.sends + 1] = { id = id, body = body, protocol = protocol } end,
    broadcast = function() end }
  local mods = env.SO.mods
  local values = {}
  s.values = values
  mods.state = { view = function() return { values = values } end, get = function() return machines end }
  mods.lease = { status = function(id) return { open = leases[id] == 'open' and 'l' or nil, lost = leases[id] == 'lost' or nil } end }
  mods.drops = { list = function() return drops end }
  if not opts.bare then
    mods.daily = { today = function() return today end }
    mods.mine = { mapView = function() return mineView end }
    mods.lumber = { mapView = function() return wood end }
    if opts.facts then
      mods.mine.facts = function() return { state = 'running', done = 7, total = 10, busy = 2, workers = 4,
        lane = { id = 4, facing = 2 }, fuel = { value = 412, id = 6 }, depth = -58 } end
      mods.lumber.facts = function() return { state = 'running', ready = 9, spots = 12, grow = '6:20',
        saplings = s.sys.saplings, fuel = 1210 } end
    end
  end
  if opts.thumb or opts.crop then mods.map = { thumb = opts.thumb, crop = opts.crop } end
  for _, row in ipairs(displays) do s.saved.roles[tostring(row[1])], s.saved.locked[tostring(row[1])] = row[2], true end
  local d = assert(loadfile('so-mod-display.lua', 't', env))()
  mods.display = d
  local D = S.private(d.handlers.hello, 'D')
  if opts.panel then
    s.jobs = { mining = 'running', lumber = 'running' }
    for _, role in ipairs({ 'mining', 'lumber' }) do
      d.screen(role, function() return { rows = {}, buttons = {} } end, function(e)
        s.calls[#s.calls + 1] = { role, e.id }
        s.jobs[role] = e.id == 'start' and 'running' or 'stopped'
      end)
    end
  end
  if opts.shop then
    local shop = assert(loadfile('so-mod-shop.lua', 't', env))()
    mods.shop = shop
    shop.tick(0)
    shop.listen.roomsorter_stock(9, { totals = s.sys.stock })
    s.shop = shop
  end
  if opts.panel then
    local p = assert(loadfile('so-mod-panel.lua', 't', env))()
    mods.panel = p
    p.tick(0)
    s.panel = p
  end
  for _, row in ipairs(displays) do
    local w, h = row[3]:match('(%d+)x(%d+)')
    d.handlers.hello({ from = row[1], body = { w = tonumber(w), h = tonumber(h) - 1, fullH = tonumber(h), keyboard = row[2] == 'pocket' } })
    D.sessions[row[1]].sent = s.now
  end
  -- Raised after the displays opened: alerts standing before a session opened never take over it.
  if opts.alert then
    values[s.sys.alert.key] = { id = s.sys.alert.id, text = s.sys.alert.text }
    if s.panel then s.panel.tick(0) end
  end
  s.d, s.D, s.env = d, D, env
  -- The full server path: gather, compose, fit and compact, as a display would receive it.
  s.view = function(id)
    local got
    d.handlers['view.get']({ from = id }, function(_, body) got = body end)
    return got
  end
  -- A display taps what it was last sent: fetch the frame, then press the drawn control there.
  s.tap = function(id, button)
    local x, y = 1, 1
    for _, b in ipairs((s.view(id) or {}).buttons or {}) do if b.id == button then x, y = b.x, b.y break end end
    d.handlers.input({ from = id, body = { id = button, x = x, y = y } })
  end
  s.type = function(id, text) d.handlers.input({ from = id, body = { text = text, x = 1, y = 1 } }) end
  -- Status or a takeover at any size for a private session, through the same fit and compact.
  s.frame = function(session, w, h, pocket)
    D.model = D.gather()
    local frame = D.statusFrame(session, w, h, s.now, pocket)
    local fitted = D.fit(frame, w, h)
    fitted.palette = frame.palette
    return fitted
  end
  return s
end

return S
