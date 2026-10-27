local F = dofile("tests/so/lumber-farm-fixture.lua")
local H = dofile("tests/so/harness.lua")
local setup, delivered, run, TREES = F.setup, F.delivered, F.run, F.trees
return function(test, equal)
  test("lumber paired worker harvests and delivers on shipped defaults", function()
    local g=F.setup(true,10000,"down",1,nil,nil,true)
    equal(g.server.files["so-server.cfg"],nil)
    equal(g.server.env.SO.mods.lease.boundaries(),true)
    F.run(g,function(v) return F.delivered(v)==16 end)
    equal(F.delivered(g),16)
    equal(g.server.env.SO.mods.lease.status(2).boundaryHold,nil)
  end)
  test("SO7 chest access faces the chest from the nearest unblocked neighbour", function()
    local L=dofile("so-lumber-plan.lua")
    local point={dim="minecraft:overworld",x=10,y=2,z=10,side="front"}
    for _, pose in ipairs({
      {dim=point.dim,x=10,y=2,z=9,facing=2}, {dim=point.dim,x=11,y=2,z=10,facing=3},
      {dim=point.dim,x=10,y=2,z=11,facing=0}, {dim=point.dim,x=9,y=2,z=10,facing=1},
    }) do equal(L.access(point,pose),pose) end
    equal(L.access(point,{x=11,y=2,z=9},function(p) return p.z==9 or p.x==11 end),
      {dim=point.dim,x=10,y=2,z=11,facing=0})
    equal(L.access(point,nil,function() return true end),nil)
    equal(L.access({dim=point.dim,x=10,y=1,z=10,side="down"}),{dim=point.dim,x=10,y=2,z=10})
  end)
  for _, side in ipairs({ "down", "front" }) do
    test("SO7 real chest coordinates transfer wood, saplings and fuel from "..side, function()
      local g=setup(true,40,side)
      g.net.advance(90)
      assert(#g.burned>0,"fuel was not taken from the chest cell")
      run(g,function(v) return delivered(v)==16 end)
      equal(delivered(g),16)
      assert(g.chests.fuel.inv[1].count < 32)
      assert(g.chests.saplings.inv[1].count < 32)
      assert(g.chests.saplings.inv[2].count < 32)
      for _, spot in ipairs(TREES) do
        equal(g.net.world[spot[1]..",1,"..spot[2]],"minecraft:"..spot[3].."_sapling")
      end
      for _, chest in pairs(g.chests) do equal(g.net.world[chest.x..","..chest.y..","..chest.z],chest) end
      for _, name in ipairs(g.digs) do assert(name ~= "minecraft:chest" and name ~= "minecraft:stone",name) end
    end)
  end
  test("SO7 default-off tool checks let a pickaxe-only turtle fell and deliver logs",function()
    local g=setup(true,10000,"down",1,nil,{left="minecraft:diamond_pickaxe",right="computercraft:wireless_modem"})
    local lease=g.server.env.SO.mods.lease
    equal(lease.status(2).autoToolSwap,false)
    equal(lease.status(2).tools.left,"minecraft:diamond_pickaxe")
    equal(lease.ensureTool(2,"axe"),true)
    g.net.advance(1)
    equal(g.worker.screen[4],"needs axe")
    run(g,function(x) return delivered(x)>=16 end)
    equal(delivered(g),16)
  end)

  test("SO7 fells four trees, replants the farm and delivers every log", function()
    local g = setup(true)
    run(g, function(v) return delivered(v)==16 end)
    equal(delivered(g), 16)
    for _, spot in ipairs(TREES) do
      equal(g.net.world[spot[1]..",1,"..spot[2]], "minecraft:"..spot[3].."_sapling")
      for y=2,4 do equal(g.net.world[spot[1]..","..y..","..spot[2]], nil) end
    end
    for _, name in ipairs(g.digs) do assert(name ~= "minecraft:dirt" and name ~= "minecraft:stone", name) end
    equal(g.net.world["3,2,2"], "minecraft:stone")
    local count=0
    for _, ev in ipairs(g.events) do if ev.kind=="lumber.logs" then count=count+ev.data.count equal(ev.data.id,2) end end
    equal(count,16)
    local beacons=0
    for _, msg in ipairs(g.worker.sent) do if msg.payload.t=="beacon" then beacons=beacons+1 end end
    g.net.advance(90)
    local after=0
    for _, msg in ipairs(g.worker.sent) do if msg.payload.t=="beacon" then after=after+1 end end
    equal(after,beacons)
    equal(g.server.env.SO.mods.lease.status(2).lost,false)
  end)
  test("SO7 an empty sapling chest raises one alert and still fells all trees", function()
    local g = setup(false)
    run(g, function(v) return delivered(v)==16 end)
    local alerts=0
    for _, ev in ipairs(g.events) do
      if ev.kind=="lumber.alert" and ev.data.reason=="empty" then alerts=alerts+1 end
    end
    equal(alerts,1)
    for _, spot in ipairs(TREES) do equal(g.net.world[spot[1]..",1,"..spot[2]],nil) end
    for _, name in ipairs(g.digs) do assert(name ~= "minecraft:dirt" and name ~= "minecraft:stone",name) end
  end)
  test("SO7 a server restart mid-round recovers the worker pose and finishes", function()
    local g = setup(true)
    run(g, function(v) return #v.digs>=3 end)
    assert(g.server.files["so-data/lumber/job"], "job was not saved")
    g.server.co=nil
    g.server.timers={}
    g.server.inbox={}
    g.server.error=nil
    g.server.boot("so-server.lua")
    assert(g.server.alive(),tostring(g.server.error))
    local register=g.server.env.SO.mods.display.screen
    g.server.env.SO.mods.display.screen=function(role,render,input)
      if render then g.screens[role]={render=render,input=input} end
      return register(role,render,input)
    end
    run(g,function(v) return delivered(v)==16 end)
    for _, spot in ipairs(TREES) do equal(g.net.world[spot[1]..",1,"..spot[2]],"minecraft:"..spot[3].."_sapling") end
    equal(g.server.env.SO.mods.lease.status(2).lost,false)
  end)
  test("SO7 low fuel uses the fuel chest without burning harvested logs", function()
    local g=setup(true,40)
    run(g,function(v) return delivered(v)==16 end)
    assert(#g.burned>0,"fuel chest was not used")
    for _, name in ipairs(g.burned) do equal(name,"minecraft:coal") end
    equal(delivered(g),16)
  end)
  test("SO7 a fuel trip during felling returns to the interrupted trunk height", function()
    local g=setup(true)
    local up=g.worker.env.turtle.up
    local drained=false
    g.worker.env.turtle.up=function()
      local ok=up()
      if ok and not drained and g.worker.pos.y>=3 then
        g.worker.fuel=40
        drained=true
      end
      return ok
    end
    run(g,function(v) return delivered(v)==16 end)
    assert(drained,"tree climb did not run")
    assert(#g.burned>0,"interrupted fuel trip did not run")
    for _, name in ipairs(g.burned) do equal(name,"minecraft:coal") end
    for _, spot in ipairs(TREES) do equal(g.net.world[spot[1]..",1,"..spot[2]],"minecraft:"..spot[3].."_sapling") end
  end)
  test("SO7 range failures stop movement and show a red alert", function()
    local g=setup(true)
    g.server.env.SO.mods.lease.inRange=function(_,cell) return cell.x<0 end
    run(g,function(v) return v.screens.lumber.render().rows[1].text:find("out of range",1,true) end,30)
    local picture=g.screens.lumber.render()
    equal(picture.rows[1].fg,"e")
    assert(g.worker.pos.x<0,"worker left the allowed range")
    equal(#g.digs,0)
  end)
  test("SO7 another owner's reservation prevents the worker entering the cell", function()
    local g=setup(true)
    assert(g.server.env.SO.mods.cells.reserve("other",-1,2,0,"minecraft:overworld"))
    g.net.advance(15)
    equal(g.worker.pos,{x=-2,y=2,z=0})
    equal(#g.digs,0)
    local picture=g.screens.lumber.render()
    assert(picture.rows[6].text:find("cells held",1,true),picture.rows[6].text)
    equal(g.server.env.SO.mods.cells.owner(-1,2,0,"minecraft:overworld"),"other")
  end)
  test("SO7 the server command gives a display the lumber screen", function()
    local g=setup(true)
    local d=g.server.env.SO.mods.display
    local body
    d.handlers.hello({from=3,body={w=51,h=19}})
    d.handlers["view.get"]({from=3},function(_,v) body=v end)
    equal(body.role,"unassigned")
    for _, b in ipairs(body.buttons) do assert(b.id~="lumber","unassigned screen links to lumber") end
    d.handlers.input({from=3,body={id="lumber",x=1,y=1}})
    d.handlers["view.get"]({from=3},function(_,v) body=v end)
    equal(body.role,"unassigned")
    assert(d.command("3 lumber"))
    d.handlers["view.get"]({from=3},function(_,v) body=v end)
    equal(body.role,"lumber")
    assert(#body.rows>1,"lumber status missing")
    g.server.co=nil
    g.server.timers={}
    g.server.inbox={}
    g.server.error=nil
    g.server.boot("so-server.lua")
    g.net.advance(1)
    assert(g.server.alive(),tostring(g.server.error))
    d=g.server.env.SO.mods.display
    d.handlers.hello({from=3,body={w=51,h=19}})
    d.handlers["view.get"]({from=3},function(_,v) body=v end)
    equal(body.role,"lumber")
  end)
  test("SO7 saved frame restores its open lease before stationary reconciliation",function()
    local g=setup(true)
    run(g,function(v) return #v.digs>=1 end)
    local fresh=g.net.boot(g.server)
    g.server=fresh
    local lease=fresh.env.SO.mods.lease
    equal(lease.status(2).pose,nil)
    local open=assert(lease.status(2).open)
    local sent,work={},false
    local send=lease.send
    lease.send=function(id,steps,opts)
      local lid,err=send(id,steps,opts)
      if lid then
        sent[#sent+1]={recover=opts.recover,steps=steps}
        if not opts.recover and not (#steps==1 and steps[1].op=="inspectDown") then work=true end
      end
      return lid,err
    end
    fresh.env.SO.mods.lumber.tick(g.net.time)
    equal(lease.status(2).open,open)
    equal(#sent,0)
    for _=1,80 do if work then break end g.net.advance(1) end
    assert(sent[1] and sent[1].recover,"first replacement was not a recovery observation")
    assert(work,"no work after recovery report")
    g.net.advance(3)
    local saved=fresh.env.SO.store.read("so-data/lumber/job").value
    equal(saved.turtles["2"].turtle.pose.x,g.worker.pos.x)
    equal(saved.turtles["2"].turtle.pose.y,g.worker.pos.y)
    equal(saved.turtles["2"].turtle.pose.z,g.worker.pos.z)
  end)

end
