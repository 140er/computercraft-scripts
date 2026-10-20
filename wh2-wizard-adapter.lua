local M = {}
local Wizard = require("wh2-wizard")
local serial = 0
local function int(value, min, max)
  return type(value)=="number" and value==value and value%1==0 and value>=min and value<=max
end
local function resource(value)
  return type(value)=="string" and #value<=128 and value:match("^[a-z0-9_.-]+:[a-z0-9_/.-]+$")~=nil
end
local function dense(value, limit)
  if type(value)~="table" or getmetatable(value) then return false end
  local count=0
  for key in pairs(value) do
    count=count+1
    if not int(key,1,limit) then return false end
  end
  return count==#value and count<=limit
end

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
    local request={}
    for key,value in pairs(body) do request[key]=value end
    request.wh2 = 1
    local ok, result, err, code = pcall(client.call, op, request)
    if not ok then return unavailable() end
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
      local layoutRevision,wizardRevision
      if topic=="classes" and type(revision)=="string" then
        layoutRevision,wizardRevision=revision:match("^(%d+):(%d+)$")
      end
      if not dense(reply.records,64) or not int(reply.cursor,0,256)
        or topic == "questions" and not int(revision,0,2147483647)
        or topic == "classes" and (type(revision) ~= "string" or #revision>21
          or not int(tonumber(layoutRevision),0,2147483647) or not int(tonumber(wizardRevision),0,2147483647)
          or revision~=string.format("%d:%d",tonumber(layoutRevision),tonumber(wizardRevision)))
        or reply.cursor~=0 and (reply.cursor<=cursor or #reply.records==0) then
        return nil, "Invalid list reply", "invalid"
      end
      for _, record in ipairs(reply.records) do
        if type(record) ~= "table" or records[record.item]
          or topic=="questions" and not Wizard.validQuestion(record,revision)
          or topic=="classes" and not Wizard.validClass(record) then return nil, "Invalid item record", "invalid" end
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

  function adapter.answer(item, value, revision, questionId, draftRevision)
    return adapter.call("wh2-class", { action=questionId and "resolve" or "set", item=item,
      value=value, baseRevision=revision, questionId=questionId, draftRevision=draftRevision })
  end

  function adapter.draft(item, draft, revision, questionId, draftRevision)
    return adapter.call("wh2-class", { action="draft", item=item, draft=draft,
      baseRevision=revision, questionId=questionId, draftRevision=draftRevision })
  end

  function adapter.discard(item, revision, questionId, draftRevision)
    return adapter.call("wh2-class", { action="discard", item=item,
      baseRevision=revision, questionId=questionId, draftRevision=draftRevision })
  end

  local function release()
    if query and query.ticket then adapter.call("wh2-recipe", { action = "release", ticket = query.ticket }) end
    query = nil
  end
  adapter.close = release

  local function remote(method, id, page)
    if query and (query.method~=method or query.id~=id or query.page~=(page or 1)) then release() end
    if not query then
      serial = serial + 1
      local reply, err, code = adapter.call("wh2-recipe", {
        action = "query", key = "wizard:" .. tostring(context.computerId or os.getComputerID())
          .. ":" .. tostring(os.epoch and os.epoch("utc") or 0) .. ":" .. serial,
        method = method, id = id, page = page or 1, pageSize = 20,
      })
      if not reply then return nil, err, code end
      if type(reply.ticket) ~= "string" or #reply.ticket==0 or #reply.ticket>64 then return nil, "Invalid recipe ticket", "invalid" end
      query = { ticket = reply.ticket, method=method, id=id, page=page or 1, offset = 0, data = "" }
      return nil, "Recipe lookup pending", "pending"
    end
    local reply, err, code = adapter.call("wh2-recipe", { action = "read", ticket = query.ticket })
    if not reply then release() return nil, err, code end
    if reply.pending~=nil and type(reply.pending)~="boolean" then release() return nil,"Invalid recipe reply","invalid" end
    if reply.pending then return nil, "Recipe lookup pending", "pending" end
    local f = reply.fragment or reply
    if type(f.data) ~= "string" or #f.data > 4096 or f.encoding ~= "lua"
      or type(f.generation) ~= "string" or #f.generation==0 or #f.generation>64 or f.offset ~= query.offset
      or not int(f.totalBytes,1,65536) or not int(f.offset,0,65536) or not int(f.nextOffset,1,65536)
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
      if type(provider)~="table" or type(provider[method]) ~= "function" then return nil, "Recipe provider unavailable", "recipe_unavailable" end
      local ok, result
      if method == "getRecipe" or method=="resolveTag" then ok, result = pcall(provider[method], id)
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
      lookup = { item = item, choices = {}, next = 1, page = 1, seen={} }
    end
    if not lookup.ids then
      local uses, err, code = request("getUsesOf", item, lookup.page)
      if not uses then return nil, err, code end
      local records = uses.recipes
      lookup.pages = uses.pages==nil and 1 or uses.pages
      if not dense(records,20) or not int(lookup.pages,0,100000)
        or uses.page~=nil and uses.page~=lookup.page then return nil, "Invalid recipe page", "invalid" end
      lookup.ids = {}
      for i, row in ipairs(records) do
        if i > 20 then break end
        local id = type(row) == "string" and row or type(row) == "table" and row.id
        if not resource(id) then return nil, "Invalid recipe ID", "invalid" end
        if not lookup.seen[id] then lookup.ids[#lookup.ids + 1] = id lookup.seen[id]=true end
      end
    end
    local id = lookup.ids[lookup.next]
    if #lookup.choices == 20 then
      lookup.choices.more = id ~= nil or lookup.page < lookup.pages
      return lookup.choices
    end
    if id then
      if not lookup.recipe then
        local result, err, code = request("getRecipe", id)
        if not result then return nil, err, code end
        lookup.recipe=result.recipe or result
      end
      local recipe = lookup.recipe
      local route = routes[recipe.type]
      local valid = recipe.id==id and dense(recipe.inputs,64) and dense(recipe.outputs,64)
        and (recipe.time==nil or int(recipe.time,1,2147483647))
      local accepts, produces = false, false
      if route and valid then
        for _,input in ipairs(recipe.inputs) do
          if type(input)~="table" or not int(input.count,1,2147483647) then valid=false break end
          local kinds=(input.item~=nil and 1 or 0)+(input.tag~=nil and 1 or 0)+(input.items~=nil and 1 or 0)
          if kinds~=1 or input.item~=nil and not resource(input.item) or input.tag~=nil and not resource(input.tag)
            or input.items~=nil and (not dense(input.items,16) or #input.items==0) then valid=false break end
          if input.item==item then accepts=true end
          if input.items then
            for _,option in ipairs(input.items) do
              if not resource(option) then valid=false break end
              if option==item then accepts=true end
            end
            if input.more==true then accepts=true end
          end
          if input.tag then
            local members,err,code=request("resolveTag",input.tag)
            if not members then return nil,err,code end
            if not dense(members,100000) then valid=false break end
            for _,member in ipairs(members) do
              if not resource(member) then valid=false break end
              if member==item then accepts=true end
            end
          end
        end
        for _,output in ipairs(recipe.outputs) do
          if type(output)~="table" or not resource(output.item) or not int(output.count,1,2147483647)
            or type(output.chance)~="number" or output.chance~=output.chance
            or output.chance<=0 or output.chance>1 then valid=false break end
          if output.chance==1 then produces=true end
        end
      end
      if route and valid and accepts and produces and #recipe.inputs==1 and recipe.fluids==nil and recipe.steps==nil then
        lookup.choices[#lookup.choices + 1] = { route = route, recipeId = id, label = route .. " " .. id }
      end
      lookup.next = lookup.next + 1
      lookup.recipe=nil
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
