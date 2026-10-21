local function stubPath()
  local source = debug.getinfo(1, "S").source
  local dir = source:match("^@(.+/)problems%.lua$")
  if dir then return dir .. "lib/stubs/b2_dep.lua" end
  return "lib/stubs/b2_dep.lua"
end

local B1 = dofile(stubPath())

local M = {}

local KEYS = {
  compactInventory = { type = "boolean", default = false },
  filteredTrash = { type = "boolean", default = false },
  trashItems = { type = "ids", max = 64, default = {} },
  fuelReturnMargin = { type = "int", min = 0, max = 100000, default = 120 },
  unbreakableDetour = { type = "boolean", default = false },
  detourMaxCells = { type = "int", min = 1, max = "navMaxCells", default = 64 },
  avoidFluids = { type = "boolean", default = false },
  containFluids = { type = "boolean", default = false },
  maxFluidBlocks = { type = "int", min = 1, max = 64, default = 16 },
  fallingRetry = { type = "boolean", default = false },
  fallingMaxRetries = { type = "int", min = 1, max = 32, default = 8 },
  blockedRetry = { type = "boolean", default = false },
  blockedMaxRetries = { type = "int", min = 1, max = 32, default = 3 },
  rerouteBlocked = { type = "boolean", default = false },
  rerouteMaxCells = { type = "int", min = 1, max = "navMaxCells", default = 128 },
  reanchor = { type = "boolean", default = false },
  reanchorMaxAttempts = { type = "int", min = 1, max = 32, default = 3 },
  stuckBackoff = { type = "boolean", default = false },
  stuckMaxAttempts = { type = "int", min = 1, max = 32, default = 3 },
  stuckSkip = { type = "boolean", default = false },
}

local FALLING = {
  ["minecraft:gravel"] = true,
  ["minecraft:sand"] = true,
  ["minecraft:red_sand"] = true,
}

local SOURCE = { ["minecraft:lava"] = true, ["minecraft:water"] = true }
local FLOW = { ["minecraft:flowing_lava"] = true, ["minecraft:flowing_water"] = true }

local function integer(n)
  return type(n) == "number" and n == n and n % 1 == 0
end

local function namespaced(id)
  return type(id) == "string" and id == id:lower() and id:match("^[%a][%w_]*:[%a%d_/%.%-]+$") ~= nil
end

local function cellOf(cell, kind)
  if type(cell) ~= "table" or not integer(cell.x) or not integer(cell.y) or not integer(cell.z) then
    return nil
  end
  return { v = 1, x = cell.x, y = cell.y, z = cell.z, kind = kind }
end

function M.registry()
  local list = {}
  for key, spec in pairs(KEYS) do
    list[#list + 1] = {
      key = key, type = spec.type, default = spec.default, min = spec.min, max = spec.max,
    }
  end
  table.sort(list, function(a, b) return a.key < b.key end)
  return list
end

function M.parse(raw)
  if raw == nil then raw = {} end
  if type(raw) ~= "table" then return nil, "bad settings" end
  local nav = raw.navMaxCells
  if nav == nil then nav = 2048 end
  if not integer(nav) or nav < 1 or nav > 100000 then return nil, "navMaxCells" end
  local settings = { navMaxCells = nav }
  for key, spec in pairs(KEYS) do
    local value = raw[key]
    if value == nil then
      if spec.type == "ids" then value = {} else value = spec.default end
    end
    if spec.type == "boolean" then
      if type(value) ~= "boolean" then return nil, key end
    elseif spec.type == "int" then
      local max = spec.max == "navMaxCells" and nav or spec.max
      if not integer(value) or value < spec.min or value > max then return nil, key end
    elseif spec.type == "ids" then
      if type(value) ~= "table" then return nil, key end
      local list, seen = {}, 0
      for index, id in ipairs(value) do
        if not namespaced(id) then return nil, key end
        list[index] = id
        seen = seen + 1
      end
      local extra = 0
      for _ in pairs(value) do extra = extra + 1 end
      if extra ~= seen or seen > spec.max then return nil, key end
      value = list
    end
    settings[key] = value
  end
  for key in pairs(raw) do
    if key ~= "navMaxCells" and not KEYS[key] then return nil, "unknown setting" end
  end
  return settings
end

local function proposal(state, decision, kind, reason, attempts)
  return {
    state = state,
    decision = decision or false,
    kind = kind,
    reason = reason,
    attempts = attempts or 0,
    action = false,
    conf = false,
    mark = false,
    dig = false,
    move = false,
    enter = false,
  }
