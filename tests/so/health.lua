local R = dofile("tests/ui/render.lua")
local Harness = dofile("tests/so/harness.lua")

local ERROR = "tick\nfailed: so-mod-mine.lua:120 attempt to index a nil value while saving the mining job "..
  "for turtle 7; checkpoint refused because the disk is full. Free space in so-data, "..
  "then retry the job. The worker keeps its last saved pose and reservations while the "..
  "server waits for the checkpoint. Final detail: no blocks were changed."

local FIXTURES = {
  "tests/ui/fixtures/health/facts-runtime-29x12.txt",
  "tests/ui/fixtures/health/facts-modules-26x20.txt",
  "tests/ui/fixtures/health/facts-modules-29x12.txt",
  "tests/ui/fixtures/health/facts-26x20.txt",
  "tests/ui/fixtures/health/facts-next-26x20.txt",
  "tests/ui/fixtures/health/lost-26x20.txt",
  "tests/ui/fixtures/health/lost-detail-26x20.txt",
  "tests/ui/fixtures/health/gps-gap-26x20.txt",
  "tests/ui/fixtures/health/facts-29x12.txt",
  "tests/ui/fixtures/health/facts-next-29x12.txt",
  "tests/ui/fixtures/health/lost-29x12.txt",
  "tests/ui/fixtures/health/lost-detail-29x12.txt",
  "tests/ui/fixtures/health/gps-gap-29x12.txt",
  "tests/ui/fixtures/health/needs-error-26x20.txt", "tests/ui/fixtures/health/needs-error-29x12.txt",
  "tests/ui/fixtures/health/needs-enroll-26x20.txt", "tests/ui/fixtures/health/needs-enroll-29x12.txt",
  "tests/ui/fixtures/health/errors-list-26x20.txt", "tests/ui/fixtures/health/errors-list-29x12.txt",
  "tests/ui/fixtures/health/error-detail-26x20.txt", "tests/ui/fixtures/health/error-detail-29x12.txt",
  "tests/ui/fixtures/health/error-detail-next-26x20.txt", "tests/ui/fixtures/health/error-detail-next-29x12.txt",
  "tests/ui/fixtures/health/events-page2-26x20.txt", "tests/ui/fixtures/health/events-page2-29x12.txt",
  "tests/ui/fixtures/health/events-held-26x20.txt", "tests/ui/fixtures/health/events-held-29x12.txt",
  "tests/ui/fixtures/health/events-picker-26x20.txt", "tests/ui/fixtures/health/events-picker-29x12.txt",
  "tests/ui/fixtures/health/events-find-26x20.txt", "tests/ui/fixtures/health/events-find-29x12.txt",
  "tests/ui/fixtures/health/event-facts-26x20.txt", "tests/ui/fixtures/health/event-facts-29x12.txt",
  "tests/ui/fixtures/health/events-15x10.txt", "tests/ui/fixtures/health/events-page2-15x10.txt",
  "tests/ui/fixtures/health/events-picker-15x10.txt",
}

-- The real so-mod-state with the log of other.py's history_events: 40 events 20 s apart, a single
-- lumber.logs at 12, and later arrivals from 41 on.
local function history()
  local net = Harness.new()
  local m = net.machine({id=1, directories=true})
  m.install({"so-store.lua", "so-log.lua", "so-mod-state.lua"})
  local h = {now=0}
  m.env.SO = {mods={}, now=function() return h.now end, breathe=function() end, store=m.env.dofile("so-store.lua")}
  h.state = m.env.dofile("so-mod-state.lua")
  h.emit = function(i)
    local kind, data
    if i == 12 then kind, data = "lumber.logs", {id=5,count=12,total=40}
    elseif i%5 == 0 then kind, data = "mine.alert", {id=7,text="ore chest full",reason="full"}
    elseif i%7 == 0 then kind, data = "drops.broken", {text="chest 3 broken"}
    else kind, data = "mine.ore", {id=7,name="diamond",count=1,x=12,y=i-60,z=88} end
    h.now = i <= 40 and 3600000-(41-i)*20000 or 3590000+(i-41)*5000
    assert(h.state.emit(kind,data))
  end
  for i=1,40 do h.emit(i) end
  return h
end

