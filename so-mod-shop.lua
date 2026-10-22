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
  search = {},
  heardAt = nil,
  selectedAt = nil,
  staleAfter = 300000,
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

S.render = function(w, h, clientId)
  local search = S.search[clientId or 0] or ""
  local picture = {
    rows = {},
    buttons = {
      { id = "generic", x = 1, y = 1, w = 7, label = "generic" },
      { id = "clear", x = 9, y = 1, w = 5, label = "clear" },
    },
  }
  local rows, buttons = picture.rows, picture.buttons
  rows[1] = S.row("              Storage: " .. S.state)
  rows[2] = S.row("Search: " .. search)
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

S.input = function(event)
  if type(event.text) == "string" then
    S.search[event.from or 0] = (event.text == " " or event.text == "*") and "" or event.text
    return
  end
  if event.id == "clear" then S.search[event.from or 0] = "" return end
  if type(event.id) ~= "string" then return end
  local count, name = event.id:match("^order:(%d+):(.+)$")
  count = tonumber(count)
  if (count == 1 or count == 16 or count == 64) and S.totals[name] ~= nil then
    S.request("order", name, count)
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
