-- fleetview.lua - 3D view of the fleet, shared by hub.lua, server.lua and panel.lua
-- (CC: Tweaked). Not a program: the others load it with loadfile("fleetview.lua").
--
-- What it does:
--   * a rotating 3D wireframe of shafts, mining areas and bots on any screen
--     (monitor, computer, pocket), drawn with CC's 2x3 "teletext" pixels
--   * the AR goggles picture (cc_ar's ar_controller): world labels, boxes around
--     the turtles, ore icons above the shafts and a HUD with the fleet's status
-- All of it works on one simple list of bots (see V.entry).

local V = {}

local STALE = 15 -- seconds without a message = "no signal"
local DIRS = { north = { 0, -1 }, east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 } }
-- Screen colours per kind of bot (miners use their state colour)
V.KIND_COLOR = { hub = colors.white, server = colors.magenta, lumber = colors.green, farmer = colors.lime,
  lava = colors.orange, builder = colors.yellow, buddy = colors.pink, factory = colors.purple,
  roomsorter = colors.cyan, panel = colors.lightBlue }
-- The same in ARGB for the goggles
local KIND_ARGB = { hub = 0xFFFFFFFF, server = 0xFFFF55FF, lumber = 0xFF55AA55, farmer = 0xFF88FF55,
  lava = 0xFFFFAA00, builder = 0xFFFFFF55, buddy = 0xFFFF88CC, factory = 0xFFAA55FF, roomsorter = 0xFF55FFFF }
-- What each button ore drops, for the icon above a shaft in the goggles
V.ORE_ITEM = { diamond = "minecraft:diamond", redstone = "minecraft:redstone", gold = "minecraft:raw_gold",
  lapis = "minecraft:lapis_lazuli", iron = "minecraft:raw_iron", copper = "minecraft:raw_copper",
  coal = "minecraft:coal", emerald = "minecraft:emerald" }

