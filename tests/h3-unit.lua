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
      for _, sent in ipairs(m.sent) do if sent.message.rid == rid then return sent.message end end
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
end
