local function setup(legacy)
  local s = { now = 1000, sends = {}, session = { id = 2 } }
  local env = setmetatable({
    fs = { exists = function() return not legacy end },
    os = { epoch = function() return 72840000 end },
    rednet = {
      send = function(id, body)
        s.sends[#s.sends + 1] = { id = id, body = body }
        return true
      end,
      broadcast = function() end,
    },
    SO = { now = function() return s.now end, mods = { display = {
      screen = function(_, render, input) s.render, s.input = render, input end,
    } } },
  }, { __index = _G })
  s.mod = assert(loadfile("so-mod-shop.lua", "t", env))()
  function s.at(ms)
    s.now = 1000 + ms
    s.mod.listen.roomsorter_stock(9, { totals = { ["minecraft:iron_ingot"] = 64 } })
    s.mod.tick(s.now)
  end
  s.at(0)
  s.input({ session = s.session, id = "item:minecraft:iron_ingot" })
  function s.order()
    s.input({ session = s.session, id = "order:16:minecraft:iron_ingot" })
    return s.sends[#s.sends].body.rid
  end
  function s.reply(rid, text, sender)
    s.mod.listen.roomsorter(sender or 9, { rid = rid, text })
  end
  function s.text()
    local lines = {}
    for _, row in ipairs(s.render(39, 19, s.session).rows) do lines[#lines + 1] = row.text end
    return table.concat(lines, "\n")
  end
  function s.row(status)
    assert(s.text():find("16 " .. status, 1, true), "missing order row: " .. status)
  end
  return s
end

return function(test)
  for _, acknowledgement in ipairs({ "Getting 16 Iron ingot...", "Crafting 16 Iron ingot..." }) do
    test("shop UB-10 delivers after 121 seconds: " .. acknowledgement, function()
      local s = setup()
      local rid = s.order()
      s.reply(rid, acknowledgement)
      s.at(121000)
      s.row("sent")
      s.reply(rid, "Delivered 16 Iron ingot")
      s.row("delivered")
    end)
  end

  test("shop UB-10 acknowledged order fails at 600 seconds without extending on replies", function()
    local s = setup()
    local rid = s.order()
    s.at(100000)
    s.reply(rid, "Getting 16 Iron ingot...")
    s.at(599999)
    s.reply(rid, "Crafting 16 Iron ingot...")
    s.row("sent")
    s.at(600000)
    s.row("failed")
    for _, reply in ipairs({ "Delivered 16 Iron ingot", "Getting 16 Iron ingot...", "Refused order" }) do
      s.reply(rid, reply)
      s.row("failed")
    end
  end)

  test("shop UB-10 accepts refusal after an acknowledgement and 121 seconds", function()
    local s = setup()
    local rid = s.order()
    s.reply(rid, "Getting 16 Iron ingot...")
    s.at(121000)
    s.reply(rid, "Refused order")
    s.row("failed")
    s.reply(rid, "Delivered 16 Iron ingot")
    s.row("failed")
  end)

  test("shop UB-10 reports no delivery after the acknowledged deadline", function()
    local s = setup(true)
    local rid = s.order()
    s.reply(rid, "Getting 16 Iron ingot...")
    s.at(600000)
    assert(s.text():find("Order: no delivery", 1, true))
    s.reply(rid, "Delivered 16 Iron ingot")
    assert(s.text():find("Order: no delivery", 1, true))
  end)

  test("shop UB-10 unacknowledged order still fails at 120 seconds", function()
    local s = setup()
    local rid = s.order()
    s.at(119999)
    s.row("sent")
    s.reply(rid, "Getting 16 Iron ingot...", 10)
    s.reply(rid + 1000, "Getting 16 Iron ingot...")
    s.at(120000)
    s.row("failed")
    s.reply(rid, "Delivered 16 Iron ingot")
    s.row("failed")
  end)
end
