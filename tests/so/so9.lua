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
    m.urls, m.remote, m.sha = {}, {}, string.rep("a", 40)
    local function norm(p) return p:gsub("^/+", ""):gsub("/+$", "") end
    e.fs = {
      getDir = function(p) return p:match("^(.*)/[^/]*$") or "" end,
      getCapacity = function() return m.capacity end,
      isReadOnly = function() return false end,
      getDrive = function() return "hdd" end,
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
        table.sort(out)
        return out
      end,
      move = function(a, b)
        a, b = norm(a), norm(b)
        if dirs[a] then
          assert(not dirs[b] and not disk[b], "destination exists " .. b)
          for _, group in ipairs({ disk, dirs }) do
            local moved = {}
            for path, value in pairs(group) do
              if path == a or path:sub(1, #a + 1) == a .. "/" then moved[path] = value end
            end
            for path, value in pairs(moved) do
              group[b .. path:sub(#a + 1)], group[path] = value, nil
            end
          end
          return
        end
        assert(disk[a] ~= nil, "missing source " .. a)
        assert(disk[b] == nil, "destination exists " .. b)
        disk[b], disk[a] = disk[a], nil
      end,
      open = function(p, mode)
        p = norm(p)
        if mode == "w" then
          disk[p] = ""
          return { write = function(s)
            disk[p] = disk[p] .. s
            local used = 0
            for _, bytes in pairs(disk) do used = used + math.max(500, #bytes) end
            m.peak = math.max(m.peak or 0, used)
            assert(used <= m.capacity, "disk limit exceeded")
          end, close = function() end }
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
    e.textutils.unserializeJSON = function(body)
      if body ~= "branch-json" then error("bad JSON") end
      return { commit = { sha = m.sha } }
    end
    e.http = { get = function(url, headers, binary)
      m.urls[#m.urls + 1] = url
      if url == "https://api.github.com/repos/140er/computercraft-scripts/branches/server-only" then
        if m.apiError then error("HTTP disabled") end
        if m.apiFail then return nil, "API unavailable" end
        return { getResponseCode = function() return m.apiStatus or 200 end,
          readAll = function() return m.apiBody or "branch-json" end, close = function() end }
      end
      if url == "https://github.com/140er/computercraft-scripts.git/info/refs?service=git-upload-pack" then
        if not m.gitBody then return nil, "Git refs unavailable" end
        return { getResponseCode = function() return m.gitStatus or 200 end,
          readAll = function() return m.gitBody end, close = function() end }
      end
      m.calls = m.calls + 1
      if m.onRaw then m.onRaw(url) end
      equal(headers, nil); equal(binary, true)
      local ref, path = url:match("^https://raw%.githubusercontent%.com/140er/computercraft%-scripts/([^/]+)/(.*)$")
      if ref == "refs" then path = path:match("^heads/server%-only/(.*)$") end
      assert(path, url)
      if m.failAt == m.calls then return nil, "not found" end
      local body = m.badPath == path and (m.badBody or "") or m.remote[path] or read(path)
      return { getResponseCode = function() return m.status or 200 end,
        readAll = function() return body end, close = function() end }
    end }
    m.run = function(command) return assert(load(m.source or source, "@install.lua", "t", e))(command) end
    m.boot = function()
      local run = e.shell.run
      e.shell.run = function(path, ...)
        local bytes = disk[norm(path)]
        if path:match("install%.lua$") or path == "/startup.lua" then
          if not bytes then return false end
          local chunk = assert(load(bytes, "@" .. path, "t", e))
          local ok, err = pcall(chunk, ...)
          assert(ok, err)
          return true
        end
        return run(path, ...)
      end
      if disk["startup.lua"] then assert(load(disk["startup.lua"], "@startup.lua", "t", e))() end
      for _, name in ipairs(e.fs.list("/startup")) do
        local bytes = disk["startup/" .. name]
        if bytes then assert(load(bytes, "@startup/" .. name, "t", e))() end
      end
      e.shell.run = run
    end

    return m
  end
  local function installed(role)
    local m = machine(role, role == "server" and 16000000 or 1000000)
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
      if p == "/.so-prev" and m.files[".so-new/committed"] then coroutine.yield("power cut") end
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
    local input = { "bad", "-4 70 12", "minecraft:the_nether", "" }
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
  test("SO9 reset skips mounted and read-only paths and removes keys and data", function()
    local m = installed("worker")
    m.files["disk/keep"] = "mounted disk"
    m.files["readonly/keep"] = "read-only data"
    m.env.fs.getDrive = function(p) return p == "/disk" and "left" or "hdd" end
    m.env.fs.isReadOnly = function(p) return p == "/readonly" end
    local delete = m.env.fs.delete
    m.env.fs.delete = function(p)
      if p == "/disk" or p == "/readonly" then error("Cannot delete " .. p) end
      delete(p)
    end
    m.env.read = function() return "yes" end
    m.run("reset")
    equal(m.files["disk/keep"], "mounted disk")
    equal(m.files["readonly/keep"], "read-only data")
    assert(m.files["install.lua"])
    equal(m.files["so-keys"], nil)
    equal(m.files["so-data/mine/job"], nil)
    for p in pairs(m.files) do
      assert(p == "install.lua" or p == "disk/keep" or p == "readonly/keep", p)
    end
  end)
  test("SO9 reset reports a failed delete and continues clearing local data", function()
    local m = installed("worker")
    m.files["blocked"] = "cannot delete"
    local delete = m.env.fs.delete
    m.env.fs.delete = function(p)
      if p == "/blocked" then error("delete denied") end
      delete(p)
    end
    m.env.read = function() return "yes" end
    m.run("reset")
    equal(m.files["blocked"], "cannot delete")
    equal(m.files["so-keys"], nil)
    equal(m.files["so-data/mine/job"], nil)
    local output = table.concat(m.log, "\n")
    assert(output:find("/blocked", 1, true))
    assert(output:find("delete denied", 1, true))
  end)
  test("SO9 update shim calls only role installer", function()
    local args
    assert(load(read("update.lua"), "@update.lua", "t", {
      shell = { run = function(...) args = { ... } end },
    }))()
    equal(args[1], "install.lua"); equal(args[2], "update"); equal(#args, 2)
  end)
  test("SO9 first update uses the new installer list and removes retired role files", function()
    local m = installed("server")
    m.files["so-mod-retired.lua"] = "return {name='retired'}"
    m.remote["install.lua"] = source:gsub('"so%-plan%.lua", ', '')
      :gsub('"so%-mod%-shop%.lua", ', '"so-mod-added.lua", "lib/new-helper.lua", ')
    m.remote["so-mod-added.lua"] = "return {name='added'}"
    m.remote["lib/new-helper.lua"] = "return {}"
    m.run("update")
    equal(m.files["so-mod-added.lua"], m.remote["so-mod-added.lua"])
    equal(m.files["so-plan.lua"], nil)
    equal(m.files["so-mod-shop.lua"], nil)
    equal(m.files["so-mod-retired.lua"], nil)
    equal(m.files["so-server.cfg"], "position")
    equal(m.files["so-keys"], "secret")
    equal(m.files["install.lua"], m.remote["install.lua"])
    m.source = m.files["install.lua"]
    m.remote["install.lua"] = source
    m.run("update")
    equal(m.files["so-mod-added.lua"], nil)
    equal(m.files["lib/new-helper.lua"], nil)
    equal(m.files["so-plan.lua"], read("so-plan.lua"))
  end)
  test("SO9 trims saved role whitespace and pins every raw request to one SHA", function()
    local m = installed("worker")
    m.files[".so-role"] = " \tworker\r\n"
    m.run("update")
    equal(m.files[".so-role"], "worker")
    equal(m.files[".so-revision"], m.sha)
    equal(m.urls[1], "https://api.github.com/repos/140er/computercraft-scripts/branches/server-only")
    equal(m.urls[2], "https://raw.githubusercontent.com/140er/computercraft-scripts/" .. m.sha .. "/install.lua")
    for i = 2, #m.urls do
      assert(m.urls[i]:find("/" .. m.sha .. "/", 1, true), m.urls[i])
    end
    equal(m.files["worker.lua"], read("worker.lua"))
  end)
  test("SO9 API failures use only the saved commit or leave the install unchanged", function()
    for _, mode in ipairs({ "offline", "exception", "status", "json", "sha" }) do
      for _, saved in ipairs({ false, true }) do
        local m = installed("display")
        if mode == "offline" then m.apiFail = true
        elseif mode == "exception" then m.apiError = true
        elseif mode == "status" then m.apiStatus = 403
        elseif mode == "json" then m.apiBody = "broken"
        else m.sha = "refs/heads/server-only" end
        local sha = string.rep("b", 40)
        if saved then m.files[".so-revision"] = sha end
        local before = snapshot(m)
        m.run("update")
        if saved then
          equal(m.files[".so-revision"], sha)
          equal(m.files["display.lua"], read("display.lua"))
          for _, url in ipairs(m.urls) do
            if url:find("raw.githubusercontent.com", 1, true) then assert(url:find("/" .. sha .. "/", 1, true)) end
          end
        else
          unchanged(m, before)
          equal(m.calls, 0)
        end
      end
    end
  end)
  test("SO9 a failed pinned download never retries from a branch", function()
    local m = installed("worker")
    local before = snapshot(m)
    m.failAt = 3
    m.run("update")
    unchanged(m, before)
    for i = 2, #m.urls do assert(m.urls[i]:find("/" .. m.sha .. "/", 1, true)) end
  end)
  test("SO9 a branch advance cannot change the commit during an update", function()
    local m = installed("worker")
    local sha = m.sha
    m.onRaw = function() m.sha = string.rep("c", 40) end
    m.run("update")
    equal(m.files[".so-revision"], sha)
    for i = 2, #m.urls do assert(m.urls[i]:find("/" .. sha .. "/", 1, true)) end
  end)
  test("SO9 invalid installer and invalid cached commit leave installed files unchanged", function()
    for _, mode in ipairs({ "empty", "syntax", "incompatible", "cache" }) do
      local m = installed("worker")
      if mode == "cache" then
        m.apiFail = true
        m.files[".so-revision"] = "refs/heads/server-only"
      else
        m.badPath = "install.lua"
        m.badBody = mode == "empty" and "" or mode == "syntax" and "not lua !" or "return true"
      end
      local before = snapshot(m)
      m.run("update")
      unchanged(m, before)
    end
  end)
  test("SO9 every deletion and metadata move rolls back across power loss", function()
    for _, role in ipairs({ "worker", "display", "server" }) do
      local function setup()
        local m = installed(role)
        m.files["so-mod-retired.lua"] = "old module"
        m.files["retired-util.lua"] = "old helper"
        m.files[".so-files"] = m.env.textutils.serialize({ "retired-util.lua" })
        m.files[".so-revision"] = string.rep("b", 40)
        return m
      end
      local probe, count = setup(), 0
      local move = probe.env.fs.move
      probe.env.fs.move = function(a, b)
        move(a, b)
        if not probe.files[".so-new/committed"] then count = count + 1 end
      end
      probe.run("update")
      equal(probe.files["so-mod-retired.lua"], nil)
      equal(probe.files["retired-util.lua"], nil)
      for stop = 1, count do
        local m = setup()
        local before, moves = snapshot(m), 0
        local native = m.env.fs.move
        m.env.fs.move = function(a, b)
          native(a, b)
          moves = moves + 1
          if moves == stop then coroutine.yield("power cut") end
        end
        local co = coroutine.create(function() m.run("update") end)
        local ok, err = coroutine.resume(co)
        assert(ok, err)
        equal(coroutine.status(co), "suspended")
        m.env.fs.move = native
        m.source = m.files["install.lua"]
        m.run("recover")
        m.run("recover")
        unchanged(m, before)
      end
    end
  end)
  test("SO9 failed swaps restore deletions and committed cleanup errors remain recoverable", function()
    for _, committed in ipairs({ false, true }) do
      local m = installed("worker")
      m.files["so-mod-retired.lua"] = "old module"
      local before = snapshot(m)
      if committed then
        local delete = m.env.fs.delete
        m.env.fs.delete = function(p)
          if p == "/.so-prev" and m.files[".so-new/committed"] then error("cleanup failed") end
          delete(p)
        end
        m.run("update")
        equal(m.files[".so-new/committed"], "yes")
        m.env.fs.delete = delete
        m.run("recover")
        equal(m.files["so-mod-retired.lua"], nil)
        equal(m.files["worker.lua"], read("worker.lua"))
      else
        local move = m.env.fs.move
        m.env.fs.move = function(a, b)
          move(a, b)
          if a == "/so-mod-retired.lua" then error("disk fault") end
        end
        m.run("update")
        unchanged(m, before)
      end
    end
  end)
  test("SO9 worker and display stay below 1 MB during the complete update", function()
    for _, role in ipairs({ "worker", "display" }) do
      local m = installed(role)
      m.run("update")
      assert(m.peak < 1000000, role .. " peak " .. tostring(m.peak))
      equal(m.files[".so-revision"], m.sha)
      print("SO9 " .. role .. " peak charged bytes=" .. m.peak)
    end
  end)
  test("SO9 first update can resolve a SHA through Git refs when the API is blocked", function()
    local m = installed("worker")
    m.apiFail = true
    local function packet(value) return string.format("%04x", #value + 4) .. value end
    local sha = string.rep("d", 40)
    m.gitBody = packet("# service=git-upload-pack\n") .. "0000" ..
      packet(string.rep("b", 40) .. " HEAD\0capabilities\n") ..
      packet(string.rep("c", 40) .. " refs/heads/server-only-ui\n") ..
      packet(sha .. " refs/heads/server-only\n") .. "0000"
    m.run("update")
    equal(m.files[".so-revision"], sha)
    equal(m.files["worker.lua"], read("worker.lua"))
    equal(m.calls, #files("worker"))
    for _, url in ipairs(m.urls) do
      if url:find("raw.githubusercontent.com", 1, true) then assert(url:find("/" .. sha .. "/", 1, true)) end
    end
  end)
  test("SO9 malformed Git refs cannot select a moving ref or modify an existing install", function()
    for _, body in ipairs({ "bad", "0001", "ffffshort", "0044" .. string.rep("e", 40) .. " refs/heads/server-only-ui\n" }) do
      local m = installed("display")
      m.apiFail, m.gitBody = true, body
      local before = snapshot(m)
      m.run("update")
      unchanged(m, before)
      equal(m.calls, 0)
    end
  end)
  test("SO9 downloaded installer must still define the saved role", function()
    local m = installed("worker")
    m.remote["install.lua"] = source:gsub('  worker = { program = "worker.lua", "worker.lua" },', '')
    local before = snapshot(m)
    m.run("update")
    unchanged(m, before)
  end)
  test("SO9 rejects unsafe saved file paths and invalid handoff revisions", function()
    for _, path in ipairs({ "../so-keys", "lib/../../so-keys", "/startup.lua", "so-server.cfg" }) do
      local m = installed("worker")
      m.files[".so-files"] = m.env.textutils.serialize({ path })
      local before = snapshot(m)
      m.run("update")
      unchanged(m, before)
    end
    local m = installed("worker")
    local before = snapshot(m)
    local apply = assert(load(source, "@install.lua", "t", m.env))("prepare")
    local ok = pcall(apply, "update", { revision = "server-only", previous = {}, role = "worker" })
    equal(ok, false)
    unchanged(m, before)
  end)
  test("SO9 rollback restores exact files manifest commit and preserves live data", function()
    for _, role in ipairs({ "worker", "display", "server" }) do
      local m = installed(role)
      m.files[".so-files"] = m.env.textutils.serialize(files(role))
      m.files[".so-revision"] = string.rep("b", 40)
      m.files["so-mod-retired.lua"] = "return {}"
      local before = snapshot(m)
      m.remote["install.lua"] = source:gsub('"so%-store%.lua",', '"so-store.lua", "lib/added.lua",')
      m.remote["lib/added.lua"] = "return {}"
      m.run("update")
      equal(m.files[".so-prev/.so-revision"], before[".so-revision"])
      assert(m.files[".so-prev/manifest"])
      m.files["so-keys"] = "new pairing"
      m.files["so-server.cfg"] = "new config"
      m.files["so-data/mine/job"] = "new job"
      m.files["so-journal"] = "new journal"
      before["so-keys"], before["so-server.cfg"] = "new pairing", "new config"
      before["so-data/mine/job"], before["so-journal"] = "new job", "new journal"
      local calls = m.calls
      m.source = m.files["install.lua"]
      m.run("rollback")
      unchanged(m, before)
      equal(m.calls, calls)
      equal(m.env.fs.exists("/.so-prev"), false)
    end
  end)
  test("SO9 pinned bootstrap retains the previous release without a handoff update flag", function()
    local m = installed("worker")
    m.source = source:gsub(", updating = updating", "")
    local previous = m.files["worker.lua"]
    m.run("update")
    equal(m.files[".so-prev/worker.lua"], previous)
    assert(m.files[".so-prev/manifest"])
  end)
  test("SO9 retains only the most recent release within the client disk budget", function()
    for _, role in ipairs({ "worker", "display" }) do
      local m = installed(role)
      m.run("update")
      local previous = m.files[role == "worker" and "worker.lua" or "display.lua"]
      m.remote[role .. ".lua"] = "return {}"
      m.sha = string.rep("c", 40)
      m.run("update")
      equal(m.files[".so-prev/.so-revision"], string.rep("a", 40))
      equal(m.files[".so-prev/" .. role .. ".lua"], previous)
      m.run("rollback")
      assert(m.peak < 1000000, "client disk budget")
      print("SO9 " .. role .. " retained-release rollback peak charged bytes=" .. m.peak)
    end
  end)
  test("SO9 every rollback filesystem step recovers to a complete bootable release", function()
    for _, role in ipairs({ "worker", "display", "server" }) do
      local stop, total = 1, nil
      repeat
        local m = installed(role)
        m.files[".so-revision"] = string.rep("b", 40)
        m.files["startup.lua"] = 'if shell.run("/install.lua", "recover") then shell.run("/' .. roles[role].program .. '") end'
        local previous = snapshot(m)
        m.run("update")
        local current = snapshot(m)
        local count, originals = 0, {}
        local function step()
          count = count + 1
          if count == stop then coroutine.yield("power cut") end
        end
        for _, name in ipairs({ "open", "makeDir", "move", "delete" }) do
          local original = m.env.fs[name]
          originals[name] = original
          m.env.fs[name] = function(...)
            local result = original(...)
            if name == "open" and result then
              for _, method in ipairs({ "write", "close" }) do
                local call = result[method]
                if call then result[method] = function(...) local out = call(...); step(); return out end end
              end
            end
            step()
            return result
          end
        end
        m.source = m.files["install.lua"]
        local co = coroutine.create(function() m.run("rollback") end)
        local ok, err = coroutine.resume(co)
        assert(ok, err)
        local cut = coroutine.status(co) == "suspended"
        for name, original in pairs(originals) do m.env.fs[name] = original end
        m.boot()
        assert(#m.runs > 0, "role did not boot at step " .. stop)
        local expected = m.files[".so-revision"] == string.rep("b", 40) and previous or current
        for path, bytes in pairs(expected) do
          if path:sub(1, 1) ~= "." or path == ".so-files" or path == ".so-role" or path == ".so-revision" then
            equal(m.files[path], bytes, path .. " cut " .. stop)
          end
        end
        for _, path in ipairs(files(role)) do
          if path:match("%.lua$") then assert(load(m.files[path], "@" .. path)) end
        end
        assert(load(m.files["startup.lua"], "@startup.lua"))
        equal(m.files["so-keys"], "secret")
        equal(m.env.fs.exists("/.so-new"), false)
        equal(m.env.fs.exists("/.so-old"), false)
        if not cut then total = count end
        stop = stop + 1
      until total
    end
  end)
  test("SO9 rollback refuses a missing release or incompatible protocol", function()
    local m = installed("worker")
    local before = snapshot(m)
    equal(pcall(m.run, "rollback"), false)
    unchanged(m, before)
    m.run("update")
    m.files[".so-protocol"] = "2"
    before = snapshot(m)
    equal(pcall(m.run, "rollback"), false)
    unchanged(m, before)
  end)
  test("SO9 dimension menu accepts known ids and rejects typos before saving", function()
    for input, dim in pairs({ [""] = "minecraft:overworld", ["0"] = "minecraft:overworld",
      ["-1"] = "minecraft:the_nether", ["1"] = "minecraft:the_end",
      ["minecraft:overworld"] = "minecraft:overworld", ["minecraft:the_nether"] = "minecraft:the_nether",
      ["minecraft:the_end"] = "minecraft:the_end", overworld="minecraft:overworld",
      nether="minecraft:the_nether", the_nether="minecraft:the_nether",
      ["end"]="minecraft:the_end", the_end="minecraft:the_end" }) do
      local m = machine("server")
      local answers = { "overwrold", "minecraft:typo", input, "" }
      m.env.read = function() return assert(table.remove(answers, 1)) end
      m.run()
      local cfg = m.env.textutils.unserialize(m.files["so-server.cfg"])
      equal(cfg.pos.dim, dim)
      local output = table.concat(m.log, "\n")
      assert(output:find("Invalid dimension", 1, true))
      assert(output:find("1 2 3", 1, true))
      assert(output:find("Save this? (Enter / n)", 1, true))
    end
  end)
  test("SO9 rejects invalid GPS and manual bounds and allows correcting confirmation", function()
    local m = machine("server")
    m.env.gps.locate = function() return math.huge, 64, 0 end
    local answers = { "30000001 64 0", "0 -2049 0", "0 2049 0", "0 64 0.5", "0 nan 0",
      "1 64 2", "", "n", "-30000000 -2048 30000000", "1", "" }
    m.env.read = function() return assert(table.remove(answers, 1)) end
    m.run()
    local pos = m.env.textutils.unserialize(m.files["so-server.cfg"]).pos
    equal(pos, { x = -30000000, y = -2048, z = 30000000, dim = "minecraft:the_end" })
  end)

end
