local R = dofile('tests/ui/render.lua')
local U = dofile('so-ui.lua')

local function capture(frame, w, h)
  local out = R.capture(w,h)
  assert(#frame.rows == h, 'all rows present')
  for y,row in ipairs(frame.rows) do
    local fg,bg = {},{}
    for _,run in ipairs(row.runs or {}) do
      fg[#fg+1],bg[#bg+1] = string.rep(run[2],run[1]),string.rep(run[3],run[1])
    end
    fg,bg = table.concat(fg),table.concat(bg)
    if not row.runs then
      fg = #row.fg == 1 and string.rep(row.fg,#row.text) or row.fg
      bg = #row.bg == 1 and string.rep(row.bg,#row.text) or row.bg
    end
    out.setCursorPos(1,y)
    out.blit(row.text .. string.rep(' ',#fg-#row.text),fg,bg)
  end
  for _,b in ipairs(frame.buttons) do
    assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h,'button bounds')
  end
  return out
end

local function setup()
  local s = { now=0, saved={roles={}}, calls={}, running={mining=false,lumber=true}, query='' }
  local env = setmetatable({}, {__index=_G})
  env.os = setmetatable({epoch=function() return s.now end,getComputerID=function() return 1 end}, {__index=os})
  env.SO = { now = function() return env.os.epoch("utc") end,mods={},pair={key=function() return string.rep('01',32) end},
    store={store=function() return {value=s.saved,save=function(v) s.saved=v return true end} end}}
  env.SO.proto = assert(loadfile('so-proto.lua','t',env))()
  env.rednet = {send=function() end}
  local d = assert(loadfile('so-mod-display.lua','t',env))()
  env.SO.mods.display = d
  for _,role in ipairs({'mining','lumber'}) do
    d.screen(role,function(w,h)
      local c=U.canvas(w,h);c.header(role:upper(),s.running[role] and 'running' or 'stopped');return c.frame()
    end,function(e)
      s.calls[#s.calls+1]={role,e.id};s.running[role]=e.id=='start'
    end)
  end
  d.screen('shop',function(w,h)
    local c=U.canvas(w,h)
    if s.query:lower():gsub(' ','_')=='iron' then
      c.hit('item:minecraft:iron_ingot',1,3,18,5)
      c.hit('item:minecraft:iron_ore',20,3,18,5)
    end
    return c.frame()
  end,function(e)
    if e.text then s.query=e.text else s.calls[#s.calls+1]={'shop',e.id} end
  end)
  env.SO.mods.shop={order=function(search,count)
    if search:lower()=='iron' then s.calls[#s.calls+1]={'shop','order:'..count..':minecraft:iron_ingot'} end
  end}
  local p = assert(loadfile('so-mod-panel.lua','t',env))()
  env.SO.mods.panel=p;p.tick(0)
  s.display,s.panel,s.env=d,p,env
  s.frame=function(id,w,h)
    d.handlers.hello({from=id,body={w=w or 26,h=h or 20,keyboard=true}})
    local got;d.handlers['view.get']({from=id},function(_,b) got=b end);return got
  end
  s.tap=function(id,button,text)
    local frame
    d.handlers['view.get']({from=id},function(_,body) frame=body end)
    local x,y=1,1
    for _,b in ipairs(frame.buttons) do if b.id==button then x,y=b.x,b.y break end end
    d.handlers.input({from=id,body={id=button,text=text,x=x,y=y}})
  end
  return s
end

local function model()
  local m={time='21:14',alerts={},oreShort='+12 / 10 min',tiles={}}
  for i,t in ipairs({{'TURTLES','3','3 ok, 0 lost','d'},{'LEASES','2','','b'},
    {'ALERTS','1','ore chest full','e'},{'ORE TODAY','214','+12','b'},
    {'LOGS TODAY','96','','d'},{'DISK','13%','2.1 of 16 MB','d'},
    {'DISPLAYS','4','all fresh','d'},{'DROPS','5','1 broken','1'},{'PAIR','','','9'}}) do
    m.tiles[i]={label=t[1],value=t[2],sub=t[3],bg=t[4]}
  end
  return m
end

local function private(fn, key)
  for i=1,30 do local name,value=debug.getupvalue(fn,i);if name==key then return value end end
  error('missing upvalue '..key)
end

-- B-P: the panel controls of the merged backend rows, on the scene's paired keys (tests/ui/panel-scene.txt).
local REV,OLD=string.rep('a',40),string.rep('b',40)
local function bp(o)
  o=o or {}
  local e={now=50000000,switches={},updates={},forgot={},sent={},enabled=o.enabled~=false,keys={},status=o.status or {}}
  local env=setmetatable({},{__index=_G})
  env.os=setmetatable({epoch=function() return 0 end},{__index=os})
  local proto=assert(loadfile('so-proto.lua','t',env))()
  local machines,rows,screens={},{},{}
  local f=assert(io.open('tests/ui/panel-scene.txt','rb'))
  for line in f:read('*a'):gmatch('[^\n]+') do
    local k,id,kind,seen=line:match('^(%S+)%s+(%S+)%s*(%S*)%s*(%S*)')
    if k=='paired' then
      id=tonumber(id)
      e.keys[id]='key'
      rows[#rows+1]={id=id,fingerprint=proto.hex(proto.sha256(string.rep(string.format('%02x',id),32))):sub(1,4):upper()}
      machines[tostring(id)]={role=kind~='-' and kind or nil,seen=tonumber(seen) and e.now-tonumber(seen),
        revision=kind=='turtle' and ((id==4 or id==6) and o.stale and OLD or REV) or nil}
    end
  end
  f:close()
  env.SO={now=function() return e.now end,proto=proto,
    health={revision=REV,config={panelUpdates=o.updates~=false,workerSettings=o.settings~=false}},
    mods={state={get=function(key) if key=='machines' then return machines end end},
      display={screen=function(role,render,input) if render then screens[role]={render=render,input=input} end end},
      lease={status=function(id) return e.status[id] or {} end,
        settings=function(id,changes)
          e.sent[#e.sent+1]={id,changes}
          if o.refuse then return nil,o.refuse end
          e.status[id].settingsPending={rid=1,n=1};return 1
        end}},
    pair={key=function(id) return e.keys[id] end,pending=function() end,list=function() return rows end},
    pairCode=function() end,
    forgetImpact=function() return {text=o.impact or 'parks 1 job'} end,
    forgetDevice=function(id,by) e.forgot[#e.forgot+1]={id,by};e.keys[id]=nil;return true end,
    workerUpdate=function(id) if id==6 then return {state='requested'} end end,
    updateWorker=function(id) e.updates[#e.updates+1]=id;if o.refuse then return nil,o.refuse end;return 'rid' end,
    enroll={view=function() end,open=function() return true end,close=function() end,decide=function() return true end,
      enabled=function() return e.enabled end,
      setEnabled=function(on)
        e.switches[#e.switches+1]=on
        if o.saveFails then return nil,'config verification failed' end
        e.enabled=on;return true
      end}}
  local p=assert(loadfile('so-mod-panel.lua','t',env))();p.tick(0)
  e.session={id=2,isDisplay=true,w=o.w or 57,panel={page=o.page or 'paired',search=''},pocket={page='panel'}}
  e.draw=function()
    local w,h=o.w or 57,o.h or 24
    if o.pocket then return screens.pocket.render(w,h,e.session) end
    return screens.panel.render(w,h,e.session)
  end
  e.button=function(id)
    for _,b in ipairs(e.draw().buttons) do if b.id==id or b.id:sub(1,#id+1)==id..':' then return b end end
  end
  e.tap=function(id,from)
    local b=assert(e.button(id),'missing '..id)
    local event={session=e.session,from=from or 2,id=b.id,x=b.x,y=b.y}
    if o.pocket then screens.pocket.input(event) else screens.panel.input(event) end
  end
  e.match=function(name)
    local fixture=R.load('tests/ui/fixtures/'..name..'.txt')
    local diff=R.diff(fixture,capture(e.draw(),fixture.w,fixture.h))
    assert(#diff==0,name..'\n'..table.concat(diff,'\n'))
  end
  return e
end

return function(test,equal)
  test('UI3b roleless pockets default to the pocket role; other sizes are unassigned',function()
    local s=setup();equal(s.frame(2).role,'pocket')
    equal(s.frame(3,57,24).role,'unassigned')
    equal(s.saved.roles,{})
  end)
  test('UI3b explicit generic selection survives a display module restart at both compact sizes',function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local s=setup();s.frame(2,size[1],size[2]);s.display.screen('generic',function() return {rows={},buttons={}} end)
      equal({s.display.assign(2,'drops')},{true,'display 2: drops'})
      equal(s.frame(2,size[1],size[2]).role,'generic')
      equal(s.saved.roles['2'],'generic')
      local d=assert(loadfile('so-mod-display.lua','t',s.env))()
      d.handlers.hello({from=2,body={w=size[1],h=size[2]}})
      local restored;d.handlers['view.get']({from=2},function(_,b) restored=b end)
      equal(restored.role,'generic')
    end
  end)
  test('UI3b client input height keeps the pocket tab bar and every row',function()
    local s=setup()
    s.display.handlers.hello({from=2,body={w=26,h=19,fullH=20}})
    local f;s.display.handlers['view.get']({from=2},function(_,body) f=body end)
    equal(f.role,'pocket');equal(#f.rows,20)
    local jobs
    for _,button in ipairs(f.buttons) do if button.id=='tab:jobs' then jobs=button end end
    assert(jobs and jobs.y==1,'the tab bar is the first row')
    s.tap(2,'tab:jobs');f=s.frame(2);equal(f.role,'pocket');assert(f.rows[3].text:find('MINING',1,true))
    s.tap(2,'tab:fleet');assert(s.frame(2).rows[3].text:find('TURTLES',1,true))
    equal(s.saved.roles,{})
  end)
  test('UI3b pocket FLEET shows every fact on one page and pages stay per pocket',function()
    local s=setup();s.frame(2);s.frame(3)
    local text=table.concat(capture(s.frame(2),26,20).picture().text,'\n')
    for _,label in ipairs({'TURTLES','TODAY','SERVER','disk','displays'}) do
      assert(text:find(label,1,true),label)
    end
    s.tap(2,'tab:shop')
    assert(table.concat(capture(s.frame(3),26,20).picture().text,'\n'):find('TURTLES',1,true))
    assert(not table.concat(capture(s.frame(2),26,20).picture().text,'\n'):find('TURTLES',1,true))
  end)
  -- The panel-P fixture is compared with the scene's data in tests/ui/panel.lua.
  test('UI3b panel shows the typed search and controls dispatch once per tap',function()
    local s=setup();s.now=(21*60+14)*60000;s.frame(2);assert(s.display.assign(2,'panel'));s.tap(2,nil,'iron')
    local text=table.concat(capture(s.frame(2),26,20).picture().text,'\n')
    assert(text:find('> iron_',1,true) and text:find('22:14',1,true),text)
    for _,role in ipairs({'mining','lumber'}) do for _,cmd in ipairs({'start','stop'}) do
      local n=#s.calls;s.tap(2,role..':'..cmd);equal(#s.calls,n+1);equal(s.calls[#s.calls],{role,cmd})
    end end
    local n=#s.calls;s.tap(2,'order:16');equal(#s.calls,n+1)
    equal(s.calls[n+1],{'shop','order:16:minecraft:iron_ingot'})
    s.tap(2,nil,'missing');n=#s.calls;s.tap(2,'order:16');equal(#s.calls,n)
  end)
  test('UI3b panel sessions, alert list, pairing help and monitor pages retain bounds and contrast',function()
    local s=setup();s.frame(2);assert(s.display.assign(2,'panel'));s.tap(2,nil,'iron')
    s.frame(3);assert(s.display.assign(3,'panel'));s.tap(3,nil,'gold')
    assert(table.concat(capture(s.frame(2),26,20).picture().text,'\n'):find('> iron_',1,true))
    assert(table.concat(capture(s.frame(3),26,20).picture().text,'\n'):find('> gold_',1,true))
    for _,size in ipairs({{26,20},{57,24},{39,19},{15,10},{29,12}}) do
      local w,h=unpack(size)
      for _,page in ipairs({'panel-back','alerts','pair'}) do
        if page~='panel-back' then s.tap(2,'panel-back') end
        s.tap(2,page)
        local f=s.frame(2,w,h);equal(f.role,'panel')
        local out=capture(f,w,h)
        -- Route A: no fills; coloured glyphs on f or 7, c only for structure.
        for _,row in ipairs(out.cells) do for _,cell in ipairs(row) do
          local ch,fg,bg=cell[1],cell[2],cell[3]
          assert(bg=='f' or bg=='7','fill '..bg)
          assert(ch==' ' or fg~='c' and fg~='f' and fg~='7' or fg=='c' and (ch=='-' or ch=='|' or ch=='\183'),'contrast '..fg..'/'..bg)
        end end
        if page=='pair' then
          local text=table.concat(out.picture().text,'\n');assert(not text:find('Press P on the server',1,true))
          local found={}
          for _,b in ipairs(f.buttons) do found[b.id]=true end
          -- This server has no SO.pairCode, so NEW CODE is not drawn.
          assert(found.paired and found['panel-back'] and not found['pair-code'])
        end
      end
    end
    for _,id in ipairs({'status','glance','generic','shop','map'}) do s.tap(2,id);equal(s.frame(2).role,'panel') end
    for _,b in ipairs(s.frame(2).buttons) do assert(b.id~='glance' and b.id~='generic' and b.id~='shop') end
  end)
  test('UI3b missing modules have disabled blocks and no action targets',function()
    local s=setup();local d=private(s.display.handlers.hello,'D')
    d.screens.mining=nil;d.screens.lumber=nil;d.screens.shop=nil;s.panel.tick(0)
    s.frame(2);assert(s.display.assign(2,'panel'));local f=s.frame(2)
    local picture=capture(f,26,20).picture()
    local text=table.concat(picture.text,'\n')
    local _,n=text:gsub('not loaded','');equal(n,3)
    -- START, STOP and the order sizes stay as grey chips: muted text on the panel colour.
    local grey=0
    for y=1,20 do
      for _,label in ipairs({'START','STOP','16'}) do
        local x=picture.text[y]:find(label,1,true)
        if x and picture.bg[y]:sub(x,x)=='7' then equal(picture.fg[y]:sub(x,x+#label-1),string.rep('8',#label));grey=grey+1 end
      end
    end
    equal(grey,5)
    for _,b in ipairs(f.buttons) do assert(not b.id:match(':start$') and not b.id:match(':stop$') and not b.id:match('^order:')) end
    s.tap(2,'mining:start');s.tap(2,'order:16');equal(#s.calls,0)
  end)
  test('UI3b real mining and lumber inputs save once per control tap',function()
    local s=setup();local jobs,saves={},{}
    s.env.SO.store.store=function(path)
      if path=='so-data/lumber/job' then
        jobs[path]={dim='minecraft:overworld',spots={},running=false,ground=64,
          area={x1=0,z1=0,x2=4,z2=4},turtle={id=4},fuel=4000,saplings={x=-10,y=64,z=0,side='down'},inv={}}
      end
      return {value=jobs[path],save=function(value) jobs[path]=value;saves[path]=(saves[path] or 0)+1;return true end}
    end
    s.env.SO.mods.state={canStart=function() return true end}
    jobs["so-data/mine/job"]={home={x=0,y=64,z=0,facing=0},homeSet=true,
      dim="minecraft:overworld",bottom=-58,length=48,mode="thorough",ores={},turtles={["3"]={pose={x=0,y=64,z=0},fuel=4000}},progress={done=0,nextBranch=1}}
    s.env.SO.mods.lease={onReport=function() end,status=function() return {open="park"} end}
    s.env.SO.mods.drops={list=function() return {{id="ready",dim=0,x=100000,y=64,z=0,kind="any"}} end}
    local mine=assert(loadfile('so-mod-mine.lua','t',s.env))()
    local lumber=assert(loadfile('so-mod-lumber.lua','t',s.env))()
    s.env.SO.mods.mine=mine;s.env.SO.mods.lumber=lumber
    mine.tick(0);lumber.tick(0);s.panel.tick(0)
    s.frame(2);assert(s.display.assign(2,'panel'))
    for _,role in ipairs({'mining','lumber'}) do
      local path='so-data/'..(role=='mining' and 'mine' or role)..'/job'
      for _,cmd in ipairs({'start','stop'}) do
        local n=saves[path] or 0;s.tap(2,role..':'..cmd)
        equal(saves[path],n+1);equal(jobs[path].running,cmd=='start')
      end
    end
  end)
  test('UI3b real shop orders the best match exactly once for each quantity',function()
    for _,amount in ipairs({1,16,64}) do
      local s=setup();local sends={}
      s.env.rednet.send=function(id,body,protocol) sends[#sends+1]={id=id,body=body,protocol=protocol} end
      s.env.rednet.broadcast=function() end
      local shop=assert(loadfile('so-mod-shop.lua','t',s.env))()
      s.env.SO.mods.shop=shop;shop.tick(0)
      shop.listen.roomsorter_stock(9,{totals={['minecraft:iron_ingot']=1240,['minecraft:iron_ore']=312,['minecraft:gold_ingot']=4000}})
      s.panel.tick(0);s.frame(2);assert(s.display.assign(2,'panel'));s.tap(2,nil,'IRON')
      local sessions={{id=3},{id=4},{}}
      local screen=s.display.screen('shop')
      local totals={['minecraft:iron_ingot']=1240,['minecraft:iron_ore']=312,['minecraft:gold_ingot']=4000}
      for i=1,20 do totals['minecraft:gold_'..i]=i end
      shop.listen.roomsorter_stock(9,{totals=totals})
      local function press(session,id)
        local frame=screen.render(57,24,session)
        local button
        for _,b in ipairs(frame.buttons) do if b.id==id then button=b end end
        assert(button,'missing shop button '..id)
        screen.input({id=id,x=button.x,y=button.y,session=session})
      end
      screen.input({text='gold',session=sessions[1]})
      press(sessions[1],'next')
      local selected
      for _,b in ipairs(screen.render(57,24,sessions[1]).buttons) do
        if b.id:match('^item:') then selected=b.id;break end
      end
      press(sessions[1],selected)
      screen.input({text='iron',session=sessions[2]})
      screen.input({text='gold',session=sessions[3]})
      local before={}
      for i,session in ipairs(sessions) do
        before[i]=session.id and private(s.display.handlers.hello,'D').compose('shop',57,24,session) or screen.render(57,24,session)
      end
      local panelFrame=s.frame(2)
      local orderButton
      for _,b in ipairs(panelFrame.buttons) do if b.id=='order:'..amount then orderButton=b end end
      assert(orderButton,'missing panel order button')
      local n=#sends
      s.display.handlers.input({from=2,body={id=orderButton.id,x=orderButton.x,y=orderButton.y}})
      equal(#sends,n+1)
      for i,session in ipairs(sessions) do
        local after=session.id and private(s.display.handlers.hello,'D').compose('shop',57,24,session) or screen.render(57,24,session)
        equal(after.buttons,before[i].buttons)
        for y=1,14 do equal(after.rows[y],before[i].rows[y]) end
      end
      press(sessions[1],'items')
      assert(table.concat(capture(screen.render(57,24,sessions[1]),57,24).picture().text,'\n'):find('2 of',1,true))
      assert(table.concat(capture(screen.render(57,24,sessions[3]),57,24).picture().text,'\n'):find('1 of',1,true))
      local sent=sends[#sends]
      equal(sent.id,9);equal(sent.protocol,'roomsorter');equal(sent.body.cmd,'order')
      equal(sent.body.text,'minecraft:iron_ingot');equal(sent.body.n,amount)
      for i=1,3 do s.frame(2);s.panel.tick(0) end
      equal(#sends,n+1)
    end
  end)
  test('UI3b monitor role persists and subscribed revisions stay per panel session',function()
    local s=setup()
    s.display.screen('generic',function(w,h)
      local c=U.canvas(w,h);c.header('DROP POINTS','0 points')
      c.hit('new',1,h,8,1);c.hit('status',10,h,8,1);return c.frame()
    end)
    s.frame(2,57,24);assert(s.display.assign(2,'generic'))
    for _,b in ipairs(s.frame(2,57,24).buttons) do assert(b.id~='panel','no panel link on drops') end
    s.tap(2,'panel');equal(s.frame(2,57,24).role,'generic')
    assert(s.display.assign(2,'panel'));equal(s.frame(2,57,24).role,'panel');equal(s.saved.roles['2'],'panel')
    local f=s.frame(2,57,24);local targets={}
    for _,b in ipairs(f.buttons) do
      targets[b.id]=b
      if b.id:match('^order:') then assert(b.w>=4,'monitor quantity button minimum width') end
    end
    assert(targets['mining:start'].x < targets['lumber:start'].x)
    assert(targets['lumber:start'].x < targets['order:16'].x)
    s.frame(3);s.tap(3,'panel')
    local a=s.frame(2,57,24);s.tap(3,nil,'other');equal(s.frame(2,57,24).rev,a.rev)
    s.display.handlers['view.sub']({from=2});s.display.tick(0)
    local d=assert(loadfile('so-mod-display.lua','t',s.env))()
    d.screen('panel',function(w,h) return U.canvas(w,h).frame() end)
    d.handlers.hello({from=2,body={w=57,h=24}})
    local restored;d.handlers['view.get']({from=2},function(_,b) restored=b end)
    equal(restored.role,'panel')
  end)
  test('UI3b alert list pages through all state alerts and pairing help returns',function()
    local s=setup();local values={}
    for i=1,30 do values[string.format('module%02d.alert',i)]={text='fault '..i} end
    s.env.SO.mods.state={view=function() return {values=values} end}
    s.panel.tick(0);s.frame(2);assert(s.display.assign(2,'panel'));s.tap(2,'alerts')
    local text=table.concat(capture(s.frame(2),26,20).picture().text,'\n')
    -- Each alert is its wrapped rows and a blank row, as on the pocket: eight one-line alerts a page.
    assert(text:find('fault 1',1,true));assert(text:find('fault 8',1,true));assert(not text:find('fault 9',1,true))
    assert(text:find('1/4',1,true))
    s.tap(2,'alert-next');text=table.concat(capture(s.frame(2),26,20).picture().text,'\n')
    assert(text:find('fault 9',1,true));assert(text:find('fault 16',1,true));assert(not text:find('fault 17',1,true))
    s.tap(2,'alert-prev');assert(capture(s.frame(2),26,20).picture().text[4]:find('fault 1',1,true))
    s.tap(2,'panel-back');s.tap(2,'pair');s.tap(2,'panel-back')
    assert(capture(s.frame(2),26,20).picture().text[3]:find('MINING',1,true))
  end)
  test('UI3b panel ALERTS wraps a long alert to two rows like the pocket',function()
    local s=setup()
    local long='fuel chest at drop point seven is empty and the lumber turtle cannot refuel; '
      ..'fill the chest or move the drop point, then start lumber again from the panel'
    equal(#long>=150,true)
    s.env.SO.mods.state={view=function() return {values={['lumber.alert']={text=long},['mine.alert']={text='ore chest full'}}} end}
    s.panel.tick(0);s.frame(2);assert(s.display.assign(2,'panel'));s.tap(2,'alerts')
    local rows=capture(s.frame(2),26,20).picture().text
    equal(rows[4]:sub(2,3),'! ');equal(rows[5]:sub(2,3),'  ')
    assert(rows[4]:find('fuel chest at drop',1,true),rows[4])
    assert(rows[5]:find('seven is empty',1,true),rows[5])
    equal(rows[6]:match('^%s*$')~=nil,true)
    assert(rows[7]:find('! ore chest full',1,true),rows[7])
    for _,size in ipairs({{57,24},{29,12},{15,10}}) do
      local out=capture(s.frame(2,size[1],size[2]),size[1],size[2]).picture().text
      assert(table.concat(out,'\n'):find('fuel chest',1,true),'alert drawn at '..size[1]..'x'..size[2])
    end
  end)
  -- UB-8: the keyboard panel names the item its chips order, with the stock, and the last order's reply.
  test('UI3b keyboard panel shows the best match and stock by the chips, then the order reply',function()
    local s=setup();local sends={}
    s.env.rednet.send=function(id,body) sends[#sends+1]={id=id,body=body} end
    s.env.rednet.broadcast=function() end
    local shop=assert(loadfile('so-mod-shop.lua','t',s.env))()
    s.env.SO.mods.shop=shop;shop.tick(0)
    shop.listen.roomsorter_stock(9,{totals={['minecraft:iron_ingot']=1240,['minecraft:iron_ore']=312,['minecraft:raw_gold']=4,
      ['minecraft:iron_bars']=0,['minecraft:polished_deepslate_stairs']=120}})
    s.panel.tick(0);s.frame(2);assert(s.display.assign(2,'panel'))
    local function rows() return capture(s.frame(2),26,20).picture() end
    local function row(p,pattern) for y,text in ipairs(p.text) do if text:find(pattern) then return y,text end end end
    s.tap(2,nil,'iron')
    local p=rows();local y,text=row(p,'IRON INGOT')
    assert(y and text:find('1240',1,true),'best match and stock')
    local chips;for _,b in ipairs(s.frame(2).buttons) do if b.id=='order:16' then chips=b.y end end
    equal(chips,y+1)
    s.tap(2,nil,'gold');p=rows();y=row(p,'RAW GOLD');assert(y and p.fg[y]:find('1',1,true),'low stock is amber')
    s.tap(2,nil,'nothing');assert(row(rows(),'no match'))
    s.tap(2,nil,'iron');s.tap(2,'order:16')
    equal(sends[#sends].body.text,'minecraft:iron_ingot')
    p=rows();y=row(p,'16 IRON INGOT sent');assert(y,'sent line');equal(p.fg[y]:sub(2,2),'d')
    shop.listen.roomsorter(9,{rid=sends[#sends].body.rid,'Not in storage: iron ingot'})
    p=rows();y=row(p,'16 IRON INGOT failed');assert(y,'failed line');equal(p.fg[y]:sub(2,2),'e')
    assert(p.text[y+1]:find('Not in storage: iron',1,true),p.text[y+1])
    s.tap(2,'order:64');shop.listen.roomsorter(9,{rid=sends[#sends].body.rid,'Delivered 64 Iron Ingot'})
    assert(row(rows(),'64 IRON INGOT delivered'))
    -- An exact id keeps its count, even zero, as shop.best does.
    s.tap(2,nil,'minecraft:iron_bars');y,text=row(rows(),'IRON BARS');assert(y and text:find('0%s*$'),text)
    -- A long name is cut so the count and status stay inside the 24-cell block.
    s.tap(2,nil,'deepslate_stairs');s.tap(2,'order:1')
    y,text=row(rows(),'^ 1 POLISHED');equal(text,' 1 POLISHED DEEPS... sent ')
  end)
  test('UI3b partial installs without the kit show the display id until assigned',function()
    local s=setup();s.env.fs={exists=function() return false end}
    local d=assert(loadfile('so-mod-display.lua','t',s.env))()
    d.handlers.hello({from=8,body={w=26,h=20}})
    local frame;d.handlers['view.get']({from=8},function(_,b) frame=b end)
    equal(frame.role,'unassigned');equal(frame.rows[1].text,'display 8');equal(#frame.buttons,0)
    equal({d.assign(8,'pocket')},{false,'pocket needs so-ui.lua'})
    d.screen('generic',function() return {rows={{text='drops',fg='0',bg='f'}},buttons={}} end)
    assert(d.assign(8,'drops'))
    d.handlers['view.get']({from=8},function(_,b) frame=b end)
    equal(frame.role,'generic');equal(frame.rows[1].text,'drops');equal(#frame.buttons,0)
  end)
  test('UI3b custom generic headers stay clear when panel is not loaded',function()
    local s=setup();local d=private(s.display.handlers.hello,'D');d.screens.panel=nil
    s.display.screen('generic',function(w,h)
      local c=U.canvas(w,h);c.header('DROP POINTS','0 points')
      c.hit('new',1,h,8,1);c.hit('status',10,h,8,1);return c.frame()
    end)
    s.frame(2,57,24);assert(s.display.assign(2,'generic'))
    for _,button in ipairs(s.frame(2,57,24).buttons) do assert(button.y>1) end
  end)
  test('UI3b server local monitor panel forwards controls once',function()
    local s=setup();local target=R.capture(57,24)
    target.setTextScale=function() end
    s.env.peripheral={find=function() return target end,getName=function() return 'left' end}
    s.display.tick(0)
    local d=private(s.display.handlers.hello,'D')
    local function touch(id)
      local button
      for _,b in ipairs(d.monitor.frame.buttons) do if b.id==id then button=b end end
      assert(button,'missing local button '..id)
      s.display.monitorTouch('left',button.x,button.y);s.display.tick(0)
    end
    assert(s.display.assign(1,'panel'));s.display.tick(0);equal(d.monitor.role,'panel')
    local n=#s.calls;touch('mining:start');equal(#s.calls,n+1);equal(s.calls[#s.calls],{'mining','start'})
    touch('lumber:stop');equal(#s.calls,n+2);equal(s.calls[#s.calls],{'lumber','stop'})
    touch('pair');touch('panel-back');equal(d.monitor.role,'panel')
    for _,b in ipairs(d.monitor.frame.buttons) do assert(b.id~='status' and b.id~='shop' and b.id~='glance') end
  end)
  test('UI3b monitor panels run jobs without a search field, quick orders or a shop link',function()
    for _,size in ipairs({{26,20},{29,12},{57,24},{100,38}}) do
      local s=setup()
      s.display.handlers.hello({from=2,body={w=size[1],h=size[2],keyboard=false}})
      assert(s.display.assign(2,'panel'))
      local frame
      s.display.handlers['view.get']({from=2},function(_,body) frame=body end)
      local text=table.concat(capture(frame,size[1],size[2]).picture().text,'\n')
      assert(not text:find('search',1,true) and not text:find('SHOP',1,true))
      local found={}
      for _,button in ipairs(frame.buttons) do
        assert(button.id~='search' and button.id~='shop' and not button.id:match('^order:'))
        found[button.id]=true
      end
      assert(found['mining:start'] and found['lumber:stop'] and found.alerts and found.pair)
      local calls=#s.calls
      s.tap(2,nil,'iron');s.tap(2,'order:16');s.tap(2,'shop');equal(#s.calls,calls)
      s.display.handlers['view.get']({from=2},function(_,body) frame=body end)
      equal(frame.role,'panel')
    end
  end)
  -- U5-P: the panel's EXTEND chip goes through the paired display's drawn-input path.
  local function enrollPanel(refuse)
    local e={now=1000000,exp=1000000+594000,owner=7,calls={}}
    local env=setmetatable({},{__index=_G})
    env.os=setmetatable({epoch=function() return 0 end},{__index=os})
    local screens={}
    env.SO={now=function() return e.now end,proto=assert(loadfile('so-proto.lua','t',env))(),
      mods={state={get=function() end},display={screen=function(role,render,input) if render then screens[role]={render=render,input=input} end end}},
      pair={key=function() return 'key' end,pending=function() end,list=function() return {} end},pairCode=function() end,
      enroll={view=function(owner)
        if not e.exp then return nil end
        return {owner=e.owner,left=e.exp-e.now,joined=0,cap=20,rows={},token=owner==e.owner and '1-K7QP-3MXA-9WTD-HR2E' or nil}
      end,open=function() return true end,close=function() e.exp=nil end,decide=function() return true end,
      extend=function(owner)
        e.calls[#e.calls+1]=owner
        -- As so-pair: an expired window is gone, another display's window is not this one's.
        if refuse=='closed' then e.exp=nil elseif refuse=='taken' then e.owner=9 end
        if refuse then return nil,refuse=='taken' and 'owner' or refuse end
        e.exp=e.now+600000;return true
      end}}
    local p=assert(loadfile('so-mod-panel.lua','t',env))();p.tick(0)
    local session={id=7,isDisplay=true,w=29,panel={page='enroll',search=''}}
    e.session=session
    e.draw=function() return screens.panel.render(29,12,session) end
    e.tap=function(id,from)
      local f=e.draw();local b
      for _,x in ipairs(f.buttons) do if x.id==id then b=x end end
      assert(b,'missing '..id)
      screens.panel.input({session=session,from=from or 7,id=id,x=b.x,y=b.y})
    end
    return e
  end
  test('UI3b EXTEND on the panel ENROLL page calls enrollExtend once and moves the drawn window end',function()
    local e=enrollPanel()
    assert(e.draw().rows[3].text:find('9:54',1,true))
    e.now=e.now+120000
    assert(e.draw().rows[3].text:find('7:54',1,true))
    e.tap('enroll-extend')
    equal(e.calls,{7})
    local row=e.draw().rows[3].text
    assert(row:find('10:00',1,true),row)
    e.tap('enroll-extend',8);equal(e.calls,{7})
  end)
  test('UI3b a refused EXTEND shows its reason in place of the window end',function()
    local e=enrollPanel('off')
    e.tap('enroll-extend');equal(e.calls,{7})
    local row=e.draw().rows[3].text
    assert(row:find('off',1,true) and not row:find('9:54',1,true),row)
  end)
  test('UI3b an EXTEND refused as the window closed keeps its reason on PAIR until the next enroll tap',function()
    local e=enrollPanel('closed')
    e.tap('enroll-extend');equal(e.calls,{7})
    local f=e.draw()
    equal(e.session.panel.page,'pair')
    local fixture=R.load('tests/ui/fixtures/panelrefused-S.txt')
    local diff=R.diff(fixture,capture(f,29,12))
    assert(#diff==0,table.concat(diff,'\n'))
    for _,b in ipairs(f.buttons) do assert(b.id~='enroll-extend' and b.id~='enroll-close') end
    assert(not table.concat(capture(f,29,12).picture().text,'\n'):find('K7QP',1,true))
    e.tap('enroll')
    assert(not e.draw().rows[10].text:find('closed',1,true))
  end)
  test('UI3b an EXTEND refused because another display holds the window shows taken on PAIR',function()
    local e=enrollPanel('taken')
    e.tap('enroll-extend');equal(e.calls,{7})
    local f=e.draw()
    equal(e.session.panel.page,'pair')
    local text=capture(f,29,12).picture().text
    assert(text[10]:find('ENROLL  taken',1,true),text[10])
    assert(not table.concat(text,'\n'):find('K7QP',1,true))
    for _,b in ipairs(f.buttons) do assert(b.id~='enroll' and not b.id:match('^enroll%-')) end
  end)
  test('UI3b panel installs only on the server',function()
    local f=assert(io.open('install.lua'));local source=f:read('*a');f:close()
    local roles=assert(load('return '..source:match('local ROLES = (.-)\nlocal BASE'),'roles','t',{}))()
    local function contains(list) for _,name in ipairs(list) do if name=='so-mod-panel.lua' then return true end end return false end
    assert(contains(roles.server));assert(not contains(roles.common));assert(not contains(roles.worker));assert(not contains(roles.display))
  end)
  test('B-P ENROLL ON and OFF flip the saved switch once from the drawn PAIR chip',function()
    local e=bp({page='pair',w=29,h=12})
    e.match('panelenroll-S')
    e.tap('enroll-off',8);equal(e.switches,{})
    e.tap('enroll-off');equal(e.switches,{false})
    e.match('panelenrolloff-S')
    assert(not e.button('enroll'),'ENROLL has no target while enrollment is off')
    e.tap('enroll-on');equal(e.switches,{false,true})
    assert(e.button('enroll') and e.button('enroll-off'))
    local failed=bp({page='pair',w=29,h=12,saveFails=true})
    failed.tap('enroll-off');equal(failed.switches,{false})
    local text=capture(failed.draw(),29,12).picture().text
    assert(text[10]:find('ON  save',1,true),text[10])
  end)
  test('B-P stale turtles show amber ids and UPDATE asks SO.updateWorker once behind panelUpdates',function()
    local e=bp({stale=true})
    e.match('pairedupdate-M')
    assert(not e.button('update:5') and not e.button('update:6'),'current and updating rows have no UPDATE')
    e.tap('update:4');equal(e.updates,{4})
    equal(capture(e.draw(),57,24).picture().text[3]:match('(%S+)%s*$'),'9')
    local refused=bp({stale=true,refuse='worker busy'})
    refused.tap('update:4');equal(refused.updates,{4})
    assert(capture(refused.draw(),57,24).picture().text[3]:find('#4 worker busy',1,true))
    local off=bp({stale=true,updates=false})
    for _,b in ipairs(off.draw().buttons) do assert(not b.id:match('^update:'),b.id) end
    local out=capture(off.draw(),57,24).picture()
    equal(out.fg[6]:sub(2,3),'11','a stale id stays amber without the switch')
  end)
  test('B-P FORGET arms through U.confirm and its CONFIRM row names what it parks',function()
    local e=bp({pocket=true,w=26,h=20})
    e.tap('forget:4')
    assert(e.session.panel.confirm.confirm:match('^forget:4:%d+$'),'armed through U.confirm')
    e.match('pairedimpact-P')
    e.tap('forget-confirm:4')
    equal(e.forgot,{{4,2}})
    equal(e.session.panel.confirm,nil)
    local long=bp({impact='parks 1 job; holds 1 scan'})
    long.tap('forget:4')
    long.match('pairedimpact-M')
    -- Any other tap disarms, as U.confirm does.
    long.tap('paired-next')
    equal(long.session.panel.confirm,nil)
    equal(long.forgot,{})
  end)
  test('B-P the main page shows the builder from build.facts()',function()
    local S=dofile('tests/ui/scene.lua')
    local s=S.new({panel=true,shop=true,facts=true})
    s.env.SO.mods.health={count=function() return 2 end}
    s.env.SO.mods.build={facts=function() return {state='held',done=37,total=120,turtleId=6,
      alert={key='build:fuel',severity=2,text='out of fuel'}} end}
    s.d.handlers.hello({from=21,body={w=57,h=24}})
    assert(s.d.assign(21,'panel'))
    local fixture=R.load('tests/ui/fixtures/panelbuild-M.txt')
    local diff=R.diff(fixture,S.capture(s.view(21),57,24))
    assert(#diff==0,table.concat(diff,'\n'))
    s.env.SO.mods.build={facts=function() error('broken') end}
    assert(not table.concat(S.capture(s.view(21),57,24).picture().text,'\n'):find('BUILD',1,true))
  end)
  test('B-P WORKER opens from a turtle row, shows confirmed settings and sends one change per tap',function()
    local status={[4]={workerSettings=true,settingsControl=true,settings={seq=1,dim='minecraft:the_nether',autoToolSwap=false}},
      [5]={workerSettings=true,settingsControl=true,open='l',settings={seq=1,dim='minecraft:overworld',autoToolSwap=true}}}
    local e=bp({pocket=true,w=26,h=20,status=status})
    assert(not e.button('worker:2') and not e.button('worker:3'),'only other turtles open WORKER')
    e.tap('worker:4')
    e.match('worker-P')
    e.tap('worker-dim:nether');equal(e.sent,{})
    e.tap('worker-swap:on');equal(e.sent,{{4,{autoToolSwap=true}}})
    local panel=bp({w=29,h=12,page='worker',status=status})
    panel.session.panel.worker=4
    status[4].settingsPending={rid=1,n=1}
    panel.match('worker-S')
    assert(not panel.button('worker-dim') and not panel.button('worker-swap'))
    status[4].settingsPending=nil
    panel.tap('worker-dim:end');equal(panel.sent,{{4,{dim='minecraft:the_end'}}})
    panel.session.panel.worker=5
    panel.match('workerbusy-S')
    local refused=bp({w=29,h=12,page='worker',refuse='worker busy',status={[4]={workerSettings=true,settingsControl=true,
      settings={seq=1,autoToolSwap=false}}}})
    refused.session.panel.worker=4
    refused.tap('worker-swap:on')
    assert(capture(refused.draw(),29,12).picture().text[3]:find('worker busy',1,true))
    local off=bp({settings=false,status=status})
    for _,b in ipairs(off.draw().buttons) do assert(not b.id:match('^worker'),b.id) end
    off.session.panel.page,off.session.panel.worker='worker',4
    assert(off.button('paired-back'),'WORKER closes with workerSettings off')
  end)
  test('B-P WORKER stays pending until the real lease matches the ack or a newer hello',function()
    local H=dofile('tests/so/harness.lua')
    local key=string.rep('a',64)
    local net=H.new()
    local server=net.machine({id=1,modem=true})
    server.install({'so-server.lua','so-proto.lua','so-pair.lua','so-store.lua','so-mod-state.lua','so-log.lua',
      'so-mod-lease.lua','so-mod-cells.lua','so-ui.lua','so-mod-panel.lua'})
    for _,name in ipairs({'x25519','random','blake3','chacha20','config','internal/util','internal/hw',
        'internal/curve25519','internal/fp','internal/edwards25519','internal/packing'}) do
      local path='lib/ccryptolib/'..name..'.lua'
      local f=assert(io.open(path,'rb'));server.files[path]=f:read('*a');f:close()
    end
    server.files['so-keys']=H.encode({schema=1,generation=1,value={keys={['2']=key,['3']=key}}})
    server.files['so-server.cfg']=H.encode({pos={dim=0,x=0,y=0,z=0},workerSettings=true})
    server.boot('so-server.lua')
    assert(server.alive(),tostring(server.error))
    local worker=net.machine({id=2,modem=true,turtle=true})
    worker.install({'so-proto.lua'})
    worker.env.KEY=key
    worker.spawn([[
      P = dofile("so-proto.lua")
      function send(t, body, rid) rednet.send(1, assert(P.encode(P.build(KEY, t, body, rid))), "so") end
      while true do os.pullEvent() end
    ]])
    local function send(t,body,rid) worker.env.send(t,body,rid);net.flush();assert(not server.error,tostring(server.error)) end
    local function hello(settings) send('hello',{role='turtle',capabilities={workerSettings=true},settingsControl=true,settings=settings}) end
    hello({seq=1,dim='minecraft:overworld',autoToolSwap=false,remoteN=4})
    local SO,screens=server.env.SO,{}
    local mods=setmetatable({display={screen=function(role,render,input) if render then screens[role]={render=render,input=input} end end}},{__index=SO.mods})
    local penv=setmetatable({SO=setmetatable({mods=mods},{__index=SO})},{__index=server.env})
    assert(server.env.loadfile('so-mod-panel.lua','t',penv))().tick(0)
    local session={id=3,isDisplay=true,w=29,panel={page='worker',worker=2,search=''}}
    local function text() return capture(screens.panel.render(29,12,session),29,12).picture().text end
    local function tap(id)
      for _,b in ipairs(screens.panel.render(29,12,session).buttons) do
        if b.id==id then screens.panel.input({session=session,from=3,id=id,x=b.x,y=b.y});net.flush();return end
      end
      error('missing '..id)
    end
    local function pendingRid()
      for i=#server.sent,1,-1 do
        local msg=SO.proto.decode(server.sent[i].payload)
        if msg and msg.t=='worker.settings' then return msg.rid,msg.body.n end
      end
    end
    assert(text()[4]:find('WORLD',1,true))
    tap('worker-dim:nether')
    local rid,n=pendingRid()
    assert(rid,'no worker.settings sent')
    assert(text()[3]:find('pending',1,true) and text()[4]:find('WORLD',1,true),'confirmed value kept while pending')
    send('ack',{command='worker.settings',n=n,settings={seq=2,dim='minecraft:the_nether',autoToolSwap=false,remoteN=n}},'wrong')
    assert(text()[3]:find('pending',1,true) and text()[4]:find('WORLD',1,true),'an unmatched ack confirms nothing')
    send('ack',{command='worker.settings',n=n,settings={seq=2,dim='minecraft:the_nether',autoToolSwap=false,remoteN=n}},rid)
    assert(not text()[3]:find('pending',1,true) and text()[4]:find('NETHER',1,true),'the matched ack confirms')
    tap('worker-swap:on')
    local rid2,n2=pendingRid()
    assert(rid2~=rid and text()[5]:find('off',1,true))
    hello({seq=3,dim='minecraft:the_nether',autoToolSwap=true,remoteN=n2})
    assert(not text()[3]:find('pending',1,true) and text()[5]:find('on',1,true),'a newer hello confirms')
    send('ack',{command='worker.settings',n=n2,settings={seq=2,dim='minecraft:overworld',autoToolSwap=false,remoteN=n2}},rid2)
    assert(text()[4]:find('NETHER',1,true) and text()[5]:find('on',1,true),'a delayed ack cannot replace the newer hello')
  end)
  test('B-P schematic generator reproduces the panel control fixtures',function()
    local started,pipe=pcall(io.popen,'pwd')
    local root=started and pipe and pipe:read('*l')
    if started and pipe then pipe:close() end
    if not root or root:sub(1,1)~='/' or not os.execute('python3 -V > /dev/null 2>&1') then
      return dofile('tests/skips.lua').record('B-P schematic generator','needs host processes, a POSIX shell and python3')
    end
    local function read(path) local f=assert(io.open(path,'rb')) local text=f:read('*a') f:close() return text end
    local dir=os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '"..dir.."'"))
    assert(os.execute("python3 -I '"..root.."/docs/ui/schematic/screens.py' --fixtures '"..dir.."' > /dev/null"))
    for _,name in ipairs({'panelbuild-M','panelenroll-S','panelenrolloff-S','pairedupdate-M','pairedimpact-P',
        'pairedimpact-M','worker-P','worker-S','workerbusy-S'}) do
      equal(read(dir..'/'..name..'.txt'),read('tests/ui/fixtures/'..name..'.txt'))
    end
    assert(os.execute("rm -r '"..dir.."'"))
  end)
end
