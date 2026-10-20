-- Pure planner reducer. Events in, state and effects out. No terminal, disk, or modem calls.
-- transition(state, event, now, deps) -> state, effects, err
-- A hard error returns nil state. A failed claim returns the new state and err,
-- because the failed attempt is stored on the copy code.

local Enrol = dofile("planner-enrol.lua")
local Settings = dofile("planner-settings.lua")

local M = { v = 1 }

local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = -1, 0, 1, 0 }
local SIDE = { front = 0, right = 1, back = 2, left = 3 }
local FILLER = {
  ["minecraft:stone"] = true, ["minecraft:deepslate"] = true, ["minecraft:tuff"] = true,
  ["minecraft:andesite"] = true, ["minecraft:granite"] = true, ["minecraft:diorite"] = true,
  ["minecraft:dirt"] = true, ["minecraft:netherrack"] = true,
}

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then error("cyclic plan", 0) end
  seen[value] = true
  local out = {}
  for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
  seen[value] = nil
  return out
end

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function blockName(name)
  return type(name) == "string" and name:match("^[%w_]+:[%w_/.-]+$") ~= nil and #name <= 128
end

function M.empty(origin, now)
  origin = integer(origin, 0, 2147483647) and origin or 0
  now = integer(now, 0, 9007199254740991) and now or 0
  return {
    v = 1, origin = origin, counter = 0,
    frame = "f:" .. origin .. ":" .. now,
    dim = "minecraft:overworld", y = 64,
    anchored = false, anchoredAt = 0, anchor = false,
    rev = 0, active = false,
    plans = {}, fixtures = {}, bots = {}, codes = {},
  }
end

local function mint(s)
  s.counter = s.counter + 1
  return "p:" .. s.origin .. ":" .. s.counter
end

local function bump(s)
  s.rev = s.rev + 1
  local plan = s.active and s.plans[s.active]
  if plan then plan.rev = s.rev end
  return s
end

local function makePos(s, x, y, z, h)
  return {
    v = 1,
    frame = s.anchored and "abs" or s.frame,
    yAbs = true,
    dim = s.dim, x = x, y = y, z = z, h = h or 0,
    conf = s.anchored and "certain" or "suspect",
    src = "typed",
    anchoredAt = s.anchored and s.anchoredAt or 0,
  }
end

local function sameCell(a, b)
  return a and b and a.dim == b.dim and a.x == b.x and a.y == b.y and a.z == b.z
end

local function planOf(s)
  if not s.active then return nil, "no plan" end
  local plan = s.plans[s.active]
  if not plan then return nil, "no plan" end
  return plan
end

local function inside(plan, x, z, y)
  local area = plan.areas[1]
  if not area or area.min.y ~= y then return false end
  local x1, x2 = area.min.x, area.max.x
  local z1, z2 = area.min.z, area.max.z
  return x >= x1 and x <= x2 and z >= z1 and z <= z2
end

local function shiftPos(pos, dx, dz, frame, anchoredAt)
  pos.x, pos.z = pos.x + dx, pos.z + dz
  pos.frame, pos.anchoredAt = frame, anchoredAt
  pos.conf, pos.src = "certain", "typed"
end

local function absoluteBlocks(observe, facing)
  local out = {}
  for side, turn in pairs(SIDE) do
    local name = observe.blocks and observe.blocks[side]
    if type(name) == "string" then out[(facing + turn) % 4] = name end
  end
  return out
end

local function neighboursMatch(actual, expect)
  for heading, name in pairs(expect or {}) do
    if type(heading) == "number" and actual[heading] ~= name then return false end
  end
  return true
end

local function peripheralsMatch(observe, expect)
  for side, kind in pairs(expect or {}) do
    local got = observe.peripherals and observe.peripherals[side]
    if got ~= kind then return false end
  end
  return true
end

local function distinctive(expect)
  for _, name in pairs(expect.neighbours or {}) do
    if name ~= "minecraft:air" and not FILLER[name] then return true end
  end
  for _ in pairs(expect.peripherals or {}) do return true end
  return false
end

local function facingToward(bot, chest)
  if not chest then return 0 end
  local dx, dz = chest.pos.x - bot.x, chest.pos.z - bot.z
  for heading = 0, 3 do
    if DX[heading] == dx and DZ[heading] == dz then return heading end
  end
  return 0
end

local function activeChest(s, plan)
  for _, id in ipairs(plan.fixtures) do
    local fixture = s.fixtures[id]
    if fixture and fixture.kind == "chest" and fixture.state ~= "retired" then return fixture end
  end
end

