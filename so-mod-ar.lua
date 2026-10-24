local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local A = {
  layers = { turtles = true, leases = true, drops = true, alerts = true },
  order = { "turtles", "leases", "drops", "alerts" }, controllers = {},
  alertMs = 300000, hudX = 4, hudY = 72, hudWidth = 192, hudCell = 64,
  labelScale = 0.5, labelGap = 0.25, labelLimits = { turtle = 16, drop = 8 },
  chevron = { tip = 0.75, back = 0.6, half = 0.2 },
  -- Route A palette as ARGB (docs/ui/SCHEMATIC-SPEC.md section 3): 0 white, 8 grey, c hair, f backing.
  white = 0xFFE6EAF2 - 2^32, grey = 0xFF7886A3 - 2^32, red = 0xFFFF6B5E - 2^32,
  green = 0xFF3DDC84 - 2^32, amber = 0xFFFFC24B - 2^32, blue = 0xFF5AB0FF - 2^32,
  teal = 0xFF2DD4BF - 2^32, hair = 0xFF28344D - 2^32, backing = 0xE00B111C - 2^32,
  dirs = { [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 },
    north = { 0, -1 }, east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 } },
  dimensions = { [0] = "minecraft:overworld", [-1] = "minecraft:the_nether", [1] = "minecraft:the_end" },
}

A.valid = function(value)
  if type(value) ~= "table" then return false end
  for _, layer in ipairs(A.order) do if type(value[layer]) ~= "boolean" then return false end end
  return true
end
A.box = SO.store.store("so-data/ar", A.valid)
if A.box.value then A.layers = SO.store.copy(A.box.value) end
A.config = SO.store.read("so-server.cfg") or {}
A.dim = A.config.arDim or A.config.pos and A.config.pos.dim or "minecraft:overworld"
if type(A.config.arLabelScale)=="number" then
  A.labelScale=math.max(0.5,math.min(0.7,A.config.arLabelScale))
  A.labelGap=math.max(A.labelGap,A.labelScale*0.5)
end
A.sameDim = function(dim)
  return (A.dimensions[dim] or dim or "minecraft:overworld") == (A.dimensions[A.dim] or A.dim)
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
A.gather = function()
  local count = 0
  for _ in pairs(A.controllers) do count = count + 1 end
  return { count = count, layers = SO.store.copy(A.layers) }
end
-- Route A (docs/ui/SCHEMATIC-SPEC.md section 26); docs/ui/schematic/ar.py is the twin.
-- Each layer is a leader row with its state word; a tap anywhere on the row toggles it.
A.layout = function(model, w, h)
  local C = U.canvas(w, h)
  local right = model.count .. (model.count == 1 and " controller" or " controllers")
  if #right + 14 > w then right = tostring(model.count) end
  C.bar("AR GOGGLES", {}, nil, right)
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
  return C.frame()
end
A.render = function(w,h)
  if not U then return A.legacyRender() end
  return A.layout(A.gather(),w or 57,h or 24)
