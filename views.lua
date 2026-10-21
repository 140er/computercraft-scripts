local M = {}
local function colorTerm(t)
  return t.isColor and t.isColor()
end
local function put(t,x,y,text,color)
  local w,h=t.getSize()
  if y<1 or y>h or x>w then return end
  text=tostring(text or '')
  if x<1 then text=text:sub(2-x) x=1 end
  if color and colorTerm(t) then t.setTextColor(color) end
  t.setCursorPos(x,y) t.write(text:sub(1,w-x+1))
end
function M.new(cfg,source)
  local api={mode=cfg.mode or 'pro',page=1,camera={mode=cfg.camera or (cfg.mode=='warehouse' and 'top' or 'iso'),center=cfg.center or {x=0,y=64,z=0},zoom=1}}
  local sceneLib
  local function geometry() sceneLib=sceneLib or dofile('view-scene.lua') return sceneLib end
  local function button(s,x,y,label,action,color)
    local w,h=s.t.getSize()
    put(s.t,x,y,label,color or colors.cyan)
    if x<=w and y<=h then s.buttons[#s.buttons+1]={x1=x,x2=math.min(w,x+#label-1),y=y,action=action} end
  end
  function api.draw(s,fleet,selected,notice,layers)
    local t=s.t local w,h=t.getSize()
    s.buttons={} s.map=nil
    if colorTerm(t) then t.setBackgroundColor(colors.black) t.setTextColor(colors.white) end
    t.clear()
    local scene=source and source.scene() or {stale=true,error='Pair SSOT in views.cfg',cells={},sites={}}
    put(t,1,1,api.mode=='warehouse' and 'WAREHOUSE | top view' or api.mode=='map' and ('WORLD | '..api.camera.mode) or 'MINE ARMY | PRO',colors.cyan)
    local status=scene.stale and ('STALE '..tostring(scene.error or 'no snapshot'))
      or scene.warehouseError and ('Warehouse unavailable: '..scene.warehouseError)
      or scene.truncated and 'PARTIAL VIEW'
      or ('SSOT revision '..tostring(scene.revision or 0))
    put(t,1,2,notice or status,(scene.stale or scene.warehouseError) and colors.orange or colors.lightGray)
    if api.mode=='pro' then
      if h>=7 then
      local count=h-6
      local pages=math.max(1,math.ceil(#fleet/count))
      api.page=math.max(1,math.min(api.page,pages))
      put(t,1,3,'Turtle          Fuel       Free  State',colors.lightGray)
      for i=(api.page-1)*count+1,math.min(#fleet,api.page*count) do
        local f=fleet[i] local y=4+(i-1)%count
        local label=(f.id==selected and '>' or ' ')..tostring(f.label or ('#'..f.id))
        local text=string.format('%-15.15s %-10.10s %3s %s',label,tostring(f.fuel or '?'),tostring(f.free or '?'),(f.age or 0)>15 and 'NO SIGNAL' or tostring(f.status or f.phase or '?'))
        put(t,1,y,text,(f.age or 0)>15 and colors.orange or colors.white)
        s.buttons[#s.buttons+1]={x1=1,x2=w,y=y,action={kind='select',id=f.id}}
      end
      put(t,1,h-2,'Page '..api.page..'/'..pages..'  [ prev   ] next',colors.lightGray)
      end
    else
      local camera=api.camera
      if api.mode=='warehouse' then camera={mode='top',center=api.camera.center,zoom=api.camera.zoom} end
      s.map={scene=scene,camera=camera,w=w,h=math.max(1,h-5),targets={},selections={}}
      for _,c in ipairs(geometry().visible(scene,camera)) do
        local x,y=geometry().project(c,camera,w,s.map.h)
        if x and y and x>=1 and x<=w and y>=1 and y<=s.map.h then
          x,y=math.floor(x),math.floor(y)
          put(t,x,y+2,c.name==false and '.' or '#',colors.gray)
          s.map.targets[x..","..y]=c
        end
      end
      local siteText={}
      for _,site in ipairs(scene.sites or {}) do
        local x,y=geometry().project(site.pose,camera,w,s.map.h)
        if x and y and y>=1 and y<=s.map.h then
          x,y=math.floor(x),math.floor(y)
          local label=(site.kind=='charge' and 'C' or 'S')..' '..site.name
          put(t,x,y+2,label,colors.white)
          for at=math.max(1,x),math.min(w,x+#label-1) do
            s.map.targets[at..","..y]=nil
            siteText[at..","..y]=true
          end
        end
      end
      for _,f in ipairs(fleet) do
        if type(f.x)=='number' and type(f.y)=='number' and type(f.z)=='number' and f.dim==scene.dim then
          local x,y=geometry().project(f,camera,w,s.map.h)
          if x and y and y>=1 and y<=s.map.h then
            x,y=math.floor(x),math.floor(y)
            local label='T'..f.id
            if not siteText[x..","..y] then put(t,x,y+2,label,colors.lime) end
            for at=math.max(1,x),math.min(w,x+#label-1) do
              if not siteText[at..","..y] then s.map.selections[at..","..y]=f.id end
            end
          end
        end
      end
      if h>=7 then put(t,1,h-2,'T turtle  S store  C charge  . air',colors.lightGray) end
    end
    if h>=7 then
      button(s,1,h-1,'Resume',{kind='resume'}) button(s,9,h-1,'Recall',{kind='recall'}) button(s,17,h-1,'E-stop',{kind='estop'})
      if api.mode=='pro' then
        local x=1
        local labels={P='HUD',T='TRT',O='ORE',A='AIR'}
        for _,letter in ipairs({'P','T','O','A'}) do
          local label=labels[letter]
          if x+#label-1>w then break end
          local on=type(layers)=='table' and layers[letter]==true
          button(s,x,h,label,{kind='layer',key=letter},on and colors.lime or colors.lightGray)
          x=x+#label+1
        end
        if x+4<=w then put(t,x,h,'p m n',colors.lightGray) end
      else
        put(t,1,h,'p classic  m map  n warehouse',colors.lightGray)
      end
    end
  end
  function api.click(s,x,y)
    for _,b in ipairs(s.buttons or {}) do if y==b.y and x>=b.x1 and x<=b.x2 then return b.action end end
    local map=s.map
    local id=map and map.selections[x..","..(y-2)]
    if id then return {kind='select',id=id} end
    if map and not map.scene.stale and y>2 and y<=map.h+2 then
      local cell=map.targets[x..","..(y-2)]
      if cell and cell.name==false then return {kind='move',point={dim=map.scene.dim,x=cell.x,y=cell.y,z=cell.z}} end
    end
  end
  function api.key(k)
    local modes={p='pro',m='map',n='warehouse'}
    if modes[k] then api.mode=modes[k]
    elseif k==']' then api.page=api.page+1
    elseif k=='[' then api.page=math.max(1,api.page-1)
    elseif k=='t' then api.camera.mode='top'
    elseif k=='y' then api.camera.mode='side'
    elseif k=='i' then api.camera.mode='iso'
    elseif k==',' then api.camera.yaw=((api.camera.yaw or 45)-45)%360
    elseif k=='.' then api.camera.yaw=((api.camera.yaw or 45)+45)%360
    elseif k=='+' then api.camera.zoom=math.min(8,api.camera.zoom+1)
    elseif k=='-' then api.camera.zoom=math.max(1,api.camera.zoom-1)
    elseif k=='h' then return {kind='resume'}
    elseif k=='r' then return {kind='recall'}
    elseif k=='e' then return {kind='estop'} end
  end
  return api
end
return M
