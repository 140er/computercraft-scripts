local fixture=dofile("tests/so/build-fixture.lua")
return function(test,equal)
  local function start(f)
    if f.job().fuel==nil then f.tick() f.report() end
    f.input("start")
  end
  test("builder expands floors walls and hollow boxes without duplicate cells",function()
    local f=fixture() local build=f.mod()
    for _,shape in ipairs({"floor","platform","wall","walls","box"}) do
      local cells=assert(build.expand({shape=shape,x1=0,y1=0,z1=0,x2=2,y2=2,z2=2}))
      local seen={}
      for _,p in ipairs(cells) do local k=p.x..","..p.y..","..p.z assert(not seen[k]) seen[k]=true end
      equal(#cells,(shape=="floor" or shape=="platform") and 9 or shape=="box" and 26 or 24)
      if shape=="box" then assert(not seen["1,1,1"]) end
    end
    equal(build.expand({shape="box",x1=0,y1=0,z1=0,x2=100,y2=100,z2=100}),nil)
  end)
  test("builder imports main floor and walls text with main height conventions",function()
    local build=fixture().mod()
    local floor=assert(build.import("builder floor 4 64 5 0 80 1 stone"))
    equal({floor.x1,floor.x2,floor.y1,floor.y2,floor.z1,floor.z2,floor.material},{0,4,63,63,1,5,"minecraft:stone"})
    local walls=assert(build.import("walls 0 64 0 2 64 2 3 stone"))
    equal({walls.y1,walls.y2,#assert(build.expand(walls))},{64,66,24})
    equal(build.import("clear 0 0 0 2 2 2"),nil)
  end)
  for _,case in ipairs({{"floor",5,1,5,25},{"box",3,3,3,26}}) do
    test("builder lease plan constructs exact " .. case[1],function()
      local f=fixture() f.configure(case[1],case[2],case[3],case[4]) start(f) f.run()
      equal(f.count(),case[5])
      for y=0,case[3]-1 do for z=0,case[4]-1 do for x=0,case[2]-1 do
        local k=x..","..y..","..z
        if case[1]=="floor" or x==0 or x==case[2]-1 or z==0 or z==case[4]-1 or y==0 or y==case[3]-1 then
          equal(f.world[k],"minecraft:stone") equal(f.placed[k],1)
        else equal(f.world[k],nil) end
      end end end
      for _,q in ipairs(f.calls) do assert(#q.steps<=16) end
    end)
  end
  test("builder waits for empty material chest and resumes after a timed refill",function()
    local f=fixture() f.configure("floor",5,1,5)
    f.world["-3,0,0"].stock=4 start(f)
    for _=1,1000 do f.tick() if f.queued() then f.report() end if f.job().blocked=="material" then break end end
    equal(f.count(),4) equal(f.job().alert,"out of material")
    f.world["-3,0,0"].stock=64
    f.now=f.now+10000 f.run()
    equal(f.count(),25)
  end)
  test("builder restart after unreported placement reconciles world without double placement",function()
    local f=fixture() f.configure("box",3,3,3) start(f)
    for _=1,1000 do
      f.tick()
      local q=f.queued()
      if q and q.steps[#q.steps].op=="placeDown" then f.report(true) break end
      if q then f.report() end
    end
    equal(f.count(),1) equal(f.job().cursor,1)
    f.restart() f.run() equal(f.count(),26)
    for _,n in pairs(f.placed) do equal(n,1) end
  end)
  test("builder refuses another job reservation and never breaks an occupied cell",function()
    local f=fixture() f.configure("floor",1,1,1) start(f)
    f.held["0,0,0"]="mine:7"
    for _=1,100 do f.tick() if f.queued() then f.report() end if f.job().blocked then break end end
    equal(f.count(),0) equal(f.held["0,0,0"],"mine:7") equal(f.job().blocked,"reservation")
    f.held["0,0,0"]=nil f.world["0,0,0"]="minecraft:diamond_block" f.input("start")
    for _=1,100 do f.tick() if f.queued() then f.report() end if f.job().blocked then break end end
    equal(f.count(),0) equal(f.world["0,0,0"],"minecraft:diamond_block") equal(f.job().alert,"build cell occupied")
  end)
  test("builder clips movement at proven radio range",function()
    local f=fixture() f.configure("floor",5,1,5) start(f)
    f.range=function(p) return p.x<0 end
    for _=1,100 do f.tick() if f.queued() then f.report() end if f.job().blocked then break end end
    equal(f.job().blocked,"range") equal(f.count(),0)
    for _,q in ipairs(f.calls) do if not q.opts.recover then assert(q.opts.pose.x<0) end end
  end)
  test("builder respects every mining lane facing",function()
    local P=dofile("so-plan.lua")
    for facing=0,3 do
      local f=fixture()
      local home={dim="minecraft:overworld",x=0,y=4,z=0,facing=facing}
      local top=P.apply(home,"forward")
      f.mods.mine={mapView=function() return {dim=home.dim,home=home,homeSet=true,bottom=0,mode="fast",branches=2} end}
      f.configure("floor",1,1,1)
      f.input("area "..top.x.." 0 "..top.z.." "..top.x.." 0 "..top.z)
      start(f)
      for _=1,100 do f.tick() if f.queued() then f.report() end if f.job().blocked then break end end
      equal(f.job().blocked,"reservation") equal(f.count(),0)
    end
  end)
  test("builder disk failure and uncertain poses dispatch no new work",function()
    local f=fixture() f.configure("floor",1,1,1)
    f.uncertain=true f.input("start") f.tick() equal(#f.calls,0)
    f.uncertain=false f.saveOK=false f.tick() equal(#f.calls,0)
  end)
  test("builder protects recovery routes and the whole running volume from dug retirement",function()
    local f=fixture() f.configure("floor",100,1,100)
    equal(f.mod().dugProtection(function() error("unknown recovery must refuse") end),false)
    f.tick() f.report() f.input("start")
    local boxes={}
    equal(f.mod().dugProtection(function(dim,value,margin) boxes[#boxes+1]={dim=dim,value=value,margin=margin} end),true)
    equal(#boxes,2) equal(boxes[2].value,{{x=0,y=0,z=0},{x=99,y=0,z=99}})
    equal(boxes[2].margin,1)
  end)
  test("builder resolved material alerts clear from the shared state",function()
    local f=fixture() f.configure("floor",1,1,1) f.world["-3,0,0"].stock=0 start(f)
    for _=1,100 do f.tick() if f.queued() then f.report() end if f.job().blocked=="material" then break end end
    equal(f.alert,"out of material")
    local cleared=false
    local emit=f.mods.state.emit
    f.mods.state.emit=function(kind,data)
      if kind=="build.alert" and data==false then cleared=true end
      return emit(kind,data)
    end
    f.world["-3,0,0"].stock=64 f.now=f.now+10000 f.run()
    assert(cleared,"material alert was not cleared")
    equal(f.alert,"build complete")
  end)
  test("builder setup state belongs to its display session",function()
    local f=fixture() local a,b={},{}
    f.press("setup",a)
    local function has(frame,id) for _,v in ipairs(frame.buttons) do if v.id==id then return true end end return false end
    assert(has(f.render(26,20,a),"shape-next")) assert(has(f.render(26,20,b),"tab:setup"))
    for _,size in ipairs({{26,20},{29,12}}) do
      for _,session in ipairs({a,b}) do
        local frame=f.render(size[1],size[2],session)
        local occupied={}
        for _,button in ipairs(frame.buttons) do
          assert(button.x>=1 and button.y>=1 and button.x+button.w-1<=size[1] and button.y+button.h-1<=size[2])
          local text=""
          for y=button.y,button.y+button.h-1 do
            text=text..frame.rows[y].text:sub(button.x,button.x+button.w-1)
            for x=button.x,button.x+button.w-1 do local k=x..","..y assert(not occupied[k]) occupied[k]=true end
          end
          assert(text:find(button.label,1,true),"button label is not drawn")
        end
      end
    end
  end)
  test("builder refuses workers that cannot park complete batches",function()
    local f=fixture() f.configure("floor",1,1,1)
    f.mod().handlers.hello({from=2,body={}})
    start(f)
    for _=1,100 do f.tick() if f.queued() then f.report() end if f.job().blocked then break end end
    equal(f.job().alert,"update worker for builder safety") equal(f.count(),0)
    for _,q in ipairs(f.calls) do assert(q.opts.recover) end
  end)
  test("builder stops if another planner assigns its worker",function()
    local f=fixture() f.configure("floor",1,1,1) f.tick() f.report()
    f.input("start")
    f.mods.lumber={mapView=function() return {turtle={id=2}} end}
    f.tick() equal(f.queued(),nil) equal(f.job().running,false)
    equal(f.job().alert,"turtle assigned to lumber")
  end)

  test("builder probes a dry worker and places after a manual refuel",function()
    local f=fixture() f.fuel=1 f.configure("floor",1,1,1) start(f)
    f.tick() f.fuel=0 f.report()
    f.tick()
    equal(f.job().intent.action,"fuel")
    equal(f.queued().steps,{{op="inspectDown",park=true}})
    local sent=#f.calls f.tick() equal(#f.calls,sent)
    f.fuel=5 f.report()
    equal(f.job().fuel,5) equal(f.job().blocked,nil) equal(f.alert,false)
    f.run() equal(f.count(),1) equal(f.world["0,0,0"],"minecraft:stone")
  end)
  test("builder keeps probing at zero fuel without moving and stops probing when stopped",function()
    local f=fixture() f.fuel=1 f.configure("floor",1,1,1) start(f)
    f.tick() f.fuel=0 f.report()
    for _=1,3 do
      f.tick() equal(f.queued().steps,{{op="inspectDown",park=true}}) f.report()
      equal(f.job().alert,"out of fuel") equal(f.job().blocked,"fuel")
    end
    equal(f.count(),0)
    f.input("stop") f.tick() equal(f.queued(),nil)
  end)
  test("builder fuel probe accepts unlimited fuel",function()
    local f=fixture() f.fuel=1 f.configure("floor",1,1,1) start(f)
    f.tick() f.fuel=0 f.report() f.tick() f.fuel="unlimited" f.report()
    equal(f.job().blocked,nil) f.run() equal(f.count(),1)
  end)
  for _,conflict in ipairs({"below","current"}) do
    test("builder resumes after refuelling with a fuel probe reservation conflict "..conflict,function()
      local f=fixture()
      f.setPose({dim="minecraft:overworld",x=0,y=1,z=0,facing=1})
      f.inventory[1]={name="minecraft:stone",count=2}
      f.configure("floor",2,1,1) start(f)
      for _=1,20 do
        f.tick() if f.queued() then f.report() end
        if f.count()==1 then break end
      end
      equal(f.count(),1)
      f.tick() equal(f.job().intent.action,"move")
      equal(f.queued().steps,{{op="up",park=true}})
      f.report(false,0)
      local pose=f.job().turtle.pose
      equal(pose.y,2)
      local below=pose.x..","..(pose.y-1)..","..pose.z
      local current=pose.x..","..pose.y..","..pose.z
      local held=conflict=="below" and below or current
      f.held[held]="mine:7"
      local reserveMany=f.mods.cells.reserveMany
      local reserved
      f.mods.cells.reserveMany=function(owner,cells)
        reserved=cells
        return reserveMany(owner,cells)
      end
      for _=1,2 do
        f.tick()
        equal(f.job().blocked,"fuel") equal(f.job().alert,"out of fuel")
        equal(#reserved,1) equal(reserved[1],pose)
        if conflict=="below" then
          equal(f.job().intent.action,"fuel")
          equal(f.queued().steps,{{op="inspectDown",park=true}})
          f.report()
        else equal(f.queued(),nil) end
        equal(f.job().blocked,"fuel") equal(f.job().alert,"out of fuel")
        equal(f.held[held],"mine:7") equal(f.count(),1)
      end
      f.mods.cells.reserveMany=reserveMany
      f.held[held]=nil f.fuel=5
      f.tick() equal(f.job().intent.action,"fuel") f.report()
      equal(f.job().blocked,nil) equal(f.job().fuel,5)
      f.run() equal(f.count(),2)
    end)
  end
  for _,case in ipairs({{0,"Movement obstructed","out of fuel","fuel"},
    {5,"Out of fuel","out of fuel","fuel"},{5,"Movement obstructed","path blocked; clear route","path"}}) do
    test("builder reports failed movement with fuel "..case[1].." and "..case[2],function()
      local f=fixture() f.configure("floor",1,1,1) f.tick() f.report() f.input("start")
      f.tick() equal(f.job().intent.action,"move")
      f.fuel,f.moveError=case[1],case[2] f.report()
      equal(f.job().alert,case[3]) equal(f.job().blocked,case[4])
      equal(f.count(),0)
    end)
  end
  test("builder replaces a forgotten worker while retaining its pending recovery cells",function()
    local f=fixture() f.configure("floor",1,1,1) f.tick() f.report() f.input("start")
    f.tick() equal(f.job().intent.action,"move")
    local old=f.mods.cells.list("build:2") assert(#old>1)
    assert(f.mod().forget(2)) equal(f.mod().assigned(2),false)
    f.report(true) f.restart()
    f.setPose({dim="minecraft:overworld",x=4,y=4,z=0,facing=3})
    f.input("add 3")
    equal(f.job().turtle.id,3) equal(f.job().alert,nil) equal(f.mod().assigned(3),true)
    f.mod().handlers.hello({from=3,body={capabilities={parkBatch=true}}})
    f.tick() f.report() f.restart() f.tick() f.report()
    equal(#f.mods.cells.list("build:2"),#old)
    for _,p in ipairs(old) do
      equal(f.held[p.x..","..p.y..","..p.z],"build:2")
      equal(f.mods.cells.reserveMany("build:3",{p}),false)
    end
  end)
  test("builder keeps an active worker and requires an explicit pose to re-add a forgotten worker",function()
    local f=fixture() f.configure("floor",1,1,1)
    f.input("add 3") equal(f.job().turtle.id,2)
    f.feedback("builder already has a turtle")
    assert(f.mod().forget(2)) f.input("add 2")
    f.feedback("add needs x y z n|e|s|w")
    f.input("add 2 -2 4 0 e") equal(f.job().turtle.forgotten,nil)
  end)

  local function ready(f)
    f.tick() assert(f.queued(),"recovery report missing") f.report()
  end
  local function step(f)
    f.tick() if f.queued() then return f.report() end
  end
  test("builder START names the missing storage chest without running or writing drop alerts",function()
    local f=fixture() f.configure("floor",1,1,1) ready(f)
    f.chest=nil
    f.input("start") equal(f.job().running,false) equal(f.job().alert,"no storage chest set")
    equal(f.count(),0)
    for _=1,4 do f.input("start") end
    equal(f.event,"build.alert")
  end)
  test("builder START refuses unknown and zero fuel and requires a certain pose and parkBatch",function()
    local f=fixture() f.configure("floor",1,1,1)
    local status=f.mods.lease.status
    f.mods.lease.status=function() local value=status() value.fuel=10000 return value end
    f.input("start") equal(f.job().running,false) equal(f.job().alert,"fuel unknown; wait for report")
    f.mods.lease.status=status
    ready(f)
    f.uncertain=true f.input("start") equal(f.job().running,false)
    f.feedback("paired turtle pose missing or uncertain")
    f.uncertain=false f.mod().handlers.hello({from=2,body={}})
    f.input("start") f.feedback("update worker for builder safety")
    f.mod().handlers.hello({from=2,body={capabilities={parkBatch=true}}})
    f.fuel=0 f.restart() ready(f) f.input("start")
    equal(f.job().running,false) f.feedback("out of fuel")
  end)
  test("builder material budget is unknown before a report and counts all matching stacks",function()
    local f=fixture() f.configure("floor",5,1,5)
    equal(f.mod().budget(),{total=25,remaining=25})
    f.inventory[1]={name="minecraft:stone",count=12}
    f.inventory[3]={name="minecraft:stone",count=4}
    f.inventory[4]={name="minecraft:dirt",count=7}
    ready(f) equal(f.mod().budget(),{total=25,remaining=25,carried=16})
    f.input("start")
    for _=1,100 do step(f) if f.count()==1 then break end end
    equal(f.mod().budget(),{total=25,remaining=24,carried=15})
    f.input("stop") f.input("material dirt")
    equal(f.job().cursor,2) equal(f.mod().budget(),{total=25,remaining=24,carried=7})
    f.restart() equal(f.mod().budget(),{total=25,remaining=24,carried=7})
  end)
  test("builder solid 3x3x3 places all 27 cells once with default-off geometry",function()
    local off=fixture()
    equal(off.mod().expand({shape="solid",x1=0,y1=0,z1=0,x2=2,y2=2,z2=2}),nil)
    local f=fixture({builderSolid=true}) f.configure("solid",3,3,3) ready(f)
    equal(#assert(f.mod().expand(f.job().blueprint)),27)
    f.input("start") f.run() equal(f.count(),27)
    for _,n in pairs(f.placed) do equal(n,1) end
    equal(f.world["1,1,1"],"minecraft:stone")
    f.input("stop") f.press("shape-next") equal(f.job().shape,"floor")
  end)
  test("builder material change preserves placed cells across restart",function()
    local f=fixture() f.configure("floor",2,1,1)
    f.inventory[1]={name="minecraft:stone",count=2} ready(f) f.input("start")
    for _=1,100 do step(f) if f.count()==1 then break end end
    f.input("stop") f.input("material dirt") equal(f.job().cursor,2)
    f.inventory[2]={name="minecraft:dirt",count=3}
    f.restart() ready(f) f.input("start") f.run()
    equal(f.world["0,0,0"],"minecraft:stone") equal(f.world["1,0,0"],"minecraft:dirt")
    equal(f.placed["0,0,0"],1) equal(f.placed["1,0,0"],1)
  end)
  test("builder add uses lease locate and failed delayed probes preserve the assignment",function()
    local f=fixture()
    f.input("area 0 0 0 0 0 0") f.input("material stone")
    local old=f.job().turtle
    f.deferLocate=true f.input("add 2")
    equal(f.located,{id=2,dim="minecraft:overworld"})
    equal(f.job().turtle,old)
    f.locateDone(nil,"GPS failed") equal(f.job().turtle,old) f.feedback("GPS failed")
    f.input("add 2")
    f.locateDone({dim="minecraft:overworld",x=7,y=8,z=9,facing=2})
    equal(f.job().turtle.pose,{dim="minecraft:overworld",x=7,y=8,z=9,facing=2})
  end)
  test("builder fuel 3 refuels from its chest before placing and survives restart",function()
    local f=fixture({builderFuelTrips=true})
    f.consumeFuel=true f.fuel=3
    f.fuelChest={id="fuel",kind="fuel",dim=0,x=-2,y=3,z=0,side="down"}
    f.world["-2,3,0"]={name="minecraft:chest",item="minecraft:coal",stock=8}
    f.configure("floor",1,1,1) ready(f) f.input("start")
    local refuelled=false
    for _=1,200 do
      f.tick()
      local q=f.queued()
      if q then
        local op=q.steps[#q.steps].op
        if op=="placeDown" then assert(refuelled,"placed before refuelling") end
        f.report()
        if op=="refuel" then refuelled=true end
      end
      if f.job().service and f.job().service.stage=="refuel" then f.restart() end
      if not f.job().running then break end
      assert(not f.job().blocked,f.job().alert)
    end
    assert(refuelled) equal(f.count(),1)
    assert(f.fuel>3)
  end)
  test("builder fuel trips stay off by default and missing fuel chest holds with its name",function()
    local f=fixture() f.fuel=3 f.configure("floor",1,1,1) ready(f) f.input("start") f.run()
    for _,q in ipairs(f.calls) do for _,s in ipairs(q.steps) do assert(s.op~="refuel") end end
    local enabled=fixture({builderFuelTrips=true}) enabled.configure("floor",1,1,1) ready(enabled)
    enabled.input("start") equal(enabled.job().running,false) equal(enabled.job().alert,"no fuel chest set")
  end)
  test("builder empty fuel chest retries on game time without placing",function()
    local f=fixture({builderFuelTrips=true}) f.fuel=3
    f.fuelChest={id="fuel",kind="fuel",dim=0,x=-2,y=3,z=0,side="down"}
    f.world["-2,3,0"]={name="minecraft:chest",item="minecraft:coal",stock=0}
    f.configure("floor",1,1,1) ready(f) f.input("start")
    for _=1,30 do step(f) if f.job().blocked then break end end
    equal(f.job().blocked,"fuel") equal(f.count(),0)
    local calls=#f.calls f.tick() equal(#f.calls,calls)
    f.world["-2,3,0"].stock=1 f.now=f.now+10000 f.run() equal(f.count(),1)
  end)
  test("builder unreachable fuel chest polls for manual refuel without moving",function()
    local f=fixture({builderFuelTrips=true}) f.fuel=3
    f.fuelChest={id="fuel",kind="fuel",dim=0,x=-20,y=3,z=0,side="down"}
    f.configure("floor",1,1,1) ready(f) f.input("start")
    step(f) equal(f.job().alert,"out of fuel") equal(f.count(),0)
    f.tick() equal(f.job().intent.action,"fuel") f.fuel=10000 f.report()
    f.run() equal(f.count(),1)
  end)

  test("builder paired worker START accepts its first recovery report",function()
    local f=dofile("tests/so/build-world-fixture.lua")()
    f.configure("floor",1,1,1)
    f.command("start")
    assert(f.job().running,tostring(f.job().alert))
    f.finish() equal(f.places,1)
  end)

  test("builder refused zero-fuel START accepts manual refuel and an authenticated hello",function()
    local f=dofile("tests/so/build-world-fixture.lua")()
    f.worker.fuel=0 f.configure("floor",1,1,1)
    equal(f.job().fuel,0) f.command("start")
    equal(f.job().running,false) equal(f.job().alert,"out of fuel")
    local sent=#f.worker.sent
    f.worker.fuel=10000 f.advance(31)
    local hello=false
    for i=sent+1,#f.worker.sent do
      local packet=f.worker.sent[i].payload
      if packet.t=="hello" and packet.body.fuel==10000 then hello=true end
    end
    assert(hello,"manual refuel did not reach an authenticated hello")
    equal(f.server.env.SO.mods.lease.status(2).fuel,10000)
    equal(f.job().fuel,0)
    f.command("start") assert(f.job().running,tostring(f.job().alert))
    equal(f.job().fuel,10000) f.finish() equal(f.places,1)
  end)
  test("builder real worker unlimited reports normalize minus one before START",function()
    local f=dofile("tests/so/build-world-fixture.lua")()
    f.worker.fuel="unlimited" f.configure("floor",1,1,1)
    equal(f.server.env.SO.mods.lease.status(2).fuel,-1)
    equal(f.job().fuel,"unlimited")
    f.command("start") assert(f.job().running,tostring(f.job().alert))
    f.finish() equal(f.places,1) equal(f.job().fuel,"unlimited")
  end)
  test("builder fuel 3 preserves three carried coal blocks and takes separate fuel",function()
    local f=fixture({builderFuelTrips=true}) f.fuel=3 f.consumeFuel=true
    f.fuelChest={id="fuel",kind="fuel",dim=0,x=-2,y=3,z=0,side="down"}
    f.world["-2,3,0"]={name="minecraft:chest",item="minecraft:coal",stock=8}
    f.configure("floor",1,1,1) f.input("material coal_block")
    f.inventory[1]={name="minecraft:coal_block",count=3}
    ready(f) f.input("start")
    local refuelled=false
    for _=1,100 do
      local q=step(f)
      if q and q.steps[#q.steps].op=="refuel" then
        assert(q.steps[1].slot~=1,"burned building material")
        equal(f.inventory[1].count,3)
        assert(f.world["-2,3,0"].stock<8,"fuel chest was untouched")
        refuelled=true break
      end
      assert(not f.job().blocked,f.job().alert)
    end
    assert(refuelled,"builder never refuelled") f.run()
    equal(f.inventory[1].count,2) equal(f.world["0,0,0"],"minecraft:coal_block")
  end)
  for _,legacy in ipairs({false,true}) do
    test("builder reconciles an unreported stone placement before changing to dirt after recovery"..(legacy and " from a legacy intent" or ""),function()
      local f=fixture() f.configure("floor",2,1,1)
      f.inventory[1]={name="minecraft:stone",count=3}
      f.inventory[2]={name="minecraft:dirt",count=3}
      ready(f) f.input("start")
      for _=1,100 do
        f.tick()
        local q=f.queued()
        if q and q.steps[#q.steps].op=="placeDown" then f.report(true) break end
        if q then f.report() end
      end
      equal(f.count(),1) equal(f.job().cursor,1)
      equal(f.job().placement.material,"minecraft:stone")
      if legacy then f.saved.placement=nil end
      f.restart() f.report()
      f.input("stop") f.input("material dirt")
      equal(f.job().cursor,2) equal(f.job().placement,nil) equal(f.job().material,"minecraft:dirt")
      f.input("start") f.run()
      equal(f.world["0,0,0"],"minecraft:stone") equal(f.world["1,0,0"],"minecraft:dirt")
      equal(f.placed["0,0,0"],1) equal(f.placed["1,0,0"],1)
    end)
  end

  test("B2-B facts are idle without a blueprint and omit unassigned turtle rows",function()
    local f=fixture()
    equal(f.mod().facts(),{state="idle",running=false,dim="minecraft:overworld",done=0,total=0})
    equal(f.mod().turtleView(),{})
    equal(f.mod().mapView(),{dim="minecraft:overworld",turtles={}})
  end)
  test("B2-B facts export inclusive bounds confirmed world pose and placement counts without mutation",function()
    local f=fixture() f.configure("floor",2,1,1)
    f.inventory[1]={name="minecraft:stone",count=3}
    f.tick() f.report() f.input("start")
    for _=1,100 do f.tick() if f.queued() then f.report() end if f.count()==1 then break end end
    local before,saves,calls=f.job(),f.saves,#f.calls
    f.env.SO.breathe=function() error("getter expanded geometry") end
    f.mods.lease.status=function() error("getter created a lease row") end
    local facts=f.mod().facts()
    equal({facts.state,facts.running,facts.done,facts.total},{"running",true,1,2})
    equal(facts.bounds,{dim="minecraft:overworld",x1=0,y1=0,z1=0,x2=1,y2=0,z2=0})
    equal(facts.pose,{dim="minecraft:overworld",x=0,y=1,z=0,f=1})
    facts.bounds.x1=999 facts.pose.x=999
    local turtles,map=f.mod().turtleView(),f.mod().mapView()
    equal(turtles["2"].done,1) equal(turtles["2"].pose.x,0)
    turtles["2"].pose.x=888 map.bounds.x1=888 map.turtles["2"].pose.x=888
    equal(f.mod().facts().pose.x,0) equal(f.mod().mapView().bounds.x1,0)
    equal(f.job(),before) equal(f.saves,saves) equal(#f.calls,calls)
    f.env.SO.breathe=function() end
  end)
  test("B2-B unknown lost and uncertain poses omit map markers but retain bounds",function()
    local f=fixture() f.configure("floor",1,1,1)
    equal(f.mod().facts().state,"recovering") equal(f.mod().facts().pose,nil)
    equal(f.mod().mapView().turtles,{}) assert(f.mod().mapView().bounds)
    f.tick() f.report() assert(f.mod().mapView().turtles["2"])
    for _,field in ipairs({"lost","uncertain"}) do
      f[field]=true
      equal(f.mod().facts().pose,nil) equal(f.mod().mapView().turtles,{})
      assert(f.mod().mapView().bounds)
      f[field]=false
    end
    f.saved.turtle.pose=nil f.restart(true)
    equal(f.mod().facts().pose,nil) equal(f.mod().mapView().turtles,{})
  end)
  test("B2-B invalid commands preserve holds and command feedback never becomes a hold",function()
    local f=fixture() f.configure("floor",1,1,1) f.tick() f.report()
    f.saved.blocked,f.saved.alert="path","clear the obstruction"
    f.restart(true)
    local before,saves=f.job(),f.saves
    for _,command in ipairs({"typo","area bad 0 0 1 1 1","add nope"}) do
      f.input(command)
      equal(f.job(),before) equal(f.saves,saves)
      equal(f.mod().facts().alert.key,"build:path")
    end
    f.feedback("invalid turtle")
    local empty=fixture() empty.input("start")
    empty.feedback("configure area, material, turtle")
    equal(empty.mod().facts().alert,nil) equal(empty.mod().facts().state,"idle")
  end)
  test("B2-B configure refusals during work leave the active job and hold unchanged",function()
    local f=fixture() f.configure("floor",1,1,1) f.tick() f.report() f.input("start")
    local before=f.job()
    f.input("shape walls") f.feedback("stop before configuring")
    equal(f.job(),before) equal(f.mod().facts().alert,nil)
    equal(f.mod().facts().state,"running")
  end)
  test("B2-B completion has no hold and resets to stopped after a new blueprint",function()
    local f=fixture() f.configure("floor",1,1,1) f.tick() f.report() f.input("start") f.run()
    local facts=f.mod().facts()
    equal({facts.state,facts.done,facts.total,facts.running},{"complete",1,1,false})
    equal(facts.alert,nil) equal(f.job().blocked,nil)
    f.input("area 0 0 0 1 0 0") equal(f.mod().facts().state,"stopped")
    equal(f.mod().facts().done,0)
  end)
  test("B2-B legacy generic holds survive recovery without severity inference or automatic resume",function()
    local f=fixture() f.configure("floor",1,1,1)
    f.saved.blocked,f.saved.alert,f.saved.running="hold","out of fuel; pose uncertain",true
    f.restart() f.report()
    equal(f.mod().facts().state,"held") equal(f.mod().facts().alert,nil)
    local calls=#f.calls
    for _=1,5 do f.tick() end
    equal(#f.calls,calls) equal(f.job().blocked,"hold")
    f.input("start") equal(f.job().blocked,nil) equal(f.mod().facts().state,"running")
  end)
  test("B2-B legacy named causes normalize without parsing diagnostic text",function()
    for old,new in pairs({["pose uncertain"]="pose_uncertain",["device forgotten"]="device_forgotten",
      cells="reservation",lane="reservation",fuelStock="fuel"}) do
      local f=fixture() f.configure("floor",1,1,1)
      f.saved.blocked,f.saved.alert=old,"unrelated diagnostic"
      f.restart(true)
      equal(f.mod().facts().state,"held") equal(f.mod().facts().alert.key,"build:"..new)
    end
  end)
  test("B2-B forgotten builders expose replacement setup while omitting the assigned turtle",function()
    local f=fixture() f.configure("floor",1,1,1) f.tick() f.report()
    assert(f.mod().forget(2))
    equal(f.mod().facts().alert.key,"build:device_forgotten")
    equal(f.mod().facts().alert.actions,{"setup"})
    equal(f.mod().turtleView(),{}) equal(f.mod().mapView().turtles,{})
    assert(f.mod().facts().bounds)
  end)


  test("B2-B save failure exposes its safety cause without a durable write",function()
    local f=fixture() f.configure("floor",1,1,1) f.tick() f.report()
    local before=f.job()
    f.saveOK=false f.input("material dirt")
    equal(f.mod().facts().alert.key,"build:save") equal(f.mod().facts().state,"held")
    equal(f.job(),before) equal(f.queued(),nil)
  end)
  test("B2-B transient feedback expires and reveals the existing hold after five seconds",function()
    local f=fixture() f.configure("floor",1,1,1)
    f.saved.blocked,f.saved.alert="path","clear the obstruction" f.restart(true)
    f.input("typo") f.feedback("invalid command")
    f.now=f.now+5000 f.feedback("clear the obstruction")
    equal(f.mod().facts().alert.key,"build:path")
  end)
  test("B2-B operational reservation and occupied-cell failures expose distinct safety causes",function()
    local f=fixture() f.configure("floor",1,1,1) f.tick() f.report() f.input("start")
    f.held["0,0,0"]="mine:7"
    for _=1,100 do f.tick() if f.queued() then f.report() end if f.job().blocked then break end end
    equal(f.mod().facts().alert.key,"build:reservation")
    f.held["0,0,0"]=nil f.world["0,0,0"]="minecraft:diamond_block" f.input("start")
    for _=1,100 do f.tick() if f.queued() then f.report() end if f.job().blocked then break end end
    equal(f.mod().facts().alert.key,"build:cell_occupied") equal(f.world["0,0,0"],"minecraft:diamond_block")
  end)


  test("B2-B completed legacy cursors clear stale holds in BUILD and every adapter",function()
    local f=fixture() f.configure("floor",1,1,1)
    f.saved.cursor,f.saved.blocked,f.saved.alert=2,"hold","build complete"
    f.restart(true)
    equal(f.mod().facts().state,"complete") equal(f.mod().facts().alert,nil)
    equal(f.mod().turtleView()["2"].error,nil)
    equal(f.job().blocked,nil) equal(f.job().alert,nil)
  end)


  test("B2-B failed completion save stays held until the completion is durable",function()
    local f=fixture() f.configure("floor",1,1,1)
    f.inventory[1]={name="minecraft:stone",count=1}
    f.tick() f.report() f.input("start")
    for _=1,100 do
      f.tick()
      local q=f.queued()
      if q and q.steps[#q.steps].op=="placeDown" then f.saveOK=false f.report() break end
      if q then f.report() end
    end
    equal(f.count(),1) equal(f.mod().facts().state,"held")
    equal(f.mod().facts().alert.key,"build:save") equal(f.job().cursor,1)
    f.saveOK=true f.tick()
    equal(f.mod().facts().state,"complete") equal(f.mod().facts().alert,nil)
    equal(f.job().cursor,2) equal(f.job().blocked,nil)
  end)


  for _,cause in ipairs({"storage_missing","storage_access","dimension_mismatch"}) do
    test("B2-B fuel planning records its explicit "..cause.." cause",function()
      local f=fixture({builderFuelTrips=true}) f.configure("floor",1,1,1)
      f.tick() f.report()
      f.fuelChest={id="fuel",kind="fuel",dim=0,x=-3,y=0,z=0,side="front"}
      f.input("start") assert(f.job().running)
      if cause=="storage_missing" then f.fuelChest=nil
      elseif cause=="dimension_mismatch" then f.fuelChest.dim=-1
      else
        for _,p in ipairs({{-3,0,-1},{-2,0,0},{-3,0,1},{-4,0,0}}) do
          f.held[table.concat(p,",")]="mine:7"
        end
      end
      f.tick()
      equal(f.mod().facts().alert.key,"build:"..cause)
      equal(f.queued(),nil) equal(f.count(),0)
    end)
  end


  for _,restart in ipairs({false,true}) do
    test("B2-B legacy operator hold survives expired recovery and a successful probe"..(restart and " across another restart" or ""),function()
      local f=fixture() f.configure("floor",1,1,1)
      f.saved.blocked,f.saved.alert,f.saved.running="hold","operator review required",true
      f.restart()
      equal(f.queued().opts.recover,true)
      equal(f.queued().steps,{{op="inspectDown",park=true}})
      f.expire()
      equal(f.job().blocked,"lost") equal(f.job().legacyHold,"operator review required")
      if restart then f.restart() else f.tick() end
      equal(f.queued().opts.recover,true)
      equal(f.queued().steps,{{op="inspectDown",park=true}})
      f.lost=false f.report()
      equal(f.job().blocked,"hold") equal(f.job().alert,"operator review required")
      equal(f.mod().facts().state,"held") equal(f.mod().facts().alert,nil)
      local calls=#f.calls
      for _=1,100 do f.tick() end
      equal(#f.calls,calls) equal(f.count(),0)
      f.input("typo") equal(f.job().legacyHold,"operator review required")
      f.input("stop") f.input("material dirt") equal(f.job().blocked,nil)
      equal(f.job().legacyHold,"operator review required") equal(f.mod().facts().state,"held")
      f.tick() equal(#f.calls,calls)
      local chest=f.chest f.chest=nil f.input("start")
      equal(f.job().legacyHold,"operator review required") f.chest=chest
      f.input("start") equal(f.job().legacyHold,nil) equal(f.job().blocked,nil)
      f.tick() assert(f.queued()) equal(f.queued().opts.recover,false)
    end)
  end
  for _,kind in ipairs({"material","fuel"}) do
    test("B2-B unresolved "..kind.." NEEDS stays active through pending inspection transfer and confirmed resolution",function()
      local f=fixture({builderFuelTrips=kind=="fuel"})
      if kind=="fuel" then
        f.fuel=3
        f.fuelChest={id="fuel",kind="fuel",dim=0,x=-2,y=3,z=0,side="down"}
        f.world["-2,3,0"]={name="minecraft:chest",item="minecraft:coal",stock=0}
      else f.world["-3,0,0"].stock=0 end
      f.configure("floor",1,1,1) ready(f) f.input("start")
      for _=1,200 do
        step(f)
        if f.job().blocked==kind and f.job().retryAt then break end
      end
      equal(f.job().blocked,kind) assert(f.job().retryAt)
      local health=assert(loadfile("so-mod-health.lua","t",f.env))()
      local function held()
        local facts=f.mod().facts()
        equal(facts.alert.key,"build:"..kind)
        local rows=health.attention({now=f.now,disk={},build=facts})
        equal(#rows,1) equal(rows[1].key,"build:"..kind)
      end
      held()
      local calls=#f.calls
      f.tick() equal(#f.calls,calls) held()
      f.now=f.job().retryAt f.tick()
      equal(f.job().intent.action,"supplyCheck") held()
      f.now=f.now+6000 f.tick() held()
      f.report() held()
      f.tick() equal(f.job().intent.action,"take") held()
      f.now=f.now+6000 f.tick() held()
      f.report() held()
      local chest=kind=="fuel" and f.world["-2,3,0"] or f.world["-3,0,0"]
      chest.stock=64
      f.now=f.job().retryAt f.tick() held() f.report() held()
      f.tick() equal(f.job().intent.action,"take") held()
      f.report()
      if kind=="fuel" then
        held() f.tick() equal(f.job().intent.action,"refuel") held()
        f.now=f.now+6000 f.tick() held() f.report()
      end
      equal(f.mod().facts().alert,nil) equal(f.job().blocked,nil) equal(f.job().retryAt,nil)
      f.run() equal(f.count(),1)
    end)
  end
  local refusals={
    {"DISK events pending","save"},{"pose uncertain","pose_uncertain"},{"pose","pose_uncertain"},
    {"lost","lost"},{"send","lost"},{"busy","assignment_conflict"},{"no key","device_forgotten"},
    {"update remote worker","worker_safety"},{"invalid dimension","dimension_mismatch"},
    {"remote dimensions disabled","dimension_mismatch"},
    {"worker dimension mismatch; set so-worker.cfg","dimension_mismatch"},
    {"Nether bedrock boundary","dimension_mismatch"},{"End void or height boundary","dimension_mismatch"},
    {"id","path"},{"owner","path"},{"steps","path"},{"opts","path"},
    {"ms","path"},{"size","path"},{"unrecognized refusal","path"},
  }
  for _,case in ipairs(refusals) do
    test("B2-B lease refusal "..case[1].." has cause "..case[2],function()
      local f=fixture() f.configure("floor",1,1,1) ready(f) f.input("start")
      f.sendError=case[1] f.tick()
      equal(f.queued(),nil) equal(f.mod().facts().alert.key,"build:"..case[2])
      equal(f.job().alert,"lease "..case[1]) equal(f.job().intent,nil) equal(f.count(),0)
    end)
  end
  test("B2-B real lease disk refusal exposes the save cause without requesting a worker update",function()
    local f=dofile("tests/so/build-world-fixture.lua")()
    f.configure("floor",1,1,1)
    f.server.env.SO.mods.state.canWork=function() return false end
    f.command("start")
    for _=1,20 do f.advance(0.1) if f.job().blocked then break end end
    equal(f.job().alert,"lease DISK events pending")
    equal(f.server.env.SO.mods.build.facts().alert.key,"build:save") equal(f.places,0)
  end)


  test("B2-B partial fuel refill retains NEEDS until confirmed fuel covers the planned trip",function()
    local f=fixture({builderFuelTrips=true}) f.fuel=3
    f.fuelChest={id="fuel",kind="fuel",dim=0,x=-2,y=3,z=0,side="down"}
    local chest={name="minecraft:chest",item="minecraft:coal",stock=0}
    f.world["-2,3,0"]=chest
    f.configure("floor",1,1,1) f.input("area 100 0 0 100 0 0") ready(f) f.input("start")
    for _=1,100 do step(f) if f.job().retryAt then break end end
    equal(f.job().blocked,"fuel") assert(f.job().retryAt)
    chest.stock=1 f.now=f.job().retryAt
    for _,action in ipairs({"supplyCheck","take","refuel"}) do
      f.tick() equal(f.job().intent.action,action)
      equal(f.mod().facts().alert.key,"build:fuel") f.report()
    end
    equal(f.job().fuel,83) equal(f.mod().facts().alert.key,"build:fuel")
    chest.stock=64
    for _,action in ipairs({"take","refuel"}) do
      f.tick() equal(f.job().intent.action,action)
      equal(f.mod().facts().alert.key,"build:fuel") f.report()
    end
    equal(f.job().blocked,nil) equal(f.mod().facts().alert,nil)
    assert(f.job().fuel>200) equal(f.job().retryAt,nil)
  end)

  local function returningBuilder(options)
    local f=fixture(options)
    f.configure("floor",1,1,1)
    f.inventory[1]={name="minecraft:stone",count=1}
    ready(f) f.input("return on") equal(f.job().returnHome,true)
    f.input("start")
    for _=1,100 do
      step(f)
      if f.job().completion then break end
    end
    equal(f.count(),1) equal(f.job().cursor,2)
    equal(f.job().completion.phase,"returning") equal(f.job().complete,false)
    return f
  end
  test("B4-B opt-in return uses acknowledged non-digging move and turn prefixes with certain pose and facing",function()
    local f=returningBuilder()
    local P=dofile("so-plan.lua")
    local moves,turns=0,0
    while not f.job().complete do
      local before=f.job().turtle.pose
      f.tick()
      local q=assert(f.queued(),f.job().alert)
      equal(#q.steps,1) equal(q.steps[1].park,true) equal(q.opts.journal,f.journal)
      local op=q.steps[1].op
      assert(P.moves[op] or P.turns[op],op)
      if P.moves[op] then moves=moves+1 else turns=turns+1 end
      local calls=#f.calls
      f.tick() f.tick() equal(#f.calls,calls) equal(f.job().turtle.pose,before)
      f.report()
      equal(f.job().turtle.pose,P.apply(before,op))
      if P.samePose(f.job().turtle.pose,f.job().home) then f.tick() break end
    end
    assert(moves>0 and turns>0)
    equal(f.job().turtle.pose,f.job().home) equal(f.job().completion.phase,"complete")
    equal(f.mod().facts().state,"complete") equal(f.alert,"build complete")
  end)
  for _,op in ipairs({"move","turn"}) do
    test("B4-B failed return "..op.." holds reservations and never dispatches the old remainder",function()
      local f=returningBuilder()
      f.tick()
      if op=="turn" then
        while not f.queued().steps[1].op:match("^turn") do f.report() f.tick() end
      end
      local before,held=f.job().turtle.pose,f.mods.cells.list("build:2")
      if op=="move" then f.moveError="Movement obstructed" else f.turnError="Turn failed" end
      local q=f.report()
      equal(f.job().blocked,"path") equal(f.job().turtle.pose,before)
      equal(f.mods.cells.list("build:2"),held) equal(f.job().complete,false)
      f.tick() equal(f.queued().opts.recover,true)
      equal(f.queued().steps,{{op="inspectDown",park=true}})
      assert(f.queued().id~=q.id)
      f.report() equal(f.job().blocked,"path")
      local calls=#f.calls
      for _=1,5 do f.tick() end
      equal(#f.calls,calls) equal(f.job().completion.phase,"returning")
      f.moveError,f.turnError=nil,nil f.input("start") f.run()
      equal(f.job().turtle.pose,f.job().home) equal(f.count(),1)
    end)
  end
  for _,kind in ipairs({"reservation","protected","range","fuel"}) do
    test("B4-B blocked return retains the occupied reservation for "..kind,function()
      local f=returningBuilder()
      local before=f.job().turtle.pose
      local occupied=before.x..","..before.y..","..before.z
      local held=f.mods.cells.list("build:2")
      if kind=="reservation" then f.held["0,2,0"]="mine:7"
      elseif kind=="protected" then f.protected={["0,2,0"]=true}
      elseif kind=="range" then f.range=function() return false end
      else f.saved.fuel=0 f.fuel=0 f.restart() f.report() end
      local calls=#f.calls
      f.tick() equal(#f.calls,calls) equal(f.queued(),nil)
      equal(f.job().complete,false) equal(f.job().completion.phase,"returning")
      equal(f.held[occupied],"build:2") equal(f.job().turtle.pose,before)
      if kind~="reservation" then equal(f.mods.cells.list("build:2"),held) end
      equal(f.job().blocked,(kind=="protected" or kind=="reservation") and "path" or kind)
    end)
  end
  for _,change in ipairs({"uncertain","journal","position","facing","missing facing","missing result"}) do
    test("B4-B unexpected return report holds reservations for "..change,function()
      local f=returningBuilder() f.tick()
      local before,held=f.job().turtle.pose,f.mods.cells.list("build:2")
      f.queuedJournal=f.queued().opts.journal
      f.reportChange=function(results,facts)
        if change=="uncertain" then facts.uncertain=true
        elseif change=="journal" then facts.journal=f.queuedJournal
        elseif change=="position" then facts.pose.x=facts.pose.x+1
        elseif change=="facing" then facts.pose.f=(facts.pose.f+1)%4
        elseif change=="missing facing" then facts.pose.f=nil
        else results[1]=nil end
      end
      f.report()
      equal(f.job().blocked,"pose_uncertain") equal(f.job().turtle.pose,before)
      equal(f.mods.cells.list("build:2"),held) equal(f.job().complete,false)
    end)
  end
  test("B4-B missing and stale return reports retain reservations until stationary recovery",function()
    local f=returningBuilder() f.tick()
    local q=f.queued()
    local held=f.mods.cells.list("build:2")
    f.deliver(q.id+1,{}, {}) equal(f.queued(),q)
    f.expire() equal(f.job().blocked,"lost") equal(f.mods.cells.list("build:2"),held)
    f.lost=false f.tick() equal(f.queued().opts.recover,true) f.report()
    f.run() equal(f.job().complete,true) equal(f.count(),1)
  end)
  for _,unreported in ipairs({false,true}) do
    test("B4-B completion phase and placement cursor survive restart"..(unreported and " after an unreported return move" or ""),function()
      local f=returningBuilder()
      local completion=f.job().completion
      f.tick() if unreported then f.report(true) end
      f.restart()
      equal(f.job().completion,completion) equal(f.job().cursor,2) equal(f.job().complete,false)
      equal(f.queued().opts.recover,true) equal(f.queued().steps,{{op="inspectDown",park=true}})
      f.report() equal(f.job().completion,completion) equal(f.job().cursor,2)
      f.run() equal(f.count(),1) equal(f.placed["0,0,0"],1)
      equal(f.job().completion.phase,"complete") equal(f.job().turtle.pose,f.job().home)
      f.restart() equal(f.job().completion.phase,"complete") equal(f.job().cursor,2)
    end)
  end
  test("B4-B COMPLETE waits for confirmed arrival and the saved home facing",function()
    local f=returningBuilder()
    local home=f.job().home
    for _=1,100 do
      f.tick()
      local q=f.queued()
      if q then
        if q.opts.pose.x==home.x and q.opts.pose.y==home.y and q.opts.pose.z==home.z
          and q.opts.pose.facing==home.facing then
          equal(f.job().complete,false) equal(f.mod().facts().state,"returning")
          assert(f.alert~="build complete")
          f.tick() equal(f.job().complete,false)
          f.report() f.tick() break
        end
        f.report()
        equal(f.job().complete,false)
      end
    end
    equal(f.job().turtle.pose,home) equal(f.job().complete,true)
    equal(f.job().completion.phase,"complete")
  end)
  test("B4-B default-off builders complete at the structure and retain the captured home",function()
    local f=fixture() f.configure("floor",1,1,1) ready(f)
    local home=f.job().home
    equal(f.job().returnHome,false)
    f.input("start") f.run()
    equal(f.job().complete,true) equal(f.job().completion,nil)
    equal(f.job().turtle.pose.x,0) equal(f.job().home,home)
  end)
  for _,cap in ipairs({"parkBatch","setupFence","journal"}) do
    test("B4-B return-on and START refuse a worker without "..cap,function()
      local f=fixture() f.configure("floor",1,1,1) ready(f)
      f[cap]=false
      if cap=="journal" then f.journal=nil end
      f.input("return on") equal(f.job().returnHome,false)
      f.saved.returnHome=true f.restart() f.report()
      f.input("start") equal(f.job().running,false) equal(f.job().blocked,"worker_safety")
    end)
  end
  test("B4-B stopped operators set home and unfinished returns reject configuration changes",function()
    local f=fixture() f.configure("floor",1,1,1) ready(f)
    f.input("home -4 5 1 w") equal(f.job().home,{dim="minecraft:overworld",x=-4,y=5,z=1,facing=3})
    f.input("return on") equal(f.job().returnHome,true)
    f.input("return off") equal(f.job().returnHome,false)
    f=returningBuilder() f.input("stop")
    local before=f.job()
    for _,cmd in ipairs({"return off","home 0 4 0 n","area 0 0 0 2 0 0","material dirt","add 2"}) do
      f.input(cmd) equal(f.job(),before)
    end
    f.restart() f.report() equal(f.job().running,false) equal(f.job().completion,before.completion)
    local calls=#f.calls f.tick() equal(#f.calls,calls)
    f.input("start") f.run() equal(f.count(),1) equal(f.job().complete,true)
  end)
  test("B4-B missing home refuses opt-in return",function()
    local f=fixture() f.configure("floor",1,1,1) ready(f)
    f.saved.home=nil f.restart() f.report()
    f.input("return on") equal(f.job().returnHome,false)
    f.feedback("set builder home before return-on")
  end)
  test("B4-B failed save of the final placement cannot dispatch a return",function()
    local f=fixture() f.configure("floor",1,1,1)
    f.inventory[1]={name="minecraft:stone",count=1}
    ready(f) f.input("return on") f.input("start")
    for _=1,100 do
      f.tick()
      local q=f.queued()
      if q and q.steps[#q.steps].op=="placeDown" then f.saveOK=false f.report() break end
      if q then f.report() end
    end
    equal(f.count(),1) equal(f.job().cursor,1) equal(f.job().completion,nil)
    local calls=#f.calls f.tick() equal(#f.calls,calls)
    f.saveOK=true f.restart() f.report()
    equal(f.job().cursor,2) equal(f.job().completion.phase,"returning")
    f.run() equal(f.job().complete,true) equal(f.count(),1)
  end)

  for _,restart in ipairs({false,true}) do
    test("B4-B real worker and lease confirm home arrival"..(restart and " across server restart" or ""),function()
      local f=dofile("tests/so/build-world-fixture.lua")()
      f.configure("floor",1,1,1)
      local home=f.job().home
      f.command("return on") equal(f.job().returnHome,true)
      f.command("start")
      local returning,first
      for _=1,1200 do
        f.advance(0.05)
        if f.job().completion and f.job().completion.phase=="returning" then
          returning=true first=#f.server.sent
          equal(f.job().complete,false) equal(f.job().cursor,2)
          if restart then f.restart() first=0 f.advance(31) end
          break
        end
      end
      assert(returning,"real worker never entered RETURNING")
      f.finish()
      equal(f.job().complete,true) equal(f.job().completion.phase,"complete") equal(f.places,1)
      equal(f.job().turtle.pose,home)
      equal({f.worker.pos.x,f.worker.pos.y,f.worker.pos.z,f.worker.heading},{home.x,home.y,home.z,home.facing})
      local batches=0
      for i=first+1,#f.server.sent do
        local wire=f.server.sent[i].payload
        if wire.t=="lease.batch" then
          batches=batches+1
          equal(#wire.body.steps,1) equal(wire.body.steps[1].park,true)
          assert(type(wire.body.journal)=="string","return batch was not journal fenced")
          assert(not wire.body.steps[1].op:match("^dig"))
        end
      end
      assert(batches>0,"no return batches reached the real worker")
    end)
  end

  test("B4-B START resumes a fuel-held return after an authenticated manual refuel",function()
    local f=returningBuilder()
    f.fuel=0 f.restart() f.report() f.tick()
    equal(f.job().blocked,"fuel") equal(f.job().fuel,0)
    local status=f.mods.lease.status
    f.mods.lease.status=function()
      local value=status() value.fuel=10000 return value
    end
    f.fuel=10000 f.input("start")
    equal(f.job().fuel,10000) equal(f.job().blocked,nil)
    f.run() equal(f.job().turtle.pose,f.job().home) equal(f.count(),1)
  end)

  for _,cause in ipairs({"path","fuel"}) do
    test("B4-B rejected protected return boundary keeps its "..cause.." hold until START",function()
      local f=dofile("tests/so/build-world-fixture.lua")(nil,nil,{protectedAreas=true})
      f.configure("floor",1,1,1) f.command("return on") f.command("start")
      for _=1,1200 do
        f.advance(0.05)
        if f.job().completion then break end
      end
      equal(f.job().completion.phase,"returning")
      local attempts=0
      local up=f.worker.env.turtle.up
      f.worker.env.turtle.up=function()
        attempts=attempts+1
        return false,cause=="fuel" and "Out of fuel" or "Movement obstructed"
      end
      if cause=="fuel" then f.worker.fuel=0 end
      f.advance(8)
      equal(attempts,1) equal(f.job().blocked,cause)
      equal(f.job().completion.hold.cause,cause) equal(f.job().completion.phase,"returning")
      equal(f.job().intent,nil) equal(f.job().complete,false)
      local p=f.job().turtle.pose
      equal(f.server.env.SO.mods.cells.owner(p.x,p.y,p.z,p.dim),"build:2")
      f.restart() f.advance(31)
      equal(attempts,1) equal(f.job().blocked,cause) equal(f.job().completion.hold.cause,cause)
      f.worker.env.turtle.up=up f.worker.fuel=10000 f.advance(31)
      equal(attempts,1) equal(f.job().blocked,cause)
      f.command("start") equal(f.job().completion.hold,nil)
      f.finish() equal(f.job().complete,true) equal(f.places,1)
      equal(f.job().turtle.pose,f.job().home)
    end)
  end
  for _,stopped in ipairs({false,true}) do
    test("B4-B REMOVE refuses an unfinished return before changing worker park state"..(stopped and " while stopped" or ""),function()
      local f=returningBuilder({workerPark=true})
      if stopped then f.input("stop") end
      local before,calls=f.job(),#f.calls
      f.input("remove 2")
      equal(f.job(),before) equal(#f.calls,calls)
      f.feedback("finish return before removing worker")
      equal(f.job().turtle.removeRequested,nil) equal(f.job().turtle.paused,nil)
      if stopped then f.input("start") end
      f.run() equal(f.job().complete,true) equal(f.count(),1)
      equal(f.job().turtle.id,2) equal(f.job().turtle.pose,f.job().home)
    end)
  end

  dofile("tests/so/plan.lua")(test,equal,"build")
end
