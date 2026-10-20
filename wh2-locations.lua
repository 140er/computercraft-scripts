local M = {}
local function integer(n) return type(n)=="number" and n%1==0 and n>=0 end
local function copy(value)
  if type(value)~="table" then return value end
  local result={} for key,v in pairs(value) do result[key]=copy(v) end return result
end
function M.read(state, query, validPose)
  local sites=state.warehouse and state.warehouse.sites or {}
  local revision=state.warehouse and state.warehouse.locationsRevision or 0
  local layout=state.wh2 and state.wh2.layout
  if layout and type(layout.locations)=="table" then revision=tostring(revision)..":"..tostring(layout.revision) end
  local function bad(code,error) return {wh2=1,ok=false,code=code,error=error} end
  if not integer(query.cursor or 0) or query.computerId~=nil and not integer(query.computerId) then return bad("invalid","Invalid location cursor") end
  if query.revision~=nil and query.revision~=revision then return bad("stale_revision","Shared locations changed") end
  if (query.cursor or 0)>0 and query.revision==nil then return bad("invalid","Location pages require a revision") end
  local records={}
  for name,site in pairs(sites) do
    if type(name)=="string" and #name<=64 and type(site)=="table" and validPose(site.pose)
      and type(site.pose.h)=="number" and site.pose.h%1==0 and site.pose.h>=0 and site.pose.h<=3
      and (site.side=="front" or site.side=="top" or site.side=="bottom") then
      local kind=site.kind=="charge" and "charge" or site.kind=="drop" and "dropoff" or "warehouse_input"
      local record={id=name,kind=kind,enabled=true,roomId=false,access={pose=copy(site.pose),side=site.side or "front"},
        siteNames={source=site.kind=="source" and name or false,drop=site.kind=="drop" and name or false,
          charge=site.kind=="charge" and name or false},lockId=site.lockId or name,revision=revision}
      record.v=1
      local p=record.access.pose
      if p.v==nil then
        p.v,p.frame,p.yAbs,p.conf,p.src,p.anchoredAt=1,"abs",true,"certain","typed",0
      end
      if kind~="charge" then
        local block=copy(record.access.pose)
        if site.side=="top" then block.y=block.y+1
        elseif site.side=="bottom" then block.y=block.y-1
        else
          local directions={{0,-1},{1,0},{0,1},{-1,0}}
          local step=directions[(site.pose.h or 0)+1]
          block.x,block.z=block.x+step[1],block.z+step[2]
        end
        record.block=block
      end
      if query.id==nil or query.id==name then records[#records+1]=record end
    end
  end
  if layout and type(layout.locations)=="table" then
    local byId={}
    for _,record in ipairs(records) do byId[record.id]=record end
    for id,record in pairs(layout.locations) do
      if type(id)=="string" and type(record)=="table" and record.v==1 and record.id==id
        and type(record.access)=="table" and validPose(record.access.pose) then
        byId[id]=copy(record)
      end
    end
    records={}
    for id,record in pairs(byId) do if query.id==nil or query.id==id then records[#records+1]=record end end
  end
  table.sort(records,function(a,b) return a.id<b.id end)
  local cursor=query.cursor or 0
  if cursor>#records then return bad("invalid","Location cursor is outside the result") end
  local result={wh2=1,ok=true,revision=revision,records={},cursor=0}
  for index=cursor+1,#records do
    result.records[#result.records+1]=records[index]
    if #textutils.serialize(result,{compact=true})>3500 then
      result.records[#result.records]=nil result.cursor=index-1
      if #result.records==0 then return bad("too_large","Location exceeds the page budget") end
      break
    end
  end
  return result
end
return M
