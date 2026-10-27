local H = dofile("tests/so/harness.lua")
local R = dofile("tests/ui/render.lua")
local FILES = {"so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-log.lua", "so-errors.lua",
  "so-mod-state.lua", "so-mod-display.lua", "so-mod-panel.lua", "so-mod-health.lua", "so-mod-lease.lua",
  "so-mod-cells.lua", "so-mod-drops.lua", "so-mod-mine.lua", "so-mod-lumber.lua", "so-mod-build.lua",
  "so-plan.lua", "so-ui.lua", "so-mine-plan.lua", "so-lumber-plan.lua",
  "lib/ccryptolib/x25519.lua", "lib/ccryptolib/random.lua", "lib/ccryptolib/blake3.lua",
  "lib/ccryptolib/chacha20.lua", "lib/ccryptolib/config.lua", "lib/ccryptolib/internal/util.lua",
  "lib/ccryptolib/internal/hw.lua", "lib/ccryptolib/internal/curve25519.lua", "lib/ccryptolib/internal/fp.lua",
  "lib/ccryptolib/internal/edwards25519.lua", "lib/ccryptolib/internal/packing.lua"}
local function private(fn, key)
  for i=1,40 do local n,v=debug.getupvalue(fn,i) if n==key then return v end end
  error("missing "..key)
