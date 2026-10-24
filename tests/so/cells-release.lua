local H = dofile("tests/so/harness.lua")

local function boot(files)
  local net = H.new()
  local m = net.machine({ id = 1, directories = true, capacity = 16000000 })
  m.install({ "so-store.lua", "so-mod-cells.lua" })
  for path, bytes in pairs(files or {}) do m.files[path] = bytes end
  m.env.SO = { now = function() return net.time end, mods = {},
    store = m.env.dofile("so-store.lua"), breathe = function() end }
  return m.env.dofile("so-mod-cells.lua"), m, net
end

return function(test, equal)
  test("cells release: a failed commit stays held until the next tick saves it", function()
    local cells, m, net = boot()
    local route = { { "minecraft:overworld", 1, 2, 3 }, { "minecraft:the_nether", 4, 5, 6 } }
    assert(cells.reserveMany("lane", route))
    assert(cells.reserve("other", 7, 8, 9))
    local open, attempts = m.env.fs.open, 0
    m.env.fs.open = function(path, mode)
      if path == "so-data/cells/res.tmp" and mode == "w" then
        attempts = attempts + 1
        if attempts == 1 then return nil end
      end
      return open(path, mode)
    end
    equal(cells.releaseOwner("lane"), false)
    equal(cells.owner(1, 2, 3), "lane")
    equal(cells.owner(4, 5, 6, "minecraft:the_nether"), "lane")
    local ok, reason = cells.reserveMany("next", route)
    equal(ok, false)
    equal(reason, "held")
    assert(cells.tick(net.time))
    equal(attempts, 2)
    equal(cells.owner(7, 8, 9), "other")
    local reboot = boot(m.files)
    equal(reboot.owner(1, 2, 3), nil)
    equal(reboot.owner(4, 5, 6, "minecraft:the_nether"), nil)
    assert(cells.reserveMany("next", route))
    assert(cells.tick(net.time))
    equal(attempts, 3)
    equal(cells.owner(1, 2, 3), "next")
  end)

  test("cells release: repeated failed ticks retain every pending owner", function()
    local cells, m, net = boot()
    assert(cells.reserve("lane", 1, 2, 3))
    assert(cells.reserve(42, 4, 5, 6))
    local open = m.env.fs.open
    m.env.fs.open = function(path, mode)
      if path == "so-data/cells/res.tmp" and mode == "w" then return nil end
      return open(path, mode)
    end
    equal(cells.releaseOwner("lane"), false)
    equal(cells.releaseOwner(42), false)
    for _ = 1, 2 do
      equal(cells.tick(net.time), false)
      equal(cells.owner(1, 2, 3), "lane")
      equal(cells.owner(4, 5, 6), 42)
    end
    m.env.fs.open = open
    assert(cells.tick(net.time))
    assert(cells.reserveMany("next", {
      { "minecraft:overworld", 1, 2, 3 }, { "minecraft:overworld", 4, 5, 6 },
    }))
  end)

  test("cells release: a failed recovery-policy save also retries the release", function()
    local cells, m, net = boot()
    assert(cells.reserve("lane", 1, 2, 3))
    cells.rememberWorker(9, { dim = "minecraft:overworld", x = 1, y = 2, z = 3 }, {})
    local open = m.env.fs.open
    m.env.fs.open = function(path, mode)
      if path == "so-data/dug-policy.tmp" and mode == "w" then return nil end
      return open(path, mode)
    end
    equal(cells.releaseOwner("lane"), false)
    equal(cells.tick(net.time), false)
    equal(cells.owner(1, 2, 3), "lane")
    m.env.fs.open = open
    assert(cells.tick(net.time))
    assert(cells.reserve("lane", 1, 2, 3))
    assert(cells.tick(net.time))
    equal(cells.owner(1, 2, 3), "lane")
    local reboot = boot(m.files)
    equal(reboot.owner(1, 2, 3), "lane")
  end)
end
