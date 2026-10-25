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
local function setup(w,h,wall,absent,cfg,server,prep)
  local n=H.new()
  local s=n.machine({id=1,modem=true}); install(s,true)
  if server then s.files["so-server.cfg"]=H.encode(server) end
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
  if prep then prep(c,s) end
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
  test("retryInput: a repair hint between an input retry and its timer keeps the 2 s limit",function()
    local t=setup(29,12,true,false,{retryInput=true}); pair(t); t.n.advance(3)
    stale(t)
    local log=stamp(t)
    event(t,"key",57)
    equal(count(log,"hello"),1,"key did not retry at once")
    event(t,"rednet_message",1,{t="pair.required",from=1},"so")
    assert(t.face.text():find("Old key kept",1,true),t.face.text())
    t.n.advance(1.95)
    equal(count(log,"hello"),1,"pairing timer broke the 2 s limit")
    t.n.advance(30)
    assert(count(log,"hello")>=2,"no retry after the limit")
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

  -- B1-U: REPAIR after a server replacement (repairServer in so-display.cfg).
  local function boxKeys(t)
    local raw=t.c.files["so-keys"]
    local box=raw and t.c.env.textutils.unserialize(raw)
    local ids={}
    for id in pairs(box and box.value and box.value.keys or {}) do ids[#ids+1]=tonumber(id) end
    table.sort(ids)
    return table.concat(ids,",")
  end
  -- The old server is gone (stale(t) stopped it); a new one starts with this id.
  local function replace(t,id)
    t.n.hosts.so=nil
    if id==t.s.id then
      t.s.co,t.s.inbox,t.s.timers=nil,{},{}
      for path in pairs(t.s.files) do if path:match("^so%-keys") then t.s.files[path]=nil end end
      t.s.boot("so-server.lua"); t.n.flush()
      return t.s
    end
    local s=t.n.machine({id=id,modem=true}); install(s,true)
    local send=s.env.rednet.send
    s.env.rednet.send=function(to,payload,protocol)
      if to~=t.c.id then return send(to,payload,protocol) end
      s.sent[#s.sent+1]={id=to,payload=payload,protocol=protocol}
      t.c.env.os.queueEvent("modem_message","back",t.c.id,s.id,
        {nRecipient=t.c.id,nSender=s.id,message=payload,sProtocol=protocol},1)
      return true
    end
    s.boot("so-server.lua"); t.n.flush()
    return s
  end
  local function codeOn(t,s)
    s.env.os.queueEvent("key",25,false); t.n.flush()
    for i=#s.log,1,-1 do local c=s.log[i]:match("Pair code: (%d+)") if c then return c end end
    error("no invitation")
  end
  local function shows(g,text) return g.text():find(text,1,true)~=nil end
  local function sentTo(log,kind)
    local ids={}
    for _,e in ipairs(log) do if e.t==kind then ids[e.id]=true end end
    return ids
  end
  local function reboot(t)
    t.c.co,t.c.inbox,t.c.timers=nil,{},{}
    t.c.boot("display.lua"); t.n.flush()
  end

  test("repair: terminal changes a wall display to a new server id, and it survives a reboot",function()
    local cfg={repairServer=true,retryInput=true,keep="me"}
    local t=setup(29,12,true,false,cfg); pair(t); t.n.advance(3)
    stale(t); local s=replace(t,3)
    event(t,"char","r")
    assert(shows(t.own,"REPAIR") and shows(t.own,"Server 1"),t.own.text())
    assert(shows(t.face,"REPAIR"),t.face.text())
    event(t,"key",257); assert(shows(t.own,"Leave server 1?"),t.own.text())
    event(t,"key",257); assert(shows(t.own,"New server: 3"),t.own.text())
    event(t,"key",257); assert(shows(t.own,"Code:"),t.own.text())
    local log=stamp(t)
    typeText(t,codeOn(t,s)); t.n.advance(3)
    equal(boxKeys(t),"3")
    assert(shows(t.face,"display 2"),t.face.text())
    assert(sentTo(log,"hello")[3] and not sentTo(log,"hello")[1])
    equal(t.c.files["so-display.cfg"],H.encode(cfg),"repair changed so-display.cfg")
    log=stamp(t); reboot(t); t.n.advance(3)
    assert(sentTo(log,"hello")[3] and not sentTo(log,"hello")[1],"reboot did not use the new key")
    assert(shows(t.face,"display 2"),t.face.text())
  end)

  test("repair: a pocket re-pairs the same server id from its own screen",function()
    local t=setup(26,20,false,false,{repairServer=true}); pair(t); t.n.advance(3)
    local old=t.c.files["so-keys"]
    stale(t); replace(t,1); t.n.advance(15)
    event(t,"mouse_click",1,3,1)
    assert(shows(t.face,"REPAIR") and shows(t.face,"Server 1"),t.face.text())
    event(t,"key",257); event(t,"key",257)
    assert(shows(t.face,"New server: 1"),t.face.text())
    event(t,"key",257)
    typeText(t,code(t)); t.n.advance(3)
    equal(boxKeys(t),"1")
    assert(t.c.files["so-keys"]~=old,"same-id repair kept the old key")
    assert(shows(t.face,"display 2"),t.face.text())
    local log=stamp(t); reboot(t); t.n.advance(3)
    assert(sentTo(log,"hello")[1]); assert(shows(t.face,"display 2"),t.face.text())
  end)

  test("repair: monitor_touch in every phase never changes the server or so-keys",function()
    local t=setup(29,12,true,false,{repairServer=true,retryInput=true}); pair(t); t.n.advance(3)
    local old=t.c.files["so-keys"]
    stale(t); local s=replace(t,3)
    local log=stamp(t)
    local function taps()
      for y=1,12 do for x=1,29,3 do event(t,"monitor_touch","right",x,y) end end
      t.n.advance(0.5)
      equal(t.c.files["so-keys"],old)
      equal(sentTo(log,"pair2")[3],nil,"a tap started pairing")
    end
    taps()
    event(t,"monitor_touch","right",2,1)
    assert(shows(t.face,"Server 1"),t.face.text())
    assert(not shows(t.face,"CHANGE SERVER") and not shows(t.face,"CANCEL"),t.face.text())
    for _=1,3 do event(t,"monitor_touch","right",2,3) end
    event(t,"char","r"); taps()
    assert(not shows(t.own,"Leave server"),t.own.text())
    event(t,"char","r"); assert(shows(t.own,"CHANGE SERVER"),t.own.text()); taps()
    assert(shows(t.own,"CHANGE SERVER") and not shows(t.own,"Leave server"),t.own.text())
    event(t,"key",257); taps(); assert(shows(t.own,"Leave server 1?"),t.own.text())
    event(t,"key",257); taps(); assert(shows(t.own,"New server: 3"),t.own.text())
    event(t,"key",257); typeText(t,"123"); taps()
    assert(shows(t.own,"Code: 123"),t.own.text())
    equal(sentTo(log,"hello")[3],nil,"hello went to the candidate before pairing")
    local good=codeOn(t,s); local bad=good=="000000" and "111111" or "000000"
    typeText(t,bad:sub(4)); t.n.advance(15)
    assert(shows(t.own,"Pair failed"),t.own.text())
    log=stamp(t); taps()
    equal(t.c.files["so-keys"],old)
    equal(boxKeys(t),"1")
    event(t,"char","x"); t.n.advance(3)
    assert(not shows(t.own,"REPAIR"),t.own.text())
    log=stamp(t); t.n.advance(40)
    assert(sentTo(log,"hello")[1] and not sentTo(log,"hello")[3],"cancel did not resume the old server")
  end)

  for _,cfg in ipairs({false,{},{repairServer=false}}) do
    test("repair off ("..(cfg and "key "..tostring(cfg.repairServer) or "no file").."): today's old-key prompt stays",function()
      local t=setup(29,12,true,false,cfg or nil); pair(t); t.n.advance(3)
      local old=t.c.files["so-keys"]
      stale(t); replace(t,1); t.n.advance(45)
      assert(shows(t.face,"Old key kept"),t.face.text())
      event(t,"char","r"); event(t,"mouse_click",1,2,1); event(t,"monitor_touch","right",2,1)
      assert(not shows(t.face,"REPAIR") and not shows(t.own,"REPAIR"),t.own.text())
      equal(t.c.files["so-keys"],old)
      typeText(t,code(t)); t.n.advance(2)
      assert(t.c.files["so-keys"]~=old,"old-key prompt did not re-pair")
      assert(not shows(t.face,"Old key kept"),t.face.text())
    end)
  end

  test("repair: forged hints and frames during REPAIR change nothing",function()
    local cfg={repairServer=true}
    local t=setup(29,12,true,false,cfg); pair(t); t.n.advance(3)
    local old=t.c.files["so-keys"]
    stale(t); replace(t,3)
    event(t,"rednet_message",77,{t="pair.required",from=77},"so")
    event(t,"rednet_message",3,{t="pair.required",from=3},"so")
    assert(not shows(t.own,"REPAIR") and not shows(t.face,"Old key kept"),t.face.text())
    event(t,"char","r"); event(t,"key",257); event(t,"key",257)
    assert(shows(t.own,"New server: 3"),t.own.text())
    for _,id in ipairs({1,3,77}) do
      event(t,"rednet_message",id,{t="pair.required",from=id},"so")
      event(t,"rednet_message",id,{t="view.frame",body={rows={{text="forged"}},buttons={}}},"so")
    end
    assert(shows(t.own,"New server: 3") and not shows(t.face,"forged"),t.face.text())
    equal(t.c.files["so-keys"],old)
    equal(t.c.files["so-display.cfg"],H.encode(cfg))
  end)

  for _,failure in ipairs({"open","rename"}) do
    test("repair: a failed key save ("..failure..") keeps the old key, then a reboot still uses it",function()
      local t=setup(29,12,true,false,{repairServer=true}); pair(t); t.n.advance(3)
      local old=t.c.files["so-keys"]
      stale(t); local s=replace(t,3)
      event(t,"char","r"); event(t,"key",257); event(t,"key",257); event(t,"key",257)
      local fs=t.c.env.fs
      local open,move=fs.open,fs.move
      fs.open=function(path,mode)
        if failure=="open" and path=="so-keys.tmp" and mode=="w" then return nil end
        return open(path,mode)
      end
      fs.move=function(from,to)
        if failure=="rename" and from=="so-keys.tmp" then error("rename failed") end
        return move(from,to)
      end
      typeText(t,codeOn(t,s)); t.n.advance(3)
      fs.open,fs.move=open,move
      assert(shows(t.own,"Pair failed"),t.own.text())
      if failure=="open" then equal(t.c.files["so-keys"],old) end
      local log=stamp(t); event(t,"char","x"); t.n.advance(5)
      assert(sentTo(log,"hello")[1] and not sentTo(log,"hello")[3],"cancel left the old server")
      log=stamp(t); reboot(t); t.n.advance(5)
      assert(sentTo(log,"hello")[1] and not sentTo(log,"hello")[3],"reboot left the old server")
    end)
  end

  test("repair: an abandoned server change resumes the old server after two minutes",function()
    local t=setup(29,12,true,false,{repairServer=true}); pair(t); t.n.advance(3)
    local old=t.c.files["so-keys"]
    stale(t); replace(t,3)
    event(t,"char","r"); event(t,"key",257); event(t,"key",257)
    local log=stamp(t); t.n.advance(100)
    equal(next(sentTo(log,"hello")),nil,"sent hello during the change")
    t.n.advance(60)
    assert(not shows(t.own,"REPAIR"),t.own.text())
    assert(sentTo(log,"hello")[1] and not sentTo(log,"hello")[3])
    equal(t.c.files["so-keys"],old)
  end)

  test("repair: read-only taps with retryInput off send no more than the timer alone",function()
    local function run(tap)
      local t=setup(29,12,true,false,{repairServer=true}); pair(t); t.n.advance(3)
      stale(t); t.n.advance(20)
      local log=stamp(t)
      for _=1,20 do
        if tap then event(t,"monitor_touch","right",2,1) end
        t.n.advance(0.1)
      end
      return count(log,"hello"),count(log,"view.sub")
    end
    local hello,sub=run(true)
    local timerHello,timerSub=run(false)
    assert(hello<=timerHello and sub<=timerSub,"taps sent "..hello.." hellos, timer alone "..timerHello)
  end)

  test("repair: CANCEL is neither drawn nor accepted while the code exchange runs",function()
    local t=setup(29,12,true,false,{repairServer=true}); pair(t); t.n.advance(3)
    local old=t.c.files["so-keys"]
    stale(t); local s=replace(t,3)
    event(t,"char","r"); event(t,"key",257); event(t,"key",257); event(t,"key",257)
    assert(shows(t.own,"[X] CANCEL"),t.own.text())
    local good=codeOn(t,s)
    local send=s.env.rednet.send
    s.env.rednet.send=function() return true end
    typeText(t,good)
    assert(shows(t.own,"Pairing...") and not shows(t.own,"CANCEL"),t.own.text())
    assert(shows(t.face,"Pairing...") and not shows(t.face,"CANCEL"),t.face.text())
    event(t,"char","x"); t.n.advance(1)
    assert(shows(t.own,"Pairing...") and not shows(t.own,"CANCEL"),t.own.text())
    t.n.advance(20)
    s.env.rednet.send=send
    assert(shows(t.own,"Pair failed") and shows(t.own,"[X] CANCEL"),t.own.text())
    assert(shows(t.own,"Server 3"),"the swallowed x cancelled: "..t.own.text())
    equal(t.c.files["so-keys"],old)
  end)

  -- B7-U (D7): the display echoes a frame's challenge only after drawing all of it.
  local ACK={pos={dim="minecraft:overworld",x=0,y=0,z=0},displayAck=true}
  local function acks(t)
    local list={}
    for _,m in ipairs(t.c.sent) do if m.payload.t=="view.ack" then list[#list+1]=m.payload end end
    return list
  end
  local function challenges(t)
    local list={}
    for _,m in ipairs(t.s.sent) do
      local b=m.payload.body
      if m.payload.t=="view.frame" and b.ack then list[#list+1]={token=b.ack.token,rid=m.payload.rid} end
    end
    return list
  end
  local function heard(t)
    local D=dofile("tests/ui/scene.lua").private(t.s.env.SO.mods.display.handlers.hello,"D")
    return D.sessions[2].ack and D.sessions[2].ack.heard
  end
  test("B7-U: each drawn frame is acknowledged once, unchanged heartbeats included",function()
    local t=setup(29,12,true,false,nil,ACK); pair(t); t.n.advance(2)
    equal(last(t,"hello").body.capabilities,{frameAck=1})
    local before=#challenges(t)
    t.n.advance(13)
    local sent,got=challenges(t),acks(t)
    assert(#sent-before>=3,"heartbeats carry new challenges")
    equal(#got,#sent,"one ACK per challenged frame")
    for i,a in ipairs(got) do
      equal(a.body,{v=1,token=sent[i].token})
      assert(a.rid~=sent[i].rid,"the ACK has its own rid")
    end
    assert(heard(t),"the server heard the display")
    -- A redraw without a new challenge (typing) sends no ACK.
    local n=#acks(t)
    event(t,"char","a")
    equal(#acks(t),n)
  end)
  test("B7-U: an output change while a frame is drawn sends no ACK",function()
    local t=setup(29,12,true,false,nil,ACK)
    t.face.setTextScale=function() end
    pair(t); t.n.advance(2)
    local n=#acks(t)
    assert(n>0)
    local before=#challenges(t)
    local find=t.c.env.peripheral.find
    t.c.env.peripheral.find=function(kind) if kind~="monitor" then return find(kind) end end
    t.n.advance(8)
    local done={}
    for _,a in ipairs(acks(t)) do done[a.body.token]=true end
    local sent=challenges(t)
    assert(#sent>before+1)
    assert(not done[sent[before+1].token],"the frame that switched to the terminal is not acknowledged")
    assert(done[sent[#sent].token],"a later frame on the terminal is")
    assert(t.own.text():find("display 2",1,true),t.own.text())
  end)
  test("B7-U: a draw error sends no ACK",function()
    local t=setup(29,12,true,false,nil,ACK); pair(t); t.n.advance(2)
    local n=#acks(t)
    local before=#challenges(t)
    t.face.write=function() error("monitor failed") end
    t.n.advance(5)
    assert(#challenges(t)>before,"a challenged frame arrived")
    equal(#acks(t),n)
  end)
  test("B7-U: a new display on a server without displayAck sends no ACK",function()
    local t=setup(29,12,true); pair(t); t.n.advance(10)
    equal(#challenges(t),0)
    equal(#acks(t),0)
    assert(t.face.text():find("display 2",1,true),t.face.text())
  end)

  -- B1-D: install tokens enroll pockets and wall displays; so-display.cfg.server picks the unpaired join.
  local ENROLL={pos={dim="minecraft:overworld",x=0,y=0,z=0},enroll=true}
  local function enrolling(w,h,wall,cfg,isPocket,off)
    local token
    local t=setup(w,h,wall,false,cfg,ENROLL,function(c,s)
      assert(s.env.SO.enroll.open(50)); token=s.env.SO.enroll.view(50).token
      c.files["so-enroll"]=H.encode({token=token})
      if isPocket then c.env.pocket={} end
      -- A real modem sends nothing until rednet.open.
      local send=c.env.rednet.send
      c.env.rednet.send=function(...)
        if not c.env.rednet.isOpen() then return false end
        return send(...)
      end
      if off then assert(s.env.SO.enroll.setEnabled(false)) end
    end)
    return t,token
  end
  local function approve(t,kind)
    local so=t.s.env.SO
    local row=assert(so.enroll.view(50) and so.enroll.view(50).rows[1],"no enroll row")
    equal(row.kind,kind)
    assert(so.enroll.decide(t.c.id,row.n,true))
    t.n.advance(7)
    equal(boxKeys(t),"1")
    equal(t.c.files["so-enroll"],nil)
    assert(last(t,"view.sub"),"enrolled display did not subscribe")
    equal(t.c.env.textutils.unserialize(t.c.files["so-keys"]).value.keys["1"],so.pair.key(t.c.id))
  end
  local function enrolls(t)
    local n=0
    for _,p in ipairs(t.c.sent) do if p.payload.t=="enroll" then n=n+1 end end
    return n
  end
  for _,case in ipairs({{26,20,false,true,"pocket"},{29,12,true,false,"computer"}}) do
    test("B1-D: an install token enrolls a "..case[5].." display after owner approval",function()
      local t=enrolling(case[1],case[2],case[3],{keep="me"},case[4])
      t.n.advance(4)
      assert(shows(t.face,"Enroll "),t.face.text())
      assert(shows(t.own,"Enroll "),t.own.text())
      equal(boxKeys(t),"")
      approve(t,case[5])
      equal(t.c.files["so-display.cfg"],H.encode({keep="me"}))
      reboot(t); t.n.advance(3)
      equal(boxKeys(t),"1")
      assert(not shows(t.face,"Enroll "),t.face.text())
    end)
  end
  for _,pick in ipairs({false,true}) do
    test("B1-D: so-display.cfg server "..(pick and "3 overrides" or "missing uses").." discovery and keeps every flag",function()
      local cfg={retryInput=true,repairServer=true,keep="me"}
      if pick then cfg.server=3 end
      local t=setup(29,12,true,true,cfg)
      local s3=replace(t,3)
      t.s.boot("so-server.lua"); t.n.flush()
      equal(t.c.env.rednet.lookup("so","server"),1)
      t.n.advance(31)
      typeText(t,codeOn(t,pick and s3 or t.s)); t.n.advance(2)
      equal(boxKeys(t),pick and "3" or "1")
      equal(t.c.files["so-display.cfg"],H.encode(cfg))
      assert(last(t,"view.sub"))
    end)
  end
  test("B1-D: monitor_touch never enrolls or resumes a paused enrollment; terminal paste does",function()
    local t=enrolling(29,12,true,{retryInput=true,repairServer=true},false,true)
    t.n.advance(7)
    equal(t.c.env.textutils.unserialize(t.c.files["so-enroll"]).paused,"off")
    assert(shows(t.face,"Enroll off"),t.face.text())
    local asked=enrolls(t)
    t.s.env.SO.enroll.setEnabled(true)
    assert(t.s.env.SO.enroll.open(50))
    local token=t.s.env.SO.enroll.view(50).token
    for y=1,12 do for x=1,29,3 do event(t,"monitor_touch","right",x,y) end t.n.advance(0.5) end
    reboot(t); t.n.advance(10)
    for y=1,12 do for x=1,29,3 do event(t,"monitor_touch","right",x,y) end end
    t.n.advance(30)
    equal(enrolls(t),asked,"monitor_touch or reboot sent enroll")
    equal(t.c.env.textutils.unserialize(t.c.files["so-enroll"]).paused,"off")
    equal(boxKeys(t),"")
    equal(t.s.env.SO.enroll.view(50).rows[1],nil)
    event(t,"paste",token); t.n.advance(4)
    approve(t,"computer")
  end)

  -- B11-U (D11): a pocket plays a fresh frame's tone once through its speaker.
  local function toneClient(w,h,wall,isPocket,speaker)
    local notes={}
    local t=setup(w,h,wall,false,nil,nil,function(c)
      if isPocket then c.env.pocket={} end
      local find=c.env.peripheral.find
      c.env.peripheral.find=function(kind)
        if kind~="speaker" then return find(kind) end
        if speaker=="none" then return nil end
        return {playNote=function(...)
          notes[#notes+1]={...}
          if speaker=="error" then error("speaker failed") end
          return speaker~="busy"
        end}
      end
    end)
    pair(t); t.n.advance(2)
    t.notes=notes
    return t
  end
  local function tone(id,over)
    local sound={v=1,id=id or "1-7000-1",key="drop/2",instrument="pling",volume=0.5,pitch=12}
    for k,v in pairs(over or {}) do sound[k]=v end
    return sound
  end
  local function signed(t,sound,key)
    local P=t.s.env.SO.proto
    return P.encode(P.build(key or t.s.env.SO.pair.key(t.c.id),"view.frame",{rows={{text="TONE"}},buttons={},sound=sound}))
  end
  local function deliver(t,wire,from) event(t,"rednet_message",from or 1,wire,"so") end
  test("B11-U: a pocket with a speaker plays a tone once; repeats and replays stay silent",function()
    local t=toneClient(26,20,false,true)
    equal(#t.notes,0,"frames without sound are silent")
    local wire=signed(t,tone())
    deliver(t,wire)
    equal(t.notes,{{"pling",0.5,12}})
    assert(t.face.text():find("TONE",1,true),"the frame is drawn")
    deliver(t,wire)
    deliver(t,signed(t,tone()))
    t.n.advance(10)
    equal(#t.notes,1,"a replayed wire, a resent id and later frames never repeat it")
    deliver(t,signed(t,tone("1-7000-2")))
    equal(#t.notes,2,"a new occurrence plays")
  end)
  test("B11-U: the client keeps the last 128 tone ids",function()
    local t=toneClient(26,20,false,true)
    local first=signed(t,tone("1-1-1"))
    deliver(t,first)
    for i=2,129 do deliver(t,signed(t,tone("1-1-"..i))) end
    equal(#t.notes,129)
    deliver(t,signed(t,tone("1-1-129")))
    deliver(t,first)
    equal(#t.notes,129,"a replayed wire stays silent after its id left memory")
    deliver(t,signed(t,tone("1-1-1")))
    equal(#t.notes,130,"the 129th id pushed the first out")
  end)
  test("B11-U: spoofed, foreign and malformed tones are refused",function()
    local t=toneClient(26,20,false,true)
    local key=t.s.env.SO.pair.key(t.c.id)
    deliver(t,signed(t,tone("1-1-1"),(key:sub(1,1)=="0" and "1" or "0")..key:sub(2)))
    deliver(t,signed(t,tone("1-1-2")),77)
    for i,over in ipairs({{v=2},{volume=1},{pitch=13},{instrument="bell"},{id=string.rep("9",49)},{id=5},{key=false}}) do
      deliver(t,signed(t,tone("1-2-"..i,over)))
    end
    equal(#t.notes,0)
    deliver(t,signed(t,tone("1-1-1")))
    equal(#t.notes,1,"the refused spoof did not burn its id")
  end)
  test("B11-U: a computer, a pocket on a monitor, and a missing, busy or failing speaker stay quiet",function()
    for _,c in ipairs({{26,20,false,false},{29,12,true,true}}) do
      local t=toneClient(c[1],c[2],c[3],c[4])
      deliver(t,signed(t,tone()))
      equal(#t.notes,0)
    end
    for _,speaker in ipairs({"none","busy","error"}) do
      local t=toneClient(26,20,false,true,speaker)
      deliver(t,signed(t,tone()))
      deliver(t,signed(t,tone()))
      equal(#t.notes,speaker=="none" and 0 or 1,speaker)
      assert(t.face.text():find("TONE",1,true),speaker)
    end
  end)
  test("B11-U: a frame seen on a monitor cannot be replayed for a tone once the monitor goes",function()
    local t=toneClient(29,12,true,true)
    local wire=signed(t,tone("1-3-1"))
    deliver(t,wire)
    equal(#t.notes,0,"a pocket on a monitor is silent")
    local find=t.c.env.peripheral.find
    t.c.env.peripheral.find=function(kind) if kind~="monitor" then return find(kind) end end
    event(t,"peripheral_detach","right")
    deliver(t,wire)
    equal(#t.notes,0,"the replayed frame was already seen")
    deliver(t,signed(t,tone("1-3-2")))
    equal(#t.notes,1,"a fresh frame plays after the monitor went")
  end)
  test("B11-U: a restarted pocket refuses frames from before its boot",function()
    local t=toneClient(26,20,false,true)
    local wire=signed(t,tone("1-4-1"))
    deliver(t,wire)
    equal(#t.notes,1)
    t.n.advance(1)
    reboot(t); t.n.advance(2)
    deliver(t,wire)
    equal(#t.notes,1,"the replay after the restart stays silent")
    deliver(t,signed(t,tone("1-4-2")))
    equal(#t.notes,2,"a frame from after the boot plays")
  end)
end
