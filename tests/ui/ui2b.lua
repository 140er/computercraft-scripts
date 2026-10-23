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
  local s = { saved=0, events={} }
  local env = setmetatable({SO={pair={key=function() return "paired" end},now=function() return 1000000 end,mods={},store={store=function()
    return {value=j,save=function() s.saved=s.saved+1 return true end}
  end}}},{__index=_G})
  env.SO.mods.drops={list=function() return {{id="ready",dim=0,x=100000,y=0,z=0,kind="any"}} end}
  env.SO.mods.display={screen=function(_,render,input) s.render,s.input=render,input end}
  if not noDaily then env.SO.mods.daily={today=function() return {logs=96} end} end
  env.SO.mods.lease={status=function() return {} end}
  env.SO.mods.state={canStart=function() return true end,emit=function(kind,value) s.events[#s.events+1]={kind=kind,value=value} end}
  env.SO.mods.cells={releaseOwner=function() return true end}
  local mod=assert(loadfile('so-mod-lumber.lua','t',env))()
  mod.tick(1000000)
  for _, row in pairs(j.turtles) do row.recover=false end
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
      for id=4,11 do if text:find('#'..id..' ',1,true) then seen[id]=true end end
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
  test('UI2b missing daily source and grow timer show a dash',function()
    local j=job();j.nextRound=nil;local s=screen(j,true)
    local text=table.concat(capture(s.render(29,12),29,12).picture().text,'\n')
    assert(text:find('LOGS -',1,true) and text:find('GROW -',1,true))
  end)
end
