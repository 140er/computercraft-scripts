-- server.lua - the fleet server: the one place that knows and steers the whole fleet (CC: Tweaked)
-- server install: start on boot. server update: update this computer's scripts.
--
-- * Keeps the state of every bot and of the hub (the hub stores its state here).
-- * Orders from the hub go through here: the server sends them on, repeats them until
--   the turtle confirms (cmd_ack), and logs them.
-- * Passes on rednet messages for others (mesh), like the turtles do, so a bot out
--   of direct range is still reached through the bots in between.
-- * Hosts the code: bots without http fetch their scripts here (update.lua).
-- * A monitor (best: a big advanced one = touchscreen) shows the fleet: a list with
--   orders per turtle, a 3D view, the log and the code versions.
-- * An AR controller (cc_ar) next to it draws the fleet in the AR goggles.

local PROTOCOL = "fleetserver"
local BASE = "https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/"
local STATE_FILE, CODE_DIR = "server.state", "server-code"
local FILES = { "miner.lua", "hub.lua", "relay.lua", "smartmine.lua", "sorter.lua", "roomsorter.lua",
  "lumber.lua", "farmer.lua", "lava.lua", "builder.lua", "buddy.lua", "panel.lua", "factory.lua", "gpshost.lua",
  "server.lua", "install.lua", "update.lua", "fleetview.lua", "atomic.lua", "ssot.lua", "ssot-client.lua", "nav.lua", "mine-tasks.lua", "mining.lua", "warehouse-tasks.lua", "warehouse.lua", "store.lua" }
local BOTS = { minearmy = "miner", lumber = "lumber", farmer = "farmer", lava = "lava",
  builder = "builder", buddy = "buddy", roomsorter = "roomsorter", roomsorter_stock = "roomsorter",
  turtlefactory = "factory" }