end

local function canCompact(slots)
  local totals = {}
  for index = 1, 16 do
    local slot = slots[index]
    if slot.count > 0 then
      local total = totals[slot.name] or { count = 0, slots = 0 }
      total.count = total.count + slot.count
      total.slots = total.slots + 1
      totals[slot.name] = total
    end
  end
  for _, total in pairs(totals) do
    local need = math.floor((total.count + 63) / 64)
    if need < total.slots then return true end
  end
  return false
end

local function trashable(slots, names)
  local allow = {}
  for _, name in ipairs(names) do allow[name] = true end
  for index = 1, 16 do
    local slot = slots[index]
    if slot.count > 0 and allow[slot.name] then return true end
  end
  return false
end

local function slotsOk(slots)
  if type(slots) ~= "table" then return false end
  for index = 1, 16 do
    local slot = slots[index]
    if type(slot) ~= "table" or not integer(slot.count) or slot.count < 0 or slot.count > 64 then
      return false
    end
    if slot.count > 0 and not namespaced(slot.name) then return false end
  end
  local extra = 0
  for _ in pairs(slots) do extra = extra + 1 end
  return extra == 16
end

local function attemptsOf(problem)
  local attempts = problem.attempts or 0
  if not integer(attempts) or attempts < 0 then return nil end
  return attempts
end

local handlers = {}

function handlers.full_inventory(problem, settings)
  if not slotsOk(problem.slots) then return nil, "bad inventory" end
  local free = 0
  for index = 1, 16 do
    if problem.slots[index].count == 0 then free = free + 1 end
  end
  if free > 0 then return proposal("clear", false, "none", "inventory has room", 0) end
  if settings.compactInventory and canCompact(problem.slots) then
    local result = proposal("compact", "retry", "inventory", "compact", 1)
    result.action = "compact"
    return result
  end
  if settings.filteredTrash and trashable(problem.slots, settings.trashItems) then
    local result = proposal("trash", "retry", "inventory", "trash", 1)
    result.action = "trash"
    return result
  end
  return proposal("return", "return", "move", "inventory full", 0)
end

function handlers.fuel(problem, settings, ctx)
  if problem.fuel == "unlimited" then return proposal("clear", false, "none", "unlimited fuel", 0) end
  if not integer(problem.fuel) or problem.fuel < 0 then return nil, "bad fuel" end
  if not integer(problem.leg) or problem.leg < 0 then return nil, "bad fuel" end
  if not integer(problem.home) or problem.home < 0 then return nil, "bad fuel" end
  local reserve = settings.fuelReturnMargin
  if ctx.lease and type(ctx.lease) == "table" and integer(ctx.lease.fuelReserve) and ctx.lease.fuelReserve > reserve then
    reserve = ctx.lease.fuelReserve
  end
  local need = problem.leg + problem.home + reserve
  if problem.fuel < need then
    local result = proposal("return", "return", "move", "fuel reserve", 0)
    result.need = need
    return result
  end
  local result = proposal("clear", false, "none", "fuel reserve", 0)
  result.need = need
  return result
end

function handlers.bedrock(problem, settings)
  local mark = cellOf(problem.cell, "unbreakable")
  if not mark then return nil, "bad cell" end
  local detour = problem.detour == nil and 1 or problem.detour
  if not integer(detour) or detour < 1 then return nil, "bad detour" end
  if settings.unbreakableDetour and detour <= settings.detourMaxCells then
    local result = proposal("reroute", "reroute", "mark", "bedrock", 0)
    result.mark = mark
    return result
  end
  return proposal("return", "return", "move", "bedrock", 0)
end

function handlers.fluid(problem, settings)
  local source = SOURCE[problem.name] == true
  local flow = FLOW[problem.name] == true
  if not source and not flow then return nil, "not a fluid" end
  if problem.source == false then source = false end
  if not integer(problem.placed) or problem.placed < 0 then return nil, "bad fluid" end
  if type(problem.hasBlock) ~= "boolean" then return nil, "bad fluid" end
  if settings.containFluids and source and problem.hasBlock and problem.placed < settings.maxFluidBlocks then
    local result = proposal("contain", "retry", "place", "contain fluid", 1)
    result.action = "contain"
    result.mark = cellOf(problem.cell, "fluid") or false
    return result
  end
  if settings.avoidFluids then
    local result = proposal("reroute", "reroute", "move", "avoid fluid", 0)
    result.mark = cellOf(problem.cell, "fluid") or false
    return result
  end
  return proposal("return", "return", "move", "fluid", 0)
