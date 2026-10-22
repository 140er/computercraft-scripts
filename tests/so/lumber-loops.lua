local function setup(phase, fuel, inv)
  local job = { dim = 'minecraft:overworld', spots = {}, running = true, phase = phase or 'scan', cursor = 1,
    area = { x1 = 0, x2 = 2, z1 = 0, z2 = 0 }, ground = 0, fuel = fuel or 1000, inv = inv or {},
    tree = { x = 0, z = 0, kind = 'minecraft:oak_log' },
    turtle = { id = 2, pose = { dim = 'minecraft:overworld', x = 0, y = 2, z = 0, facing = 1 },
      frame = { dim = 'minecraft:overworld', ox = 0, oy = 0, oz = 0, rot = 0 } } }
  local callback, render, input, queued, events, serial = nil, nil, nil, nil, {}, 0
  local env = setmetatable({ os = { epoch = function() return 0 end }, SO = { store = { store = function() return { value = job, save = function() return true end } end }, mods = {
    cells = { reserveMany = function() return true end, releaseOwner = function() end },
    state = { emit = function(kind, data) events[#events + 1] = { kind = kind, data = data } end },
    drops = { pick = function(kind) return { point = { id = 1, x = 250, y = 1, z = 0, side = 'down', kind = kind } } end },
    display = { screen = function(_, r, i) render, input = r, i end },
    lease = { status = function() return { open = queued ~= nil, pos = job.turtle.pose, range = 10000 } end,
      inRange = function() return true end,
      onReport = function(_, fn) callback = fn end,
      send = function(_, steps, opts) serial = serial + 1 queued = { id = serial, steps = steps, opts = opts } return serial end },
  } } }, { __index = _G })
  local mod = assert(loadfile('so-mod-lumber.lua', 't', env))()
  local function report(fail)
    local q = assert(queued) queued = nil
    local results = {}
    for i, step in ipairs(q.steps) do results[i] = { ok = not fail, data = step.op == 'inspectDown' and { name = 'minecraft:oak_log', tags = { ['minecraft:logs'] = true } } or nil } end
    callback(q.id, 2, results, { report = { pose = { x = 0, y = 2, z = 0, f = 1 }, fuel = job.fuel, inv = job.inv } })
    return q
  end
  mod.tick(0) report(false)
  return { job = job, tick = mod.tick, report = report, queued = function() return queued end,
    render = function() return render() end, input = function(text) input({ text = text }) end, events = events }
end
return function(test, equal)
  test('lumber stops after three failed base digs and names start on screen', function()
    local s = setup('base')
    for _ = 1, 3 do s.tick(1) s.report(false) s.report(true) end
    assert(s.job.blocked, 'failed digs must hold')
    assert(s.job.alert:find('start', 1, true), 'hold must explain recovery')
    equal(s.events[#s.events].kind, 'lumber.alert')
    s.tick(2)
    equal(s.queued().steps[1].op, 'inspectDown')
  end)
  test('lumber reserves fuel for the actual chest distance', function()
    local s = setup('scan', 200)
    s.tick(1)
    assert(s.job.service and s.job.service.kind == 'fuel', '250 block fuel trip must start before 80 fuel')
  end)
  test('lumber clears junk when all inventory slots contain apples', function()
    local inv = {}
    for i = 1, 16 do inv[i] = { slot = i, name = 'minecraft:apple', count = 64 } end
    local s = setup('scan', 1000, inv)
    s.tick(1)
    local q = s.queued()
    assert(s.job.service and s.job.service.kind == 'wood', 'full junk inventory must be cleaned at wood chest')
  end)
end
