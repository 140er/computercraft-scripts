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
  local function autonomous()
    return type(cfg.b1)=="table" and cfg.b1.enabled==true and cfg.b1.offline and cfg.b1.offline()
  end
  local function request(op,fields)
    local r,why=client.call(op,fields)
    if not r or not r.ok then return nil,why or r and r.error or "mining server unavailable" end
    return r
  end
  local function options()
    if cfg.fleet then return cfg.fleet.settings() end
  end
  local function boundary(kind)
    if cfg.beforeAction then return cfg.beforeAction(kind) end
    return true
  end
  local function inventoryFull(v)
    local free=0
    for slot=1,16 do if turtle.getItemCount(slot)==0 then free=free+1 end end
    return free<(v and v.minFreeSlots or 2) or v and (16-free)/16>=v.fullnessHigh
  end
  local serviceWorker
  local function location(kind,from,selector)
    local origin=nav.fleetPose(from)
    if not origin then return nil,"confirmed service origin required" end
    local loc,why=cfg.fleet.location(kind,origin,selector)
    if not loc then return nil,why end
    local name=loc.siteNames and loc.siteNames[kind=="charge" and "charge" or "drop"]
    local target,err=nav.legacyTarget(loc.access and loc.access.pose)
    if not target then return nil,err end
    if type(name)~="string" or #name==0 then return nil,"shared location has no warehouse site" end
    return {name=name,locationId=loc.id,pose=target,side=loc.access.side}
  end
  local function reserveServices()
    local v,revision=cfg.fleet.settings()
    local reserve=0
    for _,service in ipairs({{v.warehouse and v.autoDropoff,"dropoff",v.dropoffId},
      {v.warehouse and v.autoCharge and turtle.getFuelLevel()~="unlimited","charge",v.chargerId}}) do
      if service[1] then
        local site,why=location(service[2],cfg.home,service[3]) if not site then return false,why end
        local out,why=nav.homeCost(site.pose,cfg.home) if out==false then return false,why end
        local back,why=nav.homeCost(cfg.home,site.pose) if back==false then return false,why end
        reserve=reserve+out+back
      end
    end
    state.serviceReserve=reserve state.serviceSettingsRevision=revision
    return true
  end
  local function droppable(v)
    for slot=1,16 do
      local item=turtle.getItemDetail(slot)
      if item and not v.keep[item.name] then return true end
    end
    return false
  end
  local function reconcile()
    local j=state.action
    if not j then return end
    local p=nav.pose()
    if same(p,j.to) then
      if j.kind=="push" then
        state.stack[#state.stack].next=state.stack[#state.stack].next+1
        state.stack[#state.stack].queued=nil
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
    if kind=="push" then state.stack[#state.stack].queued=state.stack[#state.stack].next end
    state.action={kind=kind,from=nav.pose(),to=A.copy(to)} save("action-prepared")
    local ok,why=fn()
    if cfg.checkpoint then cfg.checkpoint("action-physical") end
    reconcile()
    return ok,why
  end
  function api.state() return A.copy(state) end
  function api.interrupt(reason)
    if state.phase~="done" or reason=="recharge" then state.phase="return" state.reason=reason or "recall" save("return-saved") end
  end
  local function fleetService()
    local ok,why=boundary("poll") if not ok then return false,why end
    if state.phase~="home" and state.phase~="done" then return false,"return home before service" end
    local v,revision=options()
    state.serviceActionRevision=revision
    if not serviceWorker then
      serviceWorker=dofile("warehouse.lua").open({nav=nav,client=client,
        path=cfg.service and cfg.service.path or "mining-warehouse.state",settings=options,beforeAction=boundary})
    end
    local w=serviceWorker
    local pending=w.state()
    if not state.service then
      if pending.phase=="charge" then state.service="charge"
      elseif pending.phase=="unload" then state.service="drop"
      else
        local reserved,err=reserveServices() if not reserved then return false,err end
        local fuel=turtle.getFuelLevel()
        local need=math.max(v.minTripFuel,(state.serviceReserve or 0)+v.fuelMargin)
        if v.warehouse and v.autoCharge and fuel~="unlimited" and (fuel<=v.fuelLow or fuel<need) then
          if v.fuelTarget<need then return false,"fuel target cannot cover mining and service routes" end
          state.service="charge"
        elseif v.warehouse and v.autoDropoff and inventoryFull(v) then
          if not droppable(v) then return false,"inventory full; all items are kept" end
          state.service="drop"
        else return true end
      end
      save()
    end
    if state.service=="drop" or state.service=="charge" then
      local charging=state.service=="charge"
      local enabled=v.warehouse and (charging and v.autoCharge or not charging and v.autoDropoff)
      local reason=charging and "auto-charge disabled" or "auto-drop-off disabled"
      if not charging then
        local old=state.dropThresholds
        if enabled and old and (old.minFreeSlots~=v.minFreeSlots or old.fullnessHigh~=v.fullnessHigh)
          and not inventoryFull(v) then enabled=false reason="drop-off threshold changed" end
        if enabled and not droppable(v) then enabled=false reason="no items available for drop-off" end
        state.dropThresholds={minFreeSlots=v.minFreeSlots,fullnessHigh=v.fullnessHigh}
      end
      if not enabled then
        if pending.phase=="unload" or pending.phase=="charge" and not pending.charge.returning then
          local ok,why=w.cancelService(reason,not charging and not (v.warehouse and v.autoDropoff))
          if not ok then return false,why end
          pending=w.state()
        end
        if pending.phase~="charge" then state.service="home" save() end
      elseif not (pending.phase=="charge" and pending.charge.returning) then
        if (pending.phase=="idle" or pending.phase=="done") and not charging and not inventoryFull(v) then state.service="home" save()
        else
          local ok,why=boundary(charging and "charge" or "drop") if not ok then return false,why end
          local selector=v.dropoffId
          if charging then selector=v.chargerId end
          local site,err=location(charging and "charge" or "dropoff",nav.pose(),selector)
          if not site then return false,err end
          local out,err=nav.homeCost(site.pose) if out==false then return false,err end
          local back,err=nav.homeCost(cfg.home,site.pose) if back==false then return false,err end
          local fuel=turtle.getFuelLevel()
          if fuel~="unlimited" and fuel<out+back+v.warehouseFuelMargin then return false,"insufficient fuel for service and home" end
          if pending.phase=="idle" or pending.phase=="done" then
            if charging then ok,why=w.charge(site.name,v.fuelTarget,v.chargeTimeoutMs,site)
            else ok,why=w.unload(site.name,v.keep) end
            if not ok then return false,why end
          end
          ok,why=w.bindService(site)
          if not ok then return false,why end
        end
      end
      if state.service~="home" then
        local ok,why=w.tick()
        if w.state().phase~="done" then return false,why or (charging and "charging" or "dropping") end
        state.service=charging and enabled and "drop" or "home"
        if charging and not ok and enabled then state.serviceError=why end
        save()
        return false,why or "service"
      end
    end
    local ok,why=boundary("return") if not ok then return false,why end
    ok,why=nav.go(cfg.home,"walk") if not ok then return false,why end
    ok,why=nav.face(cfg.home.h) if not ok then return false,why end
    local err=state.serviceError
    state.service=nil state.serviceError=nil state.dropThresholds=nil save("service-saved")
    return not err,err
  end
  function api.service(cancelled)
    if cfg.fleet then return fleetService() end
    if not cfg.service or cfg.service.enabled~=true then return false,"mining service disabled" end
    if state.phase~="home" then return false,"return home before service" end
    local w=dofile("warehouse.lua").open({nav=nav,client=client,path=cfg.service.path or "mining-warehouse.state"})
    local function cancelService()
      if not cancelled or not cancelled() then return end
      local ok,why=w.cancelService()
      if not ok then return why or "cancelled" end
      ok,why=nav.go(cfg.home,"walk")
      if not ok then return why end
      ok,why=nav.face(cfg.home.h)
      if not ok then return why end
      state.service=nil
      save()
      return "cancelled"
    end
    local cancelledReason=cancelService()
    if cancelledReason then return false,cancelledReason end
    if not state.service then state.service="drop" save() end
    if state.service=="drop" then
      if not cfg.service.drop then return false,"configure a drop pose" end
      if w.state().phase~="unload" then local ok,why=w.unload(cfg.service.drop,cfg.service.keep) if not ok then return false,why end end
      repeat
        local why=cancelService()
        if why then return false,why end
        local ok,why=w.tick() if not ok and w.state().phase~="done" then return false,why end
        (cfg.yield or sleep)(.1)
      until w.state().phase=="done"
      state.service="charge" save()
    end
    if state.service=="charge" then
      local target=cfg.service.targetFuel or 2000
      if turtle.getFuelLevel()~="unlimited" and turtle.getFuelLevel()<target or w.state().phase=="charge" then
        if not cfg.service.charger then return false,"configure a charging pose" end
        local ok,why=w.charge(cfg.service.charger,target,cfg.service.chargeTimeout or 60000) if not ok then return false,why end
        repeat
          local why=cancelService()
          if why then return false,why end
          local moved,err=w.tick()
          if not moved then
            if w.state().phase=="done" then
              local home,why=nav.go(cfg.home,"walk") if not home then return false,why end
              home,why=nav.face(cfg.home.h) if not home then return false,why end
            end
            return false,err
          end
          (cfg.yield or sleep)(.25)
        until w.state().phase=="done"
        if w.state().reason~="charged" and w.state().reason~="unlimited fuel" then return false,w.state().reason end
      end
      state.service="home" save()
    end
    local ok,why=nav.go(cfg.home,"walk") if not ok then return false,why end
    ok,why=nav.face(cfg.home.h) if not ok then return false,why end
    state.service=nil save("service-saved") return true
  end
  function api.start()
    reconcile()
    if cfg.fleet then
      local allowed,why=boundary("poll") if not allowed then return false,why end
      local ok,why=reserveServices() if not ok then return false,why end
    end
    local allowed,why=boundary("mine") if not allowed then return false,why end
    if state.phase=="home" and state.reason=="complete" then return api.finish() end
    if cfg.fleet then
      local v=options()
      if inventoryFull(v) then return false,"inventory full" end
      local fuel=turtle.getFuelLevel()
      if fuel~="unlimited" and (fuel<v.minTripFuel or fuel<=v.fuelLow
        or fuel<=(state.serviceReserve or 0)+v.fuelMargin) then return false,"low fuel" end
    elseif cfg.service and cfg.service.enabled then
      state.serviceReserve=0
      local d,why=request("wh-sites",{name=cfg.service.drop}) if not d then return false,why end
      if d.site.kind~="drop" then return false,"configure a drop pose" end
      local legs={{cfg.home,d.site.pose},{d.site.pose,cfg.home}}
      if turtle.getFuelLevel()~="unlimited" then
        local c,why=request("wh-sites",{name=cfg.service.charger}) if not c then return false,why end
        if c.site.kind~="charge" then return false,"configure a charging pose" end
        legs[#legs+1]={d.site.pose,c.site.pose} legs[#legs+1]={c.site.pose,d.site.pose}
      end
      for _,leg in ipairs(legs) do
        local cost,why=nav.homeCost(leg[2],leg[1]) if cost==false then return false,why end
        state.serviceReserve=state.serviceReserve+cost
      end
    else state.serviceReserve=0 end
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
    if state.phase=="home" or state.phase=="done" then
      state.phase="resume"
      if cfg.fleet then state.tripStarted=os.epoch("utc") state.tripProgress=state.progress end
    end
    save("lease-saved")
    return true
  end
  local function interruptReason()
    if cfg.cancelled and cfg.cancelled() then return "recall" end
    local free=0
    for slot=1,16 do if turtle.getItemCount(slot)==0 then free=free+1 end end
    local v=options()
    if free<(v and v.minFreeSlots or 2) or v and (16-free)/16>=v.fullnessHigh then return "inventory full" end
    if v and state.tripStarted and os.epoch("utc")-state.tripStarted>=v.tripSeconds*1000 then return "trip time" end
    if v and state.progress-(state.tripProgress or 0)>=v.branchLength then return "trip length" end
    local fuel=turtle.getFuelLevel()
    local distance,why=nav.homeCost(cfg.home)
    if distance==false then return "no home route: "..tostring(why) end
    if fuel~="unlimited" and (v and fuel<=v.fuelLow or fuel<=distance+(state.serviceReserve or 0)+(v and v.fuelMargin or cfg.fuelMargin or 32)) then return "low fuel" end
  end
  function api.tick()
    reconcile()
    if nav.stopped() then return false,"cancelled" end
    if state.phase=="done" then return false,state.phase end
    if state.phase=="home" then return false,state.reason or "home" end
    if cfg.fleet then
      local allowed,why=boundary("poll") if not allowed then return false,why end
      local _,revision=options()
      if state.phase~="return" and state.serviceSettingsRevision~=revision then
        local ok,why=reserveServices()
        if not ok then api.interrupt(why) return false,why end
      end
    end
    local allowed,why=boundary(state.phase=="return" and "return" or "mine")
    if not allowed then
      if why=="mining disabled" or why=="inventory full" or why=="low fuel" or why=="mining reach" then api.interrupt(why) return true end
      return false,why
    end
    if state.phase=="return" then
      local ok,why=nav.go(cfg.home,"walk")
      if not ok then return false,"no home route: "..tostring(why) end
      ok,why=nav.face(cfg.home.h)
      if not ok then return false,why end
      state.phase="home" save("home-saved")
      return false,state.reason or "home"
    end
    if not state.task then return false,state.phase end
    if type(cfg.b1)=="table" and cfg.b1.enabled==true and cfg.b1.gate then
      local mode=cfg.b1.gate()
      if mode=="denied" then return false,"lease" end
      if mode=="home" or mode=="check in" then
        api.interrupt(mode=="check in" and "check in" or "journal budget")
        return true
      end
    end
    local reason=interruptReason()
    if reason then api.interrupt(reason) return true end
    if not autonomous() then
      local r,why=request("mine-renew",{token=state.task.token})
      if not r then api.interrupt(why) return false,why end
    end
    if state.phase=="resume" then
      local target=#state.stack>0 and state.stack[#state.stack].pose or A.copy(state.task.entry)
      if #state.stack==0 then target.z=target.z+state.progress end
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
    local v=options()
    if v and v.miningMode=="fast" and #state.stack==1 and frame.queued==nil and frame.next<6 then
      frame.next=6 save()
    end
    if not frame.scanned then
      for d=0,5 do
        if d<4 then local ok,err=nav.face(d) if not ok then return false,err end end
        local allowed,why=boundary("mine")
        if not allowed then if why=="mining disabled" then api.interrupt(why) end return false,why end
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
        if not autonomous() then
          local renewed,why=request("mine-renew",{token=state.task.token})
          if not renewed then return false,why end
          local ack,err=request("mine-progress",{token=state.task.token,progress=state.progress})
          if not ack then return false,err end
        end
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
    local v=options()
    local targets=v and v.miningTargets or cfg.targets
    if frame.queued==d and found and not M.ore(info,targets) then api.interrupt("queued ore blocked") return true end
    if safe and T.inside(to,state.task) and not state.visited[key(to)]
      and (found and M.ore(info,targets) or frame.queued==d and not found) then
      if #state.stack>=768 then api.interrupt("vein budget") return false,"vein budget" end
      if v and #state.stack>=v.veinLimit then api.interrupt("vein limit") return true end
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
