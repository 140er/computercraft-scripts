local M={}
local function int(v,a,b) return type(v)=="number" and v%1==0 and v>=a and v<=b end
function M.inside(p,b)
  return p.dim==b.min.dim and p.x>=b.min.x and p.x<=b.max.x and p.y>=b.min.y
    and p.y<=b.max.y and p.z>=b.min.z and p.z<=b.max.z
end
function M.zone(z,pose)
  if type(z)~="table" or not pose(z.min) or not pose(z.max) or z.min.dim~=z.max.dim
    or not int(z.spacing,2,4) then return false end
  local x,y,d=z.max.x-z.min.x+1,z.max.y-z.min.y+1,z.max.z-z.min.z+1
  return x>=z.spacing and x%z.spacing==0 and y>=3 and y%3==0 and d>=1 and d<=64
    and x/z.spacing*y/3<=128 and z.spacing*3*d<=768
end
function M.valid(s,pose)
  if s==nil then return true end
  if type(s)~="table" or not M.zone(s.zone,pose) or type(s.tasks)~="table" or #s.tasks>128 then return false end
  local z=s.zone
  local width=(z.max.x-z.min.x+1)/z.spacing
  local count=width*(z.max.y-z.min.y+1)/3
  if #s.tasks~=count then return false end
  local tokens={}
  for i,t in pairs(s.tasks) do
    if not int(i,1,128) or type(t)~="table" or not pose(t.min) or not pose(t.max) or not pose(t.entry)
      or not int(t.progress,0,z.max.z-z.min.z+1) or t.status~="open" and t.status~="offered" and t.status~="active" and t.status~="done"
      or t.owner~=nil and (not int(t.owner,0,2147483647) or type(t.token)~="string"
        or #t.token>80 or not int(t.untilAt,0,9007199254740991)) then return false end
    local x=z.min.x+(i-1)%width*z.spacing
    local y=z.min.y+math.floor((i-1)/width)*3
    if i>count or t.min.x~=x or t.max.x~=x+z.spacing-1 or t.min.y~=y or t.max.y~=y+2
      or t.min.z~=z.min.z or t.max.z~=z.max.z or t.min.dim~=z.min.dim or t.max.dim~=z.min.dim
      or t.entry.x~=x+1 or t.entry.y~=y+1 or t.entry.z~=z.min.z-1 or t.entry.dim~=z.min.dim
      or t.status=="open" and (t.owner~=nil or t.progress~=0)
      or t.status~="open" and (not t.owner or t.id~=i or tokens[t.token])
      or t.status=="done" and t.progress~=z.max.z-z.min.z+1 then return false end
    if t.token then tokens[t.token]=true end
  end
  return true
end
function M.run(s,id,m,clock,epoch,pose)
  local function fail(why) return {ok=false,error=why} end
  if m.op=="mine-config" then
    if not M.zone(m.zone,pose) then return fail("invalid mine bounds or spacing") end
    if s.mining then
      for _,t in ipairs(s.mining.tasks) do if t.status~="done" and t.status~="open" then return fail("mine has assigned tasks") end end
    end
    local A=dofile("atomic.lua")
    local mine={zone=A.copy(m.zone),tasks={}}
    local z=mine.zone
    for y=z.min.y,z.max.y,3 do
      for x=z.min.x,z.max.x,z.spacing do
        local function p(a,b,c) return {dim=z.min.dim,x=a,y=b,z=c} end
        mine.tasks[#mine.tasks+1]={min=p(x,y,z.min.z),max=p(x+z.spacing-1,y+2,z.max.z),
          entry=p(x+1,y+1,z.min.z-1),progress=0,status="open"}
      end
    end
    s.mining=mine
    return {ok=true,count=#mine.tasks}
  end
  if not s.mining or not s.poses[id] or s.poses[id].boot~=m.boot then return fail("sync before mining") end
  local now=clock()
  if m.op=="mine-lease" then
    for _,t in ipairs(s.mining.tasks) do
      if t.owner==id and t.status~="done" then
        t.untilAt=now+30000
        return {ok=true,task=t}
      end
    end
    local candidate,score
    local p=s.poses[id]
    for i,t in ipairs(s.mining.tasks) do
      if t.status=="open" or t.status=="offered" and t.untilAt<=now then
        local distance=math.abs(p.x-t.entry.x)+math.abs(p.y-t.entry.y)+math.abs(p.z-t.entry.z)
        if p.dim==t.entry.dim and (not score or distance<score) then candidate,score=i,distance end
      end
    end
    if candidate then
      local t=s.mining.tasks[candidate]
      s.seq=s.seq+1
      t.owner,t.token,t.untilAt,t.status=id,epoch..":mine:"..s.seq,now+30000,"offered"
      t.id=candidate
      return {ok=true,task=t}
    end
    return {ok=true}
  end
  local t
  for _,task in ipairs(s.mining.tasks) do if task.owner==id and task.token==m.token then t=task break end end
  if t and t.status=="done" and m.op=="mine-finish" then return {ok=true} end
  if not t or t.status=="done" or t.untilAt<=now and m.op~="mine-finish" then return fail("expired or stale mining token") end
  if m.op=="mine-progress" then
    local length=t.max.z-t.min.z+1
    if not int(m.progress,t.progress,length) then return fail("invalid mining progress") end
    t.progress,t.status,t.untilAt=m.progress,"active",now+30000
    return {ok=true}
  elseif m.op=="mine-finish" then
    if t.progress~=t.max.z-t.min.z+1 then return fail("unfinished strip") end
    t.status="done"
    return {ok=true}
  end
  return fail("unknown mining operation")
end
return M
