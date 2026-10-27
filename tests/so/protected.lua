local H = dofile("tests/so/harness.lua")
local P = dofile("so-plan.lua")
local dim = "minecraft:overworld"
local F = {}
function F.setup(config, files)
  local n = H.new()
  local m = n.machine({id=1,modem=true})
  m.install({"so-store.lua","so-mod-cells.lua","so-mod-lease.lua","so-plan.lua"})
  config = config or {protectedAreas=true,pos={dim=dim,x=0,y=0,z=0}}
  m.files["so-server.cfg"] = H.encode(config)
  for path, value in pairs(files or {}) do m.files[path] = type(value)=="string" and value or H.encode(value) end
  local s = {m=m,n=n,sent={},now=0,serial=0,pose={dim=dim,x=0,y=0,z=0,facing=1}}
  local SO = {now=function() return s.now end,breathe=function() end,mods={},pair={key=function() return "paired" end},
    proto={build=function(_,kind,body) return {kind=kind,body=body} end,encode=function(v) return v end}}
  m.env.SO = SO
  SO.store = m.env.dofile("so-store.lua")
  m.env.rednet.send = function(_,wire) s.sent[#s.sent+1] = wire return true end
  s.cells = m.env.dofile("so-mod-cells.lua") SO.mods.cells = s.cells
  s.lease = m.env.dofile("so-mod-lease.lua") SO.mods.lease = s.lease
  s.hello = function(p, capabilities)
    s.pose = SO.store.copy(p or s.pose)
    s.lease.handlers.hello({from=2,body={role="turtle",fuel=s.fuel or 100,dim=dim,gps=s.pose,
      capabilities=capabilities or {parkBatch=true,setupFence=true},
      journal={id="j"..s.serial,pose={x=s.pose.x,y=s.pose.y,z=s.pose.z,f=s.pose.facing},recovery={outcome="anchored"}}}})
  end
  s.hello()
  s.cells.tick(0)
  s.box = function(id,x1,x2,y1,y2,z1,z2)
    return {id=id,dim=dim,x1=x1,x2=x2,y1=y1 or 0,y2=y2 or 0,z1=z1 or 0,z2=z2 or 0}
  end
  s.report = function(results, actual)
    local q = s.sent[#s.sent].body
    results = results or {}
    if #results == 0 then for i in ipairs(q.steps) do results[i]={ok=true} end end
    local p = s.pose
    for i, step in ipairs(q.steps) do if results[i].ok then p=P.apply(p,step.op) end end
    s.pose = actual or p
    s.serial = s.serial+1
    s.lease.handlers["step.report"]({from=2,body={lease=q.lease,results=results,
      pose={x=s.pose.x,y=s.pose.y,z=s.pose.z,f=s.pose.facing},journal="j"..s.serial,fuel=s.reportFuel or 100,inv=s.reportInv or {}}})
    if not s.manualOutcome then
      local outcome=s.lease.outcome(2)
      if outcome then assert(s.lease.ackOutcome(outcome.id)) end
    end
    return q
  end
  return s
end
function F.run(test,equal)
  test("lease delivers ordinary operation failures without a lost boundary",function()
    for _,op in ipairs({"drop","dropUp","dropDown","suck","suckUp","suckDown","refuel","place","placeUp","placeDown","dig","digUp","digDown"}) do
      local s=F.setup()
      local received
      s.lease.onReport("mine",function(_,_,results) received=results end)
      assert(s.lease.send(2,{{op=op}},{owner="mine",pose=s.pose}))
      s.report({{ok=false,err="operation failed"}})
      equal(received,{{ok=false,err="operation failed"}},op)
      equal(s.lease.status(2).boundaryHold,nil,op)
      assert(s.lease.send(2,{{op="forward"}},{owner="mine",pose=P.apply(s.pose,"forward")}))
    end
  end)
  test("protection activation checks each reservation holder once",function()
    local s=F.setup()
    for x=1,20 do assert(s.cells.reserve("mine:3",x,0,0,dim)) end
    local calls=0
    s.lease.peek=function() calls=calls+1 return {reconciled=true,pose=s.pose,journal="j"} end
    assert(s.cells.protect({}))
    equal(calls,1)
  end)
  test("mining fluid seal planner refuses a protected box edge",function()
    local s=F.setup()
    local M=dofile("so-mine-plan.lua")
    local goal={dim=dim,x=1,y=0,z=0,facing=1}
    local job={dim=dim,home={x=0,y=0,z=0,facing=1},bottom=-2,length=4,mode="fast"}
    local action=M.next(job,{pose=s.pose,goal=goal},function() return {name="minecraft:water",level=0} end,
      {{slot=1,name="minecraft:cobblestone",count=1}},100)
    equal(action.kind,"seal") equal(action.steps[2].op,"place")
    assert(s.cells.protect({s.box("edge",1,1)}))
    local check=s.lease.assess(2,s.pose,action.steps,{owner="mine"})
    equal(check.reason,"protected") equal(check.first,2) equal(check.cell.x,1)
    local lid,why=s.lease.send(2,action.steps,{owner="mine",pose=s.pose})
    equal(lid,nil) equal(why,"protected") equal(#s.sent,0)
  end)
  for _,kind in ipairs({"material","fuel","refuel","place"}) do
    test("builder handles failed "..kind.." operations with protection enabled",function()
      local f=dofile("tests/so/build-fixture.lua")({protectedAreas=true,builderFuelTrips=kind=="fuel" or kind=="refuel"})
      if kind=="fuel" then f.setPose({dim=dim,x=-3,y=1,z=0,facing=1}) end
      f.configure("floor",1,1,1)
      if kind=="fuel" then
        f.fuel=2 f.fuelChest=f.chest
      elseif kind=="refuel" then
        f.fuel=1 f.fuelChest=f.chest
        f.inventory[1]={name="minecraft:coal",count=1} f.refuelError=true
      elseif kind=="place" then
        f.inventory[1]={name="minecraft:stone",count=32} f.placeError=true
      end
      f.world["-3,0,0"].stock=0
      f.tick() f.report() f.input("start")
      for _=1,120 do
        f.tick() if f.queued() then f.report() end
        local j=f.job()
        if j.blocked then
          local alerts={material="out of material",fuel="fuel chest empty",refuel="fuel item rejected",place="placement failed"}
          equal(j.alert,alerts[kind])
          if kind=="material" or kind=="fuel" then
            equal(j.retryAt,f.now+10000) equal(j.service.stage,"check")
          end
          assert(j.blocked~="pose_uncertain")
          return
        end
      end
      error("builder never reached its normal failure handler")
    end)
  end
  test("builder planner refuses placement at a protected box edge",function()
    local f=dofile("tests/so/build-fixture.lua")({protectedAreas=true})
    f.configure("floor",1,1,1) f.inventory[1]={name="minecraft:stone",count=32}
    f.tick() f.report() f.input("start")
    for _=1,100 do
      f.tick()
      local q=f.queued()
      if q then
        local inspect=q.steps[#q.steps].op=="inspectDown" and not q.opts.recover
        f.report()
        if inspect and f.job().phase=="place" then
          f.protected={["0,0,0"]=true}
          f.tick()
          equal(f.queued(),nil) equal(f.job().alert,"protected") equal(f.count(),0)
          return
        end
      end
    end
    error("builder did not reach placement")
  end)
  test("builder completes a protected-area boundary route with acknowledged storage travel",function()
    local f=dofile("tests/so/build-fixture.lua")({protectedAreas=true})
    f.configure("floor",2,1,1) f.tick() f.report() f.input("start") f.run()
    equal(f.count(),2)
    for _,q in ipairs(f.calls) do equal(#q.steps,#P.boundary({steps=q.steps}).steps) end
  end)
  test("protected boxes normalize coordinates and dimensions and enforce their bound",function()
    local s=F.setup()
    local box=s.box("a",2,-2) box.dim="overworld"
    assert(s.cells.protect({box}))
    equal(s.cells.protected().boxes[1],s.box("a",-2,2))
    box.x1=0.5
    equal(s.cells.protect({box}),false)
    equal(s.cells.protect({s.box("a",0,1),s.box("a",2,3)}),false)
    local boxes={}
    for i=1,65 do boxes[i]=s.box(tostring(i),i,i) end
    equal(s.cells.protect(boxes),false)
    equal(s.cells.protected().revision,1)
  end)
  test("evicted clear-cell sections stay unknown during route assessment",function()
    local s=F.setup()
    for sx=0,256 do assert(s.cells.markDug(sx*16+1,0,0,dim)) end
    equal(s.cells.dugBits(dim,0,0,0,true),false)
    assert(s.lease.assess(2,s.pose,{}).ok)
    local open=s.m.env.fs.open
    s.m.env.fs.open=function() error("assessment loaded an evicted section") end
    s.cells.isDug=function() error("assessment touched the clear-cell cache") end
    equal(s.lease.assess(2,s.pose,{{op="forward"}},{clear=true}).reason,"unknown")
    equal(s.cells.dugBits(dim,0,0,0,true),false)
    s.m.env.fs.open=open
  end)
  test("protection activation waits for stationary reconciliation of saved reservations",function()
    local path="so-data/cells/minecraft%3aoverworld/0_0_0:0"
    local s=F.setup(nil,{["so-data/cells/res"]={schema=1,generation=1,value={[path]="mine:2"}}})
    equal(s.lease.assess(2,s.pose,{{op="forward"}}).reason,"reconcile protection first")
    assert(s.lease.send(2,{{op="inspectDown"}},{owner="mine",recover=true}))
    s.report({{ok=false,err="No block to inspect"}})
    s.cells.tick(0)
    assert(s.lease.assess(2,s.pose,{{op="forward"}},{owner="mine"}).ok)
  end)
  for _, supply in ipairs({false,true}) do
    for _,failure in ipairs({"move","turn"}) do
      test("builder "..(supply and "storage trip" or "work route").." holds after a failed "..failure.." boundary",function()
        local f=dofile("tests/so/build-fixture.lua")({protectedAreas=true})
        if failure=="turn" then f.setPose({dim=dim,x=-2,y=4,z=0,facing=0}) end
        f.configure("floor",2,1,1)
        if not supply then f.inventory[1]={name="minecraft:stone",count=32} end
        f.tick() f.report()
        f.input("start")
        local failed=false
        for _=1,60 do
          f.tick()
          local q=f.queued()
          if q then
          local op=q.steps[#q.steps].op
          if failure=="move" and P.moves[op] or failure=="turn" and P.turns[op] then
            equal(#q.steps,#P.boundary({steps=q.steps}).steps)
            local before=f.job().turtle.pose
            if failure=="move" then f.moveError="blocked" else f.turnError="blocked" end
            f.report()
            equal(f.queued(),nil)
            equal(f.job().turtle.pose,before)
            equal(f.job().blocked,"pose_uncertain")
            assert(next(f.held),"failed boundary released its reservations")
            f.tick()
            equal(f.queued().steps[1].op,"inspectDown")
            failed=true break
          end
          f.report()
          end
        end
        assert(failed,"builder did not reach the injected boundary")
        assert(f.assessments>0,"builder skipped route assessment")
      end)
    end
  end
  test("protected boxes refuse every move dig place and drop target and ordinary work from inside",function()
    for _, op in ipairs({"forward","back","up","down","dig","digUp","digDown","place","placeUp","placeDown","drop","dropUp","dropDown"}) do
      local s=F.setup()
      local target=P.target(s.pose,op)
      assert(s.cells.protect({s.box("build",target.x,target.x,target.y,target.y,target.z,target.z)}))
      local check=s.lease.assess(2,s.pose,{{op=op}},{owner="mine"})
      equal(check.reason,"protected") equal(check.first,1)
      local lid,why=s.lease.send(2,{{op=op}},{owner="mine",pose=target})
      equal(lid,nil) equal(why,"protected") equal(#s.sent,0)
      assert(s.cells.protect({s.box("start",0,0)}))
      assert(s.cells.admit("mine:2",s.pose,"inspectDown",s.pose))
      equal(s.lease.assess(2,s.pose,{{op=op}},{owner="mine"}).reason,"protected")
    end
  end)
  test("protection can be disabled and saved boxes remain available",function()
    local s=F.setup({protectedAreas=false,alternateAxisOrders=false,storageDeliveries=false,pos={dim=dim,x=0,y=0,z=0}})
    assert(s.cells.protect({s.box("build",1,1)}))
    assert(s.lease.send(2,{{op="forward"},{op="dig"}},{owner="mine"}))
    equal(s.cells.protected().boxes[1].id,"build")
  end)
  test("protected saves publish only after success and reject invalid or future data",function()
    local s=F.setup()
    local open=s.m.env.fs.open
    s.m.env.fs.open=function(path,mode) if path=="so-data/cells/protected.tmp" and mode=="w" then return nil end return open(path,mode) end
    equal(s.cells.protect({s.box("build",1,1)}),false)
    equal(s.cells.protected().revision,0)
    for _, value in ipairs({{v=2,revision=1,boxes={}},{v=1,revision=1,boxes={{id="bad"}}}}) do
      local broken=F.setup(nil,{["so-data/cells/protected"]={schema=1,generation=1,value=value}})
      local lid,why=broken.lease.send(2,{{op="forward"}},{pose={dim=dim,x=1,y=0,z=0,facing=1}})
      equal(lid,nil) equal(why,"protected data unreadable")
    end
  end)
  test("protection edits refuse open leases and unreconciled reservation owners",function()
    local s=F.setup()
    assert(s.lease.send(2,{{op="inspectDown"}}))
    equal(s.cells.protect({}),false)
    s.report({{ok=false}})
    assert(s.cells.reserve("mine:3",4,0,0,dim))
    local ok,why=s.cells.protect({}) equal(ok,false) equal(why,"reconcile reservations first")
  end)
  test("read-only route assessment never loads touches or saves clear-cell caches",function()
    local s=F.setup()
    assert(s.cells.markDug(1,0,0,dim)) s.cells.tick(0)
    assert(s.lease.assess(2,s.pose,{}).ok)
    s.now=61000
    local reads,writes,accesses=0,0,{}
    local read,open=s.m.env.fs.open,s.m.env.fs.open
    s.m.env.fs.open=function(path,mode)
      accesses[#accesses+1]=path.." "..mode
      if mode=="r" then reads=reads+1 else writes=writes+1 end return open(path,mode)
    end
    s.cells.isDug=function() error("assessment loaded the clear-cell cache") end
    local bits,stamp=s.cells.dugBits(dim,0,0,0,true)
    for _=1,5 do
      assert(s.lease.assess(2,s.pose,{{op="forward"}},{owner="mine",clear=true}).ok)
      equal(s.lease.assess(2,{dim=dim,x=16,y=0,z=0,facing=1},{{op="forward"}},{clear=true}).reason,"unknown")
    end
    equal({s.cells.dugBits(dim,0,0,0,true)},{bits,stamp})
    equal(reads,0,table.concat(accesses,",")) equal(writes,0,table.concat(accesses,","))
    s.m.env.fs.open=read
    s.cells.tick(1000)
    equal(writes,0)
  end)
  test("reviewed exits forbid second boxes and re-entry into departed overlapping boxes",function()
    local s=F.setup()
    assert(s.cells.protect({s.box("a",0,1),s.box("b",1,2)}))
    for x=0,4 do assert(s.cells.markDug(x,0,0,dim)) end
    local offer,why=s.lease.exitRequest(2,{{op="forward"},{op="forward"},{op="forward"}},7)
    equal(offer,nil) equal(why,"protected")
    assert(s.cells.protect({s.box("a",0,1),s.box("b",0,2)}))
    offer,why=s.lease.exitRequest(2,{{op="forward"},{op="forward"},{op="back"},{op="forward"},{op="forward"}},7)
    equal(offer,nil) equal(why,"protected")
    offer=s.lease.exitRequest(2,{{op="forward"},{op="forward"},{op="forward"}},7)
    assert(offer and offer.route) equal(#s.sent,0)
    assert(s.lease.exitRequest(2,offer.route.steps,7,offer.token))
    equal(#s.sent,1) equal(#s.sent[1].body.steps,1)
    s.report() s.report() s.report()
    equal(s.pose.x,3) equal(s.cells.owner(3,0,0,dim),"gps:2")
    equal(s.cells.owner(1,0,0,dim),nil)
  end)
  test("exit approval binds actor journal revision path and expires after 30 seconds",function()
    for _, change in ipairs({"actor","journal","revision","path","timeout"}) do
      local s=F.setup()
      assert(s.cells.protect({s.box("a",0,0)})) assert(s.cells.markDug(1,0,0,dim))
      local steps={{op="forward"}}
      local offer=assert(s.lease.exitRequest(2,steps,7))
      local actor=7
      if change=="actor" then actor=8
      elseif change=="journal" then s.serial=1 s.hello()
      elseif change=="revision" then assert(s.cells.protect({s.box("a",0,0)}))
      elseif change=="path" then steps={{op="turnRight"},{op="turnLeft"},{op="forward"}}
      else s.now=30001 end
      equal(s.lease.exitRequest(2,steps,actor,offer.token),nil)
      equal(#s.sent,0)
    end
  end)
  test("restart discards exit approval and retains the reserved path",function()
    local s=F.setup()
    assert(s.cells.protect({s.box("a",0,1)}))
    for x=1,2 do assert(s.cells.markDug(x,0,0,dim)) end
    s.cells.tick(0)
    local steps={{op="forward"},{op="forward"}}
    local offer=assert(s.lease.exitRequest(2,steps,7))
    assert(s.lease.exitRequest(2,steps,7,offer.token))
    local restarted=F.setup(nil,s.m.files)
    equal(#restarted.sent,0)
    equal(restarted.cells.owner(2,0,0,dim),"gps:2")
    equal(restarted.lease.status(2).open,s.sent[1].body.lease)
    equal(restarted.lease.send(2,{{op="inspectDown"}},{recover=true}),nil)
    restarted.now=70001 restarted.lease.tick(restarted.now)
    assert(restarted.lease.send(2,{{op="inspectDown"}},{recover=true}))
    restarted.report({{ok=false,err="No block to inspect"}})
    restarted.cells.tick(0)
    local before=#restarted.sent
    equal(restarted.lease.exitRequest(2,steps,7,offer.token),nil)
    equal(#restarted.sent,before)
  end)
  test("failed and expired exit boundaries cancel the remainder and retain the whole path",function()
    for _, fail in ipairs({"move","turn","pose","timeout"}) do
      local s=F.setup()
      assert(s.cells.protect({s.box("a",0,1)}))
      for x=1,2 do assert(s.cells.markDug(x,0,0,dim)) end
      local steps=fail=="turn" and {{op="turnRight"},{op="turnLeft"},{op="forward"},{op="forward"}}
        or {{op="forward"},{op="forward"}}
      local offer=assert(s.lease.exitRequest(2,steps,7))
      assert(s.lease.exitRequest(2,steps,7,offer.token))
      if fail=="timeout" then s.now=71001 s.lease.tick(s.now)
      elseif fail=="pose" then s.report(nil,{dim=dim,x=9,y=0,z=0,facing=1})
      else s.report({{ok=false,err="blocked"}}) end
      equal(#s.sent,1)
      equal(s.cells.owner(2,0,0,dim),"gps:2")
      equal(s.lease.status(2).boundaryHold,true)
    end
  end)
  test("exit refuses outside starts unknown cells digs transfers and insufficient fuel",function()
    local s=F.setup()
    local steps={{op="forward"}}
    equal(s.lease.exitRequest(2,steps,7),nil)
    assert(s.cells.protect({s.box("a",0,0)}))
    equal(select(2,s.lease.exitRequest(2,steps,7)),"unknown")
    assert(s.cells.markDug(1,0,0,dim))
    equal(select(2,s.lease.exitRequest(2,{{op="dig"},{op="forward"}},7)),"exit moves and turns only")
    equal(select(2,s.lease.exitRequest(2,{{op="suck"},{op="forward"}},7)),"exit moves and turns only")
    for _,fuel in ipairs({0,-1}) do
      s.fuel=fuel s.hello()
      equal(select(2,s.lease.exitRequest(2,steps,7)),"exit fuel unknown or insufficient")
    end
  end)
end
return F
