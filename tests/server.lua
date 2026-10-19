return function(test, equal, read, mocks)
  local serverCode, updateCode, hubCode = read("server.lua"), read("update.lua"), read("hub.lua")
  local function decode(s) return assert(load("return " .. s, "=mock", "t", {}))() end
  local function hashOf(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
  end
  local function new()
    local m = mocks.new(false)
    local env, timers = m.env, {}
    env.fs.delete = function(path) m.files[path] = nil end
    env.fs.move = function(a, b) assert(m.files[a]) m.files[b], m.files[a] = m.files[a], nil end
    env.fs.makeDir = function() end
    env.textutils.unserialize = function(s)
      local f = load("return " .. s, "=state", "t", {})
      if f then local ok, t = pcall(f) if ok then return t end end
    end
    env.http = nil
    env.write = env.print
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
    env.rednet.receive = function(protocol, timeout)
      local timer = timeout and env.os.startTimer(timeout)
      while true do
        local ev, id, msg, proto = env.os.pullEvent()
        if ev == "rednet_message" and (not protocol or proto == protocol) then return id, msg, proto end
        if ev == "timer" and id == timer then return nil end
      end
    end
    m.sent = {}
    local send = env.rednet.send
    env.rednet.send = function(id, msg, proto)
      m.sent[#m.sent + 1] = { id = id, msg = decode(mocks.encode(msg)), proto = proto }
      send(id, msg, proto)
    end
    function m.advance(n)
      for _ = 1, n do
        m.time = m.time + 1
        local due = {}
        for id, at in pairs(timers) do if at <= m.time then due[#due + 1] = id end end
        table.sort(due)
        for _, id in ipairs(due) do timers[id] = nil m.push("timer", id) end
      end
    end
    function m.request(msg, id)
      m.push("rednet_message", id or 7, msg, "fleetserver")
      return m.sent[#m.sent].msg
    end
    function m.state() return decode(assert(m.files["server.state"])) end
    return m
  end

  test("server captures broadcasts, polls legacy bots and persists registry and log", function()
    local m = new()
    m.start(serverCode)
    m.status(1, { type = "status", phase = "lost", x = 12, y = 64, z = 20, lastError = "blocked", hash = "old" })
    m.push("rednet_message", 2, { type = "lumber_state", state = "PAUSED", gps = { x = 3, y = 4, z = 5 } }, "lumber")
    m.push("rednet_message", 3, { totals = { coal = 42 }, state = "sorting" }, "roomsorter_stock")
    m.request({ type = "register", kind = "relay" }, 4)
    local s = m.state()
    equal(s.bots[1].position, { x = 12, y = 64, z = 20 })
    equal(s.bots[1].error, "blocked")
    equal(s.bots[2].position, { x = 3, y = 4, z = 5 })
    equal(s.bots[3].kind, "roomsorter")
    equal(s.bots[4].kind, "relay")
    m.advance(5)
    assert(table.concat(m.output, "\n"):find("1 LOST", 1, true), "LOST not displayed")
    local polls = 0
    for _, p in ipairs(m.messages) do if p.cmd == "status" then polls = polls + 1 end end
    equal(polls, 6)
    m.advance(15)
    assert(table.concat(m.output, "\n"):find("3 stale", 1, true), "stale bots not displayed")
    local restored = new()
    for path, text in pairs(m.files) do restored.files[path] = text end
    restored.start(serverCode)
    equal(restored.state().bots, s.bots)
    assert(#restored.state().log > #s.log, "restart was not logged")
    local r = restored.request({ type = "state", rid = 9 })
    equal(r.rid, 9)
    equal(r.bots[1].lastSeen, s.bots[1].lastSeen)
  end)

  test("server recovers interrupted saves and keeps a bounded central log", function()
    local m = new()
    m.files["server.state.tmp"] = mocks.encode({ bots = { [12] = { kind = "sorter" } } })
    m.start(serverCode)
    equal(m.state().bots[12].kind, "sorter")
    for i = 1, 205 do
      m.status(1, { type = "status", lastError = "error " .. i })
    end
    equal(#m.state().log, 200)
    equal(m.state().log[200].text, "error 205")
    equal(m.files["server.state.tmp"], nil)
  end)

  test("server mirrors main, serves chunks and hashes, and keeps good code on failure", function()
    local m = new()
    local code, urls = "--" .. string.rep("x", 25000) .. "\nreturn true", {}
    m.env.http = { get = function(url)
      urls[#urls + 1] = url
      return { readAll = function() return code end, close = function() end }
    end }
    m.start(serverCode)
    equal(urls[1]:match("^(.-)%?"), "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/miner.lua")
    equal(m.state().files["miner.lua"].hash, hashOf(code))
    local parts = {}
    for _, offset in ipairs({ 0, 12000, 24000 }) do
      local r = m.request({ type = "get", file = "miner.lua", offset = offset, hash = "old", rid = offset })
      equal(r.hash, hashOf(code))
      equal(r.current, false)
      equal(r.offset, offset)
      parts[#parts + 1] = r.code
    end
    equal(table.concat(parts), code)
    local r = m.request({ type = "get", file = "miner.lua", hash = hashOf(code) })
    equal(r.current, true)
    equal(r.code, nil)
    equal(m.request({ type = "list" }).files["miner.lua"].size, #code)
    code = "this is broken lua"
    m.advance(318)
    r = m.request({ type = "get", file = "miner.lua" })
    equal(r.hash, hashOf(table.concat(parts)))
    equal(m.state().log[#m.state().log].kind, "code_error")
    local before = #m.sent
    m.push("rednet_message", 7, { type = "get", file = "../dev.key" }, "fleetserver")
    equal(#m.sent, before, "server served a non-repo path")
    local restored = new()
    for path, text in pairs(m.files) do restored.files[path] = text end
    restored.start(serverCode)
    equal(restored.request({ type = "get", file = "miner.lua" }).hash, r.hash)
  end)

  test("server refreshes its code mirror periodically", function()
    local m, downloads = new(), 0
    m.env.http = { get = function()
      downloads = downloads + 1
      return { readAll = function() return "return true" end, close = function() end }
    end }
    m.start(serverCode)
    equal(downloads, 1)
    m.advance(16)
    equal(downloads, 17)
    m.advance(301)
    equal(downloads, 18)
  end)

  local function updater(server, httpCode)
    local m = new()
    m.files["miner.lua"] = "return 'old'"
    m.env.rednet.lookup = function() return server and 99 end
    local queue, requests = {}, 0
    m.env.rednet.send = function(id, msg, proto)
      requests = requests + 1
      local before = #server.sent
      server.push("rednet_message", 7, msg, proto)
      if #server.sent > before then queue[#queue + 1] = server.sent[#server.sent].msg end
    end
    m.env.rednet.receive = function()
      local r = table.remove(queue, 1)
      if r then return 99, r, "fleetserver" end
      m.time = m.time + 8
    end
    m.httpCalls = 0
    if httpCode then m.env.http = { get = function()
      m.httpCalls = m.httpCalls + 1
      return { readAll = function() return httpCode end, close = function() end }
    end } end
    assert(load(updateCode, "=update.lua", "t", m.env))("miner", "noreboot")
    m.requests = requests
    return m
  end

  test("update downloads through the real server without http and skips current code", function()
    local s = new()
    local code = "--" .. string.rep("a", 25000) .. "\nreturn 'new'"
    s.files["server-code/miner.lua"] = code
    s.start(serverCode)
    local m = updater(s)
    equal(m.files["miner.lua"], code)
    equal(m.httpCalls, 0)
    equal(m.requests, 3)
    assert(load(updateCode, "=update.lua", "t", m.env))("miner", "noreboot")
    assert(table.concat(m.output, "\n"):find("up to date", 1, true))
    equal(s.state().bots[7].versions["miner.lua"], hashOf(code))
  end)

  test("update falls back to http with no server or a missing server copy", function()
    local m = updater(nil, "return 'http'")
    equal(m.files["miner.lua"], "return 'http'")
    equal(m.httpCalls, 1)
    local s = new()
    s.start(serverCode)
    m = updater(s, "return 'http'")
    equal(m.files["miner.lua"], "return 'http'")
    equal(m.httpCalls, 1)
    m = updater(nil)
    equal(m.files["miner.lua"], "return 'old'")
    s.env.rednet.send = function() end
    m = updater(s, "return 'timeout'")
    equal(m.files["miner.lua"], "return 'timeout'")
    equal(m.httpCalls, 1)
  end)

  test("update rejects corrupted server content and falls back to http", function()
    local s = new()
    s.files["server-code/miner.lua"] = "return true"
    s.start(serverCode)
    local send = s.env.rednet.send
    s.env.rednet.send = function(id, msg, proto)
      if msg.type == "file" then msg.code = "return false" end
      send(id, msg, proto)
    end
    local m = updater(s, "return 'http'")
    equal(m.files["miner.lua"], "return 'http'")
    equal(m.httpCalls, 1)
  end)

  test("hub restores fleet for both views, mirrors state, and falls back after a lost command ack", function()
    local s = new()
    s.start(serverCode)
    local state = { target = "diamond", branchLen64 = true, branchLen = 64, sessionLen = 1800,
      mineMinutes = 15, reach = 96, mode = "thorough", overrides = {}, bores = {}, totals = {}, progress = {} }
    s.request({ type = "hub_put", hub = state, turtles = {
      [5] = { age = 20, p = { type = "status", phase = "home", role = "east", x = 10, y = 64, z = 20 } },
    } }, 99)
    local m = new()
    m.attached = true
    m.env.rednet.lookup = function() return 99 end
    local receive = m.env.rednet.receive
    m.env.rednet.receive = function(proto, timeout)
      if proto == "fleetserver" then return 99, s.request(m.sent[#m.sent].msg), proto end
      return receive(proto, timeout)
    end
    m.start(hubCode)
    equal(decode(m.files["hub.state"]).target, "diamond")
    m.advance(5)
    local frame = m.frames[#m.frames]
    assert(frame["turtle:5"], "restored miner absent from 3D view")
    local mirror
    for _, p in ipairs(m.sent) do if p.msg.type == "hub_put" then mirror = p.msg end end
    assert(mirror, "hub did not mirror")
    equal(mirror.turtles[5].age, 25)
    s.advance(5)
    s.request(mirror, 99)
    equal(s.state().bots[5].lastSeen, 980000, "stale mirror refreshed last seen")
    m.push("char", "r")
    local command = m.sent[#m.sent].msg
    equal(command.type, "command")
    equal(command.message.type, "recall")
    local ack = s.request(command, 99)
    equal(ack.type, "ack")
    equal(s.state().log[#s.state().log].kind, "command")
    m.push("rednet_message", 99, ack, "fleetserver")
    m.advance(1)
    m.push("char", "h")
    equal(m.sent[#m.sent].msg.type, "command")
    m.advance(2)
    local found = false
    for _, p in ipairs(m.messages) do if p.type == "go" then found = true end end
    assert(found, "no direct fallback when server stopped acknowledging")
  end)

  test("server sees old hub fleets without a hub mirror and uses the terminal without a monitor", function()
    local m = new()
    local find = m.env.peripheral.find
    m.env.peripheral.find = function(kind, filter) if kind ~= "monitor" then return find(kind, filter) end end
    m.start(serverCode)
    m.status(8, { type = "panel_state", turtles = {
      { id = 2, age = 40, x = 1, y = 2, z = 3, phase = "lost", err = "stuck", ore = "iron" },
    } })
    local b = m.state().bots[2]
    equal(b.kind, "miner")
    equal(b.lastSeen, 960000)
    equal(b.position, { x = 1, y = 2, z = 3 })
    equal(b.error, "stuck")
    equal(m.state().bots[8].kind, "hub")
    assert(table.concat(m.output, "\n"):find(mocks.encode({ "term", "write", "Fleet server #99" }), 1, true))
  end)

  test("hub uses direct commands if a discovered server never answers", function()
    local m = new()
    m.env.rednet.lookup = function() return 42 end
    m.start(hubCode)
    m.advance(2)
    m.push("char", "r")
    equal(m.messages[#m.messages].type, "recall")
    m.advance(5)
    for _, p in ipairs(m.messages) do assert(p.type ~= "hub_put", "hub overwrote a server it could not read") end
  end)

  test("server records directed assignments and leaves developer commands alone", function()
    local m = new()
    m.start(serverCode)
    m.request({ type = "command", rid = 12, target = 5, protocol = "builder", message = { cmd = "home" } })
    equal(m.sent[#m.sent - 1], { id = 5, proto = "builder", msg = { cmd = "home" } })
    equal(m.state().bots[5].assignment.message.cmd, "home")
    local before = #m.sent
    m.push("rednet_message", 7, { type = "command", target = 5, protocol = "builder",
      message = { type = "dev", key = "test", op = "get" } }, "fleetserver")
    equal(#m.sent, before)
  end)

  test("server ignores malformed hub mirrors and invalid transfers", function()
    local m = new()
    m.start(serverCode)
    m.push("rednet_message", 7, { type = "hub_put", hub = {}, turtles = {} }, "fleetserver")
    equal(m.state().hub, nil)
    m.request({ type = "hub_put", hub = { overrides = {}, bores = {}, progress = {}, totals = {} },
      turtles = { [5] = { p = {}, age = 0 } } })
    equal(m.state().bots[5], nil)
    local before = #m.sent
    m.push("rednet_message", 7, { type = "get", file = "miner.lua", offset = -1 }, "fleetserver")
    equal(#m.sent, before)
  end)

  local function frame(m) return assert(m.frames[#m.frames], "no AR frame") end
  local function miner(phase, status)
    return { type = "status", label = "Miner-east", phase = phase, status = status, role = "east",
      x = 110, y = -58, z = 24, facing = "east", level = -58, reach = 96, branchLen = 64,
      shaft = { x = 100, y = 64, z = 20, bottom = -58 }, fuel = 7000, free = 12 }
  end
  local function connect(s, attached)
    local m = new()
    m.attached = attached
    m.env.rednet.lookup = function() return 99 end
    local receive = m.env.rednet.receive
    m.env.rednet.receive = function(proto, timeout)
      if proto == "fleetserver" then return 99, s.request(m.sent[#m.sent].msg), proto end
      return receive(proto, timeout)
    end
    m.start(hubCode)
    local cursor = 0
    function m.exchange()
      while cursor < #m.sent do
        cursor = cursor + 1
        local p = m.sent[cursor]
        if p.proto == "fleetserver" and p.msg.type ~= "hub_get" then
          m.push("rednet_message", 99, s.request(p.msg), "fleetserver")
        end
      end
    end
    m.exchange()
    return m
  end

  test("server batches message bursts into one frame per second and refreshes stale colors", function()
    local s = new()
    s.attached = true
    s.start(serverCode)
    local frames = #s.frames
    for second = 1, 3 do
      for i = 1, 100 do
        local p = miner("mining", "Mining")
        p.x = second * 100 + i
        s.status(1, p)
        s.request({ type = "state" })
        s.push("term_resize")
      end
      equal(#s.frames, frames, "messages drew before the timer")
      s.advance(1)
      frames = frames + 1
      equal(#s.frames, frames, "burst produced more than one frame")
      equal(frame(s)["turtle:1:position"].args[3], second * 100 + 100.5)
    end
    for _ = 1, 4 do
      s.request({ type = "list" })
      s.advance(1)
      equal(#s.frames, frames, "unchanged view redrew before the five-second refresh")
    end
    s.advance(1)
    equal(#s.frames, frames + 1)
    equal(frame(s)["turtle:1"].args[2], 0x55FFFF - 0x1000000)
    s.advance(10)
    equal(#s.frames, frames + 3)
    equal(frame(s)["turtle:1"].args[2], 0x999999 - 0x1000000)
  end)

  test("server forgets a silent hub and resumes AR after twenty seconds", function()
    for _, attached in ipairs({ true, false }) do
      local s = new()
      s.attached = true
      s.start(serverCode)
      s.status(1, miner("mining", "Mining"))
      connect(s, attached)
      s.advance(1)
      assert(frame(s)["turtle:1"], "ready hub did not allow server AR")
      s.advance(9)
      equal(frame(s), {}, "server did not clear before the hub fallback window")
      local frames = #s.frames
      s.advance(10)
      equal(#s.frames, frames, "waiting for the silent hub sent repeated clears")
      equal(s.state().arHub, 7)
      s.status(1, miner("mining", "Mining"))
      s.advance(1)
      assert(frame(s)["turtle:1"], "silent hub left server AR gated forever")
      equal(s.state().arHub, nil, "forgotten hub remained a saved gate")
    end
  end)

  test("server restart with a saved dead hub resumes AR after one grace window", function()
    local s = new()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    connect(s, true)
    local restored = new()
    restored.attached, restored.files = true, s.files
    restored.start(serverCode)
    restored.advance(20)
    equal(restored.arCalls, {}, "saved hub grace ended before the fallback window")
    restored.advance(1)
    assert(frame(restored)["turtle:1"], "saved dead hub permanently blocked AR after restart")
    equal(restored.state().arHub, nil)
    local again = new()
    again.attached, again.files = true, restored.files
    again.start(serverCode)
    assert(frame(again)["turtle:1"], "expired hub caused another startup wait")
  end)

  test("server registry renders the same HUD, shaft geometry and trouble colors as the hub", function()
    local s, h = new(), new()
    s.attached, h.attached = true, true
    s.start(serverCode)
    h.start(hubCode)
    for id, status in ipairs({ "Mining", "LOST", "STUCK: blocked", "ERROR: fuel" }) do
      local p = miner(id == 2 and "lost" or "mining", status)
      if id == 2 then p.lastError = "Cannot reach home" end
      s.status(id, p)
      h.status(id, p)
    end
    s.advance(1)
    h.advance(1)
    equal(frame(s), frame(h), "server and standalone hub AR differ")
    equal(frame(s).view.args, { "view", 0x55FF55 - 0x1000000, 4, 4, "3D: AAN", false })
    equal(frame(s)["turtle:2"].args,
      { "turtle:2", 0xFF5555 - 0x1000000, 100.5, 67, 20.5, 0, 0, 6, "#2", true })
    equal(frame(s)["turtle:2:error"].args[9], "Cannot reach home")
    s.advance(19)
    h.advance(19)
    equal(frame(s), frame(h), "stale colors differ")
  end)

  test("server draws mirrored miners, preserves progress and hides forgotten or local miners", function()
    local s = new()
    s.attached = true
    s.start(serverCode)
    local p = miner("lost", "LOST")
    p.lastError = "Blocked"
    local hub = { overrides = {}, bores = {}, progress = { ["shaft:100,20:east"] = { branch = 3 } },
      totals = {}, forgotten = { [2] = true } }
    s.request({ type = "hub_put", hub = hub, turtles = { [1] = { age = 0, p = p }, [2] = { age = 0, p = p } } })
    s.advance(1)
    equal(s.state().hub.state.progress, hub.progress)
    equal(s.state().bots[1].status.shaft, p.shaft)
    equal(frame(s)["turtle:1:error"].args[9], "Blocked")
    equal(frame(s)["turtle:2"], nil)
    p = miner("mining", "Mining")
    p.x, p.z, p.shaft = nil, nil, nil
    s.status(3, p)
    s.advance(1)
    equal(frame(s)["turtle:3"], nil)
    s.push("rednet_message", 4, { type = "lumber_state", x = 1, y = 2, z = 3 }, "lumber")
    s.advance(1)
    equal(frame(s)["turtle:4"], nil)
    s.advance(20)
    equal(frame(s)["turtle:1"].args[2], 0x999999 - 0x1000000)
  end)

  test("server key and protocol toggles persist across restarts and keep the HUD when off", function()
    local s = new()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    s.push("char", "v")
    s.advance(1)
    equal(s.state().view3D, false)
    equal(frame(s), { view = { method = "drawText2D",
      args = { "view", 0x999999 - 0x1000000, 4, 4, "3D: UIT", false } } })
    local restored = new()
    restored.attached, restored.files = true, s.files
    restored.start(serverCode)
    equal(frame(restored), frame(s))
    local ack = restored.request({ type = "ar_toggle", rid = "toggle" })
    equal(ack, { type = "ack", rid = "toggle", arOwner = true, view3D = true })
    restored.advance(1)
    assert(frame(restored)["turtle:1"], "toggle did not restore labels")
    s = new()
    s.attached, s.files = true, restored.files
    s.start(serverCode)
    equal(s.request({ type = "state" }).view3D, true)
    assert(frame(s)["turtle:1"])
  end)

  test("server detects controller attach, detach and failure without stopping its registry", function()
    local s = new()
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    equal(#s.arCalls, 0)
    equal(s.request({ type = "hub_get" }).arOwner, false)
    s.attached = true
    s.push("peripheral", "arbitrary_controller_name")
    s.advance(1)
    assert(frame(s)["turtle:1"])
    equal(s.request({ type = "list" }).arOwner, true)
    s.attached = false
    s.push("peripheral_detach", "arbitrary_controller_name")
    local calls = #s.arCalls
    equal(s.request({ type = "hub_get" }).arOwner, false)
    s.advance(5)
    equal(#s.arCalls, calls)
    s.attached = true
    s.push("peripheral", "arbitrary_controller_name")
    s.fail = "update"
    s.advance(5)
    calls = #s.arCalls
    equal(s.request({ type = "state" }).arOwner, false)
    s.advance(5)
    equal(#s.arCalls, calls)
    s.fail = nil
    s.push("peripheral", "arbitrary_controller_name")
    s.advance(1)
    equal(s.request({ type = "state" }).arOwner, true)
    assert(frame(s)["turtle:1"])
  end)

  test("hub clears once and makes no draw calls while the server owns AR, including quit", function()
    local s = new()
    s.attached = true
    s.start(serverCode)
    local h = connect(s, true)
    equal(h.arCalls, { { method = "clear", args = {} }, { method = "update", args = {} } },
      "hub drew while the server owns AR")
    for _ = 1, 40 do h.advance(1) h.exchange() s.advance(1) end
    assert(frame(s).view, "live hub lost server AR")
    equal(s.state().arHub, 7, "live hub was forgotten")
    local find, getName = h.env.peripheral.find, h.env.peripheral.getName
    h.env.peripheral.find = function(kind, filter)
      if kind == "ar_controller" and h.attached then return setmetatable({}, { __index = h.ar }) end
      return find(kind, filter)
    end
    h.env.peripheral.getName = function(device)
      if getmetatable(device) then return "arbitrary_controller_name" end
      return getName(device)
    end
    h.push("peripheral", "unrelated")
    h.attached = false
    h.push("peripheral_detach", "arbitrary_controller_name")
    equal(#h.arCalls, 2, "suppressed detach cleared the owner's frame")
    h.attached = true
    h.push("peripheral", "arbitrary_controller_name")
    equal(#h.arCalls, 4, "reattached controller was not cleared once")
    h.advance(1)
    h.push("char", "q")
    equal(#h.arCalls, 4, "quit cleared the owner's frame")
  end)

  test("hub forwards key and touch toggles to the owner without a local controller", function()
    local s = new()
    s.attached = true
    s.start(serverCode)
    local h = connect(s, false)
    h.push("char", "v")
    equal(h.sent[#h.sent].msg.type, "ar_toggle")
    h.exchange()
    equal(s.state().view3D, false)
    local x, y, button
    for _, line in ipairs(h.output) do
      local p = decode(line)
      if p[1] == "dashboard" then
        if p[2] == "setCursorPos" then x, y = p[3], p[4]
        elseif p[2] == "write" and p[3] == " 3D: UIT " then button = { x, y } end
      end
    end
    assert(button, "remote 3D button missing")
    h.push("monitor_touch", "dashboard", button[1], button[2])
    h.exchange()
    equal(s.state().view3D, true)
    equal(h.arCalls, {})
  end)

  test("hub falls back on owner timeout and relinquishes again after replies resume", function()
    local s = new()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    local h = connect(s, true)
    s.advance(11)
    equal(frame(s), {}, "server kept drawing past the hub's drawing permission")
    h.advance(14)
    equal(#h.arCalls, 2)
    h.advance(1)
    assert(frame(h)["turtle:1"], "owner timeout did not resume local AR")
    h.exchange()
    equal(frame(h), {}, "recovered owner did not clear fallback frame")
    s.advance(1)
    assert(frame(s)["turtle:1"], "server did not resume after the hub cleared")
    local calls = #h.arCalls
    h.advance(5)
    h.exchange()
    equal(#h.arCalls, calls, "recovered owner did not suppress local AR")
  end)

  test("server waits for the hub to clear before drawing after controller attach", function()
    local s = new()
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    local h = connect(s, true)
    assert(frame(h)["turtle:1"])
    s.attached = true
    s.push("peripheral", "arbitrary_controller_name")
    s.advance(1)
    equal(s.arCalls, {}, "server drew before the hub relinquished")
    h.advance(5)
    h.exchange()
    equal(frame(h), {})
    s.advance(1)
    assert(frame(s)["turtle:1"], "server did not draw after ready acknowledgement")
  end)

  test("expired ready messages cannot restart server drawing while the hub falls back", function()
    local s = new()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    local h = connect(s, true)
    local ready
    for _, p in ipairs(h.sent) do if p.msg.type == "ar_ready" then ready = p.msg end end
    assert(ready)
    s.advance(15)
    h.advance(15)
    assert(frame(h)["turtle:1"])
    equal(frame(s), {})
    s.request(ready)
    s.advance(1)
    equal(frame(s), {}, "delayed permission revived the old drawer")
  end)

  test("mirrors without server replies cannot extend drawing into the hub fallback", function()
    local s = new()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    local h = connect(s, true)
    for second = 1, 40 do
      s.advance(1)
      h.advance(1)
      if second % 5 == 0 then
        local mirror
        for _, p in ipairs(h.sent) do if p.msg.type == "hub_put" then mirror = p.msg end end
        s.request(mirror)
      end
      if second >= 10 then equal(frame(s), {}, "unanswered mirrors renewed drawing permission") end
    end
    equal(s.state().arHub, 7, "talking hub was forgotten while its replies were lost")
    assert(frame(h)["turtle:1"])
  end)

  test("a missing command ack does not end AR ownership before its liveness timeout", function()
    local s = new()
    s.attached = true
    s.start(serverCode)
    local h = connect(s, true)
    h.push("char", "r")
    h.advance(2)
    equal(#h.arCalls, 2, "command fallback also started a second AR drawer")
  end)

  test("server restart waits for its saved AR hub to relinquish the fallback view", function()
    local s = new()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    local h = connect(s, true)
    h.advance(15)
    assert(frame(h)["turtle:1"])
    local restored = new()
    restored.attached, restored.files = true, s.files
    restored.start(serverCode)
    restored.advance(1)
    equal(restored.arCalls, {}, "restarted server drew over the hub fallback")
    local mirror
    for _, p in ipairs(h.sent) do if p.msg.type == "hub_put" then mirror = p.msg end end
    local ack = restored.request(mirror)
    equal(restored.arCalls, {})
    h.push("rednet_message", 99, ack, "fleetserver")
    equal(frame(h), {})
    equal(h.sent[#h.sent].msg.type, "ar_ready")
    restored.request(h.sent[#h.sent].msg)
    restored.advance(1)
    assert(frame(restored)["turtle:1"])
  end)

  test("hub follows controller loss and reattach at the server", function()
    local s = new()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("lost", "LOST"))
    local h = connect(s, true)
    s.attached = false
    s.push("peripheral_detach", "arbitrary_controller_name")
    h.advance(5)
    h.exchange()
    assert(frame(h)["turtle:1"], "server controller loss did not resume local AR")
    s.attached = true
    s.push("peripheral", "arbitrary_controller_name")
    h.advance(5)
    h.exchange()
    equal(frame(h), {})
    local calls = #h.arCalls
    h.advance(5)
    h.exchange()
    equal(#h.arCalls, calls)
  end)
end
