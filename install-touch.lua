-- Touch view for the install state machine. Buttons only: a click returns
-- the same event the keyboard view would. No install decisions here.
-- On only when settings install.touch is true, and the machine has a pointer
-- (advanced computer, turtle, pocket, or an attached advanced monitor).

local Core = dofile("install-core.lua")
local M = {}

local function clip(text, n)
  text = tostring(text or ""):gsub("[\r\n]", " ")
  if #text <= n then return text end
  return text:sub(1, n)
end

local function wrap(text, width)
  local lines = {}
  local line = ""
  for word in tostring(text or ""):gmatch("%S+") do
    while #word > width do
      if line ~= "" then lines[#lines + 1] = line line = "" end
      lines[#lines + 1] = word:sub(1, width)
      word = word:sub(width + 1)
    end
    if line == "" then line = word
    elseif #line + 1 + #word <= width then line = line .. " " .. word
    else lines[#lines + 1] = line line = word end
  end
  if line ~= "" or #lines == 0 then lines[#lines + 1] = line end
  return lines
end

local function title(state)
  if state.step == "source" then return "What do you have?" end
  if state.step == "enter_code" then return "Type the copy code" end
  if state.step == "neighbour" then return "Which neighbour?" end
  if state.step == "role" then return "What should this be?" end
  if state.step == "position" then
    local phase = state.draft and state.draft.phase
    if phase == "x" then return "F3 position, X" end
    if phase == "y" then return "F3 position, Y" end
    if phase == "z" then return "F3 position, Z" end
    return "Where is this machine?"
  end
  if state.step == "facing" then return "Which way does it face?" end
  if state.step == "review" then
    local pos = state.pos or {}
    return (state.role or "?") .. " " .. tostring(pos.x) .. "," .. tostring(pos.y) .. "," .. tostring(pos.z)
  end
  if state.step == "error" then return "Something went wrong" end
  if state.step == "fetch" then return "Copying files" end
  if state.step == "pair" then return "Saving" end
  if state.step == "done" then return "Installed" end
  return "Installer"
end

local function typing(state)
  if state.step == "enter_code" then return true end
  local phase = state.draft and state.draft.phase
  return state.step == "position" and (phase == "x" or phase == "y" or phase == "z")
end

local function markOf(state)
  local phase = state.draft and state.draft.phase or ""
  return tostring(state.step) .. "\0" .. tostring(phase)
end

local function sync(ui, state)
  local mark = markOf(state)
  if ui.mark ~= mark then
    ui.mark = mark
    ui.buffer = ""
    ui.first = 1
    ui.focus = 1
  end
end

function M.new(width, height)
  return {
    width = width or 39, height = height or 13,
    buffer = "", first = 1, focus = 1, buttons = {},
  }
end

local function pad(text, width)
  text = clip(text, width)
  if #text < width then text = text .. string.rep(" ", width - #text) end
  return text
end

local function header(state, ui, width, height)
  local lines = { clip(title(state), width) }
  if state.step == "error" then
    local err = state.error or {}
    local detail = err.detail
    if detail == nil or detail == "" then detail = tostring(err.code or "error") end
    if state.draft and state.draft.help then
      detail = detail .. " Retry tries this step again. Back returns to the previous step."
    end
    local wrapped = wrap(tostring(err.code or "error") .. ": " .. detail, width)
    local cap = math.max(1, height - 5)
    for i = 1, math.min(#wrapped, cap) do lines[#lines + 1] = wrapped[i] end
  elseif typing(state) then
    local note = state.draft and state.draft.note
    if type(note) == "string" and note ~= "" then lines[#lines + 1] = clip(note, width) end
    lines[#lines + 1] = clip("> " .. (ui.buffer or ""), width)
  end
  return lines
end

local function activate(ui, button)
  if button.kind == "choose" then return { t = "choose", n = button.n } end
  if button.kind == "back" then return { t = "back" } end
  if button.kind == "done" then
    local text = ui.buffer or ""
    ui.buffer = ""
    return { t = "text", s = text }
  end
  if button.kind == "backspace" then
    if #(ui.buffer or "") > 0 then
      ui.buffer = ui.buffer:sub(1, -2)
      return nil
    end
    return { t = "back" }
  end
  if button.kind == "more" or button.kind == "prev" then
    ui.first = button.next or 1
    ui.focus = 1
    return nil
  end
  return nil
end

function M.render(state, ui)
  ui = ui or M.new()
  sync(ui, state)
  local width = ui.width or 39
  local height = ui.height or 13
  if width < 1 then width = 1 end
  if height < 1 then height = 1 end
  if height == 1 then
    ui.buttons = {}
    return { lines = { pad(title(state), width) }, buttons = {}, cursor = 1 }
  end

  local lines = header(state, ui, width, height)
  local maxHeader = math.max(1, height - 2)
  while #lines > maxHeader do table.remove(lines) end
  local room = height - #lines - 1
  if room < 1 then room = 1 end

  local body = {}
  local opts = Core.options(state)
  local first, last = 1, 0
  if typing(state) then
    body[1] = { kind = "done", label = "Done" }
    if room >= 2 then body[2] = { kind = "backspace", label = "Backspace" } end
  else
    first = ui.first or 1
    if type(first) ~= "number" or first < 1 or (first > #opts and #opts > 0) then first = 1 end
    ui.first = first
    last = math.min(#opts, first + room - 1)
    if #opts == 0 then last = 0 end
    for n = first, last do
      body[#body + 1] = { kind = "choose", label = tostring(opts[n].label), n = n, id = opts[n].id }
    end
  end

  local foot = { { kind = "back", label = "Back" } }
  if not typing(state) then
    if first > 1 then
      foot[#foot + 1] = { kind = "prev", label = "Prev", next = math.max(1, first - room) }
    end
    if last < #opts then
      foot[#foot + 1] = { kind = "more", label = "More", next = last + 1 }
    end
  end

  local buttons = {}
  local function push(spec, x, y, w)
    buttons[#buttons + 1] = {
      x = x, y = y, w = w, h = 1,
      kind = spec.kind, n = spec.n, id = spec.id, next = spec.next, label = spec.label,
    }
  end

  for _, spec in ipairs(body) do
    local y = #lines + 1
    if y >= height then break end
    lines[y] = pad(" " .. spec.label, width)
    push(spec, 1, y, width)
  end
  while #lines < height - 1 do lines[#lines + 1] = string.rep(" ", width) end

  local footer = string.rep(" ", width)
  local x = 1
  for _, spec in ipairs(foot) do
    local shown = " " .. spec.label .. " "
    if #shown > width - x + 1 then shown = shown:sub(1, math.max(0, width - x + 1)) end
    if shown == "" then break end
    footer = footer:sub(1, x - 1) .. shown .. footer:sub(x + #shown)
    push(spec, x, height, #shown)
    x = x + #shown + 1
    if x > width then break end
  end
  lines[#lines + 1] = footer:sub(1, width)
  while #lines > height do table.remove(lines) end
  for i, line in ipairs(lines) do lines[i] = pad(line, width) end

  if #buttons == 0 then ui.focus = 1
  elseif not ui.focus or ui.focus < 1 or ui.focus > #buttons then ui.focus = 1 end
  for i, button in ipairs(buttons) do button.hot = i == ui.focus end
  ui.buttons = buttons
  return { lines = lines, buttons = buttons, cursor = ui.focus }
end

function M.hit(ui, state, x, y)
  if type(x) ~= "number" or type(y) ~= "number" then return nil end
  x, y = math.floor(x), math.floor(y)
  if x < 1 or y < 1 then return nil end
  local view = M.render(state, ui)
  for _, button in ipairs(view.buttons) do
    if y == button.y and x >= button.x and x < button.x + button.w then
      return activate(ui, button)
    end
  end
  return nil
end

function M.key(ui, state, key, char)
  if type(key) == "string" then key = key:lower() end
  local typingNow = typing(state)
  M.render(state, ui)
  if typingNow then
    if key == "enter" or key == "numpadenter" then
      local text = ui.buffer or ""
      ui.buffer = ""
      return { t = "text", s = text }
    end
    if key == "backspace" then
      if #(ui.buffer or "") > 0 then
        ui.buffer = ui.buffer:sub(1, -2)
        return nil
      end
      return { t = "back" }
    end
    if type(char) == "string" and #char == 1 and #(ui.buffer or "") < 48 and char:match("[%w:._ -]") then
      ui.buffer = (ui.buffer or "") .. char
    end
    return nil
  end
  local buttons = ui.buttons or {}
  if #buttons == 0 then
    if key == "backspace" then return { t = "back" } end
    return nil
  end
  if not ui.focus or ui.focus < 1 or ui.focus > #buttons then ui.focus = 1 end
  if key == "up" or key == "left" then
    ui.focus = ui.focus <= 1 and #buttons or ui.focus - 1
    return nil
  end
  if key == "down" or key == "right" or key == "tab" then
    ui.focus = ui.focus >= #buttons and 1 or ui.focus + 1
    return nil
  end
  if key == "enter" or key == "numpadenter" or key == "space" then
    return activate(ui, buttons[ui.focus])
  end
  if key == "backspace" then return { t = "back" } end
  if type(char) == "string" and char:match("^[1-9]$") then
    local n = tonumber(char)
    if Core.options(state)[n] then return { t = "choose", n = n } end
  end
  return nil
end

function M.scroll(ui, state, direction)
  local view = M.render(state, ui)
  local kind = (tonumber(direction) or 0) > 0 and "more" or "prev"
  for _, button in ipairs(view.buttons) do
    if button.kind == kind then return activate(ui, button) end
  end
  return nil
end

function M.input(ui, state, ev, a, b, c)
  if ev == "mouse_click" and not ui.monitor then return M.hit(ui, state, b, c) end
  if ev == "monitor_touch" and ui.monitor and a == ui.monitor then return M.hit(ui, state, b, c) end
  if ev == "mouse_scroll" and not ui.monitor then return M.scroll(ui, state, a) end
  if ev == "key" then
    local name = a
    if keys and keys.getName then name = keys.getName(a) end
    return M.key(ui, state, name, nil)
  end
  if ev == "char" then return M.key(ui, state, nil, a) end
  return nil
end

local function settingOn()
  local ok, value = pcall(function()
    if not (settings and settings.get) then return nil end
    return settings.get("install.touch")
  end)
  if not ok or value == false then return false end
  if value == nil or value == true then return true end
  return false
end

local function colourMonitor()
  if not (peripheral and peripheral.getNames and peripheral.getType and peripheral.call) then
    return nil
  end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local ok, colour = pcall(peripheral.call, name, "isColour")
      if ok and colour then return name end
    end
  end
end

function M.available()
  if not settingOn() then return false end
  if term and term.isColour and term.isColour() then return true end
  return colourMonitor() ~= nil
end

function M.surface()
  local name = colourMonitor()
  if name and peripheral.wrap then
    local ok, mon = pcall(peripheral.wrap, name)
    if ok and mon and mon.getSize then return mon, name end
  end
  return term, nil
end

function M.draw(target, view)
  if colors and target.setBackgroundColor then
    target.setBackgroundColor(colors.black)
    if target.setTextColor then target.setTextColor(colors.white) end
  end
  if target.clear then target.clear() end
  for i, line in ipairs(view.lines) do
    target.setCursorPos(1, i)
    if target.clearLine then target.clearLine() end
    target.write(line)
  end
  if not (colors and target.setBackgroundColor and target.setTextColor) then return end
  for _, button in ipairs(view.buttons) do
    local line = view.lines[button.y]
    if line then
      target.setCursorPos(button.x, button.y)
      target.setTextColor(button.hot and colors.black or colors.white)
      target.setBackgroundColor(button.hot and colors.yellow or colors.gray)
      target.write(line:sub(button.x, button.x + button.w - 1))
    end
  end
  if target.setBackgroundColor then target.setBackgroundColor(colors.black) end
  if target.setTextColor then target.setTextColor(colors.white) end
end

return M
