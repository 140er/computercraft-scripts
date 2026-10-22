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
  local find=c.env.peripheral.find
  c.env.peripheral.find=function(kind) if kind=="monitor" and wall then return face end return find(kind) end
  c.boot("display.lua"); n.flush()
  return {n=n,s=s,c=c,face=face,own=own,w=w,h=h}
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
  test("display wrong code then right code without reboot",function()
    local t=setup(29,12,true)
    assert(t.face.text():find("press P",1,true),t.face.text())
    assert(t.own.text():find("press P",1,true),t.own.text())
    event(t,"char","0"); event(t,"char","2"); event(t,"key",259)
    assert(t.face.text():find("0",1,true)); event(t,"key",259)
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
end
