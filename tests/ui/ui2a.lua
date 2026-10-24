local R = dofile('tests/ui/render.lua')
local function setup()
  local job = {home={x=0,y=64,z=0,facing=0},bottom=-16,length=48,mode='thorough',ores={},
    turtles={},progress={done=3,nextBranch=8},dim='minecraft:overworld',running=false}
  local render,input,saves
  saves=0
  local env=setmetatable({os=setmetatable({epoch=function() return 0 end},{__index=os}),SO={pair={key=function() return "paired" end},now=function() return 0 end,mods={drops={list=function() return {{id="ready",dim=0,x=100000,y=0,z=0,kind="any"}} end},state={canStart=function() return true end},lease={onReport=function() end,status=function() return {} end,
    send=function() return 'park' end},cells={reserve=function() return true end,releaseOwner=function() end},
    display={screen=function(_,r,i) render,input=r,i end}},store={store=function()
      return {value=job,save=function() saves=saves+1 return true end} end}}},{__index=_G})
  job.turtles["9"]={pose={x=10,y=64,z=0,facing=0},fuel=4000,state="stopped"}
  local mine=assert(loadfile('so-mod-mine.lua','t',env))();mine.tick()
  local V
  for i=1,30 do local name,value=debug.getupvalue(render,i)
    if name=='V' then V=value end
  end
  return {job=job,render=render,input=input,V=V,saves=function() return saves end}
end
local function capture(frame,w,h)
  local out=R.capture(w,h)
  assert(#frame.rows==h)
  for y,row in ipairs(frame.rows) do
    local fg,bg={},{}
    for _,r in ipairs(row.runs) do fg[#fg+1]=string.rep(r[2],r[1]);bg[#bg+1]=string.rep(r[3],r[1]) end
    fg,bg=table.concat(fg),table.concat(bg);assert(#fg==w)
    out.setCursorPos(1,y);out.blit(row.text..string.rep(' ',w-#row.text),fg,bg)
  end
  for _,b in ipairs(frame.buttons) do assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+b.h-1<=h) end
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
  test('UI2a mining draws the route A header with its two tabs',function()
    local s=setup();assert(s.V,'route A layout missing')
    local frame=s.render(57,24,{id=1})
    local text=capture(frame,57,24).picture().text[1]
    assert(text:find('^ MINING   overview   setup') and text:find('stopped $'),text)
    local found=ids(frame)
    assert(found['tab:overview'] and found['tab:setup'] and found.start and found.stop)
  end)
  test('UI2a setup stays on the display that pressed its drawn tab',function()
    local s=setup();local a,b={id=1},{id=2}
    local main=s.render(57,24,b)
    local function press(session,id)
      local button=ids(s.render(57,24,session))[id]
      assert(button,'missing mining button '..id)
      s.input({id=id,x=button.x,y=button.y,session=session})
    end
    press(a,'tab:setup')
    assert(ids(s.render(57,24,a))['set-bottom-'],'setup page')
    equal(s.render(57,24,b),main)
    equal(s.render(57,24),main)
    press(a,'tab:overview');equal(s.render(57,24,a),main)
    -- The Big Tiles ids still switch pages for clients that send them.
    s.input({id='setup',session=a});assert(ids(s.render(57,24,a))['set-bottom-'],'old setup id')
    s.input({id='mine-back',session=a});equal(s.render(57,24,a),main)
    equal(s.saves(),0)
  end)
  test('UI2a text commands retain job effects on both pages',function()
    for _,page in ipairs({'main','setup'}) do
      local s=setup();if page=='setup' then s.input({id='setup'}) end
      for _,case in ipairs({{'home 1 2 3 e',function() equal(s.job.home,{x=1,y=2,z=3,facing=1}) end},
        {'bottom -32',function() equal(s.job.bottom,-32) end},{'length 100',function() equal(s.job.length,100) end},
        {'mode fast',function() equal(s.job.mode,'fast') end},{'ores diamond,iron',function() equal(s.job.ores,{'diamond','iron'}) end},
        {'add 2 1 2 3 n',function() assert(s.job.turtles['2'].recover) end},
        {'remove 2',function() equal(s.job.turtles['2'],nil) end},
        {'start',function() equal(s.job.running,true) end},{'stop',function() equal(s.job.running,false) end}}) do
        s.input({text=case[1]});case[2]()
      end
    end
  end)
  test('UI2a buttons share start and stop commands and save once per tap',function()
    for _,cmd in ipairs({'start','stop'}) do
      local a,b=setup(),setup();a.job.running=true;b.job.running=true
      local before=b.saves();a.input({text=cmd});b.input({id=cmd})
      equal(a.job,b.job);equal(b.saves(),before+1)
    end
  end)
  test('UI2a both tabs keep bounds and contrast at every size',function()
    local s=setup();s.input({text='invalid'})
    for _,size in ipairs({{26,20},{39,19},{57,24},{15,10},{100,38},{36,10},{29,12},{1,1}}) do
      for _,tab in ipairs({'tab:overview','tab:setup'}) do
        local session={id=1};s.input({id=tab,session=session})
        local w,h=unpack(size);local f=s.render(w,h,session);local out=capture(f,w,h)
        for _,b in ipairs(f.buttons) do assert(b.id~='status','mining links to status') end
        if w>=24 and h>=10 then assert(ids(f)[tab] or tab=='tab:overview' and ids(f)['tab:main'],tab..' at '..w..'x'..h) end
        if w>=24 and h>=10 and tab=='tab:setup' then assert(ids(f)['set-length+'],'steppers at '..w..'x'..h) end
        contrast(out)
      end
    end
  end)
  test('UI2a gather uses mining facts and leaves daily ore stale',function()
    local s=setup();s.job.turtles={['2']={state='mining',pose={x=12,y=60,z=-9},fuel=812,ores=14},
      ['3']={state='hold',pose={x=0,y=61,z=-1},fuel=640,laneWait={},error='ore chest full'},
      ['4']={state='range',pose={x=0,y=0,z=0}}}
    local m=s.V.gather();local f=s.V.facts(m)
    equal(f[1],{'busy','1/3','0'});equal(f[5],{'ore','-','8'});equal(f[6],{'fuel','640','0'});equal(m.fuel.id,3)
    equal(m.turtles[2].state,'wait lane');equal(m.turtles[2].tone,'1');equal(m.turtles[3].tone,'1');equal(m.alert,'ore chest full')
  end)
  for _,size in ipairs({{57,24},{100,38}}) do
    test('UI2a mining keeps full worker coordinates at '..size[1]..'x'..size[2],function()
      local s=setup()
      s.job.turtles={['2']={state='mining',pose={x=-5,y=64,z=-123},fuel=812,ores=14},
        ['3']={state='wait lane',pose={x=-7,y=64,z=456},fuel=640,ores=9}}
      local text=table.concat(capture(s.render(size[1],size[2]),size[1],size[2]).picture().text,'\n')
      for _,pos in ipairs({'-5,64,-123','-7,64,456'}) do assert(text:find(pos,1,true),'clipped '..pos) end
    end)
  end

end
