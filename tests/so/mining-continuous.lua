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
  s.add=function(id,x)
    local key=string.rep("a",64)
    assert(server.env.SO.pair.remember(id,key))
    local turtle=net.machine({id=id,modem=true,turtle=true,x=x,fuel=4000,capacity=1000000})
    turtle.install({"worker.lua","so-store.lua","so-pair.lua","so-proto.lua"})
    for path,data in pairs(server.files) do if path:find("lib/ccryptolib/",1,true)==1 then turtle.files[path]=data end end
    turtle.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
    turtle.boot("worker.lua") net.flush()
    s.command("add "..id.." "..x.." 0 0 n") net.advance(1)
    s.turtles[#s.turtles+1]=turtle
    return turtle
  end
  s.restart=function()
    net.kill(server) server=net.boot(server) net.flush() net.advance(1) s.server=server
  end
  return s
end
return function(test,equal)
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
    s.command("branches 4") s.command("start") s.net.advance(100)
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
