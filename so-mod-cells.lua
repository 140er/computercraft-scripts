local F = dofile("so-flags.lua")
local S = {
  reservations = {}, pendingReleases = {}, handoffs = {}, sections = {}, sizes = {}, cached = 0, dug = 0,
  bootAt = SO.now(), edits = {}, releases = {}, clock = 0, work = 0, yielded = SO.now(), events = {}, confirmations = {}, serial = 0,
  root = "so-data/cells/",
  bytes = {}, used = {}, versions = {}, total = 0, migrations = 0, threshold = 1000000, target = 650000,
  columns = {}, indexed = {}, stamps = {}, columnsVersion = 0, marks = 0, reservedVersion = 0, reservedCache = {},
}

S.pause = function()
  local now = SO.now()
  if not S.last or now - S.last > 50 then
    S.yielded, S.work = now, 0
  end
  S.last = now
  S.work = S.work + 1
  if S.work >= 128 or now - S.yielded >= 1000 then
    SO.breathe()
    S.work, S.yielded = 0, SO.now()
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
  if value.format == "hex4096" then
    return type(value.bits) == "string" and #value.bits == 1024 and not value.bits:find("[^0-9a-f]")
      and type(value.used) == "number" and value.used >= 0 and value.used < math.huge
  end
  for key, dug in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 0 or key > 4095 or dug ~= true then return false end
  end
  return true
end

S.bit = function(bits, index, set)
  local offset, mask = math.floor(index / 4) + 1, 2 ^ (index % 4)
  local digit = tonumber(bits:sub(offset, offset), 16)
  local marked = math.floor(digit / mask) % 2 == 1
  if set == nil then return marked end
  if marked == set then return bits end
  digit = digit + (set and mask or -mask)
  return bits:sub(1, offset - 1) .. string.format("%x", digit) .. bits:sub(offset + 1)
end

S.compact = function(value)
  if value and value.format == "hex4096" then return value, false end
  local bits = string.rep("0", 1024)
  for index in pairs(value or {}) do bits = S.bit(bits, index, true) S.pause() end
  return { format = "hex4096", bits = bits, used = 0 }, value ~= nil
end

S.measure = function(path)
  local bytes = 0
  for _, suffix in ipairs({ "", ".bak", ".tmp" }) do
    if fs.exists(path .. suffix) then bytes = bytes + math.max(500, fs.getSize(path .. suffix)) end
  end
  S.total = S.total + bytes - (S.bytes[path] or 0)
  S.bytes[path] = bytes
end

S.touch = function(path, section)
  local now = SO.now()
  S.used[path], S.versions[path] = now, S.clock
  if S.sizes[path] > 0 and now - section.value.used >= 60000 then
    section.value.used, section.dirty = now, true
  end
end

S.saveSection = function(section)
  if not section.dirty then return true end
  local ok, err = section.box.save(section.value)
  if ok then
    section.dirty, section.compactBackup = section.compactBackup == true, false
    S.measure(section.path)
    if section.dirty then return S.saveSection(section) end
    if section.migrating then S.migrations, section.migrating = S.migrations - 1, false end
  end
  return ok, err
end

S.section = function(path)
  local section = S.sections[path]
  S.clock = S.clock + 1
  if section then section.used = S.clock if not S.loading then S.touch(path, section) end return section end
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
  local box = SO.store.store(path, S.sectionValid, 2048)
  local value, migrate = S.compact(box.value)
  local backup = SO.store.read(path .. ".bak")
  local oldBackup = backup and type(backup.value) == "table" and backup.value.format ~= "hex4096"
  section = { box = box, value = value, used = S.clock, path = path,
    compactBackup = migrate, migrating = migrate or oldBackup,
    dirty = migrate or oldBackup or fs.exists(path .. ".tmp") or (box.value ~= nil and not fs.exists(path)) }
  if section.migrating then S.migrations = S.migrations + 1 end
  local count = 0
  for digit in value.bits:gmatch(".") do
    local n = tonumber(digit, 16)
    for _ = 1, 4 do count = count + n % 2 n = math.floor(n / 2) end
  end
  if count > 0 and not S.indexed[path] then S.index(path, true) end
  S.dug = S.dug + count - (S.sizes[path] or 0)
  S.sizes[path] = count
  S.sections[path], S.cached = section, S.cached + 1
  S.used[path] = value.used
  S.measure(path)
  if not S.loading then S.touch(path, section) end
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

S.handoff = function(from, to, x, y, z, dim)
  if not S.whoValid(from) or not S.whoValid(to) then return false, "owner" end
  local key = S.cell(x, y, z, dim)
  if S.reservations[key] == to then return true end
  if S.reservations[key] ~= from then return false, "held" end
  local nextRes = S.copyReservations()
  nextRes[key] = to
  return S.commit(nextRes)
end

-- Keep the previous owner until reserveMany saves the complete route.
S.prepareHandoff = function(from, to, x, y, z, dim)
  if not S.whoValid(from) or not S.whoValid(to) then return false, "owner" end
  S.handoffs[to] = nil
  local key = S.cell(x, y, z, dim)
  local held = S.reservations[key]
  if held ~= nil and held ~= from and held ~= to then return false, "held" end
  S.handoffs[to] = { key = key, from = from }
  return true
