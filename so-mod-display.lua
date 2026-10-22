-- so-mod-display.lua - one role per paired display, and the frames it is sent.

local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local D = {
  path = "so-display",
  gap = 4000,
  limit = 4096,
  order = { "shop", "mining", "status", "generic", "lumber", "ar" },
  known = {},
  box = nil,
  saved = { roles = {}, far = {} },
  screens = {},
  sessions = {},
  pictures = {},
  alertVersions = {},
  alertSequence = 0,
}

D.now = function() return os.epoch and os.epoch("utc") or 0 end

D.whole = function(n)
  return type(n) == "number" and n % 1 == 0 and n > 0
end

D.acceptSize = function(w, h)
  return D.whole(w) and D.whole(h) and w <= D.limit and h <= D.limit
end

D.roleOf = function(id)
  local role = D.saved.roles[tostring(id)]
  if role == "shop" or role == "mining" or role == "lumber" or role == "status" or role == "ar" then return role end
  return "generic"
end

D.setRole = function(id, role)
  local name = tostring(id)
  local old = D.saved.roles[name]
  local want = nil
  if role ~= "generic" then
    if not D.known[role] then return end
    want = role
  end
  if want == old then return end
  if want == nil then D.saved.roles[name] = nil else D.saved.roles[name] = want end
  local copy = { roles = {}, far = D.saved.far }
  for key, value in pairs(D.saved.roles) do copy.roles[key] = value end
  local ok = D.box.save(copy)
  if not ok then
    if old == nil then D.saved.roles[name] = nil else D.saved.roles[name] = old end
  end
end

D.far = function(id, on)
  if type(id) ~= "number" or id < 0 or id % 1 ~= 0 or type(on) ~= "boolean" then return false end
  local key = tostring(id)
  local copy = { roles = D.saved.roles, far = {} }
  for k, v in pairs(D.saved.far) do copy.far[k] = v end
  copy.far[key] = on or nil
  local ok, err = D.box.save(copy)
  if not ok then return false, err end
  D.saved = copy
  if D.sessions[id] then D.sessions[id].sent = -math.huge end
  return true
end

D.palette = U and U.palette or {
  [0] = 0xF2F4F8, 0xFFC24B, 0xE57FD8, 0x99B2F2,
  0xDEDE6C, 0x7FCC19, 0xF2B2CC, 0x1F2B45,
  0x8A97B5, 0x2DD4BF, 0xB69CFF, 0x5AB0FF,
  0x4A5468, 0x3DDC84, 0xFF6B5E, 0x0E1626,
}

