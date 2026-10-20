local cache = {}
local snapshot = ...
local function read(path)
  if cache[path] then return cache[path] end
  local source = snapshot and not path:match("^tests/") and snapshot .. "/" .. path or path
  local f = assert(io.open(source, "rb"))
  local text = f:read("*a")
  f:close()
  cache[path] = text
  return text
end
local release = assert(load(read("bundle-manifest.lua"), "=manifest", "t", {}))()
if snapshot then print("Replaying migration regressions against saved source " .. snapshot .. "; release " .. release.version) end
if release.pending and #release.pending > 0 then
  print("Testing the real pending manifest. Unavailable roles must refuse installation; the all-role gate remains incomplete.")
end
local failed, passed = 0, 0
local function test(name, run)
  if snapshot and not (name:find("legacy data", 1, true) or name:find("legacy startup", 1, true)
    or name:find("actual v1", 1, true)) then return end
  local ok, err = pcall(run)
  if ok then passed = passed + 1 print("PASS " .. name)
  else failed = failed + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end
assert(load(read("update.lua")))
assert(load(read("install.lua")))
assert(loadfile("tests/ingame/ar-install-probe.lua"))
dofile("tests/install-role-checks.lua")(test, read, dofile("tests/mocks.lua"))
dofile("tests/install-checks.lua")(test, read, dofile("tests/mocks.lua"))
print(passed .. " passed, " .. failed .. " failed")
os.exit(failed == 0 and 0 or 1)
