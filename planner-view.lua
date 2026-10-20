-- Top-down planner view. One map cell is one character.
-- Known, predicted, unknown, intent, and occupied each have their own glyph and colour.
-- A 26 by 20 pocket keeps two chrome rows, so the map is 26 by 18.

local M = {}

M.STYLE = {
  unknown = { ch = "?", fg = "8", bg = "f" },
  predicted = { ch = "+", fg = "7", bg = "8" },
  known = { ch = "#", fg = "f", bg = "7" },
  intent = { ch = "!", fg = "f", bg = "4" },
  occupied = { ch = "@", fg = "0", bg = "e" },
  base = { ch = ".", fg = "f", bg = "3" },
  chest = { ch = "C", fg = "f", bg = "1" },
  bot = { ch = "M", fg = "0", bg = "d" },
}

local HEADING = { [0] = "^", ">", "v", "<" }

local function pad(text, fg, bg, width)
  if #text > width then
    text, fg, bg = text:sub(1, width), fg:sub(1, width), bg:sub(1, width)
  elseif #text < width then
    local n = width - #text
    text = text .. string.rep(" ", n)
    fg = fg .. string.rep(fg:sub(-1), n)
    bg = bg .. string.rep(bg:sub(-1), n)
  end
  return text, fg, bg
end

function M.paint(screen, model)
  local w, h = screen.getSize()
  local hits = {}
  if w < 1 or h < 1 then return { hits = hits, mapTop = 1, originX = 0, originZ = 0 } end
  model = model or {}
  local y = model.y or 64
  local originX = model.originX or 0
  local originZ = model.originZ or 0
  local mapTop = h >= 2 and 3 or 1
  if screen.clear then screen.clear() end
  if screen.setCursorPos then screen.setCursorPos(1, 1) end

  local title = (model.name or "Plan") .. " y" .. y .. " r" .. tostring(model.rev or 0)
  if model.code then title = title .. " " .. model.code end
  if model.note and model.note ~= "" and #title + 1 + #model.note <= w then
    title = title .. " " .. model.note
  end
  local text, fg, bg = pad(title, string.rep("0", #title), string.rep("b", #title), w)
  screen.blit(text, fg, bg)

  if h >= 2 then
    local chars, fgs, bgs = {}, {}, {}
    for col = 1, w do chars[col], fgs[col], bgs[col] = " ", "0", "f" end
    local function put(col, label, hit)
      if col < 1 or col > w then return col end
      for i = 1, #label do
        local at = col + i - 1
        if at <= w then chars[at], fgs[at], bgs[at] = label:sub(i, i), "0", hit and "8" or "f" end
      end
      if hit and col <= w then
        hits[#hits + 1] = {
          row = 2, x1 = col, x2 = math.min(w, col + #label - 1),
          kind = hit.kind, dy = hit.dy, tool = hit.tool, event = hit.event,
        }
      end
      return col + #label
    end
    local col = 1
    col = put(col, "[-]", { kind = "level", dy = -1 })
    col = put(col, " " .. y .. " ", nil)
    col = put(col, "[+]", { kind = "level", dy = 1 })
    col = put(col + 1, "New", { kind = "create" })
    col = put(col + 1, "D", { kind = "tool", tool = "draw" })
    col = put(col + 1, "C", { kind = "tool", tool = "chest" })
    col = put(col + 1, "B", { kind = "tool", tool = "bot" })
    put(col + 1, "K", { kind = "issue" })
    if screen.setCursorPos then screen.setCursorPos(1, 2) end
    screen.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
  end

  local classAt = model.classAt or function() return "unknown" end
  local headingAt = model.headingAt or function() return nil end
  for row = mapTop, h do
    local chars, fgs, bgs = {}, {}, {}
    local z = originZ + (row - mapTop)
    for col = 1, w do
      local x = originX + (col - 1)
      local class = classAt(x, z)
      local style = M.STYLE[class] or M.STYLE.unknown
      local ch = style.ch
      if class == "bot" then ch = HEADING[headingAt(x, z)] or ch end
      chars[col], fgs[col], bgs[col] = ch, style.fg, style.bg
    end
    if screen.setCursorPos then screen.setCursorPos(1, row) end
    screen.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
  end
  return { hits = hits, mapTop = mapTop, originX = originX, originZ = originZ, width = w, height = h }
end

return M
