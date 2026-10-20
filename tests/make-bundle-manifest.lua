local function read(path)
  local f = assert(io.open(path, "rb"), "Missing release file: " .. path)
  local code = f:read("*a")
  f:close()
  return code:gsub("\r\n", "\n")
end
local function checksum(code)
  local h = 5381
  for i = 1, #code do h = (h * 33 + code:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end
local function encode(value, depth)
  if type(value) ~= "table" then
    return type(value) == "string" and string.format("%q", value) or tostring(value)
  end
  depth = depth or 0
  local keys, out = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b)
    if type(a) ~= type(b) then return type(a) < type(b) end
    return a < b
  end)
  for _, key in ipairs(keys) do
    out[#out + 1] = string.rep("  ", depth + 1) .. "[" .. encode(key) .. "]=" .. encode(value[key], depth + 1)
  end
  return "{\n" .. table.concat(out, ",\n") .. "\n" .. string.rep("  ", depth) .. "}"
end
local dependencies = {
  ["miner.lua"] = { "mining.lua", "nav.lua", "ssot-client.lua", "view-source.lua" },
  ["hub.lua"] = { "miner.lua", "fleetview.lua", "ar-hud.lua", "views.lua", "directview.lua" },
  ["server.lua"] = { "fleetview.lua", "ssot.lua", "ar-hud.lua" },
  ["panel.lua"] = { "fleetview.lua" },
  ["factory.lua"] = { "miner.lua" },
  ["store.lua"] = { "warehouse.lua", "nav.lua", "ssot-client.lua" },
  ["roomsorter.lua"] = { "store.lua" },
  ["sorter.lua"] = { "store.lua" },
  ["ar-role.lua"] = { "hub.lua" },
  ["ar-hud.lua"] = { "chat-control.lua" },
  ["chat-control.lua"] = { "ssot.lua" },
  ["fleetview.lua"] = { "ar-hud.lua" },
  ["mining.lua"] = { "atomic.lua", "ssot.lua", "mine-tasks.lua", "warehouse.lua" },
  ["warehouse.lua"] = { "atomic.lua", "ssot.lua" },
  ["nav.lua"] = { "atomic.lua", "ssot.lua" },
  ["ssot-client.lua"] = { "atomic.lua", "ssot.lua" },
  ["ssot.lua"] = { "atomic.lua", "mine-tasks.lua", "warehouse-tasks.lua" },
  ["mine-tasks.lua"] = { "atomic.lua" },
  ["views.lua"] = { "view-source.lua", "view-scene.lua", "ssot-client.lua" },
  ["directview.lua"] = { "view-scene.lua" },
}
local pendingViews = arg and arg[1] == "--pending-pr5"
if pendingViews then
  assert(not read("miner.lua"):find('"view-source.lua"', 1, true)
    and not read("hub.lua"):find('"views.lua"', 1, true), "Merged view code requires the complete PR5 modules")
  dependencies["miner.lua"] = { "mining.lua", "nav.lua", "ssot-client.lua" }
  dependencies["hub.lua"] = { "miner.lua", "fleetview.lua", "ar-hud.lua" }
end
local roles = {}
local function role(id, entry, startup)
  roles[id] = { entry = entry, startup = startup or false }
end
for _, id in ipairs({ "miner", "hub", "relay", "roomsorter", "sorter", "lumber", "farmer",
  "lava", "builder", "buddy", "factory", "gpshost", "server", "panel", "store" }) do
  role(id, id .. ".lua", { id })
end
role("roomclient", "roomsorter.lua", { "roomsorter", "client" })
role("smartmine", "smartmine.lua")
role("ar", "ar-role.lua", { "ar-role" })
role("vworld", "hub.lua", { "hub", "map" })
role("pro", "hub.lua", { "hub", "pro" })
for _, mode in ipairs({ "pro", "warehouse", "map" }) do
  role("view-" .. mode, "hub.lua", { "hub", mode })
end
if pendingViews then
  for _, id in ipairs({ "vworld", "pro", "view-pro", "view-warehouse", "view-map" }) do
    roles[id].unavailable = "PR5 views are not integrated; this role cannot be installed yet."
  end
end

local files = {}
for _, spec in pairs(roles) do
  if not spec.unavailable then
  local selected = {}
  local function include(file)
    if selected[file] then return end
    selected[file] = true
    files[file] = checksum(read(file))
    for _, dependency in ipairs(dependencies[file] or {}) do include(dependency) end
  end
  include(spec.entry)
  include("install.lua")
  include("update.lua")
  spec.files = {}
  for file in pairs(selected) do spec.files[#spec.files + 1] = file end
  table.sort(spec.files)
  end
end
for _, file in ipairs({ "role-adapter.lua", "store-role.lua", "view-role.lua" }) do
  files[file] = checksum(read(file))
end
local manifest = {
  schema = 1,
  roleSchema = 1,
  checksum = "djb2",
  signature = { algorithm = "Ed25519", file = "bundle-manifest.sig", status = "pending-h1h2" },
  files = files,
  dependencies = dependencies,
  roles = roles,
  pending = pendingViews and { "ssot-pr5" } or {},
  preserve = {
    paths = { ".settings", "hub.release", "hub.3d", "buddy.memory", "room.recipes", "board.hist", "board.last",
      "config", "data", "state", "journals", "keys", "cold",
      "cold-store", "cold-storage", "ssot-chunks", "ssot-cold", "peer-storage" },
    extensions = { "cfg", "state", "journal", "wal", "log", "key", "counter", "map", "idx", "pos", "stats", "job", "ar-ids" },
    generations = { "bak", "tmp", "new", "old" },
    excludedPaths = { "server-code" },
    configuredPaths = { ["miner.cfg"] = { { "ssot", "counterFile" }, { "warehouse", "path" } } },
  },
}
manifest.version = checksum(encode(manifest))
-- H1+H2 will sign these exact bytes with a detached Ed25519 signature.
local output = "return " .. encode(manifest) .. "\n"
local f = assert(io.open("bundle-manifest.lua", "wb"))
f:write(output)
f:close()
print("Bundle manifest " .. manifest.version .. (pendingViews and "; PR5 view roles unavailable" or ""))
