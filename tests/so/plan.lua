local P = dofile("so-plan.lua")
local from = {dim="minecraft:overworld",x=0,y=0,z=0,facing=1}
return function(test,equal,section)
  if section~="build" then
  test("route assessment reports the first refusal in execution order with range facts",function()
    local steps={{op="turnRight"},{op="forward"},{op="dig"},{op="forward"}}
    local seen={}
    local check=P.assess(from,steps,{limit=24,admit=function(at,op,to)
      seen[#seen+1]={op,to.x,to.z}
      if op=="dig" then return false,"protected" end
      return true
    end})
    equal(check.first,3) equal(check.reason,"protected") equal(check.cell.z,2) equal(check.limit,24)
    equal(#seen,2)
    check=P.assess(from,{{op="forward"}},{limit=24,range=function() return false,25,24 end})
    equal({check.reason,check.distance,check.limit},{"range",25,24})
    check=P.assess(from,{{op="forward"}},{admit=function() return false,"held","mine:3" end})
    equal(check.holder,"mine:3")
    equal(P.assess({},steps).reason,"pose unknown")
  end)
  test("acknowledged boundary ends at the first move or turn and rebuilds its pose",function()
    for _,op in ipairs({"forward","back","up","down","turnLeft","turnRight"}) do
      local action={from=from,steps={{op="inspect"},{op=op},{op="dig"},{op="forward"}}}
      local prefix=P.boundary(action)
      equal(#prefix.steps,2) equal(#prefix.rest,2) equal(prefix.pose,P.apply(from,op))
      equal(#action.steps,4)
      local actual=P.apply(from,op)
      assert(P.confirm(from,prefix.steps,{{ok=false},{ok=true}},actual))
      equal(P.confirm(from,prefix.steps,{{ok=false},{ok=false}},from),false)
      actual.facing=(actual.facing+1)%4
      equal(P.confirm(from,prefix.steps,{{ok=false},{ok=true}},actual),false)
    end
  end)
  test("ordinary operation failures confirm the acknowledged pose boundary",function()
    for _,op in ipairs({"drop","suck","refuel","place","dig"}) do
      assert(P.confirm(from,{{op=op}},{{ok=false}},from),op)
      local actual=P.apply(from,"forward")
      assert(P.confirm(from,{{op=op},{op="forward"}},{{ok=false},{ok=true}},actual),op)
      equal(P.confirm(from,{{op=op},{op="forward"}},{{ok=false},{ok=false}},from),false)
    end
  end)
  test("range clipping retains boundary metadata and trims nested part poses",function()
    local part=P.path(from,{dim=from.dim,x=3,y=0,z=0,facing=1})
    part.first=1
    local action={kind="batch",from=from,boundary=true,steps={{op="forward"}},
      cells=part.cells,pose=part.pose,actions={part}}
    local out=assert(P.rangeBatch({inRange=function(_,p) return p.x<=1 end},2,action))
    equal(out.boundary,true) equal(out.from,from)
    equal(#out.steps,1) equal(#out.actions[1].steps,1)
    equal(out.pose,P.apply(from,"forward")) equal(out.actions[1].pose,out.pose)
    for _,p in ipairs(out.cells) do assert(p.x<=1) end
    equal(#part.steps,3) equal(part.pose.x,3)
    local boundary=P.boundary({from=from,steps=part.steps,actions={part}})
    equal(boundary.actions[1].pose,boundary.pose)
  end)

  local goal={dim=from.dim,x=2,y=1,z=2}
  local function assess(clear,admit)
    return function(at,steps,opts)
      return P.assess(at,steps,{clear=opts.clear and clear or nil,admit=admit})
    end
  end
  test("axis ranking keeps yxz first and orders safe alternatives by turns then the D3 list",function()
    local paths=P.rankPaths(from,goal,{alternateAxisOrders=true},assess(function() return true end))
    local orders={}
    for _,path in ipairs(paths) do orders[#orders+1]=path.order end
    equal(orders,{"yxz","xyz","xzy","yzx","zxy","zyx"})
    equal(paths[1].moves,5) equal(paths[1].turns,1) equal(paths[4].turns,2)
    local south={dim=from.dim,x=0,y=0,z=0,facing=2}
    local preferred=P.rankPaths(south,goal,{alternateAxisOrders=true},assess(function() return true end))
    equal(preferred[1].order,"yxz") equal(preferred[1].turns,2) equal(preferred[2].turns,1)
    paths=P.rankPaths(from,goal,{alternateAxisOrders=true},function(at,steps,opts)
      local path=P.path(at,goal)
      if #steps==#path.steps then return {ok=false,reason="protected"} end
      return assess(function() return true end)(at,steps,opts)
    end)
    equal(paths[1].order,"yzx")
  end)
  test("axis ranking is off by default and preserves the legacy yxz path",function()
    local paths=P.rankPaths(from,goal,{},assess(function() return true end))
    equal(#paths,1) equal(paths[1].order,"yxz") equal(paths[1].steps,P.path(from,goal).steps)
  end)
  test("axis ranking rejects unknown entered cells on every non-digging candidate",function()
    local paths,refusal=P.rankPaths(from,goal,{alternateAxisOrders=true},assess(function() return false end))
    equal(#paths,0) equal(refusal.reason,"unknown")
    paths=P.rankPaths(from,goal,{alternateAxisOrders=true,dig=true},assess(function() return false end))
    equal(#paths,6)
  end)
  test("axis ranking rejects inadmissible yxz and selects a known-clear alternative without writes",function()
    local calls=0
    local paths=P.rankPaths(from,goal,{alternateAxisOrders=true},assess(function() calls=calls+1 return true end,
      function(_,_,to) return not (to.x==0 and to.y==1 and to.z==0),"protected" end))
    equal(paths[1].order,"xyz") assert(calls>0)
    equal(from,{dim="minecraft:overworld",x=0,y=0,z=0,facing=1})
  end)
  test("axis ranking retains the first refusal and refuses an unknown start pose",function()
    local paths,refusal=P.rankPaths(from,goal,{alternateAxisOrders=true},assess(function() return true end,
      function() return false,"held","mine:7" end))
    equal(#paths,0) equal(refusal.reason,"held") equal(refusal.holder,"mine:7")
    paths,refusal=P.rankPaths({},goal,{alternateAxisOrders=true},function() error("assessed invalid pose") end)
    equal(#paths,0) equal(refusal.reason,"pose unknown")
  end)
  test("axis ranking with real assessments changes no files reservations or clear-cell cache",function()
    local s=dofile("tests/so/protected.lua").setup({alternateAxisOrders=true,pos=from})
    for x=0,2 do for y=0,1 do for z=0,2 do assert(s.cells.markDug(x,y,z,from.dim)) end end end
    local files=s.m.env.SO.store.copy(s.m.files)
    local counts=s.cells.counts()
    local bits=s.cells.dugBits(from.dim,0,0,0,true)
    assert(s.lease.assess(2,from,{}).ok)
    s.m.env.fs.open=function() error("ranking accessed disk") end
    s.cells.isDug=function() error("ranking touched clear-cell cache") end
    local paths=P.rankPaths(from,goal,{alternateAxisOrders=true},function(at,steps,opts)
      opts.owner="build" return s.lease.assess(2,at,steps,opts)
    end)
    equal(#paths,6) equal(s.m.files,files) equal(s.cells.counts(),counts)
    equal(s.cells.dugBits(from.dim,0,0,0,true),bits)
  end)
  else
  local fixture=dofile("tests/so/build-fixture.lua")
  local function storageBuilder(config)
    local f=fixture(config or {alternateAxisOrders=true})
    f.configure("floor",1,1,1) f.tick() f.report()
    f.saved.running=true
    f.saved.service={kind="storage",point={id="supply",dim=0,x=-3,y=0,z=2,side="down"},
      access={dim=from.dim,x=-3,y=1,z=2},stage="travel"}
    f.world["-3,0,2"]={name="minecraft:chest",stock=128}
    f.restart() f.report()
    for x=-4,1 do for y=0,5 do for z=0,2 do f.clear[x..","..y..","..z]=true end end end
    return f
  end
  local function heldSnapshot(f)
    return {owners=f.env.SO.store.copy(f.held),reserves=f.reserves or 0,releases=f.releases or 0}
  end
  test("builder storage ranking stays off by default and uses the legacy flight without clear marks",function()
    local f=storageBuilder({}) f.clear={}
    f.tick() assert(f.queued()) equal(f.job().blocked,nil)
    equal(f.queued().steps[1].op,"turnRight") assert(#f.queued().steps>1)
  end)
  test("builder storage trip dispatches only one fenced acknowledged move or turn",function()
    local f=storageBuilder()
    for _=1,3 do
      local before=f.job().turtle.pose
      f.tick() local q=assert(f.queued())
      equal(#q.steps,1) equal(q.steps[1].park,true) equal(q.opts.journal,f.journal)
      equal(q.opts.clear,true) equal(q.opts.intent.storageTrip,true)
      equal(f.job().turtle.pose,before)
      local calls=#f.calls f.tick() equal(#f.calls,calls)
      f.report() equal(f.job().turtle.pose,P.apply(before,q.steps[1].op))
    end
  end)
  test("builder storage trip takes material after acknowledged arrival and completes the build",function()
    local f=storageBuilder() f.run()
    local took=false
    for _,q in ipairs(f.calls) do
      if q.opts.intent.storageTrip then
        equal(#q.steps,#P.boundary({steps=q.steps}).steps)
        if q.opts.intent.action=="take" then
          local p=q.opts.intent.pose
          equal({p.x,p.y,p.z},{-3,1,2}) took=true
        end
      end
    end
    assert(took) equal(f.count(),1) equal(f.job().complete,true)
  end)
  test("builder storage trip waits for the fleet restart barrier without changing reservations or requiring START",function()
    local f=storageBuilder()
    f.restartReady=false
    local held,calls,job=heldSnapshot(f),#f.calls,f.job()
    for _=1,3 do f.tick() end
    equal(f.queued(),nil) equal(#f.calls,calls) equal(heldSnapshot(f),held) equal(f.job(),job)
    f.restartReady=true
    f.tick() assert(f.queued()) equal(f.job().blocked,nil)
  end)
  for _,reason in ipairs({"unknown","held","protected","range","lane","fuel"}) do
    test("builder unsafe storage candidates HOLD without reservation changes for "..reason,function()
      local f=storageBuilder()
      if reason=="unknown" then f.clear={}
      elseif reason=="held" then
        for k in pairs(f.clear) do if not f.held[k] then f.held[k]="mine:7" end end
      elseif reason=="protected" then f.assessmentError="protected"
      elseif reason=="range" then f.range=function() return false end
      elseif reason=="lane" then f.mods.mine={mapView=function() return {dim=from.dim,homeSet=true,
        home={x=-3,y=4,z=0,facing=1},bottom=0,branches=1,mode="fast"} end}
      else f.fuel=1 f.saved.fuel=1 f.restart() f.report() end
      local held,calls=heldSnapshot(f),#f.calls
      f.tick() equal(f.queued(),nil) equal(#f.calls,calls)
      assert(f.job().blocked) equal(heldSnapshot(f),held)
      f.tick() equal(heldSnapshot(f).owners,held.owners)
      equal(f.releases or 0,held.releases)
      if reason~="fuel" then equal(f.reserves or 0,held.reserves) equal(#f.calls,calls) end
    end)
  end
  for _,op in ipairs({"move","turn"}) do
    test("builder failed storage "..op.." keeps its pose and route until stationary recovery",function()
      local f=storageBuilder()
      if op=="move" then f.moveError="blocked" else f.turnError="blocked" end
      if op=="turn" then
        for _=1,8 do
          f.tick()
          if P.turns[f.queued().steps[1].op] then break end
          f.report()
        end
      end
      local before=f.job().turtle.pose
      f.tick() local q=assert(f.queued()) equal(#q.steps,1)
      assert(op=="move" and P.moves[q.steps[1].op] or op=="turn" and P.turns[q.steps[1].op])
      local held=heldSnapshot(f) f.report()
      equal(f.job().turtle.pose,before) equal(heldSnapshot(f),held)
      f.tick() equal(f.queued().steps,{{op="inspectDown",park=true}})
      for cell,who in pairs(held.owners) do equal(f.held[cell],who) end
      equal(f.releases or 0,held.releases)
    end)
  end
  for _,fact in ipairs({"journal","pose","setupFence"}) do
    test("builder storage trip holds an unconfirmed "..fact.." without releasing reservations",function()
      local f=storageBuilder()
      if fact=="setupFence" then
        f.setupFence=false
        local held=heldSnapshot(f) f.tick()
        equal(f.queued(),nil) equal(heldSnapshot(f),held) equal(f.job().blocked,"worker_safety")
      else
        local before=f.job().turtle.pose
        f.tick() local held=heldSnapshot(f)
        f.reportChange=function(_,facts,q)
          if fact=="journal" then facts.journal=q.opts.journal else facts.pose.f=(facts.pose.f+1)%4 end
        end
        f.report() equal(f.job().turtle.pose,before) equal(heldSnapshot(f),held)
        equal(f.job().blocked,"pose_uncertain")
      end
    end)
  end
  for _,terminal in ipairs({false,true}) do
    test("builder storage trip interrupted by restart resumes the "..(terminal and "acknowledged" or "open").." prefix without replay",function()
      local s=dofile("tests/so/protected.lua").setup({alternateAxisOrders=true,pos=from})
      s.manualOutcome=true
      s.m.install({"so-mod-build.lua","so-ui.lua","so-mine-plan.lua"})
      local SO=s.m.env.SO
      SO.mods.display={screen=function() end}
      SO.mods.state={emit=function() return true end,canStart=function() return true end}
      local job={dim=from.dim,cursor=1,running=true,phase="check",fuel=100,inv={},material="minecraft:stone",
        home=from,blueprint={shape="floor",dim=from.dim,x1=4,y1=-1,z1=0,x2=4,y2=-1,z2=0},
        turtle={id=2,pose=from,frame={dim=from.dim,ox=0,oy=0,oz=0,rot=0}},
        service={kind="storage",point={id="supply",dim=0,x=3,y=0,z=2,side="down"},
          access={dim=from.dim,x=3,y=1,z=2},stage="travel"}}
      local path="so-data/build/job"
      assert(SO.store.store(path,function() return true end).save(job))
      for x=0,3 do for y=0,1 do for z=0,2 do assert(s.cells.markDug(x,y,z,from.dim)) end end end
      local function loadBuilder()
        s.build=s.m.env.dofile("so-mod-build.lua") SO.mods.build=s.build
        s.build.handlers.hello({from=2,body={capabilities={parkBatch=true,setupFence=true}}})
      end
      local function saved() return SO.store.store(path,function() return true end).value end
      loadBuilder() s.build.tick() s.report({{ok=false,err="No block to inspect"}})
      s.build.tick() local q=s.sent[#s.sent].body
      equal(q.steps[1].op,"up") equal(#q.steps,1)
      local count=#s.sent
      if terminal then
        s.lease.onReport("build",function() end)
        s.report()
        equal(saved().turtle.pose.y,0) equal(s.lease.outcome(2).id,q.lease)
      end
      s.lease=s.m.env.dofile("so-mod-lease.lua") SO.mods.lease=s.lease s.hello()
      equal(s.lease.restartReady(),false)
      loadBuilder() s.build.tick() equal(#s.sent,count)
      if not terminal then s.report() end
      equal(saved().turtle.pose.y,1) equal(saved().leaseReceipt,q.lease..":reported")
      equal(s.lease.outcome(2),nil)
      equal(s.lease.restartReady(),false)
      s.build.tick() equal(#s.sent,count+1)
      equal(s.sent[#s.sent].body.steps[1].op,"inspectDown")
      equal(saved().turtle.pose.y,1)
      s.report({{ok=false,err="No block to inspect"}})
      equal(s.lease.restartReady(),true)
      equal(s.cells.owner(0,1,0,from.dim),"build:2")
      s.build.tick() equal(#s.sent,count+2)
      equal(s.sent[#s.sent].body.steps[1].op,"forward")
      s.report() equal(saved().turtle.pose.x,1) equal(saved().turtle.pose.y,1)
    end)
  end
  end
end
