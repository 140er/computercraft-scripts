local R = dofile('tests/ui/render.lua')
local H = dofile('tests/so/harness.lua')
local function screen(job, noDaily)
  local s = {saved=0, released=0, events={}, persisted=H.encode(job)}
  local env = setmetatable({SO={now=function() return 1000000 end,mods={},store={store=function()
    return {value=job,save=function(value) s.saved=s.saved+1 s.persisted=H.encode(value) return true end}
  end}}},{__index=_G})
  env.os = {epoch=function() return 1000000 end}
  env.SO.mods.display={screen=function(_,render,input) s.render,s.input=render,input end}
  if not noDaily then env.SO.mods.daily={today=function() return {logs=96} end} end
  env.SO.mods.lease={status=function() return {} end}
  env.SO.mods.state={canStart=function() return true end,emit=function(kind,value) s.events[#s.events+1]={kind=kind,value=value} end}
  env.SO.mods.cells={releaseOwner=function() s.released=s.released+1 end}
  local mod=assert(loadfile('so-mod-lumber.lua','t',env))()
  mod.tick(1000000)
  for i=1,20 do
    local name,value=debug.getupvalue(mod.tick,i)
    if name=='S' then s.state=value break end
  end
  return s
end
local function job()
  return {dim='minecraft:overworld',spots={a={},b={},c={plantedAt=900000},d={plantedAt=950000}},
    running=true,phase='felling',logs=96,fuel=1210,inv={},nextRound=1380000,
    alert='out of saplings: replanting paused',turtle={id=4},
    area={x1=0,z1=0,x2=4,z2=4},ground=64}
end
local function capture(frame,w,h)
  local out=R.capture(w,h)
  assert(#frame.rows==h)
  for y,row in ipairs(frame.rows) do
    local fg,bg={},{}
    for _,run in ipairs(row.runs) do fg[#fg+1]=string.rep(run[2],run[1]);bg[#bg+1]=string.rep(run[3],run[1]) end
    fg,bg=table.concat(fg),table.concat(bg)
    assert(#fg==w and #bg==w and #row.text<=w)
    out.setCursorPos(1,y);out.blit(row.text..string.rep(' ',w-#row.text),fg,bg)
  end
  for _,b in ipairs(frame.buttons) do
    assert(b.x>=1 and b.y>=1 and b.w>0 and b.h>0 and b.x+b.w-1<=w and b.y+b.h-1<=h)
  end
  return out
end
-- The route A rule for coloured glyphs (docs/ui/SCHEMATIC-SPEC.md, section 3).
local function contrast(out)
  for _,row in ipairs(out.cells) do for _,cell in ipairs(row) do
    local ch,fg,bg=cell[1],cell[2],cell[3]
    local ok=ch==' ' or (bg=='f' or bg=='7') and (('0389d1eba2'):find(fg,1,true) or fg=='c' and ('-|+\183\166'):find(ch,1,true))
      or bg=='c' and (fg=='0' or fg=='3') or not ('f7c'):find(bg,1,true) and fg=='f'
    assert(ok,'contrast '..fg..'/'..bg..' '..ch)
  end end
end
local function ids(frame) local out={} for _,b in ipairs(frame.buttons) do out[b.id]=b end return out end
return function(test,equal)
  test('UI2b lumber draws the route A header, its facts and its alert',function()
    local s=screen(job())
    s.state.recover=false
    local frame=s.render(57,24,{id=1})
    local text=capture(frame,57,24).picture().text
    assert(text[1]:find('^ LUMBER   overview   setup') and text[1]:find('running $'),text[1])
    assert(text[4]:find('ready',1,true) and text[4]:find('2/4',1,true),text[4])
    assert(text[21]:find('! out of saplings: replanting paused',1,true),text[21])
    local found=ids(frame)
    assert(found['tab:setup'] and found.start and found.stop)
  end)
  test('UI2b both tabs render within every size with spec contrast',function()
    local s=screen(job())
    for _,size in ipairs({{26,20},{39,19},{57,24},{15,10},{100,38},{36,10},{29,12},{1,1}}) do
      for _,tab in ipairs({'tab:overview','tab:setup'}) do
        local session={id=1};s.input({id=tab,session=session})
        contrast(capture(s.render(size[1],size[2],session),unpack(size)))
      end
    end
    local session={id=2}
    s.input({id='tab:setup',session=session});local frame=s.render(57,24,session)
    local text=table.concat(capture(frame,57,24).picture().text,'\n')
    for _,part in ipairs({'area       0,0 4,4','ground     64','saplings   -','turtle     -'}) do assert(text:find(part,1,true),part) end
    equal(s.render(57,24,{id=3}).buttons[1].id,'tab:overview')
    s.input({id='lumber-back',session=session});assert(capture(s.render(57,24,session),57,24).picture().text[4]:find('ready',1,true))
    s.input({id='setup',session=session});assert(capture(s.render(57,24,session),57,24).picture().text[3]:find('area',1,true))
    s.input({id='setup-next',session=session});s.input({id='tab:main',session=session})
    assert(capture(s.render(57,24,session),57,24).picture().text[4]:find('ready',1,true))
    equal(s.saved,0)
  end)
  test('UI2b start and stop taps use the text commands once per tap including refusals',function()
    for _,configured in ipairs({false,true}) do
      local a,b=job(),job()
      if not configured then a.area=nil;b.area=nil end
      local typed,tapped=screen(a),screen(b)
      for _,command in ipairs({'start','stop','start','stop'}) do
        local before,typedBefore=tapped.saved,typed.saved
        typed.input({text=command});tapped.input({id=command})
        equal(a,b);equal(typed.saved,tapped.saved)
        equal(tapped.saved-before,typed.saved-typedBefore)
        assert(tapped.saved-before<=1)
      end
      if not configured then equal(a.alert,'configure area and turtle') end
    end
  end)
  test('UI2b navigation and unknown taps leave alerts events and saved jobs unchanged',function()
    for _,id in ipairs({'status','unknown','generic','alerts','area 0 0 1 1 64'}) do
      local j=job();local s=screen(j)
      local before,events,persisted=H.encode(j),H.encode(s.events),s.persisted
      local alert,saves=j.alert,s.saved
      s.input({id=id})
      equal(j.alert,alert)
      equal(H.encode(j),before)
      equal(H.encode(s.events),events)
      equal(s.persisted,persisted)
      equal(s.saved,saves)
    end
  end)
  test('UI2b every text command retains configuration and refusal behavior',function()
    local j=job();j.turtle.id=2;local s=screen(j)
    local function cmd(text,alert)
      s.input({text=text});if alert then equal(j.alert,alert) end
    end
    cmd('area 0 0 1 1 64','stop before configuring')
    cmd('add 2 0 65 0 n','stop before configuring')
    cmd('stop');equal(j.running,false)
    cmd('area 4 3 0 1 60');equal(j.area,{x1=0,z1=1,x2=4,z2=3});equal(j.ground,60);equal(j.spots,{})
    cmd('saplings 1 2 3 front');equal(j.saplings,{x=1,y=2,z=3,side='front'})
    cmd('saplings -1 2 -3 down');equal(j.saplings,{x=-1,y=2,z=-3,side='down'})
    for facing,n in pairs({n=0,e=1,s=2,w=3}) do
      cmd('add 2 0 65 0 '..facing);equal(j.turtle.pose.facing,n)
    end
    equal(s.released,4)
    cmd('start');equal(j.running,true);equal(j.alert,nil)
    cmd('stop');s.state.pending={}
    cmd('area 0 0 1 1 64','stop before configuring');cmd('add 2 0 65 0 n','stop before configuring')
    s.state.pending=nil
    for _,text in ipairs({'area 0 0 128 0 64','area 0.5 0 1 1 64','area 0 0 1 1 30000000'}) do cmd(text,'invalid area') end
    for _,text in ipairs({'saplings 1 2 3 up','saplings x 2 3 front'}) do cmd(text,'invalid sapling chest') end
    for _,text in ipairs({'add -1 0 65 0 n','add 2 0 65 0 up','add 2 x 65 0 n'}) do cmd(text,'invalid turtle') end
    for _,text in ipairs({'','wat','start extra','stop extra','area 0','saplings 0','add 0'}) do cmd(text,'invalid command') end
    for _,missing in ipairs({'area','turtle','ground'}) do
      local bad=job();bad[missing]=nil;local x=screen(bad);x.input({text='start'});equal(bad.alert,'configure area and turtle')
    end
  end)
  test('UI2b gather keeps missing timers and daily counters stale',function()
    local j=job();j.nextRound=nil;local s=screen(j,true);s.render(57,24)
    local A=s.state.screen;local f=A.facts(A.gather())
    equal(f[4],{'logs','-','8'});equal(f[3],{'next grow','-','8'})
    j.nextRound=999000;equal(A.facts(A.gather())[3],{'next grow','0:00','0'})
  end)
end