local function read(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

local state, stateSource, stateExists
for _, path in ipairs({ STATE_FILE, STATE_FILE .. ".bak", STATE_FILE .. ".tmp" }) do
  stateExists=stateExists or fs.exists(path)
  local s = read(path)
  local ok, t = pcall(textutils.unserialize, s or "")
  if not ok then t = nil end
  if type(t) == "table" and (t.schema == nil or t.schema == 1)
    and (t.bots == nil or type(t.bots) == "table") and (t.log == nil or type(t.log) == "table")
    and (t.files == nil or type(t.files) == "table") then state, stateSource = t, path break end
end
if not state and stateExists then error("No valid server.state generation; preserve the files for recovery.",0) end
state = state or {}
state.schema = 1
state.bots, state.log, state.files = state.bots or {}, state.log or {}, state.files or {}
local function now() return os.epoch("utc") end
local function copy(value, parents)
  if type(value) ~= "table" then return value end
  parents = parents or {}
  if parents[value] then return nil end
  parents[value] = true
  local result = {}
  for k, v in pairs(value) do
    local key = copy(k, parents)
    if key ~= nil then result[key] = copy(v, parents) end
  end
  parents[value] = nil
  return result
end
local function log(kind, id, text)
  state.log[#state.log + 1] = { at = now(), kind = kind, id = id, text = tostring(text):sub(1, 256) }
  while #state.log > 200 do table.remove(state.log, 1) end
end

local diskFull = false
local function writeFile(path, text, cache)
  local tmp, backup, h = path .. ".tmp", path .. ".bak"
  local ok, err = pcall(function()
    if stateSource and stateSource ~= STATE_FILE and path == STATE_FILE then
      if fs.exists(path) then fs.delete(path) end
      fs.move(stateSource, path)
      stateSource = STATE_FILE
    end
    if fs.exists(tmp) then fs.delete(tmp) end
    if fs.exists(path) and fs.exists(backup) then fs.delete(backup) end
    local free = fs.getFreeSpace(path)
    if type(free) == "number" and free < #text + (cache and 65536 or 1024) then
      error("disk full: insufficient space", 0)
    end
    h = assert(fs.open(tmp, "w"), "Cannot write " .. tmp)
    h.write(text)
    h.close()
    h = nil
    assert(read(tmp) == text, "write verification failed")
    if path == STATE_FILE then
      local parsed = textutils.unserialize(read(tmp))
      assert(type(parsed) == "table" and parsed.schema == 1, "state verification failed")
    end
    if fs.exists(path) then
      fs.move(path, backup)
    end
    fs.move(tmp, path)
    local cleaned, cleanupError = true, nil
    if cache or path ~= STATE_FILE then cleaned, cleanupError = pcall(fs.delete, backup) end
    if not cleaned then
      diskFull = true
      log(cache and "code_error" or "state_error", nil, path .. ": " .. tostring(cleanupError))
    end
  end)
  if not ok then
    if h then pcall(h.close) end
    pcall(function()
      if fs.exists(backup) and not fs.exists(path) then fs.move(backup, path) end
    end)
    if stateSource ~= tmp then pcall(fs.delete, tmp) end
    diskFull = true
    log(cache and "code_error" or "state_error", nil, path .. ": " .. tostring(err))
  end
  return ok
end
local function save()
  local ok, text = pcall(function() return textutils.serialize(copy(state), { compact = true }) end)
  if ok then return writeFile(STATE_FILE, text) end
  log("state_error", nil, text)
  return false
end
local SSOT, ssot, ssotConfig
if fs.exists("ssot.lua") and fs.exists("atomic.lua") then
  local ok,lib=pcall(dofile,"ssot.lua")
  if ok and type(lib)=="table" then SSOT=lib end
end
if fs.exists("ssot.cfg") then
  assert(SSOT,"SSOT modules are missing or invalid")
  ssotConfig = assert(dofile("atomic.lua").read("ssot.cfg"), "invalid ssot.cfg")
  assert(type(ssotConfig) == "table" and type(ssotConfig.controllers) == "table", "invalid controllers")
  ssot = SSOT.open(ssotConfig)
end

local args = { ... }
if args[1] == "install" then
  if writeFile("startup.lua", 'shell.run("server")\n') then
    print("Server will now start automatically on boot.")
  else
    print("Could not install startup: disk full or write failed.")
    save()
  end
  return
elseif args[1] == "update" then
  if not fs.exists("update.lua") then shell.run("wget", BASE .. "update.lua", "update.lua") end
  shell.run("update")
  return
end

local function trimStatus(p)
  local t = {}
  for _, k in ipairs({ "type", "label", "phase", "state", "status", "lastError", "lastErrorAt", "hash",
    "x", "y", "z", "fuel", "free", "ore", "branch", "step", "level", "branchLen", "reach", "role", "facing" }) do
    local v = p[k]
    if type(v) == "string" then t[k] = v:sub(1, 256)
    elseif type(v) == "number" or type(v) == "boolean" then t[k] = v end
  end
  for _, k in ipairs({ "gps", "pos", "shaft" }) do
    if type(p[k]) == "table" then
      t[k] = {}
      for _, axis in ipairs({ "x", "y", "z", "bottom" }) do
        if type(p[k][axis]) == "number" then t[k][axis] = p[k][axis] end
      end
    end
  end
  if type(p.items) == "table" then
    t.items = {}
    local n = 0
    for name, count in pairs(p.items) do
      if type(name) == "string" and #name <= 256 and type(count) == "number" and n < 16 then
        t.items[name], n = count, n + 1
      end
    end
  end
  return t
end
while #state.log > 200 do table.remove(state.log, 1) end
for _, e in ipairs(state.log) do e.text = tostring(e.text):sub(1, 256) end
for _, b in pairs(state.bots) do if b.status then b.status = trimStatus(b.status) end end

local function yieldWork()
  os.queueEvent("server_work")
  os.pullEvent("server_work")
end
local function hashOf(text)
  local h = 5381
  for i = 1, #text do
    h = (h * 33 + text:byte(i)) % 4294967296
    if i%16384==0 then yieldWork() end
  end
  return string.format("%08x", h)
end

local known = {}
local function cacheOp(op, ...)
  local ok, err = pcall(op, ...)
  if not ok then diskFull = true log("code_error", nil, err) end
  return ok
end
local cacheOK, cacheFiles = pcall(function() fs.makeDir(CODE_DIR) return fs.list(CODE_DIR) end)
if not cacheOK then diskFull = true log("code_error", nil, cacheFiles) end
for _, f in ipairs(cacheOK and cacheFiles or {}) do
  if f:match("%.tmp$") then cacheOp(fs.delete, CODE_DIR .. "/" .. f) end
end
for _, f in ipairs(FILES) do
  known[f] = true
  local path = CODE_DIR .. "/" .. f
  if not fs.exists(path) and fs.exists(path .. ".bak") then cacheOp(fs.move, path .. ".bak", path) end
  local code, root = read(path), read(f)
  if root and root ~= "" and load(root, "=" .. f) and (not code or hashOf(root) == hashOf(code)) then
    code, path = root, f
    cacheOp(fs.delete, CODE_DIR .. "/" .. f)
  end
  local old = state.files[f]
  state.files[f] = nil
  if code and code ~= "" and load(code, "=" .. f) then
    cacheOp(fs.delete, CODE_DIR .. "/" .. f .. ".bak")
    state.files[f] = { hash = hashOf(code), size = #code, fetched = old and old.fetched or 0, path = path }
  end
  yieldWork()
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
    local root, path = read(f), CODE_DIR .. "/" .. f
    if root and hashOf(root) == hash then
      path = f
      cacheOp(fs.delete, CODE_DIR .. "/" .. f)
    elseif not state.files[f] or state.files[f].hash ~= hash or state.files[f].path ~= path
      or not fs.exists(path) then
      if not writeFile(path, code, true) then save() return end
      log("code", nil, f .. " " .. hash)
    end
    state.files[f] = { hash = hash, size = #code, fetched = now(), path = path }
  end
  save()
end

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Attach a wireless or ender modem to this computer.", 0) end
rednet.open(peripheral.getName(modem))
rednet.host(PROTOCOL, "server")

-- The 3D view and the AR picture (fleetview.lua, fetched when it is missing)
local function loadView()
  if not fs.exists("fleetview.lua") and shell and fs.exists("update.lua") then
    pcall(shell.run, "update", "fleetview.lua", "noreboot")
  end
  local chunk = loadfile and loadfile("fleetview.lua", "t", _ENV)
  local ok, lib = pcall(chunk or error)
  return ok and type(lib) == "table" and lib or nil
end
local V = loadView()

-- Mesh: pass on rednet messages meant for others, like CC's "repeat" program (each
-- message once), so a bot out of this server's range still hears it through the bots
-- in between, and the other way round. Turtles do the same (see miner.lua).
local function meshLoop()
  local relayed, count = {}, 0
  modem.open(rednet.CHANNEL_REPEAT)
  while true do
    local _, side, ch, replyCh, msg = os.pullEvent("modem_message")
    if ch == rednet.CHANNEL_REPEAT and type(msg) == "table" and type(msg.nMessageID) == "number"
      and msg.nMessageID>=0 and msg.nMessageID<=2147483647 and msg.nMessageID%1==0
      and type(msg.nRecipient) == "number" and msg.nRecipient>=0 and msg.nRecipient<=2147483647
      and msg.nRecipient%1==0 and type(replyCh)=="number" and replyCh>=0 and replyCh<=65535 and replyCh%1==0
      and (not SSOT or SSOT.bounded(msg,262144,true)) and not relayed[msg.nMessageID] then
      relayed[msg.nMessageID], count = os.clock() + 30, count + 1
      if count > 500 then
        for k, t in pairs(relayed) do if t < os.clock() then relayed[k], count = nil, count - 1 end end
      end
      local m = peripheral.wrap(side) or modem
      m.transmit(rednet.CHANNEL_REPEAT, replyCh, msg)
      m.transmit(msg.nRecipient == rednet.CHANNEL_BROADCAST and msg.nRecipient or msg.nRecipient % 65500, replyCh, msg)
    end
  end
end

local ar = peripheral.find("ar_controller")
if ar then pcall(function() ar.clear() ar.update() end) end
local arHub, arUntil, arDrawn = state.arHub, 0, false
local arSeen, arDirty, arLastDraw = now(), true, 0

local function toggle3D()
  state.view3D = state.view3D == false
  arDirty = true
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
  arDirty = true
  local err = p.lastError or p.err
  if err and err ~= b.error then log("error", id, err) end
  b.lastSeen, b.status, b.error = seen, trimStatus(p), type(err) == "string" and err:sub(1, 256) or nil
  b.position = copy(b.status.gps) or (b.status.x and b.status.z
    and { x = b.status.x, y = b.status.y, z = b.status.z })
  b.localPosition = copy(b.status.pos)
  b.hash = b.status.hash or b.hash
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

-- Orders on their way: [cid] = { target, protocol, message, tries, next }. Miners answer
-- with { type = "cmd_ack", cid }; until then the order goes out again every 3 seconds.
local outbox, cidSeq = {}, 0
local SWAPS = { go = "move", recall = "move", estop = "move" }
local function deliver(target, proto, p)
  local msg = copy(p)
  for cid, o in pairs(outbox) do
    local t = o.message.type
    if o.target == target and o.protocol == proto and (t == msg.type or (SWAPS[t] and SWAPS[t] == SWAPS[msg.type])) then
      outbox[cid] = nil
    end
  end
  if proto == "minearmy" then -- only the miners confirm orders
    cidSeq = cidSeq + 1
    msg.cid = cidSeq
    if ssot then msg.commandEpoch=ssot.epoch end
    outbox[cidSeq] = { target = target, protocol = proto, message = msg, tries = 1, next = now() + 3000 }
  end
  rednet.send(target, msg, proto)
end

local function retryOrders()
  for cid, o in pairs(outbox) do
    if now() >= o.next then
      if o.tries >= 6 then
        outbox[cid] = nil
        log("command", o.target, "no answer to " .. tostring(o.message.type) .. " (out of range or unloaded?)")
        save()
      else
        o.tries, o.next = o.tries + 1, now() + 3000
        rednet.send(o.target, o.message, o.protocol)
      end
    end
  end
end

local function request(id, m)
  if SSOT and (not SSOT.bounded(m,262144,true)
    or #textutils.serialize(copy(m),{compact=true})>262144) then return end
  if m.type == "ssot" then
    if ssot then
      local r, err = ssot.handle(id, m)
      if r then rednet.send(id, r, PROTOCOL) end
      if err then log("ssot_error", id, err) end
    end
    return
  end
  if ssotConfig and
    (m.type == "hub_put" or m.type == "command" or m.type == "register" or m.type == "ar_toggle" or m.type == "ar_ready" or m.arClient)
    and not ssotConfig.controllers[tostring(id)] then return end
  if m.arClient == true and (m.type == "hub_get" or m.type == "hub_put") then
    arHub = id
    arUntil = 0
    arDirty = true
    if state.arHub ~= id then state.arHub = id save() end
  end
  if id == arHub then arSeen = now() end
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
    local code = info and (read(info.path) or read(info.path .. ".bak"))
    if code and hashOf(code) ~= info.hash then code = nil end
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
    arDirty = true
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
    arDirty = true
    local b = bot(id, "hub", "minearmy")
    b.lastSeen = now()
    b.assignments = { target = m.hub.target, overrides = copy(m.hub.overrides), bores = copy(m.hub.bores) }
    for tid, t in pairs(m.turtles) do
      if type(tid) == "number" and type(t) == "table" and type(t.p) == "table" and t.p.type == "status"
        and type(t.age) == "number" and t.age >= 0 and t.age < math.huge then
        status(tid, t.p, "minearmy", now() - math.max(0, t.age) * 1000)
        local ore = (m.hub.overrides or {})[tid]
        if ore == nil then ore = m.hub.target end
        state.bots[tid].assignment = { ore = ore, recall = m.hub.recallAll, bore = copy((m.hub.bores or {})[tid]) }
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
    if m.direct then -- an older hub that already reached the bots itself
    elseif m.target then deliver(m.target, m.protocol, p)
    else
      -- Everyone: one broadcast for bots the server does not know (yet), and to each
      -- miner it knows its own copy, repeated until that miner confirms.
      rednet.broadcast(p, m.protocol)
      if m.protocol == "minearmy" then
        local forgotten = state.hub and state.hub.state and state.hub.state.forgotten or {}
        for bid, b in pairs(state.bots) do
          if b.kind == "miner" and not forgotten[bid] and now() - (b.lastSeen or 0) < 600000 then
            deliver(bid, m.protocol, p)
          end
        end
      end
    end
    reply(id, m, { type = "ack" })
  elseif m.type == "view" then
    -- The fleet for 3D views (pocket panel): every bot with where it is and how it does
    local forgotten = state.hub and state.hub.state and state.hub.state.forgotten
    reply(id, m, { type = "view", bots = V and V.fromServer(state.bots, now(), forgotten) or {},
      hubPos = state.hub and state.hub.state and state.hub.state.pos, nolib = V == nil })
  end
end

local function forgottenList() return state.hub and state.hub.state and state.hub.state.forgotten end

local arMem = {} -- what the goggles show now (fleetview keeps it, to delete what is gone)
local function draw3D()
  -- A saved hub gets the same bounded grace as a hub that stops talking.
  if arHub and now() - arSeen > 20000 then
    arHub, state.arHub = nil, nil
    save()
  end
  if not ar or not V then return end
  -- Stop before the hub's 15-second fallback, including when replies are lost.
  if arHub and now() >= arUntil then
    if arDrawn then pcall(function() V.arClear(ar, arMem) end) end
    arDrawn, arMem.drawn = false, nil
    return
  end
  if arDrawn and not arDirty and now() - arLastDraw < 5000 then return end
  local ok = pcall(function()
    V.ar(ar, V.fromServer(state.bots, now(), forgottenList()), state.view3D ~= false, arMem, "Fleet")
    arDrawn = true
    arDirty, arLastDraw = false, now()
  end)
  if not ok then
    pcall(function() ar.clear() ar.update() end)
    ar = nil
    arDrawn, arMem.drawn = false, nil
  end
end

---------------------------------------------------------------------------
-- Screen: a touch dashboard on the biggest monitor (or this computer's screen)
---------------------------------------------------------------------------
local hubPanel = nil -- the hub's last panel_state: ores, target, its turtles
local ui = { tab = "fleet", sel = nil, scroll = 0, buttons = {}, cam = V and V.camera(), hits = {}, note = nil,
  noteUntil = 0, ctl = {} }

local function pickScreen()
  local best, size
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local m = peripheral.wrap and peripheral.wrap(name) or peripheral.find("monitor")
      if m and m.isColor and m.isColor() then
        local w, h = m.getSize()
        if not size or w * h > size then best, size = m, w * h end
      end
    end
  end
  best = best or peripheral.find("monitor")
  if best and best.setTextScale then
    -- Text as big as the monitor allows while the dashboard still fits (57 x 24 or more)
    for _, sc in ipairs({ 2, 1.5, 1, 0.5 }) do
      best.setTextScale(sc)
      local w, h = best.getSize()
      if w >= 57 and h >= 24 then break end
    end
  end
  return best or term.native(), best ~= nil
end
local screen, touchable = pickScreen()
local plannerHost
if ssot and ssot.plan and ssotConfig and ssotConfig.planner == true and fs.exists("planner-host.lua") then
  local loaded, Host = pcall(dofile, "planner-host.lua")
  if loaded and type(Host) == "table" and type(Host.attach) == "function" then
    local opened, host = pcall(Host.attach, { ssot = ssot, screen = screen, clock = now })
    if opened then plannerHost = host
    else log("error", os.getComputerID(), "planner: " .. tostring(host)) end
  elseif not loaded then
    log("error", os.getComputerID(), "planner: " .. tostring(Host))
  end
end

local function note(text)
  ui.note, ui.noteUntil = text, now() + 6000
end

local function hubId()
  local h = state.hub and state.hub.id
  for id, b in pairs(state.bots) do
    if b.kind == "hub" and (not h or (b.lastSeen or 0) > ((state.bots[h] or {}).lastSeen or 0)) then h = id end
  end
  return h
end

-- Orders from the touchscreen go to the hub like the pocket panel's (it plans the jobs);
-- the hub then sends them to the turtles through this server.
local function hubOrder(msg, what)
  local h = hubId()
  if not h then note("No hub found: start hub.lua on the hub computer") return end
  msg.type, msg.rid = "panel", "server"
  if ui.sel and state.bots[ui.sel] and state.bots[ui.sel].kind == "miner" then msg.turtle = ui.sel end
  rednet.send(h, msg, "minearmy")
  log("command", os.getComputerID(), "screen: " .. what .. (msg.turtle and (" #" .. msg.turtle) or " (all)"))
  note(what .. (msg.turtle and (" for #" .. msg.turtle) or " for the whole fleet"))
end

local function text(x, y, s, fg, bg)
  screen.setCursorPos(x, y)
  if bg then screen.setBackgroundColor(bg) end
  if fg then screen.setTextColor(fg) end
  screen.write(s)
end
local function fill(x, y, w, bg)
  if w > 0 then text(x, y, string.rep(" ", w), nil, bg) end
end
local function button(x, y, label, fg, bg, action)
  text(x, y, " " .. label .. " ", fg, bg)
  ui.buttons[#ui.buttons + 1] = { x, y, x + #label + 1, action }
  return x + #label + 3
end

local function botName(id, b)
  local p = b.status or {}
  return tostring(p.label or (b.kind or "bot") .. " #" .. id)
end

local function botState(id, b)
  local p = b.status or {}
  local age = (now() - (b.lastSeen or 0)) / 1000
  if tostring(p.phase or p.state):lower() == "lost" or tostring(p.status):find("^LOST") then
    return "LOST", colors.red
  elseif age > 15 then return "stale", colors.gray end
  if b.error and tostring(p.status):find("^STUCK") then return "STUCK", colors.orange end
  return tostring(p.status or p.state or p.phase or "online"), colors.lime
end

local function counts()
  local online, stale, lost = 0, 0, 0
  for id, b in pairs(state.bots) do
    local s = botState(id, b)
    if s == "LOST" then lost = lost + 1 elseif s == "stale" then stale = stale + 1 else online = online + 1 end
  end
  return online, stale, lost
end

local function sortedBots()
  local list = {}
  local forgotten = forgottenList() or {}
  for id, b in pairs(state.bots) do
    if b.kind ~= "client" and not (b.kind == "miner" and forgotten[id]) then list[#list + 1] = id end
  end
  local rank = { hub = 1, miner = 2 }
  table.sort(list, function(a, b)
    local ra, rb = rank[state.bots[a].kind] or 3, rank[state.bots[b].kind] or 3
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  return list
end

local function ago(ms)
  local s = math.floor(math.max(0, now() - (ms or 0)) / 1000)
  if s < 60 then return s .. "s" elseif s < 3600 then return math.floor(s / 60) .. "m" end
  return math.floor(s / 3600) .. "h"
end

local function view3D(x0, y0, w, h)
  if not V then
    text(x0 + 1, y0 + 1, "fleetview.lua is missing: run 'update fleetview.lua'", colors.orange, colors.black)
    return
  end
  local scene = V.scene(V.fromServer(state.bots, now(), forgottenList()),
    { selected = ui.sel, places = { state.hub and state.hub.state and state.hub.state.pos
      and { x = state.hub.state.pos.x, y = state.hub.state.pos.y, z = state.hub.state.pos.z, name = "Hub",
        color = colors.white } or nil } })
  if scene.empty then
    for row = y0, y0 + h - 2 do fill(x0, row, w, colors.black) end
    text(x0 + 1, y0 + 1, "No bot has sent a position yet.", colors.lightGray, colors.black)
  else
    ui.hits = V.render(screen, x0, y0, w, h - 1, scene, ui.cam)
  end
  ui.ctl = V.controls(screen, x0, y0 + h - 1, w, ui.cam)
end

local function details(x0, y0, w, h)
  local id = ui.sel
  local b = id and state.bots[id]
  for row = y0, y0 + h - 1 do fill(x0, row, w, colors.black) end
  if not b then
    text(x0 + 1, y0, "Tap a bot for its details.", colors.lightGray, colors.black)
    text(x0 + 1, y0 + 1, "Orders without one go to the whole fleet.", colors.lightGray, colors.black)
    return
  end
  local p = b.status or {}
  local s, sc = botState(id, b)
  local lines = {
    { botName(id, b) .. "  (" .. tostring(b.kind) .. " #" .. id .. ")", colors.white },
    { "State: " .. s, sc },
  }
  if b.error then lines[#lines + 1] = { "Error: " .. b.error, colors.red } end
  local at = b.position
  if at then lines[#lines + 1] = { "At " .. tostring(at.x) .. " " .. tostring(at.y) .. " " .. tostring(at.z)
    .. (p.facing and (" facing " .. p.facing) or ""), colors.lightGray } end
  if p.fuel then lines[#lines + 1] = { "Fuel " .. tostring(p.fuel) .. (p.free and ("  free slots " .. p.free) or ""),
    colors.lightGray } end
  if p.ore then lines[#lines + 1] = { "Mining " .. tostring(p.ore) .. (p.level and (" at y " .. p.level) or "")
    .. (p.branch and ("  branch " .. p.branch) or ""), colors.lightGray } end
  local a = b.assignment
  if a and a.ore ~= nil then lines[#lines + 1] = { "Hub order: " .. tostring(a.ore == false and "stay home" or a.ore)
    .. (a.recall and " (recalled)" or ""), colors.lightGray } end
  lines[#lines + 1] = { "Last heard " .. ago(b.lastSeen) .. " ago", colors.lightGray }
  local file = b.kind and state.files[b.kind .. ".lua"]
  if b.hash and file then
    lines[#lines + 1] = b.hash == file.hash and { "Code up to date", colors.lime }
      or { "Code outdated: " .. tostring(b.hash) .. " (new " .. file.hash .. ")", colors.orange }
  end
  for k, l in ipairs(lines) do
    if k > h then break end
    text(x0 + 1, y0 + k - 1, l[1]:sub(1, w - 1), l[2], colors.black)
  end
end

local function drawFleet(x0, y0, w, h)
  local list = sortedBots()
  text(x0, y0, ("%-18s %-8s %-6s %s"):format("Name", "Kind", "Seen", "State"):sub(1, w), colors.yellow, colors.gray)
  fill(x0 + math.min(w, 50), y0, w - 50, colors.gray)
  local rows = h - 1
  ui.scroll = math.max(0, math.min(ui.scroll, #list - rows))
  for r = 1, rows do
    local id = list[r + ui.scroll]
    local y = y0 + r
    if id then
      local b = state.bots[id]
      local s, sc = botState(id, b)
      local bg = id == ui.sel and colors.blue or colors.black
      fill(x0, y, w, bg)
      text(x0, y, ("%-18s %-8s %-6s "):format(botName(id, b):sub(1, 18), tostring(b.kind):sub(1, 8), ago(b.lastSeen)),
        colors.white, bg)
      text(x0 + 34, y, s:sub(1, math.max(0, w - 34)), sc, bg)
      ui.buttons[#ui.buttons + 1] = { x0, y, x0 + w - 1, function() ui.sel = ui.sel ~= id and id or nil end }
    else
      fill(x0, y, w, colors.black)
    end
  end
  if #list > rows then
    text(x0 + w - 3, y0, "^", colors.white, colors.gray)
    ui.buttons[#ui.buttons + 1] = { x0 + w - 3, y0, x0 + w - 3, function() ui.scroll = ui.scroll - rows + 1 end }
    text(x0 + w - 1, y0, "v", colors.white, colors.gray)
    ui.buttons[#ui.buttons + 1] = { x0 + w - 1, y0, x0 + w - 1, function() ui.scroll = ui.scroll + rows - 1 end }
  end
end

local ORE_FALLBACK = { { key = "diamond", short = "Diamond" }, { key = "iron", short = "Iron" },
  { key = "gold", short = "Gold" }, { key = "redstone", short = "Redstone" }, { key = "lapis", short = "Lapis" },
  { key = "copper", short = "Copper" }, { key = "coal", short = "Coal" } }

-- Bottom bar: ores and the fleet orders (for the picked miner when one is picked)
local function orders(y, w)
  fill(1, y, w, colors.gray)
  fill(1, y + 1, w, colors.gray)
  local x = 1
  local hp = hubPanel or {}
  for _, o in ipairs(type(hp.ores) == "table" and hp.ores or ORE_FALLBACK) do
    local label = tostring(o.short or o.label or o.key):sub(1, 9)
    if x + #label + 2 > w then break end
    local on = hp.target == o.key
    x = button(x, y, label, on and colors.black or colors.white, on and colors.lime or (o.color or colors.blue),
      function() hubOrder({ cmd = "target", ore = o.key }, "Mine " .. label) end) - 1
  end
  x = 1
  x = button(x, y + 1, "STOP", colors.white, colors.red, function() hubOrder({ cmd = "stop" }, "Stop") end)
  x = button(x, y + 1, "RECALL", colors.white, colors.orange, function() hubOrder({ cmd = "recall" }, "Recall") end)
  x = button(x, y + 1, "RESUME", colors.white, colors.green, function() hubOrder({ cmd = "resume" }, "Resume") end)
  local view = state.view3D ~= false
  x = button(x, y + 1, view and "AR: ON" or "AR: OFF", colors.black, view and colors.lime or colors.lightGray,
    function() toggle3D() end)
  if ui.sel then
    x = button(x, y + 1, "ALL", colors.black, colors.yellow, function() ui.sel = nil end)
  end
  local sel = ui.sel and state.bots[ui.sel]
  local who = sel and sel.kind == "miner" and ("orders: " .. botName(ui.sel, sel)) or "orders: whole fleet"
  if x + #who < w then text(w - #who, y + 1, who, colors.white, colors.gray) end
end

local function drawLog(x0, y0, w, h)
  for row = y0, y0 + h - 1 do fill(x0, row, w, colors.black) end
  local colours = { error = colors.red, code_error = colors.red, state_error = colors.red, command = colors.yellow,
    join = colors.lime, code = colors.lightBlue, start = colors.white }
  local row = y0
  for i = #state.log - ui.scroll, 1, -1 do
    local e = state.log[i]
    if row >= y0 + h then break end
    local ok, when = pcall(os.date, "%H:%M", math.floor((e.at or 0) / 1000))
    local line = (ok and type(when) == "string" and when or ago(e.at)) .. " " .. tostring(e.kind) .. " "
      .. (e.id and ("#" .. e.id .. " ") or "") .. tostring(e.text)
    text(x0 + 1, row, line:sub(1, w - 1), colours[e.kind] or colors.lightGray, colors.black)
    row = row + 1
  end
end

local function drawCode(x0, y0, w, h)
  for row = y0, y0 + h - 1 do fill(x0, row, w, colors.black) end
  local row = y0
  text(x0 + 1, row, ("Disk: %s bytes free%s"):format(tostring(fs.getFreeSpace(STATE_FILE)),
    diskFull and " | disk full" or ""), diskFull and colors.red or colors.lightGray, colors.black)
  row = row + 1
  for _, f in ipairs(FILES) do
    if row >= y0 + h then break end
    local info = state.files[f]
    local old = 0
    for _, b in pairs(state.bots) do
      if info and b.kind and b.kind .. ".lua" == f and b.hash and b.hash ~= info.hash then old = old + 1 end
    end
    local line = ("%-15s %s"):format(f, info and (info.hash .. "  " .. info.size .. " bytes"
      .. (info.fetched > 0 and ("  " .. ago(info.fetched) .. " ago") or "")) or "not cached")
    if old > 0 then line = line .. "  " .. old .. " bot(s) outdated" end
    text(x0 + 1, row, line:sub(1, w - 1), info and (old > 0 and colors.orange or colors.white) or colors.red, colors.black)
    row = row + 1
  end
end

local TABS = { { "fleet", "Fleet" }, { "3d", "3D" }, { "log", "Log" }, { "code", "Code" } }
local function draw()
  if plannerHost then plannerHost.draw() return end
  local w, h = screen.getSize()
  ui.buttons, ui.ctl, ui.hits = {}, {}, {}
  screen.setBackgroundColor(colors.black)
  screen.setTextColor(colors.white)
  screen.clear()
  -- Top: name, counts and tabs
  local online, stale, lost = counts()
  fill(1, 1, w, colors.blue)
  text(1, 1, "Fleet server #" .. os.getComputerID(), colors.white, colors.blue)
  local x = w + 1
  for k = #TABS, 1, -1 do
    local t = TABS[k]
    x = x - #t[2] - 2
    local on = ui.tab == t[1]
    text(x, 1, " " .. t[2] .. " ", on and colors.black or colors.white, on and colors.white or colors.lightBlue)
    local key = t[1]
    ui.buttons[#ui.buttons + 1] = { x, 1, x + #t[2] + 1, function() ui.tab, ui.scroll = key, 0 end }
    x = x - 1
  end
  local nfiles = 0
  for _ in pairs(state.files) do nfiles = nfiles + 1 end
  fill(1, 2, w, colors.black)
  text(1, 2, online .. " online / " .. stale .. " stale / ", colors.lightGray, colors.black)
  text(#(online .. " online / " .. stale .. " stale / ") + 1, 2, lost .. " LOST", lost > 0 and colors.red or colors.lightGray,
    colors.black)
  local hid = hubId()
  local right = tostring(fs.getFreeSpace(STATE_FILE)) .. " bytes free" .. (diskFull and " | disk full" or "")
    .. " | code " .. nfiles .. "/" .. #FILES .. (hid and (" | hub #" .. hid) or " | no hub")
    .. (ar and (" | AR " .. (state.view3D ~= false and "on" or "off")) or "")
  local left = #(online .. " online / " .. stale .. " stale / " .. lost .. " LOST") + 2
  right = right:sub(1, math.max(0, w - left))
  text(w - #right + 1, 2, right, diskFull and colors.red or colors.lightGray, colors.black)
  local top, bottom = 3, h - 2 -- rows for the tab's content
  if not touchable then bottom = h end
  if ui.tab == "fleet" then
    local rows = bottom - top + 1
    local dh = math.min(9, math.floor(rows / 3))
    if w >= 100 then -- wide: list and details left, 3D right
      local lw = math.floor(w * 0.45)
      drawFleet(1, top, lw, rows - dh)
      details(1, bottom - dh + 1, lw, dh)
      view3D(lw + 2, top, w - lw - 1, rows)
    else -- list, details, and the 3D view in what is left below them
      local lh = math.max(4, math.min(#sortedBots() + 1, math.floor(rows / 3)))
      if rows - lh - dh < 8 then lh = rows - dh end
      drawFleet(1, top, w, lh)
      details(1, top + lh, w, dh)
      if rows - lh - dh >= 8 then view3D(1, top + lh + dh, w, rows - lh - dh) end
    end
  elseif ui.tab == "3d" then
    view3D(1, top, w, bottom - top + 1)
  elseif ui.tab == "log" then
    drawLog(1, top, w, bottom - top + 1)
  else
    drawCode(1, top, w, bottom - top + 1)
  end
  if touchable then orders(h - 1, w) end
  if ui.note and now() < ui.noteUntil then
    fill(1, h, w, colors.yellow)
    text(2, h, ui.note:sub(1, w - 2), colors.black, colors.yellow)
  end
end

local function touch(x, y)
  for _, b in ipairs(ui.buttons) do
    if y == b[2] and x >= b[1] and x <= b[3] then b[4]() return true end
  end
  if V and ui.cam and V.tap(ui.cam, ui.ctl, x, y) then return true end
  for id, at in pairs(ui.hits or {}) do
    if y == at[2] and x >= at[1] and x <= at[1] + 6 then ui.sel = id return true end
  end
  return false
end

local function network()
  local timer = os.startTimer(1)
  local ticks = 0
  draw()
  draw3D()
  while true do
    local ev, id, m, proto = os.pullEvent()
    if ev == "rednet_message" and type(m) == "table" and type(id)=="number" and id>=0 and id<=2147483647
      and id%1==0 and (not SSOT or SSOT.bounded(m,262144,true)) then
      if proto == PROTOCOL then request(id, m)
      elseif proto == "minearmy" and m.type == "cmd_ack" then
        local o = outbox[m.cid]
        if o and o.target == id and (m.commandEpoch==nil or m.commandEpoch==o.message.commandEpoch) then outbox[m.cid] = nil end
      elseif BOTS[proto] and (not ssotConfig or ssotConfig.controllers[tostring(id)])
        and (m.type == "status" or tostring(m.type):match("_state$")
        or proto == "roomsorter_stock" or (proto == "turtlefactory" and m.state)) then
        if proto == "minearmy" and m.type == "panel_state" then hubPanel = m end
        status(id, m, proto)
        save()
      end
    elseif ev == "timer" and id == timer then
      ticks = ticks + 1
      if ticks % 15 == 5 then
        rednet.broadcast({ type = "panel" }, "minearmy")
        for _, p in ipairs({ "lumber", "farmer", "lava", "builder", "buddy", "turtlefactory" }) do
          rednet.broadcast({ cmd = "status" }, p)
        end
      end
      retryOrders()
      if V and ui.cam and (ui.tab == "3d" or ui.tab == "fleet") then V.tick(ui.cam) end
      -- The 3D view turns: redraw every second while it shows, else every 5 seconds
      if ticks % 5 == 0 or (ui.cam and ui.cam.auto and (ui.tab == "3d" or ui.tab == "fleet")) then
        draw()
      end
      draw3D()
      timer = os.startTimer(1)
    elseif ev == "monitor_touch" or ev == "mouse_click" then
      if plannerHost then plannerHost.touch(m, proto) draw()
      elseif touch(m, proto) then draw() end
    elseif ev == "char" and plannerHost then
      plannerHost.char(id) draw()
    elseif ev == "key" and plannerHost then
      plannerHost.key(id) draw()
    elseif ev == "mouse_scroll" then
      ui.scroll = ui.scroll + id
      draw()
    elseif ev == "char" and id == "v" then
      toggle3D()
      draw()
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      local prev = ar
      ar = peripheral.find("ar_controller")
      if prev and (not ar or peripheral.getName(prev) ~= peripheral.getName(ar)) then
        pcall(function() prev.clear() prev.update() end)
        arDrawn, arMem.drawn = false, nil
      end
      arDirty = true
      screen, touchable = pickScreen()
      if plannerHost then plannerHost.setScreen(screen) end
      draw()
    elseif ev == "monitor_resize" or ev == "term_resize" then
      screen, touchable = pickScreen()
      if plannerHost then plannerHost.setScreen(screen) end
      draw()
    end
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
-- A Tom's Peripherals GPU (tm_gpu) with bitmap monitors: the fleet in real 3D
local function gpuLoop()
  if not V then while true do os.pullEvent("gpu_never") end end
  V.gpuLoop(function() return V.fromServer(state.bots, now(), forgottenList()) end, function()
    local pos = state.hub and state.hub.state and state.hub.state.pos
    return { title = "Fleet", places = pos and { { x = pos.x, y = pos.y, z = pos.z, name = "Hub" } } or nil }
  end, function(text) log("error", os.getComputerID(), text) save() end)
end

local ok, err = pcall(parallel.waitForAny, network, refresh, meshLoop, gpuLoop)
if ar then pcall(function() ar.clear() ar.update() end) end
if not ok then error(err, 0) end
