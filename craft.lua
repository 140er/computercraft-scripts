-- Craft worker: progress journal, turtle grid, and the factory adapter.
-- The factory enters this file only when factory.cfg sets wh2.enabled = true.

local M = {}
local CRAFT_SLOTS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local SLOT = {}
for _, slot in ipairs(CRAFT_SLOTS) do SLOT[slot] = true end

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then error("cycle", 0) end
  seen[value] = true
  local out = {}
  for k, v in pairs(value) do out[copy(k, seen)] = copy(v, seen) end
  seen[value] = nil
  return out
end

local function loadDep()
  local function attempt(path)
    local ok, mod = pcall(dofile, path)
    if ok and type(mod) == "table" then return mod end
  end
  local client = attempt("wh2-client.lua")
  local layout = attempt("wh2-layout.lua")
  local stub = attempt("lib/stubs/craft_dep.lua") or attempt("craft_dep.lua") or {}
  return {
    reserve = (layout and type(layout.reserveCraft) == "function" and layout.reserveCraft)
      or stub.reserve or function() return { orderKey = false, line = false, deferred = true } end,
    lookupClass = (client and type(client.lookupClass) == "function" and client.lookupClass)
      or stub.lookupClass or function(item) return { route = "unknown", item = item } end,
    register = stub.register,
  }
end

function M.dependency()
  return loadDep()
end

function M.prepareMove(step)
  local dep = loadDep()
  local reservation = dep.reserve(step)
  if type(reservation) ~= "table" or reservation.deferred or reservation.orderKey == false then
    return false, "layout_unavailable"
  end
  return reservation
end

function M.classify(itemId)
  return loadDep().lookupClass(itemId)
end

local function fileBackend(path)
  return {
    read = function()
      if not fs.exists(path) then return nil end
      local h = fs.open(path, "r")
      if not h then return nil end
      local text = h.readAll()
      h.close()
      local ok, value = pcall(textutils.unserialize, text)
      if ok then return value end
    end,
    write = function(value)
      local tmp = path .. ".tmp"
      local h = fs.open(tmp, "w")
      h.write(textutils.serialize(value, { compact = true }))
      h.close()
      if fs.exists(path) then fs.delete(path) end
      fs.move(tmp, path)
    end,
  }
end

function M.journal(backend, computerId)
  if type(backend) ~= "table" then backend = fileBackend(backend or "craft.journal") end
  computerId = computerId or (os and os.getComputerID and os.getComputerID()) or 0
  local state = backend.read()
  if type(state) ~= "table" or state.v ~= 1 then
    state = { v = 1, counter = 0, acked = 0, pending = false }
  end
  local api = {}
  local function save() backend.write(state) end
  function api.pending()
    if state.pending == false then return false end
    return copy(state.pending)
  end
  function api.acked() return state.acked end
  function api.begin(spec)
    if state.pending then return copy(state.pending) end
    if type(spec) ~= "table" then return nil, "invalid" end
    state.counter = state.counter + 1
    state.pending = {
      eventId = "cp:" .. tostring(computerId) .. ":" .. state.counter,
      seq = spec.seq, stepId = spec.stepId, state = spec.state,
      observed = copy(spec.observed), jobId = spec.jobId,
      token = spec.token, epoch = spec.epoch,
    }
    save()
    return copy(state.pending)
  end
  function api.ack(seq)
    if not state.pending or state.pending.seq ~= seq then return false end
    state.acked = seq
    save()
    state.pending = false
    save()
    return true
  end
  return api
end

function M.gridReady(detail, pattern)
  if type(pattern) ~= "table" then return false, "invalid" end
  for slot = 1, 16 do
    if not SLOT[slot] then
      local have = detail(slot)
      if have and (have.count or 0) > 0 then return false, "slot_occupied" end
    end
  end
  for _, slot in ipairs(CRAFT_SLOTS) do
    local have = detail(slot)
    local count = have and have.count or 0
    local want = pattern[slot]
    if want and want ~= false then
      if count < 1 or have.item ~= want then return false, "missing_ingredient" end
    elseif count > 0 then
      return false, "slot_occupied"
    end
  end
  return true
end

function M.placeAndCraft(api, pattern, batches)
  if type(api) ~= "table" or type(api.craft) ~= "function" then return false, "no_turtle" end
  local function detail(slot)
    if api.getItemDetail then return api.getItemDetail(slot) end
    return nil
  end
  local ready, why = M.gridReady(detail, pattern)
  if not ready then return false, why end
  local ok, err = api.craft(batches or 1)
  if ok == false then return false, err or "craft_failed" end
  local out = detail(1)
  return true, out
end

function M.worker(opts)
  opts = opts or {}
  local journal = opts.journal
  local client = opts.client or {}
  local api = {}
  function api.tick()
    local pending = journal and journal.pending()
    if pending and pending ~= false then
      local result = client.progress and client.progress(pending)
      if result and result.ok and journal.ack(pending.seq) then return result end
      return result or { ok = false, code = "unavailable", error = "progress not sent" }
    end
    if opts.step and opts.pattern then
      local reserved, why = M.prepareMove(opts.step)
      if not reserved then return { ok = false, code = "unavailable", error = why } end
    end
    if not client.claim then return { ok = true, idle = true } end
    return client.claim()
  end
  return api
end

function M.factory(args, cfg)
  local wh2 = type(cfg) == "table" and cfg.wh2 or nil
  local craftOn = wh2 == nil or type(wh2) == "table" and (wh2.enabled == nil or wh2.enabled == true)
  if type(cfg) ~= "table" or not craftOn then
    print("wh2 craft is off")
    return false
  end
  local journal = M.journal("craft.journal", os.getComputerID())
  print("wh2 craft worker")
  if args and args[2] == "once" then
    local worker = M.worker({ journal = journal })
    return worker.tick()
  end
  while true do
    local worker = M.worker({ journal = journal })
    worker.tick()
    sleep(1)
  end
end

return M
