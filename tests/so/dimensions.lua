local H = dofile("tests/so/harness.lua")
local F = dofile("tests/so/worker-fixture.lua")
local P = dofile("so-plan.lua")
local M = dofile("so-mine-plan.lua")
local modules = {"so-plan.lua","so-ui.lua","so-log.lua","so-mod-state.lua","so-mod-lease.lua",
  "so-mod-cells.lua","so-mod-display.lua","so-mod-drops.lua","so-mod-mine.lua","so-mine-plan.lua",
  "so-mod-lumber.lua","so-lumber-plan.lua","so-mod-map.lua","so-mod-ar.lua"}
local function setup(dim, enabled)
  local a=F.setup({id=2,modem=true,turtle=true,capacity=1000000,fuel=10000},modules)
  a.s.files["so-server.cfg"]=H.encode({pos={dim="minecraft:overworld",x=0,y=64,z=0},remoteDimensions=enabled})
  a.t.files["so-worker.cfg"]=H.encode({dim=dim})
  a.n.advance(31)
  a.screen=function(role) return assert(a.s.env.SO.mods.display.screen(role)) end
  a.input=function(role,text) a.screen(role).input({text=text}) end
  a.job=function(role) return a.s.env.SO.store.store("so-data/"..role.."/job",function() return true end).value end
  return a
end
local function text(frame)
  local rows={} for _,r in ipairs(frame.rows) do rows[#rows+1]=r.text end
  return table.concat(rows,"\n")
end
local function press(screen,w,h,id,session)
  local f=screen.render(w,h,session)
  for _,b in ipairs(f.buttons) do if b.id==id then
    assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h)
    assert(f.rows[b.y].text:sub(b.x,b.x+b.w-1):find("%S"),"button not drawn")
    screen.input({id=id,x=b.x,y=b.y,session=session}) return
  end end
  error("missing button "..id)
