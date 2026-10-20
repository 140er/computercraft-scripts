local Mocks=dofile("tests/mocks.lua")
local function fixture(ready,program)
  local m=Mocks.new(false)
  local env=m.env
  local client,child
  local settings={enabled=true,sorting=true,autoCharge=true,autoDropoff=true}
  local physical=0
  env.turtle={drop=function() physical=physical+1 return true end,refuel=function() physical=physical+1 return true end}
  env.turtle.getItemCount=function() return 0 end
  env.turtle.getFuelLevel=function() return 500 end
  env.turtle.getFuelLimit=function() return 20000 end
  env.os.pullEventRaw=env.os.pullEvent
  env.sleep=function() env.os.pullEvent("timer") end
  env.gps=nil
  env.loadfile=function(_,_,environment)
    child=environment
    return function() return program(environment) end
  end
  env.dofile=function(path)
    if path=="atomic.lua" then return {read=function() return {enabled=true,server=0,dimension="minecraft:overworld"} end} end
    if path=="ssot-client.lua" then return {new=function() return {boot="test"} end} end
    if path=="wh2-client.lua" then return {new=function(options)
      client={tick=function() return true end,ready=function() return ready end,
        status=function() return {detail="Server unavailable"} end,settings=function() return settings end,
        dispatch=function() return false end,snapshot=options.snapshot}
      return client
    end} end
    error(path)
  end
  local module=assert(loadfile("wh2-program.lua","t",env))()
  local co=coroutine.create(function() assert(module.run("sorter.lua")) end)
  local function step(...)
    local ok,err=coroutine.resume(co,...)
    assert(ok,err)
  end
  step()
  local function flush()
    local limit=30
    while coroutine.status(co)~="dead" and #m.queued>0 do
      limit=limit-1 assert(limit>0,"event loop did not settle")
      local event=table.remove(m.queued,1)
      step(table.unpack(event,1,event.n))
    end
  end
  return {m=m,settings=settings,flush=flush,step=step,co=co,client=function() return client end,
    count=function() return physical end,child=function() return child end}
end

local m=fixture(false,function(env) assert(env.turtle.drop()) end)
m.flush()
assert(coroutine.status(m.co)=="dead" and m.count()==1)
assert(table.concat(m.m.output," "):find("Standalone mode",1,true))

m=fixture(true,function(env) assert(env.turtle.drop()) end)
m.settings.enabled=false
m.flush()
assert(m.count()==0 and coroutine.status(m.co)~="dead")
m.settings.enabled=true
m.step("wh2_settings")
assert(m.count()==1 and coroutine.status(m.co)=="dead")
assert(m.client().snapshot().v==1 and m.client().snapshot().currentJob==false)

m=fixture(true,function(env)
  assert(env.turtle.refuel(0))
  local ok,why=env.turtle.refuel(1)
  assert(not ok and why=="auto-charge disabled")
end)
m.settings.autoCharge=false
m.flush()
assert(m.count()==1)
print("PASS fleet programs start standalone and enforce live controls before native calls")
