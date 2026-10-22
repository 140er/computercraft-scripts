local H = dofile("tests/so/harness.lua")

return function(test)
  local function machine()
    local net = H.new()
    local m = net.machine({id=1, directories=true})
    m.install({"so-store.lua", "so-log.lua", "so-mod-state.lua"})
    return m
  end
  local function run(m, code)
    m.spawn(code)
    assert(not m.error, m.error)
  end
  local boot = [[
    store = dofile("so-store.lua")
    box = store.store("state", function(v) return type(v.n)=="number" end)
    assert(box.save({n=1}))
  ]]

  test("space precheck changes no files and the same store retries", function()
    local m = machine()
    run(m, boot)
    local before = H.encode(m.files)
    local free = m.env.fs.getFreeSpace
    m.env.fs.getFreeSpace = function() return 0 end
    run(m, [[assert(not box.save({n=2}))]])
    assert(H.encode(m.files) == before, "precheck changed disk")
    m.env.fs.getFreeSpace = free
    run(m, [[assert(box.save({n=3})); assert(store.store("state", function() return true end).value.n==3)]])
  end)

  test("space precheck leaves recovered temporary and backup sources untouched", function()
    for _, suffix in ipairs({".tmp", ".bak"}) do
      local m = machine()
      run(m, boot)
      m.files["state" .. suffix], m.files.state = m.files.state, nil
      run(m, [[box=store.store("state", function() return true end)]])
      local before, free = H.encode(m.files), m.env.fs.getFreeSpace
      m.env.fs.getFreeSpace = function() return 0 end
      run(m, [[assert(not box.save({n=2}))]])
      assert(H.encode(m.files)==before, "precheck changed recovered source")
      m.env.fs.getFreeSpace = free
      run(m, [[assert(box.save({n=3})); assert(store.store("state", function() return true end).value.n==3)]])
    end
  end)

  test("store retries after a failure at every save mutation", function()
    local function intercept(m, hit)
      for _, op in ipairs({"open", "delete", "move"}) do
        local original = m.env.fs[op]
        m.env.fs[op] = function(...)
          local mutation = op ~= "open" or select(2, ...) == "w"
          if mutation then hit(false) end
          local result = original(...)
          if mutation then hit(true) end
          if op == "open" and select(2, ...) == "w" then
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
    local probe, total = machine(), 0
    run(probe, boot .. [[assert(box.save({n=2}))]])
    intercept(probe, function(after) if not after then total = total + 1 end end)
    run(probe, [[assert(box.save({n=3}))]])
    for cut=1,total do
      for _, after in ipairs({false,true}) do
        local m, count, fired = machine(), 0, false
        run(m, boot .. [[assert(box.save({n=2}))]])
        intercept(m, function(done)
          if not done then count = count + 1 end
          if not fired and count==cut and done==after then fired=true error("disk failure") end
        end)
        run(m, [[assert(not box.save({n=3})); assert(box.save({n=4}))
          assert(store.store("state", function() return true end).value.n==4)]])
        assert(fired)
      end
    end
  end)

  test("a partial first save retries on the same store", function()
    local m = machine()
    run(m, [[store=dofile("so-store.lua")
      box=store.store("state", function(v) return type(v.n)=="number" end)]])
    local original = m.env.fs.open
    m.env.fs.open = function(path, mode)
      local handle = original(path, mode)
      if mode=="w" then
        local write = handle.write
        handle.write = function(text) write(text:sub(1, 10)); error("disk full") end
      end
      return handle
    end
    run(m, [[assert(not box.save({n=1}))]])
    m.env.fs.open = original
    run(m, [[assert(box.save({n=2})); assert(store.store("state", function() return true end).value.n==2)]])
  end)

  test("logging resumes after nearly full disk is freed without reboot", function()
    for _, partial in ipairs({false,true}) do
      local m = machine()
      run(m, [[SO={store=dofile("so-store.lua"), mods={}}
        state=dofile("so-mod-state.lua")
        assert(state.emit("value", 1))]])
      local function used()
        local bytes = 0
        for _, text in pairs(m.files) do bytes = bytes + #text end
        return bytes
      end
      local open = m.env.fs.open
      m.capacity = used() + (partial and 12000 or 100)
      if partial then
        m.env.fs.open = function(path, mode)
          local handle = open(path, mode)
          if mode=="w" then
            m.files.ballast = string.rep("x", m.capacity - used() - 20)
          end
          return handle
        end
      end
      run(m, [[assert(not state.emit("value", 2)); assert(state.get("value")==1)]])
      m.files.ballast = nil
      m.capacity, m.env.fs.open = 16000000, open
      run(m, [[assert(state.emit("value", 3)); assert(state.get("value")==3)
        local rows=state.history.page({}).entries
        assert(#rows==2 and rows[1].data==1 and rows[2].data==3)
        state=dofile("so-mod-state.lua")
        assert(state.get("value")==3)]])
    end
  end)
end
