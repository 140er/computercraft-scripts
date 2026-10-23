-- Server-owned shop screen for the existing Storage Room turtle.
local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end

local S = {
  turtle = nil,
  lookupAt = nil,
  stockAt = nil,
  sampleAt = nil,
  rid = 0,
  pending = {},
  totals = {},
  history = {},
  state = "waiting for stock",
  views = {},
  heardAt = nil,
  selectedAt = nil,
  staleAfter = 300000,
  orders = {},
  latestOrder = nil,
  registered = false,
  -- Learned from roomsorter stock replies (additive fields; older rooms send none).
  labels = {},
  stacks = {},
  tags = {},
  recipes = {},
  -- Recent orders per item, newest first, and cached categories.
  recent = {},
  kinds = {},
}

S.wall = function()
  if not U or not S.heardDate then return "--:--" end
  return U.clock(S.heardDate + SO.now() - S.heardAt).hm
end

S.request = function(kind, name, count, view)
  if not S.turtle then
    if view then view.order, view.orderDetail = "Order: failed, storage room not found", nil end
    return false
  end
  S.rid = S.rid + 1
  local rid = S.rid
  local pending = { kind = kind, sender = S.turtle, at = SO.now(), view = view }
  S.pending[rid] = pending
  if kind == "order" then
    S.latestOrder = rid
    S.orders = { "sent " .. tostring(count) .. " " .. name }
    local list = S.recent[name] or {}
    S.recent[name] = list
    pending.entry = { hm = S.wall(), n = count, status = "sent" }
    table.insert(list, 1, pending.entry)
    if #list > 8 then table.remove(list) end
    if view then
      view.order, view.orderDetail, view.orderRid = "Order: sent " .. count, nil, rid
    end
  end
  rednet.send(S.turtle, { cmd = kind, text = name, n = count, rid = rid }, "roomsorter")
  return true
end

S.stock = function(message)
  if type(message.totals) == "table" then
    S.heardAt = SO.now()
    S.heardDate = os.epoch("utc")
    local totals = {}
    for name, count in pairs(message.totals) do
      if type(name) == "string" and type(count) == "number" and count >= 0
          and count < math.huge then totals[name] = count end
    end
    S.totals = totals
  end
  if type(message.state) == "string" then S.state = message.state end
  for name, label in pairs(type(message.labels) == "table" and message.labels or {}) do
    if type(name) == "string" and type(label) == "string" then S.labels[name] = label:sub(1, 40) end
  end
  for name, stack in pairs(type(message.stacks) == "table" and message.stacks or {}) do
    if type(name) == "string" and type(stack) == "number" and stack >= 1 and stack <= 64 then
      S.stacks[name] = math.floor(stack)
    end
  end
  for name, tags in pairs(type(message.tags) == "table" and message.tags or {}) do
    if type(name) == "string" and type(tags) == "table" then
      local list = {}
      for _, tag in ipairs(tags) do if type(tag) == "string" and #list < 16 then list[#list + 1] = tag end end
      S.tags[name], S.kinds[name] = list, nil
    end
  end
  if type(message.recipes) == "table" then
    local recipes = {}
    for _, recipe in ipairs(message.recipes) do
      if type(recipe) == "table" and type(recipe.name) == "string" and type(recipe.can) == "number" then
        recipes[recipe.name] = recipe.can
      end
    end
    S.recipes = recipes
  end
end

