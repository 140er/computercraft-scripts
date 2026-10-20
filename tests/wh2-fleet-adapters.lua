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
assert(result.records[1].access.pose.x==1 and result.records[1].block.x==2)
assert(result.records[1].siteNames.drop=="output" and result.records[2].kind=="charge")
assert(state.warehouse.sites.output.block==nil)
assert(locations.read(state,{cursor=0,revision=7},pose).code=="stale_revision")
assert(locations.read(state,{cursor=99},pose).code=="invalid")
result=locations.read(state,{cursor=0,id="station"},pose)
assert(#result.records==1 and result.records[1].id=="station")
local records={['cc:7']={computerId=7,role="miner",label="East",state="mining",lastSeen=1000,
  pose={dim="minecraft:overworld",x=4,y=65,z=8},poseConfirmed=true,fuel={level=80},appliedSettingsRevision=3,error=false}}
result=ar.merge({{id=7,x=-1},{id=8,x=2}},records,2000)
assert(#result==2 and result[1].id==7 and result[1].x==4 and result[1].status=="mining")
assert(result[1].poseConfirmed and result[1].settingsRevision==3 and result[1].fuel==80)
assert(ar.entries(records,16000)[1].status=="offline")
assert(records['cc:7'].state=="mining")
local dispatch=env.dofile("wh2-dispatch.lua").open({enabled=false},pose)
assert(dispatch.run(state,7,{op="wh2-report",body={wh2=1}},{now=1000}).code=="disabled")
assert(state.wh2==nil)
dispatch=env.dofile("wh2-dispatch.lua").open({enabled=true},pose)
assert(dispatch.run(state,7,{op="wh2-layout",body={wh2=1}},{now=1000}).code=="unavailable")
assert(dispatch.run(state,7,{op="wh2-get",body={wh2=1,topic="locations",cursor=0}},{now=1000}).ok)
assert(dispatch.valid({schema=1,layout={opaque="retained"}}))
print("PASS fleet shared location and AR adapters")
