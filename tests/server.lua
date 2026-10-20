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
      local before = #m.sent
      m.push("rednet_message", id or 7, msg, "fleetserver")
      return #m.sent > before and m.sent[#m.sent].msg or nil
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

  test("serialize mock rejects shared tables and cycles", function()
    local serialize = new().env.textutils.serialize
    local shared = { x = 12 }
    local cycle = {}
    cycle.self = cycle
    for _, value in ipairs({ { shared, shared }, cycle }) do
      local ok, err = pcall(serialize, value)
      equal(ok, false)
      equal(err, "Cannot serialize table with repeated entries")
    end
    equal(serialize({ { x = 12 }, { x = 12 } }), "{[1]={[\"x\"]=12},[2]={[\"x\"]=12}}")
  end)
  test("server refuses to overwrite corrupt generations without a recoverable state",function()
    local m=new()
    m.files["server.state"]="broken state"
    local ok=pcall(m.start,serverCode)
    equal(ok,false)
    equal(m.files["server.state"],"broken state")
  end)
  test("server bounds legacy requests when the shared validator is installed",function()
    local m=new()
    m.files["ssot.lua"],m.files["atomic.lua"]=read("ssot.lua"),read("atomic.lua")
    m.env.dofile=function(path) return assert(loadfile(path,"t",m.env))() end
    m.start(serverCode)
    local sent=#m.sent
    m.push("rednet_message",7,{type="register",kind="spoof",rid=string.rep("x",300000)},"fleetserver")
    equal(#m.sent,sent)
    equal(m.state().bots[7],nil)
    equal(m.request({type="register",kind="miner",rid="valid"}).type,"ack")
  end)
  test("view commands require pairing and fresh counters and only route observed air",function()
    local function setup(files)
      local m=new()
      for path,value in pairs(files or {}) do m.files[path]=value end
      m.files["ssot.lua"],m.files["atomic.lua"]=read("ssot.lua"),read("atomic.lua")
      m.files["ssot.cfg"]='{controllers={["7"]="test-secret-123456",["5"]="turtle-secret-123456"}}'
      m.env.dofile=function(path)
        local lib=assert(loadfile(path,"t",m.env))()
        if path=="ssot.lua" then
          lib.open=function()
            return {epoch="1",state=function() return {chunks={["minecraft:overworld|0|4|0"]={cells={[258]=0,[259]=1}}}} end}
          end
        end
        return lib
      end
      m.start(serverCode)
      return m
    end
    local m=setup()
    local packet={type="command",target=5,protocol="minearmy",viewControl=true,sequence=1,
      secret="wrong",message={type="view_move",point={dim="minecraft:overworld",x=1,y=65,z=0}}}
    equal(m.request(packet).ok,false)
    packet.secret="test-secret-123456"
    packet.message.point.x=2 equal(m.request(packet).ok,false)
    packet.message.point.x=3 equal(m.request(packet).ok,false)
    packet.message.point.x=1
    local r=m.request(packet)
    equal(r.type,"ack")
    local delivered
    for _,p in ipairs(m.sent) do if p.proto=="minearmy" and p.msg.type=="view_move" then delivered=p end end
    assert(delivered and delivered.id==5 and delivered.msg.target==5)
    equal(delivered.msg.commandAuth,"turtle-secret-123456")
    equal(delivered.msg.commandEpoch,"1")
    equal(m.request(packet).error,"Replayed view command")
    local restored=setup(m.files)
    equal(restored.request(packet).error,"Replayed view command")
    restored.request({type="command",target=5,protocol="minearmy",
      message={type="go",commandAuth="turtle-secret-123456"}})
    local legacy
    for _,p in ipairs(restored.sent) do if p.proto=="minearmy" and p.msg.type=="go" then legacy=p.msg end end
    assert(legacy and legacy.commandAuth==nil,"legacy request gained manual-control credentials")
    packet.sequence=2 packet.message={type="estop"}
    equal(restored.request(packet).type,"ack")
    packet.sequence=1 packet.message={type="go"}
    equal(restored.request(packet).error,"Replayed view command")
  end)

  test("server saves GPS status and hub assignments across restart", function()
    local m = new()
    m.start(serverCode)
    local gps, pos = { x = 12, y = 64, z = 20 }, { x = 1, y = 2, z = 3 }
    m.status(5, { type = "status", gps = gps, pos = pos })
    local hub = { target = "diamond", recallAll = true, overrides = { [5] = "iron" },
      bores = { [5] = { x = 10, z = 20 } }, progress = { [5] = 3 }, totals = { iron = 42 } }
    equal(m.request({ type = "hub_put", hub = hub, turtles = {
      [5] = { age = 0, p = { type = "status", gps = gps, pos = pos } },
    } }, 99).type, "ack")
    local restored = new()
    for path, text in pairs(m.files) do restored.files[path] = text end
    restored.start(serverCode)
    local s = restored.state()
    equal(s.hub.state, hub)
    equal(s.bots[99].assignments, { target = "diamond", overrides = hub.overrides, bores = hub.bores })
    equal(s.bots[5].position, gps)
    equal(s.bots[5].localPosition, pos)
    equal(s.bots[5].status, { type = "status", gps = gps, pos = pos })
    equal(s.bots[5].assignment, { ore = "iron", recall = true, bore = hub.bores[5] })
  end)

  test("server trims unused status fields and copies shared coordinates without changing packets", function()
    local m = new()
    m.start(serverCode)
    local shared = { x = 42 }
    local packet = { type = "status", gps = shared, pos = shared, first = shared, second = shared }
    packet.self = packet
    shared.parent = packet
    m.status(5, packet)
    local restored = new()
    for path, text in pairs(m.files) do restored.files[path] = text end
    restored.start(serverCode)
    equal(restored.state().bots[5].status,
      { type = "status", gps = { x = 42 }, pos = { x = 42 } })
    assert(packet.self == packet, "save mutated the live packet")
    assert(packet.first == packet.second and shared.parent == packet, "save changed live references")
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
    equal(urls[1]:match("^(.-)%?"), "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/alpha/miner.lua")
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
    local count = #assert(load("return " .. assert(serverCode:match("local FILES = (%b{})"))))()
    m.advance(count - 1)
    equal(downloads, count)
    m.advance(301)
    equal(downloads, count + 1)
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
    m.updater = assert(load(updateCode, "=update.lua", "t", m.env))("--module")
    m.fetched = m.updater.fetch("miner.lua")
    m.requests = requests
    m.requestCount = function() return requests end
    return m
  end
  local AR_SECRET, AR_UUID = "paired-controller-secret", "12345678-1234-1234-1234-123456789abc"
  local function arMachine()
    local m = new()
    m.files["ssot.cfg"] = mocks.encode({
      controllers = { ["1"] = AR_SECRET, ["2"] = AR_SECRET, ["3"] = AR_SECRET,
        ["4"] = AR_SECRET, ["7"] = AR_SECRET, ["99"] = AR_SECRET },
      chatNames = { "Jeffreyy2" }, chatUUIDs = { Jeffreyy2 = AR_UUID },
      arControllers = { ["7"] = { name = "Jeffreyy2", uuid = AR_UUID },
        ["99"] = { name = "Jeffreyy2", uuid = AR_UUID } },
    })
    m.files["ar.cfg"] = mocks.encode({ enabled = false, ownerName = "Jeffreyy2", ownerUUID = AR_UUID })
    for _, file in ipairs({ "ssot.lua", "atomic.lua", "ar-hud.lua", "chat-control.lua", "ssot-client.lua",
      "planner-ops.lua", "planner-core.lua", "planner-enrol.lua", "planner-settings.lua", "wh2-dispatch.lua" }) do
      m.files[file] = read(file)
    end
    m.env.dofile = function(path) return assert(load(read(path), "@" .. path, "t", m.env))() end
    local counter = 1000000
    function m.authorizeAR(fields)
      local saved = m.files["server.state"] and m.state()
      counter = math.max(counter, saved and saved.arCounters and saved.arCounters["7"] or 0) + 1
      local packet = { type = "ssot", v = 1, op = "ar-control", boot = "ar-server-test",
        rid = "ar-server-" .. counter, counter = counter, expect = "ssot_reply", secret = AR_SECRET,
        name = "Jeffreyy2", uuid = AR_UUID, action = "lease", untilAt = m.env.os.epoch("utc") + 10000 }
      for key, value in pairs(fields or {}) do packet[key] = value end
      return m.request(packet), packet
    end
    return m
  end

  test("update fetch downloads server chunks and reuses current code without retransmission", function()
    local s = new()
    local code = "--" .. string.rep("a", 25000) .. "\nreturn 'new'"
    s.files["server-code/miner.lua"] = code
    s.start(serverCode)
    local m = updater(s)
    equal(m.fetched, code)
    equal(m.httpCalls, 0)
    equal(m.requests, 3)
    m.files["miner.lua"] = code
    equal(m.updater.fetch("miner.lua"), code)
    equal(m.requestCount(), 4, "current code should need one hash request")
    local reply = s.sent[#s.sent].msg
    equal(reply.current, true)
    equal(reply.code, nil, "current code was retransmitted")
    equal(s.state().bots[7].versions["miner.lua"], hashOf(code))
  end)

  test("update fetch uses http without a server and reports unavailable sources", function()
    local m = updater(nil, "return 'http'")
    equal(m.fetched, "return 'http'")
    equal(m.httpCalls, 1)
    local s = new()
    s.start(serverCode)
    m = updater(s, "return 'http'")
    equal(m.fetched, "return 'http'")
    equal(m.httpCalls, 1)
    m = updater(nil)
    equal(m.fetched, nil)
    equal(m.files["miner.lua"], "return 'old'")
    s.env.rednet.send = function() end
    m = updater(s, "return 'timeout'")
    equal(m.fetched, "return 'timeout'")
    equal(m.httpCalls, 1)
  end)

  test("update fetch takes GitHub over a server copy that may be behind main", function()
    local s = new()
    s.files["server-code/miner.lua"] = "return 'cached'"
    s.start(serverCode)
    local m = updater(s, "return 'http'")
    equal(m.fetched, "return 'http'")
    equal(m.requests, 0)
  end)

  test("update fetch rejects corrupted server content and accepts a valid http copy", function()
    local s = new()
    s.files["server-code/miner.lua"] = "return true"
    s.start(serverCode)
    local send = s.env.rednet.send
    s.env.rednet.send = function(id, msg, proto)
      if msg.type == "file" then msg.code = "return false" end
      send(id, msg, proto)
    end
    local m = updater(s)
    equal(m.fetched, nil, "corrupt server content passed hash verification")
    equal(m.requests, 1, "corrupt response was not exercised")
    equal(m.files["miner.lua"], "return 'old'")
    m = updater(s, "return 'http'")
    equal(m.fetched, "return 'http'")
    equal(m.httpCalls, 1)
  end)

  test("hub restores fleet, orders go through the server, and it falls back after a lost command ack", function()
    local s = new()
    s.start(serverCode)
    local state = { target = "diamond", branchLen64 = true, branchLen = 64, sessionLen = 1800,
      mineMinutes = 15, reach = 96, mode = "thorough", overrides = {}, bores = {}, totals = {}, progress = {} }
    s.request({ type = "hub_put", hub = state, turtles = {
      [5] = { age = 20, p = { type = "status", phase = "home", role = "east", x = 10, y = 64, z = 20 } },
    } }, 99)
    local m = arMachine()
    local cfg = decode(m.files["ssot.cfg"])
    cfg.controllers["99"], cfg.arControllers["99"] = nil, nil
    m.files["ssot.cfg"] = mocks.encode(cfg)
    m.attached = true
    m.env.rednet.lookup = function() return 99 end
    local receive = m.env.rednet.receive
    m.env.rednet.receive = function(proto, timeout)
      if proto == "fleetserver" then return 99, s.request(m.sent[#m.sent].msg), proto end
      return receive(proto, timeout)
    end
    m.files["hub.state"] = nil -- a fresh hub computer takes the server's copy
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
    local before = #m.messages
    m.push("char", "r")
    local command = m.sent[#m.sent].msg
    equal(command.type, "command")
    equal(command.message.type, "recall")
    assert(not command.direct, "the server must pass the order on")
    for i = before + 1, #m.messages do
      assert(m.messages[i].type ~= "recall", "hub sent the order itself while the server answers")
    end
    local sent = #s.sent
    local ack = s.request(command, 99)
    equal(ack.type, "ack")
    equal(s.state().log[#s.state().log].kind, "command")
    -- The server sends the known miner its own copy, with an id to confirm
    local copy
    for i = sent + 1, #s.sent do if s.sent[i].id == 5 then copy = s.sent[i].msg end end
    assert(copy and copy.type == "recall" and copy.cid, "server did not deliver to the known miner")
    m.push("rednet_message", 99, ack, "fleetserver")
    m.advance(1)
    m.push("char", "h")
    equal(m.sent[#m.sent].msg.type, "command")
    m.advance(2)
    local found = false
    for _, p in ipairs(m.messages) do if p.type == "go" then found = true end end
    assert(found, "without a server answer the hub did not send the order itself")
  end)

  test("the newer hub state wins between the hub's file and the server's copy", function()
    for _, case in ipairs({ { own = 200, server = 100, want = "gold" }, { own = 100, server = 200, want = "diamond" },
      { server = 100, want = "diamond" } }) do
      local s = new()
      s.start(serverCode)
      s.request({ type = "hub_put", hub = { target = "diamond", rev = case.server, overrides = {}, bores = {},
        totals = {}, progress = {} }, turtles = {} }, 99)
      local m = new()
      m.files["hub.state"] = case.own and mocks.encode({ target = "gold", rev = case.own }) or nil
      m.env.rednet.lookup = function() return 99 end
      local receive = m.env.rednet.receive
      m.env.rednet.receive = function(proto, timeout)
        if proto == "fleetserver" then return 99, s.request(m.sent[#m.sent].msg), proto end
        return receive(proto, timeout)
      end
      m.start(hubCode)
      equal(decode(m.files["hub.state"]).target, case.want)
      assert(decode(m.files["hub.state"]).rev >= case.server, "saved state has no newer revision")
    end
  end)

  test("server ESTOP replaces queued movement commands",function()
    local s=new() s.start(serverCode)
    s.request({type="command",target=5,protocol="minearmy",message={type="go"}},99)
    s.request({type="command",target=5,protocol="minearmy",message={type="estop"}},99)
    s.advance(4)
    local go,stop=0,0
    for _,p in ipairs(s.sent) do
      if p.id==5 and p.msg.type=="go" then go=go+1 end
      if p.id==5 and p.msg.type=="estop" then stop=stop+1 end
    end
    assert(go==1 and stop>=2,"an older go command was retried after ESTOP")
  end)
  test("server repeats an order until the miner confirms it, then gives up and logs", function()
    local s = new()
    s.start(serverCode)
    s.status(5, { type = "status", phase = "mining", x = 1, y = 2, z = 3 })
    s.status(6, { type = "status", phase = "mining", x = 1, y = 2, z = 3 })
    s.request({ type = "command", target = 5, protocol = "minearmy", message = { type = "recall", from = 99 } }, 99)
    s.request({ type = "command", protocol = "minearmy", message = { type = "go", from = 99 } }, 99)
    local function count(id, kind)
      local n = 0
      for _, p in ipairs(s.sent) do if p.id == id and p.msg.type == kind then n = n + 1 end end
      return n
    end
    -- the later "go" to everyone replaced the waiting "recall" for #5
    equal(count(5, "recall"), 1)
    equal(count(5, "go"), 1)
    local cid
    for _, p in ipairs(s.sent) do if p.id == 6 and p.msg.type == "go" then cid = p.msg.cid end end
    s.push("rednet_message", 6, { type = "cmd_ack", cid = cid }, "minearmy")
    s.advance(4)
    equal(count(5, "go"), 2, "unconfirmed order was not repeated")
    equal(count(6, "go"), 1, "confirmed order was repeated")
    equal(count(5, "recall"), 1, "replaced order was repeated")
    s.advance(30)
    equal(count(5, "go"), 6)
    local logged = false
    for _, e in ipairs(s.state().log) do if e.id == 5 and e.text:find("no answer to go", 1, true) then logged = true end end
    assert(logged, "giving up was not logged")
  end)

  test("touchscreen: tap a miner, give it an order through the hub, switch tabs", function()
    local s = new()
    s.start(serverCode)
    s.status(8, { type = "panel_state", target = "iron", ores = { { key = "diamond", short = "Diamond" },
      { key = "iron", short = "Iron" } }, turtles = {} })
    s.status(5, { type = "status", label = "Digger", phase = "mining", status = "Mining", x = 1, y = 2, z = 3,
      shaft = { x = 0, y = 64, z = 0, bottom = -58 } })
    s.advance(5)
    local function find(label)
      local x, y, found
      for _, line in ipairs(s.output) do
        local call = assert(load("return " .. line, "=output", "t", {}))()
        if call[1] == "dashboard" then
          if call[2] == "setCursorPos" then x, y = call[3], call[4]
          elseif call[2] == "write" and type(call[3]) == "string" and call[3]:find(label, 1, true) then
            found = { x, y }
          end
        end
      end
      return assert(found, "not on screen: " .. label)
    end
    local row = find("Digger")
    s.push("monitor_touch", "dashboard", row[1], row[2])
    assert(find("orders: Digger"), "picked miner not shown")
    local stop = find(" STOP ")
    s.push("monitor_touch", "dashboard", stop[1], stop[2])
    local order = s.sent[#s.sent]
    equal(order.id, 8)
    equal(order.proto, "minearmy")
    equal({ order.msg.type, order.msg.cmd, order.msg.turtle }, { "panel", "stop", 5 })
    local iron = find(" Iron ")
    s.push("monitor_touch", "dashboard", iron[1], iron[2])
    equal({ s.sent[#s.sent].msg.cmd, s.sent[#s.sent].msg.ore }, { "target", "iron" })
    local tab = find(" 3D ")
    s.push("monitor_touch", "dashboard", tab[1], tab[2])
    local blits = 0
    for _, line in ipairs(s.output) do if line:find('"blit"', 1, true) then blits = blits + 1 end end
    assert(blits > 0, "3D tab drew no pixels")
    tab = find(" Log ")
    s.push("monitor_touch", "dashboard", tab[1], tab[2])
    assert(find("screen: Stop #5"), "order not in the log")
  end)

  test("miner confirms an order the server passes on", function()
    local m = mocks.new(false)
    m.files["miner.cfg"] = mocks.encode({ home = { x = 100, y = 64, z = -20 }, facing = 0, spine = 1 })
    m.files["miner.state"] = mocks.encode({ pos = { x = 100, y = 64, z = -20 }, h = 0, phase = "home" })
    m.env.turtle = { select = function() end, getItemDetail = function() end,
      getItemCount = function() return 0 end, getFuelLevel = function() return 7000 end }
    local scheduler = m.env.parallel.waitForAny
    m.env.parallel.waitForAny = function(_, listener) scheduler(listener) end
    m.start(read("miner.lua"))
    m.push("rednet_message", 42, { type = "recall", from = 7, cid = 13 }, "minearmy")
    local acked = false
    for _, p in ipairs(m.messages) do if p.type == "cmd_ack" and p.cid == 13 then acked = true end end
    assert(acked, "no cmd_ack")
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
  local function connect(s, attached, pending)
    local m = arMachine()
    m.env.os.getComputerID = function() return 7 end
    m.attached = attached
    m.env.rednet.lookup = function() return 99 end
    local receive = m.env.rednet.receive
    m.env.rednet.receive = function(proto, timeout)
      if proto == "fleetserver" then return 99, s.request(m.sent[#m.sent].msg), proto end
      return receive(proto, timeout)
    end
    m.start(hubCode)
    local cursor = 0
    function m.exchange(server)
      server = server or s
      while cursor < #m.sent do
        cursor = cursor + 1
        local p = m.sent[cursor]
        if p.proto == "fleetserver" and p.msg.type ~= "hub_get" then
          local reply = server.request(p.msg)
          if reply then m.push("rednet_message", 99, reply, "fleetserver") end
        end
      end
    end
    if not pending then
      m.exchange()
      m.advance(5)
      s.advance(5)
      m.exchange()
    end
    return m
  end

  local hosted = assert(load("return " .. assert(serverCode:match("local FILES = (%b{})")), "=files"))()
  local repo = {}
  for _, f in ipairs(hosted) do repo[f] = read(f) end
  local function downloads(m, files)
    m.downloads = 0
    m.env.http = { get = function(url)
      m.downloads = m.downloads + 1
      local code = assert(files[url:match("/([^/?]+)%?t=")], url)
      return { readAll = function() return code end, close = function() end }
    end }
  end
  local function noTemps(m)
    for path in pairs(m.files) do assert(not path:match("%.tmp$"), "leftover " .. path) end
  end

  test("capacity mock raises Out of space at write or close and counts partial bytes", function()
    for _, deferred in ipairs({ false, true }) do
      local m = new()
      m.files, m.capacity, m.writeOnClose = {}, 10, deferred
      local h = m.env.fs.open("file", "w")
      local ok, err = pcall(function() h.write(string.rep("x", 11)) h.close() end)
      equal(ok, false)
      equal(err, "Out of space")
      equal(#m.files.file, 10)
      equal(m.env.fs.getFreeSpace("/"), 0)
    end
  end)

  test("server install guards startup writes and logs failures without replacing existing startup", function()
    for _, failure in ipairs({ "open", "write", "close" }) do
      local m = new()
      m.capacity, m.files["startup.lua"] = 1000000, "return 'good'"
      local open = m.env.fs.open
      m.env.fs.open = function(path, mode)
        if path == "startup.lua.tmp" and failure == "open" then error("open failed") end
        local h = open(path, mode)
        if path == "startup.lua.tmp" then
          h[failure] = function() error(failure .. " failed") end
        end
        return h
      end
      assert(load(serverCode, "=server.lua", "t", m.env))("install")
      equal(m.files["startup.lua"], "return 'good'")
      equal(m.state().log[#m.state().log].kind, "state_error")
      noTemps(m)
    end
  end)

  test("four megabyte server mirrors the real repo once and serves matching root scripts", function()
    local m = new()
    m.files, m.capacity = {}, 4000000
    for _, f in ipairs({ "server.lua", "install.lua", "update.lua" }) do m.files[f] = repo[f] end
    downloads(m, repo)
    m.start(serverCode)
    m.advance(#hosted - 1)
    equal(m.downloads, #hosted)
    for _, f in ipairs(hosted) do
      local info = assert(m.state().files[f], "missing " .. f)
      equal(m.files[info.path], repo[f])
      equal(info.hash, hashOf(repo[f]))
      if m.files[f] then equal(m.files["server-code/" .. f], nil, "duplicate root " .. f) end
    end
    m.status(42, { type = "status", phase = "mining" })
    equal(m.state().bots[42].status.phase, "mining")
    for _, f in ipairs({ "server.lua", "install.lua", "update.lua" }) do
      equal(m.request({ type = "get", file = f }).code, repo[f]:sub(1, 12000))
    end
    noTemps(m)
    assert(m.env.fs.getFreeSpace("/") > 65536)
    assert(table.concat(m.output, "\n"):find("bytes free", 1, true))
  end)

  test("884 KB mirror startup cleans a disk-filling roomsorter tmp without rewriting good code", function()
    local total = 0
    for _, f in ipairs(hosted) do total = total + #repo[f] end
    local roots = #repo["server.lua"] + #repo["install.lua"] + #repo["update.lua"]
    for _, used in ipairs({ total + 69313, total + roots + 23398 }) do
      local m = new()
      m.files, m.capacity = {}, used + 23398
      for _, f in ipairs(hosted) do m.files["server-code/" .. f] = repo[f] end
      for _, f in ipairs({ "server.lua", "install.lua", "update.lua" }) do m.files[f] = repo[f] end
      if used == total + 69313 then
        for _, f in ipairs({ "server.lua", "install.lua", "update.lua" }) do m.files["server-code/" .. f] = nil end
      end
      m.files["server.state"] = mocks.encode({ view3D = true }) .. string.rep(" ", 12000)
      m.files.padding = string.rep("p", used - m.used())
      equal(m.used(), used)
      assert(m.env.fs.getFreeSpace("/") < #repo["roomsorter.lua"])
      m.files["server-code/roomsorter.lua.tmp"] = repo["roomsorter.lua"]:sub(1, m.env.fs.getFreeSpace("/"))
      equal(m.env.fs.getFreeSpace("/"), 0)
      local open = m.env.fs.open
      m.env.fs.open = function(path, mode)
        assert(mode ~= "w" or not path:match("^server%-code/"), "rewrote unchanged cache: " .. path)
        return open(path, mode)
      end
      downloads(m, repo)
      m.start(serverCode)
      m.advance(#hosted - 1)
      equal(m.downloads, #hosted)
      for _, f in ipairs(hosted) do
        equal(m.files[m.state().files[f].path], repo[f])
      end
      m.status(42, { type = "status", status = "still running" })
      equal(m.state().bots[42].status.status, "still running")
      noTemps(m)
      -- A changed roomsorter cannot fit alongside its good copy and the state reserve.
      m.env.fs.open = open
      local changed = {}
      for f, code in pairs(repo) do changed[f] = code end
      changed["roomsorter.lua"] = repo["roomsorter.lua"] .. "\n-- changed\n"
      downloads(m, changed)
      m.advance(317)
      equal(m.files["server-code/roomsorter.lua"], repo["roomsorter.lua"])
      equal(m.state().files["roomsorter.lua"].hash, hashOf(repo["roomsorter.lua"]))
      local found = false
      for _, e in ipairs(m.state().log) do
        if e.kind == "code_error" and e.text:find("roomsorter.lua", 1, true) then found = true end
      end
      assert(found, "deferred cache write was not logged")
      m.status(42, { type = "status", status = "saved after disk error" })
      equal(m.state().bots[42].status.status, "saved after disk error")
      m.advance(5)
      assert(table.concat(m.output, "\n"):find("disk full", 1, true))
      noTemps(m)
    end
  end)

  test("state and cache backups survive failed promotion and recover on restart", function()
    local m = new()
    m.files["server.state.bak"] = mocks.encode({ view3D = false })
    m.files["server-code/roomsorter.lua.bak"] = repo["roomsorter.lua"]
    m.start(serverCode)
    equal(m.state().view3D, false)
    equal(m.request({ type = "get", file = "roomsorter.lua" }).hash, hashOf(repo["roomsorter.lua"]))
    assert(decode(m.files["server.state.bak"]), "previous good generation missing")
    equal(m.files["server-code/roomsorter.lua.bak"], nil)
    local good, move = m.files["server.state"], m.env.fs.move
    m.env.fs.move = function(a, b)
      if b == "server.state" then error("move failed") end
      return move(a, b)
    end
    m.status(5, { type = "status", status = "unsaved" })
    equal(m.files["server.state"], nil)
    equal(m.files["server.state.bak"], good)
    noTemps(m)
    local restored = new()
    restored.files = m.files
    restored.start(serverCode)
    equal(restored.state().view3D, false)
    equal(restored.state().bots[5], nil)
  end)

  test("root scripts changed outside the server are not served with a stale hash", function()
    local m = new()
    m.files["miner.lua"] = repo["miner.lua"]
    downloads(m, repo)
    m.start(serverCode)
    equal(m.files["server-code/miner.lua"], nil)
    m.files["miner.lua"] = "return 'changed'"
    equal(m.request({ type = "get", file = "miner.lua" }).error, "not cached")
    m.advance(#hosted + 300)
    equal(m.files["server-code/miner.lua"], repo["miner.lua"])
    equal(m.request({ type = "get", file = "miner.lua" }).code, repo["miner.lua"]:sub(1, 12000))
  end)

  test("cache write failures at open, write, close and move keep old code and leave state writable", function()
    for _, failure in ipairs({ "write", "close", "open", "move" }) do
      local m = new()
      m.files, m.capacity = { ["server-code/miner.lua"] = "return 'good'" }, 1000000
      downloads(m, repo)
      local open, move = m.env.fs.open, m.env.fs.move
      m.env.fs.open = function(path, mode)
        if path ~= "server-code/miner.lua.tmp" or mode ~= "w" then return open(path, mode) end
        if failure == "open" then return nil end
        local h = open(path, mode)
        if failure == "write" or failure == "close" then
          m.writeOnClose = failure == "close"
          m.capacity = m.used() + 10
        end
        return h
      end
      m.env.fs.move = function(a, b)
        if failure == "move" and a == "server-code/miner.lua.tmp" then error("move failed") end
        return move(a, b)
      end
      m.start(serverCode)
      equal(coroutine.status(m.app), "suspended")
      equal(m.files["server-code/miner.lua"], "return 'good'")
      equal(m.request({ type = "list" }).files["miner.lua"].hash, hashOf("return 'good'"))
      noTemps(m)
      local live = m.request({ type = "state" })
      local found = false
      for _, e in ipairs(live.log) do if e.kind == "code_error" then found = true end end
      assert(found, "missing code_error for " .. failure)
      m.capacity, m.writeOnClose = 1000000, false
      m.status(1, { type = "status", status = failure })
      equal(m.state().bots[1].status.status, failure)
      noTemps(m)
    end
  end)

  test("failed state writes preserve the only good state and persist errors after space returns", function()
    for _, failure in ipairs({ "preflight", "write", "close", "move" }) do
      local m = new()
      m.capacity = 1000000
      m.start(serverCode)
      local good, open, move = m.files["server.state"], m.env.fs.open, m.env.fs.move
      if failure == "preflight" then m.capacity = m.used() end
      m.env.fs.open = function(path, mode)
        local h = open(path, mode)
        if mode == "w" and path == "server.state.tmp" and (failure == "write" or failure == "close") then
          m.writeOnClose = failure == "close"
          m.capacity = m.used() + 10
        end
        return h
      end
      m.env.fs.move = function(a, b)
        if failure == "move" and a == "server.state.tmp" then error("move failed") end
        return move(a, b)
      end
      m.status(1, { type = "status", status = failure })
      equal(m.files["server.state"], good)
      noTemps(m)
      local live = m.request({ type = "state" })
      equal(live.log[#live.log].kind, "state_error")
      m.advance(5)
      assert(table.concat(m.output, "\n"):find("disk full", 1, true))
      m.env.fs.open, m.env.fs.move = open, move
      m.capacity, m.writeOnClose = 1000000, false
      m.status(1, { type = "status", status = "recovered" })
      equal(m.state().bots[1].status.status, "recovered")
      local found = false
      for _, e in ipairs(m.state().log) do if e.kind == "state_error" then found = true end end
      assert(found, "state failure was lost")
    end
  end)

  test("large status packets and old log text stay bounded across saves and restart", function()
    local m = new()
    local large = string.rep("x", 150000)
    m.files["server.state"] = mocks.encode({ bots = { [2] = { status = { type = "status", extra = large } } },
      log = { { kind = "error", text = large } } })
    m.start(serverCode)
    for i = 1, 210 do
      m.status(1, { type = "status", status = large, lastError = large .. i, ignored = large,
        turtles = { { payload = large } }, items = { [large] = 1, coal = 2 } })
    end
    local s = m.state()
    equal(#s.log, 200)
    equal(#s.bots[1].status.status, 256)
    equal(s.bots[1].status.ignored, nil)
    equal(s.bots[1].status.turtles, nil)
    equal(s.bots[1].status.items, { coal = 2 })
    equal(s.bots[2].status.extra, nil)
    assert(#m.files["server.state"] < 65536)
  end)

  test("server clears AR and re-raises Terminated through parallel", function()
    local s = arMachine()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    s.advance(1)
    assert(frame(s)["turtle:1"])
    local frames, calls = #s.frames, #s.arCalls
    local ok, err = coroutine.resume(s.app, "terminate")
    equal(ok, false)
    equal(err, "Terminated")
    equal(coroutine.status(s.app), "dead")
    equal(#s.frames, frames + 1)
    equal(frame(s), {})
    equal(#s.arCalls, calls + 2)
    equal(s.arCalls[calls + 1].method, "clear")
    equal(s.arCalls[calls + 2].method, "update")
  end)

  test("legacy AR world geometry requires the shared owner allowlist", function()
    for _, code in ipairs({ serverCode, hubCode }) do
      for _, configured in ipairs({ false, true }) do
        local m = arMachine()
        if configured then
          local cfg = decode(m.files["ssot.cfg"])
          cfg.chatUUIDs = {}
          m.files["ssot.cfg"] = mocks.encode(cfg)
        else m.files["ssot.cfg"], m.files["ar.cfg"] = nil, nil end
        m.attached = true
        m.start(code)
        m.status(1, miner("mining", "Mining"))
        m.advance(1)
        for _, call in ipairs(m.arCalls) do
          assert(not call.method:find("3D", 1, true), "unapproved legacy owner drew world geometry")
        end
      end
    end
  end)

  test("raw AR ownership claims cannot acquire a lease or change the view", function()
    local s = arMachine()
    s.attached = true
    s.start(serverCode)
    s.request({ type = "hub_get", arClient = true })
    s.request({ type = "ar_ready", untilAt = s.env.os.epoch("utc") + 10000 })
    s.request({ type = "ar_toggle", enabled = false })
    equal(s.state().arHub, nil)
    assert(s.state().view3D ~= false)
    assert(s.authorizeAR().ok)
    equal(s.state().arHub, 7)
  end)

  test("hub suppresses AR until its first authenticated reply or the owner timeout", function()
    local s = arMachine()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    local h = connect(s, true, true)
    equal(h.arCalls, { { method = "clear", args = {} }, { method = "update", args = {} } })
    h.push("rednet_message", 99, { type = "ack", arOwner = false }, "fleetserver")
    h.advance(14)
    equal(#h.arCalls, 2, "hub rendered before the first lease timeout")
    h.advance(1)
    assert(frame(h)["turtle:1"], "unanswered initial lease prevented fallback forever")
    h.exchange()
    h.advance(1)
    h.exchange()
    equal(frame(h), {}, "authenticated owner reply did not suppress fallback")
  end)

  test("hub batches server acks into the existing timer frames", function()
    local s = arMachine()
    s.start(serverCode)
    local h = connect(s, true)
    for _ = 1, 3 do
      local frames, output = #h.frames, #h.output
      for _ = 1, 20 do
        h.push("rednet_message", 99, { type = "ack", arOwner = false, view3D = true }, "fleetserver")
      end
      equal(#h.frames, frames, "acks drew before the timer")
      equal(#h.output, output, "acks redrew the dashboard")
      h.advance(1)
      equal(#h.frames, frames + 1, "acks added frames beyond the timer")
      assert(frame(h).view)
    end
  end)

  test("server batches message bursts into one frame per second and refreshes stale colors", function()
    local s = arMachine()
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
      local s = arMachine()
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

  test("server restart with a saved dead hub clears once and resumes AR after one grace window", function()
    local s = arMachine()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    connect(s, true)
    local restored = arMachine()
    restored.attached, restored.files = true, s.files
    restored.start(serverCode)
    equal(restored.arCalls, { { method = "clear", args = {} }, { method = "update", args = {} } })
    equal(#restored.frames, 1)
    equal(frame(restored), {})
    restored.advance(20)
    equal(#restored.arCalls, 2, "saved hub grace ended before the fallback window")
    restored.advance(1)
    assert(frame(restored)["turtle:1"], "saved dead hub permanently blocked AR after restart")
    equal(restored.state().arHub, nil)
    local again = arMachine()
    again.attached, again.files = true, restored.files
    again.start(serverCode)
    assert(frame(again)["turtle:1"], "expired hub caused another startup wait")
  end)

  test("server registry renders the same HUD, shaft geometry and trouble colors as the hub", function()
    local s, h = arMachine(), arMachine()
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
      { "turtle:2", 0xFF5555 - 0x1000000, 100.5, 67, 20.5, 0, 0, 6, "Miner-east", true })
    equal(frame(s)["turtle:2:error"].args[9], "Cannot reach home")
    s.advance(19)
    h.advance(19)
    equal(frame(s), frame(h), "stale colors differ")
  end)

  test("server draws mirrored miners, preserves progress and hides forgotten or local miners", function()
    local s = arMachine()
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
    local s = arMachine()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    s.push("char", "v")
    s.advance(1)
    equal(s.state().view3D, false)
    equal(frame(s), { view = { method = "drawText2D",
      args = { "view", 0x999999 - 0x1000000, 4, 4, "3D: UIT", false } } })
    local restored = arMachine()
    restored.attached, restored.files = true, s.files
    restored.start(serverCode)
    equal(frame(restored), frame(s))
    assert(restored.authorizeAR().ok)
    local ack, request = restored.authorizeAR({ action = "view", enabled = true })
    equal(ack.type, "ssot_reply")
    equal(ack.rid, request.rid)
    assert(ack.ok and ack.arOwner and ack.view3D)
    restored.advance(1)
    assert(frame(restored)["turtle:1"], "toggle did not restore labels")
    s = arMachine()
    s.attached, s.files = true, restored.files
    s.start(serverCode)
    equal(s.request({ type = "state" }).view3D, true)
    equal(frame(s), {}, "restart drew before its saved hub renewed ownership")
    assert(s.authorizeAR().ok)
    s.advance(1)
    assert(frame(s)["turtle:1"])
  end)

  test("server detects controller attach, detach and failure without stopping its registry", function()
    local s = arMachine()
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
    local s = arMachine()
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
    local s = arMachine()
    s.attached = true
    s.start(serverCode)
    local h = connect(s, false)
    h.push("char", "v")
    h.advance(1)
    equal(h.sent[#h.sent].msg.type, "ssot")
    equal(h.sent[#h.sent].msg.op, "ar-control")
    equal(h.sent[#h.sent].msg.action, "view")
    h.exchange()
    equal(s.state().view3D, false)
    h.advance(1)
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
    h.advance(1)
    h.exchange()
    equal(s.state().view3D, true)
    equal(h.arCalls, {})
  end)

  test("hub falls back on owner timeout and relinquishes again after replies resume", function()
    local s = arMachine()
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
    h.advance(1)
    equal(frame(h), {}, "recovered owner did not clear fallback frame")
    h.exchange()
    s.advance(1)
    assert(frame(s)["turtle:1"], "server did not resume after the hub cleared")
    local calls = #h.arCalls
    h.advance(5)
    h.exchange()
    equal(#h.arCalls, calls, "recovered owner did not suppress local AR")
  end)

  test("server waits for the hub to clear before drawing after controller attach", function()
    local s = arMachine()
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
    h.advance(1)
    equal(frame(h), {})
    h.exchange()
    s.advance(1)
    assert(frame(s)["turtle:1"], "server did not draw after ready acknowledgement")
  end)

  test("expired ready messages cannot restart server drawing while the hub falls back", function()
    local s = arMachine()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    local h = connect(s, true)
    local ready
    for _, p in ipairs(h.sent) do
      if p.msg.op == "ar-control" and p.msg.action == "lease" and p.msg.untilAt then ready = p.msg end
    end
    assert(ready)
    s.advance(15)
    h.advance(15)
    assert(frame(h)["turtle:1"])
    equal(frame(s), {})
    s.request(ready)
    s.advance(1)
    equal(frame(s), {}, "delayed permission revived the old drawer")
  end)

  test("mirrors and authenticated leases without replies cannot extend drawing into the hub fallback", function()
    local s = arMachine()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    local h = connect(s, true)
    local cursor = #h.sent
    for second = 1, 40 do
      s.advance(1)
      h.advance(1)
      while cursor < #h.sent do
        cursor = cursor + 1
        local p = h.sent[cursor]
        if p.proto == "fleetserver" then s.request(p.msg) end
      end
      if second >= 10 then equal(frame(s), {}, "unanswered mirrors renewed drawing permission") end
    end
    equal(s.state().arHub, 7, "talking hub was forgotten while its replies were lost")
    assert(frame(h)["turtle:1"])
  end)

  test("a missing command ack does not end AR ownership before its liveness timeout", function()
    local s = arMachine()
    s.attached = true
    s.start(serverCode)
    local h = connect(s, true)
    h.push("char", "r")
    h.advance(2)
    equal(#h.arCalls, 2, "command fallback also started a second AR drawer")
  end)

  test("server restart waits for its saved AR hub to relinquish the fallback view", function()
    local s = arMachine()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("mining", "Mining"))
    local h = connect(s, true)
    h.advance(15)
    assert(frame(h)["turtle:1"])
    local restored = arMachine()
    restored.attached, restored.files = true, s.files
    restored.start(serverCode)
    restored.advance(1)
    equal(#restored.arCalls, 2, "restarted server drew over the hub fallback")
    equal(frame(restored), {})
    local sentBeforeReconnect = #h.sent
    h.exchange(restored)
    equal(#restored.arCalls, 2)
    h.advance(1)
    h.exchange(restored)
    h.advance(1)
    equal(frame(h), {})
    h.exchange(restored)
    local ready
    for i, p in ipairs(h.sent) do
      if i > sentBeforeReconnect and p.msg.op == "ar-control" and p.msg.action == "lease" and p.msg.untilAt then ready = p.msg end
    end
    assert(ready, "hub did not send authenticated drawing permission after clearing")
    restored.request(ready)
    restored.advance(1)
    assert(frame(restored)["turtle:1"])
  end)

  test("hub follows controller loss and reattach at the server", function()
    local s = arMachine()
    s.attached = true
    s.start(serverCode)
    s.status(1, miner("lost", "LOST"))
    local h = connect(s, true)
    s.attached = false
    s.push("peripheral_detach", "arbitrary_controller_name")
    h.advance(5)
    h.exchange()
    h.advance(1)
    assert(frame(h)["turtle:1"], "server controller loss did not resume local AR")
    s.attached = true
    s.push("peripheral", "arbitrary_controller_name")
    h.advance(5)
    h.exchange()
    h.advance(1)
    equal(frame(h), {})
    local calls = #h.arCalls
    h.advance(5)
    h.exchange()
    equal(#h.arCalls, calls)
  end)

  test("a vanished turtle shows as missing and the fleet screen offers forget turtle", function()
    local m = new()
    m.env.dofile = function(path) return assert(loadfile(path, "t", m.env))() end
    for _, name in ipairs({ "ssot.lua", "atomic.lua", "dead.lua", "mine-tasks.lua", "warehouse-tasks.lua" }) do
      m.files[name] = read(name)
    end
    m.files["ssot.cfg"] = '{controllers={["1"]="test-secret-123456",["2"]="test-secret-123456"},deadTurtles=true,deadAfterMs=10000,leaseMs=5000}'
    m.start(serverCode)
    local n = 0
    local function call(id, op, fields)
      n = n + 1
      local msg = {}
      for k, v in pairs(fields or {}) do msg[k] = v end
      msg.v, msg.type, msg.expect, msg.op = 1, "ssot", "ssot_reply", op
      msg.boot, msg.rid, msg.counter, msg.secret = "turtle-" .. id, "h5-" .. n, n, "test-secret-123456"
      local before = #m.sent
      m.push("rednet_message", id, msg, "fleetserver")
      equal(#m.sent, before + 1, op .. " got no reply")
      return m.sent[#m.sent].msg
    end
    local p = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 }
    local to = { dim = p.dim, x = 1, y = 64, z = 0 }
    equal(call(1, "sync", { pose = p }).ok, true)
    local g = call(1, "reserve", { pose = p, to = to })
    equal(g.ok, true)
    equal(call(1, "start", { pose = p, token = g.token, epoch = g.epoch }).ok, true)
    m.push("rednet_message", 1, { type = "status", label = "Digger", status = "mining" }, "minearmy")
    m.advance(12)
    local beside = { dim = p.dim, x = 2, y = 64, z = 0 }
    equal(call(2, "sync", { pose = beside }).ok, true)
    equal(call(2, "reserve", { pose = beside, to = to }).ok, true, "started cells stayed reserved after silence")
    local function lastWrite(text)
      local x, y, cx, cy, found = 1, 1, 1, 1, false
      for _, line in ipairs(m.output) do
        local item = assert(load("return " .. line, "=out", "t", {}))()
        if item[1] == "dashboard" and item[2] == "setCursorPos" then cx, cy = item[3], item[4]
        elseif item[1] == "dashboard" and item[2] == "write" and type(item[3]) == "string" and item[3]:find(text, 1, true) then
          found, x, y = true, cx, cy
        end
      end
      assert(found, "screen never wrote " .. text)
      return x, y
    end
    local _, row = lastWrite("missing")
    m.push("monitor_touch", "dashboard", 2, row)
    local fx, fy = lastWrite("forget turtle")
    m.push("monitor_touch", "dashboard", fx + 1, fy)
    local stored = assert(load("return " .. m.files["ssot.state"], "=ssot", "t", {}))()
    equal(stored.value.poses[1], nil)
    equal(stored.value.poses[2].x, 2)
    equal(stored.value.moves[2].to.x, 1)
    assert(table.concat(m.output, "\n"):find("Forgot turtle #1", 1, true), "forget was not confirmed")
  end)
end
