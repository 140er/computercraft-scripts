local harness = dofile("tests/so/harness.lua")

local SOURCES = {
  "so-proto.lua", "so-pair.lua", "so-store.lua", "so-server.lua",
  "so-mod-state.lua", "so-mod-cells.lua", "so-mod-display.lua", "so-mod-drops.lua",
}

local TESTMOD = [[
local mod = { name = "test", ticks = 0, handlers = {} }
mod.handlers["test.ping"] = function(msg, reply)
  mod.seen = msg.body.value
  reply("ack", { ok = true })
end
mod.tick = function(now)
  mod.ticks = mod.ticks + 1
  mod.now = now
end
return mod
]]

local JOIN = [[
proto = dofile("so-proto.lua")
store = dofile("so-store.lua")
pair = dofile("so-pair.lua")
pair.open(proto, store)
local ok, err = pair.join(%q)
assert(ok, err)
JOINED = true
]]

return function(test, equal)
  local function logtext(m)
    return table.concat(m.log, "\n")
  end

  local function bootServer(cap, full, extra)
    local net = harness.new()
    local server = net.machine({ id = 1, capacity = cap, modem = true })
    server.install(full and SOURCES or { "so-server.lua" })
    if extra then extra(server) end
    server.boot("so-server.lua")
    net.flush()
    return net, server
  end

  local function pairWith(spawn, extra)
    local net, server = bootServer(16000000, true, extra)
    assert(server.alive(), tostring(server.error))
    local code = assert(logtext(server):match("Pair code: (%d%d%d%d%d%d)"), "pair code missing")
    equal(server.screen[1], "Pair code: " .. code)
    local client = net.machine({ id = 2, capacity = 1000000, modem = true })
    client.install({ "so-proto.lua", "so-pair.lua", "so-store.lua" })
    client.spawn(spawn(code, server.id))
    net.flush()
    assert(not client.error, tostring(client.error))
    assert(not server.error, tostring(server.error))
    assert(client.env.JOINED == true, "join did not finish")
    return net, server, client, code
  end

  local function acks(server)
    local n = 0
    for i = 1, #server.sent do
      local msg = server.env.SO.proto.decode(server.sent[i].payload)
      if msg and msg.t == "ack" then n = n + 1 end
    end
    return n
  end

  test("sha256 and hmac match known vectors", function()
    local env = setmetatable({
      os = { getComputerID = function() return 1 end, epoch = function() return 0 end },
      rednet = { send = function() end },
    }, { __index = _G })
    local proto = assert(loadfile("so-proto.lua", "t", env))()
    equal(proto.hex(proto.sha256("")),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    equal(proto.hex(proto.sha256("abc")),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    equal(proto.hex(proto.hmac("key", "The quick brown fox jumps over the lazy dog")),
      "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
    equal(proto.encode({ b = 1, a = "x" }), proto.encode({ a = "x", b = 1 }))
  end)

  test("so-server refuses on 1 MB and 8 MB disks with the message, boots on 16 MB", function()
    for _, cap in ipairs({ 1000000, 8000000 }) do
      local _, server = bootServer(cap, false)
      assert(not server.alive(), "booted on " .. cap)
      assert(not server.error, tostring(server.error))
      local text = logtext(server)
      assert(text:find("so-server: need 16000000 bytes, this disk has " .. cap .. ".", 1, true), text)
      assert(text:find("Set computer_space_limit in computercraft-server.toml to at least 16000000, then restart the world.", 1, true), text)
    end
    local _, server = bootServer(16000000, true)
    assert(server.alive(), tostring(server.error))
    assert(not logtext(server):find("need 16000000", 1, true), logtext(server))
    local state = server.env.SO.mods.state
    state.emit("k", "v")
    local view = state.view()
    equal(view.values.k, "v")
    equal(view.rev, 1)
    view.values.k = "changed"
    equal(state.get("k"), "v")
    assert(server.env.SO.mods.cells.isFree(0, 0, 0) == true)
    assert(server.env.SO.mods.cells.reserve(1, 0, 0, 0) == true)
    server.env.SO.mods.cells.markDug(0, 0, 0)
    assert(server.env.SO.mods.cells.isDug(0, 0, 0) == false)
    equal(server.env.SO.mods.drops.steps({ name = "minecraft:cobble", n = 1, where = "front" }), {})
    assert(server.env.SO.mods.drops.pick({ name = "minecraft:cobble", n = 1 }) == nil)
    server.env.SO.mods.display.screen("main", function() end, function() end)
  end)

  test("two fake machines pair with a code, then exchange hello and ack", function()
    local _, server, client = pairWith(function(code, id)
      return string.format(JOIN .. [[

local reply, rerr = proto.request(%d, "hello", { role = "turtle", label = "digger" }, 2, 2)
assert(reply and reply.t == "ack" and reply.body.ok == true, tostring(rerr))
HELLO = reply
]], code, id)
    end)
    assert(client.env.HELLO.t == "ack")
    local function keys(machine)
      local raw = assert(machine.files["so-keys"], "so-keys missing")
      return assert(machine.env.textutils.unserialize(raw)).value.keys
    end
    local shared = keys(server)[tostring(client.id)]
    equal(shared, keys(client)[tostring(server.id)])
    equal(#shared, 64)
  end)

  test("a message with a wrong MAC is dropped and logged", function()
    local net, server, client = pairWith(function(code)
      return string.format(JOIN, code)
    end)
    local before = acks(server)
    local key = client.env.pair.key(server.id)
    local msg = client.env.proto.build(key, "hello", { role = "turtle" })
    local last = msg.mac:sub(64, 64)
    msg.mac = msg.mac:sub(1, 63) .. (last == "a" and "b" or "a")
    client.env.rednet.send(server.id, client.env.proto.encode(msg), "so")
    net.flush()
    equal(acks(server), before)
    assert(logtext(server):find("so-server: bad mac from 2", 1, true), logtext(server))
    assert(not logtext(server):find("replay", 1, true), logtext(server))
  end)

  test("a replayed rid is dropped", function()
    local net, server, client = pairWith(function(code)
      return string.format(JOIN, code)
    end)
    local before = acks(server)
    local key = client.env.pair.key(server.id)
    local msg = client.env.proto.build(key, "hello", { role = "turtle" })
    local wire = client.env.proto.encode(msg)
    client.env.rednet.send(server.id, wire, "so")
    net.flush()
    client.env.rednet.send(server.id, wire, "so")
    net.flush()
    equal(acks(server), before + 1)
    assert(logtext(server):find("so-server: replay from 2", 1, true), logtext(server))
  end)

  test("an unknown type gets err", function()
    local net, server, client = pairWith(function(code)
      return string.format(JOIN, code)
    end)
    local key = client.env.pair.key(server.id)
    local msg = client.env.proto.build(key, "nope", {})
    client.env.rednet.send(server.id, client.env.proto.encode(msg), "so")
    net.flush()
    local last = assert(server.sent[#server.sent], "no reply")
    local reply = assert(server.env.SO.proto.decode(last.payload))
    equal(reply.t, "err")
    equal(reply.rid, msg.rid)
    equal(reply.body, { code = "unknown", text = "unknown type" })
  end)

  test("a test module so-mod-test.lua receives its message type and its tick runs", function()
    local net, server, client = pairWith(function(code)
      return string.format(JOIN, code)
    end, function(server)
      server.files["so-mod-test.lua"] = TESTMOD
    end)
    local mod = server.env.SO.mods.test
    equal(mod.ticks, 0)
    local stamp = net.time + 1000
    net.advance(1)
    equal(mod.ticks, 1)
    equal(mod.now, stamp)
    local key = client.env.pair.key(server.id)
    local msg = client.env.proto.build(key, "test.ping", { value = "hi" })
    client.env.rednet.send(server.id, client.env.proto.encode(msg), "so")
    net.flush()
    equal(mod.seen, "hi")
    equal(mod.ticks, 1)
  end)

  test("so-store refuses a write past its budget and the old file stays intact", function()
    local net = harness.new()
    local machine = net.machine({ id = 3, capacity = 16000000 })
    machine.install({ "so-store.lua" })
    machine.spawn([[
      local store = dofile("so-store.lua")
      local box = store.store("note", function(v) return type(v) == "table" end, 80)
      local ok, err = box.save({ n = 1 })
      assert(ok, err)
      local handle = fs.open("note", "r")
      KEPT = handle.readAll()
      handle.close()
      local again, budgetErr = box.save({ n = 1, big = string.rep("x", 200) })
      assert(again == false, "budget write succeeded")
      assert(type(budgetErr) == "string" and budgetErr:find("budget", 1, true), tostring(budgetErr))
      local now = fs.open("note", "r").readAll()
      assert(now == KEPT, "old file changed")
      local small, smallErr = box.save({ n = 2 })
      assert(small, smallErr)
      DONE = true
    ]])
    net.flush()
    assert(not machine.error, tostring(machine.error))
    assert(machine.env.DONE == true)
  end)

  test("the fake turtle digs and moves in the block world", function()
    local net = harness.new()
    net.world["0,0,0"] = "minecraft:stone"
    local turtle = net.machine({ id = 4, capacity = 1000000, turtle = true, x = 0, y = 0, z = 1, facing = 0 })
    turtle.spawn([[
      local ok, data = turtle.inspect()
      assert(ok and data.name == "minecraft:stone", "inspect")
      assert(turtle.dig(), "dig")
      assert(turtle.forward(), "forward")
      DONE = true
    ]])
    net.flush()
    assert(not turtle.error, tostring(turtle.error))
    assert(turtle.env.DONE == true)
    assert(net.world["0,0,0"] == nil, "stone remained")
    equal(turtle.pos.x, 0)
    equal(turtle.pos.y, 0)
    equal(turtle.pos.z, 0)
    equal(turtle.fuel, 999)
  end)
end
