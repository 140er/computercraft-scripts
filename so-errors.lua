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
  local revision = 0
  local function flush(at, force)
    at = at or now()
    if not dirty or not force and at-last < 30000 then return failure == nil, failure end
    last = at
    local ok, err = box.save({entries=entries})
    failure = not ok and tostring(err) or nil
    if ok then dirty = false end
    return ok, err
  end
  local function record(text, force)
    entries[#entries+1] = {at=now(),text=tostring(text):sub(1,2048)}
    -- Reserve envelope space even at large generation numbers.
    while #entries > 128 or #textutils.serialize({entries=entries},{compact=true}) > budget-256 do
      table.remove(entries,1)
    end
    dirty = true
    revision = revision+1
    return flush(nil, force)
  end
  return {
    record=record, flush=flush,
    clear=function(expectedRevision)
      if expectedRevision == nil or expectedRevision ~= revision then return false, "errors changed; confirm again" end
      local ok, err = box.save({entries={}})
      if not ok then return false, err end
      entries, dirty, failure = {}, false, nil
      revision = revision+1
      return true
    end,
    entries=function() return store.copy(entries) end,
    summary=function()
      local groups, out = {}, {}
      for _, entry in ipairs(entries) do
        local group = groups[entry.text]
        if not group then
          group = {text=entry.text,count=0,first=entry.at,last=entry.at}
          groups[entry.text] = group
          out[#out+1] = group
        end
        group.count = group.count + 1
        group.last = entry.at
      end
      return out
    end,
    status=function()
      local bytes = 0
      for _, suffix in ipairs({"", ".tmp", ".bak"}) do
        if fs.exists(path..suffix) then bytes = bytes + fs.getSize(path..suffix) end
      end
      return {bytes=bytes,cap=65536,pending=dirty,error=failure,count=#entries,revision=revision}
    end,
  }
end
return M
