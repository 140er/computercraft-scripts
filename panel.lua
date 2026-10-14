-- panel.lua - base control panel for an advanced pocket computer (CC: Tweaked)
-- Needs a wireless or ender modem (ender = works from anywhere, also other dimensions).
--
--   panel            start
--   panel install    start automatically when the pocket computer turns on
--
-- Tabs (tap them, or keys 1-5):
--   Home   everything at a glance; tap a card to open it
--   Mine   the mining fleet through the hub: pick an ore, STOP / RECALL / RESUME,
--          session time, tap a turtle to give orders to that turtle only
--   Store  the storage room turtle: search, tap an item to order it, pause, resync
--   Wood   the lumber turtle: status, fuel and lava, pause / come home
--   Buddy  chat with Buddy, send it home or to a place it remembers
-- Update all (Home tab, tap twice): every bot fetches its latest version from GitHub.
-- Q quits.
--
-- What it talks to (each needs its own wireless or ender modem):
--   hub.lua (protocol "minearmy"), roomsorter.lua ("roomsorter"),
--   lumber.lua ("lumber"), buddy.lua ("buddy")

local args = { ... }
if args[1] == "install" then
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("panel")\n')
  h.close()
  print("The panel will now start when the pocket computer turns on.")
  return
end

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Put a wireless or ender modem on this pocket computer.", 0) end
rednet.open(peripheral.getName(modem))

local W, H = term.getSize()
local COLOR = term.isColour()

---------------------------------------------------------------------------
-- Devices and what they last told us
---------------------------------------------------------------------------
local DEV = {
  hub   = { proto = "minearmy", host = "hub", name = "Mine Army", poll = 2 },
  store = { proto = "roomsorter", name = "Storage", poll = 4 },
  wood  = { proto = "lumber", name = "Lumberjack", poll = 2 },
  buddy = { proto = "buddy", name = "Buddy", poll = 3 },
}
local DEV_ORDER = { "hub", "store", "wood", "buddy" }
for _, d in pairs(DEV) do d.seen = -1e9 d.asked = -1e9 end

local data = { hub = nil, store = nil, storeInfo = nil, wood = nil, buddy = nil }
local chatLog = {} -- { who =, text = }
local hubLeftAt = 0 -- os.clock() when the hub's session time came in

local function online(key)
  local d = DEV[key]
  local limit = (key == "store") and 25 or 15
  return d.id ~= nil and os.clock() - d.seen < limit
end

local function redrawSoon() os.queueEvent("panel_redraw") end

local toastText, toastUntil = nil, 0
local consoleSay -- set by the console further down: messages go there on its tab
local function toast(text, secs)
  if consoleSay and consoleSay(text) then return end
  toastText, toastUntil = tostring(text), os.clock() + (secs or 6)
  redrawSoon()
end

local function send(key, msg)
  local d = DEV[key]
  if not d.id then
    toast(d.name .. " not found yet. Is it running, with a wireless or ender modem?")
    return false
  end
  msg.rid = math.random(1, 1073741824)
  rednet.send(d.id, msg, d.proto)
  d.asked = os.clock()
  return msg.rid
end

local function ask(key)
  if key == "hub" then send("hub", { type = "panel" })
  elseif key == "store" then send("store", { cmd = "stock" })
  else send(key, { cmd = "status" }) end
end

-- Update all: every bot in range fetches its latest version from GitHub at a safe moment
-- (the hub also hands the new miner.lua to its turtles), then this pocket updates itself.
-- From the button it asks for a second tap first.
local updateTapped = -1e9
local function updateAll(sure)
  if not sure and os.clock() - updateTapped > 5 then
    updateTapped = os.clock()
    toast("Tap Update all again to update every bot and this panel from GitHub.", 5)
    return
  end
  rednet.broadcast({ type = "panel", cmd = "update" }, "minearmy")
  for _, p in ipairs({ "roomsorter", "lumber", "buddy" }) do rednet.broadcast({ cmd = "update" }, p) end
  sleep(1)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("Update sent to every bot.")
  print("Updating this panel...")
  if not fs.exists("update.lua") then
    shell.run("wget", "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/update.lua", "update.lua")
  end
  shell.run("update") -- reboots when there's a new version
  toast("Update sent. This panel was already up to date.", 5)
end

---------------------------------------------------------------------------
-- Text helpers
---------------------------------------------------------------------------
local function pretty(name)
  local s = (tostring(name):match(":(.+)$") or tostring(name)):gsub("_", " ")
  return s:sub(1, 1):upper() .. s:sub(2)
end

local function num(n)
  if n == "unlimited" then return "inf" end
  if type(n) ~= "number" then return "?" end
  if n == math.huge or n > 1e12 then return "inf" end
  if n >= 100000 then return string.format("%dk", math.floor(n / 1000)) end
  if n >= 10000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end

local function clock(sec)
  sec = math.max(0, math.floor(sec))
  local m = math.floor(sec / 60)
  if sec >= 3600 then return string.format("%d:%02d:%02d", math.floor(sec / 3600), m % 60, sec % 60) end
  return string.format("%d:%02d", m, sec % 60)
end

local function age(sec)
  if sec < 60 then return math.floor(sec) .. "s" end
  return math.floor(sec / 60) .. "m"
end

