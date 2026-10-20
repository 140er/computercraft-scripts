return function(test, read, mocks)
  local function fixture()
    local m = mocks.new(false)
    local env, requests = m.env, {}
    m.files = {}
    env.term.getSize = function() return 51, 19 end
    env.term.isColour = function() return true end
    env.write, env.printError = env.print, env.print
    env.shell = { run = function() return true end }
    local function clean(path) return path:gsub("^/+", ""):gsub("/+$", "") end
    env.fs.isDir = function(path)
      path = clean(path)
      if path == "" then return true end
      for file in pairs(m.files) do
        if file:sub(1, #path + 1) == path .. "/" then return true end
      end
      return false
    end
    env.fs.exists = function(path) return m.files[clean(path)] ~= nil or env.fs.isDir(path) end
    env.fs.getDrive = function(path)
      path = clean(path)
      return path:match("^rom[/]?") and "rom" or path:match("^disk[/]?") and "disk" or "hdd"
    end
    env.fs.list = function(path)
      path = clean(path)
      local names, out = {}, {}
      for file in pairs(m.files) do
        local tail = path == "" and file or file:sub(1, #path + 1) == path .. "/" and file:sub(#path + 2)
        local name = tail and tail:match("^[^/]+")
        if name and not names[name] then names[name] = true out[#out + 1] = name end
      end
      table.sort(out)
      return out
    end
    env.fs.delete = function(path)
      path = clean(path)
      for file in pairs(m.files) do
        if file == path or file:sub(1, #path + 1) == path .. "/" then m.files[file] = nil end
      end
    end
    env.http = { get = function(url)
      local file = assert(url:match("heads/[%w%-]+/([^?]+)"))
      requests[file] = true
      return { readAll = function() return read(file) end, close = function() end }
    end }
    local updater = assert(load(read("update.lua"), "=update", "t", env))("--module")
    return m, env, updater, requests
  end
  local function manifest()
    return assert(load(read("bundle-manifest.lua"), "=manifest", "t", {}))()
  end
  local function expected(role, release)
    local files = { ["bundle-manifest.lua"] = true, [".fleet-role"] = true }
    for _, file in ipairs(release.roles[role].files) do files[file] = true end
    if release.roles[role].startup then files["startup.lua"] = true end
    return files
  end
  local function exact(m, files, retained)
    for file in pairs(files) do assert(m.files[file], "Missing " .. file) end
    for file, content in pairs(retained or {}) do
      assert(m.files[file] == content, "Changed retained data " .. file)
    end
    for file in pairs(m.files) do
      assert(files[file] or retained and retained[file], "Unexpected file " .. file)
    end
  end
  local retained = {
    ["miner.cfg"] = "miner configuration",
    ["warehouse.cfg.bak"] = "warehouse recovery",
    ["nav.state.tmp"] = "navigation recovery",
    ["views.counter"] = "73",
    ["hub.ar-ids.bak"] = "AR ID recovery journal",
    ["hub.3d"] = "legacy view setting",
    ["buddy.memory"] = "remembered routes and notes",
    ["room.recipes"] = "learned recipes",
    ["board.hist"] = "stock history",
    ["board.last"] = "last stock arrivals",
    ["buddy.memory.bak.tmp"] = "nested recovery generation",
    ["room.recipes.bak"] = "recipe recovery",
    ["board.hist.tmp"] = "history recovery",
    ["board.last.old"] = "arrival recovery",
    ["data/nested/value.bin"] = "data",
    ["config/nested/robot.json"] = "configuration",
    ["journals/moves/1"] = "pending movement",
    ["cold-storage/chunks/0.bin"] = "cold block",
    ["keys/controllers/7"] = "secret",
    ["dev.key"] = "dev secret",
    [".settings"] = "settings",
    [".settings.bak"] = "settings recovery",
    ["rom/programs/shell.lua"] = "ROM",
    ["disk/backup.lua"] = "mounted disk",
  }
  for _, file in ipairs({
    "ar.cfg", "api.key", "buddy.cfg", "buddy.state", "builder.cfg", "builder.state", "builder.log",
    "deliver.job", "factory.cfg", "farmer.cfg", "farmer.state", "farmer.log", "hub.state", "hub.release",
    "hub.ar-ids", "hub-ar.counter", "lava.cfg", "lava.state", "lava.log", "lumber.cfg", "lumber.state",
    "lumber.log", "miner.state", "miner.log", "mining.state", "mining-warehouse.state", "nav.state",
    "panel.key", "room.map", "room.idx", "room.pos", "room.cfg", "room.stats", "room.log",
    "server.state", "server.ar-ids", "sorter.cfg", "sorter.stats", "sorter.log", "ssot.cfg",
    "ssot.state", "ssot.counter", "store-nav.state", "warehouse.cfg", "warehouse.state",
  }) do retained[file] = "retained production state: " .. file end
  for _, case in ipairs({ { "buddy", "buddy.memory" }, { "roomsorter", "room.recipes" },
    { "roomclient", "board.hist" }, { "roomclient", "board.last" } }) do
    test("legacy data survives role update: " .. case[2], function()
      local m, _, updater = fixture()
      m.files[case[2]] = "saved production data"
      assert(updater.apply(case[1]))
      assert(m.files[case[2]] == "saved production data", "Deleted " .. case[2])
    end)
  end
  test("every role installs its exact manifest and removes stale files without touching data", function()
    local release = manifest()
    assert(release.schema == 1 and release.roleSchema == 1 and type(release.roles) == "table", "Manifest has no roles")
    for role, spec in pairs(release.roles) do
      if not spec.unavailable then
      local m, env, _, requests = fixture()
      for file, value in pairs(retained) do m.files[file] = value end
      m.files["obsolete.lua"], m.files["old/nested.lua"], m.files["readme.txt"] = "old", "old nested", "old text"
      assert(assert(load(read("install.lua"), "=install", "t", env))(role, "quick"),
        role .. " install failed: " .. table.concat(m.output, "\n"))
      local wanted = expected(role, release)
      exact(m, wanted, retained)
      for file in pairs(requests) do
        assert(file == "bundle-manifest.lua" or wanted[file], role .. " downloaded unrelated " .. file)
      end
      assert(m.files[".fleet-role"] == role .. "\n", "Role not saved")
      if spec.startup then
        local command
        assert(load(m.files["startup.lua"], "=startup", "t", { shell = {
          run = function(...) command = { ... } end,
        } }))()
        assert(mocks.encode(command) == mocks.encode(spec.startup), role .. " starts the wrong program")
      end
      end
    end
  end)
  test("legacy startup migration preserves client board delivery and calibrated arguments", function()
    for _, case in ipairs({
      { "roomsorter", "roomclient", 'shell.run("roomsorter", "board")\n' },
      { "roomsorter", "roomclient", 'shell.run("roomsorter", "client")\n' },
      { "factory", "factory", 'shell.run("factory", "deliver")\n' },
      { "gpshost", "gpshost", 'shell.run("gpshost", "100", "70", "-30")\n' },
      { "miner", "miner", 'shell.run("miner", "east")\n' },
    }) do
      for _, startup in ipairs({ "startup.lua", "startup" }) do
        local m, _, updater = fixture()
        m.files[case[1] .. ".lua"], m.files[startup] = "return 'old role'", case[3]
        for file, value in pairs(retained) do m.files[file] = value end
        assert(updater.apply({ case[1] .. ".lua" }))
        assert(m.files["startup.lua"] == case[3], "Configured arguments changed")
        assert(m.files[".fleet-role"] == case[2] .. "\n", "Wrong migrated role")
        exact(m, expected(case[2], manifest()), retained)
      end
    end
  end)
  test("current installer bootstraps the actual v1 updater through its file transport", function()
    for _, role in ipairs({ "miner", "hub", "buddy", "roomclient", "store" }) do
      local m, env = fixture()
      if role == "miner" then
        local reply
        env.http = nil
        env.rednet.lookup = function() return 8 end
        env.rednet.send = function(_, request)
          local code, hash = read(request.file), 5381
          for i = 1, #code do hash = (hash * 33 + code:byte(i)) % 4294967296 end
          reply = { type = "file", file = request.file, rid = request.rid, offset = 0,
            code = code, size = #code, hash = string.format("%08x", hash) }
        end
        env.rednet.receive = function() return 8, reply end
      end
      m.files["update.lua"] = read("tests/fixtures/update-v1.lua")
      m.files["startup.lua"] = 'shell.run("roomsorter", "board")\n'
      for file, value in pairs(retained) do m.files[file] = value end
      assert(assert(load(read("install.lua"), "=install", "t", env))(role, "quick"))
      exact(m, expected(role, manifest()), retained)
      assert(m.files["update.lua"] == read("update.lua"))
      if role == "roomclient" then
        assert(m.files["startup.lua"] == 'shell.run("roomsorter", "board")\n')
      end
    end
  end)
  test("actual v1 update CLI upgrades itself before role pruning without losing saved data", function()
    -- The fixture is the unchanged updater from 754b6699199fae7890c9b490fb98053f80157768.
    for _, role in ipairs({ "hub", "server", "buddy", "roomsorter", "factory" }) do
      local m, env = fixture()
      m.files["update.lua"] = read("tests/fixtures/update-v1.lua")
      m.files[role .. ".lua"] = "return 'old role'"
      m.files["startup.lua"] = 'shell.run("' .. role .. '", "' .. (role == "roomsorter" and "board" or "deliver") .. '")\n'
      local startup = m.files["startup.lua"]
      for file, value in pairs(retained) do m.files[file] = value end
      assert(assert(load(m.files["update.lua"], "=legacy-update", "t", env))("noreboot"))
      assert(m.files["update.lua"] == read("update.lua"), "v1 could not upgrade itself")
      for file, value in pairs(retained) do assert(m.files[file] == value, "v1 changed data") end
      assert(assert(load(m.files["update.lua"], "=current-update", "t", env))("noreboot"))
      local migrated = role == "roomsorter" and "roomclient" or role
      exact(m, expected(migrated, manifest()), retained)
      assert(m.files["startup.lua"] == startup, "Upgrade changed startup arguments")
    end
  end)
  test("failed legacy updater bootstrap leaves all code and data unchanged", function()
    local m, env = fixture()
    m.files["update.lua"] = read("tests/fixtures/update-v1.lua")
    for file, value in pairs(retained) do m.files[file] = value end
    local before = mocks.encode(m.files)
    env.http = nil
    env.rednet.lookup = function() return nil end
    assert(not assert(load(read("install.lua"), "=install", "t", env))("miner", "quick"))
    assert(mocks.encode(m.files) == before)
  end)
  test("configured extensionless counter and warehouse journals survive role changes", function()
    for _, source in ipairs({ "miner.cfg", "miner.cfg.bak", "miner.cfg.tmp" }) do
      local m, _, updater = fixture()
      local data = {
        [source] = mocks.encode({ ssot = { counterFile = "/robot/private/counter" },
          warehouse = { path = "custom/warehouse-data" } }),
        ["robot/private/counter"] = "counter",
        ["robot/private/counter.tmp.bak"] = "counter recovery",
        ["custom/warehouse-data"] = "warehouse state",
        ["custom/warehouse-data.bak"] = "warehouse recovery",
      }
      for file, value in pairs(data) do m.files[file] = value end
      assert(updater.apply("miner"))
      assert(updater.apply("buddy"))
      exact(m, expected("buddy", manifest()), data)
    end
  end)
  test("configured state in every recoverable config survives cache pruning and role changes", function()
    for _, main in ipairs({ false, true }) do
      local m, _, updater = fixture()
      local data = {
        ["miner.cfg.bak"] = mocks.encode({ ssot = { counterFile = "old-counter" } }),
        ["miner.cfg.tmp"] = mocks.encode({ ssot = { counterFile = "server-code/private-counter" },
          warehouse = { path = "server-code/private-data.tmp" } }),
        ["old-counter"] = "backup counter",
        ["old-counter.bak"] = "backup counter recovery",
        ["server-code/private-counter"] = "active counter",
        ["server-code/private-counter.tmp.bak"] = "active counter recovery",
        ["server-code/private-data.tmp"] = "configured temporary name",
        ["server-code/private-data.tmp.bak"] = "configured temporary recovery",
      }
      if main then
        data["miner.cfg"] = mocks.encode({ warehouse = { path = "main-warehouse" } })
        data["main-warehouse"], data["main-warehouse.tmp"] = "main state", "main recovery"
      end
      for file, value in pairs(data) do m.files[file] = value end
      m.files["server-code/pretend.state"] = "cached code"
      assert(updater.apply("server"))
      exact(m, expected("server", manifest()), data)
      assert(updater.apply("buddy"))
      exact(m, expected("buddy", manifest()), data)
    end
  end)
  test("an abandoned updater coroutine is recovered by a fresh updater after promotion", function()
    local m, env, updater = fixture()
    assert(updater.apply("ar"))
    m.files["atomic.lua"] = m.files["atomic.lua"] .. "\n-- previous release\n"
    for file, value in pairs(retained) do m.files[file] = value end
    local source = { ["bundle-manifest.lua"] = read("bundle-manifest.lua") }
    for _, file in ipairs(manifest().roles.miner.files) do source[file] = read(file) end
    env.http.get = function(url)
      local file = assert(url:match("heads/[%w%-]+/([^?]+)"))
      return { readAll = function() return assert(source[file]) end, close = function() end }
    end
    local before, move = mocks.encode(m.files), env.fs.move
    env.fs.move = function(from, to)
      move(from, to)
      if from == "atomic.lua.fleet-stage" and to == "atomic.lua" then coroutine.yield("power-cut") end
    end
    local process = coroutine.create(function() updater.apply("miner") end)
    local ok, stopped = coroutine.resume(process)
    assert(ok and stopped == "power-cut" and coroutine.status(process) == "suspended")
    assert(m.files[".fleet-update-journal"] and m.files["atomic.lua.fleet-backup"])
    env.fs.move = move
    assert(assert(load(read("update.lua"), "=fresh-update", "t", env))("--repair"))
    assert(mocks.encode(m.files) == before, "Restart did not restore the interrupted release")
  end)
  test("miner and store role closures exclude unrelated entrypoints and rendering", function()
    local release = manifest()
    for _, role in ipairs({ "miner", "store" }) do
      local files = expected(role, release)
      for _, unwanted in ipairs({ "hub.lua", "server.lua", "panel.lua", "roomsorter.lua",
        "fleetview.lua", "ar-hud.lua", "chat-control.lua", "views.lua", "directview.lua" }) do
        assert(not files[unwanted], role .. " includes " .. unwanted)
      end
    end
    assert(not expected("miner", release)["store.lua"])
    assert(not expected("store", release)["miner.lua"])
  end)
  test("updates prune stale files and preserve the selected role and configured startup", function()
    local release = manifest()
    for role, spec in pairs(release.roles) do
      if not spec.unavailable then
      local m, env, updater = fixture()
      assert(updater.apply(role))
      m.files["retired.lua"], m.files["retired/nested.txt"] = "obsolete", "obsolete"
      local original = m.files[release.roles[role].entry]
      m.files[release.roles[role].entry] = "return 'old release'"
      assert(load(read("update.lua"), "=update", "t", env))("noreboot")
      assert(m.files[release.roles[role].entry] == original)
      exact(m, expected(role, release))
      local before = mocks.encode(m.files)
      local ok, err, changed = updater.apply(role)
      assert(ok, err)
      assert(changed == 0 and before == mocks.encode(m.files), role .. " update is not idempotent")
      end
    end
    local m, _, updater = fixture()
    assert(updater.apply("roomclient"))
    m.files["startup.lua"] = 'shell.run("roomsorter", "board")\n'
    assert(updater.apply({ "roomsorter.lua" }))
    assert(m.files["startup.lua"] == 'shell.run("roomsorter", "board")\n')
  end)
  test("role changes atomically replace startup and remove the previous role", function()
    local m, env, updater = fixture()
    local release = manifest()
    for file, value in pairs(retained) do m.files[file] = value end
    for _, role in ipairs({ "ar", "miner", "store", "vworld", "pro", "relay", "smartmine" }) do
      if not release.roles[role].unavailable then
      assert(updater.apply(role))
      exact(m, expected(role, release), retained)
      end
    end
    assert(updater.apply("miner"))
    m.files["stale.lua"] = "stale"
    local before, move = mocks.encode(m.files), env.fs.move
    env.fs.move = function(from, to)
      if from == "stale.lua" then error("injected stale removal failure") end
      return move(from, to)
    end
    local ok = updater.apply("store")
    assert(not ok and mocks.encode(m.files) == before, "Role change did not roll back deletions and startup")
  end)
  test("failed role downloads leave stale files and state untouched", function()
    local m, env, updater = fixture()
    assert(updater.apply("miner"))
    m.files["stale.lua"] = "obsolete"
    m.files["cold-store/old.bin"] = "cold data"
    local before, get = mocks.encode(m.files), env.http.get
    env.http.get = function(url)
      if url:find("/store.lua", 1, true) then return nil end
      return get(url)
    end
    assert(not updater.apply("store"))
    assert(mocks.encode(m.files) == before, "Failed download changed the disk")
  end)
  test("server cache is cleared on install, update, and role change even with data-like names", function()
    local m, _, updater = fixture()
    for file, value in pairs(retained) do m.files[file] = value end
    for _, role in ipairs({ "server", "server", "miner" }) do
      m.files["server-code/miner.lua"] = "cached"
      m.files["server-code/pretend.state"] = "cached"
      m.files["server-code/keys/stale.key.bak"] = "cached"
      assert(updater.apply(role))
      exact(m, expected(role, manifest()), retained)
    end
  end)
  test("a failed cache prune restores cached code and user data byte for byte", function()
    local m, env, updater = fixture()
    assert(updater.apply("server"))
    for file, value in pairs(retained) do m.files[file] = value end
    m.files["server-code/a.lua"] = "cached"
    m.files["server-code/keys/stale.key.bak"] = "cached"
    m.files["server-code/z.state"] = "cached"
    local before, move, removed = mocks.encode(m.files), env.fs.move, 0
    env.fs.move = function(from, to)
      if from:sub(1, 12) == "server-code/" then
        if from == "server-code/z.state" then error("injected cache removal failure") end
        if to == from .. ".fleet-backup" then removed = removed + 1 end
      end
      return move(from, to)
    end
    assert(not updater.apply("server"))
    assert(removed >= 2, "Cache failure happened before prior removals")
    assert(mocks.encode(m.files) == before, "Cache rollback changed files or user data")
  end)
  test("interrupted stale removal restores nested files before fetching", function()
    local m, env, updater = fixture()
    m.files["old/nested.lua.fleet-backup"] = "old code"
    m.files[".fleet-update-journal"] = mocks.encode({ version = 2, files = {
      { file = "old/nested.lua", existed = true, remove = true },
    } })
    env.http = nil
    assert(not updater.apply("miner"))
    assert(m.files["old/nested.lua"] == "old code")
    assert(not m.files["old/nested.lua.fleet-backup"] and not m.files[".fleet-update-journal"])
  end)
  test("interrupted staging is cleaned before a new role transaction", function()
    local m, _, updater = fixture()
    m.files["miner.lua.fleet-stage"] = "interrupted download"
    m.files[".fleet-update-journal.new"] = "partial journal"
    m.files[".fleet-update-committed"] = "old marker"
    assert(updater.apply("miner"))
    exact(m, expected("miner", manifest()))
  end)
  test("orphan cleanup preserves data and configured state with transaction-like names", function()
    local m, env, updater = fixture()
    local data = {
      ["data/user.fleet-stage"] = "user data",
      ["data/user.fleet-backup"] = "user backup",
      ["journals/.fleet-update-journal.new"] = "user journal",
      ["keys/.fleet-update-committed"] = "user key",
      ["miner.cfg"] = mocks.encode({ ssot = { counterFile = "private-counter.fleet-stage" },
        warehouse = { path = "private-warehouse.fleet-backup" } }),
      ["private-counter.fleet-stage"] = "configured counter",
      ["private-counter.fleet-stage.tmp"] = "counter recovery",
      ["private-warehouse.fleet-backup"] = "configured warehouse",
      ["private-warehouse.fleet-backup.bak"] = "warehouse recovery",
    }
    for file, value in pairs(data) do m.files[file] = value end
    assert(updater.apply("miner"))
    exact(m, expected("miner", manifest()), data)
    local before, get = mocks.encode(m.files), env.http.get
    env.http.get = function(url)
      if url:find("/store.lua", 1, true) then return nil end
      return get(url)
    end
    assert(not updater.apply("store"))
    assert(mocks.encode(m.files) == before, "Failed download changed protected transaction-like data")
  end)
  test("configured data overlapping updater paths refuses installation without changing disk", function()
    for _, path in ipairs({ ".fleet-update-journal", ".fleet-update-journal.new", ".fleet-update-committed",
      ".fleet-role", "miner.lua", "miner.lua.fleet-stage", "miner.lua.fleet-backup", "startup.lua" }) do
      local m, _, updater = fixture()
      m.files["miner.cfg"] = mocks.encode({ ssot = { counterFile = path } })
      m.files[path] = "configured user state"
      local before = mocks.encode(m.files)
      assert(not updater.apply("miner"), "Installer accepted a conflicting data path: " .. path)
      assert(mocks.encode(m.files) == before, "Installer changed conflicting data: " .. path)
    end
  end)
  test("an unclaimed backup stops cleanup without deleting the recovery copy", function()
    local m, _, updater = fixture()
    m.files["retired.lua.fleet-backup"] = "recoverable code"
    local before = mocks.encode(m.files)
    local ok, err = updater.apply("miner")
    assert(not ok and err:find("unclaimed backup", 1, true))
    assert(before == mocks.encode(m.files))
  end)
  test("manifest declares deferred Ed25519 authentication separately from release checksums", function()
    local release = manifest()
    assert(release.signature.algorithm == "Ed25519")
    assert(release.signature.status == "pending-h1h2")
    assert(release.signature.file == "bundle-manifest.sig")
    assert(release.checksum == "djb2")
  end)
  test("unavailable roles fail before changing installed code or data", function()
    for role, spec in pairs(manifest().roles) do
      if spec.unavailable then
        local m, _, updater = fixture()
        assert(updater.apply("miner"))
        m.files["cold-store/saved.bin"], m.files["obsolete.lua"] = "data", "stale code"
        local before = mocks.encode(m.files)
        local ok, err = updater.apply(role)
        assert(not ok and err:find(spec.unavailable, 1, true), "Unavailable role did not explain its dependency")
        assert(mocks.encode(m.files) == before, "Unavailable role changed installed files")
      end
    end
  end)
end
