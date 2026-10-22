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
  local w, h = 1, 1
  if C.out and C.out.getSize then w, h = C.out.getSize() end
  if type(w) ~= "number" or w < 1 then w = 1 end
  if type(h) ~= "number" or h < 1 then h = 1 end
  C.w = math.floor(w)
  C.h = math.floor(h)
  C.viewH = C.h >= 3 and C.h - 1 or C.h
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
  local body = { w = C.w, h = C.viewH }
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

C.clipDraw = function()
  local out = C.out
  if not out then return end
  if out.clear then out.clear() end
  local n = #C.rows
  if n > C.viewH then n = C.viewH end
  for i = 1, n do
    local row = C.rows[i]
    local text = type(row) == "table" and type(row.text) == "string" and row.text or ""
    if #text > C.w then text = text:sub(1, C.w) end
    if out.setCursorPos then out.setCursorPos(1, i) end
    local fg, bg = "0", "f"
    if type(row) == "table" then fg, bg = row.fg, row.bg end
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
  if C.phase == "stale" then C.drawStale() end
end

C.drawStale = function()
  if C.w < 1 or C.h < 1 or not C.out then return end
  local word = "stale"
  if #word > C.w then word = word:sub(#word - C.w + 1) end
  if C.out.setCursorPos then C.out.setCursorPos(C.w - #word + 1, C.h) end
  if C.out.write then C.out.write(word) end
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
    if type(b) == "table" and b.y == y and type(b.x) == "number" and type(b.w) == "number"
      and x >= b.x and x < b.x + b.w then
      return b
    end
  end
end

C.onFrame = function(msg)
  local body = msg.body
  if type(body) ~= "table" then return end
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
  C.clipDraw()
  C.arm(C.waitSeconds(os.getComputerID(), C.attempt))
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
    if ev == "timer" and a == C.timer then
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
      C.output()
      if C.phase == "pairing" then C.drawPair() else C.sendHello(); C.clipDraw() end
    end
  end
end

C.output()
C.phase = "pairing"
C.drawPair()
C.retry()
C.loop()
