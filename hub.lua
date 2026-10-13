-- hub.lua - Mine Army hub + dashboard (CC: Tweaked)
-- Draai op een (advanced) computer in je basis met een wireless/ender modem.
-- Een monitor ernaast is optioneel; tikken op de monitor werkt als knoppen.
--
--   hub            start de hub (zet "startup.lua" neer met: hub install)
--   hub install    hub automatisch starten bij opstarten
--
-- Bediening: tik een erts aan -> de hele vloot gaat daarvoor graven.
-- Tik eerst een turtle aan in de lijst om alleen die turtle een opdracht te geven.
-- STOP = na deze trip thuis blijven. TERUG = nu meteen naar huis.
-- Toetsenbord: 1-7 erts, s stop, r terug, a alle turtles, q afsluiten.

local PROTOCOL = "minearmy"
local STATE_FILE = "hub.state"
local STALE = 15 -- seconden zonder bericht = "geen signaal"

local args = { ... }
if args[1] == "install" then
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("hub")\n')
  h.close()
  print("Hub start nu automatisch bij opstarten.")
  return
end

local ORES = {
  diamond  = { label = "Diamond",  y = -58, color = colors.lightBlue, targets = { "minecraft:diamond_ore", "minecraft:deepslate_diamond_ore" } },
  redstone = { label = "Redstone", y = -58, color = colors.red,       targets = { "minecraft:redstone_ore", "minecraft:deepslate_redstone_ore" } },
  gold     = { label = "Gold",     y = -16, color = colors.yellow,    targets = { "minecraft:gold_ore", "minecraft:deepslate_gold_ore" } },
  lapis    = { label = "Lapis",    y = 0,   color = colors.blue,      targets = { "minecraft:lapis_ore", "minecraft:deepslate_lapis_ore" } },
  iron     = { label = "Iron",     y = 16,  color = colors.orange,    targets = { "minecraft:iron_ore", "minecraft:deepslate_iron_ore" } },
  copper   = { label = "Copper",   y = 48,  color = colors.brown,     targets = { "minecraft:copper_ore", "minecraft:deepslate_copper_ore" } },
  coal     = { label = "Coal",     y = 48,  color = colors.gray,      targets = { "minecraft:coal_ore", "minecraft:deepslate_coal_ore" } },
}
local ORDER = { "diamond", "redstone", "gold", "lapis", "iron", "copper", "coal" }
-- Welke items tellen voor het totaal-overzicht
local TALLY = {
  { "Diamond", { "minecraft:diamond" } },
  { "Redstone", { "minecraft:redstone" } },
  { "Gold", { "minecraft:raw_gold", "minecraft:gold_ore", "minecraft:deepslate_gold_ore" } },
  { "Lapis", { "minecraft:lapis_lazuli" } },
  { "Iron", { "minecraft:raw_iron", "minecraft:iron_ore", "minecraft:deepslate_iron_ore" } },
  { "Copper", { "minecraft:raw_copper" } },
  { "Coal", { "minecraft:coal" } },
  { "Emerald", { "minecraft:emerald" } },
}

