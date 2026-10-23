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
      if row.state == "hold" or row.state == "range" then
        add(role.."/"..id,2,"T"..id.." "..tostring(row.error or row.state),role)
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
  H.items = attention({now=now,machines=machines,leases=leases,jobs=H.jobs,disk=disk,
    points=call("drops","list") or {},fuelAlerts=call("shop","fuelAlerts") or {},retirement=call("cells","retirement"),
    pairing=SO.pair and SO.pair.pending and SO.pair.pending() ~= nil,
    requests=SO.pair and SO.pair.requests and SO.pair.requests() or {}})
  local log = call("state","diagnostics") or {}
  local clock = generation("so-data/clock")
  local runtime = SO.health or {}
  local modems = peripheral and peripheral.find and {peripheral.find("modem")} or {}
  local errors = SO.errors and SO.errors.status() or {}
  H.metrics = {
    "Uptime "..duration(now-(runtime.started or now)),
    "Tick "..tostring(runtime.cadence or "-").."ms / wall "..tostring(runtime.wallCadence or "-").."ms",
    "Tick cost "..tostring(runtime.tickMs or "-").."ms",
    log.available and ("Events #"..log.seq.." / "..log.segments.." seg") or "Events unavailable",
    "Event bytes "..tostring(log.bytes or "-"),
    log.snapshot and log.snapshot>0 and ("Snapshot #"..log.snapshot.." "..(log.snapshotAt and duration(now-log.snapshotAt) or "age unknown")) or "Snapshot none",
    "Disk "..math.floor((disk.ratio or 0)*100).."% / "..tostring(disk.free or "-").."B free",
    "Modems "..#modems,
    "Paired "..online.." online / "..lost.." lost",
    "Leases "..open.." open",
    "Clock reserve "..(clock and duration(clock.ceiling-now) or "unavailable"),
    "Errors "..tostring(errors.count or 0).." / "..tostring(errors.bytes or 0).."B",
  }
  if log.due then H.metrics[#H.metrics+1] = "Snapshot due" end
  if errors.error then H.metrics[#H.metrics+1] = "Error save: "..errors.error end
  local entries = SO.errors and SO.errors.entries() or {}
  if entries[#entries] then H.metrics[#H.metrics+1] = "Last: "..entries[#entries].text end
end

local function sessionView(session, role)
  session.visibility = session.visibility or {}
  session.visibility[role] = session.visibility[role] or {page=1,cursors={}}
  return session.visibility[role]
end

H.render = function(role,w,h,session)
  session = session or {}
  local v = sessionView(session,role)
  local c = U.canvas(w,h)
  if h < 5 then c.button(1,h,w,"BACK","generic","7",1);return c.frame() end
  local halves = U.grid(w,h,2)
  c.button(halves[1].x,1,halves[1].w,"HEALTH","health","7",1)
  c.button(halves[2].x,1,halves[2].w,"NEEDS "..#H.items,"attention","1",1)
  c.header(role:upper(),"")
  local capacity = math.max(0,h-5)
  local rows, page = {}, nil
  if role == "health" then
    for _, text in ipairs(H.metrics) do rows[#rows+1] = {text=text} end
  elseif role == "attention" then rows=H.items
  elseif role == "errors" then
    local entries = SO.errors and SO.errors.entries() or {}
    for i=#entries,1,-1 do rows[#rows+1] = {text=duration(H.now-entries[i].at).." "..entries[i].text,severity=1} end
  else
    local state = SO.mods.state
    if state and state.history then
      page = state.history.page({reverse=true,before=v.cursors[v.page],count=math.max(1,capacity),kind=v.kind,alerts=role=="alerts"})
      for _, e in ipairs(page.entries) do
        local data = e.data
        local text = type(data)=="table" and (data.text or data.reason) or type(data)=="string" and data or data==false and "cleared"
        rows[#rows+1] = {text=duration(H.now-(e.gameAt or H.now)).." "..e.kind..(text and " "..text or ""),severity=role=="alerts" and 1 or nil}
        H.kinds[e.kind] = true
      end
    end
    if role == "events" then c.button(1,3,w,"KIND "..(v.kind or "ALL"),"kind","7",1) end
    v.next = page and page.next
  end
  if not page then
    v.page = math.max(1,math.min(v.page,math.max(1,math.ceil(#rows/math.max(1,capacity)))))
    v.next = v.page*capacity < #rows and v.page+1 or nil
  end
  v.targets = {}
  if #rows == 0 then c.put(2,4,role=="attention" and "All clear" or "No entries") end
  local first = page and 1 or (v.page-1)*capacity+1
  for i=1,capacity do
    local row = rows[first+i-1]
    if row then
      local text = row.text:gsub("[%c]"," ")
      c.listRow(i+3,text,row.severity==1 and "e" or row.severity==2 and "1" or "b")
      if row.target then
        local id = "item:"..row.key
        c.hit(id,1,i+3,w,1)
        v.targets[id] = row
      end
    end
  end
  for i,col in ipairs(U.grid(w,h,3)) do
    c.button(col.x,h-1,col.w,({"PREV","BACK","NEXT"})[i],({"prev","generic","next"})[i],"7",1)
    c.button(col.x,h,col.w,({"EVENTS","ALERTS","ERRORS"})[i],({"events","alerts","errors"})[i],"7",1)
  end
  return c.frame()
end

H.input = function(role,event)
  if not event.session then return end
  local v = sessionView(event.session,role)
  local id = event.id
  if id == "next" and v.next then
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
  if not H.last or now-H.last>=5000 then H.gather(now);H.last=now end
  local display = SO.mods.display
  if display and not H.registered then
    for _, role in ipairs({"health","attention","alerts","events","errors"}) do
      display.screen(role,function(w,h,s) return H.render(role,w,h,s) end,function(e) return H.input(role,e) end)
    end
    H.registered=true
  end
end
return {name="health",handlers={},tick=H.tick,attention=attention,count=function() return #H.items end}
