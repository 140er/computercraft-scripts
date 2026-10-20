local function source(path)
  if io then
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return data
  end
  local file = assert(fs.open(path, "r"))
  local data = file.readAll()
  file.close()
  return data
end

local mocks = dofile("tests/mocks.lua")
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 print("PASS " .. name)
  else failed = failed + 1 print("FAIL " .. name .. "\n" .. tostring(err)) end
end

local function fixture(enabled, width, height, monitor)
  local m = mocks.new(false)
  local env, native = m.env, m.env.term.native()
  native.getSize = function() return width or 51, height or 19 end
  native.setCursorBlink = function() end
  local cursor, writeText = 1, native.write
  native.setCursorPos = function(x, y)
    assert(x >= 1 and x <= (width or 51) and y >= 1 and y <= (height or 19), "Drawing outside terminal")
    cursor = x
  end
  native.write = function(text)
    assert(cursor + #text - 1 <= (width or 51), "Text exceeds terminal")
    writeText(text)
  end
  setmetatable(env.term, { __index = native })
  env.term.current = function() return native end
  env.keys = { backspace = 1, escape = 2, enter = 3, up = 4, down = 5 }
  env.settings = { get = function(key, default)
    assert(key == "wh2.enabled" and default == false)
    return enabled == nil and default or enabled
  end }
  env.sleep = function() env.os.pullEvent("host_test_tick") end
  env.write = function(...) env.print(...) end
  env.read = function() local _, line = env.os.pullEvent("host_test_line") return line end
  local find = env.peripheral.find
  env.peripheral.find = function(kind, filter)
    if kind == "monitor" and not monitor then return nil end
    return find(kind, filter)
  end
  m.files["wh2.cfg"] = mocks.encode({ server = 0, pairingFile = "controller.pair" })
  local openFile = env.fs.open
  env.fs.open = function(path, mode)
    assert(mode == "r", "Wizard wrote local state")
    return openFile(path, mode)
  end
  m.calls, m.dispatches, m.factories, m.workers = {}, {}, 0, 0
  m.client = {
    call = function(op, body)
      assert(not m.receiving, "Call ran inside receiver dispatch")
      m.calls[#m.calls + 1] = { op = op, body = body }
      return { ok = true, records = {}, cursor = 0, revision = body.topic == "classes" and "0:0" or 0 }
    end,
    dispatch = function(...)
      m.receiving = true
      m.dispatches[#m.dispatches + 1] = { ... }
      m.receiving = false
      return true
    end,
    worker = function()
      m.workers = m.workers + 1
      while true do env.os.pullEvent("host_test_outbound") end
    end,
  }
  local modules = {}
  env.require = function(name)
    if name=="ssot-auth" then
      if m.missingAuth then error("Missing authentication dependency") end
      return {}
    end
    if name=="ssot-client" then return {new=function(config)
      assert(config.secret==nil and config.token==nil,"Legacy pairing material reached the constructor")
      m.rpcConfig=config
      return m.client
    end} end
    if name == "wh2-client" then
      if m.missing then error("Missing fleet dependency") end
      return { new = function(config)
        m.factories, m.config = m.factories + 1, config
        return m.client
      end }
    end
    if not modules[name] then modules[name] = assert(load(source(name .. ".lua"), "@" .. name, "t", env))() end
    return modules[name]
  end
  env.rednet.lookup = function() error("Raw discovery forbidden") end
  env.rednet.send = function() error("Raw send forbidden") end
  env.rednet.receive = function() error("Extra receiver forbidden") end
  env.rednet.broadcast = function() error("Raw broadcast forbidden") end
  function m.startClient(...)
    local args = table.pack(...)
    m.app = coroutine.create(function()
      assert(load(source("roomsorter.lua"), "@roomsorter.lua", "t", env))(table.unpack(args, 1, args.n))
    end)
    m.push()
  end
  function m.push(...)
    local ok, err = coroutine.resume(m.app, ...)
    assert(ok, err)
    while #m.queued > 0 and coroutine.status(m.app) ~= "dead" do
      local event = table.remove(m.queued, 1)
      ok, err = coroutine.resume(m.app, table.unpack(event, 1, event.n))
      assert(ok, err)
    end
  end
  function m.hasText(text)
    return table.concat(m.output, "\n"):find(text, 1, true) ~= nil
  end
  function m.orderMode()
    env.rednet.lookup = function(protocol) assert(protocol == "roomsorter") return 23 end
    env.rednet.send = function(id, msg, protocol)
      assert(id == 23 and protocol == "roomsorter" and msg.cmd == "stock", "Wizard used legacy transport")
      env.os.queueEvent("rednet_message", 23, {
        rid = msg.rid, totals = {}, state = "Idle", version = 15,
      }, "roomsorter")
    end
  end
  m.host = env.require("wh2-wizard-host")
  return m
end

test("disabled host never loads fleet or config and board shows disabled", function()
  local m = fixture()
  m.env.fs.open = function() error("Disabled host read private config") end
  local host = m.host.open()
  assert(not host.context.enabled and m.factories == 0)
  assert(host.dispatch(0, {}, "fleetserver") == false)
  local board = m.env.require("wh2-board").open(host.context)
  board.tick()
  board.draw()
  assert(m.hasText("Wizard disabled"))
end)

test("missing fleet fails visibly without raw transport fallback", function()
  local m = fixture(true)
  m.missing = true
  local host = m.host.open()
  local reply, err, code = host.context.client.call("wh2-get", {})
  assert(reply == nil and code == "unavailable" and err:find("wh2-client", 1, true))
  local board = m.env.require("wh2-board").open(host.context)
  board.tick()
  board.draw()
  assert(m.hasText("Authenticated wh2-client"))
  assert(not host.dispatch(0, {}, "fleetserver") and m.factories == 0)
end)

test("private pinned config constructs one fleet client shared with board", function()
  local m = fixture(true)
  local host = m.host.open({ role = "panel" })
  assert(not host.error and host.context.client == m.client and host.context.role == "panel")
  assert(m.factories == 1 and m.rpcConfig.server == 0 and m.rpcConfig.pairingFile == "controller.pair")
  assert(m.config.rpc==m.client and m.config.enabled and m.config.role=="panel")
  local board = m.env.require("wh2-board").open(host.context)
  board.tick()
  assert(#m.calls == 2 and m.factories == 1)
  local packet = { type = "authenticated_reply" }
  assert(host.dispatch(0, packet, "fleetserver"))
  assert(m.dispatches[1][1] == 0 and m.dispatches[1][2] == packet and m.dispatches[1][3] == "fleetserver")
  assert(m.workers == 0)
  local thread = coroutine.create(host.worker)
  assert(coroutine.resume(thread))
  assert(coroutine.status(thread) == "suspended" and m.workers == 1)
  assert(not pcall(host.worker) and m.workers == 1)
end)

test("absent, malformed, and unpinned config never starts fleet", function()
  for _, config in ipairs({ "false", "{server='lookup'}", "{server=-1}", "{server=1.5}", "{server=math.huge}", "{" }) do
    local m = fixture(true)
    m.files["wh2.cfg"] = config
    assert(m.host.open().error:find("Pin server", 1, true))
    assert(m.factories == 0)
  end
  local m = fixture(true)
  m.files["wh2.cfg"] = nil
  assert(m.host.open().error and m.factories == 0)
end)

test("injected shared client needs opt-in and the complete fleet interface", function()
  local m = fixture(true)
  m.env.fs.open = function() error("Injected client read config") end
  local host = m.host.open({ client = m.client })
  assert(host.context.client == m.client and m.factories == 0)
  assert(m.host.open({ client = { call = m.client.call } }).error)
  local off = fixture(false)
  assert(off.host.open({ client = m.client }).context.client ~= m.client)
end)

test("a stopped outbound worker fails visibly instead of leaving queued calls waiting", function()
  local m = fixture(true)
  m.client.worker = function() end
  local ok, err = pcall(m.host.open({ client = m.client }).worker)
  assert(not ok and err:find("worker stopped", 1, true))
end)

test("direct wizard command precedes discovery and runs one receiver and worker", function()
  local m = fixture(true)
  m.startClient("client", "wizard")
  assert(m.factories == 1 and m.workers == 1 and m.hasText("Material wizard"))
  assert(#m.calls == 2)
  m.push("rednet_message", 0, { type = "hint" }, "fleetserver")
  assert(#m.dispatches == 1 and m.dispatches[1][1] == 0)
  m.push("char", "q")
  assert(coroutine.status(m.app) == "dead")
end)

test("direct disabled and missing dependency commands explain failure before discovery", function()
  for _, enabled in ipairs({ false, true }) do
    local m = fixture(enabled)
    m.missing = true
    m.startClient("client", "wizard")
    assert(coroutine.status(m.app) == "dead" and m.factories == 0 and m.workers == 0)
    assert(m.hasText(enabled and "Authenticated wh2-client unavailable" or "Wizard disabled"))
  end
end)

test("queued board calls complete through the outer receiver while outbound work is suspended", function()
  local m = fixture(true)
  local env, pending, serial = m.env, nil, 0
  m.sent = {}
  m.client.call = function(op, body)
    assert(not pending, "Concurrent calls bypassed the shared client")
    serial = serial + 1
    local request = { serial = serial, op = op, body = body }
    pending = request
    env.os.queueEvent("host_test_request")
    while not request.reply do env.os.pullEvent("host_test_reply") end
    return request.reply
  end
  m.client.worker = function()
    m.workers = m.workers + 1
    while true do
      if pending and not pending.sent then
        pending.sent = true
        m.sent[#m.sent + 1] = pending
      end
      env.os.pullEvent("host_test_request")
    end
  end
  m.client.dispatch = function(sender, msg, protocol)
    if sender ~= 0 or protocol ~= "fleetserver" or not pending or msg.serial ~= pending.serial then return false end
    pending.reply = msg.reply
    pending = nil
    env.os.queueEvent("host_test_reply")
    return true
  end
  m.startClient("client", "wizard")
  assert(#m.sent == 1 and m.sent[1].body.topic == "questions")
  m.push("rednet_message", 9, { serial = 1, reply = {} }, "fleetserver")
  assert(#m.sent == 1)
  m.push("rednet_message", 0, { serial = 1,
    reply = { ok = true, revision = 0, records = {}, cursor = 0 } }, "fleetserver")
  assert(#m.sent == 2 and m.sent[2].body.topic == "classes")
  m.push("rednet_message", 0, { serial = 2,
    reply = { ok = true, revision = "0:0", records = {}, cursor = 0 } }, "fleetserver")
  assert(m.hasText("Questions 0") and m.workers == 1 and m.factories == 1)
  m.push("char", "q")
  assert(coroutine.status(m.app) == "dead")
end)

test("factory failures stay unavailable and do not expose private config", function()
  local m = fixture(true)
  local requireModule = m.env.require
  m.env.require = function(name)
    if name == "wh2-client" then return { new = function() error("private-pairing-key") end } end
    return requireModule(name)
  end
  local host = m.host.open()
  assert(host.error == "Authenticated wh2-client unavailable")
  assert(not host.context.client.call("wh2-get", {}))
end)

test("missing authentication fails before constructing or transmitting a legacy client",function()
  local m=fixture(true)
  m.missingAuth=true
  local original=m.env.require
  m.env.require=function(name)
    assert(name~="ssot-client","Legacy transport loaded before authentication prerequisite")
    return original(name)
  end
  local host=m.host.open()
  assert(host.error=="Authenticated wh2-client unavailable" and m.factories==0 and m.rpcConfig==nil)
end)

test("an injected RPC uses the fleet constructor and preserves the pinned server",function()
  local m=fixture(true)
  m.missingAuth=true
  local host=m.host.open({rpc=m.client,role="hub"})
  assert(not host.error and m.config.rpc==m.client and m.config.role=="hub" and m.factories==1)
  assert(m.rpcConfig==nil)
end)

test("terminal and pocket order screens open wizard by key and touch and return", function()
  for _, size in ipairs({ { 51, 19 }, { 26, 20 } }) do
    for _, entry in ipairs({ "keyboard", "touch" }) do
      local m = fixture(true, size[1], size[2])
      m.orderMode()
      m.startClient("client")
      assert(m.hasText("Materials/Wizard [w]") and m.workers == 1)
      if entry == "keyboard" then m.push("char", "w")
      else m.push("mouse_click", 1, 3, size[2] - 1) end
      assert(m.hasText("Material wizard") and #m.calls == 2)
      m.push("rednet_message", 0, { type = "hint" }, "fleetserver")
      m.push("char", "q")
      assert(coroutine.status(m.app) == "suspended")
      m.push("char", "w")
      assert(#m.calls == 4 and m.factories == 1 and m.workers == 1)
      m.push("char", "q")
      m.push("mouse_click", 1, size[1] - 3, size[2])
      assert(coroutine.status(m.app) == "dead", "Order screen quit fell through to turtle runtime")
    end
  end
end)

test("monitor button and command prompt open the board and return without stale typing", function()
  local m = fixture(true, 51, 19, true)
  m.orderMode()
  m.startClient("client")
  assert(m.hasText("Materials/Wizard [w]"))
  m.push("monitor_touch", "dashboard", 3, 39)
  assert(#m.calls == 2)
  m.push("monitor_touch", "dashboard", 12, 40)
  m.push("host_test_line", "wizard")
  assert(#m.calls == 4 and m.workers == 1 and m.factories == 1)
  m.push("char", "q")
  m.push("host_test_line", "quit")
  assert(coroutine.status(m.app) == "dead")
end)

print(string.format("Wizard host %d passed, %d failed", passed, failed))
assert(failed == 0, "Wizard host checks failed")
return { passed = passed, failed = failed }
