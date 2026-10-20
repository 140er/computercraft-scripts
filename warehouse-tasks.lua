local M={}
local A=dofile("atomic.lua")
local function int(n,a,b) return type(n)=="number" and n%1==0 and n>=a and n<=b end
local function word(v) return type(v)=="string" and #v>0 and #v<=64 and v:match("^[%w_:./-]+$") end
local function stock(v)
  if type(v)~="table" then return false end
  local n=0
  for item,count in pairs(v) do
    n=n+1
    if n>64 or not word(item) or not int(count,0,1000000) then return false end
  end
  return true
end
function M.site(v,pose)
  return type(v)=="table" and (v.kind=="source" or v.kind=="drop" or v.kind=="charge")
    and pose(v.pose) and int(v.pose.h,0,3) and (v.side=="front" or v.side=="top" or v.side=="bottom")
end
function M.valid(v,pose)
  if v==nil then return true end
  if type(v)~="table" or type(v.sites)~="table" or type(v.orders)~="table" or type(v.locks)~="table" then return false end
  if v.locationsRevision~=nil and not int(v.locationsRevision,0,2147483647) then return false end
  local n=0
  for name,s in pairs(v.sites) do
    n=n+1
    if n>32 or not word(name) or not M.site(s,pose) or s.stock and not stock(s.stock) then return false end
  end
  for name,id in pairs(v.locks) do if not v.sites[name] or not int(id,0,2147483647) then return false end end
  n=0
  for key,j in pairs(v.orders) do
    n=n+1
    if n>32 or not word(key) or type(j)~="table" or j.key~=key or not v.sites[j.drop]
      or v.sites[j.drop].kind~="drop" or type(j.lines)~="table" or #j.lines<1 or #j.lines>8
      or j.status~="open" and j.status~="active" and j.status~="done" and j.status~="partial"
      or j.status~="open" and j.owner==nil or j.status=="open" and j.owner~=nil
      or j.owner~=nil and (not int(j.owner,0,2147483647) or not word(j.token)) then return false end
    for i,l in pairs(j.lines) do
      if not int(i,1,#j.lines) or type(l)~="table" or not word(l.item) or not v.sites[l.source]
        or v.sites[l.source].kind~="source" or not int(l.wanted,1,4096) or not int(l.count,0,l.wanted)
        or not int(l.picked,0,l.count) or not int(l.delivered,0,l.picked) then return false end
    end
  end
  return true
end
function M.run(s,id,m,epoch,pose)
  local function fail(err) return {ok=false,error=err} end
  local v=s.warehouse or {sites={},orders={},locks={}}
  s.warehouse=v
  if m.op=="wh-site" then
    if not word(m.name) or not M.site(m.site,pose) then return fail("invalid interaction site") end
    if v.locks[m.name] then return fail("site is locked") end
    for _,j in pairs(v.orders) do
      if j.status=="open" or j.status=="active" then
        if j.drop==m.name then return fail("site has orders") end
        for _,l in ipairs(j.lines) do if l.source==m.name then return fail("site has orders") end end
      end
    end
    local count=0 for _ in pairs(v.sites) do count=count+1 end
    if count>=32 and not v.sites[m.name] then return fail("site limit") end
    if (v.locationsRevision or 0)>=2147483647 then return fail("location revision limit") end
    v.sites[m.name]=A.copy(m.site) v.sites[m.name].stock=nil
    v.locationsRevision=(v.locationsRevision or 0)+1
    return {ok=true}
  elseif m.op=="wh-sites" then
    if m.name~=nil then
      if not v.sites[m.name] then return fail("unknown site") end
      local site=A.copy(v.sites[m.name]) site.stock=nil return {ok=true,site=site}
    end
    local names={} for name in pairs(v.sites) do names[#names+1]=name end table.sort(names)
    return {ok=true,names=names}
  elseif m.op=="wh-stock" then
    local site=v.sites[m.name]
    if not site or site.kind~="source" or not stock(m.stock) or v.locks[m.name] and v.locks[m.name]~=id then return fail("invalid stock report") end
    site.stock=A.copy(m.stock) return {ok=true}
  elseif m.op=="wh-order" then
    if not word(m.key) or not v.sites[m.drop] or v.sites[m.drop].kind~="drop"
      or type(m.lines)~="table" or #m.lines<1 or #m.lines>8 then return fail("invalid order") end
    local j={key=m.key,drop=m.drop,status="open",lines={}}
    for i,l in pairs(m.lines) do
      if not int(i,1,#m.lines) or type(l)~="table" or not word(l.item) or not int(l.count,1,4096)
        or not v.sites[l.source] or v.sites[l.source].kind~="source" then return fail("invalid order line") end
      j.lines[i]={item=l.item,wanted=l.count,count=0,picked=0,delivered=0,source=l.source}
    end
    if v.orders[m.key] then
      local old=v.orders[m.key]
      if old.drop~=j.drop or #old.lines~=#j.lines then return fail("order key conflict") end
      for i,l in ipairs(j.lines) do
        local x=old.lines[i]
        if x.item~=l.item or x.wanted~=l.wanted or x.source~=l.source then return fail("order key conflict") end
      end
      return {ok=true,job=A.copy(old)}
    end
    local count=0 for _ in pairs(v.orders) do count=count+1 end
    if count>=32 then return fail("order limit; archive completed orders") end
    v.orders[m.key]=j return {ok=true,job=A.copy(j)}
  elseif m.op=="wh-lock" or m.op=="wh-unlock" then
    if not v.sites[m.name] then return fail("unknown site") end
    if v.locks[m.name] and v.locks[m.name]~=id then
      if m.op=="wh-unlock" then return {ok=true} end
      return fail("bay occupied")
    end
    v.locks[m.name]=m.op=="wh-lock" and id or nil
    return {ok=true,site=A.copy(v.sites[m.name])}
  elseif m.op=="wh-claim" then
    if not s.poses[id] or s.poses[id].boot~=m.boot then return fail("sync before warehouse work") end
    local keys={} for key,j in pairs(v.orders) do
      if j.status=="active" and j.owner==id then return {ok=true,job=A.copy(j)} end
      if j.status=="open" then keys[#keys+1]=key end
    end
    table.sort(keys)
    if not keys[1] then return {ok=true} end
    local j=v.orders[keys[1]]
    j.status,j.owner="active",id s.seq=s.seq+1 j.token=epoch..":wh:"..s.seq
    for _,l in ipairs(j.lines) do
      local available=(v.sites[l.source].stock or {})[l.item] or 0
      for _,other in pairs(v.orders) do
        if other.status=="active" then
          for _,x in ipairs(other.lines) do
            if x.source==l.source and x.item==l.item then available=available-(x.count-x.picked) end
          end
        end
      end
      l.count=math.max(0,math.min(l.wanted,available))
    end
    return {ok=true,job=A.copy(j)}
  end
  local j
  if not s.poses[id] or s.poses[id].boot~=m.boot then return fail("sync before warehouse progress") end
  for _,x in pairs(v.orders) do if x.owner==id and x.token==m.token then j=x break end end
  if not j then return fail("stale warehouse token") end
  if m.op=="wh-progress" then
    local l=int(m.line,1,#j.lines) and j.lines[m.line]
    if j.status~="active" or not l or not int(m.picked,l.picked,l.count) or not int(m.delivered,l.delivered,m.picked) then return fail("invalid order progress") end
    local counts=v.sites[l.source].stock or {}
    counts[l.item]=math.max(0,(counts[l.item] or 0)-(m.picked-l.picked)) v.sites[l.source].stock=counts
    l.picked,l.delivered=m.picked,m.delivered
    return {ok=true}
  elseif m.op=="wh-finish" then
    if j.status=="done" or j.status=="partial" then return {ok=true,status=j.status} end
    local complete=true
    for _,l in ipairs(j.lines) do
      if l.picked~=l.delivered then return fail("cargo still outstanding") end
      if l.delivered<l.wanted then complete=false end
    end
    j.status=complete and "done" or "partial"
    return {ok=true,status=j.status}
  end
  return fail("unknown warehouse operation")
end
return M
