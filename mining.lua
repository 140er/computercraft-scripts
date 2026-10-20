local M={}
local A,S,T=dofile("atomic.lua"),dofile("ssot.lua"),dofile("mine-tasks.lua")
local vectors={[0]={0,0,-1},{1,0,0},{0,0,1},{-1,0,0},{0,1,0},{0,-1,0}}
local function key(p) return p.x..","..p.y..","..p.z end
local function same(a,b) return a.dim==b.dim and key(a)==key(b) end
local function neighbor(p,d)
  local v=vectors[d]
  return {dim=p.dim,x=p.x+v[1],y=p.y+v[2],z=p.z+v[3],h=p.h}
end
local ground={}
for _,n in ipairs({"stone","deepslate","tuff","dirt","gravel","granite","diorite","andesite","netherrack"}) do ground["minecraft:"..n]=true end
function M.ore(info,targets)
  if targets and targets[info.name] then return true end
  for tag,on in pairs(info.tags or {}) do
    if on and (tag=="c:ores" or tag=="forge:ores" or tag:match("^c:ores/") or tag:match("^forge:ores/")) then return true end
  end
  return info.name:match("_ore$")~=nil or info.name=="minecraft:ancient_debris"
end
function M.excavatable(info,targets)
  return not (info.state and info.state.waterlogged) and (ground[info.name]==true or M.ore(info,targets))
