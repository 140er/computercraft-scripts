local H = dofile("tests/so/harness.lua")
local R = dofile("tests/ui/render.lua")
local FILES = { "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-log.lua",
  "so-mod-state.lua", "so-mod-display.lua", "so-mod-health.lua", "so-ui.lua" }

local function libs(m)
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path, "rb"))
    m.files[path] = f:read("*a")
    f:close()
  end
end

local function boot(setup)
  local net = H.new()
  local m = net.machine({ id = 1, modem = true })
  m.install(FILES)
  libs(m)
  m.files["so-server.cfg"] = H.encode({ enroll = true })
  if setup then setup(m) end
  m.boot("so-server.lua")
  net.flush()
  assert(m.alive(), tostring(m.error))
  return net, m, m.env.SO
end

local function packet(so, key, t, from, body)
  local msg = so.proto.build(key, t, body or {})
  msg.from = from
  msg.mac = so.proto.sign(key, msg)
  return assert(so.proto.encode(msg))
end

local function deliver(net, m, from, wire)
  m.env.os.queueEvent("rednet_message", from, wire, "so")
  net.flush()
  assert(m.alive(), tostring(m.error))
end

local function last(m, so, from)
  for i = #m.sent, 1, -1 do
    if m.sent[i].id == from then return assert(so.proto.decode(m.sent[i].payload)), m.sent[i].payload end
  end
  error("missing reply")
end

local function attention(so, net)
  net.advance(5.05)
  so.mods.health.tick(so.now())
  for i = 1, 40 do
    local name, value = debug.getupvalue(so.mods.health.tick, i)
    if name == "H" then return value.items end
  end
  error("missing health state")
end

