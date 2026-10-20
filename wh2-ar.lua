local M = {}
function M.entries(records, now)
  local entries={}
  for _,record in pairs(records or {}) do
    if type(record)=="table" and type(record.computerId)=="number" then
      local age=math.max(0,(now-(record.lastSeen or 0))/1000)
      local entry={id=record.computerId,kind=record.role,name=record.label,role=record.role,
        age=age,stale=age>=15,phase=record.state,status=age>=15 and "offline" or record.state,
        err=record.error or nil,trouble=record.state=="blocked",poseConfirmed=record.poseConfirmed==true,
        settingsRevision=record.appliedSettingsRevision,fuel=type(record.fuel)=="table" and record.fuel.level or nil}
      if type(record.pose)=="table" then entry.x,entry.y,entry.z,entry.dim=record.pose.x,record.pose.y,record.pose.z,record.pose.dim end
      entries[#entries+1]=entry
    end
  end
  table.sort(entries,function(a,b) return a.id<b.id end)
  return entries
end
function M.merge(legacy, records, now)
  local byId={}
  for _,entry in ipairs(legacy or {}) do byId[entry.id]=entry end
  for _,entry in ipairs(M.entries(records,now)) do byId[entry.id]=entry end
  local result={} for _,entry in pairs(byId) do result[#result+1]=entry end
  table.sort(result,function(a,b) return a.id<b.id end)
  return result
end
return M
