local H = dofile("tests/so/harness.lua")

local function point(id, kind)
  return {id=id or "ore", dim=0, x=1, y=64, z=0, side="front", kind=kind or "ore", fails=0}
end
local function candidate(x)
  return {dim=0, x=x or 1, y=64, z=0, side="front", block="minecraft:chest", at=1000}
end
local function boot(files, enabled)
  local m = H.new().machine({id=1, capacity=16000000})
  m.install({"so-store.lua", "so-ui.lua", "so-mod-drops.lua"})
  for name, bytes in pairs(files or {}) do m.files[name] = bytes end
  m.files["so-server.cfg"] = H.encode({dropsSavedSetup=enabled == true})
  local e, t = m.env, {machine=m, sent=0, events=0}
  e.SO = {store=e.dofile("so-store.lua"), now=function() return 1000 end, mods={}}
  e.SO.mods.state = {emit=function() t.events=t.events+1 end}
  e.SO.mods.display = {screen=function(_, render, input) t.render,t.input=render,input end}
  e.SO.mods.lease = {send=function() t.sent=t.sent+1 end, cancel=function() t.sent=t.sent+1 end}
  t.mod=e.dofile("so-mod-drops.lua")
  t.mod.tick()
  for i=1,30 do local k,v=debug.getupvalue(t.mod.tick,i) if k=="S" then t.S=v end end
  t.tap=function(id, from) t.input({id=id, from=from or 7}) end
  t.saved=function() return assert(e.SO.store.read("so-drops")).value end
  return t
end
local function generation(value, n)
  return H.encode({schema=1, generation=n or 1, value=value})
end

