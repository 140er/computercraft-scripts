local harness = dofile("tests/so/harness.lua")

local MODS = { "so-proto.lua", "so-pair.lua", "so-store.lua", "so-log.lua", "so-mod-state.lua" }
local SERVER = {
  "so-proto.lua", "so-pair.lua", "so-store.lua", "so-server.lua", "so-log.lua",
  "so-mod-state.lua", "so-mod-cells.lua", "so-mod-display.lua", "so-mod-drops.lua",
}
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

local function lay(machine, paths)
  machine.install(paths)
  for i = 1, #LIB do
    local path = LIB[i]
    local handle = assert(io.open(path, "rb"))
    local data = handle:read("*a")
    handle:close()
    machine.files[path] = data
  end
end

local PREAMBLE = [[
SO = { now = function() return os.epoch("utc") end, mods = {} }
SO.store = dofile("so-store.lua")
SO.proto = dofile("so-proto.lua")
SO.pair = dofile("so-pair.lua")
SO.pair.open(SO.proto, SO.store)
state = dofile("so-mod-state.lua")
SO.mods.state = state
]]

local SHOT = [[
state.view("jobs", function(model) return model.jobs end)
PICTURE = {
  rev = state.view().rev,
  n = state.get("n"),
  mark = state.get("mark"),
  fuel = state.get("machines/4/fuel"),
  x = state.get("machines/4/pose/x"),
  facing = state.get("machines/4/pose/facing"),
  role = state.get("machines/4/role"),
  jobs = state.view.get({ name = "jobs" }).data,
  fleet = state.view.get({ name = "fleet" }).data,
  turtle = state.view.get({ name = "turtle/4" }).data,
  log = state.view.get({ name = "log" }).data,
  page = state.history.page({ from = 0, count = 2 }),
}
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
  local function logtext(machine)
    return table.concat(machine.log, "\n")
  end

  local function copyDisk(src, dest)
    for name, text in pairs(src.files) do dest.files[name] = text end
  end

  local function logBytes(files)
    local total = 0
    local biggest = 0
    for name, text in pairs(files) do
      if name:find("^so%-data/log/%d+$") then
        total = total + #text
        if #text > biggest then biggest = #text end
      end
    end
    return total, biggest
  end

  local function hasSnap(files)
    for name in pairs(files) do
      if name:find("^so%-data/snap/%d+$") then return true end
    end
    return false
  end

  test("restart after 5000 events restores the same state", function()
    local net = harness.new()
    local machine = net.machine({ id = 1, capacity = 16000000 })
    lay(machine, MODS)
    machine.spawn(PREAMBLE .. [[
      local i = 1
      while i <= 5000 do
        local ok, err
        if i == 10 then ok, err = state.emit("machine", { id = 4, role = "turtle", fuel = 40 })
        elseif i == 11 then ok, err = state.emit("pose", { id = 4, dim = "overworld", x = 8, y = 64, z = -3, facing = 1 })
        elseif i == 12 then ok, err = state.job({ name = "dig", at = 12 })
        elseif i == 2000 or i == 4000 then ok, err = state.emit("mark", i)
        else ok, err = state.emit("n", i) end
        if not ok then error(tostring(err) .. " at " .. i, 0) end
        i = i + 1
      end
    ]] .. SHOT .. "\nDONE = true\n")
    net.flush()
    assert(not machine.error, tostring(machine.error))
    assert(machine.env.DONE == true, "first boot did not finish")
    local picture = machine.env.PICTURE
    equal(picture.rev, 5000)
    equal(picture.n, 5000)
    equal(picture.mark, 4000)
    equal(picture.fuel, 40)
    equal(picture.x, 8)
    equal(picture.facing, 1)
    equal(picture.role, "turtle")
    equal(picture.jobs, { { name = "dig", at = 12 } })
    equal(picture.turtle.pose.z, -3)
    equal(#picture.fleet, 1)
    equal(#picture.log, 50)
    equal(picture.log[50].kind, "n")
    equal(picture.log[50].data, 5000)
    equal(picture.log[1].seq, 4951)
    equal(#picture.page.entries, 2)
    equal(picture.page.entries[1].seq, 1)
    assert(hasSnap(machine.files), "no snapshot after 5000 events")
    local bytes, biggest = logBytes(machine.files)
    assert(bytes <= 1048576, "raw log " .. bytes)
    assert(biggest <= 65536, "segment " .. biggest)

    local restarted = net.machine({ id = 9, capacity = 16000000 })
    lay(restarted, MODS)
    copyDisk(machine, restarted)
    restarted.spawn(PREAMBLE .. SHOT .. "\nDONE = true\n")
    net.flush()
    assert(not restarted.error, tostring(restarted.error))
    assert(restarted.env.DONE == true, "restart did not finish")
    equal(restarted.env.PICTURE, picture)
  end)

  test("a killed segment write loses only the event in that write", function()
    local net = harness.new()
    local machine = net.machine({ id = 1, capacity = 16000000 })
    lay(machine, MODS)
    machine.spawn(PREAMBLE .. [[
      local i = 1
      while i <= 30 do
        local ok, err = state.emit("k", i)
        if not ok then error(tostring(err), 0) end
        i = i + 1
      end
      DONE = true
    ]])
    net.flush()
    assert(not machine.error, tostring(machine.error))
    equal(machine.env.state.get("k"), 30)
    equal(machine.env.state.view().rev, 30)

    local opened = machine.env.fs.open
    local armed = true
    machine.env.fs.open = function(path, mode)
      local handle = opened(path, mode)
      if armed and mode == "w" and type(path) == "string" and path:find("%.tmp$", 1) then
        armed = false
        local write = handle.write
        handle.write = function(text)
          write(tostring(text):sub(1, 8))
          error("killed", 0)
        end
      end
      return handle
    end
    local ok, err = machine.env.state.emit("k", "lost")
    assert(ok == false, "killed write was stored")
    assert(type(err) == "string" and #err > 0, "missing error")
    equal(machine.env.state.get("k"), 30)
    equal(machine.env.state.view().rev, 30)

    local restarted = net.machine({ id = 6, capacity = 16000000 })
    lay(restarted, MODS)
    copyDisk(machine, restarted)
    restarted.spawn(PREAMBLE .. [[
      KEPT = state.get("k")
      REV = state.view().rev
      PAGE = state.history.page({ count = 50 })
      DONE = true
    ]])
    net.flush()
    assert(not restarted.error, tostring(restarted.error))
    assert(restarted.env.DONE == true, "restart did not finish")
    equal(restarted.env.KEPT, 30)
    equal(restarted.env.REV, 30)
    equal(#restarted.env.PAGE.entries, 30)
    equal(restarted.env.PAGE.entries[30].data, 30)
  end)

  test("disk at 80 percent raises the disk alert and refuses a new job", function()
    local net = harness.new()
    local machine = net.machine({ id = 1, capacity = 200000 })
    lay(machine, MODS)
    machine.spawn(PREAMBLE .. "\nDONE = true\n")
    net.flush()
    assert(not machine.error, tostring(machine.error))
    local function used()
      local total = 0
      for _, text in pairs(machine.files) do total = total + #text end
      return total
    end
    local cap = 200000
    machine.capacity = cap
    local want = math.floor(cap * 0.8) - 1
    local pad = want - used()
    assert(pad > 0, "pad")
    machine.files["pad"] = string.rep("x", pad)
    local below = machine.env.state.view.get({ name = "status" }).data
    equal(below.accepting, true)
    equal(below.alerts, {})
    local took, tookErr = machine.env.state.job({ name = "dig" })
    assert(took, tostring(tookErr))
    equal(machine.env.state.get("job").name, "dig")

    local rev = machine.env.state.view().rev
    machine.files["pad"] = string.rep("x", math.floor(cap * 0.8) - (used() - #machine.files["pad"]))
    local status = machine.env.state.view.get({ name = "status" }).data
    equal(status.accepting, false)
    equal(status.alerts, { "disk" })
    assert(status.ratio >= 0.8, tostring(status.ratio))
    local refused, why = machine.env.state.job({ name = "again" })
    assert(refused == false, "job accepted while the disk was full")
    equal(why, "disk")
    equal(machine.env.state.view().rev, rev)
    equal(machine.env.state.get("job").name, "dig")
    local still, stillErr = machine.env.state.emit("note", "kept")
    assert(still, tostring(stillErr))
    equal(machine.env.state.get("note"), "kept")
    equal(machine.env.state.view().rev, rev + 1)
  end)

  test("a subscriber gets increasing revs and at most 2 frames per second", function()
    local net = harness.new()
    local machine = net.machine({ id = 1, capacity = 16000000 })
    lay(machine, MODS)
    machine.spawn(PREAMBLE .. [[
      got = {}
      state.view.sub({ name = "log", notify = function(frame) got[#got + 1] = frame end })
      assert(state.emit("k", 1))
      assert(state.emit("k", 2))
      assert(state.emit("k", 3))
      BURST = #got
      sleep(0.49)
      state.tick(os.epoch("utc"))
      EARLY = #got
      sleep(0.01)
      state.tick(os.epoch("utc"))
      LATER = #got
      local i = 1
      while i <= 15 do
        assert(state.emit("k", 100 + i))
        state.tick(os.epoch("utc"))
        sleep(0.1)
        i = i + 1
      end
      WINDOW = true
      RISING = true
      local a = 1
      while a <= #got do
        local n, b = 0, a
        while b <= #got do
          if got[b].at - got[a].at < 1000 then n = n + 1 end
          b = b + 1
        end
        if n > 2 then WINDOW = false end
        if a > 1 and got[a].rev <= got[a - 1].rev then RISING = false end
        a = a + 1
      end
      LAST = got[#got]
      DONE = true
    ]])
    net.advance(3)
    assert(not machine.error, tostring(machine.error))
    assert(machine.env.DONE == true, "subscriber loop did not finish")
    equal(machine.env.BURST, 1)
    equal(machine.env.EARLY, 1)
    equal(machine.env.LATER, 2)
    equal(machine.env.got[2].rev, 3)
    equal(machine.env.got[2].data[#machine.env.got[2].data].data, 3)
    assert(machine.env.got[2].at - machine.env.got[1].at >= 500, "frames closer than 500 ms")
    assert(machine.env.WINDOW == true, "more than 2 frames in one second")
    assert(machine.env.RISING == true, "rev did not increase")
    equal(machine.env.LAST.t, "view.frame")
    assert(machine.env.LAST.rev > machine.env.got[1].rev, "last rev")
  end)

  test("history pages move forward and the raw log stays within its caps", function()
    local net = harness.new()
    local machine = net.machine({ id = 1, capacity = 16000000 })
    lay(machine, MODS)
    local blob = string.rep("a", 20000)
    machine.spawn(PREAMBLE .. string.format([[
      local blob = %q
      local i = 1
      while i <= 80 do
        local ok, err = state.emit("b", blob .. i)
        if not ok then error(tostring(err) .. " at " .. i, 0) end
        i = i + 1
      end
      local page = state.history.page({ count = 1000 })
      FIRST = page.entries[1] and page.entries[1].seq
      local guard = 0
      while page.next and guard < 100 do
        guard = guard + 1
        page = state.history.page({ from = page.next, count = 50 })
        if page.entries[1] then FIRST = math.min(FIRST, page.entries[1].seq) end
      end
      LAST = state.get("b")
      REV = state.view().rev
      DONE = true
    ]], blob))
    net.flush()
    assert(not machine.error, tostring(machine.error))
    assert(machine.env.DONE == true, "fold did not finish")
    equal(machine.env.REV, 80)
    equal(machine.env.LAST, blob .. "80")
    assert(machine.env.FIRST > 1, "oldest event was kept after the log window folded")
    local bytes, biggest = logBytes(machine.files)
    assert(bytes <= 1048576, "raw log " .. bytes)
    assert(biggest <= 65536 and biggest > 0, "segment " .. biggest)
    assert(hasSnap(machine.files), "fold did not write a snapshot")

    local restarted = net.machine({ id = 7, capacity = 16000000 })
    lay(restarted, MODS)
    copyDisk(machine, restarted)
    restarted.spawn(PREAMBLE .. "\nLAST = state.get(\"b\")\nREV = state.view().rev\nDONE = true\n")
    net.flush()
    assert(not restarted.error, tostring(restarted.error))
    equal(restarted.env.REV, 80)
    equal(restarted.env.LAST, blob .. "80")

    local paging = net.machine({ id = 8, capacity = 16000000 })
    lay(paging, MODS)
    paging.spawn(PREAMBLE .. [[
      local i = 1
      while i <= 55 do
        assert(state.emit("p", i))
        i = i + 1
      end
      local page = state.history.page({ from = 0, count = 2 })
      A = page.entries
      N1 = page.next
      page = state.history.page({ from = page.next, count = 2 })
      B = page.entries
      N2 = page.next
      page = state.history.page({ from = 0, count = 1000 })
      WIDE = #page.entries
      DONE = true
    ]])
    net.flush()
    assert(not paging.error, tostring(paging.error))
    equal(paging.env.A[1].data, 1)
    equal(paging.env.A[2].data, 2)
    equal(paging.env.N1, paging.env.A[2].seq)
    equal(paging.env.B[1].seq, paging.env.N1 + 1)
    equal(paging.env.B[2].data, 4)
    equal(paging.env.WIDE, 50)
    local tail = paging.env.state.history.page({ from = paging.env.N2, count = 50 })
    assert(tail.next ~= nil or #tail.entries > 0, "page stopped early")
  end)

  test("a paired machine keeps its fingerprint and pose across a server restart", function()
    local net = harness.new()
    local server = net.machine({ id = 1, capacity = 16000000, modem = true })
    lay(server, SERVER)
    server.boot("so-server.lua")
    net.flush()
    assert(server.alive(), tostring(server.error))
    server.env.os.queueEvent("key", 25, false)
    net.flush()
    assert(not server.error, tostring(server.error))
    local code = assert(logtext(server):match("Pair code: (%d%d%d%d%d%d)"), "pair code missing")
    local client = net.machine({ id = 2, capacity = 1000000, modem = true })
    lay(client, { "so-proto.lua", "so-pair.lua", "so-store.lua" })
    client.spawn(string.format(JOIN, code))
    net.flush()
    assert(not client.error, tostring(client.error))
    assert(client.env.JOINED == true, "join did not finish")
    local key = server.env.SO.pair.key(2)
    local expect = server.env.SO.proto.hex(server.env.SO.proto.sha256(key))
    assert(server.env.SO.mods.state.emit("machine", { id = 2, role = "turtle", fuel = 80 }))
    assert(server.env.SO.mods.state.emit("pose", { id = 2, dim = "overworld", x = 1, y = 2, z = 3, facing = 2 }))
    local row = server.env.SO.mods.state.view.get({ name = "turtle/2" }).data
    equal(row.fp, expect)
    equal(#row.fp, 64)
    equal(row.fuel, 80)
    equal(row.pose, { dim = "overworld", x = 1, y = 2, z = 3, facing = 2 })
    local changed = server.env.SO.mods.state.view()
    changed.values.n = "mutated"
    assert(server.env.SO.mods.state.get("n") == nil, "shallow view wrote through")

    local server2 = net.machine({ id = 11, capacity = 16000000, modem = true })
    lay(server2, SERVER)
    copyDisk(server, server2)
    server2.boot("so-server.lua")
    net.flush()
    assert(server2.alive(), tostring(server2.error))
    local again = server2.env.SO.mods.state.view.get({ name = "turtle/2" }).data
    equal(again.fp, expect)
    equal(again.pose.facing, 2)
    equal(server2.env.SO.mods.state.view.get({ name = "fleet" }).data[1].id, 2)
  end)
end
