return function(test, equal)
  local setup = dofile('tests/so/lumber-fixture.lua')
  local P = dofile('so-plan.lua')
  local L = dofile('so-lumber-plan.lua')
  test('lumber travel refuses saplings and propagules', function()
    equal(L.canDig({ name = 'minecraft:oak_sapling' }), false)
    equal(L.canDig({ name = 'minecraft:mangrove_propagule' }), false)
  end)
  for _, side in ipairs({ 'front', 'down' }) do
    for _, height in ipairs({ 2, 7 }) do
      test('lumber service flight ' .. side .. ' height ' .. height, function()
        local f = setup()
        local j = f.job
        j.turtle.pose.y = height
        local back = { dim = j.dim, x = 0, y = height, z = 0, facing = 1 }
        j.service = { kind = 'wood', stage = 'travel', resume = 'waiting',
          point = { x = 6, y = 0, z = 0, side = side }, back = back }
        j.detour = { dim = j.dim, x = 5, y = 1, z = 0 }
        local returned = false
        for n = 1, 150 do
          f.tick(n)
          local q = f.queued()
          if q then
            local at = j.turtle.pose
            local results = {}
            for i, step in ipairs(q.steps) do
              if step.op == 'forward' or step.op == 'back' then equal(at.y, 2, 'horizontal flight height') end
              equal(step.op:match('^dig') == nil, true, 'does not dig farm')
              results[i] = { ok = not step.op:match('^inspect') }
              if results[i].ok then at = P.apply(at, step.op) end
            end
            f.report(false, results)
          end
          if not j.service then returned = true break end
        end
        equal(returned, true, 'service returned')
        equal(j.turtle.pose.x, back.x)
        equal(j.turtle.pose.y, back.y)
        equal(j.turtle.pose.z, back.z)
      end)
    end
  end
  test('lumber service does not dig an unknown log base', function()
    local f = setup()
    f.job.turtle.pose.y = 2
    f.job.service = { kind = 'wood', stage = 'travel', resume = 'scan',
      point = { x = 0, y = -1, z = 0, side = 'down' } }
    f.tick(1)
    f.report(false, { { ok = true, data = { name = 'minecraft:oak_log', tags = { ['minecraft:logs'] = true } } } })
    equal(f.queued() == nil, true, 'no dig sent')
    equal(f.job.blocked ~= nil, true, 'blocked route holds')
  end)
  test('lumber failed send releases reservations and parks', function()
    local f = setup()
    local releases = 0
    f.mods.cells.releaseOwner = function() releases = releases + 1 end
    local send = f.mods.lease.send
    f.mods.lease.send = function() return nil, 'offline' end
    f.tick(1)
    equal(releases > 0, true)
    equal(f.job.blocked ~= nil, true)
    f.mods.lease.send = send
    f.tick(2)
    equal(f.queued().opts.ms, P.park.ms)
  end)
  test('lumber replacement waits for old lease and confirmed park', function()
    local f = setup()
    f.tick(1)
    f.report(false, { { ok = false } })
    f.input('stop')
    f.input('add 3 8 2 0 e')
    equal(f.job.turtle.id, 2, 'old turtle retained while parking')
    equal(f.queued().opts.ms, P.park.ms)
    f.input('add 3 8 2 0 e')
    equal(f.job.turtle.id, 2, 'open park cannot be abandoned')
    f.report(false, { { ok = false } })
    f.input('add 3 8 2 0 e')
    equal(f.job.turtle.id, 3)
  end)
  test('lumber replacement refuses an external open lease', function()
    local f = setup()
    f.input('stop')
    f.mods.lease.status = function() return { open = true } end
    f.input('add 3 8 2 0 e')
    equal(f.job.turtle.id, 2)
  end)
end
