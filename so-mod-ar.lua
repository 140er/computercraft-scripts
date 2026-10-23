local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local A = {
  layers = { turtles = true, leases = true, drops = true, alerts = true },
  order = { "turtles", "leases", "drops", "alerts" }, controllers = {},
  alertMs = 300000,
  labelScale = 0.5, labelGap = 0.25, labelLimits = { turtle = 16, drop = 8 },
  strands = 5, strandRadius = 0.02, thickLimit = 16,
  arrow = { start = 0.55, base = 1.2, tip = 1.65, half = 0.22, hatches = 24 },
  white = 0xFFF2F4F8 - 2^32, grey = 0xFF4A5468 - 2^32, red = 0xFFFF6B5E - 2^32,
  green = 0xFF3DDC84 - 2^32, amber = 0xFFFFC24B - 2^32, blue = 0xFF5AB0FF - 2^32,
  teal = 0xFF2DD4BF - 2^32, backing = 0xC00E1626 - 2^32,
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
A.dim = A.config.pos and A.config.pos.dim
A.sameDim = function(dim)
  return A.dim == nil or (A.dimensions[dim] or dim) == (A.dimensions[A.dim] or A.dim)
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
A.layout = function(model, w, h)
  local C = U.canvas(w,h)
  C.header("AR GOGGLES", model.count .. (model.count == 1 and " controller" or " controllers"))
  local cols = U.grid(w,h,2)
  if h < 16 then
    for i,layer in ipairs(A.order) do
      local y = i + 3
      local on = model.layers[layer]
      C.put(2,y,(layer:upper() .. " " .. (on and '1' or '0')):sub(1,math.max(0,w-2)))
      C.hit(layer,2,y,math.max(0,w-2),1)
    end
  else
    for i,layer in ipairs(A.order) do
      local col=cols[(i-1)%#cols+1]
      local height = h >= 24 and 7 or 6
      local y=4+math.floor((i-1)/#cols)*(height+1)
      local on=model.layers[layer]
      C.tile(col.x,y,col.w,layer:upper(),on and '1' or '0',on and 'layer on' or 'layer off',on and 'd' or 'c')
      C.hit(layer,col.x,y,col.w,height)
    end
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
  if retirement then
    put("alert:dug-storage", "drawText2D", A.red, 4, 4,
      retirement.text .. (retirement.status == "pending" and " Choose allow or keep on a display." or ""), false)
  end
  local origin = A.config.pos
  local function far(x, y, z)
    if not (origin and origin.x and origin.y and origin.z) then return 0 end
    return (x - origin.x)^2 + (y - origin.y)^2 + (z - origin.z)^2
  end
  local function label(id, color, p, text, kind, group)
    labels[#labels + 1] = { id = id, color = color, x = p.x + 0.5, y = p.y + 1.25,
      z = p.z + 0.5, text = text:sub(1, 8), kind = kind, group = group, distance = far(p.x, p.y, p.z) }
  end
  local shapes = {}
  local function shape(id, x, y, z, draw) shapes[#shapes + 1] = { id = id, distance = far(x, y, z), draw = draw } end
  local function stroke(id, color, n, x, y, z, u, v, w)
    put(id, "drawLine3D", color, x, y, z, u, v, w)
    if n < 2 then return end
    local dx, dy, dz = u - x, v - y, w - z
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len == 0 then return end
    dx, dy, dz = dx / len, dy / len, dz / len
    local px, py, pz = -dz, 0, dx
    if math.abs(dy) > 0.9 then px, py, pz = 1, 0, 0 end
    local plen = math.sqrt(px * px + pz * pz)
    px, pz = px / plen, pz / plen
    local qx, qy, qz = dy * pz - dz * py, dz * px - dx * pz, dx * py - dy * px
    for k = 2, n do
      local a = math.pi / 2 * (k - 2)
      local ox, oy, oz = A.strandRadius * (math.cos(a) * px + math.sin(a) * qx),
        A.strandRadius * (math.cos(a) * py + math.sin(a) * qy), A.strandRadius * (math.cos(a) * pz + math.sin(a) * qz)
      put(id .. ":s" .. k, "drawLine3D", color, x + ox, y + oy, z + oz, u + ox, v + oy, w + oz)
    end
  end
  local function box(id, color, thick, x, y, z, u, v, w)
    local n = thick and A.strands or 1
    local corners = { { x, z }, { u, z }, { u, w }, { x, w } }
    for k, p in ipairs(corners) do
      local q = corners[k % 4 + 1]
      stroke(id .. ":" .. k, color, n, p[1], y, p[2], q[1], y, q[2])
      stroke(id .. ":" .. (k + 4), color, n, p[1], v, p[2], q[1], v, q[2])
      stroke(id .. ":" .. (k + 8), color, n, p[1], y, p[2], p[1], v, p[2])
    end
  end
  local function arrow(id, color, thick, p, d)
    local x, y, z = p.x + 0.5, p.y + 0.5, p.z + 0.5
    local a = A.arrow
    local bx, bz = x + d[1] * a.base, z + d[2] * a.base
    local tx, tz = x + d[1] * a.tip, z + d[2] * a.tip
    stroke(id, color, thick and A.strands or 1, x + d[1] * a.start, y, z + d[2] * a.start, bx, y, bz)
    local sx, sz = -d[2] * a.half, d[1] * a.half
    put(id .. ":1", "drawLine3D", color, tx, y, tz, bx - sx, y, bz - sz)
    put(id .. ":2", "drawLine3D", color, tx, y, tz, bx + sx, y, bz + sz)
    if not thick then return end
    put(id .. ":3", "drawLine3D", color, tx, y, tz, bx, y - a.half, bz)
    put(id .. ":4", "drawLine3D", color, tx, y, tz, bx, y + a.half, bz)
    for i = 0, a.hatches - 1 do
      local t = i / a.hatches
      local hx, hz, r = bx + (tx - bx) * t, bz + (tz - bz) * t, 1 - t
      put(id .. ":h" .. i, "drawLine3D", color, hx - sx * r, y, hz - sz * r, hx + sx * r, y, hz + sz * r)
      put(id .. ":v" .. i, "drawLine3D", color, hx, y - a.half * r, hz, hx, y + a.half * r, hz)
    end
  end
  local machines = A.call("state", "get", "machines") or {}
  local lostCount, turtleCount = 0, 0
  for id, machine in pairs(machines) do
    local p = machine.pose
    local status = A.call("lease", "status", tonumber(id) or id) or {}
    local color = A.turtle(machine, status, now, p and A.call("lease", "inRange", tonumber(id) or id, p))
    if machine.role == nil or machine.role == "worker" or machine.role == "turtle" then
      turtleCount = turtleCount + 1
      if status.lost then lostCount = lostCount + 1 end
      if A.layers.turtles and p and A.sameDim(p.dim) then
        local key = "turtle:" .. id
        label(key, color, p, "#" .. id, "turtle", "turtle")
        local d = A.dirs[p.facing or p.f or 0]
        shape(key, p.x, p.y, p.z, function(thick)
          box(key .. ":box", color, thick, p.x - 0.05, p.y - 0.05, p.z - 0.05, p.x + 1.05, p.y + 1.05, p.z + 1.05)
          if d then arrow(key .. ":heading", color, thick, p, d) end
        end)
      end
    end
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
        shape("lease:" .. owner, (bounds[1] + bounds[4]) / 2, (bounds[2] + bounds[5]) / 2, (bounds[3] + bounds[6]) / 2,
          function(thick) box("lease:" .. owner, A.blue, thick, unpack(bounds)) end)
      end
    end
  end
  if A.layers.drops then
    for _, p in ipairs(A.call("drops", "list") or {}) do
      if A.sameDim(p.dim) then
        local key, color = "drop:" .. p.id, p.broken and A.red or A.white
        shape(key, p.x, p.y, p.z, function(thick)
          box(key .. ":box", color, thick, p.x + 0.2, p.y + 0.2, p.z + 0.2, p.x + 0.8, p.y + 0.8, p.z + 0.8)
        end)
        label(key, color, p, p.kind:sub(1, 1):upper(), "drop", "drop:" .. p.kind)
      end
    end
  end
  table.sort(shapes, function(a, b) return a.distance < b.distance or a.distance == b.distance and a.id < b.id end)
  for i, row in ipairs(shapes) do row.draw(i <= A.thickLimit) end
  table.sort(labels, function(a, b) return a.distance < b.distance or a.distance == b.distance and a.id < b.id end)
  local placed, counts = {}, {}
  for _, row in ipairs(labels) do
    local count = counts[row.group] or 0
    if count < A.labelLimits[row.kind] then
      counts[row.group] = count + 1
      local moved
      repeat
        moved = false
        for _, other in ipairs(placed) do
          if (row.x - other.x)^2 + (row.z - other.z)^2 <= 4 and math.abs(row.y - other.y) < A.labelGap then
            row.y = other.y + A.labelGap
            moved = true
          end
        end
      until not moved
      placed[#placed + 1] = row
      put(row.id, "drawText3D", row.color, row.x, row.y, row.z, 0, 0, A.labelScale, row.text, true)
    end
  end
  local alertCount = 0
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
        if now < A.alerts[key].expires then
          alerts[#alerts + 1] = { key = key, value = value, at = A.alerts[key].at, since = A.alerts[key].since }
        end
      end
    end
    table.sort(alerts, function(a, b) return a.at > b.at or (a.at == b.at and a.key < b.key) end)
    alertCount = #alerts
    local row = alerts[1]
    local banners = false
    for _, controller in ipairs(A.controllers) do
      if type(controller.ar.drawRect2D) == "function" then banners = true break end
    end
    if A.layers.alerts and row and (not banners or now - row.since < 5000) then
      local text = type(row.value) == "table" and row.value.text or row.value
      local top = retirement and 12 or 0
      put("alert:backing", "drawRect2D", A.red, 0, top, 120, 14)
      put("alert:" .. row.key, "drawText2D", A.white, 4, 4 + top, tostring(text), false)
    end
  end
  local capacity = fs and fs.getCapacity and fs.getCapacity("/")
  local free = fs and fs.getFreeSpace and fs.getFreeSpace("/")
  local ratio = type(capacity) == "number" and capacity > 0 and type(free) == "number" and (capacity - free) / capacity
  local tiles = {
    { "turtles", "TURTLES", tostring(turtleCount), lostCount == 0 and A.green or A.red },
    { "alerts", "ALERTS", tostring(alertCount), alertCount > 0 and A.red or A.green },
    { "disk", "DISK", ratio and math.floor(ratio * 100) .. "%" or "?", ratio and (ratio >= 0.8 and A.red or A.green) or A.grey },
  }
  local hudTop = retirement and 12 or 0
  for i, tile in ipairs(tiles) do
    local id, x = "hud:" .. tile[1], 4 + (i - 1) * 64
    put(id .. ":backing", "drawRect2D", A.backing, x, 18 + hudTop, 56, 30)
    put(id .. ":bar", "drawRect2D", tile[4], x, 18 + hudTop, 56, 4)
    put(id .. ":label", "drawText2D", A.white, x + 4, 26 + hudTop, tile[2], false)
    put(id .. ":value", "drawText2D", A.white, x + 4, 36 + hudTop, tile[3], false)
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
