return function(test, read, mocks)
  local UUID = "12345678-1234-1234-1234-123456789abc"
  local OTHER = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  local function setup(cfg)
    local now, replies, calls = 100000, {}, {}
    local chat = assert(load(read("chat-control.lua"), "=chat", "t", _G))().new(cfg or {}, {
      now = function() return now end,
      save = function() return true end,
      reply = function(name, text, hidden) replies[#replies + 1] = { name, text, hidden } end,
      execute = function(action, args, uuid)
        calls[#calls + 1] = { action, args, uuid }
        return true, "queued; awaiting turtle acknowledgement"
      end,
    })
    return chat, replies, calls, function(ms) now = now + ms end
  end
  test("chat defaults deny and usernames never authorize", function()
    local c, replies, calls = setup()
    c:event("chat", "Jeffreyy2", "!hub", UUID, false)
    assert(#calls == 0 and #replies == 0)
    assert(c:command({ "enable", "on" }))
    c:event("chat", "Jeffreyy2", "!hub", UUID, false)
    assert(#calls == 0 and #replies == 0)
    assert(c:command({ "allow", UUID, "Jeffreyy2" }))
    c:event("chat", "Jeffreyy2", "!hub", OTHER, false)
    assert(#replies == 0)
  end)
  test("chat confirms once, binds UUID and expires requests", function()
    local c, replies, calls, advance = setup({ chatEnabled = true, chatAllowlist = { [UUID] = "Jeffreyy2", [OTHER] = "njov10" } })
    c:event("chat", "Jeffreyy2", "!hub", UUID, false)
    local token = assert(replies[#replies][2]:match("confirm (%S+)"))
    assert(#calls == 0)
    c:event("chat", "njov10", "!confirm " .. token, OTHER, false)
    assert(#calls == 0)
    c:event("chat", "Jeffreyy2", "!confirm " .. token, UUID, false)
    assert(#calls == 1 and calls[1][1] == "hub")
    assert(replies[#replies][2]:find("awaiting turtle", 1, true))
    c:event("chat", "Jeffreyy2", "!confirm " .. token, UUID, false)
    assert(#calls == 1)
    c:event("chat", "Jeffreyy2", "!recharge", UUID, false)
    token = assert(replies[#replies][2]:match("confirm (%S+)"))
    advance(31000)
    c:event("chat", "Jeffreyy2", "!confirm " .. token, UUID, false)
    assert(#calls == 1)
  end)
  test("AP public and stripped hidden tuples preserve visibility", function()
    local c, replies, calls = setup({ chatEnabled = true, chatAllowlist = { [UUID] = "Jeffreyy2" } })
    assert(not c:event("chat", "Jeffreyy2", "pro on", UUID, false))
    c:event("chat", "Jeffreyy2", "pro on", UUID, true)
    assert(replies[#replies][3] == true)
    local token = replies[#replies][2]:match("confirm (%S+)")
    c:event("chat", "Jeffreyy2", "confirm " .. token, UUID, true)
    assert(calls[1][1] == "pro" and calls[1][2][1] == "on")
    c:event("chat", "Jeffreyy2", "!xray off", UUID, false)
    assert(replies[#replies][3] == false)
    c:event("chat", "Jeffreyy2", "$recharge", UUID, true)
    assert(replies[#replies][3] == true and replies[#replies][2]:find("recharge", 1, true))
  end)
  test("chat rejects confirmation replay after restart", function()
    local cfg = { chatEnabled = true, chatAllowlist = { [UUID] = "Jeffreyy2" } }
    local c, replies = setup(cfg)
    c:event("chat", "Jeffreyy2", "!hub", UUID, false)
    local token = assert(replies[#replies][2]:match("confirm (%S+)"))
    local restarted, _, calls = setup(cfg)
    restarted:event("chat", "Jeffreyy2", "!confirm " .. token, UUID, false)
    assert(#calls == 0)
  end)
  test("chat settings validate UUIDs and configurable geometry", function()
    local cfg = {}
    local c = setup(cfg)
    assert(not c:command({ "allow", "Jeffreyy2" }))
    assert(not c:command({ "bounds", "minecraft:overworld", "9", "0", "0", "1", "1", "1" }))
    assert(c:command({ "bounds", "minecraft:overworld", "0", "-64", "0", "10", "70", "10" }))
    assert(cfg.mineBounds.max.y == 70)
    assert(c:command({ "spot", "charging", "north", "minecraft:overworld", "1", "64", "-2" }))
    assert(cfg.spots.charging.north.x == 1)
    assert(not c:command({ "spot", "charging", "bad", "minecraft:overworld", "nan", "64", "0" }))
  end)
  test("chat save failures keep authorization disabled", function()
    local cfg = {}
    local c = dofile("chat-control.lua").new(cfg, { now = function() return 100000 end,
      save = function() return false, "disk full" end })
    assert(not c:command({ "enable", "on" }))
    assert(not cfg.chatEnabled)
    assert(not c:command({ "allow", UUID, "Jeffreyy2" }))
    assert(not cfg.chatAllowlist)
  end)
  test("AR settings keep recovered backup after a failed promotion", function()
    local m = mocks.new(false)
    m.files["ar.cfg"] = "broken"
    m.files["ar.cfg.bak"] = mocks.encode({ enabled = true, chatAllowlist = { [UUID] = "Jeffreyy2" } })
    local H = assert(load(read("ar-hud.lua"), "=ar-hud", "t", m.env))()
    local cfg, save = H.settings()
    assert(cfg.enabled and cfg.chatAllowlist[UUID])
    local move = m.env.fs.move
    m.env.fs.move = function(from, to)
      if from == "ar.cfg.tmp" then error("injected promotion failure") end
      return move(from, to)
    end
    cfg.proHud = false
    assert(not save())
    local recovered = H.settings()
    assert(recovered.enabled and recovered.chatAllowlist[UUID], "authorization configuration was lost")
  end)
  test("AR settings preserve sole temp generation before a write failure", function()
    local m = mocks.new(false)
    m.files["ar.cfg.tmp"] = mocks.encode({ enabled = true, chatAllowlist = { [UUID] = "Jeffreyy2" } })
    local H = assert(load(read("ar-hud.lua"), "=ar-hud", "t", m.env))()
    local cfg, save = H.settings()
    local open = m.env.fs.open
    m.env.fs.open = function(path, mode)
      if mode == "w" then error("injected write failure") end
      return open(path, mode)
    end
    assert(not save())
    assert(H.settings().chatAllowlist[UUID])
    m.files["ar.cfg"], m.files["ar.cfg.tmp"], m.files["ar.cfg.bak"] = nil, "broken", "broken"
    assert(not pcall(H.settings), "invalid generations silently reset to defaults")
  end)
  test("AR recovery retains more than 4096 IDs from interrupted frame unions", function()
    local m = mocks.new(true)
    local ids = {}
    for i = 1, 7000 do ids[i] = "ssot-ar:ore:" .. i end
    m.files["ar.ids"] = mocks.encode(ids)
    local H = assert(load(read("ar-hud.lua"), "=ar-hud", "t", m.env))()
    local mem = H.memory("ar.ids")
    local count = 0
    for _ in pairs(mem.elements) do count = count + 1 end
    assert(count == 7000 and mem.elements["ssot-ar:ore:7000"])
    H.clear(m.ar, mem)
    assert(not next(mem.elements))
  end)
  test("AR snapshot skips stone and hidden air before its ore budget", function()
    local m = mocks.new(false)
    local H = assert(load(read("ar-hud.lua"), "=ar-hud", "t", m.env))()
    local cells = {}
    for i = 1, 200 do cells[i] = i % 2 == 0 and 0 or 1 end
    cells[201] = 2
    local cfg = { dimension = "minecraft:overworld", origin = { dim = "minecraft:overworld", x = 0, y = 0, z = 0 },
      maxCells = 128, xrayOres = true, xrayTunnels = false }
    local snap = H.snapshot({}, { names = { "minecraft:stone", "minecraft:diamond_ore" },
      chunks = { ["minecraft:overworld|0|0|0"] = { cells = cells } } }, cfg)
    assert(#snap.world_map == 1 and snap.world_map[1].name == "minecraft:diamond_ore")
  end)
end
