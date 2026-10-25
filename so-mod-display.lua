-- so-mod-display.lua - one role per paired display, and the frames it is sent.

local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local Turtle = U and U.turtle
local D = {
  path = "so-display",
  gap = 4000,
  limit = 4096,
  budget = 15400,
  order = { "status", "pocket", "mining", "lumber", "shop", "generic", "ar", "panel", "map",
    "health", "attention", "alerts", "events", "errors", "disk", "build" },
  known = {},
  box = nil,
  saved = { roles = {}, far = {}, locked = {} },
  screens = {},
  sessions = {},
  pictures = {},
  details = {},
  alertVersions = {},
  alertSequence = 0,
  modelRev = 0,
  thumbSizes = {},
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
  -- A confirm armed on the old role's frame must not fire on the new one.
  local session = D.sessions[id]
  if session and session.panel and role ~= old then session.panel.confirm, session.panel.drawn = nil, nil end
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
  if session then
    session.pocket, session.page, session.visit, session.turtle, session.alertList = nil, nil, nil, nil, nil
    session.sent = -math.huge
  end
  return true, "display " .. id .. ": " .. (role and D.label(role) or "cleared")
end

-- Shows the id in large digits on that display alone for five seconds. Nothing is saved.
D.identify = function(id)
  local session = id == D.self() and D.monitor and D.monitor.session or D.sessions[id]
  if not session or not session.w then return false, "display " .. id .. " not connected" end
  session.identify, session.sent = D.now() + 5000, -math.huge
  return true, "display " .. id .. ": identify 5 s"
end

-- Parses the server terminal's "<id> <role>", "<id> -", "<id> far on|off" and "<id> identify".
D.command = function(text)
  local line = tostring(text or ""):lower()
  local id, rest = line:match("^%s*(%d+)%s+far(.*)$")
  if id and (rest == "" or rest:match("^%s")) then
    local flag = rest:match("^%s+(%a+)%s*$")
    if flag ~= "on" and flag ~= "off" then return false, "use <id> far on|off" end
    id = tonumber(id)
    if not D.isDisplay(id) then return false, "no display " .. id end
    local ok, err = D.far(id, flag == "on")
    if not ok then return false, "save failed: " .. tostring(err) end
    return true, "display " .. id .. ": far " .. flag
  end
  id = line:match("^%s*(%d+)%s+identify%s*$")
  if id then return D.identify(tonumber(id)) end
  local role
  id, role = line:match("^%s*(%d+)%s+(%S+)%s*$")
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
  [0] = 0xE6EAF2, 0xFFC24B, 0xE57FD8, 0x9DB0D2,
  0xDEDE6C, 0x7FCC19, 0xF2B2CC, 0x18223A,
  0x7886A3, 0x2DD4BF, 0xB69CFF, 0x5AB0FF,
  0x28344D, 0x3DDC84, 0xFF6B5E, 0x0B111C,
}

