local id=os.getComputerID()
local restart=fs.exists("ar-native.json")
local resultName=restart and "ar-restart.json" or "ar-native.json"
local function write(name,value)
  local f=assert(fs.open(name,"w"))
  f.write(textutils.serializeJSON(value))
  f.close()
end
local function count(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
local function run()
  while not peripheral.find("modem") do sleep(0.2) end
  peripheral.find("modem",rednet.open)
  assert(fs.getCapacity("/") == 4000000,"Wrong computer disk capacity")
  if turtle then
    local x=2+id*2
    if not restart then
      assert(turtle.forward(),"Native turtle forward failed")
      assert(turtle.back(),"Native turtle return failed")
    end
    local status={type="status",id=id,kind="miner",name="Miner "..id,label="Miner "..id,x=x,y=65,z=-3,dim="minecraft:overworld",
      fuel=turtle.getFuelLevel(),maxFuel=turtle.getFuelLimit(),state=id==2 and "LOW FUEL" or "ready"}
    write(resultName,{ok=true,nativeTurtle=true,movement=not restart,fuel=status.fuel,restart=restart})
    while true do
      status.fuel=turtle.getFuelLevel()
      rednet.broadcast(status,"pr6-native-fleet")
      rednet.broadcast(status,"minearmy")
      sleep(1)
    end
  end
  local ar=assert(peripheral.find("ar_controller"),"Real cc_ar controller missing")
  write("ar-peripheral.json",{ok=true,name=peripheral.getName(ar),methods=peripheral.getMethods(peripheral.getName(ar))})
  if id==4 then
    write(resultName,{ok=true,observer=true,restart=restart})
    while true do sleep(1) end
  end
  local chat=assert(peripheral.find("chat_box"),"Real AP chat_box missing")
  local H=dofile("ar-hud.lua")
  local cfg=H.defaults()
  cfg.enabled=true
  cfg.origin={x=1,y=66,z=0,dim="minecraft:overworld"}
  cfg.anchors={hub={x=1,y=66,z=0,dim="minecraft:overworld"}}
  cfg.chatEnabled=true
  cfg.chatAllowlist={}
  local fleet={}
  local deadline=os.epoch("utc")+60000
  while count(fleet)<3 and os.epoch("utc")<deadline do
    local sender,message,protocol=rednet.receive("pr6-native-fleet",2)
    if sender and type(message)=="table" then fleet[sender]=message end
  end
  assert(count(fleet)==3,"Three real turtle reports required")
  local snap={turtles={},world_map={
    {x=5,y=65,z=-4,dim="minecraft:overworld",state="SOLID",name="minecraft:diamond_ore"},
    {x=7,y=65,z=-4,dim="minecraft:overworld",state="SOLID",name="minecraft:deepslate_iron_ore"}
  },anchors=cfg.anchors,orders={},revision=1}
  for i=1,3 do snap.turtles[#snap.turtles+1]=fleet[i] end
  local mem={}
  ar.drawText2D("pr6-observer", -1, 4, 240, "Real cc_ar fixture", false)
  ar.update()
  H.render(ar,snap,mem,cfg)
  local elements=ar.getAllElements()
  assert(count(elements)>10,"HUD did not create native elements")
  local draws=0
  local proxy=setmetatable({},{__index=function(_,key)
    return function(...) draws=draws+1 return ar[key](...) end
  end})
  H.render(proxy,snap,mem,cfg)
  assert(draws==0,"Unchanged frame caused native writes")
  H.clear(ar,mem)
  local remaining=ar.getAllElements()
  assert(remaining["pr6-observer"],"Scoped cleanup deleted another namespace")
  H.render(ar,snap,mem,cfg)
  write("ar-elements.json",{ok=true,elements=ar.getAllElements()})
  write(resultName,{ok=true,restart=restart,realController=true,realChatBox=true,
    turtles=3,elements=count(elements),unchangedFrameCalls=draws,scopedCleanup=true,
    coverage="Native renderer and turtle fixture. Production ownership is exercised in Gate A."})
  local Chat=dofile("chat-control.lua")
  local events={}
  local actions={}
  local controller=Chat.new(cfg,{
    save=function() return true end,
    reply=function(username,text)
      write("ar-chat-reply.json",{ok=true,username=username,text=text,time=os.epoch("utc")})
      chat.sendMessageToPlayer(text,username)
    end,
    execute=function(action,args,uuid)
      actions[#actions+1]={action=action,args=args,uuid=uuid}
      if action=="pro" then cfg.proHud=not cfg.proHud
      elseif action=="xray" then cfg.xrayTurtles=not cfg.xrayTurtles cfg.xrayOres=cfg.xrayTurtles
      else return false,"Movement integration is not enabled in this renderer fixture" end
      return true,"Applied "..action
    end
  })
  while true do
    local ev={os.pullEvent()}
    if ev[1]=="chat" then
      events[#events+1]={username=ev[2],message=ev[3],uuid=ev[4],hidden=ev[5]}
      if fs.exists("ar-enroll-test-player") and ev[2]=="SSOTProof" then
        cfg.chatAllowlist[ev[4]]="SSOTProof"
      end
      controller:event(table.unpack(ev))
      write("ar-chat-events.json",{ok=true,events=events,actions=actions})
      H.render(ar,snap,mem,cfg)
    elseif ev[1]=="rednet_message" and ev[4]=="pr6-native-fleet" then
      local message=ev[3]
      if type(message)=="table" and message.id then snap.turtles[message.id]=message end
      H.render(ar,snap,mem,cfg)
    end
  end
end
local ok,err=pcall(run)
if not ok then write(resultName,{ok=false,error=tostring(err)}) end
