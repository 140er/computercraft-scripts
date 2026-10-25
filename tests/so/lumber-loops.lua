local fixture = dofile('tests/so/lumber-fixture.lua')
local function setup(...)
  local s = fixture(...)
  s.mods.drops.choose = s.mods.drops.pick
  return s
end

local function scanner(enabled)
  local s = setup('waiting')
  s.row.tree = nil
  s.job.visited, s.job.nextRound = { true, true, true }, 600000
  s.env.SO.store.read = function() return { lumberScan = enabled } end
  s.mods.display.screen = function(_, render, input)
    s.draw, s.tap = render, function(id) input({ id = id }) end
    s.input = function(text) input({ text = text }) end
  end
  s.tick = assert(loadfile('so-mod-lumber.lua', 't', s.env))().tick
  s.tick(0)
  s.report(false)
  return s
end

local function realDrops(s)
  local store = s.env.SO.store.store
  s.env.SO.store.store = function() return { save = function() return true end } end
  s.mods.drops = assert(loadfile('so-mod-drops.lua', 't', s.env))()
  s.env.SO.store.store = store
end


local function copy(v)
  if type(v) ~= 'table' then return v end
  local out={} for k,x in pairs(v) do out[k]=copy(x) end return out
end
local function controls(s, config)
  s.env.SO.store.copy=copy
  s.env.SO.store.read=function() return config or {} end
  s.mods.display.screen=function(_,render,input)
    s.draw=render
    s.press=function(id,session) input({id=id,session=session}) end
    s.input=function(text) input({text=text}) end
  end
  local mod=assert(loadfile('so-mod-lumber.lua','t',s.env))()
  s.tick=mod.tick s.mod=mod s.tick(0) s.report(false)
  return s
end

