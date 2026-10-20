local M = {}
local Adapter = require("wh2-wizard-adapter")
local Wizard = require("wh2-wizard")
local Atomic = require("atomic")
local categories = { "any", "ores", "ingots", "gems", "fuel", "misc" }
local function copy(value)
  if type(value)~="table" then return value end
  local result={}
  for key,entry in pairs(value) do result[key]=copy(entry) end
  return result
end
local function validCache(value)
  if type(value)~="table" or value.v~=1 then return false end
  local d=value.draft
  if d==false then return true end
  return type(d)=="table" and type(d.item)=="string" and #d.item<=128
    and type(d.baseRevision)=="number" and d.baseRevision%1==0 and d.baseRevision>=0 and d.baseRevision<=2147483647
    and type(d.questionRevision)=="number" and d.questionRevision%1==0 and d.questionRevision>=0 and d.questionRevision<=2147483647
    and (d.questionId==false or d.questionId=="item:"..d.item)
    and type(d.dirty)=="boolean" and Wizard.validDraft(d.value,true)
end

-- context.client is the host's shared wh2-client with queued call(op, body).
-- Hosts call handle on UI events and tick in a worker, outside their receiver.
function M.open(context)
  context = context or {}
  local api = Adapter.open(context)
  local computerId=context.computerId or os.getComputerID()
  local cache,cacheFailure
  if context.enabled==true then
    if context.cache then cache=context.cache
    else
      local ok,result=pcall(Atomic.store,"wh2-wizard.cache",validCache,8192)
      if ok then cache=result else cacheFailure="Cannot read wizard cache" end
    end
  end
  local board = {}
  local state = {
    queue = {}, selection = 1, skipped = {}, editSelection = 1,
    view = "queue", revision = false, classes = {}, questions={}, draft = false,
    pending = "refresh", status = "Loading questions", failure = false, closed = false,
  }
  board.state = state
  local screens, editItems, choices = {}, {}, {}
  local recipeItem, recipePending = nil, false
  local now = context.now or function() return os.epoch and os.epoch("utc") or 0 end
  local nextRefresh = 0
  local localDraft=cache and cache.value and copy(cache.value.draft) or false

  local function message(text, failed)
    state.status, state.failure = text, failed or false
  end

  local function persist(d)
    if not cache then message(cacheFailure or "Wizard cache unavailable",true) return false end
    local value={v=1,draft=d and {
      item=d.item,baseRevision=d.baseRevision,questionId=d.questionId or false,
      questionRevision=d.questionRevision or 0,dirty=d.dirty==true,
      value={v=1,editor=computerId,revision=d.draftRevision or 0,updatedAt=now(),
        step=d.step or "class",answers={class=d.class,route=d.route,storeCategory=d.storeCategory,recipeId=d.recipeId},text=d.text or ""},
    } or false}
    if not validCache(value) then message("Invalid or oversized draft",true) return false end
    local ok,saved=pcall(cache.save,value)
    if not ok or saved~=true then message("Cannot save wizard cache",true) return false end
    localDraft=copy(value.draft)
    return true
  end

  local function change(fields)
    local d=copy(state.draft)
    if not d or d.stale or d.foreign then message("Take over this draft first",true) return false end
    for key,value in pairs(fields) do d[key]=value end
    d.dirty=true
    if not persist(d) then return false end
    state.draft=d
    return true
  end

  local function selected()
    local list = state.view == "edit" and editItems or state.queue
    return list[state.view == "edit" and state.editSelection or state.selection]
  end

  local function rebuild(snapshot)
    state.classes, state.questions, state.revision = snapshot.classes, snapshot.questions, snapshot.revision
    state.queue, editItems = {}, {}
    for item, q in pairs(snapshot.questions) do
      if (q.state == "open" or q.state=="answering") and not state.skipped[item] then state.queue[#state.queue + 1] = item end
    end
    for item in pairs(snapshot.classes) do editItems[#editItems + 1] = item end
    table.sort(state.queue)
    table.sort(editItems)
    state.selection = math.max(1, math.min(state.selection, #state.queue))
    state.editSelection = math.max(1, math.min(state.editSelection, #editItems))
    if state.draft and state.draft.baseRevision ~= state.revision then
      state.draft.stale = true
      message("Stale edit. Back, then reopen.", true)
    end
  end

  local function choose(item)
    if not item then return end
    if localDraft and localDraft.item~=item and localDraft.dirty then
      message("Save or discard the current draft first",true) return
    end
    if state.revision == false then message("Refresh questions first", true) return end
    local row = state.classes[item]
    local q=state.questions[item]
    if localDraft and localDraft.item==item and q and q.state=="resolved" and row then
      local value=localDraft.value.answers
      if row.class==value.class and row.route==value.route and row.storeCategory==value.storeCategory
        and row.recipeId==value.recipeId then
        if persist(false) then state.draft=false message("Answer already saved") end
        return
      end
    end
    local saved=q and q.state=="answering" and q.draft
    local d = {
      item = item, class = row and row.class or "misc", route = row and row.route or "store",
      storeCategory = row and row.storeCategory or "misc", recipeId = row and row.recipeId or false,
      baseRevision = state.revision, stale = false,
      suggest = row == nil and not saved, questionId=q and q.state~="resolved" and q.id or nil,
      questionRevision=q and q.revision or 0,draftRevision=saved and saved.revision or 0,
      step=saved and saved.step or "class",text=saved and saved.text or "",dirty=not saved,
      foreign=saved and saved.editor~=computerId or false,
    }
    if saved then for key,value in pairs(saved.answers) do d[key]=value end end
    if localDraft and localDraft.item==item then
      local localValue=localDraft.value
      local same=saved and saved.editor==computerId and saved.step==localValue.step
        and saved.text==localValue.text
        and textutils.serialize(saved.answers,{compact=true})==textutils.serialize(localValue.answers,{compact=true})
      local unchanged=q and q.revision==localDraft.questionRevision and d.draftRevision==localValue.revision
      if same then
        d.dirty=false
      elseif unchanged or not q and localDraft.questionId==false then
        for key,value in pairs(localValue.answers) do d[key]=value end
        d.step,d.text,d.dirty=localValue.step,localValue.text,localDraft.dirty
      else
        for key,value in pairs(localValue.answers) do d[key]=value end
        d.step,d.text,d.stale=localValue.step,localValue.text,true
      end
    end
    if not d.foreign and not d.stale and not persist(d) then return end
    state.draft=d
    state.returnView, state.view = state.view, "answer"
    recipeItem, recipePending, choices = item, true, {}
    state.recipeSelection = 1
    message(d.stale and "Local conflict. t Keep local edit" or d.foreign and "Draft by another operator. t Take over" or "Looking for cooking recipes",d.stale or d.foreign)
  end

  local function back()
    if state.view == "answer" then state.view = state.returnView or "queue"
    elseif state.view == "edit" then state.view = "queue"
    else state.closed = true end
  end

  local function save()
    if state.pending then return end
    if state.draft.stale or state.draft.foreign then message("Take over this draft first", true) return end
    state.pending = "save"
    message("Saving answer")
  end

  local function action(name, value)
    if name == "back" then back()
    elseif name == "refresh" then
      if not state.pending then state.pending = "refresh" message("Refreshing questions") end
    elseif name == "edit" then state.view = "edit"
    elseif name == "skipped" then state.skipped = {} state.pending = "refresh"
    elseif name == "choose" then choose(value or selected())
    elseif name == "skip" then
      local item = selected()
      if item then state.skipped[item] = true table.remove(state.queue, state.selection) end
      state.selection = math.max(1, math.min(state.selection, #state.queue))
    elseif name == "route" then
      change({route=value.route,recipeId=value.recipeId or false,suggest=false,step="review"})
    elseif name == "category" or name=="class" then
      local field=name=="class" and "class" or "storeCategory"
      local index = 1
      for i, category in ipairs(categories) do if category == state.draft[field] then index = i end end
      local category=categories[index % #categories + 1]
      change({[field]=category,step=name})
    elseif name=="discard" then
      if state.draft.questionId and not state.draft.stale and not state.draft.foreign then
        state.pending="discard"
      elseif not state.draft.questionId and persist(false) then back() end
    elseif name=="takeover" then
      state.pending="takeover"
    elseif name == "save" then save() end
  end

  local function move(delta)
    if state.view == "answer" then state.recipeSelection = math.max(1, math.min(#choices, (state.recipeSelection or 1) + delta))
    elseif state.view == "edit" then state.editSelection = math.max(1, math.min(#editItems, state.editSelection + delta))
    else state.selection = math.max(1, math.min(#state.queue, state.selection + delta)) end
  end

  function board.tick()
    if state.closed then api.close() return end
    if not state.pending and state.view ~= "answer" and not recipePending and now() >= nextRefresh then
      state.pending = "refresh"
    end
    local pending = state.pending
    if pending=="takeover" then
      local snapshot,err=api.snapshot()
      state.pending=nil
      if not snapshot then message(err,true) return end
      local d=state.draft
      local q=snapshot.questions[d.item]
      if not q or q.state=="resolved" then message("Question changed. Back, refresh.",true) return end
      state.revision,state.questions,state.classes=snapshot.revision,snapshot.questions,snapshot.classes
      local next=copy(d)
      next.baseRevision,next.questionRevision,next.draftRevision=snapshot.revision,q.revision,q.draft and q.draft.revision or 0
      next.stale,next.foreign,next.dirty=false,false,true
      if persist(next) then state.draft=next message("Draft taken over") end
    end
    local d=state.draft
    if d and d.dirty and d.questionId and not d.stale and not d.foreign and pending~="discard" then
      state.busy=true
      local result,err,code=api.draft(d.item,{v=1,editor=computerId,revision=d.draftRevision,
        updatedAt=now(),step=d.step,answers={class=d.class,route=d.route,storeCategory=d.storeCategory,recipeId=d.recipeId},text=d.text},
        d.baseRevision,d.questionId,d.draftRevision)
      state.busy=false
      if not result then
        if code=="stale_revision" then d.stale=true end
        state.pending=nil
        message(code=="stale_revision" and "Stale edit. t Keep local edit" or err,true)
        return
      end
      if not Wizard.validQuestion(result.question,result.revision) or result.question.state~="answering"
        or result.question.draft.editor~=computerId then message("Invalid saved draft",true) state.pending=nil return end
      d.baseRevision,d.questionRevision,d.draftRevision,d.dirty=result.revision,result.question.revision,result.question.draft.revision,false
      state.revision,state.questions[d.item]=result.revision,result.question
      if not persist(d) then state.pending=nil return end
    end
    if pending == "save" then
      local d = state.draft
      local result, err, code = api.answer(d.item, {
        class = d.class, route = d.route, storeCategory = d.storeCategory, recipeId = d.recipeId,
      }, d.baseRevision,d.questionId,d.questionId and d.draftRevision or nil)
      state.pending = nil
      if not result then
        if code == "stale_revision" then d.stale = true end
        message(code == "stale_revision" and "Stale edit. Back, refresh." or err, true)
      else
        if not persist(false) then d.stale=true return end
        api.close()
        recipePending = false
        state.view, state.draft = state.returnView or "queue", false
        state.pending = "refresh"
        message("Answer saved")
      end
    elseif pending=="discard" then
      local result,err,code=api.discard(d.item,d.baseRevision,d.questionId,d.draftRevision)
      state.pending=nil
      if not result then
        if code=="stale_revision" then d.stale=true end
        message(err,true)
      elseif persist(false) then
        state.view,state.draft=state.returnView or "queue",false
        state.pending="refresh"
        message("Draft discarded")
      end
    elseif pending == "refresh" then
      nextRefresh = now() + 3000
      local result, err = api.snapshot()
      state.pending = nil
      if result then
        message("Questions refreshed")
        rebuild(result)
        if localDraft and state.view=="queue" then choose(localDraft.item)
        elseif not state.draft and state.view=="queue" then
          for _,item in ipairs(state.queue) do
            local q=state.questions[item]
            if q.draft and q.draft.editor==computerId then choose(item) break end
          end
        end
      else message(err, true) end
    elseif recipePending and state.view ~= "answer" then
      api.close()
      recipePending = false
    elseif recipePending and state.view == "answer" then
      local draft = state.draft
      local result, err, code = api.suggestions(recipeItem)
      if state.draft ~= draft then return end
      if result then
        choices, recipePending = result, false
        if draft.suggest and choices[1] then
          change({route=choices[1].route,recipeId=choices[1].recipeId,suggest=false,step="recipe"})
        end
        if not state.failure then
          message(choices.more and "Showing 20 cooking recipes" or (#choices > 0 and "Choose a route" or "No cooking recipes"))
        end
      elseif code ~= "pending" then
        recipePending = false
        if not state.failure then message(err or "Recipe lookup unavailable", true) end
      end
    end
  end

  function board.draw(target, screenName)
    target = target or context.term or term.current()
    screenName = screenName or context.monitorName or "term"
    local w, h = target.getSize()
    local buttons = {}
    screens[screenName] = buttons
    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
    target.clear()
    if target.setCursorBlink then target.setCursorBlink(false) end
    local function text(y, value, color)
      if y < 1 or y > h then return end
      target.setCursorPos(1, y)
      target.setTextColor(color or colors.white)
      target.write(tostring(value):sub(1, w))
    end
    local function button(y, label, name, value, x1, x2)
      if y < 2 or y > h - 3 then return end
      text(y, label, colors.lightBlue)
      buttons[#buttons + 1] = { y = y, name = name, value = value, x1 = x1 or 1, x2 = x2 or w }
    end
    text(1, "Material wizard", colors.yellow)
    if w < 26 or h < 16 then
      text(3, "Needs at least 26 x 16")
    elseif state.view == "answer" then
      local d = state.draft
      text(2, d.item)
      text(3, "Route " .. d.route .. " / " .. d.step)
      text(4, d.text~="" and d.text or d.recipeId or "No cooking recipe")
      button(5, "a Class " .. d.class .. "  c " .. d.storeCategory, "class",nil,1,math.floor(w/2))
      buttons[#buttons+1]={y=5,name="category",x1=math.floor(w/2)+1,x2=w}
      button(6, "1 Store", "route", { route = "store" })
      button(7, "2 Fuel", "route", { route = "fuel" })
      button(8, "3 Keep unknown", "route", { route = "unknown" })
      local rows = math.max(1, h - 14)
      local start = math.max(1, state.recipeSelection or 1)
      for i = start, math.min(#choices, start + rows - 1) do
        local c = choices[i]
        button(9 + i - start, (i == start and "> " or "  ") .. c.label, "route", c)
      end
      if #choices == 0 then text(9, recipePending and "Recipes pending" or "No cooking suggestions", colors.gray) end
      button(h - 5, "n Next cooking recipe", "nextRecipe")
      button(h - 4, "s Save answer", "save")
      button(h - 3, (d.foreign or d.stale) and "t Keep local edit" or "x Discard draft",(d.foreign or d.stale) and "takeover" or "discard")
    else
      local edit = state.view == "edit"
      local list = edit and editItems or state.queue
      local index = edit and state.editSelection or state.selection
      text(2, (edit and "Prior answers " or "Questions ") .. #list)
      local rows = h - 11
      local start = math.max(1, index - rows + 1)
      for i = start, math.min(#list, start + rows - 1) do
        button(3 + i - start, (i == index and "> " or "  ") .. list[i], "choose", list[i])
      end
      if #list == 0 then text(3, edit and "No prior answers" or "No open questions", colors.gray) end
      button(h - 8, "< Prev       Next >", "previous", nil, 1, math.floor(w / 2))
      buttons[#buttons + 1] = { y = h - 8, name = "next", x1 = math.floor(w / 2) + 1, x2 = w }
      if not edit then
        button(h - 7, "s Skip selected", "skip")
        button(h - 6, "e Change prior answer", "edit")
        button(h - 5, "k Show skipped", "skipped")
      end
      button(h - 4, "r Refresh", "refresh")
    end
    text(h - 2, state.status, state.failure and colors.red or colors.lime)
    -- A second status line keeps failures readable on a pocket screen.
    text(h - 1, tostring(state.status):sub(w + 1, w * 2), state.failure and colors.red or colors.lime)
    text(h, "b Back    q Close", colors.lightBlue)
    buttons[#buttons + 1] = { y = h, name = "back", x1 = 1, x2 = 9 }
    buttons[#buttons + 1] = { y = h, name = "close", x1 = 10, x2 = w }
  end

  function board.handle(event, a, b, c)
    if state.closed then return false end
    if state.busy or state.pending=="save" or state.pending=="discard" or state.pending=="takeover" then return true end
    if event == "mouse_click" or event == "monitor_touch" then
      if event == "mouse_click" and a ~= 1 then return true end
      local name = event == "monitor_touch" and a or "term"
      for _, button in ipairs(screens[name] or {}) do
        if c == button.y and b >= button.x1 and b <= button.x2 then
          if state.pending == "save" then return true end
          if button.name == "next" then move(1)
          elseif button.name == "previous" then move(-1)
          elseif button.name == "nextRecipe" then state.recipeSelection = (state.recipeSelection or 1) % math.max(1, #choices) + 1
          elseif button.name == "close" then state.closed = true
          else action(button.name, button.value) end
          return true
        end
      end
    elseif event == "key" then
      if state.pending == "save" then return true end
      if (a == keys.backspace or a == keys.delete) and state.view=="answer" and state.textEditing then
        change({text=state.draft.text:sub(1,-2)})
      elseif a==keys.escape and state.textEditing then state.textEditing=false
      elseif a == keys.backspace or a == keys.escape then back()
      elseif a == keys.up or a == keys.down then
        local delta = a == keys.up and -1 or 1
        move(delta)
      elseif a == keys.enter then
        if state.view == "answer" and state.textEditing then state.textEditing=false change({step="review"})
        elseif state.view == "answer" then
          local choice = choices[state.recipeSelection or 1]
          if choice then action("route", choice) end
        else choose(selected()) end
      end
    elseif event == "mouse_scroll" then
      if state.pending ~= "save" then move(a) end
    elseif event == "char" then
      if state.pending == "save" then return true end
      if state.view=="answer" and state.textEditing then change({text=state.draft.text..a})
      elseif a == "q" then state.closed = true
      elseif a == "b" then back()
      elseif state.view == "answer" then
        local route = ({ ["1"] = "store", ["2"] = "fuel", ["3"] = "unknown" })[a]
        if route then action("route", { route = route })
        elseif a=="a" then action("class")
        elseif a == "c" then action("category")
        elseif a == "n" then state.recipeSelection = (state.recipeSelection or 1) % math.max(1, #choices) + 1
        elseif a == "s" then save()
        elseif a == "x" then action("discard")
        elseif a == "t" then action("takeover")
        elseif a == "/" then if change({step="recipe"}) then state.textEditing=true message("Type text. Enter finishes") end
        elseif a == "r" then action("refresh") end
      elseif a == "r" then action("refresh")
      elseif a == "e" then action("edit")
      elseif a == "s" and state.view == "queue" then action("skip")
      elseif a == "k" then action("skipped") end
    end
    if event=="paste" and state.view=="answer" then change({text=(state.draft.text or "")..a,step="recipe"}) end
    return true
  end

  function board.close() state.closed = true api.close() end
  return board
end

function M.run(context)
  context = context or {}
  local board = M.open(context)
  local function ui()
    while not board.state.closed do
      board.draw()
      board.handle(os.pullEvent())
    end
  end
  local function worker()
    while not board.state.closed do board.tick() os.queueEvent("wh2_board_draw") sleep(0.25) end
  end
  parallel.waitForAny(ui, worker)
  board.close()
  return board.state
end

return M
