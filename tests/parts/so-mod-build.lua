local fixture=dofile("tests/so/build-fixture.lua")
return function(test,equal)
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
      local f=fixture() f.configure(case[1],case[2],case[3],case[4]) f.input("start") f.run()
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
    f.world["-3,0,0"].stock=4 f.input("start")
    for _=1,1000 do f.tick() if f.queued() then f.report() end if f.job().blocked=="material" then break end end
    equal(f.count(),4) equal(f.job().alert,"out of material")
    f.world["-3,0,0"].stock=64
    f.now=f.now+10000 f.run()
    equal(f.count(),25)
  end)
  test("builder restart after unreported placement reconciles world without double placement",function()
    local f=fixture() f.configure("box",3,3,3) f.input("start")
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
    local f=fixture() f.configure("floor",1,1,1) f.input("start")
    f.held["0,0,0"]="mine:7"
    for _=1,100 do f.tick() if f.queued() then f.report() end if f.job().blocked then break end end
    equal(f.count(),0) equal(f.held["0,0,0"],"mine:7") equal(f.job().blocked,"cells")
    f.held["0,0,0"]=nil f.world["0,0,0"]="minecraft:diamond_block" f.input("start")
    for _=1,100 do f.tick() if f.queued() then f.report() end if f.job().blocked then break end end
    equal(f.count(),0) equal(f.world["0,0,0"],"minecraft:diamond_block") equal(f.job().alert,"build cell occupied")
  end)
  test("builder clips movement at proven radio range",function()
    local f=fixture() f.configure("floor",5,1,5) f.input("start")
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
      f.input("start")
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
    local f=fixture() f.configure("floor",1,1,1) f.world["-3,0,0"].stock=0 f.input("start")
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
    f.input("start")
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

end
