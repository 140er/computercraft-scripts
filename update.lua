-- update refreshes this computer's installed role. Add noreboot to keep it running.

local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/"

local args = { ... }
local reboot, requested = true, {}
for _, a in ipairs(args) do
  if a == "noreboot" then reboot = false
  elseif a ~= "--module" and a ~= "--repair" then requested[#requested + 1] = a end
end

local function read(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  local s = h.readAll()
  h.close()
  return s
end

local function hashOf(text)
  local h = 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

local PROTOCOL = "fleetserver"
local server -- looked up the first time GitHub can't be reached

local function fromServer(f)
  if server == nil then
    server = false
    for _, name in ipairs(peripheral.getNames()) do
      if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
        rednet.open(name)
        server = rednet.lookup(PROTOCOL, "server") or false
        break
      end
    end
  end
  if not server then return nil end
  local old = read(f)
  local hash = old and hashOf(old)
  local parts, offset, version, size = {}, 0
  while true do
    local rid = math.random(1, 1073741824)
    rednet.send(server, { type = "get", file = f, hash = hash, offset = offset, rid = rid }, PROTOCOL)
    local deadline = os.clock() + 8
    local reply
    repeat
      local id, m = rednet.receive(PROTOCOL, math.max(0, deadline - os.clock()))
      if id == server and type(m) == "table" and m.type == "file" and m.file == f and m.rid == rid then reply = m end
    until reply or os.clock() >= deadline
    if not reply or reply.error then return nil end
    if reply.current then return reply.hash == hash and old or nil end
    if type(reply.hash) ~= "string" or type(reply.size) ~= "number" or reply.size <= 0
      or reply.size > 2000000 or reply.offset ~= offset or type(reply.code) ~= "string" or #reply.code == 0 then return nil end
    version, size = version or reply.hash, size or reply.size
    if reply.hash ~= version or reply.size ~= size then return nil end
    parts[#parts + 1] = reply.code
    offset = offset + #reply.code
    if offset >= size then
      local code = table.concat(parts)
      return offset == size and hashOf(code) == version and code or nil
    end
  end
end

local function fetch(f)
  local code, err
  if http then
    pcall(function()
      local res
      res, err = http.get(BASE .. f .. "?t=" .. os.epoch("utc"))
      code = res and res.readAll()
      if res then res.close() end
    end)
  end
  if not code or code == "" or not load(code, "=" .. f) then
    local copy = fromServer(f)
    if copy then code = copy end
  end
  if not code or code == "" or not load(code, "=" .. f) then
    return nil, err or "no valid server copy or http download"
  end
  return code
end
local JOURNAL = ".fleet-update-journal"
local COMMITTED = ".fleet-update-committed"
local ROLE = ".fleet-role"
local function remove(path) if fs.exists(path) then fs.delete(path) end end
local function safePath(path)
  if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" or path:find("\\", 1, true) then return false end
  for part in path:gmatch("[^/]+") do if part == "." or part == ".." then return false end end
  return not fs.getDrive or fs.getDrive(path) == "hdd"
end
local function writeFile(path, text)
  local h = assert(fs.open(path, "w"), "cannot open " .. path)
  local ok, err = pcall(h.write, text)
  h.close()
  assert(ok, err)
  assert(read(path) == text, "verification failed for " .. path)
end
local function recover()
  local raw = read(JOURNAL)
  if not raw then return end
  local journal = assert(textutils.unserialize(raw), "invalid update journal")
  assert((journal.version == 1 or journal.version == 2) and type(journal.files) == "table", "invalid update journal")
  local committed = read(COMMITTED) == hashOf(raw)
  for _, entry in ipairs(journal.files) do
    local f = entry.file
    assert(safePath(f), "invalid journal path")
    if committed then
      remove(f .. ".fleet-backup")
    elseif fs.exists(f .. ".fleet-backup") then
      remove(f)
      fs.move(f .. ".fleet-backup", f)
    elseif not entry.existed then
      remove(f)
    end
    remove(f .. ".fleet-stage")
  end
  remove(JOURNAL)
  remove(COMMITTED)
end
local function loadManifest(code)
  local manifest = assert(load(code, "=bundle-manifest", "t", {}))()
  assert(type(manifest) == "table" and manifest.schema == 1 and manifest.roleSchema == 1 and manifest.checksum == "djb2"
    and type(manifest.version) == "string" and type(manifest.files) == "table"
    and type(manifest.roles) == "table" and type(manifest.dependencies) == "table"
    and type(manifest.preserve) == "table", "invalid release manifest")
  return manifest
end
local function startupRole(manifest)
  local startup = read("startup.lua") or read("startup") or ""
  local command, rest = startup:match('shell%.run%s*%(%s*["\']([%w%-]+)["\'](.*)')
  if not command then return nil end
  local mode = rest:match('^%s*,%s*["\']([%w%-]+)["\']')
  if command == "roomsorter" and (mode == "client" or mode == "board") then return "roomclient" end
  if command == "hub" then
    local alias = ({ map = "vworld", pro = "pro", warehouse = "view-warehouse" })[mode]
    if alias then return alias end
  end
  if manifest.roles[command] then return command end
  for role, spec in pairs(manifest.roles) do if spec.entry == command .. ".lua" then return role end end
end
local function chooseRole(manifest, selection)
  if type(selection) == "string" then
    assert(manifest.roles[selection], "unknown role: " .. selection)
    return selection
  end
  selection = selection or {}
  local current = (read(ROLE) or ""):match("^([%w%-]+)%s*$") or startupRole(manifest)
  if current and manifest.roles[current] then
    local selected, subset = {}, true
    for _, file in ipairs(manifest.roles[current].files or {}) do selected[file] = true end
    for _, file in ipairs(selection) do
      if not file:match("%.lua$") then file = file .. ".lua" end
      if not selected[file] then subset = false end
    end
    if subset then return current end
  end
  for _, file in ipairs(selection) do
    local id = file:gsub("%.lua$", "")
    if manifest.roles[id] then return id end
    for role, spec in pairs(manifest.roles) do if spec.entry == file then return role end end
  end
  local found
  for role, spec in pairs(manifest.roles) do
    if spec.entry == role .. ".lua" and fs.exists(spec.entry) then
      assert(not found, "multiple installed programs; select a role with install <role> quick")
      found = role
    end
  end
  return assert(found, "no installed role; run install <role> quick")
end
local function diskFiles()
  local files, dirs = {}, {}
  local function walk(path)
    for _, name in ipairs(fs.list(path == "" and "/" or path)) do
      local child = path == "" and name or path .. "/" .. name
      if safePath(child) and name ~= "rom" and (not fs.isReadOnly or not fs.isReadOnly(child)) then
        if fs.isDir and fs.isDir(child) then
          walk(child)
          dirs[#dirs + 1] = child
        else files[#files + 1] = child end
      end
    end
  end
  walk("")
  table.sort(files)
  return files, dirs
end
local function configuredPaths(manifest)
  local paths = {}
  for file, selectors in pairs(manifest.preserve.configuredPaths or {}) do
    for _, suffix in ipairs({ "", ".tmp", ".bak" }) do
      local raw = read(file .. suffix)
      local ok, cfg = pcall(textutils.unserialize, raw or "")
      if ok and type(cfg) == "table" then
        for _, keys in ipairs(selectors) do
          local value = cfg
          for _, key in ipairs(keys) do value = type(value) == "table" and value[key] or nil end
          if type(value) == "string" then
            value = value:gsub("^/+", "")
            assert(safePath(value), "invalid configured state path")
            paths[#paths + 1] = value
          end
        end
      end
    end
  end
  return paths
end
local function preserved(path, manifest, role, configured)
  local base = path
  local generations = { [path] = true }
  local changed = true
  while changed do
    changed = false
    for _, suffix in ipairs(manifest.preserve.generations or {}) do
      if base:sub(-#suffix - 1) == "." .. suffix then
        base = base:sub(1, -#suffix - 2)
        generations[base], changed = true, true
        break
      end
    end
  end
  for _, root in ipairs(configured) do
    if generations[root] or path:sub(1, #root + 1) == root .. "/" then return true end
  end
  for _, root in ipairs(manifest.preserve.excludedPaths or {}) do
    if path == root or path:sub(1, #root + 1) == root .. "/" then return false end
  end
  for _, roots in ipairs({ manifest.preserve.paths or {}, role.preserve or {} }) do
    for _, root in ipairs(roots) do
      if path == root or path:sub(1, #root + 1) == root .. "/" then return true end
    end
  end
  for _, root in ipairs(manifest.preserve.paths or {}) do if base == root then return true end end
  for _, suffix in ipairs(manifest.preserve.extensions or {}) do
    if base:sub(-#suffix - 1) == "." .. suffix then return true end
  end
  return false
end
local function startupFor(spec)
  if not spec.startup then return nil end
  local words = {}
  for _, word in ipairs(spec.startup) do
    assert(type(word) == "string", "invalid startup command")
    words[#words + 1] = string.format("%q", word)
  end
  assert(#words > 0, "empty startup command")
  return "shell.run(" .. table.concat(words, ", ") .. ")\n"
end
local function apply(selection)
  local staged, journal = {}, { version = 2, files = {} }
  local journalStarted = false
  local ok, err = pcall(function()
    recover()
    local manifestCode, why = fetch("bundle-manifest.lua")
    assert(manifestCode, "release manifest unavailable: " .. tostring(why))
    local manifest = loadManifest(manifestCode)
    local role = chooseRole(manifest, selection)
    local spec = manifest.roles[role]
    assert(not spec.unavailable, spec.unavailable)
    assert(type(spec.files) == "table", "missing role files")
    local configured = configuredPaths(manifest)
    local selected, list = {}, {}
    for _, file in ipairs(spec.files) do
      assert(type(file) == "string" and file:match("^[%w_%-]+%.lua$") and manifest.files[file], "invalid role file")
      assert(not selected[file], "duplicate role file")
      selected[file], list[#list + 1] = true, file
    end
    assert(selected[spec.entry] and selected["install.lua"] and selected["update.lua"], "incomplete role")
    for _, file in ipairs(list) do
      for _, dependency in ipairs(manifest.dependencies[file] or {}) do
        assert(selected[dependency], "missing dependency: " .. dependency)
      end
    end
    local reserved = { JOURNAL, JOURNAL .. ".new", COMMITTED }
    for _, file in ipairs({ "bundle-manifest.lua", ROLE, "startup.lua" }) do reserved[#reserved + 1] = file end
    for _, file in ipairs(list) do reserved[#reserved + 1] = file end
    for _, file in ipairs(reserved) do
      for _, suffix in ipairs({ "", ".fleet-stage", ".fleet-backup" }) do
        assert(not preserved(file .. suffix, manifest, spec, configured),
          "configured data overlaps updater path: " .. file .. suffix)
      end
    end
    table.sort(list)
    local found, dirs = diskFiles()
    local existing = {}
    for _, file in ipairs(found) do
      local protected = preserved(file, manifest, spec, configured)
      assert(protected or not file:match("%.fleet%-backup$"), "unclaimed backup for " .. file)
      if not protected and (file:match("%.fleet%-stage$") or file == JOURNAL .. ".new" or file == COMMITTED) then remove(file)
      else existing[#existing + 1] = file end
    end
    local function stage(file, code)
      selected[file] = true
      if code == read(file) then return end
      assert(not fs.exists(file .. ".fleet-backup"), "unclaimed backup for " .. file)
      staged[#staged + 1] = file
      writeFile(file .. ".fleet-stage", code)
      journal.files[#journal.files + 1] = { file = file, existed = fs.exists(file), hash = hashOf(code) }
    end
    journal.release = manifest.version
    for _, file in ipairs(list) do
      local code, reason = fetch(file)
      assert(code, file .. ": " .. tostring(reason))
      assert(manifest.files[file] == hashOf(code:gsub("\r\n", "\n")), "release hash mismatch: " .. file)
      stage(file, code)
    end
    stage("bundle-manifest.lua", manifestCode)
    local previousRole = read(ROLE)
    local legacyRole = not previousRole and startupRole(manifest)
    local keepStartup = previousRole == role .. "\n"
      or not previousRole and (legacyRole == role or not legacyRole and type(selection) ~= "string")
    stage(ROLE, role .. "\n")
    local startup = startupFor(spec)
    if startup then
      stage("startup.lua", keepStartup and (read("startup.lua") or read("startup")) or startup)
    end
    for _, file in ipairs(existing) do
      if not selected[file] and not preserved(file, manifest, spec, configured) then
        assert(not fs.exists(file .. ".fleet-backup"), "unclaimed backup for " .. file)
        journal.files[#journal.files + 1] = { file = file, existed = true, remove = true }
      end
    end
    if #journal.files == 0 then return end
    remove(COMMITTED)
    local journalText = textutils.serialize(journal)
    journalStarted = true
    writeFile(JOURNAL .. ".new", journalText)
    fs.move(JOURNAL .. ".new", JOURNAL)
    for _, entry in ipairs(journal.files) do
      local f = entry.file
      if entry.existed then fs.move(f, f .. ".fleet-backup") end
      if not entry.remove then
        fs.move(f .. ".fleet-stage", f)
        assert(hashOf(assert(read(f))) == entry.hash, "installed hash mismatch")
      end
    end
    writeFile(COMMITTED, hashOf(journalText))
    recover()
    for _, dir in ipairs(dirs) do
      if fs.exists(dir) and not preserved(dir, manifest, spec, configured) and #fs.list(dir) == 0 then fs.delete(dir) end
    end
  end)
  if not ok then
    local restored, why = pcall(recover)
    for _, f in ipairs(staged) do remove(f .. ".fleet-stage") end
    if journalStarted then remove(JOURNAL .. ".new") end
    return false, tostring(err) .. (restored and "" or "; recovery required: " .. tostring(why)), 0
  end
  for _, f in ipairs(staged) do remove(f .. ".fleet-backup") end
  return true, nil, #journal.files
end
if args[1] == "--module" then return { roleSchema = 1, apply = apply, fetch = fetch, loadManifest = loadManifest } end
if args[1] == "--repair" then
  local ok, err = pcall(recover)
  print(ok and "Bundle recovery complete." or ("Recovery failed. " .. tostring(err)))
  return ok
end
local ok, err, changed = apply(requested)
print(ok and (changed .. " updated.") or ("Update failed. " .. tostring(err)))
if ok and changed > 0 and reboot then
  print("Rebooting...")
  sleep(1)
  os.reboot()
end
return ok and changed > 0
