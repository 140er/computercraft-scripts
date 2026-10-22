local R = dofile("tests/ui/render.lua")
local function setup()
  local s = {now=0,finds=0}
  local env = setmetatable({}, {__index=_G})
  env.os = setmetatable({epoch=function() return s.now end,getComputerID=function() return 1 end},{__index=os})
  env.fs = {getCapacity=function() return 16000000 end,getFreeSpace=function() return 13900000 end}
  env.SO = {mods={},proto=dofile("so-proto.lua"),store={store=function()
    return {value={roles={}},save=function() error("local navigation saved") end}
  end},pair={key=function() error("local monitor used rednet") end}}
  env.peripheral = {find=function() s.finds=s.finds+1; return s.monitor end,getName=function() return "left" end}
  s.display=assert(loadfile("so-mod-display.lua","t",env))()
  s.env=env
  return s
end
local function capture(frame,w,h)
  local out=R.capture(w,h)
  for y,row in ipairs(frame.rows) do
    local fg,bg={},{}
    for _,run in ipairs(row.runs) do
      fg[#fg+1]=string.rep(run[2],run[1]);bg[#bg+1]=string.rep(run[3],run[1])
    end
    fg,bg=table.concat(fg),table.concat(bg)
    assert(#fg==w and #bg==w)
    out.setCursorPos(1,y);out.blit(row.text..string.rep(" ",w-#row.text),fg,bg)
  end
  return out
end
local function server()
  local s={now=0,invites=0,clears=0,draws=0}
  local env=setmetatable({}, {__index=_G})
  env.term=R.capture(51,19)
  env.print=function() error("server log escaped") end
  env.keys={p=25,l=38,escape=1,up=200,down=208}
  env.fs={getCapacity=function() return 16000000 end,exists=function() return true end,
    list=function() return {"so-mod-display.lua"} end}
  local pair={open=function() end,pending=function()
    if s.now >= (s.expires or 0) then s.code=nil end
    return s.code
  end,clear=function() s.clears=s.clears+1;s.code=nil end,
    invite=function() s.invites=s.invites+1;s.code=s.invites==1 and "482915" or "123456"
      s.expires=s.now+300000;env.print("pair invite");return s.code end}
  env.rednet={host=function() end}
  env.peripheral={find=function() end}
  env.os={clock=function() return s.now/1000 end,epoch=function() return s.now end,getComputerID=function() return 1 end,
    startTimer=function() return 99 end,pullEvent=function() return coroutine.yield() end}
  env.dofile=function(path)
    if path=="so-pair.lua" then return pair end
    if path=="so-proto.lua" then return {decode=function() end} end
    if path=="so-store.lua" then return {} end
    if path=="so-mod-display.lua" then
      return {name="display",handlers={},tick=function()
        s.view=env.SO.terminal;s.draws=s.draws+1
      end,monitorTouch=function() s.touched=true end}
    end
    error(path)
  end
  env.loadfile=function(path) return function() return env.dofile(path) end end
  s.thread=coroutine.create(assert(loadfile("so-server.lua","t",env)))
  function s.event(...)
    local ok,err=coroutine.resume(s.thread,...);assert(ok,err)
  end
  s.event()
  s.env=env
  return s
end
return function(test,equal)
  test("UI3a normal and pairing match unchanged fixtures",function()
    local d=setup().display
    assert(d.terminal,"terminal renderer missing")
    local m={tiles={},terminalSubs={"ok","fresh","2.1 MB","see log"}}
    for _,t in ipairs({{1,"TURTLES","3","d"},{7,"DISPLAYS","4","d"},
      {6,"DISK","13%","d"},{3,"ALERTS","1","e"}}) do
      m.tiles[t[1]]={label=t[2],value=t[3],bg=t[4]}
    end
    local v={id=1,mode="normal",uptime="up 3h12",log={
      "21:14:02 lease 2-961 reported ok","21:14:05 drops: hold ore (3)",
      "21:14:09 pair: display 7 joined","21:14:11 mine: #3 wait lane"}}
    local diff=R.diff("tests/ui/fixtures/server-T.txt",capture(d.terminal(m,v,51,19),51,19))
    assert(#diff==0,table.concat(diff,"\n"))
    v.mode,v.code,v.now,v.expires="code","482915",0,292000
    diff=R.diff("tests/ui/fixtures/pairing-T.txt",capture(d.terminal(m,v,51,19),51,19))
    assert(#diff==0,table.concat(diff,"\n"))
    for _,size in ipairs({{1,1},{15,10},{26,20},{39,19},{100,38}}) do
      for _,mode in ipairs({"normal","code","log"}) do
        v.mode=mode;capture(d.terminal(m,v,size[1],size[2]),size[1],size[2])
      end
    end
  end)
  test("UI3a keys, expiry, used codes, bounded log and timer-only redraw",function()
    local s=server();s.event("timer",99);equal(s.view.mode,"normal")
    s.event("key",25,false);equal(s.invites,1);equal(s.view.mode,"code")
    s.event("key",25,false);equal(s.invites,2);equal(s.view.code,"123456")
    s.event("key",1,false);equal(s.clears,1);equal(s.view.mode,"normal")
    s.event("key",25,false);s.now=300001;s.event("timer",99);equal(s.view.mode,"normal")
    s.event("key",25,false);s.code=nil;s.event("timer",99);equal(s.view.mode,"normal")
    s.event("key",38,false);equal(s.view.mode,"log")
    s.event("key",38,false);equal(s.view.mode,"normal")
    s.event("key",38,false);s.event("key",1,false);equal(s.view.mode,"normal")
    for i=1,230 do s.event("rednet_message",i,"bad","so") end
    equal(#s.view.log,200);equal(s.view.log[200],"so-server: bad message from 230")
    s.env.print(string.rep("x",4100).."\nlast",17)
    equal(#s.view.log,200);equal(#s.view.log[198],4096)
    equal(s.view.log[199],"xxxx");equal(s.view.log[200],"last\t17")
    local d=setup().display
    for _,mode in ipairs({"normal","log"}) do
      s.view.mode=mode
      local out=capture(d.terminal({tiles={}},s.view,51,19),51,19).picture()
      assert(table.concat(out.text,"\n"):find(s.view.log[200],1,true))
    end
    s.event("key",200,false);equal(s.view.offset,1)
    s.event("key",208,false);equal(s.view.offset,0)
    s.event("monitor_touch","left",2,3);assert(s.touched)
    equal(s.draws,3)
  end)
  test("UI3a display tick paints the terminal with uptime and palette",function()
    local s=setup()
    s.env.term=R.capture(51,19)
    s.env.SO.terminal={id=1,started=0,mode="normal",log={"retained server message"}}
    s.now=11520000;s.display.tick(s.now)
    local picture=s.env.term.picture()
    assert(picture.text[1]:find("up 3h12",1,true))
    assert(table.concat(picture.text,"\n"):find("retained server message",1,true))
    equal(s.env.term.palette[2^9][1],s.display.palette[9])
  end)
  test("UI3a monitor discovers at most every five seconds and navigates locally",function()
    local s=setup()
    s.display.tick(0);equal(s.finds,1)
    s.monitor=R.capture(57,24)
    s.monitor.setTextScale=function(scale) equal(scale,0.5) end
    s.now=4999;s.display.tick(s.now);equal(s.finds,1)
    s.now=5000;s.display.tick(s.now);equal(s.finds,2)
    assert(s.monitor.picture().text[1]:find("STATUS",1,true))
    local U=dofile("so-ui.lua")
    local mining
    local tiles={}
    for i=1,9 do tiles[i]={label="T",value="0",sub="",bg="d"} end
    for _,b in ipairs(U.status({time="",tiles=tiles},57,24).buttons) do
      if b.id=="mining" then mining=b end
    end
    assert(mining)
    local inputs=0
    s.display.screen("mining",function(w,h)
      equal(w,57);equal(h,24)
      local c=U.canvas(w,h);c.header("MINING");c.button(1,h-2,10,"BACK","status")
      return c.frame()
    end,function() inputs=inputs+1 end)
    s.display.monitorTouch("right",mining.x,mining.y)
    s.now=5500;s.display.tick(s.now)
    assert(s.monitor.picture().text[1]:find("STATUS",1,true))
    s.display.monitorTouch("left",mining.x,mining.y)
    assert(s.monitor.picture().text[1]:find("STATUS",1,true))
    s.now=6000;s.display.tick(s.now)
    assert(s.monitor.picture().text[1]:find("MINING",1,true))
    s.display.monitorTouch("left",1,22);s.now=7000;s.display.tick(s.now)
    assert(s.monitor.picture().text[1]:find("STATUS",1,true));equal(inputs,1)
    s.monitor=nil;s.now=10000;s.display.tick(s.now)
  end)
end
