-- hub.lua - Mine Army hub + dashboard (CC: Tweaked)
-- Run on an (advanced) computer in your base with a wireless/ender modem.
-- A monitor next to it is optional; tapping the monitor works as buttons.
--
--   hub            start the hub
--   hub install    start the hub automatically on boot
--
-- Controls: tap an ore -> the whole fleet goes mining for it.
-- Tap a turtle in the list first to give only that turtle an order.
-- STOP = stay home after this trip. RECALL = come home right now.
-- Keyboard: 1-7 ore, s stop, r recall, h resume, u update, a all turtles, q quit.
-- Update: drag a new miner.lua onto this computer and press UPDATE (or u).

local PROTOCOL = "minearmy"
local STATE_FILE = "hub.state"
local STALE = 15 -- seconds without a message = "no signal"

local args = { ... }
if args[1] == "install" then
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("hub")\n')
  h.close()
  print("Hub will now start automatically on boot.")
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

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------
local function loadTable(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  local t = textutils.unserialize(h.readAll())
  h.close()
  return type(t) == "table" and t or nil
end

local hub = loadTable(STATE_FILE) or {}
hub.target = hub.target           -- nil = paused
hub.overrides = hub.overrides or {} -- [turtle id] = ore
hub.progress = hub.progress or {}   -- [role] = { levels=, shaft= }
hub.totals = hub.totals or {}
hub.branchLen = hub.branchLen or 64
-- Old hub.state had 32 as default: bump to 64 once (after that your own value is kept)
if not hub.branchLen64 then
  if hub.branchLen == 32 then hub.branchLen = 64 end
  hub.branchLen64 = true
end
-- Max minutes of mining per trip. With normal wireless modems the hub only hears the
-- turtles near the base, so shorter trips = new orders get picked up sooner.
hub.mineMinutes = hub.mineMinutes or 15
-- Max distance (blocks) a turtle goes from its shaft. Keep it inside the chunks
-- that are loaded while you are at your base (6 chunks = 96 blocks).
hub.reach = hub.reach or 96
hub.released = hub.released -- hash of the miner.lua released with UPDATE
hub.recallAll = hub.recallAll or false

local function save()
  local h = fs.open(STATE_FILE, "w")
  h.write(textutils.serialize(hub))
  h.close()
end

local turtles = {} -- [id] = { p = status packet, seen = os.clock() }
local selected = nil -- nil = all turtles

---------------------------------------------------------------------------
-- Network
---------------------------------------------------------------------------
local modemFound = false
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
    rednet.open(name)
    modemFound = true
  end
end
if not modemFound then error("Attach a wireless or ender modem to this computer.", 0) end
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
      c = { branch = L.branch, step = L.step, spine = math.max(L.spine or 0, c and c.spine or 0),
        full = L.full or (c and c.full), offset = L.offset or (c and c.offset) }
      cur.levels[y] = c
    else
      if (L.spine or 0) > (c.spine or 0) then c.spine = L.spine end
      if L.full then c.full = true end
      if c.offset == nil then c.offset = L.offset end
    end
  end
  hub.progress[role] = cur
end

-- Turtle updates: put a new miner.lua on this computer (drag it onto the screen).
-- Turtles at home see the different version, download it and reboot.
local MINER_FILE = "miner.lua"
local minerCache = { mod = nil, hash = nil, code = nil }
local function hashOf(text)
  local h = 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end
local function minerVersion()
  if not fs.exists(MINER_FILE) then return nil end
  local attr = fs.attributes and fs.attributes(MINER_FILE)
  local mod = attr and (attr.modified .. ":" .. attr.size) or nil
  if not minerCache.hash or not mod or mod ~= minerCache.mod then
    local h = fs.open(MINER_FILE, "r")
    local code = h.readAll()
    h.close()
    minerCache = { mod = mod, hash = hashOf(code), code = code }
  end
  return minerCache.hash, minerCache.code
end

-- Only a version released with the UPDATE button is handed out
-- (and only while the file is still exactly that version).
local function releasedVersion()
  local hash = minerVersion()
  if hash and hash == hub.released then return hash end
  return nil
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
      y = o and o.y, targets = o and o.targets, branchLen = hub.branchLen, mineMinutes = hub.mineMinutes, reach = hub.reach,
      progress = hub.progress[m.role],
      update = releasedVersion(),
    })
  elseif m.type == "get_miner" then
    local hash, code = minerVersion()
    if code and hash == hub.released then send(id, { type = "miner_file", hash = hash, code = code }) end
  elseif m.type == "report" then
    mergeProgress(m.role, m.progress)
    for name, n in pairs(m.haul or {}) do
      if type(n) == "number" then hub.totals[name] = (hub.totals[name] or 0) + n end
    end
    save()
  end