end

function handlers.gravel(problem, settings)
  if not FALLING[problem.name] then return nil, "not falling" end
  local attempts = attemptsOf(problem)
  if not attempts then return nil, "bad attempts" end
  if settings.fallingRetry and attempts < settings.fallingMaxRetries then
    return proposal("retry", "retry", "dig", "falling", attempts + 1)
  end
  return proposal("return", "return", "move", "falling bound", attempts)
end

function handlers.mob(problem, settings)
  local attempts = attemptsOf(problem)
  if not attempts then return nil, "bad attempts" end
  local detour = problem.detour == nil and 1 or problem.detour
  if not integer(detour) or detour < 1 then return nil, "bad detour" end
  if settings.blockedRetry and attempts < settings.blockedMaxRetries then
    local result = proposal("retry", "retry", "work", "mob", attempts + 1)
    result.action = "attack"
    return result
  end
  if settings.rerouteBlocked and detour <= settings.rerouteMaxCells then
    return proposal("reroute", "reroute", "move", "mob", attempts)
  end
  return proposal("return", "return", "move", "mob", attempts)
end

local function reanchor(result, settings, attempts, conf)
  if settings.reanchor and attempts < settings.reanchorMaxAttempts then
    result.decision = "retry"
    result.action = "reanchor"
    result.kind = "anchor"
    result.attempts = attempts + 1
  end
  result.conf = conf
  result.state = conf
  return result
end

function handlers.dimension(problem, settings, ctx)
  if not namespaced(problem.dim) then return nil, "bad dimension" end
  local attempts = attemptsOf(problem)
  if not attempts then return nil, "bad attempts" end
  local changed = problem.dim ~= ctx.pose.dim
  local home = ctx.lease and type(ctx.lease) == "table" and ctx.lease.home
  if home and home.dim and home.dim ~= problem.dim then changed = true end
  if not changed then return proposal("clear", false, "none", "same dimension", attempts) end
  return reanchor(proposal("lost", "wait", "none", "dimension", attempts), settings, attempts, "lost")
end

function handlers.pickup(problem, settings)
  local attempts = attemptsOf(problem)
  if not attempts then return nil, "bad attempts" end
  if problem.fingerprint ~= "match" and problem.fingerprint ~= "mismatch" and problem.fingerprint ~= "unknown" then
    return nil, "bad fingerprint"
  end
  if type(problem.unresolved) ~= "boolean" then return nil, "bad pickup" end
  local conf = (problem.fingerprint == "match" and not problem.unresolved) and "suspect" or "lost"
  return reanchor(proposal(conf, "wait", "none", "pickup", attempts), settings, attempts, conf)
end

function handlers.stuck(problem, settings)
  local attempts = attemptsOf(problem)
  if not attempts then return nil, "bad attempts" end
  local mark = cellOf(problem.cell, "stuck")
  if not mark then return nil, "bad cell" end
  if settings.stuckBackoff and attempts < settings.stuckMaxAttempts then
    local result = proposal("backoff", "retry", "move", "stuck", attempts + 1)
    result.action = "backoff"
    return result
  end
  if settings.stuckSkip then
    local result = proposal("skip", "skip", "mark", "stuck", attempts)
    result.mark = mark
    return result
  end
  return proposal("return", "return", "move", "stuck", attempts)
end

local function poseOk(pose)
  if type(pose) ~= "table" or pose.v ~= 1 then return false end
  if pose.conf ~= "certain" and pose.conf ~= "suspect" and pose.conf ~= "lost" then return false end
  if type(pose.frame) ~= "string" or pose.frame == "" then return false end
  if not namespaced(pose.dim) then return false end
  if not integer(pose.x) or not integer(pose.y) or not integer(pose.z) then return false end
  if not integer(pose.h) or pose.h < 0 or pose.h > 3 then return false end
  return true
end

local function settle(result, state, decision, kind, reason)
  local conf = result.conf
  result.state = state
  result.decision = decision
  result.kind = kind
  result.action = false
  result.mark = false
  result.reason = reason
  result.conf = conf
end

local function newWork(result)
  if result.kind == "inventory" or result.kind == "anchor" or result.kind == "none" then return false end
  if result.decision == false or result.decision == "wait" or result.decision == "return" then return false end
  return true
end

local function workKind(kind)
  return kind == "dig" or kind == "work" or kind == "place" or kind == "mark"
end

