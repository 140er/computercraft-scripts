-- SSOT adapter for plan-put, plan-intent, plan-code, and plan-claim.
-- Planner data lives on s.planner. Reservation checks call blocks().

local Core = dofile("planner-core.lua")
local Enrol = dofile("planner-enrol.lua")
local Settings = dofile("planner-settings.lua")

local M = {}

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

function M.normalize(planner, origin, now)
  if type(planner) == "table" and planner.v == 1 then return planner end
  return Core.empty(origin, now)
end

function M.valid(planner)
  if planner == nil then return true end
  if type(planner) ~= "table" or planner.v ~= 1 then return false end
  if not integer(planner.rev, 0, 2147483647) then return false end
  if not integer(planner.origin, 0, 2147483647) then return false end
  if not integer(planner.counter, 0, 2147483647) then return false end
  if not integer(planner.y, -2048, 2048) then return false end
  if planner.anchored ~= true and planner.anchored ~= false then return false end
  if planner.frame ~= "abs" and (type(planner.frame) ~= "string" or not planner.frame:match("^f:%d+:%d+$")) then
    return false
  end
  if type(planner.dim) ~= "string" or not planner.dim:match("^[%w_]+:[%w_/.-]+$") then return false end
  if type(planner.plans) ~= "table" or type(planner.fixtures) ~= "table"
    or type(planner.bots) ~= "table" or type(planner.codes) ~= "table" then return false end
  if planner.active ~= false and type(planner.active) ~= "string" then return false end
  local plans = 0
  for id, plan in pairs(planner.plans) do
    plans = plans + 1
    if plans > 8 or id ~= plan.id or plan.v ~= 1 or not integer(plan.rev, 0, planner.rev) then return false end
    if not integer(plan.y, -2048, 2048) or type(plan.areas) ~= "table" then return false end
  end
  return true
end

function M.blocks(planner, pose)
  return Core.blocks(planner, pose)
end

function M.holds(planner)
  local list = {}
  if type(planner) ~= "table" then return list end
  for id, fixture in pairs(planner.fixtures or {}) do
    if fixture.state == "planned" and fixture.pos then
      list[#list + 1] = { id = id, kind = fixture.kind, pos = fixture.pos }
    end
  end
  for id, bot in pairs(planner.bots or {}) do
    if (bot.state == "planned" or bot.state == "code-issued") and bot.pos then
      list[#list + 1] = { id = id, kind = "bot", pos = bot.pos }
    end
  end
  return list
end

local function same(a, b)
  return a and b and a.dim == b.dim and a.x == b.x and a.y == b.y and a.z == b.z
end

local function taken(s, pose, owner)
  for id, pos in pairs(s.poses or {}) do
    if id ~= owner and same(pos, pose) then return true end
  end
  for id, move in pairs(s.moves or {}) do
    if id ~= owner and (same(move.to, pose) or same(move.from, pose)) then return true end
  end
  return false
end

function M.apply(planner, event, clock)
  local now = clock
  if type(clock) == "function" then now = clock() end
  return Core.transition(planner, event, now, { enrol = Enrol, settings = Settings })
end

function M.commit(s, event, clock, id, boot)
  s.planner = M.normalize(s.planner, s.planner and s.planner.origin or 0, 0)
  local nextState, effects, err = M.apply(s.planner, event, clock)
  if not nextState then return nil, err end
  local sync
  for _, effect in ipairs(effects or {}) do
    if effect.op == "sync" then sync = effect end
  end
  if sync and taken(s, sync.pose, id) then return nil, "pose conflict" end
  s.planner = nextState
  if sync then
    local pose = sync.pose
    s.poses = s.poses or {}
    s.poses[id] = {
      dim = pose.dim, x = pose.x, y = pose.y, z = pose.z, h = pose.h,
      boot = boot, conf = pose.conf, frame = pose.frame, src = pose.src or "neighbour",
    }
    sync.computerId = id
  end
  return effects, err
end

local function reply(effects, err, rev)
  local screen, code, untilAt, role, settings, pose
  for _, effect in ipairs(effects or {}) do
    if effect.op == "screen" then screen = effect.text end
    if effect.op == "code" then code, untilAt = effect.code, effect.untilAt end
    if effect.op == "sync" then
      role, settings, pose = effect.role, effect.settings, effect.pose
    end
  end
  return {
    ok = err == nil, error = err or false, rev = rev, screen = screen or false,
    code = code or false, untilAt = untilAt or false,
    role = role or false, settings = settings or false, pose = pose or false,
  }
end

function M.op(s, id, m, clock)
  s.planner = M.normalize(s.planner, 0, 0)
  if m.op == "plan-put" then
    if type(m.event) ~= "table" or type(m.event.t) ~= "string" then
      return { ok = false, error = "invalid plan event" }
    end
    if m.event.t == "claim" or m.event.t == "boot" then
      return { ok = false, error = "invalid plan event" }
    end
    if m.rev ~= nil and m.rev ~= s.planner.rev then return { ok = false, error = "stale revision" } end
    local effects, err = M.commit(s, m.event, clock, id, m.boot)
    if not effects then return { ok = false, error = err } end
    local out = reply(effects, err, s.planner.rev)
    out.holds = M.holds(s.planner)
    return out
  end
  if m.op == "plan-intent" then
    return { ok = true, rev = s.planner.rev, holds = M.holds(s.planner) }
  end
  if m.op == "plan-code" then
    local effects, err = M.commit(s, { t = "issue" }, clock, id, m.boot)
    if not effects then return { ok = false, error = err } end
    return reply(effects, err, s.planner.rev)
  end
  if m.op == "plan-claim" then
    local observe = m.observe or (type(m.event) == "table" and m.event.observe)
    local code = m.code or (type(m.event) == "table" and m.event.code)
    local effects, err = M.commit(s, {
      t = "claim", code = code, observe = observe, computerId = id,
    }, clock, id, m.boot)
    if not effects then return { ok = false, error = err } end
    return reply(effects, err, s.planner.rev)
  end
  return { ok = false, error = "unknown operation" }
end

return M