local function num(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
V.coordinate = num

-- ARGB (0xAARRGGBB) as the signed Java int the controller wants
local function argb(n)
  if n >= 0x80000000 then return n - 0x100000000 end
  return n
end
V.argb = argb

---------------------------------------------------------------------------
-- Bots
---------------------------------------------------------------------------
-- One bot for the views, from its status packet p (as a bot sends it, or as the
-- server keeps it). age = seconds since it was last heard. Returns nil without p.
function V.entry(id, kind, p, age, fallback)
  if type(p) ~= "table" then return nil end
  local e = { id = id, kind = kind or "bot", age = age or 0, name = p.label, role = p.role,
    phase = p.phase, status = p.status, facing = p.facing, ore = p.ore, level = p.level,
    reach = p.reach, branchLen = p.branchLen, err = p.lastError or p.err, fuel = p.fuel }
  local at = (num(p.x) and num(p.z) and p) or (type(p.gps) == "table" and num(p.gps.x) and p.gps)
    or (type(fallback) == "table" and num(fallback.x) and fallback) or nil
  if at then e.x, e.y, e.z = at.x, num(at.y) and at.y or nil, at.z end
  local s = p.shaft
  if type(s) == "table" and num(s.x) and num(s.y) and num(s.z) then
    e.shaft = { x = s.x, y = s.y, z = s.z, bottom = num(s.bottom) and s.bottom or nil }
  end
  local st = tostring(p.status)
  e.trouble = p.phase == "lost" or st:find("^LOST") ~= nil or st:find("^STUCK") ~= nil
    or st:find("^ERROR") ~= nil
  e.stale = e.age > STALE
  return e
end

-- The bots the server keeps (state.bots), as entries. forgotten = the hub's list of
-- turtles that were removed from the fleet.
function V.fromServer(bots, now, forgotten)
  local list = {}
  for id, b in pairs(bots or {}) do
    if not (b.kind == "miner" and forgotten and forgotten[id]) then
      local e = V.entry(id, b.kind, b.status, (now - (b.lastSeen or 0)) / 1000, b.position)
      if e then list[#list + 1] = e end
    end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

-- Short state text for lists
function V.stateText(e)
  if e.stale then return "geen signaal" end
  if e.trouble then return tostring(e.err or e.status or "LOST") end
  return tostring(e.status or e.phase or "?")
end

---------------------------------------------------------------------------
-- Scene: lines and marks in world coordinates
---------------------------------------------------------------------------
local function minerColor(e)
  if e.stale then return colors.gray end
  if e.trouble then return colors.red end
  if e.phase == "home" then return colors.lightBlue end
  return colors.cyan
end

-- The mining area of a miner: a rectangle at its level, out from the shaft
local function region(e)
  local s = e.shaft
  local d = DIRS[type(e.role) == "string" and e.role:match("^[^@]+") or ""]
  if not (s and d and num(e.level) and num(e.reach) and e.reach > 0 and num(e.branchLen) and e.branchLen > 0) then
    return nil
  end
  local dx, dz = d[1], d[2]
  local sx, sz, y = s.x + 0.5, s.z + 0.5, e.level
  local width = math.min(e.branchLen, e.reach)
  local x1, z1 = sx + dx * e.reach, sz + dz * e.reach
  return { { sx, y, sz }, { x1, y, z1 }, { x1 - dz * width, y, z1 + dx * width }, { sx - dz * width, y, sz + dx * width } }
end

function V.scene(list, opt)
  opt = opt or {}
  local lines, marks = {}, {}
  local function line(a, b, c) lines[#lines + 1] = { a[1], a[2], a[3], b[1], b[2], b[3], c } end
  local minX, maxX, minZ, maxZ, ground, ny = math.huge, -math.huge, math.huge, -math.huge, 0, 0
  local function grow(x, z)
    if x < minX then minX = x end
    if x > maxX then maxX = x end
    if z < minZ then minZ = z end
    if z > maxZ then maxZ = z end
  end
  for _, e in ipairs(list) do
    local col = e.kind == "miner" and minerColor(e) or (V.KIND_COLOR[e.kind] or colors.white)
    if e.stale then col = colors.gray end
    if opt.selected == e.id then col = colors.yellow end
    local s = e.shaft
    if s then
      grow(s.x, s.z)
      ground, ny = ground + s.y, ny + 1
      local top = { s.x + 0.5, s.y + 2, s.z + 0.5 }
      if s.bottom then line(top, { s.x + 0.5, s.bottom, s.z + 0.5 }, colors.lightGray) end
      local r = region(e)
      if r then
        local rc = e.stale and colors.gray or (e.trouble and colors.red or colors.blue)
        if opt.selected == e.id then rc = colors.yellow end
        for k = 1, 4 do line(r[k], r[k % 4 + 1], rc) grow(r[k][1], r[k][3]) end
      end
      if e.x and e.y and (e.x ~= s.x or e.z ~= s.z) then
        line({ s.x + 0.5, e.y + 0.5, s.z + 0.5 }, { e.x + 0.5, e.y + 0.5, e.z + 0.5 }, col)
      end
    end
    if e.x and e.y then
      grow(e.x, e.z)
      if not s then ground, ny = ground + e.y, ny + 1 end
      local d = DIRS[e.facing]
      if d then
        line({ e.x + 0.5, e.y + 0.5, e.z + 0.5 }, { e.x + 0.5 + d[1] * 3, e.y + 0.5, e.z + 0.5 + d[2] * 3 }, col)
      end
      marks[#marks + 1] = { e.x + 0.5, e.y + 0.5, e.z + 0.5, col, e.name or ("#" .. e.id), e.id }
    elseif s then
      marks[#marks + 1] = { s.x + 0.5, s.y + 1, s.z + 0.5, col, e.name or ("#" .. e.id), e.id }
    end
  end
  for _, p in ipairs(opt.places or {}) do
    if num(p.x) and num(p.y) and num(p.z) then
      grow(p.x, p.z)
      marks[#marks + 1] = { p.x + 0.5, p.y + 0.5, p.z + 0.5, p.color or colors.white, p.name }
    end
  end
  if minX == math.huge then return { lines = lines, marks = marks, empty = true } end
  ground = ny > 0 and math.floor(ground / ny) or 64
  -- Chunk grid on the ground (every 16 blocks), for a sense of size and direction
  local pad = 8
  local x1, x2 = math.floor((minX - pad) / 16) * 16, math.ceil((maxX + pad) / 16) * 16
  local z1, z2 = math.floor((minZ - pad) / 16) * 16, math.ceil((maxZ + pad) / 16) * 16
  local step = 16
  while (x2 - x1) / step > 6 or (z2 - z1) / step > 6 do step = step * 2 end
  local grid = {}
  for x = x1, x2, step do grid[#grid + 1] = { x, ground, z1, x, ground, z2, colors.gray } end
  for z = z1, z2, step do grid[#grid + 1] = { x1, ground, z, x2, ground, z, colors.gray } end
  for _, l in ipairs(lines) do grid[#grid + 1] = l end -- the grid goes underneath everything
  marks[#marks + 1] = { (x1 + x2) / 2, ground, z1, colors.white, "N" }
  return { lines = grid, marks = marks, box = { x1, x2, z1, z2 }, ground = ground }
end

---------------------------------------------------------------------------
-- Drawing a scene on a screen
---------------------------------------------------------------------------
function V.camera() return { yaw = 0.7, pitch = 0.55, zoom = 1, auto = true, panX = 0, panZ = 0 } end

local HEX = {}
for i = 0, 15 do HEX[2 ^ i] = string.format("%x", i) end

-- t = screen (term or monitor). x0, y0, w, h = the part of the screen to use.
-- Returns the screen cell of each mark with an id, for taps: { [id] = { x, y } }.
function V.render(t, x0, y0, w, h, scene, cam, bg)
  bg = bg or colors.black
  local W, H = w * 2, h * 3
  local px, pc = {}, {} -- pixel bits and colour per cell
  local hits = {}
  local bx = scene.box
  local cx, cz = 0, 0
  local cy = scene.ground or 0
  local radius = 16
  if bx then
    cx, cz = (bx[1] + bx[2]) / 2 + cam.panX, (bx[3] + bx[4]) / 2 + cam.panZ
    radius = math.max(bx[2] - bx[1], bx[4] - bx[3]) / 2
  end
  -- Height matters too: take the deepest point into account
  local lowY, highY = cy, cy
  for _, l in ipairs(scene.lines) do
    lowY, highY = math.min(lowY, l[2], l[5]), math.max(highY, l[2], l[5])
  end
  cy = (lowY + highY) / 2
  radius = math.max(radius, (highY - lowY) / 2, 8)
  local cyaw, syaw = math.cos(cam.yaw), math.sin(cam.yaw)
  local cp, sp = math.cos(cam.pitch), math.sin(cam.pitch)
  local scale = math.min(W, H) / (2 * radius) * cam.zoom * 0.9
  local function project(x, y, z)
    local dx, dy, dz = x - cx, y - cy, z - cz
    local rx = dx * cyaw - dz * syaw
    local rz = dx * syaw + dz * cyaw
    return W / 2 + rx * scale, H / 2 + (rz * sp - dy * cp) * scale
  end
  local function plot(x, y, col)
    x, y = math.floor(x), math.floor(y)
    if x < 0 or y < 0 or x >= W or y >= H then return end
    local cxl, cyl = math.floor(x / 2), math.floor(y / 3)
    local k = cyl * w + cxl
    local bit = 2 ^ ((y % 3) * 2 + (x % 2))
    local b = px[k] or 0
    if b % (bit * 2) < bit then px[k] = b + bit end
    pc[k] = col
  end
  for _, l in ipairs(scene.lines) do
    local ax, ay = project(l[1], l[2], l[3])
    local bx2, by2 = project(l[4], l[5], l[6])
    local n = math.max(math.abs(bx2 - ax), math.abs(by2 - ay))
    n = math.min(math.ceil(n), 600)
    for k = 0, n do
      local f = n == 0 and 0 or k / n
      plot(ax + (bx2 - ax) * f, ay + (by2 - ay) * f, l[7])
    end
  end
  local labels = {}
  for _, m in ipairs(scene.marks) do
    local x, y = project(m[1], m[2], m[3])
    if m[5] ~= "N" then
      plot(x, y, m[4]) plot(x + 1, y, m[4]) plot(x, y + 1, m[4]) plot(x + 1, y + 1, m[4])
    end
    local cxl, cyl = math.floor(x / 2), math.floor(y / 3)
    if cxl >= 0 and cyl >= 0 and cxl < w and cyl < h then
      labels[#labels + 1] = { cxl, cyl, m[4], m[5] }
      if m[6] then hits[m[6]] = { x0 + cxl, y0 + cyl } end
    end
  end
  -- Rows of cells: teletext characters 128-159 (the bottom-right pixel is the background)
  local hexBg = HEX[bg] or "f"
  local rows = {}
  for row = 0, h - 1 do
    local text, fg, back = {}, {}, {}
    for col = 0, w - 1 do
      local k = row * w + col
      local b = px[k]
      if not b then
        text[#text + 1], fg[#fg + 1], back[#back + 1] = " ", "0", hexBg
      elseif b >= 32 then
        text[#text + 1] = string.char(128 + (63 - b))
        fg[#fg + 1], back[#back + 1] = hexBg, HEX[pc[k]] or "0"
      else
        text[#text + 1] = string.char(128 + b)
        fg[#fg + 1], back[#back + 1] = HEX[pc[k]] or "0", hexBg
      end
    end
    rows[row] = { text, fg, back }
  end
  -- Labels next to their mark, skipping ones that would cover another label
  local used = {}
  for _, l in ipairs(labels) do
    local text = tostring(l[4] or "")
    local x = l[1] + (l[4] == "N" and 0 or 1)
    if l[4] ~= "N" then text = text:sub(1, math.max(1, w - x)) end
    local free = true
    for i = 0, #text - 1 do if used[l[2] * w + x + i] then free = false end end
    if free and x >= 0 and x + #text <= w then
      local r = rows[l[2]]
      for i = 1, #text do
        r[1][x + i] = text:sub(i, i)
        r[2][x + i] = HEX[l[3]] or "0"
        r[3][x + i] = hexBg
        used[l[2] * w + x + i - 1] = true
      end
    end
  end
  for row = 0, h - 1 do
    local r = rows[row]
    t.setCursorPos(x0, y0 + row)
    if t.blit then
      t.blit(table.concat(r[1]), table.concat(r[2]), table.concat(r[3]))
    else
      for i = 1, w do
        local f, b = tonumber(r[2][i], 16), tonumber(r[3][i], 16)
        t.setTextColor(2 ^ f)
        t.setBackgroundColor(2 ^ b)
        t.write(r[1][i])
      end
    end
  end
  return hits
end

-- The control bar under a 3D view: one row of buttons. Returns the buttons
-- as { x1, x2, y, action } so the caller can hit-test a tap.
local CONTROLS = { { "<", "left" }, { ">", "right" }, { "^", "up" }, { "v", "down" }, { "+", "in" },
  { "-", "out" }, { "A", "auto" }, { "o", "reset" } }
function V.controls(t, x0, y, w, cam)
  local list = {}
  local bw = math.max(3, math.min(5, math.floor(w / #CONTROLS)))
  t.setCursorPos(x0, y)
  t.setBackgroundColor(colors.gray)
  t.write(string.rep(" ", w))
  for k, c in ipairs(CONTROLS) do
    local x = x0 + (k - 1) * bw
    if x + bw - 1 > x0 + w - 1 then break end
    local on = c[2] == "auto" and cam.auto
    t.setCursorPos(x, y)
    t.setBackgroundColor(on and colors.green or colors.lightGray)
    t.setTextColor(colors.black)
    local label = c[1]
    local pad = math.floor((bw - 1 - #label) / 2)
    t.write(string.rep(" ", pad) .. label .. string.rep(" ", bw - 1 - pad - #label))
    list[#list + 1] = { x, x + bw - 2, y, c[2] }
  end
  return list
end

-- What a control does to the camera
function V.control(cam, what)
  if what == "left" then cam.yaw, cam.auto = cam.yaw - math.pi / 8, false
  elseif what == "right" then cam.yaw, cam.auto = cam.yaw + math.pi / 8, false
  elseif what == "up" then cam.pitch = math.min(math.pi / 2, cam.pitch + 0.2)
  elseif what == "down" then cam.pitch = math.max(0, cam.pitch - 0.2)
  elseif what == "in" then cam.zoom = math.min(16, cam.zoom * 1.5)
  elseif what == "out" then cam.zoom = math.max(0.25, cam.zoom / 1.5)
  elseif what == "auto" then cam.auto = not cam.auto
  elseif what == "reset" then
    local fresh = V.camera()
    for k, v in pairs(fresh) do cam[k] = v end
  end
end

-- Dragging a finger/mouse over the view turns it (dx, dy in cells)
function V.drag(cam, dx, dy)
  cam.auto = false
  cam.yaw = cam.yaw + dx * 0.12
  cam.pitch = math.max(0, math.min(math.pi / 2, cam.pitch + dy * 0.1))
end

-- Called every second or so: slow turn while "A" (auto) is on
function V.tick(cam)
  if cam.auto then cam.yaw = cam.yaw + 0.08 end
end

-- Hit-test the control bar: true when a button was tapped
function V.tap(cam, buttons, x, y)
  for _, b in ipairs(buttons or {}) do
    if y == b[3] and x >= b[1] and x <= b[2] then V.control(cam, b[4]) return true end
  end
  return false
end

---------------------------------------------------------------------------
-- AR goggles (cc_ar: ar_controller)
---------------------------------------------------------------------------
-- Draws the whole picture: the HUD top left, and in the world per miner its name
-- above the shaft, the shaft, its mining area, a box around the turtle with an
-- arrow for the way it faces, an icon of the ore it mines; other bots get a box
-- and their name. Elements keep their id between frames, and ones that are gone
-- are deleted, so the picture does not flicker. ar.update() sends it to the goggles.
-- mem = a table this function keeps its bookkeeping in (one per controller).
-- Errors are passed on: the caller pcalls this and drops a controller that fails.
function V.ar(ar, list, enabled, mem, title)
  local drawn = {}
  local useDelete = mem.drawn ~= nil and type(ar.delete) == "function"
  if not useDelete then ar.clear() end
  local function text3(id, c, x, y, z, size, s)
    drawn[id] = true
    ar.drawText3D(id, c, x, y, z, 0, 0, size, s, true)
  end
  local function line3(id, c, ax, ay, az, bx, by, bz)
    drawn[id] = true
    ar.drawLine3D(id, c, ax, ay, az, bx, by, bz)
  end
  drawn.view = true
  ar.drawText2D("view", argb(enabled and 0xFF55FF55 or 0xFF999999), 4, 4,
    enabled and "3D: AAN" or "3D: UIT", false)
  -- HUD: one line per bot, with a dark backing
  local rows = {}
  for _, e in ipairs(enabled and list or {}) do
    local c = e.stale and 0xFF999999 or (e.trouble and 0xFFFF5555
      or (e.kind == "miner" and 0xFF55FFFF or (KIND_ARGB[e.kind] or 0xFFFFFFFF)))
    rows[#rows + 1] = { c, ((e.name or ("#" .. e.id)) .. ": " .. V.stateText(e)):sub(1, 44) }
    if #rows >= 12 then break end
  end
  if #rows > 0 and type(ar.drawRect2D) == "function" then
    drawn["hud:bg"] = true
    ar.drawRect2D("hud:bg", argb(0x90000000), 2, 15, 232, 30 + #rows * 10)
    drawn["hud:title"] = true
    ar.drawText2D("hud:title", argb(0xFFFFFFFF), 6, 18, title or "Vloot", false)
    for k, r in ipairs(rows) do
      drawn["hud:" .. k] = true
      ar.drawText2D("hud:" .. k, argb(r[1]), 6, 20 + k * 10, r[2], false)
    end
  end
  for _, e in ipairs(enabled and list or {}) do
    local key = (e.kind == "miner" and "turtle:" or "bot:") .. e.id
    local color = argb(e.stale and 0xFF999999 or (e.trouble and 0xFFFF5555
      or (e.kind == "miner" and 0xFF55FFFF or (KIND_ARGB[e.kind] or 0xFFFFFFFF))))
    local s = e.shaft
    if e.kind == "miner" and e.x and e.y then
      local x, y, z = e.x + 0.5, e.y + 0.5, e.z + 0.5
      local sx, sy, sz = s and s.x + 0.5 or x, s and s.y or e.y, s and s.z + 0.5 or z
      text3(key, color, sx, sy + 3, sz, 6, e.name and e.name ~= "" and e.name or ("#" .. e.id))
      if e.trouble then
        text3(key .. ":error", color, sx, sy + 1.8, sz, 2, tostring(e.err or e.status or "LOST"):sub(1, 40))
      end
      if s and (e.x ~= s.x or e.y ~= s.y or e.z ~= s.z) then
        text3(key .. ":position", color, x, y + 0.9, z, 2, "#" .. e.id)
        if e.x ~= s.x or e.z ~= s.z then line3(key .. ":path", color, sx, y, sz, x, y, z) end
      end
      -- A box around the turtle (see it through the rock)
      local a, b = 0.55, 0.55
      local c8 = { { x - a, y - b, z - a }, { x + a, y - b, z - a }, { x + a, y - b, z + a }, { x - a, y - b, z + a },
        { x - a, y + b, z - a }, { x + a, y + b, z - a }, { x + a, y + b, z + a }, { x - a, y + b, z + a } }
      local edges = { { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 }, { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
        { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 } }
      for k, ed in ipairs(edges) do
        local p, q = c8[ed[1]], c8[ed[2]]
        line3(key .. ":box:" .. k, color, p[1], p[2], p[3], q[1], q[2], q[3])
      end
      local heading = DIRS[e.facing]
      if heading then
        local dx, dz = heading[1], heading[2]
        local tx, tz = x + dx * 1.5, z + dz * 1.5
        line3(key .. ":heading", color, x, y, z, tx, y, tz)
        line3(key .. ":heading:1", color, tx, y, tz, tx - dx * 0.5 - dz * 0.5, y, tz - dz * 0.5 + dx * 0.5)
        line3(key .. ":heading:2", color, tx, y, tz, tx - dx * 0.5 + dz * 0.5, y, tz - dz * 0.5 - dx * 0.5)
      end
      if s and s.bottom then
        line3(key .. ":shaft", e.stale and color or -1, sx, sy + 2.5, sz, sx, s.bottom, sz)
        local r = region(e)
        if r then
          for k = 1, 4 do
            local p, q = r[k], r[k % 4 + 1]
            line3(key .. ":region:" .. k, color, p[1], p[2], p[3], q[1], q[2], q[3])
          end
        end
      end
      local item = V.ORE_ITEM[e.ore]
      if s and item and type(ar.drawItemIcon3D) == "function" then
        -- An unknown item must not take the rest of the picture with it
        if pcall(ar.drawItemIcon3D, key .. ":ore", sx, sy + 5, sz, 0, 0, 1.5, item) then drawn[key .. ":ore"] = true end
      end
    elseif e.kind ~= "miner" and e.x and e.y then
      local x, y, z = e.x + 0.5, e.y + 0.5, e.z + 0.5
      text3(key, color, x, y + 1.6, z, 3, (e.name or ("#" .. e.id)) .. (e.stale and " (?)" or ""))
      local a = 0.55
      local c4 = { { x - a, z - a }, { x + a, z - a }, { x + a, z + a }, { x - a, z + a } }
      for k = 1, 4 do
        local p, q = c4[k], c4[k % 4 + 1]
        line3(key .. ":box:" .. k, color, p[1], y - a, p[2], q[1], y - a, q[2])
        line3(key .. ":box:" .. (k + 4), color, p[1], y + a, p[2], q[1], y + a, q[2])
        line3(key .. ":box:" .. (k + 8), color, p[1], y - a, p[2], p[1], y + a, p[2])
      end
    end
  end
  if useDelete then
    for id in pairs(mem.drawn) do
      if not drawn[id] then ar.delete(id) end
    end
  end
  mem.drawn = drawn
  ar.update()
end

-- Empty the goggles of a controller this program no longer uses
function V.arClear(ar, mem)
  ar.clear()
  ar.update()
  if mem then mem.drawn = nil end
end

return V
