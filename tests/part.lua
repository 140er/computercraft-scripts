local manifest = dofile("tests/part-manifest.lua")
local rawOpen, rawLoad = io.open, loadfile
local violations = {}
local function check(path)
  local name = tostring(path):gsub("^%./", "")
  if not manifest.allowed[name] then
    violations[#violations + 1] = name
    error("PART DEPENDENCY VIOLATION: " .. name, 0)
  end
  return name
end
io.open = function(path, mode)
  if mode and mode:find("[wa+]") then error("part tests cannot write host files", 0) end
  return rawOpen(check(path), mode)
end
loadfile = function(path, mode, env)
  path = check(path)
  if env == nil then return rawLoad(path, mode) end
  return rawLoad(path, mode, env)
end
dofile = function(path) return assert(loadfile(path))() end
local rawRequire = require
require = function(name)
  local path = package.searchpath(name, package.path)
  if path then check(path) end
  if not path and not package.loaded[name] then error("PART DEPENDENCY VIOLATION: require " .. name, 0) end
  return rawRequire(name)
end
io.popen = function() error("part tests cannot start host processes", 0) end
os.execute = io.popen
os.remove = function() error("part tests cannot remove host files", 0) end
os.rename = os.remove
local mocks = dofile("tests/mocks.lua")
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1 end
  print((ok and "PASS " or "FAIL ") .. name)
  if not ok then print(tostring(err):sub(1, 3000)) end
end
local function equal(a, b, message)
  assert(mocks.encode(a) == mocks.encode(b), (message or "values differ")
    .. "\nexpected: " .. mocks.encode(b) .. "\nactual: " .. mocks.encode(a))
end
local function read(path)
  local file = assert(io.open(path, "rb"))
  local data = file:read("*a") file:close()
  return data
end
local began = os.clock()
for _, path in ipairs(manifest.suites) do
  local suite = dofile(path)
  if type(suite) == "table" then suite = suite.run end
  assert(type(suite) == "function", "not a test suite: " .. path)
  suite(test, equal, read, mocks)
end
print(string.format("part: %d passed, %d failed, %d undeclared reads; Lua CPU %.3fs",
  passed, failed, #violations, os.clock() - began))
if failed > 0 or #violations > 0 or passed == 0 then os.exit(1) end
