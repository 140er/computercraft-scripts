-- Recipe provider and production planner. The hub calls open(); the server
-- stores only the plan wh2-craft.lua accepts. The cache stays in RAM.

local M = {}

M.limits = {
  cache = 131072,
  steps = 128,
  plan = 65536,
  fragment = 4096,
  result = 65536,
  page = 100,
}

local DEFAULT_TYPES = {
  ["minecraft:crafting"] = true,
  ["minecraft:smelting"] = true,
  ["minecraft:blasting"] = true,
  ["minecraft:smoking"] = true,
}

local UNRESOLVED = {
  chance_only = true, cycle = true, adapter_unsupported = true,
  components_unresolved = true, alternatives_incomplete = true,
  empty_tag = true, plan_limit = true,
}

local function int(n, a, b)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= a and n <= b
end

local function itemId(v)
  return type(v) == "string" and #v <= 128 and v:match("^[%w_]+:[%w_/.-]+$") ~= nil
end

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then error("cycle", 0) end
  seen[value] = true
  local out = {}
  for k, v in pairs(value) do out[copy(k, seen)] = copy(v, seen) end
  seen[value] = nil
  return out
end

local function bytes(value)
  local ok, text = pcall(textutils.serialize, value, { compact = true })
  if not ok then ok, text = pcall(textutils.serialize, value) end
  if not ok or type(text) ~= "string" then return nil end
  return #text, text
end

local function issue(code, item, recipeId, path, detail)
  return {
    code = code, item = item or false, recipeId = recipeId or false,
    path = path or {}, detail = detail or "",
  }
end

local function guaranteed(recipe, item)
  local total, blocked = 0, false
  for _, output in ipairs(recipe.outputs or {}) do
    if output.item == item then
      local chance = output.chance
      if chance == nil then chance = 1 end
      if output.components ~= nil and output.components ~= false then
        blocked = "components"
      elseif type(chance) == "number" and chance >= 1 and int(output.count or 0, 1, 1000000) then
        total = total + output.count
      end
    end
  end
  return total, blocked
end

local function produces(recipe, item)
  for _, output in ipairs(recipe.outputs or {}) do
    if output.item == item then return true end
  end
  return false
end

local function adapterOf(adapters, typeName)
  if adapters[typeName] == nil then return nil end
  return adapters[typeName]
end

local function eligible(recipe, item, adapters)
  if not adapterOf(adapters, recipe.type) then
    return issue("adapter_unsupported", item, recipe.id, {}, recipe.type or "")
  end
  if type(recipe.steps) == "table" or recipe.fluids or recipe.heat or recipe.tools or recipe.energy then
    local adapter = adapters[recipe.type]
    if type(adapter) ~= "table" or adapter.extra ~= true then
      return issue("adapter_unsupported", item, recipe.id, {}, "extra")
    end
  end
  local count, blocked = guaranteed(recipe, item)
  if blocked == "components" and count == 0 then
    return issue("components_unresolved", item, recipe.id, {}, "components")
  end
  if count <= 0 then
    return issue("chance_only", item, recipe.id, {}, "chance")
  end
  return nil, count
end

local function sortedIds(catalog, item)
  local ids = {}
  for id, recipe in pairs(catalog.recipes or {}) do
    if recipe.id == id and produces(recipe, item) then ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end

