local F = dofile("so-flags.lua")
local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local A = {
  layers = { turtles = true, leases = true, drops = true, alerts = true },
  order = { "turtles", "leases", "drops", "alerts" }, controllers = {},
  alertMs = 300000, hudX = 4, hudY = 72, hudWidth = 192, hudCell = 64,
  labelScale = 0.5, labelGap = 0.25, labelLimits = { turtle = 16, drop = 8 },
  chevron = { tip = 0.75, back = 0.6, half = 0.2 }, pad = { turtle = 0.08, lease = 0.12 },
  -- Route A palette as ARGB (docs/ui/SCHEMATIC-SPEC.md section 3): 0 white, 8 grey, c hair, f backing.
  white = 0xFFE6EAF2 - 2^32, grey = 0xFF7886A3 - 2^32, red = 0xFFFF6B5E - 2^32,
  green = 0xFF3DDC84 - 2^32, amber = 0xFFFFC24B - 2^32, blue = 0xFF5AB0FF - 2^32,
  teal = 0xFF2DD4BF - 2^32, hair = 0xFF28344D - 2^32, backing = 0xE00B111C - 2^32,
  dirs = { [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 },
    north = { 0, -1 }, east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 } },
  dimensions = { [0] = "minecraft:overworld", [-1] = "minecraft:the_nether", [1] = "minecraft:the_end" },
}

-- so-data/ar is the four layer booleans, or with arFollowups the v2 record
-- {v=2, turtles, leases, drops, alerts, dim?, focus={kind,id?}} (docs/server-only/PROTOCOL.md).
A.layerIds = { turtles = true, leases = true, drops = true, alerts = true }
A.dimIds = { world = "minecraft:overworld", nether = "minecraft:the_nether", ["end"] = "minecraft:the_end" }
A.dimNames = { ["minecraft:overworld"] = "world", ["minecraft:the_nether"] = "nether", ["minecraft:the_end"] = "end" }
A.validFocus = function(f)
  if type(f) ~= "table" then return false end
  for k in pairs(f) do if k ~= "kind" and k ~= "id" then return false end end
  if f.kind == "all" then return f.id == nil end
  if f.kind == "turtle" then
    return type(f.id) == "number" and f.id >= 1 and f.id <= 2147483647 and f.id % 1 == 0
  end
  return f.kind == "drop" and type(f.id) == "string" and #f.id <= 128 and f.id:match("^[%w_%-]+$") ~= nil
end
A.valid = function(value)
  if type(value) ~= "table" then return false end
  for _, layer in ipairs(A.order) do if type(value[layer]) ~= "boolean" then return false end end
  if value.v == nil then return true end
  if value.v ~= 2 then return false end
  for k in pairs(value) do
    if not (A.layerIds[k] or k == "v" or k == "dim" or k == "focus") then return false end
  end
  return (value.dim == nil or A.dimNames[value.dim] ~= nil) and A.validFocus(value.focus)
end
A.box = SO.store.store("so-data/ar", A.valid, 4096)
A.config = SO.store.read("so-server.cfg") or {}
A.follow = F.enabled(A.config, "arFollowups")
A.remote = A.follow and F.enabled(A.config, "remoteDimensions")
A.norm = function(dim) return A.dimensions[dim] or dim or "minecraft:overworld" end
A.baseDim = A.norm(A.config.arDim or A.config.pos and A.config.pos.dim)
if type(A.config.arLabelScale)=="number" then
  A.labelScale=math.max(0.5,math.min(0.7,A.config.arLabelScale))
  A.labelGap=math.max(A.labelGap,A.labelScale*0.5)
end
A.sameDim = function(dim) return A.norm(dim) == A.dim end
-- The saved dimension and focus apply only with the flags on; otherwise they stay in the file unused.
A.apply = function(settings)
  A.settings, A.layers = settings, {}
  for _, layer in ipairs(A.order) do A.layers[layer] = settings[layer] end
  local v2 = settings.v == 2
  A.dim = A.remote and v2 and settings.dim or A.baseDim
  A.focus = A.follow and v2 and SO.store.copy(settings.focus) or { kind = "all" }
  A.frameAt = nil
  for _, controller in ipairs(A.controllers) do controller.sig = nil end
