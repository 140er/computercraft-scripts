-- CC:AR 0.2.1 subset; exact jar signatures and bytecode are saved in evidence/.
return function()
  local state = { elements = {}, published = {}, updates = 0, calls = {} }
  local ar = setmetatable({}, { __name = "peripheral", name = "craftos_ar",
    type = "ar_controller", types = { "ar_controller", ar_controller = true } })
  local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
  end
  local signatures = {
    drawLine3D = { "string", "number", "number", "number", "number", "number", "number", "number" },
    drawText2D = { "string", "number", "number", "number", "string", "boolean" },
    drawText3D = { "string", "number", "number", "number", "number", "number", "number", "number", "string", "boolean" },
    drawRect2D = { "string", "number", "number", "number", "number", "number" },
    drawItemIcon3D = { "string", "number", "number", "number", "number", "number", "number", "string" },
  }
  for method, signature in pairs(signatures) do
    ar[method] = function(...)
      local args = { ... }
      for i, kind in ipairs(signature) do
        assert(type(args[i]) == kind, method .. " argument " .. i .. " requires " .. kind)
      end
      state.elements[args[1]] = { method = method, args = copy(args) }
      state.calls[method] = (state.calls[method] or 0) + 1
    end
  end
  ar.delete = function(id)
    assert(type(id) == "string", "delete requires an element id")
    state.elements[id] = nil
  end
  ar.clear = function() state.elements = {} end
  ar.update = function()
    state.published = copy(state.elements)
    state.updates = state.updates + 1
    state.version = os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000)
  end
  return ar, state
end
