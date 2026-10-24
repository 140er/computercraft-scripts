local H = dofile("tests/so/harness.lua")

local function setup(files, config)
  local net = H.new()
  local m = net.machine({id=1, directories=true, guardServer=true})
  m.install({"so-store.lua", "so-log.lua", "so-mod-state.lua"})
  for name, data in pairs(files or {}) do m.files[name] = data end
  if config ~= nil then m.files["so-server.cfg"] = H.encode(config) end
  m.env.SO = {mods={}, now=function() return net.time end, breathe=function() end}
  local function run(code)
    m.spawn(code)
    net.flush()
    assert(not m.error, m.error)
  end
  run([[SO.store=dofile("so-store.lua"); log=dofile("so-log.lua").open(SO.store)]])
  return m, net, run
end

local function seed(run)
  run([[for i=1,2 do assert(log.append({kind="probe",data={n=i,text=string.rep("x",1000)}})) end]])
end

return function(test, equal)
  test("log perf keeps every completed append through every write crash", function()
    for _, size in ipairs({1000,7000}) do
      local probe, _, run = setup()
      seed(run)
      local function intercept(m, hit)
        for _, op in ipairs({"open", "delete", "move"}) do
          local call = m.env.fs[op]
          m.env.fs[op] = function(...)
            local mutation = op ~= "open" or select(2,...) == "w"
            if mutation then hit(false) end
            local result = call(...)
            if mutation then hit(true) end
            if op == "open" and select(2,...) == "w" then
              for _, method in ipairs({"write", "close"}) do
                local invoke = result[method]
                result[method] = function(...)
                  hit(false)
                  local out = invoke(...)
                  hit(true)
                  return out
                end
              end
            end
            return result
          end
        end
      end
      local total = 0
      intercept(probe, function(after) if not after then total=total+1 end end)
      run("assert(log.append({kind='probe',data={n=3,text=string.rep('x'," .. size .. ")}}))")
      for cut=1,total do
        for _, after in ipairs({false,true}) do
          local m, _, execute = setup()
          seed(execute)
          local n = 0
          intercept(m, function(done)
            if not done then n=n+1 end
            if n==cut and done==after then m.killed=true error("power cut") end
          end)
          m.spawn("log.append({kind='probe',data={n=3,text=string.rep('x'," .. size .. ")}})")
          assert(m.killed, "cut missed")
          local recovered = setup(m.files)
          local evs = recovered.env.log.events()
          assert(#evs>=2 and #evs<=3, "lost completed event")
          for i, ev in ipairs(evs) do equal(ev.seq,i) equal(ev.data.n,i) end
        end
      end
    end
  end)

  test("log perf recovers partial writes and accounts the selected generation", function()
    for _, suffix in ipairs({".tmp", ".bak"}) do
      local m, _, run = setup()
      seed(run)
      local path = "so-data/log/000001"
      m.files[path..suffix], m.files[path] = m.files[path], "broken"
      local bytes = #m.files[path..suffix]
      local recovered, _, execute = setup(m.files)
      equal(recovered.env.log.rawBytes(), bytes)
      local open = recovered.env.fs.open
      recovered.env.fs.open = function(name, mode)
        local h = open(name, mode)
        if name:match("%.tmp$") and mode=="w" then
          local write = h.write
          h.write = function(text) write(text:sub(1, math.floor(#text/2))) error("disk full") end
        end
        return h
      end
      execute([[assert(not log.append({kind="probe",data={n=3}}))]])
      recovered.env.fs.open = open
      execute([[assert(log.append({kind="probe",data={n=3}})); assert(log.append({kind="probe",data={n=4}}))]])
      local reboot = setup(recovered.files)
      equal(#reboot.env.log.events(),4)
      for i, ev in ipairs(reboot.env.log.events()) do equal(ev.seq,i) equal(ev.data.n,i) end
    end
  end)

  test("log perf retains schema one, large events and bounded generations", function()
    local m, _, run = setup()
    run([[for i=1,180 do assert(log.append({kind="probe",data={n=i,text=string.rep("\n\"\\",100)}})) end
      assert(log.append({kind="large",data=string.rep("x",50000)}))
      assert(not log.append({kind="oversize",data=string.rep("x",70000)}))
      assert(log.append({kind="tail"}))]])
    local segments = 0
    for path, text in pairs(m.files) do
      if path:match("^so%-data/log/") then
        assert(#text<=65536, "segment budget")
        local v = assert(load("return "..text, "=legacy", "t", {}))()
        equal(v.schema,1)
        assert(type(v.generation)=="number" and type(v.value.events)=="table")
        if path:match("%d$") then segments=segments+1 end
      end
    end
    assert(segments>3, "no rotation")
    local reboot = setup(m.files)
    equal(#reboot.env.log.events(),182)
    equal(reboot.env.log.events()[182].kind,"tail")
  end)

  test("log perf rotates a recovered legacy segment before the next append", function()
    local m, _, run = setup()
    run([[local events={}
      for i=1,90 do events[i]={seq=i,seg=1,kind="legacy",data=string.rep("x",600)} end
      assert(SO.store.store("so-data/log/000001",function(v) return type(v.events)=="table" end,65536).save({events=events}))]])
    local recovered, _, execute = setup(m.files)
    assert(recovered.env.log.rawBytes()>50000, "legacy segment not full")
    execute([[assert(log.append({kind="new"})); assert(log.events()[91].seg==2)]])
    local reboot = setup(recovered.files)
    equal(#reboot.env.log.events(),91)
  end)

  test("heartbeat coalescing defaults off for missing and malformed settings", function()
    for _, config in ipairs({{}, {state=false}, {state={coalesceHeartbeats=false}}, {state={coalesceHeartbeats="true"}}}) do
      local m, net, run = setup(nil, config)
      run([[state=dofile("so-mod-state.lua"); state.handlers.hello({from=2,body={role="worker",fuel=1000}})]])
      net.advance(60)
      run([[state.handlers.hello({from=2,body={role="worker",fuel=1000}})]])
      equal(m.env.state.diagnostics().seq,2)
    end
  end)

  test("coalesced fleet refreshes for twelve minutes with only five machine events", function()
    local m, net, run = setup(nil, {state={coalesceHeartbeats=true}})
    run([[state=dofile("so-mod-state.lua"); frames={}; sub=state.view.sub({name="fleet",notify=function(f) frames[#frames+1]=f end})]])
    for _=0,144 do
      run([[for id=2,6 do state.handlers.hello({from=id,body={role=id<=4 and "worker" or "display",fuel=1000}}) end]])
      net.advance(5)
    end
    equal(m.env.state.diagnostics().seq,5)
    equal(#m.env.state.view.get({name="fleet"}).data,5)
    equal(m.env.state.get("machines/2/seen"), net.time-5000)
    local frames=m.env.frames
    for i=2,#frames do
      assert(frames[i].rev>frames[i-1].rev, "revision reversed")
      assert(frames[i].at-frames[i-1].at>=500, "unthrottled view")
    end
    local rev = m.env.state.view().rev
    run([[assert(state.emit("probe",1))]])
    assert(m.env.state.view().rev>rev)
    equal(m.env.state.diagnostics().seq,6)
    assert(not m.waits, "handler waited")
  end)

  test("default fleet retains sixty-five machine events over twelve minutes", function()
    local m, net, run = setup()
    run([[state=dofile("so-mod-state.lua")]])
    for _=0,144 do
      run([[for id=2,6 do state.handlers.hello({from=id,body={role=id<=4 and "worker" or "display",fuel=1000}}) end]])
      net.advance(5)
    end
    equal(m.env.state.diagnostics().seq,65)
  end)

  test("coalescing records real changes and cumulative fuel under pressure", function()
    local m, _, run = setup(nil, {state={coalesceHeartbeats=true}})
    local fp="first"
    m.env.SO.pair={key=function() return fp end}
    m.env.SO.proto={sha256=function(v) return v end,hex=function(v) return v end}
    run([[state=dofile("so-mod-state.lua")
      function hello(fuel,role,journal) state.handlers.hello({from=2,body={role=role or "worker",fuel=fuel,journal=journal or "a"}}) end
      hello(1000)]])
    m.files.ballast=string.rep("x",math.floor(m.capacity*0.86))
    run([[hello(999); hello(950); hello(901)]])
    equal(m.env.state.diagnostics().seq,1)
    equal(m.env.state.get("machines/2/fuel"),901)
    run([[hello(900); hello(1000); hello(1); hello(0); hello(1); hello("unlimited"); hello(1000); hello(1000,"display"); hello(1000,"display","b")]])
    equal(m.env.state.diagnostics().seq,10)
    fp="second"
    run([[hello(1000,"display","b")]])
    equal(m.env.state.diagnostics().seq,11)
    equal(m.env.state.get("machines/2/fp"),"second")
  end)

  test("coalesced seen survives snapshots and old snapshots get boot grace", function()
    local m, net, run = setup(nil, {state={coalesceHeartbeats=true}})
    run([[state=dofile("so-mod-state.lua"); state.handlers.hello({from=2,body={role="worker"}})]])
    net.advance(720)
    run([[state.handlers.hello({from=2,body={role="worker"}})
      log=dofile("so-log.lua").open(SO.store)
      assert(log.checkpoint({values={},machines=state.get("machines"),jobs={},gameAt=SO.now()}))]])
    local saved = m.env.state.get("machines/2/seen")
    local reboot, fresh, execute = setup(m.files)
    fresh.time=net.time
    execute([[state=dofile("so-mod-state.lua")]])
    equal(reboot.env.state.get("machines/2/seen"),saved)
    fresh.advance(1000)
    execute([[state=dofile("so-mod-state.lua")]])
    equal(reboot.env.state.get("machines/2/seen"),fresh.time)
    equal(reboot.env.state.diagnostics().seq,1)
  end)

  test("coalesced cumulative fuel baseline survives a snapshot restart", function()
    local m, _, run = setup(nil, {state={coalesceHeartbeats=true}})
    run([[state=dofile("so-mod-state.lua")
      state.handlers.hello({from=2,body={role="worker",fuel=1000}})
      state.handlers.hello({from=2,body={role="worker",fuel=950}})
      log=dofile("so-log.lua").open(SO.store)
      assert(log.checkpoint({values={},machines=state.get("machines"),jobs={}}))]])
    local reboot, _, execute = setup(m.files)
    execute([[state=dofile("so-mod-state.lua")
      state.handlers.hello({from=2,body={role="worker",fuel=900}})]])
    equal(reboot.env.state.diagnostics().seq,2)
    equal(reboot.env.state.get("machines/2/fuel"),900)
  end)

  test("small segments retain the window without a checkpoint every segment", function()
    local m, _, run = setup()
    run([[checkpoints=0
      for i=1,1000 do
        assert(log.append({kind="probe",data=string.rep("x",2000)}))
        if log.due() then
          assert(log.checkpoint({values={},machines={}}))
          checkpoints=checkpoints+1
        end
        assert(log.rawBytes()<=1048576)
      end]])
    assert(m.env.checkpoints>0 and m.env.checkpoints<=20, "snapshot churn")
    local reboot = setup(m.files)
    equal(reboot.env.log.events()[#reboot.env.log.events()].seq,1000)
  end)
end
