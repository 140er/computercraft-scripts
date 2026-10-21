return function(test, equal, read, mocks)
  local function screen(m, from)
    local lines = {}
    for i = from or 1, #m.output do
      local call = assert(load("return " .. m.output[i], "=output", "t", {}))()
      if call[2] == "write" or call[2] == "blit" then lines[#lines + 1] = tostring(call[3]) end
    end
    return table.concat(lines, "\n")
  end

  test("the stock board draws a no-map broadcast and keeps drawing", function()
    local m = mocks.new(false)
    local fn = assert(load(read("roomsorter.lua"), "=roomsorter.lua", "t", m.env))
    m.app = coroutine.create(function() fn("board") end)
    m.push()
    m.push("rednet_message", 12, { totals = {}, state = "No map yet" }, "roomsorter_stock")
    m.tick()
    local empty = screen(m)
    assert(empty:find("No map yet", 1, true), "board did not draw the no-map stock\n" .. empty)
    assert(empty:find("0 chests", 1, true), "board did not draw empty stock counts\n" .. empty)
    local mark = #m.output
    m.push("rednet_message", 12, {
      totals = { ["minecraft:cobblestone"] = 12 },
      used = 4, size = 10, chests = 2, furnaces = 1, state = "Idle",
    }, "roomsorter_stock")
    m.tick()
    local mapped = screen(m, mark + 1)
    assert(mapped:find("Cobblestone", 1, true), "board stopped drawing after the map\n" .. mapped)
    assert(mapped:find("Idle", 1, true), "board did not draw the mapped state\n" .. mapped)
    assert(coroutine.status(m.app) == "suspended", "board loop died")
  end)
end
