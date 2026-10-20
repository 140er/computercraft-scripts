local id=os.getComputerID()
local function readJSON(path)
  if not fs.exists(path) then return nil end
  local h=assert(fs.open(path,"r"))
  local value=textutils.unserializeJSON(h.readAll())
  h.close()
  return value
end
local function writeJSON(path,value)
  local h=assert(fs.open(path,"w"))
  h.write(textutils.serializeJSON(value))
  h.close()
end
local config=assert(readJSON("ar-depth-config.json"),"Missing depth configuration")
local prior=readJSON("ar-depth.json")
if prior and prior.sourceHash~=config.sourceHash then prior=nil end
local state={ok=true,id=id,role=config.role,boot=(prior and prior.boot or 0)+1,
  sourceHash=config.sourceHash,
  started=os.epoch("utc"),activeMs=prior and prior.activeMs or 0,programRunning=false,
  saves={},writes={},requests={},requestErrors={},packets=0,chat={},replies={},
  moves=prior and prior.moves or 0,reportedOres=prior and prior.reportedOres or 0,
  arUpdates=0,arPositions={},arOrePeak=0,errors={},authPackets={},resultId=prior and prior.resultId}
local nativeOpen,nativeDofile=fs.open,dofile
local readStore=nativeDofile("atomic.lua").read
local ssot,nav
local lastSSOT,lastRecharge
local authReplies,authWaiting={}
local function copy(value) return textutils.unserialize(textutils.serialize(value)) end
local function publicReply(reply)
  if not reply then return nil end
  return {rid=reply.rid,ok=reply.ok,error=reply.error,count=reply.count,layers=reply.layers,arOwner=reply.arOwner}
end
local function timing(rows,path,elapsed,ok)
  local row=rows[path] or {count=0,totalMs=0,maxMs=0,failed=0}
  rows[path]=row
  row.count,row.totalMs,row.maxMs=row.count+1,row.totalMs+elapsed,math.max(row.maxMs,elapsed)
  if not ok then row.failed=row.failed+1 end
  if fs.exists(path) then row.bytes=fs.getSize(path) end
end
fs.open=function(path,mode)
  local handle=nativeOpen(path,mode)
  if handle and mode=="w" and not path:find("ar-depth",1,true) then
    local started,close=os.epoch("utc"),handle.close
    handle.close=function(...)
      local result=table.pack(pcall(close,...))
      timing(state.writes,path,os.epoch("utc")-started,result[1])
      if not result[1] then error(result[2],0) end
      return table.unpack(result,2,result.n)
    end
  end
  return handle
end
dofile=function(path)
  local module=nativeDofile(path)
  if path=="atomic.lua" then
    local open=module.store
    module.store=function(file,...)
      local store=open(file,...)
      local save=store.save
      store.save=function(value)
        local started=os.epoch("utc")
        local result=table.pack(pcall(save,value))
        timing(state.saves,file,os.epoch("utc")-started,result[1] and result[2])
        if not result[1] then error(result[2],0) end
        return table.unpack(result,2,result.n)
      end
      return store
    end
  elseif path=="ssot.lua" then
    local open=module.open
    module.open=function(...)
      local api=open(...)
      ssot=api
      local handle=api.handle
      api.handle=function(peer,message)
        local result,err=handle(peer,message)
        local op=type(message)=="table" and message.op or "invalid"
        state.requests[op]=(state.requests[op] or 0)+1
        if result and not result.ok then
          local why=tostring(result.error)
          state.requestErrors[why]=(state.requestErrors[why] or 0)+1
        end
        if result and result.ok and op=="scan" then
          for _,cell in ipairs(message.cells or {}) do
            if type(cell.name)=="string" and cell.name:find("_ore",1,true) then
              state.reportedOres=state.reportedOres+1
            end
          end
        end
        return result,err
      end
      return api
    end
  elseif path=="nav.lua" then
    local open=module.open
    module.open=function(...) nav=open(...) return nav end
  elseif path=="mining.lua" then
    local open=module.open
    module.open=function(cfg)
      state.serviceTarget=cfg.service and cfg.service.targetFuel
      return open(cfg)
    end
  end
  return module
