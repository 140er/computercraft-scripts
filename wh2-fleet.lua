local M = {}
local MAX_ID, MAX_REV, MAX_TIME, PAGE_BYTES = 2147483647, 2147483647, 9007199254740991, 4096
local fuels = {"minecraft:charcoal", "minecraft:coal", "minecraft:coal_block", "minecraft:dried_kelp_block"}
M.registry = {
  enabled = {type="boolean", default=false},
  navigation = {type="boolean", default=false},
  mining = {type="boolean", default=false},
  warehouse = {type="boolean", default=false},
  sorting = {type="boolean", default=false},
  smelting = {type="boolean", default=false},
  crafting = {type="boolean", default=false},
  forestry = {type="boolean", default=false},
  farming = {type="boolean", default=false},
  building = {type="boolean", default=false},
  lavaCollection = {type="boolean", default=false},
  following = {type="boolean", default=false},
  autoCharge = {type="boolean", default=false},
  autoDropoff = {type="boolean", default=false},
  traffic = {type="boolean", default=false},
  mesh = {type="boolean", default=true},
  returnHome = {type="boolean", default=true},
  fuelLow = {type="integer", min=0, max=99999, default=200},
  fuelTarget = {type="integer", min=1, max=100000, default=2000},
  fuelMargin = {type="integer", min=0, max=100000, default=32},
  minFreeSlots = {type="integer", min=0, max=16, default=2},
  fullnessHigh = {type="number", min=0, exclusiveMin=true, max=1, default=0.875},
  chargeTimeoutMs = {type="integer", min=1, max=86400000, default=60000},
  dropoffId = {type="id", maxLength=64, default=false},
  chargerId = {type="id", maxLength=64, default=false},
  parkingId = {type="id", maxLength=64, default=false},
  keep = {type="itemSet", maxEntries=32, maxLength=128, default={}},
  miningTargets = {type="itemSet", maxEntries=32, maxLength=128, default={}},
  miningMode = {type="enum", values={"thorough", "fast"}, default="thorough"},
  branchLength = {type="integer", min=1, max=64, default=64},
  reach = {type="integer", min=1, max=4096, default=96},
  tripSeconds = {type="integer", min=1, max=86400, default=900},
  sessionSeconds = {type="integer", min=1, max=86400, default=1800},
  minSessionSeconds = {type="integer", min=1, max=86400, default=180},
  thoroughGap = {type="integer", min=2, max=4, default=4},
  fastGap = {type="integer", min=2, max=4, default=2},
  layerStep = {type="integer", min=3, max=3, default=3},
  layers = {type="integer", min=1, max=128, default=4},
  veinLimit = {type="integer", min=1, max=4096, default=64},
  junkEvery = {type="integer", min=1, max=4096, default=10},
  retrySeconds = {type="integer", min=1, max=86400, default=20},
  minTripFuel = {type="integer", min=0, max=100000, default=2000},
  warehouseFuelMargin = {type="integer", min=0, max=100000, default=16},
  roomMaxSize = {type="integer", min=1, max=256, default=48},
  roomMaxHeight = {type="integer", min=1, max=256, default=24},
  roomMaxCells = {type="integer", min=1, max=32768, default=6000},
  roomMaxFurnaces = {type="integer", min=1, max=64, default=16},
  roomIntervalMs = {type="integer", min=1, max=86400000, default=5000},
  roomFuelLow = {type="integer", min=0, max=100000, default=1000},
  wiredIntervalMs = {type="integer", min=1, max=86400000, default=3000},
  smeltQueue = {type="integer", min=1, max=64, default=32},
  charcoal = {type="boolean", default=true},
  keepLogs = {type="integer", min=0, max=2147483647, default=32},
  useStorageFuel = {type="boolean", default=true},
  extraSmelt = {type="itemList", maxEntries=32, maxLength=128, default={}},
  noSmelt = {type="itemList", maxEntries=32, maxLength=128, default={}},
  roomFuels = {type="itemList", maxEntries=32, maxLength=128, default=fuels},
  wiredFuels = {type="itemList", maxEntries=32, maxLength=128,
    default={"minecraft:charcoal", "minecraft:coal", "minecraft:coal_block", "minecraft:dried_kelp_block", "minecraft:lava_bucket"}},
  leave = {type="itemCounts", maxEntries=32, maxLength=128,
    default={["minecraft:bucket"]=9999, ["minecraft:lava_bucket"]=9999, ["minecraft:water_bucket"]=9999}},
  navMaxCells = {type="integer", min=1, max=4096, default=2048},
  navMaxSearch = {type="integer", min=1, max=4096, default=2048},
  navBatch = {type="integer", min=1, max=64, default=32},
  trafficWaits = {type="integer", min=1, max=4096, default=80},
  trafficWaitMs = {type="integer", min=1, max=86400000, default=250},
  routeRetries = {type="integer", min=1, max=4096, default=5},
  trafficRouteRetries = {type="integer", min=1, max=4096, default=80},
  trailLength = {type="integer", min=1, max=4096, default=64},
  rpcTimeoutMs = {type="integer", min=1, max=86400000, default=5000},
  offlineAutonomy = {type="boolean", default=false},
  checkInEveryMs = {type="integer", min=1000, max=3600000, default=60000},
  leaseMs = {type="integer", min=60000, max=3600000, default=900000},
  returnMarginMs = {type="integer", min=1000, max=3600000, default=120000},
  journalMaxBytes = {type="integer", min=4096, max=262144, default=90000},
  journalMaxEvents = {type="integer", min=1, max=4096, default=1024},
  compactInventory = {type="boolean", default=false},
  filteredTrash = {type="boolean", default=false},
  trashItems = {type="itemSet", maxEntries=64, maxLength=128, default={}},
  fuelReturnMargin = {type="integer", min=0, max=100000, default=120},
  unbreakableDetour = {type="boolean", default=false},
  detourMaxCells = {type="integer", min=1, max=4096, default=64},
  avoidFluids = {type="boolean", default=false},
  containFluids = {type="boolean", default=false},
  maxFluidBlocks = {type="integer", min=1, max=64, default=16},
  fallingRetry = {type="boolean", default=false},
  fallingMaxRetries = {type="integer", min=1, max=32, default=8},
  blockedRetry = {type="boolean", default=false},
  blockedMaxRetries = {type="integer", min=1, max=32, default=3},
  rerouteBlocked = {type="boolean", default=false},
  rerouteMaxCells = {type="integer", min=1, max=4096, default=128},
  reanchor = {type="boolean", default=false},
  reanchorMaxAttempts = {type="integer", min=1, max=32, default=3},
  stuckBackoff = {type="boolean", default=false},
  stuckMaxAttempts = {type="integer", min=1, max=32, default=3},
  stuckSkip = {type="boolean", default=false},
  storagePolicy = {type="storagePolicy", scope="global",
    default={v=1,mode="ask",warnAt=0.8,forgetOlderThanMs=false,controlReserve=65536}},
}

