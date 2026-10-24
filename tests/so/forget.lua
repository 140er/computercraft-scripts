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
local function setup(w,h)
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
  s.open=function(id)
    s.frame(id)
    s.press(id,"panel")
    s.press(id,"pair")
    s.press(id,"paired")
  end
  return s
end
return function(test,equal)
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
      local first=f.rows[3].text
      assert(first:find("#2",1,true))
      local fingerprint=s.so.pair.list()[1].fingerprint
      equal(#fingerprint,4)
      assert(first:find(fingerprint,1,true))
      s.press(2,"paired-next")
      assert(s.frame(2).rows[3].text~=first)
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
      if frame().role~="panel" then tap("panel") end
      tap("pair");tap("paired");tap("forget:3")
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
  test("forget keeps the key when setup reservation handoff cannot save",function()
    local s=setup(26,20)
    local drops,cells=s.so.mods.drops,s.so.mods.cells
    local state=private(drops.busy,"S")
    state.task={id=3,lease="old-step"}
    assert(cells.reserve("setup:3",5,64,0,"minecraft:overworld"))
    local handoff=cells.handoff
    cells.handoff=function() return false,"disk" end
    equal(s.so.forgetDevice(3,2),false)
    assert(s.so.pair.key(3) and drops.busy(3))
    equal(state.task.lease,nil)
    equal(cells.owner(5,64,0,"minecraft:overworld"),"setup:3")
    cells.handoff=handoff
    assert(s.so.forgetDevice(3,2))
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
    lease.turtles[3]={open={id="moving",expires=so.now()+100,owner="mine",steps={{op="forward"}}},probe={done=function() called=true end},range=96}
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
