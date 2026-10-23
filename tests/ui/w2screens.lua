local U = dofile('so-ui.lua')
local R = dofile('tests/ui/render.lua')
local fixtures = {[26]='tests/ui/fixtures/turtle-P.txt',[29]='tests/ui/fixtures/turtle-S.txt',[57]='tests/ui/fixtures/turtle-M.txt'}
local function setup(w,h)
  local s={now=100000,commands={}}
  s.mine={home={x=0,y=64,z=0,facing=0},homeSet=true,bottom=60,length=48,mode='thorough',ores={},
    dim='minecraft:overworld',running=true,progress={done=0,nextBranch=2},turtles={
      ['2']={pose={x=12,y=60,z=-5,facing=1},anchor={x=0,y=64,z=0,facing=0},state='mining',branch=0,fuel=42,ores=14,
        inv={{slot=1,name='minecraft:diamond',count=14}}},
      ['3']={pose={x=0,y=60,z=-9,facing=0},state='waiting',branch=1,fuel=100,inv={}}}}
  s.lumber={dim='minecraft:overworld',spots={a={plantedAt=90000},b={}},running=false,
    phase='scan',cursor=2,turtle={id=4,pose={x=3,y=64,z=2,facing=2}},fuel=400,inv={}}
  local store=dofile('so-store.lua')
  local env=setmetatable({},{__index=_G})
  env.os=setmetatable({epoch=function() return s.now end},{__index=os})
  env.SO={now=function() return s.now end,proto=dofile('so-proto.lua'),pair={key=function() return 'key' end},
    mods={},store={copy=store.copy,read=function() return {} end,store=function(path)
      return {value=path=='so-data/mine/job' and s.mine or path=='so-data/lumber/job' and s.lumber or {roles={['9']='mining',['10']='mining'}},
        save=function() return true end}
    end}}
  env.rednet={send=function() end}
  env.SO.mods.state={get=function() return {['2']={role='worker',seen=97000},['3']={role='worker',seen=90000},['4']={role='worker',seen=98000}} end}
  env.SO.mods.lease={onReport=function() end,status=function(id)
    return {open='lease-'..id,uncertain=s.uncertain==id,journal='journal-'..id}
  end}
  local d=assert(loadfile('so-mod-display.lua','t',env))()
  env.SO.mods.display=d
  for _,entry in ipairs({{'mine','so-mod-mine.lua'},{'lumber','so-mod-lumber.lua'},{'map','so-mod-map.lua'}}) do
    local name,path=entry[1],entry[2]
    local mod=assert(loadfile(path,'t',env))()
    env.SO.mods[name]=mod mod.tick(s.now)
    if name=='mine' then
      for i=1,20 do
        local key,value=debug.getupvalue(mod.tick,i)
        if key=='S' then value.pending[2]={kind='forward'} break end
      end
    end
  end
  s.mine.turtles['2'].state='mining'
  d.tick(s.now)
  d.handlers.hello({from=9,body={w=w,h=h}})
  s.frame=function(client)
    local frame d.handlers['view.get']({from=client or 9},function(_,body) frame=body end) return frame
  end
  s.press=function(id,client)
    local button
    for _,b in ipairs(s.frame(client).buttons) do if b.id==id then button=b break end end
    assert(button,'missing drawn button '..id)
    d.handlers.input({from=client or 9,body={id=id,x=button.x,y=button.y}})
  end
  s.display,s.env=d,env
  return s
