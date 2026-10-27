local H = dofile("tests/so/harness.lua")

return function(test)
  local function machine()
    local net = H.new()
    local m = net.machine({id=1, directories=true})
    m.install({"so-store.lua", "so-log.lua", "so-mod-state.lua"})
    return m
  end
  local function run(m, code)
    m.spawn(code)
    assert(not m.error, m.error)
  end
  local boot = [[
    store = dofile("so-store.lua")
    box = store.store("state", function(v) return type(v.n)=="number" end)
    assert(box.save({n=1}))
  ]]

  test("space precheck changes no files and the same store retries", function()
    local m = machine()
    run(m, boot)
    local before = H.encode(m.files)
    local free = m.env.fs.getFreeSpace
    m.env.fs.getFreeSpace = function() return 0 end
    run(m, [[assert(not box.save({n=2}))]])
    assert(H.encode(m.files) == before, "precheck changed disk")
    m.env.fs.getFreeSpace = free
    run(m, [[assert(box.save({n=3})); assert(store.store("state", function() return true end).value.n==3)]])
  end)

  test("space precheck leaves recovered temporary and backup sources untouched", function()
    for _, suffix in ipairs({".tmp", ".bak"}) do
      local m = machine()
      run(m, boot)
      m.files["state" .. suffix], m.files.state = m.files.state, nil
      run(m, [[box=store.store("state", function() return true end)]])
      local before, free = H.encode(m.files), m.env.fs.getFreeSpace
      m.env.fs.getFreeSpace = function() return 0 end
      run(m, [[assert(not box.save({n=2}))]])
      assert(H.encode(m.files)==before, "precheck changed recovered source")
      m.env.fs.getFreeSpace = free
      run(m, [[assert(box.save({n=3})); assert(store.store("state", function() return true end).value.n==3)]])
    end
  end)

  test("store retries after a failure at every save mutation", function()
    local function intercept(m, hit)
      for _, op in ipairs({"open", "delete", "move"}) do
        local original = m.env.fs[op]
        m.env.fs[op] = function(...)
          local mutation = op ~= "open" or select(2, ...) == "w"
          if mutation then hit(false) end
          local result = original(...)
          if mutation then hit(true) end
          if op == "open" and select(2, ...) == "w" then
            for _, method in ipairs({"write", "close"}) do
              local call = result[method]
              result[method] = function(...)
                hit(false)
                local value = call(...)
                hit(true)
                return value
              end
            end
          end
          return result
        end
      end
    end
    local probe, total = machine(), 0
    run(probe, boot .. [[assert(box.save({n=2}))]])
    intercept(probe, function(after) if not after then total = total + 1 end end)
    run(probe, [[assert(box.save({n=3}))]])
    for cut=1,total do
      for _, after in ipairs({false,true}) do
        local m, count, fired = machine(), 0, false
        run(m, boot .. [[assert(box.save({n=2}))]])
        intercept(m, function(done)
          if not done then count = count + 1 end
          if not fired and count==cut and done==after then fired=true error("disk failure") end
        end)
        run(m, [[assert(not box.save({n=3})); assert(box.save({n=4}))
          assert(store.store("state", function() return true end).value.n==4)]])
        assert(fired)
      end
    end
  end)

  test("a partial first save retries on the same store", function()
    local m = machine()
    run(m, [[store=dofile("so-store.lua")
      box=store.store("state", function(v) return type(v.n)=="number" end)]])
    local original = m.env.fs.open
    m.env.fs.open = function(path, mode)
      local handle = original(path, mode)
      if mode=="w" then
        local write = handle.write
        handle.write = function(text) write(text:sub(1, 10)); error("disk full") end
      end
      return handle
    end
    run(m, [[assert(not box.save({n=1}))]])
    m.env.fs.open = original
    run(m, [[assert(box.save({n=2})); assert(store.store("state", function() return true end).value.n==2)]])
  end)

  test("logging resumes after nearly full disk is freed without reboot", function()
    for _, partial in ipairs({false,true}) do
      local m = machine()
      run(m, [[SO={now=function() return os.epoch("utc") end,store=dofile("so-store.lua"), mods={}}
        state=dofile("so-mod-state.lua")
        assert(state.emit("value", 1))]])
      local function used()
        local bytes = 0
        for _, text in pairs(m.files) do bytes = bytes + #text end
        return bytes
      end
      local open = m.env.fs.open
      m.capacity = used() + (partial and 12000 or 100)
      if partial then
        m.env.fs.open = function(path, mode)
          local handle = open(path, mode)
          if mode=="w" then
            m.files.ballast = string.rep("x", m.capacity - used() - 20)
          end
          return handle
        end
      end
      run(m, [[assert(state.emit("value", 2)); assert(state.get("value")==2); assert(state.disk().pending==1); assert(not state.canWork())]])
      m.files.ballast = nil
      m.capacity, m.env.fs.open = 16000000, open
      run(m, [[assert(state.emit("value", 3)); assert(state.get("value")==3)
        state.tick(); assert(state.disk().pending==0); assert(state.canWork())
        local rows=state.history.page({}).entries
        assert(#rows==3 and rows[1].data==1 and rows[2].data==2 and rows[3].data==3)
        state=dofile("so-mod-state.lua")
        assert(state.get("value")==3)
        rows=state.history.page({}).entries
        assert(#rows==3 and rows[1].seq==1 and rows[2].seq==2 and rows[3].seq==3)]])
    end
  end)

  local function server(full)
    local net = H.new()
    local m = net.machine({id=1, modem=true, directories=true})
    m.install({"so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-errors.lua",
      "so-ui.lua", "so-mod-display.lua", "so-mod-health.lua", "so-mod-lease.lua"})
    for _, name in ipairs({"x25519", "random", "blake3", "chacha20", "config", "internal/util",
      "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing"}) do
      local path = "lib/ccryptolib/" .. name .. ".lua"
      local f = assert(io.open(path)); m.files[path] = f:read("*a"); f:close()
    end
    m.files["so-server.cfg"]=H.encode({protectedAreas=false,alternateAxisOrders=false,storageDeliveries=false})
    m.files["so-keys"] = H.encode({schema=1,generation=1,value={keys={["2"]=string.rep("a",64)}}})
    m.files["so-display"] = H.encode({schema=1,generation=1,value={roles={["1"]="health",["2"]="health"}}})
    m.files["so-mod-zprobe.lua"] = [[return {name="probe",handlers={},tick=function(now)
      TICKS=(TICKS or 0)+1; assert(not LAST or now>=LAST); LAST=now
    end}]]
    if full then
      m.files.ballast = string.rep("x", m.env.fs.getFreeSpace("/")-8000)
    end
    m.boot("so-server.lua"); net.flush()
    assert(m.alive(), tostring(m.error))
    return net, m
  end

  local function picture(frame)
    local rows = {}
    for _, row in ipairs(frame.rows) do rows[#rows+1] = row.text end
    return table.concat(rows,"\n")
  end

  local function frozen(net, m, last)
    local so = m.env.SO
    net.advance(6)
    assert(m.alive(), tostring(m.error))
    assert(so.now()==last and so.clock.refused, "clock did not freeze")
    assert(m.env.TICKS>=6, "server ticks stopped")
    assert(so.health.cadence==0 and so.health.tickMs>=0, "invalid frozen tick duration")
    local display = so.mods.display
    local frame = display.screen("health").render(51,30,{})
    assert(picture(frame):find("refused",1,true), "health metric did not show refusal")
    local session = {}
    frame = display.screen("attention").render(51,30,session)
    assert(picture(frame):find("Clock frozen",1,true), "attention did not show frozen clock")
    local target
    display.screen("attention").input({session=session,id="item:clock",open=function(role) target=role end})
    assert(target=="health", "clock attention row did not open health")
    local notices = 0
    for _, line in ipairs(so.terminal.log) do
      if line:find("clock checkpoint refused",1,true) then notices=notices+1 end
      assert(not line:find("tick health failed",1,true),line)
    end
    assert(notices==1, "clock refusal should print once")
  end

  test("full disk at boot freezes time while server and screens keep running", function()
    local net, m = server(true)
    frozen(net,m,m.env.SO.health.started)
  end)

  test("failed clock checkpoint preserves leases, health frames and the tick watchdog", function()
    local net, m = server()
    local so = m.env.SO
    net.advance(1)
    so.mods.display.handlers.hello({from=2,body={role="display",w=51,h=30}})
    so.mods.display.handlers["view.sub"]({from=2,body={w=51,h=30}})
    assert(so.mods.lease.send(2,{{op="inspectDown"}},{ms=2000}))
    local last, free = so.now(), m.env.fs.getFreeSpace
    m.env.fs.getFreeSpace = function(path)
      if path=="so-data/clock" then return 0 end
      return free(path)
    end
    frozen(net,m,last)
    assert(so.mods.lease.peek(2), "standing clock expired the lease")
    local healthFrame
    for _, sent in ipairs(m.sent) do
      local wire = sent.payload
      if wire.t=="lease.batch" then assert(wire.body.ttl>=0, "negative lease duration") end
      if wire.t=="view.frame" and picture(wire.body):find("refused",1,true) then healthFrame=true end
    end
    assert(healthFrame, "subscribed display did not receive clock refusal")
    local ticks = m.env.TICKS
    m.timers = {}
    net.advance(4)
    m.env.os.queueEvent("watchdog-probe"); net.flush()
    assert(m.env.TICKS==ticks+1, "frozen clock prevented lost-timer recovery")
    m.env.fs.getFreeSpace = free
    assert(so.now()==last and not so.clock.refused, "clock did not resume at frozen time")
    net.advance(1)
    assert(so.now()==last+1000)
  end)

  test("forced stop saves errors inside the thirty second flush interval", function()
    local m = machine()
    m.install({"so-errors.lua"})
    run(m, [[store=dofile("so-store.lua"); at=100000
      errors=dofile("so-errors.lua").open(store,function() return at end)
      assert(errors.record("first")); at=at+5000
      assert(errors.record("second")); assert(errors.status().pending)
      assert(errors.record("so-server: stopped: crash",true))
      local reopened=dofile("so-errors.lua").open(store,function() return at end)
      local entries=reopened.entries()
      assert(#entries==3 and entries[1].text=="first" and entries[2].text=="second"
        and entries[3].text=="so-server: stopped: crash")
      assert(entries[2].at-entries[1].at==5000)
      assert(errors.record("fourth")); assert(errors.status().pending)
      assert(errors.flush(at,true))
      errors=dofile("so-errors.lua").open(store,function() return at end)
      assert(#errors.entries()==4)]])
  end)

  test("server forces its stop record to disk after a recent error", function()
    local net, m = server()
    local so = m.env.SO
    so.error("first")
    net.advance(5)
    so.error("second")
    assert(so.errors.status().pending)
    m.env.os.queueEvent("terminate"); net.flush()
    assert(not m.alive() and m.error, "termination did not stop server")
    local errors = m.env.dofile("so-errors.lua").open(so.store,so.now).entries()
    assert(#errors==3 and errors[1].text=="first" and errors[2].text=="second")
    assert(errors[3].text:find("so-server: stopped:",1,true), "stop record was not saved")
  end)
  test("plain config recovery orders sequences and ties primary temporary backup while preserving keys", function()
    local m=machine()
    for _, primary in ipairs({false,true}) do
      m.files.cfg=primary and H.encode({settingsSeq=2,dim="minecraft:the_nether",keep="primary"}) or nil
      m.files["cfg.tmp"]=H.encode({settingsSeq=2,dim="minecraft:the_nether",keep="tmp"})
      m.files["cfg.bak"]=H.encode({settingsSeq=2,dim="minecraft:the_nether",keep="bak"})
      run(m, [[store=dofile("so-store.lua"); value,state=store.readConfig("cfg")]])
      assert(m.env.value.keep==(primary and "primary" or "tmp"))
      assert(m.env.state.hold==not primary)
    end
    m.files.cfg=H.encode({settingsSeq=2,keep="old"})
    m.files["cfg.tmp"]=H.encode({settingsSeq=3,keep="new",settingsControl=true})
    m.files["cfg.bak"]=H.encode({settingsSeq=1})
    run(m, [[local v,s=store.readConfig("cfg"); assert(v.keep=="new" and v.settingsControl and not s.hold)
      assert(store.saveConfig("cfg",{settingsSeq=4,keep=v.keep,autoToolSwap=false}))
      v=store.readConfig("cfg"); assert(v.keep=="new" and v.autoToolSwap==false)]])
  end)
  test("plain config never treats corrupt or failed recovery as an absent config", function()
    local m=machine()
    run(m, [[store=dofile("so-store.lua"); local v,s=store.readConfig("cfg"); assert(not v and s.absent and not s.hold)]])
    m.files.cfg="broken"
    run(m, [[local v,s=store.readConfig("cfg"); assert(not v and s.hold and not s.absent)
      assert(not store.saveConfig("cfg",{}))]])
    m.files["cfg.tmp"]=H.encode({settingsSeq=1})
    local move=m.env.fs.move
    m.env.fs.move=function() error("promotion failed") end
    run(m, [[local v,s=store.readConfig("cfg"); assert(not v and s.hold)]])
    m.env.fs.move=move
    run(m, [[local v,s=store.readConfig("cfg"); assert(v.configRecovery and s.hold and not v.dim)]])
  end)
  test("failed config saves discard valid temporary edits before the next read", function()
    for _,target in ipairs({"close","backup delete","backup move","promote"}) do
      local m=machine()
      local old={dim="minecraft:the_nether",autoToolSwap=true,settingsSeq=1,keep="old"}
      m.files.cfg=H.encode(old)
      m.files["cfg.bak"]=H.encode({settingsSeq=0})
      local open,delete,move=m.env.fs.open,m.env.fs.delete,m.env.fs.move
      local failed=false
      local function fail()
        assert(not failed)
        failed=true
        error("injected save failure")
      end
      m.env.fs.open=function(path,mode)
        local h=open(path,mode)
        if target=="close" and path=="cfg.tmp" and mode=="w" then
          local close=h.close
          h.close=function() close(); if not failed then fail() end end
        end
        return h
      end
      m.env.fs.delete=function(path)
        if target=="backup delete" and path=="cfg.bak" and not failed then fail() end
        return delete(path)
      end
      m.env.fs.move=function(from,to)
        if not failed and (target=="backup move" and from=="cfg" or target=="promote" and from=="cfg.tmp") then fail() end
        return move(from,to)
      end
      run(m, [[store=dofile("so-store.lua")
        assert(not store.saveConfig("cfg",{dim="minecraft:the_end",autoToolSwap=false,settingsSeq=2,keep="new"}))]])
      assert(failed,target.." did not reach its failure")
      assert(not m.files["cfg.tmp"],target.." retained the failed edit")
      run(m, [[local v=store.readConfig("cfg")
        assert(v.dim=="minecraft:the_nether" and v.autoToolSwap and v.settingsSeq==1 and v.keep=="old")]])
    end
  end)
  test("plain config interruptions at every write close delete and move recover before any dimension read", function()
    local snapshots={}
    local probe=machine()
    probe.files.cfg=H.encode({dim="minecraft:the_nether",settingsSeq=1,keep={n=7}})
    probe.files["cfg.bak"]=H.encode({dim="minecraft:the_nether",settingsSeq=0,keep={n=7}})
    local function capture() snapshots[#snapshots+1]={cfg=probe.files.cfg,tmp=probe.files["cfg.tmp"],bak=probe.files["cfg.bak"]} end
    for _,op in ipairs({"open","delete","move"}) do
      local original=probe.env.fs[op]
      probe.env.fs[op]=function(...)
        local mutation=op~="open" or select(2,...)=="w"
        if mutation then capture() end
        local result=original(...)
        if mutation then capture() end
        if op=="open" and select(2,...)=="w" then
          for _,method in ipairs({"write","close"}) do
            local call=result[method]
            result[method]=function(...)
              capture()
              local value=call(...)
              capture()
              return value
            end
          end
        end
        return result
      end
    end
    run(probe, [[store=dofile("so-store.lua"); assert(store.saveConfig("cfg",{dim="minecraft:the_end",settingsSeq=2,keep={n=7}}))]])
    assert(#snapshots==12, "save mutation coverage changed")
    for _,snapshot in ipairs(snapshots) do
      local m=machine()
      m.files.cfg,m.files["cfg.tmp"],m.files["cfg.bak"]=snapshot.cfg,snapshot.tmp,snapshot.bak
      run(m, [[local store=dofile("so-store.lua"); local v,s=store.readConfig("cfg")
        assert(v and (v.dim=="minecraft:the_nether" or v.dim=="minecraft:the_end"))
        assert(v.keep.n==7)
        if not fs.exists("cfg") then assert(s.hold) end
        if s.hold then assert(v.configRecovery) end
        local again,state=store.readConfig("cfg")
        assert(again.dim==v.dim and state.hold==s.hold)]])
      if not snapshot.cfg then assert(m.env.textutils.unserialize(m.files.cfg).configRecovery) end
    end
  end)

  test("config recovery persists its marker and journal hold before promotion and refuses a failed hold save", function()
    local m=machine()
    m.files["cfg.tmp"]=H.encode({dim="minecraft:the_nether",settingsSeq=2})
    run(m, [[store=dofile("so-store.lua")
      local v,s=store.readConfig("cfg",function()
        assert(not fs.exists("cfg"))
        assert(store.read("cfg.tmp").configRecovery)
        return false
      end)
      assert(not v and s.hold and not fs.exists("cfg"))
      v,s=store.readConfig("cfg",function()
        assert(not fs.exists("cfg"))
        journalHeld=true
        return true
      end)
      assert(journalHeld and v.configRecovery and s.hold and fs.exists("cfg"))]])
  end)

end
