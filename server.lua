-- server.lua - fleet state and code host (CC: Tweaked)
-- server install: start on boot. server update: update this computer's scripts.

local PROTOCOL = "fleetserver"
local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/"
local STATE_FILE, CODE_DIR = "server.state", "server-code"
local FILES = { "miner.lua", "hub.lua", "relay.lua", "smartmine.lua", "sorter.lua", "roomsorter.lua",
  "lumber.lua", "farmer.lua", "lava.lua", "builder.lua", "buddy.lua", "panel.lua", "factory.lua", "gpshost.lua",
  "server.lua", "install.lua", "update.lua" }
local BOTS = { minearmy = "miner", lumber = "lumber", farmer = "farmer", lava = "lava",
  builder = "builder", buddy = "buddy", roomsorter = "roomsorter", roomsorter_stock = "roomsorter",
  turtlefactory = "factory" }

local args = { ... }
if args[1] == "install" then
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("server")\n')
  h.close()
  print("Server will now start automatically on boot.")
  return
elseif args[1] == "update" then
  if not fs.exists("update.lua") then shell.run("wget", BASE .. "update.lua", "update.lua") end
  shell.run("update")
  return
end

local function read(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

local function writeFile(path, text)
  local tmp = path .. ".tmp"
  local h = assert(fs.open(tmp, "w"), "Cannot write " .. tmp)
  h.write(text)
  h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
end

local state
for _, path in ipairs({ STATE_FILE, STATE_FILE .. ".tmp" }) do
  local s = read(path)
  local t = s and textutils.unserialize(s)
  if type(t) == "table" then state = t break end
end
state = state or {}
state.bots, state.log, state.files = state.bots or {}, state.log or {}, state.files or {}
local function now() return os.epoch("utc") end
local function save() writeFile(STATE_FILE, textutils.serialize(state, { compact = true })) end
local function log(kind, id, text)
  state.log[#state.log + 1] = { at = now(), kind = kind, id = id, text = tostring(text) }
  while #state.log > 200 do table.remove(state.log, 1) end
end

local function hashOf(text)
  local h = 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

local known = {}
fs.makeDir(CODE_DIR)
for _, f in ipairs(FILES) do
  known[f] = true
  local code = read(CODE_DIR .. "/" .. f) or read(CODE_DIR .. "/" .. f .. ".tmp")
  local old = state.files[f]
  state.files[f] = nil
  if code and code ~= "" and load(code, "=" .. f) then
    writeFile(CODE_DIR .. "/" .. f, code)
    state.files[f] = { hash = hashOf(code), size = #code, fetched = old and old.fetched or 0 }
  end
end

local function mirror(f)
  if not http then return end
  local res, err = http.get(BASE .. f .. "?t=" .. now())
  local code = res and res.readAll()
  if res then res.close() end
  if not code or code == "" or not load(code, "=" .. f) then
    log("code_error", nil, f .. ": " .. tostring(err or "broken download"))
  else
    local hash = hashOf(code)
    if not state.files[f] or state.files[f].hash ~= hash then
      writeFile(CODE_DIR .. "/" .. f, code)
      log("code", nil, f .. " " .. hash)
    end
    state.files[f] = { hash = hash, size = #code, fetched = now() }
  end
  save()
end

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Attach a wireless or ender modem to this computer.", 0) end
rednet.open(peripheral.getName(modem))
rednet.host(PROTOCOL, "server")

local ar = peripheral.find("ar_controller")
local arHub, arUntil, arDrawn = state.arHub, 0, false

local function toggle3D()
  state.view3D = state.view3D == false
  save()
end

local function bot(id, kind, proto)
  local b = state.bots[id]
  if not b then
    b = { id = id }
    state.bots[id] = b
    log("join", id, kind)
  end
  b.kind, b.protocol = kind, proto
  return b
end

local function status(id, p, proto, seen)
  local kind = BOTS[proto]
  if not kind then return end
  if proto == "minearmy" and p.type ~= "status" and p.type ~= "panel_state" then return end
  if proto == "minearmy" and p.type == "panel_state" then kind = "hub" end
  local b = bot(id, kind, proto)
  seen = seen or now()
  if b.lastSeen and seen < b.lastSeen then return end
  local err = p.lastError or p.err
  if err and err ~= b.error then log("error", id, err) end
  b.lastSeen, b.status, b.error = seen, p, err
  b.position = p.gps or (p.x and p.z and { x = p.x, y = p.y, z = p.z })
  b.localPosition = p.pos
  b.hash = p.hash or b.hash
  if kind == "hub" and type(p.turtles) == "table" then
    for _, t in ipairs(p.turtles) do
      if type(t) == "table" and type(t.id) == "number" and type(t.age) == "number" then
        local packet = {}
        for k, v in pairs((state.bots[t.id] or {}).status or {}) do packet[k] = v end
        for k, v in pairs(t) do packet[k] = v end
        packet.type, packet.lastError, packet.err = "status", t.err, nil
        status(t.id, packet, "minearmy", now() - math.max(0, t.age) * 1000)
      end
    end
  end
end

local function reply(id, m, r)
  r.rid = m.rid
  r.arOwner, r.view3D = ar ~= nil, state.view3D ~= false
  rednet.send(id, r, PROTOCOL)
end

local function request(id, m)
  if m.arClient == true and (m.type == "hub_get" or m.type == "hub_put") then
    arHub = id
    arUntil = 0
    if state.arHub ~= id then state.arHub = id save() end
  end
  if id == arHub and (m.type == "ar_ready" or m.type == "hub_put")
    and type(m.arUntil) == "number" and m.arUntil == m.arUntil then
    arUntil = math.min(m.arUntil, now() + 10000)
  end
  if m.type == "get" and known[m.file] then
    local offset = m.offset or 0
    if type(offset) ~= "number" or offset < 0 or offset % 1 ~= 0 then return end
    local info = state.files[m.file]
    if offset == 0 and not info then mirror(m.file) end
    info = state.files[m.file]
    local code = info and read(CODE_DIR .. "/" .. m.file)
    local b = state.bots[id] or bot(id, "client", PROTOCOL)
    local kind = m.file:gsub("%.lua$", "")
    if b.kind == "client" and kind ~= "install" and kind ~= "update" then b.kind = kind end
    b.lastSeen = now()
    b.versions = b.versions or {}
    b.versions[m.file] = m.hash
    save()
    if not code then reply(id, m, { type = "file", file = m.file, error = "not cached" }) return end
    reply(id, m, { type = "file", file = m.file, hash = info.hash, size = #code, offset = offset,
      current = m.hash == info.hash, code = m.hash ~= info.hash and code:sub(offset + 1, offset + 12000) or nil })
  elseif m.type == "ar_ready" and id == arHub then
    reply(id, m, { type = "ack" })
  elseif m.type == "ar_toggle" then
    if ar then toggle3D() end
    reply(id, m, { type = "ack" })
  elseif m.type == "list" then
    reply(id, m, { type = "versions", files = state.files })
  elseif m.type == "state" or m.type == "hub_get" then
    reply(id, m, { type = "state", bots = state.bots, hub = state.hub, files = state.files, log = state.log })
  elseif m.type == "register" and type(m.kind) == "string" then
    local b = bot(id, m.kind, PROTOCOL)
    b.lastSeen = now()
    save()
    reply(id, m, { type = "ack" })
  elseif m.type == "hub_put" and type(m.hub) == "table" and type(m.turtles) == "table"
    and type(m.hub.overrides) == "table" and type(m.hub.bores) == "table"
    and type(m.hub.progress) == "table" and type(m.hub.totals) == "table" then
    state.hub = { id = id, state = m.hub, updated = now() }
    local b = bot(id, "hub", "minearmy")
    b.lastSeen = now()
    b.assignments = { target = m.hub.target, overrides = m.hub.overrides, bores = m.hub.bores }
    for tid, t in pairs(m.turtles) do
      if type(tid) == "number" and type(t) == "table" and type(t.p) == "table" and t.p.type == "status"
        and type(t.age) == "number" and t.age >= 0 and t.age < math.huge then
        status(tid, t.p, "minearmy", now() - math.max(0, t.age) * 1000)
        local ore = (m.hub.overrides or {})[tid]
        if ore == nil then ore = m.hub.target end
        state.bots[tid].assignment = { ore = ore, recall = m.hub.recallAll, bore = (m.hub.bores or {})[tid] }
      end
    end
    save()
    reply(id, m, { type = "ack" })
  elseif m.type == "command" and BOTS[m.protocol] and type(m.message) == "table"
    and (m.target == nil or (type(m.target) == "number" and m.target % 1 == 0 and m.target >= 0)) then
    local p = m.message
    -- Code and developer operations stay on their existing channels, including pairing checks.
    if p.type == "dev" or p.key or p.code then return end
    log("command", id, m.protocol .. " " .. tostring(p.cmd or p.type) .. " -> " .. tostring(m.target or "all"))
    if m.target then
      local b = bot(m.target, BOTS[m.protocol], m.protocol)
      b.assignment = { by = id, at = now(), message = p }
    end
    save()
    if m.target then rednet.send(m.target, p, m.protocol) else rednet.broadcast(p, m.protocol) end
    reply(id, m, { type = "ack" })
  end
end

local function coordinate(n)
  return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function draw3D()
  if not ar then return end
  -- Stop before the hub's 15-second fallback, including when replies are lost.
  if arHub and now() >= arUntil then
    if arDrawn then pcall(function() ar.clear() ar.update() end) end
    arDrawn = false
    return
  end
  local ok = pcall(function()
    ar.clear()
    local view3D = state.view3D ~= false
    ar.drawText2D("view", (view3D and 0x55FF55 or 0x999999) - 0x1000000, 4, 4,
      view3D and "3D: AAN" or "3D: UIT", false)
    local directions = { north = { 0, -1 }, east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 } }
    local hub = state.hub and state.hub.state or {}
    for id, b in pairs(view3D and state.bots or {}) do
      local p = b.status or {}
      if b.kind == "miner" and not (hub.forgotten and hub.forgotten[id])
        and coordinate(p.x) and coordinate(p.y) and coordinate(p.z) then
        local key = "turtle:" .. id
        local trouble = p.phase == "lost" or tostring(p.status):find("^LOST")
          or tostring(p.status):find("^STUCK") or tostring(p.status):find("^ERROR")
        local stale = now() - (b.lastSeen or 0) > 15000
        local color = stale and 0x999999 or (trouble and 0xFF5555 or 0x55FFFF)
        color = color - 0x1000000 -- Opaque ARGB as a signed Java int.
        local x, y, z = p.x + 0.5, p.y + 0.5, p.z + 0.5
        local s = p.shaft
        local top = type(s) == "table" and coordinate(s.x) and coordinate(s.y) and coordinate(s.z)
        local sx, sy, sz = top and s.x + 0.5 or x, top and s.y or p.y, top and s.z + 0.5 or z
        ar.drawText3D(key, color, sx, sy + 3, sz, 0, 0, 6, "#" .. id, true)
        if trouble then
          local err = tostring(p.lastError or p.status or "LOST"):sub(1, 40)
          ar.drawText3D(key .. ":error", color, sx, sy + 1.8, sz, 0, 0, 2, err, true)
        end
        if top and (p.x ~= s.x or p.y ~= s.y or p.z ~= s.z) then
          ar.drawText3D(key .. ":position", color, x, y, z, 0, 0, 2, "#" .. id, true)
          if p.x ~= s.x or p.z ~= s.z then
            ar.drawLine3D(key .. ":path", color, sx, y, sz, x, y, z)
          end
        end
        local heading = directions[p.facing]
        if heading then
          local dx, dz = heading[1], heading[2]
          local tx, tz = x + dx * 1.5, z + dz * 1.5
          ar.drawLine3D(key .. ":heading", color, x, y, z, tx, y, tz)
          ar.drawLine3D(key .. ":heading:1", color, tx, y, tz, tx - dx * 0.5 - dz * 0.5, y, tz - dz * 0.5 + dx * 0.5)
          ar.drawLine3D(key .. ":heading:2", color, tx, y, tz, tx - dx * 0.5 + dz * 0.5, y, tz - dz * 0.5 - dx * 0.5)
        end
        if top and coordinate(s.bottom) then
          ar.drawLine3D(key .. ":shaft", stale and color or -1, sx, sy + 2.5, sz, sx, s.bottom, sz)
          local d = directions[type(p.role) == "string" and p.role:match("^[^@]+") or ""]
          if d and coordinate(p.level) and coordinate(p.reach) and p.reach > 0
            and coordinate(p.branchLen) and p.branchLen > 0 then
            local dx, dz = d[1], d[2]
            local width = math.min(p.branchLen, p.reach)
            local x1, z1 = sx + dx * p.reach, sz + dz * p.reach
            local x2, z2 = x1 - dz * width, z1 + dx * width
            local x3, z3 = sx - dz * width, sz + dx * width
            local y = p.level
            ar.drawLine3D(key .. ":region:1", color, sx, y, sz, x1, y, z1)
            ar.drawLine3D(key .. ":region:2", color, x1, y, z1, x2, y, z2)
            ar.drawLine3D(key .. ":region:3", color, x2, y, z2, x3, y, z3)
            ar.drawLine3D(key .. ":region:4", color, x3, y, z3, sx, y, sz)
          end
        end
      end
    end
    ar.update()
    arDrawn = true
  end)
  if not ok then
    pcall(function() ar.clear() ar.update() end)
    ar = nil
    arDrawn = false
  end
end

local function draw()
  local screen = peripheral.find("monitor") or term.native()
  local w, h = screen.getSize()
  screen.setBackgroundColor(colors.black)
  screen.setTextColor(colors.white)
  screen.clear()
  local online, stale, lost, nfiles = 0, 0, 0, 0
  for _, b in pairs(state.bots) do
    local p = b.status or {}
    if tostring(p.phase or p.state):lower() == "lost" then lost = lost + 1
    elseif now() - (b.lastSeen or 0) > 15000 then stale = stale + 1
    else online = online + 1 end
  end
  for _ in pairs(state.files) do nfiles = nfiles + 1 end
  local lines = { "Fleet server #" .. os.getComputerID(),
    online .. " online / " .. stale .. " stale / " .. lost .. " LOST",
    "Code: " .. nfiles .. "/" .. #FILES .. " main files",
    "server.lua: " .. ((state.files["server.lua"] or {}).hash or "not cached") }
  for i = #state.log, 1, -1 do
    local e = state.log[i]
    if e.kind == "error" or e.kind == "code_error" then
      lines[#lines + 1] = tostring(e.id or "code") .. ": " .. e.text
      if #lines >= h then break end
    end
  end
  for i = 1, math.min(h, #lines) do screen.setCursorPos(1, i) screen.write(lines[i]:sub(1, w)) end
  draw3D()
end

local function network()
  local timer = os.startTimer(1)
  local ticks = 0
  draw()
  while true do
    local ev, id, m, proto = os.pullEvent()
    if ev == "rednet_message" and type(m) == "table" then
      if proto == PROTOCOL then request(id, m)
      elseif BOTS[proto] and (m.type == "status" or tostring(m.type):match("_state$")
        or proto == "roomsorter_stock" or (proto == "turtlefactory" and m.state)) then
        status(id, m, proto)
        save()
      end
      draw3D()
    elseif ev == "timer" and id == timer then
      ticks = ticks + 1
      if ticks % 15 == 5 then
        rednet.broadcast({ type = "panel" }, "minearmy")
        for _, p in ipairs({ "lumber", "farmer", "lava", "builder", "buddy", "turtlefactory" }) do
          rednet.broadcast({ cmd = "status" }, p)
        end
      end
      if ticks % 5 == 0 then draw() else draw3D() end
      timer = os.startTimer(1)
    elseif ev == "char" and id == "v" then
      toggle3D()
      draw()
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      local prev = ar
      ar = peripheral.find("ar_controller")
      if prev and (not ar or peripheral.getName(prev) ~= peripheral.getName(ar)) then
        pcall(function() prev.clear() prev.update() end)
        arDrawn = false
      end
      draw()
    elseif ev == "monitor_resize" or ev == "term_resize" then draw() end
  end
end

local function refresh()
  while true do
    for _, f in ipairs(FILES) do mirror(f) sleep(1) end
    sleep(300)
  end
end

log("start", os.getComputerID(), "server")
save()
parallel.waitForAny(network, refresh)
