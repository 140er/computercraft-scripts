local selectedRole = ({ ... })[1]
local result = { ok = false, roles = {}, unavailable = {}, transport = { requests = 0, bytes = 0 }, faults = {} }
local resultPath = "data/ar-install-result.json"
local recoveryPath = "data/ar-install-recovery.state"
local function read(path)
  local h = assert(fs.open(path, "r"), "Missing " .. path)
  local text = h.readAll()
  h.close()
  return text
end
local function write(path, text)
  local dir = fs.getDir(path)
  if dir ~= "" then fs.makeDir(dir) end
  local h = assert(fs.open(path, "w"))
  h.write(text)
  h.close()
end
local function save() write(resultPath, textutils.serializeJSON(result)) end
local function inventory()
  local files = {}
  local function walk(path)
    for _, name in ipairs(fs.list(path)) do
      local file = fs.combine(path, name)
      if fs.getDrive(file) == "hdd" then
        if fs.isDir(file) then walk(file) else files[#files + 1] = file end
      end
    end
  end
  walk("")
  table.sort(files)
  return files
end
local function fingerprint(text)
  local hash = 5381
  for i = 1, #text do hash = (hash * 33 + text:byte(i)) % 4294967296 end
  return #text .. ":" .. string.format("%08x", hash)
end
local function finish(spec)
  result.phase = "complete"
  if not spec then
    result.ok = #result.unavailable == 0
    if not result.ok then result.error = "A selected role was reported unavailable." end
    return
  end
  local wanted, seen = {}, {}
  for role, entry in pairs(spec.roles) do
    if entry.unavailable then wanted[role] = entry.unavailable end
  end
  result.ok = true
  for _, row in ipairs(result.unavailable) do
    if seen[row.role] or wanted[row.role] ~= row.reason then result.ok = false end
    seen[row.role] = true
  end
  for role in pairs(wanted) do
    if not seen[role] then result.ok = false end
  end
  if not result.ok then result.error = "Unavailable role set did not match the manifest." end
end
local function recoverAfterReboot()
  assert(os.getComputerID() == 4, "Recovery requires disposable computer 4")
  http, _G.http = nil, nil
  result = textutils.unserializeJSON(read(resultPath))
  local saved = assert(textutils.unserialize(read(recoveryPath)))
  assert(fs.exists(".fleet-update-journal") and fs.exists("miner.lua.fleet-backup"),
    "Reboot did not leave the interrupted transaction")
  assert(read("miner.lua") ~= read("miner.lua.fleet-backup"), "No file was promoted before reboot")
  assert(assert(loadfile("update.lua", "t", _ENV))("--repair"), "Restart recovery failed")
  local expected = {}
  for _, file in ipairs(saved.files) do expected[file] = true end
  for _, file in ipairs(inventory()) do assert(expected[file], "Recovery left unexpected file: " .. file) end
  for file, hash in pairs(saved.contents) do assert(fingerprint(read(file)) == hash, "Recovery changed " .. file) end
  result.faults.powerLoss = { ok = true, rebooted = true, recovered = inventory() }
  write("startup.lua", saved.startup)
  fs.delete(recoveryPath)
  local updater = assert(loadfile("update.lua", "t", _ENV))("--module")
  assert(updater.apply("ar"))
  result.final = inventory()
  finish(updater.loadManifest(read("bundle-manifest.lua")))
end
local function run()
  if selectedRole then
    assert(selectedRole == "miner" or selectedRole == "store" or selectedRole == "vworld" or selectedRole == "pro",
      "Expected miner, store, vworld or pro")
    if selectedRole == "miner" or selectedRole == "store" then
      assert(turtle, "Miner and store evidence requires a real turtle")
    end
  else assert(os.getComputerID() == 4, "All-role probe requires disposable computer 4") end
  result.computer, result.turtle, result.capacity = os.getComputerID(), turtle ~= nil, fs.getCapacity("/")
  http, _G.http = nil, nil
  local modem = assert(peripheral.find("modem", function(_, m) return m.isWireless() end), "Wireless modem missing")
  rednet.open(peripheral.getName(modem))
  local server = rednet.lookup("fleetserver", "server")
  assert(server == 0, "Expected disposable cache server 0")
  result.server = server
  local nativeSend, nativeReceive = rednet.send, rednet.receive
  rednet.send = function(peer, message, protocol)
    if protocol == "fleetserver" and type(message) == "table" and message.type == "get" then
      assert(peer == server, "File request went to another server")
      result.transport.requests = result.transport.requests + 1
    end
    return nativeSend(peer, message, protocol)
  end
  rednet.receive = function(...)
    local peer, message, protocol = nativeReceive(...)
    if peer == server and type(message) == "table" and message.type == "file" then
      result.transport.bytes = result.transport.bytes + #(message.code or "")
    end
    return peer, message, protocol
  end
  local updater = assert(loadfile("update.lua", "t", _ENV))("--module")
  local manifest = updater.loadManifest(read("bundle-manifest.lua"))
  local installer = read("install.lua")
  local oldUpdater = read("data/update-v1.lua")
  if not selectedRole then
    write("data/ar-install-probe.lua", read(shell.getRunningProgram()))
  end
  result.expectedVersion, result.signature = manifest.version, manifest.signature
  local roles = {}
  if selectedRole then
    assert(not manifest.roles[selectedRole].unavailable, manifest.roles[selectedRole].unavailable)
    roles[1] = selectedRole
  else for role in pairs(manifest.roles) do roles[#roles + 1] = role end table.sort(roles) end
  local retained = {
    ["data/install-proof.bin"] = "retained data",
    ["cold-storage/install-proof.bin"] = "retained cold chunk",
    ["journals/install-proof.bin"] = "retained movement journal",
    ["keys/install-proof.key"] = "retained test key",
    ["buddy.memory"] = "retained routes and notes",
    ["room.recipes"] = "retained learned recipes",
    ["board.hist"] = "retained board history",
    ["board.last"] = "retained last arrivals",
  }
  for file, content in pairs(retained) do write(file, content) end
  local function dataPath(file)
    if file == resultPath then return true end
    for _, root in ipairs(manifest.preserve.paths) do
      if file == root or file:sub(1, #root + 1) == root .. "/" then return true end
    end
    local plain, changed = file, true
    while changed do
      local previous = plain
      for _, suffix in ipairs(manifest.preserve.generations) do
        if plain:sub(-#suffix - 1) == "." .. suffix then plain = plain:sub(1, -#suffix - 2) break end
      end
      changed = plain ~= previous
    end
    for _, root in ipairs(manifest.preserve.paths) do if plain == root then return true end end
    for _, suffix in ipairs(manifest.preserve.extensions) do
      if plain:sub(-#suffix - 1) == "." .. suffix then return true end
    end
    return false
  end
  for _, file in ipairs(inventory()) do if dataPath(file) and file ~= resultPath then retained[file] = read(file) end end
  save()
  local function verify(role)
    local wanted = { ["bundle-manifest.lua"] = true, [".fleet-role"] = true, [resultPath] = true }
    for _, file in ipairs(manifest.roles[role].files) do
      wanted[file] = true
      assert(loadfile(file), "Installed Lua does not compile: " .. file)
    end
    if manifest.roles[role].startup then wanted["startup.lua"] = true end
    for file in pairs(retained) do wanted[file] = true end
    local actual, seen = inventory(), {}
    for _, file in ipairs(actual) do assert(wanted[file], "Unexpected installed file: " .. file) seen[file] = true end
    for file in pairs(wanted) do assert(seen[file], "Missing installed file: " .. file) end
    for file, content in pairs(retained) do assert(read(file) == content, "Retained data changed: " .. file) end
    assert(read(".fleet-role") == role .. "\n", "Selected role did not survive")
    assert(updater.loadManifest(read("bundle-manifest.lua")).version == manifest.version, "Installed another release")
    return actual
  end
  local migrationRole = selectedRole or "roomclient"
  write("update.lua", oldUpdater)
  if not selectedRole then write("startup.lua", 'shell.run("roomsorter", "board")\n') end
  assert(assert(load(installer, "=install.lua", "t", _ENV))(migrationRole, "quick"),
    "Current installer could not bootstrap v1 through the native cache")
  result.upgrade = { installer = verify(migrationRole) }
  if not selectedRole then
    assert(read("startup.lua") == 'shell.run("roomsorter", "board")\n', "Migration changed board startup")
    write("update.lua", oldUpdater)
    fs.delete(".fleet-role")
    result.upgrade.cliBefore = inventory()
    assert(assert(load(oldUpdater, "=update-v1", "t", _ENV))("noreboot"), "v1 CLI could not upgrade itself")
    assert(read("update.lua") ~= oldUpdater, "v1 CLI left its old updater installed")
    assert(not fs.exists(".fleet-role"), "Legacy CLI unexpectedly wrote role metadata")
    assert(assert(loadfile("update.lua", "t", _ENV))("noreboot"))
    result.upgrade.cli = verify("roomclient")
    assert(read("startup.lua") == 'shell.run("roomsorter", "board")\n', "CLI migration changed board startup")
  end
  for _, role in ipairs(roles) do
    if manifest.roles[role].unavailable then
      local before = inventory()
      local accepted, why = updater.apply(role)
      assert(not accepted and why:find(manifest.roles[role].unavailable, 1, true))
      assert(textutils.serialize(before) == textutils.serialize(inventory()), "Unavailable role changed files")
      result.unavailable[#result.unavailable + 1] = { role = role, reason = manifest.roles[role].unavailable }
    else
    write("obsolete.lua", "return 'obsolete'\n")
    write("obsolete/nested.txt", "obsolete nested file")
    local row = { role = role, before = inventory() }
    result.roles[#result.roles + 1] = row
    assert(assert(load(installer, "=install.lua", "t", _ENV))(role, "quick"), "Installer failed for " .. role)
    row.after = verify(role)
    row.free = fs.getFreeSpace("/")
    write("obsolete.lua", "return 'obsolete after install'\n")
    assert(updater.apply({}))
    row.afterUpdate = verify(role)
    local ok, err, changed = updater.apply({})
    assert(ok and changed == 0, err or "No-op update changed disk")
    row.ok = true
    save()
    sleep(0)
    end
  end
  if selectedRole then
    local configFile = selectedRole == "store" and "warehouse.cfg" or selectedRole == "miner" and "miner.cfg" or "views.cfg"
    local cfg = textutils.unserialize(read(configFile))
    assert(type(cfg) == "table", "Production role configuration missing")
    if selectedRole == "store" then assert(cfg.enabled == true, "Store must be enabled in this disposable test") end
    if selectedRole == "pro" or selectedRole == "vworld" then
      assert(cfg.enabled == true and cfg.server and cfg.secret, "Views must be enabled and paired in this disposable test")
    end
    local startup = { command = read("startup.lua"), running = false }
    result.startup = startup
    parallel.waitForAny(function()
      local ok = shell.run("startup.lua")
      error("Production startup exited: " .. tostring(ok))
    end, function()
      sleep(5)
      startup.running = true
    end)
    assert(startup.running, "Production startup did not run")
    startup.after = inventory()
  else
    assert(updater.apply("ar"))
    local oldHub = read("hub.lua")
    local observedReceive = rednet.receive
    rednet.receive = function(...)
      local peer, packet, protocol = observedReceive(...)
      if peer == server and type(packet) == "table" and packet.type == "file" and packet.file == "hub.lua" then
        packet.hash = "injected-bad-checksum"
      end
      return peer, packet, protocol
    end
    local accepted, why = updater.apply("ar")
    rednet.receive = observedReceive
    assert(not accepted and read("hub.lua") == oldHub, "Corrupt cached transfer changed installed code")
    result.faults.cacheChecksum = { ok = true, message = tostring(why) }
    write("obsolete.lua", "rollback sentinel")
    local before, nativeMove = inventory(), fs.move
    local injected = false
    fs.move = function(from, to)
      if from == "obsolete.lua" and not injected then injected = true error("Injected stale-file promotion failure") end
      return nativeMove(from, to)
    end
    accepted, why = updater.apply("miner")
    fs.move = nativeMove
    assert(injected and not accepted, "Removal failure did not abort role change")
    assert(read("obsolete.lua") == "rollback sentinel" and read("hub.lua") == oldHub, "Role rollback lost files")
    assert(read(".fleet-role") == "ar\n", "Role rollback changed the selected role")
    assert(textutils.serialize(before) == textutils.serialize(inventory()), "Role rollback changed the file list")
    result.faults.commit = { ok = true, message = tostring(why) }
    assert(updater.apply("ar"))
    verify("ar")
    assert(result.transport.requests > 0 and result.transport.bytes > 0, "No native cached transfer")
    local startup = read("startup.lua")
    write("miner.lua", read("miner.lua") .. "\n-- interrupted-upgrade sentinel\n")
    write("startup.lua", 'shell.run("data/ar-install-probe.lua", "--recover")\n')
    write(recoveryPath, "{}")
    local saved = { files = inventory(), contents = {}, startup = startup }
    for _, file in ipairs(saved.files) do
      if file ~= resultPath and file ~= recoveryPath then saved.contents[file] = fingerprint(read(file)) end
    end
    write(recoveryPath, textutils.serialize(saved))
    result.coverage = "Native role installs, exact inventories, v1 migration, rollback and recovery after a real reboot."
    result.phase = "reboot-after-promotion"
    save()
    local move = fs.move
    fs.move = function(from, to)
      move(from, to)
      if from == "miner.lua.fleet-stage" and to == "miner.lua" then os.reboot() end
    end
    updater.apply("miner")
    error("Interrupted update did not reboot")
  end
  assert(result.transport.requests > 0 and result.transport.bytes > 0, "No native cached transfer")
  finish(selectedRole and nil or manifest)
  result.coverage = selectedRole and "Native role install, update, exact inventory, retained data and production startup."
    or "Native all-role install, update, exact inventory, retained data and rollback. Turtle startup is tested separately."
end
local ok, err = pcall(selectedRole == "--recover" and recoverAfterReboot or run)
if not ok then result.ok, result.error = false, tostring(err) end
save()
