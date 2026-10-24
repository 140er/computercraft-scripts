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
    assert(text:find('fault 1',1,true));assert(text:find('fault 15',1,true));assert(not text:find('fault 16',1,true))
    s.tap(2,'alert-next');text=table.concat(capture(s.frame(2),26,20).picture().text,'\n')
    assert(text:find('fault 16',1,true));assert(text:find('fault 30',1,true))
    s.tap(2,'alert-prev');assert(capture(s.frame(2),26,20).picture().text[4]:find('fault 1',1,true))
    s.tap(2,'panel-back');s.tap(2,'pair');s.tap(2,'panel-back')
    assert(capture(s.frame(2),26,20).picture().text[3]:find('MINING',1,true))
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
  test('UI3b panel installs only on the server',function()
    local f=assert(io.open('install.lua'));local source=f:read('*a');f:close()
    local roles=assert(load('return '..source:match('local ROLES = (.-)\nlocal BASE'),'roles','t',{}))()
    local function contains(list) for _,name in ipairs(list) do if name=='so-mod-panel.lua' then return true end end return false end
    assert(contains(roles.server));assert(not contains(roles.common));assert(not contains(roles.worker));assert(not contains(roles.display))
  end)
end
