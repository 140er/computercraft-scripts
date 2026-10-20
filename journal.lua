-- Append-only lease journal. Replay identity is (turtle, lease, seq).
local M = {}
local A = dofile("atomic.lua")
local N1 = dofile("lib/stubs/b1_n1.lua")
local kinds = { move = true, turn = true, dig = true, observe = true, item = true, problem = true, boot = true, anchor = true }

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function size(value)
  local text
  local ok = pcall(function()
    text = textutils.serialize(value, { compact = true })
  end)
  if not ok or type(text) ~= "string" then text = textutils.serialize(value) end
  return #text
end

function M.shouldReturn(head)
  return type(head) == "table" and integer(head.bytes, 0, 9007199254740991)
    and integer(head.budget, 1, 9007199254740991) and head.bytes * 10 >= head.budget * 8
end

function M.validEntry(e, turtle)
  if type(e) ~= "table" or e.v ~= 1 or not integer(e.seq, 1, 2147483647) then return false end
  if type(e.lease) ~= "string" or #e.lease == 0 or #e.lease > 80 then return false end
  if not integer(e.at, 0, 9007199254740991) then return false end
  if e.frame ~= "abs" and (type(e.frame) ~= "string" or not e.frame:match("^f:[%w:_-]+$")) then return false end
  if not kinds[e.kind] or (e.phase ~= "intent" and e.phase ~= "done") then return false end
  if e.from ~= nil and not N1.pos(e.from) then return false end
  if e.to ~= nil and not N1.pos(e.to) then return false end
  if e.cell ~= nil and not N1.pos(e.cell) then return false end
  if e.fuelBefore ~= nil and not integer(e.fuelBefore, 0, 9007199254740991) then return false end
  if e.count ~= nil and not integer(e.count, 0, 1000000) then return false end
  if e.name ~= nil and e.name ~= false and (type(e.name) ~= "string" or #e.name == 0 or #e.name > 128
    or not e.name:match("^[%w_]+:[%w_/.-]+$")) then return false end
  if e.kind == "observe" and e.name ~= false and type(e.name) ~= "string" then return false end
  if (e.kind == "move" or e.kind == "turn") and (not N1.pos(e.from) or not N1.pos(e.to)) then return false end
  if (e.kind == "dig" or e.kind == "observe") and not N1.pos(e.cell) then return false end
  if e.kind == "item" and (type(e.name) ~= "string" or not integer(e.count, 0, 1000000)) then return false end
  if e.kind == "problem" and type(e.name) ~= "string" then return false end
  if turtle ~= nil and e.turtle ~= nil and e.turtle ~= turtle then return false end
  return true
end

local function blank(lease, budget)
  return {
    v = 1,
    head = { v = 1, lease = lease, committed = 0, acked = 0, bytes = 0, budget = budget },
    entries = {},
  }
end

function M.accept(state, entry, turtle, maxEvents)
  if not M.validEntry(entry, turtle) then return nil, "invalid journal entry" end
  if state.head.lease ~= entry.lease then return nil, "journal lease changed" end
  if entry.seq <= state.head.committed then return state end
  if entry.seq ~= state.head.committed + 1 then return nil, "journal gap" end
  maxEvents = maxEvents or 1024
  if #state.entries >= maxEvents then return nil, "journal event limit" end
  local extra = size(entry)
  if state.head.bytes + extra > state.head.budget then return nil, "journal full" end
  local nextState = {
    v = 1,
    head = {
      v = 1, lease = state.head.lease, committed = entry.seq, acked = state.head.acked,
      bytes = state.head.bytes + extra, budget = state.head.budget,
    },
    entries = {},
  }
  for i, old in ipairs(state.entries) do nextState.entries[i] = old end
  nextState.entries[#nextState.entries + 1] = entry
  return nextState
end

function M.open(cfg)
  assert(type(cfg.lease) == "string" and integer(cfg.budget, 1, 9007199254740991), "journal budget required")
  local maxEvents = cfg.maxEvents or 1024
  local function valid(v)
    if type(v) ~= "table" or v.v ~= 1 or type(v.head) ~= "table" or type(v.entries) ~= "table" then return false end
    local head = v.head
    if head.v ~= 1 or head.lease ~= cfg.lease or not integer(head.committed, 0, 2147483647)
      or not integer(head.acked, 0, head.committed) or not integer(head.bytes, 0, 9007199254740991)
      or head.budget ~= cfg.budget or #v.entries ~= head.committed or #v.entries > maxEvents then return false end
    local bytes = 0
    for i, entry in ipairs(v.entries) do
      if entry.seq ~= i or not M.validEntry(entry) or entry.lease ~= cfg.lease then return false end
      bytes = bytes + size(entry)
    end
    return bytes == head.bytes
  end
  local store = A.store(cfg.path or "lease.journal", valid, cfg.limit or 262144)
  local state = store.value or blank(cfg.lease, cfg.budget)
  local api = {}
  local function persist(nextState)
    local ok, err = store.save(nextState)
    if not ok then return nil, tostring(err) end
    state = nextState
    return state
  end
  function api.head()
    return {
      v = state.head.v, lease = state.head.lease, committed = state.head.committed,
      acked = state.head.acked, bytes = state.head.bytes, budget = state.head.budget,
    }
  end
  function api.entries()
    local out = {}
    for i, entry in ipairs(state.entries) do out[i] = entry end
    return out
  end
  function api.fits(list)
    local cursor = state
    for _, entry in ipairs(list) do
      local nextState = M.accept(cursor, entry, cfg.turtle, maxEvents)
      if not nextState or nextState == cursor then return false end
      cursor = nextState
    end
    return true
  end
  function api.append(entry)
    local nextState, err = M.accept(state, entry, cfg.turtle, maxEvents)
    if not nextState then return nil, err end
    if nextState == state then return api.head() end
    local saved, why = persist(nextState)
    if not saved then return nil, why end
    return api.head()
  end
  function api.ack(n)
    if not integer(n, state.head.acked, state.head.committed) then return nil, "invalid journal ack" end
    local nextState = A.copy(state)
    nextState.head.acked = n
    return persist(nextState)
  end
  function api.shouldReturn()
    return M.shouldReturn(state.head)
  end
  return api
end

return M
