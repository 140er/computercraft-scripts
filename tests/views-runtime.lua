local runtime=...
local id=os.getComputerID()
local secret="test-secret-123456"
local dim="minecraft:overworld"
local function json(path,v)
  local f=assert(fs.open(path,"w")) f.write(textutils.serializeJSON(v)) f.close()
end
local function write(path,v)
  local f=assert(fs.open(path,"w")) f.write(textutils.serialize(v)) f.close()
end
local checks={}
local function check(name,fn)
  local ok,err=pcall(fn)
  checks[#checks+1]={name=name,ok=ok,error=not ok and tostring(err) or nil}
  json("views-checks.json",checks)
  assert(ok,name..": "..tostring(err))
end
local function result(ok,err)
  json("sandbox-result.json",{ok=ok,booted=true,errors=err and {tostring(err)} or {},checks=checks,free=fs.getFreeSpace("/"),lines={"views production runtime"}})
end
local function forever() while true do sleep(1) end end
peripheral.find("modem",rednet.open)
http=nil _G.http=nil
local ok,err=pcall(function()
  if id==0 then
    parallel.waitForAny(function() assert(loadfile("server.lua","t",_ENV))() end,function()
      while true do
        local from,m,protocol=rednet.receive()
        if protocol=="views_boot" and runtime=="sandbox" then rednet.send(from,true,"views_start") end
        if protocol=="views_test" and from==4 then
          if m=="done" then result(true)
          elseif type(m)=="table" and m.reboot and m.reboot>=1 and m.reboot<=3 then
            if runtime=="sandbox" then peripheral.call("computer_"..m.reboot,"reboot")
            else json("restart-request-"..m.reboot..".json",{id=m.reboot,reason=m.reason}) end
          end
        end
      end
    end)
  elseif id>=1 and id<=3 then
    local z=(id-2)*3
    local function preserveRecovery(x,y,pz)
      if not fs.exists("nav.state") then return end
      local folder="recovery-"..os.epoch("utc")
      fs.makeDir(folder)
      fs.copy("nav.state",folder.."/nav.state")
      if fs.exists("ssot.counter") then fs.copy("ssot.counter",folder.."/ssot.counter") end
      json(folder.."/actual-pose.json",{dim=dim,x=x,y=y,z=pz})
    end
    if runtime=="sandbox" then
      local pending,serial,boot={},0,tostring(os.epoch("utc"))
      local function world(op,args)
        serial=serial+1 local rid=boot..":"..serial
        local deadline,nextSend=os.clock()+30,0
        while not pending[rid] and os.clock()<deadline do
          if os.clock()>=nextSend then
            rednet.send(5,{op=op,args=args or {},rid=rid},"ssot_world")
            nextSend=os.clock()+.5
          end
          sleep(.01)
        end
        local answer=assert(pending[rid],"emulated world timeout") pending[rid]=nil return answer
      end
      local function receive()
        while true do
          local from,m=rednet.receive("ssot_world_reply")
          if from==5 then pending[m.rid]=m.values end
        end
      end
      turtle=dofile("turtle.lua").new(world) _G.turtle=turtle
      gps.locate=function() local p=world("pose") return p[1],p[2],p[3] end
      local function miner()
        preserveRecovery(gps.locate())
        write("miner.cfg",{home={x=-2,y=65,z=z},facing=1,spine=1,viewsControl=true,
          ssot={enabled=true,server=0,secret=secret,dimension=dim,timeout=10},
          nav={enabled=true,bounds={min={dim=dim,x=-4,y=65,z=-4},max={dim=dim,x=4,y=65,z=4}}}})
        assert(loadfile("miner.lua","t",_ENV))()
      end
      parallel.waitForAny(receive,miner,function()
        while true do
          sleep(1)
          local p=world("pose")
          if p[1]==1 and p[2]==65 and p[3]==z then result(true) forever() end
        end
      end)
    else
      preserveRecovery(gps.locate(3))
      if not fs.exists("miner.cfg") then
        write("miner.cfg",{home={x=-2,y=65,z=z},facing=1,spine=1,viewsControl=true,
          ssot={enabled=true,server=0,secret=secret,dimension=dim,timeout=10},
          nav={enabled=true,bounds={min={dim=dim,x=-4,y=65,z=-4},max={dim=dim,x=4,y=65,z=4}}}})
      end
      parallel.waitForAny(function() assert(loadfile("miner.lua","t",_ENV))() end,function()
        while true do
          sleep(2)
          local x,y,pz=gps.locate(3)
          if x and math.floor(x+.5)==1 and math.floor(y+.5)==65 and math.floor(pz+.5)==z then result(true) forever() end
        end
      end)
    end
  elseif id==4 then
    local client=dofile("ssot-client.lua").new({server=0,secret=secret,timeout=10})
    local statuses={}
    local function receive()
      while true do
        local _,from,m,proto=os.pullEvent("rednet_message")
        client.dispatch(from,m,proto)
        if proto=="minearmy" and type(m)=="table" and m.type=="status" then
          statuses[tostring(from)]=m
          json("views-statuses.json",statuses)
        end
      end
    end
    local function run()
      sleep(5)
      check("real authenticated scan and snapshot",function()
        local pose={dim=dim,x=4,y=65,z=-4}
        assert(client.resync(pose))
        local revision=0
        if fs.exists("seed-revision") then
          local f=assert(fs.open("seed-revision","r")) revision=assert(tonumber(f.readAll())) f.close()
        end
        local cells={}
        for x=-4,4 do for z=-4,4 do
          cells[#cells+1]={dim=dim,x=x,y=65,z=z,
            name=z==-4 and (x==-4 or x==4) and "computercraft:computer_advanced" or false}
        end end
        for x=-2,2 do cells[#cells+1]={dim=dim,x=x,y=66,z=4,name="minecraft:iron_ore"} end
        for start=fs.exists("views-ready.json") and #cells+1 or 1,#cells,32 do
          local batch={} for n=start,math.min(start+31,#cells) do batch[#batch+1]=cells[n] end
          local r,e=client.call("scan",{pose=pose,revision=revision,cells=batch})
          assert(r and r.ok,e or r and r.error)
          revision=r.revision
          local f=assert(fs.open("seed-revision","w")) f.write(tostring(revision)) f.close()
        end
        local source=dofile("view-source.lua").new(client,{radius=4,maxChunks=8,maxCells=256,warehouse=false})
        local function refresh()
          local deadline=os.clock()+180
          repeat
            local good,why=source.refresh({dim=dim,x=0,y=65,z=0})
            if good then return end
            local log=assert(fs.open("snapshot-retries.log","a")) log.writeLine(tostring(why)) log.close()
            sleep(1)
          until os.clock()>deadline
          error("snapshot refresh never recovered")
        end
        refresh()
        assert(#source.scene().cells>0,"empty scene")
        local previous=source.scene()
        local real=client.call
        client.call=function() return nil,"injected transport loss" end
        assert(not source.refresh({dim=dim,x=0,y=65,z=0}))
        assert(source.scene().stale,"lost connection did not mark stale")
        client.call=real
        refresh()
        assert(not source.scene().stale,"reconnect stayed stale")
      end)
      check("three production miners reach authenticated view targets",function()
        local deadline,nextRetry,attempt,reboots=os.clock()+360,0,0,{}
        while os.clock()<deadline do
          local reached=0
          for tid=1,3 do
            local p=statuses[tostring(tid)]
            if p and p.x==1 and p.y==65 and p.z==(tid-2)*3 and p.dim==dim then reached=reached+1 end
          end
          if reached==3 then return end
          if os.clock()>=nextRetry then
            attempt=attempt+1
            for tid=1,3 do
              local p=statuses[tostring(tid)]
              if not p or p.x~=1 then
                if p and tostring(p.status):find("navigation needs recovery",1,true) then
                  reboots[tid]=(reboots[tid] or 0)+1
                  assert(reboots[tid]<=3,"turtle recovery exceeded three reboots")
                  json("restart-"..tid.."-"..attempt..".json",{id=tid,status=p,attempt=attempt})
                  rednet.send(0,{reboot=tid,reason=p.status},"views_test")
                  sleep(2)
                end
                rednet.send(0,{type="command",rid="views-"..attempt.."-"..tid,sequence=os.epoch("utc")+tid,
                  target=tid,protocol="minearmy",secret=secret,viewControl=true,
                  message={type="view_move",point={dim=dim,x=1,y=65,z=(tid-2)*3}}},"fleetserver")
                sleep(.2)
              end
            end
            nextRetry=os.clock()+30
          end
          sleep(1)
        end
        error("view targets not reached; inspect views-statuses.json")
      end)
      json(fs.exists("views-ready.json") and "views-restarted.json" or "views-ready.json",{ok=true,checks=checks})
      rednet.send(0,"done","views_test")
      if runtime=="sandbox" then rednet.send(5,{op="done"},"ssot_world") end
      result(true)
      forever()
    end
    parallel.waitForAny(receive,run)
  elseif id==9 then
    check("real Tom secondary backend",function()
      local V=dofile("fleetview.lua")
      local gpu=assert(peripheral.find("tm_gpu"),"missing Tom GPU")
      local view,why=V.gpuOpen(gpu)
      assert(view,why)
      view.cam.auto=false
      local list={}
      for tid=1,3 do
        list[#list+1]=V.entry(tid,"miner",{label="Miner "..tid,dim=dim,x=1,y=65,z=(tid-2)*3,
          phase="home",status="View target",facing="east",fuel=9997},0)
      end
      local start=os.epoch("utc")
      V.gpuDraw(view,list,{title="Tom secondary"})
      json("toms-gpu.json",{ok=true,width=view.w,height=view.h,frames=view.frames,millis=os.epoch("utc")-start})
    end)
    result(true) forever()
  else
    if runtime=="sandbox" then assert(periphemu.create("right","monitor")) end
    local gpuRun={generations=0,draws={},paused=false}
    do
      local original=dofile
      dofile=function(path)
        local module=original(path)
        if path=="ssot-client.lua" then
          local create=module.new
          module.new=function(cfg)
            local client=create(cfg)
            local call=client.call
            local sites={
              iron={kind="source",pose={dim=dim,x=-4,y=65,z=0,h=3},side="front"},
              drop={kind="drop",pose={dim=dim,x=4,y=65,z=0,h=1},side="front"},
              charge={kind="charge",pose={dim=dim,x=0,y=65,z=4,h=2},side="front"}}
            client.call=function(op,fields)
              if op~="wh-sites" then return call(op,fields) end
              if fields and fields.name then return {ok=true,site=sites[fields.name]} end
              return {ok=true,names={"charge","drop","iron"}}
            end
            json("warehouse-fixture.json",{boundary="PR4 wh-sites response fixture; all map snapshots use real SSOT",sites=sites})
            return client
          end
          return module
        end
        if path~="directview.lua" or runtime~="minecraft" or id==8 then return module end
        local create=module.new
        module.new=function(gpu,cfg)
          local view,why=create(gpu,cfg)
          if not view then error("DirectGPU initialization: "..tostring(why)) end
          gpuRun.generations=gpuRun.generations+1
          gpuRun.view,gpuRun.cfg,gpuRun.gpu=view,cfg,gpu
          local draw=view.draw
          gpuRun.draw=draw
          local event=view.event
          view.event=function(tuple)
            local picked=event(tuple)
            if fs.exists("client-click-arm") then
              gpuRun.events=gpuRun.events or {}
              gpuRun.events[#gpuRun.events+1]={tuple=tuple,picked=picked}
              json("client-click-events.json",gpuRun.events)
            end
            return picked
          end
          view.draw=function(scene,camera)
            if gpuRun.paused then return true,"test paused" end
            gpuRun.scene,gpuRun.camera=scene,camera
            local at=os.epoch("utc")
            local good,reason=draw(scene,camera)
            gpuRun.draws[#gpuRun.draws+1]={ok=good,reason=reason,millis=os.epoch("utc")-at,mode=camera.mode}
            return good,reason
          end
          return view
        end
        return module
      end
      _G.dofile=dofile
    end
    write("views.cfg",{enabled=true,mode=id==8 and "warehouse" or "pro",server=0,secret=secret,
      dim=dim,center={x=0,y=65,z=0},radius=runtime=="sandbox" and 1 or 4,gpu=runtime=="minecraft" and id~=8 and "right" or nil,
      monitor=runtime=="minecraft" and "back" or "right",width=320,height=240,camera="iso",timeout=10})
    parallel.waitForAny(function() assert(loadfile("hub.lua","t",_ENV))(id==8 and "warehouse" or "pro") end,function()
      sleep(15)
      if runtime=="minecraft" and id~=8 then
        check("real DirectGPU display exists",function()
          local gpu=assert(peripheral.find("directgpu"),"missing real DirectGPU")
          local displays=gpu.listDisplays()
          assert(type(displays)=="table" and next(displays),"DirectGPU has no display")
          json("directgpu-displays.json",displays)
          json("directgpu-resources.json",gpu.getResourceStats())
        end)
        check("real cached frames throttle and camera modes",function()
          assert(gpuRun.scene and #gpuRun.scene.cells>0,"no rendered world snapshot")
          gpuRun.paused=true
          local A=dofile("atomic.lua")
          local scene,camera=A.copy(gpuRun.scene),A.copy(gpuRun.camera)
          gpuRun.cfg.interval=0
          assert(gpuRun.draw(scene,camera))
          local good,reason=gpuRun.draw(scene,camera)
          assert(good and reason=="unchanged","unchanged scene was not cached")
          gpuRun.cfg.interval=60
          camera.yaw=(camera.yaw or 45)+1
          good,reason=gpuRun.draw(scene,camera)
          assert(good and reason=="throttled","nonzero interval was not enforced")
          gpuRun.cfg.interval=0
          local measurements={}
          for _,mode in ipairs({"top","side","iso"}) do
            camera.mode=mode
            local start=os.epoch("utc")
            good,reason=gpuRun.draw(scene,camera)
            assert(good and reason=="drawn","camera frame failed "..tostring(reason))
            measurements[#measurements+1]={mode=mode,millis=os.epoch("utc")-start}
          end
          local start=os.epoch("utc")
          for yaw=0,315,45 do
            camera.yaw=yaw
            assert(gpuRun.draw(scene,camera))
          end
          measurements[#measurements+1]={mode="eight orbit frames",millis=os.epoch("utc")-start}
          json("directgpu-measurements.json",{frames=measurements,resources=gpuRun.gpu.getResourceStats(),
            explicitMonitor=gpuRun.cfg.monitor,generations=gpuRun.generations,cache=true,throttle=true,
            bandwidthMeasured=false,wiredSelectionTested=false})
          gpuRun.cfg.interval=.2
          gpuRun.paused=false
        end)
        if fs.exists("views-gpu-checks.lua") then
          check("real adjacent and wired selection with multiple displays",function()
            gpuRun.paused=true
            local evidence=dofile("views-gpu-checks.lua").run(gpuRun.gpu,{
              selectors={"back"},existingDisplayId=gpuRun.view.displayId,width=320,height=240})
            json("directgpu-selection.json",evidence)
            gpuRun.paused=false
            assert(evidence.ok,"see directgpu-selection.json")
          end)
        end
      end
      if id==6 and runtime=="sandbox" then
        os.queueEvent("char","p") sleep(1) os.queueEvent("char","p")
        os.queueEvent("monitor_resize","right")
        sleep(1) periphemu.remove("right")
        sleep(1) assert(periphemu.create("right","monitor"))
      end
      result(true)
      local armed=false
      local probed=false
      local timer=os.startTimer(1)
      while true do
        if runtime=="minecraft" and id==7 and gpuRun.generations>0 and gpuRun.view and
          fs.exists("rebuild-baseline-request") and not fs.exists("rebuild-baseline.json") then
          json("rebuild-baseline.json",{generation=gpuRun.generations,at=os.epoch("utc")})
          fs.delete("rebuild-baseline-request")
        end
        if runtime=="minecraft" and id==7 and fs.exists("rebuild-request") and fs.exists("rebuild-baseline.json") then
          local f=assert(fs.open("rebuild-baseline.json","r"))
          local baseline=assert(textutils.unserializeJSON(f.readAll())) f.close()
          if gpuRun.generations>baseline.generation then
            json("views-rebuilt.json",{baseline=baseline.generation,generations=gpuRun.generations,
              baselineAt=baseline.at,at=os.epoch("utc"),draws=gpuRun.draws})
          end
        end
        if runtime=="minecraft" and id==6 and fs.exists("client-probe-arm") and not probed then
          gpuRun.paused=true
          local camera=dofile("atomic.lua").copy(gpuRun.camera)
          local interval=gpuRun.cfg.interval
          gpuRun.cfg.interval=0
          local frames={}
          for yaw=0,345,15 do
            camera.mode,camera.yaw="iso",yaw
            local at=os.epoch("utc")
            local good,why=gpuRun.draw(gpuRun.scene,camera)
            assert(good and why=="drawn","client orbit frame did not draw")
            frames[#frames+1]={yaw=yaw,millis=os.epoch("utc")-at}
            sleep(.05)
          end
          assert(gpuRun.draw(gpuRun.scene,gpuRun.camera))
          gpuRun.cfg.interval=interval
          gpuRun.paused=false probed=true
          json("client-probe-result.json",{ok=true,frames=frames,resources=gpuRun.gpu.getResourceStats()})
        end
        if runtime=="minecraft" and id==6 and fs.exists("client-click-arm") and not armed then
          os.queueEvent("mouse_click",1,2,4)
          sleep(3)
          local S=dofile("view-scene.lua")
          local info=gpuRun.gpu.getDisplayInfo(gpuRun.view.displayId)
          local frame=S.camera(gpuRun.camera,info.pixelWidth,info.pixelHeight)
          local target={dim=dim,x=2,y=65,z=-3}
          local x,y=S.project3d({x=target.x,y=64.55,z=target.z},frame)
          assert(x and y,"click target is outside the frame")
          local hit=S.hit3d(gpuRun.scene,gpuRun.camera,frame,x,y)
          assert(hit and hit.x==target.x and hit.y==target.y and hit.z==target.z,"projected click did not select the intended AIR cell")
          local worldTarget=dofile("views-gpu-checks.lua").pixelTarget(info,x,y)
          json("client-click-ready.json",{pixelX=x,pixelY=y,width=info.pixelWidth,height=info.pixelHeight,
            info=info,world=worldTarget,target=target,displayId=gpuRun.view.displayId,selectedId=1,selection="injected terminal row click; GPU click must come from real client"})
          armed=true
        end
        local ev,from,m,proto=os.pullEvent()
        if ev=="timer" and from==timer then timer=os.startTimer(1) end
        if armed and ev=="rednet_message" and from==1 and proto=="minearmy" and type(m)=="table"
          and m.type=="status" and m.x==2 and m.y==65 and m.z==-3 and m.dim==dim then
          local clicked=false
          for _,entry in ipairs(gpuRun.events or {}) do
            if entry.picked and entry.picked.x==2 and entry.picked.y==65 and entry.picked.z==-3 then clicked=true end
          end
          assert(clicked,"target reached without a recorded real DirectGPU target click")
          json("client-click-result.json",{ok=true,pose={dim=m.dim,x=m.x,y=m.y,z=m.z},events=gpuRun.events,
            status=m.status,selectedId=1})
        end
      end
    end)
  end
end)
if not ok then
  pcall(function()
    local f=assert(fs.open("views-error.txt","w"))
    f.write(tostring(err):sub(1,2000))
    if f.flush then f.flush() end
    f.close()
  end)
  result(false,err)
  forever()
end