end

S.reserveMany = function(who, cells)
  if not S.whoValid(who) then return false, "bad" end
  local handoff = S.handoffs[who]
  S.handoffs[who] = nil
  if type(cells) ~= "table" then return false, "bad" end
  local keys, includesHandoff = {}, false
  for i, cell in ipairs(cells) do
    if type(cell) ~= "table" then return false, "bad" end
    local key = S.cell(cell.x or cell[2], cell.y or cell[3], cell.z or cell[4], cell.dim or cell[1])
    local held = S.reservations[key]
    if held ~= nil and held ~= who and not (handoff and key == handoff.key and held == handoff.from) then
      return false, "held", cell
    end
    if handoff and key == handoff.key then includesHandoff = true end
    keys[i] = key
    S.pause()
  end
  if handoff and not includesHandoff then return false, "handoff cell missing" end
  local pending = S.pendingReleases[who]
  if pending then
    for _, key in ipairs(keys) do pending[key] = nil S.pause() end
    if next(pending) == nil then S.pendingReleases[who] = nil end
  end
  local changed = false
  for _, key in ipairs(keys) do if S.reservations[key] ~= who then changed = true break end end
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

S.protectedValid = function(value)
  if type(value) ~= "table" or value.v ~= 1 or type(value.revision) ~= "number"
    or value.revision < 0 or value.revision % 1 ~= 0 or value.revision >= 2^53
    or type(value.boxes) ~= "table" or #value.boxes > 64 then return false end
  local ids, count = {}, 0
  for i, box in pairs(value.boxes) do
    if type(i) ~= "number" or i % 1 ~= 0 or i < 1 or i > #value.boxes
      or type(box) ~= "table" or type(box.id) ~= "string" or box.id == "" or #box.id > 64 or ids[box.id]
      or not ({["minecraft:overworld"]=true,["minecraft:the_nether"]=true,["minecraft:the_end"]=true})[box.dim] then return false end
    ids[box.id], count = true, count + 1
    for _, axis in ipairs({"x", "y", "z"}) do
      local lo, hi = box[axis .. "1"], box[axis .. "2"]
      if type(lo) ~= "number" or type(hi) ~= "number" or lo ~= lo or hi ~= hi
        or lo % 1 ~= 0 or hi % 1 ~= 0 or math.abs(lo) >= 2^53 or math.abs(hi) >= 2^53 or lo > hi then return false end
    end
  end
  return count == #value.boxes
end

S.membership = function(p, boxes)
  local found = {}
  for _, box in ipairs(boxes) do
    if p.dim == box.dim and p.x >= box.x1 and p.x <= box.x2 and p.y >= box.y1 and p.y <= box.y2
      and p.z >= box.z1 and p.z <= box.z2 then found[box.id] = true end
  end
  return found
end

S.protectionReady = function()
  local lease = SO.mods.lease
  if not lease or not lease.protectionReady or not lease.protectionReady() then return false, "reconcile leases first" end
  local checked = {}
  for _, who in pairs(S.reservations) do
    if not checked[who] then
      checked[who] = true
      local id = type(who) == "string" and tonumber(who:match(":(%d+)$"))
      local row = id and lease.peek(id)
      if not row or row.open or row.uncertain or row.boundaryHold or row.lost or not row.pose or not row.journal or not row.reconciled then
        return false, "reconcile reservations first"
      end
    end
  end
  return true
end

S.protected = function()
  return SO.store.copy(S.protectedState), S.protectionError
end

S.protect = function(boxes)
  if not S.protectedBox then return false, "protected data unreadable" end
  local value = {v=1,revision=S.protectedState.revision+1,boxes=SO.store.copy(boxes)}
  if type(value.boxes) == "table" then
    local plan = dofile("so-plan.lua")
    for _, box in ipairs(value.boxes) do
      if type(box) == "table" then
        box.dim = plan.dimension(box.dim)
        for _, axis in ipairs({"x","y","z"}) do
          local a,b = box[axis.."1"],box[axis.."2"]
          if type(a)=="number" and type(b)=="number" and a>b then box[axis.."1"],box[axis.."2"]=b,a end
        end
      end
    end
  end
  if not S.protectedValid(value) then return false, "invalid protected boxes" end
  local ready, reason = S.protectionReady()
  if not ready then return false, reason end
  local ok, err = S.protectedBox.save(value)
  if not ok then return false, err end
  S.protectedState, S.protectionError, S.protectionActive = value, nil, S.protectionEnabled
  return true
end

