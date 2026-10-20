local M = {}
local A = dofile("atomic.lua")

local function integer(n) return type(n)=="number" and n>=0 and n%1==0 and n<math.huge end
local function boundedInteger(n, low, high)
  return type(n)=="number" and n%1==0 and n>=low and n<=high
end
local function text(value, limit) return type(value)=="string" and #value>0 and #value<=limit end
local confidence={certain=true,suspect=true,lost=true}
local sources={gps=true,neighbour=true,radio=true,typed=true,reckoned=true,inherited=true}
local states={idle=true,mining=true,returning=true,dropping=true,charging=true,sorting=true,
  crafting=true,blocked=true,stopped=true}
local roles={miner=true,store=true,crafter=true,factory=true,hub=true,server=true,panel=true,other=true}
local jobKinds={mine=true,warehouse=true,craft=true}
local activeJobs={mining="mine",sorting="warehouse",crafting="craft"}
local poseFields={v=true,frame=true,yAbs=true,dim=true,x=true,y=true,z=true,h=true,
  conf=true,src=true,anchoredAt=true}
local fuelFields={level=true,limit=true}
local inventoryFields={slots=true,usedSlots=true,fullness=true}
local jobFields={kind=true,id=true,step=true}
local function fields(value, allowed)
  if type(value)~="table" or getmetatable(value)~=nil then return false end
  for key in pairs(value) do if not allowed[key] then return false end end
  return true
end
local function coordinates(p)
  return type(p)=="table" and getmetatable(p)==nil and text(p.dim,80)
    and p.dim:match("^[%w_]+:[%w_/.-]+$") and boundedInteger(p.x,-30000000,30000000)
    and boundedInteger(p.y,-2048,2048) and boundedInteger(p.z,-30000000,30000000)
end
local function pose(p)
  return fields(p,poseFields) and coordinates(p) and p.v==1 and text(p.frame,96)
    and (p.frame=="abs" or p.frame:match("^f:[%w_.:-]+$"))
    and type(p.yAbs)=="boolean" and (p.frame~="abs" or p.yAbs)
    and boundedInteger(p.h,0,3) and confidence[p.conf]==true and sources[p.src]==true
    and boundedInteger(p.anchoredAt,0,9007199254740991)
end
local function routable(p) return pose(p) and p.conf=="certain" and p.anchoredAt>0 end
local function legacyPose(p)
  return coordinates(p) and p.v==nil and p.frame==nil and p.yAbs==nil
    and p.conf==nil and p.src==nil and p.anchoredAt==nil
end
local function navPose(p)
  if p.frame~="abs" then return nil end
  return {dim=p.dim,x=p.x,y=p.y,z=p.z,h=p.h}
