return function(test)
  test("P0 measurement distinguishes errors and counts coroutine suspensions", function()
    local now = 1000
    local events = {{"ignored"}, {"timer", 7}}
    local env = setmetatable({os = {
      epoch = function() return now end,
      pullEventRaw = function()
        local event = table.remove(events, 1)
        assert(event, "measurement consumed an extra event")
        now = now + 20
        return table.unpack(event)
      end,
    }}, {__index = _G})
    local P = assert(loadfile("tests/bench/probe.lua", "t", env))()
    local row = P.measure(function()
      now = now + 15
      local event, id = coroutine.yield("timer")
      assert(event == "timer" and id == 7)
      now = now + 30
      return "checked output"
    end)
    assert(row.ok and row.value == "checked output")
    assert(row.yields == 1 and row.longestSliceMs == 30 and row.elapsedMs == 85)
    local failed = P.measure(function() error("known failure") end)
    assert(not failed.ok and failed.error:find("known failure", 1, true) and failed.value == false)
    local timed = P.measure(function() now = now + 7000 end)
    assert(timed.ok and not timed.belowTimeout)
    assert(P.hex(P.unhex("00abff")) == "00abff")
    assert(not pcall(P.unhex, "xyz"))
  end)
end