S.assessment = function(who, exit, targets)
  local reservations, protection = {}, SO.store.copy(S.protectedState)
  if targets then
    for _, p in ipairs(targets) do
      local key = S.cell(p.x,p.y,p.z,p.dim)
      reservations[key] = S.reservations[key]
    end
  else
    for key, holder in pairs(S.reservations) do reservations[key] = holder end
  end
  local blocked = S.protectionEnabled and (S.protectionError or not S.protectionActive and "reconcile protection first")
  return {
    admit = function(from, op, to)
      if S.protectionEnabled then
        if blocked then return false, blocked end
        local start, target = S.membership(from, protection.boxes), S.membership(to, protection.boxes)
        if exit then
          if protection.revision ~= exit.revision or not ({forward=true,back=true,up=true,down=true})[op] then return false, "protected" end
          for id in pairs(target) do
            if not exit.start[id] or exit.departed[id] then return false, "protected" end
          end
        elseif next(start) or next(target) then return false, "protected" end
      end
      local holder = reservations[S.cell(to.x, to.y, to.z, to.dim)]
      if holder and holder ~= who then return false, "held", holder end
      return true
    end,
    clear = function(p)
      local bits = S.dugBits(p.dim, math.floor(p.x/16), math.floor(p.y/16), math.floor(p.z/16), true)
      return type(bits) == "string" and S.bit(bits, p.x%16+16*(p.y%16)+256*(p.z%16)) or false
    end,
  }
end

S.admit = function(who, from, op, to)
  if not ({forward=true,back=true,up=true,down=true,dig=true,digUp=true,digDown=true,
    place=true,placeUp=true,placeDown=true,drop=true,dropUp=true,dropDown=true})[op] then return true end
  return S.assessment(who,nil,{to}).admit(from, op, to)
end

S.release = function(who, x, y, z, dim)
  local key = S.cell(x, y, z, dim)
  if S.reservations[key] ~= who then return true end
  local copy = S.copyReservations()
  copy[key] = nil
  return S.commit(copy)
end

S.releaseCells = function(who, keys)
  if S.policyDirty then
    local ok, err = S.savePolicy(S.policy)
    if not ok then return false, err end
  end
  local copy, count = {}, 0
  for key, held in pairs(S.reservations) do
    if held == who and keys[key] then count = count + 1 else copy[key] = held end
    S.pause()
  end
  if count == 0 then return true, 0 end
  local ok, err = S.commit(copy)
  if not ok then return false, err end
  return true, count
end

S.releaseOwner = function(who)
  local keys = {}
  for key, held in pairs(S.reservations) do
    if held == who then keys[key] = true end
    S.pause()
  end
  local ok, count = S.releaseCells(who, keys)
  if S.whoValid(who) then S.pendingReleases[who] = not ok and keys or nil end
  return ok, count
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
  if not S.bit(section.value.bits, index) then
    section.value.bits, section.dirty = S.bit(section.value.bits, index, true), true
    section.value.used = SO.now()
    S.used[path] = section.value.used
    S.sizes[path], S.dug = S.sizes[path] + 1, S.dug + 1
    S.changed(path)
  end
  S.pause()
  return true
end

S.isDug = function(x, y, z, dim)
  local _, path, index = S.cell(x, y, z, dim)
  local section, err = S.section(path)
  if not section then error(err, 2) end
  S.pause()
  return S.bit(section.value.bits, index)
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
  if S.bit(section.value.bits, index) then
    section.value.bits, section.dirty = S.bit(section.value.bits, index, false), true
    section.value.used = SO.now()
    S.used[path] = section.value.used
    S.sizes[path], S.dug = S.sizes[path] - 1, S.dug - 1
    S.changed(path)
  end
  return true
end

-- Read-only views for the map. They never load a section into the cache,
-- bump its use time or write anything.
S.changed = function(path)
  S.marks, S.stamps[path] = S.marks + 1, (S.stamps[path] or 0) + 1
  if not S.indexed[path] then S.index(path, true) end
end

S.index = function(path, add)
  local dim, sx, sy, sz = path:match("^so%-data/cells/(.-)/(%-?%d+)_(%-?%d+)_(%-?%d+)$")
  if not dim then return end
  local columns = S.columns[dim] or {}
  S.columns[dim] = columns
  local key = sx .. "_" .. sz
  local column = columns[key]
  S.indexed[path] = add or nil
  if add then
    column = column or { sx = tonumber(sx), sz = tonumber(sz), sy = {} }
    columns[key], column.sy[tonumber(sy)] = column, true
  elseif column then
    column.sy[tonumber(sy)] = nil
    if next(column.sy) == nil then columns[key] = nil end
  end
  S.columnsVersion = S.columnsVersion + 1
end