end
A.input = function(event)
  if not event or A.layers[event.id] == nil then return end
  local nextLayers = SO.store.copy(A.layers)
  nextLayers[event.id] = not nextLayers[event.id]
  if A.box.save(nextLayers) then A.layers = nextLayers end
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
  local machines = SO.store.copy(A.call("state", "get", "machines") or {})
  local lumber = A.call("lumber", "mapView") or {}
  for id, worker in pairs(lumber.turtles or {}) do
    id = tostring(id)
    local machine = machines[id] or machines[tonumber(id)] or {}
    machine.role, machine.pose, machine.state = "worker", worker.pose, worker.state
    if machine.pose and machine.pose.dim == nil then machine.pose.dim = lumber.dim end
    machines[tonumber(id)], machines[id] = nil, machine
  end
  local lostCount, turtleCount = 0, 0
  for id, machine in pairs(machines) do
    local p = machine.pose
    local status = A.call("lease", "peek", tonumber(id) or id) or {}
    local color = A.turtle(machine, status, now, p and A.call("lease", "inRange", tonumber(id) or id, p))
    if machine.role == nil or machine.role == "worker" or machine.role == "turtle" then
      turtleCount = turtleCount + 1
      if status.lost then lostCount = lostCount + 1 end
      if A.layers.turtles and p and A.sameDim(p.dim) then
        local key = "turtle:" .. id
        label(key, color, p, machine.label or ("#" .. id), "turtle", "turtle")
        local d = A.dirs[p.facing or p.f or 0]
        box(key .. ":box", color, p.x - 0.05, p.y - 0.05, p.z - 0.05, p.x + 1.05, p.y + 1.05, p.z + 1.05)
        if d then chevron(key .. ":heading", color, p, d) end
      end
    end
  end
  local mine = A.call("mine", "mapView") or {}
  if A.layers.turtles and A.sameDim(mine.dim) then
    for _, trail in ipairs(mine.trails or {}) do
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
    end
  end
  if A.layers.leases and mine.preview and A.sameDim(mine.dim) then
    local a,b = mine.preview[1],mine.preview[2]
    line("preview:branch", A.blue, a.x+0.5,a.y+0.5,a.z+0.5,b.x+0.5,b.y+0.5,b.z+0.5)
  end
  if A.layers.leases then
    local owners = {}
    for id in pairs(machines) do owners["mine:" .. id], owners["lumber:" .. id] = true, true end
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
      if bounds then
        box("lease:" .. owner, A.blue, unpack(bounds))
      end
    end
  end
  local drops = A.call("drops", "list") or {}
  local broken = 0
  for _,p in ipairs(drops) do if p.broken and A.sameDim(p.dim) then broken=broken+1 end end
  if A.layers.drops then
    for _, p in ipairs(drops) do
      if A.sameDim(p.dim) then
        local key, color = "drop:" .. p.id, p.broken and A.red or A.white
        box(key .. ":box", color, p.x + 0.2, p.y + 0.2, p.z + 0.2, p.x + 0.8, p.y + 0.8, p.z + 0.8)
        label(key, color, p, p.kind:sub(1, 1):upper(), p.broken and "broken" or "drop", p.broken and "broken" or "drop:" .. p.kind)
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
    local row = alerts[1]
    if row and (row.key == "disk.alert" or A.layers.alerts and now - row.since < 5000) then
      local text = type(row.value) == "table" and row.value.text or row.value
      -- A route A flag: a coral ! and white text on the backing, over a coral hairline.
      put("alert:backing", "drawRect2D", A.backing, A.hudX, hudTop, A.hudX + A.hudWidth, hudTop + 14)
      put("alert:rule", "drawRect2D", A.red, A.hudX, hudTop + 14, A.hudX + A.hudWidth, hudTop + 15)
      put("alert:mark", "drawText2D", A.red, A.hudX + 6, hudTop + 3, "!", false)
      put("alert:" .. row.key, "drawText2D", A.white, A.hudX + 14, hudTop + 3,
        tostring(text):sub(1, math.floor((A.hudWidth - 20) / 6)), false)
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
  if broken>0 then cells[3]={"broken","BROKEN",tostring(broken),A.red} end
  -- One hairline-ruled panel on translucent navy: muted caps labels, white values, coral only for
  -- trouble. Cells are split by dim rules and the panel ends on a dim hairline. Rectangles never
  -- overlap, because the controller draws its elements in no fixed order.
  for i, cell in ipairs(cells) do
    local id, x = "hud:" .. cell[1], A.hudX + (i - 1) * A.hudCell
    put(id .. ":backing", "drawRect2D", A.backing, i > 1 and x + 1 or x, hudTop, x + A.hudCell, hudTop + 28)
    if i > 1 then put(id .. ":divider", "drawRect2D", A.hair, x, hudTop, x + 1, hudTop + 28) end
    put(id .. ":rule", "drawRect2D", A.hair, x, hudTop + 28, x + A.hudCell, hudTop + 29)
    put(id .. ":label", "drawText2D", A.grey, x + 6, hudTop + 5, cell[2], false)
    put(id .. ":value", "drawText2D", cell[4], x + 6, hudTop + 16, cell[3], false)
  end
  if retirement then
    put("alert:dug-storage", "drawText2D", A.red, A.hudX + 6, hudTop + 34, retirement.text, false)
  end
  return scene, machines
end
A.alerts, A.serial = {}, 0
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
      if pcall(A.draw, controller, scene) then controller.sig = sig
      else table.remove(A.controllers, i) end
    end
  end
end
return { name = "ar", handlers = {}, tick = A.tick }
