return function(test, equal, read, mocks)
  local function world(enrolOn)
    local m = mocks.new(false)
    m.env.dofile = function(path) return assert(loadfile(path, "t", m.env))() end
    m.env.os.getComputerID = function() return 1 end
    local ViewPair = m.env.dofile("view-pair.lua")
    local Enrol = m.env.dofile("enrol.lua")
    local clock = { n = 5000000 }
    local cfg = { controllers = {} }
    if enrolOn == true then cfg.enrol = true
    elseif enrolOn == false then cfg.enrol = false end
    local sent, logs = {}, {}
    local io = {
      cfg = cfg, fs = m.env.fs, computerId = 1,
      now = function() return clock.n end,
      save = function()
        m.files["ssot.cfg"] = m.env.textutils.serialize(cfg)
        return true
      end,
      log = function(id, verb) logs[#logs + 1] = tostring(id) .. " " .. tostring(verb) end,
      rednet = { send = function(id, msg, proto)
        sent[#sent + 1] = { id = id, msg = msg, proto = proto }
      end },
    }
    io.save()
    return m, ViewPair, Enrol, cfg, io, sent, logs, clock
  end

  local function flat(value)
    if type(value) ~= "table" then return tostring(value) end
    local parts = {}
    for key, item in pairs(value) do
      parts[#parts + 1] = flat(key)
      parts[#parts + 1] = flat(item)
    end
    return table.concat(parts, "\n")
  end

  local function bytes(rng)
    return function() return rng end
  end

  test("second hub hosts view-<id> and an explicit pair stays put", function()
    local m, ViewPair = world(false)
    local second = ViewPair.decide({}, {
      computerId = 12, hubNameFree = false, hostError = "Hostname in use", ar = false, localKey = false,
    })
    assert(second.ok, second.error)
    equal(second.hostname, "view-12")
    equal(second.runView, true)
    equal(second.ask, true)
    local quiet = ViewPair.decide({}, { computerId = 3, hubNameFree = true, ar = false, localKey = false })
    equal(quiet.hostname, "hub")
    equal(quiet.runView, false)
    equal(quiet.ask, false)
    local shown = ViewPair.decide({ enabled = true }, { computerId = 3, hubNameFree = true, ar = false, localKey = false })
    equal(shown.hostname, "hub")
    equal(shown.runView, true)
    equal(shown.ask, true)
    local glasses = ViewPair.decide({}, { computerId = 3, hubNameFree = true, ar = true, localKey = false })
    equal(glasses.hostname, "hub")
    equal(glasses.runView, false)
    equal(glasses.ask, true)
    local views = { server = 0, secret = string.rep("s", 16), mode = "map", dim = "minecraft:overworld" }
    local before = mocks.encode(views)
    m.files["views.cfg"] = m.env.textutils.serialize(views)
    local file = m.files["views.cfg"]
    local explicit = ViewPair.decide(views, {
      computerId = 12, hubNameFree = false, hostError = "Hostname in use", ar = true, localKey = false,
    })
    assert(explicit.ok, explicit.error)
    equal(explicit.hostname, "view-12")
    equal(explicit.ask, false)
    equal(explicit.runView, true)
    equal(mocks.encode(views), before)
    equal(m.files["views.cfg"], file)
    local parked = { server = 0, secret = string.rep("s", 16), enabled = false }
    m.files["views.cfg"] = m.env.textutils.serialize(parked)
    local parkedFile = m.files["views.cfg"]
    local parkedBoot = ViewPair.decide(parked, {
      computerId = 12, hubNameFree = false, hostError = "Hostname in use", ar = false, localKey = false,
    })
    assert(not parkedBoot.ok)
    assert(tostring(parkedBoot.error):find("Hostname in use", 1, true))
    equal(m.files["views.cfg"], parkedFile)
    local numbered = { server = 4, secret = string.rep("n", 16), enabled = true }
    local kept = ViewPair.decide(numbered, { computerId = 4, hubNameFree = true, ar = true, localKey = false })
    equal(kept.ask, false)
    equal(kept.runView, true)
    equal(numbered.secret, string.rep("n", 16))
    local localKey = ViewPair.decide({}, {
      computerId = 8, hubNameFree = false, hostError = "Hostname in use", ar = false, localKey = true,
    })
    equal(localKey.ask, false)
    equal(localKey.hostname, "view-8")
    local blocked = ViewPair.decide({ enabled = false }, {
      computerId = 9, hubNameFree = false, hostError = "Hostname in use", ar = true, localKey = false,
    })
    assert(not blocked.ok)
    assert(tostring(blocked.error):find("Hostname in use", 1, true))
    assert(blocked.hostname == nil)
    local other = ViewPair.decide({ enabled = true }, {
      computerId = 10, hubNameFree = false, hostError = "Modem unavailable", ar = false, localKey = false,
    })
    assert(not other.ok)
    assert(tostring(other.error):find("Modem unavailable", 1, true))
    local secret, server = ViewPair.localSecret(
      { secret = string.rep("a", 16), server = 0 },
      { controllers = { ["3"] = string.rep("b", 16) } }, 3)
    equal(secret, string.rep("a", 16))
    equal(server, 0)
    equal(ViewPair.localSecret({}, { controllers = { ["3"] = string.rep("b", 16) } }, 3), string.rep("b", 16))
    local filled = ViewPair.fillViews({ mode = "pro", dim = "minecraft:overworld" }, 4, string.rep("k", 16), false)
    assert(filled.enabled == nil)
    equal(filled.server, 4)
    equal(filled.secret, string.rep("k", 16))
    equal(filled.mode, "pro")
    equal(filled.dim, "minecraft:overworld")
    equal(ViewPair.fillViews({ mode = "pro" }, 4, string.rep("k", 16), true).enabled, true)
  end)

  test("held and forId mismatch reject hello and claim without counting attempts", function()
    local m, _, Enrol = world(true)
    local store = Enrol.empty()
    local rng = bytes(4)
    local held = assert(Enrol.issue(store, 1000, 1, { role = "view", held = true, forId = 31 }, rng))
    local hello = Enrol.hello(store, 1000, 31, { codeId = held.id, nNew = "0123456789abcdef" }, 1, rng)
    equal(hello.error, "code_rejected")
    equal(store.codes[held.id].attempts, 0)
    local claim = Enrol.claim(store, 1000, 31, {
      codeId = held.id, nNew = "0123456789abcdef", nServer = "00112233445566778899aabbccddeeff", proof = "00",
    }, 1)
    equal(claim.error, "code_rejected")
    equal(store.codes[held.id].attempts, 0)
    assert(store.codes[held.id].code == held.code)
    local foreign = assert(Enrol.issue(store, 1000, 1, { role = "view", forId = 31 }, rng))
    for _ = 1, 6 do
      local denied = Enrol.hello(store, 1000, 99, { codeId = foreign.id, nNew = "0123456789abcdef" }, 1, rng)
      equal(denied.error, "code_rejected")
      local deniedClaim = Enrol.claim(store, 1000, 99, {
        codeId = foreign.id, nNew = "0123456789abcdef", nServer = "ff", proof = "00",
      }, 1)
      equal(deniedClaim.error, "code_rejected")
    end
    equal(store.codes[foreign.id].attempts, 0)
    assert(not store.codes[foreign.id].burned)
    local opened = Enrol.hello(store, 1000, 31, { codeId = foreign.id, nNew = "0123456789abcdef" }, 1, rng)
    assert(opened.ok, opened.error)
    local bad = Enrol.claim(store, 1000, 31, {
      codeId = foreign.id, nNew = "0123456789abcdef", nServer = opened.nServer, proof = "00",
    }, 1)
    equal(bad.error, "code_rejected")
    equal(store.codes[foreign.id].attempts, 1)
    local result = Enrol.operate(1, {
      op = "enrol-issue", role = "view", held = true, forId = 99, frame = "abs",
    }, function() return 1000 end, { controllers = {} }, m.env.fs)
    assert(result.ok and result.code and result.held == nil and result.forId == nil, result.error)
    local saved = assert(Enrol.load(m.env.fs))
    assert(saved.codes[result.id].held == nil)
    assert(saved.codes[result.id].forId == nil)
    local any = Enrol.hello(saved, 1000, 5, { codeId = result.id, nNew = "0123456789abcdef" }, 1, rng)
    assert(any.ok, any.error)
  end)

  test("enrol off writes nothing and the view does not wait out the code", function()
    local m, ViewPair, _, cfg, io, sent, _, clock = world(false)
    local before = m.files["ssot.cfg"]
    local ask = {
      v = 1, type = "ssot", op = "enrol-issue", role = "view", secret = "",
      expect = "ssot_reply", rid = "view-pair-31", boot = "view-31", counter = 1,
    }
    assert(ViewPair.offer(io, 31, ask) == false)
    equal(#sent, 0)
    equal(ViewPair.pending(io, clock.n), {})
    equal(m.files["ssot.cfg"], before)
    assert(not m.files["views.cfg"] and not m.files["enrol.store"])
    equal(cfg.controllers["31"], nil)
    local viewSent = {}
    local client = ViewPair.client({
      fs = m.env.fs,
      rednet = { send = function(id, msg, proto)
        viewSent[#viewSent + 1] = { id = id, msg = msg, proto = proto }
      end },
      now = function() return clock.n end,
      computerId = 31, enableView = true,
      lookup = function() return 1 end,
    })
    client.start()
    equal(#viewSent, 1)
    equal(viewSent[1].msg.secret, "")
    equal(viewSent[1].msg.role, "view")
    clock.n = clock.n + 5000
    assert(client.handle("timer", 1) == nil)
    client.handle("rednet_message", 1, { v = 1, type = "ssot_reply", ok = true, rid = viewSent[1].msg.rid, pending = true, server = 1 }, "fleetserver")
    client.handle("rednet_message", 1, { v = 1, type = "pair-code", codeId = "c:1:1", code = "0123456789ABCDEF", server = 1 }, "fleetserver")
    equal(#viewSent, 1)
    assert(not m.files["views.cfg"])
    equal(m.files["ssot.cfg"], before)
    equal(ViewPair.pending(io, clock.n), {})
  end)

  local function finish(m, ViewPair, Enrol, io, sent, clock, enableView, owner)
    local viewSent = {}
    local client = ViewPair.client({
      fs = m.env.fs,
      rednet = { send = function(id, msg, proto)
        viewSent[#viewSent + 1] = { id = id, msg = msg, proto = proto }
      end },
      now = function() return clock.n end,
      computerId = 31, enableView = enableView,
      lookup = function() return 1 end,
      owner = owner,
    })
    client.start()
    local ask = viewSent[#viewSent].msg
    assert(ViewPair.offer(io, 31, ask))
    local screen, code = {}, nil
    for _, row in ipairs(ViewPair.pending(io, clock.n)) do
      screen[#screen + 1] = ViewPair.rowText(row)
      code = row.code
      assert(row.key == nil)
    end
    local note = ViewPair.accept(io, 31)
    local delivery
    for _, item in ipairs(sent) do
      if item.msg and item.msg.type == "pair-code" then delivery = item.msg end
    end
    assert(delivery, "accept did not deliver the copy code")
    assert(client.handle("rednet_message", 1, delivery, "fleetserver") == nil)
    local helloMsg = viewSent[#viewSent].msg
    assert(helloMsg.op == "enrol-hello", helloMsg.op)
    local store = assert(Enrol.load(m.env.fs))
    local hello = Enrol.hello(store, clock.n, 31, helloMsg, 1, math.random)
    assert(hello.ok, hello.error)
    assert(Enrol.save(m.env.fs, store))
    hello.v, hello.type, hello.rid, hello.server = 1, "ssot_reply", helloMsg.rid, 1
    assert(client.handle("rednet_message", 1, hello, "fleetserver") == nil)
    local claimMsg = viewSent[#viewSent].msg
    assert(claimMsg.op == "enrol-claim", claimMsg.op)
    store = assert(Enrol.load(m.env.fs))
    local claimed = Enrol.claim(store, clock.n, 31, claimMsg, 1)
    assert(claimed.ok, claimed.error)
    assert(claimed.key == nil)
    assert(Enrol.save(m.env.fs, store))
    claimed.v, claimed.type, claimed.rid = 1, "ssot_reply", claimMsg.rid
    assert(client.handle("rednet_message", 1, claimed, "fleetserver") == nil)
    ViewPair.observe(io, 31, "enrol-claim", claimed)
    local done
    for _, item in ipairs(sent) do
      if item.msg and item.msg.type == "pair-done" then done = item.msg end
    end
    assert(done, "claim did not finish pairing")
    local saved = client.handle("rednet_message", 1, done, "fleetserver")
    return saved, code, table.concat(screen, "\n"), note, viewSent, delivery, claimMsg
  end

  test("accept writes the controller and views.cfg without sending the pairing key", function()
    local m, ViewPair, Enrol, cfg, io, sent, logs, clock = world(true)
    local authed = string.rep("k", 16)
    cfg.controllers["1"] = authed
    assert(ViewPair.offer(io, 1, { op = "enrol-issue", role = "view", secret = authed }) == false)
    assert(ViewPair.offer(io, 1, { op = "enrol-issue", role = "miner", secret = authed }) == false)
    cfg.controllers["1"] = nil
    local saved, code, screen, note, viewSent, delivery, claimMsg = finish(m, ViewPair, Enrol, io, sent, clock, true)
    assert(type(saved) == "table", "views.cfg was not written")
    equal(saved.server, 1)
    equal(saved.enabled, true)
    local key = Enrol.pairingKey(code, {
      id = 31, server = 1, codeId = delivery.codeId, nNew = claimMsg.nNew, nServer = claimMsg.nServer,
      newPub = "", serverPub = "",
    })
    equal(saved.secret, key)
    equal(cfg.controllers["31"], key)
    equal(cfg.arControllers, nil)
    equal(cfg.chatNames, nil)
    local disk = m.env.textutils.unserialize(m.files["views.cfg"])
    equal(disk.server, 1)
    equal(disk.secret, key)
    local auth = m.env.textutils.unserialize(m.files["ssot.cfg"])
    equal(auth.controllers["31"], key)
    assert(screen:find(code, 1, true), "copy code missing from the screen")
    assert(not screen:find(key, 1, true), "pairing key on the screen")
    assert(note:find("31", 1, true) and not note:find(code, 1, true) and not note:find(key, 1, true))
    local logText = table.concat(logs, "\n")
    assert(logText:find("31 accept", 1, true), logText)
    assert(not logText:find(code, 1, true) and not logText:find(key, 1, true), logText)
    local payloads = flat(sent) .. "\n" .. flat(viewSent)
    assert(not payloads:find(key, 1, true), "pairing key in a rednet payload")
    local copies = 0
    for _, item in ipairs(sent) do
      if item.msg and item.msg.code == code then
        copies = copies + 1
        equal(item.msg.type, "pair-code")
        assert(item.msg.key == nil and item.msg.secret == nil)
      end
      assert(item.msg.key == nil and item.msg.secret == nil)
    end
    equal(copies, 1)
    for _, item in ipairs(viewSent) do
      assert(item.msg.code == nil and item.msg.key == nil and item.msg.secret == "")
    end
    assert(delivery.code == code and delivery.codeId)
  end)

  test("deny and an expired code leave both files unchanged", function()
    local m, ViewPair, Enrol, cfg, io, _, logs, clock = world(true)
    local old = string.rep("p", 16)
    cfg.controllers["8"] = old
    io.save()
    local ask = {
      v = 1, type = "ssot", op = "enrol-issue", role = "view", secret = "",
      expect = "ssot_reply", rid = "view-pair-31", boot = "view-31", counter = 1,
    }
    assert(ViewPair.offer(io, 31, ask))
    local pending = ViewPair.pending(io, clock.n)
    equal(#pending, 1)
    equal(pending[1].computerId, 31)
    local beforeCfg, beforeViews = m.files["ssot.cfg"], m.files["views.cfg"]
    local store = assert(Enrol.load(m.env.fs))
    local effect = ViewPair.step(store, cfg, { t = "deny", computerId = 31 }, clock.n)
    assert(effect.key == nil and effect.deliver == nil)
    equal(cfg.controllers["8"], old)
    equal(cfg.controllers["31"], nil)
    local note = ViewPair.deny(io, 31)
    equal(m.files["ssot.cfg"], beforeCfg)
    equal(m.files["views.cfg"], beforeViews)
    equal(ViewPair.pending(io, clock.n), {})
    assert(note:find("31", 1, true) and not note:find(pending[1].code, 1, true))
    local logText = table.concat(logs, "\n")
    assert(logText:find("31 deny", 1, true) and not logText:find(pending[1].code, 1, true), logText)
    cfg.controllers["44"] = old
    io.save()
    assert(ViewPair.offer(io, 44, ask))
    local rotating = ViewPair.pending(io, clock.n)
    equal(#rotating, 1)
    beforeCfg = m.files["ssot.cfg"]
    ViewPair.deny(io, 44)
    equal(cfg.controllers["44"], old)
    equal(m.files["ssot.cfg"], beforeCfg)
    assert(not m.files["views.cfg"])
    assert(ViewPair.offer(io, 31, ask))
    local issued = ViewPair.pending(io, clock.n)
    equal(#issued, 1)
    local loaded = assert(Enrol.load(m.env.fs))
    local late = ViewPair.step(loaded, cfg, { t = "accept", computerId = 31 }, clock.n + 120001)
    assert(late.key == nil and late.deliver == nil)
    beforeCfg, beforeViews = m.files["ssot.cfg"], m.files["views.cfg"]
    clock.n = clock.n + 120001
    ViewPair.accept(io, 31)
    equal(m.files["ssot.cfg"], beforeCfg)
    equal(m.files["views.cfg"], beforeViews)
    equal(cfg.controllers["31"], nil)
    equal(ViewPair.pending(io, clock.n), {})
  end)

  test("a second accept leaves the stored key in place", function()
    local m, ViewPair, Enrol, cfg, io, sent, _, clock = world(true)
    local saved, code, _, _, _, delivery, claimMsg = finish(m, ViewPair, Enrol, io, sent, clock, true)
    local key = saved.secret
    equal(cfg.controllers["31"], key)
    local store = assert(Enrol.load(m.env.fs))
    local again = ViewPair.step(store, cfg, { t = "ask", computerId = 31, hasLocal = true, issuer = 1 }, clock.n)
    assert(again.key == nil)
    equal(cfg.controllers["31"], key)
    local before = m.files["ssot.cfg"]
    local views = m.files["views.cfg"]
    assert(ViewPair.offer(io, 31, {
      v = 1, type = "ssot", op = "enrol-issue", role = "view", secret = "", hasLocal = true,
      expect = "ssot_reply", rid = "view-pair-31", boot = "view-31", counter = 1,
    }))
    equal(ViewPair.pending(io, clock.n), {})
    ViewPair.accept(io, 31)
    equal(ViewPair.pending(io, clock.n), {})
    equal(cfg.controllers["31"], key)
    equal(m.files["ssot.cfg"], before)
    equal(m.files["views.cfg"], views)
    local payloads = flat(sent)
    assert(not payloads:find(key, 1, true))
    assert(code == delivery.code and claimMsg.op == "enrol-claim")
  end)

  test("a missing enrol flag still shows the pairing request", function()
    local m, ViewPair, _, cfg, io, sent, _, clock = world()
    equal(cfg.enrol, nil)
    local ask = {
      v = 1, type = "ssot", op = "enrol-issue", role = "view", secret = "",
      expect = "ssot_reply", rid = "view-pair-31", boot = "view-31", counter = 1,
    }
    assert(ViewPair.offer(io, 31, ask))
    equal(#ViewPair.pending(io, clock.n), 1)
    equal(#sent, 1)
    equal(sent[1].msg.pending, true)
    assert(sent[1].msg.code == nil and sent[1].msg.key == nil and sent[1].msg.secret == nil)
    assert(m.files["enrol.store"])
    assert(not m.files["views.cfg"])
    equal(cfg.controllers["31"], nil)
  end)

  test("accept of an AR computer fills the owner allowlist", function()
    local m, ViewPair, Enrol, cfg, io, sent, logs, clock = world(true)
    local uuid = "11111111-2222-3333-4444-555555555555"
    local saved, code, screen, _, viewSent, delivery, claimMsg = finish(
      m, ViewPair, Enrol, io, sent, clock, true, { name = "Ada_1", uuid = uuid })
    local key = Enrol.pairingKey(code, {
      id = 31, server = 1, codeId = delivery.codeId, nNew = claimMsg.nNew, nServer = claimMsg.nServer,
      newPub = "", serverPub = "",
    })
    equal(saved.secret, key)
    equal(cfg.controllers["31"], key)
    equal(cfg.arControllers["31"].name, "Ada_1")
    equal(cfg.arControllers["31"].uuid, uuid)
    local listed = false
    for _, name in ipairs(cfg.chatNames) do if name == "Ada_1" then listed = true end end
    assert(listed, "owner missing from the chat allowlist")
    equal(cfg.chatUUIDs["Ada_1"], uuid)
    local auth = m.env.textutils.unserialize(m.files["ssot.cfg"])
    equal(auth.arControllers["31"].name, "Ada_1")
    equal(auth.arControllers["31"].uuid, uuid)
    equal(auth.chatUUIDs["Ada_1"], uuid)
    assert(viewSent[1].msg.ownerName == "Ada_1" and viewSent[1].msg.ownerUUID == uuid)
    assert(delivery.ownerName == nil and delivery.ownerUUID == nil and delivery.key == nil)
    local shown = screen .. "\n" .. table.concat(logs, "\n") .. "\n" .. flat(sent)
    assert(not shown:find(key, 1, true), "pairing key left the controller file")
    assert(not screen:find(uuid, 1, true) and not table.concat(logs, "\n"):find(uuid, 1, true))
  end)

  test("a bad or conflicting AR owner still pairs and leaves that enrolment unchanged", function()
    local m, ViewPair, Enrol, cfg, io, sent, _, clock = world(true)
    local saved = finish(m, ViewPair, Enrol, io, sent, clock, true, { name = "Ada_1", uuid = "not-a-uuid" })
    equal(cfg.controllers["31"], saved.secret)
    equal(cfg.arControllers, nil)
    equal(cfg.chatNames, nil)
    local other = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    local uuid = "11111111-2222-3333-4444-555555555555"
    local n, ViewPair2, Enrol2, cfg2, io2, sent2, _, clock2 = world(true)
    cfg2.arControllers = { ["31"] = { name = "Other", uuid = other } }
    cfg2.chatUUIDs = { Ada_1 = "22222222-3333-4444-5555-666666666666" }
    cfg2.chatNames = { "Ada_1" }
    io2.save()
    local kept = finish(n, ViewPair2, Enrol2, io2, sent2, clock2, true, { name = "Ada_1", uuid = uuid })
    equal(cfg2.controllers["31"], kept.secret)
    equal(cfg2.arControllers["31"].name, "Other")
    equal(cfg2.arControllers["31"].uuid, other)
    equal(cfg2.chatUUIDs.Ada_1, "22222222-3333-4444-5555-666666666666")
  end)

  test("ssot-client ignores an enrol reply that has no auth", function()
    local m = mocks.new(false)
    m.env.dofile = function(path) return assert(loadfile(path, "t", m.env))() end
    local Client = m.env.dofile("ssot-client.lua")
    local secret = "test-secret-123456"
    local client = Client.new({ server = 4, secret = secret, counterFile = "view-pair-auth.counter", timeout = 0.05 })
    local timerId = 0
    local startTimer = m.env.os.startTimer
    m.env.os.startTimer = function(delay)
      timerId = startTimer(delay)
      return timerId
    end
    m.env.os.pullEvent = function() return "timer", timerId end
    local function call(withAuth)
      local send = m.env.rednet.send
      m.env.rednet.send = function(_, msg, protocol)
        local reply = { v = 1, type = "ssot_reply", server = 4, rid = msg.rid, ok = true, op = "enrol-claim" }
        if withAuth then reply.auth = secret end
        client.dispatch(4, reply, protocol)
      end
      local ok, reply = pcall(function() return client.sync({ pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 } }) end)
      m.env.rednet.send = send
      assert(ok, reply)
      return reply
    end
    local accepted = call(true)
    assert(accepted and accepted.ok and accepted.auth == secret)
    assert(call(false) == nil)
  end)
end
