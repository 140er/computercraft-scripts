return function(test, equal, read, mocks)
  local source = read("server.lua")
  local secret = "h3-test-secret-123456"
  local function fixture()
    local m = mocks.new(false)
    local env, timers = m.env, {}
    env.http = nil
    env.textutils.unserialize = function(text)
      local chunk = load("return " .. (text or ""), "=state", "t", {})
      if chunk then local ok, value = pcall(chunk) if ok then return value end end
    end
    env.dofile = function(path) return assert(loadfile(path, "t", env))() end
    env.sleep = function(delay)
      local timer = env.os.startTimer(delay)
      repeat local _, id = env.os.pullEvent("timer") until id == timer
    end
    local startTimer = env.os.startTimer
    env.os.startTimer = function(delay)
      local id = startTimer(delay)
      timers[id] = m.time + delay
      return id
    end
    env.os.cancelTimer = function(id) timers[id] = nil end
    m.sent = {}
    env.rednet.send = function(id, message, protocol)
      m.sent[#m.sent + 1] = { id = id, message = env.textutils.unserialize(mocks.encode(message)), protocol = protocol }
    end
    function m.burst(events)
      for _, event in ipairs(events) do env.os.queueEvent(table.unpack(event)) end
      m.push()
    end
    function m.advance(seconds, drop)
      for _ = 1, seconds do
        m.time = m.time + 1
        local due = {}
        for id, deadline in pairs(timers) do if deadline <= m.time then due[#due + 1] = id end end
        table.sort(due)
        for _, id in ipairs(due) do
          timers[id] = nil
          if not drop or not drop(id) then m.push("timer", id) end
        end
      end
    end
    function m.request(message, id) m.push("rednet_message", id or 1, message, "fleetserver") end
    function m.reply(rid)
      for i = #m.sent, 1, -1 do if m.sent[i].message.rid == rid then return m.sent[i].message end end
    end
    function m.state() return env.textutils.unserialize(m.files["server.state"]) end
    return m
  end
  local function packet(op, counter, fields)
    local message = fields or {}
    message.type, message.v, message.expect = "ssot", 1, "ssot_reply"
    message.op, message.rid, message.counter = op, "h3-" .. counter, counter
    message.boot, message.secret = "h3-boot", secret
    return message
  end
  local function pose(x) return { dim = "minecraft:overworld", x = x, y = 64, z = 0 } end
  local function installSSOT(m)
    for _, path in ipairs({ "ssot.lua", "atomic.lua", "mine-tasks.lua", "warehouse-tasks.lua" }) do
      m.files[path] = read(path)
    end
    m.files["ssot.cfg"] = mocks.encode({ controllers = { ["1"] = secret, ["2"] = secret } })
  end

  test("H3 HTTP wait preserves an exact register, command, ack and state burst", function()
    local m = fixture()
    local code = "--" .. string.rep("h", 25000) .. "\nreturn true"
    m.env.http = { get = function()
      m.env.os.pullEvent("h3_http")
      return { readAll = function() return code end, close = function() end }
    end }
    m.start(source)
    m.request({ type = "get", file = "builder.lua", rid = "download" })
    m.burst({
      { "rednet_message", 1, { type = "register", kind = "miner", rid = "register" }, "fleetserver" },
      { "rednet_message", 1, { type = "command", protocol = "minearmy", target = 2,
        message = { type = "go" }, rid = "command" }, "fleetserver" },
      { "rednet_message", 2, { type = "cmd_ack", cid = 1 }, "minearmy" },
      { "rednet_message", 1, { type = "state", rid = "state" }, "fleetserver" },
    })
    assert(m.reply("register") and m.reply("command") and m.reply("state"), "HTTP discarded application events")
    equal(m.reply("state").bots[1].kind, "miner")
    m.push("h3_http")
    m.advance(1)
    m.push("h3_http")
    assert(m.reply("download") and m.reply("download").code == code:sub(1, 12000), "cache miss never completed")
    local deliveries = 0
    for _, sent in ipairs(m.sent) do if sent.message.cid == 1 then deliveries = deliveries + 1 end end
    m.advance(4)
    local after = 0
    for _, sent in ipairs(m.sent) do if sent.message.cid == 1 then after = after + 1 end end
    equal(after, deliveries, "queued command acknowledgement did not stop retries")
  end)

  test("H3 maintenance recovers a dropped timer on the next unrelated event", function()
    local m = fixture()
    m.start(source)
    m.request({ type = "command", protocol = "minearmy", target = 2,
      message = { type = "go" }, rid = "command" })
    m.advance(4, function() return true end)
    m.push("h3_watchdog")
    local deliveries = 0
    for _, sent in ipairs(m.sent) do if sent.message.cid == 1 then deliveries = deliveries + 1 end end
    equal(deliveries, 2, "dropped timer stopped order maintenance")
    m.advance(3)
    deliveries = 0
    for _, sent in ipairs(m.sent) do if sent.message.cid == 1 then deliveries = deliveries + 1 end end
    equal(deliveries, 3, "maintenance timer was not rearmed")
  end)

  test("H3 SSOT validation and atomic saves finish without yielding at four chunks", function()
    local m = fixture()
    local s = { schema = 1, epoch = 0, rev = 1, seq = 0, chunks = {}, names = {}, poses = {}, moves = {}, clients = {} }
    for i = 0, 3 do s.chunks["minecraft:overworld|" .. i .. "|4|0"] = { rev = 1, cells = { [1] = 0 } } end
    m.files["ssot.state"] = mocks.encode({ schema = 1, generation = 1, value = s })
    m.env.sleep = function() coroutine.yield("unexpected save yield") end
    local S = m.env.dofile("ssot.lua")
    local api
    local opening = coroutine.create(function() api = S.open({ controllers = { ["1"] = secret } }) end)
    local ok, err = coroutine.resume(opening)
    assert(ok, err)
    assert(coroutine.status(opening) == "dead", "SSOT open/save yielded in validation")
    local transaction = coroutine.create(function()
      assert(api.handle(1, packet("sync", 1, { pose = pose(0) })).ok)
    end)
    ok, err = coroutine.resume(transaction)
    assert(ok, err)
    assert(coroutine.status(transaction) == "dead", "SSOT handle/save yielded in validation")
    equal(m.env.textutils.unserialize(m.files["ssot.state"]).value.poses[1].x, 0)
  end)

  test("H3 watchdog wakes maintenance after its primary timer disappears during HTTP", function()
    local m = fixture()
    m.env.http = { get = function() m.env.os.pullEvent("h3_http") end }
    m.start(source)
    m.request({ type = "command", protocol = "minearmy", target = 2,
      message = { type = "go" }, rid = "command" })
    local dropped = false
    m.advance(4, function()
      if not dropped then dropped = true return true end
    end)
    local deliveries = 0
    for _, sent in ipairs(m.sent) do if sent.message.cid == 1 then deliveries = deliveries + 1 end end
    equal(deliveries, 2, "maintenance needed an unrelated application event to recover")
  end)

  test("H3 FIFO grants once and replays the durable result after restart", function()
    local m = fixture()
    installSSOT(m)
    m.start(source)
    local sync = packet("sync", 1, { pose = pose(0) })
    local reserve = packet("reserve", 2, { pose = pose(0), to = pose(1) })
    m.burst({
      { "rednet_message", 1, sync, "fleetserver" },
      { "rednet_message", 1, reserve, "fleetserver" },
      { "rednet_message", 1, reserve, "fleetserver" },
      { "rednet_message", 1, { type = "state", rid = "after" }, "fleetserver" },
    })
    assert(m.reply("h3-1") and m.reply("h3-1").ok, "sync lost")
    local grant = assert(m.reply("h3-2"), "reserve lost")
    assert(grant.ok, "reserve ran before sync")
    local durable = m.env.textutils.unserialize(m.files["ssot.state"]).value
    equal(durable.seq, 1, "duplicate request allocated twice")
    local restored = fixture()
    for path, text in pairs(m.files) do restored.files[path] = text end
    restored.start(source)
    restored.request(reserve)
    equal(restored.reply("h3-2"), grant)
    equal(restored.env.textutils.unserialize(restored.files["ssot.state"]).value.seq, 1)
  end)

  test("H3 collector stays listening while a view yields and overflow retries safely", function()
    local m = fixture()
    installSSOT(m)
    m.start(source)
    local originalFind, paused = m.env.peripheral.find, false
    m.env.peripheral.find = function(kind, filter)
      if paused and kind == "ar_controller" then m.env.os.pullEvent("h3_view_ready") end
      return originalFind(kind, filter)
    end
    paused = true
    m.push("peripheral", "view")
    local events = {}
    for i = 1, 140 do
      events[i] = { "rednet_message", 1, packet("snapshot", i, { chunk = "minecraft:overworld|0|4|0" }), "fleetserver" }
    end
    m.burst(events)
    assert(not m.reply("h3-1"), "worker did not pause in the view")
    paused = false
    m.push("h3_view_ready")
    local last = 0
    for _, sent in ipairs(m.sent) do
      if sent.message.type == "ssot_reply" then
        local counter = tonumber(sent.message.rid:match("h3%-(%d+)"))
        equal(counter, last + 1, "accepted request order changed")
        last = counter
      end
    end
    assert(last > 8 and last < 140, "queue did not bound admission")
    equal(m.reply("h3-140").type, "busy", "queue overflow was silent")
    local saved = m.env.textutils.unserialize(m.files["ssot.state"]).value
    equal(saved.clients[1].counter, last, "overflow advanced the durable counter")
    m.request(events[last + 1][3])
    assert(m.reply("h3-" .. (last + 1)), "overflow request could not retry unchanged")
    local restored = fixture()
    for path, text in pairs(m.files) do restored.files[path] = text end
    restored.start(source)
    restored.request(events[last + 1][3])
    equal(restored.reply("h3-" .. (last + 1)), m.reply("h3-" .. (last + 1)))
  end)

  test("H3 worker batches leave time for maintenance during a sustained backlog", function()
    local m = fixture()
    m.start(source)
    m.request({ type = "command", protocol = "minearmy", target = 2,
      message = { type = "go" }, rid = "command" })
    local originalFind, paused = m.env.peripheral.find, true
    m.env.peripheral.find = function(kind, filter)
      if paused and kind == "ar_controller" then m.env.os.pullEvent("h3_view_ready") end
      return originalFind(kind, filter)
    end
    m.push("peripheral", "view")
    local events = {}
    for i = 1, 32 do events[i] = { "rednet_message", 1, { type = "register", kind = "miner", rid = i }, "fleetserver" } end
    m.burst(events)
    local serialize = m.env.textutils.serialize
    m.env.textutils.serialize = function(value, options)
      if value.bots then m.time = m.time + 0.25 end
      return serialize(value, options)
    end
    local startTimer, progressed = m.env.os.startTimer, false
    m.env.os.startTimer = function(delay)
      if m.time >= 1 then
        local replies = 0
        for _, sent in ipairs(m.sent) do
          if sent.message.type == "ack" and type(sent.message.rid) == "number" then replies = replies + 1 end
        end
        if replies > 0 and replies < 32 then progressed = true end
      end
      return startTimer(delay)
    end
    paused = false
    m.push("h3_view_ready")
    local delivered, replied = 0, 0
    for _, sent in ipairs(m.sent) do
      if sent.message.cid == 1 then delivered = delivered + 1 end
      if sent.message.type == "ack" and type(sent.message.rid) == "number" then replied = replied + 1 end
    end
    equal(replied, 32, "backlog lost requests")
    assert(progressed, "worker did not let another coroutine run before draining the backlog")
    assert(delivered >= 2, "worker starved the maintenance coroutine")
  end)

  test("H3 slow saves cannot hold the event pump for a whole watchdog interval", function()
    local m = fixture()
    m.env.os.clock = function() return 0 end
    m.start(source)
    local find, paused = m.env.peripheral.find, true
    m.env.peripheral.find = function(kind, filter)
      if paused and kind == "ar_controller" then m.env.os.pullEvent("h3_view_ready") end
      return find(kind, filter)
    end
    m.push("peripheral", "view")
    local events = {}
    for i = 1, 16 do events[i] = { "rednet_message", 1, { type = "register", kind = "miner", rid = i }, "fleetserver" } end
    m.burst(events)
    local serialize, pull = m.env.textutils.serialize, m.env.os.pullEvent
    local lastYield, largest = m.time, 0
    m.env.textutils.serialize = function(value, options)
      if value.bots then m.time = m.time + 1.1 end
      return serialize(value, options)
    end
    m.env.os.pullEvent = function(...)
      largest = math.max(largest, m.time - lastYield)
      lastYield = m.time
      return pull(...)
    end
    paused = false
    m.push("h3_view_ready")
    for i = 1, 16 do assert(m.reply(i), "slow save lost a queued request") end
    assert(largest < 7, ("individually bounded saves held the event pump for %.3f seconds"):format(largest))
  end)

  test("H3 failed HTTP completion releases callers and permits the same cache miss to retry", function()
    local m = fixture()
    local failed, closed = true, 0
    m.env.http = { get = function(url)
      if url:find("builder.lua", 1, true) then
        m.env.os.pullEvent("h3_http")
        if failed then return nil, "offline" end
      end
      return { readAll = function() return "return true" end, close = function() closed = closed + 1 end }
    end }
    m.start(source)
    m.request({ type = "get", file = "builder.lua", rid = "miss-1" })
    m.request({ type = "get", file = "builder.lua", rid = "miss-2" }, 2)
    m.request({ type = "state", rid = "during-http" })
    assert(m.reply("during-http"), "HTTP blocked available reads")
    m.push("h3_http")
    equal(m.reply("miss-1").error, "not cached")
    equal(m.reply("miss-2").error, "not cached")
    failed = false
    m.request({ type = "get", file = "builder.lua", rid = "retry" })
    m.push("h3_http")
    equal(m.reply("retry").code, "return true")
    assert(closed >= 2, "HTTP handles were not closed")
  end)

  test("H3 a full queue retains the HTTP completion until the worker makes space", function()
    local m = fixture()
    m.env.http = { get = function()
      m.env.os.pullEvent("h3_http")
      return { readAll = function() return "return true" end, close = function() end }
    end }
    m.start(source)
    m.request({ type = "get", file = "builder.lua", rid = "download" })
    local find, paused = m.env.peripheral.find, true
    m.env.peripheral.find = function(kind, filter)
      if paused and kind == "ar_controller" then m.env.os.pullEvent("h3_view_ready") end
      return find(kind, filter)
    end
    m.push("peripheral", "view")
    local events = {}
    for i = 1, 128 do events[i] = { "rednet_message", 1, { type = "register", kind = "miner", rid = i }, "fleetserver" } end
    m.burst(events)
    m.push("h3_http")
    paused = false
    m.push("h3_view_ready")
    m.push("h3_http")
    for i = 1, 128 do assert(m.reply(i), "HTTP completion displaced an accepted request") end
    equal(m.reply("download").code, "return true")
  end)

  test("H3 serving and saving a large cached file never pulls an event inside a request", function()
    local m = fixture()
    local code = "--" .. string.rep("f", 25000) .. "\nreturn true"
    m.files["server-code/miner.lua"] = code
    m.start(source)
    local pull, waits = m.env.os.pullEvent, {}
    m.env.os.pullEvent = function(...)
      local level = 2
      while true do
        local info = debug.getinfo(level, "n")
        if not info then break end
        if info.name == "request" or info.name == "save" or info.name == "handle" then
          waits[#waits + 1] = info.name
        end
        level = level + 1
      end
      return pull(...)
    end
    m.burst({
      { "rednet_message", 1, { type = "get", file = "miner.lua", rid = "file" }, "fleetserver" },
      { "rednet_message", 1, { type = "register", kind = "miner", rid = "after-file" }, "fleetserver" },
    })
    equal(m.reply("file").code, code:sub(1, 12000))
    assert(m.reply("after-file"), "request behind a large file was lost")
    equal(waits, {}, "a request or save pulled an event")
  end)

  test("H3 a slow background fetch does not delay an unrelated cache miss", function()
    local m = fixture()
    m.env.http = { get = function(url)
      if url:find("miner.lua", 1, true) then m.env.os.pullEvent("h3_background_http") end
      return { readAll = function() return "return true" end, close = function() end }
    end }
    m.start(source)
    m.request({ type = "get", file = "builder.lua", rid = "urgent-download" })
    m.advance(2)
    assert(m.reply("urgent-download") and m.reply("urgent-download").code == "return true",
      "unrelated background HTTP blocked the requested file")
    m.push("h3_background_http")
  end)

  test("H3 queued hub mirrors cannot suppress a newer direct turtle status", function()
    for _, proto in ipairs({ "minearmy", "fleetserver" }) do
      local m = fixture()
      m.start(source)
      local find, paused = m.env.peripheral.find, true
      m.env.peripheral.find = function(kind, filter)
        if paused and kind == "ar_controller" then m.env.os.pullEvent("h3_view_ready") end
        return find(kind, filter)
      end
      m.push("peripheral", "view")
      local old = { type = "status", x = 0, y = 64, z = 0 }
      local mirror = proto == "minearmy" and { type = "panel_state", turtles = { { id = 1, age = 0, x = 0, y = 64, z = 0 } } }
        or { type = "hub_put", rid = "mirror", hub = { overrides = {}, bores = {}, progress = {}, totals = {} },
          turtles = { { p = old, age = 0 } } }
      m.push("rednet_message", 7, mirror, proto)
      m.time = 1
      m.push("rednet_message", 1, { type = "status", x = 1, y = 64, z = 0 }, "minearmy")
      m.time, paused = 5, false
      m.push("h3_view_ready")
      equal(m.state().bots[1].position.x, 1, "queued older hub status hid the newer turtle position")
      equal(m.state().bots[1].lastSeen, 1001000)
    end
  end)

  test("H3 queue and HTTP progress survive lost private wake notifications", function()
    local m = fixture()
    m.env.http = { get = function()
      return { readAll = function() return "return true" end, close = function() end }
    end }
    m.start(source)
    local queueEvent = m.env.os.queueEvent
    m.env.os.queueEvent = function(name, ...)
      if not name:match("^server_") then queueEvent(name, ...) end
    end
    m.request({ type = "get", file = "builder.lua", rid = "lost-wake-download" })
    m.request({ type = "register", kind = "miner", rid = "lost-wake-register" })
    m.advance(4)
    assert(m.reply("lost-wake-register"), "lost private notification stranded an accepted request")
    assert(m.reply("lost-wake-download") and m.reply("lost-wake-download").code == "return true",
      "lost private notification stranded HTTP or its completion")
    local before = 0
    for _, info in pairs(m.state().files) do
      if type(info) == "table" and type(info.fetched) == "number" and info.fetched > before then before = info.fetched end
    end
    m.advance(5)
    local after = 0
    for _, info in pairs(m.state().files) do
      if type(info) == "table" and type(info.fetched) == "number" and info.fetched > after then after = info.fetched end
    end
    assert(after > before, "refresh stopped after a lost completion notification")
  end)

  test("H3 200 requests during a slow save each get a reply or busy and the timer fires every second", function()
    local m = fixture()
    installSSOT(m)
    m.start(source)
    local find, paused = m.env.peripheral.find, true
    m.env.peripheral.find = function(kind, filter)
      if paused and kind == "ar_controller" then m.env.os.pullEvent("h3_view_ready") end
      return find(kind, filter)
    end
    m.push("peripheral", "view")
    local serialize = m.env.textutils.serialize
    m.env.textutils.serialize = function(value, options)
      if type(value) == "table" and value.schema == 1 and type(value.value) == "table" and value.value.chunks then
        m.time = m.time + 0.25
      end
      return serialize(value, options)
    end
    local events = {}
    for i = 1, 200 do
      events[i] = { "rednet_message", 1, packet("snapshot", i, { chunk = "minecraft:overworld|0|4|0" }), "fleetserver" }
    end
    m.burst(events)
    paused = false
    m.push("h3_view_ready")
    local reply, busy, seen = 0, 0, {}
    for _, sent in ipairs(m.sent) do
      local rid = sent.message.rid
      local n = type(rid) == "string" and tonumber(rid:match("^h3%-(%d+)$"))
      if n and n >= 1 and n <= 200 and not seen[n] then
        seen[n] = sent.message.type == "busy" and "busy" or "reply"
        if seen[n] == "busy" then busy = busy + 1 else reply = reply + 1 end
      end
    end
    equal(reply + busy, 200, "a request during the slow save got neither a reply nor busy")
    assert(reply > 0 and reply <= 32, "the queue admitted more than 32 requests from the burst")
    assert(busy >= 200 - 32, "a full queue did not answer busy")
    local oneSecond = 0
    local startTimer = m.env.os.startTimer
    m.env.os.startTimer = function(delay)
      if delay == 1 then oneSecond = oneSecond + 1 end
      return startTimer(delay)
    end
    for _ = 1, 3 do m.advance(1) end
    assert(oneSecond >= 3, "the one-second timer did not fire on each advanced second")
  end)
end
