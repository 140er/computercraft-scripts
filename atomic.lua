local M = {}
M.writeMargin = 8192
M.controlCeiling = 32768

-- dofile runs this file again. One disk has one reserve, so both copies share the box.
local BOX = rawget(_ENV, "atomicBox")
if type(BOX) ~= "table" then
  BOX = { mounts = {} }
  rawset(_ENV, "atomicBox", BOX)
end

function M.hash(text)
  local h = 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

function M.copy(value)
  local parents = {}
  local function tree(v)
    if type(v) ~= "table" then return v end
    assert(not parents[v], "cyclic state")
    parents[v] = true
    local out = {}
    for k, x in pairs(v) do out[tree(k)] = tree(x) end
    parents[v] = nil
    return out
  end
  return tree(value)
end

function M.report()
  return BOX.report
end

local function note(path, class, err)
  BOX.report = { path = path, class = class, error = err, at = os.epoch("utc") }
end

local function clearReport()
  BOX.report = nil
end

local function rawText(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  if type(h.read) ~= "function" then
    local ok, bytes = pcall(h.readAll)
    h.close()
    if ok and type(bytes) == "string" then return bytes end
    return nil
  end
  local parts, failed = {}, false
  while true do
    local ok, chunk = pcall(h.read, 4096)
    if not ok then failed = true break end
    if type(chunk) ~= "string" or #chunk == 0 then break end
    parts[#parts + 1] = chunk
  end
  h.close()
  if failed then return nil end
  return table.concat(parts)
end

local function parsed(path)
  local bytes = rawText(path)
  if not bytes then return nil end
  local ok, value = pcall(textutils.unserialize, bytes)
  if ok then return value, bytes end
end

function M.read(path)
  local best, bestBytes
  for _, slot in ipairs({ "a", "b" }) do
    local value, bytes = parsed(path .. "." .. slot)
    if type(value) == "table" and value.v == 1 and type(value.generation) == "number"
      and (not best or value.generation > best.generation) then
      best, bestBytes = value, bytes
    end
  end
  if best then return best, bestBytes end
  return parsed(path)
end

local function fileSize(path)
  local bytes = rawText(path)
  return bytes and #bytes or 0
end

local function envelopeOk(value, generation, valid)
  return type(value) == "table" and value.v == 1 and value.generation == generation
    and type(valid) == "function" and valid(value.value) and true or false
end

local mount = {}
local record = {}

function M.mount(root)
  root = root or "/"
  local found = BOX.mounts[root]
  if found then return found end
  local self = { root = root, records = {}, controlLimit = 0 }
  BOX.mounts[root] = self
  return setmetatable(self, { __index = mount })
end

function mount:measure()
  local cap = fs.getCapacity(self.root)
  local free = fs.getFreeSpace(self.root)
  local kind = "limited"
  if cap == "unlimited" or free == "unlimited" then kind = "unlimited"
  elseif type(cap) ~= "number" or type(free) ~= "number" then kind = "unknown" end
  local used
  if type(cap) == "number" and type(free) == "number" then used = cap - free end
  return { kind = kind, capacity = cap, free = free, used = used }
end

function mount:reserve()
  if self.controlLimit == 0 then return 0 end
  return self.controlLimit + M.writeMargin
end

local function anchorOf(path, spec)
  if spec.anchor then return spec.anchor, true end
  if path:sub(-4) == ".map" then return path:sub(1, -5) .. ".control", true end
  if path:sub(-5) == ".bulk" then return path:sub(1, -6) .. ".control", true end
  return nil, false
end

local function mapGenOf(self, anchor)
  local rec = self.records[anchor]
  if rec and type(rec.value) == "table" and type(rec.value.mapGen) == "number" then
    return rec.value.mapGen
  end
  local best
  for _, slot in ipairs({ "a", "b" }) do
    local value = parsed(anchor .. "." .. slot)
    if type(value) == "table" and value.v == 1 and type(value.generation) == "number"
      and (not best or value.generation > best.generation) then best = value end
  end
  if best and type(best.value) == "table" and type(best.value.mapGen) == "number" then
    return best.value.mapGen
  end
  return 0
end

local function slotValue(path, slot, valid)
  local value, bytes = parsed(path .. "." .. slot)
  if type(value) ~= "table" or value.v ~= 1 or type(value.generation) ~= "number"
    or value.generation < 1 or value.generation % 1 ~= 0 then return nil end
  if not valid(value.value) then return nil end
  return value, bytes
end

local function legacyValue(path, valid)
  for _, file in ipairs({ path, path .. ".tmp", path .. ".bak" }) do
    if fs.exists(file) then
      local value = parsed(file)
      if type(value) == "table" then
        if value.schema == 1 and type(value.value) == "table" and valid(value.value) then
          return value.value, true
        elseif value.v ~= 1 and value.schema ~= 1 and valid(value) then
          return value, true
        end
      end
      return nil, true
    end
  end
  return nil, false
end

function mount:open(path, valid, spec)
  spec = spec or {}
  assert(spec.class == "control" or spec.class == "bulk", "class")
  assert(type(spec.limit) == "number" and spec.limit > 0, "limit")
  if spec.class == "control" and spec.limit > M.controlCeiling then
    error("control limit", 0)
  end
  if self.records[path] then return self.records[path] end
  local anchored, isMap = false, false
  local anchor
  anchor, isMap = anchorOf(path, spec)
  anchored = isMap
  local published = anchored and mapGenOf(self, anchor) or nil
  local winner, generation, value
  local sawSlot = false
  for _, slot in ipairs({ "a", "b" }) do
    local env = slotValue(path, slot, valid)
    if env then
      sawSlot = true
      local take = false
      if anchored then take = env.generation == published
      elseif not generation or env.generation > generation then take = true end
      if take then winner, generation, value = slot, env.generation, env.value end
    elseif fs.exists(path .. "." .. slot) then
      sawSlot = true
    end
  end
  local legacy, legacyExists = nil, false
  if not winner then
    legacy, legacyExists = legacyValue(path, valid)
    if legacyExists and not legacy and not sawSlot then
      error("no valid generation: " .. path, 0)
    end
  end
  local rec = setmetatable({
    path = path, valid = valid, spec = spec, mount = self,
    value = value or legacy, generation = generation or 0, winner = winner,
    anchored = anchored, anchor = anchor,
  }, { __index = record })
  self.records[path] = rec
  if spec.class == "control" and spec.limit > self.controlLimit then
    self.controlLimit = spec.limit
  end
  if legacy and not winner then
    local ok = rec:save(legacy)
    if ok then
      for _, file in ipairs({ path, path .. ".tmp", path .. ".bak" }) do
        if fs.exists(file) then fs.delete(file) end
      end
    end
  end
  return rec
end

local function admit(self, class, limit, text, olderSize)
  if #text > limit then return false, "capacity" end
  local occupied = #text
  if olderSize == 0 and #text < 500 then occupied = 500 end
  local measured = self.mount:measure()
  local free = measured.free
  if measured.kind == "unlimited" or free == "unlimited" then return true end
  if type(free) ~= "number" then return false, "capacity" end
  local reusable = free + olderSize
  if class == "control" then
    if reusable >= occupied + M.writeMargin then return true end
    return false, "capacity"
  end
  if reusable - occupied >= self.mount:reserve() then return true end
  return false, "capacity"
end

function record:save(value)
  if type(self.valid) ~= "function" or not self.valid(value) then
    note(self.path, self.spec.class, "invalid")
    return false, "invalid"
  end
  local published
  if self.anchored then published = mapGenOf(self.mount, self.anchor) end
  local winner, maxGen = nil, 0
  for _, slot in ipairs({ "a", "b" }) do
    local env = slotValue(self.path, slot, self.valid)
    if env then
      if env.generation > maxGen then maxGen = env.generation end
      if self.anchored then
        if env.generation == published then winner = slot end
      elseif not winner or env.generation > slotValue(self.path, winner, self.valid).generation then
        winner = slot
      end
    end
  end
  local scratch = (winner == "a") and "b" or "a"
  if self.anchored and not winner then scratch = "a" end
  local generation = maxGen + 1
  if generation < 1 then generation = 1 end
  local text = textutils.serialize({ v = 1, generation = generation, value = M.copy(value) }, { compact = true })
  local scratchPath = self.path .. "." .. scratch
  local olderSize = fileSize(scratchPath)
  local okAdmit, why = admit(self, self.spec.class, self.spec.limit, text, olderSize)
  if not okAdmit then
    note(self.path, self.spec.class, why)
    return false, why
  end
  local h = fs.open(scratchPath, "w")
  if not h then
    if fs.exists(scratchPath) then fs.delete(scratchPath) end
    note(self.path, self.spec.class, "save")
    return false, "save"
  end
  local written, err = pcall(function()
    h.write(text)
    h.close()
  end)
  if not written then
    pcall(function() h.close() end)
    if fs.exists(scratchPath) then fs.delete(scratchPath) end
    note(self.path, self.spec.class, "save")
    return false, "save"
  end
  local back, bytes = parsed(scratchPath)
  if bytes ~= text or not envelopeOk(back, generation, self.valid) then
    if fs.exists(scratchPath) then fs.delete(scratchPath) end
    note(self.path, self.spec.class, "save")
    return false, "save"
  end
  self.value = M.copy(value)
  self.generation = generation
  self.winner = scratch
  clearReport()
  return true
end

function M.store(path, valid, limit)
  local disk = M.mount("/")
  disk.records[path] = nil
  local rec = disk:open(path, valid, { class = "bulk", limit = limit or 900000 })
  local api = { value = rec.value }
  function api.save(value)
    local ok, err = rec:save(value)
    if ok then api.value = rec.value end
    return ok, err
  end
  return api
end

function M.replaceBytes(path, text, valid)
  if type(text) ~= "string" or type(valid) ~= "function" or not valid(text) then
    note(path, "bulk", "invalid")
    return false, "invalid"
  end
  local tmp = path .. ".tmp"
  local live = rawText(path)
  local staged = rawText(tmp)
  if staged and valid(staged) and (not live or not valid(live)) then
    if live then fs.delete(path) end
    local moved, moveErr = pcall(fs.move, tmp, path)
    if not moved then
      note(path, "bulk", "save")
      return false, "save"
    end
    live = staged
  elseif staged and not valid(staged) then
    fs.delete(tmp)
  end
  local disk = M.mount("/")
  local older = fileSize(tmp)
  local occupied = #text
  if older == 0 and occupied < 500 then occupied = 500 end
  local measured = disk:measure()
  local free = measured.free
  if not (measured.kind == "unlimited" or free == "unlimited") then
    if type(free) ~= "number" or (free + older) - occupied < disk:reserve() then
      note(path, "bulk", "capacity")
      return false, "capacity"
    end
  end
  local opened, h = pcall(fs.open, tmp, "w")
  if not opened or not h then
    note(path, "bulk", "save")
    return false, "save"
  end
  local written = pcall(function()
    h.write(text)
    h.close()
  end)
  if not written or rawText(tmp) ~= text or not valid(rawText(tmp)) then
    pcall(function() h.close() end)
    if fs.exists(tmp) then fs.delete(tmp) end
    note(path, "bulk", "save")
    return false, "save"
  end
  local function finishMove()
    local moved, moveErr = pcall(fs.move, tmp, path)
    if moved then return true end
    if fs.exists(path) and fs.exists(tmp) and tostring(moveErr):find("Destination exists", 1, true) then
      fs.delete(path)
      moved = pcall(fs.move, tmp, path)
      if moved then return true end
    end
    return false
  end
  if not finishMove() then
    if fs.exists(path) and fs.exists(tmp) then fs.delete(tmp) end
    note(path, "bulk", "save")
    return false, "save"
  end
  clearReport()
  return true
end

return M
