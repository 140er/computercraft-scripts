local fixture=dofile("tests/so/build-world-fixture.lua")
return function(test,equal)
  for _,case in ipairs({{"floor",5,1,5,25},{"box",3,3,3,26}}) do
    test("builder paired worker places exact "..case[1].." after server restart",function()
      local f=fixture() f.configure(case[1],case[2],case[3],case[4]) f.crashAt=4 f.command("start")
      for _=1,1000 do f.net.advance(0.1) if f.crashed then break end end
      assert(f.crashed,"server crash hook did not run")
      f.restart() equal(f.job().cursor,4) f.finish()
      equal(f.places,case[5])
      for y=0,case[3]-1 do for z=0,case[4]-1 do for x=0,case[2]-1 do
        local k=x..","..y..","..z
        if case[1]=="floor" or x==0 or x==case[2]-1 or y==0 or y==case[3]-1 or z==0 or z==case[4]-1 then
          equal(f.net.world[k],"minecraft:stone") equal(f.placed[k],1)
        else equal(f.net.world[k],nil) end
      end end end
      assert(f.worker.env.fs.getFreeSpace("/")>0,"worker exceeded 1 MB")
    end)
  end
  test("builder paired worker refills from a real storage inventory",function()
    local f=fixture() f.configure("floor",5,1,5) f.chest.inv[1].count=3 f.command("start")
    for _=1,1000 do f.advance(0.25) if f.job().blocked=="material" then break end end
    equal(f.places,3) equal(f.job().alert,"out of material")
    f.chest.inv[1].count=64
    f.advance(11) f.finish() equal(f.places,25)
  end)
  test("builder outage parks above foreign reservations without inherited fallback digs",function()
    local f=fixture() f.configure("floor",5,1,5)
    f.beforeCrash=function()
      assert(f.server.env.SO.mods.cells.reserve("mine:7",0,2,0,"minecraft:overworld"))
    end
    f.crashAt=2 f.command("start")
    for _=1,1000 do f.net.advance(0.1) if f.crashed then break end end
    assert(f.crashed)
    local before={x=f.worker.pos.x,y=f.worker.pos.y,z=f.worker.pos.z}
    f.net.advance(160)
    assert(not f.worker.error,tostring(f.worker.error))
    equal(f.worker.pos,before)
    local journal=f.worker.env.textutils.unserialize(f.worker.files["so-journal"]).value
    equal(journal.park,true)
    f.worker.killed=false f.worker.co=nil f.worker.inbox={} f.worker.timers={}
    journal.dug={{x=journal.pose.x,y=journal.pose.y+1,z=journal.pose.z}}
    journal.moves={{n=1,op="down",ok=true}}
    f.seedJournal(journal)
    local outside=before.x..","..(before.y+1)..","..before.z
    f.net.world[outside]="minecraft:diamond_block"
    f.worker.boot("worker.lua") f.net.flush() f.net.advance(160)
    assert(not f.worker.error,tostring(f.worker.error))
    equal(f.worker.pos,before) equal(f.net.world[outside],"minecraft:diamond_block")
  end)
  test("builder retirement veto and volume bounds reach the actual cells selector",function()
    local F=dofile("tests/so/dug-fixture.lua")
    local cells,m,net=F.setup(nil,500)
    m.install({"so-ui.lua","so-mod-build.lua"})
    local dim="minecraft:overworld"
    local pose={dim=dim,x=9000,y=4,z=0,facing=0}
    local job={dim=dim,cursor=1,running=true,phase="check",inv={},home=pose,
      blueprint={shape="floor",x1=1616,y1=0,z1=0,x2=1631,y2=0,z2=15},
      turtle={id=2,pose=pose,frame={dim=dim,ox=0,oy=0,oz=0,rot=0}}}
    assert(m.env.SO.store.store("so-data/build/job",function() return true end).save(job))
    local callback
    m.env.SO.mods.lease={dugProtection=function() return true end,status=function() return {} end,onReport=function(_,fn) callback=fn end,
      send=function() return "recover" end}
    local build=m.env.dofile("so-mod-build.lua") m.env.SO.mods.build=build
    assert(cells.tick(net.time)) equal(cells.retirement(),nil)
    build.tick()
    callback("recover",2,{{ok=false,err="No block to inspect"}},{report={pose={x=9000,y=4,z=0,f=0}}})
    net.time=net.time+10000 assert(cells.tick(net.time))
    local request=assert(cells.retirement())
    assert(cells.decideRetirement(request.id,"allow"))
    equal(cells.isDug(1616,0,0),true)
    equal(cells.isDug(2880,0,0),false)
  end)

end
