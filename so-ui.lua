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
  return cols, math.max(0, math.floor((h - 6) / 6))
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
    C.fill(1, 1, w, 1, background or '7')
    C.put(2, 1, name:sub(1, math.max(0, w - 2)))
    C.put(w - #(right or '') , 1, right or '')
  end
  C.alert = function(text)
    if not text or text == '' then return end
    C.fill(1, 2, w, 1, 'e'); C.put(2, 2, text:sub(1, math.max(0, w - 2)))
    C.hit('alerts', 1, 2, w, 1)
  end
  C.tile = function(x, y, width, label, value, sub, background)
    C.fill(x, y, width, 5, background)
    C.put(x + 1, y, label:sub(1, math.max(0, width - 2)))
    C.big(x, y + 1, width, value, background)
    C.put(x + 1, y + 4, (sub or ''):sub(1, math.max(0, width - 2)))
  end
  C.button = function(x, y, width, label, id, background, height)
    height, background = height or 3, background or '7'
    C.fill(x, y, width, height, background)
    C.center(x, width, y + math.floor(height / 2), label)
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
  local draw = function(index, x, y, width, sub)
    local t = tiles[index]
    C.tile(x, y, width, t.label, t.value, sub or t.sub, t.bg)
    if index == 9 then
      C.fill(x, y + 1, width, 3, t.bg)
      C.center(x, width, y + 2, 'new client:')
      C.put(x + 1, y + 4, t.sub:sub(1, width - 1))
    end
  end
  C.header((size == 'P' or size == 'XS') and 'FLEET' or 'STATUS',
    size == 'P' and model.time or size == 'M' and (model.time .. '  ok') or 'ok')
  if size == 'P' then
    for i, index in ipairs({1,3,4}) do draw(index, 1, 2 + (i - 1) * 6, w, index == 4 and model.oreShort or nil) end
  elseif size == 'XS' then
    local index = (model.page or 0) % #tiles + 1
    draw(index, 1, 3, w, index == 1 and model.lostShort or nil)
    C.button(1,h-1,w,'NEXT','next','7',1)
    C.button(1,h,w,'MORE','generic','7',1)
  elseif size == 'T' then
    for i, index in ipairs({1,7,6,3}) do draw(index, (i - 1) * 13 + 1, 3, 12, (model.terminalSubs or {})[i]) end
    C.fill(1,9,w,1,'7'); C.put(2,9,'LOG')
    for i, line in ipairs(model.log or {}) do if i <= 6 then C.put(2,9+i,line:sub(1,w-2)) end end
    for i, label in ipairs({'MINING','LUMBER','SHOP','MORE'}) do
      C.button((i-1)*13+1,h-2,12,label,({'mining','lumber','shop','generic'})[i],i == 3 and 'a' or '7')
    end
    C.alert(model.alert and ('! ' .. model.alert) or nil)
  else
    C.alert(model.alert and ('! ' .. model.alert .. (size == 'M' and '          tap for alerts' or '')) or nil)
    local cols, count = U.grid(w,h,size == 'M' and 3 or size == 'L' and 2 or nil)
    if size == 'M' then cols = {{x=1,w=18},{x=20,w=19},{x=40,w=18}}; count = 3 end
    if size == 'L' then count = 2 end
    local indices = size == 'L' and {1,3,4,6} or {1,2,3,4,5,6,7,8,9}
    for i, index in ipairs(indices) do
      local r, col = math.floor((i-1)/#cols), cols[(i-1)%#cols+1]
      if r < count then
        draw(index, col.x, 4+r*6, col.w, size == 'L' and (index == 1 and model.okShort or index == 4 and model.oreShort or nil) or nil)
      end
    end
    local labels = size == 'L' and {'MINING','SHOP','MORE'} or {'MINING','LUMBER','SHOP','MORE'}
    local buttons = U.grid(w,h,#labels)
    for i, label in ipairs(labels) do
      local col = buttons[i]
      if size == 'M' then col = ({{x=1,w=13},{x=15,w=14},{x=30,w=14},{x=45,w=13}})[i] end
      if size == 'L' then col = ({{x=1,w=12},{x=14,w=12},{x=27,w=13}})[i] end
      C.button(col.x,h-2,col.w,label,label == 'MORE' and 'generic' or label:lower(),label == 'SHOP' and 'a' or '7')
    end
  end
  if size == 'P' then C.button(1,h-1,w,'MORE','generic','7',1) end
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
return U
