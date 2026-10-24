local U = dofile('so-ui.lua')
local R = dofile('tests/ui/render.lua')
local fixtures = {[26]='tests/ui/fixtures/turtle-P.txt',[29]='tests/ui/fixtures/turtle-S.txt',[57]='tests/ui/fixtures/turtle-M.txt'}
local function setup(w,h)
  local s={now=100000,commands={},sent={}}
  s.mine={home={x=0,y=64,z=0,facing=0},homeSet=true,bottom=60,length=48,mode='thorough',ores={},
    dim='minecraft:overworld',running=true,progress={done=0,nextBranch=2},turtles={
      ['2']={pose={x=12,y=60,z=-5,facing=1},anchor={x=0,y=64,z=0,facing=0},state='mining',branch=0,fuel=42,ores=14,
        inv={{slot=1,name='minecraft:diamond',count=14}}},
      ['3']={pose={x=0,y=60,z=-9,facing=0},state='waiting',branch=1,fuel=100,inv={}}}}
  s.lumber={dim='minecraft:overworld',spots={a={plantedAt=90000},b={}},running=false,
    phase='scan',cursor=2,turtle={id=4,pose={x=3,y=64,z=2,facing=2}},fuel=400,inv={}}
  local store=dofile('so-store.lua')
  local env=setmetatable({},{__index=_G})
  env.os=setmetatable({epoch=function() return s.now end,getComputerID=function() return 1 end},{__index=os})
  env.SO={now=function() return s.now end,proto=dofile('so-proto.lua'),pair={key=function() return string.rep('01',32) end},
    mods={},store={copy=store.copy,read=function() return {} end,store=function(path)
      return {value=path=='so-data/mine/job' and s.mine or path=='so-data/lumber/job' and s.lumber or {roles={['9']='mining',['10']='mining'}},
        save=function() return true end}
    end}}
  env.SO.proto=assert(loadfile('so-proto.lua','t',env))()
  env.rednet={send=function(id) s.sent[id]=(s.sent[id] or 0)+1 end}
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
  -- Roles change only by assignment; a 26x20 display would otherwise start as a pocket.
  assert(d.assign(9,'mining'))
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
local function lumberWorkers(s)
  for id=5,6 do
    s.lumber.turtles[tostring(id)]={turtle={id=id,pose={dim=s.lumber.dim,x=id*3,y=64,z=2,facing=1}},
      phase=id==5 and 'plant' or 'scan',fuel=id*100,inv={{slot=1,name='minecraft:oak_sapling',count=id}}}
  end
  s.lumber.running=true
  for _,row in pairs(s.lumber.turtles) do row.recover=false end
  s.display.tick(s.now)
  -- Roles change only by assignment.
  assert(s.display.assign(9,'lumber'))
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
        local row={branch=2,pose={x=10-d[2]*n+d[1]*13,y=60,z=-20+d[1]*n+d[2]*13}}
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
      -- Route A rows show the 1-based branch and its live progress: b1 12/48.
      local _,text=capture(s.frame(),w,h) assert(text:find('b1 12/48',1,true),text)
      s.press('turtle:2')
      local out,detail=capture(s.frame(),w,h)
      for _,value in ipairs({'#2','mining','12,60,-5 E','FUEL 42','INV 1/16','LEASE lease-2','STEP forward','SEEN 3s','B0 12/48','PARK ALL','REMOVE','BACK'}) do
        assert(detail:find(value,1,true),'missing '..value..' '..detail)
      end
      local diff=R.diff(fixtures[w],out)
      assert(#diff==0,table.concat(diff,'\n'))
      equal(out.cells[5][2][3],'1','low fuel')
      s.mine.turtles['2'].pose.x=24 s.display.tick(s.now)
      s.press('turtle-back') local _,back=capture(s.frame(),w,h) assert(back:find('MINING',1,true))
      assert(back:find('b1 24/48',1,true),back)
      -- The route A map draws DETAILS (turtle:2) in a picked turtle's callout: tap cells until it shows.
      assert(s.display.assign(9,'map'))
      local function details()
        for _,b in ipairs(s.frame().buttons) do if b.id=='turtle:2' then return true end end
      end
      local picked=details()
      local cells={}
      for _,b in ipairs(s.frame().buttons) do
        if b.id=='map-pick' then for x=b.x,b.x+b.w-1 do for y=b.y,b.y+b.h-1 do cells[#cells+1]={x,y} end end end
      end
      for _,c in ipairs(cells) do
        if picked then break end
        s.display.handlers.input({from=9,body={id='map-pick',x=c[1],y=c[2]}})
        picked=details()
      end
      assert(picked,'map has no turtle:2 DETAILS')
      s.press('turtle:2') capture(s.frame(),w,h)
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
      local s=setup(w,h) assert(s.display.assign(9,'lumber'))
      -- Route A's ready leader counts the unplanted or grown spots; the detail keeps SPOTS planted/total.
      local _,text=capture(s.frame(),w,h) assert(text:find('ready ',1,true) and text:find('1/2',1,true),text)
      s.press('turtle:4') local _,detail=capture(s.frame(),w,h) assert(detail:find('SPOTS 1/2',1,true))
      s.press('turtle-back') s.lumber.spots.b.plantedAt=s.now s.display.tick(s.now)
      local _,updated=capture(s.frame(),w,h) assert(updated:find('0/2',1,true),updated)
    end)
  end
  for _,size in ipairs({{26,20},{29,12},{57,24}}) do
    local w,h=unpack(size)
    test('G8a lumber details select each worker and keep progress live at '..w..'x'..h,function()
      local s=setup(w,h) lumberWorkers(s)
      for id=4,6 do
        local row=s.lumber.turtles[tostring(id)]
        row.pending={action={kind='path'}}
        s.press('turtle:'..id)
        local _,detail=capture(s.frame(),w,h)
        for _,text in ipairs({'#'..id,'FUEL '..row.fuel,'LEASE lease-'..id,'STEP path','SPOTS 1/2'}) do
          assert(detail:find(text,1,true),text)
        end
        row.fuel=row.fuel+7 s.display.tick(s.now)
        local _,updated=capture(s.frame(),w,h) assert(updated:find('FUEL '..row.fuel,1,true))
        s.press('turtle-back')
        local _,main=capture(s.frame(),w,h) assert(main:find('LUMBER',1,true))
      end
      s.lumber.spots.b.plantedAt=s.now s.display.tick(s.now)
      local _,main=capture(s.frame(),w,h) assert(main:find('0/2',1,true),main)
      s.press('turtle:5') local _,detail=capture(s.frame(),w,h) assert(detail:find('SPOTS 2/2',1,true))
    end)
    test('G8a lumber PARK targets only the selected worker at '..w..'x'..h,function()
      local s=setup(w,h) lumberWorkers(s)
      s.press('turtle:5') s.press('turtle-park')
      assert(s.lumber.running and s.lumber.turtles['5'].paused)
      assert(not s.lumber.turtles['4'].paused and not s.lumber.turtles['6'].paused)
      local _,detail=capture(s.frame(),w,h) assert(detail:find('parking',1,true))
      s.press('turtle-back') capture(s.frame(),w,h)
    end)
    test('G8a lumber RE-ADD changes only the selected uncertain worker at '..w..'x'..h,function()
      local s=setup(w,h) lumberWorkers(s)
      local before4,before6=s.env.SO.store.copy(s.lumber.turtles['4']),s.env.SO.store.copy(s.lumber.turtles['6'])
      s.uncertain=5 s.lumber.turtles['5'].paused=true s.display.tick(s.now)
      local anchored
      s.env.SO.mods.lease.reanchor=function(id,p) anchored={id=id,pose=p} s.uncertain=nil return true end
      s.press('turtle:5')
      local _,detail=capture(s.frame(),w,h) assert(detail:find('POSE ?',1,true))
      s.press('turtle-add') s.press('pose:x:1') s.press('pose:facing:1')
      s.press('turtle-save') equal(anchored,nil)
      s.press('turtle-save') equal(anchored.id,5)
      equal(anchored.pose,{dim=s.lumber.dim,x=16,y=64,z=2,facing=2})
      equal(s.lumber.turtles['4'],before4) equal(s.lumber.turtles['6'],before6)
      assert(s.lumber.running and s.lumber.turtles['5'].paused and s.lumber.turtles['5'].recover)
      s.press('turtle-back') capture(s.frame(),w,h)
    end)
  end
  for _,size in ipairs({{26,20},{29,12}}) do
    local w,h=unpack(size)
    test('G8a partial mining poses keep both subscribed displays refreshing at '..w..'x'..h,function()
      local s=setup(w,h)
      s.display.handlers.hello({from=10,body={w=w,h=h}})
      for _,id in ipairs({9,10}) do s.display.handlers['view.sub']({from=id}) end
      local before9,before10=s.sent[9],s.sent[10]
      s.mine.turtles['2'].pose={x=12}
      s.now=s.now+6000
      s.display.tick(s.now)
      assert(s.sent[9]>before9 and s.sent[10]>before10,'all displays must refresh')
      local _,main=capture(s.frame(),w,h) assert(main:find('b1 -/48',1,true),main)
      s.press('turtle:2')
      local _,detail=capture(s.frame(),w,h)
      assert(detail:find('POS -',1,true)) assert(detail:find('B0 -/48',1,true))
      equal(U.branchProgress(s.mine,s.mine.turtles['2']),nil)
    end)
    test('G8a re-add fills partial coordinates before drawing at '..w..'x'..h,function()
      local s=setup(w,h)
      s.mine.turtles['2'].pose={x=12} s.uncertain=2 s.display.tick(s.now)
      s.press('turtle:2') s.press('turtle-add')
      local _,editor=capture(s.frame(),w,h)
      assert(editor:find('12,0,0 N',1,true))
      local commands={}
      s.display.screen('mining').input=function(e) commands[#commands+1]=e.text end
      s.press('turtle-save') equal(#commands,0)
      s.press('turtle-save') equal(commands,{'add 2 12 0 0 n'})
      s.press('turtle-add') s.press('turtle-cancel') s.press('turtle-back')
      local _,main=capture(s.frame(),w,h) assert(main:find('MINING',1,true))
    end)
    test('G8a editor cancellation uses the last drawn controls when composing throws at '..w..'x'..h,function()
      local s=setup(w,h) s.uncertain=2 s.display.tick(s.now)
      s.press('turtle:2') s.press('turtle-add')
      local d
      for i=1,20 do local key,value=debug.getupvalue(s.display.tick,i) if key=='D' then d=value break end end
      assert(d)
      d.sessions[9].turtle.draft={x=12}
      capture(s.frame(),w,h)
      local compose=d.compose
      d.compose=function() error('broken editor render') end
      s.display.handlers.input({from=9,body={id='turtle-cancel',x=1,y=h}})
      equal(d.sessions[9].turtle.draft,nil)
      s.display.handlers.input({from=9,body={id='turtle-back',x=1,y=h}})
      assert(d.sessions[9].turtle,'hidden BACK must not dispatch')
      d.compose=compose
      s.press('turtle-back')
      equal(d.sessions[9].turtle,nil)
      local _,main=capture(s.frame(),w,h) assert(main:find('MINING',1,true))
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
