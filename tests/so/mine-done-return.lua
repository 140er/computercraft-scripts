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
  f.mod=assert(loadfile("so-mod-mine.lua","t",env))() f.mod.tick()
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
end
