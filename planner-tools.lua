-- Full planner tools (plan item T2): Y slider, area drawing, every fixture kind,
-- bot roles, job areas, and dev toggles. Hosts are the pocket panel, the hub,
-- and the server. The flag defaults off.
--
-- planner-core.lua (T1) supplies mint, pos, style, and op names when it is present.
-- Until then lib/stubs/t2_dep.lua does. These hosts do not call transition:
-- that reducer is the one-chest MVP, and the tool set here is the full one.
-- The hub sends plans to a server. Hub-only planning is S1.
-- Dev-toggle names are a stand-in list. W1's settings registry replaces them.
-- Ghost markers are data for the AR owner (A1). This module does not draw them.

local M = {}

local function existing(path)
  if type(fs) == "table" and type(fs.exists) == "function" then return fs.exists(path) end
  if type(io) == "table" and type(io.open) == "function" then
    local f = io.open(path, "r")
    if f then f:close() return true end
  end
  return false
end

local function loadCore()
  if existing("planner-core.lua") then
    local ok, core = pcall(dofile, "planner-core.lua")
    if ok and type(core) == "table" and type(core.mint) == "function"
      and type(core.pos) == "function" and type(core.style) == "function" then
      return core
    end
  end
  return dofile("lib/stubs/t2_dep.lua")
end

local core = assert(loadCore(), "planner core missing")
assert(type(core.mint) == "function" and type(core.pos) == "function" and type(core.style) == "function",
  "planner core interface")

local OPS = {
  put = (core.ops and core.ops.put) or "plan-put",
  intent = (core.ops and core.ops.intent) or "plan-intent",
  code = (core.ops and core.ops.code) or "plan-code",
  claim = (core.ops and core.ops.claim) or "plan-claim",
}

-- Planner copy codes last 15 minutes. The 5-try burn stays with enrolment (I1).
local CODE_TTL = 900000
local AREA_CELLS = 4096

local ROLES = { "miner", "lumber", "farmer", "lava", "builder", "buddy", "roomsorter", "factory", "store", "sorter" }
local FIXTURES = { "chest", "dropoff", "charger", "furnace" }
local ROLE_SET, FIXTURE_SET = {}, {}
for _, name in ipairs(ROLES) do ROLE_SET[name] = true end
for _, name in ipairs(FIXTURES) do FIXTURE_SET[name] = true end

local SIDES = { front = true, back = true, left = true, right = true, top = true, bottom = true }
local BLOCK = { chest = "minecraft:chest", dropoff = "minecraft:chest", furnace = "minecraft:furnace" }
local PERIPH = { chest = "inventory", dropoff = "inventory", furnace = "inventory" }
local FIX_GLYPH = { chest = "C", dropoff = "D", charger = "G", furnace = "F" }
local BOT_GLYPH = {
  miner = "M", lumber = "L", farmer = "R", lava = "V", builder = "B",
  buddy = "U", roomsorter = "S", factory = "Y", store = "T", sorter = "O",
}
local SIDE_NAME = { [0] = "front", "right", "back", "left" }
local FACING_NAME = { [0] = "N", "E", "S", "W" }

-- Boolean flags named in the fleet contract. Defaults stay off. W1 replaces this list.
local TOGGLE_ORDER = { "offlineAutonomy", "trash", "fluidPlacement" }
local TOGGLE_DEFAULT = { offlineAutonomy = false, trash = false, fluidPlacement = false }

local BUTTONS = {
  { id = "ydn", label = "Y-" }, { id = "yup", label = "Y+" }, { id = "area", label = "Ar" },
  { id = "fix", label = "Fx" }, { id = "bot", label = "Bt" }, { id = "job", label = "Jb" },
  { id = "tog", label = "Tg" }, { id = "ok", label = "Ok" }, { id = "undo", label = "Un" },
}

-- Pocket 26x20, computer 51x19, monitor scale 1 on an 8x6 block screen 164x81.
M.screens = {
  panel = { w = 26, h = 20 },
  hub = { w = 51, h = 19 },
  server = { w = 164, h = 81 },
}

local function integer(n, lo, hi)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= lo and n <= hi
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[copy(k)] = copy(x) end
  return out
end

local function idNumber(id)
  return tonumber(tostring(id):match(":(%d+)$")) or 0
end

local function sortIds(map)
  local ids = {}
  for id in pairs(map) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b)
    local na, nb = idNumber(a), idNumber(b)
    if na == nb then return tostring(a) < tostring(b) end
    return na < nb
  end)
  return ids
end

local function count(map)
  local n = 0
  for _ in pairs(map) do n = n + 1 end
  return n
end