return function(test, equal)
  test("B8-U default-off writes legacy and enabled migration retains roomSink", function()
    local t=boot({["so-drops"]=generation({points={point()},roomSink=true})})
    assert(t.mod.add(point("wood","wood")))
    equal(t.saved().v,nil)
    equal(t.saved().roomSink,true)
    t=boot(t.machine.files,true)
    assert(t.mod.note("ore"))
    equal({t.saved().v,t.saved().roomSink,#t.saved().candidates},{2,true,0})
  end)
  test("UB-38 FOUND merges, replaces and survives restart without verification or movement", function()
    local t=boot(nil,true)
    assert(t.S.observe(candidate()))
    assert(t.S.observe(candidate(2)))
    local p=candidate() p.block="minecraft:barrel"
    assert(t.S.observe(p))
    equal({#t.S.candidates,t.S.candidates[1].block},{2,"minecraft:barrel"})
    t=boot(t.machine.files,true)
    equal({#t.S.candidates,t.S.candidates[1].x,t.sent,#t.mod.list()},{2,1,0,0})
    assert(t.mod.add(point()))
    equal(#t.saved().candidates,2)
    t.tap("clear-found") equal(#t.S.candidates,2)
    t.tap("clear-found",8) equal(#t.S.candidates,2)
    t.tap("clear-found") equal(#t.S.candidates,0)
    equal(#boot(t.machine.files,true).S.candidates,0)
  end)
  test("P-U4-8 stable suspension excludes exact and fallback across restart and flag off", function()
    local t=boot(nil,true)
    assert(t.mod.add(point())) assert(t.mod.add(point("any","any")))
    t.tap("suspend:ore")
    local near={dim=0,x=0,y=64,z=0}
    equal(t.mod.pick("ore",near).point.id,"any")
    t.tap("suspend:any")
    equal({t.mod.choose("ore",near).reason,t.sent},{"suspended",0})
    equal({t.mod.list()[1].suspended,t.mod.list()[1].disabled},{true,true})
    t=boot(t.machine.files,false)
    equal(t.mod.pick("ore",near).reason,"suspended")
    t.tap("resume:ore") equal(t.mod.list()[1].suspended,true)
    assert(t.mod.note("ore"))
    equal({t.saved().v,t.saved().points[1].suspended},{2,true})
    t=boot(t.machine.files,true)
    t.tap("resume:ore") equal(t.mod.pick("ore",near).point.id,"ore")
    equal(t.sent,0)
  end)
  test("B8-U invalid and unreadable newer generations block selection and every write", function()
    for _, bad in ipairs({"unreadable",generation({v=3,points={}},2),
      generation({v=2,points={point()},roomSink=false,candidates={candidate(),candidate()}},2)}) do
      local files={["so-drops"]=bad,["so-drops.bak"]=generation({points={point()}})}
      local t=boot(files,true)
      assert(not t.mod.pick("ore",{dim=0,x=0,y=64,z=0}).point)
      assert(not t.mod.add(point("new")))
      assert(not t.mod.remove("ore"))
      equal(t.machine.files["so-drops"],bad)
    end
  end)
  test("B8-U candidate validator rejects malformed rows and bounds discovery order", function()
    local t=boot(nil,true)
    local good={v=2,points={},roomSink=false,candidates={candidate()}}
    assert(t.S.valid(good))
    for key,value in pairs({dim=2,x=0/0,y=math.huge,z=1.5,side="up",block="chest",at=-1,extra=true}) do
      local v=t.machine.env.SO.store.copy(good) v.candidates[1][key]=value
      assert(not t.S.valid(v),key)
    end
    local sparse={v=2,points={},roomSink=false,candidates={[2]=candidate()}}
    assert(not t.S.valid(sparse))
    local legacy={points={point()}} legacy.points[1].suspended=true
    assert(not t.S.valid(legacy))
    for i=1,64 do assert(t.S.observe(candidate(i))) end
    assert(not t.S.observe(candidate(65)))
    equal({#t.S.candidates,t.S.candidates[1].x},{64,1})
    local replacement=candidate(1) replacement.at=2000
    assert(t.S.observe(replacement))
    equal({#t.S.candidates,t.S.candidates[1].at},{64,2000})
  end)
  test("B8-U failed saves preserve the entire envelope, revision and reservations", function()
    local t=boot(nil,true)
    assert(t.mod.add(point())) assert(t.S.observe(candidate()))
    local saved,rev=t.saved(),t.S.rev
    t.S.box.save=function() return false,"disk full" end
    t.tap("suspend:ore")
    equal({t.mod.list()[1].suspended,t.S.rev},{nil,rev})
    assert(not t.S.observe(candidate(2)))
    t.tap("clear-found") t.tap("clear-found")
    equal(t.saved(),saved)
    equal({#t.S.candidates,t.S.rev,t.sent},{1,rev,0})
  end)
  test("UB-38 a scanned FOUND survives server restart and two displays see the same saved list", function()
    local suite = dofile("tests/so/setup-ux.lua")
    local setup
    for i=1,30 do local k,v=debug.getupvalue(suite,i) if k=="setup" then setup=v end end
    local a=assert(setup) (true)
    local F=dofile("tests/so/worker-fixture.lua")
    a.s.files["so-server.cfg"]=H.encode({setupMovement=true,dropsSavedSetup=true,
      pos={dim="minecraft:overworld",x=40,y=64,z=10}})
    a.n.world["1,0,0"]="minecraft:chest"
    a.n.world["0,-1,0"]="minecraft:barrel"
    a.ui.input({id="scan:2",from=7})
    a.ui.input({id="facing:1",from=7})
    a.n.advance(4)
    F.check(a)
    local function saved() return a.s.env.SO.store.read("so-drops").value.candidates end
    equal(#saved(),2)
    a.ui.input({id="scan:2",from=8}) a.n.advance(4)
    equal(#saved(),2)
    local batches=#F.sent(a.s,"lease.batch")
    a.s.boot("so-server.lua") a.n.advance(1)
    assert(not a.s.error,tostring(a.s.error))
    a.ui=a.s.env.SO.mods.display.screen("generic")
    for _,id in ipairs({7,8}) do
      a.ui.input({id="testing",from=id})
      local found=0
      for _,b in ipairs(a.ui.render(29,12,{id=id}).buttons) do if b.id:match("^candidate:") then found=found+1 end end
      equal(found,2)
    end
    equal(#saved(),2)
    equal(#F.sent(a.s,"lease.batch"),batches)
    equal(a.s.env.SO.mods.drops.list(),{})
  end)
  test("B8-U a failed discovery save stops collection and completes the safe return", function()
    local suite=dofile("tests/so/setup-ux.lua")
    local setup
    for i=1,30 do local k,v=debug.getupvalue(suite,i) if k=="setup" then setup=v end end
    local a=assert(setup)(true)
    a.s.files["so-server.cfg"]=H.encode({setupMovement=true,dropsSavedSetup=true,
      pos={dim="minecraft:overworld",x=40,y=64,z=10}})
    local S
    for i=1,30 do local k,v=debug.getupvalue(a.s.env.SO.mods.drops.tick,i) if k=="S" then S=v end end
    assert(S.observe(candidate(99)))
    local calls=0
    S.box.save=function() calls=calls+1 return false,"disk full" end
    a.n.world["1,0,0"]="minecraft:chest"
    a.n.world["0,-1,0"]="minecraft:barrel"
    a.ui.input({id="scan:2",from=7}) a.ui.input({id="facing:1",from=7}) a.n.advance(4)
    equal({calls,#S.candidates,S.candidates[1].x,S.message},{1,1,99,"save failed"})
    equal({a.t.pos.x,a.t.pos.y,a.t.pos.z,a.t.heading},{0,0,0,1})
    equal(a.s.env.SO.mods.cells.list("setup:2",100),{})
  end)

  test("B8-U every point transaction retains suspension and saved candidates", function()
    local t=boot(nil,true)
    assert(t.mod.add(point())) assert(t.S.observe(candidate())) t.tap("suspend:ore")
    assert(t.mod.roomMark("ore",true)) assert(t.mod.roomSink(true)) assert(t.mod.note("ore"))
    assert(t.mod.fix("ore"))
    assert(t.S.verify("ore",{ok=true,data={name="minecraft:chest"}}))
    local moved=point() moved.x=2
    assert(t.S.edit("ore",moved))
    equal({t.saved().points[1].suspended,#t.saved().candidates,t.saved().roomSink},{true,1,true})
    equal(t.saved().points[1].verified,nil)
    t=boot(t.machine.files,true)
    equal({t.mod.list()[1].suspended,#t.S.candidates},{true,1})
    assert(t.mod.remove("ore")) equal(#t.saved().candidates,1)
  end)
  test("B8-U the generation wrapper counts toward the 65536 byte save limit", function()
    local t=boot(nil,true)
    local p=point(string.rep("p",65500))
    local ok,why=t.mod.add(p)
    equal({ok,why,#t.mod.list(),t.S.rev},{false,"budget exceeded",0,0})
    equal(t.machine.files["so-drops"],nil)
  end)

  test("UB-38 forgetting a worker retains saved FOUND", function()
    local t=boot(nil,true)
    assert(t.S.observe(candidate()))
    t.S.task={id=12}
    t.machine.env.SO.mods.cells={list=function() return {} end, handoff=function() return true end,
      releaseOwner=function() return true end}
    assert(t.mod.forget(12))
    equal({t.S.task,#t.S.candidates,#t.saved().candidates},{nil,1,1})
  end)

  test("B8-U legacy point transactions work with the minimal store fixture", function()
    local t=boot()
    local store=t.machine.env.SO.store
    t.machine.env.SO.store={store=store.store,read=store.read}
    local mod=t.machine.env.dofile("so-mod-drops.lua")
    assert(mod.add(point()))
    assert(mod.note("ore")) assert(mod.fix("ore")) assert(mod.remove("ore"))
    equal(mod.list(),{})
  end)

end
