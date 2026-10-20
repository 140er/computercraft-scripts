-- Effect shell for the role installer. The state machine decides. This file
-- scans, downloads a role bundle, writes install.cfg, and reboots.
-- Run: install role | install role <id> | install role <id> quick
--      install role issue <id> | install role confirm <side>
-- Plain install opens this shell. install classic, or settings set install.roles false, keeps the old menu.

local Core = dofile("install-core.lua")
local Keys = dofile("install-keys.lua")
local Roles = dofile("install-roles.lua")

local function drive()
  return {
    exists = function(path) return fs.exists(path) end,
    isDir = function(path) return fs.isDir(path) end,
    list = function(path) return fs.list(path) end,
    open = function(path, mode) return fs.open(path, mode) end,
    delete = function(path)
      if fs.exists(path) and fs.getDrive(path) ~= "hdd" then return end
      fs.delete(path)
    end,
    move = function(from, to) fs.move(from, to) end,
  }
end

local function openModem()
  if not (rednet and peripheral and peripheral.getNames) then return false end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
      rednet.open(name)
      return true
    end
  end
  return false
end

local function httpText(base, name)
  if not http then return nil end
  local res, err = http.get(base .. name .. "?t=" .. os.epoch("utc"))
  local text = res and res.readAll()
  if res then res.close() end
  if not text or text == "" or not load(text, "=" .. name) then return nil, err end
  return text
end

