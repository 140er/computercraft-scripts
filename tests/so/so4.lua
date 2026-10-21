local harness = dofile("tests/so/harness.lua")

local function boot(files)
  local net = harness.new()
  local machine = net.machine({ id = 1, capacity = 16000000 })
  machine.install({ "so-mod-cells.lua", "so-store.lua" })
  for path, bytes in pairs(files or {}) do machine.files[path] = bytes end
  local env = machine.env
  env.fs.list = function(dir)
    dir = dir:gsub("/+$", "")
    local names, seen = {}, {}
    local prefix = dir == "" and "" or dir .. "/"
    for path in pairs(machine.files) do
      if path:sub(1, #prefix) == prefix then
        local name = path:sub(#prefix + 1):match("^[^/]+")
        if name and not seen[name] then names[#names + 1], seen[name] = name, true end
      end
    end
    table.sort(names)
    return names
  end
  env.fs.isDir = function(dir)
    for path in pairs(machine.files) do
      if path:sub(1, #dir + 1) == dir .. "/" then return true end
    end
    return false
  end
  local probe = { yields = 0, last = net.time, longest = 0, saves = 0,
    handles = setmetatable({}, { __mode = "k" }) }
  local function elapsed()
    probe.longest = math.max(probe.longest, net.time - probe.last)
  end
  env.sleep = function()
    elapsed()
    probe.yields = probe.yields + 1
    probe.last = net.time
  end
  local open = env.fs.open
  env.fs.open = function(path, mode)
    net.time = net.time + 50
    elapsed()
    return open(path, mode)
  end
  local store = env.dofile("so-store.lua")
  local makeStore = store.store
  store.store = function(path, ...)
    local handle = makeStore(path, ...)
    if path ~= "so-data/cells/res" then probe.handles[handle] = true end
    local save = handle.save
    handle.save = function(value)
      if path ~= "so-data/cells/res" then probe.saves = probe.saves + 1 end
      return save(value)
    end
    return handle
  end
  env.SO = { store = store, mods = {} }
  local cells = env.dofile("so-mod-cells.lua")
  env.SO.mods.cells = cells
  return cells, machine, net, probe
end

local function restart(machine)
  return boot(machine.files)
end

return function(test, equal)
  test("cells exclude other owners and reserveMany is atomic", function()
    local c = boot()
    assert(c.reserve("lease-a", 1, 2, 3))
    local ok, err = c.reserve(2, 1, 2, 3)
    equal(ok, false)
    equal(err, "held")
    assert(c.reserve("lease-a", 1, 2, 3))
    local held = { "minecraft:overworld", 1, 2, 3 }
    local many, reason, conflict = c.reserveMany(2, {
      { "minecraft:overworld", 9, 2, 3 }, held,
    })
    equal(many, false)
    equal(reason, "held")
    equal(conflict, held)
    assert(c.isFree(9, 2, 3))
    equal(c.owner(1, 2, 3), "lease-a")
    assert(c.release(2, 1, 2, 3))
    equal(c.owner(1, 2, 3), "lease-a")
    assert(c.release("lease-a", 1, 2, 3))
    assert(c.isFree(1, 2, 3))
    assert(c.reserveMany(2, { held, held, { "minecraft:overworld", 4, 5, 6 } }))
    equal(c.counts().reserved[2], 2)
  end)

  test("cells keep quiet owners for an hour", function()
    local c, _, net = boot()
    assert(c.reserve(42, 0, 0, 0))
    net.time = net.time + 3600000
    c.tick(net.time)
    equal(c.owner(0, 0, 0), 42)
    equal(c.isFree(0, 0, 0), false)
  end)

  test("cells forgetOwner frees exactly its owner and emits an event", function()
    local c, m, net = boot()
    local events = {}
    m.env.SO.mods.state = { emit = function(kind, data)
      events[#events + 1] = { kind = kind, data = data }
    end }
    assert(c.reserveMany("gone", {
      { "minecraft:overworld", 0, 0, 0 }, { "minecraft:the_nether", 0, 0, 0 },
    }))
    assert(c.reserve("here", 1, 0, 0))
    c.markDug(0, 0, 0)
    c.forgetOwner("gone")
    c.tick(net.time)
    assert(c.isFree(0, 0, 0))
    assert(c.isFree(0, 0, 0, "minecraft:the_nether"))
    equal(c.owner(1, 0, 0), "here")
    assert(c.isDug(0, 0, 0))
    equal(events, { { kind = "cells.forget", data = { who = "gone", count = 2 } } })
    c.releaseOwner("here")
    assert(c.isFree(1, 0, 0))
  end)

  test("cells restore reservations and dug marks after restart", function()
    local c, m, net = boot()
    assert(c.reserve(23, -17, -1, 16))
    assert(c.reserve("23", -17, -1, 16, "minecraft:the_nether"))
    c.markDug(-17, -1, 16)
    c.markDug(-17, -1, 16, "minecraft:the_nether")
    c.tick(net.time)
    local again, nextMachine = restart(m)
    equal(again.owner(-17, -1, 16), 23)
    equal(again.owner(-17, -1, 16, "minecraft:the_nether"), "23")
    assert(again.isDug(-17, -1, 16))
    assert(again.isDug(-17, -1, 16, "minecraft:the_nether"))
    equal(again.counts().dug, 2)
    again.releaseOwner(23)
    equal(again.owner(-17, -1, 16, "minecraft:the_nether"), "23")
    local third = restart(nextMachine)
    equal(third.owner(-17, -1, 16), nil)
  end)

  test("cells preserve default calls and isolate dimensions", function()
    local c, m, net = boot()
    assert(c.reserve("a", 1, 2, 3))
    assert(c.reserve("b", 1, 2, 3, "minecraft:the_end"))
    equal(c.owner(1, 2, 3, "minecraft:overworld"), "a")
    c.markDug(1, 2, 3)
    c.markDug(1, 2, 3)
    assert(c.isDug(1, 2, 3))
    equal(c.isDug(1, 2, 3, "minecraft:the_end"), false)
    equal(c.counts().dug, 1)
    c.forget(1, 2, 3)
    assert(c.isFree(1, 2, 3))
    equal(c.isDug(1, 2, 3), false)
    equal(c.owner(1, 2, 3, "minecraft:the_end"), "b")
    c.tick(net.time)
    local again = restart(m)
    equal(again.isDug(1, 2, 3), false)
    equal(again.counts().dug, 0)
  end)

  test("cells save and reload 10000 dug cells in 50 sections with yields", function()
    local c, m, net, probe = boot()
    for section = 0, 49 do
      for i = 0, 199 do c.markDug(section * 16 + i % 16, math.floor(i / 16), 0) end
    end
    equal(c.counts().dug, 10000)
    for _ = 1, 7 do
      local before = probe.saves
      c.tick(net.time)
      assert(probe.saves - before <= 8, "more than eight section saves in a tick")
    end
    equal(probe.saves, 50)
    assert(probe.yields > 0, "bulk work never yielded")
    assert(probe.longest <= 5000, "save stretch exceeded five simulated seconds")
    local again, _, _, loaded = restart(m)
    equal(again.counts().dug, 10000)
    for section = 0, 49 do
      for i = 0, 199 do assert(again.isDug(section * 16 + i % 16, math.floor(i / 16), 0)) end
    end
    assert(loaded.yields > 0, "bulk load never yielded")
    assert(loaded.longest <= 5000, "load stretch exceeded five simulated seconds")
  end)

  test("cells evict saved sections at the 256 section limit", function()
    local c, m, net, probe = boot()
    for i = 0, 299 do c.markDug(i * 16, 0, 0) end
    collectgarbage("collect")
    local resident = 0
    for _ in pairs(probe.handles) do resident = resident + 1 end
    assert(resident <= 256, "resident section handles " .. resident)
    equal(c.counts().dug, 300)
    for _ = 1, 32 do c.tick(net.time) end
    local again = restart(m)
    equal(again.counts().dug, 300)
    for i = 0, 299 do assert(again.isDug(i * 16, 0, 0)) end
  end)

  test("cells.forget requires a fresh token bound to sender and owner", function()
    local c, _, net = boot()
    assert(c.reserve("gone", 0, 0, 0))
    local function request(sender, body)
      local answer
      c.handlers["cells.forget"]({ from = sender, body = body }, function(kind, data)
        answer = { kind = kind, data = data }
      end)
      return assert(answer)
    end
    local first = request(10, { who = "gone" })
    assert(first.data.confirm ~= nil)
    equal(c.owner(0, 0, 0), "gone")
    equal(request(11, { who = "gone", confirm = first.data.confirm }).kind, "err")
    equal(request(10, { who = "other", confirm = first.data.confirm }).kind, "err")
    equal(c.owner(0, 0, 0), "gone")
    local fresh = request(10, { who = "gone" }).data.confirm
    net.time = net.time + 30001
    equal(request(10, { who = "gone", confirm = fresh }).kind, "err")
    equal(c.owner(0, 0, 0), "gone")
    local token = request(10, { who = "gone" }).data.confirm
    local done = request(10, { who = "gone", confirm = token })
    assert(done.kind ~= "err")
    assert(c.isFree(0, 0, 0))
    equal(request(10, { who = "gone", confirm = token }).kind, "err")
    equal(request(10, {}).kind, "err")
  end)

  test("cells keep ownership when reservation persistence fails", function()
    local c, m = boot()
    assert(c.reserve("safe", 0, 0, 0))
    local open = m.env.fs.open
    m.env.fs.open = function(path, mode)
      if path == "so-data/cells/res.tmp" and mode == "w" then return nil end
      return open(path, mode)
    end
    local ok = c.releaseOwner("safe")
    equal(ok, false)
    equal(c.owner(0, 0, 0), "safe")
    local again = restart(m)
    equal(again.owner(0, 0, 0), "safe")
  end)

  test("cells register a callable state view from tick", function()
    local c, m, net = boot()
    local views = {}
    m.env.SO.mods.state = { view = setmetatable({}, { __call = function(_, name, fn)
      views[name] = fn
    end }) }
    c.tick(net.time)
    assert(type(views.cells) == "function")
    c.reserve("lease", 0, 0, 0)
    equal(views.cells(), { reserved = { lease = 1 }, dug = 0 })
  end)
end
