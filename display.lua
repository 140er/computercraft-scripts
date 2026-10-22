-- display.lua - one client for a monitor or a pocket. The server picks the picture.

local C = {
  phase = "boot",
  server = nil,
  w = 1,
  h = 1,
  rows = {},
  buttons = {},
  typed = "",
  digits = "",
  pairError = nil,
  attempt = 0,
  timer = nil,
  lastFrame = os.epoch("utc"),
  retryAt = 0,
  stock = {},
  out = nil,
  proto = dofile("so-proto.lua"),
  store = dofile("so-store.lua"),
}

C.pair = dofile("so-pair.lua")
C.pair.open(C.proto, C.store)

local saved = C.store.store("so-keys", function(v)
  return type(v) == "table" and type(v.keys) == "table"
end, 200000).value
if saved then
  for id in pairs(saved.keys) do
    local n = tonumber(id)
    if n and n >= 0 and n % 1 == 0 and C.pair.key(n)
      and (not C.server or n < C.server) then C.server = n end
  end
end

C.openModems = function()
  local modems = { peripheral.find("modem") }
  for i = 1, #modems do
    rednet.open(peripheral.getName(modems[i]))
  end
end

C.output = function()
  local mon = peripheral.find("monitor")
  C.out = mon or term
  C.monitor = mon ~= nil
  C.outputKey = mon or "term"
  if mon and peripheral.getName then
    local ok, name = pcall(peripheral.getName, mon)
    if ok then C.outputKey = name end
  end
  if not C.stock[C.outputKey] then
    local palette = {}
    local get = term.nativePaletteColour or C.out.getPaletteColour
    if get then
      for i = 0, 15 do palette[i] = { get(2 ^ i) } end
    end
    C.stock[C.outputKey] = palette
  end
  local w, h = 1, 1
  if C.out and C.out.getSize then w, h = C.out.getSize() end
  if type(w) ~= "number" or w < 1 then w = 1 end
  if type(h) ~= "number" or h < 1 then h = 1 end
  C.w = math.floor(w)
  C.h = math.floor(h)
  C.viewH = C.fullFrame and C.h or (C.h >= 3 and C.h - 1 or C.h)
end

C.waitSeconds = function(id, attempt)
  local n = attempt
  if type(n) ~= "number" or n < 1 then n = 1 end
  n = math.floor(n)
  local base = 30
  if n <= 5 then
    base = 1
    local step = 1
    while step < n do
      base = base * 2
      step = step + 1
    end
  end
  local frac = ((id * 17 + n) % 50) / 100
  local gap = base * (0.5 + frac)
  if gap > 30 then gap = 30 end
  return gap
end

C.arm = function(seconds)
  if C.timer then os.cancelTimer(C.timer) end
  C.timer = os.startTimer(seconds)
  C.retryAt = os.epoch("utc") + seconds * 1000
end

C.send = function(kind, body)
  local key = C.pair.key(C.server)
  if not key then return end
  local msg = C.proto.build(key, kind, body)
  local wire = C.proto.encode(msg)
  if type(wire) ~= "table" then return end
  rednet.send(C.server, wire, "so")
end

C.sendHello = function()
  local body = { w = C.w, h = C.h >= 3 and C.h - 1 or C.h, fullH = C.h }
  local label = os.getComputerLabel()
  if type(label) == "string" and label ~= "" then body.label = label end
  C.send("hello", body)
end

C.sendSub = function()
  C.send("view.sub", {})
end

