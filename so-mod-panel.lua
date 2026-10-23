local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local P = { screens = {}, states = {}, facts = {}, alerts = {} }

P.now = function() return SO.now() end
P.time = function() return U and U.clock(os.epoch("utc")).hm or "" end

P.refresh = function()
  local display = SO.mods.display
  if not display or type(display.screen) ~= "function" then return end
  for _,role in ipairs({"mining", "lumber", "shop"}) do
    P.screens[role] = display.screen(role)
    local screen = P.screens[role]
    P.states[role] = "not loaded"
    if screen and type(screen.render) == "function" and type(screen.input) == "function" then
      P.states[role] = "stopped"
      if role ~= "shop" then P.probe(role, screen) end
    else P.facts[role] = {} end
  end
  P.fleet = nil
  local state = SO.mods.state
  local machines = state and type(state.get) == "function" and state.get("machines") or {}
  local count, lost = 0, 0
  for id, row in pairs(machines or {}) do
    if row.role == nil or row.role == "worker" or row.role == "turtle" then
      count = count + 1
      local lease = SO.mods.lease
      local status = lease and lease.status and lease.status(tonumber(id)) or {}
      if status.lost then lost = lost + 1 end
    end
  end
  if count > 0 then P.fleet = "TURTLES " .. (count-lost) .. " ok, " .. lost .. " lost" end
  P.alerts = {}
  local view = state and state.view
  local meta = type(view) == "table" and getmetatable(view)
  if type(view) == "function" or (meta and type(meta.__call) == "function") then
    for key,value in pairs(view().values or {}) do
      if type(key) == "string" and key:match("%.alert$") and value then
        P.alerts[#P.alerts+1] = {key=key,text=type(value)=="table" and tostring(value.text or value.reason or key) or tostring(value)}
      end
    end
    table.sort(P.alerts,function(a,b) return a.key < b.key end)
  end
end

-- Reads a job's state and facts from its own frame: the header's right side,
-- then the one-line "LABEL VALUE" rows on 3-8 with their state colour. Below
-- 19 rows both job screens draw those rows; 120 columns fit a long hold reason.
-- A frame without the expected rows (lumber SETUP is shared) keeps the last facts.
P.probe = function(role, screen)
  local ok, frame = pcall(screen.render, 120, 18, {})
  local rows = ok and type(frame) == "table" and type(frame.rows) == "table" and frame.rows or {}
  local header = rows[2] and tostring(rows[2].text or ""):match("^%s*(.-)%s*$") or ""
  local state = header:match("^" .. role:upper() .. "%s+(.+)$")
  if state then P.states[role] = state end
  local found = {}
  for y = 3, 8 do
    local row = rows[y]
    local label, value = tostring(row and row.text or ""):match("^%s*(.-)%s+(%S+)$")
    local run = row and type(row.runs) == "table" and row.runs[1]
    if label and run then found[label] = { value, run[3] } end
  end
  if found[P.jobFacts[role][1]] or not P.facts[role] then P.facts[role] = found end
end

P.block = function(c, role, x, y, w, height, compact)
  local loaded = P.states[role] ~= "not loaded"
  c.put(x+1,y,role:upper():sub(1,w-2))
  local offset = loaded and 10 or math.min(10,math.max(1,w-10))
  c.put(x+offset,y,P.states[role]:sub(1,math.max(0,w-offset)))
  local halves = U.grid(w, height, 2)
  if w == 26 then halves = {{x=1,w=12},{x=14,w=13}} end
  for i,cmd in ipairs({"start","stop"}) do
    local col = halves[i]
    if loaded then c.button(x+col.x-1,y+1,col.w,cmd:upper(),role..":"..cmd,i==1 and "9" or "e",compact and 1 or 3)
    else
      c.fill(x+col.x-1,y+1,col.w,compact and 1 or 3,"c")
      c.center(x+col.x-1,col.w,y+(compact and 1 or 2),cmd:upper())
    end
  end
end

P.shop = function(c, session, x, y, w, height, compact)
  local loaded = P.states.shop ~= "not loaded"
  c.put(x+1,y,"SHOP")
  c.put(x+(loaded and 10 or math.min(10,math.max(1,w-10))),y,loaded and "search:" or "not loaded")
  if loaded then c.search(x+1,y+1,w-2," " .. (session.panel.search or "") .. "_","search")
  else c.fill(x+1,y+1,w-2,1,"c") end
  local stacked = w < 26 and height >= 19 and not compact
  local cols = U.grid(w,height,3)
  for i,n in ipairs({1,16,64}) do
    local col = stacked and {x=1,w=w} or cols[i]
    local top = y + (compact and 2 or 3) + (stacked and (i-1)*4 or 0)
    if loaded then c.button(x+col.x-1,top,col.w,tostring(n),"order:"..n,"a",compact and 1 or 3)
    else
      c.fill(x+col.x-1,top,col.w,compact and 1 or 3,"c")
      c.center(x+col.x-1,col.w,top+(compact and 0 or 1),tostring(n))
    end
  end
end

-- The session's own invitation while it is still pending; clears it otherwise.
P.invitation = function(state)
  local invitation = state.invitation
  if invitation and (P.now() >= invitation.expires or SO.pair.pending() ~= invitation.code) then
    state.invitation, invitation = nil, nil
  end
  if state.pairBusy and not SO.pair.pending() then state.pairBusy = nil end
  return invitation
end
P.left = function(invitation)
  local left = math.max(0,math.ceil((invitation.expires-P.now())/1000))
  return string.format("%d:%02d left",math.floor(left/60),left%60)
end
P.paired = function(session)
  return session.id and SO.pair.key(session.id) and type(SO.pairCode) == "function"
end
P.requestCode = function(state, event, session)
  if event.from ~= session.id or not P.paired(session) then return end
  state.invitation = SO.pairCode(event.from)
  state.pairBusy = state.invitation == nil
end

P.render = function(w, h, session)
  if not U then return {rows={{text="panel needs so-ui.lua",fg="0",bg="f"}},buttons={}} end
  session = session or {}
  session.panel = session.panel or {search="",page="main"}
  local c = U.canvas(w,h)
  c.header("PANEL",P.time())
  local page = session.panel.page
  if page == "pair" then
    c.put(2,3,"PAIR NEW CLIENT")
    local invitation = P.invitation(session.panel)
    if session.panel.pairBusy then c.center(1,w,5,"CODE IN USE") end
    if invitation then
      c.fill(2,4,w-2,4,"9")
      c.big(2,4,w-2,invitation.code,"9")
      c.center(2,w-2,7,P.left(invitation),"9")
    end
    if P.paired(session) then
      c.button(1,h < 12 and h-1 or h-3,w,"NEW CODE","pair-code","9",h < 12 and 1 or 3)
    else
      c.put(2,5,"Press P on the server")
    end
    c.button(1,h,w,"BACK","panel-back","7",1)
  elseif page == "alerts" then
    c.put(2,3,"ALERTS")
    local capacity = math.max(1,h-5)
    local pages = math.max(1,math.ceil(#P.alerts/capacity))
    session.panel.alertPage = (session.panel.alertPage or 0) % pages
    if #P.alerts == 0 then c.put(2,5,"No alerts") end
    for i=1,capacity do
      local alert = P.alerts[session.panel.alertPage*capacity+i]
      if alert then c.listRow(4+i,alert.text,"e") end
    end
    local cols = U.grid(w,h,3)
    for i,label in ipairs({"<","BACK",">"}) do
      c.button(cols[i].x,h,cols[i].w,label,({"alert-prev","panel-back","alert-next"})[i],"7",1)
    end
  else
    local top = P.fleet and h >= 12 and 4 or 3
    if top == 4 then c.put(2,3,P.fleet:sub(1,w-2)) end
    -- Typed quick orders need a keyboard; monitor panels only run jobs.
    local shop = session.keyboard
    local cols = U.grid(w,h)
    if not shop and #cols > 2 then cols = U.grid(w,h,2) end
    if h < 19 and #cols == 1 then
      P.block(c,"mining",1,top,w,h,true)
      P.block(c,"lumber",1,top+2,w,h,true)
      if shop then P.shop(c,session,1,top+4,w,h,true) end
    elseif #cols >= 3 then
      P.block(c,"mining",cols[1].x,top,cols[1].w,h)
      P.block(c,"lumber",cols[2].x,top,cols[2].w,h)
      P.shop(c,session,cols[3].x,top,cols[3].w,h)
    elseif #cols == 2 then
      P.block(c,"mining",cols[1].x,top,cols[1].w,h)
      P.block(c,"lumber",cols[2].x,top,cols[2].w,h)
      if shop then P.shop(c,session,1,top+6,w,h) end
    else
      P.block(c,"mining",1,top,w,h)
      P.block(c,"lumber",1,top+5,w,h)
      if shop then P.shop(c,session,1,top+10,w,h) end
    end
    local labels, ids = {"ALERTS","PAIR"}, {"alerts","pair"}
    c.fill(1,h,w,1,"7")
    if w >= 26 then
      local x = 1
      for i,label in ipairs(labels) do
        c.put(x+1,h,label)
        c.hit(ids[i],x,h,i == #labels and w-x+1 or #label+2,1)
        x = x+#label+2
      end
    else
      for i,col in ipairs(U.grid(w,h,#labels)) do c.button(col.x,h,col.w,labels[i],ids[i],"7",1) end
    end
  end
  return c.frame()
end

P.input = function(event)
  local session = event.session
  if not session then return end
  session.panel = session.panel or {search="",page="main"}
  local panel,id = session.panel,event.id
  if type(event.text) == "string" and session.keyboard then panel.search = event.text:sub(1,256);return end
  if id == "panel-back" then panel.page="main"
  elseif id == "pair" or id == "alerts" then panel.page=id
  elseif id == "pair-code" and panel.page == "pair" then P.requestCode(panel, event, session)
  elseif id == "alert-next" then panel.alertPage=(panel.alertPage or 0)+1
  elseif id == "alert-prev" then panel.alertPage=(panel.alertPage or 0)-1
  elseif panel.page == "main" then
    P.refresh()
    local role,cmd = (id or ""):match("^(%a+):(%a+)$")
    if (role == "mining" or role == "lumber") and (cmd == "start" or cmd == "stop") then
      local target = P.screens[role]
      if target and type(target.input) == "function" then target.input({id=cmd,role=role}) end
    else
      local amount = (id or ""):match("^order:(%d+)$")
      local shop = SO.mods.shop
      if (amount == "1" or amount == "16" or amount == "64") and P.screens.shop and session.keyboard
          and shop and type(shop.order) == "function" then
        shop.order(panel.search, tonumber(amount))
      end
    end
    P.refresh()
  end
end

-- The pocket role (26x20) in route A; docs/ui/schematic/pocket.py is its twin. A tab row and four
-- pages. ALERTS is a page under FLEET, opened from its alert rows. Every control is one row tall.
P.tabs = {"FLEET","JOBS","SHOP","PAIR"}
P.jobFacts = {mining={"BUSY","DEPTH","BRANCHES","MIN FUEL"},lumber={"TREES READY","SAPLINGS","NEXT GROW","FUEL"}}
P.codeLife = 300000

-- The status model (docs/server-only/PROTOCOL.md#display) with every list present.
P.model = function()
  local display = SO.mods.display
  local model = display and type(display.statusModel) == "function" and display.statusModel()
  local m = {}
  for k,v in pairs(type(model) == "table" and model or {}) do m[k] = v end
  m.turtles,m.drops,m.events,m.flags = m.turtles or {},m.drops or {},m.events or {},m.flags or {}
  m.displays,m.leases,m.time = m.displays or {},m.leases or 0,m.time or ""
  m.server = m.server or {id="?",up="-"}
  return m
end

-- Four tabs from column 1, the active one on the panel colour; a coral dot inside FLEET while anything needs a look.
P.tabBar = function(c, page, dot)
  local x = 1
  for _,t in ipairs(P.tabs) do
    local label,on = " "..t.." ",t:lower() == page
    c.put(x,1,label,on and "0" or "8",on and "7" or "f")
    c.hit("tab:"..t:lower(),x,1,#label,1,t)
    x = x+#label
  end
  if dot then c.put(7,1,U.g.bullet,"e") end
end

-- Status's one-column layout under the tab row; the alert rows open ALERTS.
P.fleetPage = function(c, m, w, h)
  local q = {}
  for k,v in pairs(m) do q[k] = v end
  q.alerts = {}
  U.st.column(c,q)
  c.put(1,1,string.rep(" ",w),"0","f")
  P.tabBar(c,"fleet",#m.flags > 0)
  for y = 3,2+math.min(#m.flags,h >= 17 and 2 or 1) do c.hit("alerts",2,y,w-2,1) end
end

P.wrap = function(text, width)
  local lines, line = {}, ""
  width = math.max(1, width)
  for word in text:gmatch("%S+") do
    while #word > width do
      if line ~= "" then lines[#lines+1],line = line,"" end
      lines[#lines+1],word = word:sub(1,width),word:sub(width+1)
    end
    if line == "" then line = word
    elseif #line+1+#word <= width then line = line.." "..word
    else lines[#lines+1],line = line,word end
  end
  if line ~= "" then lines[#lines+1] = line end
  return lines
end

-- Every flag (lost turtles, alerts, broken drops): two rows of text, two of detail, then a blank row.
P.alertPages = function(flags, w, h)
  local pages, page, used = {}, nil, 0
  for _,f in ipairs(flags) do
    local rows = {}
    for _,part in ipairs({{f.text,"0"},{f.detail,"8"}}) do
      local lines = P.wrap(tostring(part[1] or ""),w-4)
      for i = 1,math.min(2,#lines) do rows[#rows+1] = {lines[i],part[2]} end
    end
    if not page or used+#rows > h-5 then page,used = {},0;pages[#pages+1] = page end
    page[#page+1],used = rows,used+#rows+1
  end
  return pages
end

P.alertPage = function(c, state, m, w, h)
  c.section(2,3,w-2,"ALERTS",#m.flags,#m.flags > 0 and "e" or "8")
  local pages = P.alertPages(m.flags,w,h)
  state.alertPage = (state.alertPage or 0) % math.max(1,#pages)
  local y = 4
  for _,rows in ipairs(pages[state.alertPage+1] or {}) do
    c.put(2,y,"!","e")
    for _,row in ipairs(rows) do c.put(4,y,row[1],row[2]);y = y+1 end
    y = y+1
  end
  if #pages > 1 then
    c.chip(2,h,U.g.left,"alert-prev")
    local n = (state.alertPage+1).."/"..#pages
    c.put(math.floor((w-#n)/2)+1,h,n,"8")
    c.chip(w-3,h,U.g.right,"alert-next")
  end
end

-- A job's facts: the module's facts() when it has one, else the status model, else the probed state.
P.jobData = function(role, m)
  local mod = SO.mods[role == "mining" and "mine" or "lumber"]
  if mod and type(mod.facts) == "function" then
    local ok,f = pcall(mod.facts)
    if ok and type(f) == "table" then return f end
  end
  if role == "mining" and m.mining then
    local mi,low = m.mining,nil
    for _,t in ipairs(m.turtles) do
      if t.where ~= "farm" and t.where ~= "-" and t.fuel and (not low or t.fuel < low.fuel) then low = t end
    end
    return {state=mi.state,done=mi.done,total=mi.total,busy=mi.busy,workers=mi.workers,
      lane=mi.lane and {id=mi.lane.id,facing=mi.lane.facing},fuel=low and {value=low.fuel,id=low.id}}
  elseif role == "lumber" and m.lumber then
    local lu,farm = m.lumber,nil
    for _,t in ipairs(m.turtles) do if t.where == "farm" then farm = t;break end end
    return {state=lu.state,ready=lu.ready,spots=lu.spots,grow=lu.grow,fuel=farm and farm.fuel}
  end
  return {state=P.states[role] or "-"}
end

-- A long hold reason reads as its first word; ALERTS has the rest.
P.word = function(state, room)
  if #state <= room then return state end
  return (state:match("^[^ :;,]*") or state):sub(1,room)
end

-- START and STOP; the one that does nothing now is muted. Missing jobs get grey chips without targets.
P.jobChips = function(c, y, w, role, running, loaded)
  local half = math.floor((w-4)/2)
  for i,cmd in ipairs({"start","stop"}) do
    local x,label = i == 1 and 2 or w-half,cmd:upper()
    if loaded then
      local kind = i == 1 and (running and "muted" or "primary") or (running and "stop" or "muted")
      c.chip(x,y,label,role..":"..cmd,kind,half)
    else
      c.put(x,y,string.rep(" ",half),"8","7")
      c.put(x+math.floor((half-#label)/2),y,label,"8","7")
    end
  end
end

P.job = function(c, y, w, role, f)
  local title,loaded,lw = role:upper(),f ~= nil,w-2
  local state = loaded and tostring(f.state or "-") or "not loaded"
  local word = P.word(state,w-2-#title-3)
  c.section(2,y,lw,title,word,loaded and U.tone(word) or "8")
  if loaded and role == "mining" then
    c.progress(2,y+1,10,f.done or 0,f.total or 0)
    c.leader(2,y+2,lw,"busy",f.busy and f.workers and (f.busy.."/"..f.workers) or "-",f.busy and f.workers and "0" or "8")
    local lane,fuel = f.lane,f.fuel
    c.leader(2,y+3,lw,"lane",lane and (U.arrow(lane.facing)..lane.id) or "-",lane and "b" or "8")
    c.leader(2,y+4,lw,"min fuel",fuel and (fuel.value.." #"..fuel.id) or "-",fuel and (fuel.value < 500 and "1" or "0") or "8")
  elseif loaded then
    local spots = f.spots or 0
    c.progress(2,y+1,spots > 0 and math.min(12,spots) or 12,f.ready or 0,spots,"d",U.g.spade,"8",U.g.club)
    for i,row in ipairs({{"next grow","grow"},{"saplings","saplings"},{"fuel","fuel"}}) do
      local v = f[row[2]]
      c.leader(2,y+1+i,lw,row[1],v == nil and "-" or tostring(v),v == nil and "8" or "0")
    end
  end
  P.jobChips(c,y+6,w,role,loaded and state ~= "stopped",loaded)
end

-- The item the order chips act on: the tapped one while it still matches, else the best match.
P.shown = function(state, items)
  for _,item in ipairs(items) do if item.name == state.selected then return item end end
  return items[1]
end

-- Search, then the matches with the shown item's 1, 16 and 64 chips under it; the last order on row h-1.
P.shopPage = function(c, state, keyboard, w, h)
  local shop = SO.mods.shop
  if not P.screens.shop or not shop or type(shop.matches) ~= "function" or type(shop.order) ~= "function" then
    c.put(2,3,"shop not loaded","8");return
  end
  local search,y = state.search or "",3
  if keyboard then
    local typed = search:sub(-(w-8))
    c.put(2,3,">","8");c.put(4,3,typed,"0");c.put(4+#typed,3,"_","9")
    if search ~= "" then c.chip(w-3,3,U.g.cross,"clear","off") end
    c.rule(2,4,w-1)
    y = 5
  end
  local items = shop.matches(search,h)
  local shown = P.shown(state,items)
  if #items == 0 then c.put(2,y,search == "" and "no stock" or "no match","8") end
  for _,item in ipairs(items) do
    if y > h-2-(item == shown and 2 or 0) then break end
    if item == shown then c.put(1,y,string.rep(" ",w),"0","7") end
    local n = tonumber(item.count) or 0
    c.leader(2,y,w-2,item.label,tostring(item.count),n == 0 and "8" or n < 10 and "1" or "0","0")
    c.hit("pick:"..item.name,2,y,w-2,1)
    y = y+1
    if item == shown then
      local cw = math.floor((w-4)/3)
      for i,amount in ipairs({1,16,64}) do
        c.chip(2+(i-1)*(cw+1),y,tostring(amount),"order:"..amount..":"..item.name,"plain",cw)
      end
      y = y+2
    end
  end
  if state.sent then c.put(2,h-1,state.sent[1]:sub(1,w-2),state.sent[2]) end
end

-- The code in six line digits, a teal tick row counting its five minutes down, then NEW CODE.
P.pairPage = function(c, session, state, w, h)
  local invitation = P.invitation(state)
  local code = invitation and tostring(invitation.code) or "------"
  c.digits(math.floor((w-(#code*4-1))/2)+1,5,code,invitation and "0" or "8",3,7,1)
  if invitation then
    local left = math.max(0,invitation.expires-P.now())
    local secs = math.ceil(left/1000)
    c.ticks(2,14,18,U.filled(18,left,P.codeLife),"9")
    c.put(21,14,string.format("%d:%02d",math.floor(secs/60),secs%60),"0")
  elseif state.pairBusy then c.put(2,14,"code in use","1") end
  if P.paired(session) then c.chip(2,h-2,"NEW CODE","pair-code","plain",w-2) end
end

P.pocketState = function(session)
  session.pocket = type(session.pocket) == "table" and session.pocket or {page="fleet",search=""}
  return session.pocket
end

P.pocket = function(w, h, session)
  session = session or {}
  local state,m,c = P.pocketState(session),P.model(),U.canvas(w,h)
  local page = state.page
  if page == "fleet" or not page then P.fleetPage(c,m,w,h);return c.frame() end
  P.tabBar(c,page == "alerts" and "fleet" or page,#m.flags > 0)
  if page == "alerts" then P.alertPage(c,state,m,w,h)
  elseif page == "jobs" then
    for i,role in ipairs({"mining","lumber"}) do
      local screen = P.screens[role]
      local loaded = screen and type(screen.render) == "function" and type(screen.input) == "function"
      P.job(c,i == 1 and 3 or 12,w,role,loaded and P.jobData(role,m) or nil)
    end
  elseif page == "shop" then P.shopPage(c,state,session.keyboard,w,h)
  elseif page == "pair" then P.pairPage(c,session,state,w,h) end
  return c.frame()
end

-- One tap is one action, and only on the page that drew it.
P.pocketInput = function(event)
  local session = event.session
  if not session then return end
  local state, id = P.pocketState(session), event.id
  if type(event.text) == "string" then
    if session.keyboard then state.search,state.selected,state.sent = event.text:sub(1,64),nil,nil end
    return
  end
  local tab = (id or ""):match("^tab:(%a+)$")
  if tab == "fleet" or tab == "jobs" or tab == "shop" or tab == "pair" then state.page = tab
  elseif id == "alerts" and state.page == "fleet" then state.page,state.alertPage = "alerts",0
  elseif state.page == "alerts" and (id == "alert-next" or id == "alert-prev") then
    state.alertPage = (state.alertPage or 0)+(id == "alert-next" and 1 or -1)
  elseif state.page == "pair" and id == "pair-code" then P.requestCode(state,event,session)
  elseif state.page == "jobs" then
    local role,cmd = (id or ""):match("^(%a+):(%a+)$")
    local target = P.screens[role or ""]
    if (role == "mining" or role == "lumber") and (cmd == "start" or cmd == "stop")
        and target and type(target.input) == "function" then
      target.input({id=cmd,role=role})
      P.refresh()
    end
  elseif state.page == "shop" then
    local shop, name = SO.mods.shop, (id or ""):match("^pick:(.+)$")
    local amount, item = (id or ""):match("^order:(%d+):(.+)$")
    if name then state.selected,state.sent = name,nil
    elseif id == "clear" then state.search,state.selected,state.sent = "",nil,nil
    elseif (amount == "1" or amount == "16" or amount == "64") and P.screens.shop and shop
        and type(shop.order) == "function" and type(shop.matches) == "function" then
      -- The chip names its item; it must still match the search.
      for _,match in ipairs(shop.matches(state.search or "",256)) do
        if match.name == item then
          local sent = shop.order(item,tonumber(amount))
          state.sent = sent and {amount.." "..match.label.." sent","d"} or {"not sent","e"}
          break
        end
      end
    end
  end
end

P.tick = function()
  local display = SO.mods.display
  if display and type(display.screen)=="function" then
    if not P.registered then
      display.screen("panel",P.render,P.input)
      if U then display.screen("pocket",P.pocket,P.pocketInput) end
      P.registered=true
    end
    P.refresh()
  end
end

return {name="panel",handlers={},tick=P.tick}
