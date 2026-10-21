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

local COUNTMOD = [[
local mod = { name = "count", hits = 0, handlers = {} }
mod.handlers.hello = function()
  mod.hits = mod.hits + 1
end
return mod
]]

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
    local handle = io.open(path, "rb")
    if not handle then return end
    local data = handle:read("*a")
    handle:close()
    machine.files[path] = data
  end
end

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
    if full then installTree(server) end
    if extra then extra(server) end
    server.boot("so-server.lua")
    net.flush()
    return net, server
  end

  local function pairWith(spawn, extra)
    local net, server = bootServer(16000000, true, extra)
    assert(server.alive(), tostring(server.error))
    server.env.os.queueEvent("key", 25, false)
    net.flush()
    assert(not server.error, tostring(server.error))
    local code = assert(logtext(server):match("Pair code: (%d%d%d%d%d%d)"), "pair code missing")
    equal(server.screen[1], "Pair code: " .. code .. " server " .. tostring(server.id))
    local client = net.machine({ id = 2, capacity = 1000000, modem = true })
    client.install({ "so-proto.lua", "so-pair.lua", "so-store.lua" })
    installTree(client)
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
      local payload = server.sent[i].payload
      if type(payload) == "table" and payload.t == "ack" then n = n + 1 end
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

  test("a repeated rid gets the saved reply again", function()
    local net, server, client = pairWith(function(code)
      return string.format(JOIN, code)
    end, function(srv)
      srv.files["so-mod-count.lua"] = COUNTMOD
    end)
    local before = acks(server)
    local key = client.env.pair.key(server.id)
    local msg = client.env.proto.build(key, "hello", { role = "turtle" })
    local wire = client.env.proto.encode(msg)
    client.env.rednet.send(server.id, wire, "so")
    net.flush()
    client.env.rednet.send(server.id, wire, "so")
    net.flush()
    equal(acks(server), before + 2)
    equal(server.env.SO.mods.count.hits, 1)
    assert(not logtext(server):find("replay", 1, true), logtext(server))
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

  test("a string payload, a 1 MB field, and a deep body are dropped and the server still answers", function()
    local net, server, client = pairWith(function(code)
      return string.format(JOIN, code)
    end)
    local key = client.env.pair.key(server.id)
    local before = acks(server)
    local hello = client.env.proto.build(key, "hello", { role = "turtle" })
    assert(client.env.proto.decode(client.env.proto.ser(hello)) == nil, "string payload decoded")
    client.env.rednet.send(server.id, client.env.proto.ser(hello), "so")
    net.flush()
    equal(acks(server), before)

    local big = client.env.proto.build(key, "hello", {})
    big.body.blob = string.rep("a", 1000000)
    assert(client.env.proto.decode(big) == nil, "1 MB field decoded")
    client.env.rednet.send(server.id, big, "so")
    net.flush()
    equal(acks(server), before)

    local deep = client.env.proto.build(key, "hello", {})
    local cur = deep.body
    for _ = 1, 8 do
      cur.n = {}
      cur = cur.n
    end
    deep.mac = client.env.proto.sign(key, deep)
    assert(client.env.proto.decode(deep) == nil, "deep body decoded")
    client.env.rednet.send(server.id, deep, "so")
    net.flush()
    equal(acks(server), before)

    local okm = client.env.proto.build(key, "hello", { role = "turtle" })
    client.env.rednet.send(server.id, okm, "so")
    net.flush()
    equal(acks(server), before + 1)
    assert(server.alive(), tostring(server.error))
    assert(logtext(server):find("so-server: bad message from 2", 1, true), logtext(server))
  end)

  local function latestCode(server)
    local code
    for found in logtext(server):gmatch("Pair code: (%d%d%d%d%d%d)") do code = found end
    return code
  end

  local function pressP(net, server)
    server.env.os.queueEvent("key", 25, false)
    net.flush()
    assert(not server.error, tostring(server.error))
    local code = assert(latestCode(server), "pair code missing")
    equal(server.screen[1], "Pair code: " .. code .. " server " .. tostring(server.id))
    return code
  end

  local function savedKey(machine, id)
    local raw = assert(machine.files["so-keys"], "so-keys missing")
    return assert(machine.env.textutils.unserialize(raw)).value.keys[tostring(id)]
  end

  local function bootClient(net, id)
    local client = net.machine({ id = id, capacity = 1000000, modem = true, turtle = true })
    client.install({ "so-proto.lua", "so-pair.lua", "so-store.lua" })
    installTree(client)
    return client
  end

  test("three turtles pair one after another and a re-pair needs a fresh code", function()
    local net, server = bootServer(16000000, true)
    assert(server.alive(), tostring(server.error))
    equal(server.screen[1], "Press P to pair")
    local clients = {}
    local codes = {}
    for n = 1, 3 do
      local id = n + 1
      local code = pressP(net, server)
      codes[n] = code
      local client = bootClient(net, id)
      clients[n] = client
      client.spawn(string.format(JOIN, code))
      net.flush()
      assert(not client.error, tostring(client.error))
      assert(client.env.JOINED == true, "turtle " .. id .. " did not pair")
      equal(savedKey(server, id), savedKey(client, server.id))
      equal(server.screen[1], "Press P to pair")
    end
    local burned = bootClient(net, 9)
    burned.spawn(string.format(JOIN, codes[3]))
    net.advance(8)
    assert(burned.env.JOINED ~= true, "spent code paired a fourth turtle")
    local again = clients[1]
    local first = savedKey(server, again.id)
    again.error = nil
    again.env.JOINED = nil
    again.spawn(string.format(JOIN, codes[1]))
    net.advance(8)
    assert(again.env.JOINED ~= true, "old code re-paired an existing id")
    equal(savedKey(server, again.id), first)
    local code = pressP(net, server)
    again.error = nil
    again.env.JOINED = nil
    again.spawn(string.format(JOIN, code))
    net.flush()
    assert(not again.error, tostring(again.error))
    assert(again.env.JOINED == true, "fresh code did not re-pair")
    local second = savedKey(server, again.id)
    equal(second, savedKey(again, server.id))
    assert(second ~= first, "re-pair kept the old key")
    local stale = pressP(net, server)
    net.advance(300)
    equal(server.screen[1], "Press P to pair")
    local late = bootClient(net, 10)
    late.spawn(string.format(JOIN, stale))
    net.advance(8)
    assert(late.env.JOINED ~= true, "expired code paired")
    assert(server.alive(), tostring(server.error))
  end)

  test("a listener that records pairing and knows the code cannot compute the key", function()
    local net, server, client, code = pairWith(function(pairCode)
      return string.format(JOIN, pairCode)
    end)
    local saved = savedKey(server, client.id)
    equal(saved, savedKey(client, server.id))
    equal(#saved, 64)
    local function guess(material)
      return client.env.proto.hex(client.env.proto.sha256(material))
    end
    local old = guess("so-pair-v1\0" .. server.id .. "\0" .. client.id .. "\0" .. code)
    assert(old ~= saved, "key is sha256 of the code and ids")
    local hs = guess("so-pair-hs-v2\0" .. server.id .. "\0" .. client.id .. "\0" .. code)
    assert(hs ~= saved, "key is the handshake mac key")
    local pubs = {}
    local function collect(value)
      if type(value) == "string" then
        assert(value ~= saved, "key appeared on the wire")
      elseif type(value) == "table" then
        if type(value.pub) == "string" then pubs[#pubs + 1] = value.pub end
        for k, item in pairs(value) do
          collect(k)
          collect(item)
        end
      end
    end
    for _, machine in ipairs({ server, client }) do
      for i = 1, #machine.sent do collect(machine.sent[i].payload) end
    end
    assert(#pubs >= 2, "public keys were not on the wire")
    local raws = {}
    for i = 1, #pubs do raws[i] = client.env.proto.unhex(pubs[i]) end
    local mixed = guess(code .. raws[1] .. raws[2])
    assert(mixed ~= saved, "key is sha256 of the code and public keys")
    local proof = client.env.proto.hex(client.env.proto.hmac(code, "so-pair-v2\0" .. raws[1] .. raws[2]))
    assert(proof ~= saved, "key is the pairing proof")
    local x = server.env.require("ccryptolib.x25519")
    local function unhex(hex) return server.env.SO.proto.unhex(hex) end
    equal(x.exchange(
      unhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
      unhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")),
      unhex("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"))
    assert(not server.error, tostring(server.error))
    assert(net.machines[server.id].alive())
  end)

  test("a replay 61s later is dropped and a retry runs the handler once", function()
    local net, server, client = pairWith(function(code)
      return string.format(JOIN, code)
    end, function(srv)
      srv.files["so-mod-count.lua"] = COUNTMOD
    end)
    local key = client.env.pair.key(server.id)
    local before = acks(server)
    local msg = client.env.proto.build(key, "hello", { role = "turtle" })
    local wire = client.env.proto.encode(msg)
    client.env.rednet.send(server.id, wire, "so")
    net.flush()
    for _ = 1, 256 do
      local filler = client.env.proto.build(key, "hello", { role = "turtle" })
      client.env.rednet.send(server.id, client.env.proto.encode(filler), "so")
    end
    net.flush()
    equal(acks(server), before + 257)
    net.advance(61)
    client.env.rednet.send(server.id, wire, "so")
    net.flush()
    equal(acks(server), before + 257)
    local fresh = client.env.proto.build(key, "hello", { role = "turtle" })
    client.env.rednet.send(server.id, client.env.proto.encode(fresh), "so")
    net.flush()
    equal(acks(server), before + 258)
    assert(server.alive(), tostring(server.error))

    local countNet, countServer, countClient = pairWith(function(code)
      return string.format(JOIN, code)
    end, function(srv)
      srv.files["so-mod-count.lua"] = COUNTMOD
    end)
    local send = countServer.env.rednet.send
    local skipped = false
    countServer.env.rednet.send = function(id, payload, protocol)
      local decoded = countServer.env.SO.proto.decode(payload)
      if not skipped and decoded and decoded.t == "ack" then
        skipped = true
        return
      end
      return send(id, payload, protocol)
    end
    local sentBefore = #countClient.sent
    countClient.spawn(string.format([[
      local reply, err = proto.request(%d, "hello", { role = "turtle" }, 0.4, 2)
      assert(reply and reply.t == "ack" and reply.body.ok == true, tostring(err))
      GOT = reply
    ]], countServer.id))
    countNet.flush()
    countNet.advance(0.5)
    assert(not countClient.error, tostring(countClient.error))
    assert(countClient.env.GOT and countClient.env.GOT.t == "ack", "retry got no reply")
    equal(countServer.env.SO.mods.count.hits, 1)
    local rid
    local hellos = 0
    for i = sentBefore + 1, #countClient.sent do
      local decoded = countClient.env.proto.decode(countClient.sent[i].payload)
      if decoded and decoded.t == "hello" then
        hellos = hellos + 1
        if not rid then rid = decoded.rid else equal(decoded.rid, rid) end
      end
    end
    equal(hellos, 2)
    equal(countClient.env.GOT.rid, rid)
  end)

  test("a fresh fake computer calls initWithTiming before its first random(32)", function()
    local net = harness.new()
    local machine = net.machine({ id = 8, capacity = 1000000 })
    machine.install({ "so-proto.lua", "so-pair.lua", "so-store.lua" })
    installTree(machine)
    machine.spawn([[
      proto = dofile("so-proto.lua")
      store = dofile("so-store.lua")
      pair = dofile("so-pair.lua")
      pair.open(proto, store)
      pair.invite()
      DONE = true
    ]])
    net.flush()
    assert(not machine.error, tostring(machine.error))
    assert(machine.env.DONE == true, "invite did not finish")
    local timing, mix, first32
    for i = 1, #machine.randomLog do
      local entry = machine.randomLog[i]
      if entry == "initWithTiming" and not timing then timing = i end
      if type(entry) == "string" and entry:sub(1, 4) == "mix:" and not mix then mix = entry:sub(5) end
      if entry == "random:32" and not first32 then first32 = i end
    end
    assert(timing and first32 and timing < first32,
      "initWithTiming before random(32), log: " .. table.concat(machine.randomLog, ","))
    assert(type(mix) == "string", "mix missing")
    local parts = {}
    for part in mix:gmatch("[^|]+") do parts[#parts + 1] = part end
    equal(#parts, 5)
    equal(parts[1], tostring(net.time))
    equal(parts[2], tostring(net.time / 1000))
    assert(parts[3]:sub(1, 6) == "table:", parts[3])
    equal(parts[5], tostring(machine.id))
    assert(tonumber(parts[4]), "math.random missing: " .. tostring(parts[4]))

    local noisy = net.machine({ id = 11, capacity = 1000000, timingError = true })
    noisy.install({ "so-proto.lua", "so-pair.lua", "so-store.lua" })
    installTree(noisy)
    noisy.spawn([[
      proto = dofile("so-proto.lua")
      store = dofile("so-store.lua")
      pair = dofile("so-pair.lua")
      pair.open(proto, store)
      local raw = pair.invite()
      assert(type(raw) == "string" and #raw == 6, tostring(raw))
      DONE = true
    ]])
    net.flush()
    assert(not noisy.error, tostring(noisy.error))
    assert(noisy.env.DONE == true, "invite failed after timing error")
    local saw = false
    for i = 1, #noisy.randomLog do
      if noisy.randomLog[i] == "initWithTiming" then saw = true end
    end
    assert(saw, "timing failure was not attempted")
  end)

  test("a retried pair message gets the saved ack", function()
    local net, server = bootServer(16000000, true)
    assert(server.alive(), tostring(server.error))
    local code = pressP(net, server)
    local client = bootClient(net, 2)
    local send = server.env.rednet.send
    local skipped = false
    server.env.rednet.send = function(id, payload, protocol)
      local decoded = server.env.SO.proto.decode(payload)
      if not skipped and decoded and decoded.t == "ack" then
        skipped = true
        return
      end
      return send(id, payload, protocol)
    end
    client.spawn(string.format([[
      proto = dofile("so-proto.lua")
      store = dofile("so-store.lua")
      pair = dofile("so-pair.lua")
      pair.open(proto, store)
      local ok, err = pair.join(%q)
      JOINED = ok
      JOINERR = err
    ]], code))
    net.flush()
    net.advance(7)
    assert(skipped, "first ack was not dropped")
    assert(not client.error, tostring(client.error))
    assert(client.env.JOINED == true, "retry got " .. tostring(client.env.JOINERR))
    equal(server.screen[1], "Press P to pair")
    assert(not logtext(server):find("bad mac", 1, true), logtext(server))
    local wire
    local sentPair = 0
    for i = 1, #client.sent do
      local payload = client.sent[i].payload
      if type(payload) == "table" and payload.t == "pair" then
        sentPair = sentPair + 1
        wire = payload
      end
    end
    equal(sentPair, 2)
    local key = savedKey(server, client.id)
    equal(key, savedKey(client, server.id))
    local before = acks(server)
    client.env.rednet.send(server.id, wire, "so")
    net.flush()
    equal(acks(server), before + 1)
    equal(savedKey(server, client.id), key)
    assert(not logtext(server):find("bad mac", 1, true), logtext(server))
    local function resign()
      local hs = client.env.pair.derive(code, server.id, client.id)
      return client.env.proto.build(hs, "pair", wire.body, wire.rid)
    end
    net.advance(112)
    client.env.rednet.send(server.id, resign(), "so")
    net.flush()
    equal(acks(server), before + 2)
    equal(savedKey(server, client.id), key)
    net.advance(3)
    client.env.rednet.send(server.id, resign(), "so")
    net.flush()
    equal(acks(server), before + 2)
    assert(logtext(server):find("so-server: bad mac from 2", 1, true), logtext(server))
    assert(server.alive(), tostring(server.error))
  end)

  test("the pair code comes from ccryptolib random bytes", function()
    local net, server = bootServer(16000000, true, function(srv)
      srv.env.math = setmetatable({ random = function() return 0 end }, { __index = srv.env.math })
    end)
    assert(server.alive(), tostring(server.error))
    server.env.os.queueEvent("key", 25, false)
    net.flush()
    assert(not server.error, tostring(server.error))
    local code = assert(logtext(server):match("Pair code: (%d%d%d%d%d%d)"), "pair code missing")
    local raw
    local nout = 0
    for i = 1, #server.randomLog do
      local entry = server.randomLog[i]
      if type(entry) == "string" and entry:sub(1, 7) == "random:" then
        nout = nout + 1
        if entry == "random:4" then raw = server.randomOut[nout] end
      end
    end
    assert(type(raw) == "string" and #raw == 4, "no random(4), log: " .. table.concat(server.randomLog, ","))
    local n = raw:byte(1) * 16777216 + raw:byte(2) * 65536 + raw:byte(3) * 256 + raw:byte(4)
    equal(code, string.format("%06d", n % 1000000))
  end)

  test("five bad pair MACs burn the code and join can pin the server id", function()
    local net, server = bootServer(16000000, true)
    assert(server.alive(), tostring(server.error))
    local code = pressP(net, server)
    equal(server.screen[1], "Pair code: " .. code .. " server " .. tostring(server.id))
    local attacker = bootClient(net, 6)
    attacker.spawn([[
      proto = dofile("so-proto.lua")
      BAD = proto.build("]] .. string.rep("ab", 32) .. [[", "pair", { pub = "]] .. string.rep("cd", 32) .. [[" })
      READY = true
    ]])
    net.flush()
    assert(attacker.env.READY == true, tostring(attacker.error))
    local function poke()
      attacker.env.rednet.send(server.id, attacker.env.BAD, "so")
      net.flush()
      assert(not server.error, tostring(server.error))
    end
    for _ = 1, 4 do poke() end
    assert(tostring(server.screen[1]):find(code, 1, true), "code burned early: " .. tostring(server.screen[1]))
    poke()
    equal(server.screen[1], "Press P to pair")
    local late = bootClient(net, 7)
    late.spawn(string.format(JOIN, code))
    net.advance(8)
    assert(late.env.JOINED ~= true, "burned code still paired")

    local fresh = pressP(net, server)
    equal(server.screen[1], "Pair code: " .. fresh .. " server " .. tostring(server.id))
    for _ = 1, 4 do poke() end
    assert(tostring(server.screen[1]):find(fresh, 1, true), "new code burned early")
    local pinned = bootClient(net, 8)
    pinned.spawn(string.format([[
      proto = dofile("so-proto.lua")
      store = dofile("so-store.lua")
      pair = dofile("so-pair.lua")
      pair.open(proto, store)
      rednet.lookup = function() return 99 end
      local trusted, trustedErr = pair.join(%q)
      LOOKUP = trusted
      LOOKUPERR = trustedErr
      local ok, err = pair.join(%q, %d)
      PINNED = ok
      PINERR = err
    ]], fresh, fresh, server.id))
    net.advance(8)
    assert(not pinned.error, tostring(pinned.error))
    assert(pinned.env.LOOKUP == nil, "lookup was trusted")
    assert(pinned.env.PINNED == true, tostring(pinned.env.PINERR))
    equal(savedKey(server, pinned.id), savedKey(pinned, server.id))
    local sentTo = {}
    for i = 1, #pinned.sent do sentTo[pinned.sent[i].id] = true end
    assert(sentTo[99] == true, "join(code) did not use lookup")
    assert(sentTo[server.id] == true, "join(code, serverId) did not pin")
    assert(server.alive(), tostring(server.error))
  end)
end
