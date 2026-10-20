-- Keyboard view for the install state machine. Arrow keys move, Enter confirms,
-- digits pick, Backspace goes back. Every screen fits a 39 by 13 turtle terminal.

local Core = dofile("install-core.lua")
local M = { width = 39, height = 13 }

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
    return clip((state.role or "?") .. " " .. tostring(pos.x) .. "," .. tostring(pos.y) .. "," .. tostring(pos.z), 39)
  end
  if state.step == "error" then return "Something went wrong" end
  if state.step == "fetch" then return "Copying files" end
  if state.step == "pair" then return "Saving" end
  if state.step == "done" then return "Installed" end
  return "Installer"
end

function M.new()
  return { cursor = 1, buffer = "", step = false }
end

local function sync(ui, state)
  if ui.step ~= state.step then
    ui.step = state.step
    ui.cursor = 1
    ui.buffer = ""
  end
end

local function typing(state)
  if state.step == "enter_code" then return true end
  local phase = state.draft and state.draft.phase
  return state.step == "position" and (phase == "x" or phase == "y" or phase == "z")
end

function M.render(state, ui)
  ui = ui or M.new()
  sync(ui, state)
  local lines = { clip(title(state), M.width) }
  if state.step == "error" then
    local err = state.error or {}
    local detail = err.detail
    if detail == nil or detail == "" then detail = tostring(err.code or "error") end
    if state.draft and state.draft.help then
      detail = detail .. " Retry tries this step again. Back returns to the previous step."
    end
    for _, line in ipairs(wrap(err.code .. ": " .. detail, M.width)) do
      lines[#lines + 1] = line
    end
  elseif typing(state) then
    local note = state.draft and state.draft.note
    if note and note ~= "" and note ~= false then
      lines[#lines + 1] = clip(note, M.width)
    end
    lines[#lines + 1] = clip("> " .. ui.buffer, M.width)
  end
  local opts = Core.options(state)
  local room = M.height - #lines - 1
  if room < 1 then room = 1 end
  local first = 1
  if ui.cursor > room then first = ui.cursor - room + 1 end
  local shown = 0
  for i = first, #opts do
    if shown >= room then break end
    local mark = i == ui.cursor and ">" or " "
    local prefix = i <= 9 and tostring(i) or " "
    lines[#lines + 1] = clip(mark .. prefix .. " " .. opts[i].label, M.width)
    shown = shown + 1
  end
  while #lines < M.height - 1 do lines[#lines + 1] = "" end
  lines[#lines + 1] = clip("Arrows  Enter  1-9  Backspace", M.width)
  while #lines > M.height do table.remove(lines, 2) end
  return { lines = lines, cursor = ui.cursor }
end

function M.event(ui, state, key, char)
  sync(ui, state)
  key = key and key:lower() or nil
  if typing(state) then
    if key == "enter" or key == "numpadenter" then
      local text = ui.buffer
      ui.buffer = ""
      return { t = "text", s = text }
    end
    if key == "backspace" then
      if #ui.buffer > 0 then
        ui.buffer = ui.buffer:sub(1, -2)
        return nil
      end
      return { t = "back" }
    end
    if char and #char == 1 and #ui.buffer < 48 and char:match("[%w:._ -]") then
      ui.buffer = ui.buffer .. char
    end
    return nil
  end
  local opts = Core.options(state)
  if #opts == 0 then
    if key == "backspace" then return { t = "back" } end
    return nil
  end
  if key == "up" or key == "left" then
    ui.cursor = ui.cursor <= 1 and #opts or ui.cursor - 1
    return nil
  end
  if key == "down" or key == "right" or key == "tab" then
    ui.cursor = ui.cursor >= #opts and 1 or ui.cursor + 1
    return nil
  end
  if key == "enter" or key == "numpadenter" or key == "space" then
    return { t = "choose", n = ui.cursor }
  end
  if key == "backspace" then return { t = "back" } end
  if char and char:match("^[1-9]$") then
    local n = tonumber(char)
    if opts[n] then return { t = "choose", n = n } end
  end
  return nil
end

return M
