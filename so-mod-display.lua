-- so-mod-display.lua - one role per paired display, and the frames it is sent.

local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local D = {
  path = "so-display",
  gap = 4000,
  limit = 4096,
  order = { "shop", "mining", "status", "generic", "lumber", "ar", "panel", "map" },
  known = {},
  box = nil,
  saved = { roles = {}, far = {} },
  screens = {},
  sessions = {},
  pictures = {},
  alertVersions = {},
  alertSequence = 0,
}

if U then
  local probe = U.canvas(15,3)
  probe.header("MAP", "")
  for y,row in ipairs(probe.frame().rows) do
    if row.text:find("MAP",1,true) then D.headerRow=y break end
  end
end

D.now = function() return os.epoch and os.epoch("utc") or 0 end

D.whole = function(n)
  return type(n) == "number" and n % 1 == 0 and n > 0
end

D.acceptSize = function(w, h)
  return D.whole(w) and D.whole(h) and w <= D.limit and h <= D.limit
end

D.roleOf = function(id)
  local role = D.saved.roles[tostring(id)]
  if D.known[role] then return role end
  local session = D.sessions[id]
  if U and role == nil and session and session.w == 26 and session.h == 20 then return "status" end
  return "generic"
end

D.setRole = function(id, role)
  local name = tostring(id)
  local old = D.saved.roles[name]
  local want = U and role or nil
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

