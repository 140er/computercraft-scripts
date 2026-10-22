local R = dofile('tests/ui/render.lua')
local function setup()
  local job = {home={x=0,y=64,z=0,facing=0},bottom=-16,length=48,mode='thorough',ores={},
    turtles={},progress={done=3,nextBranch=8},dim='minecraft:overworld',running=false}
  local render,input,saves
  saves=0
  local env=setmetatable({os=setmetatable({epoch=function() return 0 end},{__index=os}),SO={mods={state={canStart=function() return true end},lease={onReport=function() end,status=function() return {} end,
    send=function() return 'park' end},cells={reserve=function() return true end,releaseOwner=function() end},
    display={screen=function(_,r,i) render,input=r,i end}},store={store=function()
      return {value=job,save=function() saves=saves+1 return true end} end}}},{__index=_G})
  local mine=assert(loadfile('so-mod-mine.lua','t',env))();mine.tick()
  local layout,gather
  for i=1,20 do local name,value=debug.getupvalue(render,i)
    if name=='layout' then layout=value elseif name=='gather' then gather=value end
  end
  return {job=job,render=render,input=input,layout=layout,gather=gather,saves=function() return saves end}
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
return function(test,equal)
  test('UI2a mining mockup matches both fixture layers',function()
    local s=setup();assert(s.layout,'pure layout missing')
    local m={running=true,tiles={
      {'BUSY','2/2','both digging','d'},{'ORE TODAY','214','iron 120 dia 3','b'},
      {'DEPTH','-12','bottom -16','d'},{'LANE','1','#3 waiting','1'},
      {'MIN FUEL','640','#3','d'},{'BRANCHES','3/8','48 long','b'}},turtles={
      {id=2,state='mining',pos='12,60,-9',fuel='812',ore='14',stripe='d'},
      {id=3,state='wait lane',pos=' 0,61,-1',fuel='640',ore='9',stripe='1'}}}
    local diff=R.diff('tests/ui/fixtures/mining-M.txt',capture(s.layout(m,57,24),57,24))
    assert(#diff==0,table.concat(diff,'\n'))
  end)
  test('UI2a setup stays on the display that pressed its drawn button',function()
    local s=setup();local a,b={},{}
    local main=s.render(57,24,b)
    local function press(session,id)
      local button
      for _,v in ipairs(s.render(57,24,session).buttons) do if v.id==id then button=v end end
      assert(button,'missing mining button '..id)
      s.input({id=id,x=button.x,y=button.y,session=session})
    end
    press(a,'setup')
    assert(capture(s.render(57,24,a),57,24).picture().text[1]:find('SETUP',1,true))
    equal(s.render(57,24,b),main)
    equal(s.render(57,24),main)
    press(a,'mine-back');equal(s.render(57,24,a),main)
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
  test('UI2a setup navigation and every size keep bounds and contrast',function()
    local s=setup();s.input({text='invalid'})
    for _,size in ipairs({{26,20},{39,19},{57,24},{15,10},{100,38},{36,10},{1,1}}) do
      for _,setupPage in ipairs({false,true}) do
        s.input({id=setupPage and 'setup' or 'mine-back'})
        local w,h=unpack(size);local f=s.render(w,h);local out=capture(f,w,h)
        if #f.buttons>0 then equal(f.buttons[#f.buttons].id,setupPage and 'mine-back' or 'status') end
        if w==57 then assert(out.picture().text[1]:find(setupPage and 'SETUP' or 'MINING',1,true)) end
        for _,row in ipairs(out.cells) do for _,cell in ipairs(row) do
          local fg,bg=cell[2],cell[3]
          if cell[1]:byte()>=128 and cell[1]:byte()<=159 and bg=='f' and fg~='0' and fg~='8' then fg,bg=bg,fg end
          assert((bg=='f' or bg=='7' or bg=='c') and (fg=='0' or fg=='8') or
            (bg=='d' or bg=='1' or bg=='e' or bg=='b' or bg=='a' or bg=='9') and fg=='f','contrast '..fg..'/'..bg)
        end end
      end
    end
  end)
  test('UI2a gather uses mining facts and leaves daily ore stale',function()
    local s=setup();s.job.turtles={['2']={state='mining',pose={x=12,y=60,z=-9},fuel=812,ores=14},
      ['3']={state='hold',pose={x=0,y=61,z=-1},fuel=640,laneWait={},error='ore chest full'},
      ['4']={state='range',pose={x=0,y=0,z=0}}}
    assert(s.gather,'gather missing');local m=s.gather()
    equal(m.tiles[1][2],'1/3');equal(m.tiles[2][2],'-');equal(m.tiles[2][4],'c')
    equal(m.tiles[4][2],'1');equal(m.tiles[5][2],'640');equal(m.tiles[5][3],'#3')
    equal(m.turtles[2].stripe,'1');equal(m.turtles[3].stripe,'e');equal(m.alert,'ore chest full')
  end)
end
