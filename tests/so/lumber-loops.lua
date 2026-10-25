local fixture = dofile('tests/so/lumber-fixture.lua')
local function setup(...)
  local s = fixture(...)
  s.mods.drops.choose = s.mods.drops.pick
  return s
end

local function scanner(enabled)
  local s = setup('waiting')
  s.row.tree = nil
  s.job.visited, s.job.nextRound = { true, true, true }, 600000
  s.env.SO.store.read = function() return { lumberScan = enabled } end
  s.mods.display.screen = function(_, render, input)
    s.draw, s.tap = render, function(id) input({ id = id }) end
    s.input = function(text) input({ text = text }) end
  end
  s.tick = assert(loadfile('so-mod-lumber.lua', 't', s.env))().tick
  s.tick(0)
  s.report(false)
  return s
end

local function realDrops(s)
  local store = s.env.SO.store.store
  s.env.SO.store.store = function() return { save = function() return true end } end
  s.mods.drops = assert(loadfile('so-mod-drops.lua', 't', s.env))()
  s.env.SO.store.store = store
end


local function copy(v)
  if type(v) ~= 'table' then return v end
  local out={} for k,x in pairs(v) do out[k]=copy(x) end return out
end
local function controls(s, config)
  s.env.SO.store.copy=copy
  s.env.SO.store.read=function() return config or {} end
  s.mods.display.screen=function(_,render,input)
    s.draw=render
    s.press=function(id,session) input({id=id,session=session}) end
    s.input=function(text) input({text=text}) end
  end
  local mod=assert(loadfile('so-mod-lumber.lua','t',s.env))()
  s.tick=mod.tick s.mod=mod s.tick(0) s.report(false)
  return s
end

