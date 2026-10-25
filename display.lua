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
  lastFrame = math.floor(os.clock() * 1000 + 0.5),
  retryAt = 0,
  lastRetry = nil,
  history = {},
  recall = nil,
  stock = {},
  out = nil,
  proto = dofile("so-proto.lua"),
  store = dofile("so-store.lua"),
}

C.now = function() return math.floor(os.clock() * 1000 + 0.5) end

-- retryInput (so-display.cfg, default off): in NO SERVER any key or tap retries at once.
local cfg = C.store.read and C.store.read("so-display.cfg")
C.retryInput = type(cfg) == "table" and cfg.retryInput == true

C.pair = dofile("so-pair.lua")
C.pair.open(C.proto, C.store, C.now)

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
  C.retryAt = C.now() + seconds * 1000
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
  local body = { w = C.w, h = C.h >= 3 and C.h - 1 or C.h, fullH = C.h, keyboard = not C.monitor }
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
      -- A label is drawn only on a blank button; drawn chips and tabs already show theirs.
      local row = type(C.rows[b.y]) == "table" and C.expand(C.rows[b.y]) or ""
      local span = type(b.w) == "number" and b.w > #label and b.w or #label
      if label ~= "" and not row:sub(b.x, b.x + span - 1):find("%S") then
        if out.setCursorPos then out.setCursorPos(b.x, b.y) end
        if out.write then out.write(label) end
      end
    end
  end
  C.drawInput()
  if C.phase == "stale" then
    C.drawStale()
    if C.out.setPaletteColour and not C.repaint then C.repaint = os.startTimer(1) end
  end
end

-- No server: the last picture stays and only the palette changes, to this grey ramp (so-ui.lua U.stale);
-- slot 2 carries the one coral row.
C.stale = { [0] = 0x6A7690, 0x46526C, 0xFF6B5E, 0x46526C, 0x46526C, 0x46526C, 0x46526C, 0x18223A,
  0x46526C, 0x46526C, 0x46526C, 0x46526C, 0x222B3E, 0x46526C, 0x46526C, 0x0B111C }

