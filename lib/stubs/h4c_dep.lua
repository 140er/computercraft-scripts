-- H4a replaces usage and kind. H4b1 replaces the section store. H5 replaces pinnedKeys.

local M = { h4a = {}, h4b1 = {}, h5 = {} }

local MAP = { scan = true, ["section-put"] = true, observe = true }

function M.h4a.usage(fs)
  local total, free = fs.getCapacity("/"), fs.getFreeSpace("/")
  if total == "unlimited" or free == "unlimited" then
    return { total = 0, used = 0, free = 0, peerTotal = 0, peerUsed = 0, unlimited = true }
  end
  if type(total) ~= "number" or type(free) ~= "number" or total ~= total or free ~= free then
    return nil, "bad capacity"
  end
  return {
    total = total, used = total - free, free = free,
    peerTotal = 0, peerUsed = 0, unlimited = false,
  }
end

function M.h4a.kind(op)
  if type(op) ~= "string" or #op == 0 or #op > 32 then return nil end
  if MAP[op] then return "map" end
  return "control"
end

function M.h4b1.new()
  return { items = {} }
end

function M.h4b1.put(store, section)
  store.items[section.key] = {
    v = section.v, key = section.key, rev = section.rev, hash = section.hash,
    bytes = section.bytes, observedAt = section.observedAt,
  }
  return true
end

function M.h4b1.list(store)
  local out = {}
  for _, section in pairs(store.items) do out[#out + 1] = section end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

function M.h4b1.read(store, key)
  local section = store.items[key]
  if not section then return { confidence = "unknown" } end
  return {
    confidence = "observed", key = section.key, rev = section.rev, hash = section.hash,
    bytes = section.bytes, observedAt = section.observedAt,
  }
end

function M.h4b1.forget(store, key, rev, hash)
  local section = store.items[key]
  if not section or section.rev ~= rev or section.hash ~= hash then return "skipped" end
  store.items[key] = nil
  return "deleted"
end

function M.h5.pinnedKeys(records, now)
  local out = {}
  for i = 1, #(records or {}) do
    local row = records[i]
    if type(row) == "table" and type(row.key) == "string" then
      if row.untilAt == false or (type(row.untilAt) == "number" and row.untilAt > now) then
        out[row.key] = true
      end
    end
  end
  return out
end

return M
