local Source = dofile("view-source.lua")
local Scene = dofile("view-scene.lua")
local calls = 0
local client = {call=function(op, q)
  if op == "wh-sites" then return {ok=false,error="unknown operation"} end
  calls = calls + 1
  if q.chunk == "minecraft:overworld|-1|-1|-1" then
    return {ok=true,revision=3,cursor=0,cells={{4095,"minecraft:stone"},{4096,false}}}
  end
  return {ok=true,revision=0,cursor=0,cells={}}
end}
local source = Source.new(client,{radius=1})
assert(source.refresh({dim="minecraft:overworld",x=-1,y=-1,z=-1}))
local scene=source.scene()
assert(#scene.cells==2 and calls<=8,"bounded negative chunk snapshot")
assert(scene.cells[1].x==-2 and scene.cells[2].name==false,"AIR and negative coordinates survive")
assert(scene.warehouseError,"unavailable warehouse is explicit")
local farCell={x=0,y=0,z=0,name="minecraft:stone"}
local nearCell={x=0,y=0,z=10,name="minecraft:stone"}
local kept=Scene.visible({dim="minecraft:overworld",cells={farCell,nearCell}},
  {mode="iso",center={x=0,y=0,z=0},yaw=45,zoom=1},1)
assert(#kept==1 and kept[1].z==10,"visible limit keeps the nearest cell")
local partial={cells={{x=-4,y=65,z=-4,name="computercraft:computer_advanced"}}}
assert(not Scene.hasCell(partial,0,66,4,"minecraft:iron_ore"),"computer blocks are not the scan seed")
assert(Scene.hasCell({cells={partial.cells[1],{x=0,y=66,z=4,name="minecraft:iron_ore"}}},0,66,4,"minecraft:iron_ore"))
for _,mode in ipairs({"top","side","iso"}) do
  local camera={mode=mode,center={x=-1,y=-1,z=-1},zoom=3}
  local x,y=Scene.project(scene.cells[2],camera,80,40)
  assert(Scene.hit(scene,camera,80,40,x,y)==scene.cells[2],"projection round trip "..mode)
end
local old=scene
client.call=function() return nil,"disconnected" end
assert(not source.refresh({dim="minecraft:overworld",x=-1,y=-1,z=-1}))
assert(source.scene().stale and source.scene().cells==old.cells,"disconnect retains marked snapshot")
print("view-core checks passed")
local Direct=dofile("directview.lua")
local draws,updates,removed,time=0,0,0,0
local nextId=10
local gpu={}
for name,count in pairs({enableMouseEvents=3,setupCamera=4,setBackfaceCulling=2,
  addAmbientLight=5,addDirectionalLight=8,clear=4,clearZBuffer=1,
  setCameraPosition=4,lookAt=4,drawCube=11,drawText=10,unload3DModel=1,unloadTexture=1,clearLights=1,clear3D=1}) do
  gpu[name]=function(...) assert(select("#",...)==count,name.." signature") end
end
gpu.autoDetectAndCreateDisplay=function(name,w,h)
  assert(name=="monitor_17" and w==320 and h==240,"explicit wired monitor")
  return 4
end
gpu.getDisplayInfo=function() return {pixelWidth=640,pixelHeight=360} end
gpu.load3DModel=function(obj) assert(obj:find("vt 0 0",1,true)) nextId=nextId+1 return nextId end
gpu.loadTexture=function(w,h,data) assert(w==2 and h==2 and #data==16) nextId=nextId+1 return nextId end
gpu.draw3DModelTextured=function(...) assert(select("#",...)==10) draws=draws+1 end
gpu.updateDisplay=function(id) assert(id==4) updates=updates+1 end
gpu.removeDisplay=function(id) assert(id==4) removed=removed+1 end
assert(not Direct.new(gpu,{}),"monitor selection required")
local renderer=assert(Direct.new(gpu,{monitor="monitor_17",clock=function()return time end}))
local cell={x=-4,y=-50,z=-4,name="minecraft:diamond_ore"}
local world={dim="minecraft:overworld",revision=1,cells={cell},sites={}}
local camera={mode="iso",center={x=-4,y=-50,z=-4},zoom=1}
assert(renderer.draw(world,camera))
assert(draws==1 and updates==1)
assert(renderer.draw(world,camera))
assert(updates==1,"unchanged frames do not redraw")
assert(renderer.event({"directgpu_mouse",4,"mouse_click",320,180,1})==cell,"actual pixel size and event tuple")
time=0.05
world.fleet={{id=1,dim=world.dim,x=cell.x,y=cell.y,z=cell.z,label="T1"}}
local held,heldReason=renderer.draw(world,camera)
assert(held and heldReason=="throttled","movement inside the interval keeps the last frame")
assert(renderer.event({"directgpu_mouse",4,"mouse_click",320,180,1})==cell,"throttled frame keeps the previous pick")
world.fleet=nil
time=0
assert(not renderer.event({"directgpu_mouse",5,"mouse_click",320,180,1}))
assert(not renderer.event({"directgpu_mouse",4,"mouse_hover",320,180,1}))
world.stale=true
assert(not renderer.event({"directgpu_mouse",4,"mouse_click",320,180,1}),"stale frame blocks control immediately")
time=1
assert(renderer.draw(world,camera))
assert(updates==2)
renderer.close()
renderer.close()
assert(removed==1,"owned display cleaned once")
assert(not renderer.draw(world,camera))
print("DirectGPU signature and lifecycle checks passed")
local attempts=0
local paged=Source.new({call=function(op,q)
  assert(op=="snapshot","warehouse disabled")
  attempts=attempts+1
  if attempts==1 then return {ok=true,revision=2,cursor=1,cells={{1,"minecraft:old"}}} end
  if attempts==2 then assert(q.revision==2) return {ok=false,error="stale cursor"} end
  if attempts==3 then assert(q.cursor==0 and not q.revision) return {ok=true,revision=3,cursor=1,cells={{1,false}}} end
  assert(q.revision==3)
  return {ok=true,revision=3,cursor=0,cells={{2,"minecraft:stone"}}}
end},{radius=1,warehouse=false})
assert(paged.refresh({dim="minecraft:overworld",x=1,y=1,z=1}))
assert(attempts==4 and #paged.scene().cells==2 and paged.scene().cells[1].name==false,"stale pages retry without mixing generations")
local sites=Source.new({call=function(op,q)
  if op=="snapshot" then return {ok=true,revision=0,cursor=0,cells={}} end
  if not q.name then return {ok=true,names={"charger","nether"}} end
  return {ok=true,site={kind="charge",pose={dim=q.name=="nether" and "minecraft:the_nether" or "minecraft:overworld",x=1,y=1,z=1},side="front"}}
end},{radius=0})
assert(sites.refresh({dim="minecraft:overworld",x=1,y=1,z=1}))
assert(#sites.scene().sites==1 and sites.scene().sites[1].name=="charger","PR4 site adapter filters dimensions")
for _,mode in ipairs({"top","side","iso"}) do
  local cam={mode=mode,center={x=-4,y=-50,z=-4},zoom=2}
  local f=Scene.camera(cam,640,360)
  local px,py=Scene.project3d(cell,f)
  assert(Scene.hit3d({cells={cell}},cam,f,px,py)==cell,"GPU camera round trip "..mode)
end
print("snapshot paging, PR4 boundary and camera checks passed")
assert(not pcall(Source.new,client,{radius=0/0}),"NaN source radius rejected")
assert(not Direct.new(gpu,{monitor="left",maxCells=math.huge}),"infinite renderer cap rejected")
local malformed=Source.new({call=function()
  return {ok=true,revision=1,cursor=1,cells={}}
end},{radius=0,warehouse=false})
assert(not malformed.refresh({dim="minecraft:overworld",x=0,y=0,z=0}),"empty nonfinal page rejected")
local partial=Source.new({call=function(op,q)
  if op=="snapshot" then return {ok=true,revision=0,cursor=0,cells={}} end
  if not q.name then return {ok=true,names={"a","b"}} end
  if q.name=="b" then return nil,"lost connection" end
  return {ok=true,site={kind="source",pose={dim="minecraft:overworld",x=0,y=0,z=0}}}
end},{radius=0})
assert(partial.refresh({dim="minecraft:overworld",x=0,y=0,z=0}))
assert(#partial.scene().sites==0 and partial.scene().warehouseError,"partial warehouse fetch is not published")
world.stale=false
local renderer2=assert(Direct.new(gpu,{monitor="monitor_17",clock=function()return time end}))
assert(renderer2.draw(world,camera))
assert(not renderer2.event({"directgpu_mouse",4,"mouse_click",0/0,180,1}),"NaN click rejected")
assert(not renderer2.event({"directgpu_mouse",4,"mouse_click",320,180,2}),"secondary click rejected")
world.fleet={{id=1,label="One",dim=world.dim,x=-4,y=-50,z=-4,age=0}}
time=time+1
assert(renderer2.draw(world,camera))
local before=updates
world.fleet[1].x=-3
time=time+1
assert(renderer2.draw(world,camera))
assert(updates==before+1,"fleet movement invalidates frame without map changes")
renderer2.close()
for _,yaw in ipairs({0,45,90,180,270}) do
  local cam={mode="iso",center={x=-4,y=-50,z=-4},zoom=2,yaw=yaw}
  local f=Scene.camera(cam,640,360)
  local px,py=Scene.project3d(cell,f)
  assert(Scene.hit3d({cells={cell}},cam,f,px,py)==cell,"orbit hit round trip")
end
print("boundary validation, complete warehouse and moving fleet checks passed")
assert(not source.refresh({dim="minecraft:overworld",x=0/0,y=65,z=0}))
assert(source.scene().stale and source.scene().error=="invalid view center","bad viewport must disable old map controls")
local textCamera={mode="top",center={x=-4,y=-50,z=-4},zoom=1}
local tx,ty=Scene.project(cell,textCamera,80,40)
assert(Scene.hit({cells={cell}},textCamera,80,40,math.floor(tx),math.floor(ty))==cell,"even monitor text hit uses drawn pixels")
