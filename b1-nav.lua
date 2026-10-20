-- Offline movement inside a signed lease. GPS and per-step reserve stay in nav.lua until N1.
-- This wrapper is used only when leaseV2 and offlineAutonomy are both on.
local M = {}
local A = dofile("atomic.lua")
local Lease = dofile("lease.lua")
local Journal = dofile("journal.lua")
local N1 = dofile("lib/stubs/b1_n1.lua")
local H4c = dofile("lib/stubs/b1_h4c.lua")

local function integer(n)
  return type(n) == "number" and n == n and n % 1 == 0
end

function M.wrap(nav, cfg)
  assert(type(cfg.client) == "table" and type(cfg.secret) == "string" and type(cfg.mac) == "function", "lease client required")
  assert(type(cfg.now) == "function" and type(cfg.free) == "function", "lease clock required")
  local turtleApi = cfg.turtle or turtle
  local lease, journal, pose
  local cache = A.store(cfg.cache or "lease.cache", function(v)
    return type(v) == "table" and v.v == 1 and Lease.shape(v.lease) and type(v.lease.mac) == "string"
  end, 65536)
  local api = { enabled = true }

  local function using()
    return lease and journal and pose and cfg.now() < lease.untilAt and not lease.fenced
  end

  function api.ready()
    return using()
  end

  function api.offline()
    return using() and lease.grant == "work"
  end

  function api.gate()
    if not lease or not journal then return nil end
    if not using() then return "denied" end
    if lease.grant == "return" or journal.shouldReturn() then return "home" end
    if cfg.now() >= lease.issuedAt + lease.settings.values.checkInEveryMs then return "check in" end
    return nil
  end

  function api.pose()
    if pose then return N1.copy(pose) end
    return nav.pose()
  end

  function api.stopped() return nav.stopped() end
  function api.stop() return nav.stop() end
  function api.resume() return nav.resume() end
  function api.record(p, name) return nav.record(p, name) end

  function api.homeCost(goal, from)
    if using() then
      local origin = from or pose
      return math.abs(origin.x - goal.x) + math.abs(origin.y - goal.y) + math.abs(origin.z - goal.z)
    end
    return nav.homeCost(goal, from)
  end

  local function fuel()
    local level = turtleApi.getFuelLevel()
    if type(level) == "number" then return level end
  end

  local function entry(kind, phase, fields)
    local seq = journal.head().committed + 1
    local out = {
      v = 1, seq = seq, lease = lease.id, at = cfg.now(), frame = lease.frame,
      kind = kind, phase = phase, fuelBefore = fuel(),
    }
    for k, v in pairs(fields) do out[k] = v end
    return out
  end

  local function append(kind, phase, fields)
    return journal.append(entry(kind, phase, fields))
  end

  local function openJournal(stored)
    local budget = H4c.journalBudget({
      freeBytes = cfg.free(), budget = cfg.budget,
      ceiling = lease.settings.values.journalMaxBytes ~= false and lease.settings.values.journalMaxBytes or nil,
    })
    if budget < 1 then return false, "journal budget" end
    journal = Journal.open({
      lease = lease.id, budget = budget, path = cfg.journal or "lease.journal",
      maxEvents = lease.settings.values.journalMaxEvents, turtle = lease.turtle,
    })
    local seed = stored or {
      v = 1, frame = lease.frame, yAbs = true, dim = nav.pose().dim,
      x = nav.pose().x, y = nav.pose().y, z = nav.pose().z, h = nav.pose().h or 0,
      conf = cfg.confidence or "suspect",
      src = cfg.confidence == "certain" and "gps" or "inherited",
      anchoredAt = cfg.now(),
    }
    for _, item in ipairs(journal.entries()) do
      if item.phase == "done" and item.to and (item.kind == "move" or item.kind == "turn") then seed = item.to end
    end
    if not N1.pos(seed) then return false, "invalid cached pose" end
    pose = seed
    return true
  end

  function api.ensure()
    local now = cfg.now()
    local stored = cache.value
    if stored and Lease.verify(stored.lease, cfg.secret, cfg.mac) and now < stored.lease.untilAt then
      lease = stored.lease
      return openJournal(stored.pose)
    end
    if type(cfg.spec) ~= "table" then return false, "lease spec required" end
    local spec = cfg.spec
    local reply, err = cfg.client.call("lease-issue", {
      area = spec.area, corridor = spec.corridor, dropoff = spec.dropoff, charger = spec.charger,
      home = spec.home, fuelReserve = spec.fuelReserve, settings = spec.settings,
      settingsRevision = spec.settingsRevision, frame = spec.frame,
    })
    if not reply or not reply.ok or not Lease.verify(reply.lease, cfg.secret, cfg.mac) then
      return false, err or reply and reply.error or "bad lease mac"
    end
    lease = reply.lease
    local ok, why = cache.save({ v = 1, lease = lease })
    if not ok then return false, tostring(why) end
    return openJournal()
  end

  function api.use(signed)
    if not Lease.verify(signed, cfg.secret, cfg.mac) then return false, "bad lease mac" end
    lease = signed
    local ok, why = cache.save({ v = 1, lease = lease })
    if not ok then return false, tostring(why) end
    return openJournal()
  end

  local function turnTo(h)
    while pose.h ~= h do
      local from = N1.copy(pose)
      local delta = (h - from.h) % 4 == 3 and 3 or 1
      local to = N1.copy(from)
      to.h = (from.h + delta) % 4
      local intent = entry("turn", "intent", { from = from, to = to })
      local done = entry("turn", "done", { from = from, to = to })
      done.seq = intent.seq + 1
      if not journal.fits({ intent, done }) then return false, "journal full" end
      if not append("turn", "intent", { from = from, to = to }) then return false, "journal full" end
      local ok, err = (delta == 3 and turtleApi.turnLeft or turtleApi.turnRight)()
      append("turn", "done", { from = from, to = ok and to or from })
      if not ok then return false, err end
      pose = to
    end
    return true
  end

  local function step(d, policy)
    if not using() then return nav.step(d, policy) end
    if not integer(d) or d < 0 or d > 5 or (policy ~= "walk" and policy ~= "explore" and policy ~= "excavate") then
      return false, "invalid movement policy"
    end
    if d < 4 then
      local ok, err = turnTo(d)
      if not ok then return false, err end
    end
    local from = N1.copy(pose)
    local to = N1.offset(from, d)
    if not to then return false, "invalid movement policy" end
    local inspect = d == 4 and turtleApi.inspectUp or d == 5 and turtleApi.inspectDown or turtleApi.inspect
    local dig = d == 4 and turtleApi.digUp or d == 5 and turtleApi.digDown or turtleApi.dig
    local move = d == 4 and turtleApi.up or d == 5 and turtleApi.down or turtleApi.forward
    local found, info = inspect()
    local name = found and info.name or "minecraft:air"
    if name:find("turtle", 1, true) then return false, "occupied" end
    local mode, why = Lease.authorize({
      lease = lease, from = from, to = to, now = cfg.now(),
      dig = found and policy == "excavate" or false,
      journal = journal.head(), settings = lease.settings, home = lease.home,
    })
    if mode ~= "local" and mode ~= "return" then return false, why end
    local fields = { cell = to, name = found and name or false }
    local observe = entry("observe", "done", fields)
    if not journal.fits({ observe }) then return false, "journal full" end
    if not append("observe", "done", fields) then return false, "journal full" end
    if found and policy ~= "excavate" then return false, "blocked" end
    if found then
      if from.conf ~= "certain" then return false, "lost" end
      local digIntent = entry("dig", "intent", fields)
      local digDone = entry("dig", "done", { cell = to, name = name })
      digDone.seq = digIntent.seq + 1
      if not journal.fits({ digIntent, digDone }) then return false, "journal full" end
      append("dig", "intent", fields)
      local dug, err = dig()
      append("dig", "done", { cell = to, name = name })
      if not dug then return false, err end
      if inspect() then return false, "falling block" end
    end
    if turtleApi.getFuelLevel() == 0 then return false, "out of fuel" end
    local moveIntent = entry("move", "intent", { from = from, to = to })
    local moveDone = entry("move", "done", { from = from, to = to })
    moveDone.seq = moveIntent.seq + 1
    if not journal.fits({ moveIntent, moveDone }) then return false, "journal full" end
    append("move", "intent", { from = from, to = to })
    local moved, err = move()
    append("move", "done", { from = from, to = moved and to or from })
    if moved then pose = to end
    return moved, err
  end

  function api.step(d, policy)
    return step(d, policy)
  end

  function api.face(h)
    if not using() then return nav.face(h) end
    if not integer(h) or h < 0 or h > 3 then return false, "invalid heading" end
    return turnTo(h)
  end

  function api.go(goal, policy)
    if not using() then return nav.go(goal, policy) end
    if type(goal) ~= "table" or not integer(goal.x) or not integer(goal.y) or not integer(goal.z) then
      return false, "invalid route"
    end
    local guard = 0
    while pose.x ~= goal.x or pose.y ~= goal.y or pose.z ~= goal.z do
      guard = guard + 1
      if guard > 512 then return false, "no route" end
      local here = math.abs(pose.x - goal.x) + math.abs(pose.y - goal.y) + math.abs(pose.z - goal.z)
      local best, bestDist
      for d = 0, 5 do
        local to = N1.offset(pose, d)
        if to then
          local dist = math.abs(to.x - goal.x) + math.abs(to.y - goal.y) + math.abs(to.z - goal.z)
          local mode = Lease.authorize({
            lease = lease, from = pose, to = to, now = cfg.now(), dig = false,
            journal = journal.head(), settings = lease.settings, home = lease.home,
          })
          if (mode == "local" or mode == "return") and dist < here and (not bestDist or dist < bestDist) then
            best, bestDist = d, dist
          end
        end
      end
      if not best then return false, "no route" end
      local ok, err = step(best, policy or "walk")
      if not ok then return false, err end
    end
    if goal.h ~= nil then return api.face(goal.h) end
    return true
  end

  return api
end

return M
