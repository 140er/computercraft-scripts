local U = dofile('so-ui.lua')
local function copy(v)
  if type(v) ~= 'table' then return v end
  local out = {} for k,x in pairs(v) do out[k] = copy(x) end return out
end
local function daily(events, now, saved)
  local s = {now=now, saved=copy(saved), saves=0, pages=0}
  local env = setmetatable({}, {__index=_G})
  env.os = {epoch=function() return s.now end}
  env.sleep = function() error('daily slept') end
  env.coroutine = {yield=function() error('daily yielded') end}
  env.SO = {mods={state={history={page=function(q)
    s.pages=s.pages+1
    assert(q.count<=50,'unbounded history request')
    local entries={}
    for _,ev in ipairs(events) do
      if ev.seq>q.from and #entries<q.count then entries[#entries+1]=copy(ev) end
    end
    return {entries=entries}
  end}}},store={copy=copy,store=function(path,valid)
    assert(path=='so-data/daily')
    if s.saved then assert(valid(s.saved)) end
    return {value=copy(s.saved),save=function(v) s.saved=copy(v);s.saves=s.saves+1;return true end}
  end}}
  s.mod=assert(loadfile('so-mod-daily.lua','t',env))()
  s.env=env
  return s
end
local function event(seq,at,kind,count,name)
  return {seq=seq,at=at,kind=kind,data={count=count,name=name,id=2}}
end
local function up(fn,want)
  for i=1,50 do local name,value=debug.getupvalue(fn,i);if name==want then return value end end
  error('missing test access '..want)
end
local function screens(now,today)
  local s={now=now,registered={}}
  local env=setmetatable({}, {__index=_G})
  env.os=setmetatable({epoch=function() return s.now end,getComputerID=function() return 1 end},{__index=os})
  env.SO={mods={},proto=dofile('so-proto.lua'),pair={key=function() return 'key' end},
    store={copy=copy,store=function() return {save=function() return true end} end}}
  if today then env.SO.mods.daily={today=function() return copy(today) end} end
  env.rednet={send=function() end}
  s.display=assert(loadfile('so-mod-display.lua','t',env))()
  env.SO.mods.display=s.display
  env.SO.mods.lease={onReport=function() end}
  s.panel=assert(loadfile('so-mod-panel.lua','t',env))()
  s.shop=assert(loadfile('so-mod-shop.lua','t',env))()
  s.mine=assert(loadfile('so-mod-mine.lua','t',env))()
  s.lumber=assert(loadfile('so-mod-lumber.lua','t',env))()
  s.env=env
  return s
end
local function terminal(now)
  local s={}
  local env=setmetatable({}, {__index=_G})
  env.term={blit=function() end}
  env.fs={getCapacity=function() return 16000000 end,exists=function() return true end,
    list=function() return {'so-mod-capture.lua'} end}
  env.os={clock=function() return now/1000 end,epoch=function() return now end,getComputerID=function() return 1 end,
    startTimer=function() return 1 end,pullEvent=function() return coroutine.yield() end}
  env.rednet={open=function() end,host=function() end}
  env.peripheral={find=function() end,getNames=function() return {} end}
  env.dofile=function(path)
    if path=='so-ui.lua' then return U end
    if path=='so-pair.lua' then return {open=function() end} end
    if path=='so-store.lua' or path=='so-proto.lua' then return {} end
    if path=='so-mod-capture.lua' then
      return {name='capture',handlers={},tick=function() s.view=env.SO.terminal end}
    end
    error(path)
  end
  env.loadfile=function(path) return function() return env.dofile(path) end end
  local co=coroutine.create(assert(loadfile('so-server.lua','t',env)))
  local ok,err=coroutine.resume(co);assert(ok,err)
  s.env=env;s.co=co
  return s
