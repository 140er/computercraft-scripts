local mocks=dofile("tests/mocks.lua")
local env=mocks.new(false).env
env.dofile=function(path) return assert(loadfile(path,"t",env))() end
local Fleet=env.dofile("wh2-fleet.lua")
local settings={revision=0,defaults={},overrides={}}
local state={}
local context={now=1000,epoch="1",config={enabled=true,operators={["4"]=true}}}
local requests={}
local client={call=function(op,body)
  requests[#requests+1]={op=op,body=body}
  return Fleet.run(state,4,{op=op,body=body},context)
end}
local dev=env.dofile("wh2-dev.lua").open({client=client,screen={}})
dev.tick()
assert(dev.effective.autoCharge==false and requests[1].body.field=="defaults")
assert(dev.set("autoCharge",true))
assert(dev.set("fuelLow",150))
dev.tick() dev.tick()
assert(state.wh2.fleet.settings.defaults.autoCharge==true and state.wh2.fleet.settings.defaults.fuelLow==150)
assert(state.wh2.fleet.settings.revision==2)
assert(dev.select(17))
assert(dev.set("autoCharge",false))
assert(dev.select(false))
dev.tick()
assert(state.wh2.fleet.settings.overrides["17"].autoCharge==false)
assert(state.wh2.fleet.settings.defaults.autoCharge==true)
assert(dev.select(17))
assert(dev.unset("autoCharge"))
dev.tick()
assert(state.wh2.fleet.settings.overrides["17"]==nil)
assert(dev.select(false))
assert(dev.set("fullnessHigh",0.75))
assert(dev.select(17))
dev.tick()
assert(state.wh2.fleet.settings.defaults.fullnessHigh==0.75)
assert(state.wh2.fleet.settings.overrides["17"]==nil)
assert(not dev.set("offlineAutonomy",true))
assert(not dev.select(-1))
print("PASS fleet dev edits preserve scope and order")
