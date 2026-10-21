return function(test, equal)
  local UUID = "12345678-1234-1234-1234-123456789abc"
  local OTHER = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  local dim = "minecraft:overworld"

  test("anchor command rejects a bad facing and does not call anchor", function()
    local Anchor = dofile("anchor-radio.lua")
    local calls = 0
    local nav = { anchor = function() calls = calls + 1 return true end }
    local ok, why = Anchor.command(nav, { "anchor", "10", "64", "-20", "nope" }, { dim = dim })
    equal(ok, false)
    equal(why, "invalid anchor")
    equal(calls, 0)
  end)

  test("anchor command stores a typed absolute pose", function()
    local Anchor = dofile("anchor-radio.lua")
    local spec
    local nav = { anchor = function(value) spec = value return true end }
    local ok, why = Anchor.command(nav, { "anchor", "10", "64", "-20", "north" }, { dim = dim })
    assert(ok, why)
    equal(spec.src, "typed")
    equal(spec.frame, "abs")
    equal(spec.yAbs, true)
    equal(spec.h, 0)
    equal({ spec.x, spec.y, spec.z }, { 10, 64, -20 })
  end)

  test("anchor relay sends nothing without a detector", function()
    local Anchor = dofile("anchor-radio.lua")
    local sent = false
    local ok = Anchor.relay(function() sent = true end, nil, "Ada", { "17" }, dim)
    equal(ok, false)
    equal(sent, false)
  end)

  test("anchor relay keeps the detector y and the dollar text", function()
    local Anchor = dofile("anchor-radio.lua")
    local sent
    local detector = { getPlayerPos = function() return { x = 1.2, y = 66.9, z = -3.4, dim = dim } end }
    local ok, why = Anchor.relay(function(id, proto, message)
      sent = { id = id, proto = proto, message = message }
    end, detector, "Ada", { "17" }, "minecraft:the_nether")
    assert(ok, why)
    equal(sent.message.text, "$anchor 17")
    equal(sent.message.player.y, 66.9)
    equal(sent.proto, "minearmy")
  end)

  test("anchor accept ignores a sender other than the server", function()
    local Anchor = dofile("anchor-radio.lua")
    local heard = false
    local nav = { hear = function() heard = true return true end }
    local ok = Anchor.accept(nav, { text = "$anchor 9", player = { x = 1, y = 65, z = 1, dim = dim } }, 4, 9)
    equal(ok, false)
    equal(heard, false)
  end)

  test("chat anchor ignores a player who is not allow-listed", function()
    local calls = 0
    local chat = dofile("chat-control.lua").new({
      chatEnabled = true, chatNames = { "Ada" }, chatUUIDs = { Ada = UUID },
    }, {
      now = function() return 1000 end,
      execute = function() calls = calls + 1 return true, "sent" end,
    }, { chatNames = { "Ada" }, chatUUIDs = { Ada = UUID } })
    local ok = chat:event("chat", "Eve", "anchor 17", OTHER, true)
    equal(ok, false)
    equal(calls, 0)
  end)

  test("chat anchor runs without storing a confirm token", function()
    local calls, replies = {}, {}
    local chat = dofile("chat-control.lua").new({
      chatEnabled = true, chatNames = { "Ada" }, chatUUIDs = { Ada = UUID },
    }, {
      now = function() return 1000 end,
      execute = function(action, args, id, username)
        calls[#calls + 1] = { action, args, id, username }
        return true, "Anchor sent to 17"
      end,
      reply = function(_, text) replies[#replies + 1] = text end,
    }, { chatNames = { "Ada" }, chatUUIDs = { Ada = UUID } })
    local ok, status = chat:event("chat", "Ada", "anchor 17", UUID, true)
    equal(ok, true)
    equal(status, "accepted")
    equal(calls[1][1], "anchor")
    equal(calls[1][2][1], "17")
    equal(calls[1][4], "Ada")
    assert(not tostring(replies[#replies]):find("confirm", 1, true), "anchor stored a confirm token")
    chat:event("chat", "Ada", "confirm 17", UUID, true)
    equal(#calls, 1)
  end)

  test("anchor boot keeps only the point from the later cell", function()
    local Anchor = dofile("anchor-radio.lua")
    local pose = { conf = "suspect", dim = dim, x = 0, y = 64, z = 0, h = 0 }
    local radioed
    local nav = {
      pose = function() return pose end,
      reckoned = function() return { pose = pose, legs = {} } end,
      radio = function(points) radioed = points return false, "suspect" end,
    }
    local replyCh
    local modem = {
      open = function() end,
      transmit = function(_, reply, payload) if payload == "PING" then replyCh = reply end end,
    }
    local old = sleep
    sleep = function()
      Anchor.onModem(nav, replyCh, { 10, 64, 0 }, 4)
      pose = { conf = "suspect", dim = dim, x = 2, y = 64, z = 0, h = 0 }
      Anchor.onModem(nav, replyCh, { 12, 64, 0 }, 6)
      Anchor.onModem(nav, replyCh, { 0, 70, 0 }, 6)
      Anchor.onModem(nav, replyCh, { 0, 64, 8 }, 6)
      Anchor.onModem(nav, replyCh, { 0, 64, -8 }, 6)
    end
    local ok = pcall(function() Anchor.boot(nav, { modem = modem, timeout = 1 }) end)
    sleep = old
    assert(ok)
    assert(radioed and #radioed == 4, "later cell did not keep four points")
    for index = 1, #radioed do
      assert(not (radioed[index].x == 10 and radioed[index].dist == 4), "kept the point from the earlier cell")
    end
  end)

  test("anchor boot does not sample a certain pose", function()
    local Anchor = dofile("anchor-radio.lua")
    local calls, transmits = 0, 0
    local nav = {
      pose = function() return { conf = "certain", dim = dim, x = 0, y = 64, z = 0 } end,
      radio = function() calls = calls + 1 return true end,
    }
    local modem = { open = function() end, transmit = function() transmits = transmits + 1 end }
    local ok, why = Anchor.boot(nav, { modem = modem, timeout = 0 })
    equal(ok, false)
    equal(why, "already certain")
    equal(calls, 0)
    equal(transmits, 0)
  end)

  test("anchor answer names the server cell only for where_server", function()
    local Anchor = dofile("anchor-radio.lua")
    local sent = {}
    local modem = { transmit = function(reply, channel, message)
      sent[#sent + 1] = { reply = reply, channel = channel, message = message }
    end }
    local ok = Anchor.answer(modem, 16525, 12, { type = "where_server" }, { x = 1, y = 2, z = 3, dim = dim })
    equal(ok, true)
    equal(sent[1].message.type, "server_here")
    equal(sent[1].message.dim, dim)
    equal(sent[1].channel, 16525)
    ok = Anchor.answer(modem, 16524, 12, { type = "where_hub" }, { x = 1, y = 2, z = 3, dim = dim })
    equal(ok, false)
    equal(#sent, 1)
  end)
end
