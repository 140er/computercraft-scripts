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
    s.display.handlers.hello({from=2,body={w=26,h=19,fullH=20,keyboard=true}})
    s.env.SO.mods.state = {get=function() return {} end,view=function() return {values={['mine.alert']={text='ore chest full'}}} end}
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
      {{'4','d'},{'#5 stale','1'}},{{'5','d'},{'1 broken','1'}}})
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
    equal(s.shop.order('nothing',1),nil);equal(s.shop.order('stone',65),nil)
  end)

  -- UB-8: the shop's reply reaches the pocket that ordered.
  test('R3 pocket orders show the reply: not in storage fails, Getting then Delivered, silence times out', function()
    local s = setup()
    s.tap('tab:shop');s.type('iron')
    local function rows() return capture(s.render(),26,20).picture() end
    local function order(amount, reply)
      s.tap('order:'..amount..':minecraft:iron_ingot')
      local rid = s.sends[#s.sends].body.rid
      if reply then s.shop.listen.roomsorter(9,{rid=rid,reply}) end
      return rid
    end
    order(16)
    assert(rows().text[19]:find('16 IRON INGOT sent',1,true),rows().text[19])
    s.shop.listen.roomsorter(9,{rid=s.sends[#s.sends].body.rid,'Not in storage: iron ingot'})
    local p = rows()
    assert(p.text[19]:find('16 IRON INGOT failed',1,true),p.text[19]);equal(p.fg[19]:sub(2,2),'e')
    assert(p.text[20]:find('Not in storage: iron ing',1,true),p.text[20]);equal(p.fg[20]:sub(2,2),'8')
    local rid = order(64,'Getting 64 Iron Ingot')
    assert(rows().text[19]:find('64 IRON INGOT sent',1,true));assert(rows().text[20]:find('Getting 64',1,true))
    s.shop.listen.roomsorter(9,{rid=rid,'Delivered 64 Iron Ingot'})
    p = rows();assert(p.text[19]:find('64 IRON INGOT delivered',1,true),p.text[19]);equal(p.fg[19]:sub(2,2),'d')
    -- A reply from another computer or for another order changes nothing.
    order(1);rid = s.sends[#s.sends].body.rid
    s.shop.listen.roomsorter(7,{rid=rid,'Not in storage'});s.shop.listen.roomsorter(9,{rid=rid+50,'Not in storage'})
    assert(rows().text[19]:find('1 IRON INGOT sent',1,true),rows().text[19])
    s.now = 120000;s.shop.tick(s.now)
    p = rows();assert(p.text[19]:find('1 IRON INGOT failed',1,true),p.text[19]);assert(p.text[20]:find('timed out',1,true))
  end)

  -- UB-26: STACK and ALL use shop.order's count rules.
  test('R3 pocket STACK sends the stack size and ALL the stock; ALL is grey at zero stock', function()
    local s = setup()
    s.shop.listen.roomsorter_stock(9,{totals={['minecraft:iron_ingot']=1240,['minecraft:raw_iron']=48,
      ['minecraft:ender_pearl']=40,['minecraft:iron_bars']=0},stacks={['minecraft:raw_iron']=64}})
    s.tap('tab:shop');s.type('')
    local function last() local b = s.sends[#s.sends].body;return b.cmd..' '..b.text..' '..b.n end
    s.tap('pick:minecraft:raw_iron')
    local f = s.render();local pick = find(f,'pick:minecraft:raw_iron')
    equal(find(f,'order:stack:minecraft:raw_iron').y,pick.y+2);equal(find(f,'order:all:minecraft:raw_iron').y,pick.y+2)
    s.tap('order:all:minecraft:raw_iron');equal(last(),'order minecraft:raw_iron 48')
    assert(capture(s.render(),26,20).picture().text[19]:find('48 RAW IRON sent',1,true))
    s.tap('order:stack:minecraft:raw_iron');equal(last(),'order minecraft:raw_iron 64')
    s.tap('pick:minecraft:ender_pearl');s.tap('order:stack:minecraft:ender_pearl');equal(last(),'order minecraft:ender_pearl 16')
    assert(capture(s.render(),26,20).picture().text[19]:find('16 ENDER PEARL sent',1,true))
    local n = #s.sends
    s.tap('pick:minecraft:iron_bars');f = s.render()
    assert(not find(f,'order:stack:minecraft:iron_bars') and not find(f,'order:all:minecraft:iron_bars'),'no order chips at 0')
    s.tap('order:all:minecraft:iron_bars');s.tap('order:stack:minecraft:iron_bars');equal(#s.sends,n)
    assert(capture(s.render(),26,20).picture().text[19]:find('not sent',1,true))
    equal(s.shop.order('minecraft:raw_iron','all'),'minecraft:raw_iron');equal(select(2,s.shop.order('raw','stack')),64)
    equal({s.shop.order('nothing','all')},{nil,'no match'});equal({s.shop.order('raw',65)},{nil,'bad count'})
  end)

  -- An order is never larger than one stack: ALL sends the stock up to the stack size.
  test('R3 pocket ALL sends at most one stack: 1240 in stock sends 64, 10 in stock sends 10', function()
    local s = setup()
    s.shop.listen.roomsorter_stock(9,{totals={['minecraft:iron_ingot']=1240,['minecraft:gold_ingot']=10}})
    s.tap('tab:shop');s.type('ingot')
    s.tap('order:all:minecraft:iron_ingot');equal(s.sends[#s.sends].body.n,64)
    assert(capture(s.render(),26,20).picture().text[19]:find('64 IRON INGOT sent',1,true))
    s.tap('pick:minecraft:gold_ingot');s.tap('order:all:minecraft:gold_ingot');equal(s.sends[#s.sends].body.n,10)
    equal({s.shop.order('minecraft:iron_ingot','all')},{'minecraft:iron_ingot',64})
    equal({s.shop.order('gold','all')},{'minecraft:gold_ingot',10})
    for _,sent in ipairs(s.sends) do assert(sent.body.cmd ~= 'order' or sent.body.n <= 64,'over one stack') end
  end)

  -- A long item name never pushes the count or the status off the 26-column pocket.
  test('R3 pocket order line cuts a long label and keeps the count and status', function()
    local s = setup()
    s.shop.listen.roomsorter_stock(9,{totals={['minecraft:polished_deepslate_stairs']=120,['minecraft:oak_stairs']=40}})
    s.tap('tab:shop');s.type('stairs')
    s.tap('order:1:minecraft:polished_deepslate_stairs')
    equal(capture(s.render(),26,20).picture().text[19],' 1 POLISHED DEEPS... sent ')
    s.shop.listen.roomsorter(9,{rid=s.sends[#s.sends].body.rid,'Delivered 1 Polished Deepslate Stairs'})
    -- The scene has an alert, so FLEET carries the dot.
    s.D.model.flags = {{text='ore chest full'}}
    s.match('tests/ui/fixtures/pocket-shoplong-P.txt')
  end)

  -- UB-30: the panel reads only the job header; the rows below it are the job's own.
  test('R3 the panel probe reads only the header row of each job screen', function()
    local s = setup()
    local P, reads = private(s.panel.tick,'P'), {}
    for _,role in ipairs({'mining','lumber'}) do
      local screen = s.display.screen(role)
      s.display.screen(role,function(w,h,session)
        local frame = screen.render(w,h,session)
        local rows = frame.rows
        frame.rows = setmetatable({rows[1],rows[2]},{__index=function(_,y) reads[#reads+1] = role..y;return rows[y] end})
        return frame
      end,screen.input)
    end
    s.panel.tick(0)
    equal(reads,{});equal(P.facts,nil)
    equal(P.states.mining,'running');equal(P.states.lumber,'stopped')
    s.tap('tab:jobs');s.tap('lumber:start');equal(P.states.lumber,'running')
  end)
end