local function health(state,configure)
  local t = {now=3600000,clock=0,entries={},screens={},enroll=nil}
  local env = setmetatable({}, {__index=_G})
  env.os = {clock=function() return t.clock end}
  env.peripheral = {find=function() return {} end}
  env.SO = {mods={},store={read=function() end},
    enroll={view=function(owner) assert(owner==nil);return t.enroll end},
    errors={entries=function() return t.entries end,status=function() return {count=#t.entries,bytes=340} end}}
  env.SO.mods.display = {screen=function(role,render,input) t.screens[role]={render=render,input=input} end}
  env.SO.mods.state = state
  t.env = env
  if configure then configure(t,env) end
  t.mod = assert(loadfile("so-mod-health.lua","t",env))()
  t.tick = function(now) t.now=now or t.now;t.clock=t.clock+5;t.mod.tick(t.now) end
  t.render = function(role,w,h,session) return t.screens[role].render(w,h,session) end
  t.input = function(role,session,id,open) t.screens[role].input({session=session,id=id,open=open}) end
  t.tick()
  return t
end

local function buttons(frame)
  local out = {}
  for _, b in ipairs(frame.buttons) do out[b.id]=b end
  return out
end

local function capture(frame,w,h)
  local out = R.capture(w,h)
  assert(#frame.rows==h)
  for y,row in ipairs(frame.rows) do
    local fg,bg = {},{}
    for _,run in ipairs(row.runs) do
      fg[#fg+1],bg[#bg+1]=string.rep(run[2],run[1]),string.rep(run[3],run[1])
    end
    fg,bg=table.concat(fg),table.concat(bg)
    assert(#row.text<=w and #fg==w and #bg==w,"row width")
    out.setCursorPos(1,y)
    out.blit(row.text..string.rep(" ",w-#row.text),fg,bg)
  end
  for i,b in ipairs(frame.buttons) do
    assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+b.h-1<=h,"button bounds "..b.id)
    for j,o in ipairs(frame.buttons) do
      assert(i==j or b.x+b.w<=o.x or o.x+o.w<=b.x or b.y+b.h<=o.y or o.y+o.h<=b.y,
        "overlapping buttons "..b.id.." "..o.id)
    end
  end
  return out
end

local function match(name,frame,w,h)
  local path = "tests/ui/fixtures/health/"..name..(name:match("%d+x%d+$") and "" or "-"..w.."x"..h)..".txt"
  local declared = false
  for _,v in ipairs(FIXTURES) do if v==path then declared=true end end
  assert(declared,path)
  local diff = R.diff(R.load(path),capture(frame,w,h))
  assert(#diff==0,path.."\n"..table.concat(diff,"\n"))
end

local function frameText(frame)
  local out = {}
  for _, row in ipairs(frame.rows) do out[#out+1]=row.text end
  return table.concat(out,"\n")
end

local function pages(t,role,w,h)
  local s, out = {}, {}
  for _=1,32 do
    local frame = t.render(role,w,h,s)
    capture(frame,w,h)
    out[#out+1] = frameText(frame)
    if not s.visibility[role].next then return table.concat(out,"\n") end
    t.input(role,s,"next")
  end
  error("health paging did not finish")
end

local function startup(cfg,setup)
  local net = Harness.new()
  local m = net.machine({id=1,capacity=16000000,modem=true})
  m.install({"so-server.lua","so-store.lua","so-errors.lua"})
  m.files["so-proto.lua"] = "return {since=function() end,prune=function() end}"
  m.files["so-pair.lua"] = "return {open=function() end,forgetPending=function() return {} end,pending=function() end}"
  if cfg ~= nil then m.files["so-server.cfg"] = type(cfg)=="table" and Harness.encode(cfg) or cfg end
  if setup then setup(m) end
  m.boot("so-server.lua")
  net.flush()
  assert(m.alive(),tostring(m.error))
  return net,m
end

local function diagnosticFacts(t)
  t.env.SO.health = {modules={
    ["so-mod-mine.lua"]={status="loaded",lastGood=3595000},
    ["so-mod-shop.lua"]={status="failed",error="loader failed"},
    ["so-mod-ar.lua"]={status="absent"}},revision=string.rep("a",40),
    config={retireLegacyPair=true},gpsGap=10,
    slowest={name="mine",tickMs=142,at=3480000},
    refused={totals={shape=512,time=2,mac=3,replay=4,blocked=5},evicted=384,
      senders={[612]={shape=1,time=0,mac=0,replay=0,blocked=0}}}}
  t.env.SO.mods.state = {diagnostics=function() return {bytes=6100000} end,
    view={get=function() return {data={free=6100000}} end}}
  t.tick()
end

local function sounding(config, initial)
  return health(nil,function(t,env)
    t.notes,t.diagnostics,t.machines,t.leases,t.points,t.disk = {},{},{},{},{},{}
    t.utc = 1767222000000
    env.os.epoch = function() return t.utc end
    env.SO.health = {config=config or {alarm=true}}
    env.SO.error = function(text) t.diagnostics[#t.diagnostics+1]=text end
    env.SO.mods.state = {get=function(key) if key=="machines" then return t.machines end end,
      view={get=function() return {data=t.disk} end}}
    env.SO.mods.lease = {status=function(id) return t.leases[id] or {} end}
    env.SO.mods.drops = {list=function() return t.points end}
    env.peripheral.getNames = function() return {"speaker_z","modem","speaker_a"} end
    env.peripheral.getType = function(name) return name~="modem" and "speaker" or "modem" end
    env.peripheral.wrap = function(name)
      return {playNote=function(...)
        t.notes[#t.notes+1]={name=name,args={...}}
        if t.play then return t.play() end
        return true
      end}
    end
    if initial then initial(t,env) end
  end)
end

return function(test,equal)
  test("sound facts are unready before gather and snapshots cannot change health",function()
    local env=setmetatable({SO={mods={},store={}}},{__index=_G})
    local mod=assert(loadfile("so-mod-health.lua","t",env))()
    equal(mod.soundFacts(),{ready=false,quiet=false,keys={}})
    local t=sounding()
    t.points={{id="b",broken=true}}
    t.tick()
    local facts=t.mod.soundFacts()
    equal(facts,{ready=true,quiet=false,keys={"drop/b"}})
    facts.keys[1],facts.ready,facts.quiet="fake",false,true
    equal(t.mod.soundFacts(),{ready=true,quiet=false,keys={"drop/b"}})
  end)

  test("alarm sounds each severity one key in lexical order once per tick",function()
    local t=sounding()
    t.points={{id="b",broken=true}}
    t.machines={[3]={role="worker",seen=0},[4]={role="worker",seen=0}}
    t.leases[4]={uncertain=true}
    t.disk.ratio=0.8
    t.env.SO.clock={refused=true}
    local want={"clock","disk","drop/b","lost/3","pose/4"}
    for i=1,#want do
      t.tick(t.now+1)
      equal(#t.notes,i)
      equal(t.notes[i],{name="speaker_a",args={"pling",0.5,12}})

    end
    equal(t.mod.soundFacts().keys,want)
    t.disk.ratio=0.91
    t.machines[3].pose={x=1,y=64,z=9}
    t.tick(t.now+10000)
    equal(#t.notes,5)
  end)

  test("severity two fuel tools holds dug pairing and errors stay silent",function()
    local t=sounding()
    t.env.SO.store.read=function(path)
      if path=="so-data/mine/job" then
        return {schema=1,generation=1,value={turtles={[3]={state="hold",error="held"}}}}
      end
    end
    t.machines={[3]={role="worker",seen=t.now}}
    t.leases[3]={tools={}}
    t.env.SO.mods.cells={retirement=function() return {status="pending"} end}
    t.env.SO.mods.shop={fuelAlerts=function() return {{text="fuel wait"}} end}
    t.env.SO.pair={pending=function() return 123 end}
    t.enroll={rows={{id=5}}}
    t.entries={{at=t.now,text="job alert failed"}}
    t.tick()
    equal(t.mod.soundFacts().keys,{})
    assert(t.mod.count()>=7)
    t.machines[3].seen=t.now+600000
    t.tick(t.now+600000)
    equal(#t.notes,0)
  end)

  test("alarm defaults off and pocketTone is independent with a silent enabling baseline",function()
    for _,cfg in ipairs({{}, {pocketTone=true}, {alarm=false,pocketTone=true}}) do
      local t=sounding(cfg)
      t.points={{id=1,broken=true}}
      t.tick();t.tick(t.now+600000)
      equal(#t.notes,0)
      cfg.alarm=true
      t.tick()
      equal(#t.notes,0)
      t.tick(t.now+299999);equal(#t.notes,0)
      t.tick(t.now+1);equal(#t.notes,1)
      cfg.alarm=false
      t.tick(t.now+600000);equal(#t.notes,1)
      cfg.alarm=true
      t.tick(t.now+600000);equal(#t.notes,1)
      t.tick(t.now+300000);equal(#t.notes,2)
    end
  end)

  test("alarm boot baseline repeats after five game minutes and frozen clocks cannot loop",function()
    local t=sounding(nil,function(s) s.points={{id=1,broken=true}} end)
    equal(#t.notes,0)
    t.tick(t.now+299999);equal(#t.notes,0)
    t.tick(t.now+1);equal(#t.notes,1)
    for _=1,5 do t.tick() end
    equal(#t.notes,1)
    t.tick(t.now+900000);equal(#t.notes,2)
    t.tick(t.now+299999);equal(#t.notes,2)
    t.tick(t.now+1);equal(#t.notes,3)
  end)

  test("alarm clear removes its reminder and recurrence and lost-to-pose sound again",function()
    local t=sounding()
    t.machines={[3]={role="worker",seen=0}}
    t.tick();equal(#t.notes,1)
    t.leases[3]={uncertain=true}
    t.tick(t.now+1);equal(#t.notes,2)
    equal(t.mod.soundFacts().keys,{"pose/3"})
    t.leases[3]={seen=t.now}
    t.tick();equal(t.mod.soundFacts().keys,{})
    t.leases[3]={uncertain=true}
    t.tick(t.now+1);equal(#t.notes,3)
  end)

  test("alarm missing busy detached and throwing speakers skip without queued retries or errors",function()
    for _,mode in ipairs({"missing","busy","detached","error"}) do
      local t=sounding()
      if mode=="missing" then t.env.peripheral.getNames=function() return {} end
      elseif mode=="detached" then t.env.peripheral.wrap=function() error("detached") end
      else t.play=function() if mode=="error" then error("speaker failed") end return false end end
      t.points={{id=1,broken=true}}
      t.tick()
      local attempts=#t.notes
      equal(attempts,(mode=="missing" or mode=="detached") and 0 or 1)
      t.tick(t.now+299999);equal(#t.notes,attempts)
      t.env.peripheral.getNames=function() return {"speaker_a"} end
      t.env.peripheral.wrap=function() return {playNote=function() t.notes[#t.notes+1]=true end} end
      t.tick(t.now+1);equal(#t.notes,attempts+1)
      equal(#t.diagnostics,0)
    end
  end)

  test("quiet hours include start exclude end and wrap Amsterdam midnight without deferred notes",function()
    local t=sounding({alarm=true,pocketTone=true,soundQuiet={startMinute=1380,endMinute=60}})
    t.points={{id=1,broken=true}}
    t.tick();equal(t.mod.soundFacts().quiet,true);equal(#t.notes,0)
    t.utc=1767225599000
    t.tick(t.now+600000);equal(#t.notes,0)
    t.utc=1767225600000
    t.tick();equal(t.mod.soundFacts().quiet,false);equal(#t.notes,0)
    t.tick(t.now+299999);equal(#t.notes,0)
    t.tick(t.now+1);equal(#t.notes,1)
    t.utc=1767218399000
    t.tick();equal(t.mod.soundFacts().quiet,false)
    t.utc=1767218400000
    t.tick();equal(t.mod.soundFacts().quiet,true)
  end)

  test("a new severity one key sounds on the quiet-end tick while standing keys wait five minutes",function()
    local t=sounding({alarm=true,soundQuiet={startMinute=1380,endMinute=60}},function(s)
      s.points={{id="standing",broken=true}}
    end)
    equal(t.mod.soundFacts().quiet,true)
    equal(#t.notes,0)
    t.points[#t.points+1]={id="new",broken=true}
    t.utc=1767225600000
    t.tick(t.now+1000)
    equal(t.mod.soundFacts().quiet,false)
    equal(t.mod.soundFacts().keys,{"drop/new","drop/standing"})
    equal(#t.notes,1)
    t.tick(t.now+299999)
    equal(#t.notes,1)
    t.points={{id="standing",broken=true}}
    t.tick(t.now+1)
    equal(#t.notes,2)
  end)

  test("quiet hours follow both Amsterdam DST transitions and equal endpoints mute all day",function()
    local t=sounding({soundQuiet={startMinute=120,endMinute=180}})
    for _,case in ipairs({{1774745999000,false},{1774746000000,false},
      {1792889999000,true},{1792890000000,true}}) do
      t.utc=case[1];t.tick();equal(t.mod.soundFacts().quiet,case[2])
    end
    t.env.SO.health.config.soundQuiet={startMinute=10,endMinute=10}
    t.tick();equal(t.mod.soundFacts().quiet,true)
    t.env.SO.health.config.soundQuiet=false
    t.tick();equal(t.mod.soundFacts().quiet,false)
  end)

  test("invalid quiet hours mute both outputs and diagnose once until corrected",function()
    for _,hours in ipairs({true,"23:00",{}, {startMinute=-1,endMinute=3},
      {startMinute=0,endMinute=1440},{startMinute=0.5,endMinute=1},{startMinute=0/0,endMinute=1}}) do
      local t=sounding({alarm=true,pocketTone=true,soundQuiet=hours})
      t.points={{id=1,broken=true}}
      t.tick();t.tick(t.now+600000)
      equal(t.mod.soundFacts().quiet,true);equal(#t.notes,0);equal(#t.diagnostics,1)
      assert(pages(t,"health",26,20):find("quiet invalid",1,true))
      t.env.SO.health.config.soundQuiet=false
      t.tick();equal(t.mod.soundFacts().quiet,false)
      equal(t.env.SO.health.soundError,nil)
      t.tick(t.now+300000);equal(#t.notes,1)
    end
  end)

  test("health loss snooze leaves the server alarm key active",function()
    local t=sounding()
    t.env.SO.mods.display.snoozer=function() return {on=function() return true end} end
    t.machines={["3"]={role="worker",seen=0}}
    t.tick()
    equal(t.mod.count(),0)
    equal(t.mod.soundFacts().keys,{"lost/3"})
    equal(#t.notes,1)
  end)

  test("server exposes default off sound flags and refreshes config without rewriting unrelated keys",function()
    local net,m=startup({secret="keep",state={coalesceHeartbeats=true}})
    local before=m.files["so-server.cfg"]
    equal(m.env.SO.health.config.alarm,false)
    equal(m.env.SO.health.config.pocketTone,false)
    equal(m.env.SO.health.config.soundQuiet,false)
    m.files["so-server.cfg"]=Harness.encode({alarm=true,pocketTone=false,soundQuiet={startMinute=5,endMinute=10},secret="keep"})
    local changed=m.files["so-server.cfg"]
    assert(before~=changed)
    net.advance(1.05)
    equal(m.env.SO.health.config.alarm,true)
    equal(m.env.SO.health.config.secret,"keep")
    equal(m.files["so-server.cfg"],changed)
  end)

  test("pending terminal revoke lets normal role commands through Enter and cancels confirmation",function()
    for _,enter in ipairs({28,156}) do
      local net,m=startup({terminalRevoke=true},function(server)
        server.files["so-pair.lua"]="return {open=function() end,forgetPending=function() return {} end,pending=function() end,key=function(id) if id==3 then return 'saved-key' end end}"
        server.files["so-mod-display.lua"]="return {name='display',handlers={},command=function(text) COMMAND=text;return true,'role applied' end}"
      end)
      m.env.os.queueEvent("key",19,false);net.flush()
      local function command(text)
        m.env.os.queueEvent("paste",text);m.env.os.queueEvent("key",enter,false);net.flush()
        assert(m.alive(),tostring(m.error))
      end
      command("3 revoke")
      assert(m.env.SO.terminal.notice:find("Type 3 to revoke",1,true))
      command("3 panel")
      equal(m.env.COMMAND,"3 panel");equal(m.env.SO.terminal.notice,"role applied")
      command("3")
      equal(m.env.COMMAND,"3")
      assert(m.env.SO.pair.key(3))
    end
  end)

  test("refused flood keeps per-reason totals and an evicted count outside 128 sender rows",function()
    local net,m=startup({},function(server)
      server.files["so-proto.lua"]="return {since=function() end,prune=function() end,decode=function(payload) return nil,payload end}"
    end)
    local function deliver(id,reason)
      m.env.os.queueEvent("rednet_message",id,reason,"so");net.flush()
      assert(m.alive(),tostring(m.error))
    end
    deliver(2,"time")
    for id=101,612 do deliver(id,"shape") end
    local refused,count=m.env.SO.health.refused,0
    for _ in pairs(refused.senders) do count=count+1 end
    equal(count,128);equal(refused.evicted,385)
    equal(refused.totals,{shape=512,time=1,mac=0,replay=0,blocked=0})
    local now=m.env.SO.now()
    m.env.SO.now=function() return now+600000 end
    net.advance(1.05)
    equal(next(refused.senders),nil)
    equal(refused.evicted,385)
    equal(refused.totals.shape,512);equal(refused.totals.time,1)
    local t=health()
    t.env.SO.health=m.env.SO.health
    t.tick()
    for _,size in ipairs({{26,20},{29,12}}) do
      local text=pages(t,"health",size[1],size[2])
      assert(text:find("512",1,true) and text:find("385",1,true))
    end
  end)

  test("refused traffic stays below one ERRORS line per sender in every ten minute interval",function()
    local net,m=startup({},function(server)
      server.files["so-proto.lua"]="return {since=function() end,prune=function() end,decode=function() return nil end}"
    end)
    local at=m.env.SO.now()
    for _,offset in ipairs({0,599999,600000,600001,1200000}) do
      m.env.SO.now=function() return at+offset end
      for id=2,260 do
        for _=1,2 do m.env.os.queueEvent("rednet_message",id,{},"so") end
      end
      net.flush()
      assert(m.alive(),tostring(m.error))
      equal(m.env.SO.errors.status().count,0)
    end
  end)

  test("health startup distinguishes loaded failed invalid and absent modules and tracks ticks",function()
    local net,m = startup({},function(server)
      server.files["so-mod-mine.lua"] = "return {name='mine',handlers={},tick=function() if FAIL then error('tick broken') end end}"
      server.files["so-mod-shop.lua"] = "error('load broken')"
      server.files["so-mod-extra.lua"] = "return false"
      server.files[".so-revision"] = string.rep("b",40).."\n"
    end)
    local runtime = m.env.SO.health
    equal(runtime.revision,string.rep("b",40))
    equal(runtime.modules["so-mod-mine.lua"].status,"loaded")
    equal(runtime.modules["so-mod-ar.lua"].status,"absent")
    equal(runtime.modules["so-mod-shop.lua"].status,"failed")
    assert(runtime.modules["so-mod-shop.lua"].error:find("load broken",1,true))
    equal(runtime.modules["so-mod-extra.lua"].error,"invalid module")
    net.advance(1)
    local status = runtime.modules["so-mod-mine.lua"]
    local good = status.lastGood
    assert(good)
    m.env.FAIL=true
    net.advance(1)
    equal(status.lastGood,good)
    assert(status.tickError:find("tick broken",1,true))
    m.env.FAIL=false
    net.advance(1)
    assert(status.lastGood>good)
    equal(status.tickError,nil)
  end)

  test("health startup bounds module facts and errors",function()
    local _,m = startup({},function(server)
      for i=1,90 do server.files["so-mod-extra"..i..".lua"]="error(string.rep('x',1000))" end
    end)
    local count=0
    for _,status in pairs(m.env.SO.health.modules) do
      count=count+1
      assert(not status.error or #status.error<=160)
    end
    equal(count,64)
  end)

  test("health startup logs the legacy decision once and only kept pairing prints the notice",function()
    for _,cfg in ipairs({{}, {retireLegacyPair=false}, {retireLegacyPair=true}}) do
      local net,m=startup(cfg)
      net.advance(3)
      local log=table.concat(m.log,"\n")
      local decision=cfg.retireLegacyPair and "retired" or "kept"
      local _,count=log:gsub("legacy pair: "..decision,"")
      equal(count,1)
      equal(log:find("The next server-only release removes legacy pair",1,true)~=nil,not cfg.retireLegacyPair)
    end
  end)

  test("health startup warns on unreadable config in the terminal log errors and NEEDS",function()
    for _,cfg in ipairs({"not a table","false"}) do
      local _,m=startup(cfg)
      local warning="so-server.cfg unreadable; defaults active"
      equal(m.env.SO.health.configError,warning)
      equal(m.env.SO.terminal.hostError,warning)
      assert(table.concat(m.log,"\n"):find(warning,1,true))
      assert(#m.env.SO.errors.entries()>0)
      local t=health()
      t.env.SO.health=m.env.SO.health
      t.tick()
      assert(pages(t,"attention",26,20):find("Config unreadable",1,true))
    end
    local _,m=startup(nil)
    equal(m.env.SO.health.configError,nil)
    local _,denied=startup({},function(server)
      local open=server.env.fs.open
      server.env.fs.open=function(path,mode) if path=="so-server.cfg" then return nil end return open(path,mode) end
    end)
    assert(denied.env.SO.health.configError)
  end)

  test("health uses one byte formatter for event free and error storage",function()
    for _,case in ipairs({{0,"0 B"},{1023,"1023 B"},{1024,"1.0 KB"},{81920,"80.0 KB"},
      {1048576,"1.0 MB"},{6100000,"5.8 MB"}}) do
      local t=health()
      t.env.SO.mods.state={diagnostics=function() return {bytes=case[1]} end,
        view={get=function() return {data={free=case[1]}} end}}
      t.env.SO.errors.status=function() return {count=0,bytes=case[1]} end
      t.tick()
      for _,size in ipairs({{26,20},{29,12}}) do
        local text=pages(t,"health",size[1],size[2])
        local _,count=text:gsub(case[2]:gsub("%.","%%."),"")
        equal(count,3)
      end
    end
  end)

  test("health a fresh lease contact clears a stale registry loss without hiding other warnings",function()
    local t=health()
    local facts={now=500000,disk={},machines={["5"]={role="worker",seen=0}},leases={["5"]={seen=499000}}}
    equal(#t.mod.attention(facts),0)
    facts.leases["5"].uncertain=true
    facts.snoozed={["5"]=true}
    equal(t.mod.attention(facts)[1].key,"pose/5")
  end)

  test("health startup compares saved position to GPS once without changing the position",function()
    for _,gap in ipairs({0,2,2.1,10}) do
      local cfg={pos={x=120,y=64,z=-30,dim="minecraft:overworld"}}
      local calls=0
      local net,m=startup(cfg,function(server)
        server.env.gps={locate=function(timeout) equal(timeout,2);calls=calls+1;return 120+gap,64,-30 end}
      end)
      net.advance(2)
      equal(calls,1)
      assert(math.abs(m.env.SO.health.gpsGap-gap)<0.00001)
      equal(m.env.textutils.unserialize(m.files["so-server.cfg"]),cfg)
      local t=health()
      local rows=t.mod.attention({now=0,disk={},gpsGap=m.env.SO.health.gpsGap})
      equal(#rows,gap>2 and 1 or 0)
      if gap>2 then equal(rows[1].key,"gps") end
    end
    for _,gps in ipairs({{}, {locate=function() return nil end}, {locate=function() error("offline") end},
      {locate=function() return 0/0,64,0 end}}) do
      local _,m=startup({pos={x=0,y=64,z=0}},function(server) server.env.gps=gps end)
      equal(m.env.SO.health.gpsGap,nil)
    end
    local _,m=startup({},function(server) server.env.gps={locate=function() error("no saved position") end} end)
    equal(m.env.SO.health.gpsGap,nil)
  end)

  for _,size in ipairs({{26,20},{29,12}}) do
    local w,h=size[1],size[2]
    for _,row in ipairs({{"modules","1 loaded"},{"skip","1 fail 1 absent"},{"rev","aaaaaaaa"},{"cfg","retireLegacyPair"},
      {"pos","missing"},{"GPS gap","10.0 blocks"},{"event bytes","5.8 MB"},{"disk free","5.8 MB"},{"errors","340 B"},
      {"uptime","0s"},{"tick","wall -"},{"tick cost","-"},{"clock reserve","unknown"},
      {"slow module","mine"},{"peak tick","142ms"},{"peak age","2m"},
      {"deny shape","512"},{"deny time","2"},{"deny mac","3"},{"deny replay","4"},{"deny blocked","5"},
      {"refused","526"},{"evicted","384"},{"sender 612","1"},
      {"events","unavailable"},{"snapshot","none"},{"disk","0%"},{"modems","1"},
      {"paired","0 online"},{"leases","0 open"},{"ar","absent"},{"mine","ok 5s ago"},{"shop","failed"},{"error","loader failed"}}) do
      test("health row "..row[1].." fits "..w.."x"..h,function()
        local t=health()
        diagnosticFacts(t)
        local text=pages(t,"health",w,h)
        local found
        for line in text:gmatch("[^\n]+") do
          if line:sub(2,#row[1]+1)==row[1] and line:sub(#row[1]+2,#row[1]+2)==" " then
            found = found or line:find(row[2],#row[1]+2,true)
          end
        end
        assert(found,row[1].." value "..row[2].." missing in "..text)
      end)
    end

    test("health flags show only enabled flags and safe values at "..w.."x"..h,function()
      local t=health()
      diagnosticFacts(t)
      t.env.SO.health.config={pos={x=120,y=64,z=-30},enroll=true,remoteDimensions=true,
        setupMovement=false,secret="do not display",state={coalesceHeartbeats=true}}
      t.tick()
      local text=pages(t,"health",w,h)
      assert(text:find("enroll",1,true) and text:find("remoteDimensions",1,true))
      assert(text:find("x120 y64 z-30",1,true))
      assert(not text:find("setupMovement",1,true) and not text:find("do not display",1,true))
      t.env.SO.health.config={}
      t.tick()
      assert(pages(t,"health",w,h):find("defaults",1,true))
    end)

    test("health lost silence and last pose fit "..w.."x"..h,function()
      local t,s=health(),{}
      local machines={["12"]={role="worker",seen=t.now-420000,pose={x=120,y=64,z=-30}}}
      t.env.SO.mods.state={get=function(key) if key=="machines" then return machines end end}
      t.tick()
      local rows=t.mod.attention({now=t.now,disk={},machines=machines})
      equal(rows[1].text,"T12 lost 7m x120 y64 z-30")
      match("lost",t.render("attention",w,h,s),w,h)
      machines["12"].pose=nil
      t.tick()
      assert(pages(t,"attention",w,h):find("T12 lost 7m",1,true))
      equal(t.mod.attention({now=t.now,disk={},machines=machines})[1].text,"T12 lost 7m")
    end)

    test("health GPS gap row matches its fixture at "..w.."x"..h,function()
      local t=health()
      diagnosticFacts(t)
      match("gps-gap",t.render("attention",w,h,{}),w,h)
    end)

    test("health facts pages match their fixtures at "..w.."x"..h,function()
      local t,s=health(),{}
      diagnosticFacts(t)
      match("facts",t.render("health",w,h,s),w,h)
      t.input("health",s,"next")
      match("facts-next",t.render("health",w,h,s),w,h)
      if h==12 then
        t.input("health",s,"next")
        match("facts-runtime",t.render("health",w,h,s),w,h)
      end
      while s.visibility.health.next do t.input("health",s,"next");t.render("health",w,h,s) end
      match("facts-modules",t.render("health",w,h,s),w,h)
    end)

    test("health lost SNOOZE calls U4-B for one hour and contact clears it at "..w.."x"..h,function()
      local t,s=health(),{}
      local net=Harness.new()
      local m=net.machine({id=1})
      m.install({"so-store.lua","so-mod-display.lua","so-ui.lua"})
      m.env.SO={mods={},store=m.env.dofile("so-store.lua"),now=function() return t.now end}
      local display=m.env.dofile("so-mod-display.lua")
      local calls=0
      t.env.SO.mods.display.snoozer=function(span) equal(span,3600000);calls=calls+1;return display.snoozer(span) end
      local machines={["12"]={role="worker",seen=t.now-420000,pose={x=120,y=64,z=-30}}}
      t.env.SO.mods.state={get=function(key) if key=="machines" then return machines end end}
      t.tick()
      t.render("attention",w,h,s)
      t.input("attention",s,"item:lost/12")
      match("lost-detail",t.render("attention",w,h,s),w,h)
      t.input("attention",s,"lost-snooze")
      equal(t.mod.count(),0)
      assert(frameText(t.render("attention",w,h,{})):find("all clear",1,true))
      t.tick(t.now+3599999)
      equal(t.mod.count(),0)
      t.tick(t.now+1)
      equal(t.mod.count(),1)
      t.render("attention",w,h,s);t.input("attention",s,"item:lost/12");t.render("attention",w,h,s)
      t.input("attention",s,"lost-snooze")
      machines["12"].seen=t.now+1000
      t.tick(t.now+1000)
      equal(t.mod.count(),0)
      t.tick(t.now+180001)
      equal(t.mod.count(),1)
      equal(calls,1)
    end)
  end

  test("health shows add disk space during the snooze, then restores the pending ask",function()
    local F=dofile("tests/so/dug-fixture.lua")
    local cells,m,net=F.setup(nil,500)
    m.env.SO.mods.state={disk=function() return {pressure=true} end}
    assert(cells.tick(net.time))
    assert(cells.decideRetirement(cells.retirement().id,"keep"))
    net.time=net.time+30001
    assert(cells.tick(net.time))
    local t=health()
    local facts={now=net.time,disk={},retirement=cells.retirement()}
    equal(facts.retirement.status,"snoozed")
    local rows=t.mod.attention(facts)
    equal(#rows,1)
    equal(rows[1].key,"disk-snooze")
    equal(rows[1].severity,2)
    equal(rows[1].text,"Add disk space")
    equal(rows[1].target,"health")
    net.time=facts.retirement.untilAt
    assert(cells.tick(net.time))
    facts.now,facts.retirement=net.time,cells.retirement()
    equal(facts.retirement.status,"pending")
    rows=t.mod.attention(facts)
    equal(#rows,1)
    equal(rows[1].key,"dug")
    equal(rows[1].target,"status")
  end)

  test("health keeps UTF-8 codepoints whole at list and detail cut points",function()
    local function valid(text)
      local i = 1
      while i <= #text do
        local byte = text:byte(i)
        local size = byte < 128 and 1 or byte >= 194 and byte <= 223 and 2
          or byte >= 224 and byte <= 239 and 3 or byte >= 240 and byte <= 244 and 4
        assert(size,"invalid UTF-8 lead byte at "..i)
        for j=1,size-1 do
          local nextByte = text:byte(i+j)
          assert(nextByte and nextByte >= 128 and nextByte <= 191,"split UTF-8 codepoint at "..i)
        end
        i = i+size
      end
    end
    for _,size in ipairs({{26,20},{29,12}}) do
      local w,h = size[1],size[2]
      for _,width in ipairs({w-2,w-7}) do
        for _,char in ipairs({"\195\169","\226\130\172","\240\159\152\128"}) do
          for offset=1,#char-1 do
            local t,s = health(),{}
            local text = string.rep("x",width-offset)..char..string.rep("z",w+4).." final detail"
            t.entries = {{at=t.now,text=text}}
            local frame = t.render("errors",w,h,s)
            capture(frame,w,h)
            for _,row in ipairs(frame.rows) do valid(row.text) end
            t.input("errors",s,"error:1")
            local got = {}
            for page=1,64 do
              frame = t.render("errors",w,h,s)
              capture(frame,w,h)
              local top
              for y,row in ipairs(frame.rows) do
                valid(row.text)
                if row.text:find("ago",1,true) then top=y+1+(h>=16 and 1 or 0) end
              end
              assert(top)
              for y=top,h-1-(h>=16 and 1 or 0) do got[#got+1]=frame.rows[y].text end
              if not s.visibility.errors.errorNext then break end
              t.input("errors",s,"next")
              assert(page<64,"UTF-8 detail paging did not finish")
            end
            equal(table.concat(got):gsub("%s",""),text:gsub("%s",""))
          end
        end
      end
    end
  end)

  test("health error list stops at the first line break and details keep every line",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local w,h = size[1],size[2]
      for _,newline in ipairs({"\n","\r\n","\r"}) do
        for _,first in ipairs({"FIRST",""}) do
          local t,s = health(),{}
          t.entries = {{at=t.now,text=first..newline.."SECOND line"}}
          local frame = t.render("errors",w,h,s)
          local preview = {}
          for _,row in ipairs(frame.rows) do preview[#preview+1]=row.text end
          assert(not table.concat(preview):find("SECOND",1,true),"list includes a later line")
          t.input("errors",s,"error:1")
          frame = t.render("errors",w,h,s)
          capture(frame,w,h)
          local detail = {}
          for _,row in ipairs(frame.rows) do detail[#detail+1]=row.text end
          assert(table.concat(detail):find("SECOND line",1,true),"detail lost a later line")
        end
      end
    end
  end)

  test("health gathers pending enroll rows without an owner token",function()
    local t,s = health(),{}
    t.enroll={owner=6,rows={{id=17,kind="worker",n="nonce"}}}
    t.tick(t.now+5000)
    local frame=t.render("attention",26,20,s)
    equal(t.mod.count(),1)
    assert(buttons(frame)["item:pair/17"])
    local opened
    t.input("attention",s,"item:pair/17",function(...) opened={...} end)
    equal(opened,{"panel",{"pair"}})
    t.enroll=nil
    t.tick(t.now+5000)
    equal(t.mod.count(),0)
    local env=setmetatable({SO={mods={},store={}}},{__index=_G})
    local mod=assert(loadfile("so-mod-health.lua","t",env))()
    mod.tick(0)
    equal(mod.count(),0)
  end)

  test("health shows one NEEDS row for fresh errors and expires it after ten minutes",function()
    local t,s=health(),{}
    t.entries={{at=t.now-700000,text="old"},{at=t.now,text="fresh"}}
    t.tick(t.now+5000)
    equal(t.mod.count(),1)
    local frame=t.render("attention",26,20,s)
    assert(buttons(frame)["item:errors"])
    local opened
    t.input("attention",s,"item:errors",function(role) opened=role end)
    equal(opened,"errors")
    t.tick(4199999)
    equal(t.mod.count(),1)
    t.tick(4205000)
    equal(t.mod.count(),0)
    equal(#t.entries,2)
    local facts={now=600000,disk={},errorCount=1,errorAt=0}
    equal(#t.mod.attention(facts),0)
    facts.now=599999
    equal(#t.mod.attention(facts),1)
    facts.errorCount=0
    equal(#t.mod.attention(facts),0)
  end)

  test("health fresh errors and enroll rows match generated fixtures at both sizes",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local w,h=size[1],size[2]
      local t,s=health(),{}
      t.entries={{at=3590000,text=ERROR}}
      t.tick()
      match("needs-error",t.render("attention",w,h,s),w,h)
      match("errors-list",t.render("errors",w,h,s),w,h)
      local row=buttons(t.render("errors",w,h,s))["error:1"]
      assert(row and row.x==1 and row.w==w)
      t.input("errors",s,"error:1")
      match("error-detail",t.render("errors",w,h,s),w,h)
      t.input("errors",s,"next")
      match("error-detail-next",t.render("errors",w,h,s),w,h)
      t.input("errors",s,"prev")
      match("error-detail",t.render("errors",w,h,s),w,h)
      t.input("errors",s,"error-back")
      match("errors-list",t.render("errors",w,h,s),w,h)
      t.entries={}
      t.enroll={rows={{id=17}}}
      t.tick(3610000)
      match("needs-enroll",t.render("attention",w,h,s),w,h)
    end
  end)

  test("health error details keep all 2048 bytes reachable across pages and resize",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local t,s=health(),{}
      local text=("start\n"..string.rep("long/path/without/spaces/",65)..string.rep(" word",130)):sub(1,2038).." END-MARK!"
      equal(#text,2048)
      t.entries={{at=t.now,text=text}}
      t.render("errors",size[1],size[2],s)
      t.input("errors",s,"error:1")
      local got={}
      for page=1,128 do
        local frame=t.render("errors",size[1],size[2],s)
        capture(frame,size[1],size[2])
        local top
        for y,row in ipairs(frame.rows) do if row.text:find("ago",1,true) then top=y+1+(size[2]>=16 and 1 or 0) end end
        assert(top)
        for y=top,size[2]-1-(size[2]>=16 and 1 or 0) do got[#got+1]=frame.rows[y].text end
        if not s.visibility.errors.errorNext then break end
        t.input("errors",s,"next")
        assert(page<128,"detail paging did not finish")
      end
      equal(table.concat(got):gsub("%s",""),text:gsub("%s",""))
      local other={}
      equal(buttons(t.render("errors",26,20,other))["error-back"],nil)
      t.entries={{at=t.now,text="replacement"}}
      t.render("errors",57,24,s)
      equal(s.visibility.errors.error.text,text)
      t.input("errors",s,"errors",function(role) equal(role,"errors") end)
      equal(s.visibility.errors.error,nil)
    end
  end)

  test("health returns from an error detail to the same list page",function()
    local t,s=health(),{}
    for i=1,30 do t.entries[i]={at=t.now,text="error "..i} end
    t.render("errors",29,12,s)
    t.input("errors",s,"next")
    local frame=t.render("errors",29,12,s)
    local id
    for key in pairs(buttons(frame)) do if key:match("^error:") then id=key;break end end
    assert(id)
    t.input("errors",s,id)
    assert(buttons(t.render("errors",29,12,s))["error-back"])
    t.input("errors",s,"error-back")
    equal(s.visibility.errors.page,2)
    assert(buttons(t.render("errors",29,12,s))[id])
  end)

  local function text(frame)
    local out = {}
    for _,row in ipairs(frame.rows) do out[#out+1]=row.text end
    return table.concat(out,"\n")
  end

  test("health EVENTS page 2 shows 2 and LATEST returns to the newest page with the filter",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local w,h=size[1],size[2]
      local t,s=health(history().state),{}
      local first=text(t.render("events",w,h,s))
      assert(buttons(t.render("events",w,h,s)).hold)
      t.input("events",s,"next")
      local frame=t.render("events",w,h,s)
      match("events-page2",frame,w,h)
      equal(frame.rows[h].text:match("(%d+)%s+\17"),"2")
      t.input("events",s,"latest")
      equal(text(t.render("events",w,h,s)),first)
      -- LATEST keeps the kind: four pages deep in mine.ore it returns to mine.ore's newest page.
      t.input("events",s,"kind")
      local kinds=s.visibility.events.picker.kinds
      for i,kind in ipairs(kinds) do if kind=="mine.ore" then t.input("events",s,"pick:"..i) end end
      for _=1,3 do t.render("events",w,h,s);t.input("events",s,"next") end
      t.render("events",w,h,s)
      t.input("events",s,"latest")
      equal(s.visibility.events.page,1)
      equal(s.visibility.events.kind,"mine.ore")
      assert(text(t.render("events",w,h,s)):find("40s mine.ore",1,true))
    end
  end)

  test("health EVENTS kind picker offers a kind seen only on page 4 from page 1",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local w,h=size[1],size[2]
      -- The single lumber.logs is the 29th newest event: page 4 of eight rows at 29x12, page 3 at 26x20.
      local t,s=health(history().state),{}
      assert(not text(t.render("events",w,h,s)):find("lumber",1,true))
      t.input("events",s,"kind")
      local frame=t.render("events",w,h,s)
      match("events-picker",frame,w,h)
      local pick
      for id in pairs(buttons(frame)) do
        local n=id:match("^pick:(%d+)$")
        if n and s.visibility.events.picker.kinds[tonumber(n)]=="lumber.logs" then pick=id end
      end
      assert(pick,"lumber.logs offered")
      t.input("events",s,pick)
      frame=t.render("events",w,h,s)
      equal(buttons(frame).kind.label,"lumber.logs")
      assert(text(frame):find("9m lumber.logs",1,true),text(frame))
      -- BACK leaves the picker without changing the kind; ALL clears it.
      t.input("events",s,"kind")
      t.input("events",s,"kind-back")
      equal(buttons(t.render("events",w,h,s)).kind.label,"lumber.logs")
      t.input("events",s,"kind")
      t.input("events",s,"pick:1")
      equal(buttons(t.render("events",w,h,s)).kind.label,"all")
    end
  end)

  test("health HOLD keeps EVENTS rows while events arrive, another display stays live, LIVE resumes",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local w,h=size[1],size[2]
      local log=history()
      local t,s,other=health(log.state),{},{}
      local before=text(t.render("events",w,h,s))
      t.input("events",s,"hold")
      log.emit(41);log.emit(42)
      local frame=t.render("events",w,h,s)
      match("events-held",frame,w,h)
      local held=text(frame)
      equal(held:gsub("LIVE","HOLD"),before)
      assert(text(t.render("events",w,h,other)):find("10s mine.ore",1,true))
      -- Paging from the held page and back keeps the hold.
      t.input("events",s,"next");t.render("events",w,h,s);t.input("events",s,"prev")
      equal(text(t.render("events",w,h,s)),held)
      t.input("events",s,"live")
      frame=t.render("events",w,h,s)
      assert(text(frame):find("5s drops.broken",1,true) and buttons(frame).hold)
    end
  end)

  test("health EVENTS text search filters rows case-insensitively and clears",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local w,h=size[1],size[2]
      local t,s=health(history().state),{}
      local all=text(t.render("events",w,h,s))
      t.screens.events.input({session=s,text="chest"})
      local frame=t.render("events",w,h,s)
      match("events-find",frame,w,h)
      assert(not text(frame):find("mine.ore",1,true))
      t.screens.events.input({session=s,text=" CHEST "})
      equal(text(t.render("events",w,h,s)):lower(),text(frame):lower())
      t.input("events",s,"find")
      equal(text(t.render("events",w,h,s)),all)
      t.screens.events.input({session=s,text="chest"})
      t.screens.events.input({session=s,text="*"})
      equal(text(t.render("events",w,h,s)),all)
    end
    -- The state filter: name and kind match, the query is cut to 32 bytes, no match is empty.
    local state=history().state
    equal(#state.history.page({text="DIAMOND",count=50}).entries,27)
    equal(#state.history.page({text="lumber.",count=50}).entries,1)
    equal(#state.history.page({text="ore chest full"..string.rep("x",18).."ignored",count=50}).entries,0)
    equal(#state.history.page({text="nothing like it",count=50}).entries,0)
    equal(state.history.kinds(),{"drops.broken","lumber.logs","mine.alert","mine.ore"})
  end)

  test("health opens an event's facts from its row and BACK returns to the same page",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local w,h=size[1],size[2]
      local t,s=health(history().state),{}
      local row=buttons(t.render("events",w,h,s))["event:2"]
      assert(row and row.x==1 and row.w==w)
      t.input("events",s,"event:2")
      match("event-facts",t.render("events",w,h,s),w,h)
      t.input("events",s,"fact-back")
      t.input("events",s,"next")
      local list=text(t.render("events",w,h,s))
      t.input("events",s,"event:1")
      assert(buttons(t.render("events",w,h,s))["fact-back"])
      t.input("events",s,"fact-back")
      equal(s.visibility.events.page,2)
      equal(text(t.render("events",w,h,s)),list)
    end
  end)

  -- Footer controls on the last two rows: each draws its own label in its touch area, the page
  -- number sits outside every touch area, and a tap anywhere in an area reaches only that control.
  local function footer(frame,w,h,note)
    capture(frame,w,h)
    local list,cells = {},{}
    for _,b in ipairs(frame.buttons) do
      if b.y >= h-1 and not b.id:match("^event:") and not b.id:match("^pick:") then
        list[#list+1] = b
        equal(frame.rows[b.y].text:sub(b.x,b.x+b.w-1):match("^%s*(.-)%s*$"),b.label,b.id.." label at "..w)
        for x=b.x,b.x+b.w-1 do cells[b.y*100+x]=b.id end
      end
    end
    if note then
      local row,at = frame.rows[h].text,nil
      for x=1,#row do
        if row:sub(x,x+#note-1) == note and not cells[h*100+x] then at = x end
      end
      assert(at and not cells[h*100+at+#note-1],"page number "..note.." clear of the chips at "..w)
    end
    return list,cells
  end
  local function tapAt(t,s,frame,x,y)
    local hit
    for _,b in ipairs(frame.buttons) do
      if x >= b.x and x < b.x+b.w and y >= b.y and y < b.y+b.h then assert(not hit,"two controls at "..x..","..y);hit=b.id end
    end
    t.input("events",s,assert(hit,"no control at "..x..","..y))
    return hit
  end

  test("health history footers draw each control once and taps reach only it at 15x10, 26x20 and 29x12",function()
    for _,size in ipairs({{15,10},{26,20},{29,12}}) do
      local w,h=size[1],size[2]
      local t,s=health(history().state),{}
      local frame=t.render("events",w,h,s)
      if w==15 then match("events-15x10",frame,w,h) end
      local list=footer(frame,w,h)
      equal(#list,3)
      -- Page 3: LATEST, PREV and NEXT each lead to their own page from every cell they cover.
      for _,want in ipairs({{"latest",1},{"prev",2},{"next",4}}) do
        local fresh,go={},nil
        t.render("events",w,h,fresh);t.input("events",fresh,"next")
        t.render("events",w,h,fresh);t.input("events",fresh,"next")
        frame=t.render("events",w,h,fresh)
        for _,b in ipairs(footer(frame,w,h,"3")) do if b.id==want[1] then go=b end end
        assert(go,want[1].." drawn at "..w)
        for x=go.x,go.x+go.w-1 do
          local again={}
          for k,v in pairs(fresh.visibility.events) do again[k]=v end
          again.cursors={}
          for k,v in pairs(fresh.visibility.events.cursors) do again.cursors[k]=v end
          local session={visibility={events=again}}
          t.render("events",w,h,session)
          equal(tapAt(t,session,frame,x,go.y),want[1])
          equal(session.visibility.events.page,want[2],want[1].." at "..w)
        end
      end
      -- Page 2 draws its number clear of LATEST and the arrows.
      s={}
      t.render("events",w,h,s);t.input("events",s,"next")
      frame=t.render("events",w,h,s)
      if w==15 then match("events-page2-15x10",frame,w,h) end
      footer(frame,w,h,"2")
      -- Page 1: HOLD holds and stays on page 1; the picker's BACK closes it.
      s={}
      frame=t.render("events",w,h,s)
      for _,b in ipairs(footer(frame,w,h)) do
        if b.id=="hold" then tapAt(t,s,frame,b.x+b.w-1,b.y) end
      end
      assert(s.visibility.events.cursors[1] and s.visibility.events.page==1)
      footer(t.render("events",w,h,s),w,h)
      t.input("events",s,"kind")
      frame=t.render("events",w,h,s)
      if w==15 then match("events-picker-15x10",frame,w,h) end
      for _,b in ipairs(footer(frame,w,h,"1/1")) do
        if b.id=="kind-back" then tapAt(t,s,frame,b.x+b.w-1,b.y) end
      end
      equal(s.visibility.events.picker,nil)
    end
  end)
end
