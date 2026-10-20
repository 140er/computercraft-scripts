local runtime,scenario = ...
local navigation=scenario=="nav"
local id = os.getComputerID()
local A, S = dofile("atomic.lua"), dofile("ssot.lua")
local client = dofile("ssot-client.lua").new({server=0,secret="test-secret-123456",timeout=5})
local received, pending, serial, checks, timeline = {}, {}, 0, {}, {}
local controls={}
local drop, duplicate, delayed = false, false, {}
local previousReply
local readyDropped=false
local worldBoot=tostring(os.epoch("utc"))
local send = rednet.send
rednet.send = function(to,m,proto)
  if navigation and runtime=="sandbox" and proto=="ssot_test" and type(m)=="table" and m.kind=="ready" and not readyDropped then
    readyDropped=true return true
  end
  if proto == "fleetserver" and type(m) == "table" and m.type == "ssot" then
    assert(not client.dispatch(999,{v=1,type="ssot_reply",server=0,rid=m.rid,ok=true},proto))
    assert(not client.dispatch(0,{v=1,type="ssot_reply",server=0,rid=m.rid,ok=true},proto))
    if duplicate then send(to,m,proto) end
  end
  return send(to,m,proto)
end
local function writeJSON(path,value)
  local h = assert(fs.open(path,"w")) h.write(textutils.serializeJSON(value)) h.close()
