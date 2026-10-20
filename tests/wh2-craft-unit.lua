local mocks = dofile("tests/mocks.lua")
local env = mocks.new(false).env
env.dofile = function(path) return assert(loadfile(path, "t", env))() end
local Craft = env.dofile("wh2-craft.lua")
local Recipes = env.dofile("wh2-recipes.lua")
local Worker = env.dofile("craft.lua")
local failed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n  " .. tostring(err))
  end
end
dofile("tests/wh2-craft-checks.lua")(test, Craft, Recipes, Worker)
if failed > 0 then error(failed .. " craft failures") end
