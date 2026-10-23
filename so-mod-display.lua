-- so-mod-display.lua - one role per paired display, and the frames it is sent.

local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local D = {
  path = "so-display",
  gap = 4000,
  limit = 4096,
  order = { "status", "pocket", "mining", "lumber", "shop", "generic", "ar", "panel", "map" },
  known = {},
  box = nil,
  saved = { roles = {}, far = {}, locked = {} },
  screens = {},
  sessions = {},
  pictures = {},
  alertVersions = {},
  alertSequence = 0,
}

D.now = function() return SO.now() end
D.self = function() return os.getComputerID and os.getComputerID() end

D.whole = function(n)
  return type(n) == "number" and n % 1 == 0 and n > 0
end

D.acceptSize = function(w, h)
  return D.whole(w) and D.whole(h) and w <= D.limit and h <= D.limit
end

-- Only pocket computers are 26 wide; older clients report 19 rows without fullH.
D.isPocket = function(session)
  return U and session and session.w == 26 and (session.h == 20 or session.h == 19) or false
end

-- The saved role wins. Before R1 pockets saved every navigation tap, so a
-- pocket keeps a saved role only once the server command set it (locked).
-- A pocket without one is a pocket; anything else shows its id.
D.roleOf = function(id)
  local key = tostring(id)
  local role, pocket = D.saved.roles[key], D.isPocket(D.sessions[id])
  if D.known[role] and (not pocket or D.saved.locked[key]) then return role end
  if pocket then return "pocket" end
  return "unassigned"
end

-- Operators know the drop-point list as drops; saved files keep "generic".
D.label = function(role) return role == "generic" and "drops" or role end

D.setRole = function(id, role)
  local name = tostring(id)
  local old = D.saved.roles[name]
  if role == old and (role == nil) == not D.saved.locked[name] then return true end
  local copy = { roles = {}, far = D.saved.far, locked = {} }
  for key, value in pairs(D.saved.roles) do copy.roles[key] = value end
  for key, value in pairs(D.saved.locked) do copy.locked[key] = value end
  copy.roles[name], copy.locked[name] = role, role and true or nil
  local ok, err = D.box.save(copy)
  if not ok then return false, err end
  D.saved = copy
  return true
end

D.isDisplay = function(id)
  if id == D.self() or D.saved.roles[tostring(id)] or (D.sessions[id] and D.sessions[id].w) then return true end
  local state = SO.mods.state
  local machines = state and type(state.get) == "function" and state.get("machines") or {}
  local row = type(machines) == "table" and (machines[id] or machines[tostring(id)])
  return type(row) == "table" and row.role == "display"
end

