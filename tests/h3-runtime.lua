local runtime = ...
local id, controller = os.getComputerID(), 5
local A = dofile("atomic.lua")
local cfg = assert(A.read("h3.cfg"))
local function now() return os.epoch("utc") end
local function json(path, value)
  local temporary = path .. ".tmp"
  local h = assert(fs.open(temporary, "w")) h.write(textutils.serializeJSON(value)) h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(temporary,path)
end
local function append(path, value)
  local h = assert(fs.open(path, "a")) h.writeLine(textutils.serializeJSON(value)) h.close()
end
local function report(ok, err, extra)
  local r = extra or {}
  r.ok, r.booted, r.free, r.capacity = ok, true, fs.getFreeSpace("/"), fs.getCapacity("/")
  r.errors = err and {tostring(err)} or textutils.empty_json_array
  r.lines = {"H3 " .. runtime .. " computer " .. id}
  json("sandbox-result.json", r)
end
local function control(to, m) rednet.send(to, m, "h3_control") end
local function broadcast(m)
  for peer = 1, 5 do control(peer, m) end
end
local function forever() while true do os.pullEvent() end end
local function trace(value)
  return debug and debug.traceback and debug.traceback(tostring(value),2) or tostring(value)
end
local function guard(fn)
  return function()
    local ok,err=xpcall(fn,trace)
    if not ok then error(err,0) end
  end