local roles={miner=true,store=true,crafter=true,factory=true,hub=true,server=true,panel=true,other=true}

local function integer(v, lo, hi)
  return type(v)=="number" and v%1==0 and v>=lo and v<=hi
end
local function text(v, limit, empty)
  return type(v)=="string" and (empty or #v>0) and #v<=limit
end
local function resource(v, limit)
  return text(v,limit) and v:match("^[a-z0-9_.-]+:[a-z0-9_/.-]+$")~=nil
end
local function computerKey(v)
  return type(v)=="string" and integer(tonumber(v),0,MAX_ID) and tostring(tonumber(v))==v
end
local function copy(v)
  if type(v)~="table" then return v end
  local result = {}
  for k,item in pairs(v) do result[k]=copy(item) end
  return result
end
local function plain(value, limit)
  local seen, nodes = {}, 0
  local function visit(v, depth)
    nodes=nodes+1
    if nodes>limit or depth>10 then return false end
    local kind=type(v)
    if kind=="table" then
      if getmetatable(v) or seen[v] then return false end
      seen[v]=true
      for k,item in pairs(v) do
        if type(k)~="string" and type(k)~="number" or not visit(k,depth+1) or not visit(item,depth+1) then return false end
      end
      return true
    end
    return kind=="string" or kind=="boolean" or kind=="number" and v==v and math.abs(v)~=math.huge
  end
  return visit(value,0)
end
local function keys(value, allowed)
  if type(value)~="table" then return false end
  for key in pairs(value) do if not allowed[key] then return false end end
  return true
end
local function size(value) return #textutils.serialize(value,{compact=true}) end
local function setting(row, value)
  if row.type=="boolean" then return type(value)=="boolean" end
  if row.type=="integer" then return integer(value,row.min,row.max) end
  if row.type=="number" then
    return type(value)=="number" and value>=row.min and value<=row.max and (not row.exclusiveMin or value>row.min)
  end
  if row.type=="id" then return value==false or text(value,row.maxLength) end
  if row.type=="enum" then
    for _,choice in ipairs(row.values) do if value==choice then return true end end
    return false
  end
  if row.type=="storagePolicy" then
    return keys(value,{v=true,mode=true,warnAt=true,forgetOlderThanMs=true,controlReserve=true}) and value.v==1
      and (value.mode=="ask" or value.mode=="expand" or value.mode=="forget-old")
      and type(value.warnAt)=="number" and value.warnAt>0 and value.warnAt<=1
      and (value.forgetOlderThanMs==false or integer(value.forgetOlderThanMs,1,MAX_TIME))
      and integer(value.controlReserve,65536,MAX_TIME)
  end
  if type(value)~="table" then return false end
  local count=0
  for key,item in pairs(value) do
    count=count+1
    if count>row.maxEntries then return false end
    if row.type=="itemList" then
      if not integer(key,1,#value) or not resource(item,row.maxLength) then return false end
    elseif not resource(key,row.maxLength) or row.type=="itemSet" and item~=true
      or row.type=="itemCounts" and not integer(item,0,MAX_ID) then return false end
  end
  return row.type~="itemList" or count==#value
end
local function settingMap(value, scope)
  if type(value)~="table" then return false end
  for key,item in pairs(value) do
    local row=M.registry[key]
    if not row or row.scope and row.scope~=scope or not setting(row,item) then return false end
  end
  return true
end
function M.defaults()
  local result={}
  for key,row in pairs(M.registry) do result[key]=copy(row.default) end
  return result
end
function M.effective(settings, computerId, role)
  local result=M.defaults()
  if settings then
    for key,value in pairs(settings.global or {}) do result[key]=copy(value) end
    local roleOverride=(role~=nil or computerId~=nil) and settings.roles and settings.roles[role or "other"]
    for key,value in pairs(roleOverride or {}) do result[key]=copy(value) end
    local override=computerId~=nil and settings.computers and settings.computers[tostring(computerId)]
    for key,value in pairs(override or {}) do result[key]=copy(value) end
  end
  return result
end
local function combinations(value)
  return value.fuelTarget>value.fuelLow and value.branchLength<=value.reach
    and value.tripSeconds<=value.sessionSeconds and value.minSessionSeconds<=value.sessionSeconds
    and value.checkInEveryMs<value.leaseMs-value.returnMarginMs
    and value.detourMaxCells<=value.navMaxCells and value.rerouteMaxCells<=value.navMaxCells
end
-- Enrollment supplies config.enrolledRoles[decimalComputerId] independently of telemetry.
function M.enrolledRole(config, computerId)
  return config and config.enrolledRoles and config.enrolledRoles[tostring(computerId)] or "other"
end
local function enrollments(config)
  if config.enrolledRoles==nil then return true end
  if not plain(config.enrolledRoles,256) or type(config.enrolledRoles)~="table" then return false end
  local count=0
  for id,role in pairs(config.enrolledRoles) do
    count=count+1
    if count>32 or not computerKey(id) or not roles[role] then return false end
  end
  return true
end
local function settingsRow(settings, target, role)
  return {id=tostring(target),revision=settings.revision,effective=M.effective(settings,target,role)}
end
local function readable(settings, target, role)
  local row=settingsRow(settings,target,role)
  row.id=target==nil and role~=nil and "role:"..role or tostring(target or MAX_ID)
  return size({ok=true,wh2=1,revision=settings.revision,records={row},cursor=0})<=PAGE_BYTES
end
function M.validSettings(value, config, diskCapacity)
  if not plain(value,32768) or not keys(value,{v=true,revision=true,global=true,roles=true,computers=true}) then
    return false,"Invalid settings record"
  end
  if value.v~=1 or not integer(value.revision,0,MAX_REV) or not settingMap(value.global,"global")
    or type(value.roles)~="table" or type(value.computers)~="table" then
    return false,"Invalid settings fields"
  end
  if config and not enrollments(config) then return false,"Invalid role enrollment" end
  local global=M.effective(value)
  if not combinations(global) then return false,"Invalid global settings combination" end
  if diskCapacity~=nil and (not integer(diskCapacity,1,MAX_TIME) or global.storagePolicy.controlReserve>diskCapacity) then
    return false,"Storage reserve exceeds measured disk capacity"
  end
  if not readable(value) then return false,"Effective settings exceed the page budget","too_large" end
  for role,override in pairs(value.roles) do
    if not roles[role] or not settingMap(override,"role") then return false,"Invalid role override" end
    if not combinations(M.effective(value,nil,role)) then return false,"Invalid settings combination for role "..role end
    if not readable(value,nil,role) then return false,"Effective settings exceed the page budget","too_large" end
  end
  local count=0
  for id,override in pairs(value.computers) do
    count=count+1
    if count>32 then return false,"Computer override limit reached","capacity" end
    if not computerKey(id) or not settingMap(override,"computer") then return false,"Invalid computer override" end
    if config then
      local role=M.enrolledRole(config,id)
      if not combinations(M.effective(value,id,role)) then return false,"Invalid settings combination for computer "..id end
      if not readable(value,id,role) then return false,"Effective settings exceed the page budget","too_large" end
    else
      local possible,readablePossible=false,false
      for role in pairs(roles) do
        if combinations(M.effective(value,id,role)) then
          possible=true
          if readable(value,id,role) then readablePossible=true break end
        end
      end
      if not possible then return false,"No valid enrolled role for computer "..id end
      if not readablePossible then return false,"Effective settings exceed the page budget","too_large" end
    end
  end
  return true
end

local states={idle=true,mining=true,returning=true,dropping=true,charging=true,sorting=true,crafting=true,blocked=true,stopped=true}
local recordKeys={v=true,id=true,computerId=true,turtleId=true,kind=true,label=true,role=true,boot=true,ownerGeneration=true,
  state=true,detail=true,pose=true,fuel=true,inventory=true,currentJob=true,
  lastSeen=true,appliedSettingsRevision=true,capabilities=true,error=true}
local poseKeys={v=true,frame=true,yAbs=true,dim=true,x=true,y=true,z=true,h=true,conf=true,src=true,anchoredAt=true}
local sources={gps=true,neighbour=true,radio=true,typed=true,reckoned=true,inherited=true}
local function pose(value, validator)
  return keys(value,poseKeys) and value.v==1 and resource(value.dim,80)
    and (value.frame=="abs" or text(value.frame,64) and value.frame:match("^f:.+"))
    and type(value.yAbs)=="boolean" and (value.frame~="abs" or value.yAbs)
    and integer(value.x,-30000000,30000000) and integer(value.y,-2048,2048) and integer(value.z,-30000000,30000000)
    and integer(value.h,0,3) and (value.conf=="certain" or value.conf=="suspect" or value.conf=="lost")
    and sources[value.src]==true and integer(value.anchoredAt,0,MAX_TIME)
    and (not validator or validator(value))
end
-- Legacy occupancy cannot establish a frame, heading, or anchor that navigation never saved.
function M.fromLegacyPose(value, computerId)
  if not plain(value,256) or not keys(value,{dim=true,x=true,y=true,z=true,h=true}) or not resource(value.dim,80)
    or not integer(value.x,-30000000,30000000) or not integer(value.y,-2048,2048)
    or not integer(value.z,-30000000,30000000) or not integer(computerId,0,MAX_ID) then return nil end
  if value.h==nil then return false end
  if not integer(value.h,0,3) then return nil end
  return {v=1,frame="f:"..computerId..":legacy",yAbs=false,dim=value.dim,
    x=value.x,y=value.y,z=value.z,h=value.h,conf="lost",src="inherited",anchoredAt=0}
end
local function occupancyPose(s, computerId, boot, validator)
  if s.poses==nil then return false end
  if type(s.poses)~="table" or getmetatable(s.poses) then return nil end
  local value=s.poses[computerId]
  if value==nil then return false end
  if type(value)~="table" or not plain(value,256) then return nil end
  if value.boot~=boot then return false end
  local result=copy(value)
  result.boot=nil
  if result.v==nil and result.frame==nil then result=M.fromLegacyPose(result,computerId) end
  if result==false then return false end
  if not pose(result,validator) then return nil end
  return result
end
local function fuel(value)
  if not keys(value,{level=true,limit=true}) then return false end
  if value.level=="unlimited" or value.limit=="unlimited" then
    return (value.level=="unlimited" or value.level==false) and (value.limit=="unlimited" or value.limit==false)
  end
  return (value.level==false or integer(value.level,0,MAX_ID)) and (value.limit==false or integer(value.limit,0,MAX_ID))
    and (value.level==false or value.limit==false or value.level<=value.limit)
end
local function inventory(value)
  return keys(value,{slots=true,usedSlots=true,fullness=true}) and (value.slots==false or integer(value.slots,1,16))
    and (value.usedSlots==false or integer(value.usedSlots,0,value.slots or 16))
    and (value.fullness==false or type(value.fullness)=="number" and value.fullness>=0 and value.fullness<=1)
    and (value.slots==false or value.usedSlots==false or value.fullness==false or value.fullness==value.usedSlots/value.slots)
end
local function job(value)
  return value==false or keys(value,{kind=true,id=true,step=true})
    and (value.kind=="mine" or value.kind=="warehouse" or value.kind=="craft") and text(value.id,64)
    and text(value.step,64)
end
local function record(value, validator)
  if not keys(value,recordKeys) or value.v~=1 or not integer(value.computerId,0,MAX_ID) or value.id~="cc:"..value.computerId
    or (value.kind~="turtle" and value.kind~="computer")
    or value.turtleId~=(value.kind=="turtle" and value.computerId or false)
    or not text(value.label,64,true) or not roles[value.role] or not states[value.state]
    or not text(value.boot,80) or not integer(value.ownerGeneration,0,MAX_REV)
    or not text(value.detail,256,true) or not (value.pose==false or pose(value.pose,validator))
    or value.kind=="turtle" and (not fuel(value.fuel) or not inventory(value.inventory))
    or value.kind=="computer" and (value.fuel~=false or value.inventory~=false)
    or not job(value.currentJob) or not integer(value.lastSeen,0,MAX_TIME)
    or not integer(value.appliedSettingsRevision,0,MAX_REV) or type(value.capabilities)~="table"
    or not (value.error==false or text(value.error,256)) then return false end
  local active={mining="mine",sorting="warehouse",crafting="craft"}
  if value.state=="idle" and value.currentJob~=false
    or active[value.state] and (value.currentJob==false or value.currentJob.kind~=active[value.state]) then return false end
  local count=0
  for key,item in pairs(value.capabilities) do
    count=count+1
    if count>16 or not text(key,32) or not key:match("^[a-zA-Z][a-zA-Z0-9_]*$") or type(item)~="boolean" then return false end
  end
  return true
end
function M.valid(value, poseValidator, config, diskCapacity)
  if value==nil then return true end
  if not plain(value,32768) or not keys(value,{v=true,revision=true,records=true,settings=true}) or value.v~=1
    or not integer(value.revision,0,MAX_REV) or type(value.records)~="table"
    or not M.validSettings(value.settings,config,diskCapacity) then return false end
  local count=0
  for id,item in pairs(value.records) do
    count=count+1
    if count>32 or not record(item,poseValidator) or id~=item.id then return false end
  end
  return true
end

local function failure(code, why) return {ok=false,wh2=1,code=code,error=why} end
local function page(rows, query, revision)
  local cursor=query.cursor
  if cursor==nil then cursor=0 end
  if not integer(cursor,0,MAX_ID) or query.revision~=nil and not integer(query.revision,0,MAX_REV)
    or cursor>0 and query.revision==nil then return failure("invalid","Invalid page cursor or revision") end
  if query.revision~=nil and query.revision~=revision then return failure("stale_revision","The requested records changed") end
  if cursor>#rows then return failure("invalid","Page cursor is outside the result") end
  local result={ok=true,wh2=1,revision=revision,records={},cursor=0}
  for index=cursor+1,#rows do
    result.records[#result.records+1]=copy(rows[index])
    result.cursor=index<#rows and index or 0
    if #result.records>64 or size(result)>PAGE_BYTES then
      result.records[#result.records]=nil
      if #result.records==0 then return failure("too_large","Record exceeds the page budget") end
      result.cursor=index-1
      break
    end
  end
  return result
end
local function commit(s, fleet)
  if s.wh2==nil then s.wh2={schema=1} end
  s.wh2.fleet=fleet
end
function M.run(s, senderId, message, context)
  if type(context)~="table" or type(context.config)~="table" or context.config.enabled~=true then
    return failure("disabled","Warehouse v2 is disabled")
  end
  if not integer(context.now,0,MAX_TIME) or not integer(context.epoch,0,MAX_REV) or not enrollments(context.config)
    or context.diskCapacity~=nil and not integer(context.diskCapacity,1,MAX_TIME)
    or not integer(senderId,0,MAX_ID) or type(s)~="table" or type(message)~="table" or not plain(message.body,8192)
    or type(message.body)~="table" or message.body.wh2~=nil and message.body.wh2~=1 then
    return failure("invalid","Invalid fleet request")
  end
  local body=message.body
  if size(body)>8192 then return failure("too_large","Fleet request exceeds the wire budget") end
  if s.wh2~=nil and type(s.wh2)~="table" then return failure("invalid","Invalid warehouse state") end
  local fleet=s.wh2 and s.wh2.fleet
  if fleet==nil then fleet={v=1,revision=0,records={},settings={v=1,revision=0,global={},roles={},computers={}}} end
  if not M.valid(fleet,context.pose,context.config,context.diskCapacity) then return failure("invalid","Invalid saved fleet state") end
  local settings=fleet.settings
  local settingsRevision=settings.revision
  if message.op=="wh2-get" then
    if not keys(body,{wh2=true,topic=true,cursor=true,revision=true,id=true,computerId=true,role=true,field=true})
      or body.id~=nil and not text(body.id,64) then return failure("invalid","Invalid fleet query") end
    local rows={}
    if body.topic=="fleet" then
      if body.computerId~=nil or body.role~=nil or body.field~=nil then return failure("invalid","Fleet queries use record IDs") end
      for id,item in pairs(fleet.records) do if body.id==nil or body.id==id then rows[#rows+1]=item end end
      table.sort(rows,function(a,b) return a.id<b.id end)
      return page(rows,body,fleet.revision)
    elseif body.topic=="settings" then
      if body.role~=nil then
        if not roles[body.role] or body.id~=nil or body.computerId~=nil or body.field~=nil then
          return failure("invalid","Role settings queries require one known role")
        end
        return page({{id="role:"..body.role,revision=settingsRevision,effective=M.effective(settings,nil,body.role)}},body,settingsRevision)
      end
      if body.field~=nil then
        if body.field~="defaults" or body.id~=nil or body.computerId~=nil and not integer(body.computerId,0,MAX_ID) then
          return failure("invalid","Unknown settings field or computer")
        end
        return page({{id="defaults",revision=settingsRevision,effective=M.effective(settings)}},body,settingsRevision)
      end
      local target=body.computerId
      if target==nil and body.id~=nil and body.id~="settings" then
        if not computerKey(body.id) then return failure("invalid","Invalid settings record ID") end
        target=tonumber(body.id)
      end
      if target==nil then target=senderId end
      if not integer(target,0,MAX_ID) or body.id~=nil and body.id~="settings" and body.id~=tostring(target) then
        return failure("invalid","Invalid settings computer")
      end
      if body.id=="settings" then
        rows[1]={v=1,id="settings",revision=settingsRevision,global=copy(settings.global),
          roles=copy(settings.roles),computers=copy(settings.computers),
          effective=M.effective(settings,target,M.enrolledRole(context.config,target))}
      else rows[1]=settingsRow(settings,target,M.enrolledRole(context.config,target)) end
      return page(rows,body,settingsRevision)
    end
    return failure("invalid","Unknown fleet topic")
  elseif message.op=="wh2-report" then
    if not keys(body,{wh2=true,record=true,appliedSettingsRevision=true}) or type(body.record)~="table" then
      return failure("invalid","Invalid fleet report")
    end
    local incoming=body.record
    if incoming.computerId~=senderId or incoming.id~="cc:"..senderId
      or incoming.kind=="turtle" and incoming.turtleId~=senderId then return failure("forbidden","Reports must describe their sender") end
    local accepted=copy(incoming)
    if accepted.lastSeen==nil then accepted.lastSeen=context.now end
    if not record(accepted,context.pose)
      or body.appliedSettingsRevision~=nil and not integer(body.appliedSettingsRevision,0,MAX_REV) then
      return failure("invalid","Invalid fleet record")
    end
    local count=0 for _ in pairs(fleet.records) do count=count+1 end
    if not fleet.records[incoming.id] and count>=32 then return failure("capacity","Fleet record limit reached") end
    if fleet.revision==MAX_REV then return failure("capacity","Fleet revision limit reached") end
    accepted.lastSeen=context.now
    if body.appliedSettingsRevision~=nil then accepted.appliedSettingsRevision=body.appliedSettingsRevision end
    if accepted.kind=="turtle" and (accepted.capabilities.navigation==true or s.poses and s.poses[senderId]~=nil) then
      local position=occupancyPose(s,senderId,accepted.boot,context.pose)
      if position==nil then return failure("invalid","Invalid navigation occupancy pose") end
      accepted.pose=position
    end
    local nextFleet={v=1,revision=fleet.revision+1,records=copy(fleet.records),settings=copy(settings)}
    nextFleet.records[accepted.id]=accepted
    if not M.valid(nextFleet,context.pose,context.config,context.diskCapacity) then return failure("capacity","Fleet state exceeds its validation budget") end
    local result={ok=true,wh2=1,revision=nextFleet.revision,record=copy(accepted),settingsRevision=settingsRevision}
    if size(result)>PAGE_BYTES then return failure("too_large","Fleet report exceeds the reply budget") end
    commit(s,nextFleet)
    return result
  elseif message.op=="wh2-settings" then
    if type(context.config.operators)~="table" or context.config.operators[tostring(senderId)]~=true then
      return failure("forbidden","Only operators can change settings")
    end
    if not keys(body,{wh2=true,scope=true,role=true,computerId=true,baseRevision=true,set=true,unset=true})
      or not integer(body.baseRevision,0,MAX_REV)
      or body.scope~="global" and body.scope~="role" and body.scope~="computer"
      or body.scope=="computer" and (not integer(body.computerId,0,MAX_ID) or body.role~=nil)
      or body.scope=="role" and (not roles[body.role] or body.computerId~=nil)
      or body.scope=="global" and (body.computerId~=nil or body.role~=nil)
      or body.set~=nil and not settingMap(body.set,body.scope) or body.unset~=nil and type(body.unset)~="table" then
      return failure("invalid","Invalid settings patch")
    end
    if body.baseRevision~=settingsRevision then return failure("stale_revision","Settings changed since this edit") end
    if settingsRevision==MAX_REV then return failure("capacity","Settings revision limit reached") end
    local unset,unsetCount=body.unset or {},0
    local seen={}
    for index,key in pairs(unset) do
      unsetCount=unsetCount+1
      local row=M.registry[key]
      if not integer(index,1,#unset) or not row or row.scope and row.scope~=body.scope
        or seen[key] or body.set and body.set[key]~=nil then
        return failure("invalid","Invalid unset list")
      end
      seen[key]=true
    end
    if unsetCount~=#unset then return failure("invalid","Unset list must be dense") end
    if body.set and body.set.storagePolicy and context.diskCapacity==nil then
      return failure("unavailable","Storage policy requires measured disk capacity")
    end
    local candidate={v=1,revision=settingsRevision+1,global=copy(settings.global),
      roles=copy(settings.roles),computers=copy(settings.computers)}
    local target=body.scope=="computer" and body.computerId or nil
    local role=body.scope=="role" and body.role or target~=nil and M.enrolledRole(context.config,target) or nil
    local patch=candidate.global
    if body.scope=="computer" then
      local id=tostring(target)
      candidate.computers[id]=candidate.computers[id] or {}
      patch=candidate.computers[id]
    elseif body.scope=="role" then
      candidate.roles[role]=candidate.roles[role] or {}
      patch=candidate.roles[role]
    end
    for key,value in pairs(body.set or {}) do patch[key]=copy(value) end
    for _,key in ipairs(unset) do patch[key]=nil end
    if next(patch)==nil then
      if body.scope=="computer" then candidate.computers[tostring(target)]=nil
      elseif body.scope=="role" then candidate.roles[role]=nil end
    end
    local valid,why,code=M.validSettings(candidate,context.config,context.diskCapacity)
    if not valid then return failure(code or "invalid",why) end
    local result={ok=true,wh2=1,revision=candidate.revision,scope=body.scope,
      role=body.role,computerId=body.computerId,effective=M.effective(candidate,target,role)}
    if size(result)>PAGE_BYTES then return failure("too_large","Settings exceed the reply budget") end
    local nextFleet={v=1,revision=fleet.revision,records=copy(fleet.records),settings=candidate}
    if not M.valid(nextFleet,context.pose,context.config,context.diskCapacity) then return failure("capacity","Fleet state exceeds its validation budget") end
    commit(s,nextFleet)
    return result,{topic="settings",revision=candidate.revision}
  end
  return failure("invalid","Unknown fleet operation")
end
return M
