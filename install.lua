-- install.lua - guided installer for every bot in this repo (CC: Tweaked)
--
-- One command on a fresh computer, turtle or pocket computer:
--   wget run https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/install.lua
-- Then pick what it should become and follow the screens: it downloads the script,
-- tells you what to build around it, checks what it can, asks the few numbers it
-- needs (with GPS it fills in the coordinates) and runs the setup commands for you.
--
--   install              the guided installer (it saves itself, so this works later too)
--   install <bot>        straight to that bot's guided setup
--   install <bot> quick  only download the files, no questions
-- Keys: arrows / Tab to move, Enter to press, Backspace = back. Or tap / click.
-- Every install also gets update.lua, so "update" (or "<bot> update") fetches new versions later.

local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/"
local args = { ... }

---------------------------------------------------------------------------
-- What this computer is, and helpers for the checks
---------------------------------------------------------------------------
local KIND = turtle and "turtle" or (pocket and "pocket" or "computer")
local COLOR = term.isColour and term.isColour()
local function col(c, plain) if COLOR then return c end return plain or colors.white end

local function wireless()
  return peripheral.find("modem", function(_, m) return m.isWireless() end)
end

-- GPS position, only when a wireless modem is there to ask
local function gpsHere()
  if not gps or not wireless() then return nil end
  local x, y, z = gps.locate(2)
  if not x then return nil end
  return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
end

local function isChest(name)
  return name and (name:find("chest") or name:find("barrel") or name:find("shulker")) and true or false
end

-- A chest behind, to the right or to the left of the turtle? (it turns to look, and back)
local function chestNear()
  if not turtle then return false end
  local n = 0
  for _ = 1, 4 do
    turtle.turnRight()
    local ok, info = turtle.inspect()
    if ok and isChest(info.name) then n = n + 1 end
  end
  return n > 0, n
end

local function fuel()
  if not turtle then return 0 end
  local f = turtle.getFuelLevel()
  return f == "unlimited" and math.huge or f
end

