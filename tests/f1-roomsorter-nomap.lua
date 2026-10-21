return function(test, equal, read, mocks)
  test("a storage turtle with config and no map still answers stock", function()
    local m = mocks.new(false)
    m.env.turtle = {
      getFuelLevel = function() return 0 end,
      select = function() end,
      getItemCount = function() return 0 end,
      getItemDetail = function() end,
    }
    m.env.os.date = function() return "test" end
    m.env.os.getComputerID = function() return 12 end
    m.env.os.getComputerLabel = function() return "storage" end
    m.files["room.cfg.a"] = mocks.encode({ v = 1, generation = 1, value = { keepLogs = 32 } })
    m.start(read("roomsorter.lua"))
    local hosted = false
    for _, line in ipairs(m.output) do
      if line:find("roomsorter", 1, true) and line:find("rednet.host", 1, true) then hosted = true end
    end
    assert(hosted, "turtle returned before rednet.host\n" .. table.concat(m.output, "\n"))
    m.push("rednet_message", 4, { cmd = "stock", rid = 9 }, "roomsorter")
    local reply
    for i = #m.messages, 1, -1 do
      local msg = m.messages[i]
      if type(msg) == "table" and msg.rid == 9 then reply = msg end
    end
    assert(type(reply) == "table" and type(reply.totals) == "table", "stock reply has no totals")
    equal(reply.state, "No map yet")
    equal(reply.version, 15)
    m.push("rednet_message", 4, { cmd = "status", rid = 10 }, "roomsorter")
    local again
    for i = #m.messages, 1, -1 do
      local msg = m.messages[i]
      if type(msg) == "table" and msg.rid == 10 then again = msg end
    end
    assert(type(again) == "table" and again.rid == 10, "turtle died after the first stock request")
    m.tick()
    local stock
    for i = #m.messages, 1, -1 do
      local msg = m.messages[i]
      if type(msg) == "table" and msg.state == "No map yet" and msg.rid == nil then stock = msg end
    end
    assert(type(stock) == "table" and type(stock.totals) == "table", "no-map loop did not broadcast stock")
    equal(stock.used, 0)
    equal(stock.size, 0)
    equal(stock.chests, 0)
    equal(stock.furnaces, 0)
    local hinted = false
    for _, line in ipairs(m.output) do
      if line:find("Hold Ctrl+T to stop, then run roomsorter scan", 1, true) then hinted = true end
    end
    assert(hinted, "no-map screen does not say how to stop and scan")
  end)
end
