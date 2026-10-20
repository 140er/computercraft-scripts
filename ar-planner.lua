-- AR planner adapter (plan item A1).
-- Turns chat commands and player-detector samples into the typed events
-- planner-core.lua accepts. The host calls open unless cfg.arPlanner
-- is false. A false flag refuses, so an old config still draws nothing.
--
-- Without a player detector, open refuses and the panel stays the front end.
-- A block controller only plans in its own dimension.
--
-- planner-core.lua is T1. Until it is on disk this loads
-- lib/stubs/a1_planner_core.lua. Chat authorization uses
-- lib/stubs/a1_chat.lua until PR 6's chat-control.lua can accept planner verbs.
-- Drawing calls the same ar_controller methods as ar-hud.lua. It does not call
-- ar-hud.render, which draws the fleet picture.

local M = {}

-- nav.lua and plan section 2.1. The A1 example that maps north to 3 is the older order.
M.HEADING = { north = 0, east = 1, south = 2, west = 3 }

local POLL_MS = 250
local DRAW_MS = 500
local MAX_ELEMENTS = 128
local RAY_BLOCKS = 32
local SCAN_RADIUS = 8
local SCAN_COOLDOWN = 2000
local EYE_HEIGHT = 1.62

local PASSABLE = {
  ["minecraft:air"] = true, ["minecraft:cave_air"] = true, ["minecraft:void_air"] = true,
  ["minecraft:water"] = true, ["minecraft:lava"] = true,
  ["minecraft:flowing_water"] = true, ["minecraft:flowing_lava"] = true,
}

local function argb(n)
  if n >= 0x80000000 then return n - 0x100000000 end
  return n
end

local C = {
  hud = argb(0xFFE6EDF3), bg = argb(0xDD11161D), code = argb(0xFF2EA043),
  chest = argb(0xFFD29922), bot = argb(0xFF58A6FF),
  certain = argb(0xFFE6EDF3), uncertain = argb(0xFFD29922),
}

local EDGES = {
  { 0, 0, 0, 1, 0, 0 }, { 1, 0, 0, 1, 0, 1 }, { 1, 0, 1, 0, 0, 1 }, { 0, 0, 1, 0, 0, 0 },
  { 0, 1, 0, 1, 1, 0 }, { 1, 1, 0, 1, 1, 1 }, { 1, 1, 1, 0, 1, 1 }, { 0, 1, 1, 0, 1, 0 },
  { 0, 0, 0, 0, 1, 0 }, { 1, 0, 0, 1, 1, 0 }, { 1, 0, 1, 1, 1, 1 }, { 0, 0, 1, 0, 1, 1 },
}

local function finite(n)
  return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function exists(path)
  if type(fs) == "table" and type(fs.exists) == "function" then return fs.exists(path) end
  if type(io) == "table" and type(io.open) == "function" then
    local f = io.open(path, "rb")
    if f then f:close() return true end
  end
  return false
end

local function loadModule(path)
  if not exists(path) then return nil, "missing" end
  local chunk, loadErr = loadfile(path)
  if type(chunk) ~= "function" then return nil, loadErr or "load" end
  local mod = chunk()
  if type(mod) ~= "table" then return nil, "module" end
  return mod
end

