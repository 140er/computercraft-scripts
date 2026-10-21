local H = dofile("tests/so/harness.lua")
local KEY = string.rep("a", 64)
local DIM = 0
local TREES = { {1, 1, "birch"}, {4, 4, "oak"}, {7, 7, "oak"}, {1, 7, "birch"} }
local function libs(m)
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path, "rb"))
    m.files[path] = f:read("*a")
    f:close()
  end
end
local function setup(saplings, fuel, side)
  side = side or "down"
  local n = H.new()
  local s = n.machine({ id = 1, modem = true })
  s.install({ "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-plan.lua",
    "so-lumber-plan.lua", "so-mod-lease.lua", "so-mod-cells.lua", "so-mod-drops.lua",
    "so-mod-display.lua", "so-mod-lumber.lua" })
  libs(s)
  s.files["so-keys"] = H.encode({schema=1,generation=1,value={keys={["2"]=KEY}}})
  s.boot("so-server.lua")
  assert(s.alive(), tostring(s.error))
  local w = n.machine({ id = 2, modem = true, turtle = true, x = -2, y = 2, z = 0,
    facing = 1, fuel = fuel or 10000, capacity = 1000000 })
  w.install({ "worker.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" })
  libs(w)
  w.files["so-keys"] = H.encode({schema=1,generation=1,value={keys={["1"]=KEY}}})
  local digs, burned = {}, {}
  local refuel = w.env.turtle.refuel
  w.env.turtle.refuel = function(n)
    local item = w.inv[w.selected]
    burned[#burned + 1] = item and item.name or "empty"
    return refuel(n)
  end
  for _, ops in ipairs({ {"dig", "inspect"}, {"digUp", "inspectUp"}, {"digDown", "inspectDown"} }) do
    local dig, inspect = w.env.turtle[ops[1]], w.env.turtle[ops[2]]
    w.env.turtle[ops[1]] = function()
      local present, block = inspect()
      assert(not present or block.name ~= "minecraft:chest", "worker tried to dig a chest")
      local ok = dig()
      if ok and present then
        digs[#digs + 1] = block.name
        if block.tags and block.tags["minecraft:logs"] then
          local slot
          for i = 1, 16 do
            if w.inv[i] and w.inv[i].name == block.name and w.inv[i].count < 64 then slot = i break end
          end
          if not slot then for i = 1, 16 do if not w.inv[i] then slot = i break end end end
          assert(slot, "log lost to full inventory")
          w.inv[slot] = { name = block.name, count = (w.inv[slot] and w.inv[slot].count or 0) + 1 }
        end
      end
      return ok
    end
  end
  local screens, events = {}, {}
  local register = s.env.SO.mods.display.screen
  s.env.SO.mods.display.screen = function(role, render, input)
    screens[role] = { render = render, input = input }
    return register(role, render, input)
  end
  s.env.SO.mods.state = { emit = function(kind, data) events[#events+1] = {kind=kind,data=data} return true end }
  for x = 0, 8 do for z = 0, 8 do n.world[x..",0,"..z] = "minecraft:dirt" end end
  n.world["3,2,2"] = "minecraft:stone"
  for _, spot in ipairs(TREES) do
    for y = 1, 4 do n.world[spot[1]..","..y..","..spot[2]] = {
      name = "minecraft:"..spot[3].."_log", tags = {["minecraft:logs"]=true} } end
  end
  local chests = {
    saplings = { x=-2, y=side == "down" and 1 or 2, z=side == "down" and 0 or -2,
      name="minecraft:chest", inv=saplings and {{name="minecraft:oak_sapling",count=32},{name="minecraft:birch_sapling",count=32}} or {} },
    wood = { x=side == "down" and -3 or -4, y=side == "down" and 1 or 2, z=side == "down" and 0 or -2,
      name="minecraft:chest", inv={} },
    fuel = { x=side == "down" and -4 or -6, y=side == "down" and 1 or 2, z=side == "down" and 0 or -2,
      name="minecraft:chest", inv={{name="minecraft:coal",count=32}} },
  }
  if side == "front" then n.world["-5,2,-2"] = "minecraft:stone" end
  for kind, chest in pairs(chests) do
    n.world[chest.x..","..chest.y..","..chest.z] = chest
    if kind ~= "saplings" then
      assert(s.env.SO.mods.drops.add({id=kind,dim=DIM,x=chest.x,y=chest.y,z=chest.z,side=side,kind=kind}))
    end
  end
  for _, op in ipairs({ "forward", "back", "up", "down" }) do
    local move = w.env.turtle[op]
    w.env.turtle[op] = function()
      local ok = move()
      local block = n.world[w.pos.x..","..w.pos.y..","..w.pos.z]
      assert(type(block) ~= "table" or block.name ~= "minecraft:chest", "worker entered a chest")
      return ok
    end
  end
  w.boot("worker.lua")
  n.flush()
  n.advance(1)
  assert(screens.lumber, "lumber screen not registered")
  local function command(text) screens.lumber.input({text=text,role="lumber",x=1,y=1}) end
  command("area 0 0 8 8 0")
  command("saplings "..chests.saplings.x.." "..chests.saplings.y.." "..chests.saplings.z.." "..side)
  command("add 2 -2 2 0 e")
  n.advance(2)
  command("start")
  return {net=n,server=s,worker=w,screens=screens,events=events,digs=digs,burned=burned,wood=chests.wood,chests=chests,command=command}
end
local function delivered(g)
  local count = 0
  for _, item in ipairs(g.wood.inv) do if item.name:match("_log$") then count=count+item.count end end
  return count
end
local function run(g, untilFn, seconds)
  for _ = 1, seconds or 1800 do
    g.net.advance(1)
    assert(g.server.alive(), tostring(g.server.error))
    assert(g.worker.alive(), tostring(g.worker.error))
    for _, line in ipairs(g.server.log) do assert(not line:find("failed:",1,true), line) end
    if untilFn(g) then return end
  end
  error("lumber did not finish: " .. H.encode(g.screens.lumber.render()))
end
return function(test, equal)
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
      equal(g.chests.fuel.inv[1].count,0)
      equal(g.chests.saplings.inv[1].count,0)
      equal(g.chests.saplings.inv[2].count,0)
      for _, spot in ipairs(TREES) do
        equal(g.net.world[spot[1]..",1,"..spot[2]],"minecraft:"..spot[3].."_sapling")
      end
      for _, chest in pairs(g.chests) do equal(g.net.world[chest.x..","..chest.y..","..chest.z],chest) end
      for _, name in ipairs(g.digs) do assert(name ~= "minecraft:chest" and name ~= "minecraft:stone",name) end
    end)
  end
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
      if ev.kind=="lumber.alert" and ev.data.text=="out of saplings" then alerts=alerts+1 end
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
      g.screens[role]={render=render,input=input}
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
  test("SO7 the generic lumber button opens the lumber screen", function()
    local g=setup(true)
    local d=g.server.env.SO.mods.display
    local body
    d.handlers.hello({from=3,body={w=51,h=19}})
    d.handlers["view.get"]({from=3},function(_,v) body=v end)
    local button
    for _, b in ipairs(body.buttons) do if b.id=="lumber" then button=b end end
    assert(button,"generic screen has no lumber button")
    d.handlers.input({from=3,body={id=button.id,x=button.x,y=button.y}})
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
  test("SO7 saved frame recovers on the first tick without lease memory",function()
    local g=setup(true)
    run(g,function(v) return #v.digs>=1 end)
    local fresh=g.net.boot(g.server)
    g.server=fresh
    local lease=fresh.env.SO.mods.lease
    equal(lease.status(2).pose,nil)
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
    assert(sent[1] and sent[1].recover,"first tick did not send recovery park")
    g.net.advance(3)
    assert(work,"no work after recovery report")
    local saved=fresh.env.SO.store.read("so-data/lumber/job").value
    equal(saved.turtle.pose.x,g.worker.pos.x)
    equal(saved.turtle.pose.y,g.worker.pos.y)
    equal(saved.turtle.pose.z,g.worker.pos.z)
  end)

end
