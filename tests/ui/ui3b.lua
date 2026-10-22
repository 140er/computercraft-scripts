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
  env.SO = {mods={},pair={key=function() return string.rep('01',32) end},
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
  local p = assert(loadfile('so-mod-panel.lua','t',env))()
  env.SO.mods.panel=p;p.tick(0)
  s.display,s.panel,s.env=d,p,env
  s.frame=function(id,w,h)
    d.handlers.hello({from=id,body={w=w or 26,h=h or 20}})
    local got;d.handlers['view.get']({from=id},function(_,b) got=b end);return got
  end
  s.tap=function(id,button,text)
    d.handlers.input({from=id,body={id=button,text=text,x=1,y=1}})
  end
  return s
end

local function model()
  local m={time='21:14',alerts={},oreShort='+12 / 10 min',tiles={}}
  for i,t in ipairs({{'TURTLES','3','3 ok, 0 lost','d'},{'LEASES','2','open now','b'},
    {'ALERTS','1','ore chest full','e'},{'ORE TODAY','214','+12 last 10 min','b'},
    {'LOGS TODAY','96','4 trees','d'},{'DISK','13%','2.1 of 16 MB','d'},
    {'DISPLAYS','4','all fresh','d'},{'DROPS','5','1 broken','1'},{'PAIR','','press P on server','9'}}) do
    m.tiles[i]={label=t[1],value=t[2],sub=t[3],bg=t[4]}
  end
  return m
end

local function private(fn, key)
  for i=1,30 do local name,value=debug.getupvalue(fn,i);if name==key then return value end end
  error('missing upvalue '..key)
end

return function(test,equal)
  test('UI3b roleless pockets default to status and glance matches all twenty fixture rows',function()
    local s=setup();equal(s.frame(2).role,'status')
    local d=private(s.display.handlers.hello,'D');d.model=model()
    local diff=R.diff('tests/ui/fixtures/status-P.txt',capture(d.statusFrame(d.sessions[2],26,20,0),26,20))
    assert(#diff==0,table.concat(diff,'\n'))
    equal(s.frame(3,57,24).role,'generic')
  end)
  test('UI3b client input height keeps full Big Tiles pocket navigation',function()
    local s=setup()
    s.display.handlers.hello({from=2,body={w=26,h=19,fullH=20}})
    local f;s.display.handlers['view.get']({from=2},function(_,body) f=body end)
    equal(f.role,'status');equal(#f.rows,20)
    local panel
    for _,button in ipairs(f.buttons) do if button.id=='panel' then panel=button end end
    assert(panel and panel.y==20,'last-row panel navigation must remain reachable')
    s.tap(2,panel.id);equal(s.frame(2).role,'panel')
  end)
  test('UI3b glance pages cover all tiles independently and wrap both ways',function()
    local s=setup();s.frame(2);s.frame(3)
    local seen={}
    for page=1,3 do
      local out=capture(s.frame(2),26,20)
      for _,row in ipairs(out.cells) do for _,cell in ipairs(row) do
        local fg,bg=cell[2],cell[3]
        if cell[1]:byte()>=128 and cell[1]:byte()<=159 and bg=='f' and fg~='0' and fg~='8' then fg,bg=bg,fg end
        assert((bg=='f' or bg=='7' or bg=='c') and (fg=='0' or fg=='8') or
          (bg=='d' or bg=='1' or bg=='e' or bg=='b' or bg=='a' or bg=='9') and fg=='f','glance contrast '..fg..'/'..bg)
      end end
      local text=out.picture().text
      for _,y in ipairs({2,8,14}) do seen[text[y]:match('^%s*(.-)%s*$')]=true end
      assert(text[20]:find('glance '..page..'/3',1,true));s.tap(2,'next')
    end
    for _,label in ipairs({'TURTLES','LEASES','ALERTS','ORE TODAY','LOGS TODAY','DISK','DISPLAYS','DROPS','PAIR'}) do assert(seen[label],label) end
    assert(capture(s.frame(2),26,20).picture().text[20]:find('glance 1/3',1,true))
    s.tap(2,'prev');assert(capture(s.frame(2),26,20).picture().text[20]:find('glance 3/3',1,true))
    assert(capture(s.frame(3),26,20).picture().text[20]:find('glance 1/3',1,true))
  end)
  test('UI3b panel fixture matches and controls dispatch once per tap',function()
    local s=setup();s.now=(21*60+14)*60000;s.frame(2);s.tap(2,'panel');s.tap(2,nil,'iron')
    local diff=R.diff('tests/ui/fixtures/panel-P.txt',capture(s.frame(2),26,20))
    assert(#diff==0,table.concat(diff,'\n'))
    for _,role in ipairs({'mining','lumber'}) do for _,cmd in ipairs({'start','stop'}) do
      local n=#s.calls;s.tap(2,role..':'..cmd);equal(#s.calls,n+1);equal(s.calls[#s.calls],{role,cmd})
    end end
    local n=#s.calls;s.tap(2,'order:16');equal(#s.calls,n+2)
    equal(s.calls[n+1],{'shop','item:minecraft:iron_ingot'})
    equal(s.calls[n+2],{'shop','order:16:minecraft:iron_ingot'})
    s.tap(2,nil,'missing');n=#s.calls;s.tap(2,'order:16');equal(#s.calls,n)
  end)
  test('UI3b panel sessions, alert list, pairing help and monitor pages retain bounds and contrast',function()
    local s=setup();s.frame(2);s.tap(2,'panel');s.tap(2,nil,'iron')
    s.frame(3);s.tap(3,'panel');s.tap(3,nil,'gold')
    assert(capture(s.frame(2),26,20).picture().text[14]:find('iron_',1,true))
    assert(capture(s.frame(3),26,20).picture().text[14]:find('gold_',1,true))
    for _,size in ipairs({{26,20},{57,24},{39,19},{15,10},{29,12}}) do
      local w,h=unpack(size)
      for _,page in ipairs({'panel-back','alerts','pair'}) do
        s.tap(2,page)
        local f=s.frame(2,w,h);equal(f.role,'panel')
        local out=capture(f,w,h)
        for _,row in ipairs(out.cells) do for _,cell in ipairs(row) do
          local fg,bg=cell[2],cell[3]
          assert((bg=='0' and fg=='f') or (bg=='f' or bg=='7' or bg=='c') and (fg=='0' or fg=='8') or
            (bg=='9' or bg=='e' or bg=='a') and fg=='f','contrast '..fg..'/'..bg)
        end end
        if page=='pair' and w>=26 then
          local text=table.concat(out.picture().text,'\n');assert(text:find('Press P on the server',1,true));assert(text:find('new client',1,true))
        end
      end
    end
    s.tap(2,'status');equal(s.frame(2).role,'status')
    s.tap(2,'panel');equal(s.frame(2).role,'panel')
  end)
  test('UI3b missing modules have disabled blocks and no action targets',function()
    local s=setup();local d=private(s.display.handlers.hello,'D')
    d.screens.mining=nil;d.screens.lumber=nil;d.screens.shop=nil;s.panel.tick(0)
    s.frame(2);s.tap(2,'panel');local f=s.frame(2)
    local picture=capture(f,26,20).picture()
    local text=table.concat(picture.text,'\n')
    local _,n=text:gsub('not loaded','');equal(n,3)
    for _,y in ipairs({4,9,16}) do equal(picture.bg[y]:sub(1,8),string.rep('c',8)) end
    for _,b in ipairs(f.buttons) do assert(not b.id:match(':start$') and not b.id:match(':stop$') and not b.id:match('^order:')) end
    s.tap(2,'mining:start');s.tap(2,'order:16');equal(#s.calls,0)
  end)
  test('UI3b real mining and lumber inputs save once per control tap',function()
    local s=setup();local jobs,saves={},{}
    s.env.SO.store.store=function(path)
      if path=='so-data/lumber/job' then
        jobs[path]={dim='minecraft:overworld',spots={},running=false,ground=64,
          area={x1=0,z1=0,x2=4,z2=4},turtle={id=4},inv={}}
      end
      return {value=jobs[path],save=function(value) jobs[path]=value;saves[path]=(saves[path] or 0)+1;return true end}
    end
    s.env.SO.mods.state={canStart=function() return true end}
    jobs["so-data/mine/job"]={home={x=0,y=64,z=0,facing=0},homeSet=true,
      dim="minecraft:overworld",bottom=-58,length=48,mode="thorough",ores={},turtles={},progress={done=0,nextBranch=1}}
    s.env.SO.mods.lease={onReport=function() end}
    local mine=assert(loadfile('so-mod-mine.lua','t',s.env))()
    local lumber=assert(loadfile('so-mod-lumber.lua','t',s.env))()
    s.env.SO.mods.mine=mine;s.env.SO.mods.lumber=lumber
    mine.tick(0);lumber.tick(0);s.panel.tick(0)
    s.frame(2);s.tap(2,'panel')
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
      s.panel.tick(0);s.frame(2);s.tap(2,'panel');s.tap(2,nil,'IRON')
      local n=#sends;s.tap(2,'order:'..amount);equal(#sends,n+1)
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
    local generic=s.frame(2,57,24);local entry
    for _,b in ipairs(generic.buttons) do if b.id=='panel' then entry=b end end
    assert(entry and entry.label=='PANEL','panel role remains reachable with a custom generic screen')
    s.tap(2,entry.id);equal(s.frame(2,57,24).role,'panel');equal(s.saved.roles['2'],'panel')
    local f=s.frame(2,57,24);local targets={}
    for _,b in ipairs(f.buttons) do
      targets[b.id]=b
      if b.id:match('^order:') then assert(b.w>=8,'monitor quantity button minimum width') end
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
    s.panel.tick(0);s.frame(2);s.tap(2,'dismiss');s.tap(2,'panel');s.tap(2,'alerts')
    local text=table.concat(capture(s.frame(2),26,20).picture().text,'\n')
    assert(text:find('fault 1',1,true));assert(text:find('fault 15',1,true));assert(not text:find('fault 16',1,true))
    s.tap(2,'alert-next');text=table.concat(capture(s.frame(2),26,20).picture().text,'\n')
    assert(text:find('fault 16',1,true));assert(text:find('fault 30',1,true))
    s.tap(2,'alert-prev');assert(capture(s.frame(2),26,20).picture().text[5]:find('fault 1',1,true))
    s.tap(2,'panel-back');s.tap(2,'pair');s.tap(2,'panel-back')
    assert(capture(s.frame(2),26,20).picture().text[3]:find('MINING',1,true))
  end)
  test('UI3b partial installs without the kit keep the legacy role picker',function()
    local s=setup();s.env.fs={exists=function() return false end}
    local d=assert(loadfile('so-mod-display.lua','t',s.env))()
    d.handlers.hello({from=8,body={w=26,h=20}})
    local frame;d.handlers['view.get']({from=8},function(_,b) frame=b end)
    equal(frame.role,'generic')
  end)
  test('UI3b custom generic headers stay clear when panel is not loaded',function()
    local s=setup();local d=private(s.display.handlers.hello,'D');d.screens.panel=nil
    s.display.screen('generic',function(w,h)
      local c=U.canvas(w,h);c.header('DROP POINTS','0 points')
      c.hit('new',1,h,8,1);c.hit('status',10,h,8,1);return c.frame()
    end)
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
    touch('generic');touch('panel');equal(d.monitor.role,'panel')
    local n=#s.calls;touch('mining:start');equal(#s.calls,n+1);equal(s.calls[#s.calls],{'mining','start'})
    touch('lumber:stop');equal(#s.calls,n+2);equal(s.calls[#s.calls],{'lumber','stop'})
    touch('pair');touch('panel-back');touch('status');equal(d.monitor.role,'status')
  end)
  test('UI3b panel installs only on the server',function()
    local f=assert(io.open('install.lua'));local source=f:read('*a');f:close()
    local roles=assert(load('return '..source:match('local ROLES = (.-)\nlocal BASE'),'roles','t',{}))()
    local function contains(list) for _,name in ipairs(list) do if name=='so-mod-panel.lua' then return true end end return false end
    assert(contains(roles.server));assert(not contains(roles.common));assert(not contains(roles.worker));assert(not contains(roles.display))
  end)
end
