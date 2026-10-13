-- roomsorter.lua - Storage room turtle (CC: Tweaked), no modems or cables needed
-- The turtle lives in a closed room with an INPUT chest and an OUTPUT chest in the walls.
-- It maps the room itself, builds chests and furnaces from the ones you give it, sorts
-- everything you put in the input chest, smelts raw ores and remembers where it all is.
-- Ask for items and it brings them to the output chest.
--
--   roomsorter scan [h]  first time: map the room (turtle on the floor facing the input
--                        chest). h = inside height; leave it out and it measures it
--   roomsorter           start (or: roomsorter install = start on boot)
--   roomsorter client    on a computer/pocket computer with a wireless modem: ask from outside
--
-- Commands (on the turtle, or in the client):
--   get <item> [n]   bring items to the output chest, e.g. "get iron ingot 32"
--   find <item>      how many there are       list   everything in storage
--   pause / resume / quit (turtle only)
--
-- Give it chests or barrels (storage) and furnaces / blast furnaces by putting them in the
-- input chest. Fuel for the turtle and the furnaces: coal, charcoal, coal blocks.

local MAP_FILE, IDX_FILE, POS_FILE = "room.map", "room.idx", "room.pos"
local CFG_FILE, STATS_FILE, LOG_FILE = "room.cfg", "room.stats", "room.log"
local PROTOCOL = "roomsorter"

local args = { ... }
if args[1] == "install" then
  -- roomsorter install         (turtle)
  -- roomsorter install board   (computer with the stock board monitor)
  local mode = args[2] and (" " .. args[2]) or ""
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("roomsorter' .. mode .. '")\n')
  h.close()
  print("roomsorter" .. mode .. " will now start automatically on boot.")
  return
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

local function saveTable(path, t)
  local h = fs.open(path, "w")
  h.write(textutils.serialize(t, { compact = true }))
  h.close()
end

---------------------------------------------------------------------------
-- Client: ask the turtle from a computer outside the room
---------------------------------------------------------------------------
local function pretty(name)
  local s = (name:match(":(.+)$") or name):gsub("_", " ")
  return s:sub(1, 1):upper() .. s:sub(2)
end

