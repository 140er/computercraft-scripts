-- One role, one disk. The closure is every static and lazy literal dofile,
-- loadfile, require, and pcall of those. A path passed into a local function
-- that loads it counts too. A file the closure loads and the bundle does not
-- ship is a failure.
--
-- tests/f0-expected.lua, when present, freezes the installer gaps. The
-- release bundle and the root-module manifest are never allowlisted.

local graph = dofile("tests/f0-graph.lua")
local manifest = dofile("bundle-manifest.lua")

local function sorted(list)
  table.sort(list)
  return list
end

local function missing(order, shipped)
  local out = {}
  for _, path in ipairs(order) do
    if not shipped[path] then out[#out + 1] = path end
  end
  return sorted(out)
end

local function same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

local function shippedSet(list)
  local set = {}
  for _, name in ipairs(list or {}) do set[name] = true end
  return set
end

local expected
local handle = io.open("tests/f0-expected.lua", "rb")
if handle then
  handle:close()
  expected = dofile("tests/f0-expected.lua")
end

local failed = false
local roots = {}

local function noteRoot(order)
  for _, path in ipairs(order) do
    if not path:find("/", 1, true) then roots[path] = true end
  end
end

local function show(path)
  local note = graph.read(path) and "" or " (not in tree)"
  print("  " .. path .. note)
end

local function report(kind, id, miss)
  if #miss == 0 then
    print(kind .. " " .. id .. " PASS")
    return
  end
  if kind == "install" and expected then
    local want = sorted(expected[id] or {})
    if same(miss, want) then
      print(kind .. " " .. id .. " EXPECTED")
      for _, path in ipairs(miss) do show(path) end
      return
    end
    print(kind .. " " .. id .. " FAIL expected list does not match")
  else
    print(kind .. " " .. id .. " FAIL")
  end
  for _, path in ipairs(miss) do show(path) end
  failed = true
end

for _, role in ipairs(graph.installRoles()) do
  local order = graph.closure(role.entry)
  noteRoot(order)
  report("install", role.id, missing(order, role.files))
end

local ids = {}
for id in pairs(manifest.roles) do ids[#ids + 1] = id end
table.sort(ids)
for _, id in ipairs(ids) do
  local spec = manifest.roles[id]
  if type(spec.files) ~= "table" then
    print("release " .. id .. " FAIL no file list")
    failed = true
  else
    local order = graph.closure(spec.entry)
    noteRoot(order)
    report("release", id, missing(order, shippedSet(spec.files)))
  end
end

local rootMiss = {}
for path in pairs(roots) do
  if not manifest.files[path] then rootMiss[#rootMiss + 1] = path end
end
rootMiss = sorted(rootMiss)
if #rootMiss == 0 then
  print("root PASS")
else
  print("root FAIL")
  for _, path in ipairs(rootMiss) do show(path) end
  failed = true
end

local function listed(list, name)
  for _, item in ipairs(list) do
    if item == name then return true end
  end
  return false
end

local bare, bareGuarded = graph.literalDeps('dofile("bare-missing.lua")\n')
local guardedOnly, guardedNames = graph.literalDeps('pcall(require,"guarded-missing")\n')
if not listed(bare, "bare-missing.lua") or listed(guardedOnly, "guarded-missing")
    or not listed(guardedNames, "guarded-missing") or listed(bareGuarded, "bare-missing.lua") then
  print("classifier FAIL unguarded missing module was not required")
  failed = true
end

local attemptSrc = [[
local function attempt(path)
  local ok, mod = pcall(dofile, path)
  if ok and type(mod) == "table" then return mod end
end
attempt("lib/stubs/craft_dep.lua")
attempt("craft_dep.lua")
]]
local attemptReq, attemptGrd = graph.forwardedDeps(attemptSrc)
if listed(attemptReq, "craft_dep.lua") or listed(attemptReq, "lib/stubs/craft_dep.lua")
    or not listed(attemptGrd, "craft_dep.lua") or not listed(attemptGrd, "lib/stubs/craft_dep.lua") then
  print("classifier FAIL guarded fallback was required")
  failed = true
end

local craftDeps = graph.direct("craft.lua")
local hostDeps = graph.direct("wh2-wizard-host.lua")
if not listed(craftDeps, "lib/stubs/craft_dep.lua") or listed(craftDeps, "craft_dep.lua")
    or listed(hostDeps, "ssot-auth.lua")
    or not listed(hostDeps, "wh2-client.lua")
    or not listed(hostDeps, "ssot-client.lua") then
  print("classifier FAIL real optional loads were required")
  failed = true
end

local optional = graph.guardedAbsent()
for _, path in ipairs(optional) do
  print("optional " .. path .. " (guarded, not in tree)")
end

if failed then
  print("role-load failed")
  os.exit(1)
end
print("role-load passed")
