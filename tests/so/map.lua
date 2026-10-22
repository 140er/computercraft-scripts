local H = dofile("tests/so/harness.lua")
local R = dofile("tests/ui/render.lua")
local U = dofile("so-ui.lua")

local function setup(monitor, padded)
  local net = H.new()
  local m = net.machine({id=1,modem=true,monitor=monitor,width=26,height=20})
  m.install({"so-store.lua","so-mod-map.lua","so-mod-display.lua","so-ui.lua","so-proto.lua"})
  if monitor then
    local target=R.capture(26,20)
    target.setTextScale=function() end
    local find=m.env.peripheral.find
    m.env.peripheral.find=function(kind) if kind=="monitor" then return target end return find(kind) end
    m.env.peripheral.getName=function() return "monitor" end
  end
  if padded then
    local native=m.env.dofile
    m.env.dofile=function(path)
      local lib=native(path)
      if path=="so-ui.lua" then
        local probe=lib.canvas(15,3) probe.header("MAP","")
        if probe.frame().rows[1].text:find("MAP",1,true) then
          local canvas=lib.canvas
          lib.canvas=function(w,h,bg)
            local c=canvas(w,h,bg)
            local header=c.header
            c.header=function(...)
              header(...)
              c.cells[2]=c.cells[1]
              c.cells[1]={}
              for x=1,w do c.cells[1][x]={" ","0","f"} end
            end
            return c
          end
        end
      end
      return lib
    end
  end
  local scene = {queries=0, machines={},levels={}}
  local mine = {dim="minecraft:overworld",home={x=0,y=64,z=0,facing=0},bottom=60,length=4,branches=2,
    turtles={[2]={pose={x=2,y=60,z=-5,facing=1},state="mining"},
      [3]={pose={x=4,y=60,z=-9,facing=2},state="done"}}}
  scene.mine = mine
  scene.lumber = {dim="minecraft:overworld",area={x1=-5,x2=-3,z1=-3,z2=-1},ground=64,
    saplings={x=-1,y=64,z=2}}
  local store=m.env.dofile("so-store.lua")
  m.files["so-server.cfg"]=H.encode({pos={dim="minecraft:overworld",x=0,y=64,z=2}})
  m.env.SO={store=store,proto=m.env.dofile("so-proto.lua"),pair={key=function() return "key" end},mods={
    mine={mapView=function() return mine end},lumber={mapView=function() return scene.lumber end},
    state={get=function() return scene.machines end},
    cells={isDug=function(x,y,z)
      scene.queries=scene.queries+1
      scene.levels[y]=true
      return x==1 and y==60 and z==-7
    end},
    lease={status=function(id) return scene.lost==id and {lost=true} or {} end,inRange=function() return true end},
    drops={list=function() return {{kind="ore",dim=0,x=5,y=60,z=-5},
      {kind="fuel",dim=0,x=-5,y=64,z=2},{kind="wood",dim=0,x=-3,y=64,z=2},
      {kind="ore",dim=-1,x=10000,y=60,z=10000}} end}}}
  local d=m.env.dofile("so-mod-display.lua")
  m.env.SO.mods.display=d
  local map=m.env.dofile("so-mod-map.lua")
  m.env.SO.mods.map=map
  map.tick(0)
  d.tick(0)
  scene.map,scene.display,scene.machine,scene.net=map,d,m,net
  scene.screen=d.screen("map")
  return scene
end

