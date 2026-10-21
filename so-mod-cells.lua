local S = {
  reservations = {}, sections = {}, sizes = {}, cached = 0, dug = 0,
  clock = 0, work = 0, yielded = os.epoch("utc"), events = {}, confirmations = {}, serial = 0,
  root = "so-data/cells/",
}

S.pause = function()
  local now = os.epoch("utc")
  if not S.last or now - S.last > 50 then
    S.yielded, S.work = now, 0
  end
  S.last = now
  S.work = S.work + 1
  if S.work >= 128 or now - S.yielded >= 1000 then
    sleep(0)
    S.work, S.yielded = 0, os.epoch("utc")
  end
end

S.whoValid = function(who)
  return (type(who) == "string" and who ~= "")
    or (type(who) == "number" and who == who and who % 1 == 0)
end

S.dimension = function(dim)
  dim = dim or "minecraft:overworld"
  assert(type(dim) == "string" and dim ~= "", "dimension")
  return (dim:gsub("[^%w_%-]", function(c) return string.format("%%%02x", string.byte(c)) end))
end

S.cell = function(x, y, z, dim)
  for _, n in ipairs({ x, y, z }) do
    assert(type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n % 1 == 0, "coordinate")
  end
  assert(x ~= nil and y ~= nil and z ~= nil, "coordinate")
  local path = S.root .. S.dimension(dim) .. "/" .. string.format("%.0f_%.0f_%.0f",
    math.floor(x / 16) + 0, math.floor(y / 16) + 0, math.floor(z / 16) + 0)
  local index = x % 16 + 16 * (y % 16) + 256 * (z % 16)
  return path .. ":" .. index, path, index
end

S.resValid = function(value)
  if type(value) ~= "table" then return false end
  for key, who in pairs(value) do
    if type(key) ~= "string" or not S.whoValid(who) then return false end
  end
  return true
end

S.sectionValid = function(value)
  if type(value) ~= "table" then return false end
  for key, dug in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 0 or key > 4095 or dug ~= true then return false end
  end
  return true
end

S.saveSection = function(section)
  if not section.dirty then return true end
  local ok, err = section.box.save(section.value)
  if ok then section.dirty = false end
  return ok, err
end

S.section = function(path)
  local section = S.sections[path]
  S.clock = S.clock + 1
  if section then section.used = S.clock return section end
  if S.cached >= 256 then
    local oldest, victim
    for name, row in pairs(S.sections) do
      if not victim or row.used < victim.used then oldest, victim = name, row end
    end
    local ok, err = S.saveSection(victim)
    if not ok then return nil, err end
    S.sections[oldest], S.cached = nil, S.cached - 1
  end
  fs.makeDir(path:match("^(.*)/"))
  local box = SO.store.store(path, S.sectionValid)
  section = { box = box, value = box.value or {}, used = S.clock, dirty = false }
  local count = 0
  for _ in pairs(section.value) do count = count + 1 end
  S.dug = S.dug + count - (S.sizes[path] or 0)
  S.sizes[path] = count
  S.sections[path], S.cached = section, S.cached + 1
  S.pause()
  return section
end

S.commit = function(nextRes)
  local ok, err = S.box.save(nextRes)
  if ok then S.reservations = nextRes end
  return ok, err
end

S.copyReservations = function()
  local copy = {}
  for key, who in pairs(S.reservations) do copy[key] = who S.pause() end
  return copy
end

S.reserveMany = function(who, cells)
  if not S.whoValid(who) or type(cells) ~= "table" then return false, "bad" end
  local keys = {}
  for i, cell in ipairs(cells) do
    if type(cell) ~= "table" then return false, "bad" end
    local key = S.cell(cell.x or cell[2], cell.y or cell[3], cell.z or cell[4], cell.dim or cell[1])
    if S.reservations[key] ~= nil and S.reservations[key] ~= who then return false, "held", cell end
    keys[i] = key
    S.pause()
  end
  local changed = false
  for _, key in ipairs(keys) do if S.reservations[key] == nil then changed = true break end end
  if not changed then return true end
  local copy = S.copyReservations()
  for _, key in ipairs(keys) do copy[key] = who S.pause() end
  return S.commit(copy)
end

S.reserve = function(who, x, y, z, dim)
  return S.reserveMany(who, { { dim or "minecraft:overworld", x, y, z } })
end

S.owner = function(x, y, z, dim)
  return S.reservations[S.cell(x, y, z, dim)]
end

S.release = function(who, x, y, z, dim)
  local key = S.cell(x, y, z, dim)
  if S.reservations[key] ~= who then return true end
  local copy = S.copyReservations()
  copy[key] = nil
  return S.commit(copy)
end

S.releaseOwner = function(who)
  local copy, count = {}, 0
  for key, held in pairs(S.reservations) do
    if held == who then count = count + 1 else copy[key] = held end
    S.pause()
  end
  if count == 0 then return true, 0 end
  local ok, err = S.commit(copy)
  if not ok then return false, err end
  return true, count
