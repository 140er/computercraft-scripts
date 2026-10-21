return function(test, equal, read, mocks)
  local hub, miner = read("hub.lua"), read("miner.lua")
  local cfg = { home = { x = 100, y = 64, z = 20 }, facing = 2, spine = 3 }
  local function loadMiner(m)
    local code = assert(miner:match("^(.*)\nopenModem%(%)"))
    return assert(load(code .. [[
return { st = st, getJob = getJob, openModem = openModem, cfg = cfg }
]], "=miner.lua", "t", m.env))()
  end
  local function last(m) return m.messages[#m.messages] end
  local function saved(m) return m.env.textutils.unserialize(m.files["hub.state"]) end

  test("hub hands each new miner the direction the fewest others have and keeps it", function()
    local m = mocks.new(false, { target = "iron" })
    m.start(hub)
    m.status(1, { type = "status", phase = "home", role = "east" })
    m.status(5, { type = "dir?", id = 5 })
    equal(last(m), { type = "dir", dir = "south", from = 99 })
    m.status(5, { type = "status", phase = "home", role = "south" })
    m.status(6, { type = "dir?", id = 6 })
    equal(last(m).dir, "west")
    m.status(5, { type = "dir?", id = 5 })
    equal(last(m).dir, "south", "a miner asking again got another direction")
    equal(saved(m).dirs, { [5] = "south", [6] = "west" })
    m.status(5, { type = "job?", role = "south" })
    equal(last(m).dir, "south")
    m.status(1, { type = "job?", role = "east" })
    equal(last(m).dir, nil, "a miner with its own role was given one")
  end)

  test("pocket panel renames a miner and changes its direction through the hub", function()
    local m = mocks.new(false, { target = "iron" })
    m.start(hub)
    m.status(5, { type = "status", phase = "home", role = "east", label = "Miner-east" })
    m.status(7, { type = "panel", cmd = "name", turtle = 5, text = "  Digger Bob " })
    local rename
    for _, p in ipairs(m.messages) do if p.type == "rename" then rename = p end end
    equal(rename, { type = "rename", target = 5, name = "Digger Bob", from = 99 })
    m.status(7, { type = "panel", cmd = "dir", turtle = 5, dir = "North" })
    local state = last(m)
    equal(state.type, "panel_state")
    equal(state.turtles[1].dir, "north")
    equal(state.turtles[1].label, "Digger Bob")
    m.status(5, { type = "job?", role = "east" })
    equal(last(m).dir, "north")
    m.status(7, { type = "panel", cmd = "dir", turtle = 5, dir = "up" })
    equal(last(m).note, "Direction: east, south, west or north")
  end)

  test("miner switches to the hub's direction at home and starts that quarter fresh", function()
    local m = mocks.miner(cfg, { phase = "home", levels = { [16] = { spine = 9, branch = 2, step = 0 } } })
    m.env.os.reboot = function() error("rebooted", 0) end
    m.env.sleep = function() end
    local api = loadMiner(m)
    api.openModem()
    api.st.phase = "home"
    m.env.rednet.lookup = function() return 99 end
    m.app = coroutine.create(api.getJob)
    m.push()
    local ok, why = pcall(m.push, "rednet_message", 99, { type = "job", paused = true, dir = "north" }, "minearmy")
    assert(not ok and tostring(why):find("rebooted"), "no restart after a new direction: " .. tostring(why))
    equal(m.env.textutils.unserialize(m.files["miner.cfg"]).spine, 0)
    equal(m.env.textutils.unserialize(m.files["miner.state"]).levels, {})
  end)

  test("miner keeps going when the hub's direction is the one it has", function()
    local m = mocks.miner(cfg)
    m.env.os.reboot = function() error("rebooted", 0) end
    local api = loadMiner(m)
    api.openModem()
    api.st.phase = "home"
    m.env.rednet.lookup = function() return 99 end
    m.app = coroutine.create(api.getJob)
    m.push()
    m.push("rednet_message", 99, { type = "job", paused = true, dir = "west" }, "minearmy")
    equal(m.env.textutils.unserialize(m.files["miner.cfg"]).spine, 3)
  end)

  test("setup without a role leaves the direction to the hub and takes a name", function()
    for _, case in ipairs({
      { args = { "setup", "name=Digger Bob" }, spine = nil, label = "Digger Bob" },
      { args = { "setup", "auto" }, spine = nil, label = "Miner-99" },
      { args = { "setup", "east" }, spine = 1, label = "Miner-east" },
      { args = { "setup", "64" }, spine = nil, label = "Miner-99", loc = true },
      { args = { "setup", "64", "left", "name=Lefty" }, spine = 3, label = "Lefty", loc = true },
    }) do
      local m = mocks.miner(cfg)
      m.files["miner.cfg"] = nil
      m.world["100,64,19"] = "minecraft:chest"
      m.env.gps = { locate = function() return m.pos.x, m.pos.y, m.pos.z end }
      local label
      m.env.os.setComputerLabel = function(l) label = l end
      m.env.os.getComputerLabel = function() return label end
      assert(load(miner, "=miner.lua", "t", m.env))(table.unpack(case.args))
      local saved = m.env.textutils.unserialize(assert(m.files["miner.cfg"], table.concat(case.args, " ")))
      equal(saved.spine, case.spine, table.concat(case.args, " "))
      equal(saved.loc, case.loc)
      equal(label, case.label)
    end
  end)

  test("setup digs its own hole and turns around when placed facing the chest", function()
    for _, case in ipairs({ { heading = 2, front = "minecraft:dirt" }, { heading = 0 } }) do
      local m = mocks.miner(cfg)
      m.files["miner.cfg"] = nil
      m.heading = case.heading
      m.world["100,64,19"] = "minecraft:chest"
      if case.front then m.world["100,64,21"] = case.front end
      m.env.gps = { locate = function() return m.pos.x, m.pos.y, m.pos.z end }
      m.env.os.setComputerLabel = function() end
      assert(load(miner, "=miner.lua", "t", m.env))("setup", "east")
      local saved = m.env.textutils.unserialize(assert(m.files["miner.cfg"], "setup failed"))
      equal(saved.facing, 2)
      equal(saved.chest, 0)
      equal(m.world["100,64,19"], "minecraft:chest", "dug up its chest")
      equal(m.world["100,64,21"], nil, "no hole in front")
      equal(m.pos, cfg.home)
    end
  end)

  test("setup says why it failed, last on the screen", function()
    for _, case in ipairs({
      { gps = false, want = "No GPS signal" },
      { gps = true, block = "Movement obstructed", want = "can't step into the hole" },
      { gps = true, args = { "setup", "eats" }, want = "Unknown role" },
    }) do
      local m = mocks.miner(cfg)
      m.files["miner.cfg"] = nil
      m.env.gps = { locate = function() if case.gps then return m.pos.x, m.pos.y, m.pos.z end end }
      m.blockMove = case.block
      m.env.os.setComputerLabel = function() end
      local printed = {}
      m.env.print = function(t) printed[#printed + 1] = tostring(t) end
      assert(load(miner, "=miner.lua", "t", m.env))(table.unpack(case.args or { "setup" }))
      equal(m.files["miner.cfg"], nil)
      assert(printed[#printed]:find(case.want, 1, true), "last line: " .. tostring(printed[#printed]))
    end
  end)

  test("miner set up without a direction asks the hub before it starts", function()
    local m = mocks.miner({ home = cfg.home, facing = 2 })
    m.env.rednet.lookup = function() return 99 end
    local api
    m.app = coroutine.create(function() api = loadMiner(m) end)
    m.push()
    equal(last(m).type, "dir?")
    equal(last(m).shaft, { x = 100, z = 21 })
    m.push("rednet_message", 99, { type = "dir", dir = "south" }, "minearmy")
    equal(m.env.textutils.unserialize(m.files["miner.cfg"]).spine, 2)
    equal(api.cfg.spine, 2)
  end)

  test("install reset wipes the machine but keeps the installer and disks, and the hub forgets it", function()
    local files = { ["rom"] = true, ["disk"] = true, ["install.lua"] = true, ["miner.lua"] = true,
      ["miner.cfg"] = true, ["miner.state"] = true, ["startup.lua"] = true, ["update.lua"] = true }
    local label, sent = "Miner-east", {}
    local env = setmetatable({
      term = { isColour = function() return true end, getSize = function() return 39, 13 end },
      colors = setmetatable({}, { __index = function() return 1 end }),
      shell = { getRunningProgram = function() return "install.lua" end },
      fs = {
        list = function() local l = {} for f in pairs(files) do l[#l + 1] = f end return l end,
        delete = function(f) files[f] = nil end,
        getDrive = function(f) return f == "rom" and "rom" or f == "disk" and "left" or "hdd" end,
      },
      os = { setComputerLabel = function(l) label = l end, getComputerID = function() return 5 end,
        getComputerLabel = function() return label end },
      peripheral = { getNames = function() return { "back" } end, getType = function() return "modem" end,
        call = function() return true end },
      rednet = { open = function() end, broadcast = function(m, p) sent[#sent + 1] = { m = m, p = p } end },
      print = function() end, turtle = {},
    }, { __index = _G })
    local baseline = assert(io.popen("git show main:install.lua", "r"))
    local installCode = baseline:read("*a")
    assert(baseline:close(), "git show main:install.lua failed")
    assert(#installCode > 0, "empty installer baseline")
    assert(load(installCode, "=install.lua", "t", env))("reset", "now")
    local left = {}
    for f in pairs(files) do left[#left + 1] = f end
    table.sort(left)
    equal(left, { "disk", "install.lua", "rom" })
    equal(label, nil)
    equal(sent, { { m = { type = "reset", id = 5 }, p = "minearmy" } })

    local m = mocks.new(false, { target = "iron", overrides = { [5] = "gold" }, bores = { [5] = { x = 1, z = 2, n = 1 } },
      dirs = { [5] = "west" } })
    m.start(hub)
    m.status(5, { type = "status", phase = "home", role = "west" })
    m.status(5, { type = "reset", id = 5 })
    local state = saved(m)
    equal(state.overrides[5], nil)
    equal(state.bores[5], nil)
    equal(state.dirs[5], nil)
    m.status(5, { type = "dir?", id = 5 })
    equal(last(m).dir, "east", "a wiped miner kept its old direction")
  end)
end
