local harness = dofile("tests/so/harness.lua")

local SOURCES = {
  "so-proto.lua", "so-pair.lua", "so-store.lua", "so-server.lua",
  "so-mod-state.lua", "so-mod-cells.lua", "so-mod-display.lua", "so-mod-drops.lua",
}

local LIB = {
  "lib/ccryptolib/x25519.lua",
  "lib/ccryptolib/random.lua",
  "lib/ccryptolib/blake3.lua",
  "lib/ccryptolib/chacha20.lua",
  "lib/ccryptolib/config.lua",
  "lib/ccryptolib/internal/util.lua",
  "lib/ccryptolib/internal/hw.lua",
  "lib/ccryptolib/internal/curve25519.lua",
  "lib/ccryptolib/internal/fp.lua",
  "lib/ccryptolib/internal/edwards25519.lua",
  "lib/ccryptolib/internal/packing.lua",
}

local JOIN = [[
proto = dofile("so-proto.lua")
store = dofile("so-store.lua")
pair = dofile("so-pair.lua")
pair.open(proto, store)
local ok, err = pair.join(%q)
assert(ok, err)
JOINED = true
]]

local function copyCrypto(machine)
  for i = 1, #LIB do
    local path = LIB[i]
    local handle = assert(io.open(path, "rb"), path)
    machine.files[path] = handle:read("*a")
    handle:close()
  end
end

local function boot(extra)
  local net = harness.new()
  local server = net.machine({ id = 1, capacity = 16000000, modem = true })
  server.install(SOURCES)
  copyCrypto(server)
  if extra then extra(server) end
  server.boot("so-server.lua")
  net.flush()
  return net, server
end

local function logtext(machine)
  return table.concat(machine.log, "\n")
end

local function near()
  return { dim = 0, x = 0, y = 64, z = 0 }
end

local function place(id, x, side, kind, dim)
  return { id = id, dim = dim or 0, x = x, y = 64, z = 0, side = side, kind = kind }
end