-- A blank cell's fg never shows, so a space joins the previous run whatever its fg.
D.compact = function(row)
  local runs = {}
  for x = 1, #row.text do
    local fg = #row.fg == 1 and row.fg or row.fg:sub(x, x)
    local bg = #row.bg == 1 and row.bg or row.bg:sub(x, x)
    local last = runs[#runs]
    if last and last[3] == bg and (last[2] == fg or row.text:byte(x) == 32) then last[1] = last[1] + 1
    else runs[#runs + 1] = { 1, fg, bg } end
  end
  local compact = { text = row.text:gsub(" +$", ""), runs = runs }
  if #SO.proto.ser(compact) < #SO.proto.ser(row) then return compact end
  return row
end

D.session = function(id)
  local found = D.sessions[id]
  if found then return found end
  found = { id = id, sub = false, sent = 0, since = D.since() }
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

-- A page without its own way back gets an x chip at the right end of row 1.
D.closable = function(picture, w)
  local buttons = type(picture.buttons) == "table" and picture.buttons or {}
  for _, b in ipairs(buttons) do if D.back[b.id] then return picture end end
  local rows, copy = type(picture.rows) == "table" and picture.rows or {}, {}
  for i, row in ipairs(rows) do copy[i] = row end
  local first = D.fit({ rows = { rows[1] or { text = "" } }, buttons = {} }, w, 1).rows[1]
  local text, fg, bg = first.text .. string.rep(" ", w), "", ""
  if first.runs then
    for _, run in ipairs(first.runs) do fg, bg = fg .. string.rep(run[2], run[1]), bg .. string.rep(run[3], run[1]) end
  else
    fg = #first.fg == 1 and string.rep(first.fg, w) or first.fg
    bg = #first.bg == 1 and string.rep(first.bg, w) or first.bg
  end
  fg, bg = (fg .. string.rep("0", w)):sub(1, w - 3), (bg .. string.rep("f", w)):sub(1, w - 3)
  copy[1] = { text = text:sub(1, w - 3) .. " " .. (U and U.g.cross or "x") .. " ", fg = fg .. "000", bg = bg .. "777" }
  local controls = { { id = "visit-back", x = w - 2, y = 1, w = 3, h = 1, label = "" } }
  for _, b in ipairs(buttons) do controls[#controls + 1] = b end
  return { rows = copy, buttons = controls, palette = picture.palette }
end

-- Displays without a role, and roles whose module is missing: the role name in the header and the
-- display id in line digits, as large as fits (docs/ui/schematic/system.py unassigned).
D.idFrame = function(w, h, id, title)
  if not U then
    return { rows = { { text = "display " .. tostring(id or "?"), fg = "0", bg = "f" },
      { text = title:lower(), fg = "0", bg = "f" } }, buttons = {} }
  end
  local C, text = U.canvas(w, h), tostring(id or "?")
  C.bar(title)
  local dh = math.min(11, h - 3)
  dh = dh - (1 - dh % 2)
  local dw = math.min(9, dh - 2, math.floor((w - 4 - 2 * (#text - 1)) / #text))
  if dh < 5 or dw < 3 or text:find("%D") then C.put(2, h >= 3 and 3 or h, text, "0")
  else C.digits(math.floor((w - (#text * (dw + 2) - 2)) / 2) + 1, 3 + math.floor((h - 2 - dh) / 2), text, "0", dw, dh, 2) end
  return C.frame()
end

-- With revSent, returns nil instead when the picture is unchanged since that rev, before fitting it.
D.compose = function(role, w, h, session, revSent)
  local banner = D.retirement(w)
  local offset = banner and #banner.rows or 0
  local contentH = math.max(1, h - offset)
  local screen = D.screens[role]
  local picture
  if session and session.identify and D.now() >= session.identify then session.identify = nil end
  if session and session.identify then picture = D.idFrame(w, contentH, session.id, "IDENTIFY") end
  local glance = U and session and (role == "status" and screen and screen.render == D.statusRender
    or role == "pocket")
  local visit = session and session.visit and D.screens[session.visit]
  if glance and visit and not picture then
    D.model = D.model or D.gather()
    picture = D.takeover(session, D.model, w, contentH, D.now())
  end
  if picture then
  elseif Turtle and session and session.turtle then
    picture = Turtle.render(w, contentH, session.turtle, D.details[session.turtle.id], D.now())
  elseif visit then
    local ok, got = pcall(visit.render, w, contentH, session)
    if ok and type(got) == "table" then picture = D.closable(got, w) end
  elseif glance or (screen and role ~= "unassigned") then
    local ok, got
    if glance then
      D.model = D.model or D.gather()
      ok, got = pcall(D.statusFrame, session, w, contentH, D.now(), role == "pocket")
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
  if (role == "panel" or role == "pocket") and session and session.panel and session.panel.drawn then
    for _, button in ipairs(buttons) do
      local drawn = session.panel.drawn[button.id]
      if drawn then drawn.x, drawn.y, drawn.w, drawn.h = button.x, button.y, button.w, button.h end
    end
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
  if revSent and slot.rev == revSent then return end
  local fitted = D.fit({ rows = rows, buttons = buttons }, w, h)
  fitted.palette = picture.palette
  fitted.rev = slot.rev
  fitted.role = role
  return fitted
end

D.drawn = D.roleOf

D.rememberFrame = function(session, frame)
  local ids={}
  for _,button in ipairs(frame.buttons or {}) do
    if type(button.id)=="string" then ids[button.id]=true end
  end
  session.inputRole,session.inputIds=frame.role,ids
end

D.visibleInput = function(session, role, id)
  return session and session.inputRole==role and session.inputIds and session.inputIds[id]==true
end

-- What a plain status frame depends on, or nil while it can change by itself: a takeover, an
-- identify, a turtle or a page open, or an unseen alert the 30 s gate would let through.
D.stamp = function(session, role, now)
  local screen = D.screens.status
  if not U or role ~= "status" or not screen or screen.render ~= D.statusRender or not D.model then return end
  if session.visit or session.turtle or session.identify or not session.alertSeen
    or now < (session.alertUntil or 0) then return end
  if not session.alertAt or now - session.alertAt >= 30000 then
    for _, alert in ipairs(D.model.alerts) do if not session.alertSeen[alert.key] then return end end
  end
  local cells, banner = SO.mods.cells, ""
  local notice = cells and type(cells.retirement) == "function" and cells.retirement()
  if notice then
    local ok, text = pcall(SO.proto.ser, notice)
    banner = ok and text or "?"
  end
  return table.concat({ session.w, session.h, D.modelRev, tostring(session.alertList), banner }, "|")
end

-- Sends a frame when the picture changed, and repeats the last one every D.gap as the heartbeat.
-- An unchanged status display is not composed at all, and other roles skip the fit.
D.sendFrame = function(id, now, force)
  local session = D.sessions[id]
  if not session or not session.w or not session.h then return end
  local key = SO.pair.key(id)
  if not key then return end
  local role = D.drawn(id)
  local scale = D.saved.far[tostring(id)] and 1 or 0.5
  local beat = now - session.sent >= D.gap
  local last = not force and session.roleSent == role and session.scaleSent == scale and session.bodySent
  local stamp = not force and D.stamp(session, role, now) or nil
  local body
  if last and stamp and stamp == session.stampSent then body = last
  else
    if force and U and (role == "status" or role == "pocket") then D.model = D.gather() end
    body = D.compose(role, session.w, session.h, session, last and session.revSent)
    if body then body.scale = scale else body = last end
  end
  if body == last and not beat then return end
  local slot = (session.pictures or D.pictures)[body.role .. ":" .. session.w .. "x" .. session.h]
  local msg = SO.proto.build(key, "view.frame", body)
  local wire = SO.proto.encode(msg)
  while not wire do
    if #body.rows > 1 then body.rows[#body.rows] = nil
    elseif not D.dropButton(body.buttons) then break end
    msg = SO.proto.build(key, "view.frame", body)
    wire = SO.proto.encode(msg)
  end
  if type(wire) ~= "table" then return end
  if rednet.send(id, wire, "so") == false then return end
  D.rememberFrame(session,body)
  session.sent, session.roleSent, session.scaleSent, session.bodySent, session.stampSent = now, body.role, scale, body, stamp
  if slot then session.revSent = slot.rev end
end

-- BACK and nav controls outlive the rest when an oversize frame sheds buttons: the role and
-- page returns, tabs, pagers and every *-back, *-cancel, *-close, *-prev and *-next.
D.keep = { status = true, generic = true, dismiss = true, back = true, cancel = true, close = true,
  items = true, prev = true, next = true }

D.nav = function(id)
  if type(id) ~= "string" then return false end
  return D.keep[id] or id:match("^tab:") ~= nil or id:match("%-back$") ~= nil or id:match("%-cancel$") ~= nil
    or id:match("%-close$") ~= nil or id:match("%-prev$") ~= nil or id:match("%-next$") ~= nil
end

D.dropButton = function(buttons)
  for i = #buttons, 1, -1 do
    if not D.nav(buttons[i].id) then table.remove(buttons, i); return true end
  end
  return false
end

D.register = function(role, render, input)
  if render == nil and input == nil then return D.screens[role] end
  if type(role) ~= "string" or role == "" then return end
  if type(render) ~= "function" then render = function() end end
  if type(input) ~= "function" then input = function() end end
  D.screens[role] = { render = render, input = input }
end

D.stateView = function()
  local state = SO.mods.state
  if state then
    local fn, meta = state.view, type(state.view) == "table" and getmetatable(state.view)
    if type(fn) == "function" or (meta and type(meta.__call) == "function") then
      local ok, got = pcall(fn)
      if ok and type(got) == "table" then return got end
    end
  end
  return {}
end

D.alertKeys = function(view)
  local keys = {}
  for key, value in pairs(view.values or {}) do
    if type(key) == "string" and key:match("%.alert$") and value then keys[#keys + 1] = key end
  end
  table.sort(keys)
  return keys
end

-- Each alert value gets a sequence number; a changed value is a new alert.
D.alertVersion = function(key, value)
  local identity = key .. ":" .. SO.proto.ser(value)
  local version = D.alertVersions[key]
  if not version or version.key ~= identity then
    D.alertSequence = D.alertSequence + 1
    version = {key = identity, sequence = D.alertSequence}
    D.alertVersions[key] = version
  end
  return version
end

-- The newest alert sequence, after numbering the alerts standing now: a session opened
-- between gathers, or before the first one after boot, still knows them as old.
-- The first numbering after boot also sets bootSequence: alerts up to it stood through a restart.
D.since = function()
  if SO.mods.state then
    local view = D.stateView()
    for _, key in ipairs(D.alertKeys(view)) do D.alertVersion(key, view.values[key]) end
    D.bootSequence = D.bootSequence or D.alertSequence
  end
  return D.alertSequence
end

D.gather = function()
  if not D.bootSequence then D.since() end
  local model = { time = U and U.clock(os.epoch("utc")).hm or "",
    alerts = {}, log = {}, tiles = {}, oreShort = "no source", terminalSubs = {} }
  local state, lease, drops = SO.mods.state, SO.mods.lease, SO.mods.drops
  local view = D.stateView()
  local machines = state and type(state.get) == "function" and state.get("machines") or {}
  local turtles, lost, leases, lostIds = 0, 0, 0, {}
  for id, machine in pairs(machines or {}) do
    if machine.role == nil or machine.role == "worker" or machine.role == "turtle" then
      turtles = turtles + 1
      local status = lease and type(lease.status) == "function" and lease.status(tonumber(id)) or {}
      if status.lost then lost, lostIds[#lostIds + 1] = lost + 1, tonumber(id) or id end
      if status.open then leases = leases + 1 end
    end
  end
  for _, key in ipairs(D.alertKeys(view)) do
    local value = view.values[key]
    local text = type(value) == "table" and tostring(value.text or value.reason or key) or tostring(value)
    local version = D.alertVersion(key, value)
    local fields = type(value) == "table" and value or {}
    model.alerts[#model.alerts + 1] = { key = version.key, sequence = version.sequence, text = text,
      detail = fields.detail, sub = fields.sub, id = fields.id, kind = fields.kind,
      point = type(fields.point) == "table" and fields.point or nil }
  end
  table.sort(model.alerts, function(a, b) return a.sequence < b.sequence end)
  model.alert = model.alerts[#model.alerts] and model.alerts[#model.alerts].text
  local displays, staleIds = 0, {}
  for id, session in pairs(D.sessions) do
    if session.w then displays = displays + 1; if D.now() - session.sent > 10000 then staleIds[#staleIds + 1] = id end end
  end
  local stale, staleText = #staleIds, D.staleText(staleIds)
  local points = drops and type(drops.list) == "function" and drops.list() or {}
  local broken = 0
  for _, point in ipairs(points) do if point.broken then broken = broken + 1 end end
  local capacity = fs and fs.getCapacity and fs.getCapacity("/")
  local free = fs and fs.getFreeSpace and fs.getFreeSpace("/")
  local ratio = type(capacity) == "number" and capacity > 0 and type(free) == "number" and (capacity-free)/capacity
  local diskState = state and state.disk and state.disk() or {}
  local disk = ratio and tostring(math.floor(ratio*100)) .. "%" or "-"
  local diskSub = ratio and string.format("%.1f of %.0f MB",(capacity-free)/1000000,capacity/1000000) or "no source"
  model.okShort, model.lostShort = tostring(turtles-lost) .. " ok", tostring(lost) .. " lost"
  -- Chips for the 26-wide fact rows; a second chip only when something needs a look.
  local function chips(first, bg, count, word, warn)
    local list = { { first, bg } }
    if count > 0 then list[2] = { count .. " " .. word, warn } end
    return list
  end
  local daily = SO.mods.daily
  local today = daily and type(daily.today) == "function" and daily.today()
  model.tiles = {
    {label="TURTLES",value=tostring(turtles),sub=model.okShort .. ", " .. model.lostShort,bg=lost > 0 and "e" or "d",
      chips=turtles > 0 and chips(model.okShort,"d",lost,"lost","e") or {{"0","c"}}},
    {label="LEASES",value=tostring(leases),sub="",bg="b",chips={{leases .. " open","b"}}},
    {label="ALERTS",value=tostring(#model.alerts),sub=model.alert or "none",bg=#model.alerts > 0 and "e" or "d"},
    {label="ORE TODAY",value=today and tostring(today.ore) or "-",sub=today and ("+" .. today.oreRecent) or "no source",bg=today and "b" or "c"},
    {label="LOGS TODAY",value=today and tostring(today.logs) or "-",sub=today and "" or "no source",bg=today and "d" or "c"},
    {label="DISK",value=disk,sub=diskSub,bg=(diskState.pending or 0) > 0 and "e" or ratio and (ratio >= 0.8 and "e" or "d") or "c"},
    {label="DISPLAYS",value=tostring(displays),sub=staleText or "all fresh",bg=stale > 0 and "1" or "d",
      chips=staleText and {{tostring(displays),"d"},{staleText,"1"}} or {{tostring(displays),"d"}}},
    {label=broken>0 and "BROKEN" or "DROPS",value=tostring(broken>0 and broken or #points),sub="",bg=broken > 0 and "e" or "d",
      id=broken>0 and "broken" or nil,chips=chips(tostring(#points),"d",broken,"broken","1")},
  }
  if D.drawsStatus() then D.facts(model, machines, points, today, capacity, free) end
  local shown = 0
  for _, row in ipairs(D.listing()) do if row.size ~= "-" then shown = shown + 1 end end
  D.termFacts(model, lostIds, points, turtles, leases, shown, capacity, free)
  model.oreShort = model.tiles[4].sub
  model.terminalSubs = {model.okShort, model.tiles[7].sub, diskSub, model.alert or "none"}
  for _, alert in ipairs(model.alerts) do model.log[#model.log + 1] = alert.text end
  return model
end

-- "#7 stale", "#7 #9 stale", or the two lowest ids and +N; nil when every display is fresh.
D.staleText = function(ids)
  if #ids == 0 then return nil end
  table.sort(ids, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
  local names = {}
  for i = 1, math.min(2, #ids) do names[i] = "#" .. tostring(ids[i]) end
  if #ids > 2 then names[3] = "+" .. (#ids - 2) end
  return table.concat(names, " ") .. " stale"
end

-- The server terminal's facts, without a mapView: counts, disk and the alert lines.
D.termFacts = function(model, lostIds, points, turtles, leases, displays, capacity, free)
  table.sort(lostIds, function(a, b)
    if type(a) == "number" and type(b) == "number" then return a < b end
    return tostring(a) < tostring(b)
  end)
  local flags = {}
  for _, id in ipairs(lostIds) do flags[#flags + 1] = { text = "#" .. id .. " lost" } end
  for i = #model.alerts, 1, -1 do flags[#flags + 1] = { text = model.alerts[i].text } end
  for i, p in ipairs(points) do
    if p.broken then flags[#flags + 1] = { text = "drop " .. (p.id or i) .. " " .. tostring(p.kind or "drop") .. " broken" } end
  end
  model.terminal = { flags = flags, ok = turtles - #lostIds, lost = #lostIds, leases = leases, displays = displays,
    disk = type(capacity) == "number" and capacity > 0 and type(free) == "number" and { used = capacity - free, cap = capacity } or nil }
end

-- The route A facts cost a mapView of each job; gather them only while a display shows status.
D.drawsStatus = function()
  if D.monitor and D.localRole() == "status" then return true end
  for id, session in pairs(D.sessions) do
    local role = session.w and D.roleOf(id)
    if role == "status" or role == "pocket" then return true end
  end
  return false
end

D.call = function(name, fn, ...)
  local mod = SO.mods[name]
  if type(mod) ~= "table" or type(mod[fn]) ~= "function" then return end
  local ok, got = pcall(mod[fn], ...)
  if ok then return got end
end

D.phases = { scan = "scanning", base = "felling", climb = "felling", descend = "felling",
  plant = "planting", plantPlace = "planting" }

-- Turtle rows for route A status: mining first, then lumber, then the rest, each by id.
D.turtles = function(model, machines, mine, wood)
  local now, jobs, list = D.now(), {}, {}
  for id, row in pairs(mine and mine.turtles or {}) do jobs[tostring(id)] = { 0, row } end
  if wood and wood.turtle then jobs[tostring(wood.turtle.id)] = { 1, wood.turtle } end
  local busy, workers, lane = 0, 0, nil
  for id, machine in pairs(machines or {}) do
    if machine.role == nil or machine.role == "worker" or machine.role == "turtle" then
      local job = jobs[tostring(id)] or { 2, {} }
      local row, status = job[2], D.call("lease", "status", tonumber(id)) or {}
      local pose = row.pose or machine.pose or {}
      local word = tostring(row.state or "idle")
      if job[1] == 1 and word == "lumber" then word = D.phases[row.phase] or "working" end
      if status.lost then word = "lost" end
      local t = { id = tonumber(id) or id, order = job[1], facing = pose.facing, state = word, tone = U.tone(word),
        where = job[1] == 1 and "farm" or row.lane and "lane" or row.branch and "b" .. (row.branch + 1) or "-",
        x = pose.x, y = pose.y, z = pose.z, fuel = machine.fuel, ore = row.ores or 0,
        ago = D.ago(now - (machine.seen or now)), lost = status.lost and true or false }
      list[#list + 1] = t
      if job[1] == 0 then
        workers = workers + 1
        if t.tone == "d" then busy = busy + 1 end
        if row.lane then lane = t end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    local x, y = tonumber(a.id), tonumber(b.id)
    if x and y then return x < y end
    return tostring(a.id) < tostring(b.id)
  end)
  model.turtles = list
  if mine then
    model.mining = { state = mine.running and "running" or "stopped", done = mine.done or 0, total = mine.branches or 0,
      busy = busy, workers = workers, lane = lane }
  end
end

-- Route A status facts beside the tiles (docs/server-only/PROTOCOL.md#display).
-- Ages in whole 10 s: every age and age colour the screens draw changes on a 10 s step, so the
-- model, and with it every status frame, stays the same between those steps.
D.ago = function(ms)
  ms = math.max(0, ms)
  return ms == math.huge and ms or ms - ms % 10000
end

D.facts = function(model, machines, points, today, capacity, free)
  local now, mine, wood = D.now(), D.call("mine", "mapView"), D.call("lumber", "mapView")
  local started = type(SO.terminal) == "table" and SO.terminal.started
  local up = started and math.floor((now - started) / 60000)
  model.server = { id = D.self() or "?", up = up and string.format("%dh%02d", math.floor(up / 60), up % 60) or "-" }
  D.turtles(model, machines, mine, wood)
  if wood then
    local ready, spots, state = 0, wood.spots or {}, wood.turtle and wood.turtle.state
    for _, spot in ipairs(spots) do if spot.ready then ready = ready + 1 end end
    local grow = wood.grow and math.floor(wood.grow / 1000)
    model.lumber = { ready = ready, spots = #spots, grow = grow and string.format("%d:%02d", math.floor(grow / 60), grow % 60),
      state = not wood.running and "stopped" or (state and state ~= "lumber" and state ~= "idle") and state or "running" }
  end
  local flags = {}
  for _, t in ipairs(model.turtles) do
    if t.lost then
      flags[#flags + 1] = { text = "#" .. t.id .. " lost", short = U.age(t.ago), hit = "turtle:" .. t.id,
        detail = (t.x and (t.x .. "," .. t.y .. "," .. t.z .. " " .. U.g.dot .. " ") or "") .. U.age(t.ago, true) }
    end
  end
  for i = #model.alerts, 1, -1 do flags[#flags + 1] = { text = model.alerts[i].text, detail = model.alerts[i].detail } end
  model.drops = {}
  for i, p in ipairs(points) do
    local d = { id = p.id or i, kind = tostring(p.kind or "drop"), x = p.x or 0, y = p.y or 0, z = p.z or 0, broken = p.broken and true or false }
    model.drops[i] = d
    if d.broken then flags[#flags + 1] = { text = "drop " .. d.id .. " " .. d.kind .. " broken", brief = "drop " .. d.id .. " broken", hit = "broken" } end
  end
  model.flags = flags
  if today then
    local names = {}
    for name, count in pairs(today.oreByName or {}) do
      names[#names + 1] = { (name:gsub("^.-:", ""):gsub("^deepslate_", ""):gsub("^raw_", ""):gsub("_ore$", "")), count }
    end
    table.sort(names, function(a, b) return a[2] > b[2] or a[2] == b[2] and a[1] < b[1] end)
    model.today = { ore = today.ore or 0, logs = today.logs or 0, recent = today.oreRecent or 0, names = names }
  end
  if type(capacity) == "number" and capacity > 0 and type(free) == "number" then
    model.disk = { used = capacity - free, cap = capacity }
  end
  local leases = 0
  for _, t in ipairs(model.turtles) do
    local status = D.call("lease", "status", tonumber(t.id)) or {}
    if status.open then leases = leases + 1 end
  end
  model.leases = leases
  model.displays = {}
  for _, row in ipairs(D.listing()) do
    local session = D.sessions[row.id]
    if row.size ~= "-" then
      model.displays[#model.displays + 1] = { id = row.id, role = row.role, size = row.size,
        ago = session and session.sent and D.ago(now - session.sent) or 0 }
    end
  end
  model.events = {}
  local log = type(SO.terminal) == "table" and type(SO.terminal.log) == "table" and SO.terminal.log or {}
  -- Pairing codes reach the terminal log but belong only to the terminal and the asking pocket.
  for i = #log, math.max(1, #log - 39), -1 do
    if #model.events >= 10 then break end
    local time, text = tostring(log[i]):match("^(%d%d:%d%d:%d%d) (.*)$")
    if not time then time, text = "", tostring(log[i]) end
    if not text:lower():find("pair code", 1, true) then
      model.events[#model.events + 1] = { time = time, text = text, tone = U.mark(text) }
    end
  end
  local map = SO.mods.map
  model.thumb = type(map) == "table" and type(map.thumb) == "function" and D.thumb or nil
end

-- The map thumbnail, drawn by the map module; each size a status frame draws it at is kept
-- so the tick can sign the thumbnail at those sizes.
D.thumb = function(C, x, y, w, h)
  local key = w .. "x" .. h
  if not D.thumbSizes[key] then
    local count = 0
    for _ in pairs(D.thumbSizes) do count = count + 1 end
    if count >= 8 then D.thumbSizes = {} end
    D.thumbSizes[key] = { w, h }
  end
  return SO.mods.map.thumb(C, x, y, w, h)
end

-- The status model's signature: its data, which leaves out the thumbnail function, and the
-- thumbnail itself at every size drawn so far. Drawing it here also keeps the map gathering
-- while unchanged status displays are not composed. Nil when it cannot be signed.
D.modelSignature = function(model)
  local data = {}
  for k, v in pairs(model) do if type(v) ~= "function" then data[k] = v end end
  local ok, text = pcall(SO.proto.ser, data)
  if not ok then return end
  local parts, map = { text }, SO.mods.map
  if model.thumb and type(map) == "table" and type(map.thumb) == "function" then
    for key, size in pairs(D.thumbSizes) do
      local C = U.canvas(size[1], size[2])
      local drawn = pcall(map.thumb, C, 1, 1, size[1], size[2])
      parts[#parts + 1] = key .. "=" .. (drawn and D.sig(C.frame().rows, {}) or "!")
    end
  end
  table.sort(parts)
  return table.concat(parts, "|")
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

D.diskRender = function(w, h)
  local state = SO.mods.state
  local disk = state and state.disk and state.disk() or {}
  local c = U.canvas(w,h)
  c.header("DISK", math.floor((disk.ratio or 0)*100).."%")
  c.alert(disk.pending and disk.pending > 0 and (disk.pending .. " events pending") or disk.pressure and "DISK pressure")
  for i, key in ipairs({"log","snapshots","cells","jobs","keys","other"}) do
    local bytes = disk.stores and disk.stores[key] or 0
    c.put(2,i+3,key:upper())
    local text = tostring(bytes)
    c.put(math.max(2,w-#text),i+3,text)
  end
  c.put(2,10,"USED " .. tostring(disk.used or 0))
  c.button(1,h,w,"BACK","status","7",1)
  return c.frame()
end

D.statusRender = function(w, h)
  if not U then return D.legacyStatus() end
  return U.status(D.model or { tiles = {}, time = "" }, w, h)
end

-- In-memory snoozes: one end time per key, span ms after set; a restart forgets them all.
-- The takeover SNOOZE uses it per session; health's lost rows (P1-4) reuse it per turtle id.
D.snoozer = function(span)
  local ends, snooze = {}, {}
  snooze.set = function(key, now)
    for k, at in pairs(ends) do if now >= at then ends[k] = nil end end
    ends[key] = now + span
  end
  -- True and the ms left while key is snoozed.
  snooze.on = function(key, now)
    local at = ends[key]
    if at and now >= at then ends[key], at = nil, nil end
    return at ~= nil, at and at - now
  end
  snooze.clear = function(key) ends[key] = nil end
  return snooze
end
D.snoozes = D.snoozer(300000)

-- Shows each new alert once, oldest first, at most every 30 s, for five seconds or until a tap.
-- An alert counts as seen only once shown. On a session's first sight, the alerts standing
-- before it opened are seen already, except that the newest one standing through a server
-- restart takes over once. Alerts raised while the session is snoozed count as seen.
-- Cleared alerts leave alertSeen, so it stays bounded.
D.takeover = function(session, model, w, h, now)
  local first, seen, live, look = not session.alertSeen, session.alertSeen or {}, {}, nil
  for _, alert in ipairs(model.alerts) do
    live[alert.key] = true
    if first and alert.sequence <= (session.since or 0) then
      seen[alert.key] = true
      if alert.sequence <= (D.bootSequence or 0) then look = alert end
    end
  end
  for key in pairs(seen) do if not live[key] then seen[key] = nil end end
  session.alertSeen = seen
  if D.snoozes.on(session, now) then
    for key in pairs(live) do seen[key] = true end
  elseif not session.alertAt or now - session.alertAt >= 30000 then
    for _, alert in ipairs(model.alerts) do
      if not seen[alert.key] then look = alert; break end
    end
    if look then
      seen[look.key] = true
      session.alertAt, session.alertUntil, session.takeover = now, now + 5000, look
    end
  end
  if session.takeover and now < (session.alertUntil or 0) then
    return D.alertFrame(model, session.takeover, w, h, session.alertUntil - now)
  end
end

D.wrap = function(text, width)
  local lines, line = {}, ""
  width = math.max(1, width)
  for word in text:gmatch("%S+") do
    while #word > width do
      if line ~= "" then lines[#lines + 1], line = line, "" end
      lines[#lines + 1], word = word:sub(1, width), word:sub(width + 1)
    end
    if line == "" then line = word
    elseif #line + 1 + #word <= width then line = line .. " " .. word
    else lines[#lines + 1], line = line, word end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

-- The takeover's subject: the alert's turtle (id) or drop (point id, then kind), from the status model.
D.subject = function(model, a)
  if a.id ~= nil then
    for _, t in ipairs(model.turtles or {}) do
      if tostring(t.id) == tostring(a.id) and t.x then return { label = "#" .. t.id, x = t.x, y = t.y, z = t.z, id = t.id, row = t } end
    end
  end
  local point = a.point and a.point.id
  for _, d in ipairs(point ~= nil and model.drops or {}) do
    if tostring(d.id) == tostring(point) then return { label = "drop " .. d.id, x = d.x, y = d.y, z = d.z, drop = d.id, row = d } end
  end
  if a.kind then
    for _, d in ipairs(model.drops or {}) do
      if d.kind == a.kind then return { label = "drop " .. d.id, x = d.x, y = d.y, z = d.z, drop = d.id, row = d } end
    end
  end
end

D.subjectRows = function(s)
  local r = s.row
  if s.drop then return { { "kind", r.kind, "0" }, { "state", r.broken and "broken" or "ok", r.broken and "e" or "0" } } end
  local fuel = tonumber(r.fuel)
  return { { "state", r.state, U.st.fg(r.tone) }, { "where", r.where, "0" },
    { "fuel", fuel and tostring(fuel) or "-", fuel and (fuel < 500 and "1" or "0") or "8" },
    { "ore", tostring(r.ore or "-"), "0" }, { "seen", U.age(r.ago or 0, true), "8" } }
end

-- Coral frame and title chip, the subject's position and the detail, a map crop around the subject
-- from map.crop, and a coral tick row counting down the time left.
-- The #id chip opens its turtle, SNOOZE mutes takeovers on this display for five minutes, and a tap
-- anywhere else dismisses it. docs/ui/schematic/system.py alert is the twin.
D.alertFrame = function(model, a, w, h, left)
  local C, s = U.canvas(w, h), D.subject(model, a)
  C.box(1, 1, w, h, "e")
  local mx = w >= 40 and 5 or 3
  local iw = w - 2 * (mx - 1)
  local text = tostring(a.text or "")
  local name = (s and s.id ~= nil and (s.label .. " ") or "") .. text
  -- Too narrow for the whole title: the chip names the turtle and the text wraps under it.
  local rest = #name > iw - 2 and s and s.id ~= nil
  local label = " " .. (rest and s.label or name):upper():sub(1, math.max(0, iw - 2)) .. " "
  local y = h >= 10 and 3 or 2
  local chipY = y
  C.put(mx, y, label, "f", "e")
  if rest then
    for i, line in ipairs(D.wrap(text, iw)) do
      if i <= 2 and y + 1 < h - 2 then y = y + 1; C.put(mx, y, line, "0") end
    end
  end
  local pos = s and (s.x .. "," .. s.y .. "," .. s.z)
  if pos and #pos <= iw then
    if not rest and #label + 1 + #pos <= iw then C.put(mx + #label + 1, y, pos, "0")
    elseif y + 1 < h - 2 then y = y + 1; C.put(mx, y, pos, "0") end
  end
  local detail = a.detail or a.sub
  if detail and y + 2 < h - 2 then y = y + 2; C.put(mx, y, tostring(detail):sub(1, iw), "8") end
  local top, bottom, map, drawn = y + 2, h - 5, SO.mods.map, false
  if s and bottom - top + 1 >= 3 and iw >= 10 and type(map) == "table" and type(map.crop) == "function" then
    local ok, got = pcall(map.crop, C, mx, top, iw, bottom - top + 1, { x = s.x, y = s.y, z = s.z, id = s.id, drop = s.drop })
    drawn = ok and got ~= false
  end
  -- Without a crop the subject's own facts fill the space.
  if s and not drawn then
    for i, r in ipairs(D.subjectRows(s)) do
      if top + i - 1 <= bottom then C.leader(mx, top + i - 1, math.min(iw, 30), r[1], r[2], r[3]) end
    end
  end
  if left and h >= 8 then C.ticks(mx, h - 2, iw, U.filled(iw, left, 5000), "e") end
  C.hit("dismiss", 1, 1, w, h)
  -- Clients take the last button drawn, so SNOOZE and the chip go after the dismiss hit.
  if h >= 6 and iw >= 8 then C.chip(mx + iw - 8, h - 1, "SNOOZE", "snooze") end
  if s and s.id ~= nil then C.hit("turtle:" .. s.id, mx, chipY, #label, 1) end
  return C.frame()
end

-- Status ALERTS: every standing alert, newest first, a pager when they do not fit, and BACK.
D.alertList = function(model, session, w, h)
  local C, list = U.canvas(w, h), {}
  for i = #model.alerts, 1, -1 do list[#list + 1] = model.alerts[i] end
  local top = h >= 6 and 3 or 2
  local capacity = math.max(1, h - top - 1)
  local pages = math.max(1, math.ceil(#list / capacity))
  session.alertList = session.alertList % pages
  -- BACK, a gap, then the arrows at the right, moved up to the edge on narrow displays. The page count
  -- goes between BACK and the arrows when it fits there, else in the header.
  local back = w >= 15 and "BACK" or U.g.cross
  local free = 2 + #back + 3
  local px = math.max(w - 7, free)
  local note = pages > 1 and (session.alertList + 1) .. "/" .. pages or nil
  local footer = note and px - 1 - #note >= free
  C.bar("ALERTS", nil, nil, note and not footer and note or tostring(#list), #list > 0 and "e" or "8")
  if #list == 0 then C.put(2, top, "no alerts", "8") end
  for i = 1, capacity do
    local a = list[session.alertList * capacity + i]
    if a then C.flag(2, top + i - 1, w - 2, tostring(a.text or ""), a.detail and tostring(a.detail)) end
  end
  C.chip(2, h, back, "alerts-back")
  if pages > 1 and px + 6 <= w then
    C.chip(px, h, U.g.left, "alert-prev")
    C.chip(px + 4, h, U.g.right, "alert-next")
    if footer then C.put(px - 1 - #note, h, note, "8") end
  end
  return C.frame()
end

-- Status and pocket share the takeover. The pocket role draws its own pages when
-- the panel module registered them; otherwise it shows the 26-wide status rows.
D.statusFrame = function(session, w, h, now, pocket)
  local model = D.model
  local alert = D.takeover(session, model, w, h, now)
  if alert then return alert end
  if session.alertList then return D.alertList(model, session, w, h) end
  if pocket and D.screens.pocket then return D.screens.pocket.render(w, h, session) end
  local copy = {}
  for k, v in pairs(model) do copy[k] = v end
  copy.name = pocket and "FLEET" or nil
  local frame = U.status(copy, w, pocket and w == 26 and 20 or h)
  -- Big walls with many rows can pass the 16 KB frame limit; redraw them with fewer rows.
  if w * h > 4000 and #SO.proto.ser(D.fit(frame, w, h)) > D.budget then
    copy.tight = true
    frame = U.status(copy, w, h)
  end
  return frame
end

D.hello = function(msg)
  local body = msg.body
  if type(body) ~= "table" then return end
  local session = D.sessions[msg.from]
  local display = body.role == nil or body.role == "display"
  if session and not display then
    session.isDisplay = false
    if session.panel then session.panel.confirm, session.panel.drawn = nil, nil end
  end
  if not D.acceptSize(body.w, body.h) then return end
  session = D.session(msg.from)
  session.isDisplay = display
  session.keyboard = body.keyboard == true
  -- The computer label, printable and short, for the terminal's role list.
  local label = type(body.label) == "string" and (body.label:gsub("[^\32-\126]", "")):sub(1, 32) or ""
  session.label = label ~= "" and label or nil
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
  if reply("view.frame", body) ~= false then D.rememberFrame(session,body) end
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

-- A page shows another registered screen inside the drawn role (health, disk, build, a focused
-- drop list). Its own "status" or "generic" control, or the x chip, returns to the role.
D.back = { status = true, generic = true, ["visit-back"] = true }

-- Opens role as a page of the session, then sends it actions. The drawn role never changes.
D.open = function(session, change, role, actions)
  local target = D.screens[role]
  if not D.known[role] or not target then return end
  change(role)
  for _, id in ipairs(actions or {}) do
    pcall(target.input, {from=session.id,id=id,role=role,session=session})
  end
end

-- Routes one tap or text inside the drawn role. Pages may change; the role never does.
D.handle = function(role, session, event, now)
  local screen, own = D.screens[role], role
  if role == "status" or role == "pocket" then
    if now < (session.alertUntil or 0) then
      session.alertUntil = 0
      if event.id == "snooze" then D.snoozes.set(session, now); return end
      -- The takeover's #id chip opens its turtle; any other tap dismisses it.
      local target = Turtle and type(event.id) == "string" and event.id:match("^turtle:(%d+)$")
      if target and session.takeover and tostring(session.takeover.id) == target then
        D.gatherTurtles()
        if D.details[target] then session.turtle = { id = target } end
        return
      end
      event.id = "dismiss"
    elseif session.visit then
    elseif session.alertList and not session.turtle then
      if event.id == "alerts-back" then session.alertList = nil
      elseif event.id == "alert-next" then session.alertList = session.alertList + 1
      elseif event.id == "alert-prev" then session.alertList = session.alertList - 1 end
      return
    elseif event.id == "disk" and D.screens.disk then session.visit = "disk"; return
    elseif (role == "status" or not screen) and event.id == "alerts" and U then
      session.alertList = 0
      return
    end
    if role == "pocket" and (event.id == "dismiss" or not screen) then return end
  end
  if event.id ~= "dismiss" and event.x and D.turtleInput({ id = event.id, x = event.x, y = event.y, session = session,
    role = role, from = event.from }, session.w or 1, session.h or 1) then return end
  if session.visit then
    if not D.screens[session.visit] or D.back[event.id] then session.visit = nil; return end
    role, screen = session.visit, D.screens[session.visit]
  end
  event.role, event.session = role, session
  event.open = function(name, actions)
    D.open(session, function(page) session.visit = page ~= own and page or nil end, name, actions)
  end
  if screen then pcall(screen.input, event) end
end

D.gatherTurtles = function()
  local out = {}
  local state = SO.mods.state
  local machines = state and type(state.get)=="function" and state.get("machines") or {}
  for id,row in pairs(machines or {}) do
    if row.role == nil or row.role == "worker" or row.role == "turtle" then out[tostring(id)] = row end
  end
  for _,name in ipairs({"mine","lumber"}) do
    local mod = SO.mods[name]
    if mod and type(mod.turtleView)=="function" then
      for id,row in pairs(mod.turtleView()) do
        row.seen = out[id] and out[id].seen
        out[id] = row
      end
    end
  end
  local lease = SO.mods.lease
  for id,row in pairs(out) do
    local status = lease and type(lease.status)=="function" and lease.status(tonumber(id)) or {}
    row.lease,row.uncertain = status.open,status.uncertain
    row.seen = row.seen or status.seen
  end
  D.details = out
end
D.turtleInput = function(event,w,h)
  local session,id = event.session,event.id or ""
  if not Turtle or not session then return false end
  local selected = session.turtle
  local target = id:match("^turtle:(%d+)$")
  if not selected and not target then return false end
  if selected and event.x >= 1 and event.x <= w and event.y == h then
    if id == "turtle-back" and not selected.draft then session.turtle=nil return true end
    if id == "turtle-cancel" and selected.draft then selected.draft,selected.confirm=nil,nil return true end
  end
  if selected and selected.draft then selected.draft=Turtle.draft(selected.draft) end
  local frame = D.compose(event.role,w,h,session)
  local drawn = false
  for _,b in ipairs(frame.buttons) do
    if b.id == id and event.x >= b.x and event.x < b.x+b.w and event.y >= b.y and event.y < b.y+(b.h or 1) then drawn=true break end
  end
  if not drawn then return true end
  if target then
    D.gatherTurtles()
    if D.details[target] then session.turtle={id=target} end
    return true
  end
  D.gatherTurtles()
  local row = D.details[selected.id] or {}
  -- Every drawn tap goes through U.confirm: REMOVE and the editor's save are two-tap, and any other
  -- tap disarms them.
  local key = id == "turtle-remove" and "remove" or id == "turtle-save" and selected.draft and row.uncertain and "add" or nil
  local fire = U.confirm(selected, key, D.now())
  local screen = row.role and D.screens[row.role]
  local function command(text)
    if screen then screen.input({text=text,session=session,from=event.from,role=row.role}) end
    D.gatherTurtles()
  end
  if id == "turtle-back" then session.turtle=nil
  elseif id == "turtle-cancel" then selected.draft=nil
  elseif id == "turtle-park" then command(row.role == "lumber" and ("park "..selected.id) or "stop")
  elseif id == "turtle-remove" then
    if fire then command("remove "..selected.id) end
  elseif id == "turtle-add" and row.uncertain then
    selected.draft=Turtle.draft(row.pose or row.anchor)
  elseif selected.draft then
    local axis,delta=id:match("^pose:(%a+):(%-?%d+)$")
    if axis and selected.draft[axis] then
      selected.draft[axis]=selected.draft[axis]+tonumber(delta)
      if axis=="facing" then selected.draft.facing=selected.draft.facing%4 end
    elseif key == "add" and fire then
      local p=selected.draft
      command(string.format("add %s %d %d %d %s",selected.id,p.x,p.y,p.z,({[0]="n","e","s","w"})[p.facing]))
      selected.draft=nil
    end
  end
  return true
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
  -- Only a control on the last frame sent to this display counts.
  if id and not D.visibleInput(session, drawn, id) then return end
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
    local row = frame.rows[button.y] and frame.rows[button.y].text or ""
    if label ~= "" and not row:sub(button.x,button.x+math.max(button.w,#label)-1):find("%S") then
      target.setCursorPos(button.x,button.y)
      target.blit(label,string.rep("0",#label),string.rep("7",#label))
    end
  end
end

D.hints = function(C, x, y, keys, step)
  for _, k in ipairs(keys) do
    C.put(x, y, "[" .. k[1] .. "]", "9")
    C.put(x + #k[1] + 3, y, k[2], "0")
    x = x + math.max(step, #k[1] + #k[2] + 5)
  end
end

-- "hh:mm:ss text" as a muted time, a state mark and white text.
D.logLine = function(C, x, y, w, line)
  local time, text = line:match("^(%d%d:%d%d:%d%d) (.*)$")
  if time then C.put(x, y, time, "8"); x, w = x + 9, w - 9 else text = line end
  C.put(x, y, U.g.bullet, U.mark(text))
  C.put(x + 2, y, text:sub(1, math.max(0, w - 2)), "0")
end

-- The server's own screen in route A (docs/ui/schematic/system.py terminal): alerts, FLEET and DISK,
-- the log and the key hints; P shows the code, R the role prompt and L the whole log.
D.terminal = function(model, view, w, h)
  if not U and view.mode == "role" then
    local rows = { { text = "roles", fg = "0", bg = "f" } }
    for _, row in ipairs(view.displays or {}) do
      rows[#rows + 1] = { text = row.id .. " " .. (row.size or "-") .. " " .. row.role .. (row.label and " " .. row.label or ""),
        fg = "0", bg = "f" }
    end
    rows[#rows + 1] = { text = tostring(view.notice or ""), fg = "0", bg = "f" }
    rows[#rows + 1] = { text = "> " .. tostring(view.input or "") .. "_", fg = "0", bg = "f" }
    return { rows = rows, buttons = {} }
  end
  if not U then return D.legacyStatus() end
  local C, mode, log = U.canvas(w, h), view.mode or "normal", view.log or {}
  C.bar("SO SERVER #" .. tostring(view.id), nil, nil, view.uptime or "")
  if mode == "code" then
    C.section(2, 3, w - 2, "PAIR CODE")
    local code = tostring(view.code or "")
    local left = math.max(0, (view.expires or 0) - (view.now or 0))
    local secs = math.ceil(left / 1000)
    local clock = string.format("%d:%02d", math.floor(secs / 60), secs % 60)
    local width = #code * 7 - 2
    local x = math.floor((w - width) / 2) + 1
    if width <= w - 2 and h >= 14 and not code:find("%D") then
      C.digits(x, 5, code, "0", 5, 7, 2)
      C.ticks(x, 13, width - 5, U.filled(width - 5, left, 300000), "9")
      C.put(x + width - 4, 13, clock, "0")
    else
      C.put(2, 5, code, "0")
      C.put(3 + #code, 5, clock, "8")
    end
    -- Senders whose pairing attempts were refused while this code was open.
    local rejected = type(view.rejected) == "table" and view.rejected or {}
    if #rejected > 0 and h >= 17 then
      C.put(2, h - 2, "Rejected", "8")
      C.put(11, h - 2, table.concat(rejected, " "):sub(1, math.max(0, w - 11)), "e")
    end
    D.hints(C, 2, h, { { "P", "new code" }, { "Esc", "cancel" } }, 14)
    return C.frame()
  elseif mode == "role" then
    local rows, notice = view.displays or {}, tostring(view.notice or "")
    local width = math.max(1, w - 2)
    local lines = notice == "" and 0 or #notice > width and 2 or 1
    local last = h - 1 - math.max(1, lines)
    C.section(2, 3, w - 2, "DISPLAYS", #rows)
    for i, r in ipairs(rows) do
      local y = 3 + i
      if y > last then break end
      if y == last and i < #rows then C.put(4, y, "+" .. (#rows - i + 1) .. " more", "8"); break end
      C.put(2, y, string.format("%3s", tostring(r.id)), "0")
      C.put(7, y, tostring(r.size or "-"), "8")
      C.put(17, y, tostring(r.role):sub(1, math.max(0, w - 17)), r.role == "unassigned" and "8" or "0")
      if r.label and w > 29 then C.put(28, y, tostring(r.label):sub(1, w - 29), "0") end
    end
    for r = 1, lines do C.put(2, h - 1 - lines + r, notice:sub((r - 1) * width + 1, r * width), "8") end
    local keys, kx = { { "Enter", "set" }, { "Esc", "back" } }, w - 2
    for _, k in ipairs(keys) do kx = kx - #k[1] - 3 - #k[2] end
    local typed = tostring(view.input or ""):sub(-math.max(1, kx - 7))
    C.put(2, h, ">", "9"); C.put(4, h, typed, "0"); C.put(4 + #typed, h, "_", "9")
    D.hints(C, kx, h, keys, 0)
    return C.frame()
  end
  local top
  if mode == "log" then
    C.section(2, 3, w - 2, "LOG", #log)
    top = 4
  else
    local t = model.terminal or { flags = {}, ok = 0, lost = 0, leases = 0, displays = 0 }
    local na = math.min(2, #t.flags)
    for i = 1, na do C.flag(2, 2 + i, w - 2, t.flags[i].text) end
    local y = na > 0 and 4 + na or 3
    local two = w >= 48
    local lw = two and math.floor((w - 5) / 2) or w - 2
    local rx, ry = two and lw + 5 or 2, two and y or y + 5
    C.section(2, y, lw, "FLEET")
    local gone = t.lost > 0 and (" " .. U.g.dot .. " " .. t.lost .. " lost") or ""
    C.leader(2, y + 1, lw, "turtles", t.ok .. " ok" .. gone)
    if t.lost > 0 then C.put(5 + lw - #gone, y + 1, gone:sub(4), "e") end
    C.leader(2, y + 2, lw, "displays", t.displays)
    C.leader(2, y + 3, lw, "leases", t.leases)
    local d = t.disk
    local pct, fg = U.st.diskValue(d)
    C.section(rx, ry, w - rx, "DISK", pct, fg)
    C.ticks(rx, ry + 1, w - rx, d and U.filled(w - rx, d.used, d.cap) or 0, fg == "e" and "e" or "3")
    C.leader(rx, ry + 2, w - rx, "used", d and string.format("%.1f MB", d.used / 1e6) or "-", d and "0" or "8")
    C.leader(rx, ry + 3, w - rx, "pair", view.pending or "-", view.pending and "0" or "8")
    top = ry + 5
    C.section(2, top, w - 2, "LOG")
    top = top + 1
  end
  if view.hostError then C.put(2, 2, tostring(view.hostError):sub(1, math.max(0, w - 2)), "e") end
  local count, last = math.max(0, h - 1 - top), math.max(0, #log - (view.offset or 0))
  for i = math.max(1, last - count + 1), last do D.logLine(C, 2, top + i - math.max(1, last - count + 1), w - 2, tostring(log[i])) end
  if mode == "log" then D.hints(C, 2, h, { { "Esc", "back" }, { "\24\25", "scroll" } }, 14)
  else D.hints(C, 2, h, { { "P", "pair" }, { "R", "roles" }, { "L", "log" } }, 12) end
  return C.frame()
end

-- Every known display for the terminal's role list, lowest id first.
D.listing = function()
  local rows, seen = {}, {}
  local function add(id, w, h, role, label)
    if seen[id] then return end
    seen[id] = true
    rows[#rows + 1] = { id = id, size = w and (w .. "x" .. h) or "-", role = D.label(role), label = label }
  end
  local m, self = D.monitor, D.self()
  local own = os.getComputerLabel and os.getComputerLabel()
  if m and self then add(self, m.session.w, m.session.h, D.localRole(), type(own) == "string" and own ~= "" and own or nil) end
  for id, session in pairs(D.sessions) do
    if session.w then add(id, session.w, session.h, D.roleOf(id), session.label) end
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
  v.pending = SO.pair and type(SO.pair.pending) == "function" and SO.pair.pending() or nil
  local w,h = term.getSize()
  D.paint(term,D.terminal(D.model or { tiles = {} },v,w,h),w,h)
end

D.localTouch = function(side,x,y)
  local m = D.monitor
  if not m or side ~= m.name or not m.frame then return end
  local id
  -- The last button drawn wins, as on display.lua clients.
  for i = #m.frame.buttons, 1, -1 do
    local b = m.frame.buttons[i]
    if x >= b.x and x < b.x+b.w and y >= b.y and y < b.y+(b.h or 1) then id=b.id; break end
  end
  if not id then return end
  -- The tap acts and redraws at once instead of waiting for the next tick.
  D.localDraw(D.now(), {id=id,x=x,y=y})
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
        D.monitor = {target=target,name=name,session={id=D.self(),since=D.since()}}
      else D.monitor.target=target end
    else D.monitor=nil end
  end
  if D.monitor then D.localDraw(now) end
end

-- Handles one tap on the server's monitor, if any, and redraws it at the saved scale.
D.localDraw = function(now, event)
  local m = D.monitor
  local ok, err = pcall(function()
    m.target.setTextScale(D.saved.far[tostring(D.self())] and 1 or 0.5)
    local w,h = m.target.getSize()
    m.session.w, m.session.h = w, h
    local role = D.localRole()
    if m.role ~= role then
      m.role, m.session.page, m.session.visit, m.session.turtle, m.session.alertList = role, nil, nil, nil, nil
    end
    if event and m.frame and m.frame.role ~= role then event = nil end
    if event and not D.visibleInput(m.session, role, event.id) then event = nil end
    if event and event.id:match("^dug%.") then
      D.consent(event, role, w, h, m.session)
    elseif event then
      D.handle(role, m.session, event, now)
    end
    m.frame = D.compose(role,w,h,m.session)
    D.paint(m.target,m.frame,w,h)
    D.rememberFrame(m.session,m.frame)
  end)
  -- Log each new error, then rebuild the monitor on the next tick.
  if not ok then
    local line = "display: monitor " .. tostring(m.name) .. " failed: " .. tostring(err)
    if line ~= D.monitorError then D.monitorError = line; (SO.error or print)(line) end
    D.monitor, D.scanAt = nil, 0
  else D.monitorError = nil end
end

D.tick = function(now)
  if Turtle then D.gatherTurtles() end
  if U then
    D.model = D.gather()
    -- The status frames' only input; a new revision makes every status display compose again.
    local text = D.modelSignature(D.model)
    if not text or text ~= D.modelSig then D.modelRev, D.modelSig = D.modelRev + 1, text end
  end
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
  if U then D.register("disk", D.diskRender, function() end) end
  -- A broken drop on status opens the drop list on it, as a page of the status role.
  D.register("status", D.statusRender, function(event)
    if event.id ~= "broken" or not event.open then return end
    local points = SO.mods.drops and SO.mods.drops.list() or {}
    for _, p in ipairs(points) do if p.broken then event.open("generic", { "list", "focus:" .. p.id }) return end end
  end)
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
  forget = function(id)
    if D.sessions[id] then D.snoozes.clear(D.sessions[id]) end
    D.sessions[id] = nil
  end,
  tick = D.tick,
  screen = D.register,
  far = D.far,
  identify = D.identify,
  palette = D.palette,
  terminal = D.terminal,
  monitorTouch = D.localTouch,
  assign = D.assign,
  command = D.command,
  drawTerminal = D.drawTerminal,
  statusModel = function() return D.model end,
  snoozer = D.snoozer,
}
