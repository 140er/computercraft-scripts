local U = {}
U.clock = function(epochMs)
  local seconds = math.floor(epochMs / 1000)
  local function calendar(days)
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local year = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local day = doy - math.floor((153 * mp + 2) / 5) + 1
    local month = mp + (mp < 10 and 3 or -9)
    return year + (month <= 2 and 1 or 0), month, day
  end
  local year = calendar(math.floor(seconds / 86400))
  local function switch(month)
    local days = month == 3 and 90 or 304
    local y = year - 1
    local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
    local last = 365 * (year - 1970) + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) - 477
      + days - 1 + (leap and 1 or 0)
    return (last - (last + 4) % 7) * 86400 + 3600
  end
  local offset = seconds >= switch(3) and seconds < switch(10) and 7200 or 3600
  seconds = seconds + offset
  local y, month, day = calendar(math.floor(seconds / 86400))
  local h, m, sec = math.floor(seconds / 3600) % 24, math.floor(seconds / 60) % 60, seconds % 60
  return { h = h, m = m, s = sec, date = string.format("%04d-%02d-%02d", y, month, day),
    hm = string.format("%02d:%02d", h, m), hms = string.format("%02d:%02d:%02d", h, m, sec) }
end

U.palette = {
  [0] = 0xF2F4F8, 0xFFC24B, 0xE57FD8, 0x99B2F2,
  0xDEDE6C, 0x7FCC19, 0xF2B2CC, 0x1F2B45,
  0x8A97B5, 0x2DD4BF, 0xB69CFF, 0x5AB0FF,
  0x4A5468, 0x3DDC84, 0xFF6B5E, 0x0E1626,
}
U.font = {
  ['0'] = '.###.#...##...##...##...##...#.###.',
  ['1'] = '..#...##....#....#....#....#...###.',
  ['2'] = '.###.#...#....#...#...#...#...#####',
  ['3'] = '####.....#....#.###.....#....#####.',
  ['4'] = '...#...##..#.#.#..#.#####...#....#.',
  ['5'] = '######....####.....#....##...#.###.',
  ['6'] = '..##..#...#....####.#...##...#.###.',
  ['7'] = '#####....#...#...#...#....#....#...',
  ['8'] = '.###.#...##...#.###.#...##...#.###.',
  ['9'] = '.###.#...##...#.####....#...#..##..',
  ['%'] = '##...##..#...#...#...#...#..##...##',
  ['-'] = '...............#####...............',
  [':'] = '......##...##........##...##.......',
  ['/'] = '....#....#...#...#...#...#....#....',
  [' '] = '...................................',
}

U.ink = function(bg) return (bg == 'f' or bg == '7' or bg == 'c') and '0' or 'f' end
U.size = function(w, h)
  for _, s in ipairs({ {26,20,'P'}, {51,19,'T'}, {57,24,'M'}, {39,19,'L'}, {15,10,'XS'} }) do
    if w == s[1] and h == s[2] then return s[3] end
  end
  return 'generic'
end
U.grid = function(w, h, columns)
  local n = columns or math.max(1, math.floor((w + 1) / 19))
  local cols, available = {}, w - n + 1
  for i = 1, n do
    local left = math.floor((i - 1) * available / n + 0.5)
    local right = math.floor(i * available / n + 0.5)
    cols[i] = { x = left + i, w = right - left }
  end
  return cols, math.max(0, math.floor((h - 6) / 8))
end
U.glyph = function(ch, ink, bg)
  local glyph, rows = assert(U.font[ch], 'unknown glyph'), {}
  for r = 0, 2 do
    local row = { text = '', fg = '', bg = '' }
    for c = 0, 2 do
      local bits = 0
      for p = 0, 5 do
        local x, y = c * 2 + p % 2, r * 3 + math.floor(p / 2)
        if x < 5 and y >= 1 and y <= 7 and glyph:sub((y - 1) * 5 + x + 1, (y - 1) * 5 + x + 1) == '#' then
          bits = bits + 2 ^ p
        end
      end
      local inverse = bits >= 32
      row.text = row.text .. string.char(128 + (inverse and 63 - bits or bits))
      row.fg = row.fg .. (inverse and bg or ink)
      row.bg = row.bg .. (inverse and ink or bg)
    end
    rows[r + 1] = row
  end
  return rows
