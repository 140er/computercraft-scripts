return function(test, equal, read, mocks)
  local roles = dofile("roles.lua")
  local function bytes(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return #text, text
  end
  local original = { "miner.lua", "hub.lua", "server.lua", "store.lua", "sorter.lua", "roomsorter.lua",
    "factory.lua", "lumber.lua", "builder.lua", "lava.lua", "farmer.lua", "buddy.lua", "smartmine.lua",
    "relay.lua", "gpshost.lua", "panel.lua", "fleetview.lua", "update.lua", "install.lua", "atomic.lua",
    "ssot.lua", "ssot-client.lua", "nav.lua", "mine-tasks.lua", "mining.lua", "warehouse-tasks.lua",
    "warehouse.lua" }

  test("the 27 scripts are the measured catalog and both shelves fit a million bytes", function()
    local baseline, seen = 0, {}
    for _, name in ipairs(original) do
      local blob = os.tmpname()
      assert(os.execute("git show main:" .. name .. " > " .. blob), name)
      local handle = assert(io.open(blob, "rb"))
      local text = handle:read("*a")
      handle:close()
      os.remove(blob)
      baseline = baseline + #text
      seen[name] = true
    end
    equal(baseline, 977085)
    local catalog = roles.catalog()
    for _, name in ipairs(catalog) do seen[name] = seen[name] or false end
    for _, name in ipairs(original) do assert(seen[name] == true, name) end
    local extra = {}
    for _, name in ipairs(catalog) do
      if seen[name] == false then extra[#extra + 1] = name end
    end
    table.sort(extra)
    equal(extra, { "mirror.lua", "roles.lua", "shelf.lua" })
    local function sizeOf(name)
      local n = bytes(name)
      return n
    end
    assert(roles.fit("fleet", sizeOf, 1000000))
    assert(roles.fit("yard", sizeOf, 1000000))
    local union = 0
    for _, name in ipairs(original) do union = union + select(1, bytes(name)) end
    union = union + select(1, bytes("roomsorter.lua"))
    assert(union > 1000000, "full catalog plus roomsorter staging is " .. union)
    local hubOn, hubBytes = roles.resident("hub", true), 0
    for _, name in ipairs(hubOn) do
      assert(name ~= "miner.lua")
      hubBytes = hubBytes + select(1, bytes(name))
    end
    assert(hubBytes <= 158575, "hub program is " .. hubBytes)
    local hubOff, sawMiner, sawSsot = roles.resident("hub", false), false, false
    for _, name in ipairs(hubOff) do
      if name == "miner.lua" then sawMiner = true end
      if name == "ssot.lua" then sawSsot = true end
    end
    assert(sawMiner and not sawSsot)
  end)

  test("a second dofile returns the same mount and the same reserve", function()
    local m = mocks.new(false)
    m.capacity = 1000000
    local first = m.env.dofile("atomic.lua")
    local second = m.env.dofile("atomic.lua")
    assert(first == second)
    assert(rawget(m.env, "atomicBox") == nil)
    first.mount("/"):open("pose.control", function(v) return type(v) == "table" end,
      { class = "control", limit = 32768 })
    equal(second.mount("/"):reserve(), 32768 + 8192)
  end)

  test("a failed slot write keeps the previous value and the same handle saves the next one", function()
    local function trial(failure)
      local m = mocks.new(false)
      m.capacity = 1000000
      local A = m.env.dofile("atomic.lua")
      local rec = A.mount("/"):open("sample.state", function(v) return type(v) == "table" and type(v.n) == "number" end,
        { class = "bulk", limit = 900000 })
      assert(rec:save({ n = 1 }))
      equal(rec.value.n, 1)
      local open = m.env.fs.open
      m.env.fs.open = function(path, mode)
        if path == "sample.state.b" and mode == "w" and failure == "open" then return nil end
        local h = open(path, mode)
        if path == "sample.state.b" and mode == "w" and (failure == "write" or failure == "close") then
          h[failure] = function() error(failure .. " failed") end
        end
        if path == "sample.state.b" and mode == "r" and failure == "read" then
          h.readAll = function() return "broken" end
        end
        return h
      end
      local ok, err = rec:save({ n = 2 })
      equal(ok, false)
      equal(err, "save")
      equal(rec.value.n, 1)
      local again = A.mount("/"):open("sample.state", function(v) return type(v) == "table" and type(v.n) == "number" end,
        { class = "bulk", limit = 900000 })
      equal(again.value.n, 1)
      m.env.fs.open = open
      assert(rec:save({ n = 3 }))
      equal(rec.value.n, 3)
      equal(A.mount("/"):open("sample.state", function(v) return type(v) == "table" end,
        { class = "bulk", limit = 900000 }).value.n, 3)
    end
    for _, failure in ipairs({ "open", "write", "close", "read" }) do trial(failure) end
  end)

  test("free space held at the reserve still stores a pose and answers reserve", function()
    local m = mocks.new(false)
    m.capacity = 1000000
    m.holdFree = 32768 + 8192
    local A = m.env.dofile("atomic.lua")
    local disk = A.mount("/")
    local pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 }
    local control = disk:open("pose.control", function(v) return type(v) == "table" end, { class = "control", limit = 32768 })
    local map = disk:open("pose.map", function(v) return type(v) == "table" end, { class = "bulk", limit = 900000, anchor = "pose.control" })
    assert(control:save({ pose = pose, token = "held" }))
    assert(map:save({ cells = { { name = "minecraft:stone" } } }) == false)
    assert(control.value.token == "held")
    assert(control:save({ pose = pose, token = "r1" }))
    assert(control.value.token == "r1")
  end)

  test("server and update take script names from roles", function()
    local update = read("update.lua")
    assert(not update:find("local KNOWN", 1, true))
    assert(not update:find("local ALSO", 1, true))
    local server = read("server.lua")
    assert(server:find("codeShelf", 1, true))
    assert(not server:find("local KNOWN", 1, true))
    assert(not server:find("local ALSO", 1, true))
  end)

  test("a fleet mirror serves the miner program once and each role hello fits", function()
    local host, client = mocks.new(false), mocks.new(false)
    host.env.os.getComputerID = function() return 1 end
    client.env.os.getComputerID = function() return 2 end
    local mail = { [1] = {}, [2] = {} }
    local function arm(m, id)
      m.env.rednet.host = function() end
      m.env.rednet.open = function() end
      m.env.rednet.lookup = function(_, name) if name == "fleet" then return 1 end end
      m.env.peripheral.find = function() return { isWireless = function() return true end } end
      m.env.peripheral.getName = function() return "radio" end
      m.env.rednet.send = function(to, msg, proto)
        local box = mail[to]
        box[#box + 1] = { from = id, msg = msg, proto = proto }
      end
      m.env.rednet.receive = function(proto)
        while true do
          local box = mail[id]
          if #box > 0 then
            local item = table.remove(box, 1)
            if not proto or item.proto == proto then return item.from, item.msg, item.proto end
          else
            coroutine.yield("mail")
          end
        end
      end
    end
    arm(host, 1)
    arm(client, 2)
    local programs = roles.program("miner")
    local bodies = {}
    for _, name in ipairs(programs) do
      local n, text = bytes(name)
      bodies[name] = text
      host.files[name] = text
      assert(n > 0)
    end
    local function sizeOf(name)
      local text = host.files[name]
      return text and #text or 0
    end
    client.files["shelf.cfg"] = mocks.encode({ v = 1, codeShelf = true, shelf = "fleet" })
    local shelfHost = host.env.dofile("shelf.lua")
    local shelfClient = client.env.dofile("shelf.lua")
    local hostThread = coroutine.create(function()
      shelfHost.host({ name = "fleet", roles = roles, sizeOf = sizeOf })
    end)
    local fetched, writes = {}, 0
    local oldOpen = client.env.fs.open
    client.env.fs.open = function(path, mode)
      if mode == "w" then writes = writes + 1 end
      return oldOpen(path, mode)
    end
    local clientThread = coroutine.create(function()
      for _, name in ipairs(programs) do
        local text, err = shelfClient.fetch(name)
        assert(text == bodies[name], name .. " " .. tostring(err))
        assert(client.env.dofile("atomic.lua").replaceBytes(name, text, function(s) return s == text end))
        fetched[name] = true
      end
      local secondWrites = writes
      for _, name in ipairs(programs) do
        local text, err = shelfClient.fetch(name)
        assert(text == nil and err == "current", name .. " " .. tostring(text) .. " " .. tostring(err))
      end
      equal(writes, secondWrites)
    end)
    for _ = 1, 400 do
      if coroutine.status(hostThread) == "suspended" then assert(coroutine.resume(hostThread)) end
      if coroutine.status(clientThread) == "suspended" then
        local ok, err = coroutine.resume(clientThread)
        assert(ok, err)
      end
      if coroutine.status(clientThread) == "dead" then break end
    end
    equal(coroutine.status(clientThread), "dead")
    assert(not fetched["roomsorter.lua"])
    local function helloBytes(roleName)
      mail[1] = { { from = 2, msg = { type = "hello", role = roleName, rid = 7 }, proto = "codeshelf" } }
      mail[2] = {}
      local ok, err = coroutine.resume(hostThread)
      assert(ok, err)
      local reply = assert(mail[2][1], roleName)
      local text = host.env.textutils.serialize(reply.msg)
      assert(#text <= 8192, roleName .. " hello is " .. #text)
    end
    for _, name in ipairs(roles.shelves.fleet) do helloBytes(name) end
    for _, name in ipairs(roles.shelves.yard) do
      local role = roles.roles[name]
      local files = {}
      for _, file in ipairs(role.program) do
        local n = select(1, bytes(file))
        files[file] = { hash = "0123abcd", size = n }
      end
      local reply = { type = "shelf", name = "yard", role = name, program = role.program, serves = {}, files = files }
      local text = host.env.textutils.serialize(reply)
      assert(#text <= 8192, name .. " hello is " .. #text)
    end
  end)
end
