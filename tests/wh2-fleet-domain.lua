local encode=dofile("tests/mocks.lua").encode
local function forbidden() error("The fleet domain attempted I/O or yielded") end
local env=setmetatable({textutils={serialize=encode},sleep=forbidden,
  fs=setmetatable({},{__index=function() return forbidden end}),
  rednet={send=forbidden,broadcast=forbidden,receive=forbidden},
  os={epoch=forbidden,pullEvent=forbidden,queueEvent=forbidden}},{__index=_G})
local function loadModule() return assert(loadfile("wh2-fleet.lua","t",env))() end
local F=loadModule()
local function clone(value) return assert(load("return "..encode(value),"=saved","t",{}))() end
local function equal(a,b) assert(encode(a)==encode(b),"Values differ") end
local function pose(p)
  return type(p)=="table" and p.dim=="minecraft:overworld" and type(p.x)=="number"
    and type(p.y)=="number" and type(p.z)=="number"
end
local function context()
  return {now=1792500000123,epoch=3,pose=pose,diskCapacity=1000000,
    config={enabled=true,operators={["4"]=true},enrolledRoles={["17"]="miner",["18"]="crafter"}},capabilities={}}
end
local function state()
  return {schema=1,poses={},moves={},warehouse={sites={}},wh2={schema=1,
    layout={opaque="kept"},wizard={opaque="kept"},craft={opaque="kept"}}}
end
local function record(id)
  return {v=1,id="cc:"..id,computerId=id,turtleId=id,kind="turtle",label="Miner east",role="miner",
    boot="1792500000000:"..id,ownerGeneration=4,state="mining",detail="Zone 3",
    pose={v=1,frame="abs",yAbs=true,dim="minecraft:overworld",x=100,y=65,z=200,h=0,
      conf="certain",src="gps",anchoredAt=1792500000000},
    fuel={level=1800,limit=20000},inventory={slots=16,usedSlots=14,fullness=0.875},
    currentJob={kind="mine",id="zone:3",step="extract"},lastSeen=1,appliedSettingsRevision=0,
    capabilities={navigation=true,inventory=true,crafting=false},error=false}
end
local function call(s,id,op,body,ctx)
  return F.run(s,id,{op=op,body=body},ctx or context())
end
local function patch(s,body,id,ctx)
  if body.scope==nil then body.scope="global" end
  if body.baseRevision==nil then body.baseRevision=s.wh2 and s.wh2.fleet and s.wh2.fleet.settings.revision or 0 end
  return call(s,id or 4,"wh2-settings",body,ctx)
end
local function report(s,id,value,ctx)
  return call(s,id,"wh2-report",{record=value or record(id)},ctx)
end
local function rejected(s,code,run)
  local before=encode(s)
  local result,hint=run()
  assert(result and result.ok==false and result.code==code and type(result.error)=="string",encode(result))
  assert(hint==nil,"Rejected mutations must not emit hints")
  assert(encode(s)==before,"Rejected requests changed state")
  return result
end
local passed=0
local function test(name,run)
  local ok,why=pcall(run)
  assert(ok,name..". "..tostring(why))
  passed=passed+1
  print("PASS fleet domain "..name)
end