local function choose(catalog, item, choices, adapters)
  local ids = sortedIds(catalog, item)
  local picked = choices and choices[item]
  if picked ~= nil then
    local recipe = catalog.recipes[picked]
    if not recipe or not produces(recipe, item) then
      return nil, { issue("adapter_unsupported", item, picked, {}, "invalid_choice") }
    end
    local why, count = eligible(recipe, item, adapters)
    if why then return nil, { why } end
    return recipe, nil, count
  end
  local rejected, winner, winCount = {}, nil, nil
  for _, id in ipairs(ids) do
    local why, count = eligible(catalog.recipes[id], item, adapters)
    if not why and not winner then
      winner, winCount = catalog.recipes[id], count
    elseif why then
      rejected[#rejected + 1] = why
    end
  end
  if winner then return winner, nil, winCount end
  return nil, rejected
end

local function pool(stock, item)
  local entry = stock[item]
  if type(entry) == "number" then return { any = entry, fp = {} } end
  if type(entry) ~= "table" then return { any = 0, fp = {} } end
  local any, fp = 0, {}
  if int(entry.count or 0, 0, 1000000) and entry.nbt == nil then any = entry.count end
  local map = entry.nbt or entry
  if entry.nbt or entry.count == nil then
    for key, count in pairs(map) do
      if type(key) == "string" and int(count, 0, 1000000) then
        if key == "" then any = any + count else fp[key] = count end
      end
    end
  end
  return { any = any, fp = fp }
end

local function have(stock, item, nbt)
  local got = pool(stock, item)
  if type(nbt) == "string" then return got.fp[nbt] or 0 end
  local sum = got.any
  for _, count in pairs(got.fp) do sum = sum + count end
  return sum
end

local function take(stock, item, nbt, qty)
  if qty <= 0 then return end
  local entry = stock[item]
  if type(entry) == "number" then
    if type(nbt) == "string" then return end
    stock[item] = math.max(0, entry - qty)
    return
  end
  if type(nbt) == "string" then
    if type(entry) == "table" and type(entry.nbt) == "table" then
      entry.nbt[nbt] = math.max(0, (entry.nbt[nbt] or 0) - qty)
    elseif type(entry) == "table" then
      entry[nbt] = math.max(0, (entry[nbt] or 0) - qty)
    end
    return
  end
  local left = qty
  if type(entry) == "number" then
    stock[item] = math.max(0, entry - left)
    return
  end
  if type(entry) ~= "table" then return end
  local keys = {}
  local map = entry.nbt or entry
  for key in pairs(map) do if type(key) == "string" then keys[#keys + 1] = key end end
  table.sort(keys)
  for _, key in ipairs(keys) do
    if left <= 0 then break end
    local use = math.min(left, map[key])
    map[key] = map[key] - use
    left = left - use
  end
end

local function members(catalog, input)
  if input.item then return { input.item }, false, "item" end
  if input.items then
    local list = {}
    for _, id in ipairs(input.items) do list[#list + 1] = id end
    table.sort(list)
    return list, input.more == true, "items"
  end
  if input.tag then
    local known = catalog.tags and catalog.tags[input.tag]
    if known == nil then return {}, true, "tag" end
    local list = {}
    for _, id in ipairs(known) do list[#list + 1] = id end
    table.sort(list)
    return list, input.more == true, "tag"
  end
  return {}, false, "bad"
end

local function pushPath(path, kind, id)
  local nextPath = {}
  for i, entry in ipairs(path) do nextPath[i] = entry end
  nextPath[#nextPath + 1] = { kind = kind, id = id }
  return nextPath
end

function M.plan(spec)
  spec = spec or {}
  local output = spec.output or {}
  local catalog = spec.catalog or {}
  local choices = spec.recipeChoices or {}
  local adapters = spec.adapters or DEFAULT_TYPES
  local limitSteps = spec.stepLimit or M.limits.steps
  local limitBytes = spec.planBudget or M.limits.plan
  local result = {
    steps = {}, missing = {}, unresolved = {},
    generation = catalog.generation or false, error = false,
  }
  if not itemId(output.item) or not int(output.count, 1, 1000000) then
    result.error = "invalid"
    return result
  end
  local stock = copy(spec.stock or {})
  local nodes, missing, unresolved = {}, {}, {}
  local seenMissing = {}

  local function addMissing(item, count, nbt)
    local key = item .. "\0" .. tostring(nbt or false)
    if seenMissing[key] then
      seenMissing[key].count = seenMissing[key].count + count
      return
    end
    local row = { item = item, count = count, nbt = nbt or false }
    seenMissing[key] = row
    missing[#missing + 1] = row
  end

  local function addUnresolved(row)
    unresolved[#unresolved + 1] = row
  end

  local function canMake(item, stack)
    if stack[item] then return false end
    local recipe = choose(catalog, item, choices, adapters)
    return recipe ~= nil
  end

  local function pick(input, qty, stack, path)
    local list, more, kind = members(catalog, input)
    if kind == "bad" then
      addUnresolved(issue("alternatives_incomplete", false, false, path, "ingredient"))
      return nil
    end
    if kind == "item" then return list[1], input.nbt or false end
    if #list == 0 then
      addUnresolved(issue(more and "alternatives_incomplete" or "empty_tag", false, false, path, input.tag or "items"))
      return nil
    end
    local nbt = input.nbt or false
    local stocked = {}
    for _, id in ipairs(list) do
      if have(stock, id, nbt) >= qty then stocked[#stocked + 1] = id end
    end
    table.sort(stocked)
    if stocked[1] then return stocked[1], nbt end
    local makers = {}
    for _, id in ipairs(list) do
      if canMake(id, stack) then makers[#makers + 1] = id end
    end
    table.sort(makers)
    if makers[1] then return makers[1], nbt end
    if more then
      addUnresolved(issue("alternatives_incomplete", false, false, path, input.tag or "items"))
      return nil
    end
    return list[1], nbt
  end

  local function ensure(item, qty, nbt, stack, path, via)
    if qty <= 0 then return true end
    local use = math.min(qty, have(stock, item, nbt))
    take(stock, item, nbt, use)
    qty = qty - use
    if qty == 0 then return true end
    if type(nbt) == "string" then
      addMissing(item, qty, nbt)
      addUnresolved(issue("components_unresolved", item, false, path, "fingerprint"))
      return false
    end
    if stack[item] then
      addUnresolved(issue("cycle", item, false, path, "cycle"))
      return false
    end
    local node = nodes[item]
    if not node then
      local recipe, rejected, each = choose(catalog, item, choices, adapters)
      if not recipe then
        if rejected and #rejected > 0 then
          for _, row in ipairs(rejected) do
            row.path = path
            addUnresolved(row)
          end
        end
        addMissing(item, qty, false)
        return false
      end
      node = {
        item = item, recipe = recipe, each = each, batches = 0, committed = 0,
        via = via or 0, needsItems = {}, ingredients = {}, path = path,
      }
      nodes[item] = node
    end
    local haveOut = node.batches * node.each - node.committed
    if haveOut >= qty then
      node.committed = node.committed + qty
      return true
    end
    local extra = qty - haveOut
    local extraBatches = math.floor((extra + node.each - 1) / node.each)
    if node.batches + extraBatches > 1000000 then
      addUnresolved(issue("plan_limit", item, node.recipe.id, path, "batches"))
      return false
    end
    local first = node.batches == 0
    node.batches = node.batches + extraBatches
    node.committed = node.committed + qty
    local itemPath = pushPath(path, "item", item)
    local recipePath = pushPath(itemPath, "recipe", node.recipe.id)
    stack[item] = true
    if first then
      node.bound = {}
      local inputs = {}
      for index, input in ipairs(node.recipe.inputs or {}) do
        inputs[#inputs + 1] = { index = index, input = input, perBatch = input.count, fuel = false }
      end
      local adapter = adapters[node.recipe.type]
      if type(adapter) == "table" and type(adapter.fuelPerBatch) == "table" then
        inputs[#inputs + 1] = {
          index = #inputs + 1,
          input = { count = adapter.fuelPerBatch.count, item = adapter.fuelPerBatch.item },
          perBatch = adapter.fuelPerBatch.count, fuel = true,
        }
      end
      for _, row in ipairs(inputs) do
        local per = row.perBatch or 1
        if not int(per, 1, 4096) then
          addUnresolved(issue("plan_limit", item, node.recipe.id, recipePath, "count"))
        else
          local chosen, chosenNbt = pick(row.input, per * node.batches, stack, recipePath)
          if chosen then
            node.bound[#node.bound + 1] = {
              item = chosen, nbt = chosenNbt or false, perBatch = per,
              index = row.index, fuel = row.fuel,
            }
            node.ingredients[#node.ingredients + 1] = {
              item = chosen, nbt = chosenNbt or false, perBatch = per,
              orderKey = false, line = false,
            }
          end
        end
      end
    end
    for _, bound in ipairs(node.bound or {}) do
      local childPath = pushPath(recipePath, "item", bound.item)
      ensure(bound.item, bound.perBatch * extraBatches, bound.nbt, stack, childPath, bound.index)
      if nodes[bound.item] then
        local known = false
        for _, haveItem in ipairs(node.needsItems) do
          if haveItem == bound.item then known = true end
        end
        if not known then node.needsItems[#node.needsItems + 1] = bound.item end
      end
    end
    stack[item] = nil
    return true
  end

  ensure(output.item, output.count, output.nbt or false, {}, {}, 0)

  local emitted, done = {}, {}
  local function ready(item, node)
    for _, dep in ipairs(node.needsItems) do
      if nodes[dep] and not done[dep] then return false end
    end
    return not done[item]
  end
  while true do
    local bestItem, best = nil, nil
    for item, node in pairs(nodes) do
      if ready(item, node) then
        if not best or node.recipe.id < best.recipe.id
          or (node.recipe.id == best.recipe.id and node.via < best.via) then
          bestItem, best = item, node
        end
      end
    end
    if not best then break end
    done[bestItem] = true
    local needs = {}
    for _, dep in ipairs(best.needsItems) do
      if emitted[dep] then needs[#needs + 1] = emitted[dep] end
    end
    local pattern = false
    if best.recipe.type == "minecraft:crafting" and type(best.recipe.pattern) == "table" then
      pattern = {}
      for slot, value in pairs(best.recipe.pattern) do
        if type(value) == "number" then
          local ingredient = best.ingredients[value]
          pattern[slot] = ingredient and ingredient.item or false
        else
          pattern[slot] = value
        end
      end
    end
    local step = {
      id = #result.steps + 1,
      recipeId = best.recipe.id,
      type = best.recipe.type,
      batches = best.batches,
      machineLocationId = false,
      needs = needs,
      state = "pending",
      outputItem = best.item,
      ingredients = best.ingredients,
      pattern = pattern,
    }
    result.steps[#result.steps + 1] = step
    emitted[bestItem] = step.id
    if #result.steps > limitSteps then
      result.steps = {}
      unresolved[#unresolved + 1] = issue("plan_limit", output.item, false, {}, "steps")
      break
    end
  end

  local function byItem(a, b)
    if a.item ~= b.item then return a.item < b.item end
    return tostring(a.nbt) < tostring(b.nbt)
  end
  table.sort(missing, byItem)
  result.missing = missing
  result.unresolved = unresolved
  local size = bytes({ steps = result.steps, missing = result.missing, unresolved = result.unresolved })
  if not size or size > limitBytes or #result.steps > limitSteps then
    result.steps = {}
    result.unresolved = { issue("plan_limit", output.item, false, {}, "bytes") }
  end
  for _, row in ipairs(result.unresolved) do
    if not UNRESOLVED[row.code] then row.code = "plan_limit" end
  end
  return result
end

local function ingredientFrom(spec)
  if type(spec) == "string" then
    if spec:sub(1, 1) == "#" then return { count = 1, tag = spec:sub(2) } end
    return { count = 1, item = spec }
  end
  if type(spec) ~= "table" then return nil end
  local count = spec.count or spec[2] or 1
  if not int(count, 1, 4096) then return nil end
  local head = spec.item or spec.tag or spec[1]
  if type(head) == "string" and head:sub(1, 1) == "#" then
    return { count = count, tag = head:sub(2), more = spec.more == true }
  end
  if type(head) == "string" then return { count = count, item = head } end
  if type(head) == "table" then
    local items = {}
    for _, id in ipairs(head) do
      if type(id) ~= "string" then return nil end
      items[#items + 1] = id:sub(1, 1) == "#" and id:sub(2) or id
    end
    return { count = count, items = items, more = spec.more == true }
  end
  if spec.tag then return { count = count, tag = spec.tag, more = spec.more == true } end
  if spec.items then return { count = count, items = spec.items, more = spec.more == true } end
  return nil
end

local function outputsFrom(spec)
  if type(spec) ~= "table" then return nil end
  if type(spec[1]) == "string" then
    local chance = spec[3] or 1
    local row = { item = spec[1], count = spec[2] or 1, chance = chance }
    if type(spec[4]) == "table" then row.components = spec[4] end
    return { row }
  end
  local rows = {}
  for _, entry in ipairs(spec) do
    local one = outputsFrom(entry)
    if not one then return nil end
    rows[#rows + 1] = one[1]
  end
  return rows
end

function M.importDump(dump, hash)
  if type(dump) ~= "table" or type(hash) ~= "string" or #hash < 8 or #hash > 64 then
    return nil, "invalid"
  end
  local recipes, tags = {}, {}
  if type(dump.tags) == "table" then
    for tag, list in pairs(dump.tags) do
      if type(tag) == "string" and type(list) == "table" then tags[tag] = copy(list) end
    end
  end
  local source = dump.recipes or dump
  for id, row in pairs(source) do
    if id ~= "tags" and id ~= "recipes" and type(row) == "table" then
      local recipeId = type(row.n) == "string" and row.n:match("^[%w_]+:") and row.n or id
      local inputs, pattern = {}, false
      local typeName = "minecraft:crafting"
      if type(row.s) == "string" then
        typeName = row.s
        for _, spec in ipairs(row.l or {}) do
          local ingredient = ingredientFrom(spec)
          if not ingredient then return nil, "invalid" end
          inputs[#inputs + 1] = ingredient
        end
      elseif type(row.s) == "table" then
        typeName = "minecraft:crafting"
        pattern = {}
        local slots = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
        for index, spec in ipairs(row.s) do
          local slot = slots[index]
          if not slot then return nil, "invalid" end
          if spec ~= false and spec ~= "" then
            local ingredient = ingredientFrom(spec)
            if not ingredient then return nil, "invalid" end
            local found = false
            for at, have in ipairs(inputs) do
              if have.item == ingredient.item and have.tag == ingredient.tag and have.count == ingredient.count then
                pattern[slot] = at
                found = true
              end
            end
            if not found then
              inputs[#inputs + 1] = ingredient
              pattern[slot] = #inputs
            end
          end
        end
        for _, spec in ipairs(row.l or {}) do
          local ingredient = ingredientFrom(spec)
          if not ingredient then return nil, "invalid" end
          inputs[#inputs + 1] = ingredient
        end
      else
        return nil, "invalid"
      end
      local outputs = outputsFrom(row.o)
      if not outputs then return nil, "invalid" end
      for _, output in ipairs(outputs) do
        if output.components ~= nil and output.components ~= false then
          output.components = copy(output.components)
        end
      end
      recipes[recipeId] = {
        id = recipeId, type = typeName, machine = type(row.n) == "string" and row.n or false,
        inputs = inputs, outputs = outputs, pattern = pattern,
      }
    end
  end
  return {
    v = 1, source = "dump", hash = hash,
    generation = "dump:" .. hash, recipes = recipes, tags = tags,
  }
end

function M.cache(limit)
  limit = limit or M.limits.cache
  local order, data, used = {}, {}, 0
  local api = {}
  function api.put(key, value)
    if type(key) ~= "string" then return false, "invalid" end
    local size = bytes(value)
    if not size or size > limit then return false, "too_large" end
    if data[key] then
      used = used - data[key].bytes
      data[key] = nil
      for i, have in ipairs(order) do
        if have == key then table.remove(order, i) break end
      end
    end
    while used + size > limit and order[1] do
      local drop = table.remove(order, 1)
      used = used - data[drop].bytes
      data[drop] = nil
    end
    data[key] = { value = copy(value), bytes = size }
    order[#order + 1] = key
    used = used + size
    return true
  end
  function api.get(key)
    local row = data[key]
    if not row then return nil end
    return copy(row.value)
  end
  function api.bytes() return used end
  return api
end

local function trim(text, width)
  text = tostring(text or "")
  if #text <= width then return text end
  return text:sub(1, width)
end

function M.open(context)
  context = context or {}
  local width = context.width or 39
  local lines = { "Craft", "Recipe index unavailable" }
  local pending = false
  local generation = context.generation or "hub:local"
  local service = {}

  local function publish(fragments, note)
    if context.publish then context.publish(fragments, note) end
    return fragments
  end

  function service.tick()
    if type(context.peripheral) ~= "table" then
      lines = { "Craft", "recipe_unavailable" }
      return { ok = false, code = "recipe_unavailable", error = "no recipe index" }
    end
    local query = pending
    if not query and context.fetch then query = context.fetch() end
    pending = false
    if not query then
      lines = { "Craft", "Idle" }
      return { ok = true, idle = true }
    end
    local method = context.peripheral[query.method or ""]
    if type(method) ~= "function" then
      return { ok = false, code = "recipe_unavailable", error = "missing method" }
    end
    local ok, value = pcall(method, query.id, query.page, query.pageSize)
    if not ok then
      return { ok = false, code = "recipe_unavailable", error = "provider failed" }
    end
    local size, text = bytes(value)
    if not size then return { ok = false, code = "invalid", error = "unreadable result" } end
    if size > M.limits.result then
      return { ok = false, code = "too_large", error = "result exceeds 65536" }
    end
    local fragments, offset = {}, 0
    while offset < #text do
      local part = text:sub(offset + 1, offset + M.limits.fragment)
      fragments[#fragments + 1] = {
        offset = offset, nextOffset = offset + #part, totalBytes = size,
        encoding = "lua", data = part, generation = generation,
      }
      offset = offset + #part
    end
    lines = { "Craft", trim(query.method or "query", width), trim(query.id or "", width) }
    return { ok = true, generation = generation, fragments = publish(fragments, query) }
  end

  function service.draw()
    local shown = {}
    for i = 1, math.min(13, #lines) do shown[i] = trim(lines[i], width) end
    if context.draw then context.draw(shown) end
    return shown
  end

  function service.handle(event)
    if type(event) ~= "table" then return false end
    if event.t == "text" and type(event.s) == "string" then
      pending = {
        method = event.method or "getRecipesFor", id = event.s,
        page = 1, pageSize = 20,
      }
      lines = { "Craft", "Lookup", trim(event.s, width) }
      return true
    end
    if event.t == "refresh" then
      lines = { "Craft", "Refresh" }
      return true
    end
    return false
  end

  return service
end

return M
