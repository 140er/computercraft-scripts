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
}

S.request = function(kind, name, count, view)
  if not S.turtle then
    if view then view.order = "Order: failed, storage room not found" end
    return
  end
  S.rid = S.rid + 1
  local rid = S.rid
  S.pending[rid] = { kind = kind, sender = S.turtle, at = os.epoch("utc"), view = view }
  if kind == "order" then
    S.latestOrder = rid
    S.orders = { "sent " .. tostring(count) .. " " .. name }
    if view then
      view.order, view.orderDetail, view.orderRid = "Order: sent " .. count, nil, rid
    end
  end
  rednet.send(S.turtle, { cmd = kind, text = name, n = count, rid = rid }, "roomsorter")
end

S.stock = function(message)
  if type(message.totals) == "table" then
    S.heardAt = os.epoch("utc")
    local totals = {}
    for name, count in pairs(message.totals) do
      if type(name) == "string" and type(count) == "number" and count >= 0
          and count < math.huge then totals[name] = count end
    end
    S.totals = totals
  end
  if type(message.state) == "string" then S.state = message.state end
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
    if pending.view and pending.view.orderRid == message.rid then
      pending.view.order = "Order: " .. status
      pending.view.orderDetail = text ~= "" and text or "empty reply"
    end
  end
end

S.broadcast = function(sender, message)
  if type(message) ~= "table" or type(message.totals) ~= "table" then return end
  if not S.turtle then S.turtle = sender S.selectedAt = os.epoch("utc") end
  if sender == S.turtle then S.stock(message) end
end

S.dns = function(sender, message)
  if not S.turtle and type(message) == "table" and message.sType == "lookup response"
      and message.sProtocol == "roomsorter" then
    S.turtle = sender
    S.selectedAt = os.epoch("utc")
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
  if not S.views[key] then S.views[key] = { search = "", page = 1, category = "all", sort = "count" } end
  return S.views[key]
end

S.order = function(search, count)
  if type(search) ~= "string" or (count ~= 1 and count ~= 16 and count ~= 64) then return end
  local query, best = search:lower():gsub("%s+", "_"), nil
  for name, stock in pairs(S.totals) do
    if name:lower():find(query, 1, true) and (not best or stock > S.totals[best]
        or (stock == S.totals[best] and name < best)) then best = name end
  end
  if best then S.request("order", best, count) end
end

