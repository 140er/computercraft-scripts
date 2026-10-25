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
    equal(f.count(),0) equal(f.held["0,0,0"],"mine:7") equal(f.job().blocked,"cells")
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
      equal(f.job().blocked,"lane") equal(f.count(),0)
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
    f.world["-3,0,0"].stock=64 f.now=f.now+10000 f.run()
    equal(f.alert,false)
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
    equal(f.job().alert,"builder already has a turtle")
    assert(f.mod().forget(2)) f.input("add 2")
    equal(f.job().alert,"add needs x y z n|e|s|w")
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
    f.input("start") equal(f.job().running,false) equal(f.job().alert,"fuel unknown; wait for report")
    ready(f)
    f.uncertain=true f.input("start") equal(f.job().running,false)
    assert(f.job().alert:find("pose missing or uncertain",1,true))
    f.uncertain=false f.mod().handlers.hello({from=2,body={}})
    f.input("start") equal(f.job().alert,"update worker for builder safety")
    f.mod().handlers.hello({from=2,body={capabilities={parkBatch=true}}})
    f.fuel=0 f.restart() ready(f) f.input("start")
    equal(f.job().running,false) equal(f.job().alert,"out of fuel")
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
    f.locateDone(nil,"GPS failed") equal(f.job().turtle,old) equal(f.job().alert,"GPS failed")
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
    equal(f.job().blocked,"fuelStock") equal(f.count(),0)
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

end
