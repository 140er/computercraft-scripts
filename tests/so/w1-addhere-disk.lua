local H = dofile("tests/so/harness.lua")
local F = dofile("tests/so/worker-fixture.lua")
local D = dofile("tests/so/dug-fixture.lua")
local modules = {"so-plan.lua","so-ui.lua","so-log.lua","so-mod-state.lua","so-mod-lease.lua",
  "so-mod-cells.lua","so-mod-display.lua","so-mod-drops.lua","so-mod-mine.lua","so-mine-plan.lua",
  "so-mod-lumber.lua","so-lumber-plan.lua"}
local function setup(opts)
  local a = F.setup(opts,modules)
  a.t.files["so-worker.cfg"] = H.encode({dim="minecraft:overworld"})
  a.s.files["so-server.cfg"] = H.encode({pos={dim="minecraft:overworld",x=0,y=64,z=0}})
  a.n.advance(3)
  return a
end
local function hello(a, fix)
  local seen=F.sent(a.t,"hello")[#F.sent(a.t,"hello")].body
  local body = {role="turtle",journal=a.t.files["so-journal"] and F.journal(a.t) or seen.journal,capabilities=seen.capabilities,fuel=1000,gps=fix and {dim=fix.dim or "minecraft:overworld",x=fix.x,y=fix.y,z=fix.z}}
  local proto = a.t.env.dofile("so-proto.lua")
  local msg = proto.build(string.rep("a",64),"hello",body)
  a.t.env.rednet.send(1,proto.encode(msg),"so")
  a.n.flush()
end
local function gps(a)
  a.t.env.gps = {locate=function() return a.t.pos.x+40,a.t.pos.y+64,a.t.pos.z+10 end}
  hello(a,{x=a.t.pos.x+40,y=a.t.pos.y+64,z=a.t.pos.z+10})
end
local function state()
  local net = H.new()
  local m = net.machine({id=1,directories=true})
  m.install({"so-store.lua","so-log.lua","so-mod-state.lua"})
  m.env.SO = {mods={},proto={ser=H.encode},now=function() return net.time end,breathe=function() end,store=m.env.dofile("so-store.lua")}
  local s = m.env.dofile("so-mod-state.lua")
  m.env.SO.mods.state = s
  return s,m,net
end
local function fill(m, ratio)
  m.files.ballast = nil
  local used = 0
  for _, text in pairs(m.files) do used=used+#text end
  m.files.ballast = string.rep("x",math.max(0,math.floor(m.capacity*ratio)-used))
end
local function press(screen, w, h, id, session)
  local frame = screen.render(w,h,session)
  for _, b in ipairs(frame.buttons) do
    if b.id == id then
      assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h,"button outside frame")
      assert(frame.rows[b.y].text:find(b.label,1,true),"button is not drawn")
      screen.input({id=id,x=b.x,y=b.y,session=session})
      return
    end
  end
  error("missing drawn button " .. id)
