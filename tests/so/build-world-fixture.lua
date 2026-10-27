local H=dofile("tests/so/harness.lua")
local function crypto(machine)
  for _,name in ipairs({"x25519","random","blake3","chacha20","config","internal/util","internal/hw",
    "internal/curve25519","internal/fp","internal/edwards25519","internal/packing"}) do
    local path="lib/ccryptolib/" .. name .. ".lua"
    local file=assert(io.open(path,"rb")) machine.files[path]=file:read("*a") file:close()
  end
end
return function(w,h,options,defaults)
  local net=H.new()
  local server=net.machine({id=1,modem=true,capacity=16000000})
  server.install({"so-server.lua","so-store.lua","so-pair.lua","so-proto.lua","so-log.lua","so-plan.lua",
    "so-ui.lua","so-mine-plan.lua","so-mod-state.lua","so-mod-cells.lua","so-mod-lease.lua",
    "so-mod-display.lua","so-mod-drops.lua","so-mod-build.lua"})
  crypto(server)
  local config={builderFuelTrips=false,builderSolid=false,alternateAxisOrders=false,protectedAreas=false,storageDeliveries=false,jobPoseSetup=false,pos={dim="minecraft:overworld",x=0,y=4,z=0}}
  for name,value in pairs(options or {}) do config[name]=value end
  if not defaults then server.files["so-server.cfg"]=H.encode(config) end
  server.boot("so-server.lua") net.flush()
  local f={net=net,server=server,placed={},places=0}
  local key=string.rep("a",64)
  assert(server.env.SO.pair.remember(2,key))
  local worker=net.machine({id=2,modem=true,turtle=true,x=-2,y=4,z=0,facing=1,fuel=10000,capacity=1000000})
  worker.install({"worker.lua","so-store.lua","so-pair.lua","so-proto.lua"}) crypto(worker)
  worker.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
  local place=worker.env.turtle.placeDown
  worker.env.turtle.placeDown=function()
    local p=worker.pos
    local k=p.x..","..(p.y-1)..","..p.z
    assert(f.server.env.SO.mods.cells.owner(p.x,p.y-1,p.z,"minecraft:overworld")=="build:2","unreserved placement")
    local ok,err=place()
    if ok then
      f.placed[k]=(f.placed[k] or 0)+1 f.places=f.places+1
      if f.crashAt==f.places then
        if f.beforeCrash then f.beforeCrash() end
        net.kill(f.server) f.crashed=true
      end
    end
    return ok,err
  end
  for _,op in ipairs({"dig","digUp","digDown"}) do worker.env.turtle[op]=function() error("builder must never dig") end end
  f.worker=worker
  f.seedJournal=function(journal)
    assert(worker.env.dofile("so-store.lua").store("so-journal",function() return true end,16000).save(journal))
  end
  worker.boot("worker.lua") net.flush() net.advance(1)
  local chest={name="minecraft:chest",inv={{name="minecraft:stone",count=64}}}
  net.world["-3,0,0"]=chest f.chest=chest
  assert(server.env.SO.mods.drops.add({id="build-stock",dim=0,x=-3,y=0,z=0,side="down",kind="storage"}))
  f.command=function(text)
    local so=f.server.env.SO
    local breathe=so.breathe
    so.breathe=function() end
    local ok,err=pcall(so.mods.display.screen("build").input,{text=text})
    so.breathe=breathe
    assert(ok,err)
  end
  f.job=function() local saved=f.server.env.SO.store.read("so-data/build/job") return saved and saved.value end
  f.advance=function(seconds)
    net.advance(seconds)
    assert(not f.server.error,tostring(f.server.error)) assert(not worker.error,tostring(worker.error))
  end
  f.finish=function()
    for _=1,2400 do
      f.advance(0.25)
      local j=f.job()
      if not j.running then assert(not j.blocked,j.alert) return end
      local retry=j.retryAt and f.server.env.SO.now()>=j.retryAt and j.service
        and (j.blocked=="material" and j.service.kind=="storage" or j.blocked=="fuel" and j.service.kind=="fuel")
      local recovery=j.blocked=="lost" and f.server.env.SO.mods.lease.status(2).recovering
      assert(not j.blocked or retry or recovery,j.alert)
    end
    error("real worker build timed out")
  end
  f.restart=function() f.server=net.boot(f.server) net.flush() end
  f.configure=function(shape,x,y,z)
    f.command("area 0 0 0 "..(x-1).." "..(y-1).." "..(z-1))
    f.command("shape "..shape) f.command("material stone") f.command("add 2 -2 4 0 e")
    for _=1,40 do
      if f.job().fuel~=nil then break end
      f.advance(0.25)
    end
    assert(f.job().fuel~=nil,"builder recovery did not report fuel within 10 game seconds")
  end
  if w then
    assert(server.env.SO.pair.remember(3,key))
    local client=net.machine({id=3,modem=true,monitor=w==29,width=w,height=h,capacity=1000000})
    client.install({"display.lua","so-store.lua","so-pair.lua","so-proto.lua"}) crypto(client)
    client.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
    client.env.term.write=function(text)
      local x,y=client.cx or 1,client.cy or 1
      local row=(client.screen[y] or "")..string.rep(" ",w)
      client.screen[y]=(row:sub(1,x-1)..text..row:sub(x+#text)):sub(1,w) client.cx=x+#text
    end
    client.boot("display.lua") net.flush() net.advance(2)
    f.frame=function()
      assert(not client.error,tostring(client.error))
      for i=#f.server.sent,1,-1 do local packet=f.server.sent[i]
        if packet.id==3 and packet.payload.t=="view.frame" then return packet.payload.body end
      end
      error("no client frame")
    end
    f.press=function(label,id)
      local frame=f.frame()
      for _,b in ipairs(frame.buttons) do
        local text=""
        for y=b.y,b.y+(b.h or 1)-1 do text=text..(client.screen[y] or ""):sub(b.x,b.x+b.w-1) end
        if (not id or b.id==id) and text:find(label,1,true) then
          assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h,"clipped button")
          for _,other in ipairs(frame.buttons) do
            if other~=b then assert(b.x+b.w<=other.x or other.x+other.w<=b.x
              or b.y+(b.h or 1)<=other.y or other.y+(other.h or 1)<=b.y,"overlapping buttons") end
          end
          client.inbox[#client.inbox+1]=table.pack(w==29 and "monitor_touch" or "mouse_click",w==29 and "monitor" or 1,b.x,b.y)
          net.flush() return
        end
      end
      error("no drawn "..label.." button on "..frame.role)
    end
  end
  return f
end
