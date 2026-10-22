-- Gate B C8: a finished miner had backed along its path while the server was
-- quiet, then recovery marked it done where it stood. It parked in another
-- miner's return column for good.
local H = dofile("tests/so/harness.lua")
local FILES = { "so-server.lua", "so-store.lua", "so-mod-state.lua", "so-pair.lua", "so-proto.lua", "so-mod-lease.lua",
  "so-mod-cells.lua", "so-mod-display.lua", "so-mod-drops.lua", "so-mod-mine.lua", "so-mine-plan.lua", "so-plan.lua" }

local function tree(m)
  for _, name in ipairs({ "x25519", "random", "blake3", "chacha20", "config", "internal/util",
    "internal/hw", "internal/curve25519", "internal/fp", "internal/edwards25519", "internal/packing" }) do
    local path = "lib/ccryptolib/" .. name .. ".lua"
    local f = assert(io.open(path)); m.files[path] = f:read("*a"); f:close()
  end
end

local function wire(server)
  local input
  local display = server.env.SO.mods.display
  local original = display.screen
  display.screen = function(role, r, i) if role == "mining" then input = i end return original(role, r, i) end
  server.env.SO.mods.mine.tick()
  return function(text) input({ text = text }) end
end

local function job(server)
  return server.env.SO.store.read("so-data/mine/job").value.turtles["2"]
end

return function(test, equal)
  test("mine-done-return: a finished miner recovered away from its branch end returns there", function()
    local net = H.new()
    local server = net.machine({ id = 1, modem = true })
    server.install(FILES) tree(server)
    server.files["so-server.cfg"] = H.encode({ pos = { dim = "minecraft:overworld", x = 0, y = 0, z = 0 } })
    server.boot("so-server.lua") net.flush()
    local input = wire(server)
    local key = string.rep("a", 64)
    assert(server.env.SO.pair.remember(2, key))
    local turtle = net.machine({ id = 2, modem = true, turtle = true, fuel = 4000, capacity = 1000000 })
    turtle.install({ "worker.lua", "so-store.lua", "so-pair.lua", "so-proto.lua" }) tree(turtle)
    turtle.files["so-keys"] = H.encode({ schema = 1, generation = 1, value = { keys = { ["1"] = key } } })
    turtle.boot("worker.lua") net.flush()
    input("add 2 0 0 0 n") net.advance(1)
    for y = -2, 0 do net.world["0," .. y .. ",-1"] = "minecraft:stone" end
    for z = -2, -5, -1 do net.world["0,-2," .. z] = "minecraft:stone" end
    for x = 1, 3 do net.world[x .. ",-2,-5"] = "minecraft:stone" end
    input("bottom -2") input("length 3") input("start")
    net.advance(100)
    equal({ turtle.pos.x, turtle.pos.y, turtle.pos.z }, { 3, -2, -5 })
    equal(job(server).state, "done")

    -- Workers before #146 backed along their path after an idle park lease
    -- expired; Gate B's miner 5 was saved that way. Recreate that saved state:
    -- the turtle and its journal sit back in the spine at 0,-2,-2.
    net.kill(server)
    local store = turtle.env.dofile("so-store.lua")
    local box = store.store("so-journal", function(v) return type(v) == "table" end, 16000)
    local saved = box.value
    saved.pose, saved.moves, saved.park = { x = 0, y = -2, z = -2, f = 2 }, {}, nil
    assert(box.save(saved))
    net.onBoot = function(m)
      if m.id == 2 then m.pos.x, m.pos.y, m.pos.z, m.heading = 0, -2, -2, 2 end
    end
    turtle = net.boot(turtle) net.flush()
    net.onBoot = nil
    net.advance(5)
    assert(turtle.alive(), tostring(turtle.error))

    server = net.boot(server) net.flush()
    wire(server)
    net.advance(300)
    assert(not server.error, tostring(server.error))
    assert(not turtle.error, tostring(turtle.error))
    equal({ turtle.pos.x, turtle.pos.y, turtle.pos.z }, { 3, -2, -5 })
    local row = job(server)
    equal(row.state, "done")
    equal({ row.pose.x, row.pose.y, row.pose.z }, { 3, -2, -5 })
    equal(server.env.SO.mods.cells.owner(3, -2, -5), "mine:2")
  end)
end
