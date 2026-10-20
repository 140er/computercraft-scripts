-- update.lua - fetches this computer's scripts from the fleet server or GitHub
--
--   update                 update every script from this repo that is on this computer,
--                          then reboot if anything changed
--   update <file> ...      update (or fetch) just these files, e.g. update lumber.lua
--   update ... noreboot    don't reboot afterwards
--
-- Every script also has its own "update" command (e.g. "lumber update"), and the
-- pocket panel's Update all button tells every bot it can reach to run this.
-- Needs a fleet server in modem range, or http enabled in the ComputerCraft config.

local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/"

-- Everything in the repo that runs on a computer or turtle
local KNOWN = { "miner.lua", "hub.lua", "relay.lua", "smartmine.lua", "sorter.lua", "roomsorter.lua",
  "lumber.lua", "farmer.lua", "lava.lua", "builder.lua", "buddy.lua", "panel.lua", "factory.lua", "gpshost.lua",
  "server.lua", "install.lua", "update.lua", "fleetview.lua", "atomic.lua", "ssot.lua", "ssot-client.lua", "nav.lua", "mine-tasks.lua", "mining.lua",
  "ar-hud.lua", "chat-control.lua", "role-adapter.lua", "ar-role.lua", "store-role.lua", "view-role.lua", "bundle-manifest.lua",
  "store.lua", "warehouse.lua", "warehouse-tasks.lua" }
-- The hub hands miner.lua out to the mining turtles, so it keeps a copy too.
-- fleetview.lua draws the 3D view and the AR goggles for the hub, server and panel.
local ALSO = { ["hub.lua"] = { "miner.lua", "fleetview.lua", "atomic.lua", "ssot.lua", "ssot-client.lua", "nav.lua", "mine-tasks.lua", "mining.lua" },
  ["miner.lua"] = { "atomic.lua", "ssot.lua", "ssot-client.lua", "nav.lua", "mine-tasks.lua", "mining.lua" }, ["factory.lua"] = { "miner.lua" },
  ["server.lua"] = { "fleetview.lua", "atomic.lua", "ssot.lua", "ssot-client.lua", "nav.lua", "mine-tasks.lua", "mining.lua" }, ["panel.lua"] = { "fleetview.lua" },
  ["fleetview.lua"] = { "ar-hud.lua" }, ["ar-role.lua"] = { "hub.lua", "chat-control.lua", "role-adapter.lua" },
  ["store-role.lua"] = { "role-adapter.lua" }, ["view-role.lua"] = { "role-adapter.lua" } }
for _, owner in ipairs({ "hub.lua", "server.lua" }) do
  ALSO[owner][#ALSO[owner] + 1] = "chat-control.lua"
  ALSO[owner][#ALSO[owner] + 1] = "role-adapter.lua"
end
ALSO["store.lua"] = { "atomic.lua", "ssot.lua", "ssot-client.lua", "nav.lua", "mine-tasks.lua", "warehouse-tasks.lua", "warehouse.lua" }
ALSO["roomsorter.lua"], ALSO["sorter.lua"] = { "store.lua" }, { "store.lua" }
ALSO["ssot.lua"] = { "warehouse-tasks.lua" }
ALSO["mining.lua"] = { "warehouse.lua" }

local args = { ... }
local reboot = true
local files, seen = {}, {}
local function add(f)
  if not f:find("%.lua$") then f = f .. ".lua" end
  if not seen[f] then seen[f] = true files[#files + 1] = f end
end
for _, a in ipairs(args) do
  if a == "noreboot" then reboot = false elseif a ~= "--module" and a ~= "--repair" then add(a) end
end
local cursor = 1
while cursor <= #files do
  for _, f in ipairs(ALSO[files[cursor]] or {}) do add(f) end
  cursor = cursor + 1
end
if #files == 0 then
  for _, f in ipairs(KNOWN) do
    if fs.exists(f) then
      add(f)
      for _, g in ipairs(ALSO[f] or {}) do add(g) end
    end
  end
end
-- update.lua itself last, so a broken download never stops the rest
table.sort(files, function(a, b) return a ~= "update.lua" and (b == "update.lua" or a < b) end)

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
local function remove(path) if fs.exists(path) then fs.delete(path) end end
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
  assert(journal.version == 1 and type(journal.files) == "table", "invalid update journal")
  local committed = read(COMMITTED) == hashOf(raw)
  for _, entry in ipairs(journal.files) do
    local f = entry.file
    assert(type(f) == "string" and f:match("^[%w%-]+%.lua$"), "invalid journal path")
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
local function apply(requested)
  local list, selected = {}, {}
  local function include(f)
    assert(type(f) == "string" and f:match("^[%w%-]+%.lua$"), "invalid script name")
    if selected[f] then return end
    selected[f] = true
    list[#list + 1] = f
    for _, dep in ipairs(ALSO[f] or {}) do include(dep) end
  end
  for _, f in ipairs(requested) do include(f) end
  local staged, journal = {}, { version = 1, files = {} }
  local ok, err = pcall(function()
    recover()
    local manifestCode, why = fetch("bundle-manifest.lua")
    assert(manifestCode, "release manifest unavailable: " .. tostring(why))
    local manifest = assert(load(manifestCode, "=bundle-manifest", "t", {}))()
    assert(type(manifest) == "table" and manifest.schema == 1 and type(manifest.version) == "string"
      and type(manifest.files) == "table", "invalid release manifest")
    journal.release = manifest.version
    include("bundle-manifest.lua")
    for _, f in ipairs(list) do
      local code, why
      if f == "bundle-manifest.lua" then code = manifestCode else code, why = fetch(f) end
      assert(code, f .. ": " .. tostring(why))
      assert(f == "bundle-manifest.lua" or manifest.files[f] == hashOf(code:gsub("\r\n", "\n")), "release hash mismatch: " .. f)
      if code ~= read(f) then
        assert(not fs.exists(f .. ".fleet-backup"), "unclaimed backup for " .. f)
        staged[#staged + 1] = f
        writeFile(f .. ".fleet-stage", code)
        journal.files[#journal.files + 1] = { file = f, existed = fs.exists(f), hash = hashOf(code) }
      end
    end
    remove(COMMITTED)
    local journalText = textutils.serialize(journal)
    writeFile(JOURNAL .. ".new", journalText)
    fs.move(JOURNAL .. ".new", JOURNAL)
    for _, entry in ipairs(journal.files) do
      local f = entry.file
      if entry.existed then fs.move(f, f .. ".fleet-backup") end
      fs.move(f .. ".fleet-stage", f)
      assert(hashOf(assert(read(f))) == entry.hash, "installed hash mismatch")
    end
    writeFile(COMMITTED, hashOf(journalText))
    recover()
  end)
  if not ok then
    local restored, why = pcall(recover)
    for _, f in ipairs(staged) do remove(f .. ".fleet-stage") end
    return false, tostring(err) .. (restored and "" or "; recovery required: " .. tostring(why)), 0
  end
  for _, f in ipairs(staged) do remove(f .. ".fleet-backup") end
  return true, nil, #staged
end
if args[1] == "--module" then return { apply = apply, fetch = fetch, known = KNOWN, dependencies = ALSO } end
if args[1] == "--repair" then
  local ok, err = pcall(recover)
  print(ok and "Bundle recovery complete." or ("Recovery failed. " .. tostring(err)))
  return ok
end
local ok, err, changed = apply(files)
print(ok and (changed .. " updated.") or ("Update failed. " .. tostring(err)))
if ok and changed > 0 and reboot then
  print("Rebooting...")
  sleep(1)
  os.reboot()
end
return ok and changed > 0
