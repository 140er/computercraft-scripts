local H = dofile("tests/so/harness.lua")
local file = assert(io.open("roomsorter.lua", "rb"))
local source = file:read("*a") file:close()
local point = {dim="minecraft:overworld",x=0,y=0,z=1}
local function fixture(managed, previous)
  local net = H.new()
  local m = net.machine({id=9,turtle=true,modem=true,fuel=10000})
  local e = m.env
  local function copy(v) return e.textutils.unserialize(H.encode(v)) end
  local s = {net=net,m=m,e=e,serial=100}
  m.files = previous and copy(previous.files) or {}
  if previous then
    m.inv, m.pos, m.heading = copy(previous.inv), copy(previous.pos), previous.heading
    m.fuel = previous.fuel or m.fuel
  end
  if not previous then
    m.files["room.cfg"] = H.encode({managedOutput=managed,minFuel=0,maxFurnaces=0,v2=true})
    m.files["room.map"] = H.encode({home="0,0,0",slots={},layout=2,badCleared=true,cells={
      ["0,0,0"]="a",["0,0,-1"]="minecraft:chest",["0,0,1"]="minecraft:chest",["1,0,0"]="minecraft:chest"}})
    m.files["room.idx"] = H.encode({
      ["0,0,-1"]={kind="input",acc="0,0,0",dir=0,size=27,items={}},
      ["0,0,1"]={kind="output",acc="0,0,0",dir=2,size=27,items={}},
      ["1,0,0"]={kind="store",acc="0,0,0",dir=1,size=27,items={[1]={name="minecraft:stone",count=20}}}})
  end
  net.world = previous and copy(previous.world) or {
    ["0,0,-1"]={name="minecraft:chest",inv={}},
    ["0,0,1"]={name="minecraft:chest",inv={}},
    ["1,0,0"]={name="minecraft:chest",inv={{name="minecraft:stone",count=20}}}}
  local world = net.world
  local function chest(side)
    local x,y,z = m.pos.x,m.pos.y,m.pos.z
    if side == "top" then y=y+1 elseif side == "bottom" then y=y-1
    else x=x+({[0]=0,1,0,-1})[m.heading] z=z+({[0]=-1,0,1,0})[m.heading] end
    return world[x..","..y..","..z]
  end
  e.peripheral.hasType = function(side, kind) return kind=="inventory" and chest(side)~=nil end
  e.peripheral.call = function(side, method, a,b,c,d)
    local ch = assert(chest(side),"missing chest")
    if method=="list" then
      local out={} for slot,it in pairs(ch.inv) do if it.count>0 then out[slot]=copy(it) end end return out
    elseif method=="size" then return 27
    elseif method=="getItemDetail" then return ch.inv[a] and copy(ch.inv[a])
    elseif method=="pushItems" then
      local it=ch.inv[b] if not it then return 0 end
      local into=d or 1 local dest=ch.inv[into]
      if dest and dest.name~=it.name then return 0 end
      local n=math.min(c or 64,it.count,64-(dest and dest.count or 0))
      ch.inv[into]={name=it.name,count=(dest and dest.count or 0)+n}
      it.count=it.count-n if it.count==0 then ch.inv[b]=nil end return n
    end
    error("unsupported inventory method "..method)
  end
  local function suck(side,n)
    local ch=assert(chest(side))
    for slot=1,27 do
      local it=ch.inv[slot] local dest=m.inv[m.selected]
      if it and it.count>0 and (not dest or dest.name==it.name) then
        local count=math.min(n or 64,it.count,64-(dest and dest.count or 0))
        if count>0 then
          m.inv[m.selected]={name=it.name,count=(dest and dest.count or 0)+count}
          it.count=it.count-count if it.count==0 then ch.inv[slot]=nil end return true
        end
      end
    end
    return false
  end
  local function drop(side,n)
    if s.beforeDrop then s.beforeDrop(side) end
    local ch=assert(chest(side)) local it=m.inv[m.selected]
    if not it then return false end
    if ch.full then return false end
    for slot=1,27 do
      local dest=ch.inv[slot]
      if not dest or (dest.name==it.name and dest.count<64) then
        local count=math.min(n or it.count,it.count,64-(dest and dest.count or 0))
        ch.inv[slot]={name=it.name,count=(dest and dest.count or 0)+count}
        it.count=it.count-count if it.count==0 then m.inv[m.selected]=nil end
        if s.afterDrop then s.afterDrop(side,count) end
        return true
      end
    end
    return false
  end
  e.turtle.suck=function(n) return suck("front",n) end
  e.turtle.suckUp=function(n) return suck("top",n) end
  e.turtle.suckDown=function(n) return suck("bottom",n) end
  e.turtle.drop=function(n) return drop("front",n) end
  e.turtle.dropUp=function(n) return drop("top",n) end
  e.turtle.dropDown=function(n) return drop("bottom",n) end
  e.turtle.transferTo=function(slot,n)
    local it=m.inv[m.selected] if not it then return false end
    local dest=m.inv[slot] if dest and dest.name~=it.name then return false end
    local count=math.min(n or it.count,it.count,64-(dest and dest.count or 0))
    m.inv[slot]={name=it.name,count=(dest and dest.count or 0)+count}
    it.count=it.count-count if it.count==0 then m.inv[m.selected]=nil end return true
  end
  local find=e.peripheral.find
  e.peripheral.find=function(kind,...)
    if kind=="workbench" and s.workbench then return {} end
    return find(kind,...)
  end
  e.turtle.craft=function(n)
    local a,b=m.inv[1],m.inv[5]
    if not a or not b or a.name~="minecraft:oak_planks" or b.name~=a.name then return false end
    if n==0 then return true end
    n=math.min(n or 64,a.count,b.count,16)
    for _,slot in ipairs({1,5}) do
      m.inv[slot].count=m.inv[slot].count-n if m.inv[slot].count==0 then m.inv[slot]=nil end
    end
    m.inv[m.selected]={name="minecraft:stick",count=n*4}
    if s.afterCraft then s.afterCraft() end
    return true
  end
  local inspect=e.turtle.inspect
  e.turtle.inspect=function() local ch=chest("front") if ch then return true,{name=ch.name} end return inspect() end
  e.os.time=function() return 0 end e.os.date=function() return "test " end
  e.textutils.formatTime=function() return "00:00" end
  e.colors={black=32768,white=1}
  e.term.current=function() return e.term end e.term.redirect=function() end
  e.window={create=function() return e.term end}
  e.parallel={waitForAny=function(worker,_,prompt,remote) s.worker,s.prompt,s.remote=worker,prompt,remote end}
  local instrumented=source:gsub("local W, H = term.getSize%(%)", [[
_ROOM_TEST = {output=K.output,command=command,requests=requests,crafts=crafts,idx=idx,cfg=cfg,
  serveRequests=serveRequests,serveCrafts=serveCrafts,findOutput=findOutput,deliver=deliver}
local W, H = term.getSize()]],1)
  assert(load(instrumented,"@roomsorter.lua","t",e))()
  s.api=e._ROOM_TEST s.o=s.api.output s.world=world
  s.ask=function(cmd,extra,sender)
    s.serial=s.serial+1
    local b={cmd=cmd,rid=s.serial,outputToken="claim-a",output=copy(point)}
    for k,v in pairs(extra or {}) do b[k]=v end
    return s.o.network(sender or 1,b)
  end
  s.wire=function(b)
    local remote=coroutine.create(s.remote)
    assert(coroutine.resume(remote))
    local ok,err=coroutine.resume(remote,"rednet_message",1,b,"roomsorter") assert(ok,err)
    return m.sent[#m.sent].payload
  end
  s.start=function()
    m.co=coroutine.create(s.worker) m.resume() assert(not m.error,m.error)
  end
  s.wake=function()
    m.resume(table.pack("room_request")) assert(not m.error,m.error)
  end
  s.reconcile=function() s.api.command("output","reconcile") s.wake() end
  s.count=function(k,name)
    local n=0 for _,it in pairs(world[k].inv) do if not name or it.name==name then n=n+it.count end end return n
  end
  s.snapshot=function() return {files=copy(m.files),inv=copy(m.inv),world=copy(world),pos=copy(m.pos),heading=m.heading,fuel=m.fuel} end
  return s
end

return function(test,equal)
  test("managed output defaults off and legacy get and order responses remain unchanged",function()
    local s=fixture(nil)
    equal(s.api.cfg.managedOutput,false)
    equal(s.ask("output.claim").error,"room support missing")
    equal(s.ask("get",{text="minecraft:stone",n=4}).error,"room support missing")
    local get=s.o.network(2,{cmd="get",text="stone",n=4,rid=7})
    equal(get,{"Getting 4 Stone..."})
    local order=s.o.network(2,{cmd="order",text="stone",n=4,rid=8})
    equal(order,{"Getting 4 Stone..."})
    s.start()
    equal(s.count("0,0,1"),8)
    equal(s.m.files["room.output"],nil)
  end)
  for _,item in ipairs({"minecraft:lava_bucket","minecraft:coal"}) do
    test("quarantined "..item.." survives restart and reconciliation without refuelling",function()
      local s=fixture(true) s.start()
      local count=item=="minecraft:coal" and 5 or 1
      s.world["1,0,0"].inv={[1]={name=item,count=count}}
      s.api.idx["1,0,0"].items={[1]={name=item,count=count}}
      s.ask("output.claim")
      local order=s.ask("get",{text=item,n=count}) equal(order.state,"busy")
      local cut
      s.beforeDrop=function()
        cut=s.snapshot() error("power cut before output drop")
      end
      s.wake() assert(cut)
      local cfg=s.e.textutils.unserialize(cut.files["room.cfg"])
      cfg.minFuel=1000
      cut.files["room.cfg"]=H.encode(cfg) cut.fuel=10
      local r=fixture(true,cut) r.start()
      equal(r.m.fuel,10) equal(r.m.inv[1],{name=item,count=count})
      equal(r.ask("output.status",{requestRid=order.requestRid}).state,"quarantined")
      r.reconcile()
      equal(r.m.fuel,10) equal(next(r.m.inv),nil)
      equal(r.count("1,0,0",item),count) equal(r.count("1,0,0","minecraft:bucket"),0)
      equal(r.count("0,0,1"),0)
      local receipt=r.ask("output.status",{requestRid=order.requestRid})
      equal(receipt.state,"settled") equal(receipt.requestRid,order.requestRid)
      local saved=r.e.textutils.unserialize(r.m.files["room.output"])
      equal(saved.barrier,receipt.barrier) equal(saved.work,nil)
      local legacy=fixture(false)
      legacy.m.inv[1]={name=item,count=count} legacy.m.fuel=10 legacy.api.cfg.minFuel=1000
      legacy.start()
      assert(legacy.m.fuel>10,"legacy automatic refuelling changed")
    end)
  end
  test("managed delivery stores three sorting stone before fetching four, with legacy behavior unchanged",function()
    for _,managed in ipairs({false,true}) do
      local s=fixture(managed) s.start()
      if managed then s.ask("output.claim") end
      s.m.inv[1]={name="minecraft:stone",count=3}
      local order
      if managed then order=s.ask("get",{text="minecraft:stone",n=4})
      else s.o.network(1,{cmd="get",text="minecraft:stone",n=4}) end
      s.wake()
      equal(s.count("0,0,1","minecraft:stone"),managed and 4 or 7)
      equal(s.count("1,0,0","minecraft:stone"),managed and 19 or 16)
      equal(next(s.m.inv),nil)
      if managed then
        local receipt=s.ask("output.status",{requestRid=order.requestRid})
        equal(receipt.state,"settled") equal(receipt.requestRid,order.requestRid)
        local saved=s.e.textutils.unserialize(s.m.files["room.output"])
        equal(saved.barrier,receipt.barrier) equal(saved.work,nil)
      end
    end
  end)
  test("managed delivery holds existing sorting cargo when storage cannot accept it",function()
    local s=fixture(true) s.start() s.ask("output.claim")
    s.m.inv[1]={name="minecraft:stone",count=3}
    s.world["1,0,0"].full=true
    s.ask("get",{text="minecraft:stone",n=4}) s.wake()
    equal(s.ask("output.status").state,"quarantined")
    equal(s.m.inv[1],{name="minecraft:stone",count=3})
    equal(s.count("1,0,0"),20) equal(s.count("0,0,1"),0)
  end)
  test("first claim waits for the worker drain rather than an empty output chest",function()
    local s=fixture(true)
    s.api.requests[1]={name="minecraft:stone",n=3}
    equal(s.count("0,0,1"),0)
    equal(s.ask("output.claim").state,"busy")
    equal(s.ask("output.status").state,"busy")
    s.start()
    equal(s.count("0,0,1"),3)
    equal(s.ask("output.claim").state,"claimed")
    equal(s.o.state.server,1)
    equal(s.ask("output.status",nil,2).error,"server mismatch")
  end)
  test("managed get is exact and stock-only with partial stock at execution",function()
    local s=fixture(true) s.start()
    equal(s.ask("output.claim").state,"claimed")
    equal(s.ask("get",{text="stone",n=4}).error,"exact item id required")
    local r=s.ask("get",{text="minecraft:stone",n=9}) equal(r.state,"busy")
    equal(s.api.requests[1].outputRid,r.requestRid)
    equal(s.api.requests[1].outputToken,"claim-a")
    s.world["1,0,0"].inv[1].count=2
    s.wake()
    equal(s.count("0,0,1"),2) equal(#s.api.crafts,0)
    local receipt=s.ask("output.status",{requestRid=r.requestRid})
    equal(receipt.state,"settled") assert(receipt.barrier>0)
    equal(s.ask("get",{text="minecraft:stone",n=1}).state,"busy")
  end)
  test("unclaimed network and terminal output commands cannot enqueue",function()
    local s=fixture(true) s.start()
    for _,cmd in ipairs({"get","order","craft"}) do
      equal(s.api.command(cmd,"minecraft:stone",1),{"output claim required"})
      local r=s.o.network(1,{cmd=cmd,text="minecraft:stone",n=1,rid=5})
      if cmd=="craft" then equal(r,{"output claim required"}) else equal(r.error,"invalid output request") end
    end
    equal(#s.api.requests,0) equal(#s.api.crafts,0)
    equal(s.ask("output",{text="reconcile"}).error,"local reconciliation required")
  end)
  test("claims and request ids reach verified storage before acknowledgement and admission",function()
    local s=fixture(true) s.start()
    equal(s.ask("output.claim",{rid=50}).state,"claimed")
    local saved=s.e.textutils.unserialize(s.m.files["room.output"])
    equal(saved.claim.token,"claim-a") equal(saved.highWater,50)
    local r=s.ask("order",{rid=51,text="minecraft:stone",n=5})
    equal(r.state,"busy")
    saved=s.e.textutils.unserialize(s.m.files["room.output"])
    equal(saved.work.rid,51) equal(saved.claim.requestRid,51) equal(saved.highWater,51)
    equal(s.api.requests[1].outputRid,51)
    equal(s.ask("order",{rid=51,text="minecraft:stone",n=5}).state,"busy")
    equal(#s.api.requests,1)
  end)
  test("release requires the matching settled barrier and rejects old tokens",function()
    local s=fixture(true) s.start() s.ask("output.claim",{rid=40})
    local r=s.ask("get",{rid=41,text="minecraft:stone",n=2})
    equal(s.ask("output.release",{rid=42,barrier=r.barrier}).state,"busy")
    s.wake()
    local settled=s.ask("output.status") equal(settled.state,"settled")
    equal(s.ask("output.release",{rid=42,barrier=settled.barrier-1}).error,"settled barrier required")
    local released=s.ask("output.release",{rid=42,barrier=settled.barrier,requestRid=41})
    equal(released.state,"released") equal(released.requestRid,41)
    equal(s.ask("output.claim",{rid=43,outputToken="claim-b",output={dim=point.dim,x=9,y=0,z=1}}).error,"output mismatch")
    equal(s.ask("output.claim",{rid=43,outputToken="claim-b"}).state,"claimed")
    equal(s.ask("get",{rid=44,text="minecraft:stone",n=1}).error,"output claim required")
    equal(s.ask("output.status",{outputToken="claim-b",requestRid=41}).error,"request mismatch")
  end)
  test("restart mid-claim restores quarantine, preserves rids and never replays output",function()
    local s=fixture(true) s.start() s.ask("output.claim",{rid=30})
    s.ask("get",{rid=31,text="minecraft:stone",n=5})
    local r=fixture(true,s.snapshot()) r.start()
    equal(r.ask("output.status",{requestRid=31}).state,"quarantined")
    equal(r.count("0,0,1"),0) equal(#r.api.requests,0)
    equal(r.ask("output.release",{rid=32,barrier=r.o.state.barrier}).state,"quarantined")
    r.reconcile()
    local receipt=r.ask("output.status",{requestRid=31}) equal(receipt.state,"settled")
    equal(r.ask("output.release",{rid=32,barrier=receipt.barrier}).state,"released")
    local again=fixture(true,r.snapshot()) again.start() again.reconcile()
    equal(again.ask("output.claim",{rid=31}).error,"retired rid")
    equal(again.ask("output.claim",{rid=33}).state,"claimed")
    equal(again.ask("get",{rid=31,text="minecraft:stone",n=5}).error,"retired rid")
  end)
  test("full output retains carried cargo until local reconciliation can store it",function()
    local s=fixture(true) s.start() s.ask("output.claim")
    s.world["0,0,1"].full=true
    s.ask("get",{text="minecraft:stone",n=5}) s.wake()
    equal(s.ask("output.status").state,"quarantined")
    equal(s.m.inv[1].count,5)
    s.world["1,0,0"].full=true
    s.reconcile() equal(s.ask("output.status").state,"quarantined")
    assert(next(s.m.inv))
    s.world["1,0,0"].full=nil s.reconcile()
    equal(s.ask("output.status").state,"settled") equal(next(s.m.inv),nil)
    equal(s.count("0,0,1"),0)
  end)
  test("ordinary orders track derived crafts through the physical delivery boundary",function()
    local s=fixture(true) s.workbench=true
    local item={name="minecraft:oak_planks",count=8}
    s.world["1,0,0"].inv={[1]=item}
    s.api.idx["1,0,0"].items={[1]={name=item.name,count=item.count}}
    s.start() s.ask("output.claim")
    local order=s.ask("order",{text="minecraft:stick",n=4}) equal(order.state,"busy")
    equal(s.api.crafts[1].outputRid,order.requestRid)
    equal(s.api.crafts[1].outputToken,"claim-a")
    local seen=false
    s.afterCraft=function()
      seen=true equal(s.ask("output.status").state,"busy")
      equal(s.ask("output.release",{barrier=s.o.state.barrier}).state,"busy")
    end
    s.wake() assert(seen)
    equal(s.count("0,0,1","minecraft:stick"),4)
    equal(s.ask("output.status").state,"settled")
  end)
  test("initial drain includes old crafts and carried cargo",function()
    local s=fixture(true) s.workbench=true
    s.m.inv[6]={name="minecraft:stone",count=3}
    s.world["1,0,0"].inv[2]={name="minecraft:oak_planks",count=2}
    s.api.idx["1,0,0"].items[2]={name="minecraft:oak_planks",count=2}
    s.api.crafts[1]={name="minecraft:stick",n=4}
    s.afterCraft=function() equal(s.ask("output.claim").state,"busy") end
    equal(s.ask("output.claim").state,"busy") s.start()
    equal(s.count("0,0,1","minecraft:stick"),4)
    equal(next(s.m.inv),nil) equal(s.ask("output.claim").state,"claimed")
    local blocked=fixture(true)
    blocked.m.inv[1]={name="minecraft:stone",count=2}
    blocked.world["1,0,0"].full=true
    blocked.start() equal(blocked.ask("output.claim").state,"quarantined")
  end)
  test("local reconciliation cancels linked queues and crafts without executing them",function()
    for _,craft in ipairs({false,true}) do
      local s=fixture(true) s.start() s.ask("output.claim")
      if craft then
        s.workbench=true
        s.world["1,0,0"].inv[2]={name="minecraft:oak_planks",count=2}
        s.api.idx["1,0,0"].items[2]={name="minecraft:oak_planks",count=2}
      end
      s.ask("order",{text=craft and "minecraft:stick" or "minecraft:stone",n=4})
      assert(#s.api.requests+#s.api.crafts>0)
      s.api.command("output","reconcile")
      equal(s.ask("output.status").state,"quarantined")
      s.wake()
      equal(#s.api.requests+#s.api.crafts,0) equal(s.count("0,0,1"),0)
      equal(s.ask("output.status").state,"settled")
    end
  end)
  test("a reboot at either side of a drop cannot replay a request or lose cargo ownership",function()
    for _,after in ipairs({false,true}) do
      local s=fixture(true) s.start() s.ask("output.claim")
      s.ask("get",{text="minecraft:stone",n=5})
      local cut
      local function powerCut()
        equal(s.ask("output.status").state,"busy")
        cut=s.snapshot() error("power cut")
      end
      if after then s.afterDrop=powerCut else s.beforeDrop=powerCut end
      s.wake() assert(cut)
      local r=fixture(true,cut) r.start()
      equal(r.ask("output.status").state,"quarantined")
      equal(r.count("0,0,1"),after and 5 or 0)
      r.reconcile() equal(r.ask("output.status").state,"settled")
      equal(r.count("0,0,1"),after and 5 or 0)
      equal(next(r.m.inv),nil)
    end
  end)
  test("reconciliation requested during a transfer waits for the worker boundary",function()
    local s=fixture(true) s.start() s.ask("output.claim")
    s.ask("get",{text="minecraft:stone",n=5})
    s.beforeDrop=function()
      s.beforeDrop=nil
      s.api.command("output","reconcile")
      equal(s.ask("output.status").state,"quarantined")
      assert(s.o.active)
    end
    s.wake()
    equal(s.ask("output.status").state,"settled")
    equal(#s.api.requests+#s.api.crafts,0) equal(next(s.m.inv),nil)
    local count=s.count("0,0,1") s.wake() equal(s.count("0,0,1"),count)
  end)
  test("a new admission during settlement cannot overwrite its saved rid or queue",function()
    local s=fixture(true) s.start() s.ask("output.claim")
    s.m.inv[1]={name="minecraft:stone",count=1}
    s.afterDrop=function()
      s.afterDrop=nil
      equal(s.ask("get",{rid=900,text="minecraft:stone",n=2}).state,"busy")
    end
    s.o.boundary()
    equal(s.o.state.highWater,900) equal(s.o.state.work.rid,900)
    equal(#s.api.requests,1) equal(s.ask("output.status").state,"busy")
    s.wake() equal(s.count("0,0,1"),2)
  end)
  test("managed outputs refuse relocation and retain enrollment when disabled",function()
    local s=fixture(true) s.start() s.ask("output.claim",{rid=50})
    s.ask("get",{rid=51,text="minecraft:stone",n=2})
    equal(s.api.command("pickup"),{"Managed output refuses automatic relocation."})
    equal(s.api.findOutput(),false)
    local cfg=s.e.textutils.unserialize(s.m.files["room.cfg"])
    cfg.managedOutput=false s.m.files["room.cfg"]=H.encode(cfg)
    local r=fixture(false,s.snapshot()) r.start()
    equal(r.ask("output.status").state,"quarantined")
    equal(r.api.command("get","stone",1),{"output claim required"})
    equal(r.ask("get",{text="minecraft:stone",n=1}).state,"quarantined")
    r.reconcile()
    local receipt=r.ask("output.status")
    equal(r.ask("output.release",{rid=52,barrier=receipt.barrier}).state,"released")
    equal(r.ask("output.claim",{rid=53}).state,"quarantined")
    equal(r.count("0,0,1"),0)
  end)
  test("failed writes never acknowledge or enqueue and surviving generations retain consumed rids",function()
    for _,phase in ipairs({"open","write","verify","backup","install"}) do
      local s=fixture(true) s.start() s.ask("output.claim",{rid=40})
      local open,move=s.e.fs.open,s.e.fs.move
      s.e.fs.open=function(path,mode)
        if path=="room.output.tmp" and mode=="w" then
          if phase=="open" then return nil end
          local h=open(path,mode)
          local write=h.write
          h.write=function(bytes)
            if phase=="write" then write(bytes:sub(1,30)) error("disk full") end
            write(bytes)
          end
          return h
        end
        if path=="room.output.tmp" and mode=="r" and phase=="verify" then
          return {readAll=function() return "broken" end,close=function() end}
        end
        return open(path,mode)
      end
      s.e.fs.move=function(from,to)
        if (phase=="backup" and to=="room.output.bak") or (phase=="install" and to=="room.output") then
          error("rename failed")
        end
        return move(from,to)
      end
      equal(s.ask("get",{rid=41,text="minecraft:stone",n=2}).state,"quarantined")
      equal(#s.api.requests,0) s.wake() equal(s.count("0,0,1"),0)
      local r=fixture(true,s.snapshot()) r.start()
      equal(r.ask("output.status").state,"quarantined")
      if phase=="backup" or phase=="install" or phase=="verify" then
        r.reconcile()
        local status=r.ask("output.status") equal(status.state,"settled")
        equal(r.ask("output.release",{rid=42,barrier=status.barrier}).state,"released")
        equal(r.ask("output.claim",{rid=41}).error,"retired rid")
      end
    end
  end)
  test("corrupt or future state blocks output even with a valid older backup",function()
    for _,bad in ipairs({"broken",H.encode({v=2,generation=100,highWater=9000})}) do
      local s=fixture(true) s.start() s.ask("output.claim")
      s.m.files["room.output.tmp"]=bad
      local r=fixture(true,s.snapshot()) r.start() r.reconcile()
      equal(r.ask("output.status").state,"quarantined")
      equal(r.ask("get",{text="minecraft:stone",n=1}).state,"quarantined")
      equal(r.count("0,0,1"),0)
    end
  end)
  test("output pins, request references and exact integer limits reject mismatched admission",function()
    local s=fixture(true) s.start()
    equal(s.ask("output.claim",{output={dim="overworld",x=0,y=0,z=1}}).error,"invalid output")
    equal(s.ask("output.claim",{rid=9007199254740991}).error,"invalid output request")
    equal(s.ask("output.claim",{rid=9007199254740988}).state,"claimed")
    equal(s.ask("get",{text="minecraft:stone",n=1,output={dim=point.dim,x=1,y=0,z=1}}).error,"output mismatch")
    equal(s.ask("get",{text="minecraft:stone",n=1,outputToken="old-token"}).error,"output claim required")
    equal(s.ask("get",{rid=9007199254740989,text="minecraft:stone",n=1}).state,"busy")
    s.wake()
    local status=s.ask("output.status",{requestRid=9007199254740989}) equal(status.state,"settled")
    equal(s.ask("output.release",{rid=9007199254740990,barrier=status.barrier}).state,"released")
    equal(s.ask("output.claim",{rid=9007199254740991}).error,"invalid output request")
  end)
  test("wire receipts echo the transport rid separately from the admitted request rid",function()
    local s=fixture(true) s.start() s.ask("output.claim",{rid=50})
    s.ask("get",{rid=51,text="minecraft:stone",n=2})
    local receipt=s.wire({cmd="output.status",rid=700,outputToken="claim-a",output=point,requestRid=51})
    equal(receipt.rid,700) equal(receipt.requestRid,51) equal(receipt.v,1) equal(receipt.state,"busy")
    s.wake()
    receipt=s.wire({cmd="output.status",rid=701,outputToken="claim-a",output=point,requestRid=51})
    equal(receipt.rid,701) equal(receipt.requestRid,51) equal(receipt.state,"settled")
  end)
end
