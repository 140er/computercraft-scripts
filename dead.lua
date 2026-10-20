-- H5. A started move keeps both cells until this turtle has been silent for
-- deadAfterMs. Lease expiry only rejects commit and renew. Mining ownership
-- stays with the turtle that activated it.

local M = {}

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

function M.valid(live)
  if live == nil then return true end
  if type(live) ~= "table" then return false end
  local n = 0
  for id, rec in pairs(live) do
    n = n + 1
    if n > 32 or not integer(id, 0, 2147483647) or type(rec) ~= "table" or rec.v ~= 1
      or not integer(rec.lastAt, 0, 9007199254740991)
      or (rec.state ~= "alive" and rec.state ~= "missing")
      or (rec.missingAt ~= nil and not integer(rec.missingAt, 0, 9007199254740991)) then
      return false
    end
  end
  return true
end

function M.missing(s, id)
  local rec = s.live and s.live[id]
  return rec ~= nil and rec.state == "missing"
end

function M.note(s, id, now)
  s.live = s.live or {}
  local rec = s.live[id]
  if not rec then
    s.live[id] = { v = 1, lastAt = now, state = "alive" }
    return
  end
  rec.lastAt = now
end

function M.revive(s, id, now)
  M.note(s, id, now)
  local rec = s.live[id]
  rec.state = "alive"
  rec.missingAt = nil
end

local function cargo(job)
  for _, line in ipairs(job.lines) do
    if line.picked ~= line.delivered then return true end
  end
  return false
end

local function emptyJob(job)
  for _, line in ipairs(job.lines) do
    if line.picked ~= 0 or line.delivered ~= 0 then return false end
  end
  return true
end

local function releaseLocks(s, id)
  local wh = s.warehouse
  if not wh or type(wh.locks) ~= "table" then return false end
  local names = {}
  for name, owner in pairs(wh.locks) do
    if owner == id then names[#names + 1] = name end
  end
  for _, name in ipairs(names) do wh.locks[name] = nil end
  return #names > 0
end

local function releaseEmptyJobs(s, id)
  local wh = s.warehouse
  if not wh or type(wh.orders) ~= "table" then return false end
  local changed = false
  for _, job in pairs(wh.orders) do
    if job.owner == id and job.status == "active" and emptyJob(job) then
      job.status, job.owner, job.token = "open", nil, nil
      changed = true
    end
  end
  return changed
end

local function mineHeld(s, id)
  if not s.mining or type(s.mining.tasks) ~= "table" then return false end
  for _, task in ipairs(s.mining.tasks) do
    if task.owner == id and task.status ~= "open" and task.status ~= "done" then return true end
  end
  return false
end

function M.sweep(s, now, window)
  local ids = {}
  local function add(id)
    if type(id) == "number" then ids[id] = true end
  end
  for id in pairs(s.poses or {}) do add(id) end
  for id in pairs(s.moves or {}) do add(id) end
  for id in pairs(s.live or {}) do add(id) end
  if not next(ids) then return false end
  s.live = s.live or {}
  local changed = false
  for id in pairs(ids) do
    if not s.live[id] then
      s.live[id] = { v = 1, lastAt = now, state = "alive" }
      changed = true
    end
    local rec = s.live[id]
    if rec.state == "alive" and now - rec.lastAt >= window then
      rec.state, rec.missingAt = "missing", now
      changed = true
      if s.moves then s.moves[id] = nil end
      if releaseLocks(s, id) then changed = true end
      if releaseEmptyJobs(s, id) then changed = true end
    end
  end
  return changed
end

function M.forget(s, id)
  local rec = s.live and s.live[id]
  local present = (s.poses and s.poses[id] ~= nil) or (s.moves and s.moves[id] ~= nil) or rec ~= nil
  if not present then return { ok = true, changed = false, cargo = false, mine = false } end
  if not rec or rec.state ~= "missing" then return { ok = false, error = "turtle is alive" } end
  local held = false
  local wh = s.warehouse
  if type(wh) == "table" and type(wh.orders) == "table" then
    for _, job in pairs(wh.orders) do
      if job.owner == id and job.status == "active" and cargo(job) then held = true end
    end
  end
  releaseLocks(s, id)
  releaseEmptyJobs(s, id)
  local mine = mineHeld(s, id)
  s.poses[id] = nil
  if s.moves then s.moves[id] = nil end
  s.live[id] = nil
  return { ok = true, changed = true, cargo = held, mine = mine }
end

return M