end
if turtle then
  for _,method in ipairs({"forward","back","up","down"}) do
    local move=turtle[method]
    turtle[method]=function(...)
      local ok,why=move(...)
      if ok then state.moves=state.moves+1 end
      return ok,why
    end
  end
end
local nativeSend,nativeBroadcast=rednet.send,rednet.broadcast
local function sent(message,protocol)
  if protocol=="minearmy" and type(message)=="table" and message.type=="status" then state.status=message end
end
rednet.send=function(peer,message,protocol)
  sent(message,protocol)
  if peer==0 and protocol=="fleetserver" and type(message)=="table" and message.type=="ssot" then
    lastSSOT=copy(message)
  end
  return nativeSend(peer,message,protocol)
end
rednet.broadcast=function(message,protocol) sent(message,protocol) return nativeBroadcast(message,protocol) end
local nativeFind,nativeWrap=peripheral.find,peripheral.wrap
local wrapped=setmetatable({},{__mode="k"})
local function observe(device)
  if not device or wrapped[device] then return device end
  local name=peripheral.getName(device)
  wrapped[device]=true
  if peripheral.hasType(name,"ar_controller") then
    local line,update,delete=device.drawLine3D,device.update,device.delete
    device.drawLine3D=function(element,color,x,y,z,...)
      local result=line(element,color,x,y,z,...)
      local turtleID=element:match("^ssot%-ar:turtle:(%d+):edge:1$")
      if turtleID then state.arPositions[turtleID]={x=x,y=y,z=z} end
      return result
    end
    device.delete=function(element)
      local result=delete(element)
      local turtleID=element:match("^ssot%-ar:turtle:(%d+):edge:1$")
      if turtleID then state.arPositions[turtleID]=nil end
      return result
    end
    device.update=function(...) state.arUpdates=state.arUpdates+1 return update(...) end
  elseif peripheral.hasType(name,"chat_box") then
    local reply=device.sendMessageToPlayer
    device.sendMessageToPlayer=function(message,player,...)
      state.replies[#state.replies+1]={at=os.epoch("utc"),name=player,text=message}
      if #state.replies>32 then table.remove(state.replies,1) end
      return reply(message,player,...)
    end
  end
  return device
end
peripheral.find=function(...)
  local devices=table.pack(nativeFind(...))
  for i=1,devices.n do devices[i]=observe(devices[i]) end
  return table.unpack(devices,1,devices.n)
end
peripheral.wrap=function(name) return observe(nativeWrap(name)) end
http,_G.http=nil,nil
local function inventory()
  local counts={}
  for slot=1,16 do
    local item=turtle.getItemDetail(slot)
    if item then counts[item.name]=(counts[item.name] or 0)+item.count end
  end
  return counts
end
local lastSample=os.epoch("utc")
local function sample()
  local now=os.epoch("utc")
  state.activeMs=state.activeMs+math.min(10000,math.max(0,now-lastSample))
  lastSample=now
  state.time,state.free,state.capacity=now,fs.getFreeSpace("/"),fs.getCapacity("/")
  state.bytes={}
  for _,path in ipairs({"server.state","ssot.state","nav.state","mining.state","miner.state"}) do
    if fs.exists(path) then state.bytes[path]=fs.getSize(path) end
  end
  if turtle then
    state.fuel,state.inventory=turtle.getFuelLevel(),inventory()
    if nav then state.pose,state.control=nav.pose(),nav.controlState() end
    if fs.exists("mining-warehouse.state") then
      local service=readStore("mining-warehouse.state")
      state.service=service and service.value
    end
    if fs.exists("mining.state") then
      local mining=readStore("mining.state")
      mining=mining and mining.value
      if mining then state.mining={phase=mining.phase,reason=mining.reason,progress=mining.progress,task=mining.task} end
    end
  end
  if ssot then
    state.ssot=ssot.state(function(s)
      local out={revision=s.rev,chunks=0,cells=0,ores=0,poses={},tasks={},authCounters={}}
      for _,peer in ipairs({20,21,22}) do
        local client=s.clients[peer] or s.clients[tostring(peer)]
        if client then out.authCounters[tostring(peer)]=client.counter end
      end
      for peer,p in pairs(s.poses) do out.poses[tostring(peer)]={x=p.x,y=p.y,z=p.z,dim=p.dim} end
      for _,chunk in pairs(s.chunks) do
        out.chunks=out.chunks+1
        for _,n in pairs(chunk.cells) do
          out.cells=out.cells+1
          if n~=0 and s.names[n]:find("_ore",1,true) then out.ores=out.ores+1 end
          if out.cells%512==0 then os.queueEvent("ar_depth_sample") os.pullEvent("ar_depth_sample") end
        end
      end
      for _,task in ipairs(s.mining and s.mining.tasks or {}) do
        out.tasks[#out.tasks+1]={owner=task.owner,status=task.status,progress=task.progress}
      end
      return out
    end)
    local saved=readStore("server.state")
    saved=saved and (saved.value or saved)
    if saved then
      state.controls={arHub=saved.arHub,view3D=saved.view3D,arCounters=saved.arCounters,
        recharges={},rechargeRequests=saved.rechargeRequests,commandSeq=saved.commandSeq}
      for peer,delivery in pairs(saved.recharges or {}) do state.controls.recharges[tostring(peer)]=delivery end
    end
    local layers=readStore("ar.cfg")
    if layers then
      state.layers={P=layers.proHud,T=layers.xrayTurtles,O=layers.xrayOres,A=layers.xrayTunnels}
    end
  end
  local ar=nativeFind("ar_controller")
  if ar then
    local ok,elements=pcall(ar.getAllElements)
    if ok then
      local total,ores=0,0
      for element in pairs(elements) do
        total=total+1
        if tostring(element):match("^ssot%-ar:ore:") then ores=ores+1 end
      end
      state.arElements,state.arOrePeak=total,math.max(state.arOrePeak,ores)
    end
  end
  writeJSON("ar-depth.json",state)
end
local function monitor()
  local timer=os.startTimer(2)
  local logAt=0
  while true do
    local ev,a,b,c,d=os.pullEvent()
    if ev=="rednet_message" then
      state.packets=state.packets+1
      if type(b)=="table" and b.authProbe then
        state.authPackets[#state.authPackets+1]={at=os.epoch("utc"),peer=a,protocol=c,
          probe=b.authProbe,type=b.type,op=b.op,rid=b.rid,counter=b.counter}
        if #state.authPackets>64 then table.remove(state.authPackets,1) end
      end
    elseif ev=="chat" then
      state.chat[#state.chat+1]={at=os.epoch("utc"),name=a,message=b,uuid=c,hidden=d}
      if #state.chat>32 then table.remove(state.chat,1) end
    elseif ev=="timer" and a==timer then
      sample()
      if state.time>=logAt then
        local h=assert(fs.open("ar-depth-metrics.jsonl","a"))
        h.writeLine(textutils.serializeJSON({time=state.time,boot=state.boot,activeMs=state.activeMs,
          bytes=state.bytes,free=state.free,saves=state.saves,moves=state.moves,
          phase=state.status and state.status.phase,revision=state.ssot and state.ssot.revision,
          chunks=state.ssot and state.ssot.chunks,cells=state.ssot and state.ssot.cells,
          reportedOres=state.reportedOres,arUpdates=state.arUpdates}))
        h.close()
        logAt=state.time+60000
      end
      timer=os.startTimer(2)
    end
  end
end
local function controller()
  peripheral.find("modem",rednet.open)
  local client=dofile("ssot-client.lua").new({server=0,secret=config.secret,timeout=5,counterFile="ar-depth.counter"})
  local function receive()
    while true do
      local _,peer,message,protocol=os.pullEvent("rednet_message")
      if peer==0 and protocol=="fleetserver" and type(message)=="table"
        and message.type=="ssot_reply" and message.auth==config.secret and message.rid==authWaiting then
        authReplies[message.rid]=publicReply(message)
      end
      client.dispatch(peer,message,protocol)
    end
  end
  local function awaitReply(packet)
    authReplies[packet.rid]=nil
    authWaiting=packet.rid
    assert(nativeSend(0,packet,"fleetserver"),"Native replay modem is closed")
    local timer=os.startTimer(5)
    while not authReplies[packet.rid] do
      local ev,value=os.pullEvent()
      if ev=="timer" and value==timer then break end
    end
    os.cancelTimer(timer)
    authWaiting=nil
    return authReplies[packet.rid]
  end
  local function ownerFields(fields)
    fields.name,fields.uuid=config.ownerName,config.ownerUUID
    return fields
  end
  local function arCall(fields)
    local reply,why=client.call("ar-control",ownerFields(fields))
    assert(reply and reply.ok,why)
    return reply
  end
  local function worker()
    while true do
      local request=readJSON("ar-depth-request.json")
      if request and request.id~=state.resultId then
        state.commandResult={ok=false}
        local ok,err=pcall(function()
          if request.action=="auth-raw" then
            local rows={}
            local function send(label,packet,claimed)
              packet.authProbe=request.id..":"..label
              if claimed then
                local modem=assert(peripheral.find("modem"))
                modem.transmit(0,id,{nMessageID=os.epoch("utc")*1000+#rows,nRecipient=0,
                  nSender=claimed,message=packet,sProtocol="fleetserver"})
              else assert(rednet.send(0,packet,"fleetserver"),"Native attacker modem is closed") end
              rows[#rows+1]={probe=packet.authProbe,emitter=id,claimedPeer=claimed or id,type=packet.type}
            end
            for _,claimed in ipairs({false,20}) do
              local suffix=claimed and "-spoofed" or "-own-id"
              send("claim"..suffix,{type="hub_get",arClient=true,name="WrongOwner",uuid=config.ownerUUID},claimed)
              send("layer"..suffix,{type="ar_layer",key="O",enabled=false,name="WrongOwner",uuid=config.ownerUUID},claimed)
              send("recharge"..suffix,{type="command",protocol="minearmy",target=7,message={type="recharge"}},claimed)
              send("unpaired-ssot"..suffix,ownerFields({type="ssot",v=1,op="ar-control",action="lease",
                rid=request.id..suffix,boot="native-unpaired",counter=1,secret=config.secret,expect="ssot_reply"}),claimed)
            end
            state.commandResult={ok=true,packets=rows,transport="real wireless modem; nSender from installed CC ROM"}
          elseif request.action=="auth-owner" then
            local rows={}
            for _,op in ipairs({"ar-control","recharge"}) do
              for _,wrong in ipairs({"name","uuid"}) do
                local fields=ownerFields({action="lease",target=7,authProbe=request.id..":"..op..":"..wrong})
                fields[wrong]=wrong=="name" and "WrongOwner" or "00000000-0000-0000-0000-000000000000"
                local reply,why=client.call(op,fields)
                assert(reply and reply.ok==false,"Owner mismatch was not explicitly rejected: "..tostring(why))
                rows[#rows+1]=publicReply(reply)
              end
            end
            if id==21 then
              local reply,why=client.call("ar-control",ownerFields({action="lease",authProbe=request.id..":unenrolled"}))
              assert(reply and reply.ok==false,"Unenrolled controller was not rejected: "..tostring(why))
              rows[#rows+1]=publicReply(reply)
            end
            state.commandResult={ok=true,rejections=rows,counter=lastSSOT.counter}
          elseif request.action=="auth-counters" then
            local rows={}
            for i,counter in ipairs({-1,1.5,"42",{},1e100,2147483648,9007199254740992}) do
              for _,op in ipairs({"ar-control","recharge"}) do
                local probe=request.id..":"..i..":"..op
                local packet=ownerFields({type="ssot",v=1,op=op,rid=probe,boot="native-auth-probe",
                  counter=counter,secret=config.secret,expect="ssot_reply",action="lease",target=7,authProbe=probe})
                assert(rednet.send(0,packet,"fleetserver"),"Native counter test modem is closed")
                rows[#rows+1]={probe=probe,counter=counter,op=op,emitter=id,claimedPeer=id}
              end
            end
            state.commandResult={ok=true,packets=rows}
          elseif request.action=="auth-ar-replay" then
            arCall({action="lease",authProbe=request.id..":lease"})
            arCall({action="layer",key="O",enabled=false,authProbe=request.id..":old-off"})
            local old=copy(lastSSOT)
            arCall({action="layer",key="O",enabled=true,authProbe=request.id..":new-on"})
            local current=copy(lastSSOT)
            local replayedAt=os.epoch("utc")
            local reply=awaitReply(old)
            assert(not reply or reply.ok==false or reply.layers and reply.layers.O==true,"AR replay changed the restored ore layer")
            state.commandResult={ok=true,oldCounter=old.counter,currentCounter=current.counter,reply=reply,
              responseObserved=reply~=nil,packets={{probe=old.authProbe,claimedPeer=id,after=replayedAt}}}
          elseif request.action=="auth-recharge-replay" then
            local stored=lastRecharge or readJSON("ar-depth-recharge-packet.json")
            assert(stored and stored.sourceHash==config.sourceHash,"No successful native recharge packet was captured")
            local replayedAt=os.epoch("utc")
            local reply=awaitReply(stored.packet)
            state.commandResult={ok=true,original=stored.reply,counter=stored.packet.counter,rid=stored.packet.rid,reply=reply,
              responseObserved=reply~=nil,packets={{probe=stored.packet.authProbe,claimedPeer=id,after=replayedAt}}}
          elseif request.action=="mine-config" then
            local reply,why=client.call("mine-config",{zone=request.zone})
            assert(reply and reply.ok,why)
            state.commandResult=reply
          elseif request.action=="service-site" then
            local reply,why=client.call("wh-site",{name=request.name,site=request.site})
            assert(reply and reply.ok,why)
            state.commandResult=reply
          elseif request.action=="snapshot-burst" then
            local started=os.epoch("utc")
            for _=1,request.count or 32 do
              local reply,why=client.snapshot({chunk=request.chunk})
              assert(reply and reply.ok,why)
            end
            state.commandResult={ok=true,count=request.count or 32,started=started,finished=os.epoch("utc")}
          elseif request.action=="command" then
            assert(request.command=="go" or request.command=="estop" or request.command=="recall" or request.command=="recharge")
            if request.command=="recharge" then
              local reply,why=client.call("recharge",{name=config.ownerName,uuid=config.ownerUUID,target=request.target,
                authProbe=request.id..":accepted-recharge"})
              assert(reply and reply.ok,why)
              lastRecharge={sourceHash=config.sourceHash,packet=copy(lastSSOT),reply=publicReply(reply)}
              writeJSON("ar-depth-recharge-packet.json",lastRecharge)
              state.commandResult=reply
            else
              rednet.send(0,{type="command",protocol="minearmy",target=request.target,message={type=request.command}},"fleetserver")
              state.commandResult={ok=true,sent=request.command,target=request.target}
            end
          else error("Unknown depth action") end
        end)
        if not ok then state.commandResult={ok=false,error=tostring(err)} end
        state.commandResult.completedAt=os.epoch("utc")
        state.resultId=request.id
        sample()
      end
      sleep(.2)
    end
  end
  parallel.waitForAny(receive,worker)
end
local ok,err=pcall(function()
  assert(fs.getCapacity("/")==config.spaceLimit,"Unexpected native disk capacity")
  while not peripheral.find("modem") do sleep(.2) end
  if turtle then
    local deadline=os.epoch("utc")+120000
    repeat
      local x,y,z=gps.locate(2)
      if x then state.initialGPS={x=x,y=y,z=z} break end
      sleep(1)
    until os.epoch("utc")>=deadline
    assert(state.initialGPS,"Native GPS did not become available")
  end
  state.programRunning=true
  sample()
  parallel.waitForAny(function()
    if config.role=="controller" then controller()
    else
      if config.role=="miner" and config.surveys then
        local surveyed=readJSON("ar-depth-survey.json")
        if not surveyed or surveyed.sourceHash~=config.sourceHash then
          for _,p in ipairs(config.surveys) do
            assert(loadfile("miner.lua","t",_ENV))("nav","survey",tostring(p.x),tostring(p.y),tostring(p.z))
            local actual=nav and nav.pose()
            assert(actual and actual.x==p.x and actual.y==p.y and actual.z==p.z,"Native service survey did not reach its destination")
          end
          writeJSON("ar-depth-survey.json",{ok=true,sourceHash=config.sourceHash})
        end
      end
      if config.role=="miner" then
        state.surveyed=true
        sample()
        while not fs.exists("ar-depth-start.json") do sleep(.2) end
      end
      assert(loadfile(config.role..".lua","t",_ENV))()
    end
    error("Production program exited")
  end,monitor)
end)
if not ok then
  state.ok,state.programRunning,state.error=false,false,tostring(err)
  state.errors[#state.errors+1]={time=os.epoch("utc"),error=tostring(err)}
  pcall(sample)
end