return function(test, equal)
  for _, builtin in ipairs({ false, true }) do
    test("server caches a handler error for " .. (builtin and "an unpaired pair2 request" or "a module request"), function()
      local net, m, so = boot()
      local calls, kind, key = 0, "broken", string.rep("ab", 32)
      local function fail()
        calls = calls + 1
        error("handler secret detail")
      end
      if builtin then
        so.pair.start = fail
        kind, key = "pair2", so.pair.envelopeKey()
      else
        assert(so.pair.remember(2, key))
        so.mods.state.handlers[kind] = fail
      end
      local wire = packet(so, key, kind, 2)
      deliver(net, m, 2, wire)
      local reply, original = last(m, so, 2)
      equal(reply.t, "err")
      equal(reply.body, { code = "handler" })
      equal(reply.rid, wire.rid)
      assert(so.proto.macOk(key, reply))
      deliver(net, m, 2, wire)
      local retry, cached = last(m, so, 2)
      equal(calls, 1)
      equal(cached, original)
      equal(retry, reply)
    end)
  end

  test("server keeps the first cached reply if a handler throws after replying", function()
    local net, m, so = boot()
    local key, calls = string.rep("ab", 32), 0
    assert(so.pair.remember(2, key))
    so.mods.state.handlers.broken = function(_, reply)
      calls = calls + 1
      reply("ack", { ok = true })
      error("after reply")
    end
    local wire = packet(so, key, "broken", 2)
    deliver(net, m, 2, wire)
    equal(last(m, so, 2).t, "ack")
    local count = #m.sent
    deliver(net, m, 2, wire)
    equal(last(m, so, 2).t, "ack")
    equal(#m.sent, count + 1)
    equal(calls, 1)
  end)

  test("server pair2 emits pair.done and the next pairing clears the durable forgotten row", function()
    for _, id in ipairs({ 2, 3 }) do
      local net, m, so = boot()
      assert(so.pair.remember(2, string.rep("ab", 32)))
      assert(so.forgetDevice(2, 1))
      equal(so.mods.state.get("pair.forgotten").id, 2)
      local found = false
      for _, row in ipairs(attention(so, net)) do if row.key == "forgotten" then found = true end end
      assert(found, "forgotten row missing before pairing")
      m.env.os.queueEvent("key", 25, false)
      net.flush()
      local code = assert(so.pair.pending())
      local c = net.machine({ id = id, modem = true, capacity = 1000000 })
      c.install({ "so-proto.lua", "so-pair.lua", "so-store.lua" })
      libs(c)
      c.spawn(string.format([[
        pair = dofile("so-pair.lua")
        pair.open(dofile("so-proto.lua"), dofile("so-store.lua"))
        JOINED, WHY = pair.join(%q, 1)
      ]], code))
      net.flush()
      assert(not c.error, tostring(c.error))
      equal(c.env.JOINED, true)
      equal(so.mods.state.get("pair.done").id, id)
      equal(so.mods.state.get("pair.forgotten"), nil)
      for _, row in ipairs(attention(so, net)) do assert(row.key ~= "forgotten") end
      local restarted = assert(loadfile("so-mod-state.lua", "t", m.env))()
      equal(restarted.get("pair.done").id, id)
      equal(restarted.get("pair.forgotten"), nil)
    end
  end)

  test("server enroll approval emits pair.done and clears forget only after a successful save", function()
    local net, m, so = boot()
    assert(so.pair.remember(2, string.rep("ab", 32)))
    assert(so.forgetDevice(2, 1))
    assert(so.pair.remember(4, string.rep("cd", 32)))
    assert(so.enroll.open(4))
    local token = so.enroll.view(4).token
    local proto, C = so.proto, so.pair.cpace
    local pub = m.env.require("ccryptolib.x25519").publicKey(string.rep("\5", 32))
    local key = proto.sha256("so-enroll-key\0" .. token:gsub("^%d+%-", ""):gsub("%-", ""))
    local tag = proto.hmac(key, "so-enroll-1 device\0" .. C.lv("1", "2", pub, "turtle"))
    equal(so.pair.enrollAnswer(2, { pub = proto.hex(pub), kind = "turtle", tag = proto.hex(tag) }), "ack")
    local row = so.enroll.view(4).rows[1]
    local state
    for i = 1, 40 do
      local name, value = debug.getupvalue(so.pair.key, i)
      if name == "S" then state = value break end
    end
    assert(state)
    local save = state.box.save
    state.box.save = function() return false, "disk" end
    equal(so.enroll.decide(2, row.n, true), nil)
    equal(so.mods.state.get("pair.done"), nil)
    equal(so.mods.state.get("pair.forgotten").id, 2)
    state.box.save = save
    assert(so.enroll.decide(2, row.n, true))
    equal(so.mods.state.get("pair.done").id, 2)
    equal(so.mods.state.get("pair.forgotten"), nil)
    for _, item in ipairs(attention(so, net)) do assert(item.key ~= "forgotten") end
  end)

  for _, blit in ipairs({ false, true }) do
    test("server shows entropy failure and throttles retries on " .. (blit and "a colour screen" or "a text screen"), function()
      local screen
      local net, m, so = boot(function(machine)
        machine.timingError = true
        if blit then screen = R.capture(51, 19); machine.env.term = screen end
      end)
      local function attempts()
        local count = 0
        for _, call in ipairs(m.randomLog) do if call == "initWithTiming" then count = count + 1 end end
        return count
      end
      local function text()
        if screen then return table.concat(screen.picture().text, "\n") end
        local rows = {}
        for y = 1, 19 do rows[y] = m.screen[y] or "" end
        return table.concat(rows, "\n")
      end
      equal(attempts(), 3)
      assert(so.pair.remember(2, string.rep("ab", 32)))
      local result
      so.mods.state.handlers["test.code"] = function(_, reply)
        result = so.pairCode(2)
        reply("ack", {})
      end
      local function requestCode()
        result = nil
        deliver(net, m, 2, packet(so, so.pair.key(2), "test.code", 2))
        return result
      end
      for _ = 1, 10 do equal(requestCode(), nil) end
      m.env.os.queueEvent("key", 25, false)
      net.flush()
      net.advance(1.05)
      assert(text():find("random source unavailable", 1, true), text())
      equal(so.pair.pending(), nil)
      equal(so.terminal.expires <= so.now(), true)
      equal(attempts(), 3)
      -- UTC changes cannot shorten the game-time cooldown.
      local epoch = m.env.os.epoch
      m.env.os.epoch = function() return epoch("utc") + 3600000 end
      equal(so.pairCode(2), nil)
      equal(attempts(), 3)
      m.env.os.epoch = epoch
      net.advance(27.9)
      equal(requestCode(), nil)
      equal(attempts(), 3)
      net.advance(1.1)
      equal(requestCode(), nil)
      equal(attempts(), 6)
      m.timingError = nil
      net.advance(30.1)
      local code = assert(requestCode())
      equal(attempts(), 7)
      assert(code.code:match("^%d%d%d%d%d%d$"))
      equal(so.terminal.codeError, nil)
      equal(so.terminal.code, code.code)
      equal(requestCode(), code)
      equal(attempts(), 7)
    end)
  end
end
