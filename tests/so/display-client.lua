local H = dofile("tests/so/harness.lua")
local function install(m, server)
  m.install(server and {"so-server.lua","so-proto.lua","so-pair.lua","so-store.lua","so-mod-display.lua"}
    or {"display.lua","so-proto.lua","so-pair.lua","so-store.lua"})
  for _,name in ipairs({"x25519","random","blake3","chacha20","config","internal/util",
    "internal/hw","internal/curve25519","internal/fp","internal/edwards25519","internal/packing"}) do
    local path="lib/ccryptolib/"..name..".lua"
    local f=assert(io.open(path)); m.files[path]=f:read("*a"); f:close()
  end
  if server then m.files["so-server.cfg"]=H.encode({pos={dim="minecraft:overworld",x=0,y=0,z=0}}) end
end
local function grid(w,h)
  local rows,x,y={},1,1
  local g={getSize=function() return w,h end,isColor=function() return false end}
  g.clear=function() rows={} end
  g.setCursorPos=function(a,b) x,y=a,b end
  g.write=function(s)
    assert(y>=1 and y<=h and x>=1 and x+#s-1<=w,"draw outside screen")
    local row=rows[y] or string.rep(" ",w)
    rows[y]=row:sub(1,x-1)..s..row:sub(x+#s); x=x+#s
  end
  g.line=function(n) return rows[n] or string.rep(" ",w) end
  g.text=function() local a={} for n=1,h do a[n]=g.line(n) end return table.concat(a,"\n") end
  return g
end
local function setup(w,h,wall,absent,cfg)
  local n=H.new()
  local s=n.machine({id=1,modem=true}); install(s,true)
  if not absent then s.boot("so-server.lua"); n.flush() end
  local c=n.machine({id=2,modem=true,capacity=1000000}); install(c)
  if cfg then c.files["so-display.cfg"]=H.encode(cfg) end
  local face=grid(w,h); local own=wall and grid(51,19) or face
  c.env.term=own
  local pull=c.env.os.pullEvent
  c.env.os.pullEvent=function(...)
    local ev=table.pack(pull(...))
    if ev[1]=="modem_message" then
      local packet=ev[5]
      c.env.os.queueEvent("rednet_message",packet.nSender,packet.message,packet.sProtocol)
    end
    return table.unpack(ev,1,ev.n)
  end
  local send=s.env.rednet.send
  s.env.rednet.send=function(id,payload,protocol)
    if id~=c.id then return send(id,payload,protocol) end
    s.sent[#s.sent+1]={id=id,payload=payload,protocol=protocol}
    c.env.os.queueEvent("modem_message","back",c.id,s.id,
      {nRecipient=c.id,nSender=s.id,message=payload,sProtocol=protocol},1)
    return true
  end
  local find=c.env.peripheral.find
  c.env.peripheral.find=function(kind) if kind=="monitor" and wall then return face end return find(kind) end
  local lookups=0
  local lookup=c.env.rednet.lookup
  c.env.rednet.lookup=function(...)
    lookups=lookups+1
    return lookup(...)
  end
  c.boot("display.lua"); n.flush()
  return {n=n,s=s,c=c,face=face,own=own,w=w,h=h,lookups=function() return lookups end}
end
local function event(t,...)
  t.c.env.os.queueEvent(...); t.n.flush(); assert(t.c.alive(),tostring(t.c.error))
end
local function typeText(t,s) for ch in s:gmatch(".") do event(t,"char",ch) end end
local function code(t)
  t.s.env.os.queueEvent("key",25,false); t.n.flush()
  for i=#t.s.log,1,-1 do local c=t.s.log[i]:match("Pair code: (%d+)") if c then return c end end
  error("no invitation")
end
local function pair(t) typeText(t,code(t)); t.n.advance(1); assert(t.c.files["so-keys"],"not paired") end
local function last(t,kind)
  for i=#t.c.sent,1,-1 do local p=t.c.sent[i].payload if p.t==kind then return p end end
end
return function(test,equal)
  for _, size in ipairs({{26,20,false},{29,12,true}}) do
    test("display re-pairs after server key loss " .. size[1] .. "x" .. size[2], function()
      local t = setup(size[1], size[2], size[3]); pair(t)
      local old = t.c.files["so-keys"]
      t.s.env.os.queueEvent("terminate"); t.n.flush()
      t.s.co, t.s.inbox, t.s.timers = nil, {}, {}
      for path in pairs(t.s.files) do
        if path:match("^so%-keys") then t.s.files[path] = nil end
      end
      t.s.boot("so-server.lua"); t.n.flush(); t.n.advance(45)
      assert(t.face.text():find("Old key kept", 1, true), t.face.text())
      assert(t.own.text():find("Old key kept", 1, true), t.own.text())
      assert(t.face.text():find("Code:", 1, true), t.face.text())
      equal(t.c.files["so-keys"], old)
      typeText(t, "000000"); t.n.advance(15)
      equal(t.c.files["so-keys"], old, "failed pairing replaced key")
      assert(t.face.text():find("Code:", 1, true), t.face.text())
      typeText(t, code(t)); t.n.advance(2)
      assert(t.c.files["so-keys"] ~= old, "new pairing did not replace key")
      assert(not t.face.text():find("Old key kept", 1, true), t.face.text())
      assert(last(t, "view.sub"))
    end)
  end
  test("forged display repair hint keeps valid key and authenticated frames recover", function()
    local t = setup(26,20,false); pair(t)
    local old = t.c.files["so-keys"]
    event(t, "rednet_message", 77, {t="pair.required",from=77}, "so")
    assert(not t.face.text():find("Old key kept", 1, true))
    event(t, "rednet_message", 1, {t="pair.required",from=1}, "so")
    assert(t.face.text():find("Old key kept", 1, true))
    equal(t.c.files["so-keys"], old)
    t.n.advance(5)
    equal(t.c.files["so-keys"], old)
    assert(not t.face.text():find("Old key kept", 1, true), t.face.text())
  end)
  test("display wrong code then right code without reboot",function()
    local t=setup(29,12,true)
    assert(t.face.text():find("Code:",1,true),t.face.text())
    assert(t.own.text():find("Code:",1,true),t.own.text())
    event(t,"char","0"); event(t,"char","2"); event(t,"key",259)
    local lookups=t.lookups()
    t.n.advance(2)
    equal(t.lookups(),lookups,"discovery interrupted code entry")
    assert(t.face.text():find("Code: 0",1,true)); event(t,"key",259)
    local good=code(t); local bad=good=="000000" and "111111" or "000000"
    typeText(t,bad); t.n.advance(15)
    assert(not t.c.files["so-keys"],"wrong code saved")
    assert(t.face.text():find("failed",1,true) or t.face.text():find("timeout",1,true),t.face.text())
    typeText(t,code(t)); t.n.advance(1)
    assert(t.c.files["so-keys"],"retry did not pair")
    assert(last(t,"view.sub"),"did not subscribe")
  end)
  test("display discovers a server that starts after boot",function()
    local t=setup(26,20,false,true)
    t.n.advance(65)
    assert(t.lookups()>1 and t.lookups()<12,"discovery did not back off")
    assert(t.c.alive(),tostring(t.c.error))
    t.s.boot("so-server.lua"); t.n.flush(); t.n.advance(31)
    pair(t)
    assert(last(t,"hello")); assert(last(t,"view.sub"))
  end)
  test("paired display boots before server and recovers after restart",function()
    local t=setup(26,20,false); pair(t)
    local co=t.c.co
    t.s.env.os.queueEvent("terminate"); t.n.flush()
    t.n.advance(45)
    t.s.co,t.s.inbox,t.s.timers=nil,{},{}
    t.s.boot("so-server.lua"); t.n.flush(); t.n.advance(31)
    equal(t.c.co,co)
    assert(not t.face.text():find("NO SERVER",1,true),t.face.text())
    t.s.env.os.queueEvent("terminate"); t.n.flush(); t.n.hosts.so=nil
    t.c.co,t.c.inbox,t.c.timers=nil,{},{}
    t.c.boot("display.lua"); t.n.advance(40)
    t.s.co,t.s.inbox,t.s.timers=nil,{},{}
    t.s.boot("so-server.lua"); t.n.flush(); t.n.advance(31)
    assert(not t.face.text():find("NO SERVER",1,true),t.face.text())
    assert(t.c.alive(),tostring(t.c.error))
  end)
  test("display clears a no-server code and accepts another after discovery",function()
    local t=setup(29,12,true,true)
    typeText(t,"012345")
    assert(t.face.text():find("no server",1,true),t.face.text())
    assert(not t.c.files["so-keys"])
    t.s.boot("so-server.lua"); t.n.flush(); t.n.advance(31)
    pair(t)
    assert(last(t,"view.sub"))
  end)
  test("display clears a timed-out code and accepts a new invitation",function()
    local t=setup(26,20,false)
    local send=t.s.env.rednet.send
    t.s.env.rednet.send=function() return true end
    typeText(t,code(t)); t.n.advance(15)
    assert(t.face.text():find("timeout",1,true),t.face.text())
    assert(not t.c.files["so-keys"])
    t.s.env.rednet.send=send
    pair(t)
    assert(last(t,"view.sub"))
  end)
  for _,size in ipairs({{26,20,false},{29,12,true}}) do
    test("display echoes commands without covering buttons "..size[1].."x"..size[2],function()
      local t=setup(size[1],size[2],size[3])
      local received={}
      t.s.env.SO.mods.display.screen("generic",function()
        return {rows={{text="Commands"}},buttons={
          {id="go",label="go",x=1,y=size[2]-3,w=2}}}
      end,function(e) received[#received+1]=e end)
      pair(t)
      assert(t.s.env.SO.mods.display.command(t.c.id.." drops")) t.n.advance(1)
      equal(last(t,"hello").body.h,size[2]-1)
      for _,text in ipairs({"home 1 64 2 n","area 0 0 8 8 63","diamond"}) do
        typeText(t,text.."x"); event(t,"key",259)
        equal(t.face.line(size[2]):sub(1,#text+2),"> "..text)
        local _,ownH=t.own.getSize()
        equal(t.own.line(ownH):sub(1,#text+2),"> "..text)
        t.n.advance(2)
        equal(t.face.line(size[2]):sub(1,#text+2),"> "..text)
        equal(t.face.line(size[2]-3):sub(1,2),"go")
        event(t,"key",257)
        equal(last(t,"input").body.text,text)
        equal(t.face.line(size[2]):sub(1,3),">  ")
        equal(t.own.line(ownH):sub(1,3),">  ")
      end
      typeText(t,string.rep("a",64)); event(t,"char","b")
      equal(t.face.line(size[2]),"> "..string.rep("a",size[1]-2))
      local y,x
      for row=1,size[2]-1 do
        local at=t.face.line(row):find("go",1,true)
        if at then x,y=at,row break end
      end
      assert(x and y,"no drawn button")
      event(t,size[3] and "monitor_touch" or "mouse_click",size[3] and "right" or 1,x,y)
      equal(received[#received].id,"go")
      equal(t.face.line(size[2]):sub(1,3),">  ")
    end)
  end
  test("pairing screen fits a 26x20 pocket with no helper line",function()
    local t=setup(26,20,false)
    assert(not t.face.text():find("press P",1,true),t.face.text())
    equal(t.face.line(1):match("^(.-)%s*$"),"Pair a new client")
    assert(t.face.line(3):find("%S"),t.face.text())
    local row
    for n=1,20 do if t.face.line(n):find("^Code:") then row=n end end
    assert(row==3 or row==4,t.face.text())
  end)
  test("display keeps a wrong code so Backspace fixes one digit",function()
    local t=setup(26,20,false)
    local good=code(t)
    local bad=good:sub(1,5)..tostring((tonumber(good:sub(6))+1)%10)
    typeText(t,bad); t.n.advance(15)
    assert(not t.c.files["so-keys"],"wrong code saved")
    assert(t.face.text():find("Code: "..bad,1,true),t.face.text())
    event(t,"key",259)
    equal(t.face.text():match("Code: (%d*)"),bad:sub(1,5))
    event(t,"char",good:sub(6)); t.n.advance(1)
    assert(t.c.files["so-keys"],"corrected code did not pair")
    assert(last(t,"view.sub"))
  end)
  test("display draws the next frame on the terminal after its monitor is removed",function()
    local t=setup(29,12,true); pair(t); t.n.advance(2)
    assert(t.face.text():find("display 2",1,true),t.face.text())
    local find=t.c.env.peripheral.find
    t.c.env.peripheral.find=function(kind) if kind~="monitor" then return find(kind) end end
    local gone=function() error("monitor detached") end
    t.face.clear,t.face.setCursorPos,t.face.write,t.face.getSize=gone,gone,gone,gone
    event(t,"peripheral_detach","top"); t.n.advance(3)
    assert(t.c.alive(),tostring(t.c.error))
    equal(last(t,"hello").body.w,51)
    assert(t.own.text():find("display 2",1,true),t.own.text())
  end)
  test("display uses a monitor attached while it runs",function()
    local t=setup(26,20,false); pair(t); t.n.advance(2)
    local mon=grid(29,12)
    local find=t.c.env.peripheral.find
    t.c.env.peripheral.find=function(kind) if kind=="monitor" then return mon end return find(kind) end
    event(t,"peripheral","top"); t.n.advance(3)
    equal(last(t,"hello").body.w,29)
    assert(mon.text():find("display 2",1,true),mon.text())
  end)
  test("display echoes the typed line on a kit frame",function()
    local t=setup(26,20,false)
    local rows={}
    for n=1,20 do rows[n]={text="kit row "..n} end
    t.s.env.SO.mods.display.screen("generic",function()
      return {rows=rows,buttons={},palette={[0]=0x101010,0xFFFFFF}}
    end,function() end)
    pair(t)
    assert(t.s.env.SO.mods.display.command(t.c.id.." drops")) t.n.advance(2)
    -- Without so-ui the server fits 19 rows, so the kit frame leaves row 20 blank.
    equal(t.face.line(19):sub(1,11),"kit row 19 ")
    equal(t.face.line(20),string.rep(" ",26))
    typeText(t,"scan 3")
    equal(t.face.line(20):sub(1,9),"> scan 3 ")
    t.n.advance(2)
    equal(t.face.line(20):sub(1,9),"> scan 3 ")
    event(t,"key",257)
    equal(last(t,"input").body.text,"scan 3")
    equal(t.face.line(20),string.rep(" ",26))
  end)

  -- Sends hello/view.sub with their game time, so tests can check the retry spacing.
  local function stamp(t)
    local log,send={},t.c.env.rednet.send
    t.c.env.rednet.send=function(id,payload,protocol)
      if type(payload)=="table" then log[#log+1]={t=payload.t,id=id,at=t.n.time} end
      return send(id,payload,protocol)
    end
    return log
  end
  local function count(log,kind) local n=0 for _,e in ipairs(log) do if e.t==kind then n=n+1 end end return n end
  local function stale(t)
    t.s.env.os.queueEvent("terminate"); t.n.flush()
    for _=1,400 do
      if t.face.text():find("NO SERVER",1,true) then return end
      t.n.advance(0.05)
    end
    error("never stale: "..t.face.text())
  end
  test("retryInput: a key in NO SERVER sends one hello at once, two seconds apart with timers",function()
    local t=setup(29,12,true,false,{retryInput=true}); pair(t); t.n.advance(3)
    stale(t)
    local log=stamp(t)
    event(t,"key",57)
    equal(count(log,"hello"),1,"key did not retry at once")
    equal(count(log,"view.sub"),1)
    for _,e in ipairs({{"char","a"},{"key",28},{"monitor_touch","right",3,3},{"mouse_click",1,3,3}}) do
      event(t,table.unpack(e))
    end
    equal(count(log,"hello"),1,"repeated input queued a retry")
    t.n.advance(1.9)
    event(t,"key",57)
    equal(count(log,"hello"),1,"timer or input broke the 2 s limit")
    t.n.advance(60)
    for _=1,40 do event(t,"monitor_touch","right",2,2); t.n.advance(0.25) end
    assert(count(log,"hello")>=2,"no later retries")
    equal(count(log,"hello"),count(log,"view.sub"))
    local prev
    for _,e in ipairs(log) do
      if e.t=="hello" then
        if prev then assert(e.at-prev>=2000,"hellos "..(e.at-prev).." ms apart") end
        prev=e.at
      end
    end
  end)
  for _,cfg in ipairs({false,{},{retryInput=false}}) do
    test("retryInput off ("..(cfg and "key "..tostring(cfg.retryInput) or "no file").."): input in NO SERVER waits for the timer",function()
      local t=setup(26,20,false,false,cfg or nil); pair(t); t.n.advance(3)
      stale(t)
      local log=stamp(t)
      event(t,"key",57); event(t,"char","a"); event(t,"mouse_click",1,2,2)
      equal(count(log,"hello"),0,"input retried with the flag off")
      t.n.advance(1.1)
      equal(count(log,"hello"),1,"timed retry changed")
    end)
  end
  test("monitor_touch cannot change the server or keys in NO SERVER or pairing",function()
    local t=setup(29,12,true,false,{retryInput=true}); pair(t); t.n.advance(3)
    local old=t.c.files["so-keys"]
    t.c.env.rednet.lookup=function() return 77 end
    stale(t)
    local log=stamp(t)
    local function taps()
      for y=1,12 do for x=1,29,4 do event(t,"monitor_touch","right",x,y) end t.n.advance(0.3) end
    end
    taps()
    event(t,"rednet_message",1,{t="pair.required",from=1},"so")
    assert(t.face.text():find("Old key kept",1,true),t.face.text())
    taps()
    t.n.advance(40); taps()
    equal(t.c.files["so-keys"],old)
    assert(count(log,"hello")>0)
    for _,e in ipairs(log) do equal(e.id,1,"sent to another server") end
    assert(not t.face.text():find("Code: %d"),t.face.text())
  end)
  test("Up and Down recall sent lines",function()
    local t=setup(26,20,false)
    t.s.env.SO.mods.display.screen("generic",function() return {rows={{text="Commands"}},buttons={}} end,function() end)
    pair(t)
    assert(t.s.env.SO.mods.display.command(t.c.id.." drops")) t.n.advance(1)
    for _,line in ipairs({"scan 1","scan 2","scan 3"}) do typeText(t,line); event(t,"key",257) end
    event(t,"key",265)
    equal(t.face.line(20):sub(1,9),"> scan 3 ")
    event(t,"key",265); event(t,"key",265); event(t,"key",265)
    equal(t.face.line(20):sub(1,9),"> scan 1 ")
    event(t,"key",264)
    equal(t.face.line(20):sub(1,9),"> scan 2 ")
    event(t,"key",264); event(t,"key",264)
    equal(t.face.line(20):sub(1,3),">  ")
    event(t,"key",264)
    equal(t.face.line(20):sub(1,3),">  ")
    event(t,"key",265); event(t,"key",257)
    equal(last(t,"input").body.text,"scan 3")
    for n=1,25 do typeText(t,"x"..n); event(t,"key",257) end
    for _=1,30 do event(t,"key",265) end
    equal(t.face.line(20):sub(1,6),"> x6  ")
  end)
  test("pasted six digits start one pairing",function()
    local t=setup(26,20,false)
    local log=stamp(t)
    event(t,"paste"," "..code(t).." "); t.n.advance(1)
    assert(t.c.files["so-keys"],"paste did not pair")
    equal(count(log,"pair2"),2,"not one pair2 exchange")
    assert(last(t,"view.sub"))
  end)
  test("paste ignores text and over-long codes while pairing",function()
    local t=setup(26,20,false)
    event(t,"paste","hello"); event(t,"paste","1234567")
    equal(t.face.text():match("Code: (%d*)"),"")
    event(t,"paste","12"); event(t,"char","3")
    equal(t.face.text():match("Code: (%d*)"),"123")
  end)
  test("pasted command text is sent on Enter",function()
    local t=setup(26,20,false)
    t.s.env.SO.mods.display.screen("generic",function() return {rows={{text="Commands"}},buttons={}} end,function() end)
    pair(t)
    assert(t.s.env.SO.mods.display.command(t.c.id.." drops")) t.n.advance(1)
    local before=last(t,"input")
    event(t,"paste","scan 3")
    equal(last(t,"input"),before,"paste sent before Enter")
    equal(t.face.line(20):sub(1,9),"> scan 3 ")
    event(t,"paste",string.rep("z",80))
    event(t,"key",257)
    equal(last(t,"input").body.text,"scan 3"..string.rep("z",58))
  end)
end