-- The only way a display changes role. Role nil or "-" clears it.
D.assign = function(id, role)
  if type(id) == "string" then id = tonumber(id) end
  if type(id) ~= "number" or id < 0 or id % 1 ~= 0 then return false, "bad display id" end
  if not D.isDisplay(id) then return false, "no display " .. id end
  if role == "-" then role = nil end
  if role == "drops" then role = "generic" end
  if role ~= nil and not D.known[role] then
    local names = {}
    for _, name in ipairs(D.order) do names[#names + 1] = D.label(name) end
    return false, "roles: " .. table.concat(names, " ")
  end
  if role ~= nil and role ~= "pocket" and not D.screens[role] then return false, D.label(role) .. " not loaded" end
  if role == "pocket" and not U then return false, "pocket needs so-ui.lua" end
  local ok, err = D.setRole(id, role)
  if not ok then return false, "save failed: " .. tostring(err) end
  -- The next tick sends the new role; the command itself never renders.
  local session = D.sessions[id]
  if session then session.pocketPage, session.page, session.sent = nil, nil, -math.huge end
  return true, "display " .. id .. ": " .. (role and D.label(role) or "cleared")
end

-- Parses the server terminal's "<id> <role>" or "<id> -".
D.command = function(text)
  local id, role = tostring(text or ""):lower():match("^%s*(%d+)%s+(%S+)%s*$")
  if not id then return false, "use <id> <role> or <id> -" end
  return D.assign(tonumber(id), role)
end

D.far = function(id, on)
  if type(id) ~= "number" or id < 0 or id % 1 ~= 0 or type(on) ~= "boolean" then return false end
  local key = tostring(id)
  local copy = { roles = D.saved.roles, far = {}, locked = D.saved.locked }
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
  found = { id = id, sub = false, sent = 0 }
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

D.retirement = function(w)
  local cells = SO.mods.cells
  local notice = cells and type(cells.retirement) == "function" and cells.retirement()
  if not notice then return end
  local rows, line = {}, ""
  for word in notice.text:gmatch("%S+") do
    if #line + #word + 1 > w and line ~= "" then
      rows[#rows + 1], line = { text=line, fg="0", bg="f" }, ""
    end
    line = line == "" and word or line .. " " .. word
  end
  if line ~= "" then rows[#rows + 1] = { text=line, fg="0", bg="f" } end
  local buttons = {}
  if notice.status == "pending" then
    rows[#rows + 1] = { text="", fg="0", bg="f" }
    for i, choice in ipairs({ "allow", "keep" }) do
      buttons[i] = { id="dug." .. choice .. "/" .. notice.id, label=choice, x=(i-1)*8+1, y=#rows, w=#choice }
    end
  end
  return { rows=rows, buttons=buttons }
end

-- A teal block with the display id in big digits, for displays without a role
-- and roles whose module is missing.
D.idFrame = function(w, h, id, title)
  if not U then
    return { rows = { { text = "display " .. tostring(id or "?"), fg = "0", bg = "f" },
      { text = title:lower(), fg = "0", bg = "f" } }, buttons = {} }
  end
  local c = U.canvas(w, h)
  c.header(title, "")
  local top = h >= 10 and 4 or 3
  local height = math.max(1, h - top)
  c.fill(2, top, math.max(0, w - 2), height, "9")
  if height >= 7 then c.put(3, top + 1, ("DISPLAY"):sub(1, math.max(0, w - 4))) end
  c.big(2, top + math.max(0, math.floor((height - 3) / 2)), math.max(0, w - 2), tostring(id or "?"), "9")
  return c.frame()
end

D.compose = function(role, w, h, session)
  local banner = D.retirement(w)
  local offset = banner and #banner.rows or 0
  local contentH = math.max(1, h - offset)
  local screen = D.screens[role]
  local picture
  if session then session.pocket = role == "pocket" end
  local glance = U and session and (role == "status" and screen and screen.render == D.statusRender
    or role == "pocket" and (session.pocketPage ~= "panel" or not D.screens.panel))
  if glance or (role == "pocket" and D.screens.panel) or (screen and role ~= "unassigned") then
    local ok, got
    if glance then
      D.model = D.model or D.gather()
      ok, got = pcall(D.statusFrame, session, w, contentH, D.now(), role == "pocket")
    elseif role == "pocket" then ok, got = pcall(D.screens.panel.render, w, contentH, session)
    else ok, got = pcall(screen.render, w, contentH, U and session or (session and session.id)) end
    if ok and type(got) == "table" then picture = got end
  end
  if not picture then
    picture = D.idFrame(w, contentH, session and session.id, role == "unassigned" and "UNASSIGNED" or D.label(role):upper())
  end
  local rows = type(picture.rows) == "table" and picture.rows or {}
  local buttons = type(picture.buttons) == "table" and picture.buttons or {}
  if banner then
    local combined, controls = {}, {}
    for i, row in ipairs(banner.rows) do combined[i] = row end
    for _, button in ipairs(banner.buttons) do controls[#controls + 1] = button end
    for i, row in ipairs(rows) do combined[i + offset] = row end
    for _, button in ipairs(buttons) do
      local moved = SO.store.copy(button)
      moved.y = moved.y + offset
      controls[#controls + 1] = moved
    end
    rows, buttons = combined, controls
  end
  local sig = D.sig({ rows = rows, palette = picture.palette }, buttons)
  local pictureKey = role .. ":" .. w .. "x" .. h
  local pictures = session and (session.pictures or {}) or D.pictures
  if session then session.pictures = pictures end
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

D.drawn = D.roleOf

D.sendFrame = function(id, now, force)
  local session = D.sessions[id]
  if not session or not session.w or not session.h then return end
  local key = SO.pair.key(id)
  if not key then return end
  local role = D.drawn(id)
  if U and (role == "status" or role == "pocket") then D.model = D.gather() end
  local body = D.compose(role, session.w, session.h, session)
  body.scale = D.saved.far[tostring(id)] and 1 or 0.5
  local slot = (session.pictures or D.pictures)[body.role .. ":" .. session.w .. "x" .. session.h]
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
  if render == nil and input == nil then return D.screens[role] end
  if type(role) ~= "string" or role == "" then return end
  if type(render) ~= "function" then render = function() end end
  if type(input) ~= "function" then input = function() end end
  D.screens[role] = { render = render, input = input }
end

D.gather = function()
  local model = { time = U and U.clock(os.epoch("utc")).hm or "",
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
    if machine.role == nil or machine.role == "worker" or machine.role == "turtle" then
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
  local daily = SO.mods.daily
  local today = daily and type(daily.today) == "function" and daily.today()
  model.tiles = {
    {label="TURTLES",value=tostring(turtles),sub=model.okShort .. ", " .. model.lostShort,bg=lost > 0 and "e" or "d"},
    {label="LEASES",value=tostring(leases),sub="open now",bg="b"},
    {label="ALERTS",value=tostring(#model.alerts),sub=model.alert or "none",bg=#model.alerts > 0 and "e" or "d"},
    {label="ORE TODAY",value=today and tostring(today.ore) or "-",sub=today and ("+" .. today.oreRecent .. " last 10 min") or "no source",bg=today and "b" or "c"},
    {label="LOGS TODAY",value=today and tostring(today.logs) or "-",sub=today and "logs delivered" or "no source",bg=today and "d" or "c"},
    {label="DISK",value=disk,sub=diskSub,bg=ratio and (ratio >= 0.8 and "e" or "d") or "c"},
    {label="DISPLAYS",value=tostring(displays),sub=stale > 0 and (stale .. " stale") or "all fresh",bg=stale > 0 and "1" or "d"},
    {label="DROPS",value=tostring(#points),sub=broken .. " broken",bg=broken > 0 and "1" or "d"},
    {label="PAIR",value="",sub="press P on server",bg="9"},
  }
  model.oreShort = model.tiles[4].sub
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
  return { rows = rows, buttons = {} }
end

D.statusRender = function(w, h)
  if not U then return D.legacyStatus() end
  return U.status(D.model or { tiles = {}, time = "" }, w, h)
end

D.statusFrame = function(session, w, h, now, pocket)
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
  if w == 26 and (h == 20 or pocket) then
    local indices = {1,3,4,2,5,6,7,8,9}
    local page = (session.page or 0) % math.max(1, math.ceil(#model.tiles / 2))
    local c = U.canvas(w, h)
    c.header("FLEET", copy.time)
    for i = 1, 2 do
      local index = indices[page * 2 + i]
      local tile = copy.tiles[index]
      if tile then
        local y = 4 + (i - 1) * 8
        if y + 7 > h then break end
        c.tile(1, y, w, tile.label, tile.value, index == 4 and copy.oreShort or tile.sub, tile.bg, 7)
        if index == 9 then
          c.fill(3, y + 2, w-4, 3, tile.bg)
          c.center(3, w-4, y + 3, "new client:")
        end
      end
    end
    c.fill(1, h, w, 1, "7")
    local panel = pocket and D.screens.panel
    c.put(2, h, "<  glance " .. (page + 1) .. "/" .. math.ceil(#model.tiles / 2) .. "  >" .. (panel and "  PANEL" or ""))
    c.hit("prev", 1, h, 3, 1)
    c.hit("next", 15, h, 3, 1)
    if panel then c.hit("panel", 19, h, 7, 1) end
    return c.frame()
  end
  return U.status(copy, w, h)
end

D.hello = function(msg)
  local body = msg.body
  if type(body) ~= "table" or not D.acceptSize(body.w, body.h) then return end
  local session = D.session(msg.from)
  session.keyboard = body.keyboard == true
  session.w = body.w
  session.h = U and D.acceptSize(body.w, body.fullH) and body.fullH or body.h
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
  if U and (role == "status" or role == "pocket") then D.model = D.gather() end
  local body = D.compose(role, w, h, session)
  body.scale = D.saved.far[tostring(msg.from)] and 1 or 0.5
  reply("view.frame", body)
end

D.consent = function(event, role, w, h, session)
  local cells = SO.mods.cells
  if not cells or type(cells.decideRetirement) ~= "function" then return end
  local frame = D.compose(role, w, h, session)
  for _, button in ipairs(frame.buttons) do
    if button.id == event.id and button.label == event.id:match("^dug%.(%a+)/")
      and #button.label == button.w and event.y == button.y
      and event.x >= button.x and event.x < button.x + button.w then
      local choice, token = event.id:match("^dug%.(%a+)/(.+)$")
      cells.decideRetirement(token, choice)
      return
    end
  end
end

-- Routes one tap or text inside the drawn role. Pages may change; the role never does.
D.handle = function(role, session, event, now)
  local glance = role == "status" or role == "pocket" and session.pocketPage ~= "panel"
  local screen = D.screens[role]
  if glance then
    if session.showAlerts or now < (session.alertUntil or 0) then
      session.alertUntil, session.showAlerts = 0, false
      event.id = "dismiss"
    elseif event.id == "alerts" then
      session.takeover = D.model and D.model.alerts[#D.model.alerts]
      session.showAlerts = session.takeover ~= nil
    elseif event.id == "next" then session.page = (session.page or 0) + 1
    elseif event.id == "prev" then session.page = (session.page or 0) - 1
    elseif event.id == "panel" and role == "pocket" and D.screens.panel then session.pocketPage = "panel" end
    if role == "pocket" then return end
  elseif role == "pocket" then
    if event.id == "glance" then session.pocketPage = nil return end
    screen = D.screens.panel
  end
  event.role, event.session = role, session
  if screen then pcall(screen.input, event) end
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
  -- A tap on the previous role's frame, sent before the new one arrived.
  if id and session.roleSent and session.roleSent ~= drawn then return end
  if id and id:match("^dug%.") then
    if not session.w then return end
    D.consent(body, drawn, session.w, session.h, session)
  else
    local event = { from = msg.from, id = id, x = body.x, y = body.y }
    if text ~= nil then event.text = text end
    D.handle(drawn, session, event, D.now())
  end
  if session.sub then D.sendFrame(msg.from, D.now(), true) end
end

D.paint = function(target, frame, w, h)
  if target.setPaletteColour then
    for i = 0, 15 do target.setPaletteColour(2^i, D.palette[i]) end
  end
  for y = 1, h do
    local row = frame.rows[y] or {text="", runs={{w,"0","f"}}}
    local fg, bg = {}, {}
    if row.runs then
      for _, run in ipairs(row.runs) do
        fg[#fg+1], bg[#bg+1] = string.rep(run[2],run[1]), string.rep(run[3],run[1])
      end
    else
      fg[1] = #row.fg == 1 and string.rep(row.fg,#row.text) or row.fg
      bg[1] = #row.bg == 1 and string.rep(row.bg,#row.text) or row.bg
    end
    fg, bg = table.concat(fg), table.concat(bg)
    local n = math.min(w,#fg)
    target.setCursorPos(1,y)
    target.blit((row.text .. string.rep(" ",w)):sub(1,w),
      fg:sub(1,n)..string.rep("0",w-n), bg:sub(1,n)..string.rep("f",w-n))
  end
  for _, button in ipairs(frame.buttons or {}) do
    local label = (button.label or ""):sub(1,math.min(button.w,w-button.x+1))
    if label ~= "" then
      target.setCursorPos(button.x,button.y)
      target.blit(label,string.rep("0",#label),string.rep("7",#label))
    end
  end
end

D.terminal = function(model, view, w, h)
  if not U and view.mode == "role" then
    local rows = { { text = "roles", fg = "0", bg = "f" } }
    for _, row in ipairs(view.displays or {}) do
      rows[#rows + 1] = { text = row.id .. " " .. (row.size or "-") .. " " .. row.role, fg = "0", bg = "f" }
    end
    rows[#rows + 1] = { text = tostring(view.notice or ""), fg = "0", bg = "f" }
    rows[#rows + 1] = { text = "> " .. tostring(view.input or "") .. "_", fg = "0", bg = "f" }
    return { rows = rows, buttons = {} }
  end
  if not U then return D.legacyStatus() end
  local C = U.canvas(w,h)
  C.header("SO SERVER #" .. tostring(view.id), view.mode == "code" and "pairing" or view.mode == "role" and "roles" or view.uptime)
  if view.hostError then C.put(1,2,view.hostError,"e") end
  local lines, first = view.log or {}, 10
  if view.mode == "code" then
    C.fill(1,3,w,math.max(0,h-6),"9")
    C.center(1,w,4,"PAIR CODE  (type it on the new client)","9")
    local code = tostring(view.code or "")
    C.big(1,7,w,code:sub(1,3).." "..code:sub(4,6),"9")
    local left = math.max(0,math.ceil((view.expires-view.now)/1000))
    C.center(1,w,12,string.format("%d:%02d left, works once",math.floor(left/60),left%60),"9")
    C.center(1,w,14,"5 wrong tries burn the code","9")
  elseif view.mode == "log" then
    C.fill(1,3,w,1,"7"); C.put(2,3,"FULL LOG")
    first = 4
  elseif view.mode == "role" then
    local notice, width = tostring(view.notice or ""), math.max(1,w-2)
    local noticeRows = #notice > width and 2 or 1
    local last = h-1-noticeRows
    local list = view.displays or {}
    C.fill(1,4,w,1,"7"); C.put(2,4,"ID    SIZE    ROLE")
    for i, row in ipairs(list) do
      if 4+i < last or (4+i == last and i == #list) then
        C.put(2,4+i,string.format("%-6s%-8s%s",tostring(row.id),row.size or "-",row.role):sub(1,width))
      elseif 4+i == last then
        C.put(2,4+i,"+" .. (#list-i+1) .. " more")
      end
    end
    for r = 1, noticeRows do C.put(2,h-1-noticeRows+r,notice:sub((r-1)*width+1,r*width)) end
  else
    local cols = U.grid(w,h,math.max(1,math.min(4,math.floor((w+1)/13))))
    local bottom = 7
    for i, index in ipairs({1,7,6,3}) do
      local col = cols[(i-1)%#cols+1]
      local y = 4 + math.floor((i-1)/#cols)*8
      local t = model.tiles[index]
      if t then C.tile(col.x,y,col.w,t.label,t.value,(model.terminalSubs or {})[i] or t.sub,t.bg,7) end
      bottom = math.max(bottom,y+6)
    end
    first = bottom+3
    C.fill(1,first-1,w,1,"7"); C.put(2,first-1,"LOG")
  end
  if view.mode ~= "code" and view.mode ~= "role" then
    local count = math.max(0,h-first)
    local last = math.max(0,#lines-(view.offset or 0))
    local start = math.max(1,last-count+1)
    for i = start,last do C.put(2,first+i-start,tostring(lines[i]):sub(1,math.max(0,w-2))) end
  end
  C.fill(1,h,w,1,"7")
  if view.mode == "role" then
    C.put(2,h,("> " .. tostring(view.input or "") .. "_"):sub(-math.max(1,w-27)))
    C.put(w-24,h,"[Enter] set  [Esc] back")
    return C.frame()
  end
  C.put(2,h,view.mode == "code" and "[P] new code     [Esc] cancel"
    or view.mode == "log" and "[Esc/L] back  [Up/Down] scroll"
    or "[P] pair a client   [R] roles   [L] full log")
  return C.frame()
end

-- Every known display for the terminal's role list, lowest id first.
D.listing = function()
  local rows, seen = {}, {}
  local function add(id, w, h, role)
    if seen[id] then return end
    seen[id] = true
    rows[#rows + 1] = { id = id, size = w and (w .. "x" .. h) or "-", role = D.label(role) }
  end
  local m, self = D.monitor, D.self()
  if m and self then add(self, m.session.w, m.session.h, D.localRole()) end
  for id, session in pairs(D.sessions) do
    if session.w then add(id, session.w, session.h, D.roleOf(id)) end
  end
  for key in pairs(D.saved.roles) do
    local id = tonumber(key)
    if id then add(id, nil, nil, D.roleOf(id)) end
  end
  table.sort(rows, function(a, b) return a.id < b.id end)
  return rows
end

D.drawTerminal = function(now)
  local v = SO.terminal
  if not v or not term or not term.blit then return end
  v.now = now or D.now()
  local minutes = math.floor((v.now-(v.started or v.now))/60000)
  v.uptime = string.format("up %dh%02d",math.floor(minutes/60),minutes%60)
  if v.mode == "role" then v.displays = D.listing() end
  local w,h = term.getSize()
  D.paint(term,D.terminal(D.model or { tiles = {} },v,w,h),w,h)
end

D.localTouch = function(side,x,y)
  local m = D.monitor
  if not m or side ~= m.name or not m.frame then return end
  local id
  for _, b in ipairs(m.frame.buttons) do
    if x >= b.x and x < b.x+b.w and y >= b.y and y < b.y+(b.h or 1) then id=b.id; break end
  end
  if not id then return end
  m.pending = {id=id,x=x,y=y}
end

-- The server's own monitor shows the role saved under the server's id, or status.
D.localRole = function()
  local role = D.saved.roles[tostring(D.self())]
  return D.known[role] and role or "status"
end

D.localTick = function(now)
  if peripheral and peripheral.find and now >= (D.scanAt or 0) then
    D.scanAt = now+5000
    local target = peripheral.find("monitor")
    if target then
      local name = peripheral.getName(target)
      if not D.monitor or D.monitor.name ~= name then
        D.monitor = {target=target,name=name,session={id=D.self()}}
      else D.monitor.target=target end
    else D.monitor=nil end
  end
  local m = D.monitor
  if m then
    local ok = pcall(function()
      m.target.setTextScale(0.5)
      local w,h = m.target.getSize()
      m.session.w, m.session.h = w, h
      local role = D.localRole()
      if m.role ~= role then m.role, m.session.page = role, nil end
      local event = m.pending
      m.pending = nil
      if event and m.frame and m.frame.role ~= role then event = nil end
      if event and event.id:match("^dug%.") then
        D.consent(event, role, w, h, m.session)
      elseif event then
        D.handle(role, m.session, event, now)
      end
      m.frame = D.compose(role,w,h,m.session)
      D.paint(m.target,m.frame,w,h)
    end)
    if not ok then D.monitor=nil end
  end
end

D.tick = function(now)
  if U then D.model = D.gather() end
  D.localTick(now)
  D.drawTerminal(now)
  for id, session in pairs(D.sessions) do
    if session.sub and session.w then D.sendFrame(id, now, false) end
  end
end

D.load = function()
  for i = 1, #D.order do D.known[D.order[i]] = true end
  D.box = SO.store.store(D.path, function(v)
    if type(v) ~= "table" or type(v.roles) ~= "table" then return false end
    for _, role in pairs(v.roles) do
      if not D.known[role] then return false end
    end
    for _, field in ipairs({ "far", "locked" }) do
      if v[field] ~= nil then
        if type(v[field]) ~= "table" then return false end
        for _, on in pairs(v[field]) do if type(on) ~= "boolean" then return false end end
      end
    end
    return true
  end)
  D.saved = { roles = {}, far = {}, locked = {} }
  if D.box.value and type(D.box.value.roles) == "table" then
    for id, role in pairs(D.box.value.roles) do D.saved.roles[tostring(id)] = role end
  end
  for _, field in ipairs({ "far", "locked" }) do
    if D.box.value and D.box.value[field] then
      for id, on in pairs(D.box.value[field]) do D.saved[field][tostring(id)] = on end
    end
  end
  D.register("status", D.statusRender, function() end)
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
  terminal = D.terminal,
  monitorTouch = D.localTouch,
  assign = D.assign,
  command = D.command,
  drawTerminal = D.drawTerminal,
}
