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
  C.header((size == 'P' or size == 'XS') and 'FLEET' or 'STATUS', tiles[8] and tiles[8].id=='broken' and '' or (size == 'XS' or size == 'P') and 'ok' or model.time or 'ok')
  local broken=tiles[8] and tiles[8].id=="broken" and tiles[8].value
  if broken and w>=26 then C.button(w-14,2,10,"BROKEN "..broken,"broken","e",1) end
  local function draw(index, x, y, width, height)
    local t = tiles[index]
    if not t then return end
    if index == 9 then
      C.button(math.max(2,x),y+1,math.max(0,math.min(w-1,x+width-1)-math.max(2,x)+1),'PAIR','pair','9',3)
    else
      C.tile(x,y,width,t.label,t.value,t.sub,t.bg,height)
      if t.id then C.hit(t.id,x,y,width,height) end
    end
    if index == 6 then C.hit("disk",math.max(2,x)+1,y+1,4,1) end
  end
  if size == 'P' then
    for i,index in ipairs({1,3}) do draw(index,1,4+(i-1)*8,w,7) end
    U.pocketHeader(C, 'FLEET')
    C.button(1,h,w,'PANEL','panel','7',1)
  elseif size == 'XS' then
    draw((model.page or 0) % #tiles+1,1,3,w,6)
    C.button(1,h-1,w,'NEXT','next','7',1)
    C.button(1,h,w,'MORE','generic','7',1)
  else
    C.alert(model.alert and ('! '..model.alert) or nil)
    local cols = U.grid(w,h,size == 'T' and 4 or size == 'L' and 2 or nil)
    local indices = size == 'T' and {1,7,6,3} or size == 'L' and {1,3,4,6} or {1,2,3,4,5,6,7,8,9}
    local wanted = math.ceil(#indices/#cols)
    local navHeight = h >= 19 and h-7 >= wanted*8 and 3 or 1
    local navY = h-navHeight+1
    local height = navY-4 >= wanted*8-1 and 7 or 6
    local count = math.max(0,math.floor((navY-3)/(height+1)))
    for i,index in ipairs(indices) do
      local row,col = math.floor((i-1)/#cols),cols[(i-1)%#cols+1]
      if row < count then draw(index,col.x,4+row*(height+1),col.w,height) end
    end
    if size == 'T' then
      C.fill(2,12,w-2,1,'7'); C.put(2,12,'LOG')
      for i,line in ipairs(model.log or {}) do if 12+i < navY then C.put(2,12+i,line:sub(1,w-2)) end end
    end
    local labels = size == 'L' and {'MINING','SHOP','MORE'} or {'MINING','LUMBER','SHOP','MORE'}
    for i,col in ipairs(U.grid(w,h,#labels)) do
      local label=labels[i]
      C.button(col.x,navY,col.w,label,label == 'MORE' and 'generic' or label:lower(),label == 'SHOP' and 'a' or '7',navHeight)
    end
  end
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
T.render = function(w,h,selection,row,now)
  local c = U.canvas(w,h)
  row = row or {}
  local color = (row.uncertain or row.error) and 'e' or
    ({lost='e',range='e',waiting='1',['wait lane']='1',hold='1',stopped='c',done='b'})[row.state] or 'd'
  c.header('#'..selection.id, '')
  if selection.draft then
    local p = T.draft(selection.draft)
    c.put(2,3,'POSE '..T.pose(p))
    for i,axis in ipairs({'x','y','z','facing'}) do
      local y = 3+i*(h >= 19 and 3 or 1)
      local value = axis == 'facing' and ({[0]='N','E','S','W'})[p.facing] or p[axis]
      c.put(2,y,axis:upper()..' '..value)
      c.button(w-9,y,4,'-','pose:'..axis..':-1','7',1)
      c.button(w-4,y,4,'+','pose:'..axis..':1','7',1)
    end
    c.button(1,h-1,w,'RE-ADD','turtle-save',selection.confirm == 'add' and 'e' or '9',1)
    c.button(1,h,w,'BACK','turtle-cancel','7',1)
    return c.frame()
  end
  c.fill(1,3,w,1,color) c.put(2,3,row.uncertain and 'POSE ?' or tostring(row.state or 'unassigned'))
  local slots,items = 0,0
  for _,item in pairs(row.inv or {}) do slots=slots+1 items=items+(item.count or 0) end
  local lines = {
    {'POS '..(row.uncertain and '?' or T.pose(row.pose)),row.uncertain and 'e' or '7'},
    {'FUEL '..tostring(row.fuel or '-'),type(row.fuel)=='number' and row.fuel < 64 and '1' or 'd'},
    {'INV '..slots..'/16 '..items..' items','b'},
    {'LEASE '..tostring(row.lease or '-'),'7'},
    {'STEP '..tostring(row.step or '-')..'  ORE '..tostring(row.ore or 0),'7'},
    {'SEEN '..(row.seen and math.max(0,math.floor((now-row.seen)/1000))..'s' or '-'),'7'},
  }
  local bottom = h-2
  if h < 19 then
    lines[2][1] = 'FUEL '..tostring(row.fuel or '-')..'  INV '..slots..'/16'
    table.remove(lines,3)
  end
  for i,line in ipairs(lines) do
    local y = i+3
    if y < bottom then c.fill(1,y,w,1,line[2]) c.put(2,y,line[1]:sub(1,w-2)) end
  end
  local progressY = h >= 19 and 11 or 9
  local label = row.role == 'lumber' and 'SPOTS' or 'B'..tostring(row.branch or '-')
  if row.total then
    if row.done == nil then
      c.put(2,math.min(progressY,bottom),label..' -/'..row.total)
    elseif progressY <= bottom then
      U.progress(c,2,progressY,math.min(12,w-2),row.done or 0,row.total,'b')
      c.put(15,progressY,label..' '..(row.done or 0)..'/'..row.total)
    else
      c.put(2,9,label..' '..(row.done or 0)..'/'..row.total,'f','b')
    end
  end
  local errorText = row.error
  if row.retry then
    local retry = 'RETRY '..math.max(0,math.ceil((row.retry-now)/1000))..'s'
    errorText = errorText and (errorText..' '..retry) or retry
  end
  if errorText then
    local y = h >= 19 and 13 or 10
    local limit = bottom
    for first=1,#errorText,math.max(1,w-2) do
      if y <= limit then c.fill(1,y,w,1,'e') c.put(2,y,errorText:sub(first,first+w-3)) end
      y=y+1
    end
  end
  local buttons = {}
  local assigned = row.role == 'mining' or row.role == 'lumber'
  if assigned then buttons[#buttons+1]={row.role=='mining' and 'PARK ALL' or 'PARK','turtle-park','1'} end
  if row.role == 'mining' then buttons[#buttons+1]={'REMOVE','turtle-remove',selection.confirm=='remove' and 'e' or '7'} end
  if assigned and row.uncertain then buttons[#buttons+1]={'RE-ADD','turtle-add','9'} end
  for i,col in ipairs(U.grid(w,h,math.max(1,#buttons))) do
    local b=buttons[i]
    if b then c.button(col.x,h-1,col.w,b[1],b[2],b[3],1) end
  end
  c.button(1,h,w,'BACK','turtle-back','7',1)
  return c.frame()
end
U.turtle = T
return U
