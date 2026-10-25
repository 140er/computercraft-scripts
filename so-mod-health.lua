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
    if lease.uncertain then
      add("pose/"..id,1,"T"..id.." pose uncertain",role,{"setup"})
    elseif lease.lost or ((row.role == "worker" or row.role == "turtle") and facts.now-(row.seen or 0)>180000) then
      add("lost/"..id,1,"T"..id.." lost",role)
    end
  end
  if facts.retirement and facts.retirement.status == "pending" then
    add("dug",2,"Dug marks consent","status")
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

local function duration(ms)
  local s = math.max(0,math.floor((ms or 0)/1000))
  if s < 60 then return s.."s" end
  if s < 3600 then return math.floor(s/60).."m" end
  return string.format("%dh%02dm",math.floor(s/3600),math.floor(s/60)%60)
end

H.gather = function(now)
  local state = SO.mods.state
  local machines = call("state","get","machines") or {}
  local keys = generation("so-keys")
  for id in pairs(keys and keys.keys or {}) do
    if not machines[tostring(id)] then machines[tostring(id)] = {id=tonumber(id)} end
  end
  local leases, online, lost, open = {}, 0, 0, 0
  for id, row in pairs(machines) do
    local lease = call("lease","status",tonumber(id)) or {}
    leases[tostring(id)] = lease
    if lease.open then open = open+1 end
    if row.seen and now-row.seen<=180000 and not lease.lost then online=online+1 else lost=lost+1 end
  end
  H.jobs = {mining=generation("so-data/mine/job"),lumber=generation("so-data/lumber/job")}
  local diskFrame = state and state.view and state.view.get({name="status"})
  local disk = diskFrame and diskFrame.data or {}
  local enroll = SO.enroll and SO.enroll.view()
  local errors = SO.errors and SO.errors.status() or {}
  local entries = SO.errors and SO.errors.entries() or {}
  H.items = attention({now=now,machines=machines,leases=leases,jobs=H.jobs,disk=disk,
    clockRefused=SO.clock and SO.clock.refused,
    errorCount=errors.count,errorAt=entries[#entries] and entries[#entries].at,
    points=call("drops","list") or {},fuelAlerts=call("shop","fuelAlerts") or {},retirement=call("cells","retirement"),
    forgotten=call("state","get","pair.forgotten"),
    pairing=SO.pair and SO.pair.pending and SO.pair.pending() ~= nil,
    requests=enroll and enroll.rows or {}})
  local log = call("state","diagnostics") or {}
  local clock = generation("so-data/clock")
  local runtime = SO.health or {}
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
    {"clock reserve", SO.clock and SO.clock.refused and "refused" or clock and duration(clock.ceiling-now) or "unavailable",
      SO.clock and SO.clock.refused and "e" or not clock and "8"},
    {"events", log.available and ("#"..log.seq..dot..log.segments.." seg") or "unavailable", not log.available and "8"},
    {"event bytes", tostring(log.bytes or "-")},
    {"snapshot", (snapshot or "none")..(log.due and " due" or ""), log.due and "1" or not snapshot and "8"},
    {"disk", math.floor(ratio*100).."%", ratio >= 0.8 and "e"},
    {"disk free", disk.free and (disk.free.." B") or "-"},
    {"errors", tostring(errors.count or 0)..dot..tostring(errors.bytes or 0).." B"},
    {"modems", tostring(#modems)},
    {"paired", online.." online"..dot..lost.." lost", nil, lost > 0 and (lost.." lost")},
    {"leases", open.." open"},
  }
  if errors.error then H.metrics[#H.metrics+1] = {flag="error save "..errors.error} end
  if entries[#entries] then H.metrics[#H.metrics+1] = {last=entries[#entries].text} end
end

local function sessionView(session, role)
  session.visibility = session.visibility or {}
  session.visibility[role] = session.visibility[role] or {page=1,cursors={}}
  return session.visibility[role]
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
  if role == "events" then
    c.put(2,top,"kind","8")
    c.chip(7,top,v.kind or "all","kind")
    top = top+1+gap
  end
  local capacity = math.max(0,h-1-gap-top+1)
  if role == "errors" and v.error then
    c.put(2,top,duration(H.now-v.error.at).." ago","8")
    top = top+1+gap
    capacity = math.max(1,h-gap-top)
    local lines = U.wrap(v.error.text:gsub("[%c]"," "),lw)
    local pages = math.max(1,math.ceil(#lines/capacity))
    v.errorPage = math.max(1,math.min(v.errorPage or 1,pages))
    v.errorNext = v.errorPage < pages
    v.targets = {}
    for i=1,capacity do
      local line = lines[(v.errorPage-1)*capacity+i]
      if line then c.put(2,top+i-1,line,"0") end
    end
    c.chip(2,h,"BACK","error-back")
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
      rows[#rows+1] = {time=duration(H.now-entries[i].at),text=entries[i].text,fg="e",entry=entries[i],id="error:"..i}
    end
  else
    local state = SO.mods.state
    if state and state.history then
      page = state.history.page({reverse=true,before=v.cursors[v.page],count=math.max(1,capacity),kind=v.kind,alerts=role=="alerts"})
      for _, e in ipairs(page.entries) do
        local data = e.data
        local text = type(data)=="table" and (data.text or data.reason) or type(data)=="string" and data or data==false and "cleared"
        local kind = role == "alerts" and (e.kind:gsub("%.alert$","")) or e.kind
        rows[#rows+1] = {time=duration(H.now-(e.gameAt or H.now)),kind=kind,text=text and tostring(text) or "",
          fg=role=="alerts" and "e" or U.mark(e.kind..(text and " "..tostring(text) or ""))}
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
        c.leader(2,y,lw,row[1],row[2],row[3] or (row[2]=="-" and "8" or "0"))
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
      c.put(x,y,U.fit((row.text:gsub("[%c]"," ")),w-x),"0")
      if role == "errors" then
        c.hit(row.id,1,y,w,1)
        v.targets[row.id] = row.entry
      end
    end
  end
  local pages = math.max(1,math.ceil(#rows/math.max(1,capacity)))
  U.pager(c,h,not page and (v.page.."/"..pages) or "",v.page>1,v.next~=nil)
  return c.frame()
end

H.input = function(role,event)
  if not event.session then return end
  local v = sessionView(event.session,role)
  local id = event.id
  if role == "errors" and id == "error-back" then
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
  elseif id == "next" and v.next then
    v.page = v.page+1
    if role == "events" or role == "alerts" then v.cursors[v.page] = v.next end
  elseif id == "prev" then v.page=math.max(1,v.page-1)
  elseif id == "kind" or type(event.text)=="string" and role=="events" then
    local kinds = {"ALL"}
    for kind in pairs(H.kinds) do kinds[#kinds+1]=kind end
    table.sort(kinds)
    local nextKind = kinds[1]
    for i,kind in ipairs(kinds) do if kind==(v.kind or "ALL") then nextKind=kinds[i%#kinds+1] break end end
    v.kind = event.text or nextKind
    if v.kind=="ALL" or v.kind=="*" or v.kind=="" then v.kind=nil end
    v.page,v.cursors = 1,{}
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
