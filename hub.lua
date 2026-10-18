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
-- Update: "hub update" fetches the latest hub.lua and miner.lua from GitHub and releases it
-- to the turtles. Or drag a new miner.lua onto this computer and press UPDATE (or u).

local PROTOCOL = "minearmy"
local STATE_FILE = "hub.state"
local STALE = 15 -- seconds without a message = "no signal"

local args = { ... }
if args[1] == "update" then
  -- latest version from GitHub (update.lua does the work, fetched here if missing)
  if not fs.exists("update.lua") then
    shell.run("wget", "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/update.lua", "update.lua")
  end
  -- after the reboot the hub releases the new miner.lua to the turtles (see releaseUpdate)
  local h = fs.open("hub.release", "w") h.close()
  shell.run("update")
  fs.delete("hub.release") -- only reached when nothing changed
  return
end
if args[1] == "install" then
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("hub")\n')
  h.close()
  print("Hub will now start automatically on boot.")
  return
end

local ORES = {
  diamond  = { label = "Diamond",  short = "Dia",  y = -58, color = colors.lightBlue, targets = { "minecraft:diamond_ore", "minecraft:deepslate_diamond_ore" } },
  redstone = { label = "Redstone", short = "Rstone", y = -58, color = colors.red,       targets = { "minecraft:redstone_ore", "minecraft:deepslate_redstone_ore" } },
  gold     = { label = "Gold",     y = -16, color = colors.yellow,    targets = { "minecraft:gold_ore", "minecraft:deepslate_gold_ore" } },
  lapis    = { label = "Lapis",    y = 0,   color = colors.blue,      targets = { "minecraft:lapis_ore", "minecraft:deepslate_lapis_ore" } },
  iron     = { label = "Iron",     y = 16,  color = colors.orange,    targets = { "minecraft:iron_ore", "minecraft:deepslate_iron_ore" } },
  copper   = { label = "Copper",   y = 48,  color = colors.brown,     targets = { "minecraft:copper_ore", "minecraft:deepslate_copper_ore" } },
  coal     = { label = "Coal",     y = 48,  color = colors.gray,      targets = { "minecraft:coal_ore", "minecraft:deepslate_coal_ore" } },
}
local ORDER = { "diamond", "redstone", "gold", "lapis", "iron", "copper", "coal" }

-- Custom item, typed on the hub computer (CUSTOM button or the c key).
-- Rock: the turtles keep that item (plus the ores they find) instead of dropping it.
-- Anything else is taken as (part of) an ore name, also modded: "zinc", "emerald".
local ROCKS = {
  cobbled_deepslate = -16, cobblestone = 48, tuff = -16, granite = 48, diorite = 48,
  andesite = 48, calcite = -16, gravel = 16, flint = 16, dirt = 55, smooth_basalt = -50,
}
local ALIAS = {
  deepslate = "cobbled_deepslate", cobbled = "cobbled_deepslate", stone = "cobblestone", cobble = "cobblestone",
  diamonds = "diamond", raw_iron = "iron", raw_gold = "gold", raw_copper = "copper",
  lapis_lazuli = "lapis", basalt = "smooth_basalt",
}
local ORE_DEFAULT_Y = { emerald = 48, zinc = 32, tin = 32, osmium = 32, lead = 0, silver = 0,
  uranium = 0, nickel = 16, quartz = 16, sulfur = -30 }

local function prettyItem(n)
  n = n:gsub("^[^:]*:", ""):gsub("_", " ")
  return n:sub(1, 1):upper() .. n:sub(2)
end

-- "Cobbled Deepslate" -> kind, data. kind: "ore" (a button ore), "rock", "match", or nil + error
local function resolveItem(text)
  local n = text:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("[%s%-]+", "_")
  if n == "" then return nil end
  local mod = n:match("^([%w_]+):") or "minecraft"
  n = n:gsub("^[%w_]+:", "")
  n = ALIAS[n] or n
  if ORES[n] then return "ore", n end
  if ROCKS[n] then
    local keep = { "minecraft:" .. n }
    if n == "gravel" then keep[2] = "minecraft:flint" elseif n == "flint" then keep[2] = "minecraft:gravel" end
    return "rock", { item = "minecraft:" .. n, keep = keep, y = ROCKS[n] }
  end
  -- An ore name: keep the core word ("raw_zinc", "deepslate_zinc_ore" -> "zinc")
  local word = n:gsub("^raw_", ""):gsub("^deepslate_", ""):gsub("_ore$", ""):gsub("^ore_", ""):gsub("_ingot$", "")
  if ORES[ALIAS[word] or word] then return "ore", ALIAS[word] or word end
  if #word < 3 then return nil, "Too short: type more of the name" end
  for _, bad in ipairs({ "log", "plank", "wool", "wood", "leaves", "sapling", "seeds", "wheat" }) do
    if word:find(bad, 1, true) then return nil, "Turtles can't mine " .. word .. " underground" end
  end
  return "match", { match = word, mod = mod, y = ORE_DEFAULT_Y[word] or 16 }
end

local function customEntry(c)
  if type(c) ~= "table" then return nil end
  local label = c.label or "Custom"
  return { label = label, short = label:sub(1, 12), y = c.y, color = colors.white, targets = {},
    keep = c.keep, match = c.match, custom = true }
