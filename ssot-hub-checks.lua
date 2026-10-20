-- S1 hub profile, authority handover, and idempotent import.
return function(S, A, test)
  local T1 = dofile("s1_t1.lua")
  local secret = "pairing-secret-0123456789"
  local function box(profile, holder, extra, keys)
    local saved = { s = {}, time = 1000000, counter = 0 }
    local cfg = {
      hubProfile = true, profile = profile, holder = holder,
      joining = extra and extra.joining or false,
      pageRecords = extra and extra.pageRecords or nil,
      budget = extra and extra.budget or nil,
      controllers = { ["1"] = "test-secret-123456" },
      keys = keys,
      saveKeys = function() return true end,
    }
    local api = S.new(saved.s, cfg, function() return saved.time end, "boot-1", function(s)
      saved.s = A.copy(s)
      return true
    end)
    local function req(op, fields)
      saved.counter = saved.counter + 1
      local n = saved.counter
      local m = A.copy(fields or {})
      m.v, m.type, m.expect, m.op = 1, "ssot", "ssot_reply", op
      m.boot, m.rid, m.counter = "hub-test", "h" .. n, n
      m.secret = "test-secret-123456"
      return api.handle(1, m)
    end
    local node
    node = {
      req = req,
      reboot = function() return box(profile, holder, extra, keys) end,
      state = function() return api.state() end,
      keys = keys,
    }
    -- Reboot must keep the counter and the saved state, not a fresh box.
    node.reboot = function()
      local nextSaved = { s = saved.s, time = saved.time, counter = saved.counter }
      local nextCfg = {
        hubProfile = true, profile = profile, holder = holder,
        joining = cfg.joining, pageRecords = cfg.pageRecords, budget = cfg.budget,
        controllers = cfg.controllers, keys = keys, saveKeys = cfg.saveKeys,
      }
      local nextApi = S.new(nextSaved.s, nextCfg, function() return nextSaved.time end, "boot-1", function(s)
        nextSaved.s = A.copy(s)
        saved.s = nextSaved.s
        return true
      end)
      local function nextReq(op, fields)
        nextSaved.counter = nextSaved.counter + 1
        saved.counter = nextSaved.counter
        local n = nextSaved.counter
        local m = A.copy(fields or {})
        m.v, m.type, m.expect, m.op = 1, "ssot", "ssot_reply", op
        m.boot, m.rid, m.counter = "hub-test", "h" .. n, n
        m.secret = "test-secret-123456"
        return nextApi.handle(1, m)
      end
      local again = { keys = keys, state = function() return nextApi.state() end }
      again.req = nextReq
      again.reboot = node.reboot
      return again
    end
    return node
  end
  local function wire(value)
    return textutils.unserialize(textutils.serialize(value))
  end
  local function step(node, op, fields, crash)
    local result = node.req(op, fields)
    assert(result and result.ok, op .. " failed: " .. tostring(result and result.error))
    if not crash then return result, node end
    local again = node.reboot()
    local replay = again.req(op, fields)
    assert(replay and replay.ok, op .. " rerun failed: " .. tostring(replay and replay.error))
    return replay, again
  end
  local function encode(value)
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) ~= "table" then return tostring(value) end
    local keys, parts = {}, {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then return a < b end
      return type(a) < type(b)
    end)
    for _, key in ipairs(keys) do parts[#parts + 1] = "[" .. encode(key) .. "]=" .. encode(value[key]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  local function summary(server, hub, serverKeys)
    local s, h = server.state(), hub.state()
    local function dump(map)
      local lines = {}
      for k, v in pairs(map or {}) do lines[#lines + 1] = tostring(k) .. "=" .. encode(v) end
      table.sort(lines)
      return table.concat(lines, ";")
    end
    return table.concat({
      dump(s.plans), dump(s.fixtures), dump(s.bots), dump(s.codes), dump(s.leases),
      dump(s.poses), dump(s.moves), dump(serverKeys),
      encode(s.authority), h.handover.phase, tostring(h.authority.holder),
      tostring(h.authority.epoch), tostring(h.authority.kind),
    }, "\n")
  end

  test("hub profile stays off unless ssot.cfg asks for it", function()
    local api = S.new({}, { controllers = { ["1"] = "test-secret-123456" } }, function() return 1 end, "1", function() return true end)
    local r = api.handle(1, { v = 1, type = "ssot", expect = "ssot_reply", op = "hub-freeze",
      rid = "off", counter = 1, boot = "turtle", secret = "test-secret-123456" })
    assert(r and r.ok == false and r.error == "unknown operation")
    assert(api.state().authority == nil)
    assert(api.state().plans == nil)
  end)

  test("hub and server ledgers use one policy with the hub budget", function()
    local hub = box("hub", 7, nil, {})
    local server = box("server", 4, nil, {})
    local h = hub.req("hub-ledger")
    local s = server.req("hub-ledger")
    assert(h.ok and h.policy.budget == 300000 and h.policy.peers == false and h.policy.expand == "server")
    assert(h.policy.warnAt == 0.8 and h.ledger.v == 1 and h.canIssue == true)
    assert(s.ok and s.policy.budget == 900000 and s.policy.expand == "storage-turtles" and s.policy.peers == false)
    assert(hub.state().authority.kind == "hub" and hub.state().authority.holder == 7 and hub.state().authority.epoch == 1)
    assert(server.state().authority.kind == "server" and server.state().authority.epoch == 1)
  end)

  test("ids are minted from the holder and survive a restart", function()
    local hub = box("hub", 7, nil, {})
    local first = hub.req("hub-mint")
    local second = hub.req("hub-mint")
    assert(first.ok and first.id == "p:7:1" and second.id == "p:7:2")
    hub = hub.reboot()
    local third = hub.req("hub-mint")
    assert(third.ok and third.id == "p:7:3")
  end)

  test("a full disk refuses a plan and still accepts the handover freeze", function()
    local hub = box("hub", 7, { budget = 1 }, {})
    local minted = hub.req("hub-mint")
    assert(minted.ok)
    local put = hub.req("hub-put", { kind = "plan", body = {
      v = 1, frame = "abs", dim = "minecraft:overworld", y = 64, name = "Base", rev = 1,
      areas = {}, fixtures = {}, bots = {},
    } })
    assert(put and put.ok == false and put.error == "capacity")
    assert(next(hub.state().plans) == nil)
    local frozen = hub.req("hub-freeze")
    assert(frozen and frozen.ok and hub.state().authority.frozen == true)
  end)

  test("movement still reserves while the hub profile is on", function()
    local hub = box("hub", 7, nil, {})
    local p = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 }
    local to = { dim = "minecraft:overworld", x = 1, y = 64, z = 0 }
    assert(hub.req("sync", { pose = p }).ok)
    local grant = hub.req("reserve", { pose = p, to = to })
    assert(grant.ok and grant.token)
  end)

  local function handover(crash)
    local hubKeys, serverKeys = {}, {}
    local hub = box("hub", 7, { pageRecords = 1 }, hubKeys)
    local server = box("server", 4, { joining = true, pageRecords = 1 }, serverKeys)
    local planId = hub.req("hub-mint").id
    local areaId = hub.req("hub-mint").id
    local fixId = hub.req("hub-mint").id
    local botId = hub.req("hub-mint").id
    assert(planId == "p:7:1" and botId == "p:7:4")
    local function at(x, z, h)
      return T1.samplePos(x, 64, z, h or 0)
    end
    assert(hub.req("hub-put", { kind = "plan", body = {
      v = 1, id = planId, frame = "abs", dim = "minecraft:overworld", y = 64, name = "Base", rev = 3,
      areas = { { id = areaId, kind = "base", min = at(10, 20), max = at(20, 30) } },
      fixtures = { fixId }, bots = { botId },
    } }).ok)
    assert(hub.req("hub-put", { kind = "fixture", body = {
      v = 1, id = fixId, plan = planId, kind = "chest", pos = at(12, 20), side = "front",
      state = "planned", layoutId = false,
    } }).ok)
    assert(hub.req("hub-put", { kind = "bot", body = {
      v = 1, id = botId, plan = planId, role = "miner", pos = at(14, 20, 0),
      settings = { revision = 4, overrides = {} }, devToggles = {},
      jobArea = { min = at(14, 20), max = at(30, 40) },
      expect = { neighbours = { [2] = "minecraft:chest" }, peripherals = { back = "inventory" } },
      state = "planned", code = false, computerId = false,
    } }).ok)
    assert(hub.req("hub-put", { kind = "code", body = {
      v = 1, code = "K7Q2M3XDPT", issuer = 7, issuedAt = 1000000, untilAt = 5000000,
      role = "miner", used = false, attempts = 0, planBot = botId,
    } }).ok)
    assert(hub.req("hub-put", { kind = "code", body = {
      v = 1, code = "M3XDPTK7Q2", issuer = 7, issuedAt = 1000000, untilAt = 5000000,
      role = "miner", used = false, attempts = 0, planBot = false,
    } }).ok)
    assert(hub.req("hub-put", { kind = "code", body = {
      v = 1, code = "Q2M3XDPTK7", issuer = 7, issuedAt = 1000000, untilAt = 4000000,
      role = "miner", used = false, attempts = 1, planBot = false, claiming = true,
    } }).ok)
    assert(hub.req("hub-put", { kind = "lease", body = { v = 2, id = "7:mine:1", turtle = 17 } }).ok)
    assert(hub.req("hub-put", { kind = "pairing", body = {
      v = 1, id = "pair:31", computer = 31, key = secret,
    } }).ok)
    local pose = { dim = "minecraft:overworld", x = 10, y = 64, z = 20 }
    local dest = { dim = "minecraft:overworld", x = 11, y = 64, z = 20 }
    assert(hub.req("sync", { pose = pose }).ok)
    assert(hub.req("reserve", { pose = pose, to = dest }).ok)
    local cells = T1.cells(hub.state().fixtures[fixId])
    assert(cells[1].x == 12 and cells[1].z == 20)
    local frozen
    frozen, hub = step(hub, "hub-freeze", nil, crash)
    assert(frozen.count >= 8)
    assert(hub.state().authority.frozen == true)
    assert(hub.state().codes["Q2M3XDPTK7"].invalidated == true)
    assert(not hub.req("hub-put", { kind = "code", body = {
      v = 1, code = "K7Q2M3XDPQ", issuer = 7, issuedAt = 1000000, untilAt = 5000000,
      role = "miner", used = false, attempts = 0, planBot = false,
    } }).ok)
    local blocked = hub.req("hub-put", { kind = "lease", body = { v = 2, id = "7:mine:2", turtle = 18 } })
    assert(blocked.ok == false and blocked.error == "frozen")
    local function hasSecret(value)
      if type(value) == "string" then return value:find(secret, 1, true) ~= nil end
      if type(value) ~= "table" then return false end
      for k, v in pairs(value) do
        if hasSecret(k) or hasSecret(v) then return true end
      end
      return false
    end
    assert(not hasSecret(hub.state().handover.records), "pairing key landed in the handover snapshot")
    assert(not hasSecret(hub.state().plans) and not hasSecret(hub.state().codes))
    assert(hubKeys["pair:31"].key == secret)
    local pages, cursor = {}, 0
    repeat
      local page
      page, hub = step(hub, "hub-export", { cursor = cursor }, crash)
      pages[#pages + 1] = page
      cursor = page.next
    until page.done
    assert(#pages >= 2, "handover did not cross a page boundary")
    local hash = pages[1].manifest.hash
    local early = server.req("hub-take", {})
    assert(early.ok == false)
    assert(server.req("hub-ledger").canIssue == false)
    for _, page in ipairs(pages) do
      local body = wire({ records = page.records, manifest = page.manifest })
      local imported
      imported, server = step(server, "hub-import", body, crash)
      assert(imported.ok)
    end
    local again = server.req("hub-import", wire({ records = pages[1].records, manifest = pages[1].manifest }))
    assert(again.ok)
    assert(server.state().plans[planId].name == "Base")
    local function count(map)
      local n = 0
      for _ in pairs(map) do n = n + 1 end
      return n
    end
    local plans, codes = count(server.state().plans), count(server.state().codes)
    assert(plans == 1 and codes == 3)
    local taken
    taken, server = step(server, "hub-take", nil, crash)
    assert(taken.authority.holder == 4 and taken.authority.epoch == 2 and taken.authority.kind == "server")
    assert(taken.authority.frozen == false)
    local adopted
    adopted, hub = step(hub, "hub-adopt", { authority = taken.authority, hash = hash }, crash)
    assert(adopted.authority.holder == 4 and hub.state().handover.phase == "client")
    assert(hub.req("hub-ledger").canIssue == false)
    assert(server.req("hub-ledger").canIssue == true)
    local reissued
    reissued, server = step(server, "hub-reissue", nil, crash)
    assert(#reissued.codes == 1)
    local fresh = reissued.codes[1]
    assert(server.state().codes["K7Q2M3XDPT"].used == false)
    assert(server.state().codes["K7Q2M3XDPT"].untilAt == 5000000)
    assert(server.state().codes["M3XDPTK7Q2"].used == false)
    assert(server.state().codes["Q2M3XDPTK7"].invalidated == true)
    assert(server.state().codes[fresh].used == false and server.state().codes[fresh].invalidated == false)
    assert(serverKeys["pair:31"].key == secret)
    assert(server.state().poses[1].x == 10 and server.state().moves[1].to.x == 11)
    assert(server.state().leases["7:mine:1"].turtle == 17)
    assert(server.state().bots[botId].role == "miner")
    assert(server.state().fixtures[fixId].kind == "chest")
    local claim1 = server.req("hub-claim", { code = "K7Q2M3XDPT", proof = "claim-proof" })
    local claim2 = server.req("hub-claim", { code = "M3XDPTK7Q2", proof = "claim-proof" })
    local claimFresh = server.req("hub-claim", { code = fresh, proof = "claim-proof" })
    local claimOld = server.req("hub-claim", { code = "Q2M3XDPTK7", proof = "claim-proof" })
    local claimHub = hub.req("hub-claim", { code = "K7Q2M3XDPT", proof = "claim-proof" })
    assert(claim1.ok and claim2.ok and claimFresh.ok)
    assert(claimOld.ok == false and claimOld.error == "invalidated")
    assert(claimHub.ok == false)
    local used = server.reboot().req("hub-claim", { code = "K7Q2M3XDPT", proof = "claim-proof" })
    assert(used.ok == false and used.error == "used")
    return summary(server, hub, serverKeys)
  end

  test("handover keeps each id once and the codes still claim after a crash at every step", function()
    local clean = handover(false)
    local crashed = handover(true)
    assert(clean == crashed, "crash rerun diverged")
  end)

  test("a server that already issues rejects the import", function()
    local hubKeys, serverKeys = {}, {}
    local hub = box("hub", 7, { pageRecords = 1 }, hubKeys)
    local server = box("server", 4, { joining = false }, serverKeys)
    assert(hub.req("hub-freeze").ok)
    local page = hub.req("hub-export", { cursor = 0 })
    assert(page.ok and page.done)
    local imported = server.req("hub-import", { records = page.records, manifest = page.manifest })
    assert(imported.ok == false and imported.error == "not a joining server")
    assert(next(server.state().plans) == nil)
  end)

  test("importing a different body for an id conflicts and keeps the first", function()
    local hubKeys, serverKeys = {}, {}
    local hub = box("hub", 7, { pageRecords = 8 }, hubKeys)
    local server = box("server", 4, { joining = true }, serverKeys)
    local id = hub.req("hub-mint").id
    assert(hub.req("hub-put", { kind = "lease", body = { v = 2, id = id, turtle = 17 } }).ok)
    assert(hub.req("hub-freeze").ok)
    local page = hub.req("hub-export", { cursor = 0 })
    assert(page.ok)
    assert(server.req("hub-import", { records = page.records, manifest = page.manifest }).ok)
    local tweaked = wire({ records = page.records, manifest = page.manifest })
    tweaked.records[1].body.turtle = 18
    local conflict = server.req("hub-import", tweaked)
    assert(conflict.ok == false and conflict.error == "id conflict")
    assert(server.state().leases[id].turtle == 17)
  end)
end
