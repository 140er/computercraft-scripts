return function(test, equal, read, mocks)
  local hub, miner = read("hub.lua"), read("miner.lua")
  local cfg = { home = { x = 100, y = 64, z = 20 }, facing = 2, spine = 3 }
  local function loadMiner(m)
    local code = assert(miner:match("^(.*)\nopenModem%(%)"))
    return assert(load(code .. [[
return { st = st, face = face, rawMove = rawMove, moveOrFail = moveOrFail, seal = seal,
  recover = recover, mergeProgress = mergeProgress, getJob = getJob, report = report,
  openModem = openModem, worker = worker }
]], "=miner.lua", "t", m.env))()
  end
  local function progress(n)
    return { shaft = -58, levels = { [16] = { spine = n, branch = n, step = 0, full = true } } }
  end
  local function claim(x, z)
    return { x = x, y = 64, z = z, bottom = -58 }
  end
  local function job(m, shaft, role)
    m.status(1, { type = "job?", role = role or "west", shaft = shaft })
    return m.messages[#m.messages]
  end

  test("world progress belongs to one shaft, including bore jobs and replacement turtles", function()
    local m = mocks.new(false, { target = "iron", bores = { [2] = { x = 110, z = 20, n = 1 } } })
    m.start(hub)
    m.status(1, { type = "report", role = "west", shaft = claim(100, 21), progress = progress(16) })
    equal(job(m, claim(104, 21)).progress, nil, "fresh west shaft inherited another shaft")
    equal(job(m, claim(100, 21)).progress.levels[16].spine, 16)
    m.status(2, { type = "job?", role = "west", shaft = claim(104, 21) })
    equal(m.messages[#m.messages].progress, nil, "bore job inherited another shaft")
    m.status(3, { type = "job?", role = "west", shaft = claim(100, 21) })
    equal(m.messages[#m.messages].progress.levels[16].spine, 16, "replacement lost shaft progress")
    equal(job(m, claim(100, 21), "east").progress, nil, "new direction inherited west tunnels")
  end)

  test("legacy role progress stays available only to miners without world shafts", function()
    local legacy = progress(48)
    local m = mocks.new(false, { target = "iron", progress = { west = legacy } })
    m.start(hub)
    equal(job(m, claim(104, 21)).progress, nil, "ambiguous legacy progress assigned to fresh shaft")
    equal(job(m).progress, legacy, "local coordinate fallback lost progress")
    m.status(1, { type = "report", role = "west", shaft = claim(104, 21), progress = progress(2) })
    local saved = m.env.textutils.unserialize(m.files["hub.state"])
    equal(saved.progress.west, legacy, "migration destroyed legacy progress")
    local restarted = mocks.new(false, saved)
    restarted.start(hub)
    equal(job(restarted, claim(104, 21)).progress.levels[16].spine, 2)
    equal(job(restarted, claim(100, 21)).progress, nil)
  end)

  test("old miners with world telemetry use their shaft for reports and jobs", function()
    local m = mocks.new(false, { target = "iron", progress = { west = progress(48) } })
    m.start(hub)
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

  test("dashboard flags duplicate shafts and clears the warning when a claim changes", function()
    local m = mocks.new(false)
    m.start(hub)
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
end