S.dugColumns = function(dim, sx1, sz1, sx2, sz2, max)
  local out = {}
  for _, column in pairs(S.columns[S.dimension(dim)] or {}) do
    if #out >= (max or 1024) then break end
    if column.sx >= sx1 and column.sx <= sx2 and column.sz >= sz1 and column.sz <= sz2 then
      local sy = {}
      for y in pairs(column.sy) do sy[#sy + 1] = y end
      table.sort(sy)
      out[#out + 1] = { sx = column.sx, sz = column.sz, sy = sy }
    end
    S.pause()
  end
  return out
end

-- Returns the bits (nil for an unknown or empty section) and a change stamp
-- that survives eviction. memoryOnly returns false for an evicted section.
S.dugBits = function(dim, sx, sy, sz, memoryOnly)
  local path = S.root .. S.dimension(dim) .. "/" .. string.format("%.0f_%.0f_%.0f", sx, sy, sz)
  local section, stamp = S.sections[path], S.stamps[path] or 0
  if section then return section.value.bits, stamp end
  if (S.sizes[path] or 0) == 0 then return nil, stamp end
  if memoryOnly then return false, stamp end
  local newest, bits = -1, nil
  for _, file in ipairs({ path, path .. ".tmp", path .. ".bak" }) do
    local saved = SO.store.read(file)
    if type(saved) == "table" and type(saved.generation) == "number" and saved.generation > newest
      and type(saved.value) == "table" and saved.value.format == "hex4096" and S.sectionValid(saved.value) then
      newest, bits = saved.generation, saved.value.bits
    end
  end
  return bits, stamp
end

S.reserved = function(dim, max)
  local key = S.dimension(dim)
  local cache = S.reservedCache[key]
  max = max or 4096
  if cache and cache.source == S.reservations and cache.max == max then return cache.list, cache.version end
  local list = {}
  for cell, who in pairs(S.reservations) do
    if #list >= max then break end
    local d, sx, sy, sz, index = cell:match("^so%-data/cells/(.-)/(%-?%d+)_(%-?%d+)_(%-?%d+):(%d+)$")
    if d == key then
      index = tonumber(index)
      list[#list + 1] = { x = tonumber(sx) * 16 + index % 16, y = tonumber(sy) * 16 + math.floor(index / 16) % 16,
        z = tonumber(sz) * 16 + math.floor(index / 256), who = who }
    end
    S.pause()
  end
  S.reservedVersion = S.reservedVersion + 1
  S.reservedCache[key] = { source = S.reservations, max = max, list = list, version = S.reservedVersion }
  return list, S.reservedVersion
end

-- Find the lowest held cell in a projected map cell, without the display-list cap.
S.holder = function(dim, x1, z1, x2, z2, y1, y2)
  local key, best = S.dimension(dim), nil
  for cell, who in pairs(S.reservations) do
    local d, sx, sy, sz, index = cell:match("^so%-data/cells/(.-)/(%-?%d+)_(%-?%d+)_(%-?%d+):(%d+)$")
    if d == key then
      index = tonumber(index)
      local x, y, z = tonumber(sx)*16 + index%16, tonumber(sy)*16 + math.floor(index/16)%16,
        tonumber(sz)*16 + math.floor(index/256)
      if x >= x1 and x <= x2 and z >= z1 and z <= z2 and (not y1 or y >= y1 and y <= y2)
        and (not best or y < best.y or y == best.y and (x < best.x or x == best.x and z < best.z)) then
        best = {who=who, x=x, y=y, z=z}
      end
    end
    S.pause()
  end
  return best
end

S.list = function(who, max)
  local out = {}
  max = max or 256
  for key, held in pairs(S.reservations) do
    if #out >= max then break end
    if held == who then
      local dim, sx, sy, sz, index = key:match("^so%-data/cells/(.-)/(%-?%d+)_(%-?%d+)_(%-?%d+):(%d+)$")
      if dim then
        dim = dim:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
        index = tonumber(index)
        out[#out + 1] = { dim = dim, x = tonumber(sx) * 16 + index % 16,
          y = tonumber(sy) * 16 + math.floor(index / 16) % 16,
          z = tonumber(sz) * 16 + math.floor(index / 256) }
      end
    end
  end
  return out
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

S.releaseReady = function(who)
  if not F.enabled(SO.store.read and SO.store.read("so-server.cfg"), "worldEdits") then return nil, "world edits disabled" end
  local id = type(who) == "string" and tonumber(who:match("^[%a]+:(%d+)$"))
  if not id or #S.list(who, 1) == 0 then return nil, "unknown holder" end
  if S.pendingReleases[who] then return nil, "owner release unresolved" end
  local lease = SO.mods.lease
  if not lease or not lease.releaseReady then return nil, "lease unavailable" end
  local contact, err = lease.releaseReady(id, S.bootAt)
  if not contact then return nil, err end
  return {id=id, contact=contact}
end

S.releaseRequest = function(who, actor, token)
  if not S.whoValid(actor) then return nil, "actor" end
  local ready, err = S.releaseReady(who)
  if not ready then return nil, err end
  local now, offer = SO.now(), S.confirmations[actor]
  if token == nil then
    S.serial = S.serial + 1
    offer = {who=who, actor=actor, token=now..":"..S.serial, untilAt=now+30000,
      reservations=S.reservations, contact=ready.contact}
    S.confirmations[actor] = offer
    return {status="confirm", token=offer.token, untilAt=offer.untilAt, who=who}
  end
  S.confirmations[actor] = nil
  if not offer or offer.token ~= token or offer.who ~= who or now > offer.untilAt
    or offer.reservations ~= S.reservations or offer.contact ~= ready.contact then return nil, "invalid confirmation" end
  local attempt = {status="pending", who=who}
  S.releases[who] = attempt
  local holds = SO.store.copy(S.releaseHolds)
  for key, held in pairs(S.reservations) do if held == who then holds[key] = held end end
  local held, holdErr = S.releaseBox.save(holds)
  if not held then attempt.status="held" return nil, holdErr end
  S.releaseHolds = holds
  local lid, reason = SO.mods.lease.releaseFence(ready.id, ready.contact, function(pose)
    if not pose or S.reservations ~= offer.reservations or not F.enabled(SO.store.read and SO.store.read("so-server.cfg"), "worldEdits") then
      attempt.status="held" return false
    end
    local key = S.cell(pose.x,pose.y,pose.z,pose.dim)
    local held = S.reservations[key]
    local occupied = "gps:"..ready.id
    if held and held ~= who and held ~= occupied then attempt.status="held" return false end
    if S.policyDirty and not S.savePolicy(S.policy) then attempt.status="held" return false end
    local pending = S.pendingReleases[occupied]
    if pending then
      pending[key] = nil
      if next(pending) == nil then S.pendingReleases[occupied] = nil end
    end
    local copy, count = S.copyReservations(), 0
    for _, owner in pairs(copy) do if owner == who then count = count+1 end end
    copy[key] = occupied
    local ok, saveErr = S.commit(copy)
    if ok then
      copy = S.copyReservations()
      for cell, owner in pairs(copy) do if owner == who and cell ~= key then copy[cell] = nil end end
      ok, saveErr = S.commit(copy)
    end
    attempt.status, attempt.error = ok and "released" or "held", saveErr
    if not ok then return false end
    S.pendingReleases[who], S.pendingReleases[occupied] = nil, nil
    local remaining = SO.store.copy(S.releaseHolds)
    for cell, owner in pairs(remaining) do if owner == who then remaining[cell] = nil end end
    -- A failed cleanup may restore extra holds after restart. It cannot lose a route.
    if S.releaseBox.save(remaining) then S.releaseHolds = remaining end
    attempt.count = count
    S.events[#S.events+1] = {who=who,count=count}
    return true
  end)
  if not lid then attempt.status="held" return nil, reason end
  attempt.lease = lid
  return SO.store.copy(attempt)
end

S.releaseStatus = function(who) return SO.store.copy(S.releases[who]) end

S.onForget = function(msg, reply)
  local body = msg.body
  if type(body) ~= "table" or not S.whoValid(body.who) then
    reply("err", {code="bad",text="bad owner"}) return
  end
  local result, err = S.releaseRequest(body.who, msg.from, body.confirm)
  if not result then reply("err", {code="release",text=tostring(err)})
  elseif result.status == "confirm" then reply("cells.forget", {confirm=result.token})
  else reply("ack", {ok=true,who=body.who,status=result.status,lease=result.lease}) end
end

S.normalBoxes = function(boxes)
  local value = {v=1,revision=0,boxes=SO.store.copy(boxes)}
  if type(value.boxes) ~= "table" then return nil end
  local plan = dofile("so-plan.lua")
  for _, box in ipairs(value.boxes) do
    if type(box) == "table" then
      box.dim = plan.dimension(box.dim)
      for _, axis in ipairs({"x","y","z"}) do
        local a,b = box[axis.."1"],box[axis.."2"]
        if type(a)=="number" and type(b)=="number" and a>b then box[axis.."1"],box[axis.."2"]=b,a end
      end
    end
  end
  return S.protectedValid(value) and value.boxes or nil
end

S.keep = function(boxes)
  if boxes == nil then return SO.store.copy(S.policy.keepBoxes or {}) end
  if not F.enabled(SO.store.read and SO.store.read("so-server.cfg"), "worldEdits") then return false, "world edits disabled" end
  boxes = S.normalBoxes(boxes)
  if not boxes then return false, "invalid keep boxes" end
  local policy = SO.store.copy(S.policy)
  policy.keepBoxes = boxes
  return S.savePolicy(policy)
end

S.clearMarks = function(box, actor, token)
  if not F.enabled(SO.store.read and SO.store.read("so-server.cfg"), "worldEdits") then return nil, "world edits disabled" end
  if not S.whoValid(actor) or type(box) ~= "table" then return nil, "selection" end
  box = SO.store.copy(box) box.id = "selection"
  local boxes = S.normalBoxes({box})
  if not boxes then return nil, "selection" end
  box = boxes[1]
  local paths = {}
  for x=math.floor(box.x1/16),math.floor(box.x2/16) do
    for y=math.floor(box.y1/16),math.floor(box.y2/16) do
      for z=math.floor(box.z1/16),math.floor(box.z2/16) do
        if #paths == 64 then return nil, "selection exceeds 64 sections" end
        paths[#paths+1] = S.root..S.dimension(box.dim).."/"..string.format("%.0f_%.0f_%.0f",x+0,y+0,z+0)
      end
    end
  end
  local protected = S.protection(true)
  if not protected then return nil, "unresolved recovery" end
  for _, path in ipairs(paths) do if protected(path) then return nil, "work or recovery intersects selection" end end
  local offer, now = S.edits[actor], SO.now()
  if not token then
    S.serial = S.serial+1
    S.edits[actor] = {token=now..":marks:"..S.serial,untilAt=now+30000,box=box,
      marks=S.marks,reservations=S.reservations}
    return {status="confirm",token=S.edits[actor].token,sections=#paths,box=SO.store.copy(box)}
  end
  S.edits[actor] = nil
  if not offer or offer.token ~= token or now > offer.untilAt or offer.marks ~= S.marks
    or offer.reservations ~= S.reservations then return nil, "invalid confirmation" end
  for k,v in pairs(box) do if offer.box[k] ~= v then return nil, "selection changed" end end
  local result, changed = {status="cleared",saved=0,total=#paths,marks=0}, {}
  for _, path in ipairs(paths) do
    local exists = fs.exists(path) or fs.exists(path..".bak") or fs.exists(path..".tmp")
    if exists then
      local section, err = S.section(path)
      if not section then result.error=err break end
      local value, removed = SO.store.copy(section.value), 0
      local stamp = S.stamps[path]
      local sx,sy,sz = path:match("/(%-?%d+)_(%-?%d+)_(%-?%d+)$")
      for z=math.max(box.z1,tonumber(sz)*16),math.min(box.z2,tonumber(sz)*16+15) do
        for y=math.max(box.y1,tonumber(sy)*16),math.min(box.y2,tonumber(sy)*16+15) do
          for x=math.max(box.x1,tonumber(sx)*16),math.min(box.x2,tonumber(sx)*16+15) do
            local index=x%16+16*(y%16)+256*(z%16)
            if S.bit(value.bits,index) then value.bits=S.bit(value.bits,index,false) removed=removed+1 end
          end
        end
      end
      if removed > 0 then
        local reservations = S.reservations
        local current = S.protection(true)
        if not current or current(path) or S.reservations ~= reservations or S.stamps[path] ~= stamp
          or not F.enabled(SO.store.read and SO.store.read("so-server.cfg"), "worldEdits") then
          result.error="selection became protected or changed" break
        end
        local ok
        ok, err = section.box.save(value)
        if not ok then result.error, result.uncertain = err, path break end
        S.sizes[path], S.dug = S.sizes[path]-removed, S.dug-removed
        if section.migrating then S.migrations = S.migrations-1 end
        S.sections[path], S.cached = nil, S.cached-1
        S.measure(path)
        S.changed(path)
        if S.sizes[path] == 0 then S.index(path,false) end
        changed[path] = true
        result.saved, result.marks = result.saved+1, result.marks+removed
      end
    end
    S.pause()
  end
  if result.error then result.status="partial" end
  local mine = SO.mods.mine
  if next(changed) and mine and mine.forgetDug then mine.forgetDug(changed) end
  return result
end

S.policyValid = function(value)
  if type(value) ~= "table" or type(value.nextAsk) ~= "number" or value.nextAsk ~= value.nextAsk or value.nextAsk < S.threshold
    or value.nextAsk >= math.huge or type(value.workers) ~= "table" then return false end
  if value.pressureAfter ~= nil and (type(value.pressureAfter) ~= "number" or value.pressureAfter ~= value.pressureAfter
    or value.pressureAfter < 0 or value.pressureAfter >= math.huge) then return false end
  if value.serial ~= nil and (type(value.serial) ~= "number" or value.serial < 0 or value.serial % 1 ~= 0) then return false end
  if value.keepBoxes ~= nil and not S.protectedValid({v=1,revision=0,boxes=value.keepBoxes}) then return false end
  local function point(p)
    if type(p) ~= "table" or type(p.dim) ~= "string" then return false end
    for _, axis in ipairs({ "x", "y", "z" }) do
      local n = p[axis]
      if type(n) ~= "number" or n ~= n or math.abs(n) == math.huge or n % 1 ~= 0 then return false end
    end
    return true
  end
  for id, worker in pairs(value.workers) do
    if type(id) ~= "string" or type(worker) ~= "table" or not point(worker.pose)
      or type(worker.dug) ~= "table" or #worker.dug > 32 then return false end
    for _, p in ipairs(worker.dug) do if not point(p) then return false end end
  end
  return true
end

S.savePolicy = function(nextPolicy)
  local ok, err = S.policyBox.save(nextPolicy)
  if ok then S.policy, S.policyDirty = nextPolicy, false end
  return ok, err
end

S.rememberWorker = function(id, pose, dug)
  S.policy.workers[tostring(id)] = SO.store.copy({ pose = pose, dug = dug })
  S.policyDirty = true
end

S.protection = function(marksOnly)
  local boxes, reserved = marksOnly and {} or SO.store.copy(S.policy.keepBoxes or {}), {}
  local function protect(dim, value, margin)
    local bounds
    local function visit(v)
      if type(v) ~= "table" then return end
      if type(v.x) == "number" and type(v.y) == "number" and type(v.z) == "number" then
        if not bounds then bounds = { x1=v.x, x2=v.x, y1=v.y, y2=v.y, z1=v.z, z2=v.z, dim=dim } end
        for _, axis in ipairs({ "x", "y", "z" }) do
          bounds[axis .. "1"] = math.min(bounds[axis .. "1"], v[axis])
          bounds[axis .. "2"] = math.max(bounds[axis .. "2"], v[axis])
        end
      end
      for _, child in pairs(v) do if type(child) == "table" then visit(child) end end
      S.pause()
    end
    visit(value)
    if bounds then
      for _, axis in ipairs({ "x", "y", "z" }) do
        bounds[axis .. "1"] = bounds[axis .. "1"] - (margin or 0)
        bounds[axis .. "2"] = bounds[axis .. "2"] + (margin or 0)
      end
      boxes[#boxes + 1] = bounds
    end
  end
  for key in pairs(S.reservations) do
    local path = key:match("^(.*):%d+$")
    if not path then return nil end
    reserved[path] = true
    S.pause()
  end
  if marksOnly then
    for key in pairs(S.releaseHolds) do
      local path = key:match("^(.*):%d+$")
      if not path then return nil end
      reserved[path] = true
    end
  end
  for _, worker in pairs(S.policy.workers) do
    protect(worker.pose.dim, worker.pose, 48)
    protect(worker.pose.dim, worker.dug, 0)
  end
  for _, name in ipairs({ "mine", "lumber", "lease", "build" }) do
    local mod = SO.mods[name]
    if mod and (type(mod.dugProtection) ~= "function" or mod.dugProtection(protect) ~= true) then return nil end
  end
  return function(path)
    if reserved[path] then return true end
    local dim, x, y, z = path:match("^so%-data/cells/(.-)/(%-?%d+)_(%-?%d+)_(%-?%d+)$")
    if not dim then return true end
    dim = dim:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    x, y, z = tonumber(x) * 16, tonumber(y) * 16, tonumber(z) * 16
    for _, b in ipairs(boxes) do
      if dim == b.dim and x <= b.x2 and x + 15 >= b.x1 and y <= b.y2 and y + 15 >= b.y1
        and z <= b.z2 and z + 15 >= b.z1 then return true end
    end
    return false
  end
end

S.candidates = function()
  local protected = S.protection()
  if not protected then return {} end
  local candidates = {}
  for path, bytes in pairs(S.bytes) do
    local section = S.sections[path]
    if bytes > 0 and not (section and section.dirty) and not protected(path) then
      candidates[#candidates + 1] = { path = path, bytes = bytes, used = S.used[path] or 0,
        version = S.versions[path] }
    end
    S.pause()
  end
  table.sort(candidates, function(a, b) return a.used < b.used or a.used == b.used and a.path < b.path end)
  local selected, reclaimed = {}, 0
  for _, candidate in ipairs(candidates) do
    selected[#selected + 1], reclaimed = candidate, reclaimed + candidate.bytes
    if S.total - reclaimed <= S.target then break end
  end
  return selected, reclaimed
end

S.amount = function(bytes)
  if bytes >= 1000000 then return string.format("%.1f MB", bytes / 1000000) end
  return string.format("%.0f KB", math.ceil(bytes / 1000))
end

S.retirement = function()
  if S.request then
    return { id = S.request.id, status = "pending", bytes = S.request.bytes,
      count = #S.request.candidates, reclaim = S.request.reclaim, text = S.request.text,
      areas = SO.store.copy(S.request.areas) }
  end
  if S.notice and SO.now() < S.notice.untilAt then return SO.store.copy(S.notice) end
  local state = SO.mods.state
  if S.policy.choice == "keep" and SO.now() < (S.policy.pressureAfter or 0)
    and state and state.disk and state.disk().pressure then
    return { status = "snoozed", text = "Disk full. Add disk space.", untilAt = S.policy.pressureAfter }
  end
end

S.checkRetirement = function(now)
  local state = SO.mods.state
  local pressure = state and state.disk and state.disk().pressure
  if now < (S.policy.pressureAfter or 0) then return end
  local pressureAsk = pressure
  if S.request or S.migrations > 0 or (S.total < S.policy.nextAsk and not pressureAsk) or (S.checked and now - S.checked < 10000) then return end
  S.checked = now
  local candidates, reclaim = S.candidates()
  if #candidates == 0 then return end
  local policy = SO.store.copy(S.policy)
  policy.serial = (policy.serial or 0) + 1
  if not S.savePolicy(policy) then return end
  local areas = {}
  for _, candidate in ipairs(candidates) do
    local dim, x, y, z = candidate.path:match("^so%-data/cells/(.-)/(%-?%d+)_(%-?%d+)_(%-?%d+)$")
    dim = dim:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    x, y, z = tonumber(x) * 16, tonumber(y) * 16, tonumber(z) * 16
    areas[#areas + 1] = { dim = dim, x1 = x, y1 = y, z1 = z, x2 = x + 15, y2 = y + 15, z2 = z + 15 }
    S.pause()
  end
  S.request = { id = tostring(now) .. ":" .. policy.serial, bytes = S.total,
    candidates = candidates, reclaim = reclaim, areas = areas, pressure = pressure,
    text = "Dug marks " .. S.amount(S.total) .. ". Forget " .. #candidates .. " areas ("
      .. S.amount(reclaim) .. ")?" }
end

S.decideRetirement = function(id, choice)
  local request = S.request
  if not request or request.id ~= id or (choice ~= "allow" and choice ~= "keep") then return false end
  local policy = SO.store.copy(S.policy)
  policy.nextAsk, policy.choice = math.max(S.threshold, math.ceil(S.total * 1.5)), choice
  policy.pressureAfter = SO.now() + (choice == "keep" and 600000 or 60000)
  local ok, err = S.savePolicy(policy)
  if not ok then return false, err end
  local forgotten, freed, forgottenPaths = 0, 0, {}
  if choice == "allow" then
    local protected = S.protection()
    for _, candidate in ipairs(request.candidates) do
      local path, section = candidate.path, S.sections[candidate.path]
      if protected and not protected(path) and (request.pressure or S.total > S.target) then
        if section and section.dirty then
          ok, err = S.saveSection(section)
          if not ok then break end
        end
        local bytes = S.bytes[path] or 0
        -- Remove every recovery generation before the primary, so a restart
        -- cannot restore marks the player allowed us to forget.
        local deleted, deleteErr = pcall(function()
          for _, suffix in ipairs({ ".bak", ".tmp", "" }) do
            if fs.exists(path .. suffix) then fs.delete(path .. suffix) end
          end
        end)
        S.measure(path)
        if not deleted then err = deleteErr break end
        if section then S.sections[path], S.cached = nil, S.cached - 1 end
        S.dug = S.dug - (S.sizes[path] or 0)
        S.sizes[path], S.used[path], S.versions[path] = nil, nil, nil
        S.changed(path)
        S.index(path, false)
        forgottenPaths[path] = true
        forgotten, freed = forgotten + 1, freed + bytes - (S.bytes[path] or 0)
      end
      S.pause()
    end
    local mine = SO.mods.mine
    if forgotten > 0 and mine and type(mine.forgetDug) == "function" then mine.forgetDug(forgottenPaths) end
    policy.nextAsk = math.max(S.threshold, math.ceil(S.total * 1.5))
    S.savePolicy(policy)
  end
  S.request = nil
  local text = choice == "keep" and "Kept."
    or ("Forgot marks for " .. forgotten .. " old areas. Freed " .. S.amount(freed) .. ".")
  if err then text = text .. " Storage error; retry later." end
  S.notice = { status = choice == "keep" and "kept" or "allowed", text = text,
    untilAt = SO.now() + 30000 }
  return true
end

S.tick = function(now)
  if S.protectionEnabled and not S.protectionActive and not S.protectionError and S.protectionReady() then
    S.protectionActive = true
  end
  now = now or SO.now()
  if S.policyDirty then
    local ok, err = S.savePolicy(S.policy)
    if not ok then return false, err end
  end
  for who, keys in pairs(S.pendingReleases) do
    local ok, err = S.releaseCells(who, keys)
    if not ok then return false, err end
    S.pendingReleases[who] = nil
    S.pause()
  end
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
    if (now or SO.now()) > pending.untilAt then S.confirmations[sender] = nil end
  end
  for actor, offer in pairs(S.edits) do
    if now > offer.untilAt then S.edits[actor] = nil end
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
  S.checkRetirement(now)
  return true
end

S.policyBox = SO.store.store("so-data/dug-policy", S.policyValid)
S.policy = S.policyBox.value or { nextAsk = S.threshold, workers = {} }
S.loading = true
fs.makeDir(S.root)
S.box = SO.store.store(S.root .. "res", S.resValid)
S.reservations = S.box.value or {}
S.releaseBox = SO.store.store(S.root .. "release-holds", S.resValid)
S.releaseHolds = S.releaseBox.value or {}
for key, who in pairs(S.releaseHolds) do
  if S.reservations[key] == nil then S.reservations[key] = who end
end
S.protectionEnabled = F.enabled(SO.store.read and SO.store.read("so-server.cfg"), "protectedAreas")
local protectionOK, protectionBox = pcall(SO.store.store, S.root .. "protected", S.protectedValid, 32768)
S.protectedBox = protectionOK and protectionBox or nil
if not protectionOK then S.protectionError = "protected data unreadable" end
S.protectedState = S.protectedBox and S.protectedValid(S.protectedBox.value) and S.protectedBox.value or {v=1,revision=0,boxes={}}
for _, suffix in ipairs({"", ".bak", ".tmp"}) do
  local path = S.root .. "protected" .. suffix
  if fs.exists and fs.exists(path) then
    local raw = SO.store.read(path)
    if type(raw) ~= "table" or not S.protectedValid(raw.value) then S.protectionError = "protected data unreadable" end
  end
end
for _, dim in ipairs(fs.list(S.root)) do
  if dim ~= "res" and dim ~= "res.tmp" and dim ~= "res.bak"
    and dim ~= "release-holds" and dim ~= "release-holds.tmp" and dim ~= "release-holds.bak"
    and dim ~= "protected" and dim ~= "protected.tmp" and dim ~= "protected.bak" then
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

S.loading = false

return {
  name = "cells", handlers = { ["cells.forget"] = S.onForget }, tick = S.tick,
  prepareHandoff = S.prepareHandoff, handoff = S.handoff, reserve = S.reserve, reserveMany = S.reserveMany, release = S.release,
  releaseRequest = S.releaseRequest, releaseStatus = S.releaseStatus, clearMarks = S.clearMarks, keep = S.keep,
  releaseOwner = S.releaseOwner, forgetOwner = S.forgetOwner, owner = S.owner, holder = S.holder,
  isFree = function(x, y, z, dim) return S.owner(x, y, z, dim) == nil end,
  retirement = S.retirement, decideRetirement = S.decideRetirement, rememberWorker = S.rememberWorker,
  markDug = S.markDug, isDug = S.isDug, forget = S.forget, counts = S.counts, list = S.list,
  dugColumns = S.dugColumns, dugBits = S.dugBits, reserved = S.reserved,
  protected = S.protected, protect = S.protect, admit = S.admit, assessment = S.assessment,
  dugVersion = function() return S.columnsVersion, S.marks end,
}
