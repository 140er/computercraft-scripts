return function(test, equal)
  local setup = dofile('tests/so/lumber-fixture.lua')
  local function fixture(kind)
    local f = setup('scan', 1000, { { slot = 1, name = 'minecraft:oak_log', count = 8 } })
    local store = f.env.SO.store.store
    f.env.SO.store.store = function() return { save = function() return true end } end
    f.mods.drops = assert(loadfile('so-mod-drops.lua', 't', f.env))()
    f.env.SO.store.store = store
    assert(f.mods.drops.add({ id = kind, dim = 0, x = 0, y = 1, z = 0, side = 'down', kind = kind == 'saplings' and 'storage' or kind }))
    f.job.service = { kind = kind, point = { id = kind, dim = f.job.dim, x = 0, y = 1, z = 0, side = 'down' },
      access = f.job.turtle.pose, stage = 'travel', resume = 'scan' }
    return f
  end
  test('lumber counts only successful log drops', function()
    for _, success in ipairs({ false, true }) do
      local f = fixture('wood')
      f.tick(1)
      f.job.inv = {}
      f.report(false, { { ok = true }, { ok = true, data = { name = 'minecraft:chest' } }, { ok = success } })
      equal(f.job.logs or 0, success and 8 or 0)
      if not success then equal(f.job.blocked, 'hold') end
    end
  end)
  test('lumber marks failed wood inspections broken without counting lost logs', function()
    local f = fixture('wood')
    for i = 1, 3 do
      f.job.blocked = nil
      f.job.inv = { { slot = 1, name = 'minecraft:oak_log', count = 8 } }
      f.tick(i)
      f.job.inv = {}
      f.report(false, { { ok = true }, { ok = false }, { ok = false } })
    end
    equal(f.mods.drops.list()[1].broken, true)
    equal(f.job.logs or 0, 0)
  end)
  for _, kind in ipairs({ 'fuel', 'saplings' }) do
    test('lumber checks ' .. kind .. ' chest before taking supplies', function()
      local f = fixture(kind)
      for i = 1, 3 do
        f.job.blocked, f.job.service.stage = nil, 'travel'
        f.tick(i)
        local q = assert(f.queued())
        equal(#q.steps, 1)
        equal(q.steps[1].op, 'inspectDown')
        f.report(false, { { ok = false } })
        equal(f.job.blocked, 'hold')
        equal(f.queued(), nil)
      end
      equal(f.mods.drops.list()[1].broken, true)
    end)
  end
  test('lumber registers sapling chest for inspection failures', function()
    local f = fixture('wood')
    f.job.service, f.job.inv, f.job.phase = nil, {}, 'plant'
    f.input('saplings 4 1 0 down')
    f.tick(1)
    local point = f.job.service.point
    assert(point.id, 'sapling service needs a registered drop point')
    local found
    for _, p in ipairs(f.mods.drops.list()) do if p.id == point.id then found = p end end
    assert(found and found.kind == 'storage' and found.x == 4)
  end)
end
