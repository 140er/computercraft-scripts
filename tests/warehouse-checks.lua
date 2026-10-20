return function(test,mocks)
  local function fixture(crash)
    local m=mocks.new(false)
    local e=m.env
    e.dofile=function(path) return assert(loadfile(path,"t",e))() end
    local A=e.dofile("atomic.lua")
    local inv,source,drop={},{ {name="minecraft:dirt",count=7}, {name="minecraft:iron_ingot",count=11}, {name="minecraft:diamond_pickaxe",count=1} },{}
    local p={dim="minecraft:overworld",x=0,y=65,z=0,h=2}
    local selected,fuel,time=1,40,10000
    m.moves=0
    local sites={source={kind="source",pose=A.copy(p),side="front"},drop={kind="drop",pose={dim=p.dim,x=3,y=65,z=0,h=1},side="front"},
      charge={kind="charge",pose={dim=p.dim,x=1,y=65,z=0,h=0},side="front"}}
    local job={key="test",token="1:wh:1",drop="drop",status="active",lines={
      {item="minecraft:iron_ingot",count=12,wanted=12,picked=0,delivered=0,source="source"},
      {item="minecraft:diamond_pickaxe",count=1,wanted=1,picked=0,delivered=0,source="source"}}}
    local function chest() return p.x==0 and source or drop end
    e.turtle={getFuelLevel=function() return fuel end,getFuelLimit=function() return 100 end,
      getItemDetail=function(slot) return inv[slot] and A.copy(inv[slot]) end,getItemCount=function(slot) return inv[slot] and inv[slot].count or 0 end,
      select=function(slot) selected=slot return true end,
      suck=function(n)
        local c=chest()
        for i,v in ipairs(c) do
          if v.count>0 then
            local take=math.min(n,v.count) v.count=v.count-take
            inv[selected]={name=v.name,count=take} return true
          end
        end
        return false
      end,
      drop=function(n)
        if m.full then return false end
        local v=inv[selected] if not v then return false end
        local take=math.min(n,v.count,m.partial or 64) local c=chest()
        c[#c+1]={name=v.name,count=take} v.count=v.count-take
        if v.count==0 then inv[selected]=nil end
        return true
      end}
    e.turtle.suckUp=e.turtle.suck e.turtle.suckDown=e.turtle.suck
    e.turtle.dropUp=e.turtle.drop e.turtle.dropDown=e.turtle.drop
    local calls={}
    local cfg={path="warehouse.state",charger=false,nav={pose=function() return A.copy(p) end,go=function(q) if m.noRoute and (p.x~=q.x or p.z~=q.z) then return false,"no route" end if p.x~=q.x or p.z~=q.z then m.moves=m.moves+1 end p=A.copy(q) return true end,
      homeCost=function(q,from) local a=from or p return m.cost or math.abs(q.x-a.x)+math.abs(q.y-a.y)+math.abs(q.z-a.z) end,
      face=function(h) p.h=h return true end,stopped=function() return false end},
      clock=function() return time end,inventory=function() return {list=function() return chest() end} end,
      client={call=function(op,v)
        calls[#calls+1]={op=op,value=A.copy(v or {})}
        if op=="wh-claim" then return {ok=true,job=A.copy(job)} end
        if op=="wh-sites" then return {ok=true,site=A.copy(sites[v.name])} end
        if op=="wh-lock" then
          if m.busy then return {ok=false,error="bay occupied"} end
          local s=A.copy(sites[v.name]) if m.side then s.side=m.side end
          return {ok=true,site=s}
        end
        return {ok=true,status="partial"}
      end},checkpoint=function(point)
        if point==crash then crash=nil error("injected "..point) end
      end}
    local W=e.dofile("warehouse.lua")
    return W.open(cfg),function() return W.open(cfg) end,inv,source,drop,m,function(dt,gain) time=time+dt fuel=gain=="unlimited" and gain or fuel+(gain or 0) end,calls,cfg
  end
  local function finish(w)
    for _=1,150 do
      local ok,why=w.tick()
      if w.state().phase=="done" then return end
      assert(ok,why)
    end
    error("unbounded warehouse job")
  end
  test("mixed source, partial supply and nonstackable orders preserve exact inventories",function()
    local w,_,inv,source,drop=fixture()
    finish(w)
    local total={}
    for _,v in ipairs(drop) do total[v.name]=(total[v.name] or 0)+v.count end
    assert(total["minecraft:iron_ingot"]==11 and total["minecraft:diamond_pickaxe"]==1 and not total["minecraft:dirt"])
    local dirt=0 for _,v in ipairs(source) do if v.name=="minecraft:dirt" then dirt=dirt+v.count end end
    assert(dirt==7 and next(inv)==nil,"supplies were lost")
  end)
  test("physical pickup and delivery crashes reconcile without double delivery",function()
    for _,point in ipairs({"pickup-physical","deliver-physical","restore-physical","transfer-saved","progress-acked"}) do
      local w,reopen,_,source,drop=fixture(point)
      local ok,why=pcall(finish,w) assert(not ok and tostring(why):find("injected",1,true),point)
      w=reopen() finish(w)
      local total=0 for _,v in ipairs(drop) do if v.name=="minecraft:iron_ingot" then total=total+v.count end end
      assert(total==11,"duplicate or missing delivery at "..point)
    end
  end)
  test("full drop retains cargo and resumes after space is available",function()
    local w,reopen,inv,_,_,m=fixture()
    for _=1,15 do assert(w.tick()) if w.state().phase=="deliver" then break end end
    m.full=true local ok=w.tick() assert(not ok and next(inv),"full drop lost cargo")
    m.full=false w=reopen() finish(w) assert(next(inv)==nil)
  end)
  test("vertical interactions, partial drops and empty sources keep exact quantities",function()
    for _,side in ipairs({"top","bottom"}) do
      local w,_,inv,source,drop,m=fixture() m.side=side m.partial=3 finish(w)
      local n=0 for _,v in ipairs(drop) do if v.name=="minecraft:iron_ingot" then n=n+v.count end end
      assert(n==11 and next(inv)==nil,side)
    end
    local w,_,inv,source,drop=fixture()
    for _,v in ipairs(source) do if v.name=="minecraft:iron_ingot" then v.count=0 end end
    finish(w)
    for _,v in ipairs(drop) do assert(v.name=="minecraft:diamond_pickaxe") end
    assert(next(inv)==nil and w.state().job.lines[1].delivered==0)
  end)
  test("charging preserves an unfinished order and refuses a trip without return fuel",function()
    local w,reopen,_,_,drop,m,advance,calls=fixture()
    while w.state().phase~="deliver" do assert(w.tick()) end
    local picked=w.state().job.lines[1].picked
    assert(w.charge("charge",60,5000),"active cargo could not charge")
    assert(w.tick()) advance(1000,20) assert(w.tick())
    w=reopen() finish(w)
    local n=0 for _,v in ipairs(drop) do if v.name=="minecraft:iron_ingot" then n=n+v.count end end
    assert(n==11 and picked==11)
    w,_,_,_,_,m,advance=fixture() m.cost=100
    local ok=w.charge("charge",60,5000)
    assert(not ok and m.moves==0,"stranded on an unaffordable service route")
  end)
  test("automatic low-fuel charging survives a crash and continues the same order",function()
    local w,reopen,_,_,drop,_,advance,_,cfg=fixture("charged-saved")
    cfg.charger="charge" cfg.targetFuel=80 cfg.fuelMargin=50
    local crashed=false
    for _=1,180 do
      local ran,ok,why=pcall(w.tick)
      if not ran then assert(not crashed and tostring(ok):find("injected",1,true),ok) crashed=true w=reopen()
      elseif not ok then assert(why=="charging",why) end
      if w.state().phase=="charge" then advance(1000,10) end
      if w.state().phase=="done" then break end
    end
    assert(crashed and w.state().phase=="done" and w.state().serviceCharges==1)
    local n=0 for _,v in ipairs(drop) do if v.name=="minecraft:iron_ingot" then n=n+v.count end end
    assert(n==11 and w.state().job.lines[2].delivered==1)
  end)
  test("charging needs measured fuel rise and has a durable timeout",function()
    local w,reopen,_,_,_,_,advance=fixture()
    assert(w.charge("charge",60,5000)) assert(w.tick())
    advance(1000,10) assert(w.tick()) assert(w.state().phase=="charge")
    w=reopen() advance(1000,10) assert(w.tick()) assert(w.state().phase=="done")
    w,reopen,_,_,_,_,advance=fixture() assert(w.charge("charge",60,1000)) assert(w.tick())
    advance(1001) w=reopen() local ok,why=w.tick()
    assert(not ok and why=="no charging fuel rise" and w.state().phase=="done")
    w,reopen,_,_,_,_,advance=fixture() assert(w.charge("charge",60,1000)) advance(0,"unlimited")
    assert(w.tick() and w.state().reason=="unlimited fuel")
  end)
  test("unavailable charging routes release the bay and competing bays time out",function()
    local w,_,_,_,_,m,advance,calls=fixture()
    m.noRoute=true assert(w.charge("charge",60,1000))
    assert(not w.tick() and w.state().phase=="done")
    assert(calls[#calls].op=="wh-unlock","failed route kept the bay")
    w,_,_,_,_,m,advance=fixture() m.busy=true assert(w.charge("charge",60,1000))
    local ok,why=w.tick() assert(not ok and why=="bay occupied")
    advance(1001) ok,why=w.tick() assert(not ok and why=="charging bay timeout")
  end)
  test("store commands and sorter aliases configure the opted-in worker without moving",function()
    local e=mocks.new(false).env e.dofile=function(path) return assert(loadfile(path,"t",e))() end
    local function command(...) assert(loadfile("store.lua","t",e))(...) end
    command("server","0","test-secret-123456","minecraft:overworld")
    command("pose","1","65","0","2") command("bounds","0","64","-4","12","66","9")
    local A=e.dofile("atomic.lua") assert(A.read("warehouse.cfg").enabled==false)
    command("enable") command("traffic","on")
    local c=A.read("warehouse.cfg") assert(c.enabled and c.traffic and c.pose.h==2 and c.bounds.min.z==-4)
    command("disable") assert(A.read("warehouse.cfg").enabled==false)
    local seen={}
    e.shell={run=function(...) seen[#seen+1]={...} end}
    for _,name in ipairs({"roomsorter.lua","sorter.lua"}) do assert(loadfile(name,"t",e))("ssot","disable") end
    assert(#seen==2 and seen[1][1]=="store" and seen[2][2]=="disable")
    local server=e.dofile("ssot.lua").new({},{controllers={["99"]="test-secret-123456"}},function() return 10000 end,"1")
    local counter=0
    e.parallel={waitForAny=function(work) work() end}
    e.dofile=function(path)
      if path=="ssot-client.lua" then return {new=function(c)
        assert(c.server==0 and c.secret=="test-secret-123456")
        return {call=function(op,fields)
          counter=counter+1 local packet=A.copy(fields or {})
          packet.type,packet.v,packet.op,packet.expect="ssot",1,op,"ssot_reply"
          packet.rid,packet.counter,packet.boot,packet.secret=tostring(counter),counter,"test",c.secret
          return server.handle(99,packet)
        end}
      end} end
      return assert(loadfile(path,"t",e))()
    end
    command("site","input","source","1","65","0","0","front")
    command("site","output","drop","3","65","0","1","front")
    command("order","cli-order","output","minecraft:iron_ingot","5","input")
    assert(server.state().warehouse.orders["cli-order"].lines[1].wanted==5)
    local m=mocks.miner({home={x=1,y=65,z=0},facing=2,mining={enabled=true}})
    e=m.env e.dofile=function(path) return assert(loadfile(path,"t",e))() end
    for _,v in ipairs({{"drop","drop1"},{"charger","charge"},{"fuel","700"},{"enable"},{"disable"}}) do
      assert(loadfile("miner.lua","t",e))("service",table.unpack(v))
      local c=e.textutils.unserialize(m.files["miner.cfg"])
      assert(c.warehouse.enabled==(v[1]=="enable"),"service enabled before explicit command")
    end
    local c=e.textutils.unserialize(m.files["miner.cfg"])
    assert(c.warehouse.drop=="drop1" and c.warehouse.charger=="charge" and c.warehouse.targetFuel==700)
    assert(loadfile("miner.lua","t",e))("nav","traffic","on")
    assert(e.textutils.unserialize(m.files["miner.cfg"]).nav.traffic==true)
  end)
end
