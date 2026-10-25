local H = dofile("tests/so/harness.lua")

return function(test, equal)
  local function machine(files, directories)
    local net = H.new()
    local m = net.machine({ id = 1, directories = directories ~= false })
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

  local function legacySave()
    local files = {}
    local function save(path, value, generation)
      files[path] = H.encode({ schema=1, generation=generation or 1, value=value })
    end
    save("so-data/snap/000001", {seq=16,first=1,values={mark=16},machines={}})
    save("so-data/snap/000002", {seq=24,first=6,values={mark=24},machines={}})
    save("so-data/snap/latest", {n=2,seq=24,first=6}, 2)
    save("so-data/snap/latest.bak", {n=1,seq=16,first=1})
    -- The old checkpoint at 24 already deleted segments 1 through 5.
    for seq=6,25 do
      save(string.format("so-data/log/%06d",seq), {
        events={{seq=seq,seg=seq,kind="value",data=seq}},
      })
    end
    return files
  end

  test("old saves recover committed event 25 without reusing its sequence", function()
    for _, unreadable in ipairs({false, true}) do
      for _, directories in ipairs({false, true}) do
        local m = machine(legacySave(), directories)
        if unreadable then m.files["so-data/snap/000002"] = "broken" end
        run(m, boot)
        equal(m.env.log.snap.seq, unreadable and 16 or 24)
        run(m, [[
          local events = log.events()
          assert(#events == 20 and events[1].seq == 6)
          assert(events[#events].seq == 25 and events[#events].data == 25)
          assert(log.status().seq == 25)
          local ev = {kind="value",data=26}
          assert(log.append(ev) and ev.seq == 26, "committed sequence reused")
        ]])
        local recovered = machine(m.files, directories)
        run(recovered, boot .. [[
          assert(log.status().seq == 26)
          assert(log.events()[#log.events()].seq == 26)
          local ev = {kind="value",data=27}
          assert(log.append(ev) and ev.seq == 27)
        ]])
      end
    end
  end)

  test("old saves skip missing leading segments and recover surviving generations", function()
    for _, unreadable in ipairs({false, true}) do
      local files = legacySave()
      for n=6,8 do files[string.format("so-data/log/%06d",n)] = nil end
      files["so-data/log/000009.tmp"], files["so-data/log/000009"] = files["so-data/log/000009"], nil
      files["so-data/log/000025.bak"], files["so-data/log/000025"] = files["so-data/log/000025"], nil
      if unreadable then files["so-data/snap/000002"] = "broken" end
      local m = machine(files)
      run(m, boot .. [[
        local events = log.events()
        assert(events[1].seq == 9 and events[#events].seq == 25)
        assert(log.status().seq == 25)
        local ev = {kind="value"}
        assert(log.append(ev) and ev.seq == 26)
      ]])
    end
  end)

  local function windowSeed(last)
    local m = machine()
    run(m, "local last=" .. (last or 24) .. boot .. [[
      for i=1,16 do assert(log.append({kind="value",data=string.rep("x",50000)})) end
      assert(log.checkpoint({values={mark=16},machines={}}))
      for i=17,20 do assert(log.append({kind="value",data=string.rep("x",50000)})) end
      assert(log.checkpoint({values={mark=20},machines={}}))
      for i=21,last do assert(log.append({kind="value",data=string.rep("x",50000)})) end
      assert(log.checkpoint({values={mark=last},machines={}}))
    ]])
    return m.files
  end

  test("snapshot fallback retains every event after the previous checkpoint", function()
    local files = windowSeed()
    for _, reboot in ipairs({false, true}) do
      local m = machine(files)
      if reboot then run(m, boot) end
      m.files["so-data/snap/000003"] = "broken"
      run(m, boot .. [[
        assert(log.snap.seq == 20 and log.snap.values.mark == 20)
        local nextSeq = log.snap.seq + 1
        for _, ev in ipairs(log.events()) do
          if ev.seq > log.snap.seq then
            assert(ev.seq == nextSeq, "gap after previous snapshot")
            nextSeq = nextSeq + 1
          end
        end
        assert(nextSeq == 25, "missing events after previous snapshot")
      ]])
    end
  end)

  test("repeated checkpoints never move the segment floor backwards", function()
    local m = machine(windowSeed(21))
    run(m, boot .. [[
      local first = log.snap.first
      assert(log.checkpoint({values={mark=21},machines={}}))
      local latest = store.store("so-data/snap/000004",function() return true end).value
      assert(latest.first >= first, "segment floor moved backwards")
    ]])
    m.files["so-data/snap/000004"] = "broken"
    run(m, boot .. [[
      assert(log.snap.seq == 21)
      local events = log.events()
      assert(events[1].seg == log.snap.first and events[#events].seq == 21)
    ]])
  end)

  test("checkpoint and startup remove only segments older than the previous snapshot", function()
    local m = machine(windowSeed())
    run(m, boot .. [[
      local previous = store.store("so-data/snap/000002",function() return true end).value
      assert(previous.first > 1 and previous.first < log.snap.first)
      assert(log.events()[1].seg == log.snap.first, "replayed below the newest snapshot's first")
      for n=1,24 do
        local path = string.format("so-data/log/%06d",n)
        assert(fs.exists(path) == (n >= previous.first), "wrong retained segment " .. n)
      end
      assert(log.checkpoint({values={mark=24},machines={}}))
    ]])
    run(m, boot .. [[
      local previous = store.store("so-data/snap/000003",function() return true end).value
      for n=1,24 do
        local path = string.format("so-data/log/%06d",n)
        assert(fs.exists(path) == (n >= previous.first), "stale segment " .. n)
      end
    ]])
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