local function activeBot(s, plan)
  for _, id in ipairs(plan.bots) do
    local bot = s.bots[id]
    if bot and bot.state ~= "retired" then return bot end
  end
end

local function refreshExpect(s, plan)
  local bot = activeBot(s, plan)
  if not bot or bot.state == "claimed" or bot.state == "code-issued" then return end
  local area = plan.areas[1]
  if area then bot.jobArea = { min = copy(area.min), max = copy(area.max) } end
  local chest = activeChest(s, plan)
  if chest and chest.pos.y == bot.pos.y
    and math.abs(chest.pos.x - bot.pos.x) + math.abs(chest.pos.z - bot.pos.z) == 1 then
    bot.pos.h = facingToward(bot.pos, chest)
  end
  local expect = { neighbours = {}, peripherals = {} }
  if chest and chest.pos.y == bot.pos.y then
    local dx, dz = chest.pos.x - bot.pos.x, chest.pos.z - bot.pos.z
    if DX[bot.pos.h] == dx and DZ[bot.pos.h] == dz then
      expect.neighbours[bot.pos.h] = "minecraft:chest"
      expect.peripherals.front = "inventory"
    end
  end
  bot.expect = expect
end

function M.blocks(planner, pose)
  if type(planner) ~= "table" or type(pose) ~= "table" then return false end
  for _, fixture in pairs(planner.fixtures or {}) do
    if fixture.state == "planned" and sameCell(fixture.pos, pose) then return true end
  end
  for _, bot in pairs(planner.bots or {}) do
    if (bot.state == "planned" or bot.state == "code-issued") and sameCell(bot.pos, pose) then return true end
  end
  return false
end

local function hard(err) return nil, nil, err end