end
local function capture(frame,w,h)
  local out=R.capture(w,h)
  assert(#frame.rows==h)
  for y,row in ipairs(frame.rows) do
    local fg,bg='',''
    if row.runs then
      for _,r in ipairs(row.runs) do fg=fg..string.rep(r[2],r[1]) bg=bg..string.rep(r[3],r[1]) end
    else
      fg=#row.fg==1 and string.rep(row.fg,w) or row.fg
      bg=#row.bg==1 and string.rep(row.bg,w) or row.bg
    end
    out.setCursorPos(1,y) out.blit(row.text..string.rep(' ',w-#row.text),fg,bg)
  end
  for i,b in ipairs(frame.buttons) do
    assert(b.x>=1 and b.y>=1 and b.w>0 and b.x+b.w-1<=w and b.y+b.h-1<=h)
    for j,other in ipairs(frame.buttons) do if i~=j then
      assert(b.x+b.w<=other.x or other.x+other.w<=b.x or b.y+b.h<=other.y or other.y+other.h<=b.y,'overlapping buttons')
    end end
  end
  return out,table.concat(out.picture().text,'\n')
end
return function(test,equal)
  test('G8a branch progress follows every axis and clamps',function()
    local dirs={[0]={0,-1},{1,0},{0,1},{-1,0}}
    for facing,d in pairs(dirs) do
      local job={home={x=10,z=-20,facing=facing},length=48}
      for _,n in ipairs({-10,0,12,48,100}) do
        local row={branch=2,pose={x=10-d[2]*n+d[1]*13,z=-20+d[1]*n+d[2]*13}}
        local done,total=U.branchProgress(job,row)
        equal(done,math.max(0,math.min(48,n))) equal(total,48)
      end
    end
    equal(U.branchProgress({length=0},{branch=0}),0)
  end)
  for _,size in ipairs({{26,20},{29,12},{57,24}}) do
    local w,h=unpack(size)
    test('G8a row detail back and live progress at '..w..'x'..h,function()
      local s=setup(w,h)
      local _,text=capture(s.frame(),w,h) assert(text:find('B0 12/48',1,true))
      s.press('turtle:2')
      local out,detail=capture(s.frame(),w,h)
      for _,value in ipairs({'#2','mining','12,60,-5 E','FUEL 42','INV 1/16','LEASE lease-2','STEP forward','SEEN 3s','B0 12/48','PARK ALL','REMOVE','BACK'}) do
        assert(detail:find(value,1,true),'missing '..value..' '..detail)
      end
      local diff=R.diff(fixtures[w],out)
      assert(#diff==0,table.concat(diff,'\n'))
      equal(out.cells[5][2][3],'1','low fuel')
      s.mine.turtles['2'].pose.x=24 s.display.tick(s.now)
      local _,updated=capture(s.frame(),w,h) assert(updated:find('B0 24/48',1,true))
      s.press('turtle-back') local _,back=capture(s.frame(),w,h) assert(back:find('MINING',1,true))
      s.press('map') s.press('turtle:2') capture(s.frame(),w,h)
      s.press('turtle-back') local _,map=capture(s.frame(),w,h) assert(map:find('MAP',1,true))
    end)
    test('G8a uncertain pose hides coordinates and re-add edits are isolated at '..w..'x'..h,function()
      local s=setup(w,h) s.uncertain=2 s.display.tick(s.now)
      local commands={}
      local screen=s.display.screen('mining')
      local original=screen.input screen.input=function(e) if e.text then commands[#commands+1]=e.text else original(e) end end
      s.press('turtle:2')
      local _,detail=capture(s.frame(),w,h) assert(detail:find('POSE ?',1,true)) assert(not detail:find('12,60,-5',1,true))
      s.press('turtle-add') s.press('pose:x:1') s.press('pose:facing:1') capture(s.frame(),w,h)
      s.press('turtle-save') equal(#commands,0)
      s.press('turtle-save') equal(commands,{'add 2 13 60 -5 s'})
      s.press('turtle-remove') equal(#commands,1)
      s.now=s.now+6000 s.press('turtle-remove') equal(#commands,1)
      s.press('turtle-remove') equal(commands[2],'remove 2')
      s.press('turtle-park') equal(commands[3],'stop')
    end)
    test('G8a lumber spots and turtle detail at '..w..'x'..h,function()
      local s=setup(w,h) s.press('status') s.press('generic') s.press('lumber')
      local _,text=capture(s.frame(),w,h) assert(text:find('SPOTS 1/2',1,true))
      s.press('turtle:4') local _,detail=capture(s.frame(),w,h) assert(detail:find('SPOTS 1/2',1,true))
      s.press('turtle-back') s.lumber.spots.b.plantedAt=s.now s.display.tick(s.now)
      local _,updated=capture(s.frame(),w,h) assert(updated:find('SPOTS 2/2',1,true))
    end)
  end
  test('G8a selections and destructive confirmations belong to one display',function()
    local s=setup(29,12)
    s.display.handlers.hello({from=10,body={w=29,h=12}})
    local commands={}
    local screen=s.display.screen('mining')
    screen.input=function(e) commands[#commands+1]=e.text end
    s.press('turtle:2',9)
    local _,other=capture(s.frame(10),29,12) assert(other:find('MINING',1,true))
    s.press('turtle-remove',9) equal(#commands,0)
    s.press('turtle:2',10) s.press('turtle-remove',10) equal(#commands,0)
    s.display.handlers.input({from=9,body={id='turtle-remove',x=1,y=1}}) equal(#commands,0)
    s.press('turtle-remove',9) equal(commands,{'remove 2'})
    s.press('turtle-back',9)
    local _,detail=capture(s.frame(10),29,12) assert(detail:find('LEASE lease-2',1,true))
  end)
  test('G8a compact mining pages every drawn worker row',function()
    local s=setup(29,12)
    for id=4,12 do s.mine.turtles[tostring(id)]={state='waiting',branch=id,pose={x=id,y=60,z=-5},inv={}} end
    local seen={}
    for _=1,6 do
      for _,b in ipairs(s.frame().buttons) do
        local id=b.id:match('^turtle:(%d+)$') if id then seen[id]=true end
      end
      s.press('workers-next')
    end
    for id=2,12 do assert(seen[tostring(id)],'worker missing '..id) end
  end)
  test('G8a unassigned registry workers have only a return action',function()
    local frame=U.turtle.render(29,12,{id='2'},{role='worker',uncertain=true},1000)
    equal(#frame.buttons,1) equal(frame.buttons[1].id,'turtle-back')
  end)
  test('G8a waiting lost and retry details stay visible at both compact sizes',function()
    for _,size in ipairs({{26,20},{29,12}}) do
      for _,state in ipairs({'waiting','lost'}) do
        local selection={id='8'}
        local frame=U.turtle.render(size[1],size[2],selection,{role='mining',state=state,branch=0,done=2,total=10,
          error='ore chest full',retry=2000,inv={}},1000)
        local _,text=capture(frame,size[1],size[2]) assert(text:find(state,1,true)) assert(text:find('ore chest full',1,true))
      end
    end
  end)
end
