-- Server-owned shop screen for the existing Storage Room turtle.
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

local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end

-- Amsterdam time of the newest stock plus the elapsed server time since.
S.wall = function()
  if not U or not S.heardDate then return "--:--" end
  return U.clock(S.heardDate + SO.now() - S.heardAt).hm
end

S.request = function(kind, name, count, view, reservedRid)
  if not S.turtle then
    if view then view.order = "Order: failed, storage room not found" end
    return nil, "storage room missing"
  end
  S.rid = reservedRid or S.rid + 1
  local rid = S.rid
  local pending = { kind = kind, sender = S.turtle, at = SO.now(), view = view }
  S.pending[rid] = pending
  if kind == "order" then
    S.latestOrder = rid
    S.orders = { "sent " .. tostring(count) .. " " .. name }
    -- Only orders from a shop display are listed under the item; shop.order leaves displays alone.
    local list = view and (S.recent[name] or {})
    if list then
      S.recent[name] = list
      pending.entry = { hm = S.wall(), n = count, status = "sent" }
      table.insert(list, 1, pending.entry)
      if #list > 8 then table.remove(list) end
    end
    if view then
      view.order, view.orderDetail, view.orderRid = "Order: sent " .. count, nil, rid
    end
  end
  local ok = rednet.send(S.turtle, { cmd = kind, text = name, n = count, rid = rid }, "roomsorter")
  if ok == false then
    S.pending[rid] = nil
    if kind == "order" then
      S.orders = { "failed: send failed" }
      if pending.entry then pending.entry.status = "failed" end
      if view then view.order, view.orderDetail = "Order: failed", "send failed" end
    end
    return nil, "send failed"
  end
  return rid
end

S.fuelPointOk = function(point)
  if type(point) ~= "table" or type(point.id) ~= "string" then return false end
  if point.dim ~= 0 and point.dim ~= -1 and point.dim ~= 1
      and point.dim ~= "minecraft:overworld" and point.dim ~= "minecraft:the_nether" and point.dim ~= "minecraft:the_end" then return false end
  for _, key in ipairs({"x","y","z"}) do
    local n = point[key]
    if type(n) ~= "number" or n ~= n or math.abs(n) == math.huge or n % 1 ~= 0 then return false end
  end
  return point.side == "front" or point.side == "down"
end
S.fuelBox = SO.store and SO.store.store and SO.store.store("so-data/fuel-policy", function(v)
  if type(v) ~= "table" or type(v.auto) ~= "boolean" or type(v.cooldowns) ~= "table" then return false end
  if v.output ~= nil and not S.fuelPointOk(v.output) then return false end
  if v.waiting ~= nil and (type(v.waiting) ~= "table" or not S.fuelPointOk(v.waiting.point)
      or type(v.waiting.at) ~= "number" or v.waiting.at ~= v.waiting.at or v.waiting.at < 0 or v.waiting.at == math.huge) then return false end
  if v.alert ~= nil and (type(v.alert) ~= "table" or type(v.alert.reason) ~= "string" or type(v.alert.text) ~= "string") then return false end
  if v.serial ~= nil and (type(v.serial) ~= "number" or v.serial ~= v.serial or v.serial < 0
      or v.serial >= 2^53 or v.serial % 1 ~= 0) then return false end
  if v.waiting and (type(v.waiting.rid) ~= "number" or v.waiting.rid ~= v.serial
      or type(v.waiting.sender) ~= "number" or v.waiting.sender < 0 or v.waiting.sender % 1 ~= 0) then return false end
  local n = 0
  for key, at in pairs(v.cooldowns) do
    n = n + 1
    if type(key) ~= "string" or type(at) ~= "number" or at ~= at or at < 0 or at == math.huge then return false end
  end
  return n <= 64
end) or {save=function() return false,"store unavailable" end}
S.fuel = S.fuelBox.value or {auto=false,cooldowns={}}
S.rid = S.fuel.serial or 0
S.fuelKey = function(point)
  if not point then return end
  local dim = ({["minecraft:overworld"]=0,["minecraft:the_nether"]=-1,["minecraft:the_end"]=1})[point.dim] or point.dim
  return table.concat({tostring(dim),tostring(point.x),tostring(point.y),tostring(point.z)}, "/")