end

---------------------------------------------------------------------------
-- Screen
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
    hub.overrides[selected] = false -- stays home until you pick an ore
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

local notice, noticeUntil = nil, 0
local function flash(text)
  notice, noticeUntil = text, os.clock() + 8
end

-- UPDATE button: release the miner.lua on this computer and call the turtles
local function releaseUpdate()
  local hash = minerVersion()
  if not hash then
    flash("No miner.lua on the hub. Drag it onto this screen first.")
    return
  end
  hub.released = hash
  save()
  send(nil, { type = "update", hash = hash })
  flash("Update " .. hash .. " released. Turtles update when they get home.")
end

local function outdatedCount()
  local hash = minerVersion()
  if not hash then return 0 end
  local n = 0
  for _, r in pairs(turtles) do
    if r.p.hash ~= hash then n = n + 1 end -- no hash = very old version
  end
  return n
end

-- "minecraft:raw_iron" -> "Raw iron"
local function prettyName(id)
  local n = id:gsub("^[^:]*:", ""):gsub("_", " ")
  return n:sub(1, 1):upper() .. n:sub(2)
end
local COMMON = {
  ["minecraft:cobblestone"] = true, ["minecraft:cobbled_deepslate"] = true, ["minecraft:stone"] = true,
  ["minecraft:deepslate"] = true, ["minecraft:tuff"] = true, ["minecraft:bucket"] = true,
  ["minecraft:lava_bucket"] = true, ["minecraft:dirt"] = true, ["minecraft:gravel"] = true,
}

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
  -- Title
  at(1, 1, string.rep(" ", W), colors.white, colors.gray)
  at(2, 1, "MINE ARMY HUB", colors.yellow, colors.gray)
  local mode
  if hub.recallAll then mode = "RECALLED"
  elseif hub.target then mode = "MINING: " .. ORES[hub.target].label:upper() .. " (Y " .. ORES[hub.target].y .. ")"
  else mode = "STOPPED" end
  at(math.max(16, W - #mode), 1, mode, hub.target and not hub.recallAll and colors.lime or colors.red, colors.gray)

  -- Lost turtles: red alert line with where to find them (overrides other notices)
  local lost = {}
  for id, r in pairs(turtles) do
    if r.p.phase == "lost" then
      lost[#lost + 1] = (r.p.label or ("#" .. id)) .. " at " .. tostring(r.p.x) .. "," .. tostring(r.p.y) .. "," .. tostring(r.p.z)
    end
  end
  if #lost > 0 then
    at(1, 2, "LOST: " .. table.concat(lost, "  "), colors.red)
  elseif notice and os.clock() < noticeUntil then
    at(1, 2, notice, colors.yellow)
  end

  -- Ore buttons
  local y = 3
  local x = 1
  local applyTo = "Orders for: "
  if selected and turtles[selected] then applyTo = applyTo .. (turtles[selected].p.label or ("#" .. selected))
  else applyTo = applyTo .. "ALL turtles" end
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
  x = button(x, y, " RECALL ", colors.white, colors.purple, recallNow)
  if hub.recallAll then x = button(x, y, " RESUME ", colors.black, colors.lime, resumeAll) end
  local outdated = outdatedCount()
  x = button(x, y, outdated > 0 and (" UPDATE (" .. outdated .. ") ") or " UPDATE ", colors.white,
    outdated > 0 and colors.green or colors.gray, releaseUpdate)
  if selected then x = button(x, y, " ALL ", colors.black, colors.white, function() selected = nil end) end

  -- Turtle table
  y = y + 2
  at(1, y, "Turtle       Job      Status", colors.cyan)
  local right = "Y    Fuel  Free"
  at(W - #right + 1, y, right, colors.cyan)
  y = y + 1
  local list = ids()
  if #list == 0 then
    at(1, y, "No turtles seen yet. Run 'miner' on the turtles.", colors.lightGray)
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
    local away = p.phase == "descending" or p.phase == "mining" or p.phase == "returning"
    local statColor = colors.lightGray
    if stat:find("^LOST") or stat:find("^STUCK") or stat:find("^ERROR") then statColor = colors.red end
    if age > STALE then
      if away then
        stat = "Underground (" .. fmtAge(age) .. ") " .. stat
        statColor = colors.orange
      else
        stat = "NO SIGNAL " .. fmtAge(age) .. " | " .. stat
        statColor = colors.red
      end
    end
    if p.branch and p.phase == "mining" then ore = ore .. " b" .. p.branch end
    local name = (p.label or ("#" .. id)):sub(1, 12)
    local want = releasedVersion()
    if (want and p.hash ~= want) or not p.hash then
      name = (p.label or ("#" .. id)):sub(1, 11) .. "*" -- waiting for update (next time home)
    end
    local rightTxt = string.format("%-4s %5s %2s", tostring(p.y or "?"),
      type(p.fuel) == "number" and tostring(p.fuel) or "inf", tostring(p.free or "?"))
    local rowBg = isSel and colors.gray or colors.black
    at(1, y, string.rep(" ", W), nil, rowBg)
    at(1, y, string.format("%-12s %-8s", name, ore:sub(1, 8)), isSel and colors.yellow or colors.white, rowBg)
    local statW = W - 22 - #rightTxt - 1
    if statW > 0 then
      at(23, y, stat:sub(1, statW), statColor, rowBg)
    end
    at(W - #rightTxt + 1, y, rightTxt, (type(p.fuel) == "number" and p.fuel < 300) and colors.red or colors.white, rowBg)
    s.buttons[#s.buttons + 1] = { x1 = 1, x2 = W, y = y, action = function()
      if selected == id then selected = nil else selected = id end
    end }
    y = y + 1
  end

  -- What is in the turtles right now (last reported inventory of each turtle)
  local sum = {}
  for _, r in pairs(turtles) do
    if type(r.p.items) == "table" then
      for name, n in pairs(r.p.items) do
        if type(n) == "number" then sum[name] = (sum[name] or 0) + n end
      end
    end
  end
  local list2 = {}
  for name, n in pairs(sum) do list2[#list2 + 1] = { name = name, n = n, common = COMMON[name] and 1 or 0 } end
  table.sort(list2, function(a, b)
    if a.common ~= b.common then return a.common < b.common end -- ores first, cobble/buckets last
    if a.n ~= b.n then return a.n > b.n end
    return a.name < b.name
  end)
  local top = y + 1
  if top <= H - 1 then
    at(1, top, "IN TURTLES NOW", colors.cyan)
    local row, col = top + 1, 1
    if #list2 == 0 then at(1, row, "nothing", colors.lightGray) end
    for _, it in ipairs(list2) do
      local txt = prettyName(it.name) .. " " .. it.n
      if col > 1 and col + #txt - 1 > W then row, col = row + 1, 1 end
      if row > H - 1 then break end
      at(col, row, txt, it.common == 1 and colors.lightGray or colors.lightBlue)
      col = col + #txt + 2
    end
  end
  at(1, H, ("Tap a turtle = only that one. 1-7 ore s stop r recall u update q quit"):sub(1, W), colors.gray)
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
  local tick = 0
  redraw()
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then
      -- Normal modems: turtles out of range miss the call, so keep repeating it
      tick = tick + 1
      if hub.recallAll and tick % 5 == 0 then send(nil, { type = "recall" }) end
      local rel = releasedVersion()
      if rel and tick % 10 == 0 and outdatedCount() > 0 then send(nil, { type = "update", hash = rel }) end
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
      elseif a == "u" then releaseUpdate()
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
print("Hub stopped.")
