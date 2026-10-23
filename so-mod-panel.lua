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
    P.states[role], P.facts[role] = "not loaded", {}
    if screen and type(screen.render) == "function" and type(screen.input) == "function" then
      P.states[role] = "stopped"
      if role ~= "shop" then P.probe(role, screen) end
    end
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
P.probe = function(role, screen)
  local ok, frame = pcall(screen.render, 120, 18, {})
  local rows = ok and type(frame) == "table" and type(frame.rows) == "table" and frame.rows or {}
  local header = rows[2] and tostring(rows[2].text or ""):match("^%s*(.-)%s*$") or ""
  local state = header:match("^" .. role:upper() .. "%s+(.+)$")
  if state then P.states[role] = state end
  for y = 3, 8 do
    local row = rows[y]
    local label, value = tostring(row and row.text or ""):match("^%s*(.-)%s+(%S+)$")
    local run = row and type(row.runs) == "table" and row.runs[1]
    if label and run then P.facts[role][label] = { value, run[3] } end
  end
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

-- The pocket role (26x20): a one-row tab bar and four pages. ALERTS is a page
-- under FLEET, opened from its ALERTS row. Every control is one row tall.
P.tabs = {{"tab:fleet","FLEET"},{"tab:jobs","JOBS"},{"tab:shop","SHOP"},{"tab:pair","PAIR"}}
P.jobFacts = {mining={"BUSY","DEPTH","BRANCHES","MIN FUEL"},lumber={"TREES READY","SAPLINGS","NEXT GROW","FUEL"}}

P.model = function()
  local display = SO.mods.display
  local model = display and type(display.statusModel) == "function" and display.statusModel()
  return type(model) == "table" and model or {tiles={},alerts={}}
end