-- The coral row: NO SERVER, the time since the last frame, and the next retry at the right.
C.drawStale = function()
  local out = C.out
  if not out then return end
  local grey = out.setPaletteColour ~= nil
  if grey then for i = 0, 15 do out.setPaletteColour(2 ^ i, C.stale[i]) end end
  local secs = math.max(0, math.floor((C.now() - C.lastFrame) / 1000))
  local clock = math.floor(secs / 60) .. string.format(":%02d", secs % 60)
  local retry = math.max(0, math.ceil((C.retryAt - C.now()) / 1000))
  local right = "retry in " .. retry .. " s"
  if 13 + #clock + 1 + #right > C.w - 1 then right = retry .. "s" end
  if 13 + #clock + 1 + #right > C.w - 1 then right = "" end
  local text = (" NO SERVER  " .. clock .. string.rep(" ", C.w)):sub(1, C.w - #right - 1) .. right .. " "
  text = text:sub(1, C.w)
  local bg = grey and "2" or "e"
  out.setCursorPos(1, 1)
  C.paint(text, string.rep("f", #text), string.rep(bg, #text))
end

C.drawInput = function()
  local draw = function(out, width, height, room)
    if out.setCursorPos then out.setCursorPos(1, height) end
    local text = "> " .. C.typed:sub(-math.max(1, room - 2))
    text = text:sub(1, room)
    if out.write then out.write(text .. string.rep(" ", width - #text)) end
  end
  -- A kit frame fills every row; the typed line covers its last row only while there is one.
  if C.h > C.viewH or C.typed ~= "" then
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
  C.lastFrame = C.now()
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
      "",
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
  -- Every keyed retry, in any phase, waits out the shared 2 s limit.
  if C.server and C.pair.key(C.server) and C.retryWait() > 0 then
    C.arm(C.retryWait() / 1000)
    return
  end
  C.openModems()
  C.output()
  if not C.server or (not C.pair.key(C.server) and C.digits == "") then
    C.server = rednet.lookup("so", "server")
  end
  if C.server and C.pair.key(C.server) then
    local was = C.phase
    C.phase = C.repair and "pairing" or "stale"
    C.sendHello()
    C.sendSub()
    C.lastRetry = C.now()
    -- Still stale: the picture is already there, only its row changes.
    if C.repair then C.drawPair() elseif was == "stale" then C.drawStale() else C.clipDraw() end
  else
    C.phase = "pairing"
    C.drawPair()
  end
  C.attempt = C.attempt + 1
  C.arm(C.waitSeconds(os.getComputerID(), C.attempt))
end

-- With retryInput on, timers and input share one hello/view.sub pair per 2 s.
C.retryWait = function()
  if not C.retryInput or not C.lastRetry then return 0 end
  return math.max(0, C.lastRetry + 2000 - C.now())
end

-- Steps through sent lines; Down past the newest clears the line.
C.recallStep = function(step)
  if not C.recall and step > 0 then return end
  local n = (C.recall or #C.history + 1) + step
  if n < 1 then return end
  if n > #C.history then
    C.recall, C.typed = nil, ""
  else
    C.recall, C.typed = n, C.history[n]
  end
  C.clipDraw()
end

C.join = function()
  C.pairError = "Pairing..."
  C.drawPair()
  local ok, reason = C.pair.join(C.digits, C.server)
  C.attempt = 0
  if ok then
    C.digits = ""
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
      if C.phase == "stale" then
        C.drawStale()
        C.repaint = os.startTimer(1)
      end
    elseif ev == "timer" and a == C.timer then
      if C.phase == "live" then C.markStale() else C.retry() end
    elseif C.phase == "stale" and C.retryInput
      and (ev == "key" or ev == "char" or ev == "monitor_touch" or ev == "mouse_click") then
      -- A retry only re-sends hello to the saved server; it never changes C.server or keys.
      if C.retryWait() == 0 then C.retry() end
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
      -- A failed code stays for Backspace; a seventh digit starts a new code.
      C.digits = #C.digits < 6 and C.digits .. a or a
      C.drawPair()
      if #C.digits == 6 then C.join() end
    elseif ev == "paste" and C.phase == "pairing" and type(a) == "string" then
      -- Pasted digits join the code like typed ones; anything else, or a code over six, is ignored.
      local p = a:gsub("%s", "")
      if p:match("^%d+$") and #p <= 6 then
        C.digits = #C.digits + #p <= 6 and C.digits .. p or p
        C.drawPair()
        if #C.digits == 6 then C.join() end
      end
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
      C.typed, C.recall = C.typed .. a, nil
      C.clipDraw()
    elseif ev == "paste" and C.phase == "live" and type(a) == "string" then
      C.typed, C.recall = (C.typed .. a:gsub("%c", "")):sub(1, 64), nil
      C.clipDraw()
    elseif ev == "key" and (a == 265 or a == 200 or a == 264 or a == 208) and C.phase == "live" then
      C.recallStep((a == 265 or a == 200) and -1 or 1)
    elseif ev == "key" and (a == 259 or a == 14) and C.phase == "live" then
      C.typed, C.recall = C.typed:sub(1, -2), nil
      C.clipDraw()
    elseif ev == "key" and (a == 257 or a == 28) and C.phase == "live" and C.typed ~= "" then
      local text = C.typed
      C.typed, C.recall = "", nil
      if C.history[#C.history] ~= text then C.history[#C.history + 1] = text end
      if #C.history > 20 then table.remove(C.history, 1) end
      C.send("input", { text = text, x = 1, y = 1 })
      C.clipDraw()
    elseif ev == "monitor_resize" or ev == "term_resize" or ev == "peripheral" or ev == "peripheral_detach" then
      if ev == "peripheral" or ev == "peripheral_detach" then C.openModems() end
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
