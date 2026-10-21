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
  "server.lua", "install.lua", "update.lua", "fleetview.lua" }
-- The hub hands miner.lua out to the mining turtles, so it keeps a copy too.
-- fleetview.lua draws the 3D view and the AR goggles for the hub, server and panel.
local ALSO = { ["hub.lua"] = { "miner.lua", "fleetview.lua" }, ["factory.lua"] = { "miner.lua" },
  ["server.lua"] = { "fleetview.lua" }, ["panel.lua"] = { "fleetview.lua" } }

local args = { ... }
local reboot = true
local files, seen = {}, {}
local function add(f)
  if not f:find("%.lua$") then f = f .. ".lua" end
  if not seen[f] then seen[f] = true files[#files + 1] = f end
end
for _, a in ipairs(args) do
  if a == "noreboot" then reboot = false else add(a) end
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

local changed, failed = 0, 0
for _, f in ipairs(files) do
  write(f .. " ... ")
  -- GitHub first: the server's copy can be up to a few minutes behind main.
  local code, err
  if http then
    -- The query string gets past GitHub's cache of the raw file.
    local res
    res, err = http.get(BASE .. f .. "?t=" .. os.epoch("utc"))
    code = res and res.readAll()
    if res then res.close() end
  end
  if not code or code == "" or not load(code, "=" .. f) then
    local copy = fromServer(f)
    if copy then code = copy end
  end
  if not code or code == "" then
    print("failed: " .. tostring(err or "no server copy or http download"))
    failed = failed + 1
  elseif not load(code, "=" .. f) then
    -- never replace a working script with one that doesn't even compile
    print("failed: download is broken")
    failed = failed + 1
  elseif code == read(f) then
    print("up to date")
  else
    local h = fs.open(f .. ".new", "w")
    h.write(code)
    h.close()
    if fs.exists(f) then fs.delete(f) end
    fs.move(f .. ".new", f)
    print("updated")
    changed = changed + 1
  end
end

print(changed .. " updated, " .. failed .. " failed.")
if changed > 0 and reboot then
  print("Rebooting...")
  sleep(1)
  os.reboot()
end
return changed > 0
