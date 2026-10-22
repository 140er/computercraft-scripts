local H = dofile("tests/so/harness.lua")

local function setup(files)
  local net = H.new()
  local m = net.machine({ id = 1, directories = true })
  m.install({ "so-store.lua", "so-mod-cells.lua" })
  for path, bytes in pairs(files or {}) do m.files[path] = bytes end
  m.env.SO = { mods = {}, store = m.env.dofile("so-store.lua"), breathe = function() end }
  local cells = m.env.dofile("so-mod-cells.lua")
  m.env.SO.mods.cells = cells
  return cells, m
end

local path = "so-data/cells/minecraft%3aoverworld/0_0_0"

return function(test, equal)
  test("dug bitset: full and sparse sections survive save and reload within 2 KB", function()
    for _, full in ipairs({ true, false }) do
      local cells, m = setup()
      for index = 0, 4095 do
        if full or index % 97 == 0 then
          assert(cells.markDug(index % 16, math.floor(index / 16) % 16, math.floor(index / 256)))
        end
      end
      assert(cells.tick(0))
      local bytes = assert(m.files[path])
      assert(#bytes < 2048, "section bytes " .. #bytes)
      local saved = m.env.SO.store.read(path).value
      equal(saved.format, "hex4096")
      equal(#saved.bits, 1024)
      local loaded = setup(m.files)
      local count = 0
      for index = 0, 4095 do
        local marked = full or index % 97 == 0
        equal(loaded.isDug(index % 16, math.floor(index / 16) % 16, math.floor(index / 256)), marked)
        if marked then count = count + 1 end
      end
      equal(loaded.counts().dug, count)
      assert(loaded.forget(0, 0, 0))
      equal(loaded.isDug(0, 0, 0), false)
      equal(loaded.counts().dug, count - 1)
      assert(loaded.markDug(0, 0, 0))
      assert(loaded.markDug(0, 0, 0))
      equal(loaded.counts().dug, count)
    end
  end)

  test("dug bitset: legacy generations migrate without losing negative or dimension cells", function()
    local other = "so-data/cells/mod%3amoon/-1_-1_-1"
    local old = H.encode({ schema = 1, generation = 7, value = { [0] = true, [4095] = true, [93] = true } })
    local cells, m = setup({ [other .. ".tmp"] = old })
    equal(cells.counts().dug, 3)
    equal(cells.isDug(-1, -1, -1, "mod:moon"), true)
    assert(cells.tick(0))
    local saved = m.env.SO.store.read(other)
    equal(saved.generation, 8)
    equal(saved.value.format, "hex4096")
    equal(m.files[other .. ".bak"], old)
    local loaded = setup(m.files)
    equal(loaded.isDug(-16, -16, -16, "mod:moon"), true)
    equal(loaded.isDug(-3, -11, -16, "mod:moon"), true)
    equal(loaded.counts().dug, 3)
  end)

  test("dug bitset: interrupted migration recovers the newest valid generation", function()
    local old = H.encode({ schema = 1, generation = 3, value = { [0] = true, [255] = true } })
    for _, failAt in ipairs({ 1, 2 }) do
      local cells, m = setup({ [path] = old })
      local move, calls = m.env.fs.move, 0
      m.env.fs.move = function(from, to)
        calls = calls + 1
        if calls == failAt then error("power cut") end
        return move(from, to)
      end
      equal(cells.tick(0), false)
      local loaded, reboot = setup(m.files)
      equal(loaded.isDug(0, 0, 0), true)
      equal(loaded.isDug(15, 15, 0), true)
      equal(loaded.counts().dug, 2)
      assert(loaded.tick(0))
      local saved = reboot.env.SO.store.read(path)
      equal(saved.value.format, "hex4096")
    end
  end)
end