D.compose = function(role, w, h, session)
  local banner = D.retirement(w)
  local offset = banner and #banner.rows or 0
  local contentH = math.max(1, h - offset)
  local screen = D.screens[role]
  local picture
  if screen then
    local ok, got
    if U and role == "status" and session and screen.render == D.statusRender then ok, got = pcall(D.statusFrame, session, w, contentH, D.now())
    else ok, got = pcall(screen.render, w, not U and role == "generic" and math.max(1, contentH - 2) or contentH,
      U and session or (session and session.id)) end
    if ok and type(got) == "table" then picture = got end
  end
  if not picture then
    if role ~= "generic" and D.screens.generic then return D.compose("generic", w, h, session) end
    picture = { rows = { { text = "display", fg = "0", bg = "f" } }, buttons = {} }
  end
  local rows = type(picture.rows) == "table" and picture.rows or {}
  local buttons = type(picture.buttons) == "table" and picture.buttons or {}
  if role == "generic" and not U then
    local shifted = { { text = "", fg = "0", bg = "f" }, { text = "", fg = "0", bg = "f" } }
    for i, row in ipairs(rows) do shifted[i + 2] = row end
    rows = shifted
    local copy = {
      { id = "mining", x = 1, y = 1, w = 6, label = "mining" },
      { id = "lumber", x = 8, y = 1, w = 6, label = "lumber" },
      { id = "shop", x = 15, y = 1, w = 4, label = "shop" },
      { id = "status", x = 1, y = 2, w = 6, label = "status" },
      { id = "ar", x = 8, y = 2, w = 2, label = "ar" },
    }
    for _, button in ipairs(buttons) do
      if not D.known[button.id] then
        local moved = {}
        for key, value in pairs(button) do moved[key] = value end
        moved.y = button.y + 2
        copy[#copy + 1] = moved
      end
    end
    buttons = copy
  elseif role == "generic" then
    local copy, found = {}, {}
    for i, button in ipairs(buttons) do copy[i], found[button.id] = button, true end
    for _, button in ipairs({
      { id = "lumber", x = 1, y = 1, w = 6, label = "lumber" },
      { id = "ar", x = 8, y = 1, w = 2, label = "ar" },
    }) do
      if not found[button.id] and not (found.new and found.status) and not found.list then copy[#copy + 1] = button end
    end
    if D.screens.panel and not found.panel and not found.list and w >= 39 then
      copy[#copy + 1] = { id = "panel", x = math.floor((w - 5) / 2) + 1, y = 1, w = 5, label = "PANEL" }
    end
    buttons = copy
  end
  if U and role ~= "map" and D.screens.map and w >= 15 then
    local copy, targets = {}, {}
    for i,row in ipairs(rows) do copy[i]=row end
    local headerRow = D.headerRow
    local row = rows[headerRow] or {text=""}
    local fitted = D.fit({rows={row},buttons={}},w,1).rows[1]
    local text = fitted.text .. string.rep(" ",w)
    local fg,bg = "",""
    if fitted.runs then
      for _,run in ipairs(fitted.runs) do
        fg,bg=fg..string.rep(run[2],run[1]),bg..string.rep(run[3],run[1])
      end
    else
      fg = #(fitted.fg or "0")==1 and string.rep(fitted.fg or "0",w) or fitted.fg
      bg = #(fitted.bg or "f")==1 and string.rep(fitted.bg or "f",w) or fitted.bg
    end
    fg,bg=fg..string.rep("0",w),bg..string.rep("7",w)
    local head,first,last = text:sub(1,w):gsub(" +$",""),nil,nil
    for a,b in head:gmatch("()  +()") do first,last=a,b end
    if first and #head>=w-1 then
      text=head:sub(1,first-1)..string.rep(" ",w-first+1)
      if last-first>=6 then
        local tail=head:sub(last)
        text=text:sub(1,last-6)..tail..string.rep(" ",w)
      end
    end
    copy[headerRow] = {text=text:sub(1,w-4).." MAP", fg=fg:sub(1,w-4).."ffff",
      bg=bg:sub(1,w-4).."9999"}
    for _,b in ipairs(buttons) do targets[#targets+1]=b end
    targets[#targets+1] = {id="map",x=w-3,y=headerRow,w=4,h=1,label=""}
    rows,buttons=copy,targets
  end
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
  local model = { time = U and U.clock(D.now()).hm or "",
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
  if w == 26 and h == 20 then
    local indices = {1,3,4,2,5,6,7,8,9}
    local page = (session.page or 0) % math.max(1, math.ceil(#model.tiles / 3))
    local c = U.canvas(w, h)
    c.header("FLEET", copy.time)
    for i = 1, 3 do
      local index = indices[page * 3 + i]
      local tile = copy.tiles[index]
      if tile then
        local y = 2 + (i - 1) * 6
        c.tile(1, y, w, tile.label, tile.value, index == 4 and copy.oreShort or tile.sub, tile.bg)
        if index == 9 then
          c.fill(1, y + 1, w, 3, tile.bg)
          c.center(1, w, y + 2, "new client:")
        end
      end
    end
    c.button(1, h-1, w, "MORE", "generic", "7", 1)
    c.fill(1, h, w, 1, "7")
    c.put(2, h, "<  glance " .. (page + 1) .. "/" .. math.ceil(#model.tiles / 3) .. "  >  PANEL")
    c.hit("prev", 1, h, 3, 1)
    c.hit("next", 15, h, 3, 1)
    c.hit("panel", 19, h, 7, 1)
    return c.frame()
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
  if U and role == "status" then D.model = D.gather() end
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
  if id and id:match("^dug%.") then
    local session = D.sessions[msg.from]
    if not session or not session.w then return end
    D.consent(body, D.drawn(msg.from), session.w, session.h, session)
    if session.sub then D.sendFrame(msg.from, D.now(), true) end
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
    elseif id == "prev" then session.page = (session.page or 0) - 1
    elseif id == "panel" then D.setRole(msg.from, "panel")
    elseif id == "mining" or id == "lumber" or id == "shop" then D.setRole(msg.from, id) end
  end
  local screen = D.screens[drawn]
  if id == "map" and D.screens.map then
    session.mapReturn = drawn
    D.setRole(msg.from, "map")
  elseif id == "map-back" and drawn == "map" then
    D.setRole(msg.from, session.mapReturn or "status")
  elseif id == "status" then
    D.setRole(msg.from, "status")
  elseif drawn == "panel" and id == "shop" then
    D.setRole(msg.from, "shop")
  elseif drawn == "generic" and type(id) == "string" and D.known[id] then
    D.setRole(msg.from, id)
  elseif id == "generic" and D.roleOf(msg.from) ~= "generic" then
    D.setRole(msg.from, "generic")
  end
  local event = { from = msg.from, id = id, x = body.x, y = body.y, role = drawn, session = session }
  if text ~= nil then event.text = text end
  if screen then pcall(screen.input, event) end
  local session = D.sessions[msg.from]
  if session and session.sub then D.sendFrame(msg.from, D.now(), true) end
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
  if not U then return D.legacyStatus() end
  local C = U.canvas(w,h)
  C.header("SO SERVER #" .. tostring(view.id), view.mode == "code" and "pairing" or view.uptime)
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
  else
    local cols = U.grid(w,h,math.max(1,math.min(4,math.floor((w+1)/13))))
    local bottom = 7
    for i, index in ipairs({1,7,6,3}) do
      local col = cols[(i-1)%#cols+1]
      local y = 3 + math.floor((i-1)/#cols)*6
      local t = model.tiles[index]
      if t then C.tile(col.x,y,col.w,t.label,t.value,(model.terminalSubs or {})[i] or t.sub,t.bg) end
      bottom = math.max(bottom,y+4)
    end
    first = bottom+3
    C.fill(1,first-1,w,1,"7"); C.put(2,first-1,"LOG")
  end
  if view.mode ~= "code" then
    local count = math.max(0,h-first)
    local last = math.max(0,#lines-(view.offset or 0))
    local start = math.max(1,last-count+1)
    for i = start,last do C.put(2,first+i-start,tostring(lines[i]):sub(1,math.max(0,w-2))) end
  end
  C.fill(1,h,w,1,"7")
  C.put(2,h,view.mode == "code" and "[P] new code     [Esc] cancel"
    or view.mode == "log" and "[Esc/L] back  [Up/Down] scroll"
    or "[P] pair a client     [L] full log")
  return C.frame()
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

D.localTick = function(now)
  if peripheral and peripheral.find and now >= (D.scanAt or 0) then
    D.scanAt = now+5000
    local target = peripheral.find("monitor")
    if target then
      local name = peripheral.getName(target)
      if not D.monitor or D.monitor.name ~= name then
        D.monitor = {target=target,name=name,role="status",session={}}
      else D.monitor.target=target end
    else D.monitor=nil end
  end
  local m = D.monitor
  if m then
    local ok = pcall(function()
      m.target.setTextScale(0.5)
      local w,h = m.target.getSize()
      local event = m.pending
      m.pending = nil
      if event and event.id:match("^dug%.") then
        D.consent(event, m.role, w, h, m.session)
      elseif event then
        local drawn = m.role
        if drawn == "status" and (m.session.showAlerts or now < (m.session.alertUntil or 0)) then
          m.session.showAlerts=false
          m.session.alertUntil=0
          event.id="dismiss"
        elseif drawn == "status" and event.id == "next" then
          m.session.page=(m.session.page or 0)+1
        elseif drawn == "status" and event.id == "prev" then
          m.session.page=(m.session.page or 0)-1
        elseif drawn == "status" and event.id == "alerts" then
          m.session.takeover=D.model.alerts[#D.model.alerts]
          m.session.showAlerts=m.session.takeover ~= nil
        elseif event.id == "map" and D.screens.map then
          m.session.mapReturn=drawn
          m.role="map"
        elseif event.id == "map-back" and drawn == "map" then
          m.role=m.session.mapReturn or "status"
        elseif event.id == "status" or event.id == "generic"
          or ((drawn == "status" or drawn == "generic") and D.known[event.id]) then
          m.role=event.id
        end
        local screen=D.screens[drawn]
        event.role=drawn
        if drawn == "panel" and event.id == "shop" then m.role = "shop" end
        event.session=m.session
        if screen then screen.input(event) end
      end
      m.frame = D.compose(m.role,w,h,m.session)
      D.paint(m.target,m.frame,w,h)
    end)
    if not ok then D.monitor=nil end
  end
end

D.tick = function(now)
  if U then D.model = D.gather() end
  D.localTick(now)
  if SO.terminal and term and term.blit then
    local v = SO.terminal
    v.now = now
    local minutes = math.floor((now-v.started)/60000)
    v.uptime = string.format("up %dh%02d",math.floor(minutes/60),minutes%60)
    local w,h = term.getSize()
    D.paint(term,D.terminal(D.model,v,w,h),w,h)
  end
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
  terminal = D.terminal,
  monitorTouch = D.localTouch,
}
