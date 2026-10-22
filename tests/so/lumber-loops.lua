local setup = dofile('tests/so/lumber-fixture.lua')
return function(test, equal)
  test('lumber stops after three failed base digs and names start on screen', function()
    local s = setup('base')
    for _ = 1, 3 do s.tick(1) s.report(false) s.report(true) end
    assert(s.job.blocked, 'failed digs must hold')
    assert(s.job.alert:find('start', 1, true), 'hold must explain recovery')
    equal(s.events[#s.events].kind, 'lumber.alert')
    s.tick(2)
    equal(s.queued().steps[1].op, 'inspectDown')
    s.report(false)
    s.input('start')
    assert(not s.job.blocked and not s.job.failures, 'start must clear retry hold')
    s.tick(3)
    s.report(false)
    s.tick(4)
    s.report(false)
    s.report(true)
    assert(not s.job.blocked, 'first new failure must not immediately hold')
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
  test('lumber stops after failed travel movement despite successful inspections', function()
    local s = setup('scan')
    s.job.cursor = 2
    for _ = 1, 3 do s.tick(1) s.report(false) s.report(true) end
    assert(s.job.blocked, 'mob-blocked moves must hold')
    assert(s.job.alert:find('forward failed', 1, true))
  end)
  test('lumber stops after failed ascent digs and moves', function()
    for _, failedIndex in ipairs({ 1, 2 }) do
      local s = setup('climb')
      for _ = 1, 3 do
        s.tick(1)
        s.report(false, { { ok = true, data = { name = 'minecraft:oak_log', tags = { ['minecraft:logs'] = true } } } })
        s.report(false, { { ok = failedIndex ~= 1 }, { ok = failedIndex ~= 2 } })
      end
      assert(s.job.blocked, 'failed ascent must hold')
    end
  end)

  test('lumber drops excess saplings but keeps one for each known spot', function()
    local s = setup('scan', 1000, { { slot = 1, name = 'minecraft:oak_sapling', count = 64 },
      { slot = 2, name = 'minecraft:birch_sapling', count = 8 } })
    s.job.spots = { ['0,0'] = { kind = 'minecraft:oak_log' }, ['1,0'] = { kind = 'minecraft:oak_log' } }
    s.job.service = { kind = 'wood', point = { side = 'down' }, stage = 'drop' }
    s.tick(1)
    local q = s.queued()
    equal(q.steps[1].slot, 1)
    equal(q.steps[3].n, 62)
    equal(q.steps[3].op, 'dropDown')
    s.job.inv[1].count = 2
    s.report(false)
    s.tick(2)
    equal(s.queued().steps[1].slot, 2)
    equal(s.queued().steps[3].n, 8)
    s.report(true)
    assert(s.job.blocked, 'failed junk drop must hold instead of looping')
  end)

  test('lumber unloads a full log inventory during a climb', function()
    local inv = {}
    for i = 1, 16 do inv[i] = { slot = i, name = 'minecraft:oak_log', count = 64 } end
    local s = setup('climb', 1000, inv)
    s.tick(1)
    assert(s.job.service and s.job.service.kind == 'wood')
    equal(s.job.service.resume, 'climb')
  end)
  test('lumber clears a single junk stack at the end of a round', function()
    local s = setup('roundEnd', 1000, { { slot = 1, name = 'minecraft:stick', count = 1 } })
    s.tick(1)
    assert(s.job.service and s.job.service.kind == 'wood')
  end)

end
