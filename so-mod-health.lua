local U = dofile("so-ui.lua")
local H = { now=0, items={}, metrics={}, jobs={}, kinds={} }

local function call(name, method, ...)
  local mod = SO.mods[name]
  if mod and type(mod[method]) == "function" then return mod[method](...) end
end

local function generation(path)
  if type(SO.store.read) ~= "function" then return end
  local picked
  for _, suffix in ipairs({"", ".tmp", ".bak"}) do
    local v = SO.store.read(path..suffix)
    if type(v) == "table" and v.schema == 1 and type(v.generation) == "number"
      and type(v.value) == "table" and (not picked or v.generation > picked.generation) then picked = v end
  end
  return picked and picked.value
end

local function duration(ms)
  local s = math.max(0,math.floor((ms or 0)/1000))
  if s < 60 then return s.."s" end
  if s < 3600 then return math.floor(s/60).."m" end
  return string.format("%dh%02dm",math.floor(s/3600),math.floor(s/60)%60)
end

local function poseText(p)
  if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number" then
    return "x"..p.x.." y"..p.y.." z"..p.z
  end
end

local function bytes(n)
  if type(n) ~= "number" then return "-" end
  if n >= 1048576 then return string.format("%.1f MB",n/1048576) end
  if n >= 1024 then return string.format("%.1f KB",n/1024) end
  return n.." B"
end

