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
      if not success then
        equal(f.job.blocked, 'hold')
        equal(f.job.alert,'wood #wood full at 0,1,0')
        for _, event in ipairs(f.events) do assert(event.kind ~= 'lumber.logs') end
      end
    end
  end)
  test('lumber holds without delivery credit when worker reports no inventory', function()
    local f = fixture('wood')
    f.tick(1)
    f.report(false, { { ok = true }, { ok = true, data = { name = 'minecraft:stone' } },
      { ok = false, err = 'no inventory' } })
    equal(f.job.logs or 0, 0)
    equal(f.job.inv[1].count, 8)
    equal(f.job.blocked, 'hold')
    for _, event in ipairs(f.events) do assert(event.kind ~= 'lumber.logs') end
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
    equal(f.job.alert,'wood #wood broken at 0,1,0')
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
        equal(f.job.alert,kind..' #'..kind..' broken at 0,1,0')
        equal(f.queued(), nil)
      end
      equal(f.mods.drops.list()[1].broken, true)
    end)
  end
  test('lumber rechecks supply service saved before inspection support', function()
    local f = fixture('fuel')
    f.job.service.stage = 'suck'
    f.tick(1)
    equal(f.queued().steps[1].op, 'inspectDown')
    equal(#f.queued().steps, 1)
  end)
  test('lumber takes supplies after a successful inspection and clears strikes', function()
    local f = fixture('fuel')
    assert(f.mods.drops.note('fuel', nil))
    assert(f.mods.drops.note('fuel', nil))
    f.tick(1)
    f.report(false, { { ok = true, data = { name = 'minecraft:chest' } } })
    equal(f.job.service.stage, 'take')
    f.tick(2)
    equal(f.queued().steps[2].op, 'suckDown')
    assert(f.mods.drops.note('fuel', nil))
    equal(f.mods.drops.list()[1].broken, false)
  end)
  for _,kind in ipairs({'wood','fuel','saplings'}) do
    test('lumber names missing and marked broken '..kind..' chests',function()
      local f=fixture(kind)
      f.job.service=nil
      local state
      for i=1,20 do local name,value=debug.getupvalue(f.tick,i) if name=='S' then state=value break end end
      assert(state)
      if kind=='saplings' then f.job.saplings={x=0,y=1,z=0,side='down'} end
      for _=1,3 do assert(f.mods.drops.note(kind,nil)) end
      assert(not state.service(kind))
      equal(f.job.alert,kind..' #'..kind..' broken at 0,1,0')
      assert(f.mods.drops.remove(kind))
      if kind=='saplings' then f.job.saplings=nil end
      assert(not state.service(kind))
      equal(f.job.alert,'no '..kind..' chest set')
    end)
  end
  for _,kind in ipairs({'fuel','saplings'}) do
    test('lumber names an inspected empty '..kind..' chest',function()
      local f=fixture(kind)
      f.tick(1) f.report(false,{{ok=true,data={name='minecraft:chest'}}})
      f.tick(2) f.report(false,{{ok=true},{ok=false,err='No items to take'}})
      equal(f.job.alert,kind..' #'..kind..' empty at 0,1,0')
      equal(f.mods.drops.list()[1].broken,false)
      equal(f.events[#f.events].data.reason,'empty')
      equal(f.events[#f.events].data.point.id,kind)
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
    local count = #f.mods.drops.list()
    f.job.service = nil
    f.tick(2)
    equal(f.job.service.point.id, point.id)
    equal(#f.mods.drops.list(), count)
  end)
  test('lumber distinguishes successful wrong saplings from an empty chest',function()
    local f=fixture('saplings')
    f.tick(1) f.report(false,{{ok=true,data={name='minecraft:chest'}}})
    f.tick(2)
    f.job.inv={}
    for slot=1,16 do f.job.inv[slot]={slot=slot,name='minecraft:birch_sapling',count=64} end
    f.report(false,{{ok=true},{ok=true}})
    equal(f.job.alert,'saplings #saplings wrong saplings; inventory full at 0,1,0')
    equal(f.job.noSaplings,true)
  end)
  for _,kind in ipairs({'wood','fuel','saplings'}) do
    test('lumber distinguishes no inventory at '..kind..' chests',function()
      local f=fixture(kind)
      if kind=='wood' then
        f.tick(1)
        f.report(false,{{ok=true},{ok=true,data={name='minecraft:ender_chest'}},{ok=false,err='no inventory'}})
      else
        f.tick(1) f.report(false,{{ok=true,data={name='minecraft:ender_chest'}}})
        f.tick(2) f.report(false,{{ok=true},{ok=false,err='no inventory'}})
      end
      equal(f.job.alert,kind..' #'..kind..' no inventory at 0,1,0')
    end)
  end

end
