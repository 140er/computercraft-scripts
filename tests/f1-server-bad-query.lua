return function(test, equal, read, mocks)
  local function decode(s) return assert(load("return " .. s, "=mock", "t", {}))() end
  local function machine()
    local m = mocks.new(false)
    m.files["views.cfg"] = mocks.encode({ enabled = false })
    m.files["ssot.lua"] = read("ssot.lua")
    m.files["atomic.lua"] = read("atomic.lua")
    m.files["update.lua"] = read("update.lua")
    m.files["ssot.cfg"] = '{controllers={["7"]="test-secret-123456"}}'
    local env = m.env
    env.fs.delete = function(path) m.files[path] = nil end
    env.fs.move = function(a, b) assert(m.files[a]) m.files[b], m.files[a] = m.files[a], nil end
    env.fs.makeDir = function() end
    env.textutils.unserialize = function(s)
      local f = load("return " .. s, "=state", "t", {})
      if f then local ok, t = pcall(f) if ok then return t end end
    end
    env.http = nil
    env.write = env.print
    env.sleep = function(delay)
      local timer = env.os.startTimer(delay)
      repeat local _, id = env.os.pullEvent("timer") until id == timer
    end
    env.rednet.receive = function(protocol, timeout)
      local timer = timeout and env.os.startTimer(timeout)
      while true do
        local ev, id, msg, proto = env.os.pullEvent()
        if ev == "rednet_message" and (not protocol or proto == protocol) then return id, msg, proto end
        if ev == "timer" and id == timer then return nil end
      end
    end
    m.sent = {}
    local send = env.rednet.send
    env.rednet.send = function(id, msg, proto)
      if m.failRid and type(msg) == "table" and msg.rid == m.failRid then
        m.failRid = nil
        error("forced query failure")
      end
      m.sent[#m.sent + 1] = { id = id, msg = decode(mocks.encode(msg)), proto = proto }
      send(id, msg, proto)
    end
    function m.request(msg, id)
      local before = #m.sent
      m.push("rednet_message", id or 7, msg, "fleetserver")
      return #m.sent > before and m.sent[#m.sent].msg or nil
    end
    m.env.dofile = function(path) return assert(loadfile(path, "t", m.env))() end
    return m
  end

  local function ssot(op, rid, counter, extra)
    local msg = { type = "ssot", v = 1, op = op, boot = "f1-boot", rid = rid,
      counter = counter, expect = "ssot_reply", secret = "test-secret-123456" }
    for key, value in pairs(extra or {}) do msg[key] = value end
    return msg
  end

  test("a bad query does not stop the server from answering the next get", function()
    local m = machine()
    m.start(read("server.lua"))
    local unknown = m.request(ssot("not-an-op", "bad-op", 1))
    assert(type(unknown) == "table" and unknown.type == "ssot_reply" and unknown.rid == "bad-op",
      "unknown op got no reply")
    equal(unknown.ok, false)
    local before = #m.sent
    local malformed = m.request({ type = "ssot", body = "malformed" })
    assert(malformed == nil or (type(malformed) == "table" and malformed.ok == false),
      "malformed table killed the server")
    equal(#m.sent >= before, true)
    local locations = m.request(ssot("wh2-get", "bad-loc", 2, { body = { wh2 = 1, topic = "locations" } }))
    assert(type(locations) == "table" and locations.rid == "bad-loc", "locations query killed the server")
    equal(locations.ok, false)
    m.failRid = "explode"
    local exploded = m.request(ssot("not-an-op", "explode", 3))
    assert(type(exploded) == "table", "thrown request got no reply")
    equal(exploded.type, "ssot_reply")
    equal(exploded.v, 1)
    equal(exploded.rid, "explode")
    equal(exploded.ok, false)
    equal(exploded.auth, "test-secret-123456")
    equal(exploded.server, 99)
    assert(type(exploded.error) == "string" and exploded.error:find("forced query failure", 1, true),
      "thrown request was not answered\n" .. mocks.encode(exploded))
    local got = m.request({ type = "get", file = "update.lua", rid = "good-get" })
    assert(type(got) == "table" and got.type == "file" and got.file == "update.lua" and got.rid == "good-get",
      "valid get was not answered\n" .. mocks.encode(got))
    assert(got.error == nil, "valid get failed: " .. tostring(got.error))
    assert(type(got.code) == "string" and #got.code > 0, "valid get returned no code")
    local manifest = assert(loadfile("bundle-manifest.lua"))()
    local shipped = false
    for _, name in ipairs(manifest.roles.server.files) do
      if name == "wh2-locations.lua" then shipped = true end
    end
    assert(shipped, "server role bundle does not include wh2-locations.lua")
    local listed = false
    for _, name in ipairs(dofile("install-roles.lua").files("server")) do
      if name == "wh2-locations.lua" then listed = true end
    end
    assert(listed, "install role server does not include wh2-locations.lua")
  end)
end
