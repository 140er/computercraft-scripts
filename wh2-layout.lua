-- Layout registry. Default off until ssot.cfg.wh2.enabled is true.
-- W1 routes wh2-layout and the locations, rooms, slots, and classes topics here.
-- H4b1 replaces lib/stubs/layout_dep.lua. T1 sends verified fixtures through kind "fixture".

local M = {}

local KINDS = {
  dropoff = true, charge = true, parking = true, warehouse_input = true, warehouse_output = true,
  storage = true, furnace = true, blast = true, smoker = true, room = true,
}
local SLOT_KINDS = { chest = true, furnace = true, blast = true, smoker = true }
local CLASSES = { any = true, ores = true, ingots = true, gems = true, fuel = true, misc = true }
local ROUTES = { store = true, furnace = true, blast = true, smoker = true, fuel = true, unknown = true }
local RESERVE = { access = true, entrance = true, parking = true, charge = true, machine = true }
local FIXTURE_KIND = {
  chest = "storage", dropoff = "dropoff", charger = "charge", furnace = "furnace",
  blast = "blast", smoker = "smoker",
}
local ROOM_FIELDS = { accessPaths = true, blocked = true, reserved = true }
local BUDGET = 98304
local RECORD_BUDGET = 65536
local UPLOAD_IDLE_MS = 30000
local PAGE_BYTES = 4096

local function int(n, a, b)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= a and n <= b
end

local function word(v, n)
  return type(v) == "string" and #v > 0 and #v <= (n or 64) and v:match("^[%w_:./%-]+$") ~= nil
end

local function itemId(v)
  return type(v) == "string" and #v > 0 and #v <= 128 and v:match("^[%w_]+:[%w_/%.%-]+$") ~= nil
end

local function fail(code, error)
  return { ok = false, code = code, error = error }
end

local function copy(v, seen)
  if type(v) ~= "table" then
    if type(v) == "number" and (v ~= v or v == math.huge or v == -math.huge) then return nil, "number" end
    return v
  end
  seen = seen or {}
  if seen[v] or getmetatable(v) then return nil, "table" end
  seen[v] = true
  local out = {}
  for k, item in pairs(v) do
    if type(k) ~= "string" and type(k) ~= "number" then return nil, "key" end
    local ck, err = copy(k, seen)
    if err then return nil, err end
    local cv, err2 = copy(item, seen)
    if err2 then return nil, err2 end
    out[ck] = cv
  end
  seen[v] = nil
  return out
end

