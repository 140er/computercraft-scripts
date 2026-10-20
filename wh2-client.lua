local M = {}
local A = dofile("atomic.lua")

local function integer(n) return type(n)=="number" and n>=0 and n%1==0 and n<math.huge end
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
  local function validSettings(v)
    return type(v)=="table" and v.id==tostring(id) and integer(v.revision)
      and type(v.effective)=="table" and copy(v,32768)~=nil
  end
  local opened, store=pcall(A.store,opts.cacheFile or "wh2-settings.cache",validSettings,32768)
  local cached=opened and store.value or nil
  cached=cached or {id=tostring(id),revision=0,effective={}}
  local fresh, wanted, applied=false, 0, 0
  local state, why="server unavailable", "server unavailable; fresh settings required"
  local queue, coalesced, driving, worker={}, {}, false, false
  local wake, nextTick="wh2-client:"..tostring(queue), 0
  local api={routeCost=opts.routeCost}

  local function pause(message, phase)
    fresh, state, why=false, phase or "paused", message
  end
  local function enqueue(slot, key)
    if key and coalesced[key] and not coalesced[key].running then
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
    if fields.computerId==nil and (op=="wh2-get" and fields.topic=="settings"
      or op=="wh2-settings" and fields.scope=="turtle") then fields.computerId=id end
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
  local reportFields={"label","boot","ownerGeneration","state","detail","pose","heading",
    "poseConfirmed","fuel","inventory","currentJob","capabilities","error"}
  local boot=rpc and rpc.boot or tostring(os.epoch("utc"))..":"..id
  local function record(value)
    if value==nil and opts.snapshot then
      local ok, result=pcall(opts.snapshot)
      if not ok then return nil,tostring(result) end
      value=result
    end
    if value==nil then value={} end
    if type(value)~="table" then return nil,"invalid fleet snapshot" end
    local out={id="cc:"..id,computerId=id,turtleId=turtle and id or false,
      kind=turtle and "turtle" or "computer",role=opts.role or "other",
      label=os.getComputerLabel() or "",boot=boot,ownerGeneration=0,state="idle",detail="",
      pose=false,heading=false,poseConfirmed=false,fuel=false,inventory=false,
      currentJob=false,capabilities={},error=false}
    for _,key in ipairs(reportFields) do if value[key]~=nil then out[key]=value[key] end end
    out.appliedSettingsRevision=applied
    return copy(out,4096)
  end
  local function run(slot)
    if slot.kind=="refresh" then return refresh() end
    if slot.kind=="query" then return read(slot.topic,slot.target) end
    if slot.kind=="report" then
      local value, err=record(slot.record)
      if not value then return nil,err end
      local reply, reason, busy=request("wh2-report",{record=value,appliedSettingsRevision=applied})
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
      local body=hint.body or hint
      if type(body)=="table" and body.wh2==1 and body.topic=="settings" then changed(body.revision) end
    end
    -- Only the transport may pass a verified hint to this callback or return it.
    local handled,hint=rpc.dispatch(sender,message,protocol,verified)
    verified(hint)
    return handled
  end
  function api.settings() return assert(copy(cached.effective,32768)),cached.revision end
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
  function api.location(kind, from, selector)
    if selector==false then selector=nil end
    local function pose(p)
      return type(p)=="table" and type(p.dim)=="string" and type(p.x)=="number"
        and type(p.y)=="number" and type(p.z)=="number"
        and p.x%1==0 and p.y%1==0 and p.z%1==0
    end
    if not pose(from) or opts.dimension and from.dim~=opts.dimension then return nil,"blocked: invalid location origin" end
    if selector~=nil and (type(selector)~="string" or #selector>64) then return nil,"blocked: invalid location selector" end
    local result,err=submit({kind="query",topic="locations",target=selector})
    if not result then return nil,err end
    local best,distance
    for _,candidate in ipairs(result.records) do
      local p=type(candidate)=="table" and type(candidate.access)=="table" and candidate.access.pose
      if pose(p) and p.dim==from.dim and candidate.enabled==true and candidate.kind==kind
        and type(candidate.id)=="string" and (selector==nil or candidate.id==selector) then
        local cost=math.abs(p.x-from.x)+math.abs(p.y-from.y)+math.abs(p.z-from.z)
        if api.routeCost then cost=api.routeCost(p,from) end
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
