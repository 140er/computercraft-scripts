local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name)
    print("  " .. tostring(err))
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
    .. " expected " .. encode(expected) .. " actual " .. encode(actual))
end

assert(config.get("standardsMode") == true, "standardsMode disabled")
assert(fs.getCapacity("/") == 1000000, "disk " .. tostring(fs.getCapacity("/")))

dofile("tests/b2-checks.lua")(test, equal)

local handle = assert(fs.open("sandbox-result.json", "w"))
handle.write('{"ok":' .. (failed == 0 and "true" or "false") .. ',"passed":' .. passed .. ',"failed":' .. failed .. "}")
handle.close()
print(passed .. " passed, " .. failed .. " failed")
if failed > 0 then error("b2 sandbox failed", 0) end