end
return function(test,equal)
  for _, role in ipairs({"mining","lumber"}) do
    for _, size in ipairs({{26,20},{29,12}}) do
      test("add here "..role.." drawn probe at "..size[1].."x"..size[2],function()
        local a = setup({id=2,modem=true,turtle=true,capacity=1000000,facing=1})
        gps(a)
        local screen = a.s.env.SO.mods.display.screen(role)
        local session = {}
        -- Route A: the setup tab lists unassigned turtles in READY with an add chip; setup-next pages it.
        press(screen,size[1],size[2],"tab:setup",session)
        do
          for _=1,3 do
            local found=false
            for _,b in ipairs(screen.render(size[1],size[2],session).buttons) do if b.id=="here:2" then found=true end end
            if found then break end
            press(screen,size[1],size[2],"setup-next",session)
          end
        end
        press(screen,size[1],size[2],"here:2",session)
        a.n.advance(1)
        F.check(a)
        local path = role=="mining" and "so-data/mine/job" or "so-data/lumber/job"
        local job = assert(a.s.env.SO.store.store(path,function() return true end).value)
        local pose = role=="mining" and job.turtles["2"].pose or job.turtles["2"].turtle.pose
        equal({pose.x,pose.y,pose.z,pose.facing},{41,64,10,1})
        equal(a.t.pos.x,1)
        equal(a.s.env.SO.mods.lease.candidates(),{})
      end)
    end
  end
  test("lumber GPS add retains an existing worker and reserves the new pose",function()
    local a=setup({id=2,modem=true,turtle=true,capacity=1000000,facing=1})
    gps(a)
    local screen=a.s.env.SO.mods.display.screen("lumber")
    screen.input({text="add 3 60 64 10 n"})
    screen.input({text="add 2"})
    a.n.advance(1) F.check(a)
    local job=assert(a.s.env.SO.store.store("so-data/lumber/job",function() return true end).value)
    assert(job.turtles["2"] and job.turtles["3"])
    equal(job.turtles["2"].turtle.pose.x,41)
    equal(job.turtles["3"].turtle.pose.x,60)
  end)
  test("add here refuses no GPS and uncertain journals without moving",function()
    local a=setup()
    local screen=a.s.env.SO.mods.display.screen("mining")
    screen.input({text="add 2"})
    local frame=screen.render(29,12)
    -- Route A shows the refusal as the alert above the action row, wrapped onto two rows when long.
    assert((frame.rows[10].text.." "..frame.rows[11].text):find("no fresh GPS",1,true))
    equal(a.t.pos.z,0)
    gps(a)
    local lease=a.s.env.SO.mods.lease
    lease.handlers.hello({from=2,body={role="turtle",gps={dim="minecraft:overworld",x=40,y=64,z=10},journal={id="uncertain",uncertain=true}}})
    local p,err=lease.world(2,"minecraft:overworld")
    equal(p,nil);assert(err:find("pose uncertain",1,true))
  end)
  test("GPS movement resolves facing in every orientation without trusting local north",function()
    local a=setup()
    local lease=a.s.env.SO.mods.lease
    for f=0,3 do
      local dx,dz=({[0]=0,1,0,-1})[f],({[0]=-1,0,1,0})[f]
      lease.handlers.hello({from=2,body={role="turtle",gps={dim="minecraft:overworld",x=40,y=64,z=10},journal={id="a",seq=0,pose={x=0,y=0,z=0,f=0}}}})
      lease.handlers.hello({from=2,body={role="turtle",gps={dim="minecraft:overworld",x=40+dx,y=64,z=10+dz},journal={id="b",seq=1,pose={x=0,y=0,z=-1,f=0}}}})
      equal(assert(lease.world(2,"minecraft:overworld")).facing,f)
    end
  end)
  test("blocked GPS probe never digs or adds a turtle",function()
    local a=setup();gps(a)
    a.t.env.turtle.forward=function() return false,"Movement obstructed" end
    local pose,why
    a.s.env.SO.mods.lease.locate(2,"minecraft:overworld",function(p,e) pose,why=p,e end)
    a.n.advance(1);F.check(a)
    equal(pose,nil);equal(why,"probe blocked; use explicit add")
    equal(a.t.pos.z,0)
  end)
  test("drop from turtle uses chest cell for four headings and down",function()
    local a=setup()
    a.s.files["so-server.cfg"]=H.encode({pos={dim="minecraft:overworld",x=0,y=64,z=0}})
    local lease=a.s.env.SO.mods.lease
    local ui=a.s.env.SO.mods.display.screen("generic")
    ui.input({id="new"})
    for f=0,3 do
      local dx,dz=({[0]=0,1,0,-1})[f],({[0]=-1,0,1,0})[f]
      lease.handlers.hello({from=2,body={role="turtle",gps={dim="minecraft:overworld",x=40,y=64,z=10},journal={id="anchor",seq=f,pose={x=40,y=64,z=10,f=f},recovery={outcome="anchored"}}}})
      press(ui,29,12,"from:2")
      press(ui,29,12,"add")
      local list=a.s.env.SO.mods.drops.list();local p=list[#list]
      equal({p.x,p.y,p.z},{40+dx,64,10+dz})
    end
    ui.input({id="side"});press(ui,26,20,"from:2");press(ui,26,20,"add")
    local list=a.s.env.SO.mods.drops.list();local p=list[#list]
    equal({p.x,p.y,p.z,p.side},{40,63,10,"down"})
  end)
  test("disk ledger screen has drawn controls and exact byte counts at compact sizes",function()
    local a=setup()
    local state=a.s.env.SO.mods.state
    local screen=a.s.env.SO.mods.display.screen("disk")
    state.tick(a.n.time)
    for _,size in ipairs({{26,20},{29,12}}) do
      local f=screen.render(size[1],size[2])
      local text={};for _,row in ipairs(f.rows) do text[#text+1]=row.text end;text=table.concat(text,"\n")
      for _,key in ipairs({"log","snapshots","cells","jobs","keys","other"}) do
        assert(text:find(key:upper(),1,true));assert(text:find(tostring(state.disk().stores[key]),1,true))
      end
      press(screen,size[1],size[2],"status")
    end
  end)
  test("GPS loss after the probe keeps reservations and refuses assignment",function()
    local a=setup();gps(a)
    a.t.env.gps.locate=function() return nil end
    local pose,why
    local lease=a.s.env.SO.mods.lease
    lease.locate(2,"minecraft:overworld",function(p,e) pose,why=p,e end)
    a.n.advance(1);F.check(a)
    equal(pose,nil);equal(why,"probe pose unknown; use explicit add")
    assert(#a.s.env.SO.mods.cells.list("gps:2",10)==5)
    local ui=a.s.env.SO.mods.display.screen("mining")
    ui.input({text="add 2 40 64 9 n"})
    equal(#a.s.env.SO.mods.cells.list("gps:2",10),0)
  end)
  test("pressure heartbeats persist fuel changes and resume below pressure",function()
    local s,m,n=state()
    s.handlers.hello({from=2,body={role="turtle",fuel=1000,journal={id="same"}}})
    local count=#s.history.page({count=50}).entries
    fill(m,0.85)
    for i=1,5 do
      n.time=n.time+60001
      s.handlers.hello({from=2,body={role="turtle",fuel=1000-i,journal={id="same"}}})
      equal(s.get("machines/2").seen,n.time)
    end
    equal(#s.history.page({count=50}).entries,count+5)
    fill(m,0.79);n.time=n.time+60001
    s.handlers.hello({from=2,body={role="turtle",fuel=995,journal={id="same"}}})
    equal(#s.history.page({count=50}).entries,count+6)
  end)
  for _,size in ipairs({{26,20},{29,12}}) do
    test("drawn status DISK opens ledger through the real display at "..size[1].."x"..size[2],function()
      local a=setup()
      local client=a.n.machine({id=3,modem=true,width=size[1],height=size[2],capacity=1000000})
      client.install({"display.lua","so-proto.lua","so-store.lua","so-pair.lua"})
      for path,text in pairs(a.s.files) do if path:match("^lib/ccryptolib/") then client.files[path]=text end end
      local key=string.rep("a",64)
      assert(a.s.env.SO.pair.remember(3,key))
      client.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
      client.boot("display.lua");a.n.flush();a.n.advance(2)
      local function frame()
        for i=#a.s.sent,1,-1 do
          local packet=a.s.sent[i]
          if packet.id==3 and packet.payload.t=="view.frame" then return packet.payload.body end
        end
        error("no display frame")
      end
      -- Roles change only by assignment; the ledger opens as a page of the status role.
      assert(a.s.env.SO.mods.display.assign(3,"status"));a.n.advance(1)
      local picture=frame();local button
      equal(picture.role,"status")
      for _,b in ipairs(picture.buttons) do if b.id=="disk" then button=b end end
      assert(button,"status has no DISK control")
      assert(picture.rows[button.y].text:lower():find("disk",1,true),"DISK control is not drawn")
      client.inbox[#client.inbox+1]=table.pack("mouse_click",1,button.x,button.y)
      a.n.flush();assert(not client.error,tostring(client.error));equal(frame().role,"status")
      local text={};for _,row in ipairs(frame().rows) do text[#text+1]=row.text end
      assert(table.concat(text,"\n"):find("SNAPSHOTS",1,true))
      -- The ledger draws its own way back to status.
      button=nil
      for _,b in ipairs(frame().buttons) do if b.id=="status" or b.id=="visit-back" then button=b end end
      assert(button,"no drawn return to status")
      client.inbox[#client.inbox+1]=table.pack("mouse_click",1,button.x,button.y)
      a.n.flush();text={};for _,row in ipairs(frame().rows) do text[#text+1]=row.text end
      assert(not table.concat(text,"\n"):find("SNAPSHOTS",1,true),"return did not leave the ledger")
    end)
  end
  test("oversized events refuse explicitly without a sticky write fault",function()
    local s,m=state()
    local ok,err=s.emit("huge",string.rep("x",70000))
    equal(ok,false);assert(err:find("refused",1,true));equal(s.get("huge"),nil)
    equal(s.disk().pending,0);equal(s.disk().error,nil);assert(s.canWork());assert(s.canStart())
    equal(s.get("disk.alert").error,"event exceeds log budget")
    assert(m.log[#m.log]:find("DISK event refused",1,true))
    assert(s.emit("small",1));assert(s.canWork());equal(s.get("disk.alert"),nil)
  end)
  test("pending events block new moves while a stationary recovery park remains available",function()
    local a=setup();local state=a.s.env.SO.mods.state;local lease=a.s.env.SO.mods.lease
    a.s.capacity=500000;fill(a.s,0.99);assert(state.emit("recovery",{step=2}))
    local id,err=lease.send(2,{{op="forward"}})
    equal(id,nil);equal(err,"DISK events pending")
    assert(lease.send(2,{{op="inspectDown"}},{recover=true}))
    a.n.advance(1);equal(a.t.pos.z,0)
  end)
  for _,role in ipairs({"mine","lumber"}) do
    for _,failure in ipairs({"handoff","assignment"}) do
      test(role.." probe keeps durable reservations after "..failure.." save failure",function()
        local a=setup()
        F.send(a,{{op="forward"},{op="forward"},{op="forward"}});a.n.advance(1)
        gps(a)
        local open=a.s.env.fs.open
        local writes=0
        a.s.env.fs.open=function(path,mode)
          if mode=="w" and path=="so-data/cells/res.tmp" then
            writes=writes+1
            if failure=="handoff" and writes>=2 then return nil,"disk full" end
          end
          if mode=="w" and failure=="assignment" and path=="so-data/"..role.."/job.tmp" then return nil,"disk full" end
          return open(path,mode)
        end
        local screen=a.s.env.SO.mods.display.screen(role=="mine" and "mining" or role)
        screen.input({text="add 2"});a.n.advance(1)
        assert(not a.s.env.SO.mods[role].assigned(2))
        local cells=a.s.env.SO.mods.cells
        local standing=cells.owner(40,64,6,"minecraft:overworld")
        equal(standing,failure=="handoff" and "gps:2" or role..":2")
        equal(#cells.list("gps:2",10),failure=="handoff" and 5 or 4)
        a.s.env.fs.open=open
        local recovered=a.s.env.dofile("so-mod-cells.lua")
        equal(recovered.owner(40,64,6,"minecraft:overworld"),standing)
        equal(a.t.pos.z,-4);equal(#F.journal(a.t).moves,4)
        assert(F.journal(a.t).park)
        a.n.kill(a.s);a.n.advance(120)
        assert(a.t.alive(),tostring(a.t.error))
        equal(a.t.pos.z,-4);equal(#F.journal(a.t).moves,4)
      end)
    end
  end
  for _,outcome in ipairs({"success","GPS loss","report loss","blocked"}) do
    test("GPS probe stays parked with earlier moves after "..outcome,function()
      local a=setup()
      F.send(a,{{op="forward"},{op="forward"},{op="forward"}});a.n.advance(1)
      gps(a)
      if outcome=="GPS loss" then a.t.env.gps.locate=function() return nil end end
      if outcome=="blocked" then a.t.env.turtle.forward=function() return false,"Movement obstructed" end end
      if outcome=="report loss" then
        local send=a.t.env.rednet.send
        a.t.env.rednet.send=function(id,wire,protocol)
          if type(wire)=="table" and wire.t=="step.report" then return true end
          return send(id,wire,protocol)
        end
      end
      local called,pose,why=false
      local lease=a.s.env.SO.mods.lease
      lease.locate(2,"minecraft:overworld",function(p,e) called,pose,why=true,p,e end)
      a.n.advance(27);F.check(a)
      assert(called)
      if outcome=="success" then assert(pose);equal(why,nil) else equal(pose,nil);assert(why) end
      local z=outcome=="blocked" and -3 or -4
      equal(a.t.pos.z,z);assert(F.journal(a.t).park)
      equal(#a.s.env.SO.mods.cells.list("gps:2",10),outcome=="blocked" and 0 or 5)
      a.n.kill(a.s);a.n.advance(120)
      assert(a.t.alive(),tostring(a.t.error))
      equal(a.t.pos.z,z);equal(#F.journal(a.t).moves,-z)
      assert(#F.sent(a.t,"beacon")>=4)
    end)
  end
  test("GPS probe refuses workers without stationary batch support",function()
    local a=setup();gps(a)
    local lease=a.s.env.SO.mods.lease
    local body=F.sent(a.t,"hello")[#F.sent(a.t,"hello")].body
    equal(body.capabilities.parkBatch,true)
    equal(body.capabilities.setupFence,true)
    body.capabilities=nil
    lease.handlers.hello({from=2,body=body})
    local called=false
    lease.locate(2,"minecraft:overworld",function(p,e)
      called=true;equal(p,nil);equal(e,"probe needs worker update; use explicit add")
    end)
    assert(called);equal(#a.s.env.SO.mods.cells.list("gps:2",10),0)
    a.n.advance(1);equal(a.t.pos.z,0)
  end)
  test("uncertain recovery add retains the probe standing reservation when fresh reserve fails",function()
    local a=setup();gps(a)
    a.t.env.gps.locate=function() return nil end
    local lease=a.s.env.SO.mods.lease
    a.s.env.SO.mods.display.screen("mining").input({text="add 2"});a.n.advance(1)
    lease.handlers.beacon({from=2,body={uncertain=true,journal="recover",fuel=999}})
    local cells=a.s.env.SO.mods.cells
    cells.reserve=function() return false,"disk full" end
    a.s.env.SO.mods.display.screen("mining").input({text="add 2 40 64 9 n"})
    equal(cells.owner(40,64,9,"minecraft:overworld"),"mine:2")
  end)
  test("dimensionless and other-dimension GPS refuse add and drop without moving",function()
    local a=setup();gps(a)
    local lease=a.s.env.SO.mods.lease
    local journal=F.sent(a.t,"hello")[#F.sent(a.t,"hello")].body.journal
    for _,dim in ipairs({false,"minecraft:the_nether"}) do
      lease.handlers.hello({from=2,body={role="turtle",journal=journal,gps={x=40,y=64,z=10,dim=dim or nil}}})
      local p,err=lease.world(2,"minecraft:overworld")
      equal(p,nil);assert(err:find("dimension",1,true))
      local ui=a.s.env.SO.mods.display.screen("generic")
      ui.input({id="new"});press(ui,29,12,"from:2")
      -- Route A shows the editor's refusal in the row above its actions.
      assert(ui.render(29,12).rows[11].text:find("dimension",1,true))
      lease.locate(2,"minecraft:overworld",function(pose,why) equal(pose,nil);assert(why:find("dimension",1,true)) end)
      equal(a.t.pos.z,0)
    end
    a.s.env.SO.mods.display.screen("mining").input({text="add 2 40 64 10 n"})
    assert(a.s.env.SO.mods.mine.assigned(2))
  end)
  test("oversized event behind a full-disk backlog refuses before folding and cannot poison retry",function()
    local s,m,n=state();m.capacity=50000;fill(m,0.99)
    assert(s.emit("small",1))
    local ok,err=s.emit("huge",string.rep("x",70000))
    equal(ok,false);assert(err:find("refused",1,true));equal(s.get("huge"),nil);equal(s.disk().pending,1)
    m.files.ballast=nil;n.time=n.time+5000;s.tick(n.time)
    equal(s.disk().pending,0);assert(s.canWork());equal(#s.history.page({}).entries,1)
  end)
  test("AR disk warning survives alert timeout and disabled event alerts",function()
    local s,m,n=state()
    m.install({"so-mod-ar.lua"})
    assert(m.env.SO.store.store("so-data/ar",function() return true end).save({turtles=false,leases=false,drops=false,alerts=false}))
    local elements,ar={},{}
    for _,method in ipairs({"drawText2D","drawRect2D"}) do ar[method]=function(id,...) elements[id]={...} end end
    ar.delete=function(id) elements[id]=nil end;ar.update=function() end
    m.env.peripheral.find=function(kind) if kind=="ar_controller" then return ar end end
    local mod=m.env.dofile("so-mod-ar.lua")
    fill(m,0.85);s.tick(n.time);mod.tick(n.time)
    assert(elements["alert:disk.alert"])
    n.time=n.time+301000;s.tick(n.time);mod.tick(n.time)
    assert(elements["alert:disk.alert"])
    fill(m,0.79);n.time=n.time+1000;s.tick(n.time);mod.tick(n.time)
    equal(elements["alert:disk.alert"],nil)
  end)
  test("lost probe keeps all cells across lease expiry and permits explicit recovery after reboot",function()
    local a=setup();gps(a);a.n.kill(a.t)
    local why
    local lease=a.s.env.SO.mods.lease
    lease.locate(2,"minecraft:overworld",function(_,err) why=err end)
    a.n.advance(27)
    equal(why,"GPS probe lost; retry add")
    equal(#a.s.env.SO.mods.cells.list("gps:2",10),5)
    lease=a.s.env.dofile("so-mod-lease.lua")
    a.s.env.SO.mods.lease=lease
    a.s.env.SO.mods.display.screen("mining").input({text="add 2 40 64 10 n"})
    equal(#a.s.env.SO.mods.cells.list("gps:2",10),0)
    equal(a.s.env.SO.mods.cells.owner(40,64,10,"minecraft:overworld"),"mine:2")
  end)
  test("disk pressure enters, clears, and ledger sums include generations",function()
    local s,m,n=state()
    for path,bytes in pairs({["so-data/log/000001.bak"]=10,["so-data/snap/latest.tmp"]=20,
      ["so-data/cells/d/0_0_0"]=30,["so-data/mine/job.bak"]=40,["so-keys.bak"]=50}) do m.files[path]=string.rep("x",bytes) end
    fill(m,0.85);s.tick(n.time)
    local d=s.disk();assert(d.pressure);equal(d.stores.log,10);equal(d.stores.snapshots,20)
    equal(d.stores.cells,30);equal(d.stores.jobs,40);equal(d.stores.keys,50)
    local total=0;for _,bytes in pairs(d.stores) do total=total+bytes end;equal(total,d.used)
    equal(s.get("disk.alert").text,"DISK pressure")
    fill(m,0.79);s.tick(n.time);assert(not s.disk().pressure);equal(s.get("disk.alert"),nil)
  end)
  test("tiny full disk queues events, blocks work, and saves them exactly once after relief",function()
    local s,m,n=state();m.capacity=50000;fill(m,0.99)
    assert(s.emit("ore",{count=7}));assert(s.emit("recovery",{step=2}))
    equal(s.get("ore").count,7);equal(s.disk().pending,2);assert(not s.canWork())
    equal(#s.history.page({count=50}).entries,2)
    assert(s.get("disk.alert").text:find("events pending",1,true))
    m.files.ballast=nil;n.time=n.time+5000;s.tick(n.time)
    equal(s.disk().pending,0);assert(s.canWork())
    local reboot=m.env.dofile("so-mod-state.lua")
    equal(reboot.get("ore").count,7);equal(reboot.get("recovery").step,2)
    local events=reboot.history.page({count=50}).entries
    equal(#events,2);equal(events[1].seq,1);equal(events[2].seq,2)
  end)
  test("full disk backlog is bounded and overflow refusal stays visible",function()
    local s,m=state();m.capacity=50000;fill(m,0.99)
    for i=1,256 do assert(s.emit("event",{n=i})) end
    local ok,err=s.emit("event",{n=257});equal(ok,false);assert(err:find("event refused",1,true))
    equal(s.get("event").n,256);equal(s.disk().pending,256);assert(s.disk().pendingBytes<=262144)
    assert(m.log[#m.log]:find("DISK event refused",1,true))
  end)
  test("keep under disk pressure asks for dug consent again",function()
    local cells,m,n=D.setup(nil,500)
    m.env.SO.mods.state={disk=function() return {pressure=true} end}
    assert(cells.tick(n.time));assert(cells.decideRetirement(cells.retirement().id,"keep"))
    n.time=n.time+60001;assert(cells.tick(n.time))
    equal(cells.retirement().status,"snoozed");equal(cells.counts().dug,500)
    n.time=n.time+540000;assert(cells.tick(n.time))
    equal(cells.retirement().status,"pending");equal(cells.counts().dug,500)
  end)
end
