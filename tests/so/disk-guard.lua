local H = dofile("tests/so/harness.lua")

local function install(machine, files)
  machine.install(files)
  for _, name in ipairs({"x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing"}) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local file = assert(io.open(path, "rb"))
    machine.files[path] = file:read("*a")
    file:close()
  end
end

local function setup(w, h, existing)
  local net = existing and existing.net or H.new()
  local server = existing and existing.server or net.machine({id=1, modem=true})
  if not existing then
  install(server, {"so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-log.lua",
    "so-plan.lua", "so-mine-plan.lua", "so-lumber-plan.lua", "so-mod-state.lua", "so-mod-display.lua",
    "so-mod-drops.lua", "so-mod-mine.lua", "so-mod-lumber.lua", "so-mod-shop.lua", "so-mod-ar.lua",
    "so-mod-cells.lua", "so-mod-lease.lua"})
  server.files["so-server.cfg"] = H.encode({pos={dim="minecraft:overworld", x=0, y=64, z=0}})
  server.boot("so-server.lua")
  net.flush()
  assert(not server.error, tostring(server.error))
  end
  local client = net.machine({id=existing and 3 or 2, modem=true, monitor=w==29, width=w, height=h, capacity=1000000})
  install(client, {"display.lua", "so-proto.lua", "so-pair.lua", "so-store.lua"})
  client.env.term.write = function(text)
    local x, y = client.cx or 1, client.cy or 1
    local row = (client.screen[y] or "") .. string.rep(" ", w)
    client.screen[y] = (row:sub(1, x-1) .. text .. row:sub(x+#text)):sub(1, w)
    client.cx = x + #text
  end
  local key = string.rep("a", 64)
  assert(server.env.SO.pair.remember(client.id, key))
  client.files["so-keys"] = H.encode({schema=1, generation=1, value={keys={["1"]=key}}})
  client.boot("display.lua")
  net.flush()
  net.advance(2)
  local function frame()
    assert(not server.error, tostring(server.error))
    assert(not client.error, tostring(client.error))
    for i=#server.sent,1,-1 do
      local packet = server.sent[i]
      if packet.id==client.id and packet.payload.t=="view.frame" then return packet.payload.body end
    end
    error("display received no frame")
  end
  local function button(label)
    local picture = frame()
    for _, b in ipairs(picture.buttons) do
      if b.label==label and b.x>=1 and b.y>=1 and b.y<=h and b.x+b.w-1<=w and #b.label<=b.w then
        assert((client.screen[b.y] or ""):sub(b.x,b.x+#label-1)==label, label .. " is overwritten")
        for _, other in ipairs(picture.buttons) do
          if other~=b and other.y==b.y then
            assert(b.x+b.w<=other.x or other.x+other.w<=b.x, label .. " overlaps another button")
          end
        end
        return b
      end
    end
    error("no visible " .. label .. " button on " .. picture.role .. " at " .. w .. "x" .. h)
  end
  local function press(label)
    local b = button(label)
    client.inbox[#client.inbox+1] = table.pack(w==29 and "monitor_touch" or "mouse_click",
      w==29 and "monitor" or 1, b.x, b.y)
    net.flush()
  end
  local function typeText(text)
    for ch in text:gmatch(".") do client.inbox[#client.inbox+1] = table.pack("char", ch) end
    client.inbox[#client.inbox+1] = table.pack("key", 28)
    net.flush()
  end
  local function assign(role)
    assert(server.env.SO.mods.display.command(client.id .. " " .. role))
    net.advance(1)
  end
  return {net=net, server=server, client=client, frame=frame, button=button, press=press, typeText=typeText, assign=assign}
end

local function stateFixture()
  local net = H.new()
  local m = net.machine({id=1, directories=true})
  m.install({"so-store.lua", "so-log.lua", "so-errors.lua", "so-mod-state.lua"})
  m.env.SO = {mods={}, now=function() return net.time end, breathe=function() end,
    store=m.env.dofile("so-store.lua")}
  return m.env.dofile("so-mod-state.lua"), m, net
end

local function fill(m, ratio)
  m.files.ballast = nil
  local used = 0
  for _, bytes in pairs(m.files) do used = used + #bytes end
  m.files.ballast = string.rep("x", math.max(0, math.floor(m.capacity * ratio) - used))
end

return function(test)
  test("error summary groups alternating repeats with counts and first and last times", function()
    local _, m, net = stateFixture()
    local function open()
      return m.env.dofile("so-errors.lua").open(m.env.SO.store, function() return net.time end)
    end
    local errors = open()
    assert(#errors.summary() == 0)
    for i, text in ipairs({"alpha", "beta", "alpha", "beta", "alpha"}) do
      net.time = i * 10
      assert(errors.record(text))
    end
    local files = {}
    for path, text in pairs(m.files) do files[path] = text end
    local function check(log)
      local groups = log.summary()
      assert(#groups == 2)
      assert(groups[1].text == "alpha" and groups[1].count == 3 and groups[1].first == 10 and groups[1].last == 50)
      assert(groups[2].text == "beta" and groups[2].count == 2 and groups[2].first == 20 and groups[2].last == 40)
      groups[1].count, groups[1].text = 999, "changed"
      assert(log.summary()[1].count == 3 and log.entries()[1].text == "alpha")
      assert(#log.entries() == 5)
    end
    check(errors)
    assert(errors.status().pending)
    for path, text in pairs(m.files) do assert(files[path] == text, "summary wrote " .. path) end
    for path, text in pairs(files) do assert(m.files[path] == text, "summary removed " .. path) end
    net.time = 30010
    assert(errors.flush())
    check(open())
  end)
  test("error summary counts only entries still retained in the ring", function()
    local _, m, net = stateFixture()
    local errors = m.env.dofile("so-errors.lua").open(m.env.SO.store, function() return net.time end)
    for i = 1, 130 do net.time = i assert(errors.record("repeat")) end
    local groups = errors.summary()
    assert(#groups == 1 and groups[1].count == 128 and groups[1].first == 3 and groups[1].last == 130)
    assert(errors.status().count == 128)
  end)
  test("retained log range survives pruning and restart including fallback segments", function()
    local net = H.new()
    local m = net.machine({id=1, directories=true})
    m.install({"so-store.lua", "so-log.lua"})
    local store = m.env.dofile("so-store.lua")
    local function open() return m.env.dofile("so-log.lua").open(store) end
    local function bounds(log, first, last)
      local status = log.status()
      assert(status.oldestSeq == first and status.oldestAt == 1000 + first)
      assert(status.newestSeq == last and status.newestAt == 1000 + last)
    end
    local log = open()
    assert(log.status().oldestSeq == nil and log.status().oldestAt == nil)
    assert(log.status().newestSeq == nil and log.status().newestAt == nil)
    for i = 1, 26 do
      assert(log.append({kind="range", at=1000+i, data=string.rep("x", 50000)}))
      if i == 22 then
        bounds(log, 1, 22)
        assert(log.checkpoint({values={}, machines={}}))
        bounds(log, 1, 22)
      end
    end
    bounds(log, 1, 26)
    assert(log.checkpoint({values={}, machines={}}))
    local previous = store.store("so-data/snap/000001", function() return true end).value.first
    local latest = store.store("so-data/snap/000002", function() return true end).value.first
    assert(previous > 1 and latest > previous)
    assert(not m.files["so-data/log/000001"])
    bounds(log, previous, 26)
    local status = log.status()
    status.oldestSeq = 999
    bounds(log, previous, 26)
    log = open()
    assert(log.events()[1].seq == latest)
    bounds(log, previous, 26)
    assert(log.checkpoint({values={}, machines={}}))
    bounds(log, latest, 26)
    bounds(open(), latest, 26)
  end)
  test("state diagnostics expose retained sequence and UTC time bounds", function()
    local s, _, net = stateFixture()
    assert(s.diagnostics().oldestSeq == nil and s.diagnostics().newestSeq == nil)
    assert(s.emit("range", 1))
    net.time = net.time + 1234
    assert(s.emit("range", 2))
    local entries, status = s.history.page({}).entries, s.diagnostics()
    assert(status.oldestSeq == entries[1].seq and status.oldestAt == entries[1].at)
    assert(status.newestSeq == entries[2].seq and status.newestAt == entries[2].at)
  end)
  test("disk warning starts at exactly 70% and job refusal starts at exactly 80%", function()
    for _, store in ipairs({{"log", "so-data/log/ballast"}, {"cells", "so-data/cells/ballast"}}) do
      local s, m = stateFixture()
      m.capacity = 1000000
      m.files[store[2]] = string.rep("x", 600000)
      for _, used in ipairs({699999, 700000, 720000, 799999, 800000, 820000, 849999, 850000}) do
        fill(m, used / m.capacity)
        s.tick()
        local disk, alert = s.disk(), s.get("disk.alert")
        assert(disk.used == used and disk.pressure == (used >= 850000))
        assert((alert ~= nil) == (used >= 700000))
        assert((#disk.alerts > 0) == (used >= 800000))
        if disk.pressure then
          assert(alert.text == "DISK pressure", alert.text)
        elseif alert then
          assert(alert.text == string.format("DISK %.0f%%: %s 0.6 MB", used / 10000, store[1]), alert.text)
        end
        local ok, reason = s.canStart()
        assert(ok == (used < 800000))
        if not ok then
          assert(reason == string.format("disk %.0f%%: %s 0.6 MB", used / 10000, store[1]), reason)
        end
        assert(s.job({name="threshold"}) == (used < 800000))
        assert(s.canWork(), "disk warning blocked recovery work")
      end
      fill(m, 0.699999)
      s.tick()
      assert(s.get("disk.alert") == nil and #s.disk().alerts == 0 and s.canStart())
    end
  end)
  test("disk refusal names the largest measured store", function()
    for _, store in ipairs({{"log", "so-data/log/ballast"}, {"cells", "so-data/cells/ballast"}}) do
      local s, m = stateFixture()
      m.capacity = 8000000
      m.files[store[2]] = string.rep("x", 6100000)
      fill(m, 0.83)
      local ok, text = s.canStart()
      assert(not ok and text == "disk >=80%; free space", tostring(text))
      s.tick()
      ok, text = s.canStart()
      assert(not ok and text == "disk 83%: " .. store[1] .. " 6.1 MB", tostring(text))
    end
  end)
  test("unreadable disk capacity names the cause and alerts after a ledger scan", function()
    for _, capacity in ipairs({false, 0, -1, "unknown"}) do
      local s, m = stateFixture()
      s.tick()
      assert(s.disk().scanned ~= nil)
      local getCapacity = m.env.fs.getCapacity
      m.env.fs.getCapacity = function() return capacity or nil end
      assert(not s.disk().accepting)
      local ok, reason = s.canStart()
      assert(not ok and reason == "disk size unknown", tostring(reason))
      s.tick()
      assert(s.get("disk.alert").text == "DISK size unknown")
      assert(not s.job({name="blocked"}))
      assert(#s.history.page({}).entries == 0)
      m.env.fs.getCapacity = getCapacity
      s.tick()
      assert(s.canStart())
      assert(s.get("disk.alert") == nil)
    end
  end)
  test("disk reuses the ledger for thirty seconds when stores exceed capacity", function()
    local s, m, net = stateFixture()
    m.files["so-data/log/ballast"] = string.rep("x", 200000)
    s.tick()
    m.capacity = 100000
    local list, scans = m.env.fs.list, 0
    m.env.fs.list = function(path)
      if path == "/" then
        scans = scans + 1
        assert(scans <= 2, "disk ledger rescanned more than once per interval")
      end
      return list(path)
    end
    local function pressure()
      local disk = s.disk()
      assert(disk.pressure and not disk.accepting and disk.ratio >= 1)
      assert(disk.stores.log == 200000 and disk.stores.other == 0)
    end
    pressure()
    assert(scans == 0)
    net.time = net.time + 30000
    pressure()
    assert(scans == 1)
    for i = 1, 5 do
      pressure()
      assert(not s.canStart())
      assert(s.emit("probe", i))
      s.handlers.hello({from=2, body={role="worker", journal="same", fuel=1000}})
    end
    assert(scans == 1)
    net.time = net.time + 29999
    pressure()
    assert(scans == 1)
    net.time = net.time + 1
    pressure()
    assert(scans == 2)
  end)
  test("oversize refusal alerts without blocking healthy writes", function()
    local s, m = stateFixture()
    local ok, err = s.emit("huge", string.rep("x", 70000))
    assert(not ok and err:find("refused", 1, true))
    assert(s.get("huge") == nil and #s.history.page({}).entries == 0)
    assert(s.get("disk.alert").error == "event exceeds log budget")
    assert(m.log[#m.log]:find("DISK event refused", 1, true))
    assert(s.disk().pending == 0 and s.disk().error == nil)
    assert(s.canStart() and s.canWork())
  end)
  test("oversize refusal preserves an existing write failure", function()
    local s, m = stateFixture()
    m.capacity = 50000
    fill(m, 0.99)
    assert(s.emit("queued", 1))
    local err = s.disk().error
    assert(err and not s.canWork())
    assert(not s.emit("huge", string.rep("x", 70000)))
    assert(s.disk().error == err and s.disk().pending == 1)
    assert(not s.canStart() and not s.canWork())
  end)
  test("pressure preserves label and significant fuel changes", function()
    local s, m, net = stateFixture()
    local function hello(label, fuel)
      s.handlers.hello({from=2, body={role="worker", journal="j", label=label, fuel=fuel}})
    end
    hello("before", 1000)
    fill(m, 0.9)
    local count = #s.history.page({}).entries
    net.time = net.time + 1000
    hello("before", 1000)
    assert(#s.history.page({}).entries == count)
    assert(s.get("machines/2/seen") == net.time)
    hello("after", 1000)
    assert(s.get("machines/2/label") == "after")
    assert(#s.history.page({}).entries == count + 1)
    for _, fuel in ipairs({1500, 0}) do
      hello("after", fuel)
      count = count + 1
      assert(s.get("machines/2/fuel") == fuel)
      assert(#s.history.page({}).entries == count + 1)
    end
  end)
  test("history device filter combines with cursors and kind filters", function()
    local s = stateFixture()
    for _, event in ipairs({
      {"machine", {id=2}}, {"note", false}, {"mine.alert", {id=3}},
      {"mine.alert", {id=2}}, {"mine.alert", {id=3}}, {"machine", {id=2}},
      {"mine.alert", {id=2}}, {"note", "plain"}, {"note", {id=0}},
    }) do assert(s.emit(event[1], event[2])) end
    local page = s.history.page({id=2, count=2})
    assert(#page.entries == 2 and page.entries[1].seq == 1 and page.entries[2].seq == 4 and page.next == 4)
    page = s.history.page({id=2, from=page.next, count=2})
    assert(#page.entries == 2 and page.entries[1].seq == 6 and page.entries[2].seq == 7 and page.next == nil)
    page = s.history.page({id=2, alerts=true, reverse=true, limit=1})
    assert(#page.entries == 1 and page.entries[1].seq == 7 and page.next == 7)
    page = s.history.page({id=2, kind="mine.alert", reverse=true, before=page.next, count=1})
    assert(#page.entries == 1 and page.entries[1].seq == 4 and page.next == nil)
    assert(#s.history.page({id=99}).entries == 0)
    assert(#s.history.page({id=0}).entries == 1)
    assert(#s.history.page({}).entries == 9)
  end)
  for _, size in ipairs({{26,20}, {29,12}}) do
    for _, role in ipairs({"mining", "lumber"}) do
      test(role .. " refuses start at 80% and resumes below it on " .. size[1] .. "x" .. size[2], function()
        local s = setup(size[1], size[2])
        s.assign(role)
        if role == "mining" then
          s.typeText("home 0 64 0 n")
        else
          s.typeText("area 0 0 2 2 64")
          s.typeText("add 3 0 65 0 n")
        end
        local key=string.rep("b",64)
        assert(s.server.env.SO.pair.remember(3,key))
        local worker=s.net.machine({id=3,modem=true,turtle=true,x=0,y=65,z=0,fuel=4000,capacity=1000000})
        install(worker,{"worker.lua","so-store.lua","so-pair.lua","so-proto.lua"})
        worker.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
        worker.boot("worker.lua") s.net.flush()
        if role=="mining" then s.typeText("add 3 0 65 0 n")
        else s.typeText("saplings -3 64 0 down") end
        assert(s.server.env.SO.mods.drops.add({id="ready",dim=0,x=-2,y=64,z=0,side="down",kind="any"}))
        s.net.advance(2)
        local path = role == "mining" and "so-data/mine/job" or "so-data/lumber/job"
        local function job()
          return s.server.env.SO.store.store(path, function() return true end).value
        end
        local function fill(ratio)
          s.server.files.ballast = nil
          local used = 0
          for _, bytes in pairs(s.server.files) do used = used + #bytes end
          s.server.files.ballast = string.rep("x", math.floor(s.server.capacity * ratio) - used)
        end
        local function screenHas(text)
          for _, line in pairs(s.client.screen) do if line:find(text, 1, true) then return true end end
          return false
        end
        for _, ratio in ipairs({0.8, 0.9}) do
          fill(ratio)
          s.typeText("start")
          s.net.advance(2)
          assert(not job() or not job().running, "started above disk threshold")
          assert(screenHas("disk " .. math.floor(ratio * 100) .. "%: other"), "disk refusal is not visible")
          assert(not s.server.env.SO.mods.state.canStart())
          assert(not s.server.env.SO.mods.state.job({name="blocked"}))
        end
        local opened, capture, reason = pcall(io.open,
          "tests/evidence/disk-guard/" .. role .. "-" .. size[1] .. "x" .. size[2] .. ".txt", "w")
        if opened then
          assert(capture, reason)
          for y=1,size[2] do capture:write((s.client.screen[y] or ""):gsub("%s+$", ""), "\n") end
          capture:close()
        else
          assert(capture == "part tests cannot write host files", capture)
        end
        fill(0.79)
        assert(s.server.env.SO.mods.state.canStart())
        s.typeText("start")
        s.net.advance(2)
        assert(job().running, "did not resume below disk threshold")
        assert(not screenHas("%: other"), "stale disk warning")
        assert(s.server.env.SO.mods.state.job({name="accepted"}))
        fill(0.9)
        s.typeText("stop")
        assert(not job().running, "stop refused above threshold")
      end)
    end
  end
end
