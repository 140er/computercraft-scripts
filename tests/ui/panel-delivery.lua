-- B5-U panel and pocket SHOP deliveries: the fixtures docs/ui/schematic/panel.py writes for the panel's
-- SHOP page and the pocket's delivery mode, then the real so-mod-build delivery engine and so-mod-shop
-- under so-mod-panel: one request per drawn attempt token, ORDERED until the worker's confirmed deposit,
-- held cargo with RETRY, refused as final, busy outputs and the explicitly disabled flag.
local R = dofile('tests/ui/render.lua')
local S = dofile('tests/ui/scene.lua')
local H = dofile('tests/so/harness.lua')
local PL = dofile('so-plan.lua')

-- Literal paths, so part runs declare every fixture they read.
local FIXTURE = {
  ['panelshopnav-M'] = 'tests/ui/fixtures/panelshopnav-M.txt', ['panelshop-M'] = 'tests/ui/fixtures/panelshop-M.txt',
  ['panelshop-S'] = 'tests/ui/fixtures/panelshop-S.txt', ['panelshop-XS'] = 'tests/ui/fixtures/panelshop-XS.txt',
  ['panelshopkey-S'] = 'tests/ui/fixtures/panelshopkey-S.txt', ['panelshopnone-M'] = 'tests/ui/fixtures/panelshopnone-M.txt',
  ['panelshopordered-M'] = 'tests/ui/fixtures/panelshopordered-M.txt',
  ['panelshopheld-M'] = 'tests/ui/fixtures/panelshopheld-M.txt', ['panelshopbusy-L'] = 'tests/ui/fixtures/panelshopbusy-L.txt',
  ['pocket-shopdeliver-P'] = 'tests/ui/fixtures/pocket-shopdeliver-P.txt',
  ['pocket-shoprefused-P'] = 'tests/ui/fixtures/pocket-shoprefused-P.txt',
  ['pocket-shoproom-P'] = 'tests/ui/fixtures/pocket-shoproom-P.txt' }

-- The scene's delivery chest (panel.py CHEST) and the statuses its fixtures show (panel.py DELIVERY).
local CHEST = { id = 'workshop', dim = 0, x = 12, y = 64, z = -3, side = 'front', kind = 'storage' }
local STATUS = {
  ordered = { id = 'delivery-1', stage = 'pickup', n = 16, item = 'minecraft:iron_ingot', deposited = 0, picked = 0, terminal = false },
  held = { id = 'delivery-1', stage = 'held', n = 16, item = 'minecraft:iron_ingot', deposited = 0, picked = 16, terminal = false,
    error = 'delivery chest full or transfer failed' },
  delivered = { id = 'delivery-1', stage = 'complete', n = 16, item = 'minecraft:iron_ingot', deposited = 16, picked = 16,
    terminal = true, destination = { id = 'workshop' } },
  refused = { id = 'delivery-1', stage = 'refused', n = 16, item = 'minecraft:iron_ingot', deposited = 0, picked = 0,
    terminal = true, error = 'room support missing' } }
-- Each size-coverage state: a picked chest, the session's own delivery and what holds the room output.
local STATES = {
  scene = { chest = true }, none = {}, ordered = { chest = true, own = 'ordered', active = true },
  held = { chest = true, own = 'held', active = true }, busy = { chest = true, busy = true }, keyboard = { chest = true },
  deliver = { chest = true, own = 'delivered' }, refused = { chest = true, own = 'refused' }, room = {} }

