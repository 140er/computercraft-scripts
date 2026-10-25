local U = dofile("so-ui.lua")
local D = {}
D.valid = function(v)
  return type(v) == "table" and type(v.date) == "string" and type(v.cursor) == "number"
    and type(v.ore) == "number" and type(v.oreByName) == "table"
    and type(v.logs) == "number" and type(v.recent) == "table"
end
local opened, box = pcall(SO.store.store, "so-data/daily", D.valid)
if not opened and tostring(box):find("no valid generation", 1, true) then
  for _, suffix in ipairs({ "", ".tmp", ".bak" }) do
    local path = "so-data/daily" .. suffix
    if fs.exists(path) then fs.delete(path) end
  end
  opened, box = pcall(SO.store.store, "so-data/daily", D.valid)
  if opened then (SO.error or print)("so-daily: unreadable totals reset") end
end
if not opened then error(box, 0) end
D.box = box
D.value = D.box.value or { date = "", cursor = 0, ore = 0, oreByName = {}, logs = 0, recent = {} }
D.lastSave = SO.now()
D.recent = function(now)
  local total, cutoff = 0, now - 600000
  for second, bucket in pairs(D.value.recent) do
    if tonumber(second) * 1000 + 999 <= cutoff then
      D.value.recent[second] = nil
    elseif tonumber(second) * 1000 > cutoff then
      total = total + bucket.total
    else
      for at, count in pairs(bucket.counts) do
        if tonumber(at) > cutoff then total = total + count end
      end
    end
  end
  return total
end
D.tick = function(gameNow)
  local now = os.epoch("utc")
  local date = U.clock(now).date
  local changed = date ~= D.value.date
  if changed then
    D.value = { date = date, cursor = D.value.cursor, ore = 0, oreByName = {}, logs = 0, recent = {} }
  end
  local state = SO.mods.state
  if state and state.history and type(state.history.page) == "function" then
    local page = state.history.page({ from = D.value.cursor, count = 50 })
    for _, ev in ipairs(page.entries) do
      if ev.seq > D.value.cursor then
        if U.clock(ev.at).date == date then
          local data = ev.data or {}
          local count = data.count
          if type(count) == "number" and count > 0 and count < math.huge then
            if ev.kind == "mine.ore" and type(data.name) == "string" then
              D.value.ore = D.value.ore + count
              D.value.oreByName[data.name] = (D.value.oreByName[data.name] or 0) + count
              local atGame = ev.gameAt or ev.at
              if atGame > gameNow - 600000 and atGame <= gameNow then
                local second = tostring(math.floor(atGame / 1000))
                local bucket = D.value.recent[second] or { total = 0, counts = {} }
                local at = tostring(atGame)
                bucket.total = bucket.total + count
                bucket.counts[at] = (bucket.counts[at] or 0) + count
                D.value.recent[second] = bucket
              end
            elseif ev.kind == "lumber.logs" then D.value.logs = D.value.logs + count end
          end
        end
        D.value.cursor = ev.seq
      end
    end
  end
  D.recent(gameNow)
  if changed or gameNow - D.lastSave >= 60000 then
    D.lastSave = gameNow
    D.box.save(D.value)
  end
end
D.today = function()
  local v = D.value
  return { date = v.date, ore = v.ore, oreByName = SO.store.copy(v.oreByName),
    oreRecent = D.recent(SO.now()), logs = v.logs }
end
return { name = "daily", handlers = {}, tick = D.tick, today = D.today }
