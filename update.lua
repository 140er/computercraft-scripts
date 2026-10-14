-- update.lua - fetches the latest version of this computer's scripts from GitHub
--
--   update                 update every script from this repo that is on this computer,
--                          then reboot if anything changed
--   update <file> ...      update (or fetch) just these files, e.g. update lumber.lua
--   update ... noreboot    don't reboot afterwards
--
-- Every script also has its own "update" command (e.g. "lumber update"), and the
-- pocket panel's Update all button tells every bot it can reach to run this.
-- Needs http enabled in the ComputerCraft config (it is by default).

local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/"

-- Everything in the repo that runs on a computer or turtle
local KNOWN = { "miner.lua", "hub.lua", "relay.lua", "smartmine.lua", "sorter.lua", "roomsorter.lua",
  "lumber.lua", "buddy.lua", "panel.lua", "factory.lua", "install.lua", "update.lua" }
-- The hub hands miner.lua out to the mining turtles, so it keeps a copy too
local ALSO = { ["hub.lua"] = { "miner.lua" }, ["factory.lua"] = { "miner.lua" } }

if not http then
  print("http is disabled in the ComputerCraft config, can't update.")
  return false
end

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

local changed, failed = 0, 0
for _, f in ipairs(files) do
  write(f .. " ... ")
  -- the query string gets past GitHub's cache of the raw file
  local res, err = http.get(BASE .. f .. "?t=" .. os.epoch("utc"))
  local code = res and res.readAll()
  if res then res.close() end
  if not code or code == "" then
    print("failed: " .. tostring(err or "empty file"))
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