D.compact = function(row)
  local runs = {}
  for x = 1, #row.text do
    local fg = #row.fg == 1 and row.fg or row.fg:sub(x, x)
    local bg = #row.bg == 1 and row.bg or row.bg:sub(x, x)
    local last = runs[#runs]
    if last and last[2] == fg and last[3] == bg then last[1] = last[1] + 1
    else runs[#runs + 1] = { 1, fg, bg } end
  end
  local compact = { text = row.text:gsub(" +$", ""), runs = runs }
  if #SO.proto.ser(compact) < #SO.proto.ser(row) then return compact end
  return row
end

D.session = function(id)
  local found = D.sessions[id]
  if found then return found end
  found = { sub = false, sent = 0 }
  D.sessions[id] = found
  return found
end

D.sig = function(rows, buttons)
  local ok, text = pcall(SO.proto.ser, { rows = rows, buttons = buttons })
  if ok and type(text) == "string" then return text end
  return ""
end

D.fit = function(picture, w, h)
  local rows = {}
  local src = type(picture.rows) == "table" and picture.rows or {}
  local n = #src
  if n > h then n = h end
  for i = 1, n do
    local row = src[i]
    local text, fg, bg = "", "0", "f"
    if type(row) == "table" then
      if type(row.runs) == "table" then
        local f, b, width = {}, {}, 0
        for _, run in ipairs(row.runs) do
          local count = math.min(run[1], w - width)
          if count > 0 then
            f[#f + 1], b[#b + 1] = string.rep(run[2], count), string.rep(run[3], count)
            width = width + count
          end
        end
        fg, bg = table.concat(f), table.concat(b)
        text = (row.text or "") .. string.rep(" ", math.max(0, width - #(row.text or "")))
      end
      if type(row.text) == "string" and not row.runs then text = row.text end
      if type(row.fg) == "string" and row.fg ~= "" then fg = row.fg end
      if type(row.bg) == "string" and row.bg ~= "" then bg = row.bg end
    end
    if #text > w then text = text:sub(1, w) end
    if #fg ~= 1 then fg = fg:sub(1, #text) end
    if #bg ~= 1 then bg = bg:sub(1, #text) end
    if fg == "" then fg = "0" end
    if bg == "" then bg = "f" end
    rows[i] = D.compact({ text = text, fg = fg, bg = bg })
  end
  local buttons = {}
  local srcB = type(picture.buttons) == "table" and picture.buttons or {}
  for i = 1, #srcB do
    local b = srcB[i]
    if type(b) == "table" and type(b.id) == "string" and D.whole(b.x) and D.whole(b.y) and D.whole(b.w)
      and b.y <= h and b.x <= w then
      local width = b.w
      if b.x + width - 1 > w then width = w - b.x + 1 end
      local label = type(b.label) == "string" and b.label or b.id
      buttons[#buttons + 1] = { id = b.id, x = b.x, y = b.y, w = width, label = label:sub(1, width),
        h = math.min(D.whole(b.h) and b.h or 1, h - b.y + 1) }
    end
  end
  return { rows = rows, buttons = buttons }
end

D.compose = function(role, w, h, session)
  local screen = D.screens[role]
  local picture
  if screen then
    local ok, got
    if U and role == "status" and session and screen.render == D.statusRender then ok, got = pcall(D.statusFrame, session, w, h, D.now())
    else ok, got = pcall(screen.render, w, h) end
    if ok and type(got) == "table" then picture = got end
  end
  if not picture then
    if role ~= "generic" and D.screens.generic then return D.compose("generic", w, h, session) end
    picture = { rows = { { text = "display", fg = "0", bg = "f" } }, buttons = {} }
  end
  local rows = type(picture.rows) == "table" and picture.rows or {}
  local buttons = type(picture.buttons) == "table" and picture.buttons or {}
  if role == "generic" then
    local copy, found = {}, {}
    for i, button in ipairs(buttons) do copy[i], found[button.id] = button, true end
    for _, button in ipairs({
      { id = "lumber", x = 1, y = 1, w = 6, label = "lumber" },
      { id = "ar", x = 8, y = 1, w = 2, label = "ar" },
    }) do
      if not found[button.id] then copy[#copy + 1] = button end
    end
    buttons = copy
  end
  local sig = D.sig({ rows = rows, palette = picture.palette }, buttons)
  local pictureKey = role .. ":" .. w .. "x" .. h
  local pictures = role == "status" and session and (session.pictures or {}) or D.pictures
  if role == "status" and session then session.pictures = pictures end
  local slot = pictures[pictureKey]
  if not slot then
    slot = { rev = 0, sig = "" }
    pictures[pictureKey] = slot
  end
  if sig ~= slot.sig then
    slot.rev = slot.rev + 1
    slot.sig = sig
  end
  local fitted = D.fit({ rows = rows, buttons = buttons }, w, h)
  fitted.palette = picture.palette
  fitted.rev = slot.rev
  fitted.role = role
  return fitted
end

D.drawn = function(id)
  local role = D.roleOf(id)
  if D.screens[role] then return role end
  return "generic"
end

D.sendFrame = function(id, now, force)
  local session = D.sessions[id]
  if not session or not session.w or not session.h then return end
  local key = SO.pair.key(id)
  if not key then return end
  local role = D.drawn(id)
  if U and role == "status" then D.model = D.gather() end
  local body = D.compose(role, session.w, session.h, session)
  body.scale = D.saved.far[tostring(id)] and 1 or 0.5
  local slot = (body.role == "status" and session.pictures or D.pictures)[body.role .. ":" .. session.w .. "x" .. session.h]
  local due = force or (now - session.sent >= D.gap) or session.roleSent ~= body.role
    or not slot or session.revSent ~= slot.rev
  if not due then return end
  local msg = SO.proto.build(key, "view.frame", body)
  local wire = SO.proto.encode(msg)
  while not wire do
    if #body.rows > 1 then body.rows[#body.rows] = nil
    elseif #body.buttons > 0 then body.buttons[#body.buttons] = nil
    else break end
    msg = SO.proto.build(key, "view.frame", body)
    wire = SO.proto.encode(msg)
  end
  if type(wire) ~= "table" then return end
  rednet.send(id, wire, "so")
  session.sent = now
  session.roleSent = body.role
  if slot then session.revSent = slot.rev end
end

D.register = function(role, render, input)
  if type(role) ~= "string" or role == "" then return end
  if type(render) ~= "function" then render = function() end end
  if type(input) ~= "function" then input = function() end end
  D.screens[role] = { render = render, input = input }
end

D.gather = function()
  local model = { time = os.date and os.date("!%H:%M", math.floor(D.now() / 1000)) or "",
    alerts = {}, log = {}, tiles = {}, oreShort = "no source", terminalSubs = {} }
  local state, lease, drops = SO.mods.state, SO.mods.lease, SO.mods.drops
  local view = {}
  if state then
    local fn, meta = state.view, type(state.view) == "table" and getmetatable(state.view)
    if type(fn) == "function" or (meta and type(meta.__call) == "function") then
      local ok, got = pcall(fn)
      if ok and type(got) == "table" then view = got end
    end
  end
  local machines = state and type(state.get) == "function" and state.get("machines") or {}
  local turtles, lost, leases = 0, 0, 0
  for id, machine in pairs(machines or {}) do
    if machine.role == "worker" or machine.role == "turtle" then
      turtles = turtles + 1
      local status = lease and type(lease.status) == "function" and lease.status(tonumber(id)) or {}
      if status.lost then lost = lost + 1 end
      if status.open then leases = leases + 1 end
    end
  end
  local keys = {}
  for key, value in pairs(view.values or {}) do
    if type(key) == "string" and key:match("%.alert$") and value then keys[#keys + 1] = key end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local value = view.values[key]
    local text = type(value) == "table" and tostring(value.text or value.reason or key) or tostring(value)
    local identity = key .. ":" .. SO.proto.ser(value)
    local version = D.alertVersions[key]
    if not version or version.key ~= identity then
      D.alertSequence = D.alertSequence + 1
      version = {key = identity, sequence = D.alertSequence}
      D.alertVersions[key] = version
    end
    model.alerts[#model.alerts + 1] = { key = identity, sequence = version.sequence, text = text,
      detail = type(value) == "table" and value.detail or nil, sub = type(value) == "table" and value.sub or nil }
  end
  table.sort(model.alerts, function(a, b) return a.sequence < b.sequence end)
  model.alert = model.alerts[#model.alerts] and model.alerts[#model.alerts].text
  local displays, stale = 0, 0
  for _, session in pairs(D.sessions) do
    if session.w then displays = displays + 1; if D.now() - session.sent > 10000 then stale = stale + 1 end end
  end
  local points = drops and type(drops.list) == "function" and drops.list() or {}
  local broken = 0
  for _, point in ipairs(points) do if point.broken then broken = broken + 1 end end
  local capacity = fs and fs.getCapacity and fs.getCapacity("/")
  local free = fs and fs.getFreeSpace and fs.getFreeSpace("/")
  local ratio = type(capacity) == "number" and capacity > 0 and type(free) == "number" and (capacity-free)/capacity
  local disk = ratio and tostring(math.floor(ratio*100)) .. "%" or "-"
  local diskSub = ratio and string.format("%.1f of %.0f MB",(capacity-free)/1000000,capacity/1000000) or "no source"
  model.okShort, model.lostShort = tostring(turtles-lost) .. " ok", tostring(lost) .. " lost"
  model.tiles = {
    {label="TURTLES",value=tostring(turtles),sub=model.okShort .. ", " .. model.lostShort,bg=lost > 0 and "e" or "d"},
    {label="LEASES",value=tostring(leases),sub="open now",bg="b"},
    {label="ALERTS",value=tostring(#model.alerts),sub=model.alert or "none",bg=#model.alerts > 0 and "e" or "d"},
    {label="ORE TODAY",value="-",sub="no source",bg="c"},
    {label="LOGS TODAY",value="-",sub="no source",bg="c"},
    {label="DISK",value=disk,sub=diskSub,bg=ratio and (ratio >= 0.8 and "e" or "d") or "c"},
    {label="DISPLAYS",value=tostring(displays),sub=stale > 0 and (stale .. " stale") or "all fresh",bg=stale > 0 and "1" or "d"},
    {label="DROPS",value=tostring(#points),sub=broken .. " broken",bg=broken > 0 and "1" or "d"},
    {label="PAIR",value="",sub="press P on server",bg="9"},
  }
  model.terminalSubs = {model.okShort, model.tiles[7].sub, diskSub, model.alert or "none"}
  for _, alert in ipairs(model.alerts) do model.log[#model.log + 1] = alert.text end
  return model
end

D.legacyStatus = function()
  local rows = { { text = "status", fg = "0", bg = "f" } }
  local state = SO.mods.state
  local view
  local viewFn = type(state) == "table" and state.view
  local viewMeta = type(viewFn) == "table" and getmetatable(viewFn)
  if type(viewFn) == "function"
      or (type(viewMeta) == "table" and type(viewMeta.__call) == "function") then
    local ok, got = pcall(state.view)
    if ok and type(got) == "table" then view = got end
  end
  if not view then
    rows[2] = { text = "no state", fg = "0", bg = "f" }
  else
    rows[2] = { text = "rev " .. tostring(view.rev or 0), fg = "0", bg = "f" }
    local keys = {}
    if type(view.values) == "table" then
      for key in pairs(view.values) do
        if type(key) == "string" then keys[#keys + 1] = key end
      end
    end
    table.sort(keys)
    for i = 1, #keys do
      local key = keys[i]
      rows[#rows + 1] = { text = key .. " " .. tostring(view.values[key]), fg = "0", bg = "f" }
    end
  end
  return {
    rows = rows,
    buttons = { { id = "generic", x = 9, y = 1, w = 7, label = "generic" } },
  }
end

D.statusRender = function(w, h)
  if not U then return D.legacyStatus() end
  return U.status(D.model or { tiles = {}, time = "" }, w, h)
end

D.statusFrame = function(session, w, h, now)
  local model = D.model
  session.alertSeen = session.alertSeen or {}
  local newest
  for _, alert in ipairs(model.alerts) do
    if not session.alertSeen[alert.key] then
      session.alertSeen[alert.key] = true
      newest = alert
    end
  end
  if newest and (not session.alertAt or now - session.alertAt >= 30000) then
    session.alertAt, session.alertUntil, session.takeover = now, now + 5000, newest
  end
  local copy = {}
  for k, v in pairs(model) do copy[k] = v end
  copy.page = session.page or 0
  if session.takeover and (session.showAlerts or now < (session.alertUntil or 0)) then
    copy.takeover = session.takeover
    return U.alert(copy, w, h)
  end
  return U.status(copy, w, h)
end

D.genericRender = function()
  local buttons = {}
  for i = 1, #D.order do
    local name = D.order[i]
    buttons[i] = { id = name, x = 1, y = i + 1, w = #name, label = name }
  end
  return {
    rows = { { text = "pick a role", fg = "0", bg = "f" } },
    buttons = buttons,
  }
end

D.hello = function(msg)
  local body = msg.body
  if type(body) ~= "table" or not D.acceptSize(body.w, body.h) then return end
  local session = D.session(msg.from)
  session.w = body.w
  session.h = body.h
  if session.sub then D.sendFrame(msg.from, D.now(), true) end
end

D.subscribe = function(msg)
  local session = D.session(msg.from)
  session.sub = true
  if session.w then D.sendFrame(msg.from, D.now(), true) end
end

D.once = function(msg, reply)
  local session = D.session(msg.from)
  local w = session.w or 1
  local h = session.h or 1
  local role = D.drawn(msg.from)
  if U and role == "status" then D.model = D.gather() end
  local body = D.compose(role, w, h, session)
  body.scale = D.saved.far[tostring(msg.from)] and 1 or 0.5
  reply("view.frame", body)
end

D.onInput = function(msg)
  local body = msg.body
  if type(body) ~= "table" or not D.whole(body.x) or not D.whole(body.y) then return end
  local id, text = body.id, body.text
  if type(id) == "string" and id ~= "" then
    text = nil
  elseif type(text) == "string" then
    id = nil
  else
    return
  end
  local drawn = D.drawn(msg.from)
  local session = D.session(msg.from)
  if drawn == "status" then
    if session.showAlerts or (session.alertUntil and D.now() < session.alertUntil) then
      session.alertUntil, session.showAlerts = 0, false
      id = "dismiss"
    elseif id == "alerts" then
      session.takeover = D.model and D.model.alerts[#D.model.alerts]
      session.showAlerts = session.takeover ~= nil
    elseif id == "next" then session.page = (session.page or 0) + 1
    elseif id == "mining" or id == "lumber" or id == "shop" then D.setRole(msg.from, id) end
  end
  local screen = D.screens[drawn]
  if drawn == "generic" and type(id) == "string" and D.known[id] then
    D.setRole(msg.from, id)
  elseif id == "generic" and D.roleOf(msg.from) ~= "generic" then
    D.setRole(msg.from, "generic")
  end
  local event = { id = id, x = body.x, y = body.y, role = drawn }
  if text ~= nil then event.text = text end
  if screen then pcall(screen.input, event) end
  local session = D.sessions[msg.from]
  if session and session.sub then D.sendFrame(msg.from, D.now(), true) end
end

D.tick = function(now)
  for id, session in pairs(D.sessions) do
    if session.sub and session.w then D.sendFrame(id, now, false) end
  end
end

D.load = function()
  for i = 1, #D.order do D.known[D.order[i]] = true end
  D.box = SO.store.store(D.path, function(v)
    if type(v) ~= "table" or type(v.roles) ~= "table" then return false end
    for _, role in pairs(v.roles) do
      if role ~= "shop" and role ~= "mining" and role ~= "lumber" and role ~= "status" and role ~= "ar" then return false end
    end
    if v.far ~= nil then
      if type(v.far) ~= "table" then return false end
      for _, on in pairs(v.far) do if type(on) ~= "boolean" then return false end end
    end
    return true
  end)
  D.saved = { roles = {}, far = {} }
  if D.box.value and type(D.box.value.roles) == "table" then
    for id, role in pairs(D.box.value.roles) do D.saved.roles[tostring(id)] = role end
  end
  if D.box.value and D.box.value.far then
    for id, on in pairs(D.box.value.far) do D.saved.far[tostring(id)] = on end
  end
  D.register("status", D.statusRender, function() end)
  D.register("generic", D.genericRender, function() end)
end

D.load()

return {
  name = "display",
  handlers = {
    hello = D.hello,
    ["view.sub"] = D.subscribe,
    ["view.get"] = D.once,
    input = D.onInput,
  },
  tick = D.tick,
  screen = D.register,
  far = D.far,
  palette = D.palette,
}