end
local function copy(value, limit)
  local seen, nodes = {}, 0
  local function visit(v, depth)
    nodes=nodes+1
    assert(nodes<=2048 and depth<=8, "record is too large")
    if type(v)=="table" then
      assert(not seen[v] and getmetatable(v)==nil, "invalid record table")
      seen[v]=true
      local out={}
      for k,x in pairs(v) do
        assert(type(k)=="string" or integer(k), "invalid record key")
        out[visit(k,depth+1)]=visit(x,depth+1)
      end
      return out
    end
    assert(type(v)=="boolean" or type(v)=="string" and #v<=4096
      or type(v)=="number" and v==v and math.abs(v)<math.huge, "invalid record value")
    return v
  end
  local ok, result=pcall(function()
    local out=visit(value,0)
    assert(#textutils.serialize(out,{compact=true})<=limit, "record exceeds byte budget")
    return out
  end)
  if ok then return result end
  return nil,tostring(result)
end

function M.new(opts)
  opts=opts or {}
  local rpc, enabled, id=opts.rpc, opts.enabled==true, os.getComputerID()
  local isTurtle=type(turtle)=="table"
  local function validSettings(v)
    return type(v)=="table" and (v.v==1 or v.v==nil) and v.id==tostring(id) and integer(v.revision)
      and type(v.effective)=="table" and copy(v,32768)~=nil
  end
  local opened, store=pcall(A.store,opts.cacheFile or "wh2-settings.cache",validSettings,32768)
  local cached=opened and store.value or nil
  cached=cached or {v=1,id=tostring(id),revision=0,effective={}}
  cached.v=1
  local fresh, wanted, applied=false, 0, 0
  local state, why="server unavailable", "server unavailable; fresh settings required"
  local queue, coalesced, driving, worker={}, {}, false, false
  local wake, nextTick="wh2-client:"..tostring(queue), 0
  local api={routeCost=opts.routeCost}

  local function pause(message, phase)
    fresh, state, why=false, phase or "paused", message
  end
  local function enqueue(slot, key)
    if key and coalesced[key] and not coalesced[key].running and not coalesced[key].body then
      local old=coalesced[key]
      if slot.record then old.record=slot.record end
      return old
    end
    slot.key=key
    queue[#queue+1]=slot
    if key then coalesced[key]=slot end
    os.queueEvent(wake)
    return slot
  end
  local function changed(revision)
    if not integer(revision) or revision<=cached.revision or revision<=wanted then return end
    wanted=revision
    pause("settings refresh pending", "refreshing")
    enqueue({kind="refresh"},"refresh")
  end
  local function request(op, body)
    if not rpc or type(rpc.call)~="function" then
      pause("server unavailable", "server unavailable")
      return nil,why
    end
    if body~=nil and type(body)~="table" then return nil,"invalid request body" end
    local fields, err=copy(body or {},65536)
    if not fields then return nil,err end
    fields.wh2=1
    if fields.computerId==nil and (op=="wh2-get" and fields.topic=="settings" and fields.field==nil and fields.role==nil
      or op=="wh2-settings" and fields.scope=="computer") then fields.computerId=id end
    local ok, reply, reason=pcall(rpc.call,op,{body=fields})
    if not ok then reason,reply=reply,nil end
    local result=type(reply)=="table" and reply or nil
    if result and result.body~=nil then result=type(result.body)=="table" and result.body or nil end
    if reason=="SSOT busy" or result and result.ok==false and result.code=="busy" then
      return nil,"SSOT busy",true
    end
    if result and result.ok==false then
      reason=tostring(reason or result.error or result.code or "request rejected")
      pause(reason)
      return result,reason,false,result.code
    end
    if not result or result.ok~=true then
      reason=tostring(reason or result and (result.error or result.code) or "no reply")
      pause("server unavailable: "..reason, "server unavailable")
      return nil,why,false,result and result.code
    end
    return result
  end
  local function read(topic, target)
    for _=1,2 do
      local records, cursor, revision={}, 0, nil
      while true do
        local result, err, busy, code=request("wh2-get",{topic=topic,id=target,cursor=cursor,revision=revision})
        if not result or not result.ok then
          if code=="stale_revision" then break end
          return nil,err,busy
        end
        if type(result.records)~="table" or not integer(result.cursor)
          or type(result.revision)~="string" and not integer(result.revision)
          or revision~=nil and result.revision~=revision then
          pause("invalid "..topic.." response") return nil,why
        end
        revision=result.revision
        local count=0
        for key,record in pairs(result.records) do
          if not integer(key) or key<1 or type(record)~="table" then
            pause("invalid "..topic.." records") return nil,why
          end
          count=count+1
        end
        if count~=#result.records then pause("invalid "..topic.." records") return nil,why end
        for _,record in ipairs(result.records) do records[#records+1]=record end
        if result.cursor==0 then return {ok=true,records=records,revision=revision} end
        if result.cursor<=cursor or result.cursor~=cursor+#result.records or #records>4096 then
          pause("invalid "..topic.." cursor") return nil,why
        end
        cursor=result.cursor
      end
    end
    return nil,why
  end
  local function refresh()
    pause("settings refresh pending", "refreshing")
    local page, err, busy=read("settings",tostring(id))
    if not page then return nil,err,busy end
    local record=page.records[1]
    if #page.records~=1 or not validSettings(record) or record.revision~=page.revision
      or record.revision<cached.revision or record.revision<wanted then
      pause("invalid or stale settings response") return nil,why
    end
    record=assert(copy(record,32768))
    record.v=1
    if not opened then pause("settings cache unavailable: "..tostring(store)) return nil,why end
    local ok, saved, reason=pcall(store.save,record)
    if not ok or not saved then
      pause("settings cache failed: "..tostring(ok and reason or saved)) return nil,why
    end
    cached=record
    if enabled and opts.apply then
      local appliedOK, failure=pcall(opts.apply,assert(copy(record.effective,32768)),record.revision)
      if not appliedOK then pause("settings apply failed: "..tostring(failure)) return nil,why end
    end
    applied=record.revision
    fresh=record.revision>=wanted
    state=fresh and "ready" or "refreshing"
    why=not fresh and "settings refresh pending" or nil
    return {ok=fresh,revision=record.revision},why
  end
  local reportFields={"label","ownerGeneration","state","detail","pose",
    "fuel","inventory","currentJob","capabilities","error"}
  local boot=rpc and rpc.boot or tostring(os.epoch("utc"))..":"..id
  local relativeFrame="f:"..id..":"..tostring(os.epoch("utc"))
  local function observation(value, heading)
    if value==false then return false end
    if pose(value) then return value end
    if legacyPose(value) then
      heading=value.h~=nil and value.h or heading
      if boundedInteger(heading,0,3) then
        return {v=1,frame=relativeFrame,yAbs=false,dim=value.dim,x=value.x,y=value.y,z=value.z,
          h=heading,conf="suspect",src="inherited",anchoredAt=0}
      end
      return false
    end
    return nil,"invalid fleet pose"
  end
  local function measurements(value, isTurtle)
    if not isTurtle then return value.fuel==false and value.inventory==false end
    local fuel, inventory=value.fuel,value.inventory
    if not fields(fuel,fuelFields) or not fields(inventory,inventoryFields) then return false end
    if fuel.level=="unlimited" or fuel.limit=="unlimited" then
      if fuel.level~="unlimited" or fuel.limit~="unlimited" then return false end
    elseif not (fuel.level==false or boundedInteger(fuel.level,0,2147483647))
      or not (fuel.limit==false or boundedInteger(fuel.limit,0,2147483647))
      or type(fuel.level)=="number" and type(fuel.limit)=="number" and fuel.level>fuel.limit then
      return false
    end
    if not (inventory.slots==false or boundedInteger(inventory.slots,1,16))
      or not (inventory.usedSlots==false or boundedInteger(inventory.usedSlots,0,inventory.slots or 16)) then return false end
    if inventory.slots==false or inventory.usedSlots==false then return inventory.fullness==false end
    return inventory.fullness==inventory.usedSlots/inventory.slots
  end
  local function validRecord(value)
    if not roles[value.role] or not states[value.state] or type(value.label)~="string" or #value.label>64
      or not text(value.boot,128) or not integer(value.ownerGeneration)
      or type(value.detail)~="string" or #value.detail>256
      or not (value.error==false or text(value.error,256)) or not measurements(value,isTurtle)
      or type(value.capabilities)~="table" or getmetatable(value.capabilities)~=nil then return false end
    for key,enabledCapability in pairs(value.capabilities) do
      if not text(key,32) or type(enabledCapability)~="boolean" then return false end
    end
    local job=value.currentJob
    if job~=false and (not fields(job,jobFields) or not jobKinds[job.kind] or not text(job.id,64)
      or not text(job.step,64)) then return false end
    if value.state=="idle" then return job==false end
    return not activeJobs[value.state] or job~=false and job.kind==activeJobs[value.state]
  end
  local function record(value)
    if value==nil and opts.snapshot then
      local ok, result=pcall(opts.snapshot)
      if not ok then return nil,tostring(result) end
      value=result
    end
    if value==nil then value={} end
    if type(value)~="table" or getmetatable(value)~=nil then return nil,"invalid fleet snapshot" end
    local out={v=1,id="cc:"..id,computerId=id,turtleId=isTurtle and id or false,
      kind=isTurtle and "turtle" or "computer",role=opts.role or "other",
      label=os.getComputerLabel() or "",boot=boot,ownerGeneration=0,state="idle",detail="",
      pose=false,fuel=isTurtle and {level=false,limit=false} or false,
      inventory=isTurtle and {slots=16,usedSlots=false,fullness=false} or false,
      currentJob=false,lastSeen=0,capabilities={},error=false}
    for _,key in ipairs(reportFields) do if value[key]~=nil then out[key]=value[key] end end
    if isTurtle then
      if out.fuel==false then out.fuel={level=false,limit=false} end
      if out.inventory==false then out.inventory={slots=16,usedSlots=false,fullness=false} end
    end
    local position,err=observation(out.pose,value.heading)
    if position==nil then return nil,err end
    out.pose=position
    if value.v~=nil and value.v~=1 or not validRecord(out) then return nil,"invalid fleet snapshot" end
    out.appliedSettingsRevision=applied
    return copy(out,4096)
  end
  local function run(slot)
    if slot.kind=="refresh" then return refresh() end
    if slot.kind=="query" then return read(slot.topic,slot.target) end
    if slot.kind=="report" then
      if not slot.body then
        local value,err=record(slot.record)
        if not value then return nil,err end
        slot.body={record=value,appliedSettingsRevision=applied}
      end
      local reply, reason, busy=request("wh2-report",slot.body)
      if reply then changed(reply.settingsRevision) end
      return reply,reason,busy
    end
    return request(slot.op,slot.body)
  end
  local function drive(untilSlot)
    if driving then return nil,"SSOT busy" end
    driving=true
    while #queue>0 do
      local slot=queue[1]
      slot.running=true
      local result, err, busy=run(slot)
      slot.running=false
      if busy then driving=false return nil,err end
      table.remove(queue,1)
      if slot.key and coalesced[slot.key]==slot then coalesced[slot.key]=nil end
      slot.done,slot.result,slot.error=true,result,err
      os.queueEvent(wake)
      if slot==untilSlot then break end
    end
    driving=false
    return true
  end
  local function await(slot)
    while not slot.done do os.pullEvent(wake) end
    return slot.result,slot.error
  end
  local function submit(slot, key)
    slot=enqueue(slot,key)
    if worker then return await(slot) end
    local ok,err=drive(slot)
    if not ok then return nil,err end
    return slot.result,slot.error
  end
  local function schedule()
    if enabled and os.epoch("utc")>=nextTick then
      nextTick=os.epoch("utc")+3000
      enqueue({kind="refresh"},"refresh")
      enqueue({kind="report"},"report")
    end
  end

  function api.call(op, body)
    if type(op)~="string" or #op>16 or body~=nil and type(body)~="table" then return nil,"invalid request" end
    local value,err=copy(body or {},65536)
    if not value then return nil,err end
    return await(enqueue({kind="call",op=op,body=value}))
  end
  function api.worker()
    assert(not worker,"wh2 worker already running")
    worker=true
    while true do
      schedule()
      drive()
      local delay=#queue>0 and 0.05 or enabled and math.max(0.05,(nextTick-os.epoch("utc"))/1000) or 3
      local timer=os.startTimer(delay)
      while true do
        local event,value=os.pullEvent()
        if event==wake or event=="timer" and value==timer then break end
      end
      os.cancelTimer(timer)
    end
  end
  function api.tick()
    schedule()
    local ok,err=drive()
    if not ok then return nil,err end
    if enabled and not fresh then return nil,why end
    return true
  end
  function api.refresh()
    local result,err=submit({kind="refresh"},"refresh")
    if result and result.ok then return true,result.revision end
    return nil,err
  end
  function api.dispatch(sender, message, protocol)
    if not rpc or type(rpc.dispatch)~="function" then return false end
    local function verified(hint)
      if type(hint)~="table" or hint.op~=nil and hint.op~="wh2-changed" then return end
      local body=hint.body
      if body==nil then body=hint end
      if type(body)=="table" and body.wh2==1 and body.topic=="settings" then changed(body.revision) end
    end
    return (rpc.dispatch(sender,message,protocol,verified))
  end
  function api.settings() return assert(copy(cached.effective,32768)),cached.revision end
  function api.fleet() return submit({kind="query",topic="fleet"}) end
  function api.ready() return enabled and fresh end
  function api.status()
    return {enabled=enabled,ready=api.ready(),state=enabled and state or "standalone",
      detail=why,revision=cached.revision,appliedSettingsRevision=applied,
      pendingRevision=wanted,queued=#queue}
  end
  function api.record(value)
    local bounded,err=record(value)
    if not bounded then return nil,err end
    enqueue({kind="report",record=bounded},"report")
    return true
  end
  local function resolveLegacyOrigin(from)
    if not legacyPose(from) or not boundedInteger(from.h,0,3) then return nil end
    local result,err=submit({kind="query",topic="fleet",target="cc:"..id})
    if not result then return nil,err end
    for _,row in ipairs(result.records) do
      local p=row.pose
      if row.v==1 and row.id=="cc:"..id and row.computerId==id and row.boot==boot
        and routable(p) and p.frame=="abs" and p.dim==from.dim
        and p.x==from.x and p.y==from.y and p.z==from.z and p.h==from.h then return p end
    end
    return nil
  end
  function api.location(kind, from, selector)
    if selector==false then selector=nil end
    if not text(kind,32) or selector~=nil and not text(selector,64) then return nil,"blocked: invalid location selector" end
    local origin,reason=copy(from,4096)
    if not coordinates(origin) or opts.dimension and origin.dim~=opts.dimension then return nil,"blocked: invalid location origin" end
    if legacyPose(origin) then origin,reason=resolveLegacyOrigin(origin) end
    if not routable(origin) then return nil,reason or "blocked: certain anchored location origin required" end
    from=origin
    local result,err=submit({kind="query",topic="locations",target=selector})
    if not result then return nil,err end
    local best,distance
    for _,candidate in ipairs(result.records) do
      local p=type(candidate)=="table" and type(candidate.access)=="table" and candidate.access.pose
      if candidate.v==1 and routable(p) and p.dim==from.dim and p.frame==from.frame and p.yAbs==from.yAbs
        and (candidate.access.side=="front" or candidate.access.side=="top" or candidate.access.side=="bottom")
        and candidate.enabled==true and candidate.kind==kind
        and text(candidate.id,64) and (selector==nil or candidate.id==selector) then
        local cost=math.abs(p.x-from.x)+math.abs(p.y-from.y)+math.abs(p.z-from.z)
        if api.routeCost then
          local target,origin=navPose(p),navPose(from)
          cost=false
          if target and origin then
            local ok,result=pcall(api.routeCost,target,origin)
            cost=ok and result or false
          end
        end
        if type(cost)=="number" and cost>=0 and cost<math.huge
          and (not best or cost<distance or cost==distance and candidate.id<best.id) then best,distance=candidate,cost end
      end
    end
    if not best then return nil,"blocked: no enabled "..tostring(kind).." location in "..from.dim end
    return copy(best,8192)
  end
  function api.lookupClass(item)
    local result,err=submit({kind="query",topic="classes",target=item})
    if result then
      for _,row in ipairs(result.records) do if row.item==item then return copy(row,8192),result.revision end end
    end
    return {item=item,route="unknown"},result and result.revision or nil,err
  end
  function api.reportUnknown(item, locationId)
    return submit({kind="call",op="wh2-unknown",body={item=item,sampleLocationId=locationId or false}})
  end
  return api
end
return M