S.legacy = function(w, h, clientId)
  local search = S.view(clientId).search
  local picture = {
    rows = {},
    buttons = {
      { id = "generic", x = 1, y = 1, w = 7, label = "generic" },
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

local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end

S.categories = {
  {"all", "ALL"}, {"ores", "ORES", {"ore", "ingot", "nugget", "raw_", "diamond", "emerald", "coal", "redstone", "lapis", "quartz"}},
  {"wood", "WOOD", {"log", "planks", "wood", "stem", "hyphae", "sapling", "stick"}},
  {"food", "FOOD", {"apple", "bread", "carrot", "potato", "beef", "porkchop", "chicken", "mutton", "fish", "cod", "salmon", "melon", "berry", "berries", "cookie", "stew", "wheat"}},
  {"blocks", "BLOCKS", {"stone", "dirt", "sand", "gravel", "brick", "glass", "concrete", "terracotta", "wool", "block", "deepslate", "obsidian", "netherrack"}},
  {"tools", "TOOLS", {"pickaxe", "axe", "shovel", "hoe", "sword", "bow", "shield", "shears", "bucket", "fishing_rod", "helmet", "chestplate", "leggings", "boots"}},
  {"other", "OTHER"},
}

S.category = function(name)
  local id = name:gsub("^.-:", "")
  for _, index in ipairs({6, 2, 3, 4, 5}) do
    local category = S.categories[index]
    for _, part in ipairs(category[3] or {}) do
      if id:find(part, 1, true) then return category[1] end
    end
  end
  return "other"
end

S.measurements = {}
S.metrics = function(h)
  if S.measurements[h] then return S.measurements[h] end
  local probe = U.canvas(16, math.max(8, h))
  probe.header("SHOP", "", "a")
  local header = 1
  for y, row in ipairs(probe.frame().rows) do
    if row.text:find("SHOP", 1, true) then header = y break end
  end
  probe = U.canvas(16, math.max(8, h))
  probe.tile(1, 1, 16, "", "", "", "d")
  local tile = 5
  for y, row in ipairs(probe.frame().rows) do
    for _, run in ipairs(row.runs) do
      if run[3] == "d" then tile = y break end
    end
  end
  local metrics = { header = header, tile = h < 16 and 5 or tile }
  S.measurements[h] = metrics
  return metrics
end

S.geometry = function(w, h)
  local metrics = S.metrics(h)
  local tabs = U.grid(w, h, math.max(1, math.min(7, math.floor((w + 1) / 7))))
  local compact = w < 26 or h < 12
  local top = metrics.header + (compact and 3 or 2 + math.ceil(7 / #tabs))
  local nav = h < 16 and 1 or 3
  local bottom = h - nav + 1
  local cols = U.grid(w, h)
  local rows = math.max(1, math.floor((bottom - top) / (metrics.tile + 1)))
  return { tabs = tabs, top = top, nav = nav, bottom = bottom, cols = cols,
    rows = rows, capacity = #cols * rows, compact = compact, header = metrics.header, tile = metrics.tile }
end

S.capacity = function(w, h)
  local g = S.geometry(w, h)
  return g.cols, g.rows, g.capacity
end

S.gather = function(client)
  local view = S.view(client)
  local search = view.search
  local m = { found = S.turtle ~= nil, search = search, page = view.page, items = {},
    order = view.order or "", orderDetail = view.orderDetail, ordered = view.ordered,
    categories = view.categories, category = view.category, letter = view.letter, letters = view.letters, sort = view.sort,
    stale = S.heardAt == nil or os.epoch("utc") - S.heardAt >= 30000, time = "-" }
  if S.heardAt then
    m.time = U and U.clock(S.heardAt).hm or "-"
  end
  local query = search:lower():gsub("%s+", "_")
  for name, count in pairs(S.totals) do
    local samples = S.history[name]
    local delta = count - (samples and samples[1] or count)
    local rate = math.floor(math.abs(delta) * 60 / math.max(1, samples and #samples - 1 or 1) + 0.5)
    local sub = delta > 0 and ("^ +" .. rate .. "/h") or delta < 0 and ("v -" .. rate .. "/h") or "- steady"
    local item = { name = name, label = name:gsub("^.-:", ""):gsub("_", " "):upper(),
      count = count, sub = sub, detail = sub:gsub("/h", " per hour"),
      bg = count == 0 and "e" or (count <= 16 or delta < 0) and "1" or "b" }
    if count == 0 then item.sub = "empty"
    elseif count <= 16 and delta < 0 then item.sub = "v low" end
    if name == view.selected then m.selected = item end
    if name:lower():find(query, 1, true)
        and (view.category == "all" or S.category(name) == view.category)
        and (not view.letter or item.label:sub(1, 1) == view.letter) then
      m.items[#m.items + 1] = item
    end
  end
  table.sort(m.items, function(a, b)
    if view.sort == "name" then
      if a.label == b.label then return a.name < b.name end
      return a.label < b.label
    end
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end)
  return m
end

S.layout = function(m, w, h)
  local C, g = U.canvas(w, h), S.geometry(w, h)
  if w < 4 or h < 5 then return C.frame() end
  local status = m.stale and "STALE STOCK" or ("stock " .. m.time)
  local footer = function(back)
    local pages = math.max(1, math.ceil(#m.items / g.capacity))
    local cols = U.grid(w, h, w < 26 and 5 or 4)
    if w < 26 then cols[4].w = cols[4].w + cols[5].w + 1; cols[5] = nil end
    for i, label in ipairs({"<", (m.page or 1) .. "/" .. pages, ">", "BACK"}) do
      local col = cols[i]
      if i == 2 and col.w < #label then label = tostring(m.page or 1) end
      C.button(col.x, g.bottom, col.w, label, ({"prev", "page", "next", back})[i], "7", g.nav)
    end
  end
  if m.categories then
    C.header("SHOP CATEGORIES", "", "a")
    for i, category in ipairs(S.categories) do
      local cols = U.grid(w, h, 2)
      local col = cols[(i - 1) % 2 + 1]
      C.button(col.x, g.header + 2 + math.floor((i - 1) / 2), col.w, category[2], "category:" .. category[1], "a", 1)
    end
    C.button(1, g.bottom, w, "BACK", "items", "7", g.nav)
    return C.frame()
  end
  if m.letters then
    C.header("SHOP A-Z", "", "a")
    local cols = U.grid(w, h, math.min(7, math.max(1, math.floor((w + 1) / 4))))
    local start = g.header + 2
    local height = math.max(1, math.min(h >= 20 and 3 or 1, math.floor((g.bottom - start) / math.ceil(27 / #cols))))
    for i = 1, 27 do
      local col = cols[(i - 1) % #cols + 1]
      local letter = i == 1 and "ALL" or string.char(63 + i)
      C.button(col.x, start + math.floor((i - 1) / #cols) * height, col.w,
        letter, "letter:" .. letter, "a", height)
    end
    C.button(1, g.bottom, w, "BACK", "items", "7", g.nav)
    return C.frame()
  end
  if m.selected then
    local item = m.selected
    C.header("SHOP > " .. item.label, "", "a")
    local tileY = h < 16 and 3 or g.header + 2
    if tileY > g.header + 1 then C.put(2, g.header + 1, status:sub(1, math.max(0, w - 2))) end
    C.tile(1, tileY, w, m.stale and "STALE STOCK" or "IN STOCK", item.count, item.detail,
      m.stale and "c" or item.bg, g.tile)
    local orderCols = U.grid(w, h, 3)
    local y = h < 16 and 8 or tileY + g.tile + 1
    local height = h < 12 and 1 or h < 16 and 3 or math.min(5, g.bottom - 2 - y)
    for i, amount in ipairs({1,16,64}) do
      local col = orderCols[i]
      if m.ordered then
        C.fill(col.x, y, col.w, height, "c")
        C.center(col.x, col.w, y + math.floor(height / 2), tostring(amount))
      else
        C.button(col.x, y, col.w, (w < 26 and "" or "ORDER ") .. amount,
          "order:" .. amount .. ":" .. item.name, "a", height)
      end
    end
    C.put(2, g.bottom - 1, (m.order or ""):sub(1, math.max(0, w - 2)))
    if h >= 16 then
      C.put(2, g.bottom - 2, (m.orderDetail or status):sub(1, math.max(0, w - 2)))
    end
    C.button(1, g.bottom, w, "BACK", "items", "7", g.nav)
    return C.frame()
  end
  C.header("SHOP", w >= 26 and status or "", "a")
  if g.compact then
    C.button(1, g.header + 1, w, (m.category or "all"):upper(), "categories", "a", 1)
  else
    for i, category in ipairs(S.categories) do
      local col = g.tabs[(i - 1) % #g.tabs + 1]
      C.button(col.x, g.header + 1 + math.floor((i - 1) / #g.tabs), col.w, category[2],
        "category:" .. category[1], category[1] == (m.category or "all") and "a" or "7", 1)
    end
  end
  for i, col in ipairs(U.grid(w, h, 3)) do
    C.button(col.x, g.top - 1, col.w, ({m.letter or "A-Z", "STOCK", "NAME"})[i],
      ({"letters", "sort:count", "sort:name"})[i],
      (i == 2 and m.sort ~= "name" or i == 3 and m.sort == "name") and "a" or "7", 1)
  end
  local page = math.max(1, math.min(m.page or 1, math.max(1, math.ceil(#m.items / g.capacity))))
  if not m.found then
    local text, width = "Storage room not found", math.max(1, w - 2)
    for i = 1, math.ceil(#text / width) do
      C.put(2, g.top + i - 1, text:sub((i - 1) * width + 1, i * width))
    end
  elseif #m.items == 0 then
    C.center(1, w, g.top + 1, "No items")
  else
    for i = 1, g.capacity do
      local item = m.items[(page - 1) * g.capacity + i]
      if not item then break end
      local col = g.cols[(i - 1) % #g.cols + 1]
      local y = g.top + math.floor((i - 1) / #g.cols) * (g.tile + 1)
      C.tile(col.x, y, col.w, item.label, item.count, item.sub, m.stale and "c" or item.bg, g.tile)
      C.hit("item:" .. item.name, col.x, y, col.w, g.tile)
    end
  end
  C.put(2, g.bottom - 1, (m.order or ""):sub(1, math.max(0, w - 2)))
  footer("status")
  return C.frame()
end

S.render = function(w, h, session)
  local client = session
  if not U then return S.legacy(w, h, client) end
  w, h = w or 57, h or 24
  local _, _, capacity = S.capacity(w,h)
  local m = S.gather(client)
  local view = S.view(client)
  view.page = math.max(1,math.min(view.page,math.max(1,math.ceil(#m.items/capacity))))
  view.capacity = capacity
  m.page = view.page
  return S.layout(m,w,h)
end

S.input = function(event)
  local client = event.session or event.from
  local view = S.view(client)
  if type(event.text) == "string" then
    view.search = (event.text == " " or event.text == "*") and "" or event.text
    view.page, view.selected, view.ordered = 1, nil, nil
    return
  end
  if event.id == "clear" then view.search = ""; view.page, view.selected, view.ordered = 1, nil, nil; return end
  if type(event.id) ~= "string" then return end
  if U then
    if event.id == "items" then view.selected, view.letters, view.ordered, view.categories = nil, nil, nil, nil return end
    if event.id == "categories" then view.categories = true return end
    if event.id == "letters" then view.letters = true return end
    local letter = event.id:match("^letter:(%u+)$")
    if letter and (letter == "ALL" or #letter == 1) then
      view.letter = letter ~= "ALL" and letter or nil
      view.page, view.letters = 1, nil
      return
    end
    local category = event.id:match("^category:(%a+)$")
    if category then
      for _, entry in ipairs(S.categories) do
        if entry[1] == category then
          view.category, view.page, view.selected, view.letter, view.search, view.categories = category, 1, nil, nil, "", nil
          return
        end
      end
      return
    end
    if event.id == "sort:name" or event.id == "sort:count" then
      view.sort, view.page = event.id:sub(6), 1
      return
    end
    if event.id == "next" or event.id == "prev" then
      local pages = math.max(1,math.ceil(#S.gather(client).items/(view.capacity or 1)))
      view.page = math.max(1,math.min(pages,view.page + (event.id == "next" and 1 or -1)))
      return
    end
    local item = event.id:match("^item:(.+)$")
    if item and S.totals[item] ~= nil then view.selected, view.ordered = item, nil return end
  end
  local count, name = event.id:match("^order:(%d+):(.+)$")
  count = tonumber(count)
  if (count == 1 or count == 16 or count == 64) and S.totals[name] ~= nil
      and (not U or view.selected == name) and not view.ordered then
    view.ordered = U ~= nil
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
    S.totals, S.history = {}, {}
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
}
