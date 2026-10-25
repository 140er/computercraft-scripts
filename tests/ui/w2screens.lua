local U = dofile('so-ui.lua')
local R = dofile('tests/ui/render.lua')
local fixtures = {[26]='tests/ui/fixtures/turtle-P.txt',[29]='tests/ui/fixtures/turtle-S.txt',[57]='tests/ui/fixtures/turtle-M.txt'}
local function setup(w,h,cfg)
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
    mods={},store={copy=store.copy,read=function(path) return path=='so-server.cfg' and cfg or {} end,store=function(path)
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
-- A route A leader row: the label at the left, the value at the right end.
local function leader(text,label,value)
  for line in (text..'\n'):gmatch('(.-)\n') do
    local l=line:match('^%s*(.-)%s*$')
    if l:sub(1,#label+1)==label..' ' and l:sub(-#value)==value then return true end
  end
  return false
end

local BUILD_RETURN_MODES={'off','on','home','returning','stopped','fuel','path','reservation','uncertain',
  'complete','configure','remove','missing-home'}
local function buildReturn(mode)
  local dim='minecraft:overworld'
  local home={dim=dim,x=12,y=64,z=-5,facing=1}
  local job={dim=dim,shape='walls',blueprint={dim=dim,shape='walls',x1=10,y1=64,z1=-5,x2=20,y2=66,z2=5},
    material='minecraft:cobblestone',cursor=38,phase='check',running=false,returnHome=mode~='off',fuel=840,
    turtle={id=8,pose={dim=dim,x=12,y=67,z=-5,facing=1}},home=home,inv={}}
  if mode=='returning' or mode=='stopped' or mode=='fuel' or mode=='path' or mode=='reservation' or mode=='uncertain'
    or mode=='complete' or mode=='configure' or mode=='remove' then
    job.cursor,job.running,job.completion=121,mode~='stopped',{phase='returning',target=home}
  end
  local holds={fuel='out of fuel for return',path='path blocked; clear route',reservation='cells held',
    uncertain='boundary unconfirmed; reservations held'}
  if holds[mode] then job.blocked,job.alert=mode=='uncertain' and 'pose_uncertain' or mode,holds[mode] end
  if mode=='complete' then
    job.complete,job.running,job.completion.phase,job.turtle.pose=true,false,'complete',home
  end
  if mode=='configure' then job.running=false end
  if mode=='missing-home' then job.home,job.returnHome=nil,false end
  local s={job=job,open='lease-8',session={buildSetup=mode=='off' or mode=='on' or mode=='home' or mode=='missing-home'}}
  local env=setmetatable({SO={now=function() return 100000 end,breathe=function() end,mods={},
    store={copy=dofile('so-store.lua').copy,read=function() return {jobPoseSetup=mode=='home'} end,
      store=function() return {value=job,save=function() return true end} end}}},{__index=_G})
  env.SO.mods.state={emit=function() return true end}
  env.SO.mods.lease={status=function() return {open=s.open} end,onReport=function() end}
  env.SO.mods.display={screen=function(_,render,input) s.render,s.input=render,input end}
  s.mod=assert(loadfile('so-mod-build.lua','t',env))()
  s.mod.tick()
  if mode=='configure' or mode=='missing-home' then
    s.open=nil
    s.input({text=mode=='configure' and 'return off' or 'return on',session=s.session})
  elseif mode=='remove' then s.input({text='remove 8',session=s.session}) end
  return s
end

local function oreMap(w,h)
  local s=setup(w,h)
  s.events={}
  s.env.SO.mods.drops={list=function()
    return {{id=3,kind='ore',dim='minecraft:overworld',x=180,y=64,z=-370,broken=true}}
  end}
  s.env.SO.mods.state.history={page=function(q)
    local entries={}
    if q.kind=='mine.ore' then
      for _,ev in ipairs(s.events) do if ev.seq>(q.from or 0) then entries[#entries+1]=ev end end
    end
    return {entries=entries}
  end}
  s.map=s.env.SO.mods.map
  s.view=function()
    return {map={fit=false,sx=1,sz=1,cx=1000,cz=1000,level=64}}
  end
  s.render=function(session)
    local frame
    for _=1,60 do
      frame=s.map.render(w,h,session)
      s.map.tick(s.now)
      if session.map.ready then return s.map.render(w,h,session) end
    end
    error('ore screen planes did not settle')
  end
  s.find=function(age)
    s.events[#s.events+1]={seq=#s.events+1,kind='mine.ore',gameAt=s.now-(age or 0),
      data={id=2,name='minecraft:diamond_ore',count=1,pos={dim='minecraft:overworld',x=996,y=64,z=997}}}
    s.map.tick(s.now)
  end
  return s
end

return function(test,equal)
  for _,size in ipairs({{15,10},{26,20},{29,12},{57,24}}) do
    local w,h=size[1],size[2]
    test('B4-US ore setting matches Lua without an invented control at '..w..'x'..h,function()
      local s=oreMap(w,h)
      local a,b=s.view(),s.view()
      local off=s.render(a)
      equal(a.map.oreFinds,false)
      s.map.input({session=b,text='ore finds on'})
      local on=s.render(b)
      assert(b.map.oreFinds and not a.map.oreFinds)
      for state,frame in pairs({off=off,on=on}) do
        local out=capture(frame,w,h)
        local diff=R.diff('tests/ui/fixtures/map-ore-screen-'..state..'-'..w..'x'..h..'.txt',out)
        assert(#diff==0,table.concat(diff,'\n'))
        for _,button in ipairs(frame.buttons) do assert(button.id~='map-ore','Lua has no visible ore toggle') end
      end
      equal(on.rows,off.rows) equal(on.buttons,off.buttons)
    end)
    test('B4-US ore arrivals and exact expiry redraw cached screens at '..w..'x'..h,function()
      local s=oreMap(w,h)
      local a,b=s.view(),s.view()
      s.map.input({session=a,text='ore finds on'})
      local blank=s.render(a)
      equal(s.map.render(w,h,a),blank)
      s.render(b)
      s.find(599999)
      local found=s.map.render(w,h,a)
      assert(found~=blank,'arrival reused the cached frame')
      local x=1+math.floor((996-a.map.left)/a.map.sx)
      local y=a.map.L.my+math.floor((997-a.map.top)/a.map.sz)
      local out=capture(found,w,h)
      equal(out.cells[y][x],{'*','4','f'})
      equal(s.map.render(w,h,a),found)
      local hidden=s.map.render(w,h,b)
      equal(capture(hidden,w,h).cells[y][x][1],' ')
      s.map.input({session=a,text='ore finds off'})
      equal(s.map.render(w,h,a).rows,hidden.rows)
      s.map.input({session=a,text='ore finds on'})
      found=s.map.render(w,h,a)
      -- Render must prune an expired find even when no tick ran after the clock advanced.
      s.now=s.now+1
      local expired=s.map.render(w,h,a)
      assert(expired~=found,'expiry reused the cached frame')
      equal(expired.rows,blank.rows)
      assert(a.map.oreFinds and not b.map.oreFinds)
      equal(a.map.sx,1) equal(a.map.sz,1)
      assert(#s.env.SO.proto.ser(expired)<16384)
    end)
  end
  test('B4-US display text opt-in and redraws belong to one session',function()
    local s=oreMap(26,20)
    s.display.screen('map',function(w,h,session)
      if not session.map then session.map=s.view().map end
      return s.map.render(w,h,session)
    end,s.map.input)
    s.display.handlers.hello({from=10,body={w=26,h=20}})
    for _,id in ipairs({9,10}) do assert(s.display.assign(id,'map')) end
    s.frame(9) s.frame(10) s.find(0)
    local function shown(id)
      for _,r in ipairs(s.frame(id).rows) do if r.text:find('*',1,true) then return true end end
      return false
    end
    assert(not shown(9) and not shown(10))
    s.display.handlers.input({from=9,body={text='ore finds on',x=1,y=1}})
    assert(shown(9) and not shown(10))
    s.display.handlers.input({from=9,body={text='ore finds off',x=1,y=1}})
    assert(not shown(9) and not shown(10))
  end)
  test('B4-US generator reproduces every ore screen fixture',function()
    local started,pipe=pcall(io.popen,'pwd')
    local root=started and pipe and pipe:read('*l')
    if started and pipe then pipe:close() end
    if not root or root:sub(1,1)~='/' or not os.execute('python3 -V > /dev/null 2>&1') then
      return dofile('tests/skips.lua').record('B4-US generator','needs host processes, a POSIX shell and python3')
    end
    local function read(path) local f=assert(io.open(path,'rb')) local text=f:read('*a') f:close() return text end
    local dir=os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '"..dir.."'"))
    local names={}
    for _,size in ipairs({'15x10','26x20','29x12','57x24'}) do
      for _,state in ipairs({'off','on'}) do names[#names+1]='map-ore-screen-'..state..'-'..size end
    end
    local ok=os.execute("python3 -I '"..root.."/docs/ui/schematic/screens.py' --fixtures '"..dir.."' "..table.concat(names,' ')..' > /dev/null')
    local mismatches={}
    if ok then
      for _,name in ipairs(names) do
        if read(dir..'/'..name..'.txt')~=read('tests/ui/fixtures/'..name..'.txt') then mismatches[#mismatches+1]=name end
      end
    end
    assert(os.execute("rm -r '"..dir.."'"))
    assert(ok,'ore screen generator failed')
    equal(mismatches,{})
  end)
  for _,size in ipairs({{26,20},{29,12}}) do
    local w,h=size[1],size[2]
    for _,mode in ipairs(BUILD_RETURN_MODES) do
      test('B4-UB builder return '..mode..' matches Lua at '..w..'x'..h,function()
        local s=buildReturn(mode)
        local frame=s.render(w,h,s.session)
        local out,text=capture(frame,w,h)
        local diff=R.diff('tests/ui/fixtures/buildreturn-'..mode..'-'..w..'x'..h..'.txt',out)
        assert(#diff==0,table.concat(diff,'\n'))
        local ids={}
        for _,b in ipairs(frame.buttons) do
          ids[b.id]=true
          local row=frame.rows[b.y].text..string.rep(' ',w)
          assert(row:sub(b.x,b.x+b.w-1):find(b.label,1,true),'hidden label '..b.id)
          assert(b.id=='tab:job' or b.id=='tab:setup' or b.id=='shape-next' or b.id=='material-pick'
            or b.id=='start' or b.id=='stop' or mode=='home' and
              (b.id=='from-here' or b.id=='to-here' or b.id=='home-here'),'invented control '..b.id)
        end
        assert(ids.start and ids.stop and ids['tab:job'] and ids['tab:setup'])
        if mode=='home' then assert(ids['home-here'] and ids['from-here'] and ids['to-here']) end
        if mode=='returning' or mode=='stopped' then assert(text:find('RETURNING',1,true),text) end
        if mode=='complete' then
          assert(text:find('COMPLETE',1,true) and text:find('120/120',1,true),text)
          assert(leader(text,'need','0') and leader(text,'position','12,64,-5 E'),text)
        end
        if mode=='configure' or mode=='remove' then assert(s.job.completion.phase=='returning' and s.job.returnHome) end
        if mode=='missing-home' then assert(not s.job.returnHome) end
        assert(#dofile('so-proto.lua').ser(frame)<16384,'oversized builder frame')
      end)
    end
    test('B4-UB return opt-in has no rendered toggle at '..w..'x'..h,function()
      local off,on=buildReturn('off'),buildReturn('on')
      assert(not off.job.returnHome and on.job.returnHome)
      local a,b=off.render(w,h,off.session),on.render(w,h,on.session)
      equal(a.rows,b.rows) equal(a.buttons,b.buttons)
      on.open=nil on.input({text='return off',session=on.session})
      assert(not on.job.returnHome,'typed opt-out did not save')
    end)
  end
  test('B4-UB generator reproduces every builder return fixture',function()
    local started,pipe=pcall(io.popen,'pwd')
    local root=started and pipe and pipe:read('*l')
    if started and pipe then pipe:close() end
    if not root or root:sub(1,1)~='/' or not os.execute('python3 -V > /dev/null 2>&1') then
      return dofile('tests/skips.lua').record('B4-UB generator','needs host processes, a POSIX shell and python3')
    end
    local function read(path) local f=assert(io.open(path,'rb')) local text=f:read('*a') f:close() return text end
    local dir=os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '"..dir.."'"))
    local names={}
    for _,size in ipairs({'26x20','29x12'}) do
      for _,mode in ipairs(BUILD_RETURN_MODES) do names[#names+1]='buildreturn-'..mode..'-'..size end
    end
    local ok=os.execute("python3 -I '"..root.."/docs/ui/schematic/screens.py' --fixtures '"..dir.."' "..table.concat(names,' ')..' > /dev/null')
    local mismatches={}
    if ok then
      for _,name in ipairs(names) do
        if read(dir..'/'..name..'.txt')~=read('tests/ui/fixtures/'..name..'.txt') then mismatches[#mismatches+1]=name end
      end
    end
    assert(os.execute("rm -r '"..dir.."'"))
    assert(ok,'builder return generator failed')
    equal(mismatches,{})
  end)
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
      for _,value in ipairs({'#2','mining','12,60,-5 E','b1 ','12/48','PARK ALL','REMOVE','BACK'}) do
        assert(detail:find(value,1,true),'missing '..value..' '..detail)
      end
      for _,pair in ipairs({{'fuel','42'},{'inventory','1/16 \194\183 14'},{'lease','lease-2'},{'step','forward'},{'seen','3s'}}) do
        assert(leader(detail,pair[1],pair[2]),'missing '..pair[1]..' '..pair[2]..' '..detail)
      end
      local diff=R.diff(fixtures[w],out)
      assert(#diff==0,table.concat(diff,'\n'))
      -- Low fuel is an amber value.
      local fuel=false
      for _,row in ipairs(out.cells) do
        local line={}
        for x,cell in ipairs(row) do line[x]=cell[1] end
        line=table.concat(line)
        if line:find(' fuel ',1,true) then equal(row[line:find('42',1,true)][2],'1','low fuel') fuel=true end
      end
      assert(fuel,'no fuel row')
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
      local _,detail=capture(s.frame(),w,h) assert(detail:find('pose ?',1,true)) assert(not detail:find('12,60,-5',1,true))
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
      -- Route A's ready leader counts the unplanted or grown spots; the detail keeps spots planted/total.
      local _,text=capture(s.frame(),w,h) assert(text:find('ready ',1,true) and text:find('1/2',1,true),text)
      s.press('turtle:4') local _,detail=capture(s.frame(),w,h) assert(detail:find('spots ',1,true) and detail:find('1/2',1,true))
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
        assert(detail:find('#'..id,1,true) and detail:find('spots ',1,true) and detail:find('1/2',1,true))
        for _,pair in ipairs({{'fuel',tostring(row.fuel)},{'lease','lease-'..id},{'step','path'}}) do
          assert(leader(detail,pair[1],pair[2]),pair[1])
        end
        row.fuel=row.fuel+7 s.display.tick(s.now)
        local _,updated=capture(s.frame(),w,h) assert(leader(updated,'fuel',tostring(row.fuel)))
        s.press('turtle-back')
        local _,main=capture(s.frame(),w,h) assert(main:find('LUMBER',1,true))
      end
      s.lumber.spots.b.plantedAt=s.now s.display.tick(s.now)
      local _,main=capture(s.frame(),w,h) assert(main:find('0/2',1,true),main)
      s.press('turtle:5') local _,detail=capture(s.frame(),w,h) assert(detail:find('spots ',1,true) and detail:find('2/2',1,true))
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
      local _,detail=capture(s.frame(),w,h) assert(detail:find('pose ?',1,true))
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
      assert(leader(detail,'pose','-')) assert(detail:find('b1 -/48',1,true))
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
    local _,detail=capture(s.frame(10),29,12) assert(leader(detail,'lease','lease-2'))
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
  test('UB-14 a long error keeps its retry countdown first and marks the cut at 26x20',function()
    local frame=U.turtle.render(26,20,{id='8'},{role='mining',state='waiting',branch=0,done=2,total=10,
      error='ore chest full at drop 3 and the spare chest is full too, place a new chest',retry=6000,inv={}},1000)
    local text=capture(frame,26,20).picture().text
    equal(text[3]:sub(1,13),' ! retry 5s  ')
    assert(text[4]:find('ore chest full',1,true),text[4])
    assert(text[5]:find('%.%.%. *$'),text[5])
    assert(not text[6]:find('chest',1,true),text[6])
    -- A short error keeps the countdown on its own row and draws no cut mark.
    text=capture(U.turtle.render(26,20,{id='8'},{role='mining',state='waiting',error='ore chest full',retry=6000,
      inv={}},1000),26,20).picture().text
    equal(text[3]:sub(1,12),' ! retry 5s ') equal(text[4]:sub(1,17),'   ore chest full')
    assert(not table.concat(text):find('...',1,true))
  end)
  test('U.confirm drives REMOVE on the turtle page and another tap disarms it',function()
    local s=setup(29,12)
    local commands={}
    s.display.screen('mining').input=function(e) commands[#commands+1]=e.text end
    local function label()
      for _,b in ipairs(s.frame().buttons) do if b.id=='turtle-remove' then return b.label end end
    end
    s.press('turtle:2')
    equal(label(),'REMOVE')
    s.press('turtle-remove') equal(label(),'CONFIRM')
    s.press('turtle-park') equal(commands,{'stop'}) equal(label(),'REMOVE')
    s.now=s.now+1000
    s.press('turtle-remove') equal(commands,{'stop'}) equal(label(),'CONFIRM')
    s.now=s.now+6000
    s.press('turtle-remove') equal(commands,{'stop'}) equal(label(),'CONFIRM')
    s.now=s.now+1000
    s.press('turtle-remove') equal(commands,{'stop','remove 2'})
  end)
  test('P-U1-1 the pose editor steps x, y and z by 10 from 36 cells',function()
    local s=setup(57,24) s.uncertain=2 s.display.tick(s.now)
    local commands={}
    s.display.screen('mining').input=function(e) commands[#commands+1]=e.text end
    s.press('turtle:2') s.press('turtle-add')
    local diff=R.diff('tests/ui/fixtures/turtlepose-M.txt',(capture(s.frame(),57,24)))
    assert(#diff==0,table.concat(diff,'\n'))
    s.press('pose-step')
    local _,text=capture(s.frame(),57,24) assert(text:find('step 10',1,true),text)
    s.press('pose:x:1') s.press('pose:y:-1') s.press('pose:facing:1')
    s.press('pose-step') s.press('pose:z:1')
    s.press('turtle-save') s.press('turtle-save')
    equal(commands,{'add 2 22 50 -4 s'})
    -- 26 cells keep the old editor: no step chip, and every chip moves by 1.
    local small=setup(26,20) small.uncertain=2 small.display.tick(small.now)
    small.press('turtle:2') small.press('turtle-add')
    for _,b in ipairs(small.frame().buttons) do assert(b.id~='pose-step','step chip at 26 cells') end
  end)
  test('P-U1-3 the wall map thumbnail opens the map and visit-back returns',function()
    local s=setup(100,38) assert(s.display.assign(9,'status'))
    local function ids()
      local out={} for _,b in ipairs(s.frame().buttons) do out[b.id]=b end return out
    end
    local map=ids().map
    assert(map and map.x==60 and map.y==3 and map.w>1 and map.h>1,'no map hit over the thumbnail')
    s.press('map')
    local b=ids()
    assert(b['visit-back'] and not b.map,'map page not open')
    assert(b['map-fit'] or b['map-in'],'map controls missing')
    s.press('visit-back')
    b=ids()
    assert(b.map and not b['visit-back'],'visit-back did not return to status')
  end)
  test('PARK RESUME and REMOVE on the detail page send the worker commands with workerPark',function()
    local s=setup(26,20,{workerPark=true})
    local function ids()
      local out={} for _,b in ipairs(s.frame().buttons) do out[b.id]=b end return out
    end
    s.press('turtle:2')
    local b=ids()
    equal(b['turtle-park'].label,'PARK') assert(b['turtle-remove'] and not b['turtle-resume'])
    s.press('turtle-park')
    local row=s.mine.turtles['2']
    assert(row.paused and row.state=='parking' and s.mine.running)
    assert(not s.mine.turtles['3'].paused,'park reached another worker')
    -- A parking worker still shows PARK; RESUME waits for the park report.
    assert(not ids()['turtle-resume'])
    row.state,row.parkConfirmed='parked',true s.display.tick(s.now)
    local out=capture(s.frame(),26,20)
    local diff=R.diff('tests/ui/fixtures/turtlepark-P.txt',out)
    assert(#diff==0,table.concat(diff,'\n'))
    s.press('turtle-resume')
    assert(not row.paused and row.state=='mining')
    b=ids() assert(b['turtle-park'] and not b['turtle-resume'])
    s.press('turtle-remove') assert(not row.removeRequested,'REMOVE fired on the first tap')
    s.press('turtle-remove') assert(row.paused and row.removeRequested)
    assert(s.mine.turtles['2'],'remove parks before the row goes')
    -- Lumber gets the same three chips.
    lumberWorkers(s)
    s.press('turtle:5')
    b=ids() equal(b['turtle-park'].label,'PARK') assert(b['turtle-remove'])
    s.press('turtle-remove') s.press('turtle-remove')
    local five=s.lumber.turtles['5']
    assert(five.paused and five.removeRequested and not s.lumber.turtles['6'].paused)
  end)
  test('without workerPark the detail page keeps PARK ALL and lumber has no REMOVE',function()
    local s=setup(26,20)
    s.mine.turtles['2'].state='parked' s.display.tick(s.now)
    s.press('turtle:2')
    local b={} for _,x in ipairs(s.frame().buttons) do b[x.id]=x end
    equal(b['turtle-park'].label,'PARK ALL') assert(not b['turtle-resume'])
    lumberWorkers(s)
    s.press('turtle:5')
    b={} for _,x in ipairs(s.frame().buttons) do b[x.id]=x end
    assert(b['turtle-park'] and not b['turtle-remove'] and not b['turtle-resume'])
  end)
  test('U6-T schematic generator reproduces the step and worker park fixtures',function()
    local started,pipe=pcall(io.popen,'pwd')
    local root=started and pipe and pipe:read('*l')
    if started and pipe then pipe:close() end
    if not root or root:sub(1,1)~='/' or not os.execute('python3 -V > /dev/null 2>&1') then
      return dofile('tests/skips.lua').record('U6-T schematic generator','needs host processes, a POSIX shell and python3')
    end
    local function read(path) local f=assert(io.open(path,'rb')) local text=f:read('*a') f:close() return text end
    local dir=os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '"..dir.."'"))
    assert(os.execute("python3 -I '"..root.."/docs/ui/schematic/screens.py' --fixtures '"..dir.."' > /dev/null"))
    for _,name in ipairs({'turtlepose-M','turtlepark-P'}) do
      equal(read(dir..'/'..name..'.txt'),read('tests/ui/fixtures/'..name..'.txt'))
    end
    assert(os.execute("rm -r '"..dir.."'"))
  end)
  test('P-U1-1 a display narrowed below 36 cells drops the x10 step',function()
    local s=setup(57,24) s.uncertain=2 s.display.tick(s.now)
    local commands={}
    s.display.screen('mining').input=function(e) commands[#commands+1]=e.text end
    s.press('turtle:2') s.press('turtle-add') s.press('pose-step')
    s.display.handlers.hello({from=9,body={w=26,h=20}})
    s.press('pose:x:1')
    s.display.handlers.hello({from=9,body={w=57,h=24}})
    local _,text=capture(s.frame(),57,24) assert(text:find('step 1',1,true) and not text:find('step 10',1,true),text)
    s.press('turtle-save') s.press('turtle-save')
    equal(commands,{'add 2 13 60 -5 e'})
  end)
  test('P-U1-3 the crowded 164x81 wall keeps its map hit inside the budget',function()
    local s=setup(164,81) assert(s.display.assign(9,'status'))
    local D
    for i=1,60 do local k,v=debug.getupvalue(s.display.tick,i) if k=='D' then D=v break end if not k then break end end
    assert(D,'display table')
    local frame=s.frame()
    local slim={}
    for i,b in ipairs(frame.buttons) do slim[i]={id=b.id,x=b.x,y=b.y,w=b.w,h=b.h,label=b.label~='' and b.label or nil} end
    local bytes,buttons=#s.env.SO.proto.ser({rows=frame.rows,buttons=slim}),#frame.buttons
    -- A crowd one byte under the budget: with an empty label on every hit it would redraw tight.
    D.budget=bytes+1 D.model=nil
    local _,full=capture(frame,164,81)
    frame=s.frame()
    local _,text=capture(frame,164,81) equal(text,full)
    local map
    for _,b in ipairs(frame.buttons) do if b.id=='map' then map=b end assert(b.label~='','empty label sent') end
    assert(map and map.x==60 and map.y==3 and map.w==48 and map.h==30,'no map hit on the 164x81 wall')
    assert(bytes+13*buttons>D.budget and #s.env.SO.proto.ser(frame)<=16384)
    s.press('map')
    local open=false
    for _,b in ipairs(s.frame().buttons) do if b.id=='visit-back' then open=true end end
    assert(open,'map page not open on the 164x81 wall')
  end)
  test('build workers get no PARK RESUME or REMOVE: so-mod-build has no turtle view',function()
    local frame=U.turtle.render(26,20,{id='7'},{role='worker',workerPark=true,state='parked'},1000)
    equal(#frame.buttons,1) equal(frame.buttons[1].id,'turtle-back')
  end)
  test('a blocked lumber worker that is parked shows RESUME from its confirmed park',function()
    local s=setup(26,20,{workerPark=true}) lumberWorkers(s)
    s.press('turtle:5') s.press('turtle-park')
    local row=s.lumber.turtles['5']
    row.parkConfirmed=true s.display.tick(s.now)
    local function ids() local out={} for _,b in ipairs(s.frame().buttons) do out[b.id]=b end return out end
    assert(ids()['turtle-resume'],'parked lumber worker has no RESUME')
    row.blocked='path blocked' s.display.tick(s.now)
    local b=ids()
    assert(b['turtle-resume'] and not b['turtle-park'] and b['turtle-remove'])
  end)
end
