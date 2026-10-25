local S = dofile('tests/ui/scene.lua')
local U = dofile('so-ui.lua')
local function helpers(path, names)
  local suite, out = dofile(path), {}
  for name in names:gmatch('%S+') do out[name]=S.private(suite,name) end
  return out
end
local J = helpers('tests/ui/s3.lua','mining lumber drops')
local O = helpers('tests/ui/ra2-other.lua','build health detailRow scene')
local SH = helpers('tests/ui/ui2c.lua','loaded setup stock')
local AR = helpers('tests/ui/ra3-ar.lua','boot')
local INV = helpers('tests/ui/inventory.lua','setup sample SCENE')
local MAP = helpers('tests/so/map.lua','setup')
local W = helpers('tests/ui/w2screens.lua','buildReturn')
local HEALTH = helpers('tests/so/health.lua','health history ERROR diagnosticFacts')
local CLEAR = helpers('tests/so/disk-guard.lua','clearFixture confirm')
local SAVED = helpers('tests/so/shop.lua','savedShop')
local PANEL = helpers('tests/ui/panel.lua','bare scene')
local A, cache = {}, {}

A.render = function(id, state, w, h)
  local key=id..'/'..state
  local function once(make)
    if not cache[key] then cache[key]=make() end
    return cache[key]
  end
  if id=='panel' or id=='panel-alerts' or id=='panel-pair' or (id=='pocket-fleet' or id=='pocket-jobs' or id=='pocket-shop' or id=='pocket-alerts') or id=='pocket-pair' then
    local t=once(function()
      local b=S.new({panel=true,shop=true,facts=true,alert=id=='panel-alerts' or id=='pocket-alerts'})
      b.env.SO.mods.health=id=='panel' and {count=function() return PANEL.scene().needs end} or nil
      if state=='builder' or state=='next' and id=='panel' then
        b.env.SO.mods.build={facts=function() return {state='held',done=37,total=120,turtleId=6,alert={text='out of fuel'}} end}
      end
      if state=='missing' then b.env.SO.mods.mine,b.env.SO.mods.lumber=nil,nil b.d.screen('mining').render=nil b.d.screen('lumber').render=nil end
      b.panel.tick(0)
      return b
    end)
    t.D.model=t.D.gather()
    local page=id=='panel' and 'main' or id:sub(id:find('-',1,true)+1)
    local session={id=7,isDisplay=true,w=w,keyboard=state=='keyboard' or id:match('^pocket')~=nil,
      panel={page=page,search=state=='keyboard' and t.sys.search or '',jobPage=state=='next' and 1 or 0,alertPage=state=='next' and 1 or 0},
      pocket={page=page,search=t.sys.search}}
    if state=='code' then
      t.pending=t.sys.code
      local target=id=='panel-pair' and session.panel or session.pocket
      target.invitation={code=t.sys.code,expires=t.now+t.sys.left}
    end
    if id=='panel-alerts' and state=='empty' then S.private(t.d.screen('panel').render,'P').alerts={} end
    local role=id:match('^pocket') and 'pocket' or 'panel'
    return t.d.screen(role).render(w,h,session),t.d.screen(role).input,session
  elseif id=='panel-paired' or id=='pocket-paired' or id=='panel-enroll' or id=='pocket-enroll' or id=='panel-worker' then
    local b=once(function()
      local screens,session,env=PANEL.bare(PANEL.scene(),true)
      return {screens=screens,session=session,env=env}
    end)
    local page=id:match('paired') and 'paired' or id:match('enroll') and 'enroll' or 'worker'
    local session=b.session(page,w)
    session.panel.pairedPage=state=='next' and 1 or 0
    if state=='confirm' then session.panel.confirm={id=PANEL.scene().confirm,token='1',expires=50015000,key='key'} end
    if page=='worker' then
      b.env.SO.health={config={workerSettings=true}}
      b.env.SO.mods.lease={status=function() return {workerSettings=state~='missing',settingsControl=true,
        settings=state~='missing' and {dim='minecraft:overworld',autoToolSwap=false} or nil,
        settingsPending=state=='pending',open=state=='busy' and 'lease' or nil,
        settingsError=state=='error' and 'settings refused' or nil} end}
      session.panel.worker=4
    end
    local role=id:match('^pocket') and 'pocket' or 'panel'
    return b.screens[role].render(w,h,session),b.screens[role].input,session
  elseif id=='pocket-lists' or id=='pocket-minimum' then
    local b=once(function()
      local t=SAVED.savedShop(nil,true)
      t.stock({['minecraft:iron_ingot']=42},{['minecraft:iron_ingot']=64})
      assert(t.shop.setList('supplies',{id='supplies',name='Supplies',items={{item='minecraft:iron_ingot',count=37}}},0))
      return t
    end)
    local session={id=7,keyboard=true,pocket={page='shop',search='iron'}}
    if id=='pocket-minimum' then b.tap(session,'saved:min:0:minecraft:iron_ingot')
    else
      b.tap(session,'saved2:lists')
      if state~='scene' then b.tap(session,'saved2:open:1:supplies') end
      if state=='draft' or state=='row' then b.tap(session,'saved2:edit:1:supplies') end
      if state=='row' then b.tap(session,'saved2:row:1') end
    end
    return b.frame(session,'pocket',w,h)
  elseif id == 'status' then
    local s = once(S.new)
    local m = s.D.gather()
    if state == 'missing' then m.mining,m.lumber,m.today,m.disk=nil,nil,nil,nil
    elseif state == 'empty' then m.turtles, m.flags, m.events = {}, {}, {}
    elseif state == 'crowded' or state == 'tight' then
      local rows = {}
      for i=1,40 do
        local row = {} for k,v in pairs(m.turtles[(i-1)%#m.turtles+1]) do row[k]=v end
        row.id=i+99 rows[i]=row
      end
      m.turtles=rows
    end
    m.tight=state=='tight'
    return U.status(m,w,h)
  elseif id:match('^mining') or id:match('^lumber') then
    local mine=id:match('^mining')
    local t = once(function() return mine and J.mining({empty=state=='empty'}) or J.lumber() end)
    local session={id=7}
    if id:find('-',1,true) then t.tap(session,'tab:setup') end
    if id=='mining-ores' then t.tap(session,'ores-edit') end
    return t.render(w,h,session), t.input, session
  elseif id=='map' then
    local t=once(MAP.setup)
    local session={}
    if state~='scene' then session.map={fit=false,sx=1,sz=1,cx=184,cz=-369,level=-58,
      pick=state=='selection' and {k='turtle',id='6'} or nil} end
    return t.settle(w,h,session)
  elseif id=='ar-focus' then
    local t=once(AR.boot)
    local items={{id='ar-all',text='ALL',on=false}}
    for _,n in ipairs({3,7,12,40}) do items[#items+1]={id='ar-turtle:'..n,text='turtle #'..n,on=n==12} end
    for n=1,8 do items[#items+1]={id='ar-drop:p'..n,text='drop #'..n,on=false} end
    if state=='empty' then items={} end
    return t.A.pickLayout({count=2,picker={page=state=='next' and 2 or 1,items=items}},w,h)
  elseif id=='drops-dimension' or id=='drops-preview' or id=='drops-saved' then
    local t,session=once(J.drops),{id=7}
    t.S.views={}
    local env=S.private(t.mod.tick,'_ENV')
    if id=='drops-dimension' then
      t.S.points[3].dim=-1
      t.tap(session,'dims') t.tap(session,'dims')
    else
      if id=='drops-saved' then
        local read=env.SO.store.read
        if not t.coverageRead then
          env.SO.store.read=function(path)
            local value=read(path)
            if path=='so-server.cfg' then value.dropsSavedSetup=true end
            return value
          end
          t.coverageRead=true
        end
      end
      env.SO.mods.lease.world=function() return {dim='minecraft:overworld',x=118,y=64,z=-336} end
      t.tap(session,'testing')
      if id=='drops-preview' then t.tap(session,'turtle:12') end
    end
    return t.render(w,h,session),t.input,session
  elseif id=='ar-follow' then
    local t=once(AR.boot)
    return t.A.layout({count=1,layers={turtles=true,leases=true,drops=true,alerts=true},
      follow={focus='#12',missing=state=='missing',dims='world'}},w,h)
  elseif id=='attention-lost' then
    local t=once(function()
      return HEALTH.health(nil,function(_,env)
        env.SO.mods.display.snoozer=function() return {on=function() return false end,set=function() end,clear=function() end} end
        env.SO.mods.state={get=function(key)
          if key=='machines' then return {['12']={role='worker',seen=3180000,pose={x=120,y=64,z=-30}}} end
        end}
      end)
    end)
    local session={}
    t.render('attention',w,h,session)
    if state=='detail' then t.input('attention',session,'item:lost/12') end
    return t.render('attention',w,h,session)
  elseif id=='health-diagnostics' then
    local t=once(function() local b=HEALTH.health() HEALTH.diagnosticFacts(b) return b end)
    local session={}
    t.render('health',w,h,session)
    if state=='next' then t.input('health',session,'next') end
    return t.render('health',w,h,session)
  elseif id=='drops-queue' or id=='drops-tools' then
    local t,session=once(J.drops),{id=7}
    t.S.views={}
    t.S.queueEnabled=function() return true end
    t.S.enabled=function() return true end
    t.S.queue=id=='drops-queue' and {completed=2,total=3,state=state,current={id='ore-west'}} or nil
    t.S.task=id=='drops-tools' and state=='release' and {id=12} or nil
    t.S.compass=state=='facing' and {id=12} or nil
    if state=='facing' then t.S.queue.state='stopped' end
    if state=='feedback' then t.S.queue.state,t.S.queue.reason='stopped','stopped by operator' end
    t.tap(session,'testing')
    local view=t.S.views[7]
    view.queueSelected={[t.S.points[1].id]=true}
    view.queueTools=id=='drops-tools'
    view.fromPage=state=='found' and 1 or 0
    view.queueFeedback=state=='feedback' and 'selection unavailable' or nil
    return t.render(w,h,session),t.input,session
  elseif id:match('^drops') then
    local t,session=once(J.drops),{id=7}
    t.S.views={}
    if id=='drops-add' then t.type(session,'126 64 -337')
    elseif id=='drops-edit' then t.tap(session,'edit')
    elseif id=='drops-remove' then t.tap(session,'remove')
    elseif id=='drops-setup' then t.tap(session,'testing') end
    return t.render(w,h,session),t.input,session
  elseif id=='build-return' then
    local t=once(function() return W.buildReturn(state) end)
    return t.render(w,h,t.session)
  elseif id:match('^build') then
    local t=once(function() return O.build({inv=state=='empty' and {} or nil,noReport=state=='missing'}) end)
    local session={buildSetup=id~='build'}
    if id=='build-picker' then t.input({id='material-pick',session=session}) end
    return t.render(w,h,session),t.input,session
  elseif id=='errors-detail' then
    local t=once(function()
      return HEALTH.health(nil,function(b) b.entries={{at=3590000,text=HEALTH.ERROR}} end)
    end)
    local session={}
    t.render('errors',w,h,session) t.input('errors',session,'error:1')
    if state=='next' then t.render('errors',w,h,session) t.input('errors',session,'next') end
    return t.render('errors',w,h,session)
  elseif id=='events-history' then
    local t=once(function() return HEALTH.health(HEALTH.history().state) end)
    local session={}
    t.render('events',w,h,session)
    if state=='next' then t.input('events',session,'next')
    elseif state=='picker' then t.input('events',session,'kind')
    elseif state=='find' then t.screens.events.input({session=session,text='lumber'})
    elseif state=='facts' then
      local frame=t.render('events',w,h,session)
      for _,b in ipairs(frame.buttons) do if b.id:match('^event:') then t.input('events',session,b.id) break end end
    end
    return t.render('events',w,h,session)
  elseif id=='errors-clear' then
    local t=once(function() return CLEAR.clearFixture(state=='empty' and 0 or 1) end)
    local session={}
    t.render(session,w,h)
    if state=='confirm' then t.input(session,'error-clear')
    elseif state=='detail' or state=='next' then
      t.input(session,'error:1')
      if state=='next' then t.render(session,w,h) t.input(session,'next') end
    end
    return t.render(session,w,h)
  elseif id=='health'  or id=='attention' or id=='events' or id=='alerts' or id=='errors' or id=='events-picker' then
    local t,session=once(O.health),{}
    local role=id=='events-picker' and 'events' or id
    t.render(role,w,h,session)
    if id=='events-picker' then t.screens.events.input({id='kind',session=session}) end
    return t.render(role,w,h,session),t.screens[role].input,session
  elseif id=='turtle' or id=='turtle-pose' then
    local scene,row=O.scene(),O.detailRow()
    local sel={id=tostring(scene.detail.id)}
    if state=='error' then row.error=string.rep('storage write failed ',8) end
    if state=='confirm' then sel.confirm='remove' end
    if id=='turtle-pose' then sel.draft,row.uncertain=scene.draft,true end
    return U.turtle.render(w,h,sel,row,scene.detail.now)
  elseif id=='inventory' then
    local t=once(function() return INV.setup(w,h,{turtleInventory=true}) end)
    local scene=O.scene()
    t.now=scene.detail.now
    if state~='unknown' then t.hello(state=='empty' and {} or INV.sample()) end
    local model=t.model()
    if state=='stale' then model.stale=true end
    local now=state=='stale' and INV.SCENE.later or INV.SCENE.at
    model.at=INV.SCENE.at
    return U.turtle.inventory(w,h,{inventoryPage=state=='next' and 2 or 1},model,now)
  elseif id=='shop-saved' then
    local t=once(function()
      local b=SAVED.savedShop(nil,true)
      b.machine.env.os.epoch=function() return 0 end
      local item='minecraft:iron_ingot'
      b.stock({[item]=42},{[item]=64}) assert(b.shop.setPin(item,true,0))
      if state=='full' then
        for n=1,16 do assert(b.shop.setList('list-'..n,{id='list-'..n,name='List '..n,items={}},n-1)) end
      else assert(b.shop.setList('supplies',{id='supplies',name='Supplies',items={{item=item,count=37}}},0)) end
      return b
    end)
    S.private(t.screens.shop.render,'S').views={}
    local session={id=7,keyboard=true}
    if state=='item' then t.tap(session,'item:minecraft:iron_ingot','shop')
    elseif state~='browse' then
      t.tap(session,'saved2:lists','shop')
      if state=='list' or state=='draft' then t.tap(session,'saved2:open:1:supplies','shop') end
      if state=='draft' then t.tap(session,'saved2:edit:1:supplies','shop') end
    end
    return t.frame(session,'shop',w,h)
  elseif id:match('^shop') then
    local t,session=once(SH.loaded),{id=2}
    t.S.views={}
    t.S.recent['minecraft:iron_ingot']=SH.stock().orders
    local ids= id=='shop-low' and {'tab:low'} or id=='shop-find' and {'tab:find','key:I','key:R','key:O','key:N'}
      or {'cat:ores'}
    for _,bid in ipairs(ids) do t.input({id=bid,session=session}) end
    if id=='shop-item' then
      t.input({id='item:minecraft:iron_ingot',session=session})
      t.input({id='order:16:minecraft:iron_ingot',session=session})
      t.mod.listen.roomsorter(9,{rid=t.sends[#t.sends].body.rid,'Getting 16 Iron ingot...'})
    elseif id=='shop-picker' then t.input({id='pick:cats',session=session}) end
    return t.render(w,h,session),t.input,session
  elseif id=='ar' then
    local t=once(AR.boot)
    local layers={turtles=true,leases=true,drops=true,alerts=true}
    local model={count=state=='empty' and 0 or 2,layers=layers,
      alert=state=='error' and {text=string.rep('storage write failed ',8),i=1,n=2} or nil}
    return t.A.layout(model,w,h)
  elseif id:match('^terminal') then
    local t=once(S.new)
    local mode=id=='terminal' and 'normal' or id:sub(10)=='roles' and 'role' or id:sub(10)
    local v={id=1,uptime='up 3h12',mode=mode,log=t.sys.log,offset=0,code=t.sys.code,now=0,expires=292000,
      input='6 shop',notice='display 7: status',displays={
      {id=1,size='57x24',role='status'},{id=2,size='26x20',role='pocket'},
      {id=5,size='57x24',role='mining'},{id=6,size='57x24',role='unassigned'},
      {id=7,size='15x10',role='status'},{id=9,size='-',role='drops'}}}
    return t.d.terminal(t.D.gather(),v,w,h)
  elseif id=='unassigned' or id=='unloaded' then
    local t=once(S.new)
    return t.D.idFrame(w,h,id=='unassigned' and 6 or 9,id=='unloaded' and 'MAP' or 'UNASSIGNED')
  elseif id=='alert' then
    local t=once(function() return S.new({alert=true}) end)
    t.now=50000000
    local session={alertSeen={}}
    t.frame(session,w,h) t.now=t.now+2000
    return t.frame(session,w,h)
  end
  error('unknown Lua adapter '..id)
end
return A