end
A.apply(A.box.value and SO.store.copy(A.box.value) or SO.store.copy(A.layers))
-- A failed save keeps the previous settings and scene.
A.commit = function(settings)
  if not A.box.save(settings) then return false end
  A.apply(settings)
  return true
end
-- The current settings as a v2 record; a legacy file migrates here, keeping every layer choice.
A.v2 = function()
  local s = A.settings
  local out = { v = 2, dim = s.v == 2 and s.dim or nil, focus = s.v == 2 and SO.store.copy(s.focus) or { kind = "all" } }
  for _, layer in ipairs(A.order) do out[layer] = s[layer] end
  return out
end
A.call = function(name, method, ...)
  local mod = SO.mods[name]
  if type(mod) ~= "table" then return end
  local fn = mod[method]
  local meta = type(fn) == "table" and getmetatable(fn)
  if type(fn) == "function" or (meta and type(meta.__call) == "function") then return fn(...) end
end
A.legacyRender = function()
  local picture = { rows = { { text = "AR layers", fg = "0", bg = "f" } }, buttons = {} }
  for i, layer in ipairs(A.order) do
    local label = layer .. (A.layers[layer] and " on" or " off")
    picture.buttons[i] = { id = layer, x = 1, y = i + 1, w = #label, label = label }
  end
  return picture
end
-- Workers from the state machines and the lumber farm's saved turtles.
A.machines = function()
  local machines = SO.store.copy(A.call("state", "get", "machines") or {})
  local lumber = A.call("lumber", "mapView") or {}
  for id, worker in pairs(lumber.turtles or {}) do
    id = tostring(id)
    local machine = machines[id] or machines[tonumber(id)] or {}
    machine.role, machine.pose, machine.state = "worker", worker.pose, worker.state
    if machine.pose and machine.pose.dim == nil then machine.pose.dim = lumber.dim end
    machines[tonumber(id)], machines[id] = nil, machine
  end
  return machines
end
-- Focus targets in the drawn dimension: ALL, then turtles by id, then drops in DROP POINTS order.
A.targets = function(machines)
  local list, turtles = { { id = "ar-all", text = "ALL", kind = "all" } }, {}
  for id, m in pairs(machines or A.machines()) do
    local n = tonumber(id)
    if (m.role == nil or m.role == "worker" or m.role == "turtle") and m.pose and A.sameDim(m.pose.dim)
      and A.validFocus({ kind = "turtle", id = n }) then turtles[#turtles + 1] = n end
  end
  table.sort(turtles)
  for _, n in ipairs(turtles) do
    list[#list + 1] = { id = "ar-turtle:" .. n, text = "turtle #" .. n, kind = "turtle", key = n }
  end
  for _, p in ipairs(A.call("drops", "list") or {}) do
    if A.sameDim(p.dim) and A.validFocus({ kind = "drop", id = p.id }) then
      list[#list + 1] = { id = "ar-drop:" .. p.id, text = "drop #" .. (p.n or p.id), kind = "drop", key = p.id, n = p.n }
    end
  end
  return list
end
A.find = function(focus, list)
  for _, t in ipairs(list or A.targets()) do if t.kind == focus.kind and t.key == focus.id then return t end end
end
A.gather = function(session)
  local count = 0
  for _ in pairs(A.controllers) do count = count + 1 end
  local model = { count = count, layers = SO.store.copy(A.layers), alert = A.shown and SO.store.copy(A.shown) }
  if A.follow then
    local list, f = A.targets(), A.focus
    local t = f.kind ~= "all" and A.find(f, list)
    model.follow = { focus = f.kind == "all" and "all" or not t and "missing"
      or t.kind == "turtle" and "#" .. t.key or "drop #" .. (t.n or t.key), missing = f.kind ~= "all" and not t,
      dims = A.remote and A.dimNames[A.dim] or nil }
    -- The FOCUS list is per display session; the saved settings are shared.
    local picker = type(session) == "table" and session.arPicker
    if picker then
      for _, item in ipairs(list) do item.on = item.kind == f.kind and (f.kind == "all" or item.key == f.id) end
      model.picker = { page = picker.page, items = list }
    end
  end
  return model
end
A.bar = function(C, model, w)
  local right = model.count .. (model.count == 1 and " controller" or " controllers")
  if #right + 14 > w then right = tostring(model.count) end
  C.bar("AR GOGGLES", {}, nil, right)
end
-- Route A (docs/ui/SCHEMATIC-SPEC.md section 26); docs/ui/schematic/ar.py is the twin.
-- Each layer is a leader row with its state word; a tap anywhere on the row toggles it.
-- With arFollowups, the focus row and the dimension words follow the layers.
-- The goggles' alert sits under them where it fits, and a tap steps to the next alert.
A.layout = function(model, w, h)
  local C = U.canvas(w, h)
  A.bar(C, model, w)
  local on = 0
  for _, layer in ipairs(A.order) do if model.layers[layer] then on = on + 1 end end
  local lw, step, y = math.min(w - 2, 55), h >= 16 and 2 or 1, 2
  if h >= 7 then
    C.section(2, 3, lw, "LAYERS", on .. " on")
    y = 3 + step
  end
  for i, layer in ipairs(A.order) do
    local ry, state = y + (i - 1) * step, model.layers[layer]
    local word = state and "on" or "off"
    C.leader(2, ry, lw, layer, "[" .. word .. "]", "8")
    C.put(lw - #word + 1, ry, word, state and "d" or "8")
    C.hit(layer, 1, ry, w, 1, layer)
  end
  local alert, ay, f = model.alert, y + #A.order * step, model.follow
  if f and ay <= h then
    C.leader(2, ay, lw, "focus", "[" .. f.focus .. "]", "8")
    C.put(lw - #f.focus + 1, ay, f.focus, f.missing and "e" or "0")
    C.hit("ar-focus", 1, ay, w, 1, "focus")
    ay = ay + step
  end
  if f and f.dims and ay <= h then
    local x, words = 2, w >= 20 and { "WORLD", "NETHER", "END" } or { "OVER", "NETH", "END" }
    for i, key in ipairs({ "world", "nether", "end" }) do
      C.put(x, ay, words[i], key == f.dims and "d" or "8")
      C.hit("ar-dim:" .. key, x, ay, #words[i], 1, words[i])
      x = x + #words[i] + (w >= 20 and 2 or 1)
    end
    ay = ay + step
  end
  if alert and ay + 1 <= h then
    C.section(2, ay, lw, "ALERTS", alert.i .. "/" .. alert.n)
    C.put(2, ay + 1, "!", "e")
    C.put(4, ay + 1, tostring(alert.text):sub(1, lw - 2), "0")
    C.hit("alert:next", 1, ay, w, 2, "next alert")
  end
  return C.frame()
end
-- FOCUS: ALL and the targets one per row, the current one green; BACK, and MORE with more pages.
A.pickLayout = function(model, w, h)
  local C = U.canvas(w, h)
  A.bar(C, model, w)
  local p, lw, step, y = model.picker, math.min(w - 2, 55), h >= 16 and 2 or 1, 2
  if h >= 7 then y = 3 + step end
  local per = math.max(1, math.floor((h - step - y) / step) + 1)
  local pages = math.max(1, math.ceil(#p.items / per))
  local page = (p.page - 1) % pages + 1
  if h >= 7 then C.section(2, 3, lw, "FOCUS", pages > 1 and page .. "/" .. pages or "") end
  for i = 1, per do
    local item, ry = p.items[(page - 1) * per + i], y + (i - 1) * step
    if item then
      C.put(2, ry, item.text:sub(1, lw), item.on and "d" or "0")
      C.hit(item.id, 1, ry, w, 1, item.text)
    end
  end
  C.put(2, h, "BACK", "0")
  C.hit("ar-back", 1, h, 6, 1, "BACK")
  if pages > 1 then
    C.put(w - 4, h, "MORE", "0")
    C.hit("ar-more", w - 5, h, 6, 1, "MORE")
  end
  return C.frame()
end
A.render = function(w,h,session)
  if not U then return A.legacyRender() end
  local model = A.gather(session)
  return (model.picker and A.pickLayout or A.layout)(model, w or 57, h or 24)
end
-- Only the four layer rows and the checked follow-up controls reach a save; v, dim and focus
-- are never toggles.
A.input = function(event)
  local id = event and event.id
  if id == "alert:next" then
    local list, at = A.active or {}, 0
    for i, row in ipairs(list) do if row.key == (A.shown and A.shown.key) then at = i end end
    if #list > 0 then A.pick, A.frameAt = list[at % #list + 1].key, nil end
    return
  end
  if type(id) ~= "string" then return end
  if A.layerIds[id] then
    local nextLayers = A.follow and A.v2() or SO.store.copy(A.settings)
    nextLayers[id] = not nextLayers[id]
    A.commit(nextLayers)
    return
  end
  if not A.follow then return end
  local dim, focus = id:match("^ar%-dim:(%a+)$"), nil
  local session = type(event.session) == "table" and event.session or {}
  if id == "ar-focus" then session.arPicker = { page = 1 }
  elseif id == "ar-back" then session.arPicker = nil
  elseif id == "ar-more" then if session.arPicker then session.arPicker.page = session.arPicker.page + 1 end
  elseif dim then
    if not (A.remote and A.dimIds[dim]) then return end
    local nextSettings = A.v2()
    -- A new dimension resets focus to ALL in the same save.
    nextSettings.dim, nextSettings.focus = A.dimIds[dim], { kind = "all" }
    if A.commit(nextSettings) then session.arPicker = nil end
  elseif id == "ar-all" then focus = { kind = "all" }
  elseif id:match("^ar%-turtle:%d+$") then focus = { kind = "turtle", id = tonumber(id:sub(11)) }
  elseif id:match("^ar%-drop:") then focus = { kind = "drop", id = id:sub(9) }
  end
  -- The target must still be valid and in the drawn dimension when it is saved.
  if not focus or not A.validFocus(focus) or focus.kind ~= "all" and not A.find(focus) then return end
  local nextSettings = A.v2()
  nextSettings.focus = focus
  if A.commit(nextSettings) then session.arPicker = nil end
end
A.turtle = function(machine, status, now, inRange)
  local state = tostring(machine.state or "idle"):lower():gsub("_", " ")
  local seen = machine.seen or 0
  if status.seen then seen = math.max(seen, status.seen) end
  if now - seen >= 120000 then return A.grey, "STALE" end
  if status.lost or inRange == false or state == "lost" or state == "range" or state == "out of range" then
    return A.red, status.lost and "LOST" or (inRange == false and "OUT OF RANGE" or state:upper())
  end
  if type(machine.fuel) == "number" and machine.fuel >= 0 and machine.fuel < 64 then return A.amber, "LOW FUEL" end
  if state:find("wait", 1, true) or state:find("hold", 1, true) or state == "low fuel" then return A.amber, state:upper() end
  if state == "working" or state == "mining" or state == "running" or state == "lumber" then return A.green, state:upper() end
  if status.open then return A.teal, state == "idle" and "LEASED" or state:upper() end
  return A.white, state:upper()
end
A.scene = function(now)
  local scene = {}
  local labels = {}
  local function put(id, method, ...) scene[id] = { method = method, args = { ... } } end
  local retirement = A.call("cells", "retirement")
  local hudTop = A.hudY
  local origin = A.config.pos
  local function line(id, color, x, y, z, u, v, w) put(id, "drawLine3D", color, x, y, z, u, v, w) end
  local function far(x, y, z)
    if not (origin and A.sameDim(origin.dim) and origin.x and origin.y and origin.z) then return 0 end
    return (x - origin.x)^2 + (y - origin.y)^2 + (z - origin.z)^2
  end
  local function label(id, color, p, text, kind, group)
    labels[#labels + 1] = { id = id, color = color, x = p.x + 0.5, y = p.y + 1.25,
      z = p.z + 0.5, text = text:sub(1, 8), kind = kind, group = group, distance = far(p.x, p.y, p.z) }
  end
  -- Route A strokes: one line per box edge and a small upright chevron just outside the front face,
  -- a > from the side and a tick from the front.
  local function box(id, color, x, y, z, u, v, w)
    local corners = { { x, z }, { u, z }, { u, w }, { x, w } }
    for k, p in ipairs(corners) do
      local q = corners[k % 4 + 1]
      line(id .. ":" .. k, color, p[1], y, p[2], q[1], y, q[2])
      line(id .. ":" .. (k + 4), color, p[1], v, p[2], q[1], v, q[2])
      line(id .. ":" .. (k + 8), color, p[1], y, p[2], p[1], v, p[2])
    end
  end
  local function chevron(id, color, p, d)
    local c, x, y, z = A.chevron, p.x + 0.5, p.y + 0.5, p.z + 0.5
    local tx, tz, bx, bz = x + d[1] * c.tip, z + d[2] * c.tip, x + d[1] * c.back, z + d[2] * c.back
    line(id, color, bx, y + c.half, bz, tx, y, tz)
    line(id .. ":1", color, bx, y - c.half, bz, tx, y, tz)
  end
  local machines = A.machines()
  -- A focused turtle keeps its box, trail and every reservation of its exact id; a focused drop
  -- keeps its point. A target gone from this dimension draws nothing until ALL is chosen.
  local only = A.focus.kind ~= "all" and A.focus
  A.missing = only and not A.find(only, A.targets(machines))
  local prefixes = only and { "mine:", "lumber:", "build:", "setup:", "gps:" } or { "mine:", "lumber:" }
  local function shown(id)
    return not only or only.kind == "turtle" and not A.missing and tonumber(id) == only.id
  end
  local leases, merged = {}, {}
  if A.layers.leases then
    local owners = {}
    for id in pairs(machines) do
      if shown(id) then for _, prefix in ipairs(prefixes) do owners[prefix .. id] = true end end
    end
    for owner in pairs(owners) do
      local bounds
      for _, cell in ipairs(A.call("cells", "list", owner, math.huge) or {}) do
        if A.sameDim(cell.dim) then
          if not bounds then bounds = { cell.x, cell.y, cell.z, cell.x + 1, cell.y + 1, cell.z + 1 }
          else
            for i, axis in ipairs({ "x", "y", "z" }) do
              bounds[i] = math.min(bounds[i], cell[axis])
              bounds[i + 3] = math.max(bounds[i + 3], cell[axis] + 1)
            end
          end
        end
      end
      leases[owner] = bounds
    end
  end
  local lostCount, turtleCount = 0, 0
  for id, machine in pairs(machines) do
    local p = machine.pose
    local status = A.call("lease", "peek", tonumber(id) or id) or {}
    local color = A.turtle(machine, status, now, p and A.call("lease", "inRange", tonumber(id) or id, p))
    if machine.role == nil or machine.role == "worker" or machine.role == "turtle" then
      turtleCount = turtleCount + 1
      if status.lost then lostCount = lostCount + 1 end
      if A.layers.turtles and p and A.sameDim(p.dim) and shown(id) then
        local key = "turtle:" .. id
        label(key, color, p, machine.label or ("#" .. id), "turtle", "turtle")
        local d = A.dirs[p.facing or p.f or 0]
        -- One outline per turtle: blue while it holds just its own cell, white when ok, the state
        -- colour for trouble (coral, amber, stale grey); the label always carries the state colour.
        local edge = (color == A.green or color == A.teal) and A.white or color
        for _, prefix in ipairs(prefixes) do
          local owner = prefix .. id
          local b = leases[owner]
          if b and b[1] == p.x and b[2] == p.y and b[3] == p.z and b[4] == p.x + 1 and b[5] == p.y + 1 and b[6] == p.z + 1 then
            merged[owner] = true
            if edge == A.white then edge = A.blue end
          end
        end
        local q = A.pad.turtle
        box(key .. ":box", edge, p.x - q, p.y - q, p.z - q, p.x + 1 + q, p.y + 1 + q, p.z + 1 + q)
        if d then chevron(key .. ":heading", edge, p, d) end
      end
    end
  end
  local mine = A.call("mine", "mapView") or {}
  if A.layers.turtles and A.sameDim(mine.dim) then
    for _, trail in ipairs(mine.trails or {}) do if shown(trail.id) then
      local a,b = trail.points[1],trail.points[2]
      local color = 0x507886A3
      if trail.state~="done" then
        local machine = machines[trail.id] or machines[tonumber(trail.id)] or {}
        local status = A.call("lease","peek",tonumber(trail.id) or trail.id) or {}
        color = A.turtle({state=trail.state,seen=machine.seen,fuel=machine.fuel},status,now,
          machine.pose and A.call("lease","inRange",tonumber(trail.id) or trail.id,machine.pose))
        if status.uncertain then color=A.red end
      end
      line("trail:"..trail.id, color, a.x+0.5,a.y+0.25,a.z+0.5,b.x+0.5,b.y+0.25,b.z+0.5)
    end end
  end
  if A.layers.leases and mine.preview and A.sameDim(mine.dim) and not only then
    local a,b = mine.preview[1],mine.preview[2]
    line("preview:branch", A.blue, a.x+0.5,a.y+0.5,a.z+0.5,b.x+0.5,b.y+0.5,b.z+0.5)
  end
  -- Lease outlines sit outside the turtle boxes, and a lease of just its turtle's cell merges
  -- into that turtle's box, so no edge lies on a block face or doubles another.
  for owner, bounds in pairs(leases) do
    if not merged[owner] then
      local q = A.pad.lease
      box("lease:" .. owner, A.blue, bounds[1] - q, bounds[2] - q, bounds[3] - q, bounds[4] + q, bounds[5] + q, bounds[6] + q)
    end
  end
  local drops = A.call("drops", "list") or {}
  local broken = 0
  for _,p in ipairs(drops) do if p.broken and not p.disabled and A.sameDim(p.dim) then broken=broken+1 end end
  if A.layers.drops then
    for _, p in ipairs(drops) do
      -- Broken chests keep their warning under any focus.
      if A.sameDim(p.dim) and (not only or p.broken and not p.disabled
        or only.kind == "drop" and not A.missing and p.id == only.id) then
        -- A room point that room sinks switch off draws grey and never gets a beam.
        local bad = p.broken and not p.disabled
        local key, color = "drop:" .. p.id, p.disabled and A.grey or bad and A.red or A.white
        box(key .. ":box", color, p.x + 0.2, p.y + 0.2, p.z + 0.2, p.x + 0.8, p.y + 0.8, p.z + 0.8)
        -- #n is the point's DROP POINTS row number.
        label(key, color, p, p.n and "#" .. p.n or p.kind:sub(1, 1):upper(), bad and "broken" or "drop", bad and "broken" or "drop:" .. p.kind)
      end
    end
  end
  -- Broken chests label first, so their beams survive the label limits.
  table.sort(labels, function(a, b)
    if (a.kind=="broken")~=(b.kind=="broken") then return a.kind=="broken" end
    return a.distance < b.distance or a.distance == b.distance and a.id < b.id
  end)
  local placed, counts = {}, {}
  for _, row in ipairs(labels) do
    local count = counts[row.group] or 0
    if count < (row.kind=="broken" and 4 or A.labelLimits[row.kind]) then
      counts[row.group] = count + 1
      if row.kind=="broken" then
        line(row.id..":beam", A.red, row.x,row.y-0.25,row.z,row.x,row.y+5.75,row.z)
      end
      local moved
      repeat
        moved = false
        for _, other in ipairs(placed) do
          if (row.x - other.x)^2 + (row.z - other.z)^2 <= 4 and math.abs(row.y - other.y) < A.labelGap - 0.000001 then
            row.y = other.y + A.labelGap
            moved = true
          end
        end
      until not moved
      placed[#placed + 1] = row
      put(row.id, "drawText3D", row.color, row.x, row.y, row.z, 0, 0, A.labelScale, row.text, true)
    end
  end
  local alertCount
  do
    local view = A.call("state", "view") or {}
    local state = SO.mods.state
    local history = state and state.history
    if history and type(history.page) == "function" then
      repeat
        local page = history.page({ from = A.cursor or 0, count = 50 })
        for _, event in ipairs(page.entries or {}) do
          A.cursor = event.seq
          if event.kind:match("%.alert$") then
            A.alerts[event.kind] = { at = event.seq, since = event.gameAt or event.at or now, expires = (event.gameAt or event.at or now) + A.alertMs }
          end
        end
      until not page.next
    end
    local alerts = {}
    for key, value in pairs(view.values or {}) do
      if type(key) == "string" and key:match("%.alert$") and value then
        local signature = SO.proto.ser(value)
        local old = A.alerts[key]
        if not old then A.serial = A.serial + 1 A.alerts[key] = { sig = signature, at = A.serial, since = now, expires = now + A.alertMs }
        elseif not history and old.sig ~= signature then
          A.serial = A.serial + 1 A.alerts[key] = { sig = signature, at = A.serial, since = now, expires = now + A.alertMs }
        end
        if key == "disk.alert" or now < A.alerts[key].expires then
          alerts[#alerts + 1] = { key = key, value = value, at = A.alerts[key].at, since = A.alerts[key].since }
        end
      end
    end
    table.sort(alerts, function(a, b)
      if (a.key == "disk.alert") ~= (b.key == "disk.alert") then return a.key == "disk.alert" end
      return a.at > b.at or (a.at == b.at and a.key < b.key)
    end)
    alertCount = #alerts
    -- A newer alert takes the flag back from one the player stepped to.
    local newest
    for _, a in ipairs(alerts) do newest = math.max(newest or a.since, a.since) end
    if newest and newest > (A.newest or -math.huge) then A.pick = nil end
    A.newest, A.active, A.shown = newest, alerts, nil
    local row, index = alerts[1], 1
    -- With the alerts layer off only the disk alert shows, so a stepped-to pick is ignored.
    for i, a in ipairs(alerts) do if A.layers.alerts and a.key == A.pick then row, index = a, i end end
    if row and (row.key == "disk.alert" or A.layers.alerts) then
      local text = tostring(type(row.value) == "table" and row.value.text or row.value)
      local count = #alerts > 1 and index .. "/" .. #alerts or ""
      A.shown = { key = row.key, text = text, i = index, n = #alerts }
      -- A route A flag: a coral ! and white text on the backing. The hairline flashes coral for
      -- 5 s, then dims; the flag stays while the alert is active.
      put("alert:backing", "drawRect2D", A.backing, A.hudX, hudTop, A.hudX + A.hudWidth, hudTop + 14)
      put("alert:rule", "drawRect2D", now - row.since < 5000 and A.red or A.hair, A.hudX, hudTop + 14, A.hudX + A.hudWidth, hudTop + 15)
      put("alert:mark", "drawText2D", A.red, A.hudX + 6, hudTop + 3, "!", false)
      put("alert:" .. row.key, "drawText2D", A.white, A.hudX + 14, hudTop + 3,
        text:sub(1, math.floor((A.hudWidth - 20) / 6) - (count ~= "" and #count + 1 or 0)), false)
      if count ~= "" then put("alert:count", "drawText2D", A.grey, A.hudX + A.hudWidth - 6 - #count * 6, hudTop + 3, count, false) end
      hudTop = hudTop + 16
    end
  end
  local capacity = fs and fs.getCapacity and fs.getCapacity("/")
  local free = fs and fs.getFreeSpace and fs.getFreeSpace("/")
  local ratio = type(capacity) == "number" and capacity > 0 and type(free) == "number" and (capacity - free) / capacity
  local cells = {
    { "turtles", "TURTLES", tostring(turtleCount), lostCount == 0 and A.white or A.red },
    { "alerts", "ALERTS", tostring(alertCount), alertCount > 0 and A.red or A.white },
    { "disk", "DISK", ratio and math.floor(ratio * 100) .. "%" or "?", ratio and (ratio >= 0.8 and A.red or A.white) or A.grey },
  }
  -- BROKEN takes its own row under the panel, so DISK stays in view.
  if broken>0 then cells[4]={"broken","BROKEN",tostring(broken),A.red} end
  -- One hairline-ruled panel on translucent navy: muted caps labels, white values, coral only for
  -- trouble. Cells are split by dim rules and the panel ends on a dim hairline. Rectangles never
  -- overlap, because the controller draws its elements in no fixed order.
  for i, cell in ipairs(cells) do
    local col, top = (i - 1) % 3, hudTop + math.floor((i - 1) / 3) * 29
    local id, x = "hud:" .. cell[1], A.hudX + col * A.hudCell
    put(id .. ":backing", "drawRect2D", A.backing, col > 0 and x + 1 or x, top, x + A.hudCell, top + 28)
    if col > 0 then put(id .. ":divider", "drawRect2D", A.hair, x, top, x + 1, top + 28) end
    put(id .. ":rule", "drawRect2D", A.hair, x, top + 28, x + A.hudCell, top + 29)
    put(id .. ":label", "drawText2D", A.grey, x + 6, top + 5, cell[2], false)
    put(id .. ":value", "drawText2D", cell[4], x + 6, top + 16, cell[3], false)
  end
  if retirement then
    put("alert:dug-storage", "drawText2D", A.red, A.hudX + 6, hudTop + 34 + (broken > 0 and 29 or 0), retirement.text, false)
  end
  return scene, machines
end
A.alerts, A.serial, A.failed = {}, 0, {}
A.draw = function(controller, scene)
  local ar, drawn = controller.ar, {}
  if (not controller.drawn or type(ar.delete) ~= "function") and type(ar.clear) == "function" then ar.clear() end
  for id, element in pairs(scene) do
    if element.method == "drawItemIcon3D" then
      if pcall(ar.drawItemIcon3D, id, unpack(element.args)) then drawn[id] = true end
    elseif element.method ~= "drawRect2D" or type(ar.drawRect2D) == "function" then
      ar[element.method](id, unpack(element.args))
      drawn[id] = true
    end
  end
  if type(ar.delete) == "function" then
    for id in pairs(controller.drawn or {}) do if not drawn[id] then ar.delete(id) end end
  end
  ar.update()
  controller.drawn = drawn
end
A.tick = function(now)
  local display = SO.mods.display
  if not A.wired and display and type(display.screen) == "function" then
    display.screen("ar", A.render, A.input)
    A.wired = true
  end
  if not A.foundAt or now - A.foundAt >= 5000 then
    A.foundAt = now
    local found = peripheral and type(peripheral.find) == "function" and { peripheral.find("ar_controller") } or {}
    local nextControllers = {}
    for _, ar in ipairs(found) do
      local name
      if type(peripheral.getName) == "function" then
        local ok, got = pcall(peripheral.getName, ar)
        if ok then name = got end
      end
      local old
      for _, controller in ipairs(A.controllers) do
        if controller.ar == ar or (name and controller.name == name) then old = controller break end
      end
      if old then old.ar = ar end
      nextControllers[#nextControllers + 1] = old or { ar = ar, name = name }
    end
    A.controllers = nextControllers
  end
  if #A.controllers == 0 or (A.frameAt and now - A.frameAt < 1000) then return end
  A.frameAt = now
  local scene, machines = A.scene(now)
  local sig = SO.proto.ser({ scene, machines })
  for i = #A.controllers, 1, -1 do
    local controller = A.controllers[i]
    if controller.sig ~= sig then
      local ok, err = pcall(A.draw, controller, scene)
      local name = controller.name or "ar_controller"
      if ok then controller.sig, A.failed[name] = sig, nil
      else
        table.remove(A.controllers, i)
        -- Discovery re-adds the controller in 5 s, so one failure is logged until a draw succeeds.
        if A.failed[name] ~= tostring(err) and type(SO.error) == "function" then
          SO.error("so-mod-ar: draw on " .. name .. " failed: " .. tostring(err))
        end
        A.failed[name] = tostring(err)
      end
    end
  end
end
return { name = "ar", handlers = {}, tick = A.tick }
