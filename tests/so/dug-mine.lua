local H = dofile("tests/so/harness.lua")
local setup = dofile("tests/so/minor-ui-fixture.lua")
local F = dofile("tests/so/dug-fixture.lua")

local function addWorker(s, id)
  local turtle=s.net.machine({id=id,modem=true,turtle=true,fuel=4000,capacity=1000000})
  turtle.install({"worker.lua","so-store.lua","so-proto.lua","so-pair.lua"})
  for path,bytes in pairs(s.server.files) do if path:match("^lib/") then turtle.files[path]=bytes end end
  local key=string.rep("b",64)
  assert(s.server.env.SO.pair.remember(id,key))
  turtle.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
  turtle.boot("worker.lua") s.net.flush()
  return turtle
end

return function(test, equal)
  test("dug retirement: mining re-inspects a forgotten cell and counts its interrupted dig once",function()
    local dim="minecraft:overworld"
    local retired="so-data/cells/minecraft%3aoverworld/0_0_-1"
    local s=setup(26,20,function(server)
      server.opts.directories=true
      server.files["so-server.cfg"]=H.encode({pos={dim=dim,x=0,y=0,z=0}})
      F.seed(server,500)
      local value={format="hex4096",bits=string.rep("f",1024),used=0}
      for generation,suffix in ipairs({".bak",""}) do
        server.files[retired..suffix]=H.encode({schema=1,generation=generation,value=value})
      end
    end)
    s.press("allow")
    equal(s.server.env.SO.mods.cells.isDug(0,0,-1),false)
    assert(not s.server.files[retired] and not s.server.files[retired..".bak"])
    local turtle=addWorker(s,3)
    s.press("mining")
    for _,text in ipairs({"home 0 0 0 n","bottom -2","length 3","add 3 0 0 0 n"}) do s.typeText(text) end
    s.net.advance(1)
    s.net.world["0,0,-1"]="minecraft:diamond_ore"
    local inspected,digs,pending=false,0,nil
    local inspect,dig=turtle.env.turtle.inspect,turtle.env.turtle.dig
    turtle.env.turtle.inspect=function()
      if turtle.pos.x==0 and turtle.pos.y==0 and turtle.pos.z==0 and turtle.heading==0 then inspected=true end
      return inspect()
    end
    turtle.env.turtle.dig=function()
      if turtle.pos.x==0 and turtle.pos.y==0 and turtle.pos.z==0 and turtle.heading==0 then
        assert(inspected,"mining dug a retired cell before inspecting it") digs=digs+1
      end
      return dig()
    end
    local transmit=turtle.env.rednet.send
    turtle.env.rednet.send=function(id,payload,protocol)
      if payload.t=="step.report" and #payload.body.dug>0 then pending=payload return end
      return transmit(id,payload,protocol)
    end
    s.typeText("start")
    s.net.advance(5)
    assert(inspected and digs==1 and pending,"did not interrupt the inspected dig")
    s.net.kill(s.server)
    s.server=s.net.boot(s.server)
    turtle.env.rednet.send=transmit
    s.net.flush() s.net.advance(150)
    assert(not s.server.error,tostring(s.server.error))
    assert(not turtle.error,tostring(turtle.error))
    local function row() return s.server.env.SO.store.read("so-data/mine/job").value.turtles["3"] end
    equal(row().ores,1)
    equal(s.server.env.SO.mods.cells.isDug(0,0,-1,dim),true)
    transmit(1,pending,"so") s.net.flush()
    equal(row().ores,1)
    s.net.kill(s.server) s.server=s.net.boot(s.server)
    s.net.flush() s.net.advance(10)
    equal(row().ores,1)
    equal(digs,1)
    local used=0
    for _,bytes in pairs(turtle.files) do used=used+#bytes end
    assert(used<1000000,"worker exceeded 1 MB")
  end)

  test("dug retirement: forgotten tunnel facts cannot bypass inspection on a later job",function()
    local s=setup(26,20,function(server)
      server.opts.directories=true
      server.files["so-server.cfg"]=H.encode({pos={dim="minecraft:overworld",x=0,y=0,z=0}})
    end)
    local first=addWorker(s,3)
    for y=0,-80,-1 do s.net.world["0,"..y..",-1"]="minecraft:stone" end
    s.press("mining")
    for _,text in ipairs({"home 0 0 0 n","bottom -80","length 3","mode fast","add 3 0 0 0 n","start"}) do s.typeText(text) end
    s.net.advance(200)
    assert(not first.error,tostring(first.error))
    local job=s.server.env.SO.store.read("so-data/mine/job").value
    equal(job.turtles["3"].state,"done")
    s.typeText("stop") s.typeText("remove 3")
    equal(s.server.env.SO.store.read("so-data/mine/job").value.turtles["3"],nil)

    local server=s.server
    server.env.SO.mods.cells.handlers["test.reload-dug"]=function()
      F.seed(server,500)
      for i=1,500 do
        for _,suffix in ipairs({"",".bak"}) do
          local path=F.path(i)..suffix
          local value=server.env.textutils.unserialize(server.files[path])
          value.value.used=s.net.time+100000
          server.files[path]=H.encode(value)
        end
      end
      local cells=server.env.dofile("so-mod-cells.lua")
      server.env.SO.mods.cells=cells
      assert(cells.tick(s.net.time))
    end
    local proto=s.client.env.dofile("so-proto.lua")
    s.client.env.rednet.send(1,proto.encode(proto.build(string.rep("a",64),"test.reload-dug",{})),"so")
    s.net.flush() s.net.advance(1)
    assert(s.server.env.SO.mods.cells.retirement(),"no eligible old tunnel section")
    s.press("allow")
    equal(s.server.env.SO.mods.cells.isDug(0,0,-1),false)
    s.net.world["0,0,-1"]="minecraft:diamond_ore"
    local turtle=addWorker(s,4)
    local inspected=false
    local inspect,forward=turtle.env.turtle.inspect,turtle.env.turtle.forward
    turtle.env.turtle.inspect=function()
      if turtle.pos.x==0 and turtle.pos.y==0 and turtle.pos.z==0 and turtle.heading==0 then inspected=true end
      return inspect()
    end
    turtle.env.turtle.forward=function()
      if turtle.pos.x==0 and turtle.pos.y==0 and turtle.pos.z==0 and turtle.heading==0 then
        assert(inspected,"cached retired tunnel skipped its inspect")
      end
      return forward()
    end
    s.typeText("add 4 0 0 0 n") s.typeText("start")
    s.net.advance(200)
    assert(not turtle.error,tostring(turtle.error))
    assert(inspected,"retired tunnel was never inspected")
    local row=s.server.env.SO.store.read("so-data/mine/job").value.turtles["4"]
    equal(row.ores,1)
  end)

end
