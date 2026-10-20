-- CraftOS-PC entry for the A1 adapter. Writes sandbox-result.json and stops.
local failed = {}
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS " .. name)
  else
    failed[#failed + 1] = name .. ": " .. tostring(err)
    print("FAIL " .. name)
    print(tostring(err))
  end
end

local function encode(value)
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) ~= "table" then return tostring(value) end
  local keys, parts = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = "[" .. encode(key) .. "]=" .. encode(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function equal(actual, expected, message)
  assert(encode(actual) == encode(expected), (message or "values differ")
    .. "\nexpected: " .. encode(expected) .. "\nactual: " .. encode(actual))
end

local ran, err = pcall(function()
  dofile("tests/a1-checks.lua")(test, equal)
end)
if not ran then failed[#failed + 1] = tostring(err) end

local capacity = fs.getCapacity("/")
local result = {
  ok = #failed == 0, booted = true, errors = failed, lines = {},
  free = fs.getFreeSpace("/"), capacity = capacity,
}
local handle = assert(fs.open("sandbox-result.json", "w"))
handle.write(textutils.serializeJSON(result))
handle.close()
print(#failed == 0 and "A1 sandbox PASS" or "A1 sandbox FAIL")
os.shutdown()