end
S.fuelSave = function(nextPolicy)
  local hadAlert = S.fuel.alert ~= nil
  local ok, err = S.fuelBox.save(nextPolicy)
  if ok then S.fuel, S.fuelSaveError = nextPolicy, nil
  else S.fuelSaveError = "fuel policy save failed: " .. tostring(err) end
  if ok and hadAlert and not nextPolicy.alert then
    local state = SO.mods.state
    if state and state.emit then state.emit("shop.alert",false) end
  end
  return ok, err
end
S.fuelAlert = function(reason, point, failed)
  reason = tostring(reason):sub(1,160)
  local text = "Fuel " .. reason .. " #" .. tostring(point and point.id or "output"):sub(1,64)
  if S.fuel.alert and S.fuel.alert.text == text and not (failed and S.fuel.waiting) then return end
  local nextPolicy = SO.store.copy(S.fuel)
  nextPolicy.alert = {reason=reason,text=text,point=point}
  local waiting = S.fuel.waiting
  if failed then nextPolicy.waiting = nil end
  if not S.fuelSave(nextPolicy) then return false end
  if failed and waiting then S.pending[waiting.rid] = nil end
  local state = SO.mods.state
  if state and state.emit then state.emit("shop.alert", nextPolicy.alert) end
  return true
end
S.fuelConfig = function(auto, output)
  if auto == nil and output == nil then return SO.store.copy(S.fuel) end
  local nextPolicy = SO.store.copy(S.fuel)
  if auto ~= nil then nextPolicy.auto = auto == true end
  if output ~= nil then
    local drops = SO.mods.drops
    local picked
    for _, p in ipairs(drops and drops.list and drops.list() or {}) do
      if p.id == output and p.kind == "fuel" and not p.broken then picked = p break end
    end
    if not picked then return false, "fuel output point missing or broken" end
    nextPolicy.output = picked
  end
  if not nextPolicy.waiting then nextPolicy.alert = nil end
  return S.fuelSave(nextPolicy)
end
S.fuelClear = function()
  local waiting = S.fuel.waiting
  if not waiting and not S.fuel.alert then return true end
  local nextPolicy = SO.store.copy(S.fuel)
  nextPolicy.waiting, nextPolicy.alert = nil, nil
  local ok, err = S.fuelSave(nextPolicy)
  if ok and waiting then S.pending[waiting.rid] = nil end
  return ok, err
end
S.fuelAvailable = function(point, orderRid)
  local waiting = S.fuel.waiting
  if orderRid ~= nil and (waiting and waiting.rid ~= orderRid or not waiting and orderRid ~= false) then return end
  local expected = S.fuel.waiting and S.fuel.waiting.point or S.fuel.output
  if S.fuelKey(point) ~= S.fuelKey(expected) then return end
  return S.fuelClear()
end
S.fuelEmpty = function(point)
  if not S.fuel.auto or not S.fuelPointOk(point) then return false end
  if not S.fuel.output then S.fuelAlert("output not set", point) return false end
  local key, now = S.fuelKey(point), SO.now()
  if key ~= S.fuelKey(S.fuel.output) then return false end
  if S.fuel.waiting then return true, "waiting" end
  if now < (S.fuel.cooldowns[key] or 0) then return true, "cooldown" end
  if not S.turtle then S.fuelAlert("storage room missing",point) return true end
  if not S.heardAt or now - S.heardAt >= 30000 then S.fuelAlert("stock stale",point) return true end
  local name
  for _, fuel in ipairs({"minecraft:charcoal","minecraft:coal"}) do
    if (S.totals[fuel] or 0) >= 64 then name = fuel break end
  end
  if not name then S.fuelAlert("stock below 64",point) return true end
  local nextPolicy = SO.store.copy(S.fuel)
  local count = 0
  for saved, untilAt in pairs(nextPolicy.cooldowns) do
    if untilAt <= now then nextPolicy.cooldowns[saved] = nil else count = count + 1 end
  end
  if not nextPolicy.cooldowns[key] and count >= 64 then S.fuelAlert("cooldown ledger full",point) return true end
  nextPolicy.cooldowns[key] = now + 600000
  nextPolicy.serial = S.rid + 1
  nextPolicy.waiting = {at=now,point=SO.store.copy(point),rid=nextPolicy.serial,sender=S.turtle}
  nextPolicy.alert = nil
  -- Save before sending so a power cut cannot repeat the order.
  if not S.fuelSave(nextPolicy) then return true end
  local rid, err = S.request("order", name, 64, nil, nextPolicy.serial)
  if not rid then S.fuelAlert(err,point,true) end
  return true