if args[1] == "client" then
  -- A wireless modem, or a wired modem with a cable to the board computer (which passes
  -- the messages on to the turtle)
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end) or peripheral.find("modem")
  if not modem then print("Needs a wireless modem, or a wired modem + cable to the board computer.") return end
  rednet.open(peripheral.getName(modem))
  local id, proto
  if modem.isWireless() then
    print("Looking for the storage turtle...")
    id = rednet.lookup(PROTOCOL)
    if not id then
      -- The turtle also sends its stock every 10 s: wait for that
      local timer = os.startTimer(15)
      while not id do
        local ev, a, b, c = os.pullEvent()
        if ev == "rednet_message" and c == PROTOCOL .. "_stock" then id = a
        elseif ev == "timer" and a == timer then break end
      end
    end
    if not id then
      print("No storage turtle found. Is it running roomsorter, with a wireless modem, within ~64 blocks?")
      return
    end
    proto = PROTOCOL
    print("Connected to the storage turtle.")
  else
    -- Wired: the board computer on the other end of the cable passes requests on
    print("Looking for the board computer on the cable...")
    id = rednet.lookup(PROTOCOL .. "_relay")
    if not id then
      print("Board computer not found on the cable. Check:")
      print("- the board computer runs the NEW roomsorter.lua and was rebooted (its own screen says 'Passing requests')")
      print("- a wired modem sits on the board computer itself, one on this computer, cable between them")
      return
    end
    proto = PROTOCOL .. "_relay"
    print("Connected through the board computer (#" .. id .. ").")
  end
  print("Commands: list [text], find <item>, get <item> [n], build, status, quit")
  local history = {}
  while true do
    write("> ")
    local line = read(nil, history)
    if not line or line == "quit" or line == "q" or line == "exit" then return end
    history[#history + 1] = line
    local words = {}
    for wd in line:gmatch("%S+") do words[#words + 1] = wd end
    if #words > 0 then
      local n = tonumber(words[#words])
      local text = table.concat(words, " ", 2, n and #words - 1 or #words)
      rednet.send(id, { cmd = words[1]:lower(), text = text, n = n }, proto)
      local from, reply
      repeat from, reply = rednet.receive(proto, 8) until not from or from == id
      if not from then print("No answer (out of range?)")
      elseif type(reply) == "table" then for _, l in ipairs(reply) do print(l) end
      else print(tostring(reply)) end
    end
  end
end

---------------------------------------------------------------------------
-- Board: stock-market display of what is in storage, on a computer with a
-- wireless modem and a monitor (the turtle sends its stock every few seconds)
---------------------------------------------------------------------------
local function fmtNum(n)
  n = math.floor(n)
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 100000 then return string.format("%dk", math.floor(n / 1000)) end
  local s = tostring(math.abs(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return (n < 0 and "-" or "") .. s
end

local boardTurtle -- id of the turtle, learned from its stock messages
local function board()
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then print("Needs a wireless (or ender) modem.") return end
  rednet.open(peripheral.getName(modem))
  local mon = peripheral.find("monitor")
  local t = mon or term.current()
  if mon then
    mon.setTextScale(1)
    local w, h = mon.getSize()
    if w < 40 or h < 8 then mon.setTextScale(0.5) end
    print("Stock board on " .. peripheral.getName(mon) .. ". Hold Ctrl+T to stop.")
  end
  local color = t.isColor()
  local HEX = {} -- colour -> blit character
  for i = 0, 15 do HEX[2 ^ i] = ("0123456789abcdef"):sub(i + 1, i + 1) end
  -- Colours: green/red on an advanced monitor, shades of grey on a normal one
  local C = color and {
    bg = colors.black, text = colors.white, dim = colors.gray, label = colors.lightGray,
    up = colors.lime, down = colors.red, flat = colors.lightGray,
    title = colors.blue, titleText = colors.white, upBg = colors.green, downBg = colors.red, ticker = colors.yellow,
  } or {
    bg = colors.black, text = colors.white, dim = colors.gray, label = colors.lightGray,
    up = colors.white, down = colors.lightGray, flat = colors.gray,
    title = colors.lightGray, titleText = colors.black, upBg = colors.white, downBg = colors.gray, ticker = colors.white,
  }
  local UP, DOWN = "\30", "\31"

  local HIST_FILE = "board.hist"
  local hist = loadTable(HIST_FILE) or {} -- { { t = ms, v = { [item] = count } } }, 1 per minute
  local data, lastMsg = nil, nil
  local flash = {} -- [item] = { untilMs, dir }
  local page, pages, nextPage, tick = 1, 1, 0, 0
  local function now() return os.epoch("utc") end

  local function sample()
    if not data then return end
    local last = hist[#hist]
    if last and now() - last.t < 60000 then return end
    local v = {}
    for k, n in pairs(data.totals) do v[k] = n end
    hist[#hist + 1] = { t = now(), v = v }
    while #hist > 180 do table.remove(hist, 1) end
    saveTable(HIST_FILE, hist)
  end

  -- Change over the last hour (or since the oldest sample)
  local function change(name, cur)
    local base
    for i = #hist, 1, -1 do
      if now() - hist[i].t >= 3600000 then base = hist[i] break end
    end
    base = base or hist[1]
    if not base then return 0, nil end
    local old = base.v[name] or 0
    return cur - old, old > 0 and (cur - old) * 100 / old or nil
  end

  -- Little chart: 2 points per character, 3 levels, drawn with the 2x3 block characters
  local function spark(name, cur, width)
    local pts = {}
    for i = math.max(1, #hist - width * 2 + 2), #hist do pts[#pts + 1] = hist[i].v[name] or 0 end
    pts[#pts + 1] = cur
    while #pts < width * 2 do table.insert(pts, 1, pts[1]) end
    local lo, hi = math.huge, -math.huge
    for _, p in ipairs(pts) do lo, hi = math.min(lo, p), math.max(hi, p) end
    local function lvl(p) if hi == lo then return 1 end return 1 + math.floor((p - lo) * 2 / (hi - lo) + 0.5) end
    local text, fg, bg = "", "", ""
    local up = cur >= pts[1]
    for i = 1, width do
      local a, b = lvl(pts[i * 2 - 1]), lvl(pts[i * 2])
      local bits = 0
      if a >= 3 then bits = bits + 1 end
      if b >= 3 then bits = bits + 2 end
      if a >= 2 then bits = bits + 4 end
      if b >= 2 then bits = bits + 8 end
      if a >= 1 then bits = bits + 16 end
      local f, g = HEX[up and C.up or C.down], HEX[C.bg]
      if b >= 1 then bits, f, g = 31 - bits, g, f end -- bottom-right pixel = inverted character
      text = text .. string.char(128 + bits)
      fg, bg = fg .. f, bg .. g
    end
    return text, fg, bg
  end

  local function put(x, y, s, fg, bg)
    t.setCursorPos(x, y)
    t.setTextColor(fg or C.text)
    t.setBackgroundColor(bg or C.bg)
    t.write(s)
  end
  local function rjust(s, n) s = tostring(s) if #s >= n then return s:sub(1, n) end return (" "):rep(n - #s) .. s end
  local function ljust(s, n) s = tostring(s) if #s >= n then return s:sub(1, n) end return s .. (" "):rep(n - #s) end

  local function draw()
    local W, H = t.getSize()
    t.setBackgroundColor(C.bg)
    t.clear()
    -- Title bar
    local clock = textutils.formatTime(os.time(), true)
    local signal
    if not lastMsg then signal = "CONNECTING"
    elseif now() - lastMsg > 60000 then signal = (tick % 2 == 0) and "NO SIGNAL" or ""
    else signal = "LIVE" end
    put(1, 1, (" "):rep(W), C.titleText, C.title)
    put(2, 1, W >= 30 and "ROOM EXCHANGE" or "STOCK", C.titleText, C.title)
    local right = signal .. "  " .. clock .. " "
    put(W - #right + 1, 1, right, C.titleText, C.title)
    if not data then
      put(2, 3, "Waiting for the storage turtle...", C.label)
      return
    end
    local items = {}
    local total = 0
    for name, n in pairs(data.totals) do items[#items + 1] = { name = name, n = n } total = total + n end
    table.sort(items, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)

    local y = 2
    if H >= 7 then
      local pct = data.size > 0 and math.floor(data.used * 100 / data.size) or 0
      local s = ("%s items  %d kinds  %d chests %d%% full  %d furnaces  %s"):format(fmtNum(total), #items,
        data.chests or 0, pct, data.furnaces or 0, data.full and "STORAGE FULL" or (data.state or ""))
      put(2, y, s:sub(1, W - 2), data.full and C.down or C.label)
      y = y + 1
    end
    -- Columns of entries
    -- Name up to 24 wide, whatever is left over becomes the trend chart
    local ncols = math.max(1, math.floor((W + 2) / 43))
    local ew = math.floor((W - (ncols - 1) * 2) / ncols)
    local showChg = ew >= 24
    local showPct = ew >= 40
    local rest = ew - 8 - (showChg and 9 or 0) - (showPct and 8 or 0)
    local nw, tw = rest, 0
    if rest >= 22 then
      nw = math.min(24, rest - 7)
      tw = rest - nw - 1
    end
    local function header(x)
      local s = ljust("ITEM", nw) .. rjust("QTY", 8) .. (showChg and rjust("CHG 1H", 9) or "") .. (showPct and rjust("%", 8) or "")
      if tw > 0 then s = s .. " " .. ljust("TREND", tw) end
      put(x, y, s, C.dim)
    end
    if H >= 5 then
      for c = 1, ncols do header(1 + (c - 1) * (ew + 2)) end
      y = y + 1
    end
    local top = y
    local rows = H - top -- last line = ticker
    local perPage = math.max(1, rows * ncols)
    pages = math.max(1, math.ceil(#items / perPage))
    if page > pages then page = 1 end
    for i = 1, perPage do
      local it = items[(page - 1) * perPage + i]
      if not it then break end
      local col = math.floor((i - 1) / rows)
      local x = 1 + col * (ew + 2)
      local ry = top + (i - 1) % rows
      local chg, pct = change(it.name, it.n)
      local dc = chg > 0 and C.up or chg < 0 and C.down or C.flat
      put(x, ry, ljust(pretty(it.name), nw - 1), C.text)
      local f = flash[it.name]
      if f and now() < f[1] then
        put(x + nw, ry, rjust(fmtNum(it.n), 7) .. " ", C.bg, f[2] > 0 and C.upBg or C.downBg)
      else
        put(x + nw, ry, rjust(fmtNum(it.n), 7), C.text)
      end
      local cx = x + nw + 8
      if showChg then
        local arrow = chg > 0 and UP or chg < 0 and DOWN or "="
        put(cx, ry, rjust(arrow .. (chg > 0 and "+" or "") .. (chg ~= 0 and fmtNum(chg) or ""), 9), dc)
        cx = cx + 9
      end
      if showPct then
        local ps = pct and (chg == 0 and "0.0%" or string.format("%+.1f%%", pct)) or (chg > 0 and "new" or "")
        put(cx, ry, rjust(ps, 8), dc)
        cx = cx + 8
      end
      if tw > 0 then
        local s, fg, bg = spark(it.name, it.n, tw)
        t.setCursorPos(cx + 1, ry)
        t.blit(s, fg, bg)
      end
    end
    if pages > 1 then
      local p = (" %d/%d "):format(page, pages)
      put(W - #p + 1, top - (H >= 5 and 1 or 0), p, C.dim)
    end
    -- Ticker tape on the last line
    local text, fg = "", ""
    for _, it in ipairs(items) do
      local chg = change(it.name, it.n)
      local seg1 = " " .. pretty(it.name):upper() .. " " .. fmtNum(it.n) .. " "
      local seg2 = (chg > 0 and UP .. "+" or chg < 0 and DOWN or "=") .. (chg ~= 0 and fmtNum(chg) or "") .. "  \7"
      text = text .. seg1 .. seg2
      fg = fg .. HEX[C.ticker]:rep(#seg1) .. HEX[chg > 0 and C.up or chg < 0 and C.down or C.flat]:rep(#seg2)
    end
    if #text > 0 then
      while #text < W * 2 do text, fg = text .. text, fg .. fg end
      local off = tick % #text
      local tt = (text .. text):sub(off + 1, off + W)
      local tf = (fg .. fg):sub(off + 1, off + W)
      t.setCursorPos(1, H)
      t.blit(tt, tf, HEX[C.bg]:rep(W))
    end
  end

  local frame = os.startTimer(0)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and c == PROTOCOL .. "_stock" and type(b) == "table" and type(b.totals) == "table" then
      if data then
        for name, n in pairs(b.totals) do
          local old = data.totals[name] or 0
          if n ~= old then flash[name] = { now() + 4000, n > old and 1 or -1 } end
        end
      end
      data, lastMsg, boardTurtle = b, now(), a
      sample()
    elseif ev == "timer" and a == frame then
      tick = tick + 1
      if now() >= nextPage then page = page % pages + 1 nextPage = now() + 10000 end
      sample()
      draw()
      frame = os.startTimer(0.3)
    elseif ev == "monitor_resize" then
      draw()
    end
  end
end

if args[1] == "board" then
  -- A wired modem too: pass rednet messages between the cable and the air, so a request
  -- computer on the cable can reach the turtle without its own wireless modem
  local wired = peripheral.find("modem", function(_, m) return not m.isWireless() end)
  if wired then
    rednet.open(peripheral.getName(wired))
    rednet.host(PROTOCOL .. "_relay", "board" .. os.getComputerID())
    if peripheral.find("monitor") then print("Passing requests from the cable on to the turtle.") end
    parallel.waitForAny(board, function()
      while true do
        local from, msg = rednet.receive(PROTOCOL .. "_relay")
        if type(msg) == "table" then
          local reply
          if not boardTurtle then
            reply = { "The board doesn't hear the turtle (yet). Wait for LIVE on the board." }
          else
            rednet.send(boardTurtle, msg, PROTOCOL)
            local deadline = os.clock() + 5
            while not reply do
              local f, r = rednet.receive(PROTOCOL, math.max(0.1, deadline - os.clock()))
              if not f then reply = { "The turtle didn't answer (busy or out of range?)." }
              elseif f == boardTurtle then reply = r end
            end
          end
          rednet.send(from, reply, PROTOCOL .. "_relay")
        end
      end
    end)
  else
    board()
  end
  return
end

if not turtle then print("Run this on a turtle (or 'roomsorter client' / 'roomsorter board' on a computer).") return end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
local cfg = loadTable(CFG_FILE) or {}
cfg.maxSize = cfg.maxSize or 48       -- the room may not reach further than this from the start
cfg.maxHeight = cfg.maxHeight or 24
cfg.maxCells = cfg.maxCells or 6000   -- max blocks of air in the room (16x16x4 = 1024)
cfg.maxFurnaces = cfg.maxFurnaces or 16
if not cfg.v2 then cfg.maxFurnaces, cfg.v2 = math.max(cfg.maxFurnaces, 16), true end
cfg.queue = cfg.queue or 32           -- max items waiting in one furnace
cfg.interval = cfg.interval or 5      -- seconds between looks in the input chest when idle
cfg.minFuel = cfg.minFuel or 1000     -- turtle refuels below this
cfg.extraSmelt = cfg.extraSmelt or {} -- e.g. { "minecraft:oak_log", "minecraft:sand" } (normal furnaces only)
cfg.noSmelt = cfg.noSmelt or {}
cfg.fuels = cfg.fuels or { "minecraft:charcoal", "minecraft:coal", "minecraft:coal_block", "minecraft:dried_kelp_block" }
saveTable(CFG_FILE, cfg)

local stats = loadTable(STATS_FILE) or {}
stats.smelted = stats.smelted or {}
stats.stored = stats.stored or 0
stats.delivered = stats.delivered or 0

---------------------------------------------------------------------------
-- Log + status
---------------------------------------------------------------------------
local status = { state = "Starting", note = nil, full = false }
local logLines = {}
local function log(msg, isError)
  table.insert(logLines, 1, { textutils.formatTime(os.time(), true) .. " " .. msg, isError })
  while #logLines > 10 do table.remove(logLines) end
  if isError then
    local h = fs.open(LOG_FILE, "a")
    if h then h.writeLine(os.date("%Y-%m-%d %H:%M ") .. msg) h.close() end
  end
  os.queueEvent("room_redraw")
end
local function setState(s) status.state = s os.queueEvent("room_redraw") end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------
local FUEL_VALUE = { -- items smelted per fuel item in a normal furnace (blast furnace: half)
  ["minecraft:coal"] = 8, ["minecraft:charcoal"] = 8, ["minecraft:coal_block"] = 80,
  ["minecraft:dried_kelp_block"] = 20, ["minecraft:lava_bucket"] = 100, ["minecraft:blaze_rod"] = 12,
}
local CHEST_ITEMS = { ["minecraft:chest"] = true, ["minecraft:barrel"] = true }
local FURNACE_ITEMS = { ["minecraft:furnace"] = "furnace", ["minecraft:blast_furnace"] = "blast" }

local function short(name) return name:match(":(.+)$") or name end
local function listHas(l, x) for _, v in ipairs(l) do if v == x then return true end end return false end

local function smeltKind(name)
  if listHas(cfg.noSmelt, name) then return nil end
  local n = short(name)
  if not n:find("_block$") and (n:find("^raw_") or n:find("_ore$") or n == "ancient_debris") then return "ore" end
  if listHas(cfg.extraSmelt, name) then return "extra" end
  return nil
end

-- What gets smelted first: the valuable ores, copper last
local function smeltPriority(name)
  local n = short(name)
  if n:find("debris") then return 100 end
  if n:find("gold") then return 50 end
  if n:find("iron") then return 40 end
  if n:find("copper") then return 10 end
  if smeltKind(name) == "extra" then return 5 end
  return 20 -- other (modded) ores: tin, silver, zinc, ...
end
local function byPriority(a, b)
  local pa, pb = smeltPriority(a.name), smeltPriority(b.name)
  if pa ~= pb then return pa > pb end
  return a.name < b.name
end

local maxStack = {} -- [item] = stack size, learned from the turtle's own slots
local function stackOf(name) return maxStack[name] or 64 end

---------------------------------------------------------------------------
-- Grid
---------------------------------------------------------------------------
-- Positions are relative to the start: x/z on the floor, heading 0 = facing the input chest
-- at the start, 1 = right of that, 2 = back, 3 = left.
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = -1, 0, 1, 0 }
local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function unkey(k)
  local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
  return tonumber(x), tonumber(y), tonumber(z)
end
local function step(k, d)
  local x, y, z = unkey(k)
  if d == "up" then return key(x, y + 1, z) end
  if d == "down" then return key(x, y - 1, z) end
  return key(x + DX[d], y, z + DZ[d])
end
local ALL_DIRS = { 0, 1, 2, 3, "up", "down" }
local function dirBetween(a, b)
  for _, d in ipairs(ALL_DIRS) do if step(a, d) == b then return d end end
end

-- map.cells[k]: "a" = free air, otherwise the name of the block there
local map = loadTable(MAP_FILE)
local idx = loadTable(IDX_FILE) or {} -- [cell] = { kind=, acc=, dir=, size=, items= }
local pos = loadTable(POS_FILE) or { x = 0, y = 0, z = 0, h = 0 }
local mapVersion = 0
local function saveMap() mapVersion = mapVersion + 1 saveTable(MAP_FILE, map) end
local function saveIdx() saveTable(IDX_FILE, idx) end
local function savePos() saveTable(POS_FILE, pos) end
local function here() return key(pos.x, pos.y, pos.z) end
local function free(k) return map.cells[k] == "a" end

-- Breadth-first search over free cells. Returns the first cell for which goal(k) is
-- true and the parent table, or the distance table when goal is nil.
local function bfs(from, goal, blocked)
  local prev, dist, queue, head = { [from] = false }, { [from] = 0 }, { from }, 1
  while queue[head] do
    local k = queue[head]
    head = head + 1
    if goal and goal(k) then return k, prev end
    for _, d in ipairs(ALL_DIRS) do
      local n = step(k, d)
      if prev[n] == nil and free(n) and not (blocked and blocked[n]) then
        prev[n] = k
        dist[n] = dist[k] + 1
        queue[#queue + 1] = n
      end
    end
  end
  if goal then return nil end
  return dist
end

local function findPath(from, to)
  local found, prev = bfs(from, function(k) return k == to end)
  if not found then return nil end
  local path, k = {}, to
  while k do table.insert(path, 1, k) k = prev[k] end
  return path
end

---------------------------------------------------------------------------
-- Moving (position and heading are saved before every move and turn)
---------------------------------------------------------------------------
local function turn(right)
  local nh = right and (pos.h + 1) % 4 or (pos.h + 3) % 4
  pos.pend = { turn = nh }
  savePos()
  if right then turtle.turnRight() else turtle.turnLeft() end
  pos.h = nh
  pos.pend = nil
  savePos()
end

local function turnTo(h)
  local diff = (h - pos.h) % 4
  if diff == 1 then turn(true)
  elseif diff == 3 then turn(false)
  elseif diff == 2 then turn(true) turn(true) end
end

local function rawMove(d)
  if d ~= "up" and d ~= "down" then turnTo(d) end
  pos.pend = { mv = d, fuel = turtle.getFuelLevel() }
  savePos()
  local ok, err
  if d == "up" then ok, err = turtle.up()
  elseif d == "down" then ok, err = turtle.down()
  else ok, err = turtle.forward() end
  if ok then pos.x, pos.y, pos.z = unkey(step(here(), d)) end
  pos.pend = nil
  savePos()
  return ok, err
end

local function inspectDir(d)
  if d == "up" then return turtle.inspectUp() end
  if d == "down" then return turtle.inspectDown() end
  turnTo(d)
  return turtle.inspect()
end

local function fuelLeft()
  local f = turtle.getFuelLevel()
  return f == "unlimited" and math.huge or f
end

local onStep -- called after every step (the scan looks around)
local function goTo(target)
  for _ = 1, 20 do
    if here() == target then return true end
    local path = findPath(here(), target)
    if not path then error("No way to " .. target .. " (blocked?)", 0) end
    if fuelLeft() < #path then error("Out of fuel: put coal in the input chest", 0) end
    local okAll = true
    for i = 2, #path do
      local d = dirBetween(path[i - 1], path[i])
      local ok = false
      local function blocked(name)
        -- remember it for good and go around it
        map.cells[path[i]] = name
        map.obstacles = map.obstacles or {}
        map.obstacles[path[i]] = name
        log("Something in the way at " .. path[i] .. ": going around")
        saveMap()
      end
      for try = 1, 5 do
        ok = rawMove(d)
        if ok then break end
        if fuelLeft() == 0 then error("Out of fuel", 0) end
        local isBlock, data = inspectDir(d)
        if isBlock then blocked(data.name or "s") break end -- a block appeared there (a cable?)
        if try == 5 then blocked("blocked") break end   -- 5 times in a row: blocked too
        sleep(1) -- probably you standing in the way
      end
      if not ok then okAll = false break end
      if onStep then onStep() end
    end
    if okAll then return true end
  end
  error("Can't get to " .. target, 0)
end

-- Face an inventory from its access cell; returns the peripheral side
local function face(dir)
  if dir == "up" then return "top" end
  if dir == "down" then return "bottom" end
  turnTo(dir)
  return "front"
end
local DROP = { top = turtle.dropUp, bottom = turtle.dropDown, front = turtle.drop }
local SUCK = { top = turtle.suckUp, bottom = turtle.suckDown, front = turtle.suck }
local PLACE = { top = turtle.placeUp, bottom = turtle.placeDown, front = turtle.place }

local function goToInv(e)
  goTo(e.acc)
  return face(e.dir)
end

---------------------------------------------------------------------------
-- Turtle inventory
---------------------------------------------------------------------------
local function detail(s)
  local d = turtle.getItemDetail(s)
  if d and not maxStack[d.name] then
    local dd = turtle.getItemDetail(s, true)
    if dd and dd.maxCount then maxStack[d.name] = dd.maxCount end
  end
  return d
end
local function emptySlot()
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then return s end end
end
local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end
local function carried(pred)
  local out = {}
  for s = 1, 16 do
    local d = detail(s)
    if d and (not pred or pred(d.name)) then out[#out + 1] = { slot = s, name = d.name, count = d.count } end
  end
  return out
end
local function carriedCount(pred)
  local n = 0
  for _, c in ipairs(carried(pred)) do n = n + c.count end
  return n
end

---------------------------------------------------------------------------
-- Scan: map the room
---------------------------------------------------------------------------
local function isInv(side)
  if peripheral.hasType then return peripheral.hasType(side, "inventory") == true end
  for _, m in ipairs(peripheral.getMethods(side) or {}) do if m == "pushItems" then return true end end
  return false
end

local function isInventoryBlock(side, data)
  if data.name:find("furnace") or data.name:find("smoker") then return false end
  return isInv(side)
end

local airCount = 0
local function look(d)
  local k = step(here(), d)
  if map.cells[k] ~= nil then return end
  local ok, data = inspectDir(d)
  if ok then
    map.cells[k] = data.name
    local side = (d == "up" and "top") or (d == "down" and "bottom") or "front"
    if isInventoryBlock(side, data) then map.found[k] = data.name end
  else
    local x, y, z = unkey(k)
    if math.abs(x) > cfg.maxSize or math.abs(z) > cfg.maxSize or math.abs(y) > cfg.maxHeight or airCount >= cfg.maxCells then
      error("The room seems open (or is bigger than " .. cfg.maxSize .. " blocks). Close it off and scan again.", 0)
    end
    map.cells[k] = "a"
    airCount = airCount + 1
    if airCount % 25 == 0 then print("  " .. airCount .. " blocks of floor mapped") end
  end
end

local function hasUnknown(k)
  local _, y = unkey(k)
  if y ~= 0 then return false end
  for d = 0, 3 do if map.cells[step(k, d)] == nil then return true end end
  return false
end

-- Only the floor layer is mapped: the turtle drives over the floor and looks at the
-- walls around it. The walls are taken to go straight up to the ceiling.
local function explore()
  onStep = function() look(pos.h) end
  while true do
    local target = bfs(here(), hasUnknown)
    if not target then break end
    goTo(target)
    for _, o in ipairs({ 0, 1, 3, 2 }) do look((pos.h + o) % 4) end
  end
  onStep = nil
end

-- Fly up from the start spot until the ceiling: that's the height of the room
local function measureHeight()
  local n = 0
  while not turtle.inspectUp() do
    if n >= cfg.maxHeight then
      goTo(key(0, 0, 0))
      error("No ceiling found above the start spot. Close the room off or give the height: roomsorter scan <height>", 0)
    end
    map.cells[key(0, n + 1, 0)] = "a"
    goTo(key(0, n + 1, 0))
    n = n + 1
  end
  goTo(key(0, 0, 0))
  return n + 1
end

-- Copy the floor map up to the given height ("w" = wall we haven't looked at)
local function extrude(height)
  local cells = map.cells
  local floor = {}
  for k, v in pairs(cells) do
    local _, y = unkey(k)
    if y == 0 then floor[#floor + 1] = { k = k, v = v } end
  end
  for _, f in ipairs(floor) do
    local x, _, z = unkey(f.k)
    if f.v == "a" then
      for y = 1, height - 1 do cells[key(x, y, z)] = "a" end
      cells[key(x, height, z)] = cells[key(x, height, z)] or "w"
      cells[key(x, -1, z)] = cells[key(x, -1, z)] or "w"
    else
      for y = 1, height - 1 do cells[key(x, y, z)] = cells[key(x, y, z)] or "w" end
    end
  end
end

-- Look at the walls above the floor too (only needed when the output chest isn't at
-- floor height)
local function scanWalls()
  local function unchecked(k)
    local _, y = unkey(k)
    if y < 1 then return false end
    for d = 0, 3 do if map.cells[step(k, d)] == "w" then return true end end
    return false
  end
  while true do
    local target = bfs(here(), unchecked)
    if not target then break end
    goTo(target)
    for _, o in ipairs({ 0, 1, 3, 2 }) do
      local d = (pos.h + o) % 4
      local n = step(here(), d)
      if map.cells[n] == "w" then
        local ok, data = inspectDir(d)
        if not ok then error("Opening in the wall at " .. n .. ": close it and scan again", 0) end
        map.cells[n] = data.name
        if isInventoryBlock("front", data) then map.found[n] = data.name end
      end
    end
  end
end

-- Decide where chests may go. The layer 1 block above the floor (and every 3rd layer
-- above that) stays free as the turtle's road; chests go in the layers below and above it.
local function plan()
  local cells = map.cells
  local floorY = math.huge
  for k, v in pairs(cells) do
    if v == "a" then local _, y = unkey(k) if y < floorY then floorY = y end end
  end
  map.floorY = floorY
  local function layer(y) return (y - floorY) % 3 end

  -- Input = in front of the start, output = the other chest
  local home = key(0, 0, 0)
  local inputK = step(home, 0)
  if not map.found[inputK] then error("No chest in front of the turtle: face the input chest and scan again", 0) end
  local others = {}
  for k in pairs(map.found) do if k ~= inputK then others[#others + 1] = k end end
  table.sort(others)

  -- The spots around the start stay free, so the turtle can always tell which way it faces
  local reserved = { [home] = true }
  for _, d in ipairs({ 1, 3 }) do reserved[step(home, d)] = true end
  local function accessOf(k)
    local best, bestD
    for _, d in ipairs(ALL_DIRS) do
      local n = step(k, d)
      if cells[n] == "a" then
        local _, y = unkey(n)
        local score = layer(y) == 1 and 0 or 1
        if not best or score < bestD then best, bestD = n, score end
      end
    end
    return best
  end
  map.home = home
  idx[inputK] = { kind = "input", acc = home, dir = 0 }

  local outputK
  if #others == 1 then outputK = others[1]
  elseif #others > 1 then
    -- Several chests: the output chest is the one with something in it
    local withItems = {}
    for _, k in ipairs(others) do
      local acc = accessOf(k)
      if acc then
        goTo(acc)
        local side = face(dirBetween(acc, k))
        local ok, l = pcall(peripheral.call, side, "list")
        if ok and l and next(l) then withItems[#withItems + 1] = k end
      end
    end
    if #withItems ~= 1 then
      goTo(home) turnTo(0)
      error("Found " .. #others .. " other chests. Put 1 item in the OUTPUT chest only (it stays there) and scan again.", 0)
    end
    outputK = withItems[1]
  end
  if outputK then
    local acc = accessOf(outputK)
    idx[outputK] = { kind = "output", acc = acc, dir = dirBetween(acc, outputK) }
    reserved[acc] = true
  end
  -- No storage right next to chests in the walls (two chests side by side become one)
  for k in pairs(map.found) do
    for _, d in ipairs({ 0, 1, 2, 3 }) do reserved[step(k, d)] = true end
  end

  local dist = bfs(home)
  local cands = {}
  for k, v in pairs(cells) do
    if v == "a" and not reserved[k] then
      local _, y = unkey(k)
      local L = layer(y)
      local road = (L == 0 and step(k, "up")) or (L == 2 and step(k, "down")) or nil
      if road and cells[road] == "a" and dist[road] then
        cands[#cands + 1] = { cell = k, acc = road, dir = L == 0 and "down" or "up", d = dist[road] }
      end
    end
  end
  table.sort(cands, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.cell < b.cell end)

  -- Every free cell that has to stay reachable: the roads and the chest access spots
  local must = {}
  for k, v in pairs(cells) do
    if v == "a" then local _, y = unkey(k) if layer(y) == 1 then must[#must + 1] = k end end
  end
  for _, e in pairs(idx) do must[#must + 1] = e.acc end
  local function connected(blocked)
    local d = bfs(home, nil, blocked)
    for _, k in ipairs(must) do if not d[k] and not blocked[k] then return false end end
    return true
  end
  local blocked = {}
  for _, c in ipairs(cands) do blocked[c.cell] = true end
  local slots = {}
  if connected(blocked) then
    slots = cands
  else
    -- Odd room: add the spots one by one and keep only those that don't cut off a road
    blocked = {}
    for i, c in ipairs(cands) do
      blocked[c.cell] = true
      if connected(blocked) then slots[#slots + 1] = c else blocked[c.cell] = nil end
      if i % 20 == 0 then os.queueEvent("yield") os.pullEvent("yield") end
    end
  end
  -- Layout, in rows parallel to the input wall:
  --   row 0 (along the input wall): stays free on the floor, the way in
  --   row 1: the furnace row, centred on the start spot. Furnace on the floor, its helper
  --          chest straight above the road.
  --   row 2 and further: storage, row by row, left to right, floor and upper layer
  -- Spots outside that pattern are only used when everything else is full.
  local bySpot = {}
  for _, c in ipairs(slots) do c.d = nil bySpot[c.cell] = c end
  local row = {}
  for _, c in ipairs(slots) do
    local x, y, z = unkey(c.cell)
    if c.dir == "down" and z == 1 and y == floorY then
      local top = bySpot[step(c.acc, "up")]
      if top then row[#row + 1] = { floor = c, top = top, x = x } end
    end
  end
  table.sort(row, function(a, b)
    if math.abs(a.x) ~= math.abs(b.x) then return math.abs(a.x) < math.abs(b.x) end
    return a.x > b.x
  end)
  local stations, used = {}, {}
  for i = 1, math.min(#row, cfg.maxFurnaces) do
    stations[i] = { floor = row[i].floor, top = row[i].top }
    used[row[i].floor.cell], used[row[i].top.cell] = true, true
  end
  -- The spot behind the start stays free unless it holds a furnace (so the turtle can
  -- always tell which way it faces)
  used[step(home, 2)] = true
  local main, extra = {}, {}
  for _, c in ipairs(slots) do
    if not used[c.cell] then
      local _, _, z = unkey(c.cell)
      if z >= 2 then main[#main + 1] = c else extra[#extra + 1] = c end
    end
  end
  local function order(a, b)
    local ax, ay, az = unkey(a.cell)
    local bx, by, bz = unkey(b.cell)
    local _, ar = unkey(a.acc)
    local _, br = unkey(b.acc)
    if ar ~= br then return ar < br end -- lowest road first
    if az ~= bz then return az < bz end -- then row by row
    if ax ~= bx then return ax < bx end -- left to right
    return ay < by                      -- floor before the upper layer
  end
  table.sort(main, order)
  table.sort(extra, order)
  for _, c in ipairs(extra) do main[#main + 1] = c end
  map.slots = main
  map.stations = stations
  map.layout = 2
  return #main + #stations * 2, outputK
end

local function scanRoom(height)
  if fuelLeft() < 200 then
    for s = 1, 16 do turtle.select(s) turtle.refuel() end
    turtle.select(1)
    if fuelLeft() < 200 then print("Needs fuel: put some coal in the turtle first.") return end
  end
  if not isInv("front") then
    print("Face the turtle towards the INPUT chest and stand it on the floor, then scan again.")
    return
  end
  print("Mapping the floor of the room (a 16x16 room takes ~5 minutes).")
  map = { cells = { [key(0, 0, 0)] = "a" }, found = {} }
  idx = {}
  pos = { x = 0, y = 0, z = 0, h = 0 }
  savePos()
  local ok, err = pcall(function()
    look(0)
    if not height then
      height = measureHeight()
      print("Room is " .. height .. " blocks high.")
    end
    explore()
    goTo(key(0, 0, 0))
    extrude(height)
    local others = 0
    for k in pairs(map.found) do if k ~= key(0, 0, -1) then others = others + 1 end end
    if others == 0 and height > 1 then
      print("No output chest at floor height, looking at the walls higher up...")
      scanWalls()
    end
    goTo(key(0, 0, 0))
    turnTo(0)
  end)
  if not ok then
    print("Scan stopped: " .. tostring(err))
    pcall(function() goTo(key(0, 0, 0)) turnTo(0) end)
    return
  end
  print(airCount .. " blocks of floor, " .. height .. " high. Planning...")
  local ok2, n, out = pcall(plan)
  goTo(map.home)
  turnTo(0)
  if not ok2 then print(tostring(n)) return end
  saveMap()
  saveIdx()
  print(("Room for %d chests/furnaces."):format(n))
  if not out then print("No output chest found: 'get' won't work.") end
  print("Next: put chests (or barrels), furnaces and coal in the input chest, then run: roomsorter")
end

if args[1] == "scan" then
  local placed = 0
  for _, e in pairs(idx) do if e.kind ~= "input" and e.kind ~= "output" then placed = placed + 1 end end
  local force, height = false, nil
  for i = 2, #args do
    if args[i] == "force" then force = true end
    if tonumber(args[i]) then height = math.floor(tonumber(args[i])) end
  end
  if height and height < 1 then print("Height must be at least 1.") return end
  if placed > 0 and not force then
    print("This room already has " .. placed .. " chests/furnaces built by the turtle.")
    print("A new scan forgets what is where. Sure? Use: roomsorter scan force")
    return
  end
  scanRoom(height)
  return
end

if not map or not map.slots then
  print("No map yet. Stand the turtle on the floor facing the input chest and run: roomsorter scan")
  return
end

---------------------------------------------------------------------------
-- Startup check: where am I and which way do I face?
---------------------------------------------------------------------------
-- Compares what is around the turtle with the map (after a reboot the last move or
-- turn may or may not have happened).
local function verifyPose()
  local cands = { here() }
  if pos.pend and pos.pend.mv then
    if turtle.getFuelLevel() ~= "unlimited" then
      if turtle.getFuelLevel() < pos.pend.fuel then cands = { step(here(), pos.pend.mv) } end
    else
      cands[#cands + 1] = step(here(), pos.pend.mv)
    end
  end
  local function seen(ok, data) return ok and (data.name or "?") or "a" end
  local obs = {}
  for i = 0, 3 do
    obs[i] = seen(turtle.inspect())
    turtle.turnRight()
  end
  local up, down = seen(turtle.inspectUp()), seen(turtle.inspectDown())
  -- Does what we see fit what the map says is at cell k?
  local function fits(k, o)
    local v = map.cells[k]
    if v == nil then return true end
    if v == "a" or o == "a" then return v == o end
    return v == "s" or v == "p" or v == "w" or v == o
  end
  local matches = {}
  for _, c in ipairs(cands) do
    for h = 0, 3 do
      local ok = fits(step(c, "up"), up) and fits(step(c, "down"), down)
      for i = 0, 3 do
        if not fits(step(c, (h + i) % 4), obs[i]) then ok = false end
      end
      if ok then matches[#matches + 1] = { k = c, h = h } end
    end
  end
  local pick
  for _, m in ipairs(matches) do if m.k == cands[1] and m.h == (pos.pend and pos.pend.turn or pos.h) then pick = m end end
  for _, m in ipairs(matches) do if not pick and m.k == cands[1] and m.h == pos.h then pick = m end end
  pick = pick or matches[1]
  if not pick then
    error("Lost: what's around me doesn't match the map. Put me back on my start spot facing the input chest and type: roomsorter home", 0)
  end
  pos.x, pos.y, pos.z = unkey(pick.k)
  pos.h = pick.h
  pos.pend = nil
  savePos()
end

if args[1] == "home" then
  pos = { x = 0, y = 0, z = 0, h = 0 }
  savePos()
  print("Position reset to the start spot. Start with: roomsorter")
  return
end

---------------------------------------------------------------------------
-- Storage index
---------------------------------------------------------------------------
-- Which free cells the turtle can get to from its start spot (redone when the map changes)
local reachCache, reachVersion
local function reachable()
  if reachVersion ~= mapVersion or not reachCache then
    reachCache = bfs(map.home)
    reachVersion = mapVersion
  end
  return reachCache
end
local function canReach(e) return reachable()[e.acc] ~= nil end

-- Storage chests it can get to (ones cut off by something in the way are left out)
local function storageList()
  local l = {}
  for k, e in pairs(idx) do if e.kind == "store" and not e.merged and canReach(e) then l[#l + 1] = k end end
  table.sort(l)
  return l
end

local function unreachableCount()
  local n = 0
  for _, e in pairs(idx) do
    if (e.kind == "store" or e.kind == "furnace") and not e.merged and not canReach(e) then n = n + 1 end
  end
  return n
end

-- Filling 'cell' must not cut the turtle off from a road or a chest it can reach now
local safeCache = {}
local function safeToFill(cell)
  local c = safeCache[cell]
  if c and c.v == mapVersion then return c.ok end
  local before = reachable()
  local after = bfs(map.home, nil, { [cell] = true })
  local ok = true
  local floorY = map.floorY or 0
  for k in pairs(before) do
    if not after[k] and k ~= cell then
      local _, y = unkey(k)
      if (y - floorY) % 3 == 1 then ok = false break end -- a road cell would be cut off
    end
  end
  if ok then
    for _, e in pairs(idx) do
      if e.acc and before[e.acc] and not after[e.acc] then ok = false break end
    end
  end
  safeCache[cell] = { v = mapVersion, ok = ok }
  return ok
end

local function refresh(k, side)
  local e = idx[k]
  local ok, l = pcall(peripheral.call, side, "list")
  if ok and l then
    e.items = l
    local ok2, s = pcall(peripheral.call, side, "size")
    if ok2 and s then e.size = s end
  end
  saveIdx()
  return e.items
end

local function roomFor(e, name)
  local n, used = 0, 0
  for _, it in pairs(e.items or {}) do
    used = used + 1
    if it.name == name then n = n + math.max(0, stackOf(name) - it.count) end
  end
  return n + math.max(0, (e.size or 27) - used) * stackOf(name)
end
local function holds(e, name)
  for _, it in pairs(e.items or {}) do if it.name == name then return true end end
  return false
end
local function isEmpty(e) return next(e.items or {}) == nil end

-- Every chest/barrel the turtle built: storage + the helper chests above the furnaces
local function chestCount()
  local n = 0
  for _, e in pairs(idx) do if e.kind == "store" or e.kind == "buffer" then n = n + 1 end end
  return n
end

local function totals()
  local t = {}
  for _, k in ipairs(storageList()) do
    for _, it in pairs(idx[k].items or {}) do t[it.name] = (t[it.name] or 0) + it.count end
  end
  return t
end

local function usedSlots()
  local used, size = 0, 0
  for _, k in ipairs(storageList()) do
    local e = idx[k]
    size = size + (e.size or 27)
    for _ in pairs(e.items or {}) do used = used + 1 end
  end
  return used, size
end

-- Spots from the plan that are still free
local function freeSlot(filter)
  for _, s in ipairs(map.slots) do
    if not idx[s.cell] and not (map.bad and map.bad[s.cell]) and free(s.cell) and reachable()[s.acc]
      and (not filter or filter(s)) and safeToFill(s.cell) then return s end
  end
end
-- Spots it can still build on (free and reachable)
local function usableSpots()
  local n = 0
  for _, sl in ipairs(map.slots) do
    if not idx[sl.cell] and not (map.bad and map.bad[sl.cell]) and free(sl.cell) and reachable()[sl.acc] then n = n + 1 end
  end
  return n
end

local function slotAt(cell)
  for _, s in ipairs(map.slots) do if s.cell == cell then return s end end
end

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------
local function markBad(cell)
  map.bad = map.bad or {}
  map.bad[cell] = true
  saveMap()
end

-- Place a block from turtle slot 'tslot' at plan spot s. Chests next to each other turn
-- into double chests when they face the same way, so they alternate north/south.
local function placeAt(s, tslot, kind)
  local side = goToInv(s)
  local d = detail(tslot)
  if d and d.name == "minecraft:chest" then
    -- Chests in a row all face the same way (along the row), the next row the other
    -- way: then no two of them join into a double chest
    local _, _, z = unkey(s.cell)
    turnTo(z % 2 == 0 and 3 or 1)
  end
  turtle.select(tslot)
  local ok = PLACE[side]()
  turtle.select(1)
  if not ok then
    local isBlock, data = inspectDir(s.dir == "up" and "up" or s.dir == "down" and "down" or s.dir)
    if isBlock then -- something is already there (a cable?): skip that spot for good
      map.cells[s.cell] = data.name or "s"
      map.obstacles = map.obstacles or {}
      map.obstacles[s.cell] = data.name or "?"
      log("Something in the way at " .. s.cell .. ": skipping that spot")
      saveMap()
    else
      log("Can't place at " .. s.cell, true)
      markBad(s.cell)
    end
    return nil
  end
  map.cells[s.cell] = d and d.name or "p"
  saveMap()
  local e = { kind = kind, acc = s.acc, dir = s.dir, size = 27, items = {} }
  idx[s.cell] = e
  if kind == "store" or kind == "buffer" then
    refresh(s.cell, side)
    if e.size and e.size > 27 and d and d.name == "minecraft:chest" then
      e.merged = true -- joined a neighbour into a double chest after all: leave this half alone
      log("Chest at " .. s.cell .. " became a double chest", true)
    end
  end
  saveIdx()
  return e
end

local fetch -- defined below

-- A chest/furnace from the turtle's own inventory, or else fetched from storage
local function supplySlot(set)
  for _, c in ipairs(carried(function(n) return set[n] ~= nil end)) do return c.slot, c.name end
  for name in pairs(set) do
    for _, k in pairs(idx) do
      if k.kind == "store" and not k.merged and holds(k, name) and freeSlots() > 0 then
        if fetch(name, set == CHEST_ITEMS and 16 or 1, 1) > 0 then
          for _, c in ipairs(carried(function(n) return n == name end)) do return c.slot, c.name end
        end
      end
    end
  end
end

local function placeStorage()
  local tslot = supplySlot(CHEST_ITEMS)
  if not tslot then return false end
  local s = freeSlot()
  if not s then return false end
  setState("Building a chest")
  return placeAt(s, tslot, "store") ~= nil
end

local function furnaces()
  local l = {}
  for k, e in pairs(idx) do if e.kind == "furnace" and canReach(e) then l[#l + 1] = k end end
  table.sort(l)
  return l
end

-- A furnace goes under the road with a helper chest above the road: the turtle drops
-- ores in from above and moves fuel and results through the helper chest.
local function freeStation()
  for _, st in ipairs(map.stations or {}) do
    if not idx[st.floor.cell] and not (map.bad and (map.bad[st.floor.cell] or map.bad[st.top.cell]))
      and free(st.floor.cell) and (idx[st.top.cell] or free(st.top.cell)) and reachable()[st.floor.acc]
      and safeToFill(st.floor.cell) and (idx[st.top.cell] or safeToFill(st.top.cell)) then return st end
  end
end

local function buildFurnaces()
  while #furnaces() < cfg.maxFurnaces do
    local st = freeStation()
    if not st then return end
    local fslot, fname = supplySlot(FURNACE_ITEMS)
    if not fslot then return end
    if not idx[st.top.cell] then
      local cslot = supplySlot(CHEST_ITEMS)
      if not cslot then
        status.note = "A furnace is waiting for a chest"
        return
      end
      setState("Building a furnace")
      if not placeAt(st.top, cslot, "buffer") then return end
    end
    setState("Building a furnace")
    local f = placeAt(st.floor, fslot, "furnace")
    if not f then return end
    f.blast = FURNACE_ITEMS[fname] == "blast"
    f.buffer = st.top.cell
    status.note = nil
    saveIdx()
    log("Built a " .. (f.blast and "blast furnace" or "furnace"))
  end
end

-- Every chest/barrel it has (or has in storage) gets built right away
local function buildChests()
  while freeSlot() do
    if not placeStorage() then return end
  end
  -- Chests left but nowhere to put them: say so
  local t = totals()
  local spare = carriedCount(function(n) return CHEST_ITEMS[n] ~= nil end)
  for name in pairs(CHEST_ITEMS) do spare = spare + (t[name] or 0) end
  status.roomNote = (spare > 0 and not freeSlot()) and ("Room is full: " .. spare .. " chests can't be placed") or nil
end

---------------------------------------------------------------------------
-- Taking items out of a chest
---------------------------------------------------------------------------
-- turtle.suck() always takes the first stack in a chest, so the wanted stack is moved
-- to slot 1 first.
local function takeFrom(k, side, slot, n)
  local e = idx[k]
  local l = peripheral.call(side, "list")
  if not l[slot] then return 0 end
  local t = emptySlot()
  if not t then return 0 end
  local parked
  if slot ~= 1 then
    if l[1] then
      local size = peripheral.call(side, "size")
      local spare
      for s = size, 2, -1 do if not l[s] then spare = s break end end
      if spare then
        peripheral.call(side, "pushItems", side, 1, 64, spare)
      else -- chest full: hold slot 1 in the turtle for a moment
        parked = t
        turtle.select(parked)
        SUCK[side]()
        t = emptySlot()
        if not t then DROP[side]() turtle.select(1) return 0 end
      end
    end
    peripheral.call(side, "pushItems", side, slot, n, 1)
  end
  turtle.select(t)
  local before = turtle.getItemCount(t)
  SUCK[side](n)
  local got = turtle.getItemCount(t) - before
  if parked then turtle.select(parked) DROP[side]() end
  turtle.select(1)
  refresh(k, side)
  return got
end

-- Take up to n of an item from storage. Returns how many it got.
function fetch(name, n, maxSlotsUsed)
  local got = 0
  local dist = bfs(here())
  local list = {}
  for _, k in ipairs(storageList()) do if holds(idx[k], name) then list[#list + 1] = k end end
  table.sort(list, function(a, b) return (dist[idx[a].acc] or 1e9) < (dist[idx[b].acc] or 1e9) end)
  local startFree = freeSlots()
  for _, k in ipairs(list) do
    if got >= n then break end
    local side = goToInv(idx[k])
    for slot, it in pairs(refresh(k, side)) do
      if got < n and it.name == name then
        if freeSlots() == 0 or (maxSlotsUsed and startFree - freeSlots() >= maxSlotsUsed) then return got end
        got = got + takeFrom(k, side, slot, math.min(n - got, it.count))
      end
    end
  end
  return got
end

---------------------------------------------------------------------------
-- Storing
---------------------------------------------------------------------------
-- What the turtle keeps on board: 1 stack of chests/barrels and furnaces it can still use
local function keepOnBoard(c, kept)
  if CHEST_ITEMS[c.name] then
    -- normally all built already; keep one stack for a furnace that waits for one
    if kept.chest or not (freeSlot() or freeStation()) then return false end
    kept.chest = true
    return true
  end
  if FURNACE_ITEMS[c.name] and #furnaces() < cfg.maxFurnaces and freeStation() then return true end
  return false
end

local function storeAll()
  for _ = 1, 10 do
    local kept = {}
    local todo = {}
    for _, c in ipairs(carried()) do
      if not keepOnBoard(c, kept) then todo[#todo + 1] = c end
    end
    if #todo == 0 then status.full = false return true end
    setState("Storing")
    -- Per item: a chest that already has it, else an empty chest, else a new chest,
    -- else any chest with room
    local dist = bfs(here())
    local function byDist(a, b) return (dist[idx[a].acc] or 1e9) < (dist[idx[b].acc] or 1e9) end
    local chests = storageList()
    table.sort(chests, byDist)
    local plan, claimed = {}, {}
    local noRoom = false
    local byName = {}
    for _, c in ipairs(todo) do
      byName[c.name] = byName[c.name] or {}
      table.insert(byName[c.name], c)
    end
    local names = {}
    for n in pairs(byName) do names[#names + 1] = n end
    table.sort(names)
    for _, name in ipairs(names) do
      local target
      for _, k in ipairs(chests) do if not target and holds(idx[k], name) and roomFor(idx[k], name) > 0 then target = k end end
      for _, k in ipairs(chests) do if not target and isEmpty(idx[k]) and not claimed[k] then target = k end end
      if not target and placeStorage() then
        chests = storageList()
        for _, k in ipairs(chests) do if not target and isEmpty(idx[k]) and not claimed[k] then target = k end end
      end
      for _, k in ipairs(chests) do if not target and roomFor(idx[k], name) > 0 then target = k end end
      if target then
        claimed[target] = true
        plan[target] = plan[target] or {}
        for _, c in ipairs(byName[name]) do table.insert(plan[target], c.slot) end
      else
        noRoom = true
      end
    end
    -- Visit the chests, nearest first
    local order = {}
    for k in pairs(plan) do order[#order + 1] = k end
    dist = bfs(here())
    table.sort(order, byDist)
    local moved = 0
    for _, k in ipairs(order) do
      local side = goToInv(idx[k])
      for _, s in ipairs(plan[k]) do
        local before = turtle.getItemCount(s)
        if before > 0 then
          turtle.select(s)
          DROP[side]()
          local m = before - turtle.getItemCount(s)
          moved = moved + m
          stats.stored = stats.stored + m
        end
      end
      turtle.select(1)
      refresh(k, side)
    end
    if noRoom and moved == 0 then
      status.full = true
      log("Storage full: put chests or barrels in the input chest", true)
      return false
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Input, output, fuel
---------------------------------------------------------------------------
local function inputEntry() for _, e in pairs(idx) do if e.kind == "input" then return e end end end
local function outputEntry() for _, e in pairs(idx) do if e.kind == "output" then return e end end end

local function goHome()
  goTo(map.home)
  turnTo(0)
end

-- Empty the input chest into the turtle (keeps 1 slot free)
local function pullInput()
  local side = goToInv(inputEntry())
  local ok, l = pcall(peripheral.call, side, "list")
  if not ok or not l or not next(l) then return 0 end
  setState("Taking from the input chest")
  local n = 0
  while freeSlots() > 1 do
    turtle.select(emptySlot())
    if not SUCK[side]() then break end
    n = n + 1
  end
  turtle.select(1)
  return n
end

local function refuelSelf()
  if fuelLeft() >= cfg.minFuel then return end
  for _, c in ipairs(carried(function(n) return FUEL_VALUE[n] ~= nil end)) do
    turtle.select(c.slot)
    while fuelLeft() < cfg.minFuel * 4 and turtle.getItemCount(c.slot) > 0 do
      if not turtle.refuel(1) then break end
    end
  end
  turtle.select(1)
  if fuelLeft() < cfg.minFuel then
    for _, f in ipairs(cfg.fuels) do
      if fuelLeft() < cfg.minFuel and totals()[f] then
        fetch(f, 16, 1)
        for _, c in ipairs(carried(function(n) return n == f end)) do
          turtle.select(c.slot)
          turtle.refuel()
        end
        turtle.select(1)
      end
    end
  end
  if fuelLeft() < 100 then log("Turtle low on fuel: put coal in the input chest", true) end
end

---------------------------------------------------------------------------
-- Smelting
---------------------------------------------------------------------------
local lastPass = -1e9

local function furnaceRoom(e, name)
  local st = e.state or {}
  local inp = st[1]
  if inp and inp.name ~= name then return 0 end
  return math.max(0, cfg.queue - (inp and inp.count or 0))
end

local function smeltableHere(e, name)
  local k = smeltKind(name)
  return k == "ore" or (k == "extra" and not e.blast)
end

-- Suck everything out of a furnace's helper chest into the turtle
local function emptyBuffer(e)
  local b = idx[e.buffer]
  for _ = 1, 27 do
    if freeSlots() == 0 then break end
    turtle.select(emptySlot())
    if not turtle.suckUp() then break end
  end
  turtle.select(1)
  refresh(e.buffer, "top")
  return b
end

local function serviceFurnace(k, share)
  local e = idx[k]
  goTo(e.acc)
  local ok, st = pcall(peripheral.call, "bottom", "list")
  if not ok or not st then log("Furnace at " .. k .. " is missing", true) return end
  -- 1. Results (and empty buckets) out, through the helper chest
  if st[3] then
    local m = peripheral.call("bottom", "pushItems", "top", 3)
    if m and m > 0 then
      stats.smelted[st[3].name] = (stats.smelted[st[3].name] or 0) + m
      status.lastSmelt = m .. " " .. pretty(st[3].name)
    end
  end
  if st[2] and st[2].name == "minecraft:bucket" then peripheral.call("bottom", "pushItems", "top", 2) end
  emptyBuffer(e)
  st = peripheral.call("bottom", "list")
  e.state = st
  -- 2. Ores in from above
  local list = carried(function(n) return smeltableHere(e, n) end)
  table.sort(list, byPriority)
  for _, c in ipairs(list) do
    local room = furnaceRoom(e, c.name)
    local n = math.min(room, c.count, share)
    if n > 0 then
      turtle.select(c.slot)
      if turtle.dropDown(n) then
        st = peripheral.call("bottom", "list")
        e.state = st
      end
    end
  end
  turtle.select(1)
  -- 3. Fuel for what's waiting, through the helper chest into the fuel slot
  local need = st[1] and st[1].count or 0
  local div = e.blast and 2 or 1
  local have = 0
  if st[2] then have = FUEL_VALUE[st[2].name] and FUEL_VALUE[st[2].name] / div * st[2].count or math.huge end
  if need > have then
    for _, f in ipairs(st[2] and { st[2].name } or cfg.fuels) do
      if need > have then
        local per = (FUEL_VALUE[f] or 8) / div
        for _, c in ipairs(carried(function(n) return n == f end)) do
          local want = math.min(c.count, math.ceil((need - have) / per))
          if want > 0 then
            turtle.select(c.slot)
            turtle.dropUp(want)
            for slot, it in pairs(peripheral.call("top", "list")) do
              if it.name == f then
                local m = peripheral.call("top", "pushItems", "bottom", slot, want, 2) or 0
                have = have + m * per
                want = want - m
              end
            end
          end
        end
      end
    end
    turtle.select(1)
    emptyBuffer(e)
    e.state = peripheral.call("bottom", "list")
  end
  saveIdx()
end

local function smeltablesInStorage()
  local n = 0
  for name, c in pairs(totals()) do if smeltKind(name) then n = n + c end end
  return n
end

local function furnacePass()
  local fl = furnaces()
  if #fl == 0 then return end
  local busy = false
  local room = 0
  for _, k in ipairs(fl) do
    local st = idx[k].state or {}
    if st[1] or st[3] then busy = true end
    room = room + (st[1] and math.max(0, cfg.queue - st[1].count) or cfg.queue)
  end
  local carriedSmelt = carriedCount(function(n) return smeltKind(n) ~= nil end)
  local stored = smeltablesInStorage()
  if carriedSmelt == 0 and (stored == 0 or room < 8) and not (busy and os.clock() - lastPass > 30) then return end
  lastPass = os.clock()
  setState("Smelting")
  -- Take ores from storage for the room there is (keeps 4 slots free for results)
  if carriedSmelt < room and stored > 0 then
    local wanted = {}
    for name, c in pairs(totals()) do if smeltKind(name) then wanted[#wanted + 1] = { name = name, count = c } end end
    table.sort(wanted, byPriority) -- gold and iron before copper
    for _, w in ipairs(wanted) do
      if carriedSmelt < room and freeSlots() > 4 then
        local got = fetch(w.name, math.min(w.count, room - carriedSmelt), freeSlots() - 4)
        carriedSmelt = carriedSmelt + got
      end
    end
  end
  -- Take fuel along
  local fuelCarried = carriedCount(function(n) return FUEL_VALUE[n] ~= nil and n ~= "minecraft:lava_bucket" end)
  local fuelWanted = math.ceil(carriedSmelt / 8) + #fl
  if fuelCarried < fuelWanted then
    local t = totals()
    for _, f in ipairs(cfg.fuels) do
      if fuelCarried < fuelWanted and t[f] and freeSlots() > 3 then
        fuelCarried = fuelCarried + fetch(f, fuelWanted - fuelCarried, 1)
      end
    end
  end
  if fuelCarried == 0 and carriedSmelt > 0 then status.noFuel = true else status.noFuel = false end
  local share = math.max(8, math.ceil(carriedSmelt / #fl))
  -- Blast furnaces first (twice as fast), then nearest
  table.sort(fl, function(a, b)
    if idx[a].blast ~= idx[b].blast then return idx[a].blast == true end
    return a < b
  end)
  for _, k in ipairs(fl) do serviceFurnace(k, share) end
end

---------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------
local requests = {}

local function matchItem(text)
  local q = text:lower():gsub("%s+", "_")
  local found, exact = {}, nil
  for name, n in pairs(totals()) do
    if short(name) == q or name == q then exact = name end
    if name:find(q, 1, true) then found[#found + 1] = name end
  end
  table.sort(found)
  return exact or (#found == 1 and found[1]) or nil, found
end

local function deliver(req)
  local out = outputEntry()
  if not out then log("No output chest", true) return end
  local left = req.n
  setState("Getting " .. pretty(req.name))
  while left > 0 do
    local got = fetch(req.name, left)
    if got == 0 then break end
    local side = goToInv(out)
    for _, c in ipairs(carried(function(n) return n == req.name end)) do
      turtle.select(c.slot)
      local before = turtle.getItemCount(c.slot)
      DROP[side]()
      local m = before - turtle.getItemCount(c.slot)
      left = left - m
      stats.delivered = stats.delivered + m
    end
    turtle.select(1)
    if carriedCount(function(n) return n == req.name end) > 0 then
      log("Output chest is full", true)
      break
    end
  end
  log("Delivered " .. (req.n - left) .. " " .. pretty(req.name))
end

local function serveRequests()
  while #requests > 0 do
    local r = table.remove(requests, 1)
    deliver(r)
  end
end

-- Shared by the turtle prompt and the client. Returns lines of text.
local function command(cmd, text, n)
  cmd = (cmd or ""):lower()
  if cmd == "list" or cmd == "find" then
    local t = totals()
    local l = {}
    local q = (text or ""):lower():gsub("%s+", "_")
    for name, c in pairs(t) do if q == "" or name:find(q, 1, true) then l[#l + 1] = { name = name, n = c } end end
    table.sort(l, function(a, b) return a.n > b.n end)
    local out = {}
    for _, it in ipairs(l) do out[#out + 1] = (" %s: %d"):format(pretty(it.name), it.n) end
    if #out == 0 then out[1] = " none" end
    return out
  elseif cmd == "get" then
    if not text or text == "" then return { "get <item> [n]" } end
    local name, found = matchItem(text)
    if not name then
      if #found == 0 then return { "None in storage." } end
      local out = { "Which one?" }
      for _, f in ipairs(found) do out[#out + 1] = " " .. short(f) end
      return out
    end
    if not outputEntry() then return { "No output chest." } end
    n = math.min(n or stackOf(name), totals()[name] or 0)
    requests[#requests + 1] = { name = name, n = n }
    os.queueEvent("room_request")
    return { "Getting " .. n .. " " .. pretty(name) .. "..." }
  elseif cmd == "build" then
    -- Build right away with the chests/barrels/furnaces it has (normally automatic)
    local t = totals()
    local chests = carriedCount(function(x) return CHEST_ITEMS[x] ~= nil end)
    local furn = carriedCount(function(x) return FURNACE_ITEMS[x] ~= nil end)
    for name in pairs(CHEST_ITEMS) do chests = chests + (t[name] or 0) end
    for name in pairs(FURNACE_ITEMS) do furn = furn + (t[name] or 0) end
    local spots = usableSpots()
    os.queueEvent("room_request")
    return { ("Built: %d chests/barrels, %d furnaces. Room for %d more."):format(chestCount(), #furnaces(), spots),
      chests + furn > 0 and ("%d chests/barrels and %d furnaces not built yet: building now."):format(chests, furn)
        or "Nothing left to build. New chests/barrels in the drop-off chest get built by themselves." }
  elseif cmd == "status" then
    local used, size = usedSlots()
    return { status.state, ("Storage %d/%d slots, %d furnaces"):format(used, size, #furnaces()) }
  end
  return { "Commands: list [text], find <item>, get <item> [n], build, status" }
end

---------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------
local paused = false
local W, H = term.getSize()
local native = term.current()
local statusWin = window.create(native, 1, 1, W, H - 1)
local promptWin = window.create(native, 1, H, W, 1)
local showingOutput = false

local function draw(t)
  local w, h = t.getSize()
  local color = t.isColor and t.isColor()
  local function c(x) return color and x or colors.white end
  t.setBackgroundColor(colors.black)
  t.clear()
  local y = 1
  local function line(text, col, right, rcol)
    if y > h then return end
    t.setCursorPos(1, y)
    t.setTextColor(c(col or colors.white))
    if right then text = text:sub(1, math.max(0, w - #right - 1)) end
    t.write(text:sub(1, w))
    if right and #right < w then
      t.setCursorPos(w - #right + 1, y)
      t.setTextColor(c(rcol or colors.lightGray))
      t.write(right)
    end
    y = y + 1
  end
  line("STORAGE ROOM", colors.yellow, paused and "PAUSED" or textutils.formatTime(os.time(), true), paused and colors.red or nil)
  line(string.rep("-", w), colors.gray)
  line(status.state, colors.white, "fuel " .. tostring(turtle.getFuelLevel()))
  local used, size = usedSlots()
  local nChests = chestCount()
  local pct = size > 0 and math.floor(used * 100 / size) or 100
  line(("%d chests, %d/%d slots"):format(nChests, used, size), (status.full or pct >= 90) and colors.orange or colors.white,
    status.full and "FULL" or (pct .. "%"), status.full and colors.red or nil)
  local spots = usableSpots()
  line(("%d furnaces, room for %d more blocks"):format(#furnaces(), spots), colors.lightGray)
  if status.full then line("Put chests/barrels in the input chest", colors.red) end
  if status.noFuel then line("Furnaces need coal!", colors.red) end
  if status.note then line(status.note, colors.orange) end
  if status.roomNote then line(status.roomNote, colors.orange) end
  local cut = unreachableCount()
  if cut > 0 then
    local where = next(map.obstacles or {})
    line(cut .. " chests cut off" .. (where and (" (blocked at " .. where .. ")") or ""), colors.orange)
  end
  if status.lastSmelt then line("Smelted " .. status.lastSmelt, colors.lightGray) end
  y = y + 1
  local l = {}
  for name, n in pairs(totals()) do l[#l + 1] = { name = name, n = n } end
  table.sort(l, function(a, b) return a.n > b.n end)
  line("IN STORAGE", colors.yellow)
  if #l == 0 then line(" nothing yet", colors.gray) end
  for i = 1, #l do
    if y > h - 2 then break end
    line(" " .. pretty(l[i].name), colors.white, tostring(l[i].n), colors.white)
  end
  y = math.max(y, h - 1)
  for i = 2, 1, -1 do
    local e = logLines[i]
    if e and y <= h then line(e[1], e[2] and colors.red or colors.gray) else y = y + 1 end
  end
end

local function redraw()
  pcall(draw, statusWin)
  if not showingOutput then promptWin.restoreCursor() end
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
local function round()
  serveRequests()
  pullInput()
  refuelSelf()
  buildFurnaces()
  buildChests()
  furnacePass()
  storeAll()
  serveRequests()
  goHome()
  saveTable(STATS_FILE, stats)
  os.queueEvent("room_stock")
end

local function worker()
  if map.layout ~= 2 then log("Old room plan: pick up what it built and run 'roomsorter scan force' for the tidy layout", true) end
  setState("Checking position")
  local ok, err = pcall(verifyPose)
  if not ok then setState("LOST") log(tostring(err), true) return end
  while true do
    if not paused then
      local ok2, err2 = pcall(round)
      if not ok2 then
        if tostring(err2):find("^No way to") then
          -- a spot it wanted got blocked; the map knows now, carry on without it
          log("Can't reach " .. tostring(err2):match("^No way to (%S+)") .. ", skipping it")
        else
          log("Error: " .. tostring(err2), true)
        end
        pcall(goHome)
      end
    end
    setState(paused and "Paused" or (status.full and "Storage full" or "Waiting for items"))
    -- Sleep, but wake up for a request
    local timer = os.startTimer(cfg.interval)
    while true do
      local ev, a = os.pullEvent()
      if ev == "room_request" or (ev == "timer" and a == timer) then break end
    end
  end
end

local function screenLoop()
  local tick = os.startTimer(1)
  while true do
    redraw()
    local ev, a = os.pullEvent()
    if ev == "timer" and a == tick then tick = os.startTimer(1) end
  end
end

local function prompt()
  local history = {}
  while true do
    term.redirect(promptWin)
    promptWin.clear()
    promptWin.setCursorPos(1, 1)
    promptWin.setTextColor(colors.white)
    write("> ")
    local line = read(nil, history)
    term.redirect(native)
    if line and line:find("%S") then
      history[#history + 1] = line
      local words = {}
      for wd in line:gmatch("%S+") do words[#words + 1] = wd end
      local cmd = words[1]:lower()
      if cmd == "quit" or cmd == "q" or cmd == "exit" then return end
      showingOutput = true
      statusWin.setVisible(false)
      native.setBackgroundColor(colors.black)
      native.clear()
      native.setCursorPos(1, 1)
      if cmd == "pause" then paused = true print("Paused (after the current job).")
      elseif cmd == "resume" then paused = false print("Running.") os.queueEvent("room_request")
      else
        local n = tonumber(words[#words])
        local text = table.concat(words, " ", 2, n and #words > 2 and #words - 1 or #words)
        if n and #words == 2 then n = nil end
        for _, l in ipairs(command(cmd, text, n)) do print(l) end
      end
      print("Press any key")
      os.pullEvent("key")
      showingOutput = false
      statusWin.setVisible(true)
      statusWin.redraw()
    end
  end
end

-- Questions from 'roomsorter client' over a wireless modem
local function remote()
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then while true do os.pullEvent("never") end end
  rednet.open(peripheral.getName(modem))
  rednet.host(PROTOCOL, os.getComputerLabel() or ("storage" .. os.getComputerID()))
  -- The stock board listens to these: what's in storage, every 10 s and after each job
  local lastSent, lastSig = -1e9, nil
  local function sendStock(onlyIfChanged)
    local used, size = usedSlots()
    local msg = { totals = totals(), used = used, size = size, chests = chestCount(),
      furnaces = #furnaces(), state = status.state, full = status.full }
    local sig = textutils.serialize(msg.totals) .. used .. tostring(status.full)
    if onlyIfChanged and sig == lastSig then return end
    rednet.broadcast(msg, PROTOCOL .. "_stock")
    lastSent, lastSig = os.clock(), sig
  end
  local tick = os.startTimer(1)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and c == PROTOCOL and type(b) == "table" then
      rednet.send(a, command(b.cmd, b.text, b.n), PROTOCOL)
    elseif ev == "timer" and a == tick then
      sendStock()
      tick = os.startTimer(10)
    elseif ev == "room_stock" and os.clock() - lastSent > 2 then
      sendStock(true)
    end
  end
end

parallel.waitForAny(worker, screenLoop, prompt, remote)
term.redirect(native)
native.setBackgroundColor(colors.black)
native.clear()
native.setCursorPos(1, 1)
saveTable(STATS_FILE, stats)
print("roomsorter stopped.")
