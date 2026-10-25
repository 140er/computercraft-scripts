-- Gate B C8: a finished miner had backed along its path while the server was
-- quiet, then recovery marked it done where it stood. It parked in another
-- miner's return column for good.
local H = dofile("tests/so/harness.lua")
local FILES = { "so-server.lua", "so-store.lua", "so-mod-state.lua", "so-pair.lua", "so-proto.lua", "so-mod-lease.lua",
  "so-mod-cells.lua", "so-mod-display.lua", "so-mod-drops.lua", "so-mod-mine.lua", "so-mine-plan.lua", "so-plan.lua" }

local function tree(m)
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path)); m.files[path] = f:read("*a"); f:close()
  end
end

local function wire(server)
  local input
  local display = server.env.SO.mods.display
  local original = display.screen
  display.screen = function(role, r, i) if role == "mining" then input = i end return original(role, r, i) end
  server.env.SO.mods.mine.tick()
  return function(text) input({ text = text }) end
end

local function job(server)
  return server.env.SO.store.read("so-data/mine/job").value.turtles["2"]
end


local function copy(v)
  if type(v) ~= "table" then return v end
  local out={} for k,x in pairs(v) do out[k]=copy(x) end return out
end
local function text(frame)
  local out={} for _,row in ipairs(frame.rows) do out[#out+1]=row.text end
  return table.concat(out,"\n")
end
local function buttons(frame)
  local out={} for _,b in ipairs(frame.buttons) do out[b.id]=b end return out
end
local function miner(config)
  local f={now=1000,events={},calls={},status={},saveOK=true}
  local j={homeSet=true,home={x=0,y=0,z=0,facing=0},bottom=-2,length=4,dim="minecraft:overworld",
    mode="fast",ores={},turtles={},running=false,progress={nextBranch=0,done=0}}
  f.job=j
  local input,render,report
  local env=setmetatable({SO={now=function() return f.now end,breathe=function() end,
    pair={key=function() return "paired" end},store={copy=copy,read=function() return config or {} end,
      store=function() return {value=j,save=function() return f.saveOK,"disk full" end} end},mods={}}},{__index=_G})
  local mods=env.SO.mods
  mods.state={canStart=function() return true end,emit=function(kind,data) f.events[#f.events+1]={kind=kind,data=copy(data)} end}
  mods.drops={list=function() return {{id="ore",dim=0,x=0,y=0,z=0,kind="ore"},
    {id="fuel",dim=0,x=1,y=0,z=0,kind="fuel"}} end}
  mods.cells={reserve=function() return true end,reserveMany=function() return true end,releaseOwner=function() return true end}
  mods.lease={status=function(id) return f.status[id] or {} end,inRange=function() return true end,
    onReport=function(_,fn) report=fn end,send=function(id,steps,opts)
      f.calls[#f.calls+1]={id=id,steps=copy(steps),opts=opts} return #f.calls end}
  mods.display={screen=function(_,r,i) render,input=r,i end}
  f.restart=function()
    f.mod=assert(loadfile("so-mod-mine.lua","t",env))() f.mod.tick()
  end
  f.restart()
  f.mods=mods
  f.input=function(value,session) input(type(value)=="table" and value or {text=value,session=session}) end
  f.render=function(w,h,session) return render(w,h,session) end
  f.row=function(id)
    local pose={dim=j.dim,x=10,y=-2,z=-5,facing=1}
    local row={pose=pose,anchor=copy(pose),frame={dim=j.dim,ox=0,oy=0,oz=0,rot=0},
      inv={},fuel=4000,state="mining",branch=id-2,route={copy(pose)},index=2}
    j.turtles[tostring(id)]=row
    return row
  end
  f.report=function(id,results,facts) report("report",id,results,{report=facts}) end
  f.recover=function(id)
    local row=j.turtles[tostring(id)]
    local p=row.pose
    local q=f.calls[#f.calls]
    report(q.id or #f.calls,id,{{ok=false,err="No block to inspect"}},
      {report={pose={x=p.x,y=p.y,z=p.z,f=p.facing},fuel=4000,inv={}}})
  end
  return f
end

local P = dofile("so-plan.lua")
local M = dofile("so-mine-plan.lua")
local function recaller()
  local f=miner()
  f.actual,f.journals,f.open,f.held,f.clear={},{},{},{},{}
  f.assessments,f.admissions=0,0
  local oldSend=f.mods.lease.send
  f.mods.lease.send=function(id,steps,opts)
    assert(not f.open[id],"overlapping recall leases")
    if opts.journal then assert(opts.journal==f.journals[id],"stale journal") end
    local lid=oldSend(id,steps,opts) f.open[id]=f.calls[#f.calls] return lid
  end
  f.mods.lease.status=function(id)
    if f.status[id] then return f.status[id] end
    local p=f.actual[id]
    return {parkBatch=true,setupFence=true,journal=f.journals[id],open=f.open[id] and "open",
      pose=p and {x=p.x,y=p.y,z=p.z,f=p.facing}}
  end
  f.mods.cells.reserve=function(who,x,y,z,dim)
    local key=M.key({dim=dim,x=x,y=y,z=z})
    if f.held[key] and f.held[key]~=who then return false,"held" end
    f.held[key]=who return true
  end
  f.mods.cells.reserveMany=function(who,cells)
    for _,c in ipairs(cells) do
      local key=M.key(c) if f.held[key] and f.held[key]~=who then return false,"held" end
    end
    for _,c in ipairs(cells) do f.held[M.key(c)]=who end
    return true
  end
  f.mods.cells.owner=function(x,y,z,dim) return f.held[M.key({dim=dim,x=x,y=y,z=z})] end
  f.mods.cells.list=function(who)
    local cells={}
    for key,held in pairs(f.held) do
      if held==who then
        local x,y,z=key:match("^([%-0-9]+),([%-0-9]+),([%-0-9]+)$")
        cells[#cells+1]={dim=f.job.dim,x=tonumber(x),y=tonumber(y),z=tonumber(z)}
      end
    end
    return cells
  end
  f.mods.cells.release=function(who,x,y,z,dim)
    local key=M.key({dim=dim,x=x,y=y,z=z}) if f.held[key]==who then f.held[key]=nil end return true
  end
  f.mods.cells.releaseOwner=function(who)
    for key,held in pairs(f.held) do if held==who then f.held[key]=nil end end return true
  end
  f.mods.cells.isDug=function(x,y,z,dim) return f.clear[M.key({dim=dim,x=x,y=y,z=z})]==true end
  f.mods.cells.admit=function(_,from,op,target)
    f.admissions=f.admissions+1
    if f.deny then return false,"protected" end
    if f.finalDeny then return false,"changed protection" end
    return true
  end
  f.mods.lease.assess=function(_,from,steps)
    f.assessments=f.assessments+1
    return P.assess(from,steps,{admit=function() return not f.deny,"protected" end,
      clear=function(p) return f.clear[M.key(p)]==true end})
  end
  f.add=function(id,x,y,z,facing)
    local row=f.row(id)
    row.pose={dim=f.job.dim,x=x,y=y,z=z,facing=facing or 1}
    row.anchor,row.route,row.index=copy(row.pose),{copy(row.pose)},2
    f.actual[id],f.journals[id]=copy(row.pose),"j0"
    f.clear[M.key(row.pose)]=true
    return row
  end
  f.stage=function(id,x,z,facing)
    f.input(table.concat({"staging",id,x,0,z,({[0]="n","e","s","w"})[facing or 1]}," "))
    assert(f.job.staging[tostring(id)],"staging was refused")
    local row=f.job.turtles[tostring(id)]
    local path=M.supplyRoute(f.job,row,f.job.staging[tostring(id)])
    for _,p in ipairs(path or {}) do f.clear[M.key(p)]=true end
  end
  f.step=function(id,ok,actual,extra)
    local q=assert(f.open[id],"no open lease") f.open[id]=nil
    local results={}
    local p=copy(f.actual[id])
    for i,step in ipairs(q.steps) do
      results[i]={ok=ok~=false,err=ok==false and "blocked" or nil}
      if ok~=false then p=P.apply(p,step.op) end
    end
    p=actual or p f.actual[id]=copy(p)
    f.journals[id]=f.journals[id].."n"
    local facts={pose={x=p.x,y=p.y,z=p.z,f=p.facing},journal=f.journals[id],
      inv=copy(f.job.turtles[tostring(id)].inv),fuel=f.job.turtles[tostring(id)].fuel}
    for k,v in pairs(extra or {}) do facts[k]=v end
    f.now=f.now+100
    f.report(id,results,facts)
    return q
  end
  f.begin=function() f.input("recall on") f.input("recall") f.mod.tick() end
  f.finish=function()
    for _=1,120 do
      if f.job.recall and f.job.recall.phase=="staged" then return end
      local ran=false
      for id in pairs(f.open) do f.step(id) ran=true break end
      f.mod.tick()
      if not ran and not next(f.open) then error("recall made no progress") end
    end
    error("recall did not stage")
  end
  return f
end

return function(test, equal)
  test("mine-done-return: a finished miner recovered away from its branch end returns there", function()
    local net = H.new()
    local server = net.machine({ id = 1, modem = true })
    server.install(FILES) tree(server)
    server.files["so-server.cfg"] = H.encode({ pos = { dim = "minecraft:overworld", x = 0, y = 0, z = 0 } })
    server.boot("so-server.lua") net.flush()
    assert(server.env.SO.mods.drops.add({id="ready",dim=0,x=100000,y=0,z=0,side="front",kind="any"}))
    local input = wire(server)
    local key = string.rep("a", 64)
    assert(server.env.SO.pair.remember(2, key))
    local turtle = net.machine({ id = 2, modem = true, turtle = true, fuel = 4000, capacity = 1000000 })
    turtle.install({ "worker.lua", "so-store.lua", "so-pair.lua", "so-proto.lua" }) tree(turtle)
    turtle.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["1"] = key } } })
    turtle.boot("worker.lua") net.flush()
    input("add 2 0 0 0 n") net.advance(1)
    for y = -2, 0 do net.world["0," .. y .. ",-1"] = "minecraft:stone" end
    for z = -2, -5, -1 do net.world["0,-2," .. z] = "minecraft:stone" end
    for x = 1, 3 do net.world[x .. ",-2,-5"] = "minecraft:stone" end
    input("home 0 0 0 n") input("bottom -2") input("length 3") input("start")
    net.advance(100)
    equal({ turtle.pos.x, turtle.pos.y, turtle.pos.z }, { 3, -2, -5 })
    equal(job(server).state, "done")

    -- Workers before #146 backed along their path after an idle park lease
    -- expired; Gate B's miner 5 was saved that way. Recreate that saved state:
    -- the turtle and its journal sit back in the spine at 0,-2,-2.
    net.kill(server)
    local store = turtle.env.dofile("so-store.lua")
    local box = store.store("so-journal", function(v) return type(v) == "table" end, 16000)
    local saved = box.value
    saved.pose, saved.moves, saved.park = { x = 0, y = -2, z = -2, f = 2 }, {}, nil
    assert(box.save(saved))
    net.onBoot = function(m)
      if m.id == 2 then m.pos.x, m.pos.y, m.pos.z, m.heading = 0, -2, -2, 2 end
    end
    turtle = net.boot(turtle) net.flush()
    net.onBoot = nil
    net.advance(5)
    assert(turtle.alive(), tostring(turtle.error))

    server = net.boot(server) net.flush()
    wire(server)
    net.advance(300)
    assert(not server.error, tostring(server.error))
    assert(not turtle.error, tostring(turtle.error))
    equal({ turtle.pos.x, turtle.pos.y, turtle.pos.z }, { 3, -2, -5 })
    local row = job(server)
    equal(row.state, "done")
    equal({ row.pose.x, row.pose.y, row.pose.z }, { 3, -2, -5 })
    equal(server.env.SO.mods.cells.owner(3, -2, -5), "mine:2")
  end)

  test("S4-12 mining has no fuel missing row without turtles",function()
    local f=miner()
    f.input("start")
    local message=f.events[#f.events].data.text
    assert(message:find("paired turtle missing",1,true))
    assert(not message:find("fuel missing",1,true))
    f.row(2).fuel=0 f.input("start")
    assert(f.events[#f.events].data.text:find("fuel missing #2",1,true))
  end)
  test("S4-10 mining home chip copies the selected paired pose through command validation",function()
    local f=miner({jobPoseSetup=true}) local a,b={id=10},{id=11}
    f.row(2) local row=f.row(3) f.input("stop") row.pose={dim=f.job.dim,x=7,y=12,z=-3,facing=2}
    f.input({id="setup",session=a}) f.input({id="pose-next",session=a})
    assert(buttons(f.render(26,20,a))["home-here"])
    f.input({id="home-here",session=a}) equal(f.job.home,{x=7,y=12,z=-3,facing=2})
    f.input({id="home-here",session=b}) equal(f.job.home,{x=10,y=-2,z=-5,facing=1})
    local old=copy(f.job.home)
    f.status[2]={uncertain=true} f.input({id="home-here",session=b}) equal(f.job.home,old)
    f.status[2]={} f.job.running=true f.input({id="home-here",session=b}) equal(f.job.home,old)
  end)
  test("S4-10 mining pose controls default off and UB-29 branch controls clamp the budget",function()
    local f=miner() f.input({id="setup"})
    assert(not buttons(f.render(57,24))["home-here"])
    f.input({id="home-here"}) equal(f.job.home,{x=0,y=0,z=0,facing=0})
    f.input({id="continuous"})
    local b=buttons(f.render(57,24)) assert(b["set-branches+"] and b["set-branches-"])
    f.input("branches 4096") f.input({id="set-branches+"}) equal(f.job.branches,4096)
    f.input("branches 1") f.input({id="set-branches-"}) equal(f.job.branches,1)
  end)
  test("P4-3 mining stops at COMPLETE and emits one counted alert for all workers",function()
    local f=miner() f.row(2) f.row(3)
    f.job.running=true f.job.progress.nextBranch=2
    f.mod.tick() equal(f.job.running,false) equal(f.job.progress.done,2)
    equal(f.mod.facts().state,"complete") assert(text(f.render(26,20)):find("COMPLETE",1,true))
    for _=1,3 do f.mod.tick() end
    local alerts=0
    for _,event in ipairs(f.events) do
      if event.kind=="mine.alert" then alerts=alerts+1 equal(event.data.done,2) equal(event.data.workers,2) end
    end
    equal(alerts,1)
  end)
  test("P4-3 mining waits for unfinished rows and branch budget then START resumes extra branches",function()
    local f=miner() local row=f.row(2) local other=f.row(3)
    f.job.running=true f.status[3]={open=123}
    f.mod.tick() equal(row.state,"done") equal(f.job.running,true)
    f.status[3]={} f.mod.tick() equal(f.job.running,false)
    f.input("branches 3") equal(f.job.branches,3) f.input("start")
    equal(f.job.complete,nil) equal(f.job.running,true)
    assert(row.state=="mining" and other.state=="mining")
    local empty=miner() empty.job.running=true empty.mod.tick() equal(empty.job.running,true)
  end)
  for _,reason in ipairs({"suspended","missing","broken","unreadable"}) do
    test("B8-F mining holds a cached drop retry that is "..reason,function()
      local f=miner() local row=f.row(2) f.job.running=true
      row.trip={kind="fuel",stage="out",point={id="fuel",x=10,y=-3,z=-5,side="down"},stand=copy(row.pose),back=copy(row.pose)}
      row.dropRetry={key="fuel:empty",tries=3,after=f.now+100}
      local checks=0
      f.mods.drops.usable=function(id) equal(id,"fuel") checks=checks+1 return false,reason end
      f.mod.tick() equal(checks,0)
      f.now=f.now+100 f.mod.tick() equal(checks,1) equal(row.state,"hold")
      assert(row.error:find(reason,1,true)) equal(row.trip.stage,"out")
      for _,q in ipairs(f.calls) do equal(q.steps,{{op="inspectDown"}}) end
      f.status[2]={open=123} f.now=f.now+60000 f.mod.tick() equal(checks,1)
    end)
  end
  test("B8-F mining permits an accepted retry and completes a committed return after suspension",function()
    local f=miner() local row=f.row(2) f.job.running=true
    row.trip={kind="fuel",stage="out",point={id="fuel",x=10,y=-3,z=-5,side="down"},stand=copy(row.pose),back=copy(row.pose)}
    row.dropRetry={key="fuel:empty",tries=3,after=f.now}
    f.mods.drops.usable=function() return true end
    f.mod.tick() equal(f.calls[1].steps[3].op,"suckDown")
    row.trip.stage="back"
    f.mods.drops.usable=function() error("committed return revalidated") end
    f.mod.tick() equal(row.trip,nil)
  end)

  test("S4-10 build corner and home chips copy the paired pose with session-local first corners",function()
    local f=dofile("tests/so/build-fixture.lua")({jobPoseSetup=true})
    f.configure("floor",1,1,1) f.tick() f.report()
    local a,b={},{}
    f.press("setup",a) assert(buttons(f.render(26,20,a))["from-here"])
    f.press("from-here",a)
    f.press("to-here",b) equal(f.job().blueprint.x1,0)
    f.press("to-here",a)
    equal(f.job().blueprint,{dim="minecraft:overworld",shape="floor",x1=-2,x2=-2,y1=3,y2=3,z1=0,z2=0})
    f.press("home-here",a) equal(f.job().home,f.job().turtle.pose)
    local old=f.job().blueprint f.uncertain=true f.press("to-here",a) equal(f.job().blueprint,old)
    local off=dofile("tests/so/build-fixture.lua")() off.press("setup")
    assert(not buttons(off.render(26,20))["from-here"])
  end)
  test("P4-3 build renders COMPLETE 25/25 and emits one alert across ticks START and reload",function()
    local f=dofile("tests/so/build-fixture.lua")()
    local raised=0 local emit=f.mods.state.emit
    f.mods.state.emit=function(kind,data)
      if kind=="build.alert" and data and data.text=="build complete" then raised=raised+1 equal(data.done,25) equal(data.total,25) end
      return emit(kind,data)
    end
    f.configure("floor",5,1,5) f.tick() f.report() f.input("start") f.run()
    equal(f.count(),25) equal(f.job().running,false) equal(raised,1)
    local frame=text(f.render(26,20)) assert(frame:find("COMPLETE",1,true))
    assert(frame:find("25/25",1,true))
    equal(f.mod().budget().remaining,0)
    for _=1,3 do f.tick() end
    f.input("start") f.restart() if f.queued() then f.report() end f.tick()
    equal(raised,1) equal(f.job().running,false)
  end)

  for _,displaced in ipairs({false,true}) do
    test("review P1 mining budget growth and restart without START only returns to the completed end "..tostring(displaced),function()
      local f=miner() local row=f.row(2)
      f.job.continuous,f.job.branches,f.job.running=true,1,true
      f.job.progress.nextBranch=1
      f.mod.tick() equal(f.job.complete,true) equal(f.job.running,false)
      f.input("branches 2") equal(f.job.branches,2)
      local endpoint=copy(row.pose)
      if displaced then row.pose.x=row.pose.x-1 end
      local atRestart=copy(row.pose)
      f.restart() f.recover(2)
      local first=#f.calls+1
      f.mod.tick()
      equal(f.job.running,false) equal(f.job.progress.nextBranch,1)
      equal(row.branch,0) equal(row.returning,nil)
      if displaced then
        equal(row.goal,endpoint)
        row.pose=copy(endpoint)
        row.parkUntil=nil
        f.mod.tick()
      end
      for _=1,3 do f.mod.tick() end
      equal(row.state,"done") equal(row.returning,nil) equal(f.job.progress.nextBranch,1)
      equal(f.job.progress.done,1) equal(row.pose,endpoint)
      for i=first,#f.calls do
        local pose=copy(atRestart)
        for _,step in ipairs(f.calls[i].steps) do
          assert(step.op~="dig" and step.op~="digUp" and step.op~="digDown")
          pose=dofile("so-plan.lua").apply(pose,step.op)
          assert(pose.x<=endpoint.x and pose.x>=atRestart.x)
          equal(pose.y,endpoint.y) equal(pose.z,endpoint.z)
        end
      end
    end)
  end
  test("review P2 adding a worker after single-mode completion clears COMPLETE and announces the next completion",function()
    local f=miner() f.row(2)
    f.job.running=true f.job.progress.nextBranch=1
    f.mod.tick() equal(f.job.complete,true)
    f.input("add 3 12 -2 -5 e") equal(f.job.complete,nil)
    local added=f.job.turtles["3"] assert(added and added.recover)
    f.recover(3) f.input("start") equal(f.mod.facts().state,"running")
    assert(not text(f.render(26,20)):find("COMPLETE",1,true))
    local last=copy(added.pose) last.x=last.x+1
    added.route={copy(added.pose),last} added.branch=1 added.index=2
    f.job.progress.nextBranch=2
    f.mod.tick() equal(f.job.running,true)
    added.pose=last f.mod.tick()
    equal(f.job.running,false) equal(f.job.complete,true) equal(f.job.progress.done,2)
    local notices=0
    for _,event in ipairs(f.events) do if event.kind=="mine.alert" and event.data and event.data.text=="mining complete" then notices=notices+1 end end
    equal(notices,2)
  end)
  test("review P2 a failed assignment save retains the completion marker",function()
    local f=miner() f.row(2)
    f.job.running=true f.job.progress.nextBranch=1 f.mod.tick()
    f.saveOK=false f.input("add 3 12 -2 -5 e")
    equal(f.job.complete,true) equal(f.job.turtles["3"],nil)
  end)
  test("B4-A KEEP sorts exact IDs and waits for outstanding batches",function()
    local f=miner() f.row(2)
    equal(f.job.keep,{}) equal(f.job.recallEnabled,false) equal(f.job.staging,{})
    f.input("keep minecraft:tuff,minecraft:cobblestone minecraft:tuff")
    equal(f.job.keep,{"minecraft:cobblestone","minecraft:tuff"})
    f.status[2]={open="busy"} f.input("keep none") equal(#f.job.keep,2)
    f.status[2]={lost=true} f.input("keep none") equal(#f.job.keep,2)
    f.status[2]={} f.input("keep bad:id*") equal(#f.job.keep,2)
    local names={} for i=1,65 do names[i]="mod:item"..i end
    f.input("keep "..table.concat(names,",")) equal(#f.job.keep,2)
    f.saveOK=false f.input("keep none") equal(#f.job.keep,2)
    f.saveOK=true f.input("keep none") equal(f.job.keep,{})
  end)
  test("B4-A KEEP excludes selected cleanup and reserves shared sealing stock before bounded surplus",function()
    local inv={{slot=1,name="minecraft:cobblestone",count=32},
      {slot=2,name="minecraft:cobblestone",count=120},
      {slot=3,name="minecraft:coal",count=64},{slot=4,name="minecraft:diamond_pickaxe",count=1},
      {slot=5,name="minecraft:raw_iron",count=35}}
    equal(M.cleanup(inv,false,nil,{"minecraft:cobblestone"}),{})
    equal(M.cleanup(inv,false),{{op="select",slot=2},{op="discard",side="down"}})
    local surplus,stock=M.unload(inv,{"minecraft:cobblestone","minecraft:coal","minecraft:diamond_pickaxe"})
    equal(surplus,{slot=2,n=64}) equal(stock,true)
    inv[2].count=13 equal(M.unload(inv,{"minecraft:cobblestone"}),{slot=2,n=13})
    table.remove(inv,2) equal(M.unload(inv,{"minecraft:cobblestone"}),{slot=5,n=35})
    inv[4]=nil equal(M.unload(inv,{"minecraft:cobblestone"}),nil)
  end)
  test("B4-A KEEP never bypasses the fewer-than-two-free-slots unload trigger",function()
    local f=miner() local row=f.row(2)
    f.input("keep minecraft:cobblestone")
    row.inv={} for i=1,16 do row.inv[i]={slot=i,name="minecraft:cobblestone",count=64} end
    f.mods.drops.pick=function(kind)
      equal(kind,"ore") return {point={id="ore",dim=0,x=0,y=-1,z=0,side="down"}}
    end
    f.job.running=true f.mod.tick()
    assert(row.trip and row.trip.kind=="ore")
    for _,q in ipairs(f.calls) do for _,step in ipairs(q.steps) do assert(step.op~="discard") end end
  end)
  test("B4-A KEEP unload recalculates positive counts after reports and holds for headroom or sealing stock",function()
    local f=miner() local row=f.row(2) f.input("keep minecraft:cobblestone")
    row.inv={} for i=1,16 do row.inv[i]={slot=i,name="minecraft:torch",count=64} end
    row.inv[1]={slot=1,name="minecraft:cobblestone",count=32}
    row.inv[2]={slot=2,name="minecraft:cobblestone",count=90}
    row.trip={kind="ore",stage="out",stand=copy(row.pose),back=copy(row.pose),
      point={id="ore",dim=f.job.dim,x=10,y=-3,z=-5,side="down"}}
    f.mods.drops.steps=function() return {{op="inspectDown"},{op="dropDown"}} end
    f.job.running=true f.mod.tick()
    equal(f.calls[1].steps[1],{op="select",slot=2}) equal(f.calls[1].steps[3],{op="dropDown",n=64})
    row.inv[2].count=26
    f.report(2,{{ok=true},{ok=true,data={name="minecraft:chest"}},{ok=true}},
      {pose={x=row.pose.x,y=row.pose.y,z=row.pose.z,f=row.pose.facing},inv=copy(row.inv),fuel=row.fuel})
    f.mod.tick() equal(f.calls[2].steps[3],{op="dropDown",n=26})
    table.remove(row.inv,2)
    f.mod.tick() equal(row.state,"hold") equal(row.error,"KEEP needs two free slots") equal(row.trip.stage,"out")
    table.remove(row.inv,2) row.parkUntil=nil f.mod.tick() equal(row.trip.stage,"back")
    row.trip.stage="out" table.remove(row.inv,1) row.parkUntil=nil f.mod.tick()
    equal(row.error,"KEEP needs sealing stock") equal(row.trip.stage,"out")
    for _,q in ipairs(f.calls) do
      for _,step in ipairs(q.steps) do if step.op=="dropDown" then assert(step.n and step.n>0 and step.n<=64) end end
    end
  end)
  test("B4-A recall refuses old unknown and partly capable workers",function()
    for _,caps in ipairs({{}, {parkBatch=true}, {setupFence=true}}) do
      local f=recaller() f.add(2,0,0,-1) f.stage(2,3,2)
      f.status[2]=caps f.input("recall on") f.input("recall")
      equal(f.job.recall,nil) equal(#f.calls,0)
      assert(f.events[#f.events].data.text:find("parkBatch and setupFence",1,true))
    end
    local f=recaller() f.add(2,0,0,-1) f.stage(2,3,2) f.input("recall") equal(f.job.recall,nil)
  end)
  test("B4-A staging rejects shared lane chest access and duplicate destinations",function()
    local f=recaller() f.add(2,0,0,-1) f.add(3,1,0,-1)
    for _,cmd in ipairs({"staging 2 0 0 -1 e","staging 2 0 0 1 e","staging 2 4 -1 3 e"}) do
      f.input(cmd) equal(f.job.staging["2"],nil)
    end
    f.stage(2,3,2) f.input("staging 3 3 0 2 n") equal(f.job.staging["3"],nil)
    f.saveOK=false f.input("staging 3 5 0 4 n") equal(f.job.staging["3"],nil)
  end)
  test("B4-A recall saves before dispatch and drains active batches before snapshotting cursors",function()
    local f=recaller() local row=f.add(2,0,0,-1) f.stage(2,3,2)
    f.saveOK=false f.input("recall on") equal(f.job.recallEnabled,false)
    f.saveOK=true f.input("recall on") f.saveOK=false f.input("recall")
    equal(f.job.recall,nil) equal(#f.calls,0)
    f.saveOK=true f.status[2]={parkBatch=true,setupFence=true,open="dig"}
    f.input("recall") f.mod.tick() equal(#f.calls,0)
    local worker=f.job.recall.workers["2"] equal(worker.phase,"draining")
    local nextBranch=f.job.progress.nextBranch
    f.status[2]=nil row.index=7 f.mod.tick()
    equal(worker.cursor.index,7) equal(worker.cursor.branch,row.branch)
    equal(f.job.progress.nextBranch,nextBranch) assert(f.calls[1].steps[1].park)
  end)
  test("B4-A recall sends only acknowledged non-digging fenced stationary prefixes and reserves the lane exit",function()
    local f=recaller() local row=f.add(2,0,-2,-3,0) f.stage(2,3,2,3)
    local cursor=copy(row.route) local index=row.index
    f.begin()
    local worker=f.job.recall.workers["2"]
    for _,cell in ipairs(worker.remaining) do equal(f.held[M.key(cell)],"mine:2") end
    f.finish()
    equal(worker.phase,"staged") equal(row.pose,f.job.staging["2"])
    equal(row.route,cursor) equal(row.index,index) equal(f.job.running,false)
    assert(f.assessments>0 and f.admissions>0)
    for _,q in ipairs(f.calls) do
      assert(q.steps[1].park) assert(q.opts.journal)
      local motions=0
      for i,step in ipairs(q.steps) do
        assert(step.op~="dig" and step.op~="digUp" and step.op~="digDown" and step.op~="place")
        if P.moves[step.op] or P.turns[step.op] then motions=motions+1 equal(i,#q.steps) end
      end
      assert(motions<=1)
    end
  end)
  test("B4-A recall holds unknown cells and both assessment and final admission refusals",function()
    for _,kind in ipairs({"unknown","assessment","final"}) do
      local f=recaller() local row=f.add(2,0,0,-1) f.stage(2,3,2)
      if kind=="unknown" then f.clear["1,0,-1"]=nil
      elseif kind=="assessment" then f.deny=true else f.finalDeny=true end
      f.begin() equal(f.job.recall.workers["2"].phase,"blocked")
      for _,q in ipairs(f.calls) do equal(q.steps,{{op="inspectDown",park=true}}) end
      equal({row.pose.x,row.pose.y,row.pose.z},{0,0,-1})
      if kind=="final" then assert(f.admissions>0) end
    end
  end)
  test("B4-A failed recall movement waits for stationary reconciliation before a dependent turn",function()
    local f=recaller() local row=f.add(2,0,0,-1,3) f.stage(2,-1,2)
    f.begin() equal(f.open[2].steps[1].op,"forward")
    local held=copy(f.held) f.step(2,false)
    equal(row.recover,true) equal(f.held,held)
    f.mod.tick() equal(f.open[2].steps,{{op="inspectDown",park=true}}) assert(f.open[2].opts.recover)
    equal(row.pose.x,0)
    f.step(2) f.mod.tick()
    equal(row.recover,false) equal(f.open[2].steps[1].op,"forward")
    f.step(2)
    if not f.open[2] then f.mod.tick() end
    equal(f.open[2].steps[1].op,"turnLeft")
  end)
  test("B4-A expired and unexpected recall reports retain occupied and uncertain cells",function()
    for _,kind in ipairs({"expired","unexpected","stale","uncertain"}) do
      local f=recaller() local row=f.add(2,0,0,-1,1) f.stage(2,3,2) f.begin()
      local held=copy(f.held)
      if kind=="expired" then f.open[2]=nil f.report(2,nil,nil)
      elseif kind=="unexpected" then
        local actual=copy(f.actual[2]) actual.x=7 f.step(2,true,actual)
      elseif kind=="stale" then f.step(2,true,nil,{journal=f.journals[2]})
      else f.step(2,true,nil,{uncertain=true}) end
      equal(row.recover,true) equal(f.held,held) equal(row.pose.x,0)
      f.mod.tick() assert(f.open[2].opts.recover) assert(f.open[2].steps[1].park)
    end
  end)
  test("B4-A low-fuel recall uses inventory fuel or parks without digging",function()
    for _,stock in ipairs({false,true}) do
      local f=recaller() local row=f.add(2,0,0,-1) f.stage(2,3,2)
      row.fuel=0 if stock then row.inv={{slot=1,name="minecraft:coal",count=1}} end
      f.begin()
      equal(f.job.recall.workers["2"].phase,"fuel")
      if stock then
        equal(f.calls[1].steps,{{op="select",slot=1,park=true},{op="refuel",n=1}})
      else equal(f.calls[1].steps,{{op="inspectDown",park=true}}) end
      for _,q in ipairs(f.calls) do for _,step in ipairs(q.steps) do assert(not step.op:match("^dig") and not step.op:match("^place")) end end
    end
  end)
  test("B4-A recall restart recovers the journal before replacing stale routes and preserves STOP and disabled intents",function()
    local f=recaller() local row=f.add(2,0,0,-1) f.stage(2,3,2) f.begin()
    f.step(2)
    local worker=f.job.recall.workers["2"] local cursor=copy(worker.cursor)
    worker.remaining={{dim=f.job.dim,x=999,y=999,z=999}}
    f.open[2]=nil f.restart()
    equal(worker.remaining,nil) assert(row.recover) assert(f.open[2].opts.recover)
    equal(f.open[2].steps,{{op="inspectDown",park=true}})
    f.step(2) f.input("stop") f.input("recall off")
    equal(f.job.running,false) equal(worker.cursor,cursor) assert(f.job.recall)
    if f.open[2] then f.step(2) end
    f.mod.tick()
    if f.open[2] then equal(f.open[2].steps,{{op="inspectDown",park=true}}) f.step(2) end
    f.input("start") f.mod.tick() f.finish()
    equal(row.pose,f.job.staging["2"]) equal(worker.cursor,cursor)
    f.open[2]=nil f.restart() assert(f.open[2].opts.recover) f.step(2) f.mod.tick()
    equal(worker.phase,"staged") equal(f.job.running,false)
  end)
  test("B4-A recall completes only after every worker stages and START returns to unfinished cursors",function()
    local f=recaller() local row=f.add(2,0,0,-1) f.stage(2,3,2)
    local other=f.add(3,5,0,3) f.stage(3,5,4,2)
    local original,index=copy(row.pose),row.index
    f.begin() f.finish()
    equal(f.job.recall.workers["3"].phase,"staged") equal(other.pose,f.job.staging["3"])
    if f.open[2] then f.step(2) end if f.open[3] then f.step(3) end
    f.input("start")
    equal(f.job.recall.phase,"resuming")
    for _=1,120 do
      if not f.job.recall then break end
      for id in pairs(f.open) do f.step(id) break end
      if f.job.recall then f.mod.tick() end
    end
    equal(f.job.recall,nil) equal(row.pose,original) equal(row.index,index)
  end)

  test("B4-A real B3-A admission refuses protected recall entry and automatic protected exits",function()
    for _,inside in ipairs({false,true}) do
      local fixture=dofile("tests/so/protected.lua")
      local a=fixture.setup()
      local so=a.m.env.SO
      local pose=copy(a.pose)
      local j={homeSet=true,home={x=0,y=0,z=0,facing=1},bottom=-2,length=4,dim=pose.dim,
        mode="fast",ores={},turtles={["2"]={pose=pose,anchor=copy(pose),
          frame={dim=pose.dim,ox=0,oy=0,oz=0,rot=0},inv={},fuel=100,state="stopped",branch=0,
          route={copy(pose)},index=2}},running=false,progress={nextBranch=1,done=0}}
      assert(so.store.store("so-data/mine/job",function(v) return type(v)=="table" end).save(j))
      local input
      so.mods.display={screen=function(_,_,fn) input=fn end}
      so.mods.state={emit=function() end,canStart=function() return true end}
      so.mods.drops={list=function() return {} end}
      a.m.install({"so-mod-mine.lua","so-mine-plan.lua"})
      local mine=a.m.env.dofile("so-mod-mine.lua") so.mods.mine=mine
      a.lease.describe=function() end
      mine.tick() a.report()
      local blocked=inside and 0 or 2
      assert(a.cells.protect({a.box("recall-box",blocked,blocked)}))
      input({text="staging 2 3 0 2 e"})
      local row=j.turtles["2"]
      for _,cell in ipairs(M.supplyRoute(j,row,{dim=pose.dim,x=3,y=0,z=2})) do
        assert(a.cells.markDug(cell.x,cell.y,cell.z,cell.dim))
      end
      input({text="recall on"}) input({text="recall"}) mine.tick()
      local function lastBatch()
        for i=#a.sent,1,-1 do if a.sent[i].body.steps then return a.sent[i] end end
      end
      if not inside then
        equal(lastBatch().body.steps[1].op,"forward") a.report()
      end
      mine.tick()
      equal(lastBatch().body.steps,{{op="inspectDown",park=true}})
      for _,wire in ipairs(a.sent) do
        for _,step in ipairs(wire.body.steps or {}) do assert(not step.op:match("^dig")) end
      end
      local view=mine.turtleView()["2"]
      equal(view.error,"protected") equal(view.pose.x,inside and 0 or 1)
      equal(a.cells.owner(view.pose.x,view.pose.y,view.pose.z,view.pose.dim),"mine:2")
      if not inside then assert(#a.cells.list("mine:2")>1,"recall released its reserved pass") end
    end
  end)
  test("B4-A real worker keeps a recall travel prefix stationary through expiry and reboot",function()
    local F=dofile("tests/so/worker-fixture.lua")
    local a=F.setup(nil,{"so-mod-lease.lua","so-mod-cells.lua","so-plan.lua","so-mine-plan.lua"})
    local so=a.s.env.SO
    local pose={dim="minecraft:overworld",x=0,y=0,z=0,facing=0}
    local j={homeSet=true,home={x=0,y=0,z=1,facing=0},bottom=-2,length=4,dim=pose.dim,
      mode="fast",ores={},turtles={["2"]={pose=pose,anchor=copy(pose),
        frame={dim=pose.dim,ox=0,oy=0,oz=0,rot=0},inv={},fuel=100,state="stopped",branch=0,
        route={copy(pose)},index=2}},running=false,progress={nextBranch=1,done=0}}
    assert(so.store.store("so-data/mine/job",function(v) return type(v)=="table" end).save(j))
    local input
    so.mods.display={screen=function(_,_,fn) input=fn end}
    so.mods.drops={list=function() return {} end}
    a.s.install({"so-mod-mine.lua"})
    local mine=a.s.env.dofile("so-mod-mine.lua") so.mods.mine=mine
    mine.tick() a.n.advance(1)
    input({text="staging 2 3 0 2 e"})
    for _,cell in ipairs(M.supplyRoute(j,j.turtles["2"],{dim=pose.dim,x=3,y=0,z=2})) do
      assert(so.mods.cells.markDug(cell.x,cell.y,cell.z,cell.dim))
    end
    local send=a.t.env.rednet.send
    a.t.env.rednet.send=function(id,wire,protocol)
      local msg=a.t.env.dofile("so-proto.lua").decode(wire)
      if msg and msg.t=="step.report" and a.t.pos.x>0 then return true end
      return send(id,wire,protocol)
    end
    input({text="recall on"}) input({text="recall"}) mine.tick() a.n.advance(2)
    for _=1,5 do mine.tick() a.n.advance(1) if a.t.pos.x>0 then break end end
    assert(a.t.pos.x==1,"worker did not move "..H.encode(mine.turtleView()).." batches "..H.encode(F.sent(a.s,"lease.batch")))
    local batches=F.sent(a.s,"lease.batch") local batch=batches[#batches].body
    equal(batch.steps,{{op="forward",park=true}}) assert(batch.journal)
    a.n.kill(a.s) a.n.advance(95)
    assert(a.t.alive(),tostring(a.t.error)) equal(a.t.pos.x,1) equal(a.t.pos.z,0)
    equal(F.journal(a.t).park,true)
    local physical,heading=copy(a.t.pos),a.t.heading
    a.n.onBoot=function(m) if m.id==2 then m.pos=copy(physical) m.heading=heading end end
    a.t=a.n.boot(a.t) a.n.onBoot=nil a.n.advance(95)
    assert(a.t.alive(),tostring(a.t.error)) equal(a.t.pos.x,1) equal(a.t.pos.z,0)
  end)

  test("B4-A low-fuel service stays on clear fenced prefixes and preserves the frozen mining trip",function()
    local f=recaller() local row=f.add(2,0,0,-1) f.stage(2,100,2)
    row.fuel=70
    row.trip={kind="ore",stage="out",back=copy(row.pose),stand=copy(row.pose),point={id="old"}}
    local frozen=copy(row.trip)
    f.mods.drops.pick=function(kind)
      equal(kind,"fuel") return {point={id="fuel",dim=0,x=3,y=-1,z=-1,side="down"}}
    end
    f.begin()
    for _=1,8 do
      local q=assert(f.open[2])
      if q.steps[#q.steps].op=="suckDown" then break end
      f.step(2) f.mod.tick()
    end
    equal(row.pose.x,3) equal(f.open[2].steps[#f.open[2].steps],{op="suckDown",n=64})
    f.step(2,true,nil,{inv={{slot=1,name="minecraft:coal",count=64}}}) f.mod.tick()
    equal(f.open[2].steps[2].op,"refuel")
    f.step(2,true,nil,{fuel=230,inv={{slot=1,name="minecraft:coal",count=62}}}) f.mod.tick()
    equal(row.trip,frozen) equal(f.job.recall.workers["2"].service,nil)
    for _,q in ipairs(f.calls) do
      assert(q.steps[1].park and q.opts.journal)
      for _,step in ipairs(q.steps) do assert(not step.op:match("^dig") and not step.op:match("^place")) end
    end
  end)
  test("B4-A low-fuel service refuses a trip that would consume its reserve",function()
    local f=recaller() local row=f.add(2,0,0,-1) f.stage(2,100,2) row.fuel=65
    f.mods.drops.pick=function() return {point={id="fuel",dim=0,x=3,y=-1,z=-1,side="down"}} end
    f.begin()
    equal(f.job.recall.workers["2"].service,nil)
    equal(f.open[2].steps,{{op="inspectDown",park=true}})
  end)
  test("B4-A draining recall suppresses new vein claims from the last mining scan",function()
    local f=recaller() local row=f.add(2,0,0,-1) f.stage(2,3,2)
    row.scan={index=1,facing=row.pose.facing} f.job.running=true f.mod.tick()
    equal(f.open[2].steps[1].op,"inspect")
    f.input("recall on") f.input("recall")
    equal(f.job.recall.workers["2"].phase,"draining")
    f.open[2]=nil f.journals[2]="j1"
    f.report(2,{{ok=true,data={name="minecraft:diamond_ore"}}},
      {pose={x=0,y=0,z=-1,f=1},journal="j1",fuel=row.fuel,inv={}})
    equal(row.veins,nil) equal(f.job.progress.nextBranch,0)
  end)
  test("B4-A recall dispatch refuses a failed intent save before any worker message",function()
    local f=recaller() f.add(2,0,0,-1) f.stage(2,3,2)
    f.input("recall on") f.input("recall") f.saveOK=false f.mod.tick()
    equal(#f.calls,0) equal(f.job.running,false) assert(f.job.recall)
  end)

  test("B4-A recall treats unknown fuel as service pending and leaves offline workers pending",function()
    local f=recaller() local row=f.add(2,0,0,-1) f.stage(2,3,2) row.fuel=nil
    f.begin() equal(f.job.recall.workers["2"].phase,"fuel")
    equal(f.open[2].steps,{{op="inspectDown",park=true}})
    f.open[2]=nil f.status[2]={parkBatch=true,setupFence=true,journal=f.journals[2],lost=true}
    f.mod.tick() equal(row.recover,true) equal(f.job.recall.phase,"returning")
    assert(f.open[2].opts.recover and f.open[2].steps[1].park)
  end)
  test("B4-A a failed recall completion save preserves the saved cursor and intent",function()
    local f=recaller() f.add(2,0,0,-1) f.stage(2,3,2) f.begin() f.finish()
    local pending=f.job.recall
    if f.open[2] then f.step(2) end
    f.input("start") f.saveOK=false
    local worker=pending.workers["2"]
    worker.phase="resumed"
    f.mod.tick()
    equal(f.job.recall,pending) equal(f.job.recall.phase,"resuming")
    assert(worker.cursor) equal(f.job.running,false)
  end)

  test("B4-A restart cannot complete recall while a previously staged offline worker still needs recovery",function()
    local f=recaller() f.add(2,0,0,-1) f.stage(2,3,2)
    local offline=f.add(3,5,0,4) f.stage(3,5,4) f.begin()
    equal(f.job.recall.workers["3"].phase,"staged")
    f.open[2],f.open[3]=nil,nil
    f.status[3]={parkBatch=true,setupFence=true,journal=f.journals[3],lost=true}
    f.restart() assert(offline.recover) f.status[3].open="recovery"
    f.step(2)
    for _=1,60 do
      if f.job.recall.workers["2"].phase=="staged" then break end
      f.mod.tick() if f.open[2] then f.step(2) end
    end
    equal(f.job.recall.workers["2"].phase,"staged")
    equal(f.job.recall.phase,"returning") equal(f.job.running,true) assert(offline.recover)
    f.status[3]=nil f.step(3) f.mod.tick()
    equal(offline.recover,false) equal(f.job.recall.phase,"staged") equal(f.job.running,false)
  end)

end
