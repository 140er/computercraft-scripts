local H = dofile("tests/so/harness.lua")
local P = dofile("so-plan.lua")
local output = {id="output",dim=0,x=0,y=1,z=0,side="down",kind="fuel"}
local function fixture()
  local net = H.new()
  net.time = 0
  local m = net.machine({id=1,modem=true})
  m.install({"so-store.lua","so-mod-shop.lua","so-mod-drops.lua","so-ui.lua","so-plan.lua",
    "so-mod-mine.lua","so-mine-plan.lua","so-mod-health.lua"})
  local screens, sends, events = {}, {}, {}
  local store = m.env.dofile("so-store.lua")
  local s = {net=net,m=m,sends=sends,screens=screens,events=events}
  local open = store.store
  store.store = function(path, ...)
    local box = open(path, ...)
    local save = box.save
    box.save = function(value)
      if s.failSave then return false,"disk full" end
      return save(value)
    end
    return box
  end
  m.env.SO = {now=function() return net.time end,breathe=function() end,store=store,mods={
    lease={onReport=function() end},
    state={emit=function(kind,data) events[#events+1]={kind=kind,data=data} end},
    display={screen=function(role,render,input) screens[role]={render=render,input=input} end},
  }}
  m.env.rednet.send = function(id,body,protocol)
    sends[#sends+1]={id=id,body=body,protocol=protocol}
    return not s.sendFail
  end
  s.restart = function()
    local mods = m.env.SO.mods
    mods.shop = m.env.dofile("so-mod-shop.lua")
    mods.drops = m.env.dofile("so-mod-drops.lua")
    s.shop,s.drops = mods.shop,mods.drops
    mods.shop.tick(net.time) mods.drops.tick(net.time)
  end
  s.restart()
  assert(s.drops.add(output))
  s.stock = function(totals) s.shop.listen.roomsorter_stock(9,{totals=totals or {["minecraft:charcoal"]=128,["minecraft:coal"]=256}}) end
  s.enable = function() assert(s.shop.fuelConfig(nil,"output"));assert(s.shop.fuelConfig(true)) end
  s.orders = function()
    local rows={}
    for _,send in ipairs(sends) do if send.body.cmd=="order" then rows[#rows+1]=send.body end end
    return rows
  end
  return s
end
local function tap(screen,id,w,h)
  screen.session = screen.session or {id=2}
  local frame = screen.render(w,h,screen.session)
  for _,b in ipairs(frame.buttons) do
    if b.id==id then
      assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h)
      local text=""
      for y=b.y,b.y+(b.h or 1)-1 do text=text..frame.rows[y].text:sub(b.x,b.x+b.w-1) end
      assert(text:find("%S"),"button was not drawn")
      for _, other in ipairs(frame.buttons) do
        if other ~= b then
          assert(b.x+b.w<=other.x or other.x+other.w<=b.x or b.y+(b.h or 1)<=other.y
            or other.y+(other.h or 1)<=b.y,"overlapping drawn controls")
        end
      end
      screen.input({id=id,x=b.x,y=b.y,session=screen.session})
      return
    end
  end
  error("missing drawn button "..id)
end
return function(test,equal)
  test("manual shop send failures retain their existing timeout feedback",function()
    local s=fixture() s.stock()
    local screen=s.screens.shop
    tap(screen,"item:minecraft:coal",29,12)
    s.sendFail=true
    tap(screen,"order:64:minecraft:coal",29,12)
    s.net.time=120000 s.shop.tick(s.net.time)
    local text=""
    for _,row in ipairs(screen.render(29,12,screen.session).rows) do text=text..row.text end
    assert(text:find("Order: failed, timed out",1,true),"manual order lost its failure feedback")
  end)
  test("room fuel defaults off and refuses an unbound output",function()
    local s=fixture() s.stock()
    equal(s.shop.fuelConfig().auto,false)
    equal(s.shop.fuelEmpty(output),false) equal(#s.orders(),0)
    assert(s.shop.fuelConfig(true))
    equal(s.shop.fuelEmpty(output),false) equal(#s.orders(),0)
    equal(s.shop.fuelAlerts()[1].reason,"output not set")
    s.enable()
    local other=s.m.env.SO.store.copy(output) other.x=10
    equal(s.shop.fuelEmpty(other),false) equal(#s.orders(),0)
  end)
  test("room fuel uses exact stock ids and a durable physical-chest cooldown",function()
    local s=fixture() s.stock() s.enable()
    assert(s.shop.fuelEmpty(output))
    equal(s.orders()[1].text,"minecraft:charcoal") equal(s.orders()[1].n,64)
    local duplicate=s.m.env.SO.store.copy(output) duplicate.id="other-id" duplicate.dim="minecraft:overworld"
    assert(s.shop.fuelEmpty(duplicate)) equal(#s.orders(),1)
    s.restart() s.stock()
    assert(s.shop.fuelConfig().auto)
    assert(s.shop.fuelEmpty(duplicate)) equal(#s.orders(),1)
    s.net.time=599999 s.stock() s.shop.fuelEmpty(output) equal(#s.orders(),1)
    s.shop.fuelAvailable(duplicate)
    s.shop.fuelEmpty(output) equal(#s.orders(),1)
    s.net.time=600000 s.stock({["minecraft:charcoal"]=1,["minecraft:coal"]=64,["mod:charcoal"]=9999})
    s.shop.fuelEmpty(output) equal(#s.orders(),2) equal(s.orders()[2].text,"minecraft:coal")
  end)
  test("paused room keeps one outstanding fuel order across cooldowns and restarts",function()
    local s=fixture() s.stock() s.enable() s.shop.fuelEmpty(output)
    local order=s.orders()[1]
    for minute=10,60,10 do
      s.net.time=minute*60000
      s.shop.listen.roomsorter(9,{"Getting 64 charcoal",rid=order.rid})
      s.stock() s.shop.tick(s.net.time)
      if minute==20 then s.restart() s.stock() end
      s.shop.fuelEmpty(output)
      equal(#s.orders(),1)
      equal(s.shop.fuelConfig().waiting.rid,order.rid)
    end
    equal(s.shop.fuelAlerts()[1].reason,"delivery unconfirmed")
    s.shop.listen.roomsorter(9,{"Delivered 64 charcoal",rid=order.rid})
    s.shop.fuelEmpty(output) equal(#s.orders(),2)
  end)
  test("an old pickup report cannot complete a later fuel order",function()
    local s=fixture() s.stock() s.enable() s.shop.fuelEmpty(output)
    local first=s.orders()[1]
    s.shop.listen.roomsorter(9,{"Delivered 64 charcoal",rid=first.rid})
    s.net.time=600000 s.stock() s.shop.fuelEmpty(output)
    local nextOrder=s.orders()[2]
    s.shop.fuelAvailable(output,first.rid)
    s.shop.fuelAvailable(output,false)
    equal(s.shop.fuelConfig().waiting.rid,nextOrder.rid)
    s.shop.fuelAvailable(output,nextOrder.rid)
    equal(s.shop.fuelConfig().waiting,nil)
  end)
  test("unknown room replies do not release an outstanding fuel order",function()
    local s=fixture() s.stock() s.enable() s.shop.fuelEmpty(output)
    local order=s.orders()[1]
    s.shop.listen.roomsorter(9,{"Queued while paused",rid=order.rid})
    assert(s.shop.fuelConfig().waiting)
    s.net.time=600000 s.stock() s.shop.fuelEmpty(output) equal(#s.orders(),1)
    assert(s.shop.fuelAlerts()[1].reason:find("reply unconfirmed",1,true))
  end)
  test("only a saved confirmed failure permits the next fuel order",function()
    local s=fixture() s.stock() s.enable() s.shop.fuelEmpty(output)
    local order=s.orders()[1]
    s.net.time=600000 s.stock() s.failSave=true
    s.shop.listen.roomsorter(9,{"Not enough charcoal",rid=order.rid})
    assert(s.shop.fuelConfig().waiting)
    s.shop.fuelEmpty(output) equal(#s.orders(),1)
    s.failSave=false
    s.shop.listen.roomsorter(9,{"Not enough charcoal",rid=order.rid})
    equal(s.shop.fuelConfig().waiting,nil)
    assert(s.shop.fuelAlerts()[1].reason:find("order refused",1,true))
    s.restart() s.stock() s.shop.fuelEmpty(output) equal(#s.orders(),2)
  end)
  test("room fuel distinguishes missing storage stale stock low stock and save failure",function()
    local s=fixture() s.enable()
    s.shop.fuelEmpty(output) equal(s.shop.fuelAlerts()[1].reason,"storage room missing")
    s.stock() s.net.time=30000
    s.shop.fuelEmpty(output) equal(s.shop.fuelAlerts()[1].reason,"stock stale")
    s.stock({["mod:charcoal"]=9999,["minecraft:coal"]=63})
    s.shop.fuelEmpty(output) equal(s.shop.fuelAlerts()[1].reason,"stock below 64")
    s.stock() s.failSave=true
    s.shop.fuelEmpty(output) equal(#s.orders(),0)
    equal(s.shop.fuelAlerts()[1].reason,"save failed")
    s.failSave=false s.restart() s.stock() s.shop.fuelEmpty(output)
    equal(#s.orders(),1)
  end)
  test("room fuel acknowledgement does not prove delivery and failures reach attention",function()
    local s=fixture() s.stock() s.enable() s.shop.fuelEmpty(output)
    local order=s.orders()[1]
    s.shop.listen.roomsorter(9,{"Getting 64 charcoal",rid=order.rid})
    s.net.time=120000 s.shop.tick(s.net.time)
    equal(s.shop.fuelAlerts()[1].reason,"delivery unconfirmed")
    local health=s.m.env.dofile("so-mod-health.lua")
    local rows=health.attention({disk={},fuelAlerts=s.shop.fuelAlerts()})
    equal(rows[1].target,"mining") equal(rows[1].actions,{"setup"})
    assert(rows[1].text:find("delivery unconfirmed",1,true))
    s.restart() equal(s.shop.fuelAlerts()[1].reason,"delivery unconfirmed")
    s.shop.fuelAvailable(output) equal(#s.shop.fuelAlerts(),0)
    s.net.time=600000 s.stock() s.shop.fuelEmpty(output)
    order=s.orders()[2]
    s.shop.listen.roomsorter(8,{"refused",rid=order.rid}) equal(#s.shop.fuelAlerts(),0)
    s.shop.listen.roomsorter(9,{"Not enough fuel",rid=order.rid})
    assert(s.shop.fuelAlerts()[1].reason:find("order refused",1,true))
    assert(s.shop.fuelConfig(false)) equal(#s.shop.fuelAlerts(),0)
    s.restart() equal(s.shop.fuelConfig().auto,false)
  end)
  for _,restart in ipairs({false,true}) do
    test("room fuel accepts late delivery after "..(restart and "restart" or "pending timeout"),function()
      local s=fixture() s.stock() s.enable() s.shop.fuelEmpty(output)
      local order=s.orders()[1]
      s.shop.listen.roomsorter(9,{"Getting 64 charcoal",rid=order.rid})
      s.net.time=120000 s.shop.tick(s.net.time)
      equal(s.shop.fuelAlerts()[1].reason,"delivery unconfirmed")
      if restart then s.restart() end
      s.net.time=121000
      s.shop.listen.roomsorter(8,{"Delivered 64 charcoal",rid=order.rid})
      assert(s.shop.fuelConfig().waiting)
      s.shop.listen.roomsorter(9,{"Delivered 64 charcoal",rid=order.rid})
      equal(s.shop.fuelConfig().waiting,nil) equal(#s.shop.fuelAlerts(),0)
      s.restart() equal(s.shop.fuelConfig().waiting,nil)
      s.net.time=600000 s.stock() s.shop.fuelEmpty(output)
      assert(s.orders()[2].rid>order.rid,"fuel request id reused after restart")
    end)
  end
  test("room replies cannot clear another output order sent in the same tick",function()
    local s=fixture() s.stock() s.enable() s.shop.fuelEmpty(output)
    local first=s.orders()[1]
    local other=s.m.env.SO.store.copy(output) other.id="second" other.x=1
    assert(s.drops.add(other)) assert(s.shop.fuelConfig(nil,"second"))
    s.shop.fuelEmpty(other) equal(#s.orders(),1)
    equal(s.shop.fuelConfig().waiting.point.id,"output")
    assert(s.shop.fuelConfig(false)) assert(s.shop.fuelConfig(true))
    s.shop.fuelEmpty(other) equal(#s.orders(),1)
    s.shop.listen.roomsorter(9,{"Delivered 64 charcoal",rid=first.rid})
    s.shop.fuelEmpty(other) equal(#s.orders(),2)
    s.shop.listen.roomsorter(9,{"Delivered 64 charcoal",rid=first.rid})
    equal(s.shop.fuelConfig().waiting.point.id,"second")
  end)
  test("room fuel records failed sends and retains cooldown across a power cut before send",function()
    local s=fixture() s.stock() s.enable() s.sendFail=true
    s.shop.fuelEmpty(output) equal(s.shop.fuelAlerts()[1].reason,"send failed")
    s.restart() s.stock() s.shop.fuelEmpty(output) equal(#s.orders(),1)
    s.net.time=600000 s.stock() s.sendFail=false
    s.m.env.rednet.send=function() error("power cut") end
    assert(not pcall(s.shop.fuelEmpty,output))
    s.restart() s.stock() s.shop.fuelEmpty(output) equal(#s.orders(),1)
  end)
  test("room ore and wood sinks are opt-in persistent points with ordinary unload steps",function()
    local s=fixture()
    local near={dim=0,x=0,y=2,z=0}
    for _,kind in ipairs({"ore","wood"}) do
      local p={id="input-"..kind,dim=0,x=0,y=1,z=0,side="down",kind=kind,room=true}
      assert(s.drops.add(p))
      equal(s.drops.pick(kind,near).point,nil)
      equal(P.chestCheck(s.drops.list(),kind,near).ok,false)
    end
    assert(s.drops.roomSink(true)) s.restart()
    for _,kind in ipairs({"ore","wood"}) do
      local p=assert(s.drops.pick(kind,near).point)
      equal(p.id,"input-"..kind)
      equal(s.drops.steps(p),{{op="inspectDown"},{op="dropDown"}})
      equal(P.chestCheck(s.drops.list(),kind,near).ok,true)
    end
    s.failSave=true
    equal(s.drops.roomSink(false),false)
    assert(s.drops.pick("ore",near).point)
    s.failSave=false assert(s.drops.roomSink(false)) s.restart()
    equal(s.drops.pick("ore",near).point,nil)
    assert(s.drops.roomMark("input-ore",false))
    assert(s.drops.pick("ore",near).point)
  end)
  for _,size in ipairs({{26,20},{29,12}}) do
    test("room controls use drawn buttons at "..size[1].."x"..size[2],function()
      local s=fixture() local mods=s.m.env.SO.mods
      s.m.env.SO.pair={key=function() return "paired" end}
      mods.state.get=function(path)
        if path=="machines" then return {["2"]={role="worker"},["3"]={role="worker"}} end
      end
      mods.mine=s.m.env.dofile("so-mod-mine.lua") mods.mine.tick()
      local mining=s.screens.mining
      tap(mining,"setup",unpack(size))
      tap(mining,"fuel-output",unpack(size))
      equal(s.shop.fuelConfig().output.id,"output")
      tap(mining,"fuel-auto",unpack(size)) equal(s.shop.fuelConfig().auto,true)
      tap(mining,"fuel-auto",unpack(size)) equal(s.shop.fuelConfig().auto,false)
      local drops=s.screens.generic
      tap(drops,"new",unpack(size))
      tap(drops,"room-point",unpack(size))
      tap(drops,"add",unpack(size))
      local found
      for _,p in ipairs(s.drops.list()) do if p.kind=="ore" then found=p end end
      assert(found and found.room and found.disabled)
      tap(drops,"room-sink",unpack(size))
      assert(s.drops.pick("ore",{dim=0,x=0,y=64,z=0}).point)
      if size[2]==12 then
        tap(drops,"from-next",unpack(size))
        local foundNext
        for _,b in ipairs(drops.render(size[1],size[2],drops.session).buttons) do if b.id=="from:3" then foundNext=true end end
        assert(foundNext,"FROM paging lost after room controls")
      end
      tap(drops,"list",unpack(size))
      tap(mining,"mine-back",unpack(size))
    end)
  end
  test("mining empty fuel shares the policy without changing standing reservations",function()
    local s=fixture() s.stock() s.enable()
    local pose={dim="minecraft:overworld",x=0,y=2,z=0,facing=0}
    local row={pose=pose,anchor=pose,inv={},fuel=1,state="mining"}
    local job={homeSet=true,home=pose,dim=pose.dim,bottom=-2,length=3,mode="fast",ores={},
      progress={nextBranch=0,done=0},turtles={["2"]=row},running=true}
    local store=s.m.env.SO.store
    local open=store.store
    store.store=function(path,...)
      if path=="so-data/mine/job" then return {value=job,save=function() return true end} end
      return open(path,...)
    end
    local callback, queued
    local standing="mine:2"
    s.m.env.SO.mods.lease={status=function() return {} end,inRange=function() return true end,
      onReport=function(_,fn) callback=fn end,send=function(_,steps) queued=steps return "lease" end}
    s.m.env.SO.mods.cells={owner=function() return standing end,reserveMany=function() return true end,
      release=function() error("standing reservation released") end}
    local mine=s.m.env.dofile("so-mod-mine.lua")
    mine.tick()
    callback("lease",2,{{ok=true}},{report={pose={x=0,y=2,z=0,f=0},inv={},fuel=1}})
    row.trip={kind="fuel",point=output,stand=pose,back=pose,stage="out",path={pose},reserve=2000}
    mine.tick() equal(queued[#queued].op,"suckDown")
    callback("lease",2,{{ok=true,data={name="minecraft:chest"}},{ok=true},{ok=false,err="No items to take"}},
      {report={pose={x=0,y=2,z=0,f=0},inv={},fuel=1}})
    equal(#s.orders(),1) equal(standing,"mine:2")
    callback("lease",2,{{ok=true,data={name="minecraft:chest"}},{ok=true},{ok=true}},
      {report={pose={x=0,y=2,z=0,f=0},inv={{slot=1,name="minecraft:iron_ingot",count=64}},fuel=1}})
    assert(s.shop.fuelConfig().waiting,"mining non-fuel pickup cleared the fuel order")
  end)
  test("ordinary worker unloads ore and logs into the opted-in room chest under 1 MB",function()
    local F=dofile("tests/so/worker-fixture.lua")
    local f=F.setup({id=2,modem=true,turtle=true,y=2,capacity=1000000},{"so-mod-drops.lua"})
    local drops=f.s.env.SO.mods.drops
    local chest={name="minecraft:chest",inv={}}
    f.n.world["0,1,0"]=chest
    assert(drops.roomSink(true))
    for i,kind in ipairs({"ore","wood"}) do
      assert(drops.add({id="room-"..kind,dim=0,x=0,y=1,z=0,side="down",kind=kind,room=true}))
      local point=assert(drops.pick(kind,{dim=0,x=0,y=2,z=0}).point)
      local steps={{op="select",slot=1}}
      for _,step in ipairs(drops.steps(point)) do steps[#steps+1]=step end
      f.t.inv[1]={name=i==1 and "minecraft:raw_iron" or "minecraft:oak_log",count=8}
      F.send(f,steps) f.n.advance(1) F.check(f)
      equal(chest.inv[i].count,8)
      equal(chest.inv[i].name,i==1 and "minecraft:raw_iron" or "minecraft:oak_log")
    end
  end)
  test("lumber empty fuel uses the shared policy and retries after a minute",function()
    local policy=fixture() policy.stock() policy.enable()
    local s=dofile("tests/so/lumber-fixture.lua")("scan",1,{})
    s.mods.shop=policy.shop s.env.SO.now=function() return policy.net.time end
    s.row.service={kind="fuel",point={id="output",dim="minecraft:overworld",x=0,y=1,z=0,side="down"},
      stage="take",back={x=0,y=2,z=0,facing=1}}
    s.tick(0)
    local q=assert(s.queued()) local results={}
    for i=1,#q.steps do results[i]={ok=true} end
    results[#q.steps]={ok=false,err="No items to take"}
    s.report(false,results)
    equal(#policy.orders(),1) equal(s.row.blocked,"fuel") equal(s.row.fuelRetry,60000)
    policy.net.time=60000 s.tick(60000)
    equal(s.row.blocked,nil)
    q=assert(s.queued()) equal(q.steps[#q.steps].op,"inspectDown")
    s.report(false,{{ok=true,data={name="minecraft:chest"}}})
    s.tick(60000) q=assert(s.queued()) equal(q.steps[#q.steps].op,"suckDown")
    s.row.inv={{slot=1,name="minecraft:charcoal",count=64}}
    s.report(false)
    equal(policy.shop.fuelConfig().waiting,nil)
  end)
  test("lumber recovers usable fuel from an interrupted pickup without another suck",function()
    local policy=fixture() policy.stock() policy.enable() policy.shop.fuelEmpty(output)
    local logs={slot=1,name="minecraft:oak_log",count=8}
    local s=dofile("tests/so/lumber-fixture.lua")("scan",1,{logs})
    s.mods.shop=policy.shop s.env.SO.now=function() return policy.net.time end
    s.row.service={kind="fuel",point={id="output",dim="minecraft:overworld",x=0,y=1,z=0,side="down"},
      stage="take",resume="scan",back={x=0,y=2,z=0,facing=1}}
    s.tick(0) equal(s.queued().steps[2].op,"suckDown")
    s.row.inv={logs,{slot=2,name="minecraft:charcoal",count=64}} s.expire()
    local mod=assert(loadfile("so-mod-lumber.lua","t",s.env))()
    s.tick=mod.tick s.tick(0) s.report(false)
    s.tick(0)
    equal(s.queued().steps,{{op="select",slot=2},{op="refuel",n=64}})
    equal(policy.shop.fuelConfig().waiting,nil)
  end)
  for _,restart in ipairs({false,true}) do
    test("lumber returns iron and refuels when charcoal arrives"..(restart and " after restart" or ""),function()
      local policy=fixture() policy.stock() policy.enable() policy.shop.fuelEmpty(output)
      local logs={slot=1,name="minecraft:oak_log",count=8}
      local iron={slot=2,name="minecraft:iron_ingot",count=64}
      local coal={slot=3,name="minecraft:charcoal",count=64}
      local s=dofile("tests/so/lumber-fixture.lua")("scan",1,{logs})
      s.mods.shop=policy.shop s.env.SO.now=function() return policy.net.time end
      s.row.service={kind="fuel",point={id="output",dim="minecraft:overworld",x=0,y=1,z=0,side="down"},
        stage="take",resume="scan",back={x=0,y=2,z=0,facing=1}}
      s.tick(0) equal(s.queued().steps[1].slot,2)
      s.row.inv={logs,iron} s.report(false)
      equal(s.row.blocked,"fuel") equal(s.row.fuelRetry,60000)
      assert(policy.shop.fuelConfig().waiting)
      equal(s.row.service.rejected["2"],iron.name)
      if restart then
        local mod=assert(loadfile("so-mod-lumber.lua","t",s.env))()
        s.tick=mod.tick s.tick(0) s.report(false)
      end
      policy.net.time=60000 s.tick(60000)
      equal(s.queued().steps[1].op,"inspectDown")
      s.report(false,{{ok=true,data={name="minecraft:chest"}}})
      s.tick(60000) equal(s.queued().steps[1].slot,3)
      s.row.inv={logs,iron,coal} s.report(false)
      equal(policy.shop.fuelConfig().waiting,nil) equal(s.row.fuelRetry,nil)
      s.tick(60000)
      local q=assert(s.queued())
      equal(q.steps,{{op="select",slot=2},{op="inspectDown"},{op="dropDown",n=64}})
      if restart then
        s.report(false,{{ok=true},{ok=true,data={name="minecraft:chest"}},{ok=false,err="No space for items"}})
        equal(s.row.blocked,"fuel") equal(s.row.fuelRetry,120000)
        policy.net.time=600000 policy.stock() policy.shop.fuelEmpty(output)
        equal(#policy.orders(),2)
        s.tick(policy.net.time)
        equal(s.queued().steps[1].slot,2)
        equal(policy.shop.fuelConfig().waiting.rid,policy.orders()[2].rid)
      end
      s.row.inv={logs,coal}
      s.report(false,{{ok=true},{ok=true,data={name="minecraft:chest"}},{ok=true}})
      s.tick(policy.net.time) s.tick(policy.net.time)
      equal(s.queued().steps,{{op="select",slot=3},{op="refuel",n=64}})
      s.row.inv={logs} s.row.fuel=5121 s.report(false)
      equal(s.row.service.stage,"return") equal(s.row.inv[1],logs)
      equal(#policy.orders(),restart and 2 or 1)
      if restart then equal(policy.shop.fuelConfig().waiting.rid,policy.orders()[2].rid) end
    end)
  end

end