end
local function setup(w,h,config)
  local net = H.new()
  local m = net.machine({id=1,modem=true})
  m.install(FILES)
  for _,path in ipairs(FILES) do
    if path:match("^lib/") then
      local f=assert(io.open(path,"rb"))
      m.files[path]=f:read("*a")
      f:close()
    end
  end
  config=config or {terminalRevoke=false}
  for _,name in ipairs({"workerPark","protectedAreas","alternateAxisOrders","storageDeliveries","builderFuelTrips","worldEdits","dropsTestQueue","dropsSavedSetup"}) do
    if config[name]==nil then config[name]=false end
  end
  m.files["so-server.cfg"] = H.encode(config)
  m.boot("so-server.lua")
  net.flush()
  assert(m.alive(),tostring(m.error))
  local so=m.env.SO
  assert(so.mods.panel and so.mods.mine and so.mods.lumber and so.mods.build)
  for _,id in ipairs({2,3,4,5,6,7,8,9,10}) do assert(so.pair.remember(id,string.rep(string.format("%02x",id),32))) end
  net.advance(1.05)
  local ok,err=pcall(so.mods.display.screen("panel").render,w,h,{})
  assert(ok,tostring(err))
  local d=so.mods.display
  local s={net=net,m=m,so=so,roles={}}
  s.frame=function(id)
    d.handlers.hello({from=id,body={w=w,h=h,role=s.roles[id] or "display"}})
    local f
    d.handlers["view.get"]({from=id},function(_,body) f=body end)
    return f
  end
  s.press=function(id,name)
    local f=s.frame(id)
    for _,b in ipairs(f.buttons) do
      if b.id==name or b.id:sub(1,#name+1)==name..":" then
        d.handlers.input({from=id,body={id=b.id,x=b.x,y=b.y}})
        return
      end
    end
    error("button missing "..name.." role "..tostring(f.role).." buttons "..H.encode(f.buttons))
  end
  -- Roles change only by assignment: a pocket keeps its tabs and opens PAIRED from PAIR,
  -- other displays are assigned the panel role.
  s.open=function(id)
    s.frame(id)
    if w==26 then s.press(id,"tab:pair")
    else assert(d.assign(id,"panel")) s.press(id,"pair") end
    s.press(id,"paired")
  end
  return s
end
-- Per-cell fg and bg strings of a frame row.
local function layers(row,w)
  if not row.runs then
    return #row.fg==1 and string.rep(row.fg,w) or row.fg,#row.bg==1 and string.rep(row.bg,w) or row.bg
  end
  local fg,bg={},{}
  for _,run in ipairs(row.runs) do
    fg[#fg+1]=string.rep(run[2],run[1]);bg[#bg+1]=string.rep(run[3],run[1])
  end
  return table.concat(fg),table.concat(bg)
end
-- CC glyphs start on a cell's top pixel row, so a label inked in the colour of the cell above
-- loses its top stroke on a real screen.
local function strokesShow(f,w,prefix)
  local n=0
  for _,b in ipairs(f.buttons) do
    if b.id:sub(1,#prefix)==prefix then
      local fg=layers(f.rows[b.y],w)
      local _,above=layers(f.rows[b.y-1],w)
      for x=b.x,b.x+b.w-1 do
        if f.rows[b.y].text:sub(x,x)~=" " then
          n=n+1
          assert(fg:sub(x,x)~=above:sub(x,x),prefix.." ink matches the row above at column "..x)
        end
      end
    end
  end
  assert(n>0,"no "..prefix.." label drawn")
end
return function(test,equal)
  local function packet(s, from, kind, body)
    local key = s.so.pair.key(from)
    local msg = s.so.proto.build(key, kind, body or {})
    msg.from = from
    msg.mac = s.so.proto.sign(key, msg)
    return assert(s.so.proto.encode(msg))
  end
  local function deliver(s, from, wire)
    s.m.env.os.queueEvent("rednet_message", from, wire, "so")
    s.net.flush()
    assert(s.m.alive(), tostring(s.m.error))
  end
  local function terminal(s, text)
    for _=1,#s.so.terminal.input do s.m.env.os.queueEvent("key",14,false) end
    s.m.env.os.queueEvent("paste", text)
    s.m.env.os.queueEvent("key", 28, false)
    s.net.flush()
    assert(s.m.alive(), tostring(s.m.error))
  end
  local function openTerminal(s)
    s.m.env.os.queueEvent("key", 19, false)
    s.net.flush()
    equal(s.so.terminal.mode, "role")
  end
  test("server refusal buckets separate shape time MAC and replay by sender without payloads",function()
    local s = setup(26,20)
    local accepted = 0
    s.so.mods.state.handlers["f6c.silent"] = function() accepted = accepted + 1 end
    deliver(s,2,{secret="untrusted body"})
    local old = packet(s,2,"hello")
    old.at = old.at - 120001
    deliver(s,2,old)
    local bad = packet(s,2,"hello",{secret="untrusted body"})
    bad.mac = string.rep("0",64)
    deliver(s,2,bad)
    local once = packet(s,2,"f6c.silent")
    deliver(s,2,once); deliver(s,2,once)
    deliver(s,3,packet(s,2,"hello"))
    equal(accepted,1)
    local facts = s.so.health.refused
    equal(facts.senders[2].shape,1); equal(facts.senders[2].time,1)
    equal(facts.senders[2].mac,1); equal(facts.senders[2].replay,1)
    equal(facts.senders[3].shape,1); equal(facts.senders[3].mac,0)
    local text = H.encode(facts)
    assert(not text:find("untrusted body",1,true) and not text:find(s.so.pair.key(2),1,true))
    equal(s.so.errors.status().count,0)
  end)
  test("server refusal flood bounds sender buckets and leaves the error ring untouched",function()
    local s = setup(26,20)
    local count = s.so.errors.status().count
    for i=1,512 do deliver(s,100+i,{}) end
    local facts, countSenders = s.so.health.refused, 0
    for _ in pairs(s.so.health.refused.senders) do countSenders = countSenders + 1 end
    equal(countSenders,facts.cap); equal(facts.cap,128)
    equal(s.so.errors.status().count,count)
    equal(#s.so.terminal.log,200)
    assert(s.so.terminal.log[200]:find("612",1,true))
    local at = s.so.now()
    s.so.now = function() return at + facts.windowMs end
    deliver(s,612,{})
    equal(facts.senders[612].shape,1)
    s.net.advance(1.05)
    countSenders = 0
    for _ in pairs(facts.senders) do countSenders = countSenders + 1 end
    equal(countSenders,1)
    equal(s.so.errors.status().count,count)
  end)
  test("server flood of 192 failing dispatches keeps the newest 128 errors and cached replies",function()
    local s = setup(26,20)
    local calls, wire = 0, nil
    s.so.mods.state.handlers["f6c.fail"] = function(msg)
      calls = calls + 1
      error("flood " .. msg.body.n,0)
    end
    for i=1,192 do
      wire = packet(s,2,"f6c.fail",{n=i})
      deliver(s,2,wire)
      local reply = assert(s.so.proto.decode(s.m.sent[#s.m.sent].payload))
      equal(reply.t,"err"); equal(reply.body,{code="handler"})
      equal(reply.rid,wire.rid)
      assert(s.so.proto.macOk(s.so.pair.key(2),reply))
    end
    local entries = s.so.errors.entries()
    equal(#entries,128); equal(s.so.errors.status().count,128)
    for i,entry in ipairs(entries) do equal(entry.text,"so-server: handler f6c.fail failed: flood " .. (i+64)) end
    local cached = s.m.sent[#s.m.sent].payload
    deliver(s,2,wire)
    equal(calls,192); equal(s.m.sent[#s.m.sent].payload,cached)
    equal(s.so.errors.entries(),entries)
  end)
  test("server module tick timing names the slowest peak and ages it in game time",function()
    local s = setup(26,20)
    local clock, extra = s.m.env.os.clock, 0
    s.m.env.os.clock = function() return clock()+extra end
    s.so.mods.mine.tick = function() extra = extra + 0.025 end
    s.so.mods.lumber.tick = function() extra = extra + 0.080 end
    s.net.advance(1.05)
    local health = s.so.health
    equal(health.modules["so-mod-mine.lua"].tickMs,25)
    equal(health.modules["so-mod-lumber.lua"].tickMs,80)
    equal(health.modules["so-mod-lumber.lua"].peakMs,80)
    equal(health.slowest.name,"lumber"); equal(health.slowest.tickMs,80)
    equal(health.slowest.age,0)
    s.so.mods.mine.tick = function() end
    s.so.mods.lumber.tick = function() end
    s.net.advance(1.05)
    equal(health.modules["so-mod-lumber.lua"].tickMs,0)
    equal(health.modules["so-mod-lumber.lua"].peakMs,80)
    assert(health.slowest.age >= 1000)
    s.so.mods.lumber.tick = function() extra=extra+0.090 error("slow failure",0) end
    s.net.advance(1.05)
    equal(health.modules["so-mod-lumber.lua"].tickMs,90)
    equal(health.modules["so-mod-lumber.lua"].peakMs,90)
    equal(health.modules["so-mod-lumber.lua"].tickError,"slow failure")
    equal(health.slowest.tickMs,90); equal(health.slowest.age,0)
  end)
  test("forget impact reads parks 1 job for lumber and counts jobs and scans without writes",function()
    local s = setup(26,20)
    local so = s.so
    private(so.mods.lumber.forget,"S").job.turtles["3"] = {turtle={id=3},inv={}}
    local before = H.encode(s.m.files)
    local impact = so.forgetImpact(3)
    equal(impact,{jobs=1,scans=0,jobNames={"lumber"},text="parks 1 job"})
    equal(H.encode(s.m.files),before)
    private(so.mods.mine.assigned,"job").turtles["3"] = {}
    private(so.mods.build.forget,"j").turtle = {id=3}
    private(so.mods.drops.busy,"S").task = {id=3}
    before = H.encode(s.m.files)
    impact = so.forgetImpact(3)
    equal(impact,{jobs=3,scans=1,jobNames={"mine","lumber","build"},text="parks 3 jobs; holds 1 scan"})
    equal(so.forgetImpact(4).text,"parks 0 jobs")
    equal(so.forgetImpact(999).jobs,0)
    equal(H.encode(s.m.files),before)
    assert(so.pair.key(3))
    impact.jobNames[1] = "changed"
    equal(so.forgetImpact(3).jobNames,{"mine","lumber","build"})
  end)
  test("terminal revoke can be disabled and refuses an unknown device",function()
    local s = setup(26,20)
    openTerminal(s)
    local before = H.encode(s.m.files)
    terminal(s,"3 revoke"); terminal(s,"3")
    assert(s.so.pair.key(3))
    equal(H.encode(s.m.files),before)
    s.m.files["so-server.cfg"] = H.encode({terminalRevoke=true})
    terminal(s,"999 revoke")
    equal(s.so.terminal.notice,"device not paired")
  end)
  test("terminal revoke refuses a mismatched id without changing keys jobs leases scans or reservations",function()
    local s = setup(26,20,{terminalRevoke=true})
    local so = s.so
    local mine = private(so.mods.mine.assigned,"job")
    mine.turtles["3"] = {state="mining",recover=false}
    local lumber = private(so.mods.lumber.forget,"S").job
    lumber.turtles["3"] = {turtle={id=3},inv={}}
    local build = private(so.mods.build.forget,"j")
    build.turtle, build.running = {id=3}, true
    local drops = private(so.mods.drops.busy,"S")
    drops.task = {id=3,lease="scan"}
    local lease = private(so.mods.lease.forget,"S")
    lease.turtles[3] = {open={id="moving"}}
    assert(so.mods.cells.reserve("setup:3",5,64,0,"minecraft:overworld"))
    openTerminal(s)
    local function snapshot()
      return H.encode({files=s.m.files,mine=mine,lumber=lumber,build=build,task=drops.task,lease=lease.turtles[3],
        keys=so.pair.list(),pending=so.pair.forgetPending(),forgotten=so.mods.state.get("pair.forgotten"),sent=s.m.sent})
    end
    local before = snapshot()
    terminal(s,"3 revoke")
    equal(snapshot(),before)
    terminal(s,"4")
    equal(so.terminal.notice,"revoke id mismatch")
    equal(snapshot(),before)
    equal(so.mods.cells.owner(5,64,0,"minecraft:overworld"),"setup:3")
    terminal(s,"3")
    equal(snapshot(),before)
  end)
  test("terminal revoke with a repeated id uses durable forget cleanup and preserves held cells",function()
    local s = setup(26,20,{terminalRevoke=true})
    local so = s.so
    local job = private(so.mods.lumber.forget,"S").job
    job.turtles["3"] = {turtle={id=3},inv={}}
    assert(so.mods.cells.reserve("lumber:3",5,64,0,"minecraft:overworld"))
    openTerminal(s)
    terminal(s,"3 revoke")
    assert(so.terminal.notice:find("parks 1 job",1,true))
    assert(so.pair.key(3))
    terminal(s,"3")
    equal(so.pair.key(3),nil); assert(so.pair.key(4))
    assert(job.turtles["3"].turtle.forgotten and job.turtles["3"].paused)
    equal(so.mods.cells.owner(5,64,0,"minecraft:overworld"),"lumber:3")
    equal(so.pair.forgetPending(),{})
    equal(so.mods.state.get("pair.forgotten").actor,1)
  end)
  for _,kind in ipairs({"escape","expired","rekeyed","disabled"}) do
    test("terminal revoke refuses a confirmation after " .. kind,function()
      local s = setup(26,20,{terminalRevoke=true})
      openTerminal(s)
      terminal(s,"3 revoke")
      if kind == "escape" then
        s.m.env.os.queueEvent("key",1,false); s.net.flush(); openTerminal(s)
      elseif kind == "expired" then
        local at = s.so.now()
        s.so.now = function() return at+15000 end
      elseif kind == "rekeyed" then
        assert(s.so.pair.remember(3,string.rep("ab",32)))
      else s.m.files["so-server.cfg"] = H.encode({terminalRevoke=false}) end
      local before = H.encode(s.m.files)
      terminal(s,"3")
      assert(s.so.pair.key(3))
      equal(H.encode(s.m.files),before)
      equal(s.so.pair.forgetPending(),{})
    end)
  end
  test("forget and confirm labels keep their top stroke on the panel and pocket",function()
    for _,size in ipairs({{26,20},{29,12},{57,24}}) do
      local s=setup(unpack(size))
      s.open(2)
      strokesShow(s.frame(2),size[1],"forget:")
      s.press(2,"forget:3")
      strokesShow(s.frame(2),size[1],"forget-confirm:")
    end
  end)
  test("forget drawn flow fits compact displays, pages keys and refuses self",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local s=setup(unpack(size))
      s.open(2)
      local f=s.frame(2)
      local out=R.capture(size[1],size[2])
      for y,row in ipairs(f.rows) do
        local fg,bg={},{}
        for _,run in ipairs(row.runs or {}) do
          fg[#fg+1]=string.rep(run[2],run[1]);bg[#bg+1]=string.rep(run[3],run[1])
        end
        fg,bg=table.concat(fg),table.concat(bg)
        if not row.runs then
          fg=#row.fg==1 and string.rep(row.fg,size[1]) or row.fg
          bg=#row.bg==1 and string.rep(row.bg,size[1]) or row.bg
        end
        out.setCursorPos(1,y);out.blit(row.text..string.rep(" ",size[1]-#row.text),fg,bg)
      end
      local fixture=size[1]==26 and "tests/ui/fixtures/paired-P.txt" or "tests/ui/fixtures/paired-S.txt"
      local differences=R.diff(fixture,out)
      assert(#differences==0,table.concat(differences,"\n"))
      local seen={}
      for _,b in ipairs(f.buttons) do
        assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=size[1] and b.y+(b.h or 1)-1<=size[2])
        seen[b.id]=true
      end
      assert(not seen["forget:2"] and seen["forget:3"])
      -- The PAIRED section is row 3; the keys start under it.
      local first=f.rows[4].text
      assert(first:find("#2",1,true))
      local fingerprint=s.so.pair.list()[1].fingerprint
      equal(#fingerprint,4)
      assert(first:find(fingerprint,1,true))
      s.press(2,"paired-next")
      assert(s.frame(2).rows[4].text~=first)
      s.press(2,"paired-prev")
      assert(s.so.pairCode(3))
      s.press(2,"forget:3")
      assert(s.so.pair.key(3))
      s.press(2,"forget-confirm:3")
      equal(s.so.pair.key(3),nil)
      equal(s.so.pair.pending(),nil)
      equal(s.so.mods.state.get("pair.forgotten").id,3)
      local box=s.m
      local saved=box.env.textutils.unserialize(box.files["so-keys"])
      equal(saved.value.keys["3"],nil)
      s.net.advance(5)
      s.so.mods.health.tick(s.so.now())
      local items=private(s.so.mods.health.tick,"H").items
      local found=false
      for _,row in ipairs(items) do if row.key=="forgotten" then found=true end end
      assert(found,"missing attention row")
    end
  end)
  test("forget rejects forged, expired, cross-session, rekeyed and unpaired confirmations",function()
    local s=setup(26,20)
    s.open(2)
    local input=s.so.mods.display.handlers.input
    input({from=2,body={id="forget-confirm:3",x=14,y=5}})
    assert(s.so.pair.key(3))
    input({from=2,body={id="forget:3",x=1,y=1}})
    input({from=2,body={id="forget-confirm:3",x=14,y=7}})
    assert(s.so.pair.key(3))
    s.press(2,"forget:3")
    local confirmation
    for _,b in ipairs(s.frame(2).buttons) do
      if b.id:match("^forget%-confirm:3:") then confirmation=b end
    end
    assert(confirmation)
    s.open(4)
    input({from=4,body={id=confirmation.id,x=confirmation.x,y=confirmation.y}})
    assert(s.so.pair.key(3))
    s.net.advance(15.001)
    input({from=2,body={id=confirmation.id,x=confirmation.x,y=confirmation.y}})
    assert(s.so.pair.key(3))
    s.press(2,"forget:3")
    assert(s.so.pair.remember(3,string.rep("ab",32)))
    s.press(2,"forget-confirm:3")
    assert(s.so.pair.key(3))
    s.press(2,"forget:3")
    assert(s.so.pair.forget(2))
    s.press(2,"forget-confirm:3")
    assert(s.so.pair.key(3))
  end)
  test("forget delayed authenticated confirm cannot authorize a later attempt",function()
    for _,size in ipairs({{26,20},{29,12}}) do
      local s=setup(unpack(size))
      local proto,key=s.so.proto,s.so.pair.key(2)
      local function packet(t,body)
        local msg=proto.build(key,t,body)
        msg.from=2
        msg.mac=proto.sign(key,msg)
        return assert(proto.encode(msg))
      end
      local function deliver(wire)
        s.m.env.os.queueEvent("rednet_message",2,wire,"so")
        s.net.flush()
        assert(s.m.alive(),tostring(s.m.error))
      end
      local function frame()
        deliver(packet("view.get",{}))
        for i=#s.m.sent,1,-1 do
          local msg=proto.decode(s.m.sent[i].payload)
          if s.m.sent[i].id==2 and msg and msg.t=="view.frame" then return msg.body end
        end
        error("missing authenticated frame")
      end
      local function button(name)
        for _,b in ipairs(frame().buttons) do
          if b.id==name or b.id:sub(1,#name+1)==name..":" then return b end
        end
        error("missing drawn button "..name)
      end
      local function tap(name)
        local b=button(name)
        deliver(packet("input",{id=b.id,x=b.x,y=b.y}))
      end
      deliver(packet("hello",{role="display",w=size[1],h=size[2]}))
      if size[1]==26 then tap("tab:pair") else assert(s.so.mods.display.assign(2,"panel")) tap("pair") end
      tap("paired");tap("forget:3")
      local old=button("forget-confirm:3")
      local delayed=packet("input",{id=old.id,x=old.x,y=old.y})
      tap("paired-back")
      local session=private(s.so.mods.display.handlers.hello,"D").sessions[2]
      equal(session.panel.confirm,nil)
      assert(s.so.pair.remember(3,string.rep("ab",32)))
      tap("paired");tap("forget:3")
      local current=button("forget-confirm:3")
      local count=s.so.errors.status().count
      deliver(delayed)
      assert(s.so.pair.key(3),"delayed confirmation deleted replacement key")
      equal(s.so.errors.status().count,count)
      assert(current.id~=old.id,"confirmation token reused")
      deliver(packet("input",{id=current.id,x=current.x,y=current.y}))
      equal(s.so.pair.key(3),nil)
      equal(session.panel.confirm,nil)
    end
  end)
  test("forget uses composed banner coordinates and refuses worker-role sessions",function()
    local s=setup(29,12)
    s.so.mods.cells.retirement=function() return {text="Dug marks",status="pending",id="test"} end
    s.open(2)
    s.press(2,"forget:3")
    s.press(2,"forget-confirm:3")
    equal(s.so.pair.key(3),nil)
    s.roles[2]="turtle"
    s.frame(2)
    local count=s.so.errors.status().count
    local f=s.frame(2)
    for _,b in ipairs(f.buttons) do
      if b.id=="forget:4" then
        s.so.mods.display.handlers.input({from=2,body={id=b.id,x=b.x,y=b.y}})
      end
    end
    for _,b in ipairs(s.frame(2).buttons) do assert(not b.id:match("^forget%-confirm:4:")) end
    assert(s.so.pair.key(4))
    equal(s.so.errors.status().count,count)
  end)
  test("forget persistence failure keeps key and pair2 sessions are invalidated on success",function()
    local s=setup(26,20)
    local pair=s.so.pair
    local state=private(pair.key,"S")
    state.sessions["3"]={at=s.so.now()}
    local save=state.box.save
    state.box.save=function() return false,"disk" end
    equal(pair.forget(3),false)
    assert(pair.key(3) and state.sessions["3"])
    state.box.save=save
    assert(pair.forget(3))
    equal(state.sessions["3"],nil)
    local proto=s.so.proto
    local msg=proto.build(string.rep("03",32),"hello",{})
    msg.from=3
    msg.mac=proto.sign(string.rep("03",32),msg)
    s.m.env.os.queueEvent("rednet_message",3,proto.encode(msg),"so")
    s.net.flush()
    local found=false
    for _,sent in ipairs(s.m.sent) do
      if sent.id==3 and type(sent.payload)=="table" and sent.payload.t=="pair.required" then found=true end
    end
    assert(found,"forgotten hello needs pair.required")
  end)
  test("forget key save failure leaves every planner, lease and invitation unchanged",function()
    local s=setup(26,20)
    local so=s.so
    local mine=private(so.mods.mine.assigned,"job")
    mine.turtles["3"]={pose={dim="minecraft:overworld",x=1,y=64,z=0},state="mining",recover=false}
    local lumber=private(so.mods.lumber.forget,"S").job
    lumber.turtles["3"]={turtle={id=3,pose={x=2,y=64,z=0}},inv={}}
    lumber.running=true
    local build=private(so.mods.build.forget,"j")
    build.turtle={id=3,pose={x=3,y=64,z=0}}
    build.running=true
    local drops=private(so.mods.drops.busy,"S")
    drops.task={id=3,lease="setup"}
    local lease=private(so.mods.lease.forget,"S")
    lease.turtles[3]={open={id="moving",turtleId=3,status="open",expires=so.now()+100,owner="mine",steps={{op="forward"}}}}
    assert(so.mods.cells.reserve("setup:3",5,64,0,"minecraft:overworld"))
    local invitation=assert(so.pairCode(3))
    local function planners()
      return H.encode({mine=mine,lumber=lumber,build=build,task=drops.task,lease=lease.turtles[3]})
    end
    local before,files,key=planners(),H.encode(s.m.files),so.pair.key(3)
    local pairState=private(so.pair.key,"S")
    local save=pairState.box.save
    pairState.box.save=function() return false,"disk" end
    local ok,err=so.forgetDevice(3,2)
    equal(ok,false);equal(err,"disk")
    equal(so.pair.key(3),key)
    equal(planners(),before)
    equal(H.encode(s.m.files),files)
    equal(so.pairCode(3),invitation)
    equal(so.mods.cells.owner(5,64,0,"minecraft:overworld"),"setup:3")
    equal(so.mods.state.get("pair.forgotten"),nil)
    equal(so.pair.forgetPending(),{})
    pairState.box.save=save
    assert(so.forgetDevice(3,2))
    equal(so.pair.key(3),nil)
    assert(mine.turtles["3"].forgotten and lumber.turtles["3"].turtle.forgotten and build.turtle.forgotten)
  end)
  test("forget clears setup and visit state while preserving possible occupied cells",function()
    for _,visit in ipairs({false,true}) do
      local s=setup(26,20)
      local drops,cells=s.so.mods.drops,s.so.mods.cells
      local state=private(drops.busy,"S")
      state.task={id=3,lease="old-step",point=visit and {id="ore"} or nil}
      state.releasing={id=3,lease="old-release"}
      state.compass={id=3}
      state.candidates={{x=1,y=64,z=0}}
      assert(cells.reserveMany("setup:3",{{dim="minecraft:overworld",x=0,y=64,z=0},
        {dim="minecraft:overworld",x=1,y=64,z=0}}))
      s.open(2);s.press(2,"forget:3");s.press(2,"forget-confirm:3")
      equal(s.so.pair.key(3),nil)
      assert(not drops.busy(3))
      equal(cells.list("setup:3",100),{})
      equal(state.task,nil);equal(state.releasing,nil);equal(state.compass,nil);equal(state.candidates,{})
      for x=0,1 do
        equal(cells.owner(x,64,0,"minecraft:overworld"),"gps:3")
        assert(not cells.reserve("other",x,64,0,"minecraft:overworld"))
      end
      local before=#s.m.sent
      state.setupReport("old-step",3,{{ok=true}},{report={}})
      state.setupReport("old-release",3,{{ok=true}},{report={}})
      equal(#s.m.sent,before)
      local replacement=assert(loadfile("so-mod-drops.lua","t",s.m.env))()
      assert(not replacement.busy(3))
      equal(cells.owner(1,64,0,"minecraft:overworld"),"gps:3")
    end
  end)
  for _,restart in ipairs({false,true}) do
    test("forget mid-lease permits re-pair and mine re-add"..(restart and " across restart" or " live"),function()
      local s=setup(26,20)
      local so=s.so
      so.mods.lease.handlers.hello({from=3,body={role="turtle",journal={id="before",pose={x=0,y=0,z=0,f=1}},
        capabilities={setupFence=true,parkBatch=true}}})
      local job=private(so.mods.mine.assigned,"job")
      job.turtles["3"]={pose={dim="minecraft:overworld",x=0,y=0,z=0,facing=1},state="mining",inv={}}
      assert(so.mods.cells.reserve("mine:3",0,0,0,"minecraft:overworld"))
      local old=assert(so.mods.lease.send(3,{{op="forward"}},{owner="mine"}))
      assert(so.forgetDevice(3))
      equal(so.mods.lease.status(3).recovering,false)
      equal(so.mods.cells.owner(0,0,0,"minecraft:overworld"),"mine:3")
      if restart then
        s.net.kill(s.m) s.m=s.net.boot(s.m) s.net.flush() s.net.advance(1)
        so=s.m.env.SO
      end
      assert(so.pair.remember(3,string.rep("ab",32)))
      so.mods.lease.handlers.hello({from=3,body={role="turtle",journal={id="after",pose={x=0,y=0,z=0,f=1}},
        capabilities={setupFence=true,parkBatch=true}}})
      so.mods.display.screen("mining").input({text="add 3 0 0 0 e"})
      job=private(so.mods.mine.assigned,"job")
      assert(job.turtles["3"] and not job.turtles["3"].forgotten,"re-add refused the forgotten worker")
      local nextId=so.mods.lease.status(3).open
      assert(nextId and nextId~=old,"re-add did not dispatch a fresh stationary lease")
    end)
  end
  test("forget recovers orphan setup reservations without cancelling another device",function()
    local s=setup(26,20)
    local drops,cells=s.so.mods.drops,s.so.mods.cells
    local state=private(drops.busy,"S")
    state.task={id=4,lease="other"}
    state.compass={id=4}
    assert(cells.reserve("setup:3",5,64,0,"minecraft:overworld"))
    assert(s.so.forgetDevice(3,2))
    equal(cells.list("setup:3",100),{})
    equal(cells.owner(5,64,0,"minecraft:overworld"),"gps:3")
    assert(drops.busy(4));equal(state.task.lease,"other");equal(state.compass.id,4)
  end)
  test("forget keeps a device revoked when setup handoff fails and cleanup retries automatically",function()
    local s=setup(26,20)
    local drops,cells=s.so.mods.drops,s.so.mods.cells
    local state=private(drops.busy,"S")
    state.task={id=3,lease="old-step"}
    assert(cells.reserve("setup:3",5,64,0,"minecraft:overworld"))
    local handoff=cells.handoff
    cells.handoff=function() return false,"disk" end
    equal(s.so.forgetDevice(3,2),false)
    assert(not s.so.pair.key(3) and drops.busy(3))
    equal(state.task.lease,nil)
    equal(cells.owner(5,64,0,"minecraft:overworld"),"setup:3")
    cells.handoff=handoff
    s.net.advance(1.05)
    assert(s.m.alive(),tostring(s.m.error))
    equal(s.so.pair.forgetPending(),{})
    equal(s.so.pair.key(3),nil);assert(not drops.busy(3))
    equal(cells.owner(5,64,0,"minecraft:overworld"),"gps:3")
  end)
  test("forget parks one lumber worker while the rest of its fleet continues",function()
    local F=dofile("tests/so/lumber-farm-fixture.lua")
    local g=F.setup(true,10000,"down",3)
    F.run(g,function(v) return #v.digs>=2 end)
    local so=g.server.env.SO
    local job=private(so.mods.lumber.forget,"S").job
    local forgotten
    for _,worker in ipairs(g.workers) do
      if job.turtles[tostring(worker.id)].tree then forgotten=worker.id break end
    end
    assert(forgotten)
    local before=#g.digs
    assert(so.forgetDevice(forgotten))
    assert(job.turtles[tostring(forgotten)].turtle.forgotten and job.running)
    F.run(g,function(v) return #v.digs>before and F.delivered(v)>=12 end)
    equal(so.pair.key(forgotten),nil)
    local row=job.turtles[tostring(forgotten)]
    assert(row.turtle.forgotten and row.paused and not row.pending)
    assert(so.mods.cells.list("lumber:"..forgotten,1)[1],"forgotten worker lost its reservations")
  end)
  test("forget parks every planner and lease without releasing possibly occupied reservations",function()
    local s=setup(26,20)
    local so=s.so
    local mine=private(so.mods.mine.assigned,"job")
    mine.turtles["3"]={pose={dim="minecraft:overworld",x=1,y=64,z=0},state="mining",lane={release=true},recover=false}
    local lumber=private(so.mods.lumber.forget,"S")
    lumber.job.turtles["3"]={turtle={id=3,pose={x=2,y=64,z=0}},inv={}}
    lumber.job.running=true
    local build=private(so.mods.build.forget,"j")
    build.turtle={id=3,pose={x=3,y=64,z=0}}
    build.running=true
    local lease=private(so.mods.lease.forget,"S")
    local called=false
    lease.turtles[3]={open={id="moving",turtleId=3,status="open",expires=so.now()+100,owner="mine",steps={{op="forward"}}},probe={done=function() called=true end},range=96}
    for i,owner in ipairs({"mine:3","lumber:3","build:3","moving","gps:3"}) do
      assert(so.mods.cells.reserve(owner,i,64,0,"minecraft:overworld"))
    end
    s.open(2);s.press(2,"forget:3");s.press(2,"forget-confirm:3")
    assert(mine.turtles["3"].forgotten and lumber.job.turtles["3"].turtle.forgotten and build.turtle.forgotten)
    assert(lumber.job.turtles["3"].paused and not build.running)
    equal(so.mods.lease.status(3).open,nil)
    assert(so.mods.lease.status(3).uncertain)
    s.net.advance(20)
    assert(not called)
    for i,owner in ipairs({"mine:3","lumber:3","build:3","moving","gps:3"}) do
      equal(so.mods.cells.owner(i,64,0,"minecraft:overworld"),owner)
    end
    for _,name in ipairs({"mine","lumber","build"}) do equal(so.mods[name].dugProtection(function() end),false) end
    local before=#s.m.sent
    for _,name in ipairs({"mine","lumber","build"}) do so.mods[name].tick(so.now()) end
    equal(#s.m.sent,before)
    local restartedMine=assert(loadfile("so-mod-mine.lua","t",s.m.env))()
    assert(private(restartedMine.assigned,"job").turtles["3"].forgotten)
  end)
end
