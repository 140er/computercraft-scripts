return function(test, equal, read, mocks)
  local hub, miner = read("hub.lua"), read("miner.lua")
  local cfg = { home = { x = 100, y = 64, z = 20 }, facing = 2, spine = 3 }
  local function loadMiner(m)
    local code = assert(miner:match("^(.*)\nopenModem%(%)"))
    return assert(load(code .. [[
return { st = st, rawMove = rawMove, move = move, moveOrFail = moveOrFail, seal = seal,
  recover = recover, getJob = getJob, report = report, openModem = openModem }
]], "=miner.lua", "t", m.env))()
  end
  local function progress(n)
    return { shaft = -58, levels = { [16] = { spine = n, branch = n, step = 0, full = true } } }
  end
  local function claim(x, z)
    return { x = x, y = 64, z = z, bottom = -58 }
  end
  local function boot(m)
    m.files["views.cfg"] = mocks.encode({ enabled = false })
    m.start(hub)
  end
  local function job(m, shaft, role)
    m.status(1, { type = "job?", role = role or "west", shaft = shaft })
    return m.messages[#m.messages]
  end

  test("world progress belongs to one shaft, including bore jobs and replacement turtles", function()
    local m = mocks.new(false, { target = "iron", bores = { [2] = { x = 110, z = 20, n = 1 } } })
    boot(m)
    m.status(1, { type = "report", role = "west", shaft = claim(100, 21), progress = progress(16) })
    equal(job(m, claim(104, 21)).progress, nil, "fresh west shaft inherited another shaft")
    equal(job(m, claim(100, 21)).progress.levels[16].spine, 16)
    m.status(2, { type = "job?", role = "west", shaft = claim(104, 21) })
    equal(m.messages[#m.messages].progress, nil, "bore job inherited another shaft")
    m.status(3, { type = "job?", role = "west", shaft = claim(100, 21) })
    equal(m.messages[#m.messages].progress.levels[16].spine, 16, "replacement lost shaft progress")
    equal(job(m, claim(100, 21), "east").progress, nil, "new direction inherited west tunnels")
    equal(job(m, claim(100, 21), "west@2").progress, nil, "site identity was discarded")
  end)

  test("legacy role progress stays available only to miners without world shafts", function()
    local legacy = progress(48)
    local m = mocks.new(false, { target = "iron", progress = { west = legacy } })
    boot(m)
    equal(job(m, claim(104, 21)).progress, nil, "ambiguous legacy progress assigned to fresh shaft")
    equal(job(m).progress, legacy, "local coordinate fallback lost progress")
    m.status(1, { type = "report", role = "west", shaft = claim(104, 21), progress = progress(2) })
    local saved = mocks.hubFile(m.files)
    equal(saved.progress.west, legacy, "migration destroyed legacy progress")
    local restarted = mocks.new(false, saved)
    boot(restarted)
    equal(job(restarted, claim(104, 21)).progress.levels[16].spine, 2)
    equal(job(restarted, claim(100, 21)).progress, nil)
  end)

  test("old miners with world telemetry use their shaft for reports and jobs", function()
    local m = mocks.new(false, { target = "iron", progress = { west = progress(48) } })
    boot(m)
    m.status(1, { type = "status", role = "west", shaft = claim(100, 21) })
    m.status(1, { type = "report", role = "west", progress = progress(3) })
    equal(job(m, claim(104, 21)).progress, nil)
    equal(job(m).progress.levels[16].spine, 3)
  end)

  test("miner sends shaft identity and rejects unscoped progress from an old hub", function()
    local m = mocks.miner(cfg)
    local api = loadMiner(m)
    api.openModem()
    m.env.rednet.lookup = function() return 99 end
    m.app = coroutine.create(api.getJob)
    m.push()
    equal(m.messages[#m.messages].shaft, { x = 100, y = 64, z = 21, bottom = 64 })
    m.push("rednet_message", 99, { type = "job", paused = true, progress = progress(48) }, "minearmy")
    equal(api.st.shaft, 64, "old role-scoped hub polluted a world shaft")
    api.report({})
    equal(m.messages[#m.messages].shaft, { x = 100, y = 64, z = 21, bottom = 64 })
    m.app = coroutine.create(api.getJob)
    m.push()
    m.push("rednet_message", 99, { type = "job", paused = true, progress = progress(2),
      progressKey = "shaft:100,21:west" }, "minearmy")
    equal(api.st.levels[16].spine, 2)
  end)

  test("a local-coordinate miner still accepts progress from a legacy hub", function()
    local m = mocks.miner({ home = cfg.home, facing = 2, spine = 3, loc = true })
    local api = loadMiner(m)
    api.openModem()
    m.env.rednet.lookup = function() return 99 end
    m.app = coroutine.create(api.getJob)
    m.push()
    equal(m.messages[#m.messages].shaft, nil)
    m.push("rednet_message", 99, { type = "job", paused = true, progress = progress(3) }, "minearmy")
    equal(api.st.levels[16].spine, 3)
  end)

  test("dashboard flags duplicate shafts and clears the warning when a claim changes", function()
    local m = mocks.new(false)
    boot(m)
    local p = { type = "status", phase = "home", status = "Waiting", role = "west", shaft = claim(100, 21) }
    m.status(1, p)
    m.status(2, p)
    m.tick()
    assert(table.concat(m.output):find("SHAFT #", 1, true), "duplicate shaft missing from dashboard")
    m.status(2, { type = "status", phase = "home", status = "Waiting", role = "west", shaft = claim(104, 21) })
    m.output = {}
    m.tick()
    assert(not table.concat(m.output):find("SHAFT #", 1, true), "resolved claim still flagged")
  end)

  test("startup refuses a moved home even beside a chest and preserves tunnel state", function()
    local m = mocks.miner(cfg, { shaft = -58, levels = progress(16).levels })
    m.pos.x = 104
    m.world[m.key(0)] = "minecraft:chest"
    m.env.gps = { locate = function() return m.pos.x, m.pos.y, m.pos.z end }
    local api = loadMiner(m)
    api.openModem()
    local ok, why = pcall(api.recover)
    assert(not ok and tostring(why):find("miner setup", 1, true), "wrong home accepted beside a chest")
    equal(m.heading, cfg.facing, "wrong home turned before refusal")
    equal(m.dug, {})
    assert(m.messages[#m.messages].status:find("miner setup", 1, true), "setup error missing from telemetry")
    local saved = mocks.value(m.files, "miner.state")
    assert(saved.lastError.msg:find("miner setup", 1, true), "setup error not persisted")
    equal(saved.shaft, -58)
    equal(saved.levels, progress(16).levels)
  end)

  test("home verification rounds GPS and allows local setups or unavailable GPS", function()
    for _, mode in ipairs({ "round", "offline", "local" }) do
      local c = { home = cfg.home, facing = 2, spine = 3, loc = mode == "local" }
      local m = mocks.miner(c)
      m.world[m.key(0)] = "minecraft:chest"
      m.env.gps = { locate = function()
        if mode == "offline" then return end
        if mode == "local" then return 900, 70, 900 end
        return 99.9999, 64.0001, 20.0001
      end }
      local api = loadMiner(m)
      api.recover()
      equal(api.st.pos, cfg.home)
    end
  end)

  test("GPS resync also checks vertical routes before declaring LOST", function()
    local m = mocks.miner(cfg, { pos = { x = 100, y = 63, z = 21 }, phase = "returning", shaft = 16 })
    m.pos = { x = 100, y = 64, z = 21 }
    m.world[m.key(5)] = "minecraft:andesite"
    m.env.gps = { locate = function() return 100.0001, 63.9999, 21.0001 end }
    local api = loadMiner(m)
    api.moveOrFail(5)
    equal(api.st.pos, m.pos)
    equal(m.pos.y, 63)
  end)

  test("an underground restart may return home with GPS away from home", function()
    local m = mocks.miner(cfg, { pos = { x = 100, y = 63, z = 21 }, phase = "descending", shaft = 63 })
    m.pos = { x = 100, y = 63, z = 21 }
    m.world["100,64,19"] = "minecraft:chest"
    m.env.gps = { locate = function() return m.pos.x, m.pos.y, m.pos.z end }
    local api = loadMiner(m)
    api.recover()
    equal(api.st.pos, cfg.home)
    equal(m.pos, cfg.home)
  end)

  test("a failed turn never advances the saved heading or permits a move", function()
    for _, direction in ipairs({ 1, 3 }) do
      local m = mocks.miner(cfg)
      m.failTurn = true
      local api = loadMiner(m)
      local ok = pcall(api.rawMove, direction)
      assert(not ok, "failed turn allowed a forward move")
      equal(api.st.h, m.heading)
      equal(api.st.pos, m.pos)
      local saved = mocks.value(m.files, "miner.state")
      equal(saved.h, m.heading)
      equal(saved.turnFrom, nil)
    end
  end)

  test("turnFrom recovers both sides of an interrupted turn from tunnel geometry", function()
    for _, completed in ipairs({ false, true }) do
      local m = mocks.miner(cfg, { pos = { x = 98, y = 16, z = 21 }, h = 3, turnFrom = 2,
        phase = "mining", shaft = 16, job = { y = 16, targets = {} },
        levels = { [16] = { spine = 4, branch = 1, step = 0 } } })
      m.pos = { x = 98, y = 16, z = 21 }
      m.heading = completed and 3 or 2
      m.world["98,16,20"], m.world["98,16,22"] = "minecraft:stone", "minecraft:stone"
      m.world["100,64,19"] = "minecraft:chest"
      local api = loadMiner(m)
      api.recover()
      equal(api.st.pos, cfg.home)
      equal(m.pos, cfg.home, "interrupted turn changed the route home")
      equal(api.st.h, m.heading)
    end
  end)

  test("recorded natural seals can be reopened after a reboot without allowing other rock", function()
    local m = mocks.miner(cfg)
    m.inventory[1] = { name = "minecraft:andesite", count = 5 }
    local api = loadMiner(m)
    assert(api.seal(4))
    local saved = mocks.value(m.files, "miner.state")
    m.files["miner.state"] = mocks.encode(saved)
    api = loadMiner(m)
    api.moveOrFail(4)
    equal(api.st.pos, m.pos)
    equal(#m.dug, 1)
    m.world[m.key(4)] = "minecraft:andesite"
    local ok, why = pcall(api.moveOrFail, 4)
    assert(not ok and tostring(why):find("LOST", 1, true), "unrecorded natural rock was dug")
    equal(#m.dug, 1)
  end)

  test("seal permission is consumed after digging and does not match a different block", function()
    local m = mocks.miner(cfg)
    m.inventory[1] = { name = "minecraft:tuff", count = 5 }
    local api = loadMiner(m)
    assert(api.seal(4))
    m.world[m.key(4)] = "minecraft:deepslate"
    assert(not pcall(api.moveOrFail, 4), "different rock accepted at seal position")
    equal(#m.dug, 0)
    m.world[m.key(4)] = "minecraft:tuff"
    api.moveOrFail(4)
    api.rawMove(5)
    m.world[m.key(4)] = "minecraft:tuff"
    assert(not pcall(api.moveOrFail, 4), "removed seal permission reused")
    equal(#m.dug, 1)
  end)

  test("failed movement after digging does not advance position, including falling blocks", function()
    for _, obstacle in ipairs({ "gravel", "sand", "mob", "player", "turtle", "unloaded" }) do
      local m = mocks.miner(cfg)
      local api = loadMiner(m)
      m.world[m.key(4)] = "minecraft:gravel"
      local attempts = 0
      m.beforeMove = function(d)
        attempts = attempts + 1
        if attempts == 1 then
          equal(api.st.pos, m.pos, "position advanced before move completed")
          if obstacle == "gravel" or obstacle == "sand" then m.world[m.key(d)] = "minecraft:" .. obstacle
          elseif obstacle == "turtle" then m.world[m.key(d)] = "computercraft:turtle_normal"
          else m.blockMove = obstacle == "unloaded" and "Cannot leave loaded world" or "Movement obstructed" end
        else m.blockMove = nil end
      end
      if obstacle == "turtle" then m.env.sleep = function() m.world[m.key(4)] = nil end end
      local ok, why = api.move(4)
      equal(api.st.pos, m.pos)
      if obstacle == "unloaded" then
        assert(not ok and why == "outside loaded chunks")
        equal(api.st.pos, cfg.home)
      else
        assert(ok)
        equal(api.st.pos.y, 65)
      end
    end
  end)

  test("known routes reject new natural rock during movement and digging retries", function()
    for _, refill in ipairs({ "move", "dig" }) do
      local m = mocks.miner(cfg)
      local api = loadMiner(m)
      if refill == "move" then
        m.beforeMove = function(d) m.world[m.key(d)] = "minecraft:stone" end
      else
        m.world[m.key(4)] = "minecraft:gravel"
        local dig = m.env.turtle.digUp
        m.env.turtle.digUp = function()
          local ok = dig()
          m.world[m.key(4)] = "minecraft:stone"
          return ok
        end
      end
      local ok, why = pcall(api.moveOrFail, 4)
      assert(not ok and tostring(why):find("LOST", 1, true), "retry dug unrecorded natural rock")
      equal(m.world[m.key(4)], "minecraft:stone")
      equal(api.st.pos, cfg.home)
      for _, dug in ipairs(m.dug) do assert(dug.name ~= "minecraft:stone", "retry dug new rock") end
    end
  end)

  test("lava sources and flows use seals, while water never goes in the fuel bucket", function()
    for _, fluid in ipairs({ "source", "flow", "water" }) do
      local m = mocks.miner(cfg)
      m.inventory[1] = { name = "minecraft:bucket", count = 1 }
      m.inventory[2] = { name = "minecraft:andesite", count = 8 }
      m.flowing = fluid == "flow"
      m.world[m.key(4)] = fluid == "water" and "minecraft:water" or "minecraft:lava"
      local api = loadMiner(m)
      api.moveOrFail(4)
      equal(api.st.pos, m.pos)
      equal(m.fuel, fluid == "source" and 7999 or 6999)
      equal(m.inventory[1].name, "minecraft:bucket")
    end
  end)

  test("lava that cannot be sealed blocks the route without a false LOST", function()
    local m = mocks.miner(cfg)
    m.world[m.key(4)] = "minecraft:lava"
    local api = loadMiner(m)
    local ok, why = pcall(api.moveOrFail, 4)
    assert(not ok and tostring(why):find("lava", 1, true))
    assert(not tostring(why):find("LOST", 1, true), "unsealed lava treated as missing tunnel")
    equal(m.pos, cfg.home)
    equal(m.dug, {})
  end)

  test("fuel checkpoint recovers moves interrupted before or after physical movement", function()
    for _, completed in ipairs({ false, true }) do
      for _, vein in ipairs({ false, true, "pop" }) do
        local m = mocks.miner(cfg, { pos = { x = 100, y = 62, z = 21 }, phase = "returning",
          shaft = 62, vein = vein == "pop" and { 5 } or {} })
        m.pos = { x = 100, y = 62, z = 21 }
        m.world["100,64,19"] = "minecraft:chest"
        local api = loadMiner(m)
        local function crash() error("power loss", 0) end
        if completed then m.afterMove = crash else m.beforeMove = crash end
        assert(not pcall(api.rawMove, 4, vein))
        m.afterMove, m.beforeMove = nil, nil
        api = loadMiner(m)
        api.recover()
        equal(api.st.pos, cfg.home)
        equal(m.pos, cfg.home, "restart lost a physical move")
        equal(api.st.pending, nil)
        equal(api.st.vein, {})
      end
    end
  end)

  test("unlimited fuel needs GPS to resolve an interrupted move", function()
    for _, withGPS in ipairs({ false, true }) do
      local m = mocks.miner(cfg, { pos = { x = 100, y = 62, z = 21 }, phase = "returning", shaft = 62 })
      m.pos = { x = 100, y = 62, z = 21 }
      m.fuel = "unlimited"
      m.world["100,64,19"] = "minecraft:chest"
      local api = loadMiner(m)
      m.afterMove = function() error("power loss", 0) end
      assert(not pcall(api.rawMove, 4))
      m.afterMove = nil
      if withGPS then m.env.gps = { locate = function() return m.pos.x, m.pos.y, m.pos.z end } end
      api = loadMiner(m)
      local ok, why = pcall(api.recover)
      if withGPS then
        assert(ok, why)
        equal(m.pos, cfg.home)
        equal(api.st.pos, cfg.home)
      else
        assert(not ok and tostring(why):find("miner home", 1, true), "ambiguous unlimited move silently accepted")
        equal(m.pos, { x = 100, y = 63, z = 21 }, "ambiguous restart moved the turtle")
      end
    end
  end)
end
