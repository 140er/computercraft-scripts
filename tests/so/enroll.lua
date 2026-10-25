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
  -- Roles change only by assignment: a pocket opens its PAIR tab, other displays are assigned the panel.
  s.openPair = function(id)
    s.frame(id)
    if w == 26 then s.press(id, "tab:pair")
    else assert(d.assign(id, "panel")); s.press(id, "pair") end
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

local function installerMachine(kind)
  local source = read("install.lua")
  local m = H.new().machine({ id = 9, capacity = 16000000 })
  local e, queue = m.env, {}
  e.turtle, e.pocket = kind == "worker" and {} or nil, kind == "pocket" and {} or nil
  e.keys, e.colors = { up = 1, down = 2, enter = 3 }, { white = 1, gray = 128, black = 32768 }
  e.os.queueEvent = function(...) queue[#queue+1] = table.pack(...) end
  e.os.pullEvent = function()
    if #queue > 0 then return table.unpack(table.remove(queue,1)) end
    return "key", e.keys.enter
  end
  local fs = e.fs
  local function norm(path) return path:gsub("^/+", "") end
  for _, name in ipairs({ "exists", "open", "getSize", "getFreeSpace" }) do
    local f = fs[name]
    fs[name] = function(path, ...) return f(norm(path), ...) end
  end
  fs.getDrive = function() return "hdd" end
  fs.getDir = function(path) return path:match("^(.*)/[^/]*$") or "" end
  fs.delete = function(path)
    path = norm(path)
    for name in pairs(m.files) do
      if name == path or name:sub(1,#path+1) == path .. "/" then m.files[name] = nil end
    end
  end
  local move = fs.move
  fs.move = function(from, to)
    if m.onMove then m.onMove(norm(from),norm(to)) end
    return move(norm(from),norm(to))
  end
  e.peripheral.find = function(name)
    if name == "monitor" and kind == "wall" then return e.term end
  end
  m.runs, m.urls = {}, {}
  e.shell = { run = function(path) m.runs[#m.runs+1] = path; return true end }
  local sha = string.rep("a",40)
  local roles = assert(load(source:match("^(.-)local BASE =") .. "return ROLES"))()
  local digest = assert(load(source:match("(local yieldEvent.-)local function validPath") .. "return digest",
    "@install-digest", "t", e))()
  local role = kind == "worker" and "worker" or "display"
  local tree
  e.textutils.unserializeJSON = function(bytes)
    if bytes == "branch" then return {commit={sha=sha}} end
    return {tree=tree}
  end
  e.http = { get = function(url)
    m.urls[#m.urls+1] = url
    local bytes
    if url:find("/branches/",1,true) then bytes = "branch"
    elseif url:find("/git/trees/",1,true) then
      tree = {}
      for _, group in ipairs({roles.common,roles[role]}) do
        for _, path in ipairs(group) do
          local value = path == "install.lua" and (m.pinnedInstaller or source) or read(path)
          tree[#tree+1] = {path=path,type="blob",mode="100644",size=#value,
            sha=digest("blob " .. #value .. "\0" .. value,true)}
        end
      end
      bytes = "tree"
    else
      local pin, path = url:match("computercraft%-scripts/([^/]+)/(.*)$")
      assert(pin == sha, "unpinned role download")
      bytes = path == "install.lua" and (m.pinnedInstaller or source) or read(path)
    end
    return {readAll=function() return bytes end,getResponseCode=function() return 200 end,close=function() end}
  end }
  m.run = function(...) return assert(load(source,"@install.lua","t",e))(...) end
  return m
end

return function(test, equal)
  test("enroll saved runtime toggle defaults off, merges settings and restarts without a window", function()
    local t = boot(nil)
    equal(t.so.enroll.enabled(), false)
    equal(select(2, t.so.enroll.open(OWNER)), "off")
    t.s.files["so-server.cfg"] = H.encode({ pos = { x = 7 }, remoteDimensions = true, other = { keep = 9 } })
    assert(t.so.enroll.setEnabled(true))
    equal(t.so.enroll.enabled(), true)
    local token = t.open()
    local body = t.request(token, 10, string.rep("a", 32))
    t.so.pair.enrollAnswer(10, body)
    assert(t.so.enroll.setEnabled(false))
    equal(t.so.enroll.enabled(), false)
    equal(t.so.enroll.view(OWNER), nil)
    equal(select(2, t.so.enroll.decide(10, 1, true)), "off")
    local cfg = t.s.env.textutils.unserialize(t.s.files["so-server.cfg"])
    equal(cfg, { enroll = false, pos = { x = 7 }, remoteDimensions = true, other = { keep = 9 } })
    t.net.kill(t.s)
    t.s = t.net.boot(t.s)
    t.net.flush()
    assert(t.s.alive(), tostring(t.s.error))
    equal(t.s.env.SO.enroll.enabled(), false)
    equal(t.s.env.SO.enroll.view(OWNER), nil)
    assert(t.s.env.SO.enroll.setEnabled(true))
    assert(t.s.env.SO.enroll.open(OWNER))
    equal(#t.s.env.SO.enroll.view(OWNER).rows, 0)
    t.net.kill(t.s)
    t.s = t.net.boot(t.s)
    t.net.flush()
    equal(t.s.env.SO.enroll.enabled(), true)
    equal(t.s.env.SO.enroll.view(OWNER), nil)
  end)

  test("enroll runtime toggle reports failed saves without changing the running flag or window", function()
    for _, failure in ipairs({ "open", "write", "verify", "move" }) do
      local t = boot(true)
      local token = t.open()
      local open, move = t.s.env.fs.open, t.s.env.fs.move
      t.s.env.fs.open = function(path, mode)
        if path == "so-server.cfg.tmp" then
          if failure == "open" and mode == "w" then return nil end
          if failure == "write" and mode == "w" then error("disk full") end
          if failure == "verify" and mode == "r" then return nil end
        end
        return open(path, mode)
      end
      t.s.env.fs.move = function(from, to)
        if failure == "move" and from == "so-server.cfg.tmp" then error("move failed") end
        return move(from, to)
      end
      equal(t.so.enroll.setEnabled(false), nil)
      equal(t.so.enroll.enabled(), true)
      equal(t.so.enroll.view(OWNER).token, token)
      t.net.kill(t.s)
      t.s = t.net.boot(t.s)
      t.net.flush()
      assert(t.s.alive(), tostring(t.s.error))
      equal(t.s.env.SO.enroll.enabled(), failure ~= "move")
      equal(t.s.env.SO.enroll.view(OWNER), nil)
    end
    local t = boot(true)
    t.s.files["so-server.cfg"] = "broken"
    equal(t.so.enroll.setEnabled(false), nil)
    equal(t.s.files["so-server.cfg"], "broken")
  end)

  local function interruptedOff(temp)
    local t = boot(true)
    local before = { enroll = true, pos = { dim = "minecraft:the_nether", x = 7, y = 64, z = 9 },
      workerSettings = true, state = { coalesceHeartbeats = true }, other = { keep = 11 } }
    t.s.files["so-server.cfg"] = H.encode(before)
    local move = t.s.env.fs.move
    t.s.env.fs.move = function(from, to)
      move(from, to)
      if from == "so-server.cfg" and to == "so-server.cfg.bak" then
        t.net.kill(t.s)
        error("chunk unloaded between config moves")
      end
    end
    equal(pcall(t.so.enroll.setEnabled, false), false)
    equal(t.s.files["so-server.cfg"], nil)
    equal(t.s.env.textutils.unserialize(t.s.files["so-server.cfg.bak"]), before)
    local expected = t.s.env.textutils.unserialize(t.s.files["so-server.cfg.tmp"])
    equal(expected.enroll, false)
    if temp ~= "valid" then expected = before end
    if temp == "malformed" then t.s.files["so-server.cfg.tmp"] = "interrupted write" end
    if temp == "missing" then t.s.files["so-server.cfg.tmp"] = nil end
    if temp == "unreadable" then
      t.net.onBoot = function(m)
        local open = m.env.fs.open
        m.env.fs.open = function(path, mode)
          if path == "so-server.cfg.tmp" and mode == "r" then return nil end
          return open(path, mode)
        end
      end
    end
    t.s.files["so-mod-state.lua"] =
      'CONFIG_AT_MODULE_LOAD = assert(SO.store.read("so-server.cfg"), "config missing during module load")\n' ..
      t.s.files["so-mod-state.lua"]
    t.s = t.net.boot(t.s)
    t.net.flush()
    assert(t.s.alive(), tostring(t.s.error))
    assert(t.s.env.SO.mods.state, "state failed to load")
    equal(t.s.env.SO.store.read("so-server.cfg"), expected)
    equal(t.s.env.CONFIG_AT_MODULE_LOAD, expected)
    equal(t.s.env.SO.enroll.enabled(), expected.enroll)
    equal(t.s.env.SO.enroll.view(OWNER), nil)
  end

  test("enroll interrupted OFF promotes the checked temporary config before modules load", function()
    interruptedOff("valid")
  end)

  test("enroll interrupted OFF restores the backup before modules load when the temporary config is unreadable", function()
    for _, temp in ipairs({ "unreadable", "malformed", "missing" }) do interruptedOff(temp) end
  end)

  test("enroll approved keys remain collectible through runtime OFF while undecided rows are cancelled", function()
    local t = boot(true)
    local token = t.open()
    local approved, pending = turtle(t, 10, token), turtle(t, 11, token)
    t.net.advance(4)
    local rows = t.so.enroll.view(OWNER).rows
    assert(t.so.enroll.decide(10, rows[1].n, true))
    assert(t.so.enroll.setEnabled(false))
    equal(t.so.enroll.view(OWNER), nil)
    t.net.advance(10)
    equal(savedKey(approved, 1), t.so.pair.key(10))
    equal(approved.files["so-enroll"], nil)
    equal(pending.env.textutils.unserialize(pending.files["so-enroll"]).paused, "off")
    assert(t.so.enroll.setEnabled(true))
    assert(t.so.enroll.open(OWNER))
    equal(t.so.enroll.decide(11, rows[2].n, true), nil)
    equal(t.so.pair.key(11), nil)
  end)

  test("enroll server stages worker, pocket and wall requests with kind-bound approvals", function()
    local t = boot(true)
    local token = t.open()
    for i, kind in ipairs({ "turtle", "pocket", "computer" }) do
      local id, sk = 9+i, string.rep(string.char(20+i), 32)
      local body, pub = t.request(token, id, sk, kind)
      local wire, reply = t.so.pair.enrollAnswer(id, body, t.so.enroll.enabled())
      equal(wire, "ack")
      equal(reply.state, "pending")
      local row = t.so.enroll.view(OWNER).rows[1]
      equal(row.kind, kind)
      assert(t.so.enroll.decide(id, row.n, true))
      wire, reply = t.so.pair.enrollAnswer(id, body, false)
      equal(wire, "ack")
      local xs = t.unhex(reply.pub)
      local k = t.x.exchange(sk, xs)
      equal(reply.tag, t.hex(t.tag(token, 3, "1", tostring(id), pub, kind, xs, k)))
      equal(t.so.pair.key(id), t.so.pair.machineKey(t.C.sha512(t.C.lv("so-enroll isk", "1", tostring(id), pub, xs, k))))
    end
  end)

  test("enroll installer stages worker, pocket and wall tokens with the selected server and preserves config", function()
    for _, kind in ipairs({ "worker", "pocket", "wall" }) do
      local m = installerMachine(kind)
      local cfgPath = kind == "worker" and "so-worker.cfg" or "so-display.cfg"
      m.files[cfgPath] = H.encode({ repairServer = true, retryInput = true, other = { keep = 7 } })
      local token = "12-K7QP-3MXA-9WTD-HR2E"
      m.run(token, "--server", "12")
      equal(m.env.textutils.unserialize(m.files["so-enroll"]), {token=token})
      equal(m.env.textutils.unserialize(m.files[cfgPath]),
        {server=12,repairServer=true,retryInput=true,other={keep=7}})
      equal(m.files["so-server.cfg"], nil)
      equal(m.runs, {kind == "worker" and "/worker.lua" or "/display.lua"})
      equal(m.files[".so-revision"], string.rep("a",40))
      assert(not table.concat(m.log):find("K7QP",1,true))
    end
  end)

  test("enroll installer rejects a different explicit server before downloading or changing config", function()
    local m = installerMachine("worker")
    m.files["so-worker.cfg"] = H.encode({other=7,server=3})
    local before = H.encode(m.files)
    local ok, err = pcall(m.run, "12-K7QP-3MXA-9WTD-HR2E", "--server", "3")
    equal(ok,false)
    assert(tostring(err):find("different server",1,true))
    equal(H.encode(m.files),before)
    equal(#m.urls,0)
  end)

  test("enroll installer accepts an unpaired explicit server without a token and leaves missing selection untouched", function()
    local m = installerMachine("worker")
    m.files["so-worker.cfg"] = H.encode({autoToolSwap=true})
    m.run("--server", "0")
    equal(m.env.textutils.unserialize(m.files["so-worker.cfg"]), {server=0,autoToolSwap=true})
    equal(m.files["so-enroll"],nil)
    m = installerMachine("pocket")
    m.files["so-display.cfg"] = H.encode({other=9})
    m.run("12-K7QP-3MXA-9WTD-HR2E")
    equal(m.env.textutils.unserialize(m.files["so-display.cfg"]), {other=9})
  end)

  test("enroll installer refuses role tokens and selected-server trust changes for every saved key generation", function()
    for _, kind in ipairs({"worker","pocket","wall"}) do
      for _, suffix in ipairs({"", ".bak", ".tmp"}) do
        local m = installerMachine(kind)
        m.files["so-keys" .. suffix] = "saved trust"
        local before = H.encode(m.files)
        m.run("--server", "12")
        m.run("12-K7QP-3MXA-9WTD-HR2E")
        equal(H.encode(m.files),before)
        equal(#m.urls,0)
        equal(#m.runs,0)
      end
    end
  end)

  test("enroll installer validates server ids and keeps install check read-only", function()
    for _, args in ipairs({ {"--server","-1"}, {"--server","1.5"}, {"--server","nan"},
      {"--server","9007199254740992"}, {"--server"}, {"--server","1","--server","2"},
      {"check","--server","12"}, {"update","--server","12"} }) do
      local m = installerMachine("worker")
      local ok = pcall(m.run,table.unpack(args))
      equal(ok,false)
      equal(next(m.files),nil)
      equal(#m.urls,0)
    end
    local m = installerMachine("worker")
    m.files["so-worker.cfg"] = H.encode({server=3,other=7})
    local before = H.encode(m.files)
    m.run("check")
    equal(H.encode(m.files),before)
    equal(#m.runs,0)
  end)

  test("enroll installer refuses malformed client config without replacing unrelated settings", function()
    for _, kind in ipairs({"worker","pocket"}) do
      local m = installerMachine(kind)
      local path = kind == "worker" and "so-worker.cfg" or "so-display.cfg"
      m.files[path] = "broken config"
      equal(pcall(m.run,"--server","12"),false)
      equal(m.files[path],"broken config")
      equal(#m.urls,0)
    end
  end)

  test("enroll selected-server config rolls back with an interrupted installer swap", function()
    local m = installerMachine("worker")
    m.files["so-worker.cfg"] = H.encode({other=7,server=3})
    local before = m.files["so-worker.cfg"]
    m.onMove = function(from)
      if from == ".so-new/so-worker.cfg" then error("interrupted config swap") end
    end
    m.run("--server","12")
    equal(m.files["so-worker.cfg"],before)
    equal(m.files["worker.lua"],nil)
    equal(m.files[".so-revision"],nil)
    equal(#m.runs,0)
  end)

  test("enroll selected-server and display-token installs refuse an older pinned installer without falling back", function()
    for _, args in ipairs({{"--server","12"},{"12-K7QP-3MXA-9WTD-HR2E"}}) do
      local m = installerMachine("pocket")
      m.pinnedInstaller = read("install.lua"):gsub(' enrollRoles = true,', '')
      m.run(table.unpack(args))
      equal(m.files["so-display.cfg"],nil)
      equal(m.files["so-enroll"],nil)
      equal(m.files["display.lua"],nil)
      equal(#m.runs,0)
      assert(table.concat(m.log):find("Pinned installer does not support",1,true))
    end
  end)

  test("enroll rerun before approval leaves one row and keeps the secret", function()
    local t = boot(true)
    local token = t.open()
    local w = turtle(t, 10, token)
    t.net.advance(4)
    local saved = w.env.textutils.unserialize(w.files["so-enroll"])
    local fp = t.so.enroll.view(OWNER).rows[1].fp
    w.spawn([[local p = dofile("so-pair.lua")
      p.open(dofile("so-proto.lua"), dofile("so-store.lua"))
      local saved = textutils.unserialize(fs.open("so-enroll", "r").readAll())
      assert(p.enrollSave(saved.token))]])
    t.net.flush()
    equal(w.env.textutils.unserialize(w.files["so-enroll"]).sk, saved.sk)
    w = t.net.boot(w)
    t.net.advance(4)
    local view = t.so.enroll.view(OWNER)
    equal(#view.rows, 1)
    equal(view.rows[1].fp, fp)
    assert(t.so.enroll.decide(10, view.rows[1].n, true))
    t.net.advance(7)
    equal(savedKey(w, 1), t.so.pair.key(10))
  end)

  test("enroll extend at 9:00 accepts at 15:00 without changing the token or cap", function()
    local t = boot(true)
    local token = t.open()
    t.net.advance(540)
    equal(t.so.enroll.extend(3), nil)
    assert(t.so.enroll.extend(OWNER))
    t.net.advance(360)
    equal(t.so.enroll.view(OWNER).token, token)
    equal(t.so.enroll.view(OWNER).cap, 20)
    local body = t.request(token, 10, string.rep("a", 32))
    equal(select(2, t.so.pair.enrollAnswer(10, body)).state, "pending")
    assert(t.so.enroll.decide(10, t.so.enroll.view(OWNER).rows[1].n, true))
  end)

  test("enroll extended window keeps the waiting turtle's secret past 12:00 and approves at 15:00", function()
    local t = boot(true)
    local token = t.open()
    local w = turtle(t, 10, token)
    t.net.advance(4)
    local saved = w.env.textutils.unserialize(w.files["so-enroll"])
    local first = t.so.enroll.view(OWNER).rows[1]
    t.net.advance(536)
    assert(t.so.enroll.extend(OWNER))
    t.net.advance(180)
    equal(w.env.textutils.unserialize(w.files["so-enroll"]).sk, saved.sk)
    equal(#t.so.enroll.view(OWNER).rows, 1)
    equal(t.so.enroll.view(OWNER).rows[1].n, first.n)
    t.net.advance(180)
    equal(w.env.textutils.unserialize(w.files["so-enroll"]).sk, saved.sk)
    equal(t.so.enroll.view(OWNER).rows[1].n, first.n)
    assert(t.so.enroll.decide(10, first.n, true))
    t.net.advance(7)
    equal(savedKey(w, 1), t.so.pair.key(10))
    equal(w.files["so-enroll"], nil)
  end)

  test("enroll a full reply cap before the first tagged share cannot persistently pause a turtle", function()
    for _, locked in ipairs({ false, true }) do
      for _, text in ipairs({ "off", "closed" }) do
        local t = boot(true)
        local token = t.open()
        local w = t.net.machine({ id = 10, modem = true, turtle = true, capacity = 1000000 })
        w.install(WORKER)
        libs(w)
        w.files["so-enroll"] = H.encode({ token = token })
        local send, flood, rounds = w.env.rednet.send, not locked, 0
        w.env.rednet.send = function(id, payload, protocol)
          if flood and type(payload) == "table" and payload.t == "enroll" then
            rounds = rounds + 1
            local wire = t.proto.encode(t.proto.build(t.so.pair.envelopeKey(), "err",
              { code = "enroll", text = text }, payload.rid))
            for _ = 1, 16 do
              w.inbox[#w.inbox + 1] = table.pack("rednet_message", 1, wire, "so")
            end
            return
          end
          send(id, payload, protocol)
        end
        w.boot("worker.lua")
        t.net.advance(4)
        local saved = w.env.textutils.unserialize(w.files["so-enroll"])
        equal(saved.paused, nil)
        flood = true
        t.net.advance(15)
        assert(rounds >= 4, "flood did not cover several rounds")
        equal(w.env.textutils.unserialize(w.files["so-enroll"]).sk, saved.sk)
        equal(w.env.textutils.unserialize(w.files["so-enroll"]).paused, nil)
        local screenText = table.concat(w.screen, "\n")
        assert(not screenText:find("enroll off", 1, true), "noisy off changed the screen")
        assert(not screenText:find("window closed", 1, true), "noisy closed changed the screen")
        flood = false
        t.net.advance(4)
        local row = t.so.enroll.view(OWNER).rows[1]
        assert(t.so.enroll.decide(10, row.n, true))
        t.net.advance(7)
        equal(savedKey(w, 1), t.so.pair.key(10))
        equal(w.files["so-enroll"], nil)
      end
    end
  end)

  test("enroll one quiet forged off after a tagged share does not pause, but real off does", function()
    local t = boot(true)
    local token = t.open()
    local w = turtle(t, 10, token)
    t.net.advance(4)
    local saved = w.env.textutils.unserialize(w.files["so-enroll"])
    local send, injected = w.env.rednet.send, 0
    w.env.rednet.send = function(id, payload, protocol)
      if type(payload) == "table" and payload.t == "enroll" and injected == 0 then
        injected = injected + 1
        local wire = t.proto.encode(t.proto.build(t.so.pair.envelopeKey(), "err",
          { code = "enroll", text = "off" }, payload.rid))
        w.inbox[#w.inbox + 1] = table.pack("rednet_message", 1, wire, "so")
        return
      end
      send(id, payload, protocol)
    end
    t.net.advance(10)
    equal(injected, 1)
    equal(w.env.textutils.unserialize(w.files["so-enroll"]).paused, nil)
    t.s.files["so-server.cfg"] = H.encode({ enroll = false })
    t.net.advance(10)
    local paused = w.env.textutils.unserialize(w.files["so-enroll"])
    equal(paused.paused, "off")
    equal(paused.sk, saved.sk)
  end)

  test("enroll message bursts read server config at most once per tick", function()
    local t = boot(nil)
    local w = t.net.machine({ id = 10, modem = true })
    local reads, readConfig = 0, t.so.store.read
    t.so.store.read = function(path)
      if path == "so-server.cfg" then reads = reads + 1 end
      return readConfig(path)
    end
    local function burst()
      for _ = 1, 20 do
        local msg = t.proto.build(t.so.pair.envelopeKey(), "enroll", {})
        msg.from = 10
        msg.mac = t.proto.sign(t.so.pair.envelopeKey(), msg)
        w.env.rednet.send(1, t.proto.encode(msg), "so")
      end
      t.net.flush()
    end
    burst()
    equal(reads, 1)
    burst()
    equal(reads, 1)
    t.net.advance(1.05)
    burst()
    equal(reads, 2)
  end)

  test("enroll paired requests are tagged and logged with the six-digit route", function()
    local t = boot(true)
    local token = t.open()
    local w = turtle(t, 3, token)
    t.net.advance(7)
    assert(table.concat(t.s.log, "\n"):find("enroll paired 3", 1, true))
    assert(table.concat(w.screen, "\n"):find("6-digit code", 1, true))
    equal(w.files["so-enroll"], nil)
  end)

  test("enroll off survives reboot and pauses attempts until explicit resume", function()
    local t = boot(true)
    local token = t.open()
    assert(t.so.enroll.setEnabled(false))
    local w = turtle(t, 10, token)
    t.net.advance(7)
    local saved = w.env.textutils.unserialize(w.files["so-enroll"])
    equal(saved.paused, "off")
    assert(saved.sk)
    t.net.kill(w)
    w = t.net.boot(w)
    t.net.advance(30)
    for _, packet in ipairs(w.sent) do assert(packet.payload.t ~= "enroll", "paused reboot sent enroll") end
    assert(t.so.enroll.setEnabled(true))
    token = t.open()
    w.env.os.queueEvent("paste", token)
    w.env.os.queueEvent("key", 257)
    t.net.flush()
    t.net.advance(7)
    local row = t.so.enroll.view(OWNER).rows[1]
    assert(row, "explicit resume did not enroll")
    assert(t.so.enroll.decide(10, row.n, true))
    t.net.advance(7)
    equal(savedKey(w, 1), t.so.pair.key(10))
  end)

  test("enroll approved results stay collectible while off", function()
    local t = boot(true)
    local token = t.open()
    local w = turtle(t, 10, token)
    local pending = turtle(t, 11, token)
    t.net.advance(4)
    assert(t.so.enroll.decide(10, t.so.enroll.view(OWNER).rows[1].n, true))
    t.s.files["so-server.cfg"] = H.encode({ enroll = false })
    t.net.advance(10)
    equal(savedKey(w, 1), t.so.pair.key(10))
    equal(w.files["so-enroll"], nil)
    equal(pending.env.textutils.unserialize(pending.files["so-enroll"]).paused, "off")
    equal(t.so.enroll.view(OWNER), nil)
  end)

  test("enroll a forged untagged closed does not delete a saved attempt", function()
    local t = boot(true)
    local token = t.open()
    local w = turtle(t, 10, token)
    t.net.advance(4)
    local send = w.env.rednet.send
    local forged = false
    w.env.rednet.send = function(id, payload, protocol)
      if payload.t ~= "enroll" then return send(id, payload, protocol) end
      forged = true
      local body = { code = "enroll", text = "closed" }
      w.inbox[#w.inbox + 1] = table.pack("rednet_message", 1,
        t.proto.encode(t.proto.build(t.so.pair.envelopeKey(), "err", body, payload.rid)), "so")
    end
    t.net.advance(7)
    assert(forged)
    assert(w.files["so-enroll"], "forged closed deleted saved attempt")
    w.env.rednet.send = send
    assert(t.so.enroll.decide(10, t.so.enroll.view(OWNER).rows[1].n, true))
    t.net.advance(7)
    equal(savedKey(w, 1), t.so.pair.key(10))
  end)

  test("enroll atomic replacement saves only the proven peer and retains old keys on save failure", function()
    for _, fail in ipairs({ false, true }) do
      local t = boot(true)
      local token = t.open()
      local w = t.net.machine({ id = 10, modem = true, turtle = true, capacity = 1000000 })
      w.install(WORKER)
      libs(w)
      local old = string.rep("a", 64)
      w.files["so-keys"] = H.encode({ schema = 1, generation = 1,
        value = { keys = { ["0"] = old, ["9"] = old } } })
      w.files["so-enroll"] = H.encode({ token = token })
      w.env.FAIL = fail
      w.spawn([[
        local p, proto, store = dofile("so-pair.lua"), dofile("so-proto.lua"), dofile("so-store.lua")
        p.open(proto, store)
        local move = fs.move
        fs.move = function(from, to)
          if FAIL and from == "so-keys.tmp" and to == "so-keys" then error("rename failed") end
          return move(from, to)
        end
        SERVER, WHY = p.enroll("turtle", nil, { replace = 0 })
        PEER, KEYS, NEW = p.peer(), p.list(), p.key(1)
        fs.move = move
        local reboot = dofile("so-pair.lua")
        reboot.open(proto, store)
        REBOOT_PEER, REBOOT_KEYS = reboot.peer(), reboot.list()
      ]])
      t.net.advance(4)
      equal(savedKey(w, 0), old)
      equal(savedKey(w, 1), nil)
      assert(t.so.enroll.decide(10, t.so.enroll.view(OWNER).rows[1].n, true))
      t.net.advance(7)
      assert(not w.error, tostring(w.error))
      if fail then
        equal(w.env.SERVER, nil)
        assert(w.env.WHY)
        equal(w.env.PEER, 0)
        equal(#w.env.KEYS, 2)
        equal(w.env.NEW, nil)
        equal(w.env.REBOOT_PEER, 0)
        equal(#w.env.REBOOT_KEYS, 2)
        assert(w.files["so-enroll"], "save failure discarded attempt")
      else
        equal(w.env.SERVER, 1)
        equal(w.env.PEER, 1)
        equal(#w.env.KEYS, 1)
        equal(w.env.REBOOT_PEER, 1)
        equal(#w.env.REBOOT_KEYS, 1)
        equal(savedKey(w, 1), t.so.pair.key(10))
        equal(w.files["so-enroll"], nil)
      end
    end
  end)

  test("enroll a valid tagged approval wins over an untagged off in the same round", function()
    local t = boot(true)
    local token = t.open()
    local w = turtle(t, 10, token)
    t.net.advance(4)
    assert(t.so.enroll.decide(10, t.so.enroll.view(OWNER).rows[1].n, true))
    local send = w.env.rednet.send
    w.env.rednet.send = function(id, payload, protocol)
      if payload.t == "enroll" then
        local body = { code = "enroll", text = "off" }
        w.inbox[#w.inbox + 1] = table.pack("rednet_message", 1,
          t.proto.encode(t.proto.build(t.so.pair.envelopeKey(), "err", body, payload.rid)), "so")
      end
      send(id, payload, protocol)
    end
    t.net.advance(7)
    equal(savedKey(w, 1), t.so.pair.key(10))
    equal(w.files["so-enroll"], nil)
  end)

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
    local secret = w.env.textutils.unserialize(w.files["so-enroll"]).sk
    net.advance(620)
    equal(savedKey(w, 1), nil)
    equal(w.env.textutils.unserialize(w.files["so-enroll"]).sk, secret)
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

  test("enroll: denial deletes the attempt and untagged closed remains a hint", function()
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
    assert(a.files["so-enroll"], "public closed deleted the attempt")
    local secret = a.env.textutils.unserialize(a.files["so-enroll"]).sk
    t.net.advance(700)
    equal(a.env.textutils.unserialize(a.files["so-enroll"]).sk, secret)
    equal(savedKey(a, 1), nil)
  end)

  test("enroll off replies off and the handler answers with the flag off and on", function()
    local t = boot(nil)
    equal(t.so.enroll.enabled(), false)
    local w = turtle(t, 10, "1-K7QP-3MXA-9WTD-HR2E")
    t.net.advance(7)
    local function last()
      for i = #t.s.sent, 1, -1 do
        local packet = t.s.sent[i]
        if packet.id == 10 and packet.payload.t == "err" then return packet.payload.body.text end
      end
    end
    equal(last(), "off")
    equal(w.env.textutils.unserialize(w.files["so-enroll"]).paused, "off")
    assert(not table.concat(t.s.log, "\n"):find("bad mac from 10", 1, true))
    t.s.files["so-server.cfg"] = H.encode({ enroll = true })
    t.net.advance(1.05)
    local msg = t.proto.build(t.so.pair.envelopeKey(), "enroll", { kind = "turtle" })
    msg.from = 10
    msg.mac = t.proto.sign(t.so.pair.envelopeKey(), msg)
    w.env.rednet.send(1, t.proto.encode(msg), "so")
    t.net.flush()
    equal(last(), "closed")
    t.s.files["so-server.cfg"] = H.encode({ enroll = false })
    t.net.advance(1.05)
    w.env.rednet.send(1, t.proto.encode(msg), "so")
    t.net.flush()
    equal(last(), "off", "cached reply bypassed the per-request flag check")
    equal(savedKey(w, 1), nil)
  end)

  test("enroll panel uses drawn buttons and fits 26x20 and 29x12", function()
    for _, size in ipairs({ { 26, 20 }, { 29, 12 } }) do
      local w, h = size[1], size[2]
      local t = boot(true)
      local s = screen(t, w, h)
      s.openPair(OWNER)
      s.openPair(3)
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
      -- Only page words, ids, kinds, fingerprints, counts, the timer and the token. Hairlines, leader
      -- dots, action brackets and the pocket's tabs are structure.
      local text = table.concat(s.text(OWNER), "\n")
      local flat = text:gsub("[\7\128-\255]", ""):gsub("[%[%]]", " ")
      assert(flat:find(token, 1, true) or flat:find(token:match("^%d+%-%w+%-%w+"), 1, true), flat)
      assert(flat:find("#10 turtle", 1, true), "kind label cut at " .. w .. "x" .. h)
      for word in flat:gmatch("[^%s]+") do
        local ok = ({ ENROLL = true, PENDING = true, joined = true, APPROVE = true, ALL = true, CLOSE = true, OK = true,
          NO = true, turtle = true, PANEL = true, FLEET = true, JOBS = true, SHOP = true, PAIR = true })[word]
          or word:match("^#%d+$") or fps[word] or word:match("^%d+:%d%d$") or word:match("^%d+/?%d*$")
          or word:match("^%-+$") or token:find(word, 1, true)
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
    s.openPair(OWNER)
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
    -- A 29x12 display is no pocket; the panel role shows the same window.
    small.frame(OWNER)
    assert(t.so.mods.display.assign(OWNER, "panel"))
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
      open = function(path, mode)
        if mode == "r" then
          if not written[path] then return nil end
          return { readAll = function() return written[path] end, close = function() end }
        end
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
    written["/so-enroll"] = e.textutils.serialize({ token = handed.token, sk = string.rep("ab", 32), paused = "off" })
    main(nil, { revision = string.rep("a", 40), previous = {}, role = "worker", enroll = handed.token })
    handed = e.textutils.unserialize(written["/so-enroll"])
    equal(handed.sk, string.rep("ab", 32), "installer rerun discarded secret")
    equal(handed.paused, nil, "explicit installer rerun did not resume")
    log = table.concat(m.log, "\n")
    assert(not log:find("K7QP", 1, true), log)
    assert(log:find("server 12", 1, true), log)
    e.turtle, e.pocket = nil, {}
    main(nil, { revision = string.rep("a", 40), previous = {}, role = "display",
      enroll = "12-K7QP-3MXA-9WTD-HR2E" })
    equal(e.textutils.unserialize(written["/so-enroll"]).token, handed.token)
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

  -- A token holder hides the real server's reply behind cheap junk and
  -- sends its own valid ok first in every round.
  local function hidden(junk)
    local t = boot(true)
    local token = t.open()
    local P = t.so.pair
    local fake = string.rep("f", 32)
    local fx = t.x.publicKey(fake)
    local pubs = {}
    for i = 1, 60 do pubs[i] = t.hex(t.x.publicKey(string.rep(string.char(i + 64), 32))) end
    local w = t.net.machine({ id = 10, modem = true, turtle = true, capacity = 1000000 })
    w.install(WORKER)
    libs(w)
    w.files["so-enroll"] = H.encode({ token = token })
    w.env.read = function() return coroutine.yield() end
    local send, rounds = w.env.rednet.send, 0
    local function push(body, rid)
      w.inbox[#w.inbox + 1] = table.pack("rednet_message", 1,
        t.proto.encode(t.proto.build(P.envelopeKey(), "ack", body, rid)), "so")
    end
    w.env.rednet.send = function(id, payload, protocol)
      -- Queue the forgeries before the real server sees the request.
      if type(payload) == "table" and payload.t == "enroll" then
        rounds = rounds + 1
        local pub = t.unhex(payload.body.pub)
        local k = t.x.exchange(fake, pub)
        push({ state = "ok", pub = t.hex(fx), tag = t.hex(t.tag(token, 3, "1", "10", pub, "turtle", fx, k)) }, payload.rid)
        for i = 1, junk do
          push({ state = "pending", pub = pubs[(rounds * junk + i) % #pubs + 1], tag = string.rep("ab", 32) }, payload.rid)
        end
      end
      send(id, payload, protocol)
    end
    w.boot("worker.lua")
    t.net.advance(30)
    assert(w.alive(), tostring(w.error))
    assert(rounds >= 5, "rounds " .. rounds)
    equal(savedKey(w, 1), nil, "turtle saved the token holder's key")
    -- The real request is still pending on the server.
    equal(#t.so.enroll.view(OWNER).rows, 1)
  end

  test("enroll: sixteen junk replies hiding the real server never confirm a key", function()
    hidden(16)
  end)

  test("enroll: junk that uses up the exchange cap never confirms a key", function()
    hidden(4)
  end)
end
