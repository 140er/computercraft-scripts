local mocks = dofile("tests/mocks.lua")
local only = ...
local cache = {}
local function read(path)
  if cache[path] then return cache[path] end
  local f = assert(io.open(path, "rb"))
  cache[path] = f:read("*a")
  f:close()
  return cache[path]
end
local function equal(actual, expected, message)
  assert(mocks.encode(actual) == mocks.encode(expected),
    (message or "Values differ") .. "\nactual: " .. mocks.encode(actual) .. "\nexpected: " .. mocks.encode(expected))
end
local passed, failed = 0, 0
local function test(name, run)
  if only and not name:find(only, 1, true) then return end
  if not (name:find("AR", 1, true) or name:find("controller", 1, true)
    or name:find("HUD", 1, true) or name:find("toggle", 1, true) or name:find("owner", 1, true)
    or name:find("frame", 1, true) or name:find("hub fallback", 1, true)
    or name:find("expired ready", 1, true) or name:find("server draws", 1, true)
    or name:find("hub restores fleet", 1, true)) then return end
  local ok, err = pcall(run)
  if ok then passed = passed + 1 print("PASS " .. name)
  else failed = failed + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end
dofile("tests/server.lua")(test, equal, read, mocks)
print(passed .. " passed, " .. failed .. " failed")
os.exit(failed == 0 and 0 or 1)
