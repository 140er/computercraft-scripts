local mocks=dofile("tests/mocks.lua")
local env=mocks.new(false).env
env.dofile=function(path) return assert(loadfile(path,"t",env))() end
local locations=env.dofile("wh2-locations.lua")
local ar=env.dofile("wh2-ar.lua")
local function pose(p) return type(p)=="table" and type(p.dim)=="string" and type(p.x)=="number" and type(p.y)=="number" and type(p.z)=="number" end
local state={rev=8,warehouse={locationsRevision=8,sites={
  output={kind="drop",pose={dim="minecraft:overworld",x=1,y=64,z=2,h=0},side="front"},
  station={kind="charge",pose={dim="minecraft:overworld",x=4,y=64,z=2,h=0},side="front"},
}}}
local result=locations.read(state,{cursor=0},pose)
assert(result.ok and #result.records==2 and result.records[1].id=="output")
assert(result.records[1].access.pose.x==1 and result.records[1].block.x==1 and result.records[1].block.z==1)
assert(result.records[1].v==1 and result.records[1].access.pose.frame=="abs" and result.records[1].access.pose.h==0)
assert(result.records[1].siteNames.drop=="output" and result.records[2].kind=="charge")
assert(state.warehouse.sites.output.block==nil)
for heading,step in pairs({[0]={0,-1},[1]={1,0},[2]={0,1},[3]={-1,0}}) do
  state.warehouse.sites.output.pose.h=heading
  local location=locations.read(state,{cursor=0,id="output"},pose).records[1]
  assert(location.block.x==1+step[1] and location.block.z==2+step[2])
end
state.warehouse.sites.output.pose.h=0
for side,dy in pairs({top=1,bottom=-1}) do
  state.warehouse.sites.output.side=side
  local location=locations.read(state,{cursor=0,id="output"},pose).records[1]
  assert(location.block.x==1 and location.block.y==64+dy and location.block.z==2)
end
state.warehouse.sites.output.side="front"
assert(locations.read(state,{cursor=0,revision=7},pose).code=="stale_revision")
assert(locations.read(state,{cursor=99},pose).code=="invalid")
result=locations.read(state,{cursor=0,id="station"},pose)
assert(#result.records==1 and result.records[1].id=="station")
local records={['cc:7']={computerId=7,role="miner",label="East",state="mining",lastSeen=1000,
  pose={v=1,frame="abs",yAbs=true,dim="minecraft:overworld",x=4,y=65,z=8,h=0,conf="certain",src="typed",anchoredAt=0},fuel={level=80},appliedSettingsRevision=3,error=false}}
result=ar.merge({{id=7,x=-1},{id=8,x=2}},records,2000)
assert(#result==2 and result[1].id==7 and result[1].x==4 and result[1].status=="mining")
assert(result[1].poseConfirmed and result[1].settingsRevision==3 and result[1].fuel==80)
assert(ar.entries(records,16000)[1].status=="offline")
assert(records['cc:7'].state=="mining")
records['cc:7'].pose.conf="suspect"
local uncertain=ar.entries(records,2000)[1]
assert(uncertain.x==4 and not uncertain.poseConfirmed and uncertain.status=="mining [suspect]")
records['cc:7'].pose.frame="f:7"
assert(ar.entries(records,2000)[1].x==nil and not ar.entries(records,2000)[1].poseConfirmed)
assert(ar.entries(records,2000)[1].pose.frame=="f:7")
local dispatch=env.dofile("wh2-dispatch.lua").open({enabled=false},pose)
assert(dispatch.run(state,7,{op="wh2-report",body={wh2=1}},{now=1000}).code=="disabled")
assert(state.wh2==nil)
dispatch=env.dofile("wh2-dispatch.lua").open({enabled=true},pose)
assert(dispatch.run(state,7,{op="wh2-layout",body={wh2=1}},{now=1000}).code=="unavailable")
assert(dispatch.run(state,7,{op="wh2-get",body={wh2=1,topic="locations",cursor=0}},{now=1000}).ok)
assert(dispatch.valid({schema=1,layout={opaque="retained"}}))
local config=env.dofile("wh2-dispatch.lua").config
assert(config(nil).enabled==false)
assert(config({enabled=true,operators={["4"]=true},enrolledRoles={["17"]="miner"}},{["4"]="paired",["17"]="paired"}))
assert(not pcall(config,{operators={["04"]=true}}))
assert(not pcall(config,{operators={[4]=true}}))
assert(not pcall(config,{enrolledRoles={["17"]="invented"}}))
assert(not pcall(config,{operators={["4"]=true}},{}))
state.wh2={schema=1,layout={v=1,revision=2,locations={parking={v=1,id="parking",kind="parking",enabled=true,
  access={pose={v=1,frame="abs",yAbs=true,dim="minecraft:overworld",x=2,y=65,z=3,h=0,conf="certain",src="typed",anchoredAt=1000},side="front"}}}}}
local published=locations.read(state,{cursor=0,id="parking"},pose)
assert(published.ok and published.revision=="8:2" and #published.records==1 and published.records[1].kind=="parking")
assert(locations.read(state,{cursor=1},pose).code=="invalid")
print("PASS fleet shared location and AR adapters")
