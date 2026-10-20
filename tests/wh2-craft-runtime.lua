local failed = {}
local function test(name, fn)
  local ok, err = pcall(fn)
  print((ok and "PASS " or "FAIL ") .. name)
  if not ok then failed[#failed + 1] = name .. ": " .. tostring(err) end
end

local Craft = dofile("wh2-craft.lua")
local Recipes = dofile("wh2-recipes.lua")
local Worker = dofile("craft.lua")
dofile("wh2-craft-checks.lua")(test, Craft, Recipes, Worker)

local capacity = fs.getCapacity("/")
local free = fs.getFreeSpace("/")
local result = {
  ok = #failed == 0, booted = true, errors = failed,
  lines = { "capacity=" .. tostring(capacity), "free=" .. tostring(free) },
  free = free, capacity = capacity,
}
if config and config.get and config.get("standardsMode") ~= true then
  result.ok = false
  result.errors[#result.errors + 1] = "standardsMode disabled"
end
local handle = fs.open("sandbox-result.json", "w")
handle.write(textutils.serializeJSON(result))
handle.close()
if #failed > 0 then
  for _, line in ipairs(failed) do print(line) end
end
os.shutdown()
