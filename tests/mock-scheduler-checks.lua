return function(test, equal, mocks)
  test("mock scheduler runs concurrent sleeps without starving slower loops", function()
    local m=mocks.new(false)
    m.start([[
      counts={fast=0,slow=0,zero=0}
      parallel.waitForAny(
        function() while true do sleep(.25) counts.fast=counts.fast+1 end end,
        function() while true do sleep(1) counts.slow=counts.slow+1 end end,
        function() while true do sleep(0) counts.zero=counts.zero+1 end end)
    ]])
    m.tick()
    equal(m.env.counts,{fast=4,slow=1,zero=20})
    m.tick()
    equal(m.env.counts,{fast=8,slow=2,zero=40})
  end)
  test("mock scheduler cancels timers and preserves independent event filters", function()
    local m=mocks.new(false)
    m.start([[
      observed={}
      parallel.waitForAny(
        function()
          sleep(.5)
          observed.woke=os.clock()
          while true do os.pullEvent("keep_alive") end
        end,
        function()
          local cancelled=os.startTimer(.1)
          os.cancelTimer(cancelled)
          local witness=os.startTimer(.25)
          while true do
            local event,id=os.pullEvent()
            if event=="timer" then
              assert(id~=cancelled,"cancelled timer fired")
              if id==witness then observed.witness=os.clock() end
            elseif event=="message" then observed.message=id end
          end
        end)
    ]])
    m.push("message","delivered while sleeping")
    m.tick()
    equal(m.env.observed,{woke=.5,witness=.25,message="delivered while sleeping"})
  end)
end
