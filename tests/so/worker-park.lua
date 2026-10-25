local F = dofile("tests/so/worker-fixture.lua")
local H = dofile("tests/so/harness.lua")
local P = dofile("so-plan.lua")
local function copy(v)
  if type(v)~="table" then return v end
  local out={} for k,x in pairs(v) do out[k]=copy(x) end return out
end
local function fixture(name, enabled)
  local f={now=1000,calls={},jobs={},fail=nil,enabled=enabled,logs={}}
  local net=H.new()
  local server=net.machine({id=1,modem=true})
  server.install({"so-plan.lua","so-ui.lua","so-mine-plan.lua","so-lumber-plan.lua",
    "so-mod-cells.lua","so-mod-lease.lua","so-mod-mine.lua","so-mod-lumber.lua","so-mod-build.lua"})
  local env=server.env
  local dim="minecraft:overworld"
  local function pose(id) return {dim=dim,x=id*4,y=2,z=4,facing=1} end
  local function turtle(id) return {id=id,pose=pose(id),frame={dim=dim,ox=0,oy=0,oz=0,rot=0}} end
  local job
  if name=="mine" then
    job={dim=dim,homeSet=true,home={x=0,y=2,z=0,facing=0},bottom=2,length=16,mode="fast",ores={},
      progress={nextBranch=2,done=0},running=true,turtles={}}
    for id=2,3 do job.turtles[tostring(id)]={pose=pose(id),frame=turtle(id).frame,inv={},fuel=4000,
      state="mining",branch=id-2,route={pose(id),{dim=dim,x=id*4+2,y=2,z=4,facing=1}},index=2} end
  elseif name=="lumber" then
    job={dim=dim,spots={},area={x1=0,x2=30,z1=4,z2=4},ground=0,running=true,turtles={}}
    for id=2,3 do job.turtles[tostring(id)]={turtle=turtle(id),phase="scan",inv={},fuel=4000,
      target={dim=dim,x=id*4+2,y=2,z=4}} end
  else
    job={dim=dim,cursor=1,running=true,phase="check",inv={{slot=1,name="minecraft:stone",count=64}},fuel=4000,
      material="minecraft:stone",home=pose(2),turtle=turtle(2),blueprint={dim=dim,shape="floor",x1=8,x2=10,y1=0,y2=0,z1=4,z2=4}}
  end
  f.inventory=copy(job.inv or {})
  local jobPath="so-data/"..name.."/job"
  f.jobs[jobPath]=copy(job)
  local mods={}
  env.SO={now=function() return f.now end,breathe=function() end,mods=mods,pair={key=function() return "paired" end},
    proto={build=function(_,t,b) return {t=t,body=b} end,encode=function(v) return v end},
    store={copy=copy,read=function(path) if path=="so-server.cfg" then return {workerPark=f.enabled~=false} end end,
      store=function(path)
        local value=copy(f.jobs[path])
        if path==jobPath then job=value end
        return {value=value,save=function(nextValue)
          if f.fail==path then return false,"injected disk failure" end
          f.jobs[path]=copy(nextValue) return true
        end}
      end}}
  env.print=function(text) f.logs[#f.logs+1]=text end
  env.rednet.send=function() return true end
  mods.state={emit=function() return true end,get=function() end,canStart=function() return true end}
  mods.display={screen=function(_,_,input) f.input=function(text) input({text=text}) end end}
  mods.cells=env.dofile("so-mod-cells.lua")
  mods.lease=env.dofile("so-mod-lease.lua")
  local send=mods.lease.send
  mods.lease.send=function(id,steps,opts)
    local lid,err=send(id,steps,opts)
    if lid then f.calls[#f.calls+1]={id=lid,worker=id,steps=copy(steps),opts=copy(opts)} end
    return lid,err
  end
  mods[name]=env.dofile(({mine="so-mod-mine.lua",lumber="so-mod-lumber.lua",build="so-mod-build.lua"})[name])
  f.job,f.mods,f.env,f.name=job,mods,env,name
  f.row=function(id) if name=="build" then return job.turtle end return job.turtles[tostring(id or 2)] end
  f.pose=function(id) local row=f.row(id) return name=="mine" and row.pose or row.turtle and row.turtle.pose or row.pose end
  f.tick=function() f.now=f.now+100 mods[name].tick(f.now) end
  f.pending=function(id)
    local lid=mods.lease.status(id or 2).open
    for i=#f.calls,1,-1 do if f.calls[i].id==lid then return f.calls[i] end end
  end
  f.journals, f.workerPoses = {}, {[2]=pose(2),[3]=pose(3)}
  f.hello=function(id)
    local at=f.workerPoses[id]
    mods.lease.handlers.hello({from=id,body={role="worker",dim=dim,
      capabilities={parkBatch=true,setupFence=true},journal={id=f.journals[id] or "initial-"..id,
        pose={x=at.x,y=at.y,z=at.z,f=at.facing}}}})
  end
  f.report=function(id,missing)
    id=id or 2
    local q=assert(f.pending(id),"no pending report")
    local at=copy(f.workerPoses[id])
    local results={}
    for i,step in ipairs(q.steps) do
      at=P.apply(at,step.op)
      results[i]={ok=not step.op:match("^inspect"),err=step.op:match("^inspect") and "No block to inspect" or nil}
    end
    f.journals[id]="report-"..q.id
    f.workerPoses[id]=copy(at)
    mods.lease.handlers["step.report"]({from=id,body={lease=q.id,results=results,journal=f.journals[id],
      pose=not missing and {x=at.x,y=at.y,z=at.z,f=at.facing} or nil,fuel=4000,inv=copy(f.inventory)}})
    return q
  end
  f.restart=function(workerPark)
    if workerPark~=nil then f.enabled=workerPark end
    mods.cells=env.dofile("so-mod-cells.lua")
    mods.lease=env.dofile("so-mod-lease.lua")
    local again=mods.lease.send
    mods.lease.send=function(id,steps,opts)
      local lid,err=again(id,steps,opts)
      if lid then f.calls[#f.calls+1]={id=lid,worker=id,steps=copy(steps),opts=copy(opts)} end
      return lid,err
    end
    mods[name]=env.dofile(({mine="so-mod-mine.lua",lumber="so-mod-lumber.lua",build="so-mod-build.lua"})[name])
    f.job=job
    f.hello(2) if name~="build" then f.hello(3) end
    if name=="build" then mods.build.handlers.hello({from=2,body={capabilities={parkBatch=true}}}) end
    f.tick()
  end
  f.hello(2) if name~="build" then f.hello(3) end
  f.tick()
  f.report(2) if name~="build" then f.report(3) end
  if name=="build" then mods.build.handlers.hello({from=2,body={capabilities={parkBatch=true}}}) end
  return f
end
local function moving(f)
  for _=1,30 do
    f.tick()
    local q=f.pending()
    if q then
      for _,step in ipairs(q.steps) do
        if step.op=="forward" or step.op=="down" or step.op=="up" then return q end
      end
      f.report()
    end
    if f.name~="build" and f.pending(3) then f.report(3) end
  end
  error("worker did not start moving")
end
local function parkReport(f)
  for _=1,6 do
    f.tick()
    local q=f.pending()
    if q then
      local stationary=#q.steps==1 and q.steps[1].op=="inspectDown"
      f.report()
      if stationary and not q.opts.recover or stationary and f.row().parkConfirmed then return end
    end
  end
  error("worker did not confirm park")
end
local function moduleTests(test,equal)
  for _,name in ipairs({"mine","lumber","build"}) do
    test(name.." running worker removes its row only after the park report and releases leases and cells",function()
      local f=fixture(name) local q=moving(f)
      local held=f.mods.cells.list(name..":2",100000) assert(#held>0)
      f.input("remove 2") f.tick()
      assert(f.row()) equal(f.pending().id,q.id)
      for _,p in ipairs(held) do equal(f.mods.cells.owner(p.x,p.y,p.z,p.dim),name..":2") end
      f.report() assert(f.row())
      f.tick() assert(f.row())
      local park=assert(f.pending()) equal(#park.steps,1) equal(park.steps[1].op,"inspectDown")
      local at=copy(f.pose(2)) f.report() assert(f.row())
      f.tick() equal(f.row(),nil) equal(f.mods.lease.status(2).open,nil)
      equal(#f.mods.cells.list(name..":2",100000),0)
      equal(f.mods.cells.owner(at.x,at.y,at.z,at.dim),"gps:2")
    end)
    test(name.." park waits for the batch and resume brings the worker back",function()
      local f=fixture(name) local q=moving(f)
      f.input("park 2") f.tick() equal(f.pending().id,q.id) assert(not f.row().parkConfirmed)
      f.report() parkReport(f) assert(f.row().parkConfirmed)
      if name=="build" then equal(f.row().state,"parked")
      else equal(f.mods[name].turtleView()["2"].state,"parked") end
      f.input("resume 2") assert(not f.row().paused) assert(not f.row().removeRequested)
      moving(f) assert(f.job.running)
    end)
    test(name.." lost mid-route worker retains its row and reservations without a park report",function()
      local f=fixture(name) moving(f)
      f.input("remove 2")
      f.now=f.now+71000 f.mods.lease.tick(f.now)
      f.tick() assert(f.row()) assert(f.pending()) assert(f.pending().opts.recover)
      local count=#f.mods.cells.list(name..":2",100000) assert(count>0)
      for _=1,3 do f.tick() end
      assert(f.row()) equal(#f.mods.cells.list(name..":2",100000),count)
      f.report(2,true) f.tick() assert(f.row()) assert(not f.row().parkConfirmed)
    end)
    test(name.." remove retries reservation and job save failures with the row retained",function()
      for _,path in ipairs({"so-data/cells/res","so-data/"..name.."/job"}) do
        local f=fixture(name) moving(f) f.input("remove 2") f.report() parkReport(f)
        f.fail=path f.tick() assert(f.row(),path)
        f.fail=nil f.tick() equal(f.row(),nil)
      end
    end)
    test(name.." restart requires a fresh park report before pending removal",function()
      local f=fixture(name) moving(f) f.input("remove 2") f.report() parkReport(f)
      f.restart() assert(f.row()) assert(not f.row().parkConfirmed)
      f.tick() assert(f.row())
      f.report() parkReport(f) f.tick() equal(f.row(),nil)
    end)
    test(name.." failed removal save then restart reclaims the cell and waits for a new park report",function()
      local f=fixture(name) moving(f) f.input("remove 2") f.report() parkReport(f)
      local at=copy(f.pose(2))
      f.fail="so-data/"..name.."/job" f.tick() assert(f.row())
      equal(f.mods.cells.owner(at.x,at.y,at.z,at.dim),"gps:2")
      f.fail=nil f.restart() assert(f.row()) assert(not f.row().parkConfirmed)
      equal(f.mods.cells.owner(at.x,at.y,at.z,at.dim),name..":2")
      assert(f.pending().opts.recover) f.report() f.tick() assert(f.row())
      assert(not f.row().parkConfirmed)
      local q=assert(f.pending()) equal(#q.steps,1) equal(q.steps[1].op,"inspectDown")
      f.report() f.tick() equal(f.row(),nil)
      equal(#f.mods.cells.list(name..":2",100000),0)
      equal(f.mods.cells.owner(at.x,at.y,at.z,at.dim),"gps:2")
    end)
    test(name.." recovery retries a failed standing-cell reclaim without deleting the row",function()
      local f=fixture(name) moving(f) f.input("remove 2") f.report() parkReport(f)
      local at=copy(f.pose(2))
      f.fail="so-data/"..name.."/job" f.tick() assert(f.row())
      f.fail="so-data/cells/res" f.restart() assert(f.row()) equal(f.pending(),nil)
      equal(f.mods.cells.owner(at.x,at.y,at.z,at.dim),"gps:2")
      f.fail=nil f.tick() assert(f.pending().opts.recover)
      equal(f.mods.cells.owner(at.x,at.y,at.z,at.dim),name..":2")
      f.report() parkReport(f) f.tick() equal(f.row(),nil)
    end)
    test(name.." flag off at restart clears and logs saved pause and removal state",function()
      for _,command in ipairs({"park 2","remove 2"}) do
        local f=fixture(name) moving(f) f.input(command) f.report() parkReport(f)
        f.restart(false) assert(f.row()) assert(not f.row().paused) assert(not f.row().removeRequested)
        assert(not f.row().parkConfirmed)
        local saved=f.jobs["so-data/"..name.."/job"]
        local row=name=="build" and saved.turtle or saved.turtles["2"]
        assert(not row.paused) assert(not row.removeRequested) assert(not row.parkConfirmed)
        assert(table.concat(f.logs,"\n"):find("workerPark off; cleared park state for 2",1,true))
        f.report() moving(f) assert(f.row()) assert(f.job.running)
      end
    end)
    test(name.." flag off before the first park report clears the saved pause",function()
      local f=fixture(name) moving(f) f.input("park 2") assert(not f.row().parkConfirmed)
      f.restart(false) assert(f.row()) assert(not f.row().paused) assert(not f.row().removeRequested)
      f.report() moving(f) assert(f.job.running)
    end)
    test(name.." flag off after a failed removal save reclaims the cell and schedules the worker",function()
      local f=fixture(name) moving(f) f.input("remove 2") f.report() parkReport(f)
      local at=copy(f.pose(2))
      f.fail="so-data/"..name.."/job" f.tick() assert(f.row())
      equal(f.mods.cells.owner(at.x,at.y,at.z,at.dim),"gps:2")
      f.fail=nil f.restart(false)
      assert(f.row()) assert(not f.row().paused) assert(not f.row().removeRequested)
      equal(f.mods.cells.owner(at.x,at.y,at.z,at.dim),name..":2")
      f.report() moving(f) assert(f.row()) assert(f.job.running)
    end)
    test(name.." worker park commands default off",function()
      local f=fixture(name,false) moving(f) f.input("resume 2") assert(not f.row().paused)
      if name~="lumber" then f.input("park 2") assert(not f.row().paused) end
    end)
    test(name.." malformed remove cannot bypass parking",function()
      local f=fixture(name) local q=moving(f)
      f.input("remove 2 force")
      assert(f.row()) equal(f.pending().id,q.id)
    end)
    if name~="build" then
      test(name.." parking one worker leaves the other reporting",function()
        local f=fixture(name) moving(f) f.input("park 2") f.report() parkReport(f)
        local reports=0
        for _=1,12 do f.tick() if f.pending(3) then f.report(3) reports=reports+1 end end
        assert(reports>0,"other worker stopped reporting") assert(f.row().paused) assert(f.job.running)
      end)
    end
  end
  test("builder re-adds a removed worker and reclaims its standing cell",function()
    local f=fixture("build")
    f.mods.drops={choose=function()
      return {point={id="build-stock",dim=0,x=0,y=0,z=0,side="down",kind="storage"}}
    end}
    moving(f) f.input("remove 2") f.report() parkReport(f)
    local p=copy(f.pose(2)) f.tick() equal(f.row(),nil)
    f.input("add 2 "..p.x.." "..p.y.." "..p.z.." e")
    assert(f.row()) equal(f.mods.cells.owner(p.x,p.y,p.z,p.dim),"build:2")
    f.tick() assert(f.pending()) f.report()
    f.input("start") moving(f)
  end)
  test("mining keeps a parked shared-lane worker until access is cleared",function()
    local f=fixture("mine") local row=f.row()
    row.pose={dim=f.job.dim,x=0,y=2,z=-1,facing=0}
    f.workerPoses[2]=copy(row.pose) f.hello(2)
    f.input("remove 2") parkReport(f) f.tick()
    assert(f.row()) assert(row.error:find("shared lane",1,true))
    assert(#f.mods.cells.list("mine:2",100000)>0)
  end)
  test("lumber keeps a parked chest-lane worker until access is cleared",function()
    local f=fixture("lumber") moving(f)
    f.row().service={kind="wood",lane={copy(f.pose(2))}}
    f.input("remove 2") f.report() parkReport(f) f.tick()
    assert(f.row()) assert(f.row().alert:find("chest",1,true))
  end)
end

return function(test, equal)
  moduleTests(test,equal)
  test("parked worker stays put and beacons through a twenty minute outage", function()
    local a=F.setup()
    F.send(a, {{op="forward"},{op="forward"},{op="turnRight"}})
    a.n.advance(1)
    F.send(a, {{op="inspectDown"}}, 600000)
    a.n.advance(1)
    a.n.kill(a.s)
    a.n.advance(1200)
    assert(a.t.alive(),tostring(a.t.error))
    equal(a.t.pos.z,-2); equal(a.t.pos.x,0); equal(a.t.heading,1)
    equal(#F.journal(a.t).moves,3)
    local b=F.sent(a.t,"beacon")
    assert(#b>=19,"slow beacons missing")
    for i=2,#b do equal(b[i].at-b[i-1].at,30000) end
    local count=#b
    a.n.advance(60)
    equal(#F.sent(a.t,"beacon"),count+2)
  end)
  test("worker interrupted during work still reverses its moves", function()
    local a=F.setup()
    F.send(a, {{op="forward"},{op="forward"}}, 5000)
    a.n.advance(1); a.n.kill(a.s); a.n.advance(70)
    assert(a.t.alive(),tostring(a.t.error))
    equal(a.t.pos.z,0); equal(#F.journal(a.t).moves,0)
    assert(#F.sent(a.t,"beacon")>=12)
  end)

  test("B8-F build exports copied worker details and confirmed PARK RESUME REMOVE state",function()
    local f=fixture("build",true)
    f.input("park 2") f.tick() f.report()
    local view=f.mods.build.turtleView()["2"]
    equal(view.role,"build") equal(view.state,"parked") equal(view.paused,true) equal(view.parkConfirmed,true)
    equal(view.total,3) equal(view.done,0) equal(view.fuel,4000)
    view.pose.x=900 view.inv[1].count=1
    equal(f.pose(2).x,8) equal(f.mods.build.turtleView()["2"].inv[1].count,64)
    f.input("resume 2") equal(f.mods.build.turtleView()["2"].paused,nil)
    f.input("remove 2") f.tick() f.report() f.tick() equal(f.mods.build.turtleView(),{})
  end)
  test("B8-F blocked parked lumber exports confirmation and renders RESUME",function()
    local f=fixture("lumber",true)
    f.input("park 2") f.tick() f.report()
    f.row(2).blocked="path blocked"
    local view=f.mods.lumber.turtleView()["2"]
    equal(view.parkConfirmed,true) equal(view.paused,true) equal(view.state,"parked")
    view.workerPark=true
    local frame=dofile("so-ui.lua").turtle.render(26,20,{id="2"},view,f.now)
    local found={}
    for _,button in ipairs(frame.buttons) do found[button.id]=true end
    assert(found["turtle-resume"] and found["turtle-remove"] and not found["turtle-park"])
    view.pose.x=900 equal(f.pose(2).x,8)
  end)
end