local function nextIn(list, current)
  for i, name in ipairs(list) do
    if name == current then return list[i % #list + 1] end
  end
  return list[1]
end

function M.config(raw)
  if raw == nil and type(fs) == "table" and fs.exists and fs.exists("planner.cfg") and fs.open then
    local h = fs.open("planner.cfg", "r")
    if h then
      local body = h.readAll()
      h.close()
      if textutils and textutils.unserialize then
        local ok, parsed = pcall(textutils.unserialize, body)
        if ok and type(parsed) == "table" then raw = parsed end
      end
    end
  end
  if type(raw) ~= "table" then raw = {} end
  local server = false
  if integer(raw.server, 0, 2147483647) then server = raw.server end
  return { enabled = raw.enabled == nil or raw.enabled == true, server = server }
end

function M.clip(list, cap)
  if type(list) ~= "table" then return {} end
  if type(cap) ~= "number" or cap < 0 then cap = 128 end
  cap = math.floor(cap)
  local n = #list
  if n > cap then n = cap end
  local out = {}
  for i = 1, n do out[i] = list[i] end
  return out
end

local function planRecord(session)
  local plan = session.data.plan
  local areas = {}
  for i, area in ipairs(plan.areas) do areas[i] = copy(area) end
  table.sort(areas, function(a, b) return idNumber(a.id) < idNumber(b.id) end)
  return {
    v = 1, id = plan.id, frame = plan.frame, dim = plan.dim, y = plan.y, name = plan.name,
    rev = plan.rev, areas = areas, fixtures = sortIds(session.data.fixtures), bots = sortIds(session.data.bots),
  }
end

local function records(session)
  if not session.enabled then return { plan = false, fixtures = {}, bots = {} } end
  local fixtures, bots = {}, {}
  for _, id in ipairs(sortIds(session.data.fixtures)) do
    fixtures[#fixtures + 1] = copy(session.data.fixtures[id])
  end
  for _, id in ipairs(sortIds(session.data.bots)) do
    bots[#bots + 1] = copy(session.data.bots[id])
  end
  return { plan = planRecord(session), fixtures = fixtures, bots = bots }
end

local function route(session, list)
  local to = session.server or false
  for i = 1, #list do
    local e = list[i]
    e.to = to
    e.localApply = session.host == "server"
    if session.host ~= "server" and not to then e.discover = "fleetserver" end
  end
  return list
end

local function reject(session, code)
  session.ui.message = code
  return session, route(session, { { op = "reject", code = code } })
end

local function ui(session, message)
  session.ui.message = message or "ok"
  return session, route(session, { { op = "ui" } })
end

local function take(data)
  return { counter = data.counter, plan = copy(data.plan), fixtures = copy(data.fixtures), bots = copy(data.bots) }
end

local function restore(session, snap)
  session.data.counter = snap.counter
  session.data.plan = snap.plan
  session.data.fixtures = snap.fixtures
  session.data.bots = snap.bots
end

local function commit(session, extra)
  session.data.plan.rev = session.data.plan.rev + 1
  local effects = { { op = OPS.put, plan = planRecord(session) } }
  for i = 1, #extra do effects[#effects + 1] = extra[i] end
  session.ui.message = "ok"
  return session, route(session, effects)
end

local function change(session, fn)
  local snap = take(session.data)
  local extra, code = fn()
  if code == "same" then
    restore(session, snap)
    session.ui.message = "same"
    return session, route(session, { { op = "same" } })
  end
  if code then
    restore(session, snap)
    return reject(session, code)
  end
  session.data.undo[#session.data.undo + 1] = snap
  if #session.data.undo > 32 then table.remove(session.data.undo, 1) end
  return commit(session, extra or {})
end

local function makePos(session, x, z, h)
  local plan = session.data.plan
  return core.pos({
    x = x, y = plan.y, z = z, h = h or 0, frame = plan.frame, yAbs = session.yAbs, dim = plan.dim,
    conf = plan.frame == "abs" and "certain" or "suspect", src = "typed", anchoredAt = 0,
  })
end

local function bounds(from, to)
  if type(from) ~= "table" or type(to) ~= "table" then return nil, nil, "bad_area" end
  if not integer(from.x, -30000000, 30000000) or not integer(from.z, -30000000, 30000000)
    or not integer(to.x, -30000000, 30000000) or not integer(to.z, -30000000, 30000000) then
    return nil, nil, "bad_area"
  end
  local x1, x2 = math.min(from.x, to.x), math.max(from.x, to.x)
  local z1, z2 = math.min(from.z, to.z), math.max(from.z, to.z)
  if (x2 - x1 + 1) * (z2 - z1 + 1) > AREA_CELLS then return nil, nil, "area_limit" end
  return { x = x1, z = z1 }, { x = x2, z = z2 }
end

local function findBot(session, x, z)
  for _, bot in pairs(session.data.bots) do
    if bot.pos.x == x and bot.pos.z == z then return bot end
  end
end

local function findFixture(session, x, z)
  for _, fix in pairs(session.data.fixtures) do
    if fix.pos.x == x and fix.pos.z == z then return fix end
  end
end

local function targetBot(session, at)
  if type(at) == "table" and integer(at.x, -30000000, 30000000) and integer(at.z, -30000000, 30000000) then
    return findBot(session, at.x, at.z)
  end
  if session.ui.selected then return session.data.bots[session.ui.selected] end
end

local function blocked(session, x, z)
  return session.world and session.world(x, session.data.plan.y, z) == "occupied"
end

local function intentOf(entity)
  return { op = OPS.intent, id = entity.id, pos = copy(entity.pos), hold = "intent" }
end

local function relink(session)
  local fixIds = sortIds(session.data.fixtures)
  for _, bot in pairs(session.data.bots) do
    local neighbours, peripherals = {}, {}
    for _, id in ipairs(fixIds) do
      local fix = session.data.fixtures[id]
      if fix.pos.y == bot.pos.y then
        local dx, dz = fix.pos.x - bot.pos.x, fix.pos.z - bot.pos.z
        local dir
        if dx == 0 and dz == -1 then dir = 0
        elseif dx == 1 and dz == 0 then dir = 1
        elseif dx == 0 and dz == 1 then dir = 2
        elseif dx == -1 and dz == 0 then dir = 3 end
        if dir and BLOCK[fix.kind] then neighbours[dir] = BLOCK[fix.kind] end
        if dir and PERIPH[fix.kind] then peripherals[SIDE_NAME[(dir - bot.pos.h) % 4]] = PERIPH[fix.kind] end
      end
    end
    bot.expect = { neighbours = neighbours, peripherals = peripherals }
  end
end

local function setLevel(session, y)
  if not integer(y, -2048, 2048) then return nil, "bad_level" end
  if y == session.data.plan.y then return nil, "same" end
  session.data.plan.y = y
  for _, area in ipairs(session.data.plan.areas) do
    area.min.y, area.max.y = y, y
  end
  for _, fix in pairs(session.data.fixtures) do fix.pos.y = y end
  for _, bot in pairs(session.data.bots) do
    bot.pos.y = y
    if bot.jobArea then bot.jobArea.min.y, bot.jobArea.max.y = y, y end
  end
  local extra = {}
  for _, id in ipairs(sortIds(session.data.fixtures)) do
    extra[#extra + 1] = intentOf(session.data.fixtures[id])
  end
  for _, id in ipairs(sortIds(session.data.bots)) do
    extra[#extra + 1] = intentOf(session.data.bots[id])
  end
  return extra
end

local function addArea(session, from, to)
  local min, max, code = bounds(from, to)
  if not min then return nil, code end
  for _, area in ipairs(session.data.plan.areas) do
    if area.kind == "base" and area.min.x == min.x and area.min.z == min.z
      and area.max.x == max.x and area.max.z == max.z then
      return nil, "same"
    end
  end
  if #session.data.plan.areas >= 32 then return nil, "area_cap" end
  local id, counter = core.mint(session.data.origin, session.data.counter)
  if not id then return nil, counter end
  session.data.counter = counter
  local pmin, errMin = makePos(session, min.x, min.z, 0)
  local pmax, errMax = makePos(session, max.x, max.z, 0)
  if not pmin or not pmax then return nil, errMin or errMax or "bad_pos" end
  session.data.plan.areas[#session.data.plan.areas + 1] = { id = id, kind = "base", min = pmin, max = pmax }
  return {}
end

local function placeFixture(session, kind, at, side)
  if not FIXTURE_SET[kind] then return nil, "bad_fixture" end
  side = side or "front"
  if not SIDES[side] then return nil, "bad_side" end
  if type(at) ~= "table" or not integer(at.x, -30000000, 30000000) or not integer(at.z, -30000000, 30000000) then
    return nil, "bad_pos"
  end
  if blocked(session, at.x, at.z) then return nil, "occupied" end
  if findBot(session, at.x, at.z) then return nil, "cell_taken" end
  local existing = findFixture(session, at.x, at.z)
  if existing then
    if existing.kind == kind and existing.side == side then return nil, "same" end
    existing.kind, existing.side = kind, side
    relink(session)
    return { intentOf(existing) }
  end
  if count(session.data.fixtures) >= 64 then return nil, "fixture_cap" end
  local id, counter = core.mint(session.data.origin, session.data.counter)
  if not id then return nil, counter end
  session.data.counter = counter
  local pos, err = makePos(session, at.x, at.z, 0)
  if not pos then return nil, err or "bad_pos" end
  local fix = {
    v = 1, id = id, plan = session.data.plan.id, kind = kind, pos = pos, side = side,
    state = "planned", layoutId = false,
  }
  session.data.fixtures[id] = fix
  relink(session)
  return { intentOf(fix) }
end

local function placeBot(session, role, at, h)
  if not ROLE_SET[role] then return nil, "bad_role" end
  if h == nil then h = 0 end
  if not integer(h, 0, 3) then return nil, "bad_facing" end
  if type(at) ~= "table" or not integer(at.x, -30000000, 30000000) or not integer(at.z, -30000000, 30000000) then
    return nil, "bad_pos"
  end
  if blocked(session, at.x, at.z) then return nil, "occupied" end
  if findFixture(session, at.x, at.z) then return nil, "cell_taken" end
  local existing = findBot(session, at.x, at.z)
  if existing then
    if existing.role == role and existing.pos.h == h then return nil, "same" end
    existing.role, existing.pos.h = role, h
    session.ui.selected = existing.id
    relink(session)
    return { intentOf(existing) }
  end
  if count(session.data.bots) >= 32 then return nil, "bot_cap" end
  local id, counter = core.mint(session.data.origin, session.data.counter)
  if not id then return nil, counter end
  session.data.counter = counter
  local pos, err = makePos(session, at.x, at.z, h)
  if not pos then return nil, err or "bad_pos" end
  local bot = {
    v = 1, id = id, plan = session.data.plan.id, role = role, pos = pos,
    settings = { revision = session.settingsRevision, overrides = {} }, devToggles = {},
    jobArea = false, expect = { neighbours = {}, peripherals = {} },
    state = "planned", code = false, computerId = false,
  }
  session.data.bots[id] = bot
  session.ui.selected = id
  session.ui.role = role
  session.ui.facing = h
  relink(session)
  return { intentOf(bot) }
end

local function setJob(session, at, from, to)
  local bot = targetBot(session, at)
  if not bot then return nil, "no_bot" end
  local min, max, code = bounds(from, to)
  if not min then return nil, code end
  local pmin, errMin = makePos(session, min.x, min.z, 0)
  local pmax, errMax = makePos(session, max.x, max.z, 0)
  if not pmin or not pmax then return nil, errMin or errMax or "bad_pos" end
  if bot.jobArea and bot.jobArea.min.x == pmin.x and bot.jobArea.min.z == pmin.z
    and bot.jobArea.max.x == pmax.x and bot.jobArea.max.z == pmax.z then
    return nil, "same"
  end
  bot.jobArea = { min = pmin, max = pmax }
  session.ui.selected = bot.id
  return {}
end

local function flipToggle(session, at, key)
  if TOGGLE_DEFAULT[key] == nil then return nil, "bad_toggle" end
  local bot = targetBot(session, at)
  if not bot then return nil, "no_bot" end
  local current = bot.devToggles[key]
  if current == nil then current = TOGGLE_DEFAULT[key] end
  local toggles = copy(bot.devToggles)
  local value = not current
  if value == TOGGLE_DEFAULT[key] then toggles[key] = nil else toggles[key] = value end
  bot.devToggles = toggles
  bot.settings = { revision = session.settingsRevision, overrides = copy(toggles) }
  session.ui.selected = bot.id
  return {}
end

local function issue(session, at)
  local bot = targetBot(session, at)
  if not bot then return nil, "no_bot" end
  if bot.state ~= "planned" then return nil, "already_issued" end
  bot.state = "code-issued"
  session.ui.selected = bot.id
  return { { op = OPS.code, bot = bot.id, planBot = bot.id, ttl = CODE_TTL } }
end

local function doUndo(session)
  local snap = table.remove(session.data.undo)
  if not snap then return reject(session, "nothing") end
  restore(session, snap)
  if session.ui.selected and not session.data.bots[session.ui.selected] then session.ui.selected = nil end
  session.ui.corner = nil
  session.ui.message = "undo"
  return session, route(session, { { op = OPS.put, plan = planRecord(session) } })
end

local function doAnchor(session)
  if session.data.plan.frame == "abs" then return reject(session, "already_abs") end
  session.ui.message = "anchor"
  return session, route(session, { { op = "frame-merge", frame = session.data.plan.frame } })
end

local function apply(session, step)
  if not session.enabled then return reject(session, "disabled") end
  if type(step) ~= "table" then return reject(session, "bad_event") end
  if step.t == "level" then return change(session, function() return setLevel(session, step.y) end)
  elseif step.t == "draw" then
    if step.kind ~= nil and step.kind ~= "base" then return reject(session, "bad_area") end
    return change(session, function() return addArea(session, step.from, step.to) end)
  elseif step.t == "place" and step.kind == "bot" then
    return change(session, function() return placeBot(session, step.role, step.at, step.h) end)
  elseif step.t == "place" then
    return change(session, function() return placeFixture(session, step.kind, step.at, step.side) end)
  elseif step.t == "job" then
    return change(session, function() return setJob(session, step.bot or step.at, step.from, step.to) end)
  elseif step.t == "toggle" then
    return change(session, function() return flipToggle(session, step.bot or step.at, step.key) end)
  elseif step.t == "confirm" then
    return change(session, function() return issue(session, step.bot or step.at) end)
  elseif step.t == "undo" then return doUndo(session)
  elseif step.t == "anchor" then return doAnchor(session)
  else return reject(session, "bad_event") end
end

local function layout(session)
  local w, h = session.screen.w, session.screen.h
  local title = (session.host == "server" and h >= 24) and 1 or 0
  local tools = 1 + title
  local buttons, x = {}, 1
  for _, b in ipairs(BUTTONS) do
    if not (b.id == "undo" and w < 27) and x + 1 <= w then
      buttons[#buttons + 1] = { id = b.id, label = b.label, x = x, x2 = x + 1, y = tools }
      x = x + 3
    end
  end
  return {
    title = title == 1 and 1 or false, tools = tools,
    map = { x = 1, y = tools + 1, w = w, h = h - title - 2 }, status = h, buttons = buttons,
  }
end

local function paint(w, text, fg, bg)
  text = tostring(text or "")
  if #text > w then text = text:sub(1, w) end
  if #text < w then text = text .. string.rep(" ", w - #text) end
  return { text = text, fg = string.rep(fg or "0", w), bg = string.rep(bg or "f", w) }
end

local function cellGlyph(session, x, z)
  local bot = findBot(session, x, z)
  if bot then return BOT_GLYPH[bot.role] or "B", "2" end
  local fix = findFixture(session, x, z)
  if fix then return FIX_GLYPH[fix.kind] or "C", "2" end
  local kind = "unknown"
  if session.world then
    local got = session.world(x, session.data.plan.y, z)
    if core.style(got) then kind = got end
  end
  local style = core.style(kind)
  return style.glyph, style.blit
end

local function render(session)
  local w, h = session.screen.w, session.screen.h
  if not session.enabled then
    local rows = {}
    for i = 1, h do rows[i] = paint(w, i == 1 and "Full planner is off" or "", "8", "f") end
    return rows
  end
  local L = layout(session)
  local plan = session.data.plan
  local rows = {}
  if L.title then rows[L.title] = paint(w, "Planner " .. plan.name .. " y=" .. plan.y, "0", "1") end
  local text, fg, bg = {}, {}, {}
  for i = 1, w do text[i], fg[i], bg[i] = " ", "0", "7" end
  for _, b in ipairs(L.buttons) do
    local active = (b.id == "area" and session.ui.tool == "area" and session.ui.page == "map")
      or (b.id == "fix" and session.ui.tool == "fixture")
      or (b.id == "bot" and session.ui.tool == "bot")
      or (b.id == "job" and session.ui.tool == "job")
      or (b.id == "tog" and session.ui.page == "toggles")
    text[b.x], text[b.x + 1] = b.label:sub(1, 1), b.label:sub(2, 2)
    if active then bg[b.x], bg[b.x + 1] = "b", "b" end
  end
  rows[L.tools] = { text = table.concat(text), fg = table.concat(fg), bg = table.concat(bg) }
  local map = L.map
  if session.ui.page == "toggles" then
    local bot = session.ui.selected and session.data.bots[session.ui.selected]
    for row = 0, map.h - 1 do
      local key = TOGGLE_ORDER[row + 1]
      local line = ""
      if key then
        local on = bot and bot.devToggles[key]
        if on == nil then on = TOGGLE_DEFAULT[key] end
        line = key .. (on and " on" or " off")
      end
      rows[map.y + row] = paint(w, line, "0", "f")
    end
  else
    for row = 0, map.h - 1 do
      local chars, colours, backs = {}, {}, {}
      for col = 0, map.w - 1 do
        local glyph, blit = cellGlyph(session, session.ui.cam.x + col, session.ui.cam.z + row)
        chars[col + 1], colours[col + 1], backs[col + 1] = glyph, blit, "f"
      end
      rows[map.y + row] = { text = table.concat(chars), fg = table.concat(colours), bg = table.concat(backs) }
    end
  end
  local detail = session.ui.tool == "fixture" and session.ui.fixtureKind or session.ui.role
  rows[L.status] = paint(w, string.format("y=%d %s %s %s %s", plan.y, session.ui.tool, detail,
    FACING_NAME[session.ui.facing] or "?", session.ui.message or ""), "0", "f")
  return rows
end

local function buttonAt(L, x, y)
  if y ~= L.tools then return nil end
  for _, b in ipairs(L.buttons) do
    if x >= b.x and x <= b.x2 then return b.id end
  end
end

local function onButton(session, id)
  if id == "ydn" then return change(session, function() return setLevel(session, session.data.plan.y - 1) end) end
  if id == "yup" then return change(session, function() return setLevel(session, session.data.plan.y + 1) end) end
  if id == "ok" then return change(session, function() return issue(session) end) end
  if id == "undo" then return doUndo(session) end
  session.ui.corner = nil
  session.ui.page = "map"
  if id == "area" then session.ui.tool = "area"
  elseif id == "fix" then
    if session.ui.tool == "fixture" then session.ui.fixtureKind = nextIn(FIXTURES, session.ui.fixtureKind)
    else session.ui.tool = "fixture" end
  elseif id == "bot" then session.ui.tool = "bot"
  elseif id == "job" then session.ui.tool = "job"
  elseif id == "tog" then session.ui.page = "toggles" end
  return ui(session, id)
end

local function onCell(session, x, z)
  local tool = session.ui.tool
  local bot = findBot(session, x, z)
  if tool == "area" or tool == "job" then
    if tool == "job" and bot and not session.ui.corner then
      session.ui.selected = bot.id
      return ui(session, "bot")
    end
    if not session.ui.corner then
      session.ui.corner = { x = x, z = z }
      return ui(session, "corner")
    end
    local from = session.ui.corner
    session.ui.corner = nil
    if tool == "area" then return change(session, function() return addArea(session, from, { x = x, z = z }) end) end
    return change(session, function() return setJob(session, nil, from, { x = x, z = z }) end)
  end
  if tool == "fixture" then
    return change(session, function()
      return placeFixture(session, session.ui.fixtureKind, { x = x, z = z }, "front")
    end)
  end
  if tool == "bot" then
    if bot then
      session.ui.selected = bot.id
      return ui(session, "bot")
    end
    return change(session, function()
      return placeBot(session, session.ui.role, { x = x, z = z }, session.ui.facing)
    end)
  end
  return ui(session, "none")
end

local function onTouch(session, x, y)
  if not integer(x, 1, 100000) or not integer(y, 1, 100000) then return reject(session, "bad_event") end
  local L = layout(session)
  local button = buttonAt(L, x, y)
  if button then return onButton(session, button) end
  if session.ui.page == "toggles" then
    local index = y - L.map.y + 1
    local key = TOGGLE_ORDER[index]
    if not key or x < L.map.x or x >= L.map.x + L.map.w then return ui(session, "none") end
    return change(session, function() return flipToggle(session, nil, key) end)
  end
  if y < L.map.y or y >= L.map.y + L.map.h or x < L.map.x or x >= L.map.x + L.map.w then
    return ui(session, "none")
  end
  return onCell(session, session.ui.cam.x + (x - L.map.x), session.ui.cam.z + (y - L.map.y))
end

local function onChar(session, ch)
  if ch == "+" or ch == "=" then
    return change(session, function() return setLevel(session, session.data.plan.y + 1) end)
  elseif ch == "-" then
    return change(session, function() return setLevel(session, session.data.plan.y - 1) end)
  elseif ch == "u" then return doUndo(session)
  elseif ch == "a" or ch == "f" or ch == "b" or ch == "r" or ch == "h" or ch == "j" or ch == "t" or ch == "m" then
    session.ui.corner = nil
    if ch ~= "t" then session.ui.page = "map" end
    if ch == "a" then session.ui.tool = "area"
    elseif ch == "f" then
      if session.ui.tool ~= "fixture" then session.ui.tool = "fixture"
      else session.ui.fixtureKind = nextIn(FIXTURES, session.ui.fixtureKind) end
    elseif ch == "b" then session.ui.tool = "bot"
    elseif ch == "r" then
      session.ui.tool = "bot"
      session.ui.role = nextIn(ROLES, session.ui.role)
    elseif ch == "h" then
      session.ui.tool = "bot"
      session.ui.facing = (session.ui.facing + 1) % 4
    elseif ch == "j" then session.ui.tool = "job"
    elseif ch == "t" then session.ui.page = "toggles"
    end
    return ui(session, ch)
  end
  return reject(session, "bad_event")
end

local function onKey(session, key)
  if key == "enter" then return change(session, function() return issue(session) end) end
  if key == "backspace" then return doUndo(session) end
  if key == "left" then session.ui.cam.x = session.ui.cam.x - 1
  elseif key == "right" then session.ui.cam.x = session.ui.cam.x + 1
  elseif key == "up" then session.ui.cam.z = session.ui.cam.z - 1
  elseif key == "down" then session.ui.cam.z = session.ui.cam.z + 1
  else return reject(session, "bad_event") end
  return ui(session, "pan")
end

local function input(session, ev)
  if not session.enabled then return reject(session, "disabled") end
  if type(ev) ~= "table" then return reject(session, "bad_event") end
  if ev.t == "touch" or ev.t == "mouse_click" or ev.t == "monitor_touch" then return onTouch(session, ev.x, ev.y) end
  if ev.t == "char" then return onChar(session, ev.ch) end
  if ev.t == "key" then return onKey(session, ev.key) end
  -- One slider commit. The + and - keys step by a single level; a scripted level is one revision.
  if ev.t == "level" then return change(session, function() return setLevel(session, ev.y) end) end
  return reject(session, "bad_event")
end

local function copySession(session)
  return {
    enabled = session.enabled, host = session.host, server = session.server, yAbs = session.yAbs,
    settingsRevision = session.settingsRevision, world = session.world,
    screen = { w = session.screen.w, h = session.screen.h },
    ui = copy(session.ui), data = copy(session.data),
  }
end

local function screenOf(session, x, z)
  local map = layout(session).map
  local sx = map.x + (x - session.ui.cam.x)
  local sy = map.y + (z - session.ui.cam.z)
  if sx < map.x or sy < map.y or sx >= map.x + map.w or sy >= map.y + map.h then return nil end
  return sx, sy
end

local function gesture(session, step)
  if type(step) ~= "table" then error("bad gesture") end
  local sim = copySession(session)
  local events = {}
  local function push(ev)
    local effects
    sim, effects = input(sim, ev)
    events[#events + 1] = ev
    if effects[1] and effects[1].op == "reject" then
      error("gesture " .. tostring(step.t) .. " " .. tostring(effects[1].code))
    end
  end
  local function touch(x, z)
    local guard = 0
    while not screenOf(sim, x, z) do
      guard = guard + 1
      if guard > 400 then error("pan") end
      local map = layout(sim).map
      local sx = map.x + (x - sim.ui.cam.x)
      local sy = map.y + (z - sim.ui.cam.z)
      local key = "down"
      if sx < map.x then key = "left"
      elseif sx >= map.x + map.w then key = "right"
      elseif sy < map.y then key = "up" end
      push({ t = "key", key = key })
    end
    local sx, sy = screenOf(sim, x, z)
    push({ t = "touch", x = sx, y = sy })
  end
  if step.t == "level" then
    if not integer(step.y, -2048, 2048) then error("level") end
    push({ t = "level", y = step.y })
  elseif step.t == "draw" then
    if sim.ui.page ~= "map" or sim.ui.tool ~= "area" then push({ t = "char", ch = "a" }) end
    touch(step.from.x, step.from.z)
    touch(step.to.x, step.to.z)
  elseif step.t == "place" and step.kind == "bot" then
    if sim.ui.page ~= "map" or sim.ui.tool ~= "bot" then push({ t = "char", ch = "b" }) end
    local guard = 0
    while sim.ui.role ~= step.role do
      push({ t = "char", ch = "r" })
      guard = guard + 1
      if guard > 16 then error("role cycle") end
    end
    guard = 0
    local h = step.h or 0
    while sim.ui.facing ~= h do
      push({ t = "char", ch = "h" })
      guard = guard + 1
      if guard > 6 then error("facing cycle") end
    end
    touch(step.at.x, step.at.z)
  elseif step.t == "place" then
    local guard = 0
    while sim.ui.page ~= "map" or sim.ui.tool ~= "fixture" or sim.ui.fixtureKind ~= step.kind do
      push({ t = "char", ch = "f" })
      guard = guard + 1
      if guard > 12 then error("fixture cycle") end
    end
    touch(step.at.x, step.at.z)
  elseif step.t == "job" then
    if sim.ui.page ~= "map" or sim.ui.tool ~= "bot" then push({ t = "char", ch = "b" }) end
    touch(step.bot.x, step.bot.z)
    push({ t = "char", ch = "j" })
    touch(step.from.x, step.from.z)
    touch(step.to.x, step.to.z)
  elseif step.t == "toggle" then
    if sim.ui.page ~= "map" or sim.ui.tool ~= "bot" then push({ t = "char", ch = "b" }) end
    touch(step.bot.x, step.bot.z)
    push({ t = "char", ch = "t" })
    local index
    for i, key in ipairs(TOGGLE_ORDER) do if key == step.key then index = i end end
    if not index then error("toggle") end
    local map = layout(sim).map
    push({ t = "touch", x = 1, y = map.y + index - 1 })
    push({ t = "char", ch = "m" })
  elseif step.t == "confirm" then
    if sim.ui.page ~= "map" then push({ t = "char", ch = "m" }) end
    if sim.ui.tool ~= "bot" then push({ t = "char", ch = "b" }) end
    touch(step.bot.x, step.bot.z)
    push({ t = "key", key = "enter" })
  else error("no gesture for " .. tostring(step.t)) end
  return events
end

local function ghosts(session)
  if not session.enabled then return {} end
  local plan = session.data.plan
  local list = {}
  local function add(marker, y)
    if type(y) == "number" and math.abs(y - plan.y) <= 1 then list[#list + 1] = marker end
  end
  for _, id in ipairs(sortIds(session.data.bots)) do
    local bot = session.data.bots[id]
    add({ id = "bot:" .. id, kind = "label", x = bot.pos.x, y = bot.pos.y, z = bot.pos.z, label = bot.role }, bot.pos.y)
  end
  for _, id in ipairs(sortIds(session.data.fixtures)) do
    local fix = session.data.fixtures[id]
    local marker = {
      id = "fix:" .. id, kind = BLOCK[fix.kind] and "item" or "label",
      x = fix.pos.x, y = fix.pos.y, z = fix.pos.z, label = fix.kind,
    }
    if BLOCK[fix.kind] then marker.item = BLOCK[fix.kind] end
    add(marker, fix.pos.y)
  end
  for _, area in ipairs(plan.areas) do
    add({
      id = "area:" .. area.id, kind = "box", x = area.min.x, y = area.min.y, z = area.min.z,
      w = area.max.x - area.min.x + 1, h = 1, d = area.max.z - area.min.z + 1, label = area.kind,
    }, area.min.y)
  end
  list = M.clip(list, 128)
  if existing("planner-ar.lua") then
    local ok, ar = pcall(dofile, "planner-ar.lua")
    if ok and type(ar) == "table" and type(ar.markers) == "function" then pcall(ar.markers, list) end
  end
  return list
end

local function draw(session, term)
  local rows = render(session)
  if term and term.setCursorPos then
    if term.clear then term.clear() end
    if term.setBackgroundColor and colors then term.setBackgroundColor(colors.black) end
    for i, row in ipairs(rows) do
      term.setCursorPos(1, i)
      if term.blit then term.blit(row.text, row.fg, row.bg)
      elseif term.write then term.write(row.text) end
    end
  end
  return rows
end

function M.fromCC(ev, a, b, c)
  if ev == "char" and type(a) == "string" then return { t = "char", ch = a } end
  if ev == "key" and type(keys) == "table" and type(keys.getName) == "function" then
    local name = keys.getName(a)
    if name then return { t = "key", key = name } end
  end
  if (ev == "mouse_click" or ev == "monitor_touch") and integer(b, 1, 100000) and integer(c, 1, 100000) then
    return { t = "touch", x = b, y = c }
  end
end

local function open(hostName, opts)
  opts = opts or {}
  if opts.enabled == nil then opts.enabled = M.config(nil).enabled end
  local enabled = opts.enabled == true
  local screen = opts.screen or M.screens[hostName]
  if type(screen) ~= "table" or not integer(screen.w, 16, 512) or not integer(screen.h, 8, 256) then
    return nil, "bad_screen"
  end
  if not enabled then
    return {
      enabled = false, host = hostName, screen = { w = screen.w, h = screen.h },
      ui = { message = "off" },
      data = { plan = { y = 64, rev = 0, areas = {} }, fixtures = {}, bots = {}, undo = {} },
    }
  end
  if hostName == "hub" then
    if opts.hubOnly then return nil, "hub_only_is_s1" end
    if not integer(opts.server, 0, 2147483647) then return nil, "needs_server" end
  end
  local frame = opts.frame or "abs"
  if frame ~= "abs" and not (type(frame) == "string" and frame:match("^f:[%w:.%-]+$") and #frame <= 64) then
    return nil, "bad_frame"
  end
  local dim = opts.dim or "minecraft:overworld"
  if type(dim) ~= "string" or #dim > 80 or not dim:match("^[%w_]+:[%w_/.-]+$") then return nil, "bad_dim" end
  local name = opts.name or "Base"
  if type(name) ~= "string" or #name > 32 or not name:match("^[%w ]+$") then return nil, "bad_name" end
  local y = opts.y or 64
  if not integer(y, -2048, 2048) then return nil, "bad_level" end
  local revision = opts.settingsRevision or 0
  if not integer(revision, 0, 1000000000) then return nil, "bad_settings" end
  local origin = opts.origin
  if origin == nil then
    if integer(opts.server, 0, 2147483647) then origin = opts.server
    elseif os and type(os.getComputerID) == "function" then origin = os.getComputerID()
    else origin = 0 end
  end
  local counter = opts.counter or 1
  local id, nextCounter = core.mint(origin, counter)
  if not id then return nil, nextCounter end
  local server = false
  if integer(opts.server, 0, 2147483647) then server = opts.server end
  return {
    enabled = true, host = hostName, server = server, yAbs = opts.yAbs ~= false,
    settingsRevision = revision, world = type(opts.world) == "function" and opts.world or nil,
    screen = { w = screen.w, h = screen.h },
    ui = {
      tool = "area", fixtureKind = "chest", role = "miner", facing = 0, page = "map",
      cam = { x = 0, z = 0 }, corner = nil, selected = nil, message = "",
    },
    data = {
      origin = origin, counter = nextCounter, undo = {},
      plan = { v = 1, id = id, frame = frame, dim = dim, y = y, name = name, rev = 0, areas = {} },
      fixtures = {}, bots = {},
    },
  }
end

function M.host(name)
  if name ~= "panel" and name ~= "hub" and name ~= "server" then
    error("unknown planner host " .. tostring(name), 2)
  end
  local api = { config = M.config, fromCC = M.fromCC }
  function api.open(opts) return open(name, opts) end
  function api.records(session) return records(session) end
  function api.apply(session, step) return apply(session, step) end
  function api.input(session, ev) return input(session, ev) end
  function api.gesture(session, step) return gesture(session, step) end
  function api.layout(session) return layout(session) end
  function api.render(session) return render(session) end
  function api.draw(session, term) return draw(session, term) end
  function api.ghosts(session) return ghosts(session) end
  function api.start(opts, io)
    io = io or {}
    local session, err = api.open(opts)
    if not session then return nil, err end
    local write = io.write or print
    if not session.enabled then
      write("Full planner is off.")
      return session
    end
    local pull = io.pull or os.pullEvent
    local term = io.term
    api.draw(session, term)
    local left = io.steps
    while true do
      local ev, a, b, c = pull()
      if ev == "char" and a == "q" then return session end
      local decoded = api.fromCC(ev, a, b, c)
      if decoded then
        session = api.input(session, decoded)
        api.draw(session, term)
      end
      if left then
        left = left - 1
        if left <= 0 then return session end
      end
    end
  end
  return api
end

return M