end

S.forgetOwner = function(who)
  if not S.whoValid(who) then return false, "bad" end
  local ok, count = S.releaseOwner(who)
  if ok then S.events[#S.events + 1] = { who = who, count = count } end
  return ok, count
end

S.markDug = function(x, y, z, dim)
  local _, path, index = S.cell(x, y, z, dim)
  local section, err = S.section(path)
  if not section then return false, err end
  if not section.value[index] then
    section.value[index], section.dirty = true, true
    S.sizes[path], S.dug = S.sizes[path] + 1, S.dug + 1
  end
  S.pause()
  return true
end

S.isDug = function(x, y, z, dim)
  local _, path, index = S.cell(x, y, z, dim)
  local section, err = S.section(path)
  if not section then error(err, 2) end
  S.pause()
  return section.value[index] == true
end

S.forget = function(x, y, z, dim)
  local key, path, index = S.cell(x, y, z, dim)
  local section, err = S.section(path)
  if not section then return false, err end
  if S.reservations[key] ~= nil then
    local copy = S.copyReservations()
    copy[key] = nil
    local ok
    ok, err = S.commit(copy)
    if not ok then return false, err end
  end
  if section.value[index] then
    section.value[index], section.dirty = nil, true
    S.sizes[path], S.dug = S.sizes[path] - 1, S.dug - 1
  end
  return true
end

S.counts = function()
  local reserved = {}
  for _, who in pairs(S.reservations) do reserved[who] = (reserved[who] or 0) + 1 S.pause() end
  return { reserved = reserved, dug = S.dug }
end

S.emit = function()
  local state = SO.mods.state
  if type(state) ~= "table" or type(state.emit) ~= "function" then return end
  while #S.events > 0 do
    local ok = state.emit("cells.forget", S.events[1])
    if ok == false then break end
    table.remove(S.events, 1)
    S.pause()
  end
end

S.onForget = function(msg, reply)
  local body = msg.body
  if type(body) ~= "table" or not S.whoValid(body.who) or not S.whoValid(msg.from) then
    reply("err", { code = "bad", text = "bad owner" }) return
  end
  local now, pending = os.epoch("utc"), S.confirmations[msg.from]
  if body.confirm == nil then
    S.serial = S.serial + 1
    local token = tostring(now) .. ":" .. tostring(S.serial)
    S.confirmations[msg.from] = { who = body.who, token = token, untilAt = now + 30000 }
    reply("cells.forget", { confirm = token })
    return
  end
  if not pending or pending.token ~= body.confirm or pending.who ~= body.who or now > pending.untilAt then
    reply("err", { code = "confirm", text = "invalid confirmation" }) return
  end
  S.confirmations[msg.from] = nil
  local ok, count = S.forgetOwner(body.who)
  S.emit()
  if ok then reply("ack", { ok = true, who = body.who, count = count })
  else reply("err", { code = "store", text = tostring(count) }) end
end

S.tick = function(now)
  local saved = 0
  for _, section in pairs(S.sections) do
    if section.dirty then
      local ok, err = S.saveSection(section)
      if not ok then return false, err end
      saved = saved + 1
      S.pause()
      if saved == 8 then break end
    end
  end
  for sender, pending in pairs(S.confirmations) do
    if (now or os.epoch("utc")) > pending.untilAt then S.confirmations[sender] = nil end
  end
  local state = SO.mods.state
  if not S.view and type(state) == "table" then
    local view = state.view
    local meta = type(view) == "table" and getmetatable(view) or nil
    if type(view) == "function" or (meta and type(meta.__call) == "function") then
      view("cells", S.counts)
      S.view = true
    end
  end
  S.emit()
  return true
end

fs.makeDir(S.root)
S.box = SO.store.store(S.root .. "res", S.resValid)
S.reservations = S.box.value or {}
for _, dim in ipairs(fs.list(S.root)) do
  if dim ~= "res" and dim ~= "res.tmp" and dim ~= "res.bak" then
    local directory = S.root .. dim
    if not fs.isDir or fs.isDir(directory) then
      local seen = {}
      for _, file in ipairs(fs.list(directory)) do
        local name = file:gsub("%.tmp$", ""):gsub("%.bak$", "")
        if name:match("^%-?%d+_%-?%d+_%-?%d+$") and not seen[name] then
          seen[name] = true
          local section, err = S.section(directory .. "/" .. name)
          assert(section, err)
        end
      end
    end
  end
end

return {
  name = "cells", handlers = { ["cells.forget"] = S.onForget }, tick = S.tick,
  reserve = S.reserve, reserveMany = S.reserveMany, release = S.release,
  releaseOwner = S.releaseOwner, forgetOwner = S.forgetOwner, owner = S.owner,
  isFree = function(x, y, z, dim) return S.owner(x, y, z, dim) == nil end,
  markDug = S.markDug, isDug = S.isDug, forget = S.forget, counts = S.counts,
}
