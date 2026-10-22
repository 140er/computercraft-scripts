local H = dofile("tests/so/harness.lua")

return function(test, equal)
  local function machine(files)
    local net = H.new()
    local m = net.machine({ id = 1, directories = true })
    m.install({ "so-store.lua", "so-log.lua" })
    for path, text in pairs(files or {}) do m.files[path] = text end
    return m
  end
  local function run(m, code)
    m.spawn(code)
    assert(not m.error, m.error)
  end
  local boot = [[
    store = dofile("so-store.lua")
    log = dofile("so-log.lua").open(store)
  ]]
  local checkpoint = [[
    assert(log.append({kind="value"}))
    assert(log.checkpoint({values={mark=1}, machines={}}))
  ]]
  local function seed()
    local m = machine()
    run(m, boot .. checkpoint .. checkpoint)
    for _, suffix in ipairs({"", ".tmp", ".bak"}) do
      m.files["so-data/snap/000000" .. suffix] = m.files["so-data/snap/000001"]
    end
    return m.files
  end
  local function retained(m)
    for path in pairs(m.files) do
      local n = path:match("^so%-data/snap/(%d+)")
      if n then assert(tonumber(n) >= 2, "stale snapshot " .. path) end
    end
    assert(m.files["so-data/snap/000002"])
    assert(m.files["so-data/snap/000003"])
  end

  test("checkpoint retains only the two usable snapshots", function()
    local m = machine(seed())
    run(m, boot .. checkpoint)
    retained(m)
  end)

  test("startup removes stale snapshot generations", function()
    local m = machine(seed())
    run(m, boot .. checkpoint)
    m.files["so-data/snap/000001.tmp"] = "broken"
    m.files["so-data/snap/000000.bak"] = "broken"
    m.files["so-data/snap/notes"] = "keep"
    run(m, boot)
    retained(m)
    equal(m.files["so-data/snap/notes"], "keep")
  end)

  test("startup cleanup resumes after interrupted stale-file deletion", function()
    local seedMachine = machine(seed())
    run(seedMachine, boot .. checkpoint)
    for cut=1,6 do
      local m, deleted = machine(seedMachine.files), 0
      for _, n in ipairs({"000000", "000001"}) do
        for _, suffix in ipairs({"", ".tmp", ".bak"}) do m.files["so-data/snap/" .. n .. suffix] = "stale" end
      end
      local original = m.env.fs.delete
      m.env.fs.delete = function(path)
        original(path)
        deleted = deleted + 1
        if deleted == cut then m.killed = true error("power cut") end
      end
      m.spawn(boot)
      assert(m.killed)
      local recovered = machine(m.files)
      run(recovered, boot .. [[assert(log.snap.seq == 3)]])
      retained(recovered)
    end
  end)

  test("previous snapshot still loads after pruning", function()
    local m = machine(seed())
    run(m, boot .. checkpoint)
    m.files["so-data/snap/000003"] = "broken"
    run(m, boot .. [[assert(log.snap.seq == 2)]])
    assert(m.files["so-data/snap/000002"])
  end)

  test("partial snapshot and pointer writes preserve the published state", function()
    for _, path in ipairs({"so-data/snap/000003.tmp", "so-data/snap/latest.tmp"}) do
      local m = machine(seed())
      run(m, boot .. [[assert(log.append({kind="value"}))]])
      local original = m.env.fs.open
      m.env.fs.open = function(name, mode)
        local handle = original(name, mode)
        if name == path and mode == "w" then
          local write = handle.write
          handle.write = function(text)
            write(text:sub(1, math.floor(#text / 2)))
            m.killed = true
            error("power cut")
          end
        end
        return handle
      end
      m.spawn([[assert(log.checkpoint({values={mark=1}, machines={}}))]])
      assert(m.killed)
      local recovered = machine(m.files)
      run(recovered, boot .. [[
        assert(log.snap.seq == 2)
        assert(log.events()[#log.events()].seq == 3)
      ]])
      assert(recovered.files["so-data/snap/000001"])
      assert(recovered.files["so-data/snap/000002"])
    end
  end)

  test("snapshot pruning survives power loss at every disk mutation", function()
    local initial = seed()
    local function intercept(m, hit)
      for _, op in ipairs({"open", "delete", "move"}) do
        local original = m.env.fs[op]
        m.env.fs[op] = function(...)
          local mutation = op ~= "open" or select(2, ...) == "w"
          if mutation then hit(false) end
          local result = original(...)
          if mutation then hit(true) end
          if op == "open" and select(2, ...) == "w" and result then
            for _, method in ipairs({"write", "close"}) do
              local call = result[method]
              result[method] = function(...)
                hit(false)
                local value = call(...)
                hit(true)
                return value
              end
            end
          end
          return result
        end
      end
    end
    local probe, mutations = machine(initial), 0
    run(probe, boot .. [[assert(log.append({kind="value"}))]])
    intercept(probe, function(after) if not after then mutations = mutations + 1 end end)
    run(probe, [[assert(log.checkpoint({values={mark=1}, machines={}}))]])
    for cut = 1, mutations do
      for _, after in ipairs({false, true}) do
        local m, count = machine(initial), 0
        run(m, boot .. [[assert(log.append({kind="value"}))]])
        intercept(m, function(done)
          if not done then count = count + 1 end
          if count == cut and done == after then m.killed = true error("power cut") end
        end)
        m.spawn([[assert(log.checkpoint({values={mark=1}, machines={}}))]])
        assert(m.killed, "crash point not reached")
        local recovered = machine(m.files)
        run(recovered, boot .. [[
          assert(log.snap and (log.snap.seq == 2 or log.snap.seq == 3))
          local events = log.events()
          assert(events[#events].seq == 3 or log.snap.seq == 3)
        ]])
        run(recovered, boot .. checkpoint)
        local latest = recovered.env.store.store("so-data/snap/latest", function() return true end).value.n
        for path in pairs(recovered.files) do
          local n = path:match("^so%-data/snap/(%d+)")
          if n then assert(tonumber(n) >= latest - 1, path) end
        end
      end
    end
  end)
end