---------------------------------------------------------------------------
-- Opslag
---------------------------------------------------------------------------
local function loadTable(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  local t = textutils.unserialize(h.readAll())
  h.close()
  return type(t) == "table" and t or nil
end

local hub = loadTable(STATE_FILE) or {}
hub.target = hub.target           -- nil = gepauzeerd
hub.overrides = hub.overrides or {} -- [turtle id] = ore
hub.progress = hub.progress or {}   -- [role] = { levels=, shaft= }
hub.totals = hub.totals or {}
hub.branchLen = hub.branchLen or 32
hub.recallAll = hub.recallAll or false

local function save()
  local h = fs.open(STATE_FILE, "w")
  h.write(textutils.serialize(hub))
  h.close()
end

local turtles = {} -- [id] = { p = status packet, seen = os.clock() }
local selected = nil -- nil = alle turtles

---------------------------------------------------------------------------
-- Netwerk
---------------------------------------------------------------------------
local modemFound = false
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
    rednet.open(name)
    modemFound = true
  end
end
if not modemFound then error("Sluit een wireless of ender modem aan op deze computer.", 0) end
rednet.host(PROTOCOL, "hub")

local function oreFor(id)
  local o = hub.overrides[id]
  if o == false then return nil end
  return o or hub.target
end

local function send(id, msg)
  msg.from = os.getComputerID()
  if id then rednet.send(id, msg, PROTOCOL) else rednet.broadcast(msg, PROTOCOL) end
end

local function mergeProgress(role, p)
  if type(p) ~= "table" or not role then return end
  local cur = hub.progress[role] or { levels = {} }
  cur.levels = cur.levels or {}
  if type(p.shaft) == "number" and (not cur.shaft or p.shaft < cur.shaft) then cur.shaft = p.shaft end
  for y, L in pairs(p.levels or {}) do
    local c = cur.levels[y]
    if not c or (L.branch or 0) > (c.branch or 0)
      or (L.branch == c.branch and (L.step or 0) > (c.step or 0)) then
      c = { branch = L.branch, step = L.step, spine = math.max(L.spine or 0, c and c.spine or 0) }
      cur.levels[y] = c
    elseif (L.spine or 0) > (c.spine or 0) then
      c.spine = L.spine
    end
  end
  hub.progress[role] = cur
end

local function handle(id, m)
  if type(m) ~= "table" then return end
  if m.type == "status" then
    turtles[id] = { p = m, seen = os.clock() }
  elseif m.type == "job?" then
    local ore = oreFor(id)
    local paused = (ore == nil) or hub.recallAll
    local o = ore and ORES[ore]
    send(id, {
      type = "job", paused = paused, ore = (not paused) and ore or nil,
      y = o and o.y, targets = o and o.targets, branchLen = hub.branchLen,
      progress = hub.progress[m.role],
    })
  elseif m.type == "report" then
    mergeProgress(m.role, m.progress)
    for name, n in pairs(m.haul or {}) do
      if type(n) == "number" then hub.totals[name] = (hub.totals[name] or 0) + n end
    end
    save()
  end
end

---------------------------------------------------------------------------
-- Scherm
---------------------------------------------------------------------------
local screens = { { t = term.native(), name = "term", buttons = {} } }
local mon = peripheral.find("monitor")
if mon then
  mon.setTextScale(1)
  local w = mon.getSize()
  if w < 50 then mon.setTextScale(0.5) end
  screens[#screens + 1] = { t = mon, name = peripheral.getName(mon), buttons = {} }
end

local function setTarget(ore)
  if selected then
    hub.overrides[selected] = ore
  else
    hub.target = ore
    hub.overrides = {}
    hub.recallAll = false
    send(nil, { type = "go" })
  end
  save()
end

local function stopAll()
  if selected then
    hub.overrides[selected] = false
  else
    hub.target = nil
    hub.overrides = {}
  end
  save()
end

local function recallNow()
  if selected then
    hub.overrides[selected] = false -- blijft thuis tot je een erts kiest
    send(selected, { type = "recall", target = selected })
  else
    hub.recallAll = true
    send(nil, { type = "recall" })
  end
  save()
end

local function resumeAll()
  hub.recallAll = false
  send(nil, { type = "go" })
  save()
end

local function fmtAge(sec)
  if sec < 60 then return math.floor(sec) .. "s" end
  return math.floor(sec / 60) .. "m"
end

local function ids()
  local l = {}
  for id in pairs(turtles) do l[#l + 1] = id end
  table.sort(l, function(a, b) return (turtles[a].p.label or "") < (turtles[b].p.label or "") end)
  return l
end

local function draw(s)
  local t = s.t
  local W, H = t.getSize()
  local col = t.isColor()
  s.buttons = {}
  local function fg(c) if col then t.setTextColor(c) end end
  local function bg(c) if col then t.setBackgroundColor(c) end end
  local function at(x, y, text, f, b)
    if y < 1 or y > H then return end
    t.setCursorPos(x, y)
    if f then fg(f) end
    if b then bg(b) end
    t.write(text:sub(1, math.max(0, W - x + 1)))
    fg(colors.white) bg(colors.black)
  end
  local function button(x, y, label, f, b, action)
    at(x, y, label, f, b)
    s.buttons[#s.buttons + 1] = { x1 = x, x2 = x + #label - 1, y = y, action = action }
    return x + #label + 1
  end

  bg(colors.black) t.clear()
  -- Titel
  at(1, 1, string.rep(" ", W), colors.white, colors.gray)
  at(2, 1, "MINE ARMY HUB", colors.yellow, colors.gray)
  local mode
  if hub.recallAll then mode = "TERUGGEROEPEN"
  elseif hub.target then mode = "GRAAFT: " .. ORES[hub.target].label:upper() .. " (Y " .. ORES[hub.target].y .. ")"
  else mode = "GESTOPT" end
  at(math.max(16, W - #mode), 1, mode, hub.target and not hub.recallAll and colors.lime or colors.red, colors.gray)

  -- Erts-knoppen
  local y = 3
  local x = 1
  local applyTo = "Opdracht voor: "
  if selected and turtles[selected] then applyTo = applyTo .. (turtles[selected].p.label or ("#" .. selected))
  else applyTo = applyTo .. "ALLE turtles" end
  at(1, y, applyTo, colors.lightGray)
  y = y + 1
  for i, ore in ipairs(ORDER) do
    local o = ORES[ore]
    local label = " " .. o.label .. " "
    if x + #label - 1 > W then x = 1 y = y + 1 end
    local active = (selected and oreFor(selected) == ore) or (not selected and hub.target == ore)
    x = button(x, y, label, active and colors.black or colors.white, active and colors.lime or o.color,
      function() setTarget(ore) end)
  end
  y = y + 2
  x = 1
  x = button(x, y, " STOP ", colors.white, colors.red, stopAll)
  x = button(x, y, " TERUG NU ", colors.white, colors.purple, recallNow)
  if hub.recallAll then x = button(x, y, " HERVAT ", colors.black, colors.lime, resumeAll) end
  if selected then x = button(x, y, " ALLE ", colors.black, colors.white, function() selected = nil end) end

  -- Turtle-tabel
  y = y + 2
  at(1, y, "Turtle       Taak     Status", colors.cyan)
  local right = "Y    Fuel  Vrij"
  at(W - #right + 1, y, right, colors.cyan)
  y = y + 1
  local list = ids()
  if #list == 0 then
    at(1, y, "Nog geen turtles gezien. Start 'miner' op de turtles.", colors.lightGray)
    y = y + 1
  end
  for _, id in ipairs(list) do
    if y > H - 3 then break end
    local r = turtles[id]
    local p = r.p
    local age = os.clock() - r.seen
    local isSel = (selected == id)
    local ore = p.ore and ORES[p.ore] and ORES[p.ore].label or "-"
    local own = hub.overrides[id]
    if own == false then ore = "stop" end
    local stat = p.status or "?"
    if age > STALE then stat = "GEEN SIGNAAL " .. fmtAge(age) .. " | " .. stat end
    if p.branch and p.phase == "mining" then ore = ore .. " z" .. p.branch end
    local name = (p.label or ("#" .. id)):sub(1, 12)
    local rightTxt = string.format("%-4s %5s %2s", tostring(p.y or "?"),
      type(p.fuel) == "number" and tostring(p.fuel) or "inf", tostring(p.free or "?"))
    local rowBg = isSel and colors.gray or colors.black
    at(1, y, string.rep(" ", W), nil, rowBg)
    at(1, y, string.format("%-12s %-8s", name, ore:sub(1, 8)), isSel and colors.yellow or colors.white, rowBg)
    local statW = W - 22 - #rightTxt - 1
    if statW > 0 then
      at(23, y, stat:sub(1, statW), age > STALE and colors.red or colors.lightGray, rowBg)
    end
    at(W - #rightTxt + 1, y, rightTxt, (type(p.fuel) == "number" and p.fuel < 300) and colors.red or colors.white, rowBg)
    s.buttons[#s.buttons + 1] = { x1 = 1, x2 = W, y = y, action = function()
      if selected == id then selected = nil else selected = id end
    end }
    y = y + 1
  end

  -- Totalen
  local tot = {}
  for _, tl in ipairs(TALLY) do
    local n = 0
    for _, name in ipairs(tl[2]) do n = n + (hub.totals[name] or 0) end
    if n > 0 then tot[#tot + 1] = tl[1] .. " " .. n end
  end
  local line = "Totaal: " .. (#tot > 0 and table.concat(tot, "  ") or "nog niets")
  local ty = H - 1
  if #line > W then
    at(1, ty - 1, line:sub(1, W), colors.lightBlue)
    at(1, ty, line:sub(W + 1, 2 * W), colors.lightBlue)
  else
    at(1, ty, line, colors.lightBlue)
  end
  at(1, H, ("Tik turtle = alleen die. 1-7 erts, s stop, r terug, a alle, q uit"):sub(1, W), colors.gray)
end

local function redraw()
  for _, s in ipairs(screens) do draw(s) end
end

local function click(screenName, x, y)
  for _, s in ipairs(screens) do
    if s.name == screenName then
      for _, b in ipairs(s.buttons) do
        if y == b.y and x >= b.x1 and x <= b.x2 then
          b.action()
          redraw()
          return
        end
      end
    end
  end
end

local function netLoop()
  while true do
    local id, msg = rednet.receive(PROTOCOL)
    handle(id, msg)
  end
end

local function uiLoop()
  local timer = os.startTimer(1)
  redraw()
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then
      redraw()
      timer = os.startTimer(1)
    elseif ev == "mouse_click" then
      click("term", b, c)
    elseif ev == "monitor_touch" then
      click(a, b, c)
    elseif ev == "char" then
      local n = tonumber(a)
      if n and ORDER[n] then setTarget(ORDER[n])
      elseif a == "s" then stopAll()
      elseif a == "r" then recallNow()
      elseif a == "h" then resumeAll()
      elseif a == "a" then selected = nil
      elseif a == "q" then return end
      redraw()
    elseif ev == "monitor_resize" or ev == "term_resize" then
      redraw()
    end
  end
end

parallel.waitForAny(netLoop, uiLoop)
term.native().setBackgroundColor(colors.black)
term.native().clear()
term.native().setCursorPos(1, 1)
print("Hub gestopt.")
