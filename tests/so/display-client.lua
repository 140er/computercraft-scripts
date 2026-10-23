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
local function setup(w,h,wall,absent)
  local n=H.new()
  local s=n.machine({id=1,modem=true}); install(s,true)
  if not absent then s.boot("so-server.lua"); n.flush() end
  local c=n.machine({id=2,modem=true,capacity=1000000}); install(c)
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
    assert(t.face.text():find("press P",1,true),t.face.text())
    assert(t.own.text():find("press P",1,true),t.own.text())
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
    assert(not t.face.text():find("stale",1,true),t.face.text())
    t.s.env.os.queueEvent("terminate"); t.n.flush(); t.n.hosts.so=nil
    t.c.co,t.c.inbox,t.c.timers=nil,{},{}
    t.c.boot("display.lua"); t.n.advance(40)
    t.s.co,t.s.inbox,t.s.timers=nil,{},{}
    t.s.boot("so-server.lua"); t.n.flush(); t.n.advance(31)
    assert(not t.face.text():find("stale",1,true),t.face.text())
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

end