local function onceFixture(options)
  options = options or {}
  local P = dofile('so-plan.lua')
  local dim = 'minecraft:overworld'
  local function key(p) return p.x .. ',' .. p.y .. ',' .. p.z end
  local s = { clock = 0, queued = {}, sent = {}, workers = {}, world = {}, events = {}, saves = 0 }
  local job = { dim = dim, ground = 0, area = {x1=0,x2=2,z1=0,z2=2}, spots = {},
    running = false, turtles = {}, candidates = options.candidates or {},
    saplings = {x=-4,y=1,z=2,side='down'} }
  for _, id in ipairs(options.ids or {2}) do
    local pose = {dim=dim,x=id==2 and 0 or 2,y=2,z=1,facing=1}
    local inv = options.inv or {{slot=1,name='minecraft:oak_sapling',count=8}}
    s.workers[id] = {pose=copy(pose),inv=copy(inv),fuel=10000}
    job.turtles[tostring(id)] = {turtle={id=id,pose=pose,frame={dim=dim,ox=0,oy=0,oz=0,rot=0}},
      inv=copy(inv),fuel=10000,phase='scan'}
  end
  local points = {{id='wood',dim=0,x=-4,y=1,z=-2,side='down',kind='wood'},
    {id='fuel',dim=0,x=-4,y=1,z=-2,side='down',kind='fuel'},
    {id='saplings',dim=0,x=-4,y=1,z=2,side='down',kind='storage'}}
  for _, point in ipairs(points) do s.world[key(point)] = {name='minecraft:chest'} end
  local saved, callbacks, reservations, serial = copy(job), {}, {}, 0
  local mods = {}
  local env = setmetatable({SO={now=function() return s.clock end,pair={key=function() return 'paired' end},mods=mods,
    store={copy=copy,read=function() return {lumberScan=true} end,
      store=function()
        local value=copy(saved) s.job=value
        return {value=value,save=function(v)
          s.saves=s.saves+1
          if s.failSave then return false,'disk' end
          saved=copy(v) return true
        end}
      end}}}, {__index=_G})
  mods.cells = {
    owner=function(x,y,z) return reservations[x..','..y..','..z] end,
    reserveMany=function(owner,cells)
      for _,p in ipairs(cells) do if reservations[key(p)] and reservations[key(p)]~=owner then return false,'held',p end end
      for _,p in ipairs(cells) do reservations[key(p)]=owner end
      return true
    end,
    releaseOwner=function(owner) for k,v in pairs(reservations) do if v==owner then reservations[k]=nil end end return true end,
    list=function(owner)
      local out={}
      for k,v in pairs(reservations) do if v==owner then
        local x,y,z=k:match('^(%-?%d+),(%-?%d+),(%-?%d+)$')
        out[#out+1]={dim=dim,x=tonumber(x),y=tonumber(y),z=tonumber(z)}
      end end
      return out
    end,
    release=function(owner,x,y,z) if reservations[x..','..y..','..z]==owner then reservations[x..','..y..','..z]=nil end return true end,
    isDug=function(x,y,z) return not options.unknownParking and x>=-6 and x<=6 and z>=-6 and z<=6 and y>=2 and y<=4 and not s.world[x..','..y..','..z] end,
  }
  mods.state = {canStart=function() return true end,emit=function(kind,data)
    s.events[#s.events+1]={kind=kind,data=copy(data)} return true end}
  mods.drops = {list=function() return points end,add=function() return true end,usable=function() return true end,
    choose=function(kind) return {point=points[kind=='wood' and 1 or 2]} end,
    steps=function() return {{op='inspectDown'},{op='dropDown'}} end}
  mods.display = {screen=function(_,_,input) s.input=function(text) input({text=text}) end end}
  mods.lease = {
    status=function(id)
      local w=s.workers[id]
      return {open=s.queued[id] and s.queued[id].id,parkBatch=not s.oldWorker,setupFence=not s.oldWorker,
        journal='journal-'..id..'-'..(w.journal or 0),pose=copy(w.pose),lost=w.lost,uncertain=w.uncertain,range=10000}
    end,
    inRange=function() return true end,
    assess=function(id,from,steps)
      return P.assess(from,steps,{admit=function(_,_,p)
        if s.protected and s.protected(p) then return false,'protected' end
        local owner=reservations[key(p)]
        return not owner or owner=='lumber:'..id,'held'
      end})
    end,
    onReport=function(owner,fn) callbacks[owner]=fn end,
    send=function(id,steps,opts)
      assert(not s.queued[id],'overlapping lease')
      serial=serial+1
      local q={id=serial,steps=copy(steps),opts=copy(opts),worker=id}
      s.queued[id]=q s.sent[#s.sent+1]=q
      return serial
    end,
  }
  s.mods,s.env,s.callbacks=mods,env,callbacks
  function s.reload()
    s.mod=assert(loadfile('so-mod-lumber.lua','t',env))()
    s.mod.tick(s.clock)
  end
  function s.row(id) return s.job.turtles[tostring(id or 2)] end
  function s.save() saved=copy(s.job) end
  function s.tree(x,z,name)
    for y=1,3 do s.world[x..','..y..','..z]={name=name or 'minecraft:oak_log',tags={['minecraft:logs']=true}} end
  end
  function s.reply(id, failure, lose)
    local q=assert(s.queued[id]) s.queued[id]=nil
    local w,results=s.workers[id],{}
    local function add(name,n)
      for _,item in ipairs(w.inv) do if item.name==name then item.count=item.count+n return end end
      local used={} for _,item in ipairs(w.inv) do used[item.slot]=true end
      for slot=1,16 do if not used[slot] then w.inv[#w.inv+1]={slot=slot,name=name,count=n} return end end
      error('inventory full')
    end
    for i,step in ipairs(q.steps) do
      local op,r=step.op,{ok=true}
      local dir=({inspect='forward',dig='forward',inspectUp='up',digUp='up',inspectDown='down',digDown='down',placeDown='down'})[op]
      local cell
      if dir then local x,y,z=P.ahead(w.pose,dir) cell={x=x,y=y,z=z} end
      if failure and (P.moves[op] or P.turns[op]) then r={ok=false,err='blocked'}
      elseif op:match('^inspect') then r={ok=s.world[key(cell)]~=nil,data=copy(s.world[key(cell)])}
      elseif op:match('^dig') then
        local block=s.world[key(cell)]
        if block then s.world[key(cell)]=nil add(block.name,1) else r.ok=false end
      elseif op=='placeDown' then
        local item
        for _,v in ipairs(w.inv) do if v.slot==w.selected then item=v end end
        if s.world[key(cell)] or not item or item.count==0 then r.ok=false
        else s.world[key(cell)]={name=item.name} item.count=item.count-1 end
      elseif op=='select' then w.selected=step.slot
      elseif op=='dropDown' or op=='drop' then
        if s.blockUnload then r={ok=false,err='No space for items'} else
          for _,item in ipairs(w.inv) do if item.slot==w.selected then item.count=math.max(0,item.count-(step.n or item.count)) end end
        end
      elseif op=='suckDown' or op=='suck' then
        if s.noSaplings then r={ok=false,err='No items to take'} else add('minecraft:oak_sapling',step.n or 8) end
      elseif P.moves[op] then
        local dest=P.apply(w.pose,op)
        if s.world[key(dest)] then r={ok=false,err='Movement obstructed'} else w.pose=dest end
      elseif P.turns[op] then w.pose=P.apply(w.pose,op)
      end
      results[i]=r
    end
    for i=#w.inv,1,-1 do if w.inv[i].count==0 then table.remove(w.inv,i) end end
    w.journal=(w.journal or 0)+1
    if lose then return q end
    callbacks.lumber(q.id,id,results,{report={pose={x=w.pose.x,y=w.pose.y,z=w.pose.z,f=w.pose.facing},
      fuel=w.fuel,inv=copy(w.inv),journal='journal-'..id..'-'..w.journal}})
    return q
  end
  function s.step(n)
    for _=1,n or 1 do
      s.clock=s.clock+1 s.mod.tick(s.clock)
      for _,id in ipairs(options.ids or {2}) do if s.queued[id] then s.reply(id) end end
    end
  end
  s.reload()
  for _,id in ipairs(options.ids or {2}) do s.reply(id) end
  return s
end

return function(test, equal)
  test('B4-C ONCE drains saved and discovered candidates, accepted trees, claims, replant and unload before confirmed parking',function()
    local dim='minecraft:overworld'
    local s=onceFixture({candidates={{dim=dim,x=2,y=2,z=2},{dim=dim,x=2,y=2,z=2}}})
    s.tree(2,2) s.tree(0,0)
    s.job.spots['0,0']={kind='minecraft:oak_log',plantedAt=1}
    s.input('mode once') s.input('start')
    equal(s.job.cycleMode,'once') equal(#s.job.cycle.candidates,1)
    local sawClaim,sawFinishing,sawReceipt,sawPark=false,false,false,false
    for _=1,900 do
      s.clock=s.clock+1 s.mod.tick(s.clock)
      local cycle=s.job.cycle
      sawClaim=sawClaim or next(cycle.claims)~=nil
      sawFinishing=sawFinishing or cycle.phase=='finishing'
      local q=s.queued[2]
      if q then
        equal(#q.steps,#dofile('so-plan.lua').boundary({steps=q.steps}).steps)
        equal(q.steps[1].park,true) assert(q.opts.journal:match('^journal%-2%-'))
        if s.row().pending.action=='cyclePark' then
          equal(s.job.running,true) assert(cycle.phase~='complete')
          assert(s.job.logs and s.job.logs>0,'park preceded delivery receipt')
          sawPark=true
        end
        s.reply(2)
      end
      sawReceipt=sawReceipt or (s.job.logs or 0)>0
      if cycle.phase=='complete' then break end
    end
    equal(s.job.cycle.phase,'complete') equal(s.job.running,false)
    assert(sawClaim and sawFinishing and sawReceipt and sawPark,'cycle skipped a completion obligation')
    equal(#s.job.cycle.candidates,0) equal(next(s.job.cycle.claims),nil)
    equal(s.job.logs,6)
    equal(s.world['0,1,0'].name,'minecraft:oak_sapling') equal(s.world['2,1,2'].name,'minecraft:oak_sapling')
    local park=s.job.cycle.parks['2']
    assert(park.x < -1 or park.x > 3 or park.z < -1 or park.z > 3,'park blocks tree access')
    for _,point in ipairs(s.mods.drops.list()) do assert(math.abs(park.x-point.x)+math.abs(park.z-point.z)>2,'park blocks chest corridor') end
    equal(s.job.cycle.parked['2'],true)
    local id=s.job.cycle.id
    s.step(40) equal(s.job.cycle.id,id) equal(s.job.nextRound,nil)
    s.input('mode repeat') equal(s.job.cycle,nil) equal(s.row().phase,'scan')
    s.input('mode once') s.input('start') equal(s.job.cycle.id,id+1)
  end)

  test('B4-C STOP START and reboot retain one cycle, its membership, queues, claims and service intent',function()
    local ids={2}
    local s=onceFixture({ids=ids,candidates={{dim='minecraft:overworld',x=2,y=2,z=2}}})
    s.tree(2,2)
    s.input('mode once') s.input('start') s.step(3)
    local cycle=copy(s.job.cycle)
    assert(next(cycle.claims),'no claimed candidate to resume')
    s.input('stop') s.input('scan') s.input('mode repeat') s.input('species none')
    equal(s.job.cycleMode,'once') equal(s.job.species,false)
    equal(s.job.scanRequested,nil)
    local pose={dim=s.job.dim,x=5,y=2,z=5,facing=0}
    s.workers[9]={pose=pose,inv={},fuel=10000}
    s.input('add 9 5 2 5 n') ids[#ids+1]=9
    s.mods.lease.ensureTool=function(id) assert(id~=9,'waiting worker was equipped before its cycle') return true end
    equal(s.job.cycle.members,{['2']=true})
    local target=copy(s.row().target)
    s.row().service={kind='wood',stage='return',resume=s.row().phase,back=copy(s.row().turtle.pose),
      point={id='wood',x=-4,y=1,z=-2,side='down'}}
    s.save() local service=copy(s.row().service)
    s.reload() equal(s.job.running,false)
    s.step(2)
    equal(s.job.cycle.id,cycle.id) equal(s.job.cycle.members,cycle.members)
    equal(s.job.cycle.claims,cycle.claims) equal(s.job.cycle.done,cycle.done)
    equal(s.job.cycle.candidates,cycle.candidates) equal(s.row().target,target) equal(s.row().service,service)
    s.input('park 2') equal(s.row().paused,true)
    s.input('start') equal(s.job.running,true) equal(s.job.cycle.id,cycle.id) equal(s.row().paused,nil)
    s.step(900)
    equal(s.job.cycle.phase,'complete') equal(s.job.cycle.members,{['2']=true})
    equal(s.job.cycle.parks['9'],nil) equal(s.row(9).target,nil)
    s.reload() equal(s.job.running,false) equal(s.job.cycle.id,cycle.id)
  end)

  for _,mode in ipairs({'once','repeat'}) do
  test('B4-C '..mode..' START re-inspects a paused travel dig before excluding a changed species',function()
    local s=onceFixture({ids={2,3}})
    s.tree(0,0) s.input('species minecraft:oak_log') s.input('mode '..mode) s.input('start')
    local paused=false
    for _=1,200 do
      s.step()
      local motion=s.row().motion
      if motion and motion.op and motion.op:match('^dig') and motion.cell then
        local cell=motion.cell local key=cell.x..','..cell.y..','..cell.z
        s.input('stop')
        s.world[key]={name='minecraft:birch_log',tags={['minecraft:logs']=true}}
        s.input('start') s.step(2)
        equal(s.world[key].name,'minecraft:birch_log','START replayed a stale dig before inspecting the new species')
        paused=true break
      end
    end
    assert(paused,'no travel dig to pause')
  end)
  end

  test('B4-C an ONCE reboot during a running claimed tree resumes without a second cycle',function()
    local s=onceFixture()
    s.tree(0,0) s.input('mode once') s.input('start')
    for _=1,200 do s.step() if s.row().tree then break end end
    assert(s.row().tree)
    local id,claims=s.job.cycle.id,copy(s.job.cycle.claims)
    s.reload() equal(s.job.running,true) equal(s.job.cycle.id,id) equal(s.job.cycle.claims,claims)
    s.step(900) equal(s.job.cycle.phase,'complete') equal(s.job.cycle.id,id) equal(s.job.logs,3)
  end)

  test('B4-C ONCE holds completion for missing saplings, blocked unloads and lost members',function()
    for _,cause in ipairs({'saplings','unload','lost'}) do
      local s=onceFixture({inv=cause=='saplings' and {} or nil})
      s.tree(0,0) s.input('mode once') s.input('start')
      s.noSaplings=cause=='saplings' s.blockUnload=cause=='unload'
      if cause=='lost' then s.workers[2].lost=true end
      s.step(400)
      assert(s.job.cycle.phase~='complete',cause..' was treated as complete')
      equal(s.job.running,true)
      if cause=='saplings' then assert(s.row().tree and next(s.job.cycle.claims),'missing saplings discarded accepted tree') end
      if cause=='unload' then assert(s.row().service and s.row().blocked,'blocked unload lost its service intent') end
    end
  end)

  test('B4-C ONCE parks several members in distinct cells outside all remaining work and chest access',function()
    local s=onceFixture({ids={2,3}})
    s.tree(0,0) s.tree(2,2) s.input('mode once') s.input('start') s.step(1200)
    equal(s.job.cycle.phase,'complete')
    local a,b=s.job.cycle.parks['2'],s.job.cycle.parks['3']
    assert(a and b and (a.x~=b.x or a.y~=b.y or a.z~=b.z),'workers share a park')
    equal(s.job.cycle.parked,{['2']=true,['3']=true})
    equal(s.job.logs,6)
  end)

  test('B4-C ONCE refuses old workers and never completes without a known clear park route',function()
    local s=onceFixture({unknownParking=true,inv={}})
    s.input('mode once') s.oldWorker=true s.input('start')
    equal(s.job.running,false) equal(s.job.cycle,nil)
    s.oldWorker=false s.input('start') s.step(300)
    equal(s.job.cycle.phase,'finishing') equal(s.job.cycle.parks['2'],nil)
    assert(s.row().alert:find('parking',1,true))
  end)

  for _,failure in ipairs({'move','turn'}) do
    test('B4-C ONCE parking holds failed '..failure..' boundaries and retains reservations',function()
      local s=onceFixture()
      s.input('mode once') s.input('start')
      local injected,planned=false,false
      for _=1,400 do
        if failure=='turn' and s.job.cycle.phase=='finishing' and not planned then
          s.job.cycle.parks['2']={dim=s.job.dim,x=2,y=2,z=-2,facing=0}
          s.save() planned=true
        end
        s.clock=s.clock+1 s.mod.tick(s.clock)
        local q=s.queued[2]
        if q then
          local P=dofile('so-plan.lua') local op=q.steps[#q.steps].op
          if s.row().phase=='cyclePark' and (failure=='move' and P.moves[op] or failure=='turn' and P.turns[op]) then
            local before=copy(s.row().turtle.pose)
            s.reply(2,true)
            equal(s.queued[2],nil) equal(s.row().turtle.pose,before)
            equal(s.row().recover,true) assert(s.row().uncertain and #s.row().uncertain>0)
            assert(#s.mods.cells.list('lumber:2')>0,'failed return released its cells')
            equal(s.job.cycle.parked['2'],nil) injected=true break
          end
          s.reply(2)
        end
      end
      assert(injected,'no parking '..failure..' to fail')
    end)
  end

  test('B4-C explicit species governs discovery, base, climb and every horizontal, vertical and service travel dig',function()
    local L=dofile('so-lumber-plan.lua')
    local selected={'minecraft:oak_log'}
    for _,name in ipairs({'minecraft:birch_log','mod:unknown_log','minecraft:birch_leaves','mod:unknown_leaves'}) do
      local block={name=name,tags={['minecraft:logs']=name:match('_log$')~=nil,['minecraft:leaves']=name:match('_leaves$')~=nil}}
      equal(L.canDig(block,selected),false,name)
      for _,kind in ipairs({'scan','base','climb','horizontal','up','down','service'}) do
        local s=setup(kind=='base' and 'base' or kind=='climb' and 'climb' or 'scan')
        s.job.species=selected s.row.target={dim=s.job.dim,x=0,y=2,z=0,index=1}
        s.job.spots['0,0']={kind='minecraft:oak_log'}
        if kind=='horizontal' then s.row.target.x=1
        elseif kind=='up' then s.row.target.y=3
        elseif kind=='down' then s.row.turtle.pose.y=3
        elseif kind=='service' then s.row.service={kind='wood',stage='travel',resume='scan',point={id='wood',x=3,y=1,z=0,side='down'}} end
        s.tick(1)
        local q=assert(s.queued()) local results={}
        for i,step in ipairs(q.steps) do results[i]={ok=not step.op:match('^inspect'),data=nil}
          if step.op:match('^inspect') then results[i]={ok=true,data=block} end
        end
        s.report(false,results)
        local nextq=s.queued()
        if nextq then for _,step in ipairs(nextq.steps) do assert(not step.op:match('^dig'),kind..' dug '..name) end end
        if s.row.motion then assert(not (s.row.motion.op or ''):match('^dig'),kind..' queued a dig') end
      end
    end
    equal(L.canDig({name='minecraft:oak_leaves'},selected),true)
    equal(L.isLog({name='minecraft:oak_log',tags={['minecraft:logs']=true}},selected),true)
    equal(L.isLog({name='minecraft:oak_log',tags={['minecraft:logs']=true}},{}),false)
  end)

  test('B4-C STOP at an ONCE scan boundary sends no dependent turn and resumes the saved claim',function()
    local s=onceFixture({inv={}})
    s.input('mode once') s.input('start')
    local interrupted=false
    for _=1,100 do
      s.clock=s.clock+1 s.mod.tick(s.clock)
      local q=s.queued[2]
      if q then
        if s.row().pending.action=='scan' then
          local target=copy(s.row().target) local claims=copy(s.job.cycle.claims)
          local before=#s.sent
          s.input('stop') s.reply(2)
          equal(#s.sent,before) equal(s.queued[2],nil)
          equal(s.row().target,target) equal(s.job.cycle.claims,claims)
          s.input('start') interrupted=true break
        end
        s.reply(2)
      end
    end
    assert(interrupted,'scan had no boundary to interrupt')
    s.step(300) equal(s.job.cycle.phase,'complete')
    equal(next(s.job.cycle.claims),nil)
  end)

  for _,action in ipairs({'plant','drop'}) do
    test('B4-C reboot after a lost '..action..' report reconciles replant and delivery receipts once',function()
      local s=onceFixture()
      s.tree(0,0) s.input('mode once') s.input('start')
      local lost=false
      for _=1,600 do
        s.clock=s.clock+1 s.mod.tick(s.clock)
        local q=s.queued[2]
        if q then
          local pending=s.row().pending.action
          if pending==action or type(pending)=='table' and pending.kind==action then
            s.reply(2,false,true) s.reload() lost=true break
          end
          s.reply(2)
        end
      end
      assert(lost,'no '..action..' report to lose')
      s.step(600)
      equal(s.job.cycle.phase,'complete') equal(s.job.logs,3)
      equal(s.world['0,1,0'].name,'minecraft:oak_sapling')
      s.reload() s.step(4) equal(s.job.logs,3)
    end)
  end

  test('B4-C a rejected journal fence cannot acknowledge an ONCE park or release its reservations',function()
    local s=onceFixture()
    s.input('mode once') s.input('start')
    local rejected=false
    for _=1,600 do
      s.clock=s.clock+1 s.mod.tick(s.clock)
      local q=s.queued[2]
      if q then
        if s.row().pending.action=='cyclePark' then
          local w=s.workers[2] s.queued[2]=nil
          local results={} for i=1,#q.steps do results[i]={ok=false,err='journal changed'} end
          s.callbacks.lumber(q.id,2,results,{report={journal='changed',inv=copy(w.inv),
            pose={x=w.pose.x,y=w.pose.y,z=w.pose.z,f=w.pose.facing}}})
          equal(s.job.cycle.parked['2'],nil) equal(s.row().recover,true)
          assert(#s.mods.cells.list('lumber:2')>0)
          rejected=true break
        end
        s.reply(2)
      end
    end
    assert(rejected,'no park fence to reject')
  end)

  test('B4-C a cycle save failure sends no work and cannot publish COMPLETE',function()
    local s=onceFixture()
    s.input('mode once') s.failSave=true
    local before=#s.sent s.input('start')
    equal(#s.sent,before) equal(s.job.running,false)
    s.failSave=false s.input('start')
    for _=1,600 do
      s.clock=s.clock+1 s.mod.tick(s.clock)
      if s.queued[2] then s.reply(2) end
      if s.job.cycle.parked['2'] then break end
    end
    equal(s.job.cycle.parked['2'],true)
    s.failSave=true s.clock=s.clock+1 s.mod.tick(s.clock)
    equal(s.job.cycle.phase,'finishing') equal(s.mod.facts().state,'stopped')
    s.failSave=false s.reload() s.step(600)
    equal(s.job.cycle.phase,'complete')
  end)

  test('B4-C parking revalidates a saved destination when it becomes obstructed',function()
    local s=onceFixture()
    s.input('mode once') s.input('start')
    local checked=false
    for _=1,600 do
      s.clock=s.clock+1 s.mod.tick(s.clock)
      if s.queued[2] then s.reply(2) end
      if s.job.cycle.parks['2'] and not s.queued[2] then
        local target=copy(s.job.cycle.parks['2'])
        s.world[target.x..','..target.y..','..target.z]={name='minecraft:stone'}
        s.job.obstacles[target.x..','..target.y..','..target.z]=true
        s.clock=s.clock+1 s.mod.tick(s.clock)
        equal(s.job.cycle.parked['2'],nil)
        assert(s.job.cycle.phase~='complete')
        local replacement=s.job.cycle.parks['2']
        assert(not replacement or replacement.x~=target.x or replacement.y~=target.y or replacement.z~=target.z,'blocked park was reused')
        checked=true break
      end
    end
    assert(checked,'no saved parking destination to revalidate')
  end)

  test('B4-C ONCE admits each movement through the protected cell boundary',function()
    local s=onceFixture({inv={}})
    s.input('mode once') s.input('start')
    local checked=false
    for _=1,200 do
      s.clock=s.clock+1 s.mod.tick(s.clock)
      if s.queued[2] then
        local action=s.row().pending.action
        if type(action)=='table' and action.kind=='path' then
          s.protected=function() return true end
          local before=#s.sent s.reply(2)
          equal(#s.sent,before) equal(s.row().blocked,'hold') equal(s.row().alert,'protected')
          assert(s.job.cycle.phase~='complete') checked=true break
        end
        s.reply(2)
      end
    end
    assert(checked,'no route admission to reject')
  end)

  test('B4-C selected oak travel digs remain available under an explicit selection',function()
    for _,kind in ipairs({'horizontal','up','service'}) do
      local s=setup('scan') s.job.species={'minecraft:oak_log'}
      s.row.target={dim=s.job.dim,x=kind=='horizontal' and 1 or 0,y=kind=='up' and 3 or 2,z=0,index=1}
      if kind=='service' then s.row.service={kind='wood',stage='travel',resume='scan',point={id='wood',x=3,y=1,z=0,side='down'}} end
      s.tick(1) local q=assert(s.queued()) local results={}
      for i,step in ipairs(q.steps) do results[i]={ok=true,data=step.op:match('^inspect') and {name='minecraft:oak_log',tags={['minecraft:logs']=true}} or nil} end
      s.report(false,results)
      q=assert(s.queued(),kind..' did not permit a selected log')
      assert(q.steps[1].op:match('^dig'),kind..' did not dig a selected log')
    end
  end)

  test('B4-C species false preserves exact legacy tagged log, leaf, plant and exclusion classification',function()
    local L=dofile('so-lumber-plan.lua')
    for _,case in ipairs({
      {'mod:unknown_log',{['minecraft:logs']=true},true,true},
      {'minecraft:oak_wood',{['minecraft:logs']=true},true,true},
      {'minecraft:dark_oak_log',{['minecraft:logs']=true},false,false},
      {'minecraft:dark_oak_leaves',{},false,true},
      {'minecraft:oak_log',{},false,false},
      {'mod:unknown_leaves',{},false,true},
      {'mod:canopy',{['minecraft:leaves']=true},false,true},
      {'minecraft:vine',{},false,true},{'minecraft:oak_sapling',{},false,false},{'minecraft:stone',{},false,false},
    }) do
      local block={name=case[1],tags=case[2]}
      equal(L.isLog(block,false),case[3],case[1]) equal(L.canDig(block,false),case[4],case[1])
      equal(L.isLog(block),case[3]) equal(L.canDig(block),case[4])
    end
    local s=onceFixture()
    equal(s.job.cycleMode,'repeat') equal(s.job.species,false)
    s.input('species minecraft:oak_log minecraft:birch_log minecraft:oak_log')
    equal(s.job.species,{'minecraft:birch_log','minecraft:oak_log'})
    s.input('species mod:unknown_log') equal(s.job.species,{'minecraft:birch_log','minecraft:oak_log'})
    s.input('species none') equal(s.job.species,{}) s.input('species false') equal(s.job.species,false)
  end)

  for _,kind in ipairs({"fuel suck","sapling place"}) do
    test("lumber handles failed "..kind.." with protection enabled",function()
      local P=dofile("so-plan.lua")
      local plant=kind=="sapling place"
      local s=setup(plant and "plantPlace" or "scan",1000,
        plant and {{slot=1,name="minecraft:oak_sapling",count=1}} or {})
      s.mods.lease.boundaries=function() return true end
      s.mods.lease.assess=function(_,from,steps) return P.assess(from,steps) end
      s.row.target={dim=s.job.dim,x=0,y=2,z=0,index=1}
      s.job.spots["0,0"]={kind="minecraft:oak_log"}
      if not plant then s.row.service={kind="fuel",stage="take",resume="scan",
        point={id="fuel",dim=0,x=0,y=1,z=0,side="down"},back=copy(s.row.turtle.pose)} end
      s.tick(1)
      local q=assert(s.queued())
      equal(q.steps[#q.steps].op,plant and "placeDown" or "suckDown")
      s.report(false,{{ok=true},{ok=false,err=plant and "Cannot place block here" or "No items to take"}})
      equal(s.row.recover,false)
      if plant then
        equal(s.row.target,nil) equal(s.row.phase,"scan") equal(s.job.spots["0,0"].plantedAt,nil)
      else
        equal(s.row.blocked,"fuel") assert(s.row.alert:find("empty",1,true),s.row.alert)
      end
    end)
  end
  test("lumber sapling planner refuses placement at a protected box edge",function()
    local P=dofile("so-plan.lua")
    local s=setup("plantPlace",1000,{{slot=1,name="minecraft:oak_sapling",count=1}})
    s.mods.lease.boundaries=function() return true end
    s.mods.lease.assess=function(_,from,steps)
      return P.assess(from,steps,{admit=function(_,_,to) return to.y~=1,"protected" end})
    end
    s.row.target={dim=s.job.dim,x=0,y=2,z=0,index=1}
    s.job.spots["0,0"]={kind="minecraft:oak_log"}
    s.tick(1)
    equal(s.queued(),nil) equal(s.row.blocked,"hold") equal(s.row.alert,"protected")
  end)
  for _, supply in ipairs({false,true}) do
    for _,failure in ipairs({"move","turn"}) do
      test("lumber "..(supply and "supply trip" or "work route").." holds after a failed "..failure.." boundary",function()
        local P=dofile("so-plan.lua")
        local s=setup(failure=="move" and "climb" or "scan")
        local assessments=0
        s.mods.lease.boundaries=function() return true end
        s.mods.lease.assess=function(_,from,steps)
          assessments=assessments+1
          return P.assess(from,steps)
        end
        if supply then
          s.row.service={kind="fuel",stage="travel",resume="scan",point={id="fuel",dim=0,x=5,y=1,z=4,side="down"},
            back=copy(s.row.turtle.pose)}
        else
          s.row.target={dim=s.job.dim,x=0,y=2,z=0,index=1}
          if failure=="turn" then s.row.tree=nil end
        end
        local failed=false
        for n=1,30 do
          s.tick(n)
          local q=assert(s.queued(),"lumber did not dispatch a prefix")
          equal(#q.steps,#P.boundary({steps=q.steps}).steps)
          local op=q.steps[#q.steps].op
          local inject=failure=="move" and P.moves[op] or failure=="turn" and P.turns[op]
          local results={}
          for i,step in ipairs(q.steps) do
            results[i]={ok=not step.op:match("^inspect")}
            if step.op=="inspectUp" and not supply then results[i]={ok=true,data={name="minecraft:oak_log",tags={["minecraft:logs"]=true}}} end
          end
          local before=copy(s.row.turtle.pose)
          if inject then results[#results]={ok=false,err="blocked"} end
          s.report(false,results)
          if inject then
            equal(s.queued(),nil,"failed boundary dispatched a remainder")
            equal(s.row.turtle.pose,before)
            equal(s.row.recover,true)
            assert(s.row.uncertain and #s.row.uncertain>0,"failed boundary lost its possible cells")
            s.tick(n+1)
            equal(s.queued().steps[1].op,"inspectDown")
            failed=true break
          end
        end
        assert(failed,"lumber did not reach the injected boundary")
        assert(assessments>0,"lumber skipped route assessment")
      end)
    end
  end
  test("lumber scan combines only acknowledged turn prefixes before using inspection results",function()
    local P=dofile("so-plan.lua")
    local s=setup("scan")
    s.row.tree=nil s.row.target={dim=s.job.dim,x=0,y=2,z=0,index=1}
    s.mods.lease.boundaries=function() return true end
    s.mods.lease.assess=function(_,from,steps) return P.assess(from,steps) end
    local before=copy(s.row.turtle.pose)
    s.tick(1)
    local prefixes=0
    while s.queued() and prefixes<10 do
      local q=s.queued()
      prefixes=prefixes+1
      equal(#q.steps,#P.boundary({steps=q.steps}).steps)
      local results={}
      for i,step in ipairs(q.steps) do results[i]={ok=not step.op:match("^inspect")} end
      s.report(false,results)
    end
    equal(prefixes,5)
    equal(s.row.turtle.pose,before)
    equal(s.row.target,nil)
  end)
  test('lumber SCAN is off by default and rejects the command without resetting a round', function()
    local s = scanner()
    s.input('scan')
    equal(s.job.scanRequested, nil)
    equal(s.job.visited, { true, true, true })
    equal(s.job.nextRound, 600000)
    for _, b in ipairs(s.draw(26, 20).buttons) do assert(b.id ~= 'scan') end
  end)

  test('lumber SCAN preserves an active claim through replanting then finds a new tree', function()
    local s = scanner(true)
    local tree = { x = 0, z = 0, kind = 'minecraft:oak_log' }
    local target = { dim = s.job.dim, x = 0, y = 2, z = 0, index = 1 }
    s.row.tree, s.row.target, s.row.phase = tree, target, 'base'
    s.row.inv = { { slot = 1, name = 'minecraft:oak_sapling', count = 1 } }
    s.job.spots['0,0'] = { kind = tree.kind }
    s.tick(1)
    local pending = s.row.pending
    s.tap('scan')
    s.tap('scan')
    s.tick(2)
    equal(s.row.pending, pending)
    equal(s.row.target, target)
    equal(s.row.tree, tree)
    equal(s.job.scanRequested, true)
    equal(s.job.visited, { true, true, true })
    s.report(false, { { ok = false } })
    s.tick(3)
    s.report(false, { { ok = false } })
    s.tick(4)
    s.tick(5)
    s.report(false, { { ok = true, data = { name = 'minecraft:oak_sapling' } } })
    equal(s.row.tree, nil)
    equal(s.job.scanRequested, true)
    s.tick(6)
    equal(s.job.scanRequested, nil)
    equal(s.job.nextRound, nil)
    equal(s.job.visited, {})
    s.report(false, { { ok = true }, { ok = false }, { ok = true }, { ok = true },
      { ok = false }, { ok = true }, { ok = true, data = { name = 'minecraft:oak_sapling' } } })
    for n = 7, 12 do
      s.tick(n)
      local q = s.queued()
      if q then
        if s.row.pending.action == 'scan' then
          s.report(false)
          break
        end
        local results = {}
        for i, step in ipairs(q.steps) do results[i] = { ok = not step.op:match('^inspect') } end
        s.report(false, results)
      end
    end
    equal(s.row.phase, 'base')
    equal(s.row.tree.x, 1)
    equal(s.row.tree.kind, 'minecraft:oak_log')
    equal(s.job.scanRequested, nil)
  end)

  test('lumber SCAN waits for blocked claims and keeps idle workers from claiming more cells', function()
    local s = scanner(true)
    local held = { x = 2, z = 0, kind = 'minecraft:birch_log' }
    s.job.turtles['3'] = { turtle = { id = 3, pose = { dim = s.job.dim, x = 2, y = 2, z = 0 } },
      tree = held, phase = 'base', blocked = 'lost', idlePark = true, parkAt = 0 }
    s.row.phase = 'scan'
    local release = 0
    s.mods.cells.releaseOwner = function() release = release + 1 end
    s.tap('scan')
    s.tick(1)
    equal(s.job.scanRequested, true)
    equal(s.job.turtles['3'].tree, held)
    equal(s.row.target, nil)
    equal(release, 0)
    equal(s.row.pending, nil)
    equal(s.row.idlePark, true)
  end)

  test('lumber SCAN waits for service and survives a server reload', function()
    local s = scanner(true)
    s.row.service = { kind = 'wood', stage = 'return', resume = 'waiting',
      back = s.row.turtle.pose, point = { x = 250, y = 1, z = 0, side = 'down' } }
    s.row.blocked = 'hold'
    s.tap('scan')
    local visited = s.job.visited
    s.tick(1)
    equal(s.job.scanRequested, true)
    equal(s.job.visited, visited)
    s.tick = assert(loadfile('so-mod-lumber.lua', 't', s.env))().tick
    s.tick(2)
    equal(s.job.scanRequested, true)
    s.report(false)
    s.row.blocked = nil
    s.tick(3)
    equal(s.row.service, nil)
    equal(s.job.scanRequested, true)
    s.tick(4)
    equal(s.job.scanRequested, nil)
    equal(s.row.phase, 'scan')
  end)

  test('lumber SCAN leaves a stopped job and existing alerts unchanged', function()
    local s = scanner(true)
    s.job.running, s.job.alert = false, 'saved hold'
    s.tap('scan')
    equal(s.job.scanRequested, nil)
    equal(s.job.running, false)
    equal(s.job.alert, 'saved hold')
    s.job.running = true
    s.tap('scan')
    equal(s.job.scanRequested, true)
    equal(s.job.alert, 'saved hold')
    equal(#s.events, 0)
  end)

  test('lumber SCAN finishes round-end cleanup before restarting the scan', function()
    local s = scanner(true)
    s.row.phase = 'roundEnd'
    s.tap('scan')
    s.tick(1)
    equal(s.job.scanRequested, true)
    equal(s.row.phase, 'waiting')
    s.tick(2)
    equal(s.job.scanRequested, nil)
    equal(s.job.nextRound, nil)
    equal(s.row.phase, 'scan')
    equal(s.row.pending.action, 'scan')
  end)

  test('lumber SCAN finds a bone-mealed tree beside the lane before its grow timer', function()
    local s = scanner(true)
    s.job.area.z2 = 2
    s.row.turtle.pose.z = 1
    s.job.spots['0,0'] = { kind = 'minecraft:oak_log', plantedAt = 1 }
    s.tap('scan')
    s.tick(1)
    equal(s.row.pending.action, 'scan')
    s.report(false, { { ok = true }, { ok = true, data = { name = 'minecraft:oak_log', tags = { ['minecraft:logs'] = true } } },
      { ok = true }, { ok = true }, { ok = false }, { ok = true }, { ok = false } })
    equal(#s.job.candidates, 1)
    equal(s.job.candidates[1].x, 0)
    equal(s.job.candidates[1].z, 0)
    equal(s.job.spots['0,0'].plantedAt, 1)
    s.tick(2)
    equal(s.row.target.x, 0)
    equal(s.row.target.z, 0)
    equal(s.row.probing, true)
  end)

  for _, size in ipairs({ { 26, 20 }, { 29, 12 } }) do
    test('lumber SCAN chip fits ' .. size[1] .. 'x' .. size[2] .. ' and queues one request per tap', function()
      local s = scanner(true)
      local frame, found = s.draw(size[1], size[2])
      for _, b in ipairs(frame.buttons) do
        if b.id == 'scan' then
          found = b
          equal(b.label, 'SCAN')
          assert(b.x >= 1 and b.x + b.w - 1 <= size[1] and b.y >= 1 and b.y <= size[2])
          assert(frame.rows[b.y].text:sub(b.x, b.x + b.w - 1):find('SCAN', 1, true))
          for _, other in ipairs(frame.buttons) do
            if other ~= b and other.y == b.y then assert(b.x + b.w <= other.x or other.x + other.w <= b.x) end
          end
        end
      end
      assert(found, 'SCAN chip missing')
      s.tap(found.id)
      equal(s.job.scanRequested, true)
      s.tick(1)
      equal(s.job.scanRequested, nil)
      s.report(false)
      s.tick(2)
      equal(s.job.scanRequested, nil)
    end)
  end

  test('lumber fuel estimates without a chest stay silent when fuel is sufficient', function()
    local s = setup('waiting', 1000)
    s.row.tree, s.job.nextRound = nil, 600000
    realDrops(s)
    s.mods.drops.pick = function() error('estimation must use read-only choose') end
    for n = 1, 10 do
      s.tick(n)
      if s.queued() then s.report(false) end
    end
    equal(#s.events, 0)
    equal(s.row.service, nil)
  end)

  test('lumber missing fuel service emits one alert across repeated ticks and retries', function()
    local s = setup('scan', 0)
    realDrops(s)
    s.mods.drops.pick = function() error('service must use read-only choose') end
    for n = 1, 10 do
      s.tick(n)
      if s.queued() then s.report(false) end
      s.row.blocked = nil
    end
    equal(#s.events, 1)
    equal(s.events[1].kind, 'lumber.alert')
    equal(s.events[1].data.text, 'no fuel chest set')
    equal(s.row.service, nil)
  end)

  test('lumber fuel alert resets after reload and refuel without START and alerts on the next outage', function()
    local s = setup('waiting', 0)
    s.row.tree, s.job.nextRound = nil, 600000
    realDrops(s)
    local emit, active, raised = s.mods.state.emit, nil, 0
    s.mods.state.emit = function(kind, data)
      emit(kind, data)
      if kind == 'lumber.alert' then
        active = data
        if data ~= false then raised = raised + 1 end
      end
    end
    s.mods.state.get = function(key) if key == 'lumber.alert' then return active end end
    s.tick(1)
    equal(raised, 1)
    equal(s.row.alert, 'no fuel chest set')
    s.tick(2)
    if s.queued() then s.report(false) end
    assert(s.mods.drops.add({ id = 'fuel', dim = 0, x = 0, y = 1, z = 0, side = 'down', kind = 'fuel' }))
    s.tick = assert(loadfile('so-mod-lumber.lua', 't', s.env))().tick
    s.tick(3)
    s.report(false)
    equal(s.row.blocked, nil)
    s.tick(4)
    equal(s.row.service.kind, 'fuel')
    equal(s.row.alert, nil)
    equal(active, false)
    s.report(false, { { ok = true, data = { name = 'minecraft:chest' } } })
    s.tick(5)
    s.row.inv = { { slot = 1, name = 'minecraft:coal', count = 8 } }
    s.report(false, { { ok = true }, { ok = true } })
    s.tick(6)
    equal(s.queued().steps[2].op, 'refuel')
    s.row.fuel, s.row.inv = 640, {}
    s.report(false, { { ok = true }, { ok = true } })
    s.tick(7)
    equal(s.row.service, nil)
    equal(s.row.alert, nil)
    equal(raised, 1)
    assert(s.mods.drops.remove('fuel'))
    s.row.fuel = 0
    s.tick(8)
    equal(raised, 2)
    equal(active.text, 'no fuel chest set')
    equal(active.id, s.row.turtle.id)
    s.tick(9)
    s.report(false)
    s.tick(10)
    equal(raised, 2)
  end)

  test('lumber stops after three failed base digs and names start on screen', function()
    local s = setup('base')
    for _ = 1, 3 do s.tick(1) s.report(false) s.tick(1) s.report(true) end
    assert(s.row.blocked, 'failed digs must hold')
    assert(s.row.alert:find('start', 1, true), 'hold must explain recovery')
    equal(s.events[#s.events].kind, 'lumber.alert')
    s.tick(2)
    equal(s.queued().steps[1].op, 'inspectDown')
    s.report(false)
    s.input('start')
    assert(not s.row.blocked and not s.row.failures, 'start must clear retry hold')
    s.tick(3)
    s.report(false)
    s.tick(4)
    s.report(false)
    s.tick(4)
    s.report(true)
    assert(not s.row.blocked, 'first new failure must not immediately hold')
  end)
  test('lumber reserves fuel for the actual chest distance', function()
    local s = setup('scan', 200)
    s.tick(1)
    assert(s.row.service and s.row.service.kind == 'fuel', '250 block fuel trip must start before 80 fuel')
  end)
  test('lumber clears junk when all inventory slots contain apples', function()
    local inv = {}
    for i = 1, 16 do inv[i] = { slot = i, name = 'minecraft:apple', count = 64 } end
    local s = setup('scan', 1000, inv)
    s.tick(1)
    local q = s.queued()
    assert(s.row.service and s.row.service.kind == 'wood', 'full junk inventory must be cleaned at wood chest')
  end)
  test('lumber stops after failed travel movement despite successful inspections', function()
    local s = setup('scan')
    s.row.tree = nil
    s.row.target = { dim = s.job.dim, x = 1, y = 2, z = 0 }
    for _ = 1, 3 do s.tick(1) s.report(false) s.tick(1) s.report(true) end
    assert(s.row.blocked, 'mob-blocked moves must hold')
    assert(s.row.alert:find('forward failed', 1, true))
  end)
  test('lumber stops after failed ascent digs and moves', function()
    for _, failedIndex in ipairs({ 1, 2 }) do
      local s = setup('climb')
      for _ = 1, 3 do
        s.tick(1)
        s.report(false, { { ok = true, data = { name = 'minecraft:oak_log', tags = { ['minecraft:logs'] = true } } } })
        s.tick(1)
        s.report(false, { { ok = failedIndex ~= 1 }, { ok = failedIndex ~= 2 } })
      end
      assert(s.row.blocked, 'failed ascent must hold')
    end
  end)

  test('lumber drops excess saplings but keeps one for each known spot', function()
    local s = setup('scan', 1000, { { slot = 1, name = 'minecraft:oak_sapling', count = 64 },
      { slot = 2, name = 'minecraft:birch_sapling', count = 8 } })
    s.job.spots = { ['0,0'] = { kind = 'minecraft:oak_log' }, ['1,0'] = { kind = 'minecraft:oak_log' } }
    s.row.service = { kind = 'wood', point = { id='wood',x=0,y=1,z=0,side='down' }, stage = 'drop' }
    s.tick(1)
    local q = s.queued()
    equal(q.steps[1].slot, 1)
    equal(q.steps[3].n, 62)
    equal(q.steps[3].op, 'dropDown')
    s.row.inv[1].count = 2
    s.report(false)
    s.tick(2)
    equal(s.queued().steps[1].slot, 2)
    equal(s.queued().steps[3].n, 8)
    s.report(true)
    assert(s.row.blocked, 'failed junk drop must hold instead of looping')
  end)

  test('lumber unloads a full log inventory during a climb', function()
    local inv = {}
    for i = 1, 16 do inv[i] = { slot = i, name = 'minecraft:oak_log', count = 64 } end
    local s = setup('climb', 1000, inv)
    s.tick(1)
    assert(s.row.service and s.row.service.kind == 'wood')
    equal(s.row.service.resume, 'climb')
  end)
  test('lumber clears a single junk stack at the end of a round', function()
    local s = setup('roundEnd', 1000, { { slot = 1, name = 'minecraft:stick', count = 1 } })
    s.tick(1)
    assert(s.row.service and s.row.service.kind == 'wood')
  end)


  test('S4-12 lumber has no fuel missing row without turtles',function()
    local s=setup('waiting')
    s.job.turtles={} s.job.running=false s.input('start')
    local message=s.events[#s.events].data.text
    assert(message:find('paired turtle missing',1,true))
    assert(not message:find('fuel missing',1,true))
  end)
  test('S4-10 lumber corner chips use paired poses and keep drafts per display',function()
    local s=controls(setup('waiting'),{jobPoseSetup=true})
    local a,b={id=10},{id=11}
    s.job.running=false
    s.press('setup',a)
    local found={}
    for _,button in ipairs(s.draw(26,20,a).buttons) do found[button.id]=true end
    assert(found['from-here'] and found['to-here'])
    s.press('from-here',a)
    local original=copy(s.job.area)
    s.row.turtle.pose={dim=s.job.dim,x=2,y=2,z=1,facing=1}
    s.press('to-here',b) equal(s.job.area,original)
    s.press('to-here',a) equal(s.job.area,{x1=0,x2=2,z1=0,z2=1}) equal(s.job.ground,1)
    s.row.turtle.pose.x=500 s.press('to-here',a)
    equal(s.job.area,{x1=0,x2=2,z1=0,z2=1})
    s.row.turtle.pose.x=3
    s.mods.lease.status=function() return {uncertain=true} end
    s.press('to-here',a) equal(s.job.area,{x1=0,x2=2,z1=0,z2=1})
    local off=controls(setup('waiting')) off.press('setup')
    for _,button in ipairs(off.draw(26,20).buttons) do assert(button.id~='from-here' and button.id~='to-here') end
  end)
  for _,reason in ipairs({'suspended','missing','broken','unreadable'}) do
    test('B8-F lumber keeps an automatic fuel retry held when its cached point is '..reason,function()
      local s=setup('waiting',0)
      s.row.tree=nil s.job.nextRound=600000
      s.row.blocked,s.row.fuelRetry='fuel',60000
      s.row.service={kind='fuel',stage='take',point={id='fuel',x=0,y=1,z=0,side='down'}}
      s.mods.shop={fuelConfig=function() return {auto=true} end}
      local checks=0
      s.mods.drops.usable=function(id) equal(id,'fuel') checks=checks+1 return false,reason end
      s.tick(59999) equal(checks,0)
      if s.queued() then s.report(false) end
      s.tick(60000) equal(checks,1) equal(s.row.blocked,'fuel') equal(s.row.service.stage,'take')
      assert(s.row.alert:find(reason,1,true)) equal(s.queued(),nil)
      s.tick(60001) equal(checks,1)
    end)
    test('B8-F lumber refuses an initial sapling service whose registered point is '..reason,function()
      local s=setup('plant')
      local point={id='saplings',dim=0,x=251,y=1,z=0,side='down',kind='storage'}
      s.mods.drops.list=function() return {point} end
      s.mods.drops.add=function() error('registered saplings should be reused') end
      s.mods.drops.usable=function(id) equal(id,'saplings') return false,reason end
      s.tick(1) equal(s.row.blocked,'hold') equal(s.row.service,nil) equal(s.queued(),nil)
      assert(s.row.alert:find(reason,1,true))
    end)
    for _,hasId in ipairs({false,true}) do
      test('B8-F lumber rejects '..reason..' saplings before a new restored attempt with ID '..tostring(hasId),function()
        local s=setup('plant')
        local point={id='saplings',dim=0,x=251,y=1,z=0,side='down',kind='storage'}
        s.mods.drops.list=function() return {point} end s.mods.drops.add=function() return true end
        s.mods.drops.usable=function(id) equal(id,'saplings') return false,reason end
        s.row.service={kind='saplings',stage='check',point={id=hasId and 'saplings' or nil,x=251,y=1,z=0,side='down'}}
        s.tick(1) equal(s.row.blocked,'hold') equal(s.queued(),nil)
        assert(s.row.alert:find(reason,1,true))
      end)
    end
  end
  test('B8-F lumber accepts usable saplings and does not interrupt a committed transfer or its return',function()
    local s=setup('plant')
    local checks=0
    s.mods.drops.usable=function() checks=checks+1 return true end
    local back=copy(s.row.turtle.pose)
    s.row.service={kind='saplings',stage='take',back=back,resume='plant',point={id='saplings',x=0,y=1,z=0,side='down'}}
    s.tick(1) local q=s.queued() assert(q and q.steps[2].op=='suckDown') equal(checks,1)
    s.mods.drops.usable=function() error('committed command or return revalidated') end
    s.tick(2) equal(s.queued(),q)
    s.row.inv={{slot=1,name='minecraft:oak_sapling',count=1}} s.report(false)
    s.row.service.stage='return' s.tick(3) equal(s.row.service,nil)
  end)

  test('B8-F lumber restarts a usable automatic fuel retry after backoff',function()
    local s=setup('waiting',0)
    s.row.tree=nil s.job.nextRound=600000
    s.row.blocked,s.row.fuelRetry='fuel',60000
    s.row.service={kind='fuel',stage='take',point={id='fuel',x=0,y=1,z=0,side='down'}}
    s.mods.shop={fuelConfig=function() return {auto=true} end}
    local checks=0
    s.mods.drops.usable=function(id) equal(id,'fuel') checks=checks+1 return true end
    s.tick(60000) equal(checks,2) equal(s.row.blocked,nil) equal(s.row.fuelRetry,nil)
    equal(s.row.service.stage,'check') assert(s.queued())
    equal(s.queued().steps[1].op,'inspectDown')
  end)

  for _,reason in ipairs({'suspended','missing','broken','unreadable'}) do
    for _,resume in ipairs({'reload','START'}) do
      test('review P1 lumber '..resume..' cannot resume a failed fuel take when its point is '..reason,function()
        local s=setup('waiting',0)
        s.row.tree=nil s.job.nextRound=600000
        local point={id='fuel',dim=0,x=0,y=1,z=0,side='down',kind='any'}
        local usable=true
        s.mods.drops.list=function() return {point} end
        s.mods.drops.usable=function(id) equal(id,'fuel') return usable,reason end
        s.mods.shop={fuelConfig=function() return {auto=true} end}
        s.job.saplings={x=point.x,y=point.y,z=point.z,side=point.side}
        s.row.service={kind='fuel',stage='take',point=point,back=copy(s.row.turtle.pose),resume='waiting'}
        s.tick(1) assert(s.queued() and s.queued().steps[2].op=='suckDown')
        s.report(true)
        equal(s.row.blocked,'fuel') equal(s.row.service.stage,'take')
        s.row.fuel=1000
        usable=false
        local sent={}
        local send=s.mods.lease.send
        s.mods.lease.send=function(id,steps,opts)
          sent[#sent+1]=copy(steps) return send(id,steps,opts)
        end
        if resume=='reload' then
          s.tick=assert(loadfile('so-mod-lumber.lua','t',s.env))().tick
        else s.input('start') equal(s.job.running,true) end
        s.tick(2) assert(s.row.pending and s.row.pending.action=='recover')
        s.report(false) equal(s.row.blocked,nil) equal(s.row.service.stage,'take')
        s.tick(3)
        equal(s.row.blocked,'fuel') assert(s.row.alert:find(reason,1,true))
        equal(s.row.service.stage,'take')
        for _,steps in ipairs(sent) do for _,step in ipairs(steps) do assert(step.op~='suck' and step.op~='suckDown') end end
      end)
    end
  end
  test('review P1 fuel commands already committed finish and refuel before returning from a suspended point',function()
    local s=setup('waiting',0)
    s.row.tree=nil s.job.nextRound=600000
    local back=copy(s.row.turtle.pose)
    s.row.service={kind='fuel',stage='take',point={id='fuel',x=0,y=1,z=0,side='down'},back=back,resume='waiting'}
    s.mods.drops.usable=function() return true end
    s.tick(1) local q=s.queued() assert(q and q.steps[2].op=='suckDown')
    s.mods.drops.usable=function() error('committed pickup or safe return was checked') end
    s.tick(2) equal(s.queued(),q)
    s.row.inv={{slot=1,name='minecraft:coal',count=1}} s.report(false)
    equal(s.row.service.stage,'refuel')
    s.tick(3) equal(s.queued().steps[2].op,'refuel')
    s.row.inv={} s.row.fuel=1000 s.report(false)
    equal(s.row.service.stage,'return')
    s.tick(4) equal(s.row.service,nil)
  end)
end