end
return function(test,equal)
  test("dimension aliases normalize and remote opt-in requires literal true",function()
    equal(P.dimension("overworld"),"minecraft:overworld")
    equal(P.dimension("nether"),"minecraft:the_nether")
    equal(P.dimension("end"),"minecraft:the_end")
    equal(P.dimension("typo"),nil)
    for _,c in ipairs({{}, {remoteDimensions=false}, {remoteDimensions="true"}}) do
      assert(P.dimensionError("minecraft:the_nether",c))
    end
    equal(P.dimensionError("minecraft:the_nether",{remoteDimensions=true}),nil)
    for _,y in ipairs({0,127,-58}) do assert(P.heightError("minecraft:the_nether",y)) end
    for _,y in ipairs({1,126}) do equal(P.heightError("minecraft:the_nether",y),nil) end
    assert(P.heightError("minecraft:the_end",0));equal(P.heightError("minecraft:the_end",1),nil)
  end)
  test("Nether ore filters include debris quartz and nether gold",function()
    for name,filter in pairs({ancient_debris="ancient_debris",nether_quartz_ore="quartz",nether_gold_ore="nether_gold"}) do
      assert(M.ore({name="minecraft:"..name},{filter}))
      assert(not M.junk({name="minecraft:"..name}))
    end
    assert(not M.ore({name="minecraft:ancient_debris"},{"iron"}))
  end)
  test("job commands refuse disabled or invalid dimensions without changing overworld jobs",function()
    local a=setup("minecraft:the_nether",false)
    for _,role in ipairs({"mining","lumber"}) do
      a.input(role,role=="mining" and "home 0 64 0 n minecraft:the_nether" or "area 0 0 3 3 62 minecraft:the_nether")
      assert(text(a.screen(role).render(29,12)):find("remote dimensions disabled",1,true))
    end
    equal(a.job("mine"),nil);equal(a.job("lumber").dim,"minecraft:overworld");equal(a.job("lumber").area,nil)
    a.s.files["so-server.cfg"]=H.encode({remoteDimensions=true})
    a.input("mining","home 0 64 0 n typo")
    assert(text(a.screen("mining").render(29,12)):find("invalid dimension",1,true))
    a.input("mining","home 0 64 0 n overworld")
    equal(a.job("mine").dim,"minecraft:overworld")
  end)
  test("remote assignment uses explicit poses and checks worker dimensions",function()
    local a=setup("minecraft:the_nether",true)
    a.input("mining","home 0 64 0 n minecraft:the_nether")
    equal(a.job("mine").bottom,15)
    a.input("mining","add 2")
    assert(text(a.screen("mining").render(57,24)):find("explicit add",1,true))
    a.input("mining","add 2 0 64 0 n")
    a.n.advance(1);F.check(a)
    equal(a.job("mine").turtles["2"].pose.dim,"minecraft:the_nether")
    local lease=a.s.env.SO.mods.lease
    assert(lease.inRange(2,{dim="minecraft:the_nether",x=100000,y=64,z=100000}))
    assert(not lease.inRange(2,{dim="minecraft:the_end",x=0,y=64,z=0}))
    local before=a.job("mine").home
    a.input("mining","home 10 64 0 n minecraft:the_end")
    equal(a.job("mine").home,before)
  end)
  test("Nether home and bottom reject bedrock and lumber rejects missing headroom",function()
    local a=setup("minecraft:the_nether",true)
    for _,y in ipairs({0,127}) do
      a.input("mining","home 0 "..y.." 0 n minecraft:the_nether")
      assert(text(a.screen("mining").render(29,12)):find("bedrock",1,true))
    end
    a.input("mining","home 0 64 0 n minecraft:the_nether")
    a.input("mining","bottom -58");equal(a.job("mine").bottom,15)
    a.input("lumber","area 0 0 3 3 123 minecraft:the_nether")
    equal(a.job("lumber").area,nil)
    a.input("lumber","area 0 0 3 3 62 minecraft:the_nether")
    equal(a.job("lumber").dim,"minecraft:the_nether")
  end)
  test("Nether mine cannot start with overworld supply chests",function()
    local a=setup("minecraft:the_nether",true)
    a.input("mining","home 0 64 0 n nether")
    a.input("mining","add 2 0 64 0 n");a.n.advance(1)
    a.s.env.SO.mods.drops.add({id="wrong",dim=0,x=2,y=64,z=0,kind="any",side="front"})
    a.input("mining","start")
    assert(not a.job("mine").running)
    local why=text(a.screen("mining").render(57,24))
    assert(why:find("ore",1,true) and why:find("fuel",1,true))
    F.check(a)
  end)
  test("Nether mine runs its own shaft lane and dimension dug marks",function()
    local a=setup("minecraft:the_nether",true)
    a.input("mining","home 0 64 0 n nether")
    a.input("mining","bottom 62");a.input("mining","length 2")
    a.input("mining","branches 1")
    a.input("mining","add 2 0 64 0 n");a.n.advance(1)
    a.s.env.SO.mods.drops.add({id="supply",dim=-1,x=100,y=64,z=0,kind="any",side="front"})
    a.n.world["0,-1,-1"]="minecraft:netherrack"
    a.n.world["0,-2,-1"]="minecraft:netherrack"
    a.input("mining","start");assert(a.job("mine").running)
    a.n.advance(20);F.check(a)
    local cells=a.s.env.SO.mods.cells
    assert(cells.isDug(0,63,-1,"minecraft:the_nether"))
    assert(not cells.isDug(0,63,-1,"minecraft:overworld"))
    for _,c in ipairs(cells.list("mine:2")) do equal(c.dim,"minecraft:the_nether") end
  end)
  test("remote dispatch refuses old workers mismatched dimensions and a disabled flag",function()
    local a=setup("minecraft:the_nether",true)
    local lease=a.s.env.SO.mods.lease
    local steps={{op="forward"}}
    local opts={pose={dim="minecraft:the_nether",x=0,y=64,z=-1}}
    local hellos=F.sent(a.t,"hello")
    local body={role="turtle",dim="minecraft:the_nether",journal=hellos[#hellos].body.journal}
    lease.handlers.hello({from=2,body=body})
    local id,why=lease.send(2,steps,opts)
    equal(id,nil);equal(why,"update remote worker")
    body.capabilities={dimensionSafety=true};body.dim="minecraft:the_end"
    lease.handlers.hello({from=2,body=body})
    id,why=lease.send(2,steps,opts)
    equal(id,nil);assert(why:find("dimension mismatch",1,true))
    body.dim="minecraft:the_nether";lease.handlers.hello({from=2,body=body})
    a.s.files["so-server.cfg"]=H.encode({remoteDimensions=false})
    id,why=lease.send(2,steps,opts)
    equal(id,nil);equal(why,"remote dimensions disabled")
    equal(a.t.pos.z,0)
  end)
  test("remote worker silence raises the unloaded-chunk warning",function()
    local a=setup("minecraft:the_nether",true)
    a.input("mining","home 0 64 0 n nether")
    a.n.kill(a.t)
    a.input("mining","add 2 0 64 0 n")
    a.n.advance(615)
    assert(text(a.screen("mining").render(57,24)):find("remote silent; unloaded?",1,true))
  end)
  test("Nether lumber travels and digs with its own dimension marks",function()
    local a=setup("minecraft:the_nether",true)
    a.input("lumber","area 0 0 3 3 62 nether")
    a.input("lumber","saplings 5 63 0 down")
    a.input("lumber","add 2 0 64 0 n")
    a.n.advance(3)
    a.s.env.SO.mods.drops.add({id="woodfuel",dim=-1,x=100,y=64,z=0,kind="any",side="front"})
    for y=-1,1 do a.n.world["1,"..y..",1"]={name="minecraft:oak_log",tags={["minecraft:logs"]=true}} end
    a.input("lumber","start");assert(a.job("lumber").running,text(a.screen("lumber").render(57,24)))
    a.n.advance(20);F.check(a)
    local cells=a.s.env.SO.mods.cells
    assert(cells.isDug(1,64,1,"minecraft:the_nether"))
    assert(not cells.isDug(1,64,1,"minecraft:overworld"))
  end)
  test("worker catches late lava before moving and aborts the rest of the batch",function()
    local a=setup("minecraft:the_nether",true)
    a.n.world["0,0,-1"]={name="minecraft:lava",state={level=0}}
    F.send(a,{{op="forward",safety={dim="minecraft:the_nether",y=64}},
      {op="up",safety={dim="minecraft:the_nether",y=65}}})
    a.n.advance(1);F.check(a)
    equal(a.t.pos.z,0);equal(a.t.pos.y,0)
    local reports=F.sent(a.t,"step.report")
    local r=reports[#reports].body.results
    equal(r[1].err,"remote safety: lava");equal(r[2].ok,false)
  end)
  test("worker refuses remote void bedrock missing guards and dimension mismatch",function()
    for _,case in ipairs({{"minecraft:the_end",0},{"minecraft:the_nether",127},
      {"minecraft:the_end",64,"minecraft:the_nether"},{"minecraft:the_end",64,false}}) do
      local a=setup(case[1],true)
      F.send(a,{{op="down",safety=case[3]~=false and {dim=case[3] or case[1],y=case[2]} or nil}})
      a.n.advance(1);F.check(a);equal(a.t.pos.y,0)
      local r=F.sent(a.t,"step.report");assert(r[#r].body.results[1].err:find("remote safety:",1,true))
    end
  end)
  test("remote expiry stays stationary instead of reversing without inspection",function()
    local a=setup("minecraft:the_end",true)
    F.send(a,{{op="forward",safety={dim="minecraft:the_end",y=64}}},1000)
    a.n.advance(90);F.check(a)
    equal(a.t.pos.z,-1)
    assert(#F.sent(a.t,"beacon")>0)
  end)
  test("map dimension button isolates overlapping workers drops and dug lookups",function()
    local a=setup("minecraft:the_nether",true)
    a.input("mining","home 0 64 0 n nether")
    a.input("mining","add 2 0 64 0 n");a.n.advance(1)
    a.s.env.SO.mods.drops.add({id="nether",dim=-1,x=1,y=64,z=0,kind="ore",side="front"})
    a.s.env.SO.mods.drops.add({id="world",dim=0,x=1,y=64,z=0,kind="ore",side="front"})
    a.n.advance(5)
    local dims={}
    a.s.env.SO.mods.cells.isDug=function(_,_,_,dim) dims[dim]=true return false end
    for _,size in ipairs({{26,20},{29,12}}) do
      local screen,session=a.screen("map"),{}
      press(screen,size[1],size[2],"map-dim",session)
      equal(session.map.dim,"minecraft:the_nether")
      screen.render(size[1],size[2],session)
      assert(dims["minecraft:the_nether"])
      press(screen,size[1],size[2],"map-dim",session)
      equal(session.map.dim,"minecraft:the_end")
    end
    F.check(a)
  end)
  test("worker dimension changes cannot replay dug history into a new anchor",function()
    local a=setup("minecraft:overworld",true)
    a.n.world["0,-1,0"]="minecraft:stone"
    F.send(a,{{op="digDown"}});a.n.advance(1)
    equal(#F.journal(a.t).dug,1)
    a.n.kill(a.t)
    a.t.files["so-worker.cfg"]=H.encode({dim="minecraft:the_nether"})
    a.t.killed=false;a.t.co,a.t.inbox,a.t.timers=nil,{},{}
    a.t.boot("worker.lua");a.n.advance(3);F.check(a)
    local lease=a.s.env.SO.mods.lease
    equal(lease.status(2).uncertain,true)
    a.input("mining","home 0 64 0 n nether")
    a.input("mining","add 2 0 64 0 n");a.n.advance(3);F.check(a)
    equal(F.journal(a.t).dim,"minecraft:the_nether")
    equal(#F.journal(a.t).dug,0)
    equal(lease.status(2).uncertain,nil)
    assert(not a.s.env.SO.mods.cells.isDug(0,63,0,"minecraft:the_nether"))
    a.n.kill(a.t)
    a.t.killed=false;a.t.co,a.t.inbox,a.t.timers=nil,{},{}
    a.t.boot("worker.lua");a.n.advance(3);F.check(a)
    equal(lease.status(2).uncertain,nil)
  end)
  test("remote map focus and chest taps use the drawn dimension",function()
    local a=setup("minecraft:the_nether",true)
    a.s.env.SO.mods.cells.isDug=function() return false end
    local drops=a.s.env.SO.mods.drops
    drops.add({id="world",dim=0,x=-10,y=64,z=-10,side="front",kind="ore"})
    drops.add({id="nether",dim=-1,x=10,y=64,z=10,side="front",kind="ore"})
    for _,id in ipairs({"world","nether"}) do for _=1,3 do drops.note(id,nil) end end
    a.n.advance(5)
    for _,size in ipairs({{26,20},{29,12}}) do
      local screen,session=a.screen("map"),{}
      press(screen,size[1],size[2],"map-dim",session)
      press(screen,size[1],size[2],"map-focus",session)
      equal(session.map.x,10);equal(session.map.z,10)
      session.map.x,session.map.z=0,0
      press(screen,size[1],size[2],"map-fit",session)
      press(screen,size[1],size[2],"map-drop:nether",session)
      equal(session.map.x,10);equal(session.map.z,10)
    end
  end)
  test("AR scopes overlapping geometry to its explicit dimension",function()
    local a=setup("minecraft:the_nether",true)
    local mods=a.s.env.SO.mods
    mods.state.get=function() return {
      [2]={role="turtle",pose={dim="minecraft:overworld",x=1,y=64,z=1}},
      [3]={role="turtle",pose={dim="minecraft:the_nether",x=1,y=64,z=1}}} end
    local drawn,ar={},{}
    for _,method in ipairs({"drawLine3D","drawText3D","drawText2D"}) do
      ar[method]=function(id) drawn[id]=true end
    end
    ar.delete=function(id) drawn[id]=nil end
    ar.clear=function() drawn={} end
    ar.update=function() end
    a.s.env.peripheral.find=function(kind) if kind=="ar_controller" then return ar end end
    a.s.files["so-server.cfg"]=H.encode({arDim="minecraft:the_nether",remoteDimensions=true,
      pos={dim="minecraft:overworld",x=0,y=64,z=0}})
    local module=a.s.env.dofile("so-mod-ar.lua")
    module.tick(a.n.time)
    assert(drawn["turtle:3"]);assert(not drawn["turtle:2"])
  end)
  test("coordinate keys distinguish dimensions and planner holds at remote bounds",function()
    local a={dim="minecraft:overworld",x=0,y=1,z=0}
    local b={dim="minecraft:the_end",x=0,y=1,z=0}
    assert(M.key(a)~=M.key(b));assert(not M.same(a,b))
    local action=M.next({dim=b.dim},{pose=b,goal={dim=b.dim,x=0,y=0,z=0}},function() return false end,{},100)
    equal(action.kind,"hold");assert(action.error:find("void",1,true))
  end)
end
