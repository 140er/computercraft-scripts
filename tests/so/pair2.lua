local H = dofile("tests/so/harness.lua")

local V1 = {
  ["so-pair.lua"] = "tests/so/fixtures/pair-v1/so-pair.lua",
  ["so-proto.lua"] = "tests/so/fixtures/pair-v1/so-proto.lua",
  ["so-server.lua"] = "tests/so/fixtures/pair-v1/so-server.lua",
}
local SERVER = { "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-log.lua",
  "so-mod-state.lua", "so-mod-cells.lua", "so-mod-display.lua", "so-mod-drops.lua" }
local CLIENT = { "so-proto.lua", "so-pair.lua", "so-store.lua" }
local JOIN = [[
proto = dofile("so-proto.lua")
store = dofile("so-store.lua")
pair = dofile("so-pair.lua")
pair.open(proto, store)
RESULTS = {}
for i = 1, %d do
  local ok, err = pair.join(%q, %s)
  RESULTS[i] = ok and "ok" or tostring(err)
end
DONE = true
]]

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

local function v1(m, names)
  for _, name in ipairs(names) do m.files[name] = read(V1[name]) end
end

local function logtext(m) return table.concat(m.log, "\n") end

local function boot(old, kit, extra, setup)
  local net = H.new()
  local server = net.machine({ id = 1, modem = true })
  server.install(SERVER)
  if kit then server.install({ "so-ui.lua" }) end
  if extra then server.install(extra) end
  libs(server)
  if old then v1(server, { "so-server.lua", "so-pair.lua", "so-proto.lua" }) end
  if setup then setup(server) end
  server.boot("so-server.lua")
  net.flush()
  assert(server.alive(), tostring(server.error))
  return net, server
end

local function pressP(net, server)
  server.env.os.queueEvent("key", 25, false)
  net.flush()
  local code
  for found in logtext(server):gmatch("Pair code: (%d%d%d%d%d%d)") do code = found end
  assert(code, "pair code missing")
  return code
end

local function client(net, id, old)
  local m = net.machine({ id = id, modem = true, capacity = 1000000 })
  m.install(CLIENT)
  libs(m)
  if old then v1(m, { "so-pair.lua" }) end
  return m
end

local function join(net, m, code, times, server, wait)
  m.spawn(string.format(JOIN, times or 1, code, server and tostring(server) or "nil"))
  net.flush()
  if wait then net.advance(wait) end
  assert(not m.error, tostring(m.error))
  assert(m.env.DONE == true, "join did not finish")
  return m.env.RESULTS
end

local function types(m)
  local out = {}
  for i = 1, #m.sent do
    local p = m.sent[i].payload
    if type(p) == "table" then out[p.t] = (out[p.t] or 0) + 1 end
  end
  return out
end

local function savedKey(m, id)
  local raw = m.files["so-keys"]
  local box = raw and m.env.textutils.unserialize(raw)
  return box and box.value and box.value.keys and box.value.keys[tostring(id)]
end

local function wrong(code, n)
  return string.format("%06d", (tonumber(code) + n) % 1000000)
end

local function entropy(m, failures, silent)
  local calls = { attempts = 0, yields = 0, seeds = 0, mixes = 0 }
  local dofile, queue = m.env.dofile, m.env.os.queueEvent
  m.env.dofile = function(path)
    local value = dofile(path)
    if path == "lib/ccryptolib/random.lua" then
      local timing, mix = value.initWithTiming, value.mix
      value.initWithTiming = function()
        calls.attempts = calls.attempts + 1
        if calls.attempts <= failures then
          if silent then return end
          error("timing health check failed")
        end
        return timing()
      end
      value.init = function() calls.seeds = calls.seeds + 1 error("fallback seed used") end
      value.mix = function(data) calls.mixes = calls.mixes + 1 return mix(data) end
    end
    return value
  end
  m.env.os.queueEvent = function(name, ...)
    if name == "so-pair-random" then calls.yields = calls.yields + 1 end
    return queue(name, ...)
  end
  m.env.sleep = function() error("entropy initialization called sleep") end
  m.env.ENTROPY = calls
  return calls
end

