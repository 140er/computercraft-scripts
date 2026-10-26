local H=dofile("tests/so/harness.lua")
local P=dofile("so-plan.lua")
local dim="minecraft:overworld"
local function fixture(options)
  options=options or {}
  local net=H.new()
  net.time=1000
  local m=net.machine({id=1,capacity=16000000})
  m.install({"so-store.lua","so-mod-build.lua","so-mod-shop.lua","so-ui.lua","so-plan.lua","so-mine-plan.lua"})
  local cfg={storageDeliveries=true,builderMaterialOrders=true,storageDeliveryOutput="room",storageDeliveryWorkers={3,2}}
  for k,v in pairs(options) do cfg[k]=v end
  m.files["so-server.cfg"]=H.encode(cfg)
  local store=m.env.dofile("so-store.lua")
  local f={m=m,net=net,cfg=cfg,calls={},sends={},inv={},sourceStock=0,destStock=0,journal="j0",fuel=10000,serial=0,held={},callbacks={}}
  f.pose={dim=dim,x=0,y=2,z=0,facing=1}
  f.points={{id="room",dim=0,x=2,y=1,z=0,side="down",kind="fuel"},
    {id="materials",dim=0,x=4,y=1,z=0,side="down",kind="storage"}}
  local function copy(v) return store.copy(v) end
  local function key(p) return p.x..","..p.y..","..p.z end
  local open=store.store
  store.store=function(path,...)
    local box=open(path,...)
    local save=box.save
    box.save=function(v)
      if f.failPath==path then return false,"disk full" end
      return save(v)
    end
    return box
  end
  m.env.SO={store=store,now=function() return net.time end,breathe=function() end,pair={key=function() return "paired" end},mods={}}
  local mods=m.env.SO.mods
  mods.state={emit=function() return true end}
  mods.display={screen=function() end}
  mods.drops={list=function() return copy(f.points) end,note=function() end}
  mods.cells={owner=function(x,y,z) return f.held[x..","..y..","..z] end,
    handoff=function(from,to,x,y,z) local k=x..","..y..","..z if f.held[k]~=from and f.held[k]~=to then return false end f.held[k]=to return true end,
    reserveMany=function(who,cells)
      for _,p in ipairs(cells) do if f.held[key(p)] and f.held[key(p)]~=who then return false end end
      for _,p in ipairs(cells) do f.held[key(p)]=who end return true
    end,releaseOwner=function(who) for k,v in pairs(f.held) do if v==who then f.held[k]=nil end end return true end}
  f.held[key(f.pose)]="gps:2"
  mods.lease={status=function(id) return {open=f.queued and f.queued.worker==id and f.queued.id,parkBatch=f.parkBatch~=false,setupFence=f.setupFence~=false,
      journal=f.journal,pose={x=f.pose.x,y=f.pose.y,z=f.pose.z,f=f.pose.facing},fuel=f.fuel,uncertain=f.uncertain,lost=f.lost} end,
    world=function() if not f.noWorld then return copy(f.pose) end end,
    restartReady=function() return f.restartReady~=false end,
    onReport=function(owner,cb) f.callbacks[owner]=cb end,
    assess=function(id,from,steps,opts)
      return P.assess(from,steps,{clear=opts.clear and function(p) return not f.unknown or not f.unknown[key(p)] end or nil,
        admit=function(_,_,p)
          if f.protected and f.protected[key(p)] then return false,"protected" end
          local who=f.held[key(p)]
          return not who or who==(opts.who or opts.owner..":"..id),"held"
        end})
    end,
    send=function(id,steps,opts)
      f.serial=f.serial+1
      f.queued={id="lease-"..f.serial,worker=id,steps=copy(steps),opts=copy(opts),intent=copy(opts.intent)}
      f.calls[#f.calls+1]=f.queued
      return f.queued.id
    end}
  local room={state="settled",barrier=1,highWater=0}
  f.room=room
  m.env.rednet.send=function(id,body,protocol)
    f.sends[#f.sends+1]={id=id,body=copy(body),protocol=protocol}
    if f.cutSend then error("power cut") end
    if body.cmd=="stock" then return true end
    local answer={v=1,rid=body.rid,outputToken=body.outputToken,requestRid=room.requestRid,state=room.state,barrier=room.barrier}
    if body.cmd=="output.claim" then
      if f.ignoreClaim then answer.state="settled"
      elseif f.legacyRoom then answer.state,answer.error="refused","room support missing"
      elseif room.token or room.state~="settled" then answer.state="busy"
      else room.token,room.state=body.outputToken,"claimed" answer.state="claimed" end
    elseif body.cmd=="get" or body.cmd=="order" then
      if body.outputToken then
        assert(body.outputToken==room.token and body.rid>room.highWater,"invalid room ownership or reused rid")
        room.highWater,room.requestRid,room.state=body.rid,body.rid,"busy"
      end
      if body.cmd=="get" and not f.delayed then f.sourceStock=f.sourceStock+(f.available or body.n) room.state="settled" room.barrier=room.barrier+1 end
      answer[1]="Getting "..body.n.." "..body.text
      answer.requestRid,answer.state=room.requestRid,room.state
    elseif body.cmd=="output.release" then
      assert(room.state=="settled" and body.barrier==room.barrier,"released without room settlement")
      room.token,room.requestRid=nil,nil answer.state="released"
    end
    if f.loseRelease and body.cmd=="output.release" then return true end
    if f.noReceipts then return true end
    f.replies=f.replies or {} f.replies[#f.replies+1]=answer
    return true
  end
  f.flush=function()
    local replies=f.replies or {} f.replies={}
    for _,reply in ipairs(replies) do f.shop.listen.roomsorter(9,reply) end
  end
  f.stock=function()
    f.shop.listen.roomsorter_stock(9,{totals={["minecraft:stone"]=f.stockCount or 128,["minecraft:coal"]=128},stacks={["minecraft:stone"]=64,["minecraft:coal"]=64}})
  end
  f.hello=function(id)
    f.build.handlers.hello({from=id or 2,body={inv=copy(f.inv),journal={id=f.journal,pose={x=f.pose.x,y=f.pose.y,z=f.pose.z,f=f.pose.facing}},capabilities={parkBatch=true,setupFence=true}}})
  end
  f.boot=function()
    f.shop=m.env.dofile("so-mod-shop.lua") mods.shop=f.shop
    f.build=m.env.dofile("so-mod-build.lua") mods.build=f.build
    f.hello(2) f.hello(3)
    f.shop.tick(net.time) f.build.tick() f.stock()
  end
  f.boot()
  f.restart=function() f.queued=nil f.callbacks={} f.boot() end
  f.request=function(item,n)
    return f.build.deliveryRequest({item=item or "minecraft:stone",n=n or 64,destination="materials",requester="test"})
  end
  f.status=function() return f.build.deliveryStatus(f.id) end
  f.step=function(noReport)
    net.time=net.time+100
    f.shop.tick(net.time) f.build.tick() f.flush()
    local q=f.queued
    if not q then return end
    f.queued=nil
    local results={}
    for _,step in ipairs(q.steps) do
      local result={ok=true}
      if step.op=="gps" then result.data=copy(f.pose) if f.badGPS then result.data.x=result.data.x+1 end
      elseif step.op=="inspectDown" or step.op=="inspect" then
        result.data={name="minecraft:chest"}
        if f.missingChest then result.ok=false result.data=nil end
      elseif step.op=="select" then f.slot=step.slot
      elseif step.op=="suckDown" or step.op=="suck" then
        assert(f.pose.x==2,"pickup away from pinned source")
        local n=math.min(step.n,f.sourceStock)
        result.ok=n>0
        if n>0 then
          f.inv[#f.inv+1]={slot=f.slot,name=f.unexpected or "minecraft:stone",count=n}
          f.sourceStock=f.sourceStock-n
        end
      elseif step.op=="dropDown" or step.op=="drop" then
        result.ok=not f.full
        if result.ok then
          for i,v in ipairs(f.inv) do if v.slot==f.slot then
            if f.pose.x==4 then f.destStock=f.destStock+v.count else f.sourceStock=f.sourceStock+v.count end
            table.remove(f.inv,i) break
          end end
        end
      else
        if f.moveFail then result.ok=false result.err="Movement obstructed"
        else f.pose=P.apply(f.pose,step.op) end
      end
      results[#results+1]=result
    end
    f.journal=f.journal.."n"
    local facts={pose={x=f.pose.x,y=f.pose.y,z=f.pose.z,f=f.pose.facing},journal=f.journal,inv=copy(f.inv),fuel=f.fuel}
    if f.changeFacts then f.changeFacts(facts,q,results) end
    if not noReport then f.callbacks.build(q.id,q.worker,results,{intent=q.intent,report=facts}) end
    return q
  end
  f.untilPhase=function(phase)
    for _=1,400 do
      if f.status() and f.status().phase==phase then return end
      if f.status() and f.status().stage=="held" then error(f.status().error) end
      f.step()
    end
    error("phase not reached "..phase)
  end
  f.finish=function()
    for _=1,500 do f.step() if f.status().stage=="complete" then return end end
    error("delivery did not complete "..H.encode(f.status()))
  end
  f.commands=function(cmd)
    local rows={} for _,v in ipairs(f.sends) do if v.body.cmd==cmd then rows[#rows+1]=v.body end end return rows
  end
  return f
end
local function paired(withBuilder)
  local net=H.new()
  local server=net.machine({id=1,modem=true,capacity=16000000,directories=true})
  server.install({"so-server.lua","so-store.lua","so-pair.lua","so-proto.lua","so-log.lua","so-plan.lua","so-ui.lua",
    "so-mine-plan.lua","so-mod-state.lua","so-mod-cells.lua","so-mod-lease.lua","so-mod-display.lua","so-mod-drops.lua","so-mod-build.lua","so-mod-shop.lua"})
  local worker=net.machine({id=2,modem=true,turtle=true,x=0,y=4,z=0,facing=1,fuel=10000,capacity=1000000})
  worker.install({"worker.lua","so-store.lua","so-pair.lua","so-proto.lua"})
  local builder=withBuilder and net.machine({id=3,modem=true,turtle=true,x=6,y=4,z=2,facing=3,fuel=10000,capacity=1000000})
  if builder then builder.install({"worker.lua","so-store.lua","so-pair.lua","so-proto.lua"}) end
  for _,m in ipairs({server,worker,builder}) do
    for _,name in ipairs({"x25519","random","blake3","chacha20","config","internal/util","internal/hw",
      "internal/curve25519","internal/fp","internal/edwards25519","internal/packing"}) do
      local path="lib/ccryptolib/"..name..".lua"
      local file=assert(io.open(path,"rb")) m.files[path]=file:read("*a") file:close()
    end
  end
  local cfg={pos={dim=dim,x=0,y=4,z=0},protectedAreas=true,storageDeliveries=true,builderMaterialOrders=true,
    storageDeliveryOutput="room",storageDeliveryWorkers={2}}
  server.files["so-server.cfg"]=H.encode(cfg)
  worker.files["so-worker.cfg"]=H.encode({dim=dim})
  worker.env.gps={locate=function() return worker.pos.x,worker.pos.y,worker.pos.z end}
  local key=string.rep("a",64)
  worker.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
  worker.files["so-journal"]=H.encode({schema=1,generation=1,value={id="2-seed",seq=1,moves={},dug={},park=true,
    pose={x=0,y=4,z=0,f=1},recovery={outcome="anchored",journal="prior"}}})
  local source={name="minecraft:chest",inv={}}
  local destination={name="minecraft:chest",inv={}}
  net.world["2,3,0"],net.world["4,3,0"]=source,destination
  local room={state="settled",barrier=1,gets=0}
  local function connect(m)
    local send=m.env.rednet.send
    m.env.rednet.send=function(id,body,protocol)
      if protocol~="roomsorter" then return send(id,body,protocol) end
      local reply={v=1,rid=body.rid,outputToken=body.outputToken,requestRid=room.requestRid,state=room.state,barrier=room.barrier}
      if body.cmd=="stock" then
        reply.totals={["minecraft:stone"]=128} reply.stacks={["minecraft:stone"]=64}
      elseif body.cmd=="output.claim" then
        if room.refuseClaim then reply.state,reply.error="refused","room support missing"
        else room.token=body.outputToken room.state="claimed" reply.state="claimed" end
      elseif body.cmd=="get" then
        assert(room.token==body.outputToken)
        room.gets=room.gets+1 room.requestRid=body.rid room.state="settled" room.barrier=room.barrier+1
        if not room.delayed then source.inv[1]={name=body.text,count=body.n}
        else room.state="busy" end
        reply.requestRid,reply.state=body.rid,"busy" reply[1]="Getting "..body.n
      elseif body.cmd=="output.release" then room.token=nil room.requestRid=nil reply.state="released" end
      m.inbox[#m.inbox+1]=table.pack("rednet_message",9,reply,"roomsorter")
      return true
    end
  end
  connect(server)
  server.boot("so-server.lua") net.flush()
  assert(server.env.SO.pair.remember(2,key))
  worker.boot("worker.lua") net.flush() net.advance(1)
  if builder then
    assert(server.env.SO.pair.remember(3,key))
    builder.files["so-worker.cfg"]=H.encode({dim=dim})
    builder.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
    builder.files["so-journal"]=H.encode({schema=1,generation=1,value={id="3-seed",seq=1,moves={},dug={},park=true,
      pose={x=6,y=4,z=2,f=3},recovery={outcome="anchored",journal="prior"}}})
    builder.env.gps={locate=function() return builder.pos.x,builder.pos.y,builder.pos.z end}
    builder.boot("worker.lua") net.flush() net.advance(1)
  end
  local f={net=net,server=server,worker=worker,builder=builder,source=source,destination=destination,room=room}
  f.prepare=function()
    local so=f.server.env.SO
    local breathe=so.breathe so.breathe=function() end
    assert(so.mods.drops.add({id="room",dim=0,x=2,y=3,z=0,side="down",kind="fuel"}))
    assert(so.mods.drops.add({id="materials",dim=0,x=4,y=3,z=0,side="down",kind="storage"}))
    for x=0,6 do for z=-2,2 do assert(so.mods.cells.markDug(x,4,z,dim)) end end
    so.mods.shop.listen.roomsorter_stock(9,{totals={["minecraft:stone"]=128},stacks={["minecraft:stone"]=64}})
    so.breathe=breathe
  end
  f.prepare()
  f.advance=function(seconds)
    net.advance(seconds)
    assert(not f.server.error,tostring(f.server.error)) assert(not worker.error,tostring(worker.error))
  end
  f.request=function()
    local so=f.server.env.SO
    local breathe=so.breathe so.breathe=function() end
    local id,err=so.mods.build.deliveryRequest({item="minecraft:stone",n=64,destination="materials",requester="test"})
    so.breathe=breathe
    return assert(id,err)
  end
  f.status=function() return f.server.env.SO.mods.build.deliveryStatus(f.id) end
  f.command=function(text)
    local so=f.server.env.SO local breathe=so.breathe so.breathe=function() end
    so.mods.display.screen("build").input({text=text}) so.breathe=breathe
  end
  f.job=function() local v=f.server.env.SO.store.read("so-data/build/job") return v and v.value end
  f.configure=function()
    f.command("area 6 3 2 6 3 2") f.command("material stone") f.command("add 3 6 4 2 w")
    for _=1,100 do f.advance(0.1) if f.job().fuel then break end end
    f.command("start")
  end
  f.restart=function()
    net.onBoot=function(m) if m.id==1 then connect(m) end end
    f.server=net.boot(f.server) net.flush()
  end
  return f
end
return function(test,equal)
  test("delivery flags default off and stock-only exact get refuses tools",function()
    local f=fixture({storageDeliveries=false})
    equal(f.request(),nil) equal(#f.commands("get"),0)
    for _,suffix in ipairs({"pickaxe","axe","shovel","hoe","sword"}) do
      assert(not f.build.deliveryItem("minecraft:diamond_"..suffix))
    end
    f=fixture()
    equal(f.request("minecraft:diamond_pickaxe"),nil) equal(#f.commands("output.claim"),0)
  end)
  test("delivery carries ordered 64 stone once and confirms the counted deposit and return",function()
    local f=fixture() f.id=assert(f.request())
    equal(f.status().worker,2) assert(f.build.assigned(2))
    equal(f.request(),nil)
    f.untilPhase("pickup")
    equal(f.status().text,"ordered 64 stone")
    equal(#f.commands("get"),1) equal(#f.commands("order"),0)
    local get=f.commands("get")[1] equal(get.text,"minecraft:stone") equal(get.n,64)
    f.finish() equal(f.destStock,64) equal(f.pose,{dim=dim,x=0,y=2,z=0,facing=1})
    equal(f.build.assigned(2),false) equal(#f.commands("get"),1)
  end)
  test("delivery requires receipts before probing a legacy room",function()
    local f=fixture() f.legacyRoom=true f.id=assert(f.request())
    for _=1,5 do f.step() end
    equal(f.status().stage,"refused") equal(f.status().terminal,true) equal(f.build.assigned(2),false)
    equal(#f.calls,0) equal(#f.commands("get"),0)
    assert(f.status().error:find("room support missing",1,true))
  end)
  test("delivery refuses uncertain busy assigned loaded and underfueled workers",function()
    for _,fault in ipairs({"uncertain","noWorld","setupFence","cargo","assigned","fuel","unknownFuel"}) do
      local f=fixture()
      if fault=="setupFence" then f.setupFence=false
      elseif fault=="cargo" then f.inv={{slot=1,name="minecraft:stone",count=1}} f.hello(2) f.hello(3)
      elseif fault=="assigned" then f.m.env.SO.mods.mine={mapView=function() return {turtles={["2"]={},["3"]={}}} end}
      elseif fault=="fuel" then f.fuel=1
      elseif fault=="unknownFuel" then f.fuel=nil
      else f[fault]=true end
      equal(f.request(),nil) equal(#f.commands("get"),0) equal(#f.commands("output.claim"),0)
    end
  end)
  test("delivery rejects unknown and protected round trips before ordering",function()
    for _,kind in ipairs({"unknown","protected"}) do
      local f=fixture() f[kind]={["1,2,0"]=true,["0,1,0"]=true,["0,3,0"]=true}
      equal(f.request(),nil) equal(#f.commands("get"),0)
    end
  end)
  test("delivery verifies the actual GPS fix and facing before each transfer",function()
    for _,fault in ipairs({"gps","facing","journal","move"}) do
      local f=fixture() f.id=assert(f.request())
      if fault=="gps" then f.badGPS=true
      elseif fault=="move" then f.moveFail=true
      else f.changeFacts=function(facts,q)
        if q.steps[1].op=="gps" then
          if fault=="facing" then facts.pose.f=(facts.pose.f+1)%4 else facts.journal=q.intent.journal end
        end
      end end
      for _=1,50 do f.step() if f.status().stage=="held" then break end end
      equal(f.status().stage,"held") equal(#f.commands("get"),0) equal(f.destStock,0)
      for _,q in ipairs(f.calls) do for _,step in ipairs(q.steps) do assert(not step.op:match("^suck")) end end
    end
  end)
  test("delivery returns existing output cargo and refuses another order",function()
    local f=fixture() f.sourceStock=3 f.id=assert(f.request())
    for _=1,100 do f.step() if f.status().stage=="held" then break end end
    equal(f.status().error,"output not empty") equal(f.sourceStock,3) equal(#f.inv,0) equal(#f.commands("get"),0)
  end)
  test("delivery holds unexpected tool cargo for manual recovery",function()
    local f=fixture() f.sourceStock=1 f.unexpected="minecraft:diamond_pickaxe" f.id=assert(f.request())
    for _=1,100 do f.step() if f.status().stage=="held" then break end end
    equal(f.status().error,"unexpected tool cargo; manual recovery") equal(#f.inv,1) equal(#f.commands("get"),0)
  end)
  test("delivery partial pickup holds at its two minute deadline without retries",function()
    local f=fixture() f.available=7 f.id=assert(f.request()) f.untilPhase("pickup")
    for _=1,20 do f.step() end
    equal(f.status().error,"partial 7/64") equal(f.status().text,"partial 7/64")
    f.net.time=f.status().deadline f.step()
    equal(f.status().error,"order timed out") equal(#f.commands("get"),1) equal(#f.inv,1)
    equal(f.request(),nil)
  end)
  test("delivery full destination holds cargo and reservations without another order",function()
    local f=fixture() f.id=assert(f.request()) f.untilPhase("deposit") f.full=true
    for _=1,10 do f.step() end
    equal(f.status().stage,"held") equal(f.destStock,0) equal(#f.inv,1)
    assert(next(f.held)) equal(#f.commands("get"),1) equal(#f.commands("output.release"),0)
  end)
  test("delivery restart mid-delivery quarantines the output and never replays a transfer",function()
    local f=fixture() f.id=assert(f.request()) f.untilPhase("routeDelivery")
    local calls=#f.calls f.restart()
    for _=1,20 do f.step() end
    equal(f.status().stage,"held") equal(#f.calls,calls) equal(#f.commands("get"),1)
    assert(f.build.assigned(2)) equal(#f.commands("output.release"),0)
    local output=f.shop.outputStatus(f.id) equal(output.reconciled,false)
  end)
  test("delivery flag disable mid-delivery retains cargo ownership and quarantine after restart",function()
    local f=fixture() f.id=assert(f.request()) f.untilPhase("routeDelivery")
    f.cfg.storageDeliveries=false f.m.files["so-server.cfg"]=H.encode(f.cfg) f.restart()
    local calls=#f.calls
    for _=1,20 do f.step() end
    equal(f.status().stage,"held") assert(f.build.assigned(2)) equal(#f.calls,calls)
    equal(f.request(),nil) equal(f.shop.order("stone",1),nil) equal(#f.commands("get"),1)
    equal(#f.commands("output.release"),0)
  end)
  test("delivery timeout ignores a late acceptance and late physical output until room settlement",function()
    local f=fixture() f.delayed=true f.id=assert(f.request()) f.untilPhase("pickup")
    local rid=f.status().orderRid f.net.time=f.status().deadline f.step()
    f.shop.listen.roomsorter(9,{"Getting 64 stone",rid=rid})
    f.sourceStock=64 f.restart()
    equal(f.status().stage,"held") equal(f.build.deliveryRetry(f.id),true)
    f.step()
    local ok,why=f.build.deliveryRetry(f.id)
    equal(ok,false) equal(why,"room settlement required")
    equal(#f.commands("get"),1) equal(#f.commands("output.release"),0)
    f.room.state="settled" f.net.time=f.net.time+10000 f.step()
    assert(f.build.deliveryRetry(f.id))
    for _=1,100 do f.step() if f.status().stage=="held" then break end end
    equal(f.status().error,"output not empty") equal(f.sourceStock,64)
    equal(#f.commands("get"),1) equal(#f.commands("output.release"),0)
  end)
  test("delivery changed destination refuses departure instead of substituting a chest",function()
    local f=fixture() f.id=assert(f.request()) f.points[2].x=5
    for _=1,5 do f.step() end
    equal(f.status().error,"delivery point changed") equal(#f.commands("get"),0)
  end)
  test("delivery save failure sends nothing and corrupt future state blocks restart",function()
    local f=fixture() f.failPath="so-data/build/delivery"
    equal(f.request(),nil) equal(#f.commands("output.claim"),0)
    f=fixture() f.id=assert(f.request())
    f.m.files["so-data/build/delivery.tmp"]=H.encode({schema=1,generation=999,value={v=2,serial=0}})
    f.restart() equal(f.request(),nil) equal(f.status().error,"delivery save unavailable")
  end)
  test("delivery paired worker executes fenced GPS inspect pickup deposit and home leases",function()
    local f=paired() f.id=f.request()
    for _=1,500 do f.advance(0.25) if f.status().stage=="complete" then break end end
    equal(f.status().stage,"complete") equal(f.room.gets,1)
    equal(f.destination.inv[1].count,64) equal(f.worker.pos,{x=0,y=4,z=0})
    equal(next(f.worker.inv),nil)
    assert(f.worker.env.fs.getFreeSpace("/")>0)
  end)
  test("delivery paired worker restart retains cargo and requires explicit recovery",function()
    local f=paired() f.id=f.request()
    for _=1,500 do f.advance(0.25) if f.status().picked==64 then break end end
    equal(f.status().picked,64) f.restart()
    f.advance(15) equal(f.status().stage,"held") equal(f.room.gets,1)
    equal(next(f.destination.inv),nil)
    local so=f.server.env.SO local breathe=so.breathe so.breathe=function() end
    assert(so.mods.build.deliveryRetry(f.id)) so.breathe=breathe
    f.advance(2)
    so.breathe=function() end assert(so.mods.build.deliveryRetry(f.id)) so.breathe=breathe
    for _=1,500 do f.advance(0.25) if f.status().stage=="complete" then break end end
    assert(f.status().stage=="complete",H.encode(f.status())) equal(f.destination.inv[1].count,64) equal(f.room.gets,1)
  end)

  test("builder one empty chest request reads ordered 64 stone without retries",function()
    local f=paired(true) f.room.delayed=true f.configure()
    for _=1,1200 do
      f.advance(0.1)
      if f.job().alert=="ordered 64 stone" then break end
    end
    equal(f.job().alert,"ordered 64 stone") equal(f.room.gets,1)
    equal(f.builder.pos,{x=6,y=4,z=2})
    local id=f.job().service.deliveryId assert(id)
    f.advance(125) equal(f.room.gets,1) equal(f.job().alert,"order timed out")
    f.restart() f.advance(15) equal(f.room.gets,1) equal(f.job().service.deliveryId,id)
  end)
  test("builder vacates its material access and resumes only after the delivery deposit",function()
    local f=paired(true) f.configure()
    for _=1,1800 do f.advance(0.1) if f.job().complete then break end end
    assert(f.job().complete,H.encode(f.job()).." delivery="..H.encode(f.server.env.SO.mods.build.deliveryStatus(f.job().service and f.job().service.deliveryId) or {})) equal(f.room.gets,1)
    equal(f.net.world["6,3,2"],"minecraft:stone")
  end)

  test("delivery refuses stale missing and insufficient exact stock before any room send",function()
    for _,kind in ipairs({"stale","missing","insufficient"}) do
      local f=fixture()
      if kind=="stale" then f.net.time=f.net.time+30000
      elseif kind=="missing" then f.shop=f.m.env.dofile("so-mod-shop.lua") f.m.env.SO.mods.shop=f.shop
      else f.stockCount=63 f.stock() end
      local before=#f.sends
      equal(f.request(),nil) equal(#f.sends,before)
    end
  end)
  test("delivery refuses an unadmitted claim while earlier room work is busy",function()
    local f=fixture() f.room.state="busy" f.id=assert(f.request())
    for _=1,10 do f.step() end
    equal(f.status().stage,"refused") equal(f.status().terminal,true) equal(f.build.assigned(2),false)
    equal(#f.calls,0) equal(#f.commands("get"),0)
  end)
  test("delivery stock loss after sampling stays partial and never crafts or substitutes",function()
    local f=fixture() f.available=3 f.id=assert(f.request()) f.untilPhase("pickup")
    for _=1,20 do f.step() end
    equal(f.status().picked,3) equal(f.status().error,"partial 3/64")
    equal(#f.commands("get"),1) equal(#f.commands("order"),0) equal(#f.commands("craft"),0)
    equal(f.commands("get")[1].text,"minecraft:stone")
  end)
  test("delivery disable without restart stops movement and keeps the saved output owner",function()
    local f=fixture() f.id=assert(f.request()) f.untilPhase("routeDelivery")
    f.cfg.storageDeliveries=false f.m.files["so-server.cfg"]=H.encode(f.cfg)
    local calls=#f.calls
    for _=1,20 do f.step() end
    equal(f.status().stage,"held") equal(#f.calls,calls) equal(#f.inv,1)
    equal(f.shop.order("stone",1),nil) equal(#f.commands("output.release"),0)
  end)
  test("delivery full destination resumes the same cargo only after explicit recovery and settlement",function()
    local f=fixture() f.id=assert(f.request()) f.untilPhase("deposit") f.full=true
    for _=1,20 do f.step() end
    equal(f.status().stage,"held") f.full=false
    f.net.time=f.net.time+10000 f.step()
    assert(f.build.deliveryRetry(f.id)) f.step()
    assert(f.build.deliveryRetry(f.id)) f.finish()
    equal(f.destStock,64) equal(#f.commands("get"),1)
  end)

  test("delivery legacy replies without receipts refuse before any probe",function()
    local f=fixture() f.noReceipts=true f.id=assert(f.request())
    f.net.time=f.net.time+16000 f.step()
    equal(f.status().stage,"refused") equal(f.status().terminal,true) equal(f.build.assigned(2),false)
    equal(#f.calls,0) equal(#f.commands("get"),0)
    assert(f.status().error:find("room support missing",1,true))
  end)
  test("delivery lost release receipt uses a terminal room status without another order",function()
    local f=fixture() f.loseRelease=true f.id=assert(f.request()) f.finish()
    equal(f.destStock,64) equal(#f.commands("get"),1) equal(f.status().stage,"complete")
  end)

  test("delivery stale journal after inspection cannot authorize a transfer",function()
    local f=fixture() f.id=assert(f.request()) f.untilPhase("pickup")
    for _=1,10 do
      local q=f.step()
      if q and q.intent.action=="inspect" then break end
    end
    f.journal=f.journal.."-foreign"
    local cargo=#f.inv
    f.step() equal(f.status().stage,"held") equal(#f.inv,cargo) equal(f.destStock,0)
  end)
  test("delivery actual GPS mismatch at the destination keeps all picked cargo",function()
    local f=fixture() f.id=assert(f.request()) f.untilPhase("deposit") f.badGPS=true
    for _=1,10 do f.step() end
    equal(f.status().stage,"held") equal(f.status().picked,64) equal(f.destStock,0)
    equal(#f.inv,1) equal(#f.commands("get"),1)
  end)

  test("delivery settlement without a matching claim cannot start the trip",function()
    local f=fixture() f.ignoreClaim=true f.id=assert(f.request())
    for _=1,10 do f.step() end
    equal(f.status().stage,"refused") equal(f.status().terminal,true) equal(f.build.assigned(2),false)
    equal(#f.calls,0) equal(#f.commands("get"),0)
  end)

  test("delivery recovery cannot probe an output without a saved claim proof",function()
    local f=fixture() f.ignoreClaim=true f.id=assert(f.request())
    for _=1,5 do f.step() end
    equal(f.status().stage,"refused") equal(f.status().terminal,true)
    local ok,why=f.build.deliveryRetry(f.id)
    equal(ok,false) equal(why,"delivery not held") equal(#f.calls,0)
    equal(f.build.assigned(2),false)
    f.ignoreClaim=false f.hello(2) f.hello(3)
    assert(f.request())
  end)
  test("delivery cannot move or transfer outside its durable trip reservations",function()
    local f=fixture() f.id=assert(f.request()) f.untilPhase("pickup")
    f.held["2,1,0"]=nil
    for _=1,5 do f.step() end
    equal(f.status().stage,"held") equal(f.destStock,0) equal(#f.inv,0)
    equal(f.status().error,"delivery reservation missing")
  end)

  test("delivery protected inventory blocks refuse admission from an otherwise clear access cell",function()
    local f=fixture() f.protected={["2,1,0"]=true}
    equal(f.request(),nil) equal(#f.commands("output.claim"),0) equal(#f.commands("get"),0)
  end)

  test("delivery missing destination holds picked cargo without another order",function()
    local f=fixture() f.id=assert(f.request()) f.untilPhase("deposit") f.missingChest=true
    for _=1,10 do f.step() end
    equal(f.status().error,"delivery chest missing") equal(f.destStock,0)
    equal(f.status().picked,64) equal(#f.inv,1) equal(#f.commands("get"),1)
  end)
  test("delivery failed return of pre-existing output cargo retains the claim and inventory",function()
    local f=fixture() f.sourceStock=3 f.full=true f.id=assert(f.request())
    for _=1,100 do f.step() if f.status().stage=="held" then break end end
    equal(f.status().error,"delivery chest full or transfer failed")
    equal(#f.inv,1) equal(#f.commands("get"),0) equal(#f.commands("output.release"),0)
    assert(f.shop.outputStatus(f.id))
  end)

  test("ordinary SHOP releases after timeout and room settlement so later orders and deliveries proceed",function()
    local f=fixture()
    for attempt=1,3 do
      f.stock()
      equal(f.shop.order("stone",1),nil) f.flush()
      assert(f.shop.order("stone",1)) f.flush()
      if attempt==2 then f.restart() end
      f.net.time=f.net.time+600001 f.shop.tick(f.net.time) f.flush()
      equal(#f.commands("output.release"),attempt-1)
      f.room.state="settled" f.room.barrier=f.room.barrier+1
      f.net.time=f.net.time+10000 f.shop.tick(f.net.time) f.flush()
      f.net.time=f.net.time+10000 f.shop.tick(f.net.time) f.flush()
      equal(#f.commands("output.release"),attempt)
      f.stock()
    end
    equal(#f.commands("order"),3)
    f.hello(2) f.hello(3) f.id=assert(f.request()) f.untilPhase("pickup")
    equal(#f.commands("get"),1)
  end)
  test("claim admission failure refuses without retaining a worker or blocking another request",function()
    for _,why in ipairs({"storage room missing","output ledger full","output quarantined"}) do
      local f=fixture() local claim=f.shop.outputClaim
      f.shop.outputClaim=function() return nil,why end
      local id,err=f.request() equal(id,nil) equal(err,why)
      equal(f.build.assigned(2),false) equal(#f.calls,0) equal(#f.commands("get"),0)
      local last=f.m.env.SO.store.read("so-data/build/delivery").value.last
      equal(last.stage,"refused") equal(last.error,why)
      f.shop.outputClaim=claim f.id=assert(f.request()) f.untilPhase("pickup")
    end
  end)
  test("legacy claim refusal survives restart and permits a later supported delivery",function()
    for _,disabled in ipairs({false,true}) do
      local f=fixture() f.legacyRoom=true f.id=assert(f.request())
      if disabled then f.cfg.storageDeliveries=false f.m.files["so-server.cfg"]=H.encode(f.cfg) end
      for _=1,5 do f.step() end
      equal(f.status().stage,"refused") equal(f.status().error,"room support missing")
      equal(f.shop.outputStatus(f.id),nil) equal(f.build.assigned(2),false)
      f.restart() equal(f.build.assigned(2),false)
      f.legacyRoom=false f.cfg.storageDeliveries=true f.m.files["so-server.cfg"]=H.encode(f.cfg)
      f.restart() f.id=assert(f.request()) f.untilPhase("pickup")
    end
  end)
  test("restart before claim admission refuses the delivery without reserving its worker",function()
    local f=fixture() f.noReceipts=true f.id=assert(f.request()) f.restart()
    equal(f.status().stage,"refused") equal(f.build.assigned(2),false)
    equal(#f.calls,0) equal(#f.commands("get"),0)
    assert(f.shop.outputStatus(f.id))
  end)
  test("an older interrupted claim with worker reservations remains held after restart",function()
    local f=fixture() f.id=assert(f.request())
    f.held["0,2,0"]="build:2" f.restart()
    equal(f.status().stage,"held") equal(f.build.assigned(2),true)
    equal(#f.calls,0) equal(#f.commands("get"),0)
  end)
  test("a failed refusal save dispatches nothing and can finish refusal after restart",function()
    local f=fixture() f.legacyRoom=true f.id=assert(f.request())
    f.failPath="so-data/build/delivery"
    for _=1,5 do f.step() end
    equal(#f.calls,0) equal(#f.commands("get"),0)
    f.failPath=nil f.restart()
    equal(f.status().stage,"refused") equal(f.build.assigned(2),false)
  end)
  test("builder request refusal returns to chest checks and accepts a manual refill without reordering",function()
    local f=paired(true)
    f.server.env.SO.mods.shop.deliveryReady=function() return false,"stock below 64" end
    f.configure()
    for _=1,1200 do f.advance(0.1) if f.job().service and f.job().service.deliveryDone then break end end
    equal(f.job().service.stage,"check") equal(f.job().service.deliveryAttempted,true)
    assert(f.job().retryAt) equal(f.room.gets,0)
    f.advance(25) equal(f.room.gets,0)
    f.destination.inv[1]={name="minecraft:stone",count=64}
    for _=1,800 do f.advance(0.1) if f.job().complete then break end end
    assert(f.job().complete,H.encode(f.job())) equal(f.room.gets,0)
    equal(f.net.world["6,3,2"],"minecraft:stone")
  end)
  test("builder terminal refused delivery returns to normal checks and accepts a manual refill",function()
    local f=paired(true) f.room.refuseClaim=true f.configure()
    for _=1,1200 do f.advance(0.1) if f.job().service and f.job().service.deliveryDone then break end end
    local job=f.job() equal(job.service.stage,"check") equal(job.service.deliveryAttempted,true)
    equal(f.server.env.SO.mods.build.deliveryStatus(job.service.deliveryId).stage,"refused")
    f.advance(25) equal(f.room.gets,0)
    f.destination.inv[1]={name="minecraft:stone",count=64}
    for _=1,800 do f.advance(0.1) if f.job().complete then break end end
    assert(f.job().complete,H.encode(f.job())) equal(f.room.gets,0)
  end)

end
