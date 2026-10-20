local M = {}

local MAX = 9007199254740991
local PREVIEW_MS = 600000

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function hex64(s)
  return type(s) == "string" and #s == 64 and s:match("^%x+$") ~= nil
end

local function keyOk(s)
  return type(s) == "string" and #s > 0 and #s <= 120 and s:match("^[%w:|._-]+$") ~= nil
end

function M.defaults()
  return { v = 1, mode = "ask", warnAt = 0.8, forgetOlderThanMs = false, controlReserve = 65536 }
end

function M.parsePolicy(raw)
  if type(raw) ~= "table" or raw.v ~= 1 then return nil, "unknown policy v" end
  if raw.mode ~= "ask" then return nil, "invalid storage policy" end
  if type(raw.warnAt) ~= "number" or raw.warnAt ~= raw.warnAt or raw.warnAt <= 0 or raw.warnAt > 1 then
    return nil, "invalid storage policy"
  end
  if raw.forgetOlderThanMs ~= false and not integer(raw.forgetOlderThanMs, 1, MAX) then
    return nil, "invalid storage policy"
  end
  if not integer(raw.controlReserve, 0, 1000000) then return nil, "invalid storage policy" end
  return {
    v = 1, mode = "ask", warnAt = raw.warnAt,
    forgetOlderThanMs = raw.forgetOlderThanMs, controlReserve = raw.controlReserve,
  }
end

function M.parseSection(raw)
  if type(raw) ~= "table" or raw.v ~= 2 then return nil, "unknown section v" end
  if not keyOk(raw.key) or not integer(raw.rev, 0, MAX) or not hex64(raw.hash) then
    return nil, "invalid section"
  end
  if not integer(raw.bytes, 0, MAX) or not integer(raw.observedAt, 0, MAX) then
    return nil, "invalid section"
  end
  return {
    v = 2, key = raw.key, rev = raw.rev, hash = raw.hash,
    bytes = raw.bytes, observedAt = raw.observedAt,
  }
end

local function usageOk(usage)
  if type(usage) ~= "table" then return false end
  if usage.unlimited then return true end
  if not integer(usage.total, 0, MAX) or not integer(usage.used, 0, usage.total) then return false end
  if not integer(usage.free, 0, usage.total) or usage.used + usage.free ~= usage.total then return false end
  local peerTotal, peerUsed = usage.peerTotal or 0, usage.peerUsed or 0
  return integer(peerTotal, 0, MAX) and integer(peerUsed, 0, peerTotal)
end

local function choiceOf(decision)
  local choice = decision and decision.choice or false
  if choice ~= false and choice ~= "decline" and choice ~= "expand" then return nil end
  return choice
end

local function over(policy, usage)
  if usage.unlimited or usage.total <= 0 then return false end
  if usage.free < policy.controlReserve then return true end
  return usage.used >= usage.total * policy.warnAt
end

local function growth(samples)
  local rows = {}
  for i = 1, #(samples or {}) do
    local row = samples[i]
    if type(row) == "table" and integer(row.at, 0, MAX) and integer(row.used, 0, MAX) then
      rows[#rows + 1] = row
    end
  end
  if #rows < 2 then return 0 end
  table.sort(rows, function(a, b) return a.at < b.at end)
  local dt = rows[#rows].at - rows[1].at
  if dt <= 0 then return 0 end
  local per = (rows[#rows].used - rows[1].used) * 3600000 / dt
  if per < 0 then return 0 end
  return math.floor(per + 1e-9)
end

function M.ledger(policy, usage, decision, samples, now)
  if not usageOk(usage) or not integer(now, 0, MAX) then return nil, "invalid ledger input" end
  if choiceOf(decision) == nil then return nil, "invalid ledger input" end
  local state = "ok"
  if over(policy, usage) then
    local choice = choiceOf(decision)
    state = (choice == "decline" or choice == "expand") and "paused" or "warn"
  end
  return {
    v = 1,
    localTotal = usage.unlimited and 0 or usage.total,
    localUsed = usage.unlimited and 0 or usage.used,
    peerTotal = usage.peerTotal or 0,
    peerUsed = usage.peerUsed or 0,
    growthPerHour = growth(samples),
    state = state,
  }
end

function M.admit(enabled, ledger, kind)
  if not enabled then return { ok = true } end
  if kind == "control" then return { ok = true } end
  if kind ~= "map" then return { ok = false, error = "bad op" } end
  if ledger.state ~= "ok" then return { ok = false, error = "capacity" } end
  return { ok = true }
end

local function eligible(section, now, olderThanMs)
  return now >= section.observedAt and now - section.observedAt >= olderThanMs
end

function M.preview(sections, now, olderThanMs, rev, seq, pinned)
  if not integer(now, 0, MAX) or not integer(olderThanMs, 0, MAX) then return nil, "invalid preview" end
  if not integer(rev, 0, MAX) or not integer(seq, 1, MAX) then return nil, "invalid preview" end
  if type(sections) ~= "table" or type(pinned) ~= "table" then return nil, "invalid preview" end
  local items, bytes = {}, 0
  for i = 1, #sections do
    local section, err = M.parseSection(sections[i])
    if not section then return nil, err end
    if not pinned[section.key] and eligible(section, now, olderThanMs) then
      items[#items + 1] = { key = section.key, rev = section.rev, hash = section.hash, bytes = section.bytes }
      bytes = bytes + section.bytes
    end
  end
  table.sort(items, function(a, b) return a.key < b.key end)
  return {
    v = 1, id = string.format("p:%d:%d", rev, seq), createdAt = now, untilAt = now + PREVIEW_MS,
    olderThanMs = olderThanMs, rev = rev, items = items, bytes = bytes,
  }
end

local function previewItem(item)
  if type(item) ~= "table" or not keyOk(item.key) or not integer(item.rev, 0, MAX) or not hex64(item.hash) then
    return nil
  end
  if not integer(item.bytes, 0, MAX) then return nil end
  return true
end

function M.commit(preview, sections, pinned, now)
  if type(preview) ~= "table" or preview.v ~= 1 then return nil, "unknown preview v" end
  if type(preview.id) ~= "string" or not preview.id:match("^p:%d+:%d+$") then return nil, "invalid preview" end
  if not integer(preview.untilAt, 0, MAX) or not integer(now, 0, MAX) then return nil, "invalid preview" end
  if type(preview.items) ~= "table" or type(sections) ~= "table" or type(pinned) ~= "table" then
    return nil, "invalid preview"
  end
  local current = {}
  for i = 1, #sections do
    local section, err = M.parseSection(sections[i])
    if not section then return nil, err end
    current[section.key] = section
  end
  local delete, skipped = {}, {}
  local expired = now >= preview.untilAt
  for i = 1, #preview.items do
    local item = preview.items[i]
    if not previewItem(item) then return nil, "bad preview item" end
    local reason = nil
    if expired then reason = "expired"
    elseif pinned[item.key] then reason = "pinned"
    else
      local section = current[item.key]
      if not section then reason = "missing"
      elseif section.rev ~= item.rev or section.hash ~= item.hash then reason = "mismatch"
      end
    end
    if reason then skipped[#skipped + 1] = { key = item.key, reason = reason }
    else delete[#delete + 1] = { key = item.key, rev = item.rev, hash = item.hash } end
  end
  return { delete = delete, skipped = skipped }
end

function M.note(samples, at, used)
  if #samples > 0 then
    local last = samples[#samples]
    if last.at == at and last.used == used then return samples end
  end
  samples[#samples + 1] = { at = at, used = used }
  while #samples > 16 do table.remove(samples, 1) end
  return samples
end

return M
