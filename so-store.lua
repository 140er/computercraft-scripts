-- so-store.lua - atomic save and load, ported from atomic.lua.
-- A write over the byte budget fails before it touches the current file.
-- Failed disk writes recover their surviving generations on the next save.

local M = {}

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

function M.read(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local ok, bytes = pcall(h.readAll)
  h.close()
  if not ok then return nil end
  local parsed, value = pcall(textutils.unserialize, bytes)
  if parsed then return value, bytes end
end

function M.store(path, valid, limit)
  assert(type(valid) == "function", "valid")
  local budget = limit or 900000
  local generation, current, source
  local box = {}
  local function recover(allowEmpty)
    local newest, value, picked, exists = 0, nil, nil, false
    for _, file in ipairs({ path, path .. ".tmp", path .. ".bak" }) do
      exists = exists or fs.exists(file)
      local t, bytes = M.read(file)
      if type(t) == "table" and t.schema == 1 and type(t.generation) == "number"
        and t.generation % 1 == 0 and t.generation > newest and valid(t.value) then
        newest, value, picked = t.generation, t.value, file
        box.bytes = #bytes
      end
    end
    assert(value or not exists or allowEmpty, "no valid generation: " .. path)
    generation, current, source = newest, value, picked
  end
  recover()
  local needsRecovery = false
  box.value = current
  box.save = function(value)
    if needsRecovery then
      local recovered, recoveryErr = pcall(recover, generation == 0 and current == nil)
      if not recovered then return false, recoveryErr end
    end
    local text
    local prepared, prepErr = pcall(function()
      assert(valid(value), "invalid state")
      text = textutils.serialize({ schema = 1, generation = generation + 1,
        value = M.copy(value) }, { compact = true })
    end)
    if not prepared then return false, prepErr end
    if #text > budget then return false, "budget exceeded" end
    local checked, spaceErr = pcall(function()
      local free = fs.getFreeSpace(path)
      assert(type(free) ~= "number" or free >= #text + 8192, "disk full")
    end)
    if not checked then return false, spaceErr end
    local h
    local ok, err = pcall(function()
      if source and source ~= path then
        if fs.exists(path) then fs.delete(path) end
        fs.move(source, path)
        source = path
      end
      if fs.exists(path .. ".tmp") then fs.delete(path .. ".tmp") end
      h = assert(fs.open(path .. ".tmp", "w"), "open failed")
      h.write(text)
      h.close()
      h = nil
      local parsed, bytes = M.read(path .. ".tmp")
      assert(bytes == text and parsed and valid(parsed.value), "verification failed")
      if fs.exists(path .. ".bak") then fs.delete(path .. ".bak") end
      if fs.exists(path) then fs.move(path, path .. ".bak") end
      fs.move(path .. ".tmp", path)
      generation, source = generation + 1, path
      box.bytes = #text
    end)
    if h then pcall(h.close) end
    needsRecovery = not ok
    return ok, err
  end
  return box
end

function M.clock()
  local box = M.store("so-data/clock", function(v)
    return type(v) == "table" and type(v.ceiling) == "number"
      and v.format == "ticks-v1" and v.ceiling % 1 == 0 and v.ceiling >= 0 and v.ceiling < math.huge
  end, 1024)
  local origin = box.value and box.value.ceiling or os.epoch("utc")
  local started, ceiling, last = os.clock(), origin, origin
  local status = { refused = false }
  local function now()
    local clock = os.clock()
    local at = status.refused and last or origin + math.floor((clock - started) * 1000 + 0.5)
    if at >= ceiling or status.refused then
      local reserved = at + 1000
      local ok, err = box.save({ format = "ticks-v1", ceiling = reserved })
      if not ok then
        status.refused, status.error = true, tostring(err)
        return last
      end
      -- Resume at the frozen time without charging the storage outage.
      if status.refused then origin, started = last, clock end
      status.refused, status.error = false, nil
      ceiling = reserved
    end
    last = at
    return at
  end
  return now, status
end

return M
