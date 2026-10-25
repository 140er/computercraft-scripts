local H = dofile("tests/so/harness.lua")
local key = string.rep("a", 64)
local function libs(m)
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path, "rb"))
    m.files[path] = f:read("*a")
    f:close()
  end
end
local function setup(paired, serverId, config)
  local net = H.new()
  local s = net.machine({ id = serverId or 1, modem = true })
  s.install({ "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" })
  libs(s)
  s.files["so-keys"] = H.encode({schema=1,generation=1,value={keys={["2"]=key}}})
  local w = net.machine({ id = 2, modem = true, turtle = true, capacity = 1000000 })
  w.install({ "worker.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" })
  libs(w)
  if paired then w.files["so-keys"] = H.encode({schema=1,generation=1,value={keys={["1"]=key}}}) end
  w.env.read = function() w.reads = (w.reads or 0) + 1; return coroutine.yield() end
  local lookup = w.env.rednet.lookup
  w.lookups = 0
  w.env.rednet.lookup = function(...) w.lookups = w.lookups + 1; return lookup(...) end
  if config then w.files["so-worker.cfg"] = H.encode(config) end
  w.boot("worker.lua")
  return net, s, w
end
return function(test, equal)
  test("worker boot lookup 12 shows server 12 on the code row at 39x13", function()
    local n, s, w = setup(false, 12)
    w.env.term.getSize = function() return 39, 13 end
    w.env.term.write = function(text)
      local x, y = w.cx or 1, w.cy or 1
      assert(x >= 1 and x + #text - 1 <= 39, "boot row exceeds turtle width")
      assert(y >= 1 and y <= 13, "boot row exceeds turtle height")
      local row = w.screen[y] or string.rep(" ", 39)
      w.screen[y] = row:sub(1, x - 1) .. text .. row:sub(x + #text)
      w.cx = x + #text
    end
    s.boot("so-server.lua")
    n.advance(3)
    assert(w.lookups > 0, "boot did not discover the server")
    equal(w.screen[5]:gsub("%s+$", ""), "Code:  server 12")
    w.env.os.queueEvent("paste", "123456")
    n.flush()
    equal(w.screen[5]:gsub("%s+$", ""), "Code: 123456 server 12")
    w.env.os.queueEvent("paste", "-ABCDEFGHIJKLMNOPQRSTUVWXY")
    n.flush()
    equal(#w.screen[5], 39)
    assert(w.screen[5]:find(" server 12", 1, true), "long input hides server id")
    assert(not w.screen[5]:find("ABC", 1, true), "token was not masked")
    assert(w.alive(), tostring(w.error))
  end)
  test("worker repair screen re-keys with a token while install refuses", function()
    for _, serverId in ipairs({ 1, 7 }) do
      local n, s, w = setup(true)
      s.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["3"] = key } } })
      s.files["so-server.cfg"] = H.encode({ enroll = true })
      w.files["so-worker.cfg"] = H.encode({ repairServer = true, autoToolSwap = false })
      s.boot("so-server.lua")
      n.advance(3)
      if serverId ~= 1 then
        s = n.machine({ id = serverId, modem = true })
        s.install({ "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" })
        libs(s)
        s.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["3"] = key } } })
        s.files["so-server.cfg"] = H.encode({ enroll = true })
        s.boot("so-server.lua")
        n.advance(1.05)
      end
      local old = w.files["so-keys"]
      assert(s.env.SO.enroll.open(3))
      local token = s.env.SO.enroll.view(3).token
      w.env.os.queueEvent("monitor_touch", "wall", 1, 1)
      n.flush()
      equal(w.files["so-keys"], old)
      w.env.os.queueEvent("paste", token)
      n.flush()
      assert(not table.concat(w.screen, "\n"):find(token, 1, true), "repair printed token")
      w.env.os.queueEvent("key", 257)
      n.flush()
      n.advance(4)
      local row = s.env.SO.enroll.view(3).rows[1]
      assert(row, "repair did not request enrollment")
      equal(w.files["so-keys"], old, "unapproved repair replaced keys")
      assert(s.env.SO.enroll.decide(2, row.n, true))
      n.advance(7)
      local saved = w.env.textutils.unserialize(w.files["so-keys"]).value.keys
      equal(saved[tostring(serverId)], s.env.SO.pair.key(2))
      assert(saved[tostring(serverId)] ~= key)
      if serverId ~= 1 then equal(saved["1"], nil, "repair retained the old lower-id peer") end
      equal(w.files["so-enroll"], nil)
      local journal = w.env.textutils.unserialize(w.files["so-journal"]).value
      equal(journal.uncertain, true)
      equal(w.pos, { x = 0, y = 0, z = 0 })
      local fuel = w.fuel
      s.env.rednet.send(2, s.env.SO.proto.build(saved[tostring(serverId)], "lease.batch",
        { lease = "after-repair", ttl = 10000, expires = w.env.os.epoch("utc") + 10000, steps = { { op = "forward" } } }), "so")
      n.flush()
      n.advance(3)
      equal(w.fuel, fuel, "replacement moved before re-anchor")

      local f = assert(io.open("install.lua", "rb"))
      local source = f:read("*a")
      f:close()
      local m = n.machine({ id = 8, turtle = true })
      m.files["/so-keys"] = old
      m.env.http = { get = function() error("keyed install reached network") end }
      local main = assert(load(source, "@install.lua", "t", m.env))("prepare")
      main(token)
      equal(m.files["/so-keys"], old)
      equal(m.files["/so-enroll"], nil)
      assert(table.concat(m.log, "\n"):find("paired keys", 1, true))
    end
  end)

  test("worker token repair defaults off and does not change trust", function()
    local n, s, w = setup(true)
    s.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = {} } })
    s.boot("so-server.lua")
    n.advance(3)
    local old = w.files["so-keys"]
    w.env.os.queueEvent("paste", "1-K7QP-3MXA-9WTD-HR2E")
    w.env.os.queueEvent("key", 257)
    n.flush()
    n.advance(4)
    equal(w.files["so-keys"], old)
    equal(w.files["so-enroll"], nil)
    assert(table.concat(w.screen, "\n"):find("token repair disabled", 1, true))
  end)

  test("worker re-pairs with replaced server keys without losing the old key on failure", function()
    local n, s, w = setup(true)
    s.files["so-keys"] = H.encode({schema=1,generation=1,value={keys={["2"]=string.rep("b",64)}}})
    s.boot("so-server.lua"); n.advance(3)
    local old = w.files["so-keys"]
    assert((w.screen[6] or ""):find("No key on server", 1, true), "repair prompt missing")
    assert((w.screen[7] or ""):find("Code:", 1, true), "code entry missing")
    equal(w.screen[8] or "", "")
    equal(w.screen[7], "Code: ")
    equal(w.files["so-keys"], old)
    w.env.os.queueEvent("paste", "000000"); w.env.os.queueEvent("key", 257)
    n.flush(); n.advance(10)
    equal(w.files["so-keys"], old, "failed repair replaced key")
    local code = s.env.SO.pair.invite()
    w.env.os.queueEvent("paste", code); w.env.os.queueEvent("key", 257)
    n.flush(); n.advance(31)
    assert(w.alive(), tostring(w.error))
    assert(w.files["so-keys"] ~= old, "repair did not save new key")
    equal(w.screen[2], "step idle")
    assert(not (w.screen[6] or ""):find("No key on server", 1, true))
  end)
  test("running idle worker notices server keys replaced after boot", function()
    local n, s, w = setup(true)
    s.boot("so-server.lua"); n.advance(5)
    equal(w.screen[2], "step idle")
    local old, journal = w.files["so-keys"], w.files["so-journal"]
    assert(s.env.SO.pair.remember(2, string.rep("b",64)))
    n.advance(35)
    assert((w.screen[6] or ""):find("No key on server", 1, true), "running worker did not offer repair")
    equal(w.files["so-keys"], old)
    equal(w.files["so-journal"], journal)
    local code = s.env.SO.pair.invite()
    w.env.os.queueEvent("paste", code); w.env.os.queueEvent("key", 257)
    n.flush(); n.advance(5)
    assert(w.files["so-keys"] ~= old, "running worker did not re-pair")
    equal(w.screen[2], "step idle")
  end)
  test("worker ignores unrelated hints and retains valid keys on forged server hints", function()
    local n, s, w = setup(true)
    s.boot("so-server.lua"); n.advance(3)
    local old = w.files["so-keys"]
    w.env.os.queueEvent("rednet_message", 77, {t="pair.required",from=77}, "so")
    n.flush()
    assert(not (w.screen[6] or ""):find("No key on server", 1, true))
    w.env.os.queueEvent("rednet_message", 1, {t="pair.required",from=1}, "so")
    n.flush()
    assert((w.screen[6] or ""):find("No key on server", 1, true))
    equal(w.files["so-keys"], old)
    s.env.rednet.send(2, s.env.SO.proto.build(key, "ack", {ok=true}), "so")
    n.flush(); n.advance(5)
    equal(w.files["so-keys"], old)
    assert(not (w.screen[6] or ""):find("No key on server", 1, true))
  end)
  test("worker paired boot recovers without keyboard after server outage", function()
    local n, s, w = setup(true)
    n.advance(120)
    equal(w.reads or 0, 0)
    assert(w.lookups > 2, "lookup never retried")
    assert(w.lookups <= 10, "discovery did not back off")
    assert(table.concat(w.screen, " "):find("waiting for server", 1, true), "waiting status missing")
    w.env.rednet.lookup = function() return nil end
    s.boot("so-server.lua")
    n.advance(31)
    assert(w.alive(), tostring(w.error))
    assert(s.alive(), tostring(s.error))
    equal(w.reads or 0, 0)
    equal(w.screen[2], "step idle")
    local hello = false
    for _, wire in ipairs(w.sent) do
      if wire.payload.t == "hello" then hello = true end
    end
    assert(hello, "hello missing")
  end)
  test("worker unpaired code prompt keeps retrying discovery", function()
    local n, _, w = setup(false)
    n.advance(20)
    assert(w.alive(), tostring(w.error))
    assert(w.lookups > 2, "prompt blocked discovery")
    equal(w.reads or 0, 0)
    assert((w.screen[5] or ""):find("Code:", 1, true), "code prompt missing")
    equal(w.screen[4], "UNPAIRED")
  end)
  test("worker accepts typed code after discovering a late server", function()
    local n, s, w = setup(false)
    n.advance(10)
    s.boot("so-server.lua")
    n.advance(3)
    local code = s.env.SO.pair.invite()
    w.inbox[#w.inbox + 1] = table.pack("paste", code)
    w.inbox[#w.inbox + 1] = table.pack("key", 257)
    n.flush()
    n.advance(3)
    assert(w.alive(), tostring(w.error))
    assert(w.files["so-keys"], "typed code did not pair")
    equal(w.reads or 0, 0)
    equal(w.screen[2], "step idle")
    assert(w.screen[4]:find("seen ", 1, true), "paired status missing")
  end)

  test("worker first boot shows the wrong-code reason and retries", function()
    local n, s, w = setup(false)
    s.boot("so-server.lua"); n.advance(3)
    local code = s.env.SO.pair.invite()
    local wrong = code == "000000" and "111111" or "000000"
    w.env.os.queueEvent("paste", wrong); w.env.os.queueEvent("key", 257)
    n.flush(); n.advance(10)
    equal(w.screen[6], "Pair failed: wrong code")
    equal(w.screen[4], "UNPAIRED")
    assert(not w.files["so-keys"])
    w.env.os.queueEvent("paste", code); w.env.os.queueEvent("key", 257)
    n.flush(); n.advance(5)
    assert(w.files["so-keys"], "retry did not save a key")
    assert(w.screen[4]:find("seen ", 1, true))
  end)
  test("worker forgotten by server shows the missing-key state", function()
    local n, s, w = setup(true)
    s.boot("so-server.lua"); n.advance(5)
    assert(s.env.SO.pair.forget(2))
    n.advance(35)
    equal(w.screen[6], "No key on server")
    equal(w.screen[7], "Code: ")
    equal(w.screen[8] or "", "")
    local code = s.env.SO.pair.invite()
    w.env.os.queueEvent("paste", code); w.env.os.queueEvent("key", 257)
    n.flush(); n.advance(5)
    equal(w.screen[2], "step idle")
    assert(s.env.SO.pair.key(2), "forgotten worker did not re-pair")
  end)
  test("worker pending enrollment shows the panel approval state and fingerprint", function()
    local n, s, w = setup(false)
    s.files["so-server.cfg"] = H.encode({ enroll = true })
    s.boot("so-server.lua"); n.advance(3)
    assert(s.env.SO.pair.forget(2))
    assert(s.env.SO.enroll.open(3))
    local token = s.env.SO.enroll.view(3).token
    n.kill(w)
    w.files["so-enroll"] = H.encode({ token = token })
    w = n.boot(w); n.advance(5)
    local row = assert(s.env.SO.enroll.view(3).rows[1])
    equal(w.screen[2], "step approve on panel " .. row.fp)
    equal(w.screen[4], "UNPAIRED")
  end)

  local function settingsSetup(config)
    local n, s, w = setup(true, nil, config or {settingsControl=true, autoToolSwap=true,
      dim="minecraft:overworld", keep={name="untouched"}})
    s.install({"so-mod-lease.lua"})
    s.files["so-server.cfg"] = H.encode({workerSettings=true})
    s.boot("so-server.lua")
    n.advance(5)
    assert(w.alive(), tostring(w.error))
    return n, s, w, s.env.SO.mods.lease
  end
  local function cfg(w) return w.env.textutils.unserialize(w.files["so-worker.cfg"]) end
  local function click(n, w, x, y)
    w.env.os.queueEvent("mouse_click", 1, x, y)
    n.flush()
    assert(w.alive(), tostring(w.error))
  end
  local function serverSend(n, s, t, body, rid)
    local msg = s.env.SO.proto.build(s.env.SO.pair.key(2), t, body, rid)
    s.env.rednet.send(2, msg, "so")
    n.flush()
    return msg
  end
  test("local turtle screen saves NETHER and SWAP off preserving unrelated keys", function()
    local n, _, w, lease = settingsSetup()
    assert((w.screen[7] or ""):find("NETHER", 1, true))
    local pairing=w.files["so-keys"]
    click(n,w,10,7)
    equal(cfg(w).dim,"minecraft:the_nether")
    click(n,w,3,8)
    equal(cfg(w).autoToolSwap,false)
    equal(cfg(w).settingsSeq,2)
    equal(cfg(w).keep,{name="untouched"})
    equal(w.files["so-keys"],pairing)
    n.advance(1)
    equal(lease.status(2).settings,{seq=2,dim="minecraft:the_nether",autoToolSwap=false})
    equal(w.pos,{x=0,y=0,z=0})
  end)
  test("backend server call and local screen use last durable write wins across reboot and duplicate counters", function()
    local n, s, w, lease = settingsSetup()
    local rid = assert(lease.settings(2,{autoToolSwap=false}))
    n.flush()
    equal(cfg(w).autoToolSwap,false)
    equal(lease.status(2).settingsPending,nil)
    click(n,w,3,8)
    equal(cfg(w).autoToolSwap,true)
    local first = cfg(w)
    serverSend(n,s,"worker.settings",{n=1,autoToolSwap=false},rid.."-retry")
    equal(cfg(w),first,"equal n reapplied an older intent")
    serverSend(n,s,"worker.settings",{n=0,autoToolSwap=false})
    equal(cfg(w),first)
    n.kill(w); w=n.boot(w); n.advance(6)
    serverSend(n,s,"worker.settings",{n=1,autoToolSwap=false})
    equal(cfg(w),first,"reboot lost remote counter")
    assert(lease.settings(2,{autoToolSwap=false})); n.flush()
    equal(cfg(w).autoToolSwap,false)
    equal(cfg(w).settingsSeq,3)
  end)
  test("settings flags default off and offline local edits never queue", function()
    local n,s,w,lease = settingsSetup({autoToolSwap=true,dim="minecraft:overworld"})
    local before=w.files["so-worker.cfg"]
    click(n,w,10,7)
    serverSend(n,s,"worker.settings",{n=1,autoToolSwap=false})
    equal(w.files["so-worker.cfg"],before)
    s.files["so-server.cfg"] = H.encode({})
    equal(lease.settings(2,{autoToolSwap=false}),nil)
    n,s,w = settingsSetup()
    n.kill(s); n.advance(61)
    before=w.files["so-worker.cfg"]
    click(n,w,3,8)
    equal(w.files["so-worker.cfg"],before)
  end)
  test("settings idle guard refuses between batches and needs fresh authenticated unassignment after stationary expiry", function()
    local n,s,w,lease = settingsSetup()
    local oldHello
    for _, sent in ipairs(w.sent) do if sent.payload.t=="hello" then oldHello=sent.payload end end
    serverSend(n,s,"worker.status",{job="mine",reason="working"})
    local lid=assert(lease.send(2,{{op="inspectDown",park=true}},{ms=3000}))
    n.flush(); n.advance(.2)
    local before=w.files["so-worker.cfg"]
    click(n,w,3,8); equal(w.files["so-worker.cfg"],before)
    serverSend(n,s,"worker.status",{job="",reason="",idleRid=oldHello.rid})
    n.advance(4)
    click(n,w,3,8); equal(w.files["so-worker.cfg"],before)
    serverSend(n,s,"worker.status",{job="",reason=""})
    click(n,w,3,8); equal(w.files["so-worker.cfg"],before)
    local forged=s.env.SO.proto.build(string.rep("b",64),"worker.status",{job="",reason="",idleRid=oldHello.rid})
    s.env.rednet.send(2,forged,"so"); n.flush()
    click(n,w,3,8); equal(w.files["so-worker.cfg"],before)
    n.advance(31)
    click(n,w,3,8)
    equal(cfg(w).autoToolSwap,false,"fresh status did not release expired stationary park "..lid)
  end)
  test("dimension edits with history require durable re-anchor before old history can be used", function()
    local n,s,w,lease = settingsSetup()
    assert(lease.send(2,{{op="forward",park=true}},{ms=1000}))
    n.flush(); n.advance(32)
    click(n,w,10,7)
    local j=w.env.textutils.unserialize(w.files["so-journal"]).value
    equal(j.uncertain,true); equal(j.dimensionChanged,true)
    local fuel=w.fuel
    serverSend(n,s,"lease.batch",{lease="held",ttl=1000,expires=n.time+1000,steps={{op="forward"}}})
    n.advance(2); equal(w.fuel,fuel)
    serverSend(n,s,"worker.anchor",{journal=j.id,pose={x=4,y=64,z=5,f=1}})
    j=w.env.textutils.unserialize(w.files["so-journal"]).value
    equal(j.uncertain,nil); equal(j.moves,{}); equal(j.dug,{})
    equal(j.dim,"minecraft:the_nether")
    equal(j.pose,{x=4,y=64,z=5,f=1})
  end)
  test("config recovery persists before GPS and pending inference and only explicit dimension re-anchor clears it", function()
    for _, suffix in ipairs({".tmp",".bak"}) do
      local n,s,w = setup(true)
      n.kill(w)
      w.files["so-worker.cfg"..suffix] = H.encode({dim="minecraft:the_nether",settingsControl=true,settingsSeq=4})
      w.files["so-journal"] = H.encode({schema=1,generation=1,value={id="old",seq=2,moves={},dug={},
        pending={n=2,op="forward",fuel=1000},pose={x=0,y=0,z=0,f=0}}})
      local gpsReads=0
      n.onBoot=function(fresh) if fresh.id==2 then fresh.env.gps={locate=function() gpsReads=gpsReads+1 return 0,64,0 end} end end
      w=n.boot(w); s.boot("so-server.lua"); n.advance(5)
      equal(gpsReads,0)
      equal(cfg(w).configRecovery,true)
      local j=w.env.textutils.unserialize(w.files["so-journal"]).value
      equal(j.uncertain,true); assert(j.pending)
      n.kill(w); w=n.boot(w); n.advance(6)
      equal(gpsReads,0); equal(cfg(w).configRecovery,true)
      j=w.env.textutils.unserialize(w.files["so-journal"]).value
      serverSend(n,s,"worker.anchor",{journal=j.id,pose={x=0,y=64,z=0,f=0}})
      equal(cfg(w).configRecovery,false)
      j=w.env.textutils.unserialize(w.files["so-journal"]).value
      equal(j.uncertain,nil); equal(j.pending,nil)
      assert(gpsReads>0)
    end
  end)

  test("worker boot holds before dimension GPS and fuel inference at every interrupted config write or move", function()
    local n,s,w = settingsSetup({settingsControl=true,dim="minecraft:the_nether",autoToolSwap=false,settingsSeq=1})
    w.files["so-worker.cfg.bak"]=H.encode({dim="minecraft:the_nether"})
    local snapshots={}
    local function capture()
      snapshots[#snapshots+1]={primary=w.files["so-worker.cfg"],tmp=w.files["so-worker.cfg.tmp"],bak=w.files["so-worker.cfg.bak"]}
    end
    for _,op in ipairs({"open","delete","move"}) do
      local original=w.env.fs[op]
      w.env.fs[op]=function(...)
        local args=table.pack(...)
        local mutation=(op~="open" or args[2]=="w") and tostring(args[1]):find("so-worker.cfg",1,true)
        if mutation then capture() end
        local result=original(...)
        if mutation then capture() end
        if op=="open" and mutation then
          for _,method in ipairs({"write","close"}) do
            local call=result[method]
            result[method]=function(...)
              capture(); local value=call(...); capture(); return value
            end
          end
        end
        return result
      end
    end
    click(n,w,19,7)
    equal(#snapshots,12)
    for _,snapshot in ipairs(snapshots) do
      n.kill(w)
      w.files["so-worker.cfg"],w.files["so-worker.cfg.tmp"],w.files["so-worker.cfg.bak"]=snapshot.primary,snapshot.tmp,snapshot.bak
      w.files["so-journal"]=H.encode({schema=1,generation=1,value={id="cut",seq=1,dim="minecraft:the_nether",
        pose={x=0,y=0,z=0,f=0},moves={},dug={},pending={n=1,op="forward",fuel=1000}}})
      w.files["so-journal.tmp"],w.files["so-journal.bak"]=nil,nil
      local gpsReads=0
      n.onBoot=function(fresh) if fresh.id==2 then fresh.env.gps={locate=function() gpsReads=gpsReads+1 return 0,64,0 end} end end
      w=n.boot(w); n.advance(6)
      assert(w.alive(),tostring(w.error))
      local hello
      for _,sent in ipairs(w.sent) do if sent.payload.t=="hello" then hello=sent.payload.body end end
      assert(hello and hello.dim~="minecraft:overworld" and hello.dim~=nil)
      if not snapshot.primary then
        equal(gpsReads,0)
        equal(hello.journal.uncertain,true)
        assert(hello.journal.pending,"recovery inferred the pending move")
        equal(cfg(w).configRecovery,true)
      end
      equal(w.pos,{x=0,y=0,z=0})
    end
    assert(s.alive(),tostring(s.error))
  end)
  test("settings requests during execution and assigned idle are refused without equipping tools", function()
    local n,s,w = settingsSetup()
    local equips=0
    w.env.turtle.equipLeft=function() equips=equips+1 return true end
    w.env.turtle.equipRight=w.env.turtle.equipLeft
    local before=w.files["so-worker.cfg"]
    serverSend(n,s,"worker.status",{job="build",reason="between batches"})
    click(n,w,3,8); equal(w.files["so-worker.cfg"],before)
    local p=s.env.SO.proto
    s.env.rednet.send(2,p.build(key,"lease.batch",{lease="executing",ttl=10000,expires=n.time+10000,
      steps={{op="inspectDown"},{op="inspectDown"}}}),"so")
    s.env.rednet.send(2,p.build(key,"worker.settings",{n=1,autoToolSwap=false}),"so")
    n.flush(); n.advance(1)
    equal(w.files["so-worker.cfg"],before)
    equal(equips,0)
    local refused=false
    for _,sent in ipairs(w.sent) do
      if sent.payload.t=="err" and sent.payload.body.command=="worker.settings" then refused=true end
    end
    assert(refused)
  end)

  test("assignment without a batch revokes local settings within one lease tick", function()
    for _,name in ipairs({"build","mine"}) do
      local n,s,w,lease=settingsSetup()
      local before=w.files["so-worker.cfg"]
      s.env.SO.mods[name]={assigned=function(id) return id==2 end}
      lease.tick(); n.flush()
      click(n,w,10,7); click(n,w,3,8)
      equal(w.files["so-worker.cfg"],before,name.." assignment allowed settings before its first batch")
      equal(w.pos,{x=0,y=0,z=0})
    end
  end)
  test("an open lease revokes local settings before its batch reaches the worker", function()
    local n,s,w,lease=settingsSetup()
    local before=w.files["so-worker.cfg"]
    local send=s.env.rednet.send
    s.env.rednet.send=function(id,payload,protocol)
      local msg=s.env.SO.proto.decode(payload)
      if id==2 and msg and msg.t=="lease.batch" then return true end
      return send(id,payload,protocol)
    end
    assert(lease.send(2,{{op="inspectDown"}},{owner="mine",ms=60000}))
    lease.tick(); n.flush()
    click(n,w,10,7); click(n,w,3,8)
    equal(w.files["so-worker.cfg"],before)
  end)
  test("unassignment expires after 45 seconds without idle refresh despite authenticated contact", function()
    local n,s,w=settingsSetup()
    local send=s.env.rednet.send
    s.env.rednet.send=function(id,payload,protocol)
      local msg=s.env.SO.proto.decode(payload)
      if id==2 and msg and msg.t=="worker.status" and msg.body.job=="" then return true end
      return send(id,payload,protocol)
    end
    n.advance(40)
    serverSend(n,s,"ack",{})
    click(n,w,3,8)
    equal(cfg(w).autoToolSwap,false,"fresh unassignment expired too early")
    local before=w.files["so-worker.cfg"]
    n.advance(6)
    serverSend(n,s,"ack",{})
    click(n,w,10,7); click(n,w,3,8)
    equal(w.files["so-worker.cfg"],before,"stale unassignment survived authenticated contact")
    s.env.rednet.send=send
    n.advance(31)
    click(n,w,3,8)
    equal(cfg(w).autoToolSwap,true,"fresh idle refresh did not release settings")
  end)
  test("config recovery reuses durable journal uncertainty without repeated hello writes", function()
    local n,s,w=settingsSetup()
    n.kill(w)
    w.files["so-worker.cfg.bak"],w.files["so-worker.cfg"]=w.files["so-worker.cfg"],nil
    w.files["so-journal"]=H.encode({schema=1,generation=1,value={id="held",seq=0,
      pose={x=0,y=0,z=0,f=0},moves={},dug={},uncertain=true}})
    w.files["so-journal.tmp"],w.files["so-journal.bak"]=nil,nil
    w=n.boot(w); n.advance(5)
    local before=w.files["so-journal"]
    equal(w.env.textutils.unserialize(before).generation,1)
    n.advance(65)
    equal(w.files["so-journal"],before,"held config rewrote the uncertain journal")
    assert(w.alive(),tostring(w.error)); assert(s.alive(),tostring(s.error))
  end)

  test("settings validation and failed writes retain confirmed values without equipping a tool", function()
    local n,s,w,lease=settingsSetup()
    local before=w.files["so-worker.cfg"]
    for _,body in ipairs({{n=1,dim="nether"},{n=1,autoToolSwap=0},{n=1,autoToolSwap=false,extra=true},
      {n=-1,autoToolSwap=false},{n=1.5,autoToolSwap=false},{n=1}}) do
      serverSend(n,s,"worker.settings",body)
      equal(w.files["so-worker.cfg"],before)
    end
    local equips=0
    w.env.turtle.equipLeft=function() equips=equips+1 return true end
    w.env.turtle.equipRight=w.env.turtle.equipLeft
    local free=w.env.fs.getFreeSpace
    w.env.fs.getFreeSpace=function(path) if path=="so-worker.cfg" then return 0 end return free(path) end
    assert(lease.settings(2,{autoToolSwap=false})); n.flush()
    equal(w.files["so-worker.cfg"],before)
    equal(lease.status(2).settings.autoToolSwap,true)
    equal(lease.status(2).settingsPending,nil)
    w.env.fs.getFreeSpace=free
    assert(lease.settings(2,{autoToolSwap=false})); n.flush()
    equal(cfg(w).autoToolSwap,false)
    equal(equips,0)
  end)
  test("config with no valid candidate or no explicit dimension stays held through re-anchor attempts", function()
    for _,text in ipairs({"broken",H.encode({settingsSeq=1,settingsControl=true})}) do
      local n,s,w=setup(true)
      n.kill(w)
      w.files["so-worker.cfg.tmp"]=text
      w=n.boot(w); s.boot("so-server.lua"); n.advance(5)
      local hello
      for _,sent in ipairs(w.sent) do if sent.payload.t=="hello" then hello=sent.payload.body end end
      assert(hello and hello.journal.uncertain)
      equal(hello.dim,nil); equal(hello.gps,nil)
      serverSend(n,s,"worker.anchor",{journal=hello.journal.id,pose={x=1,y=64,z=2,f=0}})
      serverSend(n,s,"lease.batch",{lease="no-dim",ttl=1000,expires=n.time+1000,steps={{op="forward"}}})
      n.advance(2)
      equal(w.pos,{x=0,y=0,z=0})
      local journal=w.env.textutils.unserialize(w.files["so-journal"]).value
      equal(journal.uncertain,true)
    end
  end)

  test("completed backtracking permits edits with a stale lease id only after a new idle confirmation", function()
    local n,s,w,lease=settingsSetup()
    local send=s.env.rednet.send
    s.env.rednet.send=function(id,payload,protocol)
      local msg=s.env.SO.proto.decode(payload)
      if id==2 and msg and msg.t=="worker.status" and msg.body.job=="" then return true end
      return send(id,payload,protocol)
    end
    assert(lease.send(2,{{op="forward"}},{ms=1000}))
    n.flush(); n.advance(70)
    local before=w.files["so-worker.cfg"]
    equal(w.pos,{x=0,y=0,z=0})
    click(n,w,3,8)
    equal(w.files["so-worker.cfg"],before,"missing post-recovery status released the guard")
    s.env.rednet.send=send
    local hello
    for _,sent in ipairs(w.sent) do if sent.payload.t=="hello" then hello=sent.payload end end
    serverSend(n,s,"worker.status",{job="",reason="",idleRid=hello.rid})
    click(n,w,3,8)
    equal(cfg(w).autoToolSwap,false,"stale lease id kept completed recovery busy")
  end)

  local current, target = string.rep("a",40), string.rep("b",40)
  local function updateSetup(config)
    local n,s,w,lease = settingsSetup(config or {remoteUpdates=true,dim="minecraft:overworld"})
    n.kill(w)
    w.files[".so-revision"] = current
    w = n.boot(w)
    s.files[".so-revision"] = target
    s.files["so-server.cfg"] = H.encode({panelUpdates=true})
    n.kill(s); s=n.boot(s)
    n.advance(32)
    return n,s,w,s.env.SO.mods.lease
  end
  local function updater(n,w, outcome)
    local trace = {}
    local send = w.env.rednet.send
    w.env.rednet.send=function(id,msg,protocol)
      if msg.t=="ack" and msg.body.command=="worker.update" then trace[#trace+1]="ack" end
      return send(id,msg,protocol)
    end
    w.env.shell={run=function(path,command,revision,running)
      equal({path,command,revision,running},{"/install.lua","worker-update",target,current})
      trace[#trace+1]="installer"
      if outcome=="throw" then error("handled failure") end
      if outcome then w.files[".so-revision"]=target end
      return outcome == true
    end}
    w.env.os.reboot=function() trace[#trace+1]="reboot" coroutine.yield("reboot") end
    return trace
  end
  test("pinned update ack precedes loop exit installer handoff and reboot on success or failure",function()
    for _,outcome in ipairs({true,false,"throw"}) do
      local n,s,w=updateSetup()
      local trace=updater(n,w,outcome)
      local rid=assert(s.env.SO.updateWorker(2))
      n.flush()
      equal(trace,{"ack","installer","reboot"})
      equal(s.env.SO.workerUpdate(2).state,"awaiting reboot")
      local fuel=w.fuel
      serverSend(n,s,"lease.batch",{lease="after-ack",ttl=1000,expires=n.time+1000,steps={{op="forward"}}})
      equal(w.fuel,fuel)
      assert(rid)
    end
  end)
  test("worker hello caches revision at boot and target hello confirms only after reboot",function()
    local n,s,w=updateSetup()
    w.files[".so-revision"]=target
    n.advance(31)
    equal(s.env.SO.workerUpdate(2).running,current)
    updater(n,w,true)
    assert(s.env.SO.updateWorker(2)); n.flush()
    equal(s.env.SO.workerUpdate(2).state,"awaiting reboot")
    n.kill(w); w=n.boot(w); n.advance(6)
    equal(s.env.SO.workerUpdate(2).running,target)
    equal(s.env.SO.workerUpdate(2).state,"complete")
  end)
  test("pinned update flags default off and old capability unknown equal or malformed revisions refuse",function()
    for _,cfgValue in ipairs({{}, {remoteUpdates=false}}) do
      local n,s,w=updateSetup(cfgValue)
      local before=w.files["so-worker.cfg"]
      equal(s.env.SO.updateWorker(2),nil)
      serverSend(n,s,"worker.update",{revision=target})
      equal(w.files["so-worker.cfg"],before)
      assert(w.alive(),tostring(w.error))
    end
    local n,s,w=updateSetup()
    s.files["so-server.cfg"]=H.encode({})
    equal(s.env.SO.updateWorker(2),nil)
    for _,revision in ipairs({current,"bad",false}) do
      local hello={role="turtle",remoteUpdates=true,capabilities={pinnedUpdate=true},revision=revision or nil}
      if revision==false then hello.capabilities={} end
      w.env.rednet.send(1,w.env.dofile("so-proto.lua").build(key,"hello",hello,"flags-"..tostring(revision)),"so")
      n.flush()
      s.files["so-server.cfg"]=H.encode({panelUpdates=true})
      if revision==current then
        serverSend(n,s,"worker.update",{revision=current})
      else equal(s.env.SO.updateWorker(2),nil) end
      assert(w.alive(),tostring(w.error))
    end
  end)
  test("pinned update uses shared idle guard for assignment open batch uncertain journal and cfg recovery",function()
    for _,kind in ipairs({"assignment","open lease","uncertain","config recovery","corrupt config"}) do
      local n,s,w,lease=updateSetup()
      local trace=updater(n,w,true)
      if kind=="assignment" then
        s.env.SO.mods.mine={assigned=function() return true end}
        serverSend(n,s,"worker.status",{job="mine",reason="assigned"})
      elseif kind=="open lease" then
        assert(lease.send(2,{{op="inspectDown",park=true}},{ms=20000})); n.flush(); n.advance(.2)
      elseif kind=="uncertain" then
        n.kill(w)
        w.files["so-journal"]=H.encode({schema=1,generation=1,value={id="held",seq=1,
          uncertain=true,moves={},dug={},pose={x=0,y=0,z=0,f=0}}})
        w=n.boot(w); n.advance(5); trace=updater(n,w,true)
      elseif kind=="config recovery" then
        w.files["so-worker.cfg.tmp"]=w.files["so-worker.cfg"]; w.files["so-worker.cfg"]=nil
      else w.files["so-worker.cfg"]="corrupt"; w.files["so-worker.cfg.bak"]=nil end
      local before=w.files["so-keys"]
      serverSend(n,s,"worker.update",{revision=target})
      equal(trace,{})
      equal(w.files["so-keys"],before)
      if kind=="assignment" or kind=="uncertain" then equal(s.env.SO.updateWorker(2),nil,kind) end
      assert(w.alive(),tostring(w.error))
    end
  end)
  test("pinned update replies match sender rid command revision and deadline and consume duplicates without err loops",function()
    local n,s,w=updateSetup()
    local send=w.env.rednet.send
    w.env.rednet.send=function(id,msg,protocol)
      if msg.body.command=="worker.update" then return true end
      return send(id,msg,protocol)
    end
    w.env.shell={run=function() return false end}
    w.env.os.reboot=function() coroutine.yield("reboot") end
    local rid=assert(s.env.SO.updateWorker(2)); n.flush()
    local proto=w.env.dofile("so-proto.lua")
    local function reply(t,body,replyRid,from)
      local msg=proto.build(key,t,body,replyRid)
      if from then msg.from=from; msg.mac=proto.sign(key,msg) end
      send(1,msg,"so"); n.flush()
    end
    local accepted={command="worker.update",revision=target,state="accepted"}
    reply("ack",accepted,rid.."other")
    reply("ack",{command="worker.settings",revision=target,state="accepted"},rid.."settings")
    reply("ack",accepted,rid,3)
    equal(s.env.SO.workerUpdate(2).state,"requested")
    reply("ack",{command="worker.update",revision=current,state="accepted"},rid.."wrong-target")
    equal(s.env.SO.workerUpdate(2).state,"requested")
    reply("ack",accepted,rid)
    equal(s.env.SO.workerUpdate(2).state,"awaiting reboot")
    local count=#s.sent
    reply("ack",accepted,rid)
    reply("err",{command="worker.update",code="update",text="late"},rid.."late")
    equal(s.env.SO.workerUpdate(2).state,"awaiting reboot")
    equal(#s.sent,count)
    n.advance(121)
    equal(s.env.SO.workerUpdate(2).state,"unconfirmed")
    reply("ack",accepted,rid.."expired")
    equal(s.env.SO.workerUpdate(2).state,"unconfirmed")
  end)
  test("pinned update matched err refuses without accepting an unrelated error",function()
    local n,s,w=updateSetup()
    local send=w.env.rednet.send
    w.env.rednet.send=function(id,msg,protocol)
      if msg.body.command=="worker.update" then
        msg=w.env.dofile("so-proto.lua").build(key,"err",{command="worker.update",code="update",text="worker busy",revision=target},msg.rid)
      end
      return send(id,msg,protocol)
    end
    w.env.shell={run=function() return false end}; w.env.os.reboot=function() coroutine.yield("reboot") end
    assert(s.env.SO.updateWorker(2)); n.flush()
    equal(s.env.SO.workerUpdate(2).state,"refused")
    equal(s.env.SO.workerUpdate(2).text,"worker busy")
  end)
  test("worker selected cfg server is used for an unpaired join despite another discovery result",function()
    local n,s,w=setup(false,7,{server=7,dim="minecraft:overworld"})
    w.env.rednet.lookup=function() return 1 end
    s.boot("so-server.lua"); n.advance(3)
    assert(w.screen[5]:find("Code:  server 7",1,true),w.screen[5])
    s.env.os.queueEvent("key",25); n.flush()
    local invite=s.env.SO.pair.pending()
    w.env.os.queueEvent("paste",invite); w.env.os.queueEvent("key",257)
    n.flush(); n.advance(6)
    equal(w.env.dofile("so-store.lua").read("so-keys").value.keys["7"],s.env.SO.pair.key(2))
    assert(w.alive(),tostring(w.error))
  end)
  test("revision machine events precede coalescing and pressure returns and survive restart",function()
    for _,coalesce in ipairs({false,true}) do
      local n,s,w=setup(true)
      s.install({"so-mod-state.lua","so-log.lua"})
      s.files["so-server.cfg"]=H.encode({state={coalesceHeartbeats=coalesce}})
      s.boot("so-server.lua"); n.advance(4)
      local state=s.env.SO.mods.state
      local proto=w.env.dofile("so-proto.lua")
      local function hello(revision)
        w.env.rednet.send(1,proto.build(key,"hello",{role="turtle",fuel=1000,journal={id="2-0"},revision=revision}),"so")
        n.flush()
      end
      hello(current)
      equal(state.get("machines/2/revision"),current)
      local free=s.env.fs.getFreeSpace
      s.env.fs.getFreeSpace=function() return 1600000 end
      hello(target)
      equal(state.get("machines/2/revision"),target)
      local events=state.history.page({kind="machine",reverse=true,count=1}).entries
      equal(events[1].data.revision,target)
      hello(nil)
      equal(state.get("machines/2/revision"),false)
      s.env.fs.getFreeSpace=free
      n.kill(s); s=n.boot(s); n.advance(1)
      equal(s.env.SO.mods.state.get("machines/2/revision"),false)
    end
  end)

  test("pinned update refuses a queued executing batch and accepts no work after acknowledgement",function()
    local n,s,w,lease=updateSetup()
    local trace=updater(n,w,true)
    assert(lease.send(2,{{op="inspectDown",park=true}},{ms=10000}))
    local msg=s.env.SO.proto.build(key,"worker.update",{revision=target})
    s.env.rednet.send(2,msg,"so")
    n.flush();n.advance(.2)
    equal(trace,{})
    local errorReply
    for _,sent in ipairs(w.sent) do
      if sent.payload.rid==msg.rid then errorReply=sent.payload end
    end
    equal(errorReply.t,"err");equal(errorReply.body.text,"worker busy")
    assert(w.alive(),tostring(w.error))
  end)
  test("revision emit refusal leaves the last confirmed registry revision intact",function()
    local n,s,w=setup(true)
    s.install({"so-mod-state.lua","so-log.lua"})
    s.boot("so-server.lua");n.advance(4)
    local state=s.env.SO.mods.state
    local proto=w.env.dofile("so-proto.lua")
    w.env.rednet.send(1,proto.build(key,"hello",{role="turtle",revision=current},"revision-confirmed"),"so")
    n.flush()
    local open=s.env.fs.open
    s.env.fs.open=function(path,mode)
      if mode=="w" and path:match("^so%-data/log/") then error("disk write refused") end
      return open(path,mode)
    end
    for i=1,256 do assert(state.emit("test.pending",{n=i})) end
    w.env.rednet.send(1,proto.build(key,"hello",{role="turtle",revision=target},"revision-refused"),"so")
    n.flush()
    equal(state.get("machines/2/revision"),current)
    equal(state.disk().pending,256)
  end)

  test("pinned update cannot leave the loop when sending its acknowledgement fails",function()
    local n,s,w=updateSetup()
    local trace=updater(n,w,true)
    local send=w.env.rednet.send
    w.env.rednet.send=function(id,msg,protocol)
      if msg.t=="ack" and msg.body.command=="worker.update" then return false end
      return send(id,msg,protocol)
    end
    assert(s.env.SO.updateWorker(2));n.flush()
    equal(trace,{})
    equal(s.env.SO.workerUpdate(2).state,"requested")
    assert(w.alive(),tostring(w.error))
  end)

end
