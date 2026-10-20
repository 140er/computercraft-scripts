local M={}
local A,S=dofile("atomic.lua"),dofile("ssot.lua")
function M.open(cfg)
  local nav,client=assert(cfg.nav),assert(cfg.client)
  local clock=cfg.clock or function() return os.epoch("utc") end
  local phases={idle=true,pickup=true,restore=true,deliver=true,unload=true,charge=true,done=true}
  local function integer(n,a,b) return type(n)=="number" and n%1==0 and n>=a and n<=b end
  local function slots(v)
    if type(v)~="table" then return false end
    for slot,item in pairs(v) do
      if not integer(slot,1,16) or type(item)~="table" or type(item.name)~="string" or #item.name>128 or not integer(item.count,1,4096) then return false end
    end
    return true
  end
  local function valid(v)
    return type(v)=="table" and v.version==1 and phases[v.phase]==true and slots(v.cargo)
      and slots(v.escrow) and integer(v.line,1,9)
      and (v.phase~="charge" or type(v.charge)=="table" and type(v.charge.name)=="string"
        and integer(v.charge.target,0,100000) and integer(v.charge.queuedUntil,0,9007199254740991)
        and integer(v.charge.timeout,1000,3600000))
      and (not v.pending or type(v.pending)=="table" and S.pose(v.pending.pose)
        and integer(v.pending.slot,1,16) and integer(v.pending.before,0,4096) and integer(v.pending.count,1,4096)
        and (v.pending.kind=="pickup" or v.pending.kind=="restore" or v.pending.kind=="deliver" or v.pending.kind=="unload"))
  end
  local disk=A.store(cfg.path or "warehouse.state",valid,64000)
  local state=disk.value or {version=1,phase="idle",line=1,cargo={},escrow={}}
  local api,confirmedLock={},nil
  local function save(point)
    assert(disk.save(state))
    if point and cfg.checkpoint then cfg.checkpoint(point) end
  end
  local function call(op,v)
    local r,err=client.call(op,v)
    if not r or not r.ok then return nil,err or r and r.error or "warehouse server unavailable" end
    return r
  end
  local function release()
    if state.lock then
      local r,err=call("wh-unlock",{name=state.lock}) if not r then return false,err end
      state.lock=nil state.site=nil confirmedLock=nil save()
    end
    return true
  end
  local function reach(name,kind)
    if state.lock~=name or confirmedLock~=name then
      if state.lock~=name then local ok,err=release() if not ok then return false,err end end
      local r,why=call("wh-lock",{name=name}) if not r then return false,why end
      state.lock,state.site,confirmedLock=name,r.site,name save()
    end
    if state.site.kind~=kind then release() return false,"wrong interaction site kind" end
    local ok,why=nav.go(state.site.pose,"walk") if not ok then return false,why end
    return nav.face(state.site.pose.h)
  end
  local function inventory()
    local side=state.site.side
    local inv=cfg.inventory and cfg.inventory(side) or peripheral.wrap(side)
    if not inv or type(inv.list)~="function" then return nil,"interaction inventory unavailable" end
    return inv
  end
  local function reconcile()
    local j=state.pending
    if not j then return end
    local p=nav.pose()
    assert(p.dim==j.pose.dim and p.x==j.pose.x and p.y==j.pose.y and p.z==j.pose.z and p.h==j.pose.h,"transfer pose changed; reconcile inventory")
    local item=turtle.getItemDetail(j.slot)
    local count=item and item.count or 0
    local delta=j.kind=="pickup" and count-j.before or j.before-count
    assert(delta>=0 and delta<=j.count,"inventory changed outside the transfer")
    if j.kind=="pickup" then
      if delta>0 then
        if item.name==state.job.lines[state.line].item then
          state.job.lines[state.line].picked=state.job.lines[state.line].picked+delta
          state.cargo[j.slot]={name=item.name,count=delta}
          state.phase="restore" state.ack=state.line
        else state.escrow[j.slot]={name=item.name,count=delta} end
      else state.phase="restore" state.reason="source empty" state.endLine=true end
    else
      assert(not item or item.name==j.item,"transfer item changed")
      local slots=j.kind=="restore" and state.escrow or state.cargo
      if slots[j.slot] then
        slots[j.slot].count=slots[j.slot].count-delta
        if slots[j.slot].count==0 then slots[j.slot]=nil end
      end
      if j.kind=="deliver" then
        state.job.lines[state.line].delivered=state.job.lines[state.line].delivered+delta state.ack=state.line
      end
    end
    state.pending=nil save("transfer-saved")
  end
  local function transfer(kind,slot,count)
    local inv,why=inventory() if not inv then return false,why end
    local item=turtle.getItemDetail(slot)
    if kind=="pickup" then assert(not item,"pickup needs an empty slot")
    else
      local expected=(kind=="restore" and state.escrow or state.cargo)[slot]
      assert(item and item.name==expected.name and item.count==expected.count,"cargo changed; reconcile inventory")
    end
    turtle.select(slot)
    state.pending={kind=kind,slot=slot,count=count,before=item and item.count or 0,item=item and item.name,pose=nav.pose()}
    save(kind.."-prepared")
    local side=state.site.side
    local method=kind=="pickup" and "suck" or "drop"
    method=method..(side=="top" and "Up" or side=="bottom" and "Down" or "")
    local before=turtle.getItemCount(slot)
    turtle[method](count)
    if cfg.checkpoint then cfg.checkpoint(kind.."-physical") end
    local after=turtle.getItemCount(slot)
    reconcile()
    if before==after and kind~="pickup" then return false,"interaction inventory full or unavailable" end
    return true
  end
  function api.state() return A.copy(state) end
  function api.charge(name,target,timeout)
    if state.phase=="charge" then return true end
    if state.phase~="idle" and state.phase~="done" then return false,"warehouse job active" end
    assert(type(name)=="string" and type(target)=="number" and target>=0 and target%1==0
      and type(timeout)=="number" and timeout>=1000 and timeout<=3600000,"invalid charging target")
    state={version=1,phase="charge",line=1,cargo={},escrow={},charge={name=name,target=target,timeout=timeout,queuedUntil=clock()+timeout}}
    save("charge-saved") return true
  end
  function api.unload(name,keep)
    if state.phase=="unload" then return true end
    if state.phase~="idle" and state.phase~="done" then return false,"warehouse job active" end
    state={version=1,phase="unload",line=1,cargo={},escrow={},drop=name}
    for slot=1,16 do
      local v=turtle.getItemDetail(slot)
      if v and not (keep or {})[v.name] then state.cargo[slot]={name=v.name,count=v.count} end
    end
    save("unload-saved") return true
  end
  function api.tick()
    if nav.stopped() then return false,"cancelled" end
    reconcile()
    if state.ack then
      local l=state.job.lines[state.ack]
      local r,why=call("wh-progress",{token=state.job.token,line=state.ack,picked=l.picked,delivered=l.delivered})
      if not r then return false,why end
      state.ack=nil save("progress-acked")
    end
    if state.phase=="idle" then
      local r,why=call("wh-claim") if not r then return false,why end
      if not r.job then return false,"no orders" end
      state.job=r.job state.phase="pickup" state.line=1 save("job-saved")
    end
    if state.phase=="done" then return false,state.reason or "done" end
    if state.phase=="charge" then
      local c=state.charge
      if not c.deadline and clock()>=c.queuedUntil then
        assert(release()) state.phase="done" state.reason="charging bay timeout" save() return false,state.reason
      end
      local ok,why=reach(c.name,"charge")
      if not ok then
        if why=="bay occupied" then return false,why end
        local released,err=release() if not released then return false,err end
        state.phase="done" state.reason="charging route unavailable: "..tostring(why) save()
        return false,state.reason
      end
      local fuel=turtle.getFuelLevel()
      if fuel=="unlimited" then
        assert(release()) state.phase="done" state.reason="unlimited fuel" save() return true
      end
      if not c.deadline then c.initial=fuel c.deadline=clock()+c.timeout c.target=math.min(c.target,turtle.getFuelLimit()) save() end
      c.rose=c.rose or fuel>c.initial
      if fuel>=c.target and (c.rose or c.initial>=c.target) then
        assert(release()) state.phase="done" state.reason="charged" save("charged-saved") return true
      end
      if clock()>=c.deadline then
        local ok,err=release() if not ok then return false,err end
        state.phase="done" state.reason=c.rose and "charging target timeout" or "no charging fuel rise" save()
        return false,state.reason
      end
      save() return true
    end
    if state.phase=="unload" then
      local ok,why=reach(state.drop,"drop") if not ok then return false,why end
      local slot=next(state.cargo)
      if slot then return transfer("unload",slot,state.cargo[slot].count) end
      assert(release()) state.phase="done" state.reason="unloaded" save() return true
    end
    local l=state.job.lines[state.line]
    if not l then
      local ok,why=release() if not ok then return false,why end
      local r,err=call("wh-finish",{token=state.job.token}) if not r then return false,err end
      state.phase="done" state.reason=r.status save("job-finished") return true
    end
    if state.phase=="pickup" then
      if l.picked>=l.count then state.line=state.line+1 save() return true end
      local ok,why=reach(l.source,"source") if not ok then return false,why end
      for slot=1,16 do if turtle.getItemCount(slot)==0 then return transfer("pickup",slot,math.min(64,l.count-l.picked)) end end
      state.phase="restore" state.endLine=true state.reason="source exceeds escrow capacity" save() return true
    elseif state.phase=="restore" then
      local ok,why=reach(l.source,"source") if not ok then return false,why end
      local slot=next(state.escrow)
      if slot then return transfer("restore",slot,state.escrow[slot].count) end
      state.phase="deliver" save() return true
    elseif state.phase=="deliver" then
      local slot=next(state.cargo)
      if slot then
        local ok,why=reach(state.job.drop,"drop") if not ok then return false,why end
        return transfer("deliver",slot,state.cargo[slot].count)
      end
      assert(release())
      if state.endLine or l.picked>=l.count then state.line=state.line+1 end
      state.endLine=nil state.phase="pickup" save() return true
    end
    return false,"invalid warehouse phase"
  end
  function api.next()
    if state.phase~="done" then return false,"warehouse job active" end
    state={version=1,phase="idle",line=1,cargo={},escrow={}} save() return true
  end
  return api
end
return M