end

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
-- Session timer: how long the fleet mines after you pick an ore (seconds)
-- Session lengths on the dashboard: 10 minutes up to 1 hour
local TIMES = { { " 10m ", 600 }, { " 20m ", 1200 }, { " 30m ", 1800 }, { " 45m ", 2700 }, { " 1h ", 3600 } }
local validLen = false
for _, opt in ipairs(TIMES) do if hub.sessionLen == opt[2] then validLen = true end end
if not validLen then hub.sessionLen = 1800 end -- also replaces an old "no limit" or 2h/4h
-- Mining mode: "thorough" (branches every 4, wall checks) or "fast" (every 2, no turning)
hub.mode = hub.mode or "thorough"
ORES.custom = customEntry(hub.custom)
if not ORES.custom then
  if hub.target == "custom" then hub.target = nil end
  for id, o in pairs(hub.overrides) do if o == "custom" then hub.overrides[id] = nil end end
end
hub.sessionEnd = hub.sessionEnd -- os.epoch("utc") in ms, nil = no session running
hub.released = hub.released -- hash of the miner.lua released with UPDATE
hub.recallAll = hub.recallAll or false
hub.bores = hub.bores or {} -- [turtle id] = tunnel job { x=, z=, every=, n= } (runs until done or STOP)

local function save()
  local h = fs.open(STATE_FILE, "w")
  h.write(textutils.serialize(hub))
  h.close()
end

