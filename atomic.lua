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
  local generation, current, source, exists = 0, nil, nil, false
  for _, file in ipairs({ path, path .. ".tmp", path .. ".bak" }) do
    exists = exists or fs.exists(file)
    local t = M.read(file)
    if type(t) == "table" and t.schema == 1 and type(t.generation) == "number"
      and t.generation % 1 == 0 and t.generation > generation and valid(t.value) then
      generation, current, source = t.generation, t.value, file
    end
  end
  assert(current or not exists, "no valid generation: " .. path)
  local poisoned = false
  return {
    value = current,
    save = function(value)
      if poisoned then return false, "storage requires restart" end
      local h
      local ok, err = pcall(function()
        assert(valid(value), "invalid state")
        local text = textutils.serialize({ schema = 1, generation = generation + 1,
          value = M.copy(value) }, { compact = true })
        assert(#text <= (limit or 900000), "state budget exceeded")
        if source and source ~= path then
          if fs.exists(path) then fs.delete(path) end
          fs.move(source, path)
          source = path
        end
        if fs.exists(path .. ".tmp") then fs.delete(path .. ".tmp") end
        local free = fs.getFreeSpace(path)
        assert(type(free) ~= "number" or free >= #text + 8192, "disk full")
        h = assert(fs.open(path .. ".tmp", "w"), "open failed")
        h.write(text) h.close() h = nil
        local parsed, bytes = M.read(path .. ".tmp")
        assert(bytes == text and parsed and valid(parsed.value), "verification failed")
        if fs.exists(path .. ".bak") then fs.delete(path .. ".bak") end
        if fs.exists(path) then fs.move(path, path .. ".bak") end
        fs.move(path .. ".tmp", path)
        generation, source = generation + 1, path
      end)
      if h then pcall(h.close) end
      if not ok then poisoned = true end
      return ok, err
    end,
  }
end
return M
