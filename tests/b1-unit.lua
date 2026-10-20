local mocks = dofile("tests/mocks.lua")
local env = mocks.new(false).env
env.dofile = function(path) return assert(loadfile(path, "t", env))() end
local S, A = env.dofile("ssot.lua"), env.dofile("atomic.lua")
local Lease, Journal = env.dofile("lease.lua"), env.dofile("journal.lua")
local H4c, W1, N1 = env.dofile("lib/stubs/b1_h4c.lua"), env.dofile("lib/stubs/b1_w1.lua"), env.dofile("lib/stubs/b1_n1.lua")
local failed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or ": " .. tostring(err)))
  if not ok then failed = failed + 1 end
end

local function mac(key, msg)
  local n = 2166136261
  local data = tostring(key) .. "\0" .. msg
  for i = 1, #data do n = (n * 16777619 + data:byte(i)) % 4294967296 end
  return string.format("%08x", n)
end

local function pos(x, y, z, h, conf)
  return {
    v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
    x = x, y = y, z = z, h = h or 0, conf = conf or "certain", src = "typed", anchoredAt = 1000,
  }
end

local function bare(p)
  return { dim = p.dim, x = p.x, y = p.y, z = p.z, h = p.h }
end

local secret = "test-secret-123456"
local function server(flag, now)
  local clock = now or 100000
  local cfg = {
    controllers = { ["1"] = secret, ["2"] = secret },
    leaseV2 = flag and true or nil, leaseMac = mac, maxChunks = 8,
  }
  local api = S.new({ schema = 1, chunks = {}, names = {}, poses = {}, moves = {}, clients = {}, rev = 0, seq = 0 },
    cfg, function() return clock end, "7", function(state)
      assert(Lease.validStored(state), "stored lease state")
      return true
    end)
  local counters = {}
  local function call(id, op, fields)
    counters[id] = (counters[id] or 0) + 1
    local message = A.copy(fields or {})
    message.v, message.type, message.expect, message.op = 1, "ssot", "ssot_reply", op
    message.boot, message.rid, message.counter = "boot", id .. ":" .. counters[id], counters[id]
    message.secret = secret
    return assert(api.handle(id, message), "request dropped"), message
  end
  return { api = api, call = call, clock = function(n) if n then clock = n end return clock end, cfg = cfg }
end

