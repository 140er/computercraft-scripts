local Core = dofile("install-core.lua")
local Keys = dofile("install-keys.lua")
local Roles = dofile("install-roles.lua")
local Enrol = dofile("enrol.lua")

local function readFile(path)
  local file = io.open(path, "rb")
  if file then
    local text = file:read("*a")
    file:close()
    return text
  end
  if fs and fs.exists(path) then
    local handle = fs.open(path, "r")
    local text = handle.readAll()
    handle.close()
    return text
  end
end

local function memoryDisk()
  local files = {}
  local api = {}
  function api.exists(path) return files[path] ~= nil end
  function api.isDir() return false end
  function api.list()
    local names = {}
    for name in pairs(files) do
      if not name:find("/", 1, true) and not name:match("%.new$") then names[#names + 1] = name end
    end
    table.sort(names)
    return names
  end
  function api.open(path, mode)
    if mode == "r" then
      local body = assert(files[path], path)
      return { readAll = function() return body end, close = function() end }
    end
    local buf = ""
    return {
      write = function(text) buf = buf .. text end,
      close = function() files[path] = buf end,
    }
  end
  function api.delete(path) files[path] = nil end
  function api.move(from, to) files[to], files[from] = files[from], nil end
  function api.get(path) return files[path] end
  function api.put(path, body) files[path] = body end
  return api
end

local function bundle(role, mark)
  local bodies = {}
  for _, name in ipairs(Roles.files(role)) do
    bodies[name] = "-- " .. role .. " " .. name .. " " .. (mark or "v1") .. "\n"
  end
  return bodies
end

local function index(state, id)
  for i, opt in ipairs(Core.options(state)) do
    if opt.id == id then return i end
  end
  error("no option " .. tostring(id))
end

local function effectsOf(state, event)
  return Core.transition(state, event)
end

local function assertNoGps(effects, where)
  for _, effect in ipairs(effects or {}) do
    assert(effect.op ~= "gps", where or "gps effect")
  end
end

local function freshMiner()
  local state, effects = Core.boot({ kind = "turtle", id = 31, advanced = false, label = false, sides = {} }, Roles.catalog())
  assert(effects[1].op == "scan", "boot scans")
  assertNoGps(effects, "boot")
  state, effects = effectsOf(state, { t = "io", op = "scan", ok = true, value = { kind = "turtle", id = 31, sides = {} } })
  assert(state.step == "source")
  state, effects = effectsOf(state, { t = "choose", n = index(state, "fresh") })
  assert(state.step == "role" and state.source == "fresh")
  state, effects = effectsOf(state, { t = "choose", n = index(state, "miner") })
  assert(state.step == "position" and state.role == "miner")
  state, effects = effectsOf(state, { t = "choose", n = index(state, "f3") })
  assert(state.draft.phase == "x")
  state = effectsOf(state, { t = "text", s = "10" })
  state = effectsOf(state, { t = "text", s = "64" })
  state, effects = effectsOf(state, { t = "text", s = "20" })
  assert(state.step == "facing" and state.pos.frame == "abs" and state.pos.src == "typed")
  assert(state.pos.x == 10 and state.pos.y == 64 and state.pos.z == 20 and state.pos.yAbs == true)
  state, effects = effectsOf(state, { t = "choose", n = index(state, 0) })
  assert(state.step == "review" and state.pos.h == 0, "north is heading 0")
  assertNoGps(effects, "facing")
  state, effects = effectsOf(state, { t = "choose", n = index(state, "go") })
  assert(state.step == "fetch" and effects[1].op == "apply_bundle" and effects[1].role == "miner")
  assertNoGps(effects, "fetch")
  return state, effects
end

return function(test, equal)
  test("every role installs on an empty disk, then reinstalls and upgrades", function()
    for _, role in ipairs(Roles.list()) do
      local disk = memoryDisk()
      local bodies = bundle(role.id, "v1")
      local first, err = Roles.apply(disk, "", role.id, bodies, 1000000)
      assert(first, role.id .. " fresh " .. tostring(err))
      equal(#first.wrote, #role.files, role.id .. " fresh write count")
      for _, name in ipairs(role.files) do
        assert(disk.get(name) == bodies[name], role.id .. " missing " .. name)
      end
      assert(disk.get("hub.lua") == nil or role.id == "hub", role.id .. " kept the hub")
      if role.id == "relay" then assert(disk.get("miner.lua") == nil, "relay installed miner.lua") end
      if role.id == "miner" then assert(disk.get("hub.lua") == nil, "miner installed hub.lua") end
      local again = assert(Roles.apply(disk, "", role.id, bodies, 1000000), role.id .. " reinstall")
      equal(#again.wrote, 0, role.id .. " reinstall wrote files")
      equal(#again.dropped, 0, role.id .. " reinstall deleted files")
      local changed = role.files[1]
      disk.put(changed, "-- stale " .. changed .. "\n")
      disk.put("junk.lua", "junk\n")
      disk.put(role.id .. ".cfg", "keep\n")
      local upgraded = assert(Roles.apply(disk, "", role.id, bodies, 1000000), role.id .. " upgrade")
      equal(upgraded.wrote, { changed }, role.id .. " upgrade set")
      assert(disk.get(changed) == bodies[changed], role.id .. " upgrade bytes")
      assert(disk.get("junk.lua") == nil, role.id .. " left junk.lua")
      assert(disk.get(role.id .. ".cfg") == "keep\n", role.id .. " removed state")
      local quiet = assert(Roles.apply(disk, "", role.id, bodies, 1000000), role.id .. " second reinstall")
      equal(#quiet.wrote, 0, role.id .. " second reinstall")
    end
  end)

  test("full disk and a bad hash write nothing", function()
    local disk = memoryDisk()
    local bodies = bundle("relay")
    local full, err = Roles.apply(disk, "", "relay", bodies, 0)
    assert(full == nil and err == "disk_full", err)
    assert(disk.get("relay.lua") == nil, "full disk wrote relay.lua")
    bodies["relay.lua"] = { text = "relay\n", expect = "00000000" }
    local bad, why = Roles.apply(disk, "", "relay", bodies, 1000000)
    assert(bad == nil and why == "hash_mismatch", why)
    assert(disk.get("relay.lua") == nil, "bad hash wrote relay.lua")
    bodies["relay.lua"] = { text = "relay\n", expect = Roles.hash("relay\n") }
    assert(Roles.apply(disk, "", "relay", bodies, 500), "500 byte slot holds a new file")
    local tight = memoryDisk()
    assert(Roles.apply(tight, "", "relay", bodies, 499) == nil, "499 bytes is short of the 500 byte minimum")
  end)

  test("role bundles fit a 1000000 byte disk with the installer kit", function()
    local sample = readFile("miner.lua")
    if not sample then return end
    local function size(name)
      return math.max(500, #assert(readFile(name), name))
    end
    local kit = 0
    local seenKit = {}
    for _, name in ipairs(Roles.kit) do
      kit = kit + size(name)
      seenKit[name] = true
    end
    for _, role in ipairs(Roles.list()) do
      local total, seen = kit, {}
      for name in pairs(seenKit) do seen[name] = true end
      for _, name in ipairs(role.files) do
        if not seen[name] then total = total + size(name) seen[name] = true end
      end
      assert(total < 1000000, role.id .. " needs " .. total .. " bytes")
    end
  end)

  test("installer files list the same role scripts and never call gps.locate", function()
    local src = assert(readFile("install.lua"))
    for _, role in ipairs(Roles.list()) do
      for _, name in ipairs(role.files) do
        if name ~= "enrol.lua" then
          assert(src:find('"' .. name .. '"', 1, true), role.id .. " list drifted at " .. name)
        end
      end
    end
    for _, name in ipairs({ "install-core.lua", "install-keys.lua", "install-shell.lua", "enrol.lua", "install-roles.lua" }) do
      assert(not readFile(name):find("gps.locate", 1, true), name .. " calls gps.locate")
    end
    local listed = Roles.updateFiles("miner")
    assert(listed, "miner update list")
    local joined = table.concat(listed, " ")
    assert(joined:find("miner.lua", 1, true) and joined:find("install-core.lua", 1, true), "update list")
    equal(Roles.pruneNames("miner", { "hub.lua", "miner.lua", "startup.lua", "notes.cfg" }), { "hub.lua" })
    local shell = assert(readFile("install-shell.lua"))
    assert(shell:find("enrol-confirm", 1, true) and shell:find("install.secret", 1, true), "neighbour confirm")
  end)

  test("fresh miner reaches install with north as heading 0 and no gps effect", function()
    local state, effects = freshMiner()
    state, effects = effectsOf(state, { t = "io", op = "apply_bundle", ok = true, value = { files = { "miner.lua" }, manifest = "abc" } })
    assert(state.step == "pair" and effects[1].op == "write_cfg" and effects[1].cfg.role == "miner")
    assert(effects[1].cfg.pos.h == 0)
    state, effects = effectsOf(state, { t = "io", op = "write_cfg", ok = true })
    assert(state.step == "done" and effects[1].op == "reboot")
    assertNoGps(effects, "done")
  end)

  test("this spot is home uses a relative frame and the nav headings", function()
    local state = Core.boot({ kind = "turtle", id = 31 }, Roles.catalog())
    state = effectsOf(state, { t = "io", op = "scan", ok = true, value = { kind = "turtle", id = 31, sides = {} } })
    state = effectsOf(state, { t = "choose", n = index(state, "fresh") })
    state = effectsOf(state, { t = "choose", n = index(state, "miner") })
    local effects
    state, effects = effectsOf(state, { t = "choose", n = index(state, "here") })
    assert(effects[1].op == "clock")
    assertNoGps(effects, "here")
    state = effectsOf(state, { t = "io", op = "clock", ok = true, value = 1792500000000 })
    assert(state.pos.frame == "f:31:1792500000000", state.pos.frame)
    assert(state.pos.yAbs == false and state.pos.conf == "suspect" and state.pos.src == "reckoned")
    assert(state.pos.x == 0 and state.pos.y == 0 and state.pos.z == 0)
    state = effectsOf(state, { t = "choose", n = index(state, 3) })
    equal(state.pos.h, 3, "west is heading 3")
    local before = Roles.literal(state)
    local ignored, none = effectsOf(state, { t = "io", op = "gps", ok = true, value = { x = 5, y = 6, z = 7 } })
    equal(Roles.literal(state), before, "gps event mutated state")
    equal(ignored.step, state.step)
    equal(#none, 0)
  end)

  test("code and neighbour failures land on the error step and retry", function()
    local function source(kind)
      local state = Core.boot({ kind = kind or "turtle", id = 31, sides = {} }, Roles.catalog())
      return effectsOf(state, { t = "io", op = "scan", ok = true, value = { kind = kind or "turtle", id = 31, sides = {} } })
    end
    local function codeError(code)
      local state = source()
      state = effectsOf(state, { t = "choose", n = index(state, "code") })
      assert(state.step == "enter_code")
      local bad = effectsOf(state, { t = "text", s = "short" })
      assert(bad.step == "enter_code" and bad.draft.note, "short code left the step")
      local effects
      state, effects = effectsOf(state, { t = "text", s = "c:4:1 K7Q2M9XDPT4H6N8R" })
      assert(effects[1].op == "rpc" and effects[1].call == "enrol-hello")
      state = effectsOf(state, { t = "io", op = "rpc", ok = false, error = { code = code, detail = code } })
      assert(state.step == "error" and state.error.code == code, code)
      assert(state.error.retry == "enter_code")
      state, effects = effectsOf(state, { t = "retry" })
      assert(state.step == "enter_code" and state.error == false, code .. " retry")
      assertNoGps(effects, code)
      return state
    end
    codeError("code_expired")
    codeError("code_replayed")
    codeError("code_burned")
    local state, effects = source()
    state, effects = effectsOf(state, { t = "choose", n = index(state, "neighbour") })
    assert(effects[1].op == "scan")
    state = effectsOf(state, { t = "io", op = "scan", ok = true, value = { sides = {} } })
    assert(state.step == "error" and state.error.code == "neighbour_missing")
    state, effects = effectsOf(state, { t = "choose", n = index(state, "retry") })
    assert(state.step == "neighbour" and effects[1].op == "scan")
    state = effectsOf(state, { t = "io", op = "scan", ok = true, value = { sides = { front = { id = 17, kind = "computer" } } } })
    assert(state.step == "neighbour")
    state, effects = effectsOf(state, { t = "choose", n = 1 })
    assert(effects[1].call == "enrol-neighbour" and effects[1].neighbour == 17 and effects[1].side == "front")
    state = effectsOf(state, { t = "io", op = "rpc", ok = false, error = { code = "neighbour_unknown", detail = "not paired" } })
    assert(state.step == "error" and state.error.code == "neighbour_unknown")
    state = effectsOf(state, { t = "choose", n = index(state, "help") })
    assert(state.step == "error" and state.draft.help == true, "help left the error")
    state = effectsOf(state, { t = "back" })
    assert(state.step ~= "error", "back stayed on the error")
  end)

  test("disk full and hash mismatch retry the fetch", function()
    local state = freshMiner()
    for _, code in ipairs({ "disk_full", "hash_mismatch" }) do
      local failed, effects = effectsOf(state, { t = "io", op = "apply_bundle", ok = false, error = { code = code, detail = code } })
      assert(failed.step == "error" and failed.error.code == code, code)
      local retried
      retried, effects = effectsOf(failed, { t = "retry" })
      assert(retried.step == "fetch" and effects[1].op == "apply_bundle", code .. " retry")
    end
  end)

  test("keyboard screens fit 39 by 13 and digits pick a role", function()
    local state = Core.boot({ kind = "turtle", id = 7 }, Roles.catalog())
    state = effectsOf(state, { t = "io", op = "scan", ok = true, value = { kind = "turtle", id = 7, sides = {} } })
    local screens = { state }
    local role = effectsOf(state, { t = "choose", n = index(state, "fresh") })
    screens[#screens + 1] = role
    local entered = effectsOf(state, { t = "choose", n = index(state, "code") })
    screens[#screens + 1] = entered
    local pocket = Core.boot({ kind = "pocket", id = 3 }, Roles.catalog())
    pocket = effectsOf(pocket, { t = "io", op = "scan", ok = true, value = { kind = "pocket", id = 3, sides = {} } })
    pocket = effectsOf(pocket, { t = "choose", n = index(pocket, "fresh") })
    equal(#Core.options(pocket), 1, "pocket roles")
    equal(Core.options(pocket)[1].id, "panel")
    local computer = Core.boot({ kind = "computer", id = 4 }, Roles.catalog())
    computer = effectsOf(computer, { t = "io", op = "scan", ok = true, value = { kind = "computer", id = 4, sides = {} } })
    computer = effectsOf(computer, { t = "choose", n = index(computer, "fresh") })
    local ids = {}
    for _, opt in ipairs(Core.options(computer)) do ids[opt.id] = true end
    assert(ids.hub and ids.server and ids.sorter and not ids.miner and not ids.panel, "computer roles")
    assert(not ids.gps and not ids.locate, "no gps role was added")
    screens[#screens + 1] = computer
    screens[#screens + 1] = role
    local failed = effectsOf(entered, { t = "io", op = "rpc", ok = false, error = { code = "code_expired", detail = "The code timed out." } })
    failed = effectsOf(failed, { t = "choose", n = index(failed, "help") })
    screens[#screens + 1] = failed
    local ui = Keys.new()
    for _, screen in ipairs(screens) do
      local view = Keys.render(screen, ui)
      assert(#view.lines <= 13, screen.step .. " has " .. #view.lines .. " lines")
      for _, line in ipairs(view.lines) do
        assert(#line <= 39, screen.step .. " line is " .. #line .. " [" .. line .. "]")
      end
    end
    ui = Keys.new()
    assert(Keys.event(ui, role, "down") == nil)
    local picked = Keys.event(ui, role, "enter")
    assert(picked.t == "choose" and picked.n == 2, "enter uses the cursor")
    picked = Keys.event(ui, role, nil, "1")
    assert(picked.t == "choose" and picked.n == 1)
    ui = Keys.new()
    Keys.event(ui, entered, nil, "A")
    Keys.event(ui, entered, nil, "B")
    local text = Keys.event(ui, entered, "backspace")
    assert(text == nil and ui.buffer == "A", "backspace edits the code")
    text = Keys.event(Keys.new(), entered, "backspace")
    assert(text.t == "back")
  end)

  test("copy codes expire, replay, and burn, and a neighbour gives the pose", function()
    local function rng() return 3 end
    local store = Enrol.empty()
    local issued = assert(Enrol.issue(store, 1000, 4, { role = "miner", frame = "abs", home = false }, rng))
    equal(#issued.code, 16)
    equal(issued.untilAt, 1000 + 120000)
    local planned = assert(Enrol.issue(store, 1000, 4, { role = "miner", planBot = "p:4:20" }, rng))
    equal(planned.untilAt - planned.issuedAt, 900000)
    local id, code = Enrol.parse(issued.id .. " " .. issued.code)
    equal(id, issued.id)
    equal(code, issued.code)
    local hello = Enrol.hello(store, issued.untilAt, 31, { codeId = issued.id, nNew = "0123456789abcdef" }, 4, rng)
    assert(hello.ok, hello.error)
    local claim = {
      id = 31, server = 4, codeId = issued.id, nNew = "0123456789abcdef",
      nServer = hello.nServer, newPub = "", serverPub = "",
    }
    local proof = Enrol.proof(issued.code, claim)
    local done = Enrol.claim(store, 2000, 31, {
      codeId = issued.id, nNew = claim.nNew, nServer = claim.nServer, proof = proof,
    }, 4)
    assert(done.ok and done.role == "miner", done.error)
    assert(store.paired["31"].key == Enrol.pairingKey(issued.code, claim), "pairing key")
    assert(store.codes[issued.id].code == nil, "used code stayed on disk")
    local replay = Enrol.claim(store, 2000, 31, {
      codeId = issued.id, nNew = claim.nNew, nServer = claim.nServer, proof = proof,
    }, 4)
    equal(replay.error, "code_replayed")
    local expired = Enrol.claim(store, planned.untilAt + 1, 31, { codeId = planned.id, proof = "00" }, 4)
    equal(expired.error, "code_expired")
    equal(store.codes[planned.id].attempts, 0)
    local burnStore = Enrol.empty()
    local burn = assert(Enrol.issue(burnStore, 1000, 4, { role = "store" }, rng))
    local opened = Enrol.hello(burnStore, 1000, 8, { codeId = burn.id, nNew = "abcdef0123456789" }, 4, rng)
    assert(opened.ok)
    for n = 1, 4 do
      local bad = Enrol.claim(burnStore, 1000, 8, {
        codeId = burn.id, nNew = "abcdef0123456789", nServer = opened.nServer, proof = "00",
      }, 4)
      equal(bad.error, "code_rejected")
      equal(bad.attempts, n)
    end
    local last = Enrol.claim(burnStore, 1000, 8, {
      codeId = burn.id, nNew = "abcdef0123456789", nServer = opened.nServer, proof = "00",
    }, 4)
    equal(last.error, "code_burned")
    equal(Enrol.claim(burnStore, 1000, 8, { codeId = burn.id, proof = "00" }, 4).error, "code_burned")
    equal(Enrol.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    equal(Enrol.hmac(string.rep(string.char(11), 20), "Hi There"),
      "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    local pose = { dim = "minecraft:overworld", x = 10, y = 64, z = 20, h = 0, frame = "abs", yAbs = true }
    local front = Enrol.beside(pose, "front")
    equal({ front.x, front.y, front.z, front.h }, { 10, 64, 19, 2 })
    local right = Enrol.beside(pose, "right")
    equal({ right.x, right.z, right.h }, { 11, 20, 3 })
    local missing = Enrol.neighbour(store, 1000, 31, { neighbour = 1, side = "front" }, { ["1"] = "test-secret-123456" })
    equal(missing.error, "neighbour_missing")
    equal(Enrol.neighbour(store, 1000, 31, { neighbour = 9, side = "front" }, { ["1"] = "test-secret-123456" }).error,
      "neighbour_unknown")
    assert(Enrol.confirm(store, 1000, 1, { newId = 31, side = "front", pose = pose }).ok)
    local placed = Enrol.neighbour(store, 1000, 31, { neighbour = 1, side = "front" }, { ["1"] = "test-secret-123456" })
    assert(placed.ok, placed.error)
    equal({ placed.pos.x, placed.pos.y, placed.pos.z, placed.pos.h }, { 10, 64, 19, 2 })
    equal(placed.pos.src, "neighbour")
  end)

  test("enrol stays off until ssot.cfg says so, then a claim is single use", function()
    local loader = loadfile("tests/mocks.lua")
    if not loader then return end
    local mocks = loader()
    local env = mocks.new(false).env
    env.dofile = function(path) return assert(loadfile(path, "t", env))() end
    local S = env.dofile("ssot.lua")
    local function handle(cfg, id, op, fields, secret)
      local api = S.new({}, cfg, function() return 5000 end, "boot", function() return true end)
      local message = {
        v = 1, type = "ssot", expect = "ssot_reply", op = op, boot = "install",
        rid = "r-" .. op .. "-" .. id, counter = 1, secret = secret or "",
      }
      for key, value in pairs(fields or {}) do message[key] = value end
      return api.handle(id, message)
    end
    local off = { controllers = { ["1"] = "test-secret-123456" } }
    local denied = handle(off, 1, "enrol-issue", { role = "miner" }, "test-secret-123456")
    equal(denied.error, "enrol off")
    assert(handle(off, 31, "enrol-hello", { codeId = "c:1:1", nNew = "0123456789abcdef" }) == nil,
      "guest enrol answered while off")
    local on = { controllers = { ["1"] = "test-secret-123456" }, enrol = true }
    local api = S.new({}, on, function() return 5000 end, "boot", function() return true end)
    local function send(id, op, fields, secret)
      local message = {
        v = 1, type = "ssot", expect = "ssot_reply", op = op, boot = "install-" .. id,
        rid = op .. ":" .. id .. ":" .. math.random(1000, 9999), counter = 1, secret = secret or "",
      }
      for key, value in pairs(fields or {}) do message[key] = value end
      return api.handle(id, message)
    end
    local issued = send(1, "enrol-issue", { role = "panel", frame = "abs" }, "test-secret-123456")
    assert(issued and issued.ok and issued.code and #issued.code == 16, issued and issued.error)
    local hello = send(31, "enrol-hello", { codeId = issued.id, nNew = "0123456789abcdef" })
    assert(hello and hello.ok, hello and hello.error)
    local claim = {
      id = 31, server = hello.server, codeId = issued.id, nNew = "0123456789abcdef",
      nServer = hello.nServer, newPub = "", serverPub = "",
    }
    local proof = Enrol.proof(issued.code, claim)
    local done = send(31, "enrol-claim", {
      codeId = issued.id, nNew = claim.nNew, nServer = claim.nServer, proof = proof,
    })
    assert(done and done.ok and done.role == "panel", done and done.error)
    local replay = send(31, "enrol-claim", {
      codeId = issued.id, nNew = claim.nNew, nServer = claim.nServer, proof = proof,
    })
    equal(replay.error, "code_replayed")
    assert(api.state().enrol == nil, "pairing record entered ssot.state")
  end)
end