P.tabBar = function(c, page, alerts)
  c.fill(1,1,c.w,1,"7")
  local x = 1
  for _,tab in ipairs(P.tabs) do
    local active = tab[1] == "tab:"..page or page == "alerts" and tab[1] == "tab:fleet"
    c.put(x,1," "..tab[2].." ",nil,active and "9" or tab[1] == "tab:fleet" and alerts > 0 and "e" or "7")
    c.hit(tab[1],x,1,#tab[2]+2,1)
    x = x+#tab[2]+2
  end
end

P.wrap = function(text, width)
  local lines, line = {}, ""
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

-- Newest alert first, three lines at most each, a blank row between alerts.
P.alertPage = function(c, state, alerts, w, h)
  U.chipRow(c,3,"ALERTS",{{#alerts,#alerts > 0 and "e" or "d"}})
  local pages, page, used = {}, nil, 0
  local room = h-6
  for i = #alerts,1,-1 do
    local lines = P.wrap(tostring(alerts[i].text or ""),w-4)
    lines = {lines[1] or "",lines[2],lines[3]}
    if not page or used+#lines > room then page,used = {},0;pages[#pages+1] = page end
    page[#page+1],used = lines,used+#lines+1
  end
  state.alertPage = (state.alertPage or 0) % math.max(1,#pages)
  local y = 5
  for _,lines in ipairs(pages[state.alertPage+1] or {}) do
    for _,line in ipairs(lines) do c.fill(2,y,1,1,"e");c.put(4,y,line);y = y+1 end
    y = y+1
  end
  if #pages > 1 then
    c.button(2,h,5,"<","alert-prev","7",1)
    c.center(7,w-12,h,(state.alertPage+1).."/"..#pages)
    c.button(w-5,h,5,">","alert-next","7",1)
  end
end

P.stateColour = function(state)
  return state == "running" and "d" or (state == "stopped" or state == "not loaded") and "c" or "1"
end

-- Title bar with the state chip, up to `n` fact rows, a gap, then START and STOP.
P.jobBlock = function(c, role, y, n, w)
  local state, loaded = P.states[role] or "not loaded", P.states[role] ~= "not loaded"
  c.fill(2,y,w-2,1,"7")
  -- A hold reads "hold"; the alert list has the reason.
  local word = loaded and state:match("^[^%s:;,]+") or state
  U.chipRow(c,y,role:upper(),{{word:sub(1,w-15),P.stateColour(state)}},3,w-1)
  for i = 1,n do
    local label = P.jobFacts[role][i]
    local fact = (P.facts[role] or {})[label]
    if fact then U.chipRow(c,y+i,label,{fact},3,w-1) end
  end
  local half = math.floor((w-4)/2)
  for i,cmd in ipairs({"start","stop"}) do
    local x = i == 1 and 2 or w-half
    if loaded then c.button(x,y+n+2,half,cmd:upper(),role..":"..cmd,i == 1 and "9" or "e",1)
    else c.fill(x,y+n+2,half,1,"c");c.center(x,half,y+n+2,cmd:upper()) end
  end
end

-- The item the order chips act on: the tapped one while it still matches, else the best match.
P.shown = function(state, items)
  for _,item in ipairs(items) do if item.name == state.selected then return item end end
  return items[1]
end

-- Search, then the matches with the shown item's 1, 16 and 64 chips under it.
P.shopPage = function(c, state, keyboard, w, h)
  local shop = SO.mods.shop
  if not P.screens.shop or not shop or type(shop.matches) ~= "function" or type(shop.order) ~= "function" then
    c.fill(2,3,w-2,1,"c");c.put(3,3,"shop not loaded");return
  end
  local search = state.search or ""
  if keyboard then
    local width = search == "" and w-2 or w-5
    c.search(2,3,width," "..search:sub(-(width-2)).."_","search")
    if search ~= "" then c.button(w-3,3,3,"x","clear","7",1) end
  end
  local items, y = shop.matches(search,h), keyboard and 5 or 3
  local shown = P.shown(state,items)
  if #items == 0 then c.put(2,y,search == "" and "no stock" or "no match") end
  for _,item in ipairs(items) do
    if y > h-2 - (item == shown and 2 or 0) then break end
    local bg = item.count == 0 and "e" or item.count <= 16 and "1" or "b"
    if item == shown then c.fill(2,y,w-2,1,"7") end
    U.chipRow(c,y,item.label,{{item.count,bg}})
    c.hit("pick:"..item.name,2,y,w-2,1)
    y = y+1
    if item == shown then
      for i,col in ipairs(U.grid(w-2,1,3)) do
        local n = ({1,16,64})[i]
        c.button(col.x+1,y,col.w,tostring(n),"order:"..n,"a",1)
      end
      y = y+2
    end
  end
  if state.sent then c.put(2,h-1,state.sent:sub(1,w-2)) end
end

-- Code block on rows 3-7: big digits on teal while pending, dashes on grey otherwise.
P.pairPage = function(c, session, state, w)
  local invitation, paired = P.invitation(state), P.paired(session)
  local bg = invitation and "9" or "c"
  c.fill(2,3,w-2,5,bg)
  c.big(2,4,w-2,invitation and invitation.code or "------",bg)
  local line = invitation and P.left(invitation) or state.pairBusy and "CODE IN USE"
    or not paired and "press P on the server" or ""
  c.center(2,w-2,7,line,bg)
  if paired then c.button(2,9,w-2,"NEW CODE","pair-code","9",1) end
end

P.pocketState = function(session)
  session.pocket = type(session.pocket) == "table" and session.pocket or {page="fleet",search=""}
  return session.pocket
end

P.pocket = function(w, h, session)
  session = session or {}
  local state, model, c = P.pocketState(session), P.model(), U.canvas(w,h)
  local alerts = model.alerts or {}
  P.tabBar(c,state.page,#alerts)
  if state.page == "alerts" then P.alertPage(c,state,alerts,w,h)
  elseif state.page == "jobs" then
    local n = math.max(0,math.min(4,math.floor((h-10)/2)))
    P.jobBlock(c,"mining",3,n,w)
    P.jobBlock(c,"lumber",n+8,n,w)
  elseif state.page == "shop" then P.shopPage(c,state,session.keyboard,w,h)
  elseif state.page == "pair" then P.pairPage(c,session,state,w)
  else U.fleetRows(c,model,3,h >= 17 and 2 or 1) end
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
    local shop, amount, name = SO.mods.shop, (id or ""):match("^order:(%d+)$"), (id or ""):match("^pick:(.+)$")
    if name then state.selected,state.sent = name,nil
    elseif id == "clear" then state.search,state.selected,state.sent = "",nil,nil
    elseif (amount == "1" or amount == "16" or amount == "64") and P.screens.shop and shop
        and type(shop.order) == "function" and type(shop.matches) == "function" then
      local item = P.shown(state,shop.matches(state.search or "",256))
      local sent = item and shop.order(item.name,tonumber(amount))
      if item then state.sent = sent and ("sent "..amount.." "..item.label) or "not sent: no storage" end
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
