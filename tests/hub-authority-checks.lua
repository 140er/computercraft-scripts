return function(test, equal)
  local mocks = dofile("tests/mocks.lua")
  local env = mocks.new(false).env
  env.dofile = function(path) return assert(loadfile(path, "t", env))() end
  local S = env.dofile("ssot.lua")
  local A = env.dofile("atomic.lua")
  local Auth = env.dofile("hub-authority.lua")
  local T1 = env.dofile("s1_t1.lua")

  local function box(profile, holder, extra)
    local function make(saved)
      local cfg = {
        hubProfile = true, profile = profile, holder = holder,
        joining = extra and extra.joining or false,
        pageRecords = extra and extra.pageRecords or nil,
        controllers = { ["1"] = "test-secret-123456" },
        keys = {},
        saveKeys = function() return true end,
      }
      local api = S.new(saved.s, cfg, function() return 1000000 end, "boot-1", function(s)
        saved.s = A.copy(s)
        return true
      end)
      local node = { holder = holder }
      function node.state() return api.state() end
      function node.req(op, fields)
        saved.counter = saved.counter + 1
        local n = saved.counter
        local m = A.copy(fields or {})
        m.v, m.type, m.expect, m.op = 1, "ssot", "ssot_reply", op
        m.boot, m.rid, m.counter = "hub-test", "h" .. n, n
        m.secret = "test-secret-123456"
        return api.handle(1, m)
      end
      function node.reboot()
        return make({ s = saved.s, counter = saved.counter })
      end
      return node
    end
    return make({ s = {}, counter = 0 })
  end

  local function at(x, z)
    return T1.samplePos(x, 64, z, 0)
  end

  local function seed(hub)
    local planId = hub.req("hub-mint").id
    local areaId = hub.req("hub-mint").id
    assert(hub.req("hub-put", { kind = "plan", body = {
      v = 1, id = planId, frame = "abs", dim = "minecraft:overworld", y = 64, name = "Base", rev = 3,
      areas = { { id = areaId, kind = "base", min = at(10, 20), max = at(20, 30) } },
      fixtures = {}, bots = {},
    } }).ok)
    assert(hub.req("hub-put", { kind = "code", body = {
      v = 1, code = "K7Q2M3XDPT", issuer = 7, issuedAt = 1000000, untilAt = 5000000,
      role = "miner", used = false, attempts = 0, planBot = false,
    } }).ok)
    assert(hub.req("hub-put", { kind = "code", body = {
      v = 1, code = "M3XDPTK7Q2", issuer = 7, issuedAt = 1000000, untilAt = 5000000,
      role = "miner", used = false, attempts = 0, planBot = false,
    } }).ok)
    assert(hub.req("hub-put", { kind = "code", body = {
      v = 1, code = "Q2M3XDPTK7", issuer = 7, issuedAt = 1000000, untilAt = 4000000,
      role = "miner", used = false, attempts = 1, planBot = false, claiming = true,
    } }).ok)
    return planId
  end

  local function snapshot(hub, server)
    local h, s = hub.state(), server.state()
    local codes = {}
    for id, code in pairs(s.codes or {}) do
      codes[#codes + 1] = id .. ":" .. tostring(code.untilAt) .. ":" .. tostring(code.used) .. ":" .. tostring(code.invalidated)
    end
    table.sort(codes)
    return {
      plan = h.plans and next(s.plans) and s.plans[next(s.plans)].id,
      name = next(s.plans) and s.plans[next(s.plans)].name,
      codes = codes,
      epoch = s.authority.epoch,
      phase = h.handover.phase,
      hubIssues = Auth.issuing(h, hub.holder),
      serverIssues = Auth.issuing(s, server.holder),
    }
  end

  test("a hub with plans and two unclaimed codes hands over once", function()
    local function run(crash)
      local hub = box("hub", 7, { pageRecords = 1 })
      local server = box("server", 4, { joining = true, pageRecords = 1 })
      local planId = seed(hub)
      local action, doneHub, doneServer = Auth.migrate(hub, server, { crash = crash })
      equal(action, "client")
      local shot = snapshot(doneHub, doneServer)
      equal(shot.plan, planId)
      equal(shot.name, "Base")
      equal(shot.epoch, 2)
      equal(shot.phase, "client")
      equal(shot.hubIssues, false)
      equal(shot.serverIssues, true)
      equal(doneServer.state().codes["K7Q2M3XDPT"].untilAt, 5000000)
      equal(doneServer.state().codes["M3XDPTK7Q2"].untilAt, 5000000)
      equal(doneServer.state().codes["Q2M3XDPTK7"].invalidated, true)
      local fresh
      for id, code in pairs(doneServer.state().codes) do
        if id ~= "K7Q2M3XDPT" and id ~= "M3XDPTK7Q2" and id ~= "Q2M3XDPTK7" then fresh = code.code end
      end
      assert(type(fresh) == "string", "missing reissued code")
      assert(doneServer.req("hub-claim", { code = "K7Q2M3XDPT", proof = "claim-proof" }).ok)
      assert(doneServer.req("hub-claim", { code = "M3XDPTK7Q2", proof = "claim-proof" }).ok)
      assert(doneServer.req("hub-claim", { code = fresh, proof = "claim-proof" }).ok)
      local denied = doneServer.req("hub-claim", { code = "Q2M3XDPTK7", proof = "claim-proof" })
      equal(denied.ok, false)
      equal(denied.error, "invalidated")
      equal(doneHub.req("hub-claim", { code = "K7Q2M3XDPT", proof = "claim-proof" }).ok, false)
      equal(doneHub.req("hub-mint").ok, false)
      local again = Auth.migrate(doneHub, doneServer)
      equal(again, "client")
      local plans = 0
      for _ in pairs(doneServer.state().plans) do plans = plans + 1 end
      equal(plans, 1)
      return shot
    end
    equal(run(true), run(false))
  end)

  test("lookup blinks do not make a frozen or client hub issue", function()
    local here = { phase = "idle", kind = "hub", epoch = 1, frozen = false, canIssue = true, records = 2 }
    local joining = { phase = "idle", epoch = 0, canIssue = false, kind = "server", frozen = false }
    local memory = {}
    equal(Auth.observe(memory, 4), nil)
    equal(Auth.next(here, nil, nil), "issue")
    equal(Auth.observe(memory, 4), 4)
    equal(Auth.decide(here, joining), "freeze")
    here.phase, here.frozen, here.canIssue = "frozen", true, false
    equal(Auth.observe(memory, nil), nil)
    equal(Auth.decide(here, nil), "wait")
    equal(Auth.pick(4, 9), 4)
    equal(Auth.pick(4, nil), 4)
    equal(Auth.next(here, 4, nil), "wait")
    here.phase = "client"
    equal(Auth.decide(here, nil), "client")
    equal(Auth.decide(here, joining), "client")
    local established = { phase = "idle", epoch = 1, canIssue = true, kind = "server", frozen = false }
    local empty = { phase = "idle", kind = "hub", epoch = 1, frozen = false, canIssue = true, records = 0 }
    local holding = { phase = "idle", kind = "hub", epoch = 1, frozen = false, canIssue = true, records = 2 }
    equal(Auth.decide(empty, established), "follow")
    equal(Auth.decide(holding, established), "issue")
  end)

  test("an established server does not receive a second authority", function()
    local hub = box("hub", 7, {})
    local server = box("server", 4, { joining = false })
    seed(hub)
    local action, done = Auth.migrate(hub, server)
    equal(action, "issue")
    equal(done.state().handover.phase, "idle")
    equal(done.state().authority.frozen, false)
    local quiet = box("hub", 7, {})
    local followed = Auth.migrate(quiet, server)
    equal(followed, "follow")
    equal(quiet.state().authority.frozen, false)
  end)

  local tools = dofile("planner-tools.lua")
  local panel = dofile("planner-panel.lua")
  local hubHost = dofile("planner-hub.lua")
  local serverHost = tools.host("server")
  local script = {
    { t = "level", y = 70 },
    { t = "draw", kind = "base", from = { x = 0, z = 0 }, to = { x = 5, z = 3 } },
    { t = "place", kind = "chest", at = { x = 1, z = 1 }, side = "front" },
    { t = "place", kind = "dropoff", at = { x = 2, z = 1 } },
    { t = "place", kind = "charger", at = { x = 3, z = 1 } },
    { t = "place", kind = "furnace", at = { x = 4, z = 1 } },
    { t = "place", kind = "bot", role = "miner", at = { x = 1, z = 2 }, h = 0 },
    { t = "place", kind = "bot", role = "farmer", at = { x = 3, z = 2 }, h = 1 },
    { t = "job", bot = { x = 1, z = 2 }, from = { x = 0, z = 16 }, to = { x = 4, z = 20 } },
    { t = "toggle", bot = { x = 1, z = 2 }, key = "offlineAutonomy" },
    { t = "confirm", bot = { x = 1, z = 2 } },
  }

  local function played(api, opts)
    local session = assert(api.open(opts))
    for _, step in ipairs(script) do session = api.apply(session, step) end
    return api.records(session), session
  end

  test("the same plan on the hub authority, the panel, and the server", function()
    local seedOpts = {
      enabled = true, origin = 4, counter = 17, server = 4, now = 1792500000000,
      frame = "abs", dim = "minecraft:overworld", settingsRevision = 4, name = "Base", y = 64,
    }
    local function withScreen(screen, extra)
      local opts = {}
      for key, value in pairs(seedOpts) do opts[key] = value end
      opts.screen = screen
      for key, value in pairs(extra or {}) do opts[key] = value end
      return opts
    end
    local want = played(serverHost, withScreen(tools.screens.server))
    equal(played(panel, withScreen(tools.screens.panel)), want)
    equal(played(hubHost, withScreen(tools.screens.hub)), want)
    local records, session = played(hubHost, withScreen(tools.screens.hub, { hubOnly = true, server = false }))
    equal(records, want)
    equal(session.hubOnly, true)
    local _, effects = hubHost.apply(session, { t = "level", y = 71 })
    equal(effects[1].localApply, true)
    equal(effects[1].to, false)
    equal(effects[1].discover, nil)
  end)

  test("the panel plan tab is one hook and it is not added twice", function()
    local ui = { tab = "home" }
    local tabs = { { "home", "Home" } }
    local tabColor = {}
    panel.hook(ui, tabs, tabColor)
    equal(tabs[2][1], "plan")
    equal(ui.tab, "home")
    panel.hook(ui, tabs, tabColor)
    equal(#tabs, 2)
  end)
end
