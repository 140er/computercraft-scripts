local A = {
  layers = { turtles = true, leases = true, drops = true, alerts = true },
  order = { "turtles", "leases", "drops", "alerts" }, controllers = {},
  alertMs = 300000,
  white = -1, grey = -6710887, red = -43691, cyan = -11141121,
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
A.render = function()
  local picture = { rows = { { text = "AR layers", fg = "0", bg = "f" } }, buttons = {} }
  for i, layer in ipairs(A.order) do
    local label = layer .. (A.layers[layer] and " on" or " off")
    picture.buttons[i] = { id = layer, x = 1, y = i + 1, w = #label, label = label }
  end
  picture.buttons[5] = { id = "generic", x = 1, y = 6, w = 7, label = "generic" }
  return picture
end
A.input = function(event)
  if not event or A.layers[event.id] == nil then return end
  local nextLayers = SO.store.copy(A.layers)
  nextLayers[event.id] = not nextLayers[event.id]
  if A.box.save(nextLayers) then A.layers = nextLayers end
end
A.scene = function(now)
  local scene = {}
  local function put(id, method, ...) scene[id] = { method = method, args = { ... } } end
  local retirement = A.call("cells", "retirement")
  if retirement then
    put("alert:dug-storage", "drawText2D", A.red, 4, 4,
      retirement.text .. (retirement.status == "pending" and " Choose allow or keep on a display." or ""), false)
  end
  local function line(id, color, x, y, z, u, v, w) put(id, "drawLine3D", color, x, y, z, u, v, w) end
  local function label(id, color, p, text)
    put(id, "drawText3D", color, p.x + 0.5, p.y + 1.6, p.z + 0.5, 0, 0, 3, text, true)
  end
  local function box(id, color, x, y, z, u, v, w)
    local corners = { { x, z }, { u, z }, { u, w }, { x, w } }
    for k, p in ipairs(corners) do
      local q = corners[k % 4 + 1]
      line(id .. ":" .. k, color, p[1], y, p[2], q[1], y, q[2])
      line(id .. ":" .. (k + 4), color, p[1], v, p[2], q[1], v, q[2])
      line(id .. ":" .. (k + 8), color, p[1], y, p[2], p[1], v, p[2])
    end
  end
  local machines = A.call("state", "get", "machines") or {}
  for id, machine in pairs(machines) do
    local p = machine.pose
    if A.layers.turtles and p and A.sameDim(p.dim) then
      local status = A.call("lease", "status", tonumber(id) or id) or {}
      local color = now - (machine.seen or 0) >= 120000 and A.grey
        or (status.lost and A.red or (status.open and A.cyan or A.white))
      local key = "turtle:" .. id
      label(key, color, p, (machine.name or machine.label or ("#" .. id)) .. "  " .. tostring(machine.fuel or "?"))
      box(key .. ":box", color, p.x - 0.05, p.y - 0.05, p.z - 0.05, p.x + 1.05, p.y + 1.05, p.z + 1.05)
      local d = A.dirs[p.facing or p.f or 0]
      if d then
        local x, y, z = p.x + 0.5, p.y + 0.5, p.z + 0.5
        local tx, tz = x + d[1] * 1.5, z + d[2] * 1.5
        line(key .. ":heading", color, x, y, z, tx, y, tz)
        for k, sign in ipairs({ -1, 1 }) do
          line(key .. ":heading:" .. k, color, tx, y, tz,
            tx - d[1] * 0.5 + sign * d[2] * 0.5, y, tz - d[2] * 0.5 - sign * d[1] * 0.5)
        end
      end
    end
    if A.layers.leases then
      for _, prefix in ipairs({ "mine:", "lumber:" }) do
        local owner, bounds = prefix .. id, nil
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
        if bounds then box("lease:" .. owner, A.cyan, unpack(bounds)) end
      end
    end
  end
  if A.layers.drops then
    for _, p in ipairs(A.call("drops", "list") or {}) do
      if A.sameDim(p.dim) then
        local key, color = "drop:" .. p.id, p.broken and A.red or A.white
        box(key .. ":box", color, p.x + 0.2, p.y + 0.2, p.z + 0.2, p.x + 0.8, p.y + 0.8, p.z + 0.8)
        label(key, color, p, p.kind .. " " .. p.id)
      end
    end
  end
  if A.layers.alerts then
    local view = A.call("state", "view") or {}
    local state = SO.mods.state
    local history = state and state.history
    if history and type(history.page) == "function" then
      repeat
        local page = history.page({ from = A.cursor or 0, count = 50 })
        for _, event in ipairs(page.entries or {}) do
          A.cursor = event.seq
          if event.kind:match("%.alert$") then
            A.alerts[event.kind] = { at = event.seq, expires = (event.at or now) + A.alertMs }
          end
        end
      until not page.next
    end
    local alerts = {}
    for key, value in pairs(view.values or {}) do
      if type(key) == "string" and key:match("%.alert$") then
        local signature = SO.proto.ser(value)
        local old = A.alerts[key]
        if not old then A.serial = A.serial + 1 A.alerts[key] = { sig = signature, at = A.serial, expires = now + A.alertMs }
        elseif not history and old.sig ~= signature then
          A.serial = A.serial + 1 A.alerts[key] = { sig = signature, at = A.serial, expires = now + A.alertMs }
        end
        if now < A.alerts[key].expires then
          alerts[#alerts + 1] = { key = key, value = value, at = A.alerts[key].at }
        end
      end
    end
    table.sort(alerts, function(a, b) return a.at > b.at or (a.at == b.at and a.key < b.key) end)
    for i = 1, math.min(8, #alerts) do
      local row = alerts[i]
      local text = type(row.value) == "table" and row.value.text or row.value
      put("alert:" .. row.key, "drawText2D", A.red, 4, 4 + (i - 1 + (retirement and 1 or 0)) * 10,
        row.key .. " " .. tostring(text), false)
    end
  end
  return scene
end
A.alerts, A.serial = {}, 0
A.draw = function(controller, scene)
  local ar, drawn = controller.ar, {}
  if (not controller.drawn or type(ar.delete) ~= "function") and type(ar.clear) == "function" then ar.clear() end
  for id, element in pairs(scene) do
    if element.method == "drawItemIcon3D" then
      if pcall(ar.drawItemIcon3D, id, unpack(element.args)) then drawn[id] = true end
    else
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
  local scene = A.scene(now)
  local sig = SO.proto.ser(scene)
  for i = #A.controllers, 1, -1 do
    local controller = A.controllers[i]
    if controller.sig ~= sig then
      if pcall(A.draw, controller, scene) then controller.sig = sig
      else table.remove(A.controllers, i) end
    end
  end
end
return { name = "ar", handlers = {}, tick = A.tick }
