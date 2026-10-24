local H = dofile("tests/so/harness.lua")

local SERVER = { "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-log.lua", "so-errors.lua",
  "so-mod-state.lua", "so-mod-display.lua", "so-mod-panel.lua", "so-ui.lua" }
local WORKER = { "worker.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" }
local LABEL = { "so-enroll-1 device\0", "so-enroll-2 server pending\0",
  "so-enroll-3 server approved\0", "so-enroll-4 server denied\0", "so-enroll-5 server notice\0" }
local OWNER = 2

local function read(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

local function libs(m)
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    m.files[path] = read(path)
  end
end

local function boot(on)
  local net = H.new()
  local s = net.machine({ id = 1, modem = true })
  s.install(SERVER)
  libs(s)
  s.files["so-server.cfg"] = H.encode({ pos = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 }, enroll = on })
  s.boot("so-server.lua")
  net.flush()
  assert(s.alive(), tostring(s.error))
  local so = s.env.SO
  for _, id in ipairs({ OWNER, 3 }) do assert(so.pair.remember(id, string.rep(string.format("%02x", id), 32))) end
  net.advance(1.05)
  local t = { net = net, s = s, so = so, proto = so.proto, C = so.pair.cpace,
    x = s.env.require("ccryptolib.x25519") }
  t.hex, t.unhex = t.proto.hex, t.proto.unhex
  t.key = function(token) return t.proto.sha256("so-enroll-key\0" .. token:gsub("^%d+%-", ""):gsub("%-", "")) end
  t.tag = function(token, n, ...) return t.proto.hmac(t.key(token), LABEL[n] .. t.C.lv(...)) end
  -- A device request as the protocol defines it, built outside so-pair.
  t.request = function(token, id, sk, kind)
    local pub = t.x.publicKey(sk)
    kind = kind or "turtle"
    return { pub = t.hex(pub), kind = kind, tag = t.hex(t.tag(token, 1, "1", tostring(id), pub, kind)) }, pub
  end
  t.open = function()
    assert(so.enroll.open(OWNER))
    return so.enroll.view(OWNER).token
  end
  return t
end

local function savedKey(m, id)
  local raw = m.files["so-keys"]
  local box = raw and m.env.textutils.unserialize(raw)
  return box and box.value and box.value.keys and box.value.keys[tostring(id)]
end

local function turtle(t, id, token)
  local w = t.net.machine({ id = id, modem = true, turtle = true, capacity = 1000000 })
  w.install(WORKER)
  libs(w)
  if token then w.files["so-enroll"] = H.encode({ token = token }) end
  w.env.read = function() return coroutine.yield() end
  w.boot("worker.lua")
  return w
end

