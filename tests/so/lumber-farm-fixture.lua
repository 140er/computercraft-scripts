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
local function setup(saplings, fuel, side, count, starts, tools)
  count = count or 1
  side = side or "down"
  local n = H.new()
  local s = n.machine({ id = 1, modem = true })
  s.install({ "so-server.lua", "so-proto.lua", "so-pair.lua", "so-store.lua", "so-plan.lua",
    "so-lumber-plan.lua", "so-mod-lease.lua", "so-mod-cells.lua", "so-mod-drops.lua",
    "so-mod-display.lua", "so-mod-lumber.lua", "so-mod-state.lua" })
  libs(s)
  local keys = {}
  for id = 2, count + 1 do keys[tostring(id)] = KEY end
  s.files["so-keys"] = H.encode({schema=1,generation=1,value={keys=keys}})
  s.boot("so-server.lua")
  assert(s.alive(), tostring(s.error))
  local digs, burned, workers, dugCells = {}, {}, {}, {}
  local function worker(id)
  local at = starts and starts[id] or { x=-2, y=2, z=(id - 2) * 2 }
  local w = n.machine({ id = id, modem = true, turtle = true, x = at.x, y = at.y, z = at.z,
    facing = 1, fuel = fuel or 10000, capacity = 1000000 })
  w.install({ "worker.lua", "so-proto.lua", "so-pair.lua", "so-store.lua" })
  libs(w)
  w.files["so-keys"] = H.encode({schema=1,generation=1,value={keys={["1"]=KEY}}})
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
        dugCells[id] = (dugCells[id] or 0) + 1
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
  return w
  end
  for id = 2, count + 1 do workers[#workers + 1] = worker(id) end
  local w = workers[1]
  local screens, events = {}, {}
  local register = s.env.SO.mods.display.screen
  s.env.SO.mods.display.screen = function(role, render, input)
    if render then screens[role] = { render = render, input = input } end
    return register(role, render, input)
  end
  s.env.SO.mods.state = { canStart = s.env.SO.mods.state.canStart, emit = function(kind, data) events[#events+1] = {kind=kind,data=data} return true end }
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
  local P = dofile("so-plan.lua")
  for _, worker in ipairs(workers) do
    for _, op in ipairs({ "forward", "back", "up", "down" }) do
      local move = worker.env.turtle[op]
      worker.env.turtle[op] = function()
        local at = P.apply({ x=worker.pos.x, y=worker.pos.y, z=worker.pos.z, facing=worker.heading }, op)
        for _, other in ipairs(workers) do
          assert(other == worker or at.x ~= other.pos.x or at.y ~= other.pos.y or at.z ~= other.pos.z,
            "turtle collision " .. worker.id .. " with " .. other.id .. " at " .. at.x .. "," .. at.y .. "," .. at.z)
        end
        return move()
      end
    end
    if tools then
      worker.env.turtle.getEquippedLeft = function() return {name=tools.left} end
      worker.env.turtle.getEquippedRight = function() return {name=tools.right} end
      worker.files["so-worker.cfg"] = "{autoToolSwap=false}"
    end
    worker.boot("worker.lua")
  end
  n.flush()
  n.advance(1)
  assert(screens.lumber, "lumber screen not registered")
  local function command(text)
    s.env.SO.mods.display.screen("lumber").input({text=text,role="lumber",x=1,y=1})
  end
  command("area 0 0 8 8 0")
  command("saplings "..chests.saplings.x.." "..chests.saplings.y.." "..chests.saplings.z.." "..side)
  for _, worker in ipairs(workers) do
    command(string.format("add %d %d %d %d e", worker.id, worker.pos.x, worker.pos.y, worker.pos.z))
  end
  n.advance(2)
  command("start")
  return {net=n,server=s,worker=w,workers=workers,dugCells=dugCells,screens=screens,events=events,digs=digs,burned=burned,wood=chests.wood,chests=chests,command=command}
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
    for _, worker in ipairs(g.workers) do if not worker.killed then assert(worker.alive(), tostring(worker.error)) end end
    for _, line in ipairs(g.server.log) do assert(not line:find("failed:",1,true), line) end
    if untilFn(g) then return end
  end
  error("lumber did not finish: " .. H.encode(g.server.env.SO.mods.display.screen("lumber").render()))
end

return { setup = setup, delivered = delivered, run = run, trees = TREES }
