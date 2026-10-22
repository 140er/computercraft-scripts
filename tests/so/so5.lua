local harness = dofile("tests/so/harness.lua")

local SOURCES = {
  "so-proto.lua", "so-pair.lua", "so-store.lua", "so-server.lua",
  "so-mod-state.lua", "so-mod-cells.lua", "so-mod-display.lua", "so-mod-drops.lua",
}

local LIB = {
  "lib/ccryptolib/x25519.lua",
  "lib/ccryptolib/random.lua",
  "lib/ccryptolib/blake3.lua",
  "lib/ccryptolib/chacha20.lua",
  "lib/ccryptolib/config.lua",
  "lib/ccryptolib/internal/util.lua",
  "lib/ccryptolib/internal/hw.lua",
  "lib/ccryptolib/internal/curve25519.lua",
  "lib/ccryptolib/internal/fp.lua",
  "lib/ccryptolib/internal/edwards25519.lua",
  "lib/ccryptolib/internal/packing.lua",
}

local function installTree(machine)
  for i = 1, #LIB do
    local path = LIB[i]
    local handle = assert(io.open(path, "rb"), "missing " .. path)
    local data = handle:read("*a")
    handle:close()
    machine.files[path] = data
  end
  assert(machine.files["lib/ccryptolib/x25519.lua"], "ccryptolib was not copied")
  assert(machine.files["so-pair.lua"], "so-pair.lua missing")
end

local function newGrid(getSize, color)
  local cells = {}
  local cx, cy = 1, 1
  local g = { overflow = 0 }
  g.getSize = getSize
  g.isColor = function() return not not color end
  g.clear = function() cells = {} end
  g.setCursorPos = function(x, y) cx, cy = x, y end
  g.getCursorPos = function() return cx, cy end
  g.write = function(text)
    text = tostring(text)
    local w, h = getSize()
    if cy < 1 or cy > h then
      if #text > 0 then g.overflow = g.overflow + 1 end
      cx = cx + #text
      return
    end
    cells[cy] = cells[cy] or {}
    for i = 1, #text do
      local x = cx + i - 1
      if x < 1 or x > w then g.overflow = g.overflow + 1
      else cells[cy][x] = text:sub(i, i) end
    end
    cx = cx + #text
  end
  g.blit = function(text) g.write(text) end
  g.line = function(y)
    local w = getSize()
    local row = cells[y] or {}
    local parts = {}
    for x = 1, w do parts[x] = row[x] or " " end
    return table.concat(parts)
  end
  return g
end

local function lastCode(server)
  local code
  for found in table.concat(server.log, "\n"):gmatch("Pair code: (%d%d%d%d%d%d)") do
    code = found
  end
  return code
end