local function canonical(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local keys, parts = {}, {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) < type(b)
  end)
  for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. canonical(k) .. "]=" .. canonical(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.encoded(v)
  return #canonical(v)
end

function M.pose(p)
  if type(p) ~= "table" or p.v ~= 1 then return false end
  if p.frame ~= "abs" and not (type(p.frame) == "string" and p.frame:match("^f:[%w_:./%-]+$") and #p.frame <= 64) then return false end
  if type(p.yAbs) ~= "boolean" then return false end
  if p.frame == "abs" and p.yAbs ~= true then return false end
  if not itemId(p.dim) and not (type(p.dim) == "string" and p.dim:match("^[%w_]+:[%w_/%.%-]+$")) then return false end
  if not int(p.x, -30000000, 30000000) or not int(p.y, -2048, 2048) or not int(p.z, -30000000, 30000000) then return false end
  if not int(p.h, 0, 3) then return false end
  if p.conf ~= "certain" and p.conf ~= "suspect" and p.conf ~= "lost" then return false end
  if p.src ~= "gps" and p.src ~= "neighbour" and p.src ~= "radio" and p.src ~= "typed"
    and p.src ~= "reckoned" and p.src ~= "inherited" then return false end
  if not int(p.anchoredAt, 0, 9007199254740991) then return false end
  return true
end

local function keysOf(t, allowed)
  if type(t) ~= "table" then return false end
  for k in pairs(t) do if not allowed[k] then return false end end
  return true
end

function M.empty()
  return {
    v = 1, revision = 0, enabled = false,
    locations = {}, rooms = {}, slots = {}, classDefaults = {},
    uploads = { stages = {}, watermarks = {}, receipts = {} },
  }
end

function M.config(raw)
  raw = type(raw) == "table" and raw or {}
  local operators = {}
  if type(raw.operators) == "table" then
    for id, on in pairs(raw.operators) do
      local n = type(id) == "number" and id or tonumber(id)
      if int(n, 0, 2147483647) and on == true then operators[tostring(n)] = true end
    end
  end
  return {
    enabled = raw.enabled == true,
    operators = operators,
    recipeHubId = raw.recipeHubId,
  }
end

function M.orderKey(computerId, counter)
  if not int(computerId, 0, 2147483647) or not int(counter, 1, 2147483647) then return nil end
  local key = "cw:" .. computerId .. ":" .. counter
  if #key > 64 then return nil end
  return key
end

function M.fingerprintMatches(detail, nbt)
  if nbt == nil or nbt == false then return true end
  if type(nbt) ~= "string" or type(detail) ~= "table" then return false end
  return detail.nbt == nbt or detail.fingerprint == nbt
end

local function step(h)
  if h == 0 then return 0, -1 end
  if h == 1 then return 1, 0 end
  if h == 2 then return 0, 1 end
  if h == 3 then return -1, 0 end
end

local function samePos(a, b)
  return a.frame == b.frame and a.dim == b.dim and a.x == b.x and a.y == b.y and a.z == b.z and a.h == b.h
end

local function sameCell(a, b)
  return a.frame == b.frame and a.dim == b.dim and a.x == b.x and a.y == b.y and a.z == b.z
end

local function cellKey(p)
  return p.frame .. "|" .. p.dim .. "|" .. p.x .. "|" .. p.y .. "|" .. p.z
end

function M.targets(access, block)
  if type(access) ~= "table" or not M.pose(access.pose) or not M.pose(block) then return false end
  if access.pose.frame ~= block.frame or access.pose.dim ~= block.dim then return false end
  if access.side == "top" then return access.pose.x == block.x and access.pose.z == block.z and access.pose.y + 1 == block.y end
  if access.side == "bottom" then return access.pose.x == block.x and access.pose.z == block.z and access.pose.y - 1 == block.y end
  if access.side ~= "front" then return false end
  local dx, dz = step(access.pose.h)
  return access.pose.x + dx == block.x and access.pose.y == block.y and access.pose.z + dz == block.z
end

local function siteNamesOk(kind, names, lockId)
  if type(names) ~= "table" or not keysOf(names, { source = true, drop = true, charge = true }) then return false end
  local function named(v) return word(v) end
  local function off(v) return v == false end
  local s, d, c = names.source, names.drop, names.charge
  if kind == "parking" or kind == "room" then return off(s) and off(d) and off(c) and lockId == false end
  if kind == "charge" then return off(s) and off(d) and named(c) and word(lockId) end
  if kind == "warehouse_input" then return named(s) and off(d) and off(c) and word(lockId) end
  if kind == "storage" then return named(s) and (off(d) or named(d)) and off(c) and word(lockId) end
  if kind == "dropoff" or kind == "warehouse_output" or kind == "furnace" or kind == "blast" or kind == "smoker" then
    return off(s) and named(d) and off(c) and word(lockId)
  end
  return false
end

local function validClass(row, source)
  return type(row) == "table" and row.v == 1 and itemId(row.item) and CLASSES[row.class] and ROUTES[row.route]
    and CLASSES[row.storeCategory] and (row.recipeId == false or word(row.recipeId, 128))
    and row.source == source and int(row.revision, 0, 2147483647) and int(row.updatedBy, 0, 2147483647)
    and keysOf(row, { v = true, item = true, class = true, route = true, storeCategory = true, recipeId = true, source = true, revision = true, updatedBy = true })
end

local function validStack(stack)
  if stack == false then return false end
  return type(stack) == "table" and itemId(stack.item) and int(stack.count, 1, 1000000) and int(stack.maxCount, 1, 1000000)
    and stack.count <= stack.maxCount and (stack.nbt == false or (type(stack.nbt) == "string" and #stack.nbt > 0 and #stack.nbt <= 128))
    and keysOf(stack, { item = true, count = true, maxCount = true, nbt = true })
end

local function validLocation(loc)
  if type(loc) ~= "table" or loc.v ~= 1 or not word(loc.id) or not KINDS[loc.kind] or type(loc.enabled) ~= "boolean" then return false end
  if not (loc.roomId == false or word(loc.roomId)) or not int(loc.revision, 0, 2147483647) then return false end
  if not siteNamesOk(loc.kind, loc.siteNames, loc.lockId) then return false end
  local allowed = { v = true, id = true, kind = true, roomId = true, enabled = true, siteNames = true, lockId = true, revision = true, block = true, access = true }
  if not keysOf(loc, allowed) then return false end
  if loc.kind == "room" then return loc.block == nil and loc.access == nil end
  if loc.kind == "parking" then
    return loc.block == nil and type(loc.access) == "table" and (loc.access.side == "front" or loc.access.side == "top" or loc.access.side == "bottom")
      and M.pose(loc.access.pose) and keysOf(loc.access, { pose = true, side = true })
  end
  if not M.pose(loc.block) or type(loc.access) ~= "table" then return false end
  if loc.access.side ~= "front" and loc.access.side ~= "top" and loc.access.side ~= "bottom" then return false end
  if not keysOf(loc.access, { pose = true, side = true }) or not M.pose(loc.access.pose) then return false end
  return M.targets(loc.access, loc.block)
end

local function boundsOk(bounds, limits)
  if type(bounds) ~= "table" or not M.pose(bounds.min) or not M.pose(bounds.max) then return false end
  if bounds.min.frame ~= bounds.max.frame or bounds.min.dim ~= bounds.max.dim then return false end
  local dx = bounds.max.x - bounds.min.x + 1
  local dy = bounds.max.y - bounds.min.y + 1
  local dz = bounds.max.z - bounds.min.z + 1
  if dx < 1 or dy < 1 or dz < 1 then return false end
  if dx > limits.roomMaxSize or dz > limits.roomMaxSize or dy > limits.roomMaxHeight then return false end
  if dx * dy * dz > limits.roomMaxCells then return false end
  return true, dx * dy * dz
end

local function inside(bounds, pos)
  return pos.frame == bounds.min.frame and pos.dim == bounds.min.dim
    and pos.x >= bounds.min.x and pos.x <= bounds.max.x
    and pos.y >= bounds.min.y and pos.y <= bounds.max.y
    and pos.z >= bounds.min.z and pos.z <= bounds.max.z
end

local function adjacent(a, b)
  if a.frame ~= b.frame or a.dim ~= b.dim then return false end
  local d = math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
  return d == 1
end

local function normalizeUploads(layout)
  local u = layout.uploads
  if type(u) ~= "table" then return nil end
  u.stages = type(u.stages) == "table" and u.stages or {}
  u.watermarks = type(u.watermarks) == "table" and u.watermarks or {}
  u.receipts = type(u.receipts) == "table" and u.receipts or {}
  layout.uploads = u
  return u
end

local function limitsOf(context)
  local s = type(context) == "table" and context.settings or nil
  local function pick(name, default, lo, hi)
    if type(s) == "table" and int(s[name], lo, hi) then return s[name] end
    return default
  end
  return {
    roomMaxSize = pick("roomMaxSize", 48, 1, 48),
    roomMaxHeight = pick("roomMaxHeight", 24, 1, 24),
    roomMaxCells = pick("roomMaxCells", 6000, 1, 6000),
  }
end

local function observe(s, context, pos)
  if type(context) == "table" and type(context.observe) == "function" then return context.observe(pos) end
  local ok, stub = pcall(dofile, "lib/stubs/layout_dep.lua")
  if ok and type(stub) == "table" and type(stub.observe) == "function" then return stub.observe(s, pos) end
  return nil
end

local function air(s, context, pos, blocked)
  if blocked and blocked[cellKey(pos)] then return false end
  return observe(s, context, pos) == "minecraft:air"
end

local function pathOk(path, location, room, s, context)
  if type(path) ~= "table" or #path < 1 or #path > 6000 then return false end
  for i, pos in ipairs(path) do
    if not M.pose(pos) or not inside(room.bounds, pos) then return false end
    if pos.frame ~= room.bounds.min.frame or pos.dim ~= room.bounds.min.dim then return false end
    if i > 1 and not adjacent(path[i - 1], pos) then return false end
    if not air(s, context, pos, room.blocked) then return false end
  end
  local last = path[#path]
  return samePos(last, location.access.pose)
end

local function reserveKind(loc)
  if loc.kind == "parking" then return "parking" end
  if loc.kind == "charge" then return "charge" end
  if loc.kind == "furnace" or loc.kind == "blast" or loc.kind == "smoker" then return "machine" end
  return "access"
end

local function reservedCell(room, pos, kind, locationId)
  local row = room.reserved[cellKey(pos)]
  return type(row) == "table" and row.kind == kind and row.locationId == locationId
end

local function roomLinksOk(layout, s, context)
  for _, loc in pairs(layout.locations) do
    if type(loc.roomId) == "string" then
      local room = layout.rooms[loc.roomId]
      if loc.kind ~= "room" and room and loc.access then
        if not inside(room.bounds, loc.access.pose) then return false, "location access is outside its room" end
        if loc.block and not inside(room.bounds, loc.block) then return false, "location block is outside its room" end
        local kind = reserveKind(loc)
        if kind == "access" then
          if not (reservedCell(room, loc.access.pose, "access", loc.id) or reservedCell(room, loc.access.pose, "entrance", loc.id)) then
            return false, "standing cell is not reserved"
          end
        elseif not reservedCell(room, loc.access.pose, kind, loc.id) then
          return false, "standing cell is not reserved"
        end
        local path = room.accessPaths[loc.id]
        if path then
          for i, pos in ipairs(path) do
            local expect = (i == #path and kind ~= "access") and kind or "access"
            if i == #path and kind == "access" then
              if not (reservedCell(room, pos, "access", loc.id) or reservedCell(room, pos, "entrance", loc.id)) then
                return false, "path cell is not reserved"
              end
            elseif not reservedCell(room, pos, expect, loc.id) then
              return false, "path cell is not reserved"
            end
          end
          if not pathOk(path, loc, room, s, context) then return false, "access path is not observed air" end
        end
      end
    end
  end
  return true
end

local function validRoom(room, limits)
  if type(room) ~= "table" or room.v ~= 1 or not word(room.id) or type(room.scanComplete) ~= "boolean" then return false end
  if not int(room.revision, 0, 2147483647) or not boundsOk(room.bounds, limits) then return false end
  if not keysOf(room, { v = true, id = true, revision = true, scanComplete = true, bounds = true, observedChunks = true, blocked = true, accessPaths = true, reserved = true }) then return false end
  if type(room.observedChunks) ~= "table" or type(room.blocked) ~= "table" or type(room.accessPaths) ~= "table" or type(room.reserved) ~= "table" then return false end
  for key, rev in pairs(room.observedChunks) do
    if type(key) ~= "string" or not key:match("^[%w_:./%-]+|[%w_]+:[%w_/%.%-]+|%-?%d+|%-?%d+|%-?%d+$") or not int(rev, 0, 2147483647) then return false end
  end
  for key, name in pairs(room.blocked) do
    if type(key) ~= "string" or not itemId(name) then return false end
  end
  for id, path in pairs(room.accessPaths) do
    if not word(id) or type(path) ~= "table" then return false end
    for i, pos in ipairs(path) do
      if not int(i, 1, #path) or not M.pose(pos) then return false end
    end
  end
  for key, row in pairs(room.reserved) do
    if type(key) ~= "string" or type(row) ~= "table" or not RESERVE[row.kind] or not word(row.locationId) then return false end
    if not keysOf(row, { kind = true, locationId = true }) then return false end
  end
  return M.encoded(room) <= RECORD_BUDGET
end

local function validSlot(slot)
  if type(slot) ~= "table" or slot.v ~= 1 or not word(slot.id) or not SLOT_KINDS[slot.kind] then return false end
  if not (slot.roomId == false or word(slot.roomId)) or not word(slot.locationId) then return false end
  if not (slot.category == false or CLASSES[slot.category]) or not int(slot.revision, 0, 2147483647) then return false end
  if not int(slot.observedAt, 0, 9007199254740991) then return false end
  local machine = slot.kind ~= "chest"
  if machine then
    if slot.size ~= 3 or type(slot.roles) ~= "table" then return false end
    if slot.roles[1] ~= "input" or slot.roles[2] ~= "fuel" or slot.roles[3] ~= "output" then return false end
  elseif not int(slot.size, 1, 54) or slot.roles ~= nil then return false end
  if slot.contents ~= false then
    if type(slot.contents) ~= "table" then return false end
    for i, stack in pairs(slot.contents) do
      if not int(i, 1, slot.size) or not validStack(stack) then return false end
    end
    if M.encoded(slot.contents) > RECORD_BUDGET then return false end
  end
  return true
end

function M.valid(value, poseValidator)
  if value == nil then return true end
  if type(value) ~= "table" or value.v ~= 1 or not int(value.revision, 0, 2147483647) then return false end
  if value.enabled ~= nil and type(value.enabled) ~= "boolean" then return false end
  if type(value.locations) ~= "table" or type(value.rooms) ~= "table" or type(value.slots) ~= "table" then return false end
  if type(value.classDefaults) ~= "table" or type(value.uploads) ~= "table" then return false end
  local pose = poseValidator or M.pose
  for id, loc in pairs(value.locations) do
    if id ~= loc.id or not validLocation(loc) then return false end
    if loc.block and not pose(loc.block) then return false end
    if loc.access and not pose(loc.access.pose) then return false end
    for _, pathRoom in pairs(value.rooms) do
      local path = pathRoom.accessPaths and pathRoom.accessPaths[id]
      if path then for _, stepPos in ipairs(path) do if not pose(stepPos) then return false end end end
    end
  end
  for id, room in pairs(value.rooms) do
    if id ~= room.id or not validRoom(room, limitsOf(nil)) then return false end
  end
  for id, slot in pairs(value.slots) do
    if id ~= slot.id or not validSlot(slot) then return false end
  end
  for item, row in pairs(value.classDefaults) do
    if item ~= row.item or not validClass(row, "layout") then return false end
  end
  local u = value.uploads
  if u.stages ~= nil or u.watermarks ~= nil or u.receipts ~= nil then
    if type(u.stages) ~= "table" or type(u.watermarks) ~= "table" or type(u.receipts) ~= "table" then return false end
  end
  return M.encoded(value) <= BUDGET
end

local function rotate(x, z, rot)
  if rot == 0 then return x, z end
  if rot == 1 then return -z, x end
  if rot == 2 then return -x, -z end
  if rot == 3 then return z, -x end
end

function M.toAbs(pos, frame)
  if not M.pose(pos) or type(frame) ~= "table" or frame.v ~= 1 or type(frame.id) ~= "string" then return nil end
  if pos.frame ~= frame.id or type(frame.toAbs) ~= "table" then return nil end
  local t = frame.toAbs
  if not int(t.dx, -30000000, 30000000) or not int(t.dy, -2048, 2048) or not int(t.dz, -30000000, 30000000) or not int(t.rot, 0, 3) then return nil end
  local x, z = rotate(pos.x, pos.z, t.rot)
  local y = pos.yAbs and pos.y or pos.y + t.dy
  local out = copy(pos)
  out.frame, out.yAbs = "abs", true
  out.x, out.y, out.z, out.h = x + t.dx, y, z + t.dz, (pos.h + t.rot) % 4
  if not M.pose(out) then return nil end
  return out
end

local function splitKey(key)
  local parts = {}
  for part in string.gmatch(key, "[^|]+") do parts[#parts + 1] = part end
  if #parts ~= 5 then return nil end
  return parts[1], parts[2], tonumber(parts[3]), tonumber(parts[4]), tonumber(parts[5])
end

local function convertCellKey(key, frame)
  local id, dim, x, y, z = splitKey(key)
  if id ~= frame.id or not int(x, -30000000, 30000000) or not int(y, -2048, 2048) or not int(z, -30000000, 30000000) then return key end
  local probe = {
    v = 1, frame = id, yAbs = true, dim = dim, x = x, y = y, z = z, h = 0,
    conf = "certain", src = "typed", anchoredAt = 0,
  }
  local abs = M.toAbs(probe, frame)
  if not abs then return nil end
  return cellKey(abs)
end

function M.applyFrameMerge(layout, frame)
  if type(layout) ~= "table" or type(frame) ~= "table" or frame.toAbs == false or type(frame.toAbs) ~= "table" then return nil end
  local nextLayout = copy(layout)
  if not nextLayout then return nil end
  local t = frame.toAbs
  local aligned = int(t.rot, 0, 3) and t.rot == 0 and int(t.dx, -30000000, 30000000) and t.dx % 16 == 0 and int(t.dz, -30000000, 30000000) and t.dz % 16 == 0
  for _, loc in pairs(nextLayout.locations or {}) do
    if loc.block and loc.block.frame == frame.id then
      loc.block = M.toAbs(loc.block, frame) or loc.block
    end
    if loc.access and loc.access.pose.frame == frame.id then
      loc.access.pose = M.toAbs(loc.access.pose, frame) or loc.access.pose
    end
  end
  for _, room in pairs(nextLayout.rooms or {}) do
    local touched = false
    if room.bounds.min.frame == frame.id then
      room.bounds.min = M.toAbs(room.bounds.min, frame) or room.bounds.min
      room.bounds.max = M.toAbs(room.bounds.max, frame) or room.bounds.max
      touched = true
    end
    local blocked, reserved, paths = {}, {}, {}
    for key, name in pairs(room.blocked) do
      local converted = key:sub(1, #frame.id) == frame.id and convertCellKey(key, frame) or key
      if converted then blocked[converted] = name end
    end
    for key, row in pairs(room.reserved) do
      local converted = key:sub(1, #frame.id) == frame.id and convertCellKey(key, frame) or key
      if converted then reserved[converted] = row end
    end
    for id, path in pairs(room.accessPaths) do
      local out = {}
      for i, pos in ipairs(path) do
        out[i] = pos.frame == frame.id and (M.toAbs(pos, frame) or pos) or pos
      end
      paths[id] = out
    end
    room.blocked, room.reserved, room.accessPaths = blocked, reserved, paths
    if touched then
      local chunks = {}
      for key, rev in pairs(room.observedChunks) do
        local id, dim, cx, cy, cz = splitKey(key)
        if id == frame.id and aligned and int(cx, -30000000, 30000000) and int(cy, -2048, 2048) and int(cz, -30000000, 30000000) then
          local nx = cx + t.dx / 16
          local nz = cz + t.dz / 16
          local ny = room.bounds.min.yAbs and cy or cy
          chunks["abs|" .. dim .. "|" .. nx .. "|" .. ny .. "|" .. nz] = rev
        elseif id ~= frame.id then
          chunks[key] = rev
        end
      end
      if not aligned then room.scanComplete = false end
      room.observedChunks = chunks
    end
  end
  return nextLayout
end

function M.project(layout)
  local sites = {}
  for _, loc in pairs(layout.locations or {}) do
    if loc.enabled and loc.access and loc.kind ~= "room" and loc.kind ~= "parking" then
      local function put(name, kind)
        if type(name) == "string" then
          sites[name] = { kind = kind, pose = copy(loc.access.pose), side = loc.access.side }
        end
      end
      put(loc.siteNames.source, "source")
      put(loc.siteNames.drop, "drop")
      put(loc.siteNames.charge, "charge")
    elseif loc.enabled and loc.kind == "parking" and loc.access then
      -- Parking has no warehouse site. The access pose stays on the location.
    end
  end
  return sites
end

function M.lockGroup(layout, siteName)
  local lockId
  for _, loc in pairs(layout.locations or {}) do
    local names = loc.siteNames or {}
    if names.source == siteName or names.drop == siteName or names.charge == siteName then lockId = loc.lockId end
  end
  if type(lockId) ~= "string" then return { siteName } end
  local seen, names = {}, {}
  for _, loc in pairs(layout.locations or {}) do
    if loc.lockId == lockId then
      local sn = loc.siteNames or {}
      for _, key in ipairs({ "source", "drop", "charge" }) do
        if type(sn[key]) == "string" and not seen[sn[key]] then
          seen[sn[key]] = true
          names[#names + 1] = sn[key]
        end
      end
    end
  end
  table.sort(names)
  if #names == 0 then return { siteName } end
  return names
end

local function defaultSites(kind, id)
  local none = { source = false, drop = false, charge = false }
  if kind == "parking" or kind == "room" then return none, false end
  if kind == "charge" then return { source = false, drop = false, charge = id }, "lock:" .. id end
  if kind == "warehouse_input" or kind == "storage" then return { source = id, drop = false, charge = false }, "lock:" .. id end
  return { source = false, drop = id, charge = false }, "lock:" .. id
end

function M.fixtureToLocation(fixture)
  if type(fixture) ~= "table" or fixture.v ~= 1 or not word(fixture.id) then return nil end
  if fixture.state ~= "verified" and fixture.state ~= "active" then return nil end
  local kind = FIXTURE_KIND[fixture.kind]
  if not kind or not M.pose(fixture.pos) then return nil end
  local side = fixture.side or "front"
  if side ~= "front" and side ~= "top" and side ~= "bottom" then return nil end
  local access = fixture.access
  if access == nil then
    local pose = copy(fixture.pos)
    if side == "front" then
      local dx, dz = step(pose.h)
      pose.x, pose.z = pose.x - dx, pose.z - dz
    elseif side == "top" then pose.y = pose.y - 1
    else pose.y = pose.y + 1 end
    access = { pose = pose, side = side }
  end
  local names, lockId = defaultSites(kind, fixture.id)
  local loc = {
    v = 1, id = fixture.id, kind = kind, roomId = word(fixture.roomId) and fixture.roomId or false,
    enabled = true, block = copy(fixture.pos), access = copy(access),
    siteNames = names, lockId = lockId, revision = 0,
  }
  if not validLocation(loc) then return nil end
  return loc
end

function M.effectiveClasses(layout, wizard)
  local rows = {}
  for item, row in pairs(layout.classDefaults or {}) do rows[item] = copy(row) end
  local wizardRevision = 0
  if type(wizard) == "table" then
    if int(wizard.revision, 0, 2147483647) then wizardRevision = wizard.revision end
    if type(wizard.classes) == "table" then
      for item, row in pairs(wizard.classes) do
        if item == row.item and validClass(row, "wizard") then rows[item] = copy(row) end
      end
    end
  end
  return rows, tostring(layout.revision or 0) .. ":" .. tostring(wizardRevision)
end

function M.arm(s, config)
  if type(s) ~= "table" or not (type(config) == "table" and config.enabled == true) then return false end
  s.wh2 = type(s.wh2) == "table" and s.wh2 or {}
  if type(s.wh2.layout) ~= "table" then s.wh2.layout = M.empty() end
  s.wh2.layout.enabled = true
  return true
end

local function operator(context, id)
  local ops = context.config and context.config.operators
  return type(ops) == "table" and ops[tostring(id)] == true
end

local function busy(s, loc, context)
  if type(loc) ~= "table" then return false end
  local names = {}
  local sn = loc.siteNames or {}
  for _, key in ipairs({ "source", "drop", "charge" }) do
    if type(sn[key]) == "string" then names[#names + 1] = sn[key] end
  end
  local wh = s.warehouse
  if type(wh) == "table" then
    for _, name in ipairs(names) do
      if type(wh.locks) == "table" and wh.locks[name] then return true end
    end
    for _, job in pairs(type(wh.orders) == "table" and wh.orders or {}) do
      if type(job) == "table" and (job.status == "open" or job.status == "active") then
        for _, name in ipairs(names) do
          if job.drop == name then return true end
          for _, line in ipairs(type(job.lines) == "table" and job.lines or {}) do
            if type(line) == "table" and line.source == name then return true end
          end
        end
      end
    end
  end
  if type(context.busy) == "function" and context.busy(loc.id) then return true end
  return false
end

local function sharedLock(layout, loc)
  if not loc.block then return true end
  for _, other in pairs(layout.locations) do
    if other.id ~= loc.id and other.block and sameCell(other.block, loc.block) and other.lockId ~= loc.lockId then
      return false
    end
  end
  return true
end

local function scanCompleteOk(room, s, context)
  if not room.scanComplete then return true end
  local min, max = room.bounds.min, room.bounds.max
  for y = min.y, max.y do
    for z = min.z, max.z do
      for x = min.x, max.x do
        local pos = { frame = min.frame, dim = min.dim, x = x, y = y, z = z }
        local key = cellKey(pos)
        if room.blocked[key] == nil and observe(s, context, pos) == nil then return false end
      end
    end
  end
  return true
end

local readField

local function pageOf(rows, cursor)
  if not int(cursor, 0, 2147483647) then return nil, fail("invalid", "invalid cursor") end
  local out, bytes, i = {}, 2, cursor + 1
  while i <= #rows and #out < 64 do
    local n = #canonical(rows[i]) + 1
    if #out > 0 and bytes + n > PAGE_BYTES then break end
    if #out == 0 and n > PAGE_BYTES then return nil, fail("too_large", "record needs a subresource page") end
    out[#out + 1] = rows[i]
    bytes = bytes + n
    i = i + 1
  end
  return { ok = true, records = out, cursor = i <= #rows and (i - 1) or 0 }
end

local function sortedIds(map)
  local ids = {}
  for id in pairs(map) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

local function readLayout(s, layout, message, context)
  local topic = message.topic
  if topic ~= "locations" and topic ~= "rooms" and topic ~= "slots" and topic ~= "classes" then
    return fail("unavailable", "topic is not owned by layout")
  end
  if message.revision ~= nil and message.revision ~= layout.revision and topic ~= "classes" then
    return fail("stale_revision", "layout revision changed")
  end
  if topic == "classes" then
    local pinned = message.revision
    local rows, revision = M.effectiveClasses(layout, s.wh2 and s.wh2.wizard)
    if pinned ~= nil and pinned ~= revision then return fail("stale_revision", "class revision changed") end
    local list = {}
    if message.id ~= nil then
      if rows[message.id] then list[1] = rows[message.id] end
    else
      for _, item in ipairs(sortedIds(rows)) do list[#list + 1] = rows[item] end
    end
    local paged, err = pageOf(list, message.cursor or 0)
    if not paged then return err end
    paged.revision = revision
    return paged
  end
  local map = topic == "locations" and layout.locations or topic == "rooms" and layout.rooms or layout.slots
  if message.id ~= nil then
    local row = map[message.id]
    if not row then return { ok = true, revision = layout.revision, records = {}, cursor = 0 } end
    if message.field ~= nil then
      return readField(row, message, layout.revision)
    end
    local paged, err = pageOf({ copy(row) }, message.cursor or 0)
    if not paged then return err end
    paged.revision = layout.revision
    return paged
  end
  local list = {}
  for _, id in ipairs(sortedIds(map)) do list[#list + 1] = copy(map[id]) end
  local paged, err = pageOf(list, message.cursor or 0)
  if not paged then return err end
  paged.revision = layout.revision
  return paged
end

readField = function(row, message, revision)
  local field = message.field
  local list = {}
  if row.accessPaths and field == "accessPaths" then
    if not word(message.pathId) then return fail("invalid", "path id required") end
    local path = row.accessPaths[message.pathId] or {}
    for i, pos in ipairs(path) do list[i] = copy(pos) end
  elseif row.blocked and (field == "blocked" or field == "reserved") then
    local src = row[field]
    local keys = sortedIds(src)
    for _, key in ipairs(keys) do list[#list + 1] = { key = key, value = copy(src[key]) } end
  elseif field == "contents" and row.contents ~= nil then
    if row.contents == false then return { ok = true, revision = revision, records = {}, cursor = 0, unknown = true } end
    local slots = {}
    for slot in pairs(row.contents) do slots[#slots + 1] = slot end
    table.sort(slots)
    for _, slot in ipairs(slots) do list[#list + 1] = { slot = slot, stack = copy(row.contents[slot]) } end
  else
    return fail("invalid", "unknown layout field")
  end
  local paged, err = pageOf(list, message.cursor or 0)
  if not paged then return err end
  paged.revision = revision
  return paged
end

local function commit(layout, nextLayout)
  if M.encoded(nextLayout) > BUDGET then return nil, fail("capacity", "layout budget exceeded") end
  nextLayout.revision = layout.revision + 1
  return nextLayout
end

local function publish(s, nextLayout)
  s.wh2.layout = nextLayout
end

local function sweep(layout, now)
  local u = normalizeUploads(layout)
  for _, stage in pairs(u.stages) do
    if not stage.final and not stage.expired and int(stage.updatedAt, 0, 9007199254740991) and now - stage.updatedAt >= UPLOAD_IDLE_MS then
      stage.expired = true
      stage.records = {}
      local mark = tostring(stage.operator)
      if int(stage.counter, 1, 2147483647) and (u.watermarks[mark] or 0) < stage.counter then
        u.watermarks[mark] = stage.counter
      end
    end
  end
  return u
end

local function parseUploadId(id, senderId)
  if type(id) ~= "string" then return nil end
  local computer, counter = id:match("^layout:(%d+):(%d+)$")
  computer, counter = tonumber(computer), tonumber(counter)
  if not int(computer, 0, 2147483647) or not int(counter, 1, 2147483647) then return nil end
  if computer ~= senderId or #id > 64 then return nil end
  return counter
end

local function stageKey(senderId, kind, id, field, pathId, uploadId)
  return tostring(senderId) .. "|" .. kind .. "|" .. id .. "|" .. field .. "|" .. (pathId or "") .. "|" .. uploadId
end

local function activeUploads(u, senderId)
  local n = 0
  for _, stage in pairs(u.stages) do
    if stage.operator == senderId and not stage.final and not stage.expired then n = n + 1 end
  end
  return n
end

local function assemble(kind, field, records, room)
  if field == "accessPaths" then
    local path = {}
    for i, pos in ipairs(records) do
      if not M.pose(pos) then return nil, fail("invalid", "path pose is invalid") end
      path[i] = copy(pos)
    end
    return path
  end
  if field == "blocked" or field == "reserved" then
    local map = {}
    for _, rec in ipairs(records) do
      if type(rec) ~= "table" or type(rec.key) ~= "string" or map[rec.key] ~= nil then
        return nil, fail("invalid", "duplicate or invalid upload record")
      end
      if field == "blocked" then
        if not itemId(rec.value) then return nil, fail("invalid", "blocked cell needs a block name") end
        map[rec.key] = rec.value
      else
        if type(rec.value) ~= "table" or not RESERVE[rec.value.kind] or not word(rec.value.locationId) then
          return nil, fail("invalid", "reservation is invalid")
        end
        map[rec.key] = { kind = rec.value.kind, locationId = rec.value.locationId }
      end
    end
    return map
  end
  if field == "contents" then
    local map, size = {}, room
    for _, rec in ipairs(records) do
      if type(rec) ~= "table" or not int(rec.slot, 1, size) or map[rec.slot] ~= nil or not validStack(rec.stack) then
        return nil, fail("invalid", "slot contents are invalid")
      end
      map[rec.slot] = copy(rec.stack)
    end
    if M.encoded(map) > RECORD_BUDGET then return nil, fail("too_large", "slot contents exceed 65536 bytes") end
    return map
  end
  return nil, fail("invalid", "unknown upload field")
end

local function applyField(layout, stage, s, context, limits)
  if stage.kind == "room" then
    local room = layout.rooms[stage.id]
    if not room then return nil, fail("invalid", "unknown room") end
    local body, err = assemble(stage.kind, stage.field, stage.records, room.size)
    if not body then return nil, err end
    local nextRoom = copy(room)
    if stage.field == "accessPaths" then
      local loc = layout.locations[stage.pathId]
      if not loc or not loc.access then return nil, fail("invalid", "path needs a location") end
      nextRoom.accessPaths[stage.pathId] = body
      if not pathOk(body, loc, nextRoom, s, context) then return nil, fail("blocked", "access path is not observed air") end
    else
      nextRoom[stage.field] = body
    end
    if not validRoom(nextRoom, limits) then return nil, fail("invalid", "room is invalid") end
    if not scanCompleteOk(nextRoom, s, context) then return nil, fail("blocked", "scan is incomplete") end
    layout.rooms[stage.id] = nextRoom
    return layout
  end
  local slot = layout.slots[stage.id]
  if not slot then return nil, fail("invalid", "unknown slot") end
  local body, err = assemble("slot", "contents", stage.records, slot.size)
  if not body then return nil, err end
  local nextSlot = copy(slot)
  nextSlot.contents = body
  if not validSlot(nextSlot) then return nil, fail("invalid", "slot is invalid") end
  layout.slots[stage.id] = nextSlot
  return layout
end

local function upload(s, layout, senderId, message, context, now)
  local kind, id, field = message.kind, message.id, message.field
  if kind ~= "room" and kind ~= "slot" then return fail("invalid", "upload kind is invalid") end
  if not word(id) or type(field) ~= "string" then return fail("invalid", "upload target is invalid") end
  if kind == "room" and not ROOM_FIELDS[field] then return fail("invalid", "unknown room field") end
  if kind == "slot" and field ~= "contents" then return fail("invalid", "unknown slot field") end
  local pathId = message.pathId
  if field == "accessPaths" then
    if not word(pathId) then return fail("invalid", "path id required") end
  elseif pathId ~= nil then return fail("invalid", "path id is only for access paths") end
  local counter = parseUploadId(message.uploadId, senderId)
  if not counter then return fail("invalid", "upload id is invalid") end
  if not int(message.baseRevision, 0, 2147483647) or not int(message.offset, 0, 2147483647) then
    return fail("invalid", "upload offset is invalid")
  end
  if type(message.records) ~= "table" then return fail("invalid", "upload records are invalid") end
  local u = sweep(layout, now)
  local mark = tostring(senderId)
  local key = stageKey(senderId, kind, id, field, pathId, message.uploadId)
  local stage = u.stages[key]
  local replay = canonical({ offset = message.offset, records = message.records, final = message.final == true })
  if stage and stage.final then
    if replay == stage.last then
      local receipt = u.receipts[message.uploadId]
      return { ok = true, revision = receipt.revision, nextOffset = stage.nextOffset, uploadId = message.uploadId, final = true }
    end
    return fail("invalid", "changed upload fragment")
  end
  if stage and stage.expired then return fail("upload_expired", "upload expired") end
  if not stage and (u.receipts[message.uploadId] or (u.watermarks[mark] or 0) >= counter) then
    return fail("upload_expired", "upload id is spent")
  end
  if message.baseRevision ~= layout.revision then return fail("stale_revision", "layout revision changed") end
  if not stage then
    if message.offset ~= 0 then return fail("invalid", "upload gap") end
    if activeUploads(u, senderId) >= 2 then return fail("capacity", "operator upload limit") end
    stage = {
      uploadId = message.uploadId, operator = senderId, kind = kind, id = id, field = field, pathId = pathId,
      counter = counter, baseRevision = message.baseRevision, nextOffset = 0, records = {}, updatedAt = now,
    }
    u.stages[key] = stage
  end
  if stage.operator ~= senderId or stage.baseRevision ~= message.baseRevision then
    return fail("stale_revision", "upload belongs to another revision")
  end
  local records = message.records
  if message.offset < stage.nextOffset then
    if message.offset + #records > stage.nextOffset then return fail("invalid", "changed upload fragment") end
    for i, rec in ipairs(records) do
      if canonical(rec) ~= canonical(stage.records[message.offset + i]) then
        return fail("invalid", "changed upload fragment")
      end
    end
    if not message.final then
      return { ok = true, revision = layout.revision, nextOffset = stage.nextOffset, uploadId = stage.uploadId }
    end
  elseif message.offset ~= stage.nextOffset then
    return fail("invalid", "upload gap")
  else
    local snapshot, previous = {}, stage.nextOffset
    for i, rec in ipairs(stage.records) do snapshot[i] = rec end
    for _, rec in ipairs(records) do
      local saved, err = copy(rec)
      if err then
        stage.records, stage.nextOffset = snapshot, previous
        if previous == 0 then u.stages[key] = nil end
        return fail("invalid", "upload record is invalid")
      end
      stage.records[#stage.records + 1] = saved
    end
    stage.nextOffset = previous + #records
    stage.updatedAt = now
    local size = M.encoded(stage.records)
    if size > RECORD_BUDGET or M.encoded(layout) > BUDGET then
      stage.records, stage.nextOffset = snapshot, previous
      if previous == 0 then u.stages[key] = nil end
      if size > RECORD_BUDGET then return fail("too_large", "upload exceeds 65536 bytes") end
      return fail("capacity", "layout budget exceeded")
    end
  end
  stage.last = replay
  if not message.final then
    return { ok = true, revision = layout.revision, nextOffset = stage.nextOffset, uploadId = stage.uploadId }
  end
  local nextLayout = copy(layout)
  if not nextLayout then return fail("invalid", "layout cannot be copied") end
  local applied, err = applyField(nextLayout, stage, s, context, limitsOf(context))
  if not applied then return err end
  local okLinks, why = roomLinksOk(nextLayout, s, context)
  if not okLinks then return fail("blocked", why) end
  local published, cap = commit(layout, nextLayout)
  if not published then return cap end
  published.uploads.receipts[message.uploadId] = {
    uploadId = message.uploadId, revision = published.revision, nextOffset = stage.nextOffset, final = true, at = now,
  }
  published.uploads.watermarks[mark] = math.max(published.uploads.watermarks[mark] or 0, counter)
  if M.encoded(published) > BUDGET then return fail("capacity", "layout budget exceeded") end
  stage.final = true
  stage.records = {}
  stage.updatedAt = now
  published.uploads.stages[key] = stage
  publish(s, published)
  return { ok = true, revision = published.revision, nextOffset = stage.nextOffset, uploadId = message.uploadId, final = true }
end

local function status(layout, senderId, message, now)
  local counter = parseUploadId(message.uploadId, senderId)
  if not counter then return fail("invalid", "upload id is invalid") end
  local u = sweep(layout, now)
  local receipt = u.receipts[message.uploadId]
  if receipt then
    return { ok = true, revision = receipt.revision, nextOffset = receipt.nextOffset, uploadId = message.uploadId, final = true }
  end
  for _, stage in pairs(u.stages) do
    if stage.uploadId == message.uploadId and stage.operator == senderId then
      if stage.expired then return fail("upload_expired", "upload expired") end
      return { ok = true, revision = stage.baseRevision, nextOffset = stage.nextOffset, uploadId = stage.uploadId, final = false }
    end
  end
  if (u.watermarks[tostring(senderId)] or 0) >= counter then return fail("upload_expired", "upload id is spent") end
  return fail("invalid", "unknown upload")
end

local function putLocation(s, layout, senderId, message, context)
  local value = message.value
  if message.kind == "fixture" then
    if type(value) ~= "table" or value.state == "retired" then
      local id = type(value) == "table" and (word(value.layoutId) and value.layoutId or value.id) or message.id
      local existing = layout.locations[id]
      if existing and busy(s, existing, context) then return fail("blocked", "location is in use") end
      if not existing then return fail("invalid", "unknown fixture location") end
      local nextLayout = copy(layout)
      nextLayout.locations[id] = nil
      local published, err = commit(layout, nextLayout)
      if not published then return err end
      publish(s, published)
      return { ok = true, revision = published.revision, removed = id }
    end
    local loc = M.fixtureToLocation(value)
    if not loc or loc.id ~= message.id then return fail("invalid", "fixture is not a verified location") end
    value = loc
  end
  if not validLocation(value) or value.id ~= message.id then return fail("invalid", "location is invalid") end
  if value.roomId ~= false and not layout.rooms[value.roomId] and value.kind == "room" then
    return fail("invalid", "unknown room")
  end
  local existing = layout.locations[value.id]
  if existing and busy(s, existing, context) and canonical(existing) ~= canonical(value) then
    return fail("blocked", "location is in use")
  end
  local nextLayout = copy(layout)
  value = copy(value)
  value.revision = layout.revision + 1
  nextLayout.locations[value.id] = value
  if not sharedLock(nextLayout, value) then return fail("invalid", "one block needs one lock") end
  if value.roomId ~= false and value.kind ~= "room" and not nextLayout.rooms[value.roomId] then
    return fail("invalid", "unknown room")
  end
  local okLinks, why = roomLinksOk(nextLayout, s, context)
  if not okLinks then return fail("blocked", why) end
  if canonical(layout.locations[value.id] or {}) == canonical(value) then
    return { ok = true, revision = layout.revision, record = copy(layout.locations[value.id]) }
  end
  -- revision was stamped as layout.revision+1 before commit bumps the tree
  local published, err = commit(layout, nextLayout)
  if not published then return err end
  published.locations[value.id].revision = published.revision
  publish(s, published)
  return { ok = true, revision = published.revision, record = copy(published.locations[value.id]) }
end

local function putRoom(s, layout, message, context)
  local value = copy(message.value)
  if not value or value.id ~= message.id then return fail("invalid", "room is invalid") end
  value.revision = layout.revision + 1
  if not validRoom(value, limitsOf(context)) then return fail("invalid", "room is invalid") end
  if not scanCompleteOk(value, s, context) then return fail("blocked", "scan is incomplete") end
  local nextLayout = copy(layout)
  nextLayout.rooms[value.id] = value
  local okLinks, why = roomLinksOk(nextLayout, s, context)
  if not okLinks then return fail("blocked", why) end
  local published, err = commit(layout, nextLayout)
  if not published then return err end
  published.rooms[value.id].revision = published.revision
  publish(s, published)
  return { ok = true, revision = published.revision, record = copy(published.rooms[value.id]) }
end

local function putSlot(s, layout, message, context)
  local value = copy(message.value)
  if not value or value.id ~= message.id or not validSlot(value) then return fail("invalid", "slot is invalid") end
  if value.roomId ~= false and not layout.rooms[value.roomId] then return fail("invalid", "unknown room") end
  if not layout.locations[value.locationId] then return fail("invalid", "unknown location") end
  local loc = layout.locations[value.locationId]
  if loc.kind == "furnace" or loc.kind == "blast" or loc.kind == "smoker" then
    if value.kind ~= loc.kind then return fail("invalid", "machine slot kind must match its location") end
  elseif loc.kind == "storage" or loc.kind == "dropoff" or loc.kind == "warehouse_input" or loc.kind == "warehouse_output" then
    if value.kind ~= "chest" then return fail("invalid", "storage slot must be a chest") end
  end
  value.revision = layout.revision + 1
  local nextLayout = copy(layout)
  nextLayout.slots[value.id] = value
  local published, err = commit(layout, nextLayout)
  if not published then return err end
  published.slots[value.id].revision = published.revision
  publish(s, published)
  return { ok = true, revision = published.revision, record = copy(published.slots[value.id]) }
end

local function putClass(s, layout, senderId, message)
  local value = copy(message.value)
  if not value or value.item ~= message.id then return fail("invalid", "class default is invalid") end
  value.source = "layout"
  value.updatedBy = senderId
  value.revision = layout.revision + 1
  value.v = 1
  if not validClass(value, "layout") then return fail("invalid", "class default is invalid") end
  local nextLayout = copy(layout)
  nextLayout.classDefaults[value.item] = value
  local published, err = commit(layout, nextLayout)
  if not published then return err end
  published.classDefaults[value.item].revision = published.revision
  publish(s, published)
  return { ok = true, revision = published.revision, record = copy(published.classDefaults[value.item]) }
end

local function removeRecord(s, layout, message, context)
  local map = message.kind == "location" and layout.locations or message.kind == "room" and layout.rooms
    or message.kind == "slot" and layout.slots or message.kind == "classDefault" and layout.classDefaults
  if not map or not map[message.id] then return fail("invalid", "unknown layout record") end
  if message.kind == "location" and busy(s, map[message.id], context) then return fail("blocked", "location is in use") end
  if message.kind == "slot" then
    local loc = layout.locations[map[message.id].locationId]
    if loc and busy(s, loc, context) then return fail("blocked", "location is in use") end
  end
  if message.kind == "room" then
    for _, loc in pairs(layout.locations) do
      if loc.roomId == message.id then return fail("blocked", "room has locations") end
    end
    for _, slot in pairs(layout.slots) do
      if slot.roomId == message.id then return fail("blocked", "room has slots") end
    end
  end
  local nextLayout = copy(layout)
  local target = message.kind == "location" and nextLayout.locations or message.kind == "room" and nextLayout.rooms
    or message.kind == "slot" and nextLayout.slots or nextLayout.classDefaults
  target[message.id] = nil
  local published, err = commit(layout, nextLayout)
  if not published then return err end
  publish(s, published)
  return { ok = true, revision = published.revision, removed = message.id }
end

function M.run(s, senderId, message, context)
  if type(s) ~= "table" or type(message) ~= "table" then return fail("invalid", "invalid layout request") end
  context = type(context) == "table" and context or {}
  if not (type(context.config) == "table" and context.config.enabled == true) then
    return fail("disabled", "layout is off")
  end
  if not int(senderId, 0, 2147483647) or not int(context.now or 0, 0, 9007199254740991) then
    return fail("invalid", "invalid sender")
  end
  if not int(context.epoch or 0, 0, 2147483647) then return fail("invalid", "invalid epoch") end
  local op = message.op
  if op ~= "wh2-layout" and op ~= "wh2-get" then return fail("unavailable", "not a layout operation") end
  s.wh2 = type(s.wh2) == "table" and s.wh2 or {}
  if s.wh2.layout ~= nil and not M.valid(s.wh2.layout, context.pose or M.pose) then
    return fail("invalid", "stored layout is invalid")
  end
  if s.wh2.layout == nil then s.wh2.layout = M.empty() end
  local layout = s.wh2.layout
  layout.enabled = true
  normalizeUploads(layout)
  if op == "wh2-get" then return readLayout(s, layout, message, context) end
  if message.action == "status" then return status(layout, senderId, message, context.now) end
  if not operator(context, senderId) then return fail("forbidden", "layout edit requires an operator") end
  if message.field ~= nil or message.uploadId ~= nil then
    return upload(s, layout, senderId, message, context, context.now)
  end
  if not word(message.id) or (message.kind ~= "location" and message.kind ~= "room" and message.kind ~= "slot"
    and message.kind ~= "classDefault" and message.kind ~= "fixture") then
    return fail("invalid", "layout record is invalid")
  end
  if not int(message.baseRevision, 0, 2147483647) then return fail("invalid", "base revision is invalid") end
  if message.baseRevision ~= layout.revision then return fail("stale_revision", "layout revision changed") end
  if message.remove == true then
    if message.value ~= nil then return fail("invalid", "remove carries no value") end
    return removeRecord(s, layout, message, context)
  end
  if type(message.value) ~= "table" then return fail("invalid", "layout value is missing") end
  if message.kind == "location" or message.kind == "fixture" then return putLocation(s, layout, senderId, message, context) end
  if message.kind == "room" then return putRoom(s, layout, message, context) end
  if message.kind == "slot" then return putSlot(s, layout, message, context) end
  return putClass(s, layout, senderId, message)
end

return M
