-- R3: the pocket role's own pages at 26x20. Fixtures come from docs/ui/mockup-gen.py.
local R = dofile('tests/ui/render.lua')
local U = dofile('so-ui.lua')

local function capture(frame, w, h)
  local out = R.capture(w,h)
  assert(#frame.rows == h, 'all rows present')
  for y,row in ipairs(frame.rows) do
    local fg,bg = {},{}
    for _,run in ipairs(row.runs or {}) do fg[#fg+1],bg[#bg+1] = string.rep(run[2],run[1]),string.rep(run[3],run[1]) end
    fg,bg = table.concat(fg),table.concat(bg)
    if not row.runs then
      fg = #row.fg == 1 and string.rep(row.fg,#row.text) or row.fg
      bg = #row.bg == 1 and string.rep(row.bg,#row.text) or row.bg
    end
    out.setCursorPos(1,y)
    out.blit(row.text .. string.rep(' ',#fg-#row.text),fg,bg)
  end
  for _,b in ipairs(frame.buttons) do
    assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h,'button bounds '..b.id)
  end
  return out
end

local function private(fn, key)
  for i=1,40 do local name,value=debug.getupvalue(fn,i);if name==key then return value end end
  error('missing upvalue '..key)
end

-- The fleet model the fixtures show: what D.gather builds for this fleet.
local function fleetModel()
  local alerts = {}
  for i,text in ipairs({'drops: hold fuel','hold saplings chest; fix drop point and start','ore chest full'}) do
    alerts[i] = {key='k'..i,sequence=i,text=text}
  end
  return {time='21:14',alerts=alerts,log={},tiles={
    {label='TURTLES',value='4',bg='e',chips={{'3 ok','d'},{'1 lost','e'}}},
    {label='LEASES',value='2',bg='b',chips={{'2 open','b'}}},
    {label='ALERTS',value='3',bg='e'},
    {label='ORE TODAY',value='214',bg='b'},
    {label='LOGS TODAY',value='96',bg='d'},
    {label='DISK',value='13%',bg='d'},
    {label='DISPLAYS',value='4',bg='d',chips={{'4','d'}}},
    {label='DROPS',value='5',bg='1',chips={{'5','d'},{'1 broken','1'}}},
    {label='PAIR',value='',bg='9'},
  }}
end

-- Job screens drawn like the real 26x20 compact layouts: header state, then LABEL VALUE rows.
local function job(name, state, rows)
  return function(w,h)
    local c=U.canvas(w,h);c.header(name,state.value)
    for i,r in ipairs(rows) do c.fill(1,i+2,w,1,r[3]);c.put(2,i+2,r[1]..' '..r[2]) end
    return c.frame()
  end
end

local function setup()
  local s = {now=0,saved={roles={}},calls={},sends={},pending=nil}
  local env = setmetatable({}, {__index=_G})
  env.os = setmetatable({epoch=function() return s.now end,getComputerID=function() return 1 end}, {__index=os})
  env.SO = {now=function() return s.now end,mods={},
    pair={key=function(id) return id ~= 9 and string.rep('01',32) or nil end,pending=function() return s.pending end},
    store={store=function() return {value=s.saved,save=function(v) s.saved=v return true end} end}}
  env.SO.pairCode = function(id)
    s.calls[#s.calls+1] = {'pair',id}
    s.pending = '482915'
    return {code='482915',expires=s.now+292000}
  end
  env.SO.proto = assert(loadfile('so-proto.lua','t',env))()
  env.rednet = {send=function(id,body,protocol) s.sends[#s.sends+1]={id=id,body=body,protocol=protocol} end,broadcast=function() end}
  local d = assert(loadfile('so-mod-display.lua','t',env))()
  env.SO.mods.display = d
  s.mining, s.lumber = {value='running'}, {value='stopped'}
  d.screen('mining',job('MINING',s.mining,{{'BUSY','2/3','d'},{'ORE TODAY','214','b'},{'DEPTH','-58','d'},
    {'LANE','0','d'},{'MIN FUEL','640','d'},{'BRANCHES','3/8','b'}}),
    function(e) s.calls[#s.calls+1]={'mining',e.id};s.mining.value=e.id=='start' and 'running' or 'stopped' end)
  d.screen('lumber',job('LUMBER',s.lumber,{{'TREES READY','2','d'},{'LOGS TODAY','96','d'},{'SAPLINGS','0','e'},
    {'TURTLE','4','d'},{'FUEL','1210','d'},{'NEXT GROW','6:20','b'}}),
    function(e) s.calls[#s.calls+1]={'lumber',e.id};s.lumber.value=e.id=='start' and 'running' or 'stopped' end)
  local shop = assert(loadfile('so-mod-shop.lua','t',env))()
  env.SO.mods.shop = shop;shop.tick(0)
  shop.listen.roomsorter_stock(9,{totals={['minecraft:iron_ingot']=1240,['minecraft:iron_ore']=312,
    ['minecraft:raw_iron']=48,['minecraft:iron_block']=27,['minecraft:iron_nugget']=5,['minecraft:iron_door']=3,
    ['minecraft:iron_pickaxe']=1,['minecraft:iron_bars']=0,['minecraft:gold_ingot']=4000}})
  local p = assert(loadfile('so-mod-panel.lua','t',env))()
  env.SO.mods.panel = p;p.tick(0)
  s.D, s.display, s.panel, s.env, s.shop = private(d.handlers.hello,'D'), d, p, env, shop
  s.D.model = fleetModel()
  s.session = {id=2,keyboard=true}
  s.render = function(h) return d.screen('pocket').render(26,h or 20,s.session) end
  s.tap = function(id) d.screen('pocket').input({from=2,id=id,x=1,y=1,session=s.session}) end
  s.type = function(text) d.screen('pocket').input({from=2,text=text,x=1,y=1,session=s.session}) end
  s.match = function(name, h)
    local diff = R.diff(name,capture(s.render(h),26,h or 20))
    assert(#diff==0,name..'\n'..table.concat(diff,'\n'))
  end
  return s
end

local function find(frame, id)
  for _,b in ipairs(frame.buttons) do if b.id==id then return b end end
end

-- Text on d,1,e,b,a,9 and 0 is f; on f,7,c it is 0 or 8. Inverted big-digit cells count either way.
local function contrast(out)
  local function ok(fg, bg)
    return (bg=='0' and fg=='f') or (bg=='f' or bg=='7' or bg=='c') and (fg=='0' or fg=='8') or
      (bg=='d' or bg=='1' or bg=='e' or bg=='b' or bg=='a' or bg=='9') and fg=='f'
  end
  for _,row in ipairs(out.cells) do for _,cell in ipairs(row) do
    local fg,bg = cell[2],cell[3]
    local sextant = cell[1]:byte()>=128 and cell[1]:byte()<=159
    assert(ok(fg,bg) or sextant and ok(bg,fg),'contrast '..fg..'/'..bg)
  end end
end

return function(test, equal)
  test('R3 every pocket page matches its fixture at 26x20', function()
    local s = setup()
    s.match('tests/ui/fixtures/pocket-fleet-P.txt')
    s.tap('alerts');s.match('tests/ui/fixtures/pocket-alerts-P.txt')
    s.tap('tab:jobs');s.match('tests/ui/fixtures/pocket-jobs-P.txt')
    s.tap('tab:shop');s.type('iron');s.tap('order:16:minecraft:iron_ingot');s.match('tests/ui/fixtures/pocket-shop-P.txt')
    s.tap('tab:pair');s.match('tests/ui/fixtures/pocket-pair-P.txt')
    s.tap('pair-code');s.match('tests/ui/fixtures/pocket-code-P.txt')
    local status = s.D.statusFrame({alertSeen={k1=true,k2=true,k3=true}},26,20,0,false)
    local diff = R.diff('tests/ui/fixtures/status-P.txt',capture(status,26,20))
    assert(#diff==0,table.concat(diff,'\n'))
  end)

  test('R3 pocket routing: tabs change pages, a takeover comes first, the role never changes', function()
    local s = setup()
    s.D.model = nil
    s.env.SO.mods.state = {get=function() return {} end,view=function() return {values={['mine.alert']={text='ore chest full'}}} end}
    s.display.handlers.hello({from=2,body={w=26,h=19,fullH=20,keyboard=true}})
    local function frame() local f;s.display.handlers['view.get']({from=2},function(_,b) f=b end);return f end
    local f = frame();equal(f.role,'pocket')
    assert(capture(f,26,20).picture().text[4]:find('ALERT',1,true),'new alert takes over first')
    s.display.handlers.input({from=2,body={id='dismiss',x=1,y=1}})
    f = frame();equal(f.role,'pocket')
    for _,tab in ipairs({'fleet','jobs','shop','pair'}) do
      local b = assert(find(f,'tab:'..tab),'tab '..tab);equal(b.y,1);equal(b.h,1)
    end
    s.display.handlers.input({from=2,body={id='tab:jobs',x=9,y=1}})
    f = frame();assert(find(f,'mining:start') and find(f,'lumber:stop'),'jobs page')
    for _,b in ipairs(f.buttons) do
      assert(b.id:match('^tab:') or b.id:match('^mining:') or b.id:match('^lumber:'),'in-role id '..b.id)
    end
    for _,id in ipairs({'status','panel','glance','shop','items','map','generic','jobs'}) do
      s.display.handlers.input({from=2,body={id=id,x=1,y=1}})
    end
    equal(frame().role,'pocket');equal(s.saved.roles,{})
    assert(s.display.assign(2,'status'))
    equal(frame().role,'status')
  end)

  test('R3 one tap is one action: START, STOP and each order send exactly once', function()
    local s = setup()
    s.tap('mining:start');equal(#s.calls,0)
    s.tap('tab:jobs')
    for _,role in ipairs({'mining','lumber'}) do for _,cmd in ipairs({'start','stop'}) do
      local n=#s.calls;s.tap(role..':'..cmd);equal(#s.calls,n+1);equal(s.calls[#s.calls],{role,cmd})
    end end
    s.tap('lumber:start')
    assert(capture(s.render(),26,20).picture().text[12]:find('running',1,true),'state chip follows the job')
    s.lumber.value='hold saplings chest; fix drop point and start';s.panel.tick(0)
    local row=capture(s.render(),26,20).picture()
    assert(row.text[12]:find('LUMBER',1,true) and row.text[12]:find('hold ',1,true),row.text[12])
    assert(row.bg[12]:find('111111',1,true),'hold is amber')
    s.lumber.value='out of range';s.panel.tick(0)
    assert(capture(s.render(),26,20).picture().text[12]:find('out of range',1,true),'a state that fits stays whole')
    s.tap('order:16:minecraft:iron_ingot');equal(#s.sends,0)
    s.tap('tab:shop');s.type('iron')
    for _,amount in ipairs({1,16,64}) do
      assert(find(s.render(),'order:'..amount..':minecraft:iron_ingot'),'chip names its item')
      local n=#s.sends;s.tap('order:'..amount..':minecraft:iron_ingot');equal(#s.sends,n+1)
      local sent=s.sends[#s.sends]
      equal({sent.id,sent.protocol,sent.body.cmd,sent.body.text,sent.body.n},{9,'roomsorter','order','minecraft:iron_ingot',amount})
    end
    s.tap('pick:minecraft:raw_iron')
    local f = s.render();local chip = find(f,'order:64:minecraft:raw_iron')
    equal(chip.y,find(f,'pick:minecraft:raw_iron').y+1)
    s.tap('order:64:minecraft:raw_iron');equal(s.sends[#s.sends].body.text,'minecraft:raw_iron')
    assert(capture(s.render(),26,20).picture().text[19]:find('sent 64 RAW IRON',1,true))
    local n=#s.sends;s.render();s.panel.tick(0);s.render();equal(#s.sends,n)
    s.tap('clear');assert(find(s.render(),'pick:minecraft:gold_ingot'),'clear shows every item')
    s.type('missing');f=s.render()
    for _,b in ipairs(f.buttons) do assert(not b.id:match('^order:')) end
    s.tap('order:1:minecraft:iron_ingot');equal(#s.sends,n)
    s.type('raw');s.tap('order:16:minecraft:iron_ingot');equal(#s.sends,n,'a chip for an item outside the search')
    s.tap('tab:pair');n=#s.calls;s.tap('pair-code');equal(#s.calls,n+1);equal(s.calls[#s.calls],{'pair',2})
    s.tap('tab:jobs');n=#s.calls;s.tap('pair-code');equal(#s.calls,n)
  end)

  test('R3 every pocket control is one row, inside the screen, with contrast, at 26x20 and 26x19', function()
    for _,h in ipairs({20,19}) do
      local s = setup()
      for _,page in ipairs({'fleet','alerts','jobs','shop','pair'}) do
        if page=='alerts' then s.tap('tab:fleet') end
        s.tap(page=='alerts' and 'alerts' or 'tab:'..page)
        if page=='shop' then s.type('iron') end
        local f = s.render(h);local out = capture(f,26,h)
        contrast(out)
        local seen = {}
        for _,b in ipairs(f.buttons) do
          equal(b.h,1,page..' '..b.id..' height')
          for y=b.y,b.y+b.h-1 do for x=b.x,b.x+b.w-1 do
            assert(not seen[y..','..x],page..' overlapping '..b.id);seen[y..','..x]=true
          end end
        end
      end
    end
  end)

  test('R3 missing job screens draw grey controls without targets; missing shop says so', function()
    local s = setup()
    s.D.screens.mining,s.D.screens.lumber,s.D.screens.shop = nil,nil,nil
    s.panel.tick(0);s.tap('tab:jobs')
    local f = s.render();local text = table.concat(capture(f,26,20).picture().text,'\n')
    local _,n = text:gsub('not loaded','');equal(n,2)
    for _,b in ipairs(f.buttons) do assert(not b.id:match(':st')) end
    s.tap('mining:start');equal(#s.calls,0)
    s.tap('tab:shop');f = s.render()
    assert(table.concat(capture(f,26,20).picture().text,'\n'):find('shop not loaded',1,true))
    for _,b in ipairs(f.buttons) do assert(not b.id:match('^order:')) end
  end)

  test('R3 jobs keep the last facts while a job screen shows its SETUP rows', function()
    local s = setup()
    s.tap('tab:jobs');assert(capture(s.render(),26,20).picture().text[13]:find('TREES READY',1,true))
    s.display.screen('lumber',function(w,h)
      local c=U.canvas(w,h);c.header('LUMBER','stopped')
      for i,line in ipairs({'AREA 1,2 to 3,4','GROUND 64','SAPLINGS -'}) do c.put(2,i+2,line,'0','f') end
      return c.frame()
    end,function() end)
    s.panel.tick(0)
    local text=capture(s.render(),26,20).picture().text
    assert(text[13]:find('TREES READY',1,true) and text[14]:find('SAPLINGS',1,true),text[13])
    assert(not table.concat(text,'\n'):find('AREA',1,true))
  end)

  test('R3 alerts page wraps, pages and returns to FLEET', function()
    local s = setup()
    for i=4,12 do s.D.model.alerts[i]={key='k'..i,sequence=i,text='fault number '..i..' needs a look at drop point '..i} end
    s.tap('alerts');local f=s.render();local text=capture(f,26,20).picture().text
    assert(text[5]:find('fault number 12',1,true));assert(find(f,'alert-next'))
    local pages=tonumber(text[20]:match('1/(%d+)'))
    for _=1,pages do s.tap('alert-next') end
    assert(capture(s.render(),26,20).picture().text[5]:find('fault number 12',1,true),'paging wraps')
    s.tap('alert-prev');assert(capture(s.render(),26,20).picture().text[20]:find(pages..'/'..pages,1,true))
    s.tap('tab:fleet');assert(find(s.render(),'alerts'))
  end)

  test('R3 status gather builds the fleet chips', function()
    local s = setup()
    local now = 50000
    s.now = now
    s.env.SO.mods.state = {get=function() return {[11]={role='worker'},[12]={role='worker'},[13]={role='worker'},[14]={role='worker'}} end,
      view=function() return {values={['mine.alert']={text='ore chest full'}}} end}
    s.env.SO.mods.lease = {status=function(id) return {lost=id==14,open=id<13} end}
    s.env.SO.mods.drops = {list=function() return {{},{},{},{},{broken=true}} end}
    s.env.SO.mods.daily = {today=function() return {ore=214,oreRecent=12,logs=96} end}
    s.env.fs = {getCapacity=function() return 16000000 end,getFreeSpace=function() return 13900000 end,exists=fs and fs.exists}
    for id=2,5 do s.display.handlers.hello({from=id,body={w=26,h=20}});s.D.sessions[id].sent=id==5 and 0 or now end
    local model = s.D.gather();local chips = {}
    for i=1,8 do chips[i] = model.tiles[i].chips or {{model.tiles[i].value,model.tiles[i].bg}} end
    equal(chips,{{{'3 ok','d'},{'1 lost','e'}},{{'2 open','b'}},{{'1','e'}},{{'214','b'}},{{'96','d'}},{{'13%','d'}},
      {{'4','d'},{'1 stale','1'}},{{'5','d'},{'1 broken','1'}}})
    s.env.SO.mods.state.get=function() return {} end
    equal(s.D.gather().tiles[1].chips,{{'0','c'}})
  end)

  test('R3 jobs page reads the real mining and lumber screens', function()
    local s = setup();local jobs={}
    s.env.SO.store.store=function(path)
      if path=='so-data/lumber/job' then
        jobs[path]=jobs[path] or {dim='minecraft:overworld',spots={},running=false,ground=64,
          area={x1=0,z1=0,x2=4,z2=4},turtle={id=4},inv={}}
      end
      return {value=jobs[path],save=function(value) jobs[path]=value;return true end}
    end
    s.env.SO.mods.state={canStart=function() return true end}
    jobs['so-data/mine/job']={home={x=0,y=64,z=0,facing=0},homeSet=true,dim='minecraft:overworld',bottom=-58,
      length=48,mode='thorough',ores={},turtles={},progress={done=3,nextBranch=8}}
    s.env.SO.mods.lease={onReport=function() end}
    local mine=assert(loadfile('so-mod-mine.lua','t',s.env))()
    local lumber=assert(loadfile('so-mod-lumber.lua','t',s.env))()
    s.env.SO.mods.mine,s.env.SO.mods.lumber=mine,lumber
    mine.tick(0);lumber.tick(0);s.panel.tick(0)
    s.tap('tab:jobs')
    local text=capture(s.render(),26,20).picture().text
    assert(text[3]:find('MINING',1,true) and text[3]:find('stopped',1,true))
    assert(text[5]:find('DEPTH',1,true) and text[5]:find('-58',1,true))
    assert(text[6]:find('BRANCHES',1,true) and text[6]:find('3/8',1,true))
    assert(text[13]:find('TREES READY',1,true))
    s.tap('mining:start')
    assert(capture(s.render(),26,20).picture().text[3]:find('running',1,true))
    equal(jobs['so-data/mine/job'].running,true)
  end)

  test('R3 shop matches sort by stock and an exact item id wins the order', function()
    local s = setup()
    s.shop.listen.roomsorter_stock(9,{totals={['minecraft:stone']=10,['minecraft:stone_bricks']=900,['minecraft:cobblestone']=5}})
    local names={}
    for _,item in ipairs(s.shop.matches('stone',2)) do names[#names+1]=item.name..'='..item.count..'='..item.label end
    equal(names,{'minecraft:stone_bricks=900=STONE BRICKS','minecraft:stone=10=STONE'})
    equal(s.shop.order('minecraft:stone',16),'minecraft:stone');equal(s.sends[#s.sends].body.text,'minecraft:stone')
    equal(s.shop.order('stone',1),'minecraft:stone_bricks')
    equal(s.shop.order('nothing',1),nil);equal(s.shop.order('stone',5),nil)
  end)
end
