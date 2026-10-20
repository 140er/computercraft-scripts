return function(test, read, mocks)
  local function decode(text)
    return assert(load("return " .. text, "=cfg", "t", {}))()
  end

  local function sandbox()
    local m = mocks.new(false)
    local env = m.env
    env.dofile = function(path) return assert(loadfile(path, "t", env))() end
    env.os.pullEventRaw = env.os.pullEvent
    return m, env
  end

  local function mentions(output, needle)
    local n, from, blob = 0, 1, table.concat(output, "\n")
    while true do
      local at = blob:find(needle, from, true)
      if not at then return n end
      n, from = n + 1, at + #needle
    end
  end

  local function pose(x, y, z)
    return {
      v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
      x = x, y = y, z = z, h = 0, conf = "certain", src = "typed", anchoredAt = 1000,
    }
  end

  test("fleet defaults are on and a stored false survives a module reload", function()
    local function loadFleet()
      local env = mocks.new(false).env
      env.textutils.serialize = mocks.encode
      env.dofile = function(path) return assert(loadfile(path, "t", env))() end
      return env.dofile("wh2-fleet.lua")
    end
    local first = loadFleet()
    local defaults = first.defaults()
    for _, key in ipairs({
      "enabled", "navigation", "mining", "warehouse", "sorting", "smelting", "crafting",
      "forestry", "farming", "building", "lavaCollection", "following", "autoCharge",
      "autoDropoff", "traffic", "offlineAutonomy", "avoidFluids", "containFluids",
      "fallingRetry", "blockedRetry", "rerouteBlocked", "reanchor", "stuckBackoff", "unbreakableDetour",
    }) do
      assert(defaults[key] == true, key)
    end
    assert(defaults.compactInventory == false and defaults.filteredTrash == false and defaults.stuckSkip == false)
    local stored = {
      v = 1, revision = 1, global = {}, roles = {},
      computers = { ["17"] = { autoCharge = false, mining = false } },
    }
    local off = first.effective(stored, 17, "miner")
    assert(off.autoCharge == false and off.mining == false and off.enabled == true and off.traffic == true)
    assert(first.effective(stored, 18, "miner").autoCharge == true and first.effective(stored, 18, "miner").mining == true)
    local second = loadFleet()
    local again = second.effective(stored, 17, "miner")
    assert(again.autoCharge == false and again.mining == false and again.forestry == true)
    assert(stored.computers["17"].autoCharge == false and stored.computers["17"].mining == false)
  end)

  test("a miner with a pairing key and one server opts into the fleet", function()
    local source = read("miner.lua")
    assert(source:find("traffic=cfg.nav.traffic==true", 1, true), "nav open still requires an explicit true")
    local m = mocks.miner({ home = { x = 1, y = 65, z = 0 }, facing = 2, spine = 1 })
    local env = m.env
    local asks = 0
    m.files["fleet-boot.lua"] = "return {}"
    m.files["plug.lua"] = "return {}"
    m.files["install.cfg"] = mocks.encode({ pairingKey = "paired-key-123456" })
    env.dofile = function(path) return assert(loadfile(path, "t", env))() end
    env.rednet.lookup = function() return 4 end
    env.gps = { locate = function() return 1, 65, 0 end }
    env.read = function()
      asks = asks + 1
      return "minecraft:overworld"
    end
    env.parallel.waitForAny = function() end
    local app = assert(load(source .. "\nreturn {C=C,cfg=cfg}", "=miner.lua", "t", env))()
    assert(app.C.fleetOptIn == true)
    assert(app.cfg.wh2 == nil)
    assert(app.cfg.ssot.enabled == true and app.cfg.ssot.server == 4)
    assert(app.cfg.ssot.dimension == "minecraft:overworld" and app.cfg.ssot.secret == "paired-key-123456")
    assert(app.cfg.nav.enabled == true and app.cfg.nav.traffic == true)
    assert(app.cfg.nav.bounds.min.x == -95 and app.cfg.nav.bounds.max.x == 97)
    assert(app.cfg.nav.bounds.min.y == -31 and app.cfg.nav.bounds.max.z == 96)
    assert(app.cfg.mining.home.dim == "minecraft:overworld" and app.cfg.mining.home.h == 2)
    assert(app.cfg.mining.home.x == 1 and app.cfg.mining.home.y == 65 and app.cfg.mining.home.z == 0)
    assert(app.cfg.mining.enabled == nil)
    assert(asks == 1)
    assert(mentions(m.output, "keeps its own route") == 0)
    local saved = decode(m.files["miner.cfg"])
    assert(saved.ssot.server == 4 and saved.nav.traffic == true and saved.wh2 == nil)
    local boot = env.dofile("fleet-boot.lua")
    local plug = env.dofile("plug.lua")
    boot.miner(app.cfg, plug, function(spec)
      return plug.ask(plug.termio(), spec)
    end, function() end)
    assert(asks == 1)
  end)

  test("a miner with no pairing key keeps its own route and asks nothing", function()
    local source = read("miner.lua")
    local m = mocks.miner({ home = { x = 1, y = 65, z = 0 }, facing = 2, spine = 1 })
    local env = m.env
    local asks = 0
    m.files["fleet-boot.lua"] = "return {}"
    m.files["plug.lua"] = "return {}"
    env.dofile = function(path) return assert(loadfile(path, "t", env))() end
    env.rednet.lookup = function() return 4 end
    env.read = function()
      asks = asks + 1
      return "minecraft:overworld"
    end
    env.parallel.waitForAny = function() end
    local app = assert(load(source .. "\nreturn {C=C,cfg=cfg}", "=miner.lua", "t", env))()
    assert(app.C.fleetOptIn == false and app.cfg.ssot == nil and app.cfg.nav == nil)
    assert(asks == 0)
    assert(mentions(m.output, "keeps its own route") == 1)
    assert(decode(m.files["miner.cfg"]).ssot == nil)
  end)

  test("explicit miner flags stay off and a stored traffic false stays false", function()
    local source = read("miner.lua")
    local function boot(cfg)
      local m = mocks.miner(cfg)
      local env = m.env
      local asks = 0
      m.files["fleet-boot.lua"] = "return {}"
      m.files["plug.lua"] = "return {}"
      m.files["install.cfg"] = mocks.encode({ pairingKey = "paired-key-123456" })
      env.dofile = function(path) return assert(loadfile(path, "t", env))() end
      env.rednet.lookup = function() return 4 end
      env.gps = { locate = function() return cfg.home.x, cfg.home.y, cfg.home.z end }
      env.read = function()
        asks = asks + 1
        return "minecraft:overworld"
      end
      env.parallel.waitForAny = function() end
      local app = assert(load(source .. "\nreturn {C=C,cfg=cfg}", "=miner.lua", "t", env))()
      return app, asks, mentions(m.output, "keeps its own route")
    end
    local home = { x = 1, y = 65, z = 0 }
    local off, asks, notes = boot({ home = home, facing = 2, spine = 1, wh2 = { enabled = false } })
    assert(off.C.fleetOptIn == false and off.cfg.ssot == nil and asks == 0 and notes == 0)
    local ssotOff, ssotAsks, ssotNotes = boot({
      home = home, facing = 2, spine = 1, ssot = { enabled = false },
    })
    assert(ssotOff.C.fleetOptIn == false and ssotOff.cfg.ssot.enabled == false and ssotOff.cfg.ssot.server == nil)
    assert(ssotAsks == 0 and ssotNotes == 1)
    local quiet, quietAsks = boot({
      home = home, facing = 0, spine = 1, nav = { traffic = false },
    })
    assert(quiet.C.fleetOptIn == true and quiet.cfg.nav.traffic == false and quiet.cfg.nav.enabled == true)
    assert(quiet.cfg.mining.home.h == 0 and quietAsks == 1)
  end)

  test("lumber fills wh2.cfg from lookup and does not wait on a disabled fleet", function()
    local function run(files, answers)
      local m, env = sandbox()
      local asks, moved = 0, 0
      local settings = env.dofile("wh2-fleet.lua").defaults()
      for name, body in pairs(files) do m.files[name] = body end
      m.files["fleet-boot.lua"] = m.files["fleet-boot.lua"] or "return {}"
      m.files["plug.lua"] = "return {}"
      env.turtle = {
        forward = function() moved = moved + 1 return true end,
        getItemCount = function() return 0 end,
        getFuelLevel = function() return 500 end,
        getFuelLimit = function() return 20000 end,
      }
      env.gps = nil
      env.rednet.lookup = function() return 4 end
      env.read = function()
        asks = asks + 1
        return answers[asks]
      end
      env.loadfile = function()
        return function() assert(env.turtle.forward()) end
      end
      env.dofile = function(path)
        if path == "ssot-client.lua" then
          return { new = function(cfg) m.bootstrap = cfg return { boot = "test" } end }
        end
        if path == "wh2-client.lua" then
          return { new = function()
            return {
              tick = function() return true end,
              ready = function() return true end,
              settings = function() return settings end,
              status = function() return {} end,
              dispatch = function() return false end,
            }
          end }
        end
        return assert(loadfile(path, "t", env))()
      end
      local program = env.dofile("wh2-program.lua")
      local co = coroutine.create(function() return program.run("lumber.lua") end)
      local function step(...)
        local ok, err = coroutine.resume(co, ...)
        assert(ok, err)
      end
      step()
      local limit = 30
      while coroutine.status(co) ~= "dead" and #m.queued > 0 do
        limit = limit - 1
        assert(limit > 0, "event loop did not settle")
        local event = table.remove(m.queued, 1)
        step(table.unpack(event, 1, event.n))
      end
      return m, asks, moved, coroutine.status(co)
    end
    local m, asks, moved, status = run({
      ["install.cfg"] = mocks.encode({ pairingKey = "paired-key-123456" }),
    }, { "minecraft:overworld" })
    assert(status == "dead" and moved == 1 and asks == 1)
    assert(mentions(m.output, "Fleet behavior is disabled") == 0)
    assert(mentions(m.output, "Standalone mode") == 0)
    local written = decode(m.files["wh2.cfg"])
    assert(written.enabled == true and written.server == 4)
    assert(written.dimension == "minecraft:overworld" and written.secret == "paired-key-123456")
    local env = m.env
    local boot = env.dofile("fleet-boot.lua")
    local plug = env.dofile("plug.lua")
    local extra = 0
    local again = boot.client({
      read = function() return written end,
      plug = plug,
      ask = function() extra = extra + 1 end,
      write = function() extra = extra + 10 end,
    })
    assert(again.enabled == true and extra == 0)
    local held = { enabled = false, server = 9 }
    local kept = boot.client({
      read = function() return held end,
      plug = plug,
      ask = function() extra = extra + 1 end,
      write = function() extra = extra + 10 end,
    })
    assert(kept == held and kept.enabled == false and extra == 0)
    local absent, absentAsks, absentMoved = run({}, { "minecraft:overworld" })
    assert(absentAsks == 0 and absentMoved == 0 and absent.files["wh2.cfg"] == nil)
    local blocked, blockedAsks, blockedMoved = run({
      ["wh2.cfg"] = mocks.encode({ enabled = false }),
      ["install.cfg"] = mocks.encode({ pairingKey = "paired-key-123456" }),
    }, { "minecraft:overworld" })
    assert(blockedAsks == 0 and blockedMoved == 0)
    assert(decode(blocked.files["wh2.cfg"]).enabled == false)
  end)

  test("a store with no traffic key opens navigation with traffic on", function()
    local function boot(traffic)
      local m, env = sandbox()
      local poseRow = { dim = "minecraft:overworld", x = 0, y = 65, z = 0, h = 0 }
      local warehouse = {
        pose = poseRow,
        bounds = {
          min = { dim = poseRow.dim, x = -2, y = 64, z = -2 },
          max = { dim = poseRow.dim, x = 2, y = 66, z = 2 },
        },
      }
      if traffic ~= nil then warehouse.traffic = traffic end
      m.files["warehouse.cfg"] = mocks.encode(warehouse)
      m.files["install.cfg"] = mocks.encode({ pairingKey = "paired-key-123456" })
      m.files["fleet-boot.lua"] = "return {}"
      m.files["plug.lua"] = "return {}"
      local asks, ticks = 0, 0
      local observed = {}
      local settings = env.dofile("wh2-fleet.lua").defaults()
      env.turtle = {
        getItemCount = function() return 0 end,
        getFuelLevel = function() return "unlimited" end,
        getFuelLimit = function() return "unlimited" end,
      }
      env.rednet.lookup = function() return 4 end
      env.read = function()
        asks = asks + 1
        return "minecraft:overworld"
      end
      env.sleep = function() coroutine.yield() end
      env.parallel.waitForAny = function(work)
        local co = coroutine.create(work)
        local ok, why = coroutine.resume(co)
        assert(ok, why)
      end
      env.dofile = function(path)
        if path == "ssot-client.lua" then return { new = function() return {} end } end
        if path == "wh2-client.lua" then
          return { new = function()
            return {
              ready = function() return true end,
              tick = function() return true end,
              settings = function() return settings end,
              dispatch = function() end,
              location = function() error("charge lookup") end,
            }
          end }
        end
        if path == "nav.lua" then
          return { open = function(options)
            observed.nav = options
            return { recover = function() return true end, configure = function() end, fleetPose = function() return poseRow end }
          end }
        end
        if path == "warehouse.lua" then
          return { open = function()
            return { tick = function() ticks = ticks + 1 return true end, state = function() return { phase = "idle" } end, next = function() end }
          end }
        end
        return assert(loadfile(path, "t", env))()
      end
      assert(loadfile("store.lua", "t", env))()
      return m, asks, ticks, observed
    end
    local m, asks, ticks, observed = boot(nil)
    assert(asks == 1 and ticks == 1 and observed.nav.traffic == true)
    assert(mentions(m.output, "Warehouse behavior is disabled") == 0)
    local written = decode(m.files["wh2.cfg"])
    assert(written.enabled == true and written.server == 4 and written.dimension == "minecraft:overworld")
    local _, quietAsks, quietTicks, quiet = boot(false)
    assert(quietAsks == 1 and quietTicks == 1 and quiet.nav.traffic == false)
  end)

  test("a cancelled question keeps the facts already found", function()
    local m, env = sandbox()
    m.files["plug.lua"] = "return {}"
    m.files["install.cfg"] = mocks.encode({ pairingKey = "paired-key-123456" })
    env.rednet.lookup = function() return 4 end
    local answers = { nil, "minecraft:overworld" }
    local asks = 0
    env.read = function()
      asks = asks + 1
      return answers[asks]
    end
    local boot = env.dofile("fleet-boot.lua")
    local plug = env.dofile("plug.lua")
    local function ask(spec)
      return plug.ask(plug.termio(), spec)
    end
    local stored
    local function host()
      return {
        read = function() return stored end,
        plug = plug,
        ask = ask,
        write = function(_, value) stored = value end,
      }
    end
    local partial = boot.client(host())
    assert(asks == 1 and partial.enabled == nil and partial.server == 4 and partial.secret == "paired-key-123456")
    assert(stored.dimension == nil and stored.enabled == nil)
    local done = boot.client(host())
    assert(asks == 2 and done.enabled == true and done.dimension == "minecraft:overworld" and done.server == 4)
    local cfg = { home = { x = 1, y = 65, z = 0 }, facing = 2 }
    local saved
    answers = { nil, "minecraft:overworld" }
    asks = 0
    local function save(nextCfg) saved = nextCfg end
    local held = boot.miner(cfg, plug, ask, save)
    assert(asks == 1 and held.ssot.server == 4 and held.ssot.enabled ~= true and held.nav == nil)
    local finished = boot.miner(saved, plug, ask, save)
    assert(asks == 2 and finished.ssot.enabled == true and finished.nav.traffic == true and finished.mining.home.h == 2)
  end)

  test("a lease with default settings takes the local offline path", function()
    local _, env = sandbox()
    local Lease = env.dofile("lease.lua")
    local W1 = env.dofile("lib/stubs/b1_w1.lua")
    local home = pose(0, 64, 0)
    local lease = {
      grant = "work", issuedAt = 0, untilAt = 1000000, workUntil = 1000000,
      frame = "abs", home = home, corridor = { home },
      area = { min = pose(0, 64, 0), max = pose(1, 64, 0) },
    }
    local from, to = pose(0, 64, 0), pose(1, 64, 0)
    local snap = W1.snapshot(0)
    assert(snap.values.offlineAutonomy == true and snap.values.journalMaxBytes == false)
    assert(Lease.authorize({
      lease = lease, settings = snap, from = from, to = to, now = 1000, home = home,
    }) == "local")
    local blocked, why = Lease.authorize({
      lease = lease, settings = W1.snapshot(0, { offlineAutonomy = false }),
      from = from, to = to, now = 1000, home = home,
    })
    assert(blocked == "rpc" and why == "offline autonomy disabled")
  end)
end
