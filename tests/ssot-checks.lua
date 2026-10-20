return function(S, A, test)
  test("paired-controller configuration and UUID chat allowlist fail closed", function()
    local cfg=S.config({controllers={["1"]="test-secret-123456"}})
    assert(cfg.chatNames[1]=="Jeffreyy2" and cfg.chatNames[2]=="njov10" and cfg.chatNames[3]=="yolobeerman")
    local uuid="01234567-89ab-cdef-0123-456789abcdef"
    assert(not S.chatAllowed(cfg,"Jeffreyy2",uuid))
    cfg.chatUUIDs.Jeffreyy2=uuid
    assert(S.chatAllowed(cfg,"Jeffreyy2",uuid))
    assert(not S.chatAllowed(cfg,"someone",uuid))
    assert(not S.chatAllowed(cfg,"Jeffreyy2","invalid"))
    assert(not pcall(S.config,{controllers={["1"]="short"}}))
    assert(not pcall(S.config,{controllers={},pageBytes=1000000}))
  end)
  local function pose(x, y, z, dim)
    return { dim = dim or "minecraft:overworld", x = x, y = y or 64, z = z or 0 }
  end
  local function fixture(config)
    local time, counter, saved = 10000, {}, nil
    local cfg = config or { controllers = { ["1"] = "test-secret-123456", ["2"] = "test-secret-123456" } }
    local api = S.new({}, cfg, function() return time end, "boot-1", function(s) saved = A.copy(s) return true end)
    local function request(id, op, fields)
      counter[id] = (counter[id] or 0) + 1
      local m = A.copy(fields or {})
      m.v, m.type, m.expect, m.op = 1, "ssot", "ssot_reply", op
      m.boot, m.rid, m.counter = "turtle-" .. id, "r" .. counter[id], counter[id]
      m.secret=cfg.controllers and cfg.controllers[tostring(id)] or "test-secret-123456"
      return api.handle(id, m), m
    end
    return request, function(dt) time = time + dt end, function() return api.state(), saved end, api, cfg
  end
  test("six adjacent directions reserve and commit with independent dimension occupancy", function()
    for _, d in ipairs({ {1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1} }) do
      local req, _, state = fixture()
      local p, to = pose(0), pose(d[1], 64 + d[2], d[3])
      assert(req(1, "sync", { pose = p }).ok)
      assert(req(2, "sync", { pose = pose(0, 64, 0, "minecraft:the_nether") }).ok)
      local g = req(1, "reserve", { pose = p, to = to }) assert(g.ok)
      local f = { pose = p, to = to, token = g.token, epoch = g.epoch }
      assert(req(1, "start", f).ok)
      assert(req(1, "commit", f).ok)
      assert(state().poses[1].x == to.x)
      assert(req(1, "reserve", { pose = to, to = p }).ok)
    end
  end)
  test("contention, wrong owner, wrong source, teleport, expiry and lease renewal", function()
    local req, advance = fixture()
    local p, q, to = pose(-1), pose(1), pose(0)
    assert(req(1, "sync", { pose = p }).ok) assert(req(2, "sync", { pose = q }).ok)
    assert(not req(1, "reserve", { pose = p, to = pose(4) }).ok)
    local g = req(1, "reserve", { pose = p, to = to }) assert(g.ok)
    local f = { pose = p, to = to, token = g.token, epoch = g.epoch }
    assert(not req(2, "start", f).ok)
    assert(not req(2, "reserve", { pose = q, to = to }).ok)
    advance(4000) assert(req(1, "renew", f).ok)
    advance(4000) assert(req(1, "start", f).ok)
    advance(6000) assert(not req(1, "commit", f).ok)
    assert(not req(1, "release", f).ok)
    assert(not req(2, "reserve", { pose = q, to = to }).ok)
    assert(req(1, "sync", { pose = p }).ok)
    assert(req(2, "reserve", { pose = q, to = to }).ok)
  end)
  test("explicit calibration checks the prior pose, destination occupancy and pending token",function()
    local req,_,state=fixture()
    local p,q=pose(0),pose(1)
    assert(not req(1,"calibrate",{pose=pose(10)}).ok)
    assert(not req(1,"calibrate",{pose=false,previous=p}).ok)
    assert(req(3,"calibrate",{pose=pose(10),previous=p})==nil)
    assert(req(1,"sync",{pose=p}).ok) assert(req(2,"sync",{pose=q}).ok)
    assert(not req(1,"sync",{pose=pose(10)}).ok)
    assert(not req(1,"calibrate",{pose=pose(10),previous=pose(9)}).ok)
    assert(not req(1,"calibrate",{pose=q,previous=p}).ok)
    assert(req(1,"calibrate",{pose=pose(10),previous=p}).ok)
    assert(req(1,"calibrate",{pose=pose(10),previous=p}).ok)
    assert(state().poses[1].x==10)
    assert(req(2,"reserve",{pose=q,to=p}).ok)
    req=fixture()
    assert(req(1,"sync",{pose=p}).ok)
    local g=req(1,"reserve",{pose=p,to=q}) assert(g.ok)
    assert(req(1,"start",{pose=p,token=g.token,epoch=g.epoch}).ok)
    assert(not req(1,"calibrate",{pose=pose(10),previous=p}).ok)
    assert(req(1,"calibrate",{pose=pose(10),previous=p,token=g.token,epoch=g.epoch}).ok)
  end)
  test("offline occupancy and restart preserve both cells of uncertain moves", function()
    local req, _, state, _, cfg = fixture()
    local p, to = pose(-1), pose(0)
    assert(req(1, "sync", { pose = p }).ok)
    assert(req(2, "sync", { pose = pose(1) }).ok)
    local g = req(1, "reserve", { pose = p, to = to })
    assert(req(1, "start", { pose = p, token = g.token, epoch = g.epoch }).ok)
    local s = state()
    local api = S.new(s, cfg, function() return 900000 end, "boot-2")
    local function send(id, op, fields)
      fields.v, fields.type, fields.expect, fields.op = 1, "ssot", "ssot_reply", op
      fields.boot, fields.rid, fields.counter, fields.secret = "new-turtle", "restart" .. op, 100 + id, "test-secret-123456"
      return api.handle(id, fields)
    end
    assert(not send(2, "reserve", { pose = pose(1), to = to }).ok)
    assert(send(1, "sync", { pose = to }).ok)
    assert(api.state().moves[1] == nil)
    assert(api.state().poses[1].x == 0)
  end)
  test("duplicate requests return the durable result and changed or stale replays fail", function()
    local req, _, state, api, cfg = fixture()
    assert(req(1, "sync", { pose = pose(-1) }).ok)
    local r, m = req(1, "reserve", { pose = pose(-1), to = pose(0) })
    assert(api.handle(1, m).token == r.token)
    local reordered={}
    for _,key in ipairs({"secret","counter","rid","boot","op","expect","type","v","to","pose"}) do reordered[key]=A.copy(m[key]) end
    assert(api.handle(1,reordered).token==r.token)
    assert(state().seq == 1)
    m.to.x = 3 assert(api.handle(1, m) == nil) m.to.x = 0
    local restored = S.new(state(), cfg, function() return 10001 end, "boot-2")
    assert(restored.handle(1, m).token == r.token)
    for _ = 1, 12 do req(1, "snapshot", { chunk = "minecraft:overworld|0|4|0" }) end
    assert(api.handle(1, m) == nil)
  end)
  test("missing fields, bad types, cyclic, oversized and unauthorized packets do not mutate", function()
    local _, _, state, api = fixture()
    for _, m in ipairs({ {}, { type = "ssot" }, { v = 1, type = "ssot", rid = false },
      { type = "ssot", cells = string.rep("x", 9000) } }) do assert(api.handle(1, m) == nil) end
    local t = {} t.self = t assert(api.handle(1, t) == nil)
    assert(api.handle(999, {}) == nil)
    assert(api.handle(999,{v=1,type="ssot",expect="ssot_reply",op="sync",rid="unpaired",counter=1,
      boot="attacker",secret="test-secret-123456",pose=pose(0)})==nil)
    assert(state().seq == 0)
  end)
  test("sparse tri-state scans, stale deltas, paged snapshots and resident bound", function()
    local req = fixture({ maxChunks = 1, pageBytes = 1024, controllers = { ["1"] = "test-secret-123456" } })
    assert(req(1, "sync", { pose = pose(0) }).ok)
    local cells = {}
    for i = 0, 63 do
      local c = pose(i % 16, 64, math.floor(i / 16))
      c.name = i % 2 == 0 and "minecraft:stone" or false
      cells[#cells + 1] = c
    end
    local r = req(1, "scan", { pose = pose(0), revision = 0, cells = cells }) assert(r.ok)
    assert(not req(1, "scan", { pose = pose(0), revision = 0, cells = cells }).ok)
    local c = pose(16) c.name = false
    assert(not req(1, "scan", { pose = pose(0), revision = r.revision, cells = {c} }).ok)
    local cursor, n = 0, 0
    repeat
      local page = req(1, "snapshot", { chunk = "minecraft:overworld|0|4|0", cursor = cursor, revision = 1 })
      assert(page.ok and #textutils.serialize(page, { compact = true }) <= 1024)
      for _, entry in ipairs(page.cells) do assert(entry[2] == false or entry[2] == "minecraft:stone") end
      cursor, n = page.cursor, n + #page.cells
    until cursor == 0
    assert(n == 64)
    assert(not req(1, "snapshot", { chunk = "minecraft:overworld|0|4|0", revision = 0 }).ok)
  end)
  test("failed persistence never acknowledges a grant or admits another mutation", function()
    local cfg = { controllers = { ["1"] = "test-secret-123456" } }
    local api = S.new({}, cfg, function() return 0 end, "1", function() return false, "disk full" end)
    local m = { v = 1, type = "ssot", expect = "ssot_reply", op = "sync", rid = "one", counter = 1,
      boot = "turtle", secret = "test-secret-123456", pose = pose(0) }
    assert(api.handle(1, m) == nil)
    assert(api.state().poses[1] == nil)
    assert(api.handle(1, m) == nil)
  end)
  test("encoded snapshot limits include credentials and request metadata",function()
    local secret=string.rep("\127",128)
    local req,_,_,api=fixture({pageBytes=1024,maxChunks=1,controllers={["1"]=secret}})
    assert(req(1,"sync",{pose=pose(0)}).ok)
    local rev=0
    for first=0,32,32 do
      local cells={}
      for i=first,first+31 do local p=pose(i%16,64,math.floor(i/16)) p.name=false cells[#cells+1]=p end
      local r=req(1,"scan",{pose=pose(0),revision=rev,cells=cells}) assert(r and r.ok) rev=r.revision
    end
    local r=req(1,"snapshot",{chunk="minecraft:overworld|0|4|0"})
    assert(r and r.ok and #r.cells>0 and #textutils.serialize(r,{compact=true})<=1024)
    r=api.handle(1,{v=1,type="ssot",expect="ssot_reply",op="snapshot",chunk="minecraft:overworld|0|4|0",
      boot="turtle-1",counter=1000,rid=string.rep("\127",80),secret=secret})
    assert(r==nil or #textutils.serialize(r,{compact=true})<=1024)
    assert(r==nil or not r.ok or #r.cells>0)
  end)
  local secret = "test-secret-123456"
  local function deadCfg()
    return { controllers = { ["1"] = secret, ["2"] = secret }, deadTurtles = true, deadAfterMs = 10000, leaseMs = 5000 }
  end
  local function bootMove(req)
    local p, to, other = pose(0), pose(1), pose(2)
    assert(req(1, "sync", { pose = p }).ok)
    assert(req(2, "sync", { pose = other }).ok)
    local g = req(1, "reserve", { pose = p, to = to })
    assert(g.ok, g.error)
    local f = { pose = p, to = to, token = g.token, epoch = g.epoch }
    assert(req(1, "start", f).ok)
    return p, to, f
  end
  local function mineZone()
    return { min = pose(0, 64, 0), max = pose(3, 66, 0), spacing = 4 }
  end
  local function placeSites(req)
    local function site(kind, x)
      return { kind = kind, pose = { dim = "minecraft:overworld", x = x, y = 64, z = 0, h = 0 }, side = "front" }
    end
    assert(req(1, "wh-site", { name = "src", site = site("source", 10) }).ok)
    assert(req(1, "wh-site", { name = "drop", site = site("drop", 12) }).ok)
  end
  test("a vanished turtle frees its cells and leaves the map, the neighbour and active mining alone", function()
    local req, advance, state = fixture(deadCfg())
    local _, to = bootMove(req)
    assert(req(1, "mine-config", { zone = mineZone() }).ok)
    local leased = req(1, "mine-lease", {})
    assert(leased.ok and leased.task and leased.task.status == "offered")
    assert(req(1, "mine-progress", { token = leased.task.token, progress = 1 }).ok)
    placeSites(req)
    assert(req(1, "wh-order", { key = "job", drop = "drop", lines = { { item = "minecraft:cobble", count = 1, source = "src" } } }).ok)
    assert(req(1, "wh-claim", {}).ok)
    assert(req(1, "wh-lock", { name = "src" }).ok)
    local rock = pose(8, 64, 8)
    rock.name = "minecraft:stone"
    local scanned = req(1, "scan", { pose = pose(0), revision = 0, cells = { rock } })
    assert(scanned.ok)
    advance(10000)
    local before = state()
    assert(req(2, "snapshot", { chunk = "minecraft:overworld|0|4|0" }).ok)
    local after = state()
    assert(after.live[1].state == "missing")
    assert(after.moves[1] == nil)
    assert(after.poses[1].x == 0)
    assert(after.poses[2].x == 2 and after.poses[2].z == 0)
    assert(after.rev == before.rev)
    assert(after.chunks["minecraft:overworld|0|4|0"].rev == before.chunks["minecraft:overworld|0|4|0"].rev)
    local seen = 0
    for index, name in pairs(after.chunks["minecraft:overworld|0|4|0"].cells) do
      seen = seen + 1
      assert(before.chunks["minecraft:overworld|0|4|0"].cells[index] == name)
    end
    assert(seen == 1)
    local task, earlier = after.mining.tasks[1], before.mining.tasks[1]
    assert(task.owner == 1 and task.status == "active" and task.progress == earlier.progress)
    assert(task.untilAt == earlier.untilAt and task.token == earlier.token)
    assert(after.warehouse.orders.job.status == "open" and after.warehouse.orders.job.owner == nil)
    assert(after.warehouse.locks.src == nil)
    local beside = pose(2)
    assert(req(2, "sync", { pose = beside }).ok)
    assert(req(2, "reserve", { pose = beside, to = to }).ok)
    assert(not req(1, "sync", { pose = to }).ok)
    assert(state().poses[2].x == 2)
  end)
  test("a turtle that returns after expiry syncs onto a free cell", function()
    local req, advance, state = fixture(deadCfg())
    local _, to = bootMove(req)
    advance(10000)
    assert(req(2, "snapshot", { chunk = "minecraft:overworld|0|4|0" }).ok)
    assert(state().live[1].state == "missing")
    assert(req(1, "sync", { pose = to }).ok)
    local after = state()
    assert(after.live[1].state == "alive")
    assert(after.poses[1].x == 1 and after.moves[1] == nil)
    assert(after.poses[2].x == 2)
    assert(not req(2, "sync", { pose = to }).ok)
  end)
  test("a slow turtle keeps its cells inside the silence window and a later request extends it", function()
    local req, advance, state = fixture(deadCfg())
    local _, to, f = bootMove(req)
    local other = pose(2)
    advance(8000)
    local blocked = req(2, "reserve", { pose = other, to = to })
    assert(not blocked.ok and blocked.error == "occupied")
    local late = req(1, "commit", f)
    assert(not late.ok and late.error == "expired; reconcile")
    assert(state().live[1].state == "alive")
    assert(state().moves[1] ~= nil)
    assert(req(1, "snapshot", { chunk = "minecraft:overworld|0|4|0" }).ok)
    advance(9000)
    assert(req(2, "snapshot", { chunk = "minecraft:overworld|0|4|0" }).ok)
    assert(state().live[1].state == "alive")
    local still = req(2, "reserve", { pose = other, to = to })
    assert(not still.ok and still.error == "occupied")
    advance(2000)
    assert(req(2, "snapshot", { chunk = "minecraft:overworld|0|4|0" }).ok)
    assert(state().live[1].state == "missing")
    assert(req(2, "sync", { pose = pose(2) }).ok)
    assert(req(2, "reserve", { pose = pose(2), to = to }).ok)
  end)
  test("silence does not expire a started move when dead turtles are disabled", function()
    local req, advance, state, api = fixture()
    local _, to = bootMove(req)
    advance(100000)
    assert(api.sweep() == false)
    assert(api.missing(1) == false)
    assert(state().live == nil)
    assert(state().moves[1] ~= nil)
    local blocked = req(2, "reserve", { pose = pose(2), to = to })
    assert(not blocked.ok and blocked.error == "occupied")
    assert(not req(2, "turtle-forget", { target = 1 }).ok)
  end)
  test("forget removes a missing turtle and leaves its mine quarantined", function()
    local req, advance, state = fixture(deadCfg())
    bootMove(req)
    assert(req(1, "mine-config", { zone = mineZone() }).ok)
    local leased = req(1, "mine-lease", {})
    assert(req(1, "mine-progress", { token = leased.task.token, progress = 1 }).ok)
    placeSites(req)
    assert(req(1, "wh-stock", { name = "src", stock = { ["minecraft:cobble"] = 4 } }).ok)
    assert(req(1, "wh-order", { key = "job", drop = "drop", lines = { { item = "minecraft:cobble", count = 2, source = "src" } } }).ok)
    local job = req(1, "wh-claim", {}).job
    assert(req(1, "wh-progress", { token = job.token, line = 1, picked = 1, delivered = 0 }).ok)
    advance(10000)
    assert(not req(2, "turtle-forget", { target = 2 }).ok)
    local forgotten = req(2, "turtle-forget", { target = 1 })
    assert(forgotten.ok and forgotten.changed and forgotten.mine and forgotten.cargo)
    local after = state()
    assert(after.poses[1] == nil and after.moves[1] == nil and after.live[1] == nil)
    assert(after.poses[2].x == 2)
    assert(after.mining.tasks[1].owner == 1 and after.mining.tasks[1].status == "active")
    assert(after.warehouse.orders.job.owner == 1 and after.warehouse.orders.job.lines[1].picked == 1)
    local again = req(2, "turtle-forget", { target = 1 })
    assert(again.ok and again.changed == false)
    assert(state().mining.tasks[1].owner == 1)
  end)
  test("forget keeps a delivered order with its owner", function()
    local req, advance, state = fixture(deadCfg())
    assert(req(1, "sync", { pose = pose(0) }).ok)
    placeSites(req)
    assert(req(1, "wh-stock", { name = "src", stock = { ["minecraft:cobble"] = 4 } }).ok)
    assert(req(1, "wh-order", { key = "job", drop = "drop", lines = { { item = "minecraft:cobble", count = 1, source = "src" } } }).ok)
    local job = req(1, "wh-claim", {}).job
    assert(req(1, "wh-progress", { token = job.token, line = 1, picked = 1, delivered = 1 }).ok)
    advance(10000)
    assert(req(2, "snapshot", { chunk = "minecraft:overworld|0|4|0" }).ok)
    local forgotten = req(2, "turtle-forget", { target = 1 })
    assert(forgotten.ok and forgotten.changed and forgotten.cargo == false)
    local order = state().warehouse.orders.job
    assert(order.status == "active" and order.owner == 1 and order.lines[1].delivered == 1)
  end)
  test("deadAfterMs outside 10 seconds to 10 minutes is rejected", function()
    assert(not pcall(S.config, { controllers = { ["1"] = secret }, deadAfterMs = 999 }))
    assert(not pcall(S.config, { controllers = { ["1"] = secret }, deadTurtles = "yes" }))
    local cfg = S.config({ controllers = { ["1"] = secret }, deadTurtles = false })
    assert(cfg.deadTurtles == false)
  end)
end
