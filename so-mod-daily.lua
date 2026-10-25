local U = dofile("so-ui.lua")
local D = {}
D.integer = function(n)
  return type(n) == "number" and n >= 0 and n < math.huge and n % 1 == 0
end
D.date = function(day)
  return U.clock(day * 86400000 + 43200000).date
end
D.day = function(date)
  if type(date) ~= "string" then return nil end
  local y, m, d = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m < 1 or m > 12 or d < 1 or d > 31 then return nil end
  y = y - (m <= 2 and 1 or 0)
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local day = era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100)
    + math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1 - 719468
  if D.date(day) == date then return day end
end
D.rowValid = function(v)
  return type(v) == "table" and D.day(v.date) ~= nil
    and ((D.integer(v.ore) and D.integer(v.logs) and (v.partial == nil or type(v.partial) == "boolean"))
      or (v.ore == false and v.logs == false and v.partial == true))
end
D.valid = function(v)
  if type(v) ~= "table" or (v.date ~= "" and not D.day(v.date)) or not D.integer(v.cursor)
    or not D.integer(v.ore) or type(v.oreByName) ~= "table" or not D.integer(v.logs)
    or type(v.recent) ~= "table" or (v.partial ~= nil and type(v.partial) ~= "boolean") then return false end
  for name, count in pairs(v.oreByName) do
    if type(name) ~= "string" or not D.integer(count) then return false end
  end
  for second, bucket in pairs(v.recent) do
    if not D.integer(tonumber(second)) or type(bucket) ~= "table" or not D.integer(bucket.total)
      or type(bucket.counts) ~= "table" then return false end
    for at, count in pairs(bucket.counts) do
      if not D.integer(tonumber(at)) or not D.integer(count) then return false end
    end
  end
  if v.previous == nil then return true end
  if type(v.previous) ~= "table" then return false end
  if v.previous.date then return D.rowValid(v.previous) end
  if #v.previous > 6 then return false end
  for key, row in pairs(v.previous) do
    if not D.integer(key) or key < 1 or key > #v.previous or not D.rowValid(row) then return false end
  end
  return true
end
local opened, box = pcall(SO.store.store, "so-data/daily", D.valid, 262144)
if not opened and tostring(box):find("no valid generation", 1, true) then
  for _, suffix in ipairs({ "", ".tmp", ".bak" }) do
    local path = "so-data/daily" .. suffix
    if fs.exists(path) then fs.delete(path) end
  end
  opened, box = pcall(SO.store.store, "so-data/daily", D.valid, 262144)
  if opened then (SO.error or print)("so-daily: unreadable totals reset") end
