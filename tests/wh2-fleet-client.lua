local passed, failed=0,0
local function test(name, run)
  local ok,err=xpcall(run,debug.traceback)
  if ok then passed=passed+1 print("PASS "..name)
  else failed=failed+1 print("FAIL "..name.."\n"..err) end
end
local function clone(v)
  if type(v)~="table" then return v end
  local out={} for k,x in pairs(v) do out[k]=clone(x) end return out
end
local function encode(v)
  if type(v)=="string" then return string.format("%q",v) end
  if type(v)~="table" then return tostring(v) end
  local out={}
  for k,x in pairs(v) do out[#out+1]="["..encode(k).."]="..encode(x) end
  return "{"..table.concat(out,",").."}"
end
local dim="minecraft:overworld"
local function pose(x,y,z,dimension)
  return {v=1,frame="abs",yAbs=true,dim=dimension or dim,x=x,y=y or 64,z=z or 0,
    h=0,conf="certain",src="typed",anchoredAt=90000}
end
local function location(id,x,kind,dimension)
  return {v=1,id=id,kind=kind or "dropoff",enabled=true,access={pose=pose(x,64,0,dimension),side="front"}}
end
local function fixture(config)
  config=config or {}
  local m={time=100000,events={},threads={},timers={},calls={},reports={},saved={},order={},applies={},
    revision=1,effective={enabled=true,mining=true,autoCharge=false,dropoffId=false},locations={},classes={},fleet={}}
  local timer=0
  local env=setmetatable({},{__index=_G})
  env.turtle=config.turtle and {} or false
  env.os={getComputerID=function() return 17 end,getComputerLabel=function() return "Test" end,
    epoch=function() return m.time end,
    queueEvent=function(...) m.events[#m.events+1]=table.pack(...) end,
    pullEvent=function(filter) return coroutine.yield(filter) end,
    startTimer=function(delay) timer=timer+1 m.timers[timer]=m.time+delay*1000 return timer end,
    cancelTimer=function(id) m.timers[id]=nil end}
  env.textutils={serialize=encode}
  env.rednet=setmetatable({},{__index=function() error("client must use the supplied RPC") end})
  env.dofile=function(path)
    assert(path=="atomic.lua","unexpected dependency "..path)
    return {store=function(file,valid,limit)
      assert(file==(config.cacheFile or "wh2-settings.cache") and limit<=32768)
      if config.corrupt then error("no valid generation") end
      if config.cache then assert(valid(config.cache)) end
      return {value=clone(config.cache),save=function(value)
        assert(valid(value))
        if m.saveFailure then return false,"disk full" end
        if m.saveThrows then error("disk full") end
        m.saved[#m.saved+1]=clone(value)
        m.order[#m.order+1]="save:"..value.revision
        return true
      end}
    end}
  end
  local rpc={boot="90000:17"}
  function rpc.call(op, fields)
    assert(type(fields.body)=="table" and fields.body.wh2==1)
    m.calls[#m.calls+1]={op=op,body=clone(fields.body)}
    if op=="wh2-report" then m.reports[#m.reports+1]=clone(fields.body.record) end
    if m.respond then return m.respond(op,fields.body) end
    if m.offline then return nil,"SSOT timeout (stopped)" end
    if op=="wh2-get" then
      local topic=fields.body.topic
      if topic=="settings" then
        return {body={wh2=1,ok=true,revision=m.revision,cursor=0,
          records={{v=1,id=tostring(fields.body.computerId),revision=m.revision,effective=clone(m.effective)}}}}
      end
      return {body={wh2=1,ok=true,revision=topic=="classes" and "1:2" or 1,
        records=clone(topic=="classes" and m.classes or topic=="fleet" and m.fleet or m.locations),cursor=0}}
    end
    return {body={wh2=1,ok=true,settingsRevision=m.revision}}
  end
  function rpc.dispatch(sender,message,protocol,verified)
    m.dispatched={sender,message,protocol}
    if m.dispatch then return m.dispatch(sender,message,protocol,verified) end
    return false
  end
  local opts={rpc=rpc,enabled=config.enabled~=false,role="miner",dimension=dim,
    cacheFile=config.cacheFile,snapshot=function() return m.snapshot or {} end,
    apply=function(effective,revision)
      m.order[#m.order+1]="apply:"..revision
      assert(m.saved[#m.saved].revision==revision,"apply preceded cache save")
      m.applies[#m.applies+1]={effective=clone(effective),revision=revision}
      if m.apply then m.apply(effective,revision) end
    end}
  if config.noRpc then opts.rpc=nil end
  if config.unsetEnabled then opts.enabled=nil end
  m.rpc=rpc
  m.api=assert(loadfile("wh2-client.lua","t",env))().new(opts)
  local function resume(thread,...)
    local ok,filter=coroutine.resume(thread.co,...)
    assert(ok,filter)
    thread.filter=filter
  end
  function m.spawn(fn)
    local thread={co=coroutine.create(fn)}
    m.threads[#m.threads+1]=thread
    resume(thread)
    return thread
  end
  function m.pump()
    local count=0
    while #m.events>0 do
      count=count+1 assert(count<1000,"event loop did not settle")
      local event=table.remove(m.events,1)
      for _,thread in ipairs(m.threads) do
        if coroutine.status(thread.co)~="dead" and (thread.filter==nil or thread.filter==event[1]) then
          resume(thread,table.unpack(event,1,event.n))
        end
      end
    end
  end
  function m.push(...) m.events[#m.events+1]=table.pack(...) m.pump() end
  function m.advance(ms)
    m.time=m.time+ms
    local due={}
    for id,at in pairs(m.timers) do if at<=m.time then due[#due+1]=id end end
    table.sort(due)
    for _,id in ipairs(due) do
      if m.timers[id] then m.timers[id]=nil m.events[#m.events+1]=table.pack("timer",id) end
    end
    m.pump()
  end
  return m
end

test("fresh settings save before apply and preserve false values",function()
  local m=fixture()
  assert(not m.api.ready() and #m.calls==0)
  local ok,revision=m.api.refresh()
  assert(ok and revision==1 and m.api.ready())
  assert(m.api.status().state=="ready" and m.api.status().detail==nil)
  assert(table.concat(m.order,",")=="save:1,apply:1")
  assert(m.saved[1].v==1)
  local settings,rev=m.api.settings()
  assert(rev==1 and settings.autoCharge==false and settings.dropoffId==false)
  assert(m.calls[1].body.id=="17" and m.calls[1].body.computerId==17)
  settings.mining=false
  assert(m.api.settings().mining==true)
end)

test("persisted cache cannot authorize startup or offline work",function()
  local m=fixture({cache={id="17",revision=4,effective={enabled=true,mining=true}}})
  assert(m.api.settings().mining and not m.api.ready() and #m.applies==0)
  m.offline=true
  local ok,err=m.api.refresh()
  assert(not ok and err:find("server unavailable",1,true) and not m.api.ready())
  assert(#m.saved==0 and #m.applies==0)
end)

test("unknown offline startup reports server unavailable",function()
  local m=fixture()
  m.offline=true
  assert(not m.api.tick() and not m.api.ready())
  assert(m.api.status().state=="server unavailable")
  assert(m.api.status().detail:find("server unavailable",1,true))
end)

test("failed fetch pauses until settings refresh succeeds",function()
  local m=fixture()
  assert(m.api.refresh())
  m.offline=true
  assert(not m.api.refresh() and not m.api.ready())
  m.offline=false m.revision=2
  assert(m.api.refresh() and m.api.ready())
  local _,revision=m.api.settings() assert(revision==2)
end)

test("cache save failure never applies settings",function()
  local m=fixture()
  m.saveFailure=true
  local ok,err=m.api.refresh()
  assert(not ok and err:find("cache",1,true) and not m.api.ready())
  assert(#m.applies==0 and #m.saved==0)
end)

test("corrupt cache leaves client available for status and reads",function()
  local m=fixture({corrupt=true})
  assert(not m.api.refresh() and not m.api.ready() and #m.applies==0)
  m.locations={location("drop",1)}
  assert(m.api.location("dropoff",pose(0)).id=="drop")
end)

test("apply failure pauses even after the cache saves",function()
  local m=fixture()
  m.apply=function() error("role could not apply") end
  assert(not m.api.refresh() and not m.api.ready() and #m.saved==1)
end)

test("raw hints cannot invalidate or apply settings",function()
  local m=fixture()
  assert(m.api.refresh())
  local raw={op="wh2-changed",body={wh2=1,topic="settings",revision=99}}
  m.dispatch=function() return true end
  assert(m.api.dispatch(0,raw,"fleetserver"))
  assert(m.dispatched[2]==raw and m.api.ready() and #m.applies==1 and #m.calls==1)
  assert(m.api.status().queued==0)
end)

test("returned hints cannot invalidate settings",function()
  local m=fixture()
  assert(m.api.tick())
  m.dispatch=function() return true,{op="wh2-changed",body={wh2=1,topic="settings",revision=2}} end
  assert(m.api.dispatch(0,{},"fleetserver"))
  assert(m.api.ready() and m.api.status().queued==0 and #m.calls==2)
end)

test("verified callback hints pause and queue one refresh",function()
  local m=fixture()
  assert(m.api.tick())
  m.dispatch=function(_,_,_,verified)
    verified({op="wh2-changed",body={wh2=1,topic="settings",revision=2}}) return true
  end
  for _=1,5 do assert(m.api.dispatch(0,{},"fleetserver")) end
  assert(not m.api.ready() and m.api.status().queued==1 and #m.calls==2)
  assert(#m.applies==1)
  m.revision=2
  assert(m.api.tick() and m.api.ready() and #m.calls==3)
end)

test("verified callback hint does not call RPC from dispatch",function()
  local m=fixture()
  assert(m.api.refresh())
  m.dispatch=function(_,_,_,verified)
    verified({wh2=1,topic="settings",revision=2}) return true
  end
  assert(m.api.dispatch(0,{},"fleetserver"))
  assert(not m.api.ready() and #m.calls==1 and #m.applies==1)
  m.revision=2 assert(m.api.tick())
end)

test("older verified hints do not pause a fresh client",function()
  local m=fixture()
  m.revision=4 assert(m.api.tick())
  m.dispatch=function(_,_,_,verified) verified({wh2=1,topic="settings",revision=3}) return true end
  m.api.dispatch(0,{},"fleetserver")
  assert(m.api.ready() and m.api.status().queued==0)
end)

test("settings older than a verified hint cannot resume work",function()
  local m=fixture()
  assert(m.api.refresh())
  m.dispatch=function(_,_,_,verified) verified({wh2=1,topic="settings",revision=3}) return true end
  m.api.dispatch(0,{},"fleetserver")
  m.revision=2
  assert(not m.api.refresh() and not m.api.ready() and #m.applies==1)
  m.revision=3 assert(m.api.refresh() and m.api.ready())
end)

test("a report revision pauses before the next action",function()
  local m=fixture()
  assert(m.api.tick())
  m.revision=2
  assert(m.api.record({state="mining",currentJob={kind="mine",id="zone:3",step="extract"}}))
  assert(m.api.tick())
  assert(m.api.ready())
  local _,rev=m.api.settings() assert(rev==2)
  assert(m.calls[3].op=="wh2-report" and m.calls[4].body.topic=="settings")
end)

test("queued calls block until worker and retain FIFO order",function()
  local m=fixture({enabled=false})
  local results={}
  m.spawn(function() results[1]=m.api.call("first",{value=1}) end)
  m.spawn(function() results[2]=m.api.call("second",{value=2,computerId=23}) end)
  m.spawn(function() results[3]=m.api.call("third",{value=3}) end)
  assert(#m.calls==0 and m.api.status().queued==3)
  m.spawn(m.api.worker) m.pump()
  assert(#results==3 and #m.calls==3)
  assert(m.calls[1].op=="first" and m.calls[2].op=="second" and m.calls[3].op=="third")
  assert(m.calls[1].body.computerId==nil and m.calls[2].body.computerId==23)
end)

test("busy RPC preserves queued requests and order",function()
  local m=fixture({enabled=false})
  local busy,done=true,{}
  m.respond=function(op)
    if busy then return nil,"SSOT busy" end
    return {ok=true,value=op}
  end
  m.spawn(function() done[1]=m.api.call("first",{}) end)
  m.spawn(function() done[2]=m.api.call("second",{}) end)
  m.spawn(m.api.worker) m.pump()
  assert(#done==0 and m.api.status().queued==2)
  busy=false m.advance(50)
  assert(done[1].value=="first" and done[2].value=="second" and m.api.status().queued==0)
  assert(m.calls[#m.calls-1].op=="first" and m.calls[#m.calls].op=="second")
end)

test("queued calls retain rejection codes for management callers",function()
  local m=fixture({enabled=false})
  local result,reason
  m.respond=function(op,body)
    assert(op=="wh2-settings" and body.scope=="global" and body.computerId==nil)
    return {body={ok=false,code="stale_revision",error="Settings changed since this edit"}}
  end
  m.spawn(function() result,reason=m.api.call("wh2-settings",{scope="global",baseRevision=0,set={mining=false}}) end)
  m.spawn(m.api.worker) m.pump()
  assert(result.ok==false and result.code=="stale_revision" and reason)
end)

test("three second ticks fetch settings and report the applied revision",function()
  local m=fixture()
  m.spawn(m.api.worker) m.pump()
  assert(#m.calls==2 and m.calls[2].op=="wh2-report")
  assert(m.calls[2].body.appliedSettingsRevision==1)
  m.advance(2999) assert(#m.calls==2)
  m.revision=2 m.advance(1)
  assert(#m.calls==4 and m.calls[4].body.record.appliedSettingsRevision==2)
  assert(m.api.ready())
end)

test("disabled behavior preserves standalone mode and allows reads",function()
  local m=fixture({enabled=false})
  m.spawn(m.api.worker) m.pump()
  assert(#m.calls==0 and m.api.status().state=="standalone" and not m.api.ready())
  local done=false
  m.spawn(function() assert(m.api.refresh()) done=true end)
  m.pump()
  assert(done and #m.calls==1 and #m.applies==0 and not m.api.ready())
  assert(m.api.settings().enabled==true)
end)

test("reports coalesce to the newest bounded snapshot",function()
  local m=fixture({enabled=false})
  assert(m.api.record({state="idle",detail="old"}))
  assert(m.api.record({state="blocked",detail="new",secret="private",computerId=99}))
  assert(m.api.status().queued==1 and m.api.tick())
  local sent=m.calls[1].body.record
  assert(m.calls[1].body.computerId==nil)
  assert(sent.state=="blocked" and sent.detail=="new" and sent.secret==nil)
  assert(sent.id=="cc:17" and sent.computerId==17 and sent.role=="miner")
  assert(not m.api.record({detail=string.rep("x",5000)}))
end)

test("a report queued during an active report is retained",function()
  local m=fixture({enabled=false})
  m.respond=function(op)
    assert(op=="wh2-report")
    if #m.calls==1 then assert(m.api.record({detail="later"})) end
    return {ok=true}
  end
  assert(m.api.record({detail="first"}) and m.api.tick())
  assert(#m.calls==2 and m.calls[1].body.record.detail=="first" and m.calls[2].body.record.detail=="later")
end)

test("busy synchronous refresh stays queued for the next tick",function()
  local m=fixture()
  m.respond=function() return nil,"SSOT busy" end
  assert(not m.api.refresh() and not m.api.ready() and m.api.status().queued==1)
  m.respond=nil
  assert(m.api.tick() and m.api.ready() and m.api.status().queued==0)
end)

test("location selects by Manhattan distance then stable ID",function()
  local m=fixture({enabled=false})
  local disabled=location("disabled",0) disabled.enabled=false
  m.locations={location("z",1),location("a",-1),location("far",5),disabled,
    location("nether",0,"dropoff","minecraft:the_nether"),location("charger",0,"charge")}
  assert(m.api.location("dropoff",pose(0)).id=="a")
  assert(m.api.location("dropoff",pose(0),"z").id=="z")
  assert(m.calls[2].body.id=="z")
  assert(m.calls[2].body.computerId==nil)
end)

test("false location selector chooses a server-known location",function()
  local m=fixture()
  m.locations={location("drop",0)}
  local result=m.api.location("dropoff",pose(0),false)
  assert(result and result.id=="drop" and #m.calls==1)
  local other,reason=m.api.location("charge",pose(0))
  assert(not other and reason:find("blocked",1,true))
end)

test("location skips unreachable sites and uses known route cost",function()
  local m=fixture({enabled=false})
  m.locations={location("blocked",0),location("detour",1),location("clear",4)}
  m.api.routeCost=function(target)
    if target.x==0 then return false,"unknown route" end
    return target.x==1 and 8 or 4
  end
  assert(m.api.location("dropoff",pose(0),false).id=="clear")
  local selected,why=m.api.location("dropoff",pose(0),"blocked")
  assert(not selected and why:find("blocked",1,true))
end)

test("location pagination pins its revision",function()
  local m=fixture({enabled=false})
  m.respond=function(op,body)
    assert(op=="wh2-get" and body.topic=="locations")
    if body.cursor==0 then return {ok=true,records={location("far",8)},cursor=1,revision=7} end
    assert(body.cursor==1 and body.revision==7)
    return {ok=true,records={location("near",1)},cursor=0,revision=7}
  end
  assert(m.api.location("dropoff",pose(0)).id=="near")
end)

test("a stale page restarts the read without mixing revisions",function()
  local m=fixture({enabled=false})
  m.respond=function(_,body)
    if #m.calls==1 then return {ok=true,records={location("old",0)},cursor=1,revision=1} end
    if #m.calls==2 then
      assert(body.revision==1)
      return {ok=false,code="stale_revision",error="Shared locations changed"}
    end
    assert(body.cursor==0 and body.revision==nil)
    return {ok=true,records={location("new",2)},cursor=0,revision=2}
  end
  assert(m.api.location("dropoff",pose(0)).id=="new")
end)

test("empty advancing pages fail instead of polling forever",function()
  local m=fixture({enabled=false})
  m.respond=function()
    if #m.calls>1 then return nil,"unexpected extra page" end
    return {ok=true,records={},cursor=1,revision=1}
  end
  local row,_,err=m.api.lookupClass("example:tin")
  assert(row.route=="unknown" and err:find("cursor",1,true) and #m.calls==1)
end)

test("malformed reply bodies pause without breaking the client",function()
  local m=fixture()
  assert(m.api.refresh())
  m.respond=function() return {body=true} end
  local ran,result=pcall(m.api.refresh)
  assert(ran and not result and not m.api.ready())
  m.respond=nil
  assert(m.api.refresh() and m.api.ready())
end)

test("a settings record for another target never applies",function()
  local m=fixture()
  m.respond=function()
    return {ok=true,revision=1,cursor=0,records={{id="18",revision=1,effective={mining=true}}}}
  end
  assert(not m.api.refresh() and not m.api.ready() and #m.saved==0 and #m.applies==0)
end)

test("class lookup returns exact rows and unknown for missing items",function()
  local m=fixture({enabled=false})
  m.classes={{item="minecraft:raw_iron",route="blast",recipeId=false}}
  local row,rev=m.api.lookupClass("minecraft:raw_iron")
  assert(row.route=="blast" and row.recipeId==false and rev=="1:2")
  local missing,revision=m.api.lookupClass("example:raw_tin")
  assert(missing.item=="example:raw_tin" and missing.route=="unknown" and revision=="1:2")
  assert(m.calls[2].body.topic=="classes" and m.calls[2].body.id=="example:raw_tin")
end)

test("malformed class records cannot authorize a route",function()
  local m=fixture()
  assert(m.api.refresh())
  m.classes={false}
  local ran,row,_,err=pcall(m.api.lookupClass,"example:tin")
  assert(ran and row.route=="unknown" and err and not m.api.ready())
end)

test("class reads always observe the current definition",function()
  local m=fixture({enabled=false})
  m.classes={{item="example:tin",route="store"}}
  assert(m.api.lookupClass("example:tin").route=="store")
  m.classes={{item="example:tin",route="blast"}}
  assert(m.api.lookupClass("example:tin").route=="blast")
end)

test("unknown reporting uses the shared queue and exposes unavailable",function()
  local m=fixture({enabled=false})
  m.respond=function(op,body)
    assert(op=="wh2-unknown" and body.item=="example:tin" and body.sampleLocationId=="input")
    return {body={ok=false,code="unavailable",error="wizard unavailable"}}
  end
  local result,err=m.api.reportUnknown("example:tin","input")
  assert(result.ok==false and result.code=="unavailable" and err:find("unavailable",1,true))
end)

test("failed location fetch also pauses autonomous work",function()
  local m=fixture()
  assert(m.api.refresh())
  m.offline=true
  assert(not m.api.location("dropoff",pose(0)) and not m.api.ready())
  local row,_,err=m.api.lookupClass("example:tin")
  assert(row.route=="unknown" and err:find("unavailable",1,true))
end)

test("missing RPC retains standalone mode with behavior off by default",function()
  local m=fixture({noRpc=true,unsetEnabled=true})
  assert(m.api.status().state=="standalone" and not m.api.ready() and m.api.tick())
  local ok,err=m.api.refresh()
  assert(not ok and err:find("server unavailable",1,true) and #m.applies==0)
end)

test("legacy settings views save as version one without enabling offline work",function()
  local m=fixture({cache={id="17",revision=1,effective={mining=true}}})
  assert(not m.api.ready() and #m.applies==0)
  m.respond=function()
    return {ok=true,revision=2,cursor=0,records={{id="17",revision=2,effective={mining=false}}}}
  end
  assert(m.api.refresh() and m.saved[1].v==1 and m.api.settings().mining==false)
end)

test("unknown settings versions never save or apply",function()
  local m=fixture()
  m.respond=function()
    return {ok=true,revision=2,cursor=0,records={{v=2,id="17",revision=2,effective={mining=true}}}}
  end
  assert(not m.api.refresh() and not m.api.ready() and #m.saved==0 and #m.applies==0)
  local cached=fixture({cache={v=2,id="17",revision=1,effective={mining=true}}})
  assert(not cached.api.ready() and next((cached.api.settings()))==nil)
  assert(not cached.api.refresh() and #cached.applies==0)
end)

test("verified hints reject other operations topics and malformed revisions",function()
  local m=fixture()
  assert(m.api.tick())
  m.dispatch=function(_,_,_,verified)
    verified({op="other",body={wh2=1,topic="settings",revision=2}})
    verified({wh2=1,topic="classes",revision=2})
    verified({wh2=2,topic="settings",revision=2})
    verified({wh2=1,topic="settings",revision="2"})
    verified({wh2=1,topic="settings",revision=math.huge})
    verified({wh2=1,topic="settings",revision=1.5})
    verified({body=true})
    return true
  end
  assert(m.api.dispatch(0,{},"fleetserver") and m.api.ready() and m.api.status().queued==0)
end)

test("computer reports keep unknown positions and non-applicable measurements false",function()
  local m=fixture({enabled=false})
  assert(m.api.record({pose=false,heading=0,poseConfirmed=true,lastSeen=999999,appliedSettingsRevision=99,
    id="cc:99",computerId=99,turtleId=99,kind="turtle",role="server"}))
  assert(m.api.tick())
  local sent=m.reports[1]
  assert(sent.v==1 and sent.id=="cc:17" and sent.computerId==17 and sent.kind=="computer")
  assert(sent.turtleId==false and sent.fuel==false and sent.inventory==false and sent.pose==false)
  assert(sent.currentJob==false and sent.error==false and sent.role=="miner")
  assert(sent.heading==nil and sent.poseConfirmed==nil and sent.lastSeen==0 and sent.appliedSettingsRevision==0)
end)

test("turtle reports use tables for unknown measurements",function()
  local m=fixture({enabled=false,turtle=true})
  assert(m.api.record({}) and m.api.tick())
  local sent=m.reports[1]
  assert(sent.v==1 and sent.kind=="turtle" and sent.turtleId==17 and sent.pose==false)
  assert(sent.fuel.level==false and sent.fuel.limit==false)
  assert(sent.inventory.slots==16 and sent.inventory.usedSlots==false and sent.inventory.fullness==false)
  assert(m.api.record({fuel=false,inventory=false}) and m.api.tick())
  assert(type(m.reports[2].fuel)=="table" and type(m.reports[2].inventory)=="table")
end)

test("reports preserve measured zero unlimited fuel and partial unknown measurements",function()
  local m=fixture({enabled=false,turtle=true})
  local snapshots={
    {fuel={level=0,limit=20000},inventory={slots=16,usedSlots=0,fullness=0}},
    {fuel={level=false,limit=20000},inventory={slots=16,usedSlots=false,fullness=false}},
    {fuel={level=50,limit=false},inventory={slots=false,usedSlots=3,fullness=false}},
    {fuel={level="unlimited",limit="unlimited"},inventory={slots=16,usedSlots=14,fullness=0.875}},
  }
  for i,snapshot in ipairs(snapshots) do
    assert(m.api.record(snapshot) and m.api.tick())
    local sent=m.reports[i]
    assert(sent.fuel.level==snapshot.fuel.level and sent.fuel.limit==snapshot.fuel.limit)
    assert(sent.inventory.slots==snapshot.inventory.slots and sent.inventory.usedSlots==snapshot.inventory.usedSlots
      and sent.inventory.fullness==snapshot.inventory.fullness)
  end
end)

test("invalid measurement tables never enter the outbound queue",function()
  local m=fixture({enabled=false,turtle=true})
  local bad={
    {fuel={level=1}}, {fuel={level=20,limit=10}},
    {fuel={level="unlimited",limit=false}}, {fuel={level=math.huge,limit=math.huge}},
    {fuel={level=-1,limit=20}}, {fuel={level=1.5,limit=20}},
    {fuel={level=0,limit=20,secret=true}},
    {inventory={slots=16,usedSlots=0}}, {inventory={slots=16,usedSlots=17,fullness=1}},
    {inventory={slots=16,usedSlots=14,fullness=0}},
    {inventory={slots=16,usedSlots=false,fullness=0}},
    {inventory={slots=0,usedSlots=0,fullness=0}},
  }
  for _,snapshot in ipairs(bad) do assert(not m.api.record(snapshot)) end
  assert(m.api.status().queued==0 and #m.calls==0)
  local computer=fixture({enabled=false})
  assert(not computer.api.record({fuel={level=0,limit=0}}))
end)

test("active report states require their allocator job and idle forbids one",function()
  local m=fixture({enabled=false,turtle=true})
  for state,kind in pairs({mining="mine",sorting="warehouse",crafting="craft"}) do
    assert(not m.api.record({state=state}))
    assert(not m.api.record({state=state,currentJob={kind=kind=="mine" and "craft" or "mine",id="job:1",step="work"}}))
    assert(m.api.record({state=state,currentJob={kind=kind,id="job:1",step="work"}}) and m.api.tick())
    local sent=m.reports[#m.reports]
    assert(sent.state==state and sent.currentJob.kind==kind and sent.currentJob.step=="work")
  end
  local job={kind="mine",id="zone:3",step="extract"}
  assert(not m.api.record({state="idle",currentJob=job}))
  for _,state in ipairs({"returning","dropping","charging","blocked","stopped"}) do
    assert(m.api.record({state=state,currentJob=job}) and m.api.tick())
    assert(m.reports[#m.reports].currentJob.id=="zone:3")
  end
  assert(not m.api.record({state="blocked",currentJob={kind="mine",id="zone:3",step=false}}))
  assert(not m.api.record({state="blocked",currentJob={kind="mine",id="zone:3",step="work",token="private"}}))
end)

test("framed report poses retain heading confidence source and anchor",function()
  local m=fixture({enabled=false,turtle=true})
  local p=pose(10,65,20)
  p.h=0 p.src="neighbour"
  assert(m.api.record({pose=p,poseConfirmed=false,heading=3}) and m.api.tick())
  local sent=m.reports[1].pose
  assert(sent.v==1 and sent.frame=="abs" and sent.yAbs==true and sent.h==0)
  assert(sent.conf=="certain" and sent.src=="neighbour" and sent.anchoredAt==90000)
  local relative=pose(0)
  relative.frame="f:17:90000" relative.yAbs=true relative.conf="suspect" relative.anchoredAt=0
  assert(m.api.record({pose=relative}) and m.api.tick())
  assert(m.reports[2].pose.frame==relative.frame and m.reports[2].pose.conf=="suspect")
end)

test("legacy navigation observations stay relative and never acquire an anchor",function()
  local m=fixture({enabled=false,turtle=true})
  assert(m.api.record({pose={dim=dim,x=0,y=64,z=0},heading=0,poseConfirmed=true}) and m.api.tick())
  local first=m.reports[1].pose
  assert(first.v==1 and first.frame=="f:17:100000" and first.yAbs==false and first.h==0)
  assert(first.conf=="suspect" and first.src=="inherited" and first.anchoredAt==0)
  assert(m.api.record({pose={dim=dim,x=1,y=64,z=0,h=1},heading=0}) and m.api.tick())
  assert(m.reports[2].pose.frame==first.frame and m.reports[2].pose.h==1)
  assert(m.api.record({pose={dim=dim,x=1,y=64,z=0},heading=false}) and m.api.tick())
  assert(m.reports[3].pose==false)
  m.locations={location("drop",0)}
  local calls=#m.calls
  assert(not m.api.location("dropoff",first) and #m.calls==calls)
end)

test("malformed and future pose versions never become legacy observations",function()
  local m=fixture({enabled=false})
  for _,patch in ipairs({{v=2},{frame="world"},{yAbs=false},{h=4},{h=false},{conf="guess"},{src="legacy"},
    {anchoredAt=-1},{anchoredAt=1.5},{x=0.5},{x=math.huge},{dim="overworld"}}) do
    local p=pose(0)
    for key,value in pairs(patch) do p[key]=value end
    assert(not m.api.record({pose=p}))
  end
  assert(not m.api.record({pose={v=2,dim=dim,x=0,y=64,z=0},heading=0}))
  assert(not m.api.record({v=2}))
  assert(m.api.status().queued==0 and #m.calls==0)
end)

test("location origins require a complete certain anchored framed pose",function()
  local m=fixture({enabled=false})
  m.locations={location("drop",1)}
  local origins={false}
  for _,patch in ipairs({{v=2},{h=4},{conf="suspect"},{conf="lost"},{anchoredAt=0},{yAbs=false},
    {dim="minecraft:the_nether"},{x=math.huge}}) do
    local p=pose(0)
    for key,value in pairs(patch) do p[key]=value end
    origins[#origins+1]=p
  end
  for _,origin in ipairs(origins) do
    local result,err=m.api.location("dropoff",origin)
    assert(not result and err:find("blocked",1,true))
  end
  assert(#m.calls==0)
  assert(m.api.location("dropoff",pose(0)).id=="drop")
end)

test("legacy navigation origins resolve only through a matching anchored server pose",function()
  local m=fixture({enabled=false,turtle=true})
  local legacy={dim=dim,x=0,y=64,z=0,h=0}
  m.locations={location("drop",1)}
  m.fleet={{v=1,id="cc:17",computerId=17,boot="90000:17",pose=pose(0)}}
  local selected=m.api.location("dropoff",legacy)
  assert(selected and selected.id=="drop" and #m.calls==2)
  assert(m.calls[1].body.topic=="fleet" and m.calls[1].body.id=="cc:17")
  assert(m.calls[2].body.topic=="locations" and legacy.v==nil and legacy.frame==nil)
  local invalid={
    {v=2,id="cc:17",computerId=17,boot="90000:17",pose=pose(0)},
    {v=1,id="cc:18",computerId=18,boot="90000:17",pose=pose(0)},
    {v=1,id="cc:17",computerId=17,boot="older:17",pose=pose(0)},
    {v=1,id="cc:17",computerId=17,boot="90000:17",pose=pose(1)},
    {v=1,id="cc:17",computerId=17,boot="90000:17",pose=false},
    {v=1,id="cc:17",computerId=17,boot="90000:17",pose={dim=dim,x=0,y=64,z=0,h=0}},
  }
  for _,row in ipairs(invalid) do
    m.fleet={row}
    local result,err=m.api.location("dropoff",legacy)
    assert(not result and err:find("blocked",1,true) and m.calls[#m.calls].body.topic=="fleet")
  end
  for _,patch in ipairs({{frame="f:17:90000"},{conf="suspect"},{anchoredAt=0},{h=1}}) do
    local p=pose(0)
    for key,value in pairs(patch) do p[key]=value end
    m.fleet={{v=1,id="cc:17",computerId=17,boot="90000:17",pose=p}}
    assert(not m.api.location("dropoff",legacy) and m.calls[#m.calls].body.topic=="fleet")
  end
  m.fleet={}
  assert(not m.api.location("dropoff",legacy) and m.calls[#m.calls].body.topic=="fleet")
  m.offline=true
  local result,err=m.api.location("dropoff",legacy)
  assert(not result and err:find("unavailable",1,true))
end)

test("location lookup never mixes frames dimensions or confidence",function()
  local m=fixture({enabled=false})
  local relative=location("relative",0) relative.access.pose.frame="f:17:90000"
  local suspect=location("suspect",0) suspect.access.pose.conf="suspect"
  local lost=location("lost",0) lost.access.pose.conf="lost"
  local unanchored=location("unanchored",0) unanchored.access.pose.anchoredAt=0
  local future=location("future",0) future.v=2
  local vertical=location("vertical",0) vertical.access.pose.h=4
  local legacy=location("legacy",0) legacy.access.pose={dim=dim,x=0,y=64,z=0,h=0}
  local badSide=location("bad-side",0) badSide.access.side="back"
  m.locations={relative,suspect,lost,unanchored,future,vertical,legacy,badSide,
    location("nether",0,"dropoff","minecraft:the_nether"),location("safe",5)}
  local costs=0
  m.api.routeCost=function() costs=costs+1 return 5 end
  assert(m.api.location("dropoff",pose(0)).id=="safe" and costs==1)
  local origin=pose(0) origin.frame="f:17:90000"
  assert(not m.api.location("dropoff",origin) and costs==1)
  m.api.routeCost=nil
  assert(m.api.location("dropoff",origin).id=="relative")
  assert(not m.api.location("dropoff",origin,"safe"))
end)

test("route cost uses the explicit legacy navigation projection with north zero",function()
  local m=fixture({enabled=false})
  local site=location("north",0) site.access.pose.z=-1 site.access.pose.h=0
  m.locations={site}
  m.api.routeCost=function(target,origin)
    assert(target.v==nil and target.frame==nil and target.conf==nil and target.anchoredAt==nil)
    assert(origin.v==nil and origin.frame==nil and origin.conf==nil)
    assert(target.h==0 and target.z==-1 and origin.h==0 and origin.z==0 and target.dim==origin.dim)
    target.x=999 origin.z=999
    return 1
  end
  local origin=pose(0)
  local result=m.api.location("dropoff",origin)
  assert(result.id=="north" and result.access.pose.h==0 and result.access.pose.z==-1 and origin.z==0)
  assert(result.access.pose.v==1 and result.access.pose.x==0)
end)

test("unavailable and invalid route costs fall back to other eligible locations",function()
  local m=fixture({enabled=false})
  m.locations={location("throws",0),location("nan",1),location("infinite",2),location("negative",3),location("safe",4)}
  m.api.routeCost=function(p)
    if p.x==0 then error("navigation unavailable") end
    if p.x==1 then return 0/0 end
    if p.x==2 then return math.huge end
    if p.x==3 then return -1 end
    return 4
  end
  assert(m.api.location("dropoff",pose(0)).id=="safe")
  local result,reason=m.api.location("dropoff",pose(0),"throws")
  assert(not result and reason:find("blocked",1,true))
end)

test("the shared worker keeps a yielded transport request ahead of later work",function()
  local m=fixture({enabled=false})
  local order,done,active={}, {}, false
  m.rpc.call=function(op,fields)
    assert(not active and fields.body.wh2==1)
    active=true order[#order+1]=op
    if op=="first" then coroutine.yield("transport_reply") end
    active=false
    return {body={ok=true,value=op}}
  end
  m.spawn(function() done[1]=m.api.call("first",{value=1}) end)
  m.spawn(m.api.worker)
  m.spawn(function() done[2]=m.api.call("second",{value=2}) end)
  m.pump()
  assert(active and #order==1 and not done[1] and not done[2])
  m.push("transport_reply")
  assert(not active and done[1].value=="first" and done[2].value=="second")
  assert(table.concat(order,",")=="first,second" and m.api.status().queued==0)
end)

test("busy report retries preserve their first payload and retain the newer report",function()
  local m=fixture({enabled=false})
  local busy=true
  m.respond=function(op)
    assert(op=="wh2-report")
    if busy then return nil,"SSOT busy" end
    return {ok=true}
  end
  assert(m.api.record({detail="first"}) and not m.api.tick())
  assert(m.api.record({detail="newer"}) and m.api.status().queued==2)
  busy=false
  assert(m.api.tick() and m.api.status().queued==0 and #m.reports==3)
  assert(m.reports[1].detail=="first" and m.reports[2].detail=="first" and m.reports[3].detail=="newer")
  assert(m.calls[1].body.appliedSettingsRevision==m.calls[2].body.appliedSettingsRevision)
end)

test("computer settings patches use the numeric local identity only at that scope",function()
  local m=fixture({enabled=false})
  m.spawn(function() assert(m.api.call("wh2-settings",{scope="computer",baseRevision=0,set={mining=false}})) end)
  m.spawn(function() assert(m.api.call("wh2-settings",{scope="role",role="miner",baseRevision=0,set={mining=false}})) end)
  m.spawn(m.api.worker) m.pump()
  assert(m.calls[1].body.scope=="computer" and m.calls[1].body.computerId==17)
  assert(m.calls[2].body.scope=="role" and m.calls[2].body.computerId==nil)
end)

print(string.format("wh2-fleet-client: %d passed, %d failed",passed,failed))
if failed>0 then os.exit(1) end