end
U.canvas = function(w, h, bg)
  local C = { w = w, h = h, cells = {}, buttons = {} }
  bg = bg or 'f'
  for y = 1, h do
    C.cells[y] = {}
    for x = 1, w do C.cells[y][x] = { ' ', U.ink(bg), bg } end
  end
  C.put = function(x, y, text, fg, background)
    for i = 1, #text do
      if C.cells[y] and C.cells[y][x + i - 1] then
        local cell = C.cells[y][x + i - 1]
        cell[1], cell[2], cell[3] = text:sub(i,i), fg or U.ink(background or cell[3]), background or cell[3]
      end
    end
  end
  C.fill = function(x, y, width, height, background)
    for j = y, y + height - 1 do
      C.put(x, j, string.rep(' ', math.max(0, width)), U.ink(background), background)
    end
  end
  C.center = function(x, width, y, text, background)
    text = tostring(text):sub(1, math.max(0, width))
    C.put(x + math.max(0, math.floor((width - #text) / 2)), y, text, nil, background)
  end
  C.big = function(x, y, width, text, background)
    text = tostring(text)
    if #text * 3 > width or text:find('[^0123456789%%%-:/ ]') then
      C.center(x, width, y + 1, text, background)
      return
    end
    local start = x + math.max(0, math.floor((width - #text * 3) / 2))
    for i = 1, #text do
      for r, row in ipairs(U.glyph(text:sub(i,i), U.ink(background), background)) do
        for c = 1, 3 do
          C.put(start + (i - 1) * 3 + c - 1, y + r - 1, row.text:sub(c,c), row.fg:sub(c,c), row.bg:sub(c,c))
        end
      end
    end
  end
  C.hit = function(id, x, y, width, height)
    if x > w or y > h or x + width <= 1 or y + height <= 1 then return end
    local right, bottom = math.min(w, x + width - 1), math.min(h, y + height - 1)
    x, y = math.max(1, x), math.max(1, y)
    C.buttons[#C.buttons + 1] = { id = id, x = x, y = y, w = right - x + 1, h = bottom - y + 1, label = '' }
  end
  C.header = function(name, right, background)
    C.fill(2, 2, math.max(0,w-2), 1, background or '7')
    C.put(2, 2, name:sub(1, math.max(0, w - 2)))
    C.put(w - #(right or '') , 2, right or '')
  end
  C.alert = function(text)
    if not text or text == '' then return end
    C.fill(2, 3, math.max(0,w-2), 1, 'e'); C.put(2, 3, text:sub(1, math.max(0, w - 2)))
    C.hit('alerts', 2, 3, math.max(0,w-2), 1)
  end
  C.tile = function(x, y, width, label, value, sub, background, height)
    local right = math.min(w - 1, x + width - 1)
    x = math.max(2, x)
    width, height = math.max(0, right - x + 1), height or (h >= 24 and 7 or 6)
    C.fill(x, y, width, height, background)
    C.put(x + 1, y + 1, label:sub(1, math.max(0, width - 2)))
    C.big(x + 1, y + 2, math.max(0, width - 2), value, background)
    if height >= 7 then C.put(x + 1, y + 5, (sub or ''):sub(1, math.max(0, width - 2))) end
  end
  C.button = function(x, y, width, label, id, background, height)
    height, background = height or 3, background or '7'
    C.fill(x, y, width, height, background)
    local inset = #label <= width-2 and 1 or 0
    C.center(x + inset, math.max(0,width - 2*inset), y + math.floor(height / 2), label)
    C.hit(id, x, y, width, height)
  end
  C.listRow = function(y, text, state)
    C.fill(1, y, 1, 1, state); C.put(2, y, text:sub(1, math.max(0,w - 1)))
  end
  C.search = function(x, y, width, text, id)
    C.fill(x, y, width, 1, '0'); C.put(x, y, text:sub(1,width), 'f', '0')
    C.hit(id or 'search', x, y, width, 1)
  end
  C.frame = function()
    local rows = {}
    for y = 1, h do
      local text, runs = {}, {}
      for x = 1, w do
        local cell = C.cells[y][x]
        text[x] = cell[1]
        local last = runs[#runs]
        if last and last[2] == cell[2] and last[3] == cell[3] then last[1] = last[1] + 1
        else runs[#runs + 1] = { 1, cell[2], cell[3] } end
      end
      rows[y] = { text = table.concat(text):gsub(' +$', ''), runs = runs }
    end
    return { rows = rows, buttons = C.buttons, palette = U.palette }
  end
  return C
end

U.status = function(model, w, h)
  local C, size = U.canvas(w, h), U.size(w, h)
  local tiles = model.tiles
  C.header((size == 'P' or size == 'XS') and 'FLEET' or 'STATUS', size == 'XS' and 'ok' or model.time or 'ok')
  local function draw(index, x, y, width, height)
    local t = tiles[index]
    if not t then return end
    C.tile(x,y,width,t.label,t.value,t.sub,t.bg,height)
    if index == 9 then
      local left, right = math.max(2,x), math.min(w-1,x+width-1)
      C.fill(left+1,y+2,math.max(0,right-left-1),3,t.bg)
      C.center(left+1,math.max(0,right-left-1),y+3,'new client:')
    end
  end
  if size == 'P' then
    U.fleetRows(C,model,4,h >= 18 and 2 or 1)
  elseif size == 'XS' then
    draw((model.page or 0) % #tiles+1,1,3,w,7)
    C.button(1,h,w,'NEXT','next','7',1)
  else
    C.alert(model.alert and ('! '..model.alert) or nil)
    local cols = U.grid(w,h,size == 'T' and 4 or size == 'L' and 2 or nil)
    local indices = size == 'T' and {1,7,6,3} or size == 'L' and {1,3,4,6} or {1,2,3,4,5,6,7,8,9}
    local wanted = math.ceil(#indices/#cols)
    local height = h-4 >= wanted*8-1 and 7 or 6
    local count = math.max(0,math.floor((h-3)/(height+1)))
    for i,index in ipairs(indices) do
      local row,col = math.floor((i-1)/#cols),cols[(i-1)%#cols+1]
      if row < count then draw(index,col.x,4+row*(height+1),col.w,height) end
    end
    if size == 'T' then
      C.fill(2,12,w-2,1,'7'); C.put(2,12,'LOG')
      for i,line in ipairs(model.log or {}) do if 12+i < h then C.put(2,12+i,line:sub(1,w-2)) end end
    end
  end
  return C.frame()
end
U.alert = function(model, w, h)
  local C = U.canvas(w,h,'e')
  local a = model.takeover or {}
  C.center(1,w,4,'ALERT'); C.big(1,7,w,tostring(a.count or #model.alerts),'e')
  C.center(1,w,12,(a.text or model.alert or ''):upper())
  C.center(1,w,14,a.detail or '')
  C.center(1,w,16,a.sub or '')
  C.center(1,w,h-3,'(back to the screen in 5 s, or tap)')
  C.hit('dismiss',1,1,w,h)
  return C.frame()
end

-- Chip row: a label on navy, then { text, bg } chips right-aligned to `right`.
-- Returns the column left of the first chip.
U.chipRow = function(C, y, label, chips, x, right)
  x, right = x or 2, right or C.w - 1
  local room = right - x
  for _, chip in ipairs(chips) do room = room - #tostring(chip[1]) - 2 end
  C.put(x, y, label:sub(1, math.max(0, room)))
  for i = #chips, 1, -1 do
    local text = ' ' .. tostring(chips[i][1]) .. ' '
    right = right - #text
    C.put(right + 1, y, text, nil, chips[i][2])
  end
  return right
end
-- Fleet facts from the status model as chip rows: tiles 1-8, `step` rows apart.
-- The ALERTS row is the `alerts` target.
U.fleetRows = function(C, model, top, step)
  for i = 1, 8 do
    local t, y = (model.tiles or {})[i], top + (i - 1) * step
    if t and y <= C.h then
      U.chipRow(C, y, t.label, t.chips or { { t.value, t.bg } })
      if i == 3 then C.hit('alerts', 2, y, C.w - 2, 1) end
    end
  end
end
-- Sextant area chart of samples in width x height cells: ink on navy, lowest sample one pixel tall.
U.sparkline = function(C, x, y, width, height, samples, ink)
  local n, pw, ph = #samples, width * 2, height * 3
  if n == 0 or width < 1 or height < 1 then return end
  local lo, hi = samples[1], samples[1]
  for i = 2, n do lo, hi = math.min(lo, samples[i]), math.max(hi, samples[i]) end
  local cells, bit = {}, { 1, 2, 4, 8, 16, 32 }
  for px = 0, pw - 1 do
    local v = samples[math.floor(px * n / pw) + 1]
    local tall = hi == lo and math.ceil(ph / 2) or math.floor((v - lo) * (ph - 1) / (hi - lo) + 0.5) + 1
    for py = ph - tall, ph - 1 do
      local key = math.floor(py / 3) * width + math.floor(px / 2)
      cells[key] = (cells[key] or 0) + bit[px % 2 + 2 * (py % 3) + 1]
    end
  end
  for r = 0, height - 1 do
    for c = 0, width - 1 do
      local bits = cells[r * width + c] or 0
      if bits == 0 or bits == 63 then C.put(x + c, y + r, " ", nil, bits == 0 and "f" or ink)
      elseif bits < 32 then C.put(x + c, y + r, string.char(128 + bits), ink, "f")
      else C.put(x + c, y + r, string.char(191 - bits), "f", ink) end
    end
  end
end
return U
