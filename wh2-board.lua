local M = {}
local Adapter = require("wh2-wizard-adapter")
local categories = { "any", "ores", "ingots", "gems", "fuel", "misc" }

-- context.client is the host's shared wh2-client with queued call(op, body).
-- Hosts call handle on UI events and tick in a worker, outside their receiver.
function M.open(context)
  context = context or {}
  local api = Adapter.open(context)
  local board = {}
  local state = {
    queue = {}, selection = 1, skipped = {}, editSelection = 1,
    view = "queue", revision = false, classes = {}, draft = false,
    pending = "refresh", status = "Loading questions", failure = false, closed = false,
  }
  board.state = state
  local screens, editItems, choices = {}, {}, {}
  local recipeItem, recipePending = nil, false
  local now = context.now or function() return os.epoch and os.epoch("utc") or 0 end
  local nextRefresh = 0

  local function message(text, failed)
    state.status, state.failure = text, failed or false
  end

  local function selected()
    local list = state.view == "edit" and editItems or state.queue
    return list[state.view == "edit" and state.editSelection or state.selection]
  end

  local function rebuild(snapshot)
    state.classes, state.revision = snapshot.classes, snapshot.revision
    state.queue, editItems = {}, {}
    for item, q in pairs(snapshot.questions) do
      if q.state == "open" and not state.skipped[item] then state.queue[#state.queue + 1] = item end
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
    if state.revision == false then message("Refresh questions first", true) return end
    local row = state.classes[item]
    state.draft = {
      item = item, class = row and row.class or "misc", route = row and row.route or "store",
      storeCategory = row and row.storeCategory or "misc", recipeId = row and row.recipeId or false,
      baseRevision = state.revision, stale = false,
      suggest = row == nil,
    }
    state.returnView, state.view = state.view, "answer"
    recipeItem, recipePending, choices = item, true, {}
    state.recipeSelection = 1
    message("Looking for cooking recipes")
  end

  local function back()
    if state.view == "answer" then state.view, state.draft = state.returnView or "queue", false
    elseif state.view == "edit" then state.view = "queue"
    else state.closed = true end
  end

  local function save()
    if state.pending then return end
    if state.draft.stale then message("Stale edit. Back, then reopen.", true) return end
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
      state.draft.route, state.draft.recipeId = value.route, value.recipeId or false
      state.draft.suggest = false
    elseif name == "category" then
      local index = 1
      for i, category in ipairs(categories) do if category == state.draft.storeCategory then index = i end end
      state.draft.storeCategory = categories[index % #categories + 1]
      state.draft.class = state.draft.storeCategory
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
    if pending == "save" then
      local d = state.draft
      local result, err, code = api.answer(d.item, {
        class = d.class, route = d.route, storeCategory = d.storeCategory, recipeId = d.recipeId,
      }, d.baseRevision)
      state.pending = nil
      if not result then
        if code == "stale_revision" then d.stale = true end
        message(code == "stale_revision" and "Stale edit. Back, refresh." or err, true)
      else
        api.close()
        recipePending = false
        state.view, state.draft = state.returnView or "queue", false
        state.pending = "refresh"
        message("Answer saved")
      end
    elseif pending == "refresh" then
      nextRefresh = now() + 3000
      local result, err = api.snapshot()
      state.pending = nil
      if result then
        rebuild(result)
        if not (state.draft and state.draft.stale) then message("Questions refreshed") end
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
          draft.route, draft.recipeId = choices[1].route, choices[1].recipeId
          draft.suggest = false
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
      text(3, "Route " .. d.route)
      text(4, d.recipeId or "No cooking recipe")
      button(5, "c Category " .. d.storeCategory, "category")
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
      if a == keys.backspace or a == keys.escape then back()
      elseif a == keys.up or a == keys.down then
        local delta = a == keys.up and -1 or 1
        move(delta)
      elseif a == keys.enter then
        if state.view == "answer" then
          local choice = choices[state.recipeSelection or 1]
          if choice then action("route", choice) end
        else choose(selected()) end
      end
    elseif event == "mouse_scroll" then
      if state.pending ~= "save" then move(a) end
    elseif event == "char" then
      if state.pending == "save" then return true end
      if a == "q" then state.closed = true
      elseif a == "b" then back()
      elseif state.view == "answer" then
        local route = ({ ["1"] = "store", ["2"] = "fuel", ["3"] = "unknown" })[a]
        if route then action("route", { route = route })
        elseif a == "c" then action("category")
        elseif a == "n" then state.recipeSelection = (state.recipeSelection or 1) % math.max(1, #choices) + 1
        elseif a == "s" then save()
        elseif a == "r" then action("refresh") end
      elseif a == "r" then action("refresh")
      elseif a == "e" then action("edit")
      elseif a == "s" and state.view == "queue" then action("skip")
      elseif a == "k" then action("skipped") end
    end
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