end
if not opened then error(box, 0) end
D.box = box
D.value = SO.store.copy(box.value or {
  date = "", cursor = 0, ore = 0, oreByName = {}, logs = 0, recent = {},
})
D.lastSave = SO.now()
D.names = function(names)
  local bounded, keys = {}, {}
  for name in pairs(names) do keys[#keys + 1] = name end
  table.sort(keys)
  local exact = 0
  for _, name in ipairs(keys) do
    local key = name
    if name == "other" or #name > 128 or exact >= 128 then key = "other" else exact = exact + 1 end
    bounded[key] = (bounded[key] or 0) + names[name]
  end
  return bounded
end
D.value.oreByName = D.names(D.value.oreByName)
D.value.partial = D.value.partial ~= false
local previous = D.value.previous or {}
if previous.date then previous = { previous } end
D.value.previous = {}
local loadedDay = D.day(D.value.date)
for _, row in ipairs(previous) do
  local day = D.day(row.date)
  if loadedDay and day >= loadedDay - 6 and day < loadedDay then
    local found = false
    for _, kept in ipairs(D.value.previous) do if kept.date == row.date then found = true end end
    if not found then
      D.value.previous[#D.value.previous + 1] = {
        date = row.date, ore = row.ore, logs = row.logs, partial = row.partial ~= false,
      }
    end
  end
end
table.sort(D.value.previous, function(a, b) return a.date < b.date end)
D.recent = function(now)
  local total, cutoff = 0, now - 600000
  for second, bucket in pairs(D.value.recent) do
    if tonumber(second) * 1000 + 999 <= cutoff then
      D.value.recent[second] = nil
    elseif tonumber(second) * 1000 > cutoff and tonumber(second) * 1000 + 999 <= now then
      total = total + bucket.total
    elseif tonumber(second) * 1000 <= now then
      for at, count in pairs(bucket.counts) do
        if tonumber(at) > cutoff and tonumber(at) <= now then total = total + count end
      end
    end
  end
  return total
end
D.roll = function(date)
  local v, day = D.value, D.day(date)
  if v.date ~= "" and date <= v.date then return false end
  local rows = v.previous
  if D.day(v.date) then
    rows[#rows + 1] = { date = v.date, ore = v.ore, logs = v.logs, partial = v.partial }
  end
  local kept = {}
  for _, row in ipairs(rows) do
    if D.day(row.date) >= day - 6 and row.date < date then kept[#kept + 1] = row end
  end
  D.value = { date = date, cursor = v.cursor, ore = 0, oreByName = {}, logs = 0,
    recent = {}, previous = kept, partial = not D.day(v.date) or day > D.day(v.date) + 1 }
  return true
end
D.row = function(date)
  local v = D.value
  if date == v.date then return v end
  local day, current = D.day(date), D.day(v.date)
  if not day or day < current - 6 or day > current then return nil end
  for _, row in ipairs(v.previous) do if row.date == date then return row end end
  local row = { date = date, ore = 0, logs = 0, partial = true }
  v.previous[#v.previous + 1] = row
  table.sort(v.previous, function(a, b) return a.date < b.date end)
  return row
end
D.partial = function()
  D.value.partial = true
  for _, row in ipairs(D.value.previous) do row.partial = true end
end
D.same = function(a, b)
  if type(a) ~= "table" then return a == b end
  if type(b) ~= "table" then return false end
  for key, value in pairs(a) do if not D.same(value, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end
D.retireOversized = function()
  local paths = {}
  for _, suffix in ipairs({ ".bak", ".tmp" }) do
    local path = "so-data/daily" .. suffix
    if fs.exists(path) and fs.getSize(path) > 262144 then paths[#paths + 1] = path end
  end
  if #paths == 0 then return true end
  local saved, bytes = SO.store.read("so-data/daily")
  if type(saved) ~= "table" or saved.schema ~= 1 or not D.integer(saved.generation) or saved.generation < 1
    or type(bytes) ~= "string" or #bytes > 262144
    or not D.same(saved.value, D.value) then return false end
  for _, path in ipairs(paths) do fs.delete(path) end
  return true
end
D.currentDate = function()
  local now = os.epoch("utc")
  return U.clock(now).date
end
D.tick = function(gameNow)
  local date = D.currentDate()
  local changed = D.roll(date)
  local state = SO.mods.state
  if state and state.history and type(state.history.page) == "function" then
    local page = state.history.page({ from = D.value.cursor, count = 50 })
    for _, ev in ipairs(page.entries) do
      if ev.seq > D.value.cursor then
        if ev.seq > D.value.cursor + 1 then
          D.partial()
        end
        local at = ev.at
        local data = type(ev.data) == "table" and ev.data or {}
        local count = data.count
        local ore = ev.kind == "mine.ore" and type(data.name) == "string"
        if D.integer(at) and D.integer(count) and count > 0 and (ore or ev.kind == "lumber.logs") then
          local row = D.row(U.clock(at).date)
          if row then
            if row.ore == false then row.ore, row.logs = 0, 0 end
            if not D.integer((ore and row.ore or row.logs) + count) then
              row.partial = true
            elseif ore then
              row.ore = row.ore + count
              if row == D.value then
                local names = row.oreByName
                names[data.name] = (names[data.name] or 0) + count
                row.oreByName = D.names(names)
              end
              local atGame = ev.gameAt or at
              if row == D.value and D.integer(atGame) and atGame > gameNow - 600000 and atGame <= gameNow then
                local second = tostring(math.floor(atGame / 1000))
                local bucket = D.value.recent[second] or { total = 0, counts = {} }
                local stamp = tostring(atGame)
                bucket.total = bucket.total + count
                bucket.counts[stamp] = (bucket.counts[stamp] or 0) + count
                D.value.recent[second] = bucket
              end
            elseif ev.kind == "lumber.logs" then row.logs = row.logs + count end
          end
        end
        D.value.cursor = ev.seq
      end
    end
    if #page.entries == 0 and type(state.diagnostics) == "function" then
      local status = state.diagnostics()
      if status.available and D.integer(status.seq) and status.seq > D.value.cursor then
        D.partial()
        D.value.cursor = status.seq
        changed = true
      end
    end
  end
  D.recent(gameNow)
  if changed or D.failed or gameNow - D.lastSave >= 60000 then
    local ok, err = D.box.save(D.value)
    if not ok and tostring(err):find("budget", 1, true) and next(D.value.recent) then
      D.value.recent = {}
      ok = D.box.save(D.value)
    end
    if ok and type(SO.store.read) == "function" then
      local checked, retired = pcall(D.retireOversized)
      ok = checked and retired
    end
    D.failed = not ok
    if ok then D.lastSave = gameNow end
  end
end
D.today = function()
  local v = D.value
  return { date = v.date, ore = v.ore, oreByName = SO.store.copy(v.oreByName),
    oreRecent = D.recent(SO.now()), logs = v.logs }
end
D.days = function()
  local rows, v = {}, D.value
  local day = D.day(v.date) or D.day(D.currentDate())
  for n = day - 6, day do
    local date = D.date(n)
    local row = { date = date, ore = false, logs = false, partial = true }
    if date == v.date then
      row = { date = date, ore = v.ore, logs = v.logs, partial = v.partial }
    else
      for _, saved in ipairs(v.previous) do if saved.date == date then row = SO.store.copy(saved) break end end
    end
    rows[#rows + 1] = row
  end
  return rows
end
return { name = "daily", handlers = {}, tick = D.tick, today = D.today, days = D.days }
