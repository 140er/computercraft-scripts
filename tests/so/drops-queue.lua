local H = dofile("tests/so/harness.lua")
local P = dofile("so-plan.lua")
local R = dofile("tests/ui/render.lua")

local function private(fn, key)
  for i=1,40 do local k,v=debug.getupvalue(fn,i) if k==key then return v end end
  error("missing "..key)
end
local function boot(options, files)
  options = options or {dropsTestQueue=true,setupMovement=true}
  local m = H.new().machine({id=1,capacity=16000000})
  m.install({"so-store.lua","so-ui.lua","so-plan.lua","so-mine-plan.lua","so-mod-cells.lua","so-mod-drops.lua"})
  for path,bytes in pairs(files or {}) do m.files[path]=bytes end
  m.files["so-server.cfg"]=H.encode(options)
  local t = {machine=m, paired=true, active=nil, visits={}, sends=0, releases=0, now=1000,
    pose={dim="minecraft:overworld",x=0,y=64,z=0,facing=1},
    status={pose={x=0,y=0,z=0,f=1},journal="journal",fuel=10000,parkBatch=true,setupFence=true}}
  local e = m.env
  e.SO={store=e.dofile("so-store.lua"),now=function() return t.now end,breathe=function() end,
    pair={key=function() return t.paired and "key" or nil end},mods={}}
  e.SO.mods.state={emit=function() end}
  e.SO.mods.cells=e.dofile("so-mod-cells.lua")
  e.SO.mods.display={screen=function(_,render,input) t.render,t.input=render,input end}
  local lease={candidates=function() return t.busy and {} or {12} end,
    world=function() return e.SO.store.copy(t.pose) end,
    status=function() return e.SO.store.copy(t.status) end,
    claimProbe=function(id,owner,pose)
      local cells=e.SO.mods.cells
      if cells.owner(pose.x,pose.y,pose.z,pose.dim)=="gps:"..id then
        return cells.handoff("gps:"..id,owner,pose.x,pose.y,pose.z,pose.dim)
      end
      return true
    end,
    onReport=function(_,fn) t.report=fn end,
    send=function(id,steps)
      assert(not t.active,"two leases in flight")
      t.sends=t.sends+1
      t.active={lid="lease-"..t.sends,id=id,step=steps[1]}
      return t.active.lid
    end,
    inRange=function() return not t.outOfRange end}
  e.SO.mods.lease=lease
  t.mod=e.dofile("so-mod-drops.lua")
  t.S=private(t.mod.tick,"S")
  t.mod.tick()
  t.cells=e.SO.mods.cells
  local release=t.cells.releaseOwner
  t.cells.releaseOwner=function(owner) t.releases=t.releases+1 return release(owner) end
  t.add=function(id,x,dim)
    assert(t.mod.add({id=id,dim=dim or 0,x=x,y=63,z=0,side="down",kind="ore"}))
  end
  t.frame=function(id,w,h) return t.render(w or 26,h or 20,{id=id or 7}) end
  t.tap=function(id,from)
    from=from or 7
    t.frame(from)
    t.input({id=id,from=from})
  end
  t.open=function(from) t.tap("testing",from) end
  t.step=function(result, uncertain)
    local a=assert(t.active,"no active lease")
    local task=t.S.task
    local frame=task.frame
    local step=task.steps[task.next]
    t.active=nil
    if step.verify then t.visits[#t.visits+1]=step.verify end
    t.pose=P.apply(t.pose,a.step.op)
    t.status.pose=P.toJournal(frame,t.pose)
    local facts={report={pose=t.status.pose,uncertain=uncertain}}
    t.report(a.lid,a.id,{result or {ok=true,data={name="minecraft:chest"}}},facts)
  end
  t.drain=function()
    for _=1,500 do
      if t.active then t.step() else t.mod.tick() if not t.active then return end end
    end
    error("queue never settled")
  end
  return t
end
local function capture(frame,w,h)
  local out=R.capture(w,h)
  for y,row in ipairs(frame.rows) do
    local fg,bg={},{}
    for _,run in ipairs(row.runs) do fg[#fg+1]=string.rep(run[2],run[1]) bg[#bg+1]=string.rep(run[3],run[1]) end
    fg,bg=table.concat(fg),table.concat(bg)
    out.setCursorPos(1,y) out.blit(row.text..string.rep(" ",#fg-#row.text),fg,bg)
  end
  return out
end

return function(test,equal)
  test("P-U4-2 queue requires both default-off flags and delivered controls",function()
    for _,cfg in ipairs({{}, {setupMovement=true}, {dropsTestQueue=true}}) do
      local t=boot(cfg) t.add("a",2) t.open() t.tap("test-all")
      equal(t.sends,0)
      equal(t.S.queue,nil)
    end
    local t=boot() t.add("a",2)
    t.input({id="test-all",from=8}) equal(t.sends,0)
    t.open() t.tap("test-all") assert(t.active)
  end)
  test("P-U4-2 three stable IDs run in order after return and cell handoff",function()
    local t=boot() for i=1,3 do t.add("p"..i,i+1) end
    assert(t.S.observe({dim=0,x=9,y=63,z=0,side="down",block="minecraft:barrel",at=1000}))
    assert(t.mod.note("p1")) assert(t.mod.note("p1"))
    t.open() t.tap("test-all")
    while t.active do t.step() end
    equal(t.S.queue.completed,1) equal(t.releases,1)
    equal(t.cells.owner(0,64,0,"minecraft:overworld"),"gps:12")
    equal(t.visits,{"p1"})
    t.mod.tick() t.drain()
    equal(t.visits,{"p1","p2","p3"})
    equal({t.S.queue.state,t.S.queue.completed,t.releases},{"done",3,3})
    equal(t.pose,{dim="minecraft:overworld",x=0,y=64,z=0,facing=1})
    equal(t.cells.list("setup:12",100),{})
    equal(t.S.points[1].fails,0)
    equal(#t.S.candidates,1)
    local saved=t.machine.env.SO.store.read("so-drops").value
    equal(saved.queue,nil)
    local reboot=boot(nil,t.machine.files)
    equal({reboot.S.queue,reboot.sends,next(reboot.S.views)},{nil,0,nil})
  end)
  test("P-U4-2 ALL skips verified, broken, suspended, disabled and other dimensions",function()
    local t=boot({dropsTestQueue=true,setupMovement=true,dropsSavedSetup=true})
    for i,id in ipairs({"verified","broken","suspended","disabled","yes"}) do t.add(id,i+1) end
    t.add("nether",8,-1)
    assert(t.S.verify("verified",{ok=true,data={name="minecraft:chest"}}))
    for _=1,3 do assert(t.mod.note("broken")) end
    assert(t.S.suspend("suspended",true)) assert(t.mod.roomMark("disabled",true))
    t.open() t.tap("test-all") t.drain()
    equal(t.visits,{"yes"}) equal(t.S.queue.total,1)
  end)
  test("P-U4-2 per-display selection deduplicates IDs and explicitly retests verified points",function()
    local t=boot() t.add("a",2) t.add("b",3)
    assert(t.S.verify("a",{ok=true,data={name="minecraft:chest"}}))
    t.open() t.tap("queue-select:b") t.tap("queue-select:a")
    t.open(8) t.tap("test-selected",8) equal(t.sends,0)
    t.tap("test-selected") t.drain()
    equal(t.visits,{"a","b"}) equal(t.S.queue.total,2)
  end)
  test("P-U4-2 selected admission refuses stale, suspended and mixed-dimension selections",function()
    for _,change in ipairs({"remove","suspend","dimension"}) do
      local t=boot({dropsTestQueue=true,setupMovement=true,dropsSavedSetup=true})
      t.add("a",2) t.add("b",3) t.open()
      t.tap("queue-select:a") t.tap("queue-select:b")
      if change=="remove" then assert(t.mod.remove("a"))
      elseif change=="suspend" then assert(t.S.suspend("a",true))
      else local p=t.S.copy(t.S.points[1]) p.dim=-1 assert(t.S.edit("a",p)) end
      t.tap("test-selected") equal(t.sends,0) equal(t.S.queue,nil)
    end
  end)
  test("P-U4-2 two displays cannot start scans or tests during one queue",function()
    local t=boot() t.add("a",2) t.add("b",3) t.open() t.open(8) t.tap("test-all")
    local q=t.S.queue
    t.tap("test-all",8) t.input({text="scan 12",from=8}) t.input({text="test b",from=8})
    equal(t.S.queue,q) equal(t.sends,1)
    t.tap("list") t.drain() equal(t.S.queue.state,"done")
    local a=t.frame(7) local b=t.frame(8)
    assert(a and b)
  end)
  test("P-U4-2 busy, unpaired and incompatible workers never move",function()
    for _,kind in ipairs({"busy","unpaired","old","fuel","range"}) do
      local t=boot() t.add("a",2)
      if kind=="busy" then t.busy=true elseif kind=="unpaired" then t.paired=false
      elseif kind=="old" then t.status.setupFence=false elseif kind=="fuel" then t.status.fuel=0
      else t.outOfRange=true end
      t.open() t.tap("test-all") equal(t.sends,0)
      if t.S.queue then equal(t.S.queue.state,"stopped") equal(#t.S.queue.pending,0) end
    end
  end)
  test("P-U4-2 chooses the first eligible numeric worker once and honors an explicit choice",function()
    local t=boot() t.add("a",2) t.add("b",3)
    local lease=t.machine.env.SO.mods.lease
    lease.candidates=function() return {14,12} end
    local status=lease.status
    lease.status=function(id) local s=status(id) if id==12 then s.fuel=0 end return s end
    t.open() t.tap("test-all") equal(t.S.queue.workerId,14) equal(t.active.id,14)
    t.drain() equal(t.S.queue.workerId,14) equal(t.visits,{"a","b"})
    t.S.views[7].turtle=12
    t.tap("queue-select:a") t.tap("test-selected")
    equal(t.S.queue.workerId,12) equal(t.S.queue.state,"stopped") equal(t.active,nil)
  end)
  test("P-U4-2 a changed journal, pose or stale return proof cannot admit another visit",function()
    for _,change in ipairs({"journal","pose","age","uncertain"}) do
      local t=boot({dropsTestQueue=true,setupMovement=true,pos={dim="minecraft:overworld"}})
      t.add("a",2) t.add("b",3) t.open() t.tap("test-all")
      while t.active do t.step() end
      t.machine.env.SO.mods.lease.world=function() return nil,"no fresh GPS; use explicit add" end
      if change=="journal" then t.status.journal="new journal"
      elseif change=="pose" then t.status.pose.x=9
      elseif change=="age" then t.now=t.now+60001
      else t.status.uncertain=true end
      t.mod.tick()
      equal({t.S.queue.state,#t.S.queue.pending},{"stopped",0}) equal(t.visits,{"a"}) equal(t.active,nil)
    end
  end)
  test("P-U4-2 FACING stops and answering never restarts the discarded queue",function()
    local t=boot() t.add("a",2) t.add("b",3) t.pose.facing=nil
    t.open() t.tap("test-all")
    equal({t.S.queue.state,#t.S.queue.pending,t.sends},{"stopped",0,0})
    assert(t.S.compass)
    t.tap("facing:1") t.pose.facing=1 t.drain()
    equal(t.visits,{"a"}) equal(t.S.queue.state,"stopped")
  end)
  test("P-U4-2 a missing chest saves a strike then returns and stops",function()
    local t=boot() t.add("a",2) t.add("b",3) t.open() t.tap("test-all")
    assert(t.mod.note("a")) assert(t.mod.note("a"))
    while not t.S.task.steps[t.S.task.next].verify do t.step() end
    t.step({ok=false,err="No block to inspect"})
    equal({t.S.queue.state,#t.S.queue.pending},{"stopping",0})
    t.mod.tick()
    t.drain() equal({t.S.queue.state,t.S.queue.completed},{"stopped",0})
    equal(t.visits,{"a"}) equal(t.S.points[1].fails,3)
    equal(t.cells.list("setup:12",100),{})
  end)
  test("P-U4-2 verification save failure finishes the proven return without advancing",function()
    local t=boot() t.add("a",2) t.add("b",3) t.open() t.tap("test-all")
    t.S.box.save=function() return false,"disk full" end
    t.drain() equal(t.visits,{"a"})
    equal({t.S.queue.state,t.S.queue.completed,#t.S.queue.pending},{"stopped",0,0})
    equal(t.mod.list()[1].verified,nil) equal(t.cells.list("setup:12",100),{})
  end)
  test("P-U4-2 STOP outbound preserves the active lease and cells until safe return",function()
    local t=boot() t.add("a",3) t.add("b",4) t.open() t.tap("test-all") t.step()
    local lid=t.active.lid local held=t.cells.list("setup:12",100)
    t.tap("queue-stop",8) equal(t.active.lid,lid)
    t.open(8) t.tap("queue-stop",8)
    equal({t.S.queue.state,#t.S.queue.pending},{"stopping",0})
    equal(t.active.lid,lid) equal(t.cells.list("setup:12",100),held)
    t.drain() equal(t.S.queue.state,"stopped") equal(t.visits,{"a"})
    equal(t.cells.owner(0,64,0,"minecraft:overworld"),"gps:12")
  end)
  test("B9-U review: a new admission error overrides the old stop reason only on its display",function()
    local t=boot({dropsTestQueue=true,setupMovement=true,dropsSavedSetup=true})
    t.add("a",2) t.add("b",3) t.open() t.open(8)
    t.tap("queue-select:a") t.tap("test-selected") t.tap("queue-stop") t.drain()
    equal(t.S.queue.reason,"stopped by operator")
    assert(t.S.suspend("a",true))
    t.tap("test-selected")
    local function text(id)
      local rows={} for _,row in ipairs(t.frame(id).rows) do rows[#rows+1]=row.text end
      return table.concat(rows,"\n")
    end
    assert(text(7):find("selection unavailable",1,true),text(7))
    assert(not text(7):find("stopped by operator",1,true),text(7))
    assert(text(8):find("stopped by operator",1,true),text(8))
    equal(t.S.queue.reason,"stopped by operator")
  end)
  test("B9-U review: 15x10 saved setup keeps SCAN, RELEASE and candidate ADD reachable",function()
    local t=boot({dropsTestQueue=true,setupMovement=true,dropsSavedSetup=true})
    t.add("a",2)
    for x=9,10 do assert(t.S.observe({dim=0,x=x,y=63,z=0,side="down",block="minecraft:chest",at=1000})) end
    t.open()
    local function reach(id)
      for _=1,12 do
        local frame=t.frame(7,15,10)
        local found
        for _,b in ipairs(frame.buttons) do
          assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=15 and b.y+(b.h or 1)-1<=10,b.id)
          if b.label then assert(frame.rows[b.y].text:find(b.label,1,true),b.id.." overwritten") end
          if b.id==id then found=b end
        end
        if found then return found end
        t.input({id="from-next",from=7})
      end
      error("unreachable action "..id)
    end
    reach("queue-tools") t.input({id="queue-tools",from=7})
    reach("scan:12") t.input({id="scan:12",from=7})
    assert(t.active)
    reach("release")
    reach("queue-tools") reach("list")
    t.drain()
    reach("candidate:1") t.input({id="candidate:1",from=7})
    equal(t.S.views[7].draft.x,9)
    reach("add") t.input({id="add",from=7})
    equal(#t.mod.list(),2)
  end)
  test("P-U4-2 changed or removed pending points stop before their visit",function()
    for _,removed in ipairs({false,true}) do
      local t=boot() t.add("a",2) t.add("b",3) t.open() t.tap("test-all")
      if removed then assert(t.mod.remove("b")) else local p=t.S.copy(t.S.points[2]) p.x=7 assert(t.S.edit("b",p)) end
      t.drain() equal(t.visits,{"a"}) equal(t.S.queue.state,"stopped") equal(#t.S.queue.pending,0)
    end
  end)
  test("P-U4-2 an edit after inspection stops the queue even before the next tick",function()
    local t=boot() t.add("a",3) t.add("b",4) t.open() t.tap("test-all")
    while not t.S.task.inspected do t.step() end
    local p=t.S.copy(t.S.points[1]) p.x=8 assert(t.S.edit("a",p))
    while t.active do t.step() end
    t.mod.tick()
    equal({t.S.queue.state,t.S.queue.completed,#t.S.queue.pending},{"stopped",0,0})
    equal(t.visits,{"a"}) equal(t.cells.list("setup:12",100),{})
  end)
  test("P-U4-2 uncertainty, timeout and handoff failure retain recovery reservations",function()
    for _,kind in ipairs({"uncertain","timeout","handoff"}) do
      local t=boot() t.add("a",2) t.add("b",3) t.open() t.tap("test-all")
      if kind=="uncertain" then t.step(nil,true)
      elseif kind=="timeout" then local a=t.active t.active=nil t.report(a.lid,a.id,nil,{})
      else t.cells.handoff=function() return false,"disk full" end t.drain() end
      equal({t.S.queue.state,#t.S.queue.pending},{"stopped",0})
      assert(#t.cells.list("setup:12",100)>0)
      assert(#t.visits<=1)
    end
  end)
  test("P-U4-2 forgetting either device clears pending work",function()
    for _,id in ipairs({7,12}) do
      local t=boot() t.add("a",2) t.add("b",3) t.open() t.tap("test-all")
      local held=t.cells.list("setup:12",100)
      assert(t.mod.forget(id)) equal(#t.S.queue.pending,0)
      if id==7 then equal(t.cells.list("setup:12",100),held) t.drain() equal(t.visits,{"a"})
      else equal(t.S.queue.state,"stopped") assert(#t.cells.list("gps:12",100)>0) end
    end
  end)
  test("B9-U queue fixtures match the Python twin at every size and state",function()
    local setup=private(dofile("tests/ui/s3.lua"),"drops")
    for _,case in ipairs({{"M",57,24,"running",0},{"P",26,20,"running",0},{"XS",15,10,"running",0},
      {"stopping-XS",15,10,"stopping",1},{"stopped-P",26,20,"stopped",0},{"done-M",57,24,"done",0},
      {"facing-P",26,20,"facing",0},{"facing-XS",15,10,"facing",0},{"feedback-P",26,20,"feedback",0}}) do
      local t=setup()
      t.S.queueEnabled=function() return true end
      t.S.queue={completed=2,total=3,state=case[4],current={id="ore-west"}}
      if case[4]=="facing" then t.S.queue.state="stopped" t.S.compass={id=12} end
      t.tap({id=7},"testing")
      local view=t.S.views[7]
      view.fromPage=case[5] view.queueSelected={[t.S.points[1].id]=true}
      if case[4]=="feedback" then
        t.S.queue.state,t.S.queue.reason="stopped","stopped by operator"
        view.queueFeedback="selection unavailable"
      end
      local frame=t.render(case[2],case[3],{id=7})
      for _,b in ipairs(frame.buttons) do
        assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=case[2] and b.y+(b.h or 1)-1<=case[3],b.id)
        if b.label then assert(frame.rows[b.y].text:find(b.label,1,true),b.id.." overwritten") end
      end
      local diff=R.diff(R.load("tests/ui/fixtures/dropsqueue-"..case[1]..".txt"),capture(frame,case[2],case[3]))
      assert(#diff==0,table.concat(diff,"\n"))
      assert(#H.encode(frame)<16384)
    end
  end)
  test("B9-U review tools fixtures match the twin at 15x10",function()
    local setup=private(dofile("tests/ui/s3.lua"),"drops")
    for _,case in ipairs({{"tools-XS",nil,0},{"release-XS",12,0},{"found-XS",nil,1}}) do
      local t=setup()
      t.S.queueEnabled=function() return true end
      t.S.enabled=function() return true end
      if case[2] then t.S.task={id=case[2]} end
      t.tap({id=7},"testing")
      t.S.views[7].queueTools,t.S.views[7].fromPage=true,case[3]
      local frame=t.render(15,10,{id=7})
      local diff=R.diff(R.load("tests/ui/fixtures/dropsqueue-"..case[1]..".txt"),capture(frame,15,10))
      assert(#diff==0,table.concat(diff,"\n"))
    end
  end)
  test("B9-U narrow setup pages every stable ID and keeps BACK reachable",function()
    local t=boot()
    for i=1,64 do t.add("p"..i,i+1) end
    t.open()
    local seen={}
    for _=1,64 do
      for _,b in ipairs(t.frame(7,15,10).buttons) do
        local id=b.id:match("^queue%-select:(.+)$")
        if id then seen[id]=true end
        assert(b.x+b.w-1<=15 and b.y+(b.h or 1)-1<=10,b.id)
      end
      t.input({id="from-next",from=7})
    end
    local count=0 for _ in pairs(seen) do count=count+1 end
    equal(count,64)
    t.tap("list")
    t.input({id="test-all",from=7}) equal(t.sends,0)
  end)
  for _,scenario in ipairs({"success","missing","stop","restart"}) do
    test("P-U4-2 actual worker and lease lifecycle, "..scenario,function()
      local setup=private(dofile("tests/so/setup-ux.lua"),"setup")
      local F=dofile("tests/so/worker-fixture.lua")
      local a=setup(true)
      a.s.files["so-server.cfg"]=H.encode({setupMovement=true,dropsTestQueue=true,dropsSavedSetup=true,
        pos={dim="minecraft:overworld",x=40,y=64,z=10}})
      a.ui.input({text="scan 2",from=7}) a.ui.input({id="facing:1",from=7}) a.n.advance(4)
      local drops=a.s.env.SO.mods.drops
      for i=1,3 do
        assert(drops.add({id="p"..i,dim=0,x=42+i,y=63,z=10,side="down",kind="ore"}))
        if scenario~="missing" or i~=2 then a.n.world[(2+i)..",-1,0"]="minecraft:chest" end
      end
      local S=private(drops.tick,"S")
      local visits,verify={},S.verify
      S.verify=function(id,result) visits[#visits+1]=id return verify(id,result) end
      a.ui.input({id="testing",from=7}) a.ui.render(26,20,{id=7}) a.ui.input({id="test-all",from=7})
      local before=#F.sent(a.s,"lease.batch")
      local held=a.s.env.SO.mods.cells.list("setup:2",100)
      assert(#held>0,tostring(S.message).." / "..tostring(S.queue and S.queue.reason))
      if scenario=="stop" then
        local open=a.s.env.SO.mods.lease.status(2).open
        a.ui.render(26,20,{id=7}) a.ui.input({id="queue-stop",from=7})
        equal(a.s.env.SO.mods.lease.status(2).open,open)
        equal(a.s.env.SO.mods.cells.list("setup:2",100),held)
      elseif scenario=="restart" then
        a.s.boot("so-server.lua") a.n.advance(1)
        equal(private(a.s.env.SO.mods.drops.tick,"S").queue,nil)
        equal(#F.sent(a.s,"lease.batch"),before)
        assert(#a.s.env.SO.mods.cells.list("setup:2",100)>0)
        return
      end
      a.n.advance(15) F.check(a)
      equal(visits,scenario=="success" and {"p1","p2","p3"} or scenario=="missing" and {"p1","p2"} or {"p1"})
      equal(S.queue.state,scenario=="success" and "done" or "stopped")
      equal({a.t.pos.x,a.t.pos.y,a.t.pos.z,a.t.heading},{0,0,0,1})
      equal(a.s.env.SO.mods.cells.list("setup:2",100),{})
      equal(a.s.env.SO.mods.cells.owner(40,64,10,"minecraft:overworld"),"gps:2")
    end)
  end
end