local function corridor(home, towardX)
  local cells = { pos(home.x, home.y, home.z, home.h) }
  for step = 1, towardX do cells[#cells + 1] = pos(home.x + step, home.y, home.z, 1) end
  return cells
end

local function spec(home, areaMax, length)
  return {
    area = { min = pos(home.x, home.y, home.z), max = pos(areaMax.x, areaMax.y, areaMax.z) },
    corridor = corridor(home, length or 0),
    dropoff = { pose = pos(home.x, home.y, home.z, 1), side = "front" },
    charger = { pose = pos(home.x, home.y, home.z, 3), side = "front" },
    home = pos(home.x, home.y, home.z),
    fuelReserve = 120,
    settings = { offlineAutonomy = true },
    settingsRevision = 4,
  }
end

local function issue(box, id, home, areaMax, length)
  assert(box.call(id, "sync", { pose = bare(home) }).ok, "sync")
  local reply = box.call(id, "lease-issue", spec(home, areaMax, length))
  assert(reply.ok and reply.lease.v == 2 and reply.lease.mac, reply.error or "issue failed")
  assert(Lease.verify(reply.lease, secret, mac), "issued mac")
  return reply.lease
end

local function observe(lease, seq, at, x, name)
  return {
    v = 1, seq = seq, lease = lease.id, at = at, frame = "abs", kind = "observe", phase = "done",
    cell = pos(x, 64, 0), name = name,
  }
end

test("lease v2 stays off unless the server flag is set", function()
  local box = server(false)
  local home = pos(0, 64, 0)
  assert(box.call(1, "sync", { pose = bare(home) }).ok)
  local reply = box.call(1, "lease-issue", spec(home, pos(2, 64, 2), 0))
  assert(not reply.ok and reply.error == "unknown operation", reply.error)
end)

test("a leased cell is exclusive and a bad mac or corridor is rejected", function()
  local box = server(true)
  local home = pos(0, 64, 0)
  local lease = issue(box, 1, home, pos(3, 64, 3), 0)
  assert(box.call(2, "sync", { pose = bare(pos(4, 64, 0)) }).ok)
  local blocked = box.call(2, "reserve", { pose = bare(pos(4, 64, 0)), to = bare(pos(3, 64, 0)) })
  assert(not blocked.ok and blocked.error == "occupied", blocked.error)
  local overlap = box.call(2, "lease-issue", spec(pos(3, 64, 0), pos(5, 64, 2), 0))
  assert(not overlap.ok and overlap.error == "occupied", overlap.error)
  local broken = A.copy(lease)
  broken.mac = "00000000"
  assert(not Lease.verify(broken, secret, mac), "tampered lease verified")
  local function draft(n)
    local cells = {}
    for i = 0, n - 1 do cells[i + 1] = pos(i, 64, 0) end
    return {
      v = 2, id = "7:mine:9", turtle = 1, boot = "boot", epoch = "7",
      issuedAt = 1, untilAt = 2, workUntil = 2, issuedRev = 0, frame = "abs", grant = "work",
      area = { min = pos(0, 64, 0), max = pos(2, 64, 0) }, corridor = cells, home = pos(0, 64, 0),
      dropoff = { pose = pos(0, 64, 0, 1), side = "front" },
      charger = { pose = pos(0, 64, 0, 3), side = "front" },
      settings = { revision = 0, values = W1.defaults() }, fuelReserve = 120,
    }
  end
  assert(Lease.shape(draft(256)), "256-cell corridor rejected")
  assert(not Lease.shape(draft(257)), "corridor cap ignored")
  local settings = box.call(2, "lease-issue", spec(pos(20, 64, 0), pos(22, 64, 0), 0))
  settings = A.copy(spec(pos(20, 64, 0), pos(22, 64, 0), 0))
  settings.settings = { offlineAutonomy = true, notASetting = true }
  local rejected = box.call(2, "lease-issue", settings)
  assert(not rejected.ok and rejected.error == "unknown setting", rejected.error)
end)

local function replayMap(box, order)
  local snapshot = A.copy(box.api.state())
  local clock = box.clock()
  local copy = S.new(snapshot, box.cfg, function() return clock end, "7", function(state)
    assert(Lease.validStored(state), "stored lease state")
    return true
  end)
  local counters = {}
  for _, item in ipairs(order) do
    counters[item.turtle] = (counters[item.turtle] or 0) + 1
    local message = {
      v = 1, type = "ssot", expect = "ssot_reply", op = "lease-replay", secret = secret,
      boot = "boot", rid = item.turtle .. ":r" .. counters[item.turtle], counter = 1000 + counters[item.turtle],
      id = item.lease.id, entries = item.entries,
    }
    local reply, err = copy.handle(item.turtle, message)
    assert(reply, "dropped " .. tostring(err) .. " bytes " .. #env.textutils.serialize(message))
    assert(reply.ok, reply.error)
  end
  return Lease.view(copy.state())
end

test("overlapping observations replay to the same map in either order", function()
  local box = server(true)
  local first = issue(box, 1, pos(0, 64, 0), pos(3, 64, 3), 0)
  local second = issue(box, 2, pos(10, 64, 0), pos(12, 64, 2), 0)
  local at = first.issuedAt + 100
  local holder = { turtle = 1, lease = first, entries = { observe(first, 1, at, 0, "minecraft:diamond_ore") } }
  local outsider = { turtle = 2, lease = second, entries = { observe(second, 1, at + 500, 0, "minecraft:cobblestone") } }
  local forward = replayMap(box, { holder, outsider })
  local reverse = replayMap(box, { outsider, holder })
  assert(mocks.encode(forward) == mocks.encode(reverse), "order changed the map")
  assert(forward[1].key == "abs|minecraft:overworld|0|64|0" and forward[1].name == "minecraft:diamond_ore"
    and forward[1].unknown == false, mocks.encode(forward))
  local again = box.call(1, "lease-replay", { id = first.id, entries = holder.entries })
  assert(again.ok, again.error)
  local duplicate = box.call(1, "lease-replay", { id = first.id, entries = holder.entries })
  assert(duplicate.ok and duplicate.acked == again.acked, "replay was not idempotent")
  assert(mocks.encode(duplicate.map) == mocks.encode(again.map), "duplicate replay changed the map")
end)

test("outside observations tie-break by time, turtle and sequence, and a stale section becomes unknown", function()
  local box = server(true)
  local early = issue(box, 1, pos(0, 64, 0), pos(1, 64, 1), 0)
  local state = box.api.state()
  state.rev = 9
  state.chunks["minecraft:overworld|0|4|0"] = { rev = 9, cells = { [9] = 0 } }
  state.names = {}
  local laterBox = S.new(state, box.cfg, box.clock, "7", function(saved)
    assert(Lease.validStored(saved))
    return true
  end)
  local counters = { [2] = 0 }
  local function call(id, op, fields)
    counters[id] = (counters[id] or 0) + 1
    local message = A.copy(fields or {})
    message.v, message.type, message.expect, message.op = 1, "ssot", "ssot_reply", op
    message.boot, message.rid, message.counter = "boot", id .. ":" .. counters[id], counters[id]
    message.secret = secret
    return assert(laterBox.handle(id, message))
  end
  assert(call(2, "sync", { pose = bare(pos(10, 64, 0)) }).ok)
  local later = call(2, "lease-issue", spec(pos(10, 64, 0), pos(12, 64, 0), 0))
  assert(later.ok, later.error)
  local at = later.lease.issuedAt + 10
  local stale = { turtle = 1, lease = early, entries = { observe(early, 1, at, 8, "minecraft:dirt") } }
  local fresh = { turtle = 2, lease = later.lease, entries = { observe(later.lease, 1, at, 8, "minecraft:stone") } }
  local host = { api = laterBox, cfg = box.cfg, clock = box.clock }
  local left = replayMap(host, { stale, fresh })
  local right = replayMap(host, { fresh, stale })
  assert(mocks.encode(left) == mocks.encode(right), "tie order changed the map")
  assert(left[1].name == "minecraft:stone" and left[1].unknown == false, mocks.encode(left))
  local onlyStale = replayMap(host, {
    { turtle = 1, lease = early, entries = { observe(early, 1, at, 8, "minecraft:dirt") } },
    { turtle = 1, lease = early, entries = { observe(early, 2, at + 1, 8, "minecraft:gravel") } },
  })
  assert(onlyStale[1].unknown == true, "stale section stayed known")
end)

test("a killed server keeps the lease, and offline steps do not call it", function()
  local box = server(true)
  local home = pos(0, 64, 0)
  local lease = issue(box, 1, home, pos(3, 64, 3), 2)
  local saved = A.copy(box.api.state())
  local restarted = S.new(saved, box.cfg, box.clock, "8", function(state)
    assert(Lease.validStored(state))
    return true
  end)
  assert(restarted.state().leases[lease.id].epoch == "7", "restart minted a new lease")
  assert(Lease.occupies(restarted.state(), bare(pos(1, 64, 0)), 2, box.clock()) == 1, "lease died with the server")
  local calls = 0
  local nav = {
    pose = function() return bare(home) end,
    step = function() error("per-step rpc") end,
    go = function() error("per-step rpc") end,
    face = function() error("per-step rpc") end,
    stopped = function() return false end, stop = function() end, resume = function() end,
    record = function() end, homeCost = function() return 1 end,
  }
  local dug, seen = 0, 0
  local turtle = {
    getFuelLevel = function() return 80 end,
    inspect = function()
      seen = seen + 1
      if seen == 1 then return true, { name = "minecraft:stone" } end
      return false
    end,
    inspectUp = function() return false end, inspectDown = function() return false end,
    dig = function() dug = dug + 1 return true end,
    digUp = function() return false end, digDown = function() return false end,
    forward = function() return true end, up = function() return true end, down = function() return true end,
    turnLeft = function() return true end, turnRight = function() return true end,
  }
  local wrapped = env.dofile("b1-nav.lua").wrap(nav, {
    client = { call = function() calls = calls + 1 return nil, "down" end },
    secret = secret, mac = mac, now = box.clock, free = function() return 200000 end,
    budget = 90000, confidence = "certain", turtle = turtle,
    cache = "kill.cache", journal = "kill.journal",
  })
  assert(wrapped.use(lease))
  assert(wrapped.step(1, "excavate"))
  assert(calls == 0, "offline step called the server")
  assert(dug == 1 and wrapped.pose().x == 1, "dead reckoning did not move")
  local stored = env.textutils.unserialize(env.fs.open("kill.journal", "r").readAll())
  local replied = box.call(1, "lease-replay", { id = lease.id, entries = stored.value.entries })
  assert(replied.ok, replied.error)
  local found = false
  for _, cell in ipairs(replied.map) do
    if cell.key == "abs|minecraft:overworld|1|64|0" then
      found = true
      assert(cell.unknown == false and cell.name == false, mocks.encode(cell))
    end
  end
  assert(found, "replayed dig did not reach the map")
end)

test("an expired lease blocks movement until a return grant, and the journal budget sends the miner home", function()
  local box = server(true)
  local home = pos(0, 64, 0)
  local lease = issue(box, 1, home, pos(4, 64, 1), 3)
  local head = { v = 1, lease = lease.id, committed = 3, acked = 0, bytes = 80, budget = 100 }
  local away = pos(2, 64, 0)
  local back = pos(1, 64, 0)
  assert(Lease.authorize({ lease = lease, from = away, to = back, now = box.clock(), journal = head,
    settings = lease.settings, home = lease.home }) == "return", "80% still mined")
  assert(select(2, Lease.authorize({ lease = lease, from = back, to = away, now = box.clock(), dig = true,
    journal = head, settings = lease.settings, home = lease.home })) == "journal budget")
  local due = lease.issuedAt + lease.settings.values.checkInEveryMs
  local empty = { v = 1, lease = lease.id, committed = 0, acked = 0, bytes = 0, budget = 100 }
  assert(select(2, Lease.authorize({ lease = lease, from = away, to = back, now = due, journal = empty,
    settings = lease.settings, home = lease.home })) == "check in")
  assert(select(2, Lease.authorize({ lease = lease, from = back, to = away, now = due, journal = empty,
    settings = lease.settings, home = lease.home })) == "check in")
  box.clock(lease.untilAt + 1)
  assert(Lease.occupies(box.api.state(), bare(pos(2, 64, 0)), 2, box.clock()) == false, "expired lease kept the cell")
  assert(select(2, Lease.authorize({ lease = lease, from = away, to = back, now = box.clock(),
    settings = lease.settings, home = lease.home })) == "expired")
  local granted = box.call(1, "lease-return", { id = lease.id })
  assert(granted.ok and granted.lease.grant == "return", granted.error)
  assert(Lease.occupies(box.api.state(), bare(pos(4, 64, 0)), 2, box.clock()) == false, "return grant kept the area")
  assert(Lease.occupies(box.api.state(), bare(home), 2, box.clock()) == 1, "return path was released")
  assert(box.call(2, "sync", { pose = bare(pos(4, 64, 0)) }).ok, "other turtle could not take the area")
  local renewed = box.call(1, "lease-renew", { id = lease.id, seq = 0 })
  assert(not renewed.ok, "return grant renewed as work")
end)

test("lost position cannot dig, and the journal is append-only", function()
  local state = { v = 1, head = { v = 1, lease = "7:mine:1", committed = 0, acked = 0, bytes = 0, budget = 500 }, entries = {} }
  local function add(seq, kind)
    local entry = {
      v = 1, seq = seq, lease = "7:mine:1", at = 10, frame = "abs", kind = kind, phase = "done",
      from = pos(0, 64, 0), to = pos(1, 64, 0),
    }
    if kind == "observe" then entry = {
      v = 1, seq = seq, lease = "7:mine:1", at = 10, frame = "abs", kind = kind, phase = "done",
      cell = pos(1, 64, 0), name = "minecraft:stone",
    } end
    local nextState, err = Journal.accept(state, entry)
    assert(nextState, err)
    state = nextState
  end
  add(1, "move")
  local same = Journal.accept(state, {
    v = 1, seq = 1, lease = "7:mine:1", at = 99, frame = "abs", kind = "move", phase = "done",
    from = pos(0, 64, 0), to = pos(1, 64, 0),
  })
  assert(same == state and same.head.committed == 1, "duplicate seq applied again")
  local gap = Journal.accept(state, {
    v = 1, seq = 3, lease = "7:mine:1", at = 11, frame = "abs", kind = "move", phase = "done",
    from = pos(1, 64, 0), to = pos(2, 64, 0),
  })
  assert(not gap, "gap was accepted")
  assert(Journal.shouldReturn({ bytes = 8, budget = 10 }))
  assert(not Journal.shouldReturn({ bytes = 7, budget = 10 }))
  local moved = N1.offset(pos(3, 64, 0, 1, "certain"), 1)
  assert(moved.x == 4 and moved.src == "reckoned" and moved.conf == "certain")
  local budget = H4c.journalBudget({ freeBytes = 100000, ceiling = W1.defaults().journalMaxBytes })
  assert(budget == 100000 - H4c.policy().controlReserve, budget)
  assert(H4c.journalBudget({ freeBytes = "unlimited" }) > 0)
  local snap = W1.snapshot(4, { offlineAutonomy = true })
  assert(snap.values.offlineAutonomy == true and snap.values.leaseMs == 900000 and snap.revision == 4)
  assert(not W1.snapshot(4, { checkInEveryMs = 800000 }))
  local sample = spec(pos(0, 64, 0), pos(1, 64, 0), 0)
  local box = server(true)
  local lease = issue(box, 1, pos(0, 64, 0), pos(1, 64, 0), 0)
  local lost = pos(0, 64, 0, 0, "lost")
  assert(select(2, Lease.authorize({ lease = lease, from = lost, to = pos(1, 64, 0, 0, "lost"),
    now = box.clock(), settings = lease.settings, home = lease.home })) == "lost")
  local suspect = pos(0, 64, 0, 0, "suspect")
  assert(select(2, Lease.authorize({ lease = lease, from = suspect, to = pos(1, 64, 0, 0, "suspect"),
    now = box.clock(), dig = true, settings = lease.settings, home = lease.home })) == "lost")
  assert(Lease.authorize({ lease = lease, from = suspect, to = pos(1, 64, 0, 0, "suspect"),
    now = box.clock(), settings = lease.settings, home = lease.home }) == "local")
  assert(sample.fuelReserve == 120)
end)

test("the mining worker skips lease renewals and new work when the offline gate says so", function()
  local box = server(true)
  local ops = {}
  local client = {
    call = function(op, fields)
      ops[#ops + 1] = op
      return box.call(1, op, fields)
    end,
  }
  local steps = 0
  local nav = {
    pose = function() return bare(pos(0, 65, 0, 2)) end,
    stopped = function() return false end,
    homeCost = function() return 1 end,
    go = function() return true end,
    face = function() return true end,
    step = function() steps = steps + 1 return true end,
  }
  local gate, offline = nil, true
  env.turtle = { getItemCount = function() return 0 end, getFuelLevel = function() return 1000 end }
  local Mine = env.dofile("mining.lua")
  local zone = { min = bare(pos(0, 64, 1)), max = bare(pos(3, 66, 2)), spacing = 4 }
  assert(box.call(1, "mine-config", { zone = zone }).ok)
  assert(box.call(1, "sync", { pose = bare(pos(1, 65, 0)) }).ok)
  local mine = Mine.open({
    nav = nav, client = client, home = bare(pos(1, 65, 0, 2)), path = "b1-mining.state",
    b1 = { enabled = true, offline = function() return offline end, gate = function() return gate end },
  })
  assert(mine.start(), "mining start")
  local before = #ops
  assert(mine.tick())
  for i = before + 1, #ops do
    assert(ops[i] ~= "mine-renew" and ops[i] ~= "mine-progress", "offline tick called " .. ops[i])
  end
  gate = "home"
  before, steps = #ops, 0
  assert(mine.tick())
  assert(steps == 0, "journal gate still dug")
  assert(mine.state().reason == "journal budget", mine.state().reason)
  for i = before + 1, #ops do assert(ops[i] ~= "mine-renew", "renew while heading home") end
end)

assert(failed == 0, failed .. " B1 failures")
