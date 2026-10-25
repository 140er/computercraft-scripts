local U
if not fs or not fs.exists or fs.exists("so-ui.lua") then U = dofile("so-ui.lua") end
local P = { screens = {}, states = {}, alerts = {}, confirmSeq = 0 }

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
    end
  end
  P.fleet = nil
  local state = SO.mods.state
  local machines = state and type(state.get) == "function" and state.get("machines") or {}
  local count, lost, lostIds = 0, 0, {}
  for id, row in pairs(machines or {}) do
    if row.role == nil or row.role == "worker" or row.role == "turtle" then
      count = count + 1
      local lease = SO.mods.lease
      local status = lease and lease.status and lease.status(tonumber(id)) or {}
      if status.lost then lost, lostIds[#lostIds+1] = lost + 1, tonumber(id) or id end
    end
  end
  if count > 0 then P.fleet, P.lost = (count-lost) .. " ok \183 " .. lost .. " lost", lost end
  P.reasons = {}
  for role,key in pairs({mining="mine.alert",lumber="lumber.alert"}) do
    local reason=state and state.get and state.get(key)
    if type(reason)=="table" then P.reasons[role]=reason.text end
  end
  local paired=state and state.get and state.get("pair.done")
  P.pairedNote=nil
  if type(paired)=="table" and type(paired.at)=="number" and P.now()-paired.at < 30000 then
    local machine=machines[tostring(paired.id)] or {}
    P.pairedNote="Paired "..(machine.role or "client").." #"..paired.id..(machine.label and (" "..machine.label) or "")
  end
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
  -- One row per lost turtle, lowest id first, above the standing alerts.
  table.sort(lostIds,function(a,b)
    if type(a) == "number" and type(b) == "number" then return a < b end
    return tostring(a) < tostring(b)
  end)
  for i,id in ipairs(lostIds) do table.insert(P.alerts,i,{key="lost:"..id,text="#"..id.." lost"}) end
end

-- Reads a job's state from the right side of its own frame's header; 120 columns fit a long hold reason.
P.probe = function(role, screen)
  local ok, frame = pcall(screen.render, 120, 18, {})
  local rows = ok and type(frame) == "table" and type(frame.rows) == "table" and frame.rows or {}
  local header = rows[2] and tostring(rows[2].text or ""):match("^%s*(.-)%s*$") or ""
  local state = header:match("^" .. role:upper() .. "%s+(.+)$")
  if state then P.states[role] = state end
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
P.paired = function(session)
  return session.id and SO.pair.key(session.id) and type(SO.pairCode) == "function"
end
P.requestCode = function(state, event, session)
  if event.from ~= session.id or not P.paired(session) then return end
  state.invitation = SO.pairCode(event.from)
  state.pairBusy = state.invitation == nil
end

P.drawn = function(event)
  local panel = event.session.panel
  local b = panel.drawn and panel.drawn[event.id]
  return b and b.page == panel.page and type(event.x) == "number" and type(event.y) == "number"
    and event.x >= b.x and event.x < b.x+b.w and event.y >= b.y and event.y < b.y+(b.h or 1)
end

-- The panel role in route A; docs/ui/schematic/panel.py is its twin. Row 1 is the PANEL header (the
-- pocket's tabs when a pocket opens PAIRED or ENROLL), pages have a section on row 3 and their
-- actions on the last row. Every control is a one-row chip.
P.header = function(c, w, h, main)
  c.put(2,1,"PANEL","0")
  local x,right = 9,main and P.time() or ""
  if main and SO.mods.health and w >= 26 and h >= 12 then
    x = c.chip(x,1,"HEALTH","health")+1
    local n = tostring(SO.mods.health.count())
    c.chip(x,1,"NEEDS "..n,"attention")
    if n ~= "0" then c.put(x+7,1,n,"1","7") end
    x = x+#n+9
  end
  if x+#right+2 > w then right = "" end
  if right ~= "" then c.put(w-#right,1,right,"8") end
  c.rule(x,1,w-#right-2)
end

-- Chips from column 2 at their own width, or shared equally when they do not fit.
P.nav = function(c, y, items)
  local need = -1
  for _,item in ipairs(items) do need = need+#item[1]+3 end
  if need > c.w-2 then U.actions(c,y,items);return end
  local x = 2
  for _,item in ipairs(items) do x = c.chip(x,y,item[1],item[2],item[3])+1 end
end
P.back = function(c, y, id) c.chip(c.w-6,y,"BACK",id) end
-- A list row's own action as bracketed text ending at column right (w-1), so stacked rows never form a slab.
P.act = function(c, y, label, id, fg, right)
  local x = (right or c.w-1)-#label-1
  c.put(x,y,"[","8");c.put(x+1,y,label,fg);c.put(x+#label+1,y,"]","8")
  c.hit(id,x,y,#label+2,1,label)
end
-- Paging chips stay drawn on a single page (muted), as the old PREV and NEXT were. Left of BACK
-- there is room up to column w-8; narrower, the arrows are one cell each and the page count goes.
P.pager = function(c, y, page, pages, prev, nxt)
  local n,kind = (page+1).."/"..pages,pages > 1 and "plain" or "muted"
  if 9+#n > c.w-8 then c.chip(2,y,U.g.left,prev,kind,1);c.chip(4,y,U.g.right,nxt,kind,1);return end
  local x = c.chip(2,y,U.g.left,prev,kind)+1
  c.put(x,y,n,"8")
  c.chip(x+#n+1,y,U.g.right,nxt,kind)
end

-- What the main page shows of a job: its facts, with the probed state unless the module reported it.
P.liveJob = function(role)
  if P.states[role] == "not loaded" then return nil end
  local f,own = P.jobData(role,P.model())
  if not own then f.state = P.states[role] or f.state end
  return f
end

-- The shop's best match for a search with its label and stock, or nil.
P.item = function(shop, search)
  if not shop or type(shop.best) ~= "function" or type(shop.matches) ~= "function" then return nil end
  local name,count = shop.best(search)
  if not name then return nil end
  for _,item in ipairs(shop.matches(name,256)) do if item.name == name then return item end end
  return {name=name,count=count,label=name:upper()}
end

-- Labels that more than one stocked id shares, each with how many of its ids are minecraft's.
P.shared = function(shop)
  local seen,shared = {},{}
  for _,item in ipairs(type(shop.matches) == "function" and shop.matches("",4096) or {}) do
    local mc = item.name:match("^minecraft:") and 1 or 0
    if seen[item.label] then shared[item.label] = (shared[item.label] or seen[item.label])+mc end
    seen[item.label] = (seen[item.label] or 0)+mc
  end
  return shared
end

-- The item with its namespace before a shared label ("CREATE:COPPER INGOT"); the one minecraft id
-- under a shared label and every other item stay as they are.
P.tag = function(item, shared)
  local ns = item and shared[item.label] and item.name:match("^([^:]+):")
  if not ns or ns == "minecraft" and shared[item.label] == 1 then return item end
  local copy = {}
  for k,v in pairs(item) do copy[k] = v end
  copy.label = ns:upper()..":"..item.label
  return copy
end

-- One quick order through shop.order. The record keeps what was sent; shop writes its status and reply into view.
P.order = function(shop, search, amount, label)
  local view = {}
  local name,n = shop.order(search,amount,view)
  if not name then return {why=n} end
  return {n=n or amount,label=label,view=view,name=name}
end

-- A typed search may end in a quantity ("sand 37"): the search, then the count or nil.
P.split = function(text)
  local search,n = tostring(text or ""):match("^(.-)%s+(%d+)$")
  if search and search ~= "" then return search,tonumber(n) end
  return tostring(text or ""),nil
end

-- The shop's storage room state; a shop without status() counts as found and fresh.
P.room = function(shop)
  if shop and type(shop.status) == "function" then return shop.status() end
  return {found=true,stale=false}
end

-- An order record as a line of at most width cells and its colour, then the shop's reply (or why it
-- was not sent). The count and status always show; a long label is cut and ends in "...".
P.orderLine = function(sent, width)
  if not sent.view then return "not sent","e",sent.why end
  local status = tostring(sent.view.order or ""):match("^Order: (%a+)") or "sent"
  local head,tail,label = sent.n.." "," "..status,sent.label
  local room = width-#head-#tail
  if #label > room then label = room > 3 and label:sub(1,room-3):gsub("%s+$","").."..." or "" end
  return head..label..tail,status == "failed" and "e" or "d",sent.view.orderDetail
end

-- The quick order (keyboards only): the typed search, its best match with the stock, 1, 16 and 64,
-- then the last order and the shop's reply.
P.shopBlock = function(c, session, x, y, cw)
  local loaded,panel = P.states.shop ~= "not loaded",session.panel
  c.section(x,y,cw,"SHOP",loaded and "" or "not loaded")
  if loaded then
    local typed = (panel.search or ""):sub(-(cw-3))
    c.put(x,y+1,">","8");c.put(x+2,y+1,typed,"0");c.put(x+2+#typed,y+1,"_","9")
    c.hit("search",x,y+1,cw,1)
  end
  local search,qty = P.split(panel.search)
  local item = loaded and P.tag(P.item(SO.mods.shop,search),P.shared(SO.mods.shop))
  -- Without a storage room the chips are muted.
  local live = loaded and P.room(SO.mods.shop).found
  if loaded and not live then c.put(x,y+2,("storage room not found"):sub(1,cw),"e")
  elseif item then
    local n = tonumber(item.count) or 0
    c.leader(x,y+2,cw,item.label,tostring(item.count),n < 10 and "1" or "0")
  elseif loaded and search ~= "" then c.put(x,y+2,"no match","8") end
  local third = math.floor((cw-2)/3)
  if qty then
    local label = "ORDER "..qty
    if live then c.chip(x,y+3,label,"order:"..qty,"plain",cw) else P.dead(c,x,y+3,label,cw) end
  end
  for i,n in ipairs(qty and {} or {1,16,64}) do
    local cx = x+(i-1)*(third+1)
    if live then c.chip(cx,y+3,tostring(n),"order:"..n,"plain",third) else P.dead(c,cx,y+3,tostring(n),third) end
  end
  if loaded and panel.sent then
    local text,fg,detail = P.orderLine(panel.sent,cw)
    c.put(x,y+4,text:sub(1,cw),fg)
    -- The last order sends again with the same count, through shop.order and its one-stack cap.
    if live and panel.sent.name then c.hit("order:"..panel.sent.n..":"..panel.sent.name,x,y+4,cw,1) end
    if detail then c.put(x,y+5,detail:sub(1,cw),"8") end
  end
end

-- A waiting order's age: seconds, then minutes.
P.ago = function(ms)
  local s = math.floor(math.max(0,ms)/1000)
  return s < 60 and s.."s" or math.floor(s/60).."m"
end

-- The shared fuel policy from shop.fuelConfig() as a value and its colour (read-only; MINING setup
-- changes it), or nil while fuel auto has never been set up or the shop fails. A value wider than room
-- reads "alert".
P.fuel = function(shop, room)
  local ok,policy = pcall(function() return shop and type(shop.fuelConfig) == "function" and shop.fuelConfig() end)
  if not ok or type(policy) ~= "table" or not (policy.auto or policy.output or policy.waiting or policy.alert) then return nil end
  local waiting,alert = policy.waiting,policy.auto and type(policy.alert) == "table" and tostring(policy.alert.reason or "")
  if type(waiting) == "table" and type(waiting.at) == "number" then
    local age = P.now()-waiting.at
    if age >= 120000 then return "timed out","e" end
    return "waiting "..P.ago(age),"1"
  end
  if alert == "fuel order timed out" then return "timed out","e" end
  if alert and alert ~= "" then return #alert <= room and alert or "alert","e" end
  if policy.auto then return "on","0" end
  return "off","8"
end
P.fuelRow = function(c, y, lw, value, fg) c.leader(2,y,lw,"fuel auto",value,fg) end

-- Job blocks in as many columns of 16 cells or more as fit (at most 36 wide), split by a dim rule.
-- When rows run out the lowest row of blocks gives up its spare row, then its facts.
P.main = function(c, session, w, h)
  local blocks,top = {"mining","lumber",session.keyboard and "shop" or nil},3
  local lw = math.min(w-2,36)
  local fuel,fuelFg = P.fuel(P.states.shop ~= "not loaded" and SO.mods.shop,lw-11)
  if h < 12 then fuel = nil end
  if (P.pairedNote or P.fleet) and h >= 12 then
    if P.pairedNote then
      c.put(2,3,U.g.bullet,"d");c.put(4,3,P.wrap(P.pairedNote,w-4)[1] or "","0")
    else
      c.leader(2,3,lw,"turtles",P.fleet)
      -- "N lost" opens the panel's own ALERTS, where each lost turtle has its own row, even with health loaded.
      if P.lost > 0 then
        local text = P.lost.." lost"
        c.put(2+lw-#text,3,text,"e")
        c.hit("lost",2+lw-#text,3,#text,1)
      end
    end
    top = 4
  end
  if fuel then P.fuelRow(c,top,lw,fuel,fuelFg);top = top+1 end
  if top > 3 then top = top+1 end
  local n = #blocks
  local cw = math.floor((w-2-(n-1)*3)/n)
  while n > 1 and cw < 16 do n = n-1;cw = math.floor((w-2-(n-1)*3)/n) end
  cw = math.min(cw,36)
  local grid,modes,reasons,jobs = {},{"full","tight","compact"},P.reasons or {},{}
  for i,role in ipairs(blocks) do
    local r = math.ceil(i/n)
    grid[r] = grid[r] or {mode=1}
    grid[r][#grid[r]+1] = role
    if role ~= "shop" then jobs[role] = P.liveJob(role) end
  end
  -- A job that is not loaded has no facts to show.
  local function mode(row, role) return jobs[role] and modes[row.mode] or "compact" end
  local function rows(row)
    local most = 0
    for _,role in ipairs(row) do most = math.max(most,role == "shop" and 6 or P.jobRows(mode(row,role),reasons[role])) end
    return most
  end
  local function total()
    local t = -1
    for _,row in ipairs(grid) do t = t+rows(row)+1 end
    return t
  end
  local r = #grid
  while r > 0 and total() > h-1-top do
    if grid[r].mode < 3 then grid[r].mode = grid[r].mode+1 else r = r-1 end
  end
  local y = top
  for _,row in ipairs(grid) do
    local rh = rows(row)
    if y+rh-1 > h-2 then break end
    for i,role in ipairs(row) do
      local x = 2+(i-1)*(cw+3)
      if i > 1 then for j = y,y+rh-1 do c.put(x-2,j,"|","c") end end
      if role == "shop" then P.shopBlock(c,session,x,y,cw)
      else P.job(c,x,y,cw,role,jobs[role],mode(row,role),reasons[role]) end
    end
    y = y+rh+1
  end
  P.nav(c,h,{{"ALERTS","alerts","plain"},{"PAIR","pair","plain"}})
end

P.alertsFrame = function(c, session, w, h)
  local panel = session.panel
  c.section(2,3,w-2,"ALERTS",#P.alerts,#P.alerts > 0 and "e" or "8")
  local pages = P.alertPages(P.alerts,w,h)
  panel.alertPage = (panel.alertPage or 0) % math.max(1,#pages)
  if #P.alerts == 0 then c.put(2,4,"no alerts","8") end
  P.alertRows(c,pages[panel.alertPage+1])
  P.pager(c,h,panel.alertPage,math.max(1,#pages),"alert-prev","alert-next")
  P.back(c,h,"panel-back")
end

-- Line digits as large as fit between the header and the chips; nil when they do not fit.
P.codeFit = function(w, h)
  local dh = math.min(11,h-7)
  dh = dh-(1-dh%2)
  local gap = w >= 40 and 2 or 1
  local dw = math.min(9,math.floor((w-2-5*gap)/6))
  dh = math.min(dh,2*dw+1)
  if dh >= 5 and dw >= 3 then return {dw=dw,dh=dh,gap=gap} end
end
P.panelPair = function(c, session, w, h)
  local fit,g = P.codeFit(w,h),{y=3,ty=4,list=h-2,new=h,back=h}
  if fit then g.dw,g.dh,g.gap,g.ty = fit.dw,fit.dh,fit.gap,3+fit.dh+(4+fit.dh < h-2 and 1 or 0) end
  if w < 19 then g.list,g.new = h-4,h-2 end
  P.pairPage(c,session,session.panel,w,h,g)
end

-- The paired keys: one row each from 40 columns, else the age and the chip on a second row.
P.pairedFrame = function(c, w, h, session)
  local panel = session.panel
  local rows = SO.pair.list and SO.pair.list() or {}
  local machines = SO.mods.state and SO.mods.state.get("machines") or {}
  local step = w >= 40 and 1 or 2
  local capacity = math.max(1,math.floor((h-5)/step))
  local pages = math.max(1,math.ceil(#rows/capacity))
  panel.pairedPage = (panel.pairedPage or 0) % pages
  c.section(2,3,w-2,"PAIRED",panel.forgetFailed and "save failed" or #rows,panel.forgetFailed and "e" or "8")
  if panel.confirm and P.now() >= panel.confirm.expires then panel.confirm = nil end
  for i=1,capacity do
    local row = rows[panel.pairedPage*capacity+i]
    if row then
      local y,id = 4+(i-1)*step,"#"..row.id
      local machine = machines[tostring(row.id)] or {}
      local kind = tostring(machine.role or machine.kind or ""):gsub("[%c]", " ")
      local age = machine.seen and math.max(0,math.floor((P.now()-machine.seen)/1000))
      age = age and (age < 60 and age.."s" or math.floor(age/60).."m") or "-"
      c.put(2,y,id,"0")
      if step == 1 then
        if #kind <= 9 then c.put(8,y,kind,"8") end
        c.put(18,y,row.fingerprint,"0");c.put(24,y,age,"8")
      else
        if 2+#id+#kind <= w-6 then c.put(3+#id,y,kind,"8") end
        c.put(w-4,y,row.fingerprint,"0");c.put(2,y+1,age,"8")
      end
      if row.id ~= session.id then
        local confirm = panel.confirm and panel.confirm.id == row.id
        P.act(c,y+step-1,confirm and "CONFIRM" or "FORGET",
          confirm and ("forget-confirm:"..row.id..":"..panel.confirm.token) or "forget:"..row.id,confirm and "e" or "0")
      end
    end
  end
  P.pager(c,h,panel.pairedPage,pages,"paired-prev","paired-next")
  P.back(c,h,"paired-back")
end

-- The enroll window: token, joined count, then one row per request with OK and NO, or two rows
-- when an id and kind do not fit beside the fingerprint and chips.
P.enrollFrame = function(c, w, h, session, view)
  local panel = session.panel
  local left = math.max(0,math.ceil(view.left/1000))
  c.section(2,3,w-2,"ENROLL",string.format("%d:%02d",math.floor(left/60),left%60),"0")
  local token,y = view.token,4
  if #token <= w-2 then c.put(2,4,token,"0")
  else
    local cut = select(2,token:find("^%d+%-%w+%-%w+"))
    c.put(2,4,token:sub(1,cut),"0");c.put(2,5,token:sub(cut+2),"0");y = 5
  end
  c.leader(2,y+1,w-2,"joined",view.joined.."/"..view.cap)
  c.section(2,y+2,w-2,"PENDING",panel.enrollFailed and "save failed" or #view.rows,panel.enrollFailed and "e" or "8")
  local two,foot = false,w < 23 and h-1 or h
  for _,row in ipairs(view.rows) do if #("#"..row.id.." "..row.kind) > w-17 then two = true end end
  -- APPROVE ALL names the drawn rows, and the display only accepts ids
  -- from the frame it was sent, so it approves what the owner saw.
  local shown,ry = {},y+3
  for _,row in ipairs(view.rows) do
    local cy,fx,id = two and ry+1 or ry,two and w-4 or w-14,"#"..row.id
    if cy <= foot-2 then
      shown[#shown+1] = row.id.."-"..row.n
      c.put(2,ry,id,"0")
      if 2+#id+#row.kind <= fx-2 then c.put(3+#id,ry,row.kind,"8") end
      c.put(fx,ry,row.fp,"0")
      P.act(c,cy,"OK","enroll-ok:"..row.id..":"..row.n,"9",w-6)
      P.act(c,cy,"NO","enroll-no:"..row.id..":"..row.n,"e")
    end
    ry = cy+1
  end
  c.chip(2,foot,"APPROVE ALL","enroll-all:"..table.concat(shown,"."),"primary")
  c.chip(w-7,h,"CLOSE","enroll-close")
end

-- dot is the pocket's FLEET dot when a pocket draws PAIRED or ENROLL under its own tabs.
P.render = function(w, h, session, dot)
  if not U then return {rows={{text="panel needs so-ui.lua",fg="0",bg="f"}},buttons={}} end
  session = session or {}
  session.panel = session.panel or {search="",page="main"}
  local c = U.canvas(w,h)
  local enroll = SO.enroll and SO.enroll.view(session.id)
  if session.panel.page == "enroll" and not (enroll and enroll.token) then session.panel.page = "pair" end
  local page = session.panel.page
  if page ~= "paired" then session.panel.confirm = nil end
  if dot ~= nil then P.tabBar(c,"pair",dot) else P.header(c,w,h,page ~= "paired" and page ~= "enroll" and page ~= "pair" and page ~= "alerts") end
  if page == "paired" then P.pairedFrame(c,w,h,session)
  elseif page == "enroll" then P.enrollFrame(c,w,h,session,enroll)
  elseif page == "pair" then P.panelPair(c,session,w,h)
  elseif page == "alerts" then P.alertsFrame(c,session,w,h)
  else P.main(c,session,w,h) end
  local frame = c.frame()
  session.panel.drawn = {}
  for _, b in ipairs(frame.buttons) do
    session.panel.drawn[b.id] = {x=b.x,y=b.y,w=b.w,h=b.h,page=page}
  end
  return frame
end

-- A paired display acting through its own session on a drawn control.
P.trusted = function(session, event)
  return session.id ~= nil and session.isDisplay and session.w and SO.pair.key(session.id) ~= nil
    and (not event or (event.from == session.id and P.drawn(event)))
end

P.enrollInput = function(event, panel, id)
  if not SO.enroll or not P.trusted(event.session, event) then return end
  local owner = event.from
  panel.drawn = nil
  if id == "enroll" then
    if SO.enroll.open(owner) then panel.page, panel.enrollFailed = "enroll", nil end
    return
  end
  local view = SO.enroll.view(owner)
  if not view or not view.token then return end
  local failed
  local function decide(device, n, approve)
    local ok, err = SO.enroll.decide(device, n, approve)
    if not ok and err ~= "gone" then failed = true end
  end
  if id == "enroll-close" then
    SO.enroll.close()
    panel.page = "pair"
  elseif id:match("^enroll%-all:[%d%-%.]*$") then
    for device, n in id:gmatch("(%d+)%-(%d+)") do decide(tonumber(device),tonumber(n),true) end
  else
    local verb, device, n = id:match("^enroll%-(%a+):(%d+):(%d+)$")
    if verb == "ok" or verb == "no" then decide(tonumber(device),tonumber(n),verb == "ok") end
  end
  panel.enrollFailed = failed
end

P.input = function(event)
  local session = event.session
  if not session then return end
  session.panel = session.panel or {search="",page="main"}
  local panel,id = session.panel,event.id
  if type(id) == "string" and id:match("^enroll") then return P.enrollInput(event,panel,id) end
  if id == "paired" or id == "paired-back" or id == "paired-prev" or id == "paired-next"
    or type(id) == "string" and id:match("^forget") then
    if event.from ~= session.id or not session.isDisplay or not session.w or not SO.pair.key(event.from) or not P.drawn(event) then return end
    if id == "paired" then panel.page="paired"
    elseif id == "paired-back" then panel.page="pair"
    elseif id == "paired-prev" then panel.pairedPage=(panel.pairedPage or 0)-1
    elseif id == "paired-next" then panel.pairedPage=(panel.pairedPage or 0)+1
    else
      local target = tonumber(id:match("^forget:(%d+)$"))
      if target and target ~= session.id and SO.pair.key(target) then
        P.confirmSeq = P.confirmSeq + 1
        panel.confirm = {id=target,token=tostring(P.confirmSeq),expires=P.now()+15000,key=SO.pair.key(target)}
        panel.drawn = nil
        return
      end
      local device, token = id:match("^forget%-confirm:(%d+):(%d+)$")
      target = tonumber(device)
      local confirm = panel.confirm
      panel.confirm, panel.drawn = nil, nil
      if target and target ~= session.id and confirm and confirm.id == target and confirm.token == token and P.now() < confirm.expires
        and SO.pair.key(target) == confirm.key and type(SO.forgetDevice) == "function" then
        local ok = SO.forgetDevice(target,event.from)
        if not ok then panel.forgetFailed = true else panel.forgetFailed = nil end
      end
      return
    end
    panel.confirm, panel.drawn = nil, nil
    return
  end
  if id == "panel-back" or id == "pair" or id == "alerts" or id == "lost" then panel.confirm, panel.drawn = nil, nil end
  if type(event.text) == "string" and session.keyboard then panel.search = event.text:sub(1,256);return end
  if event.open and SO.mods.health and (id == "health" or id == "attention" or id == "alerts") then
    event.open(id);return
  end
  if id == "panel-back" then panel.page="main"
  elseif id == "pair" or id == "alerts" then panel.page=id
  elseif id == "lost" and panel.page == "main" then panel.page,panel.alertPage = "alerts",0
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
      -- 1, 16, 64 or the typed quantity for the shown item, or the last order's count and item again;
      -- shop.order refuses a count over one stack.
      local amount,name = (id or ""):match("^order:(%d+):(.+)$")
      amount = tonumber(amount or (id or ""):match("^order:(%d+)$"))
      local shop = SO.mods.shop
      if amount and P.screens.shop and session.keyboard and shop and type(shop.order) == "function" then
        local search,item = name or P.split(panel.search),nil
        if name then
          -- A repeated order names its id; it orders that exact id or nothing (S.best would take a partial match).
          for _,match in ipairs(type(shop.matches) == "function" and shop.matches(name,4096) or {}) do
            if match.name == name then item = P.tag(match,P.shared(shop)) end
          end
        else item = P.tag(P.item(shop,search),P.shared(shop)) end
        if name and not item then panel.sent = {why="not in stock"}
        else panel.sent = P.order(shop,item and item.name or search,amount,item and item.label or "") end
      end
    end
    P.refresh()
  end
end

-- The pocket role (26x20) in route A; docs/ui/schematic/pocket.py is its twin. A tab row and four
-- pages. ALERTS is a page under FLEET, opened from its alert rows. Every control is one row tall.
P.tabs = {"FLEET","JOBS","SHOP","PAIR"}
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
  q.alerts,q.flagHits = {},false
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

-- One page of P.alertPages from row 4: a coral ! beside each flag's rows.
P.alertRows = function(c, page)
  local y = 4
  for _,rows in ipairs(page or {}) do
    c.put(2,y,"!","e")
    for _,row in ipairs(rows) do c.put(4,y,row[1],row[2]);y = y+1 end
    y = y+1
  end
end

P.alertPage = function(c, state, m, w, h)
  c.section(2,3,w-2,"ALERTS",#m.flags,#m.flags > 0 and "e" or "8")
  local pages = P.alertPages(m.flags,w,h)
  state.alertPage = (state.alertPage or 0) % math.max(1,#pages)
  P.alertRows(c,pages[state.alertPage+1])
  if #pages > 1 then
    c.chip(2,h,U.g.left,"alert-prev")
    local n = (state.alertPage+1).."/"..#pages
    c.put(math.floor((w-#n)/2)+1,h,n,"8")
    c.chip(w-3,h,U.g.right,"alert-next")
  end
end

-- A job's facts: the module's facts() when it has one, else the status model, else the probed state.
-- The second value is true when the module itself answered.
P.jobData = function(role, m)
  local mod = SO.mods[role == "mining" and "mine" or "lumber"]
  if mod and type(mod.facts) == "function" then
    local ok,f = pcall(mod.facts)
    if ok and type(f) == "table" then return f,true end
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

-- A long hold reason reads as its first word; ALERTS has the rest. A word that does not fit is left out.
P.word = function(state, room)
  if #state <= room then return state end
  local word = state:match("^[^ :;,]*") or state
  return #word <= room and word or ""
end

-- A grey chip without a target, for a control whose module is missing.
P.dead = function(c, x, y, label, width)
  c.put(x,y,string.rep(" ",width),"8","7")
  c.put(x+math.floor((width-#label)/2),y,label,"8","7")
end

-- START and STOP in cw cells from x; the one that does nothing now is muted. Missing jobs get grey chips.
P.jobChips = function(c, x, y, cw, role, running, loaded)
  local half = math.floor((cw-2)/2)
  for i,cmd in ipairs({"start","stop"}) do
    local cx,label = i == 1 and x or x+cw-half,cmd:upper()
    if loaded then
      local kind = i == 1 and (running and "muted" or "primary") or (running and "stop" or "muted")
      c.chip(cx,y,label,role..":"..cmd,kind,half)
    else P.dead(c,cx,y,label,half) end
  end
end

-- Rows of a job block: full 7, tight 6 (no spare row unless a flag needs it), compact 2 (3 with a flag).
P.jobRows = function(mode, reason)
  if mode == "compact" then return reason and 3 or 2 end
  return (mode == "full" or reason) and 7 or 6
end

-- A job block cw cells wide: the section with the state word, the facts, a refused start as a flag
-- on the row above START and STOP.
P.job = function(c, x, y, cw, role, f, mode, reason)
  local title,loaded = role:upper(),f ~= nil
  local state = loaded and tostring(f.state or "-") or "not loaded"
  local word = P.word(state,cw-#title-3)
  local last = y+P.jobRows(mode or "full",reason)-1
  c.section(x,y,cw,title,word,loaded and U.tone(word) or "8")
  if reason then c.flag(x,last-1,cw,P.wrap(reason,cw-2)[1] or "") end
  if loaded and mode ~= "compact" and role == "mining" then
    local frac = (f.done or 0).."/"..(f.total or 0)
    c.progress(x,y+1,math.min(10,cw-#frac-1),f.done or 0,f.total or 0)
    c.leader(x,y+2,cw,"busy",f.busy and f.workers and (f.busy.."/"..f.workers) or "-",f.busy and f.workers and "0" or "8")
    local lane,fuel = f.lane,f.fuel
    c.leader(x,y+3,cw,"lane",lane and (U.arrow(lane.facing)..lane.id) or "-",lane and "b" or "8")
    c.leader(x,y+4,cw,"min fuel",fuel and (fuel.value.." #"..fuel.id) or "-",fuel and (fuel.value < 500 and "1" or "0") or "8")
  elseif loaded and mode ~= "compact" then
    local spots = f.spots or 0
    local frac = (f.ready or 0).."/"..spots
    c.progress(x,y+1,math.min(spots > 0 and spots or 12,12,cw-#frac-1),f.ready or 0,spots,"d",U.g.spade,"8",U.g.club)
    for i,row in ipairs({{"next grow","grow"},{"saplings","saplings"},{"fuel","fuel"}}) do
      local v = f[row[2]]
      c.leader(x,y+1+i,cw,row[1],v == nil and "-" or tostring(v),v == nil and "8" or "0")
    end
  end
  P.jobChips(c,x,last,cw,role,loaded and state ~= "stopped",loaded)
end

-- The item the order chips act on: the tapped one while it is listed, else the first listed.
P.shown = function(state, items)
  for _,item in ipairs(items) do if item.name == state.selected then return item end end
  return items[1]
end

-- The pocket's list for its filter: the search's matches, or its low or empty items from shop.lows.
P.shopItems = function(shop, search, filter)
  if filter == "all" or type(shop.lows) ~= "function" then return shop.matches(search,256) end
  local list = {}
  for _,item in ipairs(shop.lows(256,search)) do if item.state == filter then list[#list+1] = item end end
  return list
end

-- Search, the all/low/empty chips, then one page of matches with the shown item's order chips under it
-- (1, 16 and 64, or the typed quantity, then STACK and ALL; none for an empty item), a pager on row h-2
-- when they do not fit, the last order on row h-1 and the shop's reply on row h.
P.shopPage = function(c, state, keyboard, w, h)
  local shop = SO.mods.shop
  if not P.screens.shop or not shop or type(shop.matches) ~= "function" or type(shop.order) ~= "function" then
    c.put(2,3,"shop not loaded","8");return
  end
  local raw,y = state.search or "",3
  local search,qty = P.split(raw)
  if keyboard then
    local typed = raw:sub(-(w-8))
    c.put(2,3,">","8");c.put(4,3,typed,"0");c.put(4+#typed,3,"_","9")
    if raw ~= "" then c.chip(w-3,3,U.g.cross,"clear","off") end
    y = 4
  end
  local filter,cw = state.filter or "all",math.floor((w-4)/3)
  for i,f in ipairs({"all","low","empty"}) do
    if f == "all" or type(shop.lows) == "function" then
      c.chip(2+(i-1)*(cw+1),y,f,"show:"..f,filter == f and "on" or "plain",cw)
    end
  end
  y = y+1
  local room = P.room(shop)
  if not room.found then c.flag(2,y,w-2,"storage room not found") end
  if room.stale and room.found then c.put(2,y,"stock stale","1");y = y+1 end
  local items = room.found and P.shopItems(shop,search,filter) or {}
  local shared = P.shared(shop)
  for i,item in ipairs(items) do items[i] = P.tag(item,shared) end
  if #items == 0 and room.found then
    c.put(2,y,search == "" and filter == "all" and "no stock" or filter ~= "all" and "none "..filter or "no match","8")
  end
  local grow = function(item) return (tonumber(item.count) or 0) > 0 and 3 or 0 end
  local bottom,list = h-2,items
  if #items+grow(P.shown(state,items) or {count=0}) > bottom-y+1 then
    -- Pages hold the rows above the pager less the shown item's chip rows.
    local per = math.max(1,bottom-y-3)
    local pages = math.ceil(#items/per)
    state.shopPage = math.max(1,math.min(state.shopPage or 1,pages))
    list = {}
    for i = (state.shopPage-1)*per+1,math.min(#items,state.shopPage*per) do list[#list+1] = items[i] end
    U.pager(c,bottom,state.shopPage.."/"..pages,state.shopPage > 1,state.shopPage < pages)
    bottom = bottom-1
  else state.shopPage = 1 end
  local shown = P.shown(state,list)
  for _,item in ipairs(list) do
    local n = tonumber(item.count) or 0
    if y > bottom-(item == shown and grow(item) > 0 and 2 or 0) then break end
    if item == shown then c.put(1,y,string.rep(" ",w),"0","7") end
    c.leader(2,y,w-2,item.label,tostring(item.count),n == 0 and "8" or n < 10 and "1" or "0","0")
    c.hit("pick:"..item.name,2,y,w-2,1)
    y = y+1
    if item == shown and n > 0 then
      local half = math.floor((w-3)/2)
      if not qty then
        for i,amount in ipairs({1,16,64}) do
          c.chip(2+(i-1)*(cw+1),y,tostring(amount),"order:"..amount..":"..item.name,"plain",cw)
        end
      else
        local stack = tonumber(item.stack) or type(shop.stack) == "function" and shop.stack(item.name) or 64
        if qty >= 1 and qty <= stack then c.chip(2,y,"ORDER "..qty,"order:"..qty..":"..item.name,"plain",w-2)
        else P.dead(c,2,y,"MAX "..stack,w-2) end
      end
      c.chip(2,y+1,"STACK","order:stack:"..item.name,"plain",half)
      c.chip(3+half,y+1,"ALL","order:all:"..item.name,"plain",half)
      y = y+3
    end
  end
  if state.sent then
    local text,fg,detail = P.orderLine(state.sent,w-2)
    c.put(2,h-1,text:sub(1,w-2),fg)
    if detail then c.put(2,h,detail:sub(1,w-2),"8") end
    -- The last order sends again with the same count, through shop.order and its one-stack cap.
    if room.found and state.sent.name then c.hit("order:"..state.sent.n..":"..state.sent.name,2,h-1,w-2,1) end
  end
end

-- The code in six line digits, a teal tick row counting its five minutes down, then PAIRED (and ENROLL)
-- and NEW CODE. g places them: the pocket's PAIR tab by default, the panel's PAIR page from P.panelPair.
P.pairPage = function(c, session, state, w, h, g)
  g = g or {y=5,dw=3,dh=7,gap=1,ty=14,list=h-4,new=h-2}
  local invitation = P.invitation(state)
  local code = invitation and tostring(invitation.code) or "------"
  local width = g.dw and #code*(g.dw+g.gap)-g.gap or w-2
  local x = math.floor((w-width)/2)+1
  if g.dw then c.digits(x,g.y,code,invitation and "0" or "8",g.dw,g.dh,g.gap)
  else c.put(x,g.y,code,invitation and "0" or "8") end
  if invitation then
    local left = math.max(0,invitation.expires-P.now())
    local secs = math.ceil(left/1000)
    c.ticks(x,g.ty,width-5,U.filled(width-5,left,P.codeLife),"9")
    c.put(x+width-4,g.ty,string.format("%d:%02d",math.floor(secs/60),secs%60),"0")
  elseif state.pairBusy then c.put(x,g.ty,"code in use","1") end
  if P.paired(session) then
    if g.back == g.new then c.chip(2,g.new,"NEW CODE","pair-code") else c.chip(2,g.new,"NEW CODE","pair-code","plain",w-2) end
  end
  if g.back then P.back(c,g.back,"panel-back") end
  -- The paired devices and the enroll window open as pages of PAIR; the panel's chips keep their own width.
  if g.back then
    local x = c.chip(2,g.list,"PAIRED","paired")+1
    if not SO.enroll then return end
    local enroll = SO.enroll.view(session.id)
    if P.trusted(session) and (not enroll or enroll.token) then c.chip(x,g.list,"ENROLL","enroll","primary")
    else P.dead(c,x,g.list,"ENROLL",8) end
    return
  end
  if not SO.enroll then c.chip(2,g.list,"PAIRED","paired","plain",w-2);return end
  -- ENROLL has no target while another display holds the window.
  local enroll,bw = SO.enroll.view(session.id),math.floor((w-3)/2)
  c.chip(2,g.list,"PAIRED","paired","plain",bw)
  if P.trusted(session) and (not enroll or enroll.token) then c.chip(3+bw,g.list,"ENROLL","enroll","primary",bw)
  else P.dead(c,3+bw,g.list,"ENROLL",bw) end
end

P.pocketState = function(session)
  session.pocket = type(session.pocket) == "table" and session.pocket or {page="fleet",search=""}
  return session.pocket
end

P.pocket = function(w, h, session)
  session = session or {}
  local state,m,c = P.pocketState(session),P.model(),U.canvas(w,h)
  local page = state.page
  local panel = session.panel
  if page == "panel" then
    if panel and (panel.page == "paired" or panel.page == "enroll") then return P.render(w,h,session,#m.flags > 0) end
    state.page,page = "pair","pair"
  end
  if page == "fleet" or not page then P.fleetPage(c,m,w,h);return c.frame() end
  P.tabBar(c,page == "alerts" and "fleet" or page,#m.flags > 0)
  if page == "alerts" then P.alertPage(c,state,m,w,h)
  elseif page == "jobs" then
    for i,role in ipairs({"mining","lumber"}) do
      local screen = P.screens[role]
      local loaded = screen and type(screen.render) == "function" and type(screen.input) == "function"
      P.job(c,2,i == 1 and 3 or 12,w-2,role,loaded and P.jobData(role,m) or nil)
    end
    local fuel,fg = P.fuel(P.screens.shop and SO.mods.shop,w-13)
    if fuel then P.fuelRow(c,h,w-2,fuel,fg) end
  elseif page == "shop" then P.shopPage(c,state,session.keyboard,w,h)
  elseif page == "pair" then P.pairPage(c,session,state,w,h) end
  local frame = c.frame()
  if page == "pair" then
    -- P.input acts only on controls the panel recorded as drawn on its page.
    session.panel = panel or {search="",page="pair"}
    session.panel.page, session.panel.drawn = "pair", {}
    for _,b in ipairs(frame.buttons) do session.panel.drawn[b.id] = {x=b.x,y=b.y,w=b.w,h=b.h,page="pair"} end
  end
  return frame
end

-- One tap is one action, and only on the page that drew it.
P.pocketInput = function(event)
  local session = event.session
  if not session then return end
  local state, id = P.pocketState(session), event.id
  if state.page == "panel" then
    if (id or ""):match("^tab:") then state.page = nil else P.input(event);return end
  end
  if state.page == "pair" and (id == "paired" or id == "enroll") then
    P.input(event)
    local panel = session.panel
    if panel and (panel.page == "paired" or panel.page == "enroll") then state.page = "panel" end
    return
  end
  if type(event.text) == "string" then
    if session.keyboard then state.search,state.selected,state.sent,state.shopPage = event.text:sub(1,64),nil,nil,1 end
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
    local amount, item = (id or ""):match("^order:(%w+):(.+)$")
    local filter = (id or ""):match("^show:(%a+)$")
    amount = amount and (amount:match("^%d+$") and tonumber(amount) or amount)
    if name then state.selected,state.sent = name,nil
    elseif id == "clear" then state.search,state.selected,state.sent,state.shopPage = "",nil,nil,1
    elseif filter == "all" or filter == "low" or filter == "empty" then
      state.filter,state.selected,state.shopPage = filter,nil,1
    elseif id == "prev" or id == "next" then
      state.shopPage,state.selected = math.max(1,(state.shopPage or 1)+(id == "next" and 1 or -1)),nil
    elseif (type(amount) == "number" or amount == "stack" or amount == "all")
        and P.screens.shop and shop and type(shop.order) == "function" and type(shop.matches) == "function" then
      -- The chip names its item; it must still match the search. shop.order refuses a count over one stack.
      for _,match in ipairs(shop.matches(P.split(state.search),256)) do
        if match.name == item then
          state.sent = P.order(shop,item,amount,P.tag(match,P.shared(shop)).label)
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