return function(test, equal)
  test("a disk that loads so-pair without ccryptolib does not boot", function()
    local net = harness.new()
    local server = net.machine({ id = 1, capacity = 16000000, modem = true })
    server.install(SOURCES)
    server.boot("so-server.lua")
    net.flush()
    assert(not server.alive(), "booted without ccryptolib")
    assert(tostring(server.error):find("ccryptolib", 1, true), tostring(server.error))
  end)

  test("the 65th drop point is refused and a repeat does not grow the list", function()
    local _, server = boot()
    assert(server.alive(), tostring(server.error))
    assert(server.files["lib/ccryptolib/x25519.lua"], "ccryptolib missing")
    local drops = server.env.SO.mods.drops
    for i = 1, 64 do
      local ok, err = drops.add(place("p" .. i, i, "front", "fuel"))
      assert(ok, tostring(err) .. " at " .. i)
    end
    local ok, err = drops.add(place("p65", 65, "front", "fuel"))
    assert(ok == false and err == "full", tostring(err))
    assert(drops.add(place("p1", 1, "front", "fuel")) == true)
    local again, exists = drops.add(place("p1", 9, "front", "fuel"))
    assert(again == false and exists == "exists", tostring(exists))
    local saved = server.env.textutils.unserialize(server.files["so-drops"])
    equal(#saved.value.points, 64)
    equal(drops.steps({ name = "minecraft:cobble", n = 1, where = "front" }), {})
    assert(drops.pick({ name = "minecraft:cobble", n = 1 }) == nil)
    assert(drops.add({ id = "up_1", dim = 0, x = 0, y = 70, z = 0, side = "up", kind = "ore" }) == false)
  end)

  test("pick falls back from a broken ore chest to any, then hold, and fix brings the ore back", function()
    local _, server = boot()
    assert(server.alive(), tostring(server.error))
    local drops = server.env.SO.mods.drops
    assert(drops.add(place("ore_1", 3, "front", "ore")) == true)
    assert(drops.add(place("any_1", 9, "down", "any")) == true)
    assert(drops.add(place("other_dim", 1, "front", "ore", 1)) == true)
    drops.note("ore_1", nil)
    drops.note("ore_1", "minecraft:chest")
    local healed = drops.pick("ore", near())
    equal(healed.point.id, "ore_1")
    drops.note("ore_1", nil)
    drops.note("ore_1", nil)
    drops.note("ore_1", nil)
    drops.note("ore_1", "minecraft:chest")
    local choice = drops.pick("ore", near())
    equal(choice.point, { id = "any_1", dim = 0, x = 9, y = 64, z = 0, side = "down", kind = "any" })
    assert(choice.alert == nil)
    equal(choice.chain[1].kind, "ore")
    assert(choice.chain[1].usable == false)
    assert(choice.chain[1].point == nil)
    equal(choice.chain[2], { kind = "any", point = choice.point, usable = true })
    equal(choice.chain[3], "hold")
    equal(drops.steps(choice.point), { { op = "inspectDown" }, { op = "dropDown" } })
    drops.note("any_1", nil)
    drops.note("any_1", nil)
    drops.note("any_1", nil)
    local held = drops.pick("ore", near())
    assert(held.point == nil)
    equal(held.alert, "drops: hold ore")
    equal(held.chain[3], "hold")
    equal(server.env.SO.mods.state.get("drops.alert"), { kind = "ore", text = "drops: hold ore" })
    assert(drops.fix("ore_1") == true)
    local back = drops.pick("ore", near())
    equal(back.point, { id = "ore_1", dim = 0, x = 3, y = 64, z = 0, side = "front", kind = "ore" })
    equal(drops.steps(back.point), { { op = "inspect" }, { op = "drop" } })
    assert(back.alert == nil)
  end)

  test("hold still returns an alert when state and display are missing", function()
    local net, server = boot(function(machine)
      machine.files["so-mod-state.lua"] = nil
      machine.files["so-mod-display.lua"] = nil
    end)
    assert(server.alive(), tostring(server.error))
    assert(server.files["lib/ccryptolib/x25519.lua"], "ccryptolib missing")
    local drops = server.env.SO.mods.drops
    local held = drops.pick("wood", near())
    assert(held.point == nil)
    equal(held.alert, "drops: hold wood")
    net.advance(1)
    assert(server.alive(), tostring(server.error))
    assert(not logtext(server):find("tick drops failed", 1, true), logtext(server))
  end)

  test("the generic screen can fix a point and a saved file loads on the next boot", function()
    local net, server = boot()
    assert(server.alive(), tostring(server.error))
    local drops = server.env.SO.mods.drops
    assert(drops.add(place("ore_1", 3, "front", "ore")) == true)
    drops.note("ore_1", nil)
    drops.note("ore_1", nil)
    drops.note("ore_1", nil)
    local seen
    server.env.SO.mods.display.screen = function(role, render, input)
      seen = { role = role, render = render, input = input }
    end
    net.advance(1)
    equal(seen.role, "generic")
    local frame = seen.render()
    assert(type(frame.rev) == "number")
    local broken = false
    for i = 1, #frame.rows do
      if frame.rows[i].text:find("ore_1", 1, true) and frame.rows[i].text:find("broken", 1, true) then
        broken = true
      end
    end
    assert(broken, "screen did not show the broken ore chest")
    seen.input({ role = "generic", id = "fix:ore_1", x = 1, y = 2 })
    equal(drops.pick("ore", near()).point.id, "ore_1")
    seen.input({ role = "generic", id = "add", x = 1, y = 3 })
    equal(drops.pick("ore", near()).point.id, "0_0_64_0_front_ore")
    local raw = server.files["so-drops"]
    local _, again = boot(function(machine)
      machine.files["so-drops"] = raw
    end)
    assert(again.alive(), tostring(again.error))
    equal(again.env.SO.mods.drops.pick("ore", near()).point.id, "0_0_64_0_front_ore")
  end)

  test("drops.edit accepts a table payload and ignores a string", function()
    local net, server = boot()
    assert(server.alive(), tostring(server.error))
    server.env.os.queueEvent("key", 25, false)
    net.flush()
    assert(server.alive(), tostring(server.error))
    local code = assert(logtext(server):match("Pair code: (%d%d%d%d%d%d)"), logtext(server))
    local client = net.machine({ id = 2, capacity = 1000000, modem = true })
    client.install({ "so-proto.lua", "so-pair.lua", "so-store.lua" })
    copyCrypto(client)
    assert(client.files["lib/ccryptolib/x25519.lua"], "client ccryptolib missing")
    client.spawn(string.format(JOIN, code))
    net.flush()
    assert(not client.error, tostring(client.error))
    assert(client.env.JOINED == true, "join did not finish")
    client.spawn(string.format([[
local reply, err = proto.request(%d, "drops.edit", {
  op = "add", id = "wire_1", dim = 0, x = 4, y = 64, z = 1, side = "front", kind = "wood",
}, 2, 2)
assert(reply and reply.t == "ack" and reply.body.ok == true and reply.body.id == "wire_1", tostring(err))
local up, uerr = proto.request(%d, "drops.edit", {
  op = "add", id = "wire_up", dim = 0, x = 0, y = 70, z = 0, side = "up", kind = "ore",
}, 2, 2)
assert(up and up.t == "err" and up.body.code == "side", tostring(uerr) .. " " .. tostring(up and up.t))
EDIT = reply
]], server.id, server.id))
    net.flush()
    assert(not client.error, tostring(client.error))
    assert(not server.error, tostring(server.error))
    local tableSent = false
    for i = 1, #client.sent do
      if type(client.sent[i].payload) == "table" and client.sent[i].payload.t == "drops.edit" then
        tableSent = true
      end
      assert(type(client.sent[i].payload) ~= "string", "rednet payload was a string")
    end
    assert(tableSent, "drops.edit was not sent as a table")
    equal(server.env.SO.mods.drops.pick("wood", near()).point.id, "wire_1")
    local before = #server.env.textutils.unserialize(server.files["so-drops"]).value.points
    client.env.rednet.send(server.id, "drops.edit", "so")
    net.flush()
    assert(server.alive(), tostring(server.error))
    assert(logtext(server):find("so-server: bad message from 2", 1, true), logtext(server))
    equal(#server.env.textutils.unserialize(server.files["so-drops"]).value.points, before)
    for i = 1, 63 do
      assert(server.env.SO.mods.drops.add(place("w" .. i, 100 + i, "front", "junk")) == true)
    end
    client.env.EDIT = nil
    client.spawn(string.format([[
local reply, err = proto.request(%d, "drops.edit", {
  op = "add", id = "wire_65", dim = 0, x = 80, y = 64, z = 0, side = "down", kind = "junk",
}, 2, 2)
assert(reply and reply.t == "err" and reply.body.code == "full" and reply.body.text == "64 points", tostring(err))
FULL = reply
]], server.id))
    net.flush()
    assert(not client.error, tostring(client.error))
    equal(client.env.FULL.body.code, "full")
  end)
end
