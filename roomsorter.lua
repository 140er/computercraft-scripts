-- roomsorter.lua - Storage room turtle (CC: Tweaked), no modems or cables needed
-- The turtle lives in a closed room with an INPUT chest and an OUTPUT chest in the walls.
-- It maps the room itself, builds chests and furnaces from the ones you give it, sorts
-- everything you put in the input chest, smelts raw ores, burns logs into charcoal and
-- remembers where it all is.
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
--   home             (turtle only) after it got lost: put it on its start spot facing the
--                    input chest first
--
-- Give it chests or barrels (storage) and furnaces / blast furnaces by putting them in the
-- input chest. Fuel for the turtle and the furnaces: coal, charcoal, coal blocks.
-- Logs (e.g. from the lumber turtle) become charcoal in the normal furnaces; it keeps
-- cfg.keepLogs of each kind as logs (default 32) and burns its own charcoal first.
-- Order something that comes out of a furnace (glass, stone, ingots, charcoal, ...) and
-- there's none: it smelts what it needs first (sand -> glass) and then delivers.

-- (one table: the main chunk is close to Lua's limit of 200 locals)
local FILES = { map = "room.map", idx = "room.idx", pos = "room.pos", cfg = "room.cfg", stats = "room.stats",
  log = "room.log" }
local PROTOCOL = "roomsorter"
local VERSION = 15 -- the order screen warns when the turtle runs an older roomsorter.lua

local args = { ... }
if args[1]=="ssot" then shell.run("store",table.unpack(args,2)) return end
if args[1] == "update" then
  -- latest version from GitHub (update.lua does the work, fetched here if missing)
  if not fs.exists("update.lua") then
    shell.run("wget", "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/update.lua", "update.lua")
  end
  shell.run("update")
  return
end
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
  -- Ask the turtle. Each question gets a number, so two screens asking at once don't mix
  -- up the answers. Events in 'keep' that come in meanwhile are handed back afterwards.
  local function ask(msg, keep)
    local rid = math.random(1, 1073741824)
    msg.rid = rid
    rednet.send(id, msg, proto)
    local timer = os.startTimer(8)
    local kept, reply = {}, nil
    while true do
      local e = table.pack(os.pullEvent())
      if e[1] == "rednet_message" and e[2] == id and e[4] == proto
        and (type(e[3]) ~= "table" or e[3].rid == nil or e[3].rid == rid) then
        reply = e[3]
        break
      elseif e[1] == "timer" and e[2] == timer then break
      elseif keep and keep[e[1]] then kept[#kept + 1] = e end
    end
    for _, e in ipairs(kept) do os.queueEvent(table.unpack(e, 1, e.n)) end
    return reply
  end

  -- The order screen with buttons, drawn on T: the computer's own screen, or an advanced
  -- monitor (onMonitor: tapping only, the typing happens on the computer)
  local function gui(T, onMonitor)
    local monName = onMonitor and peripheral.getName(T)
    local KEEP = onMonitor and { monitor_touch = true } or { mouse_click = true, key = true, char = true }
    local function askG(msg) return ask(msg, KEEP) end
    local function num(n)
      local s = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
      return s
    end
    local function has(n, words)
      for _, w in ipairs(words) do if n:find(w, 1, true) then return true end end
      return false
    end
    -- Categories: the first one that fits an item wins
    local CATS = {
      { name = "Fuel", color = colors.gray, test = function(n)
        return n == "coal" or n == "charcoal" or n == "coal_block" or n == "lava_bucket" or n == "blaze_rod" or n == "dried_kelp_block" end },
      { name = "Ores", color = colors.orange, test = function(n)
        return n:find("_ore$") or n:find("^raw_") or n == "ancient_debris" end },
      { name = "Ingots", color = colors.yellow, test = function(n)
        return n:find("_ingot$") or n:find("_nugget$") or n == "netherite_scrap"
          or n:find("^iron_block") or n:find("^gold_block") or n:find("^copper_block") or n:find("^netherite_block") end },
      { name = "Gems", color = colors.lightBlue, test = function(n)
        return has(n, { "diamond", "emerald", "lapis", "redstone", "quartz", "amethyst", "_gem", "_dust", "_shard", "_crystal" }) end },
      { name = "Wood", color = colors.brown, test = function(n)
        return has(n, { "_log", "_planks", "_wood", "stick", "sapling", "leaves", "_stem", "bamboo", "hyphae" }) end },
      { name = "Blocks", color = colors.lightGray, test = function(n)
        return has(n, { "stone", "cobble", "deepslate", "granite", "diorite", "andesite", "tuff", "calcite", "dirt", "gravel",
          "sand", "clay", "glass", "brick", "terracotta", "concrete", "netherrack", "basalt", "obsidian", "prismarine",
          "mud", "moss", "snow", "ice", "wool", "_slab", "_stairs", "_wall" }) end },
      { name = "Food & farm", color = colors.lime, test = function(n)
        return has(n, { "wheat", "seeds", "carrot", "potato", "beetroot", "bread", "apple", "beef", "porkchop", "chicken",
          "mutton", "rabbit", "cod", "salmon", "melon", "pumpkin", "sugar", "egg", "milk", "cookie", "cake", "berries",
          "kelp", "cocoa", "honey", "mushroom", "stew", "pie", "steak" }) end },
      { name = "Mob drops", color = colors.red, test = function(n)
        return has(n, { "bone", "string", "gunpowder", "rotten_flesh", "spider_eye", "ender_pearl", "slime", "leather",
          "feather", "ghast_tear", "phantom", "ink_sac", "blaze_powder", "magma_cream", "shulker", "scute", "nautilus" }) end },
      { name = "Tools & gear", color = colors.cyan, test = function(n)
        return has(n, { "pickaxe", "sword", "_axe", "shovel", "_hoe", "helmet", "chestplate", "leggings", "boots", "bow",
          "arrow", "shield", "shears", "fishing_rod", "flint_and_steel", "trident", "bucket", "compass", "clock" }) end },
      { name = "Other", color = colors.white, test = function() return true end },
    }
    local function catOf(name)
      local n = name:match(":(.+)$") or name
      for i, c in ipairs(CATS) do if c.test(n) then return i end end
    end
    -- Short names for the tiles
    local TILE = { ["Food & farm"] = "Food", ["Tools & gear"] = "Tools" }
    -- 6x6 pixel icons (blit colours, "." = see-through), drawn as 3x2 characters
    local ICONS = {
      Fuel = { "..1...", ".141..", ".1441.", "144441", "14ee41", ".1111." },
      Ores = { "777777", "717787", "777177", "787717", "177777", "777717" },
      Ingots = { "......", "..444.", ".44444", "444441", "11111.", "......" },
      Gems = { "......", ".3333.", "330033", ".3333.", "..33..", "......" },
      Wood = { ".cccc.", "c1111c", "c1cc1c", "c1111c", ".cccc.", "......" },
      Blocks = { "ee8eee", "888888", "eeee8e", "888888", "ee8eee", "888888" },
      ["Food & farm"] = { "...d..", "..c...", ".eeee.", "eeeeee", "eeeeee", ".eeee." },
      ["Mob drops"] = { "00....", "000...", "..00..", "...000", "....00", "......" },
      ["Tools & gear"] = { "88888.", "...c8.", "..c..8", ".c....", "c.....", "......" },
      Other = { ".0000.", "0....0", "...00.", "..0...", "......", "..0..." },
      ["All items"] = { "111111", "1cccc1", "111111", "1c88c1", "1cccc1", "111111" },
      Craft = { "cccccc", "c1c1c1", "cccccc", "c1c1c1", "cccccc", "8....8" },
      Frequent = { "..44..", "444444", ".4444.", ".4..4.", "4....4", "......" },
    }
    local HEXC = {}
    for i = 0, 15 do HEXC[2 ^ i] = ("0123456789abcdef"):sub(i + 1, i + 1) end
    local function icon(x, y, art, bg)
      local b = HEXC[bg] or "f"
      for row = 0, 1 do
        local txt, fg, bgs = "", "", ""
        for col = 0, 2 do
          local px = {}
          for py = 0, 2 do
            for pxx = 0, 1 do
              local ch = art[row * 3 + py + 1]:sub(col * 2 + pxx + 1, col * 2 + pxx + 1)
              px[#px + 1] = (ch == "." or ch == "") and b or ch
            end
          end
          -- 2 colours per character: the bottom-right pixel's colour is the background
          local back = px[6]
          local fore = back
          local n = {}
          for i = 1, 5 do if px[i] ~= back then n[px[i]] = (n[px[i]] or 0) + 1 end end
          local best = 0
          for c, k in pairs(n) do if k > best then fore, best = c, k end end
          local bits = 0
          for i = 1, 5 do if px[i] ~= back then bits = bits + 2 ^ (i - 1) end end
          txt = txt .. string.char(128 + bits)
          fg, bgs = fg .. fore, bgs .. back
        end
        T.setCursorPos(x, y + row)
        T.blit(txt, fg, bgs)
      end
    end

    local stock, stockOk, turtleState, canCraft = {}, false, "?", false
    local turtleOld, cutoff = false, 0
    local recipes, orders = {}, {}
    local function refresh()
      local r = askG({ cmd = "stock" })
      if type(r) == "table" and type(r.totals) == "table" then
        stock, stockOk, turtleState, canCraft = r.totals, true, r.state or "?", r.crafty
        turtleOld = (r.version or 0) < VERSION
        cutoff = r.cutoff or 0
        recipes = type(r.recipes) == "table" and r.recipes or {}
        orders = type(r.orders) == "table" and r.orders or {}
      else
        stockOk, turtleState = false, "no answer"
      end
    end
    -- Everything you can order: what's in storage, plus what it can craft
    local function entries()
      local by = {}
      for name, n in pairs(stock) do by[name] = { name = name, n = n, can = 0 } end
      for _, r in ipairs(recipes) do
        local e = by[r.name]
        if e then e.can, e.per, e.missing = r.can, r.per, r.missing
        elseif r.can > 0 then by[r.name] = { name = r.name, n = 0, can = r.can, per = r.per } end
      end
      local l = {}
      for _, e in pairs(by) do e.orders = orders[e.name] or 0 l[#l + 1] = e end
      return l
    end
    local function itemsIn(which) -- a category number, "all" or "frequent"
      local l = {}
      for _, e in ipairs(entries()) do
        if which == "all" or (which == "frequent" and e.orders > 0) or catOf(e.name) == which then l[#l + 1] = e end
      end
      if which == "frequent" then
        table.sort(l, function(a, b) if a.orders ~= b.orders then return a.orders > b.orders end return a.name < b.name end)
      else
        table.sort(l, function(a, b) return pretty(a.name) < pretty(b.name) end)
      end
      return l
    end

    local W, H = T.getSize()
    local buttons = {}
    local function clear()
      T.setBackgroundColor(colors.black)
      T.clear()
      buttons = {}
    end
    local function text(x, y, s, fg, bg)
      T.setCursorPos(x, y)
      T.setTextColor(fg or colors.white)
      T.setBackgroundColor(bg or colors.black)
      T.write(s)
    end
    local function button(x, y, w, h, label, bg, fg, action)
      for yy = y, y + h - 1 do text(x, yy, (" "):rep(w), fg, bg) end
      local l = label:sub(1, w - 2)
      text(x + math.floor((w - #l) / 2), y + math.floor((h - 1) / 2), l, fg or colors.black, bg)
      buttons[#buttons + 1] = { x1 = x, y1 = y, x2 = x + w - 1, y2 = y + h - 1, action = action }
    end
    local function titleBar(title, back)
      text(1, 1, (" "):rep(W), colors.white, colors.blue)
      local x = 2
      if back then
        button(1, 1, 8, 1, "< Back", colors.lightBlue, colors.black, back)
        x = 10
      end
      -- what the turtle is busy with, on the right
      local st = "Status: " .. tostring(turtleState)
      local room = W - x - #title - 3
      if room >= 12 then
        st = st:sub(1, room)
        text(W - #st, 1, st, colors.yellow, colors.blue)
      end
      text(x, 1, title:sub(1, W - x - 1), colors.white, colors.blue)
    end
    local function waitClick()
      local tick = os.startTimer(5)
      while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "timer" and a == tick then return "tick" end
        local clicked = (onMonitor and ev == "monitor_touch" and a == monName) or (not onMonitor and ev == "mouse_click")
        if clicked then
          for _, bt in ipairs(buttons) do
            if b >= bt.x1 and b <= bt.x2 and c >= bt.y1 and c <= bt.y2 then return bt.action end
          end
        elseif ev == "key" and a == keys.backspace and not onMonitor then
          return "back"
        end
      end
    end
    -- Tiles: icon, name and a second line; 3 columns on a computer, 2 on a pocket computer
    local function drawTiles(tiles)
      local cols = W >= 45 and 3 or 2
      local bw = math.floor((W - (cols + 1)) / cols)
      local rows = math.ceil(#tiles / cols)
      local gap = (rows * 3 - 1 <= H - 4) and 1 or 0
      for k, e in ipairs(tiles) do
        local x = 2 + ((k - 1) % cols) * (bw + 1)
        local y = 3 + math.floor((k - 1) / cols) * (2 + gap)
        local tbg = e.bg or colors.gray
        text(x, y, (" "):rep(bw), colors.white, tbg)
        text(x, y + 1, (" "):rep(bw), colors.white, tbg)
        icon(x + 1, y, ICONS[e.icon] or ICONS.Other, tbg)
        local nameColor = e.color or colors.white
        if nameColor == tbg or nameColor == colors.gray then nameColor = colors.white end
        if nameColor == colors.brown then nameColor = colors.orange end
        text(x + 5, y, e.name:sub(1, bw - 5), e.empty and colors.lightGray or nameColor, tbg)
        text(x + 5, y + 1, e.sub:sub(1, bw - 5), e.empty and colors.lightGray or colors.white, tbg)
        buttons[#buttons + 1] = { x1 = x, y1 = y, x2 = x + bw - 1, y2 = y + 1, action = e.action }
      end
    end

    local screen, cat, page, item = "home", nil, 1, nil
    local custom = 1 -- the amount picked with the arrows on a monitor
    local message = nil
    local OLD = "The turtle runs an older roomsorter.lua: copy the new one onto it and reboot it."
    local function order(name, n)
      local r = askG({ cmd = "order", text = name, n = n })
      if type(r) == "table" and type(r[1]) == "string" and r[1]:find("^Commands:") then
        -- an older turtle doesn't know 'order': just get it from storage
        r = askG({ cmd = "get", text = name, n = n })
        if type(r) == "table" then r[#r + 1] = "" r[#r + 1] = OLD end
      end
      message = type(r) == "table" and r or { "No answer (out of range?)" }
    end

    local function typeIt()
      clear()
      titleBar("Type it yourself")
      text(2, 3, "Type the item and how many, e.g.", colors.lightGray)
      text(2, 4, "  iron ingot 32", colors.white)
      text(2, 5, "If there isn't enough it crafts the rest.", colors.lightGray)
      text(2, 6, "Enter on an empty line = back.", colors.lightGray)
      T.setCursorPos(2, 8)
      T.setTextColor(colors.yellow)
      T.setBackgroundColor(colors.black)
      write("> ")
      T.setTextColor(colors.white)
      local line = read()
      if not line or not line:find("%S") then return end
      local words = {}
      for wd in line:gmatch("%S+") do words[#words + 1] = wd end
      local n = tonumber(words[#words])
      if n and #words > 1 then table.remove(words) else n = nil end
      order(table.concat(words, " "), n)
    end

    local function drawHome()
      clear()
      titleBar("ORDER")
      if not stockOk then text(2, 2, ("Couldn't get the stock list (turtle busy? old version?)"):sub(1, W - 2), colors.red)
      elseif turtleOld then text(2, 2, ("Old turtle version: copy the new file onto it, reboot it"):sub(1, W - 2), colors.red)
      elseif cutoff > 0 then text(2, 2, (cutoff .. " chests can't be reached: their items are missing. Type resync"):sub(1, W - 2), colors.orange) end
      local tiles = {}
      local nf = #itemsIn("frequent")
      tiles[1] = { icon = "Frequent", name = "Frequent", color = colors.yellow, empty = nf == 0,
        sub = nf > 0 and (nf .. " items") or "nothing yet", action = { "cat", "frequent" } }
      for i, c in ipairs(CATS) do
        local n = #itemsIn(i)
        tiles[#tiles + 1] = { icon = c.name, name = TILE[c.name] or c.name, color = c.color, empty = n == 0,
          sub = n .. (n == 1 and " item" or " items"), action = { "cat", i } }
      end
      local all = #itemsIn("all")
      tiles[#tiles + 1] = { icon = "All items", name = "All items", color = colors.white, empty = all == 0,
        sub = all .. " items", action = { "cat", "all" } }
      drawTiles(tiles)
      if not canCraft then text(2, H - 1, ("No crafting table: only what's in storage."):sub(1, W - 2), colors.gray) end
      if onMonitor then
        button(2, H, 9, 1, "Refresh", colors.lightGray, colors.black, "refresh")
        text(12, H, (W >= 45 and "Type commands on the computer" or "type on the computer"):sub(1, W - 12), colors.gray)
      else
        button(2, H, 18, 1, "Type it myself", colors.yellow, colors.black, "type")
        button(21, H, 9, 1, "Refresh", colors.lightGray, colors.black, "refresh")
        button(W - 6, H, 6, 1, "Quit", colors.red, colors.white, "quit")
      end
    end

    local function drawCat()
      clear()
      local title = cat == "all" and "All items" or cat == "frequent" and "Frequent" or CATS[cat].name
      titleBar(title, "back")
      local list = itemsIn(cat)
      local cols = W >= 46 and 2 or 1
      local cw = math.floor((W - 1 - (cols - 1)) / cols)
      local rows = H - 4
      local per = rows * cols
      local pages = math.max(1, math.ceil(#list / per))
      if page > pages then page = pages end
      if #list == 0 then text(2, 3, "Nothing here yet.", colors.lightGray) end
      for i = 1, per do
        local it = list[(page - 1) * per + i]
        if not it then break end
        local col = math.floor((i - 1) / rows)
        local x = 2 + col * (cw + 1)
        local y = 3 + (i - 1) % rows
        -- right side: how many in storage (yellow) and how many more it can craft (purple)
        local have = it.n > 0 and num(it.n) or ""
        local craft = it.can > 0 and ("+" .. num(it.can)) or ""
        local rw = #have + (#craft > 0 and #craft + 1 or 0)
        local name = pretty(it.name):sub(1, cw - rw - 4)
        local bg = (i % 2 == 0) and colors.gray or colors.black
        local ci = catOf(it.name)
        text(x, y, " ", colors.white, CATS[ci] and CATS[ci].color or colors.white)
        local left = " " .. name
        text(x + 1, y, left .. (" "):rep(cw - 1 - #left), it.n > 0 and colors.white or colors.lightGray, bg)
        local rx = x + cw - rw - 1
        if #have > 0 then text(rx, y, have, colors.yellow, bg) rx = rx + #have + 1 end
        if #craft > 0 then text(rx, y, craft, colors.magenta, bg) end
        buttons[#buttons + 1] = { x1 = x, y1 = y, x2 = x + cw - 1, y2 = y, action = { "item", it } }
      end
      if pages > 1 then
        button(2, H, 5, 1, "<", colors.lightGray, colors.black, "prev")
        text(8, H, page .. "/" .. pages, colors.white)
        button(14, H, 5, 1, ">", colors.lightGray, colors.black, "next")
      end
      if canCraft then
        text(2, H - 1, (W >= 45 and "yellow = in storage, purple +N = can craft" or "yellow=stored  purple +N=craftable"):sub(1, W - 2), colors.gray)
      end
      if onMonitor then
        text(W - 20, H, "not listed? type it", colors.gray)
      else
        button(W - 22, H, 22, 1, "Not listed? Type it", colors.yellow, colors.black, "type")
      end
    end

    local function drawAmount()
      clear()
      titleBar(pretty(item.name), "back")
      local have, can = item.n, item.can
      local ci = catOf(item.name)
      icon(2, 3, ICONS[CATS[ci] and CATS[ci].name or "Other"] or ICONS.Other, colors.black)
      text(6, 3, pretty(item.name), colors.white)
      text(6, 4, "In storage: " .. num(have), colors.yellow)
      if can > 0 then text(6 + #("In storage: " .. num(have)) + 3, 4, "can craft +" .. num(can), colors.magenta) end
      local q = can > 0 and (W >= 45 and "How many? Not enough stored: it crafts the rest." or "How many? Short: it crafts the rest.")
        or "How many to the pickup chest?"
      text(2, 6, q:sub(1, W - 2), colors.lightGray)
      local total = have + can
      local x, y = 2, 8
      for _, a in ipairs({ 1, 4, 8, 16, 32, 64 }) do
        if x + 6 > W then x, y = 2, y + 2 end
        local bg = a <= have and colors.lime or a <= total and colors.magenta or colors.lightGray
        button(x, y, 6, 1, tostring(a), bg, colors.black, { "order", a })
        x = x + 7
      end
      y = y + 2
      x = 2
      if have > 0 then
        button(x, y, 16, 1, "All stored (" .. num(have) .. ")", colors.orange, colors.black, { "order", have })
        x = x + 17
      end
      if can > 0 then
        button(x, y, 16, 1, "Max (" .. num(total) .. ")", colors.magenta, colors.black, { "order", total })
      end
      if onMonitor then
        -- no keyboard here: pick any amount with the arrows
        y = y + 2
        local ok = (custom >= 1)
        button(2, y, 5, 1, "-16", colors.lightGray, colors.black, { "step", -16 })
        button(8, y, 4, 1, "-1", colors.lightGray, colors.black, { "step", -1 })
        local c = num(custom)
        text(13, y, (" "):rep(6), colors.white)
        text(13 + math.floor((6 - #c) / 2), y, c, colors.white)
        button(20, y, 4, 1, "+1", colors.lightGray, colors.black, { "step", 1 })
        button(25, y, 5, 1, "+16", colors.lightGray, colors.black, { "step", 16 })
        button(2, y + 2, 16, 1, "Order " .. c, ok and (custom <= have and colors.lime or colors.magenta) or colors.gray,
          colors.black, { "order", custom })
      else
        button(2, y + 2, 18, 1, "Other amount...", colors.yellow, colors.black, "custom")
      end
      text(2, H, (W >= 45 and "green = from storage, purple = crafts some" or "green=stored  purple=crafts some"):sub(1, W - 2), colors.gray)
    end

    local function drawMessage()
      clear()
      titleBar("Storage turtle")
      local bw2 = W - 4
      -- wrap long lines to the box
      local lines = {}
      for _, l in ipairs(message) do
        local rest = tostring(l)
        if rest == "" then lines[#lines + 1] = "" end
        while #rest > 0 do
          local cut = bw2 - 4
          if #rest > cut then
            local sp = rest:sub(1, cut):match(".*() ")
            if sp and sp > cut / 2 then cut = sp end
          end
          lines[#lines + 1] = rest:sub(1, cut):gsub("%s+$", "")
          rest = rest:sub(cut + 1):gsub("^%s+", "")
        end
      end
      while #lines > H - 8 do table.remove(lines) end
      local bh2 = #lines + 4
      for yy = 3, 3 + bh2 - 1 do text(3, yy, (" "):rep(bw2), colors.white, colors.gray) end
      for i, l in ipairs(lines) do text(5, 4 + i, l, colors.white, colors.gray) end
      button(math.floor(W / 2) - 4, 3 + bh2 + 1, 10, 1, "OK", colors.lime, colors.black, "ok")
    end

    refresh()
    while true do
      if message then drawMessage()
      elseif screen == "home" then drawHome()
      elseif screen == "cat" then drawCat()
      elseif screen == "amount" then drawAmount() end
      local a = waitClick()
      if a == "tick" then
        refresh() -- status and counts every few seconds
        if screen == "amount" then -- keep the numbers of the open item up to date
          for _, e in ipairs(entries()) do if e.name == item.name then item = e end end
        end
      elseif message then
        if a == "ok" or a == "back" then message = nil refresh() end
      elseif a == "quit" then
        T.setBackgroundColor(colors.black) T.clear() T.setCursorPos(1, 1)
        return
      elseif a == "refresh" then refresh()
      elseif a == "type" then typeIt()
      elseif a == "back" then
        if screen == "amount" then screen = "cat" elseif screen == "cat" then screen = "home" end
      elseif a == "prev" then page = math.max(1, page - 1)
      elseif a == "next" then page = page + 1
      elseif type(a) == "table" and a[1] == "cat" then screen, cat, page = "cat", a[2], 1
      elseif type(a) == "table" and a[1] == "item" then screen, item, custom = "amount", a[2], 1
      elseif type(a) == "table" and a[1] == "step" then
        custom = math.max(1, custom + a[2])
      elseif type(a) == "table" and a[1] == "order" then
        order(item.name, a[2])
        screen = "cat"
      elseif a == "custom" then
        text(2, H - 1, "How many? ", colors.yellow)
        T.setTextColor(colors.white)
        local n = tonumber(read())
        if n and n > 0 then
          order(item.name, math.floor(n))
          screen = "cat"
        end
      end
    end
  end
  -- Typing commands (on the computer while the monitor shows the order screen)
  local function textPrompt()
    print("Type commands, e.g.:")
    print(" get iron ingot 32   order torch 16   craft chest 2")
    print(" find coal   list   recipes   status   build")
    print(" pause   learn   resume   blocked   resync   help")
    print("quit = stop")
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
        if n and #words == 1 then n = nil end
        local text = table.concat(words, " ", 2, n and #words - 1 or #words)
        local reply = ask({ cmd = words[1]:lower(), text = text, n = n })
        if reply == nil then print("No answer (out of range?)")
        elseif type(reply) == "table" then for _, l in ipairs(reply) do print(l) end
        else print(tostring(reply)) end
      end
    end
  end

  local mon = peripheral.find("monitor", function(_, m) return m.isColor() end)
  if mon and args[2] ~= "text" then
    -- Advanced monitor: order screen there (tap it), commands typed here
    mon.setTextScale(0.5)
    term.clear()
    term.setCursorPos(1, 1)
    print("Order screen is on the monitor (" .. peripheral.getName(mon) .. ").")
    parallel.waitForAny(function() gui(mon, true) end, textPrompt)
  elseif term.isColor() and args[2] ~= "text" then
    gui(term.current(), false) -- advanced computer: buttons here (click with the mouse)
  else
    textPrompt()
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
  local LAST_FILE = "board.last"
  local lastIn = loadTable(LAST_FILE) or {} -- [item] = { t = ms, d = how many came in }
  -- Valuable items: always near the top
  local VALUE = { netherite_ingot = 100, netherite_block = 100, netherite_scrap = 90, ancient_debris = 85,
    diamond = 80, diamond_block = 82, emerald = 70, emerald_block = 72, gold_ingot = 50, gold_block = 52,
    raw_gold = 45, iron_ingot = 40, iron_block = 42, raw_iron = 35, lapis_lazuli = 25, redstone = 25, quartz = 22,
    amethyst_shard = 20, copper_ingot = 15, ender_pearl = 30, blaze_rod = 30, golden_apple = 60,
    enchanted_golden_apple = 100, totem_of_undying = 100, nether_star = 100, elytra = 100 }
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
    -- Rows: TOP (valuable + most ordered) stays on top; below it "recently added" and
    -- "most in stock" take turns every 10 seconds
    local ordered = data.ordered or {}
    -- Most valuable and most ordered take turns, so both always get a place on top
    local byValue, byOrders = {}, {}
    for _, it in ipairs(items) do
      local v = VALUE[it.name:match(":(.+)$") or it.name] or 0
      local u = ordered[it.name] or 0
      if v > 0 then byValue[#byValue + 1] = { it = it, k = v } end
      if u > 0 then byOrders[#byOrders + 1] = { it = it, k = u } end
    end
    local function desc(a, b) if a.k ~= b.k then return a.k > b.k end return a.it.name < b.it.name end
    table.sort(byValue, desc)
    table.sort(byOrders, desc)
    local cands, seen = {}, {}
    for i = 1, math.max(#byValue, #byOrders) do
      for _, l in ipairs({ byValue, byOrders }) do
        local e = l[i]
        if e and not seen[e.it.name] then seen[e.it.name] = true cands[#cands + 1] = e end
      end
    end

    local ncols = math.max(1, math.floor((W + 2) / 44))
    local ew = math.floor((W - (ncols - 1) * 2) / ncols)
    local showChg = ew >= 24
    local showLast = ew >= 36
    local showPct = ew >= 46
    local nw = ew - 8 - (showChg and 9 or 0) - (showPct and 8 or 0) - (showLast and 10 or 0)
    if H >= 5 then
      for c = 1, ncols do
        local hs = ljust("ITEM", nw) .. rjust("QTY", 8) .. (showChg and rjust("CHG 1H", 9) or "")
          .. (showPct and rjust("%", 8) or "") .. (showLast and rjust("LAST IN", 10) or "")
        put(1 + (c - 1) * (ew + 2), y, hs, C.dim)
      end
      y = y + 1
    end
    local top = y
    local rowsPer = H - top -- last line = ticker
    local slots = rowsPer * ncols
    local nTop = math.min(#cands, math.max(3, math.floor(slots / 3)))
    local rowsList, onTop = {}, {}
    if nTop > 0 then
      rowsList[#rowsList + 1] = { head = "\4 TOP: valuable & most ordered" }
      for i = 1, nTop do rowsList[#rowsList + 1] = { it = cands[i].it } onTop[cands[i].it.name] = true end
    end
    local recent = math.floor(now() / 10000) % 2 == 0
    local rest = {}
    for _, it in ipairs(items) do if not onTop[it.name] then rest[#rest + 1] = it end end
    if recent then
      table.sort(rest, function(a, b)
        local ta, tb = lastIn[a.name] and lastIn[a.name].t or 0, lastIn[b.name] and lastIn[b.name].t or 0
        if ta ~= tb then return ta > tb end
        return a.n > b.n
      end)
    end
    rowsList[#rowsList + 1] = { head = recent and "RECENTLY ADDED" or "MOST IN STOCK" }
    for _, it in ipairs(rest) do rowsList[#rowsList + 1] = { it = it } end

    local function ago(name)
      local l = lastIn[name]
      if not l then return "-" end
      local sec = (now() - l.t) / 1000
      if sec < 60 then return "now" end
      if sec < 3600 then return math.floor(sec / 60) .. "m ago" end
      if sec < 86400 then return math.floor(sec / 3600) .. "h ago" end
      return math.floor(sec / 86400) .. "d ago"
    end
    for i = 1, math.min(#rowsList, slots) do
      local r = rowsList[i]
      local col = math.floor((i - 1) / rowsPer)
      local x = 1 + col * (ew + 2)
      local ry = top + (i - 1) % rowsPer
      if r.head then
        put(x, ry, ljust(" " .. r.head, ew), C.titleText, C.title)
      else
        local it = r.it
        local chg, pct = change(it.name, it.n)
        local dc = chg > 0 and C.up or chg < 0 and C.down or C.flat
        put(x, ry, ljust(pretty(it.name), nw - 1), onTop[it.name] and C.ticker or C.text)
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
        if showLast then put(cx, ry, rjust(ago(it.name), 10), C.label) end
      end
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
      local changedIn = false
      if data then
        for name, n in pairs(b.totals) do
          local old = data.totals[name] or 0
          if n ~= old then flash[name] = { now() + 4000, n > old and 1 or -1 } end
          if n > old then lastIn[name] = { t = now(), d = n - old } changedIn = true end
        end
        if changedIn then saveTable(LAST_FILE, lastIn) end
      end
      data, lastMsg, boardTurtle = b, now(), a
      sample()
    elseif ev == "timer" and a == frame then
      tick = tick + 1
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
local cfg = loadTable(FILES.cfg) or {}
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
if cfg.charcoal == nil then cfg.charcoal = true end -- logs -> charcoal (normal furnaces only)
cfg.keepLogs = cfg.keepLogs or 32     -- logs of each kind that stay logs (for planks, chests)
cfg.fuels = cfg.fuels or { "minecraft:charcoal", "minecraft:coal", "minecraft:coal_block", "minecraft:dried_kelp_block" }
saveTable(FILES.cfg, cfg)

local stats = loadTable(FILES.stats) or {}
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
    local h = fs.open(FILES.log, "a")
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
local FURNACE_ITEMS = { ["minecraft:furnace"] = "furnace", ["minecraft:blast_furnace"] = "blast",
  ["minecraft:smoker"] = "smoker" }
-- Raw food that gets cooked (furnaces and smokers)
local RAW_FOOD = {}
for _, n in ipairs({ "beef", "porkchop", "chicken", "mutton", "rabbit", "cod", "salmon", "potato", "kelp" }) do
  RAW_FOOD["minecraft:" .. n] = true
end

local function short(name) return name:match(":(.+)$") or name end
local function listHas(l, x) for _, v in ipairs(l) do if v == x then return true end end return false end

local function smeltKind(name)
  if listHas(cfg.noSmelt, name) then return nil end
  local n = short(name)
  if not n:find("_block$") and (n:find("^raw_") or n:find("_ore$") or n == "ancient_debris") then return "ore" end
  if RAW_FOOD[name] and cfg.cook ~= false then return "food" end
  -- Overworld logs and wood, stripped too (nether stems don't make charcoal)
  if cfg.charcoal and (n:find("_log$") or n:find("_wood$")) then return "log" end
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
  if smeltKind(name) == "food" then return 12 end
  if smeltKind(name) == "extra" then return 5 end
  if smeltKind(name) == "log" then return 3 end -- after everything else, unless out of fuel
  return 20 -- other (modded) ores: tin, silver, zinc, ...
end
local function byPriority(a, b)
  local pa, pb = smeltPriority(a.name), smeltPriority(b.name)
  if pa ~= pb then return pa > pb end
  return a.name < b.name
end

-- How many of a stored item may go to the furnaces (logs: all but the ones it keeps)
local function smeltable(name, count)
  if not smeltKind(name) then return 0 end
  if smeltKind(name) == "log" then return math.max(0, count - cfg.keepLogs) end
  return count
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
local map = loadTable(FILES.map)
local idx = loadTable(FILES.idx) or {} -- [cell] = { kind=, acc=, dir=, size=, items= }
local pos = loadTable(FILES.pos) or { x = 0, y = 0, z = 0, h = 0 }
local mapVersion = 0
local function saveMap() mapVersion = mapVersion + 1 saveTable(FILES.map, map) end
local function saveIdx() saveTable(FILES.idx, idx) end
local function savePos() saveTable(FILES.pos, pos) end
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
  -- Also the start spot: it may have been carried back there by hand
  if map.home and not listHas(cands, map.home) then cands[#cands + 1] = map.home end
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
  for _, m in ipairs(matches) do if not pick and m.k == map.home and m.h == 0 then pick = m end end
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
-- Another free spot next to 'cell' the turtle can get to (a road spot if possible):
-- used when the normal spot above/below a chest is blocked, e.g. by a cable
local planned -- set of all plan spots (chests and furnaces)
local function isPlanned(k)
  if not planned then
    planned = {}
    for _, s in ipairs(map.slots) do planned[s.cell] = true end
    for _, st in ipairs(map.stations or {}) do planned[st.floor.cell], planned[st.top.cell] = true, true end
  end
  return planned[k]
end

local function sideAccess(cell, notPlanned)
  local r = reachable()
  local best, bestRoad
  for _, d in ipairs(ALL_DIRS) do
    local n = step(cell, d)
    if free(n) and r[n] and not (notPlanned and isPlanned(n)) then
      local _, y = unkey(n)
      local road = (y - (map.floorY or 0)) % 3 == 1
      if not best or (road and not bestRoad) then best, bestRoad = n, road end
    end
  end
  if best then return best, dirBetween(best, cell) end
end

-- How a plan spot can be reached: its normal spot, or else from the side
local function accessFor(s)
  if free(s.acc) and reachable()[s.acc] then return s.acc, s.dir end
  -- only from a spot that isn't meant for a chest itself (else nothing is won)
  return sideAccess(s.cell, true)
end

-- A spot where placing just failed (someone standing there?) waits a minute
local function waiting(cell)
  local f = map.placeFails and map.placeFails[cell]
  return type(f) == "table" and f.t and os.epoch("utc") - f.t < 60000
end

local function freeSlot(filter)
  for _, s in ipairs(map.slots) do
    if not idx[s.cell] and not (map.bad and map.bad[s.cell]) and free(s.cell) and not waiting(s.cell)
      and (not filter or filter(s)) then
      local acc, dir = accessFor(s)
      if acc and safeToFill(s.cell) then return { cell = s.cell, acc = acc, dir = dir } end
    end
  end
end

-- Storage chests whose spot got blocked: open them from another side from now on
local function fixAccess()
  local changed = false
  for k, e in pairs(idx) do
    if e.kind == "store" and not e.merged and not canReach(e) then
      local acc, dir = sideAccess(k)
      if acc then
        e.acc, e.dir = acc, dir
        changed = true
        log("Chest at " .. k .. " is opened from the side now")
      end
    end
  end
  if changed then saveIdx() end
end
-- Spots it can still build on (free and reachable)
local function usableSpots()
  local n = 0
  for _, sl in ipairs(map.slots) do
    if not idx[sl.cell] and not (map.bad and map.bad[sl.cell]) and free(sl.cell) and accessFor(sl) then n = n + 1 end
  end
  return n
end

local function slotAt(cell)
  for _, s in ipairs(map.slots) do if s.cell == cell then return s end end
end

-- Orders go first: called between steps of longer jobs (filled in further down)
local urgent = function() end

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
  if d and d.name == "minecraft:chest" and side ~= "front" then
    -- Chests in a row all face the same way (along the row), the next row the other
    -- way: then no two of them join into a double chest
    local _, _, z = unkey(s.cell)
    turnTo(z % 2 == 0 and 3 or 1)
  end
  turtle.select(tslot)
  local ok = PLACE[side]()
  for _ = 1, 3 do -- someone standing there? wait a moment and try again
    if ok or inspectDir(s.dir) then break end
    sleep(1)
    turtle.select(tslot)
    ok = PLACE[side]()
  end
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
      -- nothing visible there: try again next round, give up after 5 rounds in a row
      map.placeFails = map.placeFails or {}
      local f = map.placeFails[s.cell] or { n = 0 }
      if type(f) ~= "table" then f = { n = f } end
      f.n, f.t = f.n + 1, os.epoch("utc")
      map.placeFails[s.cell] = f
      if f.n >= 5 then
        log("Can't place at " .. s.cell .. " (5 tries), skipping it", true)
        markBad(s.cell)
      else
        log("Couldn't place at " .. s.cell .. ", trying again later")
        saveMap()
      end
    end
    return nil
  end
  map.cells[s.cell] = d and d.name or "p"
  if map.placeFails then map.placeFails[s.cell] = nil end
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
  placeAt(s, tslot, "store") -- if it fails, that spot waits and the next one is tried
  return true
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
      and not waiting(st.floor.cell) and not waiting(st.top.cell)
      and safeToFill(st.floor.cell) and (idx[st.top.cell] or safeToFill(st.top.cell)) then return st end
  end
end

local function buildFurnaces()
  while #furnaces() < cfg.maxFurnaces do
    urgent()
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
    f.smoker = FURNACE_ITEMS[fname] == "smoker"
    f.buffer = st.top.cell
    status.note = nil
    saveIdx()
    log("Built a " .. (f.blast and "blast furnace" or f.smoker and "smoker" or "furnace"))
  end
end

-- Every chest/barrel it has (or has in storage) gets built right away
local function buildChests()
  while freeSlot() do
    urgent()
    -- Keep a chest back for every spot that waits for a retry, so no hole stays behind
    local waitingSpots, have = 0, carriedCount(function(n) return CHEST_ITEMS[n] ~= nil end)
    for _, sl in ipairs(map.slots) do
      if not idx[sl.cell] and waiting(sl.cell) and not (map.bad and map.bad[sl.cell]) then waitingSpots = waitingSpots + 1 end
    end
    local t = totals()
    for name in pairs(CHEST_ITEMS) do have = have + (t[name] or 0) end
    if have <= waitingSpots then break end
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
-- Top up partial stacks inside one chest: a dropped stack lands in the first empty
-- slot and taking shuffles slot 1 around, both of which leave the same item split
-- over several part stacks. Moves later part stacks into earlier ones.
local function mergeStacks(side)
  local ok, l = pcall(peripheral.call, side, "list")
  if not ok or not l then return end
  local slots = {}
  for s in pairs(l) do slots[#slots + 1] = s end
  table.sort(slots)
  local open = {} -- [name|nbt] = slots with room, lowest first
  for _, s in ipairs(slots) do
    local it = l[s]
    local id = it.name .. "|" .. (it.nbt or "")
    local max = stackOf(it.name)
    local targets = open[id] or {}
    open[id] = targets
    while it.count > 0 and #targets > 0 do
      local to = targets[1]
      local ok2, m = pcall(peripheral.call, side, "pushItems", side, s, it.count, to)
      m = ok2 and m or 0
      it.count = it.count - m
      l[to].count = l[to].count + m
      if m == 0 or l[to].count >= max then table.remove(targets, 1) end
      if not ok2 then return end
    end
    if it.count > 0 and it.count < max then targets[#targets + 1] = s end
  end
end

local function takeFrom(k, side, slot, n, into)
  local e = idx[k]
  local l = peripheral.call(side, "list")
  if not l[slot] then return 0 end
  local t = into or emptySlot()
  if not t then return 0 end
  local function spareSlot() -- an empty slot that isn't 'into'
    for s = 16, 1, -1 do if s ~= into and turtle.getItemCount(s) == 0 then return s end end
  end
  local parked
  if slot ~= 1 then
    if l[1] then
      local size = peripheral.call(side, "size")
      local spare
      for s = size, 2, -1 do if not l[s] then spare = s break end end
      if spare then
        peripheral.call(side, "pushItems", side, 1, 64, spare)
      else -- chest full: hold slot 1 in the turtle for a moment
        parked = spareSlot()
        if not parked then return 0 end
        turtle.select(parked)
        SUCK[side]()
        if not into then t = emptySlot() end
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
  mergeStacks(side)
  refresh(k, side)
  return got
end

-- Take up to n of an item from storage. Returns how many it got.
function fetch(name, n, maxSlotsUsed, into) -- into: put it in this turtle slot
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
        if not into and (freeSlots() == 0 or (maxSlotsUsed and startFree - freeSlots() >= maxSlotsUsed)) then return got end
        got = got + takeFrom(k, side, slot, math.min(n - got, it.count), into)
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

local function storeAll(force, onlySlot) -- force: also what it normally keeps on board; onlySlot(s): just those slots
  for _ = 1, 10 do
    local kept = {}
    local todo = {}
    for _, c in ipairs(carried()) do
      if (not onlySlot or onlySlot(c.slot)) and (force or not keepOnBoard(c, kept)) then todo[#todo + 1] = c end
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
      mergeStacks(side)
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

local refuelCarried, refuelSelf
do
local function fuelRoom()
  local lim = turtle.getFuelLimit and turtle.getFuelLimit() or 20000
  if lim == "unlimited" then return 0 end
  return lim - fuelLeft()
end

-- Fuel in its own slots (also what you put straight into the turtle): no moving needed
function refuelCarried()
  -- Lava buckets are always burnt when they fit (1000 each), never stored; the empty
  -- buckets go to storage
  for _, c in ipairs(carried(function(n) return n == "minecraft:lava_bucket" end)) do
    if fuelRoom() >= 1000 then
      turtle.select(c.slot)
      turtle.refuel()
    end
  end
  turtle.select(1)
  if fuelLeft() >= cfg.minFuel then return end
  for _, c in ipairs(carried(function(n) return FUEL_VALUE[n] ~= nil end)) do
    turtle.select(c.slot)
    while fuelLeft() < cfg.minFuel * 4 and turtle.getItemCount(c.slot) > 0 do
      if not turtle.refuel(1) then break end
    end
  end
  turtle.select(1)
end

function refuelSelf()
  refuelCarried()
  if fuelLeft() >= cfg.minFuel then return end
  -- Lava buckets in storage first (put there by older versions), then coal and the like
  if (totals()["minecraft:lava_bucket"] or 0) > 0 and fuelRoom() >= 1000 and freeSlots() > 1 then
    fetch("minecraft:lava_bucket", math.min(totals()["minecraft:lava_bucket"], math.floor(fuelRoom() / 1000), freeSlots() - 1))
    refuelCarried()
  end
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

-- Blast furnace: ores only. Smoker: food only. Furnace: everything.
local function smeltableHere(e, name)
  local k = smeltKind(name)
  if k == "ore" then return not e.smoker end
  if k == "food" then return not e.blast end
  return (k == "extra" or k == "log") and not e.blast and not e.smoker
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

local function serviceFurnace(k, share, extra) -- extra: also put this item in (for an order)
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
  local list = carried(function(n) return n == extra or smeltableHere(e, n) end)
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
  local div = (e.blast or e.smoker) and 2 or 1 -- these burn fuel twice as fast
  local function value(n) return FUEL_VALUE[n] or (smeltKind(n) == "log" and 1.5) end
  local have = 0
  if st[2] then have = value(st[2].name) and value(st[2].name) / div * st[2].count or math.huge end
  if need > have then
    local fuels = st[2] and { st[2].name } or { table.unpack(cfg.fuels) }
    if not st[2] then
      -- No coal or charcoal on board: a few logs as fuel get the charcoal going
      for _, c in ipairs(carried(function(n) return smeltKind(n) == "log" end)) do
        if not listHas(fuels, c.name) then fuels[#fuels + 1] = c.name end
      end
    end
    local logsBurnt = 0
    for _, f in ipairs(fuels) do
      if need > have then
        local per = (value(f) or 8) / div
        for _, c in ipairs(carried(function(n) return n == f end)) do
          local want = math.min(c.count, math.ceil((need - have) / per))
          if FUEL_VALUE[f] == nil then want = math.min(want, 4 - logsBurnt) logsBurnt = logsBurnt + want end
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
  for name, c in pairs(totals()) do n = n + smeltable(name, c) end
  return n
end

-- Take fuel along for 'items' to smelt in 'nf' furnaces. Returns how much it carries.
local function takeFuel(items, nf)
  local fuelCarried = carriedCount(function(n) return FUEL_VALUE[n] ~= nil and n ~= "minecraft:lava_bucket" end)
  local fuelWanted = math.ceil(items / 8) + nf
  if fuelCarried < fuelWanted then
    local t = totals()
    for _, f in ipairs(cfg.fuels) do
      if fuelCarried < fuelWanted and t[f] and freeSlots() > 3 then
        fuelCarried = fuelCarried + fetch(f, fuelWanted - fuelCarried, 1)
      end
    end
  end
  return fuelCarried
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
  -- No fuel anywhere (coal, charcoal, ... or logs to start with): don't walk the furnaces
  -- for nothing; only go to pick up results or while one still has fuel in it
  local t = totals()
  local fuel = carriedCount(function(n) return FUEL_VALUE[n] ~= nil and n ~= "minecraft:lava_bucket" or smeltKind(n) == "log" end)
  for _, f in ipairs(cfg.fuels) do fuel = fuel + (t[f] or 0) end
  for name, c in pairs(t) do if smeltKind(name) == "log" then fuel = fuel + smeltable(name, c) end end
  if fuel == 0 then
    local worth = false
    for _, k in ipairs(fl) do
      local st = idx[k].state or {}
      if st[2] or st[3] then worth = true end
    end
    status.noFuel = carriedSmelt + stored > 0
    if not worth then return end
    -- carry nothing new along: just collect
    if os.clock() - lastPass < 30 then return end
    carriedSmelt, stored = 0, 0
  end
  if carriedSmelt == 0 and (stored == 0 or room < 8) and not (busy and os.clock() - lastPass > 30) then return end
  lastPass = os.clock()
  setState("Smelting")
  -- Take ores from storage for the room there is (keeps 4 slots free for results)
  if carriedSmelt < room and stored > 0 then
    local wanted = {}
    local t = totals()
    local noFuel = true
    for _, f in ipairs(cfg.fuels) do if t[f] then noFuel = false end end
    for name, c in pairs(t) do
      local n = smeltable(name, c)
      if n > 0 then wanted[#wanted + 1] = { name = name, count = n } end
    end
    table.sort(wanted, function(a, b)
      -- No coal or charcoal left: logs first, their charcoal fuels the rest
      if noFuel and (smeltKind(a.name) == "log") ~= (smeltKind(b.name) == "log") then
        return smeltKind(a.name) == "log"
      end
      return byPriority(a, b) -- gold and iron before copper
    end)
    for _, w in ipairs(wanted) do
      if carriedSmelt < room and freeSlots() > 4 then
        local got = fetch(w.name, math.min(w.count, room - carriedSmelt), freeSlots() - 4)
        carriedSmelt = carriedSmelt + got
      end
    end
  end
  local fuelCarried = takeFuel(carriedSmelt, #fl)
  local logs = carriedCount(function(n) return smeltKind(n) == "log" end)
  if fuel > 0 then status.noFuel = fuelCarried == 0 and logs == 0 and carriedSmelt > 0 end
  local share = math.max(8, math.ceil(carriedSmelt / #fl))
  -- Blast furnaces and smokers first (twice as fast for ores / food), then furnaces
  local function rank(e) return (e.blast or e.smoker) and 0 or 1 end
  table.sort(fl, function(a, b)
    if rank(idx[a]) ~= rank(idx[b]) then return rank(idx[a]) < rank(idx[b]) end
    return a < b
  end)
  for _, k in ipairs(fl) do
    urgent()
    serviceFurnace(k, share)
  end
end

-- Smelt 'count' of 'input' right now (for an order, e.g. sand for glass): put it in the
-- furnaces that take it and wait for the results. Returns how many 'out' it got.
local function smeltNow(out, input, count)
  local function have() return (totals()[out] or 0) + carriedCount(function(n) return n == out end) end
  local function carriedIn() return carriedCount(function(n) return n == input end) end
  local kind = smeltKind(input)
  local fl = {}
  for _, k in ipairs(furnaces()) do
    local e = idx[k]
    -- blast furnace: ores only, smoker: food only, furnace: everything
    if (e.blast and kind == "ore") or (e.smoker and kind == "food") or not (e.blast or e.smoker) then fl[#fl + 1] = k end
  end
  if #fl == 0 then return 0, "a furnace" end
  local start = have()
  local lastGot, quiet, left = start, 0, count
  setState("Smelting " .. pretty(out))
  while have() < start + count and quiet < 24 do
    if left > carriedIn() and freeSlots() > 4 then fetch(input, left - carriedIn(), freeSlots() - 4) end
    if carriedIn() == 0 and (totals()[input] or 0) == 0 then left = 0 end -- none left to put in
    if takeFuel(carriedIn(), #fl) == 0 then status.noFuel = true end
    local share = math.max(8, math.ceil(left / #fl))
    local busy = false
    for _, k in ipairs(fl) do
      local st = idx[k].state or {}
      local mine = (st[1] and st[1].name == input) or (st[3] and st[3].name == out)
      if mine or (left > 0 and carriedIn() > 0) then
        local before = carriedIn()
        serviceFurnace(k, share, input)
        left = math.max(0, left - (before - carriedIn()))
        st = idx[k].state or {}
        if (st[1] and st[1].name == input) or (st[3] and st[3].name == out) then busy = true end
      end
    end
    local got = have()
    if got >= start + count or (left == 0 and not busy) then break end
    if got > lastGot then lastGot, quiet = got, 0 else quiet = quiet + 1 end
    sleep(5)
  end
  storeAll(true)
  local got = have() - start
  return got, got < count and (quiet >= 24 and "fuel (the furnaces stopped)" or pretty(input)) or nil
end

---------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------
local paused = false
local requests = {}
local findRequest, busyFind = false, false
local resyncRequest = false

-- Count everything again: look at blocked spots once more, open cut-off chests from
-- another side if possible, and read every chest it can reach. Chests that are gone
-- (broken by hand) are forgotten, so the spot can be built on again.
local function resync()
  setState("Resync: blocked spots")
  for k in pairs(map.obstacles or {}) do
    local r = reachable()
    for _, d in ipairs(ALL_DIRS) do
      local n = step(k, d)
      if free(n) and r[n] then
        goTo(n)
        if not inspectDir(dirBetween(n, k)) then
          map.cells[k] = "a"
          map.obstacles[k] = nil
          saveMap()
          log("Spot " .. k .. " is free again")
        end
        break
      end
    end
  end
  fixAccess()
  setState("Resync: counting")
  local counted, gone, cut = 0, 0, 0
  local keys = {}
  for k, e in pairs(idx) do if e.kind == "store" or e.kind == "buffer" then keys[#keys + 1] = k end end
  table.sort(keys)
  for _, k in ipairs(keys) do
    urgent()
    local e = idx[k]
    if e and canReach(e) then
      -- something new in the way (a cable)? skip this chest, carry on with the rest
      local ok, res = pcall(function()
        local side = goToInv(e)
        if isInv(side) then refresh(k, side) return "counted" end
        return "gone"
      end)
      if not ok then
        cut = cut + 1
      elseif res == "counted" then
        counted = counted + 1
      else
        idx[k] = nil -- the chest isn't there anymore
        map.cells[k] = "a"
        saveMap()
        saveIdx()
        gone = gone + 1
      end
    elseif e then
      cut = cut + 1
    end
  end
  goHome()
  local msg = ("Resync done: %d chests counted"):format(counted)
  if gone > 0 then msg = msg .. (", %d gone"):format(gone) end
  if cut > 0 then msg = msg .. (", %d cut off (type blocked)"):format(cut) end
  log(msg)
  os.queueEvent("room_stock")
end

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

-- The pickup chest was moved (e.g. down into a hole)? Feel around where it was: look at
-- the blocks near the old spot (nearest and lowest first), take open spots into the map
-- so it can go into a hole, and use the first chest that isn't one of its own.
local function findOutput()
  local oldK
  for k, e in pairs(idx) do if e.kind == "output" then oldK = k end end
  if not oldK then return false, "No pickup chest known yet." end
  setState("Looking for the pickup chest")
  local ox, oy, oz = unkey(oldK)
  local function near(k)
    local x, y, z = unkey(k)
    return math.abs(x - ox) <= 2 and math.abs(z - oz) <= 2 and y >= oy - 3 and y <= oy + 2
  end
  local function score(k) -- closest to the spot just below the old one first
    local x, y, z = unkey(k)
    return math.abs(x - ox) + math.abs(z - oz) + math.abs(y - (oy - 1))
  end
  local checked, seen = {}, {}
  for _ = 1, 60 do
    local r = reachable()
    local best
    for n in pairs(r) do
      if near(n) then
        for _, d in ipairs(ALL_DIRS) do
          local c = step(n, d)
          local e = idx[c]
          if not checked[c] and not free(c) and near(c) and (not e or e.kind == "output") then
            local sc = score(c)
            if not best or sc < best.sc then best = { n = n, c = c, sc = sc } end
          end
        end
      end
    end
    if not best then break end
    checked[best.c] = true
    goTo(best.n)
    local dir = dirBetween(best.n, best.c)
    local side = face(dir)
    local isBlock, data = inspectDir(dir)
    if isBlock then
      seen[#seen + 1] = best.c .. "=" .. short(tostring(data.name))
      if isInv(side) and not tostring(data.name):find("furnace") and not tostring(data.name):find("smoker") then
        idx[oldK] = nil
        idx[best.c] = { kind = "output", acc = best.n, dir = dir }
        map.cells[best.c] = data.name
        if map.found then map.found[best.c] = data.name end
        saveMap()
        saveIdx()
        log("Pickup chest found at " .. best.c)
        return true, "Pickup chest found at " .. best.c .. " (it was at " .. oldK .. ")."
      end
      map.cells[best.c] = data.name
    else
      map.cells[best.c] = "a" -- open: the turtle may go in there and look further
      saveMap()
    end
  end
  saveMap()
  return false, "No chest found near " .. oldK .. " (checked " .. #seen .. " blocks). Put it within 2 blocks of where it was."
end

local function deliver(req)
  local out = outputEntry()
  if not out then log("No output chest", true) return end
  -- Still there? If not, look for it nearby first
  local okSide = pcall(function()
    local side = goToInv(out)
    if not isInv(side) then error("gone") end
  end)
  if not okSide then
    local found = findOutput()
    if not found then log("Pickup chest is gone: put it back or type pickup", true) return end
    out = outputEntry()
  end
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
      stats.requested = stats.requested or {}
      stats.requested[req.name] = (stats.requested[req.name] or 0) + m
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

---------------------------------------------------------------------------
-- Crafting (the turtle needs a crafting table: put one in the drop-off chest and it
-- equips it by itself)
---------------------------------------------------------------------------
local RECIPES_FILE = "room.recipes"
local learned = loadTable(RECIPES_FILE) or {}
local crafts = {} -- queue of { name =, n = }
local lastMissing

local function crafty() return peripheral.find("workbench") ~= nil end

-- Ingredient groups: "#planks" = any planks, ...
local GROUPS = {
  ["#planks"] = function(n) return n:find("_planks$") ~= nil end,
  ["#log"] = function(n) return (n:find("_log$") or n:find("_stem$")) ~= nil end,
  ["#coal"] = { "minecraft:coal", "minecraft:charcoal" },
  ["#sand"] = { "minecraft:sand", "minecraft:red_sand" },
  ["#burnlog"] = function(n) return (n:find("_log$") or n:find("_wood$")) ~= nil end, -- no nether stems
  ["#stone"] = { "minecraft:cobblestone", "minecraft:cobbled_deepslate", "minecraft:blackstone" },
}
local function fitsSpec(spec, name)
  if spec:sub(1, 1) ~= "#" then return spec == name end
  local g = GROUPS[spec]
  if type(g) == "function" then return g(name) end
  return listHas(g, name)
end
local function specLabel(spec)
  if spec:sub(1, 1) == "#" then return spec:sub(2) end
  return pretty(spec)
end

-- Turtle slots of the 3x3 grid:  1 2 3 / 5 6 7 / 9 10 11
local M = "minecraft:"
local function ring(x) return { [1] = x, [2] = x, [3] = x, [5] = x, [7] = x, [9] = x, [10] = x, [11] = x } end
local function nine(x) return { [1] = x, [2] = x, [3] = x, [5] = x, [6] = x, [7] = x, [9] = x, [10] = x, [11] = x } end
local BUILTIN
do
local S, I, D = M .. "stick", M .. "iron_ingot", M .. "diamond"
BUILTIN = {
  { out = M .. "stick", n = 4, grid = { [1] = "#planks", [5] = "#planks" } },
  { out = M .. "torch", n = 4, grid = { [1] = "#coal", [5] = S } },
  { out = M .. "crafting_table", n = 1, grid = { [1] = "#planks", [2] = "#planks", [5] = "#planks", [6] = "#planks" } },
  { out = M .. "chest", n = 1, grid = ring("#planks") },
  { out = M .. "furnace", n = 1, grid = ring("#stone") },
  { out = M .. "ladder", n = 3, grid = { [1] = S, [3] = S, [5] = S, [6] = S, [7] = S, [9] = S, [11] = S } },
  { out = M .. "bucket", n = 1, grid = { [1] = I, [3] = I, [6] = I } },
  { out = M .. "shears", n = 1, grid = { [2] = I, [5] = I } },
  { out = M .. "hopper", n = 1, grid = { [1] = I, [3] = I, [5] = I, [6] = M .. "chest", [7] = I, [10] = I } },
  { out = M .. "rail", n = 16, grid = { [1] = I, [3] = I, [5] = I, [6] = S, [7] = I, [9] = I, [11] = I } },
  { out = M .. "compass", n = 1, grid = { [2] = I, [5] = I, [6] = M .. "redstone", [7] = I, [10] = I } },
  { out = M .. "flint_and_steel", n = 1, grid = { [1] = I, [6] = M .. "flint" } },
  { out = M .. "arrow", n = 4, grid = { [2] = M .. "flint", [6] = S, [10] = M .. "feather" } },
  { out = M .. "bread", n = 1, grid = { [1] = M .. "wheat", [2] = M .. "wheat", [3] = M .. "wheat" } },
  { out = M .. "paper", n = 3, grid = { [1] = M .. "sugar_cane", [2] = M .. "sugar_cane", [3] = M .. "sugar_cane" } },
  { out = M .. "book", n = 1, grid = { [1] = M .. "paper", [2] = M .. "paper", [3] = M .. "paper", [5] = M .. "leather" } },
  { out = M .. "stone_bricks", n = 4, grid = { [1] = M .. "stone", [2] = M .. "stone", [5] = M .. "stone", [6] = M .. "stone" } },
  { out = M .. "glass_pane", n = 16, grid = { [1] = M .. "glass", [2] = M .. "glass", [3] = M .. "glass", [5] = M .. "glass", [6] = M .. "glass", [7] = M .. "glass" } },
}
for _, m in ipairs({ "iron", "diamond" }) do
  local x = m == "iron" and I or D
  BUILTIN[#BUILTIN + 1] = { out = M .. m .. "_pickaxe", n = 1, grid = { [1] = x, [2] = x, [3] = x, [6] = S, [10] = S } }
  BUILTIN[#BUILTIN + 1] = { out = M .. m .. "_axe", n = 1, grid = { [1] = x, [2] = x, [5] = x, [6] = S, [10] = S } }
  BUILTIN[#BUILTIN + 1] = { out = M .. m .. "_shovel", n = 1, grid = { [2] = x, [6] = S, [10] = S } }
  BUILTIN[#BUILTIN + 1] = { out = M .. m .. "_sword", n = 1, grid = { [2] = x, [6] = x, [10] = S } }
end
end
-- Storage blocks (9 -> 1) and back (1 -> 9)
for _, p in ipairs({ { "iron_block", "iron_ingot" }, { "gold_block", "gold_ingot" }, { "diamond_block", "diamond" },
  { "emerald_block", "emerald" }, { "lapis_block", "lapis_lazuli" }, { "redstone_block", "redstone" },
  { "coal_block", "coal" }, { "copper_block", "copper_ingot" }, { "raw_iron_block", "raw_iron" },
  { "raw_gold_block", "raw_gold" }, { "raw_copper_block", "raw_copper" } }) do
  BUILTIN[#BUILTIN + 1] = { out = M .. p[1], n = 1, grid = nine(M .. p[2]) }
  BUILTIN[#BUILTIN + 1] = { out = M .. p[2], n = 9, grid = { [1] = M .. p[1] } }
end
BUILTIN[#BUILTIN + 1] = { out = M .. "iron_ingot", n = 1, grid = nine(M .. "iron_nugget") }
BUILTIN[#BUILTIN + 1] = { out = M .. "gold_ingot", n = 1, grid = nine(M .. "gold_nugget") }
-- Furnace recipes (1 in, 1 out): ordered and there's none, it smelts them first
for _, p in ipairs({ { "glass", "#sand" }, { "stone", "cobblestone" }, { "smooth_stone", "stone" },
  { "deepslate", "cobbled_deepslate" }, { "cracked_stone_bricks", "stone_bricks" }, { "smooth_sandstone", "sandstone" },
  { "smooth_red_sandstone", "red_sandstone" }, { "smooth_quartz", "quartz_block" }, { "brick", "clay_ball" },
  { "terracotta", "clay" }, { "nether_brick", "netherrack" }, { "charcoal", "#burnlog" }, { "iron_ingot", "raw_iron" },
  { "gold_ingot", "raw_gold" }, { "copper_ingot", "raw_copper" }, { "netherite_scrap", "ancient_debris" },
  { "dried_kelp", "kelp" }, { "green_dye", "cactus" }, { "sponge", "wet_sponge" }, { "baked_potato", "potato" },
  { "cooked_beef", "beef" }, { "cooked_porkchop", "porkchop" }, { "cooked_chicken", "chicken" },
  { "cooked_mutton", "mutton" }, { "cooked_rabbit", "rabbit" }, { "cooked_cod", "cod" }, { "cooked_salmon", "salmon" } }) do
  local inp = p[2]:sub(1, 1) == "#" and p[2] or M .. p[2]
  BUILTIN[#BUILTIN + 1] = { out = M .. p[1], n = 1, grid = { [1] = inp }, smelt = true }
end

-- All recipes: learned ones first, then built in, then planks for every log in storage
local function allRecipes(stock)
  local l = {}
  for _, r in ipairs(learned) do l[#l + 1] = r end
  for _, r in ipairs(BUILTIN) do l[#l + 1] = r end
  for name in pairs(stock or totals()) do
    local base = name:match("^(.+)_log$") or name:match("^(.+)_stem$")
    if base and not base:find("stripped_") then
      l[#l + 1] = { out = base .. "_planks", n = 4, grid = { [1] = name } }
    end
  end
  return l
end
local function recipesFor(out, stock)
  local l = {}
  for _, r in ipairs(allRecipes(stock)) do if r.out == out then l[#l + 1] = r end end
  -- planks of a kind with no log in storage yet
  if #l == 0 and out:find("_planks$") then
    local base = out:match("^(.+)_planks$")
    l[1] = { out = out, n = 4, grid = { [1] = base .. (base:find("crimson") or base:find("warped") and "_stem" or "_log") } }
  end
  return l
end

-- Best item for an ingredient: the fitting one there's most of
local function pick(spec, stock)
  local best, bestN = nil, 0
  for name, n in pairs(stock) do
    if fitsSpec(spec, name) and n > bestN then best, bestN = name, n end
  end
  if not best and spec:sub(1, 1) ~= "#" then best = spec end
  return best, bestN
end

-- Does recipe r use something we're already busy making? (coal -> coal block -> coal)
local function loops(r, visiting)
  for _, spec in pairs(r.grid) do
    for v in pairs(visiting) do if fitsSpec(spec, v) then return true end end
  end
  return false
end

local function perSpec(r)
  local per = {}
  for _, spec in pairs(r.grid) do per[spec] = (per[spec] or 0) + 1 end
  return per
end

-- How many it can make right now from what's in storage (no crafting of parts)
local function canMake(r, stock)
  local steps = math.huge
  local missing
  for spec, c in pairs(perSpec(r)) do
    local _, have = pick(spec, stock)
    local s = math.floor(have / c)
    if s < steps then steps = s end
    if s == 0 then missing = missing or specLabel(spec) end
  end
  if steps == math.huge then steps = 0 end
  return steps * r.n, missing
end

local function outStack(name)
  if maxStack[name] then return maxStack[name] end
  local n = short(name)
  for _, w in ipairs({ "pickaxe", "_axe", "shovel", "sword", "_hoe", "helmet", "chestplate", "leggings", "boots",
    "shears", "flint_and_steel", "compass", "bow", "fishing_rod" }) do
    if n:find(w, 1, true) then return 1 end
  end
  if n == "bucket" or n:find("ender_pearl") or n:find("egg") or n:find("snowball") or n:find("_sign") then return 16 end
  return 64
end

-- Put a crafting table on the free side (from the turtle's own slots or from storage)
local function equipTable()
  if crafty() then return end
  local CT = M .. "crafting_table"
  local slot
  for _, c in ipairs(carried(function(n) return n == CT end)) do slot = c.slot end
  if not slot and (totals()[CT] or 0) > 0 and freeSlots() > 0 then
    fetch(CT, 1, 1)
    for _, c in ipairs(carried(function(n) return n == CT end)) do slot = c.slot end
    goHome()
  end
  if not slot then return end
  local side = (not peripheral.getType("left") and "left") or (not peripheral.getType("right") and "right")
  if not side then return end
  turtle.select(slot)
  local ok = side == "left" and turtle.equipLeft() or turtle.equipRight()
  turtle.select(1)
  if ok and crafty() then log("Crafting table equipped: crafting works now") end
end

local function countCarried(name)
  return carriedCount(function(n) return n == name end)
end

-- Craft 'want' of 'out' into storage, making missing parts first. Returns how many it made.
local function craftItem(out, want, depth, visiting)
  visiting = visiting or {}
  if visiting[out] or depth > 4 then return 0 end
  visiting[out] = true
  local made = 0
  for _ = 1, 20 do
    if made >= want then break end
    local stock = totals()
    local rs = {}
    for _, r in ipairs(recipesFor(out, stock)) do if not loops(r, visiting) then rs[#rs + 1] = r end end
    if #rs == 0 then lastMissing = "a recipe for " .. pretty(out) break end
    table.sort(rs, function(a, b) return canMake(a, stock) > canMake(b, stock) end)
    local r = rs[1]
    local stepsWanted = math.ceil((want - made) / r.n)
    local per = perSpec(r)
    -- Make missing parts first (sticks, planks, ...)
    for spec, c in pairs(per) do
      local name, have = pick(spec, stock)
      local need = c * stepsWanted
      if have < need then
        local target = name
        if spec:sub(1, 1) == "#" and (not name or have == 0) then
          -- a group: find something in it that can be crafted
          for _, rr in ipairs(allRecipes(stock)) do
            if fitsSpec(spec, rr.out) and not visiting[rr.out] then target = rr.out break end
          end
        end
        if target then craftItem(target, need - have, depth + 1, visiting) end
      end
    end
    stock = totals()
    if r.smelt then
      -- A furnace recipe: smelt it now and wait for it
      local name, have = pick(r.grid[1], stock)
      local steps = math.min(stepsWanted, have)
      if not name or steps <= 0 then lastMissing = specLabel(r.grid[1]) break end
      storeAll(true)
      local got, why = smeltNow(out, name, steps)
      made = made + got
      if got < steps then lastMissing = why break end
    else
      stock = totals()
      local steps = math.min(stepsWanted, 64)
      local choice = {}
      for spec, c in pairs(per) do
        local name, have = pick(spec, stock)
        if not name or have < c then steps = 0 lastMissing = specLabel(spec) break end
        choice[spec] = name
        steps = math.min(steps, math.floor(have / c), outStack(name))
      end
      local gridSlots = 0
      for _ in pairs(r.grid) do gridSlots = gridSlots + 1 end
      steps = math.min(steps, math.floor((16 - gridSlots) * outStack(out) / r.n))
      if steps <= 0 then break end
      -- Empty the turtle, then fill the grid slot by slot
      setState("Crafting " .. pretty(out))
      storeAll(true)
      for slot, spec in pairs(r.grid) do fetch(choice[spec], steps, nil, slot) end
      -- Make sure every grid slot has exactly 'steps' of the right item
      local function cnt(sl) return turtle.getItemCount(sl) end
      local function nameAt(sl) local d = turtle.getItemDetail(sl) return d and d.name end
      for g, spec in pairs(r.grid) do
        local want = choice[spec]
        if nameAt(g) and nameAt(g) ~= want then -- something else in it: move it out of the grid
          for sp = 16, 1, -1 do
            if not r.grid[sp] and cnt(sp) == 0 then turtle.select(g) turtle.transferTo(sp) break end
          end
        end
        for src = 1, 16 do
          if cnt(g) >= steps then break end
          local extra = cnt(src) - (r.grid[src] and choice[r.grid[src]] == want and steps or 0)
          if src ~= g and nameAt(src) == want and extra > 0 then
            turtle.select(src)
            turtle.transferTo(g, math.min(extra, steps - cnt(g)))
          end
        end
        if cnt(g) > steps then -- too many: the rest out of the grid
          for sp = 16, 1, -1 do
            if not r.grid[sp] and (cnt(sp) == 0 or nameAt(sp) == want) then
              turtle.select(g) turtle.transferTo(sp, cnt(g) - steps)
              if cnt(g) <= steps then break end
            end
          end
        end
      end
      turtle.select(1)
      -- leftovers outside the grid back to storage
      local outside = false
      for sl = 1, 16 do if not r.grid[sl] and cnt(sl) > 0 then outside = true end end
      if outside then storeAll(true, function(sl) return not r.grid[sl] end) end
      local ready = true
      for sl = 1, 16 do
        local d = turtle.getItemDetail(sl)
        local sp = r.grid[sl]
        if sp then
          if not d or d.name ~= choice[sp] or d.count ~= steps then ready = false end
        elseif d then ready = false end
      end
      if not ready then
        lastMissing = "ingredients (couldn't take them all out)"
        storeAll(true)
        break
      end
      local before = countCarried(out)
      turtle.select(4)
      local ok, err = turtle.craft(steps)
      turtle.select(1)
      local got = countCarried(out) - before
      made = made + got
      storeAll(true)
      if not ok or got == 0 then lastMissing = tostring(err or "the recipe didn't work") break end
    end
  end
  visiting[out] = nil
  return made
end

local function serveCrafts()
  while #crafts > 0 do
    local c = table.remove(crafts, 1)
    if not crafty() then
      log("Can't craft: no crafting table on the turtle (put one in the drop-off chest)", true)
    else
      lastMissing = nil
      local inStore = totals()[c.name] or 0
      local made = craftItem(c.name, c.n, 0)
      local total = math.min(c.deliver or c.n, inStore + made)
      if made > 0 then
        stats.crafted = stats.crafted or {}
        stats.crafted[c.name] = (stats.crafted[c.name] or 0) + 1 -- how often, not how many
        log("Crafted " .. made .. " " .. pretty(c.name))
      end
      if total > 0 then deliver({ name = c.name, n = total }) end
      if made < c.n then log("Crafted only " .. made .. " " .. pretty(c.name) .. ": not enough " .. (lastMissing or "ingredients"), true) end
    end
  end
end

-- How many it can make, also by crafting parts first (planks -> sticks -> torches),
-- up to 3 steps deep. A guess: parts shared by two ingredients are counted twice.
local function deepCounter(stock)
  local byOut, all = {}, allRecipes(stock)
  for _, r in ipairs(all) do byOut[r.out] = byOut[r.out] or {} table.insert(byOut[r.out], r) end
  local memo = {}
  local function maxCraft(out, depth, visiting)
    if depth > 3 or visiting[out] then return 0 end
    local key = out .. "@" .. depth
    if memo[key] then return memo[key] end
    visiting[out] = true
    local best = 0
    for _, r in ipairs(byOut[out] or {}) do
      if not loops(r, visiting) then
        local steps = math.huge
        for spec, c in pairs(perSpec(r)) do
          local name, have = pick(spec, stock)
          local extra = 0
          if spec:sub(1, 1) == "#" then
            for o in pairs(byOut) do
              if fitsSpec(spec, o) then extra = math.max(extra, maxCraft(o, depth + 1, visiting)) end
            end
          elseif name then
            extra = maxCraft(name, depth + 1, visiting)
          end
          steps = math.min(steps, math.floor((have + extra) / c))
        end
        if steps == math.huge then steps = 0 end
        best = math.max(best, steps * r.n)
      end
    end
    visiting[out] = nil
    memo[key] = best
    return best
  end
  return function(out) return maxCraft(out, 0, {}) end, all
end

urgent = function()
  if #requests > 0 then serveRequests() end
  if #crafts > 0 then serveCrafts() end
end

-- What the order screen shows: everything it has a recipe for and how many it can make
local function craftList()
  local stock = totals()
  local by = {}
  local deep, all = deepCounter(stock)
  for _, r in ipairs(all) do
    local _, missing = canMake(r, stock)
    local can = deep(r.out)
    local e = by[r.out]
    if not e or can > e.can then
      by[r.out] = { name = r.out, per = r.n, can = can, missing = missing, crafted = (stats.crafted or {})[r.out] or 0 }
    end
  end
  local l = {}
  for _, e in pairs(by) do l[#l + 1] = e end
  table.sort(l, function(a, b) return pretty(a.name) < pretty(b.name) end)
  return l
end

local function matchRecipe(text)
  local q = text:lower():gsub("%s+", "_")
  local found, exact = {}, nil
  for _, e in ipairs(craftList()) do
    if short(e.name) == q or e.name == q then exact = e.name end
    if e.name:find(q, 1, true) then found[#found + 1] = e.name end
  end
  return exact or (#found == 1 and found[1]) or nil, found
end

-- Teach a recipe: items in the 3x3 grid of the turtle (slots 1-3, 5-7, 9-11)
local function learn()
  if not crafty() then return { "No crafting table on the turtle yet." } end
  local grid = {}
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    local inGrid = (s % 4 ~= 0) and s <= 11
    if d and not inGrid then return { "Only the 3x3 grid (slots 1-3, 5-7, 9-11) may hold items." } end
    if d then grid[s] = d.name end
  end
  if not next(grid) then return { "Put one set of the recipe in the turtle's 3x3 grid first." } end
  if not turtle.craft(0) then return { "That's not a recipe (check the layout)." } end
  local before = {}
  for s = 1, 16 do local d = turtle.getItemDetail(s) if d then before[d.name] = (before[d.name] or 0) + d.count end end
  turtle.select(4)
  turtle.craft(1)
  turtle.select(1)
  local after = {}
  for s = 1, 16 do local d = turtle.getItemDetail(s) if d then after[d.name] = (after[d.name] or 0) + d.count end end
  local out, n
  for name, c in pairs(after) do
    if c > (before[name] or 0) and (not n or c - (before[name] or 0) > n) then out, n = name, c - (before[name] or 0) end
  end
  if not out then return { "Crafting didn't give anything." } end
  for i = #learned, 1, -1 do if learned[i].out == out then table.remove(learned, i) end end
  table.insert(learned, 1, { out = out, n = n, grid = grid })
  saveTable(RECIPES_FILE, learned)
  return { "Learned: " .. n .. " " .. pretty(out) .. ". It's on the Craft tab now.", "Type resume to carry on." }
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
  elseif cmd == "blocked" then
    -- Blocked spots and the chests it can't reach because of them
    local out = { "Spots: x right, y up, z rows from the drop-off wall" }
    local any = false
    for k, what in pairs(map.obstacles or {}) do
      out[#out + 1] = " blocked " .. k .. ": " .. (what == "blocked" and "can't move there (nothing seen)" or tostring(what))
      any = true
    end
    if not any then out[#out + 1] = " no blocked spots" end
    for k, e in pairs(idx) do
      if (e.kind == "store" or e.kind == "furnace") and not e.merged and not canReach(e) then
        local names = {}
        for _, it in pairs(e.items or {}) do names[pretty(it.name)] = (names[pretty(it.name)] or 0) + it.count end
        local l = {}
        for n, c in pairs(names) do l[#l + 1] = c .. " " .. n end
        out[#out + 1] = " cut off " .. (e.kind == "furnace" and "furnace" or "chest") .. " " .. k .. ": "
          .. (#l > 0 and table.concat(l, ", ") or "empty")
      end
    end
    out[#out + 1] = "'unblock' forgets them all and tries again; 'unblock x,y,z' just one."
    return out
  elseif cmd == "unblock" then
    local n = 0
    for k in pairs(map.obstacles or {}) do
      if not text or text == "" or text == "all" or text:gsub("%s", "") == k then
        map.cells[k] = "a"
        map.obstacles[k] = nil
        n = n + 1
      end
    end
    saveMap()
    os.queueEvent("room_request")
    return { "Forgot " .. n .. " blocked spot(s). If something is really there it notices again." }
  elseif cmd == "stock" then
    -- everything the order screen needs in one answer
    return { version = VERSION, totals = totals(), state = status.state, crafty = crafty(), cutoff = unreachableCount(),
      recipes = crafty() and craftList() or {},
      orders = stats.orders or {} }
  elseif cmd == "order" then
    -- From storage, and whatever is missing gets crafted
    if not text or text == "" then return { "order <item> [n]" } end
    local name, found = matchItem(text)
    if not name and crafty() then name, found = matchRecipe(text) end
    if not name then
      if #found == 0 then return { "Not in storage" .. (crafty() and " and no recipe for it." or ".") } end
      local out = { "Which one?" }
      for _, f in ipairs(found) do out[#out + 1] = " " .. short(f) end
      return out
    end
    n = math.max(1, math.floor(n or stackOf(name)))
    local have = totals()[name] or 0
    stats.orders = stats.orders or {}
    stats.orders[name] = (stats.orders[name] or 0) + 1
    if have >= n then
      requests[#requests + 1] = { name = name, n = n }
      os.queueEvent("room_request")
      return { "Getting " .. n .. " " .. pretty(name) .. "..." }
    end
    local possible = 0
    if crafty() and #recipesFor(name) > 0 then possible = (deepCounter(totals()))(name) end
    if possible > 0 then
      local make = math.min(n - have, possible)
      crafts[#crafts + 1] = { name = name, n = make, deliver = have + make }
      os.queueEvent("room_request")
      local out = { (have > 0 and ("Getting " .. have .. " " .. pretty(name) .. " and crafting " .. make .. " more...")
        or ("Crafting " .. make .. " " .. pretty(name) .. "...")), "It all goes to the pickup chest." }
      if have + make < n then out[#out + 1] = "(It can only make " .. make .. " right now.)" end
      return out
    end
    if have > 0 then
      requests[#requests + 1] = { name = name, n = have }
      os.queueEvent("room_request")
      return { "Only " .. have .. " in storage (no recipe): getting those." }
    end
    if crafty() and #recipesFor(name) > 0 then
      local r = recipesFor(name)[1]
      local _, missing = canMake(r, totals())
      return { "None in storage, and it can't craft it: short of " .. (missing or "ingredients") .. "." }
    end
    return { "None in storage" .. (crafty() and " and no recipe for it." or ".") }
  elseif cmd == "recipes" then
    if text == "raw" then return { recipes = craftList(), crafty = crafty(), state = status.state } end
    local out = {}
    for _, e in ipairs(craftList()) do out[#out + 1] = (" %s: can make %d"):format(pretty(e.name), e.can) end
    if not crafty() then table.insert(out, 1, "No crafting table on the turtle yet (put one in the drop-off chest).") end
    return out
  elseif cmd == "craft" then
    if not text or text == "" then return { "craft <item> [n]" } end
    if not crafty() then return { "No crafting table on the turtle yet: put one in the drop-off chest." } end
    local name, found = matchRecipe(text)
    if not name then
      if #found == 0 then return { "No recipe for that. Teach it with 'learn' on the turtle." } end
      local out = { "Which one?" }
      for _, f in ipairs(found) do out[#out + 1] = " " .. short(f) end
      return out
    end
    n = math.max(1, math.floor(n or 1))
    crafts[#crafts + 1] = { name = name, n = n }
    os.queueEvent("room_request")
    return { "Crafting " .. n .. " " .. pretty(name) .. "...", "It goes to the pickup chest when done." }
  elseif cmd == "resync" then
    resyncRequest = true
    os.queueEvent("room_request")
    return { "Counting everything again: it checks blocked spots and opens every chest.",
      "Takes a few minutes; orders still go first. Status shows when it's done." }
  elseif cmd == "pickup" then
    -- find the pickup chest again after moving it
    if busyFind then return { "Already looking." } end
    findRequest = true
    os.queueEvent("room_request")
    return { "Looking for the pickup chest near where it was...", "Type status in a moment, or just order something." }
  elseif cmd == "pause" then
    paused = true
    os.queueEvent("room_request")
    return { "Pausing: it finishes its job, puts everything away and then says Paused." }
  elseif cmd == "resume" then
    paused = false
    os.queueEvent("room_request")
    return { "Running again." }
  elseif cmd == "update" then
    -- pauses (puts everything away), then the worker fetches the latest version
    if status.update == nil then status.update = paused end
    paused = true
    os.queueEvent("room_request")
    return { "Updating: it puts everything away, then fetches", "the latest version from GitHub and restarts." }
  elseif cmd == "learn" then
    if not paused or status.state ~= "Paused" then
      return { "To teach a recipe: type pause, wait until it says Paused,", "put one set in its 3x3 grid, then type learn." }
    end
    return learn()
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
  return { "Commands: list [text], find <item>, get <item> [n], order <item> [n], craft <item> [n], recipes,",
    "build, status, blocked, unblock [x,y,z], resync, pickup, pause, resume, learn" }
end

---------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------
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
    line(cut .. " chests cut off: type 'blocked'", colors.orange)
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
  if resyncRequest then
    resyncRequest = false
    resync()
  end
  if findRequest then
    findRequest, busyFind = false, true
    local _, msg = findOutput()
    log(msg)
    busyFind = false
  end
  -- Low on fuel: refuel first, before anything that moves (fuel put in the turtle or
  -- in the input chest gets it going again)
  refuelCarried()
  if fuelLeft() < cfg.minFuel then
    pullInput()
    refuelSelf()
  end
  fixAccess()
  equipTable()
  serveRequests()
  serveCrafts()
  pullInput()
  refuelCarried() -- lava buckets from the input chest straight into the tank
  urgent()
  refuelSelf()
  urgent()
  buildFurnaces()
  buildChests()
  urgent()
  furnacePass()
  urgent()
  storeAll()
  urgent()
  goHome()
  saveTable(FILES.stats, stats)
  os.queueEvent("room_stock")
end

local function worker()
  if not map.badCleared then -- older versions gave up on a spot after 1 failed try
    map.bad, map.badCleared = nil, true
    saveMap()
  end
  if map.layout ~= 2 then log("Old room plan: pick up what it built and run 'roomsorter scan force' for the tidy layout", true) end
  setState("Checking position")
  -- Lost: keep the program running and show why, try again every 10 s or right after
  -- 'home' (typed once it's back on its start spot facing the input chest)
  while true do
    refuelCarried()
    if status.homeTyped then status.homeTyped = false log("Back on the start spot") break end
    local ok, err = pcall(verifyPose)
    if ok then break end
    setState("LOST")
    status.note = "Put me on my start spot facing the input chest and type: home"
    log(tostring(err), true)
    local timer = os.startTimer(10)
    while true do
      local ev, a = os.pullEvent()
      if ev == "room_home" or (ev == "timer" and a == timer) then break end
    end
  end
  status.note = nil
  local emptied = false
  while true do
    if paused and not emptied then
      -- Paused: put everything away first, so the inventory is free (e.g. for 'learn')
      setState("Emptying before pause")
      pcall(storeAll, true)
      pcall(goHome)
      emptied = true
    end
    if paused and emptied and status.update ~= nil then
      setState("Updating")
      shell.run(shell.getRunningProgram(), "update") -- reboots when there's a new version
      paused, status.update = status.update, nil
    end
    if not paused then
      emptied = false
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
      elseif cmd == "home" then
        -- it's back on its start spot facing the input chest
        pos.x, pos.y, pos.z, pos.h, pos.pend = 0, 0, 0, 0, nil
        savePos()
        status.homeTyped = true -- trusted even if the start spot looks different
        os.queueEvent("room_home")
        print("Position reset to the start spot.")
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
      furnaces = #furnaces(), state = status.state, full = status.full, ordered = stats.requested }
    local sig = textutils.serialize(msg.totals) .. used .. tostring(status.full)
    if onlyIfChanged and sig == lastSig then return end
    rednet.broadcast(msg, PROTOCOL .. "_stock")
    lastSent, lastSig = os.clock(), sig
  end
  local tick = os.startTimer(1)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and c == PROTOCOL and type(b) == "table" then
      local reply = command(b.cmd, b.text, b.n)
      if type(reply) == "table" then reply.rid = b.rid end -- so the asking screen knows it's its answer
      rednet.send(a, reply, PROTOCOL)
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
saveTable(FILES.stats, stats)
print("roomsorter stopped.")
