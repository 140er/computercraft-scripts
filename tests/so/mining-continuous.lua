local H = dofile("tests/so/harness.lua")
local M = dofile("so-mine-plan.lua")
local function setup()
  local net=H.new()
  local server=net.machine({id=1,modem=true})
  server.install({"so-server.lua","so-store.lua","so-mod-state.lua","so-pair.lua","so-proto.lua","so-mod-lease.lua",
    "so-mod-cells.lua","so-mod-display.lua","so-mod-drops.lua","so-mod-mine.lua","so-mine-plan.lua","so-plan.lua","so-ui.lua"})
  for _,name in ipairs({"x25519","random","blake3","chacha20","config","internal/util","internal/hw",
    "internal/curve25519","internal/fp","internal/edwards25519","internal/packing"}) do
    local path="lib/ccryptolib/"..name..".lua"
    local f=assert(io.open(path)) server.files[path]=f:read("*a") f:close()
  end
  server.files["so-server.cfg"]=H.encode({pos={dim="minecraft:overworld",x=0,y=0,z=0}})
  server.boot("so-server.lua") net.flush() net.advance(1)
  local s={net=net,server=server,turtles={}}
  s.command=function(text) server.env.SO.mods.display.screen("mining").input({text=text}) end
  s.job=function() return server.env.SO.store.read("so-data/mine/job").value end
  s.add=function(id,x,tools,y,z)
    y,z=y or 0,z or 0
    local key=string.rep("a",64)
    assert(server.env.SO.pair.remember(id,key))
    local turtle=net.machine({id=id,modem=true,turtle=true,x=x,y=y,z=z,fuel=4000,capacity=1000000})
    turtle.install({"worker.lua","so-store.lua","so-pair.lua","so-proto.lua"})
    for path,data in pairs(server.files) do if path:find("lib/ccryptolib/",1,true)==1 then turtle.files[path]=data end end
    turtle.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
    if tools then
      turtle.env.turtle.getEquippedLeft=function() return {name=tools.left} end
      turtle.env.turtle.getEquippedRight=function() return {name=tools.right} end
      turtle.files["so-worker.cfg"]="{autoToolSwap=false}"
    end
    turtle.boot("worker.lua") net.flush()
    s.command("add "..id.." "..x.." "..y.." "..z.." n") net.advance(1)
    s.turtles[#s.turtles+1]=turtle
    return turtle
  end
  s.restart=function()
    net.kill(server) server=net.boot(server) net.flush() net.advance(1) s.server=server
  end
  return s
end
return function(test,equal)
  test("axe-only mining refuses digs with tool swaps off",function()
    local s=setup()
    local tools={left="minecraft:diamond_axe",right="computercraft:wireless_modem"}
    local worker=s.add(2,0,tools)
    local drops=s.server.env.SO.mods.drops
    for i,kind in ipairs({"ore","fuel"}) do
      assert(drops.add({id=kind,dim=0,x=-10-i,y=-1,z=0,side="down",kind=kind}))
    end
    s.command("home 0 0 0 n") s.command("bottom -2") s.command("length 2") s.command("mode fast")
    for y=-2,0 do s.net.world["0,"..y..",-1"]="minecraft:stone" end
    local lease=s.server.env.SO.mods.lease
    equal(lease.status(2).autoToolSwap,false)
    equal(lease.ensureTool(2,"pickaxe"),true)
    local digs,alerts=0,0
    local emit=s.server.env.SO.mods.state.emit
    s.server.env.SO.mods.state.emit=function(kind,data)
      if kind=="mine.alert" and type(data)=="table" and data.text=="needs pickaxe" then alerts=alerts+1 end
      return emit(kind,data)
    end
    for _,op in ipairs({"dig","digUp","digDown"}) do
      local original=worker.env.turtle[op]
      worker.env.turtle[op]=function(...) digs=digs+1 return original(...) end
    end
    s.command("start");assert(s.job().running,"informational readiness blocked start")
    for _=1,120 do
      s.net.advance(1)
      assert(s.server.alive(),tostring(s.server.error));assert(worker.alive(),tostring(worker.error))
      if s.job().progress.done>=1 then break end
    end
    equal(s.job().progress.done,0)
    equal(s.net.world["0,-2,-1"],"minecraft:stone")
    equal(digs,0)
    equal(s.job().turtles["2"].error,"needs pickaxe")
    equal(worker.screen[4],"needs pickaxe")
    equal(alerts,1)
    tools.left="minecraft:diamond_pickaxe"
    for _=1,200 do
      s.net.advance(1)
      assert(not s.server.error,tostring(s.server.error))
      if s.job().progress.done==1 then break end
    end
    equal(s.job().progress.done,1)
    assert(digs>0)
  end)

  for _,cell in ipairs({{x=2,y=-2,z=-3},{x=0,y=-1,z=-1},{x=0,y=-2,z=-3}}) do
    test("mining skips an undiggable cell and finishes at "..M.key(cell),function()
      local s=setup() local worker=s.add(2,0)
      assert(s.server.env.SO.mods.drops.add({id="all",dim=0,x=-10,y=0,z=0,side="front",kind="any"}))
      s.command("home 0 0 0 n") s.command("bottom -2") s.command("length 4") s.command("mode fast")
      s.command("branches 2")
      local key=M.key(cell)
      s.net.world[key]="minecraft:bedrock"
      s.net.world["3,-2,-3"]="minecraft:stone"
      local tries=0
      for _,op in ipairs({"dig","digUp","digDown"}) do
        local original=worker.env.turtle[op]
        worker.env.turtle[op]=function(...)
          local pose={x=worker.pos.x,y=worker.pos.y,z=worker.pos.z,facing=worker.heading}
          local target=M.cell(pose,op=="digUp" and "up" or op=="digDown" and "down" or "forward")
          if M.same(cell,target) then tries=tries+1 return false,"Unbreakable block detected" end
          return original(...)
        end
      end
      s.command("start")
      local restarted=false
      for _=1,200 do
        s.net.advance(1)
        assert(not s.server.error,tostring(s.server.error))
        assert(not worker.error,tostring(worker.error))
        if tries>0 and not restarted then s.restart() restarted=true end
        if s.job().progress.done==2 then break end
      end
      assert(restarted)
      equal(tries,3) equal(s.job().digFailures[key],3)
      equal(s.net.world[key],"minecraft:bedrock")
      equal(s.net.world["3,-2,-3"],nil)
      equal(s.job().progress.done,2)
      equal(s.job().turtles["2"].state,"done")
    end)
  end

  test("mining replans a bedrock detour around a newly inspected chest",function()
    local s=setup() local worker=s.add(2,0)
    assert(s.server.env.SO.mods.drops.add({id="all",dim=0,x=-10,y=0,z=0,side="front",kind="any"}))
    s.command("home 0 0 0 n") s.command("bottom -2") s.command("length 4") s.command("mode fast")
    s.command("continuous on") s.command("branches 1")
    local bedrock,chest="2,-2,-3","1,-2,-2"
    s.net.world[bedrock]="minecraft:bedrock"
    s.net.world[chest]={name="minecraft:chest",inv={}}
    s.net.world["3,-2,-3"]="minecraft:stone"
    local tries,inspected=0,0
    for _,op in ipairs({"dig","digUp","digDown","inspect","inspectUp","inspectDown"}) do
      local original=worker.env.turtle[op]
      worker.env.turtle[op]=function(...)
        local pose={x=worker.pos.x,y=worker.pos.y,z=worker.pos.z,facing=worker.heading}
        local target=M.cell(pose,op:find("Up") and "up" or op:find("Down") and "down" or "forward")
        if op:find("dig",1,true) then
          assert(M.key(target)~=chest,"mining tried to dig the chest")
          if M.key(target)==bedrock then tries=tries+1 return false,"Unbreakable block detected" end
        elseif M.key(target)==chest then inspected=inspected+1 end
        return original(...)
      end
    end
    s.command("start")
    for _=1,240 do
      s.net.advance(1)
      assert(not s.server.error,tostring(s.server.error))
      assert(not worker.error,tostring(worker.error))
      local row=s.job().turtles["2"]
      assert(row.state~="hold",tostring(row.error))
      if s.job().progress.done==1 then break end
    end
    equal(tries,3) assert(inspected>0,"the detour never discovered the chest")
    equal(s.net.world[chest].name,"minecraft:chest")
    equal(s.net.world["3,-2,-3"],nil)
    equal(s.job().progress.done,1) equal(s.job().turtles["2"].state,"done")
  end)

  test("mining detours avoid known containers, protected cells and failed digs",function()
    local job={dim="minecraft:overworld",digFailures={["2,-2,-3"]=3}}
    local chest={x=1,y=-2,z=-2}
    local protected={x=1,y=-1,z=-3}
    local row={pose={x=1,y=-2,z=-3,facing=1},goal={x=3,y=-2,z=-3},detour={chest}}
    local function lookup(cell)
      if M.same(cell,chest) then return {name="minecraft:chest"} end
      if M.same(cell,protected) then return {name="minecraft:stone",protected=true} end
      return false
    end
    local action=M.next(job,row,lookup,{},4000)
    assert(action.detour and #action.detour>0,"stale detour was not replanned")
    for _,cell in ipairs(action.detour) do assert(not M.impassable(job,cell,lookup)) end
    assert(M.impassable(job,{x=0,y=-2,z=0},lookup,{x=0,y=-2,z=0}),"drop point was not protected")
    for _,block in ipairs({{name="minecraft:barrel"},{name="minecraft:shulker_box"},
      {name="mod:box",tags={["c:chests"]=true}}}) do
      assert(M.impassable(job,chest,function() return block end),block.name.." was not avoided")
    end
  end)

  test("mining skips an unreachable goal instead of holding",function()
    local job={dim="minecraft:overworld"}
    local row={pose={x=1,y=-2,z=-3,facing=1},goal={x=3,y=-2,z=-3}}
    local action=M.next(job,row,function(cell)
      if M.same(cell,row.pose) or M.same(cell,row.goal) then return false end
      return {name="minecraft:barrel"}
    end,{},4000)
    equal(action.kind,"skip") equal(action.cell,row.goal) equal(#action.steps,0)
  end)

  test("mining completes skipped branch cells when no detour exists",function()
    local s=setup() local worker=s.add(2,0)
    assert(s.server.env.SO.mods.drops.add({id="all",dim=0,x=-10,y=0,z=0,side="front",kind="any"}))
    s.command("home 0 0 0 n") s.command("bottom -2") s.command("length 4") s.command("mode fast")
    s.command("continuous on") s.command("branches 1") s.command("start")
    local enclosed=false
    for _=1,240 do
      s.net.advance(1)
      assert(not s.server.error,tostring(s.server.error))
      assert(not worker.error,tostring(worker.error))
      local row=s.job().turtles["2"]
      if not enclosed and row.pose.x==1 and row.pose.y==-2 and row.pose.z==-3 then
        for _,delta in ipairs({{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}) do
          s.net.world[(1+delta[1])..","..(-2+delta[2])..","..(-3+delta[3])]="minecraft:barrel"
        end
        enclosed=true
      end
      assert(row.state~="hold",tostring(row.error))
      if s.job().progress.done==1 then break end
    end
    assert(enclosed) equal(s.job().progress.done,1)
    equal(s.job().turtles["2"].state,"done")
    assert(s.job().skipped["4,-2,-3"],"unreachable branch end was not skipped")
  end)

  for _,duringReturn in ipairs({false,true}) do
    test("removed miner returns its unfinished claim, returning="..tostring(duringReturn),function()
      local s=setup() local worker=s.add(2,0)
      assert(s.server.env.SO.mods.drops.add({id="all",dim=0,x=-10,y=0,z=0,side="front",kind="any"}))
      s.command("home 0 0 0 n") s.command("bottom -2") s.command("length 6") s.command("mode fast")
      s.command("branches 2")
      for x=1,6 do
        s.net.world[x..",-2,-3"]="minecraft:stone"
        s.net.world[x..",-2,-5"]="minecraft:stone"
      end
      s.command("start")
      local removed=false
      for _=1,200 do
        s.net.advance(1)
        local row=s.job().turtles["2"]
        if not M.inLane(s.job(),row.pose) and (duringReturn and row.returning or not duringReturn and row.counted==nil and row.pose.x>=1) then
          s.command("stop") s.net.advance(2)
          local before=s.job()
          local claim=duringReturn and before.turtles["2"].returning.branch or before.turtles["2"].branch
          s.command("remove 2")
          equal(s.job().turtles["2"],nil)
          equal(s.job().unfinished,{claim})
          equal(s.job().progress.nextBranch,before.progress.nextBranch)
          s.net.kill(worker) s.restart()
          s.add(3,7,nil,-2,-3) s.command("start")
          removed=true break
        end
      end
      assert(removed,"did not reach removal point")
      for _=1,300 do
        s.net.advance(1)
        assert(not s.server.error,tostring(s.server.error))
        if s.job().progress.done==2 then break end
      end
      equal(s.job().progress.done,2) equal(s.job().progress.nextBranch,2)
      equal(s.job().unfinished,{})
      for x=1,6 do
        equal(s.net.world[x..",-2,-3"],nil)
        equal(s.net.world[x..",-2,-5"],nil)
      end
    end)
  end

  for _,mode in ipairs({"fast","thorough"}) do
    test("continuous mining finishes six unique branches with two miners and restart in "..mode,function()
      local s=setup()
      s.add(2,0) s.add(3,2)
      local drops=s.server.env.SO.mods.drops
      for i,kind in ipairs({"ore","fuel"}) do
        assert(drops.add({id=kind,dim=0,x=-10-i,y=-1,z=0,side="down",kind=kind}))
      end
      s.command("home 0 0 0 n") s.command("bottom -2") s.command("length 3")
      s.command("mode "..mode) s.command("branches 6")
      for y=-2,0 do s.net.world["0,"..y..",-1"]="minecraft:stone" end
      local gap=mode=="fast" and 2 or 4
      for z=-2,-(1+6*gap),-1 do s.net.world["0,-2,"..z]="minecraft:stone" end
      for branch=0,5 do for x=1,3 do s.net.world[x..",-2,"..-(1+(branch+1)*gap)]="minecraft:stone" end end
      local counted,dug,parks,returned={}, {},0,false
      local function observe()
        local mods=s.server.env.SO.mods
        local emit=mods.state.emit
        mods.state.emit=function(kind,data)
          if kind=="mine.progress" then
            counted[data.branch]=(counted[data.branch] or 0)+1
            equal(counted[data.branch],1,"branch counted twice")
          end
          return emit(kind,data)
        end
        local send=mods.lease.send
        mods.lease.send=function(id,steps,opts)
          local job=s.job()
          local row=job.turtles[tostring(id)]
          if opts.ms==600000 and not opts.recover and row.state=="done" then
            parks=parks+1
            assert(job.progress.nextBranch==6,"parked before claiming all branches")
          end
          return send(id,steps,opts)
        end
        local mark=mods.cells.markDug
        mods.cells.markDug=function(x,y,z,dim)
          local key=x..","..y..","..z
          dug[key]=(dug[key] or 0)+1 equal(dug[key],1,"dug cell counted twice")
          return mark(x,y,z,dim)
        end
      end
      observe()
      for _,turtle in ipairs(s.turtles) do
        for _,op in ipairs({"forward","back","up","down"}) do
          local move=turtle.env.turtle[op]
          turtle.env.turtle[op]=function(...)
            local ok,err=move(...)
            if ok then
              for _,other in ipairs(s.turtles) do if other~=turtle then
                assert(not M.same(turtle.pos,other.pos),"miners collided")
                local job=s.job()
                assert(not (M.inLane(job,turtle.pos) and M.inLane(job,other.pos)),"two miners in shared lane")
              end end
            end
            return ok,err
          end
        end
      end
      s.command("start")
      for _=1,500 do
        s.net.advance(1)
        local job=s.job()
        assert(not s.server.error,tostring(s.server.error))
        for _,t in ipairs(s.turtles) do assert(not t.error,tostring(t.error)) end
        if not returned then
          for _,row in pairs(job.turtles) do if row.returning then
            assert(row.counted==row.branch)
            s.restart() observe() returned=true break
          end end
        end
        if job.progress.done==6 then break end
      end
      local job=s.job()
      equal(job.progress.done,6) equal(job.progress.nextBranch,6)
      assert(returned,"did not restart during branch handoff")
      for branch=0,5 do equal(counted[branch],1) end
      for branch=0,5 do for x=1,3 do equal(s.net.world[x..",-2,"..-(1+(branch+1)*gap)],nil) end end
      s.net.advance(5)
      equal(s.job().turtles["2"].state,"done") equal(s.job().turtles["3"].state,"done")
      assert(parks>=2)
      local before=s.job().progress.done
      s.restart() s.net.advance(20) equal(s.job().progress.done,before)
    end)
  end
  test("continuous mining stop keeps its branch budget and resumes the return route",function()
    local s=setup() s.add(2,0)
    assert(s.server.env.SO.mods.drops.add({id="all",dim=0,x=-10,y=0,z=0,side="front",kind="any"}))
    s.command("home 0 0 0 n") s.command("bottom -2") s.command("length 3") s.command("branches 3") s.command("start")
    for _=1,100 do s.net.advance(1) if s.job().turtles["2"].returning then break end end
    assert(s.job().turtles["2"].returning)
    s.command("stop") s.net.advance(2)
    local before=s.job()
    s.net.advance(10)
    equal(s.job().progress,before.progress) equal(s.job().turtles["2"].pose,before.turtles["2"].pose)
    s.command("start") s.net.advance(100)
    equal(s.job().progress.done,3)
    s.command("stop") s.net.advance(2) s.command("branches 4") s.command("start") s.net.advance(100)
    equal(s.job().progress.done,4) equal(s.job().progress.nextBranch,4)
  end)
  test("continuous mining retains its next claim through ore and fuel trips during return",function()
    local s=setup() local worker=s.add(2,0)
    local ore={name="minecraft:chest",inv={}}
    local fuel={name="minecraft:chest",inv={{name="minecraft:coal",count=64}}}
    s.net.world["-11,-1,0"],s.net.world["-12,-1,0"]=ore,fuel
    local drops=s.server.env.SO.mods.drops
    assert(drops.add({id="ore",dim=0,x=-11,y=-1,z=0,side="down",kind="ore"}))
    assert(drops.add({id="fuel",dim=0,x=-12,y=-1,z=0,side="down",kind="fuel"}))
    s.command("home 0 0 0 n") s.command("bottom -2") s.command("length 3") s.command("branches 3") s.command("start")
    for _=1,100 do s.net.advance(1) if s.job().turtles["2"].returning then break end end
    local claim=assert(s.job().turtles["2"].returning).branch
    worker.fuel=70
    for slot=1,16 do worker.inv[slot]={name="minecraft:diamond",count=1} end
    local trips={}
    for _=1,300 do
      s.net.advance(1)
      local row=s.job().turtles["2"]
      if row.trip then
        trips[row.trip.kind]=true
        assert(row.returning and row.returning.branch==claim,"supply trip lost its next claim")
      end
      if s.job().progress.done==3 then break end
    end
    assert(trips.ore and trips.fuel,"did not unload and refuel during return")
    equal(s.job().progress.done,3) equal(s.job().progress.nextBranch,3)
    local count=0 for _,item in ipairs(ore.inv) do count=count+item.count end equal(count,16)
  end)

  test("continuous mining finishes a vein found during its branch return before taking the next route",function()
    local s=setup() s.add(2,0)
    assert(s.server.env.SO.mods.drops.add({id="all",dim=0,x=-10,y=0,z=0,side="front",kind="any"}))
    local emit=s.server.env.SO.mods.state.emit
    local inserted=false
    s.server.env.SO.mods.state.emit=function(kind,data)
      if kind=="mine.progress" and data.branch==0 then
        s.net.world["2,-1,-3"]="minecraft:diamond_ore" inserted=true
      end
      return emit(kind,data)
    end
    s.command("home 0 0 0 n") s.command("bottom -2") s.command("length 3") s.command("mode fast")
    s.command("branches 2") s.command("start")
    s.net.advance(150)
    assert(inserted)
    equal(s.net.world["2,-1,-3"],nil)
    equal(s.job().progress.done,2) equal(s.job().progress.nextBranch,2)
    equal(s.job().turtles["2"].ores,1)
  end)

end
