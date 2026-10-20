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
local function exists(path)
  local f = io.open(path, "rb")
  if not f then return false end
  f:close()
  return true
end
local function accept(path)
  if type(path) ~= "string" or path == "" or path:find("%.%.", 1, true) or path:find("^tests/") then return nil end
  if path:sub(-4) ~= ".lua" then
    if exists(path .. ".lua") then path = path .. ".lua" else return nil end
  end
  if not exists(path) then return nil end
  return path
end
local function directSet(code)
  local set = {}
  local function add(path)
    path = accept(path)
    if path then set[path] = true end
  end
  local patterns = {
    "dofile%s*%(%s*[\"']([^\"']+)[\"']",
    "loadfile%s*%(%s*[\"']([^\"']+)[\"']",
    "require%s*%(%s*[\"']([^\"']+)[\"']",
    "pcall%s*%(%s*dofile%s*,%s*[\"']([^\"']+)[\"']",
    "pcall%s*%(%s*require%s*,%s*[\"']([^\"']+)[\"']",
    "attempt%s*%(%s*[\"']([^\"']+)[\"']",
    "openWh2%s*%(%s*[\"']([^\"']+)[\"']",
    "readFile%s*%(%s*[\"']([^\"']+)[\"']",
  }
  for _, pat in ipairs(patterns) do
    for path in code:gmatch(pat) do add(path) end
  end
  for path in code:gmatch("https://[^\"']+/([%w_%-]+%.lua)") do add(path) end
  if code:find("dofile%s*,%s*[%a_]") or code:find("dofile%s*%(%s*[%a_]") then
    for path in code:gmatch("[\"']([^\"']+%.lua)[\"']") do add(path) end
  end
  local i = 1
  while true do
    local startAt, stopAt, name = code:find("shell%.run%s*%(%s*[\"']([%w_%-]+)[\"']", i)
    if not startAt then break end
    local prev = startAt > 1 and code:sub(startAt - 1, startAt - 1) or ""
    if prev ~= "'" and prev ~= '"' then add(name) end
    i = stopAt + 1
  end
  return set
end
local dependencies = {}
local function directList(file)
  if dependencies[file] then return dependencies[file] end
  local code = read(file)
  local set = code and directSet(code) or {}
  set[file] = nil
  local list = {}
  for name in pairs(set) do list[#list + 1] = name end
  table.sort(list)
  dependencies[file] = list
  return list
end
local pendingViews = arg and arg[1] == "--pending-pr5"
if pendingViews then
  assert(not read("miner.lua"):find('"view-source.lua"', 1, true)
    and not read("hub.lua"):find('"views.lua"', 1, true), "Merged view code requires the complete PR5 modules")
  local function drop(file, banned)
    local kept = {}
    for _, name in ipairs(directList(file)) do
      if not banned[name] then kept[#kept + 1] = name end
    end
    dependencies[file] = kept
  end
  drop("miner.lua", { ["view-source.lua"] = true })
  drop("hub.lua", { ["views.lua"] = true, ["directview.lua"] = true })
end
local companions = {
  ["hub.lua"] = { "planner-hub.lua" },
  ["panel.lua"] = { "planner-panel.lua" },
  ["server.lua"] = { "wh2-recipes.lua" },
}
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

local function selectFrom(roots)
  local selected = {}
  local function include(file)
    if selected[file] then return end
    selected[file] = true
    for _, dependency in ipairs(directList(file)) do include(dependency) end
  end
  for _, file in ipairs(roots) do include(file) end
  return selected
end
local function programFiles(id)
  local spec = roles[id]
  if not spec then return nil end
  local roots = { spec.entry }
  for _, extra in ipairs(companions[spec.entry] or {}) do roots[#roots + 1] = extra end
  local selected = selectFrom(roots)
  local list = {}
  for name in pairs(selected) do
    if name ~= spec.entry then list[#list + 1] = name end
  end
  table.sort(list)
  table.insert(list, 1, spec.entry)
  return list
end
local files = {}
for _, spec in pairs(roles) do
  if not spec.unavailable then
  local selected = selectFrom({ spec.entry, "install.lua", "update.lua" })
  for _, extra in ipairs(companions[spec.entry] or {}) do
    for name in pairs(selectFrom({ extra })) do selected[name] = true end
  end
  spec.files = {}
  for file in pairs(selected) do spec.files[#spec.files + 1] = file end
  table.sort(spec.files)
  for _, file in ipairs(spec.files) do files[file] = true end
  end
end
for _, file in ipairs({ "role-adapter.lua", "store-role.lua", "view-role.lua" }) do
  files[file] = true
end
local function cacheNames()
  local names = {}
  for name in pairs(files) do names[#names + 1] = name end
  table.sort(names)
  for i, name in ipairs(names) do
    if name == "miner.lua" then
      table.remove(names, i)
      table.insert(names, 1, name)
      break
    end
  end
  return names
end
local function writeCacheList(names)
  local lines, row = {}, "local FILES = { "
  local function add(text)
    if #row + #text > 100 then
      lines[#lines + 1] = row:gsub("%s+$", "")
      row = "  "
    end
    row = row .. text
  end
  for i, name in ipairs(names) do
    add(string.format("%q%s", name, i < #names and ", " or " }"))
  end
  lines[#lines + 1] = row
  local block = table.concat(lines, "\n")
  local source = read("server.lua")
  local updated = source:gsub("local FILES = %b{}", block, 1)
  if updated == source then return end
  local handle = assert(io.open("server.lua", "wb"))
  handle:write(updated)
  handle:close()
end
if arg and arg[1] == "--module" then
  return { programFiles = programFiles, cacheNames = cacheNames, directList = directList }
end
writeCacheList(cacheNames())
for name in pairs(files) do files[name] = checksum(read(name)) end
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
