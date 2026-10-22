local R = {}

local function chars(text)
  local result = {}
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do result[#result + 1] = ch end
  return result
end

local function utf8(n)
  if n < 0x800 then return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64) end
  if n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
  end
  return string.char(0xF0 + math.floor(n / 262144), 0x80 + math.floor(n / 4096) % 64,
    0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
end

R.sextant = function(bits)
  if bits == 0 then return " " end
  if bits == 63 then return "█" end
  if bits == 21 then return "▌" end
  if bits == 42 then return "▐" end
  return utf8(0x1FB00 + bits - 1 - (bits > 21 and 1 or 0) - (bits > 42 and 1 or 0))
end

R.load = function(path)
  local file = assert(io.open(path, "rb"))
  local header = assert(file:read("*l"))
  local w, h, title = header:match("^(%d+)x(%d+) (.*)$")
  local picture = { w = assert(tonumber(w)), h = assert(tonumber(h)), title = title, text = {}, bg = {} }
  for _, layer in ipairs({ "text", "bg" }) do
    for y = 1, picture.h do
      local row = assert(file:read("*l"), "missing fixture row")
      assert(#chars(row) == picture.w, "fixture row width")
      picture[layer][y] = row
    end
  end
  assert(file:read("*a") == "", "extra fixture rows")
  file:close()
  return picture
end

R.capture = function(w, h)
  local state = { x = 1, y = 1, fg = "0", bg = "f", cells = {} }
  local term = { cells = state.cells, palette = {} }
  local function colour(n)
    for i = 0, 15 do if n == 2 ^ i then return ("0123456789abcdef"):sub(i + 1, i + 1) end end
    error("invalid colour")
  end
  term.getSize = function() return w, h end
  term.isColor = function() return true end
  term.isColour = term.isColor
  term.setCursorPos = function(x, y) state.x, state.y = x, y end
  term.getCursorPos = function() return state.x, state.y end
  term.setTextColour = function(n) state.fg = colour(n) end
  term.setTextColor = term.setTextColour
  term.setBackgroundColour = function(n) state.bg = colour(n) end
  term.setBackgroundColor = term.setBackgroundColour
  term.getTextColour = function() return 2 ^ tonumber(state.fg, 16) end
  term.getTextColor = term.getTextColour
  term.getBackgroundColour = function() return 2 ^ tonumber(state.bg, 16) end
  term.getBackgroundColor = term.getBackgroundColour
  term.setPaletteColour = function(n, ...) term.palette[n] = { ... } end
  term.getPaletteColour = function(n) return unpack(term.palette[n] or { 0, 0, 0 }) end
  term.blit = function(text, fg, bg)
    assert(#text == #fg and #text == #bg, "blit width")
    for i = 1, #text do
      local x, y = state.x + i - 1, state.y
      if x >= 1 and x <= w and y >= 1 and y <= h then
        state.cells[y][x] = { text:sub(i, i), fg:sub(i, i), bg:sub(i, i) }
      end
    end
    state.x = state.x + #text
  end
  term.write = function(text)
    text = tostring(text)
    term.blit(text, string.rep(state.fg, #text), string.rep(state.bg, #text))
  end
  term.clear = function()
    for y = 1, h do
      state.cells[y] = {}
      for x = 1, w do state.cells[y][x] = { " ", state.fg, state.bg } end
    end
  end
  term.clearLine = function()
    if state.y < 1 or state.y > h then return end
    for x = 1, w do state.cells[state.y][x] = { " ", state.fg, state.bg } end
  end
  term.picture = function()
    local picture = { w = w, h = h, text = {}, bg = {} }
    for y = 1, h do
      local text, backgrounds = {}, {}
      for x = 1, w do
        local cell = state.cells[y][x]
        local ch, fg, bg = cell[1], cell[2], cell[3]
        local byte = ch:byte()
        if byte >= 128 and byte <= 159 then
          local inverse = (bg == "f" and fg ~= "0" and fg ~= "8")
            or (bg == "0" and (fg == "c" or fg == "7" or fg == "f"))
          ch = R.sextant(inverse and 63 - (byte - 128) or byte - 128)
          if inverse then bg = fg end
        end
        text[x], backgrounds[x] = ch, bg
      end
      picture.text[y], picture.bg[y] = table.concat(text), table.concat(backgrounds)
    end
    return picture
  end
  term.clear()
  return term
end

R.diff = function(fixture, picture)
  if type(fixture) == "string" then fixture = R.load(fixture) end
  if picture.picture then picture = picture.picture() end
  local differences = {}
  if fixture.w ~= picture.w or fixture.h ~= picture.h then return { "picture dimensions differ" } end
  for _, layer in ipairs({ "text", "bg" }) do
    for y = 1, fixture.h do
      local expected, got = chars(fixture[layer][y]), chars(picture[layer][y])
      for x = 1, fixture.w do
        if expected[x] ~= got[x] then
          differences[#differences + 1] = string.format("row %d column %d layer %s expected %q got %q",
            y, x, layer, expected[x], got[x] or "")
          if #differences == 8 then return differences end
        end
      end
    end
  end
  return differences
end

return R
