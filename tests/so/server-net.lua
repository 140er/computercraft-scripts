local H = dofile("tests/so/harness.lua")

local function install(m, server)
  m.install(server and {"so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-mod-display.lua"}
    or {"display.lua", "so-proto.lua", "so-pair.lua", "so-store.lua"})
  for _, name in ipairs({"x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing"}) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path)); m.files[path] = f:read("*a"); f:close()
  end
  if server then m.files["so-server.cfg"] = H.encode({pos = {dim = "minecraft:overworld", x = 0, y = 0, z = 0}}) end
end

local function network()
  local n = H.new()
  local function machine(id, server, wireless)
    local m = n.machine({id = id, capacity = server and 16000000 or 1000000})
    install(m, server)
    m.devices, m.opened, m.received = {}, {}, {}
    local names = {"back", "left", "right"}
    m.devices.back = {isWireless = function() return false end}
    if wireless then m.devices.left = {isWireless = function() return true end} end
    m.env.peripheral.getNames = function()
      local found = {}
      for _, name in ipairs(names) do if m.devices[name] then found[#found + 1] = name end end
      return found
    end
    m.env.peripheral.getType = function(name) if m.devices[name] then return "modem" end end
    m.env.peripheral.hasType = function(name, kind) return kind == "modem" and m.devices[name] ~= nil end
    m.env.peripheral.wrap = function(name) return m.devices[name] end
    m.env.peripheral.find = function(kind, filter)
      local found = {}
      if kind == "modem" then
        for _, name in ipairs(names) do
          local dev = m.devices[name]
          if dev and (not filter or filter(name, dev)) then found[#found + 1] = dev end
        end
      end
      return table.unpack(found)
    end
    m.env.peripheral.getName = function(dev)
      for name, value in pairs(m.devices) do if dev == value then return name end end
      error("unknown peripheral")
    end
    m.env.rednet.open = function(name) assert(m.devices[name], "missing modem"); m.opened[name] = true end
    m.env.rednet.close = function(name) if name then m.opened[name] = nil else m.opened = {} end end
    m.env.rednet.isOpen = function(name)
      if name then return m.devices[name] ~= nil and m.opened[name] == true end
      for side in pairs(m.opened) do if m.devices[side] then return true end end
      return false
    end
    m.wireless = function()
      for side in pairs(m.opened) do
        if m.devices[side] and m.devices[side].isWireless() then return true end
      end
      return false
    end
    m.env.rednet.lookup = function(protocol, hostname)
      if not m.wireless() then return nil end
      local hosts = n.hosts[protocol] or {}
      local id = hosts[hostname]
      if id and n.machines[id] and n.machines[id].wireless() then return id end
    end
    m.env.rednet.host = function(protocol, hostname)
      n.hosts[protocol] = n.hosts[protocol] or {}
      local existing = m.env.rednet.lookup(protocol, hostname)
      if existing and existing ~= id then error("Hostname in use", 0) end
      n.hosts[protocol][hostname] = id
    end
    m.env.rednet.send = function(target, payload, protocol)
      m.sent[#m.sent + 1] = {id = target, payload = payload, protocol = protocol}
      local dest = n.machines[target]
      if m.wireless() and dest and dest.wireless() and not dest.killed then
        dest.received[#dest.received + 1] = {id = id, payload = payload, protocol = protocol}
        dest.env.os.queueEvent("rednet_message", id, payload, protocol)
        return true
      end
      return false
    end
    m.attach = function(side)
      m.devices[side] = {isWireless = function() return true end}
      m.env.os.queueEvent("peripheral", side)
      n.flush()
    end
    m.detach = function(side)
      m.devices[side], m.opened[side] = nil, nil
      m.env.os.queueEvent("peripheral_detach", side)
      n.flush()
    end
    return m
  end
  return n, machine
end

local function screen(m)
  local rows = {}
  for y = 1, 19 do rows[y] = m.screen[y] or "" end
  return table.concat(rows, "\n")
end
local function alive(m) assert(m.alive(), tostring(m.error)) end
local function boot(n, m, program) m.boot(program); n.flush(); alive(m) end
local function pair(n, s, c)
  s.env.os.queueEvent("key", 25, false); n.flush()
  local code
  for i = #s.log, 1, -1 do code = s.log[i]:match("Pair code: (%d+)"); if code then break end end
  assert(code, "missing pairing invitation")
  for ch in code:gmatch(".") do c.env.os.queueEvent("char", ch); n.flush() end
  n.advance(1)
  alive(s); alive(c)
  assert(c.files["so-keys"], "display did not pair over wireless")
  assert(s.env.SO.pair.key(c.id), "server did not save paired display")
end
local function last(m, kind)
  for i = #m.sent, 1, -1 do
    local sent = m.sent[i]
    if type(sent.payload) == "table" and sent.payload.t == kind then return sent end
  end
end

return function(test, equal)
  test("server drops invalid stored keys and refuses their frames without crashing", function()
    local n, machine = network()
    local s = machine(1, true, true)
    local good = string.rep("AB", 32)
    local keys = { ["2"] = "zz", ["3"] = string.rep("g", 64), ["4"] = "aa",
      ["5"] = string.rep("a", 63), ["6"] = string.rep("a", 66), ["7"] = false,
      ["8"] = 123, ["9"] = {}, ["10"] = good }
    s.files["so-keys"] = H.encode({schema = 1, generation = 1, value = {keys = keys}})
    boot(n, s, "so-server.lua")
    for id = 2, 9 do equal(s.env.SO.pair.key(id), nil) end
    equal(s.env.SO.pair.key(10), good)
    local notices = 0
    for _, line in ipairs(s.env.SO.terminal.log) do
      if line:find("ignored invalid stored keys", 1, true) then notices = notices + 1 end
      assert(not line:find("zz", 1, true), "log exposed an invalid key")
      assert(not line:find(good, 1, true), "log exposed a valid key")
    end
    equal(notices, 1)
    s.env.os.queueEvent("rednet_message", 2, {v = 1, t = "hello", rid = "bad-stored-key",
      from = 2, at = s.env.os.epoch("utc"), body = {}, mac = string.rep("0", 64)}, "so")
    n.flush(); alive(s)
    equal(last(s, "pair.required").id, 2)
    s.env.os.queueEvent("key", 25, false); n.flush()
    assert(s.env.SO.pair.pending(), "server stopped handling events after refusal")
  end)

  test("server refuses a malformed key at the MAC check without crashing", function()
    local n, machine = network()
    local s = machine(1, true, true)
    boot(n, s, "so-server.lua")
    local proto = s.env.dofile("so-proto.lua")
    local msg = {v = 1, t = "hello", rid = "bad-memory-key", from = 2,
      at = s.env.os.epoch("utc"), body = {}, mac = string.rep("0", 64)}
    for _, key in ipairs({"zz", string.rep("g", 64), "aa", string.rep("a", 63),
      string.rep("a", 66), false, 123, {}}) do
      equal(proto.macOk(key, msg), false)
    end
    assert(s.env.SO.pair.remember(2, "zz"))
    s.env.os.queueEvent("rednet_message", 2, msg, "so")
    n.flush(); alive(s)
    equal(last(s, "pair.required").id, 2)
  end)

  test("server and display pair with a wired modem before wireless", function()
    local n, machine = network()
    local s, c = machine(1, true, true), machine(2, false, true)
    boot(n, s, "so-server.lua"); boot(n, c, "display.lua")
    pair(n, s, c)
    equal(last(c, "hello").id, s.id)
    assert(last(s, "view.frame"), "paired display did not receive a frame")
  end)

  for _, target in ipairs({"server", "display"}) do
    test(target .. " opens a wireless modem attached after boot and after detach", function()
      local n, machine = network()
      local s = machine(1, true, target ~= "server")
      local c = machine(2, false, target ~= "display")
      boot(n, s, "so-server.lua"); boot(n, c, "display.lua")
      local changed = target == "server" and s or c
      changed.attach("left")
      n.advance(31)
      pair(n, s, c)
      changed.detach("left")
      n.advance(12)
      s.sent, c.sent, c.received = {}, {}, {}
      changed.attach("right")
      n.advance(31)
      alive(s); alive(c)
      local frame
      for _, received in ipairs(c.received) do
        if received.payload.t == "view.frame" then frame = received.payload end
      end
      assert(frame, "wireless traffic did not recover after modem replacement")
      c.env.os.queueEvent("char", "x"); c.env.os.queueEvent("key", 257); n.flush()
      equal(last(c, "input").id, s.id, "display did not send input after modem replacement")
    end)
  end

  test("server boots without modems and pairs after a wireless attachment", function()
    local n, machine = network()
    local s, c = machine(1, true, false), machine(2, false, true)
    s.devices.back = nil
    boot(n, s, "so-server.lua"); boot(n, c, "display.lua")
    s.attach("right"); n.advance(31)
    pair(n, s, c)
    assert(last(s, "view.frame"), "server did not serve display after first modem attachment")
  end)

  test("hostname collision keeps server running and identifies the other host", function()
    local n, machine = network()
    local other, s = machine(81, true, true), machine(1, true, true)
    other.devices.back, s.devices.back = nil, nil
    boot(n, other, "so-server.lua")
    boot(n, s, "so-server.lua")
    n.advance(3); alive(s)
    local output = screen(s)
    assert(output:find("81", 1, true), "hostname error did not name host 81: " .. output)
    assert(output:lower():find("host", 1, true), "hostname error missing: " .. output)
    s.env.os.queueEvent("key", 25, false); n.flush()
    assert(s.env.SO.pair.pending(), "server stopped handling pairing after collision")
    assert(screen(s):find("81", 1, true), "pairing prompt hid hostname warning")
  end)

  for _, discovery in ipairs({"other host", "no host", "backup keys"}) do
    test("paired display boots with " .. discovery .. " and uses its saved server", function()
      local n, machine = network()
      local s, c = machine(1, true, true), machine(2, false, true)
      s.devices.back, c.devices.back = nil, nil
      boot(n, s, "so-server.lua"); boot(n, c, "display.lua"); pair(n, s, c)
      if discovery ~= "no host" then
        local other = machine(81, true, true)
        other.env.rednet.open("left")
        n.hosts.so.server = other.id
      else n.hosts.so.server = nil end
      if discovery == "backup keys" then
        c.files["so-keys.bak"], c.files["so-keys"] = c.files["so-keys"], nil
      end
      c.co, c.inbox, c.timers, c.sent = nil, {}, {}, {}
      s.sent = {}
      boot(n, c, "display.lua"); n.advance(2)
      local hello, sub = last(c, "hello"), last(c, "view.sub")
      assert(hello and sub, "paired display did not reconnect without hostname discovery")
      equal(hello.id, s.id); equal(sub.id, s.id)
      assert(last(s, "view.frame"), "paired server did not authenticate restarted display")
      for _, sent in ipairs(c.sent) do equal(sent.id, s.id, "display contacted an unpaired server") end
    end)
  end
end