return function(test, equal)
  test('lumber SCAN is off by default and rejects the command without resetting a round', function()
    local s = scanner()
    s.input('scan')
    equal(s.job.scanRequested, nil)
    equal(s.job.visited, { true, true, true })
    equal(s.job.nextRound, 600000)
    for _, b in ipairs(s.draw(26, 20).buttons) do assert(b.id ~= 'scan') end
  end)

  test('lumber SCAN preserves an active claim through replanting then finds a new tree', function()
    local s = scanner(true)
    local tree = { x = 0, z = 0, kind = 'minecraft:oak_log' }
    local target = { dim = s.job.dim, x = 0, y = 2, z = 0, index = 1 }
    s.row.tree, s.row.target, s.row.phase = tree, target, 'base'
    s.row.inv = { { slot = 1, name = 'minecraft:oak_sapling', count = 1 } }
    s.job.spots['0,0'] = { kind = tree.kind }
    s.tick(1)
    local pending = s.row.pending
    s.tap('scan')
    s.tap('scan')
    s.tick(2)
    equal(s.row.pending, pending)
    equal(s.row.target, target)
    equal(s.row.tree, tree)
    equal(s.job.scanRequested, true)
    equal(s.job.visited, { true, true, true })
    s.report(false, { { ok = false } })
    s.tick(3)
    s.report(false, { { ok = false } })
    s.tick(4)
    s.tick(5)
    s.report(false, { { ok = true, data = { name = 'minecraft:oak_sapling' } } })
    equal(s.row.tree, nil)
    equal(s.job.scanRequested, true)
    s.tick(6)
    equal(s.job.scanRequested, nil)
    equal(s.job.nextRound, nil)
    equal(s.job.visited, {})
    s.report(false, { { ok = true }, { ok = false }, { ok = true }, { ok = true },
      { ok = false }, { ok = true }, { ok = true, data = { name = 'minecraft:oak_sapling' } } })
    for n = 7, 12 do
      s.tick(n)
      local q = s.queued()
      if q then
        if s.row.pending.action == 'scan' then
          s.report(false)
          break
        end
        local results = {}
        for i, step in ipairs(q.steps) do results[i] = { ok = not step.op:match('^inspect') } end
        s.report(false, results)
      end
    end
    equal(s.row.phase, 'base')
    equal(s.row.tree.x, 1)
    equal(s.row.tree.kind, 'minecraft:oak_log')
    equal(s.job.scanRequested, nil)
  end)

  test('lumber SCAN waits for blocked claims and keeps idle workers from claiming more cells', function()
    local s = scanner(true)
    local held = { x = 2, z = 0, kind = 'minecraft:birch_log' }
    s.job.turtles['3'] = { turtle = { id = 3, pose = { dim = s.job.dim, x = 2, y = 2, z = 0 } },
      tree = held, phase = 'base', blocked = 'lost', idlePark = true, parkAt = 0 }
    s.row.phase = 'scan'
    local release = 0
    s.mods.cells.releaseOwner = function() release = release + 1 end
    s.tap('scan')
    s.tick(1)
    equal(s.job.scanRequested, true)
    equal(s.job.turtles['3'].tree, held)
    equal(s.row.target, nil)
    equal(release, 0)
    equal(s.row.pending, nil)
    equal(s.row.idlePark, true)
  end)

  test('lumber SCAN waits for service and survives a server reload', function()
    local s = scanner(true)
    s.row.service = { kind = 'wood', stage = 'return', resume = 'waiting',
      back = s.row.turtle.pose, point = { x = 250, y = 1, z = 0, side = 'down' } }
    s.row.blocked = 'hold'
    s.tap('scan')
    local visited = s.job.visited
    s.tick(1)
    equal(s.job.scanRequested, true)
    equal(s.job.visited, visited)
    s.tick = assert(loadfile('so-mod-lumber.lua', 't', s.env))().tick
    s.tick(2)
    equal(s.job.scanRequested, true)
    s.report(false)
    s.row.blocked = nil
    s.tick(3)
    equal(s.row.service, nil)
    equal(s.job.scanRequested, true)
    s.tick(4)
    equal(s.job.scanRequested, nil)
    equal(s.row.phase, 'scan')
  end)

  test('lumber SCAN leaves a stopped job and existing alerts unchanged', function()
    local s = scanner(true)
    s.job.running, s.job.alert = false, 'saved hold'
    s.tap('scan')
    equal(s.job.scanRequested, nil)
    equal(s.job.running, false)
    equal(s.job.alert, 'saved hold')
    s.job.running = true
    s.tap('scan')
    equal(s.job.scanRequested, true)
    equal(s.job.alert, 'saved hold')
    equal(#s.events, 0)
  end)

  test('lumber SCAN finishes round-end cleanup before restarting the scan', function()
    local s = scanner(true)
    s.row.phase = 'roundEnd'
    s.tap('scan')
    s.tick(1)
    equal(s.job.scanRequested, true)
    equal(s.row.phase, 'waiting')
    s.tick(2)
    equal(s.job.scanRequested, nil)
    equal(s.job.nextRound, nil)
    equal(s.row.phase, 'scan')
    equal(s.row.pending.action, 'scan')
  end)

  test('lumber SCAN finds a bone-mealed tree beside the lane before its grow timer', function()
    local s = scanner(true)
    s.job.area.z2 = 2
    s.row.turtle.pose.z = 1
    s.job.spots['0,0'] = { kind = 'minecraft:oak_log', plantedAt = 1 }
    s.tap('scan')
    s.tick(1)
    equal(s.row.pending.action, 'scan')
    s.report(false, { { ok = true }, { ok = true, data = { name = 'minecraft:oak_log', tags = { ['minecraft:logs'] = true } } },
      { ok = true }, { ok = true }, { ok = false }, { ok = true }, { ok = false } })
    equal(#s.job.candidates, 1)
    equal(s.job.candidates[1].x, 0)
    equal(s.job.candidates[1].z, 0)
    equal(s.job.spots['0,0'].plantedAt, 1)
    s.tick(2)
    equal(s.row.target.x, 0)
    equal(s.row.target.z, 0)
    equal(s.row.probing, true)
  end)

  for _, size in ipairs({ { 26, 20 }, { 29, 12 } }) do
    test('lumber SCAN chip fits ' .. size[1] .. 'x' .. size[2] .. ' and queues one request per tap', function()
      local s = scanner(true)
      local frame, found = s.draw(size[1], size[2])
      for _, b in ipairs(frame.buttons) do
        if b.id == 'scan' then
          found = b
          equal(b.label, 'SCAN')
          assert(b.x >= 1 and b.x + b.w - 1 <= size[1] and b.y >= 1 and b.y <= size[2])
          assert(frame.rows[b.y].text:sub(b.x, b.x + b.w - 1):find('SCAN', 1, true))
          for _, other in ipairs(frame.buttons) do
            if other ~= b and other.y == b.y then assert(b.x + b.w <= other.x or other.x + other.w <= b.x) end
          end
        end
      end
      assert(found, 'SCAN chip missing')
      s.tap(found.id)
      equal(s.job.scanRequested, true)
      s.tick(1)
      equal(s.job.scanRequested, nil)
      s.report(false)
      s.tick(2)
      equal(s.job.scanRequested, nil)
    end)
  end

  test('lumber fuel estimates without a chest stay silent when fuel is sufficient', function()
    local s = setup('waiting', 1000)
    s.row.tree, s.job.nextRound = nil, 600000
    realDrops(s)
    s.mods.drops.pick = function() error('estimation must use read-only choose') end
    for n = 1, 10 do
      s.tick(n)
      if s.queued() then s.report(false) end
    end
    equal(#s.events, 0)
    equal(s.row.service, nil)
  end)

  test('lumber missing fuel service emits one alert across repeated ticks and retries', function()
    local s = setup('scan', 0)
    realDrops(s)
    s.mods.drops.pick = function() error('service must use read-only choose') end
    for n = 1, 10 do
      s.tick(n)
      if s.queued() then s.report(false) end
      s.row.blocked = nil
    end
    equal(#s.events, 1)
    equal(s.events[1].kind, 'lumber.alert')
    equal(s.events[1].data.text, 'no fuel chest set')
    equal(s.row.service, nil)
  end)

  test('lumber fuel alert resets after reload and refuel without START and alerts on the next outage', function()
    local s = setup('waiting', 0)
    s.row.tree, s.job.nextRound = nil, 600000
    realDrops(s)
    local emit, active, raised = s.mods.state.emit, nil, 0
    s.mods.state.emit = function(kind, data)
      emit(kind, data)
      if kind == 'lumber.alert' then
        active = data
        if data ~= false then raised = raised + 1 end
      end
    end
    s.mods.state.get = function(key) if key == 'lumber.alert' then return active end end
    s.tick(1)
    equal(raised, 1)
    equal(s.row.alert, 'no fuel chest set')
    s.tick(2)
    if s.queued() then s.report(false) end
    assert(s.mods.drops.add({ id = 'fuel', dim = 0, x = 0, y = 1, z = 0, side = 'down', kind = 'fuel' }))
    s.tick = assert(loadfile('so-mod-lumber.lua', 't', s.env))().tick
    s.tick(3)
    s.report(false)
    equal(s.row.blocked, nil)
    s.tick(4)
    equal(s.row.service.kind, 'fuel')
    equal(s.row.alert, nil)
    equal(active, false)
    s.report(false, { { ok = true, data = { name = 'minecraft:chest' } } })
    s.tick(5)
    s.row.inv = { { slot = 1, name = 'minecraft:coal', count = 8 } }
    s.report(false, { { ok = true }, { ok = true } })
    s.tick(6)
    equal(s.queued().steps[2].op, 'refuel')
    s.row.fuel, s.row.inv = 640, {}
    s.report(false, { { ok = true }, { ok = true } })
    s.tick(7)
    equal(s.row.service, nil)
    equal(s.row.alert, nil)
    equal(raised, 1)
    assert(s.mods.drops.remove('fuel'))
    s.row.fuel = 0
    s.tick(8)
    equal(raised, 2)
    equal(active.text, 'no fuel chest set')
    equal(active.id, s.row.turtle.id)
    s.tick(9)
    s.report(false)
    s.tick(10)
    equal(raised, 2)
  end)

  test('lumber stops after three failed base digs and names start on screen', function()
    local s = setup('base')
    for _ = 1, 3 do s.tick(1) s.report(false) s.tick(1) s.report(true) end
    assert(s.row.blocked, 'failed digs must hold')
    assert(s.row.alert:find('start', 1, true), 'hold must explain recovery')
    equal(s.events[#s.events].kind, 'lumber.alert')
    s.tick(2)
    equal(s.queued().steps[1].op, 'inspectDown')
    s.report(false)
    s.input('start')
    assert(not s.row.blocked and not s.row.failures, 'start must clear retry hold')
    s.tick(3)
    s.report(false)
    s.tick(4)
    s.report(false)
    s.tick(4)
    s.report(true)
    assert(not s.row.blocked, 'first new failure must not immediately hold')
  end)
  test('lumber reserves fuel for the actual chest distance', function()
    local s = setup('scan', 200)
    s.tick(1)
    assert(s.row.service and s.row.service.kind == 'fuel', '250 block fuel trip must start before 80 fuel')
  end)
  test('lumber clears junk when all inventory slots contain apples', function()
    local inv = {}
    for i = 1, 16 do inv[i] = { slot = i, name = 'minecraft:apple', count = 64 } end
    local s = setup('scan', 1000, inv)
    s.tick(1)
    local q = s.queued()
    assert(s.row.service and s.row.service.kind == 'wood', 'full junk inventory must be cleaned at wood chest')
  end)
  test('lumber stops after failed travel movement despite successful inspections', function()
    local s = setup('scan')
    s.row.tree = nil
    s.row.target = { dim = s.job.dim, x = 1, y = 2, z = 0 }
    for _ = 1, 3 do s.tick(1) s.report(false) s.tick(1) s.report(true) end
    assert(s.row.blocked, 'mob-blocked moves must hold')
    assert(s.row.alert:find('forward failed', 1, true))
  end)
  test('lumber stops after failed ascent digs and moves', function()
    for _, failedIndex in ipairs({ 1, 2 }) do
      local s = setup('climb')
      for _ = 1, 3 do
        s.tick(1)
        s.report(false, { { ok = true, data = { name = 'minecraft:oak_log', tags = { ['minecraft:logs'] = true } } } })
        s.tick(1)
        s.report(false, { { ok = failedIndex ~= 1 }, { ok = failedIndex ~= 2 } })
      end
      assert(s.row.blocked, 'failed ascent must hold')
    end
  end)

  test('lumber drops excess saplings but keeps one for each known spot', function()
    local s = setup('scan', 1000, { { slot = 1, name = 'minecraft:oak_sapling', count = 64 },
      { slot = 2, name = 'minecraft:birch_sapling', count = 8 } })
    s.job.spots = { ['0,0'] = { kind = 'minecraft:oak_log' }, ['1,0'] = { kind = 'minecraft:oak_log' } }
    s.row.service = { kind = 'wood', point = { id='wood',x=0,y=1,z=0,side='down' }, stage = 'drop' }
    s.tick(1)
    local q = s.queued()
    equal(q.steps[1].slot, 1)
    equal(q.steps[3].n, 62)
    equal(q.steps[3].op, 'dropDown')
    s.row.inv[1].count = 2
    s.report(false)
    s.tick(2)
    equal(s.queued().steps[1].slot, 2)
    equal(s.queued().steps[3].n, 8)
    s.report(true)
    assert(s.row.blocked, 'failed junk drop must hold instead of looping')
  end)

  test('lumber unloads a full log inventory during a climb', function()
    local inv = {}
    for i = 1, 16 do inv[i] = { slot = i, name = 'minecraft:oak_log', count = 64 } end
    local s = setup('climb', 1000, inv)
    s.tick(1)
    assert(s.row.service and s.row.service.kind == 'wood')
    equal(s.row.service.resume, 'climb')
  end)
  test('lumber clears a single junk stack at the end of a round', function()
    local s = setup('roundEnd', 1000, { { slot = 1, name = 'minecraft:stick', count = 1 } })
    s.tick(1)
    assert(s.row.service and s.row.service.kind == 'wood')
  end)


  test('S4-12 lumber has no fuel missing row without turtles',function()
    local s=setup('waiting')
    s.job.turtles={} s.job.running=false s.input('start')
    local message=s.events[#s.events].data.text
    assert(message:find('paired turtle missing',1,true))
    assert(not message:find('fuel missing',1,true))
  end)
  test('S4-10 lumber corner chips use paired poses and keep drafts per display',function()
    local s=controls(setup('waiting'),{jobPoseSetup=true})
    local a,b={id=10},{id=11}
    s.job.running=false
    s.press('setup',a)
    local found={}
    for _,button in ipairs(s.draw(26,20,a).buttons) do found[button.id]=true end
    assert(found['from-here'] and found['to-here'])
    s.press('from-here',a)
    local original=copy(s.job.area)
    s.row.turtle.pose={dim=s.job.dim,x=2,y=2,z=1,facing=1}
    s.press('to-here',b) equal(s.job.area,original)
    s.press('to-here',a) equal(s.job.area,{x1=0,x2=2,z1=0,z2=1}) equal(s.job.ground,1)
    s.row.turtle.pose.x=500 s.press('to-here',a)
    equal(s.job.area,{x1=0,x2=2,z1=0,z2=1})
    s.row.turtle.pose.x=3
    s.mods.lease.status=function() return {uncertain=true} end
    s.press('to-here',a) equal(s.job.area,{x1=0,x2=2,z1=0,z2=1})
    local off=controls(setup('waiting')) off.press('setup')
    for _,button in ipairs(off.draw(26,20).buttons) do assert(button.id~='from-here' and button.id~='to-here') end
  end)
  for _,reason in ipairs({'suspended','missing','broken','unreadable'}) do
    test('B8-F lumber keeps an automatic fuel retry held when its cached point is '..reason,function()
      local s=setup('waiting',0)
      s.row.tree=nil s.job.nextRound=600000
      s.row.blocked,s.row.fuelRetry='fuel',60000
      s.row.service={kind='fuel',stage='take',point={id='fuel',x=0,y=1,z=0,side='down'}}
      s.mods.shop={fuelConfig=function() return {auto=true} end}
      local checks=0
      s.mods.drops.usable=function(id) equal(id,'fuel') checks=checks+1 return false,reason end
      s.tick(59999) equal(checks,0)
      if s.queued() then s.report(false) end
      s.tick(60000) equal(checks,1) equal(s.row.blocked,'fuel') equal(s.row.service.stage,'take')
      assert(s.row.alert:find(reason,1,true)) equal(s.queued(),nil)
      s.tick(60001) equal(checks,1)
    end)
    test('B8-F lumber refuses an initial sapling service whose registered point is '..reason,function()
      local s=setup('plant')
      local point={id='saplings',dim=0,x=251,y=1,z=0,side='down',kind='storage'}
      s.mods.drops.list=function() return {point} end
      s.mods.drops.add=function() error('registered saplings should be reused') end
      s.mods.drops.usable=function(id) equal(id,'saplings') return false,reason end
      s.tick(1) equal(s.row.blocked,'hold') equal(s.row.service,nil) equal(s.queued(),nil)
      assert(s.row.alert:find(reason,1,true))
    end)
    for _,hasId in ipairs({false,true}) do
      test('B8-F lumber rejects '..reason..' saplings before a new restored attempt with ID '..tostring(hasId),function()
        local s=setup('plant')
        local point={id='saplings',dim=0,x=251,y=1,z=0,side='down',kind='storage'}
        s.mods.drops.list=function() return {point} end s.mods.drops.add=function() return true end
        s.mods.drops.usable=function(id) equal(id,'saplings') return false,reason end
        s.row.service={kind='saplings',stage='check',point={id=hasId and 'saplings' or nil,x=251,y=1,z=0,side='down'}}
        s.tick(1) equal(s.row.blocked,'hold') equal(s.queued(),nil)
        assert(s.row.alert:find(reason,1,true))
      end)
    end
  end
  test('B8-F lumber accepts usable saplings and does not interrupt a committed transfer or its return',function()
    local s=setup('plant')
    local checks=0
    s.mods.drops.usable=function() checks=checks+1 return true end
    local back=copy(s.row.turtle.pose)
    s.row.service={kind='saplings',stage='take',back=back,resume='plant',point={id='saplings',x=0,y=1,z=0,side='down'}}
    s.tick(1) local q=s.queued() assert(q and q.steps[2].op=='suckDown') equal(checks,1)
    s.mods.drops.usable=function() error('committed command or return revalidated') end
    s.tick(2) equal(s.queued(),q)
    s.row.inv={{slot=1,name='minecraft:oak_sapling',count=1}} s.report(false)
    s.row.service.stage='return' s.tick(3) equal(s.row.service,nil)
  end)

  test('B8-F lumber restarts a usable automatic fuel retry after backoff',function()
    local s=setup('waiting',0)
    s.row.tree=nil s.job.nextRound=600000
    s.row.blocked,s.row.fuelRetry='fuel',60000
    s.row.service={kind='fuel',stage='take',point={id='fuel',x=0,y=1,z=0,side='down'}}
    s.mods.shop={fuelConfig=function() return {auto=true} end}
    local checks=0
    s.mods.drops.usable=function(id) equal(id,'fuel') checks=checks+1 return true end
    s.tick(60000) equal(checks,2) equal(s.row.blocked,nil) equal(s.row.fuelRetry,nil)
    equal(s.row.service.stage,'check') assert(s.queued())
    equal(s.queued().steps[1].op,'inspectDown')
  end)

  for _,reason in ipairs({'suspended','missing','broken','unreadable'}) do
    for _,resume in ipairs({'reload','START'}) do
      test('review P1 lumber '..resume..' cannot resume a failed fuel take when its point is '..reason,function()
        local s=setup('waiting',0)
        s.row.tree=nil s.job.nextRound=600000
        local point={id='fuel',dim=0,x=0,y=1,z=0,side='down',kind='any'}
        local usable=true
        s.mods.drops.list=function() return {point} end
        s.mods.drops.usable=function(id) equal(id,'fuel') return usable,reason end
        s.mods.shop={fuelConfig=function() return {auto=true} end}
        s.job.saplings={x=point.x,y=point.y,z=point.z,side=point.side}
        s.row.service={kind='fuel',stage='take',point=point,back=copy(s.row.turtle.pose),resume='waiting'}
        s.tick(1) assert(s.queued() and s.queued().steps[2].op=='suckDown')
        s.report(true)
        equal(s.row.blocked,'fuel') equal(s.row.service.stage,'take')
        s.row.fuel=1000
        usable=false
        local sent={}
        local send=s.mods.lease.send
        s.mods.lease.send=function(id,steps,opts)
          sent[#sent+1]=copy(steps) return send(id,steps,opts)
        end
        if resume=='reload' then
          s.tick=assert(loadfile('so-mod-lumber.lua','t',s.env))().tick
        else s.input('start') equal(s.job.running,true) end
        s.tick(2) assert(s.row.pending and s.row.pending.action=='recover')
        s.report(false) equal(s.row.blocked,nil) equal(s.row.service.stage,'take')
        s.tick(3)
        equal(s.row.blocked,'fuel') assert(s.row.alert:find(reason,1,true))
        equal(s.row.service.stage,'take')
        for _,steps in ipairs(sent) do for _,step in ipairs(steps) do assert(step.op~='suck' and step.op~='suckDown') end end
      end)
    end
  end
  test('review P1 fuel commands already committed finish and refuel before returning from a suspended point',function()
    local s=setup('waiting',0)
    s.row.tree=nil s.job.nextRound=600000
    local back=copy(s.row.turtle.pose)
    s.row.service={kind='fuel',stage='take',point={id='fuel',x=0,y=1,z=0,side='down'},back=back,resume='waiting'}
    s.mods.drops.usable=function() return true end
    s.tick(1) local q=s.queued() assert(q and q.steps[2].op=='suckDown')
    s.mods.drops.usable=function() error('committed pickup or safe return was checked') end
    s.tick(2) equal(s.queued(),q)
    s.row.inv={{slot=1,name='minecraft:coal',count=1}} s.report(false)
    equal(s.row.service.stage,'refuel')
    s.tick(3) equal(s.queued().steps[2].op,'refuel')
    s.row.inv={} s.row.fuel=1000 s.report(false)
    equal(s.row.service.stage,'return')
    s.tick(4) equal(s.row.service,nil)
  end)
end
