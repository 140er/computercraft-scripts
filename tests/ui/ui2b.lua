local R = dofile('tests/ui/render.lua')
local H = dofile('tests/so/harness.lua')
local function job(count)
  local j = { dim='minecraft:overworld', spots={a={},b={},c={plantedAt=900000},d={plantedAt=950000}},
    running=true, logs=96, nextRound=1380000, alert='out of saplings: replanting paused',
    area={x1=0,z1=0,x2=4,z2=4}, ground=64, saplings={x=1,y=65,z=1,side="down"}, turtles={} }
  for id=4,3+(count or 3) do
    j.turtles[tostring(id)] = { turtle={id=id,pose={dim=j.dim,x=id,y=65,z=0,facing=1}},
      phase=id==4 and 'felling' or 'scan', wait=id==5 and 'wait chest' or nil,
      fuel=id==4 and 1210 or 640, inv={} }
  end
  return j
end
local function screen(j, noDaily)
  local s = { saved=0, released=0, events={}, persisted=H.encode(j) }
  local env = setmetatable({SO={pair={key=function() return "paired" end},now=function() return 1000000 end,mods={},store={store=function()
    return {value=j,save=function(value) s.saved=s.saved+1 s.persisted=H.encode(value) return true end}
  end}}},{__index=_G})
  env.SO.mods.drops={list=function() return {{id="ready",dim=0,x=100000,y=0,z=0,kind="any"}} end}
  env.SO.mods.display={screen=function(_,render,input) s.render,s.input=render,input end}
  if not noDaily then env.SO.mods.daily={today=function() return {logs=96} end} end
  env.SO.mods.lease={status=function() return {} end}
  env.SO.mods.state={canStart=function() return true end,emit=function(kind,value) s.events[#s.events+1]={kind=kind,value=value} end}
  env.SO.mods.cells={releaseOwner=function() s.released=s.released+1 return true end}
  local mod=assert(loadfile('so-mod-lumber.lua','t',env))()
  mod.tick(1000000)
  for _, row in pairs(j.turtles) do row.recover=false end
  for i=1,20 do local name,value=debug.getupvalue(s.render,i) if name=="S" then s.state=value break end end
  return s
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
local function press(s, frame, id)
  for _, b in ipairs(frame.buttons) do
    if b.id==id then s.input({id=b.id,x=b.x,y=b.y}) return end
  end
  error('button not drawn ' .. id)
end
return function(test,equal)
  test('UI2b lumber fleet matches the M fixture',function()
    local s=screen(job())
    local diff=R.diff('tests/ui/fixtures/lumber-M.txt',capture(s.render(57,24),57,24))
    assert(#diff==0,table.concat(diff,'\n'))
  end)
  test('UI2b every turtle and drawn action fits pocket and compact monitors',function()
    for _,size in ipairs({{26,20},{29,12},{39,19},{57,24},{15,10},{100,38},{36,10},{1,1}}) do
      local j=job();local s=screen(j)
      local frame=s.render(unpack(size))
      local picture=capture(frame,unpack(size)).picture()
      if size[1]>=26 and size[2]>=12 then
        local text=table.concat(picture.text,'\n')
        for id=4,6 do assert(text:find('#'..id,1,true), 'worker missing #'..id) end
        for _, id in ipairs({'start','stop'}) do
          press(s,frame,id)
          equal(j.running,id=='start')
        end
        press(s,frame,'setup')
        frame=s.render(unpack(size))
        capture(frame,unpack(size))
        press(s,frame,'lumber-back')
      end
    end
  end)
  test('UI2b drawn next button reaches every worker without changing the job',function()
    local j=job(8);local s=screen(j)
    local seen={}
    for _=1,3 do
      local frame=s.render(29,12)
      local text=table.concat(capture(frame,29,12).picture().text,'\n')
      for _,b in ipairs(frame.buttons) do
        local id=b.id:match('^turtle:(%d+)$')
        if id then assert(text:find('#'..id..' ',1,true)) seen[tonumber(id)]=true end
      end
      press(s,frame,'turtles-next')
    end
    for id=4,11 do assert(seen[id],'unreachable worker '..id) end
    equal(s.saved,0)
  end)
  test('UI2b setup shows only configuration and every assigned turtle',function()
    local s=screen(job())
    press(s,s.render(57,24),'setup')
    local text=table.concat(capture(s.render(57,24),57,24).picture().text,'\n')
    for _,part in ipairs({'AREA 0,0 to 4,4','GROUND 64','SAPLINGS 1,65,1','TURTLE 4','TURTLE 5','TURTLE 6'}) do assert(text:find(part,1,true),part) end
    assert(not text:find('add id',1,true))
    equal(s.saved,0)
  end)
  test('UI2b navigation and unknown taps leave the job unchanged',function()
    local j=job();local s=screen(j)
    local before=H.encode(j)
    for _,id in ipairs({'status','unknown','generic','alerts','setup','setup-next','lumber-back'}) do s.input({id=id}) end
    equal(H.encode(j),before)
    equal(s.saved,0)
  end)
  test('UI2b add and remove address only the selected worker',function()
    local j=job();local s=screen(j)
    s.input({text='stop'})
    s.input({text='add 9 0 65 0 n'})
    assert(j.turtles['4'] and j.turtles['5'] and j.turtles['6'] and j.turtles['9'])
    equal(j.turtles['9'].turtle.pose.facing,0)
    j.turtles['5'].idlePark=true
    s.input({text='remove 5'})
    assert(not j.turtles['5'] and j.turtles['4'] and j.turtles['6'] and j.turtles['9'])
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
      if not configured then equal(a.alert,'area not set') end
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
    local j=job(1);j.turtles["2"]=j.turtles["4"];j.turtles["4"]=nil;j.turtles["2"].turtle.id=2;local s=screen(j)
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
      cmd('add 2 0 65 0 '..facing);equal(j.turtles["2"].turtle.pose.facing,n)
    end
    equal(s.released,4)
    j.turtles["2"].fuel=1210
    cmd('start');equal(j.running,true);equal(j.alert,nil)
    cmd('stop');j.turtles["2"].pending={}
    cmd('area 0 0 1 1 64','stop before configuring');cmd('add 2 0 65 0 n','stop before configuring')
    j.turtles["2"].pending=nil
    for _,text in ipairs({'area 0 0 128 0 64','area 0.5 0 1 1 64','area 0 0 1 1 30000000'}) do cmd(text,'invalid area') end
    for _,text in ipairs({'saplings 1 2 3 up','saplings x 2 3 front'}) do cmd(text,'invalid sapling chest') end
    for _,text in ipairs({'add -1 0 65 0 n','add 2 0 65 0 up','add 2 x 65 0 n'}) do cmd(text,'invalid turtle') end
    for _,text in ipairs({'','wat','start extra','stop extra','area 0','saplings 0'}) do cmd(text,'invalid command') end
    cmd('add 2','turtle already assigned')
    for _,missing in ipairs({'area','turtles','ground'}) do
      local bad=job();bad[missing]=missing=="turtles" and {} or nil;local x=screen(bad);x.input({text='start'});equal(bad.alert,missing=='area' and 'area not set' or missing=='ground' and 'ground not set' or 'paired turtle missing; fuel missing')
    end
  end)
  test('UI2b missing daily source and grow timer show a dash',function()
    local j=job();j.nextRound=nil;local s=screen(j,true)
    local text=table.concat(capture(s.render(29,12),29,12).picture().text,'\n')
    assert(text:find('LOGS -',1,true) and text:find('GROW -',1,true))
  end)
end
