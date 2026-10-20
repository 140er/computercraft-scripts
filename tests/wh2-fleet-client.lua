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
local function pose(x,y,z,dimension) return {dim=dimension or dim,x=x,y=y or 64,z=z or 0} end
local function location(id,x,kind,dimension)
  return {id=id,kind=kind or "dropoff",enabled=true,access={pose=pose(x,64,0,dimension),side="front"}}
end
local function fixture(config)
  config=config or {}
  local m={time=100000,events={},threads={},timers={},calls={},saved={},order={},applies={},
    revision=1,effective={enabled=true,mining=true,autoCharge=false,dropoffId=false},locations={},classes={}}
  local timer=0
  local env=setmetatable({},{__index=_G})
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
  local rpc={}
  function rpc.call(op, fields)
    assert(type(fields.body)=="table" and fields.body.wh2==1)
    m.calls[#m.calls+1]={op=op,body=clone(fields.body)}
    if m.respond then return m.respond(op,fields.body) end
    if m.offline then return nil,"SSOT timeout (stopped)" end
    if op=="wh2-get" then
      local topic=fields.body.topic
      if topic=="settings" then
        return {body={wh2=1,ok=true,revision=m.revision,cursor=0,
          records={{id=tostring(fields.body.computerId),revision=m.revision,effective=clone(m.effective)}}}}
      end
      return {body={wh2=1,ok=true,revision=topic=="classes" and "1:2" or 1,
        records=clone(topic=="classes" and m.classes or m.locations),cursor=0}}
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

test("verified returned hint pauses and queues one refresh",function()
  local m=fixture()
  assert(m.api.tick())
  m.dispatch=function() return true,{op="wh2-changed",body={wh2=1,topic="settings",revision=2}} end
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
  m.dispatch=function() return true,{wh2=1,topic="settings",revision=3} end
  m.api.dispatch(0,{},"fleetserver")
  assert(m.api.ready() and m.api.status().queued==0)
end)

test("settings older than a verified hint cannot resume work",function()
  local m=fixture()
  assert(m.api.refresh())
  m.dispatch=function() return true,{wh2=1,topic="settings",revision=3} end
  m.api.dispatch(0,{},"fleetserver")
  m.revision=2
  assert(not m.api.refresh() and not m.api.ready() and #m.applies==1)
  m.revision=3 assert(m.api.refresh() and m.api.ready())
end)

test("a report revision pauses before the next action",function()
  local m=fixture()
  assert(m.api.tick())
  m.revision=2
  assert(m.api.record({state="mining"}))
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

print(string.format("wh2-fleet-client: %d passed, %d failed",passed,failed))
if failed>0 then os.exit(1) end
