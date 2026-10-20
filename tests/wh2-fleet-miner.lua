local function suite(test,read,mocks)
  local source=read("miner.lua")
  local function fixture(patch,opted)
    local dim="minecraft:overworld"
    local home={dim=dim,x=1,y=65,z=0,h=2}
    local cfg={home={x=1,y=65,z=0},facing=2,spine=1,
      ssot={enabled=true,server=0,secret="test-secret-123456",dimension=dim},
      nav={enabled=true,bounds={min={dim=dim,x=-2,y=63,z=-2},max={dim=dim,x=5,y=67,z=6}}},
      mining={enabled=false,home=home},wh2={enabled=true}}
    if opted==false then cfg.wh2=nil end
    local m=mocks.miner(cfg)
    local e=m.env
    local now,revision,counter,epoch=10000,1,0,1
    local online,inCall,inNative=true,false,false
    local values={enabled=true,navigation=true,mining=true,warehouse=false,autoDropoff=false,autoCharge=false,
      returnHome=true,mesh=true,traffic=false,fuelLow=200,fuelTarget=2000,fuelMargin=32,minTripFuel=2000,
      minFreeSlots=2,fullnessHigh=.875,chargeTimeoutMs=60000,dropoffId=false,chargerId=false,
      keep={},miningTargets={},miningMode="thorough",branchLength=64,reach=96,tripSeconds=900,
      sessionSeconds=1800,minSessionSeconds=180,thoroughGap=4,fastGap=2,layerStep=3,layers=4,
      veinLimit=64,junkEvery=10,retrySeconds=1,warehouseFuelMargin=16,
      navMaxCells=2048,navMaxSearch=2048,navBatch=32,trafficWaits=80,trafficWaitMs=250,
      routeRetries=5,trafficRouteRetries=80,trailLength=64,rpcTimeoutMs=5000}
    for k,v in pairs(patch or {}) do values[k]=v end
    e.os.epoch=function() return now end
    e.os.clock=function() return now/1000 end
    e.os.getComputerID=function() return 1 end
    e.sleep=function(seconds) now=now+math.max(seconds or 0,.001)*1000 coroutine.yield() end
    e.gps={locate=function() return m.pos.x,m.pos.y,m.pos.z end}
    local requested,locations,sites,locks,reports={},{},{},{},{}
    local function copy(v) return assert(load("return "..mocks.encode(v),"=copy","t",{}))() end
    e.dofile=function(path) return assert(loadfile(path,"t",e))() end
    local server=e.dofile("ssot.lua").new({},{controllers={["1"]="test-secret-123456"}},function() return now end,"1")
    local rpc={}
    local function call(op,fields)
      assert(not inCall and not inNative,"outbound calls overlapped a native action or another call")
      inCall=true
      requested[#requested+1]={op=op,fields=copy(fields or {})}
      if not online then inCall=false return nil,"test server unavailable" end
      local body=fields and fields.body
      local result
      if op=="wh2-get" then
        if body.topic=="settings" then
          result={ok=true,revision=revision,cursor=0,records={{v=1,id="1",revision=revision,effective=copy(values)}}}
        elseif body.topic=="locations" then
          local rows={}
          for _,loc in ipairs(locations) do if body.id==nil or body.id==loc.id then rows[#rows+1]=copy(loc) end end
          result={ok=true,revision=1,cursor=0,records=rows}
        end
      elseif op=="wh2-report" then
        reports[#reports+1]=copy(body.record)
        result={ok=true,settingsRevision=revision}
      elseif op=="wh-sites" or op=="wh-lock" then
        local site=sites[fields.name]
        if not site then result={ok=false,error="unknown test site"}
        elseif op=="wh-lock" and locks[fields.name] and locks[fields.name]~=1 then result={ok=false,error="bay occupied"}
        else
          if op=="wh-lock" then locks[fields.name]=1 end
          result={ok=true,site=copy(site)}
        end
      elseif op=="wh-unlock" then
        assert(locks[fields.name]==1,"released another owner's lock")
        locks[fields.name]=nil result={ok=true}
      else
        counter=counter+1
        local msg=copy(fields or {})
        msg.type,msg.v,msg.expect,msg.op="ssot",1,"ssot_reply",op
        msg.rid,msg.counter,msg.boot,msg.secret=tostring(counter),counter,"test","test-secret-123456"
        result=server.handle(1,msg)
      end
      inCall=false
      return result,result and result.error
    end
    rpc.call=call
    function rpc.resync(p)
      local r,why=call("sync",{pose=p}) return r and r.ok,why,epoch
    end
    function rpc.move(from,to,execute)
      local grant,why=call("reserve",{pose=from,to=to})
      if not grant or not grant.ok then return false,why end
      local fields={pose=from,to=to,token=grant.token,epoch=grant.epoch}
      local start,why=call("start",fields) if not start or not start.ok then return false,why end
      local ok,why=execute()
      if ok then assert(call("commit",fields).ok) else assert(rpc.resync(from)) end
      return ok,why
    end
    function rpc.dispatch(sender,packet,protocol,verified)
      if sender==0 and protocol=="fleetserver" and packet.verified==true then verified(packet) return true end
      return false
    end
    e.dofile=function(path)
      if path=="ssot-client.lua" then return {new=function() return rpc end} end
      return assert(loadfile(path,"t",e))()
    end
    local scheduled
    e.parallel.waitForAny=function(...) scheduled={...} end
    local app=assert(load(source.."\nreturn {C=C,cfg=cfg,pos=pos,st=st,mesh=devPairLoop,listener=listener}","=miner.lua","t",e))()
    assert(#scheduled==5,"SSOT boot did not retain its receiver and role worker")
    assert(call("mine-config",{zone={min={dim=dim,x=0,y=64,z=1},max={dim=dim,x=3,y=66,z=3},spacing=4}}).ok)
    local f={m=m,e=e,app=app,home=home,values=values,requested=requested,reports=reports,locks=locks,locations=locations,sites=sites}
    function f.change(p)
      for k,v in pairs(p) do values[k]=v end
      revision=revision+1
      local count=#requested
      local ok,why=coroutine.resume(m.app,"rednet_message",0,
        {verified=true,op="wh2-changed",body={wh2=1,topic="settings",revision=revision}},"fleetserver")
      assert(ok,why)
      assert(#requested==count,"receiver sent an outbound settings request")
    end
    local settings={v=1,revision=revision,global=copy(values),roles={},computers={}}
    function f.scopeChange(scope,patch)
      local target=settings.global
      if scope=="role" then settings.roles.miner=settings.roles.miner or {} target=settings.roles.miner
      elseif scope=="computer" then settings.computers["1"]=settings.computers["1"] or {} target=settings.computers["1"] end
      for key,value in pairs(patch) do target[key]=value end
      settings.revision=settings.revision+1
      f.change(e.dofile("wh2-fleet.lua").effective(settings,1,"miner"))
    end
    function f.boot()
      m.app=coroutine.create(app.C.ssotReceive)
      if debug and debug.sethook then
        debug.sethook(m.app,function() error(debug.traceback(m.app,"receiver did not yield")) end,"",2000000)
      end
      assert(coroutine.resume(m.app))
      f.worker=coroutine.create(app.C.ssotWorker)
      f.step()
    end
    function f.step(n)
      for _=1,n or 1 do
        if debug and debug.sethook then
          debug.sethook(f.worker,function() error(debug.traceback(f.worker,"fleet worker did not yield")) end,"",2000000)
        end
        local ok,why=coroutine.resume(f.worker) assert(ok,why)
        assert(coroutine.status(f.worker)~="dead","role worker exited")
      end
    end
    function f.untilTrue(predicate,limit)
      for _=1,limit or 1000 do if predicate() then return end f.step() end
      local state=f.app.C.mining and f.app.C.mining.state() or {}
      error("fleet worker did not reach the expected state: "..tostring(f.app.C.fleetError)
        ..", phase="..tostring(state.phase)..", service="..tostring(state.service)..", dropped="..f.dropped)
    end
    function f.online(v) online=v end
    function f.epoch(v) epoch=v end
    function f.advance(dt) now=now+dt end
    function f.native(fn,...)
      inNative=true local result=table.pack(pcall(fn,...)) inNative=false
      assert(result[1],result[2]) return table.unpack(result,2,result.n)
    end
    function f.reboot()
      app=assert(load(source.."\nreturn {C=C,cfg=cfg,pos=pos,st=st}","=miner.lua","t",e))()
      f.app=app f.boot()
    end
    function f.site(id,kind,x)
      local p={dim=dim,x=x or home.x,y=home.y,z=home.z,h=home.h}
      local name="old-"..id
      sites[name]={kind=kind=="charge" and "charge" or "drop",pose=copy(p),side="front"}
      p.v,p.frame,p.yAbs,p.conf,p.src,p.anchoredAt=1,"abs",true,"certain","typed",now
      local block=copy(p) block.z=block.z+1
      locations[#locations+1]={v=1,id=id,kind=kind,enabled=true,block=block,access={pose=copy(p),side="front"},
        revision=1,lockId="inventory:"..id,
        siteNames={drop=kind=="dropoff" and name or false,charge=kind=="charge" and name or false,source=false}}
      return name
    end
    e.peripheral.wrap=function() return {list=function() return {} end} end
    f.dropped=0
    e.turtle.drop=function(count)
      local item=m.inventory[m.selected]
      assert(item and next(locks),"drop did not own its physical site")
      if f.fullChest then return false end
      local moved=math.min(count,item.count)
      item.count=item.count-moved if item.count==0 then m.inventory[m.selected]=nil end
      f.dropped=f.dropped+moved
      if f.afterDrop then f.native(f.afterDrop) end
      return true
    end
    e.turtle.dropUp=e.turtle.drop e.turtle.dropDown=e.turtle.drop
    return f
  end

  test("fleet opt-in defaults off and does not load the fleet client",function()
    local f=fixture(nil,false)
    assert(not f.app.C.fleetOptIn and f.app.cfg.wh2.enabled==false and not f.app.C.fleet)
    assert(f.e.textutils.unserialize(f.m.files["miner.cfg"]).wh2==nil,"startup rewrote local setup")
  end)
  test("fleet boot mines with remote settings and preserves ESTOP across refresh",function()
    local f=fixture()
    f.m.world["1,65,1"]="minecraft:diamond_ore"
    f.boot()
    assert(f.app.C.fleet.ready() and f.app.cfg.mining.enabled==false)
    f.untilTrue(function() return f.app.C.mining.state().phase=="done" end)
    assert(not f.m.world["1,65,1"] and f.m.pos.z==0 and f.m.heading==2)
    f.app.C.nav.stop()
    f.change({mining=true,enabled=true}) f.step(15)
    assert(f.app.C.nav.stopped(),"settings cleared ESTOP")
    assert(f.e.textutils.unserialize(f.m.files["miner.cfg"]).mining.enabled==false)
  end)
  test("fleet reports confirmed navigation pose and occupied slots rather than item counts",function()
    local f=fixture({mining=false})
    f.m.inventory[2]={name="minecraft:diamond",count=1}
    f.m.inventory[9]={name="minecraft:stone",count=64}
    f.boot()
    f.app.pos.x=999
    assert(f.app.C.fleet.record()) assert(f.app.C.fleet.tick())
    local report=assert(f.reports[#f.reports])
    assert(report.v==1 and report.id=="cc:1" and report.role=="miner" and report.pose.x==1)
    assert(report.pose.v==1 and report.pose.frame=="abs" and report.pose.yAbs and report.pose.h==2)
    assert(report.pose.conf=="certain" and report.pose.src=="gps" and report.pose.anchoredAt>0)
    assert(report.heading==nil and report.poseConfirmed==nil and report.inventory.usedSlots==2 and report.inventory.fullness==.125)
    assert(report.appliedSettingsRevision==1)
  end)
  test("a settings hint during digging pauses the next move and retains unfinished ore",function()
    local f=fixture()
    f.m.world["1,65,1"]="minecraft:diamond_ore" f.m.world["2,65,1"]="minecraft:diamond_ore"
    local dig=f.e.turtle.dig
    local interrupted=false
    f.e.turtle.dig=function()
      return f.native(function()
        local ok,why=dig()
        if not interrupted then interrupted=true f.change({mining=false}) end
        return ok,why
      end)
    end
    f.boot()
    f.untilTrue(function() return interrupted and f.app.C.mining.state().phase=="home" end)
    local state=f.app.C.mining.state()
    assert(f.m.pos.z==0 and state.progress==0 and state.task and not state.action)
    assert(#f.m.dug==1 and f.m.world["2,65,1"],"mining continued after the setting change")
    f.change({mining=true})
    f.untilTrue(function() return f.app.C.mining.state().phase=="done" end)
    assert(not f.m.world["2,65,1"],"resume lost the unfinished vein")
  end)
  test("an unavailable server and a known newer revision pause work without offline autonomy",function()
    local f=fixture({mining=false}) f.boot()
    assert(f.m.files["wh2-settings.cache"])
    f.online(false) f.change({mining=true}) f.step(20)
    assert(not f.app.C.fleet.ready() and f.m.pos.z==0 and #f.m.dug==0)
    assert(f.app.C.fleetSnapshot().state=="blocked")
    f.online(true) f.advance(3001) f.step(20)
    assert(f.app.C.fleet.ready())
  end)
  test("a lost commit leaves the worker polling with both physical journals intact",function()
    local f=fixture()
    f.m.world["1,65,1"]="minecraft:diamond_ore" f.m.world["2,65,1"]="minecraft:diamond_ore"
    local failed=false
    f.m.afterMove=function() if not failed then failed=true f.online(false) end end
    f.boot()
    f.untilTrue(function() return failed and f.app.C.fleetRecovery end)
    local A=f.e.dofile("atomic.lua")
    assert(A.read("nav.state").value.action and A.read("mining.state").value.action)
    f.step(25)
    assert(f.app.C.fleetSnapshot().state=="blocked" and coroutine.status(f.worker)=="suspended")
    assert(f.m.world["2,65,1"] and f.app.C.mining.state().task)
  end)
  test("idle miners poll settings within three seconds without a competing outbound worker",function()
    local f=fixture({mining=false,retrySeconds=20}) f.boot()
    local count=#f.requested
    f.advance(3000) f.step(3)
    local polls=0
    for i=count+1,#f.requested do
      local r=f.requested[i]
      if r.op=="wh2-get" and r.fields.body.topic=="settings" then polls=polls+1 end
    end
    assert(polls>=1 and f.m.pos.z==0)
  end)
  test("mesh can fetch startup settings and follows the effective mesh toggle",function()
    local f=fixture({mining=false,mesh=false})
    local sent=0
    local modem={isWireless=function() return true end,open=function() end,transmit=function() sent=sent+1 end}
    f.e.peripheral.find=function() return modem end
    f.e.rednet.CHANNEL_REPEAT=65533 f.e.rednet.CHANNEL_BROADCAST=65535
    local relay=coroutine.create(f.app.mesh)
    assert(coroutine.resume(relay))
    local function packet(id)
      local ok,why=coroutine.resume(relay,"modem_message","left",65533,10,{nMessageID=id,nRecipient=4})
      assert(ok,why)
    end
    packet(1) assert(sent==2,"startup blocked the route needed to fetch settings")
    f.boot() packet(2) assert(sent==2,"mesh ignored shared settings")
    f.change({mesh=true}) assert(f.app.C.fleetBoundary("poll"))
    packet(3) assert(sent==4)
  end)
  test("automatic drop-off uses shared sites and stops on a live toggle without losing its lock journal",function()
    local f=fixture({mining=false,warehouse=true,autoDropoff=true,autoCharge=false,minFreeSlots=0})
    local name=f.site("shared-drop","dropoff")
    for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
    f.afterDrop=function() f.afterDrop=nil f.change({autoDropoff=false}) end
    f.boot()
    f.untilTrue(function() return f.dropped==1 and f.locks[name]==nil end)
    f.step(30)
    assert(f.dropped==1 and f.app.cfg.warehouse==nil,"drop-off used local service setup")
    local used=0 for _,item in pairs(f.m.inventory) do if item.count>0 then used=used+1 end end
    assert(used==13)
    for _,request in ipairs(f.requested) do
      if request.op=="wh-lock" then assert(request.fields.name==name) end
      if request.op=="wh-sites" then assert(request.fields.name~=nil) end
    end
    f.change({autoDropoff=true,fullnessHigh=.5})
    f.untilTrue(function() return f.dropped==14 and f.locks[name]==nil end)
  end)
  test("auto-charge is independent of drop-off and adopts its live fuel target",function()
    local f=fixture({mining=false,warehouse=true,autoCharge=true,autoDropoff=false,minTripFuel=600,dropoffId="unused-drop"})
    local name=f.site("shared-charge","charge")
    f.m.fuel=100 f.boot()
    f.untilTrue(function() return f.locks[name]==1 end)
    f.m.fuel=1100 f.change({fuelTarget=1000})
    f.untilTrue(function() return f.locks[name]==nil end)
    assert(f.dropped==0 and f.m.pos.x==f.home.x and f.m.pos.z==f.home.z)
    for _,request in ipairs(f.requested) do
      if request.op=="wh-sites" or request.op=="wh-lock" then assert(request.fields.name==name) end
    end
  end)
  test("free-slot and fullness thresholds independently trigger shared drop-off",function()
    for _,threshold in ipairs({{minFreeSlots=3,fullnessHigh=1,used=14},{minFreeSlots=0,fullnessHigh=.5,used=8}}) do
      local f=fixture({mining=false,warehouse=true,autoDropoff=true,minFreeSlots=threshold.minFreeSlots,
        fullnessHigh=threshold.fullnessHigh})
      local name=f.site("drop","dropoff")
      for slot=1,threshold.used do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
      f.boot()
      f.untilTrue(function() return f.dropped==threshold.used and not f.locks[name] end)
      assert(f.dropped==threshold.used)
    end
  end)
  test("live keep rules preserve stacks before the next drop",function()
    local f=fixture({mining=false,warehouse=true,autoDropoff=true})
    local name=f.site("drop","dropoff")
    for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
    f.afterDrop=function() f.afterDrop=nil f.change({keep={["minecraft:diamond"]=true}}) end
    f.boot()
    f.untilTrue(function() return f.dropped==1 and not f.locks[name] end)
    f.step(20)
    assert(f.dropped==1 and f.app.C.fleetSnapshot().inventory.usedSlots==13)
  end)
  test("an inventory threshold reached by a dig stops its following move",function()
    local f=fixture()
    f.m.world["1,65,1"]="minecraft:diamond_ore"
    local dig=f.e.turtle.dig
    f.e.turtle.dig=function()
      local ok,why=dig()
      for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
      return ok,why
    end
    f.boot()
    f.untilTrue(function() return #f.m.dug==1 and f.app.C.mining.state().phase=="home" end)
    assert(f.m.pos.z==0 and f.app.C.mining.state().progress==0 and f.app.C.mining.state().task)
  end)
  test("a changed fuel limit stops the next physical action and a lower limit retains return fuel",function()
    local f=fixture()
    f.m.world["1,65,1"]="minecraft:diamond_ore"
    local dig=f.e.turtle.dig
    f.e.turtle.dig=function()
      return f.native(function()
        local ok,why=dig() f.change({fuelLow=8000,fuelTarget=9000}) return ok,why
      end)
    end
    f.boot()
    f.untilTrue(function() return #f.m.dug==1 and f.app.C.mining.state().phase=="home" end)
    assert(f.m.pos.z==0 and f.app.C.mining.state().reason=="low fuel")
    f.change({fuelLow=0,fuelMargin=8000}) f.step(20)
    assert(f.m.pos.z==0 and f.app.C.mining.state().task and #f.m.dug==1)
  end)
  test("a completed physical drop recovers its saved transfer without duplicating delivery",function()
    local f=fixture({mining=false,warehouse=true,autoDropoff=true})
    local name=f.site("drop","dropoff")
    for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
    f.afterDrop=function() f.afterDrop=nil error("injected transfer crash") end
    f.boot()
    assert(f.app.C.fleetRecovery and f.app.C.fleetSnapshot().state=="blocked")
    local saved=f.e.dofile("atomic.lua").read("mining-warehouse.state").value
    assert(saved.pending and f.dropped==1 and f.locks[name]==1)
    f.reboot()
    f.untilTrue(function() return f.dropped==14 and not f.locks[name] end)
    assert(f.dropped==14 and next(f.m.inventory)==nil)
  end)
  test("a reboot with a saved settings cache waits visibly for the server before resuming",function()
    local f=fixture({mining=false}) f.boot()
    f.online(false) f.reboot()
    assert(f.app.C.fleet and not f.app.C.fleet.ready() and f.app.C.fleetSnapshot().state=="blocked")
    f.step(15)
    assert(f.m.pos.z==0 and #f.m.dug==0)
    f.online(true) f.advance(3001) f.step(30)
    assert(f.app.C.fleet.ready() and f.app.C.nav.confirmed())
  end)
  test("a live charge timeout releases the bay and retains the mining traversal",function()
    local f=fixture({mining=false,warehouse=true,autoCharge=true,minTripFuel=600})
    local name=f.site("charge","charge")
    f.m.fuel=100 f.boot()
    f.untilTrue(function() return f.locks[name]==1 end)
    f.change({chargeTimeoutMs=1000}) f.advance(1001)
    f.untilTrue(function() return not f.locks[name] end)
    assert(f.m.pos.x==f.home.x and f.m.pos.z==f.home.z and f.dropped==0)
  end)
  test("short trips resume the saved strip and finish every allocated tunnel cell",function()
    local f=fixture({branchLength=1})
    for z=1,3 do f.m.world["1,65,"..z]="minecraft:diamond_ore" end
    f.boot()
    f.untilTrue(function() return f.app.C.mining.state().phase=="home" and f.app.C.mining.state().reason=="trip length" end)
    assert(f.app.C.mining.state().progress==1 and f.m.world["1,65,2"])
    f.untilTrue(function() return f.app.C.mining.state().phase=="done" end)
    for z=1,3 do assert(not f.m.world["1,65,"..z],"short trip skipped a tunnel cell") end
  end)
  test("live reach and vein limits retain the unfinished traversal until raised",function()
    for _,limit in ipairs({{reach=1},{veinLimit=1}}) do
      local f=fixture(limit)
      f.m.world["1,65,1"]="minecraft:stone" f.m.world["2,65,1"]="minecraft:diamond_ore"
      f.m.world["1,65,2"]="minecraft:diamond_ore" f.m.world["1,65,3"]="minecraft:diamond_ore"
      f.boot()
      f.untilTrue(function()
        local state=f.app.C.mining.state()
        return state.phase=="home" and (state.reason=="mining reach" or state.reason=="vein limit")
      end)
      assert(f.app.C.mining.state().task and f.m.world["1,65,3"])
      f.change({reach=96,veinLimit=64})
      f.untilTrue(function() return f.app.C.mining.state().phase=="done" end)
      assert(not f.m.world["2,65,1"] and not f.m.world["1,65,3"])
    end
  end)
  test("fast mode finishes a queued vein before skipping new wall ore",function()
    local f=fixture()
    f.m.world["1,65,1"]="minecraft:stone"
    for x=0,3 do if x~=1 then f.m.world[x..",65,1"]="minecraft:diamond_ore" end end
    local changed=false
    f.m.afterMove=function()
      if not changed and f.m.pos.x==2 and f.m.pos.z==1 then changed=true f.change({miningMode="fast"}) end
    end
    f.boot()
    f.untilTrue(function() return f.app.C.mining.state().phase=="done" end)
    assert(changed and not f.m.world["2,65,1"] and not f.m.world["3,65,1"])
    assert(f.m.world["0,65,1"],"fast mode began a new wall vein")
  end)
  test("a live trip duration returns home before another extraction",function()
    local f=fixture()
    f.m.world["1,65,1"]="minecraft:diamond_ore"
    f.boot() f.change({tripSeconds=1}) f.advance(1001)
    f.untilTrue(function() return f.app.C.mining.state().phase=="home" and f.app.C.mining.state().reason=="trip time" end)
    assert(#f.m.dug==0 and f.m.pos.z==0 and f.app.C.mining.state().task)
    f.change({tripSeconds=900})
    f.untilTrue(function() return f.app.C.mining.state().phase=="done" end)
    assert(not f.m.world["1,65,1"])
  end)
  test("zero fuel thresholds still reserve the next move and its known return route",function()
    local f=fixture({mining=false,fuelLow=0,fuelMargin=0,minTripFuel=1}) f.boot()
    f.e.sleep=function() end
    local nav=f.app.C.nav
    for x=2,3 do nav.record({dim=f.home.dim,x=x,y=65,z=0},"minecraft:air") end
    f.change({mining=true}) assert(f.app.C.mining.start()) assert(f.app.C.fleetBoundary("mine"))
    f.m.fuel=3
    local ok,why=nav.go({dim=f.home.dim,x=3,y=65,z=0},"walk")
    assert(not ok and why=="low fuel" and f.m.pos.x==2 and f.m.fuel==2)
    assert(nav.homeCost(f.home)==1,"low fuel erased the return path")
    assert(f.app.C.fleetBoundary("return")) assert(nav.go(f.home,"walk"))
  end)
  test("live navigation budgets refuse new exploration while preserving saved return routes",function()
    local f=fixture({mining=false}) f.boot()
    f.e.sleep=function() end
    local nav=f.app.C.nav
    for x=2,4 do nav.record({dim=f.home.dim,x=x,y=65,z=0},"minecraft:air") end
    f.change({navMaxCells=1,navMaxSearch=1,navBatch=1,traffic=true,trafficWaits=2,trafficWaitMs=100,
      routeRetries=1,trafficRouteRetries=2,trailLength=2})
    assert(f.app.C.fleetBoundary("navigation"))
    local ok,why=nav.go({dim=f.home.dim,x=4,y=65,z=0},"walk")
    assert(not ok and why=="search budget" and f.m.pos.x==1)
    f.change({navMaxSearch=2048}) assert(f.app.C.fleetBoundary("navigation"))
    assert(nav.go({dim=f.home.dim,x=4,y=65,z=0},"walk"))
    assert(nav.homeCost(f.home)==3,"budget change deleted the known return route")
  end)
  test("framed observations require reconciliation and service targets cross an explicit boundary",function()
    local f=fixture({mining=false}) f.boot()
    local nav=f.app.C.nav
    local observed=nav.fleetPose()
    assert(observed.v==1 and observed.frame=="abs" and observed.h==2 and observed.anchoredAt>0)
    local target=assert(nav.legacyTarget(observed))
    assert(target.v==nil and target.frame==nil and target.x==1 and target.h==2)
    for key,value in pairs({v=2,frame="f:other",yAbs=false,conf="suspect",src="unknown",anchoredAt=0,h=4}) do
      local bad=f.e.dofile("atomic.lua").copy(observed) bad[key]=value
      assert(not nav.legacyTarget(bad),"unsafe service pose crossed the legacy boundary")
    end
    assert(not nav.legacyTarget(false) and not nav.legacyTarget(nav.pose()))
    assert(not nav.go(observed,"walk") and nav.homeCost(observed)==false)
    f.e.gps.locate=function() end
    assert(not nav.recover() and not nav.fleetPose() and f.app.C.fleetSnapshot().pose==false)
  end)
  test("north remains heading zero in framed reports and legacy movement",function()
    local f=fixture({mining=false}) f.boot()
    f.e.sleep=function() end
    assert(f.app.C.fleetBoundary("navigation"))
    assert(f.app.C.nav.face(0))
    local observed=f.app.C.fleetSnapshot().pose
    assert(observed.h==0 and f.m.heading==0)
    f.app.C.nav.record({dim=f.home.dim,x=1,y=65,z=-1},"minecraft:air")
    assert(f.app.C.nav.step(0,"walk"))
    assert(f.m.pos.z==-1 and f.app.C.fleetSnapshot().pose.h==0)
  end)
  test("unknown turtle measurements stay false while measured zero stays zero",function()
    local f=fixture({mining=false}) f.boot()
    f.e.turtle.getFuelLevel=function() return false end
    f.e.turtle.getFuelLimit=function() return nil end
    f.e.turtle.getItemCount=function() return false end
    local s=f.app.C.fleetSnapshot()
    assert(s.fuel.level==false and s.fuel.limit==false)
    assert(s.inventory.usedSlots==false and s.inventory.fullness==false)
    assert(f.app.C.fleet.record())
    f.e.turtle.getFuelLevel=function() return 0 end
    f.e.turtle.getFuelLimit=function() return 20000 end
    f.e.turtle.getItemCount=function() return 0 end
    s=f.app.C.fleetSnapshot()
    assert(s.fuel.level==0 and s.inventory.usedSlots==0 and s.inventory.fullness==0)
  end)
  test("waiting at home retains the mining job without reporting idle",function()
    local f=fixture()
    local dig=f.e.turtle.dig
    f.e.turtle.dig=function() local ok,why=dig() f.change({mining=false}) return ok,why end
    f.m.world["1,65,1"]="minecraft:diamond_ore" f.boot()
    f.untilTrue(function() return f.app.C.mining.state().phase=="home" end)
    f.app.C.fleetError=nil
    local s=f.app.C.fleetSnapshot()
    assert(s.state=="blocked" and s.currentJob.kind=="mine")
    assert(f.app.C.fleet.record())
  end)
  test("server epoch zero is numeric after decimal migration and survives reboot",function()
    for _,epoch in ipairs({0,"0"}) do
      local f=fixture({mining=false}) f.epoch(epoch) f.boot()
      assert(f.app.C.nav.controlState().epoch==0)
      assert(f.app.C.nav.control("estop",0,1))
      assert(not f.app.C.nav.control("go","0",2))
      f.reboot()
      assert(f.app.C.nav.controlState().epoch==0 and f.app.C.nav.stopped())
    end
    for _,epoch in ipairs({"1e2"," 1","-1",2147483648,false}) do
      local f=fixture({mining=false}) f.epoch(epoch) f.boot()
      assert(not f.app.C.nav.confirmed() and f.app.C.fleetSnapshot().pose==false)
      assert(f.m.pos.z==0 and #f.m.dug==0)
    end
  end)
  test("global and navigation disables stop the next extraction action without losing the job",function()
    for _,flag in ipairs({"enabled","navigation"}) do
      local f=fixture()
      f.m.world["1,65,1"]="minecraft:diamond_ore"
      local dig=f.e.turtle.dig
      f.e.turtle.dig=function()
        return f.native(function() local ok,why=dig() f.change({[flag]=false}) return ok,why end)
      end
      f.boot() f.untilTrue(function() return #f.m.dug==1 end) f.step(25)
      assert(f.m.pos.z==0 and #f.m.dug==1 and f.app.C.mining.state().task)
      f.e.turtle.dig=dig f.change({[flag]=true})
      f.untilTrue(function() return f.app.C.mining.state().phase=="done" end)
    end
  end)
  test("missing and disabled shared locations never use local service configuration",function()
    local f=fixture({mining=false,warehouse=true,autoDropoff=true})
    local name=f.site("shared","dropoff")
    f.locations[1].enabled=false
    f.app.cfg.warehouse={enabled=true,drop=name,charger="local-charge",targetFuel=1}
    for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
    f.boot() f.step(25)
    assert(f.dropped==0 and not next(f.locks) and f.m.pos.z==0)
    f.locations[1].enabled=true f.change({dropoffId="missing"}) f.step(25)
    assert(f.dropped==0 and not next(f.locks))
    f.change({dropoffId=false})
    f.untilTrue(function() return f.dropped==14 and not f.locks[name] end)
  end)
  test("automatic service selection skips an unreachable closer location",function()
    local f=fixture({mining=false}) f.boot()
    f.site("near","dropoff",2)
    local name=f.site("far","dropoff",4)
    for _,p in ipairs({{1,-1},{2,-1},{3,-1},{4,-1},{4,0}}) do
      f.app.C.nav.record({dim=f.home.dim,x=p[1],y=65,z=p[2]},"minecraft:air")
    end
    for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
    f.change({warehouse=true,autoDropoff=true})
    f.untilTrue(function() return f.dropped==14 and not f.locks[name] end)
    for _,r in ipairs(f.requested) do if r.op=="wh-lock" then assert(r.fields.name==name) end end
  end)
  test("a shared location and legacy site disagreement blocks before movement or transfer",function()
    local f=fixture({mining=false,warehouse=true,autoDropoff=true})
    local name=f.site("drop","dropoff")
    f.sites[name].pose.x=2
    for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
    f.boot() f.step(25)
    assert(f.dropped==0 and f.m.pos.x==1 and not f.locks[name])
    assert(f.app.C.fleetSnapshot().state=="blocked")
    f.sites[name].pose.x=1
    f.untilTrue(function() return f.dropped==14 and not f.locks[name] end)
  end)
  test("a full chest retains cargo and retries without claiming a successful drop",function()
    local f=fixture({mining=false,warehouse=true,autoDropoff=true})
    local name=f.site("drop","dropoff")
    for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
    f.fullChest=true f.boot() f.step(25)
    local pending=f.e.dofile("atomic.lua").read("mining-warehouse.state").value
    assert(pending.phase=="unload" and next(pending.cargo) and pending.pending==nil)
    assert(f.dropped==0 and f.locks[name]==1 and f.app.C.fleetSnapshot().state=="blocked")
    f.fullChest=false
    f.untilTrue(function() return f.dropped==14 and not f.locks[name] end)
  end)
  test("all-kept inventory blocks without a pointless service trip",function()
    local f=fixture({mining=false,warehouse=true,autoDropoff=true,keep={["minecraft:diamond"]=true}})
    f.site("drop","dropoff")
    for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
    f.boot() f.step(25)
    assert(f.dropped==0 and not next(f.locks) and f.app.C.fleetSnapshot().state=="blocked")
  end)
  test("live service toggles stop before the next drop and preserve the remaining cargo",function()
    for _,flag in ipairs({"enabled","navigation","warehouse","autoDropoff"}) do
      local f=fixture({mining=false,warehouse=true,autoDropoff=true})
      local name=f.site("drop","dropoff")
      for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
      f.afterDrop=function() f.afterDrop=nil f.change({[flag]=false}) end
      f.boot() f.untilTrue(function() return f.dropped==1 end) f.step(25)
      assert(f.dropped==1 and f.app.C.fleetSnapshot().inventory.usedSlots==13)
      f.change({[flag]=true})
      f.untilTrue(function() return f.dropped==14 and not f.locks[name] end)
    end
  end)
  test("a raised drop threshold cancels an active unload before its next item",function()
    local f=fixture({mining=false,warehouse=true,autoDropoff=true})
    local name=f.site("drop","dropoff")
    for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
    f.afterDrop=function() f.afterDrop=nil f.change({minFreeSlots=0,fullnessHigh=1}) end
    f.boot() f.untilTrue(function() return f.dropped==1 and not f.locks[name] end) f.step(25)
    assert(f.dropped==1)
    f.change({fullnessHigh=.5})
    f.untilTrue(function() return f.dropped==14 and not f.locks[name] end)
  end)
  test("a changed shared selector retargets the service before its next transfer",function()
    local f=fixture({mining=false,warehouse=true,autoDropoff=true,dropoffId="a"})
    local first=f.site("a","dropoff") local second=f.site("b","dropoff")
    for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
    local changed=false
    f.afterDrop=function() f.afterDrop=nil changed=true f.change({dropoffId="b"}) end
    f.boot() f.untilTrue(function() return changed and f.dropped==14 and not f.locks[second] end)
    assert(not f.locks[first])
    local seenSecond=false
    for _,r in ipairs(f.requested) do
      if r.op=="wh-lock" then
        if r.fields.name==second then seenSecond=true end
        if seenSecond then assert(r.fields.name~=first) end
      end
    end
    assert(seenSecond)
  end)
  test("offline service workers stop with their cargo even if offline autonomy is requested",function()
    local f=fixture({mining=false,warehouse=true,autoDropoff=true,offlineAutonomy=true})
    local name=f.site("drop","dropoff")
    for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
    f.afterDrop=function() f.afterDrop=nil f.online(false) end
    f.boot() f.untilTrue(function() return f.dropped==1 end) f.step(25)
    assert(f.dropped==1 and f.locks[name]==1 and f.app.C.fleetSnapshot().inventory.usedSlots==13)
    f.online(true) f.advance(3001)
    f.untilTrue(function() return f.dropped==14 and not f.locks[name] end)
  end)
  test("a charger without enough round-trip fuel cannot start a physical service action",function()
    local f=fixture({mining=false}) f.boot()
    f.site("charge","charge",2)
    f.app.C.nav.record({dim=f.home.dim,x=2,y=65,z=0},"minecraft:air")
    f.m.fuel=0 f.change({warehouse=true,autoCharge=true,minTripFuel=600}) f.step(25)
    assert(f.m.pos.x==1 and f.m.pos.z==0 and not next(f.locks) and f.dropped==0)
    assert(f.app.C.fleetSnapshot().state=="blocked")
  end)
  test("global role and computer settings all stop extraction before its next native action",function()
    for _,scope in ipairs({"global","role","computer"}) do
      local f=fixture()
      f.m.world["1,65,1"]="minecraft:diamond_ore"
      local dig=f.e.turtle.dig
      f.e.turtle.dig=function()
        return f.native(function()
          local ok,why=dig() f.scopeChange(scope,{mining=false}) return ok,why
        end)
      end
      f.boot()
      f.untilTrue(function() return #f.m.dug==1 and f.app.C.mining.state().phase=="home" end)
      assert(f.m.pos.z==0 and f.app.C.mining.state().task and f.app.C.fleetSnapshot().currentJob)
      f.e.turtle.dig=dig f.scopeChange(scope,{mining=true})
      f.untilTrue(function() return f.app.C.mining.state().phase=="done" end)
    end
  end)
  test("numeric command epochs work while decimal legacy commands convert once",function()
    local f=fixture({mining=false}) f.epoch(0) f.boot()
    local listener=coroutine.create(f.app.listener) assert(coroutine.resume(listener))
    local function command(kind,epoch,cid)
      local ok,why=coroutine.resume(listener,"miner_network",0,{type=kind,commandEpoch=epoch,cid=cid},"minearmy")
      assert(ok,why)
    end
    command("estop",0,1) assert(f.app.C.nav.stopped())
    command("go",0,2) assert(not f.app.C.nav.stopped())
    command("estop","0",3) assert(f.app.C.nav.stopped() and f.app.C.nav.controlState().epoch==0)
    command("go","1e2",4) assert(f.app.C.nav.stopped() and f.app.C.nav.controlState().epoch==0)
  end)
  test("a disabled shared location stops the next transfer without a local fallback",function()
    local f=fixture({mining=false,warehouse=true,autoDropoff=true})
    local name=f.site("drop","dropoff")
    for slot=1,14 do f.m.inventory[slot]={name="minecraft:diamond",count=1} end
    f.afterDrop=function() f.afterDrop=nil f.locations[1].enabled=false end
    f.boot()
    f.untilTrue(function() return f.dropped==1 and f.app.C.fleetSnapshot().state=="blocked" end)
    f.step(20)
    assert(f.dropped==1 and f.locks[name]==1 and f.app.C.fleetSnapshot().inventory.usedSlots==13)
    f.locations[1].enabled=true
    f.untilTrue(function() return f.dropped==14 and not f.locks[name] end)
  end)
  test("disabling auto-charge during a move returns home and releases the bay",function()
    local f=fixture({mining=false}) f.boot()
    local name=f.site("charge","charge",2)
    f.app.C.nav.record({dim=f.home.dim,x=2,y=65,z=0},"minecraft:air")
    local changed=false
    f.m.afterMove=function()
      if not changed then changed=true f.change({autoCharge=false}) end
    end
    f.m.fuel=100 f.change({warehouse=true,autoCharge=true,minTripFuel=600})
    f.untilTrue(function() return changed and f.m.pos.x==1 and not f.locks[name] end)
    f.step(20)
    assert(f.m.fuel==98 and f.m.pos.x==1 and not f.locks[name] and f.dropped==0)
  end)
  test("unlimited fuel during charging releases the bay and reports both unlimited values",function()
    local f=fixture({mining=false,warehouse=true,autoCharge=true,minTripFuel=600})
    local name=f.site("charge","charge")
    f.m.fuel=100 f.boot() f.untilTrue(function() return f.locks[name]==1 end)
    f.e.turtle.getFuelLevel=function() return "unlimited" end
    f.e.turtle.getFuelLimit=function() return "unlimited" end
    f.untilTrue(function() return not f.locks[name] end)
    local s=f.app.C.fleetSnapshot()
    assert(s.fuel.level=="unlimited" and s.fuel.limit=="unlimited")
    assert(not f.app.C.fleetRecovery)
  end)
  test("return-home can pause away from home without losing the unfinished vein",function()
    local f=fixture()
    for x=1,3 do f.m.world[x..",65,1"]="minecraft:diamond_ore" end
    local dig=f.e.turtle.dig
    f.e.turtle.dig=function()
      return f.native(function()
        local ok,why=dig()
        if #f.m.dug==2 then f.change({mining=false,returnHome=false}) end
        return ok,why
      end)
    end
    f.boot()
    f.untilTrue(function() return #f.m.dug==2 and f.app.C.mining.state().phase=="return" end)
    f.step(20)
    assert(f.m.pos.z==1 and f.app.C.mining.state().task and f.m.world["3,65,1"])
    f.change({returnHome=true})
    f.untilTrue(function() return f.app.C.mining.state().phase=="home" end)
    assert(f.m.pos.z==0 and #f.m.dug==2)
    f.e.turtle.dig=dig f.change({mining=true})
    f.untilTrue(function() return f.app.C.mining.state().phase=="done" end)
    assert(not f.m.world["3,65,1"])
  end)
  test("new service routes must be checked before extraction can make another move",function()
    local f=fixture()
    f.site("unreachable","dropoff",4)
    f.m.world["1,65,1"]="minecraft:diamond_ore"
    local dig=f.e.turtle.dig
    local moves=0
    f.m.afterMove=function() moves=moves+1 end
    f.e.turtle.dig=function()
      return f.native(function()
        local ok,why=dig() f.change({warehouse=true,autoDropoff=true}) return ok,why
      end)
    end
    f.boot()
    f.untilTrue(function() return #f.m.dug==1 and f.app.C.mining.state().phase=="home" end)
    f.step(20)
    assert(moves==0 and f.app.C.mining.state().task and f.app.C.fleetSnapshot().state=="blocked")
  end)
end

if ...=="standalone" then
  local failed,passed=0,0
  local function read(path)
    local h=assert(io.open(path,"rb")) local value=h:read("*a") h:close() return value
  end
  suite(function(name,fn)
    if arg[2] and not name:find(arg[2],1,true) then return end
    if debug and debug.sethook then debug.sethook(function() error(debug.traceback("test did not yield")) end,"",10000000) end
    local ok,why=pcall(fn)
    if debug and debug.sethook then debug.sethook() end
    print((ok and "PASS " or "FAIL ")..name..(ok and "" or ": "..tostring(why)))
    if ok then passed=passed+1 else failed=failed+1 end
  end,read,dofile("tests/mocks.lua"))
  print(passed.." fleet miner tests passed, "..failed.." failed")
  assert(failed==0,"fleet miner behavior failures")
else return suite end