end
local function server()
  local bootStore = A.store("h3.boot", function(v) return type(v) == "number" end)
  local boot = (bootStore.value or 0) + 1 assert(bootStore.save(boot))
  local metricStore = A.store("h3.metrics", function(v) return type(v) == "table" end)
  local metrics = metricStore.value or {saves=0, maxSaveMs=0, samples={}, windows={}, withheld=0}
  local savePhase, httpArmed, flight, stop = nil, false, nil, false
  local nextSample, nativeGet, nativeSend = 0, assert(http.get), rednet.send
  local function sample(force)
    if not force and now() < nextSample then return end
    nextSample = now() + cfg.sampleSeconds * 1000
    local s = assert(assert(A.read("ssot.state")).value)
    local row = {at=now(), boot=boot, saves=metrics.saves, lastSaveMs=metrics.lastSaveMs,
      maxSaveMs=metrics.maxSaveMs, stateBytes=fs.getSize("ssot.state"), revision=s.rev,
      capacity=fs.getCapacity("/"), free=fs.getFreeSpace("/")}
    append("h3-save-samples.jsonl", row)
    metrics.samples[#metrics.samples+1] = row
    if #metrics.samples > 180 then table.remove(metrics.samples, 1) end
    assert(metricStore.save(metrics))
  end
  local env = setmetatable({}, {__index=_ENV})
  env._G = env
  env.dofile = function(path)
    local lib = assert(loadfile(path, "t", env))()
    if path == "atomic.lua" then
      local store = lib.store
      lib.store = function(path, ...)
        local out = store(path, ...)
        if path == "ssot.state" then
          local save = out.save
          out.save = function(value)
            local start = now()
            local ok, err = save(value)
            local finish = now()
            local elapsed = finish-start
            metrics.saves, metrics.lastSaveMs = metrics.saves+1, elapsed
            metrics.maxSaveMs = math.max(metrics.maxSaveMs, elapsed)
            if savePhase then
              local window={phase=savePhase,start=start,finish=finish,actualSaveMs=elapsed,
                actualSave=true,injectedDelayMs=0,ok=ok}
              local phase=metrics.windows[savePhase]
              phase.windows[#phase.windows+1]=window
              append("h3-windows.jsonl", window)
            end
            if ok then sample(false) end
            return ok, err
          end
        end
        return out
      end
    end
    return lib
  end
  env.http = setmetatable({}, {__index=http})
  env.http.get = function(url, ...)
    local name = type(url) == "string" and url:match("/([^/?]+)%?t=")
    assert(name, "unexpected server HTTP URL")
    if name == "buddy.lua" and not httpArmed then return nil, "H3 waits for the HTTP phase" end
    local delayed = name == "buddy.lua" and httpArmed
    local token = tostring(boot) .. "-" .. tostring(now()) .. "-" .. name
    local endpoint = cfg.httpBase .. "/asset/" .. name .. "?token=" .. token
    if delayed then
      httpArmed = false
      flight = {token=token, start=now(), url=endpoint, actualHTTP=true, activeConfirmed=false}
      endpoint = endpoint .. "&delay=" .. cfg.httpDelaySeconds
    end
    local response, err = nativeGet(endpoint, ...)
    if delayed then
      flight.finish, flight.success = now(), response ~= nil
      metrics.windows.http = flight
      append("h3-windows.jsonl", flight)
      assert(metricStore.save(metrics))
      control(controller, {kind="http-finished", window=flight})
      flight = nil
    end
    return response, err
  end
  env.rednet = setmetatable({}, {__index=rednet})
  env.rednet.send = function(to, packet, proto)
    if proto == "fleetserver" and type(packet) == "table" and packet.type == "ssot_reply"
      and packet.rid:find(":restart:", 1, true) and boot == 1 then
      metrics.withheld = metrics.withheld + 1
      if metrics.withheld == 4 then
        sample(true)
        json("restart-ready.json", {ok=true, withheld=4, at=now(), boot=boot})
        control(controller, {kind="restart-ready"})
        while true do sleep(1) end
      end
      return true
    end
    return nativeSend(to, packet, proto)
  end
  parallel.waitForAny(guard(function()
    assert(loadfile("server.lua", "t", env))()
    error("server.lua returned")
  end), guard(function()
    while true do
      local from, m = rednet.receive("h3_control")
      if from == controller and type(m) == "table" then
        if m.kind == "arm-save" then
          savePhase=m.phase metrics.windows[savePhase]={windows={},actualSave=true,injectedDelayMs=0}
          broadcast({kind="wave",phase=savePhase})
          control(controller,{kind="armed",phase=m.phase})
        elseif m.kind == "arm-http" then httpArmed=true control(controller,{kind="http-armed"})
        elseif m.kind == "release-restart" then broadcast({kind="wave",phase="restart"})
        elseif m.kind == "metrics" or m.kind == "finish" then
          savePhase=nil
          sample(true)
          local state = assert(assert(A.read("ssot.state")).value)
          control(controller, {kind="metrics", boot=boot, metrics=metrics, revision=state.rev,
            capacity=fs.getCapacity("/"), free=fs.getFreeSpace("/"), bytes=fs.getSize("ssot.state")})
          if m.kind == "finish" then report(true, nil, {metrics=metrics, revision=state.rev}) stop=true end
        end
      end
    end
  end), guard(function()
    while true do
      if flight and not flight.activeConfirmed then
        local response = nativeGet(cfg.httpBase .. "/status?token=" .. flight.token)
        assert(response, "cannot confirm HTTP in flight")
        local status = textutils.unserializeJSON(response.readAll()) response.close()
        if status.active and flight and not flight.activeConfirmed then
          flight.activeConfirmed, flight.confirmedAt = true, now()
          broadcast({kind="wave", phase="http"})
        end
      end
      if stop then forever() end
      sleep(.05)
    end
  end))
end
local inbox, replies, ready = {}, {}, {}
local commands = {}
local function receiver()
  while true do
    local from, m, proto = rednet.receive()
    if type(m) == "table" then
      if proto == "h3_control" then
        if m.kind == "ready" then ready[from]=m else inbox[#inbox+1]={from=from,m=m} end
      elseif proto == "fleetserver" and from == 0 and m.type == "ssot_reply" then
        assert(m.server == 0 and m.auth == cfg.secret, "unauthenticated reply")
        replies[m.rid] = m
      elseif proto == "fleetserver" and from == 0 and m.type == "file" then
        inbox[#inbox+1]={from=from,m={kind="file",packet=m}}
      elseif proto == "minearmy" and from == 0 and m.type == "go" and id == 1 then
        local key = tostring(m.commandEpoch) .. ":" .. m.cid
        local c = commands[key] or {times={}} commands[key] = c
        c.times[#c.times+1] = now()
        control(controller,{kind="command", key=key, phase=m.h3Cycle, times=c.times})
        if #c.times >= 3 then rednet.send(0,{type="cmd_ack",cid=m.cid,commandEpoch=m.commandEpoch},"minearmy") end
      end
    end
  end
end
local function wait(kind, from, timeout, retry, phase)
  local deadline, nextRetry = now()+(timeout or cfg.timeoutSeconds)*1000, 0
  repeat
    if kind == "ready" and from and ready[from] then
      local message=ready[from] ready[from]=nil return message
    end
    for i, entry in ipairs(inbox) do
      if entry.m.kind == kind and (not from or entry.from == from)
        and (not phase or entry.m.phase == phase) then
        table.remove(inbox, i) return entry.m
      end
    end
    if retry and now() >= nextRetry then retry() nextRetry=now()+1000 end
    sleep(.02)
  until now() >= deadline
  error("timeout waiting for " .. kind .. " from " .. tostring(from) .. " phase " .. tostring(phase))
end
local function worker()
  assert(turtle, "H3 requires four turtles")
  local store = A.store("h3.client", function(v) return type(v) == "table" and type(v.counter) == "number" end)
  local state = store.value or {counter=0, revision=0, mutations=0, completed={}, batches=0, turns=0}
  local pose = cfg.poses[id]
  local function save() assert(store.save(state)) end
  local function packet(op, phase, fields)
    state.counter = state.counter+1
    local m = {v=1,type="ssot",expect="ssot_reply",op=op,boot="h3-turtle-" .. id,
      counter=state.counter,rid="h3:" .. id .. ":" .. phase .. ":" .. state.counter,secret=cfg.secret}
    for k,v in pairs(fields or {}) do m[k]=v end
    return m
  end
  local function runPending()
    local batch, sent, times, attempts = assert(state.pending), {}, {}, {}
    local deadline = now()+cfg.timeoutSeconds*1000
    while true do
      local all = true
      for _,m in ipairs(batch.packets) do
        local r = replies[m.rid]
        if r then
          assert(r.ok, m.rid .. " " .. tostring(r.error))
          state.revision = math.max(state.revision, r.revision or 0)
        else
          all = false
          if not sent[m.rid] or now()-sent[m.rid] >= cfg.retrySeconds*1000 then
            sent[m.rid] = now()
            times[#times+1]={rid=m.rid,at=sent[m.rid],retry=attempts[m.rid] or 0}
            attempts[m.rid]=(attempts[m.rid] or 0)+1
            rednet.send(0,m,"fleetserver")
            if batch.phase:match("^save%-") then sleep(.02*id) end
          end
        end
      end
      if all then break end
      assert(now()<deadline,"missing H3 reply")
      sleep(.02)
    end
    local summary={phase=batch.phase, sent=times, count=#batch.packets, mutations=state.mutations,
      revision=state.revision, retries=0}
    for _,n in pairs(attempts) do summary.retries=summary.retries+n-1 end
    for _,m in ipairs(batch.packets) do replies[m.rid]=nil end
    if batch.phase ~= "sync" then
      state.mutations=state.mutations+#batch.packets state.batches=state.batches+1
      assert(turtle.turnRight()) state.turns=state.turns+1
    end
    summary.mutations, summary.turns, summary.batches=state.mutations,state.turns,state.batches
    state.pending=nil
    if not batch.phase:match("^soak") and not batch.phase:match("^seed") then state.completed[batch.phase]=summary end
    save()
    append("h3-batches.jsonl",summary)
    return summary
  end
  local function prepare(phase, count)
    local packets={}
    for slot=0,(count or 4)-1 do
      local cells={}
      local row=state.batches%4
      for n=0,15 do cells[#cells+1]={dim=pose.dim,x=-16+(slot%2)*16+n%4,
        y=32+id*16,z=math.floor(slot/2)*16+row*4+math.floor(n/4),
        name=state.batches%2==0 and "minecraft:stone" or false} end
      packets[#packets+1]=packet("scan",phase,{pose=pose,revision=state.revision,cells=cells})
    end
    state.pending={phase=phase,packets=packets} save()
  end
  if state.pending then runPending() end
  if not state.synced then
    state.pending={phase="sync",packets={packet("sync","sync",{pose=pose})}} save()
    runPending() state.synced=true save()
  end
  while true do
    local m = wait("task",controller,math.max(cfg.seconds+600,1800),function()
      control(controller,{kind="ready",pending=state.pending and state.pending.phase,completed=state.completed})
    end)
    if m.phase == "finish" then
      report(true,nil,{mutations=state.mutations,batches=state.batches,turns=state.turns})
      control(controller,{kind="done",phase="finish",mutations=state.mutations,turns=state.turns})
    elseif state.completed[m.phase] then control(controller,{kind="done",phase=m.phase,summary=state.completed[m.phase]})
    else
      prepare(m.phase)
      control(controller,{kind="prepared",phase=m.phase})
      if m.wave then wait("wave",0,nil,nil,m.phase) end
      local summary=runPending()
      control(controller,{kind="done",phase=m.phase,summary=summary})
      rednet.send(0,{type="status",label="H3 turtle " .. id,phase=m.phase,x=pose.x,y=pose.y,z=pose.z,
        fuel=turtle.getFuelLevel(),free=16},"minearmy")
    end
  end
end
local function coordinator()
  local store=A.store("h3.coordinator",function(v) return type(v)=="table" end)
  local state=store.value or {stage="seed",batches={},startedAt=now()}
  local function save() assert(store.save(state)) end
  local function peersTask(phase,wave)
    for peer=1,4 do control(peer,{kind="task",phase=phase,wave=wave}) end
  end
  local function gather(phase)
    local rows={}
    for peer=1,4 do rows[peer]=wait("done",peer,nil,nil,phase).summary end
    return rows
  end
  local function metrics()
    control(0,{kind="metrics"}) return wait("metrics",0)
  end
  local function commandCycle(phase, alreadySent)
    if not alreadySent then
      rednet.send(0,{type="command",target=1,protocol="minearmy",message={type="go",h3Cycle=phase}},"fleetserver")
    end
    local deadline=now()+20000
    repeat
      local m=wait("command",1,20,nil,phase)
      if #m.times>=3 then
        assert(m.times[2]-m.times[1]>=2500 and m.times[3]-m.times[2]>=2500,"command retries did not use the server timer")
        append("h3-timers.jsonl",m)
        return m
      end
    until now()>=deadline
    error("server command retry timer stopped")
  end
  for peer=1,4 do wait("ready",peer) end
  if state.stage=="seed" then
    for batch=1,cfg.seedBatches do peersTask("seed-" .. batch) gather("seed-" .. batch) end
    state.timerBefore=commandCycle("before-save")
    state.stage="save" save()
  end
  if state.stage=="save" then
    local overlap=false
    for attempt=1,12 do
      local phase="save-" .. attempt
      peersTask(phase,true)
      for peer=1,4 do wait("prepared",peer,nil,nil,phase) end
      control(0,{kind="arm-save",phase=phase}) wait("armed",0,nil,nil,phase)
      rednet.send(0,{v=1,type="ssot",expect="ssot_reply",op="snapshot",boot="h3-controller",counter=attempt,
        rid="h3-controller-" .. attempt,secret=cfg.secret,chunk="minecraft:overworld|0|4|0"},"fleetserver")
      local rows=gather(phase)
      local met=metrics()
      local w=assert(met.metrics.windows[phase])
      local n=0
      for _,row in ipairs(rows) do
        assert(row.retries==0,"save burst needed retries")
        for _,tx in ipairs(row.sent) do
          for _,window in ipairs(w.windows) do
            if tx.at>=window.start and tx.at<window.finish then n=n+1 break end
          end
        end
      end
      state.batches[phase]={rows=rows,window=w,overlapRequests=n}
      if n>0 then overlap=true break end
    end
    assert(overlap,"no request was sent during an actual SSOT save")
    state.stage="http" save()
  end
  if state.stage=="http" then
    peersTask("http",true)
    for peer=1,4 do wait("prepared",peer,nil,nil,"http") end
    control(0,{kind="arm-http"}) wait("http-armed",0)
    rednet.send(0,{type="command",target=1,protocol="minearmy",message={type="go",h3Cycle="during-http"}},"fleetserver")
    rednet.send(0,{type="get",file="buddy.lua",offset=0,rid="h3-http-trigger"},"fleetserver")
    local rows=gather("http")
    local w=wait("http-finished",0).window
    local fileReply=wait("file",0).packet
    local source=assert(fs.open("buddy.lua","r")) local bytes=source.readAll() source.close()
    assert(fileReply.rid=="h3-http-trigger" and fileReply.file=="buddy.lua" and not fileReply.error
      and fileReply.size==#bytes and fileReply.code==bytes:sub(1,12000),"HTTP file request lost or changed its reply")
    assert(w.success and w.activeConfirmed and w.finish-w.start>=cfg.httpDelaySeconds*1000,"HTTP was not in flight")
    local n=0
    for _,row in ipairs(rows) do
      assert(row.retries==0,"HTTP burst needed retries")
      for _,tx in ipairs(row.sent) do if tx.at>=w.confirmedAt and tx.at<w.finish then n=n+1 end end
    end
    assert(n==16,"HTTP burst did not overlap the active request")
    state.batches.http={rows=rows,window=w,overlapRequests=n}
    state.timerDuringHTTP=commandCycle("during-http",true)
    assert(state.timerDuringHTTP.times[2]>=w.confirmedAt and state.timerDuringHTTP.times[2]<w.finish,
      "server did not retry a command while HTTP was in flight")
    state.timerAfterHTTP=commandCycle("after-http")
    state.stage="restart" save()
    peersTask("restart",true)
    for peer=1,4 do wait("prepared",peer,nil,nil,"restart") end
    control(0,{kind="release-restart"})
    wait("restart-ready",0)
    forever()
  end
  if state.stage=="restart" then
    peersTask("restart")
    local rows=gather("restart")
    local met=metrics()
    assert(met.boot>=2 and met.metrics.withheld==4,"full runtime restart did not occur")
    state.batches.restart={rows=rows,boot=met.boot,withheld=met.metrics.withheld}
    state.timerAfterRestart=commandCycle("after-restart")
    state.stage="soak" state.soakStarted=now() save()
  end
  if state.stage=="soak" then
    local batch,nextTimer=0,now()+300000
    while now()-state.soakStarted<cfg.seconds*1000 do
      batch=batch+1
      peersTask("soak-" .. batch) gather("soak-" .. batch)
      if batch%10==0 then
        local met=metrics()
        append("h3-soak.jsonl",{at=now(),elapsedMs=now()-state.soakStarted,revision=met.revision,
          stateBytes=met.bytes,lastSaveMs=met.metrics.lastSaveMs,capacity=met.capacity,free=met.free})
      end
      if now()>=nextTimer then
        commandCycle("soak-timer-" .. batch)
        state.soakTimerChecks=(state.soakTimerChecks or 0)+1
        nextTimer=now()+300000
      end
      sleep(cfg.intervalSeconds)
    end
    state.soakElapsedMs=now()-state.soakStarted state.soakBatches=batch
    state.stage="finish" save()
  end
  peersTask("finish")
  local total,turns=0,0
  for peer=1,4 do local r=wait("done",peer,nil,nil,"finish") total=total+r.mutations turns=turns+r.turns end
  local met=metrics()
  assert(met.revision==total,"duplicate or missing scan mutation after retry and restart")
  assert(met.capacity==cfg.spaceLimit and met.free>=8192,"disk limit failed")
  state.final={ok=true,scenario="h3",runtime=runtime,mutations=total,revision=met.revision,turns=turns,
    turtles=4,soakElapsedMs=state.soakElapsedMs,soakBatches=state.soakBatches,
    fullSoak=state.soakElapsedMs>=7200000,developmentRun=cfg.seconds<7200,
    gateEligible=state.soakElapsedMs>=7200000,metrics=met,batches=state.batches,
    timerBefore=state.timerBefore,timerDuringHTTP=state.timerDuringHTTP,timerAfterHTTP=state.timerAfterHTTP,
    timerAfterRestart=state.timerAfterRestart,soakTimerChecks=state.soakTimerChecks or 0}
  json("h3-summary.json",state.final)
  control(0,{kind="finish"})
  report(true,nil,{summary=state.final})
  forever()
end
local ok,err=xpcall(function()
  assert(fs.getCapacity("/")==cfg.spaceLimit,"wrong computer disk capacity")
  if id==0 then server()
  else parallel.waitForAny(guard(receiver),guard(id==controller and coordinator or worker)) end
end,trace)
if not ok then report(false,err) error(err,0) end
