local M = {}

local function read(path)
  local file = fs.open(path, "r")
  if not file then return nil end
  local value = textutils.unserializeJSON(file.readAll())
  file.close()
  return value
end

local function write(path, value)
  local file = assert(fs.open(path .. ".tmp", "w"))
  file.write(textutils.serializeJSON(value))
  file.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path .. ".tmp", path)
end

local function rows(inventory)
  local out = {}
  for slot, row in pairs(inventory.list()) do
    assert(type(row.name) == "string" and type(row.count) == "number"
      and row.count > 0 and row.count % 1 == 0, "invalid native inventory observation")
    out[#out + 1] = {slot=tonumber(slot), name=row.name, count=row.count, nbt=row.nbt or false}
  end
  table.sort(out, function(a, b) return a.slot < b.slot end)
  return out
end

local function totals(...)
  local out = {}
  for _, list in ipairs({...}) do
    for _, row in ipairs(list) do out[row.name] = (out[row.name] or 0) + row.count end
  end
  return out
end

function M.equal(a, b)
  for item, n in pairs(a) do if b[item] ~= n then return false end end
  for item, n in pairs(b) do if a[item] ~= n then return false end end
  return true
end

function M.install(cfg)
  assert(cfg.runtime == "sandbox" and cfg.role == "turtle", "emulator inventory requires a sandbox turtle")
  local input = assert(peripheral.wrap("top"), "missing native CraftOS input chest")
  local output = assert(peripheral.wrap("bottom"), "missing native CraftOS output chest")
  local held = assert(peripheral.wrap("wizard_turtle"), "missing native CraftOS turtle inventory chest")
  local path = "wizard-native-inventories.json"
  local state = read(path)
  local function restore(inventory, saved)
    for slot = 1, inventory.size() do inventory.setItem(slot, {name="minecraft:air", count=0}) end
    for _, row in ipairs(saved) do
      assert(row.nbt == nil or row.nbt == false, "component-bearing CraftOS fixtures cannot be restored by this adapter")
      assert(inventory.setItem(row.slot, {name=row.name, count=row.count}) == row.count, "native inventory restore failed")
    end
  end
  if state then
    assert(state.v == 1 and type(state.selected) == "number" and state.selected >= 1
      and state.selected <= 16, "invalid saved emulator inventory")
    restore(input, state.input) restore(output, state.output) restore(held, state.held)
  else
    local plan = assert(read("wizard-plan.json"), "missing emulator fixture plan")
    state = {v=1, selected=1, fuel=2000, input={}, output={}, held={}}
    for slot, row in ipairs(plan.inventories[1].contents) do
      assert(input.setItem(slot, {name=row.item, count=row.count}) == row.count, "native fixture fill failed")
    end
  end
  local function persist()
    state.input, state.output, state.held = rows(input), rows(output), rows(held)
    write(path, state)
  end
  local api = {}
  function api.select(slot)
    assert(type(slot) == "number" and slot % 1 == 0 and slot >= 1 and slot <= 16, "invalid turtle slot")
    state.selected = slot persist() return true
  end
  function api.getSelectedSlot() return state.selected end
  function api.getItemCount(slot)
    local row = held.list()[slot or state.selected]
    return row and row.count or 0
  end
  function api.getItemDetail(slot) return held.list()[slot or state.selected] end
  function api.getFuelLevel() return state.fuel end
  function api.suckUp(limit)
    for slot = 1, input.size() do
      if input.list()[slot] then
        local moved = input.pushItems("wizard_turtle", slot, limit or 64, state.selected)
        persist()
        return moved > 0
      end
    end
    return false, "No items to take"
  end
  function api.dropDown(limit)
    local moved = held.pushItems("bottom", state.selected, limit or 64)
    persist()
    return moved > 0, moved == 0 and "No space for items" or nil
  end
  persist()
  _G.turtle = api
  return {persist=persist, mode="craftos-native-inventory"}
end

function M.snapshot()
  assert(turtle and type(turtle.getItemDetail) == "function", "native turtle inventory unavailable")
  local input = assert(peripheral.wrap("top"), "input inventory peripheral unavailable")
  local output = assert(peripheral.wrap("bottom"), "output inventory peripheral unavailable")
  assert(type(input.list) == "function" and type(output.list) == "function", "adjacent inventories lack native list API")
  local held = {}
  for slot = 1, 16 do
    local row = turtle.getItemDetail(slot)
    if row then held[#held + 1] = {slot=slot, name=row.name, count=row.count, nbt=row.nbt or false} end
  end
  local top, bottom = rows(input), rows(output)
  return {input=top, held=held, output=bottom, totals=totals(top, held, bottom)}
end

function M.route(classes, unknowns, evidence)
  local before = M.snapshot()
  local moved, blocked, wanted = {}, {}, {}
  for _, item in ipairs(unknowns) do wanted[item] = true end
  local selected = turtle.getSelectedSlot()
  for slot = 1, 16 do
    turtle.select(slot)
    if turtle.getItemCount(slot) == 0 then turtle.suckUp() end
    local row = turtle.getItemDetail(slot)
    if row and wanted[row.name] and classes[row.name] and classes[row.name].route == "store" then
      turtle.dropDown()
      local amount = row.count - turtle.getItemCount(slot)
      moved[row.name] = (moved[row.name] or 0) + amount
      if amount < row.count then blocked[row.name] = (blocked[row.name] or 0) + row.count - amount end
    end
  end
  turtle.select(selected)
  local after = M.snapshot()
  assert(M.equal(before.totals, after.totals), "native transfer changed total item counts")
  local beforeOutput, afterOutput = totals(before.output), totals(after.output)
  for item, amount in pairs(moved) do
    assert((afterOutput[item] or 0) - (beforeOutput[item] or 0) == amount, "native destination delta differs from turtle delta")
  end
  local result = {moved=moved, blocked=blocked, totals=after.totals, slots="CC 1-based", boundary="native-inventory-adapter"}
  evidence("native-transfer", result)
  return result
end

return M