local function payloads(machine, kind, id)
  local list = {}
  for i = 1, #machine.sent do
    local item = machine.sent[i]
    local payload = item.payload
    if type(payload) == "table" and payload.t == kind and (id == nil or item.id == id) then
      list[#list + 1] = payload
    end
  end
  return list
end

local function pressVisible(net, server, client, surface, label, event)
  local frames = payloads(server, "view.frame", client.id)
  local picture = assert(frames[#frames], "no frame").body
  local w, h = surface.getSize()
  for _, button in ipairs(picture.buttons) do
    if button.label == label then
      assert(button.x >= 1 and button.y >= 1 and button.y <= h
        and button.x + button.w - 1 <= w and #label <= button.w, "button is clipped")
      assert(surface.line(button.y):sub(button.x, button.x + #label - 1) == label, "button is not drawn")
      client.env.os.queueEvent(event, event == "mouse_click" and 1 or "right", button.x, button.y)
      net.flush()
      return
    end
  end
  error("no visible " .. label .. " button")
end

local function assertTables(machine)
  for i = 1, #machine.sent do
    assert(type(machine.sent[i].payload) == "table", "sent payload was not a table")
  end
end

local function waitSeconds(id, attempt)
  local n = attempt
  if n < 1 then n = 1 end
  n = math.floor(n)
  local base = 30
  if n <= 5 then
    base = 1
    local step = 1
    while step < n do
      base = base * 2
      step = step + 1
    end
  end
  local gap = base * (0.5 + ((id * 17 + n) % 50) / 100)
  if gap > 30 then gap = 30 end
  return gap
end

local function bootServer(net, withState)
  local server = net.machine({ id = 1, capacity = 16000000, modem = true })
  local files = {}
  for i = 1, #SOURCES do files[i] = SOURCES[i] end
  if not withState then
    files = {
      "so-proto.lua", "so-pair.lua", "so-store.lua", "so-server.lua",
      "so-mod-cells.lua", "so-mod-display.lua", "so-mod-drops.lua",
    }
  end
  server.install(files)
  installTree(server)
  server.boot("so-server.lua")
  net.flush()
  assert(server.alive(), tostring(server.error))
  return server
end

local function pairCode(net, server)
  server.env.os.queueEvent("key", 25, false)
  net.flush()
  assert(server.alive(), tostring(server.error))
  return assert(lastCode(server), "pair code missing")
end

local function feedCode(client, code)
  for i = 1, #code do
    client.env.os.queueEvent("char", code:sub(i, i))
  end
end

local function startDisplay(net, id)
  local client = net.machine({ id = id, capacity = 1000000, modem = true })
  client.install({ "so-proto.lua", "so-pair.lua", "so-store.lua", "display.lua" })
  installTree(client)
  return client
end

return function(test, equal)
  test("status fits a 1x1 monitor, a 3x2 monitor, and a pocket", function()
    local net = harness.new()
    local server = bootServer(net, true)
    server.env.SO.mods.state.emit("fuel", 3)
    local code = pairCode(net, server)
    local size = { w = 26, h = 20 }
    local client = startDisplay(net, 2)
    local mon = newGrid(function() return size.w, size.h end, true)
    local modem = client.env.peripheral.find("modem")
    client.env.peripheral.find = function(kind)
      if kind == "monitor" then return mon end
      if kind == "modem" then return modem end
    end
    client.env.peripheral.getName = function(dev)
      if dev == modem then return "back" end
      error("unknown peripheral", 0)
    end
    client.boot("display.lua")
    feedCode(client, code)
    net.flush()
    assert(client.alive(), tostring(client.error))
    assertTables(client)
    local hello = payloads(client, "hello")[1]
    equal(hello.body.w, 26)
    equal(hello.body.h, 19)
    equal(payloads(client, "view.sub")[1].body, {})
    local first = payloads(server, "view.frame", 2)
    assert(#first >= 1, "no frame")
    equal(first[#first].body.role, "generic")
    pressVisible(net, server, client, mon, "status", "monitor_touch")
    local wide = payloads(server, "view.frame", 2)
    equal(wide[#wide].body.role, "status")
    assert(wide[#wide].body.rows[1].text:find("status", 1, true), "status row")
    local sawFuel = false
    for i = 1, #wide[#wide].body.rows do
      if wide[#wide].body.rows[i].text:find("fuel 3", 1, true) then sawFuel = true end
    end
    assert(sawFuel, "status did not show state")
    assert(mon.overflow == 0, "wide overflow " .. mon.overflow)
    assert(mon.line(1):find("status", 1, true), mon.line(1))

    size.w, size.h = 1, 1
    mon.overflow = 0
    client.env.os.queueEvent("monitor_resize", "right")
    net.flush()
    local tiny = payloads(server, "view.frame", 2)
    local tinyBody = tiny[#tiny].body
    equal(tinyBody.role, "status")
    assert(#tinyBody.rows <= 1, "1x1 rows")
    for i = 1, #tinyBody.rows do
      assert(#tinyBody.rows[i].text <= 1, tinyBody.rows[i].text)
    end
    assert(#tinyBody.buttons == 0, "1x1 button")
    assert(mon.overflow == 0, "1x1 overflow")
    equal(mon.line(1), "s")

    size.w, size.h = 3, 2
    mon.overflow = 0
    client.env.os.queueEvent("monitor_resize", "right")
    net.flush()
    local mid = payloads(server, "view.frame", 2)
    local midBody = mid[#mid].body
    equal(midBody.role, "status")
    assert(#midBody.rows <= 2, "3x2 rows")
    for i = 1, #midBody.rows do
      assert(#midBody.rows[i].text <= 3, midBody.rows[i].text)
    end
    assert(mon.overflow == 0, "3x2 overflow")
    equal(mon.line(1), "sta")
    equal(mon.line(2):sub(1, 3), "rev")

    local pocketCode = pairCode(net, server)
    local pocket = startDisplay(net, 3)
    local face = newGrid(function() return 26, 20 end, true)
    pocket.env.term = face
    local pocketModem = pocket.env.peripheral.find("modem")
    pocket.env.peripheral.find = function(kind)
      if kind == "modem" then return pocketModem end
    end
    pocket.boot("display.lua")
    feedCode(pocket, pocketCode)
    net.flush()
    assert(pocket.alive(), tostring(pocket.error))
    assertTables(pocket)
    pressVisible(net, server, pocket, face, "status", "mouse_click")
    local pocketFrame = payloads(server, "view.frame", 3)
    equal(pocketFrame[#pocketFrame].body.role, "status")
    assert(#pocketFrame[#pocketFrame].body.rows <= 20, "pocket rows")
    for i = 1, #pocketFrame[#pocketFrame].body.rows do
      assert(#pocketFrame[#pocketFrame].body.rows[i].text <= 26, "pocket text")
    end
    assert(face.overflow == 0, "pocket overflow")
    assert(face.line(1):find("status", 1, true), face.line(1))
  end)

  test("a stopped server shows stale and retries up to 30 s", function()
    local net = harness.new()
    local server = bootServer(net, true)
    local code = pairCode(net, server)
    local client = startDisplay(net, 2)
    local mon = newGrid(function() return 26, 20 end, true)
    local modem = client.env.peripheral.find("modem")
    client.env.peripheral.find = function(kind)
      if kind == "monitor" then return mon end
      if kind == "modem" then return modem end
    end
    client.env.peripheral.getName = function(dev)
      if dev == modem then return "back" end
      error("unknown peripheral", 0)
    end
    client.boot("display.lua")
    feedCode(client, code)
    net.flush()
    assert(client.alive(), tostring(client.error))
    net.advance(9)
    assert(client.alive(), tostring(client.error))
    assert(mon.line(20):sub(22, 26) ~= "stale", "stale while the server was up")
    local before = #payloads(client, "hello")
    server.env.os.queueEvent("terminate")
    net.flush()
    assert(not server.alive(), "server still running")

    local function nextIn(seconds)
      local best
      for i = 1, #client.timers do
        local at = client.timers[i].at
        if not best or at < best then best = at end
      end
      assert(best, "no client timer")
      local gap = (best - net.time) / 1000
      assert(gap <= seconds + 0.001, "gap " .. gap)
      net.advance(gap)
      return gap
    end

    local untilStale = nextIn(10)
    assert(untilStale > 0, "stale timer was already due")
    assert(mon.line(20):sub(22, 26) == "stale", mon.line(20))
    equal(#payloads(client, "hello"), before)
    for attempt = 1, 7 do
      local gap = nextIn(30)
      local expect = waitSeconds(2, attempt)
      assert(math.abs(gap - expect) < 0.001, "gap " .. gap .. " expected " .. expect)
      assert(gap <= 30, "gap over 30")
      if attempt >= 6 then
        local uncapped = 32 * (0.5 + ((2 * 17 + attempt) % 50) / 100)
        if attempt > 6 then uncapped = (2 ^ (attempt - 1)) * (0.5 + ((2 * 17 + attempt) % 50) / 100) end
        assert(gap < uncapped - 0.5, "retry did not cap at 30")
      end
      equal(#payloads(client, "hello"), before + attempt)
    end
  end)

  test("a button reaches the registered screen once", function()
    local net = harness.new()
    local server = bootServer(net, true)
    local hits = 0
    local last
    server.env.SO.mods.display.screen("shop", function()
      return {
        rows = { { text = "Shop", fg = "0", bg = "f" } },
        buttons = { { id = "buy", x = 1, y = 2, w = 3, label = "buy" } },
      }
    end, function(event)
      hits = hits + 1
      last = event
    end)
    local code = pairCode(net, server)
    local client = startDisplay(net, 2)
    local mon = newGrid(function() return 26, 20 end, false)
    local modem = client.env.peripheral.find("modem")
    client.env.peripheral.find = function(kind)
      if kind == "monitor" then return mon end
      if kind == "modem" then return modem end
    end
    client.env.peripheral.getName = function(dev)
      if dev == modem then return "back" end
      error("unknown peripheral", 0)
    end
    client.boot("display.lua")
    feedCode(client, code)
    net.flush()
    assert(client.alive(), tostring(client.error))
    pressVisible(net, server, client, mon, "shop", "monitor_touch")
    equal(payloads(server, "view.frame", 2)[#payloads(server, "view.frame", 2)].body.role, "shop")
    equal(hits, 0)
    pressVisible(net, server, client, mon, "buy", "monitor_touch")
    equal(hits, 1)
    equal(last.id, "buy")
    equal(last.role, "shop")
    local sent = payloads(client, "input")
    local buttonMsg = sent[#sent]
    client.env.rednet.send(server.id, buttonMsg, "so")
    net.flush()
    equal(hits, 1)
    client.env.os.queueEvent("rednet_message", server.id, "not-a-table", "so")
    net.flush()
    assert(client.alive(), tostring(client.error))
    client.env.rednet.send(server.id, "not-a-table", "so")
    net.flush()
    assert(server.alive(), tostring(server.error))
    equal(hits, 1)
    client.env.os.queueEvent("char", "h")
    client.env.os.queueEvent("char", "i")
    client.env.os.queueEvent("key", 257, false)
    net.flush()
    equal(hits, 2)
    equal(last.text, "hi")
    assert(last.id == nil, "text input kept a button id")
    local textMsg = payloads(client, "input")
    client.env.rednet.send(server.id, textMsg[#textMsg], "so")
    net.flush()
    equal(hits, 2)
  end)

  test("a display role survives a server restart", function()
    local net = harness.new()
    local server = bootServer(net, true)
    local code = pairCode(net, server)
    local client = startDisplay(net, 2)
    local mon = newGrid(function() return 26, 20 end, true)
    local modem = client.env.peripheral.find("modem")
    client.env.peripheral.find = function(kind)
      if kind == "monitor" then return mon end
      if kind == "modem" then return modem end
    end
    client.env.peripheral.getName = function(dev)
      if dev == modem then return "back" end
      error("unknown peripheral", 0)
    end
    client.boot("display.lua")
    feedCode(client, code)
    net.flush()
    pressVisible(net, server, client, mon, "status", "monitor_touch")
    equal(payloads(server, "view.frame", 2)[#payloads(server, "view.frame", 2)].body.role, "status")
    server.env.os.queueEvent("terminate")
    net.flush()
    assert(not server.alive(), "server still running")
    local function jump()
      local best
      for i = 1, #client.timers do
        local at = client.timers[i].at
        if not best or at < best then best = at end
      end
      net.advance((best - net.time) / 1000)
    end
    jump()
    assert(mon.line(20):sub(22, 26) == "stale", "no stale before restart")
    jump()
    assert(#payloads(client, "hello") >= 2, "client did not retry")
    server.timers = {}
    server.error = nil
    server.boot("so-server.lua")
    net.flush()
    assert(server.alive(), tostring(server.error))
    local again = payloads(server, "view.frame", 2)
    equal(again[#again].body.role, "status")
  end)

  test("status still draws when the state module is missing", function()
    local net = harness.new()
    local server = bootServer(net, false)
    assert(server.env.SO.mods.state == nil, "state was loaded")
    local code = pairCode(net, server)
    local client = startDisplay(net, 2)
    local mon = newGrid(function() return 26, 20 end, true)
    local modem = client.env.peripheral.find("modem")
    client.env.peripheral.find = function(kind)
      if kind == "monitor" then return mon end
      if kind == "modem" then return modem end
    end
    client.env.peripheral.getName = function(dev)
      if dev == modem then return "back" end
      error("unknown peripheral", 0)
    end
    client.boot("display.lua")
    feedCode(client, code)
    net.flush()
    assert(client.alive(), tostring(client.error))
    assert(server.alive(), tostring(server.error))
    pressVisible(net, server, client, mon, "status", "monitor_touch")
    local frame = payloads(server, "view.frame", 2)
    local body = frame[#frame].body
    equal(body.role, "status")
    local saw = false
    for i = 1, #body.rows do
      if body.rows[i].text:find("no state", 1, true) then saw = true end
    end
    assert(saw, "missing state did not draw")
    assert(mon.overflow == 0, "overflow")
  end)

  test("view.get answers one frame and does not subscribe", function()
    local net = harness.new()
    local server = bootServer(net, true)
    local code = pairCode(net, server)
    local client = net.machine({ id = 2, capacity = 1000000, modem = true })
    client.install({ "so-proto.lua", "so-pair.lua", "so-store.lua" })
    installTree(client)
    client.spawn(string.format([[
proto = dofile("so-proto.lua")
store = dofile("so-store.lua")
pair = dofile("so-pair.lua")
pair.open(proto, store)
local ok, err = pair.join(%q)
assert(ok, err)
local reply, rerr = proto.request(%d, "view.get", {}, 2, 2)
assert(reply and reply.t == "view.frame", tostring(rerr))
GOT = reply
]], code, server.id))
    net.flush()
    assert(not client.error, tostring(client.error))
    assert(client.env.GOT.body.role == "generic", "view.get role")
    equal(#payloads(server, "view.frame", 2), 1)
    net.advance(5)
    equal(#payloads(server, "view.frame", 2), 1)
  end)
end
