-- Bounded error generations, including temporary and backup files.
local M = {}
M.open = function(store, now)
  local path, budget = "so-data/errors", 21000
  local function valid(v)
    if type(v) ~= "table" or type(v.entries) ~= "table" then return false end
    if #v.entries > 128 then return false end
    for _, e in ipairs(v.entries) do
      if type(e) ~= "table" or type(e.at) ~= "number" or type(e.text) ~= "string" or #e.text > 2048 then return false end
    end
    return true
  end
  local box = store.store(path, valid, budget)
  local entries = box.value and box.value.entries or {}
  local dirty, last, failure = false, -math.huge, nil
  local function flush(at)
    at = at or now()
    if not dirty or at-last < 30000 then return failure == nil, failure end
    last = at
    local ok, err = box.save({entries=entries})
    failure = not ok and tostring(err) or nil
    if ok then dirty = false end
    return ok, err
  end
  local function record(text)
    entries[#entries+1] = {at=now(),text=tostring(text):sub(1,2048)}
    -- Reserve envelope space even at large generation numbers.
    while #entries > 128 or #textutils.serialize({entries=entries},{compact=true}) > budget-256 do
      table.remove(entries,1)
    end
    dirty = true
    return flush()
  end
  return {
    record=record, flush=flush,
    entries=function() return store.copy(entries) end,
    status=function()
      local bytes = 0
      for _, suffix in ipairs({"", ".tmp", ".bak"}) do
        if fs.exists(path..suffix) then bytes = bytes + fs.getSize(path..suffix) end
      end
      return {bytes=bytes,cap=65536,pending=dirty,error=failure,count=#entries}
    end,
  }
end
return M
