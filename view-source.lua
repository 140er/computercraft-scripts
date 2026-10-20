local M = {}
local function integer(n,lo,hi)
  return type(n)=="number" and n%1==0 and n>=lo and n<=hi
end
function M.new(client,cfg)
  cfg=cfg or {}
  for _,key in ipairs({"radius","maxCells","maxChunks","maxPages"}) do
    assert(cfg[key]==nil or (type(cfg[key])=="number" and cfg[key]==cfg[key] and math.abs(cfg[key])<math.huge),"invalid view "..key)
  end
  local radius=math.max(0,math.min(7,math.floor(cfg.radius or 6)))
  local maxCells=math.max(1,math.min(1024,math.floor(cfg.maxCells or 1024)))
  local maxChunks=math.max(1,math.min(8,math.floor(cfg.maxChunks or 8)))
  local maxPages=math.max(1,math.min(128,math.floor(cfg.maxPages or 128)))
  local current={dim=cfg.dim or "minecraft:overworld",cells={},sites={},stale=true}
  local api={}
  local function chunkCells(key,cx,cy,cz)
    for attempt=1,2 do
      local cells,cursor,revision={},0,nil
      local retry=false
      for _=1,maxPages do
        local r,err=client.call("snapshot",{chunk=key,cursor=cursor,revision=revision})
        if not r or not r.ok then
          if r and r.error=="stale cursor" and attempt==1 then retry=true break end
          return nil,err or (r and r.error) or "snapshot unavailable"
        end
        if not integer(r.revision,0,2147483647) or (revision and revision~=r.revision)
          or not integer(r.cursor,0,4096) or type(r.cells)~="table" or #r.cells>64
          or (r.cursor~=0 and (r.cursor<=cursor or #r.cells==0)) then return nil,"invalid snapshot page" end
        revision=r.revision
        local previous=cursor
        for _,entry in ipairs(r.cells) do
          if type(entry)~="table" or not integer(entry[1],previous+1,4096)
            or not (entry[2]==false or (type(entry[2])=="string" and #entry[2]>0 and #entry[2]<=128)) then return nil,"invalid snapshot cell" end
          previous=entry[1]
          local i=entry[1]-1
          cells[#cells+1]={x=cx*16+i%16,y=cy*16+math.floor(i/256),z=cz*16+math.floor(i/16)%16,name=entry[2]}
        end
        if r.cursor~=0 and previous>r.cursor then return nil,"invalid snapshot cursor" end
        cursor=r.cursor
        if cursor==0 then return cells,revision end
      end
      if not retry then return nil,"snapshot page limit" end
    end
  end
  function api.refresh(center)
    if type(center)~="table" or type(center.dim)~="string"
      or not integer(center.x,-30000000,30000000) or not integer(center.y,-2048,2048)
      or not integer(center.z,-30000000,30000000) then
      current.stale,current.error=true,"invalid view center"
      return false,current.error
    end
    local nextScene={dim=center.dim,cells={},sites={},stale=false,revisions={}}
    local chunks=0
    for cy=math.floor((center.y-radius)/16),math.floor((center.y+radius)/16) do
      for cz=math.floor((center.z-radius)/16),math.floor((center.z+radius)/16) do
        for cx=math.floor((center.x-radius)/16),math.floor((center.x+radius)/16) do
          chunks=chunks+1
          if chunks<=maxChunks then
            local key=center.dim.."|"..cx.."|"..cy.."|"..cz
            local cells,revision=chunkCells(key,cx,cy,cz)
            if not cells then current.stale,current.error=true,revision return false,revision end
            nextScene.revisions[#nextScene.revisions+1]=key.."="..revision
            for _,cell in ipairs(cells) do
              if math.abs(cell.x-center.x)<=radius and math.abs(cell.y-center.y)<=radius
                and math.abs(cell.z-center.z)<=radius then
                if #nextScene.cells<maxCells then nextScene.cells[#nextScene.cells+1]=cell
                else nextScene.truncated=true end
              end
            end
          else nextScene.truncated=true end
        end
      end
    end
    nextScene.revision=table.concat(nextScene.revisions,";")
    if cfg.warehouse==false then current=nextScene return true end
    local list,err=client.call("wh-sites",{})
    if not list or not list.ok or type(list.names)~="table" or #list.names>32 then
      nextScene.warehouseError=err or (list and list.error) or "warehouse unavailable"
    else
      for _,name in ipairs(list.names) do
        if type(name)~="string" or #name==0 or #name>128 then nextScene.warehouseError="invalid warehouse sites" break end
        local result,why=client.call("wh-sites",{name=name})
        local site=result and result.ok and result.site
        local p=site and site.pose
        if not p or not integer(p.x,-30000000,30000000) or not integer(p.y,-2048,2048)
          or not integer(p.z,-30000000,30000000) or type(p.dim)~="string"
          or not ({source=true,drop=true,charge=true})[site.kind] then
          nextScene.warehouseError=why or "warehouse site unavailable"
          break
        end
        if p.dim==center.dim then
          nextScene.sites[#nextScene.sites+1]={name=name,kind=site.kind,pose=p,side=site.side}
        end
      end
    end
    if nextScene.warehouseError then nextScene.sites={} end
    current=nextScene
    return true
  end
  function api.scene() return current end
  return api
end
return M
