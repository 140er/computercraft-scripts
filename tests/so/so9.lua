local H = dofile("tests/so/harness.lua")
return function(test, equal, read)
  local source = read("install.lua")
  local prefix = source:match("^(.-)local BASE =")
  local roles = prefix and assert(load(prefix .. "return ROLES"))()
  local function files(role)
    local result = {}
    for _, group in ipairs({ roles.common, roles[role] }) do
      for _, path in ipairs(group) do result[#result + 1] = path end
    end
    return result
  end
  local function machine(role, cap)
    local m = H.new().machine({ id = 99, capacity = cap or 16000000 })
    local e, disk, dirs = m.env, {}, { [""] = true }
    m.files, m.dirs, m.calls, m.runs = disk, dirs, 0, {}
    local function norm(p) return p:gsub("^/+", ""):gsub("/+$", "") end
    e.fs = {
      getDir = function(p) return p:match("^(.*)/[^/]*$") or "" end,
      getCapacity = function() return m.capacity end,
      exists = function(p) p = norm(p); return disk[p] ~= nil or dirs[p] == true end,
      makeDir = function(p)
        p = norm(p)
        dirs[p] = true
        for parent in p:gmatch("(.-)/") do dirs[parent] = true end
      end,
      delete = function(p)
        p = norm(p)
        disk[p], dirs[p] = nil, nil
        for name in pairs(disk) do if name:sub(1, #p + 1) == p .. "/" then disk[name] = nil end end
        for name in pairs(dirs) do if name:sub(1, #p + 1) == p .. "/" then dirs[name] = nil end end
      end,
      list = function(p)
        p = norm(p)
        local seen, out = {}, {}
        for _, group in ipairs({ disk, dirs }) do
          for name in pairs(group) do
            local relative = p == "" and name or name:sub(#p + 2)
            local child = relative:match("^[^/]+")
            if child and not seen[child] then seen[child] = true; out[#out + 1] = child end
          end
        end
        return out
      end,
      move = function(a, b)
        a, b = norm(a), norm(b)
        assert(disk[a] ~= nil, "missing source " .. a)
        assert(disk[b] == nil, "destination exists " .. b)
        disk[b], disk[a] = disk[a], nil
      end,
      open = function(p, mode)
        p = norm(p)
        if mode == "w" then
          disk[p] = ""
          return { write = function(s) disk[p] = disk[p] .. s end, close = function() end }
        end
        if not disk[p] then return nil end
        return { readAll = function() return disk[p] end, close = function() end }
      end,
    }
    e.turtle = role == "worker" and {} or nil
    e.pocket = role == "display" and {} or nil
    e.keys = { up = 1, down = 2, enter = 3 }
    e.os.pullEvent = function() return "key", e.keys.enter end
    e.gps = { locate = function(timeout) equal(timeout, 2); return 1, 2, 3 end }
    e.read = function() return "" end
    e.shell = { run = function(...) m.runs[#m.runs + 1] = { ... }; return true end }
    e.http = { get = function(url, headers, binary)
      m.calls = m.calls + 1
      equal(headers, nil); equal(binary, true)
      local path = assert(url:match("^https://raw%.githubusercontent%.com/140er/computercraft%-scripts/refs/heads/server%-only/(.*)$"))
      if m.failAt == m.calls then return nil, "not found" end
      local body = m.badPath == path and (m.badBody or "") or read(path)
      return { getResponseCode = function() return m.status or 200 end,
        readAll = function() return body end, close = function() end }
    end }
    m.run = function(command) return assert(load(source, "@install.lua", "t", e))(command) end
    return m
  end
  local function installed(role)
    local m = machine(role)
    for _, path in ipairs(files(role)) do m.files[path] = "-- previous version\n" .. read(path) end
    m.files[".so-role"] = role
    m.files["startup.lua"] = 'shell.run("' .. roles[role].program .. '")'
    m.files["so-keys"] = "secret"
    m.files["so-data/mine/job"] = "job"
    m.files["so-server.cfg"] = "position"
    return m
  end
  local function snapshot(m)
    local out = {}
    for p, s in pairs(m.files) do out[p] = s end
    return out
  end
  local function unchanged(m, before)
    for p, s in pairs(before) do equal(m.files[p], s, p) end
    for p, s in pairs(m.files) do equal(before[p], s, p) end
    equal(m.env.fs.exists("/.so-new"), false)
    equal(m.env.fs.exists("/.so-old"), false)
  end
  test("SO9 server manifest covers every root so file and crypto file", function()
    assert(roles, "installer needs the role table")
    local set = {}
    for _, path in ipairs(files("server")) do set[path] = true end
    local pipe = assert(io.popen("git ls-files"))
    for path in pipe:lines() do
      if path:match("^so%-[^/]+%.lua$") or path:match("^lib/ccryptolib/") then
        assert(set[path], "missing server file " .. path)
      end
    end
    pipe:close()
  end)
  test("SO9 each role contains its static dependencies and thin clients fit 800 KB", function()
    for _, role in ipairs({ "server", "worker", "display" }) do
      local set, total = {}, 0
      for _, path in ipairs(files(role)) do set[path] = true; total = total + #read(path) end
      if role ~= "server" then assert(total < 800000, role .. " exceeds 800 KB") end
      for path in pairs(set) do
        if path:match("%.lua$") then
          local body = read(path)
          for dep in body:gmatch('dofile%s*%(%s*["\']([^"\']+)["\']') do
            assert(set[dep], role .. " missing " .. dep)
          end
          for dep in body:gmatch('require%s*%(?%s*["\']([^"\']+)["\']') do
            if dep ~= "cc.expect" then
              local target = "lib/" .. dep:gsub("%.", "/") .. ".lua"
              assert(set[target], role .. " missing " .. target)
            end
          end
        end
      end
    end
  end)
  test("SO9 small server disk refuses before HTTP and prints both config lines", function()
    local m = machine("server", 1000000)
    m.run()
    equal(m.calls, 0)
    equal(m.log[1], "so-server: need 16000000 bytes, this disk has 1000000.")
    equal(m.log[2], "Set computer_space_limit in computercraft-server.toml to at least 16000000, then restart the world.")
    equal(next(m.files), nil)
  end)
  test("SO9 fifth download failure leaves every old file unchanged", function()
    local m = installed("worker")
    local before = snapshot(m)
    m.failAt = 5
    m.run("update")
    unchanged(m, before)
    assert(table.concat(m.log):find("not found", 1, true))
    assert(table.concat(m.log):find(files("worker")[5], 1, true))
  end)
  test("SO9 rejects empty, non-200 and invalid Lua responses", function()
    for _, mode in ipairs({ "empty", "status", "syntax" }) do
      local m = installed("worker")
      local before = snapshot(m)
      if mode == "status" then m.status = 404
      else m.badPath = "so-proto.lua"; m.badBody = mode == "syntax" and "not lua !" or "" end
      m.run("update")
      unchanged(m, before)
    end
  end)
  test("SO9 interrupted swaps recover every move for every role", function()
    for _, role in ipairs({ "worker", "display", "server" }) do
      for stop = 1, (#files(role) + 2) * 2 + 1 do
        local m = installed(role)
        local before, count = snapshot(m), 0
        local move = m.env.fs.move
        m.env.fs.move = function(a, b)
          move(a, b)
          count = count + 1
          if count == stop then coroutine.yield("power cut") end
        end
        local co = coroutine.create(function() m.run("update") end)
        local ok, why = coroutine.resume(co)
        assert(ok, why)
        equal(coroutine.status(co), "suspended")
        m.env.fs.move = move
        m.run("recover")
        unchanged(m, before)
        for _, path in ipairs(files(role)) do
          if path:match("%.lua$") then assert(load(m.files[path], "@" .. path)) end
        end
      end
    end
  end)
  test("SO9 interrupted fresh install removes newly introduced files", function()
    for stop = 1, #files("server") + 4 do
      local m = machine("server")
      local move, count = m.env.fs.move, 0
      m.env.fs.move = function(a, b)
        move(a, b)
        count = count + 1
        if count == stop then coroutine.yield("power cut") end
      end
      local co = coroutine.create(function() m.run() end)
      assert(coroutine.resume(co))
      equal(coroutine.status(co), "suspended")
      m.env.fs.move = move
      m.run("recover")
      equal(next(m.files), nil)
      equal(m.env.fs.exists("/.so-new"), false)
      equal(m.env.fs.exists("/.so-old"), false)
    end
  end)
  test("SO9 rollback can itself be interrupted and resumed", function()
    local m = installed("worker")
    local before, move = snapshot(m), m.env.fs.move
    local co = coroutine.create(function()
      m.env.fs.move = function(a, b)
        move(a, b)
        if a == "/.so-new/worker.lua" then coroutine.yield("power cut") end
      end
      m.run("update")
    end)
    assert(coroutine.resume(co))
    equal(coroutine.status(co), "suspended")
    m.env.fs.move = function(a, b) move(a, b); coroutine.yield("power cut") end
    co = coroutine.create(function() m.run("recover") end)
    assert(coroutine.resume(co))
    equal(coroutine.status(co), "suspended")
    m.env.fs.move = move
    m.run("recover")
    unchanged(m, before)
  end)
  test("SO9 committed transaction finishes cleanup after interruption", function()
    local m = installed("worker")
    local delete = m.env.fs.delete
    m.env.fs.delete = function(p)
      if p == "/.so-old" and m.files[".so-new/committed"] then coroutine.yield("power cut") end
      delete(p)
    end
    local co = coroutine.create(function() m.run("update") end)
    assert(coroutine.resume(co))
    equal(coroutine.status(co), "suspended")
    m.env.fs.delete = delete
    m.run("recover")
    for _, path in ipairs(files("worker")) do equal(m.files[path], read(path)) end
    equal(m.env.fs.exists("/.so-old"), false)
    equal(m.env.fs.exists("/.so-new"), false)
  end)
  test("SO9 update preserves keys data journal drops display and server config", function()
    for _, role in ipairs({ "worker", "display", "server" }) do
      local m = installed(role)
      for _, path in ipairs({ "so-journal", "so-drops", "so-display" }) do m.files[path] = path end
      m.run("update")
      equal(m.files["so-keys"], "secret")
      equal(m.files["so-data/mine/job"], "job")
      equal(m.files["so-server.cfg"], "position")
      for _, path in ipairs({ "so-journal", "so-drops", "so-display" }) do equal(m.files[path], path) end
      for _, path in ipairs(files(role)) do equal(m.files[path], read(path)) end
    end
  end)
  test("SO9 fresh server writes plain GPS config and recovery startup", function()
    local m = machine("server")
    m.run()
    local cfg = m.env.textutils.unserialize(m.files["so-server.cfg"])
    equal(cfg.pos.x, 1); equal(cfg.pos.y, 2); equal(cfg.pos.z, 3)
    equal(cfg.pos.dim, "minecraft:overworld")
    equal(m.files[".so-role"], "server")
    assert(m.files["startup.lua"]:find('"recover"', 1, true))
    equal(m.runs[1][1], "/so-server.lua")
  end)
  test("SO9 server manual coordinates retry invalid input", function()
    local m = machine("server")
    m.env.gps.locate = function() end
    local input = { "bad", "-4 70 12", "minecraft:the_nether" }
    m.env.read = function() return table.remove(input, 1) end
    m.run()
    local cfg = m.env.textutils.unserialize(m.files["so-server.cfg"])
    equal(cfg.pos.x, -4); equal(cfg.pos.y, 70); equal(cfg.pos.z, 12)
    equal(cfg.pos.dim, "minecraft:the_nether")
  end)
  test("SO9 thin machines install only their role and launch pairing", function()
    for _, role in ipairs({ "worker", "display" }) do
      local m = machine(role)
      m.run()
      equal(m.files[".so-role"], role)
      equal(m.files["so-server.lua"], nil)
      equal(m.runs[1][1], "/" .. roles[role].program)
      equal(m.log[#m.log], "On the server press P, then type the 6-digit code here")
    end
  end)
  test("SO9 role picker supports arrows clicks and monitor default touch", function()
    for _, mode in ipairs({ "arrows", "click", "monitor", "touch" }) do
      local m = machine("server")
      local events = mode == "arrows" and { { "key", 2 }, { "key", 3 } } or { { "mouse_click", 1, 2, 4 } }
      if mode == "monitor" or mode == "touch" then
        m.env.peripheral.find = function() return m.env.term end
        m.env.peripheral.getName = function() return "left" end
        events = mode == "monitor" and { { "key", 3 } } or { { "monitor_touch", "left", 1, 4 } }
      end
      m.env.os.pullEvent = function() return table.unpack(table.remove(events, 1)) end
      m.run()
      equal(m.files[".so-role"], "display")
    end
  end)
  test("SO9 reset needs yes and preserves only installer and ROM", function()
    local m = installed("worker")
    m.files["rom/programs/test"] = "rom"
    local before = snapshot(m)
    m.env.read = function() return "no" end
    m.run("reset")
    unchanged(m, before)
    m.env.read = function() return "yes" end
    m.run("reset")
    for p in pairs(m.files) do assert(p == "install.lua" or p:match("^rom/"), p) end
    equal(m.files["rom/programs/test"], "rom")
  end)
  test("SO9 update shim calls only role installer", function()
    local args
    assert(load(read("update.lua"), "@update.lua", "t", {
      shell = { run = function(...) args = { ... } end },
    }))()
    equal(args[1], "install.lua"); equal(args[2], "update"); equal(#args, 2)
  end)
end
