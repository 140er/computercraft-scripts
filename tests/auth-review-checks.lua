return function(test, read, mocks)
  local sources={}
  for _,path in ipairs({"server.lua","hub.lua","ssot.lua","atomic.lua","mine-tasks.lua","warehouse-tasks.lua",
      "ar-hud.lua","chat-control.lua","planner-ops.lua","planner-core.lua","planner-enrol.lua","planner-settings.lua","wh2-dispatch.lua"}) do sources[path]=read(path) end
  read=function(path) return assert(sources[path],"fixture source missing: "..path) end
  local UUID = "12345678-1234-1234-1234-123456789abc"
  local OTHER = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  local function config()
    return {controllers={["7"]="paired-controller-secret"},chatNames={"Jeffreyy2","njov10"},
      chatUUIDs={Jeffreyy2=UUID,njov10=OTHER},arControllers={["7"]={name="Jeffreyy2",uuid=UUID}}}
  end
  local function chat(auth)
    local time,replies,calls=100000,{},{}
    local control=dofile("chat-control.lua").new({chatEnabled=true,chatAllowlist={[UUID]="Jeffreyy2"}},{
      now=function() return time end,
      reply=function(_,text) replies[#replies+1]=text end,
      execute=function(action) calls[#calls+1]=action return true end,
    },auth)
    return control,replies,calls,function(ms) time=time+ms end
  end
  test("chat ignores the retired AR allowlist without shared authorization",function()
    local c,replies,calls=chat(nil)
    assert(not c:event("chat","Jeffreyy2","!hub",UUID,false))
    assert(#replies==0 and #calls==0)
  end)
  test("chat requires the actual username to match the shared UUID entry",function()
    local c,replies,calls=chat(config())
    assert(not c:event("chat","Impostor","!hub",UUID,false))
    assert(#replies==0 and #calls==0)
    assert(c:event("chat","Jeffreyy2","!hub",UUID,false))
    local token=assert(replies[#replies]:match("confirm (%S+)"))
    assert(not c:event("chat","Impostor","!confirm "..token,UUID,false))
    assert(#calls==0)
    c:event("chat","Jeffreyy2","!confirm "..token,UUID,false)
    assert(#calls==1)
  end)
  test("chat rate limit spans different commands and isolates UUIDs",function()
    local c,replies,calls,advance=chat(config())
    c:event("chat","Jeffreyy2","!hub",UUID,false)
    local token=assert(replies[#replies]:match("confirm (%S+)"))
    local _,reason=c:event("chat","Jeffreyy2","!recharge",UUID,false)
    assert(reason=="rate-limited" and #replies==1,"different command bypassed UUID cooldown")
    c:event("chat","njov10","!hub",OTHER,false)
    assert(#replies==2,"one UUID blocked another")
    c:event("chat","Jeffreyy2","!confirm "..token,UUID,false)
    assert(#calls==1,"valid confirmation was blocked by its own request")
    for i=1,20 do c:event("chat","Jeffreyy2","!confirm invalid"..i,UUID,false) end
    assert(#replies<=4,"invalid confirmations bypassed UUID reply limit")
    advance(2000)
    local _,nextReason=c:event("chat","Jeffreyy2","!recharge",UUID,false)
    assert(nextReason=="pending")
  end)
  test("hub chat authorization saves raw configuration and preserves it when promotion fails",function()
    local m=mocks.new(false)
    m.env.dofile=function(path) return assert(load(read(path),"@"..path,"t",m.env))() end
    m.files["ar-hud.lua"],m.files["ssot.lua"]=read("ar-hud.lua"),read("ssot.lua")
    m.files["ssot.cfg"]=mocks.encode(config())
    local function command(...)
      assert(load(read("hub.lua"),"@hub.lua","t",m.env))("chat",...)
    end
    command("allow","bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","NewOwner")
    local saved=m.env.textutils.unserialize(m.files["ssot.cfg"])
    assert(saved.schema==nil and saved.chatUUIDs.NewOwner=="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      "hub saved an envelope instead of the raw shared configuration")
    saved.chatUUIDs.NewOwner=saved.chatUUIDs.NewOwner:upper()
    m.files["ssot.cfg"]=mocks.encode(saved)
    command("deny","BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    assert(m.env.textutils.unserialize(m.files["ssot.cfg"]).chatUUIDs.NewOwner==nil)
    local previous=m.files["ssot.cfg"]
    local move=m.env.fs.move
    m.env.fs.move=function(from,to)
      if from=="ssot.cfg.tmp" then error("promotion failed") end
      return move(from,to)
    end
    command("allow","bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","NewOwner")
    assert(m.files["ssot.cfg"]==previous,"failed authorization save replaced the working configuration")
  end)
  local function server(cfg,files)
    local m=mocks.new(false)
    if files then m.files=files end
    m.env.http=nil
    m.env.write=m.env.print
    m.env.sleep=function(delay)
      local timer=m.env.os.startTimer(delay)
      repeat local _,id=m.env.os.pullEvent("timer") until id==timer
    end
    m.env.fs.delete=function(path) m.files[path]=nil end
    m.env.fs.move=function(from,to) assert(m.files[from]) m.files[to],m.files[from]=m.files[from],nil end
    m.env.fs.makeDir=function() end
    m.env.dofile=function(path) return assert(load(read(path),"@"..path,"t",m.env))() end
    for _,path in ipairs({"ssot.lua","atomic.lua","ar-hud.lua","chat-control.lua","planner-ops.lua","planner-core.lua","planner-enrol.lua","planner-settings.lua","wh2-dispatch.lua"}) do m.files[path]=read(path) end
    if cfg then m.files["ssot.cfg"]=mocks.encode(cfg) end
    m.files["ar.cfg"]=mocks.encode({enabled=true,ownerName="Jeffreyy2",ownerUUID=UUID,xrayOres=false})
    m.start(read("server.lua"))
    function m.request(packet,id) m.push("rednet_message",id or 7,packet,"fleetserver") end
    function m.state() return m.env.textutils.unserialize(m.files["server.state"]) end
    local counter=0
    function m.ar(fields,sender)
      counter=counter+1
      local packet={type="ssot",v=1,op="ar-control",boot="ar-test",counter=counter,rid="ar-"..counter,
        expect="ssot_reply",secret="paired-controller-secret",name="Jeffreyy2",uuid=UUID,action="lease"}
      for key,value in pairs(fields or {}) do packet[key]=value end
      m.request(packet,sender)
      return packet
    end
    function m.lastReply()
      for i=#m.messages,1,-1 do if m.messages[i].type=="ssot_reply" then return m.messages[i] end end
    end
    return m
  end
  test("server without SSOT configuration refuses AR hub claims and layer commands",function()
    local m=server()
    m.request({type="hub_get",arClient=true,name="Jeffreyy2",uuid=UUID})
    assert(m.state().arHub==nil,"unconfigured modem became AR owner")
    m.request({type="ar_layer",key="o",name="Jeffreyy2",uuid=UUID})
    assert(m.env.textutils.unserialize(m.files["ar.cfg"]).xrayOres==false)
  end)
  test("AR hub enrolment requires paired secret and the enrolled allowlisted identity",function()
    local m=server(config())
    for _,packet in ipairs({
      {type="hub_get",arClient=true,name="Jeffreyy2",uuid=UUID},
      {type="hub_get",arClient=true,secret="wrong",name="Jeffreyy2",uuid=UUID},
      {type="hub_get",arClient=true,secret="paired-controller-secret",name="njov10",uuid=OTHER},
    }) do
      m.request(packet)
      assert(m.state().arHub==nil,"untrusted AR hub claim was accepted")
    end
    m.ar({secret="wrong"})
    assert(m.state().arHub==nil,"incorrect paired secret was accepted")
    m.ar({name="njov10",uuid=OTHER})
    assert(m.state().arHub==nil,"another allowlisted owner claimed this controller")
    m.ar()
    assert(m.state().arHub==7,"trusted enrolled AR hub was rejected")
    m.ar({action="layer",key="O",enabled=true,name="njov10",uuid=OTHER})
    assert(m.env.textutils.unserialize(m.files["ar.cfg"]).xrayOres==false)
    local enable=m.ar({action="layer",key="O",enabled=true})
    assert(m.env.textutils.unserialize(m.files["ar.cfg"]).xrayOres==true,"trusted layer request failed")
    m.ar({action="layer",key="O",enabled=false})
    m.request(enable)
    assert(m.env.textutils.unserialize(m.files["ar.cfg"]).xrayOres==false,"old authenticated retry reversed a newer layer command")
  end)
  test("recharge rejects legacy spoofed controllers and requires enrolled SSOT authorization",function()
    local cfg=config()
    cfg.controllers["42"]="paired-miner-secret"
    local m=server(cfg)
    m.status(42,{type="status",rechargeAvailable=true})
    m.request({type="command",protocol="minearmy",target=42,message={type="recharge"}})
    for _,packet in ipairs(m.messages) do assert(packet.type~="recharge","legacy command injected recharge") end
    assert(not m.state().recharges[42])
    m.ar({op="recharge",target=42,secret="wrong"})
    m.ar({op="recharge",target=42,name="njov10",uuid=OTHER})
    assert(not m.state().recharges[42])
    m.ar({op="recharge",target=42})
    assert(m.lastReply().ok and m.lastReply().count==1 and m.state().recharges[42])
  end)
  test("recharge delivery survives server restart and clears only on an authenticated receipt",function()
    local cfg=config()
    cfg.controllers["42"]="paired-miner-secret"
    local m=server(cfg)
    m.status(42,{type="status",rechargeAvailable=true})
    local request=m.ar({op="recharge",target=42})
    local pending=m.state().recharges[42]
    assert(pending and pending.rechargeId)
    m.request(request)
    assert(m.state().recharges[42].rechargeId==pending.rechargeId,"request retry enqueued another job")
    local restored=server(cfg,m.files)
    restored.ar({op="recharge-check",secret="paired-miner-secret"},42)
    local delivered=restored.lastReply().recharge
    assert(delivered and delivered.rechargeId==pending.rechargeId,"restart lost an unacknowledged recharge")
    restored.ar({op="recharge-check",secret="wrong",rechargeAck=pending.rechargeId},42)
    assert(restored.state().recharges[42],"forged receipt deleted pending recharge")
    restored.ar({op="recharge-check",secret="paired-miner-secret",rechargeAck=pending.rechargeId},42)
    assert(not restored.state().recharges[42] and not restored.lastReply().recharge)
    assert(not server(cfg,restored.files).state().recharges[42],"acknowledged recharge returned after restart")
  end)
  for _,kind in ipairs({"go","recall","estop"}) do
    for _,targeted in ipairs({true,false}) do
      test("offline recharge stays cancelled after "..(targeted and "targeted " or "broadcast ")..kind.." and restart",function()
        local cfg=config()
        cfg.controllers["42"]="paired-miner-secret"
        local m=server(cfg)
        m.status(42,{type="status",rechargeAvailable=true})
        local request=m.ar({op="recharge",target=42})
        assert(m.state().recharges[42])
        m.time=m.time+60
        m.request({type="command",protocol="minearmy",target=targeted and 42 or nil,message={type=kind}})
        assert(not m.state().recharges[42],"superseding command did not persistently cancel recharge")
        local restored=server(cfg,m.files)
        restored.ar({op="recharge-check",secret="paired-miner-secret"},42)
        assert(not restored.lastReply().recharge,"cancelled recharge returned after restart")
        restored.request(request)
        assert(not restored.state().recharges[42],"old controller retry requeued cancelled recharge")
      end)
    end
  end
end
