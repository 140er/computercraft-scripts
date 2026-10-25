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

-- Route A palette (docs/ui/SCHEMATIC-SPEC.md). Slot 3 is steel, the dug-passage colour.
U.palette = {
  [0] = 0xE6EAF2, 0xFFC24B, 0xE57FD8, 0x9DB0D2,
  0xDEDE6C, 0x7FCC19, 0xF2B2CC, 0x18223A,
  0x7886A3, 0x2DD4BF, 0xB69CFF, 0x5AB0FF,
  0x28344D, 0x3DDC84, 0xFF6B5E, 0x0B111C,
}
-- No server: the client keeps the last picture in this grey ramp; slot 2 carries the coral bar.
U.stale = {
  [0] = 0x6A7690, 0x46526C, 0xFF6B5E, 0x46526C,
  0x46526C, 0x46526C, 0x46526C, 0x18223A,
  0x46526C, 0x46526C, 0x46526C, 0x46526C,
  0x222B3E, 0x46526C, 0x46526C, 0x0B111C,
}
-- CC font bytes for the route A glyphs.
U.g = { up = "\30", right = "\16", down = "\31", left = "\17", dot = "\183", bullet = "\7",
  cross = "\215", spade = "\6", club = "\5", shaft = "\186", gap = "\166" }
U.arrow = function(facing)
  return ({ [0] = U.g.up, U.g.right, U.g.down, U.g.left })[facing] or U.g.bullet
end
-- State colour of a state word: d working, 1 waiting, e lost or broken, 8 idle.
U.tones = { { "e", { "lost", "broken", "block", "error", "fail", "missing", "expire", "refuse" } },
  { "1", { "wait", "hold", "range", "recover", "stale", "low", "full" } },
  { "8", { "idle", "stop", "done", "off" } } }
U.tone = function(word)
  word = tostring(word or ""):lower()
  if word == "" or word == "-" then return "8" end
  for _, set in ipairs(U.tones) do
    for _, stem in ipairs(set[2]) do
      if word:find("%f[%a]" .. stem) then return set[1] end
    end
  end
  return "d"
end
-- A log line's mark colour: only problems and waits are coloured.
U.mark = function(line)
  local t = U.tone(line)
  return (t == "e" or t == "1") and t or "8"
end
U.age = function(ms, long)
  if ms < 60000 then return "now" end
  if ms < 3600000 then return math.floor(ms / 60000) .. (long and " min" or "m") end
  return math.floor(ms / 3600000) .. (long and " h" or "h")
end
-- Cells of an n-cell tick row for part of whole; any part above zero shows one.
U.filled = function(n, part, whole)
  if whole <= 0 or part <= 0 then return 0 end
  return math.max(1, math.min(n, math.floor((part * n * 2 + whole) / (whole * 2))))
end
U.chips = { plain = { "0", "7" }, primary = { "9", "7" }, stop = { "e", "7" }, muted = { "8", "7" },
  on = { "f", "9" }, off = { "8", "f" } }