local function fromHost(protocol, hostname, file)
  if not openModem() then return nil end
  local server = rednet.lookup(protocol, hostname)
  if not server then return nil end
  local parts, offset, version, size = {}, 0
  while true do
    local rid = math.random(1, 1073741824)
    rednet.send(server, { type = "get", file = file, offset = offset, rid = rid }, protocol)
    local deadline = os.clock() + 8
    local reply
    repeat
      local id, message = rednet.receive(protocol, math.max(0, deadline - os.clock()))
      if id == server and type(message) == "table" and message.type == "file"
        and message.file == file and message.rid == rid then reply = message end
    until reply or os.clock() >= deadline
    if not reply or reply.error or reply.current then return nil end
    if type(reply.hash) ~= "string" or type(reply.size) ~= "number" or reply.offset ~= offset
      or type(reply.code) ~= "string" or #reply.code == 0 or reply.size <= 0 or reply.size > 2000000 then
      return nil
    end
    version, size = version or reply.hash, size or reply.size
    if reply.hash ~= version or reply.size ~= size then return nil end
    parts[#parts + 1] = reply.code
    offset = offset + #reply.code
    if offset >= size then
      local code = table.concat(parts)
      if offset == size and Roles.hash(code) == version and load(code, "=" .. file) then return code end
      return nil
    end
  end
end

local function fetch(base, name)
  local text = httpText(base, name)
  if text then return text end
  text = fromHost("fleetmirror", "mirror", name)
  if text then return text end
  return fromHost("fleetserver", "server", name)
end

local function enrolModule(base)
  if fs.exists("enrol.lua") then return dofile("enrol.lua") end
  local text = fetch(base, "enrol.lua")
  if not text then return nil end
  local fn, err = load(text, "=enrol.lua", "t", _G)
  if not fn then return nil, err end
  return fn()
end

local function rpc(op, fields)
  if not openModem() then return nil, "no modem" end
  local server = rednet.lookup("fleetserver", "server")
  if not server then return nil, "no server" end
  local m = {}
  for key, value in pairs(fields or {}) do m[key] = value end
  m.v, m.type, m.op, m.expect = 1, "ssot", op, "ssot_reply"
  m.rid = "install:" .. os.getComputerID() .. ":" .. os.epoch("utc") .. ":" .. math.random(1, 999999)
  m.boot = "install:" .. os.getComputerID()
  m.counter = 1
  m.secret = fields and fields.secret or ""
  rednet.send(server, m, "fleetserver")
  local deadline = os.clock() + 8
  repeat
    local id, message = rednet.receive("fleetserver", math.max(0, deadline - os.clock()))
    if id == server and type(message) == "table" and message.type == "ssot_reply" and message.rid == m.rid then
      return message
    end
  until os.clock() >= deadline
  return nil, "no reply"
end

local function bundleFor(role, base, hashes)
  local bodies = {}
  for _, name in ipairs(Roles.files(role)) do
    local text, err = fetch(base, name)
    if not text then return nil, name .. " (" .. tostring(err or "download failed") .. ")" end
    bodies[name] = { text = text, expect = hashes and hashes[name] }
  end
  return bodies
end

local function writeCfg(cfg)
  local text = Roles.literal(cfg)
  local h = fs.open("install.cfg.tmp", "w")
  if not h then return false end
  h.write(text)
  h.close()
  if fs.exists("install.cfg") then fs.delete("install.cfg") end
  fs.move("install.cfg.tmp", "install.cfg")
  return true
end

local function writeBoot(role)
  local spec = Roles.get(role)
  if not spec or not spec.boot or fs.exists("startup.lua") then return end
  local h = fs.open("startup.lua", "w")
  if not h then return end
  h.write('shell.run("' .. spec.boot .. '")\n')
  h.close()
end

local function scan()
  local kind = "computer"
  if turtle then kind = "turtle" elseif pocket then kind = "pocket" end
  local sides = {}
  if peripheral and peripheral.getNames then
    for _, side in ipairs(peripheral.getNames()) do
      local found = peripheral.getType(side)
      if found == "computer" or found == "turtle" then
        local ok, id = pcall(peripheral.call, side, "getID")
        if ok and type(id) == "number" then sides[side] = { id = id, kind = found } end
      end
    end
  end
  return {
    kind = kind,
    advanced = term.isColour and term.isColour() or false,
    id = os.getComputerID(),
    label = os.getComputerLabel() or false,
    sides = sides,
  }
end

local function perform(effect, base)
  if effect.op == "scan" then
    return { t = "io", op = "scan", ok = true, value = scan() }
  end
  if effect.op == "clock" then
    return { t = "io", op = "clock", ok = true, value = os.epoch("utc") }
  end
  if effect.op == "apply_bundle" then
    local hashes = effect.filesRef and effect.filesRef.hashes
    local bodies, err = bundleFor(effect.role, base, hashes)
    if not bodies then
      return { t = "io", op = "apply_bundle", ok = false, error = { code = "missing", detail = err } }
    end
    local result, why = Roles.apply(drive(), "", effect.role, bodies, fs.getFreeSpace("/"))
    if not result then
      return { t = "io", op = "apply_bundle", ok = false, error = { code = why, detail = why } }
    end
    return { t = "io", op = "apply_bundle", ok = true, value = { files = result.wrote, manifest = result.manifest } }
  end
  if effect.op == "write_cfg" then
    local ok = writeCfg(effect.cfg)
    if ok then writeBoot(effect.cfg.role) end
    if ok then return { t = "io", op = "write_cfg", ok = true } end
    return { t = "io", op = "write_cfg", ok = false, error = { code = "disk_full", detail = "Could not save install.cfg." } }
  end
  if effect.op == "rpc" and effect.call == "enrol-hello" then
    local Enrol, err = enrolModule(base)
    if not Enrol then
      return { t = "io", op = "rpc", ok = false, error = { code = "missing", detail = tostring(err or "No enrol.lua") } }
    end
    local codeId, code = Enrol.parse(effect.code)
    if not codeId or not code then
      return { t = "io", op = "rpc", ok = false, error = { code = "code_rejected", detail = "Type the id and the 16 character code." } }
    end
    local nNew = string.format("%08x%08x", math.random(0, 2147483647), math.random(0, 2147483647))
    local hello, why = rpc("enrol-hello", { codeId = codeId, nNew = nNew })
    if not hello or not hello.ok then
      return { t = "io", op = "rpc", ok = false, error = { code = hello and hello.error or "code_rejected", detail = why or "" } }
    end
    local claim = {
      id = os.getComputerID(), server = hello.server, codeId = codeId,
      nNew = nNew, nServer = hello.nServer, newPub = "", serverPub = "",
    }
    local claimed, claimWhy = rpc("enrol-claim", {
      codeId = codeId, nNew = nNew, nServer = hello.nServer,
      newPub = "", serverPub = "", proof = Enrol.proof(code, claim),
    })
    if not claimed or not claimed.ok then
      return { t = "io", op = "rpc", ok = false, error = { code = claimed and claimed.error or "code_rejected", detail = claimWhy or "" } }
    end
    claimed.pairingKey = Enrol.pairingKey(code, claim)
    return { t = "io", op = "rpc", ok = true, value = claimed }
  end
  if effect.op == "rpc" and effect.call == "enrol-neighbour" then
    local reply, why = rpc("enrol-neighbour", { neighbour = effect.neighbour, side = effect.side })
    if not reply or not reply.ok then
      return { t = "io", op = "rpc", ok = false, error = { code = reply and reply.error or "neighbour_missing", detail = why or "" } }
    end
    return { t = "io", op = "rpc", ok = true, value = reply }
  end
  return { t = "io", op = effect.op, ok = false, error = { code = "missing", detail = "Unknown effect." } }
end

local function quick(role, base)
  if not Roles.get(role) then print("Unknown role: " .. tostring(role)) return end
  local bodies, err = bundleFor(role, base)
  if not bodies then print("Failed: " .. err) return end
  local result, why = Roles.apply(drive(), "", role, bodies, fs.getFreeSpace("/"))
  if not result then print("Failed: " .. why) return end
  if not writeCfg({ v = 1, role = role, source = "fresh", pos = false, manifest = result.manifest, pairingKey = false }) then
    print("Failed: install.cfg")
    return
  end
  writeBoot(role)
  print("Installed " .. role .. ". Wrote " .. #result.wrote .. ", removed " .. #result.dropped .. ".")
end

local function readInstall()
  if not fs.exists("install.cfg") then return nil end
  local h = fs.open("install.cfg", "r")
  local raw = h and h.readAll()
  if h then h.close() end
  local ok, cfg = pcall(textutils.unserialize, raw or "")
  if ok and type(cfg) == "table" then return cfg end
end

local function confirm(side)
  local names = { front = true, back = true, left = true, right = true, up = true, down = true }
  if not names[side] then
    print("Usage: install role confirm <front|back|left|right|up|down>")
    return
  end
  local cfg = readInstall()
  local pos = cfg and cfg.pos
  if type(pos) ~= "table" or pos.frame ~= "abs" then
    print("install.cfg needs an absolute position first.")
    return
  end
  if side ~= "up" and side ~= "down" and type(pos.h) ~= "number" then
    print("install.cfg has no heading.")
    return
  end
  if not (peripheral and peripheral.call) then print("No peripheral api.") return end
  local seen, nid = pcall(peripheral.call, side, "getID")
  if not seen or type(nid) ~= "number" then print("No computer on " .. side) return end
  local secret = settings and settings.get and settings.get("install.secret")
  if type(secret) ~= "string" or #secret < 16 then
    print("Set install.secret to this computer's controller secret.")
    return
  end
  local reply, why = rpc("enrol-confirm", { newId = nid, side = side, pose = pos, secret = secret })
  if not reply or not reply.ok then
    print("Confirm failed: " .. tostring((reply and reply.error) or why))
    return
  end
  print("Confirmed " .. nid .. " on " .. side .. ". The new machine has 120 seconds.")
end

local function issue(role)
  if not Roles.get(role) then print("Unknown role: " .. tostring(role)) return end
  local Enrol = dofile("enrol.lua")
  local store, err = Enrol.load(fs)
  if not store then print(tostring(err)) return end
  local rec, why = Enrol.issue(store, os.epoch("utc"), os.getComputerID(), {
    role = role, frame = "abs", home = false,
    filesRef = { role = role, manifest = Roles.manifest(role) },
    settingsRef = { revision = 0 },
  }, math.random)
  if not rec then print(tostring(why)) return end
  local saved, saveErr = Enrol.save(fs, store)
  if not saved then print(tostring(saveErr)) return end
  print("Code " .. rec.id)
  print(rec.code)
  print("One use, 120 seconds. Type both on the new machine.")
end

local function paint(state, ui, Touch)
  if Touch then
    local target, monitor = Touch.surface()
    ui.monitor = monitor
    ui.width, ui.height = target.getSize()
    if monitor and term and term.clear then
      if colors and term.setBackgroundColor then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
      end
      term.clear()
    end
    Touch.draw(target, Touch.render(state, ui))
    return
  end
  local view = Keys.render(state, ui)
  if colors and term.setBackgroundColor then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
  end
  term.clear()
  for i, line in ipairs(view.lines) do
    term.setCursorPos(1, i)
    if term.clearLine then term.clearLine() end
    term.write(line)
  end
end

local function chooseId(state, id)
  for i, opt in ipairs(Core.options(state)) do
    if opt.id == id then return i end
  end
end

local function gui(preset, base)
  local state, effects = Core.boot(scan(), Roles.catalog())
  local Touch = nil
  if fs.exists("install-touch.lua") then
    local loaded = dofile("install-touch.lua")
    if loaded.available() then Touch = loaded end
  end
  local ui = Touch and Touch.new() or Keys.new()
  if preset then
    state, effects = Core.transition(state, { t = "io", op = "scan", ok = true, value = scan() })
    state, effects = Core.transition(state, { t = "choose", n = chooseId(state, "fresh") })
    local n = chooseId(state, preset)
    if not n then print(preset .. " does not run on this machine.") return end
    state, effects = Core.transition(state, { t = "choose", n = n })
  end
  while state.step ~= "done" do
    if effects[1] then
      local effect = table.remove(effects, 1)
      if effect.op == "reboot" then
        print("Rebooting...")
        sleep(1)
        os.reboot()
        return
      end
      local event = perform(effect, base)
      local more
      state, more = Core.transition(state, event)
      for _, item in ipairs(more) do effects[#effects + 1] = item end
    else
      paint(state, ui, Touch)
      local ev, a, b, c = os.pullEvent()
      local event
      if Touch then event = Touch.input(ui, state, ev, a, b, c)
      elseif ev == "key" and keys then event = Keys.event(ui, state, keys.getName(a), nil)
      elseif ev == "char" then event = Keys.event(ui, state, nil, a) end
      if event then
        state, effects = Core.transition(state, event)
      end
    end
  end
end

return function(args, base)
  args, base = args or {}, base or "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/alpha/"
  local role, quickMode, issueMode, confirmMode
  for i, arg in ipairs(args) do
    if not (i == 1 and (arg == "role" or arg == "roles")) then
      if arg == "quick" then quickMode = true
      elseif arg == "issue" then issueMode = true
      elseif arg == "confirm" then confirmMode = true
      elseif not role then role = arg end
    end
  end
  if issueMode then
    if not role then print("Usage: install role issue <role>") return end
    return issue(role)
  end
  if confirmMode then
    if not role then print("Usage: install role confirm <side>") return end
    return confirm(role)
  end
  if quickMode then
    if not role then print("Usage: install role <role> quick") return end
    return quick(role, base)
  end
  return gui(role, base)
end