return function(test, equal)
  test("pair2 atomic replacement keeps only the proven peer on same-id and different-id repair", function()
    for _, previous in ipairs({ 0, 1 }) do
      local net, server = boot()
      local c = client(net, 2)
      c.files["so-keys"] = H.encode({ schema = 1, generation = 1,
        value = { keys = { [tostring(previous)] = string.rep("a", 64), ["9"] = string.rep("b", 64) } } })
      local code = pressP(net, server)
      c.spawn(string.format([[
        local p = dofile("so-pair.lua")
        p.open(dofile("so-proto.lua"), dofile("so-store.lua"))
        OK, WHY = p.join(%q, 1, { replace = %d })
        PEER, KEYS = p.peer(), p.list()
      ]], code, previous))
      net.flush()
      equal(c.env.OK, true, tostring(c.env.WHY))
      equal(c.env.PEER, 1)
      equal(#c.env.KEYS, 1)
      equal(savedKey(c, 1), savedKey(server, 2))
      equal(savedKey(c, 9), nil)
      if previous ~= 1 then equal(savedKey(c, previous), nil) end
    end
  end)

  test("pair2 a key save failure keeps the old keys in memory and across reopen", function()
    for _, failure in ipairs({ "open", "verify", "rename" }) do
      local net, server = boot()
      local c = client(net, 2)
      local old = string.rep("a", 64)
      c.files["so-keys"] = H.encode({ schema = 1, generation = 1,
        value = { keys = { ["0"] = old, ["9"] = old } } })
      local code = pressP(net, server)
      c.env.FAILURE = failure
      c.spawn(string.format([[
        local p, proto, store = dofile("so-pair.lua"), dofile("so-proto.lua"), dofile("so-store.lua")
        p.open(proto, store)
        local open, move = fs.open, fs.move
        fs.open = function(path, mode)
          if path == "so-keys.tmp" and FAILURE == "open" and mode == "w" then return nil end
          if path == "so-keys.tmp" and FAILURE == "verify" and mode == "r" then
            return { readAll = function() return "bad" end, close = function() end }
          end
          return open(path, mode)
        end
        fs.move = function(from, to)
          if from == "so-keys.tmp" and to == "so-keys" and FAILURE == "rename" then error("rename failed") end
          return move(from, to)
        end
        OK, WHY = p.join(%q, 1, { replace = 0 })
        KEYS, PEER, NEW = p.list(), p.peer(), p.key(1)
        fs.open, fs.move = open, move
        local reboot = dofile("so-pair.lua")
        reboot.open(proto, store)
        REBOOT_KEYS, REBOOT_PEER, REBOOT_NEW = reboot.list(), reboot.peer(), reboot.key(1)
      ]], code))
      net.flush()
      assert(not c.error, tostring(c.error))
      equal(c.env.OK, nil)
      assert(c.env.WHY)
      equal(c.env.PEER, 0)
      equal(#c.env.KEYS, 2)
      equal(c.env.NEW, nil)
      equal(c.env.REBOOT_PEER, 0)
      equal(#c.env.REBOOT_KEYS, 2)
      equal(c.env.REBOOT_NEW, nil)
      equal(c.files["so-keys.tmp"], nil)
    end
  end)

  test("pair2 server remember adds devices without replacing other keys", function()
    local _, server = boot()
    assert(server.env.SO.pair.remember(2, string.rep("a", 64)))
    assert(server.env.SO.pair.remember(3, string.rep("b", 64)))
    equal(#server.env.SO.pair.list(), 2)
    equal(server.env.SO.pair.key(2), string.rep("a", 64))
  end)

  local function unavailable(silent)
    local net = H.new()
    local m = client(net, 2)
    local calls = entropy(m, math.huge, silent)
    m.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["1"] = string.rep("ab", 32) } } })
    m.env.os.queueEvent("entropy-sentinel", 42, nil, "kept")
    m.spawn([[
      proto = dofile("so-proto.lua")
      pair = dofile("so-pair.lua")
      pair.open(proto, dofile("so-store.lua"))
      OPEN_ATTEMPTS = ENTROPY.attempts
      CODE, INVITE_ERR = pair.invite()
      WINDOW, WINDOW_ERR = pair.enrollOpen(1)
      JOINED, JOIN_ERR = pair.join("123456", 1)
      assert(pair.enrollSave("1-AAAA-AAAA-AAAA-AAAA"))
      ENROLLED, ENROLL_ERR = pair.enroll("turtle")
      EVENT = table.pack(os.pullEventRaw())
      DONE = true
    ]])
    net.flush()
    assert(not m.error, tostring(m.error))
    equal(m.env.DONE, true)
    equal(m.env.OPEN_ATTEMPTS, 3)
    equal(calls.attempts, 3)
    equal(calls.yields, 2)
    equal(calls.seeds, 0)
    equal(calls.mixes, 0)
    equal(#m.randomOut, 0)
    for _, name in ipairs({ "INVITE", "WINDOW", "JOIN", "ENROLL" }) do
      equal(m.env[name .. "_ERR"], "random source unavailable")
    end
    equal(m.env.CODE, nil)
    equal(m.env.WINDOW, nil)
    equal(m.env.JOINED, nil)
    equal(m.env.ENROLLED, nil)
    equal(m.env.pair.pending(), nil)
    equal(m.env.pair.enrollView(1), nil)
    equal(m.env.pair.key(1), string.rep("ab", 32))
    equal(m.env.textutils.unserialize(m.files["so-enroll"]).sk, nil)
    equal(m.env.EVENT, table.pack("entropy-sentinel", 42, nil, "kept"))
    equal(#m.sent, 0)
  end

  test("pair2 refuses pairing and enroll secrets when timing initialization throws", function()
    unavailable(false)
  end)

  test("pair2 refuses secrets when timing initialization returns without initializing", function()
    unavailable(true)
  end)

  for _, failures in ipairs({ 0, 1 }) do
    test("pair2 pairs after timing initialization succeeds on attempt " .. tostring(failures + 1), function()
      local serverCalls
      local net, server = boot(nil, nil, nil, function(m) serverCalls = entropy(m, failures) end)
      local c = client(net, 2)
      local clientCalls = entropy(c, failures)
      equal(join(net, c, pressP(net, server)), { "ok" })
      equal(savedKey(server, c.id), savedKey(c, server.id))
      assert(savedKey(server, c.id), "pairing key missing")
      equal(serverCalls.attempts, failures + 1)
      equal(clientCalls.attempts, failures + 1)
      equal(serverCalls.yields, failures)
      equal(clientCalls.yields, failures)
      equal(serverCalls.seeds + clientCalls.seeds, 0)
      equal(serverCalls.mixes, 1)
      equal(clientCalls.mixes, 1)
    end)
  end

  test("pair2 CPace matches the draft-irtf-cfrg-cpace-21 X25519 vectors", function()
    local net, server = boot()
    local P, x = server.env.SO.pair, server.env.require("ccryptolib.x25519")
    local C, hex = P.cpace, server.env.SO.proto.hex
    local function raw(s) return server.env.SO.proto.unhex((s:gsub("%s", ""))) end
    equal(hex(C.sha512("abc")), "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
      .. "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    -- Padding boundaries: one or two final blocks.
    for n, want in pairs({
      [111] = "fa9121c7b32b9e01733d034cfc78cbf67f926c7ed83e82200ef86818196921760b4beff48404df811b953828274461673c68d04e297b0eb7b2b4d60fc6b566a2",
      [112] = "c01d080efd492776a1c43bd23dd99d0a2e626d481e16782e75d54c2503b5dc32bd05f0f1ba33e568b88fd2d970929b719ecbb152f58f130a407c8830604b70ca",
      [127] = "828613968b501dc00a97e08c73b118aa8876c26b8aac93df128502ab360f91bab50a51e088769a5c1eff4782ace147dce3642554199876374291f5d921629502",
      [128] = "b73d1929aa615934e61a871596b3f3b33359f42b8175602e89f7e06e5f658a243667807ed300314b95cacdd579f3e33abdfbe351909519a846d465c59582f321",
    }) do
      equal(hex(C.sha512(string.rep("a", n))), want, "sha512 of " .. n .. " bytes")
    end
    equal(hex(C.sha512(string.rep("a", 200))), "4b11459c33f52a22ee8236782714c150a3b2c60994e9acee"
      .. "17fe68947a3e6789f31e7668394592da7bef827cddca88c4e6f86e4df7ed1ae6cba71f3e98faee9f")
    equal(hex(C.hmac("key", "The quick brown fox jumps over the lazy dog")),
      "b42af09057bac1e2d41708e48a902e09b5ff7f12ab428a4fe86653c73dd248fb"
      .. "82f948a549f7b791a5b41915ee4d1ec3935357e4e2317250d0372afa2ebeeb3a")
    equal(hex(C.lv("1234", "5", "", "678")), "043132333401350003363738")
    local ci = raw("0b415f696e69746961746f720b425f726573706f6e646572")
    local sid = raw("7e4b4791d6a8ef019b936c79fb7f2c57")
    equal(hex(C.generator("Password", ci, sid)),
      "d04bf6d41f6a289632a2e929fa29bebd51092512a7829fdde7d314b62f05a73f")
    local ya = raw("21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b319097153044080")
    local yb = raw("848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19c51ac40a")
    local _, Ya = C.share("Password", ci, sid, ya)
    local _, Yb = C.share("Password", ci, sid, yb)
    equal(hex(Ya), "1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32")
    equal(hex(Yb), "248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea32185623")
    local K = x.exchange(ya, Yb)
    equal(K, x.exchange(yb, Ya))
    equal(hex(K), "5b067effbdc0b2a0e1d907b21ebb25cfedb96a852179a847c37e43ee71322c6b")
    equal(hex(C.sha512(C.lv("CPace255_ISK", sid, K) .. C.lv(Ya, "ADa") .. C.lv(Yb, "ADb"))),
      "6e19b875f7a561d6b3ca3dbb9ef42ac55de3e717881018204b8922b4d5e53bb2"
      .. "aa82c300bea7b65d2b671da71922ddf6472301b79bc270adfa8bf413285f2263")
    -- B.1.10: low-order u values must give the neutral element; isk refuses them.
    local s = raw("af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff")
    for _, u in ipairs({ "00", "01", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
      "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
      "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
      "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
      "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f" }) do
      local point = raw(u) .. string.rep("\0", 32 - #raw(u))
      equal(x.exchange(s, point), string.rep("\0", 32), u)
      equal(C.isk(s, point, sid, point, Yb), nil, u)
    end
    equal(hex(x.exchange(s, raw("daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"))),
      "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806")
    equal(hex(x.exchange(s, raw("4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7"))),
      "993c6ad11c4c29da9a56f7691fd0ff8d732e49de6250b6c2e80003ff4629a175")
    assert(net.machines[server.id].alive())
  end)

  test("pair2 a recorded exchange cannot confirm a code guess offline", function()
    local net, server = boot()
    local code = pressP(net, server)
    local c = client(net, 2)
    equal(join(net, c, code), { "ok" })
    local key = savedKey(server, c.id)
    equal(key, savedKey(c, server.id))
    local env = server.env
    local proto, P = env.SO.proto, env.SO.pair
    local C = P.cpace
    -- Everything a listener saw, in order.
    local wire = {}
    for _, m in ipairs({ c, server }) do
      for i = 1, #m.sent do wire[#wire + 1] = m.sent[i].payload end
    end
    local first, second, reply1, reply2
    for _, msg in ipairs(wire) do
      if msg.t == "pair2" and msg.body.y then first = msg end
      if msg.t == "pair2" and msg.body.tag then second = msg end
    end
    assert(first and second, "pair2 messages missing")
    equal(types(c).pair, nil, "a new client sent legacy pair to a new server")
    for _, msg in ipairs(wire) do
      if msg.t == "ack" and msg.rid == first.rid then reply1 = msg end
      if msg.t == "ack" and msg.rid == second.rid then reply2 = msg end
      assert(not proto.ser(msg):find(key, 1, true), "machine key on the wire")
    end
    assert(reply1 and reply2, "pair2 replies missing")
    -- The only fields: sid, both shares and both confirmation tags.
    local names = {}
    for _, msg in ipairs({ first, reply1, second, reply2 }) do
      local keys = {}
      for k in pairs(msg.body) do keys[#keys + 1] = k end
      table.sort(keys)
      names[#names + 1] = table.concat(keys, ",")
      -- Every envelope MAC uses the fixed public key, so it says nothing about the code.
      assert(proto.macOk(P.envelopeKey(), msg), "envelope not under the public key")
    end
    equal(names, { "sid,y", "y", "sid,tag", "ok,tag" })
    local sid, ya, yb = proto.unhex(first.body.sid), proto.unhex(first.body.y), proto.unhex(reply1.body.y)
    local ta, tb = proto.unhex(second.body.tag), proto.unhex(reply2.body.tag)
    local ci = C.ci(c.id, server.id)
    -- Offline checks that need no secret scalar. A secret-free stand-in for
    -- the shared point K is the guessed generator or a share on the wire.
    local function tagged(k)
      local isk = C.sha512(C.lv("CPace255_ISK", sid, k) .. C.lv(ya, C.ada) .. C.lv(yb, C.adb))
      local a, b = C.tags(isk, sid, ya, yb)
      return a == ta or b == tb
    end
    -- These stand-ins do not depend on the guess.
    for _, k in ipairs({ ya, yb, string.rep("\0", 32) }) do
      assert(not tagged(k), "tag checkable from a public share")
    end
    local function hits(guess)
      local g = C.generator(guess, ci, sid)
      local n = 0
      if tagged(g) then n = n + 1 end
      if g == ya or g == yb then n = n + 1 end
      local hs = P.derive(guess, server.id, c.id)
      if proto.macOk(hs, first) or proto.macOk(hs, second) then n = n + 1 end
      return n
    end
    local seen = { [code] = true }
    local guesses = { code }
    while #guesses < 1001 do
      local g = string.format("%06d", math.random(0, 999999))
      if not seen[g] then
        seen[g] = true
        guesses[#guesses + 1] = g
      end
    end
    for i = 1, #guesses do equal(hits(guesses[i]), 0, "guess " .. guesses[i] .. " was checkable") end
    -- Control: the client's ephemeral scalar, which never leaves it, does
    -- confirm the real code. That is the online secret a guess needs.
    local secret
    for _, out in ipairs(c.randomOut) do
      if #out == 32 and env.require("ccryptolib.x25519").exchange(out, C.generator(code, ci, sid)) == ya then
        secret = out
      end
    end
    assert(secret, "client scalar not found")
    for _, msg in ipairs(wire) do
      assert(not proto.ser(msg):find(proto.hex(secret), 1, true), "client scalar on the wire")
    end
    local isk = C.isk(secret, yb, sid, ya, yb)
    local a, b = C.tags(isk, sid, ya, yb)
    assert(a == ta and b == tb, "control check failed")
    equal(P.machineKey(isk), key)
    for i = 2, 51 do
      local g = C.generator(guesses[i], ci, sid)
      assert(env.require("ccryptolib.x25519").exchange(secret, g) ~= ya, "wrong code matched the share")
    end
  end)

  test("pair2 five bad attempts from one sender keep the code and show its id", function()
    local net, server = boot(false, true)
    local code = pressP(net, server)
    local bad = client(net, 6)
    equal(join(net, bad, wrong(code, 1), 5, server.id), { "wrong code", "wrong code", "busy", "busy", "busy" })
    equal(server.env.SO.pair.pending(), code)
    equal(server.env.SO.terminal.rejected, { 6 })
    assert(logtext(server):find("so-server: pair rejected 6", 1, true), logtext(server))
    local view = {}
    for k, v in pairs(server.env.SO.terminal) do view[k] = v end
    view.now = view.expires - 60000
    local frame = server.env.SO.mods.display.terminal({ tiles = {} }, view, 51, 19)
    local row = ""
    for _, r in ipairs(frame.rows) do if r.text:find("Rejected", 1, true) then row = r.text end end
    equal(row:match("Rejected [%d ]+"), "Rejected 6")
    -- Legacy bad MACs from the same sender are dropped while it is blocked.
    local junk = bad.env.proto.build(string.rep("ab", 32), "pair", { pub = string.rep("cd", 32) })
    for _ = 1, 5 do bad.env.rednet.send(server.id, junk, "so") end
    net.flush()
    equal(server.env.SO.pair.pending(), code)
    assert(logtext(server):find("so-server: pair blocked 6", 1, true), logtext(server))
    local good = client(net, 2)
    equal(join(net, good, code), { "ok" })
    equal(savedKey(server, 2), savedKey(good, 1))
    equal(server.env.SO.pair.pending(), nil)
    equal(server.screen[1], "Press P to pair")
    -- The sender's window clears after 60 s. Three failed guesses per code
    -- then hold it until the next code, so one sender cannot burn a code.
    local fresh = pressP(net, server)
    net.advance(61)
    equal(join(net, bad, wrong(fresh, 2), 2, server.id), { "wrong code", "wrong code" })
    net.advance(61)
    equal(join(net, bad, wrong(fresh, 2), 1, server.id), { "wrong code" })
    net.advance(61)
    equal(join(net, bad, wrong(fresh, 2), 1, server.id), { "busy" })
    equal(server.env.SO.pair.pending(), fresh)
  end)

  test("pair2 bad attempts from paired senders never cancel the code", function()
    local net, server = boot()
    local code = pressP(net, server)
    local machines = {}
    for id = 7, 10 do
      local key = string.rep(tostring(id % 10), 64)
      assert(server.env.SO.pair.remember(id, key))
      local m = client(net, id)
      m.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["1"] = key } } })
      machines[id] = m
    end
    -- Twelve failed guesses from machines that prove their saved key.
    for id = 7, 10 do
      equal(join(net, machines[id], wrong(code, id), 2, server.id), { "wrong code", "wrong code" })
    end
    net.advance(61)
    for id = 7, 10 do
      equal(join(net, machines[id], wrong(code, id), 2, server.id), { "wrong code", "busy" })
      equal(server.env.SO.pair.pending(), code)
    end
    net.advance(61)
    equal(join(net, machines[7], wrong(code, 7), 1, server.id), { "busy" })
    equal(savedKey(server, 7), string.rep("7", 64))
    -- Legacy pair carries no proof, so its bad MACs count like any sender's.
    local legacy = client(net, 11)
    assert(server.env.SO.pair.remember(11, string.rep("1", 64)))
    legacy.spawn([[proto = dofile("so-proto.lua") READY = true]])
    net.flush()
    local junk = legacy.env.proto.build(string.rep("ab", 32), "pair", { pub = string.rep("cd", 32) })
    for _ = 1, 12 do legacy.env.rednet.send(server.id, junk, "so") end
    net.flush()
    equal(server.env.SO.pair.pending(), code)
    local good = client(net, 2)
    equal(join(net, good, code), { "ok" })
    local fresh = pressP(net, server)
    -- A new rid: JOIN reloads so-proto, so its sequence restarts.
    net.advance(1)
    equal(join(net, machines[7], fresh, 1, server.id), { "ok" })
    assert(savedKey(server, 7) ~= string.rep("7", 64), "paired sender did not re-pair with a new code")
  end)

  test("pair2 forged paired sender ids count toward the burn", function()
    local net, server = boot()
    local code = pressP(net, server)
    for id = 30, 34 do
      assert(server.env.SO.pair.remember(id, string.rep("e", 64)))
      equal(join(net, client(net, id), wrong(code, id), 2, server.id), { "wrong code", "wrong code" })
    end
    equal(server.env.SO.pair.pending(), nil)
    equal(savedKey(server, 30), string.rep("e", 64))
  end)

  test("pair2 a forged step 2 with another sid leaves the session open", function()
    local net, server = boot()
    local code = pressP(net, server)
    local P = server.env.SO.pair
    local C, hex = P.cpace, server.env.SO.proto.hex
    local sid = string.rep("\1", 16)
    local ci = C.ci(5, server.id)
    local ya, own = C.share(code, ci, sid)
    local reply = assert(P.start(5, { sid = hex(sid), y = hex(own) }))
    local yb = server.env.SO.proto.unhex(reply.y)
    local ta = C.tags(C.isk(ya, yb, sid, own, yb), sid, own, yb)
    local _, why = P.confirm(5, { sid = string.rep("00", 16), tag = string.rep("00", 64) })
    equal(why, "session")
    assert(P.confirm(5, { sid = hex(sid), tag = hex(ta) }), "forged step 2 closed the session")
  end)

  test("pair2 after ten failed guesses the right code gets no code", function()
    local net, server = boot()
    local code = pressP(net, server)
    for id = 20, 24 do
      equal(join(net, client(net, id), wrong(code, id), 2, server.id), { "wrong code", "wrong code" })
      if id < 24 then equal(server.env.SO.pair.pending(), code) end
    end
    equal(server.env.SO.pair.pending(), nil)
    equal(server.screen[1], "Press P to pair")
    equal(join(net, client(net, 2), code), { "no code" })
    local fresh = pressP(net, server)
    equal(server.env.SO.terminal.rejected, nil)
    equal(join(net, client(net, 3), fresh), { "ok" })
  end)

  test("pair2 turtle, wall display and pocket pair with a code", function()
    local net, server = boot()
    local w = net.machine({ id = 2, modem = true, turtle = true, capacity = 1000000 })
    w.install({ "worker.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" })
    libs(w)
    w.files["so-code"] = pressP(net, server)
    w.env.read = function() return coroutine.yield() end
    w.boot("worker.lua")
    net.flush()
    net.advance(3)
    assert(not w.error, tostring(w.error))
    assert(savedKey(w, 1), "turtle did not pair")
    equal(savedKey(w, 1), savedKey(server, 2))
    for _, spec in ipairs({ { id = 3, monitor = true, width = 29, height = 12 },
      { id = 4, width = 26, height = 20, pocket = true } }) do
      local code = pressP(net, server)
      local d = net.machine({ id = spec.id, modem = true, monitor = spec.monitor,
        width = spec.width, height = spec.height, capacity = 1000000 })
      if spec.pocket then d.env.pocket = {} end
      d.install({ "display.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" })
      libs(d)
      d.boot("display.lua")
      net.flush()
      for digit in code:gmatch(".") do d.env.os.queueEvent("char", digit) end
      net.flush()
      assert(not d.error, tostring(d.error))
      assert(savedKey(d, 1), "display " .. spec.id .. " did not pair")
      equal(savedKey(d, 1), savedKey(server, spec.id))
      equal(types(d).pair, nil)
    end
    equal(types(w).pair, nil)
    assert(types(w).pair2 >= 2, "turtle did not use pair2")
  end)

  test("pair2 mixed versions pair during the rollout", function()
    -- Old client, new server: legacy pair still works this release.
    local net, server = boot()
    local old = client(net, 2, true)
    equal(join(net, old, pressP(net, server)), { "ok" })
    equal(savedKey(old, 1), savedKey(server, 2))
    equal(types(old).pair2, nil)
    -- New client, old server: pair2 goes unanswered and the client never
    -- falls back to legacy pair, which a listener could test offline.
    local oldNet, oldServer = boot(true)
    local fresh = client(oldNet, 3)
    local code = pressP(oldNet, oldServer)
    equal(join(oldNet, fresh, code, 1, nil, 15), { "timeout" })
    equal(savedKey(fresh, 1), nil)
    equal(types(fresh).pair2, 2)
    equal(types(fresh).pair, nil)
    equal(oldServer.env.SO.pair.pending(), code)
    assert(oldServer.alive(), tostring(oldServer.error))
    -- After the server updates, the same client pairs.
    oldNet.kill(oldServer)
    oldServer.install({ "so-server.lua", "so-pair.lua", "so-proto.lua" })
    oldServer = oldNet.boot(oldServer)
    oldNet.flush()
    equal(join(oldNet, fresh, pressP(oldNet, oldServer)), { "ok" })
    equal(savedKey(fresh, 1), savedKey(oldServer, 3))
  end)

  test("pair2 retries get the saved replies and count nowhere", function()
    local net, server = boot()
    local code = pressP(net, server)
    local c = client(net, 2)
    equal(join(net, c, code), { "ok" })
    local key = savedKey(server, 2)
    local fresh = pressP(net, server)
    local before = types(server).ack or 0
    for i = 1, #c.sent do
      local msg = c.sent[i].payload
      if msg.t == "pair2" then c.env.rednet.send(1, msg, "so") end
    end
    net.flush()
    equal(types(server).ack, before + 2)
    equal(savedKey(server, 2), key)
    equal(server.env.SO.pair.pending(), fresh)
    equal(server.env.SO.terminal.rejected, nil)
    assert(not logtext(server):find("rejected", 1, true), logtext(server))
  end)

  test("pair2 network pairing failures stay out of the error ring", function()
    local net, server = boot(false, false, { "so-errors.lua" })
    local so = server.env.SO
    assert(so.errors, "error ring missing")
    local records, record = 0, so.errors.record
    so.errors.record = function(...)
      records = records + 1
      return record(...)
    end
    -- No code yet, then wrong guesses up to the burn, blocked senders,
    -- malformed pair2 bodies and legacy bad MACs.
    equal(join(net, client(net, 2), "123456"), { "no code" })
    local code = pressP(net, server)
    for id = 20, 24 do
      local last = id < 24 and "busy" or "no code"
      equal(join(net, client(net, id), wrong(code, id), 3, server.id), { "wrong code", "wrong code", last })
    end
    equal(so.pair.pending(), nil)
    pressP(net, server)
    local junk = client(net, 6)
    junk.spawn([[proto = dofile("so-proto.lua") READY = true]])
    net.flush()
    local key = so.pair.envelopeKey()
    for _ = 1, 5 do
      junk.env.rednet.send(1, junk.env.proto.build(key, "pair2", { sid = "zz", y = "00" }), "so")
      junk.env.rednet.send(1, junk.env.proto.build(string.rep("ab", 32), "pair", { pub = string.rep("cd", 32) }), "so")
    end
    net.flush()
    assert(server.alive(), tostring(server.error))
    local text = logtext(server)
    for _, line in ipairs({ "so-server: pair rejected 20", "so-server: pair rejected 6",
      "so-server: pair blocked 6" }) do
      assert(text:find(line, 1, true), line .. " missing from the log")
    end
    equal(records, 0)
  end)

  test("pair2 a reflected confirmation never saves a key", function()
    -- A forger answers as the server: it returns the client's own share or
    -- a fresh share, then echoes Ta back as Tb. It knows neither the code
    -- nor any scalar.
    for _, mode in ipairs({ "mirror", "fresh" }) do
      local net = H.new()
      local fake = net.machine({ id = 1, modem = true })
      fake.install(CLIENT)
      libs(fake)
      fake.spawn(string.format([[
        proto = dofile("so-proto.lua")
        pair = dofile("so-pair.lua")
        pair.open(proto, dofile("so-store.lua"))
        local x, key = require("ccryptolib.x25519"), pair.envelopeKey()
        local share = x.publicKey(require("ccryptolib.random").random(32))
        while true do
          local ev, from, msg, p = os.pullEvent()
          if ev == "rednet_message" and p == "so" and type(msg) == "table" and msg.t == "pair2" then
            local body = { ok = true, tag = msg.body.tag }
            if not msg.body.tag then body = { y = %q == "mirror" and msg.body.y or proto.hex(share) } end
            rednet.send(from, proto.encode(proto.build(key, "ack", body, msg.rid)), "so")
          end
        end
      ]], mode))
      net.flush()
      assert(fake.alive(), tostring(fake.error))
      local c = client(net, 2)
      local old = string.rep("5", 64)
      c.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["1"] = old } } })
      local before = c.files["so-keys"]
      c.spawn([[
        proto = dofile("so-proto.lua")
        pair = dofile("so-pair.lua")
        pair.open(proto, dofile("so-store.lua"))
        OK, WHY = pair.join("123456", 1, { replace = 1 })
        KEY = pair.key(1)
        DONE = true
      ]])
      net.flush()
      net.advance(15)
      assert(not c.error, tostring(c.error))
      assert(c.env.DONE, mode .. " join did not finish")
      equal(c.env.OK, nil, mode .. " reflection paired")
      equal(c.env.WHY, mode == "mirror" and "share" or "proof")
      equal(c.env.KEY, old, mode .. " replaced the key in memory")
      equal(c.files["so-keys"], before, mode .. " replaced the saved key")
    end
  end)

  test("pair2 a future-stamped packet cannot replay across a restart", function()
    local net, server = boot()
    local c = client(net, 2)
    equal(join(net, c, pressP(net, server)), { "ok" })
    local key = savedKey(c, 1)
    local proto = c.env.proto
    local function acks()
      local n = 0
      for i = 1, #server.sent do
        if server.sent[i].payload.t == "ack" then n = n + 1 end
      end
      return n
    end
    local function stamped(ms)
      local msg = proto.build(key, "hello", { role = "turtle" })
      msg.at = msg.at + ms
      msg.mac = proto.sign(key, msg)
      return proto.encode(msg)
    end
    -- No stamp may be ahead of the receiver's clock.
    for _, ms in ipairs({ 30000, 1 }) do
      local before = acks()
      c.env.rednet.send(1, stamped(ms), "so")
      net.flush()
      equal(acks(), before, ms .. " ms ahead was accepted")
    end
    assert(logtext(server):find("so-server: bad message from 2", 1, true), logtext(server))
    -- A packet accepted just before a restart is refused just after it.
    local wire = stamped(0)
    c.env.rednet.send(1, wire, "so")
    net.flush()
    net.advance(0.05)
    net.kill(server)
    server = net.boot(server)
    net.flush()
    assert(server.alive(), tostring(server.error))
    c.env.rednet.send(1, wire, "so")
    net.flush()
    equal(acks(), 0)
    assert(logtext(server):find("so-server: replay from 2", 1, true), logtext(server))
  end)

  test("pair2 a replay after a server restart is rejected", function()
    local net, server = boot()
    local c = client(net, 2)
    equal(join(net, c, pressP(net, server)), { "ok" })
    local key = savedKey(c, 1)
    local function acks()
      local n = 0
      for i = 1, #server.sent do
        if server.sent[i].payload.t == "ack" then n = n + 1 end
      end
      return n
    end
    local wire = c.env.proto.encode(c.env.proto.build(key, "hello", { role = "turtle" }))
    c.env.rednet.send(1, wire, "so")
    net.flush()
    local before = acks()
    net.advance(5)
    net.kill(server)
    server = net.boot(server)
    net.flush()
    assert(server.alive(), tostring(server.error))
    net.advance(5)
    c.env.rednet.send(1, wire, "so")
    net.flush()
    equal(acks(), 0)
    assert(logtext(server):find("so-server: replay from 2", 1, true), logtext(server))
    equal(before >= 1, true)
    c.env.rednet.send(1, c.env.proto.encode(c.env.proto.build(key, "hello", { role = "turtle" })), "so")
    net.flush()
    equal(acks(), 1)
  end)
end