local function screen(t, w, h)
  local d = t.so.mods.display
  local s = {}
  s.frame = function(id)
    d.handlers.hello({ from = id, body = { w = w, h = h, role = "display" } })
    local f
    d.handlers["view.get"]({ from = id }, function(_, body) f = body end)
    return f
  end
  s.button = function(id, name)
    for _, b in ipairs(s.frame(id).buttons) do
      if b.id == name or b.id:sub(1, #name + 1) == name .. ":" then return b end
    end
  end
  s.press = function(id, name)
    local b = assert(s.button(id, name), "button missing " .. name)
    d.handlers.input({ from = id, body = { id = b.id, x = b.x, y = b.y } })
  end
  s.text = function(id)
    local out = {}
    for y, row in ipairs(s.frame(id).rows) do out[y] = row.text end
    return out
  end
  return s
end

local function sweep(t, machines, needle)
  local function has(text) return type(text) == "string" and text:find(needle, 1, true) ~= nil end
  for _, m in ipairs(machines) do
    for _, line in ipairs(m.log) do assert(not has(line), "token printed on " .. m.id) end
    for path, bytes in pairs(m.files) do
      if path ~= "so-enroll" then assert(not has(bytes), "token saved in " .. path .. " on " .. m.id) end
    end
    for _, packet in ipairs(m.sent) do assert(not has(H.encode(packet.payload)), "token on the wire from " .. m.id) end
  end
  for _, e in ipairs(t.so.errors and t.so.errors.entries() or {}) do
    assert(not has(H.encode(e)), "token in SO.errors")
    assert(not H.encode(e):find("enroll", 1, true), "enroll line in SO.errors")
  end
end

return function(test, equal)
  test("enroll tokens use the 32-symbol alphabet, the server id and 80 random bits", function()
    local t = boot(true)
    local token = t.open()
    local id, rest = token:match("^(%d+)%-(%w%w%w%w%-%w%w%w%w%-%w%w%w%w%-%w%w%w%w)$")
    equal(id, "1")
    rest = rest:gsub("%-", "")
    assert(not rest:find("[01IO]"), token)
    equal(#rest, 16)
    local n, x = t.so.pair.enrollToken(" " .. token:lower():gsub("%-", "-  ") .. " ")
    equal(n, 1)
    equal(x, rest)
    equal(t.so.pair.enrollToken("1-K7QP-3MXA-9WTD-HR2"), nil)
    equal(t.so.pair.enrollToken("1-K7QP-3MXA-9WTD-HR20"), nil)
    equal(t.so.pair.enrollToken("K7QP-3MXA-9WTD-HR2E"), nil)
    -- 80 bits come from exactly ten random bytes.
    local sizes = {}
    for _, out in ipairs(t.s.randomOut) do sizes[#out] = (sizes[#out] or 0) + 1 end
    assert(sizes[10] == 1, "token needs one 10-byte draw")
    equal(t.so.enroll.view(3).token, nil, "only the owner sees the token")
    equal(t.so.enroll.open(3), nil)
  end)

  test("enroll tag1, tag2 and tag3 follow the transcript with distinct role labels", function()
    local t = boot(true)
    local token = t.open()
    local P = t.so.pair
    local sk = string.rep("\5", 32)
    local body, pub = t.request(token, 10, sk)
    local kind, reply = P.enrollAnswer(10, body)
    equal(kind, "ack")
    equal(reply.state, "pending")
    local xs = t.unhex(reply.pub)
    local k = t.x.exchange(sk, xs)
    local tr = { "1", "10", pub, "turtle", xs, k }
    equal(reply.tag, t.hex(t.tag(token, 2, table.unpack(tr))))
    -- Every tag differs, including the same transcript under another label.
    local seen = {}
    for n = 1, 4 do
      local tag = t.hex(t.tag(token, n, table.unpack(tr)))
      assert(not seen[tag], "labels collide")
      seen[tag] = true
    end
    -- A reflected tag2 is no tag1.
    local reflected = { pub = body.pub, kind = "turtle", tag = reply.tag }
    equal(select(2, P.enrollAnswer(11, reflected)).text, "token")
    -- The kind is in tag1, so a changed kind fails.
    local other = { pub = body.pub, kind = "pocket", tag = body.tag }
    equal(select(2, P.enrollAnswer(10, other)).text, "token")
    local row = t.so.enroll.view(OWNER).rows[1]
    equal(row.id, 10)
    equal(row.kind, "turtle")
    equal(row.fp, t.hex(t.proto.sha256(pub)):sub(1, 4):upper())
    assert(t.so.enroll.decide(10, row.n, true))
    kind, reply = P.enrollAnswer(10, body)
    equal(kind, "ack")
    equal(reply.state, "ok")
    equal(reply.tag, t.hex(t.tag(token, 3, table.unpack(tr))))
    local isk = t.C.sha512(t.C.lv("so-enroll isk", "1", "10", pub, xs, k))
    equal(P.key(10), P.machineKey(isk))
    assert(P.key(10) ~= t.hex(t.key(token)), "token used as a machine key")
    -- The approval also emits the existing pair notice.
    equal(t.so.mods.state.get("pair.done").id, 10)
  end)

  test("enroll refuses a mirrored share, a low-order share and a paired id", function()
    local t = boot(true)
    local token = t.open()
    local P = t.so.pair
    -- The server share as the device share: only a token holder can tag it.
    local _, first = P.enrollAnswer(10, (t.request(token, 10, string.rep("\6", 32))))
    local xs = t.unhex(first.pub)
    local mirrored = { pub = first.pub, kind = "turtle", tag = t.hex(t.tag(token, 1, "1", "11", xs, "turtle")) }
    equal(select(2, P.enrollAnswer(11, mirrored)).text, "share")
    local zero = string.rep("\0", 32)
    local low = { pub = t.hex(zero), kind = "turtle", tag = t.hex(t.tag(token, 1, "1", "12", zero, "turtle")) }
    equal(select(2, P.enrollAnswer(12, low)).text, "share")
    equal(select(2, P.enrollAnswer(3, (t.request(token, 3, string.rep("\7", 32))))).text, "paired")
    equal(#t.so.enroll.view(OWNER).rows, 1)
  end)

  test("enroll replays add no entry and spend no budget", function()
    local t = boot(true)
    local token = t.open()
    local P = t.so.pair
    local body = t.request(token, 10, string.rep("\5", 32))
    local _, first = P.enrollAnswer(10, body)
    for _ = 1, 12 do
      local kind, again = P.enrollAnswer(10, body)
      equal(kind, "ack")
      equal(again, first)
    end
    equal(#t.so.enroll.view(OWNER).rows, 1)
    equal(P.blocked(10), false)
    -- Any sender id can be forged, so a replay from 10 by someone else is
    -- the same answer and the same single row.
    local row = t.so.enroll.view(OWNER).rows[1]
    assert(t.so.enroll.decide(10, row.n, true))
    local saved = t.s.files["so-keys"]
    for _ = 1, 5 do equal(select(2, P.enrollAnswer(10, body)).state, "ok") end
    equal(t.s.files["so-keys"], saved)
  end)

  test("enroll charges the shared budget for new and wrong requests", function()
    local t = boot(true)
    local token = t.open()
    local P = t.so.pair
    local wrong = "1-AAAA-AAAA-AAAA-AAAA"
    local texts = {}
    for i = 1, 3 do texts[i] = select(2, P.enrollAnswer(20, (t.request(wrong, 20, string.rep("\9", 32))))).text end
    equal(texts, { "token", "token", "wait" })
    equal(select(2, P.enrollAnswer(20, (t.request(token, 20, string.rep("\9", 32))))).text, "wait")
    equal(P.blocked(20), true)
    equal(select(2, P.enrollAnswer(21, { pub = "x" })).text, "body")
    t.net.advance(61)
    equal(select(2, P.enrollAnswer(20, (t.request(token, 20, string.rep("\9", 32))))).state, "pending")
  end)

  test("enroll caps pending rows and joins at 20 and closes at the cap", function()
    local t = boot(true)
    local token = t.open()
    local P = t.so.pair
    for id = 100, 119 do
      equal(select(2, P.enrollAnswer(id, (t.request(token, id, string.rep(string.char(id), 32))))).state, "pending")
    end
    -- The window is full before the shared budget is asked.
    local _, full = P.enrollAnswer(120, (t.request(token, 120, string.rep("x", 32))))
    equal(full.text, "full")
    assert(full.tag and full.pub, "a full answer to a valid tag1 is tagged")
    -- All senders share 20 starts per minute.
    equal(select(2, P.enrollAnswer(122, (t.request("1-AAAA-AAAA-AAAA-AAAA", 122, string.rep("z", 32))))).text, "wait")
    local view = t.so.enroll.view(OWNER)
    equal(#view.rows, 20)
    for _, row in ipairs(view.rows) do assert(t.so.enroll.decide(row.id, row.n, true)) end
    equal(t.so.enroll.view(OWNER), nil, "the 20th join closes the window")
    equal(select(2, P.enrollAnswer(100, (t.request(token, 100, string.rep("d", 32))))).state, "ok")
    equal(select(2, P.enrollAnswer(121, (t.request(token, 121, string.rep("y", 32))))).text, "closed")
    t.net.advance(599)
    equal(select(2, P.enrollAnswer(100, (t.request(token, 100, string.rep("d", 32))))).state, "ok")
    t.net.advance(2)
    equal(select(2, P.enrollAnswer(100, (t.request(token, 100, string.rep("d", 32))))).text, "closed")
  end)

  test("enroll window expires after ten minutes and denial drops the row", function()
    local t = boot(true)
    local token = t.open()
    local P = t.so.pair
    local body = t.request(token, 10, string.rep("\5", 32))
    P.enrollAnswer(10, body)
    local row = t.so.enroll.view(OWNER).rows[1]
    assert(t.so.enroll.decide(10, row.n, false))
    equal(P.key(10), nil)
    local kind, reply = P.enrollAnswer(10, body)
    equal(kind, "err")
    equal(reply.text, "denied")
    local sk = string.rep("\5", 32)
    local xs = t.unhex(reply.pub)
    local tr = { "1", "10", t.x.publicKey(sk), "turtle", xs, t.x.exchange(sk, xs) }
    equal(reply.tag, t.hex(t.tag(token, 4, table.unpack(tr))))
    equal(#t.so.enroll.view(OWNER).rows, 0)
    equal(select(2, t.so.enroll.decide(10, row.n, true)), "gone")
    t.net.advance(599)
    assert(t.so.enroll.view(OWNER))
    t.net.advance(1.5)
    equal(t.so.enroll.view(OWNER), nil)
    equal(select(2, P.enrollAnswer(11, (t.request(token, 11, string.rep("\6", 32))))).text, "closed")
    local log = table.concat(t.s.log, "\n")
    assert(log:find("so-server: enroll window open", 1, true))
    assert(log:find("so-server: enroll denied 10", 1, true))
    assert(log:find("so-server: enroll window closed", 1, true))
  end)

  test("enroll three turtles on one token: approve two, deny one, no token leaks", function()
    local t = boot(true)
    local token = t.open()
    local ws = {}
    for i, id in ipairs({ 10, 11, 12 }) do ws[i] = turtle(t, id, token) end
    t.net.advance(4)
    local view = t.so.enroll.view(OWNER)
    equal(#view.rows, 3)
    for _, w in ipairs(ws) do
      assert(w.alive(), tostring(w.error))
      equal(savedKey(w, 1), nil)
      local saved = w.env.textutils.unserialize(w.files["so-enroll"])
      equal(saved.token, token)
      equal(#saved.sk, 64)
    end
    -- The turtle shows the fingerprint the panel shows.
    assert((ws[1].screen[2] or ""):find(view.rows[1].fp, 1, true), tostring(ws[1].screen[2]))
    assert(t.so.enroll.decide(10, view.rows[1].n, true))
    assert(t.so.enroll.decide(11, view.rows[2].n, true))
    assert(t.so.enroll.decide(12, view.rows[3].n, false))
    t.net.advance(8)
    for i = 1, 2 do
      local w = ws[i]
      assert(w.alive(), tostring(w.error))
      equal(savedKey(w, 1), t.so.pair.key(w.id))
      equal(w.files["so-enroll"], nil)
    end
    equal(savedKey(ws[3], 1), nil)
    equal(t.so.pair.key(12), nil)
    equal(ws[3].files["so-enroll"], nil)
    -- Approved turtles finish booting and talk under the new key.
    t.net.advance(5)
    local log = table.concat(t.s.log, "\n")
    assert(not log:find("bad mac from 10", 1, true), log)
    assert(not log:find("bad mac from 11", 1, true), log)
    local hellos = 0
    for _, packet in ipairs(ws[1].sent) do
      if type(packet.payload) == "table" and packet.payload.t == "hello" then
        hellos = hellos + 1
        assert(t.proto.macOk(t.so.pair.key(10), packet.payload))
      end
    end
    assert(hellos > 0, "approved turtle sent no hello")
    equal(ws[1].lookups, nil)
    -- The device sends straight to the token's server: no hostname lookup
    -- before it is enrolled.
    local first
    for _, packet in ipairs(ws[3].sent) do
      if packet.id == nil then first = first or "broadcast" end
      if type(packet.payload) == "table" and packet.payload.t == "enroll" then first = first or packet.id end
    end
    equal(first, 1)
    local x = token:gsub("^%d+%-", ""):gsub("%-", "")
    sweep(t, { t.s, ws[1], ws[2], ws[3] }, x)
    sweep(t, { t.s, ws[1], ws[2], ws[3] }, token)
  end)

  test("enroll survives a turtle reboot while pending", function()
    local t = boot(true)
    local token = t.open()
    local w = turtle(t, 10, token)
    t.net.advance(4)
    local fp = t.so.enroll.view(OWNER).rows[1].fp
    t.net.kill(w)
    t.net.advance(10)
    w = t.net.boot(w)
    t.net.advance(4)
    local view = t.so.enroll.view(OWNER)
    equal(#view.rows, 1)
    equal(view.rows[1].fp, fp)
    assert(t.so.enroll.decide(10, view.rows[1].n, true))
    t.net.advance(7)
    equal(savedKey(w, 1), t.so.pair.key(10))
    equal(w.files["so-enroll"], nil)
  end)

  test("enroll: a host without the token gets nothing saved", function()
    local net = H.new()
    -- The rogue answers as computer 1 with its own share and made-up tags.
    local rogue = net.machine({ id = 1, modem = true })
    rogue.install({ "so-proto.lua", "so-pair.lua", "so-store.lua" })
    libs(rogue)
    rogue.spawn([[
      local proto, store, pair = dofile("so-proto.lua"), dofile("so-store.lua"), dofile("so-pair.lua")
      pair.open(proto, store)
      local x = require("ccryptolib.x25519")
      local pub, n = proto.hex(x.publicKey(string.rep("r", 32))), 0
      while true do
        local _, from, payload = os.pullEvent("rednet_message")
        local msg = proto.decode(payload)
        if msg and msg.t == "enroll" then
          n = n + 1
          local states = { { "ack", { state = "pending" } }, { "ack", { state = "ok" } },
            { "err", { code = "enroll", text = "denied" } } }
          local pick = states[n % 3 + 1]
          pick[2].pub, pick[2].tag = pub, string.rep("ab", 32)
          rednet.send(from, proto.encode(proto.build(pair.envelopeKey(), pick[1], pick[2], msg.rid)), "so")
        end
      end
    ]])
    local w = net.machine({ id = 10, modem = true, turtle = true, capacity = 1000000 })
    w.install(WORKER)
    libs(w)
    w.files["so-enroll"] = H.encode({ token = "1-K7QP-3MXA-9WTD-HR2E" })
    w.env.read = function() return coroutine.yield() end
    w.boot("worker.lua")
    net.advance(60)
    assert(w.alive(), tostring(w.error))
    assert(not rogue.error, tostring(rogue.error))
    equal(savedKey(w, 1), nil)
    assert(w.files["so-enroll"], "a forged reply ended the attempt")
    net.advance(620)
    equal(savedKey(w, 1), nil)
    equal(w.files["so-enroll"], nil)
  end)

  test("enroll: a second token holder answering stops the attempt", function()
    local t = boot(true)
    local token = t.open()
    local w = turtle(t, 10, token)
    t.net.advance(4)
    local saved = w.env.textutils.unserialize(w.files["so-enroll"])
    local sk = t.unhex(saved.sk)
    local pub = t.x.publicKey(sk)
    local fake = string.rep("f", 32)
    local fx = t.x.publicKey(fake)
    local function forged(state, rid, xs, scalar)
      local k = t.x.exchange(scalar, pub)
      local n = state == "pending" and 2 or 3
      local body = { state = state, pub = t.hex(xs), tag = t.hex(t.tag(token, n, "1", "10", pub, "turtle", xs, k)) }
      return t.proto.encode(t.proto.build(t.so.pair.envelopeKey(), "ack", body, rid))
    end
    -- A mirrored share with a valid tag is ignored, not locked.
    local send = w.env.rednet.send
    local mode = "mirror"
    w.env.rednet.send = function(id, payload, protocol)
      send(id, payload, protocol)
      if type(payload) == "table" and payload.t == "enroll" and mode then
        local wire = mode == "mirror" and forged("ok", payload.rid, pub, sk) or forged("ok", payload.rid, fx, fake)
        w.inbox[#w.inbox + 1] = table.pack("rednet_message", 1, wire, "so")
      end
    end
    t.net.advance(6)
    equal(savedKey(w, 1), nil)
    assert(w.files["so-enroll"])
    mode = "other"
    t.net.advance(7)
    equal(savedKey(w, 1), nil)
    equal(w.files["so-enroll"], nil)
    assert(table.concat(w.screen, "\n"):find("conflict", 1, true), table.concat(w.screen, "\n"))
    -- Approving afterwards leaves the turtle unpaired; it never took the forged key.
    local row = t.so.enroll.view(OWNER).rows[1]
    assert(t.so.enroll.decide(10, row.n, true))
    t.net.advance(4)
    equal(savedKey(w, 1), nil)
  end)

  test("enroll: an expired window and a denial delete the turtle's token file", function()
    local t = boot(true)
    local token = t.open()
    local a, b = turtle(t, 10, token), turtle(t, 11, token)
    t.net.advance(4)
    local rows = t.so.enroll.view(OWNER).rows
    assert(t.so.enroll.decide(11, rows[2].n, false))
    t.net.advance(7)
    equal(b.files["so-enroll"], nil)
    assert(table.concat(b.screen, "\n"):find("denied", 1, true))
    t.net.advance(600)
    equal(a.files["so-enroll"], nil)
    equal(savedKey(a, 1), nil)
    assert(table.concat(a.screen, "\n"):find("closed", 1, true))
  end)

  test("enroll flag off: no page, no handler, no reply", function()
    local t = boot(nil)
    equal(t.so.enroll, nil)
    local s = screen(t, 26, 20)
    s.frame(OWNER)
    s.press(OWNER, "panel")
    s.press(OWNER, "pair")
    equal(s.button(OWNER, "enroll"), nil)
    assert(s.button(OWNER, "paired").w == 26)
    t.so.mods.display.handlers.input({ from = OWNER, body = { id = "enroll", x = 14, y = 16 } })
    equal(s.button(OWNER, "enroll-close"), nil)
    local w = turtle(t, 10, "1-K7QP-3MXA-9WTD-HR2E")
    t.net.advance(10)
    local answered = false
    for _, packet in ipairs(t.s.sent) do if packet.id == 10 then answered = true end end
    equal(answered, false)
    assert(table.concat(t.s.log, "\n"):find("bad mac from 10", 1, true))
    t.net.advance(660)
    equal(w.files["so-enroll"], nil)
    equal(savedKey(w, 1), nil)
    assert(w.alive(), tostring(w.error))
  end)

  test("enroll panel uses drawn buttons and fits 26x20 and 29x12", function()
    for _, size in ipairs({ { 26, 20 }, { 29, 12 } }) do
      local w, h = size[1], size[2]
      local t = boot(true)
      local s = screen(t, w, h)
      s.frame(OWNER)
      s.press(OWNER, "panel")
      s.press(OWNER, "pair")
      s.frame(3)
      s.press(3, "panel")
      s.press(3, "pair")
      s.press(OWNER, "enroll")
      local token = t.so.enroll.view(OWNER).token
      assert(token, "ENROLL did not open a window")
      -- Another display cannot open or act on the owner's window.
      equal(s.button(3, "enroll"), nil)
      t.so.mods.display.handlers.input({ from = 3, body = { id = "enroll-close", x = 1, y = h } })
      assert(t.so.enroll.view(OWNER))
      for _, id in ipairs({ 10, 11, 12 }) do
        t.so.pair.enrollAnswer(id, (t.request(token, id, string.rep(string.char(id), 32))))
      end
      local f = s.frame(OWNER)
      local fps = {}
      for _, row in ipairs(t.so.enroll.view(OWNER).rows) do fps[row.fp] = true end
      for _, b in ipairs(f.buttons) do
        assert(b.x >= 1 and b.y >= 1 and b.x + b.w - 1 <= w and b.y + (b.h or 1) - 1 <= h, b.id)
      end
      -- Only page words, ids, kinds, fingerprints, the timer and the token.
      local text = table.concat(s.text(OWNER), "\n")
      local flat = text:gsub("[\128-\255]", "")
      assert(flat:find(token, 1, true) or flat:find(token:match("^%d+%-%w+%-%w+"), 1, true), flat)
      for word in flat:gmatch("[^%s]+") do
        local ok = ({ ENROLL = true, APPROVE = true, ALL = true, CLOSE = true, OK = true, NO = true, TURTLE = true })[word]
          or word:match("^#%d+$") or fps[word] or word:match("^%d+:%d%d$") or token:find(word, 1, true)
        assert(ok, "unexpected text " .. word .. " at " .. w .. "x" .. h)
      end
      assert(s.button(OWNER, "enroll-ok:12"), "third row missing at " .. w .. "x" .. h)
      s.press(OWNER, "enroll-ok:10")
      s.press(OWNER, "enroll-no:11")
      assert(t.so.pair.key(10))
      equal(t.so.pair.key(11), nil)
      -- A stale OK for an old row id does nothing.
      t.so.mods.display.handlers.input({ from = OWNER, body = { id = "enroll-ok:11:1", x = w - 8, y = 1 } })
      equal(t.so.pair.key(11), nil)
      s.press(OWNER, "enroll-all")
      assert(t.so.pair.key(12))
      equal(t.so.enroll.view(OWNER).joined, 2)
      s.press(OWNER, "enroll-close")
      equal(t.so.enroll.view(OWNER), nil)
      assert(s.button(OWNER, "enroll"), "PAIR page not restored")
    end
  end)

  test("enroll APPROVE ALL approves only rows the owner was shown", function()
    local t = boot(true)
    local s = screen(t, 26, 20)
    s.frame(OWNER)
    s.press(OWNER, "panel")
    s.press(OWNER, "pair")
    s.press(OWNER, "enroll")
    local token = t.so.enroll.view(OWNER).token
    t.so.pair.enrollAnswer(10, (t.request(token, 10, string.rep("\10", 32))))
    local b = s.button(OWNER, "enroll-all")
    t.so.pair.enrollAnswer(11, (t.request(token, 11, string.rep("\11", 32))))
    t.so.mods.display.handlers.input({ from = OWNER, body = { id = b.id, x = b.x, y = b.y } })
    assert(t.so.pair.key(10))
    equal(t.so.pair.key(11), nil)
    equal(#t.so.enroll.view(OWNER).rows, 1)
    -- Rows below the bottom of a 29x12 screen are not approved.
    local small = screen(t, 29, 12)
    for id = 20, 25 do t.so.pair.enrollAnswer(id, (t.request(token, id, string.rep(string.char(id), 32)))) end
    t.net.advance(61)
    small.press(OWNER, "enroll-all")
    equal(t.so.enroll.view(OWNER).joined, 5)
    equal(#t.so.enroll.view(OWNER).rows, 3)
  end)

  test("enroll installer takes the token as an argument and writes so-enroll", function()
    local source = read("install.lua")
    local prepare = source:match("^(.-)local function main")
    local fn = assert(load(prepare .. "return enrollToken", "@install.lua", "t", setmetatable({}, { __index = _G })))
    local enrollToken = fn()
    equal(enrollToken("12-k7qp-3mxa-9wtd-hr2e"), "12-K7QP-3MXA-9WTD-HR2E")
    equal(enrollToken("12-K7QP3MXA9WTDHR2E"), "12-K7QP-3MXA-9WTD-HR2E")
    equal(enrollToken("12-K7QP-3MXA-9WTD-HR2O"), nil)
    equal(enrollToken("update"), nil)
    -- A fresh turtle install hands the token to the pinned installer, which
    -- writes so-enroll after the swap and never prints the token.
    local H2 = H.new()
    local m = H2.machine({ id = 9, capacity = 1000000 })
    local e, written = m.env, {}
    e.turtle = {}
    e.fs = { exists = function() return false end, delete = function() end, makeDir = function() end,
      getDir = function(p) return p:match("^(.*)/[^/]*$") or "" end,
      open = function(path)
        written[path] = ""
        return { write = function(s) written[path] = written[path] .. s end, close = function() end }
      end }
    local main = assert(load(source, "@install.lua", "t", e))("prepare")
    e.http = { get = function() error("network used") end }
    local ok = pcall(main, "12-K7QP-3MXA-9WTD-HR2E")
    equal(ok, true)
    -- The revision lookup failed, so nothing was installed or written.
    equal(written["/so-enroll"], nil)
    local log = table.concat(m.log, "\n")
    assert(not log:find("K7QP", 1, true), log)
    -- The pinned installer side: install succeeds, then so-enroll appears.
    local inner = source:gsub("if not install%(role, config, handoff%) then return end", "")
    e.shell = { run = function() return true end }
    main = assert(load(inner, "@install.lua", "t", e))("prepare")
    main(nil, { revision = string.rep("a", 40), previous = {}, role = "worker", enroll = "12-k7qp-3mxa-9wtd-hr2e" })
    local handed = e.textutils.unserialize(written["/so-enroll"])
    equal(handed.token, "12-K7QP-3MXA-9WTD-HR2E")
    log = table.concat(m.log, "\n")
    assert(not log:find("K7QP", 1, true), log)
    assert(log:find("server 12", 1, true), log)
    e.turtle, e.pocket = nil, {}
    local refused, err = pcall(main, nil, { revision = string.rep("a", 40), previous = {}, role = "display",
      enroll = "12-K7QP-3MXA-9WTD-HR2E" })
    equal(refused, false)
    assert(tostring(err):find("turtles", 1, true), tostring(err))
  end)

  test("enroll answers every valid tag1 with a tagged notice", function()
    local t = boot(true)
    local token = t.open()
    local P = t.so.pair
    local function notice(id, sk, text)
      local body, pub = t.request(token, id, sk)
      local kind, reply = P.enrollAnswer(id, body)
      equal(kind, "err")
      equal(reply.text, text)
      local xs = t.unhex(reply.pub)
      equal(reply.tag, t.hex(t.tag(token, 5, "1", tostring(id), pub, "turtle", xs, text)))
    end
    notice(3, string.rep("\3", 32), "paired")
    -- Budget used up by forged wrong guesses still gets a tagged wait.
    for _ = 1, 2 do P.enrollAnswer(10, (t.request("1-AAAA-AAAA-AAAA-AAAA", 10, string.rep("\1", 32)))) end
    notice(10, string.rep("\5", 32), "wait")
    -- A second request for a pending id removes the row: neither joins.
    P.enrollAnswer(11, (t.request(token, 11, string.rep("\6", 32))))
    equal(#t.so.enroll.view(OWNER).rows, 1)
    equal(select(3, P.enrollAnswer(11, (t.request(token, 11, string.rep("\7", 32))))), "contested")
    equal(#t.so.enroll.view(OWNER).rows, 0)
    notice(11, string.rep("\7", 32), "busy")
    notice(11, string.rep("\6", 32), "busy")
  end)

  test("enroll keeps an approval for a turtle that asks again minutes later", function()
    local t = boot(true)
    local token = t.open()
    local P = t.so.pair
    local body = t.request(token, 10, string.rep("\5", 32))
    P.enrollAnswer(10, body)
    assert(t.so.enroll.decide(10, t.so.enroll.view(OWNER).rows[1].n, true))
    t.net.advance(300)
    equal(select(2, P.enrollAnswer(10, body)).state, "ok")
  end)

  test("enroll: a turtle denied in one window can join the next", function()
    local t = boot(true)
    local token = t.open()
    local P = t.so.pair
    P.enrollAnswer(10, (t.request(token, 10, string.rep("\5", 32))))
    assert(t.so.enroll.decide(10, t.so.enroll.view(OWNER).rows[1].n, false))
    t.so.enroll.close()
    local second = t.open()
    assert(second ~= token)
    equal(select(2, P.enrollAnswer(10, (t.request(second, 10, string.rep("\8", 32))))).state, "pending")
  end)

  -- A token holder forges an ok under its own share on every request the
  -- turtle sends, after first blocking the real answer in one of two ways.
  local function takeover(block)
    local t = boot(true)
    local token = t.open()
    local P = t.so.pair
    local fake = string.rep("f", 32)
    local fx = t.x.publicKey(fake)
    block(t, token, P)
    local w = t.net.machine({ id = 10, modem = true, turtle = true, capacity = 1000000 })
    w.install(WORKER)
    libs(w)
    w.files["so-enroll"] = H.encode({ token = token })
    w.env.read = function() return coroutine.yield() end
    local send = w.env.rednet.send
    w.env.rednet.send = function(id, payload, protocol)
      send(id, payload, protocol)
      if type(payload) == "table" and payload.t == "enroll" then
        local pub = t.unhex(payload.body.pub)
        local k = t.x.exchange(fake, pub)
        local body = { state = "ok", pub = t.hex(fx), tag = t.hex(t.tag(token, 3, "1", "10", pub, "turtle", fx, k)) }
        w.inbox[#w.inbox + 1] = table.pack("rednet_message", 1,
          t.proto.encode(t.proto.build(P.envelopeKey(), "ack", body, payload.rid)), "so")
      end
    end
    w.boot("worker.lua")
    t.net.advance(8)
    assert(w.alive(), tostring(w.error))
    equal(savedKey(w, 1), nil, "turtle took the forged key")
    equal(w.files["so-enroll"], nil)
    equal(P.key(10), nil)
    return t, w
  end

  test("enroll: a token holder squatting the turtle's id cannot take it over", function()
    local _, w = takeover(function(t, token, P)
      P.enrollAnswer(10, (t.request(token, 10, string.rep("q", 32))))
    end)
    assert(table.concat(w.screen, "\n"):find("Enroll: ", 1, true))
  end)

  test("enroll: a turtle kept on wait by forged guesses cannot be taken over", function()
    takeover(function(t, _, P)
      for _ = 1, 2 do P.enrollAnswer(10, (t.request("1-AAAA-AAAA-AAAA-AAAA", 10, string.rep("\1", 32)))) end
    end)
  end)

  test("enroll: a flood of forged replies costs at most four exchanges a round", function()
    local t = boot(true)
    local token = t.open()
    local w = turtle(t, 10, token)
    t.net.advance(4)
    local x = assert(w.env.package.loaded["ccryptolib.x25519"])
    local exchange, calls = x.exchange, 0
    x.exchange = function(...) calls = calls + 1 return exchange(...) end
    local send = w.env.rednet.send
    w.env.rednet.send = function(id, payload, protocol)
      send(id, payload, protocol)
      if type(payload) == "table" and payload.t == "enroll" then
        for i = 1, 40 do
          local body = { state = "ok", pub = t.hex(t.x.publicKey(string.rep(string.char(i), 32))), tag = string.rep("cd", 32) }
          w.inbox[#w.inbox + 1] = table.pack("rednet_message", 1,
            t.proto.encode(t.proto.build(t.so.pair.envelopeKey(), "ack", body, payload.rid)), "so")
        end
      end
    end
    t.net.advance(3)
    assert(w.alive(), tostring(w.error))
    assert(calls <= 4, "exchanges in one round: " .. calls)
    equal(savedKey(w, 1), nil)
  end)
end