local function words(text)
  local out = {}
  for word in tostring(text):gmatch("%S+") do out[#out + 1] = word:lower() end
  return out
end

function M.solid(conf, name)
  if conf ~= "observed" or type(name) ~= "string" then return false end
  if PASSABLE[name] then return false end
  return true
end

function M.look(yaw, pitch)
  yaw, pitch = yaw or 0, pitch or 0
  local yr, pr = math.rad(yaw), math.rad(pitch)
  local cp = math.cos(pr)
  return { x = -math.sin(yr) * cp, y = -math.sin(pr), z = math.cos(yr) * cp }
end

function M.anchor(x, y, z, dim)
  return {
    v = 1, frame = "abs", yAbs = true, dim = dim,
    x = x, y = y, z = z, h = 0,
    conf = "certain", src = "neighbour", anchoredAt = 0,
  }
end

-- Voxel walk. Only an observed solid stops the ray. The first predicted or
-- unknown cell after the eye is the uncertain cursor. Unknown is not a hit.
function M.ray(origin, dir, query, maxBlocks)
  if not finite(origin.x) or not finite(origin.y) or not finite(origin.z) then return nil, nil end
  if not finite(dir.x) or not finite(dir.y) or not finite(dir.z) then return nil, nil end
  local len = math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
  if len < 1e-8 then return nil, nil end
  dir = { x = dir.x / len, y = dir.y / len, z = dir.z / len }
  maxBlocks = maxBlocks or RAY_BLOCKS
  local x, y, z = math.floor(origin.x), math.floor(origin.y), math.floor(origin.z)
  local function stepOf(n) if n > 0 then return 1 elseif n < 0 then return -1 else return 0 end end
  local stepX, stepY, stepZ = stepOf(dir.x), stepOf(dir.y), stepOf(dir.z)
  local tDeltaX = stepX ~= 0 and math.abs(1 / dir.x) or math.huge
  local tDeltaY = stepY ~= 0 and math.abs(1 / dir.y) or math.huge
  local tDeltaZ = stepZ ~= 0 and math.abs(1 / dir.z) or math.huge
  local function tBoundary(o, cell, step, component)
    if step == 0 then return math.huge end
    local boundary = step > 0 and (cell + 1) or cell
    return (boundary - o) / component
  end
  local tMaxX = tBoundary(origin.x, x, stepX, dir.x)
  local tMaxY = tBoundary(origin.y, y, stepY, dir.y)
  local tMaxZ = tBoundary(origin.z, z, stepZ, dir.z)
  local uncertain
  local function take(cx, cy, cz, mark)
    local cell = query(cx, cy, cz) or { conf = "unknown" }
    if cell.solid then return { x = cx, y = cy, z = cz, certain = true }, true end
    if mark and cell.conf ~= "observed" and not uncertain then
      uncertain = { x = cx, y = cy, z = cz, certain = false, conf = cell.conf or "unknown" }
    end
    return nil, false
  end
  local hit, done = take(x, y, z, false)
  if done then return hit, uncertain end
  for _ = 1, maxBlocks do
    if tMaxX <= tMaxY and tMaxX <= tMaxZ then
      if tMaxX > maxBlocks then break end
      x = x + stepX
      tMaxX = tMaxX + tDeltaX
    elseif tMaxY <= tMaxZ then
      if tMaxY > maxBlocks then break end
      y = y + stepY
      tMaxY = tMaxY + tDeltaY
    else
      if tMaxZ > maxBlocks then break end
      z = z + stepZ
      tMaxZ = tMaxZ + tDeltaZ
    end
    hit, done = take(x, y, z, true)
    if done then return hit, uncertain end
  end
  return nil, uncertain
end

function M.parse(text, ctx)
  local w = words(text)
  local cmd = w[1]
  ctx = ctx or {}
  if cmd == "undo" then
    if #w ~= 1 then return nil, "Use the panel for that." end
    return { t = "undo" }
  end
  if cmd == "level" then
    if #w ~= 2 then return nil, "Use the panel for that." end
    -- A leading plus is a step from the current level ($level +1). Any other
    -- whole number, including a negative world y, is absolute ($level 64).
    if w[2]:match("^%+%d+$") then
      local base = ctx.level
      if base == nil and ctx.feet then base = ctx.feet.y end
      if base == nil then return nil, "Level must be a whole number." end
      return { t = "level", y = base + tonumber(w[2]) }
    end
    if w[2]:match("^%-?%d+$") then return { t = "level", y = tonumber(w[2]) } end
    return nil, "Level must be a whole number."
  end
  if cmd ~= "plan" then return nil, "Use the panel for that." end
  if w[2] == "ok" and #w == 2 then return { t = "confirm" } end
  if w[2] == "chest" and #w == 2 then
    if ctx.wrongDim then return nil, "Other dimensions use the panel." end
    local hit = ctx.hit
    if not hit then return nil, "No block in sight." end
    if hit.certain == false then return nil, "Cursor is uncertain." end
    return { t = "place", kind = "chest", at = M.anchor(hit.x, hit.y, hit.z, ctx.dim) }
  end
  if w[2] == "here" and #w == 4 then
    if ctx.wrongDim then return nil, "Other dimensions use the panel." end
    local h = M.HEADING[w[4]]
    if not h then return nil, "Facing must be north, east, south or west." end
    if w[3] ~= "miner" then return nil, "Use the panel for that role." end
    if not ctx.feet then return nil, "Stand in the cell first." end
    return {
      t = "place", kind = "bot", role = "miner", h = h,
      at = M.anchor(ctx.feet.x, ctx.feet.y, ctx.feet.z, ctx.dim),
    }
  end
  return nil, "Use the panel for that."
end

local function effectError(effects)
  for _, effect in ipairs(effects or {}) do
    if effect.op == "error" then return effect.why or "Use the panel for that." end
  end
end

local function clockOf(host)
  if host.now then return host.now end
  return function()
    if os.epoch then return os.epoch("utc") end
    return 0
  end
end

local session = {}
session.__index = session

function session:clock()
  return self.now()
end

function session:reply(username, text)
  self.replies[#self.replies + 1] = { username = username, text = text }
  local box = self.chatBox
  if box and type(box.sendMessageToPlayer) == "function" then
    pcall(box.sendMessageToPlayer, text, username)
  end
end

function session:inspect(x, y, z)
  local cell = self.cell and self.cell(x, y, z) or nil
  if type(cell) ~= "table" then return { conf = "unknown", solid = false } end
  local conf = cell.conf or cell.confidence or "unknown"
  local name = cell.name
  return { conf = conf, name = name, solid = M.solid(conf, name) }
end

function session:context()
  local picture = self.core.view(self.state)
  local hit = self.hit
  if not hit then hit = self.uncertain end
  return {
    dim = self.dimension, hit = hit, feet = self.feet, level = picture.plan.y,
    wrongDim = self.wrongDim,
  }
end

function session:sample(pos, now)
  if type(pos) ~= "table" or not finite(pos.x) or not finite(pos.y) or not finite(pos.z) then
    return false
  end
  now = now or self:clock()
  if self.lastSample and now - self.lastSample < POLL_MS then return false end
  self.lastSample = now
  local dim = pos.dimension or pos.dim
  if dim ~= self.dimension then
    self.hit, self.uncertain, self.feet, self.wrongDim = nil, nil, nil, true
    self.dirty = true
    return true
  end
  self.wrongDim = false
  self.feet = { x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z) }
  local eyeHeight = finite(pos.eyeHeight) and pos.eyeHeight or EYE_HEIGHT
  local eye = { x = pos.x, y = pos.y + eyeHeight, z = pos.z }
  local hit, uncertain = M.ray(eye, M.look(pos.yaw, pos.pitch), function(x, y, z)
    return self:inspect(x, y, z)
  end, RAY_BLOCKS)
  self.hit, self.uncertain = hit, uncertain
  self.dirty = true
  return true
end

function session:poll(now)
  now = now or self:clock()
  if self.lastPoll and now - self.lastPoll < POLL_MS then return false end
  local name = self.follow
  if not name or not self.detector then return false end
  self.lastPoll = now
  local read = self.detector.getPlayerPos or self.detector.getPlayer
  if type(read) ~= "function" then return false end
  local ok, pos = pcall(read, name)
  if not ok or type(pos) ~= "table" then
    self.hit, self.uncertain, self.feet = nil, nil, nil
    self.dirty = true
    return false
  end
  self.lastSample = nil
  return self:sample(pos, now)
end

function session:scan(now)
  local scanner = self.scanner
  if not scanner or not self.scannerAt or type(scanner.scan) ~= "function" then return nil end
  if self.scanCache and self.scanAt and now - self.scanAt < SCAN_COOLDOWN then return self.scanCache end
  local ok, result = pcall(scanner.scan, SCAN_RADIUS)
  if not ok or type(result) ~= "table" then return nil end
  self.scanCache, self.scanAt = result, now
  return result
end

function session:confirmHit(now)
  local hit = self.hit
  if not hit or hit.certain == false then return hit end
  local scan = self:scan(now)
  if not scan then return hit end
  local at = self.scannerAt
  for _, block in ipairs(scan) do
    if type(block) == "table" and finite(block.x) and finite(block.y) and finite(block.z)
      and at.x + block.x == hit.x and at.y + block.y == hit.y and at.z + block.z == hit.z then
      if M.solid("observed", block.name) then return hit end
      local demoted = { x = hit.x, y = hit.y, z = hit.z, certain = false }
      self.hit = demoted
      return demoted
    end
  end
  return hit
end

function session:apply(event)
  local nextState, effects = self.core.transition(self.state, event)
  local why = effectError(effects)
  if why then return nil, why, effects end
  self.state = nextState
  self.log[#self.log + 1] = event
  self.dirty = true
  for _, effect in ipairs(effects or {}) do
    if effect.op == "plan-code" and type(effect.code) == "string" and self.owner then
      self:deliver(self.owner, effect.code)
    end
  end
  return effects
end

function session:chat(username, message, uuid, hidden, now)
  local id, text = self.gate.allow(self.cfg, uuid, hidden, message)
  if not id then return false end
  local cmd = words(text)[1]
  if cmd ~= "plan" and cmd ~= "level" and cmd ~= "undo" then return false end
  now = now or self:clock()
  if self.ownerId and self.ownerId ~= id then
    self:reply(username, "Planner is " .. self.owner .. ".")
    return true
  end
  if self.wrongDim then
    self.ownerId, self.owner = id, username
    self.dirty = true
    self:reply(username, "Other dimensions use the panel.")
    return true
  end
  if cmd == "plan" and words(text)[2] == "chest" then self:confirmHit(now) end
  local event, why = M.parse(text, self:context())
  if not event then
    self.ownerId, self.owner = id, username
    self.dirty = true
    self:reply(username, why)
    return true
  end
  self.ownerId, self.owner = id, username
  local _, err = self:apply(event)
  if err then self:reply(username, err) end
  return true
end

function session:deliver(username, code)
  self.code = code
  self.dirty = true
  self.replies[#self.replies + 1] = { username = username, text = code, toast = true }
  local box = self.chatBox
  if not box then return end
  if type(box.sendMessageToPlayer) == "function" then pcall(box.sendMessageToPlayer, code, username) end
  if type(box.sendToastToPlayer) == "function" then
    pcall(box.sendToastToPlayer, code, "Copy code", username)
  end
end

local function put(list, method, id, ...)
  list[#list + 1] = { method = method, id = id, args = { ... } }
end

local function box(list, id, color, x, y, z)
  for i, edge in ipairs(EDGES) do
    put(list, "drawLine3D", id .. ":e" .. i, color,
      x + edge[1], y + edge[2], z + edge[3], x + edge[4], y + edge[5], z + edge[6])
  end
end

local function near(level, y)
  if level == nil then return true end
  return math.abs(y - level) <= 1
end

function session:elements()
  local list = {}
  local picture = self.core.view(self.state)
  local level = picture.plan.y or (self.feet and self.feet.y)
  put(list, "drawRect2D", "a1:hud:bg", C.bg, 4, 4, 220, 48)
  put(list, "drawText2D", "a1:hud:name", C.hud, 8, 8, ("Planner: " .. (self.owner or "waiting")):sub(1, 64), false)
  put(list, "drawText2D", "a1:hud:level", C.hud, 8, 20, level and ("Y " .. level) or "Y unset", false)
  if self.code then
    put(list, "drawText2D", "a1:hud:code", C.code, 8, 32, ("Code: " .. self.code):sub(1, 64), false)
  end
  local function mark(id, cell, color, label)
    if not cell then return end
    box(list, id, color, cell.x, cell.y, cell.z)
    if label then
      put(list, "drawText3D", id .. ":label", color, cell.x + 0.5, cell.y + 1.2, cell.z + 0.5, 0, 0, 2, label, true)
    end
  end
  mark("a1:cursor", self.hit and self.hit.certain ~= false and self.hit or nil, C.certain, nil)
  mark("a1:uncertain", self.uncertain or (self.hit and self.hit.certain == false and self.hit or nil), C.uncertain, "?")
  for _, id in ipairs(picture.plan.fixtures) do
    local fixture = picture.fixtures[id]
    local pos = fixture and fixture.pos
    if pos and near(level, pos.y) then
      box(list, "a1:fix:" .. id, C.chest, pos.x, pos.y, pos.z)
      put(list, "drawItemIcon3D", "a1:fix:" .. id .. ":icon", pos.x + 0.5, pos.y + 0.5, pos.z + 0.5, 0, 0, 1.2, "minecraft:chest")
      put(list, "drawText3D", "a1:fix:" .. id .. ":label", C.chest, pos.x + 0.5, pos.y + 1.4, pos.z + 0.5, 0, 0, 2, "chest", true)
    end
  end
  for _, id in ipairs(picture.plan.bots) do
    local bot = picture.bots[id]
    local pos = bot and bot.pos
    if pos and near(level, pos.y) then
      box(list, "a1:bot:" .. id, C.bot, pos.x, pos.y, pos.z)
      put(list, "drawItemIcon3D", "a1:bot:" .. id .. ":icon", pos.x + 0.5, pos.y + 0.5, pos.z + 0.5, 0, 0, 1.2, "computercraft:turtle_normal")
      put(list, "drawText3D", "a1:bot:" .. id .. ":label", C.bot, pos.x + 0.5, pos.y + 1.4, pos.z + 0.5, 0, 0, 2, bot.role or "miner", true)
    end
  end
  self.truncated = #list > MAX_ELEMENTS
  if self.truncated then
    local kept = {}
    for i = 1, MAX_ELEMENTS do kept[i] = list[i] end
    list = kept
  end
  return list
end

local function same(a, b)
  if not a or a.method ~= b.method or #a.args ~= #b.args then return false end
  for i = 1, #a.args do if a.args[i] ~= b.args[i] then return false end end
  return true
end

function session:draw(now, ar)
  ar = ar or self.ar
  if not ar then return false end
  now = now or self:clock()
  if not self.force then
    if not self.dirty then return false end
    if self.lastDraw and now - self.lastDraw < DRAW_MS then return false end
  end
  local list = self:elements()
  local desired = {}
  for _, element in ipairs(list) do desired[element.id] = element end
  local changed = self.force or false
  if self.force then
    if type(ar.clear) == "function" then ar.clear() end
    self.shown = {}
  end
  self.shown = self.shown or {}
  for id in pairs(self.shown) do
    if not desired[id] and type(ar.delete) == "function" then
      ar.delete(id)
      self.shown[id] = nil
      changed = true
    end
  end
  for _, element in ipairs(list) do
    if not same(self.shown[element.id], element) then
      local method = ar[element.method]
      if type(method) == "function" then
        local ok = pcall(method, element.id, table.unpack(element.args))
        if ok then self.shown[element.id] = element changed = true end
      end
    end
  end
  if changed and type(ar.update) == "function" then ar.update() end
  self.force = false
  self.dirty = false
  self.lastDraw = now
  return changed
end

function session:boot()
  self.force = true
  self.dirty = true
  self.shown = {}
end

function M.open(host)
  host = host or {}
  if type(host.cfg) ~= "table" then host.cfg = {} end
  if host.cfg.arPlanner ~= nil and host.cfg.arPlanner ~= true then return nil, "off" end
  if host.detector == nil then return nil, "no-detector" end
  if type(host.dimension) ~= "string" then return nil, "no-dimension" end
  local core = host.core
  if not core then
    local loaded = loadModule("planner-core.lua")
    if type(loaded) == "table" and type(loaded.blank) == "function"
      and type(loaded.transition) == "function" and type(loaded.view) == "function" then
      core = loaded
    else
      local stub, err = loadModule("lib/stubs/a1_planner_core.lua")
      if not stub then return nil, err end
      core = stub
    end
  end
  if type(core.blank) ~= "function" or type(core.transition) ~= "function" or type(core.view) ~= "function" then
    return nil, "planner-core"
  end
  local gate = host.gate
  if not gate then
    local loaded, err = loadModule("lib/stubs/a1_chat.lua")
    if not loaded then return nil, err end
    gate = loaded
  end
  local self = setmetatable({
    cfg = host.cfg, detector = host.detector, chatBox = host.chatBox, scanner = host.scanner,
    scannerAt = host.scannerAt, ar = host.ar, dimension = host.dimension, cell = host.cell,
    follow = host.player, now = clockOf(host), core = core, gate = gate,
    state = core.blank(host.dimension, host.originId or 0),
    log = {}, replies = {}, shown = {}, dirty = true, force = true,
  }, session)
  return self
end

return M
