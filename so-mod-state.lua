-- so-mod-state.lua - in-memory state stub. SO1 replaces this file and keeps emit, get, and view.

local mem = { values = {}, rev = 0 }

return {
  name = "state",
  handlers = {},
  tick = function() end,
  emit = function(key, value)
    mem.values[key] = value
    mem.rev = mem.rev + 1
  end,
  get = function(key)
    return mem.values[key]
  end,
  view = function()
    local values = {}
    for key, value in pairs(mem.values) do values[key] = value end
    return { rev = mem.rev, values = values }
  end,
}