end
local function test(name,run)
  local ok,err = pcall(run)
  checks[#checks+1] = {name=name,ok=ok,error=not ok and tostring(err) or nil}
  local log=assert(fs.open("checks.log","a")) log.writeLine((ok and "PASS " or "FAIL ") .. name .. " " .. tostring(err or "")) log.close()
  sleep(0)
  assert(ok, name .. ": " .. tostring(err))
end
local function waitMessage(kind,from,timeout,retry,rid)
  local untilAt = os.clock() + (timeout or (navigation and 600 or 120))
  local nextRetry=0
  repeat
    for i,m in ipairs(received) do
      if m.packet.kind == kind and (not from or from == m.from) and (not rid or m.packet.rid==rid) then table.remove(received,i) return m.packet end
    end
    if retry and os.clock()>=nextRetry then retry() nextRetry=os.clock()+.5 end
    sleep(.05)
  until os.clock() >= untilAt
  error("timeout waiting for " .. kind .. " from " .. tostring(from))
end
local function readMetrics()
  serial=serial+1
  local rid=worldBoot .. ":metrics:" .. serial
  send(0,{action="metrics",rid=rid},"ssot_test")
  return waitMessage("metrics",0,nil,nil,rid)
end
local function world(op,args)
  serial = serial + 1
  local rid = worldBoot .. ":" .. id .. ":" .. serial
  local untilAt,nextSend = os.clock()+30,0
  while not pending[rid] and os.clock() < untilAt do
    if os.clock()>=nextSend then
      send(5,{op=op,args=args or {},rid=rid},"ssot_world") nextSend=os.clock()+.5
    end
    sleep(.01)
  end
  local r = assert(pending[rid],"world timeout") pending[rid] = nil return r
end
local function receive()
  while true do
    local ev,from,m,proto = os.pullEvent()
    if ev == "rednet_message" then
      if proto == "fleetserver" and type(m) == "table" and m.type == "ssot_reply" then
        if not drop then
          if duplicate then
            if previousReply and previousReply.m.rid~=m.rid then delayed[#delayed+1]=previousReply end
            delayed[#delayed+1] = {from=from,m=m,proto=proto}
            previousReply={from=from,m=m,proto=proto}
            os.startTimer(.08)
          else client.dispatch(from,m,proto) end
        end
      elseif proto == "ssot_world_reply" and from == 5 then pending[m.rid] = m.values
      elseif navigation and proto=="minearmy" and from==0 and type(m)=="table" then
        controls[m.type]=(controls[m.type] or 0)+1
        if m.type=="estop" then
          send(0,{type="cmd_ack",cid=m.cid,commandEpoch=controls.estop>=2 and m.commandEpoch or "stale"},"minearmy")
        end
      elseif proto == "ssot_test" and type(m) == "table" then
        if m.action == "reboot" and from == 4 then os.reboot() end
        received[#received+1] = {from=from,packet=m}
      end
    elseif ev == "timer" and #delayed > 0 then
      for i=#delayed,1,-1 do
        local r = table.remove(delayed,i)
        client.dispatch(r.from,r.m,r.proto)
        client.dispatch(r.from,r.m,r.proto)
      end
    end
  end
end
local starts = { [1]={dim="minecraft:overworld",x=-2,y=65,z=0,h=1},
  [2]={dim="minecraft:overworld",x=0,y=65,z=-2,h=2}, [3]={dim="minecraft:overworld",x=2,y=65,z=0,h=3} }
local function worker()
  if runtime == "sandbox" then turtle = dofile("turtle.lua").new(world) _G.turtle=turtle end
  local store = A.mount("/"):open("test.pose",function(v) return type(v) == "table" and S.pose(v.pose) end,{class="bulk",limit=900000})
  local state = store.value or {pose=starts[id],stage="new"}
  local p = state.pose
  local before={x=p.x,y=p.y,z=p.z}
  timeline=state.timeline or {}
  if runtime=="sandbox" then
    local observed=world("pose")
    p.x,p.y,p.z,p.h=observed[1],observed[2],observed[3],observed[4]
  else
    local x,y,z
    for _=1,30 do
      x,y,z=gps.locate(2)
      if x then break end
      sleep(.5)
    end
    assert(x,"real turtle GPS observation missing")
    p.x,p.y,p.z=math.floor(x+.5),math.floor(y+.5),math.floor(z+.5)
  end
  local synced,why
  for _=1,30 do
    synced,why=client.resync(p)
    if synced then break end
    sleep(1)
  end
  assert(synced,why)
  if before.x~=p.x or before.y~=p.y or before.z~=p.z then
    timeline[#timeline+1]={x=p.x,y=p.y,z=p.z,at=os.epoch("utc"),method="observed after crash"}
    state.timeline=timeline
    assert(store:save(state))
  end
  if state.stage == "new" then
    if id == 1 and not state.preflight then
      test("failed physical move reconciles without consuming fuel",function()
        local fuel=turtle.getFuelLevel()
        local to={dim=p.dim,x=p.x+1,y=p.y,z=p.z}
        local ok=client.move(p,to,function()
          assert(not client.resync(p))
          assert(not client.move(p,to,function() error("overlapping move") end))
          return turtle.forward()
        end)
        assert(not ok and turtle.getFuelLevel()==fuel)
        assert(turtle.detect())
        local found,block=turtle.inspect() assert(found and block.name=="minecraft:stone")
        assert(turtle.dig() and not turtle.detect())
        assert(turtle.turnLeft())
        assert(turtle.detect())
        assert(turtle.dig())
        assert(turtle.turnRight())
      end)
      state.preflight=true assert(store:save(state))
    end
    if not state.go then
      waitMessage("go",4,nil,function() rednet.send(4,{kind="ready"},"ssot_test") end)
      state.go=true assert(store:save(state))
    end
    local function move(to)
      local attempts = 0
      while true do
        attempts = attempts+1 assert(attempts < 400,"reservation did not converge")
        local ok,why = client.move(p,to,function()
          local method
          if to.y > p.y then method="up" elseif to.y < p.y then method="down"
          else
            local h = to.x > p.x and 1 or (to.x < p.x and 3 or (to.z > p.z and 2 or 0))
            if h == (p.h+2)%4 then method="back"
            else
              while p.h ~= h do assert(turtle.turnRight()) p.h=(p.h+1)%4 end
              method="forward"
            end
          end
          if id==1 and not state.crashedBefore then
            state.crashedBefore=true assert(store:save(state)) os.reboot()
          end
          local crashAfter=id==1 and not state.crashedAfter
          if crashAfter then state.crashedAfter=true assert(store:save(state)) end
          local moved,err = turtle[method]()
          if moved and crashAfter then os.reboot() end
          if moved then
            p.x,p.y,p.z = to.x,to.y,to.z
            timeline[#timeline+1] = {x=p.x,y=p.y,z=p.z,at=os.epoch("utc"),method=method}
            state.timeline=timeline
            assert(store:save(state))
          else error("physical move failure: " .. tostring(err)) end
          return moved,err
        end)
        if ok then return end
        assert(why == "occupied" or why == "already reserved",tostring(why))
        sleep(.03+id*.02)
      end
    end
    local navRuntime
    if navigation then
      local nav
      nav=dofile("nav.lua").open({path="nav.state",pose=p,
        bounds={min={dim=p.dim,x=-32,y=64,z=-32},max={dim=p.dim,x=32,y=69,z=32}},client=client,
        observe=function()
          if runtime=="sandbox" then
            local v=world("pose") return {dim=p.dim,x=v[1],y=v[2],z=v[3]}
          end
          local x,y,z=gps.locate(2)
          if x then return {dim=p.dim,x=math.floor(x+.5),y=math.floor(y+.5),z=math.floor(z+.5)} end
        end,
        checkpoint=function(point)
          if point=="move-observed" then
            local q=nav.pose()
            if q.x~=p.x or q.y~=p.y or q.z~=p.z then
              p.x,p.y,p.z,p.h=q.x,q.y,q.z,q.h
              timeline[#timeline+1]={x=p.x,y=p.y,z=p.z,at=os.epoch("utc"),method="nav"}
              state.timeline=timeline assert(store:save(state))
            end
          end
          if id==1 and point=="move-started" and not state.navBefore then
            state.navBefore=true assert(store:save(state)) os.reboot()
          end
          if id==1 and point=="move-physical" and not state.navAfter then
            state.navAfter=true assert(store:save(state)) os.reboot()
          end
        end})
      navRuntime=nav
      assert(nav.recover())
      local observed=nav.pose() p.x,p.y,p.z,p.h=observed.x,observed.y,observed.z,observed.h
      move=function(to)
        for _=1,100 do
                    local ok,why=nav.go(to,"explore")
          local q=nav.pose() p.x,p.y,p.z,p.h=q.x,q.y,q.z,q.h
          if ok then
            state.timeline=timeline assert(store:save(state)) return
          end

          assert(why=="search budget" or why=="no route" or why=="replan budget" or why=="occupied" or why=="already reserved",tostring(why))
          sleep(.1+id*.03)
        end
        error("bounded navigation contention exhausted")
      end
    end
    local initial=starts[id]
    local dx,dz = -initial.x/2,-initial.z/2
    local route={{x=initial.x+dx,y=65,z=initial.z+dz},{x=0,y=65,z=0},{x=0,y=66,z=0},
      {x=-dx,y=66,z=-dz},{x=-2*dx,y=66,z=-2*dz}}
    if id==1 then
      table.insert(route,1,{x=initial.x,y=65,z=initial.z})
      table.insert(route,1,{x=initial.x,y=66,z=initial.z})
    end
    for i=state.nextStep or 1,#route do
      local to=route[i] to.dim=p.dim
      if p.x~=to.x or p.y~=to.y or p.z~=to.z then move(to) end
      state.nextStep=i+1 assert(store:save(state))
    end
    if navigation and id==3 and not state.maze then
      if runtime=="minecraft" then
        writeJSON("nav-fixture-ready.json",{ok=true})
        while not fs.exists("nav-fixture-installed") do sleep(.1) end
      end
      test("known-air U maze replans around a chest and returns through three dimensions",function()
        for _,v in ipairs({{2,66,0},{3,66,0},{2,66,1},{3,66,1},{4,66,1},{4,66,0},{4,67,0}}) do
          navRuntime.record({dim=p.dim,x=v[1],y=v[2],z=v[3]},"minecraft:air")
        end
        assert(not navRuntime.step(1,"excavate"))
        assert(not navRuntime.step(4,"explore"))
        assert(not navRuntime.step(0,"excavate"))
        if runtime=="minecraft" then
          writeJSON("nav-fluid-ready.json",{ok=true})
          while not fs.exists("nav-fluid-cleared") do sleep(.1) end
        else world("clear-fluid") end
        assert(navRuntime.go({dim=p.dim,x=4,y=67,z=0},"walk"))
        assert(navRuntime.go({dim=p.dim,x=2,y=66,z=0},"walk"))
        assert(navRuntime.face(1))
        local found,info=turtle.inspect() assert(found and info.name=="minecraft:chest")
        assert(not turtle.inspectUp())
        local q=navRuntime.pose() p.x,p.y,p.z,p.h=q.x,q.y,q.z,q.h
      end)
      state.maze=true assert(store:save(state))
    end
    state.stage = "crossed" assert(store:save(state))
  end
  send(4,{kind="crossed",pose=p,timeline=timeline},"ssot_test")
  if id == 1 then
    if state.stage == "crossed" then
      local to = {dim=p.dim,x=p.x-1,y=p.y,z=p.z}
      local grant = assert(client.reserve({pose=p,to=to})) assert(grant.ok)
      assert(client.start({pose=p,to=to,token=grant.token,epoch=grant.epoch}).ok)
      send(4,{kind="held",token=grant.token},"ssot_test")
      waitMessage("reconcile",4)
      assert(client.resync(p))
      local second = assert(client.reserve({pose=p,to=to})) assert(second.ok)
      assert(client.start({pose=p,to=to,token=second.token,epoch=second.epoch}).ok)
      state.stage="full" assert(store:save(state))
      send(4,{kind="full-held"},"ssot_test")
      waitMessage("never",4,navigation and 1800 or 600)
    else assert(state.stage == "full") assert(client.resync(p)) end
  end
  writeJSON("sandbox-result.json",{ok=true,booted=true,errors={},lines={"crossing and reboot pose verified"},pose=p,timeline=timeline})
  send(4,{kind="finished",pose=p},"ssot_test")
  while true do
    local m = waitMessage("poll",4,navigation and 1800 or 600)
    if m then send(4,{kind="finished",pose=p},"ssot_test") end
  end
end
local function controller()
  local phase = A.mount("/"):open("test.phase",function(v) return type(v) == "table" and type(v.stage) == "string" end,{class="bulk",limit=900000})
  local current = phase.value or {stage="new"}
  if fs.exists("transport-probe") then
    local h=assert(fs.open("transport-probe","r")) local mode=h.readAll() h.close()
    assert(mode=="ordinary-overworld" or mode=="ordinary-nether")
    local reply=client.snapshot({chunk="test:lab|0|4|0"})
    writeJSON("transport-" .. mode .. ".json",{ok=true,mode=mode,replyReceived=reply and reply.ok==true or false})
    while true do os.pullEvent() end
  end
  if current.stage == "new" then
    if runtime == "sandbox" then
      if navigation then
        dofile("nav-checks.lua")(test,nil,dofile("nav-fixture.lua")(nil,dofile("mocks.lua")))
        dofile("miner-nav-checks.lua")(test,function(path)
          local h=assert(fs.open(path,"r")) local text=h.readAll() h.close() return text
        end,dofile("mocks.lua"))
      end
      dofile("ssot-checks.lua")(S,A,test)
      dofile("ssot-client-checks.lua")(test,dofile("ssot-client.lua"))
      dofile("ssot-storage.lua")(A,test)
      dofile("miner-ssot-checks.lua")(test,function(path)
        local h=assert(fs.open(path,"r")) local text=h.readAll() h.close() return text
      end,dofile("mocks.lua"))
    end
    if navigation then
      local available
      for _=1,30 do
        available=client.snapshot({chunk="minecraft:overworld|0|4|0"})
        if available and available.ok then break end
        sleep(.1)
      end
      assert(available and available.ok,"server did not finish startup")
      test("server ESTOP cancels an older queued go command over the real modem",function()
        send(0,{type="command",target=id,protocol="minearmy",message={type="go"}},"fleetserver")
        sleep(.2)
        send(0,{type="command",target=id,protocol="minearmy",message={type="estop"}},"fleetserver")
        local deadline=os.clock()+10
        repeat sleep(.05) until (controls.estop or 0)>=2 or os.clock()>=deadline
        assert(controls.go==1 and (controls.estop or 0)>=2,"queued go survived ESTOP")
      end)
    end
    for peer=1,3 do waitMessage("ready",peer) end
    duplicate=true
    for peer=1,3 do send(peer,{kind="go"},"ssot_test") end
    for peer=1,3 do waitMessage("crossed",peer) end
    waitMessage("held",1)
    send(0,{action="reboot"},"ssot_test")
    sleep(4)
    test(runtime=="sandbox" and "server program restart keeps the map service reachable" or "server computer reboot keeps the map service reachable",function()
      local r = client.snapshot({chunk="minecraft:overworld|0|4|0"}) assert(r and r.ok)
    end)
    send(1,{kind="reconcile"},"ssot_test")
    waitMessage("full-held",1)
    local p = {dim="test:lab",x=0,y=64,z=0}
    assert(client.resync(p))
    test("timeout never calls a physical movement",function()
      drop=true
      local moved=0
      local ok = client.move(p,{dim=p.dim,x=1,y=64,z=0},function() moved=moved+1 return true end)
      drop=false
      assert(not ok and moved == 0)
      assert(client.resync(p))
    end)
    test("late commit is rejected and started occupancy requires reconciliation",function()
      local to = {dim=p.dim,x=1,y=64,z=0}
      local g = client.reserve({pose=p,to=to}) assert(g and g.ok)
      local f = {pose=p,to=to,token=g.token,epoch=g.epoch}
      local renewed=client.renew(f) assert(renewed and renewed.ok)
      assert(client.start(f).ok)
      sleep(math.max(0,(renewed.untilAt-os.epoch("utc"))/1000)+.2)
      assert(not client.commit(f).ok)
      assert(not client.release(f).ok)
      assert(client.resync(p))
    end)
    test("malformed, oversize and unpaired clients leave the server responsive",function()
      send(0,{type="ssot"},"fleetserver")
      send(0,{type="ssot",rid="bad",cells=string.rep("x",9000)},"fleetserver")
      local r = client.snapshot({chunk="test:lab|0|4|0"}) assert(r and r.ok)
    end)
    local revision,chunkRevision=0,nil
    local metrics={}
    test("10000 sparse observations persist and snapshots stay within 8 KiB",function()
      local first,startedAt=0,os.epoch("utc")
      while first<10000 do
        local cells={}
        local last=math.min(first+63,first<1000 and 999 or 9999)
        for i=first,last do
          cells[#cells+1]={dim=p.dim,x=i%32,y=64+math.floor(i/1024),z=math.floor(i/32)%32,name=false}
        end
        local r,err=client.scan({pose=p,revision=revision,cells=cells}) assert(r and r.ok,tostring(err))
        revision=r.revision
        if last==999 or last==9999 then
          local sample=readMetrics()
          writeJSON("metrics-last.json",sample)
          assert(sample.cells==last+1 and sample.capacity==4000000)
          sample.elapsedMs=os.epoch("utc")-startedAt
          metrics[#metrics+1]=sample
          writeJSON("metrics.json",metrics)
        end
        first=last+1
        sleep(.05)
      end
      local cursor,n=0,0
      repeat
        local r,err=client.snapshot({chunk="test:lab|0|4|0",cursor=cursor}) assert(r and r.ok,tostring(err or (r and r.error)))
        chunkRevision=r.revision
        assert(#textutils.serialize(r,{compact=true})<=8192)
        cursor,n=r.cursor,n+#r.cells
        sleep(.05)
      until cursor==0
      assert(n==2560,"missing snapshot cells: " .. n)
    end)
    test("resident chunk limit rejects a ninth chunk without evicting observations",function()
      for _,point in ipairs({{-1,0},{-1,-1},{0,-1},{-32,0}}) do
        local r=client.scan({pose=p,revision=revision,cells={{dim=p.dim,x=point[1],y=64,z=point[2],name=false}}})
        assert(r and r.ok) revision=r.revision
      end
      local r=client.scan({pose=p,revision=revision,cells={{dim=p.dim,x=-32,y=64,z=-1,name=false}}})
      assert(r and not r.ok and r.error=="resident chunk limit")
      local sample=readMetrics()
      assert(sample.chunks==8 and sample.cells==10004)
      local solid=client.scan({pose=p,revision=revision,cells={{dim=p.dim,x=-32,y=64,z=0,name="minecraft:stone"}}})
      assert(solid and solid.ok) revision=solid.revision
      local page=client.snapshot({chunk="test:lab|-2|4|0"})
      assert(page and page.ok and #page.cells==1 and page.cells[1][2]=="minecraft:stone")
      metrics[#metrics+1]=sample
      writeJSON("metrics.json",metrics)
    end)
    test("real server disk fill refuses mutations and preserves the acknowledged map",function()
      send(0,{action="fill"},"ssot_test")
      local filled=waitMessage("filled",0)
      assert(filled.free<=16384)
      local r=client.scan({pose=p,revision=revision,cells={{dim=p.dim,x=0,y=64,z=0,name="minecraft:stone"}}})
      assert(r == nil or r.ok == false, "disk-full mutation was acknowledged")
      send(0,{action="clear-and-reboot"},"ssot_test")
      local page
      for _=1,30 do
        page=client.snapshot({chunk="test:lab|0|4|0"})
        if page and page.ok then break end
        sleep(1)
      end
      assert(page and page.ok and page.revision==chunkRevision and page.cells[1][2]==false)
    end)
    current={stage="after-full",checks=checks,revision=revision}
    assert(phase:save(current))
    writeJSON("restart-ready.json",{ok=true,revision=revision})
    waitMessage("never",0,600)
  end
  checks=current.checks or checks
  for peer=1,3 do send(peer,{kind="poll"},"ssot_test") end
  for peer=1,3 do waitMessage("finished",peer) end
  local r=client.snapshot({chunk="test:lab|0|4|0"}) assert(r and r.ok and #r.cells>0)
  send(0,{action="done"},"ssot_test")
  if runtime == "sandbox" then send(5,{op="done",args={},rid="done"},"ssot_world") end
  writeJSON("sandbox-result.json",{ok=true,booted=true,errors={},lines={"all SSOT assertions passed"},checks=checks,revision=current.revision})
  while true do os.pullEvent() end
end
local ok,err=pcall(parallel.waitForAny,receive,id==4 and controller or worker)
if not ok and err=="ssot sandbox restart" then return "restart" end
if not ok then
  writeJSON("sandbox-result.json",{ok=false,booted=true,errors={tostring(err)},lines={},checks=checks})
  error(err,0)
end
