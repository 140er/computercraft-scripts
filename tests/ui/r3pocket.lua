-- R3: pocket routing, missing modules and the real job and shop modules behind the pocket pages.
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

return function(test, equal)
  -- The route A pages, their fixtures, one tap per action and the alert list are in tests/ui/s4.lua.
  test('R3 pocket routing: tabs change pages, a takeover comes first, the role never changes', function()
    local s = setup()
    s.D.model = nil
    s.env.SO.mods.state = {get=function() return {} end,view=function() return {values={['mine.alert']={text='ore chest full'}}} end}
    s.display.handlers.hello({from=2,body={w=26,h=19,fullH=20,keyboard=true}})
    local function frame() local f;s.display.handlers['view.get']({from=2},function(_,b) f=b end);return f end
    local f = frame();equal(f.role,'pocket')
    assert(find(f,'dismiss') and capture(f,26,20).picture().text[3]:find('ORE CHEST FULL',1,true),'new alert takes over first')
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
    -- A job that passes the start checks (#213): home, ore and fuel chests, and paired turtle #2 with fuel.
    local at={dim='minecraft:overworld',x=0,y=64,z=0,facing=0}
    jobs['so-data/mine/job']={home={x=0,y=64,z=0,facing=0},homeSet=true,dim='minecraft:overworld',bottom=-58,
      length=48,mode='thorough',ores={},turtles={['2']={pose=at,anchor=at,state='parked',fuel=900,inv={}}},
      progress={done=3,nextBranch=8}}
    s.env.SO.mods.drops={list=function() return {{id='ore',dim=0,x=1,y=64,z=0,side='front',kind='ore'},
      {id='fuel',dim=0,x=2,y=64,z=0,side='front',kind='fuel'}} end}
    s.env.SO.mods.lease={onReport=function() end,status=function() return {} end}
    local mine=assert(loadfile('so-mod-mine.lua','t',s.env))()
    local lumber=assert(loadfile('so-mod-lumber.lua','t',s.env))()
    s.env.SO.mods.mine,s.env.SO.mods.lumber=mine,lumber
    mine.tick(0);lumber.tick(0);s.panel.tick(0)
    s.tap('tab:jobs')
    local text=capture(s.render(),26,20).picture().text
    assert(text[3]:find('MINING',1,true) and text[3]:find('stopped',1,true),text[3])
    assert(text[12]:find('LUMBER',1,true),text[12])
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