local turtles = {} -- [id] = { p = status packet, seen = os.clock() }
local selected = nil -- nil = all turtles
local wantAsk = false -- CUSTOM tapped: ask for the item on the hub computer

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
      c = { branch = L.branch, step = L.step, junction = L.junction, spine = math.max(L.spine or 0, c and c.spine or 0),
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

-- Session timer helpers
local function nowMs() return os.epoch("utc") end
local function sessionLeft()
  if not hub.sessionEnd then return nil end
  return math.max(0, (hub.sessionEnd - nowMs()) / 1000)
end
local function startSession()
  hub.sessionEnd = hub.sessionLen and (nowMs() + hub.sessionLen * 1000) or nil
  hub.session = { start = nowMs(), haul = {} } -- for the info screen
end
local function anyMining()
  if hub.target then return true end
  for _, o in pairs(hub.overrides) do if o then return true end end
  return false
end

-- Only a version released with the UPDATE button is handed out
-- (and only while the file is still exactly that version).
local function releasedVersion()
  local hash = minerVersion()
  if hash and hash == hub.released then return hash end
  return nil
end

local notice, noticeUntil = nil, 0
local function flash(text)
  notice, noticeUntil = text, os.clock() + 8
end

local function handle(id, m)
  if type(m) ~= "table" then return end
  if m.type == "status" then
    turtles[id] = { p = m, seen = os.clock() }
  elseif m.type == "job?" and hub.bores[id] then
    send(id, { type = "job", paused = hub.recallAll, bore = hub.bores[id], mineMinutes = hub.mineMinutes,
      progress = hub.progress[m.role], update = releasedVersion() })
  elseif m.type == "job?" then
    local ore = oreFor(id)
    local left = sessionLeft()
    -- less than 3 minutes left: don't start a new trip
    local paused = (ore == nil) or hub.recallAll or (left ~= nil and left < 180)
    local o = ore and ORES[ore]
    send(id, {
      type = "job", paused = paused, ore = (not paused) and ore or nil,
      y = o and o.y, targets = o and o.targets, keep = o and o.keep, match = o and o.match, label = o and o.label, branchLen = hub.branchLen, mineMinutes = hub.mineMinutes, reach = hub.reach, stopIn = left, mode = hub.mode, only = hub.only,
      progress = hub.progress[m.role],
      update = releasedVersion(),
    })
  elseif m.type == "get_miner" then
    local hash, code = minerVersion()
    if code and hash == hub.released then send(id, { type = "miner_file", hash = hash, code = code }) end
  elseif m.type == "report" then
    mergeProgress(m.role, m.progress)
    -- A tunnel job ended (done, or something stopped it): the turtle stays home
    local b = hub.bores[id]
    if b and type(m.bore) == "table" and m.bore.n == b.n then
      hub.bores[id] = nil
      hub.overrides[id] = false
      flash("#" .. id .. ": " .. tostring(m.bore.why))
    end
    for name, n in pairs(m.haul or {}) do
      if type(n) == "number" then
        hub.totals[name] = (hub.totals[name] or 0) + n
        if hub.session then hub.session.haul[name] = (hub.session.haul[name] or 0) + n end
      end
    end
    save()
  end
end

---------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------
local screens = { { t = term.native(), name = "term", buttons = {} } }
-- Monitors: the biggest advanced monitor gets the dashboard (touch buttons).
-- Normal monitors can't be tapped, so they always get the info screen.
local function monSize(m) local w, h = m.getSize() return w * h end
local dash
for _, m in ipairs({ peripheral.find("monitor") }) do
  if m.isColor() then
    if not dash or monSize(m) > monSize(dash) then dash = m end
  end
end
if dash then
  dash.setTextScale(1)
  local w = dash.getSize()
  if w < 50 then dash.setTextScale(0.5) end
  screens[#screens + 1] = { t = dash, name = peripheral.getName(dash), buttons = {} }
end
for _, m in ipairs({ peripheral.find("monitor") }) do
  if m ~= dash and peripheral.getName(m) ~= (dash and peripheral.getName(dash)) then
    m.setTextScale(1)
    local w, h = m.getSize()
    if w < 26 or h < 12 then m.setTextScale(0.5) end
    screens[#screens + 1] = { t = m, name = peripheral.getName(m), buttons = {}, info = true }
  end
end

local function setTarget(ore)
  if not anyMining() or not hub.sessionEnd then startSession() end
  if selected then
    hub.overrides[selected] = ore
    hub.bores[selected] = nil
  else
    hub.target = ore
    hub.overrides = {}
    hub.recallAll = false
    send(nil, { type = "go" })
  end
  save()
end

-- Time buttons: set the session length; while mining, the countdown restarts
local function setLimit(sec)
  hub.sessionLen = sec
  if anyMining() then startSession() end
  save()
end

-- How far from its shaft a turtle may mine (blocks). Further = more ore per layer,
-- but the chunks out there must stay loaded (a player nearby or a chunk loader).
local function setReach(n)
  if not n then
    n = 64
    for _, r in ipairs({ 64, 96, 128, 160, 192 }) do if r > hub.reach then n = r break end end
  end
  hub.reach = math.floor(math.max(16, math.min(256, n)))
  save()
  flash("Reach: " .. hub.reach .. " blocks from the shaft (next trip). Keep those chunks loaded.")
end

local function stopAll()
  if selected then
    hub.overrides[selected] = false
    hub.bores[selected] = nil
  else
    hub.target = nil
    hub.overrides = {}
    hub.bores = {}
    hub.sessionEnd = nil
  end
  save()
end

local function recallNow()
  if selected then
    hub.overrides[selected] = false -- stays home until you pick an ore
    hub.bores[selected] = nil
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

-- Common blocks, unless it's the custom item the turtles are collecting
local function isCommon(name)
  if not COMMON[name] then return false end
  local c = ORES.custom
  if c and c.keep then for _, k in ipairs(c.keep) do if k == name then return false end end end
  return true
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
  -- Top line: the current job (or a LOST alert / notice), mode button on the right.
  -- One empty line between every row of buttons, so they are easy to tap.
  local lost = {}
  for id, r in pairs(turtles) do
    if r.p.phase == "lost" then
      lost[#lost + 1] = (r.p.label or ("#" .. id)) .. " at " .. tostring(r.p.x) .. "," .. tostring(r.p.y) .. "," .. tostring(r.p.z)
    end
  end
  local modeLabel = (hub.mode == "fast") and " FAST " or " THOROUGH "
  -- ONLY switch: keep only the chosen ore, drop every other ore underground
  local tgt = hub.target and ORES[hub.target]
  local onlyLabel = hub.only and (" ONLY " .. (tgt and (tgt.short or tgt.label):upper() or "ORE") .. " ") or " ALL ORES "
  local onlyX = W - #modeLabel - #onlyLabel
  local topW = onlyX - 2
  local y = 1
  if #lost > 0 then
    at(1, y, ("LOST: " .. table.concat(lost, "  ")):sub(1, topW), colors.red)
  elseif notice and os.clock() < noticeUntil then
    at(1, y, notice:sub(1, topW), colors.yellow)
  elseif selected and turtles[selected] then
    at(1, y, ("Orders for: " .. (turtles[selected].p.label or ("#" .. selected))):sub(1, topW), colors.yellow)
  else
    local job, jc
    if hub.recallAll then job, jc = "RECALLED", colors.red
    elseif hub.target then job, jc = "Mining " .. ORES[hub.target].label .. " (Y " .. ORES[hub.target].y .. ")", colors.lime
    else job, jc = "Stopped", colors.red end
    at(1, y, job:sub(1, topW), jc)
  end
  button(onlyX, y, onlyLabel, hub.only and colors.black or colors.white, hub.only and colors.orange or colors.gray, function()
    hub.only = not hub.only
    save()
    flash(hub.only and "Only the chosen ore is kept, other ores get dropped (next trip)" or "All ores are kept again (next trip)")
  end)
  button(W - #modeLabel + 1, y, modeLabel, colors.black, (hub.mode == "fast") and colors.orange or colors.cyan, function()
    hub.mode = (hub.mode == "fast") and "thorough" or "fast"
    save()
    flash("Mode: " .. hub.mode .. " (from the next branch on)")
  end)

  -- Ore buttons
  y = y + 2
  local x = 1
  -- All on one line when they fit; if the gaps don't all fit, the last buttons touch
  local sum = 0
  for _, ore in ipairs(ORDER) do sum = sum + #(ORES[ore].short or ORES[ore].label) + 2 end
  local gaps = W - sum
  for i, ore in ipairs(ORDER) do
    local o = ORES[ore]
    local label = " " .. (o.short or o.label) .. " "
    if x + #label - 1 > W then x = 1 y = y + 2 end
    local active = (selected and oreFor(selected) == ore) or (not selected and hub.target == ore)
    x = button(x, y, label, active and colors.black or colors.white, active and colors.lime or o.color,
      function() setTarget(ore) end)
    if gaps >= 0 and gaps < #ORDER - 1 then -- squeeze: fewer gaps than buttons
      x = x - 1
      if gaps > 0 then x = x + 1 gaps = gaps - 1 end
    end
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
  -- Custom item: shows what it is when active; tapping it asks on the hub computer
  do
    local cur = selected and oreFor(selected) or (not selected and hub.target)
    local active = cur == "custom" and ORES.custom
    local label = active and (" " .. ORES.custom.short .. " ") or " CUSTOM "
    local cx = math.max(x, W - #label + 1)
    button(cx, y, label:sub(1, W - cx + 1), active and colors.black or colors.white, active and colors.lime or colors.gray,
      function() wantAsk = true end)
  end

  -- Session timer
  y = y + 2
  x = 1
  at(x, y, "Time", colors.lightGray)
  x = 6
  for _, opt in ipairs(TIMES) do
    local active = hub.sessionLen == opt[2]
    local sec = opt[2]
    x = button(x, y, opt[1], active and colors.black or colors.white, active and colors.lime or colors.gray,
      function() setLimit(sec) end)
  end
  local left = sessionLeft()
  if left then
    local t = math.floor(left)
    at(x, y, string.format("%d:%02d:%02d", math.floor(t / 3600), math.floor(t / 60) % 60, t % 60),
      left < 300 and colors.orange or colors.white)
  end
  local reachLabel = " REACH " .. hub.reach .. " "
  if W - #reachLabel + 1 > x + 8 then
    button(W - #reachLabel + 1, y, reachLabel, colors.white, colors.blue, function() setReach() end)
  end

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
    local ore = p.ore and ORES[p.ore] and ORES[p.ore].label or (p.ore == "tunnel" and "Tunnel") or "-"
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
    local want = minerVersion()
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

  -- Detail line: full status + last error of the selected turtle,
  -- or else the most recent error of any turtle (last 30 minutes)
  local function ago(ms)
    local sec = math.max(0, (nowMs() - ms) / 1000)
    if sec < 60 then return math.floor(sec) .. "s ago" end
    if sec < 3600 then return math.floor(sec / 60) .. "m ago" end
    return math.floor(sec / 3600) .. "h ago"
  end
  local detail = {}
  local sel = selected and turtles[selected]
  if sel then
    detail[#detail + 1] = { (sel.p.label or ("#" .. selected)) .. ": " .. tostring(sel.p.status), colors.white }
    local hubVer = minerVersion()
    local ver = "Version " .. tostring(sel.p.hash or "old (no version)")
    if hubVer and sel.p.hash ~= hubVer then
      ver = ver .. ", hub has " .. hubVer .. (hubVer == hub.released and " (updates when home)" or " (press UPDATE)")
    else
      ver = ver .. " (up to date)"
    end
    detail[#detail + 1] = { ver, colors.lightGray }
    if sel.p.lastError then
      detail[#detail + 1] = { "Last error " .. ago(sel.p.lastErrorAt or 0) .. ": " .. sel.p.lastError, colors.orange }
    end
  else
    local best
    for id, r in pairs(turtles) do
      if r.p.lastError and r.p.lastErrorAt and (not best or r.p.lastErrorAt > best.p.lastErrorAt) then best = r end
    end
    if best and nowMs() - best.p.lastErrorAt < 30 * 60 * 1000 then
      detail[#detail + 1] = { (best.p.label or "?") .. " error " .. ago(best.p.lastErrorAt) .. ": " .. best.p.lastError, colors.orange }
    end
  end
  for _, d in ipairs(detail) do
    local text = d[1]
    while #text > 0 and y <= H - 2 do
      at(1, y, text:sub(1, W), d[2])
      text = text:sub(W + 1)
      y = y + 1
    end
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
  for name, n in pairs(sum) do list2[#list2 + 1] = { name = name, n = n, common = isCommon(name) and 1 or 0 } end
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
  at(1, H, ("Tap a turtle = only that one. 1-7 ore c custom s stop r recall u update q quit"):sub(1, W), colors.gray)
end

-- Info screen for a normal (grey) monitor: no buttons, just the overview
local function drawInfo(s)
  local t = s.t
  local W, H = t.getSize()
  t.setBackgroundColor(colors.black)
  t.clear()
  local y = 1
  local function line(text, c, right, rc)
    if y > H then return end
    t.setCursorPos(1, y)
    t.setTextColor(c or colors.white)
    if right and #right + 2 <= W then text = text:sub(1, W - #right - 1) end
    t.write(text:sub(1, W))
    if right and #text + #right + 1 <= W then
      t.setCursorPos(W - #right + 1, y)
      t.setTextColor(rc or colors.lightGray)
      t.write(right)
    end
    y = y + 1
  end
  local function hr() line(string.rep("-", W), colors.gray) end
  local function itemLines(tbl, max)
    local l = {}
    for name, n in pairs(tbl) do if not isCommon(name) then l[#l + 1] = { name = name, n = n } end end
    table.sort(l, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    for i = 1, math.min(#l, max) do line(" " .. prettyName(l[i].name), colors.white, tostring(l[i].n), colors.white) end
    if #l == 0 then line(" nothing yet", colors.gray) end
  end

  local small = W < 26
  local left = sessionLeft()
  local leftTxt
  if left then
    local sec = math.floor(left)
    leftTxt = small and string.format("%d:%02d", math.floor(sec / 60), sec % 60)
      or string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
  end
  local job, jc
  if hub.recallAll then job, jc = "RECALLED", colors.white
  elseif hub.target then
    local o = ORES[hub.target]
    job, jc = small and ((o.short or o.label) .. " Y" .. o.y) or ("Mining " .. o.label .. (hub.only and " only" or "") .. " (Y " .. o.y .. ")"), colors.white
  else job, jc = "Stopped", colors.lightGray end
  if small then
    -- Tiny monitor: job + time left on one line, no title
    line(job, jc, leftTxt, colors.white)
  else
    line("MINE ARMY", colors.white, textutils.formatTime(os.time(), true), colors.lightGray)
    hr()
    line(job, jc)
    if leftTxt then line("Time left", colors.lightGray, leftTxt, colors.white) end
  end
  -- Fleet
  local out, home, trouble, fuel, n = 0, 0, 0, 0, 0
  for _, r in pairs(turtles) do
    n = n + 1
    local p = r.p
    if p.phase == "lost" or tostring(p.status):find("^STUCK") or tostring(p.status):find("^ERROR") then trouble = trouble + 1
    elseif p.phase == "home" then home = home + 1 else out = out + 1 end
    if type(p.fuel) == "number" then fuel = fuel + p.fuel end
  end
  local fleet = small and (out .. " out, " .. home .. " home") or (n .. " turtles: " .. out .. " out, " .. home .. " home")
  if trouble > 0 then fleet = small and (trouble .. " NEED YOU!") or (fleet .. ", " .. trouble .. " need you!") end
  line(fleet, trouble > 0 and colors.white or colors.lightGray)
  if small then hr() else y = y + 1 end

  -- This session: what was delivered to the chests, and how fast
  local sess = hub.session
  local title = small and "SESSION" or ((hub.sessionEnd and "THIS SESSION") or "LAST SESSION")
  local rate = ""
  if sess and sess.start then
    local mins = math.max(1, ((sess.stop or nowMs()) - sess.start) / 60000)
    local ores = 0
    for name, c in pairs(sess.haul) do if not isCommon(name) then ores = ores + c end end
    rate = small and (math.floor(ores * 60 / mins) .. "/h") or (math.floor(mins) .. "m, " .. math.floor(ores * 60 / mins) .. " ores/h")
  end
  line(title, colors.lightGray, rate, colors.gray)
  itemLines(sess and sess.haul or {}, small and 3 or 4)
  y = y + 1

  -- The turtles, one line each
  if not small and y + 1 <= H - 4 then
    line("TURTLES", colors.lightGray, "Y    fuel", colors.gray)
    for _, id in ipairs(ids()) do
      if y > H - 5 then break end
      local p = turtles[id].p
      local name = (p.label or ("#" .. id)):gsub("^Miner%-", "")
      local PH = { mining = "mining", returning = "going home", descending = "going down", home = "home", lost = "LOST!" }
      local where = PH[p.phase] or p.phase or "?"
      if os.clock() - turtles[id].seen > STALE and p.phase ~= "home" then where = "underground" end
      local right = string.format("%4s %5s", tostring(p.y or "?"), type(p.fuel) == "number" and tostring(p.fuel) or "inf")
      line(" " .. string.format("%-6s %s", name:sub(1, 6), where), p.phase == "lost" and colors.white or colors.lightGray, right, colors.gray)
    end
    y = y + 1
  end

  -- All time
  if y < H then
    line("ALL TIME", colors.lightGray)
    itemLines(hub.totals, H - y + 1)
  end
end

local function redraw()
  for _, s in ipairs(screens) do
    if s.info then drawInfo(s) else draw(s) end
  end
end

-- Ask for a custom item on the hub computer (monitors have no keyboard)
local function askCustom()
  flash("Type the item on the hub PC")
  redraw()
  local t = term.native()
  local prev = term.redirect(t)
  t.setBackgroundColor(colors.black)
  t.setTextColor(colors.white)
  t.clear()
  t.setCursorPos(1, 1)
  print("Mine for which item? (Enter = cancel)")
  print("Rock: cobbled deepslate, cobblestone, tuff,")
  print("  granite, diorite, andesite, gravel, dirt")
  print("Ores: emerald, zinc, tin, osmium, ...")
  write("> ")
  local text = read()
  local kind, data = resolveItem(text or "")
  if not kind then
    if data then print(data) sleep(2) end
    term.redirect(prev)
    return
  end
  if kind == "ore" then
    setTarget(data)
    flash("Mining " .. ORES[data].label)
    term.redirect(prev)
    return
  end
  print("Height (Y) to mine at? (Enter = " .. data.y .. ")")
  write("> ")
  local y = tonumber(read() or "") or data.y
  y = math.floor(math.max(-59, math.min(55, y)))
  local label
  if kind == "rock" then
    label = prettyItem(data.item)
    hub.custom = { label = label, y = y, keep = data.keep }
    print("Collecting " .. label .. " at Y " .. y .. " (and the ores they find).")
  else
    label = prettyItem(data.match)
    hub.custom = { label = label, y = y, match = data.match }
    print("Mining every ore with '" .. data.match .. "' in its name at Y " .. y .. ".")
    print("If nothing is found, check the name (e.g. with F3 on the block).")
  end
  ORES.custom = customEntry(hub.custom)
  setTarget("custom")
  flash("Mining " .. label .. " at Y " .. y)
  sleep(2)
  term.redirect(prev)
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

-- Developer commands from the pocket panel's console (panel.lua): info, log, ls, cat,
-- get (copy a file to the pocket), reboot, and put / rm / lua (write or delete a file,
-- run Lua). If this computer has a file "dev.key", every command needs that same
-- password (on the pocket: key <password>). put, rm and lua only work once dev.key exists.
-- drive: move / turn / dig / place / look, answered with the position and the blocks
-- around it, for the pocket's map. hooks (optional) let the program keep its own idea of
-- where it is: pose() -> x, y, z, forward x, forward z (map: +x right, +z down),
-- turn(right), move("forward"|"back"|"up"|"down") -> ok, why; busy() -> reason or nil.
local devDrive = { x = 0, y = 0, z = 0, h = 0 } -- position used when there are no hooks
local function devDriveHooks()
  local HX, HZ = { [0] = 0, 1, 0, -1 }, { [0] = -1, 0, 1, 0 }
  local p = devDrive
  return {
    pose = function() return p.x, p.y, p.z, HX[p.h], HZ[p.h] end,
    turn = function(right)
      if right then turtle.turnRight() else turtle.turnLeft() end
      p.h = (p.h + (right and 1 or 3)) % 4
    end,
    move = function(dir)
      local ok, why = ({ forward = turtle.forward, back = turtle.back, up = turtle.up, down = turtle.down })[dir]()
      if ok then
        local s = dir == "back" and -1 or 1
        if dir == "up" then p.y = p.y + 1 elseif dir == "down" then p.y = p.y - 1
        else p.x, p.z = p.x + s * HX[p.h], p.z + s * HZ[p.h] end
      end
      return ok, why
    end,
  }
end

local function devCommand(m, logFile, program, reply, hooks)
  local r = { type = "dev_reply", rid = m.rid, ok = true }
  local function out(s) r.out = tostring(s) end
  local key
  if fs.exists("dev.key") then
    local h = fs.open("dev.key", "r")
    key = (h.readAll() or ""):gsub("%s+$", "")
    h.close()
  end
  local op, path = m.op, tostring(m.path or "")
  if key and key ~= "" and m.key ~= key then r.ok = false out("Wrong or missing dev key")
  elseif op == "info" then
    local fuel = turtle and turtle.getFuelLevel() or nil
    local free = 0
    if turtle then for s = 1, 16 do if turtle.getItemCount(s) == 0 then free = free + 1 end end end
    out((os.getComputerLabel() or "?") .. " #" .. os.getComputerID() .. " running " .. program
      .. (fuel and (" | fuel " .. tostring(fuel) .. " | " .. free .. " free slots") or "")
      .. " | up " .. math.floor(os.clock() / 60) .. " min | disk free " .. math.floor(fs.getFreeSpace("/") / 1024) .. " KB")
  elseif op == "log" then
    if not logFile or not fs.exists(logFile) then out("No log file")
    else
      local h = fs.open(logFile, "r")
      local lines = {}
      for l in (h.readAll() .. "\n"):gmatch("([^\n]*)\n") do if l ~= "" then lines[#lines + 1] = l end end
      h.close()
      local n = math.max(1, tonumber(m.n) or 10)
      out(table.concat(lines, "\n", math.max(1, #lines - n + 1)))
      if #lines == 0 then out("Log is empty") end
    end
  elseif op == "ls" then
    if path == "" then path = "/" end
    if not fs.isDir(path) then r.ok = false out("No such folder: " .. path)
    else
      local l = {}
      for _, f in ipairs(fs.list(path)) do
        local p = fs.combine(path, f)
        l[#l + 1] = fs.isDir(p) and (f .. "/") or (f .. " " .. fs.getSize(p))
      end
      out(#l > 0 and table.concat(l, "\n") or "(empty)")
    end
  elseif op == "cat" or op == "get" then
    local name = fs.getName(path)
    if name == "api.key" or name == "dev.key" then r.ok = false out("Secret file, not sent")
    elseif not fs.exists(path) or fs.isDir(path) then r.ok = false out("No such file: " .. path)
    else
      local h = fs.open(path, "r")
      r.data = h.readAll()
      h.close()
      out(op == "cat" and r.data or (path .. ": " .. #r.data .. " bytes"))
      if op == "cat" then r.data = nil end
    end
  elseif (op == "put" or op == "rm" or op == "lua") and not (key and key ~= "") then
    r.ok = false
    out("Locked: pair it first (stand next to it with the pocket, type pair) to allow " .. op)
  elseif op == "put" then
    if path == "" or type(m.data) ~= "string" then r.ok = false out("put needs a file name and its contents")
    else
      if fs.exists(path) then
        if fs.exists(path .. ".bak") then fs.delete(path .. ".bak") end
        fs.copy(path, path .. ".bak")
      end
      local h = fs.open(path, "w")
      h.write(m.data)
      h.close()
      out("Wrote " .. path .. " (" .. #m.data .. " bytes, the old one is " .. path .. ".bak)")
    end
  elseif op == "rm" then
    if path == "" or not fs.exists(path) then r.ok = false out("No such file: " .. path)
    else fs.delete(path) out("Deleted " .. path) end
  elseif op == "lua" then
    local env = setmetatable({}, { __index = _ENV or _G })
    local code = tostring(m.code or "")
    local fn, err = load("return " .. code, "=dev", "t", env)
    if not fn then fn, err = load(code, "=dev", "t", env) end
    if not fn then r.ok = false out(err)
    else
      local res = table.pack(pcall(fn))
      r.ok = res[1]
      local l = {}
      for i = 2, res.n do
        local ok, s = pcall(textutils.serialize, res[i])
        l[#l + 1] = ok and s or tostring(res[i])
      end
      out(#l > 0 and table.concat(l, ", ") or "(done, nothing returned)")
    end
  elseif op == "drive" then
    local hk = hooks or devDriveHooks()
    local why = not turtle and "This is not a turtle" or (hk.busy and hk.busy())
    local act = tostring(m.act or "scan")
    local seen = {}
    local function look(dx, dy, dz, fn)
      local x, y, z = hk.pose()
      local ok, info = fn()
      seen[#seen + 1] = { x = x + dx, y = y + dy, z = z + dz, name = ok and info.name or "air" }
    end
    local function lookFront() local _, _, _, fx, fz = hk.pose() look(fx, 0, fz, turtle.inspect) end
    if why then r.ok = false out(why)
    else
      local ok, err = true, nil
      if act == "left" or act == "right" then hk.turn(act == "right")
      elseif act == "forward" or act == "back" or act == "up" or act == "down" then
        if turtle.getFuelLevel() == 0 then ok, err = false, "Out of fuel" else ok, err = hk.move(act) end
      elseif act == "dig" then ok, err = turtle.dig()
      elseif act == "digUp" then ok, err = turtle.digUp()
      elseif act == "digDown" then ok, err = turtle.digDown()
      elseif act == "place" then ok, err = turtle.place()
      elseif act == "placeUp" then ok, err = turtle.placeUp()
      elseif act == "placeDown" then ok, err = turtle.placeDown()
      elseif act == "look" then for _ = 1, 4 do lookFront() hk.turn(true) end
      elseif act ~= "scan" then ok, err = false, "Unknown move: " .. act end
      lookFront()
      look(0, 1, 0, turtle.inspectUp)
      look(0, -1, 0, turtle.inspectDown)
      local x, y, z, fx, fz = hk.pose()
      r.drive = { x = x, y = y, z = z, fx = fx, fz = fz, seen = seen, fuel = turtle.getFuelLevel(), home = hk.home }
      r.ok = ok and true or false
      out(ok and (act == "scan" and "Ready" or "OK") or (act .. ": " .. tostring(err or "can't")))
    end
  elseif op == "reboot" then
    out("Rebooting...")
    reply(r)
    sleep(0.5)
    os.reboot()
    return
  else r.ok = false out("Unknown dev command: " .. tostring(op)) end
  reply(r)
end

-- Pairing with the pocket's "pair" command: the pocket sends its password on a modem
-- channel and this computer saves it as dev.key, but only if the pocket is within 3 blocks
-- (so only someone standing next to it can pair) and it has no dev.key yet.
local DEV_PAIR_CHANNEL = 16523
local function devPairLoop()
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then while true do os.pullEvent("dev_never") end end
  modem.open(DEV_PAIR_CHANNEL)
  while true do
    local _, _, ch, replyCh, msg, dist = os.pullEvent("modem_message")
    if ch == DEV_PAIR_CHANNEL and type(msg) == "table" and msg.type == "dev_pair" then
      local res
      if fs.exists("dev.key") then res = "Already paired"
      elseif type(dist) ~= "number" or dist > 3 then res = "Too far away"
      elseif type(msg.newKey) ~= "string" or #msg.newKey < 8 then res = "Bad password"
      else
        local h = fs.open("dev.key", "w")
        h.write(msg.newKey)
        h.close()
        res = "Paired"
      end
      modem.transmit(replyCh, DEV_PAIR_CHANNEL, { type = "dev_pair_reply", id = os.getComputerID(),
        label = os.getComputerLabel(), text = res })
    end
  end
end

-- Pocket control panel (panel.lua): it asks for the dashboard and taps the same buttons.
-- m.turtle = give the order to that turtle only (like tapping it in the list first).
local function panelRequest(id, m)
  local prev, note = selected, nil
  selected = m.turtle and turtles[m.turtle] and m.turtle or nil
  if m.cmd == "target" and ORES[m.ore or ""] then setTarget(m.ore)
  elseif m.cmd == "stop" then stopAll()
  elseif m.cmd == "recall" then recallNow()
  elseif m.cmd == "resume" then resumeAll()
  elseif m.cmd == "limit" and tonumber(m.sec) then setLimit(tonumber(m.sec))
  elseif m.cmd == "reach" then setReach(tonumber(m.n))
  elseif m.cmd == "bore" then
    -- Tunnel job for one turtle: a lit 3x3 tunnel from its shaft to x z (see miner.lua)
    local x, z = tonumber(m.x), tonumber(m.z)
    if not selected then note = "Pick one turtle for the tunnel first"
    elseif not (x and z) then note = "Tunnel needs an end point: x z"
    else
      hub.boreN = (hub.boreN or 0) + 1
      hub.bores[selected] = { x = math.floor(x), z = math.floor(z), every = math.floor(tonumber(m.every) or 8), n = hub.boreN }
      save()
      send(selected, { type = "go", target = selected })
      note = "Tunnel to " .. math.floor(x) .. "," .. math.floor(z) .. " for #" .. selected
    end
  elseif m.cmd == "update" then
    -- panel's Update all: fetch hub.lua and miner.lua; after the reboot the new miner.lua
    -- is released to the turtles (see the end of this file)
    flash("Pocket: updating from GitHub...")
    pcall(redraw)
    local h = fs.open("hub.release", "w") h.close()
    if not fs.exists("update.lua") then
      shell.run("wget", "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/update.lua", "update.lua")
    end
    shell.run("update") -- reboots when anything changed
    fs.delete("hub.release")
    note = "Already up to date"
  elseif m.cmd == "custom" then
    local kind, data = resolveItem(tostring(m.text or ""))
    if kind == "ore" then setTarget(data)
    elseif kind then
      local y = math.floor(math.max(-59, math.min(55, tonumber(m.y) or data.y)))
      local label = prettyItem(kind == "rock" and data.item or data.match)
      hub.custom = { label = label, y = y, keep = data.keep, match = data.match }
      ORES.custom = customEntry(hub.custom)
      setTarget("custom")
    else note = data or "Unknown item" end
  end
  selected = prev
  if m.cmd then flash(note or ("Pocket: " .. m.cmd)) pcall(redraw) end
  local ores = {}
  local order = { table.unpack(ORDER) }
  if ORES.custom then order[#order + 1] = "custom" end
  for _, k in ipairs(order) do
    local o = ORES[k]
    ores[#ores + 1] = { key = k, label = o.label, short = o.short or o.label, y = o.y, color = o.color }
  end
  local list = {}
  for _, tid in ipairs(ids()) do
    local r, own = turtles[tid], hub.overrides[tid]
    local p = r.p
    list[#list + 1] = { id = tid, label = p.label, status = p.status, phase = p.phase, fuel = p.fuel,
      free = p.free, x = p.x, y = p.y, z = p.z, ore = (own == false) and "stop" or (hub.bores[tid] and "tunnel") or oreFor(tid), branch = p.branch,
      age = os.clock() - r.seen, err = p.lastError }
  end
  local haul = {}
  for name, n in pairs(hub.session and hub.session.haul or {}) do
    if not isCommon(name) then haul[#haul + 1] = { name = name, n = n } end
  end
  table.sort(haul, function(a, b) return a.n > b.n end)
  send(id, { type = "panel_state", rid = m.rid, target = hub.target, recallAll = hub.recallAll,
    left = sessionLeft(), sessionLen = hub.sessionLen, mode = hub.mode, only = hub.only, reach = hub.reach,
    ores = ores, turtles = list, haul = { table.unpack(haul, 1, 6) }, note = note })
end

local function netLoop()
  while true do
    local id, msg = rednet.receive(PROTOCOL)
    if type(msg) == "table" and msg.type == "panel" then panelRequest(id, msg)
    elseif type(msg) == "table" and msg.type == "dev" then devCommand(msg, nil, "hub", function(r) send(id, r) end)
    else handle(id, msg) end
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
      -- Session over: stop everything, like STOP (turtles finish their trip and stay home)
      if hub.sessionEnd and nowMs() >= hub.sessionEnd then
        hub.target = nil
        hub.overrides = {}
        hub.sessionEnd = nil
        if hub.session then hub.session.stop = nowMs() end
        save()
        flash("Time is up: turtles come home and stay there.")
      end
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
      elseif a == "c" then wantAsk = true
      elseif a == "q" then return end
      redraw()
    elseif ev == "monitor_resize" or ev == "term_resize" then
      redraw()
    end
    if wantAsk then
      wantAsk = false
      askCustom()
      redraw()
      timer = os.startTimer(1) -- the old timer fired while typing
    end
  end
end

-- Just updated itself from GitHub ('hub update' or the panel): hand the new miner.lua out
if fs.exists("hub.release") then
  fs.delete("hub.release")
  releaseUpdate()
end

parallel.waitForAny(netLoop, uiLoop, devPairLoop)
term.native().setBackgroundColor(colors.black)
term.native().clear()
term.native().setCursorPos(1, 1)
print("Hub stopped.")
