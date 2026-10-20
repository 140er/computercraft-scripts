local M = {}
local MAX_REV, MAX_TIME, LIMIT = 2147483647, 9007199254740991, 128
local categories = { any=true, ores=true, ingots=true, gems=true, fuel=true, misc=true }
local routes = { store=true, furnace=true, blast=true, smoker=true, fuel=true, unknown=true }
local classKeys = { item=true, class=true, route=true, storeCategory=true, recipeId=true,
  source=true, revision=true, updatedBy=true }
local questionKeys = { id=true, item=true, state=true, firstSeen=true, sampleLocationId=true }
local queryKeys = { wh2=true, topic=true, cursor=true, revision=true, id=true }
local answerKeys = { wh2=true, baseRevision=true, item=true, value=true }
local reportKeys = { wh2=true, item=true, sampleLocationId=true }

local function int(n, lo, hi)
  return type(n)=="number" and n==n and n%1==0 and n>=lo and n<=hi
end
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function word(v, limit)
  return type(v)=="string" and #v>0 and #v<=limit and not v:find("[%c]")
end
local function resource(v)
  return word(v,128) and v:match("^[a-z0-9_.-]+:[a-z0-9_/.-]+$")~=nil
end
local function shape(v, keys)
  if not plain(v) then return false end
  for k in pairs(v) do if not keys[k] then return false end end
  return true
end
local function tree(v)
  local seen, nodes = {}, 0
  local function visit(x, depth)
    nodes = nodes+1
    if depth>5 or nodes>10000 then return false end
    if type(x)=="table" then
      if not plain(x) or seen[x] then return false end
      seen[x] = true
      for k, value in pairs(x) do
        if type(k)~="string" or not visit(value,depth+1) then return false end
      end
      return true
    end
    return type(x)=="string" or type(x)=="boolean"
      or type(x)=="number" and x==x and math.abs(x)~=math.huge
  end
  return visit(v,0)
end
local function copy(v)
  if type(v)~="table" then return v end
  local out = {}
  for k,x in pairs(v) do out[k] = copy(x) end
  return out
end
local function count(v)
  local n = 0
  for _ in pairs(v) do n=n+1 end
  return n
end
local function classValue(v)
  return shape(v,classKeys) and categories[v.class]==true and routes[v.route]==true
    and categories[v.storeCategory]==true and (v.recipeId==false or resource(v.recipeId))
end
local function classRow(v, item, source, revision)
  return classValue(v) and v.item==item and v.source==source
    and int(v.revision,1,revision) and int(v.updatedBy,0,MAX_REV)
end
local function classMap(v, source, revision)
  if not plain(v) then return false end
  local n = 0
  for item,row in pairs(v) do
    n=n+1
    if n>LIMIT or not resource(item) or not classRow(row,item,source,revision) then return false end
  end
  return true
end

function M.valid(value, poseValidator)
  if value==nil then return true end
  if not tree(value) or not shape(value,{ revision=true, classes=true, questions=true })
    or not int(value.revision,0,MAX_REV)
    or not classMap(value.classes,"wizard",value.revision) or not plain(value.questions) then return false end
  local n = 0
  for item,q in pairs(value.questions) do
    n=n+1
    if n>LIMIT or not resource(item) or not shape(q,questionKeys)
      or q.item~=item or q.id~="item:"..item or not word(q.id,64)
      or (q.state~="open" and q.state~="resolved") or not int(q.firstSeen,0,MAX_TIME)
      or not (q.sampleLocationId==false or word(q.sampleLocationId,64))
      or q.state=="resolved" and (value.classes[item]==nil or value.classes[item].route=="unknown") then return false end
  end
  return true
end

local function fail(code, message)
  return { wh2=1, ok=false, code=code, error=message }
end
local function effective(wh2, wizard)
  local layout, rows, revision = wh2 and wh2.layout, {}, 0
  if layout~=nil then
    if not plain(layout) or not int(layout.revision,0,MAX_REV) then return nil end
    local defaults = layout.classDefaults
    if defaults~=nil then
      if not tree(defaults) or not classMap(defaults,"layout",layout.revision) then return nil end
      for item,row in pairs(defaults) do rows[item] = row end
    end
    revision = layout.revision
  end
  for item,row in pairs(wizard.classes) do rows[item] = row end
  return rows, string.format("%d:%d",revision,wizard.revision)
