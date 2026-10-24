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
      if role ~= "shop" then
        local frame = screen.render(57, 24)
        local header = frame and frame.rows and frame.rows[2] or frame and frame.rows and frame.rows[1]
        if header and header.text and header.text:find("running", 1, true) then P.states[role] = "running" end
      end
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
  P.reasons = {}
  for role,key in pairs({mining="mine.alert",lumber="lumber.alert"}) do
    local reason=state and state.get and state.get(key)
    if type(reason)=="table" then P.reasons[role]=reason.text end
  end
  local paired=state and state.get and state.get("pair.done")
  P.paired=nil
  if type(paired)=="table" and type(paired.at)=="number" and P.now()-paired.at < 30000 then
    local machine=machines[tostring(paired.id)] or {}
    P.paired="Paired "..(machine.role or "client").." #"..paired.id..(machine.label and (" "..machine.label) or "")
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
end

P.block = function(c, role, x, y, w, height, compact)
  local loaded = P.states[role] ~= "not loaded"
  c.put(x+1,y,role:upper():sub(1,w-2))
  local offset = loaded and 10 or math.min(10,math.max(1,w-10))
  local reason=P.reasons and P.reasons[role]
  if reason then
    c.fill(x,y,w,1,"e") c.put(x+1,y,reason:sub(1,math.max(0,w-2)),"f","e")
  else c.put(x+offset,y,P.states[role]:sub(1,math.max(0,w-offset))) end
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
  if not session.keyboard then
    if loaded then c.button(x, y, w, "SHOP", "shop", "a", compact and 3 or 5)
    else c.fill(x, y, w, compact and 3 or 5, "c"); c.center(x, w, y + 1, "SHOP") end
    return
  end
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