local function picture(frame,w,h)
  local out=R.capture(w,h)
  for y,row in ipairs(frame.rows) do
    local fg,bg="",""
    if row.runs then
      for _,r in ipairs(row.runs) do fg=fg..string.rep(r[2],r[1]) bg=bg..string.rep(r[3],r[1]) end
    else
      fg=#row.fg==1 and string.rep(row.fg,#row.text) or row.fg
      bg=#row.bg==1 and string.rep(row.bg,#row.text) or row.bg
    end
    out.setCursorPos(1,y)
    out.blit(row.text..string.rep(" ",#fg-#row.text),fg,bg)
  end
  return out
end
local function project(v,w,h,x,z)
  return math.floor((x-v.x+math.floor(w/2)*v.scale)/v.scale)+1,
    math.floor((z-v.z+math.floor((h-3-v.headerRow)/2)*v.scale)/v.scale)+v.headerRow+1
end
local function button(frame,id,w,h)
  for _,b in ipairs(frame.buttons) do if b.id==id then
    assert(b.x>=1 and b.y>=1 and b.x+b.w-1<=w and b.y+(b.h or 1)-1<=h,"button bounds")
    local row=frame.rows[b.y+math.floor((b.h or 1)/2)].text
    assert(row:sub(b.x,b.x+b.w-1):find("%S"),"button is drawn")
    for _,other in ipairs(frame.buttons) do if b~=other then
      assert(b.x+b.w<=other.x or other.x+other.w<=b.x or b.y+(b.h or 1)<=other.y
        or other.y+(other.h or 1)<=b.y,"overlapping map control")
    end end
    return b
  end end
  error("missing drawn button "..id)
end

return function(test,equal)
  for _,size in ipairs({{26,20},{29,12},{57,24},{164,81}}) do
    local w,h=size[1],size[2]
    test("map scene glyphs, colours and controls at "..w.."x"..h,function()
      local s,session=setup(),{map={level="mine",fit=true}}
      local frame
      for _=1,30 do
        local before=s.queries
        frame=s.screen.render(w,h,session)
        assert(s.queries-before<=256,"dug scan budget")
      end
      local function cell(x,z,ch,bg)
        local px,pz=project(session.map,w,h,x,z)
        local c=picture(frame,w,h).cells[pz][px]
        if ch then equal(c[1],ch,"glyph at "..x..","..z) end
        equal(c[3],bg,"colour at "..x..","..z)
      end
      cell(0,-1,"H","9")
      cell(2,-5,">","d")
      cell(4,-9,"v","b")
      cell(5,-5,"O","a")
      cell(1,-7,nil,"8")
      cell(0,-7,nil,session.map.scale==1 and "7" or "8")
      cell(3,-9,nil,"7")
      assert(session.map.scale>=1 and math.abs(session.map.x)<10,"dimension filtering")
      local previous={x=session.map.x,z=session.map.z,scale=session.map.scale}
      for _,id in ipairs({"map-in","map-out","map-n","map-s","map-w","map-e","map-fit","map-level"}) do
        local b=button(frame,id,w,h)
        s.screen.input({id=id,x=b.x,y=b.y,session=session})
        frame=s.screen.render(w,h,session)
        if id=="map-in" then equal(session.map.scale,math.max(1,math.ceil(previous.scale/2))) end
        if id=="map-n" then equal(session.map.z,previous.z-3*session.map.scale) end
        if id=="map-fit" then equal(session.map.fit,true) equal(session.map.scale,previous.scale) end
      end
      equal(session.map.level,"surface")
      cell(0,2,"@","9") cell(-5,2,"F","a") cell(-3,2,"W","a") cell(-1,2,"S","a")
      cell(-5,-2,nil,"d")
      s.screen.input({id="map-level",session=session})
      for _=1,100 do frame=s.screen.render(w,h,session) end
      equal(session.map.level,"all")
      cell(0,2,"@","9") cell(2,-5,">","d") cell(1,-7,nil,"8")
      if w==26 or w==29 or w==57 then
        local fixture=R.load("tests/ui/fixtures/map-"..w.."x"..h..".txt")
        local diffs=R.diff(fixture,picture(frame,w,h).picture())
        equal(#diffs,0,table.concat(diffs,"\n"))
      end
    end)
  end
  for _,size in ipairs({{26,20},{29,12}}) do
    local w,h=size[1],size[2]
    test("map and MAP navigation follow the kit header on row 2 at "..w.."x"..h,function()
      local s=setup(false,true)
      local kit=s.machine.env.dofile("so-ui.lua")
      s.display.screen("panel",function(cw,ch)
        local c=kit.canvas(cw,ch) c.header("PANEL","22:14") return c.frame()
      end,function() end)
      s.display.handlers.hello({from=22,body={w=w,h=h,fullH=h}})
      s.display.handlers.input({from=22,body={id="generic",x=1,y=1}})
      s.display.handlers.input({from=22,body={id="panel",x=1,y=1}})
      local frame
      s.display.handlers["view.get"]({from=22,body={}},function(_,body) frame=body end)
      local target=button(frame,"map",w,h)
      equal(target.y,2)
      equal(frame.rows[1].text:match("%S"),nil,"blank padding above navigation")
      assert(frame.rows[2].text:find("22:14",1,true),"MAP preserves the panel clock")
      local session={}
      frame=s.screen.render(w,h,session)
      equal(session.map.headerRow,2)
      equal(frame.rows[1].text:match("%S"),nil,"blank padding above map")
      assert(frame.rows[2].text:find("MAP",1,true),"map header stays on row 2")
      local x,z=project(session.map,w,h,2,-5)
      assert(z>2,"scene is below the header")
      equal(picture(frame,w,h).cells[z][x][1],">")
    end)
  end
  test("map snapshots copy mining and lumber world data",function()
    local s=setup()
    local m=s.machine
    m.install({"so-plan.lua","so-mine-plan.lua","so-lumber-plan.lua","so-mod-mine.lua","so-mod-lumber.lua"})
    local mine=m.env.dofile("so-mod-mine.lua")
    local lumber=m.env.dofile("so-mod-lumber.lua")
    mine.mapView().home.x=999
    equal(mine.mapView().home.x,0)
    local input
    m.env.SO.mods.display={screen=function(role,_,i) if role=="lumber" then input=i end end}
    m.env.SO.mods.lease=nil
    lumber.tick(0)
    input({text="area -5 -3 -3 -1 64"})
    input({text="saplings -1 64 2 front"})
    local view=lumber.mapView()
    equal(view.area.x1,-5) equal(view.ground,64) equal(view.saplings.z,2)
    view.area.x1=999 view.saplings.z=999
    equal(lumber.mapView().area.x1,-5) equal(lumber.mapView().saplings.z,2)
  end)
  test("local monitor map controls keep a separate session",function()
    local s=setup(true)
    local D
    for i=1,20 do
      local name,value=debug.getupvalue(s.display.monitorTouch,i)
      if name=="D" then D=value break end
    end
    assert(D and D.monitor,"local monitor discovered")
    local function press(id)
      local b=button(D.monitor.frame,id,26,20)
      s.display.monitorTouch("monitor",b.x,b.y)
      s.display.tick(1000)
    end
    press("map") equal(D.monitor.role,"map")
    press("map-out") press("map-e") press("map-level")
    equal(D.monitor.session.map.fit,false)
    local other={}
    s.screen.render(26,20,other)
    equal(other.map.fit,true) equal(other.map.level,"all")
    press("map-back") equal(D.monitor.role,"status")
  end)
  test("map renders complete large frames inside the protocol limit",function()
    local s=setup()
    local frame=s.screen.render(164,81,{})
    local proto=s.machine.env.SO.proto
    local wire,err=proto.encode(proto.build(string.rep("a",64),"view.frame",frame))
    assert(wire,tostring(err))
    equal(#frame.rows,81)
    button(frame,"map-level",164,81)
  end)
  test("map uses bounded dug scans at maximum manual zoom",function()
    local s=setup()
    local session={map={fit=false,x=-100,z=-100,scale=4096,level="all"}}
    local before=s.queries
    s.screen.render(29,12,session)
    equal(s.queries-before,256)
  end)
  test("all-level dug scans skip empty shaft heights and retain the frame budget",function()
    local s=setup()
    s.mine.bottom=-58
    s.mine.turtles[2].pose.y=-58
    s.mine.turtles[3].pose.y=-58
    s.map.tick(0)
    local session={}
    for _=1,30 do
      local before=s.queries
      s.screen.render(26,20,session)
      assert(s.queries-before<=256,"bounded all-level work")
    end
    equal(session.map.levelKey,"-58,-57,60,64")
    for y in pairs(s.levels) do assert(y==-58 or y==-57 or y==60 or y==64,"scanned an empty shaft height") end
    assert(s.levels[-58] and s.levels[-57] and s.levels[60] and s.levels[64],"all tracked levels scanned")
  end)
  test("map view state and scan caches belong to each display",function()
    local s,a,b=setup(),{},{}
    s.screen.render(26,20,a) s.screen.render(26,20,b)
    s.screen.input({id="map-out",session=a}) s.screen.input({id="map-e",session=a})
    s.screen.input({id="map-level",session=a})
    equal(b.map.scale,1) equal(b.map.fit,true) equal(b.map.level,"all")
    assert(a.map.dug~=b.map.dug)
    s.screen.render(29,12,b)
    equal(a.map.level,"mine")
  end)
  test("map heading arrows use worker state and lost range colours",function()
    local s=setup()
    s.mine.turtles[2].state="idle" s.mine.turtles[2].pose.facing=0
    s.mine.turtles[3].pose.facing=3 s.lost=3 s.map.tick(0)
    local session={}
    local frame=s.screen.render(26,20,session)
    local out=picture(frame,26,20)
    for _,t in ipairs({{2,-5,"^","1"},{4,-9,"<","e"}}) do
      local x,z=project(session.map,26,20,t[1],t[2])
      equal(out.cells[z][x][1],t[3]) equal(out.cells[z][x][3],t[4])
    end
    local x,z=project(session.map,26,20,2,-5)
    equal(out.cells[z][x+1][1],"2","worker id when space permits")
  end)
  for _,size in ipairs({{26,20},{29,12},{57,24}}) do
    local w,h=size[1],size[2]
    test("real display client opens and controls the map at "..w.."x"..h,function()
      local net=H.new()
      local server=net.machine({id=1,modem=true})
      local client=net.machine({id=2,modem=true,monitor=w~=26,width=w,height=h,capacity=1000000})
      local function install(machine,files)
        machine.install(files)
        for _,name in ipairs({"x25519","random","blake3","chacha20","config","internal/util",
          "internal/hw","internal/curve25519","internal/fp","internal/edwards25519","internal/packing"}) do
          local path="lib/ccryptolib/"..name..".lua"
          local f=assert(io.open(path,"rb")) machine.files[path]=f:read("*a") f:close()
        end
      end
      install(server,{"so-server.lua","so-proto.lua","so-pair.lua","so-store.lua","so-log.lua",
        "so-plan.lua","so-mine-plan.lua","so-lumber-plan.lua","so-ui.lua","so-mod-state.lua",
        "so-mod-lease.lua","so-mod-cells.lua","so-mod-display.lua","so-mod-drops.lua","so-mod-map.lua",
        "so-mod-mine.lua","so-mod-lumber.lua","so-mod-shop.lua","so-mod-ar.lua","so-mod-panel.lua"})
      server.files["so-server.cfg"]=H.encode({pos={dim="minecraft:overworld",x=0,y=64,z=0}})
      server.boot("so-server.lua") net.flush()
      assert(not server.error,tostring(server.error))
      install(client,{"display.lua","so-proto.lua","so-pair.lua","so-store.lua"})
      local key=string.rep("a",64)
      assert(server.env.SO.pair.remember(2,key))
      client.files["so-keys"]=H.encode({schema=1,generation=1,value={keys={["1"]=key}}})
      client.boot("display.lua") net.flush() net.advance(2)
      local function frame()
        assert(not server.error,tostring(server.error)) assert(not client.error,tostring(client.error))
        for i=#server.sent,1,-1 do
          local p=server.sent[i]
          if p.id==2 and p.payload.t=="view.frame" then return p.payload.body end
        end
        error("no map frame")
      end
      local function press(id)
        local b=button(frame(),id,w,h)
        client.inbox[#client.inbox+1]=table.pack(w==26 and "mouse_click" or "monitor_touch",
          w==26 and 1 or "monitor",b.x,b.y)
        net.flush()
      end
      local original=frame().role
      press("map") equal(frame().role,"map") equal(#frame().rows,h)
      for _,id in ipairs({"map-out","map-in","map-n","map-w","map-s","map-e","map-level","map-fit"}) do press(id) end
      press("map-back") equal(frame().role,original)
      assert(not server.error and not client.error,"map event loop remains healthy")
    end)
  end
  for _,size in ipairs({{26,20},{29,12},{57,24},{15,10}}) do
    local w,h=size[1],size[2]
    test("display MAP and BACK use drawn targets at "..w.."x"..h,function()
      local s=setup()
      local d=s.display
      for _,role in ipairs({"status","generic","mining","lumber","shop","ar","panel"}) do
        d.screen(role,function(cw,ch)
          local c=U.canvas(cw,ch) c.header(role:upper(),"ok")
          if role~="generic" then c.button(1,ch,cw,"MORE","generic","7",1) end
          return c.frame()
        end,function() end)
      end
      d.handlers.hello({from=22,body={w=w,h=h,fullH=h}})
      local function frame()
        local got
        d.handlers["view.get"]({from=22,body={}},function(_,body) got=body end)
        return assert(got)
      end
      local function press(id)
        local b=button(frame(),id,w,h)
        d.handlers.input({from=22,body={id=id,x=b.x,y=b.y}})
      end
      for _,role in ipairs({"generic","status","mining","lumber","shop","ar","panel"}) do
        if frame().role~="generic" then press("generic") end
        if role~="generic" then
          d.handlers.input({from=22,body={id=role,x=1,y=1}})
        end
        equal(frame().role,role)
        press("map") equal(frame().role,"map")
        press("map-out") press("map-n") press("map-level")
        press("map-back") equal(frame().role,role)
        d.handlers.input({from=22,body={id="generic",x=1,y=1}})
      end
      press("map")
      local reboot=s.machine.env.dofile("so-mod-display.lua")
      reboot.screen("map",s.screen.render,s.screen.input)
      reboot.handlers.hello({from=22,body={w=w,h=h,fullH=h}})
      local restored
      reboot.handlers["view.get"]({from=22,body={}},function(_,body) restored=body end)
      equal(restored.role,"map","saved map role survives restart")
    end)
  end
end
