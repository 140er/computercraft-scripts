return function(test,mocks)
  local function fixture(crash)
    local m=mocks.miner({home={x=1,y=65,z=0},facing=2})
    local e=m.env
    e.dofile=function(path) return assert(loadfile(path,"t",e))() end
    local A,S=e.dofile("atomic.lua"),e.dofile("ssot.lua")
    local server=S.new({},{controllers={["1"]="test-secret-123456"}},function() return 10000 end,"1")
    local counter=0
    local function call(op,fields)
      counter=counter+1 local msg=A.copy(fields or {})
      msg.type,msg.v,msg.expect,msg.op="ssot",1,"ssot_reply",op
      msg.rid,msg.counter,msg.boot,msg.secret=tostring(counter),counter,"test","test-secret-123456"
      local r=server.handle(1,msg) return r,r and r.error
    end
    local function p(x,y,z) return {dim="minecraft:overworld",x=x,y=y,z=z,h=2} end
    local home=p(1,65,0)
    assert(call("mine-config",{zone={min=p(0,64,1),max=p(3,66,5),spacing=4}}).ok)
    local Mine=e.dofile("mining.lua")
    local nc={pose=home,bounds={min=p(-1,63,-1),max=p(4,67,6)},
      client={resync=function(q) return call("sync",{pose=q}).ok end,move=function(from,to,execute)
        local g=assert(call("reserve",{pose=from,to=to})) assert(g.ok,g.error)
        local fields={pose=from,to=to,token=g.token,epoch=g.epoch}
        assert(call("start",fields).ok)
        local ok,why=execute()
        if ok then assert(call("commit",fields).ok) else assert(call("sync",{pose=from}).ok) end
        return ok,why
      end},
      observe=function() return p(m.pos.x,m.pos.y,m.pos.z) end,canExcavate=Mine.excavatable}
    local nav=e.dofile("nav.lua").open(nc) assert(nav.recover())
    local cfg={nav=nav,client={call=call},home=home,checkpoint=function(point)
      if crash and point==crash then crash=nil error("test crash "..point) end
    end}
    local miner=Mine.open(cfg)
    local function reopen()
      nav=e.dofile("nav.lua").open(nc) assert(nav.recover()) cfg.nav=nav
      miner=Mine.open(cfg) return miner,nav
    end
    return m,miner,reopen,home,nav,Mine
  end
  local function complete(miner,limit)
    for _=1,limit or 500 do
      local ok,why=miner.tick()
      if sleep then sleep(0) end
      if not ok then return why end
    end
    error("unbounded mining")
  end
  test("six-face veins preserve loops, deepslate, tags, the spacing gap and exact home pose",function()
    local m,mine,_,home,nav,M=fixture()
    for z=1,5 do m.world["1,65,"..z]="minecraft:stone" end
    local ores={"1,65,2","1,66,2","1,64,2","0,65,2","2,65,2","0,65,1","0,66,1","0,66,2","2,66,2","3,66,2"}
    for _,k in ipairs(ores) do m.world[k]="minecraft:deepslate_diamond_ore" end
    m.world["3,65,4"]="minecraft:diamond_ore"
    assert(M.ore({name="example:crystal",tags={["c:ores/crystal"]=true}}))
    assert(not M.excavatable({name="minecraft:chest"}))
    assert(not M.excavatable({name="minecraft:stone",state={waterlogged=true}}))
    assert(mine.start()) assert(complete(mine)=="complete") assert(mine.finish())
    for _,k in ipairs(ores) do assert(not m.world[k],"forgot ore "..k) end
    assert(m.world["3,65,4"],"spacing-four gap was falsely covered")
    local p=nav.pose() assert(p.x==home.x and p.y==home.y and p.z==home.z and p.h==home.h)
  end)
  test("crashes before and after traversal moves retain the queue and resume exactly",function()
    for _,point in ipairs({"action-prepared","action-physical","action-saved","strip-saved","resume-saved","return-saved","home-saved","finished-saved"}) do
      local m,mine,reopen=fixture(point)
      m.world["1,65,1"]="minecraft:diamond_ore" m.world["2,65,1"]="minecraft:diamond_ore"
      local ok,err=pcall(function() assert(mine.start()) complete(mine) assert(mine.finish()) end)
      assert(not ok and tostring(err):find("test crash",1,true),point)
      mine=reopen()
      if mine.state().phase~="done" then
        assert(mine.start())
        if mine.state().phase~="done" then assert(complete(mine)=="complete") assert(mine.finish()) end
      end
      assert(not m.world["1,65,1"] and not m.world["2,65,1"],point)
    end
  end)
  test("inventory and fuel interrupts preserve work and never drop without a chest",function()
    for _,reason in ipairs({"inventory full","low fuel"}) do
      local m,mine,reopen,home=fixture()
      m.world["1,65,1"]="minecraft:diamond_ore" m.world["2,65,1"]="minecraft:diamond_ore"
      assert(mine.start()) assert(mine.tick()) assert(mine.tick())
      if reason=="inventory full" then for i=1,16 do m.inventory[i]={name="minecraft:stone",count=64} end else m.fuel=35 end
      assert(complete(mine)==reason)
      assert(m.pos.x==home.x and m.pos.z==home.z and m.heading==home.h)
      assert(mine.state().task and #mine.state().stack>0)
      m.inventory={} m.fuel=7000 mine=reopen()
      assert(mine.start()) assert(complete(mine)=="complete") assert(mine.finish())
      assert(not m.world["2,65,1"])
    end
  end)
  test("hazards, protection and blocked home routes report bounded refusal",function()
    for _,block in ipairs({"minecraft:water","minecraft:lava","minecraft:bedrock","minecraft:chest"}) do
      local m,mine=fixture() m.world["1,65,1"]=block
      assert(mine.start()) local why=complete(mine,30)
      assert(why~="complete" and #m.dug==0 and m.world["1,65,1"]==block)
    end
    local m,mine=fixture() assert(mine.start()) assert(mine.tick()) assert(mine.tick())
    m.world["1,65,0"]="minecraft:stone" mine.interrupt("recall")
    local ok,why=mine.tick() assert(not ok and why:find("no home route",1,true) and #m.dug==0)
  end)
  test("in-game mining commands save bounds and home without enabling mining",function()
    local h=assert(io and io.open and io.open("miner.lua") or fs.open("miner.lua","r"))
    local source=h.readAll and h.readAll() or h:read("*a")
    if h.readAll then h.close() else h:close() end
    local m=mocks.miner({home={x=1,y=65,z=0},facing=2,spine=1,ssot={enabled=true,server=0,dimension="minecraft:overworld"},nav={enabled=true}})
    m.env.dofile=function(path) return assert(loadfile(path,"t",m.env))() end
    assert(load(source,"=miner.lua","t",m.env))("mine","home","1","65","0","south")
    local cfg=m.env.textutils.unserialize(m.files["miner.cfg"])
    assert(cfg.mining.home.x==1 and cfg.mining.home.h==2 and cfg.mining.enabled==nil)
    assert(load(source,"=miner.lua","t",m.env))("mine","enable")
    assert(m.env.textutils.unserialize(m.files["miner.cfg"]).mining.enabled==true)
    assert(load(source,"=miner.lua","t",m.env))("mine","disable")
    assert(m.env.textutils.unserialize(m.files["miner.cfg"]).mining.enabled==false)
  end)
  test("the opted-in miner worker executes the lease engine through its real boot adapter",function()
    local h=assert(io and io.open and io.open("miner.lua") or fs.open("miner.lua","r"))
    local source=h.readAll and h.readAll() or h:read("*a")
    if h.readAll then h.close() else h:close() end
    local dim="minecraft:overworld"
    local home={dim=dim,x=1,y=65,z=0,h=2}
    local m=mocks.miner({home={x=1,y=65,z=0},facing=2,spine=1,ssot={server=0,dimension=dim},mining={enabled=true,home=home}})
    local e=m.env e.dofile=function(path) return assert(loadfile(path,"t",e))() end
    local code=assert(source:match("^(.*)\nopenModem%(%)"))
    local app=assert(load(code.."\nreturn {C=C,st=st,pos=pos}","=miner.lua","t",e))()
    local A,S=e.dofile("atomic.lua"),e.dofile("ssot.lua")
    local server=S.new({},{controllers={["1"]="test-secret-123456"}},function() return 10000 end,"1")
    local counter=0
    local function call(op,fields)
      counter=counter+1 local msg=A.copy(fields or {})
      msg.type,msg.v,msg.expect,msg.op="ssot",1,"ssot_reply",op
      msg.rid,msg.counter,msg.boot,msg.secret=tostring(counter),counter,"test","test-secret-123456"
      local r=server.handle(1,msg) return r,r and r.error
    end
    assert(call("mine-config",{zone={min={dim=dim,x=0,y=64,z=1},max={dim=dim,x=3,y=66,z=1},spacing=4}}).ok)
    app.C.ssot={call=call}
    app.C.nav=e.dofile("nav.lua").open({pose=home,bounds={min={dim=dim,x=0,y=64,z=0},max={dim=dim,x=3,y=66,z=1}},
      observe=function() return {dim=dim,x=m.pos.x,y=m.pos.y,z=m.pos.z} end,canExcavate=app.C.navCanExcavate,
      client={resync=function(q) return call("sync",{pose=q}).ok end,move=function(_,_,execute) return execute() end}})
    assert(app.C.nav.recover()) m.world["1,65,1"]="minecraft:diamond_ore"
    e.sleep=function() coroutine.yield() end
    local worker=coroutine.create(app.C.runMining)
    for _=1,100 do
      local ok,err=coroutine.resume(worker) assert(ok,err)
      local state=e.dofile("atomic.lua").read("mining.state")
      if state and state.value.phase=="done" then
        assert(not m.world["1,65,1"] and m.pos.z==0 and m.heading==2) return
      end
      if sleep then sleep(0) end
    end
    error("miner worker did not complete")
  end)
end
