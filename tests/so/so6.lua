local H = dofile("tests/so/harness.lua")

local function setup(extra)
  local net = H.new()
  local server = net.machine({ id = 1, modem = true })
  server.install({ "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua",
    "so-mod-display.lua", "so-mod-shop.lua" })
  local libs = {
    "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing",
  }
  for _, name in ipairs(libs) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path, "rb"))
    server.files[path] = f:read("*a")
    f:close()
  end
  if extra then extra(server) end
  server.boot("so-server.lua")
  assert(server.alive(), tostring(server.error))
  local client = net.machine({ id = 2, modem = true })
  client.install({ "so-proto.lua" })
  local proto = client.env.dofile("so-proto.lua")
  local key = string.rep("ab", 32)
  assert(server.env.SO.pair.remember(2, key))
  local function send(kind, body, wire)
    wire = wire or proto.encode(proto.build(key, kind, body))
    client.env.rednet.send(1, wire, "so")
    net.flush()
    assert(server.alive(), tostring(server.error))
    return wire
  end
  local function frame()
    send("view.get", {})
    for i = #server.sent, 1, -1 do
      local msg = server.sent[i].payload
      if msg.t == "view.frame" then return msg.body end
    end
    error("no frame")
  end
  net.advance(1)
  send("hello", { w = 120, h = 100 })
  send("input", { id = "shop", x = 1, y = 2 })
  return net, server, client, send, frame
end

local function turtle(net, hosted)
  local t = net.machine({ id = 3, modem = true, turtle = true })
  t.spawn([[
rednet.open("back")
]] .. (hosted and 'rednet.host("roomsorter", "storage")\n' or '') .. [[
orders = 0
stock = { ["minecraft:stone"] = 40, ["minecraft:dirt"] = 10 }
while true do
  local ev, id, msg, protocol = os.pullEvent()
  if ev == "rednet_message" and protocol == "roomsorter" then
    if msg.cmd == "stock" then
      rednet.send(id, { rid = msg.rid, totals = stock, state = "Sorting" }, protocol)
    elseif msg.cmd == "order" then
      orders = orders + 1
      last = msg
      rednet.send(id, { "Getting " .. msg.n .. " " .. msg.text, "Queued", rid = msg.rid }, protocol)
    end
  end
end
]])
  return t
end

local function text(frame)
  local lines = {}
  for _, row in ipairs(frame.rows) do lines[#lines + 1] = row.text end
  return table.concat(lines, "\n")
end

return function(test, equal)
  test("shop orders reach the storage turtle once and show its reply", function()
    local net, server, client, send, frame = setup()
    local t = turtle(net, true)
    net.advance(10)
    local picture = frame()
    local buy
    for _, b in ipairs(picture.buttons) do
      if b.label == "16" then buy = b break end
    end
    assert(buy, "missing order button")
    local wire = send("input", { id = buy.id, x = buy.x, y = buy.y })
    send("input", {}, wire)
    net.advance(20)
    equal(t.env.orders, 1)
    equal(t.env.last.text, "minecraft:stone")
    equal(t.env.last.n, 16)
    assert(text(frame()):find("Order: Getting 16 minecraft:stone", 1, true))
    assert(text(frame()):find("Order: Queued", 1, true))
    send("input", { text = "dirt", x = 1, y = 1 })
    local filtered = text(frame())
    assert(filtered:find("minecraft:dirt", 1, true))
    for _, row in ipairs(frame().rows) do
      if row.text:sub(1, 6) ~= "Order:" then
        assert(not row.text:find("minecraft:stone", 1, true))
      end
    end
    assert(server.alive() and t.alive())
  end)

  test("shop discovers a turtle starting two minutes later", function()
    local net, _, _, _, frame = setup()
    assert(text(frame()):find("Storage room not found, still looking", 1, true))
    net.advance(120)
    assert(text(frame()):find("Storage room not found, still looking", 1, true))
    turtle(net, true)
    net.advance(10)
    local shown = text(frame())
    assert(shown:find("Sorting", 1, true))
    assert(shown:find("minecraft:stone", 1, true))
  end)

  test("shop discovers broadcasts and shows a rising stock trend", function()
    local net, _, _, _, frame = setup()
    local t = turtle(net, false)
    t.env.rednet.broadcast({ totals = t.env.stock, state = "Sorting" }, "roomsorter_stock")
    net.flush()
    net.advance(60)
    t.env.stock = { ["minecraft:stone"] = 80 }
    t.env.rednet.broadcast({ totals = t.env.stock, state = "Sorting" }, "roomsorter_stock")
    net.flush()
    net.advance(1)
    local shown = text(frame())
    assert(shown:find("minecraft:stone", 1, true))
    assert(shown:find(string.char(24), 1, true) or shown:find("^", 1, true), shown)
  end)

  test("shop trends fall, stay flat and forget samples after an hour", function()
    local net, _, _, _, frame = setup()
    local t = turtle(net, false)
    local function broadcast(count)
      t.env.stock = { ["minecraft:stone"] = count }
      t.env.rednet.broadcast({ totals = t.env.stock, state = "Sorting" }, "roomsorter_stock")
      net.flush()
    end
    broadcast(40)
    net.advance(1)
    assert(text(frame()):find("- 40 minecraft:stone", 1, true))
    broadcast(20)
    assert(text(frame()):find("v 20 minecraft:stone", 1, true))
    net.advance(3601)
    assert(text(frame()):find("- 20 minecraft:stone", 1, true))
    broadcast(60)
    assert(text(frame()):find("^ 60 minecraft:stone", 1, true))
  end)

  test("server routes other protocols to listen and so only to dispatch", function()
    local net, server, client, send = setup(function(s)
      s.files["so-mod-probe.lua"] = [[
local P = { name = "probe", handlers = {}, other = 0, so = 0, calls = 0 }
P.listen = {
  roomsorter = function(id, msg) P.other = P.other + 1 P.sender = id P.message = msg end,
  so = function() P.so = P.so + 1 end,
}
P.handlers.probe = function(msg, reply) P.calls = P.calls + 1 reply("ack", {}) end
return P
]]
    end)
    turtle(net, true)
    client.env.rednet.send(1, { test = true }, "roomsorter")
    net.flush()
    local probe = server.env.SO.mods.probe
    equal(probe.other, 1)
    equal(probe.sender, 2)
    equal(probe.message, { test = true })
    send("probe", {})
    equal(probe.calls, 1)
    equal(probe.so, 0)
  end)

  test("a broken listen does not stop the server or later listeners", function()
    local net, server, client = setup(function(s)
      s.files["so-mod-a-broken.lua"] = [[
return { name = "broken", handlers = {}, listen = { roomsorter_stock = function() error("broken listener") end } }
]]
    end)
    local t = turtle(net, false)
    t.env.rednet.broadcast({ totals = { ["minecraft:stone"] = 12 }, state = "Ready" }, "roomsorter_stock")
    net.flush()
    net.advance(2)
    assert(server.alive(), tostring(server.error))
    assert(table.concat(server.log, "\n"):find("broken listener", 1, true))
    local display = server.env.SO.mods.display
    local got
    display.handlers["view.get"]({ from = client.id }, function(_, body) got = body end)
    assert(text(got):find("minecraft:stone", 1, true))
  end)
end
