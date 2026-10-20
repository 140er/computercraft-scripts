local M={}
function M.camera(camera,width,height)
  local distance=math.max(4,24/math.max(0.25,math.min(4,camera.zoom or 1)))
  local x,y,z=0,0,distance
  if camera.mode=="top" then x,y,z=0,distance,0.001
  elseif camera.mode=="iso" then
    local yaw=math.rad(camera.yaw or 45)
    x,y,z=distance*math.sqrt(2)*math.sin(yaw),distance,distance*math.sqrt(2)*math.cos(yaw)
  end
  local length=math.sqrt(x*x+y*y+z*z)
  local fx,fy,fz=-x/length,-y/length,-z/length
  local rl=math.sqrt(fx*fx+fz*fz)
  local rx,rz=-fz/rl,fx/rl
  return {eye={x=camera.center.x+x,y=camera.center.y+y,z=camera.center.z+z},
    forward={fx,fy,fz},right={rx,0,rz},up={-rz*fy,rz*fx-rx*fz,rx*fy},
    focal=height/(2*math.tan(math.rad(50)/2)),width=width,height=height}
end
function M.project3d(p,frame)
  local x,y,z=p.x-frame.eye.x,p.y-frame.eye.y,p.z-frame.eye.z
  local f,r,u=frame.forward,frame.right,frame.up
  local depth=x*f[1]+y*f[2]+z*f[3]
  if depth<=0.1 then return nil end
  return frame.width/2+frame.focal*(x*r[1]+y*r[2]+z*r[3])/depth,
    frame.height/2-frame.focal*(x*u[1]+y*u[2]+z*u[3])/depth,depth
end
function M.hit3d(scene,camera,frame,x,y)
  if scene.stale or x<0 or y<0 or x>=frame.width or y>=frame.height then return nil end
  local sx,sy=(x-frame.width/2)/frame.focal,-(y-frame.height/2)/frame.focal
  local ray={}
  for i=1,3 do ray[i]=frame.forward[i]+sx*frame.right[i]+sy*frame.up[i] end
  local best,hit=math.huge,nil
  for _,cell in ipairs(M.visible(scene,camera)) do
    local near,far=0,math.huge
    for i,axis in ipairs({"x","y","z"}) do
      local low,high=cell[axis]-0.48,cell[axis]+0.48
      if cell.name==false and axis=="y" then high=cell.y-0.43 end
      local origin=frame.eye[axis]
      if math.abs(ray[i])<1e-10 then
        if origin<low or origin>high then far=-1 end
      else
        local a,b=(low-origin)/ray[i],(high-origin)/ray[i]
        if a>b then a,b=b,a end
        near,far=math.max(near,a),math.min(far,b)
      end
    end
    if far>=near and near<best then hit,best=cell,near end
  end
  return hit
end
function M.project(p,camera,width,height)
  local c=camera.center
  local x,y,z=p.x-c.x,p.y-c.y,p.z-c.z
  local scale=camera.zoom or 1
  local u,v,depth=x,z,-y
  if camera.mode=="side" then u,v,depth=x,-y,-z
  elseif camera.mode=="iso" then
    local yaw=math.rad(camera.yaw or 45)
    local along=x*math.sin(yaw)+z*math.cos(yaw)
    u,v,depth=x*math.cos(yaw)-z*math.sin(yaw),along*0.57735027-y*0.81649658,-along*0.81649658-y*0.57735027
  end
  return (width+1)/2+u*scale,(height+1)/2+v*scale,depth
end
function M.visible(scene,camera,limit)
  local out={}
  for _,cell in ipairs(scene.cells) do
    if (not cell.dim or cell.dim==scene.dim)
      and (camera.mode~="top" or cell.y==camera.center.y)
      and (camera.mode~="side" or cell.z==camera.center.z) then out[#out+1]=cell end
  end
  table.sort(out,function(a,b)
    local _,_,da=M.project(a,camera,1,1)
    local _,_,db=M.project(b,camera,1,1)
    if da~=db then return da>db end
    if a.y~=b.y then return a.y<b.y end
    if a.z~=b.z then return a.z<b.z end
    return a.x<b.x
  end)
  local cap=limit or 1024
  if #out>cap then
    local kept={}
    for i=#out-cap+1,#out do kept[#kept+1]=out[i] end
    out=kept
  end
  return out
end
function M.hasCell(scene,x,y,z,name)
  for _,cell in ipairs(scene and scene.cells or {}) do
    if cell.x==x and cell.y==y and cell.z==z and cell.name==name then return true end
  end
  return false
end
function M.hit(scene,camera,width,height,x,y)
  if x<1 or y<1 or x>width or y>height or scene.stale then return nil end
  local hit,best
  for _,cell in ipairs(M.visible(scene,camera)) do
    local px,py=M.project(cell,camera,width,height)
    px,py=math.floor(px),math.floor(py)
    local d=(px-math.floor(x))^2+(py-math.floor(y))^2
    if px>=1 and py>=1 and px<=width and py<=height
      and d<=(math.max(1,camera.zoom or 1)*0.6)^2 and (not best or d<=best) then hit,best=cell,d end
  end
  return hit
end
return M
