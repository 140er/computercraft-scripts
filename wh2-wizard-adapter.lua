local M = {}
local serial = 0

local function unavailable(message)
  return nil, message or "Authenticated wh2-client unavailable", "unavailable"
end

function M.open(context)
  context = context or {}
  local client = context.client
  local adapter = {}
  local query

  -- The host supplies its shared wh2-client. Its call method queues work.
  function adapter.call(op, body)
    if context.enabled ~= true then return nil, "Wizard disabled", "disabled" end
    if type(client) ~= "table" or type(client.call) ~= "function" then return unavailable() end
    body.wh2 = 1
    local ok, result, err, code = pcall(client.call, op, body)
    if not ok then return nil, tostring(result), "unavailable" end
    if type(result) ~= "table" then return nil, tostring(err or "No server reply"), code or "unavailable" end
    if result.ok ~= true then return nil, tostring(result.error or result.code or "Request failed"), result.code end
    return result
  end

  local function pages(topic)
    local cursor, revision, records, seen = 0, nil, {}, {}
    repeat
      if seen[cursor] then return nil, "Repeated page cursor", "invalid" end
      seen[cursor] = true
      local reply, err, code = adapter.call("wh2-get", { topic = topic, cursor = cursor, revision = revision })
      if not reply then return nil, err, code end
      if revision and revision ~= reply.revision then return nil, "List changed; refresh again", "stale_revision" end
      revision = reply.revision
      if type(reply.records) ~= "table" or type(reply.cursor) ~= "number" or reply.cursor < 0 or reply.cursor % 1 ~= 0
        or topic == "questions" and (type(revision) ~= "number" or revision < 0 or revision % 1 ~= 0)
        or topic == "classes" and (type(revision) ~= "string" or not revision:match("^%d+:%d+$")) then
        return nil, "Invalid list reply", "invalid"
      end
      for _, record in ipairs(reply.records) do
        if type(record) ~= "table" or type(record.item) ~= "string" then return nil, "Invalid item record", "invalid" end
        records[record.item] = record
      end
      cursor = reply.cursor
    until cursor == 0
    return { revision = revision, records = records }
  end

  function adapter.snapshot()
    local questions, err, code = pages("questions")
    if not questions then return nil, err, code end
    local classes
    classes, err, code = pages("classes")
    if not classes then return nil, err, code end
    local wizardRevision = type(classes.revision) == "string" and tonumber(classes.revision:match("^%d+:(%d+)$"))
    if wizardRevision ~= questions.revision then return nil, "Answers changed; refresh again", "stale_revision" end
    return { revision = questions.revision, questions = questions.records, classes = classes.records }
  end

  function adapter.answer(item, value, revision)
    return adapter.call("wh2-class", { item = item, value = value, baseRevision = revision })
  end

  local function release()
    if query and query.ticket then adapter.call("wh2-recipe", { action = "release", ticket = query.ticket }) end
    query = nil
  end
  adapter.close = release

  local function remote(method, id, page)
    if not query then
      serial = serial + 1
      local reply, err, code = adapter.call("wh2-recipe", {
        action = "query", key = "wizard:" .. tostring(context.computerId or os.getComputerID())
          .. ":" .. tostring(os.epoch and os.epoch("utc") or 0) .. ":" .. serial,
        method = method, id = id, page = page or 1, pageSize = 20,
      })
      if not reply then return nil, err, code end
      if type(reply.ticket) ~= "string" then return nil, "Invalid recipe ticket", "invalid" end
      query = { ticket = reply.ticket, offset = 0, data = "" }
      return nil, "Recipe lookup pending", "pending"
    end
    local reply, err, code = adapter.call("wh2-recipe", { action = "read", ticket = query.ticket })
    if not reply then release() return nil, err, code end
    if reply.pending then return nil, "Recipe lookup pending", "pending" end
    local f = reply.fragment or reply
    if type(f.data) ~= "string" or #f.data > 4096 or f.encoding ~= "lua"
      or type(f.generation) ~= "string" or f.offset ~= query.offset
      or type(f.totalBytes) ~= "number" or f.totalBytes < 0 or f.totalBytes > 65536
      or f.nextOffset ~= f.offset + #f.data or f.nextOffset > f.totalBytes
      or f.nextOffset <= f.offset or (query.generation and query.generation ~= f.generation)
      or (query.totalBytes and query.totalBytes ~= f.totalBytes) then
      release() return nil, "Invalid recipe fragment", "invalid"
    end
    query.data = query.data .. f.data
    query.generation, query.totalBytes, query.offset = f.generation, f.totalBytes, f.nextOffset
    if f.nextOffset == f.totalBytes then
      local ok, result = pcall(textutils.unserialize, query.data)
      release()
      if not ok or type(result) ~= "table" then return nil, "Invalid recipe result", "invalid" end
      return result
    end
    local advanced
    advanced, err, code = adapter.call("wh2-recipe", {
      action = "advance", ticket = query.ticket, generation = f.generation, nextOffset = f.nextOffset,
    })
    if not advanced then release() return nil, err, code end
    return nil, "Recipe lookup pending", "pending"
  end

  local provider, lookup
  local routes = { ["minecraft:smelting"] = "furnace", ["minecraft:blasting"] = "blast", ["minecraft:smoking"] = "smoker" }
  local function request(method, id, page)
    if provider then
      if type(provider[method]) ~= "function" then return nil, "Recipe provider unavailable", "recipe_unavailable" end
      local ok, result
      if method == "getRecipe" then ok, result = pcall(provider[method], id)
      else ok, result = pcall(provider[method], id, page or 1, 20) end
      if not ok or type(result) ~= "table" then return nil, "Recipe provider unavailable", "recipe_unavailable" end
      return result
    end
    return remote(method, id, page)
  end

  function adapter.suggestions(item)
    if not lookup or lookup.item ~= item then
      release()
      provider = context.recipeIndex
      if not provider and peripheral and peripheral.find then provider = peripheral.find("recipe_index") end
      lookup = { item = item, choices = {}, next = 1, page = 1 }
    end
    if not lookup.ids then
      local uses, err, code = request("getUsesOf", item, lookup.page)
      if not uses then return nil, err, code end
      local records = uses.recipes or uses
      lookup.pages = type(uses.pages) == "number" and uses.pages or 1
      if lookup.pages < 0 or lookup.pages % 1 ~= 0 then return nil, "Invalid recipe page", "invalid" end
      lookup.ids = {}
      for i, row in ipairs(records) do
        if i > 20 then break end
        local id = type(row) == "string" and row or type(row) == "table" and row.id
        if type(id) == "string" then lookup.ids[#lookup.ids + 1] = id end
      end
    end
    local id = lookup.ids[lookup.next]
    if #lookup.choices == 20 then
      lookup.choices.more = id ~= nil or lookup.page < lookup.pages
      return lookup.choices
    end
    if id then
      local result, err, code = request("getRecipe", id)
      if not result then return nil, err, code end
      local recipe = result.recipe or result
      local route = routes[recipe.type]
      if route and recipe.id == id and type(recipe.inputs) == "table" and type(recipe.outputs) == "table" then
        lookup.choices[#lookup.choices + 1] = { route = route, recipeId = id, label = route .. " " .. id }
      end
      lookup.next = lookup.next + 1
      return nil, "Recipe lookup pending", "pending"
    end
    if lookup.page < lookup.pages then
      lookup.page, lookup.next, lookup.ids = lookup.page + 1, 1, nil
      return nil, "Recipe lookup pending", "pending"
    end
    return lookup.choices
  end

  return adapter
end

return M
