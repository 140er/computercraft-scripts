return function(test,read,mocks)
  local source=read("miner.lua")
  test("miner navigation journals veins and recall cannot dig a changed tunnel",function()
    local m=mocks.miner({home={x=0,y=65,z=0},facing=1,spine=2,ssot={server=0,dimension="minecraft:overworld"}})
    m.env.dofile=function(path) return assert(loadfile(path,"t",m.env))() end
    local code=assert(source:match("^(.*)\nopenModem%(%)"))
    local api=assert(load(code .. "\nreturn {C=C,move=move,face=face,home=goHome,pos=pos,st=st,listener=listener,heartbeat=heartbeat}","=miner.lua","t",m.env))()
    local dim="minecraft:overworld"
    api.C.nav=m.env.dofile("nav.lua").open({pose={dim=dim,x=0,y=65,z=0,h=1},
      bounds={min={dim=dim,x=-5,y=60,z=-5},max={dim=dim,x=5,y=70,z=5}},
      canExcavate=api.C.navCanExcavate,observe=function() return {dim=dim,x=m.pos.x,y=m.pos.y,z=m.pos.z} end,
      client={resync=function() return true end,calibrate=function() return true end,move=function(_,_,execute) return execute() end}})
    api.C.ssot={}
    assert(api.C.nav.recover())
    m.world["1,65,0"]="minecraft:diamond_ore"
    assert(api.move(1,true))
    assert(m.dug[1].name=="minecraft:diamond_ore")
    assert(api.C.navCanExcavate({name="minecraft:gravel"}))
    assert(not api.C.navCanExcavate({name="minecraft:chest"}))
    assert(api.st.vein[1]==1 and api.st.navPending==nil and api.pos.x==1)
    m.world["0,65,0"]="minecraft:stone"
    local ok,why=pcall(api.home,"recall")
    assert(not ok and tostring(why):find("Safe return refused",1,true))
    assert(#m.dug==1 and api.pos.x==1 and api.st.phase=="returning")
    api.C.nav.stop()
    assert(not pcall(api.face,0))
    assert(m.heading==api.st.h)
    api.C.estop=true
    m.env.sleep=function() api.C.estop=false assert(api.C.nav.resume()) end
    api.face(0)
    assert(m.heading==0 and api.st.h==0)
    m.app=coroutine.create(api.listener) m.push()
    m.push("rednet_message",0,{type="estop",commandEpoch="1",cid=2},"minearmy")
    assert(api.C.estop and api.C.nav.stopped())
    m.push("rednet_message",0,{type="go",commandEpoch="1",cid=1},"minearmy")
    assert(api.C.estop and api.C.nav.stopped())
    m.push("rednet_message",0,{type="go",commandEpoch="1",cid=3},"minearmy")
    assert(not api.C.estop and not api.C.nav.stopped())
    m.env.sleep=function() coroutine.yield() end
    local beat=coroutine.create(api.heartbeat)
    assert(coroutine.resume(beat)) assert(coroutine.resume(beat))
    assert(not api.C.estop and not api.C.nav.stopped())
  end)
  test("navigation bounds can be configured from the turtle command",function()
    local m=mocks.miner({home={x=0,y=65,z=0},facing=1,spine=2})
    assert(load(source,"=miner.lua","t",m.env))("nav","bounds","minecraft:overworld","-8","60","-9","8","70","9")
    local cfg=m.env.textutils.unserialize(m.files["miner.cfg"])
    assert(cfg.nav.bounds.min.x==-8 and cfg.nav.bounds.max.z==9 and not cfg.nav.enabled)
  end)
  test("a survey command requires navigation and preserves its world target",function()
    local m=mocks.miner({home={x=0,y=65,z=0},facing=1,spine=2,
      ssot={enabled=true,server=0,secret="test-secret-123456",dimension="minecraft:overworld"},nav={enabled=true}})
    m.env.dofile=function(path) return assert(loadfile(path,"t",m.env))() end
    local code=assert(source:match("^(.*)\nopenModem%(%)"))
    local api=assert(load(code.."\nreturn C","=miner.lua","t",m.env))("nav","survey","3","65","-2")
    assert(api.navSurvey.x==3 and api.navSurvey.z==-2 and api.navSurvey.dim=="minecraft:overworld")
  end)
  test("navigation boot retries only a missing GPS fix",function()
    local m=mocks.miner({home={x=0,y=65,z=0},facing=1,spine=2})
    local code=assert(source:match("^(.*)\nopenModem%(%)"))
    local api=assert(load(code.."\nreturn C","=miner.lua","t",m.env))()
    local calls,sleeps=0,0
    m.env.sleep=function() sleeps=sleeps+1 end
    local answers={
      {nil,"GPS unavailable or wrong dimension"},
      {nil,"GPS unavailable or wrong dimension"},
      {true},
    }
    api.nav={recover=function()
      calls=calls+1
      local answer=answers[calls]
      return answer[1],answer[2]
    end}
    local ok,why=api.bootNavigation()
    assert(ok and why==nil and calls==3 and sleeps==2,"GPS boot did not retry the missing fix")
    local slept=sleeps
    calls=0
    api.nav.recover=function() calls=calls+1 return nil,"relocated" end
    ok,why=api.bootNavigation()
    assert(not ok and why=="relocated" and calls==1 and sleeps==slept,"a non-GPS failure must return immediately")
  end)
end
