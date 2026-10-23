local H = dofile("tests/so/harness.lua")
local S = {}
S.files = {"so-server.lua","so-store.lua","so-mod-state.lua","so-pair.lua","so-proto.lua","so-mod-lease.lua","so-mod-cells.lua","so-mod-display.lua","so-mod-drops.lua","so-mod-mine.lua","so-mine-plan.lua","so-plan.lua"}
local function tree(m)
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path))
    m.files[path] = f:read("*a")
    f:close()
  end
end
local function setup(opts)
  opts=opts or {}
  local net=H.new()
  local server=net.machine({id=1,modem=true}) server.install(S.files) tree(server)
  server.files["so-server.cfg"] = H.encode({pos={dim="minecraft:overworld",x=0,y=0,z=0}})
  if opts.routeGuard then
    server.files["so-mine-plan.lua"] = server.files["so-mine-plan.lua"]:gsub("\nreturn M%s*$", "\n"..[[
local supply = M.supplyRoute
routeSearches = {}
M.supplyRoute = function(job,row,stand,point,lookup)
  local cells, prior = SO.mods.cells, SO.mods.cells.isDug
  cells.isDug = function() error("route planning queried durable dug cells") end
  if stand == job.home then
    local key = M.key(row.pose)..":"..tostring(row.index)..":"..tostring(row.route)
    routeSearches[key] = (routeSearches[key] or 0)+1
  end
  local ok, path, access = pcall(supply,job,row,stand,point,lookup)
  cells.isDug = prior
  if not ok then error(path) end
  return path,access
end
return M
]])
  end
  server.boot("so-server.lua") net.flush()
  local render,input
  local display=server.env.SO.mods.display
  local original=display.screen
  display.screen=function(role,r,i) if role=="mining" then render,input=r,i end return original(role,r,i) end
  server.env.SO.mods.mine.tick()
  local turtles={}
  local function add(id,x)
    local key = string.rep("a", 64)
    assert(server.env.SO.pair.remember(id, key))
    local turtle=net.machine({id=id,modem=true,turtle=true,x=x or 0,fuel=opts.fuel or 4000,capacity=1000000})
    turtle.install({"worker.lua","so-store.lua","so-pair.lua","so-proto.lua"}) tree(turtle)
    turtle.files["so-keys"] = H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
    turtle.boot("worker.lua") net.flush()
    assert(not turtle.error,tostring(turtle.error))
    input({text="add "..id.." "..(x or 0).." 0 0 n"}) net.advance(1)
    turtles[#turtles+1]=turtle
    return turtle
  end
  assert(server.env.SO.mods.drops.add({id="ready",dim=0,x=100000,y=0,z=0,side="front",kind="any"}))
  local turtle=add(2)
  input({text="home 0 0 0 n"}) input({text="bottom -2"}) input({text="length 3"})
  return {net=net,server=server,turtle=turtle,turtles=turtles,add=add,input=function(text) input({text=text}) end,render=function() return render() end}
end
local function run(s, seconds)
  s.net.advance(seconds or 30)
  assert(not s.server.error,tostring(s.server.error))
  for _,t in ipairs(s.turtles) do assert(not t.error,tostring(t.error)) end
end
local function persisted(s)
  return s.server.env.SO.store.read("so-data/mine/job").value
end
local function digWorld(s)
  for y=-2,0 do s.net.world["0,"..y..",-1"]="minecraft:stone" end
  for z=-2,-5,-1 do s.net.world["0,-2,"..z]="minecraft:stone" end
  for x=1,3 do s.net.world[x..",-2,-5"]="minecraft:stone" end
end
local function fluidWorld(s)
  local t, world = s.turtle, s.net.world
  local stats = { scooped=0, sealed=0 }
  local function target(dir)
    local p = t.pos
    if dir == "up" then return p.x .. "," .. (p.y+1) .. "," .. p.z end
    if dir == "down" then return p.x .. "," .. (p.y-1) .. "," .. p.z end
    return (p.x+({ [0]=0, 1, 0, -1 })[t.heading]) .. "," .. p.y .. "," ..
      (p.z+({ [0]=-1, 0, 1, 0 })[t.heading])
  end
  local function liquid(block)
    return type(block) == "table" and (block.name == "minecraft:lava" or block.name == "minecraft:water")
  end
  for _, spec in ipairs({ {"", "forward"}, {"Up", "up"}, {"Down", "down"} }) do
    local suffix, dir = spec[1], spec[2]
    local place, dig, move = t.env.turtle["place"..suffix], t.env.turtle["dig"..suffix], t.env.turtle[dir]
    t.env.turtle["place"..suffix] = function()
      local key = target(dir)
      local block, item = world[key], t.inv[t.selected]
      if liquid(block) and item then
        if item.name == "minecraft:bucket" and block.name == "minecraft:lava" and block.state.level == 0 then
          item.name, world[key] = "minecraft:lava_bucket", nil
          stats.scooped = stats.scooped + 1
          return true
        end
        world[key] = nil
        local ok = place()
        if ok then stats.sealed = stats.sealed + 1 else world[key] = block end
        return ok
      end
      return place()
    end
    t.env.turtle["dig"..suffix] = function()
      assert(not liquid(world[target(dir)]), "tried to dig fluid")
      return dig()
    end
    t.env.turtle[dir] = function()
      assert(not liquid(world[target(dir)]), "tried to enter fluid")
      return move()
    end
  end
  return stats
end
return function(test,equal)
  test("mine shaft and branch mark every actual dug cell",function()
    local s=setup() digWorld(s)
    local dug={}
    local base=s.turtle.env.turtle.dig
    s.turtle.env.turtle.dig=function() local p=s.turtle.pos local dx=({[0]=0,1,0,-1})[s.turtle.heading] local dz=({[0]=-1,0,1,0})[s.turtle.heading] local ok=base() if ok then dug[#dug+1]={p.x+dx,p.y,p.z+dz} end return ok end
    local down=s.turtle.env.turtle.digDown
    s.turtle.env.turtle.digDown=function() local p=s.turtle.pos local ok=down() if ok then dug[#dug+1]={p.x,p.y-1,p.z} end return ok end
    s.input("start") run(s,100)
    equal(s.turtle.pos.x,3) equal(s.turtle.pos.y,-2) equal(s.turtle.pos.z,-5)
    for _,c in ipairs(dug) do equal(s.server.env.SO.mods.cells.isDug(c[1],c[2],c[3]),true) end
    assert(#dug>=10)
  end)
  test("mine two turtles reserve disjoint cells after every batch",function()
    local s=setup() local other=s.add(3,2) digWorld(s)
    local cells=s.server.env.SO.mods.cells
    local original=cells.reserveMany
    local batches=0
    for _, turtle in ipairs(s.turtles) do
      local transmit = turtle.env.rednet.send
      turtle.env.rednet.send = function(id, payload, protocol)
        if payload.t == "step.report" then
          for _, other in ipairs(s.turtles) do
            if other ~= turtle then
              local a, b = turtle.pos, other.pos
              assert(a.x ~= b.x or a.y ~= b.y or a.z ~= b.z, "workers occupied the same cell")
            end
          end
          local p = turtle.pos
          equal(cells.owner(p.x, p.y, p.z), "mine:" .. turtle.id)
        end
        return transmit(id, payload, protocol)
      end
    end
    cells.reserveMany=function(who,list)
      for _,c in ipairs(list) do local held=cells.owner(c.x,c.y,c.z,c.dim) if held and held~=who then return false,"held" end end
      local ok,err=original(who,list)
      if ok then for _,c in ipairs(list) do equal(cells.owner(c.x,c.y,c.z,c.dim),who) end batches=batches+1 end
      return ok,err
    end
    s.input("start") run(s,150)
    assert(batches>15) assert(other.pos.x~=s.turtle.pos.x or other.pos.z~=s.turtle.pos.z or other.pos.y~=s.turtle.pos.y)
  end)
  test("mine wall vein is exhausted once",function()
    local s=setup() digWorld(s)
    s.net.world["1,-2,-3"]="minecraft:diamond_ore" s.net.world["2,-2,-3"]="minecraft:diamond_ore"
    s.input("start") run(s,150)
    equal(s.net.world["1,-2,-3"],nil) equal(s.net.world["2,-2,-3"],nil)
    local job=persisted(s) equal(job.turtles["2"].ores,2)
    equal(s.server.env.SO.mods.cells.isDug(2,-2,-3),true)
  end)
  test("mine low fuel visits a front drop and returns to its interrupted pose", function()
    local s = setup()
    digWorld(s)
    local chest = { name = "minecraft:chest", inv = { { name = "minecraft:coal", count = 64 } } }
    s.net.world["1,0,0"] = chest
    assert(s.server.env.SO.mods.drops.add({ id="fuel", dim=0, x=1, y=0, z=0, side="front", kind="fuel" }))
    local forward = s.turtle.env.turtle.forward
    local interrupted, returned, faced
    s.turtle.env.turtle.forward = function()
      local ok, err = forward()
      local p = s.turtle.pos
      if ok and not interrupted and p.x == 1 and p.y == -2 and p.z == -5 then
        interrupted = { x=p.x, y=p.y, z=p.z, facing=s.turtle.heading }
        s.turtle.fuel = 30
      elseif ok and interrupted and s.turtle.fuel > 1900 and p.x == interrupted.x
          and p.y == interrupted.y and p.z == interrupted.z then
        returned = true
      end
      return ok, err
    end
    local suck = s.turtle.env.turtle.suck
    s.turtle.env.turtle.suck = function(n)
      local p = s.turtle.pos
      local dx = ({ [0]=0, 1, 0, -1 })[s.turtle.heading]
      local dz = ({ [0]=-1, 0, 1, 0 })[s.turtle.heading]
      faced = p.y == 0 and p.x + dx == 1 and p.z + dz == 0
      return suck(n)
    end
    s.input("start")
    run(s, 150)
    assert(interrupted, "did not reach the branch")
    assert(returned, "did not return to the interrupted branch cell")
    assert(faced, "did not stand beside and face the fuel chest")
    assert(s.turtle.fuel > 1900)
    equal(s.turtle.pos.x, 3)
    equal(s.turtle.pos.y, -2)
    assert(chest.inv[1].count < 64)
  end)
  test("mine cleanup refuses an inventory and keeps junk out of the ore chest",function()
    local s=setup()
    s.net.world["0,-1,0"]={name="mod:crate",inv={}}
    for i=1,16 do s.turtle.inv[i]={name=i<=2 and "minecraft:cobblestone" or "minecraft:diamond",count=64} end
    s.net.world["1,0,0"]={name="minecraft:chest",inv={}}
    assert(s.server.env.SO.mods.drops.add({id="ore",dim=0,x=1,y=0,z=0,side="front",kind="ore"}))
    s.input("start") run(s,150)
    local chest=s.net.world["1,0,0"] local count=0
    for _,item in ipairs(chest.inv) do assert(item.name~="minecraft:cobblestone") count=count+item.count end
    equal(count,14*64)
    equal(#s.net.world["0,-1,0"].inv,0)
  end)
  test("mine saved cleanup refusal retries safely without unloading junk",function()
    local s=setup()
    for i=1,16 do s.turtle.inv[i]={name=i<=2 and "minecraft:cobblestone" or "minecraft:diamond",count=64} end
    local chest={name="minecraft:chest",inv={}}
    s.net.world["1,0,0"]=chest
    assert(s.server.env.SO.mods.drops.add({id="ore",dim=0,x=1,y=0,z=0,side="front",kind="ore"}))
    local disk=persisted(s) disk.turtles["2"].cleanupBlocked=true disk.running=true
    assert(s.server.env.SO.store.store("so-data/mine/job",function() return true end).save(disk))
    s.server=s.net.boot(s.server)
    run(s,150)
    local ore,junk=0,0
    for _,item in ipairs(chest.inv) do
      if item.name=="minecraft:diamond" then ore=ore+item.count end
      if item.name=="minecraft:cobblestone" then junk=junk+item.count end
    end
    equal(ore,14*64) equal(junk,0)
    equal(s.turtle.inv[1].count,64)
    assert(s.turtle.pos.y<0,"mining did not resume after refused cleanup")
  end)
  test("mine discards tunnel junk into open cells and unloads only ore",function()
    local s=setup() digWorld(s)
    s.turtle.inv[1]={name="minecraft:cobblestone",count=64}
    s.turtle.inv[2]={name="minecraft:cobbled_deepslate",count=64}
    s.turtle.inv[3]={name="minecraft:diamond",count=8}
    for x=0,3 do
      for z=-5,-1 do
        s.net.world[x..",-3,"..z]="minecraft:stone"
        s.net.world[x..",-1,"..z]="minecraft:stone"
      end
    end
    local chest={name="minecraft:chest",inv={}}
    s.net.world["1,0,0"]=chest
    assert(s.server.env.SO.mods.drops.add({id="ore",dim=0,x=1,y=0,z=0,side="front",kind="ore"}))
    local discarded=0
    for _,spec in ipairs({{"drop","forward"},{"dropUp","up"},{"dropDown","down"}}) do
      local original=s.turtle.env.turtle[spec[1]]
      local dir=spec[2]
      s.turtle.env.turtle[spec[1]]=function(n)
        local item=s.turtle.inv[s.turtle.selected]
        if item and item.name~="minecraft:diamond" then
          local pose=s.turtle.pos
          local c=dofile("so-mine-plan.lua").cell({x=pose.x,y=pose.y,z=pose.z,facing=s.turtle.heading},dir)
          assert(not s.net.world[c.x..","..c.y..","..c.z],"discard entered an occupied cell")
          assert(pose.y<0,"cleanup did not use the mine tunnel")
          discarded=discarded+item.count
        end
        return original(n)
      end
    end
    s.input("start") run(s,180)
    equal(discarded,64)
    local ore=0
    for _,item in ipairs(chest.inv) do equal(item.name,"minecraft:diamond") ore=ore+item.count end
    equal(ore,8)
    equal(persisted(s).turtles["2"].state,"done")
  end)
  test("mine range refusal sends no movement outside proven range",function()
    local s=setup() local lease=s.server.env.SO.mods.lease
    lease.inRange=function(_,p) return p.y>=0 end
    s.input("start") run(s,15)
    equal(s.turtle.pos.y,0)
    local red=false for _,r in ipairs(s.render().rows) do if r.fg=="e" then red=true end end assert(red)
  end)
  test("mine restart recovers a pending dig report without digging any cell twice", function()
    local s = setup()
    digWorld(s)
    s.net.world["0,-2,-1"] = "minecraft:diamond_ore"
    local attempts = {}
    for _, op in ipairs({ "dig", "digUp", "digDown" }) do
      local base = s.turtle.env.turtle[op]
      s.turtle.env.turtle[op] = function()
        local p = s.turtle.pos
        local x, y, z = p.x, p.y, p.z
        if op == "digUp" then y = y + 1
        elseif op == "digDown" then y = y - 1
        else
          x = x + ({ [0]=0, 1, 0, -1 })[s.turtle.heading]
          z = z + ({ [0]=-1, 0, 1, 0 })[s.turtle.heading]
        end
        local key = x .. "," .. y .. "," .. z
        attempts[key] = (attempts[key] or 0) + 1
        return base()
      end
    end
    local transmit = s.turtle.env.rednet.send
    local pending, recovery
    s.turtle.env.rednet.send = function(id, payload, protocol)
      if payload.t == "step.report" and #payload.body.dug >= 3 then
        pending = payload
        return
      end
      return transmit(id, payload, protocol)
    end
    s.input("start")
    run(s, 10)
    assert(pending, "did not interrupt an unreported dig")
    local before = persisted(s).turtles["2"].pose
    assert(not s.server.env.SO.mods.cells.isDug(0, -2, -1), "pending dig was already reported")
    s.server.co, s.server.inbox, s.server.timers = nil, {}, {}
    s.server.boot("so-server.lua")
    assert(s.server.alive(), tostring(s.server.error))
    s.turtle.env.rednet.send = function(id, payload, protocol)
      if payload.t == "step.report" then recovery = payload return end
      return transmit(id, payload, protocol)
    end
    s.server.env.SO.mods.mine.tick()
    run(s, 1)
    assert(recovery, "restart did not request a recovery report")
    equal(persisted(s).turtles["2"].pose, before)
    transmit(1, pending, "so")
    s.net.flush()
    equal(persisted(s).turtles["2"].pose, before)
    s.turtle.env.rednet.send = transmit
    transmit(1, recovery, "so")
    s.net.flush()
    run(s, 150)
    equal(s.turtle.pos.x, 3)
    equal(s.turtle.pos.y, -2)
    for cell, count in pairs(attempts) do equal(count, 1) end
    equal(s.server.env.SO.mods.cells.isDug(0, -2, -1), true)
    equal(s.server.env.SO.mods.cells.isDug(3, -2, -5), true)
    equal(persisted(s).turtles["2"].ores, 1)
  end)
  test("mine lost turtle is red until recovery report",function()
    local s=setup()
    local lease=s.server.env.SO.mods.lease
    lease.handlers.beacon({from=2,body={pose={x=0,y=0,z=0,f=0},journal="lost"}})
    s.server.env.SO.mods.mine.tick()
    local red=false for _,r in ipairs(s.render().rows) do if r.fg=="e" then red=true end end assert(red)
    s.net.flush() s.net.advance(1) s.input("start") run(s,150)
    equal(s.turtle.pos.x,3) equal(s.turtle.pos.y,-2)
    equal(lease.status(2).lost,false)
  end)
  test("mine lava source uses the bucket before junk and burns the lava", function()
    local s = setup()
    s.turtle.inv[1] = { name="minecraft:cobblestone", count=64 }
    s.turtle.inv[2] = { name="minecraft:bucket", count=1 }
    s.net.world["0,0,-1"] = { name="minecraft:lava", state={level=0} }
    local stats = fluidWorld(s)
    s.input("start")
    run(s, 100)
    equal(stats.scooped, 1)
    equal(stats.sealed, 0)
    equal(s.turtle.inv[2].name, "minecraft:bucket")
    assert(s.turtle.fuel > 4900)
    equal(s.turtle.pos.x, 3)
  end)
  test("mine flowing lava and water are sealed before the worker moves", function()
    local s = setup()
    s.turtle.inv[1] = { name="minecraft:cobblestone", count=64 }
    s.turtle.inv[2] = { name="minecraft:bucket", count=1 }
    s.net.world["0,0,-1"] = { name="minecraft:lava", state={level=3} }
    s.net.world["0,-1,-1"] = { name="minecraft:water", state={level=0} }
    local stats = fluidWorld(s)
    s.input("start")
    run(s, 100)
    equal(stats.scooped, 0)
    equal(stats.sealed, 2)
    equal(s.turtle.pos.x, 3)
    equal(s.server.env.SO.mods.cells.isDug(0, -1, -1), true)
  end)
  test("mine seals lava beside a thorough branch", function()
    local s = setup()
    s.turtle.inv[1] = { name="minecraft:cobblestone", count=64 }
    s.net.world["1,-2,-3"] = { name="minecraft:lava", state={level=4} }
    local stats = fluidWorld(s)
    s.input("start")
    run(s, 100)
    equal(stats.sealed, 1)
    equal(s.turtle.pos.x, 3)
    equal(s.net.world["1,-2,-3"], "minecraft:cobblestone")
  end)
  test("mine expired lease retains its cells until a recovery report", function()
    local s = setup()
    local transmit = s.turtle.env.rednet.send
    local latest
    s.turtle.env.rednet.send = function(id, payload, protocol)
      if payload.t == "step.report" then latest = payload return end
      return transmit(id, payload, protocol)
    end
    s.input("start")
    run(s, 2)
    local cells = s.server.env.SO.mods.cells
    equal(cells.owner(0, 0, -1), "mine:2")
    run(s, 72)
    equal(cells.owner(0, 0, -1), "mine:2")
    local red = false
    for _, row in ipairs(s.render().rows) do if row.fg == "e" then red = true end end
    assert(red, "expired worker was not red")
    equal(s.turtle.pos.z, 0)
    s.turtle.env.rednet.send = transmit
    transmit(1, assert(latest), "so")
    s.net.flush()
    run(s, 100)
    equal(s.turtle.pos.x, 3)
    equal(s.server.env.SO.mods.lease.status(2).lost, false)
  end)
  test("mine down drops unload from above and hold when no drop exists", function()
    local s = setup()
    for slot = 1, 16 do s.turtle.inv[slot] = { name="minecraft:diamond", count=1 } end
    s.input("start")
    assert(s.server.env.SO.mods.drops.remove("ready"))
    run(s, 3)
    local alert = false
    for _, row in ipairs(s.render().rows) do if row.text:find("no ore chest set", 1, true) then alert = true end end
    assert(alert, "missing drop did not raise a hold alert")
    equal(s.turtle.pos, { x=0, y=0, z=0 })
    local chest = { name="minecraft:chest", inv={} }
    s.net.world["2,-1,0"] = chest
    assert(s.server.env.SO.mods.drops.add({ id="ore", dim=0, x=2, y=-1, z=0, side="down", kind="ore" }))
    local drop, above = s.turtle.env.turtle.dropDown, false
    s.turtle.env.turtle.dropDown = function(n)
      above = s.turtle.pos.x == 2 and s.turtle.pos.y == 0 and s.turtle.pos.z == 0
      assert(above, "unload was not above the chest")
      return drop(n)
    end
    run(s, 100)
    assert(above)
    equal(#chest.inv, 16)
    equal(s.turtle.pos.x, 3)
  end)
  test("mine fast mode skips branch wall veins and uses two block spacing", function()
    local s = setup()
    s.input("mode fast")
    s.net.world["1,-2,-2"] = "minecraft:diamond_ore"
    s.input("start")
    run(s, 50)
    equal(s.turtle.pos, { x=3, y=-2, z=-3 })
    equal(s.net.world["1,-2,-2"], "minecraft:diamond_ore")
  end)
  test("mine pure inventory rules keep fuel and one sealable stack", function()
    local M = dofile("so-mine-plan.lua")
    equal(M.junk({name="minecraft:raw_iron"}), false)
    equal(M.junk({name="minecraft:coal"}), false)
    equal(M.junk({name="mod:gem",tags={["c:gems"]=true}}), false)
    equal(M.sealable({name="minecraft:flint"}), false)
    equal(M.sealable({name="minecraft:gravel"}), false)
    local cleanup = M.cleanup({ {slot=1,name="minecraft:flint",count=1},
      {slot=2,name="minecraft:cobblestone",count=64}, {slot=3,name="minecraft:cobblestone",count=64} })
    equal(cleanup, { {op="select",slot=1}, {op="discard",side="down"}, {op="select",slot=3}, {op="discard",side="down"} })
  end)

  test("mine bounds a vein to 64 blocks and emits ore and progress events", function()
    local s = setup()
    local events = {}
    s.server.env.SO.mods.state = { canStart=s.server.env.SO.mods.state.canStart, emit=function(kind, data)
      events[#events+1] = { kind=kind, data=data }
      return true
    end }
    for x = 1, 66 do s.net.world[x .. ",-2,-3"] = "minecraft:diamond_ore" end
    s.input("start")
    run(s, 500)
    equal(persisted(s).turtles["2"].ores, 64)
    equal(s.net.world["65,-2,-3"], "minecraft:diamond_ore")
    local ores, progress = 0, false
    for _, event in ipairs(events) do
      if event.kind == "mine.ore" then
        equal(event.data, { id=2, name="minecraft:diamond_ore", count=1 })
        ores = ores + event.data.count
      elseif event.kind == "mine.progress" then
        equal(event.data.level, -2)
        equal(event.data.done, 1)
        progress = true
      end
    end
    equal(ores, 64)
    assert(progress, "missing completion event")
  end)
  test("mine idle leases renew before timeout without repeated park traffic", function()
    local s = setup()
    local function batches()
      local count = 0
      for _, sent in ipairs(s.server.sent) do if sent.payload.t == "lease.batch" then count = count + 1 end end
      return count
    end
    local initial = batches()
    run(s, 500)
    equal(batches(), initial)
    run(s, 50)
    equal(batches(), initial + 1)
    equal(s.server.env.SO.mods.lease.status(2).lost, false)
    equal(s.turtle.pos, { x=0, y=0, z=0 })
  end)

  test("mine down drop above the worker is routed around without digging the chest", function()
    local s = setup()
    for slot = 1, 16 do s.turtle.inv[slot] = { name="minecraft:diamond", count=1 } end
    local chest = { name="minecraft:chest", inv={} }
    s.net.world["0,1,0"] = chest
    assert(s.server.env.SO.mods.drops.add({ id="ore", dim=0, x=0, y=1, z=0, side="down", kind="ore" }))
    s.input("start")
    run(s, 100)
    equal(s.net.world["0,1,0"], chest)
    equal(#chest.inv, 16)
    equal(s.turtle.pos.x, 3)
    equal(s.turtle.pos.y, -2)
  end)
  test("mine full ore inventory unloads before fetching fuel", function()
    local s = setup({ fuel=30 })
    for slot = 1, 16 do s.turtle.inv[slot] = { name="minecraft:diamond", count=1 } end
    local ore = { name="minecraft:chest", inv={} }
    local fuel = { name="minecraft:chest", inv={{name="minecraft:coal",count=64}} }
    s.net.world["1,0,0"], s.net.world["-1,-1,0"] = ore, fuel
    assert(s.server.env.SO.mods.drops.add({ id="ore", dim=0, x=1, y=0, z=0, side="front", kind="ore" }))
    assert(s.server.env.SO.mods.drops.add({ id="fuel", dim=0, x=-1, y=-1, z=0, side="down", kind="fuel" }))
    s.input("start")
    run(s, 100)
    equal(#ore.inv, 16)
    assert(s.turtle.fuel > 1900)
    equal(s.turtle.pos.x, 3)
    equal(s.turtle.pos.y, -2)
  end)
  test("mine a coal-filled inventory unloads and frees space", function()
    local s = setup()
    for slot = 1, 16 do s.turtle.inv[slot] = { name="minecraft:coal", count=64 } end
    local chest = { name="minecraft:chest", inv={} }
    s.net.world["1,0,0"] = chest
    assert(s.server.env.SO.mods.drops.add({ id="ore", dim=0, x=1, y=0, z=0, side="front", kind="ore" }))
    s.input("start")
    run(s, 100)
    equal(#chest.inv, 16)
    equal(next(s.turtle.inv), nil)
    equal(s.turtle.pos.x, 3)
  end)

  test("mine fast mode still seals fluids above the tunnel", function()
    local s = setup()
    s.input("mode fast")
    s.turtle.inv[1] = { name="minecraft:cobblestone", count=64 }
    s.net.world["0,-1,-2"] = { name="minecraft:lava", state={level=4} }
    local stats = fluidWorld(s)
    s.input("start")
    run(s, 100)
    equal(stats.sealed, 1)
    equal(s.turtle.pos, { x=3, y=-2, z=-3 })
  end)

  test("mine ore trips retain buckets and torches and return after unloading", function()
    local s = setup()
    local kept = { "minecraft:bucket", "minecraft:lava_bucket", "minecraft:water_bucket", "minecraft:torch" }
    for slot, name in ipairs(kept) do s.turtle.inv[slot] = { name=name, count=1 } end
    for slot = 5, 15 do s.turtle.inv[slot] = { name="minecraft:diamond", count=64 } end
    s.turtle.inv[16] = { name="minecraft:coal", count=64 }
    local chest = { name="minecraft:chest", inv={} }
    s.net.world["1,0,0"] = chest
    assert(s.server.env.SO.mods.drops.add({ id="ore", dim=0, x=1, y=0, z=0, side="front", kind="ore" }))
    s.input("start")
    run(s, 100)
    for slot, name in ipairs(kept) do
      assert(s.turtle.inv[slot], name .. " was unloaded")
      equal(s.turtle.inv[slot], { name=name, count=1 })
    end
    local totals = {}
    for _, item in ipairs(chest.inv) do totals[item.name] = (totals[item.name] or 0) + item.count end
    equal(totals, { ["minecraft:diamond"]=11*64, ["minecraft:coal"]=64 })
    local row = persisted(s).turtles["2"]
    equal(row.trip, nil)
    equal(row.state, "done")
    equal(s.turtle.pos, { x=3, y=-2, z=-5 })
  end)

  test("mine batches known shaft travel and stops at an unknown inspect", function()
    local M = dofile("so-mine-plan.lua")
    local row = { pose={dim="minecraft:overworld",x=0,y=0,z=0,facing=0}, goal={x=0,y=-10,z=0} }
    local action = M.next({}, row, function(c) if c.y > -10 then return false end end, {}, 4000)
    equal(#action.steps, 10)
    equal(action.steps[10].op, "inspectDown")
    equal(#action.cells, 10)
    for i=1,9 do equal(action.steps[i].op, "down") end
  end)
  test("mine ore filters leave diamond walls and follow iron reports", function()
    local s = setup()
    digWorld(s)
    s.input("ores iron")
    s.net.world["1,-2,-3"] = "minecraft:diamond_ore"
    s.net.world["-1,-2,-3"] = "minecraft:iron_ore"
    s.net.world["-2,-2,-3"] = "minecraft:iron_ore"
    s.input("start") run(s,150)
    equal(s.net.world["1,-2,-3"], "minecraft:diamond_ore")
    equal(s.net.world["-1,-2,-3"], nil)
    equal(s.net.world["-2,-2,-3"], nil)
    equal(persisted(s).turtles["2"].ores, 2)
  end)
  test("mine empty and missing ore filters accept all ores", function()
    local M = dofile("so-mine-plan.lua")
    equal(M.ore({name="minecraft:deepslate_diamond_ore"}, {}), true)
    equal(M.ore({name="minecraft:deepslate_diamond_ore"}), true)
    equal(M.ore({name="mod:deposit", tags={["c:ores/iron"]=true}}, {"iron"}), true)
    equal(M.ore({name="minecraft:deepslate_diamond_ore"}, {"iron"}), false)
  end)
  for _, kind in ipairs({"ore", "fuel"}) do
    test("mine " .. kind .. " chest failures park and retry after sixty seconds", function()
      local s = setup({fuel=kind == "fuel" and 30 or 4000})
      if kind == "ore" then
        for slot=1,16 do s.turtle.inv[slot]={name="minecraft:diamond",count=64} end
      end
      s.net.world["1,0,0"]={name="minecraft:chest",inv={}}
      assert(s.server.env.SO.mods.drops.add({id=kind,dim=0,x=1,y=0,z=0,side="front",kind=kind}))
      local attempts, alerts, parks = 0, 0, 0
      s.turtle.env.turtle[kind == "ore" and "drop" or "suck"] = function() attempts=attempts+1 return false,kind=="ore" and "No space for items" or "No items to take" end
      local send = s.server.env.SO.mods.lease.send
      s.server.env.SO.mods.lease.send = function(id,steps,opts)
        if opts.ms == 600000 then parks=parks+1 end
        return send(id,steps,opts)
      end
      s.server.env.SO.mods.state={canStart=s.server.env.SO.mods.state.canStart,emit=function(name,data)
        if name=="mine.alert" then
          equal(data.text,kind.." #"..kind.." "..(kind=="ore" and "full" or "empty").." at 1,0,0")
          equal(data.point.id,kind)
          alerts=alerts+1
        end
      end}
      s.input("start") run(s,5)
      equal(attempts,3) equal(alerts,1) assert(parks>0)
      local row=persisted(s).turtles["2"]
      equal(row.state,"hold")
      assert(row.dropRetry.after)
      local shown=false
      for _, line in ipairs(s.render().rows) do if line.text:find(row.error,1,true) then shown=true end end
      assert(shown)
      run(s,54) equal(attempts,3)
      run(s,5) equal(attempts,4) equal(alerts,1)
    end)
  end

  for _, spec in ipairs({ { coal=1, enough=true }, { coal=0, enough=false } }) do
    test("mine empty fuel chest " .. (spec.enough and "returns with enough fuel" or "holds below reserve"), function()
      local s = setup({fuel=30})
      local chest = {name="minecraft:chest", inv={}}
      if spec.coal > 0 then chest.inv[1]={name="minecraft:coal",count=spec.coal} end
      s.net.world["1,0,0"] = chest
      assert(s.server.env.SO.mods.drops.add({id="fuel",dim=0,x=1,y=0,z=0,side="front",kind="fuel"}))
      local attempts, alerts = 0, 0
      local suck = s.turtle.env.turtle.suck
      s.turtle.env.turtle.suck = function(n) attempts=attempts+1 return suck(n) end
      s.server.env.SO.mods.state = {canStart=s.server.env.SO.mods.state.canStart,emit=function(name)
        if name=="mine.alert" then alerts=alerts+1 end
      end}
      s.input("start") run(s,100)
      local row = persisted(s).turtles["2"]
      if spec.enough then
        equal(row.trip,nil)
        equal(row.state,"done")
        equal(row.dropRetry,nil)
        equal(attempts,2)
        equal(alerts,0)
        assert(s.turtle.fuel > 64 and s.turtle.fuel < 2000)
        equal(s.turtle.pos,{x=3,y=-2,z=-5})
      else
        equal(row.state,"hold")
        equal(row.error,"fuel #fuel empty at 1,0,0")
        equal(row.trip.stage,"out")
        equal(alerts,1)
        assert(row.dropRetry.after)
        equal(s.turtle.pos,{x=0,y=0,z=0})
      end
    end)
  end

  test("mine inspect ends the batch before ore changes the plan", function()
    local M = dofile("so-mine-plan.lua")
    local row={pose={dim="minecraft:overworld",x=0,y=0,z=0,facing=0},goal={x=0,y=-20,z=0}}
    local known={}
    local action=M.next({},row,function(c) return known[M.key(c)] end,{},4000)
    equal(#action.steps,1) equal(action.steps[1].op,"inspectDown")
    known["0,-1,0"]={name="minecraft:iron_ore"}
    action=M.next({},row,function(c) return known[M.key(c)] end,{},4000)
    equal(action.kind,"dig") equal(action.ore,"minecraft:iron_ore")
    action=M.next({},row,function() return false end,{},4000)
    equal(#action.steps,16) equal(action.pose.y,-16)
  end)
  test("mine missing drop backs off and emits one alert", function()
    local s=setup()
    for slot=1,16 do s.turtle.inv[slot]={name="minecraft:diamond",count=64} end
    local picks, alerts=0,0
    local pick=s.server.env.SO.mods.drops.pick
    s.server.env.SO.mods.drops.pick=function(...) picks=picks+1 return pick(...) end
    s.server.env.SO.mods.state={canStart=s.server.env.SO.mods.state.canStart,emit=function(name) if name=="mine.alert" then alerts=alerts+1 end end}
    s.input("start") s.server.env.SO.mods.drops.remove("ready") run(s,5)
    equal(picks,1) equal(alerts,1)
    run(s,54) equal(picks,1)
    run(s,5) equal(picks,2) equal(alerts,1)
  end)

  test("mine completed branch unloads its remaining ore before parking",function()
    local s=setup()
    digWorld(s)
    s.turtle.inv[1]={name="minecraft:diamond",count=2}
    local chest={name="minecraft:chest",inv={}}
    s.net.world["-2,-1,0"]=chest
    assert(s.server.env.SO.mods.drops.add({id="ore",dim=0,x=-2,y=-1,z=0,side="down",kind="ore"}))
    s.input("start")
    run(s,200)
    local diamonds=0
    for _,item in ipairs(chest.inv) do if item.name=="minecraft:diamond" then diamonds=diamonds+item.count end end
    equal(diamonds,2)
    equal(persisted(s).turtles["2"].state,"done")
    equal(persisted(s).progress.done,1)
  end)

  test("SO11 lane geometry includes the shaft spine junction and exit",function()
    local env={dofile=dofile}
    setmetatable(env,{__index=_G})
    local M=assert(loadfile("so-mine-plan.lua","t",env))()
    local j={dim="minecraft:overworld",home={x=0,y=64,z=0,facing=0},bottom=40,
      mode="thorough",length=24,turtles={["2"]={branch=0},["3"]={branch=1}}}
    assert(M.inLane(j,{x=0,y=60,z=-1}),"shaft missing")
    assert(M.inLane(j,{x=0,y=40,z=-9}),"junction missing")
    assert(not M.inLane(j,{x=1,y=40,z=-9}),"branch is outside lane")
    local cells=M.lane(j,{x=1,y=40,z=-9})
    assert(#cells>16,"long lane truncated")
    local found={}
    for _,p in ipairs(cells) do found[p.x..","..p.y..","..p.z]=true end
    assert(found["0,64,-1"] and found["0,40,-9"] and found["1,40,-9"],"lane route or exit omitted")
  end)
  test("SO11 opposite lane passes retain one owner and let the waiter proceed",function()
    local s=setup()
    s.add(3,2)
    s.input("bottom -20")
    local disk=persisted(s)
    disk.running=true
    disk.turtles["2"].pose={dim=disk.dim,x=0,y=-20,z=-5,facing=2}
    disk.turtles["2"].anchor=disk.turtles["2"].pose
    disk.turtles["2"].frame=nil
    disk.turtles["2"].route={{dim=disk.dim,x=0,y=-20,z=-1},
      {dim=disk.dim,x=0,y=0,z=-1},{dim=disk.dim,x=-1,y=0,z=-1}}
    disk.turtles["2"].index=1
    s.turtle.pos={x=0,y=-20,z=-5} s.turtle.heading=2
    assert(s.server.env.SO.store.store("so-data/mine/job",function() return true end).save(disk))
    s.server=s.net.boot(s.server)
    for _,w in ipairs(s.turtles) do
      s.server.env.SO.mods.lease.handlers.hello({from=w.id,body={pose={x=0,y=-20,z=-9}}})
    end
    local cells=s.server.env.SO.mods.cells
    local moved,held,batches={},nil,0
    local reserve=cells.reserveMany
    cells.reserveMany=function(who,list)
      local ok,err=reserve(who,list)
      if ok then
        local a=cells.owner(0,0,-1)
        local b=cells.owner(0,-20,-1)
        if a and b then equal(a,b) held=a end
      end
      return ok,err
    end
    for _,w in ipairs(s.turtles) do
      local send=w.env.rednet.send
      w.env.rednet.send=function(id,msg,protocol)
        if msg.t=="step.report" then
          local p=w.pos
          if p.x==0 and p.z==-1 and p.y<0 then
            equal(cells.owner(0,0,-1),"mine:"..w.id)
            equal(cells.owner(0,-20,-1),"mine:"..w.id)
            batches=batches+1
          end
          if w.id==2 and p.y==0 and p.x==-1 or w.id==3 and p.x>=1 and p.y==-20 then moved[w.id]=true end
        end
        return send(id,msg,protocol)
      end
    end
    run(s,240)
    assert(held and batches>16,"lane was not kept across batches")
    assert(moved[2] and moved[3],"waiter did not enter after lane exit")
    local picture=H.encode(s.render())
    assert(not picture:find("failed",1,true),picture)
  end)
  test("SO11 deadlocked shaft poses cannot authorize a second lane entrant",function()
    local s=setup()
    local other=s.add(3,2)
    local cells=s.server.env.SO.mods.cells
    cells.releaseOwner("mine:2") cells.releaseOwner("mine:3")
    assert(cells.reserve("mine:2",0,60,-2))
    assert(cells.reserve("mine:3",0,60,-1))
    local disk=persisted(s)
    disk.running=true
    disk.home.y=64 disk.bottom=60
    disk.turtles["2"].frame=nil disk.turtles["3"].frame=nil
    disk.turtles["2"].pose={dim=disk.dim,x=0,y=60,z=-2,facing=2}
    disk.turtles["3"].pose={dim=disk.dim,x=0,y=60,z=-1,facing=0}
    disk.turtles["2"].anchor=disk.turtles["2"].pose
    disk.turtles["3"].anchor=disk.turtles["3"].pose
    assert(s.server.env.SO.store.store("so-data/mine/job",function() return true end).save(disk))
    s.turtle.pos={x=0,y=60,z=-2} s.turtle.heading=2
    other.pos={x=0,y=60,z=-1} other.heading=0
    s.server=s.net.boot(s.server)
    for _,w in ipairs(s.turtles) do
      s.server.env.SO.mods.lease.handlers.hello({from=w.id,body={pose={x=0,y=64,z=0}}})
    end
    local before={#s.server.sent,s.turtle.pos.z,other.pos.z}
    s.net.advance(6)
    for i=before[1]+1,#s.server.sent do
      local msg=s.server.sent[i].payload
      if msg.t=="lease.batch" then
        for _,step in ipairs(msg.body.steps) do
          assert(step.op~="forward" and step.op~="back" and step.op~="up" and step.op~="down","entered occupied lane")
        end
      end
    end
    equal(s.turtle.pos.z,before[2]) equal(other.pos.z,before[3])
  end)

  test("SO11 lane waiters use age then id and all pass within three grants",function()
    local s=setup()
    for id=3,5 do s.add(id,(id-2)*2) end
    local disk=persisted(s)
    local starts={{0,0,0},{1,-1,3},{-1,-1,1},{0,-2,2}}
    for id=2,5 do
      local at=starts[id-1]
      local row=disk.turtles[tostring(id)]
      row.pose={dim=disk.dim,x=at[1],y=0,z=at[2],facing=at[3]}
      row.anchor,row.frame=row.pose,nil
      local w=s.turtles[id-1]
      w.pos={x=at[1],y=0,z=at[2]} w.heading=at[3]
      s.server.env.SO.mods.cells.releaseOwner("mine:"..id)
    end
    disk.running=true
    assert(s.server.env.SO.store.store("so-data/mine/job",function() return true end).save(disk))
    s.server=s.net.boot(s.server)
    local cells=s.server.env.SO.mods.cells
    local reserve=cells.reserveMany
    assert(cells.reserve("fixture",0,0,-1))
    local lease=s.server.env.SO.mods.lease
    local status=lease.status
    local blocked={[2]=true,[3]=true,[4]=true}
    lease.status=function(id)
      local row=status(id)
      if blocked[id] and not row.open then row.open="fixture" end
      return row
    end
    local grants,last={},nil
    cells.reserveMany=function(who,list)
      local ok,err=reserve(who,list)
      local held=cells.owner(0,0,-1)
      if ok and held and held~=last then
        grants[#grants+1]=tonumber(held:match("mine:(%d+)")) last=held
      end
      return ok,err
    end
    run(s,3)
    blocked[3],blocked[4]=nil,nil
    run(s,3)
    blocked[2]=nil
    assert(cells.releaseOwner("fixture"))
    run(s,240)
    equal(grants,{5,3,4,2})
  end)

  test("mine supply trips share the shaft and retrace both branches",function()
    local s=setup()
    s.add(3,2)
    local M=dofile("so-mine-plan.lua")
    local disk=persisted(s)
    disk.running=true
    local chest={name="minecraft:chest",inv={}}
    s.net.world["-3,0,0"]=chest
    assert(s.server.env.SO.mods.drops.add({id="ore",dim=0,x=-3,y=0,z=0,side="front",kind="ore"}))
    local allowed={}
    for _,w in ipairs(s.turtles) do
      local row=disk.turtles[tostring(w.id)]
      row.branch=w.id-2 row.route=M.route(disk,row.branch) row.index=#row.route+1
      row.pose=row.route[#row.route] row.anchor=row.pose row.frame=nil
      row.inv={}
      for slot=1,16 do
        w.inv[slot]={name="minecraft:diamond",count=64}
        row.inv[slot]={slot=slot,name="minecraft:diamond",count=64}
      end
      w.pos={x=row.pose.x,y=row.pose.y,z=row.pose.z} w.heading=row.pose.facing
      for _,p in ipairs(row.route) do allowed[M.key(p)]=true end
      for y=-2,0 do allowed["0,"..y..",-1"]=true end
      s.server.env.SO.mods.cells.releaseOwner("mine:"..w.id)
    end
    assert(s.server.env.SO.store.store("so-data/mine/job",function() return true end).save(disk))
    s.server=s.net.boot(s.server)
    local cells=s.server.env.SO.mods.cells
    local visited,returns={},{}
    for _,w in ipairs(s.turtles) do
      s.server.env.SO.mods.lease.handlers.hello({from=w.id,body={pose={x=0,y=0,z=-20}}})
      for _,op in ipairs({"forward","back","up","down"}) do
        local move=w.env.turtle[op]
        w.env.turtle[op]=function(...)
          local ok,err=move(...)
          if ok then
            local p=w.pos
            assert(p.y==0 or allowed[M.key(p)],"supply trip left the dug mine")
            for _,other in ipairs(s.turtles) do
              if other~=w then assert(not M.same(p,other.pos),"supply turtles collided") end
            end
            if M.inLane(disk,p) then
              equal(cells.owner(0,0,-1),"mine:"..w.id)
              equal(cells.owner(0,-2,-1),"mine:"..w.id)
              visited[w.id]=true
            end
            if visited[w.id] and p.x==3 and p.y==-2 and p.z==-(5+(w.id-2)*4) then returns[w.id]=true end
          end
          return ok,err
        end
      end
    end
    run(s,300)
    assert(visited[2] and visited[3],"both supply trips must use the shared lane")
    assert(returns[2] and returns[3],"both supply trips must return to their branch tips")
    equal(persisted(s).turtles["2"].state,"done")
    equal(persisted(s).turtles["3"].state,"done")
  end)

  test("mine route planning avoids durable lookups and reuses a stopped pose",function()
    local s=setup({routeGuard=true})
    digWorld(s)
    local move=s.turtle.env.turtle.forward
    local blocked=0
    s.turtle.env.turtle.forward=function()
      local p=s.turtle.pos
      if p.x==1 and p.y==-2 and p.z==-5 then blocked=blocked+1 return false,"blocked" end
      return move()
    end
    s.input("start") run(s,40)
    assert(not table.concat(s.server.log,"\n"):find("route planning queried durable dug cells",1,true),
      "route planning queried durable dug cells")
    assert(blocked>2,"worker never retried a stationary obstruction")
    equal(s.turtle.pos,{x=1,y=-2,z=-5})
    local searches=0
    for _,count in pairs(s.server.env.routeSearches) do
      equal(count,1,"stationary planning rebuilt the home route")
      searches=searches+1
    end
    assert(searches>2,"worker did not exercise route planning")
  end)

  for _,kind in ipairs({"ore","fuel"}) do
    for _,cause in ipairs({"none","broken","stone","inventory"}) do
      test("mine names "..kind.." chest cause "..cause,function()
        local s=setup({fuel=kind=="fuel" and 30 or 4000})
        if kind=="ore" then for slot=1,16 do s.turtle.inv[slot]={name="minecraft:diamond",count=64} end end
        local drops=s.server.env.SO.mods.drops
        assert(drops.add({id=kind,dim=0,x=1,y=0,z=0,side="front",kind=kind}))
        s.input("start")
        assert(drops.remove("ready"))
        if cause=="none" then assert(drops.remove(kind))
        elseif cause=="broken" then for _=1,3 do assert(drops.note(kind,nil)) end
        elseif cause=="inventory" then
          s.net.world["1,0,0"]="minecraft:ender_chest"
        else s.net.world["1,0,0"]="minecraft:stone" end
        run(s,5)
        local row=persisted(s).turtles["2"]
        equal(row.error,cause=="none" and ("no "..kind.." chest set") or (kind.." #"..kind..(cause=="inventory" and " no inventory" or " broken").." at 1,0,0"))
        equal(row.state,"hold")
        assert(not row.error:find("full",1,true) and not row.error:find("empty",1,true))
      end)
    end
  end

end