end
return function(test,equal)
  test('UI5a Amsterdam clock covers both 2026 DST boundaries and midnight',function()
    for _,case in ipairs({
      {1774745999000,'2026-03-29','01:59:59'}, {1774746000000,'2026-03-29','03:00:00'},
      {1792889999000,'2026-10-25','02:59:59'}, {1792890000000,'2026-10-25','02:00:00'},
      {1767221999000,'2025-12-31','23:59:59'}, {1767222000000,'2026-01-01','00:00:00'},
      {1782856799000,'2026-06-30','23:59:59'}, {1782856800000,'2026-07-01','00:00:00'},
    }) do
      local c=U.clock(case[1]);equal(c.date,case[2]);equal(c.hms,case[3]);equal(c.hm,case[3]:sub(1,5))
      equal(c.h,tonumber(case[3]:sub(1,2)));equal(c.m,tonumber(case[3]:sub(4,5)));equal(c.s,tonumber(case[3]:sub(7,8)))
    end
  end)
  test('UI5a status shop panel and server log use Amsterdam time',function()
    local now=1774746000000
    local isolated=assert(loadfile('so-ui.lua','t',setmetatable({os={}}, {__index=_G})))()
    equal(isolated.clock(now).hms,'03:00:00')
    local s=screens(now)
    s.display.tick(now)
    local D=up(s.display.tick,'D');equal(D.model.time,'03:00')
    s.panel.tick(now)
    local panel=s.display.screen('panel').render(26,20,{})
    assert(panel.rows[1].text:find('03:00',1,true))
    local S=up(s.shop.tick,'S');S.sampleAt=now
    equal(S.gather().time,'03:00')
    assert(S.render(57,24).rows[1].text:find('stock 03:00',1,true))
    local server=terminal(now)
    server.env.print('first\nsecond')
    local ok,err=coroutine.resume(server.co,'timer',1);assert(ok,err)
    local log=server.view.log
    equal(log[#log-1],'03:00:00 first');equal(log[#log],'03:00:00 second')
    server.env.print(string.rep('x',4100))
    local a,b=log[#log-1],log[#log]
    equal(#a,4096);equal(a:sub(1,9),'03:00:00 ');equal(b:sub(1,9),'03:00:00 ')
    equal(a:sub(10)..b:sub(10),string.rep('x',4100))
  end)
  test('UI5a daily totals window copies midnight and saved cursor survive restart',function()
    local now=1782856799000
    local evs={event(1,now-600001,'mine.ore',120,'minecraft:iron_ore'),
      event(2,now-599999,'mine.ore',3,'minecraft:diamond_ore'),event(3,now,'lumber.logs',96),
      event(4,now,'unrelated',999)}
    local s=daily(evs,now);s.mod.tick(now)
    local v=s.mod.today();equal(v.ore,123);equal(v.oreRecent,3);equal(v.logs,96)
    equal(v.oreByName,{['minecraft:iron_ore']=120,['minecraft:diamond_ore']=3})
    v.oreByName['minecraft:iron_ore']=0;equal(s.mod.today().oreByName['minecraft:iron_ore'],120)
    equal(s.saves,1)
    evs[#evs+1]=event(5,now,'mine.ore',2,'minecraft:iron_ore')
    s.mod.tick(now);equal(s.saves,1);equal(s.mod.today().ore,125)
    local restarted=daily(evs,now,s.saved);restarted.mod.tick(now)
    equal(restarted.mod.today(),s.mod.today())
    restarted.mod.tick(now);equal(restarted.mod.today().ore,125)
    s.now=now+1;s.mod.tick(s.now);equal(s.mod.today().oreRecent,2)
    s.now=now+1000;evs[#evs+1]=event(6,s.now,'mine.ore',7,'minecraft:iron_ore')
    s.mod.tick(s.now);equal(s.saves,2)
    equal(s.mod.today(),{date='2026-07-01',ore=7,oreByName={['minecraft:iron_ore']=7},oreRecent=7,logs=0})
    s.now=s.now+60000;s.mod.tick(s.now);equal(s.saves,3)
    local boot=daily(evs,s.now,s.saved);boot.mod.tick(s.now);equal(boot.mod.today(),s.mod.today())
  end)
  test('UI5a real state history and daily store recover together from disk',function()
    local H=dofile('tests/so/harness.lua')
    local net=H.new()
    net.time=1774746000000
    local machine=net.machine({id=1,capacity=16000000})
    machine.install({'so-ui.lua','so-store.lua','so-log.lua','so-mod-state.lua','so-mod-daily.lua'})
    local env=machine.env
    local function boot()
      env.SO={mods={},store=env.dofile('so-store.lua')}
      env.SO.mods.state=env.dofile('so-mod-state.lua')
      return env.dofile('so-mod-daily.lua')
    end
    local mod=boot()
    assert(env.SO.mods.state.emit('mine.ore',{id=2,name='minecraft:iron_ore',count=5}))
    assert(env.SO.mods.state.emit('lumber.logs',{id=3,count=16}))
    mod.tick(net.time)
    assert(env.fs.exists('so-data/daily'))
    assert(env.SO.mods.state.emit('mine.ore',{id=2,name='minecraft:iron_ore',count=3}))
    mod.tick(net.time)
    local expected=mod.today()
    equal(expected.ore,8);equal(expected.logs,16)
    mod=boot();mod.tick(net.time);equal(mod.today(),expected)
    mod.tick(net.time);equal(mod.today(),expected)
    net.time=net.time+60000;mod.tick(net.time)
    mod=boot();mod.tick(net.time);equal(mod.today(),expected)
  end)
  test('UI5a ten thousand pending events consume only one bounded page without a yield',function()
    local now=1774746000000
    local evs={}
    for i=1,10000 do evs[i]=event(i,now,'mine.ore',1,'minecraft:iron_ore') end
    local s=daily(evs,now)
    local co=coroutine.create(function() s.mod.tick(now) end)
    local ok,err=coroutine.resume(co);assert(ok,err);equal(coroutine.status(co),'dead')
    equal(s.pages,1);equal(s.mod.today().ore,50);equal(s.saved.cursor,50)
    s.mod.tick(now);equal(s.mod.today().ore,100)
  end)
  test('UI5a status mining and lumber show daily counters and stale fallback',function()
    for _,present in ipairs({true,false}) do
      local today=present and {date='2026-03-29',ore=214,oreRecent=12,logs=96,
        oreByName={['minecraft:iron_ore']=120,['minecraft:diamond_ore']=3,['minecraft:gold_ore']=1}}
      local s=screens(1774746000000,today)
      s.display.tick(s.now)
      local m=up(s.display.tick,'D').model
      equal(m.tiles[4].value,present and '214' or '-')
      equal(m.tiles[4].sub,present and '+12 last 10 min' or 'no source')
      equal(m.tiles[4].bg,present and 'b' or 'c')
      equal(m.oreShort,m.tiles[4].sub)
      equal(m.tiles[5].value,present and '96' or '-')
      equal(m.tiles[5].sub,present and 'logs delivered' or 'no source')
      equal(m.tiles[5].bg,present and 'd' or 'c')
      s.mine.tick();s.lumber.tick(s.now)
      local mine=up(s.display.screen('mining').render,'gather')()
      equal(mine.tiles[2][2],present and '214' or '-')
      equal(mine.tiles[2][3],present and 'iron 120 dia 3' or 'no daily source')
      equal(mine.tiles[2][4],present and 'b' or 'c')
      local lumber=up(s.lumber.tick,'S').gather()
      equal(lumber.tiles[2][2],present and '96' or '-')
      equal(lumber.tiles[2][4],present and 'd' or 'c')
    end
  end)
  test('UI5a daily module installs only on the server',function()
    local f=assert(io.open('install.lua'));local text=f:read('*a');f:close()
    local roles=assert(load(text:match('^(local ROLES = .-)\nlocal BASE'):gsub('local ROLES =','return'),'roles','t',{}))()
    for _,role in ipairs({'common','worker','display'}) do
      for _,name in ipairs(roles[role]) do assert(name~='so-mod-daily.lua') end
    end
    local found=0 for _,name in ipairs(roles.server) do if name=='so-mod-daily.lua' then found=found+1 end end
    equal(found,1)
  end)
end
