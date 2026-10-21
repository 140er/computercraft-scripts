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
  ["factory.lua"] = { "miner.lua", "craft.lua" },
  ["store.lua"] = { "warehouse.lua", "nav.lua", "ssot-client.lua" },
  ["roomsorter.lua"] = { "store.lua" },
  ["sorter.lua"] = { "store.lua" },
  ["ar-role.lua"] = { "hub.lua" },
  ["ar-hud.lua"] = { "chat-control.lua" },
  ["chat-control.lua"] = { "ssot.lua" },
  ["fleetview.lua"] = { "ar-hud.lua" },
  ["mining.lua"] = { "atomic.lua", "ssot.lua", "mine-tasks.lua", "warehouse.lua" },
  ["warehouse.lua"] = { "atomic.lua", "ssot.lua" },
  ["nav.lua"] = { "atomic.lua", "ssot.lua", "position.lua" },
  ["ssot-client.lua"] = { "atomic.lua", "ssot.lua" },
  ["ssot.lua"] = { "atomic.lua", "mine-tasks.lua", "warehouse-tasks.lua", "planner-ops.lua", "dead.lua", "wh2-dispatch.lua", "lease.lua", "ssot-hub.lua" },
  ["ssot-hub.lua"] = { "atomic.lua", "s1_t1.lua", "s1_h4c.lua", "s1_i1.lua", "s1_b1.lua" },
  ["lease.lua"] = { "journal.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_h1.lua", "lib/stubs/b1_h5.lua", "lib/stubs/b1_w1.lua" },
  ["journal.lua"] = { "atomic.lua" },
  ["b1-nav.lua"] = { "atomic.lua", "lease.lua", "journal.lua", "lib/stubs/b1_n1.lua", "lib/stubs/b1_h4c.lua" },
  ["planner-ops.lua"] = { "planner-core.lua", "planner-enrol.lua", "planner-settings.lua" },
  ["planner-core.lua"] = { "planner-enrol.lua", "planner-settings.lua" },
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
dependencies["wh2-program.lua"] = { "atomic.lua", "ssot-client.lua", "wh2-client.lua" }
dependencies["wh2-client.lua"] = { "atomic.lua" }
dependencies["wh2-dev.lua"] = { "wh2-fleet.lua" }
for _, file in ipairs({ "hub.lua", "server.lua", "panel.lua", "factory.lua", "store.lua",
  "roomsorter.lua", "sorter.lua", "miner.lua", "lava.lua", "lumber.lua", "relay.lua",
  "smartmine.lua", "buddy.lua", "builder.lua", "farmer.lua", "gpshost.lua" }) do
  local listed = dependencies[file] or {}
  dependencies[file] = listed
  listed[#listed + 1] = "wh2-program.lua"
end
for _, file in ipairs({
  "miner.lua", "store.lua", "factory.lua", "farmer.lua", "lumber.lua", "lava.lua",
  "builder.lua", "buddy.lua", "roomsorter.lua", "panel.lua", "server.lua", "gpshost.lua",
  "planner-panel.lua", "planner-hub.lua",
}) do
  local listed = dependencies[file] or {}
  dependencies[file] = listed
  listed[#listed + 1] = "plug.lua"
end
dependencies["hub.lua"][#dependencies["hub.lua"] + 1] = "wh2-ar.lua"
dependencies["hub.lua"][#dependencies["hub.lua"] + 1] = "wh2-dev.lua"
dependencies["panel.lua"][#dependencies["panel.lua"] + 1] = "wh2-ar.lua"
dependencies["panel.lua"][#dependencies["panel.lua"] + 1] = "wh2-dev.lua"
dependencies["server.lua"][#dependencies["server.lua"] + 1] = "wh2-dev.lua"
dependencies["server.lua"][#dependencies["server.lua"] + 1] = "wh2-locations.lua"
dependencies["storage-peer.lua"] = { "lib/stubs/h4d_dep.lua" }
dependencies["alpha-boot.lua"] = { "ar-planner.lua", "strata.lua", "storage-host.lua", "storage-peer.lua" }
dependencies["storage-host.lua"] = { "storage-ledger.lua", "storage-buffer.lua", "storage-view.lua" }
dependencies["server.lua"][#dependencies["server.lua"] + 1] = "storage-peer.lua"
dependencies["server.lua"][#dependencies["server.lua"] + 1] = "alpha-boot.lua"
dependencies["hub.lua"][#dependencies["hub.lua"] + 1] = "alpha-boot.lua"
dependencies["planner-host.lua"] = { "planner-view.lua", "planner-map.lua" }
dependencies["server.lua"][#dependencies["server.lua"] + 1] = "planner-host.lua"
dependencies["miner.lua"][#dependencies["miner.lua"] + 1] = "wh2-client.lua"
dependencies["miner.lua"][#dependencies["miner.lua"] + 1] = "b1-nav.lua"
dependencies["store.lua"][#dependencies["store.lua"] + 1] = "wh2-client.lua"
dependencies["wh2-board.lua"] = { "wh2-wizard-adapter.lua", "wh2-wizard.lua", "atomic.lua" }
for _, file in ipairs({ "hub.lua", "panel.lua" }) do
  for _, name in ipairs({ "wh2-wizard-host.lua", "wh2-board.lua", "wh2-recipes.lua" }) do
    dependencies[file][#dependencies[file] + 1] = name
  end
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

local graph = dofile("tests/f0-graph.lua")
local function addDep(file, dep)
  if not graph.read(dep) then return end
  local list = dependencies[file]
  if not list then
    dependencies[file] = { dep }
    return
  end
  for _, have in ipairs(list) do
    if have == dep then return end
  end
  list[#list + 1] = dep
end
for _, spec in pairs(roles) do
  if spec.entry and graph.read(spec.entry) then
    for _, file in ipairs(graph.closure(spec.entry)) do
      if graph.read(file) then
        for _, dep in ipairs(graph.direct(file)) do addDep(file, dep) end
      end
    end
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