local function clamp(result, ctx, lease, room)
  local problem = ctx.problem
  if problem.corridor and result.decision ~= false and result.decision ~= "return" and result.decision ~= "wait"
    and result.kind ~= "inventory" and result.kind ~= "anchor" then
    settle(result, "corridor", "return", "move", "corridor")
  end
  if room == "full" and result.decision then
    settle(result, "journal_full", "wait", "none", "journal full")
  elseif room == "home" and newWork(result) then
    settle(result, "journal_home", "return", "move", "journal budget")
  end
  local conf = result.conf or ctx.pose.conf
  if conf == "lost" and (result.kind == "move" or workKind(result.kind)) then
    settle(result, "lost", "wait", "none", "lost")
    if not result.conf then result.conf = "lost" end
  elseif conf == "suspect" and workKind(result.kind) then
    settle(result, "suspect", "wait", "none", "suspect")
    if not result.conf then result.conf = "suspect" end
  end
  if lease == "expired" or lease == "none" then
    if result.kind ~= "inventory" and result.kind ~= "anchor" and result.kind ~= "none" then
      settle(result, lease == "none" and "no_lease" or "expired", "wait", "none",
        lease == "none" and "no lease" or "expired lease")
    elseif result.state == "clear" then
      settle(result, lease == "none" and "no_lease" or "expired", "wait", "none",
        lease == "none" and "no lease" or "expired lease")
    end
  elseif lease == "return_only" then
    local lost = (result.conf or ctx.pose.conf) == "lost"
    if not lost and (workKind(result.kind) or (result.kind == "move" and result.decision ~= "return")) then
      settle(result, "return_only", "return", "move", "return only")
    elseif lost and (workKind(result.kind) or result.kind == "move") then
      settle(result, "lost", "wait", "none", "lost")
    end
  end
  return result
end

local function finish(result, code)
  result.v = 1
  result.code = code
  result.dig = result.kind == "dig"
  result.move = result.kind == "move" or result.decision == "reroute"
  result.enter = false
  result.blocksPath = code == "fluid"
  result.action = result.action or false
  result.conf = result.conf or false
  result.mark = result.mark or false
  result.entry = false
  result.journal = false
  result.attempts = result.attempts or 0
  return result
end

local function journalEntry(result, ctx)
  if not result.decision or not ctx.journal then return false end
  local cell = false
  if result.mark then
    cell = { x = result.mark.x, y = result.mark.y, z = result.mark.z }
  elseif type(ctx.problem.cell) == "table" then
    cell = { x = ctx.problem.cell.x, y = ctx.problem.cell.y, z = ctx.problem.cell.z }
  end
  local lease = ctx.journal.lease
  if ctx.lease and type(ctx.lease) == "table" and type(ctx.lease.id) == "string" then lease = ctx.lease.id end
  return {
    v = 1,
    seq = ctx.seq,
    lease = lease,
    at = ctx.now,
    frame = ctx.pose.frame,
    kind = "problem",
    phase = "intent",
    code = ctx.problem.code,
    attempts = result.attempts,
    decision = result.decision,
    cell = cell or nil,
  }
end

function M.decide(ctx)
  if type(ctx) ~= "table" then return nil, "bad context" end
  if not integer(ctx.now) then return nil, "bad time" end
  if not poseOk(ctx.pose) then return nil, "bad pose" end
  if type(ctx.problem) ~= "table" or type(ctx.problem.code) ~= "string" then return nil, "bad problem" end
  local settings, settingsErr = M.parse(ctx.settings or {})
  if not settings then return nil, settingsErr end
  local lease, leaseErr = B1.leaseStatus(ctx.lease, ctx.now)
  if not lease then return nil, leaseErr end
  local room, roomErr = B1.journalRoom(ctx.journal)
  if not room then return nil, roomErr end
  local handler = handlers[ctx.problem.code]
  if not handler then return nil, "unknown problem" end
  local result, err = handler(ctx.problem, settings, ctx)
  if not result then return nil, err end
  clamp(result, ctx, lease, room)
  finish(result, ctx.problem.code)
  local entry = journalEntry(result, ctx)
  if entry and room ~= "full" and room ~= "none" then
    local head, stored = B1.append(ctx.journal, entry)
    if not head then
      if stored ~= "journal full" then return nil, stored end
      if result.decision ~= "wait" then
        settle(result, "journal_full", "wait", "none", "journal full")
      end
      finish(result, ctx.problem.code)
      return result
    end
    result.journal = head
    result.entry = stored
  end
  return result
end

