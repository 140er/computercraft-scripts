local function loadSlot(path)
  local handle = io.open(path)
  if not handle then return nil end
  local text = handle:read("*a")
  handle:close()
  if text == "" then return nil end
  local chunk = load("return " .. text, path, "t", {})
  if not chunk then return nil end
  local ok, value = pcall(chunk)
  if ok then return value end
end

return function(dir)
  local best
  for _, slot in ipairs({ "a", "b" }) do
    local value = loadSlot(dir .. "/ssot.control." .. slot)
    if type(value) == "table" and value.v == 1 and type(value.generation) == "number"
      and (not best or value.generation > best.generation) then
      best = value
    end
  end
  local control = best and best.value or nil
  local map
  if control and type(control.mapGen) == "number" then
    for _, slot in ipairs({ "a", "b" }) do
      local value = loadSlot(dir .. "/ssot.map." .. slot)
      if type(value) == "table" and value.generation == control.mapGen then map = value.value end
    end
  end
  return control, map
end
