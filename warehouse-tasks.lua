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
local function fingerprint(v)
  return v==false or type(v)=="string" and #v>0 and #v<=128
end
local function layoutMod()
  local ok,mod=pcall(dofile,"wh2-layout.lua")
  if ok and type(mod)=="table" then return mod end
end
local function siteHeld(v,name)
  if v.locks[name] then return true end
  for _,job in pairs(v.orders) do
    if job.status=="open" or job.status=="active" then
      if job.drop==name then return true end
      for _,line in ipairs(job.lines) do if line.source==name then return true end end
    end
  end
end
-- Layout arms this by setting s.wh2.layout.enabled. Until then the legacy caps stay.
local function layoutCaps(s,v,pose)
  local tree=type(s.wh2)=="table" and s.wh2.layout or nil
  if type(tree)=="table" and tree.enabled==true then v.raised=true end
  if v.raised~=true then return false end
  local mod=layoutMod()
  if not mod or type(mod.project)~="function" then return true end
  local count=0 for _ in pairs(v.sites) do count=count+1 end
  for name,site in pairs(mod.project(tree)) do
    if pose(site.pose) and (site.kind=="source" or site.kind=="drop" or site.kind=="charge") then
      if not siteHeld(v,name) then
        local kept=v.sites[name] and v.sites[name].kind==site.kind and v.sites[name].stock or nil
        if v.sites[name] or count<256 then
          if not v.sites[name] then count=count+1 end
          v.sites[name]=site
          if kept then v.sites[name].stock=kept end
        end
      elseif not v.sites[name] and count<256 then
        v.sites[name],count=site,count+1
      end
    end
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
  if v.raised~=nil and v.raised~=true then return false end
  local siteCap,orderCap,lineCap=v.raised==true and 256 or 32,v.raised==true and 256 or 32,v.raised==true and 64 or 8
  local n=0
  for name,s in pairs(v.sites) do
    n=n+1
    if n>siteCap or not word(name) or not M.site(s,pose) or s.stock and not stock(s.stock) then return false end
  end
  for name,id in pairs(v.locks) do if not v.sites[name] or not int(id,0,2147483647) then return false end end
  n=0
  for key,j in pairs(v.orders) do
    n=n+1
    if n>orderCap or not word(key) or type(j)~="table" or j.key~=key or not v.sites[j.drop]
      or v.sites[j.drop].kind~="drop" or type(j.lines)~="table" or #j.lines<1 or #j.lines>lineCap
      or j.status~="open" and j.status~="active" and j.status~="done" and j.status~="partial"
      or j.status~="open" and j.owner==nil or j.status=="open" and j.owner~=nil
      or j.owner~=nil and (not int(j.owner,0,2147483647) or not word(j.token))
      or (j.job~=nil or j.step~=nil) and (v.raised~=true or not word(j.job) or not int(j.step,1,128)) then return false end
    for i,l in pairs(j.lines) do
      if not int(i,1,#j.lines) or type(l)~="table" or not word(l.item) or not v.sites[l.source]
        or v.sites[l.source].kind~="source" or not int(l.wanted,1,4096) or not int(l.count,0,l.wanted)
        or not int(l.picked,0,l.count) or not int(l.delivered,0,l.picked)
        or l.nbt~=nil and (v.raised~=true or not fingerprint(l.nbt)) then return false end
    end
  end
  return true
end
function M.run(s,id,m,epoch,pose)
  local function fail(err) return {ok=false,error=err} end
  local v=s.warehouse or {sites={},orders={},locks={}}
  s.warehouse=v
  local raised=layoutCaps(s,v,pose)
  local siteCap,orderCap,lineCap=raised and 256 or 32,raised and 256 or 32,raised and 64 or 8
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
    if count>=siteCap and not v.sites[m.name] then return fail("site limit") end
    v.sites[m.name]=A.copy(m.site) v.sites[m.name].stock=nil
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
      or type(m.lines)~="table" or #m.lines<1 or #m.lines>lineCap then return fail("invalid order") end
    if (m.job~=nil or m.step~=nil) and (not raised or not word(m.job) or not int(m.step,1,128)) then return fail("invalid order") end
    local j={key=m.key,drop=m.drop,status="open",lines={}}
    if m.job~=nil then j.job,j.step=m.job,m.step end
    for i,l in pairs(m.lines) do
      if not int(i,1,#m.lines) or type(l)~="table" or not word(l.item) or not int(l.count,1,4096)
        or not v.sites[l.source] or v.sites[l.source].kind~="source"
        or l.nbt~=nil and (not raised or not fingerprint(l.nbt)) then return fail("invalid order line") end
      j.lines[i]={item=l.item,wanted=l.count,count=0,picked=0,delivered=0,source=l.source}
      if l.nbt~=nil then j.lines[i].nbt=l.nbt end
    end
    if v.orders[m.key] then
      local old=v.orders[m.key]
      if old.drop~=j.drop or #old.lines~=#j.lines then return fail("order key conflict") end
      for i,l in ipairs(j.lines) do
        local x=old.lines[i]
        if x.item~=l.item or x.wanted~=l.wanted or x.source~=l.source or x.nbt~=l.nbt then return fail("order key conflict") end
      end
      return {ok=true,job=A.copy(old)}
    end
    local count=0 for _ in pairs(v.orders) do count=count+1 end
    if count>=orderCap then return fail("order limit; archive completed orders") end
    if raised then
      local mod=layoutMod()
      if mod and (mod.encoded(j)>8192 or mod.encoded(v.orders)>98304 or mod.encoded(v.sites)>65536) then
        return fail("order limit; archive completed orders")
      end
    end
    v.orders[m.key]=j return {ok=true,job=A.copy(j)}
  elseif m.op=="wh-lock" or m.op=="wh-unlock" then
    if not v.sites[m.name] then return fail("unknown site") end
    local names={m.name}
    if raised then
      local mod=layoutMod()
      local tree=s.wh2 and s.wh2.layout
      if mod and tree then names=mod.lockGroup(tree,m.name) end
    end
    for _,name in ipairs(names) do if not v.sites[name] then return fail("unknown site") end end
    for _,name in ipairs(names) do
      if v.locks[name] and v.locks[name]~=id then
        if m.op=="wh-unlock" then return {ok=true} end
        return fail("bay occupied")
      end
    end
    for _,name in ipairs(names) do v.locks[name]=m.op=="wh-lock" and id or nil end
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
      if type(l.nbt)=="string" then
        l.count=0
      else
        local available=(v.sites[l.source].stock or {})[l.item] or 0
        for _,other in pairs(v.orders) do
          if other.status=="active" then
            for _,x in ipairs(other.lines) do
              if x.source==l.source and x.item==l.item and type(x.nbt)~="string" then available=available-(x.count-x.picked) end
            end
          end
        end
        l.count=math.max(0,math.min(l.wanted,available))
      end
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
