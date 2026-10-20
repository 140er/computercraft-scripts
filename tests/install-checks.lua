return function(test, read, mocks)
  local function setup()
    local m = mocks.new(false)
    local env = m.env
    env.term.getSize = function() return 51, 19 end
    env.term.isColour = function() return true end
    env.write, env.printError = env.print, env.print
    env.shell = { run = function() return true end }
    env.http = { get = function(url)
      local name = url:match("/([^/]+)%.lua%?")
      local code = name and read(name .. ".lua")
      return code and { readAll = function() return code end, close = function() end }
    end }
    return m, env, assert(load(read("update.lua"), "=update", "t", env))("--module")
  end
  test("update current bundle changes no scripts and does not reboot", function()
    local m, env, updater = setup()
    assert(updater.apply({ "miner.lua" }))
    local before = mocks.encode(m.files)
    local ok, err, changed = updater.apply({ "miner.lua" })
    assert(ok, err)
    assert(changed == 0, "current bundle reported changed scripts")
    assert(mocks.encode(m.files) == before, "current bundle changed installed files")
    env.os.reboot = function() error("current bundle rebooted") end
    assert(load(read("update.lua"), "=update", "t", env))("miner")
    assert(mocks.encode(m.files) == before, "current CLI update changed installed files")
  end)
  test("installer preserves old roles and clean-installs every named role", function()
    local source = read("install.lua")
    local roles = {}
    for id in source:gmatch('{ id = "([^"]+)"') do roles[#roles + 1] = id end
    assert(roles[5] == "roomclient", "existing fifth role changed")
    assert(roles[#roles - 3] == "ar")
    for _, role in ipairs(roles) do
      local m, env = setup()
      m.files = {}
      assert(load(source, "=install", "t", env))(role, "quick")
      assert(m.files["install.lua"] and m.files["update.lua"], role .. " did not install: " .. table.concat(m.output, "\n"))
      assert(not m.files[".fleet-update-journal"], role .. " left a transaction")
      if role == "ar" or role == "hub" or role == "server" then
        for _, f in ipairs({ "ar-hud.lua", "chat-control.lua", "role-adapter.lua", "fleetview.lua", "ssot.lua", "atomic.lua" }) do
          assert(m.files[f], role .. " missing " .. f)
        end
      end
    end
  end)
  test("failed bundle downloads preserve all installed scripts", function()
    local m, env, updater = setup()
    m.files["hub.lua"], m.files["fleetview.lua"] = "return 'old hub'", "return 'old view'"
    local get = env.http.get
    env.http.get = function(url)
      if url:find("/chat-control.lua", 1, true) then return nil end
      return get(url)
    end
    local ok = updater.apply({ "hub.lua" })
    assert(not ok)
    assert(m.files["hub.lua"] == "return 'old hub'")
    assert(m.files["fleetview.lua"] == "return 'old view'")
    assert(not m.files[".fleet-update-journal"])
  end)
  test("release manifest rejects a valid script from another revision", function()
    local m, env, updater = setup()
    m.files["hub.lua"] = "return 'old hub'"
    local get = env.http.get
    env.http.get = function(url)
      if url:find("/hub.lua", 1, true) then
        return { readAll = function() return "return 'other release'" end, close = function() end }
      end
      return get(url)
    end
    local ok, err = updater.apply({ "hub.lua" })
    assert(not ok and err:find("release hash mismatch", 1, true))
    assert(m.files["hub.lua"] == "return 'old hub'")
  end)
  test("failed commit rolls back every script and fresh entrypoint", function()
    local m, env, updater = setup()
    m.files["hub.lua"], m.files["fleetview.lua"] = "return 'old hub'", "return 'old view'"
    local move, failed = env.fs.move, false
    env.fs.move = function(from, to)
      if to == "fleetview.lua" and not failed then failed = true error("injected move failure") end
      return move(from, to)
    end
    assert(not updater.apply({ "ar-role.lua" }))
    assert(m.files["hub.lua"] == "return 'old hub'")
    assert(m.files["fleetview.lua"] == "return 'old view'")
    assert(not m.files["ar-role.lua"])
  end)
  test("restart rolls back an interrupted bundle before fetching", function()
    local m, env, updater = setup()
    m.files["hub.lua"] = "return 'partial'"
    m.files["hub.lua.fleet-backup"] = "return 'old hub'"
    m.files["ar-role.lua"] = "return 'partial'"
    m.files[".fleet-update-journal"] = mocks.encode({ version = 1, files = {
      { file = "hub.lua", existed = true }, { file = "ar-role.lua", existed = false },
    } })
    env.http = nil
    assert(not updater.apply({ "hub.lua" }))
    assert(m.files["hub.lua"] == "return 'old hub'" and not m.files["ar-role.lua"])
    assert(not m.files[".fleet-update-journal"])
  end)
  test("disk recovery entrypoint works when update.lua is missing", function()
    local m, env = setup()
    env.http = nil
    m.files["hub.lua"] = "return 'partial'"
    m.files["hub.lua.fleet-backup"] = "return 'old hub'"
    m.files["update.lua.fleet-backup"] = "return 'old updater'"
    m.files["update.lua.fleet-stage"] = read("update.lua")
    m.files[".fleet-update-journal"] = mocks.encode({ version = 1, files = {
      { file = "hub.lua", existed = true }, { file = "update.lua", existed = true },
    } })
    assert(not m.files["update.lua"])
    assert(load(m.files["update.lua.fleet-stage"], "=update.lua.fleet-stage", "t", env))("--repair")
    assert(m.files["hub.lua"] == "return 'old hub'")
    assert(m.files["update.lua"] == "return 'old updater'")
    assert(not m.files[".fleet-update-journal"])
  end)
  test("cached-only role deployment verifies server hashes", function()
    local m, env, updater = setup()
    env.http = nil
    local reply, corrupt
    local function hash(code)
      local h = 5381
      for i = 1, #code do h = (h * 33 + code:byte(i)) % 4294967296 end
      return string.format("%08x", h)
    end
    env.rednet.lookup = function() return 8 end
    env.rednet.send = function(_, request)
      local code = read(request.file)
      reply = { type = "file", file = request.file, rid = request.rid, offset = 0,
        code = code, size = #code, hash = corrupt and "bad" or hash(code) }
    end
    env.rednet.receive = function() return 8, reply end
    assert(updater.apply({ "ar-role.lua" }))
    assert(m.files["ar-hud.lua"] and m.files["chat-control.lua"])
    m.files = { ["update.lua"] = read("update.lua"), ["install.lua"] = read("install.lua") }
    assert(load(read("install.lua"), "=install", "t", env))("ar", "quick")
    assert(m.files["ar-role.lua"] and m.files["ar-hud.lua"], "cached-only installer missed AR dependencies: " .. table.concat(m.output, "\n"))
    local original = m.files["ar-role.lua"]
    corrupt = true
    assert(not updater.apply({ "ar-role.lua" }))
    assert(m.files["ar-role.lua"] == original)
  end)
  test("disk exhaustion leaves installed scripts intact", function()
    local m, _, updater = setup()
    m.files["hub.lua"] = "return 'old hub'"
    m.capacity = 100
    assert(not updater.apply({ "hub.lua" }))
    assert(m.files["hub.lua"] == "return 'old hub'")
  end)
end