P.pairedFrame = function(c, w, h, session)
  local panel = session.panel
  local rows = SO.pair.list and SO.pair.list() or {}
  local machines = SO.mods.state and SO.mods.state.get("machines") or {}
  local capacity = math.max(1, math.floor((h-4)/3))
  local pages = math.max(1, math.ceil(#rows/capacity))
  panel.pairedPage = (panel.pairedPage or 0) % pages
  if panel.forgetFailed then c.put(2,2,"SAVE FAILED","e") end
  if panel.confirm and P.now() >= panel.confirm.expires then panel.confirm = nil end
  for i=1,capacity do
    local row = rows[panel.pairedPage*capacity+i]
    if row then
      local y = 3+(i-1)*3
      local machine = machines[tostring(row.id)] or {}
      local kind = tostring(machine.role or machine.kind or "?"):gsub("[%c]", " ")
      c.put(2,y,("#"..row.id.." "..kind):sub(1,w-7))
      c.put(w-4,y,row.fingerprint)
      local age = machine.seen and math.max(0,math.floor((P.now()-machine.seen)/1000))
      c.put(2,y+1,age and (age<60 and age.."s" or math.floor(age/60).."m") or "-")
      if row.id ~= session.id then
        local confirm = panel.confirm and panel.confirm.id == row.id
        c.button(w-12,y+1,12,confirm and "CONFIRM" or "FORGET",
          confirm and ("forget-confirm:"..row.id..":"..panel.confirm.token) or "forget:"..row.id,"e",1)
      end
    end
  end
  for i,col in ipairs(U.grid(w,h,3)) do
    c.button(col.x,h,col.w,({"PREV","BACK","NEXT"})[i],({"paired-prev","paired-back","paired-next"})[i],"7",1)
  end
end

P.enrollFrame = function(c, w, h, session, view)
  local panel = session.panel
  local left = math.max(0,math.ceil(view.left/1000))
  c.header("ENROLL",string.format("%d:%02d",math.floor(left/60),left%60))
  if panel.enrollFailed then c.put(2,1,"SAVE FAILED","e") end
  local token, top = view.token, 3
  if #token <= w-2 then c.put(2,3,token)
  else
    local cut = select(2,token:find("^%d+%-%w+%-%w+"))
    c.put(2,3,token:sub(1,cut)); c.put(2,4,token:sub(cut+2)); top = 4
  end
  c.fill(2,top+1,w-2,3,"9")
  c.big(2,top+1,w-2,view.joined.."/"..view.cap,"9")
  local step = h >= 16 and 2 or 1
  local y = top+4+step-1
  panel.enrollShown = {}
  for _,row in ipairs(view.rows) do
    panel.enrollShown[#panel.enrollShown+1] = {id=row.id,n=row.n}
    if y <= h-2 then
      c.put(2,y,("#"..row.id.." "..row.kind:upper()):sub(1,w-16))
      c.put(w-13,y,row.fp)
      c.button(w-8,y,4,"OK","enroll-ok:"..row.id..":"..row.n,"9",1)
      c.button(w-3,y,4,"NO","enroll-no:"..row.id..":"..row.n,"e",1)
    end
    y = y+step
  end
  c.button(1,h-1,w,"APPROVE ALL","enroll-all","9",1)
  c.button(1,h,w,"CLOSE","enroll-close","7",1)
end

P.drawn = function(event)
  local panel = event.session.panel
  local b = panel.drawn and panel.drawn[event.id]
  return b and b.page == panel.page and type(event.x) == "number" and type(event.y) == "number"
    and event.x >= b.x and event.x < b.x+b.w and event.y >= b.y and event.y < b.y+(b.h or 1)
end

P.render = function(w, h, session)
  if not U then return {rows={{text="panel needs so-ui.lua",fg="0",bg="f"}},buttons={}} end
  session = session or {}
  session.panel = session.panel or {search="",page="main"}
  local c = U.canvas(w,h)
  local enroll = SO.enroll and SO.enroll.view(session.id)
  if session.panel.page == "enroll" and not (enroll and enroll.token) then session.panel.page = "pair" end
  local page = session.panel.page
  local inner = page == "paired" or page == "enroll"
  c.header(page == "paired" and "PAIRED" or "PANEL",inner and "" or P.time())
  if w == 26 and not inner then U.pocketHeader(c,"PANEL") c.put(8,2,P.time()) end
  if page ~= "paired" then session.panel.confirm = nil end
  if page == "paired" then
    P.pairedFrame(c,w,h,session)
  elseif page == "enroll" then
    P.enrollFrame(c,w,h,session,enroll)
  elseif page == "pair" then
    c.put(2,3,"PAIR NEW CLIENT")
    local invitation = session.panel.invitation
    if invitation and (P.now() >= invitation.expires or SO.pair.pending() ~= invitation.code) then
      session.panel.invitation = nil
      invitation = nil
    end
    if session.panel.pairBusy and not SO.pair.pending() then session.panel.pairBusy = nil end
    if session.panel.pairBusy then c.center(1,w,5,"CODE IN USE") end
    if invitation then
      c.fill(2,4,w-2,4,"9")
      c.big(2,4,w-2,invitation.code,"9")
      local left = math.max(0,math.ceil((invitation.expires-P.now())/1000))
      c.center(2,w-2,7,string.format("%d:%02d left",math.floor(left/60),left%60),"9")
    end
    if session.id and SO.pair.key(session.id) and type(SO.pairCode) == "function" then
      c.button(1,h < 12 and h-1 or h-3,w,"NEW CODE","pair-code","9",h < 12 and 1 or 3)
    else
      c.fill(1,h < 12 and h-1 or h-3,w,h < 12 and 1 or 3,"c")
      c.center(1,w,h < 12 and h-1 or h-2,"NEW CODE")
    end
    if SO.enroll then
      local cols = U.grid(w,h,2)
      c.button(cols[1].x,h-4,cols[1].w,"PAIRED","paired","7",1)
      if P.trusted(session) and (not enroll or enroll.token) then
        c.button(cols[2].x,h-4,cols[2].w,"ENROLL","enroll","9",1)
      else
        c.fill(cols[2].x,h-4,cols[2].w,1,"c")
        c.center(cols[2].x,cols[2].w,h-4,"ENROLL")
      end
    else
      c.button(1,h-4,w,"PAIRED","paired","7",1)
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
    if top == 4 then c.put(2,3,(P.paired or P.fleet):sub(1,w-2)) end
    local cols = U.grid(w,h)
    if h < 19 and #cols == 1 then
      P.block(c,"mining",1,top,w,h,true)
      P.block(c,"lumber",1,top+2,w,h,true)
      P.shop(c,session,1,top+4,w,h,true)
    elseif #cols >= 3 then
      P.block(c,"mining",cols[1].x,top,cols[1].w,h)
      P.block(c,"lumber",cols[2].x,top,cols[2].w,h)
      P.shop(c,session,cols[3].x,top,cols[3].w,h)
    elseif #cols == 2 then
      P.block(c,"mining",cols[1].x,top,cols[1].w,h)
      P.block(c,"lumber",cols[2].x,top,cols[2].w,h)
      P.shop(c,session,1,top+6,w,h)
    else
      P.block(c,"mining",1,top,w,h)
      P.block(c,"lumber",1,top+5,w,h)
      P.shop(c,session,1,top+10,w,h)
    end
    if w ~= 26 then c.button(8,2,6,"MORE","generic","7",1) end
    c.fill(1,h,w,1,"7")
    if w >= 26 then
      c.put(2,h,"GLANCE  ALERTS  PAIR")
      c.hit("status",1,h,8,1);c.hit("alerts",9,h,8,1);c.hit("pair",17,h,w-16,1)
    else
      for i,col in ipairs(U.grid(w,h,3)) do
        c.button(col.x,h,col.w,({"GLC","ALT","PAIR"})[i],({"status","alerts","pair"})[i],"7",1)
      end
    end
  end
  if page == "main" and SO.mods.health and w >= 26 and h >= 12 then
    local cols = U.grid(w,h,2)
    c.button(cols[1].x,1,cols[1].w,"HEALTH","health","7",1)
    c.button(cols[2].x,1,cols[2].w,"NEEDS "..SO.mods.health.count(),"attention","1",1)
  end
  local frame = c.frame()
  session.panel.drawn = {}
  for _, b in ipairs(frame.buttons) do
    local saved = {x=b.x,y=b.y,w=b.w,h=b.h,page=page}
    session.panel.drawn[b.id] = saved
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
  elseif id == "enroll-all" then
    for _,row in ipairs(panel.enrollShown or {}) do decide(row.id,row.n,true) end
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
  if id == "panel-back" or id == "pair" or id == "alerts" then panel.confirm, panel.drawn = nil, nil end
  if type(event.text) == "string" and session.keyboard then panel.search = event.text:sub(1,256);return end
  if event.open and SO.mods.health and (id == "health" or id == "attention" or id == "alerts") then
    event.open(id);return
  end
  if id == "panel-back" then panel.page="main"
  elseif id == "pair" or id == "alerts" then panel.page=id
  elseif id == "pair-code" and panel.page == "pair" and event.from == session.id
      and SO.pair.key(event.from) and type(SO.pairCode) == "function" then
    panel.invitation = SO.pairCode(event.from)
    panel.pairBusy = panel.invitation == nil
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

P.tick = function()
  local display = SO.mods.display
  if display and type(display.screen)=="function" then
    if not P.registered then display.screen("panel",P.render,P.input);P.registered=true end
    P.refresh()
  end
end

return {name="panel",handlers={},tick=P.tick}