function M.jobLease(id, untilAt, home, fuelReserve)
  if type(id) ~= "string" or id == "" or not integer(untilAt) then return false end
  local lease = { v = 2, id = id, untilAt = untilAt }
  if type(home) == "table" and type(home.dim) == "string" then lease.home = { dim = home.dim } end
  if integer(fuelReserve) then lease.fuelReserve = fuelReserve end
  return lease
end

local function projectSettings(raw)
  local settings = {}
  if type(raw) == "table" then
    for _, spec in ipairs(M.registry()) do
      if raw[spec.key] ~= nil then settings[spec.key] = raw[spec.key] end
    end
    if raw.navMaxCells ~= nil then settings.navMaxCells = raw.navMaxCells end
  end
  return M.parse(settings)
end

local function problemsFrom(sight, attempts)
  local out = {}
  local function add(problem) out[#out + 1] = problem end
  if type(sight.dim) == "string" then
    add({ code = "dimension", dim = sight.dim, attempts = attempts.dimension or 0 })
  end
  if (sight.fingerprint == "match" or sight.fingerprint == "mismatch" or sight.fingerprint == "unknown")
    and type(sight.unresolved) == "boolean" then
    add({
      code = "pickup", fingerprint = sight.fingerprint, unresolved = sight.unresolved,
      attempts = attempts.pickup or 0,
    })
  end
  if sight.fuel ~= nil and sight.leg ~= nil and sight.home ~= nil then
    add({ code = "fuel", fuel = sight.fuel, leg = sight.leg, home = sight.home })
  end
  if type(sight.slots) == "table" then add({ code = "full_inventory", slots = sight.slots }) end
  local name = sight.blockName
  if name == "minecraft:lava" or name == "minecraft:water"
    or name == "minecraft:flowing_lava" or name == "minecraft:flowing_water" then
    add({
      code = "fluid", name = name, placed = sight.placed, hasBlock = sight.hasBlock,
      cell = sight.cell, source = sight.source,
    })
  end
  if name == "minecraft:bedrock" and type(sight.cell) == "table" then
    add({ code = "bedrock", cell = sight.cell, detour = sight.detour })
  end
  if FALLING[name] then add({ code = "gravel", name = name, attempts = attempts.gravel or 0 }) end
  if sight.moveError ~= nil and sight.moveError ~= false and sight.sameCell == true and type(sight.cell) == "table" then
    add({ code = "stuck", cell = sight.cell, attempts = attempts.stuck or 0, detour = sight.detour })
  elseif sight.moveError ~= nil and sight.moveError ~= false and sight.blockName == nil and sight.detected == false then
    add({ code = "mob", attempts = attempts.mob or 0, detour = sight.detour })
  end
  return out
end

local function clearResult()
  return {
    v = 1, code = false, state = "clear", decision = false, dig = false, move = false,
    enter = false, action = false, conf = false, mark = false, reason = false,
  }
end

local function apply(result, host, pose)
  if result.dig and (type(pose) ~= "table" or pose.conf ~= "certain") then
    return host.wait(result.reason, pose and pose.conf)
  end
  if result.decision == "return" then return host.goHome(result.reason) end
  if result.decision == "wait" or result.state == "lost" or result.state == "suspect" then
    return host.wait(result.reason, result.conf)
  end
  if result.decision == "reroute" or result.decision == "skip" then
    return host.mark(result.mark, result.decision, result.reason)
  end
  if result.decision == "retry" and result.dig then return host.dig(result) end
  if result.decision == "retry" then return host.retry(result.action, result) end
  if result.decision == false then return host.clear() end
  return false, "unhandled problem state"
end

function M.handle(input, host)
  if type(input) ~= "table" or type(host) ~= "table" then return nil, "bad problem" end
  local settings, settingsErr = projectSettings(input.settings)
  if not settings then return nil, settingsErr end
  local attempts = type(input.attempts) == "table" and input.attempts or {}
  local sight = type(input.sight) == "table" and input.sight or {}
  local result
  for _, problem in ipairs(problemsFrom(sight, attempts)) do
    local decided, err = M.decide({
      now = input.now, settings = settings, pose = input.pose, lease = input.lease,
      journal = false, problem = problem,
    })
    if not decided then return nil, err end
    if decided.state ~= "clear" then result = decided break end
  end
  if not result then
    result = clearResult()
    if type(input.pose) == "table" and input.pose.conf == "lost" then
      result = {
        v = 1, code = false, state = "lost", decision = "wait", dig = false, move = false,
        enter = false, action = false, conf = "lost", mark = false, reason = "lost",
      }
    end
  end
  apply(result, host, input.pose)
  return result
end

return M