end
function M.open(cfg)
  local nav,client=assert(cfg.nav),assert(cfg.client)
  assert(S.pose(cfg.home) and type(cfg.home.h)=="number" and cfg.home.h%1==0 and cfg.home.h>=0 and cfg.home.h<4,"mining home pose required")
  local function valid(v)
    if type(v)~="table" or v.version~=1 or type(v.stack)~="table" or #v.stack>768
      or type(v.visited)~="table" or type(v.hazards)~="table" or type(v.progress)~="number"
      or v.progress%1~=0 or v.progress<0 or v.progress>64 then return false end
    if v.task and (not S.pose(v.task.entry) or not S.pose(v.task.min) or not S.pose(v.task.max) or type(v.task.token)~="string") then return false end
    for _,f in ipairs(v.stack) do if not S.pose(f.pose) or type(f.next)~="number" or f.next%1~=0 or f.next<0 or f.next>6 then return false end end
    return v.phase=="work" or v.phase=="return" or v.phase=="home" or v.phase=="resume" or v.phase=="done"
  end
  local store=A.store(cfg.path or "mining.state",valid,250000)
  local state=store.value or {version=1,stack={},visited={},hazards={},progress=0,phase="home"}
  local api={}
  local function save(point)
    assert(store.save(state))
    if point and cfg.checkpoint then cfg.checkpoint(point) end
  end
  local function request(op,fields)
    local r,why=client.call(op,fields)
    if not r or not r.ok then return nil,why or r and r.error or "mining server unavailable" end
    return r
  end
  local function reconcile()
    local j=state.action
    if not j then return end
    local p=nav.pose()
    if same(p,j.to) then
      if j.kind=="push" then
        state.stack[#state.stack].next=state.stack[#state.stack].next+1
        state.stack[#state.stack+1]={pose=A.copy(p),next=0}
        state.visited[key(p)]=true
      elseif j.kind=="pop" then state.stack[#state.stack]=nil
      elseif j.kind=="tunnel" then
        state.progress=state.progress+1 state.stack={{pose=A.copy(p),next=0}}
        state.visited[key(p)]=true
      end
    else assert(same(p,j.from),"mining action needs pose reconciliation") end
    state.action=nil save("action-saved")
  end
  local function move(kind,to,fn)
    state.action={kind=kind,from=nav.pose(),to=A.copy(to)} save("action-prepared")
    local ok,why=fn()
    if cfg.checkpoint then cfg.checkpoint("action-physical") end
    reconcile()
    return ok,why
  end
  function api.state() return A.copy(state) end
  function api.interrupt(reason)
    if state.phase~="done" then state.phase="return" state.reason=reason or "recall" save("return-saved") end
  end
  function api.start()
    reconcile()
    if state.phase=="home" and state.reason=="complete" then return api.finish() end
    local r,why=request("mine-lease")
    if not r then return false,why end
    if not r.task then return false,"mine exhausted" end
    if state.task then
      assert(state.task.token==r.task.token and state.progress>=r.task.progress,"mining lease changed; reconcile saved work")
      state.task.progress=r.task.progress
    else
      assert(r.task.progress==0,"mining traversal missing; do not skip queued ore")
      state.task=A.copy(r.task) state.progress=0 state.stack={} state.visited={} state.hazards={}
    end
    local ack,err=request("mine-progress",{token=state.task.token,progress=state.task.progress})
    if not ack then return false,err end
    if state.phase=="home" or state.phase=="done" then state.phase="resume" end
    save("lease-saved")
    return true
  end
  local function interruptReason()
    if cfg.cancelled and cfg.cancelled() then return "recall" end
    local free=0
    for slot=1,16 do if turtle.getItemCount(slot)==0 then free=free+1 end end
    if free<2 then return "inventory full" end
    local fuel=turtle.getFuelLevel()
    local distance,why=nav.homeCost(cfg.home)
    if distance==false then return "no home route: "..tostring(why) end
    if fuel~="unlimited" and fuel<=distance+(cfg.fuelMargin or 32) then return "low fuel" end
  end
  function api.tick()
    reconcile()
    if nav.stopped() then return false,"cancelled" end
    if state.phase=="done" or not state.task then return false,state.phase end
    if state.phase=="home" then return false,state.reason or "home" end
    if state.phase=="return" then
      local ok,why=nav.go(cfg.home,"walk")
      if not ok then return false,"no home route: "..tostring(why) end
      ok,why=nav.face(cfg.home.h)
      if not ok then return false,why end
      state.phase="home" save("home-saved")
      return false,state.reason or "home"
    end
    local reason=interruptReason()
    if reason then api.interrupt(reason) return true end
    local r,why=request("mine-progress",{token=state.task.token,progress=state.task.progress})
    if not r then api.interrupt(why) return false,why end
    if state.phase=="resume" then
      local target=#state.stack>0 and state.stack[#state.stack].pose or state.task.entry
      local ok,err=nav.go(target,"walk")
      if not ok then return false,"no resume route: "..tostring(err) end
      ok,err=nav.face(target.h or 2)
      if not ok then return false,err end
      state.phase="work" state.reason=nil save("resume-saved")
      return true
    end
    local frame=state.stack[#state.stack]
    if not frame then
      if state.progress==state.task.max.z-state.task.min.z+1 then
        api.interrupt("complete") return true
      end
      local to=neighbor(nav.pose(),2)
      if not T.inside(to,state.task) then return false,"outside mining lease" end
      for _,p in pairs(state.hazards) do
        if math.abs(p.x-to.x)+math.abs(p.y-to.y)+math.abs(p.z-to.z)<=1 then
          api.interrupt("hazard buffer") return true
        end
      end
      local ok,err=move("tunnel",to,function() return nav.step(2,"excavate") end)
      if not ok then api.interrupt(err) end
      return true
    end
    if not frame.scanned then
      for d=0,5 do
        if d<4 then local ok,err=nav.face(d) if not ok then return false,err end end
        local found,info=(d==4 and turtle.inspectUp or d==5 and turtle.inspectDown or turtle.inspect)()
        if found and (info.name=="minecraft:water" or info.name=="minecraft:lava") then
          local p=neighbor(nav.pose(),d) state.hazards[key(p)]=p
          api.interrupt("fluid hazard") return true
        end
        if cfg.yield then cfg.yield() elseif sleep then sleep(0) end
      end
      frame.scanned=true save()
      return true
    end
    if frame.next==6 then
      if #state.stack==1 then
        local ok,err=nav.face(frame.pose.h)
        if not ok then return false,err end
        state.stack={}
        local ack,err=request("mine-progress",{token=state.task.token,progress=state.progress})
        if not ack then return false,err end
        state.task.progress=state.progress save("strip-saved")
      else
        local parent=state.stack[#state.stack-1].pose
        local ok,err=move("pop",parent,function() return nav.go(parent,"walk") end)
        if not ok then return false,"no vein return route: "..tostring(err) end
        local faced,why=nav.face(parent.h) if not faced then return false,why end
      end
      return true
    end
    local d=frame.next
    if d<4 then local ok,err=nav.face(d) if not ok then return false,err end end
    local found,info=(d==4 and turtle.inspectUp or d==5 and turtle.inspectDown or turtle.inspect)()
    local to=neighbor(nav.pose(),d)
    if found and (info.name=="minecraft:water" or info.name=="minecraft:lava") then
      state.hazards[key(to)]=A.copy(to)
    end
    local safe=true
    for _,p in pairs(state.hazards) do
      if math.abs(p.x-to.x)+math.abs(p.y-to.y)+math.abs(p.z-to.z)<=1 then safe=false end
    end
    if found and safe and T.inside(to,state.task) and M.ore(info,cfg.targets) and not state.visited[key(to)] then
      if #state.stack>=768 then api.interrupt("vein budget") return false,"vein budget" end
      local ok,err=move("push",to,function() return nav.step(d,"excavate") end)
      if not ok then api.interrupt(err) end
    else
      frame.next=d+1 save()
    end
    return true
  end
  function api.finish()
    if state.phase~="home" or state.reason~="complete" then return false,"mining not complete at home" end
    local r,why=request("mine-finish",{token=state.task.token})
    if not r then return false,why end
    state.phase="done" state.task=nil save("finished-saved") return true
  end
  return api
end
return M
