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
  search = "",
  orders = {},
  latestOrder = nil,
  registered = false,
}

S.request = function(kind, name, count)
  if not S.turtle then return end
  S.rid = S.rid + 1
  local rid = S.rid
  S.pending[rid] = { kind = kind, sender = S.turtle, at = os.epoch("utc") }
  if kind == "order" then
    S.latestOrder = rid
    S.orders = { "sending " .. tostring(count) .. " " .. name }
  end
  rednet.send(S.turtle, { cmd = kind, text = name, n = count, rid = rid }, "roomsorter")
end

S.stock = function(message)
  if type(message.totals) == "table" then
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
  S.pending[message.rid] = nil
  if pending.kind == "stock" then
    S.stock(message)
  elseif message.rid == S.latestOrder then
    S.orders = {}
    for i = 1, #message do
      if type(message[i]) == "string" then S.orders[#S.orders + 1] = message[i] end
    end
  end
end

S.broadcast = function(sender, message)
  if type(message) ~= "table" or type(message.totals) ~= "table" then return end
  if not S.turtle then S.turtle = sender end
  if sender == S.turtle then S.stock(message) end
end

S.dns = function(sender, message)
  if not S.turtle and type(message) == "table" and message.sType == "lookup response"
      and message.sProtocol == "roomsorter" then
    S.turtle = sender
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

S.legacy = function()
  local picture = {
    rows = {},
    buttons = { { id = "generic", x = 1, y = 1, w = 7, label = "generic" } },
  }
  local rows, buttons = picture.rows, picture.buttons
  rows[1] = S.row("        Storage: " .. S.state)
  rows[2] = S.row("Search: " .. S.search)
  if not S.turtle then
    rows[#rows + 1] = S.row("Storage room not found, still looking")
    return picture
  end
  for i = 1, #S.orders do rows[#rows + 1] = S.row("Order: " .. S.orders[i]) end
  local items = {}
  local query = S.search:lower():gsub("%s+", "_")
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

S.page = 1
S.selected = nil
S.capacity = function(w, h)
  local cols = U.grid(w, h)
  if w == 57 and h == 24 then cols = {{x=1,w=18},{x=20,w=19},{x=40,w=18}} end
  local rows = math.max(1, math.floor((h - 11) / 6))
  return cols, rows, #cols * rows
end

S.gather = function()
  local m = { found = S.turtle ~= nil, search = S.search, page = S.page, items = {},
    order = table.concat(S.orders, "; "), time = "-" }
  if S.sampleAt then
    m.time = U and U.clock(S.sampleAt).hm or "-"
  end
  local query = S.search:lower():gsub("%s+", "_")
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
    if name == S.selected then m.selected = item end
    if name:lower():find(query, 1, true) then m.items[#m.items + 1] = item end
  end
  table.sort(m.items, function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end)
  return m
end

S.layout = function(m, w, h)
  local C = U.canvas(w, h)
  local cols, rows, capacity = S.capacity(w, h)
  local small = h < 16
  local navHeight = small and 1 or 3
  local bottom = h - navHeight + 1
  if m.selected then
    local item = m.selected
    C.header("SHOP > " .. item.label, "", "a")
    C.tile(1, 3, w, "IN STOCK", item.count, item.detail, item.bg)
    local orderCols = U.grid(w, h, 3)
    if w == 57 and h == 24 then orderCols = cols end
    for i, amount in ipairs({1,16,64}) do
      local col = orderCols[(i - 1) % #orderCols + 1]
      local y = small and 8 or 9
      local height = small and 1 or 5
      if y + height - 1 < bottom then
        C.button(col.x, y, col.w, (col.w < 8 and "" or "ORDER ") .. amount,
          "order:" .. amount .. ":" .. item.name, "a", height)
      end
    end
    C.put(2, small and h-1 or 15, ("Order: " .. m.order):sub(1, math.max(0,w-2)))
    C.button(1, bottom, w, "BACK", "items", "7", navHeight)
    return C.frame()
  end
  C.header("SHOP", w >= 26 and ("stock " .. m.time) or "", "a")
  C.search(2, small and 2 or 3, math.max(0,w-2), " search: " .. m.search .. "_", "search")
  local pages = math.max(1, math.ceil(#m.items / capacity))
  local page = math.max(1, math.min(m.page, pages))
  local start = (page - 1) * capacity
  if not m.found then
    local message = "Storage room not found, still looking"
    local width = math.max(1,w-2)
    for i=1, math.ceil(#message/width) do
      C.put(2, (small and 3 or 5)+i-1, message:sub((i-1)*width+1,i*width))
    end
  else
    for i=1,capacity do
      local item = m.items[start+i]
      if not item then break end
      local col = cols[(i-1)%#cols+1]
      local y = (small and 3 or 5) + math.floor((i-1)/#cols)*6
      C.tile(col.x,y,col.w,item.label,item.count,item.sub,item.bg)
      C.hit("item:" .. item.name,col.x,y,col.w,5)
    end
  end
  C.put(2, small and h-1 or h-7, ("Order: " .. m.order):sub(1,math.max(0,w-2)))
  if pages > 1 then
    local y = small and h-2 or h-5
    local pager = U.grid(w,h,3)
    if w == 57 and h == 24 then pager = cols end
    local labels = {"< PREV", "page " .. page .. "/" .. pages, "NEXT >"}
    for i,col in ipairs(pager) do
      local label = labels[i]
      if col.w < 8 then label = ({ "<", page .. "/" .. pages, ">" })[i] end
      C.button(col.x,y,col.w,label,({"prev","page","next"})[i],"7",navHeight)
    end
  end
  local halves = U.grid(w,h,2)
  if w == 57 and h == 24 then halves = {{x=1,w=28},{x=30,w=28}} end
  C.button(halves[1].x,bottom,halves[1].w,"CLEAR SEARCH","clear","7",navHeight)
  C.button(halves[2].x,bottom,halves[2].w,"BACK","status","7",navHeight)
  return C.frame()
end

S.render = function(w, h)
  if not U then return S.legacy() end
  w, h = w or 57, h or 24
  local _, _, capacity = S.capacity(w,h)
  local m = S.gather()
  S.page = math.max(1,math.min(S.page,math.max(1,math.ceil(#m.items/capacity))))
  S.pageCapacity = capacity
  m.page = S.page
  return S.layout(m,w,h)
end

S.input = function(event)
  if type(event.text) == "string" then
    S.search = event.text
    S.page, S.selected = 1, nil
    return
  end
  if type(event.id) ~= "string" then return end
  if U then
    if event.id == "items" then S.selected = nil return end
    if event.id == "clear" then S.search, S.page, S.selected = "", 1, nil return end
    if event.id == "next" or event.id == "prev" then
      local pages = math.max(1,math.ceil(#S.gather().items/(S.pageCapacity or 1)))
      S.page = math.max(1,math.min(pages,S.page + (event.id == "next" and 1 or -1)))
      return
    end
    local item = event.id:match("^item:(.+)$")
    if item and S.totals[item] ~= nil then S.selected = item return end
  end
  local count, name = event.id:match("^order:(%d+):(.+)$")
  count = tonumber(count)
  if (count == 1 or count == 16 or count == 64) and S.totals[name] ~= nil
      and (not U or S.selected == name) then
    S.request("order", name, count)
  end
end

S.tick = function(now)
  local display = SO.mods.display
  if not S.registered and type(display) == "table" and type(display.screen) == "function" then
    display.screen("shop", S.render, S.input)
    S.registered = true
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
      if pending.kind == "order" and rid == S.latestOrder then S.orders = { "reply timed out" } end
    end
  end
end

return {
  name = "shop",
  handlers = {},
  listen = { roomsorter = S.reply, roomsorter_stock = S.broadcast, dns = S.dns },
  tick = S.tick,
}