-- A command as a clean list of strings (answers that were skipped are left out)
local function words(cmd)
  local out = {}
  for k = 1, 12 do if cmd[k] ~= nil then out[#out + 1] = tostring(cmd[k]) end end
  return out
end

---------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------
local W, H = term.getSize()

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
  return lines
end

local function at(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  if bg then term.setBackgroundColor(bg) end
  if fg then term.setTextColor(fg) end
  term.write(s)
end

local function clear()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

local function header(title, sub)
  clear()
  local fg, bg = col(colors.white, colors.black), col(colors.blue, colors.white)
  at(1, 1, (" "):rep(W), fg, bg)
  at(2, 1, title:sub(1, W - 2), fg, bg)
  if sub then at(W - #sub, 1, sub, col(colors.lightBlue, colors.black), bg) end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
end

-- Buttons along the bottom (right-aligned, onto the line above when they don't fit).
-- Waits for one event: returns a button id, or "up" / "down" / "redraw".
local function buttonBar(buttons, focus)
  local spots, x, y = {}, W, H
  for i = #buttons, 1, -1 do
    local label = " " .. buttons[i][2] .. " "
    if x - #label < 1 then x, y = W, y - 1 end
    x = x - #label
    spots[i] = { x = x + 1, y = y, w = #label }
    local on = i == focus.i
    at(x + 1, y, label, on and colors.black or colors.white, on and col(colors.yellow, colors.white) or col(colors.gray, colors.black))
    x = x - 1
  end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  local ev, a, b, c = os.pullEvent()
  if ev == "key" then
    if a == keys.left then focus.i = math.max(1, focus.i - 1)
    elseif a == keys.right or a == keys.tab then focus.i = focus.i % #buttons + 1
    elseif a == keys.up then return "up"
    elseif a == keys.down then return "down"
    elseif a == keys.enter or a == keys.numPadEnter or a == keys.space then return buttons[focus.i][1]
    elseif a == keys.backspace then
      for _, bt in ipairs(buttons) do if bt[1] == "back" then return "back" end end
    end
  elseif ev == "mouse_scroll" then return a > 0 and "down" or "up"
  elseif ev == "mouse_click" then
    for i, s in ipairs(spots) do
      if c == s.y and b >= s.x and b < s.x + s.w then return buttons[i][1] end
    end
  elseif ev == "term_resize" then W, H = term.getSize()
  end
  return "redraw"
end

-- A screen of text with buttons. text: list of { text, color }. Returns the chosen button id.
-- Long text scrolls with the arrow keys / mouse wheel.
local function screen(title, sub, text, buttons, focusOn)
  local focus = { i = focusOn or #buttons }
  local scroll = 0
  while true do
    local body = {}
    for _, p in ipairs(text) do
      for _, l in ipairs(wrap(p[1], W - 2)) do body[#body + 1] = { l, p[2] or colors.white } end
    end
    local rows = H - 4
    header(title, sub)
    scroll = math.max(0, math.min(scroll, #body - rows))
    for i = 1, rows do
      local l = body[i + scroll]
      if l then at(2, 2 + i, l[1], col(l[2], colors.white)) end
    end
    if scroll > 0 then at(W, 3, "\24", colors.lightGray) end
    if scroll + rows < #body then at(W, 2 + rows, "\25", colors.lightGray) end
    local r = buttonBar(buttons, focus)
    if r == "up" then scroll = scroll - 1
    elseif r == "down" then scroll = scroll + 1
    elseif r ~= "redraw" then return r end
  end
end

-- A list to pick from. items: list of { id, label, hint }. Returns the chosen id, or "back".
local function pick(title, sub, question, items, canBack)
  local sel, scroll = 1, 0
  while true do
    local q = wrap(question, W - 2)
    header(title, sub)
    for i, l in ipairs(q) do at(2, 2 + i, l, col(colors.lightGray, colors.white)) end
    local top = 3 + #q + 1
    local rows = H - top + 1 - (canBack and 1 or 0)
    local per = (items[1] and items[1][3] and rows >= #items * 2) and 2 or 1
    local shown = math.max(1, math.floor(rows / per))
    if sel <= scroll then scroll = sel - 1 end
    if sel > scroll + shown then scroll = sel - shown end
    local spots = {}
    for i = 1, shown do
      local it = items[i + scroll]
      if not it then break end
      local y = top + (i - 1) * per
      local on = i + scroll == sel
      local fg, bg = on and colors.black or colors.white, on and col(colors.yellow, colors.white) or colors.black
      at(1, y, (" "):rep(W), fg, bg)
      at(2, y, ((on and "> " or "  ") .. it[2]):sub(1, W - 2), fg, bg)
      if per == 2 and it[3] then at(4, y + 1, tostring(it[3]):sub(1, W - 4), col(colors.lightGray, colors.white), colors.black) end
      spots[#spots + 1] = { y = y, h = per, i = i + scroll }
    end
    if scroll > 0 then at(W, top, "\24", colors.lightGray, colors.black) end
    if scroll + shown < #items then at(W, top + shown * per - 1, "\25", colors.lightGray, colors.black) end
    if canBack then at(2, H, "< Back", col(colors.lightGray, colors.white), colors.black) end
    local ev, a, b, c = os.pullEvent()
    if ev == "key" then
      if a == keys.up then sel = math.max(1, sel - 1)
      elseif a == keys.down or a == keys.tab then sel = math.min(#items, sel + 1)
      elseif a == keys.enter or a == keys.numPadEnter or a == keys.space then return items[sel][1]
      elseif a == keys.backspace and canBack then return "back" end
    elseif ev == "char" and tonumber(a) and items[tonumber(a)] and #items <= 9 then
      return items[tonumber(a)][1]
    elseif ev == "mouse_scroll" then
      scroll = math.max(0, math.min(#items - shown, scroll + a))
      sel = math.max(scroll + 1, math.min(scroll + shown, sel))
    elseif ev == "mouse_click" then
      if canBack and c == H and b <= 8 then return "back" end
      for _, s in ipairs(spots) do
        if c >= s.y and c < s.y + s.h then return items[s.i][1] end
      end
    elseif ev == "term_resize" then W, H = term.getSize()
    end
  end
end

-- Type a value. Returns the text ("" = skipped), or nil = back (empty Enter when there is
-- nothing to keep and the answer isn't optional).
local function ask(title, sub, question, default, optional, secret)
  header(title, sub)
  local q = wrap(question, W - 2)
  for i, l in ipairs(q) do at(2, 2 + i, l, colors.white) end
  local y = math.min(H - 3, 4 + #q)
  if optional then at(2, H, "Empty = skip", colors.lightGray)
  elseif not default then at(2, H, "Empty = back", colors.lightGray) end
  at(2, y, "> ", col(colors.yellow, colors.white))
  term.setTextColor(colors.white)
  term.setCursorBlink(true)
  local s = read(secret and "*" or nil, nil, nil, default ~= nil and tostring(default) or nil)
  term.setCursorBlink(false)
  s = (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" and not optional then return nil end
  return s
end

-- Run a command with its output on screen. Returns "next", "back" or "repeat".
local function runShown(title, sub, cmd)
  header(title, sub)
  at(2, 2, ("> " .. table.concat(cmd, " ")):sub(1, W - 1), col(colors.yellow, colors.white))
  local w = window.create(term.current(), 1, 3, W, H - 3)
  w.setBackgroundColor(colors.black)
  w.setTextColor(colors.white)
  w.clear()
  w.setCursorPos(1, 1)
  local old = term.redirect(w)
  local ok, err = pcall(shell.run, table.unpack(cmd))
  if not ok then printError(err) end
  term.redirect(old)
  local focus = { i = 3 }
  while true do
    at(1, H, (" "):rep(W), colors.white, colors.black)
    local r = buttonBar({ { "back", "Back" }, { "repeat", "Repeat" }, { "next", "Next" } }, focus)
    if r == "next" or r == "back" or r == "repeat" then return r end
  end
end

---------------------------------------------------------------------------
-- Download
---------------------------------------------------------------------------
local function download(files)
  local failed = {}
  for _, f in ipairs(files) do
    write(" " .. f .. " ... ")
    local res, err = http.get(BASE .. f .. "?t=" .. os.epoch("utc"))
    local code = res and res.readAll()
    if res then res.close() end
    if code and code ~= "" and load(code, "=" .. f) then
      if fs.exists(f) then fs.delete(f) end
      local h = fs.open(f, "w")
      h.write(code)
      h.close()
      print("ok")
    else
      print("failed")
      failed[#failed + 1] = f .. " (" .. tostring(err or "broken download") .. ")"
    end
  end
  return failed
end

---------------------------------------------------------------------------
-- The bots and their setup steps
--   say  = text to read (what to build by hand); check = optional test shown below it
--   ask  = a value to type (kind number/text) or pick (choices), stored as ctx[ask]
--   run  = a command to run (built from the answers); its output is shown
--   when = only do this step when it returns true
--   loop = steps to repeat while the user answers yes to 'again'
---------------------------------------------------------------------------
local DIRS = { { "north", "North (-Z)" }, { "east", "East (+X)" }, { "south", "South (+Z)" }, { "west", "West (-X)" } }
local ROLES = { { "east", "East" }, { "south", "South" }, { "west", "West" }, { "north", "North" } }

-- x, y, z of something, filled in from GPS when the installer has a fix
local function coords(what, onlyWhen)
  return {
    { ask = "x", kind = "number", q = "Where is " .. what .. "? Press F3 and look at it. X:", gps = 1, when = onlyWhen },
    { ask = "y", kind = "number", q = "Y (height):", gps = 2, when = onlyWhen },
    { ask = "z", kind = "number", q = "Z:", gps = 3, when = onlyWhen },
  }
end
local function facing(onlyWhen)
  return { ask = "facing", choices = DIRS, when = onlyWhen,
    q = "Which way does it face? (F3 'Facing' while you look the same way as the turtle)" }
end
local function join(...)
  local out = {}
  for _, l in ipairs({ ... }) do for _, s in ipairs(l) do out[#out + 1] = s end end
  return out
end
local function modemCheck()
  if wireless() then return true, "Wireless modem found." end
  return false, "No wireless or ender modem on it yet."
end
local function fuelCheck(n)
  return function()
    if fuel() >= n then return true, "Fuel: " .. fuel() .. "." end
    return false, "Fuel is " .. fuel() .. ". Put coal or a lava bucket in it and type: refuel all"
  end
end

local BOTS = {
  { id = "miner", name = "Mining turtle", hint = "Mine Army: digs ore for the hub", on = "turtle",
    files = { "miner.lua" }, start = { "miner" },
    steps = join({
      { say = "Build this around the turtle:\n\n* A mining turtle (pickaxe) with a wireless or ender modem.\n* A chest next to it: behind it, or to its left or right.\n* A 1x1 hole IN FRONT of it going down.\n* 2 lava buckets in the turtle or the chest, and a spare empty bucket in the chest.",
        check = modemCheck },
      { say = "Checking for the chest next to the turtle.", check = function()
          local ok, n = chestNear()
          if not ok then return false, "No chest behind it, or to its left or right." end
          if n > 1 then return false, "More than one chest next to it. Keep one, or it can get confused about its direction." end
          return true, "Chest found."
        end },
    }, {
      -- With GPS it finds its own position and facing. Without GPS it can work out its
      -- position from the hub's (shows on the map), or use its own spot as home (height only).
      { ask = "how", when = function(c) return not c.gps end,
        choices = { { "hub", "From the hub (on the map)" }, { "here", "Height only (no map)" } },
        q = "No GPS here. The turtle can find its position from the hub (the hub must be set up and running first, it then shows on the pocket map), or use its own spot as home and only ask its height." },
      facing(function(c) return c.how == "hub" end),
      { ask = "side", when = function(c) return c.how == "hub" end,
        choices = { { "right", "To its right" }, { "left", "To its left" } },
        q = "Stand behind the turtle, looking the way it faces. Is the hub computer more to its right or to its left?" },
      { say = "It now steps into its hole and back to measure the distance to the hub.", check = fuelCheck(4),
        when = function(c) return c.how == "hub" end },
      { ask = "y", kind = "number", q = "Its own spot is home (x 0 z 0). Only its height: press F3, look at the turtle. Y:",
        when = function(c) return c.how == "here" end },
      { say = "With GPS it finds its own position. To find which way it faces it steps into its hole and back.",
        check = fuelCheck(2), when = function(c) return c.gps end },
      { ask = "role", choices = { { "auto", "Let the hub pick" }, table.unpack(ROLES) }, when = function(c) return c.how ~= "here" end,
        q = "Its role = the direction of its main tunnel. Let the hub pick one (you can change it on the hub or the pocket later), or pick it yourself: give every turtle a different one, so they each mine their own quarter." },
      { ask = "role", when = function(c) return c.how == "here" end,
        choices = { { "auto", "Let the hub pick" }, { "right", "To its right" }, { "left", "To its left" }, { "forward", "Straight ahead" }, { "back", "Backward (under the chest)" } },
        q = "Which way should its main tunnel go? Let the hub pick, or pick it: turtles standing next to each other each need a different one." },
      { ask = "name", optional = true,
        q = "A name for this miner, shown on the hub and the pocket (you can rename it there later). Empty = Miner-<number>." },
      { run = function(c)
          local name = c.name and ('"name=' .. c.name:gsub('"', "") .. '"') or nil
          if c.gps then return { "miner", "setup", c.role, name } end
          if c.how == "hub" then return { "miner", "setup", "hub", c.facing, c.role, c.side, name } end
          return { "miner", "setup", c.y, c.role, name }
        end },
      { say = "This turtle mines for the hub. If you haven't yet: set up a computer nearby with this installer and pick 'Mine Army hub'." },
    }) },
  { id = "hub", name = "Mine Army hub", hint = "base computer + dashboard for the miners", on = "computer",
    files = { "hub.lua", "miner.lua", "fleetview.lua" }, start = { "hub" },
    steps = join({
      { say = "Build this:\n\n* An (advanced) computer within about 64 blocks of the mining turtles, with a wireless or ender modem.\n* Optional: a monitor next to it (advanced = touch buttons). A second monitor becomes an info screen.",
        check = modemCheck },
      { run = function() return { "hub", "install" } end },
    }, coords("this computer"), {
      -- miners without GPS ask the hub where it is and work out their own spot from that
      { run = function(c) return { "hub", "pos", c.x, c.y, c.z } end },
      { say = "Set up each mining turtle with this installer too (pick 'Mining turtle'). On the dashboard you pick a time and an ore." },
    }) },
  { id = "relay", name = "Radio relay", hint = "range booster for normal wireless modems", on = "computer",
    files = { "relay.lua" }, start = { "relay" },
    steps = {
      { say = "Put this computer high above your base (y 250 or more, e.g. on a pillar) with a wireless modem, in a chunk that stays loaded. It passes all messages on, so the hub hears the turtles everywhere.",
        check = modemCheck },
      { run = function() return { "relay", "install" } end },
    } },
  { id = "roomsorter", name = "Storage Room turtle", hint = "sorts, smelts and fetches in a closed room", on = "turtle",
    files = { "roomsorter.lua" }, start = { "roomsorter" },
    steps = {
      { say = "Build a closed room with a flat floor and ceiling (any size and shape), at least 3 high for furnaces. Build an INPUT chest and an OUTPUT chest into its walls, so you can reach them from outside. Best: both at floor height." },
      { say = "Put this turtle on the floor of the room, FACING THE INPUT CHEST, with some coal in it. A wireless modem is optional (for the pocket panel and the order computer).",
        check = fuelCheck(100) },
      { ask = "height", kind = "number", optional = true,
        q = "How many blocks high is the inside of the room? (empty = it flies up and measures)" },
      { run = function(c) return { "roomsorter", "scan", c.height } end },
      { run = function() return { "roomsorter", "install" } end },
      { say = "Last step: put chests or barrels, furnaces / blast furnaces and coal in the input chest. The turtle builds its storage with them." },
    } },
  { id = "roomclient", name = "Storage order computer", hint = "order screen or stock board outside the room", on = "computer",
    files = { "roomsorter.lua" },
    steps = {
      { ask = "mode", choices = { { "client", "Order screen / prompt" }, { "board", "Stock board on a monitor" } },
        q = "What should this computer be?" },
      { say = "Give it a wireless modem (or a cable to the board computer). For the order screen, an advanced monitor next to it is the nicest.",
        check = modemCheck },
      { run = function(c) return { "roomsorter", "install", c.mode } end },
    },
    start = function(c) return { "roomsorter", c.mode } end },
  { id = "sorter", name = "Sorter & Smelter", hint = "wired network of chests and furnaces", on = "any",
    files = { "sorter.lua" }, start = { "sorter" },
    steps = {
      { say = "Put a WIRED modem against this turtle/computer and connect your chests, furnaces and blast furnaces with cables and wired modems (right-click each modem so it turns red)." },
      { say = "Next, setup walks past every chest on the network and asks its role. Tip: put a marker item in a chest to recognise it." },
      { run = function() return { "sorter", "setup" } end },
      { run = function() return { "sorter", "install" } end },
    } },
  { id = "lumber", name = "Lumberjack", hint = "tree farm: fells, replants, brings logs", on = "turtle",
    files = { "lumber.lua" }, start = { "lumber" },
    steps = {
      { say = "Build this:\n\n* A felling turtle (axe), in the open, next to a chest (behind it is best).\n* Lava buckets in that chest as fuel (it never burns its own wood).\n* The space above the turtle free: it flies out through there.\n* A few saplings help it get going (optional).\n* A wireless modem for the pocket panel (optional)." },
      { ask = "radius", kind = "number", default = 48, q = "How far from its chest may it look for trees? (blocks)" },
      { run = function(c) return { "lumber", "setup", c.radius } end },
    } },
  { id = "farmer", name = "Farmer", hint = "crop farm: harvests and replants", on = "turtle",
    files = { "farmer.lua" }, start = { "farmer" },
    steps = {
      { say = "Put the turtle on the ground at one CORNER of the field, at the height of the crops, with a chest BEHIND it. The field lies in front of it. Keep the block above it free. A hoe is best (it tills dried-out dirt)." },
      { say = "Fuel: lava buckets or coal in a chest UNDER the turtle (or in the chest behind it, unless that one is the storage room's input)." },
      { ask = "length", kind = "number", q = "How many rows does the field have, counting away from the chest?" },
      { ask = "width", kind = "number", q = "How many blocks per row, counting from the turtle's own column?" },
      { ask = "side", choices = { { "right", "Rows go to its right" }, { "left", "Rows go to its left" } },
        q = "Which side of the turtle is the field?" },
      { run = function(c) return { "farmer", "setup", c.length, c.width, c.side == "left" and "left" or nil } end },
      { ask = "drop", choices = { { "behind", "The chest behind it" }, { "other", "Another chest (storage input)" } },
        q = "Where should the harvest go?" },
      { ask = "df", kind = "number", q = "Blocks FORWARD from its home spot to that chest (backward = negative):",
        when = function(c) return c.drop == "other" end },
      { ask = "dr", kind = "number", q = "Blocks to the RIGHT (left = negative):", when = function(c) return c.drop == "other" end },
      { ask = "du", kind = "number", q = "Blocks UP (down = negative). That chest needs open sky above it.",
        when = function(c) return c.drop == "other" end },
      { run = function(c) return { "farmer", "drop", c.df, c.dr, c.du } end, when = function(c) return c.drop == "other" end },
      { ask = "seed", choices = { { "none", "Something is already growing" }, { "wheat", "Wheat" }, { "carrot", "Carrots" },
          { "potato", "Potatoes" }, { "beetroot", "Beetroot" }, { "netherwart", "Nether wart" } },
        q = "Is the field new and empty? Then pick what to plant (and give it some):" },
      { run = function(c) return { "farmer", "seed", c.seed } end, when = function(c) return c.seed ~= "none" end },
    } },
  { id = "lava", name = "Lava runner", hint = "fills buckets, stocks the bots' chests", on = "turtle",
    files = { "lava.lua" }, start = { "lava" },
    steps = join({
      { say = "Build this:\n\n* A turtle with a wireless or ender modem.\n* A chest BEHIND it with some empty buckets.\n* One lava bucket in it as fuel to start.\n* Lava: a dripstone cauldron farm in a corridor in front of it, and/or a lava pool somewhere.",
        check = modemCheck },
    }, coords("the turtle"), {
      facing(),
      { run = function(c) return { "lava", "setup", c.x, c.y, c.z, c.facing } end },
      { loop = {
          { ask = "name", kind = "text", q = "A chest to keep stocked with lava. A short name for it (e.g. lumber, miner1):" },
          { ask = "dx", kind = "number", q = "Its X (F3, look at the chest):" },
          { ask = "dy", kind = "number", q = "Its Y:" },
          { ask = "dz", kind = "number", q = "Its Z:" },
          { ask = "n", kind = "number", default = 6, q = "How many lava buckets should it keep in there?" },
          { run = function(c) return { "lava", "add", c.name, c.dx, c.dy, c.dz, c.n } end },
        }, again = "Add a chest it should keep stocked with lava? (the lumberjack's, each miner's, ...)" },
      { ask = "px", kind = "number", optional = true, q = "A lava pool to scoop from? X of a lava block on its surface (empty = none):" },
      { ask = "py", kind = "number", q = "Y of that lava block:", when = function(c) return c.px end },
      { ask = "pz", kind = "number", q = "Z of that lava block:", when = function(c) return c.px end },
      { run = function(c) return { "lava", "pool", c.px, c.py, c.pz } end, when = function(c) return c.px end },
    }) },
  { id = "builder", name = "Builder", hint = "floors, walls, flat land, torches", on = "turtle",
    files = { "builder.lua" }, start = { "builder" },
    steps = join({
      { say = "Build this:\n\n* A turtle with a pickaxe (and a wireless modem to order blocks and for the panel).\n* A supply chest next to it. Best: against the outside of the Storage Room's pickup chest, so what it orders lands there.\n* Some fuel in it." },
      { ask = "pos", choices = { { "gps", "GPS, or count from its home" }, { "type", "I'll type its coordinates" } },
        q = "How should it know where it is?" },
    }, coords("the turtle", function(c) return c.pos == "type" end), {
      facing(function(c) return c.pos == "type" end),
      { run = function(c)
          if c.pos == "type" then return { "builder", "setup", c.x, c.y, c.z, c.facing } end
          return { "builder", "setup" }
        end },
      { say = "Give it jobs from the pocket panel (Bots tab, Builder), or type them, e.g.: builder floor x1 y1 z1 x2 y2 z2" },
    }) },
  { id = "buddy", name = "Buddy", hint = "a companion turtle you chat with (AI)", on = "turtle",
    files = { "buddy.lua" }, start = { "buddy" },
    steps = {
      { say = "Buddy needs a language model: your own server (vLLM, Ollama, LM Studio, ...) that the Minecraft server can reach, or xAI's Grok (paid). http must be enabled in the CC config. A Chat Box on it lets you talk in game chat (optional)." },
      { ask = "brain", choices = { { "own", "My own model server" }, { "grok", "xAI Grok" } }, q = "Which brain?" },
      { ask = "url", kind = "text", q = "Server address, e.g. http://my-gpu-box:8000", when = function(c) return c.brain == "own" end },
      { run = function(c) return { "buddy", "server", c.url } end, when = function(c) return c.brain == "own" end },
      { run = function() return { "buddy", "server", "grok" } end, when = function(c) return c.brain == "grok" end },
      { ask = "key", kind = "text", optional = true, secret = true,
        q = "API key (Grok: from console.x.ai). It stays on this turtle. Empty = none:" },
      { run = function(c) return { "buddy", "key", c.key } end, when = function(c) return c.key end },
      { ask = "bname", kind = "text", default = os.getComputerLabel() or "Buddy", q = "Its name:" },
      { say = "Put it on its home spot now: setup remembers this spot as home." },
      { run = function(c) return { "buddy", "setup", c.bname } end },
    } },
  { id = "factory", name = "Turtle factory", hint = "crafty turtle that builds new miners", on = "turtle",
    files = { "factory.lua", "miner.lua" }, start = { "factory" },
    steps = join({
      { say = "Around the factory (a crafty turtle with a wireless modem), outside the Storage Room:\n\n* FRONT: the room's pickup chest.\n* BELOW: a chest of its own for parts and coal.\n* ABOVE: the build spot, open to the sky.\n* A disk drive with a floppy right next to the build spot.\n\nThe Storage Room turtle needs a modem and a crafting table too.",
        check = modemCheck },
    }, coords("the factory turtle"), {
      { run = function(c) return { "factory", "setup", c.x, c.y, c.z } end },
      { loop = {
          { ask = "sx", kind = "number", q = "Home spot for a new miner (where it will stand). X:" },
          { ask = "sy", kind = "number", q = "Y:" },
          { ask = "sz", kind = "number", q = "Z:" },
          { ask = "sf", choices = DIRS, q = "Which way will it face? (its chest is behind it)" },
          { ask = "sr", choices = ROLES, q = "Its role (main tunnel direction):" },
          { run = function(c) return { "factory", "slot", c.sx, c.sy, c.sz, c.sf, c.sr } end },
        }, again = "Add a home spot for a new miner? (a chest behind it and a hole in front, like any miner)" },
      { say = "Put a floppy in a disk drive next to THIS turtle for a moment: it writes the installer for the new turtles onto it. Then move the drive next to the build spot." },
      { run = function() return { "factory", "disk" } end },
    }) },
  { id = "gpshost", name = "GPS host", hint = "one of 4 computers for positions + map", on = "computer",
    files = { "gpshost.lua" },
    steps = join({
      { say = "A GPS tower is 4 computers with modems (ender modems are easiest), a few blocks apart, NOT all at the same height and NOT in one line, e.g. an L of three and the fourth 3 higher. Keep the chunk loaded.",
        check = modemCheck },
    }, coords("THIS computer block (F3: 'Targeted Block')")),
    start = function(c) return { "gpshost", c.x, c.y, c.z } end,
    done = "Start it now: it saves its position and starts hosting again after every reboot. Do the same on the other three." },
  { id = "server", name = "Fleet server", hint = "fleet state, logs and offline code updates", on = "computer",
    files = { "server.lua", "fleetview.lua" }, start = { "server" },
    steps = {
      { say = "A dedicated computer with a wireless or ender modem. A monitor is optional. Keep its chunk loaded. No disk drive is needed. With http it caches the scripts from GitHub main; other computers can update through its modem.",
        check = modemCheck },
      { run = function() return { "server", "install" } end },
    } },
  { id = "panel", name = "Pocket panel", hint = "control everything from your pocket", on = "pocket",
    files = { "panel.lua", "fleetview.lua" }, start = { "panel" },
    steps = {
      { say = "Use an ADVANCED pocket computer with an ender modem (works anywhere) or a wireless modem (within range).",
        check = modemCheck },
      { run = function() return { "panel", "install" } end },
      { say = "Tip: stand next to a bot and type 'pair' in the panel's console (>_) to unlock its developer commands." },
    } },
  { id = "smartmine", name = "Simple tunnel miner", hint = "the old standalone miner, no hub", on = "turtle",
    files = { "smartmine.lua" },
    steps = {
      { say = "A mining turtle facing into the tunnel, with a chest of coal directly BEHIND it." },
      { ask = "len", kind = "number", default = 32, q = "Length of each tunnel:" },
      { ask = "tunnels", kind = "number", default = 1, q = "How many tunnels side by side (to the right)?" },
      { ask = "gap", kind = "number", default = 3, q = "Blocks between the tunnels:" },
    },
    start = function(c) return { "smartmine", c.len, c.tunnels, c.gap } end,
    done = "It doesn't start by itself after a reboot: run it again when you want another tunnel." },
}

---------------------------------------------------------------------------
-- Walking through one bot's steps
---------------------------------------------------------------------------
-- Returns true when finished, false when the user went back from the first step
local function guide(bot)
  local title = bot.name
  local ctx = {}
  header(title, "download")
  print("")
  local gx, gy, gz = gpsHere()
  ctx.gps = gx and { gx, gy, gz } or nil
  print(" Downloading...")
  local files = { "update.lua", "install.lua" }
  for k = #bot.files, 1, -1 do table.insert(files, 1, bot.files[k]) end
  local failed = download(files)
  if #failed > 0 then
    local r = screen(title, "download", { { "Couldn't download:", colors.red }, { table.concat(failed, "\n") },
      { "\nIs http enabled in the ComputerCraft config, and can this server reach GitHub?", colors.lightGray } },
      { { "back", "Back" }, { "retry", "Try again" } })
    if r == "retry" then return guide(bot) end
    return false
  end

  local steps = {}
  for _, s in ipairs(bot.steps) do steps[#steps + 1] = s end
  local i, history = 1, {}
  while i <= #steps do
    local s = steps[i]
    local sub = i .. "/" .. #steps
    local result
    if s.when and not s.when(ctx) then
      result = "skip"
    elseif s.say then
      local text = { { s.say } }
      local btns = { { "back", "Back" } }
      if s.check then
        local ok, msg = s.check(ctx)
        text[#text + 1] = { "\n" .. (ok and "OK: " or "! ") .. msg, ok and colors.lime or colors.orange }
        btns[#btns + 1] = { "again", "Check" }
      end
      btns[#btns + 1] = { "next", "Next" }
      result = screen(title, sub, text, btns)
      if result == "again" then result = "stay" end
    elseif s.ask and s.choices then
      local items = {}
      for _, ch in ipairs(s.choices) do items[#items + 1] = { ch[1], ch[2] } end
      local v = pick(title, sub, s.q, items, true)
      if v == "back" then result = "back" else ctx[s.ask] = v result = "next" end
    elseif s.ask then
      local default = s.default
      if s.gps and ctx.gps then default = ctx.gps[s.gps] end
      if ctx[s.ask] ~= nil then default = ctx[s.ask] end
      local q = s.q
      if s.gps == 1 and ctx.gps then q = q .. "\n(filled in from GPS, Enter keeps it)" end
      local v = ask(title, sub, q, default, s.optional, s.secret)
      if v == nil then result = "back"
      elseif v == "" then ctx[s.ask] = nil result = "next"
      elseif s.kind == "number" and not tonumber(v) then
        screen(title, sub, { { "That isn't a number: " .. v, colors.orange } }, { { "ok", "OK" } })
        result = "stay"
      else ctx[s.ask] = s.kind == "number" and tonumber(v) or v result = "next" end
    elseif s.run then
      result = runShown(title, sub, words(s.run(ctx)))
      if result == "repeat" then result = "stay" end
    elseif s.loop then
      local r = screen(title, sub, { { s.again } }, { { "back", "Back" }, { "no", "No" }, { "yes", "Yes" } })
      if r == "yes" then
        -- one round of the loop's steps, then this question again
        for k = #s.loop, 1, -1 do table.insert(steps, i + 1, s.loop[k]) end
        table.insert(steps, i + #s.loop + 1, s)
        result = "next"
      elseif r == "no" then result = "next"
      else result = "back" end
    end

    if result == "next" then history[#history + 1] = i i = i + 1
    elseif result == "skip" then i = i + 1
    elseif result == "back" then
      if #history == 0 then return false end
      i = table.remove(history)
    end
  end

  -- Done
  local startCmd = type(bot.start) == "function" and bot.start(ctx) or bot.start
  startCmd = startCmd and words(startCmd)
  local text = { { "All set!", colors.lime },
    { bot.done or "It starts by itself whenever it turns on." },
    { "\nLater, '" .. bot.id .. " update' (or just 'update') fetches the newest version.", colors.lightGray } }
  local btns = { { "exit", "Exit" } }
  if startCmd then btns[#btns + 1] = { "start", "Start now" } end
  local r = screen(title, "done", text, btns)
  clear()
  if r == "start" then shell.run(table.unpack(startCmd))
  elseif startCmd then print("Start it with: " .. table.concat(startCmd, " ")) end
  return true
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
local byId = {}
for _, b in ipairs(BOTS) do byId[b.id] = b end

-- Wipe this machine for a fresh start: every file except the installer (disks and rom
-- stay), the label, and anything the Mine Army hub remembers about it
local function reset(ask)
  local what = ({ turtle = "turtle", pocket = "pocket computer", computer = "computer" })[KIND]
  if ask and screen("Reset this " .. what, nil, {
      { "This deletes every file on this " .. what .. " (its setup, saved state, logs and scripts) and its name. Only install.lua stays, so you can set it up again." },
      { "\nDisks are not touched. A miner is also wiped from the hub's memory (its orders, tunnel job and direction).", colors.lightGray } },
      { { "back", "Back" }, { "reset", "Reset" } }, 1) ~= "reset" then return false end
  local me = shell and shell.getRunningProgram() or "install.lua"
  for _, f in ipairs(fs.list("/")) do
    if f ~= "rom" and f ~= me and f ~= "install.lua" and fs.getDrive(f) == "hdd" then fs.delete(f) end
  end
  os.setComputerLabel(nil)
  -- The hub forgets its orders, tunnel job and direction for this machine
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
      rednet.open(name)
      rednet.broadcast({ type = "reset", id = os.getComputerID() }, "minearmy")
      break
    end
  end
  if ask then
    screen("Reset this " .. what, nil, { { "Done: this " .. what .. " is empty. Pick what it should become next.", colors.lime } },
      { { "ok", "OK" } })
  else
    print("Done: this " .. what .. " is empty. Run 'install' to set it up again.")
  end
  return true
end

if args[1] == "reset" then
  reset(args[2] ~= "now")
  return
end

if args[1] and not byId[args[1]] then
  print("Unknown bot: " .. args[1])
  local names = {}
  for _, b in ipairs(BOTS) do names[#names + 1] = b.id end
  print("Bots: " .. table.concat(names, ", "))
  return
end
if not http then
  print("http is disabled in the ComputerCraft config. Turn it on, or drag the .lua files onto this computer.")
  return
end
if args[1] and args[2] == "quick" then
  local files = { "update.lua", "install.lua" }
  for k = #byId[args[1]].files, 1, -1 do table.insert(files, 1, byId[args[1]].files[k]) end
  local failed = download(files)
  print(#failed == 0 and ("Done. Guided setup: install " .. args[1]) or ("Failed: " .. table.concat(failed, ", ")))
  return
end

-- "any" = a turtle or a computer (a pocket computer can't hold a wired modem)
local function fits(bot) return bot.on == KIND or (bot.on == "any" and KIND ~= "pocket") end

-- A bot for another kind of machine: explain, and offer to just download it
local function elsewhere(bot)
  local what = bot.on == "any" and "turtle or computer" or (bot.on == "pocket" and "pocket computer" or bot.on)
  local r = screen(bot.name, nil, { { bot.name .. " runs on a " .. what .. "." },
    { "\nRun this installer on that " .. what .. " instead:", colors.lightGray },
    { "wget run " .. BASE .. "install.lua", col(colors.yellow, colors.white) },
    { "\nOr just download the files here (e.g. to copy them onto a disk).", colors.lightGray } },
    { { "back", "Back" }, { "dl", "Download" } }, 1)
  if r ~= "dl" then return false end
  header(bot.name, "download")
  print("")
  local files = { "update.lua", "install.lua" }
  for k = #bot.files, 1, -1 do table.insert(files, 1, bot.files[k]) end
  local failed = download(files)
  screen(bot.name, "download", { #failed == 0 and { "Downloaded.", colors.lime }
    or { "Couldn't download: " .. table.concat(failed, ", "), colors.red } }, { { "ok", "OK" } })
  return false
end

local function menu()
  while true do
    local items, others = {}, {}
    for _, b in ipairs(BOTS) do
      if fits(b) then items[#items + 1] = { b.id, b.name, b.hint } else others[#others + 1] = b end
    end
    items[#items + 1] = { "*other", "Bots for other machines", "everything else in the repo" }
    items[#items + 1] = { "*reset", "Reset this " .. ({ turtle = "turtle", pocket = "pocket computer", computer = "computer" })[KIND],
      "wipe old setup and state, start fresh" }
    items[#items + 1] = { "*quit", "Exit", " " }
    local what = ({ turtle = "turtle", pocket = "pocket computer", computer = "computer" })[KIND]
    local v = pick("Bot installer", nil, "What should this " .. what .. " become?", items, false)
    if v == "*quit" then clear() return end
    if v == "*reset" then reset(true) end
    if v == "*other" then
      local list = {}
      for _, b in ipairs(others) do
        list[#list + 1] = { b.id, b.name, "for a " .. (b.on == "pocket" and "pocket computer" or b.on == "any" and "turtle or computer" or b.on) }
      end
      v = pick("Bot installer", nil, "These are meant for another kind of machine:", list, true)
    end
    if byId[v] then
      if not fits(byId[v]) then elsewhere(byId[v])
      elseif guide(byId[v]) then return end
    end
  end
end

if args[1] then
  local bot = byId[args[1]]
  if not fits(bot) then elsewhere(bot) menu()
  elseif not guide(bot) then menu() end
else
  menu()
end
