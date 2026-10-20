-- Stub for T1's planner-core.lua. T1 replaces this file.
-- Pure: no term, peripheral, fs, or rednet. A1 sends the events below.
-- transition(state, event) -> state, effects
--   { t = "level", y = n }
--   { t = "place", kind = "chest", at = pos }
--   { t = "place", kind = "bot", role = "miner", at = pos, h = 0..3 }
--   { t = "undo" }
--   { t = "confirm" }
-- effects: { op = "error", why = "..." } or { op = "plan-code", plan = id }
-- view(state) -> { plan = plan, fixtures = { [id] = fixture }, bots = { [id] = bot } }
-- Shapes match plan section 5b. One level, one chest, one miner.

local M = {}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[copy(k)] = copy(v) end
  return out
end

local function integer(n)
  return type(n) == "number" and n == n and n % 1 == 0 and math.abs(n) <= 30000000
end

local function posOk(p)
  return type(p) == "table" and integer(p.x) and integer(p.y) and integer(p.z)
    and type(p.dim) == "string" and p.v == 1 and p.frame == "abs" and p.yAbs == true
end

function M.blank(dim, origin)
  origin = origin or 0
  return {
    origin = origin,
    seq = 1,
    id = "p:" .. tostring(origin) .. ":1",
    frame = "abs",
    dim = dim or "minecraft:overworld",
    y = nil,
    name = "Base",
    rev = 0,
    fixtures = {},
    bots = {},
    undo = {},
    confirmed = false,
  }
end

local function mint(state)
  state.seq = state.seq + 1
  return "p:" .. tostring(state.origin) .. ":" .. tostring(state.seq)
end

local function snapshot(state)
  return {
    seq = state.seq, y = state.y, rev = state.rev, confirmed = state.confirmed,
    fixtures = copy(state.fixtures), bots = copy(state.bots),
  }
end

local function restore(state, snap)
  state.seq, state.y, state.rev, state.confirmed = snap.seq, snap.y, snap.rev, snap.confirmed
  state.fixtures, state.bots = snap.fixtures, snap.bots
end

local function fail(state, why)
  return state, { { op = "error", why = why } }
end

local function push(state)
  state.undo[#state.undo + 1] = snapshot(state)
  state.rev = state.rev + 1
end

function M.transition(state, event)
  if type(event) ~= "table" or type(event.t) ~= "string" then return fail(state, "Bad event.") end
  if state.confirmed and event.t ~= "confirm" then return fail(state, "Plan already confirmed.") end
  if event.t == "undo" then
    local snap = state.undo[#state.undo]
    if not snap then return fail(state, "Nothing to undo.") end
    state.undo[#state.undo] = nil
    restore(state, snap)
    return state, {}
  end
  if event.t == "level" then
    if not integer(event.y) then return fail(state, "Level must be a whole number.") end
    if event.y < -64 or event.y > 320 then return fail(state, "Level is out of range.") end
    push(state)
    state.y = event.y
    return state, {}
  end
  if event.t == "place" and event.kind == "chest" then
    if not posOk(event.at) or event.at.dim ~= state.dim then return fail(state, "Bad chest cell.") end
    if #state.fixtures >= 1 then return fail(state, "One chest in this plan.") end
    push(state)
    local id = mint(state)
    state.fixtures[1] = {
      v = 1, id = id, plan = state.id, kind = "chest", pos = copy(event.at),
      side = false, status = "planned", layoutId = false,
    }
    return state, {}
  end
  if event.t == "place" and event.kind == "bot" then
    if event.role ~= "miner" then return fail(state, "Use the panel for that role.") end
    if not posOk(event.at) or event.at.dim ~= state.dim then return fail(state, "Bad bot cell.") end
    if type(event.h) ~= "number" or event.h < 0 or event.h > 3 or event.h % 1 ~= 0 then
      return fail(state, "Facing must be north, east, south or west.")
    end
    if #state.bots >= 1 then return fail(state, "One miner in this plan.") end
    push(state)
    local id = mint(state)
    local pos = copy(event.at)
    pos.h = event.h
    state.bots[1] = {
      v = 1, id = id, plan = state.id, role = "miner", pos = pos,
      settings = { revision = 0, overrides = {} }, devToggles = {}, jobArea = false,
      expect = { neighbours = {}, peripherals = {} },
      status = "planned", code = false, computerId = false,
    }
    return state, {}
  end
  if event.t == "confirm" then
    if #state.fixtures ~= 1 or #state.bots ~= 1 then
      return fail(state, "Need a chest and a miner before confirm.")
    end
    push(state)
    state.confirmed = true
    state.bots[1].status = "code-issued"
    return state, { { op = "plan-code", plan = state.id } }
  end
  return fail(state, "Use the panel for that.")
end

function M.view(state)
  local plan = {
    v = 1, id = state.id, frame = state.frame, dim = state.dim, y = state.y,
    name = state.name, rev = state.rev, areas = {}, fixtures = {}, bots = {},
  }
  local fixtures, bots = {}, {}
  for i, fixture in ipairs(state.fixtures) do
    plan.fixtures[i] = fixture.id
    fixtures[fixture.id] = {
      v = fixture.v, id = fixture.id, plan = fixture.plan, kind = fixture.kind,
      pos = copy(fixture.pos), side = fixture.side, state = fixture.status,
      layoutId = fixture.layoutId,
    }
  end
  for i, bot in ipairs(state.bots) do
    plan.bots[i] = bot.id
    bots[bot.id] = {
      v = bot.v, id = bot.id, plan = bot.plan, role = bot.role, pos = copy(bot.pos),
      settings = copy(bot.settings), devToggles = copy(bot.devToggles),
      jobArea = bot.jobArea, expect = copy(bot.expect), state = bot.status,
      code = bot.code, computerId = bot.computerId,
    }
  end
  return { plan = plan, fixtures = fixtures, bots = bots }
end

return M