function M.transition(state, event, now, deps)
  if type(state) ~= "table" or state.v ~= 1 then return hard("invalid plan state") end
  if type(event) ~= "table" or type(event.t) ~= "string" then return hard("invalid plan event") end
  now = integer(now, 0, 9007199254740991) and now or 0
  deps = deps or {}
  local enrol = deps.enrol or Enrol
  local settings = deps.settings or Settings
  local s = copy(state)
  local effects = {}

  local function finish(err)
    return s, effects, err
  end

  if event.t == "boot" then
    if not integer(event.origin, 0, 2147483647) then return hard("invalid origin") end
    if s.counter ~= 0 or s.active or next(s.plans) then return finish() end
    s.origin = event.origin
    s.frame = "f:" .. s.origin .. ":" .. now
    return finish()
  end

  if event.t == "level" then
    local y = event.y
    if event.dy ~= nil then
      if not integer(event.dy, -16, 16) then return hard("invalid level") end
      y = s.y + event.dy
    end
    if not integer(y, -2048, 2048) then return hard("invalid level") end
    if y == s.y then return finish() end
    s.y = y
    bump(s)
    effects[#effects + 1] = { op = "note", text = "Level " .. y }
    return finish()
  end

  if event.t == "anchor" then
    if not integer(event.x, -30000000, 30000000) or not integer(event.z, -30000000, 30000000)
      or not integer(event.y, -2048, 2048) or not integer(event.h or 0, 0, 3) then
      return hard("invalid anchor")
    end
    if type(event.dim) ~= "string" or not event.dim:match("^[%w_]+:[%w_/.-]+$") then
      return hard("invalid anchor")
    end
    if s.anchored then return finish() end
    local dx, dz = event.x, event.z
    s.anchored, s.anchoredAt = true, now
    s.anchor = { x = event.x, y = event.y, z = event.z, h = event.h or 0, dim = event.dim }
    s.dim, s.frame = event.dim, "abs"
    for _, plan in pairs(s.plans) do
      plan.frame, plan.dim = "abs", event.dim
      for _, area in ipairs(plan.areas) do
        shiftPos(area.min, dx, dz, "abs", now)
        shiftPos(area.max, dx, dz, "abs", now)
      end
    end
    for _, fixture in pairs(s.fixtures) do shiftPos(fixture.pos, dx, dz, "abs", now) end
    for _, bot in pairs(s.bots) do shiftPos(bot.pos, dx, dz, "abs", now) end
    for _, code in pairs(s.codes) do
      code.frame = "abs"
      if code.home then shiftPos(code.home, dx, dz, "abs", now) end
    end
    bump(s)
    effects[#effects + 1] = { op = "note", text = "Anchored at " .. event.x .. "," .. event.y .. "," .. event.z }
    return finish()
  end

  if event.t == "create" then
    if s.active then return hard("mvp limit") end
    local name = event.name or "Base"
    if type(name) ~= "string" or not name:match("^[%w ]+$") or #name > 40 then return hard("invalid name") end
    local id = mint(s)
    s.plans[id] = {
      v = 1, id = id, frame = s.anchored and "abs" or s.frame, dim = s.dim,
      y = s.y, name = name, rev = s.rev, areas = {}, fixtures = {}, bots = {},
    }
    s.active = id
    bump(s)
    effects[#effects + 1] = { op = "note", text = "Created " .. name }
    return finish()
  end

  if event.t == "retire" then
    local plan, err = planOf(s)
    if not plan then return hard(err) end
    for _, id in ipairs(plan.fixtures) do
      if s.fixtures[id] then s.fixtures[id].state = "retired" end
    end
    for _, id in ipairs(plan.bots) do
      local bot = s.bots[id]
      if bot then
        bot.state = "retired"
        if bot.code and s.codes[bot.code] then s.codes[bot.code].used = true end
      end
    end
    s.active = false
    bump(s)
    effects[#effects + 1] = { op = "note", text = "Retired " .. plan.name }
    return finish()
  end

  if event.t == "draw" or event.t == "place" or event.t == "edit" or event.t == "issue" then
    local plan, err = planOf(s)
    if not plan then return hard(err) end

    if event.t == "draw" or (event.t == "edit" and event.what == "base") then
      if not integer(event.x1, -30000000, 30000000) or not integer(event.x2, -30000000, 30000000)
        or not integer(event.z1, -30000000, 30000000) or not integer(event.z2, -30000000, 30000000) then
        return hard("invalid area")
      end
      local x1, x2 = math.min(event.x1, event.x2), math.max(event.x1, event.x2)
      local z1, z2 = math.min(event.z1, event.z2), math.max(event.z1, event.z2)
      if x2 - x1 > 63 or z2 - z1 > 63 then return hard("area too large") end
      local area = plan.areas[1]
      if not area then
        area = { id = mint(s), kind = "base" }
        plan.areas[1] = area
      end
      area.min = makePos(s, x1, s.y, z1, 0)
      area.max = makePos(s, x2, s.y, z2, 0)
      plan.y = s.y
      refreshExpect(s, plan)
      bump(s)
      effects[#effects + 1] = { op = "note", text = "Base " .. x1 .. "," .. z1 .. " to " .. x2 .. "," .. z2 }
      return finish()
    end

    if event.t == "edit" and event.what == "name" then
      if type(event.name) ~= "string" or not event.name:match("^[%w ]+$") or #event.name > 40 then
        return hard("invalid name")
      end
      plan.name = event.name
      bump(s)
      return finish()
    end

    if event.t == "place" or event.t == "edit" then
      local kind = event.kind or event.what
      if not integer(event.x, -30000000, 30000000) or not integer(event.z, -30000000, 30000000) then
        return hard("invalid cell")
      end
      if not inside(plan, event.x, event.z, s.y) then return hard("outside base") end
      if kind == "chest" then
        local chest = activeChest(s, plan)
        if event.t == "place" and chest then return hard("mvp limit") end
        if event.t == "edit" and not chest then return hard("no chest") end
        local pos = makePos(s, event.x, s.y, event.z, integer(event.h, 0, 3) and event.h or 0)
        if chest then
          chest.pos = pos
        else
          local id = mint(s)
          s.fixtures[id] = {
            v = 1, id = id, plan = plan.id, kind = "chest", pos = pos,
            side = "front", state = "planned", layoutId = false,
          }
          plan.fixtures[#plan.fixtures + 1] = id
        end
        refreshExpect(s, plan)
        bump(s)
        effects[#effects + 1] = { op = "note", text = "Chest at " .. event.x .. "," .. s.y .. "," .. event.z }
        return finish()
      end
      if kind == "bot" then
        local role = event.role or "miner"
        if role ~= "miner" then return hard("mvp limit") end
        local bot = activeBot(s, plan)
        if event.t == "place" and bot then return hard("mvp limit") end
        if event.t == "edit" and not bot then return hard("no bot") end
        local stored, why = settings.forBot(role)
        if not stored then return hard(why) end
        local h = integer(event.h, 0, 3) and event.h or facingToward({ x = event.x, z = event.z }, activeChest(s, plan))
        local pos = makePos(s, event.x, s.y, event.z, h)
        local expect = { neighbours = {}, peripherals = {} }
        local chest = activeChest(s, plan)
        if chest and chest.pos.y == s.y then
          local dx, dz = chest.pos.x - event.x, chest.pos.z - event.z
          if DX[h] == dx and DZ[h] == dz then
            expect.neighbours[h] = "minecraft:chest"
            expect.peripherals.front = "inventory"
          end
        end
        if bot then
          bot.pos, bot.expect, bot.jobArea = pos, expect, bot.jobArea
        else
          local id = mint(s)
          local area = plan.areas[1]
          s.bots[id] = {
            v = 1, id = id, plan = plan.id, role = role, pos = pos,
            settings = stored, devToggles = {},
            jobArea = area and { min = copy(area.min), max = copy(area.max) } or false,
            expect = expect, state = "planned", code = false, computerId = false,
          }
          plan.bots[#plan.bots + 1] = id
        end
        refreshExpect(s, plan)
        bump(s)
        effects[#effects + 1] = { op = "note", text = "Miner facing " .. h }
        return finish()
      end
      return hard("invalid place")
    end

    if event.t == "issue" then
      local bot = activeBot(s, plan)
      if not bot or bot.role ~= "miner" then return hard("no bot") end
      if not activeChest(s, plan) then return hard("no chest") end
      if bot.state == "code-issued" and bot.code and s.codes[bot.code] and not s.codes[bot.code].used then
        effects[#effects + 1] = { op = "code", code = bot.code, untilAt = s.codes[bot.code].untilAt }
        return finish()
      end
      if bot.state ~= "planned" then return hard("code used") end
      local record = enrol.issue(s.origin, s.counter + 1, bot, now)
      s.counter = s.counter + 1
      record.home = copy(bot.pos)
      s.codes[record.code] = record
      bot.code, bot.state = record.code, "code-issued"
      bump(s)
      effects[#effects + 1] = { op = "code", code = record.code, untilAt = record.untilAt }
      effects[#effects + 1] = { op = "note", text = "Code " .. record.code }
      return finish()
    end
  end

  if event.t == "claim" then
    if not enrol.matches(event.code) then return hard("code unknown") end
    local record = s.codes[event.code]
    if not record then return hard("code unknown") end
    if record.used then return hard("code used") end
    if now > record.untilAt then return hard("code expired") end
    local bot = s.bots[record.planBot]
    if not bot or bot.state ~= "code-issued" then return hard("code used") end
    local observe = event.observe
    if type(observe) ~= "table" or not integer(observe.h, 0, 3) or type(observe.blocks) ~= "table" then
      return hard("invalid observation")
    end
    for _, side in ipairs({ "front", "back", "left", "right", "up", "down" }) do
      if observe.blocks[side] ~= nil and not blockName(observe.blocks[side]) then
        return hard("invalid observation")
      end
    end
    local expect = bot.expect or { neighbours = {}, peripherals = {} }
    local found = {}
    for facing = 0, 3 do
      if neighboursMatch(absoluteBlocks(observe, facing), expect.neighbours) then found[facing] = true end
    end
    local screen, err, conf
    local emptyExpect = not next(expect.neighbours or {}) and not next(expect.peripherals or {})
    local aligned = found[bot.pos.h] and peripheralsMatch(observe, expect.peripherals) and observe.h == bot.pos.h
    if emptyExpect or aligned then
      conf = (not emptyExpect and distinctive(expect)) and "certain" or "suspect"
      screen = conf == "certain" and "Verified. This turtle is on the planned cell."
        or "Placement is not distinctive. Position stays suspect until a neighbour or F3 check."
    else
      record.attempts = record.attempts + 1
      if record.attempts >= 5 then
        record.used = true
        bot.state = "planned"
        bot.code = false
        effects[#effects + 1] = { op = "screen", text = "Code burned after 5 failed attempts.", error = "code burned" }
        bump(s)
        return finish("code burned")
      end
      local rotated = false
      for facing = 0, 3 do if found[facing] then rotated = true end end
      if rotated then
        err, screen = "wrong facing", "Wrong facing. Turn the turtle to match the plan and retry."
      else
        err, screen = "wrong cell", "Wrong cell. The blocks around this turtle do not match the plan."
      end
      effects[#effects + 1] = { op = "screen", text = screen, error = err }
      bump(s)
      return finish(err)
    end
    record.used = true
    bot.state = "claimed"
    bot.computerId = integer(event.computerId, 0, 2147483647) and event.computerId or false
    bot.pos = copy(bot.pos)
    bot.pos.conf = conf
    bot.pos.src = "neighbour"
    effects[#effects + 1] = { op = "screen", text = screen }
    effects[#effects + 1] = {
      op = "sync", computerId = bot.computerId, role = bot.role,
      settings = copy(bot.settings), pose = copy(bot.pos),
    }
    bump(s)
    return finish()
  end

  return hard("unknown plan event")
end

M.copy = copy
return M
