-- Seam for items that are not on this branch.
-- W1 replaces register() when wh2-fleet.lua loads wh2-craft.lua.
-- Layout replaces reserve() with warehouse stock reservations (wh2-layout.lua reserveCraft).
-- W1's wh2-client.lua replaces lookupClass(). Wizard owns the class rows behind that client.

local M = {}

function M.register()
  return {
    module = "wh2-craft",
    ops = { "wh2-craft", "wh2-recipe" },
    topic = "crafts",
  }
end

function M.reserve()
  return { orderKey = false, line = false, deferred = true }
end

function M.lookupClass(itemId)
  return {
    v = 1, item = itemId, route = "unknown", source = false,
    revision = 0, recipeId = false,
  }
end

return M
