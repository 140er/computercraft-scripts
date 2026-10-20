local Scene=dofile("view-scene.lua")
local M={}
local cube=[[
v -0.48 -0.48 -0.48
v 0.48 -0.48 -0.48
v 0.48 0.48 -0.48
v -0.48 0.48 -0.48
v -0.48 -0.48 0.48
v 0.48 -0.48 0.48
v 0.48 0.48 0.48
v -0.48 0.48 0.48
vt 0 0
vt 1 0
vt 1 1
vt 0 1
f 1/1 4/4 3/3
f 1/1 3/3 2/2
f 5/1 6/2 7/3
f 5/1 7/3 8/4
f 1/1 5/2 8/3
f 1/1 8/3 4/4
f 2/1 3/4 7/3
f 2/1 7/3 6/2
f 4/1 8/2 7/3
f 4/1 7/3 3/4
f 1/1 2/2 6/3
f 1/1 6/3 5/4
]]
local textures={stone="dH2Kg4yYg4yYdH2K",ore="LqW5WHJ1WHJ1LqW5",air="HS02KT1BKT1BHS02"}
local function fingerprint(scene,camera,w,h)
  local parts={scene.dim,tostring(scene.revision),tostring(scene.stale),tostring(scene.error),
    tostring(scene.warehouseError),tostring(scene.truncated),camera.mode or "iso",
    camera.center.x,camera.center.y,camera.center.z,camera.zoom or 1,camera.yaw or 45,w,h}
  for _,c in ipairs(scene.cells) do
    parts[#parts+1]=c.x..","..c.y..","..c.z.."="..tostring(c.name)
  end
  for _,s in ipairs(scene.sites or {}) do
    parts[#parts+1]=s.name..s.kind..s.pose.x..","..s.pose.y..","..s.pose.z
  end
  for _,t in ipairs(scene.fleet or {}) do
    parts[#parts+1]=table.concat({tostring(t.id),tostring(t.dim),tostring(t.x),tostring(t.y),
      tostring(t.z),tostring(t.label),tostring((t.age or 0)>15),tostring(t.status)},",")
  end
  return table.concat(parts,"|")
end
function M.new(gpu,cfg)
  cfg=cfg or {}
  for _,key in ipairs({"maxCells","width","height","interval"}) do
    if cfg[key]~=nil and (type(cfg[key])~="number" or cfg[key]~=cfg[key] or math.abs(cfg[key])==math.huge) then
      return nil,"invalid DirectGPU "..key
    end
  end
  local maxCells=math.max(1,math.min(1024,math.floor(cfg.maxCells or 1024)))
  if not cfg.displayId and (type(cfg.monitor)~="string" or cfg.monitor=="") then
    return nil,"select a DirectGPU monitor by side or wired name"
  end
  local id,model,airModel
  local loaded={}
  local api={}
  local closed=false
  function api.close()
    if closed then return end
    closed=true
    if id then pcall(gpu.enableMouseEvents,id,false,false) pcall(gpu.clear3D,id) end
    if model then pcall(gpu.unload3DModel,model) end
    if airModel then pcall(gpu.unload3DModel,airModel) end
    for _,texture in pairs(loaded) do pcall(gpu.unloadTexture,texture) end
    if id and not cfg.displayId then pcall(gpu.removeDisplay,id) end
  end
  local ok,err=pcall(function()
    id=cfg.displayId or gpu.autoDetectAndCreateDisplay(cfg.monitor,cfg.width or 320,cfg.height or 240)
    assert(type(id)=="number","invalid DirectGPU display")
    gpu.enableMouseEvents(id,true,false)
    model=gpu.load3DModel(cube)
    airModel=gpu.load3DModel((cube:gsub("v ([^ ]+) 0%.48","v %1 -0.43")))
    for name,data in pairs(textures) do loaded[name]=gpu.loadTexture(2,2,data) end
    gpu.setupCamera(id,50,0.1,256)
    gpu.setBackfaceCulling(id,true)
    gpu.clearLights(id)
    gpu.addAmbientLight(id,255,255,255,0.65)
    gpu.addDirectionalLight(id,-1,-2,-1,255,255,255,0.5)
  end)
  if not ok then api.close() return nil,tostring(err) end
  local lastKey,lastAt,frameScene,frameCamera,frame,framePick=nil,-math.huge,nil,nil,nil,nil
  local clock=cfg.clock or os.clock
  api.displayId=id
  function api.draw(scene,camera)
    if closed then return false,"display closed" end
    local success,result=pcall(function()
      local info=gpu.getDisplayInfo(id)
      local w,h=info.pixelWidth,info.pixelHeight
      assert(type(w)=="number" and type(h)=="number" and w>0 and h>0,"invalid DirectGPU resolution")
      local key=fingerprint(scene,camera,w,h)
      if key==lastKey and framePick then return "unchanged" end
      if clock()-lastAt<(cfg.interval or 0.2) then return "throttled" end
      local nextFrame=Scene.camera(camera,w,h)
      gpu.clear(id,12,19,29)
      gpu.clearZBuffer(id)
      gpu.setCameraPosition(id,nextFrame.eye.x,nextFrame.eye.y,nextFrame.eye.z)
      gpu.lookAt(id,camera.center.x,camera.center.y,camera.center.z)
      local count,drawn=0,{}
      for _,cell in ipairs(Scene.visible(scene,camera,maxCells)) do
        local x,y,depth=Scene.project3d(cell,nextFrame)
        local margin=depth and nextFrame.focal/depth or 0
        if x and x>=-margin and y>=-margin and x<w+margin and y<h+margin then
          local texture=cell.name==false and "air" or (cell.name:find("ore",1,true) and "ore" or "stone")
          gpu.draw3DModelTextured(id,cell.name==false and airModel or model,cell.x,cell.y,cell.z,0,0,0,1,loaded[texture])
          count=count+1
          drawn[#drawn+1]=cell
        end
      end
      for _,site in ipairs(scene.sites or {}) do
        local p=site.pose
        if p.dim==scene.dim then
          local x,y=Scene.project3d(p,nextFrame)
          if x and x>=0 and y>=0 and x<w and y<h then
            gpu.drawCube(id,p.x,p.y+0.2,p.z,0.35,0,0,0,site.kind=="charge" and 250 or 80,190,90)
            gpu.drawText(id,site.name,math.floor(x),math.floor(y),240,230,160,"Monospaced",10,"plain")
          end
        end
      end
      for index,turtle in ipairs(scene.fleet or {}) do
        if index>128 then break end
        if turtle.dim==scene.dim and type(turtle.x)=="number" and type(turtle.y)=="number"
          and type(turtle.z)=="number" then
          local x,y=Scene.project3d(turtle,nextFrame)
          if x and x>=0 and y>=0 and x<w and y<h then
            local stale=(turtle.age or 0)>15
            gpu.drawCube(id,turtle.x,turtle.y+0.2,turtle.z,0.65,0,0,0,stale and 140 or 245,stale and 140 or 190,70)
            gpu.drawText(id,tostring(turtle.label or turtle.id)..(stale and " STALE" or ""),
              math.floor(x),math.floor(y)-12,245,210,100,"Monospaced",10,"plain")
          end
        end
      end
      local status=scene.stale and "STALE - controls disabled" or (scene.truncated and "PARTIAL VIEW" or "SSOT "..(camera.mode or "iso"))
      gpu.drawText(id,status,6,6,scene.stale and 255 or 140,scene.stale and 90 or 220,220,"Monospaced",12,"plain")
      gpu.drawText(id,tostring(count).." cells  "..scene.dim,6,h-18,140,160,180,"Monospaced",10,"plain")
      gpu.updateDisplay(id)
      lastKey,lastAt,frameScene,frameCamera,frame=key,clock(),scene,
        {mode=camera.mode,zoom=camera.zoom,yaw=camera.yaw,center={x=camera.center.x,y=camera.center.y,z=camera.center.z}},nextFrame
      framePick={dim=scene.dim,cells=drawn,stale=scene.stale}
      return "drawn"
    end)
    if not success then lastKey,frameScene=nil,nil return false,tostring(result) end
    return true,result
  end
  function api.event(event)
    if closed or not framePick or not frameScene or frameScene.stale or event[1]~="directgpu_mouse" or event[2]~=id
      or event[3]~="mouse_click" or type(event[4])~="number" or type(event[5])~="number"
      or event[4]~=event[4] or event[5]~=event[5] or event[6]~=1 then return nil end
    return Scene.hit3d(framePick,frameCamera,frame,event[4],event[5])
  end
  return api
end
return M
