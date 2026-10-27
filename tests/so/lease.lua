local H = dofile("tests/so/harness.lua")
-- Generated with formal/evidence/lease-orderings.json by formal/verify_lease.py.
-- Part tests carry this hash because their input set excludes formal evidence.
local evidenceSourceHash = "7ec5b4f2f4d4c148a5bf7b6c2661ab437f6ace8bb5c92bbdaadf46954a243169"
local key = string.rep("a", 64)
local function setup(position, gpsPos)
  local net = H.new()
  local server = net.machine({ id = 1, modem = true })
  server.install({ "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua",
    "so-mod-state.lua", "so-log.lua", "so-mod-lease.lua", "so-mod-cells.lua", "so-plan.lua" })
  local libs = {
    "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing",
  }
  for _, name in ipairs(libs) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path, "rb"))
    server.files[path] = f:read("*a")
    f:close()
  end
  server.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["2"] = key, ["3"] = key } } })
  server.files["so-server.cfg"] = H.encode({pos=position, protectedAreas=false, alternateAxisOrders=false, storageDeliveries=false, workerSettings=false})
  if gpsPos then server.env.gps = { locate = function(timeout)
    assert(timeout == 2)
    return gpsPos.x, gpsPos.y, gpsPos.z
  end } end
  server.boot("so-server.lua")
  assert(server.alive(), tostring(server.error))
  local lease = assert(server.env.SO.mods.lease, table.concat(server.log, "\n"))
  local calls, released = {}, {}
  local cells = server.env.SO.mods.cells
  local releaseOwner = cells.releaseOwner
  cells.releaseOwner = function(owner)
    released[#released + 1] = owner
    return releaseOwner(owner)
  end
  lease.onReport("mine", function(id, turtleId, results, record)
    calls[#calls + 1] = { id = id, turtleId = turtleId, results = results, lease = record }
    assert(lease.ackOutcome(id))
  end)
  local worker = net.machine({ id = 2, modem = true, turtle = true })
  worker.install({ "so-proto.lua" })
  worker.env.KEY = key
  worker.spawn([[
    P = dofile("so-proto.lua")
    batches, replies = {}, {}
    function send(t, body)
      rednet.send(1, assert(P.encode(P.build(KEY, t, body))), "so")
    end
    while true do
      local ev, sender, wire, protocol = os.pullEvent()
      if ev == "rednet_message" and sender == 1 and protocol == "so" then
        local msg = assert(P.decode(wire))
        assert(P.macOk(KEY, msg) and P.fresh(msg))
        if msg.t == "lease.batch" then
          assert(#msg.body.steps >= 1 and #msg.body.steps <= 16)
          batches[#batches + 1] = msg.body
          if auto then
            local results = {}
            for i, step in ipairs(msg.body.steps) do
              results[i] = { ok = turtle[step.op](), counts = {} }
            end
            send("step.report", { lease = msg.body.lease, results = results })
          end
        else replies[#replies + 1] = msg end
      end
    end
  ]])
  local function send(t, body)
    worker.env.send(t, body)
    net.flush()
    assert(not server.error, tostring(server.error))
    assert(not worker.error, tostring(worker.error))
  end
  return { net = net, server = server, worker = worker, lease = lease,
    calls = calls, released = released, cells = cells, send = send, state = server.env.SO.mods.state }
end
local origin = { dim = 0, x = 0, y = 0, z = 0 }
local steps = { { op = "forward" }, { op = "up" } }
local function restartJob(name)
  local s=dofile("tests/so/protected.lua").setup()
  s.manualOutcome=true
  s.m.install({"so-mod-mine.lua","so-mine-plan.lua","so-mod-lumber.lua","so-lumber-plan.lua","so-mod-build.lua","so-ui.lua"})
  local SO=s.m.env.SO
  local pose=SO.store.copy(s.pose)
  local row={pose=pose,anchor=SO.store.copy(pose),frame={dim=pose.dim,ox=0,oy=0,oz=0,rot=0},inv={},fuel=100,state="stopped"}
  local job
  if name=="mine" then
    job={homeSet=true,home={x=0,y=0,z=0,facing=1},dim=pose.dim,bottom=0,length=4,branches=1,
      mode="fast",ores={},turtles={["2"]=row},progress={nextBranch=0,done=0},running=false}
  elseif name=="lumber" then
    job={dim=pose.dim,ground=-2,spots={},turtles={["2"]={turtle={id=2,pose=pose,frame=row.frame},phase="scan",inv={},fuel=100}},running=false}
  else
    job={dim=pose.dim,cursor=1,running=false,phase="check",material="minecraft:stone",turtle={id=2,pose=pose,frame=row.frame},inv={},fuel=100}
  end
  s.path="so-data/"..name.."/job"
  assert(SO.store.store(s.path,function() return true end).save(job))
  SO.mods.display={screen=function() end}
  SO.mods.state={emit=function() return true end,canStart=function() return true end}
  SO.mods.drops={list=function() return {} end}
  s.loadJob=function()
    s.lease.describe=function() end
    s.job=s.m.env.dofile("so-mod-"..name..".lua") SO.mods[name]=s.job
  end
  s.reload=function()
    s.lease=s.m.env.dofile("so-mod-lease.lua") SO.mods.lease=s.lease
    s.hello()
    s.loadJob()
  end
  s.savedJob=function() return SO.store.store(s.path,function() return true end).value end
  s.row=function(j)
    if name=="mine" then return j.turtles["2"] end
    if name=="lumber" then return j.turtles["2"].turtle end
    return j.turtle
  end
  s.dispatch=function(op)
    local steps={{op=op}}
    local action={kind="travel",action="move",steps=steps,from=pose,pose=pose,boundary=true}
    local target=s.m.env.dofile("so-plan.lua").apply(pose,op)
    return assert(s.lease.send(2,steps,{owner=name,pose=target,frame=row.frame,intent=action}))
  end
  s.loadJob()
  return s
end
return function(test, equal, read)
  test("restart restores open work before dispatch and never resends it",function()
    local s=dofile("tests/so/protected.lua").setup()
    s.manualOutcome=true
    local lid=assert(s.lease.send(2,{{op="forward"}},{owner="mine"}))
    s.lease=s.m.env.dofile("so-mod-lease.lua") s.m.env.SO.mods.lease=s.lease
    equal(s.lease.status(2).open,lid)
    s.hello()
    local other,why=s.lease.send(2,{{op="forward"}},{owner="mine"})
    equal(other,nil) equal(why,"busy")
    s.lease.tick(1000)
    equal(#s.sent,1)
    s.report()
    equal(s.lease.outcome(2).id,lid)
    equal(s.lease.send(2,{{op="forward"}},{owner="mine"}),nil)
    assert(s.lease.ackOutcome(lid))
    s.hello()
    equal(s.lease.send(2,{{op="dig"}},{owner="mine"}),nil)
    local observation=assert(s.lease.send(2,{{op="inspectDown"}},{owner="mine",recover=true}))
    s.report({{ok=false,err="No block to inspect"}})
    assert(s.lease.ackOutcome(observation))
    local nextId=assert(s.lease.send(2,{{op="turnRight"}},{owner="mine"}))
    assert(nextId~=lid,"restart reused a lease identity")
  end)
  test("restart retries only a stationary inspection and learns its reported fence capabilities",function()
    local s=dofile("tests/so/protected.lua").setup()
    s.manualOutcome=true
    local lid=assert(s.lease.send(2,{{op="inspectDown"}},{owner="mine"}))
    s.lease=s.m.env.dofile("so-mod-lease.lua") s.m.env.SO.mods.lease=s.lease
    s.lease.tick(1000)
    equal(#s.sent,2) equal(s.sent[2].body.lease,lid)
    s.lease.handlers["step.report"]({from=2,body={lease=lid,results={{ok=false,err="No block to inspect"}},
      pose={x=0,y=0,z=0,f=1},journal="after",capabilities={parkBatch=true,setupFence=true}}})
    assert(s.lease.ackOutcome(lid))
    assert(s.lease.send(2,{{op="inspectDown"}},{owner="mine",recover=true}))
  end)
  test("lease persists open before send and failed sends remain uncertain",function()
    local s=dofile("tests/so/protected.lua").setup()
    s.m.env.rednet.send=function(_,wire)
      local disk=s.m.env.SO.store.store("so-data/cells/leases",function() return true end).value
      equal(disk.records[wire.body.lease].status,"open")
      error("radio failed")
    end
    local lid=assert(s.lease.send(2,{{op="forward"}},{owner="mine"}))
    equal(s.lease.status(2).open,lid)
    s.lease=s.m.env.dofile("so-mod-lease.lua")
    equal(s.lease.status(2).open,lid)
  end)
  test("lease failed open close and acknowledgement saves keep dispatch blocked",function()
    local s=dofile("tests/so/protected.lua").setup()
    s.manualOutcome=true
    s.m.capacity=1
    equal(s.lease.send(2,{{op="forward"}},{owner="mine"}),nil)
    equal(#s.sent,0)
    s.m.capacity=16000000
    local lid=assert(s.lease.send(2,{{op="forward"}},{owner="mine"}))
    local calls=0
    s.lease.onReport("mine",function() calls=calls+1 end)
    s.m.capacity=1
    s.report()
    equal(calls,0) equal(s.lease.status(2).open,lid)
    s.m.capacity=16000000
    s.report(nil,s.pose)
    equal(calls,1) equal(s.lease.outcome(2).id,lid)
    s.m.capacity=1
    equal(s.lease.ackOutcome(lid),false)
    equal(s.lease.send(2,{{op="dig"}},{owner="mine"}),nil)
    s.m.capacity=16000000
    assert(s.lease.ackOutcome(lid))
    equal(s.lease.outcome(2),nil)
  end)
  test("corrupt existing lease state refuses dispatch and protection activation",function()
    for _,value in ipairs({"broken",{schema=1,generation=1,value={v=2,seq=0,records={}}},
      {schema=1,generation=1,value={v=1,seq=0,records={broken={id="broken"}}}},
      {schema=1,generation=1,value={v=1,seq=1,records={bad={id="bad",turtleId=2,owner="mine",
        steps={{op="inspectDown"}},expires=1000,status="open",retryAt="broken"}}}}}) do
      local s=dofile("tests/so/protected.lua").setup(nil,{["so-data/cells/leases"]=value})
      local id,why=s.lease.send(2,{{op="forward"}},{owner="mine"})
      equal(id,nil) equal(why,"lease state unreadable") equal(#s.sent,0)
      equal(s.lease.protectionReady(),false)
    end
  end)
  test("corrupt lease state retains GPS recovery cells during explicit reassignment",function()
    local s=dofile("tests/so/protected.lua").setup(nil,{["so-data/cells/leases"]="broken"})
    assert(s.cells.reserve("gps:2",0,0,0,s.pose.dim))
    equal(s.lease.claimProbe(2,"mine:2",s.pose),false)
    equal(s.lease.clearProbe(2),false)
    equal(s.cells.owner(0,0,0,s.pose.dim),"gps:2")
  end)
  test("a corrupt lease generation blocks dispatch even beside a valid older backup",function()
    local s=dofile("tests/so/protected.lua").setup(nil,{
      ["so-data/cells/leases"]="broken",
      ["so-data/cells/leases.bak"]={schema=1,generation=1,value={v=1,seq=0,records={}}},
    })
    equal(s.lease.send(2,{{op="forward"}}),nil)
    equal(s.lease.status(2).persistenceError,"lease state unreadable")
    equal(#s.sent,0)
  end)
  for _,partial in ipairs({"", "{schema=1,generation="}) do
    test("uncommitted partial lease tmp permits dispatch: "..#partial.." bytes",function()
      local s=dofile("tests/so/protected.lua").setup(nil,{
        ["so-data/cells/leases"]={schema=1,generation=1,value={v=1,seq=0,records={}}},
        ["so-data/cells/leases.tmp"]=partial,
      })
      assert(s.lease.send(2,{{op="forward"}},{owner="mine"}))
      equal(s.lease.status(2).persistenceError,nil)
    end)
  end
  test("expiry save failure skips that worker and still expires another worker",function()
    local s=dofile("tests/so/protected.lua").setup()
    s.manualOutcome=true
    assert(s.lease.send(2,{{op="forward"}},{owner="mine",ms=1000}))
    s.lease.handlers.hello({from=3,body={role="turtle",journal={id="other",pose={x=3,y=0,z=0,f=1}},
      capabilities={setupFence=true,parkBatch=true}}})
    assert(s.lease.send(3,{{op="inspectDown"}},{owner="mine",ms=1000}))
    local SO=s.m.env.SO
    local store=SO.store.store
    local saves=0
    SO.store.store=function(...)
      local box=store(...)
      local save=box.save
      box.save=function(value)
        saves=saves+1
        if saves==1 then return false,"disk" end
        return save(value)
      end
      return box
    end
    s.lease=s.m.env.dofile("so-mod-lease.lua")
    s.lease.tick(11001)
    equal(saves,2)
    local open,expired=0,0
    for _,id in ipairs({2,3}) do
      if s.lease.status(id).open then open=open+1 end
      if s.lease.outcome(id) then expired=expired+1 end
    end
    equal(open,1) equal(expired,1)
  end)
  test("expired restart work requires a fenced observation and retains its route",function()
    local s=dofile("tests/so/protected.lua").setup()
    s.manualOutcome=true
    assert(s.cells.reserveMany("mine:2",{s.pose,{dim=s.pose.dim,x=1,y=0,z=0}}))
    local lid=assert(s.lease.send(2,{{op="forward"}},{owner="mine",ms=1000}))
    s.lease=s.m.env.dofile("so-mod-lease.lua") s.m.env.SO.mods.lease=s.lease
    s.hello() s.lease.tick(11001)
    equal(s.lease.outcome(2).status,"expired")
    assert(s.lease.ackOutcome(lid))
    equal(s.lease.send(2,{{op="dig"}},{owner="mine",recover=true}),nil)
    equal(#s.cells.list("mine:2",10),2)
    assert(s.lease.send(2,{{op="inspectDown"}},{owner="mine",recover=true}))
    s.report({{ok=false,err="No block to inspect"}})
    assert(s.lease.ackOutcome(s.lease.outcome(2).id))
    equal(s.lease.status(2).recovering,false)
    assert(s.lease.send(2,{{op="turnRight"}},{owner="mine"}))
  end)
  for _,name in ipairs({"mine","lumber","build"}) do
    for _,terminal in ipairs({false,true}) do
      test(name.." restart with an "..(terminal and "acknowledged" or "open").." lease reconciles its prefix once",function()
        local s=restartJob(name)
        local lid=s.dispatch("forward")
        if terminal then s.report() end
        s.reload()
        s.job.tick(0)
        if not terminal then
          equal(s.lease.status(2).open,lid)
          equal(#s.sent,1)
          s.report()
        end
        local saved=s.savedJob()
        equal(s.row(saved).pose.x,1)
        local receipt=name=="build" and saved.leaseReceipt or saved.turtles["2"].leaseReceipt
        equal(receipt,lid..":reported")
        equal(s.lease.outcome(2),nil)
        s.reload() s.job.tick(0)
        for i=2,#s.sent do
          for _,step in ipairs(s.sent[i].body.steps) do
            assert(step.op~="forward","replayed interrupted movement")
          end
        end
      end)
    end
    test(name.." restart after a failed prefix sends only stationary reconciliation",function()
      local s=restartJob(name)
      s.dispatch("forward")
      s.reload() s.job.tick(0)
      s.report({{ok=false,err="blocked"}})
      equal(s.row(s.savedJob()).pose.x,0)
      s.reload() s.job.tick(0)
      equal(#s.sent,2)
      for _,step in ipairs(s.sent[2].body.steps) do equal(step.op,"inspectDown") end
      s.report({{ok=false,err="No block to inspect"}})
      equal(s.row(s.savedJob()).pose.x,0)
    end)
    test(name.." failed caller save keeps the acknowledged prefix blocked until its receipt saves",function()
      local s=restartJob(name)
      local store=s.m.env.SO.store.store
      local fail=true
      s.m.env.SO.store.store=function(path,...)
        local box=store(path,...)
        local save=box.save
        if path==s.path then box.save=function(value) if fail then return false,"disk" end return save(value) end end
        return box
      end
      s.loadJob()
      local lid=s.dispatch("forward")
      s.job.tick(0) s.report()
      equal(s.lease.outcome(2).id,lid)
      for _=1,3 do s.job.tick(0) end
      equal(#s.sent,1)
      fail=false s.job.tick(0)
      equal(s.lease.outcome(2),nil)
      equal(s.row(s.savedJob()).pose.x,1)
    end)
  end
  for _,name in ipairs({"lumber","build"}) do
    test(name.." supply inspection strike survives caller save failure and restart once",function()
      local s=restartJob(name)
      local SO=s.m.env.SO
      s.m.install({"so-mod-drops.lua"})
      SO.mods.drops=s.m.env.dofile("so-mod-drops.lua")
      local point={id="supply",dim=0,x=0,y=-1,z=0,side="down",kind="storage"}
      assert(SO.mods.drops.add(point))
      local j=s.savedJob()
      local row=name=="lumber" and j.turtles["2"] or j
      row.service={point=point,kind="fuel",stage="check"}
      assert(SO.store.store(s.path,function() return true end).save(j))
      local store=SO.store.store
      local fail=true
      SO.store.store=function(path,...)
        local box=store(path,...)
        local save=box.save
        if path==s.path then box.save=function(value) if fail then return false,"disk" end return save(value) end end
        return box
      end
      s.loadJob()
      local steps={{op="inspectDown"}}
      local id=assert(s.lease.send(2,steps,{owner=name,intent={action="supplyCheck",steps=steps,pose=s.pose}}))
      s.job.tick(0) s.report({{ok=false,err="No block to inspect"}})
      equal(SO.store.read("so-drops").value.points[1].fails,1)
      equal(s.lease.outcome(2).id,id)
      fail=false
      SO.mods.drops=s.m.env.dofile("so-mod-drops.lua")
      s.reload() s.job.tick(0)
      equal(SO.store.read("so-drops").value.points[1].fails,1)
      equal(s.lease.outcome(2),nil)
    end)
  end
  test("stationary boundary recovery reconciles an unexpected pose without publishing the intended pose",function()
    local s=dofile("tests/so/protected.lua").setup()
    local stale=s.m.env.SO.store.copy(s.pose)
    local record
    s.lease.onReport("mine",function(_,_,_,lease) record=lease end)
    assert(s.lease.send(2,{{op="forward"}},{owner="mine"}))
    s.report(nil,{dim=stale.dim,x=4,y=0,z=0,facing=2})
    equal(s.lease.status(2).boundaryHold,true)
    assert(s.lease.send(2,{{op="inspectDown"}},{owner="mine",recover=true,pose=stale}))
    s.report({{ok=false,err="No block to inspect"}})
    equal(s.lease.status(2).boundaryHold,nil)
    equal(record.pose,s.pose)
    equal(s.lease.status(2).reconciled,true)
  end)
  test("lease safety rejects every remainder and requires acknowledged journal fences",function()
    local F=dofile("tests/so/protected.lua")
    for _,op in ipairs({"forward","back","up","down","turnLeft","turnRight"}) do
      local s=F.setup()
      local lid,why=s.lease.send(2,{{op=op},{op="dig"}},{owner="mine"})
      equal(lid,nil) equal(why,"acknowledged boundary required") equal(#s.sent,0)
      assert(s.lease.send(2,{{op=op}},{owner="mine",pose=s.m.env.dofile("so-plan.lua").apply(s.pose,op)}))
      local batch=s.sent[1].body
      equal(batch.journal,"j0") equal(batch.steps[1].park,true)
      s.report({{ok=false,err="blocked"}})
      equal(s.lease.status(2).boundaryHold,true)
      equal(s.lease.send(2,{{op="dig"}},{owner="mine"}),nil)
      equal(s.lease.send(2,{{op="suck"}},{owner="mine",recover=true}),nil)
      assert(s.lease.send(2,{{op="inspectDown"}},{owner="mine",recover=true}))
      s.report({{ok=false,err="No block to inspect"}})
      equal(s.lease.status(2).boundaryHold,nil)
    end
  end)
  test("lease protection assesses the proven start instead of the caller final pose",function()
    local s=dofile("tests/so/protected.lua").setup()
    assert(s.cells.protect({s.box("target",1,1)}))
    local lid,why=s.lease.send(2,{{op="forward"}},{owner="mine",pose={dim="minecraft:overworld",x=2,y=0,z=0,facing=1}})
    equal(lid,nil) equal(why,"protected") equal(#s.sent,0)
    assert(s.cells.protect({}))
    lid,why=s.lease.send(2,{{op="forward"}},{owner="mine",pose={dim="minecraft:overworld",x=2,y=0,z=0,facing=1}})
    equal(lid,nil) equal(why,"expected pose mismatch")
    s.hello(s.pose,{parkBatch=true})
    lid,why=s.lease.send(2,{{op="turnRight"}},{owner="mine"})
    equal(lid,nil) equal(why,"boundary needs certain fenced worker")
  end)
  test("GPS facing probes hold without a proven frame while protected movement is enabled",function()
    local s=dofile("tests/so/protected.lua").setup()
    s.lease.handlers.hello({from=3,body={role="turtle",fuel=100,gps={dim="minecraft:overworld",x=0,y=0,z=0},
      journal={id="probe",pose={x=0,y=0,z=0,f=0}},capabilities={parkBatch=true,setupFence=true}}})
    local reason
    s.lease.locate(3,"minecraft:overworld",function(_,why) reason=why end)
    equal(reason,"facing unknown; use explicit add") equal(#s.sent,0)
  end)
  test("lease formal evidence matches the current source bytes", function()
    local s = setup(origin)
    local proto = s.server.env.SO.proto
    equal(proto.hex(proto.sha256(read("so-mod-lease.lua"))), evidenceSourceHash,
      "lease evidence is stale; rerun python3 formal/verify_lease.py --evidence formal/evidence/lease-orderings.json")
  end)
  test("lease refuses a second open batch without sending", function()
    local s = setup(origin)
    local id = assert(s.lease.send(2, steps, { owner = "mine" }))
    assert(id:match("^2%-%d+%-1$"), "lease ID must include its durable clock")
    local other, reason = s.lease.send(2, steps)
    equal(other, nil)
    equal(reason, "busy")
    s.net.flush()
    equal(#s.worker.env.batches, 1)
    equal(s.worker.env.batches[1].expires, s.net.time + 60000)
    equal(s.lease.status(2).open, id)
  end)
  test("lease full worker report keeps planner cells emits pose and calls once", function()
    local s = setup(origin)
    s.worker.env.auto = true
    for i, owner in ipairs({ "mine:2", "lumber:2", "build:2", "setup:2" }) do
      assert(s.cells.reserve(owner, i, 0, 0))
    end
    local pose = { dim = 0, x = 0, y = 1, z = -1, facing = 0 }
    local id = assert(s.lease.send(2, steps, { owner = "mine", pose = pose }))
    s.net.flush()
    equal(s.lease.status(2).open, nil)
    equal(s.released, {})
    for i, owner in ipairs({ "mine:2", "lumber:2", "build:2", "setup:2" }) do
      equal(s.cells.owner(i, 0, 0), owner)
    end
    equal(#s.calls, 1)
    equal(s.calls[1].id, id)
    equal(s.calls[1].turtleId, 2)
    equal(#s.calls[1].results, 2)
    equal(s.state.get("machines/2").pose, pose)
    equal(s.worker.pos.y, 1)
    equal(s.worker.pos.z, -1)
  end)
  test("lease duplicate unknown and wrong sender reports have no effects", function()
    local s = setup(origin)
    local id = assert(s.lease.send(2, steps, { owner = "mine", pose = origin }))
    s.net.flush()
    s.lease.handlers["step.report"]({ from = 3, body = { lease = id, results = { { ok = true }, { ok = true } } } })
    equal(s.lease.status(2).open, id)
    local results = { { ok = true }, { ok = true } }
    s.send("step.report", { lease = id, results = results })
    local before = s.state.view().rev
    for _ = 1, 2 do
      s.send("step.report", { lease = id, results = results })
      s.send("step.report", { lease = "unknown", results = results })
    end
    equal(#s.calls, 1)
    equal(#s.released, 0)
    equal(s.state.view().rev, before)
  end)
  test("lease park cancellation leaves real planner owners intact", function()
    local s = setup(origin)
    assert(s.cells.reserve("mine:2", 1, 0, 0))
    assert(s.lease.send(2, {{op="inspectDown"}}, {owner="mine"}))
    assert(s.lease.cancelPark(2, "mine"))
    equal(s.lease.status(2).open, nil)
    equal(s.cells.owner(1, 0, 0), "mine:2")
    equal(s.released, {})
    equal(#s.calls, 0)
  end)
  test("lease silence expires after grace and keeps reservations", function()
    local s = setup(origin)
    assert(s.cells.reserve("mine:2", 1, 0, 0))
    local id = assert(s.lease.send(2, steps, { owner = "mine", ms = 1000 }))
    s.net.advance(11)
    equal(#s.calls, 0)
    s.net.advance(1)
    equal(s.lease.status(2).open, nil)
    equal(#s.calls, 1)
    equal(s.calls[1].results, nil)
    equal(s.calls[1].lease.status, "expired")
    equal(s.cells.owner(1, 0, 0), "mine:2")
    equal(#s.released, 0)
    s.send("step.report", { lease = id, results = { { ok = true }, { ok = true } } })
    s.net.advance(1)
    equal(#s.calls, 1)
    equal(#s.released, 0)
  end)
  test("lease beacon blocks sends and hello restores contact", function()
    local s = setup(origin)
    s.send("beacon", { id = 999, fuel = 42, journal = "2-17" })
    equal(s.lease.status(2).lost, true)
    equal(s.lease.status(2).seen, s.net.time)
    local id, reason = s.lease.send(2, steps)
    equal(id, nil)
    equal(reason, "lost")
    local row = s.state.get("machines/2")
    equal(row.fuel, 42)
    equal(row.seen, s.net.time)
    local events = s.state.history.page({ count = 50 }).entries
    equal(events[#events].data.journal, "2-17")
    s.send("hello", { role = "turtle", journal = { id = "2-17" } })
    equal(s.lease.status(2).lost, false)
    assert(s.lease.send(2, steps))
  end)
  test("lease range never shrinks below 16 and grows only on full success", function()
    local s = setup(origin)
    s.send("hello", { gps = { x = 3, y = 4, z = 0 } })
    equal(s.lease.status(2).range, 16)
    local pose = { dim = 0, x = 30, y = 40, z = 0, facing = 1 }
    local id = assert(s.lease.send(2, steps, { pose = pose }))
    s.send("step.report", { lease = id, results = { { ok = true }, { ok = true } } })
    equal(s.lease.status(2).range, 50)
    equal(s.lease.inRange(2, { dim = 0, x = 58, y = 0, z = 0 }), true)
    equal(s.lease.inRange(2, { dim = 0, x = 59, y = 0, z = 0 }), false)
    id = assert(s.lease.send(2, steps, { pose = { dim = 0, x = 100, y = 0, z = 0 } }))
    s.send("step.report", { lease = id, results = { { ok = true }, { ok = false } } })
    equal(s.lease.status(2).range, 50)
    equal(s.state.get("machines/2").pose, pose)
  end)
  test("lease first park report preserves the initial range and nearer reports keep proof", function()
    local s = setup(origin)
    local near = { dim = 0, x = 3, y = 4, z = 0 }
    local park = { { op = "inspectDown" } }
    local function report(pose)
      local id = assert(s.lease.send(2, park, { pose = pose }))
      s.send("step.report", { lease = id, results = { { ok = true } } })
    end
    report(near)
    equal(s.lease.status(2).range, 16)
    equal(s.lease.inRange(2, { dim = 0, x = 24, y = 0, z = 0 }), true)
    report({ dim = 0, x = 30, y = 40, z = 0 })
    report(near)
    equal(s.lease.status(2).range, 50)
  end)
  test("lease malformed reports preserve open work and missing modules are optional", function()
    local s = setup(origin)
    local id = assert(s.lease.send(2, steps, { owner = "mine", pose = origin }))
    s.send("step.report", { lease = id, results = { { ok = true } } })
    equal(s.lease.status(2).open, id)
    equal(#s.calls, 0)
    equal(#s.released, 0)
    s.server.env.SO.mods.cells = {}
    s.server.env.SO.mods.state = {}
    s.send("step.report", { lease = id, results = { { ok = true }, { ok = true } } })
    equal(s.lease.status(2).open, nil)
    equal(#s.calls, 1)
  end)
  test("lease history wire pages use UTC cursors and text without changing sequence pages", function()
    local s = setup(origin)
    local epoch = s.server.env.os.epoch
    local utc = 1700000000000
    s.server.env.os.epoch = function(kind) return kind == "utc" and utc or epoch(kind) end
    for i = 1, 105 do
      utc = utc + 1000
      assert(s.state.emit("sample", { text = "event " .. i }))
    end
    s.server.env.os.epoch = epoch
    local internal = s.state.history.page({ from = 100, count = 2 })
    equal(internal.entries[1].seq, 101)
    equal(internal.entries[2].seq, 102)
    equal(internal.next, 102)
    local function page(query)
      local n = #s.worker.env.replies
      s.send("history.page", query)
      local reply = s.worker.env.replies[n + 1]
      equal(reply.t, "history.page")
      return reply.body
    end
    local first = page({ limit = 2, from = 1, count = 1, reverse = false })
    equal(first.entries, {
      { at = utc, text = "sample event 105" },
      { at = utc - 1000, text = "sample event 104" },
    })
    equal(first.next, {at=utc-1000, seq=104})
    local second = page({ limit = 2, before = first.next })
    equal(second.entries[1], {at=utc-2000, text="sample event 103"})
    equal(second.entries[2], {at=utc-3000, text="sample event 102"})
    local last = page({ limit = 50, before = utc - 103000 })
    equal(last.entries, {{at=utc-104000, text="sample event 1"}})
    equal(last.next, nil)
    equal(#page({}).entries, 20)
    equal(#page({limit=99}).entries, 50)
    equal(#page({limit=0}).entries, 1)
    equal(s.state.history.page({from=100,count=2}), internal)
  end)
  test("lease history wire sorts UTC times and excludes equal cursor times", function()
    local s = setup(origin)
    local epoch = s.server.env.os.epoch
    local utc = 1700000000000
    s.server.env.os.epoch = function(kind) return kind == "utc" and utc or epoch(kind) end
    assert(s.state.emit("sample", "first"))
    utc = utc - 1000
    assert(s.state.emit("sample", {reason="older"}))
    utc = utc + 1000
    assert(s.state.emit("sample", false))
    s.server.env.os.epoch = epoch
    s.send("history.page", {limit=2})
    equal(s.worker.env.replies[1].body, {entries={
      {at=utc,text="sample cleared"}, {at=utc,text="sample first"}}, next={at=utc,seq=1}})
    s.send("history.page", {before=utc,limit=2})
    equal(s.worker.env.replies[2].body, {entries={{at=utc-1000,text="sample older"}}})
  end)
  test("lease history wire cursor retains equal-time overflow across pages", function()
    for _, count in ipairs({3,55}) do
      local s = setup(origin)
      local epoch, utc = s.server.env.os.epoch, 1700000000000
      s.server.env.os.epoch = function(kind) return kind == "utc" and utc or epoch(kind) end
      for i = 1, count do assert(s.state.emit("sample", {text="event " .. i})) end
      s.server.env.os.epoch = epoch
      local cursor
      for newest = count, 1, -2 do
        s.send("history.page", {limit=2, before=cursor})
        local reply = s.worker.env.replies[#s.worker.env.replies]
        equal(reply.t, "history.page")
        local expected = {{at=utc,text="sample event " .. newest}}
        if newest > 1 then expected[2] = {at=utc,text="sample event " .. (newest-1)} end
        equal(reply.body.entries, expected)
        cursor = reply.body.next
        equal(cursor, newest > 2 and {at=utc,seq=newest-1} or nil)
      end
      s.send("history.page", {limit=2, before=utc})
      equal(s.worker.env.replies[#s.worker.env.replies].body, {entries={}})
      s.send("history.page", {limit=2, before={at=utc}})
      equal(s.worker.env.replies[#s.worker.env.replies].body, {entries={}})
    end
  end)
  test("lease setup handoff commits only with the complete route", function()
    local s = setup(origin)
    local pose = {dim="minecraft:overworld",x=0,y=0,z=0}
    local route = {pose, {dim=pose.dim,x=1,y=0,z=0}}
    assert(s.cells.reserve("gps:2", 0, 0, 0))
    assert(s.cells.reserve("mine:3", 1, 0, 0))
    assert(s.lease.claimProbe(2, "setup:2", pose))
    equal(s.cells.owner(0, 0, 0), "gps:2")
    local ok, err = s.cells.reserveMany("setup:2", route)
    equal(ok, false)
    equal(err, "held")
    equal(#s.cells.list("setup:2", 10), 0)
    equal(s.cells.owner(0, 0, 0), "gps:2")
    assert(s.cells.releaseOwner("mine:3"))
    assert(s.lease.claimProbe(2, "setup:2", pose))
    local open = s.server.env.fs.open
    s.server.env.fs.open = function(path, mode)
      if path == "so-data/cells/res.tmp" and mode == "w" then return nil end
      return open(path, mode)
    end
    equal(s.cells.reserveMany("setup:2", route), false)
    equal(#s.cells.list("setup:2", 10), 0)
    equal(s.cells.owner(0, 0, 0), "gps:2")
    s.server.env.fs.open = open
    -- A failed reservation consumes the pending handoff.
    equal(s.cells.reserveMany("setup:2", route), false)
    assert(s.lease.claimProbe(2, "setup:2", pose))
    assert(s.cells.reserveMany("setup:2", route))
    equal(s.cells.owner(0, 0, 0), "setup:2")
    equal(s.cells.owner(1, 0, 0), "setup:2")
    assert(s.lease.clearProbe(2))
    equal(s.cells.owner(0, 0, 0), "setup:2")
  end)
  test("lease setup failure does not claim a free pose or change other planner handoffs", function()
    local s = setup(origin)
    local pose = {dim="minecraft:overworld",x=0,y=0,z=0}
    assert(s.cells.reserve("gps:2", 2, 0, 0))
    assert(s.cells.reserve("mine:3", 1, 0, 0))
    assert(s.lease.claimProbe(2, "setup:2", pose))
    equal(s.cells.reserveMany("setup:2", {pose,{dim=pose.dim,x=1,y=0,z=0}}), false)
    equal(s.cells.owner(0, 0, 0), nil)
    equal(#s.cells.list("setup:2", 10), 0)
    assert(s.lease.claimProbe(2, "mine:2", {dim=pose.dim,x=2,y=0,z=0}))
    equal(s.cells.owner(2, 0, 0), "mine:2")
  end)
  test("lease lost GPS probe requires fenced recovery before another add", function()
    local dim = "minecraft:overworld"
    local s = setup({dim=dim,x=0,y=0,z=0})
    local function hello()
      s.send("hello", {role="turtle", gps={dim=dim,x=0,y=0,z=0},
        journal={id="probe",pose={x=0,y=0,z=0,f=0}},capabilities={parkBatch=true,setupFence=true}})
    end
    hello()
    local reason
    s.lease.locate(2, dim, function(_, err) reason = err end)
    local first = assert(s.lease.status(2).open)
    s.net.advance(26)
    equal(reason, "GPS probe lost; retry add")
    s.net.advance(1)
    local recovery=assert(s.lease.status(2).open)
    assert(recovery~=first)
    s.net.flush()
    equal(s.worker.env.batches[#s.worker.env.batches].steps,{{op="gps",park=true}})
    s.send("step.report",{lease=recovery,results={{ok=true,data={dim=dim,x=0,y=0,z=0}}},
      journal="recovered",pose={x=0,y=0,z=0,f=0}})
    hello()
    s.lease.locate(2, dim, function() error("retry should start a probe") end)
    local retry = assert(s.lease.status(2).open)
    assert(retry ~= first)
    equal(s.lease.status(2).probing, true)
  end)
  test("lease range uses gps or allows positions without a server fix", function()
    local s = setup(nil, origin)
    equal(s.lease.status(2).range, 16)
    equal(s.lease.inRange(2, { x = 25, y = 0, z = 0 }), false)
    s = setup()
    equal(s.lease.inRange(2, { dim = 5, x = 99999, y = 0, z = 0 }), true)
    equal(s.lease.inRange(2, { dim = 5, x = 99999, y = 0, z = 0 }), true)
  end)
  local function settingsServer()
    local s=setup(origin)
    s.server.files["so-server.cfg"]=H.encode({workerSettings=true})
    s.send("hello",{role="turtle",capabilities={workerSettings=true},settingsControl=true,
      settings={seq=1,dim="minecraft:overworld",autoToolSwap=false,remoteN=4}})
    return s
  end
  local function replySettings(s,t,body,rid,from)
    local worker=from or s.worker
    local p=worker.env.P or s.worker.env.P
    local msg=p.build(key,t,body,rid)
    if from then msg.from=from.id msg.mac=p.sign(key,msg) end
    worker.env.rednet.send(1,msg,"so")
    s.net.flush()
  end
  test("lease settings can be disabled and old workers receive no command", function()
    local s=setup(origin)
    local before=#s.server.sent
    equal(s.lease.settings(2,{autoToolSwap=false}),nil)
    equal(#s.server.sent,before)
    s.server.files["so-server.cfg"]=H.encode({workerSettings=true})
    local rid,err=s.lease.settings(2,{autoToolSwap=false})
    equal(rid,nil); equal(err,"update required")
    equal(#s.server.sent,before)
  end)
  test("lease settings replies match authenticated sender rid command and counter without reply loops", function()
    local s=settingsServer()
    local rid=assert(s.lease.settings(2,{autoToolSwap=true}))
    local pending=s.lease.status(2).settingsPending
    equal(pending,{rid=rid,n=5})
    local confirmed={seq=2,dim="minecraft:overworld",autoToolSwap=true,remoteN=5}
    local before=#s.server.sent
    for _,body in ipairs({{command="worker.update",n=5,settings=confirmed},
      {command="worker.settings",n=4,settings=confirmed}}) do
      s.lease.handlers.ack({from=2,t="ack",rid=rid,body=body})
      equal(s.lease.status(2).settingsPending,pending)
    end
    replySettings(s,"ack",{command="worker.settings",n=5,settings=confirmed},rid.."-wrong")
    equal(s.lease.status(2).settingsPending,pending)
    local other=s.net.machine({id=3,modem=true})
    replySettings(s,"ack",{command="worker.settings",n=5,settings=confirmed},rid,other)
    equal(s.lease.status(2).settingsPending,pending)
    equal(#s.server.sent,before,"unmatched replies caused a reply loop")
    replySettings(s,"ack",{command="worker.settings",n=5,settings=confirmed},rid)
    equal(s.lease.status(2).settings,confirmed)
    equal(s.lease.status(2).settingsPending,nil)
    replySettings(s,"ack",{command="worker.settings",n=5,settings={seq=99,autoToolSwap=false}},rid)
    equal(s.lease.status(2).settings,confirmed)
  end)
  test("lease delayed ack and hello cannot replace newer confirmed settings or reuse an old intent", function()
    local s=settingsServer()
    local rid=assert(s.lease.settings(2,{autoToolSwap=true}))
    local newer={seq=3,dim="minecraft:the_nether",autoToolSwap=false,remoteN=5}
    s.send("hello",{role="turtle",capabilities={workerSettings=true},settingsControl=true,settings=newer})
    replySettings(s,"ack",{command="worker.settings",n=5,
      settings={seq=2,dim="minecraft:overworld",autoToolSwap=true,remoteN=5}},rid)
    s.send("hello",{role="turtle",capabilities={workerSettings=true},settingsControl=true,
      settings={seq=1,autoToolSwap=true,remoteN=4}})
    equal(s.lease.status(2).settings,newer)
    rid=assert(s.lease.settings(2,{autoToolSwap=true}))
    equal(s.lease.status(2).settingsPending.n,6)
    replySettings(s,"err",{command="worker.settings",code="settings",n=6,text="worker busy"},rid)
    equal(s.lease.status(2).settings,newer)
    equal(s.lease.status(2).settingsError,"worker busy")
    rid=assert(s.lease.settings(2,{autoToolSwap=true}))
    equal(s.lease.status(2).settingsPending.n,7)
    s.net.advance(16)
    equal(s.lease.status(2).settings,newer)
    equal(s.lease.status(2).settingsPending,nil)
    equal(s.lease.status(2).settingsError,"settings timed out")
  end)
  test("lease unassigned status requires assignments and open lease to clear", function()
    local s=settingsServer()
    local assigned=true
    s.server.env.SO.mods.build={assigned=function() return assigned end}
    s.net.advance(2)
    local function idleCount()
      local count=0
      for _,sent in ipairs(s.server.sent) do
        if sent.payload.t=="worker.status" and sent.payload.body.job=="" then count=count+1 end
      end
      return count
    end
    equal(idleCount(),0)
    equal(s.lease.settings(2,{autoToolSwap=true}),nil)
    assigned=false
    local lid=assert(s.lease.send(2,{{op="inspectDown"}},{ms=2000}))
    s.net.advance(1)
    equal(idleCount(),0)
    s.send("step.report",{lease=lid,results={{ok=true}}})
    s.net.advance(1)
    assert(idleCount()>0)
  end)
  test("lease tick isolates assigned and idle status send failures", function()
    for _,assigned in ipairs({false,true}) do
      local s=settingsServer()
      s.server.env.SO.mods.build={assigned=function() return assigned end}
      local attempted=false
      s.server.env.rednet.send=function(_,payload)
        local msg=s.server.env.SO.proto.decode(payload)
        if msg and msg.t=="worker.status" then attempted=true; error("status transport failed") end
      end
      local ok,err=pcall(s.lease.tick)
      assert(attempted,"lease tick did not attempt the status")
      assert(ok,tostring(err))
    end
  end)
  test("lease new pairing refreshes settings baseline and counter without pushing cached values", function()
    local s=settingsServer()
    assert(s.lease.settings(2,{autoToolSwap=true}))
    s.net.flush()
    local nextKey=string.rep("b",64)
    assert(s.server.env.SO.pair.remember(2,nextKey))
    s.worker.env.KEY=nextKey
    s.send("hello",{role="turtle",capabilities={workerSettings=true},settingsControl=true,
      settings={seq=0,autoToolSwap=false}})
    equal(s.lease.status(2).settings,{seq=0,autoToolSwap=false})
    equal(s.lease.status(2).settingsPending,nil)
    local count=0
    for _,sent in ipairs(s.server.sent) do if sent.payload.t=="worker.settings" then count=count+1 end end
    equal(count,1,"reconnect pushed cached settings")
    assert(s.lease.settings(2,{autoToolSwap=true}))
    equal(s.lease.status(2).settingsPending.n,1)
  end)

  test("lease legacy hellos keep dimension and tool facts when settings control is off", function()
    local s=setup(origin)
    s.server.install({"so-plan.lua"})
    s.server.files["so-server.cfg"]=H.encode({remoteDimensions=true})
    s.send("hello",{role="turtle",capabilities={workerSettings=true,dimensionSafety=true},
      settings={seq=0,autoToolSwap=false}})
    s.send("hello",{role="turtle",dim="minecraft:the_nether",
      capabilities={workerSettings=true,dimensionSafety=true,autoToolSwap=true},
      settings={seq=0,dim="minecraft:the_nether",autoToolSwap=true}})
    equal(s.lease.status(2).autoToolSwap,true)
    assert(s.lease.remoteReady(2,"minecraft:the_nether"))
    equal(s.lease.settings(2,{autoToolSwap=false}),nil)
  end)


  test("B2-B selected worker dimension and SWAP remain confirmed while pending until the matched ack",function()
    local s=settingsServer()
    local before=s.lease.status(2).settings
    local rid=assert(s.lease.settings(2,{dim="minecraft:the_nether",autoToolSwap=true}))
    equal(s.lease.status(2).settings,before)
    equal(s.lease.status(2).settingsPending,{rid=rid,n=5})
    equal(s.lease.settings(3,{autoToolSwap=true}),nil)
    equal(s.lease.status(2).settings,before)
    local confirmed={seq=2,dim="minecraft:the_nether",autoToolSwap=true,remoteN=5}
    replySettings(s,"ack",{command="worker.settings",n=5,settings=confirmed},rid)
    equal(s.lease.status(2).settings,confirmed) equal(s.lease.status(2).settingsPending,nil)
    rid=assert(s.lease.settings(2,{dim="minecraft:the_end",autoToolSwap=false}))
    equal(s.lease.status(2).settings,confirmed)
    local newer={seq=3,dim="minecraft:the_end",autoToolSwap=false,remoteN=6}
    s.send("hello",{role="turtle",capabilities={workerSettings=true},settingsControl=true,settings=newer})
    equal(s.lease.status(2).settings,newer) equal(s.lease.status(2).settingsPending,nil)
  end)
  test("B2-B server settings respect the worker flag capability and idle assignment eligibility",function()
    for _,case in ipairs({"worker flag","capability","build assignment","open lease","uncertain"}) do
      local s=settingsServer()
      if case=="worker flag" then
        s.send("hello",{role="turtle",capabilities={workerSettings=true},settingsControl=false,
          settings={seq=1,dim="minecraft:overworld",autoToolSwap=false}})
      elseif case=="capability" then
        s.send("hello",{role="turtle",capabilities={},settingsControl=true})
      elseif case=="build assignment" then
        s.server.env.SO.mods.build={assigned=function(id) return id==2 end}
      elseif case=="open lease" then assert(s.lease.send(2,{{op="inspectDown"}}))
      else s.send("hello",{role="turtle",journal={id="changed",pose={x=0,y=0,z=0,f=0},uncertain=true},
        capabilities={workerSettings=true},settingsControl=true,
        settings={seq=1,dim="minecraft:overworld",autoToolSwap=false}}) end
      local before=s.lease.status(2).settings
      local rid,err=s.lease.settings(2,{dim="minecraft:the_nether",autoToolSwap=true})
      equal(rid,nil,case)
      equal(err,case=="worker flag" and "settings disabled" or case=="capability" and "update required" or "worker busy",case)
      equal(s.lease.status(2).settings,before)
      equal(s.lease.status(2).settingsPending,nil)
    end
  end)

end
