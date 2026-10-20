local mocks = dofile("tests/mocks.lua")
local function read(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end
local function equal(actual, expected, message)
  assert(mocks.encode(actual) == mocks.encode(expected), (message or "values differ")
    .. "\nexpected: " .. mocks.encode(expected):sub(1, 180)
    .. "\nactual: " .. mocks.encode(actual):sub(1, 180))
end
local passed, failed = 0, 0
local function test(name, fn)
  if not name:match("^update ") then return end
  local ok, err = pcall(fn)
  print((ok and "PASS " or "FAIL ") .. name)
  if ok then passed = passed + 1 else failed = failed + 1 print(err) end
end
dofile("tests/server.lua")(test, equal, read, mocks)
dofile("tests/install-checks.lua")(test, read, mocks)
print(passed .. " passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
