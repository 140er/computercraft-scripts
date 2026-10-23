local function setup(phase, fuel, inv)
  local job = { dim = 'minecraft:overworld', spots = {}, running = true, phase = phase or 'scan', cursor = 1,
    area = { x1 = 0, x2 = 2, z1 = 0, z2 = 0 }, ground = 0, saplings={x=251,y=1,z=0,side="down"}, fuel = fuel or 1000, inv = inv or {},
    tree = { x = 0, z = 0, kind = 'minecraft:oak_log' },
    turtle = { id = 2, pose = { dim = 'minecraft:overworld', x = 0, y = 2, z = 0, facing = 1 },
      frame = { dim = 'minecraft:overworld', ox = 0, oy = 0, oz = 0, rot = 0 } } }
  local callback, render, input, queued, events, serial = nil, nil, nil, nil, {}, 0
  local env = setmetatable({ os = { epoch = function() return 0 end }, SO = { now = function() return 0 end, store = { store = function() return { value = job, save = function() return true end } end }, mods = {
    cells = { reserveMany = function() return true end, releaseOwner = function() end },
    state = { emit = function(kind, data) events[#events + 1] = { kind = kind, data = data } end, canStart = function() return true end },
    drops = { list=function() return {{id="ready",dim=0,x=250,y=1,z=0,kind="any"}} end, pick = function(kind) return { point = { id = 1, x = 250, y = 1, z = 0, side = 'down', kind = kind } } end },
    display = { screen = function(_, r, i) render, input = r, i end },
    lease = { status = function() return { open = queued ~= nil, pos = job.turtle.pose, range = 10000 } end,
      inRange = function() return true end,
      onReport = function(_, fn) callback = fn end,
      send = function(_, steps, opts) serial = serial + 1 queued = { id = serial, steps = steps, opts = opts } return serial end },
  } } }, { __index = _G })
  local mod = assert(loadfile('so-mod-lumber.lua', 't', env))()
  local function report(fail, custom)
    local q = assert(queued) queued = nil
    local results = {}
    for i, step in ipairs(q.steps) do results[i] = { ok = not fail, data = step.op == 'inspectDown' and { name = 'minecraft:oak_log', tags = { ['minecraft:logs'] = true } } or nil } end
    results = custom or results
    local pose = job.turtle.pose
    local P = dofile('so-plan.lua')
    for i, step in ipairs(q.steps) do if results[i].ok then pose = P.apply(pose, step.op) end end
    callback(q.id, 2, results, { report = { pose = { x = pose.x, y = pose.y, z = pose.z, f = pose.facing }, fuel = job.fuel, inv = job.inv } })
    return q
  end
  mod.tick(0) report(false)
  return { job = job, tick = mod.tick, report = report, queued = function() return queued end,
    expire = function() local q = assert(queued) queued = nil callback(q.id, 2, nil, {}) end,
    render = function() return render() end, input = function(text) input({ text = text }) end, events = events, mods = env.SO.mods, env = env }
end
return setup