-- The scene with deliveries on: the chest in the drop list, shop.deliveryView and a build stub that
-- records requests and retries.
local function deliveries(s)
  local st = { outputs = {}, statuses = {}, requests = {}, retries = {} }
  table.insert(s.env.SO.mods.drops.list(), CHEST)
  s.shop.deliveryView = function() return { enabled = true, output = 'room', outputs = st.outputs } end
  s.env.SO.mods.build = {
    deliveryRequest = function(spec)
      st.requests[#st.requests + 1] = spec
      if st.nextErr then return nil, st.nextErr end
      return 'delivery-2'
    end,
    deliveryStatus = function(id) return st.statuses[id] end,
    deliveryRetry = function(id) st.retries[#st.retries + 1] = id return true end }
  return st
end
-- Puts one STATES case into st and the session's panel or pocket state.
local function apply(st, state, target)
  local case = STATES[state]
  for k in pairs(st.outputs) do st.outputs[k] = nil end
  for k in pairs(st.statuses) do st.statuses[k] = nil end
  target.chest = case.chest and { id = CHEST.id, dim = CHEST.dim, x = CHEST.x, y = CHEST.y, z = CHEST.z, side = CHEST.side, kind = CHEST.kind } or nil
  if case.own then
    st.statuses['delivery-1'] = STATUS[case.own]
    target.delivery = { id = 'delivery-1', n = 16, label = 'IRON INGOT' }
  end
  if case.active then st.outputs[1] = { kind = 'delivery', ownerId = 'delivery-1', state = 'claimed' } end
  if case.busy then st.outputs[1] = { kind = 'ordinary', ownerId = 'ordinary:room', state = 'quarantined', error = 'order timed out' } end
end

local function match(name, frame)
  local fixture = R.load(FIXTURE[name])
  local out = S.capture(frame, fixture.w, fixture.h)
  local diff = R.diff(fixture, out)
  assert(#diff == 0, name .. '\n' .. table.concat(diff, '\n'))
  for _, b in ipairs(frame.buttons or {}) do
    assert(b.h == 1 and b.x >= 1 and b.x + b.w - 1 <= fixture.w and b.y <= fixture.h, name .. ' button ' .. b.id)
  end
end
local function find(frame, id)
  for _, b in ipairs(frame.buttons or {}) do if b.id == id or b.id:sub(1, #id) == id then return b end end
end
local function text(frame)
  local rows = {}
  for i, row in ipairs(frame.rows) do rows[i] = row.text end
  return table.concat(rows, '\n')
end

-- The scene server with a display (or the scene's pocket, id 10) on the given role and state.
local function sceneView(role, id, w, h, state, keyboard)
  local s = S.new({ panel = true, shop = true, facts = true })
  local st = deliveries(s)
  s.env.SO.mods.health = role == 'panel' and { count = function() return 2 end } or nil
  s.panel.tick(0)
  if w then s.d.handlers.hello({ from = id, body = { w = w, h = h, keyboard = keyboard == true } }) end
  assert(s.d.assign(id, role))
  local session = s.D.sessions[id]
  if state then
    if role == 'panel' then session.panel = { page = 'shop', search = keyboard and s.sys.search or '' } else session.pocket = { page = 'shop', search = s.sys.search } end
    apply(st, state, role == 'panel' and session.panel or session.pocket)
  end
  return s, st, function() return s.view(id) end, session
end

-- The real delivery engine (tests/so/delivery.lua's fixture) with so-mod-panel on the same server.
local dim = 'minecraft:overworld'
local function engine(options)
  local net = H.new()
  net.time = 1000
  local m = net.machine({ id = 1, capacity = 16000000 })
  m.install({ 'so-store.lua', 'so-mod-build.lua', 'so-mod-shop.lua', 'so-ui.lua', 'so-plan.lua', 'so-mine-plan.lua', 'so-mod-panel.lua' })
  local cfg = { storageDeliveries = true, storageDeliveryOutput = 'room', storageDeliveryWorkers = { 2 } }
  for k, v in pairs(options or {}) do cfg[k] = v end
  m.files['so-server.cfg'] = H.encode(cfg)
  local store = m.env.dofile('so-store.lua')
  local f = { m = m, net = net, cfg = cfg, sends = {}, inv = {}, sourceStock = 0, destStock = 0, journal = 'j0', fuel = 10000,
    serial = 0, held = {}, callbacks = {}, screens = {}, paired = { [20] = true, [21] = true, [10] = true } }
  f.pose = { dim = dim, x = 0, y = 2, z = 0, facing = 1 }
  f.points = { { id = 'room', dim = 0, x = 2, y = 1, z = 0, side = 'down', kind = 'fuel' },
    { id = 'materials', dim = 0, x = 4, y = 1, z = 0, side = 'down', kind = 'storage' } }
  local function copy(v) return store.copy(v) end
  local function key(p) return p.x .. ',' .. p.y .. ',' .. p.z end
  m.env.SO = { store = store, now = function() return net.time end, breathe = function() end,
    pair = { key = function(id) return f.paired[id] and 'paired' or nil end }, mods = {} }
  local mods = m.env.SO.mods
  mods.state = { emit = function() return true end }
  f.screens.shop = { render = function() return { rows = {}, buttons = {} } end, input = function() end }
  mods.display = { screen = function(role, render, input)
    if render then f.screens[role] = { render = render, input = input } end
    return f.screens[role]
  end }
  mods.drops = { list = function() return copy(f.points) end, note = function() end }
  mods.cells = { owner = function(x, y, z) return f.held[x .. ',' .. y .. ',' .. z] end,
    handoff = function(from, to, x, y, z) local k = x .. ',' .. y .. ',' .. z if f.held[k] ~= from and f.held[k] ~= to then return false end f.held[k] = to return true end,
    reserveMany = function(who, cells)
      for _, p in ipairs(cells) do if f.held[key(p)] and f.held[key(p)] ~= who then return false end end
      for _, p in ipairs(cells) do f.held[key(p)] = who end return true
    end, releaseOwner = function(who) for k, v in pairs(f.held) do if v == who then f.held[k] = nil end end return true end }
  f.held[key(f.pose)] = 'gps:2'
  mods.lease = { status = function(id) return { open = f.queued and f.queued.worker == id and f.queued.id, parkBatch = true, setupFence = true,
      journal = f.journal, pose = { x = f.pose.x, y = f.pose.y, z = f.pose.z, f = f.pose.facing }, fuel = f.fuel } end,
    world = function() return copy(f.pose) end,
    restartReady = function() return true end,
    onReport = function(owner, cb) f.callbacks[owner] = cb end,
    assess = function(_, from, steps, opts)
      return PL.assess(from, steps, { clear = opts.clear and function() return true end or nil,
        admit = function(_, _, p) local who = f.held[key(p)] return not who or who == opts.who, 'held' end })
    end,
    send = function(id, steps, opts)
      f.serial = f.serial + 1
      f.queued = { id = 'lease-' .. f.serial, worker = id, steps = copy(steps), opts = copy(opts), intent = copy(opts.intent) }
      return f.queued.id
    end }
  local room = { state = 'settled', barrier = 1, highWater = 0 }
  m.env.rednet.send = function(id, body, protocol)
    f.sends[#f.sends + 1] = { id = id, body = copy(body), protocol = protocol }
    if body.cmd == 'stock' then return true end
    local answer = { v = 1, rid = body.rid, outputToken = body.outputToken, requestRid = room.requestRid, state = room.state, barrier = room.barrier }
    if body.cmd == 'output.claim' then
      if f.legacyRoom then answer.state, answer.error = 'refused', 'room support missing'
      elseif room.token or room.state ~= 'settled' then answer.state = 'busy'
      else room.token, room.state = body.outputToken, 'claimed' answer.state = 'claimed' end
    elseif body.cmd == 'get' or body.cmd == 'order' then
      room.highWater, room.requestRid, room.state = body.rid, body.rid, 'busy'
      if body.cmd == 'get' then f.sourceStock = f.sourceStock + body.n room.state = 'settled' room.barrier = room.barrier + 1 end
      answer[1] = 'Getting ' .. body.n .. ' ' .. body.text
      answer.requestRid, answer.state = room.requestRid, room.state
    elseif body.cmd == 'output.release' then
      room.token, room.requestRid = nil, nil answer.state = 'released'
    end
    f.replies = f.replies or {} f.replies[#f.replies + 1] = answer
    return true
  end
  f.flush = function()
    local replies = f.replies or {} f.replies = {}
    for _, reply in ipairs(replies) do f.shop.listen.roomsorter(9, reply) end
  end
  f.stock = function()
    f.shop.listen.roomsorter_stock(9, { totals = { ['minecraft:stone'] = 128, ['minecraft:ender_pearl'] = 40 },
      stacks = { ['minecraft:stone'] = 64, ['minecraft:ender_pearl'] = 16 } })
  end
  f.hello = function(id)
    f.build.handlers.hello({ from = id, body = { inv = copy(f.inv), journal = { id = f.journal, pose = { x = f.pose.x, y = f.pose.y, z = f.pose.z, f = f.pose.facing } },
      capabilities = { parkBatch = true, setupFence = true } } })
  end
  f.shop = m.env.dofile('so-mod-shop.lua') mods.shop = f.shop
  f.build = m.env.dofile('so-mod-build.lua') mods.build = f.build
  f.hello(2)
  f.shop.tick(net.time) f.build.tick() f.stock()
  f.panel = m.env.dofile('so-mod-panel.lua') mods.panel = f.panel
  f.panel.tick(0)
  f.step = function()
    net.time = net.time + 100
    f.shop.tick(net.time) f.build.tick() f.flush() f.stock() f.panel.tick(0)
    local q = f.queued
    if not q then return end
    f.queued = nil
    local results = {}
    for _, step in ipairs(q.steps) do
      local result = { ok = true }
      if step.op == 'gps' then result.data = copy(f.pose)
      elseif step.op == 'inspectDown' or step.op == 'inspect' then result.data = { name = 'minecraft:chest' }
      elseif step.op == 'select' then f.slot = step.slot
      elseif step.op == 'suckDown' or step.op == 'suck' then
        local n = math.min(step.n, f.sourceStock)
        result.ok = n > 0
        if n > 0 then f.inv[#f.inv + 1] = { slot = f.slot, name = 'minecraft:stone', count = n } f.sourceStock = f.sourceStock - n end
      elseif step.op == 'dropDown' or step.op == 'drop' then
        result.ok = not f.full
        if result.ok then
          for i, v in ipairs(f.inv) do if v.slot == f.slot then
            if f.pose.x == 4 then f.destStock = f.destStock + v.count else f.sourceStock = f.sourceStock + v.count end
            table.remove(f.inv, i) break
          end end
        end
      else f.pose = PL.apply(f.pose, step.op) end
      results[#results + 1] = result
    end
    f.journal = f.journal .. 'n'
    f.callbacks.build(q.id, q.worker, results, { intent = q.intent, report = { pose = { x = f.pose.x, y = f.pose.y, z = f.pose.z, f = f.pose.facing },
      journal = f.journal, inv = copy(f.inv), fuel = f.fuel } })
  end
  f.commands = function(cmd)
    local rows = {} for _, v in ipairs(f.sends) do if v.body.cmd == cmd then rows[#rows + 1] = v.body end end return rows
  end
  -- A paired panel (or pocket) session drawn at w x h; tap presses a control it drew last.
  f.session = function(id, role, w, h)
    local session = { id = id, isDisplay = true, w = w, h = h, keyboard = role == 'pocket' }
    if role == 'pocket' then session.pocket = { page = 'shop', search = '' } else session.panel = { page = 'main', search = '' } end
    local view = {}
    view.frame = function() view.last = f.screens[role].render(w, h, session) return view.last end
    view.tap = function(id2, frame)
      frame = frame or view.frame()
      local b = assert(find(frame, id2), 'no control ' .. id2 .. '\n' .. text(frame))
      f.screens[role].input({ id = b.id, x = b.x, y = b.y, from = id, session = session })
      return b.id
    end
    view.session = session
    return view
  end
  f.status = function(id) return f.build.deliveryStatus(id) end
  f.untilStage = function(id, done)
    for _ = 1, 600 do if done(f.status(id)) then return end f.step() end
    error('delivery did not reach the stage ' .. H.encode(f.status(id)))
  end
  return f
end

-- A panel on the SHOP page with the materials chest and stone picked.
local function picked(f, id)
  local v = f.session(id or 20, 'panel', 57, 24)
  v.tap('shop')
  v.tap('chest-next')
  v.tap('pick:minecraft:stone')
  return v
end

return function(test, equal)
  -- tests/ui/size-adapters.lua reads deliveries and apply as upvalues of this suite.
  local _ = { deliveries, apply }
  test('B5-U panel SHOP and pocket delivery pages match their fixtures through the real server path', function()
    local _, _, view = sceneView('panel', 21, 57, 24)
    match('panelshopnav-M', view())
    for _, case in ipairs({ { 'panelshop-M', 57, 24, 'scene' }, { 'panelshop-S', 29, 12, 'scene' }, { 'panelshopnone-M', 57, 24, 'none' },
        { 'panelshopordered-M', 57, 24, 'ordered' }, { 'panelshop-XS', 15, 10, 'ordered' }, { 'panelshopheld-M', 57, 24, 'held' }, { 'panelshopbusy-L', 39, 19, 'busy' } }) do
      local _, _, v = sceneView('panel', 22, case[2], case[3], case[4])
      match(case[1], v())
    end
    local _, st, v, session = sceneView('panel', 23, 29, 12, 'deliver', true)
    match('panelshopkey-S', v())
    assert(st and session.keyboard)
    for _, case in ipairs({ { 'pocket-shopdeliver-P', 'deliver' }, { 'pocket-shoprefused-P', 'refused' }, { 'pocket-shoproom-P', 'room' } }) do
      local _, _, v = sceneView('pocket', 10, nil, nil, case[2])
      match(case[1], v())
    end
  end)

  test('B5-U a final result stays visible while its own output row settles; another holder shows BUSY', function()
    local _, st, view, session = sceneView('panel', 22, 57, 24, 'refused')
    st.outputs[1] = { kind = 'delivery', ownerId = 'delivery-1', state = 'quarantined' }
    local frame = view()
    assert(text(frame):find('REFUSED 16 IRON INGOT', 1, true) and not find(frame, 'deliver:'), text(frame))
    st.outputs[1] = { kind = 'fuel', ownerId = 'fuel:0/0/1/0', state = 'ordering' }
    frame = view()
    assert(text(frame):find('BUSY fuel ordering', 1, true) and not find(frame, 'deliver:'), text(frame))
    st.outputs[1] = nil
    session.panel.delivery = nil
    frame = view()
    assert(find(frame, 'deliver:16:workshop:') and not text(frame):find('BUSY', 1, true), text(frame))
  end)

  test('B5-U a 10-row panel and a 12-row keyboard panel fit the picked item, its chips, status and BACK', function()
    for _, case in ipairs({ { 15, 10 }, { 57, 10 }, { 29, 11 }, { 57, 12, true }, { 29, 12, true }, { 26, 12, true } }) do
      local _, _, view = sceneView('panel', 24, case[1], case[2], 'ordered', case[3])
      local frame = view()
      local item = case[3] and 'pick:minecraft:iron_ingot' or 'pick:minecraft:gold_ingot'
      local name = case[1] .. 'x' .. case[2] .. (case[3] and ' keyboard' or '')
      assert(find(frame, item) and find(frame, 'panel-back') and find(frame, 'next'), name .. '\n' .. text(frame))
      assert(text(frame):find('ORDERED 16', 1, true), name .. '\n' .. text(frame))
      -- Live chips once the output is free.
      local s, st, v2 = sceneView('panel', 25, case[1], case[2], 'scene', case[3])
      frame = v2()
      local chip = find(frame, 'deliver:16:workshop:1:')
      assert(chip and find(frame, 'deliver:stack:') and find(frame, 'deliver:all:'), name .. '\n' .. text(frame))
      s.tap(25, chip.id)
      equal(#st.requests, 1, name)
      -- Every item of the list is reachable by paging, one page at a time.
      local seen = {}
      for _ = 1, 12 do
        for _, b in ipairs(v2().buttons) do if b.id:match('^pick:') then seen[b.id] = true end end
        s.tap(25, 'next')
      end
      local n = 0 for _ in pairs(seen) do n = n + 1 end
      equal(n, case[3] and 8 or 9, name .. ' reachable items')
    end
  end)

  test('B5-U a refused tap during another display\'s delivery still shows that delivery and its RETRY', function()
    local f = engine()
    f.full = true
    local a, b = picked(f, 20), picked(f, 21)
    local chip = find(b.frame(), 'deliver:16:materials:')
    a.tap('deliver:16:materials:')
    local id = a.session.panel.delivery.id
    -- b taps the chip it drew before a's request: the engine refuses it.
    f.screens.panel.input({ id = chip.id, x = chip.x, y = chip.y, from = 21, session = b.session })
    equal(b.session.panel.delivery.id, nil)
    equal(b.session.panel.delivery.why, 'delivery busy')
    local frame = b.frame()
    assert(text(frame):find('ORDERED 16 STONE', 1, true) and not text(frame):find('NOT SENT', 1, true), text(frame))
    f.untilStage(id, function(st) return st.stage == 'held' end)
    frame = b.frame()
    assert(text(frame):find('HELD 16 STONE', 1, true) and find(frame, 'deliver-retry:' .. id), text(frame))
    local retries, retry = 0, f.build.deliveryRetry
    f.build.deliveryRetry = function(...) retries = retries + 1 return retry(...) end
    b.tap('deliver-retry:' .. id, frame)
    equal(retries, 1)
  end)

  test('B5-U schematic generator reproduces the delivery fixtures', function()
    local started, pipe = pcall(io.popen, 'pwd')
    local root = started and pipe and pipe:read('*l')
    if started and pipe then pipe:close() end
    if not root or root:sub(1, 1) ~= '/' or not os.execute('python3 -V > /dev/null 2>&1') then
      return dofile('tests/skips.lua').record('B5-U schematic generator', 'needs host processes, a POSIX shell and python3')
    end
    local function read(path) local file = assert(io.open(path, 'rb')) local data = file:read('*a') file:close() return data end
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "'"))
    assert(os.execute("python3 -I '" .. root .. "/docs/ui/schematic/screens.py' --fixtures '" .. dir .. "' > /dev/null"))
    for name, path in pairs(FIXTURE) do equal(read(dir .. '/' .. name .. '.txt'), read(path), name) end
    assert(os.execute("rm -r '" .. dir .. "'"))
  end)

  test('B5-U with storageDeliveries off no delivery control is drawn and nothing is saved', function()
    local f = engine({ storageDeliveries = false })
    local panel, pocket = f.session(20, 'panel', 57, 24), f.session(10, 'pocket', 26, 20)
    assert(not find(panel.frame(), 'shop'), 'no SHOP chip')
    f.screens.panel.input({ id = 'shop', x = 1, y = 1, from = 20, session = panel.session })
    equal(panel.session.panel.page, 'main')
    pocket.session.pocket.chest = { id = 'materials', dim = 0, x = 4, y = 1, z = 0, side = 'down', kind = 'storage' }
    local frame = pocket.frame()
    assert(not find(frame, 'chest-next') and not find(frame, 'deliver:'), 'no chest or delivery chips')
    assert(find(frame, 'order:1:'), 'room orders stay as they were')
    for _ = 1, 5 do f.step() end
    assert(not f.m.files['so-data/shop-output'], 'the panel read saved no output state')
    equal(#f.commands('output.claim'), 0)
  end)

  test('B5-U one drawn attempt token sends one delivery; ORDERED stays until the confirmed deposit', function()
    local f = engine()
    local v = picked(f)
    local frame = v.frame()
    assert(text(frame):find('to materials 4 1 0', 1, true), text(frame))
    local id = v.tap('deliver:16:materials:', frame)
    local own = assert(v.session.panel.delivery.id, v.session.panel.delivery.why)
    equal(#f.commands('output.claim'), 1)
    -- The same drawn chip again, as a double tap or a late packet, sends nothing.
    f.screens.panel.input({ id = id, x = find(frame, id).x, y = find(frame, id).y, from = 20, session = v.session })
    equal(v.session.panel.delivery.id, own)
    equal(#f.commands('output.claim'), 1)
    assert(not find(v.frame(), 'deliver:'), 'chips are grey while the delivery holds the output')
    f.untilStage(own, function(st) return st.orderRid end)
    assert(#f.commands('get') == 1 and f.commands('get')[1].n == 16 and f.commands('get')[1].text == 'minecraft:stone')
    -- "Getting..." has arrived: still only requested.
    assert(text(v.frame()):find('ORDERED 16 STONE', 1, true), text(v.last))
    assert(not text(v.last):find('DELIVERED', 1, true))
    f.untilStage(own, function(st) return st.deposited == 16 end)
    assert(text(v.frame()):find('DELIVERED 16 STONE', 1, true), text(v.last))
    equal(f.destStock, 16)
    f.untilStage(own, function(st) return st.stage == 'complete' end)
    frame = v.frame()
    assert(text(frame):find('DELIVERED 16 STONE', 1, true) and find(frame, 'deliver:16:materials:'), 'a new token after the output is released')
    assert(find(frame, 'deliver:16:materials:').id ~= id, 'the spent token is not drawn again')
  end)

  test('B5-U a held delivery offers RETRY once; a refused claim is final', function()
    local f = engine()
    f.full = true
    local v = picked(f)
    v.tap('deliver:16:materials:')
    local own = v.session.panel.delivery.id
    f.untilStage(own, function(st) return st.stage == 'held' end)
    local frame = v.frame()
    assert(text(frame):find('HELD 16 STONE', 1, true) and text(frame):find('delivery chest full', 1, true), text(frame))
    local retries, retry = 0, f.build.deliveryRetry
    f.build.deliveryRetry = function(...) retries = retries + 1 return retry(...) end
    v.tap('deliver-retry:' .. own, frame)
    equal(retries, 1)
    -- Another panel sees the held delivery holding the room output and cannot order.
    local other = picked(f, 21)
    frame = other.frame()
    assert(text(frame):find('HELD 16 STONE', 1, true) and not find(frame, 'deliver:'), text(frame))

    local g = engine()
    g.legacyRoom = true
    local w = picked(g)
    w.tap('deliver:16:materials:')
    local id = w.session.panel.delivery.id
    g.untilStage(id, function(st) return st.stage == 'refused' end)
    frame = w.frame()
    assert(text(frame):find('REFUSED 16 STONE', 1, true) and text(frame):find('room support missing', 1, true), text(frame))
    assert(not find(frame, 'deliver-retry:'), 'a refused delivery is final')
  end)

  test('B5-U chest, count and display are checked again before the request', function()
    local f = engine()
    local v = picked(f)
    local frame = v.frame()
    local b = find(frame, 'deliver:16:materials:')
    -- The chest moved between the frame and the tap: the drawn chip asks for nothing.
    f.points[2].x = 5
    f.screens.panel.input({ id = b.id, x = b.x, y = b.y, from = 20, session = v.session })
    equal(v.session.panel.delivery.why, 'chest moved')
    equal(#f.commands('output.claim'), 0)
    frame = v.frame()
    assert(text(frame):find('materials moved', 1, true) and not find(frame, 'deliver:'), text(frame))
    -- The spent chip again, not drawn in this frame, does nothing.
    v.session.panel.delivery = nil
    f.screens.panel.input({ id = b.id, x = b.x, y = b.y, from = 20, session = v.session })
    equal(v.session.panel.delivery, nil)
    f.points[2].x = 4
    -- One stack at most: ender pearls stack to 16, so 64 is grey and a forged 64 sends nothing.
    local p = f.session(10, 'pocket', 26, 20)
    p.tap('chest-next')
    p.tap('pick:minecraft:ender_pearl')
    frame = p.frame()
    assert(find(frame, 'deliver:16:materials:') and not find(frame, 'deliver:64:'), text(frame))
    local token = find(frame, 'deliver:16:materials:').id:match('^deliver:16:materials:(%d+):')
    f.screens.pocket.input({ id = 'deliver:64:materials:' .. token .. ':minecraft:ender_pearl', from = 10, session = p.session })
    equal(p.session.pocket.delivery.why, 'bad count')
    equal(#f.commands('output.claim'), 0)
    -- An unpaired display draws grey chips and its taps do nothing.
    f.paired[10] = nil
    frame = p.frame()
    assert(not find(frame, 'deliver:') and find(frame, 'pick:'), 'untrusted display')
    p.session.pocket.delivery = nil
    f.screens.pocket.input({ id = 'deliver:16:materials:' .. p.session.pocket.attempt .. ':minecraft:ender_pearl', from = 10, session = p.session })
    equal(p.session.pocket.delivery, nil)
    equal(#f.commands('output.claim'), 0)
  end)

  test('B5-U the pocket steps from the room output to a chest and SHOP closes with its switch', function()
    local f = engine()
    local v = f.session(10, 'pocket', 26, 20)
    v.tap('pick:minecraft:stone')
    local frame = v.frame()
    assert(text(frame):find('to room output', 1, true) and find(frame, 'order:16:minecraft:stone'), text(frame))
    v.tap('chest-next')
    frame = v.frame()
    assert(find(frame, 'deliver:16:materials:') and not find(frame, 'order:16:'), text(frame))
    v.tap('deliver:all:materials:', frame)
    equal(f.status(v.session.pocket.delivery.id).n, 64)
    v.tap('chest-next')
    equal(v.session.pocket.chest, nil)
    -- Switching deliveries off closes the panel's SHOP page and its chips.
    local p = picked(f, 21)
    f.m.files['so-server.cfg'] = H.encode({ storageDeliveries = false })
    f.panel.tick(0)
    frame = p.frame()
    equal(p.session.panel.page, 'main')
    assert(not find(frame, 'shop') and not find(frame, 'deliver:'))
  end)
end
