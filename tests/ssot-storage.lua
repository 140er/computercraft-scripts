return function(A, test)
  local function valid(v) return type(v) == "table" and v.fact == "durable" and type(v.n) == "number" end
  local function clean(path)
    for _, suffix in ipairs({"", ".tmp", ".bak"}) do if fs.exists(path .. suffix) then fs.delete(path .. suffix) end end
  end
  test("tree copies serialize repeated values without aliasing", function()
    local p = {x=1}
    local t = A.copy({a=p,b=p})
    assert(t.a ~= t.b and t.a.x == t.b.x)
    assert(textutils.serialize(t))
  end)
  for _, checkpoint in ipairs({"open","write","close","verify","rotate","promote"}) do
    test("recover generations after " .. checkpoint .. " failure", function()
      local path = "storage-test"
      clean(path)
      local store = A.store(path, valid)
      assert(store.save({fact="durable",n=1}))
      local open, move = fs.open, fs.move
      fs.open = function(file, mode)
        if file == path .. ".tmp" then
          if checkpoint == "open" and mode == "w" then error("injected open failure") end
          if checkpoint == "verify" and mode == "r" then return nil end
          local h = open(file, mode)
          if mode == "w" and h then
            local write, close = h.write, h.close
            h.write = function(bytes)
              if checkpoint == "write" then write(bytes:sub(1,10)) error("injected disk full") end
              write(bytes)
            end
            h.close = function()
              close()
              if checkpoint == "close" then error("injected close failure") end
            end
          end
          return h
        end
        return open(file, mode)
      end
      fs.move = function(from,to)
        if (checkpoint == "rotate" and to == path .. ".bak") or
          (checkpoint == "promote" and to == path) then error("injected crash") end
        return move(from,to)
      end
      local ok = store.save({fact="durable",n=2})
      fs.open, fs.move = open, move
      assert(not ok)
      local recovered = A.store(path, valid)
      assert(recovered.value.fact == "durable" and recovered.value.n >= 1)
      assert(recovered.save({fact="durable",n=3}))
      assert(A.store(path,valid).value.n == 3)
      clean(path)
    end)
  end
  test("explicit small-disk failure preserves an acknowledged state", function()
    local path, space = "storage-small", fs.getFreeSpace
    clean(path)
    local store = A.store(path,valid)
    assert(store.save({fact="durable",n=1}))
    fs.getFreeSpace = function() return 32 end
    local ok = store.save({fact="durable",n=2})
    fs.getFreeSpace = space
    assert(not ok and A.store(path,valid).value.n == 1)
    clean(path)
  end)
end