end
S.fuelAlerts = function()
  if S.fuelSaveError then return {{reason="save failed",text=S.fuelSaveError}} end
  if S.fuel.auto and S.fuel.alert then return {SO.store.copy(S.fuel.alert)} end
  return {}
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
      if table.concat(list, " ") ~= table.concat(S.tags[name] or {}, " ") then S.kinds[name] = nil end
      S.tags[name] = list
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
  if pending and pending.sender ~= sender then pending = nil end
  local waiting = S.fuel.waiting
  local fuelReply = waiting and waiting.rid == message.rid and waiting.sender == sender
  if not pending and not fuelReply then return end
  if pending and pending.kind == "stock" then
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
    if fuelReply then
      if status == "failed" then
        local refused = lower:match("^not in storage") or lower:match("^none in storage")
          or lower:match("^not enough") or lower:match("^which one") or lower:match("^refused") or lower:match("^failed")
        S.fuelAlert((refused and "order refused: " or "reply unconfirmed: ") .. (text ~= "" and text or "empty reply"), waiting.point, refused)
      elseif status == "delivered" then S.fuelAvailable(waiting.point) end
    end
    if pending then
      if status == "sent" then pending.acknowledged = true
      else S.pending[message.rid] = nil end
      if pending.entry then pending.entry.status = status end
    end
    if pending and pending.view and pending.view.orderRid == message.rid then
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

-- One sample per minute and item, 60 kept. An item gone from stock for the whole hour is forgotten.
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
    S.views[key] = { search = "", page = 1, sort = "count", tab = "items", cat = "all", sub = "all", low = "all" }
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

-- An exact id keeps its stock count, including zero; other searches use the first match.
S.best = function(search)
  if type(search) ~= "string" or search == "" then return nil end
  if S.totals[search] ~= nil then return search, S.totals[search] end
  local best = S.matches(search, 1)[1]
  if best and best.count > 0 then return best.name, best.count end
  return nil
end

-- One order for the best match: 1, 16, 64, "stack" (its stack size) or "all" (its stock). Returns the
-- item and count sent, or nil and a reason. Changes no display's screen state; a given view gets the
-- order status and reply the way a shop display's view does.
S.order = function(search, count, view)
  local name, stock = S.best(search)
  if count == "stack" or count == "all" then
    if not name then return nil, "no match" end
    count = count == "stack" and S.stackOf(name, S.kind(name)) or stock
  elseif count ~= 1 and count ~= 16 and count ~= 64 then return nil, "bad count" end
  if not name then return nil, "no match" end
  if stock <= 0 then return nil, "out of stock" end
  local rid, err = S.request("order", name, count)
  if not rid then return nil, err end
  if type(view) == "table" then
    S.pending[rid].view = view
    view.order, view.orderDetail, view.orderRid = "Order: sent " .. count, nil, rid
  end
  return name, count
end

S.legacy = function(_w, _h, clientId)
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