-- Split text into lines of at most w characters, on spaces where possible
local function wrap(text, w)
  local lines = {}
  for para in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      while #word > w do
        if #line > 0 then lines[#lines + 1] = line line = "" end
        lines[#lines + 1] = word:sub(1, w)
        word = word:sub(w + 1)
      end
      if #line == 0 then line = word
      elseif #line + 1 + #word <= w then line = line .. " " .. word
      else lines[#lines + 1] = line line = word end
    end
    lines[#lines + 1] = line
  end
  while #lines > 1 and lines[#lines] == "" do lines[#lines] = nil end
  return lines
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local buttons = {}
local function c(col, plain) if COLOR then return col end return plain or colors.white end

local function text(x, y, s, fg, bg)
  if y < 1 or y > H or x > W then return end
  s = tostring(s)
  if x < 1 then s = s:sub(2 - x) x = 1 end
  term.setCursorPos(x, y)
  term.setTextColor(c(fg or colors.white))
  term.setBackgroundColor(c(bg or colors.black, colors.black))
  term.write(s:sub(1, W - x + 1))
end

local function fill(y, bg, y2)
  for yy = y, y2 or y do text(1, yy, (" "):rep(W), nil, bg) end
end

local function right(y, s, fg, bg) text(W - #s + 1, y, s, fg, bg) end

-- A tappable area; label centred in it
local function button(x, y, w, label, fg, bg, action, h)
  h = h or 1
  for yy = y, y + h - 1 do text(x, yy, (" "):rep(w), fg, bg) end
  local l = tostring(label):sub(1, w)
  text(x + math.floor((w - #l) / 2), y + math.floor((h - 1) / 2), l, fg, bg)
  buttons[#buttons + 1] = { x1 = x, y1 = y, x2 = x + w - 1, y2 = y + h - 1, action = action }
end

-- A row of buttons sharing the width: list of { label, fg, bg, action }
local function buttonRow(y, list, x1, x2, gap)
  x1, x2, gap = x1 or 1, x2 or W, gap or 1
  local n = #list
  local w = math.floor((x2 - x1 + 1 - gap * (n - 1)) / n)
  local extra = (x2 - x1 + 1 - gap * (n - 1)) - w * n
  local x = x1
  for i, b in ipairs(list) do
    local bw = w + (i <= extra and 1 or 0)
    button(x, y, bw, b[1], b[2], b[3], b[4])
    x = x + bw + gap
  end
end

local function bar(x, y, w, frac, col)
  frac = math.max(0, math.min(1, frac or 0))
  local f = math.floor(w * frac + 0.5)
  text(x, y, (" "):rep(f), nil, col)
  text(x + f, y, (" "):rep(w - f), nil, colors.gray)
end

---------------------------------------------------------------------------
-- UI state
---------------------------------------------------------------------------
local TABS = { { "home", "Home" }, { "hub", "Mine" }, { "store", "Stor" }, { "wood", "Wood" }, { "buddy", "Bud" },
  { "console", ">_" } }
local TAB_COLOR = { home = colors.blue, hub = colors.orange, store = colors.cyan, wood = colors.green, buddy = colors.purple,
  console = colors.gray }
local ui = { tab = "home", selected = nil, scroll = 0, search = "", popup = nil, typing = false, turtleScroll = 0 }

local function setTab(t)
  ui.tab, ui.popup, ui.scroll = t, nil, 0
  if DEV[t] then ask(t) end
end

-- Ask for text on the bottom lines (Enter = done, empty = cancel)
local function prompt(label, default)
  ui.typing = true
  fill(H - 2, colors.gray, H)
  text(1, H - 2, " " .. label, colors.white, colors.gray)
  text(1, H - 1, " (Enter = OK, empty = cancel)", colors.lightGray, colors.gray)
  fill(H, colors.white)
  term.setCursorPos(2, H)
  term.setTextColor(colors.black)
  term.setBackgroundColor(colors.white)
  local s = read(nil, nil, nil, default)
  ui.typing = false
  redrawSoon()
  s = s and s:gsub("^%s+", ""):gsub("%s+$", "") or ""
  return s ~= "" and s or nil
end

---------------------------------------------------------------------------
-- Home
---------------------------------------------------------------------------
local function offlineLines(key)
  local d = DEV[key]
  if not d.id then return { { "Searching...", colors.lightGray } } end
  return { { "No answer for " .. age(os.clock() - d.seen), colors.red }, { "Is it running?", colors.lightGray } }
end

local function hubJob(h)
  if h.recallAll then return "RECALLED", colors.red end
  if h.target then
    local label = h.target
    for _, o in ipairs(h.ores or {}) do if o.key == h.target then label = o.label end end
    return "Mining " .. label, colors.lime
  end
  return "Stopped", colors.red
end

local function hubLeft(h)
  if not h or not h.left then return nil end
  return h.left - (os.clock() - hubLeftAt)
end

local function drawHome()
  text(2, 2, "Base control", colors.white)
  button(W - 11, 2, 12, "Update all", colors.white, colors.blue, function() updateAll() end)
  local cards = {
    { key = "hub", title = "MINE ARMY", lines = function()
      local h = data.hub
      local job, jc = hubJob(h)
      local left = hubLeft(h)
      local away, lost, n = 0, nil, 0
      for _, t in ipairs(h.turtles or {}) do
        n = n + 1
        if t.phase == "descending" or t.phase == "mining" or t.phase == "returning" then away = away + 1 end
        if t.phase == "lost" then lost = t.label end
      end
      local haul = {}
      for _, it in ipairs(h.haul or {}) do
        if #haul < 3 then haul[#haul + 1] = num(it.n) .. " " .. pretty(it.name):gsub("^Raw ", ""):sub(1, 6) end
      end
      return {
        { job .. (left and ("  " .. clock(left)) or ""), jc },
        lost and { "LOST: " .. lost, colors.red } or { n .. " turtles, " .. away .. " out mining", colors.white },
        { #haul > 0 and table.concat(haul, " ") or "Nothing mined yet", colors.lightGray },
      }
    end },
    { key = "store", title = "STORAGE", lines = function()
      local s, i = data.store or {}, data.storeInfo or {}
      local n = 0
      for _ in pairs(s.totals or {}) do n = n + 1 end
      return {
        { tostring(s.state or i.state or "?"), colors.yellow },
        { i.size and ("Slots " .. num(i.used) .. "/" .. num(i.size)) or (n .. " kinds of items"),
          i.full and colors.red or colors.white },
        { i.chests and (i.chests .. " chests, " .. (i.furnaces or 0) .. " furnaces") or "", colors.lightGray },
      }
    end },
    { key = "wood", title = "LUMBERJACK", lines = function()
      local w = data.wood
      local lava = w.lava == nil and "no chest" or (w.lava .. " lava")
      return {
        { (w.state or "?") .. ": " .. tostring(w.status or ""), w.paused and colors.yellow or colors.lime },
        { "Fuel " .. num(w.fuel) .. "  " .. lava, (w.lava == 0) and colors.red or colors.white },
        { "Felled " .. num(w.felled) .. "  Logs " .. num(w.logs), colors.lightGray },
      }
    end },
    { key = "buddy", title = "BUDDY", lines = function()
      local b = data.buddy
      local last = chatLog[#chatLog]
      return {
        { b.busy and "Busy..." or "Idle, ready to help", b.busy and colors.yellow or colors.lime },
        { "Fuel " .. num(b.fuel) .. "  " .. #(b.places or {}) .. " places known", colors.white },
        { last and (last.who .. ": " .. last.text) or "Tap to chat", colors.lightGray },
      }
    end },
  }
  local y = 3
  for _, card in ipairs(cards) do
    local key = card.key
    local col = TAB_COLOR[key]
    local ok = online(key) and data[key]
    text(1, y, (" "):rep(W), colors.black, col)
    text(2, y, card.title, colors.black, col)
    right(y, "\7 ", ok and colors.lime or colors.red, col)
    local lines = ok and card.lines() or offlineLines(key)
    for i = 1, 3 do
      local l = lines[i] or { "" }
      fill(y + i, colors.black)
      text(2, y + i, l[1], l[2])
    end
    buttons[#buttons + 1] = { x1 = 1, y1 = y, x2 = W, y2 = y + 3, action = function() setTab(key) end }
    y = y + 4
  end
end

---------------------------------------------------------------------------
-- Mine
---------------------------------------------------------------------------
local TIMES = { { "10m", 600 }, { "20m", 1200 }, { "30m", 1800 }, { "45m", 2700 }, { "1h", 3600 } }

local function hubCmd(msg)
  msg.type = "panel"
  msg.turtle = ui.selected
  if send("hub", msg) then toast("Sent to the hub...", 2) end
end

local function drawMine()
  local h = data.hub
  if not online("hub") or not h then
    local l = offlineLines("hub")
    text(2, 3, "Mine Army hub", colors.orange)
    for i, x in ipairs(l) do text(2, 4 + i, x[1], x[2]) end
    text(2, 8, "Run hub.lua (new version)", colors.lightGray)
    text(2, 9, "on the hub computer.", colors.lightGray)
    return
  end
  -- Job and time left
  local job, jc = hubJob(h)
  text(1, 2, " " .. job, jc)
  local left = hubLeft(h)
  if left then right(2, clock(left) .. " ", left < 300 and colors.orange or colors.white) end

  -- Ore buttons: 4 per row, the last one is the custom item
  local selT
  for _, t in ipairs(h.turtles or {}) do if t.id == ui.selected then selT = t end end
  local current = selT and selT.ore or h.target
  local ores, custom = {}, nil
  for _, o in ipairs(h.ores or {}) do
    if o.key == "custom" then custom = o else ores[#ores + 1] = o end
  end
  local list = {}
  for i = 1, math.min(7, #ores) do
    local o = ores[i]
    local active = current == o.key
    list[#list + 1] = { o.short:sub(1, 6), active and colors.black or colors.white,
      active and colors.lime or (o.color or colors.gray), function() hubCmd({ cmd = "target", ore = o.key }) end }
  end
  local cActive = current == "custom"
  list[#list + 1] = { custom and custom.short:sub(1, 6) or "Other", cActive and colors.black or colors.white,
    cActive and colors.lime or colors.gray, function()
      local item = prompt("Mine which item? (rock or ore)", custom and custom.label or nil)
      if not item then return end
      local y = prompt("At height Y? (empty = default)")
      hubCmd({ cmd = "custom", text = item, y = tonumber(y or "") })
    end }
  for r = 0, 1 do
    local row = {}
    for i = 1, 4 do row[#row + 1] = list[r * 4 + i] end
    if #row > 0 then buttonRow(3 + r, row, 1, W, 0) end
  end

  -- STOP / RECALL / RESUME
  buttonRow(6, {
    { "STOP", colors.white, colors.red, function() hubCmd({ cmd = "stop" }) end },
    { "RECALL", colors.white, colors.purple, function() hubCmd({ cmd = "recall" }) end },
    { "RESUME", colors.black, h.recallAll and colors.lime or colors.lightGray, function() hubCmd({ cmd = "resume" }) end },
  })

  -- Session length
  local row = {}
  for _, opt in ipairs(TIMES) do
    local active = h.sessionLen == opt[2]
    row[#row + 1] = { opt[1], active and colors.black or colors.white, active and colors.lime or colors.gray,
      function() hubCmd({ cmd = "limit", sec = opt[2] }) end }
  end
  text(1, 8, "Time", colors.lightGray)
  buttonRow(8, row, 6, W, 1)

  -- Turtles: two lines each, tap one to give it its own orders
  if selT then
    text(1, 10, (" For " .. (selT.label or ("#" .. selT.id))):sub(1, W - 13), colors.yellow)
    button(W - 11, 10, 7, "TUNNEL", colors.white, colors.brown, function()
      local to = prompt("Tunnel to x z? (F3, ahead of it)")
      if not to then return end
      local x, z = to:match("^(%-?%d+)[%s,]+(%-?%d+)$")
      if not x then toast("Type two numbers: x z", 3) return end
      local every = prompt("Torch every how many blocks? (empty = 8)")
      hubCmd({ cmd = "bore", x = tonumber(x), z = tonumber(z), every = tonumber(every or "") or 8 })
    end)
    button(W - 4, 10, 5, "ALL", colors.black, colors.white, function() ui.selected = nil end)
  else
    ui.selected = nil
    text(1, 10, " Turtles (tap = orders)", colors.cyan)
  end
  local turtles = h.turtles or {}
  if #turtles == 0 then text(2, 12, "No turtles seen yet.", colors.lightGray) end
  local per = math.floor((H - 1 - 11) / 2) -- turtles that fit
  ui.turtleScroll = math.max(0, math.min(ui.turtleScroll, #turtles - per))
  local y = 11
  for i = ui.turtleScroll + 1, math.min(#turtles, ui.turtleScroll + per) do
    local t = turtles[i]
    local isSel = t.id == ui.selected
    local bg = isSel and colors.gray or colors.black
    local job = t.ore == "stop" and "stop" or "-"
    for _, o in ipairs(h.ores or {}) do if o.key == t.ore then job = o.short end end
    if t.ore == "tunnel" then job = "tunnel" end
    if t.branch and t.phase == "mining" then job = job .. " b" .. t.branch end
    local stat = t.status or "?"
    local sc = colors.lightGray
    if stat:find("^LOST") or stat:find("^STUCK") or stat:find("^ERROR") or t.phase == "lost" then sc = colors.red end
    local away = t.phase == "descending" or t.phase == "mining" or t.phase == "returning"
    if (t.age or 0) > 15 then
      if away then stat, sc = "Underground (" .. age(t.age) .. ") " .. stat, colors.orange
      else stat, sc = "NO SIGNAL " .. age(t.age) .. " | " .. stat, colors.red end
    end
    fill(y, bg, y + 1)
    text(1, y, string.format(" %-11s %-7s", (t.label or ("#" .. t.id)):sub(1, 11), job:sub(1, 7)),
      isSel and colors.yellow or colors.white, bg)
    local f = num(t.fuel)
    local fc = (type(t.fuel) == "number" and t.fuel < 500) and colors.red or colors.white
    right(y, f .. " ", fc, bg)
    text(2, y + 1, stat, sc, bg)
    local id = t.id
    buttons[#buttons + 1] = { x1 = 1, y1 = y, x2 = W, y2 = y + 1, action = function()
      ui.selected = (ui.selected ~= id) and id or nil
    end }
    y = y + 2
  end
  if #turtles > per then
    text(2, H - 1, (ui.turtleScroll + 1) .. "-" .. math.min(#turtles, ui.turtleScroll + per) .. " of " .. #turtles, colors.lightGray)
    button(W - 6, H - 1, 3, "\30", colors.white, colors.gray, function() ui.turtleScroll = ui.turtleScroll - 1 end)
    button(W - 2, H - 1, 3, "\31", colors.white, colors.gray, function() ui.turtleScroll = ui.turtleScroll + 1 end)
  end
end

---------------------------------------------------------------------------
-- Store
---------------------------------------------------------------------------
local function storeEntries()
  local s = data.store or {}
  local by = {}
  for name, n in pairs(s.totals or {}) do by[name] = { name = name, n = n, can = 0 } end
  for _, r in ipairs(s.recipes or {}) do
    local e = by[r.name]
    if e then e.can = r.can or 0
    elseif (r.can or 0) > 0 then by[r.name] = { name = r.name, n = 0, can = r.can } end
  end
  local q = ui.search:lower()
  local list = {}
  for name, e in pairs(by) do
    e.orders = (s.orders or {})[name] or 0
    e.label = pretty(name)
    if q == "" or e.label:lower():find(q, 1, true) or name:find(q:gsub("%s+", "_"), 1, true) then
      list[#list + 1] = e
    end
  end
  table.sort(list, function(a, b)
    if q == "" and a.orders ~= b.orders then return a.orders > b.orders end -- ordered often: on top
    if a.n ~= b.n then return a.n > b.n end
    return a.label < b.label
  end)
  return list
end

local function storeCmd(msg, note)
  if send("store", msg) then toast(note or "Sent...", 2) end
end

local function drawStore()
  if not online("store") then
    local l = offlineLines("store")
    text(2, 3, "Storage room turtle", colors.cyan)
    for i, x in ipairs(l) do text(2, 4 + i, x[1], x[2]) end
    text(2, 8, "It needs a wireless modem", colors.lightGray)
    text(2, 9, "and must run roomsorter.", colors.lightGray)
    return
  end
  local s, i = data.store or {}, data.storeInfo or {}
  local state = tostring(s.state or i.state or "?")
  text(1, 2, " " .. state, colors.yellow)
  local info = i.size and ("Slots " .. num(i.used) .. "/" .. num(i.size)) or ""
  if i.chests then info = info .. "  " .. i.chests .. " chests" end
  if (s.cutoff or 0) > 0 then info = info .. "  " .. s.cutoff .. " cut off" end
  text(1, 3, " " .. info, i.full and colors.red or colors.lightGray)

  local paused = state:find("^Paus") ~= nil
  buttonRow(4, {
    { "Search", colors.black, colors.white, function()
      ui.search = prompt("Search for:", ui.search ~= "" and ui.search or nil) or ""
      ui.scroll = 0
    end },
    { paused and "Resume" or "Pause", colors.black, paused and colors.lime or colors.yellow, function()
      storeCmd({ cmd = paused and "resume" or "pause" })
    end },
    { "Resync", colors.white, colors.gray, function() storeCmd({ cmd = "resync" }) end },
  })

  local list = storeEntries()
  if ui.search ~= "" then
    text(1, 5, (" '" .. ui.search .. "': " .. #list .. " found"):sub(1, W - 4), colors.white)
    button(W - 2, 5, 3, "x", colors.white, colors.red, function() ui.search = "" ui.scroll = 0 end)
  else
    text(1, 5, " " .. #list .. " items (tap to order)", colors.lightGray)
  end
  local top, bottom = 6, H - 2
  local rows = bottom - top + 1
  ui.scroll = math.max(0, math.min(ui.scroll, #list - rows))
  for k = 1, rows do
    local e = list[ui.scroll + k]
    if not e then break end
    local y = top + k - 1
    local bg = (k % 2 == 0) and colors.black or colors.gray
    if not COLOR then bg = colors.black end
    fill(y, bg)
    local count = e.n > 0 and num(e.n) or ("craft " .. num(e.can))
    text(2, y, e.label:sub(1, W - #count - 3), colors.white, bg)
    right(y, count .. " ", e.n > 0 and colors.lime or colors.orange, bg)
    buttons[#buttons + 1] = { x1 = 1, y1 = y, x2 = W, y2 = y, action = function() ui.popup = { kind = "order", e = e } end }
  end
  if #list == 0 then text(2, top + 1, ui.search ~= "" and "Nothing matches." or "Storage is empty.", colors.lightGray) end
  if #list > rows then
    local pages = math.ceil(#list / rows)
    local page = math.floor(ui.scroll / rows) + 1
    button(1, H - 1, 6, "\30 Up", colors.white, colors.gray, function() ui.scroll = ui.scroll - rows end)
    text(math.floor(W / 2) - 2, H - 1, page .. "/" .. pages, colors.lightGray)
    button(W - 5, H - 1, 6, "Dn \31", colors.white, colors.gray, function() ui.scroll = ui.scroll + rows end)
  end
end

local function drawOrderPopup(e)
  local x1, y1, x2, y2 = 2, 6, W - 1, 15
  for y = y1, y2 do text(x1, y, (" "):rep(x2 - x1 + 1), nil, colors.lightGray) end
  text(x1, y1, (" "):rep(x2 - x1 + 1), nil, colors.cyan)
  text(x1 + 1, y1, ("Order " .. e.label):sub(1, x2 - x1 - 1), colors.black, colors.cyan)
  text(x1 + 1, y1 + 2, "In storage: " .. num(e.n), colors.black, colors.lightGray)
  if (e.can or 0) > 0 then text(x1 + 1, y1 + 3, "Can craft:  " .. num(e.can), colors.black, colors.lightGray) end
  local function order(n)
    ui.popup = nil
    storeCmd({ cmd = "order", text = e.name, n = n }, "Ordering " .. n .. " " .. e.label .. "...")
  end
  local amounts = {}
  for _, n in ipairs({ 1, 16, 32, 64 }) do
    amounts[#amounts + 1] = { tostring(n), colors.white, colors.blue, function() order(n) end }
  end
  buttonRow(y1 + 5, amounts, x1 + 1, x2 - 1)
  buttonRow(y1 + 7, {
    { "All " .. num(e.n), colors.white, colors.blue, function() if e.n > 0 then order(e.n) end end },
    { "Other", colors.white, colors.blue, function()
      local n = tonumber(prompt("How many " .. e.label .. "?") or "")
      if n and n >= 1 then order(math.floor(n)) end
    end },
  }, x1 + 1, x2 - 1)
  button(x1 + 1, y2 - 1, x2 - x1 - 1, "Cancel", colors.white, colors.red, function() ui.popup = nil end)
end

---------------------------------------------------------------------------
-- Wood
---------------------------------------------------------------------------
local function drawWood()
  local w = data.wood
  if not online("wood") or not w then
    local l = offlineLines("wood")
    text(2, 3, "Lumber turtle", colors.green)
    for i, x in ipairs(l) do text(2, 4 + i, x[1], x[2]) end
    text(2, 8, "Give it a wireless modem", colors.lightGray)
    text(2, 9, "and run the new lumber.lua", colors.lightGray)
    return
  end
  local sc = w.paused and colors.yellow or (w.state == "COMING HOME" and colors.orange or colors.lime)
  fill(2, sc)
  text(2, 2, (w.label or "Lumberjack"), colors.black, sc)
  right(2, (w.state or "?") .. " ", colors.black, sc)
  local lines = wrap(w.status or "", W - 2)
  for k = 1, 2 do text(2, 3 + k, lines[k] or "", colors.yellow) end

  text(2, 7, "Fuel", colors.lightGray)
  local fuelFrac = (w.fuel == math.huge) and 1 or ((w.fuel or 0) / (w.fuelMax or 5000))
  local fc = (w.fuel or 0) < 600 and colors.red or ((w.fuel or 0) < 2000 and colors.orange or colors.lime)
  bar(7, 7, W - 13, fuelFrac, fc)
  right(7, num(w.fuel) .. " ", colors.white)
  if w.lava == nil then text(2, 8, "Lava  ? (no chest seen)", colors.lightGray)
  elseif w.lava == 0 then text(2, 8, "Lava  none left: add buckets!", colors.red)
  else text(2, 8, "Lava  " .. w.lava .. " bucket" .. (w.lava == 1 and "" or "s") .. " in the chest", colors.white) end

  local function pair(y, l1, v1, l2, v2)
    text(2, y, l1, colors.lightGray) text(10, y, v1, colors.white)
    text(15, y, l2, colors.lightGray) text(22, y, v2, colors.white)
  end
  pair(10, "Felled", num(w.felled), "Logs", num(w.logs))
  pair(11, "Farm", (w.spots or 0) .. "/" .. (w.maxSpots or "?"), "Saplng", num(w.saplings))
  pair(12, "Search", (w.searched or 0) >= 100 and "done" or ((w.searched or 0) .. "%"), "Area", (w.radius or "?") .. "")
  if w.pos then
    local home = w.pos.f == 0 and w.pos.s == 0 and w.pos.y == 0
    text(2, 13, "Where", colors.lightGray)
    text(10, 13, home and "at home" or (w.pos.f .. " fwd, " .. w.pos.s .. " right, " .. w.pos.y .. " up"), colors.white)
  end
  if w.err then
    local el = wrap("! " .. w.err, W - 2)
    for k = 1, 2 do text(2, 14 + k, el[k] or "", colors.red) end
  end
  buttonRow(H - 2, {
    { w.paused and "Go on" or "Pause", colors.black, w.paused and colors.lime or colors.yellow, function()
      if send("wood", { cmd = w.paused and "resume" or "pause" }) then toast("Sent...", 2) end
    end },
    { "Come home", colors.white, colors.orange, function()
      if send("wood", { cmd = "home" }) then toast("Calling it home...", 3) end
    end },
  })
end

---------------------------------------------------------------------------
-- Buddy
---------------------------------------------------------------------------
local function addChat(who, text)
  chatLog[#chatLog + 1] = { who = who, text = text }
  while #chatLog > 40 do table.remove(chatLog, 1) end
  redrawSoon()
end

local function drawBuddy()
  local b = data.buddy
  if not online("buddy") or not b then
    local l = offlineLines("buddy")
    text(2, 3, "Buddy", colors.purple)
    for i, x in ipairs(l) do text(2, 4 + i, x[1], x[2]) end
    text(2, 8, "Give it a wireless modem", colors.lightGray)
    text(2, 9, "and run the new buddy.lua", colors.lightGray)
    return
  end
  fill(2, colors.purple)
  text(2, 2, b.name or "Buddy", colors.white, colors.purple)
  right(2, (b.busy and "busy " or "idle ") .. "fuel " .. num(b.fuel) .. " ", b.busy and colors.yellow or colors.white, colors.purple)

  -- Chat, newest at the bottom
  local lines = {}
  for _, m in ipairs(chatLog) do
    local col = m.who == "You" and colors.lightBlue or colors.lime
    for k, l in ipairs(wrap(m.who .. ": " .. m.text, W - 1)) do lines[#lines + 1] = { l, col } end
  end
  local top, bottom = 3, H - 5
  if #lines == 0 then text(2, top + 1, "Say something to " .. (b.name or "Buddy") .. "!", colors.lightGray) end
  local first = math.max(1, #lines - (bottom - top))
  for k = first, #lines do text(1, top + k - first, lines[k][1], lines[k][2]) end

  -- Quick trips: home and the places it remembers
  local places = { { "Home", colors.white, colors.gray, function()
    if send("buddy", { cmd = "home" }) then addChat("You", "(go home)") end
  end } }
  for _, p in ipairs(b.places or {}) do
    if #places < 4 then
      places[#places + 1] = { p, colors.white, colors.gray, function()
        if send("buddy", { cmd = "goto", place = p }) then addChat("You", "(go to " .. p .. ")") end
      end }
    end
  end
  buttonRow(H - 3, places)
  button(1, H - 1, W, "Say something...", colors.black, colors.white, function()
    local s = prompt("Say to " .. (b.name or "Buddy") .. ":")
    if s and send("buddy", { cmd = "chat", text = s }) then addChat("You", s) end
  end)
end

---------------------------------------------------------------------------
-- Console (the >_ tab): type commands to manage the bots. "help" lists them.
---------------------------------------------------------------------------
local con = { lines = {}, input = "", cursor = 0, history = {}, hpos = nil, scroll = 0, pending = {}, listen = nil }
if fs.exists("panel.key") then -- the dev key (see "key"), kept on the pocket
  local h = fs.open("panel.key", "r")
  con.key = (h.readAll() or ""):gsub("%s+$", "")
  h.close()
end

local function say(s, col)
  s = tostring(s)
  for _, l in ipairs(#s <= W and not s:find("\n") and { s } or wrap(s, W)) do con.lines[#con.lines + 1] = { l, col or colors.white } end
  while #con.lines > 300 do table.remove(con.lines, 1) end
  redrawSoon()
end
consoleSay = function(s)
  if ui.tab ~= "console" then return false end
  say(s, colors.orange)
  return true
end

local DEV_OPS = { info = true, log = true, ls = true, cat = true, get = true, reboot = true, put = true, rm = true,
  lua = true, update = true }
local ALIASES = { hub = "hub", mine = "hub", mining = "hub", fleet = "hub", store = "store", storage = "store",
  sorter = "store", wood = "wood", lumber = "wood", lumberjack = "wood", buddy = "buddy" }
local STORE_CMDS = { "status", "list", "find", "get", "order", "craft", "recipes", "build", "blocked", "unblock",
  "resync", "pickup", "pause", "resume", "learn" }
local HELP = {
  "BOTS: hub, store, wood,",
  "buddy, a miner's name, #id",
  "ANY BOT (not store):",
  " <bot> info",
  " <bot> log [lines]",
  " <bot> ls [folder]",
  " <bot> cat <file>",
  " <bot> get <file> [save as]",
  " <bot> reboot",
  "NEED A PASSWORD (key):",
  " <bot> put <file> [as]",
  " <bot> update <file> [as]",
  "  (put + reboot)",
  " <bot> rm <file>",
  " <bot> lua <code>",
  " miners <any of these>",
  "MINING (via the hub):",
  " hub <ore> | stop | recall",
  " hub resume | status",
  " hub time <minutes>",
  " hub item <rock/ore> [y]",
  " <miner> <ore>|stop|recall",
  " <miner> status",
  " <miner> tunnel <x> <z> [n]",
  "  (lit 3x3 tunnel, torch every n)",
  "STORAGE:",
  " store find <item>",
  " store get <item> [n]",
  " store order <item> [n]",
  " store status | list |",
  " blocked | resync | pause",
  "LUMBER:",
  " wood status|pause|resume",
  " wood home",
  "BUDDY:",
  " buddy <say anything>",
  " buddy home | status",
  " buddy goto <place>",
  "TOOLS:",
  " update all",
  " bots  scan  clear",
  " listen [protocol|off]",
  " send <id> <proto> <msg>",
  " key <password> | key off",
  "Tab completes, Up/Down =",
  "history, scroll = older.",
}

local function lower(s) return tostring(s or ""):lower() end
local function miners() return data.hub and data.hub.turtles or {} end
local function short(s) return (lower(s):gsub("[%s_%-]", "")) end

-- A word -> the bot it names: { key = DEV key, or miner = turtle row; id, proto, name }
local function findBot(word)
  local w = lower(word)
  local key = ALIASES[w]
  if key then return { key = key, id = DEV[key].id, proto = DEV[key].proto, name = DEV[key].name } end
  local id = tonumber((w:gsub("^#", "")))
  for _, t in ipairs(miners()) do
    if (id and t.id == id) or short(t.label) == short(w) then
      return { miner = t, id = t.id, proto = "minearmy", name = t.label or ("#" .. t.id) }
    end
  end
  for _, t in ipairs(miners()) do -- the start of a name is enough when only one fits
    if not id and short(t.label):sub(1, #short(w)) == short(w) and #w >= 2 then
      return { miner = t, id = t.id, proto = "minearmy", name = t.label or ("#" .. t.id) }
    end
  end
  if id then
    for k, d in pairs(DEV) do if d.id == id then return { key = k, id = id, proto = d.proto, name = d.name } end end
  end
end

local function track(rid, bot, extra)
  if not rid then return end
  local p = extra or {}
  p.name, p.t = bot.name, os.clock()
  con.pending[rid] = p
end

local function sendTo(bot, msg, extra)
  if bot.key then return track(send(bot.key, msg), bot, extra) end
  msg.rid = math.random(1, 1073741824)
  rednet.send(bot.id, msg, bot.proto)
  track(msg.rid, bot, extra)
end

local function devOp(bot, op, words)
  if bot.key == "store" then
    say("The storage turtle only takes its own commands: store help", colors.orange)
    return
  end
  local msg = { type = "dev", op = op, key = con.key, path = words[3], n = tonumber(words[3]) }
  local extra = nil
  if op == "cat" or op == "get" or op == "rm" or op == "put" or op == "update" then
    if not words[3] then say(op .. " needs a file name", colors.orange) return end
    if op == "get" then extra = { save = words[4] or fs.getName(words[3]) } end
  end
  if op == "put" or op == "update" then -- send a file from this pocket computer
    if not fs.exists(words[3]) or fs.isDir(words[3]) then say("No file " .. words[3] .. " on this pocket", colors.red) return end
    local h = fs.open(words[3], "r")
    msg.data = h.readAll()
    h.close()
    msg.op, msg.path = "put", words[4] or fs.getName(words[3])
    if op == "update" then extra = { thenReboot = bot } end
  elseif op == "lua" then
    msg.code = table.concat(words, " ", 3)
    if msg.code == "" then say("lua <code>, e.g. lua turtle.getFuelLevel()", colors.orange) return end
  end
  if (msg.op == "put" or op == "rm" or op == "lua") and not con.key then
    say("Set the password first: key <password> (same as dev.key on the bot)", colors.orange)
    return
  end
  sendTo(bot, msg, extra)
end

local function findOre(word)
  local w = short(word)
  for _, o in ipairs(data.hub and data.hub.ores or {}) do
    if short(o.key) == w or short(o.label) == w or short(o.short) == w then return o.key end
  end
end

-- Mining through the hub; turtle = only that turtle
local function hubOrder(words, from, turtle)
  local op = lower(words[from])
  local msg = { type = "panel", turtle = turtle }
  if op == "stop" or op == "recall" or op == "resume" then msg.cmd = op
  elseif op == "time" then
    local m = tonumber(words[from + 1])
    if not m then say("hub time <minutes>: 10, 20, 30, 45 or 60", colors.orange) return end
    msg.cmd, msg.sec = "limit", math.floor(m * 60)
  elseif op == "item" or op == "custom" then
    local y = tonumber(words[#words])
    local last = (y and #words > from + 1) and #words - 1 or #words
    msg.cmd, msg.text, msg.y = "custom", table.concat(words, " ", from + 1, last), y
    if msg.text == "" then say("hub item <rock or ore> [y]", colors.orange) return end
  elseif op == "tunnel" then
    local x, z = tonumber(words[from + 1]), tonumber(words[from + 2])
    if not (turtle and x and z) then say("<miner> tunnel <x> <z> [torch every]", colors.orange) return end
    msg.cmd, msg.x, msg.z, msg.every = "bore", x, z, tonumber(words[from + 3]) or 8
  elseif findOre(op) then msg.cmd, msg.ore = "target", findOre(op)
  else -- never guess: a typo must not send the fleet off mining something odd
    say("Unknown order '" .. tostring(words[from]) .. "'. Use an ore, stop, recall, resume, time, item <name> or tunnel <x> <z>.", colors.orange)
  end
  if not msg.cmd then return end
  sendTo({ key = "hub", name = turtle and ("hub > #" .. turtle) or "hub" }, msg, { hub = true })
end

local function hubStatus()
  local h = data.hub
  if not h then say("No word from the hub yet.", colors.orange) return end
  local job = hubJob(h)
  local left = hubLeft(h)
  say(job .. (left and (", " .. clock(left) .. " left") or "") .. ", mode " .. tostring(h.mode), colors.lime)
  for _, t in ipairs(miners()) do
    say(string.format("#%d %s: %s, fuel %s", t.id, t.label or "?", tostring(t.status), num(t.fuel)), colors.lightGray)
  end
end

local function minerStatus(t)
  say(string.format("#%d %s, job %s, %s", t.id, t.label or "?", tostring(t.ore or "-"), tostring(t.status)), colors.lime)
  say(string.format("phase %s, Y %s, fuel %s, %s free slots, heard %s ago", tostring(t.phase), tostring(t.y),
    num(t.fuel), tostring(t.free), age(t.age or 0)), colors.lightGray)
  if t.err then say("last error: " .. t.err, colors.red) end
end

local function botList()
  for _, k in ipairs(DEV_ORDER) do
    local d = DEV[k]
    local st = online(k) and "online" or (d.id and ("silent " .. age(os.clock() - d.seen)) or "not found")
    say(string.format("%-6s %-5s %s", k, d.id and ("#" .. d.id) or "", st), online(k) and colors.lime or colors.red)
  end
  for _, t in ipairs(miners()) do
    say(string.format("miner  #%-4d %s %s", t.id, (t.label or "?"):sub(1, 10), num(t.fuel)),
      (t.age or 0) > 15 and colors.orange or colors.lime)
  end
end

local function run(line)
  say("> " .. line, colors.yellow)
  local words = {}
  for w in line:gmatch("%S+") do words[#words + 1] = w end
  if #words == 0 then return end
  local c, op = lower(words[1]), lower(words[2])
  if c == "help" or c == "?" then for _, l in ipairs(HELP) do say(l, colors.lightGray) end
  elseif c == "clear" or c == "cls" then con.lines, con.scroll = {}, 0
  elseif c == "update" then
    if op ~= "all" then say("update all  (every bot and this panel)", colors.orange) return end
    updateAll(true)
  elseif c == "bots" or c == "list" then botList()
  elseif c == "scan" then
    for _, d in pairs(DEV) do d.id, d.seen = nil, -1e9 end
    say("Looking for the bots again...", colors.lightGray)
  elseif c == "key" then
    if not words[2] then say(con.key and "A dev key is set." or "No dev key set.", colors.lightGray)
    elseif op == "off" then con.key = nil fs.delete("panel.key") say("Dev key removed.")
    else
      con.key = words[2]
      local h = fs.open("panel.key", "w") h.write(con.key) h.close()
      say("Password saved. Put the same password in a file dev.key on each bot: that locks it and allows put, update, rm and lua.")
    end
  elseif c == "listen" then
    con.listen = (op == "" and "all") or (op ~= "off" and words[2]) or nil
    say(con.listen and ("Showing every message" .. (con.listen ~= "all" and (" on " .. con.listen) or "")) or "Stopped listening.")
  elseif c == "send" then
    local id = tonumber(words[2])
    if not id or not words[3] then say("send <id> <protocol> <text or {table}>", colors.orange) return end
    local rest = table.concat(words, " ", 4)
    local msg = rest
    if rest:sub(1, 1) == "{" then msg = textutils.unserialize(rest) end
    if msg == nil then say("That table doesn't read right.", colors.red) return end
    rednet.send(id, msg, words[3])
    say("Sent to #" .. id .. " on " .. words[3], colors.lightGray)
  elseif c == "miners" or c == "all" then
    if not DEV_OPS[op] then say("miners info | log | reboot | put | update | lua", colors.orange) return end
    if #miners() == 0 then say("No miners known (the hub tells me about them).", colors.orange) end
    for _, t in ipairs(miners()) do devOp({ id = t.id, proto = "minearmy", name = t.label or ("#" .. t.id) }, op, words) end
  else
    local bot = findBot(c)
    if not bot then say("Don't know '" .. words[1] .. "'. Try: help, bots", colors.red) return end
    if not bot.id then say(bot.name .. " not found yet. Is it running with a modem?", colors.red) return end
    if DEV_OPS[op] and (bot.key ~= "store" or op ~= "get") then devOp(bot, op, words) return end
    if bot.miner then
      if op == "" or op == "status" then minerStatus(bot.miner) else hubOrder(words, 2, bot.id) end
    elseif bot.key == "hub" then
      if op == "" or op == "status" then hubStatus() else hubOrder(words, 2, nil) end
    elseif bot.key == "store" then
      local n = tonumber(words[#words])
      if n and #words <= 3 then n = nil end
      local text = table.concat(words, " ", 3, n and #words - 1 or #words)
      sendTo(bot, { cmd = op ~= "" and op or "status", text = text, n = n }, { store = true })
    elseif bot.key == "wood" then
      if op == "pause" or op == "resume" or op == "home" then sendTo(bot, { cmd = op }, { wood = true })
      elseif op == "" or op == "status" then sendTo(bot, { cmd = "status" }, { wood = true })
      else say("wood pause | resume | home | status", colors.orange) end
    elseif bot.key == "buddy" then
      if op == "home" then sendTo(bot, { cmd = "home" })
      elseif op == "goto" then sendTo(bot, { cmd = "goto", place = table.concat(words, " ", 3) })
      elseif op == "" or op == "status" then
        local b = data.buddy
        if b then say((b.busy and "Busy" or "Idle") .. ", fuel " .. num(b.fuel) .. ", places: "
          .. (#(b.places or {}) > 0 and table.concat(b.places, ", ") or "none"), colors.lime) end
      else
        local text = table.concat(words, " ", (op == "say") and 3 or 2)
        sendTo(bot, { cmd = "chat", text = text })
        addChat("You", text)
      end
    end
  end
end

-- An answer to something typed in the console (true = handled, don't use it elsewhere)
local function consoleReply(id, m, proto)
  if con.listen and (con.listen == "all" or con.listen == proto) then
    local ok, s = pcall(textutils.serialize, m)
    s = ok and s:gsub("%s+", " ") or tostring(m)
    say("[" .. tostring(proto) .. " #" .. id .. "] " .. s:sub(1, 200), colors.gray)
  end
  if type(m) == "table" and m.type == "buddy_answer" then say("[buddy] " .. tostring(m.text), colors.lime) end
  local p = type(m) == "table" and m.rid and con.pending[m.rid]
  if not p then return false end
  con.pending[m.rid] = nil
  local tag = "[" .. p.name .. "] "
  if m.type == "dev_reply" then
    say(tag .. tostring(m.out), m.ok and colors.lime or colors.red)
    if p.thenReboot and m.ok then devOp(p.thenReboot, "reboot", {}) end
    if p.save and type(m.data) == "string" then
      local h = fs.open(p.save, "w") h.write(m.data) h.close()
      say("Saved as " .. p.save .. " on this pocket computer.", colors.lightGray)
    end
    return true
  elseif p.store and m[1] then
    for _, l in ipairs(m) do say(tag .. tostring(l), colors.lime) end
    os.queueEvent("panel_ask", "store")
    return true
  elseif p.hub and m.type == "panel_state" then
    say(tag .. (m.note or ("OK. " .. hubJob(m))), m.note and colors.orange or colors.lime)
    m.note = nil -- already shown
  elseif p.wood and m.type == "lumber_state" then
    say(tag .. tostring(m.state) .. ": " .. tostring(m.status), colors.lime)
    say("fuel " .. num(m.fuel) .. ", lava " .. tostring(m.lava or "?") .. ", felled " .. num(m.felled)
      .. ", farm " .. tostring(m.spots) .. "/" .. tostring(m.maxSpots), colors.lightGray)
  end
  return false
end

local function consoleTick()
  for rid, p in pairs(con.pending) do
    if os.clock() - p.t > 8 then
      con.pending[rid] = nil
      say("[" .. p.name .. "] no answer", colors.red)
    end
  end
end

-- Tab: finish the word being typed
local function complete()
  local before = con.input:sub(1, con.cursor)
  local words = {}
  for w in before:gmatch("%S+") do words[#words + 1] = w end
  local partial = before:match("%S+$") or ""
  local pos = #words + (partial == "" and 1 or 0)
  local cands = {}
  local function add(l) for _, x in ipairs(l) do cands[#cands + 1] = x end end
  if pos == 1 then
    add({ "help", "bots", "scan", "listen", "send", "key", "clear", "update", "miners", "hub", "store", "wood", "buddy" })
    for _, t in ipairs(miners()) do if t.label then cands[#cands + 1] = (t.label:gsub("%s", "")) end end
  elseif pos == 2 then
    local bot = findBot(words[1])
    if bot and bot.key == "store" then add(STORE_CMDS)
    elseif bot then
      add({ "info", "log", "ls", "cat", "get", "reboot", "put", "update", "rm", "lua" })
      if bot.miner or bot.key == "hub" then
        add({ "stop", "recall", "status" })
        for _, o in ipairs(data.hub and data.hub.ores or {}) do cands[#cands + 1] = o.key end
        if bot.key == "hub" then add({ "resume", "time", "item" }) end
      elseif bot.key == "wood" then add({ "pause", "resume", "home", "status" })
      elseif bot.key == "buddy" then add({ "home", "goto", "say", "status" }) end
    elseif lower(words[1]) == "miners" then add({ "info", "log", "reboot", "put", "update", "lua" })
    elseif lower(words[1]) == "listen" then add({ "off", "minearmy", "roomsorter", "lumber", "buddy" }) end
  elseif pos == 3 and (lower(words[2]) == "put" or lower(words[2]) == "update") then
    for _, f in ipairs(fs.list("")) do if not fs.isDir(f) then cands[#cands + 1] = f end end
  elseif pos == 3 and lower(words[2]) == "goto" then
    add(data.buddy and data.buddy.places or {})
  end
  local match = {}
  for _, x in ipairs(cands) do if lower(x):sub(1, #partial) == lower(partial) then match[#match + 1] = x end end
  if #match == 0 then return end
  local common = match[1]
  for _, x in ipairs(match) do
    while lower(x):sub(1, #common) ~= lower(common) do common = common:sub(1, -2) end
  end
  if #match == 1 then common = common .. " " end
  if #common >= #partial then
    con.input = before:sub(1, #before - #partial) .. common .. con.input:sub(con.cursor + 1)
    con.cursor = #before - #partial + #common
  end
  if #match > 1 then say(table.concat(match, "  "), colors.lightGray) end
end

local function consoleKey(ev, a)
  if ev == "char" or ev == "paste" then
    con.input = con.input:sub(1, con.cursor) .. a .. con.input:sub(con.cursor + 1)
    con.cursor = con.cursor + #a
  elseif a == keys.enter then
    local line = con.input
    con.input, con.cursor, con.hpos, con.scroll = "", 0, nil, 0
    if line:find("%S") then
      if con.history[#con.history] ~= line then con.history[#con.history + 1] = line end
      run(line)
    end
  elseif a == keys.backspace and con.cursor > 0 then
    con.input = con.input:sub(1, con.cursor - 1) .. con.input:sub(con.cursor + 1)
    con.cursor = con.cursor - 1
  elseif a == keys.delete then con.input = con.input:sub(1, con.cursor) .. con.input:sub(con.cursor + 2)
  elseif a == keys.left then con.cursor = math.max(0, con.cursor - 1)
  elseif a == keys.right then con.cursor = math.min(#con.input, con.cursor + 1)
  elseif a == keys.home then con.cursor = 0
  elseif a == keys["end"] then con.cursor = #con.input
  elseif a == keys.tab then complete()
  elseif a == keys.up or a == keys.down then
    local n = #con.history
    if n == 0 then return end
    if a == keys.up then con.hpos = math.max(1, (con.hpos or n + 1) - 1)
    else con.hpos = con.hpos and con.hpos + 1 or nil end
    if con.hpos and con.hpos > n then con.hpos = nil end
    con.input = con.hpos and con.history[con.hpos] or ""
    con.cursor = #con.input
  end
end

local function drawConsole()
  local top, bottom = 2, H - 1
  local rows = bottom - top + 1
  con.scroll = math.max(0, math.min(con.scroll, #con.lines - rows))
  local first = #con.lines - rows + 1 - con.scroll
  if #con.lines == 0 then
    text(1, top, "Type help for the commands.", colors.lightGray)
    text(1, top + 1, "Tab completes, Up = last one.", colors.lightGray)
  end
  for k = 1, rows do
    local l = con.lines[first + k - 1]
    if l then text(1, top + k - 1, l[1], l[2]) end
  end
  if con.scroll > 0 then right(top, " \30 " .. con.scroll .. " more ", colors.black, colors.lightGray) end
  fill(H, colors.gray)
  local avail = W - 2
  local start = math.max(1, con.cursor - avail + 2)
  text(1, H, ">", colors.yellow, colors.gray)
  text(3, H, con.input:sub(start, start + avail - 1), colors.white, colors.gray)
  term.setCursorPos(3 + con.cursor - start + 1, H)
  term.setTextColor(colors.white)
  term.setCursorBlink(true)
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local function draw()
  if ui.typing then return end
  W, H = term.getSize()
  buttons = {}
  term.setCursorBlink(false)
  term.setBackgroundColor(colors.black)
  term.clear()
  -- Tabs
  local x = 1
  local tw = math.floor(W / #TABS)
  local extra = W - tw * #TABS
  for k, t in ipairs(TABS) do
    local w = tw + (k <= extra and 1 or 0)
    local active = ui.tab == t[1]
    local key = t[1]
    local fg = active and colors.black or colors.white
    local bg = active and colors.white or TAB_COLOR[key]
    button(x, 1, w, t[2], fg, bg, function() setTab(key) end)
    x = x + w
  end
  if ui.tab == "home" then drawHome()
  elseif ui.tab == "hub" then drawMine()
  elseif ui.tab == "store" then drawStore()
  elseif ui.tab == "wood" then drawWood()
  elseif ui.tab == "buddy" then drawBuddy()
  elseif ui.tab == "console" then drawConsole() return end
  if ui.popup and ui.popup.kind == "order" then
    buttons = {}
    drawOrderPopup(ui.popup.e)
  end
  -- Bottom line: a message, or a dot per machine (green = answering)
  if toastText and os.clock() < toastUntil then
    local l = wrap(toastText, W - 1)
    local y0 = H - #l + 1
    if #l > 3 then y0 = H - 2 end
    for k = 1, math.min(3, #l) do
      fill(y0 + k - 1, colors.yellow)
      text(1, y0 + k - 1, " " .. l[k], colors.black, colors.yellow)
    end
    buttons[#buttons + 1] = { x1 = 1, y1 = y0, x2 = W, y2 = H, action = function() toastText = nil end }
  else
    fill(H, colors.gray)
    local xx = 2
    for _, key in ipairs(DEV_ORDER) do
      local label = DEV[key].name:sub(1, 4)
      text(xx, H, "\7", online(key) and colors.lime or (DEV[key].id and colors.red or colors.lightGray), colors.gray)
      text(xx + 1, H, label, colors.white, colors.gray)
      xx = xx + #label + 2
    end
  end
end

---------------------------------------------------------------------------
-- Loops
---------------------------------------------------------------------------
-- Answers and broadcasts
local function receiveLoop()
  while true do
    local id, m, proto = rednet.receive()
    if not consoleReply(id, m, proto) and type(m) == "table" then
      local changed = true
      if proto == "minearmy" and m.type == "panel_state" then
        DEV.hub.id, DEV.hub.seen = id, os.clock()
        data.hub, hubLeftAt = m, os.clock()
        if m.note then toast(m.note) end
      elseif proto == "roomsorter_stock" and type(m.totals) == "table" then
        DEV.store.id = DEV.store.id or id
        if id == DEV.store.id then
          DEV.store.seen = os.clock()
          data.storeInfo = m
          data.store = data.store or {}
          data.store.totals = m.totals
        end
      elseif proto == "roomsorter" and id == DEV.store.id then
        DEV.store.seen = os.clock()
        if type(m.totals) == "table" then
          data.store = m
        elseif m[1] then -- an answer to an order or command: lines of text
          toast(table.concat(m, " "), 8)
          os.queueEvent("panel_ask", "store")
        end
      elseif proto == "lumber" and m.type == "lumber_state" then
        DEV.wood.id, DEV.wood.seen = id, os.clock()
        data.wood = m
      elseif proto == "buddy" and m.type == "buddy_state" then
        DEV.buddy.id, DEV.buddy.seen = id, os.clock()
        data.buddy = m
      elseif proto == "buddy" and m.type == "buddy_answer" then
        DEV.buddy.seen = os.clock()
        addChat(data.buddy and data.buddy.name or "Buddy", tostring(m.text))
        os.queueEvent("panel_ask", "buddy")
      else
        changed = false
      end
      if changed then redrawSoon() end
    end
  end
end

-- Find the machines (and look again for ones that went quiet)
local function findLoop()
  while true do
    for _, key in ipairs(DEV_ORDER) do
      local d = DEV[key]
      if not online(key) then
        local id = rednet.lookup(d.proto, d.host)
        if id then
          if d.id ~= id then d.id = id ask(key) end
        end
      end
    end
    redrawSoon()
    sleep(online("hub") and online("store") and online("wood") and online("buddy") and 30 or 8)
  end
end

-- Ask for fresh status: the open tab often, the rest now and then
local function pollLoop()
  local timer = os.startTimer(0.5)
  while true do
    local ev, a = os.pullEvent()
    if ev == "timer" and a == timer then
      for _, key in ipairs(DEV_ORDER) do
        local d = DEV[key]
        local every = (ui.tab == key or ui.tab == "home") and d.poll or 10
        if d.id and os.clock() - d.asked >= every then ask(key) end
      end
      timer = os.startTimer(0.5)
    elseif ev == "panel_ask" and DEV[a] then
      DEV[a].asked = -1e9 -- ask again on the next tick
    end
  end
end

local function uiLoop()
  draw()
  local tick = os.startTimer(1)
  while true do
    local ev, a, b, cc = os.pullEvent()
    if ev == "timer" and a == tick then
      consoleTick()
      draw()
      tick = os.startTimer(1)
    elseif ev == "panel_redraw" or ev == "term_resize" then
      draw()
    elseif ev == "mouse_click" or ev == "monitor_touch" then
      for k = #buttons, 1, -1 do
        local bt = buttons[k]
        if b >= bt.x1 and b <= bt.x2 and cc >= bt.y1 and cc <= bt.y2 then
          bt.action()
          break
        end
      end
      draw()
      tick = os.startTimer(1) -- typing in a prompt swallows the old timer
    elseif ui.tab == "console" and (ev == "char" or ev == "paste" or ev == "key") then
      consoleKey(ev, a)
      draw()
    elseif ev == "mouse_scroll" then
      if ui.tab == "console" then con.scroll = con.scroll - a * 3
      elseif ui.tab == "store" then ui.scroll = ui.scroll + a * 3
      elseif ui.tab == "hub" then ui.turtleScroll = ui.turtleScroll + a end
      draw()
    elseif ev == "char" then
      local n = tonumber(a)
      if n and TABS[n] then setTab(TABS[n][1]) draw()
      elseif a == "q" then return end
    elseif ev == "key" and a == keys.backspace and ui.popup then
      ui.popup = nil
      draw()
    end
  end
end

parallel.waitForAny(uiLoop, receiveLoop, findLoop, pollLoop)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Panel closed. Type panel to open it again.")