-- This hook accepts gathered facts and never changes jobs or reservations.
local function attention(facts)
  local rows = {}
  local function add(key, severity, text, target, actions)
    rows[#rows+1] = {key=key,severity=severity,text=text,target=target,actions=actions}
  end
  for _, p in ipairs(facts.points or {}) do
    if p.broken or (p.fails or 0) >= 3 then
      add("drop/"..p.id,1,"Chest "..p.id.." broken","generic",{"list","select:"..p.id})
    end
  end
  for i, alert in ipairs(facts.fuelAlerts or {}) do
    add("fuel/"..i,2,alert.text,"mining",{"setup"})
  end
  local owners = {}
  for role, job in pairs(facts.jobs or {}) do
    for id, row in pairs(job.turtles or {}) do
      owners[tostring(id)] = role
      local reason = row.blocked or row.alert
      if row.state == "hold" or row.state == "range" or reason then
        add(role.."/"..id,2,"T"..id.." "..tostring(row.error or reason or row.state),role)
      end
    end
    if job.turtle then owners[tostring(job.turtle.id)] = role end
    if job.blocked or job.alert then
      add(role,2,role:upper().." "..tostring(job.alert or job.blocked),role)
    end
  end
  if facts.configError then add("config",1,"Config unreadable; defaults active","health") end
  if facts.gpsGap and facts.gpsGap > 2 then
    add("gps",2,string.format("Server GPS gap %.1f blocks",facts.gpsGap),"health")
  end
  for id, row in pairs(facts.machines or {}) do
    local lease = (facts.leases or {})[tostring(id)] or {}
    local role = owners[tostring(id)] or "mining"
    local kind = owners[tostring(id)] == "mining" and "pickaxe" or owners[tostring(id)] == "lumber" and "axe"
    if kind and type(lease.tools) == "table" then
      local equipped = false
      for _, name in pairs(lease.tools) do
        if type(name) == "string" and name:match("_"..kind.."$") then equipped = true end
      end
      if not equipped or lease.toolError then
        add("tool/"..id,2,"T"..id.." "..(lease.toolError or ("needs "..kind)),role,{"setup"})
      end
    end
    local seen = math.max(row.seen or 0,lease.seen or 0)
    if lease.uncertain then
      add("pose/"..id,1,"T"..id.." pose uncertain",role,{"setup"})
    elseif lease.lost or ((row.role == "worker" or row.role == "turtle") and facts.now-seen>180000) then
      if not (facts.snoozed or {})[tostring(id)] then
        local pose = poseText(row.pose)
        add("lost/"..id,1,"T"..id.." lost "..duration(facts.now-seen)..(pose and " "..pose or ""),role)
        rows[#rows].lost = {id=tostring(id),seen=seen,pose=pose}
      end
    end
  end
  if facts.retirement and facts.retirement.status == "pending" then
    add("dug",2,"Dug marks consent","status")
  elseif facts.retirement and facts.retirement.status == "snoozed" then
    add("disk-snooze",2,"Add disk space","health")
  end
  if (facts.disk.ratio or 0) >= 0.8 then add("disk",1,"Disk "..math.floor(facts.disk.ratio*100).."% full","health") end
  if facts.clockRefused then add("clock",1,"Clock frozen; checkpoint refused","health") end
  if (facts.errorCount or 0) > 0 and facts.errorAt and facts.now >= facts.errorAt and facts.now-facts.errorAt < 600000 then
    add("errors",2,"Server errors "..facts.errorCount,"errors")
  end
  if facts.forgotten then
    add("forgotten",2,facts.forgotten.text,"panel",{"pair"})
  end
  if facts.pairing then add("pair",2,"Pairing open","panel",{"pair"}) end
  for _, request in ipairs(facts.requests or {}) do
    add("pair/"..tostring(request.id),2,"Pair "..tostring(request.id),"panel",{"pair"})
  end
  table.sort(rows,function(a,b) return a.severity==b.severity and a.key<b.key or a.severity<b.severity end)
  while #rows > 256 do rows[#rows] = nil end
  return rows
end

H.gather = function(now)
  local state = SO.mods.state
  local machines = call("state","get","machines") or {}
  local keys = generation("so-keys")
  for id in pairs(keys and keys.keys or {}) do
    if not machines[tostring(id)] then machines[tostring(id)] = {id=tonumber(id)} end
  end
  if not H.snoozes then H.snoozes = call("display","snoozer",3600000) end
  H.snoozedAt = H.snoozedAt or {}
  local snoozed = {}
  local leases, online, lost, open = {}, 0, 0, 0
  for id, row in pairs(machines) do
    local lease = call("lease","status",tonumber(id)) or {}
    local key, seen = tostring(id), math.max(row.seen or 0,lease.seen or 0)
    if H.snoozes then
      if H.snoozedAt[key] and seen > H.snoozedAt[key] then H.snoozes.clear(key);H.snoozedAt[key]=nil end
      snoozed[key] = H.snoozes.on(key,now)
      if not snoozed[key] then H.snoozedAt[key]=nil end
    end
    leases[key] = lease
    if lease.open then open = open+1 end
    if row.seen and now-row.seen<=180000 and not lease.lost then online=online+1 else lost=lost+1 end
  end
  H.jobs = {mining=generation("so-data/mine/job"),lumber=generation("so-data/lumber/job")}
  local diskFrame = state and state.view and state.view.get({name="status"})
  local disk = diskFrame and diskFrame.data or {}
  local enroll = SO.enroll and SO.enroll.view()
  local errors = SO.errors and SO.errors.status() or {}
  local entries = SO.errors and SO.errors.entries() or {}
  local runtime = SO.health or {}
  H.items = attention({now=now,machines=machines,leases=leases,jobs=H.jobs,disk=disk,snoozed=snoozed,
    gpsGap=runtime.gpsGap,configError=runtime.configError,
    clockRefused=SO.clock and SO.clock.refused,
    errorCount=errors.count,errorAt=entries[#entries] and entries[#entries].at,
    points=call("drops","list") or {},fuelAlerts=call("shop","fuelAlerts") or {},retirement=call("cells","retirement"),
    forgotten=call("state","get","pair.forgotten"),
    pairing=SO.pair and SO.pair.pending and SO.pair.pending() ~= nil,
    requests=enroll and enroll.rows or {}})
  local log = call("state","diagnostics") or {}
  local clock = generation("so-data/clock")
  local modems = peripheral and peripheral.find and {peripheral.find("modem")} or {}
  -- Leaders { label, value, fg?, tail? } for the health page: a value of "-" is muted, a tail is the
  -- value's coral end.
  local dot, ratio = " "..U.g.dot.." ", disk.ratio or 0
  local function ms(v) return v and (v.."ms") or "-" end
  local snapshot = log.snapshot and log.snapshot>0 and ("#"..log.snapshot.." "..(log.snapshotAt and duration(now-log.snapshotAt) or "age unknown"))
  H.metrics = {
    {"uptime", duration(now-(runtime.started or now))},
    {"tick", ms(runtime.cadence)..dot.."wall "..ms(runtime.wallCadence)},
    {"tick cost", ms(runtime.tickMs)},
    {"clock reserve", SO.clock and SO.clock.refused and "refused" or clock and duration(clock.ceiling-now) or "unknown",
      SO.clock and SO.clock.refused and "e" or not clock and "8"},
    {"events", log.available and ("#"..log.seq..dot..log.segments.." seg") or "unavailable", not log.available and "8"},
    {"event bytes", bytes(log.bytes)},
    {"snapshot", (snapshot or "none")..(log.due and " due" or ""), log.due and "1" or not snapshot and "8"},
    {"disk", math.floor(ratio*100).."%", ratio >= 0.8 and "e"},
    {"disk free", bytes(disk.free)},
    {"errors", tostring(errors.count or 0)..dot..bytes(errors.bytes or 0)},
    {"modems", tostring(#modems)},
    {"paired", online.." online"..dot..lost.." lost", nil, lost > 0 and (lost.." lost")},
    {"leases", open.." open"},
  }
  if runtime.modules then
    local cfg = type(runtime.config) == "table" and runtime.config or {}
    local loaded, failed, absent, modules = 0, 0, 0, {}
    for file, status in pairs(runtime.modules or {}) do
      modules[#modules+1] = file
      if status.status == "loaded" and not status.tickError then loaded=loaded+1
      elseif status.status == "absent" then absent=absent+1 else failed=failed+1 end
    end
    table.sort(modules)
    local summary = #modules > 0 and (loaded.." loaded") or "unavailable"
    local flags = {}
    for _, name in ipairs({"enroll","retireLegacyPair","remoteDimensions","setupMovement","dropsSavedSetup",
      "arFollowups","panelUpdates","workerSettings","workerPark"}) do
      if cfg[name] == true then flags[#flags+1] = name end
    end
    if type(cfg.state) == "table" and cfg.state.coalesceHeartbeats == true then flags[#flags+1]="state.coalesceHeartbeats" end
    local prefix = {
      {"modules",summary}, {"skip",failed.." fail "..absent.." absent"}, {"rev",runtime.revision and runtime.revision:sub(1,8) or "unknown"},
      {"cfg",runtime.configError and "unreadable" or #flags==0 and "defaults" or flags[1]},
      {"pos",poseText(cfg.pos) or "missing"},
      {"GPS gap",runtime.gpsGap and string.format("%.1f blocks",runtime.gpsGap) or "unavailable",runtime.gpsGap and runtime.gpsGap>2 and "1"},
    }
    for i=2,#flags do prefix[#prefix+1] = {"cfg",flags[i]} end
    for _, metric in ipairs(H.metrics) do prefix[#prefix+1]=metric end
    for _, file in ipairs(modules) do
      local status = runtime.modules[file]
      local name = file:match("^so%-mod%-(.+)%.lua$") or file
      local value = status.status == "loaded" and (status.tickError and "tick failed" or status.lastGood
        and ("ok "..duration(now-status.lastGood).." ago") or "loaded") or status.status
      prefix[#prefix+1] = {name,value,(status.status=="failed" or status.tickError) and "e" or status.status=="absent" and "8"}
      if status.error or status.tickError then prefix[#prefix+1] = {"error",status.error or status.tickError,"e"} end
    end
    H.metrics = prefix
  end
  if errors.error then H.metrics[#H.metrics+1] = {flag="error save "..errors.error} end
  if entries[#entries] then H.metrics[#H.metrics+1] = {last=entries[#entries].text} end
end

local function sessionView(session, role)
  session.visibility = session.visibility or {}
  session.visibility[role] = session.visibility[role] or {page=1,cursors={}}
  return session.visibility[role]
end

local function errorCut(text, width)
  local cut = math.max(0,math.min(#text,width))
  local byte = text:byte(cut+1)
  while cut > 0 and byte and byte >= 128 and byte <= 191 do
    cut = cut-1
    byte = text:byte(cut+1)
  end
  return cut
end

local function errorWrap(text, width)
  local rows, line = {}, ""
  width = math.max(1,width)
  for word in text:gmatch("%S+") do
    while #word > width do
      if line ~= "" then rows[#rows+1],line = line,"" end
      local cut = errorCut(word,width)
      if cut == 0 then
        cut = 1
        local byte = word:byte(cut+1)
        while byte and byte >= 128 and byte <= 191 do cut=cut+1;byte=word:byte(cut+1) end
      end
      rows[#rows+1],word = word:sub(1,cut),word:sub(cut+1)
    end
    if line == "" then line = word
    elseif #line+1+#word <= width then line = line.." "..word
    else rows[#rows+1],line = line,word end
  end
  if line ~= "" then rows[#rows+1] = line end
  return rows
end

-- The footer's left chip sits on the last row when it ends a blank column before the pager's note
-- and arrows, else on the row above. Returns the rows the footer takes.
local function footerRows(w, label, note)
  return #label+5 <= (note ~= "" and w-8-#note or w-7) and 1 or 2
end

-- Rows per page and pages for count lines under a left chip and an n/m note. Returns the capacity,
-- the pages and the footer rows.
local function fitPages(count, capacity, page, w, label)
  local pages = math.max(1,math.ceil(count/capacity))
  local rows = footerRows(w,label,math.max(1,math.min(page or 1,pages)).."/"..pages)
  if rows == 2 then
    capacity = math.max(1,capacity-1)
    pages = math.max(1,math.ceil(count/capacity))
  end
  return capacity, pages, rows
end

-- An event's recorded facts as leaders { label, value }, from an allowlist of scalar data fields,
-- then its text as the last row.
local FACTS = {{"id","id"},{"label","label"},{"role","role"},{"pos"},{"count","count"},{"item","name"},
  {"total","total"},{"fuel","fuel"},{"level","level"},{"branch","branch"},{"done","done"},{"op","op"},
  {"reason","reason"}}

local function facts(entry)
  local data, rows = entry.data, {}
  local function scalar(v) return (type(v)=="string" or type(v)=="number" or type(v)=="boolean") and tostring(v) end
  if type(data) == "table" then
    for _, f in ipairs(FACTS) do
      local value
      if f[1] == "pos" then
        local p = type(data.x)=="number" and data or type(data.point)=="table" and data.point or {}
        if type(p.x)=="number" and type(p.y)=="number" and type(p.z)=="number" then value = p.x.." "..p.y.." "..p.z end
      else value = scalar(data[f[2]]) end
      if value then rows[#rows+1] = {f[1],value} end
    end
  end
  local text = type(data)=="table" and scalar(data.text) or type(data)=="string" and data or data==false and "cleared"
  return rows, text
end

-- Route A (docs/ui/schematic/other.py health): HEALTH and NEEDS, then EVENTS ALERTS ERRORS as tabs,
-- the page's rows, and the paging chips on the last row.
H.render = function(role,w,h,session)
  session = session or {}
  local v = sessionView(session,role)
  local c = U.canvas(w,h)
  if h < 5 then c.chip(2,h,"BACK","generic");return c.frame() end
  local first = H.items[1]
  local last = U.tabRows(c,{{{"HEALTH","health"},{"NEEDS "..#H.items,"attention",first and (first.severity==1 and "e" or "1")}},
    {{"EVENTS","events"},{"ALERTS","alerts"},{"ERRORS","errors"}}},role,4)
  local gap, lw = h >= 16 and 1 or 0, math.min(w-2,40)
  local top = last+1+gap
  if role == "attention" and v.lost then
    local row
    for _, item in ipairs(H.items) do if item.key == v.lost then row=item end end
    if row and row.lost then
      c.put(2,top,"T"..row.lost.id.." lost "..duration(H.now-row.lost.seen),"e")
      c.put(2,top+1,U.fit(row.lost.pose or "pose unknown",lw),"0")
      c.chip(2,h,"BACK","lost-back")
      if H.snoozes then c.chip(9,h,"SNOOZE","lost-snooze") end
      c.chip(w-5,h,"OPEN","lost-open")
      v.lostRow = row
      return c.frame()
    end
    v.lost,v.lostRow = nil,nil
  end
  local history = role == "events" or role == "alerts"
  if history and v.fact then
    -- One event's facts: its kind and age, then leaders and the text, BACK to the same list page.
    local e = v.fact
    c.put(2,top,e.kind:sub(1,w-2),"0")
    local age = duration(H.now-(e.gameAt or H.now)).." ago"
    if 3+#e.kind+#age <= w then c.put(3+#e.kind,top,age,"8") end
    top = top+1+gap
    local rows, text = facts(e)
    for _, line in ipairs(text and U.wrap((text:gsub("[%c]"," ")),lw-5) or {}) do
      rows[#rows+1] = {label=#rows>0 and rows[#rows].label and "" or "text",text=line}
    end
    v.targets = {}
    for i, row in ipairs(rows) do
      local y = top+i-1
      if y >= h then break end
      if row.text then c.put(2,y,row.label,"8") c.put(7,y,row.text,"0")
      else c.leader(2,y,lw,row[1],row[2]:sub(1,math.max(1,lw-#row[1]-2))) end
    end
    c.chip(2,h,"BACK","fact-back")
    return c.frame()
  end
  if role == "events" and v.picker then
    -- The kind picker: ALL and every kind in the log, the current one marked.
    local kinds = v.picker.kinds
    local capacity, pages, foot = fitPages(#kinds,math.max(1,h-gap-top),v.picker.page,w,"BACK")
    v.picker.page = math.max(1,math.min(v.picker.page,pages))
    v.targets = {}
    for i=1,capacity do
      local n = (v.picker.page-1)*capacity+i
      local kind, y = kinds[n], top+i-1
      if not kind then break end
      if kind == (v.kind or "all") then c.put(2,y,U.g.bullet,"0") end
      c.put(4,y,kind:sub(1,w-4),kind == (v.kind or "all") and "0" or "8")
      c.hit("pick:"..n,1,y,w,1,kind)
    end
    c.chip(2,h-foot+1,"BACK","kind-back")
    U.pager(c,h,v.picker.page.."/"..pages,v.picker.page>1,v.picker.page<pages)
    return c.frame()
  end
  if role == "events" then
    c.put(2,top,"kind","8")
    c.chip(7,top,v.kind or "all","kind")
    top = top+1+gap
    if v.find then
      c.put(2,top,"find","8")
      c.chip(7,top,v.find:sub(1,w-9),"find")
      top = top+1+gap
    end
  end
  local capacity = math.max(0,h-1-gap-top+1)
  -- Page 1 follows new events until HOLD pins its newest sequence; LIVE and LATEST return to it.
  local left, note, foot
  if history then
    left = v.page > 1 and {"LATEST","latest"} or v.cursors[1] and {"LIVE","live","primary"} or {"HOLD","hold"}
    note = v.page > 1 and tostring(v.page) or ""
    foot = footerRows(w,left[1],note)
    capacity = math.max(0,capacity-foot+1)
  end
  if role == "errors" and v.error then
    c.put(2,top,duration(H.now-v.error.at).." ago","8")
    top = top+1+gap
    local lines = errorWrap(v.error.text:gsub("[%c]"," "),lw)
    local pages, foot
    capacity, pages, foot = fitPages(#lines,math.max(1,h-gap-top),v.errorPage,w,"BACK")
    v.errorPage = math.max(1,math.min(v.errorPage or 1,pages))
    v.errorNext = v.errorPage < pages
    v.targets = {}
    for i=1,capacity do
      local line = lines[(v.errorPage-1)*capacity+i]
      if line then c.put(2,top+i-1,line,"0") end
    end
    c.chip(2,h-foot+1,"BACK","error-back")
    U.pager(c,h,v.errorPage.."/"..pages,v.errorPage>1,v.errorNext)
    return c.frame()
  end
  local rows, page = {}, nil
  if role == "health" then
    for _, m in ipairs(H.metrics) do
      if m.last then
        for i, line in ipairs(U.wrap(m.last,lw-5)) do
          if i <= 2 then rows[#rows+1] = {label=i==1 and "last" or "",text=line} end
        end
      else rows[#rows+1] = m end
    end
  elseif role == "attention" then rows=H.items
  elseif role == "errors" then
    local entries = SO.errors and SO.errors.entries() or {}
    for i=#entries,1,-1 do
      rows[#rows+1] = {time=duration(H.now-entries[i].at),text=entries[i].text:match("^[^\r\n]*"),
        fg="e",entry=entries[i],id="error:"..i}
    end
  else
    local state = SO.mods.state
    if state and state.history then
      page = state.history.page({reverse=true,before=v.cursors[v.page],count=math.max(1,capacity),kind=v.kind,
        text=role=="events" and v.find or nil,alerts=role=="alerts"})
      if v.page == 1 then v.top = page.entries[1] and page.entries[1].seq end
      for i, e in ipairs(page.entries) do
        local data = e.data
        local text = type(data)=="table" and (data.text or data.reason) or type(data)=="string" and data or data==false and "cleared"
        local kind = role == "alerts" and (e.kind:gsub("%.alert$","")) or e.kind
        rows[#rows+1] = {time=duration(H.now-(e.gameAt or H.now)),kind=kind,text=text and tostring(text) or "",
          fg=role=="alerts" and "e" or U.mark(e.kind..(text and " "..tostring(text) or "")),entry=e,id="event:"..i}
        H.kinds[e.kind] = true
      end
    end
    v.next = page and page.next
  end
  if not page then
    v.page = math.max(1,math.min(v.page,math.max(1,math.ceil(#rows/math.max(1,capacity)))))
    v.next = v.page*capacity < #rows and v.page+1 or nil
  end
  v.targets = {}
  if #rows == 0 then
    if role == "attention" then c.put(2,top,"all clear","d") else c.put(2,top,"no entries","8") end
  end
  local start = page and 1 or (v.page-1)*capacity+1
  for i=1,capacity do
    local row, y = rows[start+i-1], top+i-1
    if row and role == "health" then
      if row.flag then c.flag(2,y,lw,row.flag)
      elseif row.text then c.put(2,y,row.label,"8") c.put(7,y,row.text,"0")
      else
        c.leader(2,y,lw,row[1],U.fit(row[2],math.max(1,lw-#row[1]-1)),row[3] or (row[2]=="-" and "8" or "0"))
        if row[4] then c.put(2+lw-#row[4],y,row[4],"e") end
      end
    elseif row and role == "attention" then
      c.put(2,y,"!",row.severity==1 and "e" or "1")
      c.put(4,y,U.fit((row.text:gsub("[%c]"," ")),w-4),"0")
      if row.target then
        local id = "item:"..row.key
        c.hit(id,1,y,w,1)
        v.targets[id] = row
      end
    elseif row then
      c.put(2,y,U.g.bullet,row.fg)
      c.put(4,y,row.time,"8")
      local x = 5+#row.time
      if row.kind then c.put(x,y,row.kind:sub(1,math.max(0,w-x)),"8") x = x+#row.kind+1 end
      local text = row.text:gsub("[%c]"," ")
      local fitted = U.fit(text,w-x)
      if role == "errors" then fitted = text:sub(1,errorCut(text,#fitted)) end
      c.put(x,y,fitted,"0")
      if row.entry then
        c.hit(row.id,1,y,w,1)
        v.targets[row.id] = row.entry
      end
    end
  end
  local pages = math.max(1,math.ceil(#rows/math.max(1,capacity)))
  if history then c.chip(2,h-foot+1,left[1],left[2],left[3]) end
  U.pager(c,h,note or (v.page.."/"..pages),v.page>1,v.next~=nil)
  return c.frame()
end

H.input = function(role,event)
  if not event.session then return end
  local v = sessionView(event.session,role)
  local id = event.id
  if role == "attention" and v.lostRow then
    local row = v.lostRow
    if id == "lost-snooze" and H.snoozes then
      H.snoozes.set(row.lost.id,H.now)
      H.snoozedAt[row.lost.id] = row.lost.seen
      H.gather(H.now)
      v.lost,v.lostRow = nil,nil
    elseif id == "lost-open" and event.open then
      v.lost,v.lostRow = nil,nil
      event.open(row.target,row.actions)
    elseif id == "lost-back" then v.lost,v.lostRow = nil,nil
    elseif event.open and (id=="health" or id=="attention" or id=="events" or id=="alerts" or id=="errors") then
      v.lost,v.lostRow = nil,nil
      event.open(id)
    end
  elseif role == "attention" and v.targets and v.targets[id] and v.targets[id].lost then
    v.lost = v.targets[id].key
  elseif role == "errors" and id == "error-back" then
    v.error,v.errorPage,v.errorNext = nil,nil,nil
  elseif role == "errors" and v.error then
    if id == "next" and v.errorNext then v.errorPage = v.errorPage+1
    elseif id == "prev" then v.errorPage = math.max(1,v.errorPage-1)
    elseif event.open and (id=="health" or id=="attention" or id=="events" or id=="alerts" or id=="errors") then
      v.error = nil
      event.open(id)
    end
  elseif role == "errors" and v.targets and v.targets[id] then
    local entry = v.targets[id]
    v.error,v.errorPage = {at=entry.at,text=entry.text},1
  elseif (role == "events" or role == "alerts") and (v.fact or v.picker) then
    if id == "fact-back" then v.fact = nil
    elseif id == "kind-back" then v.picker = nil
    elseif v.picker and id == "next" then v.picker.page = v.picker.page+1
    elseif v.picker and id == "prev" then v.picker.page = math.max(1,v.picker.page-1)
    elseif v.picker and type(id) == "string" and id:match("^pick:%d+$") then
      local kind = v.picker.kinds[tonumber(id:sub(6))]
      if kind then
        v.kind = kind ~= "all" and kind or nil
        v.page,v.cursors,v.picker = 1,{},nil
      end
    elseif event.open and (id=="health" or id=="attention" or id=="events" or id=="alerts" or id=="errors") then
      v.fact,v.picker = nil,nil
      event.open(id)
    end
  elseif (role == "events" or role == "alerts") and v.targets and v.targets[id] then
    v.fact = v.targets[id]
  elseif (role == "events" or role == "alerts") and id == "hold" and v.page == 1 then
    v.cursors[1] = (v.top or 0)+1
  elseif (role == "events" or role == "alerts") and (id == "live" or id == "latest") then
    v.page,v.cursors = 1,{}
  elseif role == "events" and id == "find" then
    v.find,v.page,v.cursors = nil,1,{}
  elseif role == "events" and type(event.text) == "string" then
    -- Typed text searches EVENTS; blank or * clears the search.
    local text = event.text:match("^%s*(.-)%s*$"):sub(1,32)
    v.find = text ~= "" and text ~= "*" and text or nil
    v.page,v.cursors = 1,{}
  elseif id == "next" and v.next then
    v.page = v.page+1
    if role == "events" or role == "alerts" then v.cursors[v.page] = v.next end
  elseif id == "prev" then v.page=math.max(1,v.page-1)
  elseif id == "kind" and role == "events" then
    -- Every kind in the log when state offers history.kinds, else the kinds drawn since boot.
    local state, kinds = SO.mods.state, nil
    if state and state.history and type(state.history.kinds) == "function" then kinds = state.history.kinds() end
    if type(kinds) ~= "table" then
      kinds = {}
      for kind in pairs(H.kinds) do kinds[#kinds+1]=kind end
      table.sort(kinds)
    end
    local list = {"all"}
    for _, kind in ipairs(kinds) do if type(kind) == "string" and kind ~= "all" then list[#list+1] = kind end end
    v.picker = {page=1,kinds=list}
  elseif event.open then
    local row = v.targets and v.targets[id]
    if row then event.open(row.target,row.actions)
    elseif id=="health" or id=="attention" or id=="events" or id=="alerts" or id=="errors" then event.open(id) end
  end
end

H.tick = function(now)
  H.now = now
  local clock, refused = os.clock(), SO.clock and SO.clock.refused
  if not H.last or clock-H.last>=5 or refused~=H.refused then
    H.gather(now);H.last=clock;H.refused=refused
  end
  local display = SO.mods.display
  if display and not H.registered then
    for _, role in ipairs({"health","attention","alerts","events","errors"}) do
      display.screen(role,function(w,h,s) return H.render(role,w,h,s) end,function(e) return H.input(role,e) end)
    end
    H.registered=true
  end
end
return {name="health",handlers={},tick=H.tick,attention=attention,count=function() return #H.items end}