test("registry contains every approved setting",function()
  local approved=[[enabled navigation mining warehouse sorting smelting crafting forestry farming building lavaCollection following autoCharge autoDropoff traffic mesh returnHome
    fuelLow fuelTarget fuelMargin minFreeSlots fullnessHigh chargeTimeoutMs dropoffId chargerId parkingId keep miningTargets
    miningMode branchLength reach tripSeconds sessionSeconds minSessionSeconds thoroughGap fastGap layerStep layers veinLimit
    junkEvery retrySeconds minTripFuel warehouseFuelMargin roomMaxSize roomMaxHeight roomMaxCells roomMaxFurnaces roomIntervalMs
    roomFuelLow wiredIntervalMs smeltQueue charcoal keepLogs useStorageFuel extraSmelt noSmelt roomFuels wiredFuels leave
    navMaxCells navMaxSearch navBatch trafficWaits trafficWaitMs routeRetries trafficRouteRetries trailLength rpcTimeoutMs
    offlineAutonomy checkInEveryMs leaseMs returnMarginMs journalMaxBytes journalMaxEvents
    compactInventory filteredTrash trashItems fuelReturnMargin unbreakableDetour detourMaxCells
    avoidFluids containFluids maxFluidBlocks fallingRetry fallingMaxRetries blockedRetry blockedMaxRetries
    rerouteBlocked rerouteMaxCells reanchor reanchorMaxAttempts stuckBackoff stuckMaxAttempts stuckSkip storagePolicy]]
  local names,count={},0
  for name in approved:gmatch("%S+") do names[name]=true end
  for key,row in pairs(F.registry) do
    assert(names[key],"Unapproved setting "..key)
    names[key]=nil count=count+1
    assert(type(row.type)=="string" and row.default~=nil)
    if row.type=="integer" or row.type=="number" then assert(row.min~=nil and row.max~=nil) end
    if row.type:match("^item") then assert(row.maxEntries and row.maxLength) end
  end
  assert(next(names)==nil and count==95)
  local d=F.defaults()
  assert(d.enabled==true and d.navigation==true and d.mining==true and d.warehouse==true)
  assert(d.sorting==true and d.smelting==true and d.crafting==true and d.forestry==true)
  assert(d.farming==true and d.building==true and d.lavaCollection==true and d.following==true)
  assert(d.autoCharge==true and d.autoDropoff==true and d.traffic==true and d.offlineAutonomy==true)
  assert(d.compactInventory==false and d.filteredTrash==false and d.stuckSkip==false)
  assert(d.mesh==true and d.returnHome==true)
  assert(d.fuelLow==200 and d.fuelTarget==2000 and d.fullnessHigh==0.875)
  assert(d.branchLength==64 and d.reach==96 and d.navMaxCells==2048 and d.navBatch==32)
  assert(d.roomIntervalMs==5000 and d.wiredIntervalMs==3000)
  assert(d.roomFuels[4]=="minecraft:dried_kelp_block" and #d.roomFuels==4)
  assert(d.wiredFuels[5]=="minecraft:lava_bucket" and d.leave["minecraft:bucket"]==9999)
  assert(F.validSettings({v=1,revision=0,global=d,roles={},computers={}}))
end)

test("defaults and effective values have no shared mutable tables",function()
  local d=F.defaults()
  d.keep["minecraft:coal"]=true d.roomFuels[1]="minecraft:stone" d.leave["minecraft:bucket"]=0
  local fresh=F.defaults()
  assert(next(fresh.keep)==nil and fresh.roomFuels[1]=="minecraft:charcoal" and fresh.leave["minecraft:bucket"]==9999)
  local settings={v=1,revision=2,global={keep={["minecraft:coal"]=true}},roles={},computers={["17"]={roomFuels={"minecraft:coal"}}}}
  local effective=F.effective(settings,17)
  effective.keep["minecraft:iron_ingot"]=true effective.roomFuels[1]="minecraft:stone"
  assert(settings.global.keep["minecraft:iron_ingot"]==nil)
  assert(settings.computers["17"].roomFuels[1]=="minecraft:coal")
end)

test("computers and uncoordinated turtles retain framed observations without moving occupancy",function()
  local s=state()
  local incoming=record(17)
  incoming.kind,incoming.turtleId,incoming.fuel,incoming.inventory="computer",false,false,false
  incoming.state,incoming.currentJob="idle",false
  incoming.capabilities.navigation=false
  assert(report(s,17,incoming).ok)
  equal(s.wh2.fleet.records["cc:17"].pose,incoming.pose)
  assert(next(s.poses)==nil)
  incoming=record(17)
  incoming.capabilities.navigation=false
  assert(report(s,17,incoming).ok)
  equal(s.wh2.fleet.records["cc:17"].pose,incoming.pose)
  assert(next(s.poses)==nil)
  s.poses[17]=clone(incoming.pose)
  s.poses[17].boot=incoming.boot
  local confirmed=clone(incoming.pose)
  incoming.pose.x=incoming.pose.x+10
  assert(report(s,17,incoming).ok)
  equal(s.wh2.fleet.records["cc:17"].pose,confirmed)
  assert(s.poses[17].x==confirmed.x)
end)

test("settings inherit per key and preserve explicit false",function()
  local s=state()
  local result,hint=patch(s,{set={autoCharge=true,fuelTarget=3000,dropoffId="mine-drop"}})
  assert(result.ok and result.wh2==1 and result.revision==1 and result.effective.autoCharge==true)
  equal(hint,{topic="settings",revision=1})
  result,hint=patch(s,{scope="computer",computerId=17,set={autoCharge=false,fuelTarget=4000,dropoffId=false}})
  assert(result.ok and result.effective.autoCharge==false and result.effective.dropoffId==false)
  equal(hint,{topic="settings",revision=2})
  assert(patch(s,{set={fuelTarget=5000}}).ok)
  assert(F.effective(s.wh2.fleet.settings,17).fuelTarget==4000)
  assert(F.effective(s.wh2.fleet.settings,18).fuelTarget==5000)
  assert(F.effective(s.wh2.fleet.settings,17).autoCharge==false)
  result=patch(s,{scope="computer",computerId=17,unset={"fuelTarget","autoCharge","dropoffId"}})
  assert(result.ok and result.effective.fuelTarget==5000 and result.effective.autoCharge==true)
  assert(result.effective.dropoffId=="mine-drop" and s.wh2.fleet.settings.computers["17"]==nil)
  result=patch(s,{unset={"fuelTarget","autoCharge","dropoffId"}})
  assert(result.ok and result.effective.fuelTarget==2000 and result.effective.autoCharge==true)
  assert(result.effective.dropoffId==false and result.revision==5)
end)

test("map and array settings replace whole values",function()
  local s=state()
  assert(patch(s,{set={keep={["minecraft:coal"]=true,["minecraft:iron_ingot"]=true},roomFuels={"minecraft:coal","minecraft:charcoal"}}}).ok)
  assert(patch(s,{scope="computer",computerId=17,set={keep={},roomFuels={"minecraft:lava_bucket"}}}).ok)
  local effective=F.effective(s.wh2.fleet.settings,17)
  assert(next(effective.keep)==nil and #effective.roomFuels==1 and effective.roomFuels[1]=="minecraft:lava_bucket")
  assert(patch(s,{scope="computer",computerId=17,unset={"keep","roomFuels"}}).ok)
  effective=F.effective(s.wh2.fleet.settings,17)
  assert(effective.keep["minecraft:coal"] and #effective.roomFuels==2)
  assert(patch(s,{set={leave={["minecraft:bucket"]=0}}}).ok)
  effective=F.effective(s.wh2.fleet.settings,17)
  assert(effective.leave["minecraft:bucket"]==0 and effective.leave["minecraft:water_bucket"]==nil)
end)

test("settings patches reject unknown and malformed values atomically",function()
  local s=state()
  for _,key in ipairs({"notASetting","offlineLease","journalBudget","storagePolicyWrong"}) do
    rejected(s,"invalid",function() return patch(s,{set={enabled=true,[key]=true}}) end)
  end
  rejected(s,"invalid",function() return patch(s,{set={fuelTarget=200}}) end)
  rejected(s,"invalid",function() return patch(s,{set={minFreeSlots=17}}) end)
  rejected(s,"invalid",function() return patch(s,{set={fullnessHigh=0}}) end)
  rejected(s,"invalid",function() return patch(s,{set={fuelLow=-1}}) end)
  rejected(s,"invalid",function() return patch(s,{set={miningMode="turbo"}}) end)
  rejected(s,"invalid",function() return patch(s,{set={keep={["minecraft:coal"]=false}}}) end)
  rejected(s,"invalid",function() return patch(s,{set={keep={coal=true}}}) end)
  rejected(s,"invalid",function() return patch(s,{set={roomFuels={[1]="minecraft:coal",[3]="minecraft:charcoal"}}}) end)
  rejected(s,"invalid",function() return patch(s,{set={leave={["minecraft:coal"]=0.5}}}) end)
  rejected(s,"invalid",function() return patch(s,{set={enabled=true},unset={"enabled"}}) end)
  rejected(s,"invalid",function() return patch(s,{unset={"enabled","enabled"}}) end)
  rejected(s,"invalid",function() return patch(s,{unset={"notASetting"}}) end)
  rejected(s,"invalid",function() return patch(s,{set=false}) end)
  rejected(s,"invalid",function() return patch(s,{unset=false}) end)
  rejected(s,"invalid",function() return patch(s,{scope="computer",set={}}) end)
end)

test("global edits validate every computer override before committing",function()
  local s=state()
  assert(patch(s,{scope="computer",computerId=17,set={fuelTarget=1000}}).ok)
  rejected(s,"invalid",function() return patch(s,{set={fuelLow=1200,enabled=true}}) end)
  assert(s.wh2.fleet.settings.revision==1 and F.effective(s.wh2.fleet.settings,18).fuelLow==200)
  assert(patch(s,{scope="computer",computerId=18,set={reach=80}}).ok)
  rejected(s,"invalid",function() return patch(s,{set={branchLength=64,reach=32}}) end)
  assert(patch(s,{scope="computer",computerId=18,set={sessionSeconds=1000}}).ok)
  rejected(s,"invalid",function() return patch(s,{set={tripSeconds=1100}}) end)
  rejected(s,"invalid",function() return patch(s,{set={minSessionSeconds=1100}}) end)
  rejected(s,"invalid",function() return patch(s,{scope="computer",computerId=17,set={fuelLow=1000}}) end)
end)

test("operators use exact string keyed authorization",function()
  local s=state()
  rejected(s,"forbidden",function() return patch(s,{set={enabled=true}},17) end)
  local ctx=context() ctx.config.operators={[4]=true}
  rejected(s,"forbidden",function() return patch(s,{set={enabled=true}},4,ctx) end)
  ctx.config.operators={["4"]=1}
  rejected(s,"forbidden",function() return patch(s,{set={enabled=true}},4,ctx) end)
  ctx.config.operators=nil
  rejected(s,"forbidden",function() return patch(s,{set={enabled=true}},4,ctx) end)
  assert(patch(s,{set={enabled=true}}).ok)
  local result=call(s,17,"wh2-get",{topic="settings"})
  assert(result.ok and result.records[1].effective.enabled==true)
end)

test("stale settings edits do not change state or emit hints",function()
  local s=state()
  assert(patch(s,{baseRevision=0,set={navigation=true}}).ok)
  rejected(s,"stale_revision",function() return patch(s,{baseRevision=0,set={navigation=false}}) end)
  assert(s.wh2.fleet.settings.revision==1 and s.wh2.fleet.settings.global.navigation==true)
end)

test("reports bind identity and copy framed occupancy and server time",function()
  local s=state()
  local incoming=record(17)
  local confirmed={v=1,frame="abs",yAbs=true,dim="minecraft:overworld",x=10,y=65,z=20,h=3,
    conf="suspect",src="reckoned",anchoredAt=1792500000000,boot=incoming.boot}
  s.poses[17]=confirmed
  local before=encode(incoming)
  local occupancy=encode(s.poses)
  local result,hint=call(s,17,"wh2-report",{record=incoming,appliedSettingsRevision=3})
  assert(result.ok and result.wh2==1 and result.revision==1 and result.settingsRevision==0 and hint==nil)
  assert(result.record.v==1 and result.record.id=="cc:17" and result.record.turtleId==17)
  assert(result.record.lastSeen==1792500000123 and result.record.appliedSettingsRevision==3)
  local expected=clone(confirmed) expected.boot=nil
  equal(result.record.pose,expected)
  assert(result.record.heading==nil and result.record.poseConfirmed==nil)
  assert(encode(s.poses)==occupancy and encode(incoming)==before)
  assert(s.wh2.fleet.settings.revision==0)
  result.record.pose.x=999 result.record.inventory.usedSlots=0
  assert(s.wh2.fleet.records["cc:17"].pose.x==10 and s.wh2.fleet.records["cc:17"].inventory.usedSlots==14)
  assert(F.valid(s.wh2.fleet,pose))
  incoming=record(17) incoming.lastSeen=nil
  assert(report(s,17,incoming).record.lastSeen==1792500000123 and incoming.lastSeen==nil)
  rejected(s,"forbidden",function() return report(s,18,record(17)) end)
  incoming=record(17) incoming.turtleId=18
  rejected(s,"forbidden",function() return report(s,17,incoming) end)
end)

test("missing stale or string keyed occupancy never trusts the reported pose",function()
  local s=state()
  local incoming=record(17)
  s.poses[17]={dim="minecraft:overworld",x=1,y=2,z=3,boot="older-boot"}
  local result=report(s,17,incoming)
  assert(result.ok and result.record.pose==false)
  s.poses[17]=nil
  s.poses["17"]={dim="minecraft:overworld",x=1,y=2,z=3,boot=incoming.boot}
  result=report(s,17,incoming)
  assert(result.ok and result.record.pose==false)
  incoming.pose=false
  result=report(s,17,incoming)
  assert(result.ok and result.record.pose==false)
end)

test("computers report false turtle fields and unlimited fuel remains a string",function()
  local s=state()
  local computer=record(4)
  computer.kind,computer.role,computer.turtleId,computer.fuel,computer.inventory="computer","panel",false,false,false
  computer.state,computer.currentJob,computer.pose="idle",false,false
  assert(report(s,4,computer).ok)
  computer.fuel={level=1,limit=2}
  rejected(s,"invalid",function() return report(s,4,computer) end)
  local unlimited=record(17) unlimited.fuel={level="unlimited",limit="unlimited"}
  assert(report(s,17,unlimited).ok)
  unlimited.fuel.limit=20000
  rejected(s,"invalid",function() return report(s,17,unlimited) end)
end)

test("record validation rejects invalid fields and inconsistent observations",function()
  local changes={
    function(r) r.v=nil end,
    function(r) r.v=2 end,
    function(r) r.extra=true end,
    function(r) r.role="administrator" end,
    function(r) r.state="offline" end,
    function(r) r.label=string.rep("x",65) end,
    function(r) r.detail=string.rep("x",257) end,
    function(r) r.boot="" end,
    function(r) r.ownerGeneration=-1 end,
    function(r) r.heading=4 end,
    function(r) r.pose.x=0.5 end,
    function(r) r.pose.dim="minecraft:the_nether" end,
    function(r) r.pose.extra=true end,
    function(r) r.pose=false r.poseConfirmed=true end,
    function(r) r.poseConfirmed=1 end,
    function(r) r.fuel.level=20001 end,
    function(r) r.fuel.limit=math.huge end,
    function(r) r.fuel.extra=true end,
    function(r) r.inventory.slots=17 end,
    function(r) r.inventory.usedSlots=17 end,
    function(r) r.inventory.fullness=0.5 end,
    function(r) r.currentJob.kind="autonomy" end,
    function(r) r.currentJob.id=string.rep("j",65) end,
    function(r) r.currentJob.token="not-a-fleet-field" end,
    function(r) r.lastSeen=-1 end,
    function(r) r.appliedSettingsRevision=0.5 end,
    function(r) r.capabilities.navigation=1 end,
    function(r) r.error={} end,
    function(r) r.error=string.rep("e",257) end,
    function(r) r.label=nil end,
    function(r) r.capabilities={} for i=1,17 do r.capabilities["c"..i]=true end end,
  }
  local s=state()
  for _,change in ipairs(changes) do
    local incoming=record(17) change(incoming)
    rejected(s,"invalid",function() return report(s,17,incoming) end)
  end
  local incoming=record(17) incoming.label=string.rep("x",64) incoming.error=string.rep("e",256)
  assert(report(s,17,incoming).ok)
  local ctx=context() ctx.now=-1
  rejected(s,"invalid",function() return report(s,17,record(17),ctx) end)
end)

test("wire graphs reject cycles aliases metatables and nonfinite values",function()
  local s=state()
  local incoming=record(17) incoming.capabilities.loop=incoming
  rejected(s,"invalid",function() return report(s,17,incoming) end)
  incoming=record(17) setmetatable(incoming,{})
  rejected(s,"invalid",function() return report(s,17,incoming) end)
  incoming=record(17) incoming.lastSeen=0/0
  rejected(s,"invalid",function() return report(s,17,incoming) end)
  local shared={}
  rejected(s,"invalid",function() return patch(s,{set={keep=shared,miningTargets=shared}}) end)
  rejected(s,"invalid",function() return patch(s,{set={enabled=function() end}}) end)
end)

test("fleet pages sort stable IDs and stay within the encoded byte limit",function()
  local s=state()
  for id=1,32 do
    local incoming=record(id) incoming.detail=string.rep("d",256) incoming.error=string.rep("e",256)
    assert(report(s,id,incoming).ok)
  end
  local cursor,revision,seen,ids,pages=0,nil,{}, {},0
  repeat
    local result=call(s,4,"wh2-get",{topic="fleet",cursor=cursor,revision=revision})
    assert(result.ok and result.wh2==1 and #encode(result)<=4096)
    pages=pages+1
    if revision then assert(revision==result.revision) else revision=result.revision end
    for _,item in ipairs(result.records) do
      assert(not seen[item.id],"Repeated page record")
      seen[item.id]=true ids[#ids+1]=item.id
      item.label="Changed response"
    end
    cursor=result.cursor
  until cursor==0
  assert(#ids==32 and pages>1 and ids[1]=="cc:1" and ids[2]=="cc:10")
  for index=2,#ids do assert(ids[index-1]<ids[index]) end
  assert(s.wh2.fleet.records["cc:1"].label=="Miner east")
  local first=call(s,4,"wh2-get",{topic="fleet",cursor=0})
  assert(first.cursor>0)
  rejected(s,"invalid",function() return call(s,4,"wh2-get",{topic="fleet",cursor=first.cursor}) end)
  assert(report(s,1).ok)
  rejected(s,"stale_revision",function()
    return call(s,4,"wh2-get",{topic="fleet",cursor=first.cursor,revision=first.revision})
  end)
  rejected(s,"invalid",function() return call(s,4,"wh2-get",{topic="fleet",cursor=33}) end)
  rejected(s,"invalid",function() return call(s,4,"wh2-get",{topic="fleet",cursor=false}) end)
  local filtered=call(s,4,"wh2-get",{topic="fleet",id="cc:17",cursor=0})
  assert(filtered.ok and #filtered.records==1 and filtered.records[1].id=="cc:17" and filtered.cursor==0)
  assert(#call(s,4,"wh2-get",{topic="fleet",id="missing"}).records==0)
end)

test("settings fetches target the sender and omit registry metadata",function()
  local s=state()
  assert(patch(s,{set={autoCharge=true}}).ok)
  assert(patch(s,{scope="computer",computerId=17,set={autoCharge=false}}).ok)
  local result=call(s,17,"wh2-get",{topic="settings",cursor=0})
  assert(result.ok and result.revision==2 and result.cursor==0 and #result.records==1 and #encode(result)<=4096)
  assert(result.records[1].id=="17" and result.records[1].revision==2 and result.records[1].effective.autoCharge==false)
  assert(result.records[1].registry==nil and result.records[1].computers==nil)
  result=call(s,17,"wh2-get",{topic="settings",computerId=18})
  assert(result.ok and result.records[1].id=="18" and result.records[1].effective.autoCharge==true)
  result=call(s,4,"wh2-get",{topic="settings",id="17"})
  assert(result.ok and result.records[1].effective.autoCharge==false)
  result=call(s,4,"wh2-get",{topic="settings",id="settings",computerId=17})
  assert(result.ok and result.records[1].id=="settings" and result.records[1].revision==2)
  assert(result.records[1].global.autoCharge==true and result.records[1].computers["17"].autoCharge==false)
  assert(result.records[1].effective.autoCharge==false and result.records[1].registry==nil)
  result.records[1].computers["17"].autoCharge=true
  assert(s.wh2.fleet.settings.computers["17"].autoCharge==false)
  assert(report(s,17).ok)
  assert(call(s,17,"wh2-get",{topic="settings",revision=2}).ok)
  assert(patch(s,{set={fuelTarget=3000}}).ok)
  rejected(s,"stale_revision",function() return call(s,17,"wh2-get",{topic="settings",revision=2}) end)
  rejected(s,"invalid",function() return call(s,17,"wh2-get",{topic="settings",computerId="17"}) end)
  rejected(s,"invalid",function() return call(s,17,"wh2-get",{topic="settings",id="017"}) end)
end)

test("disabled requests and reads preserve absent subtrees",function()
  local s={schema=1,poses={}}
  local ctx=context() ctx.config.enabled=false
  for _,op in ipairs({"wh2-get","wh2-report","wh2-settings"}) do
    rejected(s,"disabled",function() return call(s,4,op,{},ctx) end)
  end
  local result=call(s,4,"wh2-get",{topic="fleet"})
  assert(result.ok and result.revision==0 and #result.records==0 and s.wh2==nil)
  result=call(s,4,"wh2-get",{topic="settings"})
  assert(result.ok and result.records[1].effective.enabled==true and s.wh2==nil)
  assert(F.valid(nil,pose))
  s=state()
  local layout,wizard,craft=s.wh2.layout,s.wh2.wizard,s.wh2.craft
  assert(patch(s,{set={navigation=true}}).ok and report(s,17).ok)
  assert(s.wh2.layout==layout and s.wh2.wizard==wizard and s.wh2.craft==craft)
  assert(next(s.moves)==nil and next(s.warehouse.sites)==nil)
  s.wh2.fleet=false
  rejected(s,"invalid",function() return call(s,4,"wh2-get",{topic="fleet"}) end)
end)

test("saved state validates and reads after a module restart",function()
  assert(F.valid({v=1,revision=0,records={},settings={v=1,revision=0,global={},roles={},computers={}}},pose))
  local s=state()
  assert(patch(s,{set={autoCharge=true,keep={["minecraft:coal"]=true}}}).ok)
  assert(patch(s,{scope="computer",computerId=17,set={autoCharge=false}}).ok)
  assert(report(s,17).ok)
  local saved=clone(s)
  local restarted=loadModule()
  assert(restarted.valid(saved.wh2.fleet,pose))
  local before=encode(saved)
  local result=restarted.run(saved,17,{op="wh2-get",body={topic="settings"}},context())
  assert(result.ok and result.records[1].effective.autoCharge==false and result.records[1].effective.keep["minecraft:coal"]==true)
  assert(result.records[1].revision==2 and encode(saved)==before)
  local bad=clone(saved.wh2.fleet) bad.records[17]=bad.records["cc:17"] bad.records["cc:17"]=nil
  assert(not F.valid(bad,pose))
  bad=clone(saved.wh2.fleet) bad.records["cc:17"].inventory.fullness=0.5
  assert(not F.valid(bad,pose))
  bad=clone(saved.wh2.fleet) bad.extra=true
  assert(not F.valid(bad,pose))
  bad=clone(saved.wh2.fleet) bad.settings.computers[17]={enabled=false}
  assert(not F.valid(bad,pose))
  assert(not F.validSettings({v=1,revision=0,global={},roles={},computers={["017"]={}}}))
  assert(not F.validSettings({v=1,revision=0,global={},roles={},computers={["2147483648"]={}}}))
  assert(not F.validSettings({v=1,revision=0,global={},roles={},computers={["nil"]=true}}))
  assert(not F.validSettings({v=1,revision=0,global={},roles={},computers={["nil"]={fuelLow="invalid"}}}))
end)

test("fleet and settings capacity limits reject additions without changing existing records",function()
  local s=state()
  for id=1,32 do assert(report(s,id).ok) end
  rejected(s,"capacity",function() return report(s,33) end)
  assert(report(s,1).ok)
  for id=1,32 do assert(patch(s,{scope="computer",computerId=id,set={mining=false}}).ok) end
  rejected(s,"capacity",function() return patch(s,{scope="computer",computerId=33,set={mining=false}}) end)
  assert(patch(s,{scope="computer",computerId=1,unset={"mining"}}).ok)
  assert(patch(s,{scope="computer",computerId=33,set={mining=false}}).ok)
  assert(F.valid(s.wh2.fleet,pose))
  s.wh2.fleet.revision=2147483647
  rejected(s,"capacity",function() return report(s,1) end)
  s.wh2.fleet.settings.revision=2147483647
  rejected(s,"capacity",function() return patch(s,{set={enabled=true}}) end)
end)

test("settings enforce navigation geometry and collection bounds",function()
  local s=state()
  for _,values in ipairs({{navMaxCells=4097},{navMaxSearch=4097},{navBatch=65},{branchLength=65},
    {thoroughGap=5},{fastGap=1},{layerStep=2},{chargeTimeoutMs=0},{roomIntervalMs=-1}}) do
    rejected(s,"invalid",function() return patch(s,{set=values}) end)
  end
  local items={} for id=1,33 do items[id]="test:item_"..id end
  rejected(s,"invalid",function() return patch(s,{set={extraSmelt=items}}) end)
  rejected(s,"invalid",function() return patch(s,{set={dropoffId=string.rep("x",65)}}) end)
  rejected(s,"invalid",function() return patch(s,{set={roomFuels={"test:"..string.rep("x",124)}}}) end)
  local result=patch(s,{set={fuelLow=0,fuelTarget=1,fuelMargin=0,minTripFuel=0,minFreeSlots=0,fullnessHigh=1,
    keepLogs=0,navMaxCells=4096,navMaxSearch=4096,navBatch=64}})
  assert(result.ok and result.effective.fuelTarget==1 and result.effective.minFreeSlots==0)
end)

test("oversized effective settings fail atomically and snapshots fail explicitly",function()
  local s=state()
  local large={}
  for id=1,32 do large["test:"..string.rep("x",116)..string.format("%02d",id)]=true end
  rejected(s,"too_large",function() return patch(s,{set={keep=large}}) end)
  assert(s.wh2.fleet==nil)
  for id=1,32 do
    assert(patch(s,{scope="computer",computerId=id,set={keep={["test:"..string.rep("x",50)..id]=true}}}).ok)
  end
  rejected(s,"too_large",function() return call(s,4,"wh2-get",{topic="settings",id="settings"}) end)
  for id=1,32 do
    local result=call(s,4,"wh2-get",{topic="settings",computerId=id})
    assert(result.ok and #encode(result)<=4096 and result.records[1].id==tostring(id))
  end
end)

test("unknown topics operations and malformed bodies cannot mutate state",function()
  local s=state()
  rejected(s,"invalid",function() return call(s,4,"wh2-get",{topic="locations"}) end)
  rejected(s,"invalid",function() return call(s,4,"wh2-layout",{}) end)
  rejected(s,"invalid",function() return call(s,4,"wh2-get",false) end)
  rejected(s,"invalid",function() return call(s,-1,"wh2-get",{topic="fleet"}) end)
  rejected(s,"invalid",function() return call(s,4,"wh2-get",{topic="fleet",wh2=2}) end)
  rejected(s,"invalid",function() return call(s,4,"wh2-get",{topic="fleet",field="settings"}) end)
  rejected(s,"invalid",function() return patch(s,{scope="computer",computerId="17",set={enabled=true}}) end)
end)

test("global settings reads exclude computer overrides",function()
  local s=state()
  assert(patch(s,{set={autoCharge=true}}).ok)
  assert(patch(s,{scope="computer",computerId=17,set={autoCharge=false}}).ok)
  local result=call(s,17,"wh2-get",{topic="settings",field="defaults",computerId=17})
  assert(result.ok and result.records[1].id=="defaults" and result.records[1].effective.autoCharge==true)
  result=call(s,17,"wh2-get",{topic="settings"})
  assert(result.ok and result.records[1].effective.autoCharge==false)
end)
test("fleet capacity rejection preserves readable saved state",function()
  local s=state()
  for id=1,32 do
    local value=record(id)
    value.detail=string.rep("x",256)
    value.label=string.rep("x",64)
    for key=1,16 do value.capabilities["capability"..key..string.rep("x",16)]=true end
    value.capabilities.navigation,value.capabilities.inventory,value.capabilities.crafting=nil,nil,nil
    assert(report(s,id,value).ok)
    assert(F.valid(s.wh2.fleet,pose))
  end
  rejected(s,"capacity",function() return report(s,33) end)
  assert(call(s,4,"wh2-get",{topic="fleet"}).ok)
end)

test("role inheritance uses enrollment instead of a reported role",function()
  local s=state()
  assert(patch(s,{set={fuelTarget=3000,autoCharge=true,dropoffId="mine-drop"}}).ok)
  local saved=patch(s,{scope="role",role="miner",set={fuelTarget=4000,autoCharge=false,dropoffId=false}})
  assert(saved.ok and saved.scope=="role" and saved.role=="miner" and saved.effective.fuelTarget==4000)
  saved=patch(s,{scope="computer",computerId=17,set={fuelTarget=5000}})
  assert(saved.ok and saved.scope=="computer" and saved.computerId==17 and saved.effective.fuelTarget==5000)
  local settings=s.wh2.fleet.settings
  assert(settings.v==1 and settings.computers[17]==nil and settings.computers["17"].fuelTarget==5000)
  local effective=call(s,17,"wh2-get",{topic="settings"}).records[1].effective
  assert(effective.autoCharge==false and effective.dropoffId==false and effective.fuelTarget==5000)
  assert(call(s,18,"wh2-get",{topic="settings"}).records[1].effective.fuelTarget==3000)
  local incoming=record(17) incoming.role="server"
  assert(report(s,17,incoming).ok)
  effective=call(s,17,"wh2-get",{topic="settings"}).records[1].effective
  assert(effective.autoCharge==false and effective.fuelTarget==5000)
  incoming=record(19)
  assert(report(s,19,incoming).ok)
  assert(call(s,19,"wh2-get",{topic="settings"}).records[1].effective.fuelTarget==3000)
  assert(patch(s,{scope="computer",computerId=17,unset={"fuelTarget"}}).effective.fuelTarget==4000)
  assert(settings.computers["17"].fuelTarget==5000)
  assert(patch(s,{scope="role",role="miner",unset={"fuelTarget","autoCharge","dropoffId"}}).ok)
  assert(s.wh2.fleet.settings.roles.miner==nil and s.wh2.fleet.settings.computers["17"]==nil)
  effective=call(s,17,"wh2-get",{topic="settings"}).records[1].effective
  assert(effective.fuelTarget==3000 and effective.autoCharge==true and effective.dropoffId=="mine-drop")
  local ctx=context() ctx.config.enrolledRoles=nil
  assert(F.enrolledRole(ctx.config,17)=="other")
  assert(call(s,17,"wh2-get",{topic="settings"},ctx).ok)
end)

test("global controls exclude every role and computer override",function()
  local s=state()
  assert(patch(s,{scope="role",role="other",set={autoCharge=false}}).ok)
  assert(call(s,19,"wh2-get",{topic="settings"}).records[1].effective.autoCharge==false)
  assert(call(s,19,"wh2-get",{topic="settings",field="defaults"}).records[1].effective.autoCharge==true)
  assert(patch(s,{set={autoCharge=false}}).effective.autoCharge==false)
end)

test("role controls read one bounded role view and reject mixed selectors",function()
  local s=state()
  assert(patch(s,{scope="role",role="miner",set={autoCharge=true}}).ok)
  assert(patch(s,{scope="computer",computerId=17,set={autoCharge=false}}).ok)
  local before=encode(s)
  local result=call(s,4,"wh2-get",{topic="settings",role="miner"})
  assert(result.ok and result.records[1].id=="role:miner" and result.records[1].effective.autoCharge==true)
  assert(result.cursor==0 and result.revision==2 and #encode(result)<=4096 and encode(s)==before)
  for _,body in ipairs({
    {topic="settings",role="unknown"},{topic="settings",role=false},
    {topic="settings",role="miner",computerId=17},{topic="settings",role="miner",id="17"},
    {topic="settings",role="miner",field="defaults"},{topic="fleet",role="miner"},
  }) do rejected(s,"invalid",function() return call(s,4,"wh2-get",body) end) end
end)

test("scope and enrollment boundaries reject ambiguous identities",function()
  local s=state()
  for _,body in ipairs({
    {scope="turtle",computerId=17},{scope="global",computerId=17},{scope="global",role="miner"},
    {scope="role"},{scope="role",role="unknown"},{scope="role",role="miner",computerId=17},
    {scope="computer",computerId=17,role="miner"},{scope="computer",computerId="17"},
    {scope="computer",computerId=false},{scope="computer",computerId=2147483648},
  }) do rejected(s,"invalid",function() return patch(s,body) end) end
  for _,map in ipairs({{[17]="miner"},{["017"]="miner"},{["17"]="administrator"},{["17"]=false}}) do
    local ctx=context() ctx.config.enrolledRoles=map
    rejected(s,"invalid",function() return call(s,17,"wh2-get",{topic="settings"},ctx) end)
  end
  assert(patch(s,{scope="computer",computerId=0,set={autoCharge=true}}).ok)
  assert(s.wh2.fleet.settings.computers["0"].autoCharge==true)
  local result=call(s,0,"wh2-get",{topic="settings"})
  assert(result.records[1].id=="0" and result.records[1].effective.autoCharge==true)
end)

test("role edits validate the actual enrolled computer combinations",function()
  local s=state()
  assert(patch(s,{set={fuelTarget=5000}}).ok)
  assert(patch(s,{scope="role",role="miner",set={fuelTarget=3000}}).ok)
  assert(patch(s,{scope="computer",computerId=17,set={fuelLow=2500}}).ok)
  assert(patch(s,{scope="computer",computerId=18,set={fuelTarget=1500}}).ok)
  assert(patch(s,{scope="role",role="miner",set={fuelLow=1600}}).ok)
  rejected(s,"invalid",function() return patch(s,{scope="role",role="miner",set={fuelTarget=2400}}) end)
  rejected(s,"invalid",function() return patch(s,{set={fuelLow=1600}}) end)
  assert(F.valid(s.wh2.fleet,pose))
  local ctx=context() ctx.config.enrolledRoles["17"]="crafter"
  assert(call(s,17,"wh2-get",{topic="settings"},ctx).ok)
  assert(patch(s,{scope="role",role="crafter",set={fuelTarget=2000}},4,ctx).code=="invalid")
end)

test("storage policy is global and requires measured capacity for an edit",function()
  local s=state()
  local policy={v=1,mode="ask",warnAt=0.75,forgetOlderThanMs=false,controlReserve=70000}
  assert(F.registry.storagePolicy.scope=="global")
  assert(patch(s,{set={storagePolicy=policy}}).ok)
  policy.controlReserve=80000
  assert(s.wh2.fleet.settings.global.storagePolicy.controlReserve==70000)
  for _,body in ipairs({
    {scope="role",role="miner",set={storagePolicy=policy}},
    {scope="computer",computerId=17,set={storagePolicy=policy}},
    {scope="role",role="miner",unset={"storagePolicy"}},
    {scope="computer",computerId=17,unset={"storagePolicy"}},
  }) do rejected(s,"invalid",function() return patch(s,body) end) end
  for _,change in ipairs({
    function(p) p.v=2 end,function(p) p.v=nil end,function(p) p.mode="auto" end,
    function(p) p.warnAt=0 end,function(p) p.warnAt=1.01 end,function(p) p.warnAt=false end,
    function(p) p.forgetOlderThanMs=0 end,function(p) p.forgetOlderThanMs=nil end,
    function(p) p.controlReserve=65535 end,function(p) p.controlReserve=1000001 end,
    function(p) p.extra=true end,
  }) do
    local candidate=clone(policy) change(candidate)
    rejected(s,"invalid",function() return patch(s,{set={storagePolicy=candidate}}) end)
  end
  local ctx=context() ctx.diskCapacity=nil
  rejected(s,"unavailable",function() return patch(s,{set={storagePolicy=policy}},4,ctx) end)
  assert(call(s,17,"wh2-get",{topic="settings"},ctx).ok)
  policy.mode,policy.forgetOlderThanMs="forget-old",86400000
  assert(patch(s,{set={storagePolicy=policy}}).ok)
  policy.mode="expand"
  assert(patch(s,{set={storagePolicy=policy}}).ok)
  local saved=patch(s,{unset={"storagePolicy"}})
  assert(saved.ok and saved.effective.storagePolicy.controlReserve==65536
    and saved.effective.storagePolicy.forgetOlderThanMs==false)
end)

test("B1 and B2 settings enforce ranges and effective combinations",function()
  local s=state()
  local defaults=F.defaults()
  for _,key in ipairs({"offlineAutonomy","unbreakableDetour","avoidFluids","containFluids","fallingRetry",
    "blockedRetry","rerouteBlocked","reanchor","stuckBackoff"}) do
    assert(defaults[key]==true, key)
  end
  for _,key in ipairs({"compactInventory","filteredTrash","stuckSkip"}) do
    assert(defaults[key]==false, key)
  end
  for _,values in ipairs({
    {leaseMs=59999},{leaseMs=3600001},{checkInEveryMs=999},{returnMarginMs=999},
    {leaseMs=60000,checkInEveryMs=10000,returnMarginMs=50000},
    {leaseMs=60000,checkInEveryMs=1000,returnMarginMs=60000},
    {journalMaxBytes=4095},{journalMaxBytes=262145},{journalMaxEvents=0},{journalMaxEvents=4097},
    {fuelReturnMargin=-1},{fuelReturnMargin=100001},{maxFluidBlocks=65},
    {detourMaxCells=2049},{rerouteMaxCells=2049},{navMaxCells=32},
  }) do rejected(s,"invalid",function() return patch(s,{set=values}) end) end
  for _,key in ipairs({"fallingMaxRetries","blockedMaxRetries","reanchorMaxAttempts","stuckMaxAttempts"}) do
    for _,value in ipairs({0,33,1.5}) do
      rejected(s,"invalid",function() return patch(s,{set={[key]=value}}) end)
    end
  end
  local items={}
  for id=1,64 do items["t:"..id]=true end
  assert(patch(s,{set={trashItems=items,journalMaxBytes=262144,journalMaxEvents=4096}}).ok)
  items["test:trash_65"]=true
  rejected(s,"invalid",function() return patch(s,{set={trashItems=items}}) end)
  assert(patch(s,{set={trashItems={},leaseMs=60000,checkInEveryMs=1000,returnMarginMs=1000,
    navMaxCells=32,detourMaxCells=32,rerouteMaxCells=32,fuelReturnMargin=0,maxFluidBlocks=64}}).ok)
  assert(patch(s,{scope="role",role="miner",set={detourMaxCells=30}}).ok)
  rejected(s,"invalid",function() return patch(s,{set={navMaxCells=29,rerouteMaxCells=29,detourMaxCells=29}}) end)
end)

test("unknown turtle measurements stay false and required fields never default to zero",function()
  local s=state()
  local incoming=record(17)
  incoming.fuel={level=false,limit=false}
  incoming.inventory={slots=false,usedSlots=false,fullness=false}
  local result=report(s,17,incoming)
  assert(result.ok)
  equal(result.record.fuel,{level=false,limit=false})
  equal(result.record.inventory,{slots=false,usedSlots=false,fullness=false})
  incoming.fuel={level=false,limit=20000}
  incoming.inventory={slots=16,usedSlots=false,fullness=false}
  assert(report(s,17,incoming).ok)
  incoming.fuel={level=0,limit=false}
  incoming.inventory={slots=16,usedSlots=0,fullness=0}
  result=report(s,17,incoming)
  assert(result.ok and result.record.fuel.level==0 and result.record.inventory.fullness==0)
  for _,change in ipairs({
    function(r) r.fuel=false end,function(r) r.inventory=false end,
    function(r) r.fuel.level=nil end,function(r) r.fuel.limit=nil end,
    function(r) r.inventory.slots=nil end,function(r) r.inventory.usedSlots=nil end,
    function(r) r.inventory.fullness=nil end,function(r) r.ownerGeneration=false end,
    function(r) r.label=false end,function(r) r.detail=false end,function(r) r.currentJob.step=false end,
  }) do
    local bad=record(17) change(bad)
    rejected(s,"invalid",function() return report(s,17,bad) end)
  end
end)

test("working states retain a job of the correct allocator kind",function()
  local s=state()
  for status,kind in pairs({mining="mine",sorting="warehouse",crafting="craft"}) do
    local incoming=record(17) incoming.state=status incoming.currentJob=false
    rejected(s,"invalid",function() return report(s,17,incoming) end)
    incoming.currentJob={kind=kind,id="job:1",step="work"}
    assert(report(s,17,incoming).ok)
    incoming.currentJob.kind=kind=="mine" and "craft" or "mine"
    rejected(s,"invalid",function() return report(s,17,incoming) end)
  end
  local incoming=record(17) incoming.state="idle"
  rejected(s,"invalid",function() return report(s,17,incoming) end)
  incoming.currentJob=false
  assert(report(s,17,incoming).ok)
  for _,status in ipairs({"returning","dropping","charging","blocked","stopped"}) do
    incoming=record(17) incoming.state=status
    assert(report(s,17,incoming).ok)
    incoming.currentJob=false
    assert(report(s,17,incoming).ok)
  end
end)

test("occupancy keeps frame heading confidence source and anchor distinct",function()
  local s=state()
  for _,frame in ipairs({"abs","f:17:first","f:17:second"}) do
    local incoming=record(17)
    local occupied=clone(incoming.pose)
    occupied.frame,occupied.yAbs,occupied.h=frame,frame=="abs",2
    occupied.conf,occupied.src,occupied.anchoredAt="lost","inherited",0
    occupied.boot=incoming.boot
    s.poses[17]=occupied
    local before=encode(s.poses)
    local result=report(s,17,incoming)
    assert(result.ok and result.record.pose.frame==frame and result.record.pose.yAbs==(frame=="abs"))
    assert(result.record.pose.h==2 and result.record.pose.conf=="lost"
      and result.record.pose.src=="inherited" and result.record.pose.anchoredAt==0)
    assert(encode(s.poses)==before)
  end
  for _,change in ipairs({
    function(p) p.v=nil end,function(p) p.v=2 end,function(p) p.frame="local" end,
    function(p) p.frame="f:" end,function(p) p.frame=false end,function(p) p.yAbs=false end,
    function(p) p.yAbs=nil end,function(p) p.h=nil end,function(p) p.h=4 end,
    function(p) p.conf="confirmed" end,function(p) p.src="telemetry" end,
    function(p) p.anchoredAt=false end,function(p) p.anchoredAt=-1 end,
  }) do
    local incoming=record(17) change(incoming.pose)
    rejected(s,"invalid",function() return report(s,17,incoming) end)
  end
end)

test("the legacy occupancy adapter never invents confidence or a heading",function()
  local s=state()
  local incoming=record(17)
  local legacy={dim="minecraft:overworld",x=10,y=65,z=20}
  assert(F.fromLegacyPose(legacy,17)==false)
  s.poses[17]=clone(legacy) s.poses[17].boot=incoming.boot
  assert(report(s,17,incoming).record.pose==false)
  legacy.h=1
  local converted=F.fromLegacyPose(legacy,17)
  assert(converted.v==1 and converted.frame=="f:17:legacy" and converted.yAbs==false)
  assert(converted.conf=="lost" and converted.src=="inherited" and converted.anchoredAt==0 and converted.h==1)
  s.poses[17]=clone(legacy) s.poses[17].boot=incoming.boot
  equal(report(s,17,incoming).record.pose,converted)
  legacy.h=nil legacy.x="10"
  assert(F.fromLegacyPose(legacy,17)==nil)
  s.poses[17]=clone(incoming.pose) s.poses[17].boot=incoming.boot s.poses[17].v=2
  rejected(s,"invalid",function() return report(s,17,incoming) end)
  s.poses[17]=clone(incoming.pose) s.poses[17].boot=incoming.boot s.poses[17].h=nil
  rejected(s,"invalid",function() return report(s,17,incoming) end)
  s.poses=true
  rejected(s,"invalid",function() return report(s,17,incoming) end)
  s.poses=setmetatable({},{})
  local before=s.poses
  local result=report(s,17,incoming)
  assert(result.code=="invalid" and s.poses==before)
end)

test("context epochs and saved versions remain numeric and explicit",function()
  local s=state()
  for _,value in ipairs({"3",false,-1,0.5,2147483648}) do
    local ctx=context() ctx.epoch=value
    rejected(s,"invalid",function() return call(s,4,"wh2-get",{topic="fleet"},ctx) end)
  end
  local ctx=context() ctx.epoch=nil
  rejected(s,"invalid",function() return report(s,17,record(17),ctx) end)
  for _,value in ipairs({0,2147483647}) do
    ctx=context() ctx.epoch=value
    assert(call(s,4,"wh2-get",{topic="fleet"},ctx).ok)
  end
  assert(patch(s,{set={enabled=true}}).ok)
  for _,change in ipairs({
    function(v) v.v=nil end,function(v) v.v=2 end,function(v) v.settings.v=nil end,
    function(v) v.settings.v=2 end,function(v) v.settings.global=nil end,
    function(v) v.settings.roles=nil end,function(v) v.settings.computers=nil end,
  }) do
    local bad=clone(s.wh2.fleet) change(bad)
    assert(not F.valid(bad,pose))
  end
end)
print("Fleet domain passed "..passed.." checks")
return true