U.segments = { ["0"] = "abcdef", ["1"] = "bc", ["2"] = "abged", ["3"] = "abgcd", ["4"] = "fgbc",
  ["5"] = "afgcd", ["6"] = "afgedc", ["7"] = "abc", ["8"] = "abcdefg", ["9"] = "abcdfg" }
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
  C.hit = function(id, x, y, width, height, label)
    if x > w or y > h or x + width <= 1 or y + height <= 1 then return end
    local right, bottom = math.min(w, x + width - 1), math.min(h, y + height - 1)
    x, y = math.max(1, x), math.max(1, y)
    C.buttons[#C.buttons + 1] = { id = id, x = x, y = y, w = right - x + 1, h = bottom - y + 1, label = label or '' }
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
  -- Route A (docs/ui/SCHEMATIC-SPEC.md). Same names and arguments as docs/ui/schematic/kit.py.
  C.rule = function(x1, y, x2, fg)
    if x2 >= x1 then C.put(x1, y, string.rep("-", x2 - x1 + 1), fg or "c") end
  end
  -- Header row: role name, tabs (ids tab:<name>), a hairline, then the state word or time.
  C.bar = function(name, tabs, active, right, rfg, y)
    y, right = y or 1, right or ""
    C.put(2, y, name, "0")
    local x = 2 + #name + 2
    for _, t in ipairs(tabs or {}) do
      local label = " " .. t .. " "
      if t == active then C.put(x, y, label, "0", "7") else C.put(x, y, label, "8") end
      C.hit("tab:" .. t:lower(), x, y, #label, 1, t)
      x = x + #label + 1
    end
    local last = w - #right - 1
    if right ~= "" then C.put(last + 1, y, right, rfg or "8") end
    C.rule(x, y, last - 1)
  end
  C.section = function(x, y, width, title, right, rfg)
    right = right and tostring(right) or ""
    C.put(x, y, title, "8")
    local last = x + width - 1 - (right ~= "" and #right + 1 or 0)
    if right ~= "" then C.put(last + 1, y, right, rfg or "8") end
    C.rule(x + #title + 1, y, last - 1)
  end
  C.leader = function(x, y, width, label, value, vfg, lfg)
    value = tostring(value)
    C.put(x, y, label:sub(1, math.max(0, width - #value - 1)), lfg or "8")
    local vx = x + width - #value
    if vx - 1 > x + #label + 1 then C.put(x + #label + 1, y, string.rep(U.g.dot, vx - 2 - x - #label), "c") end
    C.put(vx, y, value, vfg or "0")
  end
  C.ticks = function(x, y, n, done, fg, rest, ch, restch)
    for i = 0, n - 1 do
      if i < done then C.put(x + i, y, ch or "|", fg or "3")
      else C.put(x + i, y, restch or U.g.dot, rest or "8") end
    end
  end
  -- A tick row with its explicit fraction. Returns the column after the fraction.
  C.progress = function(x, y, n, done, total, fg, ch, rest, restch)
    C.ticks(x, y, n, U.filled(n, done, total), fg, rest, ch, restch)
    local frac = done .. "/" .. total
    C.put(x + n + 1, y, frac, "0")
    return x + n + 1 + #frac
  end
  -- One-row control: plain, primary, stop, muted, on or off. width fixes the size and centres the label.
  C.chip = function(x, y, label, id, kind, width)
    local colours = U.chips[kind or "plain"]
    width = width or #label + 2
    C.put(x, y, string.rep(" ", width), colours[1], colours[2])
    C.put(x + math.max(0, math.floor((width - #label) / 2)), y, label:sub(1, width), colours[1], colours[2])
    C.hit(id, x, y, width, 1, label)
    return x + width
  end
  -- ! text detail, inside width cells; the detail only when it fits.
  C.flag = function(x, y, width, text, detail)
    C.put(x, y, "!", "e")
    text = text:sub(1, math.max(0, width - 2))
    C.put(x + 2, y, text, "0")
    if detail and detail ~= "" and #text + #detail + 3 <= width then C.put(x + 3 + #text, y, detail, "8") end
  end
  C.box = function(x, y, width, height, fg)
    C.rule(x, y, x + width - 1, fg)
    C.rule(x, y + height - 1, x + width - 1, fg)
    for j = y, y + height - 1 do C.put(x, j, "|", fg); C.put(x + width - 1, j, "|", fg) end
    for _, p in ipairs({ { x, y }, { x + width - 1, y }, { x, y + height - 1 }, { x + width - 1, y + height - 1 } }) do
      C.put(p[1], p[2], "+", fg)
    end
  end
  -- Large thin digits drawn with - | +, for numbers read across a room. Returns the width.
  C.digits = function(x, y, text, fg, dw, dh, gap)
    dw, dh, gap, fg = dw or 4, dh or 5, gap or 2, fg or "0"
    local m = math.floor(dh / 2)
    local hz = { a = 0, g = m, d = dh - 1 }
    local vt = { f = { 0, 1, m - 1 }, b = { dw - 1, 1, m - 1 }, e = { 0, m + 1, dh - 2 }, c = { dw - 1, m + 1, dh - 2 } }
    for i = 1, #text do
      local d, left = text:sub(i, i), x + (i - 1) * (dw + gap)
      local segs = U.segments[d] or ""
      if d == "1" then
        for r = 0, dh - 1 do C.put(left + math.floor(dw / 2), y + r, "|", fg) end
      else
        for s, row in pairs(hz) do if segs:find(s) then C.rule(left + 1, y + row, left + dw - 2, fg) end end
        for s, v in pairs(vt) do
          if segs:find(s) then for r = v[2], v[3] do C.put(left + v[1], y + r, "|", fg) end end
        end
        for _, col in ipairs({ 0, dw - 1 }) do
          for _, row in ipairs({ 0, m, dh - 1 }) do
            local hor, ver = false, false
            for s, r in pairs(hz) do if r == row and segs:find(s) then hor = true end end
            for s, v in pairs(vt) do
              if segs:find(s) and v[1] == col and (v[2] - 1 == row or v[3] + 1 == row) then ver = true end
            end
            local ch = hor and ver and "+" or hor and "-" or ver and "|"
            if ch then C.put(left + col, y + row, ch, fg) end
          end
        end
      end
    end
    return #text * (dw + gap) - gap
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

-- Status in route A at every size; docs/ui/schematic/status.py is its twin and makes the fixtures.
-- The model comes from so-mod-display's gather (see docs/server-only/PROTOCOL.md#display).
U.st = {}
U.st.fg = function(tone) return (tone == "1" or tone == "e" or tone == "8") and tone or "0" end
-- Arrow, id, state, where; rows under 30 cells put where at the right edge. A narrow row with pos
-- puts the whole where at the right edge and pos right-aligned before it, and cuts the state instead.
-- cut moves where left in a wide row and shortens the state by as much.
U.st.turtle = function(C, x, y, t, width, pos, pfg, cut)
  C.put(x, y, U.arrow(t.facing), t.tone)
  C.put(x + 2, y, tostring(t.id), "0")
  if width >= 30 and not pos then
    cut = cut or 0
    C.put(x + 5, y, t.state:sub(1, 10 - cut), U.st.fg(t.tone))
    C.put(x + 16 - cut, y, t.where:sub(1, 5), "8")
  elseif pos then
    local wx = x + width - #t.where
    local px = wx - 1 - #pos
    C.put(x + 5, y, t.state:sub(1, math.max(0, px - x - 7)), U.st.fg(t.tone))
    C.put(px, y, pos, pfg)
    C.put(wx, y, t.where, "8")
  else
    C.put(x + 5, y, t.state:sub(1, math.max(0, width - 11)), U.st.fg(t.tone))
    C.put(x + width - 4, y, t.where:sub(1, 4), "8")
  end
  C.hit("turtle:" .. tostring(t.id), x, y, width, 1)
end
-- "x,z" or "x,y,z", or "-" before the first known position.
U.st.at = function(t, full)
  if not (t.x and t.y and t.z) then return "-" end
  return full and (t.x .. "," .. t.y .. "," .. t.z) or (t.x .. "," .. t.z)
end
U.st.more = function(C, x, y, n) C.put(x, y, "+" .. n .. " more", "8") end
U.st.diskValue = function(d)
  if not d then return "-", "8" end
  return math.floor(d.used * 100 / d.cap) .. "%", d.used * 5 >= d.cap * 4 and "e" or "0"
end
-- disk |········ 13% across width cells; value replaces the percentage.
U.st.disk = function(C, x, y, width, d, value)
  local pct, fg = U.st.diskValue(d)
  value = value or pct
  C.put(x, y, "disk", "8")
  local n = width - 6 - math.max(4, #value)
  C.ticks(x + 5, y, n, d and U.filled(n, d.used, d.cap) or 0, fg == "e" and "e" or "3")
  C.put(x + width - #value, y, value, fg)
  C.hit("disk", x, y, width, 1)
end
U.st.jobs = function(C, x, y, m, wide)
  local mi, lu = m.mining, m.lumber
  C.put(x, y, "mining", "0")
  if mi then
    C.put(x + 8, y, mi.state, U.tone(mi.state))
    C.progress(x + 17, y, 10, mi.done, mi.total)
    if wide then
      C.put(x + 34, y, "busy " .. mi.busy .. "/" .. mi.workers, "8")
      if mi.lane then
        C.put(x + 44, y, "lane", "8")
        C.put(x + 49, y, U.arrow(mi.lane.facing) .. mi.lane.id, "b")
      end
    end
  else C.put(x + 8, y, "-", "8") end
  C.put(x, y + 1, "lumber", "0")
  if lu then
    C.put(x + 8, y + 1, lu.state, U.tone(lu.state))
    C.progress(x + 17, y + 1, 10, lu.ready, lu.spots, "d", U.g.spade, "8", U.g.club)
    if wide and lu.grow then C.put(x + 34, y + 1, "grow " .. lu.grow, "8") end
  else C.put(x + 8, y + 1, "-", "8") end
end
-- TODAY leaders: ore, the top ore names when n leaves room, logs, recent ore.
U.st.today = function(m, n)
  local t, rows = m.today, {}
  if not t then
    rows = { { "ore", "-", "8" }, { "logs", "-", "8" }, { "ore 10 min", "-", "8" } }
  else
    rows[1] = { "ore", tostring(t.ore), "0" }
    for i = 1, math.max(0, n - 3) do
      if t.names[i] then rows[#rows + 1] = { t.names[i][1], tostring(t.names[i][2]), "0" } end
    end
    rows[#rows + 1] = { "logs", tostring(t.logs), "0" }
    rows[#rows + 1] = { "ore 10 min", "+" .. t.recent, "0" }
  end
  while #rows > n do rows[#rows] = nil end
  return rows
end
-- Up to n alert rows from y with margin x; the last row counts the rest. Returns the rows drawn.
U.st.flags = function(C, y, m, n, short, x, width)
  x, width = x or 2, width or C.w
  local list, room = m.flags or {}, width - 2 * (x - 1)
  local shown = math.min(n, #list)
  for i = 1, shown do
    local f = list[i]
    local text = #f.text > room - 2 and f.brief or f.text
    C.flag(x, y + i - 1, room, text, short and f.short or not short and f.detail or "")
  end
  if #list > n and n > 0 then
    local extra = "+" .. (#list - n)
    C.put(width - #extra, y + n - 1, extra, "8")
  end
  -- A broken drop's row opens the drop list on it; the other rows open the newest alert when the
  -- state module raised one.
  for i = 1, shown do
    local hit = m.flagHits ~= false and list[i].hit or #(m.alerts or {}) > 0 and "alerts"
    if hit then C.hit(hit, x, y + i - 1, room, 1) end
  end
  return shown
end
U.st.events = function(C, x, y, width, m, n, clock)
  for i = 1, math.min(n, #(m.events or {})) do
    local e = m.events[i]
    if clock > 0 then C.put(x, y + i - 1, e.time:sub(1, clock), "8") end
    local tx = x + (clock > 0 and clock + 1 or 0)
    C.put(tx, y + i - 1, U.g.bullet, e.tone)
    C.put(tx + 2, y + i - 1, e.text:sub(1, math.max(0, width - (tx + 2 - x))), "0")
  end
end
U.st.rows = function(C, ts, n, top, draw)
  for i = 1, n do
    if i == n and #ts > n then U.st.more(C, 4, top + i - 1, #ts - i + 1); return end
    draw(ts[i], top + i - 1)
  end
end
U.st.room = function(C, m)
  local w, h = C.w, C.h
  C.bar(m.name or "STATUS", nil, nil, m.time)
  local na = U.st.flags(C, 3, m, 2)
  local top = na > 0 and 4 + na or 3
  local lw, rx, ts = w - 24, w - 19, m.turtles
  local nt = math.min(#ts, math.max(0, h - top - 11))
  -- Positions go at column 24 when every one fits there; otherwise each sits before its branch.
  local narrow = lw < 30
  for i = 1, nt do narrow = narrow or #U.st.at(ts[i]) > lw - 22 end
  C.section(2, top, lw, "TURTLES", #ts)
  U.st.rows(C, ts, nt, top + 1, function(t, y)
    local pos, fg = U.st.at(t), t.lost and "e" or "8"
    if narrow then U.st.turtle(C, 2, y, t, lw, pos, fg)
    else
      U.st.turtle(C, 2, y, t, lw)
      C.put(24, y, pos, fg)
    end
  end)
  local jy = top + nt + 2
  C.section(2, jy, lw, "JOBS")
  U.st.jobs(C, 2, jy + 1, m)
  C.section(rx, top, 19, "TODAY")
  for i, r in ipairs(U.st.today(m, 3)) do C.leader(rx, top + i, 19, r[1], r[2], r[3]) end
  C.section(rx, top + 5, 19, "SERVER")
  U.st.disk(C, rx, top + 6, 19, m.disk)
  C.leader(rx, top + 7, 19, "leases", m.leases)
  C.leader(rx, top + 8, 19, "displays", #m.displays)
  C.leader(rx, top + 9, 19, "up", m.server.up)
  local dy = math.max(jy + 2, top + 9) + 2
  C.section(2, dy, w - 2, "DROPS", #m.drops)
  -- Broken drops first; a +N ends the row when some do not fit. Each drop opens the drop list on it.
  local ds, x = {}, 2
  for _, d in ipairs(m.drops) do if d.broken then ds[#ds + 1] = d end end
  for _, d in ipairs(m.drops) do if not d.broken then ds[#ds + 1] = d end end
  for i, d in ipairs(ds) do
    local text = d.id .. " " .. d.kind
    local rest = i < #ds and #("+" .. (#ds - i)) + 3 or 0
    if x + 1 + #text + rest > w - 1 then
      C.put(x, dy + 1, "+" .. (#ds - i + 1), "8")
      break
    end
    local c = d.broken and "e" or "0"
    C.put(x, dy + 1, d.broken and U.g.cross or U.g.bullet, c)
    C.put(x + 2, dy + 1, text, c)
    C.hit("drop:" .. d.id, x, dy + 1, #text + 2, 1)
    x = x + #text + 5
  end
  local ey = dy + 3
  if ey < h then
    C.section(2, ey, w - 2, "EVENTS")
    U.st.events(C, 2, ey + 1, w - 2, m, h - ey, 5)
  end
end
U.st.wall = function(C, m)
  local w, h = C.w, C.h
  C.bar(m.name or "STATUS", nil, nil, "server #" .. m.server.id .. " " .. U.g.dot .. " " .. m.time)
  local na = U.st.flags(C, 3, m, 2, false, 2, 56)
  local top, lw, ts = na > 0 and 4 + na or 3, 54, m.turtles
  -- Caps keep the biggest walls inside the 16 KB frame; tight is the fallback when they do not.
  local tight = m.tight
  local nt = math.min(#ts, math.max(3, math.min(h - top - 27, tight and 5 or 8)))
  -- x,y,z when it fits in the 15 cells before fuel, else x,z. An x,z over 14 cells moves the position,
  -- the branch and the end of the state left, so no coordinate is cut and a gap stays before fuel.
  local function at(t)
    local pos = U.st.at(t, true)
    return #pos > 15 and U.st.at(t) or pos
  end
  local cut = 0
  for i = 1, nt do
    if at(ts[i]) ~= U.st.at(ts[i], true) then cut = math.max(cut, math.min(10, #at(ts[i]) - 14)) end
  end
  C.section(2, top, lw, "TURTLES", #ts)
  for _, c in ipairs({ { 24 - cut, "position" }, { 40, "fuel" }, { 47, "ore" }, { 52, "seen" } }) do C.put(c[1], top + 1, c[2], "8") end
  U.st.rows(C, ts, nt, top + 2, function(t, y)
    U.st.turtle(C, 2, y, t, lw, nil, nil, cut)
    C.put(24 - cut, y, at(t), "0")
    C.put(39, y, string.format("%5s", tostring(t.fuel or "-")), t.fuel and t.fuel < 500 and "1" or "0")
    C.put(46, y, string.format("%4s", tostring(t.ore or "-")), "0")
    C.put(52, y, U.age(t.ago), t.lost and "e" or t.ago >= 120000 and "1" or "8")
  end)
  local jy = top + nt + 3
  C.section(2, jy, lw, "JOBS")
  U.st.jobs(C, 2, jy + 1, m, true)
  local fy, d = jy + 4, m.disk
  C.section(2, fy, 26, "TODAY")
  for i, r in ipairs(U.st.today(m, 5)) do C.leader(2, fy + i, 26, r[1], r[2], r[3]) end
  C.section(31, fy, 25, "SERVER")
  U.st.disk(C, 31, fy + 1, 25, d, d and string.format("%.1f/%d MB", d.used / 1e6, math.floor(d.cap / 1e6)))
  C.leader(31, fy + 2, 25, "leases", m.leases)
  C.leader(31, fy + 3, 25, "displays", #m.displays)
  C.leader(31, fy + 4, 25, "up", m.server.up)
  local dy, ds = fy + 7, m.drops
  local nd = math.min(#ds, 5)
  C.section(2, dy, lw, "DROPS", #ds)
  U.st.rows(C, ds, nd, dy + 1, function(p, y)
    local c = p.broken and "e" or "0"
    C.put(2, y, p.broken and U.g.cross or U.g.bullet, c)
    C.put(4, y, tostring(p.id), c)
    C.put(7, y, p.kind:sub(1, 9), c)
    C.put(17, y, U.st.at(p, true), "8")
    C.put(31, y, p.broken and "broken" or "ok", p.broken and "e" or "8")
    C.hit("drop:" .. p.id, 2, y, 35, 1)
  end)
  local ey = dy + nd + 2
  local bottom = ey - 2
  if ey < h and #m.events > 0 then
    local ne = math.min(#m.events, h - ey, tight and 5 or 8)
    C.section(2, ey, lw, "EVENTS")
    U.st.events(C, 2, ey + 1, lw, m, ne, 8)
    bottom = ey + ne
  end
  local rx, rw, sy = 60, w - 60, 3
  if m.thumb then
    local th = math.min(h - 12, tight and 26 or 30)
    pcall(m.thumb, C, rx, 3, math.min(rw, tight and 40 or 48), th)
    sy = 3 + th + 1
  end
  local ls = m.displays
  C.section(rx, sy, rw, "DISPLAYS", #ls)
  local shown = math.min(#ls, math.max(0, h - sy))
  for i = 1, shown do
    local s, y = ls[i], sy + i
    C.put(rx, y, string.format("%2d", s.id), "0")
    C.put(rx + 4, y, s.role:sub(1, 7), "0")
    C.put(rx + 12, y, s.size, "8")
    C.put(rx + 21, y, U.age(s.ago), s.ago < 10000 and "8" or "1")
  end
  -- The rule stops with the content: every ruled row costs about 140 frame bytes.
  for y = 3, math.max(bottom, sy + shown) do C.put(58, y, "|", "c") end
end
-- One column for 24 to 95 cells and 14 or more rows: pocket, 39x19 and the 51x19 terminal.
U.st.column = function(C, m)
  local w, h = C.w, C.h
  local wide = w >= 36
  C.bar(m.name or "STATUS", nil, nil, m.time)
  local na = U.st.flags(C, 3, m, h >= 17 and 2 or 1, not wide)
  local top = na > 0 and 4 + na or 3
  local blocks = wide and { "jobs", "facts" } or { "today", "server" }
  while #blocks > 0 and h - top - 4 * #blocks < 1 do blocks[#blocks] = nil end
  local ts = m.turtles
  local nt = math.min(#ts, h - top - 4 * #blocks)
  C.section(2, top, w - 2, "TURTLES", #ts)
  U.st.rows(C, ts, nt, top + 1, function(t, y)
    U.st.turtle(C, 2, y, t, w - 2)
    if wide then C.put(24, y, U.st.at(t):sub(1, w - 25), t.lost and "e" or "8") end
  end)
  local y = top + nt + 2
  for _, b in ipairs(blocks) do
    if b == "jobs" then
      C.section(2, y, w - 2, "JOBS")
      U.st.jobs(C, 2, y + 1, m)
    elseif b == "facts" then
      local lw = math.floor((w - 5) / 2)
      local rx = 2 + lw + 3
      C.section(2, y, lw, "TODAY")
      for i, r in ipairs(U.st.today(m, 2)) do C.leader(2, y + i, lw, r[1], r[2], r[3]) end
      C.section(rx, y, w - rx, "SERVER")
      U.st.disk(C, rx, y + 1, w - rx, m.disk)
      C.leader(rx, y + 2, w - rx, "leases", m.leases)
    elseif b == "today" then
      C.section(2, y, w - 2, "TODAY")
      for i, r in ipairs(U.st.today(m, 2)) do C.leader(2, y + i, w - 2, r[1], r[2], r[3]) end
    else
      C.section(2, y, w - 2, "SERVER")
      U.st.disk(C, 2, y + 1, w - 2, m.disk)
      C.put(2, y + 2, (#m.displays .. " displays " .. U.g.dot .. " " .. m.leases .. " leases"):sub(1, w - 2), "8")
    end
    y = y + 4
  end
  if h - y >= 1 and #m.events > 0 then
    C.section(2, y, w - 2, "EVENTS")
    U.st.events(C, 2, y + 1, w - 2, m, h - y, w >= 30 and 5 or 0)
  end
end
-- Under 24 cells or 14 rows: the role name and the leaders that fit.
U.st.tiny = function(C, m)
  local w, h = C.w, C.h
  local name = m.name or "STATUS"
  C.bar(name, nil, nil, w >= #name + 9 and m.time or "")
  local y = h >= 6 and 3 or 2
  local na = U.st.flags(C, y, m, h >= 9 and 2 or h >= 6 and 1 or 0, true, 1)
  if na > 0 then y = y + na + 1 end
  local lost, mi, t, lu = 0, m.mining, m.today, m.lumber
  for _, row in ipairs(m.turtles) do if row.lost then lost = lost + 1 end end
  local rows = { { "turtles", tostring(#m.turtles), lost > 0 and "e" or "0" } }
  if mi then
    local running = mi.state == "running"
    rows[#rows + 1] = { "mining", running and (mi.done .. "/" .. mi.total) or mi.state, running and "0" or "8" }
  end
  rows[#rows + 1] = { "ore", t and tostring(t.ore) or "-", t and "0" or "8" }
  rows[#rows + 1] = { "logs", t and tostring(t.logs) or "-", t and "0" or "8" }
  local pct, fg = U.st.diskValue(m.disk)
  rows[#rows + 1] = { "disk", pct, fg }
  if lu then rows[#rows + 1] = { "trees", lu.ready .. "/" .. lu.spots, "0" } end
  for _, r in ipairs(rows) do
    if y > h then break end
    C.leader(2, y, w - 2, r[1], r[2], r[3])
    if r[1] == "disk" then C.hit("disk", 2, y, w - 2, 1) end
    y = y + 1
  end
end
U.status = function(model, w, h)
  local C = U.canvas(w, h)
  local m = {}
  for k, v in pairs(model) do m[k] = v end
  m.turtles, m.drops, m.events = m.turtles or {}, m.drops or {}, m.events or {}
  m.displays, m.leases, m.time = m.displays or {}, m.leases or 0, m.time or ""
  m.server = m.server or { id = "?", up = "-" }
  if w >= 96 and h >= 32 then U.st.wall(C, m)
  elseif w >= 52 and h >= 22 then U.st.room(C, m)
  elseif w >= 24 and h >= 14 then U.st.column(C, m)
  else U.st.tiny(C, m) end
  return C.frame()
end
local function finite(n)
  return type(n) == 'number' and n == n and n > -math.huge and n < math.huge
end
U.branchProgress = function(job, row)
  local p, home = row.pose, job.home
  if row.branch == nil or not p or not home then return 0, job.length or 0 end
  if type(p) ~= 'table' or type(home) ~= 'table' then return nil, job.length or 0 end
  local d = ({[0]={0,-1},{1,0},{0,1},{-1,0}})[home.facing or 0]
  local length = math.max(0, job.length or 0)
  if not d or not finite(p.x) or not finite(p.y) or not finite(p.z)
      or not finite(home.x) or not finite(home.z) then return nil, length end
  local dug = row.state == 'done' and length or (p.x-home.x)*(-d[2])+(p.z-home.z)*d[1]
  return math.max(0, math.min(length, dug)), length
end
U.progress = function(c, x, y, width, done, total, color)
  c.fill(x,y,width,1,'c')
  local n = total > 0 and math.floor(width*math.max(0,math.min(1,done/total))) or 0
  if n > 0 then c.fill(x,y,n,1,color or 'b') end
end
U.pocketHeader = function(c, title)
  c.header(title, '')
  c.button(c.w-9,2,5,'MORE','generic','7',1)
  c.button(c.w-3,2,4,'MAP','map','9',1)
end
U.alert = function(model, w, h)
  local C = U.canvas(w,h,'e')
  local a = model.takeover or {}
  C.center(1,w,4,'ALERT'); C.big(1,7,w,tostring(a.count or #model.alerts),'e')
  C.center(1,w,12,(a.text or model.alert or ''):upper())
  C.center(1,w,14,a.detail or '')
  C.center(1,w,16,a.sub or '')
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
-- Line digits draw "-" as the middle stroke alone: a pair code not issued yet reads "------".
U.segments["-"] = "g"
-- Job screens (S3); docs/ui/schematic/kit.py has the same three calls.
-- Header with tabs: the full labels when they fit beside the right word, then the short labels,
-- then without the right word. active is the tab's index. Returns whether the right word shows.
U.roleBar = function(C, name, tabs, short, active, right, rfg)
  right = right or ""
  local function last(list)
    local x = 2 + #name + 2
    for _, t in ipairs(list) do x = x + #t + 3 end
    return x
  end
  if last(tabs) + #right + 2 > C.w then tabs = short end
  if last(tabs) + #right + 2 > C.w then right = "" end
  C.bar(name, tabs, tabs[active], right, rfg)
  return right ~= ""
end
-- - value +: chips with ids id- and id+ around a value centred in vw cells. Returns the next column.
U.stepper = function(C, x, y, value, id, vw)
  vw = vw or 8
  C.chip(x, y, "-", id .. "-")
  value = tostring(value):sub(1, vw)
  C.put(x + 5 + math.floor((vw - #value) / 2), y, value, "0")
  return C.chip(x + 6 + vw, y, "+", id .. "+")
end
-- Screen-wide chips of equal width over columns 2 to w-1; items are { label, id, kind }.
U.actions = function(C, y, items, gap)
  gap = gap or 1
  local bw = math.floor((C.w - 2 - gap * (#items - 1)) / #items)
  for i, item in ipairs(items) do C.chip(2 + (i - 1) * (bw + gap), y, item[1], item[2], item[3], bw) end
end
-- Two-tap controls. state is the caller's table; state.confirm holds the armed key and
-- state.confirmAt when it armed. The caller passes every tap: tapped is the key of the two-tap
-- control hit, or nil for any other tap. The first tap on a key arms it, a second within window
-- (5 s) returns true, and any other tap disarms.
U.confirm = function(state, tapped, now, window)
  if state.confirm and now - (state.confirmAt or now) > (window or 5000) then state.confirm = nil end
  if tapped == nil then state.confirm = nil return false end
  if state.confirm == tapped then state.confirm = nil return true end
  state.confirm, state.confirmAt = tapped, now
  return false
end
-- The chip for a two-tap control: CONFIRM in coral while key is armed, else label as kind.
U.confirmChip = function(state, key, label, id, kind)
  if state.confirm == key then return { 'CONFIRM', id, 'stop' } end
  return { label, id, kind }
end
local T = {}
T.pose = function(p)
  if type(p) ~= 'table' or not finite(p.x) or not finite(p.y) or not finite(p.z) then return '-' end
  return string.format('%s,%s,%s %s',p.x,p.y,p.z,({[0]='N','E','S','W'})[p.facing or 0] or '?')
end
T.draft = function(p)
  p = type(p) == 'table' and p or {}
  local out = {}
  for _,axis in ipairs({'x','y','z'}) do
    local n = p[axis]
    out[axis] = finite(n) and n % 1 == 0 and math.abs(n) < 30000000 and n or 0
  end
  out.facing = finite(p.facing) and p.facing % 1 == 0 and p.facing >= 0 and p.facing <= 3 and p.facing or 0
  return out
end
-- Turtle details in route A (docs/ui/schematic/other.py turtle): the state word in the header, an
-- error flag, leaders, branch or spot progress, then the job's chips with BACK on the last row, where
-- D.turtleInput finds it even when composing fails.
T.render = function(w,h,selection,row,now)
  local c = U.canvas(w,h)
  row = row or {}
  local gap, lw, name = h >= 16 and 1 or 0, math.min(w - 2, 36), 'TURTLE #'..selection.id
  if selection.draft then
    local p = T.draft(selection.draft)
    c.bar(name, nil, nil, row.uncertain and 'pose ?' or '', 'e')
    local y = 2 + gap
    c.section(2, y, w - 2, 'POSE', T.pose(p), '0')
    for i,axis in ipairs({'x','y','z','facing'}) do
      local ry = y + gap + 1 + (i - 1) * (h >= 19 and 2 or 1)
      local value = axis == 'facing' and ({[0]='N','E','S','W'})[p.facing] or tostring(p[axis])
      c.put(2, ry, axis, '8')
      c.chip(w - 15, ry, '-', 'pose:'..axis..':-1')
      c.put(w - 12 + math.floor((9 - #value) / 2), ry, value, '0')
      c.chip(w - 3, ry, '+', 'pose:'..axis..':1')
    end
    U.controlRows(c, {U.confirmChip(selection, 'add', 'RE-ADD', 'turtle-save', 'primary')},
      {'BACK', 'turtle-cancel', 'plain'})
    return c.frame()
  end
  local state = row.uncertain and 'pose ?' or tostring(row.state or 'unassigned')
  local fg = row.uncertain and 'e' or row.state and U.tone(state) or '8'
  if #state > w - #name - 5 then state = state:match('%S+'):sub(1, math.max(0, w - #name - 5)) end
  c.bar(name, nil, nil, state, fg)
  local items, role = {}, row.role
  local assigned = role == 'mining' or role == 'lumber'
  if assigned then items[#items+1] = {role == 'mining' and 'PARK ALL' or 'PARK', 'turtle-park', 'plain'} end
  if role == 'mining' then
    items[#items+1] = U.confirmChip(selection, 'remove', 'REMOVE', 'turtle-remove', 'stop')
  end
  if assigned and row.uncertain then items[#items+1] = {'RE-ADD', 'turtle-add', 'primary'} end
  local top = U.controlRows(c, items, {'BACK', 'turtle-back', 'plain'})
  local y, bottom = 2 + gap, top - 1 - gap
  local retry = row.retry and ('retry '..math.max(0, math.ceil((row.retry - now) / 1000))..'s') or ''
  -- The countdown leads on its own row, so a long error cannot push it out.
  if row.error or retry ~= '' then
    y = y + U.flagLines(c, 2, y, w - 2, row.error or '', retry, retry ~= '' and 3 or 2, true) + gap
  end
  local slots, count = 0, 0
  for _,item in pairs(row.inv or {}) do slots = slots + 1 count = count + (item.count or 0) end
  local fuel = row.fuel
  local facts = {
    {'pose', row.uncertain and '?' or T.pose(row.pose), row.uncertain and 'e'},
    {'fuel', tostring(fuel or '-'), type(fuel) == 'number' and fuel < 64 and '1'},
    {'inventory', slots..'/16 '..U.g.dot..' '..count},
    {'lease', tostring(row.lease or '-')},
    {'step', tostring(row.step or '-')},
    {'ore', tostring(row.ore or 0)},
    {'seen', row.seen and (math.max(0, math.floor((now - row.seen) / 1000))..'s') or '-'},
  }
  local shown = math.max(0, math.min(#facts, bottom - y + 1 - (row.total and 1 + gap or 0)))
  for i = 1, shown do
    local f = facts[i]
    c.leader(2, y + i - 1, lw, f[1], f[2], f[3] or (f[2] == '-' and '8' or '0'))
  end
  if row.total then
    local py = y + shown + gap
    local label = role == 'lumber' and 'spots' or 'b'..(tonumber(row.branch) and row.branch + 1 or '-')
    c.put(2, py, label, '8')
    local x = 2 + #label + 1
    if row.done == nil then c.put(x, py, '-/'..row.total, '0')
    else
      local frac = row.done..'/'..row.total
      c.progress(x, py, math.max(1, math.min(12, w - 1 - x - #frac)), row.done, row.total)
    end
  end
  return c.frame()
end
U.turtle = T
-- Group other (RA2): Build, the health pages and turtle details in route A. docs/ui/schematic/other.py
-- has the same calls and makes their fixtures.
-- Word wrap; a word longer than the width is cut. The twin of pocket.wrap.
U.wrap = function(text, width)
  local out, line = {}, ""
  width = math.max(1, width)
  for word in tostring(text):gmatch("%S+") do
    while #word > width do
      if line ~= "" then out[#out + 1], line = line, "" end
      out[#out + 1], word = word:sub(1, width), word:sub(width + 1)
    end
    if line == "" then line = word
    elseif #line + 1 + #word <= width then line = line .. " " .. word
    else out[#out + 1], line = line, word end
  end
  if line ~= "" then out[#out + 1] = line end
  return out
end
-- The text cut to width at the last space that fits, or mid-word when one word is longer.
U.fit = function(text, width)
  text = tostring(text)
  if #text <= width then return text end
  return text:sub(1, width + 1):match("^(.*%S)%s") or text:sub(1, math.max(0, width))
end
-- ! and the text wrapped over at most n rows, ... marking a cut. The detail is muted after the text
-- when it fits, else on the next row; with first it takes row 1 alone. Returns the rows drawn.
U.flagLines = function(C, x, y, width, text, detail, n, first)
  local lines, room, dy, dx = U.wrap(text or "", width - 2), width - 2, nil, nil
  local lead = first and detail and detail ~= ""
  if lead then table.insert(lines, 1, ""); dy, dx = 1, 0 end
  if #lines > n then
    while #lines > n do lines[#lines] = nil end
    local last = lines[n]
    if last ~= "" then lines[n] = (#last + 3 <= room and last or U.fit(last, room - 3)) .. "..." end
  end
  if detail and detail ~= "" and not lead then
    local last = lines[#lines]
    if last and #last + 1 + #detail <= room then dy, dx = #lines, #last + 1
    elseif #lines < n then dy, dx = #lines + 1, 0; lines[dy] = "" end
  end
  if #lines == 0 then return 0 end
  C.put(x, y, "!", "e")
  for i, line in ipairs(lines) do C.put(x + 2, y + i - 1, line, "0") end
  if dy then C.put(x + 2 + dx, y + dy - 1, detail, "8") end
  return #lines
end
-- Tab groups from column 1, the active tab on the panel colour, a hairline after the last tab of a
-- row. A group that does not fit beside the one before starts the next row; reserve keeps the right
-- end of row 1 free for a visited page's x chip. Tabs are { label, id, accent? }: accent colours the
-- label's last word (a count). Returns the last tab row.
U.tabRows = function(C, groups, active, reserve)
  local x, y = 1, 1
  for i, group in ipairs(groups) do
    local width = 0
    for _, t in ipairs(group) do width = width + #t[1] + 2 end
    if i > 1 and x + 2 + width - 1 > C.w - (y == 1 and reserve or 0) then
      C.rule(x + 1, y, C.w - 1)
      x, y = 1, y + 1
    elseif i > 1 then x = x + 2 end
    for _, t in ipairs(group) do
      local on = t[2] == active
      C.put(x, y, " " .. t[1] .. " ", on and "0" or "8", on and "7" or "f")
      if t[3] then
        local word = t[1]:match("%S+$")
        C.put(x + 1 + #t[1] - #word, y, word, t[3])
      end
      C.hit(t[2], x, y, #t[1] + 2, 1, t[1])
      x = x + #t[1] + 2
    end
  end
  C.rule(x + 1, y, C.w - 1)
  return y
end
-- Paging on row y: a muted note, then the left and right chips at the right end; a chip with
-- nowhere to go is muted.
U.pager = function(C, y, note, back, forward)
  C.chip(C.w - 7, y, U.g.left, "prev", back and "plain" or "muted")
  C.chip(C.w - 3, y, U.g.right, "next", forward and "plain" or "muted")
  if note and note ~= "" then C.put(C.w - 8 - #note, y, note, "8") end
end
-- Chips flowed over the last rows from column 2, then back right-aligned on the last row, beside the
-- last chips when it fits. Chips are { label, id, kind }. Returns the first control row.
U.controlRows = function(C, items, back)
  local rows, x = { {} }, 2
  for _, item in ipairs(items) do
    if x + #item[1] + 2 > C.w and #rows[#rows] > 0 then rows[#rows + 1], x = {}, 2 end
    local row = rows[#rows]
    row[#row + 1] = item
    x = x + #item[1] + 3
  end
  local bx = C.w - #back[1] - 2
  if #rows[#rows] > 0 and x > bx then rows[#rows + 1] = {} end
  local top = C.h - #rows + 1
  for i, row in ipairs(rows) do
    local cx = 2
    for _, item in ipairs(row) do cx = C.chip(cx, top + i - 1, item[1], item[2], item[3]) + 1 end
  end
  C.chip(bx, C.h, back[1], back[2], back[3])
  return top
end
return U