S.reply = function(sender, message)
  if type(message) ~= "table" then return end
  local pending = S.pending[message.rid]
  if not pending or pending.sender ~= sender then return end
  if pending.kind == "stock" then
    S.pending[message.rid] = nil
    S.stock(message)
  else
    local lines = {}
    for i = 1, #message do
      if type(message[i]) == "string" then lines[#lines + 1] = message[i] end
    end
    if message.rid == S.latestOrder then S.orders = lines end
    local text = table.concat(lines, "; ")
    local lower = text:lower()
    local status = "failed"
    if lower:match("^getting ") or lower:match("^crafting ") or lower:find("getting those", 1, true) then
      status = "sent"
    elseif lower:match("^delivered ") or lower:find("sent to output chest", 1, true) then
      status = "delivered"
    end
    if status == "sent" then pending.acknowledged = true
    else S.pending[message.rid] = nil end
    if pending.entry then pending.entry.status = status end
    if pending.view and pending.view.orderRid == message.rid then
      pending.view.order = "Order: " .. status
      pending.view.orderDetail = text ~= "" and text or "empty reply"
    end
  end
end

S.broadcast = function(sender, message)
  if type(message) ~= "table" or type(message.totals) ~= "table" then return end
  if not S.turtle then S.turtle = sender S.selectedAt = SO.now() end
  if sender == S.turtle then S.stock(message) end
end

S.dns = function(sender, message)
  if not S.turtle and type(message) == "table" and message.sType == "lookup response"
      and message.sProtocol == "roomsorter" then
    S.turtle = sender
    S.selectedAt = SO.now()
  end
end

S.sample = function(now)
  if S.sampleAt and now - S.sampleAt < 60000 then return end
  if next(S.totals) == nil and next(S.history) == nil then return end
  S.sampleAt = now
  for name, samples in pairs(S.history) do
    if S.totals[name] == nil then
      samples[#samples + 1] = 0
      if #samples > 60 then table.remove(samples, 1) end
      local seen = false
      for _, value in ipairs(samples) do seen = seen or value > 0 end
      if not seen then S.history[name] = nil end
    end
  end
  for name, count in pairs(S.totals) do
    local samples = S.history[name]
    if not samples then samples = {} S.history[name] = samples end
    samples[#samples + 1] = count
    if #samples > 60 then table.remove(samples, 1) end
  end
end

S.row = function(text)
  return { text = text, fg = "0", bg = "f" }
end

S.view = function(client)
  local key = type(client) == "table" and (client.id or client) or client or 0
  if not S.views[key] then
    S.views[key] = { search = "", page = 1, sort = "count", screen = "home", list = "all", sub = "all", home = 1 }
  end
  return S.views[key]
end

S.norm = function(text)
  return (text:lower():gsub("%s+", "_"))
end

S.match = function(name, query)
  if query == "" or name:lower():find(query, 1, true) then return true end
  return S.norm(S.label(name)):find(query, 1, true) ~= nil
end

-- Read-only: stocked items whose id or name contains the search, most stock first, then by id.
S.matches = function(search, limit)
  local query, list = S.norm(tostring(search or "")), {}
  for name, count in pairs(S.totals) do
    if S.match(name, query) then list[#list + 1] = { name = name, count = count, label = S.label(name):upper() } end
  end
  table.sort(list, function(a, b) return a.count > b.count or (a.count == b.count and a.name < b.name) end)
  for i = #list, (limit or 10) + 1, -1 do list[i] = nil end
  return list
end

-- The item an order for `search` goes to: a stocked exact id, else the first match.
S.best = function(search)
  if type(search) ~= "string" or search == "" then return nil end
  if (S.totals[search] or 0) > 0 then return search, S.totals[search] end
  local best = S.matches(search, 1)[1]
  if best and best.count > 0 then return best.name, best.count end
  return nil
end

-- One order of 1, 16 or 64 for the best match. Returns the item sent, or nil and a reason.
-- Changes no display's screen state.
S.order = function(search, count)
  if count ~= 1 and count ~= 16 and count ~= 64 then return nil, "bad count" end
  local name = S.best(search)
  if not name then return nil, "no match" end
  if not S.request("order", name, count) then return nil, "storage room not found" end
  return name
end

S.legacy = function(w, h, clientId)
  local search = S.view(clientId).search
  local picture = {
    rows = {},
    buttons = {
      { id = "clear", x = 9, y = 1, w = 5, label = "clear" },
    },
  }
  local rows, buttons = picture.rows, picture.buttons
  rows[1] = S.row("              Storage: " .. S.state)
  rows[2] = S.row("")
  if not S.turtle then
    rows[#rows + 1] = S.row("Storage room not found, still looking")
    return picture
  end
  for i = 1, #S.orders do rows[#rows + 1] = S.row("Order: " .. S.orders[i]) end
  local items = {}
  local query = search:lower():gsub("%s+", "_")
  for name, count in pairs(S.totals) do
    if name:lower():find(query, 1, true) then items[#items + 1] = { name = name, count = count } end
  end
  table.sort(items, function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end)
  for i = 1, #items do
    local item = items[i]
    local samples = S.history[item.name]
    local baseline = samples and samples[1] or item.count
    local arrow = item.count > baseline and "^" or (item.count < baseline and "v" or "-")
    local y = #rows + 1
    rows[y] = S.row("1 16 64 " .. arrow .. " " .. tostring(item.count) .. " " .. item.name)
    for _, amount in ipairs({ 1, 16, 64 }) do
      buttons[#buttons + 1] = {
        id = "order:" .. tostring(amount) .. ":" .. item.name,
        x = amount == 1 and 1 or (amount == 16 and 3 or 6),
        y = y, w = #tostring(amount), label = tostring(amount),
      }
    end
  end
  return picture
end

-- Categories, in display order, with their subcategory ids. Labels are the ids in capitals.
-- MODS lists one subcategory per namespace present.
S.cats = {
  { "ores", "ORES", "ore raw ingot nugget block gem dust" },
  { "wood", "WOOD", "log planks sapling crafted" },
  { "stone", "STONE", "stone earth build" },
  { "plants", "PLANTS", "leaves seeds flowers plants" },
  { "food", "FOOD", "crops meat meals" },
  { "tools", "TOOLS", "tools weapons armour" },
  { "redstone", "REDSTONE", "dust logic motion" },
  { "mobs", "MOBS", "hostile passive" },
  { "mods", "MODS", "" },
  { "other", "OTHER", "" },
}

-- First match wins. Patterns test the id after its namespace. "=metal" is a storage
-- block of a metal or gem, "=wood" any id starting with a wood type.
S.rules = {
  "tools/armour _helmet$ _chestplate$ _leggings$ _boots$ ^elytra$ _horse_armor$ ^wolf_armor$",
  "tools/weapons _sword$ ^bow$ ^crossbow$ ^trident$ ^mace$ ^shield$ arrow$",
  "tools/tools _pickaxe$ _axe$ _shovel$ _hoe$ ^shears$ ^fishing_rod$ ^flint_and_steel$ ^brush$ ^spyglass$"
    .. " ^compass$ ^clock$ bucket$",
  "redstone/dust ^redstone$ ^redstone_block$",
  "redstone/logic ^repeater$ ^comparator$ ^observer$ ^redstone_torch$ ^lever$ _button$ _pressure_plate$"
    .. " ^daylight_detector$ ^target$ ^tripwire_hook$ ^redstone_lamp$ sculk_sensor$ ^note_block$ ^lightning_rod$",
  "redstone/motion piston$ ^hopper$ ^dropper$ ^dispenser$ rail$ minecart$ ^tnt$ ^crafter$",
  "food/meals ^cooked_ ^bread$ ^baked_potato$ ^cookie$ _pie$ _stew$ _soup$ ^cake$ ^dried_kelp$ ^golden_carrot$"
    .. " golden_apple$ ^honey_bottle$",
  "food/meat ^beef$ ^porkchop$ ^chicken$ ^mutton$ ^rabbit$ ^cod$ ^salmon$ ^tropical_fish$ ^pufferfish$",
  "food/crops ^wheat$ ^carrot$ ^potato$ ^poisonous_potato$ ^beetroot$ ^melon_slice$ ^melon$ ^pumpkin$ ^apple$"
    .. " _berries$ ^chorus_fruit$ ^nether_wart$ ^sugar$ ^cocoa_beans$",
  "mobs/hostile ^bone$ ^bone_meal$ ^string$ spider_eye$ ^gunpowder$ ^rotten_flesh$ ^ender_pearl$ ^ender_eye$"
    .. " ^blaze_ ^ghast_tear$ ^slime_ball$ ^phantom_membrane$ ^magma_cream$ ^shulker_shell$ ^prismarine_shard$"
    .. " ^prismarine_crystals$ _skull$ ^nether_star$ ^breeze_rod$",
  "mobs/passive ^leather$ ^feather$ ink_sac$ ^egg$ ^rabbit_hide$ ^rabbit_foot$ scute$ ^honeycomb$ ^nautilus_shell$",
  "ores/ore _ore$ ^ancient_debris$",
  "ores/block =metal",
  "ores/raw ^raw_",
  "ores/ingot _ingot$ ^ingot_ ^netherite_scrap$",
  "ores/nugget _nugget$ ^nugget_",
  "ores/gem ^diamond$ ^emerald$ ^lapis_lazuli$ ^quartz$ ^amethyst_shard$ ^coal$ ^charcoal$ _gem$ ^gem_",
  "ores/dust _dust$ ^dust_",
  "wood/log _log$ _wood$ _stem$ _hyphae$ ^stripped_ ^bamboo_block$",
  "wood/planks _planks$",
  "wood/sapling _sapling$ _propagule$ azalea$ _fungus$",
  "plants/leaves _leaves$",
  "plants/seeds _seeds$",
  "plants/flowers ^dandelion$ ^poppy$ ^blue_orchid$ ^allium$ ^azure_bluet$ _tulip$ ^oxeye_daisy$ ^cornflower$"
    .. " ^lily_of_the_valley$ ^sunflower$ ^lilac$ ^rose_bush$ ^peony$ ^wither_rose$ ^torchflower$ ^pitcher_plant$",
  "plants/plants ^vine$ ^kelp$ ^cactus$ ^sugar_cane$ ^bamboo$ ^moss_ ^lily_pad$ _mushroom$ grass$ fern$"
    .. " ^dead_bush$ ^seagrass$ ^sea_pickle$ ^glow_lichen$ _roots$ _vines$ dripleaf$ ^spore_blossom$",
  "stone/stone ^stone$ ^cobblestone$ ^mossy_cobblestone$ ^cobbled_deepslate$ ^deepslate$ ^granite$ ^diorite$"
    .. " ^andesite$ ^tuff$ ^calcite$ basalt$ ^blackstone$ ^netherrack$ ^end_stone$ obsidian$ ^dripstone_block$"
    .. " ^pointed_dripstone$ ^smooth_stone$ sandstone$ ^magma_block$",
  "stone/earth ^dirt$ ^coarse_dirt$ ^rooted_dirt$ ^grass_block$ ^podzol$ ^mycelium$ nylium$ ^sand$ ^red_sand$"
    .. " ^gravel$ ^clay$ ^clay_ball$ ^mud$ ^soul_sand$ ^soul_soil$ ^snow ^ice$ ^packed_ice$ ^flint$",
  "wood/crafted =wood ^stick$ ^chest$ ^barrel$ ^crafting_table$ ^ladder$ ^bowl$",
  "stone/build brick glass$ glass_pane$ _concrete terracotta$ _wool$ _carpet$ ^quartz_ ^smooth_ ^polished_"
    .. " ^chiseled_ ^cut_ _tiles$ prismarine$ ^purpur_ _stairs$ _slab$ _wall$ ^bookshelf$",
}
S.metals = {}
for word in ("iron gold copper netherite diamond emerald lapis coal zinc tin lead silver nickel osmium"
    .. " uranium aluminum platinum brass bronze steel"):gmatch("%S+") do S.metals[word] = true end
S.woods = {}
for word in ("oak spruce birch jungle acacia dark_oak pale_oak mangrove cherry bamboo crimson warped")
    :gmatch("%S+") do S.woods[word] = true end
-- Common item tags (c:, forge:, minecraft:) for ids the rules miss, keyed by the tag's base word.
S.tagKinds = {
  ores = "ores/ore", raw_materials = "ores/raw", ingots = "ores/ingot", nuggets = "ores/nugget",
  gems = "ores/gem", dusts = "ores/dust", storage_blocks = "ores/block", logs = "wood/log",
  planks = "wood/planks", saplings = "wood/sapling", leaves = "plants/leaves", seeds = "plants/seeds",
  flowers = "plants/flowers", small_flowers = "plants/flowers", crops = "food/crops", foods = "food/meals",
  tools = "tools/tools", swords = "tools/weapons", armors = "tools/armour", stones = "stone/stone",
  stone = "stone/stone", cobblestones = "stone/stone", cobblestone = "stone/stone",
}

S.special = function(token, path)
  if token == "=metal" then
    local base = path:match("^(.+)_block$")
    return base ~= nil and (S.metals[base] or base:match("^raw_") ~= nil)
  end
  for wood in pairs(S.woods) do
    if path:sub(1, #wood + 1) == wood .. "_" then return true end
  end
  return false
end

-- Category and subcategory of an item id, from the rules, then its tags, then its namespace.
S.kind = function(name)
  local cached = S.kinds[name]
  if cached then return cached[1], cached[2] end
  if not S.compiled then
    S.compiled = {}
    for _, line in ipairs(S.rules) do
      local cat, sub, rest = line:match("^(%a+)/(%a+)%s+(.+)$")
      local patterns = {}
      for pattern in rest:gmatch("%S+") do patterns[#patterns + 1] = pattern end
      S.compiled[#S.compiled + 1] = { cat, sub, patterns }
    end
  end
  local space, path = name:match("^([^:]+):(.+)$")
  if not space then space, path = "minecraft", name end
  local cat, sub
  for _, rule in ipairs(S.compiled) do
    for _, pattern in ipairs(rule[3]) do
      local hit
      if pattern:sub(1, 1) == "=" then hit = S.special(pattern, path) else hit = path:find(pattern) ~= nil end
      if hit then cat, sub = rule[1], rule[2] break end
    end
    if cat then break end
  end
  for _, tag in ipairs(cat == nil and S.tags[name] or {}) do
    local found = S.tagKinds[tag:gsub("^[%w_]+:", ""):gsub("/.*$", "")]
    if found then cat, sub = found:match("^(%a+)/(%a+)$") break end
  end
  if not cat then
    if space == "minecraft" then cat, sub = "other", "other" else cat, sub = "mods", space end
  end
  S.kinds[name] = { cat, sub }
  return cat, sub
end

S.label = function(name)
  if S.labels[name] then return S.labels[name] end
  local path = name:match(":(.+)$") or name
  return ((" " .. path:gsub("_", " ")):gsub(" (%l)", function(c) return " " .. c:upper() end):sub(2))
end

S.stackOf = function(name, cat)
  if S.stacks[name] then return S.stacks[name] end
  local path = name:match(":(.+)$") or name
  for _, pattern in ipairs({ "^ender_pearl$", "^egg$", "^snowball$", "^bucket$", "^honey_bottle$", "_sign$",
      "_banner$", "^armor_stand$" }) do
    if path:find(pattern) then return 16 end
  end
  if cat == "tools" and not path:find("arrow$") then return 1 end
  return 64
end

S.short = function(n)
  if n >= 10000 then return math.floor(n / 1000) .. "k" end
  return tostring(n)
end

-- Every known item: stocked now, or stocked within the sampled hour (count 0).
S.items = function()
  local names, list = {}, {}
  for name in pairs(S.totals) do names[name] = true end
  for name in pairs(S.history) do names[name] = true end
  for name in pairs(names) do
    local count, samples = S.totals[name] or 0, S.history[name]
    local delta = count - (samples and samples[1] or count)
    local rate = math.floor(math.abs(delta) * 60 / math.max(1, samples and #samples - 1 or 1) + 0.5)
    local cat, sub = S.kind(name)
    local stack = S.stackOf(name, cat)
    local item = { name = name, label = S.label(name), count = count, stack = stack, cat = cat, sub = sub,
      rate = delta < 0 and -rate or rate, samples = samples or { count } }
    item.trend = delta == 0 and "-" or (delta > 0 and "^ +" or "v -") .. S.short(rate) .. "/h"
    item.arrow = delta == 0 and "-" or delta > 0 and "^" or "v"
    item.state = count == 0 and "empty" or count < math.min(16, stack) and "low" or "ok"
    list[#list + 1] = item
  end
  return list
end

S.sorts = {
  count = function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end,
  name = function(a, b)
    local x, y = a.label:lower(), b.label:lower()
    if x == y then return a.name < b.name end
    return x < y
  end,
  trend = function(a, b)
    local x, y = math.abs(a.rate), math.abs(b.rate)
    if x == y then return a.name < b.name end
    return x > y
  end,
}

S.gather = function(client)
  local view = S.view(client)
  local m = { found = S.turtle ~= nil, all = S.items(), items = {}, search = view.search,
    stale = S.heardAt == nil or SO.now() - S.heardAt >= 30000, time = "-" }
  if S.heardAt then m.time = U and U.clock(S.heardDate).hm or "-" end
  m.status = not m.found and "" or m.stale and "STALE STOCK" or "stock " .. m.time
  local query = S.norm(view.search)
  for _, item in ipairs(m.all) do
    local keep
    if view.list == "cat" then keep = item.cat == view.cat and (view.sub == "all" or item.sub == view.sub)
    elseif view.list == "low" or view.list == "empty" then keep = item.state == view.list
    elseif view.list == "search" then keep = S.match(item.name, query)
    else keep = true end
    if keep then m.items[#m.items + 1] = item end
    if item.name == view.selected then m.selected = item end
  end
  table.sort(m.items, S.sorts[view.sort] or S.sorts.count)
  return m
end

-- Category rows for the home page, in display order, then LOW and EMPTY.
S.summary = function(m)
  local rows, byCat = {}, {}
  for _, cat in ipairs(S.cats) do
    local row = { id = "cat:" .. cat[1], label = cat[2], items = 0, total = 0, low = 0 }
    rows[#rows + 1], byCat[cat[1]] = row, row
  end
  local low = { id = "low", label = "LOW", items = 0 }
  local empty = { id = "empty", label = "EMPTY", items = 0 }
  for _, item in ipairs(m.all) do
    local row = byCat[item.cat]
    row.items, row.total = row.items + 1, row.total + item.count
    if item.state ~= "ok" then row.low = row.low + 1 end
    if item.state == "low" then low.items = low.items + 1 end
    if item.state == "empty" then empty.items = empty.items + 1 end
  end
  for _, row in ipairs(rows) do row.state = row.items > 0 and "b" or "c" end
  low.state, empty.state = low.items > 0 and "1" or "d", empty.items > 0 and "e" or "d"
  rows[#rows + 1], rows[#rows + 2] = low, empty
  return rows
end

S.subs = function(view, m)
  local subs = { { "sub:all", "ALL" } }
  if view.list ~= "cat" then return nil end
  for _, cat in ipairs(S.cats) do
    if cat[1] == view.cat then
      for sub in cat[3]:gmatch("%S+") do subs[#subs + 1] = { "sub:" .. sub, sub:upper() } end
    end
  end
  if view.cat == "mods" then
    local counts, spaces = {}, {}
    for _, item in ipairs(m.all) do
      if item.cat == "mods" then
        if not counts[item.sub] then spaces[#spaces + 1] = item.sub end
        counts[item.sub] = (counts[item.sub] or 0) + 1
      end
    end
    table.sort(spaces, function(a, b)
      if counts[a] == counts[b] then return a < b end
      return counts[a] > counts[b]
    end)
    for _, space in ipairs(spaces) do subs[#subs + 1] = { "sub:" .. space, space:upper():sub(1, 10) } end
  end
  return #subs > 1 and subs or nil
end

-- Kit hits and buttons, skipped when a tiny screen leaves them no cells.
S.hit = function(C, id, x, y, width, height)
  if width >= 1 and height >= 1 then C.hit(id, x, y, width, height) end
end

S.button = function(C, x, y, width, label, id, bg, height)
  if width >= 1 and (height or 3) >= 1 then C.button(x, y, width, label, id, bg, height) end
end

S.right = function(C, x, y, text)
  C.put(x - #text + 1, y, text)
end

-- One-row controls across the full width; entries without an id are labels.
-- Split puts paging on its own bottom row, for screens too narrow for one row.
S.nav = function(C, w, h, entries, split)
  if split then
    local actions, paging = {}, {}
    for _, entry in ipairs(entries) do
      local list = (entry[2] == nil or entry[2] == "prev" or entry[2] == "next") and paging or actions
      list[#list + 1] = entry
    end
    S.nav(C, w, h - 1, actions)
    entries = paging
  end
  local cols = U.grid(w, h, #entries)
  for i, entry in ipairs(entries) do
    local col = cols[i]
    if col.w < 1 then
    elseif entry[2] then S.button(C, col.x, h, col.w, entry[1], entry[2], entry[3] or "7", 1)
    else
      C.fill(col.x, h, col.w, 1, "7")
      local inset = #entry[1] <= col.w - 2 and 1 or 0
      C.center(col.x + inset, math.max(0, col.w - 2 * inset), h, entry[1])
    end
  end
end

S.paged = function(entries, page, pages)
  if pages <= 1 then return entries end
  local out = {}
  for i, entry in ipairs(entries) do
    out[#out + 1] = entry
    if i == 1 then
      out[#out + 1] = { "<", "prev" }
      out[#out + 1] = { page .. "/" .. pages }
      out[#out + 1] = { ">", "next" }
    end
  end
  return out
end

-- Chips flow left to right from column 2 and wrap; each row stretches to the margin.
S.flow = function(C, w, y, entries, selected, most)
  local rows, row, used, width = {}, {}, 0, w - 2
  for _, entry in ipairs(entries) do
    local need = #entry[2] + 1
    if #row > 0 and used + 1 + need > width then rows[#rows + 1], row, used = { row, used }, {}, 0 end
    used = used + (#row > 0 and 1 or 0) + need
    row[#row + 1] = entry
  end
  if #row > 0 then rows[#rows + 1] = { row, used } end
  for r = most + 1, #rows do rows[r] = nil end
  for r, pack in ipairs(rows) do
    local x, extra, n = 2, width - pack[2], #pack[1]
    for i, entry in ipairs(pack[1]) do
      local size = #entry[2] + 1 + math.floor(extra * i / n) - math.floor(extra * (i - 1) / n)
      S.button(C, x, y + r - 1, size, entry[2], entry[1], entry[1] == selected and "a" or "7", 1)
      x = x + size + 1
    end
  end
  return #rows
end

S.home = function(C, m, view, w, h)
  local top = h >= 16 and 4 or 3
  local rows = S.summary(m)
  local space = math.max(0, h - 2 - top)
  local tall = math.max(1, math.min(3, math.floor(space / #rows)))
  local per = math.floor(space / tall)
  local pages = math.max(1, math.ceil(#rows / math.max(1, per)))
  -- Rows end at h - 2, so a split nav can use row h - 1.
  local split = pages > 1 and w < 25
  view.home = math.max(1, math.min(view.home or 1, pages))
  view.homeCapacity = math.max(1, per)
  local nav = S.paged({ { "ALL", "all" }, { "FIND", "search" } }, view.home, pages)
  if not m.found then
    local text, width = "Storage room not found", math.max(1, w - 2)
    for i = 1, math.ceil(#text / width) do C.put(2, top + i, text:sub((i - 1) * width + 1, i * width)) end
    return nav, split
  end
  local x0, x1 = 2, w - 1
  local items = x0 + 16
  local total = items + (x1 - x0 + 1 < 26 and 7 or 8)
  local low = x1 - total >= 5 and total + 5 or nil
  local bar = (low or total) + 2
  local most = 1
  for _, row in ipairs(rows) do most = math.max(most, row.total or 0) end
  C.fill(x0, top, x1 - x0 + 1, 1, "7")
  C.put(x0 + 2, top, "CATEGORY")
  S.right(C, items, top, "ITEMS")
  S.right(C, total, top, "TOTAL")
  if low then S.right(C, low - 1, top, "LOW") end
  for i = 1, per do
    local row = rows[(view.home - 1) * per + i]
    if not row then break end
    local y = top + 1 + (i - 1) * tall
    local mid = y + math.floor((tall - 1) / 2)
    C.fill(x0, y, x1 - x0 + 1, tall, i % 2 == 0 and "7" or "f")
    C.fill(x0, y, 1, tall, m.stale and "c" or row.state)
    C.put(x0 + 2, mid, row.label:sub(1, 9))
    S.right(C, items, mid, tostring(row.items))
    if row.total then S.right(C, total, mid, tostring(row.total)) end
    if low and (row.low or 0) > 0 then
      C.fill(low - 3, y, 4, tall, "1")
      S.right(C, low - 1, mid, tostring(row.low))
    end
    if row.total and x1 - bar + 1 >= 6 and row.total > 0 then
      C.fill(bar, y, math.max(1, math.floor(row.total * (x1 - bar + 1) / most + 0.5)), tall, m.stale and "c" or "b")
    end
    S.hit(C, row.id, x0, y, x1 - x0 + 1, tall)
  end
  local y = top + 2 + #rows * tall
  if pages > 1 or h - 2 - y < 3 then return nav, split end
  local movers = {}
  for _, item in ipairs(m.all) do if item.rate ~= 0 then movers[#movers + 1] = item end end
  table.sort(movers, S.sorts.trend)
  for i = h - 1 - y, #movers do movers[i] = nil end
  if movers[1] then S.table(C, x0, x1, y, movers, nil, m.stale, "MOVING") end
  return nav, split
end

S.columns = function(width)
  if width >= 44 then return { { "count", "COUNT", 7 }, { "stacks", "STACKS", 7 }, { "trend", "TREND", 10 } } end
  if width >= 34 then return { { "count", "COUNT", 7 }, { "trend", "TREND", 10 } } end
  if width >= 20 then return { { "count", "COUNT", 6 }, { "trend", "^v", 2 } } end
  return { { "count", "COUNT", 6 } }
end

S.cell = function(item, key, width)
  if key == "count" then return tostring(item.count) end
  if key == "trend" then return width < 10 and item.arrow or item.trend end
  if item.stack <= 1 then return "-" end
  local stacks = item.count / item.stack
  return stacks >= 100 and tostring(math.floor(stacks)) or string.format("%.1f", stacks)
end

-- A sortable table of items between x0 and x1: head row at y, then one row per item.
S.table = function(C, x0, x1, y, items, sort, stale, title)
  local columns, right = S.columns(x1 - x0 + 1), x1
  local spans = {}
  for i = #columns, 1, -1 do
    -- Counts keep one column of padding inside their low and empty chips.
    spans[i] = { right - columns[i][3] + 1, right, columns[i][1] == "count" and right - 1 or right }
    right = right - columns[i][3]
  end
  C.fill(x0, y, x1 - x0 + 1, 1, "7")
  if sort == "name" then C.fill(x0, y, right - x0 + 1, 1, "a") end
  C.put(x0 + 2, y, title or "NAME")
  if not title then S.hit(C, "sort:name", x0, y, right - x0 + 1, 1) end
  for i, column in ipairs(columns) do
    local span = spans[i]
    if column[1] == sort then C.fill(span[1], y, span[2] - span[1] + 1, 1, "a") end
    S.right(C, span[3], y, column[2])
    if column[1] ~= "stacks" and not title then
      S.hit(C, "sort:" .. column[1], span[1], y, span[2] - span[1] + 1, 1)
    end
  end
  for i, item in ipairs(items) do
    local row = y + i
    local state = stale and "c" or ({ ok = "d", low = "1", empty = "e" })[item.state]
    C.fill(x0, row, x1 - x0 + 1, 1, i % 2 == 0 and "7" or "f")
    C.fill(x0, row, 1, 1, state)
    for c, column in ipairs(columns) do
      local span = spans[c]
      if column[1] == "count" and item.state ~= "ok" and not stale then
        C.fill(span[1] + 1, row, span[2] - span[1], 1, state)
      end
      S.right(C, span[3], row, S.cell(item, column[1], column[3]))
    end
    C.put(x0 + 2, row, item.label:sub(1, math.max(0, right - x0 - 2)))
    S.hit(C, "item:" .. item.name, x0, row, x1 - x0 + 1, 1)
  end
end

S.titles = { all = "ALL ITEMS", low = "LOW STOCK", empty = "EMPTY" }

S.title = function(view)
  if view.screen == "search" then return "FIND" end
  if view.screen == "item" or view.screen == "home" then return nil end
  if view.list == "search" then return "FIND " .. view.search:upper() end
  for _, cat in ipairs(S.cats) do
    if view.list == "cat" and cat[1] == view.cat then return cat[2] end
  end
  return S.titles[view.list] or "SHOP"
end

S.list = function(C, m, view, w, h)
  local y = h >= 16 and 4 or 3
  local subs = S.subs(view, m)
  if subs then y = y + S.flow(C, w, y, subs, "sub:" .. view.sub, math.max(0, h - 3 - y)) end
  local split = w - 2 >= 90 and 2 or 1
  local width = math.floor((w - 2 - (split - 1)) / split)
  local per = math.max(0, h - 2 - y)
  local capacity = math.max(1, per * split)
  local pages = math.max(1, math.ceil(#m.items / capacity))
  local narrow = pages > 1 and w < 20
  view.page = math.max(1, math.min(view.page or 1, pages))
  view.capacity = capacity
  local nav = S.paged({ { "BACK", "back" } }, view.page, pages)
  if #m.items == 0 then
    S.table(C, 2, 1 + width, y, {}, view.sort, m.stale)
    C.center(1, w, y + 2, m.found and "No items" or "Storage room not found")
    return nav, narrow
  end
  local first = (view.page - 1) * capacity
  local rows = math.min(per, math.ceil(math.min(capacity, #m.items - first) / split))
  for c = 1, split do
    local slice = {}
    for i = 1, rows do slice[i] = m.items[first + (c - 1) * rows + i] end
    if c == 1 or slice[1] then
      local x0 = 2 + (c - 1) * (width + 1)
      S.table(C, x0, x0 + width - 1, y, slice, view.sort, m.stale)
    end
  end
  return nav, narrow
end

S.trendInk = function(item)
  return item.rate > 0 and "d" or item.rate < 0 and "1" or "b"
end

-- Title bar and sextant chart of the item's sampled hour.
S.chart = function(C, x, y, width, height, item)
  if width < 4 or height < 2 then return end
  C.fill(x, y, width, 1, "7")
  if #item.trend + 9 <= width then C.put(x + 1, y, "TREND") end
  S.right(C, x + width - 2, y, #item.trend <= width - 2 and item.trend or item.arrow)
  C.fill(x, y + 1, width, height - 1, "f")
  U.sparkline(C, x + 1, y + 1, width - 2, height - 1, item.samples, S.trendInk(item))
end

S.stockTile = function(C, m, item, x, y, width, height)
  local word = m.stale and "STALE STOCK" or item.state == "empty" and "EMPTY" or item.state == "low" and "LOW"
    or "IN STOCK"
  local bg = m.stale and "c" or ({ ok = "b", low = "1", empty = "e" })[item.state]
  local full, rest = math.floor(item.count / item.stack), item.count % item.stack
  local sub = ""
  if item.stack > 1 and full > 0 then sub = full .. " stacks" .. (rest > 0 and " + " .. rest or "") end
  C.tile(x, y, width, word, tostring(item.count), sub, bg, height)
end

S.amounts = function(item)
  return { { "1", "1" }, { "16", "16" }, { "64", "64" }, { "STACK", "stack" }, { "ALL", "all", item.count > 0 } }
end

S.orderButton = function(C, x, y, width, height, entry, item)
  if entry[3] == false then
    C.fill(x, y, width, height, "c")
    C.center(x + 1, math.max(0, width - 2), y + math.floor(height / 2), entry[1])
  else
    S.button(C, x, y, width, entry[1], "order:" .. entry[2] .. ":" .. item.name, "a", height)
  end
end

S.facts = function(item)
  local cat = item.cat:upper()
  for _, entry in ipairs(S.cats) do if entry[1] == item.cat then cat = entry[2] end end
  if item.cat ~= "other" then cat = cat .. " > " .. item.sub:upper() end
  local facts = { "STACK " .. item.stack, cat }
  if S.recipes[item.name] then facts[#facts + 1] = "CRAFT " .. S.recipes[item.name] end
  return facts
end

S.item = function(C, m, view, w, h)
  local item = m.selected
  local top = h >= 16 and 4 or 3
  local status = view.order or ""
  if view.orderDetail then status = status .. "  " .. view.orderDetail end
  local amounts = S.amounts(item)
  if h < 16 then
    local bottom = h - 2
    local tile = w >= 26 and math.max(13, #tostring(item.count) * 3 + 3) or w - 2
    S.stockTile(C, m, item, 2, top, tile, math.max(1, bottom - 1 - top))
    if w >= 26 then S.chart(C, tile + 3, top, w - tile - 4, bottom - 1 - top, item) end
    for i, col in ipairs(U.grid(w, h, #amounts)) do S.orderButton(C, col.x, bottom, col.w, 1, amounts[i], item) end
    C.put(2, h - 1, status:sub(1, math.max(0, w - 2)))
    return { { "BACK", "items" } }
  end
  if w < 39 then
    local th = h >= 20 and 7 or 6
    S.stockTile(C, m, item, 1, top, w, th)
    local buttons = h - 3
    S.chart(C, 2, top + th + 1, w - 2, buttons - 1 - (top + th + 1), item)
    local first, second = U.grid(w, h, 3), U.grid(w, h, 2)
    for i = 1, 3 do S.orderButton(C, first[i].x, buttons, first[i].w, 1, amounts[i], item) end
    for i = 1, 2 do S.orderButton(C, second[i].x, buttons + 1, second[i].w, 1, amounts[i + 3], item) end
    C.put(2, h - 1, status:sub(1, math.max(0, w - 2)))
    return { { "BACK", "items" } }
  end
  local cols = U.grid(w, h)
  local th = h >= 24 and 7 or 6
  S.stockTile(C, m, item, cols[1].x, top, cols[1].w, th)
  S.chart(C, cols[2].x, top, w - cols[2].x, th, item)
  local height = 3
  local buttons = h - 2 - height
  for i, col in ipairs(U.grid(w, h, #amounts)) do
    S.orderButton(C, col.x, buttons, col.w, height, amounts[i], item)
  end
  C.put(2, h - 2, status:sub(1, math.max(0, w - 2)))
  local lines = buttons - 1 - (top + th + 1)
  local facts = w >= 50 and cols[#cols].x + 1 or w
  for i, entry in ipairs(S.recent[item.name] or {}) do
    if i > lines then break end
    C.put(3, top + th + i, (entry.hm .. string.format("%6d", entry.n) .. "  " .. entry.status)
      :sub(1, math.max(0, facts - 5)))
  end
  for i, fact in ipairs(facts < w and S.facts(item) or {}) do
    if i > lines then break end
    C.put(facts, top + th + i, fact:sub(1, math.max(0, w - facts)))
  end
  return { { "BACK", "items" } }
end

S.keys = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

S.search = function(C, m, view, w, h)
  local found = 0
  local query = S.norm(view.search)
  for _, item in ipairs(m.all) do if S.match(item.name, query) then found = found + 1 end end
  local y = h >= 16 and 4 or 3
  C.fill(2, y, w - 2, 1, "0")
  C.put(3, y, (view.search:upper() .. "_"):sub(-math.max(1, w - 4)), "f", "0")
  local top = y + (h >= 16 and 2 or 1)
  local rows = h - 2 - top + 1
  local tall = math.max(1, math.min(5, math.floor((rows + 1) / 4) - 1))
  local gap = 4 * tall + 3 <= rows and 1 or 0
  local cols = U.grid(w, h, 7)
  for i = 1, 28 do
    local label = i <= 26 and S.keys:sub(i, i) or (i == 27 and "DEL" or "CLR")
    local col, y = cols[(i - 1) % 7 + 1], top + math.floor((i - 1) / 7) * (tall + gap)
    if y + tall - 1 <= h - 2 then S.button(C, col.x, y, col.w, label, "key:" .. label, "7", tall) end
  end
  local label = found .. " FOUND"
  return { { "BACK", "back" }, { U.grid(w, h, 2)[2].w >= #label and label or tostring(found), "found", "a" } }
end

S.layout = function(m, view, w, h)
  local C = U.canvas(w, h)
  if w < 4 or h < 5 then return C.frame() end
  if view.screen == "item" and not m.selected then view.screen = "list" end
  local title = S.title(view) or (view.screen == "item" and m.selected.label:upper()) or "SHOP"
  local right = w >= 26 and m.status or (m.stale and m.found and "STALE" or "")
  C.header(title:sub(1, math.max(0, w - 3 - #right)), right, "a")
  local page = view.screen == "list" and S.list or view.screen == "item" and S.item
    or view.screen == "search" and S.search or S.home
  -- Controls register last so content comes first in the button list.
  S.nav(C, w, h, page(C, m, view, w, h))
  return C.frame()
end

S.render = function(w, h, session)
  if not U then return S.legacy(w, h, session) end
  w, h = w or 57, h or 24
  local view = S.view(session)
  return S.layout(S.gather(session), view, w, h)
end

S.open = function(view, list, cat)
  view.screen, view.list, view.cat, view.sub, view.page, view.selected = "list", list, cat, "all", 1, nil
end

S.press = function(view, client, id)
  if id == "back" then
    id = view.screen == "item" and "items" or view.screen == "list" and view.list == "search" and "search" or "home"
  end
  if id == "home" or id == "search" then view.screen, view.selected = id, nil return end
  if id == "all" or id == "low" or id == "empty" then S.open(view, id) return end
  if id == "found" then S.open(view, "search") return end
  if id == "items" then view.screen, view.selected = view.from or "list", nil return end
  local cat = id:match("^cat:(%a+)$")
  for _, entry in ipairs(S.cats) do if entry[1] == cat then S.open(view, "cat", cat) return end end
  local sub = id:match("^sub:(.+)$")
  if sub then view.sub, view.page = sub, 1 return end
  local sort = id:match("^sort:(%a+)$")
  if S.sorts[sort] then view.sort, view.page = sort, 1 return end
  local key = id:match("^key:(%u+)$")
  if key == "DEL" then view.search = view.search:sub(1, -2)
  elseif key == "CLR" then view.search = ""
  elseif key and #key == 1 and #view.search < 16 then view.search = view.search .. key:lower() end
  if key then return end
  if id == "next" or id == "prev" then
    local step = id == "next" and 1 or -1
    if view.screen == "home" then view.home = math.max(1, (view.home or 1) + step)
    else
      local pages = math.max(1, math.ceil(#S.gather(client).items / (view.capacity or 1)))
      view.page = math.max(1, math.min(pages, view.page + step))
    end
    return
  end
  local name = id:match("^item:(.+)$")
  if name and (S.totals[name] ~= nil or S.history[name] ~= nil) then
    view.from = view.screen == "home" and "home" or "list"
    view.screen, view.selected, view.order, view.orderDetail, view.orderRid = "item", name, nil, nil, nil
    return
  end
  local amount, target = id:match("^order:(%w+):(.+)$")
  if not amount or view.screen ~= "item" or view.selected ~= target then return end
  local item = S.gather(client).selected
  local count = item and (amount == "stack" and item.stack or amount == "all" and item.count
    or (amount == "1" or amount == "16" or amount == "64") and tonumber(amount))
  if count and count >= 1 then S.request("order", target, count, view) end
end

S.input = function(event)
  local client = event.session or event.from
  local view = S.view(client)
  if type(event.text) == "string" then
    view.search = (event.text == " " or event.text == "*") and "" or event.text:sub(1, 32)
    view.page, view.selected, view.ordered = 1, nil, nil
    if U then S.open(view, "search") end
    return
  end
  if event.id == "clear" then view.search = ""; view.page, view.selected, view.ordered = 1, nil, nil; return end
  if type(event.id) ~= "string" then return end
  if U then return S.press(view, client, event.id) end
  local count, name = event.id:match("^order:(%d+):(.+)$")
  count = tonumber(count)
  if (count == 1 or count == 16 or count == 64) and S.totals[name] ~= nil then
    S.request("order", name, count, view)
  end
end

S.tick = function(now)
  local display = SO.mods.display
  if not S.registered and type(display) == "table" and type(display.screen) == "function" then
    display.screen("shop", S.render, S.input)
    S.registered = true
  end
  if S.turtle and now - (S.heardAt or S.selectedAt or now) >= S.staleAfter then
    S.turtle, S.heardAt, S.selectedAt, S.stockAt, S.lookupAt = nil, nil, nil, nil, nil
    S.totals, S.history, S.labels, S.stacks, S.tags, S.recipes, S.kinds = {}, {}, {}, {}, {}, {}, {}
    S.state = "waiting for stock"
    for rid, pending in pairs(S.pending) do
      if pending.kind == "stock" then S.pending[rid] = nil end
    end
  end
  if not S.turtle and (not S.lookupAt or now - S.lookupAt >= 10000) then
    S.lookupAt = now
    rednet.broadcast({ sType = "lookup", sProtocol = "roomsorter" }, "dns")
  end
  if S.turtle then
    if not S.stockAt or now - S.stockAt >= 10000 then
      S.stockAt = now
      S.request("stock")
    end
    S.sample(now)
  end
  for rid, pending in pairs(S.pending) do
    if now - pending.at >= 120000 then
      S.pending[rid] = nil
      if pending.kind == "order" and not pending.acknowledged then
        if rid == S.latestOrder then S.orders = { "reply timed out" } end
        if pending.entry then pending.entry.status = "failed" end
        if pending.view and pending.view.orderRid == rid then pending.view.order = "Order: failed, timed out" end
      end
    end
  end
end

return {
  name = "shop",
  handlers = {},
  listen = { roomsorter = S.reply, roomsorter_stock = S.broadcast, dns = S.dns },
  tick = S.tick,
  order = S.order,
  matches = S.matches,
  best = S.best,
}
