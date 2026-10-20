local M = {}
local function integer(n) return type(n)=="number" and n%1==0 and n>=0 end
local function copy(value)
  if type(value)~="table" then return value end
  local result={} for key,v in pairs(value) do result[key]=copy(v) end return result
end
function M.read(state, query, validPose)
  local sites=state.warehouse and state.warehouse.sites or {}
  local revision=state.warehouse and state.warehouse.locationsRevision or 0
  local function bad(code,error) return {wh2=1,ok=false,code=code,error=error} end
  if not integer(query.cursor or 0) or query.computerId~=nil and not integer(query.computerId) then return bad("invalid","Invalid location cursor") end
  if query.revision~=nil and query.revision~=revision then return bad("stale_revision","Shared locations changed") end
  local records={}
  for name,site in pairs(sites) do
    if type(name)=="string" and #name<=64 and type(site)=="table" and validPose(site.pose) then
      local kind=site.kind=="charge" and "charge" or site.kind=="drop" and "dropoff" or "warehouse_input"
      local record={id=name,kind=kind,enabled=true,roomId=false,access={pose=copy(site.pose),side=site.side or "front"},
        siteNames={source=site.kind=="source" and name or false,drop=site.kind=="drop" and name or false,
          charge=site.kind=="charge" and name or false},lockId=site.lockId or name,revision=revision}
      if kind~="charge" then
        local block=copy(site.pose) block.h=nil
        if site.side=="top" then block.y=block.y+1
        elseif site.side=="bottom" then block.y=block.y-1
        else
          local directions={{1,0},{0,1},{-1,0},{0,-1}}
          local step=directions[(site.pose.h or 0)+1]
          block.x,block.z=block.x+step[1],block.z+step[2]
        end
        record.block=block
      end
      if query.id==nil or query.id==name then records[#records+1]=record end
    end
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