C.paint = function(text, fg, bg)
  local out = C.out
  if out.blit and out.isColor and out.isColor() and #text > 0 then
    if type(fg) ~= "string" or fg == "" then fg = "0" end
    if type(bg) ~= "string" or bg == "" then bg = "f" end
    if #fg == 1 then fg = string.rep(fg, #text) end
    if #bg == 1 then bg = string.rep(bg, #text) end
    fg = fg:sub(1, #text)
    bg = bg:sub(1, #text)
    if #fg == #text and #bg == #text then
      out.blit(text, fg, bg)
      return
    end
  end
  if out.write then out.write(text) end
end

C.expand = function(row)
  if type(row.runs) ~= "table" then return row.text or "", row.fg, row.bg end
  local fg, bg, width = {}, {}, 0
  for _, run in ipairs(row.runs) do
    if type(run) == "table" and type(run[1]) == "number" and run[1] > 0
      and run[1] % 1 == 0 and type(run[2]) == "string" and #run[2] == 1
      and type(run[3]) == "string" and #run[3] == 1 then
      local n = math.min(run[1], C.w - width)
      if n <= 0 then break end
      fg[#fg + 1], bg[#bg + 1] = string.rep(run[2], n), string.rep(run[3], n)
      width = width + n
    end
  end
  local text = row.text or ""
  return text .. string.rep(" ", math.max(0, width - #text)), table.concat(fg), table.concat(bg)
end

C.clipDraw = function()
  local out = C.out
  if not out then return end
  if out.clear then out.clear() end
  local n = #C.rows
  if n > C.viewH then n = C.viewH end
  for i = 1, n do
    local row = C.rows[i]
    local text, fg, bg = "", "0", "f"
    if type(row) == "table" then text, fg, bg = C.expand(row) end
    if #text > C.w then text = text:sub(1, C.w) end
    if out.setCursorPos then out.setCursorPos(1, i) end
    C.paint(text, fg, bg)
  end
  for i = 1, #C.buttons do
    local b = C.buttons[i]
    if type(b) == "table" and type(b.x) == "number" and type(b.y) == "number"
      and b.y >= 1 and b.y <= C.viewH and b.x >= 1 and b.x <= C.w then
      local label = type(b.label) == "string" and b.label or ""
      local room = C.w - b.x + 1
      if #label > room then label = label:sub(1, room) end
      if out.setCursorPos then out.setCursorPos(b.x, b.y) end
      if out.write then out.write(label) end
    end
  end
  C.drawInput()
  if C.phase == "stale" then
    C.drawStale()
    if C.out.setPaletteColour and not C.repaint then C.repaint = os.startTimer(1) end
  end
end

C.font = {
  ["0"] = ".###.#...##...##...##...##...#.###.",
  ["1"] = "..#...##....#....#....#....#...###.",
  ["2"] = ".###.#...#....#...#...#...#...#####",
  ["3"] = "####.....#....#.###.....#....#####.",
  ["4"] = "...#...##..#.#.#..#.#####...#....#.",
  ["5"] = "######....####.....#....##...#.###.",
  ["6"] = "..##..#...#....####.#...##...#.###.",
  ["7"] = "#####....#...#...#...#....#....#...",
  ["8"] = ".###.#...##...#.###.#...##...#.###.",
  ["9"] = ".###.#...##...#.####....#...#..##..",
  [":"] = "......##...##........##...##.......",
}

C.drawStale = function()
  if not C.out then return end
  local function draw(x, y, text, fg, bg)
    if y < 1 or y > C.h or x > C.w then return end
    if x < 1 then text = text:sub(2 - x); x = 1 end
    text = text:sub(1, C.w - x + 1)
    C.out.setCursorPos(x, y)
    C.paint(text, fg, bg)
  end
  for y = 1, C.h do
    local row = C.rows[y]
    local text, fg, bg = "", "0", "c"
    if type(row) == "table" then text, fg, bg = C.expand(row) end
    text = (text .. string.rep(" ", C.w)):sub(1, C.w)
    local f, b = {}, {}
    for x = 1, C.w do
      local old = type(bg) == "string" and (#bg == 1 and bg or bg:sub(x, x)) or ""
      local invert = text:byte(x) >= 128 and text:byte(x) <= 159 and ((old == "f" and type(fg) == "string"
          and (#fg == 1 and fg or fg:sub(x, x)) ~= "0"
          and (#fg == 1 and fg or fg:sub(x, x)) ~= "8") or old == "0")
      f[x], b[x] = invert and "c" or "0", invert and "0" or "c"
    end
    draw(1, y, text, table.concat(f), table.concat(b))
  end
  for _, button in ipairs(C.buttons) do
    if type(button.x) == "number" and type(button.y) == "number" and type(button.label) == "string" then
      draw(button.x, button.y, button.label, "0", "c")
    end
  end
  local x, y = math.floor((C.w - 21) / 2) + 1, math.floor((C.h - 7) / 2) + 1
  for r = 0, 6 do draw(x, y + r, string.rep(" ", 21), "f", "e") end
  local function center(text, row) draw(x + math.floor((21 - #text) / 2), row, text, "f", "e") end
  center("NO SERVER", y + 1)
  local seconds = math.max(0, math.floor((os.epoch("utc") - C.lastFrame) / 1000))
  local value = math.floor(seconds / 60) .. string.format(":%02d", seconds % 60)
  if #value > 7 then value = "9999:59" end
  for r = 0, 2 do
    local cx = x + math.floor((21 - #value * 3) / 2)
    for i = 1, #value do
      local glyph = C.font[value:sub(i, i)]
      for col = 0, 2 do
        local bits = 0
        for pixel = 0, 5 do
          local px, py = col * 2 + pixel % 2, r * 3 + math.floor(pixel / 2)
          if px < 5 and py >= 1 and py <= 7 and glyph:sub((py - 1) * 5 + px + 1, (py - 1) * 5 + px + 1) == "#" then
            bits = bits + 2 ^ pixel
          end
        end
        local inverse = bits >= 32
        draw(cx, y + 2 + r, string.char(128 + (inverse and 63 - bits or bits)), inverse and "e" or "f", inverse and "f" or "e")
        cx = cx + 1
      end
    end
  end
  center("since last frame", y + 5)
  local retry = math.max(0, math.ceil((C.retryAt - os.epoch("utc")) / 1000))
  draw(2, C.h - 1, "retrying in " .. retry .. " s", "0", "c")
  if not C.out.setPaletteColour then draw(C.w - 4, C.h, "stale", "0", "c") end
end

C.drawInput = function()
  local draw = function(out, width, height, room)
    if out.setCursorPos then out.setCursorPos(1, height) end
    local text = "> " .. C.typed:sub(-math.max(1, room - 2))
    text = text:sub(1, room)
    if out.write then out.write(text .. string.rep(" ", width - #text)) end
  end
  if C.h > C.viewH then
    local room = C.phase == "stale" and math.max(0, C.w - 6) or C.w
    draw(C.out, C.w, C.h, room)
  end
  if C.out ~= term then
    local w, h = term.getSize()
    draw(term, w, h, w)
  end
end

C.hit = function(x, y)
  if y < 1 or y > C.viewH then return end
  for i = #C.buttons, 1, -1 do
    local b = C.buttons[i]
    if type(b) == "table" and type(b.y) == "number" and y >= b.y and y < b.y + (b.h or 1)
      and type(b.x) == "number" and type(b.w) == "number"
      and x >= b.x and x < b.x + b.w then
      return b
    end
  end
end

C.onFrame = function(msg)
  local body = msg.body
  if type(body) ~= "table" then return end
  if C.out.setPaletteColour then
    for i = 0, 15 do
      local rgb = type(body.palette) == "table" and body.palette[i]
      if type(rgb) == "number" and rgb >= 0 and rgb <= 0xFFFFFF then
        C.out.setPaletteColour(2 ^ i, rgb)
      else
        local stock = C.stock[C.outputKey][i]
        if stock then C.out.setPaletteColour(2 ^ i, unpack(stock)) end
      end
    end
  end
  if C.monitor and C.out.setTextScale and (body.scale == 0.5 or body.scale == 1) then
    local w, h = C.w, C.h
    C.out.setTextScale(body.scale)
    C.output()
    if C.w ~= w or C.h ~= h then C.sendHello() end
  end
  C.fullFrame = type(body.palette) == "table"
  C.viewH = C.fullFrame and C.h or (C.h >= 3 and C.h - 1 or C.h)
  C.lastFrame = os.epoch("utc")
  C.rows = type(body.rows) == "table" and body.rows or {}
  C.buttons = type(body.buttons) == "table" and body.buttons or {}
  C.repair = nil
  C.digits = ""
  C.phase = "live"
  C.attempt = 0
  C.clipDraw()
  C.arm(10)
end

C.markStale = function()
  if C.phase == "stale" then return end
  C.phase = "stale"
  C.attempt = 1
  C.arm(C.waitSeconds(os.getComputerID(), C.attempt))
  C.clipDraw()
end

C.drawPair = function()
  local draw = function(out)
    if not out then return end
    local w, h = out.getSize()
    if out.clear then out.clear() end
    local lines = {
      C.repair and "Old key kept. Pair again?" or "Pair a new client",
      "Pair: press P on the server, then type the 6-digit code here",
      C.pairError or (C.server and "Ready for code" or "Looking for server..."),
      "Code: " .. C.digits,
    }
    local y = 1
    for _, line in ipairs(lines) do
      repeat
        if y > h then return end
        out.setCursorPos(1, y)
        out.write(line:sub(1, w))
        line, y = line:sub(w + 1), y + 1
      until line == ""
    end
  end
  draw(C.out)
  if C.out ~= term then draw(term) end
end

C.retry = function()
  C.openModems()
  C.output()
  if not C.server or (not C.pair.key(C.server) and C.digits == "") then
    C.server = rednet.lookup("so", "server")
  end
  if C.server and C.pair.key(C.server) then
    C.phase = C.repair and "pairing" or "stale"
    C.sendHello()
    C.sendSub()
    if C.repair then C.drawPair() else C.clipDraw() end
  else
    C.phase = "pairing"
    C.drawPair()
  end
  C.attempt = C.attempt + 1
  C.arm(C.waitSeconds(os.getComputerID(), C.attempt))
end

C.join = function()
  C.pairError = "Pairing..."
  C.drawPair()
  local ok, reason = C.pair.join(C.digits, C.server)
  C.digits = ""
  C.attempt = 0
  if ok then
    C.pairError = nil
    C.repair = nil
    C.retry()
  else
    C.pairError = "Pair failed: " .. tostring(reason or "unknown")
    if not C.repair then C.server = nil end
    C.phase = "pairing"
    C.drawPair()
    C.arm(C.waitSeconds(os.getComputerID(), 1))
  end
end

C.loop = function()
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == C.repaint then
      C.repaint = nil
      if C.phase == "stale" then C.clipDraw() end
    elseif ev == "timer" and a == C.timer then
      if C.phase == "live" then C.markStale() else C.retry() end
    elseif ev == "rednet_message" and c == "so" and a == C.server and type(b) == "table" then
      if C.pair.repairHint(a, b, C.server) then
        C.repair = true
        C.phase = "pairing"
        C.drawPair()
      end
      local msg = C.proto.decode(b)
      local key = C.pair.key(C.server)
      if msg and msg.t == "view.frame" and key and C.proto.macOk(key, msg) then C.onFrame(msg) end
    elseif ev == "char" and C.phase == "pairing" and type(a) == "string" and a:match("^%d$") then
      C.digits = C.digits .. a
      C.drawPair()
      if #C.digits == 6 then C.join() end
    elseif ev == "key" and C.phase == "pairing" and (a == 259 or a == 14) then
      C.digits = C.digits:sub(1, -2)
      C.drawPair()
    elseif ev == "monitor_touch" or ev == "mouse_click" then
      local x, y = b, c
      local button = C.hit(x, y)
      if button and C.phase == "live" then
        C.typed = ""
        C.send("input", { id = button.id, x = x, y = y })
        C.clipDraw()
      end
    elseif ev == "char" and C.phase == "live" and type(a) == "string" and #C.typed < 64 then
      C.typed = C.typed .. a
      C.clipDraw()
    elseif ev == "key" and (a == 259 or a == 14) and C.phase == "live" then
      C.typed = C.typed:sub(1, -2)
      C.clipDraw()
    elseif ev == "key" and (a == 257 or a == 28) and C.phase == "live" and C.typed ~= "" then
      local text = C.typed
      C.typed = ""
      C.send("input", { text = text, x = 1, y = 1 })
      C.clipDraw()
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      C.openModems()
    elseif ev == "monitor_resize" or ev == "term_resize" then
      local outputKey, w, h = C.outputKey, C.w, C.h
      C.output()
      if C.phase == "pairing" then C.drawPair() else
        if C.outputKey ~= outputKey or C.w ~= w or C.h ~= h then C.sendHello() end
        C.clipDraw()
      end
    end
  end
end

C.output()
C.phase = "pairing"
C.drawPair()
C.retry()
C.loop()