end
local function page(rows, revision, body)
  if body.revision~=nil and body.revision~=revision then
    return fail("stale_revision","The read revision changed. Restart at cursor 0.")
  end
  local ids = {}
  for id,row in pairs(rows) do
    if body.id==nil or body.id==id or body.id==row.id then ids[#ids+1]=id end
  end
  table.sort(ids)
  if body.cursor>#ids then return fail("invalid","The cursor exceeds the record count.") end
  local result = { wh2=1, ok=true, revision=revision, records={}, cursor=0 }
  for i=body.cursor+1,#ids do
    if #result.records==64 then result.cursor=i-1 break end
    result.records[#result.records+1] = copy(rows[ids[i]])
    result.cursor = i<#ids and i or 0
    if #textutils.serialize(result,{compact=true})>4096 then
      result.records[#result.records] = nil
      if #result.records==0 then return fail("too_large","The record exceeds the page budget.") end
      result.cursor = i-1
      break
    end
  end
  return result
end

-- SSOT supplies the paired, verified sender and owns replay, saving, and replies.
function M.run(s, senderId, message, context)
  if not plain(context) or not plain(context.config) or context.config.enabled~=true then
    return fail("disabled","Warehouse v2 is disabled.")
  end
  if not int(senderId,0,MAX_REV) then return fail("forbidden","A paired sender is required.") end
  if not plain(message) or not plain(message.body) or not tree(message.body)
    or message.body.wh2~=nil and message.body.wh2~=1 then
    return fail("invalid","A verified operation and body are required.")
  end
  if not plain(s) or s.wh2~=nil and (not plain(s.wh2) or s.wh2.schema~=1)
    or not M.valid(s.wh2 and s.wh2.wizard) then
    return fail("invalid","The saved wizard state is invalid.")
  end
  local body, op = message.body, message.op
  local wizard = s.wh2 and s.wh2.wizard or { revision=0, classes={}, questions={} }
  if op=="wh2-get" then
    if not shape(body,queryKeys) or (body.topic~="classes" and body.topic~="questions")
      or not int(body.cursor,0,LIMIT*2) or body.cursor>0 and body.revision==nil
      or body.id~=nil and not word(body.id,128) then
      return fail("invalid","Invalid wizard query.")
    end
    if body.topic=="questions" then
      if body.revision~=nil and not int(body.revision,0,MAX_REV) then
        return fail("invalid","Invalid question revision.")
      end
      return page(wizard.questions,wizard.revision,body)
    end
    if body.revision~=nil and (not word(body.revision,21)
      or not body.revision:match("^%d+:%d+$")) then return fail("invalid","Invalid class revision.") end
    local rows, revision = effective(s.wh2,wizard)
    if not rows then return fail("invalid","The layout class defaults are invalid.") end
    return page(rows,revision,body)
  end
  if op~="wh2-class" and op~="wh2-unknown" then return fail("invalid","Unknown wizard operation.") end
  if op=="wh2-class" then
    local operators = context.config.operators
    if not plain(operators) or operators[tostring(senderId)]~=true then
      return fail("forbidden","Only a configured operator can answer questions.")
    end
    if not shape(body,answerKeys) or not resource(body.item) or not int(body.baseRevision,0,MAX_REV)
      or not classValue(body.value) or body.value.item~=nil and body.value.item~=body.item
      or body.value.source~=nil and body.value.source~="wizard" and body.value.source~="layout"
      or body.value.revision~=nil and not int(body.value.revision,0,MAX_REV)
      or body.value.updatedBy~=nil and not int(body.value.updatedBy,0,MAX_REV) then
      return fail("invalid","Invalid class answer.")
    end
    if body.baseRevision~=wizard.revision then return fail("stale_revision","The wizard revision changed.") end
    if not wizard.classes[body.item] and count(wizard.classes)>=LIMIT then
      return fail("capacity","The wizard class limit is 128. No answer was removed.")
    end
  else
    if not shape(body,reportKeys) or not resource(body.item)
      or not (body.sampleLocationId==false or word(body.sampleLocationId,64)) then
      return fail("invalid","Invalid unknown item report.")
    end
    if not word("item:"..body.item,64) then return fail("too_large","The question ID exceeds 64 bytes.") end
    if wizard.questions[body.item] then
      return { wh2=1, ok=true, revision=wizard.revision, question=copy(wizard.questions[body.item]) }
    end
    if count(wizard.questions)>=LIMIT then
      return fail("capacity","The wizard question limit is 128. No question was removed.")
    end
    if not int(context.now,0,MAX_TIME) then return fail("invalid","A server timestamp is required.") end
  end
  if wizard.revision==MAX_REV then return fail("capacity","The wizard revision is exhausted.") end
  local candidate = copy(wizard)
  candidate.revision = wizard.revision+1
  if op=="wh2-class" then
    local value = body.value
    candidate.classes[body.item] = { item=body.item, class=value.class, route=value.route,
      storeCategory=value.storeCategory, recipeId=value.recipeId, source="wizard",
      revision=candidate.revision, updatedBy=senderId }
    if candidate.questions[body.item] then
      candidate.questions[body.item].state=value.route=="unknown" and "open" or "resolved"
    end
  else
    candidate.questions[body.item] = { id="item:"..body.item, item=body.item,
      state=candidate.classes[body.item] and candidate.classes[body.item].route~="unknown" and "resolved" or "open",
      firstSeen=context.now, sampleLocationId=body.sampleLocationId }
  end
  if not M.valid(candidate) then return fail("invalid","The resulting wizard state is invalid.") end
  if s.wh2==nil then s.wh2={schema=1} end
  s.wh2.wizard = candidate
  local result = { wh2=1, ok=true, revision=candidate.revision,
    question=copy(candidate.questions[body.item]) or false }
  if op=="wh2-class" then result.class=copy(candidate.classes[body.item]) end
  return result
end

return M
