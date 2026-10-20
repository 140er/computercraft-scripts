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
  return {now=1792500000123,epoch="3",pose=pose,config={enabled=true,operators={["4"]=true}},capabilities={}}
end
local function state()
  return {schema=1,poses={},moves={},warehouse={sites={}},wh2={schema=1,
    layout={opaque="kept"},wizard={opaque="kept"},craft={opaque="kept"}}}
end
local function record(id)
  return {id="cc:"..id,computerId=id,turtleId=id,kind="turtle",label="Miner east",role="miner",
    boot="1792500000000:"..id,ownerGeneration=4,state="mining",detail="Zone 3",
    pose={dim="minecraft:overworld",x=100,y=65,z=200},heading=0,poseConfirmed=false,
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
  local approved=[[enabled navigation mining warehouse sorting smelting crafting autoCharge autoDropoff traffic mesh returnHome
    fuelLow fuelTarget fuelMargin minFreeSlots fullnessHigh chargeTimeoutMs dropoffId chargerId parkingId keep miningTargets
    miningMode branchLength reach tripSeconds sessionSeconds minSessionSeconds thoroughGap fastGap layerStep layers veinLimit
    junkEvery retrySeconds minTripFuel warehouseFuelMargin roomMaxSize roomMaxHeight roomMaxCells roomMaxFurnaces roomIntervalMs
    roomFuelLow wiredIntervalMs smeltQueue charcoal keepLogs useStorageFuel extraSmelt noSmelt roomFuels wiredFuels leave
    navMaxCells navMaxSearch navBatch trafficWaits trafficWaitMs routeRetries trafficRouteRetries trailLength rpcTimeoutMs]]
  local names,count={},0
  for name in approved:gmatch("%S+") do names[name]=true end
  for key,row in pairs(F.registry) do
    assert(names[key],"Unapproved setting "..key)
    names[key]=nil count=count+1
    assert(type(row.type)=="string" and row.default~=nil)
    if row.type=="integer" or row.type=="number" then assert(row.min~=nil and row.max~=nil) end
    if row.type:match("^item") then assert(row.maxEntries and row.maxLength) end
  end
  assert(next(names)==nil and count==63)
  local d=F.defaults()
  assert(d.enabled==false and d.mining==false and d.mesh==true and d.returnHome==true)
  assert(d.fuelLow==200 and d.fuelTarget==2000 and d.fullnessHigh==0.875)
  assert(d.branchLength==64 and d.reach==96 and d.navMaxCells==2048 and d.navBatch==32)
  assert(d.roomIntervalMs==5000 and d.wiredIntervalMs==3000)
  assert(d.roomFuels[4]=="minecraft:dried_kelp_block" and #d.roomFuels==4)
  assert(d.wiredFuels[5]=="minecraft:lava_bucket" and d.leave["minecraft:bucket"]==9999)
  assert(F.validSettings({revision=0,defaults=d,overrides={}}))
end)

test("defaults and effective values have no shared mutable tables",function()
  local d=F.defaults()
  d.keep["minecraft:coal"]=true d.roomFuels[1]="minecraft:stone" d.leave["minecraft:bucket"]=0
  local fresh=F.defaults()
  assert(next(fresh.keep)==nil and fresh.roomFuels[1]=="minecraft:charcoal" and fresh.leave["minecraft:bucket"]==9999)
  local settings={revision=2,defaults={keep={["minecraft:coal"]=true}},overrides={["17"]={roomFuels={"minecraft:coal"}}}}
  local effective=F.effective(settings,17)
  effective.keep["minecraft:iron_ingot"]=true effective.roomFuels[1]="minecraft:stone"
  assert(settings.defaults.keep["minecraft:iron_ingot"]==nil)
  assert(settings.overrides["17"].roomFuels[1]=="minecraft:coal")
end)

test("settings inherit per key and preserve explicit false",function()
  local s=state()
  local result,hint=patch(s,{set={autoCharge=true,fuelTarget=3000,dropoffId="mine-drop"}})
  assert(result.ok and result.wh2==1 and result.revision==1 and result.effective.autoCharge==true)
  equal(hint,{topic="settings",revision=1})
  result,hint=patch(s,{scope="turtle",computerId=17,set={autoCharge=false,fuelTarget=4000,dropoffId=false}})
  assert(result.ok and result.effective.autoCharge==false and result.effective.dropoffId==false)
  equal(hint,{topic="settings",revision=2})
  assert(patch(s,{set={fuelTarget=5000}}).ok)
  assert(F.effective(s.wh2.fleet.settings,17).fuelTarget==4000)
  assert(F.effective(s.wh2.fleet.settings,18).fuelTarget==5000)
  assert(F.effective(s.wh2.fleet.settings,17).autoCharge==false)
  result=patch(s,{scope="turtle",computerId=17,unset={"fuelTarget","autoCharge","dropoffId"}})
  assert(result.ok and result.effective.fuelTarget==5000 and result.effective.autoCharge==true)
  assert(result.effective.dropoffId=="mine-drop" and s.wh2.fleet.settings.overrides["17"]==nil)
  result=patch(s,{unset={"fuelTarget","autoCharge","dropoffId"}})
  assert(result.ok and result.effective.fuelTarget==2000 and result.effective.autoCharge==false)
  assert(result.effective.dropoffId==false and result.revision==5)
end)

test("map and array settings replace whole values",function()
  local s=state()
  assert(patch(s,{set={keep={["minecraft:coal"]=true,["minecraft:iron_ingot"]=true},roomFuels={"minecraft:coal","minecraft:charcoal"}}}).ok)
  assert(patch(s,{scope="turtle",computerId=17,set={keep={},roomFuels={"minecraft:lava_bucket"}}}).ok)
  local effective=F.effective(s.wh2.fleet.settings,17)
  assert(next(effective.keep)==nil and #effective.roomFuels==1 and effective.roomFuels[1]=="minecraft:lava_bucket")
  assert(patch(s,{scope="turtle",computerId=17,unset={"keep","roomFuels"}}).ok)
  effective=F.effective(s.wh2.fleet.settings,17)
  assert(effective.keep["minecraft:coal"] and #effective.roomFuels==2)
  assert(patch(s,{set={leave={["minecraft:bucket"]=0}}}).ok)
  effective=F.effective(s.wh2.fleet.settings,17)
  assert(effective.leave["minecraft:bucket"]==0 and effective.leave["minecraft:water_bucket"]==nil)
end)

test("settings patches reject unknown and pending keys atomically",function()
  local s=state()
  for _,key in ipairs({"notASetting","offlineAutonomy","leaseMs","journalMaxBytes","storagePolicy"}) do
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
  assert(patch(s,{scope="turtle",computerId=17,set={fuelTarget=1000}}).ok)
  rejected(s,"invalid",function() return patch(s,{set={fuelLow=1200,enabled=true}}) end)
  assert(s.wh2.fleet.settings.revision==1 and F.effective(s.wh2.fleet.settings,18).fuelLow==200)
  assert(patch(s,{scope="turtle",computerId=18,set={reach=80}}).ok)
  rejected(s,"invalid",function() return patch(s,{set={branchLength=64,reach=32}}) end)
  assert(patch(s,{scope="turtle",computerId=18,set={sessionSeconds=1000}}).ok)
  rejected(s,"invalid",function() return patch(s,{set={tripSeconds=1100}}) end)
  rejected(s,"invalid",function() return patch(s,{set={minSessionSeconds=1100}}) end)
  rejected(s,"invalid",function() return patch(s,{scope="turtle",computerId=17,set={fuelLow=1000}}) end)
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
  assert(s.wh2.fleet.settings.revision==1 and s.wh2.fleet.settings.defaults.navigation==true)
end)

test("reports bind identity and stamp confirmed pose and server time",function()
  local s=state()
  local incoming=record(17)
  local confirmed={dim="minecraft:overworld",x=10,y=65,z=20,boot=incoming.boot}
  s.poses[17]=confirmed
  local before=encode(incoming)
  local occupancy=encode(s.poses)
  local result,hint=call(s,17,"wh2-report",{record=incoming,appliedSettingsRevision=3})
  assert(result.ok and result.wh2==1 and result.revision==1 and result.settingsRevision==0 and hint==nil)
  assert(result.record.id=="cc:17" and result.record.turtleId==17 and result.record.poseConfirmed==true)
  assert(result.record.lastSeen==1792500000123 and result.record.appliedSettingsRevision==3)
  equal(result.record.pose,{dim="minecraft:overworld",x=10,y=65,z=20})
  assert(encode(s.poses)==occupancy and encode(incoming)==before)
  assert(s.wh2.fleet.settings.revision==nil)
  result.record.pose.x=999 result.record.inventory.usedSlots=0
  assert(s.wh2.fleet.records["cc:17"].pose.x==10 and s.wh2.fleet.records["cc:17"].inventory.usedSlots==14)
  assert(F.valid(s.wh2.fleet,pose))
  incoming=record(17) incoming.lastSeen=nil
  assert(report(s,17,incoming).record.lastSeen==1792500000123 and incoming.lastSeen==nil)
  rejected(s,"forbidden",function() return report(s,18,record(17)) end)
  incoming=record(17) incoming.turtleId=18
  rejected(s,"forbidden",function() return report(s,17,incoming) end)
end)

test("a changed boot cannot confirm a reported pose",function()
  local s=state()
  local incoming=record(17) incoming.poseConfirmed=true
  s.poses[17]={dim="minecraft:overworld",x=1,y=2,z=3,boot="older-boot"}
  local result=report(s,17,incoming)
  assert(result.ok and result.record.poseConfirmed==false and result.record.pose.x==100)
  s.poses[17]=nil
  s.poses["17"]={dim="minecraft:overworld",x=1,y=2,z=3,boot=incoming.boot}
  result=report(s,17,incoming)
  assert(result.ok and result.record.poseConfirmed==false and result.record.pose.x==100)
  incoming.pose=false incoming.poseConfirmed=false incoming.heading=false
  result=report(s,17,incoming)
  assert(result.ok and result.record.pose==false and result.record.heading==false)
end)

test("computers report false turtle fields and unlimited fuel remains a string",function()
  local s=state()
  local computer=record(4)
  computer.kind,computer.role,computer.turtleId,computer.fuel,computer.inventory="computer","panel",false,false,false
  computer.currentJob,computer.pose,computer.heading=false,false,false
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
  assert(patch(s,{scope="turtle",computerId=17,set={autoCharge=false}}).ok)
  local result=call(s,17,"wh2-get",{topic="settings",cursor=0})
  assert(result.ok and result.revision==2 and result.cursor==0 and #result.records==1 and #encode(result)<=4096)
  assert(result.records[1].id=="17" and result.records[1].revision==2 and result.records[1].effective.autoCharge==false)
  assert(result.records[1].registry==nil and result.records[1].overrides==nil)
  result=call(s,17,"wh2-get",{topic="settings",computerId=18})
  assert(result.ok and result.records[1].id=="18" and result.records[1].effective.autoCharge==true)
  result=call(s,4,"wh2-get",{topic="settings",id="17"})
  assert(result.ok and result.records[1].effective.autoCharge==false)
  result=call(s,4,"wh2-get",{topic="settings",id="settings",computerId=17})
  assert(result.ok and result.records[1].id=="settings" and result.records[1].revision==2)
  assert(result.records[1].defaults.autoCharge==true and result.records[1].overrides["17"].autoCharge==false)
  assert(result.records[1].effective.autoCharge==false and result.records[1].registry==nil)
  result.records[1].overrides["17"].autoCharge=true
  assert(s.wh2.fleet.settings.overrides["17"].autoCharge==false)
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
  assert(result.ok and result.records[1].effective.enabled==false and s.wh2==nil)
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
  assert(F.valid({revision=0,records={},settings={}},pose))
  local s=state()
  assert(patch(s,{set={autoCharge=true,keep={["minecraft:coal"]=true}}}).ok)
  assert(patch(s,{scope="turtle",computerId=17,set={autoCharge=false}}).ok)
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
  bad=clone(saved.wh2.fleet) bad.settings.overrides[17]={enabled=false}
  assert(not F.valid(bad,pose))
  assert(not F.validSettings({revision=0,defaults={},overrides={["017"]={}}}))
  assert(not F.validSettings({revision=0,defaults={},overrides={["2147483648"]={}}}))
  assert(not F.validSettings({revision=0,defaults={},overrides={["nil"]=true}}))
  assert(not F.validSettings({revision=0,defaults={},overrides={["nil"]={fuelLow="invalid"}}}))
end)

test("fleet and settings capacity limits reject additions without changing existing records",function()
  local s=state()
  for id=1,32 do assert(report(s,id).ok) end
  rejected(s,"capacity",function() return report(s,33) end)
  assert(report(s,1).ok)
  for id=1,32 do assert(patch(s,{scope="turtle",computerId=id,set={mining=false}}).ok) end
  rejected(s,"capacity",function() return patch(s,{scope="turtle",computerId=33,set={mining=false}}) end)
  assert(patch(s,{scope="turtle",computerId=1,unset={"mining"}}).ok)
  assert(patch(s,{scope="turtle",computerId=33,set={mining=false}}).ok)
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
    assert(patch(s,{scope="turtle",computerId=id,set={keep={["test:"..string.rep("x",50)..id]=true}}}).ok)
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
  rejected(s,"invalid",function() return patch(s,{scope="turtle",computerId="17",set={enabled=true}}) end)
end)

test("global settings reads exclude computer overrides",function()
  local s=state()
  assert(patch(s,{set={autoCharge=true}}).ok)
  assert(patch(s,{scope="turtle",computerId=17,set={autoCharge=false}}).ok)
  local result=call(s,17,"wh2-get",{topic="settings",field="defaults",computerId=17})
  assert(result.ok and result.records[1].id=="defaults" and result.records[1].effective.autoCharge==true)
  result=call(s,17,"wh2-get",{topic="settings"})
  assert(result.ok and result.records[1].effective.autoCharge==false)
end)
test("fleet capacity rejection preserves readable saved state",function()
  local s=state()
  local refused=false
  for id=1,32 do
    local value=record(id)
    value.detail=string.rep("x",256)
    value.label=string.rep("x",64)
    for key=1,16 do value.capabilities["capability"..key..string.rep("x",16)]=true end
    value.capabilities.navigation,value.capabilities.inventory,value.capabilities.crafting=nil,nil,nil
    local before=encode(s)
    local result=report(s,id,value)
    if not result.ok then
      assert(result.code=="capacity" and encode(s)==before)
      refused=true break
    end
    assert(F.valid(s.wh2.fleet,pose))
  end
  assert(refused)
end)
print("Fleet domain passed "..passed.." checks")
return true
