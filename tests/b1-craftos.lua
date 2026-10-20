-- CraftOS entry for the B1 suite. The PUC runner is tests/b1-unit.lua.
local result = { ok = false, booted = true, errors = {}, lines = {} }
local ok, err = pcall(function()
  assert(config.get("standardsMode") == true, "standardsMode disabled")
  assert(fs.getCapacity("/") == 4000000, "wrong disk limit")
  dofile("tests/b1-unit.lua")
end)
if not ok then result.errors[1] = tostring(err) else result.ok = true end
result.free = fs.getFreeSpace("/")
result.lines[1] = result.ok and "b1 unit passed" or "b1 unit failed"
if #result.errors == 0 then result.errors = textutils.empty_json_array end
local handle = fs.open("sandbox-result.json", "w")
handle.write(textutils.serializeJSON(result))
handle.close()