-- Categories in chip order with their sub ids. MODS has one sub per namespace present.
S.cats = {
  { "ores", "ore raw ingot nugget block gem dust" },
  { "wood", "log planks sapling crafted" },
  { "stone", "stone earth build" },
  { "plants", "leaves seeds flowers plants" },
  { "food", "crops meat meals" },
  { "tools", "tools weapons armour" },
  { "redstone", "dust logic motion" },
  { "mobs", "hostile passive" },
  { "mods", "" },
  { "other", "" },
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

-- Category and sub of an item id, from the rules, then its tags, then its namespace.
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
    list[#list + 1] = { name = name, label = S.label(name), count = count, stack = stack, cat = cat, sub = sub,
      rate = delta < 0 and -rate or rate,
      state = count == 0 and "empty" or count < math.min(16, stack) and "low" or "ok" }
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

-- The shown list for this display: its tab's filter in its sort, plus the selected item.
S.gather = function(client)
  local view = S.view(client)
  local m = { found = S.turtle ~= nil, all = S.items(), items = {}, recipes = S.recipes,
    stale = S.heardAt == nil or SO.now() - S.heardAt >= 30000, time = "-" }
  if S.heardAt then m.time = U and U.clock(S.heardDate).hm or "-" end
  local query = S.norm(view.search)
  for _, item in ipairs(m.all) do
    local keep
    if view.tab == "low" then keep = item.state ~= "ok" and (view.low == "all" or item.state == view.low)
    elseif view.tab == "find" then keep = S.match(item.name, query)
    else keep = (view.cat == "all" or item.cat == view.cat) and (view.sub == "all" or item.sub == view.sub) end
    if keep then m.items[#m.items + 1] = item end
    if item.name == view.selected then m.selected = item end
  end
  table.sort(m.items, S.sorts[view.sort] or S.sorts.count)
  m.recent = m.selected and S.recent[m.selected.name] or {}
  return m
end

-- Sub chips of the open category: its table, or one per mod namespace by item count.
S.subs = function(view, m)
  local subs = { { "sub:all", "all" } }
  for _, cat in ipairs(S.cats) do
    if cat[1] == view.cat then
      for sub in cat[2]:gmatch("%S+") do subs[#subs + 1] = { "sub:" .. sub, sub } end
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
    for _, space in ipairs(spaces) do subs[#subs + 1] = { "sub:" .. space, space:sub(1, 10) } end
  end
  return #subs > 1 and subs or nil
end

-- Route A layout. docs/ui/schematic/shop.py is its twin and writes the fixtures; change both.
S.tabs = { "items", "low", "find" }
S.keys = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
S.marks = { sent = "d", delivered = "8", failed = "e" }
S.most, S.budget = 32, 15000

S.stateFg = function(item)
  return item.state == "empty" and "8" or item.state == "low" and "1" or "0"
end

-- Header row: the kit bar when SHOP, the tabs and the right word fit, else the tabs alone.
-- The time gives way first; a stale word that still does not fit moves to the footer (m.note).
S.head = function(C, m, view, w)
  local word = not m.found and "missing" or m.stale and "stale" or "stock"
  local rfg = not m.found and "e" or m.stale and "1" or "8"
  local right = word == "missing" and word or w >= 52 and word .. " " .. m.time or word == "stock" and m.time or word
  if w < 31 + #right then right = word == "stock" and "" or word end
  if w >= 31 + #right or (w >= 29 and right == "") then return C.bar("SHOP", S.tabs, view.tab, right, rfg) end
  if w < 23 + #right then m.note, right = word == "stale", "" end
  local x = 1
  for _, t in ipairs(S.tabs) do
    local label = " " .. t .. " "
    if t == view.tab then C.put(x, 1, label, "0", "7") else C.put(x, 1, label, "8") end
    C.hit("tab:" .. t, x, 1, #label, 1, t)
    x = x + #label + 1
  end
  local last = w - #right - 1
  if right ~= "" then C.put(last + 1, 1, right, rfg) end
  C.rule(x, 1, last - 1)
end

S.note = function(C, m, x, y)
  if m.note then C.put(x, y, "stale", "1") end
end

-- Chips left to right with one cell between, wrapping at x2. Returns the rows used; dry only counts.
S.flow = function(C, x1, x2, y, entries, active, dry)
  local x, rows = x1, 1
  for _, entry in ipairs(entries) do
    if x > x1 and x + #entry[2] + 1 > x2 then x, rows = x1, rows + 1 end
    if dry then x = x + #entry[2] + 3
    else x = C.chip(x, y + rows - 1, entry[2], entry[1], entry[1] == active and "plain" or "off") + 1 end
  end
  return rows
end

-- The column head is the sort control: item, stock and /h; the active one is a chip with a down arrow.
S.sorter = function(C, x, y, lw, view, trend)
  for _, s in ipairs({ { "item", "name", x - 1, x }, { "stock", "count", x + lw - 8, x + lw - 5 },
      { "/h", "trend", x + lw + 1, x + lw + 2 } }) do
    if s[2] ~= "trend" or trend then
      if view.sort == s[2] then C.chip(s[3], y, s[1] .. " " .. U.g.down, "sort:" .. s[2])
      else
        C.put(s[4], y, s[1], "8")
        C.hit("sort:" .. s[2], s[4], y, #s[1], 1, s[1])
      end
    end
  end
end

S.line = function(C, x, y, cw, item, trend, selected)
  if selected then C.fill(x - 1, y, cw + 2, 1, "7") end
  local lw = trend and cw - 7 or cw
  C.leader(x, y, lw, item.label:upper(), tostring(item.count), S.stateFg(item), "0")
  if trend and item.rate ~= 0 then
    local up = item.rate > 0
    C.put(x + lw + 2, y, (up and "\24" or "\25") .. S.short(math.abs(item.rate)), up and "8" or "1")
  end
  C.hit("item:" .. item.name, x, y, cw, 1, item.label:upper())
end

S.pages = function(C, m, w, h, page, count)
  local text = page .. " of " .. count
  C.put(2, h, text, "8")
  S.note(C, m, 3 + #text, h)
  S.chip(C, w - 11, h, U.g.left, "prev", page > 1, 5)
  S.chip(C, w - 5, h, U.g.right, "next", page < count, 5)
end

-- A chip that does nothing now is drawn muted and has no target.
S.chip = function(C, x, y, label, id, on, width)
  if on then return C.chip(x, y, label, id, "plain", width) end
  width = width or #label + 2
  C.put(x, y, string.rep(" ", width), "8", "7")
  C.put(x + math.max(0, math.floor((width - #label) / 2)), y, label:sub(1, width), "8", "7")
  return x + width
end

-- The item: name, facts as leaders, ORDER chips, then the recent orders.
S.pane = function(C, m, item, x, y, pw, bottom, close)
  local tall = bottom - y + 1 >= 13
  C.put(x, y, item.label:upper():sub(1, pw - (close and 3 or 0)), "0")
  if close then
    C.put(x + pw - 1, y, "\215", "8")
    C.hit("items", x + pw - 3, y, 3, 1, "\215")
  end
  y = y + (tall and 2 or 1)
  local facts = { { "stock", tostring(item.count), S.stateFg(item) } }
  if tall and item.stack > 1 then
    local full, rest = math.floor(item.count / item.stack), item.count % item.stack
    facts[#facts + 1] = { "stacks", full .. (rest > 0 and "+" .. rest or ""), "0" }
  end
  local rate = item.rate
  facts[#facts + 1] = { "last hour", rate == 0 and "0" or (rate > 0 and "\24" or "\25") .. S.short(math.abs(rate)),
    rate < 0 and "1" or rate > 0 and "0" or "8" }
  if tall and item.sub ~= item.cat then facts[#facts + 1] = { item.cat, item.sub, "0" } end
  if tall and (m.recipes[item.name] or 0) > 0 then facts[#facts + 1] = { "craftable", tostring(m.recipes[item.name]), "0" } end
  for _, fact in ipairs(facts) do
    C.leader(x, y, pw, fact[1], fact[2], fact[3])
    y = y + 1
  end
  if tall then y = y + 1 end
  C.section(x, y, pw, "ORDER")
  local cw, cw2 = math.floor((pw - 2) / 3), math.floor((pw - 1) / 2)
  for i, n in ipairs({ "1", "16", "64" }) do
    S.chip(C, x + (i - 1) * (cw + 1), y + 1, n, "order:" .. n .. ":" .. item.name, m.found, cw)
  end
  for i, n in ipairs({ "stack", "all" }) do
    S.chip(C, x + (i - 1) * (cw2 + 1), y + 2, n, "order:" .. n .. ":" .. item.name,
      m.found and (n ~= "all" or item.count > 0), cw2)
  end
  y = y + (tall and 4 or 3)
  for _, e in ipairs(m.recent) do
    if y > bottom then break end
    C.put(x, y, U.g.bullet, S.marks[e.status] or "e")
    C.put(x + 2, y, (e.n .. " " .. e.status):sub(1, math.max(0, pw - 8)), "0")
    C.put(x + pw - #e.hm, y, e.hm, "8")
    y = y + 1
  end
  return y - 1
end

-- Narrow screens pick a category or sub from leader rows with item counts.
S.picker = function(C, m, view, y, w, bottom)
  local counts = {}
  for _, item in ipairs(m.all) do
    local keys = { "cat:all", "cat:" .. item.cat }
    if item.cat == view.cat then keys[3], keys[4] = "sub:all", "sub:" .. item.sub end
    for _, key in ipairs(keys) do counts[key] = (counts[key] or 0) + 1 end
  end
  local entries, active = { { "cat:all", "all" } }, "cat:" .. view.cat
  if view.pick == "cats" then
    for _, cat in ipairs(S.cats) do entries[#entries + 1] = { "cat:" .. cat[1], cat[1] } end
  else entries, active = S.subs(view, m) or {}, "sub:" .. view.sub end
  -- Columns stay 12 cells or wider; entries past the last column are left out (mods by count).
  local n = math.max(1, bottom - y + 1)
  local cols = math.max(1, math.min(math.ceil(#entries / n), math.floor(w / 14)))
  local cw = math.floor((w - 2 - 2 * (cols - 1)) / cols)
  for i = #entries, n * cols + 1, -1 do entries[i] = nil end
  for i, entry in ipairs(entries) do
    local x, ry = 2 + math.floor((i - 1) / n) * (cw + 2), y + (i - 1) % n
    if entry[1] == active then C.fill(x - 1, ry, cw + 2, 1, "7") end
    C.leader(x, ry, cw, entry[2], tostring(counts[entry[1]] or 0), "0", "0")
    C.hit(entry[1], x, ry, cw, 1, entry[2])
  end
end

-- The controls above the list for the open tab. Returns the next free row.
S.controls = function(C, m, view, w, y, gap, wide, bottom)
  if view.tab == "items" and wide then
    local cats = { { "cat:all", "all" } }
    for _, cat in ipairs(S.cats) do cats[#cats + 1] = { "cat:" .. cat[1], cat[1] } end
    y = y + S.flow(C, 2, w - 1, y, cats, "cat:" .. view.cat)
    local subs = view.cat ~= "all" and S.subs(view, m)
    -- More subs than two rows hold (many mod namespaces) open the picker instead.
    if subs and S.flow(C, 2, w - 1, y, subs, nil, true) > 2 then
      C.chip(2, y + gap, view.sub .. " " .. U.g.down, "pick:subs", view.pick == "subs" and "on" or "plain")
      y = y + gap + 1
    elseif subs then y = y + gap + S.flow(C, 2, w - 1, y + gap, subs, "sub:" .. view.sub) end
  elseif view.tab == "items" then
    local x = C.chip(2, y, view.cat .. " " .. U.g.down, "pick:cats", view.pick == "cats" and "on" or "plain")
    if view.cat ~= "all" and S.subs(view, m) then
      C.chip(x + 1, y, view.sub .. " " .. U.g.down, "pick:subs", view.pick == "subs" and "on" or "plain")
    end
    y = y + 1
  elseif view.tab == "low" then
    y = y + S.flow(C, 2, w - 1, y, { { "low:all", "all" }, { "low:low", "low" }, { "low:empty", "empty" } },
      "low:" .. view.low)
  else
    C.chip(C.chip(w - 12, y, "del", "key:DEL") + 1, y, "clr", "key:CLR")
    C.put(2, y, ">", "8")
    C.put(4, y, view.search:upper():sub(-math.max(1, w - 19)), "0")
    if view.keys then C.put(4 + math.min(#view.search, math.max(1, w - 19)), y, "_", "8") end
    if w > 15 then C.hit("keys", 2, y, w - 15, 1, ">") end
    y = y + 1
    if view.keys then
      local per = math.max(1, math.min(13, math.floor((w - 1) / 4)))
      for i = 1, #S.keys do
        local k, ky = S.keys:sub(i, i), y + gap + math.floor((i - 1) / per)
        if ky <= bottom then C.chip(2 + (i - 1) % per * 4, ky, k, "key:" .. k) end
      end
      y = y + gap + math.ceil(#S.keys / per)
    end
  end
  return y + gap
end

S.layout = function(m, view, w, h, most)
  local C = U.canvas(w, h)
  S.head(C, m, view, w)
  local gap = h >= 16 and 1 or 0
  local y, bottom, wide, item = 2 + gap, h - 1 - gap, w >= 52, m.selected
  view.capacity = nil
  if item and not wide then
    S.pane(C, m, item, 2, y, w - 2, bottom, false)
    S.note(C, m, C.chip(2, h, "back", "items") + 1, h)
    return C.frame()
  end
  y = S.controls(C, m, view, w, y, gap, wide, bottom)
  if view.pick and view.tab == "items" and (not wide or view.pick == "subs") then
    S.picker(C, m, view, y, w, bottom)
    S.note(C, m, C.chip(2, h, "back", "back") + 1, h)
    return C.frame()
  end
  local cols, cw, trend, top, rx, last
  if item then
    rx = w - math.min(40, math.max(24, math.floor(w * 0.42))) - 2
    last = S.pane(C, m, item, rx + 2, y, w - rx - 2, bottom, true)
    cols, cw, trend, top = 1, rx - 3, false, y
  else
    cols = w >= 90 and 2 or 1
    cw = math.floor((w - 2 - 3 * (cols - 1)) / cols)
    trend, top = cw >= 36, y + 1
    for c = 1, cw >= 14 and cols or 0 do S.sorter(C, 2 + (c - 1) * (cw + 3), y, trend and cw - 7 or cw, view, trend) end
  end
  -- A page holds at most `most` items (S.most), which keeps the biggest walls under the frame budget.
  local n = math.min(math.max(0, bottom - top + 1), math.floor((most or S.most) / cols))
  local per = math.max(1, n * cols)
  local count = math.max(1, math.ceil(#m.items / per))
  view.page = math.max(1, math.min(view.page or 1, count))
  view.capacity = per
  if not m.found then
    C.put(2, top, "!", "e")
    C.put(4, top, ("storage room not found"):sub(1, math.max(0, w - 4)), "0")
  elseif #m.items == 0 then
    C.put(2, top, "no items", "8")
  end
  local first = (view.page - 1) * per
  local shown = n > 0 and math.min(per, #m.items - first) or 0
  local rows = math.max(1, math.min(n, math.ceil(shown / cols)))
  for i = 0, shown - 1 do
    local x = 2 + math.floor(i / rows) * (cw + 3)
    if i >= rows and i % rows == 0 then
      for ry = y, top + rows - 1 do C.put(x - 2, ry, "|", "c") end
    end
    local entry = m.items[first + i + 1]
    S.line(C, x, top + i % rows, cw, entry, trend, item ~= nil and entry.name == item.name)
  end
  for ry = y, item and math.max(last, shown > 0 and top + rows - 1 or y) or 0 do C.put(rx, ry, "|", "c") end
  S.pages(C, m, w, h, view.page, count)
  return C.frame()
end

-- Long item names on big walls can still pass the frame budget; redraw with fewer items a page.
S.render = function(w, h, session)
  if not U then return S.legacy(w, h, session) end
  w, h = w or 57, h or 24
  local m, view, most = S.gather(session), S.view(session), S.most
  local frame = S.layout(m, view, w, h, most)
  local ser = type(SO.proto) == "table" and SO.proto.ser
  while ser and most > 8 and #ser(frame) > S.budget do
    most = most - 8
    frame = S.layout(m, view, w, h, most)
  end
  return frame
end

-- One shop tap. Tabs, categories, subs, sorts and searches reset the page and close the item.
S.press = function(view, client, id)
  local tab, cat, sub = id:match("^tab:(%a+)$"), id:match("^cat:(%a+)$"), id:match("^sub:(.+)$")
  local known = cat == "all"
  for _, entry in ipairs(S.cats) do known = known or entry[1] == cat end
  if tab == "items" or tab == "low" or tab == "find" or known or sub or id:match("^low:") or id:match("^sort:") then
    view.page, view.selected, view.pick = 1, nil, nil
  end
  if tab == "items" or tab == "low" or tab == "find" then
    view.tab = tab
    if tab == "find" then view.keys = true end
  elseif known then view.tab, view.cat, view.sub = "items", cat, "all"
  elseif sub then
    -- Only a sub of the open category; a tap from an older frame is dropped.
    for _, entry in ipairs(S.subs(view, S.gather(client)) or {}) do
      if entry[1] == id then view.sub = sub end
    end
  elseif id == "low:all" or id == "low:low" or id == "low:empty" then view.low = id:sub(5)
  elseif id == "pick:cats" or id == "pick:subs" then
    local pick = id:sub(6)
    view.pick = view.pick ~= pick and pick or nil
  elseif id == "back" then view.pick = nil
  elseif id == "keys" then view.keys = not view.keys
  elseif id:match("^sort:") then
    if S.sorts[id:sub(6)] then view.sort = id:sub(6) end
  elseif id == "items" then view.selected = nil
  elseif id == "next" or id == "prev" then
    local count = math.max(1, math.ceil(#S.gather(client).items / (view.capacity or 1)))
    view.page = math.max(1, math.min(count, (view.page or 1) + (id == "next" and 1 or -1)))
  end
  local key = id:match("^key:(%u+)$")
  if key then
    view.page, view.selected = 1, nil
    if key == "DEL" then view.search = view.search:sub(1, -2)
    elseif key == "CLR" then view.search = ""
    elseif #key == 1 and #view.search < 16 then view.search = view.search .. key:lower() end
  end
  local name = id:match("^item:(.+)$")
  if name and (S.totals[name] ~= nil or S.history[name] ~= nil) then
    view.selected = view.selected ~= name and name or nil
    view.order, view.orderDetail, view.orderRid = nil, nil, nil
  end
  local amount, target = id:match("^order:(%w+):(.+)$")
  if not amount or view.selected ~= target then return end
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
    view.page, view.selected, view.pick, view.keys = 1, nil, nil, false
    if U then view.tab = "find" end
    return
  end
  if event.id == "clear" then view.search = ""; view.page, view.selected = 1, nil; return end
  if type(event.id) ~= "string" then return end
  if U then return S.press(view, client, event.id) end
  local count, name = event.id:match("^order:(%d+):(.+)$")
  count = tonumber(count)
  if (count == 1 or count == 16 or count == 64) and S.totals[name] ~= nil then
    S.request("order", name, count, view)
  end
end

S.tick = function(now)
  if S.fuel.auto and S.fuel.waiting and now - S.fuel.waiting.at >= 120000 then
    S.fuelAlert("fuel order timed out", S.fuel.waiting.point, true)
  end
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
    local timeout = pending.acknowledged and 600000 or 120000
    if now - pending.at >= timeout then
      S.pending[rid] = nil
      if pending.kind == "order" then
        local reason = pending.acknowledged and "no delivery" or "timed out"
        if rid == S.latestOrder then S.orders = { pending.acknowledged and reason or "reply timed out" } end
        if pending.entry then pending.entry.status = "failed" end
        if pending.view and pending.view.orderRid == rid then
          pending.view.order, pending.view.orderDetail = "Order: failed, " .. reason, reason
        end
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
  fuelConfig = S.fuelConfig,
  fuelEmpty = S.fuelEmpty,
  fuelAvailable = S.fuelAvailable,
  fuelClear = S.fuelClear,
  fuelAlerts = S.fuelAlerts,
}
