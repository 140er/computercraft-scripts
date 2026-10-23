local F = dofile('tests/so/lumber-farm-fixture.lua')
return function(test, equal)
  for _, count in ipairs({ 2, 3 }) do
    for _, side in ipairs({ 'down', 'front' }) do
      test('lumber ' .. count .. ' workers share ' .. side .. ' chests and replant every tree once', function()
        local g = F.setup(true, 40, side, count)
        F.run(g, function(v) return F.delivered(v) == 16 and (function()
          for _, spot in ipairs(F.trees) do
            if v.net.world[spot[1] .. ',1,' .. spot[2]] ~= 'minecraft:' .. spot[3] .. '_sapling' then return false end
          end
          return true
        end)() end)
        for _, spot in ipairs(F.trees) do
          equal(g.net.world[spot[1] .. ',1,' .. spot[2]], 'minecraft:' .. spot[3] .. '_sapling')
        end
        equal(#g.digs, 16)
        local total = 0
        for _, event in ipairs(g.events) do if event.kind == 'lumber.logs' then total = total + event.data.count end end
        equal(total, 16)
        local contributed = 0
        for _, n in pairs(g.dugCells) do if n > 0 then contributed = contributed + 1 end end
        assert(contributed >= 2, 'work was not shared')
        equal(g.server.env.SO.store.read('so-data/lumber/job').value.logs, 16)
      end)
    end
  end
  test('lumber a lost worker leaves the other workers harvesting', function()
    local g = F.setup(true, 10000, 'down', 3)
    F.run(g, function(v) return #v.digs >= 2 end)
    local job = g.server.env.SO.store.read('so-data/lumber/job').value
    local lost, interrupted
    for _, worker in ipairs(g.workers) do
      if job.turtles[tostring(worker.id)].tree then lost, interrupted = worker, job.turtles[tostring(worker.id)].tree break end
    end
    assert(lost, 'no active tree at outage')
    g.net.kill(lost)
    local before = #g.digs
    F.run(g, function(v)
      if #v.digs <= before or F.delivered(v) < 12 then return false end
      for _, spot in ipairs(F.trees) do
        if (spot[1] ~= interrupted.x or spot[2] ~= interrupted.z)
          and v.net.world[spot[1] .. ',1,' .. spot[2]] ~= 'minecraft:' .. spot[3] .. '_sapling' then return false end
      end
      return true
    end)
    for _, worker in ipairs(g.workers) do if worker ~= lost then assert(worker.alive()) end end
  end)
  test('lumber restart recovers all worker poses and finishes their trees', function()
    local g = F.setup(true, 10000, 'down', 3)
    F.run(g, function(v) return #v.digs >= 4 end)
    g.server.co, g.server.timers, g.server.inbox = nil, {}, {}
    g.server.boot('so-server.lua')
    F.run(g, function(v) return F.delivered(v) == 16 and (function()
          for _, spot in ipairs(F.trees) do
            if v.net.world[spot[1] .. ',1,' .. spot[2]] ~= 'minecraft:' .. spot[3] .. '_sapling' then return false end
          end
          return true
        end)() end)
    local job = g.server.env.SO.store.read('so-data/lumber/job').value
    for _, worker in ipairs(g.workers) do
      local pose = job.turtles[tostring(worker.id)].turtle.pose
      equal({ x = pose.x, y = pose.y, z = pose.z }, worker.pos)
    end
    for _, spot in ipairs(F.trees) do
      equal(g.net.world[spot[1] .. ',1,' .. spot[2]], 'minecraft:' .. spot[3] .. '_sapling')
    end
    equal(#g.digs, 16)
  end)  test('lumber a worker lost in the chest queue releases its unused approach', function()
    local g = F.setup(true, 10, 'down', 3)
    F.run(g, function(v)
      local row = v.server.env.SO.store.read('so-data/lumber/job').value.turtles['3']
      return row.service and row.service.ticket and (not row.service.access
        or row.turtle.pose.x ~= row.service.access.x or row.turtle.pose.z ~= row.service.access.z)
    end)
    g.net.kill(g.workers[2])
    F.run(g, function(v) return F.delivered(v) == 16 end)
    for _, spot in ipairs(F.trees) do
      equal(g.net.world[spot[1] .. ',1,' .. spot[2]], 'minecraft:' .. spot[3] .. '_sapling')
    end
    equal(g.server.env.SO.store.read('so-data/lumber/job').value.turtles['3'].service.ticket, nil)
  end)
  test('lumber a successful drop with a lost report is credited once after restart', function()
    local g = F.setup(true, 10000, 'down', 2)
    local suppressed = false
    for _, worker in ipairs(g.workers) do
      local send = worker.env.rednet.send
      worker.env.rednet.send = function(id, wire, protocol)
        if not suppressed and wire.t == 'step.report' and F.delivered(g) > 0 then
          suppressed = true
          return true
        end
        return send(id, wire, protocol)
      end
    end
    F.run(g, function() return suppressed end)
    g.server.co, g.server.timers, g.server.inbox = nil, {}, {}
    g.server.boot('so-server.lua')
    F.run(g, function(v) return F.delivered(v) == 16
      and v.server.env.SO.store.read('so-data/lumber/job').value.logs == 16 end)
    equal(g.server.env.SO.store.read('so-data/lumber/job').value.logs, 16)
    g.server.co, g.server.timers, g.server.inbox = nil, {}, {}
    g.server.boot('so-server.lua')
    g.net.advance(5)
    equal(g.server.env.SO.store.read('so-data/lumber/job').value.logs, 16)
  end)

end
