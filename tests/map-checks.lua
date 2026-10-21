return function(test)
  local Section = dofile("mapsection.lua")
  local Map = dofile("mapstore.lua")
  local mocks = dofile("tests/mocks.lua")

  local function read(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
  end
  local function memoryFs(limit)
    local files = {}
    local fs = {}
    local function used()
      local n = 0
      for _, text in pairs(files) do n = n + #text end
      return n
    end
    function fs.exists(path) return files[path] ~= nil end
    function fs.delete(path) files[path] = nil end
    function fs.makeDir() end
    function fs.getFreeSpace() return limit - used() end
    function fs.move(from, to)
      if files[from] == nil or files[to] ~= nil then error("move failed") end
      files[to], files[from] = files[from], nil
    end
    function fs.open(path, mode)
      if mode == "w" or mode == "wb" then files[path] = ""
      elseif files[path] == nil then return nil end
      local handle = {}
      function handle.readAll() return files[path] end
      function handle.write(text)
        if used() + #text > limit then error("Out of space") end
        files[path] = files[path] .. text
      end
      function handle.close() end
      return handle
    end
    return fs, files
  end
  local function sample()
    return {
      ["minecraft:overworld|0|4|0"] = {
        rev = 4,
        cells = { [1] = 0, [2] = 1, [4] = 2 },
      },
      ["minecraft:overworld|-1|3|-2"] = {
        rev = 4,
        cells = { [4096] = 1 },
      },
    }
  end
  local names = { "minecraft:stone", "minecraft:diamond_ore" }
  local function expect(store)
    local air = store:read("abs|minecraft:overworld|0|4|0")
    local edge = store:read("abs|minecraft:overworld|-1|3|-2")
    assert(Section.get(air, 0) == "minecraft:air")
    assert(Section.get(air, 1) == "minecraft:stone")
    assert(Section.get(air, 2) == nil)
    assert(Section.get(air, 3) == "minecraft:diamond_ore")
    assert(Section.confidence(air, 1) == "observed")
    assert(Section.confidence(air, 2) == "unknown")
    assert(Section.get(edge, 4095) == "minecraft:stone")
    assert(Section.get(edge, 0) == nil)
    assert(air.rev == 4 and edge.rev == 4)
  end

  test("sha256 matches the empty and abc vectors", function()
    assert(Section.sha256hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    assert(Section.sha256hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  end)

  test("palette runs round-trip observed cells and leave gaps unknown", function()
    local cells = { [0] = "minecraft:air", [1] = "minecraft:stone", [2] = "minecraft:stone",
      [100] = "minecraft:diamond_ore" }
    local section = assert(Section.fromCells("abs|minecraft:overworld|0|4|-1", 3, cells, 1000, 1000))
    local bytes = assert(Section.encode(section))
    assert(bytes:sub(1, 4) == "CCS2" and bytes:byte(5) == 2)
    local back = assert(Section.decode(bytes))
    assert(back.hash == section.hash)
    assert(Section.get(back, 0) == "minecraft:air")
    assert(Section.get(back, 2) == "minecraft:stone")
    assert(Section.confidence(back, 3) == "unknown")
    assert(Section.wireName(Section.get(back, 0)) == false)
    assert(Section.wireName("minecraft:stone") == "minecraft:stone")
    assert(not Section.decode("whc-rle/1\nnope"))
    assert(not Section.decode("CCS2" .. string.char(9) .. string.rep("\0", 40)))
    assert(not Section.fromCells(section.key, 3, { [0] = "=" }, 1, 1))
    print(string.format("SIZE one_gap_section=%d", #bytes))
  end)

  test("a solid section stays one run", function()
    local cells = {}
    for i = 0, 4095 do cells[i] = "minecraft:stone" end
    local section = assert(Section.fromCells("abs|minecraft:overworld|1|4|1", 1, cells, 1, 1))
    local bytes = assert(Section.encode(section))
    assert(#section.runs == 1)
    assert(#bytes < 256)
    local back = assert(Section.decode(bytes))
    assert(Section.get(back, 0) == "minecraft:stone" and Section.get(back, 4095) == "minecraft:stone")
    print(string.format("SIZE uniform_4096=%d", #bytes))
  end)

  test("negative coordinates use the same section index as schema 1 minus one", function()
    assert(Section.cellIndex(-1, 64, -1) == 15 + 16 * 15)
    local key = Section.sectionKey({ dim = "minecraft:overworld", x = -1, y = 64, z = -1 })
    assert(key == "abs|minecraft:overworld|-1|4|-1")
    local framed = Section.sectionKey({ frame = "f:17:100", dim = "minecraft:overworld", x = 3, y = 4, z = 5 })
    assert(framed == "f:17:100|minecraft:overworld|0|0|0")
    assert(Section.normalizeKey("minecraft:overworld|0|4|0") == "abs|minecraft:overworld|0|4|0")
    assert(Section.normalizeKey(framed) == framed)
  end)

  test("schema 1 migration keeps air, names and holes, and survives a crash", function()
    local phases = { "legacy", "sections", "verify", "publish", "drop" }
    for _, phase in ipairs(phases) do
      local fs = memoryFs(2000000)
      local crash = phase
      local function hook(seen)
        if seen == crash then error("crash") end
      end
      local store = assert(Map.open(fs, { reserve = 0, hook = hook }))
      local ok = pcall(function()
        assert(store:stageSchema1(names, sample()))
        if phase == "drop" then assert(store:dropLegacy()) end
      end)
      assert(not ok)
      assert(fs.exists("map/legacy"))
      store = assert(Map.open(fs, { reserve = 0 }))
      assert(store:stageSchema1(names, sample()))
      expect(store)
      assert(fs.exists("map/legacy"))
      assert(store:dropLegacy())
      assert(not fs.exists("map/legacy"))
      assert(store:stageSchema1(names, sample()))
      expect(store)
    end
  end)

  test("a second migration is a no-op and a different legacy is kept", function()
    local fs = memoryFs(2000000)
    local store = assert(Map.open(fs, { reserve = 0 }))
    assert(store:stageSchema1(names, sample()))
    local before = store:sizes()
    assert(store:stageSchema1(names, sample()))
    local after = store:sizes()
    assert(before.payload == after.payload and before.sections == 2)
    local other = sample()
    other["minecraft:overworld|0|4|0"].cells[5] = 1
    assert(not store:stageSchema1(names, other))
    assert(fs.exists("map/legacy"))
    expect(store)
    print(string.format("SIZE migrated_payload=%d index=%d sections=%d largest=%d",
      after.payload, after.index, after.sections, after.largest))
  end)

  test("a full disk refuses the new section and keeps the old one", function()
    local fs = memoryFs(620)
    local store = assert(Map.open(fs, { reserve = 400 }))
    local key = "abs|minecraft:overworld|0|4|0"
    assert(store:observe(key, { { index = 0, name = "minecraft:stone" } }, 1, 10))
    assert(store:flush())
    assert(Section.get(store:read(key), 0) == "minecraft:stone")
    store:checkpoint()
    assert(store:observe(key, { { index = 1, name = "minecraft:diamond_ore" } }, 2, 11))
    local ok, err = store:flush()
    assert(not ok and err == "capacity")
    store:rollback()
    assert(Section.get(store:read(key), 0) == "minecraft:stone")
    assert(Section.get(store:read(key), 1) == nil)
  end)

  test("a section stores 256 names and refuses the 257th", function()
    local cells = {}
    for i = 0, 255 do cells[i] = "mod:n" .. i end
    local key = "abs|minecraft:overworld|0|4|0"
    local section = assert(Section.fromCells(key, 1, cells, 1, 1))
    assert(#section.palette == 256)
    local bytes = assert(Section.encode(section))
    local back = assert(Section.decode(bytes))
    for i = 0, 255 do assert(Section.get(back, i) == cells[i]) end
    cells[256] = "mod:n256"
    local refused, why = Section.fromCells(key, 1, cells, 1, 1)
    assert(not refused and why == "palette limit")
  end)

  test("compact scans pass the old section and name caps and reload from files", function()
    local box = mocks.new(false)
    local env = box.env
    env.sleep = function() end
    env.dofile = function(path) return assert(loadfile(path, "t", env))() end
    local S = env.dofile("ssot.lua")
    local Store = env.dofile("mapstore.lua")
    local secret = "test-secret-123456"
    local function session(compact, map)
      local cfg = { controllers = { ["1"] = secret }, compactSections = compact }
      return S.new({}, cfg, function() return 50000 end, "boot", function() return true end, map)
    end
    local function send(api, op, fields, n)
      local m = {
        v = 1, type = "ssot", expect = "ssot_reply", op = op, rid = "r" .. n, counter = n,
        boot = "turtle-1", secret = secret,
      }
      for k, v in pairs(fields) do m[k] = v end
      return api.handle(1, m)
    end
    local plain = session(false)
    assert(send(plain, "sync", { pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 } }, 1).ok)
    local n, hit = 2, false
    for cx = -2, 2 do
      for cy = 2, 6 do
        for cz = -2, 2 do
          if n < 67 then
            local cell = { dim = "minecraft:overworld", x = cx * 16, y = cy * 16, z = cz * 16, name = "minecraft:stone" }
            local reply = send(plain, "scan", { pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 },
              revision = n - 2, cells = { cell } }, n)
            if n == 66 then
              assert(reply and not reply.ok and reply.error == "resident chunk limit")
              hit = true
            else
              assert(reply and reply.ok)
            end
            n = n + 1
          end
        end
      end
    end
    assert(hit)
    local capped = session(false)
    assert(send(capped, "sync", { pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 } }, 1).ok)
    local rev, counter = 0, 2
    for batch = 0, 3 do
      local cells = {}
      for i = 1, 64 do
        cells[i] = { dim = "minecraft:overworld", x = (i + batch) % 16, y = 64, z = math.floor((i + batch) / 16),
          name = "mod:block" .. (batch * 64 + i) }
      end
      local reply = send(capped, "scan", { pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 },
        revision = rev, cells = cells }, counter)
      if batch < 4 then assert(reply and reply.ok) rev = reply.revision end
      counter = counter + 1
    end
    local overflow = {}
    overflow[1] = { dim = "minecraft:overworld", x = 1, y = 64, z = 1, name = "mod:block257" }
    local refused = send(capped, "scan", { pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 },
      revision = rev, cells = overflow }, counter)
    assert(refused and not refused.ok and refused.error == "name limit")

    local map = assert(Store.open(env.fs, { reserve = 0, root = "compact" }))
    local api = session(true, map)
    assert(send(api, "sync", { pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 } }, 1).ok)
    n = 2
    for cx = -2, 2 do
      for cy = 2, 6 do
        for cz = -2, 2 do
          if n <= 66 then
            local cell = { dim = "minecraft:overworld", x = cx * 16, y = cy * 16, z = cz * 16,
              name = "mod:section" .. n }
            local reply = send(api, "scan", { pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 },
              revision = n - 2, cells = { cell } }, n)
            assert(reply and reply.ok, reply and reply.error)
            n = n + 1
          end
        end
      end
    end
    rev, counter = map:maxRevision(), 100
    api = S.new({ rev = rev }, { controllers = { ["1"] = secret }, compactSections = true },
      function() return 50000 end, "boot", function() return true end, map)
    assert(send(api, "sync", { pose = { dim = "minecraft:overworld", x = 8, y = 64, z = 8 } }, counter).ok)
    counter = counter + 1
    local made = 0
    for batch = 0, 4 do
      local cells = {}
      local count = batch == 4 and 1 or 64
      for i = 1, count do
        made = made + 1
        local n = made - 1
        cells[i] = { dim = "minecraft:overworld", x = n % 16, y = 64 + math.floor(n / 256) * 16,
          z = math.floor(n / 16) % 16, name = "mod:named" .. made }
      end
      local reply = send(api, "scan", { pose = { dim = "minecraft:overworld", x = 8, y = 64, z = 8 },
        revision = rev, cells = cells }, counter)
      assert(reply and reply.ok, reply and reply.error)
      rev, counter = reply.revision, counter + 1
    end
    assert(made == 257)
    local function drain(chunk, revision)
      local seen, cursor = {}, 0
      repeat
        local fields = { chunk = chunk, cursor = cursor }
        if revision then fields.revision = revision end
        local page = send(api, "snapshot", fields, counter)
        counter = counter + 1
        assert(page and page.ok, page and page.error)
        for _, entry in ipairs(page.cells) do seen[entry[2]] = true end
        cursor = page.cursor
      until cursor == 0
      return seen
    end
    local lower = drain("minecraft:overworld|0|4|0", nil)
    local upper = drain("minecraft:overworld|0|5|0", rev)
    local seen = {}
    for name in pairs(lower) do seen[name] = true end
    for name in pairs(upper) do seen[name] = true end
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    assert(count >= 257)
    local reloaded = assert(Store.open(env.fs, { reserve = 0, root = "compact" }))
    assert(reloaded:revision("abs|minecraft:overworld|0|4|0") > 0)
    assert(reloaded:revision("abs|minecraft:overworld|0|5|0") == rev)
    local framed = send(api, "scan", { pose = { dim = "minecraft:overworld", x = 8, y = 64, z = 8 }, revision = rev,
      cells = { { frame = "f:17:100", dim = "minecraft:overworld", x = 20, y = 64, z = 8, name = "minecraft:obsidian" } } },
      counter)
    assert(framed and framed.ok)
    local page = send(api, "snapshot", { chunk = "f:17:100|minecraft:overworld|1|4|0" }, counter + 1)
    assert(page and page.ok and page.cells[1][2] == "minecraft:obsidian")
    local absolute = send(api, "snapshot", { chunk = "abs|minecraft:overworld|1|4|0" }, counter + 2)
    assert(absolute and absolute.ok)
    for _, entry in ipairs(absolute.cells) do assert(entry[2] ~= "minecraft:obsidian") end
  end)

  test("resident chunk limit rejects the next chunk for compact and legacy scans", function()
    local box = mocks.new(false)
    local env = box.env
    env.sleep = function() end
    env.dofile = function(path) return assert(loadfile(path, "t", env))() end
    local S = env.dofile("ssot.lua")
    local Store = env.dofile("mapstore.lua")
    local secret = "test-secret-123456"
    local pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 }
    local function cell(x, z, name, y)
      if name == nil then name = false end
      return { dim = pose.dim, x = x, y = y or 64, z = z, name = name }
    end
    local spots = {
      { 0, 0 }, { 16, 0 }, { 32, 0 }, { -16, 0 }, { -32, 0 },
      { 0, 16 }, { 0, -16 },
    }
    for _, compact in ipairs({ false, true }) do
      local map = nil
      if compact then
        map = assert(Store.open(env.fs, { reserve = 0, root = "chunk-cap" }))
      end
      local api = S.new({}, {
        controllers = { ["1"] = secret }, compactSections = compact, maxChunks = 8,
      }, function() return 50000 end, "boot", function() return true end, map)
      local n, rev = 0, 0
      local function send(op, fields)
        n = n + 1
        local m = {
          v = 1, type = "ssot", expect = "ssot_reply", op = op, rid = "cap" .. n, counter = n,
          boot = "turtle-1", secret = secret,
        }
        for k, v in pairs(fields) do m[k] = v end
        return api.handle(1, m)
      end
      local label = compact and "compact" or "legacy"
      local function snap(chunk)
        local page = send("snapshot", { chunk = chunk })
        assert(page and page.ok, label .. " snap " .. tostring(page and page.error))
        return page
      end
      assert(send("sync", { pose = pose }).ok, label)
      for _, spot in ipairs(spots) do
        local reply = send("scan", { pose = pose, revision = rev, cells = { cell(spot[1], spot[2]) } })
        assert(reply and reply.ok, label .. " fill " .. tostring(reply and reply.error))
        rev = reply.revision
      end
      local refused = send("scan", { pose = pose, revision = rev, cells = { cell(0, 32), cell(16, 16) } })
      assert(refused and refused.ok == false and refused.error == "resident chunk limit",
        label .. " two new chunks reply=" .. tostring(refused and refused.error))
      assert(#snap("minecraft:overworld|0|4|2").cells == 0, label .. " stored a rejected chunk")
      assert(#snap("minecraft:overworld|1|4|1").cells == 0, label .. " stored a rejected chunk")
      local pair = send("scan", { pose = pose, revision = rev, cells = { cell(0, 32), cell(0, 32, false, 65) } })
      assert(pair and pair.ok, label .. " same chunk " .. tostring(pair and pair.error))
      rev = pair.revision
      local ninth = send("scan", { pose = pose, revision = rev, cells = { cell(16, 16) } })
      assert(ninth and ninth.ok == false and ninth.error == "resident chunk limit",
        label .. " ninth reply=" .. tostring(ninth and ninth.error))
      local solid = send("scan", { pose = pose, revision = rev, cells = { cell(0, 0, "minecraft:stone") } })
      assert(solid and solid.ok, label .. " update " .. tostring(solid and solid.error))
      local kept = snap("minecraft:overworld|0|4|0")
      local found = false
      for _, entry in ipairs(kept.cells) do
        if entry[2] == "minecraft:stone" then found = true end
      end
      assert(found, label .. " dropped the kept chunk")
      assert(#snap("minecraft:overworld|1|4|1").cells == 0, label .. " stored a rejected chunk")
    end
  end)

  test("a map already over the cap still accepts an update to a stored section", function()
    local box = mocks.new(false)
    local env = box.env
    env.sleep = function() end
    env.dofile = function(path) return assert(loadfile(path, "t", env))() end
    local S = env.dofile("ssot.lua")
    local Store = env.dofile("mapstore.lua")
    local secret = "test-secret-123456"
    local pose = { dim = "minecraft:overworld", x = 0, y = 64, z = 0 }
    local map = assert(Store.open(env.fs, { reserve = 0, root = "over-cap" }))
    local function open(maxChunks, rev)
      return S.new({ rev = rev or 0 }, {
        controllers = { ["1"] = secret }, compactSections = true, maxChunks = maxChunks,
      }, function() return 50000 end, "boot", function() return true end, map)
    end
    local n = 0
    local function send(api, op, fields)
      n = n + 1
      local m = {
        v = 1, type = "ssot", expect = "ssot_reply", op = op, rid = "over" .. n, counter = n,
        boot = "turtle-1", secret = secret,
      }
      for k, v in pairs(fields) do m[k] = v end
      return api.handle(1, m)
    end
    local function cell(x, z, name)
      if name == nil then name = false end
      return { dim = pose.dim, x = x, y = 64, z = z, name = name }
    end
    local api = open(nil, 0)
    assert(send(api, "sync", { pose = pose }).ok)
    local rev = 0
    for _, spot in ipairs({
      { 0, 0 }, { 16, 0 }, { 32, 0 }, { -16, 0 }, { -32, 0 },
      { 0, 16 }, { 0, -16 }, { 0, 32 }, { 16, 16 },
    }) do
      local reply = send(api, "scan", { pose = pose, revision = rev, cells = { cell(spot[1], spot[2]) } })
      assert(reply and reply.ok, reply and reply.error)
      rev = reply.revision
    end
    api = open(8, map:maxRevision())
    assert(send(api, "sync", { pose = pose }).ok)
    local kept = send(api, "scan", { pose = pose, revision = rev, cells = { cell(0, 0, "minecraft:stone") } })
    assert(kept and kept.ok, kept and kept.error)
    local refused = send(api, "scan", { pose = pose, revision = rev, cells = { cell(16, -16) } })
    assert(refused and refused.ok == false and refused.error == "resident chunk limit",
      "new section reply=" .. tostring(refused and refused.error))
    local page = send(api, "snapshot", { chunk = "minecraft:overworld|0|4|0" })
    assert(page and page.ok)
    local found = false
    for _, entry in ipairs(page.cells) do
      if entry[2] == "minecraft:stone" then found = true end
    end
    assert(found, "stored section lost the update")
    page = send(api, "snapshot", { chunk = "minecraft:overworld|1|4|-1" })
    assert(page and page.ok and #page.cells == 0, "stored a section past the cap")
  end)

  test("measured section payload for a quarry and branch workload", function()
    local sections = {}
    local function put(x, y, z, name)
      local key = string.format("abs|minecraft:overworld|%d|%d|%d", math.floor(x / 16), math.floor(y / 16), math.floor(z / 16))
      local index = Section.cellIndex(x, y, z)
      local cells = sections[key]
      if not cells then cells = {} sections[key] = cells end
      cells[index] = name
    end
    for x = 0, 47 do
      for z = 0, 15 do
        for y = 4, 64 do
          local name = (x + y + z) % 10 == 0 and "minecraft:andesite" or "minecraft:stone"
          put(x, y, z, name)
        end
      end
    end
    local quarryCells, quarrySections = 0, 0
    for _, cells in pairs(sections) do
      quarrySections = quarrySections + 1
      for _ in pairs(cells) do quarryCells = quarryCells + 1 end
    end
    for miner = 0, 3 do
      local x0, z0 = 80 + miner * 16, 80
      for y = 4, 64 do put(x0, y, z0, "minecraft:air") end
      for branch = 0, 31 do
        local y = 4 + (branch % 20)
        local z = z0 + 2 + (branch % 4) * 3
        for step = 1, 64 do
          for dx = -1, 1 do
            for dy = -1, 1 do
              put(x0 + step, y + dy, z + dx, (dx == 0 and dy == 0) and "minecraft:air" or "minecraft:stone")
            end
          end
        end
      end
    end
    local payload, largest, count, runs, allocated = 0, 0, 0, 0, 1500
    for key, cells in pairs(sections) do
      local section = assert(Section.fromCells(key, 1, cells, 1, 1))
      local bytes = assert(Section.encode(section))
      local back = assert(Section.decode(bytes))
      for index, name in pairs(cells) do assert(Section.get(back, index) == name) end
      payload, count = payload + #bytes, count + 1
      allocated = allocated + math.max(500, #bytes)
      runs = runs + #section.runs
      if #bytes > largest then largest = #bytes end
    end
    assert(payload < count * 8000)
    print(string.format("SIZE workload_sections=%d payload=%d largest=%d runs=%d quarry_sections=%d quarry_cells=%d",
      count, payload, largest, runs, quarrySections, quarryCells))
    print(string.format("SIZE workload_allocated_estimate=%d", allocated))
  end)

  test("map modules do not call gps", function()
    local maps = read("mapsection.lua") .. read("mapstore.lua")
    assert(not maps:find("gps", 1, true))
    assert(not read("ssot.lua"):find("gps.", 1, true))
  end)

  if type(fs) == "table" and type(fs.getCapacity) == "function" and fs.getCapacity("/") == 4000000 then
    test("CraftOS records per-section file bytes at the 4MB disk", function()
      local before = fs.getFreeSpace("/")
      local store = assert(Map.open(fs, { reserve = 0, root = "craft-map" }))
      local cells = {}
      for i = 0, 4095 do cells[i] = i % 17 == 0 and "minecraft:andesite" or "minecraft:stone" end
      local key = "abs|minecraft:overworld|2|4|2"
      local section = assert(Section.fromCells(key, 1, cells, 1, 1))
      local bytes = assert(Section.encode(section))
      assert(store:observe(key, { { index = 0, name = cells[0] } }, 1, 1))
      -- Replace the one-cell observe with the full section through a second observe batch.
      local edits = {}
      for index, name in pairs(cells) do edits[#edits + 1] = { index = index, name = name } end
      store:checkpoint()
      assert(store:observe(key, edits, 2, 2))
      assert(store:flush())
      local after = fs.getFreeSpace("/")
      local sizes = store:sizes()
      print(string.format("SIZE craftos_payload=%d craftos_free_delta=%d file_floor=%d",
        sizes.payload, before - after, #bytes))
      assert(before - after >= sizes.payload)
      assert(Section.get(store:read(key), 17) == "minecraft:andesite")
    end)
  end
end
